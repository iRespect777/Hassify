#!/bin/bash

# ============================================================================
#
#  Home Assistant Supervised — установка на X96Q (Armbian Bookworm / aarch64)
#
#  Версия:    4.1 (финальная)
#  Платформа: X96Q (Allwinner H616/H313), Armbian Bookworm, aarch64
#
#  Использование:
#    sudo bash install_ha.sh [опции]
#    sudo bash install_ha.sh --help
#
# ============================================================================

readonly HA_DEFAULT_MACHINE="qemuarm-64"
readonly STATE_FILE="/root/.ha_install_state"
readonly LOCK_FILE="/var/lock/ha_install.lock"
readonly BACKUP_DIR="/root/.ha_install_backup"
readonly LOG_DIR="/var/log"
readonly HASSIO_DIR="/usr/share/hassio"
readonly SCRIPT_VERSION="4.1"

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

# ========================== ФЛАГИ ===========================================

SKIP_SWAP=false
SKIP_UPDATE=false
SKIP_OPTIMIZE=false
SKIP_EXTRAS=false
CHECK_ONLY=false
UNINSTALL=false
DRY_RUN=false
NO_WAIT=false
SWAP_SIZE=""
HA_MACHINE="$HA_DEFAULT_MACHINE"
LOG_FILE=""
NEED_REBOOT=false
INSTALL_START_TIME=""

# ========================== ВЫВОД ===========================================

header() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    printf "${BLUE}║${WHITE}${BOLD}  %-58s${NC}${BLUE}║${NC}\n" "$1"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

separator()  { echo -e "${DIM}  ────────────────────────────────────────────────────────────${NC}"; }
msg_info()   { echo -e " ${INFO}  ${WHITE}$1${NC}"; }
msg_ok()     { echo -e " ${CHECK}  ${GREEN}$1${NC}"; }
msg_warn()   { echo -e " ${WARN}  ${YELLOW}$1${NC}"; }
msg_error()  { echo -e " ${CROSS}  ${RED}$1${NC}"; }
msg_action() { echo -e " ${ARROW}  ${CYAN}$1${NC}"; }
msg_dim()    { echo -e "       ${DIM}$1${NC}"; }

# ========================== ЛОГИРОВАНИЕ =====================================

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

# ========================== LOCK / STATE / CLEANUP ==========================

acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid=""
        pid=$(cat "$LOCK_FILE" 2>/dev/null) || true
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            msg_error "Скрипт уже запущен (PID: ${pid})"
            msg_info "Если ошибочно: rm -f ${LOCK_FILE}"
            exit 1
        fi
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
}

release_lock() { rm -f "$LOCK_FILE" 2>/dev/null || true; }
mark_done()    { echo "$1" >> "$STATE_FILE"; }
is_done()      { [ -f "$STATE_FILE" ] && grep -qx "$1" "$STATE_FILE" 2>/dev/null; }
reset_state()  { rm -f "$STATE_FILE"; msg_ok "Прогресс сброшен"; }

cleanup() {
    local exit_code=$?
    rm -f /tmp/os-agent*.deb /tmp/homeassistant-supervised*.deb \
          /tmp/ha_step_*.log /tmp/ha_dpkg_*.log 2>/dev/null || true
    release_lock
    flush_log 2>/dev/null || true

    if [ $exit_code -ne 0 ] && [ $exit_code -ne 130 ]; then
        echo ""
        echo -e " ${CROSS:-✘}  ${RED:-}Установка прервана (код: ${exit_code})${NC:-}"
        echo -e " ${INFO:-ℹ}  Повторный запуск продолжит с места остановки"
        [ -n "${LOG_FILE:-}" ] && echo -e " ${INFO:-ℹ}  Лог: ${LOG_FILE}"
    elif [ $exit_code -eq 130 ]; then
        echo ""
        echo -e " ${WARN:-⚠}  ${YELLOW:-}Прервано (Ctrl+C)${NC:-}"
    fi
}

trap cleanup EXIT INT TERM

# ========================== ВЫПОЛНЕНИЕ КОМАНД ===============================

run_cmd() {
    local description="$1"; shift
    local log_file
    log_file=$(mktemp /tmp/ha_step_XXXXXX.log)

    msg_action "${description}..."

    if [ "$DRY_RUN" = true ]; then
        msg_dim "[dry-run] $*"
        rm -f "$log_file"; return 0
    fi

    if "$@" > "$log_file" 2>&1; then
        msg_ok "$description"
        rm -f "$log_file"; return 0
    else
        local code=$?
        msg_error "${description} — ОШИБКА (код: ${code})"
        msg_warn "Лог: ${log_file}"
        tail -15 "$log_file" 2>/dev/null | while IFS= read -r l; do
            echo -e "    ${RED}│${NC} ${l}"
        done
        return $code
    fi
}

run_cmd_fatal() {
    if ! run_cmd "$@"; then
        msg_error "Критическая ошибка — остановка"; exit 1
    fi
}

# ========================== СКАЧИВАНИЕ ======================================

download_file() {
    local url="$1" output="$2" description="$3" max_retries="${4:-3}"
    local attempt=1

    if [ "$DRY_RUN" = true ]; then
        msg_action "${description}..."
        msg_dim "[dry-run] wget -O ${output} ${url}"
        return 0
    fi

    while [ $attempt -le $max_retries ]; do
        [ $attempt -gt 1 ] && msg_warn "Попытка ${attempt}/${max_retries}..." && sleep $((attempt * 3))
        msg_action "${description}..."
        rm -f "$output" 2>/dev/null || true

        if wget -q --timeout=60 --tries=1 -O "$output" "$url" 2>/dev/null; then
            if [ -s "$output" ]; then
                if [[ "$output" == *.deb ]]; then
                    if dpkg-deb --info "$output" &>/dev/null; then
                        msg_ok "${description}"; return 0
                    fi
                    msg_warn "Файл .deb повреждён"
                else
                    msg_ok "${description}"; return 0
                fi
            else
                msg_warn "Пустой файл"
            fi
        else
            msg_warn "Загрузка не удалась"
        fi

        rm -f "$output" 2>/dev/null || true
        attempt=$((attempt + 1))
    done

    msg_error "${description} — не удалось за ${max_retries} попыток"
    return 1
}

get_latest_release() {
    local repo="$1" result=""
    result=$(curl -fsSL --timeout 15 \
        "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null) || true
    echo "$result"
}

# ========================== АВТООПРЕДЕЛЕНИЕ МАШИНЫ ==========================

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
                *ODROID-C2*)       echo "odroid-c2" ;;
                *Khadas*VIM3*)     echo "khadas-vim3" ;;
                *Tinker*)          echo "tinker" ;;
                *)                 echo "qemuarm-64" ;;
            esac ;;
        armv7l) echo "qemuarm" ;;
        *)      echo "qemuarm-64" ;;
    esac
}

# ========================== АРГУМЕНТЫ ======================================

