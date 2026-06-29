#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2086
# ============================================================================
# Hassify - Ultimate Home Assistant Supervised Installer
# Version: 24
# Platform: TV-Boxes & SBC (Armbian Bookworm/Trixie / aarch64 / x86_64)
# License: MIT
# Repository: https://github.com/iRespect777/Hassify
# ============================================================================
if [ -z "$BASH_VERSION" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "Requires bash >= 4.0"; exit 1
fi

readonly SCRIPT_VERSION="24"
readonly HA_DEFAULT_MACHINE="qemuarm-64"
readonly INSTALLER_REPO="iRespect777/hassify"
readonly HA_INSTALLER_DIR="/var/lib/hassify"
readonly STATE_FILE="${HA_INSTALLER_DIR}/state"
readonly BACKUP_DIR="${HA_INSTALLER_DIR}/backup"
readonly HA_CONFIG_FILE="${HA_INSTALLER_DIR}/config"
readonly HA_BACKUP_DIR="/var/backups/homeassistant"
readonly LOCK_FILE="/var/lock/hassify.lock"
readonly LOG_DIR="/var/log"
readonly HASSIO_DIR="/usr/share/hassio"
readonly GRACE_MARKER="/tmp/.hassify_just_installed"
readonly FAKED_OS_RELEASE="${BACKUP_DIR}/os-release.faked"
readonly METRICS_DIR="/var/lib/prometheus/node-exporter"
readonly HA_SUPPORTED_CODENAMES="bookworm bullseye trixie"
readonly HISTORY_FILE="${HA_INSTALLER_DIR}/history"
readonly REBOOT_CONTINUE_SVC="hassify-continue"
readonly REBOOT_ATTEMPT_FILE="${HA_INSTALLER_DIR}/reboot_attempts"
readonly HA_INFO_FILE="${HA_INSTALLER_DIR}/hassify-info.txt"
readonly SAFE_SCRIPT_PATH="/usr/local/bin/hassify"

set -uo pipefail

# --- Colors ---
if [ -t 1 ]; then
  RED='\033[0;31m'    GREEN='\033[0;32m'
  YELLOW='\033[1;33m' BLUE='\033[0;34m'
  CYAN='\033[0;36m'   WHITE='\033[1;37m'
  BOLD='\033[1m'      DIM='\033[2m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN=''
  WHITE='' BOLD='' DIM='' NC=''
fi

CHECK="${GREEN}+${NC}"  CROSS="${RED}x${NC}"
ARROW="${CYAN}>${NC}"   WARN="${YELLOW}!${NC}"
INFO="${BLUE}i${NC}"

# --- Global state ---
RUN_WIZARD=true
OPT_ZRAM=true;         OPT_EMMC_TUNING=true;   OPT_USB_POWER=true
OPT_UFW=true;          OPT_SSH_HARDENING=true;  OPT_AUTOUPDATE=true
OPT_WATCHDOG=true;     OPT_THERMAL=true;        OPT_BACKUP=true
OPT_HACS=true;         OPT_HOSTNAME=true;       OPT_STATIC_IP=false
OPT_TELEGRAM=false;    OPT_TAILSCALE=false;  OPT_MONITORING=false
OPT_REMOTE_BACKUP=false; OPT_BOOT_RECOVERY=true; OPT_USB_DETECT=true

STATIC_IP=""; STATIC_GW=""; STATIC_DNS=""
TG_TOKEN=""; TG_CHAT=""
TS_AUTHKEY=""; REMOTE_BACKUP_TARGET=""
BOOT_DIR=""
BOOT_DEV_FSTAB=""
OPT_CLOUDFLARED=false
CF_TUNNEL_TOKEN=""
SKIP_UPDATE=false; CHECK_ONLY=false; UNINSTALL=false
DRY_RUN=false; SILENT=false; SHOW_STATUS=false
DO_UPDATE=false; DO_SELF_TEST=false; DO_SELF_UPDATE=false
DO_EXPORT_CONFIG=false; DO_SHOW_HISTORY=false; DO_BENCHMARK=false
DO_RESCUE=false
INTERACTIVE_STEPS=false
HA_MACHINE="$HA_DEFAULT_MACHINE"; MACHINE_EXPLICIT=false
OVERRIDE_OS_AGENT_VER=""; OVERRIDE_HA_VER=""
LOG_FILE=""; LOGGING_ACTIVE=false; TEE_PID=""
OS_RELEASE_FAKED=false; DAEMON_RELOAD_NEEDED=false
PREFETCH_PID=""; HA_TMP="/tmp/hassify"; INSTALL_START=""
PROFILE=""; FROM_STEP=""; IMPORT_CONFIG=""
CURRENT_STEP_NUM=0

# v9.0+ options
OPT_TIMEZONE=""; OPT_DATA_DIR=""; OPT_WIFI_SSID=""; OPT_WIFI_PASS=""
OPT_WEBHOOK_URL=""; OPT_SWAP_SIZE=""; OPT_DOCKER_MIRROR=""
OPT_RESTORE_BACKUP=""; OPT_AUTO_REBOOT=false; OPT_LOCALE=""

SYSTEM_INFO_LOADED=false
CACHED_CODENAME=""; CACHED_VERSION_ID=""
CACHED_ARCH=""; CACHED_MACHINE_ARCH=""
CACHED_PRETTY_NAME=""; CACHED_OS_ID=""

BENCH_RAM_MB=0
BENCH_CPU_CORES=0
BENCH_DISK_SPEED=""
BENCH_VERDICT=""

declare -A RELEASE_CACHE
RESOLVED_OA_VER=""; RESOLVED_HA_VER=""
declare -a ROLLBACK_ACTIONS=()
declare -A STEP_TIMES=()

declare -A STEP_DEPS=(
  [preflight]="" [update]="preflight" [deps]="update" [network]="deps"
  [apparmor]="deps" [perf]="deps" [docker]="deps" [versions]="docker"
  [download]="versions" [osagent]="download" [ha]="osagent network apparmor"
  [sec]="ha" [extras]="ha" [hacs]="extras" [postrestore]="hacs"
)

readonly ALL_STEPS=(preflight update deps network apparmor perf docker versions download osagent ha sec extras hacs postrestore)
readonly TOTAL_STEPS=${#ALL_STEPS[@]}

declare -A PROFILES=(
  [minimal]="OPT_ZRAM=true OPT_EMMC_TUNING=false OPT_USB_POWER=false OPT_UFW=false OPT_SSH_HARDENING=false OPT_AUTOUPDATE=false OPT_WATCHDOG=false OPT_THERMAL=false OPT_BACKUP=false OPT_HACS=false OPT_HOSTNAME=true OPT_MONITORING=false OPT_TAILSCALE=false OPT_CLOUDFLARED=false OPT_REMOTE_BACKUP=false OPT_BOOT_RECOVERY=false OPT_USB_DETECT=false"
  [standard]="OPT_ZRAM=true OPT_EMMC_TUNING=true OPT_USB_POWER=true OPT_UFW=true OPT_SSH_HARDENING=true OPT_AUTOUPDATE=true OPT_WATCHDOG=true OPT_THERMAL=true OPT_BACKUP=true OPT_HACS=true OPT_HOSTNAME=true OPT_MONITORING=false OPT_TAILSCALE=false OPT_CLOUDFLARED=false OPT_REMOTE_BACKUP=false OPT_BOOT_RECOVERY=true OPT_USB_DETECT=true"
  [full]="OPT_ZRAM=true OPT_EMMC_TUNING=true OPT_USB_POWER=true OPT_UFW=true OPT_SSH_HARDENING=true OPT_AUTOUPDATE=true OPT_WATCHDOG=true OPT_THERMAL=true OPT_BACKUP=true OPT_HACS=true OPT_HOSTNAME=true OPT_MONITORING=true OPT_TAILSCALE=true OPT_CLOUDFLARED=true OPT_REMOTE_BACKUP=true OPT_BOOT_RECOVERY=true OPT_USB_DETECT=true"
  [server]="OPT_ZRAM=true OPT_EMMC_TUNING=true OPT_USB_POWER=true OPT_UFW=true OPT_SSH_HARDENING=true OPT_AUTOUPDATE=true OPT_WATCHDOG=true OPT_THERMAL=true OPT_BACKUP=true OPT_HACS=true OPT_HOSTNAME=true OPT_STATIC_IP=true OPT_MONITORING=true OPT_TAILSCALE=true OPT_CLOUDFLARED=false OPT_REMOTE_BACKUP=false OPT_BOOT_RECOVERY=true OPT_USB_DETECT=true"
  [dev]="OPT_ZRAM=false OPT_EMMC_TUNING=false OPT_USB_POWER=false OPT_UFW=false OPT_SSH_HARDENING=false OPT_AUTOUPDATE=false OPT_WATCHDOG=false OPT_THERMAL=false OPT_BACKUP=false OPT_HACS=true OPT_HOSTNAME=false OPT_MONITORING=false OPT_TAILSCALE=false OPT_CLOUDFLARED=false OPT_REMOTE_BACKUP=false OPT_BOOT_RECOVERY=false OPT_USB_DETECT=false"
)

# ============================================================================
# OUTPUT
# ============================================================================
header() {
  local t="$1"
  local b="================================================================"

  # ${#t} считает байты, а не символы отображения.
  # В UTF-8 кириллица = 2 байта на символ, но занимает 1 колонку.
  # wc -m считает Unicode codepoints — правильное число для выравнивания.
  # LC_ALL=en_US.UTF-8 гарантирует правильный подсчёт независимо
  # от системной локали (в локали C wc -m считает байты как ${#t}).
  local char_count
  char_count=$(printf '%s' "$t" \
    | LC_ALL=en_US.UTF-8 wc -m 2>/dev/null \
    || printf '%s' "$t" | wc -m 2>/dev/null)
  # Убираем пробелы и переносы строк которые добавляет wc
  char_count="${char_count//[^0-9]/}"
  # Fallback если wc -m не дал результат или вернул 0
  if [ -z "$char_count" ] || [ "$char_count" -eq 0 ] 2>/dev/null; then
    char_count="${#t}"
  fi

  local p=$(( 60 - char_count ))
  [ "$p" -lt 0 ] && p=0

  echo -e "\n${BLUE}+${b}+${NC}"
  echo -e "${BLUE}|${WHITE}${BOLD} ${t}$(printf '%*s' "$p" '')${NC}${BLUE}|${NC}"
  echo -e "${BLUE}+${b}+${NC}\n"
}

separator() { [ "$SILENT" = true ] && return; echo -e "${DIM} ----------------------------------------------------------------${NC}"; }
msg_info()   { [ "$SILENT" = true ] && return; echo -e "   ${INFO}  ${WHITE}$1${NC}"; }
msg_ok()     { [ "$SILENT" = true ] && return; echo -e "   ${CHECK} ${GREEN}$1${NC}"; }
msg_warn()   { echo -e "   ${WARN}  ${YELLOW}$1${NC}"; }
msg_error()  { echo -e "   ${CROSS} ${RED}$1${NC}"; }
msg_action() { [ "$SILENT" = true ] && return; echo -e "   ${ARROW}  ${CYAN}$1${NC}"; }
msg_dim()    { [ "$SILENT" = true ] && return; echo -e "      ${DIM}$1${NC}"; }

progress_bar() {
  [ "$SILENT" = true ] && return
  local current="${1:-0}" total="${2:-0}" desc="${3:-}"
  # Защита от деления на ноль и нечисловых значений
  [[ "$total" =~ ^[0-9]+$ ]] || return
  [[ "$current" =~ ^[0-9]+$ ]] || return
  [ "$total" -le 0 ] && return
  [ "$current" -gt "$total" ] && current=$total
  local width=35
  local pct=$((current * 100 / total))
  local filled=$((current * width / total))
  local empty=$((width - filled))
  local bar="" i
  for ((i=0; i<filled; i++)); do bar="${bar}#"; done
  for ((i=0; i<empty; i++)); do bar="${bar}."; done
  printf "\r  [%s] %3d%% %s  " "$bar" "$pct" "$desc" > /dev/tty 2>/dev/null || true
}

progress_clear() { printf "\r%80s\r" "" > /dev/tty 2>/dev/null || true; }

# ============================================================================
# LOGGING
# ============================================================================
setup_logging() {
  LOG_FILE="${LOG_FILE:-${LOG_DIR}/ha_install_$(date +%Y%m%d_%H%M%S).log}"
  mkdir -p "$(dirname "$LOG_FILE")"
  exec 3>&1 4>&2
  exec > >(tee -a "$LOG_FILE") 2>&1
  TEE_PID=""
  LOGGING_ACTIVE=true
  msg_info "Лог: ${LOG_FILE}"
}

flush_log() {
  if [ "$LOGGING_ACTIVE" = true ]; then
    exec 1>&3 2>&4 3>&- 4>&- 2>/dev/null || true
    LOGGING_ACTIVE=false
    [ -n "$TEE_PID" ] && wait "$TEE_PID" 2>/dev/null || true
    sleep 0.3
  fi
}

# ============================================================================
# SPINNER (with proper signal handling)
# ============================================================================
spinner_pid=""

spinner_start() {
  local d="$1"; [ "$SILENT" = true ] && return
  ( trap 'exit 0' INT TERM HUP
    i=0 e=0; while true; do
    local c; case $((i%4)) in 0) c="|";; 1) c="/";; 2) c="-";; 3) c="\\";; esac
    printf "\r  %s %s (%dс)  " "$c" "$d" "$e" > /dev/tty 2>/dev/null || break
    sleep 1; i=$((i+1)); e=$((e+1))
  done ) &
  spinner_pid=$!; disown "$spinner_pid" 2>/dev/null || true
}

spinner_stop() {
  if [ -n "$spinner_pid" ] && kill -0 "$spinner_pid" 2>/dev/null; then
    kill "$spinner_pid" 2>/dev/null
    wait "$spinner_pid" 2>/dev/null
    printf "\r%80s\r" "" > /dev/tty 2>/dev/null || true
  fi
  spinner_pid=""
}

# ============================================================================
# TEXT FALLBACK UI (prompts to stderr, return values to stdout)
# ============================================================================
text_menu() {
  local title="$1" prompt="$2"; shift 2
  echo -e "\n   ${BOLD}${title}${NC}" >&2
  echo -e "   ${prompt}\n" >&2
  local i=1; local -a items=()
  while [ $# -ge 2 ]; do
    echo -e "   ${CYAN}${i})${NC} $1 - ${DIM}$2${NC}" >&2
    items+=("$1"); shift 2; i=$((i+1))
  done
  echo "" >&2
  echo -en "   Выбор [1-${#items[@]}]: " >&2
  local n; read -r n
  if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#items[@]} ]; then
    echo "${items[$((n-1))]}"
    return 0
  fi
  return 1
}

text_yesno() {
  local prompt="$1" default="${2:-y}"
  local show_default="$default"
  [ "$default" = "y" ] && show_default="д"
  [ "$default" = "n" ] && show_default="н"
  echo -en "   ${prompt} (д/н) [${show_default}]: " >&2
  local ans; read -r ans
  [ -z "$ans" ] && ans="$default"
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || [ "$ans" = "д" ] || [ "$ans" = "Д" ]
}

text_input() {
  local prompt="$1" default="${2:-}"
  echo -en "   ${prompt}" >&2
  [ -n "$default" ] && echo -en " [${default}]" >&2
  echo -en ": " >&2
  local val; read -r val
  [ -z "$val" ] && val="$default"
  echo "$val"
}

text_password() {
  local prompt="$1"
  echo -en "   ${prompt}: " >&2
  local val; read -rs val
  echo "" >&2
  echo "$val"
}

# =========================================================================
# SAFE READ (с таймаутом для защиты SSH)
# =========================================================================
safe_read() {
    local prompt="$1" default="${2:-}" timeout="${3:-300}"
    echo -en "$prompt" >&2
    local val=""
    if [ -t 0 ]; then
        read -r -t "$timeout" val 2>/dev/null || val="$default"
    else
        val="$default"
    fi
    [ -z "$val" ] && val="$default"
    echo "$val"
}

# ============================================================================
# DIRS, APT, TMPFS
# ============================================================================
setup_tmpdir() {
  mkdir -p "$HA_TMP"
  df -T "$HA_TMP" 2>/dev/null | grep -q tmpfs || \
    mount -t tmpfs -o size=512M tmpfs "$HA_TMP" 2>/dev/null || true
}

cleanup_tmpdir() {
  umount "$HA_TMP" 2>/dev/null || true
  rm -rf "$HA_TMP" 2>/dev/null || true
}

setup_dirs() {
  mkdir -p "$HA_INSTALLER_DIR" "$BACKUP_DIR" "$HA_BACKUP_DIR"
  chmod 750 "$HA_INSTALLER_DIR" "$BACKUP_DIR" "$HA_BACKUP_DIR"
}

apt_wait_lock() {
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1 || \
        fuser /var/lib/apt/lists/lock &>/dev/null 2>&1; do
    [ $waited -ge 120 ] && { msg_error "dpkg/apt заблокирован >120с"; return 1; }
    msg_dim "Ожидание dpkg/apt... ${waited}с"
    sleep 5; waited=$((waited+5))
  done
  return 0
}

apt_safe() {
  apt_wait_lock || return 1
  DEBIAN_FRONTEND=noninteractive apt-get \
    -o Dpkg::Options::="--force-confold" \
    -o APT::Get::Assume-Yes="true" \
    "$@" </dev/null
}

# ============================================================================
# CONFIG
# ============================================================================
save_config() {
  cat > "$HA_CONFIG_FILE" << EOF
INSTALLED_VERSION="${SCRIPT_VERSION}"
INSTALLED_DATE="$(date -Iseconds)"
HA_MACHINE="${HA_MACHINE}"
OA_VERSION="${RESOLVED_OA_VER}"
HA_VERSION="${RESOLVED_HA_VER}"
OS_RELEASE_FAKED=${OS_RELEASE_FAKED}
BACKUP_DIR="${HA_BACKUP_DIR}"
OPT_ZRAM=${OPT_ZRAM}
OPT_UFW=${OPT_UFW}
OPT_WATCHDOG=${OPT_WATCHDOG}
OPT_THERMAL=${OPT_THERMAL}
OPT_BACKUP=${OPT_BACKUP}
OPT_HACS=${OPT_HACS}
OPT_MONITORING=${OPT_MONITORING}
OPT_DATA_DIR="${OPT_DATA_DIR}"
OPT_TIMEZONE="${OPT_TIMEZONE}"
OPT_WEBHOOK_URL="${OPT_WEBHOOK_URL}"
OPT_SWAP_SIZE="${OPT_SWAP_SIZE}"
OPT_DOCKER_MIRROR="${OPT_DOCKER_MIRROR}"
OPT_AUTO_REBOOT=${OPT_AUTO_REBOOT}
OPT_LOCALE="${OPT_LOCALE}"
OPT_TAILSCALE=${OPT_TAILSCALE}
OPT_CLOUDFLARED=${OPT_CLOUDFLARED}
CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN}"
PROFILE="${PROFILE}"
BOOT_DIR="${BOOT_DIR}"
BOOT_DEV_FSTAB="${BOOT_DEV_FSTAB}"
EOF
  chmod 600 "$HA_CONFIG_FILE"
}

load_config() {
  [ -f "$HA_CONFIG_FILE" ] || return 0
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ "$line" =~ ^([A-Z_][A-Z_0-9]*)=(.*) ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      val="${val#\"}"; val="${val%\"}"
      case "$key" in
        INSTALLED_VERSION|INSTALLED_DATE|HA_MACHINE|OA_VERSION|HA_VERSION|\
        OS_RELEASE_FAKED|OPT_ZRAM|OPT_UFW|OPT_WATCHDOG|\
        OPT_THERMAL|OPT_BACKUP|OPT_HACS|OPT_MONITORING|PROFILE|\
        OPT_DATA_DIR|OPT_TIMEZONE|OPT_WEBHOOK_URL|OPT_SWAP_SIZE|\
        OPT_DOCKER_MIRROR|OPT_AUTO_REBOOT|OPT_LOCALE|OPT_TAILSCALE|BOOT_DIR|BOOT_DEV_FSTAB|OPT_CLOUDFLARED|CF_TUNNEL_TOKEN)
          printf -v "$key" '%s' "$val"
          ;;
      esac
    fi
  done < "$HA_CONFIG_FILE"
}

# ============================================================================
# HISTORY
# ============================================================================
log_run_history() {
  mkdir -p "$HA_INSTALLER_DIR"
  echo "$(date -Iseconds)|v${SCRIPT_VERSION}|$(whoami)|$*|${PROFILE:-none}" >> "$HISTORY_FILE"
  tail -50 "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" 2>/dev/null && \
    mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
}

show_history() {
  [ ! -f "$HISTORY_FILE" ] && { msg_info "Нет истории"; return; }
  header "ИСТОРИЯ ЗАПУСКОВ"
  while IFS='|' read -r ts ver user args prof; do
    echo -e "   ${DIM}${ts}${NC} ${ver} ${user} ${CYAN}${args}${NC} [${prof}]"
  done < "$HISTORY_FILE"
}

# ============================================================================
# EXPORT / IMPORT CONFIG
# ============================================================================
export_config() {
  load_config
  local ef="${HA_BACKUP_DIR}/ha_config_$(date +%Y%m%d).sh"
  mkdir -p "$HA_BACKUP_DIR"
  {
    echo "# Hassify config $(date)"
    for opt in OPT_ZRAM OPT_EMMC_TUNING OPT_USB_POWER OPT_UFW OPT_SSH_HARDENING \
      OPT_AUTOUPDATE OPT_WATCHDOG OPT_THERMAL OPT_BACKUP OPT_HACS OPT_HOSTNAME \
      OPT_MONITORING OPT_BOOT_RECOVERY OPT_USB_DETECT OPT_STATIC_IP OPT_TELEGRAM \
      OPT_TAILSCALE OPT_REMOTE_BACKUP OPT_CLOUDFLARED; do
      echo "${opt}=${!opt}"
    done
    echo "PROFILE=\"${PROFILE}\""
    echo "HA_MACHINE=\"${HA_MACHINE}\""
    [ -n "$OPT_TIMEZONE" ] && echo "OPT_TIMEZONE=\"${OPT_TIMEZONE}\""
    [ -n "$OPT_DATA_DIR" ] && echo "OPT_DATA_DIR=\"${OPT_DATA_DIR}\""
    [ -n "$OPT_WEBHOOK_URL" ] && echo "OPT_WEBHOOK_URL=\"${OPT_WEBHOOK_URL}\""
    [ -n "$OPT_LOCALE" ] && echo "OPT_LOCALE=\"${OPT_LOCALE}\""
  } > "$ef"
  chmod 600 "$ef"
  msg_ok "Конфигурация: ${ef}"
}

import_config() {
  local file="$1"
  [ ! -f "$file" ] && { msg_error "Файл не найден: ${file}"; exit 1; }
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        if [[ "$line" =~ ^(OPT_[A-Z_]+|PROFILE|HA_MACHINE|STATIC_IP|STATIC_GW|STATIC_DNS|TG_TOKEN|TG_CHAT|REMOTE_BACKUP_TARGET)=(.*) ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      val="${val#\"}"; val="${val%\"}"
      # Разрешаем пустые значения и спецсимволы URL (?=&+%)
      # Регулярку выносим в переменную, чтобы bash не ругался на спецсимвол & внутри [[ =~ ]]
      local url_regex='^[a-zA-Z0-9._:/?&=%+-]+$'
      [[ -z "$val" ]] || [[ "$val" =~ $url_regex ]] || { msg_warn "Пропуск: ${key}"; continue; }
      printf -v "$key" '%s' "$val"
    fi
  done < "$file"
  RUN_WIZARD=false
  msg_ok "Импортировано: ${file}"
}

# ============================================================================
# NOTIFICATIONS
# ============================================================================
# _send_webhook — умная отправка webhook.
# Определяет тип сервиса по URL и использует правильный формат.
# Вызывается из send_notification() и test_notifications().
_send_webhook() {
  local url="$1"
  local msg="$2"
  local host
  host=$(hostname 2>/dev/null || echo "ha-box")
  local FULL_MSG="Hassify (${HOST}): ${MSG}"

  case "$url" in

    # ntfy.sh ожидает plain text в body.
    # JSON она не парсит — выводит как есть, что выглядит некрасиво.
    # Заголовки Title и Tags добавляют иконку и заголовок уведомления.
    *ntfy.sh/*)
      curl -s -X POST "$url" \
        -H "Title: Home Assistant" \
        -H "Priority: default" \
        -H "Tags: house" \
        -d "$full_msg" \
        >/dev/null 2>&1 || true
      ;;

    # Discord ожидает JSON с полем "content"
    *discord.com/api/webhooks/*|*discordapp.com/api/webhooks/*)
      local escaped
      escaped=$(printf '%s' "$full_msg" \
        | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
      curl -s -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "{\"content\":\"${escaped}\"}" \
        >/dev/null 2>&1 || true
      ;;

    # Slack ожидает JSON с полем "text"
    *hooks.slack.com/*)
      local escaped
      escaped=$(printf '%s' "$full_msg" \
        | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
      curl -s -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "{\"text\":\"${escaped}\"}" \
        >/dev/null 2>&1 || true
      ;;

    # Gotify ожидает JSON с полями "title" и "message"
    */message*|*gotify*)
      local escaped
      escaped=$(printf '%s' "$full_msg" \
        | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
      curl -s -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "{\"title\":\"Home Assistant\",\"message\":\"${escaped}\",\"priority\":5}" \
        >/dev/null 2>&1 || true
      ;;

    # Всё остальное — сначала plain text, fallback на JSON.
    # Так работает большинство self-hosted решений.
    *)
      local rc
      rc=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$url" \
        -d "$full_msg" \
        2>/dev/null) || rc="000"
      # Защита от пустого rc если curl не запустился
      rc="${rc:-000}"
      if [[ ! "$rc" =~ ^2 ]]; then
        local escaped
        escaped=$(printf '%s' "$full_msg" \
          | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
        curl -s -X POST "$url" \
          -H "Content-Type: application/json" \
          -d "{\"text\":\"${escaped}\",\"message\":\"${escaped}\"}" \
          >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

send_notification() {
  local msg="$1"

  # --- Telegram ---
  if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ] && \
     [ "$TG_TOKEN" != "__HA_TG_TOKEN__" ]; then
    local rf="/tmp/.ha_notify_rate"
    local now; now=$(date +%s)
    local last; last=$(cat "$rf" 2>/dev/null || echo 0)
    if [ $((now - last)) -ge 30 ]; then
      echo "$now" > "$rf"
      curl -s -X POST \
        "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TG_CHAT}" \
        --data-urlencode "text=Hassify ($(hostname)): ${msg}" \
        >/dev/null 2>&1
    fi
  fi

  # --- Webhook ---
  # Делегируем в _send_webhook которая знает формат каждого сервиса
  if [ -n "$OPT_WEBHOOK_URL" ]; then
    _send_webhook "$OPT_WEBHOOK_URL" "$msg"
  fi
}

test_notifications() {
  local ok=true
  if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
    msg_action "Тест Telegram..."
    local rc
    rc=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TG_CHAT}" \
      --data-urlencode "text=Hassify: тест" 2>/dev/null)
    [ "$rc" = "200" ] && msg_ok "Telegram OK" || { msg_warn "Telegram ошибка (${rc})"; ok=false; }
  fi
  if [ -n "$OPT_WEBHOOK_URL" ]; then
    msg_action "Тест webhook..."
    # Один запрос — отправляем тест и получаем HTTP код.
    # Формат запроса соответствует типу сервиса.
    # Это избегает двойной отправки (тест + проверка статуса).
    local rc="000"
    case "$OPT_WEBHOOK_URL" in
      *ntfy.sh/*)
        rc=$(curl -s -o /dev/null -w "%{http_code}" \
          -X POST "$OPT_WEBHOOK_URL" \
          -H "Title: Home Assistant" \
          -H "Tags: house" \
          -d "Hassify: тест уведомление" \
          2>/dev/null) || rc="000"
        ;;
      *discord.com/api/webhooks/*|*discordapp.com/api/webhooks/*)
        rc=$(curl -s -o /dev/null -w "%{http_code}" \
          -X POST "$OPT_WEBHOOK_URL" \
          -H "Content-Type: application/json" \
          -d '{"content":"Hassify: тест уведомление"}' \
          2>/dev/null) || rc="000"
        ;;
      *hooks.slack.com/*)
        rc=$(curl -s -o /dev/null -w "%{http_code}" \
          -X POST "$OPT_WEBHOOK_URL" \
          -H "Content-Type: application/json" \
          -d '{"text":"Hassify: тест уведомление"}' \
          2>/dev/null) || rc="000"
        ;;
      *)
        rc=$(curl -s -o /dev/null -w "%{http_code}" \
          -X POST "$OPT_WEBHOOK_URL" \
          -d "Hassify: тест уведомление" \
          2>/dev/null) || rc="000"
        ;;
    esac
    rc="${rc:-000}"
    if [[ "$rc" =~ ^2 ]]; then
      msg_ok "Webhook OK (${rc})"
    else
      msg_warn "Webhook ответил: ${rc} (может быть нормально для некоторых сервисов)"
    fi
  fi
  $ok
}

# ============================================================================
# STATE, LOCK
# ============================================================================
acquire_lock() {
  exec 200>"$LOCK_FILE"
  flock -n 200 || { msg_error "Скрипт уже запущен"; exit 1; }
  echo $$ > "$LOCK_FILE"
}

release_lock() {
  flock -u 200 2>/dev/null || true
  rm -f "$LOCK_FILE" 2>/dev/null || true
}

mark_done() {
  local s="$1" t; t=$(date +%s)
  (
    flock -x 201
    { grep -v "^${s}|" "$STATE_FILE" 2>/dev/null || true
      echo "${s}|${t}|${SCRIPT_VERSION}"
    } > "${STATE_FILE}.new" && mv "${STATE_FILE}.new" "$STATE_FILE"
  ) 201>"${STATE_FILE}.lock"
}

is_done() {
  local s="$1"
  [ ! -f "$STATE_FILE" ] && return 1
  local l; l=$(grep "^${s}|" "$STATE_FILE" 2>/dev/null | tail -1) || return 1
  local v; v=$(echo "$l" | cut -d'|' -f3)
  [ "$v" != "$SCRIPT_VERSION" ] && { msg_dim "${s}: v${v}->v${SCRIPT_VERSION}"; return 1; }
  return 0
}

reset_state() {
  rm -f "$STATE_FILE" "$GRACE_MARKER" "${STATE_FILE}.lock" "$REBOOT_ATTEMPT_FILE" 2>/dev/null || true
  msg_ok "Состояние сброшено."
}

schedule_daemon_reload() { DAEMON_RELOAD_NEEDED=true; }

flush_daemon_reload() {
  if [ "$DAEMON_RELOAD_NEEDED" = true ]; then
    systemctl daemon-reload 2>/dev/null || true
    DAEMON_RELOAD_NEEDED=false
  fi
}

check_step_deps() {
  local step="$1"
  local deps="${STEP_DEPS[$step]:-}"
  [ -z "$deps" ] && return 0
  local dep
  for dep in $deps; do
    is_done "$dep" 2>/dev/null || {
      msg_error "Шаг '${step}' требует '${dep}'"
      return 1
    }
  done
  return 0
}

show_progress() {
  [ "$SILENT" = true ] && return
  local done_count=0
  separator
  for s in "${ALL_STEPS[@]}"; do
    if is_done "$s" 2>/dev/null; then
      done_count=$((done_count+1))
      local ts
      ts=$(grep "^${s}|" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d'|' -f2)
      echo -e "   ${CHECK} ${s} ${DIM}[$(date -d "@$ts" '+%H:%M' 2>/dev/null || echo '?')]${NC}"
    else
      echo -e "   ${DIM}o ${s}${NC}"
    fi
  done
  echo -e "\n   ${BOLD}Прогресс: ${done_count}/${TOTAL_STEPS}${NC}"
  separator
}

# ============================================================================
# ROLLBACK
# ============================================================================
push_rollback() { ROLLBACK_ACTIONS+=("$1"); }

execute_rollback() {
  [ ${#ROLLBACK_ACTIONS[@]} -eq 0 ] && return
  msg_warn "Откат изменений..."
  local i
  for ((i=${#ROLLBACK_ACTIONS[@]}-1; i>=0; i--)); do
    msg_dim "<- ${ROLLBACK_ACTIONS[$i]}"
    eval "${ROLLBACK_ACTIONS[$i]}" 2>/dev/null || true
  done
  msg_ok "Откат завершён"
}

ask_continue_on_error() {
  local sn="$1" em="$2"
  msg_error "${sn}: ${em}"
  [ "$SILENT" = true ] && return 0
  if [ -t 0 ]; then
    echo -en "   ${WARN}  ${YELLOW}Продолжить? (д/н): ${NC}" >&2
    local ans; read -r -t 30 ans || ans="y"
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || [ "$ans" = "д" ] || [ "$ans" = "Д" ] || [ "$ans" = "" ]
  else
    return 0
  fi
}

require_disk_space() {
  local req="$1" desc="$2"
  local avail; avail=$(df -m / | awk 'NR==2{print $4}')
  if [ "$avail" -lt "$req" ]; then
    msg_warn "${desc}: нужно ${req}МБ, доступно ${avail}МБ"
    msg_action "Очистка..."
    apt-get clean 2>/dev/null || true
    journalctl --vacuum-size=50M 2>/dev/null || true
    command -v docker &>/dev/null && docker system prune -f 2>/dev/null || true
    avail=$(df -m / | awk 'NR==2{print $4}')
    [ "$avail" -lt "$req" ] && { msg_error "Недостаточно места: ${avail}МБ < ${req}МБ"; return 1; }
    msg_ok "Освобождено: ${avail}МБ"
  fi
  return 0
}

# ============================================================================
# SSH NOHUP (skip in silent mode, timeout on prompt)
# ============================================================================
auto_nohup_if_ssh() {
  if who 2>/dev/null | grep -q pts; then
    msg_warn "Обнаружена SSH-сессия."
    msg_dim "Установка защищена от разрыва соединения."
    msg_dim "Если SSH оборвётся — запустите скрипт снова, он продолжит с того же места."
  fi
}

# ============================================================================
# ESTIMATE TIME
# ============================================================================
estimate_install_time() {
  detect_system_info
  local ram_mb cpu_cores est_min
  ram_mb=$(free -m | awk '/Mem:/{print $2}')
  cpu_cores=$(nproc 2>/dev/null || echo 1)
  est_min=15
  [ "$ram_mb" -lt 2048 ] && est_min=$((est_min + 10))
  [ "$cpu_cores" -lt 4 ] && est_min=$((est_min + 5))
  [ "$OPT_HACS" = true ] && est_min=$((est_min + 3))
  msg_info "Примерное время: ~${est_min} мин"
}

# =========================================================================
# SAFE SCRIPT PATH
# =========================================================================
ensure_safe_script_path() {
  local src
  src=$(readlink -f "$0" 2>/dev/null || echo "$0")

  # Защита: если $0 это интерпретатор (bash/sh), а не скрипт.
  # Такое бывает при запуске командой: bash /tmp/install.sh
  # В этом случае $0 = /bin/bash, а не путь к скрипту.
  case "$src" in
    */bin/bash|*/bin/sh|*/usr/bin/bash|*/usr/bin/sh)
      # Ищем реальный путь к скрипту через аргументы процесса.
      # /proc/$$/cmdline содержит argv[] разделённые нулевым байтом.
      # tr '\0' '\n' разбивает на отдельные строки — надёжнее чем пробел,
      # потому что аргументы сами могут содержать пробелы.
      # grep ищет только .sh файлы или конкретные имена нашего скрипта,
      # исключая системный /usr/bin/install и флаги начинающиеся с -.
      local proc_src
      proc_src=$(cat /proc/$$/cmdline 2>/dev/null \
        | tr '\0' '\n' \
        | grep -E '\.sh$|/install\.sh$|/ha-install$' \
        | grep -v '^-' \
        | head -1)
      [ -n "$proc_src" ] && \
        src=$(readlink -f "$proc_src" 2>/dev/null || echo "$proc_src")
      ;;
  esac

  # Если скрипт уже запущен из правильного места — ничего не делаем
  if [ "$src" = "$SAFE_SCRIPT_PATH" ]; then
    return 0
  fi

  # Исходный файл должен существовать и быть читаемым
  if [ ! -f "$src" ]; then
    msg_warn "ensure_safe_script_path: файл не найден: ${src}"
    return 1
  fi

  # Копируем если:
  # - файл ещё не существует в SAFE_SCRIPT_PATH
  # - или содержимое отличается от текущего скрипта
  if [ ! -f "$SAFE_SCRIPT_PATH" ] || \
     ! cmp -s "$src" "$SAFE_SCRIPT_PATH" 2>/dev/null; then
    mkdir -p "$(dirname "$SAFE_SCRIPT_PATH")"
    if cp "$src" "$SAFE_SCRIPT_PATH" 2>/dev/null; then
      chmod +x "$SAFE_SCRIPT_PATH"
      msg_dim "Скрипт сохранён: ${SAFE_SCRIPT_PATH}"
    else
      msg_warn "Не удалось скопировать скрипт в ${SAFE_SCRIPT_PATH}"
      return 1
    fi
  fi

  return 0
}

