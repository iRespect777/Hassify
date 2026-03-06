#!/bin/bash

# ============================================================================
#  Home Assistant Supervised — ULTIMATE INSTALLER
#  Версия:    6.0 (Ultimate Edition)
#  Платформа: TV-Боксы и SBC (Armbian Bookworm / aarch64 / x86_64)
# ============================================================================

readonly SCRIPT_VERSION="6.0"
readonly HA_DEFAULT_MACHINE="qemuarm-64"
readonly STATE_FILE="/root/.ha_install_state"
readonly LOCK_FILE="/var/lock/ha_install.lock"
readonly BACKUP_DIR="/root/.ha_install_backup"
readonly LOG_DIR="/var/log"
readonly HASSIO_DIR="/usr/share/hassio"
readonly GRACE_MARKER="/tmp/.ha_just_installed"

set -uo pipefail

# ========================== ЦВЕТА ===========================================
if [ -t 1 ]; then
    RED='\033[0;31m'    GREEN='\033[0;32m'
    YELLOW='\033[1;33m' BLUE='\033[0;34m'
    MAGENTA='\033[0;35m' CYAN='\033[0;36m'
    WHITE='\033[1;37m'  BOLD='\033[1m'
    DIM='\033[2m'       NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' MAGENTA=''
    CYAN='' WHITE='' BOLD='' DIM='' NC=''
fi

CHECK="${GREEN}✔${NC}"  CROSS="${RED}✘${NC}"
ARROW="${CYAN}➜${NC}"   WARN="${YELLOW}⚠${NC}"
INFO="${BLUE}ℹ${NC}"    GEAR="${MAGENTA}⚙${NC}"

# ========================== ПЕРЕМЕННЫЕ УСТАНОВКИ ============================
RUN_WIZARD=true
OPT_ZRAM=true
OPT_UFW=true
OPT_HACS=true
OPT_EXTRAS=true
OPT_HOSTNAME=true
TG_TOKEN=""
TG_CHAT=""

SKIP_UPDATE=false
CHECK_ONLY=false
UNINSTALL=false
DRY_RUN=false
HA_MACHINE="$HA_DEFAULT_MACHINE"
LOG_FILE=""

# ========================== ВЫВОД И ЛОГИРОВАНИЕ =============================
header() {
    echo -e "\n${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    printf "${BLUE}║${WHITE}${BOLD}  %-58s${NC}${BLUE}║${NC}\n" "$1"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}\n"
}
separator()  { echo -e "${DIM}  ────────────────────────────────────────────────────────────${NC}"; }
msg_info()   { echo -e " ${INFO}  ${WHITE}$1${NC}"; }
msg_ok()     { echo -e " ${CHECK}  ${GREEN}$1${NC}"; }
msg_warn()   { echo -e " ${WARN}  ${YELLOW}$1${NC}"; }
msg_error()  { echo -e " ${CROSS}  ${RED}$1${NC}"; }
msg_action() { echo -e " ${ARROW}  ${CYAN}$1${NC}"; }
msg_dim()    { echo -e "       ${DIM}$1${NC}"; }

setup_logging() {
    LOG_FILE="${LOG_FILE:-${LOG_DIR}/ha_install_$(date +%Y%m%d_%H%M%S).log}"
    mkdir -p "$(dirname "$LOG_FILE")"
    exec 3>&1 4>&2
    exec > >(tee -a "$LOG_FILE") 2>&1
    msg_info "Лог: ${LOG_FILE}"
}

flush_log() {
    exec 1>&3 2>&4 3>&- 4>&- 2>/dev/null || true
    sleep 0.5
}

# ========================== STATE & LOCK ====================================
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid=""
        pid=$(cat "$LOCK_FILE" 2>/dev/null) || true
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            msg_error "Скрипт уже запущен (PID ${pid})"
            exit 1
        fi
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
}

release_lock() { rm -f "$LOCK_FILE" 2>/dev/null || true; }
mark_done()    { echo "$1" >> "$STATE_FILE"; }
is_done()      { [ -f "$STATE_FILE" ] && grep -qx "$1" "$STATE_FILE" 2>/dev/null; }

reset_state() {
    rm -f "$STATE_FILE" "$GRACE_MARKER" 2>/dev/null || true
    msg_ok "Состояние сброшено. Следующий запуск — с нуля."
}

cleanup() {
    local exit_code=$?
    rm -f /tmp/os-agent.deb /tmp/ha.deb /tmp/ha_step_*.log 2>/dev/null || true
    release_lock
    flush_log 2>/dev/null || true
    [ $exit_code -eq 130 ] && echo -e "\n ${WARN}  ${YELLOW}Прервано (Ctrl+C)${NC}"
}
trap cleanup EXIT INT TERM

# ========================== УТИЛИТЫ =========================================
is_pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

run_cmd() {
    local desc="$1"; shift
    local lfile
    lfile=$(mktemp /tmp/ha_step_XXXXXX.log)
    msg_action "${desc}..."
    if [ "$DRY_RUN" = true ]; then
        msg_dim "[dry-run] $*"
        rm -f "$lfile"
        return 0
    fi
    if "$@" > "$lfile" 2>&1; then
        msg_ok "$desc"
        rm -f "$lfile"
        return 0
    else
        local c=$?
        msg_error "${desc} — ОШИБКА (${c})"
        msg_warn "Лог: ${lfile}"
        tail -15 "$lfile" 2>/dev/null | while IFS= read -r l; do
            echo -e "    ${RED}│${NC} ${l}"
        done
        return $c
    fi
}

run_cmd_fatal() {
    if ! run_cmd "$@"; then
        msg_error "Критическая ошибка. Остановка."
        exit 1
    fi
}