usage() {
    cat << EOF

${WHITE}${BOLD}Home Assistant Supervised — установщик v${SCRIPT_VERSION}${NC}
${WHITE}Платформа: X96Q / Armbian Bookworm / aarch64${NC}

${WHITE}Использование:${NC}  sudo bash $0 [опции]

${WHITE}Основные:${NC}
  ${CYAN}-h, --help${NC}              Справка
  ${CYAN}-c, --check${NC}             Только проверки
  ${CYAN}-u, --uninstall${NC}         Удаление HA

${WHITE}Установка:${NC}
  ${CYAN}--skip-swap${NC}             Без swap
  ${CYAN}--skip-update${NC}           Без apt upgrade
  ${CYAN}--skip-optimize${NC}         Без оптимизации eMMC
  ${CYAN}--skip-extras${NC}           Без доп. настроек (watchdog, mDNS, Telegram)
  ${CYAN}--swap-size МБ${NC}          Размер swap
  ${CYAN}--machine ТИП${NC}           Машина HA (по умолч.: авто)
  ${CYAN}--no-wait${NC}               Не ждать запуска HA

${WHITE}Отладка:${NC}
  ${CYAN}--dry-run${NC}               Предпросмотр
  ${CYAN}--log ФАЙЛ${NC}             Путь к логу
  ${CYAN}--reset-state${NC}           Сброс прогресса

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)         usage; exit 0 ;;
            -c|--check)        CHECK_ONLY=true ;;
            -u|--uninstall)    UNINSTALL=true ;;
            --reset-state)     reset_state; exit 0 ;;
            --skip-swap)       SKIP_SWAP=true ;;
            --skip-update)     SKIP_UPDATE=true ;;
            --skip-optimize)   SKIP_OPTIMIZE=true ;;
            --skip-extras)     SKIP_EXTRAS=true ;;
            --dry-run)         DRY_RUN=true ;;
            --no-wait)         NO_WAIT=true ;;
            --swap-size)
                [ -z "${2:-}" ] && msg_error "--swap-size: нужно значение" && exit 1
                SWAP_SIZE="$2"; shift ;;
            --machine)
                [ -z "${2:-}" ] && msg_error "--machine: нужно значение" && exit 1
                HA_MACHINE="$2"; shift ;;
            --log)
                [ -z "${2:-}" ] && msg_error "--log: нужен путь" && exit 1
                LOG_FILE="$2"; shift ;;
            *)
                msg_error "Неизвестный аргумент: $1"
                msg_info "Справка: --help"; exit 1 ;;
        esac
        shift
    done
}

# ========================== БАННЕР ==========================================

show_banner() {
    clear
    echo -e "${BLUE}"
    cat << 'BANNER'
    ╦ ╦┌─┐┌┬┐┌─┐  ╔═╗┌─┐┌─┐┬┌─┐┌┬┐┌─┐┌┐┌┌┬┐
    ╠═╣│ ││││├┤   ╠═╣└─┐└─┐│└─┐ │ ├─┤│││ │
    ╩ ╩└─┘┴ ┴└─┘  ╩ ╩└─┘└─┘┴└─┘ ┴ ┴ ┴┘└┘ ┴
    ╔═╗┬ ┬┌─┐┌─┐┬─┐┬  ┬┬┌─┐┌─┐┌┬┐
    ╚═╗│ │├─┘├┤ ├┬┘└┐┌┘│└─┐├┤  ││
    ╚═╝└─┘┴  └─┘┴└─ └┘ ┴└─┘└─┘─┴┘
BANNER
    echo -e "${NC}"
    echo -e "${WHITE}${BOLD}    Установщик v${SCRIPT_VERSION} / X96Q / Armbian Bookworm${NC}"
    echo -e "${CYAN}    ───────────────────────────────────────────────────${NC}"
    echo ""

    local model=""
    model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null) || model="Unknown"

    echo -e "    ${GEAR}  Устройство:   ${WHITE}${model}${NC}"
    echo -e "    ${GEAR}  Ядро:         ${WHITE}$(uname -r)${NC}"
    echo -e "    ${GEAR}  ОС:           ${WHITE}$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Unknown}")${NC}"
    echo -e "    ${GEAR}  RAM:          ${WHITE}$(free -h | awk '/^Mem:/{print $2}')${NC}"
    echo -e "    ${GEAR}  Диск /:       ${WHITE}$(df -h / | awk 'NR==2{print $2 " (свободно: " $4 ")"}')${NC}"

    local tf=""
    tf=$(find /sys/class/thermal -name "temp" -path "*/thermal_zone0/*" 2>/dev/null | head -1)
    [ -n "$tf" ] && echo -e "    ${GEAR}  Температура:  ${WHITE}$(( $(cat "$tf") / 1000 ))°C${NC}"

    echo ""
    [ "$DRY_RUN" = true ] && echo -e "    ${WARN}  ${YELLOW}${BOLD}РЕЖИМ DRY-RUN${NC}" && echo ""

    if [ -f "$STATE_FILE" ]; then
        echo -e "    ${INFO}  Прогресс: ${WHITE}$(wc -l < "$STATE_FILE") шагов${NC} ранее"
        echo -e "    ${DIM}    Сброс: $0 --reset-state${NC}"
        echo ""
    fi
}

# ========================== ПОДСТРАХОВКА ====================================

ensure_services() {
    [ "$DRY_RUN" = true ] && return 0

    if is_done "configure_network"; then
        if ! systemctl is-active --quiet NetworkManager 2>/dev/null; then
            msg_warn "NetworkManager не активен — запускаем..."
            systemctl enable NetworkManager 2>/dev/null || true
            systemctl start NetworkManager 2>/dev/null || true
            sleep 3
            systemctl is-active --quiet NetworkManager 2>/dev/null \
                && msg_ok "NetworkManager запущен" \
                || msg_warn "Не удалось запустить NetworkManager"
        fi
        if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            systemctl enable systemd-resolved 2>/dev/null || true
            systemctl start systemd-resolved 2>/dev/null || true
        fi
    fi
}

# ========================== ПРОВЕРКИ ========================================

