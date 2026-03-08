#!/bin/bash

# ============================================================================
#  Home Assistant Supervised — ULTIMATE INSTALLER
#  Версия:    7.4 (Final Release)
#  Платформа: TV-Боксы и SBC (Armbian Bookworm / aarch64 / x86_64)
# ============================================================================

readonly SCRIPT_VERSION="7.4"
readonly HA_DEFAULT_MACHINE="qemuarm-64"
readonly STATE_FILE="/root/.ha_install_state"
readonly LOCK_FILE="/var/lock/ha_install.lock"
readonly BACKUP_DIR="/root/.ha_install_backup"
readonly HA_BACKUP_DIR="/root/ha-backups"
readonly LOG_DIR="/var/log"
readonly HASSIO_DIR="/usr/share/hassio"
readonly GRACE_MARKER="/tmp/.ha_just_installed"
readonly FAKED_OS_RELEASE="${BACKUP_DIR}/os-release.faked"

set -uo pipefail

# ========================== ЦВЕТА ===========================================
if [ -t 1 ]; then
    RED='\033[0;31m'     GREEN='\033[0;32m'
    YELLOW='\033[1;33m'  BLUE='\033[0;34m'
    MAGENTA='\033[0;35m' CYAN='\033[0;36m'
    WHITE='\033[1;37m'   BOLD='\033[1m'
    DIM='\033[2m'        NC='\033[0m'
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
OPT_EMMC_TUNING=true
OPT_USB_POWER=true
OPT_UFW=true
OPT_SSH_HARDENING=true
OPT_AUTOUPDATE=true
OPT_WATCHDOG=true
OPT_THERMAL=true
OPT_BACKUP=true
OPT_HACS=true
OPT_HOSTNAME=true
OPT_STATIC_IP=false
OPT_TELEGRAM=false

STATIC_IP=""
STATIC_GW=""
STATIC_DNS=""
TG_TOKEN=""
TG_CHAT=""

SKIP_UPDATE=false
CHECK_ONLY=false
UNINSTALL=false
DRY_RUN=false
SILENT=false
SHOW_STATUS=false
HA_MACHINE="$HA_DEFAULT_MACHINE"
MACHINE_EXPLICIT=false
OVERRIDE_OS_AGENT_VER=""
OVERRIDE_HA_VER=""
LOG_FILE=""
LOGGING_ACTIVE=false