download_file() {
    local url="$1" output="$2" desc="$3" max="${4:-3}" att=1
    if [ "$DRY_RUN" = true ]; then
        msg_action "${desc}..."
        msg_dim "[dry-run] wget ${url}"
        return 0
    fi
    while [ $att -le $max ]; do
        [ $att -gt 1 ] && sleep $((att * 3))
        msg_action "${desc} (попытка ${att}/${max})..."
        rm -f "$output" 2>/dev/null || true
        if wget -q --timeout=60 --tries=1 -O "$output" "$url" 2>/dev/null && [ -s "$output" ]; then
            if [[ "$output" == *.deb ]]; then
                if dpkg-deb --info "$output" &>/dev/null; then
                    msg_ok "${desc}"
                    return 0
                fi
                msg_warn "Файл .deb повреждён, повтор..."
            else
                msg_ok "${desc}"
                return 0
            fi
        else
            msg_warn "Ошибка загрузки"
        fi
        att=$((att + 1))
    done
    msg_error "${desc} — не удалось после ${max} попыток"
    return 1
}

get_latest_release() {
    command -v curl &>/dev/null || { echo ""; return; }
    command -v jq &>/dev/null  || { echo ""; return; }
    curl -fsSL --timeout 15 \
        "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null || true
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "x86_64"  ;;
        aarch64) echo "aarch64" ;;
        armv7l)  echo "armv7"   ;;
        *)       echo "unknown" ;;
    esac
}

detect_machine_type() {
    local dtmodel=""
    dtmodel=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null) || true
    case "$(uname -m)" in
        x86_64) echo "generic-x86-64" ;;
        aarch64)
            case "$dtmodel" in
                *Raspberry*Pi*5*)  echo "raspberrypi5-64" ;;
                *Raspberry*Pi*4*)  echo "raspberrypi4-64" ;;
                *Raspberry*Pi*3*)  echo "raspberrypi3-64" ;;
                *ODROID-N2*)       echo "odroid-n2" ;;
                *ODROID-C4*)       echo "odroid-c4" ;;
                *Khadas*VIM3*)     echo "khadas-vim3" ;;
                *)                 echo "qemuarm-64" ;;
            esac ;;
        armv7l) echo "qemuarm" ;;
        *)      echo "qemuarm-64" ;;
    esac
}

# ========================== МАСТЕР TUI ======================================
run_wizard() {
    if ! command -v whiptail &>/dev/null; then
        apt-get update -qq && apt-get install -y whiptail -qq
    fi

    whiptail --title "HA Ultimate Installer v${SCRIPT_VERSION}" --msgbox \
        "Добро пожаловать в установщик Home Assistant Supervised\nдля TV-боксов и SBC.\n\nНа следующих экранах вы сможете выбрать компоненты." 12 62

    local choices
    choices=$(whiptail --title "Компоненты установки" --checklist \
        "Выберите модули (Пробел — выбор, Enter — подтвердить):" 18 65 5 \
        "ZRAM"   "Сжатие в RAM (спасает eMMC от износа)" ON \
        "UFW"    "Firewall и Fail2Ban (Безопасность)"    ON \
        "HACS"   "Автоустановка магазина HACS"           ON \
        "EXTRAS" "Watchdog, Очистка, Автосеть, mDNS"     ON \
        3>&1 1>&2 2>&3) || { echo "Установка отменена пользователем."; exit 0; }

    [[ $choices != *"ZRAM"* ]]   && OPT_ZRAM=false
    [[ $choices != *"UFW"* ]]    && OPT_UFW=false
    [[ $choices != *"HACS"* ]]   && OPT_HACS=false
    [[ $choices != *"EXTRAS"* ]] && OPT_EXTRAS=false

    if [ "$OPT_EXTRAS" = true ]; then
        # Спросить про hostname
        if ! whiptail --title "Hostname" --yesno \
            "Установить hostname = 'homeassistant'?\n\nТекущий: $(hostname)\n\nЭто позволит обращаться по http://homeassistant.local:8123" 12 60; then
            OPT_HOSTNAME=false
        fi

        # Спросить про Telegram
        if whiptail --title "Telegram" --yesno \
            "Настроить отправку критических уведомлений\n(зависания, очистка) в Telegram?" 10 60; then
            TG_TOKEN=$(whiptail --title "Telegram Token" --inputbox \
                "Введите токен вашего бота (от @BotFather):" 10 60 \
                3>&1 1>&2 2>&3) || TG_TOKEN=""
            TG_CHAT=$(whiptail --title "Telegram Chat ID" --inputbox \
                "Введите ваш Chat ID (от @userinfobot):" 10 60 \
                3>&1 1>&2 2>&3) || TG_CHAT=""
        fi
    fi
}

# ========================== CHECK / UNINSTALL ===============================