preflight_checks() {
    header "ПРОВЕРКИ СОВМЕСТИМОСТИ"
    local errors=0

    msg_ok "Запуск от root"

    local arch; arch=$(uname -m)
    [ "$arch" != "aarch64" ] \
        && { msg_error "Архитектура: ${arch} (нужна aarch64)"; errors=$((errors+1)); } \
        || msg_ok "Архитектура: ${arch}"

    local init_name=""
    init_name=$(ps -p 1 -o comm= 2>/dev/null) || init_name="unknown"
    [ "$init_name" != "systemd" ] \
        && { msg_error "Init: ${init_name} (нужен systemd)"; errors=$((errors+1)); } \
        || msg_ok "Init: systemd"

    local kmaj=0; kmaj=$(uname -r | cut -d. -f1) || true
    [ "$kmaj" -lt 5 ] 2>/dev/null \
        && { msg_error "Ядро $(uname -r) — нужно ≥5.x"; errors=$((errors+1)); } \
        || msg_ok "Ядро: $(uname -r)"

    if [ -f /etc/os-release ]; then
        local codename=""
        codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
        [ "$codename" != "bookworm" ] \
            && { msg_error "Нужен bookworm: ${codename:-unknown}"; errors=$((errors+1)); } \
            || msg_ok "Кодовое имя: ${codename}"
    else
        msg_error "/etc/os-release не найден"; errors=$((errors+1))
    fi

    if ping -c 1 -W 5 github.com &>/dev/null; then
        msg_ok "Интернет: доступен"
    elif ping -c 1 -W 5 8.8.8.8 &>/dev/null; then
        msg_warn "IP доступен, DNS может не работать"
    else
        msg_error "Нет интернета"; errors=$((errors+1))
    fi

    local disk_free=0; disk_free=$(df -m / | awk 'NR==2{print $4}') || true
    [ "$disk_free" -lt 4000 ] 2>/dev/null \
        && { msg_error "Место: ${disk_free} МБ (нужно ≥4 ГБ)"; errors=$((errors+1)); } \
        || msg_ok "Свободно: ${disk_free} МБ"

    local ram_mb=0; ram_mb=$(free -m | awk '/^Mem:/{print $2}') || true
    if [ "$ram_mb" -lt 700 ] 2>/dev/null; then
        msg_error "RAM: ${ram_mb} МБ (нужно ≥768)"; errors=$((errors+1))
    elif [ "$ram_mb" -lt 1500 ]; then
        msg_warn "RAM: ${ram_mb} МБ — swap обязателен"
    else
        msg_ok "RAM: ${ram_mb} МБ"
    fi

    separator

    local cg=""; cg=$(stat -fc %T /sys/fs/cgroup/ 2>/dev/null) || cg="unknown"
    case "$cg" in
        cgroup2fs) msg_ok  "cgroup: v2" ;;
        tmpfs)     msg_warn "cgroup: v1 (рекомендуется v2)" ;;
        *)         msg_warn "cgroup: ${cg}" ;;
    esac

    for mod in overlay br_netfilter; do
        if modinfo "$mod" &>/dev/null; then msg_ok "Модуль: ${mod}"
        elif grep -q "^${mod} " /proc/modules 2>/dev/null; then msg_ok "Модуль: ${mod} (загружен)"
        elif [ -d "/sys/module/${mod}" ]; then msg_ok "Модуль: ${mod} (встроен)"
        else msg_warn "Модуль ${mod} не найден"; fi
    done

    for svc in podman lxc lxd snapd; do
        systemctl is-active --quiet "$svc" 2>/dev/null && msg_warn "Конфликт: ${svc}"
    done

    command -v ss &>/dev/null && ss -tlnp 2>/dev/null | grep -q ":8123 " && msg_warn "Порт 8123 занят"

    if command -v docker &>/dev/null && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^homeassistant$"; then
        msg_warn "HA уже установлен"
        if [ "$CHECK_ONLY" = false ]; then
            echo ""
            read -r -p "  Продолжить поверх? [y/N]: " ans
            [[ ! "${ans:-}" =~ ^[Yy]$ ]] && exit 0
        fi
    fi

    echo ""
    [ $errors -gt 0 ] && { msg_error "Критических ошибок: ${errors}"; exit 1; }
    msg_ok "Все проверки пройдены"
}

# ========================== ШАГ 1: ОБНОВЛЕНИЕ ===============================

step_update_system() {
    local sid="update_system"
    if is_done "$sid"; then msg_ok "[1/11] Обновление — пропуск"; return 0; fi
    header "ШАГ 1/11 — ОБНОВЛЕНИЕ СИСТЕМЫ"
    if [ "$SKIP_UPDATE" = true ]; then msg_warn "Пропущено"; mark_done "$sid"; return 0; fi

    run_cmd_fatal "apt-get update" apt-get update -y
    run_cmd "apt-get upgrade" apt-get upgrade -y
    run_cmd "apt-get autoremove" apt-get autoremove -y
    msg_ok "Система обновлена"
    mark_done "$sid"
}

# ========================== ШАГ 2: ЗАВИСИМОСТИ ==============================

step_install_deps() {
    local sid="install_deps"
    if is_done "$sid"; then msg_ok "[2/11] Зависимости — пропуск"; return 0; fi
    header "ШАГ 2/11 — ЗАВИСИМОСТИ"

    local pkgs=(
        apparmor avahi-daemon bluez ca-certificates cifs-utils curl dbus
        gnupg jq libglib2.0-bin lsb-release network-manager nfs-common
        software-properties-common systemd-journal-remote
        systemd-resolved systemd-timesyncd udisks2 usbutils wget
    )
    msg_info "Пакетов: ${#pkgs[@]}"
    echo ""

    local failed=0
    for p in "${pkgs[@]}"; do
        if dpkg -l "$p" 2>/dev/null | grep -q "^ii"; then msg_ok "$p"
        else run_cmd "Установка $p" apt-get install -y "$p" || failed=$((failed+1)); fi
    done

    [ $failed -gt 0 ] && msg_warn "Ошибок: ${failed}" && run_cmd "apt-get -f install" apt-get install -f -y
    msg_ok "Зависимости установлены"
    mark_done "$sid"
}

# ========================== ШАГ 3: СЕТЬ ====================================

step_configure_network() {
    local sid="configure_network"
    if is_done "$sid"; then msg_ok "[3/11] Сеть — пропуск"; return 0; fi
    header "ШАГ 3/11 — СЕТЬ"

    mkdir -p "$BACKUP_DIR"

    msg_action "Конфигурация NetworkManager..."
    if [ "$DRY_RUN" = false ]; then
        mkdir -p /etc/NetworkManager/conf.d
        cat > /etc/NetworkManager/conf.d/10-ha-managed.conf << 'EOF'
[keyfile]
unmanaged-devices=none

[device]
wifi.scan-rand-mac-address=no
EOF
    fi
    msg_ok "Конфигурация NM создана"

    cp /etc/network/interfaces "$BACKUP_DIR/interfaces.bak" 2>/dev/null || true
    if [ "$DRY_RUN" = false ]; then
        cat > /etc/network/interfaces << 'EOF'
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback
EOF
    fi
    msg_ok "interfaces обновлён"

    if [ "$DRY_RUN" = false ]; then
        systemctl enable systemd-resolved 2>/dev/null || true
        systemctl start systemd-resolved 2>/dev/null || true
        local resolv_target="/run/systemd/resolve/resolv.conf"
        if [ -e "$resolv_target" ]; then
            local cur_link=""
            cur_link=$(readlink -f /etc/resolv.conf 2>/dev/null) || true
            if [ "$cur_link" != "$resolv_target" ]; then
                cp /etc/resolv.conf "$BACKUP_DIR/resolv.conf.bak" 2>/dev/null || true
                ln -sf "$resolv_target" /etc/resolv.conf
            fi
        fi
        msg_ok "systemd-resolved включён"
    fi

    mark_done "$sid"

    if [ "$DRY_RUN" = false ]; then
        msg_warn "Переключение на NetworkManager (возможен обрыв SSH)..."
        systemctl disable networking 2>/dev/null || true
        systemctl enable NetworkManager 2>/dev/null || true
        systemctl restart NetworkManager 2>/dev/null || true
        msg_ok "NetworkManager активен"
        sleep 3
        ping -c 1 -W 5 github.com &>/dev/null && msg_ok "Сеть работает" || msg_warn "Сеть может потребовать перезагрузки"
    fi
}

# ========================== ШАГ 4: APPARMOR =================================

step_configure_apparmor() {
    local sid="configure_apparmor"
    if is_done "$sid"; then msg_ok "[4/11] AppArmor — пропуск"; return 0; fi
    header "ШАГ 4/11 — APPARMOR"

    local aa=""; aa=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) || aa="N"

    if [ "$aa" = "Y" ]; then
        msg_ok "AppArmor активен"
    else
        msg_warn "AppArmor не активен — настройка загрузчика"
        local bootenv="/boot/armbianEnv.txt"

        if [ -f "$bootenv" ]; then
            mkdir -p "$BACKUP_DIR"
            cp "$bootenv" "$BACKUP_DIR/armbianEnv.txt.bak" 2>/dev/null || true
            if [ "$DRY_RUN" = false ]; then
                if grep -q "^extraargs=" "$bootenv"; then
                    local cur=""; cur=$(grep "^extraargs=" "$bootenv" | cut -d'=' -f2-)
                    if ! echo "$cur" | grep -q "apparmor=1"; then
                        sed -i "s|^extraargs=.*|extraargs=${cur} apparmor=1 security=apparmor|" "$bootenv"
                        msg_ok "AppArmor добавлен"
                    else msg_ok "AppArmor уже есть"; fi
                else
                    echo "extraargs=apparmor=1 security=apparmor" >> "$bootenv"
                    msg_ok "extraargs создан"
                fi
            else msg_dim "[dry-run] apparmor=1 security=apparmor → ${bootenv}"; fi
        else msg_warn "${bootenv} не найден — добавьте вручную"; fi

        NEED_REBOOT=true
        msg_warn "Перезагрузка нужна для активации AppArmor"
    fi

    if [ "$DRY_RUN" = false ]; then
        systemctl enable apparmor 2>/dev/null || true
        systemctl start apparmor 2>/dev/null || true
    fi
    msg_ok "Служба AppArmor включена"
    mark_done "$sid"
}