# ========================== ВЫВОД И ЛОГИРОВАНИЕ =============================
header() {
    local text="$1"
    local border="══════════════════════════════════════════════════════════════"
    local inner_width=62
    local visible_len=${#text}
    local pad=$((inner_width - visible_len - 2))
    [ $pad -lt 0 ] && pad=0
    echo -e "\n${BLUE}╔${border}╗${NC}"
    echo -e "${BLUE}║${WHITE}${BOLD}  ${text}$(printf '%*s' $pad '')${NC}${BLUE}║${NC}"
    echo -e "${BLUE}╚${border}╝${NC}\n"
}

separator()  { [ "$SILENT" = true ] && return; echo -e "${DIM}  ────────────────────────────────────────────────────────────${NC}"; }
msg_info()   { [ "$SILENT" = true ] && return; echo -e " ${INFO}  ${WHITE}$1${NC}"; }
msg_ok()     { [ "$SILENT" = true ] && return; echo -e " ${CHECK}  ${GREEN}$1${NC}"; }
msg_warn()   { echo -e " ${WARN}  ${YELLOW}$1${NC}"; }
msg_error()  { echo -e " ${CROSS}  ${RED}$1${NC}"; }
msg_action() { [ "$SILENT" = true ] && return; echo -e " ${ARROW}  ${CYAN}$1${NC}"; }
msg_dim()    { [ "$SILENT" = true ] && return; echo -e "       ${DIM}$1${NC}"; }

setup_logging() {
    LOG_FILE="${LOG_FILE:-${LOG_DIR}/ha_install_$(date +%Y%m%d_%H%M%S).log}"
    mkdir -p "$(dirname "$LOG_FILE")"
    exec 3>&1 4>&2
    exec > >(tee -a "$LOG_FILE") 2>&1
    LOGGING_ACTIVE=true
    msg_info "Лог: ${LOG_FILE}"
}

flush_log() {
    if [ "$LOGGING_ACTIVE" = true ]; then
        exec 1>&3 2>&4 3>&- 4>&- 2>/dev/null || true
        LOGGING_ACTIVE=false
        sleep 0.5
    fi
}

# ========================== СПИННЕР =========================================
spinner_pid=""

spinner_start() {
    local desc="$1"
    [ "$SILENT" = true ] && return
    (
        local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        local i=0 elapsed=0
        while true; do
            i=$(( (i+1) % ${#spin} ))
            printf "\r ${CYAN}%s${NC}  ${WHITE}%s${NC} ${DIM}(%ds)${NC}  " \
                "${spin:$i:1}" "$desc" "$elapsed" >&2
            sleep 1
            elapsed=$((elapsed+1))
        done
    ) &
    spinner_pid=$!
    disown "$spinner_pid" 2>/dev/null || true
}

spinner_stop() {
    if [ -n "$spinner_pid" ] && kill -0 "$spinner_pid" 2>/dev/null; then
        kill "$spinner_pid" 2>/dev/null || true
        wait "$spinner_pid" 2>/dev/null || true
        printf "\r%80s\r" "" >&2
    fi
    spinner_pid=""
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
    spinner_stop 2>/dev/null || true
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

pkg_available() {
    apt-cache show "$1" >/dev/null 2>&1
}

run_cmd() {
    local desc="$1"; shift
    local lfile
    lfile=$(mktemp /tmp/ha_step_XXXXXX.log)
    msg_action "${desc}..."
    if [ "$DRY_RUN" = true ]; then
        msg_dim "[dry-run] $*"
        rm -f "$lfile"; return 0
    fi
    if "$@" > "$lfile" 2>&1; then
        msg_ok "$desc"; rm -f "$lfile"; return 0
    else
        local c=$?
        msg_error "${desc} — ОШИБКА (код ${c})"
        msg_warn "Подробности: ${lfile}"
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
                    msg_ok "${desc}"; return 0
                fi
                msg_warn "Файл .deb повреждён, повтор..."
            else
                msg_ok "${desc}"; return 0
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
    local repo="$1"
    local version=""

    if command -v curl &>/dev/null && command -v jq &>/dev/null; then
        version=$(curl -fsSL --timeout 15 \
            "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
            | jq -r '.tag_name // empty' 2>/dev/null) || true
        version=$(echo "$version" | tr -d '[:space:]')
    fi

    if [ -z "$version" ] && command -v curl &>/dev/null; then
        local final_url=""
        final_url=$(curl -sL --timeout 15 -o /dev/null \
            -w '%{url_effective}' \
            "https://github.com/${repo}/releases/latest" 2>/dev/null) || true
        if [ -n "$final_url" ]; then
            version=$(echo "$final_url" | sed 's|.*/tag/||' | tr -d '[:space:]')
        fi
    fi

    if [ -z "$version" ] && command -v curl &>/dev/null; then
        version=$(curl -sI --timeout 15 \
            "https://github.com/${repo}/releases/latest" 2>/dev/null \
            | grep -i '^location:' \
            | head -1 \
            | sed 's|.*/tag/||' \
            | tr -d '[:space:]') || true
    fi

    if [ -z "$version" ] && command -v wget &>/dev/null; then
        version=$(wget -q --timeout=15 --max-redirect=0 -S \
            "https://github.com/${repo}/releases/latest" 2>&1 \
            | grep -i 'Location:' \
            | head -1 \
            | sed 's|.*/tag/||' \
            | tr -d '[:space:]') || true
    fi

    echo "$version"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "x86_64"  ;;
        aarch64) echo "aarch64" ;;
        armv7l)  echo "armv7"   ;;
        i686)    echo "i386"    ;;
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

get_cpu_temp() {
    [ -f /sys/class/thermal/thermal_zone0/temp ] \
        && echo "$(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 ))" \
        || echo ""
}

generate_os_release() {
    local ha_ver="$1"
    local major
    major=$(echo "$ha_ver" | sed 's/^[^0-9]*//' | cut -d. -f1)

    if [ "${major:-0}" -ge 4 ] 2>/dev/null; then
        cat << 'EOF'
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
NAME="Debian GNU/Linux"
VERSION_ID="13"
VERSION="13 (trixie)"
VERSION_CODENAME=trixie
ID=debian
HOME_URL="https://www.debian.org/"
SUPPORT_URL="https://www.debian.org/support"
BUG_REPORT_URL="https://bugs.debian.org/"
EOF
    else
        cat << 'EOF'
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
}

# ========================== МАСТЕР TUI ======================================
run_wizard() {
    if ! command -v whiptail &>/dev/null; then
        apt-get update -qq && apt-get install -y whiptail -qq
    fi

    whiptail --title "HA Ultimate Installer v${SCRIPT_VERSION}" --msgbox \
        "Добро пожаловать в установщик Home Assistant Supervised\nдля TV-боксов и SBC.\n\nОбязательное ядро (Docker, OS-Agent, HA) ставится всегда.\nНа следующем экране выберите дополнительные модули." 13 64

    local current_ip current_gw
    current_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || current_ip="н/д"
    current_gw=$(ip route 2>/dev/null | awk '/default/{print $3}' | head -1) || current_gw="н/д"

    local choices
    choices=$(whiptail --title "Компоненты установки" --checklist \
        "Пробел — выбор/снятие, Enter — подтвердить" 30 72 16 \
        "ZRAM"      "▸ Swap в RAM (защита eMMC)"               ON  \
        "EMMC"      "▸ Тюнинг eMMC/SD (noatime, journal, IO)"  ON  \
        "USBPOWER"  "▸ USB power fix (Zigbee/Z-Wave)"          ON  \
        "─────1"    "──── Безопасность ───────────────────"     OFF \
        "UFW"       "▸ Firewall UFW + Fail2Ban + DOCKER-USER"  ON  \
        "SSHHARD"   "▸ SSH hardening (лимит попыток, no X11)"  ON  \
        "AUTOUPD"   "▸ Автообновления безопасности"             ON  \
        "─────2"    "──── Мониторинг и сервисы ────────────"    OFF \
        "WATCHDOG"  "▸ Watchdog + Очистка + Авторесторе сети"  ON  \
        "THERMAL"   "▸ Мониторинг температуры CPU"              ON  \
        "BACKUP"    "▸ Еженедельный бэкап конфигурации HA"      ON  \
        "HACS"      "▸ Магазин интеграций HACS"                 ON  \
        "─────3"    "──── Сеть и уведомления ──────────────"    OFF \
        "HOSTNAME"  "▸ Hostname → homeassistant.local"          ON  \
        "STATICIP"  "▸ Статический IP (сейчас: ${current_ip})" OFF \
        "TELEGRAM"  "▸ Уведомления в Telegram"                  OFF \
        3>&1 1>&2 2>&3) || { echo "Установка отменена."; exit 0; }

    OPT_ZRAM=false;   OPT_EMMC_TUNING=false; OPT_USB_POWER=false
    OPT_UFW=false;    OPT_SSH_HARDENING=false; OPT_AUTOUPDATE=false
    OPT_WATCHDOG=false; OPT_THERMAL=false;    OPT_BACKUP=false
    OPT_HACS=false;   OPT_HOSTNAME=false;     OPT_STATIC_IP=false
    OPT_TELEGRAM=false

    [[ $choices == *"ZRAM"* ]]     && OPT_ZRAM=true
    [[ $choices == *"EMMC"* ]]     && OPT_EMMC_TUNING=true
    [[ $choices == *"USBPOWER"* ]] && OPT_USB_POWER=true
    [[ $choices == *"UFW"* ]]      && OPT_UFW=true
    [[ $choices == *"SSHHARD"* ]]  && OPT_SSH_HARDENING=true
    [[ $choices == *"AUTOUPD"* ]]  && OPT_AUTOUPDATE=true
    [[ $choices == *"WATCHDOG"* ]] && OPT_WATCHDOG=true
    [[ $choices == *"THERMAL"* ]]  && OPT_THERMAL=true
    [[ $choices == *"BACKUP"* ]]   && OPT_BACKUP=true
    [[ $choices == *"HACS"* ]]     && OPT_HACS=true
    [[ $choices == *"HOSTNAME"* ]] && OPT_HOSTNAME=true
    [[ $choices == *"STATICIP"* ]] && OPT_STATIC_IP=true
    [[ $choices == *"TELEGRAM"* ]] && OPT_TELEGRAM=true

    if [ "$OPT_STATIC_IP" = true ]; then
        STATIC_IP=$(whiptail --title "Статический IP" --inputbox \
            "IP-адрес:" 10 50 "$current_ip" 3>&1 1>&2 2>&3) || { OPT_STATIC_IP=false; }
        if [ "$OPT_STATIC_IP" = true ]; then
            STATIC_GW=$(whiptail --title "Шлюз" --inputbox \
                "Адрес шлюза:" 10 50 "$current_gw" 3>&1 1>&2 2>&3) || STATIC_GW="$current_gw"
            STATIC_DNS=$(whiptail --title "DNS" --inputbox \
                "DNS (через запятую):" 10 50 "8.8.8.8,1.1.1.1" 3>&1 1>&2 2>&3) || STATIC_DNS="8.8.8.8,1.1.1.1"
        fi
    fi

    if [ "$OPT_TELEGRAM" = true ]; then
        TG_TOKEN=$(whiptail --title "Telegram: Токен" --inputbox \
            "Токен от @BotFather:" 10 60 3>&1 1>&2 2>&3) || TG_TOKEN=""
        TG_CHAT=$(whiptail --title "Telegram: Chat ID" --inputbox \
            "Chat ID от @userinfobot:" 10 60 3>&1 1>&2 2>&3) || TG_CHAT=""
        [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ] && OPT_TELEGRAM=false
    fi

    local summary="Будет установлено:\n\n"
    summary+="  ✔ Home Assistant Supervised (ядро)\n"
    summary+="  ✔ Docker + OS-Agent\n"
    [ "$OPT_ZRAM" = true ]          && summary+="  ✔ ZRAM Swap\n"
    [ "$OPT_EMMC_TUNING" = true ]   && summary+="  ✔ Тюнинг eMMC/SD\n"
    [ "$OPT_USB_POWER" = true ]     && summary+="  ✔ USB Power Fix\n"
    [ "$OPT_UFW" = true ]           && summary+="  ✔ UFW + Fail2Ban\n"
    [ "$OPT_SSH_HARDENING" = true ] && summary+="  ✔ SSH Hardening\n"
    [ "$OPT_AUTOUPDATE" = true ]    && summary+="  ✔ Автообновления\n"
    [ "$OPT_WATCHDOG" = true ]      && summary+="  ✔ Watchdog + Очистка + Net-recovery\n"
    [ "$OPT_THERMAL" = true ]       && summary+="  ✔ Мониторинг температуры\n"
    [ "$OPT_BACKUP" = true ]        && summary+="  ✔ Автобэкап конфигурации\n"
    [ "$OPT_HACS" = true ]          && summary+="  ✔ HACS\n"
    [ "$OPT_HOSTNAME" = true ]      && summary+="  ✔ Hostname: homeassistant\n"
    [ "$OPT_STATIC_IP" = true ]     && summary+="  ✔ Статический IP: ${STATIC_IP}\n"
    [ "$OPT_TELEGRAM" = true ]      && summary+="  ✔ Telegram\n"
    summary+="\nНачать установку?"

    whiptail --title "Подтверждение" --yesno "$summary" 26 56 \
        || { echo "Установка отменена."; exit 0; }
}

# ========================== PRE-FLIGHT ======================================

step_preflight() {
    local sid="preflight"
    is_done "$sid" && return 0
    header "ПРЕДВАРИТЕЛЬНАЯ ПРОВЕРКА"

    local errors=0 warnings=0

    local arch; arch=$(detect_arch)
    [ "$arch" = "unknown" ] \
        && { msg_error "Неподдерживаемая архитектура: $(uname -m)"; errors=$((errors+1)); } \
        || msg_ok "Архитектура: $(uname -m) (${arch})"

    local free_mb; free_mb=$(df -m / | awk 'NR==2{print $4}')
    if [ "$free_mb" -lt 4000 ]; then
        msg_error "Мало места: ${free_mb}MB (нужно ≥ 4GB)"; errors=$((errors+1))
    elif [ "$free_mb" -lt 6000 ]; then
        msg_warn "Маловато: ${free_mb}MB (рекомендуется ≥ 6GB)"; warnings=$((warnings+1))
    else msg_ok "Диск: ${free_mb}MB свободно"; fi

    local ram_mb; ram_mb=$(free -m | awk '/Mem:/{print $2}')
    if [ "$ram_mb" -lt 900 ]; then
        msg_error "Мало RAM: ${ram_mb}MB (нужно ≥ 1GB)"; errors=$((errors+1))
    elif [ "$ram_mb" -lt 1800 ]; then
        msg_warn "RAM: ${ram_mb}MB (рекомендуется ≥ 2GB)"; warnings=$((warnings+1))
    else msg_ok "RAM: ${ram_mb}MB"; fi

    local kver; kver=$(uname -r | cut -d. -f1)
    if [ "$kver" -lt 4 ]; then
        msg_error "Ядро $(uname -r) слишком старое (≥ 4.x)"; errors=$((errors+1))
    elif [ "$kver" -lt 5 ]; then
        msg_warn "Ядро $(uname -r) (рекомендуется ≥ 5.x)"; warnings=$((warnings+1))
    else msg_ok "Ядро: $(uname -r)"; fi

    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then msg_ok "cgroups: v2"
    elif [ -d /sys/fs/cgroup/unified ]; then msg_ok "cgroups: hybrid"
    else msg_warn "cgroups: v1"; warnings=$((warnings+1)); fi

    if ping -c 1 -W 5 github.com >/dev/null 2>&1; then msg_ok "Интернет: OK"
    elif ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
        msg_warn "Интернет есть, DNS может не работать"; warnings=$((warnings+1))
    else msg_error "Нет интернета"; errors=$((errors+1)); fi

    ss -tlnp 2>/dev/null | grep -q ':8123 ' \
        && { msg_warn "Порт 8123 занят!"; warnings=$((warnings+1)); } \
        || msg_ok "Порт 8123: свободен"

    for svc in apache2 nginx lighttpd; do
        systemctl is-active --quiet "$svc" 2>/dev/null && \
            { msg_warn "${svc} запущен — может конфликтовать"; warnings=$((warnings+1)); }
    done

    local temp; temp=$(get_cpu_temp)
    [ -n "$temp" ] && { [ "$temp" -ge 75 ] \
        && { msg_warn "CPU: ${temp}°C — перегрев!"; warnings=$((warnings+1)); } \
        || msg_ok "CPU: ${temp}°C"; }

    separator
    if [ $errors -gt 0 ]; then
        msg_error "Критических проблем: ${errors}"; return 1
    elif [ $warnings -gt 0 ]; then
        msg_warn "Предупреждений: ${warnings} (установка возможна)"
    else msg_ok "Все проверки пройдены"; fi

    mark_done "$sid"
}

# ========================== CHECK ==========================================

do_check() {
    header "РЕЖИМ ПРОВЕРКИ"

    local ip temp
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="н/д"
    temp=$(get_cpu_temp)

    echo -e "  ${BOLD}Система${NC}"
    msg_info "Hostname:      $(hostname 2>/dev/null)"
    msg_info "IP:            ${ip}"
    msg_info "Архитектура:   $(uname -m) ($(detect_arch))"
    msg_info "Ядро:          $(uname -r)"
    [ -n "$temp" ] && msg_info "CPU:           ${temp}°C"
    msg_info "Uptime:        $(uptime -p 2>/dev/null || uptime)"
    separator

    echo -e "  ${BOLD}Компоненты${NC}"
    command -v docker &>/dev/null \
        && msg_ok  "Docker:        $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')" \
        || msg_error "Docker:        не установлен"

    command -v gdbus &>/dev/null && \
        gdbus introspect --system --dest io.hass.os --object-path /io/hass/os &>/dev/null 2>&1 \
        && msg_ok  "OS-Agent:      активен" \
        || msg_warn "OS-Agent:      не найден / не активен"

    local ha_sup; ha_sup=$(systemctl is-active hassio-supervisor 2>/dev/null) || ha_sup="не найден"
    [ "$ha_sup" = "active" ] && msg_ok "Supervisor: ${ha_sup}" || msg_error "Supervisor: ${ha_sup}"

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^homeassistant$'; then
        local hs ht
        hs=$(docker inspect -f '{{.State.Status}}' homeassistant 2>/dev/null) || hs="?"
        ht=$(docker inspect -f '{{.State.StartedAt}}' homeassistant 2>/dev/null | cut -d. -f1) || ht=""
        msg_ok  "HA Core:       ${hs} (с ${ht})"
    else msg_error "HA Core:       контейнер не найден"; fi

    local aa; aa=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) || aa="N"
    [ "$aa" = "Y" ] && msg_ok "AppArmor: активен" || msg_warn "AppArmor: выключен"
    msg_info "NetworkManager: $(systemctl is-active NetworkManager 2>/dev/null || echo '?')"

    if [ -f "$FAKED_OS_RELEASE" ]; then
        local faked_pretty
        faked_pretty=$(grep PRETTY_NAME "$FAKED_OS_RELEASE" | cut -d'"' -f2)
        msg_info "os-release:    подменён → ${faked_pretty}"
    fi
    separator

    echo -e "  ${BOLD}Ресурсы${NC}"
    msg_info "Память:        $(free -h | awk '/Mem:/{printf "%s / %s", $3, $2}')"
    msg_info "Swap:          $(free -h | awk '/Swap:/{printf "%s / %s", $3, $2}')"
    msg_info "Диск /:        $(df -h / | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}')"
    msg_info "Нагрузка:     $(uptime | awk -F'load average:' '{print $2}')"
    command -v zramctl &>/dev/null && zramctl 2>/dev/null | grep -q '/dev/zram' && msg_ok "ZRAM: активен"
    separator

    echo -e "  ${BOLD}Контейнеры${NC}"
    if command -v docker &>/dev/null; then
        docker ps --format '  {{.Names}}|{{.Status}}' 2>/dev/null | while IFS='|' read -r n s; do
            echo "$s" | grep -q "Up" \
                && echo -e "  ${CHECK}  ${n}  ${DIM}${s}${NC}" \
                || echo -e "  ${CROSS}  ${n}  ${RED}${s}${NC}"
        done
    fi
    separator

    if [ -f "$STATE_FILE" ]; then
        echo -e "  ${BOLD}Пройденные шаги${NC}"
        while IFS= read -r s; do msg_ok "  $s"; done < "$STATE_FILE"
    else msg_dim "Установка ещё не запускалась"; fi

    if [ -d "$HA_BACKUP_DIR" ]; then
        local bc; bc=$(find "$HA_BACKUP_DIR" -name "ha_config_*.tar.gz" 2>/dev/null | wc -l)
        if [ "$bc" -gt 0 ]; then
            local lb lsz
            lb=$(ls -1t "$HA_BACKUP_DIR"/ha_config_*.tar.gz 2>/dev/null | head -1)
            lsz=$(du -sh "$lb" 2>/dev/null | awk '{print $1}')
            separator
            echo -e "  ${BOLD}Бэкапы${NC}"
            msg_info "Всего: ${bc}, последний: ${lsz}"
        fi
    fi

    separator
    echo -e "  ${BOLD}Актуальные версии (GitHub)${NC}"
    local v_oa v_ha
    v_oa=$(get_latest_release "home-assistant/os-agent")
    v_ha=$(get_latest_release "home-assistant/supervised-installer")
    [ -n "$v_oa" ] && msg_info "OS-Agent:      ${v_oa}" || msg_warn "OS-Agent:      не определена"
    [ -n "$v_ha" ] && msg_info "HA Supervised: ${v_ha}" || msg_warn "HA Supervised: не определена"
    echo ""
}

# ========================== STATUS =========================================

do_status() {
    while true; do
        clear
        show_banner
        local ip temp
        ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="н/д"
        temp=$(get_cpu_temp)
        echo -e "  ${BOLD}IP:${NC} $ip    ${BOLD}CPU:${NC} ${temp:-н/д}°C    ${BOLD}Up:${NC} $(uptime -p 2>/dev/null || echo 'н/д')"
        echo -e "  ${BOLD}RAM:${NC} $(free -h | awk '/Mem:/{printf "%s/%s", $3, $2}')    ${BOLD}Swap:${NC} $(free -h | awk '/Swap:/{printf "%s/%s", $3, $2}')"
        echo -e "  ${BOLD}Disk:${NC} $(df -h / | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}')"
        separator
        echo -e "  ${BOLD}Контейнеры:${NC}"
        docker ps --format '  {{.Names}}|{{.Status}}' 2>/dev/null | while IFS='|' read -r n s; do
            echo "$s" | grep -q "Up" \
                && echo -e "  ${CHECK}  ${n}  ${DIM}${s}${NC}" \
                || echo -e "  ${CROSS}  ${n}  ${RED}${s}${NC}"
        done
        local hh; hh=$(curl -s -o /dev/null -w "%{http_code}" -m 3 http://localhost:8123 2>/dev/null || echo 000)
        separator
        [ "$hh" != "000" ] \
            && echo -e "  ${CHECK}  HA HTTP: ${GREEN}${hh}${NC}" \
            || echo -e "  ${CROSS}  HA HTTP: ${RED}не отвечает${NC}"
        separator
        echo -e "  ${DIM}Обновление каждые 5 сек. Ctrl+C — выход.${NC}"
        sleep 5
    done
}

# ========================== UNINSTALL ======================================

do_uninstall() {
    header "УДАЛЕНИЕ HOME ASSISTANT SUPERVISED"

    local confirmed=false
    if command -v whiptail &>/dev/null; then
        whiptail --title "Подтверждение" --yesno \
            "ПОЛНОСТЬЮ удалить Home Assistant Supervised?\n\nКонтейнеры и скрипты будут удалены." 12 55 \
            && confirmed=true
    else
        echo -en " ${WARN}  ${YELLOW}Удалить HA Supervised? (yes/no): ${NC}"
        read -r c; [ "$c" = "yes" ] && confirmed=true
    fi
    [ "$confirmed" != true ] && { msg_info "Отменено."; exit 0; }

    msg_action "Остановка сервисов..."
    systemctl stop hassio-supervisor hassio-apparmor 2>/dev/null || true

    msg_action "Удаление контейнеров..."
    docker ps -a --filter "label=io.hass.type" --format '{{.Names}}' 2>/dev/null \
        | while IFS= read -r c; do docker rm -f "$c" 2>/dev/null || true; done
    for c in homeassistant hassio_supervisor hassio_cli hassio_audio hassio_dns hassio_multicast hassio_observer; do
        docker rm -f "$c" 2>/dev/null || true
    done

    msg_action "Удаление образов..."
    docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
        | grep -iE "homeassistant|hassio|home-assistant" \
        | while IFS= read -r img; do docker rmi -f "$img" 2>/dev/null || true; done

    msg_action "Удаление systemd..."
    for svc in hassio-supervisor hassio-apparmor; do
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}.service" 2>/dev/null || true
    done
    rm -rf /etc/systemd/system/hassio-supervisor.service.d 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    dpkg --purge homeassistant-supervised os-agent 2>/dev/null || true

    msg_action "Удаление скриптов..."
    rm -f /usr/local/bin/ha-{notify,watchdog,cleanup,net-recovery,backup,restore,health,thermal} 2>/dev/null || true
    rm -f /etc/cron.d/ha-tools /etc/udev/rules.d/99-ha-usb-power.rules 2>/dev/null || true
    rm -f /etc/ssh/sshd_config.d/99-ha-hardening.conf /etc/sysctl.d/99-ha-swap.conf 2>/dev/null || true
    rm -f /etc/systemd/journald.conf.d/ha-tuning.conf 2>/dev/null || true

    [ -f /etc/ufw/after.rules ] && {
        sed -i '/# BEGIN HA-INSTALLER DOCKER-USER/,/# END HA-INSTALLER DOCKER-USER/d' \
            /etc/ufw/after.rules 2>/dev/null || true
        ufw reload 2>/dev/null || true
    }

    if [ -d "$HASSIO_DIR" ]; then
        echo -en " ${WARN}  ${YELLOW}Удалить данные HA? (yes/no): ${NC}"
        read -r cd; [ "$cd" = "yes" ] && { rm -rf "$HASSIO_DIR"; msg_ok "Данные удалены"; } \
            || msg_info "Данные сохранены"
    fi
    if [ -d "$HA_BACKUP_DIR" ]; then
        echo -en " ${WARN}  ${YELLOW}Удалить бэкапы? (yes/no): ${NC}"
        read -r cb; [ "$cb" = "yes" ] && { rm -rf "$HA_BACKUP_DIR"; msg_ok "Бэкапы удалены"; } \
            || msg_info "Бэкапы сохранены"
    fi

    [ -f "${BACKUP_DIR}/os-release.original" ] && \
        cp "${BACKUP_DIR}/os-release.original" /etc/os-release && msg_ok "os-release восстановлен"
    rm -f "$FAKED_OS_RELEASE" 2>/dev/null || true

    reset_state
    docker system prune -f 2>/dev/null || true
    rm -f "$GRACE_MARKER" 2>/dev/null || true

    header "УДАЛЕНИЕ ЗАВЕРШЕНО"
    msg_info "Docker оставлен. Удаление: apt purge docker-ce docker-ce-cli containerd.io"
    echo ""
}

# ========================== АРГУМЕНТЫ =======================================

show_help() {
    cat << HELP
${BOLD}Home Assistant Supervised — Ultimate Installer v${SCRIPT_VERSION}${NC}

${BOLD}Использование:${NC}
  sudo ./install.sh              Мастер установки (TUI)
  sudo ./install.sh [ОПЦИИ]

${BOLD}Основные:${NC}
  -h, --help            Справка
  -c, --check           Диагностика
  -s, --status          Живой мониторинг
  -u, --uninstall       Удалить HA Supervised
  --reset-state         Сбросить шаги

${BOLD}Установка:${NC}
  --skip-update         Без apt update/upgrade
  --dry-run             Тестовый прогон
  --silent              Тихий режим
  --machine TYPE        Тип машины
  --os-agent-ver X      Версия OS-Agent вручную
  --ha-ver X            Версия HA Supervised вручную

${BOLD}Типы машин:${NC}
  qemuarm-64            TV-боксы / SBC (по умолчанию)
  raspberrypi5-64       Raspberry Pi 5
  raspberrypi4-64       Raspberry Pi 4
  raspberrypi3-64       Raspberry Pi 3 (64-bit)
  odroid-n2             ODROID-N2/N2+
  generic-x86-64        x86-64

${BOLD}Примеры:${NC}
  sudo ./install.sh
  sudo ./install.sh --check
  sudo ./install.sh --status
  sudo ./install.sh --machine odroid-n2
  sudo ./install.sh --os-agent-ver 1.8.1 --ha-ver 4.0.1

HELP
}

parse_args() {
    if [ $# -eq 0 ]; then return; fi
    RUN_WIZARD=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)        show_help; exit 0 ;;
            -c|--check)       CHECK_ONLY=true ;;
            -s|--status)      SHOW_STATUS=true ;;
            -u|--uninstall)   UNINSTALL=true ;;
            --reset-state)    reset_state; exit 0 ;;
            --skip-update)    SKIP_UPDATE=true ;;
            --dry-run)        DRY_RUN=true ;;
            --silent)         SILENT=true; RUN_WIZARD=false ;;
            --machine)        shift; [ $# -eq 0 ] && { msg_error "--machine требует аргумент"; exit 1; }; HA_MACHINE="$1"; MACHINE_EXPLICIT=true ;;
            --machine=*)      HA_MACHINE="${1#*=}"; MACHINE_EXPLICIT=true ;;
            --os-agent-ver)   shift; [ $# -eq 0 ] && { msg_error "--os-agent-ver требует аргумент"; exit 1; }; OVERRIDE_OS_AGENT_VER="$1" ;;
            --os-agent-ver=*) OVERRIDE_OS_AGENT_VER="${1#*=}" ;;
            --ha-ver)         shift; [ $# -eq 0 ] && { msg_error "--ha-ver требует аргумент"; exit 1; }; OVERRIDE_HA_VER="$1" ;;
            --ha-ver=*)       OVERRIDE_HA_VER="${1#*=}" ;;
            *)                msg_error "Неизвестный параметр: $1"; show_help; exit 1 ;;
        esac
        shift
    done
}