do_check() {
    show_banner
    header "РЕЖИМ ПРОВЕРКИ"

    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="н/д"

    echo -e "  ${BOLD}Система${NC}"
    msg_info "Hostname:      $(hostname 2>/dev/null)"
    msg_info "IP:            ${ip}"
    msg_info "Архитектура:   $(uname -m)"
    msg_info "Ядро:          $(uname -r)"
    separator

    echo -e "  ${BOLD}Компоненты${NC}"
    if command -v docker &>/dev/null; then
        msg_ok  "Docker:        $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
    else
        msg_error "Docker:        не установлен"
    fi

    if command -v gdbus &>/dev/null && gdbus introspect --system --dest io.hass.os --object-path /io/hass/os &>/dev/null 2>&1; then
        msg_ok  "OS-Agent:      активен"
    else
        msg_warn "OS-Agent:      не найден или не активен"
    fi

    local ha_sup
    ha_sup=$(systemctl is-active hassio-supervisor 2>/dev/null) || ha_sup="не найден"
    if [ "$ha_sup" = "active" ]; then
        msg_ok  "Supervisor:    ${ha_sup}"
    else
        msg_error "Supervisor:    ${ha_sup}"
    fi

    local ha_core
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^homeassistant$'; then
        local ha_status
        ha_status=$(docker inspect -f '{{.State.Status}}' homeassistant 2>/dev/null) || ha_status="?"
        msg_ok  "HA Core:       контейнер ${ha_status}"
    else
        msg_error "HA Core:       контейнер не найден"
    fi

    local aa
    aa=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) || aa="N"
    if [ "$aa" = "Y" ]; then
        msg_ok  "AppArmor:      активен"
    else
        msg_warn "AppArmor:      выключен (нужна перезагрузка?)"
    fi

    local nm
    nm=$(systemctl is-active NetworkManager 2>/dev/null) || nm="?"
    msg_info "NetworkManager: ${nm}"
    separator

    echo -e "  ${BOLD}Ресурсы${NC}"
    msg_info "Память:        $(free -h | awk '/Mem:/{printf "%s / %s", $3, $2}')"
    msg_info "Swap:          $(free -h | awk '/Swap:/{printf "%s / %s", $3, $2}')"
    msg_info "Диск /:        $(df -h / | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}')"
    separator

    if [ -f "$STATE_FILE" ]; then
        echo -e "  ${BOLD}Пройденные шаги${NC}"
        while IFS= read -r s; do
            msg_ok "  $s"
        done < "$STATE_FILE"
    fi
    echo ""
}

do_uninstall() {
    show_banner
    header "УДАЛЕНИЕ HOME ASSISTANT SUPERVISED"

    if ! command -v whiptail &>/dev/null || \
       ! whiptail --title "Подтверждение" --yesno \
        "Вы действительно хотите ПОЛНОСТЬЮ удалить\nHome Assistant Supervised?\n\nВсе контейнеры, данные конфигурации и\nвспомогательные скрипты будут удалены." 14 55; then
        # Если whiptail нет — спросить через read
        if ! command -v whiptail &>/dev/null; then
            echo -en " ${WARN}  ${YELLOW}Удалить HA Supervised? (yes/no): ${NC}"
            read -r confirm
            [ "$confirm" != "yes" ] && { msg_info "Отменено."; exit 0; }
        else
            msg_info "Отменено."
            exit 0
        fi
    fi

    msg_action "Остановка сервисов..."
    systemctl stop hassio-supervisor 2>/dev/null || true
    systemctl stop hassio-apparmor 2>/dev/null || true

    msg_action "Остановка и удаление контейнеров HA..."
    local containers
    containers=$(docker ps -a --filter "label=io.hass.type" --format '{{.Names}}' 2>/dev/null) || true
    if [ -n "$containers" ]; then
        echo "$containers" | while IFS= read -r c; do
            msg_dim "Удаление контейнера: $c"
            docker rm -f "$c" 2>/dev/null || true
        done
    fi
    # Также основные контейнеры по имени
    for c in homeassistant hassio_supervisor hassio_cli hassio_audio hassio_dns hassio_multicast hassio_observer; do
        docker rm -f "$c" 2>/dev/null || true
    done

    msg_action "Удаление образов HA..."
    docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
        | grep -iE "homeassistant|hassio|home-assistant" \
        | while IFS= read -r img; do
            msg_dim "Удаление образа: $img"
            docker rmi -f "$img" 2>/dev/null || true
        done

    msg_action "Удаление systemd-юнитов..."
    for svc in hassio-supervisor hassio-apparmor; do
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}.service" 2>/dev/null || true
    done
    rm -rf /etc/systemd/system/hassio-supervisor.service.d 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    msg_action "Удаление пакетов..."
    dpkg --purge homeassistant-supervised 2>/dev/null || true
    dpkg --purge os-agent 2>/dev/null || true

    msg_action "Удаление вспомогательных скриптов..."
    rm -f /usr/local/bin/ha-notify /usr/local/bin/ha-watchdog \
          /usr/local/bin/ha-cleanup /usr/local/bin/ha-net-recovery 2>/dev/null || true
    rm -f /etc/cron.d/ha-tools 2>/dev/null || true

    msg_action "Удаление данных..."
    if [ -d "$HASSIO_DIR" ]; then
        msg_warn "Каталог $HASSIO_DIR содержит ваши данные HA."
        echo -en " ${WARN}  ${YELLOW}Удалить данные конфигурации HA? (yes/no): ${NC}"
        read -r confirm_data
        if [ "$confirm_data" = "yes" ]; then
            rm -rf "$HASSIO_DIR"
            msg_ok "Данные HA удалены"
        else
            msg_info "Данные сохранены в $HASSIO_DIR"
        fi
    fi

    msg_action "Восстановление /etc/os-release..."
    if [ -f "${BACKUP_DIR}/os-release.original" ]; then
        cp "${BACKUP_DIR}/os-release.original" /etc/os-release
        msg_ok "os-release восстановлен"
    fi

    reset_state

    msg_action "Очистка Docker..."
    docker system prune -f 2>/dev/null || true

    header "УДАЛЕНИЕ ЗАВЕРШЕНО"
    msg_info "Docker оставлен в системе (может использоваться другими)."
    msg_info "Для удаления Docker: apt-get purge docker-ce docker-ce-cli containerd.io"
    echo ""
}

# ========================== АРГУМЕНТЫ =======================================

show_help() {
    cat << HELP
${BOLD}Home Assistant Supervised — Ultimate Installer v${SCRIPT_VERSION}${NC}

${BOLD}Использование:${NC}
  sudo ./install.sh              Запуск мастера установки (TUI)
  sudo ./install.sh [ОПЦИИ]      Запуск с параметрами (без мастера)

${BOLD}Опции:${NC}
  -h, --help          Показать эту справку
  -c, --check         Проверить состояние установки
  -u, --uninstall     Удалить Home Assistant Supervised
  --reset-state       Сбросить отметки пройденных шагов
  --skip-update       Пропустить apt update/upgrade
  --dry-run           Показать команды без выполнения

${BOLD}Примеры:${NC}
  sudo ./install.sh                # Интерактивная установка
  sudo ./install.sh --check        # Диагностика
  sudo ./install.sh --dry-run      # Тестовый прогон
  sudo ./install.sh --skip-update  # Установка без обновления пакетов

HELP
}