# ========================== ШАГ 5: SWAP =====================================

step_configure_swap() {
    local sid="configure_swap"
    if is_done "$sid"; then msg_ok "[5/11] Swap — пропуск"; return 0; fi
    header "ШАГ 5/11 — SWAP"

    if [ "$SKIP_SWAP" = true ]; then msg_warn "Пропущено"; mark_done "$sid"; return 0; fi

    local ram_mb=0 swap_now=0
    ram_mb=$(free -m | awk '/^Mem:/{print $2}') || true
    swap_now=$(free -m | awk '/^Swap:/{print $2}') || true
    msg_info "RAM: ${ram_mb} МБ | Swap: ${swap_now} МБ"

    if [ "$swap_now" -ge 1024 ] 2>/dev/null; then
        msg_ok "Swap достаточен"; mark_done "$sid"; return 0
    fi

    local swap_mb
    if [ -n "$SWAP_SIZE" ]; then swap_mb="$SWAP_SIZE"
    elif [ "$ram_mb" -lt 1500 ] 2>/dev/null; then swap_mb=3072
    else swap_mb=2048; fi

    msg_action "Создание swap: ${swap_mb} МБ..."
    if [ "$DRY_RUN" = true ]; then msg_dim "[dry-run]"; mark_done "$sid"; return 0; fi

    [ -f /swapfile ] && { swapoff /swapfile 2>/dev/null || true; rm -f /swapfile; }

    if ! dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb" status=progress 2>&1 | tail -1; then
        msg_error "dd не удался"; rm -f /swapfile 2>/dev/null || true; mark_done "$sid"; return 0
    fi
    chmod 600 /swapfile
    if ! mkswap /swapfile >/dev/null 2>&1; then msg_error "mkswap"; rm -f /swapfile; mark_done "$sid"; return 0; fi
    if ! swapon /swapfile 2>/dev/null; then msg_error "swapon"; rm -f /swapfile; mark_done "$sid"; return 0; fi

    grep -q "/swapfile" /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab

    cat > /etc/sysctl.d/99-ha-swap.conf << 'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
    sysctl -p /etc/sysctl.d/99-ha-swap.conf >/dev/null 2>&1 || true
    msg_ok "Swap: $(free -m | awk '/^Swap:/{print $2}') МБ"
    mark_done "$sid"
}

# ========================== ШАГ 6: DOCKER ===================================

step_install_docker() {
    local sid="install_docker"
    if is_done "$sid"; then msg_ok "[6/11] Docker — пропуск"; return 0; fi
    header "ШАГ 6/11 — DOCKER"

    if command -v docker &>/dev/null && docker ps &>/dev/null; then
        msg_ok "Docker: $(docker --version | awk '{print $3}' | tr -d ',')"
        systemctl enable docker 2>/dev/null || true
        mark_done "$sid"; return 0
    fi

    [ "$DRY_RUN" = false ] && { apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true; }
    run_cmd_fatal "Установка Docker" bash -c "curl -fsSL https://get.docker.com | sh"
    if [ "$DRY_RUN" = true ]; then mark_done "$sid"; return 0; fi

    systemctl enable docker 2>/dev/null || true
    systemctl start docker 2>/dev/null || true

    local i=0
    while ! docker ps &>/dev/null; do
        sleep 2; i=$((i+1))
        [ $i -ge 20 ] && { msg_error "Docker не запустился"; exit 1; }
    done

    mkdir -p /etc/docker
    if [ ! -f /etc/docker/daemon.json ]; then
        cat > /etc/docker/daemon.json << 'EOF'
{
    "log-driver": "journald",
    "storage-driver": "overlay2"
}
EOF
        systemctl restart docker; sleep 3
    fi

    msg_ok "Docker: $(docker --version | awk '{print $3}' | tr -d ',')"
    docker run --rm hello-world &>/dev/null && { msg_ok "Тест OK"; docker rmi hello-world 2>/dev/null || true; }
    mark_done "$sid"
}

# ========================== ШАГ 7: OS-AGENT =================================

step_install_os_agent() {
    local sid="install_os_agent"
    if is_done "$sid"; then msg_ok "[7/11] OS-Agent — пропуск"; return 0; fi
    header "ШАГ 7/11 — OS-AGENT"

    if gdbus introspect --system --dest io.hass.os --object-path /io/hass/os &>/dev/null; then
        msg_ok "OS-Agent работает"; mark_done "$sid"; return 0
    fi

    local version=""; version=$(get_latest_release "home-assistant/os-agent")
    [ -z "$version" ] && { version="1.6.0"; msg_warn "API недоступен → v${version}"; } || msg_ok "Версия: ${version}"

    local url="https://github.com/home-assistant/os-agent/releases/download/${version}/os-agent_${version}_linux_aarch64.deb"
    local deb="/tmp/os-agent_${version}.deb"
    download_file "$url" "$deb" "Скачивание OS-Agent ${version}" || exit 1

    if [ "$DRY_RUN" = false ]; then
        run_cmd_fatal "Установка OS-Agent" dpkg -i "$deb"
        rm -f "$deb"
        sleep 2
        gdbus introspect --system --dest io.hass.os --object-path /io/hass/os &>/dev/null \
            && msg_ok "D-Bus OK" || msg_warn "D-Bus заработает после перезагрузки"
    fi
    mark_done "$sid"
}

# ========================== ШАГ 8: HA SUPERVISED ============================