setup_reboot_continue() {
    local continue_from="${1:-apparmor}"
    ensure_safe_script_path
    local svc_file="/etc/systemd/system/${REBOOT_CONTINUE_SVC}.service"
    local attempts=0
    [ -f "$REBOOT_ATTEMPT_FILE" ] && \
        attempts=$(cat "$REBOOT_ATTEMPT_FILE" 2>/dev/null || echo 0)

    if [ "$attempts" -ge 3 ]; then
        msg_error "Превышен лимит перезагрузок (3)"
        rm -f "$REBOOT_ATTEMPT_FILE"
        return 1
    fi

    echo $((attempts + 1)) > "$REBOOT_ATTEMPT_FILE"

    # Формируем аргументы явно и безопасно для systemd.
    # Не передаём $* или $@ целиком — systemd не понимает
    # shell-кавычки и сломает аргументы содержащие пробелы.
    # Передаём только флаги которые нужны для продолжения.
    local exec_args="--from-step=${continue_from}"

    [ "$SILENT" = true ] && \
        exec_args="${exec_args} --silent"
    [ "$SKIP_UPDATE" = true ] && \
        exec_args="${exec_args} --skip-update"
    [ "$OPT_AUTO_REBOOT" = true ] && \
        exec_args="${exec_args} --auto-reboot"
    [ -n "$PROFILE" ] && [ "$PROFILE" != "custom" ] && \
        exec_args="${exec_args} --profile ${PROFILE}"
    [ -n "$HA_MACHINE" ] && \
        exec_args="${exec_args} --machine ${HA_MACHINE}"
    [ -n "$OVERRIDE_OS_AGENT_VER" ] && \
        exec_args="${exec_args} --os-agent-ver ${OVERRIDE_OS_AGENT_VER}"
    [ -n "$OVERRIDE_HA_VER" ] && \
        exec_args="${exec_args} --ha-ver ${OVERRIDE_HA_VER}"

    cat > "$svc_file" << SVCEOF
[Unit]
Description=Hassify - продолжение после перезагрузки
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${SAFE_SCRIPT_PATH} ${exec_args}
ExecStartPost=/bin/rm -f ${svc_file}
RemainAfterExit=no
StandardOutput=append:${LOG_DIR}/hassify_reboot.log
StandardError=append:${LOG_DIR}/hassify_reboot.log

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "${REBOOT_CONTINUE_SVC}" 2>/dev/null || true
    msg_ok "Продолжит после перезагрузки с шага '${continue_from}' (попытка $((attempts+1))/3)"
}

remove_reboot_continue() {
  if [ -n "$FROM_STEP" ]; then
    systemctl disable "${REBOOT_CONTINUE_SVC}" 2>/dev/null || true
    return 0
  fi

  systemctl disable "${REBOOT_CONTINUE_SVC}" 2>/dev/null || true
  rm -f "/etc/systemd/system/${REBOOT_CONTINUE_SVC}.service" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
}

# ============================================================================
# RUN_STEP (counter + timing)
# ============================================================================
run_step() {
  local f="$1"; shift
  CURRENT_STEP_NUM=$((CURRENT_STEP_NUM + 1))
  local t0; t0=$(date +%s)

  local step_id=""
  case "$f" in
    step_preflight)          step_id="preflight";;
    step_update_system)      step_id="update";;
    step_install_deps)       step_id="deps";;
    step_configure_network)  step_id="network";;
    step_configure_apparmor) step_id="apparmor";;
    step_performance)        step_id="perf";;
    step_install_docker)     step_id="docker";;
    step_resolve_versions)   step_id="versions";;
    step_download_packages)  step_id="download";;
    step_install_os_agent)   step_id="osagent";;
    step_install_ha)         step_id="ha";;
    step_security)           step_id="sec";;
    step_extras)             step_id="extras";;
    step_hacs)               step_id="hacs";;
    step_post_restore)       step_id="postrestore";;
  esac

  [ -n "$step_id" ] && check_step_deps "$step_id"

  if [ "$INTERACTIVE_STEPS" = true ] && [ -t 0 ]; then
    echo -en "   ${ARROW} [${CURRENT_STEP_NUM}/${TOTAL_STEPS}] ${step_id:-$f}? (д/н/выход): " >&2
    local ans; read -r ans
    case "$ans" in
      n|N|н|Н)             msg_dim "Пропущен"; return 0;;
      q|Q|в|В|выход|exit)  msg_warn "Прервано"; exit 0;;
    esac
  fi

  "$f" "$@"
  local rc=$?
  local e=$(( $(date +%s) - t0 ))

  [ -n "$step_id" ] && STEP_TIMES[$step_id]=$e
  [ $e -gt 5 ] && msg_dim "Время: ${e}с"
  return $rc
}

# ============================================================================
# CLEANUP & SIGNAL HANDLING (proper Ctrl+C support)
# ============================================================================
cleanup() {
  local ec=$?

  # Restore default signal handlers
  trap - EXIT INT TERM HUP

  spinner_stop 2>/dev/null || true
  [ -n "$PREFETCH_PID" ] && kill "$PREFETCH_PID" 2>/dev/null || true
  cleanup_tmpdir 2>/dev/null || true
  release_lock
  flush_log 2>/dev/null || true

  if [ $ec -ne 0 ] && [ $ec -ne 130 ]; then
    [ ${#ROLLBACK_ACTIONS[@]} -gt 0 ] && execute_rollback
    [ "$OPT_AUTO_REBOOT" != true ] && remove_reboot_continue
  fi

  if [ $ec -eq 130 ]; then
    echo ""
    echo -e " ${WARN} ${YELLOW}Прервано пользователем (Ctrl+C)${NC}"
    echo ""
  fi

  # Beep on success
  [ $ec -eq 0 ] && [ -n "$INSTALL_START" ] && echo -e "\a" 2>/dev/null || true

  exit $ec
}

handle_interrupt() {
  echo ""
  msg_warn "Получен сигнал прерывания..."
  exit 130
}

# INT (Ctrl+C) handled separately for immediate response
trap cleanup EXIT
trap handle_interrupt INT TERM

# ============================================================================
# MIGRATION
# ============================================================================
migrate_legacy_paths() {
  [ -f "/root/.ha_install_state" ] && [ ! -f "$STATE_FILE" ] && {
    mkdir -p "$HA_INSTALLER_DIR"
    mv "/root/.ha_install_state" "$STATE_FILE" 2>/dev/null || true
  }
  [ -d "/root/.ha_install_backup" ] && [ ! -d "$BACKUP_DIR" ] && {
    mkdir -p "$BACKUP_DIR"
    cp -a /root/.ha_install_backup/* "$BACKUP_DIR/" 2>/dev/null || true
  }
  if [ -d "/root/ha-backups" ] && [ ! -d "$HA_BACKUP_DIR" ]; then
    mkdir -p "$HA_BACKUP_DIR"
    mv /root/ha-backups/* "$HA_BACKUP_DIR/" 2>/dev/null || true
    rmdir /root/ha-backups 2>/dev/null || true
  fi
  local dropin="/etc/systemd/system/hassio-supervisor.service.d/fix-os-release.conf"
  [ -f "$dropin" ] && grep -q "/root/" "$dropin" 2>/dev/null && {
    sed -i "s|/root/.ha_install_backup|${BACKUP_DIR}|g" "$dropin" 2>/dev/null
    systemctl daemon-reload 2>/dev/null || true
  }
}

# ============================================================================
# SYSTEM DETECTION
# ============================================================================
detect_arch() {
  case "$(uname -m)" in
    x86_64)  echo "x86_64";;
    aarch64) echo "aarch64";;
    armv7l)  echo "armv7";;
    i686)    echo "i386";;
    *)       echo "unknown";;
  esac
}

detect_system_info() {
  [ "$SYSTEM_INFO_LOADED" = true ] && return 0
  if [ -f /etc/os-release ]; then
    local _vc="" _vi="" _pn="" _id=""
    eval "$(. /etc/os-release 2>/dev/null; printf '_vc=%q _vi=%q _pn=%q _id=%q' \
      "${VERSION_CODENAME:-}" "${VERSION_ID:-}" "${PRETTY_NAME:-}" "${ID:-}")"
    CACHED_CODENAME="$_vc"
    CACHED_VERSION_ID="$_vi"
    CACHED_PRETTY_NAME="$_pn"
    CACHED_OS_ID="$_id"
  fi
  CACHED_ARCH=$(detect_arch)
  CACHED_MACHINE_ARCH=$(uname -m)
  SYSTEM_INFO_LOADED=true
}

is_trixie() {
  detect_system_info
  [ "$CACHED_CODENAME" = "trixie" ] || [ "$CACHED_VERSION_ID" = "13" ]
}

is_armbian() {
  [ -f /etc/armbian-release ] || dpkg -l 'armbian-bsp-cli-*' &>/dev/null
}

# ============================================================================
# PACKAGE & DOWNLOAD
# ============================================================================
is_pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

pkg_available() {
  apt-cache show "$1" >/dev/null 2>&1
}

run_cmd() {
  local d="$1"; shift
  local lf
  lf=$(mktemp "${HA_TMP}/ha_XXXXXX.log" 2>/dev/null || mktemp /tmp/ha_XXXXXX.log)
  msg_action "${d}..."
  [ "$DRY_RUN" = true ] && { msg_dim "[dry-run] $*"; rm -f "$lf"; return 0; }
  if "$@" > "$lf" 2>&1; then
    msg_ok "$d"; rm -f "$lf"; return 0
  else
    local c=$?
    msg_error "${d} (код ${c})"
    tail -15 "$lf" 2>/dev/null | while IFS= read -r l; do
      echo -e "   ${RED}|${NC} ${l}"
    done
    rm -f "$lf"; return $c
  fi
}

run_cmd_fatal() {
  run_cmd "$@" || { msg_error "Критическая ошибка."; exit 1; }
}

download_file() {
  local url="$1" out="$2" desc="$3" max="${4:-3}" att=1
  [ "$DRY_RUN" = true ] && { msg_action "${desc}..."; msg_dim "[dry-run] wget ${url}"; return 0; }
  while [ $att -le $max ]; do
    [ $att -gt 1 ] && sleep $((att*3))
    msg_action "${desc} (${att}/${max})..."
    rm -f "$out" 2>/dev/null || true
    if wget -q --timeout=60 --tries=1 -O "$out" "$url" 2>/dev/null && [ -s "$out" ]; then
      if [[ "$out" == *.deb ]]; then
        dpkg-deb --info "$out" &>/dev/null && { msg_ok "$desc"; return 0; } || msg_warn ".deb повреждён"
      else
        msg_ok "$desc"; return 0
      fi
    else
      msg_warn "Ошибка загрузки"
    fi
    att=$((att+1))
  done
  msg_error "${desc} - не удалось"; return 1
}

verify_checksum() {
  local deb="$1" repo="$2" ver="$3"
  [ "$DRY_RUN" = true ] && return 0
  local url="https://github.com/${repo}/releases/download/${ver}/SHA256SUMS"
  local tmpsha
  tmpsha=$(mktemp /tmp/ha_sha_XXXXXX 2>/dev/null)
  if wget -q --timeout=10 -O "$tmpsha" "$url" 2>/dev/null && [ -s "$tmpsha" ]; then
    local exp act bn
    bn=$(basename "$deb")
    exp=$(grep "$bn" "$tmpsha" 2>/dev/null | awk '{print $1}')
    if [ -n "$exp" ]; then
      act=$(sha256sum "$deb" | awk '{print $1}')
      rm -f "$tmpsha"
      [ "$exp" = "$act" ] && { msg_ok "SHA256 OK"; return 0; } || { msg_error "SHA256 не совпал"; return 1; }
    fi
  fi
  rm -f "$tmpsha" 2>/dev/null
  msg_dim "SHA256 недоступен - пропуск"
  return 0
}

get_latest_release() {
  local repo="$1"
  [ -n "${RELEASE_CACHE[$repo]+x}" ] && { echo "${RELEASE_CACHE[$repo]}"; return 0; }
  local v=""
  if command -v curl &>/dev/null && command -v jq &>/dev/null; then
    v=$(curl -fsSL --timeout 15 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
      | jq -r '.tag_name // empty' 2>/dev/null | tr -d '[:space:]') || true
  fi
  if [ -z "$v" ] && command -v curl &>/dev/null; then
    local u
    u=$(curl -sL --timeout 15 -o /dev/null -w '%{url_effective}' \
      "https://github.com/${repo}/releases/latest" 2>/dev/null) || true
    [ -n "$u" ] && v=$(echo "$u" | sed 's|.*/tag/||' | tr -d '[:space:]')
  fi
  if [ -z "$v" ] && command -v wget &>/dev/null; then
    v=$(wget -q --timeout=15 --max-redirect=0 -S \
      "https://github.com/${repo}/releases/latest" 2>&1 \
      | grep -i 'Location:' | head -1 | sed 's|.*/tag/||' | tr -d '[:space:]') || true
  fi
  RELEASE_CACHE[$repo]="$v"
  echo "$v"
}

detect_machine_type() {
  local m=""
  m=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null) || true
  case "$(uname -m)" in
    x86_64) echo "generic-x86-64";;
    aarch64)
      case "$m" in
        *Raspberry*Pi*5*) echo "raspberrypi5-64";;
        *Raspberry*Pi*4*) echo "raspberrypi4-64";;
        *Raspberry*Pi*3*) echo "raspberrypi3-64";;
        *ODROID-N2*)      echo "odroid-n2";;
        *ODROID-C4*)      echo "odroid-c4";;
        *Khadas*VIM3*)    echo "khadas-vim3";;
        *)                echo "qemuarm-64";;
      esac;;
    *)      echo "qemuarm-64";;
  esac
}

get_cpu_temp() {
  [ -f /sys/class/thermal/thermal_zone0/temp ] && \
    echo "$(($(cat /sys/class/thermal/thermal_zone0/temp)/1000))" || echo ""
}

check_internet() {
  ping -c1 -W2 github.com &>/dev/null & local p1=$!
  ping -c1 -W2 8.8.8.8 &>/dev/null & local p2=$!
  ping -c1 -W2 1.1.1.1 &>/dev/null & local p3=$!
  local dns=false net=false
  wait "$p1" 2>/dev/null && dns=true && net=true
  wait "$p2" 2>/dev/null && net=true
  wait "$p3" 2>/dev/null && net=true
  $dns && { msg_ok "Интернет: OK"; return 0; }
  $net && { msg_warn "DNS нестабилен"; fix_dns_if_needed; return 0; }
  msg_error "Нет интернета"; return 1
}

fix_dns_if_needed() {
  # Проверка: IP работает но DNS нет
  if ! ping -c1 -W3 github.com &>/dev/null && ping -c1 -W2 8.8.8.8 &>/dev/null; then
    msg_warn "DNS не работает, исправление..."
    # Сохранить текущий resolv.conf если ещё не сохранён
    if [ ! -f "${BACKUP_DIR}/resolv.conf.bak" ]; then
      mkdir -p "$BACKUP_DIR"
      cat /etc/resolv.conf > "${BACKUP_DIR}/resolv.conf.bak" 2>/dev/null || true
    fi
    # Записать рабочие DNS (удалить симлинк если есть)
    rm -f /etc/resolv.conf 2>/dev/null
    echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf
    sleep 2
    ping -c1 -W3 github.com &>/dev/null && msg_ok "DNS исправлен" || msg_warn "DNS всё ещё не работает"
  fi
}