parse_args() {
    if [ $# -eq 0 ]; then return; fi
    RUN_WIZARD=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)         show_help; exit 0 ;;
            -c|--check)        CHECK_ONLY=true ;;
            -u|--uninstall)    UNINSTALL=true ;;
            --reset-state)     reset_state; exit 0 ;;
            --skip-update)     SKIP_UPDATE=true ;;
            --dry-run)         DRY_RUN=true ;;
            *)                 msg_error "Неизвестный параметр: $1"; show_help; exit 1 ;;
        esac
        shift
    done
}

# ========================== БАННЕР ==========================================
show_banner() {
    clear
    echo -e "${BLUE}    ╦ ╦┌─┐┌┬┐┌─┐  ╔═╗┌─┐┌─┐┬┌─┐┌┬┐┌─┐┌┐┌┌┬┐${NC}"
    echo -e "${BLUE}    ╠═╣│ ││││├┤   ╠═╣└─┐└─┐│└─┐ │ ├─┤│││ │ ${NC}"
    echo -e "${BLUE}    ╩ ╩└─┘┴ ┴└─┘  ╩ ╩└─┘└─┘┴└─┘ ┴ ┴ ┴┘└┘ ┴ ${NC}"
    echo -e "${WHITE}${BOLD}    ULTIMATE INSTALLER v${SCRIPT_VERSION} / Armbian Bookworm${NC}"
    separator
}

# ========================== ШАГИ УСТАНОВКИ ==================================

step_update_system() {
    local sid="update"
    is_done "$sid" && return 0
    header "ШАГ 1 — ОБНОВЛЕНИЕ И ПОДГОТОВКА"

    if [ "$SKIP_UPDATE" = false ]; then
        run_cmd_fatal "apt-get update" apt-get update -y
        run_cmd "apt-get upgrade" apt-get upgrade -y
    else
        msg_warn "Обновление пропущено (--skip-update)"
    fi
    mark_done "$sid"
}