step_install_ha_supervised() {
    local sid="install_ha_supervised"
    if is_done "$sid"; then msg_ok "[8/11] HA Supervised — пропуск"; return 0; fi
    header "ШАГ 8/11 — HOME ASSISTANT SUPERVISED"

    # Маскировка
    msg_action "Маскировка os-release → Debian 12..."
    mkdir -p "$BACKUP_DIR"
    [ ! -f "${BACKUP_DIR}/os-release.original" ] && cp /etc/os-release "${BACKUP_DIR}/os-release.original" && msg_ok "Оригинал сохранён"

    if [ "$DRY_RUN" = false ]; then
        cat > /etc/os-release << 'EOF'
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
NAME="Debian GNU/Linux"
VERSION_ID="12"
VERSION="12 (bookworm)"
VERSION_CODENAME=bookworm
ID=debian
HOME_URL="https://www.debian.org/"
SUPPORT_URL="https://www.debian.org/support"
BUG_REPORT_URL="https://bugs.debian.org/"
EOF
    fi
    msg_ok "os-release → Debian 12"

    # Версия
    local version=""; version=$(get_latest_release "home-assistant/supervised-installer")
    [ -z "$version" ] && { version="2.0.0"; msg_warn "API недоступен → v${version}"; } || msg_ok "Версия: ${version}"

    local url="https://github.com/home-assistant/supervised-installer/releases/download/${version}/homeassistant-supervised.deb"
    local deb="/tmp/homeassistant-supervised.deb"
    download_file "$url" "$deb" "Скачивание HA Supervised ${version}" || exit 1

    # Установка
    if [ "$DRY_RUN" = true ]; then
        msg_dim "[dry-run] MACHINE=${HA_MACHINE} dpkg -i ${deb}"
    else
        msg_action "Установка (машина: ${HA_MACHINE})..."
        msg_info "Загрузка образов: 10–20 мин"
        echo ""
        export MACHINE="$HA_MACHINE"
        local ilog; ilog=$(mktemp /tmp/ha_dpkg_XXXXXX.log)
        DEBIAN_FRONTEND=noninteractive dpkg -i "$deb" > "$ilog" 2>&1
        local de=$?
        grep -iE "(pull|download|start|error|warn|done|extract)" "$ilog" 2>/dev/null | head -20 | \
            while IFS= read -r line; do echo -e "    ${BLUE}│${NC} ${line}"; done
        [ $de -ne 0 ] && { msg_warn "dpkg ${de} — исправление..."; apt-get install -f -y >> "$ilog" 2>&1 || true; }
        rm -f "$ilog"
        msg_ok "HA Supervised установлен"
    fi
    rm -f "$deb"

    # Drop-in
    if [ "$DRY_RUN" = false ]; then
        mkdir -p /etc/systemd/system/hassio-supervisor.service.d
        cat > /etc/systemd/system/hassio-supervisor.service.d/mask-os-release.conf << 'DROPIN'
[Service]
ExecStartPre=/bin/bash -c '\
  if ! grep -q "^ID=debian" /etc/os-release 2>/dev/null; then \
    printf "%%s\\n" \
      "PRETTY_NAME=\"Debian GNU/Linux 12 (bookworm)\"" \
      "NAME=\"Debian GNU/Linux\"" \
      "VERSION_ID=\"12\"" \
      "VERSION=\"12 (bookworm)\"" \
      "VERSION_CODENAME=bookworm" \
      "ID=debian" \
      "HOME_URL=\"https://www.debian.org/\"" \
      "SUPPORT_URL=\"https://www.debian.org/support\"" \
      "BUG_REPORT_URL=\"https://bugs.debian.org/\"" \
      > /etc/os-release; \
  fi'
DROPIN
        systemctl daemon-reload
        msg_ok "Drop-in установлен"

        cat > /root/restore_armbian_identity.sh << RESTORE
#!/bin/bash
set -e
BACKUP="${BACKUP_DIR}/os-release.original"
[ ! -f "\$BACKUP" ] && echo "✘ Бэкап не найден: \$BACKUP" && exit 1
cp "\$BACKUP" /etc/os-release
echo "✔ os-release восстановлен"
rm -f /etc/systemd/system/hassio-supervisor.service.d/mask-os-release.conf
rmdir /etc/systemd/system/hassio-supervisor.service.d 2>/dev/null || true
systemctl daemon-reload
echo "✔ Drop-in удалён"
echo "ℹ HA может показать 'unsupported system'"
RESTORE
        chmod +x /root/restore_armbian_identity.sh
        msg_ok "Откат: /root/restore_armbian_identity.sh"
    fi
    mark_done "$sid"
}

# ========================== ШАГ 9: ОПТИМИЗАЦИЯ ==============================

step_optimize_system() {
    local sid="optimize_system"
    if is_done "$sid"; then msg_ok "[9/11] Оптимизация — пропуск"; return 0; fi
    header "ШАГ 9/11 — ОПТИМИЗАЦИЯ TV-БОКСА"

    if [ "$SKIP_OPTIMIZE" = true ]; then msg_warn "Пропущено"; mark_done "$sid"; return 0; fi
    if [ "$DRY_RUN" = true ]; then msg_dim "[dry-run]"; mark_done "$sid"; return 0; fi

    mkdir -p "$BACKUP_DIR" /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/10-ha-tvbox.conf << 'EOF'
[Journal]
SystemMaxUse=50M
SystemMaxFileSize=10M
MaxRetentionSec=7day
ForwardToSyslog=no
Compress=yes
EOF
    systemctl restart systemd-journald 2>/dev/null || true
    msg_ok "Журнал: 50 МБ / 7 дней"

    cp /etc/fstab "$BACKUP_DIR/fstab.bak" 2>/dev/null || true
    if grep -E "^\S+\s+/\s+" /etc/fstab 2>/dev/null | grep -q "noatime"; then msg_ok "noatime есть"
    elif grep -E "^\S+\s+/\s+" /etc/fstab 2>/dev/null | grep -q "defaults"; then
        sed -i '/^\S\+\s\+\/\s/ s/defaults/defaults,noatime/' /etc/fstab 2>/dev/null; msg_ok "noatime добавлен"
    else msg_warn "noatime: нестандартный fstab"; fi

    cat > /etc/sysctl.d/99-ha-emmc.conf << 'EOF'
vm.dirty_ratio=10
vm.dirty_background_ratio=5
vm.dirty_writeback_centisecs=1500
EOF
    sysctl -p /etc/sysctl.d/99-ha-emmc.conf >/dev/null 2>&1 || true
    msg_ok "sysctl оптимизирован"

    grep -q "tmpfs.*/tmp" /etc/fstab 2>/dev/null || \
        { echo "tmpfs /tmp tmpfs defaults,nosuid,nodev,size=128M 0 0" >> /etc/fstab; msg_ok "tmpfs /tmp"; }

    msg_ok "Оптимизация завершена"
    mark_done "$sid"
}

# ========================== ШАГ 10: ДОПОЛНИТЕЛЬНО ===========================