wait_ha_ready() {
  local to="${1:-300}" el=0
  while [ $el -lt $to ]; do
    if [ -f "${HASSIO_DIR}/homeassistant/configuration.yaml" ]; then
      local c
      c=$(curl -s -o /dev/null -w "%{http_code}" -m 3 http://localhost:8123 2>/dev/null || echo 000)
      [ "$c" = "200" ] || [ "$c" = "401" ] && return 0
    fi
    sleep 5; el=$((el+5))
    [ $((el%30)) -eq 0 ] && msg_dim "Ожидание HA... ${el}с"
  done
  return 1
}

# ============================================================================
# VALIDATION
# ============================================================================
validate_ip() {
  local ip="$1" IFS='.'
  read -ra o <<< "$ip"
  [ ${#o[@]} -ne 4 ] && return 1
  for x in "${o[@]}"; do
    [[ "$x" =~ ^[0-9]+$ ]] || return 1
    [ "$x" -gt 255 ] && return 1
    [[ "$x" =~ ^0[0-9] ]] && return 1
  done
  [ "${o[0]}" = "0" ] && return 1
  [ "$ip" = "255.255.255.255" ] && return 1
  return 0
}

validate_gw() { [ -z "$1" ] && return 1; validate_ip "$1"; }

validate_dns_list() {
  local dns_str="$1" IFS=','
  [ -z "$dns_str" ] && return 1
  read -ra dns_arr <<< "$dns_str"
  [ ${#dns_arr[@]} -eq 0 ] && return 1
  for d in "${dns_arr[@]}"; do
    d=$(echo "$d" | tr -d '[:space:]')
    validate_ip "$d" || return 1
  done
  return 0
}

get_current_prefix() {
  ip -o -4 addr show 2>/dev/null | awk '{print $4}' | head -1 | cut -d/ -f2
}

# ============================================================================
# OS-RELEASE
# ============================================================================
os_release_needs_faking() {
  detect_system_info
  echo "$CACHED_PRETTY_NAME" | grep -qi "Debian" || return 0
  # Если codename пуст — подмена нужна (несовместимая ОС)
  [ -z "$CACHED_CODENAME" ] && return 0
  echo "$HA_SUPPORTED_CODENAMES" | grep -qw "$CACHED_CODENAME" || return 0
  return 1
}

# Разовая подмена среды для прохождения проверок установщика
apply_os_release_fake() {
  detect_system_info
  local tc="bookworm" tv="12"
  if [ "$CACHED_CODENAME" = "trixie" ] || [ "$CACHED_VERSION_ID" = "13" ]; then
    tc="trixie"; tv="13"
  elif [ "$CACHED_CODENAME" = "bullseye" ] || [ "$CACHED_VERSION_ID" = "11" ]; then
    tc="bullseye"; tv="11"
  elif [ "$CACHED_CODENAME" = "sid" ] || [ "$CACHED_CODENAME" = "testing" ]; then
    tc="trixie"; tv="13"
  fi

  # Бэкап оригинала (если еще не сделан)
  mkdir -p "${BACKUP_DIR}"
  if [ ! -f "${BACKUP_DIR}/os-release.original" ]; then
    if [ -L /etc/os-release ]; then
      readlink /etc/os-release > "${BACKUP_DIR}/os-release.symlink"
      cp "$(readlink -f /etc/os-release)" "${BACKUP_DIR}/os-release.original"
    else
      cp /etc/os-release "${BACKUP_DIR}/os-release.original"
    fi
  fi

  # КРИТИЧЕСКИ ВАЖНО: Удаляем перед созданием, чтобы не сломать /usr/lib/os-release
  rm -f /etc/os-release

  cat > /etc/os-release << EOF
PRETTY_NAME="Debian GNU/Linux ${tv} (${tc})"
NAME="Debian GNU/Linux"
VERSION_ID="${tv}"
VERSION="${tv} (${tc})"
VERSION_CODENAME=${tc}
ID=debian
HOME_URL="https://www.debian.org/"
SUPPORT_URL="https://www.debian.org/support"
BUG_REPORT_URL="https://bugs.debian.org/"
EOF

  cp /etc/os-release "$FAKED_OS_RELEASE"
  OS_RELEASE_FAKED=true
  msg_ok "os-release -> Debian ${tv} (${tc})"
}

# Создание drop-in для systemd (создает файл, патчит конфигурацию)
setup_os_release_dropin() {
  mkdir -p /etc/systemd/system/hassio-supervisor.service.d
  
  # Вычисляем точный путь к оригинальному файлу прямо сейчас, 
  # чтобы избежать проблем с экранированием $(cat ...) внутри systemd юнита.
  local symlink_target="/usr/lib/os-release" # Стандартный путь для Debian/Armbian
  if [ -f "${BACKUP_DIR}/os-release.symlink" ]; then
    local lt
    lt=$(cat "${BACKUP_DIR}/os-release.symlink")
    if [[ "$lt" == /* ]]; then
      symlink_target="$lt" # Абсолютный путь
    else
      # Если путь относительный (например, ../usr/lib/os-release), резолвим его
      symlink_target="$(cd /etc && realpath "$lt" 2>/dev/null || echo /usr/lib/os-release)"
    fi
  fi

  cat > /etc/systemd/system/hassio-supervisor.service.d/fix-os-release.conf << DROPIN
[Service]
ExecStartPre=/bin/bash -c 'rm -f /etc/os-release; F="${BACKUP_DIR}/os-release.faked"; [ -f "\$F" ] && cp "\$F" /etc/os-release'
ExecStopPost=/bin/bash -c 'rm -f /etc/os-release; O="${BACKUP_DIR}/os-release.original"; S="${BACKUP_DIR}/os-release.symlink"; if [ -f "\$S" ]; then ln -sf "${symlink_target}" /etc/os-release; elif [ -f "\$O" ]; then cp "\$O" /etc/os-release; fi'
DROPIN
  schedule_daemon_reload
  flush_daemon_reload
  msg_info "Drop-in: подмена os-release при старте Supervisor"
}

# Восстановление оригинального состояния среды
apply_os_release_restore() {
  # Удаляем текущий файл/фейк
  rm -f /etc/os-release

  if [ -f "${BACKUP_DIR}/os-release.symlink" ]; then
    local lt
    lt=$(cat "${BACKUP_DIR}/os-release.symlink")
    # Восстанавливаем симлинк. Сам файл /usr/lib/os-release мы не трогали, он цел!
    ln -sf "$lt" /etc/os-release 2>/dev/null
    msg_ok "os-release восстановлен (симлинк -> $lt)"
  elif [ -f "${BACKUP_DIR}/os-release.original" ]; then
    # Если изначально был обычный файл, просто возвращаем его
    cp "${BACKUP_DIR}/os-release.original" /etc/os-release
    msg_ok "os-release восстановлен"
  fi
}

# ============================================================================
# DOCKER PREFETCH, NETWORK ROLLBACK, USB, FS CHECKS
# ============================================================================
prefetch_docker_images() {
  [ "$DRY_RUN" = true ] && return 0
  command -v docker &>/dev/null || return 0
  detect_system_info
  local at=""
  case "$CACHED_MACHINE_ARCH" in
    x86_64) at="amd64";; aarch64) at="aarch64";; armv7l) at="armv7";; *) return 0;;
  esac
  msg_dim "Предзагрузка Docker-образов..."
  ( trap 'exit 0' INT TERM
    for img in supervisor dns cli audio multicast observer; do
    docker pull "ghcr.io/home-assistant/${at}-hassio-${img}:latest" 2>/dev/null || true
  done ) &
  PREFETCH_PID=$!; disown "$PREFETCH_PID" 2>/dev/null || true
}

wait_prefetch() {
  [ -n "$PREFETCH_PID" ] && kill -0 "$PREFETCH_PID" 2>/dev/null && {
    msg_dim "Ожидание предзагрузки..."
    wait "$PREFETCH_PID" 2>/dev/null || true
  }
  PREFETCH_PID=""
}

rollback_network() {
  msg_warn "Откат сети..."

  # 1. Остановить и отключить NetworkManager
  systemctl stop NetworkManager 2>/dev/null || true
  systemctl disable NetworkManager 2>/dev/null || true
  msg_dim "NetworkManager остановлен"

  # 2. Восстановить /etc/network/interfaces
  if [ -f "${BACKUP_DIR}/interfaces.bak" ]; then
    cp "${BACKUP_DIR}/interfaces.bak" /etc/network/interfaces 2>/dev/null
    msg_dim "interfaces восстановлен"
  fi

  # 3. Восстановить resolv.conf
  if [ -f "${BACKUP_DIR}/resolv.conf.bak" ]; then
    # Удалить симлинк если был создан
    rm -f /etc/resolv.conf 2>/dev/null
    cp "${BACKUP_DIR}/resolv.conf.bak" /etc/resolv.conf 2>/dev/null
    msg_dim "resolv.conf восстановлен"
  fi

  # 4. Остановить systemd-resolved (мог быть запущен на шаге network)
  systemctl stop systemd-resolved 2>/dev/null || true

  # 5. Включить и запустить ifupdown
  systemctl enable networking 2>/dev/null || true
  systemctl restart networking 2>/dev/null || true
  msg_dim "networking перезапущен"

  # 6. Если есть ifup — поднять интерфейс вручную
  local iface=""
  iface=$(ip -o link show 2>/dev/null | awk -F': ' '!/lo/{print $2; exit}')
  if [ -n "$iface" ] && command -v ifup &>/dev/null; then
    ifdown "$iface" 2>/dev/null || true
    ifup "$iface" 2>/dev/null || true
    msg_dim "Интерфейс ${iface} переподнят"
  fi

  # 7. Ждать появления сети
  local wait=0
  while [ $wait -lt 30 ]; do
    local ip=""
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -n "$ip" ]; then
      msg_ok "Сеть восстановлена: ${ip}"
      return 0
    fi
    sleep 3
    wait=$((wait + 3))
    msg_dim "Ожидание сети... ${wait}с"
  done

  # 8. Последняя попытка — dhclient напрямую
  if [ -n "$iface" ] && command -v dhclient &>/dev/null; then
    msg_dim "Попытка dhclient..."
    dhclient "$iface" 2>/dev/null || true
    sleep 5
    local ip=""
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -n "$ip" ]; then
      msg_ok "Сеть восстановлена через dhclient: ${ip}"
      return 0
    fi
  fi

  msg_error "Не удалось восстановить сеть!"
  msg_dim "Попробуйте вручную:"
  msg_dim "  sudo systemctl restart networking"
  msg_dim "  sudo ifup ${iface:-eth0}"
  msg_dim "  sudo dhclient ${iface:-eth0}"
  return 1
}

detect_usb_dongles() {
  [ "$OPT_USB_DETECT" != true ] && return
  msg_action "Поиск USB-устройств..."
  local found=false
  for dev in /dev/ttyUSB* /dev/ttyACM* /dev/serial/by-id/*; do
    [ -e "$dev" ] || continue
    local info
    info=$(udevadm info --query=all --name="$dev" 2>/dev/null) || continue
    case "$info" in
      *"Texas Instruments"*|*"Silicon Labs"*|*"dresden"*|*"ITEAD"*)
        msg_ok "Zigbee: ${dev}"; found=true;;
      *"Sigma Designs"*|*"Aeotec"*)
        msg_ok "Z-Wave: ${dev}"; found=true;;
    esac
  done
  hciconfig 2>/dev/null | grep -q "UP RUNNING" && { msg_ok "Bluetooth: активен"; found=true; }
  $found || msg_dim "USB-донглы не обнаружены"
}

check_broken_state() {
  if [ -f /var/lib/dpkg/updates/0001 ] || dpkg --audit 2>/dev/null | grep -qE '[a-z]'; then
    msg_warn "Обнаружена прерванная установка dpkg"
    msg_action "Восстановление..."
    dpkg --configure -a 2>/dev/null || true
    apt-get install -f -y 2>/dev/null || true
    msg_ok "dpkg восстановлен"
  fi
  if command -v docker &>/dev/null && ! docker info &>/dev/null; then
    msg_warn "Docker не отвечает"
    systemctl restart docker 2>/dev/null || true
    sleep 5
    docker info &>/dev/null && msg_ok "Docker восстановлен" || msg_warn "Docker всё ещё не работает"
  fi
}

check_filesystem() {
  touch /tmp/.ha_fs_test 2>/dev/null && rm -f /tmp/.ha_fs_test || {
    msg_error "Файловая система readonly!"
    return 1
  }
  dmesg 2>/dev/null | tail -100 | grep -qi "ext4.*error\|I/O error\|read-only" && {
    msg_warn "Ошибки ФС в dmesg"
    return 0
  }
  msg_ok "Файловая система OK"
}

verify_installed_scripts() {
  msg_action "Проверка утилит..."
  local ok=0 miss=0 fix=0
  local -A expected=(
    [ha-notify]=true
    [ha-health]=true
    [ha-watchdog]="$OPT_WATCHDOG"
    [ha-cleanup]="$OPT_WATCHDOG"
    [ha-net-recovery]="$OPT_WATCHDOG"
    [ha-backup]="$OPT_BACKUP"
    [ha-restore]="$OPT_BACKUP"
    [ha-thermal]="$OPT_THERMAL"
    [ha-boot-check]="$OPT_BOOT_RECOVERY"
    [ha-metrics]="$OPT_MONITORING"
  )
  for s in "${!expected[@]}"; do
    [ "${expected[$s]}" != true ] && continue
    local p="/usr/local/bin/$s"
    if [ -f "$p" ]; then
      if [ ! -x "$p" ]; then chmod +x "$p"; fix=$((fix+1)); fi
      ok=$((ok+1))
    else
      miss=$((miss+1))
    fi
  done
  [ $fix -gt 0 ] && msg_warn "Исправлены права: ${fix}"
  msg_ok "Утилиты: ${ok} ок, ${miss} отсутствуют"
}

# ============================================================================
# v9.x FEATURES
# ============================================================================
setup_wifi() {
  [ -z "$OPT_WIFI_SSID" ] && return 0
  command -v nmcli &>/dev/null || { msg_warn "nmcli недоступен для WiFi"; return 0; }

  # Защита от обрыва SSH: проверяем активный интерфейс маршрута по умолчанию
  local active_iface=""
  active_iface=$(ip route list default 2>/dev/null | awk '{print $5}' | head -1)
  
  # Если имя интерфейса начинается на 'w' (wlan0, wlp2s0), значит мы уже на WiFi
  if [[ "$active_iface" == w* ]]; then
    msg_ok "WiFi уже используется (${active_iface})"
    msg_dim "Подключение к '${OPT_WIFI_SSID}' пропущено для защиты текущей SSH-сессии"
    return 0
  fi

  msg_action "WiFi: ${OPT_WIFI_SSID}..."
  
  # Находим имя WiFi интерфейса (например, wlan0)
  local wifi_dev
  wifi_dev=$(nmcli -t -f DEVICE,TYPE dev status 2>/dev/null | grep ':wifi$' | head -1 | cut -d: -f1)

  if [ -z "$wifi_dev" ]; then
    msg_warn "WiFi адаптер не найден в системе"
    return 0
  fi

  # 1. Удаляем старый профиль с таким же именем (если остался от прошлых попыток)
  nmcli con delete "$OPT_WIFI_SSID" >/dev/null 2>&1 || true

  # 2. Создаем новое соединение и явно указываем SSID
  if ! nmcli con add type wifi ifname "$wifi_dev" con-name "$OPT_WIFI_SSID" ssid "$OPT_WIFI_SSID" >/dev/null 2>&1; then
    msg_error "Не удалось создать профиль WiFi"
    return 0
  fi

  # 3. Получаем UUID созданного подключения для надежной модификации.
  # Флаг -g (--get-fields) безопасно извлекает поле, даже если SSID содержит двоеточия или пробелы.
  local wifi_uuid
  wifi_uuid=$(nmcli -g UUID con show "$OPT_WIFI_SSID" 2>/dev/null)
  
  # Если профиль по имени не нашелся (имя исказилось), берем UUID активного Wi-Fi устройства
  if [ -z "$wifi_uuid" ] && [ -n "$wifi_dev" ]; then
    wifi_uuid=$(nmcli -g GENERAL.CON-UUID dev show "$wifi_dev" 2>/dev/null)
  fi

  if [ -n "$OPT_WIFI_PASS" ] && [ -n "$wifi_uuid" ]; then
    nmcli con modify "$wifi_uuid" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$OPT_WIFI_PASS" >/dev/null 2>&1
  fi

  # Отключение энергосбережения Wi-Fi для стабильности VPN (Tailscale)
  # Значение 2 = Power Save OFF. Предотвращает отвал интернета через пару минут.
  if [ -n "$wifi_uuid" ]; then
    nmcli con modify "$wifi_uuid" 802-11-wireless.powersave 2 >/dev/null 2>&1 || true
  fi

  # 4. Поднимаем соединение
  local connect_output
  connect_output=$(nmcli con up "$OPT_WIFI_SSID" ifname "$wifi_dev" 2>&1)
  local connect_rc=$?

  # Если команда сразу вернула ошибку (например, неверный пароль или сеть не найдена)
  if [ $connect_rc -ne 0 ]; then
    # Дадим 3 секунды на случай асинхронного подключения
    sleep 3
    local wifi_state
    wifi_state=$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null | grep "^${wifi_dev}:" | head -1 | cut -d: -f2)
    if [ "$wifi_state" = "connected" ]; then
      msg_ok "WiFi подключён (${wifi_dev})"
      return 0
    fi

    msg_warn "WiFi не удалось подключить"
    # Покажем пользователю, почему именно упало (NetworkManager пишет причину в stderr)
    msg_dim "Причина: $(echo "$connect_output" | head -2)"
    # Удаляем нерабочий профиль, чтобы не засорять систему
    nmcli con delete "$OPT_WIFI_SSID" >/dev/null 2>&1 || true
    return 0
  fi

  # 5. Если команда прошла успешно, ждём получения IP-адреса
  local wait_time=0
  local max_wait=15
  local wifi_state=""

  while [ $wait_time -lt $max_wait ]; do
    wifi_state=$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null | grep "^${wifi_dev}:" | head -1 | cut -d: -f2)
    
    if [ "$wifi_state" = "connected" ]; then
      msg_ok "WiFi подключён (${wifi_dev})"
      return 0
    fi
    
    sleep 2
    wait_time=$((wait_time + 2))
  done

  # Вышли по таймауту
  msg_warn "WiFi: таймаут получения IP (статус: ${wifi_state:-нет ответа})"
  msg_dim "Сеть может появиться позже"
}

do_benchmark() {
  header "ТЕСТ ПРОИЗВОДИТЕЛЬНОСТИ"
  detect_system_info
  BENCH_RAM_MB=$(free -m | awk '/Mem:/{print $2}')
  BENCH_CPU_CORES=$(nproc 2>/dev/null || echo 1)
  echo -e "   ${BOLD}CPU:${NC}  $(lscpu 2>/dev/null | awk -F: '/Model name/{print $2}' | xargs) (${BENCH_CPU_CORES} ядер)"
  echo -e "   ${BOLD}RAM:${NC}  ${BENCH_RAM_MB}МБ"
  echo -e "   ${BOLD}Арх:${NC}  ${CACHED_MACHINE_ARCH}"
  echo -e "   ${BOLD}ОС:${NC}   ${CACHED_PRETTY_NAME}"
  separator
  msg_action "Тест диска (50МБ)..."
  BENCH_DISK_SPEED=$(dd if=/dev/zero of=/tmp/.ha_bench bs=1M count=50 oflag=dsync 2>&1 | tail -1 | awk -F, '{print $NF}' | xargs)
  rm -f /tmp/.ha_bench
  echo -e "   ${BOLD}Диск:${NC} ${BENCH_DISK_SPEED}"
  separator

  # Verdict and recommendations
  BENCH_VERDICT="standard"
  if [ "$BENCH_RAM_MB" -lt 900 ]; then
    BENCH_VERDICT="impossible"
    echo -e "   ${BOLD}Вердикт:${NC} ${RED}НЕ подходит (нужно 1ГБ+ RAM)${NC}"
  elif [ "$BENCH_RAM_MB" -lt 1500 ]; then
    BENCH_VERDICT="minimal"
    echo -e "   ${BOLD}Вердикт:${NC} ${YELLOW}Подходит (мало RAM — рекомендуется minimal)${NC}"
  elif [ "$BENCH_RAM_MB" -lt 3000 ]; then
    BENCH_VERDICT="standard"
    echo -e "   ${BOLD}Вердикт:${NC} ${GREEN}Подходит (рекомендуется standard)${NC}"
  else
    BENCH_VERDICT="full"
    echo -e "   ${BOLD}Вердикт:${NC} ${GREEN}Отлично (можно full с мониторингом)${NC}"
  fi

  echo ""
  echo -e "   ${BOLD}Рекомендации:${NC}"
  echo -e "   Профиль: ${CYAN}${BENCH_VERDICT}${NC}"
  if [ "$BENCH_RAM_MB" -lt 1500 ]; then
    echo -e "   Swap:    ${CYAN}2048 МБ (файл на диске)${NC}"
  elif [ "$BENCH_RAM_MB" -lt 4000 ]; then
    echo -e "   Swap:    ${CYAN}zram (в RAM)${NC}"
  else
    echo -e "   Swap:    ${CYAN}none (достаточно RAM)${NC}"
  fi
  echo ""
}

generate_info_file() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"
  cat > "$HA_INFO_FILE" << INFOEOF
============================================
 Home Assistant - Информация об установке
 Создан: $(date)
 Hassify: v${SCRIPT_VERSION}
============================================

ДОСТУП:
  http://${ip}:8123
  http://homeassistant.local:8123

ПРОФИЛЬ: ${PROFILE:-custom}
МАШИНА:  ${HA_MACHINE}
ЧАСОВОЙ ПОЯС: ${OPT_TIMEZONE:-системный}

ПУТИ:
  Конфиг HA:    ${HASSIO_DIR}/homeassistant/
  Данные HA:    ${HASSIO_DIR}/
  Бэкапы:       ${HA_BACKUP_DIR}/
  Установщик:   ${HA_INSTALLER_DIR}/
  Логи:         ${LOG_DIR}/hassify_*.log
  Информация:   ${HA_INFO_FILE}

КОМАНДЫ:
  ha-health          Отчёт о здоровье
  ha-backup          Создать бэкап (если нет API токена - только конфиг Core)
  ha-restore         Восстановить из бэкапа
  ha-notify "текст"  Отправить уведомление

ПОЛНЫЙ БЭКАП (Через API HA - сохраняет аддоны и БД):
  1. Создайте Long-Lived Access Token в: Настройки профиля -> Безопасность
  2. Сохраните токен: echo 'ТОКЕН' | sudo tee ${HA_INSTALLER_DIR}/secrets/ha_api_token
  После этого ha-backup будет автоматически создавать полный снапшот системы.

ОБСЛУЖИВАНИЕ:
  sudo hassify --check       Диагностика
  sudo hassify --status      Мониторинг
  sudo hassify --update      Обновить HA
  sudo hassify --self-test   Самотест
  sudo hassify --benchmark   Тест железа

СЛУЖБЫ:
  systemctl status hassio-supervisor
  systemctl status hassio-apparmor
  docker ps

INFOEOF
  [ -n "$OPT_DATA_DIR" ] && echo "ВНЕШНЕЕ ХРАНИЛИЩЕ: ${OPT_DATA_DIR}" >> "$HA_INFO_FILE"
  [ "$OPT_UFW" = true ] && echo "ФАЙРВОЛ: ufw status" >> "$HA_INFO_FILE"
  chmod 644 "$HA_INFO_FILE"
  msg_ok "Информация: ${HA_INFO_FILE}"
}

# ============================================================================
# PROFILES
# ============================================================================
apply_profile() {
  local p="$1"
  # "custom" означает, что пользователь выбрал компоненты вручную в визарде.
  # Применять пресет не нужно, просто фиксируем статус.
  if [ "$p" = "custom" ]; then
    PROFILE="custom"
    RUN_WIZARD=false
    msg_ok "Профиль: custom (ручной выбор)"
    return 0
  fi
  [ -z "${PROFILES[$p]+x}" ] && { msg_error "Профиль '$p' не найден. Доступные: ${!PROFILES[*]}"; exit 1; }
  eval "${PROFILES[$p]}"
  PROFILE="$p"
  RUN_WIZARD=false
  msg_ok "Профиль: ${p}"
}

# ============================================================================
# WIZARD HELPERS
# ============================================================================

# Ask: restart wizard or exit? Returns 0=restart, 1=exit
_wizard_cancelled() {
  if command -v whiptail &>/dev/null; then
    whiptail --title "Отменено" --yesno "Вернуться в главное меню?\n\nДа = главное меню\nНет = выйти из скрипта" 10 50
    return $?
  else
    echo "" >&2
    echo -en "   Вернуться в меню? (д/н): " >&2
    local ans; read -r ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || [ "$ans" = "д" ] || [ "$ans" = "Д" ] && return 0
    return 1
  fi
}

# whiptail inputbox (returns empty + rc!=0 on ESC)
_whip_input() {
  local title="$1" body="$2" default="$3"
  whiptail --title "$title" --inputbox "$body" 14 60 "$default" 3>&1 1>&2 2>&3
}

# whiptail menu
_whip_menu() {
  local title="$1"; shift
  whiptail --title "$title" --menu "" 18 65 10 "$@" 3>&1 1>&2 2>&3
}

# Select components (returns 0=ok, 1=cancel)
_wizard_select_components() {
  if command -v whiptail &>/dev/null; then
    local ch=""
    ch=$(whiptail --title "Компоненты" --checklist "Пробел - переключить" 30 72 18 \
      "ZRAM" "ZRAM swap" ON "EMMC" "Оптимизация eMMC" ON "USBPOWER" "USB питание" ON \
      "UFW" "Файрвол" ON "SSHHARD" "Защита SSH" ON "AUTOUPD" "Автообновления" ON \
      "WATCHDOG" "Watchdog" ON "THERMAL" "Термомонитор" ON "BACKUP" "Бэкапы" ON \
      "HACS" "HACS" ON "HOSTNAME" "Имя хоста" ON "MONITOR" "Мониторинг" OFF \
      "USBDETECT" "Поиск USB" ON "BOOTRECOV" "Восст. загрузки" ON \
      "STATICIP" "Стат. IP" OFF "TELEGRAM" "Telegram" OFF \
      "TAILSCALE" "Tailscale VPN (удал. доступ)" OFF "CLOUDFLARED" "Cloudflare Tunnel (публичный HTTPS)" OFF \
      "RBACKUP" "Удал. бэкап (rclone/rsync)" OFF \
      3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && return 1

    OPT_ZRAM=false; OPT_EMMC_TUNING=false; OPT_USB_POWER=false; OPT_UFW=false
    OPT_SSH_HARDENING=false; OPT_AUTOUPDATE=false; OPT_WATCHDOG=false; OPT_THERMAL=false
    OPT_BACKUP=false; OPT_HACS=false; OPT_HOSTNAME=false; OPT_STATIC_IP=false
    OPT_TELEGRAM=false; OPT_MONITORING=false; OPT_TAILSCALE=false; OPT_CLOUDFLARED=false
    OPT_REMOTE_BACKUP=false; OPT_BOOT_RECOVERY=false; OPT_USB_DETECT=false

    [[ $ch == *ZRAM* ]]      && OPT_ZRAM=true
    [[ $ch == *EMMC* ]]      && OPT_EMMC_TUNING=true
    [[ $ch == *USBPOWER* ]]  && OPT_USB_POWER=true
    [[ $ch == *UFW* ]]       && OPT_UFW=true
    [[ $ch == *SSHHARD* ]]   && OPT_SSH_HARDENING=true
    [[ $ch == *AUTOUPD* ]]   && OPT_AUTOUPDATE=true
    [[ $ch == *WATCHDOG* ]]  && OPT_WATCHDOG=true
    [[ $ch == *THERMAL* ]]   && OPT_THERMAL=true
    [[ $ch == *BACKUP* ]]    && OPT_BACKUP=true
    [[ $ch == *HACS* ]]      && OPT_HACS=true
    [[ $ch == *HOSTNAME* ]]  && OPT_HOSTNAME=true
    [[ $ch == *STATICIP* ]]  && OPT_STATIC_IP=true
    [[ $ch == *TELEGRAM* ]]  && OPT_TELEGRAM=true
    [[ $ch == *MONITOR* ]]   && OPT_MONITORING=true
    [[ $ch == *TAILSCALE* ]]  && OPT_TAILSCALE=true
    [[ $ch == *CLOUDFLARED* ]] && OPT_CLOUDFLARED=true
    [[ $ch == *RBACKUP* ]]   && OPT_REMOTE_BACKUP=true
    [[ $ch == *BOOTRECOV* ]] && OPT_BOOT_RECOVERY=true
    [[ $ch == *USBDETECT* ]] && OPT_USB_DETECT=true
  else
    echo -e "\n   ${BOLD}Компоненты (д/н):${NC}" >&2
    text_yesno "ZRAM swap" "y"         && OPT_ZRAM=true         || OPT_ZRAM=false
    text_yesno "Оптимизация eMMC" "y"  && OPT_EMMC_TUNING=true || OPT_EMMC_TUNING=false
    text_yesno "Файрвол" "y"           && OPT_UFW=true          || OPT_UFW=false
    text_yesno "Защита SSH" "y"        && OPT_SSH_HARDENING=true || OPT_SSH_HARDENING=false
    text_yesno "Watchdog" "y"          && OPT_WATCHDOG=true     || OPT_WATCHDOG=false
    text_yesno "Бэкапы" "y"            && OPT_BACKUP=true       || OPT_BACKUP=false
    text_yesno "HACS" "y"              && OPT_HACS=true         || OPT_HACS=false
    text_yesno "Имя хоста" "y"         && OPT_HOSTNAME=true     || OPT_HOSTNAME=false
    text_yesno "Мониторинг" "n"        && OPT_MONITORING=true   || OPT_MONITORING=false
    text_yesno "Стат. IP" "n"          && OPT_STATIC_IP=true    || OPT_STATIC_IP=false
    text_yesno "Telegram" "n"          && OPT_TELEGRAM=true     || OPT_TELEGRAM=false
    text_yesno "Tailscale VPN" "n"     && OPT_TAILSCALE=true   || OPT_TAILSCALE=false
    text_yesno "Cloudflare Tunnel" "n" && OPT_CLOUDFLARED=true || OPT_CLOUDFLARED=false
    text_yesno "Удал. бэкап" "n"       && OPT_REMOTE_BACKUP=true || OPT_REMOTE_BACKUP=false
  fi
  PROFILE="custom"
  return 0
}

# ============================================================================
# PROMPT: Интерактивные шаги визарда
# ============================================================================

# prompt_: Выбор профиля и кастомных компонентов
prompt_wizard_profile() {
  local HAS_WHIPTAIL=false
  command -v whiptail &>/dev/null && HAS_WHIPTAIL=true

  local prof_title="Профиль"
  [ -n "$BENCH_VERDICT" ] && prof_title="Профиль (рекомендуется: ${BENCH_VERDICT})"
  local prof=""

  if [ "$HAS_WHIPTAIL" = true ]; then
    prof=$(_whip_menu "$prof_title" \
      "minimal"  "Только HA + Docker (без доп. компонентов)" \
      "standard" "Рекомендуемый (файрвол, бэкапы, watchdog)" \
      "full"     "Полный (+ мониторинг Prometheus)" \
      "server"   "Сервер (+ стат. IP + мониторинг)" \
      "dev"      "Разработчик (HA + HACS, без оптимизаций)" \
      "custom"   "Выбрать компоненты вручную") || return 1
  else
    prof=$(text_menu "$prof_title" "Выберите:" \
      "minimal" "Только HA" "standard" "Рекомендуемый" "full" "Полный" \
      "server" "Сервер" "dev" "Разработчик" "custom" "Вручную") || return 1
  fi

  if [ "$prof" = "custom" ]; then
    _wizard_select_components || return 1
    # Custom-specific: locale
    local curloc; curloc=$(locale 2>/dev/null | awk -F= '/^LANG=/{print $2}') || curloc="C.UTF-8"
    if [ "$HAS_WHIPTAIL" = true ]; then
      if whiptail --title "Локаль" --yesno "Сменить локаль?\nТекущая: ${curloc}" 10 50 --defaultno 2>/dev/null; then
        OPT_LOCALE=$(_whip_input "Локаль" "Например: ru_RU.UTF-8" "$curloc") || OPT_LOCALE=""
      fi
    else
      text_yesno "Сменить локаль? (${curloc})" "n" && OPT_LOCALE=$(text_input "Локаль" "$curloc")
    fi
    # Custom-specific: docker mirror
    if [ "$HAS_WHIPTAIL" = true ]; then
      if whiptail --title "Зеркало Docker" --yesno "Использовать зеркало?\n(Если Docker Hub заблокирован)" 10 55 --defaultno 2>/dev/null; then
        OPT_DOCKER_MIRROR=$(_whip_input "URL зеркала" "" "") || OPT_DOCKER_MIRROR=""
      fi
    else
      text_yesno "Зеркало Docker? (если заблокирован)" "n" && OPT_DOCKER_MIRROR=$(text_input "URL" "")
    fi
  else
    apply_profile "$prof"
  fi
  return 0
}

# prompt_: Системные настройки (Таймзона, Загрузчик, Swap, Диск)
prompt_wizard_system() {
  local HAS_WHIPTAIL=false; command -v whiptail &>/dev/null && HAS_WHIPTAIL=true
  local ram_mb; ram_mb=$(free -m | awk '/Mem:/{print $2}')
  local disk_mb; disk_mb=$(df -m / | awk 'NR==2{print $4}')

  # Timezone
  local curtz; curtz=$(timedatectl 2>/dev/null | awk '/Time zone/{print $3}') || curtz="UTC"
  if [ "$HAS_WHIPTAIL" = true ]; then
    OPT_TIMEZONE=$(_whip_input "Часовой пояс" "Например: Europe/Moscow\nТекущий: ${curtz}" "$curtz") || return 1
  else
    OPT_TIMEZONE=$(text_input "Часовой пояс (${curtz})" "$curtz")
  fi
  OPT_TIMEZONE="${OPT_TIMEZONE:-$curtz}"

  # Boot dir
  if [ "$HAS_WHIPTAIL" = true ]; then
    if ! whiptail --title "Раздел загрузчика" --yesno "Использовать автоопределение каталога загрузчика?\n\n(Выберите 'Нет', если у вас TV-box с двумя накопителями (SD+eMMC) или загрузчик не монтируется автоматически)" 12 65; then
      BOOT_DEV_FSTAB=$(_whip_input "Устройство загрузчика" "Укажите путь к партиции (например, /dev/mmcblk0p1)" "") || BOOT_DEV_FSTAB=""
    fi
  else
    if ! text_yesno "Автоопределение загрузчика?" "y"; then
      BOOT_DEV_FSTAB=$(text_input "Устройство партиции загрузчика (напр. /dev/mmcblk0p1)" "")
    fi
  fi

  # Swap
  local eff_ram="${BENCH_RAM_MB:-$ram_mb}"
  local swap_rec="zram"; [ "$eff_ram" -lt 1500 ] && swap_rec="2048"; [ "$eff_ram" -gt 4000 ] && swap_rec="none"
  local swap_title="Swap (RAM: ${eff_ram}МБ, рекомендуется: ${swap_rec})"
  if [ "$HAS_WHIPTAIL" = true ]; then
    OPT_SWAP_SIZE=$(_whip_menu "$swap_title" \
      "zram" "ZRAM в RAM (рекомендуется 2-4ГБ)" \
      "1024" "Файл 1ГБ на диске" \
      "2048" "Файл 2ГБ (для устройств с 1ГБ RAM)" \
      "4096" "Файл 4ГБ" \
      "none" "Без swap (если RAM 4ГБ+)") || return 1
  else
    OPT_SWAP_SIZE=$(text_menu "$swap_title" "Выберите:" \
      "zram" "ZRAM" "1024" "1ГБ" "2048" "2ГБ" "none" "Без swap") || OPT_SWAP_SIZE="$swap_rec"
  fi

  # Data dir
  local dw=""; [ "$disk_mb" -lt 20000 ] && dw=" (Внимание: только ${disk_mb}МБ!)"
  if [ "$HAS_WHIPTAIL" = true ]; then
    if whiptail --title "Внешний диск" --yesno "Перенести данные на внешний диск?${dw}\n\nРекомендуется для eMMC < 32ГБ" 12 60 --defaultno 2>/dev/null; then
      local mi; mi=$(lsblk -o NAME,SIZE,MOUNTPOINT,FSTYPE 2>/dev/null | grep -E "sd|nvme" | head -10)
      OPT_DATA_DIR=$(_whip_input "Путь к данным" "${mi}" "/mnt/data") || OPT_DATA_DIR=""
    fi
  else
    if text_yesno "Внешний диск?${dw}" "n"; then
      OPT_DATA_DIR=$(text_input "Путь к данным" "/mnt/data")
    fi
  fi
  return 0
}

# prompt_: Настройки сети (WiFi, Static IP, VPN, Tunnel)
prompt_wizard_network() {
  local HAS_WHIPTAIL=false; command -v whiptail &>/dev/null && HAS_WHIPTAIL=true

  # WiFi
  local has_wifi=false
  { iw dev 2>/dev/null | grep -q Interface || ip link 2>/dev/null | grep -q wlan; } && has_wifi=true
  if [ "$has_wifi" = true ]; then
    local do_wifi=false
    if [ "$HAS_WHIPTAIL" = true ]; then
      whiptail --title "WiFi" --yesno "WiFi-адаптер обнаружен.\nНастроить подключение?" 8 50 --defaultno 2>/dev/null && do_wifi=true
    else
      text_yesno "WiFi-адаптер найден. Настроить?" "n" && do_wifi=true
    fi
    if [ "$do_wifi" = true ]; then
      local wl; wl=$(nmcli -t -f SSID dev wifi list 2>/dev/null | sort -u | head -10 | tr '\n' ', ') || wl=""
      if [ "$HAS_WHIPTAIL" = true ]; then
        OPT_WIFI_SSID=$(_whip_input "WiFi" "Имя сети (SSID)\n\nДоступные: ${wl}" "") || OPT_WIFI_SSID=""
        [ -n "$OPT_WIFI_SSID" ] && { OPT_WIFI_PASS=$(whiptail --title "Пароль WiFi" --passwordbox "Пароль:" 10 50 3>&1 1>&2 2>&3) || OPT_WIFI_SSID=""; }
      else
        [ -n "$wl" ] && echo -e "   Рядом: ${wl}" >&2
        OPT_WIFI_SSID=$(text_input "SSID" "")
        [ -n "$OPT_WIFI_SSID" ] && OPT_WIFI_PASS=$(text_password "Пароль WiFi")
      fi
    fi
  fi

  # Static IP
  if [ "$OPT_STATIC_IP" = true ]; then
    local cip; cip=$(hostname -I 2>/dev/null | awk '{print $1}') || cip=""
    local cgw; cgw=$(ip route 2>/dev/null | awk '/default/{print $3}' | head -1) || cgw=""
    while true; do
      if [ "$HAS_WHIPTAIL" = true ]; then STATIC_IP=$(_whip_input "Статический IP" "IP-адрес устройства" "$cip") || { OPT_STATIC_IP=false; break; }
      else STATIC_IP=$(text_input "Статический IP" "$cip"); [ -z "$STATIC_IP" ] && { OPT_STATIC_IP=false; break; }; fi
      validate_ip "$STATIC_IP" && break; msg_warn "Неверный IP-адрес"
    done
    if [ "$OPT_STATIC_IP" = true ]; then
      while true; do
        if [ "$HAS_WHIPTAIL" = true ]; then STATIC_GW=$(_whip_input "Шлюз" "IP-адрес шлюза (роутера)" "$cgw") || { STATIC_GW="$cgw"; break; }
        else STATIC_GW=$(text_input "Шлюз" "$cgw"); fi
        validate_gw "$STATIC_GW" && break; msg_warn "Неверный шлюз"
      done
      while true; do
        if [ "$HAS_WHIPTAIL" = true ]; then STATIC_DNS=$(_whip_input "DNS" "DNS-серверы через запятую" "8.8.8.8,1.1.1.1") || { STATIC_DNS="8.8.8.8,1.1.1.1"; break; }
        else STATIC_DNS=$(text_input "DNS (через запятую)" "8.8.8.8,1.1.1.1"); fi
        validate_dns_list "$STATIC_DNS" && break; msg_warn "Неверный DNS"
      done
    fi
  fi

  # Tailscale
  if [ "$OPT_TAILSCALE" = true ]; then
    if [ "$HAS_WHIPTAIL" = true ]; then
      if whiptail --title "Tailscale VPN" --yesno "Tailscale обеспечивает безопасный удаленный доступ без открытия портов.\n\nУстановить Tailscale на этот бокс?\n\n(Авторизацию нужно будет пройти вручную)" 12 65 --defaultno 2>/dev/null; then
        TS_AUTHKEY=$(_whip_input "Auth Key (необязательно)" "Если у вас есть Tailscale Auth Key,\nвставьте его для автоматической авторизации.\nИначе оставьте пустым." "") || TS_AUTHKEY=""
      else OPT_TAILSCALE=false; fi
    else
      text_yesno "Установить Tailscale VPN для удаленного доступа?" "n" && { TS_AUTHKEY=$(text_input "Tailscale Auth Key (оставьте пустым для ручной авторизации)" ""); }
    fi
  fi

  # Cloudflare
  if [ "$OPT_CLOUDFLARED" = true ]; then
    if [ "$HAS_WHIPTAIL" = true ]; then
      CF_TUNNEL_TOKEN=$(_whip_input "Cloudflare Tunnel Token" "Вставьте токен туннеля из Cloudflare Zero Trust Dashboard.\n\nОставьте ПУСТЫМ, если хотите настроить туннель вручную позже (sudo cloudflared service install <ТОКЕН>)." "") || CF_TUNNEL_TOKEN=""
    else
      CF_TUNNEL_TOKEN=$(text_input "Cloudflare Tunnel Token (оставьте пустым для настройки позже)" "")
    fi
  fi
  return 0
}

# prompt_: Уведомления
prompt_wizard_notifications() {
  local HAS_WHIPTAIL=false; command -v whiptail &>/dev/null && HAS_WHIPTAIL=true

  if [ "$OPT_TELEGRAM" = true ]; then
    if [ "$HAS_WHIPTAIL" = true ]; then
      TG_TOKEN=$(_whip_input "Telegram" "Токен бота\n\nПолучите у @BotFather" "") || TG_TOKEN=""
      [ -n "$TG_TOKEN" ] && { TG_CHAT=$(_whip_input "Telegram" "Chat ID\n\nУзнайте у @userinfobot" "") || TG_CHAT=""; }
    else
      TG_TOKEN=$(text_input "Токен бота" "")
      [ -n "$TG_TOKEN" ] && TG_CHAT=$(text_input "Chat ID" "")
    fi
    { [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ]; } && OPT_TELEGRAM=false
  fi

  if [ "$OPT_TELEGRAM" != true ] && [ -z "$OPT_WEBHOOK_URL" ]; then
    local notif="none"
    if [ "$HAS_WHIPTAIL" = true ]; then
      notif=$(_whip_menu "Уведомления" \
        "none"     "Без уведомлений" \
        "telegram" "Telegram бот" \
        "ntfy"     "ntfy.sh (бесплатно, без регистрации)" \
        "discord"  "Discord webhook" \
        "custom"   "Свой URL (Slack, Gotify и др.)") || notif="none"
    else
      notif=$(text_menu "Уведомления" "Способ:" \
        "none" "Нет" "telegram" "Telegram" "ntfy" "ntfy.sh" \
        "discord" "Discord" "custom" "URL") || notif="none"
    fi
    case "$notif" in
      telegram)
        OPT_TELEGRAM=true
        if [ "$HAS_WHIPTAIL" = true ]; then
          TG_TOKEN=$(_whip_input "Telegram" "Токен бота" "") || TG_TOKEN=""
          [ -n "$TG_TOKEN" ] && { TG_CHAT=$(_whip_input "Telegram" "Chat ID" "") || TG_CHAT=""; }
        else
          TG_TOKEN=$(text_input "Токен бота" "")
          [ -n "$TG_TOKEN" ] && TG_CHAT=$(text_input "Chat ID" "")
        fi
        { [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ]; } && OPT_TELEGRAM=false
        ;;
      ntfy)
        local topic=""
        if [ "$HAS_WHIPTAIL" = true ]; then
          topic=$(_whip_input "ntfy.sh" "Название темы\n\nУстановите ntfy на телефон и подпишитесь на эту тему" "ha-$(hostname 2>/dev/null || echo box)") || topic=""
        else
          topic=$(text_input "Тема ntfy.sh" "ha-$(hostname 2>/dev/null || echo box)")
        fi
        [ -n "$topic" ] && OPT_WEBHOOK_URL="https://ntfy.sh/${topic}"
        ;;
      discord|custom)
        if [ "$HAS_WHIPTAIL" = true ]; then
          OPT_WEBHOOK_URL=$(_whip_input "Webhook" "URL для отправки уведомлений" "") || OPT_WEBHOOK_URL=""
        else
          OPT_WEBHOOK_URL=$(text_input "Webhook URL" "")
        fi
        ;;
    esac
  fi
  return 0
}

# prompt_: Бэкапы и перезагрузка
prompt_wizard_backup() {
  local HAS_WHIPTAIL=false; command -v whiptail &>/dev/null && HAS_WHIPTAIL=true

  # Restore backup
  local do_restore=false
  if [ "$HAS_WHIPTAIL" = true ]; then
    whiptail --title "Восстановление" --yesno "Есть бэкап предыдущей установки?\n\nЕсли да — он будет восстановлен после установки" 10 55 --defaultno 2>/dev/null && do_restore=true
  else
    text_yesno "Восстановить бэкап после установки?" "n" && do_restore=true
  fi
  if [ "$do_restore" = true ]; then
    local found=""
    for d in /mnt /media /tmp /var/backups; do
      local fb; fb=$(find "$d" -maxdepth 3 -name "ha_config_*.tar.gz" -type f 2>/dev/null | head -3)
      [ -n "$fb" ] && found="${found}${fb}"$'\n'
    done
    if [ "$HAS_WHIPTAIL" = true ]; then
      local hint=""; [ -n "$found" ] && hint="\nНайденные бэкапы:\n${found}"
      OPT_RESTORE_BACKUP=$(_whip_input "Файл бэкапа" "Полный путь к .tar.gz файлу${hint}" "") || OPT_RESTORE_BACKUP=""
    else
      [ -n "$found" ] && { echo -e "   Бэкапы:" >&2; echo "$found" | while IFS= read -r l; do [ -n "$l" ] && echo "   $l" >&2; done; }
      OPT_RESTORE_BACKUP=$(text_input "Путь к .tar.gz" "")
    fi
    [ -n "$OPT_RESTORE_BACKUP" ] && [ ! -f "$OPT_RESTORE_BACKUP" ] && { msg_warn "Файл не найден: ${OPT_RESTORE_BACKUP}"; OPT_RESTORE_BACKUP=""; }
  fi

  # Remote backup
  if [ "$OPT_REMOTE_BACKUP" = true ]; then
    if [ "$HAS_WHIPTAIL" = true ]; then
      REMOTE_BACKUP_TARGET=$(_whip_input "Удалённый бэкап" "SSH: ssh://user@host:/path\nОблако (rclone): rclone://yandex:HA_Backups\n\nВНИМАНИЕ: Для облака потребуется ручная настройка rclone после установки!" "") || OPT_REMOTE_BACKUP=false
    else
      REMOTE_BACKUP_TARGET=$(text_input "Удал. бэкап (ssh://... или rclone://yandex:path)" "")
      [ -z "$REMOTE_BACKUP_TARGET" ] && OPT_REMOTE_BACKUP=false
    fi
  fi

  # Auto-reboot
  if [ "$HAS_WHIPTAIL" = true ]; then
    whiptail --title "Авто-перезагрузка" --yesno "Разрешить автоматическую перезагрузку?\n\nAppArmor может потребовать перезагрузку.\nСкрипт продолжит установку после неё." 12 58 2>/dev/null && OPT_AUTO_REBOOT=true
  else
    text_yesno "Авто-перезагрузка?" "y" && OPT_AUTO_REBOOT=true
  fi
  return 0
}

# ============================================================================
# FORMAT: Форматирование данных для вывода
# ============================================================================

# Формирование строки подтверждения установки
format_wizard_summary() {
  local s="Установка Home Assistant Supervised\n\n"
  
  # --- Система ---
  local swap_desc="${OPT_SWAP_SIZE:-zram}"
  if [ "$OPT_SWAP_SIZE" = "zram" ]; then swap_desc="ZRAM (60% RAM)"
  elif [[ "$OPT_SWAP_SIZE" =~ ^[0-9]+$ ]]; then swap_desc="Файл ${OPT_SWAP_SIZE}MB"
  elif [ "$OPT_SWAP_SIZE" = "none" ]; then swap_desc="Отключен"; fi

  local sys="Профиль: ${PROFILE}"; sys+=", Часовой пояс: ${OPT_TIMEZONE}"
  [ -n "$OPT_LOCALE" ] && sys+=", Локаль: ${OPT_LOCALE}"
  sys+=", Swap: ${swap_desc}"
  [ "$OPT_AUTO_REBOOT" = true ] && sys+=", Авто-перезагрузка"
  s+="  СИСТЕМА:      ${sys}\n"

  # --- Доступ и Сеть ---
  local net=""
  if [ "$OPT_TAILSCALE" = true ]; then net+="Tailscale"; [ -n "$TS_AUTHKEY" ] && net+=" (ключ задан)" || net+=" (ручной логин)"; net+=", "; fi
  if [ "$OPT_CLOUDFLARED" = true ]; then net+="Cloudflare"; [ -n "$CF_TUNNEL_TOKEN" ] && net+=" (токен задан)" || net+=" (ручная настройка)"; net+=", "; fi
  [ -n "$OPT_WIFI_SSID" ] && net+="WiFi: ${OPT_WIFI_SSID}, "
  [ "$OPT_STATIC_IP" = true ] && net+="IP: ${STATIC_IP}/${STATIC_GW}, DNS: ${STATIC_DNS}, "
  if [ -n "$net" ]; then net="${net%, }"; s+="  ДОСТУП:       ${net}\n"; fi

  # --- Безопасность ---
  local sec=""
  [ "$OPT_UFW" = true ] && sec+="UFW, "
  [ "$OPT_SSH_HARDENING" = true ] && sec+="Защита SSH, "
  [ "$OPT_AUTOUPDATE" = true ] && sec+="Автообновления ОС, "
  if [ -n "$sec" ]; then sec="${sec%, }"; s+="  БЕЗОПАСНОСТЬ: ${sec}\n"; fi

  # --- Надежность ---
  local rel=""
  [ "$OPT_WATCHDOG" = true ] && rel+="Watchdog, "
  [ "$OPT_THERMAL" = true ] && rel+="Термомонитор, "
  [ "$OPT_BOOT_RECOVERY" = true ] && rel+="Восст. загрузки, "
  if [ -n "$rel" ]; then rel="${rel%, }"; s+="  НАДЕЖНОСТЬ:   ${rel}\n"; fi

  # --- Оптимизация ---
  local opt=""
  [ "$OPT_EMMC_TUNING" = true ] && opt+="eMMC (noatime), "
  [ "$OPT_USB_POWER" = true ] && opt+="USB питание, "
  [ "$OPT_USB_DETECT" = true ] && opt+="Детект USB, "
  if [ -n "$opt" ]; then opt="${opt%, }"; s+="  ОПТИМИЗАЦИЯ:  ${opt}\n"; fi

  # --- Бэкапы ---
  local bak=""
  [ "$OPT_BACKUP" = true ] && bak+="Локальные, "
  if [ "$OPT_REMOTE_BACKUP" = true ] && [ -n "$REMOTE_BACKUP_TARGET" ]; then bak+="Удаленные (${REMOTE_BACKUP_TARGET}), "; fi
  [ -n "$OPT_RESTORE_BACKUP" ] && bak+="Восст. из $(basename "$OPT_RESTORE_BACKUP"), "
  if [ -n "$bak" ]; then bak="${bak%, }"; s+="  БЭКАПЫ:       ${bak}\n"; fi

  # --- Компоненты HA ---
  local ha_comp=""
  [ "$OPT_HACS" = true ] && ha_comp+="HACS, "
  [ "$OPT_HOSTNAME" = true ] && ha_comp+="Hostname, "
  [ "$OPT_MONITORING" = true ] && ha_comp+="Prometheus, "
  if [ -n "$ha_comp" ]; then ha_comp="${ha_comp%, }"; s+="  КОМПОНЕНТЫ:   ${ha_comp}\n"; fi

  # --- Уведомления ---
  local notif=""
  [ "$OPT_TELEGRAM" = true ] && notif+="Telegram, "
  [ -n "$OPT_WEBHOOK_URL" ] && notif+="Webhook (${OPT_WEBHOOK_URL}), "
  if [ -n "$notif" ]; then notif="${notif%, }"; s+="  УВЕДОМЛЕНИЯ:  ${notif}\n"; fi

  # --- Расположение ---
  local loc=""
  [ -n "$OPT_DATA_DIR" ] && loc+="Данные: ${OPT_DATA_DIR}, "
  [ -n "$BOOT_DEV_FSTAB" ] && loc+="Загрузчик: ${BOOT_DEV_FSTAB}, "
  [ -n "$OPT_DOCKER_MIRROR" ] && loc+="Зеркало Docker: ${OPT_DOCKER_MIRROR}, "
  if [ -n "$loc" ]; then loc="${loc%, }"; s+="  РАСПОЛОЖЕНИЕ: ${loc}\n"; fi

  s+="\nНачать установку? (Нет = вернуться в меню)"
  echo "$s"
}

# ============================================================================
# MAIN WIZARD (ESC on any step = restart or exit)
# ============================================================================
run_wizard() {
  local HAS_WHIPTAIL=false
  command -v whiptail &>/dev/null && HAS_WHIPTAIL=true
  [ "$HAS_WHIPTAIL" = false ] && {
    apt-get update -qq 2>/dev/null && apt-get install -y whiptail -qq 2>/dev/null && HAS_WHIPTAIL=true
  }

  detect_system_info
  local si="${CACHED_PRETTY_NAME:-${CACHED_CODENAME}} (${CACHED_MACHINE_ARCH})"
  is_armbian && si+=" [Armbian]"
  local ram_mb; ram_mb=$(free -m | awk '/Mem:/{print $2}')
  local disk_mb; disk_mb=$(df -m / | awk 'NR==2{print $4}')

  # Welcome
  if [ "$HAS_WHIPTAIL" = true ]; then
    whiptail --title "Hassify v${SCRIPT_VERSION}" --msgbox \
      "Установщик Home Assistant Supervised\n\n${si}\nRAM: ${ram_mb}МБ | Диск: ${disk_mb}МБ\n\nESC = вернуться в меню" 14 64
  else
    header "Hassify v${SCRIPT_VERSION}"
    msg_info "${si}"; msg_info "RAM: ${ram_mb}МБ | Диск: ${disk_mb}МБ"; echo ""
  fi

  # Reset variables
  PROFILE=""
  OPT_TIMEZONE=""; OPT_LOCALE=""; OPT_SWAP_SIZE=""; OPT_DATA_DIR=""
  OPT_WIFI_SSID=""; OPT_WIFI_PASS=""; OPT_DOCKER_MIRROR=""
  OPT_WEBHOOK_URL=""; OPT_RESTORE_BACKUP=""
  OPT_AUTO_REBOOT=false
  TG_TOKEN=""; TG_CHAT=""
  STATIC_IP=""; STATIC_GW=""; STATIC_DNS=""
  OPT_TAILSCALE=false; TS_AUTHKEY=""
  REMOTE_BACKUP_TARGET=""
  OPT_CLOUDFLARED=false; CF_TUNNEL_TOKEN=""

  # --- Run Steps ---
  prompt_wizard_profile || { _wizard_cancelled && return 1 || exit 0; }
  prompt_wizard_system || { _wizard_cancelled && return 1 || exit 0; }
  prompt_wizard_network || { _wizard_cancelled && return 1 || exit 0; }
  prompt_wizard_notifications || { _wizard_cancelled && return 1 || exit 0; }
  prompt_wizard_backup || { _wizard_cancelled && return 1 || exit 0; }

  # --- Confirmation ---
  local summary; summary=$(format_wizard_summary)

  if [ "$HAS_WHIPTAIL" = true ]; then
    whiptail --title "Подтверждение" --yesno "$summary" 25 78 && return 0
    _wizard_cancelled && return 1 || exit 0
  else
    echo -e "\n$summary" >&2
    text_yesno "Начать?" "y" && return 0
    _wizard_cancelled && return 1 || exit 0
  fi
}

# ============================================================================
# MODULES MENU (Установка отдельных фич на готовую систему)
# ============================================================================
show_modules_menu() {
  while true; do
    local mod
    if command -v whiptail &>/dev/null; then
      mod=$(whiptail --title "Модули и Фичи" --menu \
        "Выберите модуль для установки.\nЯдро Home Assistant затронуто НЕ БУДЕТ.\n\nESC - вернуться в главное меню" \
        28 60 17 \
        "== СИСТЕМА ==" "" \
        "zram"          "ZRAM Swap (сжатие в RAM)" \
        "emmc"          "Оптимизация eMMC (noatime)" \
        "usbpower"      "USB питание (откл. спящего режима)" \
        "== НАДЕЖНОСТЬ ==" "" \
        "bootrecovery"  "Восст. загрузки (проверка Docker)" \
        "watchdog"      "Watchdog (перезапуск + алерты)" \
        "== ОПОВЕЩЕНИЯ ==" "" \
        "notifications" "Настройка Telegram / Webhook" \
        "== БЭКАПЫ ==" "" \
        "backups"       "Бэкапы (локальные + снапшоты)" \
        "remotebackup"  "Удаленный бэкап (rclone / SSH)" \
        "== ИНТЕГРАЦИИ ==" "" \
        "hacs"          "HACS (магазин компонентов)" \
        "mdns"          "mDNS (доступ по .local)" \
        "== СЕТЬ И ДОСТУП ==" "" \
        "tailscale"     "Tailscale VPN (удал. доступ)" \
        "cloudflare"    "Cloudflare Tunnel (HTTPS)" \
        "security"      "Безопасность (UFW + SSH)" \
        "== МОНИТОРИНГ ==" "" \
        "monitoring"    "Мониторинг (Prometheus метрики)" \
        3>&1 1>&2 2>&3) || return 1
    else
      mod=$(text_menu "Модули и Фичи" "Выберите:" \
        "zram"          "ZRAM Swap" \
        "emmc"          "Оптимизация eMMC" \
        "usbpower"      "USB питание" \
        "bootrecovery"  "Восст. загрузки" \
        "watchdog"      "Watchdog" \
        "notifications" "Уведомления (TG/Webhook)" \
        "backups"       "Бэкапы" \
        "remotebackup"  "Удал. бэкап (rclone/SSH)" \
        "hacs"          "HACS" \
        "mdns"          "mDNS (Avahi)" \
        "tailscale"     "Tailscale VPN" \
        "cloudflare"    "Cloudflare Tunnel" \
        "security"      "Безопасность (UFW)" \
        "monitoring"    "Мониторинг (Prometheus)") || return 1
    fi

    [ -z "$mod" ] && return 1
    
    # Пропускаем заголовки групп в whiptail
    [[ "$mod" =~ ^==.*==$ ]] && continue

    detect_system_info
    setup_dirs
    load_config   # Загружаем текущие OPT_*, чтобы не затереть cron
    acquire_lock
    
    case "$mod" in
      zram)          module_zram ;;
      emmc)          module_emmc ;;
      usbpower)      module_usb_power ;;
      bootrecovery)  module_boot_recovery ;;
      watchdog)      module_watchdog ;;
      notifications) module_notifications ;;
      backups)       module_backups ;;
      remotebackup)  module_remote_backup ;;
      hacs)          module_hacs ;;
      mdns)          module_mdns ;;
      tailscale)     module_tailscale ;;
      cloudflare)    module_cloudflare ;;
      security)      module_security ;;
      monitoring)    module_monitoring ;;
    esac
    
    release_lock

    echo ""
    read -n 1 -s -r -p "Нажмите любую клавишу для возврата в меню модулей..."
    echo ""
  done
}

module_tailscale() {
  header "МОДУЛЬ: TAILSCALE VPN"
  install_tailscale; configure_tailscale_ufw; apply_wifi_powersave_fix
  msg_info "Для авторизации: sudo tailscale up"
}

module_cloudflare() {
  header "МОДУЛЬ: CLOUDFLARE TUNNEL"
  install_cloudflared
  if command -v cloudflared &>/dev/null; then
    local token=""
    if command -v whiptail &>/dev/null; then
      token=$(_whip_input "Cloudflare Token" "Вставьте токен:" "") || token=""
    else
      token=$(text_input "Вставьте Cloudflare Token" "")
    fi
    configure_cloudflare_tunnel "$token"
  fi
}

module_security() {
  header "МОДУЛЬ: БЕЗОПАСНОСТЬ (UFW + SSH)"
  configure_ufw_safe
  if [ -t 0 ]; then
    echo -en "   ${ARROW} Применить жесткую защиту SSH? (д/н): " >&2
    local ans; read -r ans
    ([ "$ans" = "y" ] || [ "$ans" = "Y" ] || [ "$ans" = "д" ] || [ "$ans" = "Д" ]) && apply_ssh_hardening
  fi
}

module_zram() {
  header "МОДУЛЬ: ZRAM SWAP"
  if is_armbian && is_pkg_installed armbian-zram-config; then
    msg_ok "ZRAM уже настроен Armbian"
  else
    setup_zram
  fi
}

module_emmc() {
  header "МОДУЛЬ: ОПТИМИЗАЦИЯ EMMC"
  apply_emmc_tuning
}

module_usb_power() {
  header "МОДУЛЬ: USB ПИТАНИЕ"
  apply_usb_power_fix
}

module_watchdog() {
  header "МОДУЛЬ: WATCHDOG"
  # Watchdog требует ha-notify для отправки алертов
  setup_ha_secrets
  [ ! -f /usr/local/bin/ha-notify ] && setup_script_notify
  setup_script_watchdog
  OPT_WATCHDOG=true
  configure_cron
  msg_ok "Модуль Watchdog активирован"
}

module_backups() {
  header "МОДУЛЬ: БЭКАПЫ"
  setup_script_backups
  OPT_BACKUP=true
  configure_cron
  msg_ok "Модуль Бэкапов активирован"
}

module_remote_backup() {
  header "МОДУЛЬ: УДАЛЕННЫЙ БЭКАП"
  local HAS_WHIPTAIL=false; command -v whiptail &>/dev/null && HAS_WHIPTAIL=true

  # Убедимся, что базовый скрипт бэкапов существует
  if [ ! -x /usr/local/bin/ha-backup ]; then
    msg_warn "Сначала нужно настроить локальные бэкапы. Устанавливаем..."
    module_backups
  fi

  local target=""
  if [ "$HAS_WHIPTAIL" = true ]; then
    target=$(_whip_input "Удалённый бэкап" "SSH: ssh://user@host:/path\nОблако (rclone): rclone://yandex:HA_Backups\n\nВНИМАНИЕ: Для облака потребуется ручная настройка rclone после установки!" "") || return 0
  else
    target=$(text_input "Удал. бэкап (ssh://... или rclone://yandex:path)" "")
  fi

  if [ -z "$target" ]; then
    msg_warn "Цель не указана. Настройка отменена."
    return 0
  fi

  # Устанавливаем глобальные переменные и перегенерируем скрипты
  REMOTE_BACKUP_TARGET="$target"
  OPT_REMOTE_BACKUP=true
  
  # Пересоздаем скрипты бэкапов (функция сама установит rclone, если нужно)
  setup_script_backups

  # Обновляем конфиг и cron, чтобы добавилась задача отправки в облако
  save_config
  configure_cron

  msg_ok "Удаленный бэкап настроен на: ${target}"

  # Даем подсказку по rclone, если выбрано облако
  if [[ "$target" == rclone://* ]]; then
    local rclone_remote="${target#rclone://}"
    rclone_remote="${rclone_remote%%:*}"
    if command -v rclone &>/dev/null && ! rclone listremotes 2>/dev/null | grep -q "^${rclone_remote}:"; then
      echo ""
      msg_warn "Профиль rclone '${rclone_remote}' еще не настроен!"
      msg_info "Выполните команду для настройки: sudo rclone config"
      echo ""
    fi
  fi
}

module_hacs() {
  header "МОДУЛЬ: HACS"
  # HACS требует запущенный контейнер
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^homeassistant$'; then
    msg_error "Контейнер homeassistant не запущен! HACS можно установить только на работающий HA."
    return 1
  fi
  wait_ha_config_init 300 || { msg_error "HA не инициализирован"; return 1; }
  configure_docker_dns
  if install_hacs; then
    msg_ok "HACS установлен!"
    msg_info "Не забудьте добавить интеграцию HACS в интерфейсе HA"
  else
    msg_warn "Автоустановка HACS не удалась"
  fi
}

module_boot_recovery() {
  header "МОДУЛЬ: ВОССТАНОВЛЕНИЕ ЗАГРУЗКИ"
  setup_script_boot_check
  msg_ok "Модуль восстановления загрузки активирован"
}

module_monitoring() {
  header "МОДУЛЬ: МОНИТОРИНГ (PROMETHEUS)"
  apt_safe install -y jq >/dev/null 2>&1 || true # Требуется для метрик
  setup_script_metrics
  OPT_MONITORING=true
  configure_cron
  msg_ok "Модуль мониторинга активирован"
}

module_notifications() {
  header "МОДУЛЬ: УВЕДОМЛЕНИЯ"
  local HAS_WHIPTAIL=false; command -v whiptail &>/dev/null && HAS_WHIPTAIL=true
  
  # Убедимся, что скрипт и папка секретов существуют
  setup_ha_secrets
  [ ! -f /usr/local/bin/ha-notify ] && setup_script_notify

  local notif="none"
  if [ "$HAS_WHIPTAIL" = true ]; then
    notif=$(_whip_menu "Уведомления" \
      "none"     "Отключить уведомления" \
      "telegram" "Telegram бот" \
      "ntfy"     "ntfy.sh (бесплатно, без регистрации)" \
      "discord"  "Discord webhook" \
      "custom"   "Свой URL (Slack, Gotify и др.)") || return 0
  else
    notif=$(text_menu "Уведомления" "Способ:" \
      "none" "Отключить" "telegram" "Telegram" "ntfy" "ntfy.sh" \
      "discord" "Discord" "custom" "URL") || return 0
  fi

  case "$notif" in
    none)
      # Очищаем все секреты
      printf '' > "${HA_INSTALLER_DIR}/secrets/tg_token"
      printf '' > "${HA_INSTALLER_DIR}/secrets/tg_chat"
      printf '' > "${HA_INSTALLER_DIR}/secrets/webhook_url"
      msg_ok "Уведомления отключены"
      ;;
    telegram)
      if [ "$HAS_WHIPTAIL" = true ]; then
        TG_TOKEN=$(_whip_input "Telegram" "Токен бота\n\nПолучите у @BotFather" "") || return 0
        [ -n "$TG_TOKEN" ] && { TG_CHAT=$(_whip_input "Telegram" "Chat ID\n\nУзнайте у @userinfobot" "") || return 0; }
      else
        TG_TOKEN=$(text_input "Токен бота" "")
        [ -n "$TG_TOKEN" ] && TG_CHAT=$(text_input "Chat ID" "")
      fi
      if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
        printf '%s' "$TG_TOKEN" > "${HA_INSTALLER_DIR}/secrets/tg_token"
        printf '%s' "$TG_CHAT" > "${HA_INSTALLER_DIR}/secrets/tg_chat"
        printf '' > "${HA_INSTALLER_DIR}/secrets/webhook_url" # Очищаем вебхук
        msg_ok "Telegram настроен"
      else
        msg_warn "Не указан токен или Chat ID. Настройка отменена."
      fi
      ;;
    ntfy)
      local topic=""
      if [ "$HAS_WHIPTAIL" = true ]; then
        topic=$(_whip_input "ntfy.sh" "Название темы\n\nУстановите ntfy на телефон и подпишитесь на эту тему" "ha-$(hostname 2>/dev/null || echo box)") || return 0
      else
        topic=$(text_input "Тема ntfy.sh" "ha-$(hostname 2>/dev/null || echo box)")
      fi
      if [ -n "$topic" ]; then
        printf '%s' "https://ntfy.sh/${topic}" > "${HA_INSTALLER_DIR}/secrets/webhook_url"
        printf '' > "${HA_INSTALLER_DIR}/secrets/tg_token"
        printf '' > "${HA_INSTALLER_DIR}/secrets/tg_chat" # Очищаем Telegram
        msg_ok "ntfy.sh настроен"
      fi
      ;;
    discord|custom)
      local url=""
      if [ "$HAS_WHIPTAIL" = true ]; then
        url=$(_whip_input "Webhook" "URL для отправки уведомлений" "") || return 0
      else
        url=$(text_input "Webhook URL" "")
      fi
      if [ -n "$url" ]; then
        printf '%s' "$url" > "${HA_INSTALLER_DIR}/secrets/webhook_url"
        printf '' > "${HA_INSTALLER_DIR}/secrets/tg_token"
        printf '' > "${HA_INSTALLER_DIR}/secrets/tg_chat" # Очищаем Telegram
        msg_ok "Webhook настроен"
      fi
      ;;
  esac

  # Отправка тестового уведомления (если не отключили)
  if [ "$notif" != "none" ]; then
    msg_action "Отправка тестового уведомления..."
    /usr/local/bin/ha-notify "Тест уведомлений Hassify"
    msg_ok "Проверьте устройство/чат"
  fi
}

module_mdns() {
  header "МОДУЛЬ: MDNS (AVAHI)"
  if ! is_pkg_installed avahi-daemon; then
    apt_safe install -y avahi-daemon >/dev/null 2>&1 || { msg_error "Не удалось установить avahi-daemon"; return 1; }
  fi
  systemctl enable avahi-daemon >/dev/null 2>&1 || true
  systemctl start avahi-daemon >/dev/null 2>&1 || true
  msg_ok "mDNS (Avahi) настроен. HA доступен по адресу http://homeassistant.local:8123"
}

# ============================================================================
# MAIN MENU
# ============================================================================
show_main_menu() {
  [ ! -t 0 ] && return 1
  [ ! -t 1 ] && return 1

  local choice
  if command -v whiptail &>/dev/null; then
    choice=$(whiptail --title "Hassify v${SCRIPT_VERSION}" --menu "Действие:" 24 60 15 \
      "install"   "Установить HA Supervised" \
      "modules"   "Установить модули (VPN, UFW, Cloudflare)" \
      "check"     "Диагностика" \
      "status"    "Мониторинг (live)" \
      "update"    "Обновить OS-Agent" \
      "backup"    "Создать бэкап" \
      "restore"   "Восстановить бэкап" \
      "health"    "Отчёт о здоровье" \
      "rescue"    "Восстановление (авто-починка)" \
      "benchmark" "Тест железа" \
      "export"    "Экспорт конфига" \
      "history"   "История запусков" \
      "uninstall" "Удалить HA" \
      "selftest"  "Самотест" \
      "help"      "Помощь" \
      3>&1 1>&2 2>&3) || return 1
  else
    choice=$(text_menu "Hassify v${SCRIPT_VERSION}" "Действие:" \
      "install"   "Установить HA" \
      "modules"   "Установить модули (VPN, UFW, Cloudflare)" \
      "check"     "Диагностика" \
      "status"    "Мониторинг" \
      "update"    "Обновить OS-Agent" \
      "backup"    "Создать бэкап" \
      "restore"   "Восстановить бэкап" \
      "health"    "Отчёт о здоровье" \
      "rescue"    "Восстановление" \
      "benchmark" "Тест железа" \
      "export"    "Экспорт конфига" \
      "history"   "История" \
      "uninstall" "Удалить" \
      "selftest"  "Самотест" \
      "help"      "Помощь") || return 1
  fi

  [ -z "$choice" ] && return 1

  case "$choice" in
    install)   RUN_WIZARD=true;;
    modules)   show_modules_menu; IMMEDIATE_ACTION=true; RUN_WIZARD=false;;
    check)     CHECK_ONLY=true; RUN_WIZARD=false;;
    status)    SHOW_STATUS=true; RUN_WIZARD=false;;
    update)    DO_UPDATE=true; RUN_WIZARD=false;;
    backup)
      if [ -x /usr/local/bin/ha-backup ]; then
        /usr/local/bin/ha-backup
      else
        msg_error "Утилита ha-backup не найдена"
        msg_dim "Сначала установите Home Assistant, выбрав пункт 'Установить HA Supervised'"
      fi
      echo ""
      read -n 1 -s -r -p "Нажмите любую клавишу для возврата в меню..."
      echo ""
      IMMEDIATE_ACTION=true
      RUN_WIZARD=false
      ;;
    restore)
      if [ -x /usr/local/bin/ha-restore ]; then
        /usr/local/bin/ha-restore
      else
        msg_error "Утилита ha-restore не найдена"
        msg_dim "Сначала установите Home Assistant"
      fi
      echo ""
      read -n 1 -s -r -p "Нажмите любую клавишу для возврата в меню..."
      echo ""
      IMMEDIATE_ACTION=true
      RUN_WIZARD=false
      ;;
    health)
      if [ -x /usr/local/bin/ha-health ]; then
        /usr/local/bin/ha-health
      else
        msg_error "Утилита ha-health не найдена"
        msg_dim "Сначала установите Home Assistant"
      fi
      echo ""
      read -n 1 -s -r -p "Нажмите любую клавишу для возврата в меню..."
      echo ""
      IMMEDIATE_ACTION=true
      RUN_WIZARD=false
      ;;
    rescue)     DO_RESCUE=true; RUN_WIZARD=false;;
    benchmark) DO_BENCHMARK=true; RUN_WIZARD=false;;
    export)    DO_EXPORT_CONFIG=true; RUN_WIZARD=false;;
    history)   DO_SHOW_HISTORY=true; RUN_WIZARD=false;;
    uninstall) UNINSTALL=true; RUN_WIZARD=false;;
    selftest)  DO_SELF_TEST=true; RUN_WIZARD=false;;
    help)      show_help; exit 0;;
  esac
}

# ============================================================================
# ATOMIC ACTIONS
# ============================================================================

# --- SYSTEM & PERFORMANCE ---
setup_timezone() {
  local tz="${1:-}"
  [ -z "$tz" ] && return 0
  msg_action "Часовой пояс: ${tz}..."
  if [ -f "/usr/share/zoneinfo/${tz}" ]; then
    timedatectl set-timezone "$tz" 2>/dev/null || \
      ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime
    msg_ok "Часовой пояс: ${tz}"
  else
    msg_warn "Неизвестный часовой пояс: ${tz}"
  fi
}

setup_locale() {
  local loc="${1:-}"
  [ -z "$loc" ] && return 0
  msg_action "Локаль: ${loc}..."
  if command -v locale-gen &>/dev/null; then
    sed -i "s/^# *${loc}/${loc}/" /etc/locale.gen 2>/dev/null
    locale-gen 2>/dev/null || true
    update-locale LANG="${loc}" 2>/dev/null || true
    msg_ok "Локаль: ${loc}"
  else
    msg_warn "locale-gen недоступен"
  fi
}

setup_swap() {
  local size="${1:-}"
  [ -z "$size" ] && return 0
  case "$size" in
    none|0) swapoff -a 2>/dev/null; sed -i '/swap/d' /etc/fstab 2>/dev/null; msg_ok "Swap отключен" ;;
    zram)    setup_zram ;;
    *)
      if [[ "$size" =~ ^[0-9]+$ ]]; then
        swapoff /swapfile 2>/dev/null; rm -f /swapfile 2>/dev/null
        dd if=/dev/zero of=/swapfile bs=1M count="$size" status=none 2>/dev/null
        chmod 600 /swapfile; mkswap /swapfile >/dev/null 2>&1; swapon /swapfile 2>/dev/null
        grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        msg_ok "Swap: ${size}МБ"
      else msg_warn "Неверный размер swap: ${size}"; fi ;;
  esac
}

setup_zram() {
  if is_armbian && is_pkg_installed armbian-zram-config; then msg_ok "ZRAM: Armbian"; return 0; fi
  if is_pkg_installed zram-tools; then
    printf 'ALGO=lz4\nPERCENT=60\n' > /etc/default/zramswap
    systemctl enable zramswap 2>/dev/null; systemctl restart zramswap 2>/dev/null
    msg_ok "ZRAM настроен"
  elif is_pkg_installed systemd-zram-generator; then
    mkdir -p /etc/systemd/zram-generator.conf.d
    printf '[zram0]\nzram-size = ram * 0.6\ncompression-algorithm = lz4\n' > /etc/systemd/zram-generator.conf.d/ha.conf
    systemctl daemon-reload 2>/dev/null
    msg_ok "ZRAM настроен (generator)"
  else msg_warn "ZRAM недоступен"; fi
}

apply_emmc_tuning() {
  echo "vm.swappiness=10" > /etc/sysctl.d/99-ha-swap.conf
  sysctl -p /etc/sysctl.d/99-ha-swap.conf >/dev/null 2>&1
  grep -q noatime /etc/fstab 2>/dev/null || { cp /etc/fstab "${BACKUP_DIR}/fstab.bak" 2>/dev/null; sed -i '/^\//s/defaults/defaults,noatime,commit=600/' /etc/fstab 2>/dev/null; }
  mkdir -p /etc/systemd/journald.conf.d
  printf '[Journal]\nSystemMaxUse=50M\nSystemMaxFileSize=10M\nMaxRetentionSec=7day\nCompress=yes\nStorage=persistent\nSystemKeepFree=100M\n' > /etc/systemd/journald.conf.d/ha-tuning.conf
  systemctl restart systemd-journald 2>/dev/null
  msg_ok "Оптимизация eMMC"
}

apply_usb_power_fix() {
  for d in /sys/bus/usb/devices/*/power/autosuspend; do [ -f "$d" ] && echo -1 > "$d" 2>/dev/null; done
  echo 'ACTION=="add", SUBSYSTEM=="usb", ATTR{power/autosuspend}="-1"' > /etc/udev/rules.d/99-ha-usb-power.rules
  udevadm control --reload-rules 2>/dev/null
  msg_ok "USB питание"
}

# --- DOCKER ---
install_docker() {
  if command -v docker &>/dev/null; then msg_ok "Docker уже установлен"; return 0; fi
  msg_action "Установка Docker..."
  apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
  local codename="${CACHED_CODENAME:-bookworm}"
  [[ "$codename" == "sid" ]] && codename="trixie"
  [ -z "$codename" ] && codename="bookworm"

  local docker_ok=false
  if command -v curl &>/dev/null; then
    install -m 0755 -d /etc/apt/keyrings 2>/dev/null
    if curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc 2>/dev/null; then
      chmod a+r /etc/apt/keyrings/docker.asc
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${codename} stable" > /etc/apt/sources.list.d/docker.list
      apt-get update -qq 2>/dev/null
      apt_safe install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin &>/dev/null && docker_ok=true
    fi
  fi
  if [ "$docker_ok" = false ]; then
    msg_warn "Официальный репо не сработал -> get.docker.com"
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || { msg_error "Docker не установился!"; return 1; }
  fi
  hash -r 2>/dev/null; msg_ok "Docker установлен"
}

configure_docker_mirror() {
  local mirror_url="${1:-}"
  [ -z "$mirror_url" ] && return 0
  
  mkdir -p /etc/docker
  if command -v jq &>/dev/null; then
    [ ! -f /etc/docker/daemon.json ] && echo '{}' > /etc/docker/daemon.json
    if jq --arg m "$mirror_url" '. + {"registry-mirrors": [$m]}' /etc/docker/daemon.json > /tmp/dj.tmp 2>/dev/null; then
      mv /tmp/dj.tmp /etc/docker/daemon.json
      msg_ok "Зеркало Docker: ${mirror_url}"
    else
      msg_error "Ошибка обновления daemon.json через jq"
    fi
  else
    msg_warn "jq не установлен. Запись зеркала в daemon.json в базовом режиме."
    echo "{\"log-driver\":\"journald\",\"storage-driver\":\"overlay2\",\"registry-mirrors\":[\"${mirror_url}\"]}" \
      > /etc/docker/daemon.json
    msg_ok "Зеркало Docker: ${mirror_url} (базовый режим)"
  fi
}

setup_data_dir() {
  local t="${1:-}"; [ -z "$t" ] && return 0

  if [ ! -d "$t" ]; then msg_error "Каталог не найден: ${t}"; return 1; fi
  if ! touch "${t}/.ha_test" 2>/dev/null; then msg_error "Нет доступа на запись: ${t}"; return 1; fi
  rm -f "${t}/.ha_test"

  # Восстановленная проверка файловой системы
  local fstype
  fstype=$(df -T "$t" 2>/dev/null | awk 'NR==2{print $2}')
  case "$fstype" in
    ext4|btrfs|xfs|ext3) msg_ok "ФС данных: ${fstype}" ;;
    vfat|ntfs|exfat|fat32) msg_error "Неподдерживаемая ФС: ${fstype} (нужна ext4/btrfs/xfs)"; return 1 ;;
    *) msg_warn "ФС данных: ${fstype} (может работать)" ;;
  esac

  # Восстановленная проверка свободного места
  local free_mb
  free_mb=$(df -m "$t" | awk 'NR==2{print $4}')
  [ "$free_mb" -lt 10000 ] && msg_warn "Только ${free_mb}МБ свободно на ${t} (рекомендуется 10ГБ+)"

  msg_action "Настройка внешнего хранилища: ${t}..."

  if [ -d /var/lib/docker ] && [ ! -L /var/lib/docker ]; then
    systemctl stop docker 2>/dev/null || true
    mkdir -p "${t}/docker"
    if [ ! -d "${t}/docker/overlay2" ]; then
      rsync -aHAX /var/lib/docker/ "${t}/docker/" 2>/dev/null || \
        cp -a /var/lib/docker/* "${t}/docker/" 2>/dev/null
    fi
    mv /var/lib/docker /var/lib/docker.bak 2>/dev/null || true
    ln -sf "${t}/docker" /var/lib/docker
    systemctl start docker 2>/dev/null || true
    msg_ok "Docker -> ${t}/docker"
  fi

  mkdir -p "${t}/hassio"
  if [ -d "$HASSIO_DIR" ] && [ ! -L "$HASSIO_DIR" ]; then
    rsync -aHAX "${HASSIO_DIR}/" "${t}/hassio/" 2>/dev/null || \
      cp -a "${HASSIO_DIR}"/* "${t}/hassio/" 2>/dev/null
    mv "$HASSIO_DIR" "${HASSIO_DIR}.bak" 2>/dev/null || true
    ln -sf "${t}/hassio" "$HASSIO_DIR"
    msg_ok "HA -> ${t}/hassio"
  elif [ ! -d "$HASSIO_DIR" ]; then
    ln -sf "${t}/hassio" "$HASSIO_DIR"
    msg_ok "HA привязан: ${t}/hassio"
  fi
}

wait_for_docker() {
  local dw=0
  while ! docker info &>/dev/null; do
    sleep 2; dw=$((dw+2)); [ $dw -ge 30 ] && { msg_error "Docker не запустился!"; return 1; }
  done
}

# --- NETWORK ---
apply_wifi_powersave_fix() {
  local wifi_dev
  wifi_dev=$(nmcli -t -f DEVICE,TYPE dev status 2>/dev/null | grep ':wifi$' | head -1 | cut -d: -f1)
  if [ -n "$wifi_dev" ]; then
    local wifi_uuid
    wifi_uuid=$(nmcli -g GENERAL.CON-UUID dev show "$wifi_dev" 2>/dev/null)
    if [ -n "$wifi_uuid" ]; then
      nmcli con modify "$wifi_uuid" 802-11-wireless.powersave 2 2>/dev/null || true
      msg_ok "Wi-Fi Power Save отключен"
    fi
  fi
}

# --- TAILSCALE ---
install_tailscale() {
  if ! command -v tailscale &>/dev/null; then
    msg_action "Установка Tailscale..."; curl -fsSL https://tailscale.com/install.sh | sh; msg_ok "Tailscale установлен"
  else msg_ok "Tailscale уже установлен"; fi
}

configure_tailscale_ufw() {
  if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "status: active"; then
    ufw status | grep -qw '41641/udp' || ufw allow 41641/udp comment "Tailscale WireGuard" >/dev/null 2>&1
    ufw status | grep -qw 'tailscale0' || ufw allow in on tailscale0 comment "Tailscale VPN" >/dev/null 2>&1
    msg_ok "Правила UFW для Tailscale добавлены"
  fi
}

auth_tailscale() {
  local ts_key="${1:-}"
  if [ -n "$ts_key" ]; then
    msg_dim "Авторизация через Auth Key..."
    tailscale up --authkey="$ts_key" --accept-routes >/dev/null 2>&1 && msg_ok "Tailscale авторизован" || msg_warn "Ошибка авторизации"
  else msg_info "Для авторизации: sudo tailscale up"; fi
}

# --- CLOUDFLARE ---
install_cloudflared() {
  if ! command -v cloudflared &>/dev/null; then
    local cf_arch=""
    case "$CACHED_MACHINE_ARCH" in x86_64) cf_arch="amd64";; aarch64) cf_arch="arm64";; armv7l) cf_arch="arm";; *) msg_warn "Архитектура не поддерживается"; return 1;; esac
    msg_action "Загрузка cloudflared..."
    curl -L --fail --progress-bar "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}" -o /usr/local/bin/cloudflared 2>/dev/null && chmod +x /usr/local/bin/cloudflared && msg_ok "Cloudflared установлен" || msg_error "Не удалось загрузить"
  else msg_ok "Cloudflared уже установлен"; fi
}

configure_cloudflare_tunnel() {
  local cf_token="${1:-}"
  if [ -n "$cf_token" ]; then
    msg_dim "Регистрация туннеля..."; cloudflared service uninstall >/dev/null 2>&1 || true
    if cloudflared service install "$cf_token" >/dev/null 2>&1; then
      systemctl enable cloudflared >/dev/null 2>&1; systemctl start cloudflared >/dev/null 2>&1; msg_ok "Cloudflare Tunnel запущен"
    else msg_error "Ошибка установки (неверный токен?)"; fi
  else msg_warn "Токен не предоставлен. Настройка: sudo cloudflared service install <ТОКЕН>"; fi
}

# --- SECURITY ---
configure_ufw_safe() {
  if ! command -v ufw &>/dev/null; then apt_safe install -y ufw >/dev/null; fi
  if ! ufw status 2>/dev/null | grep -q "status: active"; then
    ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null; ufw --force enable >/dev/null
  fi
  ufw status | grep -qw '22/tcp' || ufw allow 22/tcp comment SSH >/dev/null
  ufw status | grep -qw '8123/tcp' || ufw allow 8123/tcp comment HA >/dev/null
  msg_ok "UFW настроен (22, 8123 открыты)"
}

apply_ssh_hardening() {
  mkdir -p /etc/ssh/sshd_config.d
  cp /etc/ssh/sshd_config "${BACKUP_DIR}/sshd_config.bak" 2>/dev/null
  printf 'PermitRootLogin prohibit-password\nMaxAuthTries 3\nClientAliveInterval 300\nClientAliveCountMax 2\nX11Forwarding no\n' > /etc/ssh/sshd_config.d/99-ha-hardening.conf
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  msg_ok "SSH защищен"
}

# ============================================================================
# ШАГ: ПРЕДВАРИТЕЛЬНАЯ ПРОВЕРКА
# ============================================================================
step_preflight() {
  local sid="preflight"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] ПРЕДВАРИТЕЛЬНАЯ ПРОВЕРКА"
  detect_system_info; local err=0 wrn=0

  if [ "$CACHED_MACHINE_ARCH" = "armv7l" ] || [ "$CACHED_ARCH" = "armv7" ]; then
    msg_error "Архитектура: ${CACHED_MACHINE_ARCH}. Home Assistant Supervised больше не поддерживает 32-битные системы (требуется aarch64)."
    err=$((err+1))
  elif [ "$CACHED_ARCH" = "unknown" ]; then
    msg_error "Архитектура: ${CACHED_MACHINE_ARCH}"; err=$((err+1))
  else
    msg_ok "Архитектура: ${CACHED_MACHINE_ARCH} (${CACHED_ARCH})"
  fi
  msg_info "ОС: ${CACHED_PRETTY_NAME:-${CACHED_CODENAME:-?}}"
  is_armbian && msg_info "Обнаружен Armbian"
  is_trixie && msg_info "Debian 13 Trixie"
  os_release_needs_faking && msg_warn "os-release будет подменён" || msg_ok "os-release OK"

  check_filesystem || err=$((err+1))
  check_broken_state

  is_armbian && is_pkg_installed armbian-zram-config && [ "$OPT_ZRAM" = true ] && \
    { msg_warn "Конфликт с armbian-zram-config"; wrn=$((wrn+1)); }

  require_disk_space 4000 "Установка" || err=$((err+1))

  local rm_val; rm_val=$(free -m | awk '/Mem:/{print $2}')
  [ "$rm_val" -lt 900 ] && { msg_error "RAM: ${rm_val}МБ (нужно 1ГБ+)"; err=$((err+1)); } || msg_ok "RAM: ${rm_val}МБ"

  local kv; kv=$(uname -r | cut -d. -f1)
  [ "$kv" -lt 4 ] && { msg_error "Ядро $(uname -r)"; err=$((err+1)); } || msg_ok "Ядро: $(uname -r)"

  if [ -f /sys/fs/cgroup/cgroup.controllers ]; then msg_ok "cgroups: v2"
  elif [ -d /sys/fs/cgroup/unified ]; then msg_ok "cgroups: гибрид"
  else msg_warn "cgroups: v1"; wrn=$((wrn+1)); fi

  # Проверка AppArmor (строгое требование HA Supervisor)
  local aa_kernel
  aa_kernel=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) || aa_kernel="N"
  if [ "$aa_kernel" = "Y" ]; then
    # Ядро поддерживает AppArmor. Проверяем, загружены ли политики (если есть утилита)
    if command -v aa-enabled >/dev/null 2>&1; then
      if aa-enabled --quiet 2>/dev/null; then
        msg_ok "AppArmor: активен (ядро + политики)"
      else
        msg_warn "AppArmor: включен в ядре, но политики не загружены"
        wrn=$((wrn+1))
      fi
    else
      # Утилиты ещё нет, но ядро готово - это ОК для этапа preflight
      msg_ok "AppArmor: поддерживается ядром"
    fi
  else
    msg_warn "AppArmor: отключен в ядре (потребуется патч загрузчика и перезагрузка)"
    wrn=$((wrn+1))
  fi

  check_internet || err=$((err+1))

  ss -tlnp 2>/dev/null | grep -q ':8123 ' && { msg_warn "Порт 8123 занят"; wrn=$((wrn+1)); } || msg_ok "Порт 8123 свободен"

  local t; t=$(get_cpu_temp)
  [ -n "$t" ] && { [ "$t" -ge 75 ] && { msg_warn "CPU: ${t}C!"; wrn=$((wrn+1)); } || msg_ok "CPU: ${t}C"; }

  # Проверка внешнего диска
  if [ -n "$OPT_DATA_DIR" ]; then
    if [ ! -d "$OPT_DATA_DIR" ]; then
      msg_error "Каталог данных не найден: ${OPT_DATA_DIR}"; err=$((err+1))
    else
      local fstype; fstype=$(df -T "$OPT_DATA_DIR" 2>/dev/null | awk 'NR==2{print $2}')
      case "$fstype" in
        vfat|ntfs|exfat|fat32) msg_error "Неподдерживаемая ФС: ${fstype}"; err=$((err+1)) ;;
        ext4|btrfs|xfs) msg_ok "ФС данных: ${fstype}" ;;
        *) msg_warn "ФС данных: ${fstype}" ;;
      esac
      local dfree; dfree=$(df -m "$OPT_DATA_DIR" | awk 'NR==2{print $4}')
      [ "$dfree" -lt 10000 ] && { msg_warn "Данные: только ${dfree}МБ свободно"; wrn=$((wrn+1)); }
    fi
  fi

  # Проверка Docker
  if command -v docker &>/dev/null; then
    local dver; dver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "")
    if [ -n "$dver" ]; then
      local dmaj; dmaj=$(echo "$dver" | cut -d. -f1)
      [ "$dmaj" -lt 20 ] && { msg_warn "Docker ${dver} устарел (нужен 20+)"; wrn=$((wrn+1)); } || msg_ok "Docker: ${dver}"
    fi
  fi

  # Тест уведомлений
  if [ -n "$TG_TOKEN" ] || [ -n "$OPT_WEBHOOK_URL" ]; then
    test_notifications || wrn=$((wrn+1))
  fi

  # Проверка файла бэкапа
  [ -n "$OPT_RESTORE_BACKUP" ] && [ ! -f "$OPT_RESTORE_BACKUP" ] && \
    { msg_error "Бэкап не найден: ${OPT_RESTORE_BACKUP}"; err=$((err+1)); }

  estimate_install_time
  separator
  [ $err -gt 0 ] && { msg_error "Критических ошибок: ${err}"; return 1; }
  [ $wrn -gt 0 ] && msg_warn "Предупреждений: ${wrn}" || msg_ok "Все проверки пройдены"
  mark_done "$sid"
}

# ============================================================================
# ШАГ: ОБНОВЛЕНИЕ СИСТЕМЫ
# ============================================================================
step_update_system() {
  local sid="update"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] ОБНОВЛЕНИЕ СИСТЕМЫ"
  setup_timezone "$OPT_TIMEZONE"
  setup_locale "$OPT_LOCALE"
  if [ "$SKIP_UPDATE" = false ]; then
    run_cmd_fatal "apt update" apt_safe update -y
    run_cmd "apt upgrade" apt_safe upgrade -y
  fi
  mark_done "$sid"
}

# ============================================================================
# ШАГ: ЗАВИСИМОСТИ
# ============================================================================
step_install_deps() {
  local sid="deps"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] ЗАВИСИМОСТИ"
  detect_system_info

    local pkgs=(apparmor avahi-daemon bluez ca-certificates cifs-utils curl dbus gnupg jq
    libglib2.0-bin lsb-release network-manager nfs-common systemd-journal-remote
    systemd-resolved systemd-timesyncd udisks2 usbutils wget whiptail qrencode)

  if [ "$OPT_ZRAM" = true ]; then
    if is_armbian && is_pkg_installed armbian-zram-config; then true
    elif pkg_available zram-tools; then pkgs+=(zram-tools)
    elif pkg_available systemd-zram-generator; then pkgs+=(systemd-zram-generator)
    fi
  fi

  [ "$OPT_UFW" = true ]           && pkgs+=(ufw fail2ban)
  [ "$OPT_AUTOUPDATE" = true ]    && pkgs+=(unattended-upgrades)
  [ "$OPT_BACKUP" = true ]        && pkg_available pigz && pkgs+=(pigz)
  [ "$OPT_REMOTE_BACKUP" = true ] && pkg_available rsync && pkgs+=(rsync)
  [ "$OPT_REMOTE_BACKUP" = true ] && pkg_available rclone && pkgs+=(rclone)

  is_armbian && systemctl is-active --quiet armbian-hardware-optimization 2>/dev/null || {
    for p in linux-cpupower cpufrequtils; do pkg_available "$p" && pkgs+=("$p"); done
  }

  local ti=()
  for p in "${pkgs[@]}"; do is_pkg_installed "$p" || ti+=("$p"); done

    # Бэкап DNS ДО установки пакетов (systemd-resolved может сломать)
  if [ ! -f "${BACKUP_DIR}/resolv.conf.bak" ]; then
    mkdir -p "$BACKUP_DIR"
    if [ -L /etc/resolv.conf ]; then
      # Симлинк — сохранить содержимое реального файла
      cat /etc/resolv.conf > "${BACKUP_DIR}/resolv.conf.bak" 2>/dev/null
    else
      cp /etc/resolv.conf "${BACKUP_DIR}/resolv.conf.bak" 2>/dev/null
    fi
    # Если бэкап пустой или без nameserver — создать рабочий
    if ! grep -q "nameserver" "${BACKUP_DIR}/resolv.conf.bak" 2>/dev/null || \
         grep -q "No DNS" "${BACKUP_DIR}/resolv.conf.bak" 2>/dev/null; then
      echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > "${BACKUP_DIR}/resolv.conf.bak"
    fi
  fi

      if [ ${#ti[@]} -eq 0 ]; then
    msg_ok "Все пакеты установлены"
  else
    # Ждём lock один раз
    local lock_wait=0
    while fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1 && [ $lock_wait -lt 60 ]; do
      [ $lock_wait -eq 0 ] && msg_dim "Ожидание dpkg lock..."
      sleep 3; lock_wait=$((lock_wait + 3))
    done

    local total=${#ti[@]}
    local f=()
    msg_action "Установка ${total} пакетов..."

    # Попытка 1: все разом
    if DEBIAN_FRONTEND=noninteractive apt-get install -y \
        -o Dpkg::Options::="--force-confold" \
        -o APT::Get::Assume-Yes="true" \
        "${ti[@]}" </dev/null >/dev/null 2>&1; then
      msg_ok "Установлено: ${total}"
    else
      # Попытка 2: поштучно
      msg_warn "Пакетная установка не удалась, поштучно..."
      local i=0
      local width=25
      local pct=0
      local filled=0
      local empty=0
      local bar=""
      local j=0
      for p in "${ti[@]}"; do
        i=$((i+1))

        # Прогресс
        pct=$((i * 100 / total))
        filled=$((i * width / total))
        empty=$((width - filled))
        bar=""
        for ((j=0; j<filled; j++)); do bar="${bar}#"; done
        for ((j=0; j<empty; j++)); do bar="${bar}."; done
        printf "\r   [%s] %3d%% [%d/%d] %-20s" "$bar" "$pct" "$i" "$total" "$p" > /dev/tty 2>/dev/null || echo "   [${i}/${total}] ${p}"

        # Установка
        if DEBIAN_FRONTEND=noninteractive apt-get install -y \
            -o Dpkg::Options::="--force-confold" \
            -o APT::Get::Assume-Yes="true" \
            "$p" </dev/null >/dev/null 2>&1; then
          true
        else
          f+=("$p")
        fi
      done

      # Очистка строки
      printf "\r%80s\r" "" > /dev/tty 2>/dev/null || true
      if [ ${#f[@]} -gt 0 ]; then
        msg_ok "Установлено: $((total - ${#f[@]})) из ${total}"
        msg_warn "Не удалось: ${f[*]}"
      else
        msg_ok "Установлено: ${total}"
      fi
    fi
  fi

  run_cmd "apt fix" apt_safe -f install -y
  [ "$OPT_EMMC_TUNING" = true ] && apt-get clean 2>/dev/null || true
  setup_swap "$OPT_SWAP_SIZE"
  mark_done "$sid"
}

# ============================================================================
# SETUP: Настройка конфигурации сети
# ============================================================================

# Подготовка конфигов для NetworkManager и systemd-resolved
setup_network_configs() {
  mkdir -p "$BACKUP_DIR" /etc/NetworkManager/conf.d

  # 1. Конфиги NetworkManager
  printf '[keyfile]\nunmanaged-devices=none\n[device]\nwifi.scan-rand-mac-address=no\n' \
    > /etc/NetworkManager/conf.d/10-ha-managed.conf
  printf '[main]\ndns=systemd-resolved\n' \
    > /etc/NetworkManager/conf.d/10-dns-resolved.conf

  # 2. Бэкап и очистка /etc/network/interfaces (чтобы не конфликтовал с NM)
  [ -f /etc/network/interfaces ] && cp /etc/network/interfaces "$BACKUP_DIR/interfaces.bak" 2>/dev/null
  printf 'source /etc/network/interfaces.d/*\nauto lo\niface lo inet loopback\n' > /etc/network/interfaces

  # 3. Настройка systemd-resolved
  systemctl is-active --quiet systemd-resolved 2>/dev/null || {
    systemctl enable systemd-resolved 2>/dev/null || true
    systemctl start systemd-resolved 2>/dev/null || true
  }

  # 4. Перенаправление resolv.conf на systemd-resolved
  local rt; rt=$(readlink -f /etc/resolv.conf 2>/dev/null)
  [[ "$rt" != */run/systemd/resolve/* ]] && {
    cp /etc/resolv.conf "${BACKUP_DIR}/resolv.conf.bak" 2>/dev/null
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null
  }

  # 5. Отключение ifupdown (networking.service)
  systemctl list-unit-files networking.service &>/dev/null && \
    systemctl is-active --quiet networking 2>/dev/null && \
    systemctl disable networking 2>/dev/null || true
}

# ============================================================================
# INSTALL: Установка пакетов
# ============================================================================

# Установка NetworkManager (с защитой от раннего запуска)
install_network_manager() {
  if ! is_pkg_installed network-manager; then
    msg_action "Установка network-manager..."
    
    # Временная блокировка автозапуска служб после apt
    local policy_created=false
    if [ ! -f /usr/sbin/policy-rc.d ]; then
      cat > /usr/sbin/policy-rc.d << 'RCEOF'
#!/bin/sh
exit 101
RCEOF
      chmod +x /usr/sbin/policy-rc.d
      policy_created=true
    fi

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      -o Dpkg::Options::="--force-confold" \
      network-manager </dev/null >/dev/null 2>&1 || { msg_error "network-manager не установился"; return 1; }

    # Снятие блокировки автозапуска
    if [ "$policy_created" = true ]; then
      rm -f /usr/sbin/policy-rc.d
    fi

    # Остановить NM если он всё-таки умудрился запуститься до нашей настройки
    systemctl stop NetworkManager 2>/dev/null || true
    msg_ok "network-manager установлен"
  fi
}

# ============================================================================
# CONFIGURE: Изменение параметров работающей сети
# ============================================================================

# Применение статического IP через nmcli
configure_static_ip() {
  if [ "$OPT_STATIC_IP" = true ] && [ -n "$STATIC_IP" ]; then
    local active_iface
    active_iface=$(ip route list default 2>/dev/null | awk '{print $5}' | head -1)
    local target_uuid=""
    
    if [ -n "$active_iface" ]; then
      target_uuid=$(nmcli -g GENERAL.CON-UUID dev show "$active_iface" 2>/dev/null)
    fi

    if [ -n "$target_uuid" ]; then
      local pf; pf=$(get_current_prefix); [ -z "$pf" ] && pf="24"
      nmcli con mod "$target_uuid" ipv4.addresses "${STATIC_IP}/${pf}" \
        ipv4.gateway "$STATIC_GW" ipv4.dns "$STATIC_DNS" ipv4.method manual 2>/dev/null
      nmcli con up "$target_uuid" 2>/dev/null
      
      local target_con_name
      target_con_name=$(nmcli -g NAME con show "$target_uuid" 2>/dev/null)
      msg_ok "Стат. IP: ${STATIC_IP}/${pf} (${target_con_name:-$target_uuid})"
    else
      msg_warn "Не удалось применить статический IP: активное подключение не найдено"
    fi
  fi
}

# ============================================================================
# WAIT: Ожидание готовности сервисов
# ============================================================================

# Ожидание появления IP-адреса после переключения на NM
wait_network_online() {
  local to="${1:-30}" el=0 ni=""
  while [ $el -lt $to ]; do
    sleep 5; el=$((el+5))
    ni=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -n "$ni" ]; then
      msg_ok "Сеть: ${ni}"
      return 0
    fi
  done
  
  # Если вышли по таймауту
  msg_error "Сеть не появилась после переключения на NetworkManager"
  return 1
}

# ============================================================================
# ШАГ: СЕТЬ
# ============================================================================
step_configure_network() {
  local sid="network"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] НАСТРОЙКА СЕТИ"

  push_rollback 'rollback_network'

  local cip; cip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -n "$cip" ] && msg_info "Текущий IP: ${cip}"

  # 1. Подготовка конфигов и отключение ifupdown
  setup_network_configs

  # 2. Защита SSH-сессии (пауза перед переключением)
  if who 2>/dev/null | grep -q pts; then
    msg_warn "SSH-сессия! Переключение сети..."
    if [ "$SILENT" = true ] || [ "$DRY_RUN" = true ]; then
      msg_dim "Silent/dry-run режим: пауза пропущена"
    elif [ -n "$FROM_STEP" ]; then
      msg_dim "Продолжение после reboot: пауза пропущена"
    else
      msg_dim "Пауза 15с для завершения активных SSH операций..."
      sleep 15
    fi
  fi

  # 3. Установка NetworkManager если отсутствует
  install_network_manager || return 1

  # 4. Запуск NetworkManager
  systemctl enable NetworkManager 2>/dev/null || true
  systemctl restart NetworkManager 2>/dev/null || true
  sleep 2

  # 5. Настройка WiFi (вызов существующей функции)
  setup_wifi

  # 6. Настройка статического IP
  configure_static_ip

  # 7. Ожидание появления IP
  if ! wait_network_online 30; then
    # Если сеть не появилась - пробуем откат
    if rollback_network; then
      msg_ok "Откат выполнен успешно"
    else
      msg_error "Откат не помог!"
      msg_dim "Подключитесь через UART/HDMI и выполните:"
      msg_dim "  sudo systemctl stop NetworkManager"
      msg_dim "  sudo systemctl restart networking"
      return 1
    fi
  fi

  # 8. Фикс энергосбережения WiFi
  apply_wifi_powersave_fix

  mark_done "$sid"
}

# ============================================================================
# BOOT DIR DETECTION
# ============================================================================
detect_boot_dir() {
  # Если каталог уже задан — пропускаем
  [ -n "$BOOT_DIR" ] && return 0

  # Если задано блочное устройство (из CLI или Wizard) — монтируем его
  if [ -n "$BOOT_DEV_FSTAB" ] && [ -z "$BOOT_DIR" ]; then
    BOOT_DIR="/mnt/ha_boot_tmp"
    mkdir -p "$BOOT_DIR"
    msg_action "Монтирование указанного загрузчика ${BOOT_DEV_FSTAB}..."
    if mount "$BOOT_DEV_FSTAB" "$BOOT_DIR" 2>/dev/null; then
      if [ -f "$BOOT_DIR/armbianEnv.txt" ] || [ -f "$BOOT_DIR/uEnv.txt" ] || [ -f "$BOOT_DIR/extlinux/extlinux.conf" ]; then
        msg_ok "Загрузчик найден и примонтирован"
        return 0
      else
        msg_warn "Файлы загрузчика не найдены в ${BOOT_DEV_FSTAB}"
        umount "$BOOT_DIR" 2>/dev/null || true
        BOOT_DIR=""
        BOOT_DEV_FSTAB="" # ВАЖНО: сбрасываем, чтобы не добавить в fstab
      fi
    else
      msg_error "Не удалось примонтировать ${BOOT_DEV_FSTAB}"
      BOOT_DIR=""
      BOOT_DEV_FSTAB="" # ВАЖНО: сбрасываем
    fi
  fi

  # 1. Проверяем стандартные примонтированные точки (включая временный каталог, если установка была прервана)
  for dir in /boot /boot/firmware /media/boot /mnt/boot /mnt/ha_boot_tmp; do
    if [ -d "$dir" ] && { [ -f "$dir/armbianEnv.txt" ] || [ -f "$dir/uEnv.txt" ] || [ -f "$dir/extlinux/extlinux.conf" ]; }; then
      BOOT_DIR="$dir"
      return 0
    fi
  done

  # 2. Поиск по всей примонтированной ФС
  local found
  found=$(find / -maxdepth 3 -type f \( -name "armbianEnv.txt" -o -name "extlinux.conf" \) 2>/dev/null | head -1)
  if [ -n "$found" ]; then
    if [[ "$found" == *"/extlinux/"* ]]; then
      BOOT_DIR=$(dirname "$(dirname "$found")")
    else
      BOOT_DIR=$(dirname "$found")
    fi
    return 0
  fi

  # 3. Поиск ОТМОНТИРОВАННЫХ партиций (безопасный парсинг lsblk)
  msg_dim "Загрузчик не найден на диске. Поиск отмонтированных партиций..."
  
  local root_dev root_disk
  root_dev=$(findmnt -n -o SOURCE / 2>/dev/null)
  if [ -n "$root_dev" ]; then
    root_disk=$(lsblk -nlo PKNAME "$root_dev" 2>/dev/null)
  fi

  declare -a BOOT_CANDIDATES=()
  
  # Парсим только NAME, FSTYPE, MOUNTPOINT (в них нет пробелов)
  while IFS=' ' read -r dev fstype mnt; do
    # Пропускаем примонтированные, своп и пустые
    [ -n "$mnt" ] && continue
    [ "$fstype" = "swap" ] && continue
    [ -z "$fstype" ] && continue
    
    # Запрашиваем LABEL отдельной командой (защита от пробелов)
    local label
    label=$(lsblk -nlo LABEL "$dev" 2>/dev/null)
    
    # Фильтруем по меткам и ФС
    if [[ "$label" =~ [Bb][Oo][Oo][Tt] ]] || [[ "$label" =~ [Aa][Rr][Mm] ]] || [ "$fstype" = "vfat" ] || [ "$fstype" = "ext4" ]; then
      local pkname
      pkname=$(lsblk -nlo PKNAME "$dev" 2>/dev/null)
      
      local hint=""
      if [ "$pkname" = "$root_disk" ]; then
        hint="(Тот же диск, что и корень /)"
      else
        hint="(Другой диск: возможно SD-карта)"
      fi
      
      # Добавляем в массив кандидатов
      BOOT_CANDIDATES+=("$dev" "$fstype $label $hint")
    fi
  done < <(lsblk -lnpo NAME,FSTYPE,MOUNTPOINT 2>/dev/null)

  if [ ${#BOOT_CANDIDATES[@]} -eq 0 ]; then
    BOOT_DIR="/boot"
    return 0
  fi

  local selected_dev=""

  # Если кандидат ровно один - используем его
  if [ ${#BOOT_CANDIDATES[@]} -eq 2 ]; then
    selected_dev="${BOOT_CANDIDATES[0]}"
  else
    # Если кандидатов несколько (SD + eMMC) - СПРАШИВАЕМ
    msg_warn "Обнаружено несколько партиций с загрузчиком!"
    msg_dim "Корень системы (/) находится на: ${root_dev:-неизвестно}"
    
    if [ "$SILENT" != true ] && [ -t 0 ]; then
      if command -v whiptail &>/dev/null; then
        selected_dev=$(whiptail --title "Выбор загрузчика" --menu \
          "Система загрузилась с одного из этих разделов.\nВыберите ТОТ, с которого происходит загрузка:" \
          20 70 ${#BOOT_CANDIDATES[@]} "${BOOT_CANDIDATES[@]}" 3>&1 1>&2 2>&3) || selected_dev=""
      else
        echo -e "\n   ${BOLD}Обнаружены кандидаты на загрузчик:${NC}" >&2
        local i=1
        while [ $i -lt ${#BOOT_CANDIDATES[@]} ]; do
          echo -e "   ${CYAN}$((i/2+1)))${NC} ${BOOT_CANDIDATES[$((i-1))]} - ${BOOT_CANDIDATES[$i]}" >&2
          i=$((i+2))
        done
        echo -en "\n   ${ARROW} Введите номер: " >&2
        local choice; read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $(( ${#BOOT_CANDIDATES[@]}/2 )) ]; then
          selected_dev="${BOOT_CANDIDATES[$(( (choice-1)*2 ))]}"
        fi
      fi
    fi
    
    if [ -z "$selected_dev" ]; then
      msg_warn "Автоматический выбор: ${BOOT_CANDIDATES[0]}"
      selected_dev="${BOOT_CANDIDATES[0]}"
    fi
  fi

  # Монтируем выбранное устройство
  if [ -n "$selected_dev" ]; then
    msg_ok "Выбран раздел загрузчика: ${selected_dev}"
    BOOT_DIR="/mnt/ha_boot_tmp"
    mkdir -p "$BOOT_DIR"
    
    msg_action "Временное монтирование ${selected_dev} в ${BOOT_DIR}..."
    if mount "$selected_dev" "$BOOT_DIR" 2>/dev/null; then
      if [ -f "$BOOT_DIR/armbianEnv.txt" ] || [ -f "$BOOT_DIR/uEnv.txt" ] || [ -f "$BOOT_DIR/extlinux/extlinux.conf" ]; then
        msg_ok "Загрузчик найден и примонтирован"
        BOOT_DEV_FSTAB="$selected_dev"
        return 0
      else
        msg_warn "Файлы загрузчика не найдены в ${selected_dev}"
        umount "$BOOT_DIR" 2>/dev/null || true
        BOOT_DIR=""
        BOOT_DEV_FSTAB="" # ВАЖНО: сбрасываем
      fi
    else
      msg_error "Не удалось примонтировать ${selected_dev}"
      BOOT_DIR=""
      BOOT_DEV_FSTAB="" # ВАЖНО: сбрасываем
    fi
  fi

  # 4. Fallback
  BOOT_DIR="/boot"
}

# ============================================================================
# SETUP: Настройка конфигурации загрузчика
# ============================================================================
# Патчинг файлов загрузчика для включения AppArmor и настройка fstab
setup_bootloader_apparmor() {
  msg_info "Каталог загрузчика: ${BOOT_DIR}"
  
  local patched=false
  local boot_files=()
  
  # Формируем список файлов на основе найденного каталога
  [ -f "${BOOT_DIR}/armbianEnv.txt" ] && boot_files+=("${BOOT_DIR}/armbianEnv.txt")
  [ -f "${BOOT_DIR}/uEnv.txt" ] && boot_files+=("${BOOT_DIR}/uEnv.txt")
  [ -f "${BOOT_DIR}/extlinux/extlinux.conf" ] && boot_files+=("${BOOT_DIR}/extlinux/extlinux.conf")
  [ -f "${BOOT_DIR}/cmdline.txt" ] && boot_files+=("${BOOT_DIR}/cmdline.txt") # Добавлена поддержка RPi

  # Если файлы не найдены, пытаемся искать в /boot как фоллбэк
  if [ ${#boot_files[@]} -eq 0 ] && [ "$BOOT_DIR" != "/boot" ]; then
    msg_warn "Конфиги не найдены в ${BOOT_DIR}, проверяем /boot..."
    BOOT_DIR="/boot"
    [ -f "${BOOT_DIR}/armbianEnv.txt" ] && boot_files+=("${BOOT_DIR}/armbianEnv.txt")
    [ -f "${BOOT_DIR}/uEnv.txt" ] && boot_files+=("${BOOT_DIR}/uEnv.txt")
    [ -f "${BOOT_DIR}/extlinux/extlinux.conf" ] && boot_files+=("${BOOT_DIR}/extlinux/extlinux.conf")
    [ -f "${BOOT_DIR}/cmdline.txt" ] && boot_files+=("${BOOT_DIR}/cmdline.txt")
  fi

  if [ ${#boot_files[@]} -eq 0 ]; then
    msg_error "Конфиг загрузчика не найден!"
    return 1
  fi

  # Патчим найденные файлы
  for f in "${boot_files[@]}"; do
    cp "$f" "${BACKUP_DIR}/$(basename "$f").bak" 2>/dev/null
    
    # Уже пропатчено?
    if grep -q "apparmor=1" "$f" 2>/dev/null; then
      msg_ok "$(basename "$f") уже содержит apparmor=1"
      patched=true
      continue
    fi

    msg_action "Патчинг $(basename "$f")..."

    # Разная логика для разных форматов файлов
    case "$(basename "$f")" in
      extlinux.conf)
        # extlinux: дописать в конец строки APPEND
        sed -i '/^[[:space:]]*[Aa][Pp][Pp][Ee][Nn][Dd]/ s/$/ apparmor=1 security=apparmor/' "$f"
        if grep -q "apparmor=1" "$f"; then
          msg_ok "$(basename "$f") пропатчен (строка APPEND)"; patched=true
        else
          msg_warn "$(basename "$f"): строка APPEND не найдена для патчинга"
        fi
        ;;
        
      cmdline.txt)
        # Raspberry Pi: весь файл - это одна строка. Дописать в конец.
        sed -i 's/$/ apparmor=1 security=apparmor/' "$f"
        if grep -q "apparmor=1" "$f"; then
          msg_ok "$(basename "$f") пропатчен (одна строка)"; patched=true
        else
          msg_error "Не удалось пропатчить $(basename "$f")"
        fi
        ;;
        
      armbianEnv.txt|uEnv.txt)
        # Armbian/uEnv: формат ключ=значение. Ищем переменные, которые гарантированно попадают в bootargs.
        if grep -q "^extraargs=" "$f" 2>/dev/null; then
          # Стандартный Armbian
          sed -i '/^extraargs=/ s/$/ apparmor=1 security=apparmor/' "$f"
          msg_ok "$(basename "$f") пропатчен (добавлено в extraargs)"
        elif grep -q "^optargs=" "$f" 2>/dev/null; then
          # Альтернативный стандарт
          sed -i '/^optargs=/ s/$/ apparmor=1 security=apparmor/' "$f"
          msg_ok "$(basename "$f") пропатчен (добавлено в optargs)"
        elif grep -q "^APPEND=" "$f" 2>/dev/null; then
          # Кастомные прошивки TV-боксов: всё вписано в одну строку APPEND=
          sed -i '/^APPEND=/ s/$/ apparmor=1 security=apparmor/' "$f"
          msg_ok "$(basename "$f") пропатчен (добавлено в APPEND)"
        elif grep -q "^rootflags=" "$f" 2>/dev/null; then
          # Фоллбэк для TV-боксов: U-Boot игнорирует extraargs, но использует rootflags.
          sed -i '/^rootflags=/ s/$/ apparmor=1 security=apparmor/' "$f"
          msg_ok "$(basename "$f") пропатчен (добавлено в rootflags)"
        else
          # Нет ни одной подходящей переменной. Создаем extraargs=, но предупрежаем.
          echo "extraargs=apparmor=1 security=apparmor" >> "$f"
          msg_warn "$(basename "$f") пропатчен (создана extraargs). Если AppArmor не заработает, U-Boot игнорирует эту переменную."
        fi
        patched=true
        ;;
        
      *)
        msg_warn "Неизвестный формат загрузчика: $(basename "$f")"
        ;;
    esac
  done

  # Если загрузчик был примонтирован временно, добавляем партицию в fstab
  if [ -n "$BOOT_DEV_FSTAB" ]; then
    local fstype
    fstype=$(lsblk -nlo FSTYPE "$BOOT_DEV_FSTAB" 2>/dev/null | head -1)
    
    if [ -n "$fstype" ]; then
      msg_action "Добавляем партицию загрузчика в /etc/fstab для монтирования при старте..."
      if ! grep -q "$BOOT_DEV_FSTAB" /etc/fstab 2>/dev/null; then
        local mount_point="/boot"
        if grep -q " /boot " /etc/fstab 2>/dev/null; then
          mount_point="/media/boot"
          mkdir -p "$mount_point"
        fi
        
        local dev_uuid
        dev_uuid=$(blkid -s UUID -o value "$BOOT_DEV_FSTAB" 2>/dev/null)
        
        if [ -n "$dev_uuid" ]; then
          echo "UUID=$dev_uuid $mount_point $fstype defaults,noatime 0 2" >> /etc/fstab
          msg_ok "Партиция добавлена в fstab (монтируется в $mount_point)"
        else
          msg_warn "Не удалось определить UUID $BOOT_DEV_FSTAB. Пропуск добавления в fstab (небезопасно)"
        fi
      else
        msg_dim "Партиция уже присутствует в fstab"
      fi
    else
      msg_warn "Не удалось определить ФС для fstab"
    fi
  fi

  if [ "$patched" != true ]; then
    return 1
  fi
  
  return 0
}

# ============================================================================
# ШАГ: APPARMOR
# ============================================================================
step_configure_apparmor() {
    local sid="apparmor"; is_done "$sid" && return 0
    header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] APPARMOR"

    # 1. Убеждаемся, что пользовательские утилиты AppArmor установлены
    if ! is_pkg_installed apparmor; then
        msg_action "Установка пакета apparmor..."
        apt_safe install -y apparmor >/dev/null 2>&1 || true
    fi
    
    # 2. Запускаем службу, если она не активна
    systemctl enable apparmor 2>/dev/null || true
    if ! systemctl is-active --quiet apparmor 2>/dev/null; then
        systemctl start apparmor 2>/dev/null || true
    fi

    # Защита от бесконечного цикла перезагрузок
    if [ -n "$FROM_STEP" ]; then
      local attempts=0
      [ -f "$REBOOT_ATTEMPT_FILE" ] && attempts=$(cat "$REBOOT_ATTEMPT_FILE" 2>/dev/null || echo 0)
      if [ "$attempts" -ge 3 ]; then
        msg_error "AppArmor не удалось включить после 3 перезагрузок."
        msg_warn "Продолжаем установку без AppArmor (HA будет Unsupported)."
        rm -f "$REBOOT_ATTEMPT_FILE"
        mark_done "$sid"
        return 0
      fi
    fi
    # 3. Проверяем статус в ядре
    local aa
    aa=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) || aa="N"

    if [ "$aa" = "Y" ]; then
        msg_ok "AppArmor включен в ядре"
        # Углубленная проверка: загружены ли политики
        if command -v aa-enabled >/dev/null 2>&1 && aa-enabled --quiet 2>/dev/null; then
            msg_ok "Политики AppArmor успешно загружены"
        else
            msg_warn "Политики AppArmor не энфорсятся"
            msg_dim "Home Assistant может показать предупреждение (Unsupported)"
        fi
        mark_done "$sid"
        return 0
    fi

    msg_warn "AppArmor не активен в ядре"

    # Определяем каталог загрузчика
    detect_boot_dir

    # Патчим загрузчик (setup_)
    if ! setup_bootloader_apparmor; then
        msg_error "Не удалось пропатчить загрузчик"
        msg_dim "AppArmor не будет активен. HA может работать с предупреждениями."
        systemctl enable apparmor 2>/dev/null || true
        mark_done "$sid"
        return 0
    fi

    msg_warn "Требуется перезагрузка для активации AppArmor"

    # Обработка перезагрузки
    if [ "$OPT_AUTO_REBOOT" = true ]; then
        msg_action "Настройка продолжения после перезагрузки..."
        if setup_reboot_continue "apparmor"; then
            save_config
            msg_ok "Перезагрузка через 10 секунд..."
            msg_dim "Установка продолжится автоматически после загрузки"
            msg_dim "Следить за логом после входа: tail -f /var/log/hassify_reboot.log"
            sleep 10
            sync
            reboot
            sleep 30
            exit 0
        else
            msg_error "Не удалось настроить продолжение после перезагрузки"
        fi
    fi

    if [ -t 0 ]; then
        echo ""
        msg_warn "AppArmor требует перезагрузки!"
        msg_info "Варианты:"
        msg_dim "  1) Перезагрузить сейчас (установка продолжится автоматически)"
        msg_dim "  2) Продолжить без перезагрузки (HA будет работать с предупреждениями)"
        msg_dim "  3) Выйти (перезагрузите вручную и запустите скрипт снова)"
        echo ""
        echo -en " ${ARROW} Выбор [1/2/3]: " >&2
        local choice
        read -r -t 60 choice || choice="2"

        case "$choice" in
            1)
                msg_action "Настройка продолжения..."
                if setup_reboot_continue "apparmor"; then
                    save_config
                    msg_ok "Перезагрузка..."
                    msg_dim "После загрузки скрипт продолжит работу автоматически в фоне."
                    msg_dim "Следить за логом: tail -f /var/log/hassify_reboot.log"
                    sleep 3
                    sync
                    reboot
                    sleep 30
                    exit 0
                else
                    msg_error "Не удалось настроить продолжение"
                    msg_info "Перезагрузите вручную и запустите скрипт снова:"
                    msg_dim "  sudo reboot"
                    msg_dim "  sudo bash ${SAFE_SCRIPT_PATH:-$0} --from-step=apparmor"
                    exit 1
                fi
                ;;
            3)
                msg_info "Перезагрузите и запустите скрипт снова:"
                msg_dim "  sudo reboot"
                msg_dim "  sudo bash ${SAFE_SCRIPT_PATH:-$0} --from-step=apparmor"
                exit 0
                ;;
            2|*)
                msg_warn "Продолжение без AppArmor"
                msg_dim "HA будет работать, но покажет предупреждение о неподдерживаемой системе"
                msg_dim "Для активации позже: sudo reboot"
                ;;
        esac
    else
        msg_warn "Продолжение без AppArmor (не интерактивный режим)"
    fi

    systemctl enable apparmor 2>/dev/null || true
    mark_done "$sid"
}

# ============================================================================
# ШАГ: ПРОИЗВОДИТЕЛЬНОСТЬ
# ============================================================================
step_performance() {
  local sid="perf"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] ПРОИЗВОДИТЕЛЬНОСТЬ"

  setup_swap "$OPT_SWAP_SIZE"
  
  if [ "$OPT_ZRAM" = true ] && [ "$OPT_SWAP_SIZE" != "zram" ]; then
    setup_zram
  fi

  [ "$OPT_EMMC_TUNING" = true ] && apply_emmc_tuning
  [ "$OPT_USB_POWER" = true ]   && apply_usb_power_fix

  mark_done "$sid"
}

# ============================================================================
# ШАГ: DOCKER
# ============================================================================
step_install_docker() {
  local sid="docker"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] DOCKER"

  require_disk_space 2000 "Docker" || exit 1
  push_rollback 'apt-get remove -y docker-ce docker-ce-cli containerd.io 2>/dev/null'

  install_docker || exit 1

  mkdir -p /etc/docker
  [ ! -f /etc/docker/daemon.json ] && \
    echo '{"log-driver":"journald","storage-driver":"overlay2"}' > /etc/docker/daemon.json
  
  configure_docker_mirror "$OPT_DOCKER_MIRROR"

  systemctl enable docker 2>/dev/null || true
  systemctl restart docker 2>/dev/null || true
  wait_for_docker

  setup_data_dir "$OPT_DATA_DIR"

  mark_done "$sid"
}

# ============================================================================
# ШАГ: ОПРЕДЕЛЕНИЕ ВЕРСИЙ
# ============================================================================
step_resolve_versions() {
  local sid="versions"
  if is_done "$sid"; then
    load_config
    RESOLVED_OA_VER="${OA_VERSION:-}"
    RESOLVED_HA_VER="${HA_VERSION:-}"
    [ -n "$OVERRIDE_OS_AGENT_VER" ] && RESOLVED_OA_VER="$OVERRIDE_OS_AGENT_VER"
    [ -n "$OVERRIDE_HA_VER" ] && RESOLVED_HA_VER="$OVERRIDE_HA_VER"
    if [ -n "$RESOLVED_OA_VER" ] && [ -n "$RESOLVED_HA_VER" ]; then
      msg_ok "Версии: OA=${RESOLVED_OA_VER} HA=${RESOLVED_HA_VER}"
      return 0
    fi
  fi

  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] ОПРЕДЕЛЕНИЕ ВЕРСИЙ"

  if [ -n "$OVERRIDE_OS_AGENT_VER" ]; then
    RESOLVED_OA_VER="$OVERRIDE_OS_AGENT_VER"
  else
    msg_action "Определение OS-Agent..."
    RESOLVED_OA_VER=$(get_latest_release "home-assistant/os-agent")
  fi
  [ -z "$RESOLVED_OA_VER" ] && { msg_error "Версия OS-Agent не найдена"; exit 1; }

  if [ -n "$OVERRIDE_HA_VER" ]; then
    RESOLVED_HA_VER="$OVERRIDE_HA_VER"
  else
    msg_action "Определение HA..."
    RESOLVED_HA_VER=$(get_latest_release "home-assistant/supervised-installer")
  fi
  [ -z "$RESOLVED_HA_VER" ] && { msg_error "Версия HA не найдена"; exit 1; }

  msg_ok "OA: ${RESOLVED_OA_VER}  HA: ${RESOLVED_HA_VER}"
  mark_done "$sid"
}

# ============================================================================
# ШАГ: ЗАГРУЗКА ПАКЕТОВ
# ============================================================================
step_download_packages() {
  local sid="download"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] ЗАГРУЗКА ПАКЕТОВ"

  detect_system_info
  require_disk_space 500 "Загрузка" || { msg_error "Нет места"; exit 1; }

  local tf; tf=$(df -m "$HA_TMP" 2>/dev/null | awk 'NR==2{print $4}')
  if [ "${tf:-0}" -lt 200 ]; then
    umount "$HA_TMP" 2>/dev/null || true
    HA_TMP="/var/tmp/ha-install"
    mkdir -p "$HA_TMP"
  fi

  download_file \
    "https://github.com/home-assistant/os-agent/releases/download/${RESOLVED_OA_VER}/os-agent_${RESOLVED_OA_VER}_linux_${CACHED_ARCH}.deb" \
    "${HA_TMP}/os-agent.deb" "OS-Agent" || { msg_error "Загрузка OS-Agent!"; exit 1; }
  verify_checksum "${HA_TMP}/os-agent.deb" "home-assistant/os-agent" "$RESOLVED_OA_VER"

  download_file \
    "https://github.com/home-assistant/supervised-installer/releases/download/${RESOLVED_HA_VER}/homeassistant-supervised.deb" \
    "${HA_TMP}/ha.deb" "HA Supervised" || { msg_error "Загрузка HA!"; exit 1; }
  verify_checksum "${HA_TMP}/ha.deb" "home-assistant/supervised-installer" "$RESOLVED_HA_VER"

  msg_ok "Загружены и проверены"
  mark_done "$sid"
}

# ============================================================================
# ШАГ: OS-AGENT
# ============================================================================
step_install_os_agent() {
  local sid="osagent"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] OS-AGENT"

  push_rollback 'dpkg --purge os-agent 2>/dev/null'
  run_cmd_fatal "OS-Agent" dpkg -i "${HA_TMP}/os-agent.deb"

  if command -v gdbus &>/dev/null; then
    gdbus introspect --system --dest io.hass.os --object-path /io/hass/os &>/dev/null \
      && msg_ok "D-Bus OK" || msg_warn "D-Bus будет доступен после перезагрузки"
  fi

  mark_done "$sid"
}

# ============================================================================
# WAIT: Ожидание готовности сервисов
# ============================================================================

# Ожидание запуска службы hassio-supervisor
wait_supervisor() {
  local to="${1:-120}" el=0
  while ! systemctl is-active --quiet hassio-supervisor 2>/dev/null; do
    sleep 5; el=$((el+5))
    [ $el -ge $to ] && { msg_warn "Таймаут ожидания supervisor"; return 1; }
    [ $((el%15)) -eq 0 ] && msg_dim "Ожидание Supervisor... ${el}с"
  done
  msg_ok "hassio-supervisor активен"
  return 0
}

# Ожидание запуска всех контейнеров HA
wait_ha_containers() {
  local to="${1:-900}" el=0
  local expected="hassio_dns hassio_cli hassio_audio hassio_multicast hassio_observer"
  local all_ok=false

  msg_action "Ожидание загрузки контейнеров (5-20 мин)..."
  while [ $el -lt $to ]; do
    local running=0 total=0
    for c in $expected homeassistant; do
      total=$((total + 1))
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${c}$"; then
        running=$((running + 1))
      fi
    done

    if [ $running -eq $total ]; then
      all_ok=true; break
    fi

    progress_bar $el $to "Контейнеры: ${running}/${total}"
    sleep 15; el=$((el + 15))

    # Каждые 3 минуты проверяем supervisor
    if [ $((el % 180)) -eq 0 ]; then
      progress_clear
      if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^hassio_supervisor$'; then
        msg_warn "Supervisor остановился, перезапуск..."
        systemctl restart hassio-supervisor 2>/dev/null || true
      fi
    fi
  done

  progress_clear

  if [ "$all_ok" = true ]; then
    msg_ok "Все контейнеры запущены (${el}с)"
    return 0
  else
    msg_warn "Не все контейнеры загрузились. Supervisor продолжит в фоне."
    return 1
  fi
}

# ============================================================================
# INSTALL: Установка пакетов
# ============================================================================

# Установка deb-пакета HA Supervised с обработкой зависимостей
install_ha_supervised_pkg() {
  local deb_file="${1:-}"
  local machine="${2:-qemuarm-64}"
  
  [ ! -f "$deb_file" ] && { msg_error "DEB файл не найден"; return 1; }
  
  msg_action "Установка HA Supervised..."
  msg_dim "Машина: ${machine}"
  export MACHINE="$machine"

  local dpkg_log="${HA_TMP}/dpkg_output.log"
  DEBIAN_FRONTEND=noninteractive dpkg -i "$deb_file" > "$dpkg_log" 2>&1
  local de=$?

  # Фильтрованный вывод лога
  grep -iE "(pull|download|unpack|setting up|error|warn)" "$dpkg_log" 2>/dev/null \
    | grep -vi "cgroup v1" \
    | while IFS= read -r l; do echo -e "   ${BLUE}|${NC} ${l}"; done
  rm -f "$dpkg_log"

  # Обработка ошибок dpkg
  if [ $de -ne 0 ]; then
    msg_warn "dpkg завершился с кодом ${de}, попытка исправить зависимости..."
    if ! apt-get install -f -y >/dev/null 2>&1; then
      msg_error "Не удалось исправить зависимости! Установка HA прервана."
      return 1
    fi
  fi
  return 0
}

# ============================================================================
# ШАГ: HOME ASSISTANT SUPERVISED
# ============================================================================
step_install_ha() {
  local sid="ha"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] HOME ASSISTANT SUPERVISED"

  require_disk_space 1500 "HA" || { msg_error "Нет места для HA"; exit 1; }
  push_rollback 'apply_os_release_restore 2>/dev/null; dpkg --purge homeassistant-supervised 2>/dev/null'

  # 1. Подмена os-release
  if os_release_needs_faking; then
    msg_warn "Подмена os-release"
    apply_os_release_fake
  else
    msg_ok "os-release OK"
  fi

  # 2. Установка пакета
  if ! install_ha_supervised_pkg "${HA_TMP}/ha.deb" "$HA_MACHINE"; then
    msg_error "Ошибка установки пакета HA!"
    apply_os_release_restore # Откатываем подмену, если установка провалилась
    return 1
  fi

  # 3. Настройка drop-in для systemd
  if [ "$OS_RELEASE_FAKED" = true ]; then
    setup_os_release_dropin
    apply_os_release_restore # Возвращаем оригинальный os-release для системы
    msg_info "Drop-in: подмена при старте, восстановление при остановке"
  fi

  # 4. Ожидание сервисов
  wait_supervisor 120 || true
  wait_ha_containers 900

  # 5. Финализация шага
  touch "$GRACE_MARKER"
  save_config
  msg_ok "HA Supervised установлен"
  mark_done "$sid"
}

# ============================================================================
# INSTALL: Установка пакетов безопасности
# ============================================================================

# Установка fail2ban
install_fail2ban() {
  if ! is_pkg_installed fail2ban; then
    apt_safe install -y fail2ban >/dev/null || { msg_warn "fail2ban не установлен"; return 1; }
  fi
}

# ============================================================================
# CONFIGURE: Настройка параметров работающих сервисов
# ============================================================================

# Открытие специфичных портов для HA в UFW
configure_ufw_ha_ports() {
  ufw status | grep -qw '4357/tcp' || ufw allow 4357/tcp comment ESPHome >/dev/null 2>&1
  ufw status | grep -qw '5353/udp' || ufw allow 5353/udp comment mDNS >/dev/null 2>&1
  ufw status | grep -qw '5683/udp' || ufw allow 5683/udp comment HomeKit >/dev/null 2>&1
  msg_ok "Порты HA (ESPHome, mDNS, HomeKit) открыты"
}

# ============================================================================
# SETUP: Создание файлов конфигурации безопасности
# ============================================================================

# Инъекция правил DOCKER-USER в /etc/ufw/after.rules
setup_ufw_docker_rules() {
  if ! grep -q "# BEGIN HA-INSTALLER DOCKER-USER" /etc/ufw/after.rules 2>/dev/null; then
    local iok=true
    command -v iptables &>/dev/null && iptables --version 2>/dev/null | grep -q legacy && iok=false
    
    if $iok; then
      # Вставляем правила ДО последнего COMMIT в таблице *filter.
      sed -i '$ s/^COMMIT/\
### BEGIN HA-INSTALLER DOCKER-USER RULES ###\
:DOCKER-USER - [0:0]\
-A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN\
-A DOCKER-USER -s 10.0.0.0\/8 -j RETURN\
-A DOCKER-USER -s 172.16.0.0\/12 -j RETURN\
-A DOCKER-USER -s 192.168.0.0\/16 -j RETURN\
-A DOCKER-USER -j DROP\
### END HA-INSTALLER DOCKER-USER RULES ###\
\
COMMIT/' /etc/ufw/after.rules

      ufw reload >/dev/null 2>&1
      msg_ok "DOCKER-USER правила (изоляция Docker)"
    else
      msg_warn "DOCKER-USER пропущен (обнаружен legacy iptables)"
    fi
  fi
}

# Создание конфига /etc/fail2ban/jail.local
setup_fail2ban() {
  if is_trixie || [ ! -f /var/log/auth.log ]; then
    printf '[sshd]\nenabled=true\nport=ssh\nfilter=sshd\nbackend=systemd\nmaxretry=5\nbantime=3600\nfindtime=600\n' \
      > /etc/fail2ban/jail.local
  else
    printf '[sshd]\nenabled=true\nport=ssh\nfilter=sshd\nlogpath=/var/log/auth.log\nbackend=auto\nmaxretry=5\nbantime=3600\nfindtime=600\n' \
      > /etc/fail2ban/jail.local
  fi
  systemctl enable fail2ban 2>/dev/null || true
  systemctl restart fail2ban 2>/dev/null || true
  msg_ok "Fail2Ban настроен"
}

# Создание конфигов автообновлений APT
setup_auto_updates() {
  cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'U'
Unattended-Upgrade::Allowed-Origins { "${distro_id}:${distro_codename}-security"; };
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
U
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\nAPT::Periodic::AutocleanInterval "7";\n' \
    > /etc/apt/apt.conf.d/20auto-upgrades
  msg_ok "Автообновления безопасности"
}

# ============================================================================
# ШАГ: БЕЗОПАСНОСТЬ
# ============================================================================
step_security() {
  local sid="sec"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] БЕЗОПАСНОСТЬ"
  local any=false

  if [ "$OPT_UFW" = true ]; then
    any=true

    # 1. Базовая настройка UFW (включение, порты 22 и 8123) - уже существующая функция
    configure_ufw_safe

    # 2. Дополнительные порты для HA
    configure_ufw_ha_ports

    # 3. Изоляция Docker (чтобы контейнеры не обошли UFW)
    setup_ufw_docker_rules

    # 4. Fail2Ban
    install_fail2ban && setup_fail2ban
  fi

  # 5. SSH Hardening (уже существующая функция)
  if [ "$OPT_SSH_HARDENING" = true ]; then
    any=true
    apply_ssh_hardening
  fi

  # 6. Автообновления системы
  if [ "$OPT_AUTOUPDATE" = true ]; then
    any=true
    setup_auto_updates
  fi

  $any || msg_warn "Пропущено"
  mark_done "$sid"
}

# ============================================================================
# CONFIGURE: Изменение параметров системы
# ============================================================================

# Настройка имени хоста и mDNS
configure_hostname_avahi() {
  [ "$OPT_HOSTNAME" = true ] && {
    if [ ! -f "${BACKUP_DIR}/hostname.bak" ]; then
      hostname > "${BACKUP_DIR}/hostname.bak" 2>/dev/null || true
    fi
    hostnamectl set-hostname homeassistant 2>/dev/null || true
    msg_ok "Имя хоста: homeassistant"
  }
  systemctl enable avahi-daemon >/dev/null 2>&1 || true
  systemctl start avahi-daemon >/dev/null 2>&1 || true
  msg_ok "mDNS (avahi)"
}

# Настройка заданий cron
configure_cron() {
  {
    echo "# Hassify v${SCRIPT_VERSION}"
    [ "$OPT_WATCHDOG" = true ] && printf '*/5 * * * * root /usr/local/bin/ha-watchdog >/dev/null 2>&1\n*/10 * * * * root /usr/local/bin/ha-net-recovery >/dev/null 2>&1\n30 3 * * * root /usr/local/bin/ha-cleanup >/dev/null 2>&1\n'
    [ "$OPT_THERMAL" = true ] && echo '*/5 * * * * root /usr/local/bin/ha-thermal >/dev/null 2>&1'
    [ "$OPT_BACKUP" = true ] && echo '0 4 * * 0 root /usr/local/bin/ha-backup >/dev/null 2>&1'
    [ "$OPT_REMOTE_BACKUP" = true ] && echo '30 4 * * 0 root /usr/local/bin/ha-backup-remote >/dev/null 2>&1'
    [ "$OPT_MONITORING" = true ] && echo '* * * * * root /usr/local/bin/ha-metrics >/dev/null 2>&1'
    echo '0 9 * * 1 root /usr/local/bin/ha-weekly-report >/dev/null 2>&1'
  } > /etc/cron.d/ha-tools
  chmod 644 /etc/cron.d/ha-tools
  msg_ok "Задания cron"
}

# ============================================================================
# SETUP: Создание файлов и утилит
# ============================================================================

# setup_: Сохранение токенов уведомлений в защищенные файлы
setup_ha_secrets() {
  local secrets_dir="${HA_INSTALLER_DIR}/secrets"
  mkdir -p "$secrets_dir"
  chmod 700 "$secrets_dir"
  printf '%s' "${TG_TOKEN}"        > "${secrets_dir}/tg_token"
  printf '%s' "${TG_CHAT}"         > "${secrets_dir}/tg_chat"
  printf '%s' "${OPT_WEBHOOK_URL}" > "${secrets_dir}/webhook_url"
  chmod 600 "${secrets_dir}/tg_token" "${secrets_dir}/tg_chat" "${secrets_dir}/webhook_url" 2>/dev/null
}

# setup_: Генерация скрипта ha-notify
setup_script_notify() {
  cat > /usr/local/bin/ha-notify << 'NTEOF'
#!/bin/bash
MSG="${1:-}"
[ -z "$MSG" ] && exit 0

RF="/tmp/.ha_notify_rate"
NOW=$(date +%s)
LAST=$(cat "$RF" 2>/dev/null || echo 0)
[ $((NOW - LAST)) -lt 30 ] && exit 0
echo "$NOW" > "$RF"

SECRETS="/var/lib/hassify/secrets"
TG_TOKEN=$(cat "${SECRETS}/tg_token"    2>/dev/null || echo "")
TG_CHAT=$(cat  "${SECRETS}/tg_chat"     2>/dev/null || echo "")
WEBHOOK=$(cat  "${SECRETS}/webhook_url"  2>/dev/null || echo "")

HOST=$(hostname 2>/dev/null || echo "ha-box")
FULL_MSG="Hassify (${HOST}): ${MSG}"

if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
  curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT}" \
    --data-urlencode "text=${FULL_MSG}" \
    >/dev/null 2>&1
fi

if [ -n "$WEBHOOK" ]; then
  case "$WEBHOOK" in
    *ntfy.sh/*)
      curl -s -X POST "$WEBHOOK" -H "Title: Home Assistant" -H "Priority: default" -H "Tags: house" -d "$FULL_MSG" >/dev/null 2>&1 || true ;;
    *discord.com/api/webhooks/*|*discordapp.com/api/webhooks/*)
      ESCAPED=$(printf '%s' "$FULL_MSG" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
      curl -s -X POST "$WEBHOOK" -H "Content-Type: application/json" -d "{\"content\":\"${ESCAPED}\"}" >/dev/null 2>&1 || true ;;
    *hooks.slack.com/*)
      ESCAPED=$(printf '%s' "$FULL_MSG" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
      curl -s -X POST "$WEBHOOK" -H "Content-Type: application/json" -d "{\"text\":\"${ESCAPED}\"}" >/dev/null 2>&1 || true ;;
    */message*|*gotify*)
      ESCAPED=$(printf '%s' "$FULL_MSG" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
      curl -s -X POST "$WEBHOOK" -H "Content-Type: application/json" -d "{\"title\":\"Home Assistant\",\"message\":\"${ESCAPED}\",\"priority\":5}" >/dev/null 2>&1 || true ;;
    *)
      RC=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$WEBHOOK" -d "$FULL_MSG" 2>/dev/null) || RC="000"
      RC="${RC:-000}"
      if [[ ! "$RC" =~ ^2 ]]; then
        ESCAPED=$(printf '%s' "$FULL_MSG" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
        curl -s -X POST "$WEBHOOK" -H "Content-Type: application/json" -d "{\"text\":\"${ESCAPED}\",\"message\":\"${ESCAPED}\"}" >/dev/null 2>&1 || true
      fi ;;
  esac
fi
NTEOF
  chmod 700 /usr/local/bin/ha-notify
  msg_ok "Скрипт: ha-notify"
}

# setup_: Генерация скриптов Watchdog, Cleanup, Net-recovery
setup_script_watchdog() {
  cat > /usr/local/bin/ha-watchdog << 'S'
#!/bin/bash
GF="/tmp/.ha_just_installed"
[ -f "$GF" ] && { [ $(($(date +%s)-$(stat -c %Y "$GF" 2>/dev/null||echo 0))) -lt 1200 ] && exit 0; rm -f "$GF"; }
SF="/tmp/ha_wd_state"
IFS='|' read -r fails last_restart backoff < "$SF" 2>/dev/null || { fails=0; last_restart=0; backoff=5; }
c=$(curl -s -o /dev/null -w "%{http_code}" -m 10 http://localhost:8123 2>/dev/null||echo 000)
if [ "$c" = "000" ]; then
  fails=$((fails+1)); now=$(date +%s)
  mins_since=$([ "$last_restart" -gt 0 ] && echo $(((now-last_restart)/60)) || echo 999)
  if [ "$fails" -ge 3 ] && [ "$mins_since" -ge "$backoff" ]; then
    docker restart homeassistant 2>/dev/null
    /usr/local/bin/ha-notify "WD перезапуск #${fails} (пауза ${backoff}м)"
    last_restart=$now; backoff=$((backoff*2)); [ "$backoff" -gt 60 ] && backoff=60; fails=0
  fi
else fails=0; backoff=5; fi
echo "${fails}|${last_restart}|${backoff}" > "$SF"
S

  cat > /usr/local/bin/ha-cleanup << 'S'
#!/bin/bash
fm=$(df -m / | awk 'NR==2{print $4}')
[ "$fm" -lt 1500 ] && {
  docker system prune -f 2>/dev/null
  journalctl --vacuum-size=30M 2>/dev/null
  apt-get clean 2>/dev/null
  /usr/local/bin/ha-notify "Очистка: ${fm}МБ -> $(df -m / | awk 'NR==2{print $4}')МБ"
}
S

  cat > /usr/local/bin/ha-net-recovery << 'S'
#!/bin/bash
GW=$(ip route 2>/dev/null | awk '/default/{print $3}' | head -1)
[ -z "$GW" ] && GW=8.8.8.8
ping -c2 -W3 "$GW" >/dev/null 2>&1 && exit 0
ping -c2 -W3 8.8.8.8 >/dev/null 2>&1 && exit 0
nmcli networking off 2>/dev/null; sleep 3; nmcli networking on 2>/dev/null; sleep 5
ping -c2 -W3 8.8.8.8 >/dev/null 2>&1 \
  && /usr/local/bin/ha-notify "Сеть восстановлена" \
  || /usr/local/bin/ha-notify "Сеть НЕ восстановлена"
S

  chmod +x /usr/local/bin/ha-watchdog /usr/local/bin/ha-cleanup /usr/local/bin/ha-net-recovery
  msg_ok "Скрипты: Watchdog (экспон. откат)"
}

# setup_: Генерация скрипта термомонитора
setup_script_thermal() {
  cat > /usr/local/bin/ha-thermal << 'S'
#!/bin/bash
[ ! -f /sys/class/thermal/thermal_zone0/temp ] && exit 0
t=$(($(cat /sys/class/thermal/thermal_zone0/temp)/1000))
[ "$t" -ge 80 ] && /usr/local/bin/ha-notify "КРИТИЧ. ТЕМП: ${t}C!"
[ "$t" -ge 70 ] && [ "$t" -lt 80 ] && /usr/local/bin/ha-notify "ВЫСОКАЯ ТЕМП: ${t}C"
S
  chmod +x /usr/local/bin/ha-thermal
  msg_ok "Скрипт: Термомонитор"
}

# setup_: Генерация скриптов здоровья и еженедельного отчета
setup_script_health() {
  cat > /usr/local/bin/ha-health << 'S'
#!/bin/bash
echo "===== Здоровье HA ($(date)) ====="
printf " %-16s %s\n" \
  "Хост:" "$(hostname)" \
  "IP:" "$(hostname -I 2>/dev/null | awk '{print $1}')" \
  "Время работы:" "$(uptime -p 2>/dev/null)" \
  "Ядро:" "$(uname -r)"
[ -f /sys/class/thermal/thermal_zone0/temp ] && \
  printf " %-16s %dC\n" "CPU:" "$(($(cat /sys/class/thermal/thermal_zone0/temp)/1000))"
free -h | awk '/Mem:/{printf " %-16s %s/%s\n","RAM:",$3,$2} /Swap:/{printf " %-16s %s/%s\n","Swap:",$3,$2}'
df -h / | awk 'NR==2{printf " %-16s %s/%s (%s)\n","Диск:",$3,$2,$5}'
echo "-- Контейнеры --"
docker ps --format " {{.Names}}: {{.Status}}" 2>/dev/null || echo " н/д"
echo "-- Docker диск --"
docker system df 2>/dev/null || echo " н/д"
printf " %-16s %s\n" "HA:" "$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://localhost:8123 2>/dev/null || echo 000)"
echo "========================="
S

  cat > /usr/local/bin/ha-weekly-report << 'S'
#!/bin/bash
ha_code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://localhost:8123 2>/dev/null || echo 000)
cpu_temp="н/д"
[ -f /sys/class/thermal/thermal_zone0/temp ] && cpu_temp="$(($(cat /sys/class/thermal/thermal_zone0/temp)/1000))C"
ram_info=$(free -h | awk '/Mem:/{printf "%s/%s",$3,$2}')
disk_info=$(df -h / | awk 'NR==2{printf "%s/%s (%s)",$3,$2,$5}')
uptime_info=$(uptime -p 2>/dev/null || echo "неизвестно")
containers=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l)

R="Еженедельный отчёт"
R="${R}"$'\n'"HA: ${ha_code}"
R="${R}"$'\n'"CPU: ${cpu_temp}"
R="${R}"$'\n'"RAM: ${ram_info}"
R="${R}"$'\n'"Диск: ${disk_info}"
R="${R}"$'\n'"Время работы: ${uptime_info}"
R="${R}"$'\n'"Контейнеры: ${containers}"
/usr/local/bin/ha-notify "$R"
S

  chmod +x /usr/local/bin/ha-health /usr/local/bin/ha-weekly-report
  msg_ok "Скрипты: ha-health, Еженедельный отчёт"
}

# setup_: Генерация скриптов бэкапа (локальный, восстановление, удаленный)
setup_script_backups() {
  mkdir -p "$HA_BACKUP_DIR"

  cat > /usr/local/bin/ha-backup << BEOF
#!/bin/bash
set -f
BD="${HA_BACKUP_DIR}"; KD=30
TS=\$(date +%Y%m%d_%H%M%S); mkdir -p "\$BD"

if command -v ha &>/dev/null; then
  echo "Создание полного бэкапа через HA CLI..."
  ha backups new --name "AutoBackup_\${TS}" >/dev/null
  if [ \$? -eq 0 ]; then
    echo "Полный бэкап успешно создан!"
    /usr/local/bin/ha-notify "Полный бэкап CLI завершен: AutoBackup_\${TS}"
  else
    echo "ОШИБКА: Не удалось создать бэкап через HA CLI!"
    /usr/local/bin/ha-notify "Бэкап CLI: ОШИБКА"
    exit 1
  fi
  echo "Очистка старых снапшотов (оставляем 5 последних)..."
  SLUGS=\$(ha backups list 2>/dev/null | jq -r '.data.backups | sort_by(.date) | .[].slug' 2>/dev/null)
  COUNT=\$(echo "\$SLUGS" | wc -l)
  KEEP=5
  if [ "\$COUNT" -gt "\$KEEP" ]; then
    DELETE_COUNT=\$((COUNT - KEEP))
    echo "\$SLUGS" | head -n \$DELETE_COUNT | while read -r del_slug; do
      ha backups remove "\$del_slug" >/dev/null 2>&1
      echo "Удален старый снапшот: \${del_slug}"
    done
  fi
else
  echo "Утилита 'ha' не найдена. Используется быстрый бэкап (только конфиг Core)."
  CONFIG_DIR=\$(docker inspect homeassistant --format '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
  if [ -z "\$CONFIG_DIR" ]; then CONFIG_DIR="/usr/share/hassio/homeassistant"; fi
  if [ ! -d "\$CONFIG_DIR" ]; then echo "ОШИБКА: Каталог конфигурации HA не найден (\$CONFIG_DIR)."; exit 1; fi
  
  EX="--exclude=*.db --exclude=*.db-shm --exclude=*.db-wal --exclude=home-assistant_v2.db* --exclude=tts --exclude=deps --exclude=__pycache__"
  CONFIG_PARENT=\$(dirname "\$CONFIG_DIR")
  CONFIG_NAME=\$(basename "\$CONFIG_DIR")
  
  if command -v pigz &>/dev/null; then
    tar -I pigz -cf "\${BD}/ha_config_\${TS}.tar.gz" \$EX -C "\$CONFIG_PARENT" "\$CONFIG_NAME"
  else
    tar czf "\${BD}/ha_config_\${TS}.tar.gz" \$EX -C "\$CONFIG_PARENT" "\$CONFIG_NAME"
  fi
  if [ \$? -ne 0 ]; then echo "ОШИБКА при создании tar архива!"; exit 1; fi
  
  find "\$BD" -name "ha_config_*.tar.gz" -mtime +\$KD -delete 2>/dev/null
  BSIZE=\$(du -sh "\${BD}/ha_config_\${TS}.tar.gz" 2>/dev/null | awk '{print \$1}')
  /usr/local/bin/ha-notify "Бэкап TAR: \$BSIZE"
  echo "Бэкап конфига успешно создан: \${BD}/ha_config_\${TS}.tar.gz"
fi
BEOF

  cat > /usr/local/bin/ha-restore << REOF
#!/bin/bash
[ -z "\$BASH_VERSION" ] && { echo "Нужен bash!"; exit 1; }

if command -v ha &>/dev/null; then
  echo "Доступные полные бэкапы (снапшоты) Home Assistant:"
  echo "--------------------------------------------------"
  ha backups list
  echo "--------------------------------------------------"
  read -p "Введите Slug бэкапа для восстановления: " SLUG
  [ -z "\$SLUG" ] && { echo "Отменено"; exit 1; }
  read -p "Подтвердить восстановление снапшота \$SLUG? (да/yes): " c
  [ "\$c" != "да" ] && [ "\$c" != "yes" ] && exit 0
  echo "Восстановление..."
  if ha backups restore "\$SLUG"; then echo "Восстановление успешно запущено!"; else echo "ОШИБКА восстановления!"; exit 1; fi
else
  echo "Утилита 'ha' не найдена. Восстановление из TAR архива."
  BD="${HA_BACKUP_DIR}"
  CONFIG_DIR=\$(docker inspect homeassistant --format '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
  if [ -z "\$CONFIG_DIR" ]; then CONFIG_DIR="/usr/share/hassio/homeassistant"; fi
  CONFIG_PARENT=\$(dirname "\$CONFIG_DIR")
  CONFIG_NAME=\$(basename "\$CONFIG_DIR")

  mapfile -t F < <(ls -1t "\$BD"/ha_config_*.tar.gz 2>/dev/null)
  [ \${#F[@]} -eq 0 ] && { echo "Бэкапы не найдены"; exit 1; }
  for i in "\${!F[@]}"; do
    SIZE=\$(du -sh "\${F[\$i]}" | awk '{print \$1}')
    printf " %d) %s (%s)\n" "\$((i+1))" "\$(basename "\${F[\$i]}")" "\$SIZE"
  done
  read -p "Номер: " n
  [[ ! "\$n" =~ ^[0-9]+\$ ]] || [ "\$n" -lt 1 ] || [ "\$n" -gt \${#F[@]} ] && exit 1
  read -p "Подтвердить? (да/yes): " c
  [ "\$c" != "да" ] && [ "\$c" != "yes" ] && exit 0
  echo "Проверка..."; tar tzf "\${F[\$((n-1))]}" >/dev/null 2>&1 || { echo "Архив повреждён!"; exit 1; }
  echo "Бэкап текущего..."; docker stop homeassistant 2>/dev/null
  ts=\$(date +%Y%m%d_%H%M%S)
  tar czf "\${BD}/ha_pre_restore_\${ts}.tar.gz" -C "\$CONFIG_PARENT" "\$CONFIG_NAME" 2>/dev/null
  echo "Восстановление..."; tar xzf "\${F[\$((n-1))]}" -C "\$CONFIG_PARENT"
  docker start homeassistant 2>/dev/null; echo "Готово!"
fi
REOF

  chmod +x /usr/local/bin/ha-backup /usr/local/bin/ha-restore

  if [ "$OPT_REMOTE_BACKUP" = true ] && [ -n "$REMOTE_BACKUP_TARGET" ]; then
    cat > /usr/local/bin/ha-backup-remote << RBEOF
#!/bin/bash
REMOTE="${REMOTE_BACKUP_TARGET}"
BD="${HA_BACKUP_DIR}"

LATEST_FILE=""
if [ -d "/var/lib/homeassistant/backup" ]; then SNAPSHOT_DIR="/var/lib/homeassistant/backup"
elif [ -d "/usr/share/hassio/backup" ]; then SNAPSHOT_DIR="/usr/share/hassio/backup"
else SNAPSHOT_DIR="/usr/share/hassio/backups"; fi

if command -v ha &>/dev/null && command -v jq &>/dev/null; then
  LATEST_SLUG=\$(ha backups list 2>/dev/null | jq -r '.data.backups | sort_by(.date) | reverse | .[0].slug' 2>/dev/null)
  if [ -n "\$LATEST_SLUG" ]; then [ -f "\${SNAPSHOT_DIR}/\${LATEST_SLUG}.tar" ] && LATEST_FILE="\${SNAPSHOT_DIR}/\${LATEST_SLUG}.tar"; fi
fi
if [ -z "\$LATEST_FILE" ] && [ -d "\$SNAPSHOT_DIR" ]; then LATEST_FILE=\$(ls -1t "\${SNAPSHOT_DIR}"/*.tar 2>/dev/null | head -1); fi
if [ -z "\$LATEST_FILE" ]; then LATEST_FILE=\$(ls -1t "\$BD"/ha_config_*.tar.gz 2>/dev/null | head -1); fi

if [ -z "\$LATEST_FILE" ] || [ ! -f "\$LATEST_FILE" ]; then echo "Локальные бэкапы не найдены"; exit 1; fi
echo "Отправка бэкапа \$(basename "\$LATEST_FILE") в \$REMOTE ..."

case "\$REMOTE" in
  rclone://*)
    if ! command -v rclone &>/dev/null; then echo "ОШИБКА: rclone не установлен"; exit 1; fi
    RCLONE_TARGET="\${REMOTE#rclone://}"
    RCLONE_REMOTE="\${RCLONE_TARGET%%:*}"
    if ! rclone listremotes 2>/dev/null | grep -q "^\${RCLONE_REMOTE}:"; then
      echo "ОШИБКА: Профиль rclone '\${RCLONE_REMOTE}' не настроен! Выполните: sudo rclone config"
      /usr/local/bin/ha-notify "Удал. бэкап: rclone НЕ НАСТРОЕН (\$RCLONE_REMOTE)"; exit 1
    fi
    rclone copy "\$LATEST_FILE" "\$RCLONE_TARGET" --progress
    [ \$? -eq 0 ] && /usr/local/bin/ha-notify "Удал. бэкап (rclone) -> OK" || /usr/local/bin/ha-notify "Удал. бэкап (rclone) -> ОШИБКА" ;;
  ssh://*)
    rsync -avz --partial --progress -e "ssh -o StrictHostKeyChecking=no" "\$LATEST_FILE" "\${REMOTE#ssh://}"
    [ \$? -eq 0 ] && /usr/local/bin/ha-notify "Удал. бэкап (SSH rsync) -> OK" || /usr/local/bin/ha-notify "Удал. бэкап (SSH rsync) -> ОШИБКА" ;;
  *)
    /usr/local/bin/ha-notify "Удал. бэкап: неизвестный протокол (\$REMOTE)"; echo "Ошибка: Используйте префикс ssh:// или rclone://"; exit 1 ;;
esac
RBEOF
    chmod +x /usr/local/bin/ha-backup-remote
  fi

  # Установка rclone если нужен удаленный бэкап
  if [ "$OPT_REMOTE_BACKUP" = true ] && ! command -v rclone &>/dev/null; then
    msg_action "Установка rclone..."
    curl -fsSL https://rclone.org/install.sh 2>/dev/null | bash >/dev/null 2>&1 && msg_ok "rclone установлен" || msg_warn "Не удалось установить rclone"
  fi

  msg_ok "Система бэкапов"
}

# setup_: Генерация скрипта Prometheus метрик
setup_script_metrics() {
  mkdir -p "$METRICS_DIR"
  cat > /usr/local/bin/ha-metrics << 'S'
#!/bin/bash
OUT="/var/lib/prometheus/node-exporter/ha.prom"
mkdir -p "$(dirname "$OUT")"
{
  echo "# HELP ha_up Home Assistant availability"
  echo "# TYPE ha_up gauge"
  c=$(curl -s -o /dev/null -w "%{http_code}" -m 5 http://localhost:8123 2>/dev/null || echo 000)
  { [ "$c" = "200" ] || [ "$c" = "401" ]; } && echo "ha_up 1" || echo "ha_up 0"
  echo "# HELP ha_containers Running HA containers"
  echo "# TYPE ha_containers gauge"
  echo "ha_containers $(docker ps --filter 'label=io.hass.type' --format '{{.ID}}' 2>/dev/null | wc -l)"
  if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    echo "# HELP ha_cpu_temp CPU temperature"
    echo "# TYPE ha_cpu_temp gauge"
    echo "ha_cpu_temp $(($(cat /sys/class/thermal/thermal_zone0/temp)/1000))"
  fi
  echo "# HELP ha_disk_free_bytes Root free bytes"
  echo "# TYPE ha_disk_free_bytes gauge"
  echo "ha_disk_free_bytes $(df -B1 / | awk 'NR==2{print $4}')"
} > "${OUT}.tmp" && mv "${OUT}.tmp" "$OUT"
S
  chmod +x /usr/local/bin/ha-metrics
  msg_ok "Скрипт: Метрики Prometheus"
}

# setup_: Генерация скрипта и юнита восстановления загрузки
setup_script_boot_check() {
  cat > /usr/local/bin/ha-boot-check << 'S'
#!/bin/bash
sleep 30
dmesg | grep -qi "ext4.*error\|filesystem.*error" && \
  /usr/local/bin/ha-notify "Ошибки ФС после загрузки!"
docker info &>/dev/null || { systemctl restart docker; sleep 10; }
systemctl is-active --quiet hassio-supervisor || {
  systemctl restart hassio-supervisor
  /usr/local/bin/ha-notify "Supervisor перезапущен после загрузки"
}
S
  chmod +x /usr/local/bin/ha-boot-check

  cat > /etc/systemd/system/ha-boot-check.service << 'UNIT'
[Unit]
Description=HA проверка после загрузки
After=docker.service hassio-supervisor.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ha-boot-check
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
  systemctl enable ha-boot-check 2>/dev/null || true
  msg_ok "Скрипт: Восстановление загрузки"
}

# ============================================================================
# ШАГ: УТИЛИТЫ
# ============================================================================
step_extras() {
  local sid="extras"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] УТИЛИТЫ"

  # 1. Хост и mDNS
  configure_hostname_avahi

  # 2. Секреты и базовые утилиты
  setup_ha_secrets
  setup_script_notify

  # 3. Опциональные утилиты
  [ "$OPT_WATCHDOG" = true ]      && setup_script_watchdog
  [ "$OPT_THERMAL" = true ]       && setup_script_thermal
  [ "$OPT_BACKUP" = true ]        && setup_script_backups
  [ "$OPT_MONITORING" = true ]    && setup_script_metrics
  [ "$OPT_BOOT_RECOVERY" = true ] && setup_script_boot_check

  # Базовые скрипты здоровья (ставим всегда)
  setup_script_health

  # 4. VPN и Туннели
  if [ "$OPT_TAILSCALE" = true ]; then
    msg_action "Настройка Tailscale VPN..."
    if [ -n "${TS_AUTHKEY}" ]; then
      mkdir -p "${HA_INSTALLER_DIR}/secrets"; printf '%s' "${TS_AUTHKEY}" > "${HA_INSTALLER_DIR}/secrets/ts_authkey"; chmod 600 "${HA_INSTALLER_DIR}/secrets/ts_authkey"
    fi
    install_tailscale; configure_tailscale_ufw; apply_wifi_powersave_fix
    local ts_key="${TS_AUTHKEY}"
    [ -z "$ts_key" ] && [ -f "${HA_INSTALLER_DIR}/secrets/ts_authkey" ] && ts_key=$(cat "${HA_INSTALLER_DIR}/secrets/ts_authkey" | tr -d '[:space:]')
    auth_tailscale "$ts_key"
  fi

  if [ "$OPT_CLOUDFLARED" = true ]; then
    msg_action "Настройка Cloudflare Tunnel..."
    if [ -n "${CF_TUNNEL_TOKEN}" ]; then
      mkdir -p "${HA_INSTALLER_DIR}/secrets"; printf '%s' "${CF_TUNNEL_TOKEN}" > "${HA_INSTALLER_DIR}/secrets/cf_token"; chmod 600 "${HA_INSTALLER_DIR}/secrets/cf_token"
    fi
    install_cloudflared
    if command -v cloudflared &>/dev/null; then
      local cf_token="${CF_TUNNEL_TOKEN}"
      [ -z "$cf_token" ] && [ -f "${HA_INSTALLER_DIR}/secrets/cf_token" ] && cf_token=$(cat "${HA_INSTALLER_DIR}/secrets/cf_token" | tr -d '[:space:]')
      configure_cloudflare_tunnel "$cf_token"
    fi
  fi

  # 5. Поиск USB
  detect_usb_dongles

  # 6. Настройка Cron
  configure_cron

  mark_done "$sid"
}

# ============================================================================
# WAIT: Ожидание готовности HA
# ============================================================================

# wait_: Ожидание запуска контейнера homeassistant
wait_ha_core_container() {
  local to="${1:-1200}" el=0
  msg_action "Ожидание контейнера homeassistant..."
  while ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^homeassistant$'; do
    sleep 10; el=$((el+10))
    [ $((el%60)) -eq 0 ] && msg_dim "Ожидание контейнера... ${el}с"
    [ $el -ge $to ] && { msg_warn "Контейнер не появился за $((to/60)) мин."; return 1; }
  done
  msg_ok "Контейнер homeassistant запущен"
  return 0
}

# wait_: Ожидание создания configuration.yaml внутри контейнера
wait_ha_config_init() {
  local to="${1:-600}" el=0
  msg_action "Ожидание инициализации HA..."
  while ! docker exec homeassistant ls /config/configuration.yaml &>/dev/null; do
    sleep 10; el=$((el+10))
    [ $((el%60)) -eq 0 ] && msg_dim "Ожидание /config/... ${el}с"
    [ $el -ge $to ] && { msg_warn "configuration.yaml не появился за $((to/60)) мин."; return 1; }
  done
  msg_ok "HA инициализирован"
  return 0
}

# ============================================================================
# CONFIGURE: Настройка среды для HACS
# ============================================================================

# Исправление DNS внутри контейнера при необходимости
configure_docker_dns() {
  if ! docker exec homeassistant wget -q --spider --timeout=5 https://github.com 2>/dev/null && \
     ! docker exec homeassistant python3 -c "import urllib.request; urllib.request.urlopen('https://github.com', timeout=5)" 2>/dev/null; then
    msg_warn "DNS не работает внутри контейнера, исправление..."
    mkdir -p /etc/docker
    if [ -f /etc/docker/daemon.json ] && command -v jq &>/dev/null; then
      jq '. + {"dns": ["8.8.8.8", "1.1.1.1"]}' /etc/docker/daemon.json > /tmp/dj.tmp 2>/dev/null && \
        mv /tmp/dj.tmp /etc/docker/daemon.json
    elif [ ! -f /etc/docker/daemon.json ]; then
      echo '{"log-driver":"journald","storage-driver":"overlay2","dns":["8.8.8.8","1.1.1.1"]}' > /etc/docker/daemon.json
    else
      msg_dim "jq не установлен — DNS в daemon.json не добавлен"
    fi
    systemctl restart docker 2>/dev/null || true
    
    # Ждём контейнер после рестарта Docker
    local dw=0
    while ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^homeassistant$'; do
      sleep 5; dw=$((dw+5)); [ $dw -gt 120 ] && break
    done
    sleep 15
    # Повторная проверка DNS
    docker exec homeassistant ping -c1 -W5 github.com &>/dev/null && msg_ok "DNS исправлен" || msg_warn "DNS всё ещё не работает"
  fi
}

# ============================================================================
# INSTALL: Установка HACS
# ============================================================================

# Попытка установки HACS (3 способа с таймаутами)
install_hacs() {
  msg_action "Установка HACS..."
  local hacs_ok=false

  # Способ 1: wget внутри контейнера
  if [ "$hacs_ok" = false ] && docker exec homeassistant which wget &>/dev/null; then
    msg_dim "Способ 1: wget..."
    docker exec homeassistant bash -c "wget -q -O- https://get.hacs.xyz | bash -" >/dev/null 2>&1 &
    local hp=$! hw=0
    while kill -0 "$hp" 2>/dev/null; do
      sleep 5; hw=$((hw + 5))
      if [ $hw -ge 180 ]; then
        kill "$hp" 2>/dev/null || true
        docker exec homeassistant bash -c "if command -v pkill >/dev/null 2>&1; then pkill -f 'get.hacs.xyz' 2>/dev/null || true; pkill wget 2>/dev/null || true; fi; if command -v ps >/dev/null 2>&1; then ps aux 2>/dev/null | grep -E 'get.hacs|wget' | grep -v grep | awk '{print \$2}' | xargs -r kill 2>/dev/null || true; fi" 2>/dev/null || true
        break
      fi
    done
    wait "$hp" 2>/dev/null && hacs_ok=true || true
  fi

  # Способ 2: curl внутри контейнера
  if [ "$hacs_ok" = false ] && docker exec homeassistant which curl &>/dev/null; then
    msg_dim "Способ 2: curl..."
    docker exec homeassistant bash -c "curl -fsSL https://get.hacs.xyz | bash -" >/dev/null 2>&1 &
    local hp=$! hw=0
    while kill -0 "$hp" 2>/dev/null; do
      sleep 5; hw=$((hw + 5))
      if [ $hw -ge 180 ]; then
        kill "$hp" 2>/dev/null || true
        docker exec homeassistant bash -c "if command -v pkill >/dev/null 2>&1; then pkill -f 'get.hacs.xyz' 2>/dev/null || true; pkill curl 2>/dev/null || true; fi; if command -v ps >/dev/null 2>&1; then ps aux 2>/dev/null | grep -E 'get.hacs|curl' | grep -v grep | awk '{print \$2}' | xargs -r kill 2>/dev/null || true; fi" 2>/dev/null || true
        break
      fi
    done
    wait "$hp" 2>/dev/null && hacs_ok=true || true
  fi

  # Способ 3: скачать на хост и скопировать
  if [ "$hacs_ok" = false ]; then
    msg_dim "Способ 3: загрузка на хост..."
    local hacs_zip="/tmp/hacs.zip"
    if wget -q -O "$hacs_zip" "https://github.com/hacs/integration/releases/latest/download/hacs.zip" 2>/dev/null && [ -s "$hacs_zip" ]; then
      docker exec homeassistant mkdir -p /config/custom_components 2>/dev/null
      docker cp "$hacs_zip" homeassistant:/tmp/hacs.zip 2>/dev/null
      if docker exec homeassistant bash -c "cd /config/custom_components && python3 -m zipfile -e /tmp/hacs.zip . && rm -f /tmp/hacs.zip" 2>/dev/null; then
        hacs_ok=true
      elif docker exec homeassistant bash -c "cd /config/custom_components && unzip -o /tmp/hacs.zip && rm -f /tmp/hacs.zip" 2>/dev/null; then
        hacs_ok=true
      fi
      rm -f "$hacs_zip"
    fi
  fi

  # Финальная проверка и перезапуск контейнера
  if [ "$hacs_ok" = true ] && docker exec homeassistant ls /config/custom_components/hacs &>/dev/null; then
    docker restart homeassistant >/dev/null 2>&1
    return 0
  else
    return 1
  fi
}

# ============================================================================
# ШАГ: HACS
# ============================================================================
step_hacs() {
  local sid="hacs"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] HACS"

  if [ "$OPT_HACS" != true ]; then
    msg_warn "Пропущен"
    mark_done "$sid"
    return 0
  fi

  msg_dim "HACS: внешний код с https://get.hacs.xyz"

  # 1. Ожидание контейнера
  if ! wait_ha_core_container 1200; then
    msg_dim "Установите HACS позже: docker exec homeassistant bash -c 'wget -qO- https://get.hacs.xyz|bash -'"
    mark_done "$sid"
    return 0
  fi

  # 2. Ожидание инициализации
  if ! wait_ha_config_init 600; then
    msg_dim "Установите HACS позже вручную."
    mark_done "$sid"
    return 0
  fi

  # 3. Проверка и исправление DNS
  configure_docker_dns

  # 4. Установка
  if install_hacs; then
    msg_ok "HACS установлен!"
    separator
    msg_info "Для активации HACS:"
    msg_info "1. Откройте http://IP:8123 и пройдите первичную настройку HA"
    msg_info "2. Настройки -> Устройства и службы -> Добавить интеграцию"
    msg_info "3. Найдите 'HACS' и авторизуйтесь через GitHub"
    separator
  else
    msg_warn "HACS: автоустановка не удалась"
    separator
    msg_info "Установите вручную после настройки HA:"
    msg_info "  docker exec homeassistant bash -c 'wget -qO- https://get.hacs.xyz|bash -'"
    msg_info "  docker restart homeassistant"
    separator
  fi

  mark_done "$sid"
}

# ============================================================================
# ШАГ: ВОССТАНОВЛЕНИЕ БЭКАПА
# ============================================================================
step_post_restore() {
  local sid="postrestore"; is_done "$sid" && return 0

  if [ -z "$OPT_RESTORE_BACKUP" ]; then
    mark_done "$sid"
    return 0
  fi

  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] ВОССТАНОВЛЕНИЕ БЭКАПА"

  if [ ! -f "$OPT_RESTORE_BACKUP" ]; then
    msg_error "Файл не найден: ${OPT_RESTORE_BACKUP}"
    mark_done "$sid"
    return 1
  fi

  msg_action "Проверка архива..."
  tar tzf "$OPT_RESTORE_BACKUP" >/dev/null 2>&1 || {
    msg_error "Архив повреждён!"
    mark_done "$sid"
    return 1
  }

  msg_action "Ожидание готовности HA..."
  wait_ha_ready 600 || { msg_warn "HA не готов, восстановление пропущено"; mark_done "$sid"; return 0; }

  local cw=0
  while ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^homeassistant$'; do
    sleep 5; cw=$((cw+5))
    [ $cw -gt 120 ] && break
  done

  msg_action "Остановка HA..."
  docker stop homeassistant 2>/dev/null || true
  sleep 3

  msg_action "Восстановление: $(basename "$OPT_RESTORE_BACKUP")..."
  if tar xzf "$OPT_RESTORE_BACKUP" -C "$HASSIO_DIR" 2>/dev/null; then
    msg_ok "Бэкап восстановлен"
    docker start homeassistant 2>/dev/null
    send_notification "Восстановлено: $(basename "$OPT_RESTORE_BACKUP")"
  else
    msg_error "Восстановление не удалось"
    docker start homeassistant 2>/dev/null
  fi

  mark_done "$sid"
}

# ============================================================================
# ОПЕРАЦИИ: ДИАГНОСТИКА
# ============================================================================
do_check() {
  header "ДИАГНОСТИКА"
  detect_system_info
  local ip t
  ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="?"
  t=$(get_cpu_temp)

  echo -e "   ${BOLD}Система${NC}"
  msg_info "Хост: $(hostname 2>/dev/null)  IP: ${ip}  ОС: ${CACHED_PRETTY_NAME}"
  [ -n "$t" ] && msg_info "CPU: ${t}C"
  [ -n "$OPT_TIMEZONE" ] && msg_info "Часовой пояс: ${OPT_TIMEZONE}"
  [ -n "$OPT_DATA_DIR" ] && msg_info "Данные: ${OPT_DATA_DIR}"
  separator

  echo -e "   ${BOLD}Компоненты${NC}"
  command -v docker &>/dev/null && \
    msg_ok "Docker: $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')" || msg_error "Docker: нет"

  local hs; hs=$(systemctl is-active hassio-supervisor 2>/dev/null) || hs="нет"
  [ "$hs" = "active" ] && msg_ok "Supervisor: ${hs}" || msg_error "Supervisor: ${hs}"

  docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^homeassistant$' \
    && msg_ok "HA Core: $(docker inspect -f '{{.State.Status}}' homeassistant 2>/dev/null)" \
    || msg_error "HA Core: нет"

  [ -f "$FAKED_OS_RELEASE" ] && msg_info "os-release: подменён" || msg_info "os-release: оригинал"

  separator
  verify_installed_scripts
  show_progress
  echo ""
}

# ============================================================================
# APPLY: Разовые фиксы среды (Rescue Mode)
# ============================================================================

# Проверка и фикс файловой системы
apply_rescue_filesystem() {
  msg_action "[1/8] Файловая система..."
  if ! touch /tmp/.ha_rescue_test 2>/dev/null; then
    msg_error "Файловая система readonly!"
    msg_dim "Попытка: mount -o remount,rw /"
    mount -o remount,rw / 2>/dev/null || true
    if touch /tmp/.ha_rescue_test 2>/dev/null; then
      msg_ok "ФС перемонтирована в rw"; rm -f /tmp/.ha_rescue_test; return 2
    else
      rm -f /tmp/.ha_rescue_test 2>/dev/null; msg_error "Не удалось перемонтировать ФС"; return 1
    fi
  fi
  rm -f /tmp/.ha_rescue_test 2>/dev/null
  if dmesg 2>/dev/null | tail -200 | grep -qi "ext4.*error\|I/O error"; then
    msg_warn "Ошибки ФС в dmesg!"; msg_dim "Рекомендуется: fsck после загрузки с USB"; return 1
  fi
  msg_ok "ФС: OK (rw)"; return 0
}

# Проверка и очистка места на диске
apply_rescue_disk_space() {
  msg_action "[2/8] Место на диске..."
  local avail; avail=$(df -m / | awk 'NR==2{print $4}')
  if [ "${avail:-0}" -lt 500 ]; then
    msg_error "Критически мало места: ${avail}МБ"; msg_action "Экстренная очистка..."
    journalctl --vacuum-size=20M 2>/dev/null || true; apt-get clean 2>/dev/null || true
    command -v docker &>/dev/null && docker system prune -f 2>/dev/null || true
    find /tmp -type f -mtime +1 -delete 2>/dev/null || true
    local log_count; log_count=$(ls /var/log/ha_install_*.log 2>/dev/null | wc -l)
    [ "${log_count:-0}" -gt 3 ] && ls -1t /var/log/ha_install_*.log 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null
    local after; after=$(df -m / | awk 'NR==2{print $4}')
    msg_ok "Освобождено: ${avail}МБ → ${after}МБ"; return 2
  fi
  msg_ok "Диск: ${avail}МБ свободно"; return 0
}

# Проверка и восстановление сети
apply_rescue_network() {
  msg_action "[3/8] Сеть..."
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  if [ -z "$ip" ]; then
    msg_error "Нет IP-адреса!"; msg_action "Восстановление сети..."
    if command -v nmcli &>/dev/null; then systemctl restart NetworkManager 2>/dev/null || true; sleep 5; ip=$(hostname -I 2>/dev/null | awk '{print $1}'); fi
    if [ -z "$ip" ]; then
      local iface; iface=$(ip -o link show 2>/dev/null | awk -F': ' '!/lo/{print $2; exit}' | cut -d'@' -f1)
      if [ -n "$iface" ]; then
        ip link set "$iface" up 2>/dev/null || true
        if command -v dhclient &>/dev/null; then dhclient "$iface" 2>/dev/null || true
        elif command -v udhcpc &>/dev/null; then udhcpc -i "$iface" -q 2>/dev/null || true; fi
        sleep 5; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
      fi
    fi
    if [ -z "$ip" ]; then systemctl restart systemd-networkd 2>/dev/null || true; sleep 5; ip=$(hostname -I 2>/dev/null | awk '{print $1}'); fi
    if [ -n "$ip" ]; then msg_ok "Сеть восстановлена: ${ip}"; return 2
    else msg_error "Не удалось восстановить сеть"; return 1; fi
  fi
  msg_ok "Сеть: ${ip}"; return 0
}

# Проверка и фикс DNS
apply_rescue_dns() {
  msg_action "[4/8] DNS..."
  if ! ping -c1 -W3 github.com &>/dev/null; then
    if ping -c1 -W2 8.8.8.8 &>/dev/null; then
      msg_warn "DNS не работает, исправление..."
      if [ -s /etc/resolv.conf ] && grep -q "nameserver" /etc/resolv.conf 2>/dev/null; then
        cp /etc/resolv.conf /etc/resolv.conf.rescue.bak 2>/dev/null
      fi
      rm -f /etc/resolv.conf 2>/dev/null; echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf; sleep 2
      if ping -c1 -W3 github.com &>/dev/null; then msg_ok "DNS исправлен"; return 2
      else msg_error "DNS всё ещё не работает"; return 1; fi
    else
      local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
      if [ -z "$ip" ]; then msg_error "Нет сети — DNS не проверить"; else msg_error "Нет доступа к интернету"; fi
      return 1
    fi
  fi
  msg_ok "DNS: OK"; return 0
}

# Проверка и перезапуск Docker
apply_rescue_docker() {
  msg_action "[5/8] Docker..."
  if command -v docker &>/dev/null; then
    if ! docker info &>/dev/null; then
      msg_warn "Docker не отвечает"; msg_action "Перезапуск Docker..."
      systemctl restart docker 2>/dev/null || true
      local dw=0; while ! docker info &>/dev/null && [ $dw -lt 30 ]; do sleep 3; dw=$((dw+3)); done
      if docker info &>/dev/null; then msg_ok "Docker восстановлен"; return 2
      else msg_error "Docker не запускается"; msg_dim "Логи: journalctl -u docker -n 20"; return 1; fi
    fi
    local drv; drv=$(docker info --format '{{.Driver}}' 2>/dev/null || echo "?"); msg_ok "Docker: OK (${drv})"; return 0
  fi
  msg_error "Docker не установлен"; return 1
}

# Проверка и перезапуск Supervisor
apply_rescue_supervisor() {
  msg_action "[6/8] Supervisor..."
  if systemctl list-unit-files hassio-supervisor.service &>/dev/null; then
    if ! systemctl is-active --quiet hassio-supervisor 2>/dev/null; then
      msg_warn "Supervisor не работает"; msg_action "Перезапуск Supervisor..."
      if [ -f "$FAKED_OS_RELEASE" ]; then cp "$FAKED_OS_RELEASE" /etc/os-release 2>/dev/null; msg_dim "os-release подменён для supervisor"; fi
      systemctl restart hassio-supervisor 2>/dev/null || true; sleep 15
      if systemctl is-active --quiet hassio-supervisor 2>/dev/null; then msg_ok "Supervisor восстановлен"; return 2
      else msg_error "Supervisor не запускается"; msg_dim "Логи: journalctl -u hassio-supervisor -n 30"; return 1; fi
    fi
    msg_ok "Supervisor: active"; return 0
  fi
  msg_warn "Supervisor не установлен"; return 0
}

# Проверка и запуск контейнера HA Core
apply_rescue_ha_core() {
  msg_action "[7/8] HA Core..."
  if command -v docker &>/dev/null && docker info &>/dev/null; then
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^homeassistant$'; then
      msg_warn "HA Core не запущен"
      if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^homeassistant$'; then
        msg_action "Запуск контейнера..."; docker start homeassistant 2>/dev/null || true; sleep 10
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^homeassistant$'; then msg_ok "HA Core запущен"; return 2
        else msg_error "HA Core не запускается"; msg_dim "Логи: docker logs homeassistant --tail 30"; return 1; fi
      else
        msg_warn "Контейнер homeassistant не существует"; msg_dim "Supervisor должен создать его автоматически"
        systemctl restart hassio-supervisor 2>/dev/null || true; return 1
      fi
    fi
    local ha_status; ha_status=$(docker inspect -f '{{.State.Status}}' homeassistant 2>/dev/null || echo "?")
    msg_ok "HA Core: ${ha_status}"
    local hc; hc=$(curl -s -o /dev/null -w "%{http_code}" -m 5 http://localhost:8123 2>/dev/null || echo 000)
    if [ "$hc" = "200" ] || [ "$hc" = "401" ]; then msg_ok "HA Web: OK (${hc})"
    elif [ "$hc" = "000" ]; then msg_dim "HA Web: загружается (это нормально первые 10-15 минут)"
    else msg_warn "HA Web: ${hc}"; fi
    return 0
  fi
  return 1
}

# Проверка AppArmor
apply_rescue_apparmor() {
  msg_action "[8/8] AppArmor..."
  local aa; aa=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) || aa="N"
  if [ "$aa" = "Y" ]; then
    msg_ok "AppArmor: активен"
    if ! systemctl is-active --quiet apparmor 2>/dev/null; then systemctl start apparmor 2>/dev/null || true; msg_dim "Сервис apparmor запущен"; return 2; fi
    return 0
  else
    msg_warn "AppArmor: не активен в ядре"; msg_dim "Для активации: добавьте 'apparmor=1 security=apparmor' в загрузчик и перезагрузите"; return 1
  fi
}

# =========================================================================
# ОПЕРАЦИИ: РЕЖИМ ВОССТАНОВЛЕНИЯ
# =========================================================================
do_rescue() {
    header "РЕЖИМ ВОССТАНОВЛЕНИЯ"
    local fixes=0 errors=0

    # Запускаем функции спасения и анализируем код возврата
    # 0 = OK, 2 = Fixed, 1 = Error
    
    apply_rescue_filesystem;   local rc=$?; [ $rc -eq 2 ] && fixes=$((fixes+1)); [ $rc -eq 1 ] && errors=$((errors+1))
    apply_rescue_disk_space;   local rc=$?; [ $rc -eq 2 ] && fixes=$((fixes+1)); [ $rc -eq 1 ] && errors=$((errors+1))
    apply_rescue_network;      local rc=$?; [ $rc -eq 2 ] && fixes=$((fixes+1)); [ $rc -eq 1 ] && errors=$((errors+1))
    apply_rescue_dns;          local rc=$?; [ $rc -eq 2 ] && fixes=$((fixes+1)); [ $rc -eq 1 ] && errors=$((errors+1))
    apply_rescue_docker;       local rc=$?; [ $rc -eq 2 ] && fixes=$((fixes+1)); [ $rc -eq 1 ] && errors=$((errors+1))
    apply_rescue_supervisor;   local rc=$?; [ $rc -eq 2 ] && fixes=$((fixes+1)); [ $rc -eq 1 ] && errors=$((errors+1))
    apply_rescue_ha_core;      local rc=$?; [ $rc -eq 2 ] && fixes=$((fixes+1)); [ $rc -eq 1 ] && errors=$((errors+1))
    apply_rescue_apparmor;     local rc=$?; [ $rc -eq 2 ] && fixes=$((fixes+1)); [ $rc -eq 1 ] && errors=$((errors+1))

    # === ИТОГ ===
    separator
    echo ""
    if [ $errors -eq 0 ] && [ $fixes -eq 0 ]; then
        msg_ok "Все проверки пройдены, проблем не обнаружено"
    elif [ $errors -eq 0 ]; then
        msg_ok "Исправлено проблем: ${fixes}"
    else
        msg_warn "Исправлено: ${fixes}, не удалось: ${errors}"
    fi

    echo ""
    msg_info "Дополнительная диагностика:"
    msg_dim "  sudo hassify --check                 Полная проверка"
    msg_dim "  sudo hassify --status                Мониторинг (live)"
    msg_dim "  journalctl -u hassio-supervisor -n 50   Логи Supervisor"
    msg_dim "  docker logs homeassistant --tail 50     Логи HA"
    msg_dim "  dmesg | tail -50                        Системные ошибки"
    echo ""

    # Отправить уведомление о результате
    if [ $fixes -gt 0 ] || [ $errors -gt 0 ]; then
        send_notification "Rescue: исправлено ${fixes}, ошибок ${errors}"
    fi
}

# ============================================================================
# ОПЕРАЦИИ: МОНИТОРИНГ (live)
# ============================================================================
do_status() {
  # Тяжёлые данные (curl к HA, hostname -I) кэшируем — обновляем раз в 30с.
  # Лёгкие данные (температура, RAM, uptime) обновляем каждые 5с.
  local ip=""
  local hc="000"
  local cache_tick=0
  # 6 итераций × 5с = 30с между тяжёлыми запросами
  local cache_interval=6

  # Обработка Ctrl+C — выходим чисто без мусора в терминале.
  # После return восстанавливаем глобальный обработчик INT.
  trap 'echo ""; echo -e " ${WARN} Мониторинг остановлен"; trap handle_interrupt INT; return 0' INT

  # Первичное получение тяжёлых данных до начала цикла
  ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="?"
  hc=$(curl -s -o /dev/null -w "%{http_code}" \
    -m 3 http://localhost:8123 2>/dev/null || echo 000)
  hc="${hc:-000}"

  while true; do

    # Обновляем тяжёлые данные раз в 30с
    if [ "$cache_tick" -eq 0 ]; then
      ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="?"
      hc=$(curl -s -o /dev/null -w "%{http_code}" \
        -m 3 http://localhost:8123 2>/dev/null || echo 000)
      hc="${hc:-000}"
    fi
    cache_tick=$(( (cache_tick + 1) % cache_interval ))

    clear

    # Ширина терминала: минимум 40, максимум 80 символов
    local cols
    cols=$(tput cols 2>/dev/null || echo 70)
    [ "$cols" -gt 80 ] && cols=80
    [ "$cols" -lt 40 ] && cols=40
    local sep
    sep=$(printf '%*s' "$cols" '' | tr ' ' '-')

    # Шапка — без show_banner (он делает curl и clear внутри)
    echo -e "${BLUE}${sep}${NC}"
    echo -e "${WHITE}${BOLD}  Hassify v${SCRIPT_VERSION} — Мониторинг${NC}"
    echo -e "${BLUE}${sep}${NC}"

    # Лёгкие данные — обновляются каждые 5с
    local t
    t=$(get_cpu_temp)
    printf "  ${BOLD}%-10s${NC} %s\n" "IP:"       "${ip:-?}"
    printf "  ${BOLD}%-10s${NC} %s\n" "Работает:" \
      "$(uptime -p 2>/dev/null || echo '?')"
    [ -n "$t" ] && \
      printf "  ${BOLD}%-10s${NC} %sC\n" "CPU:" "$t"
    printf "  ${BOLD}%-10s${NC} %s\n" "RAM:" \
      "$(free -h | awk '/Mem:/{printf "%s/%s",$3,$2}')"
    printf "  ${BOLD}%-10s${NC} %s\n" "Swap:" \
      "$(free -h | awk '/Swap:/{printf "%s/%s",$3,$2}')"

    echo -e "${DIM}${sep}${NC}"
    echo -e "  ${BOLD}Контейнеры:${NC}"

    # Читаем вывод docker ps в переменную — избегаем subshell от pipeline.
    # При pipeline (docker ps | while) изменения переменных внутри цикла
    # не видны снаружи, и вывод может буферизоваться иначе.
    local containers_out
    containers_out=$(docker ps \
      --format '{{.Names}}|{{.Status}}' 2>/dev/null)

    if [ -z "$containers_out" ]; then
      echo -e "  ${CROSS} Контейнеры не запущены"
    else
      # Читаем из переменной через herestring — без subshell
      while IFS='|' read -r n s; do
        [ -z "$n" ] && continue
        if echo "$s" | grep -q "^Up"; then
          echo -e "  ${CHECK} ${n} ${DIM}${s}${NC}"
        else
          echo -e "  ${CROSS} ${RED}${n}${NC} ${DIM}${s}${NC}"
        fi
      done <<< "$containers_out"
    fi

    echo -e "${DIM}${sep}${NC}"

    # Статус HA Web из кэша — не делаем curl каждые 5с
    if [ "$hc" = "200" ] || [ "$hc" = "401" ]; then
      echo -e "  ${CHECK} HA Web: ${GREEN}OK (${hc})${NC}  →  http://${ip}:8123"
    elif [ "$hc" = "000" ]; then
      echo -e "  ${CROSS} HA Web: ${RED}недоступен${NC}"
    else
      echo -e "  ${WARN}  HA Web: ${YELLOW}${hc}${NC}"
    fi

    echo -e "\n  ${DIM}$(date '+%H:%M:%S') | Ctrl+C для выхода | обновление каждые 5с${NC}"
    sleep 5
  done
}

# ============================================================================
# APPLY: Откат среды и удаление файлов (Uninstall)
# ============================================================================

# Остановка и удаление служб HA
apply_ha_services_stop() {
  msg_action "Остановка сервисов..."
  systemctl stop hassio-supervisor hassio-apparmor 2>/dev/null || true
  for svc in hassio-supervisor hassio-apparmor ha-boot-check "${REBOOT_CONTINUE_SVC}"; do
    systemctl disable "$svc" 2>/dev/null
    systemctl stop "$svc" 2>/dev/null
    rm -f "/etc/systemd/system/${svc}.service"
  done
  rm -rf /etc/systemd/system/hassio-supervisor.service.d
  systemctl daemon-reload 2>/dev/null || true
  msg_ok "Сервисы HA остановлены и удалены"
}

# Очистка контейнеров, образов и томов Docker
apply_ha_docker_cleanup() {
  if ! command -v docker &>/dev/null; then return 0; fi
  msg_action "Удаление компонентов Docker HA..."
  
  # Контейнеры
  docker ps -a --filter "label=io.hass.type" --format '{{.Names}}' 2>/dev/null | while IFS= read -r c; do docker rm -f "$c" 2>/dev/null; done
  for c in homeassistant hassio_supervisor hassio_cli hassio_audio hassio_dns hassio_multicast hassio_observer; do
    docker rm -f "$c" 2>/dev/null || true
  done

  # Образы
  docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -iE "homeassistant|hassio|home-assistant" | while IFS= read -r i; do docker rmi -f "$i" 2>/dev/null; done

  # Тома (явные + dangling с конфигами HA)
  docker volume ls --format '{{.Name}}' 2>/dev/null | grep -iE "hassio|homeassistant|home.assistant" | while IFS= read -r v; do docker volume rm -f "$v" 2>/dev/null; done
  local mp="" dangling_volumes=()
  mapfile -t dangling_volumes < <(docker volume ls -f dangling=true --format '{{.Name}}' 2>/dev/null)
  for v in "${dangling_volumes[@]}"; do
    [ -z "$v" ] && continue
    mp=$(docker volume inspect "$v" --format '{{.Mountpoint}}' 2>/dev/null) || continue
    if [ -n "$mp" ] && [ -d "$mp" ] && ls "$mp" 2>/dev/null | grep -qiE "hassio|homeassistant|configuration.yaml"; then
      docker volume rm -f "$v" 2>/dev/null && msg_dim "Удалён volume: ${v}"
    fi
  done

  # Сети
  docker network ls --format '{{.Name}}' 2>/dev/null | grep -iE "hassio|homeassistant|supervisor" | while IFS= read -r n; do docker network rm "$n" 2>/dev/null || true; done
  msg_ok "Компоненты Docker HA удалены"
}

# Удаление deb-пакетов
apply_ha_packages_purge() {
  msg_action "Удаление пакетов HA..."
  dpkg --purge homeassistant-supervised os-agent 2>/dev/null || true
  msg_ok "Пакеты HA удалены"
}

# Удаление скриптов и конфигов установщика
apply_ha_files_cleanup() {
  msg_action "Удаление скриптов и конфигов..."
  rm -f /usr/local/bin/ha-notify /usr/local/bin/ha-watchdog /usr/local/bin/ha-cleanup \
    /usr/local/bin/ha-net-recovery /usr/local/bin/ha-backup /usr/local/bin/ha-restore \
    /usr/local/bin/ha-health /usr/local/bin/ha-thermal /usr/local/bin/ha-metrics \
    /usr/local/bin/ha-boot-check /usr/local/bin/ha-backup-remote /usr/local/bin/ha-weekly-report \
    /usr/local/bin/ha-update-check "$SAFE_SCRIPT_PATH" "$HA_INFO_FILE" 2>/dev/null

  rm -f /etc/cron.d/ha-tools /etc/udev/rules.d/99-ha-usb-power.rules \
    /etc/ssh/sshd_config.d/99-ha-hardening.conf /etc/sysctl.d/99-ha-swap.conf \
    /etc/systemd/journald.conf.d/ha-tuning.conf \
    /etc/NetworkManager/conf.d/10-ha-managed.conf /etc/NetworkManager/conf.d/10-dns-resolved.conf 2>/dev/null

  rm -f /etc/default/zramswap 2>/dev/null; rm -rf /etc/systemd/zram-generator.conf.d 2>/dev/null
  rm -f /etc/apt/apt.conf.d/50unattended-upgrades /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null
  rm -f /etc/fail2ban/jail.local 2>/dev/null; systemctl restart fail2ban 2>/dev/null || true

  if [ -f /etc/ufw/after.rules ]; then
    sed -i '/# BEGIN HA-INSTALLER DOCKER-USER/,/# END HA-INSTALLER DOCKER-USER/d' /etc/ufw/after.rules 2>/dev/null
    ufw reload 2>/dev/null || true
  fi
  
  rm -f /var/lib/prometheus/node-exporter/ha.prom 2>/dev/null
  apply_os_release_restore
  rm -f "$FAKED_OS_RELEASE" 2>/dev/null
  msg_ok "Файлы и конфиги очищены"
}

# Удаление Tailscale и Cloudflared
apply_vpn_cleanup() {
  if command -v tailscale &>/dev/null; then
    tailscale down >/dev/null 2>&1 || true; apt-get purge -y tailscale >/dev/null 2>&1 || true
    rm -f /etc/apt/sources.list.d/tailscale.list
    if command -v ufw &>/dev/null && ufw status | grep -q "status: active"; then
      ufw delete allow in on tailscale0 >/dev/null 2>&1 || true; ufw delete allow 41641/udp >/dev/null 2>&1 || true; ufw reload >/dev/null 2>&1 || true
    fi
    rm -f "${HA_INSTALLER_DIR}/secrets/ts_authkey" 2>/dev/null || true
  fi
  if command -v cloudflared &>/dev/null; then
    cloudflared service uninstall >/dev/null 2>&1 || true; rm -f /usr/local/bin/cloudflared /etc/systemd/system/cloudflared.service "${HA_INSTALLER_DIR}/secrets/cf_token" 2>/dev/null || true
  fi
}

# Полное удаление Docker CE (только для Full Mode)
apply_docker_ce_purge() {
  msg_action "Удаление Docker CE..."
  systemctl stop docker docker.socket containerd 2>/dev/null || true
  systemctl disable docker docker.socket containerd 2>/dev/null || true
  apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
  apt-get autoremove -y 2>/dev/null || true
  rm -rf /var/lib/docker /var/lib/containerd /etc/docker 2>/dev/null
  rm -f /etc/docker/daemon.json /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc 2>/dev/null
  msg_ok "Docker CE удалён"
}

# Очистка AppArmor из загрузчика (только для Full Mode)
apply_bootloader_apparmor_restore() {
  msg_action "Очистка AppArmor из загрузчика..."
  detect_boot_dir
  local boot_files=()
  [ -f "${BOOT_DIR}/armbianEnv.txt" ] && boot_files+=("${BOOT_DIR}/armbianEnv.txt")
  [ -f "${BOOT_DIR}/uEnv.txt" ] && boot_files+=("${BOOT_DIR}/uEnv.txt")
  [ -f "${BOOT_DIR}/extlinux/extlinux.conf" ] && boot_files+=("${BOOT_DIR}/extlinux/extlinux.conf")
  for f in "${boot_files[@]}"; do
    [ -f "$f" ] || continue
    if grep -q "apparmor=1" "$f" 2>/dev/null; then
      local bak="${BACKUP_DIR}/$(basename "$f").bak"
      if [ -f "$bak" ]; then cp "$bak" "$f" 2>/dev/null && msg_ok "$(basename "$f") восстановлен"
      else sed -i 's/ apparmor=1 security=apparmor//g; s/ apparmor=1//g; s/ security=apparmor//g; /^extraargs=$/d' "$f" 2>/dev/null && msg_ok "$(basename "$f") очищен"; fi
    fi
  done
}

# ============================================================================
# CONFIGURE: Восстановление состояния среды (Uninstall)
# ============================================================================

# Восстановление сети (сложная логика для Full Mode)
configure_network_restore() {
  msg_action "Восстановление сети..."
  local iface=""; iface=$(ip -o link show 2>/dev/null | awk -F': ' '!/lo/{print $2; exit}' | cut -d'@' -f1)
  local use_nm=false
  if [ -f "${BACKUP_DIR}/interfaces.bak" ] && grep -qE "^auto|^iface|^allow-" "${BACKUP_DIR}/interfaces.bak" 2>/dev/null; then
    local real_ifaces; real_ifaces=$(grep -cE "^auto [^l]|^iface [^l]" "${BACKUP_DIR}/interfaces.bak" 2>/dev/null || true)
    [ "${real_ifaces:-0}" -gt 0 ] && local use_ifupdown=true
  fi
  is_armbian || [ "$use_ifupdown" != true ] && use_nm=true

  if [ "$use_nm" = true ]; then
    msg_dim "Оставляем NetworkManager"
    rm -f /etc/NetworkManager/conf.d/10-ha-managed.conf /etc/NetworkManager/conf.d/10-dns-resolved.conf 2>/dev/null
    if [ -f "${BACKUP_DIR}/resolv.conf.bak" ]; then rm -f /etc/resolv.conf 2>/dev/null; cp "${BACKUP_DIR}/resolv.conf.bak" /etc/resolv.conf 2>/dev/null; fi
    systemctl enable NetworkManager 2>/dev/null || true; systemctl restart NetworkManager 2>/dev/null || true
  else
    msg_dim "Восстановление ifupdown"
    cp "${BACKUP_DIR}/interfaces.bak" /etc/network/interfaces 2>/dev/null
    if [ -f "${BACKUP_DIR}/resolv.conf.bak" ]; then rm -f /etc/resolv.conf 2>/dev/null; cp "${BACKUP_DIR}/resolv.conf.bak" /etc/resolv.conf 2>/dev/null
    else rm -f /etc/resolv.conf 2>/dev/null; echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf; fi
    systemctl stop NetworkManager 2>/dev/null || true; systemctl disable NetworkManager 2>/dev/null || true
    systemctl stop systemd-resolved 2>/dev/null || true; systemctl disable systemd-resolved 2>/dev/null || true
    systemctl enable networking 2>/dev/null || true; systemctl restart networking 2>/dev/null || true
    [ -n "$iface" ] && command -v ifup &>/dev/null && { ifdown "$iface" 2>/dev/null || true; ifup "$iface" 2>/dev/null || true; }
  fi

  # Ожидание IP
  local net_wait=0 check_ip=""
  while [ $net_wait -lt 20 ]; do
    check_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -n "$check_ip" ] && { msg_ok "Сеть: ${check_ip}"; return 0; }
    sleep 3; net_wait=$((net_wait + 3))
  done
  [ -z "$check_ip" ] && [ -n "$iface" ] && {
    msg_warn "Нет IP, пробуем DHCP..."; ip link set "$iface" up 2>/dev/null || true
    command -v dhclient &>/dev/null && dhclient "$iface" 2>/dev/null || true
    command -v udhcpc &>/dev/null && udhcpc -i "$iface" -q 2>/dev/null || true
    sleep 5; check_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -n "$check_ip" ] && msg_ok "Сеть: ${check_ip} (DHCP)" || msg_warn "Нет IP"
  }
}

# =========================================================================
# ОПЕРАЦИИ: УДАЛЕНИЕ
# =========================================================================
do_uninstall() {
    header "УДАЛЕНИЕ HA SUPERVISED"

    # --- Локальная функция подтверждения ---
    _confirm() {
        local prompt="$1" timeout="${2:-120}"
        echo -en " ${WARN} ${prompt} (yes/y/д): " >&2
        local a=""
        if [ -t 0 ]; then read -r -t "$timeout" a 2>/dev/null || a="no"; else a="no"; fi
        case "$a" in yes|y|Y|д|Д|да|Да) return 0 ;; *) return 1 ;; esac
    }

    # === ВЫБОР РЕЖИМА ===
    local mode="standard"
    if command -v whiptail &>/dev/null; then
        mode=$(whiptail --title "Режим удаления" --menu "Выберите режим удаления:" 16 65 3 \
            "standard" "Стандартный (удалить HA, оставить Docker и сеть)" \
            "full"     "Полный (удалить ВСЁ для чистой переустановки)" \
            "cancel"   "Отмена" 3>&1 1>&2 2>&3) || { msg_info "Отменено."; exit 0; }
    else
        mode=$(text_menu "Режим удаления" "Выберите:" \
            "standard" "Стандартный (оставить Docker и сеть)" \
            "full"     "Полный (для чистой переустановки)" \
            "cancel"   "Отмена") || { msg_info "Отменено."; exit 0; }
    fi
    [ "$mode" = "cancel" ] && { msg_info "Отменено."; exit 0; }

    # === ПОДТВЕРЖДЕНИЕ ===
    local ok=false ans=""
    if [ "$mode" = "full" ]; then
        if command -v whiptail &>/dev/null; then
            whiptail --title "ПОЛНОЕ УДАЛЕНИЕ" --yesno "ВНИМАНИЕ! Будет удалено ВСЁ:\n\n- HA Supervised и OS-Agent\n- ВСЕ контейнеры и образы Docker\n- Docker CE полностью\n- Все данные HA и бэкапы\n- Настройки сети и AppArmor\n\nСистема вернётся к состоянию до установки.\nПродолжить?" 18 60 && ok=true
        else
            echo -e " ${RED}${BOLD}ПОЛНОЕ УДАЛЕНИЕ${NC}" >&2; echo -e " Будет удалено ВСЁ включая Docker, данные, бэкапы, сеть." >&2
            echo -en " ${WARN} Введите 'УДАЛИТЬ ВСЁ' для подтверждения: " >&2; read -r ans
            [ "$ans" = "УДАЛИТЬ ВСЁ" ] && ok=true
        fi
    else
        if command -v whiptail &>/dev/null; then
            whiptail --title "Удаление" --yesno "Удалить Home Assistant Supervised?\n\nDocker и сеть останутся.\nДанные HA — по запросу." 12 50 && ok=true
        else _confirm "Удалить HA Supervised?" && ok=true; fi
    fi
    [ "$ok" != true ] && { msg_info "Отменено."; exit 0; }

    load_config

    # =======================================================
    # ОБЩАЯ ЧАСТЬ (оба режима)
    # =======================================================
    apply_ha_services_stop
    apply_ha_docker_cleanup
    apply_ha_packages_purge
    apply_ha_files_cleanup
    apply_vpn_cleanup

    # =======================================================
    # СТАНДАРТНЫЙ РЕЖИМ
    # =======================================================
    if [ "$mode" = "standard" ]; then
        # Данные HA
        if [ -d "$HASSIO_DIR" ] || [ -L "$HASSIO_DIR" ]; then
            if _confirm "Удалить данные HA (${HASSIO_DIR})?"; then
                local target=""; [ -L "$HASSIO_DIR" ] && target=$(readlink -f "$HASSIO_DIR") && rm -f "$HASSIO_DIR"
                rm -rf "${target:-$HASSIO_DIR}" "${HASSIO_DIR}.bak" 2>/dev/null; msg_ok "Данные удалены"
            fi
        fi
        # Внешние диски
        [ -n "${OPT_DATA_DIR:-}" ] && [ -d "${OPT_DATA_DIR:-}/hassio" ] && \
            _confirm "Данные на внешнем диске (${OPT_DATA_DIR}/hassio). Удалить?" && { rm -rf "${OPT_DATA_DIR}/hassio"; msg_ok "Удалены"; }
        [ -L /var/lib/docker ] && _confirm "Docker на внешнем диске ($(readlink -f /var/lib/docker)). Удалить?" && {
            systemctl stop docker 2>/dev/null || true; rm -rf "$(readlink -f /var/lib/docker)" /var/lib/docker
            [ -d /var/lib/docker.bak ] && mv /var/lib/docker.bak /var/lib/docker; systemctl disable docker 2>/dev/null || true; msg_ok "Docker данные удалены"; }

        local extra_paths=("/var/lib/homeassistant" "/home/homeassistant" "/root/.homeassistant")
        for ep in "${extra_paths[@]}"; do
            if [ -d "$ep" ]; then
                local ep_size=""; ep_size=$(du -sh "$ep" 2>/dev/null | awk '{print $1}')
                _confirm "Найден ${ep} (${ep_size:-?}). Удалить?" && { rm -rf "$ep"; msg_ok "Удалён: ${ep}"; }
            fi
        done
        
        # Прочее
        [ -f /swapfile ] && _confirm "Удалить swap-файл?" && { swapoff /swapfile 2>/dev/null; rm -f /swapfile; sed -i '/\/swapfile/d' /etc/fstab 2>/dev/null; msg_ok "Swap удалён"; }
        [ "$(hostname 2>/dev/null)" = "homeassistant" ] && { echo -en " ${WARN} Вернуть имя хоста? (введите новое или Enter): " >&2; read -r hn; [ -n "$hn" ] && hostnamectl set-hostname "$hn" 2>/dev/null; }
        [ -f "${BACKUP_DIR}/fstab.bak" ] && _confirm "Восстановить оригинальный fstab?" && { cp "${BACKUP_DIR}/fstab.bak" /etc/fstab 2>/dev/null; msg_ok "fstab восстановлен"; }
        [ -d "$HA_BACKUP_DIR" ] && _confirm "Удалить бэкапы (${HA_BACKUP_DIR})?" && { rm -rf "$HA_BACKUP_DIR"; msg_ok "Бэкапы удалены"; }
        
        if id homeassistant &>/dev/null; then
            if _confirm "Удалить пользователя homeassistant?"; then
                local ha_home=""; ha_home=$(getent passwd homeassistant 2>/dev/null | cut -d: -f6)
                userdel -r homeassistant 2>/dev/null || userdel homeassistant 2>/dev/null || true
                [ -n "$ha_home" ] && [ -d "$ha_home" ] && rm -rf "$ha_home"; msg_ok "Пользователь удалён"
            fi
        fi
        _confirm "Удалить логи установщика?" && { rm -f /var/log/ha_install_*.log /var/log/ha_install_reboot.log 2>/dev/null; msg_ok "Логи удалены"; }

        rm -rf "$HA_INSTALLER_DIR" /root/.ha_install_state /root/.ha_install_backup 2>/dev/null
        command -v docker &>/dev/null && docker system prune -f 2>/dev/null || true
        rm -f "$GRACE_MARKER" 2>/dev/null
        separator
        msg_ok "Стандартное удаление завершено"

    # =======================================================
    # ПОЛНЫЙ РЕЖИМ
    # =======================================================
    elif [ "$mode" = "full" ]; then
        msg_action "Полная очистка..."
        # Данные
        local target=""; [ -L "$HASSIO_DIR" ] && target=$(readlink -f "$HASSIO_DIR") && rm -f "$HASSIO_DIR"
        rm -rf "${target:-$HASSIO_DIR}" "${HASSIO_DIR}.bak" /var/lib/homeassistant /home/homeassistant /root/.homeassistant 2>/dev/null
        [ -n "${OPT_DATA_DIR:-}" ] && [ -d "${OPT_DATA_DIR:-}" ] && rm -rf "${OPT_DATA_DIR}/hassio" "${OPT_DATA_DIR}/docker" 2>/dev/null
        [ -L /var/lib/docker ] && target=$(readlink -f /var/lib/docker) && rm -f /var/lib/docker && rm -rf "$target"
        rm -rf /var/lib/docker.bak "$HA_BACKUP_DIR" 2>/dev/null
        if id homeassistant &>/dev/null; then
            local ha_home=""; ha_home=$(getent passwd homeassistant 2>/dev/null | cut -d: -f6)
            userdel -r homeassistant 2>/dev/null || userdel homeassistant 2>/dev/null || true; [ -n "$ha_home" ] && rm -rf "$ha_home"
        fi
        [ -f /swapfile ] && { swapoff /swapfile 2>/dev/null; rm -f /swapfile; sed -i '/\/swapfile/d' /etc/fstab 2>/dev/null; }
        [ "$(hostname)" = "homeassistant" ] && { [ -f "${BACKUP_DIR}/hostname.bak" ] && hostnamectl set-hostname "$(cat "${BACKUP_DIR}/hostname.bak")" || hostnamectl set-hostname "debian"; } 2>/dev/null
        [ -f "${BACKUP_DIR}/fstab.bak" ] && cp "${BACKUP_DIR}/fstab.bak" /etc/fstab 2>/dev/null

        # Удаление Docker CE
        apply_docker_ce_purge

        # Очистка загрузчика
        apply_bootloader_apparmor_restore
        if [ -n "$BOOT_DEV_FSTAB" ]; then
            local dev_uuid; dev_uuid=$(blkid -s UUID -o value "$BOOT_DEV_FSTAB" 2>/dev/null)
            if [ -n "$dev_uuid" ]; then sed -i "/UUID=$dev_uuid/d" /etc/fstab 2>/dev/null
            else sed -i "\|^${BOOT_DEV_FSTAB}|d" /etc/fstab 2>/dev/null; fi
        fi

        # Сеть
        configure_network_restore

        # Файрвол и SSH
        ufw --force disable 2>/dev/null || true; ufw --force reset 2>/dev/null || true; msg_ok "UFW сброшен"
        [ -f "${BACKUP_DIR}/sshd_config.bak" ] && cp "${BACKUP_DIR}/sshd_config.bak" /etc/ssh/sshd_config 2>/dev/null
        rm -f /etc/ssh/sshd_config.d/99-ha-hardening.conf 2>/dev/null; systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        
        rm -f /var/log/ha_install_*.log /var/log/ha_install_reboot.log 2>/dev/null
        rm -rf "$HA_INSTALLER_DIR" /root/.ha_install_state /root/.ha_install_backup 2>/dev/null
        rm -f "$GRACE_MARKER" 2>/dev/null
        systemctl restart systemd-journald 2>/dev/null || true
        
        separator
        msg_ok "ПОЛНОЕ УДАЛЕНИЕ ЗАВЕРШЕНО"
        msg_info "Система очищена для переустановки."
        
        # Показать оставшиеся зависимости, которые установил скрипт
        msg_info "Установленные зависимости (можно удалить вручную):"
        local dep_pkgs="avahi-daemon bluez fail2ban ufw"
        dep_pkgs+=" unattended-upgrades"
        dep_pkgs+=" zram-tools systemd-zram-generator"
        dep_pkgs+=" linux-cpupower cpufrequtils"
        local installed_deps=""
        for p in $dep_pkgs; do
            is_pkg_installed "$p" && installed_deps="${installed_deps} ${p}"
        done
        if [ -n "$installed_deps" ]; then
            msg_dim "  sudo apt purge${installed_deps}"
            msg_dim "  sudo apt autoremove"
        else
            msg_dim "  Нет установленных зависимостей"
        fi
        echo ""
        
        msg_warn "Рекомендуется перезагрузка: sudo reboot"
    fi
}

# ============================================================================
# ОПЕРАЦИИ: ОБНОВЛЕНИЕ
# ============================================================================
do_update() {
  header "ОБНОВЛЕНИЕ"
  load_config; detect_system_info

  if [ -x /usr/local/bin/ha-backup ] && [ -d "${HASSIO_DIR}/homeassistant" ]; then
    msg_action "Автобэкап перед обновлением..."
    /usr/local/bin/ha-backup 2>/dev/null && msg_ok "Бэкап OK" || msg_warn "Бэкап не удался"
  fi

  local co="${OA_VERSION:-}" ch="${HA_VERSION:-}" lo lh
  lo=$(get_latest_release "home-assistant/os-agent")
  lh=$(get_latest_release "home-assistant/supervised-installer")
  msg_info "OA: ${co:-?} -> ${lo:-?}"
  msg_info "HA: ${ch:-?} -> ${lh:-?}"
  [ "$co" = "$lo" ] && [ "$ch" = "$lh" ] && { msg_ok "Всё актуально"; return 0; }

  setup_tmpdir
  if [ "$co" != "$lo" ] && [ -n "$lo" ]; then
    download_file "https://github.com/home-assistant/os-agent/releases/download/${lo}/os-agent_${lo}_linux_${CACHED_ARCH}.deb" \
      "${HA_TMP}/os-agent.deb" "OA ${lo}"
    verify_checksum "${HA_TMP}/os-agent.deb" "home-assistant/os-agent" "$lo"
    run_cmd "OS-Agent" dpkg -i "${HA_TMP}/os-agent.deb"
    RESOLVED_OA_VER="$lo"
  fi

  if [ "$ch" != "$lh" ] && [ -n "$lh" ]; then
    download_file "https://github.com/home-assistant/supervised-installer/releases/download/${lh}/homeassistant-supervised.deb" \
      "${HA_TMP}/ha.deb" "HA ${lh}"
    verify_checksum "${HA_TMP}/ha.deb" "home-assistant/supervised-installer" "$lh"
    [ "$OS_RELEASE_FAKED" = true ] && [ -f "$FAKED_OS_RELEASE" ] && cp "$FAKED_OS_RELEASE" /etc/os-release
    DEBIAN_FRONTEND=noninteractive dpkg -i "${HA_TMP}/ha.deb" >/dev/null 2>&1 || apt-get install -f -y >/dev/null 2>&1
    [ "$OS_RELEASE_FAKED" = true ] && apply_os_release_restore
    RESOLVED_HA_VER="$lh"
  fi

  RESOLVED_HA_VER="${RESOLVED_HA_VER:-${lh:-$ch}}"
  RESOLVED_OA_VER="${RESOLVED_OA_VER:-$lo}"
  save_config
  msg_ok "Обновлено"
  send_notification "Обновлено OA:${RESOLVED_OA_VER} HA:${RESOLVED_HA_VER}"
}

# ============================================================================
# ОПЕРАЦИИ: ОБНОВЛЕНИЕ СКРИПТА
# ============================================================================
do_self_update() {
  header "ОБНОВЛЕНИЕ СКРИПТА"

  local latest
  latest=$(get_latest_release "$INSTALLER_REPO")
  [ -z "$latest" ] && { msg_warn "Не удалось проверить версию"; return 1; }

  # Убираем префикс 'v' для корректного сравнения чисел
  local latest_clean="${latest#v}"
  
  [ "$SCRIPT_VERSION" = "$latest_clean" ] && {
    msg_ok "Актуальная версия: ${SCRIPT_VERSION}"
    return 0
  }
  
  msg_info "Доступно обновление: ${SCRIPT_VERSION} -> ${latest}"

  # Интерактивное подтверждение
  if [ -t 0 ]; then
    echo -en "   ${ARROW} Обновить? (д/н): " >&2
    local ans; read -r ans
    case "$ans" in
      y|Y|д|Д) ;;
      *) msg_info "Отменено"; return 0 ;;
    esac
  fi

  local nf
  nf=$(mktemp /tmp/hassify_update_XXXXXX.sh 2>/dev/null) || {
    msg_error "Не удалось создать временный файл"
    return 1
  }

  msg_action "Загрузка ${latest}..."
  
  # Умная загрузка: сначала пробуем новое имя (hassify), 
  # если 404 - пробуем старое (install.sh) для совместимости
  local download_url=""
  
  if wget -q --timeout=10 --spider "https://raw.githubusercontent.com/${INSTALLER_REPO}/${latest}/hassify" 2>/dev/null; then
    download_url="https://raw.githubusercontent.com/${INSTALLER_REPO}/${latest}/hassify"
  elif wget -q --timeout=10 --spider "https://raw.githubusercontent.com/${INSTALLER_REPO}/${latest}/install.sh" 2>/dev/null; then
    download_url="https://raw.githubusercontent.com/${INSTALLER_REPO}/${latest}/install.sh"
  else
    msg_error "Файл обновления не найден в репозитории (пробовали hassify и install.sh)"
    rm -f "$nf"
    return 1
  fi

  if ! wget -q -O "$nf" "$download_url" 2>/dev/null; then
    msg_error "Загрузка не удалась"
    rm -f "$nf"
    return 1
  fi

  # Проверяем размер — защита от пустых страниц 404
  local sz
  sz=$(wc -c < "$nf" 2>/dev/null || echo 0)
  sz="${sz//[^0-9]/}"
  if [ "${sz:-0}" -lt 10000 ]; then
    msg_error "Файл слишком мал (${sz}б) — возможно ошибка загрузки"
    rm -f "$nf"
    return 1
  fi

  # Проверяем синтаксис bash
  if ! bash -n "$nf" 2>/dev/null; then
    msg_error "Синтаксическая ошибка в загруженном файле"
    rm -f "$nf"
    return 1
  fi

  # Проверяем что это наш скрипт
  if ! grep -q "SCRIPT_VERSION=" "$nf"; then
    msg_error "Некорректный файл (нет SCRIPT_VERSION)"
    rm -f "$nf"
    return 1
  fi

  # Проверяем реальную версию в файле
  local new_ver
  new_ver=$(grep "^readonly SCRIPT_VERSION=" "$nf" \
    | head -1 \
    | cut -d'"' -f2)
  if [ -z "$new_ver" ]; then
    msg_error "Не удалось определить версию в загруженном файле"
    rm -f "$nf"
    return 1
  fi
  msg_info "Версия в файле: ${new_ver}"

  local target="$SAFE_SCRIPT_PATH"
  mkdir -p "$(dirname "$target")"
  chmod +x "$nf"

  # Атомарная замена файла
  if mv "$nf" "$target" 2>/dev/null; then
    msg_ok "Обновлён до ${new_ver}: ${target}"
  else
    if cp "$nf" "$target" 2>/dev/null; then
      chmod +x "$target"
      rm -f "$nf" 2>/dev/null || true
      msg_ok "Обновлён до ${new_ver}: ${target}"
    else
      msg_error "Не удалось заменить файл: ${target}"
      rm -f "$nf" 2>/dev/null || true
      return 1
    fi
  fi

  msg_ok "Перезапуск обновленной версии..."
  sleep 1
  exec "$target" "$@"
}

# ============================================================================
# ОПЕРАЦИИ: САМОТЕСТ
# ============================================================================
do_self_test() {
  header "САМОТЕСТИРОВАНИЕ"
  local pass=0 fail=0
  _t() {
    local d="$1" e="$2"; shift 2; local r=0
    "$@" 2>/dev/null || r=1
    if [ "$r" -eq "$e" ]; then msg_ok "$d"; pass=$((pass+1))
    else msg_error "$d (ожидание=$e результат=$r)"; fail=$((fail+1)); fi
  }

  _t "ip 192.168.1.1"     0 validate_ip "192.168.1.1"
  _t "ip 0.0.0.0"         1 validate_ip "0.0.0.0"
  _t "ip 256.1.1.1"       1 validate_ip "256.1.1.1"
  _t "ip 01.02.03.04"     1 validate_ip "01.02.03.04"
  _t "ip 255.255.255.255" 1 validate_ip "255.255.255.255"
  _t "ip 10.0.0.1"        0 validate_ip "10.0.0.1"
  _t "шлюз ок"            0 validate_gw "192.168.1.1"
  _t "шлюз пустой"        1 validate_gw ""
  _t "dns ок"             0 validate_dns_list "8.8.8.8,1.1.1.1"
  _t "dns плохой"         1 validate_dns_list "abc"
  _t "dns пустой"         1 validate_dns_list ""

  local a; a=$(detect_arch)
  [ -n "$a" ] && { msg_ok "Архитектура: ${a}"; pass=$((pass+1)); } || { msg_error "Архитектура"; fail=$((fail+1)); }

  # Тест состояния (без изменения readonly STATE_FILE)
  local tsf="/tmp/ha_test_state_$$"
  rm -f "$tsf" "${tsf}.lock" "${tsf}.new"
  # Прямая запись без mark_done/is_done (они используют readonly STATE_FILE)
  echo "test_step|$(date +%s)|${SCRIPT_VERSION}" > "$tsf"
  if grep -q "^test_step|" "$tsf" 2>/dev/null; then
    local tv; tv=$(grep "^test_step|" "$tsf" | tail -1 | cut -d'|' -f3)
    [ "$tv" = "$SCRIPT_VERSION" ] && { msg_ok "Состояние: ок"; pass=$((pass+1)); } || { msg_error "Состояние: ошибка"; fail=$((fail+1)); }
  else
    msg_error "Состояние: ошибка"; fail=$((fail+1))
  fi
  rm -f "$tsf" "${tsf}.lock" "${tsf}.new"

  # Тест профиля
  local saved="$OPT_ZRAM"
  apply_profile "minimal" 2>/dev/null
  [ "$OPT_ZRAM" = true ] && { msg_ok "Профиль: ок"; pass=$((pass+1)); } || { msg_error "Профиль: ошибка"; fail=$((fail+1)); }
  OPT_ZRAM="$saved"

  # Тест текстового UI
  local tm_result
  tm_result=$(echo "1" | text_menu "Тест" "Выберите:" "alpha" "Первый" "beta" "Второй" 2>/dev/null)
  [ "$tm_result" = "alpha" ] && { msg_ok "text_menu: ок"; pass=$((pass+1)); } || { msg_error "text_menu: ошибка (${tm_result})"; fail=$((fail+1)); }

  separator
  echo -e "   ${BOLD}Результат: ${pass} пройдено / ${fail} ошибок${NC}"
  [ $fail -gt 0 ] && return 1 || return 0
}

# ============================================================================
# АРГУМЕНТЫ (--help на русском)
# ============================================================================
show_help() {
  cat << HELP
Hassify v${SCRIPT_VERSION}

  sudo hassify                     Интерактивный мастер/меню

  РЕЖИМЫ:
    -c, --check                         Диагностика системы
    -s, --status                        Мониторинг (live)
    -u, --uninstall                     Удаление HA
    --update                            Обновление HA + OS-Agent
    --self-update                       Обновление скрипта
    --self-test                         Самотестирование
    --benchmark                         Тест производительности
    --rescue                            Режим восстановления (авто-починка)
    --export-config                     Экспорт конфигурации
    --history                           История запусков

  ОПЦИИ УСТАНОВКИ:
    --profile ИМЯ                       minimal|standard|full|server|dev
    --timezone ЗОНА                     напр. Europe/Moscow
    --locale ЛОКАЛЬ                     напр. ru_RU.UTF-8
    --data-dir ПУТЬ                     Внешний диск для данных
    --restore-backup ФАЙЛ              Восстановить бэкап после установки
    --wifi SSID ПАРОЛЬ                  Настройка WiFi
    --webhook URL                       Webhook для уведомлений
    --swap РАЗМЕР|zram|none             Настройка swap (МБ или zram/none)
    --docker-mirror URL                 Зеркало Docker registry
    --auto-reboot                       Авто-перезагрузка при необходимости
    --from-step ШАГ                     Продолжить с указанного шага
    --import-config ФАЙЛ               Импорт конфигурации
    --skip-update                       Пропустить обновление системы
    --dry-run                           Без реальных изменений
    --silent                            Тихий режим
    --interactive-steps                 Подтверждение каждого шага
    --reset-state                       Сброс состояния установки
    --machine ТИП                       Тип машины HA
    --os-agent-ver X                    Версия OS-Agent
    --ha-ver X                          Версия HA
    --tailscale                 Установить Tailscale VPN для удаленного доступа
    --ts-authkey КЛЮЧ           Tailscale Auth Key для автоматической авторизации

  ФАЙЛЫ:
    ${HA_INSTALLER_DIR}/                Конфигурация и состояние
    ${HA_BACKUP_DIR}/                   Бэкапы
    ${HA_INFO_FILE}                     Информация об установке

  ПРИМЕРЫ:
    sudo hassify                                   Мастер установки
    sudo hassify --profile standard                Стандартный профиль
    sudo hassify --profile standard --timezone Europe/Moscow
    sudo hassify --check                           Диагностика
    sudo hassify --update                          Обновить HA
    sudo hassify --benchmark                       Тест железа
    sudo hassify --profile full --data-dir /mnt/ssd --auto-reboot
    sudo hassify --restore-backup /mnt/usb/ha_config_20250101.tar.gz

HELP
}

parse_args() {
  [ $# -eq 0 ] && return
  local explicit_mode=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)            show_help; exit 0;;
      -c|--check)           CHECK_ONLY=true; explicit_mode=true;;
      -s|--status)          SHOW_STATUS=true; explicit_mode=true;;
      -u|--uninstall)       UNINSTALL=true; explicit_mode=true;;
      --update)             DO_UPDATE=true; explicit_mode=true;;
      --self-update)        DO_SELF_UPDATE=true; explicit_mode=true;;
      --self-test)          DO_SELF_TEST=true; explicit_mode=true;;
      --benchmark)          DO_BENCHMARK=true; explicit_mode=true;;
      --rescue)             DO_RESCUE=true; explicit_mode=true;;
      --export-config)      DO_EXPORT_CONFIG=true; explicit_mode=true;;
      --history)            DO_SHOW_HISTORY=true; explicit_mode=true;;
      --reset-state)        reset_state; exit 0;;
      --skip-update)        SKIP_UPDATE=true;;
      --dry-run)            DRY_RUN=true;;
      --silent)             SILENT=true; RUN_WIZARD=false;;
      --interactive-steps)  INTERACTIVE_STEPS=true;;
      --auto-reboot)        OPT_AUTO_REBOOT=true;;
      --profile)            shift; [ $# -eq 0 ] && { msg_error "--profile ?"; exit 1; }; PROFILE="$1";;
      --profile=*)          PROFILE="${1#*=}";;
      --from-step)          shift; [ $# -eq 0 ] && { msg_error "--from-step ?"; exit 1; }; FROM_STEP="$1";;
      --from-step=*)        FROM_STEP="${1#*=}";;
      --import-config)      shift; [ $# -eq 0 ] && { msg_error "--import-config ?"; exit 1; }; IMPORT_CONFIG="$1";;
      --import-config=*)    IMPORT_CONFIG="${1#*=}";;
      --timezone)           shift; [ $# -eq 0 ] && { msg_error "--timezone ?"; exit 1; }; OPT_TIMEZONE="$1";;
      --timezone=*)         OPT_TIMEZONE="${1#*=}";;
      --locale)             shift; [ $# -eq 0 ] && { msg_error "--locale ?"; exit 1; }; OPT_LOCALE="$1";;
      --locale=*)           OPT_LOCALE="${1#*=}";;
      --data-dir)           shift; [ $# -eq 0 ] && { msg_error "--data-dir ?"; exit 1; }; OPT_DATA_DIR="$1";;
      --data-dir=*)         OPT_DATA_DIR="${1#*=}";;
      --restore-backup)     shift; [ $# -eq 0 ] && { msg_error "--restore-backup ?"; exit 1; }; OPT_RESTORE_BACKUP="$1";;
      --restore-backup=*)   OPT_RESTORE_BACKUP="${1#*=}";;
      --wifi)               shift; [ $# -lt 2 ] && { msg_error "--wifi SSID PASS"; exit 1; }; OPT_WIFI_SSID="$1"; shift; OPT_WIFI_PASS="$1";;
      --webhook)            shift; [ $# -eq 0 ] && { msg_error "--webhook ?"; exit 1; }; OPT_WEBHOOK_URL="$1";;
      --webhook=*)          OPT_WEBHOOK_URL="${1#*=}";;
      --swap)               shift; [ $# -eq 0 ] && { msg_error "--swap ?"; exit 1; }; OPT_SWAP_SIZE="$1";;
      --swap=*)             OPT_SWAP_SIZE="${1#*=}";;
      --docker-mirror)      shift; [ $# -eq 0 ] && { msg_error "--docker-mirror ?"; exit 1; }; OPT_DOCKER_MIRROR="$1";;
      --docker-mirror=*)    OPT_DOCKER_MIRROR="${1#*=}";;
      --machine)            shift; [ $# -eq 0 ] && { msg_error "--machine ?"; exit 1; }; HA_MACHINE="$1"; MACHINE_EXPLICIT=true;;
      --machine=*)          HA_MACHINE="${1#*=}"; MACHINE_EXPLICIT=true;;
      --os-agent-ver)       shift; [ $# -eq 0 ] && { msg_error "--os-agent-ver ?"; exit 1; }; OVERRIDE_OS_AGENT_VER="$1";;
      --os-agent-ver=*)     OVERRIDE_OS_AGENT_VER="${1#*=}";;
      --ha-ver)             shift; [ $# -eq 0 ] && { msg_error "--ha-ver ?"; exit 1; }; OVERRIDE_HA_VER="$1";;
      --ha-ver=*)           OVERRIDE_HA_VER="${1#*=}";;
      --tailscale)           OPT_TAILSCALE=true;;
      --ts-authkey)          shift; [ $# -eq 0 ] && { msg_error "--ts-authkey ?"; exit 1; }; TS_AUTHKEY="$1";;
      --ts-authkey=*)        TS_AUTHKEY="${1#*=}";;
      --boot-dir)           shift; [ $# -eq 0 ] && { msg_error "--boot-dir ?"; exit 1; }; BOOT_DIR="$1";;
      --boot-dir=*)         BOOT_DIR="${1#*=}";;
      --boot-dev)           shift; [ $# -eq 0 ] && { msg_error "--boot-dev ?"; exit 1; }; BOOT_DEV_FSTAB="$1";;
      --boot-dev=*)         BOOT_DEV_FSTAB="${1#*=}";;
      --cloudflared)       OPT_CLOUDFLARED=true;;
      --cf-token)          shift; [ $# -eq 0 ] && { msg_error "--cf-token ?"; exit 1; }; CF_TUNNEL_TOKEN="$1";;
      --cf-token=*)        CF_TUNNEL_TOKEN="${1#*=}";;
      *)                    msg_error "Неизвестная опция: $1"; show_help; exit 1;;
    esac
    shift
  done
  [ "$explicit_mode" = true ] && RUN_WIZARD=false
}

# ============================================================================
# БАННЕР
# ============================================================================
show_banner() {
    if [ "$CHECK_ONLY" != true ] && [ "$UNINSTALL" != true ] && [ "$SHOW_STATUS" != true ]; then
        [ "$LOGGING_ACTIVE" != true ] && clear
    fi
    [ "$SILENT" != true ] && {
        echo -e "${CYAN}"
 	      echo "   _   _                       _    __         "
	      echo "  | | | |   __ _   ___   ___  (_)  / _|  _   _ "
	      echo "  | |_| |  / _  | / __| / __| | | | |_  | | | |"
	      echo "  |  _  | | (_| | \__ \ \__ \ | | |  _| | |_| |"
	      echo "  |_| |_|  \____| |___/ |___/ |_| |_|    \___ |"
	      echo "                                         |___/ "
          echo -e "${NC}"
          echo -e "${BLUE}  [ Hassify ]${NC} ${WHITE}${BOLD}Установщик v${SCRIPT_VERSION}${NC}"
          echo -e "${DIM}  Ковка Home Assistant Supervised на TV-боксах и SBC${NC}"

        # Статус HA если установлен
        if systemctl is-active --quiet hassio-supervisor 2>/dev/null; then
            local ip
            ip=$(hostname -I 2>/dev/null | awk '{print $1}')
            local hc
            hc=$(curl -s -o /dev/null -w "%{http_code}" -m 2 http://localhost:8123 2>/dev/null || echo 000)
            if [ "$hc" = "200" ] || [ "$hc" = "401" ]; then
                echo -e " ${GREEN}● HA работает: http://${ip:-localhost}:8123${NC}"
            else
                echo -e " ${YELLOW}● HA установлен (загружается...)${NC}"
            fi
        fi
        echo ""
    }
}

# ============================================================================
# ФИНАЛЬНЫЙ ОТЧЁТ
# ============================================================================
show_final() {
  # Удаляем скрипт-баннер о ongoing установке
  rm -f /etc/profile.d/hassify-notify.sh 2>/dev/null || true
  # Очищаем счётчик попыток перезагрузки, если установка успешно завершена
  rm -f "$REBOOT_ATTEMPT_FILE" 2>/dev/null || true
  
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"
  local now; now=$(date +%s)
  local el=$(( now - ${INSTALL_START:-$now} ))
  local em=$((el/60)) es=$((el%60))

  header "УСТАНОВКА ЗАВЕРШЕНА! (${em}м ${es}с)"

  echo -e "   ${GREEN}=> http://${ip}:8123${NC}"
  [ "$OPT_HOSTNAME" = true ] && echo -e "   ${GREEN}=> http://homeassistant.local:8123${NC}"

  # WiFi QR
  if [ -n "$OPT_WIFI_SSID" ] && command -v qrencode &>/dev/null && [ "$SILENT" != true ]; then
    echo ""
    echo -e "   ${BOLD}WiFi QR:${NC}"
    qrencode -m 2 -t ANSIUTF8 "WIFI:T:WPA;S:${OPT_WIFI_SSID};P:${OPT_WIFI_PASS};;"
  fi

  # HA QR
  if command -v qrencode &>/dev/null && [ "$SILENT" != true ]; then
    echo ""
    echo -e "   ${BOLD}HA QR:${NC}"
    qrencode -m 2 -t ANSIUTF8 "http://${ip}:8123"
    echo ""
  fi

  separator
  echo -e "   ${BOLD}Компоненты:${NC} (профиль: ${PROFILE:-custom})"
  echo -e "   ${CHECK} HA Supervised (${HA_MACHINE}) + Docker + OS-Agent"
  [ -n "$OPT_TIMEZONE" ]          && echo -e "   ${CHECK} Часовой пояс: ${OPT_TIMEZONE}"
  [ -n "$OPT_DATA_DIR" ]          && echo -e "   ${CHECK} Данные: ${OPT_DATA_DIR}"
  [ "$OPT_ZRAM" = true ]          && echo -e "   ${CHECK} ZRAM"
  [ "$OPT_UFW" = true ]           && echo -e "   ${CHECK} UFW + Fail2Ban"
  [ "$OPT_WATCHDOG" = true ]      && echo -e "   ${CHECK} Watchdog"
  [ "$OPT_BACKUP" = true ]        && echo -e "   ${CHECK} Бэкапы"
  [ "$OPT_HACS" = true ]          && echo -e "   ${CHECK} HACS"
  [ "$OPT_MONITORING" = true ]    && echo -e "   ${CHECK} Мониторинг"
  [ "$OPT_BOOT_RECOVERY" = true ] && echo -e "   ${CHECK} Восст. загрузки"
  [ "$OPT_TAILSCALE" = true ] && echo -e "   ${CHECK} Tailscale VPN"
  [ "$OPT_CLOUDFLARED" = true ]   && echo -e "   ${CHECK} Cloudflare Tunnel"
  [ -n "$OPT_RESTORE_BACKUP" ]    && echo -e "   ${CHECK} Восстановлено: $(basename "$OPT_RESTORE_BACKUP")"
  [ "$OS_RELEASE_FAKED" = true ]   && echo -e "   ${WARN} os-release подменяется при старте supervisor"

  # Время шагов
  separator
  echo -e "   ${BOLD}Время шагов:${NC}"
  for s in "${ALL_STEPS[@]}"; do
    local st="${STEP_TIMES[$s]:-0}"
    [ "$st" -gt 0 ] && printf "   %-16s %dс\n" "${s}" "$st"
  done

  separator
  msg_dim "Конфиг:      ${HA_INSTALLER_DIR}"
  msg_dim "Бэкапы:      ${HA_BACKUP_DIR}"
  msg_dim "Лог:         ${LOG_FILE}"
  msg_dim "Информация:  ${HA_INFO_FILE}"

  echo -e "\n   ${BOLD}Команды:${NC} ha-health  ha-backup  ha-restore"

  [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" != "Y" ] && \
    msg_warn "AppArmor требует перезагрузки: sudo reboot"

  echo -e "\n   ${YELLOW}Инициализация HA занимает 10-15 минут.${NC}\n"

  generate_info_file
  # Инструкция по Tailscale
  if [ "$OPT_TAILSCALE" = true ]; then
    local ts_ip
    ts_ip=$(tailscale ip -4 2>/dev/null || echo "")
    if [ -n "$ts_ip" ]; then
      echo -e "\n   ${GREEN}${BOLD}Tailscale VPN подключен!${NC}"
      echo -e "   IP в VPN: ${CYAN}${ts_ip}${NC}"
      echo -e "   Доступ: ${CYAN}http://${ts_ip}:8123${NC}"
    else
      echo -e "\n   ${YELLOW}${BOLD}Важно про Tailscale VPN:${NC}"
      echo -e "   ${DIM}Tailscale установлен, но требует авторизации!"
      echo -e "   ${WHITE}1.${NC} На телефоне/ПК установите приложение Tailscale и войдите в аккаунт"
      echo -e "   ${WHITE}2.${NC} На TV-боксе выполните команду: ${CYAN}sudo tailscale up${NC}"
      echo -e "   ${WHITE}3.${NC} В терминале появится ссылка — откройте её в браузере"
    fi
    echo ""
  fi
  # Инструкция по Cloudflare
  if [ "$OPT_CLOUDFLARED" = true ]; then
    if systemctl is-active --quiet cloudflared 2>/dev/null; then
      echo -e "\n   ${GREEN}${BOLD}Cloudflare Tunnel запущен!${NC}"
      echo -e "   ${DIM}Ваш Home Assistant доступен публично по HTTPS через Cloudflare."
    else
      echo -e "\n   ${YELLOW}${BOLD}Важно про Cloudflare Tunnel:${NC}"
      echo -e "   ${DIM}Cloudflared установлен, но требует настройки!"
      echo -e "   ${WHITE}1.${NC} Зайдите в Cloudflare Zero Trust Dashboard -> Networks -> Tunnels"
      echo -e "   ${WHITE}2.${NC} Создайте туннель и скопируйте токен"
      echo -e "   ${WHITE}3.${NC} Выполните команду: ${CYAN}sudo cloudflared service install <ТОКЕН>${NC}"
    fi
    echo ""
  fi
  # Инструкция по облачному бэкапу
  if [ "$OPT_REMOTE_BACKUP" = true ] && [[ "$REMOTE_BACKUP_TARGET" == rclone://* ]]; then
    local rclone_remote="${REMOTE_BACKUP_TARGET#rclone://}"
    rclone_remote="${rclone_remote%%:*}"
    echo -e "\n   ${YELLOW}${BOLD}Важно про облачный бэкап:${NC}"
    echo -e "   ${DIM}rclone установлен, но требуется авторизация в облаке!"
    echo -e "   ${WHITE}1.${NC} Выполните в консоли команду: ${CYAN}sudo rclone config${NC}"
    echo -e "   ${WHITE}2.${NC} Выберите ${CYAN}n${NC} (New remote) и назовите его: ${CYAN}${rclone_remote}${NC}"
    echo -e "   ${WHITE}3.${NC} Выберите тип хранилища (Yandex Disk, Google Drive и т.д.)"
    echo -e "   ${WHITE}4.${NC} Скопируйте ссылку из консоли, откройте в браузере и авторизуйтесь"
    echo ""
  fi
  # Инструкция по системе бэкапов
  if [ "$OPT_BACKUP" = true ]; then
    if command -v ha &>/dev/null; then
      echo -e "\n   ${GREEN}${BOLD}Бэкапы настроены!${NC}"
      echo -e "   ${DIM}Используется нативная утилита HA CLI. Создаются ПОЛНЫЕ снапшоты"
      echo -e "   ${DIM}(со всеми аддонами, Zigbee2MQTT и базами данных)."
      echo -e "   ${DIM}Никаких ручных настроек и токенов не требуется!${NC}"
    else
      echo -e "\n   ${YELLOW}${BOLD}Важно про бэкапы:${NC}"
      echo -e "   ${DIM}Утилита 'ha' не найдена. Активирован быстрый бэкап (только конфиг Core)."
      echo -e "   ${DIM}Он НЕ сохраняет аддоны (Zigbee2MQTT, ESPHome) и базы данных."
    fi
    echo ""
  fi
  send_notification "Hassify: HA установлен http://${ip}:8123"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
  # Быстрая проверка --help
  for a in "$@"; do
    [ "$a" = "-h" ] || [ "$a" = "--help" ] && { show_help; exit 0; }
  done

  [ "$EUID" -ne 0 ] && { echo "Требуется root! Используйте: sudo $0"; exit 1; }

  # Сохранить оригинальные аргументы ДО parse_args
  # Используется в setup_reboot_continue для продолжения после перезагрузки
  ORIGINAL_ARGS="$*"

  parse_args "$@"
  setup_dirs
  migrate_legacy_paths
  log_run_history "$*"

  # Очистка сервиса продолжения после ребута
  remove_reboot_continue

  # Импорт конфигурации
  [ -n "$IMPORT_CONFIG" ] && import_config "$IMPORT_CONFIG"

  # Явные режимы из аргументов командной строки
  [ "$CHECK_ONLY" = true ]      && { show_banner; do_check; exit 0; }
  [ "$SHOW_STATUS" = true ]     && { do_status; exit 0; }
  [ "$UNINSTALL" = true ]       && { show_banner; acquire_lock; do_uninstall; exit 0; }
  [ "$DO_UPDATE" = true ]       && { show_banner; acquire_lock; do_update; exit 0; }
  [ "$DO_SELF_UPDATE" = true ]  && { show_banner; do_self_update; exit 0; }
  [ "$DO_SELF_TEST" = true ]    && { show_banner; do_self_test; exit $?; }
  [ "$DO_BENCHMARK" = true ]    && { show_banner; do_benchmark; exit 0; }
  [ "$DO_RESCUE" = true ]       && { show_banner; do_rescue; exit 0; }
  [ "$DO_EXPORT_CONFIG" = true ] && { show_banner; export_config; exit 0; }
  [ "$DO_SHOW_HISTORY" = true ] && { show_banner; show_history; exit 0; }

  # Профиль из CLI
  [ -n "$PROFILE" ] && apply_profile "$PROFILE"

  # Интерактивный режим: цикл меню → wizard → меню
  if [ $# -eq 0 ] && [ "$RUN_WIZARD" = true ]; then
        while true; do
            IMMEDIATE_ACTION=false # Сбрасываем флаг разовых действий
            
            if [ -t 0 ] && [ -t 1 ]; then
                show_main_menu || exit 0
            fi

      # Обработка выбора из меню (режимы с выходом из скрипта)
      [ "$CHECK_ONLY" = true ]      && { show_banner; do_check; exit 0; }
      [ "$SHOW_STATUS" = true ]     && { do_status; exit 0; }
      [ "$UNINSTALL" = true ]       && { show_banner; acquire_lock; do_uninstall; exit 0; }
      [ "$DO_UPDATE" = true ]       && { show_banner; acquire_lock; do_update; exit 0; }
      [ "$DO_SELF_UPDATE" = true ]  && { show_banner; do_self_update; exit 0; }
      [ "$DO_SELF_TEST" = true ]    && { show_banner; do_self_test; exit $?; }
      [ "$DO_BENCHMARK" = true ]    && { show_banner; do_benchmark; exit 0; }
      [ "$DO_RESCUE" = true ]       && { show_banner; do_rescue; exit 0; }
      [ "$DO_EXPORT_CONFIG" = true ] && { show_banner; export_config; exit 0; }
      [ "$DO_SHOW_HISTORY" = true ] && { show_banner; show_history; exit 0; }

      # Если выбрано немедленное действие (бэкап, здоровье, восстановление) - возвращаемся в меню
      if [ "$IMMEDIATE_ACTION" = true ]; then
          RUN_WIZARD=true # Восстанавливаем для следующего прохода
          continue
      fi

      # install выбран → тест железа → wizard
            if [ "$RUN_WIZARD" = true ] && [ "$DRY_RUN" = false ]; then
                # Тест железа перед wizard (результат влияет на рекомендацию профиля)
                show_banner
                do_benchmark
                if [ -t 0 ]; then
                    echo -en "\n Нажмите Enter для продолжения..." >&2
                    read -r -t 30
                fi
                if run_wizard; then
                    break
        else
          # wizard вернул 1 = обратно в меню
          # Сбросить флаги
          RUN_WIZARD=true
          CHECK_ONLY=false; SHOW_STATUS=false; UNINSTALL=false
          DO_UPDATE=false; DO_SELF_UPDATE=false; DO_SELF_TEST=false
          DO_BENCHMARK=false; DO_EXPORT_CONFIG=false; DO_SHOW_HISTORY=false
          DO_RESCUE=false
          continue  # показать меню снова
        fi
      fi

      break  # если не wizard — выходим из цикла к установке
    done
  fi

  # Nohup ТОЛЬКО для установки (после wizard, до начала шагов)
  auto_nohup_if_ssh

  # Запуск установки
  show_banner
  setup_logging
  setup_tmpdir
  INSTALL_START=$(date +%s)

  detect_system_info
  is_trixie && msg_info "Debian 13 Trixie"
  is_armbian && msg_info "Обнаружен Armbian"
  [ "$MACHINE_EXPLICIT" = false ] && HA_MACHINE=$(detect_machine_type)
  msg_info "Платформа: ${HA_MACHINE} (${CACHED_MACHINE_ARCH})"
  msg_info "os-release: ${CACHED_PRETTY_NAME} [ID=${CACHED_OS_ID}]"
  [ -n "$PROFILE" ]       && msg_info "Профиль: ${PROFILE}"
  [ -n "$OPT_TIMEZONE" ]  && msg_info "Часовой пояс: ${OPT_TIMEZONE}"
  [ -n "$OPT_DATA_DIR" ]  && msg_info "Данные: ${OPT_DATA_DIR}"

  # --from-step
  if [ -n "$FROM_STEP" ]; then
    local valid=false
    for s in "${ALL_STEPS[@]}"; do [ "$s" = "$FROM_STEP" ] && valid=true; done
    if [ "$valid" = false ]; then
      msg_error "Неизвестный шаг: ${FROM_STEP}"
      msg_info "Доступные: ${ALL_STEPS[*]}"
      exit 1
    fi
    msg_info "Продолжение с шага: ${FROM_STEP}"
    
    # Восстанавливаем токены уведомлений и настройки из сохраненного конфига
    load_config
    
    # Оповещаем пользователя, что скрипт ожил после перезагрузки
    send_notification "Система перезагружена. Установка HA продолжается (шаг ${FROM_STEP})..."
    
    # Создаем скрипт-баннер для SSH (безопаснее и надежнее, чем правка /etc/motd)
    cat > /etc/profile.d/ha-install-notify.sh << 'MOTDEOF'
echo ""
echo "  ============================================="
echo "  => HASSIFY ПРОДОЛЖАЕТ РАБОТУ В ФОНЕ <="
echo "  ============================================="
echo ""
echo "  Следить за логом в реальном времени:"
echo "    sudo tail -f /var/log/hassify_reboot.log"
echo ""
MOTDEOF
    chmod +x /etc/profile.d/ha-install-notify.sh

    local skip=true
    for s in "${ALL_STEPS[@]}"; do
      [ "$s" = "$FROM_STEP" ] && { skip=false; break; }
      if [ "$skip" = true ] && ! is_done "$s" 2>/dev/null; then
        mark_done "$s"
      fi
    done
  fi

  [ -f "$STATE_FILE" ] && show_progress

  # Защита от разрыва SSH
  trap '' HUP
  acquire_lock

  # === ВЫПОЛНЕНИЕ ШАГОВ ===
  run_step step_preflight          || { msg_error "Проверки не пройдены!"; exit 1; }
  run_step step_update_system      || { ask_continue_on_error "Обновление" "Ошибка обновления" || exit 1; }
  run_step step_install_deps       || { ask_continue_on_error "Зависимости" "Ошибка зависимостей" || exit 1; }
  run_step step_configure_network  || { msg_error "Ошибка сети!"; exit 1; }
  run_step step_configure_apparmor || { ask_continue_on_error "AppArmor" "Ошибка AppArmor" || exit 1; }
  run_step step_performance        || { ask_continue_on_error "Производительность" "Ошибка настройки" || exit 1; }
  run_step step_install_docker     || { msg_error "Ошибка Docker!"; exit 1; }
  run_step step_resolve_versions   || { msg_error "Ошибка определения версий!"; exit 1; }
  run_step step_download_packages  || { msg_error "Ошибка загрузки!"; exit 1; }
  run_step step_install_os_agent   || { msg_error "Ошибка OS-Agent!"; exit 1; }
  run_step step_install_ha         || { msg_error "Ошибка установки HA!"; exit 1; }
  run_step step_security           || { ask_continue_on_error "Безопасность" "Ошибка безопасности" || exit 1; }
  run_step step_extras             || { ask_continue_on_error "Утилиты" "Ошибка утилит" || exit 1; }
  run_step step_hacs               || { ask_continue_on_error "HACS" "Ошибка HACS" || exit 1; }
  run_step step_post_restore       || { ask_continue_on_error "Восстановление" "Ошибка восстановления" || exit 1; }

  show_final
}

main "$@"