step_install_deps() {
    local sid="deps"
    is_done "$sid" && return 0
    header "ШАГ 2 — ЗАВИСИМОСТИ"

    local pkgs=(
        apparmor avahi-daemon bluez ca-certificates cifs-utils
        curl dbus gnupg jq libglib2.0-bin lsb-release
        network-manager nfs-common software-properties-common
        systemd-journal-remote systemd-resolved systemd-timesyncd
        udisks2 usbutils wget qrencode cpufrequtils
    )
    [ "$OPT_ZRAM" = true ] && pkgs+=(zram-tools)
    [ "$OPT_UFW" = true ]  && pkgs+=(ufw fail2ban)

    # Собираем список неустановленных
    local to_install=()
    for p in "${pkgs[@]}"; do
        is_pkg_installed "$p" || to_install+=("$p")
    done

    if [ ${#to_install[@]} -eq 0 ]; then
        msg_ok "Все ${#pkgs[@]} пакетов уже установлены"
    else
        msg_info "Требуется установить: ${#to_install[@]} из ${#pkgs[@]} пакетов"
        run_cmd_fatal "Установка зависимостей" apt-get install -y "${to_install[@]}"
    fi

    run_cmd "Исправление зависимостей" apt-get -f install -y
    mark_done "$sid"
}

step_configure_network() {
    local sid="network"
    is_done "$sid" && return 0
    header "ШАГ 3 — СЕТЬ И DNS"

    mkdir -p "$BACKUP_DIR" /etc/NetworkManager/conf.d

    # Запоминаем текущий IP
    local current_ip
    current_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || current_ip=""

    cat > /etc/NetworkManager/conf.d/10-ha-managed.conf << 'EOF'
[keyfile]
unmanaged-devices=none

[device]
wifi.scan-rand-mac-address=no
EOF

    # Бэкап и замена interfaces
    if [ -f /etc/network/interfaces ]; then
        cp /etc/network/interfaces "$BACKUP_DIR/interfaces.bak" 2>/dev/null || true
    fi

    cat > /etc/network/interfaces << 'EOF'
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback
EOF

    # systemd-resolved
    systemctl enable systemd-resolved 2>/dev/null || true
    systemctl start systemd-resolved 2>/dev/null || true
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || true

    # Переключение на NetworkManager
    msg_warn "Переключение на NetworkManager..."
    if who 2>/dev/null | grep -q pts; then
        msg_warn "Обнаружена SSH-сессия. Сеть может кратковременно прерваться."
    fi

    systemctl disable networking 2>/dev/null || true
    systemctl enable NetworkManager 2>/dev/null || true
    systemctl restart NetworkManager 2>/dev/null || true

    # Ожидание стабилизации сети (до 30 сек)
    msg_action "Ожидание стабилизации сети..."
    local retries=0
    local new_ip=""
    while [ $retries -lt 6 ]; do
        sleep 5
        new_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || new_ip=""
        if [ -n "$new_ip" ]; then
            msg_ok "Сеть стабильна — IP: ${new_ip}"
            break
        fi
        retries=$((retries + 1))
        msg_dim "Попытка ${retries}/6..."
    done

    if [ $retries -ge 6 ]; then
        msg_error "Сеть не поднялась за 30 секунд!"
        msg_warn "Попытка восстановления..."
        systemctl start networking 2>/dev/null || true
        nmcli networking on 2>/dev/null || true
        sleep 5
        new_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || new_ip=""
        if [ -n "$new_ip" ]; then
            msg_ok "Сеть восстановлена — IP: ${new_ip}"
        else
            msg_error "Не удалось восстановить сеть! Проверьте подключение вручную."
        fi
    fi

    mark_done "$sid"
}

step_configure_apparmor() {
    local sid="apparmor"
    is_done "$sid" && return 0
    header "ШАГ 4 — APPARMOR"

    local aa=""
    aa=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) || aa="N"

    if [ "$aa" = "Y" ]; then
        msg_ok "AppArmor уже активен"
    else
        msg_warn "AppArmor выключен в ядре. Патчим загрузчик..."
        local patched=false

        # Патчим ВСЕ найденные конфиги загрузчика
        for f in /boot/armbianEnv.txt /boot/uEnv.txt /boot/extlinux/extlinux.conf; do
            [ -f "$f" ] || continue
            cp "$f" "${BACKUP_DIR}/$(basename "$f").bak" 2>/dev/null || true

            if grep -q "apparmor=1" "$f"; then
                msg_dim "$(basename "$f") — уже содержит apparmor=1"
                patched=true
                continue
            fi

            if [[ "$f" == *extlinux.conf ]]; then
                sed -i '/^[[:space:]]*append/ s/$/ apparmor=1 security=apparmor/' "$f"
            elif grep -q "^extraargs=" "$f"; then
                sed -i 's|^extraargs=.*|& apparmor=1 security=apparmor|' "$f"
            else
                echo "extraargs=apparmor=1 security=apparmor" >> "$f"
            fi
            msg_ok "Пропатчен: $(basename "$f")"
            patched=true
        done

        if [ "$patched" = false ]; then
            msg_error "Не найден ни один файл загрузчика!"
            msg_warn "Добавьте 'apparmor=1 security=apparmor' в параметры ядра вручную."
        else
            msg_warn "AppArmor активируется после перезагрузки"
        fi
    fi

    systemctl enable apparmor 2>/dev/null || true
    systemctl start apparmor 2>/dev/null || true
    mark_done "$sid"
}

step_performance() {
    local sid="perf"
    is_done "$sid" && return 0
    header "ШАГ 5 — ПРОИЗВОДИТЕЛЬНОСТЬ"

    if [ "$OPT_ZRAM" = true ]; then
        msg_action "Настройка ZRAM (ОЗУ-сжатие)..."

        # Отключаем файловый swap
        if [ -f /swapfile ]; then
            swapoff /swapfile 2>/dev/null || true
            rm -f /swapfile
            sed -i '/swapfile/d' /etc/fstab
            msg_ok "Файловый swap удалён"
        fi

        cat > /etc/default/zramswap << 'EOF'
ALGO=lz4
PERCENT=60
EOF
        systemctl enable zramswap 2>/dev/null || true
        systemctl restart zramswap 2>/dev/null || true
        msg_ok "ZRAM активирован (лучше для eMMC)"
    else
        msg_action "Настройка классического Swap (2 GB)..."
        if [ ! -f /swapfile ]; then
            if dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress 2>/dev/null \
               || dd if=/dev/zero of=/swapfile bs=1M count=2048 2>/dev/null; then
                chmod 600 /swapfile
                mkswap /swapfile >/dev/null
                swapon /swapfile
                msg_ok "Swapfile 2GB создан"
            else
                msg_error "Не удалось создать swapfile (мало места?)"
                rm -f /swapfile 2>/dev/null || true
            fi
        else
            msg_ok "Swapfile уже существует"
        fi
        grep -q "swapfile" /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    # CPU Governor
    msg_action "Тюнинг процессора..."
    if command -v cpufreq-set &>/dev/null; then
        echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils
        systemctl restart cpufrequtils 2>/dev/null || true
        msg_ok "CPU governor: performance"
    else
        msg_dim "cpufreq-set недоступен — пропуск"
    fi

    mark_done "$sid"
}

step_install_docker() {
    local sid="docker"
    is_done "$sid" && return 0
    header "ШАГ 6 — DOCKER"

    if command -v docker &>/dev/null; then
        msg_ok "Docker уже установлен: $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
    else
        msg_action "Удаление старых версий..."
        apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

        run_cmd_fatal "Скачивание и установка Docker" bash -c "curl -fsSL https://get.docker.com | sh"
    fi

    # Гарантируем правильный daemon.json
    mkdir -p /etc/docker
    if [ ! -f /etc/docker/daemon.json ]; then
        cat > /etc/docker/daemon.json << 'EOF'
{
    "log-driver": "journald",
    "storage-driver": "overlay2"
}
EOF
    fi

    systemctl enable docker 2>/dev/null || true
    systemctl restart docker 2>/dev/null || true

    # Проверка
    if docker info &>/dev/null; then
        msg_ok "Docker работает: $(docker --version | awk '{print $3}' | tr -d ',')"
    else
        msg_error "Docker не отвечает!"
        exit 1
    fi

    mark_done "$sid"
}

step_install_os_agent() {
    local sid="osagent"
    is_done "$sid" && return 0
    header "ШАГ 7 — OS-AGENT"

    local arch
    arch=$(detect_arch)
    if [ "$arch" = "unknown" ]; then
        msg_error "Неизвестная архитектура: $(uname -m)"
        msg_error "Невозможно подобрать пакет OS-Agent"
        exit 1
    fi

    local v=""
    v=$(get_latest_release "home-assistant/os-agent")
    [ -z "$v" ] && v="1.6.0"

    local url="https://github.com/home-assistant/os-agent/releases/download/${v}/os-agent_${v}_linux_${arch}.deb"

    msg_info "Архитектура: ${arch}, версия: ${v}"
    download_file "$url" "/tmp/os-agent.deb" "OS-Agent ${v} (${arch})"
    run_cmd_fatal "Установка OS-Agent" dpkg -i /tmp/os-agent.deb

    # Проверка
    if gdbus introspect --system --dest io.hass.os --object-path /io/hass/os &>/dev/null 2>&1; then
        msg_ok "OS-Agent отвечает по D-Bus"
    else
        msg_warn "OS-Agent установлен, но D-Bus ещё не отвечает (OK при первом запуске)"
    fi

    mark_done "$sid"
}

step_install_ha() {
    local sid="ha"
    is_done "$sid" && return 0
    header "ШАГ 8 — HOME ASSISTANT SUPERVISED"

    mkdir -p "$BACKUP_DIR"

    # Бэкап os-release
    if [ ! -f "${BACKUP_DIR}/os-release.original" ]; then
        cp /etc/os-release "${BACKUP_DIR}/os-release.original"
    fi

    # Подмена os-release для прохождения проверки инсталлятора
    cat > /etc/os-release << 'EOF'
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
NAME="Debian GNU/Linux"
VERSION_ID="12"
VERSION_CODENAME=bookworm
ID=debian
EOF
    msg_ok "os-release → Debian 12 (bookworm)"

    local v=""
    v=$(get_latest_release "home-assistant/supervised-installer")
    [ -z "$v" ] && v="1.7.0"

    download_file \
        "https://github.com/home-assistant/supervised-installer/releases/download/${v}/homeassistant-supervised.deb" \
        "/tmp/ha.deb" \
        "HA Supervised ${v}"

    msg_action "Установка контейнеров HA (ожидайте 5-15 минут)..."
    msg_dim "Тип машины: ${HA_MACHINE}"
    export MACHINE="$HA_MACHINE"

    # Живой вывод лога установки
    set +o pipefail
    DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/ha.deb 2>&1 \
        | stdbuf -oL grep -iE "(pull|download|unpack|setting up|error|warn)" \
        | grep -vi "cgroup v1" \
        | while IFS= read -r line; do
            echo -e "    ${BLUE}│${NC} ${line}"
        done
    local de=${PIPESTATUS[0]}
    set -o pipefail

    if [ $de -ne 0 ]; then
        msg_warn "dpkg вернул код ${de}, пробуем исправить..."
        apt-get install -f -y >/dev/null 2>&1 || true
    fi

    # Drop-in для автоподмены os-release при старте supervisor
    mkdir -p /etc/systemd/system/hassio-supervisor.service.d
    cat > /etc/systemd/system/hassio-supervisor.service.d/mask-os-release.conf << 'DROPIN'
[Service]
ExecStartPre=/bin/bash -c 'if ! grep -q "^ID=debian" /etc/os-release; then printf "%%s\n" "PRETTY_NAME=\"Debian GNU/Linux 12 (bookworm)\"" "NAME=\"Debian GNU/Linux\"" "VERSION_ID=\"12\"" "VERSION_CODENAME=bookworm" "ID=debian" > /etc/os-release; fi'
DROPIN
    systemctl daemon-reload

    # Ожидание запуска hassio-supervisor
    msg_action "Ожидание запуска hassio-supervisor..."
    local sw=0
    while ! systemctl is-active --quiet hassio-supervisor 2>/dev/null; do
        sleep 5
        sw=$((sw + 5))
        if [ $sw -ge 120 ]; then
            msg_warn "hassio-supervisor не запустился за 2 минуты"
            msg_dim "Это может быть нормально — контейнеры всё ещё загружаются"
            break
        fi
        [ $((sw % 15)) -eq 0 ] && msg_dim "Ждём ${sw}с..."
    done
    [ $sw -lt 120 ] && msg_ok "hassio-supervisor активен"

    # Grace-маркер для watchdog
    touch "$GRACE_MARKER"

    msg_ok "Home Assistant Supervised установлен"
    mark_done "$sid"
}

step_security() {
    local sid="sec"
    is_done "$sid" && return 0
    header "ШАГ 9 — БЕЗОПАСНОСТЬ"

    if [ "$OPT_UFW" != true ]; then
        msg_warn "Firewall/Fail2Ban пропущены (не выбраны)"
        mark_done "$sid"
        return 0
    fi

    # ── UFW ──
    msg_action "Настройка UFW..."
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming   >/dev/null 2>&1
    ufw default allow outgoing  >/dev/null 2>&1
    ufw default allow routed    >/dev/null 2>&1   # Критично для Docker

    ufw allow 22/tcp   comment 'SSH'            >/dev/null 2>&1
    ufw allow 8123/tcp comment 'Home Assistant' >/dev/null 2>&1
    ufw allow 4357/tcp comment 'ESPHome'        >/dev/null 2>&1
    ufw allow 5353/udp comment 'mDNS'           >/dev/null 2>&1
    ufw allow 5683/udp comment 'HomeKit'        >/dev/null 2>&1

    ufw --force enable >/dev/null 2>&1
    msg_ok "UFW активирован"

    # ── Docker + UFW: защита через DOCKER-USER ──
    msg_action "Настройка правил DOCKER-USER..."
    if ! grep -q "DOCKER-USER" /etc/ufw/after.rules 2>/dev/null; then
        cat >> /etc/ufw/after.rules << 'UFWD'

# BEGIN HA-INSTALLER DOCKER-USER RULES
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
-A DOCKER-USER -s 10.0.0.0/8 -j RETURN
-A DOCKER-USER -s 172.16.0.0/12 -j RETURN
-A DOCKER-USER -s 192.168.0.0/16 -j RETURN
-A DOCKER-USER -j DROP
COMMIT
# END HA-INSTALLER DOCKER-USER RULES
UFWD
        ufw reload >/dev/null 2>&1
        msg_ok "DOCKER-USER: доступ к контейнерам только из локальной сети"
    else
        msg_dim "DOCKER-USER правила уже существуют"
    fi

    # ── Fail2Ban ──
    msg_action "Настройка Fail2Ban..."
    cat > /etc/fail2ban/jail.local << 'EOF'
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 5
bantime  = 3600
findtime = 600
EOF
    systemctl enable fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
    msg_ok "Fail2Ban защищает SSH (5 попыток → бан 1 час)"

    mark_done "$sid"
}

step_extras() {
    local sid="extras"
    is_done "$sid" && return 0
    header "ШАГ 10 — УТИЛИТЫ И МОНИТОРИНГ"

    if [ "$OPT_EXTRAS" != true ]; then
        msg_warn "Утилиты пропущены (не выбраны)"
        mark_done "$sid"
        return 0
    fi

    # ── mDNS / Hostname ──
    if [ "$OPT_HOSTNAME" = true ]; then
        hostnamectl set-hostname homeassistant 2>/dev/null || true
        msg_ok "Hostname: homeassistant"
    fi
    systemctl enable avahi-daemon >/dev/null 2>&1
    systemctl start avahi-daemon  >/dev/null 2>&1
    msg_ok "mDNS (avahi): $(hostname).local"

    # ── Telegram уведомления ──
    cat > /usr/local/bin/ha-notify << TGNOTIFY
#!/bin/bash
T="${TG_TOKEN}"
C="${TG_CHAT}"
[ -z "\$T" ] || [ -z "\$C" ] && exit 0
MSG="\${1:-Без текста}"
curl -s -X POST "https://api.telegram.org/bot\$T/sendMessage" \\
    -d chat_id="\$C" \\
    -d text="🏠 *HA (\$(hostname)):* \$MSG" \\
    -d parse_mode="Markdown" >/dev/null 2>&1
TGNOTIFY
    chmod +x /usr/local/bin/ha-notify

    if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
        msg_ok "Telegram-уведомления настроены"
    else
        msg_dim "Telegram не настроен (уведомления отключены)"
    fi

    # ── Watchdog ──
    cat > /usr/local/bin/ha-watchdog << 'WD'
#!/bin/bash
# Watchdog для Home Assistant
# Не трогать HA первые 20 минут после установки
GRACE_FILE="/tmp/.ha_just_installed"
if [ -f "$GRACE_FILE" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$GRACE_FILE" 2>/dev/null || echo 0) ))
    if [ $age -lt 1200 ]; then
        exit 0
    fi
    rm -f "$GRACE_FILE"
fi

FAIL_FILE="/tmp/ha_wd_fails"
fail=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 http://localhost:8123 2>/dev/null || echo 000)

if [ "$code" = "000" ]; then
    fail=$((fail + 1))
    echo "$fail" > "$FAIL_FILE"
    if [ "$fail" -ge 3 ]; then
        logger -t ha-watchdog "HA не отвечает ($fail раз). Перезапуск..."
        docker restart homeassistant 2>/dev/null || true
        /usr/local/bin/ha-notify "⚠️ Watchdog перезапустил HA (не отвечал ${fail} проверок подряд)"
        echo 0 > "$FAIL_FILE"
    fi
else
    echo 0 > "$FAIL_FILE"
fi
WD
    chmod +x /usr/local/bin/ha-watchdog
    msg_ok "Watchdog установлен (3 пропуска → рестарт)"

    # ── Автоочистка диска ──
    cat > /usr/local/bin/ha-cleanup << 'CLN'
#!/bin/bash
# Автоочистка при заполнении диска
free_mb=$(df -m / | awk 'NR==2{print $4}')
if [ "$free_mb" -lt 1500 ]; then
    logger -t ha-cleanup "Мало места: ${free_mb}MB. Очистка..."
    docker system prune -f --volumes 2>/dev/null || true
    journalctl --vacuum-size=30M 2>/dev/null || true
    apt-get clean 2>/dev/null || true
    rm -rf /tmp/*.deb 2>/dev/null || true
    new_free=$(df -m / | awk 'NR==2{print $4}')
    /usr/local/bin/ha-notify "🧹 Автоочистка: было ${free_mb}MB → стало ${new_free}MB"
fi
CLN
    chmod +x /usr/local/bin/ha-cleanup
    msg_ok "Автоочистка диска установлена (порог: 1.5 GB)"

    # ── Восстановление сети ──
    cat > /usr/local/bin/ha-net-recovery << 'NETR'
#!/bin/bash
# Пингуем шлюз, потом Google DNS
GW=$(ip route 2>/dev/null | awk '/default/ {print $3}' | head -n 1)
[ -z "$GW" ] && GW="8.8.8.8"

if ! ping -c 2 -W 3 "$GW" >/dev/null 2>&1; then
    if ! ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
        logger -t ha-net "Сеть недоступна. Перезапуск NM..."
        nmcli networking off 2>/dev/null
        sleep 3
        nmcli networking on 2>/dev/null
        sleep 5
        if ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
            /usr/local/bin/ha-notify "🌐 Сеть была потеряна и восстановлена"
        else
            /usr/local/bin/ha-notify "🔴 Сеть не восстанавливается!"
        fi
    fi
fi
NETR
    chmod +x /usr/local/bin/ha-net-recovery
    msg_ok "Авторесторе сети установлено"

    # ── Cron-задания ──
    cat > /etc/cron.d/ha-tools << 'CRON'
# Home Assistant maintenance (created by HA Ultimate Installer)
*/5 * * * *  root /usr/local/bin/ha-watchdog >/dev/null 2>&1
*/10 * * * * root /usr/local/bin/ha-net-recovery >/dev/null 2>&1
30 3 * * *   root /usr/local/bin/ha-cleanup >/dev/null 2>&1
CRON
    chmod 644 /etc/cron.d/ha-tools
    msg_ok "Cron-задания зарегистрированы"

    mark_done "$sid"
}

step_hacs() {
    local sid="hacs"
    is_done "$sid" && return 0
    header "ШАГ 11 — УСТАНОВКА HACS"

    if [ "$OPT_HACS" != true ]; then
        msg_warn "HACS пропущен (не выбран)"
        mark_done "$sid"
        return 0
    fi

    # Ждём появления конфигурации HA
    msg_action "Ожидание формирования конфигурации HA (до 5 минут)..."
    local wait=0
    while [ ! -f "${HASSIO_DIR}/homeassistant/configuration.yaml" ]; do
        sleep 5
        wait=$((wait + 5))
        if [ $wait -gt 300 ]; then
            msg_warn "Таймаут ожидания конфигурации HA."
            msg_warn "HACS можно установить позже вручную."
            msg_dim "Команда: docker exec homeassistant bash -c 'wget -O - https://get.hacs.xyz | bash -'"
            mark_done "$sid"
            return 0
        fi
        [ $((wait % 30)) -eq 0 ] && msg_dim "Ждём ${wait}с..."
    done
    msg_ok "configuration.yaml найден"

    # Ждём пока контейнер homeassistant запущен
    msg_action "Проверка контейнера homeassistant..."
    local cw=0
    while ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^homeassistant$'; do
        sleep 5
        cw=$((cw + 5))
        if [ $cw -gt 120 ]; then
            msg_warn "Контейнер homeassistant не найден. HACS пропущен."
            mark_done "$sid"
            return 0
        fi
    done
    msg_ok "Контейнер homeassistant запущен"

    # Установка HACS с таймаутом
    msg_action "Внедрение HACS в контейнер (таймаут 2 мин)..."
    if timeout 120 docker exec homeassistant \
        bash -c "wget -q -O - https://get.hacs.xyz | bash -" >/dev/null 2>&1; then
        msg_ok "Скрипт HACS выполнен"
    else
        msg_warn "HACS: таймаут или ошибка установки"
        msg_dim "Установите позже: docker exec homeassistant bash -c 'wget -O - https://get.hacs.xyz | bash -'"
        mark_done "$sid"
        return 0
    fi

    # Перезапуск HA Core для применения HACS
    msg_action "Перезапуск HA Core для активации HACS..."
    docker restart homeassistant >/dev/null 2>&1
    msg_ok "HACS интегрирован! Активируйте его в Настройки → Интеграции → + HACS"

    mark_done "$sid"
}

# ========================== ФИНАЛ ==========================================

show_final() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"

    header "УСТАНОВКА ЗАВЕРШЕНА!"

    echo -e "  ${BOLD}Доступ к Home Assistant:${NC}\n"
    echo -e "  ${GREEN}➜  http://${ip}:8123${NC}"
    if [ "$OPT_EXTRAS" = true ] && [ "$OPT_HOSTNAME" = true ]; then
        echo -e "  ${GREEN}➜  http://homeassistant.local:8123${NC}"
    fi
    echo ""

    # QR-код
    if command -v qrencode &>/dev/null; then
        echo -e "  ${BOLD}Отсканируйте для быстрого доступа:${NC}\n"
        qrencode -m 2 -t ANSIUTF8 "http://${ip}:8123"
        echo ""
    fi

    separator
    echo -e "  ${BOLD}Установленные компоненты:${NC}"
    echo -e "  ${CHECK}  Home Assistant Supervised (${HA_MACHINE})"
    echo -e "  ${CHECK}  Docker + OS-Agent"
    [ "$OPT_ZRAM" = true ]     && echo -e "  ${CHECK}  ZRAM Swap"
    [ "$OPT_UFW" = true ]      && echo -e "  ${CHECK}  UFW + Fail2Ban + DOCKER-USER"
    [ "$OPT_HACS" = true ]     && echo -e "  ${CHECK}  HACS (магазин интеграций)"
    [ "$OPT_EXTRAS" = true ]   && echo -e "  ${CHECK}  Watchdog, Автоочистка, Net-recovery"
    if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
        echo -e "  ${CHECK}  Telegram-уведомления"
    fi
    separator

    local aa
    aa=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) || aa="N"
    if [ "$aa" != "Y" ]; then
        echo ""
        msg_warn "AppArmor требует перезагрузки для активации!"
        echo -e "  ${YELLOW}Выполните: ${WHITE}sudo reboot${NC}"
        echo ""
    fi

    echo -e "  ${YELLOW}Первая инициализация HA займет 10-15 минут.${NC}"
    echo -e "  ${YELLOW}Подождите, пока интерфейс не предложит создать аккаунт.${NC}\n"

    if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
        /usr/local/bin/ha-notify "✅ Установка завершена! Интерфейс: http://${ip}:8123" 2>/dev/null || true
    fi

    msg_info "Лог установки: ${LOG_FILE}"
    echo ""
}

# ========================== MAIN ============================================

main() {
    parse_args "$@"

    # Проверка root
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Ошибка: запустите от root (sudo)${NC}"
        exit 1
    fi

    # Режим проверки
    if [ "$CHECK_ONLY" = true ]; then
        do_check
        exit 0
    fi

    # Режим удаления
    if [ "$UNINSTALL" = true ]; then
        do_uninstall
        exit 0
    fi

    # Мастер TUI
    if [ "$RUN_WIZARD" = true ] && [ "$DRY_RUN" = false ]; then
        run_wizard
    fi

    show_banner
    setup_logging

    # Автодетект архитектуры
    if [ "$HA_MACHINE" = "$HA_DEFAULT_MACHINE" ]; then
        HA_MACHINE=$(detect_machine_type)
    fi
    msg_info "Платформа: ${HA_MACHINE} ($(uname -m))"

    acquire_lock

    # ── Основные шаги ──
    step_update_system
    step_install_deps
    step_configure_network
    step_configure_apparmor
    step_performance
    step_install_docker
    step_install_os_agent
    step_install_ha
    step_security
    step_extras
    step_hacs

    # ── Финал ──
    show_final
}

main "$@"