step_extras() {
    local sid="extras"
    if is_done "$sid"; then msg_ok "[10/11] Доп. настройки — пропуск"; return 0; fi
    header "ШАГ 10/11 — ДОПОЛНИТЕЛЬНЫЕ НАСТРОЙКИ"

    if [ "$SKIP_EXTRAS" = true ]; then msg_warn "Пропущено (--skip-extras)"; mark_done "$sid"; return 0; fi
    if [ "$DRY_RUN" = true ]; then msg_dim "[dry-run] watchdog / очистка / mDNS / Telegram"; mark_done "$sid"; return 0; fi

    # ─── WATCHDOG ───

    msg_action "Watchdog для HA..."

    cat > /usr/local/bin/ha-watchdog << 'WATCHDOG'
#!/bin/bash
URL="http://localhost:8123"
LOG="/var/log/ha-watchdog.log"
STATE="/tmp/ha_watchdog_failures"
MAX=3
NOTIFY="/usr/local/bin/ha-notify"

docker ps --format '{{.Names}}' 2>/dev/null | grep -q "hassio_supervisor" || exit 0

failures=$(cat "$STATE" 2>/dev/null || echo 0)
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$URL" 2>/dev/null || echo "000")

if [ "$code" = "000" ]; then
    failures=$((failures + 1))
    echo "$failures" > "$STATE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') WARN HA не отвечает (${failures}/${MAX})" >> "$LOG"
    if [ "$failures" -ge "$MAX" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') ACTION Перезапуск homeassistant" >> "$LOG"
        docker restart homeassistant 2>/dev/null
        [ -x "$NOTIFY" ] && "$NOTIFY" "⚠️ *Watchdog*: HA перезапущен (не отвечал ${MAX} проверок)"
        echo 0 > "$STATE"
    fi
else
    [ "$failures" -gt 0 ] && echo "$(date '+%Y-%m-%d %H:%M:%S') OK Восстановлен (HTTP ${code})" >> "$LOG"
    echo 0 > "$STATE"
fi

[ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 1000 ] && tail -500 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
WATCHDOG

    chmod +x /usr/local/bin/ha-watchdog
    echo "*/5 * * * * root /usr/local/bin/ha-watchdog" > /etc/cron.d/ha-watchdog
    msg_ok "Watchdog: каждые 5 мин, перезапуск после 3 неудач"

    # ─── АВТООЧИСТКА ───

    msg_action "Автоочистка диска..."

    cat > /usr/local/bin/ha-cleanup << 'CLEANUP'
#!/bin/bash
LOG="/var/log/ha-cleanup.log"
NOTIFY="/usr/local/bin/ha-notify"
FREE_MB=$(df -m / | awk 'NR==2{print $4}')

if [ "$FREE_MB" -lt 1000 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') WARN ${FREE_MB} МБ — очистка" >> "$LOG"
    docker system prune -f 2>/dev/null
    journalctl --vacuum-size=30M 2>/dev/null
    apt-get clean 2>/dev/null
    find /var/log -name "*.gz" -mtime +7 -delete 2>/dev/null
    find /var/log -name "*.old" -delete 2>/dev/null
    find /tmp -type f -mtime +3 -delete 2>/dev/null
    NEW=$(df -m / | awk 'NR==2{print $4}')
    echo "$(date '+%Y-%m-%d %H:%M:%S') OK ${FREE_MB} → ${NEW} МБ" >> "$LOG"
    [ -x "$NOTIFY" ] && "$NOTIFY" "🧹 *Очистка*: ${FREE_MB} → ${NEW} МБ"
fi

[ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 500 ] && tail -200 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
CLEANUP

    chmod +x /usr/local/bin/ha-cleanup
    echo "30 3 * * * root /usr/local/bin/ha-cleanup" > /etc/cron.d/ha-cleanup
    msg_ok "Автоочистка: ежедневно 03:30, порог 1 ГБ"

    # ─── mDNS ───

    msg_action "Настройка mDNS..."

    systemctl enable avahi-daemon 2>/dev/null || true
    systemctl start avahi-daemon 2>/dev/null || true

    local current_hn
    current_hn=$(hostname)

    if [ "$current_hn" != "homeassistant" ]; then
        echo ""
        msg_info "Текущий hostname: ${current_hn}"
        read -r -p "  Сменить на 'homeassistant' (для homeassistant.local)? [y/N]: " hn_ans
        if [[ "${hn_ans:-}" =~ ^[Yy]$ ]]; then
            hostnamectl set-hostname homeassistant 2>/dev/null || true
            msg_ok "Hostname → homeassistant"
            msg_ok "mDNS: http://homeassistant.local:8123"
        else
            msg_info "Hostname оставлен: ${current_hn}"
            msg_ok "mDNS: http://${current_hn}.local:8123"
        fi
    else
        msg_ok "mDNS: http://homeassistant.local:8123"
    fi

    # ─── ha-health ───

    msg_action "Утилита ha-health..."

    cat > /usr/local/bin/ha-health << 'HEALTH'
#!/bin/bash
echo ""
echo "===== СИСТЕМА ====="
printf "  %-12s %s\n" "Hostname:" "$(hostname)"
printf "  %-12s %s\n" "Uptime:" "$(uptime -p 2>/dev/null || uptime)"
printf "  %-12s %s\n" "RAM:" "$(free -h | awk '/^Mem:/{printf "%s / %s", $3, $2}')"
printf "  %-12s %s\n" "Swap:" "$(free -h | awk '/^Swap:/{printf "%s / %s", $3, $2}')"
printf "  %-12s %s\n" "Диск /:" "$(df -h / | awk 'NR==2{printf "%s / %s (%s свободно)", $3, $2, $4}')"

TF=$(find /sys/class/thermal -name "temp" -path "*/thermal_zone0/*" 2>/dev/null | head -1)
if [ -n "$TF" ]; then
    T=$(($(cat "$TF") / 1000))
    printf "  %-12s %s°C" "CPU:" "$T"
    [ "$T" -gt 75 ] && printf " ⚠️"
    echo ""
fi

echo ""
echo "===== КОНТЕЙНЕРЫ ====="
docker ps --format "  {{.Names}}\t{{.Status}}" 2>/dev/null || echo "  Docker недоступен"

echo ""
echo "===== USB ====="
for dev in /dev/ttyUSB* /dev/ttyACM*; do
    [ -e "$dev" ] && printf "  %s (%s)\n" "$dev" "$(stat -c '%U:%G' "$dev" 2>/dev/null)"
done
lsusb 2>/dev/null | grep -iE "1a86|10c4|1cf1|0658|cc2531|conbee" | sed 's/^/  /' || true

echo ""
echo "===== HA ====="
ha core info 2>/dev/null | grep -E "version|machine|arch" | sed 's/^/  /' || echo "  HA CLI недоступен"

echo ""
echo "===== ПРОБЛЕМЫ ====="
ha resolution info 2>/dev/null | head -15 | sed 's/^/  /' || echo "  Нет данных"

echo ""
echo "===== WATCHDOG ====="
[ -f /var/log/ha-watchdog.log ] && tail -5 /var/log/ha-watchdog.log | sed 's/^/  /' || echo "  Лог пуст"
echo ""
HEALTH

    chmod +x /usr/local/bin/ha-health
    msg_ok "Утилита: ha-health"

    # ─── USB ───

    msg_action "Проверка USB..."

    local usb_found=false
    for dev in /dev/ttyUSB* /dev/ttyACM*; do
        [ -e "$dev" ] && { msg_info "Найдено: ${dev}"; usb_found=true; }
    done

    if command -v lsusb &>/dev/null; then
        local zb=""; zb=$(lsusb 2>/dev/null | grep -iE "1a86:55d4|10c4:ea60|1cf1:0030|cc2531|conbee" | head -1) || true
        [ -n "$zb" ] && { msg_ok "Zigbee: ${zb}"; usb_found=true; }
        local zw=""; zw=$(lsusb 2>/dev/null | grep -iE "0658:0200|sigma" | head -1) || true
        [ -n "$zw" ] && { msg_ok "Z-Wave: ${zw}"; usb_found=true; }
    fi
    [ "$usb_found" = false ] && msg_info "USB-адаптеры не обнаружены"

    # ─── TELEGRAM ───

    echo ""
    separator
    echo ""
    msg_info "Telegram-уведомления (опционально)"
    msg_dim "Watchdog и автоочистка могут отправлять алерты"
    echo ""
    read -r -p "  Настроить Telegram? [y/N]: " tg_ans

    if [[ "${tg_ans:-}" =~ ^[Yy]$ ]]; then
        echo ""
        msg_info "Бот: https://t.me/BotFather"
        msg_info "Chat ID: https://t.me/userinfobot"
        echo ""
        read -r -p "  Bot Token: " TG_TOKEN
        read -r -p "  Chat ID:   " TG_CHAT

        if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
            cat > /usr/local/bin/ha-notify << TGNOTIFY
#!/bin/bash
TOKEN="${TG_TOKEN}"
CHAT="${TG_CHAT}"
MSG="\${1:-Без текста}"
HOST="\$(hostname)"
curl -s -X POST "https://api.telegram.org/bot\${TOKEN}/sendMessage" \\
    -d chat_id="\${CHAT}" \\
    -d text="🏠 *\${HOST}*: \${MSG}" \\
    -d parse_mode="Markdown" \\
    >/dev/null 2>&1
TGNOTIFY
            chmod +x /usr/local/bin/ha-notify
            /usr/local/bin/ha-notify "✅ Уведомления настроены!" 2>/dev/null \
                && msg_ok "Telegram: настроен и протестирован" \
                || msg_warn "Telegram: настроен, тест не прошёл"
        else
            msg_warn "Данные не введены — пропущено"
        fi
    else
        msg_info "Telegram пропущен"
        cat > /usr/local/bin/ha-notify << 'STUB'
#!/bin/bash
# Telegram не настроен
# Инструкция: отредактируйте этот файл
# TOKEN="your_bot_token"
# CHAT="your_chat_id"
exit 0
STUB
        chmod +x /usr/local/bin/ha-notify
    fi

    msg_ok "Дополнительные настройки завершены"
    mark_done "$sid"
}

# ========================== ШАГ 11: HEALTH-CHECK ============================

step_health_check() {
    header "ШАГ 11/11 — ПРОВЕРКА"
    if [ "$DRY_RUN" = true ]; then msg_dim "[dry-run] пропуск"; return 0; fi

    local issues=0 warnings=0

    docker ps &>/dev/null && msg_ok "Docker" || { msg_error "Docker"; issues=$((issues+1)); }

    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "hassio_supervisor" \
        && msg_ok "Supervisor" || { msg_warn "Supervisor загружается..."; warnings=$((warnings+1)); }

    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^homeassistant$" \
        && msg_ok "HA Core" || { msg_warn "HA Core загружается..."; warnings=$((warnings+1)); }

    local aa=""; aa=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) || aa="N"
    [ "$aa" = "Y" ] && msg_ok "AppArmor" || { msg_warn "AppArmor (перезагрузка?)"; warnings=$((warnings+1)); }

    systemctl is-active --quiet NetworkManager 2>/dev/null && msg_ok "NetworkManager" \
        || { msg_error "NetworkManager"; issues=$((issues+1)); }

    systemctl is-active --quiet systemd-resolved 2>/dev/null && msg_ok "systemd-resolved" \
        || { msg_warn "systemd-resolved"; warnings=$((warnings+1)); }

    gdbus introspect --system --dest io.hass.os --object-path /io/hass/os &>/dev/null \
        && msg_ok "OS-Agent" || { msg_warn "OS-Agent D-Bus"; warnings=$((warnings+1)); }

    local sw=0; sw=$(free -m | awk '/^Swap:/{print $2}') || true
    [ "$sw" -gt 0 ] 2>/dev/null && msg_ok "Swap: ${sw} МБ" || { msg_warn "Swap: нет"; warnings=$((warnings+1)); }

    local tf=""; tf=$(find /sys/class/thermal -name "temp" -path "*/thermal_zone0/*" 2>/dev/null | head -1)
    if [ -n "$tf" ]; then
        local tc=$(( $(cat "$tf") / 1000 ))
        if   [ "$tc" -lt 65 ]; then msg_ok "Температура: ${tc}°C"
        elif [ "$tc" -lt 80 ]; then msg_warn "Температура: ${tc}°C"; warnings=$((warnings+1))
        else msg_error "Температура: ${tc}°C!"; issues=$((issues+1)); fi
    fi

    local cid=""; cid=$(. /etc/os-release 2>/dev/null && echo "${ID:-}") || true
    [ "$cid" = "debian" ] && msg_ok "Маскировка: активна" || { msg_warn "Маскировка: ${cid}"; warnings=$((warnings+1)); }

    [ -f /etc/systemd/system/hassio-supervisor.service.d/mask-os-release.conf ] \
        && msg_ok "Drop-in" || { msg_warn "Drop-in отсутствует"; warnings=$((warnings+1)); }

    [ -x /usr/local/bin/ha-watchdog ] && msg_ok "Watchdog" || { msg_warn "Watchdog не установлен"; warnings=$((warnings+1)); }
    [ -x /usr/local/bin/ha-cleanup ]  && msg_ok "Автоочистка" || { msg_warn "Автоочистка не установлена"; warnings=$((warnings+1)); }

    systemctl is-active --quiet avahi-daemon 2>/dev/null && msg_ok "mDNS (avahi)" \
        || { msg_warn "mDNS не активен"; warnings=$((warnings+1)); }

    if [ -x /usr/local/bin/ha-notify ] && grep -q "TOKEN=" /usr/local/bin/ha-notify 2>/dev/null \
        && ! grep -q "^#.*TOKEN=" /usr/local/bin/ha-notify 2>/dev/null; then
        msg_ok "Telegram"
    else
        msg_info "Telegram: не настроен"
    fi

    separator
    if [ $issues -eq 0 ] && [ $warnings -eq 0 ]; then msg_ok "Всё в порядке"
    elif [ $issues -eq 0 ]; then msg_warn "Предупреждений: ${warnings}"
    else msg_error "Ошибок: ${issues} | Предупреждений: ${warnings}"; fi
}

# ========================== ОЖИДАНИЕ ========================================

wait_for_ha() {
    header "ОЖИДАНИЕ ЗАПУСКА"
    if [ "$DRY_RUN" = true ]; then msg_dim "[dry-run] пропуск"; return 0; fi

    local ip=""; ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"
    local url="http://${ip}:8123"

    msg_info "Адрес: ${url}"
    msg_info "Таймаут: 15 мин"
    echo ""

    local max_wait=900 elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        local cnt=0 sup="—" ha="—"
        cnt=$(docker ps --format "." 2>/dev/null | wc -l) || true
        docker ps --format "{{.Names}}" 2>/dev/null | grep -q "hassio_supervisor" && sup="✔"
        docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^homeassistant$" && ha="✔"

        echo -ne "\r  ⏳ ${elapsed}/${max_wait}с │ Контейнеров: ${cnt} │ Supervisor: ${sup} │ Core: ${ha}    "

        local code=""; code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null) || code="000"
        if [ "$code" != "000" ]; then
            echo ""; echo ""
            msg_ok "HA отвечает (HTTP ${code})"
            return 0
        fi
        sleep 15; elapsed=$((elapsed + 15))
    done

    echo ""; echo ""
    msg_warn "Таймаут — HA ещё загружается"
    msg_info "Проверьте: ${url}"
}