# ========================== БАННЕР ==========================================
show_banner() {
    if [ "$CHECK_ONLY" != true ] && [ "$UNINSTALL" != true ] && [ "$SHOW_STATUS" != true ]; then
        clear
    fi
    if [ "$SILENT" != true ]; then
        echo -e "${BLUE}    ╦ ╦┌─┐┌┬┐┌─┐  ╔═╗┌─┐┌─┐┬┌─┐┌┬┐┌─┐┌┐┌┌┬┐${NC}"
        echo -e "${BLUE}    ╠═╣│ ││││├┤   ╠═╣└─┐└─┐│└─┐ │ ├─┤│││ │ ${NC}"
        echo -e "${BLUE}    ╩ ╩└─┘┴ ┴└─┘  ╩ ╩└─┘└─┘┴└─┘ ┴ ┴ ┴┘└┘ ┴ ${NC}"
        echo -e "${WHITE}${BOLD}    ULTIMATE INSTALLER v${SCRIPT_VERSION}${NC}"
        separator
    fi
}

# ========================== ШАГИ УСТАНОВКИ ==================================

step_update_system() {
    local sid="update"
    is_done "$sid" && return 0
    header "ШАГ 1 — ОБНОВЛЕНИЕ СИСТЕМЫ"
    if [ "$SKIP_UPDATE" = false ]; then
        run_cmd_fatal "apt-get update" apt-get update -y
        run_cmd "apt-get upgrade" apt-get upgrade -y
    else msg_warn "Пропущено (--skip-update)"; fi
    mark_done "$sid"
}