# ========================== УДАЛЕНИЕ ========================================

uninstall_ha() {
    header "УДАЛЕНИЕ HOME ASSISTANT"

    echo -e "  ${WARN}  ${YELLOW}Удаляется:${NC} контейнеры, образы, пакеты, утилиты, маскировка"
    echo -e "  ${INFO}  ${WHITE}Остаётся:${NC} Docker, swap, сеть, данные (${HASSIO_DIR})"
    echo ""
    read -r -p "  Удалить? [y/N]: " ans
    [[ ! "${ans:-}" =~ ^[Yy]$ ]] && { msg_info "Отменено"; return 0; }
    echo ""

    ha core stop 2>/dev/null || true; ha supervisor stop 2>/dev/null || true; sleep 5

    local ctr=""; ctr=$(docker ps -a --filter "name=hassio_" --filter "name=homeassistant" --filter "name=addon_" -q 2>/dev/null) || true
    [ -n "$ctr" ] && { echo "$ctr" | xargs docker stop 2>/dev/null || true; echo "$ctr" | xargs docker rm -f 2>/dev/null || true; msg_ok "Контейнеры"; }

    local imgs=""; imgs=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E "homeassistant|hassio|ghcr.io/home-assistant") || true
    [ -n "$imgs" ] && { echo "$imgs" | xargs docker rmi -f 2>/dev/null || true; msg_ok "Образы"; }

    dpkg --purge homeassistant-supervised 2>/dev/null || true
    dpkg --purge os-agent 2>/dev/null || true
    msg_ok "Пакеты"

    rm -f /etc/systemd/system/hassio-supervisor.service.d/mask-os-release.conf
    rmdir /etc/systemd/system/hassio-supervisor.service.d 2>/dev/null || true
    rm -f /etc/systemd/system/hassio-supervisor.service /etc/systemd/system/hassio-apparmor.service
    systemctl daemon-reload
    msg_ok "systemd"

    [ -f "${BACKUP_DIR}/os-release.original" ] && { cp "${BACKUP_DIR}/os-release.original" /etc/os-release; msg_ok "os-release"; } || msg_warn "Бэкап не найден"

    rm -f /usr/local/bin/ha-health /usr/local/bin/ha-watchdog /usr/local/bin/ha-cleanup /usr/local/bin/ha-notify \
          /root/restore_armbian_identity.sh /etc/cron.d/ha-watchdog /etc/cron.d/ha-cleanup "$STATE_FILE"
    msg_ok "Утилиты и cron"

    echo ""
    msg_ok "Home Assistant удалён"
    msg_info "Данные: ${HASSIO_DIR} (сохранены)"
    msg_info "Полное удаление: rm -rf ${HASSIO_DIR}"
}

# ========================== ОТЧЁТ ==========================================

show_report() {
    local ip=""; ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"

    local duration=""
    if [ -n "${INSTALL_START_TIME:-}" ]; then
        local el=$(( $(date +%s) - INSTALL_START_TIME ))
        duration="$((el / 60)) мин $((el % 60)) сек"
    fi

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${WHITE}${BOLD}              УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО                    ${NC}${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    [ -n "$duration" ] && msg_info "Время: ${duration}" && echo ""

    echo -e "  ${BOLD}Доступ:${NC}"
    echo -e "    ${GREEN}http://${ip}:8123${NC}"
    if systemctl is-active --quiet avahi-daemon 2>/dev/null; then
        local hn; hn=$(hostname)
        echo -e "    ${GREEN}http://${hn}.local:8123${NC}"
    fi
    echo -e "    ${YELLOW}Первая загрузка: до 20 мин${NC}"
    echo ""
    separator
    echo ""

    echo -e "  ${BOLD}Команды HA:${NC}"
    echo -e "    ha core info             ${DIM}# информация${NC}"
    echo -e "    ha supervisor info       ${DIM}# супервизор${NC}"
    echo -e "    ha resolution info       ${DIM}# проблемы${NC}"
    echo -e "    ha core logs             ${DIM}# логи${NC}"
    echo -e "    docker ps                ${DIM}# контейнеры${NC}"
    echo ""

    # Показываем только установленные утилиты
    local has_extras=false
    for u in ha-health ha-watchdog ha-cleanup ha-notify; do
        [ -x "/usr/local/bin/${u}" ] && has_extras=true && break
    done

    if [ "$has_extras" = true ]; then
        echo -e "  ${BOLD}Утилиты:${NC}"
        [ -x /usr/local/bin/ha-health ]   && echo -e "    ha-health                ${DIM}# диагностика${NC}"
        [ -x /usr/local/bin/ha-watchdog ] && echo -e "    ha-watchdog              ${DIM}# авто-проверка (cron */5 мин)${NC}"
        [ -x /usr/local/bin/ha-cleanup ]  && echo -e "    ha-cleanup               ${DIM}# авто-очистка (cron 03:30)${NC}"
        if [ -x /usr/local/bin/ha-notify ] && grep -q "TOKEN=" /usr/local/bin/ha-notify 2>/dev/null \
            && ! grep -q "^#.*TOKEN=" /usr/local/bin/ha-notify 2>/dev/null; then
            echo -e "    ha-notify \"текст\"         ${DIM}# Telegram${NC}"
        fi
        echo ""
    fi

    echo -e "  ${BOLD}Маскировка:${NC}"
    echo -e "    Откат:   bash /root/restore_armbian_identity.sh"
    echo -e "    Бэкап:   ${BACKUP_DIR}/os-release.original"
    echo ""

    [ -n "${LOG_FILE:-}" ] && echo -e "  ${BOLD}Лог:${NC} ${LOG_FILE}" && echo ""

    if [ "${NEED_REBOOT:-false}" = true ]; then
        echo -e "  ${WARN}  ${YELLOW}${BOLD}НУЖНА ПЕРЕЗАГРУЗКА (AppArmor)${NC}"
        echo ""
        read -r -p "  Перезагрузить? [y/N]: " ans
        [[ "${ans:-}" =~ ^[Yy]$ ]] && { msg_action "Перезагрузка..."; sleep 3; reboot; }
    fi
}

# ========================== MAIN ============================================

main() {
    parse_args "$@"

    if [ "$EUID" -ne 0 ]; then
        echo "✘ Запустите от root: sudo bash $0 ${*:-}"; exit 1
    fi

    show_banner
    setup_logging

    separator
    msg_info "Начало: $(date)"

    if [ "$HA_MACHINE" = "$HA_DEFAULT_MACHINE" ]; then
        local detected; detected=$(detect_machine_type)
        [ "$detected" != "$HA_DEFAULT_MACHINE" ] && msg_info "Автоопределение: ${detected}"
        HA_MACHINE="$detected"
    fi
    msg_info "Машина HA: ${HA_MACHINE}"
    [ "$DRY_RUN" = true ] && msg_warn "Режим: dry-run"

    acquire_lock
    ensure_services

    if [ "$UNINSTALL" = true ]; then uninstall_ha; exit 0; fi

    preflight_checks

    if [ "$CHECK_ONLY" = true ]; then echo ""; msg_ok "Система совместима"; exit 0; fi

    echo ""; separator; echo ""
    echo -e "  ${INFO}  ${WHITE}План:${NC}"
    [ "$SKIP_UPDATE" = false ]   && echo -e "      ${ARROW} Обновление системы"
    echo -e "      ${ARROW} Зависимости (20 пакетов)"
    echo -e "      ${ARROW} NetworkManager + systemd-resolved"
    echo -e "      ${ARROW} AppArmor"
    [ "$SKIP_SWAP" = false ]     && echo -e "      ${ARROW} Swap"
    echo -e "      ${ARROW} Docker"
    echo -e "      ${ARROW} OS-Agent"
    echo -e "      ${ARROW} Маскировка + HA Supervised (${HA_MACHINE})"
    [ "$SKIP_OPTIMIZE" = false ] && echo -e "      ${ARROW} Оптимизация eMMC/SD"
    [ "$SKIP_EXTRAS" = false ]   && echo -e "      ${ARROW} Watchdog + очистка + mDNS + Telegram"
    echo -e "      ${ARROW} Health-check"
    echo ""

    read -r -p "  Начать? [y/N]: " ans
    [[ ! "${ans:-}" =~ ^[Yy]$ ]] && { msg_info "Отменено"; exit 0; }

    INSTALL_START_TIME=$(date +%s)
    echo ""

    step_update_system
    step_install_deps
    step_configure_network
    step_configure_apparmor
    step_configure_swap
    step_install_docker
    step_install_os_agent
    step_install_ha_supervised
    step_optimize_system
    step_extras
    step_health_check

    [ "$NO_WAIT" = false ] && wait_for_ha

    show_report
}

main "$@"