step_install_deps() {
    local sid="deps"
    is_done "$sid" && return 0
    header "ШАГ 2 — ЗАВИСИМОСТИ"

    # Обязательные пакеты (должны быть в любом Debian/Armbian)
    local pkgs=(
        apparmor avahi-daemon bluez ca-certificates cifs-utils
        curl dbus gnupg jq libglib2.0-bin lsb-release
        network-manager nfs-common
        systemd-journal-remote systemd-resolved systemd-timesyncd
        udisks2 usbutils wget qrencode
    )

    # Условные обязательные
    [ "$OPT_ZRAM" = true ]       && pkgs+=(zram-tools)
    [ "$OPT_UFW" = true ]        && pkgs+=(ufw fail2ban)
    [ "$OPT_AUTOUPDATE" = true ] && pkgs+=(unattended-upgrades)

    # Опциональные — добавляем только если есть в репозиториях
    local optional_pkgs=(software-properties-common cpufrequtils linux-cpupower)
    for p in "${optional_pkgs[@]}"; do
        if pkg_available "$p"; then
            pkgs+=("$p")
        else
            msg_dim "Пакет ${p} недоступен в репозиториях — пропуск"
        fi
    done

    local to_install=()
    for p in "${pkgs[@]}"; do
        is_pkg_installed "$p" || to_install+=("$p")
    done

    if [ ${#to_install[@]} -eq 0 ]; then
        msg_ok "Все пакеты установлены"
    else
        msg_info "Нужно: ${#to_install[@]} из ${#pkgs[@]}"
        if run_cmd "Пакетная установка (${#to_install[@]} шт.)" \
            apt-get install -y "${to_install[@]}"; then
            msg_ok "Зависимости установлены"
        else
            msg_warn "Пакетная не удалась. По одному..."
            local failed=()
            for p in "${to_install[@]}"; do
                run_cmd "Установка $p" apt-get install -y "$p" || failed+=("$p")
            done
            [ ${#failed[@]} -gt 0 ] && msg_warn "Не установлены: ${failed[*]}"
        fi
    fi
    run_cmd "Исправление зависимостей" apt-get -f install -y
    mark_done "$sid"
}

step_configure_network() {
    local sid="network"
    is_done "$sid" && return 0
    header "ШАГ 3 — СЕТЬ И DNS"

    mkdir -p "$BACKUP_DIR" /etc/NetworkManager/conf.d
    local current_ip; current_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || current_ip=""
    [ -n "$current_ip" ] && msg_info "Текущий IP: ${current_ip}"

    cat > /etc/NetworkManager/conf.d/10-ha-managed.conf << 'EOF'
[keyfile]
unmanaged-devices=none
[device]
wifi.scan-rand-mac-address=no
EOF

    [ -f /etc/network/interfaces ] && cp /etc/network/interfaces "$BACKUP_DIR/interfaces.bak" 2>/dev/null || true
    cat > /etc/network/interfaces << 'EOF'
source /etc/network/interfaces.d/*
auto lo
iface lo inet loopback
EOF

    systemctl enable systemd-resolved 2>/dev/null || true
    systemctl start systemd-resolved 2>/dev/null || true
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || true

    who 2>/dev/null | grep -q pts && msg_warn "SSH-сессия. Сеть может кратковременно прерваться."

    msg_action "Переключение на NetworkManager..."
    systemctl disable networking 2>/dev/null || true
    systemctl enable NetworkManager 2>/dev/null || true
    systemctl restart NetworkManager 2>/dev/null || true

    if [ "$OPT_STATIC_IP" = true ] && [ -n "$STATIC_IP" ]; then
        msg_action "Статический IP: ${STATIC_IP}..."
        sleep 3
        local active_con; active_con=$(nmcli -t -f NAME con show --active 2>/dev/null | head -1) || active_con=""
        if [ -n "$active_con" ]; then
            nmcli con mod "$active_con" ipv4.addresses "${STATIC_IP}/24" ipv4.gateway "$STATIC_GW" ipv4.dns "$STATIC_DNS" ipv4.method manual 2>/dev/null
            nmcli con up "$active_con" 2>/dev/null || true
            msg_ok "Статический IP: ${STATIC_IP}"
        else msg_warn "Нет активного соединения"; fi
    fi

    msg_action "Ожидание стабилизации сети..."
    local retries=0 new_ip=""
    while [ $retries -lt 6 ]; do
        sleep 5; new_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || new_ip=""
        [ -n "$new_ip" ] && { msg_ok "Сеть: ${new_ip}"; break; }
        retries=$((retries+1)); msg_dim "Ожидание ${retries}/6..."
    done
    if [ $retries -ge 6 ]; then
        msg_error "Сеть не поднялась!"
        systemctl start networking 2>/dev/null || true; nmcli networking on 2>/dev/null || true; sleep 5
        new_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || new_ip=""
        [ -n "$new_ip" ] && msg_ok "Восстановлена: ${new_ip}" || { msg_error "Сеть не работает!"; return 1; }
    fi
    mark_done "$sid"
}

step_configure_apparmor() {
    local sid="apparmor"
    is_done "$sid" && return 0
    header "ШАГ 4 — APPARMOR"

    local aa; aa=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) || aa="N"
    if [ "$aa" = "Y" ]; then msg_ok "AppArmor активен"
    else
        msg_warn "AppArmor выключен. Патчим загрузчик..."
        local patched=false
        for f in /boot/armbianEnv.txt /boot/uEnv.txt /boot/extlinux/extlinux.conf; do
            [ -f "$f" ] || continue
            cp "$f" "${BACKUP_DIR}/$(basename "$f").bak" 2>/dev/null || true
            if grep -q "apparmor=1" "$f"; then patched=true; continue; fi
            if [[ "$f" == *extlinux.conf ]]; then
                sed -i '/^[[:space:]]*append/ s/$/ apparmor=1 security=apparmor/' "$f"
            elif grep -q "^extraargs=" "$f"; then
                sed -i 's|^extraargs=.*|& apparmor=1 security=apparmor|' "$f"
            else echo "extraargs=apparmor=1 security=apparmor" >> "$f"; fi
            msg_ok "Пропатчен: $(basename "$f")"; patched=true
        done
        [ "$patched" = false ] && msg_error "Файл загрузчика не найден!" || msg_warn "AppArmor включится после reboot"
    fi
    systemctl enable apparmor 2>/dev/null || true; systemctl start apparmor 2>/dev/null || true
    mark_done "$sid"
}

step_performance() {
    local sid="perf"
    is_done "$sid" && return 0
    header "ШАГ 5 — ПРОИЗВОДИТЕЛЬНОСТЬ И ЖЕЛЕЗО"

    # ── ZRAM / Swap ──
    if [ "$OPT_ZRAM" = true ]; then
        msg_action "ZRAM..."
        [ -f /swapfile ] && { swapoff /swapfile 2>/dev/null || true; rm -f /swapfile; sed -i '/swapfile/d' /etc/fstab; }
        cat > /etc/default/zramswap << 'EOF'
ALGO=lz4
PERCENT=60
EOF
        systemctl enable zramswap 2>/dev/null || true; systemctl restart zramswap 2>/dev/null || true
        msg_ok "ZRAM активирован"
    else
        if [ ! -f /swapfile ]; then
            if dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none 2>/dev/null \
               || dd if=/dev/zero of=/swapfile bs=1M count=2048 2>/dev/null; then
                chmod 600 /swapfile; mkswap /swapfile >/dev/null; swapon /swapfile; msg_ok "Swap 2GB"
            else msg_error "Swapfile не создан"; rm -f /swapfile 2>/dev/null || true; fi
        fi
        grep -q "swapfile" /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    # ── CPU Governor (с fallback cpufrequtils → cpupower) ──
    if command -v cpufreq-set &>/dev/null; then
        echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils
        systemctl restart cpufrequtils 2>/dev/null || true
        msg_ok "CPU: performance (cpufrequtils)"
    elif command -v cpupower &>/dev/null; then
        cpupower frequency-set -g performance 2>/dev/null || true
        msg_ok "CPU: performance (cpupower)"
    else
        msg_dim "Управление частотой CPU недоступно — пропуск"
    fi

    # ── eMMC/SD ──
    if [ "$OPT_EMMC_TUNING" = true ]; then
        msg_action "Тюнинг eMMC/SD..."
        echo "vm.swappiness=10" > /etc/sysctl.d/99-ha-swap.conf
        sysctl -p /etc/sysctl.d/99-ha-swap.conf >/dev/null 2>&1; msg_ok "swappiness=10"
        if ! grep -q "noatime" /etc/fstab 2>/dev/null; then
            cp /etc/fstab "${BACKUP_DIR}/fstab.bak" 2>/dev/null || true
            sed -i '/^\//s/defaults/defaults,noatime,commit=600/' /etc/fstab 2>/dev/null || true; msg_ok "noatime"
        fi
        mkdir -p /etc/systemd/journald.conf.d
        cat > /etc/systemd/journald.conf.d/ha-tuning.conf << 'JRNL'
[Journal]
SystemMaxUse=50M
SystemMaxFileSize=10M
MaxRetentionSec=7day
Compress=yes
Storage=volatile
JRNL
        systemctl restart systemd-journald 2>/dev/null || true; msg_ok "journald: volatile 50MB"
        local rootdev; rootdev=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null | head -1) || rootdev=""
        if [ -n "$rootdev" ] && [ -f "/sys/block/${rootdev}/queue/rotational" ]; then
            [ "$(cat "/sys/block/${rootdev}/queue/rotational" 2>/dev/null)" = "0" ] && \
                echo "none" > "/sys/block/${rootdev}/queue/scheduler" 2>/dev/null && msg_ok "IO: none"
        fi
    fi

    # ── USB Power ──
    if [ "$OPT_USB_POWER" = true ]; then
        for dev in /sys/bus/usb/devices/*/power/autosuspend; do
            [ -f "$dev" ] && echo -1 > "$dev" 2>/dev/null || true
        done
        cat > /etc/udev/rules.d/99-ha-usb-power.rules << 'UDEV'
ACTION=="add", SUBSYSTEM=="usb", ATTR{power/autosuspend}="-1"
UDEV
        udevadm control --reload-rules 2>/dev/null || true; msg_ok "USB autosuspend off"
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
        # Удаление старых версий (ошибки игнорируются — пакетов может не быть)
        apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

        spinner_start "Установка Docker"
        # Не проверяем exit code — get.docker.com может вернуть !=0 при предупреждениях
        curl -fsSL https://get.docker.com 2>/dev/null | sh >/dev/null 2>&1 || true
        spinner_stop

        # Обновляем хеш-таблицу PATH
        hash -r 2>/dev/null || true

        # Проверяем результат по наличию бинарника, а не по exit code
        if ! command -v docker &>/dev/null; then
            msg_warn "get.docker.com не установил docker. Попытка через apt..."
            apt-get update -qq 2>/dev/null || true
            if apt-get install -y docker-ce docker-ce-cli containerd.io >/dev/null 2>&1; then
                msg_ok "Docker установлен через apt"
            else
                msg_error "Docker не удалось установить"
                msg_dim "Установите вручную: curl -fsSL https://get.docker.com | sh"
                exit 1
            fi
        else
            msg_ok "Docker установлен"
        fi
    fi

    mkdir -p /etc/docker
    [ ! -f /etc/docker/daemon.json ] && cat > /etc/docker/daemon.json << 'EOF'
{ "log-driver": "journald", "storage-driver": "overlay2" }
EOF

    systemctl enable docker 2>/dev/null || true
    systemctl restart docker 2>/dev/null || true

    # Финальная проверка — Docker должен отвечать
    local docker_wait=0
    while ! docker info &>/dev/null; do
        sleep 2; docker_wait=$((docker_wait+2))
        if [ $docker_wait -ge 30 ]; then
            msg_error "Docker установлен, но не отвечает"
            msg_dim "Проверьте: systemctl status docker"
            exit 1
        fi
    done
    msg_ok "Docker: $(docker --version | awk '{print $3}' | tr -d ',')"
    mark_done "$sid"
}

step_install_os_agent() {
    local sid="osagent"
    is_done "$sid" && return 0
    header "ШАГ 7 — OS-AGENT"

    local arch; arch=$(detect_arch)
    [ "$arch" = "unknown" ] && { msg_error "Неизвестная архитектура: $(uname -m)"; exit 1; }

    local v=""
    if [ -n "$OVERRIDE_OS_AGENT_VER" ]; then
        v="$OVERRIDE_OS_AGENT_VER"; msg_info "Версия (вручную): ${v}"
    else
        msg_action "Определение версии OS-Agent..."
        v=$(get_latest_release "home-assistant/os-agent")
    fi
    if [ -z "$v" ]; then
        msg_error "Не удалось определить версию OS-Agent"
        msg_warn "Причины: rate-limit / DNS / прокси"
        msg_dim "Проверьте: curl -sI https://github.com/home-assistant/os-agent/releases/latest"
        msg_dim "Или: sudo ./install.sh --os-agent-ver 1.8.1"
        exit 1
    fi

    msg_info "Архитектура: ${arch}, версия: ${v}"
    download_file \
        "https://github.com/home-assistant/os-agent/releases/download/${v}/os-agent_${v}_linux_${arch}.deb" \
        "/tmp/os-agent.deb" "OS-Agent ${v} (${arch})"
    run_cmd_fatal "Установка OS-Agent" dpkg -i /tmp/os-agent.deb

    command -v gdbus &>/dev/null && \
        gdbus introspect --system --dest io.hass.os --object-path /io/hass/os &>/dev/null 2>&1 \
        && msg_ok "OS-Agent: D-Bus OK" || msg_warn "OS-Agent установлен (D-Bus ответит позже)"
    mark_done "$sid"
}

step_install_ha() {
    local sid="ha"
    is_done "$sid" && return 0
    header "ШАГ 8 — HOME ASSISTANT SUPERVISED"

    mkdir -p "$BACKUP_DIR"
    [ ! -f "${BACKUP_DIR}/os-release.original" ] && cp /etc/os-release "${BACKUP_DIR}/os-release.original"

    local v=""
    if [ -n "$OVERRIDE_HA_VER" ]; then
        v="$OVERRIDE_HA_VER"; msg_info "Версия HA (вручную): ${v}"
    else
        msg_action "Определение версии HA Supervised..."
        v=$(get_latest_release "home-assistant/supervised-installer")
    fi
    if [ -z "$v" ]; then
        msg_error "Не удалось определить версию HA Supervised"
        msg_dim "Проверьте: curl -sI https://github.com/home-assistant/supervised-installer/releases/latest"
        msg_dim "Или: sudo ./install.sh --ha-ver 4.0.1"
        exit 1
    fi

    # Генерируем os-release в зависимости от major-версии HA
    generate_os_release "$v" > /etc/os-release
    cp /etc/os-release "$FAKED_OS_RELEASE"

    local faked_pretty
    faked_pretty=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
    msg_ok "os-release → ${faked_pretty}"

    download_file \
        "https://github.com/home-assistant/supervised-installer/releases/download/${v}/homeassistant-supervised.deb" \
        "/tmp/ha.deb" "HA Supervised ${v}"

    msg_action "Установка контейнеров (5-15 минут)..."
    msg_dim "Машина: ${HA_MACHINE}"
    export MACHINE="$HA_MACHINE"

    set +o pipefail
    DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/ha.deb 2>&1 \
        | grep --line-buffered -iE "(pull|download|unpack|setting up|error|warn)" \
        | grep -vi "cgroup v1" \
        | while IFS= read -r line; do echo -e "    ${BLUE}│${NC} ${line}"; done
    local de=${PIPESTATUS[0]}
    set -o pipefail

    [ $de -ne 0 ] && { msg_warn "dpkg код ${de}, исправление..."; apt-get install -f -y >/dev/null 2>&1 || true; }

    # Drop-in: восстанавливает os-release из сохранённой копии перед стартом
    mkdir -p /etc/systemd/system/hassio-supervisor.service.d
    cat > /etc/systemd/system/hassio-supervisor.service.d/fix-os-release.conf << 'DROPIN'
[Service]
ExecStartPre=/bin/bash -c 'FAKED="/root/.ha_install_backup/os-release.faked"; [ -f "$FAKED" ] && cp "$FAKED" /etc/os-release'
DROPIN
    systemctl daemon-reload

    msg_action "Ожидание hassio-supervisor..."
    local sw=0
    while ! systemctl is-active --quiet hassio-supervisor 2>/dev/null; do
        sleep 5; sw=$((sw+5))
        [ $sw -ge 120 ] && { msg_warn "Supervisor не запустился за 2 мин"; break; }
        [ $((sw % 15)) -eq 0 ] && msg_dim "Ждём ${sw}с..."
    done
    [ $sw -lt 120 ] && msg_ok "hassio-supervisor активен"

    touch "$GRACE_MARKER"
    msg_ok "Home Assistant Supervised установлен"
    mark_done "$sid"
}

step_security() {
    local sid="sec"
    is_done "$sid" && return 0
    header "ШАГ 9 — БЕЗОПАСНОСТЬ"
    local anything=false

    if [ "$OPT_UFW" = true ]; then
        anything=true; msg_action "UFW..."
        ufw --force reset >/dev/null 2>&1
        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1
        ufw default allow routed >/dev/null 2>&1
        ufw allow 22/tcp comment 'SSH' >/dev/null 2>&1
        ufw allow 8123/tcp comment 'HA' >/dev/null 2>&1
        ufw allow 4357/tcp comment 'ESPHome' >/dev/null 2>&1
        ufw allow 5353/udp comment 'mDNS' >/dev/null 2>&1
        ufw allow 5683/udp comment 'HomeKit' >/dev/null 2>&1
        ufw --force enable >/dev/null 2>&1; msg_ok "UFW активирован"

        if ! grep -q "# BEGIN HA-INSTALLER DOCKER-USER" /etc/ufw/after.rules 2>/dev/null; then
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
            ufw reload >/dev/null 2>&1; msg_ok "DOCKER-USER: только LAN"
        fi

        cat > /etc/fail2ban/jail.local << 'EOF'
[sshd]
enabled=true
port=ssh
filter=sshd
logpath=/var/log/auth.log
maxretry=5
bantime=3600
findtime=600
EOF
        systemctl enable fail2ban 2>/dev/null || true
        systemctl restart fail2ban 2>/dev/null || true; msg_ok "Fail2Ban: SSH"
    fi

    if [ "$OPT_SSH_HARDENING" = true ]; then
        anything=true
        mkdir -p /etc/ssh/sshd_config.d
        cp /etc/ssh/sshd_config "${BACKUP_DIR}/sshd_config.bak" 2>/dev/null || true
        cat > /etc/ssh/sshd_config.d/99-ha-hardening.conf << 'SSH'
PermitRootLogin prohibit-password
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
SSH
        systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
        msg_ok "SSH hardening"
    fi

    if [ "$OPT_AUTOUPDATE" = true ]; then
        anything=true
        cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'UPG'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
UPG
        cat > /etc/apt/apt.conf.d/20auto-upgrades << 'AUTO'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUTO
        msg_ok "Автообновления безопасности"
    fi

    [ "$anything" = false ] && msg_warn "Безопасность: пропущено"
    mark_done "$sid"
}

step_extras() {
    local sid="extras"
    is_done "$sid" && return 0
    header "ШАГ 10 — УТИЛИТЫ И МОНИТОРИНГ"
    local anything=false

    if [ "$OPT_HOSTNAME" = true ]; then
        anything=true; hostnamectl set-hostname homeassistant 2>/dev/null || true; msg_ok "Hostname: homeassistant"
    fi
    systemctl enable avahi-daemon >/dev/null 2>&1; systemctl start avahi-daemon >/dev/null 2>&1
    msg_ok "mDNS: $(hostname).local"

    cat > /usr/local/bin/ha-notify << TGNOTIFY
#!/bin/bash
T="${TG_TOKEN}"
C="${TG_CHAT}"
[ -z "\$T" ] || [ -z "\$C" ] && exit 0
MSG="\${1:-Без текста}"
curl -s -X POST "https://api.telegram.org/bot\$T/sendMessage" \\
    --data-urlencode "chat_id=\$C" \\
    --data-urlencode "text=🏠 *HA (\$(hostname)):* \$MSG" \\
    --data-urlencode "parse_mode=Markdown" >/dev/null 2>&1
TGNOTIFY
    chmod +x /usr/local/bin/ha-notify
    [ "$OPT_TELEGRAM" = true ] && msg_ok "Telegram настроен" || msg_dim "Telegram не настроен"

    if [ "$OPT_WATCHDOG" = true ]; then
        anything=true
        cat > /usr/local/bin/ha-watchdog << 'WD'
#!/bin/bash
GRACE_FILE="/tmp/.ha_just_installed"
if [ -f "$GRACE_FILE" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$GRACE_FILE" 2>/dev/null || echo 0) ))
    [ $age -lt 1200 ] && exit 0; rm -f "$GRACE_FILE"
fi
FAIL_FILE="/tmp/ha_wd_fails"
fail=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 http://localhost:8123 2>/dev/null || echo 000)
if [ "$code" = "000" ]; then
    fail=$((fail+1)); echo "$fail" > "$FAIL_FILE"
    if [ "$fail" -ge 3 ]; then
        logger -t ha-watchdog "HA не отвечает ($fail). Рестарт..."
        docker restart homeassistant 2>/dev/null || true
        /usr/local/bin/ha-notify "⚠️ Watchdog перезапустил HA (${fail} пропусков)"
        echo 0 > "$FAIL_FILE"
    fi
else echo 0 > "$FAIL_FILE"; fi
WD
        chmod +x /usr/local/bin/ha-watchdog

        cat > /usr/local/bin/ha-cleanup << 'CLN'
#!/bin/bash
free_mb=$(df -m / | awk 'NR==2{print $4}')
if [ "$free_mb" -lt 1500 ]; then
    logger -t ha-cleanup "Мало места: ${free_mb}MB"
    docker system prune -f 2>/dev/null || true
    journalctl --vacuum-size=30M 2>/dev/null || true
    apt-get clean 2>/dev/null || true
    rm -f /tmp/os-agent.deb /tmp/ha.deb 2>/dev/null || true
    new_free=$(df -m / | awk 'NR==2{print $4}')
    /usr/local/bin/ha-notify "🧹 Очистка: ${free_mb}MB → ${new_free}MB"
fi
CLN
        chmod +x /usr/local/bin/ha-cleanup

        cat > /usr/local/bin/ha-net-recovery << 'NETR'
#!/bin/bash
GW=$(ip route 2>/dev/null | awk '/default/{print $3}' | head -1)
[ -z "$GW" ] && GW="8.8.8.8"
if ! ping -c 2 -W 3 "$GW" >/dev/null 2>&1; then
    if ! ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
        logger -t ha-net "Сеть недоступна"
        nmcli networking off 2>/dev/null; sleep 3; nmcli networking on 2>/dev/null; sleep 5
        ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1 \
            && /usr/local/bin/ha-notify "🌐 Сеть восстановлена" \
            || /usr/local/bin/ha-notify "🔴 Сеть не восстанавливается!"
    fi
fi
NETR
        chmod +x /usr/local/bin/ha-net-recovery
        msg_ok "Watchdog + Очистка + Net-recovery"
    fi

    if [ "$OPT_THERMAL" = true ]; then
        anything=true
        cat > /usr/local/bin/ha-thermal << 'THERMAL'
#!/bin/bash
[ ! -f /sys/class/thermal/thermal_zone0/temp ] && exit 0
temp=$(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 ))
if [ "$temp" -ge 80 ]; then
    logger -t ha-thermal "КРИТИЧНО: ${temp}°C!"
    /usr/local/bin/ha-notify "🔥 CPU: ${temp}°C!"
elif [ "$temp" -ge 70 ]; then
    logger -t ha-thermal "CPU ${temp}°C"
    /usr/local/bin/ha-notify "🌡️ CPU ${temp}°C — троттлинг"
fi
THERMAL
        chmod +x /usr/local/bin/ha-thermal; msg_ok "Мониторинг температуры"
    fi

    cat > /usr/local/bin/ha-health << 'HEALTH'
#!/bin/bash
echo "===== HA Health Report ($(date)) ====="
echo "── Система ──"
printf "  %-14s %s\n" "Hostname:" "$(hostname)"
printf "  %-14s %s\n" "IP:" "$(hostname -I | awk '{print $1}')"
printf "  %-14s %s\n" "Uptime:" "$(uptime -p 2>/dev/null || uptime)"
printf "  %-14s %s\n" "Ядро:" "$(uname -r)"
echo "── CPU ──"
[ -f /sys/class/thermal/thermal_zone0/temp ] && \
    printf "  %-14s %d°C\n" "Температура:" "$(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 ))"
printf "  %-14s%s\n" "Нагрузка:" "$(uptime | awk -F'load average:' '{print $2}')"
echo "── Память ──"
free -h | awk '/Mem:/{printf "  %-14s %s / %s\n", "RAM:", $3, $2}'
free -h | awk '/Swap:/{printf "  %-14s %s / %s\n", "Swap:", $3, $2}'
echo "── Диск ──"
df -h / | awk 'NR==2{printf "  %-14s %s / %s (%s)\n", "Корень:", $3, $2, $5}'
echo "── Контейнеры ──"
docker ps --format "  {{.Names}}: {{.Status}}" 2>/dev/null || echo "  Docker недоступен"
echo "── HA ──"
printf "  %-14s %s\n" "HTTP:" "$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://localhost:8123 2>/dev/null || echo 000)"
docker inspect -f '{{.State.StartedAt}}' homeassistant &>/dev/null 2>&1 && \
    printf "  %-14s %s\n" "Запущен:" "$(docker inspect -f '{{.State.StartedAt}}' homeassistant | cut -d. -f1)"
echo "============================================="
HEALTH
    chmod +x /usr/local/bin/ha-health; msg_ok "ha-health"

    if [ "$OPT_BACKUP" = true ]; then
        anything=true; mkdir -p "$HA_BACKUP_DIR"
        cat > /usr/local/bin/ha-backup << 'BACKUP'
#!/bin/bash
BACKUP_DIR="/root/ha-backups"; HASSIO_DIR="/usr/share/hassio"; KEEP_DAYS=30
TS=$(date +%Y%m%d_%H%M%S); mkdir -p "$BACKUP_DIR"
[ ! -d "${HASSIO_DIR}/homeassistant" ] && { logger -t ha-backup "Конфиг не найден"; exit 1; }
tar czf "${BACKUP_DIR}/ha_config_${TS}.tar.gz" \
    --exclude='*.db' --exclude='*.db-shm' --exclude='*.db-wal' \
    --exclude='home-assistant_v2.db*' --exclude='tts' --exclude='deps' --exclude='__pycache__' \
    -C "$HASSIO_DIR" homeassistant 2>/dev/null
find "$BACKUP_DIR" -name "ha_config_*.tar.gz" -mtime +${KEEP_DAYS} -delete 2>/dev/null
SIZE=$(du -sh "${BACKUP_DIR}/ha_config_${TS}.tar.gz" 2>/dev/null | awk '{print $1}')
logger -t ha-backup "Бэкап: ${SIZE}"
/usr/local/bin/ha-notify "💾 Бэкап: ${SIZE}"
BACKUP
        chmod +x /usr/local/bin/ha-backup

        cat > /usr/local/bin/ha-restore << 'RESTORE'
#!/bin/bash
BACKUP_DIR="/root/ha-backups"; HASSIO_DIR="/usr/share/hassio"
mapfile -t files < <(ls -1t "$BACKUP_DIR"/ha_config_*.tar.gz 2>/dev/null)
[ ${#files[@]} -eq 0 ] && { echo "Бэкапы не найдены"; exit 1; }
echo "Доступные бэкапы:"
for i in "${!files[@]}"; do
    sz=$(du -sh "${files[$i]}" 2>/dev/null | awk '{print $1}')
    printf "  %d) %s (%s)\n" "$((i+1))" "$(basename "${files[$i]}")" "$sz"
done
read -p "Номер: " choice
[[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#files[@]} ] && { echo "Неверный"; exit 1; }
file="${files[$((choice-1))]}"
read -p "Восстановить из $(basename "$file")? (yes/no): " confirm
[ "$confirm" != "yes" ] && { echo "Отменено"; exit 0; }
docker stop homeassistant 2>/dev/null
tar xzf "$file" -C "$HASSIO_DIR"
docker start homeassistant 2>/dev/null
echo "Готово!"
RESTORE
        chmod +x /usr/local/bin/ha-restore
        msg_ok "Автобэкап (вс 4:00, 30 дн)"
    fi

    # Cron — динамический
    {
        echo "# HA maintenance (v${SCRIPT_VERSION})"
        [ "$OPT_WATCHDOG" = true ] && echo "*/5 * * * *  root /usr/local/bin/ha-watchdog >/dev/null 2>&1"
        [ "$OPT_WATCHDOG" = true ] && echo "*/10 * * * * root /usr/local/bin/ha-net-recovery >/dev/null 2>&1"
        [ "$OPT_WATCHDOG" = true ] && echo "30 3 * * *   root /usr/local/bin/ha-cleanup >/dev/null 2>&1"
        [ "$OPT_THERMAL" = true ]  && echo "*/5 * * * *  root /usr/local/bin/ha-thermal >/dev/null 2>&1"
        [ "$OPT_BACKUP" = true ]   && echo "0 4 * * 0    root /usr/local/bin/ha-backup >/dev/null 2>&1"
    } > /etc/cron.d/ha-tools
    chmod 644 /etc/cron.d/ha-tools; msg_ok "Cron настроен"

    [ "$anything" = false ] && msg_warn "Утилиты: пропущено"
    mark_done "$sid"
}

step_hacs() {
    local sid="hacs"
    is_done "$sid" && return 0
    header "ШАГ 11 — HACS"
    [ "$OPT_HACS" != true ] && { msg_warn "HACS пропущен"; mark_done "$sid"; return 0; }

    msg_action "Ожидание конфигурации HA (до 5 мин)..."
    local w=0
    while [ ! -f "${HASSIO_DIR}/homeassistant/configuration.yaml" ]; do
        sleep 5; w=$((w+5))
        [ $w -gt 300 ] && { msg_warn "Таймаут. HACS позже:"; msg_dim "docker exec homeassistant bash -c 'wget -O - https://get.hacs.xyz | bash -'"; mark_done "$sid"; return 0; }
        [ $((w % 30)) -eq 0 ] && msg_dim "Ждём ${w}с..."
    done; msg_ok "configuration.yaml найден"

    local cw=0
    while ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^homeassistant$'; do
        sleep 5; cw=$((cw+5))
        [ $cw -gt 120 ] && { msg_warn "Контейнер не найден"; mark_done "$sid"; return 0; }
    done

    msg_action "Установка HACS (таймаут 2 мин)..."
    if timeout 120 docker exec homeassistant bash -c "wget -q -O - https://get.hacs.xyz | bash -" >/dev/null 2>&1; then
        msg_ok "HACS установлен"
    else msg_warn "Таймаут. Установите позже."; mark_done "$sid"; return 0; fi

    docker restart homeassistant >/dev/null 2>&1
    msg_ok "HACS интегрирован! Настройки → Интеграции → + HACS"
    mark_done "$sid"
}

# ========================== ФИНАЛ ==========================================

show_final() {
    local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"

    header "УСТАНОВКА ЗАВЕРШЕНА!"
    echo -e "  ${BOLD}Доступ к Home Assistant:${NC}\n"
    echo -e "  ${GREEN}➜  http://${ip}:8123${NC}"
    [ "$OPT_HOSTNAME" = true ] && echo -e "  ${GREEN}➜  http://homeassistant.local:8123${NC}"
    echo ""

    if command -v qrencode &>/dev/null && [ "$SILENT" != true ]; then
        echo -e "  ${BOLD}QR:${NC}\n"; qrencode -m 2 -t ANSIUTF8 "http://${ip}:8123"; echo ""
    fi

    separator
    echo -e "  ${BOLD}Компоненты:${NC}"
    echo -e "  ${CHECK}  Home Assistant Supervised (${HA_MACHINE})"
    echo -e "  ${CHECK}  Docker + OS-Agent"
    [ "$OPT_ZRAM" = true ]          && echo -e "  ${CHECK}  ZRAM Swap"
    [ "$OPT_EMMC_TUNING" = true ]   && echo -e "  ${CHECK}  Тюнинг eMMC/SD"
    [ "$OPT_USB_POWER" = true ]     && echo -e "  ${CHECK}  USB Power Fix"
    [ "$OPT_UFW" = true ]           && echo -e "  ${CHECK}  UFW + Fail2Ban + DOCKER-USER"
    [ "$OPT_SSH_HARDENING" = true ] && echo -e "  ${CHECK}  SSH Hardening"
    [ "$OPT_AUTOUPDATE" = true ]    && echo -e "  ${CHECK}  Автообновления"
    [ "$OPT_WATCHDOG" = true ]      && echo -e "  ${CHECK}  Watchdog + Очистка + Net-recovery"
    [ "$OPT_THERMAL" = true ]       && echo -e "  ${CHECK}  Мониторинг температуры"
    [ "$OPT_BACKUP" = true ]        && echo -e "  ${CHECK}  Автобэкап (вс 4:00)"
    [ "$OPT_HACS" = true ]          && echo -e "  ${CHECK}  HACS"
    [ "$OPT_HOSTNAME" = true ]      && echo -e "  ${CHECK}  Hostname: homeassistant"
    [ "$OPT_STATIC_IP" = true ]     && echo -e "  ${CHECK}  Статический IP: ${STATIC_IP}"
    [ "$OPT_TELEGRAM" = true ]      && echo -e "  ${CHECK}  Telegram"

    if [ -f "$FAKED_OS_RELEASE" ]; then
        local fp; fp=$(grep PRETTY_NAME "$FAKED_OS_RELEASE" | cut -d'"' -f2)
        echo -e "  ${CHECK}  os-release: ${fp}"
    fi
    separator

    echo -e "\n  ${BOLD}Команды:${NC}"
    echo -e "  ${DIM}ha-health${NC}     — сводка состояния"
    [ "$OPT_BACKUP" = true ] && echo -e "  ${DIM}ha-backup${NC}     — бэкап" && echo -e "  ${DIM}ha-restore${NC}    — восстановление"

    local aa; aa=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) || aa="N"
    [ "$aa" != "Y" ] && { echo ""; msg_warn "AppArmor требует перезагрузки!"; echo -e "  ${YELLOW}sudo reboot${NC}"; }

    echo ""
    echo -e "  ${YELLOW}Инициализация HA: 10-15 минут.${NC}"
    echo -e "  ${YELLOW}Дождитесь экрана создания аккаунта.${NC}\n"

    [ "$OPT_TELEGRAM" = true ] && /usr/local/bin/ha-notify "✅ Установка завершена! http://${ip}:8123" 2>/dev/null || true
    msg_info "Лог: ${LOG_FILE}"
    echo ""
}

# ========================== MAIN ============================================

main() {
    parse_args "$@"
    [ "$EUID" -ne 0 ] && { echo -e "${RED}Запустите от root (sudo)${NC}"; exit 1; }

    if [ "$CHECK_ONLY" = true ]; then show_banner; do_check; exit 0; fi
    if [ "$SHOW_STATUS" = true ]; then do_status; exit 0; fi
    if [ "$UNINSTALL" = true ]; then show_banner; acquire_lock; do_uninstall; exit 0; fi

    [ "$RUN_WIZARD" = true ] && [ "$DRY_RUN" = false ] && run_wizard

    show_banner
    setup_logging

    [ "$MACHINE_EXPLICIT" = false ] && HA_MACHINE=$(detect_machine_type)
    msg_info "Платформа: ${HA_MACHINE} ($(uname -m))"

    acquire_lock

    step_preflight || { msg_error "Предварительные проверки не пройдены."; exit 1; }
    step_update_system
    step_install_deps
    step_configure_network || { msg_error "Сеть не работает."; exit 1; }
    step_configure_apparmor
    step_performance
    step_install_docker
    step_install_os_agent
    step_install_ha
    step_security
    step_extras
    step_hacs
    show_final
}

main "$@"
