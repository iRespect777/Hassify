#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2086
# ============================================================================
# Home Assistant Supervised — ULTIMATE INSTALLER
# Version: 9.1.1
# Platform: TV-Boxes & SBC (Armbian Bookworm/Trixie / aarch64 / x86_64)
# License: MIT
# Repository: https://github.com/iRespect777/HAS-tvbox
# ============================================================================
if [ -z "$BASH_VERSION" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "Требуется bash >= 4.0"; exit 1
fi

readonly SCRIPT_VERSION="9.1.1"
readonly HA_DEFAULT_MACHINE="qemuarm-64"
readonly INSTALLER_REPO="mediahome/ha-installer"
readonly HA_INSTALLER_DIR="/var/lib/ha-installer"
readonly STATE_FILE="${HA_INSTALLER_DIR}/state"
readonly BACKUP_DIR="${HA_INSTALLER_DIR}/backup"
readonly HA_CONFIG_FILE="${HA_INSTALLER_DIR}/config"
readonly HA_BACKUP_DIR="/var/backups/homeassistant"
readonly LOCK_FILE="/var/lock/ha_install.lock"
readonly LOG_DIR="/var/log"
readonly HASSIO_DIR="/usr/share/hassio"
readonly GRACE_MARKER="/tmp/.ha_just_installed"
readonly FAKED_OS_RELEASE="${BACKUP_DIR}/os-release.faked"
readonly METRICS_DIR="/var/lib/prometheus/node-exporter"
readonly HA_SUPPORTED_CODENAMES="bookworm bullseye trixie"
readonly HISTORY_FILE="${HA_INSTALLER_DIR}/history"
readonly REBOOT_CONTINUE_SVC="ha-install-continue"
readonly REBOOT_ATTEMPT_FILE="${HA_INSTALLER_DIR}/reboot_attempts"
readonly HA_INFO_FILE="${HA_INSTALLER_DIR}/ha-info.txt"
readonly SAFE_SCRIPT_PATH="/usr/local/bin/ha-install"

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
OPT_TELEGRAM=false;    OPT_REVERSE_PROXY=false;  OPT_MONITORING=false
OPT_REMOTE_BACKUP=false; OPT_BOOT_RECOVERY=true; OPT_USB_DETECT=true

STATIC_IP=""; STATIC_GW=""; STATIC_DNS=""
TG_TOKEN=""; TG_CHAT=""
PROXY_DOMAIN=""; REMOTE_BACKUP_TARGET=""
SKIP_UPDATE=false; CHECK_ONLY=false; UNINSTALL=false
DRY_RUN=false; SILENT=false; SHOW_STATUS=false
DO_UPDATE=false; DO_SELF_TEST=false; DO_SELF_UPDATE=false
DO_EXPORT_CONFIG=false; DO_SHOW_HISTORY=false; DO_BENCHMARK=false
INTERACTIVE_STEPS=false
HA_MACHINE="$HA_DEFAULT_MACHINE"; MACHINE_EXPLICIT=false
OVERRIDE_OS_AGENT_VER=""; OVERRIDE_HA_VER=""
LOG_FILE=""; LOGGING_ACTIVE=false; TEE_PID=""
OS_RELEASE_FAKED=false; DAEMON_RELOAD_NEEDED=false
PREFETCH_PID=""; HA_TMP="/tmp/ha-install"; INSTALL_START=""
PROFILE=""; FROM_STEP=""; IMPORT_CONFIG=""
ORIGINAL_ARGS=""
CURRENT_STEP_NUM=0

OPT_TIMEZONE=""; OPT_DATA_DIR=""; OPT_WIFI_SSID=""; OPT_WIFI_PASS=""
OPT_WEBHOOK_URL=""; OPT_SWAP_SIZE=""; OPT_DOCKER_MIRROR=""
OPT_RESTORE_BACKUP=""; OPT_AUTO_REBOOT=false; OPT_LOCALE=""

SYSTEM_INFO_LOADED=false
CACHED_CODENAME=""; CACHED_VERSION_ID=""
CACHED_ARCH=""; CACHED_MACHINE_ARCH=""
CACHED_PRETTY_NAME=""; CACHED_OS_ID=""
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
  [minimal]="OPT_ZRAM=true OPT_EMMC_TUNING=false OPT_USB_POWER=false OPT_UFW=false OPT_SSH_HARDENING=false OPT_AUTOUPDATE=false OPT_WATCHDOG=false OPT_THERMAL=false OPT_BACKUP=false OPT_HACS=false OPT_HOSTNAME=true OPT_MONITORING=false OPT_REVERSE_PROXY=false OPT_REMOTE_BACKUP=false OPT_BOOT_RECOVERY=false OPT_USB_DETECT=false"
  [standard]="OPT_ZRAM=true OPT_EMMC_TUNING=true OPT_USB_POWER=true OPT_UFW=true OPT_SSH_HARDENING=true OPT_AUTOUPDATE=true OPT_WATCHDOG=true OPT_THERMAL=true OPT_BACKUP=true OPT_HACS=true OPT_HOSTNAME=true OPT_MONITORING=false OPT_REVERSE_PROXY=false OPT_REMOTE_BACKUP=false OPT_BOOT_RECOVERY=true OPT_USB_DETECT=true"
  [full]="OPT_ZRAM=true OPT_EMMC_TUNING=true OPT_USB_POWER=true OPT_UFW=true OPT_SSH_HARDENING=true OPT_AUTOUPDATE=true OPT_WATCHDOG=true OPT_THERMAL=true OPT_BACKUP=true OPT_HACS=true OPT_HOSTNAME=true OPT_MONITORING=true OPT_REVERSE_PROXY=false OPT_REMOTE_BACKUP=false OPT_BOOT_RECOVERY=true OPT_USB_DETECT=true"
  [server]="OPT_ZRAM=true OPT_EMMC_TUNING=true OPT_USB_POWER=true OPT_UFW=true OPT_SSH_HARDENING=true OPT_AUTOUPDATE=true OPT_WATCHDOG=true OPT_THERMAL=true OPT_BACKUP=true OPT_HACS=true OPT_HOSTNAME=true OPT_STATIC_IP=true OPT_MONITORING=true OPT_REVERSE_PROXY=false OPT_REMOTE_BACKUP=false OPT_BOOT_RECOVERY=true OPT_USB_DETECT=true"
  [dev]="OPT_ZRAM=false OPT_EMMC_TUNING=false OPT_USB_POWER=false OPT_UFW=false OPT_SSH_HARDENING=false OPT_AUTOUPDATE=false OPT_WATCHDOG=false OPT_THERMAL=false OPT_BACKUP=false OPT_HACS=true OPT_HOSTNAME=false OPT_MONITORING=false OPT_REVERSE_PROXY=false OPT_REMOTE_BACKUP=false OPT_BOOT_RECOVERY=false OPT_USB_DETECT=false"
)

# ============================================================================
# OUTPUT
# ============================================================================
header() {
  local t="$1"
  local b="================================================================"
  local p=$(( 60 - ${#t} )); [ "$p" -lt 0 ] && p=0
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
  local current="$1" total="$2" desc="${3:-}"
  [ "$total" -le 0 ] 2>/dev/null && return
  local width=35 pct=$((current * 100 / total))
  local filled=$((current * width / total)) empty=$((width - filled))
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

spinner_pid=""
spinner_start() {
  local d="$1"; [ "$SILENT" = true ] && return
  ( i=0 e=0; while true; do
    local c; case $((i%4)) in 0) c="|";; 1) c="/";; 2) c="-";; 3) c="\\";; esac
    printf "\r  %s %s (%dс)  " "$c" "$d" "$e" > /dev/tty 2>/dev/null || break
    sleep 1; i=$((i+1)); e=$((e+1))
  done ) &
  spinner_pid=$!; disown "$spinner_pid" 2>/dev/null || true
}

spinner_stop() {
  if [ -n "$spinner_pid" ] && kill -0 "$spinner_pid" 2>/dev/null; then
    kill "$spinner_pid" 2>/dev/null; wait "$spinner_pid" 2>/dev/null
    printf "\r%80s\r" "" > /dev/tty 2>/dev/null || true
  fi
  spinner_pid=""
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
  if command -v timeout &>/dev/null; then
    timeout 600 apt-get "$@"
  else
    apt-get "$@"
  fi
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
  echo -en "   ${prompt} (д/н) [${default}]: " >&2
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

# ============================================================================
# CONFIG (safe key=value parser)
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
PROFILE="${PROFILE}"
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
        OS_RELEASE_FAKED|BACKUP_DIR|OPT_ZRAM|OPT_UFW|OPT_WATCHDOG|\
        OPT_THERMAL|OPT_BACKUP|OPT_HACS|OPT_MONITORING|PROFILE|\
        OPT_DATA_DIR|OPT_TIMEZONE|OPT_WEBHOOK_URL|OPT_SWAP_SIZE|\
        OPT_DOCKER_MIRROR|OPT_AUTO_REBOOT|OPT_LOCALE)
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
    echo "# HA Installer config $(date)"
    for opt in OPT_ZRAM OPT_EMMC_TUNING OPT_USB_POWER OPT_UFW OPT_SSH_HARDENING \
      OPT_AUTOUPDATE OPT_WATCHDOG OPT_THERMAL OPT_BACKUP OPT_HACS OPT_HOSTNAME \
      OPT_MONITORING OPT_BOOT_RECOVERY OPT_USB_DETECT OPT_STATIC_IP OPT_TELEGRAM \
      OPT_REVERSE_PROXY OPT_REMOTE_BACKUP; do
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
    if [[ "$line" =~ ^(OPT_[A-Z_]+|PROFILE|HA_MACHINE)=(.*) ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      val="${val#\"}"; val="${val%\"}"
      [[ "$val" =~ ^[a-zA-Z0-9._:/-]+$ ]] || { msg_warn "Пропуск: ${key}"; continue; }
      printf -v "$key" '%s' "$val"
    fi
  done < "$file"
  RUN_WIZARD=false
  msg_ok "Импортировано: ${file}"
}

# ============================================================================
# NOTIFICATIONS (Telegram + webhook, with test)
# ============================================================================
send_notification() {
  local msg="$1"
  if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ] && [ "$TG_TOKEN" != "__HA_TG_TOKEN__" ]; then
    local rf="/tmp/.ha_notify_rate"
    local now; now=$(date +%s)
    local last; last=$(cat "$rf" 2>/dev/null || echo 0)
    if [ $((now - last)) -ge 30 ]; then
      echo "$now" > "$rf"
      curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TG_CHAT}" \
        --data-urlencode "text=HA ($(hostname)): ${msg}" >/dev/null 2>&1
    fi
  fi
  if [ -n "$OPT_WEBHOOK_URL" ]; then
    curl -s -X POST "$OPT_WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "{\"text\":\"HA ($(hostname)): ${msg}\",\"message\":\"HA ($(hostname)): ${msg}\"}" \
      >/dev/null 2>&1 || \
    curl -s -X POST "$OPT_WEBHOOK_URL" \
      -d "HA ($(hostname)): ${msg}" >/dev/null 2>&1 || true
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
      --data-urlencode "text=HA Installer: тест" 2>/dev/null)
    [ "$rc" = "200" ] && msg_ok "Telegram OK" || { msg_warn "Telegram ошибка (${rc})"; ok=false; }
  fi
  if [ -n "$OPT_WEBHOOK_URL" ]; then
    msg_action "Тест webhook..."
    local rc
    rc=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$OPT_WEBHOOK_URL" \
      -d "HA Installer: тест" 2>/dev/null)
    if [ "$rc" -ge 200 ] 2>/dev/null && [ "$rc" -lt 300 ] 2>/dev/null; then
      msg_ok "Webhook OK"
    else
      msg_warn "Webhook ошибка (${rc})"; ok=false
    fi
  fi
  $ok
}

# ============================================================================
# STATE, LOCK, ROLLBACK
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
# SSH NOHUP
# ============================================================================
auto_nohup_if_ssh() {
  # В silent режиме не спрашивать
  [ "$SILENT" = true ] && return 0
  if who 2>/dev/null | grep -q pts && [ -z "${HA_NOHUP:-}" ]; then
    msg_warn "Обнаружена SSH-сессия."
    if [ -t 0 ] && [ -t 1 ]; then
      echo -en "   ${ARROW}  Запустить через nohup (защита от разрыва)? (д/н): " >&2
      local ans; read -r -t 10 ans || ans="n"
      if [ "$ans" = "y" ] || [ "$ans" = "Y" ] || [ "$ans" = "д" ] || [ "$ans" = "Д" ]; then
        export HA_NOHUP=1
        local nlog="${LOG_DIR}/ha_install_nohup_$(date +%Y%m%d_%H%M%S).log"
        msg_info "Следить: tail -f ${nlog}"
        nohup bash "$0" $ORIGINAL_ARGS >> "$nlog" 2>&1 &
        msg_ok "PID: $!"
        exit 0
      fi
    fi
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

# ============================================================================
# REBOOT CONTINUE (with attempt counter + /tmp safety)
# ============================================================================
ensure_safe_script_path() {
  local current_path
  current_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
  if [[ "$current_path" == /tmp/* ]] || [[ "$current_path" == /var/tmp/* ]]; then
    cp "$current_path" "$SAFE_SCRIPT_PATH" 2>/dev/null
    chmod +x "$SAFE_SCRIPT_PATH"
    msg_dim "Скрипт скопирован в ${SAFE_SCRIPT_PATH}"
  elif [ ! -f "$SAFE_SCRIPT_PATH" ]; then
    cp "$current_path" "$SAFE_SCRIPT_PATH" 2>/dev/null
    chmod +x "$SAFE_SCRIPT_PATH"
  fi
}

setup_reboot_continue() {
  ensure_safe_script_path
  local svc_file="/etc/systemd/system/${REBOOT_CONTINUE_SVC}.service"
  local attempts=0
  [ -f "$REBOOT_ATTEMPT_FILE" ] && attempts=$(cat "$REBOOT_ATTEMPT_FILE" 2>/dev/null || echo 0)
  if [ "$attempts" -ge 3 ]; then
    msg_error "Превышен лимит перезагрузок (3)"
    rm -f "$REBOOT_ATTEMPT_FILE"
    return 1
  fi
  echo $((attempts + 1)) > "$REBOOT_ATTEMPT_FILE"

  cat > "$svc_file" << SVCEOF
[Unit]
Description=HA Installer - продолжение после перезагрузки
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${SAFE_SCRIPT_PATH} ${ORIGINAL_ARGS} --from-step=perf
ExecStartPost=/bin/rm -f ${svc_file}
RemainAfterExit=no
StandardOutput=append:${LOG_DIR}/ha_install_reboot.log
StandardError=append:${LOG_DIR}/ha_install_reboot.log

[Install]
WantedBy=multi-user.target
SVCEOF

  systemctl daemon-reload 2>/dev/null || true
  systemctl enable "${REBOOT_CONTINUE_SVC}" 2>/dev/null || true
  msg_ok "Продолжит после перезагрузки (попытка $((attempts+1))/3)"
}

remove_reboot_continue() {
  systemctl disable "${REBOOT_CONTINUE_SVC}" 2>/dev/null || true
  rm -f "/etc/systemd/system/${REBOOT_CONTINUE_SVC}.service" "$REBOOT_ATTEMPT_FILE" 2>/dev/null || true
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
    echo -en "   ${ARROW} [${CURRENT_STEP_NUM}/${TOTAL_STEPS}] ${step_id:-$f}? (д/н/в): " >&2
    local ans; read -r ans
    case "$ans" in
      n|N|н|Н) msg_dim "Пропущен"; return 0;;
      q|Q|в|В) msg_warn "Прервано"; exit 0;;
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
# CLEANUP
# ============================================================================
cleanup() {
  local ec=$?
  spinner_stop 2>/dev/null || true
  [ -n "$PREFETCH_PID" ] && kill "$PREFETCH_PID" 2>/dev/null || true
  cleanup_tmpdir 2>/dev/null || true
  release_lock
  flush_log 2>/dev/null || true
  if [ $ec -ne 0 ] && [ $ec -ne 130 ]; then
    [ ${#ROLLBACK_ACTIONS[@]} -gt 0 ] && execute_rollback
    [ "$OPT_AUTO_REBOOT" != true ] && remove_reboot_continue
  fi
  [ $ec -eq 130 ] && echo -e "\n ${WARN} ${YELLOW}Прервано${NC}"
  # Beep on success
  [ $ec -eq 0 ] && [ -n "$INSTALL_START" ] && echo -e "\a" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

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
  msg_error "${desc} — не удалось"; return 1
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
  msg_dim "SHA256 недоступен — пропуск"
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
    armv7l) echo "qemuarm";;
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
  if ! host github.com &>/dev/null 2>&1 && ping -c1 -W2 8.8.8.8 &>/dev/null; then
    msg_warn "DNS не работает, исправление..."
    if [ -L /etc/resolv.conf ]; then
      msg_dim "resolv.conf — симлинк, пропуск"
    else
      [ -f /etc/resolv.conf ] && cp /etc/resolv.conf "${BACKUP_DIR}/resolv.conf.dns-fix" 2>/dev/null
      printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
      host github.com &>/dev/null 2>&1 && msg_ok "DNS исправлен" || msg_warn "DNS всё ещё не работает"
    fi
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
  echo "$HA_SUPPORTED_CODENAMES" | grep -qw "$CACHED_CODENAME" || return 0
  return 1
}

backup_os_release() {
  mkdir -p "$BACKUP_DIR"
  if [ ! -f "${BACKUP_DIR}/os-release.original" ]; then
    if [ -L /etc/os-release ]; then
      readlink /etc/os-release > "${BACKUP_DIR}/os-release.symlink"
      cp "$(readlink -f /etc/os-release)" "${BACKUP_DIR}/os-release.original"
    else
      cp /etc/os-release "${BACKUP_DIR}/os-release.original"
    fi
  fi
}

fake_os_release() {
  backup_os_release; detect_system_info
  local tc="bookworm" tv="12"
  if [ "$CACHED_CODENAME" = "trixie" ] || [ "$CACHED_VERSION_ID" = "13" ]; then
    tc="trixie"; tv="13"
  elif [ "$CACHED_CODENAME" = "bullseye" ] || [ "$CACHED_VERSION_ID" = "11" ]; then
    tc="bullseye"; tv="11"
  elif [ "$CACHED_CODENAME" = "sid" ] || [ "$CACHED_CODENAME" = "testing" ]; then
    tc="trixie"; tv="13"
  fi
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

restore_os_release() {
  if [ -f "${BACKUP_DIR}/os-release.symlink" ]; then
    local lt
    lt=$(cat "${BACKUP_DIR}/os-release.symlink")
    cp "${BACKUP_DIR}/os-release.original" "$lt" 2>/dev/null
    ln -sf "$lt" /etc/os-release 2>/dev/null
    msg_ok "os-release восстановлен (симлинк)"
  elif [ -f "${BACKUP_DIR}/os-release.original" ]; then
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
  ( for img in supervisor dns cli audio multicast observer; do
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
  [ -f "${BACKUP_DIR}/interfaces.bak" ] && cp "${BACKUP_DIR}/interfaces.bak" /etc/network/interfaces 2>/dev/null
  [ -f "${BACKUP_DIR}/resolv.conf.bak" ] && cp "${BACKUP_DIR}/resolv.conf.bak" /etc/resolv.conf 2>/dev/null
  systemctl restart NetworkManager 2>/dev/null || true
  systemctl start networking 2>/dev/null || true
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
# v9.x: DATA-DIR, TIMEZONE, LOCALE, WIFI, SWAP, DOCKER MIRROR, BENCHMARK
# ============================================================================
setup_data_dir() {
  [ -z "$OPT_DATA_DIR" ] && return 0
  local t="$OPT_DATA_DIR"

  if [ ! -d "$t" ]; then msg_error "Каталог не найден: ${t}"; return 1; fi
  if ! touch "${t}/.ha_test" 2>/dev/null; then msg_error "Нет доступа на запись: ${t}"; return 1; fi
  rm -f "${t}/.ha_test"

  local fstype
  fstype=$(df -T "$t" 2>/dev/null | awk 'NR==2{print $2}')
  case "$fstype" in
    ext4|btrfs|xfs|ext3) msg_ok "ФС данных: ${fstype}" ;;
    vfat|ntfs|exfat|fat32) msg_error "Неподдерживаемая ФС: ${fstype} (нужна ext4/btrfs/xfs)"; return 1 ;;
    *) msg_warn "ФС данных: ${fstype} (может работать)" ;;
  esac

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

setup_timezone() {
  [ -z "$OPT_TIMEZONE" ] && return 0
  if [ -f "/usr/share/zoneinfo/${OPT_TIMEZONE}" ]; then
    timedatectl set-timezone "$OPT_TIMEZONE" 2>/dev/null || \
      ln -sf "/usr/share/zoneinfo/${OPT_TIMEZONE}" /etc/localtime
    msg_ok "Часовой пояс: ${OPT_TIMEZONE}"
  else
    msg_warn "Неизвестный часовой пояс: ${OPT_TIMEZONE}"
  fi
}

setup_locale() {
  [ -z "$OPT_LOCALE" ] && return 0
  msg_action "Локаль: ${OPT_LOCALE}..."
  if command -v locale-gen &>/dev/null; then
    sed -i "s/^# *${OPT_LOCALE}/${OPT_LOCALE}/" /etc/locale.gen 2>/dev/null
    locale-gen 2>/dev/null || true
    update-locale LANG="${OPT_LOCALE}" 2>/dev/null || true
    msg_ok "Локаль: ${OPT_LOCALE}"
  else
    msg_warn "locale-gen недоступен"
  fi
}

setup_wifi() {
  [ -z "$OPT_WIFI_SSID" ] && return 0
  command -v nmcli &>/dev/null || { msg_warn "nmcli недоступен для WiFi"; return 0; }
  msg_action "WiFi: ${OPT_WIFI_SSID}..."
  nmcli dev wifi connect "$OPT_WIFI_SSID" password "$OPT_WIFI_PASS" 2>/dev/null && \
    msg_ok "WiFi подключён" || msg_warn "WiFi не удалось подключить"
}

setup_swap() {
  [ -z "$OPT_SWAP_SIZE" ] && return 0
  case "$OPT_SWAP_SIZE" in
    none|0)
      swapoff -a 2>/dev/null
      sed -i '/swap/d' /etc/fstab 2>/dev/null
      msg_ok "Swap отключён"
      ;;
    zram)
      msg_dim "ZRAM настроится на шаге производительности"
      ;;
    *)
      if [[ "$OPT_SWAP_SIZE" =~ ^[0-9]+$ ]]; then
        swapoff /swapfile 2>/dev/null; rm -f /swapfile 2>/dev/null
        dd if=/dev/zero of=/swapfile bs=1M count="$OPT_SWAP_SIZE" status=none 2>/dev/null
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1
        swapon /swapfile 2>/dev/null
        grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        msg_ok "Swap: ${OPT_SWAP_SIZE}МБ"
      else
        msg_warn "Неверный размер swap: ${OPT_SWAP_SIZE}"
      fi
      ;;
  esac
}

setup_docker_mirror() {
  [ -z "$OPT_DOCKER_MIRROR" ] && return 0
  mkdir -p /etc/docker
  if [ -f /etc/docker/daemon.json ] && command -v jq &>/dev/null; then
    jq --arg m "$OPT_DOCKER_MIRROR" '. + {"registry-mirrors": [$m]}' \
      /etc/docker/daemon.json > /tmp/dj.tmp 2>/dev/null && \
      mv /tmp/dj.tmp /etc/docker/daemon.json
  else
    echo "{\"log-driver\":\"journald\",\"storage-driver\":\"overlay2\",\"registry-mirrors\":[\"${OPT_DOCKER_MIRROR}\"]}" \
      > /etc/docker/daemon.json
  fi
  msg_ok "Зеркало Docker: ${OPT_DOCKER_MIRROR}"
}

do_benchmark() {
  header "ТЕСТ ПРОИЗВОДИТЕЛЬНОСТИ"
  detect_system_info
  local ram_mb cpu_cores
  ram_mb=$(free -m | awk '/Mem:/{print $2}')
  cpu_cores=$(nproc 2>/dev/null || echo 1)
  echo -e "   ${BOLD}CPU:${NC}  $(lscpu 2>/dev/null | awk -F: '/Model name/{print $2}' | xargs) (${cpu_cores} ядер)"
  echo -e "   ${BOLD}RAM:${NC}  ${ram_mb}МБ"
  echo -e "   ${BOLD}Арх:${NC}  ${CACHED_MACHINE_ARCH}"
  echo -e "   ${BOLD}ОС:${NC}   ${CACHED_PRETTY_NAME}"
  separator
  msg_action "Тест диска (50МБ)..."
  local dio
  dio=$(dd if=/dev/zero of=/tmp/.ha_bench bs=1M count=50 oflag=dsync 2>&1 | tail -1 | awk -F, '{print $NF}' | xargs)
  rm -f /tmp/.ha_bench
  echo -e "   ${BOLD}Диск:${NC} ${dio}"
  separator
  local verdict="Подходит для Home Assistant"
  [ "$ram_mb" -lt 900 ] && verdict="НЕ подходит (нужно 1ГБ+ RAM)"
  [ "$ram_mb" -lt 2048 ] && [ "$verdict" = "Подходит для Home Assistant" ] && verdict="Подходит (мало RAM)"
  echo -e "\n   ${BOLD}Вердикт:${NC} ${verdict}\n"
}

generate_info_file() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"
  cat > "$HA_INFO_FILE" << INFOEOF
============================================
 Home Assistant — Информация об установке
 Создан: $(date)
 Установщик: v${SCRIPT_VERSION}
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
  Логи:         ${LOG_DIR}/ha_install_*.log
  Информация:   ${HA_INFO_FILE}

КОМАНДЫ:
  ha-health          Отчёт о здоровье
  ha-backup          Создать бэкап
  ha-restore         Восстановить из бэкапа
  ha-notify "текст"  Отправить уведомление

ОБСЛУЖИВАНИЕ:
  sudo ha-install --check       Диагностика
  sudo ha-install --status      Мониторинг
  sudo ha-install --update      Обновить HA
  sudo ha-install --self-test   Самотест
  sudo ha-install --benchmark   Тест железа

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
  [ -z "${PROFILES[$p]+x}" ] && { msg_error "Профиль '$p' не найден. Доступные: ${!PROFILES[*]}"; exit 1; }
  eval "${PROFILES[$p]}"
  PROFILE="$p"
  RUN_WIZARD=false
  msg_ok "Профиль: ${p}"
}

# ============================================================================
# WIZARD (whiptail + text fallback, русский интерфейс)
# ============================================================================
run_wizard() {
  local HAS_WHIPTAIL=false
  if command -v whiptail &>/dev/null; then
    HAS_WHIPTAIL=true
  else
    apt-get update -qq 2>/dev/null && apt-get install -y whiptail -qq 2>/dev/null && HAS_WHIPTAIL=true
  fi

  detect_system_info
  local si="${CACHED_PRETTY_NAME:-${CACHED_CODENAME}} (${CACHED_MACHINE_ARCH})"
  is_armbian && si+=" [Armbian]"
  local ram_mb; ram_mb=$(free -m | awk '/Mem:/{print $2}')
  local disk_mb; disk_mb=$(df -m / | awk 'NR==2{print $4}')

  # --- Приветствие ---
  if [ "$HAS_WHIPTAIL" = true ]; then
    whiptail --title "HA Установщик v${SCRIPT_VERSION}" --msgbox \
      "Установщик Home Assistant Supervised\n\n${si}\nRAM: ${ram_mb}МБ | Диск: ${disk_mb}МБ свободно" 12 64
  else
    header "HA Установщик v${SCRIPT_VERSION}"
    msg_info "${si}"
    msg_info "RAM: ${ram_mb}МБ | Диск: ${disk_mb}МБ свободно"
    echo ""
  fi

  # --- Режим ---
  local wizard_mode="advanced"
  if [ "$HAS_WHIPTAIL" = true ]; then
    wizard_mode=$(whiptail --title "Режим установки" --menu "Выберите:" 12 60 3 \
      "quick"    "Быстрый (профиль + часовой пояс)" \
      "advanced" "Расширенный (все опции)" \
      "expert"   "Эксперт (компоненты + всё)" \
      3>&1 1>&2 2>&3) || { echo "Отменено."; exit 0; }
  else
    wizard_mode=$(text_menu "Режим установки" "Выберите:" \
      "quick" "Быстрый (профиль + пояс)" \
      "advanced" "Расширенный (все опции)" \
      "expert" "Эксперт (всё)") || wizard_mode="advanced"
  fi

  # --- Бенчмарк ---
  if [ "$wizard_mode" != "quick" ]; then
    local run_bench=false
    if [ "$HAS_WHIPTAIL" = true ]; then
      whiptail --title "Тест" --yesno "Запустить тест железа? (~30с)" 8 50 --defaultno && run_bench=true
    else
      text_yesno "Тест железа? (~30с)" "n" && run_bench=true
    fi
    if [ "$run_bench" = true ]; then
      do_benchmark
      [ -t 0 ] && { echo -en "\n   Нажмите Enter..." >&2; read -r; }
    fi
  fi

  # --- Профиль (пропуск если задан через --profile) ---
  if [ -z "$PROFILE" ]; then
    local prof=""
    if [ "$HAS_WHIPTAIL" = true ]; then
      prof=$(whiptail --title "Профиль" --menu "Выберите профиль:" 18 65 6 \
        "minimal"  "Только HA + Docker" \
        "standard" "Рекомендуемый" \
        "full"     "Полный + мониторинг" \
        "server"   "Сервер + стат. IP" \
        "dev"      "Для разработчиков" \
        "custom"   "Выбрать вручную" \
        3>&1 1>&2 2>&3) || { echo "Отменено."; exit 0; }
    else
      prof=$(text_menu "Профиль" "Выберите:" \
        "minimal" "Только HA + Docker" \
        "standard" "Рекомендуемый" \
        "full" "Полный + мониторинг" \
        "server" "Сервер + стат. IP" \
        "dev" "Для разработчиков" \
        "custom" "Вручную") || { echo "Отменено."; exit 0; }
    fi

    if [ "$prof" != "custom" ]; then
      apply_profile "$prof"
    else
      if [ "$HAS_WHIPTAIL" = true ]; then
        local ch
        ch=$(whiptail --title "Компоненты" --checklist "Пробел — переключить" 30 72 18 \
          "ZRAM" "ZRAM swap" ON "EMMC" "Тюнинг eMMC" ON "USBPOWER" "USB питание" ON \
          "UFW" "Файрвол" ON "SSHHARD" "Защита SSH" ON "AUTOUPD" "Автообновления" ON \
          "WATCHDOG" "Watchdog" ON "THERMAL" "Термомонитор" ON "BACKUP" "Бэкапы" ON \
          "HACS" "HACS" ON "HOSTNAME" "Имя хоста" ON "MONITOR" "Мониторинг" OFF \
          "USBDETECT" "Поиск USB" ON "BOOTRECOV" "Восст. загрузки" ON \
          "STATICIP" "Стат. IP" OFF "TELEGRAM" "Telegram" OFF \
          "REVPROXY" "Обр. прокси" OFF "RBACKUP" "Удал. бэкап" OFF \
          3>&1 1>&2 2>&3) || { echo "Отменено."; exit 0; }

        OPT_ZRAM=false; OPT_EMMC_TUNING=false; OPT_USB_POWER=false; OPT_UFW=false
        OPT_SSH_HARDENING=false; OPT_AUTOUPDATE=false; OPT_WATCHDOG=false; OPT_THERMAL=false
        OPT_BACKUP=false; OPT_HACS=false; OPT_HOSTNAME=false; OPT_STATIC_IP=false
        OPT_TELEGRAM=false; OPT_MONITORING=false; OPT_REVERSE_PROXY=false
        OPT_REMOTE_BACKUP=false; OPT_BOOT_RECOVERY=false; OPT_USB_DETECT=false

        [[ $ch == *ZRAM* ]]      && OPT_ZRAM=true;       [[ $ch == *EMMC* ]]      && OPT_EMMC_TUNING=true
        [[ $ch == *USBPOWER* ]]  && OPT_USB_POWER=true;  [[ $ch == *UFW* ]]       && OPT_UFW=true
        [[ $ch == *SSHHARD* ]]   && OPT_SSH_HARDENING=true; [[ $ch == *AUTOUPD* ]] && OPT_AUTOUPDATE=true
        [[ $ch == *WATCHDOG* ]]  && OPT_WATCHDOG=true;   [[ $ch == *THERMAL* ]]   && OPT_THERMAL=true
        [[ $ch == *BACKUP* ]]    && OPT_BACKUP=true;     [[ $ch == *HACS* ]]      && OPT_HACS=true
        [[ $ch == *HOSTNAME* ]]  && OPT_HOSTNAME=true;   [[ $ch == *STATICIP* ]]  && OPT_STATIC_IP=true
        [[ $ch == *TELEGRAM* ]]  && OPT_TELEGRAM=true;   [[ $ch == *MONITOR* ]]   && OPT_MONITORING=true
        [[ $ch == *REVPROXY* ]]  && OPT_REVERSE_PROXY=true; [[ $ch == *RBACKUP* ]] && OPT_REMOTE_BACKUP=true
        [[ $ch == *BOOTRECOV* ]] && OPT_BOOT_RECOVERY=true; [[ $ch == *USBDETECT* ]] && OPT_USB_DETECT=true
      else
        echo -e "\n   ${BOLD}Компоненты (д/н):${NC}" >&2
        text_yesno "ZRAM swap" "y"       && OPT_ZRAM=true       || OPT_ZRAM=false
        text_yesno "Тюнинг eMMC" "y"     && OPT_EMMC_TUNING=true || OPT_EMMC_TUNING=false
        text_yesno "Файрвол" "y"         && OPT_UFW=true         || OPT_UFW=false
        text_yesno "Защита SSH" "y"      && OPT_SSH_HARDENING=true || OPT_SSH_HARDENING=false
        text_yesno "Watchdog" "y"        && OPT_WATCHDOG=true    || OPT_WATCHDOG=false
        text_yesno "Бэкапы" "y"          && OPT_BACKUP=true      || OPT_BACKUP=false
        text_yesno "HACS" "y"            && OPT_HACS=true        || OPT_HACS=false
        text_yesno "Имя хоста" "y"       && OPT_HOSTNAME=true    || OPT_HOSTNAME=false
        text_yesno "Мониторинг" "n"      && OPT_MONITORING=true  || OPT_MONITORING=false
        text_yesno "Стат. IP" "n"        && OPT_STATIC_IP=true   || OPT_STATIC_IP=false
        text_yesno "Telegram" "n"        && OPT_TELEGRAM=true    || OPT_TELEGRAM=false
      fi
      PROFILE="custom"
    fi
  fi

  # --- Быстрый режим ---
  if [ "$wizard_mode" = "quick" ]; then
    if [ -z "$OPT_TIMEZONE" ]; then
      local curtz; curtz=$(timedatectl 2>/dev/null | awk '/Time zone/{print $3}') || curtz="UTC"
      if [ "$HAS_WHIPTAIL" = true ]; then
        OPT_TIMEZONE=$(whiptail --title "Часовой пояс" --inputbox "Часовой пояс:" 10 50 "$curtz" 3>&1 1>&2 2>&3) || OPT_TIMEZONE="$curtz"
      else
        OPT_TIMEZONE=$(text_input "Часовой пояс" "$curtz")
      fi
    fi
    local qs="Быстрая установка:\n  Профиль: ${PROFILE}\n  Часовой пояс: ${OPT_TIMEZONE}\n\nНачать?"
    if [ "$HAS_WHIPTAIL" = true ]; then
      whiptail --title "Подтверждение" --yesno "$qs" 12 50 || { echo "Отменено."; exit 0; }
    else
      echo -e "\n$qs" >&2; text_yesno "Начать?" "y" || { echo "Отменено."; exit 0; }
    fi
    return 0
  fi

  # === РАСШИРЕННЫЕ ОПЦИИ (пропуск если задано через CLI) ===

  # Часовой пояс
  if [ -z "$OPT_TIMEZONE" ]; then
    local curtz; curtz=$(timedatectl 2>/dev/null | awk '/Time zone/{print $3}') || curtz="UTC"
    if [ "$HAS_WHIPTAIL" = true ]; then
      OPT_TIMEZONE=$(whiptail --title "Часовой пояс" --inputbox "Например: Europe/Moscow\nТекущий: ${curtz}" 12 60 "$curtz" 3>&1 1>&2 2>&3) || OPT_TIMEZONE="$curtz"
    else
      OPT_TIMEZONE=$(text_input "Часовой пояс (текущий: ${curtz})" "$curtz")
    fi
  fi

  # Локаль (только эксперт)
  if [ -z "$OPT_LOCALE" ] && [ "$wizard_mode" = "expert" ]; then
    local curloc; curloc=$(locale 2>/dev/null | awk -F= '/^LANG=/{print $2}') || curloc="C.UTF-8"
    local set_locale=false
    if [ "$HAS_WHIPTAIL" = true ]; then
      whiptail --title "Локаль" --yesno "Сменить локаль?\nТекущая: ${curloc}" 10 50 --defaultno && set_locale=true
    else
      text_yesno "Сменить локаль? (текущая: ${curloc})" "n" && set_locale=true
    fi
    if [ "$set_locale" = true ]; then
      if [ "$HAS_WHIPTAIL" = true ]; then
        OPT_LOCALE=$(whiptail --title "Локаль" --inputbox "Например: ru_RU.UTF-8:" 10 50 "$curloc" 3>&1 1>&2 2>&3) || OPT_LOCALE=""
      else
        OPT_LOCALE=$(text_input "Локаль (напр. ru_RU.UTF-8)" "$curloc")
      fi
    fi
  fi

  # Swap
  if [ -z "$OPT_SWAP_SIZE" ]; then
    local swap_rec="zram"
    [ "$ram_mb" -lt 1500 ] && swap_rec="2048"
    [ "$ram_mb" -gt 4000 ] && swap_rec="none"
    if [ "$HAS_WHIPTAIL" = true ]; then
      OPT_SWAP_SIZE=$(whiptail --title "Swap" --menu "RAM: ${ram_mb}МБ. Рекомендуется: ${swap_rec}" 16 60 5 \
        "zram" "ZRAM в RAM (2-4ГБ)" "1024" "Файл 1ГБ" "2048" "Файл 2ГБ (мало RAM)" \
        "4096" "Файл 4ГБ" "none" "Без swap (4ГБ+)" \
        3>&1 1>&2 2>&3) || OPT_SWAP_SIZE="$swap_rec"
    else
      OPT_SWAP_SIZE=$(text_menu "Swap (RAM: ${ram_mb}МБ, рек: ${swap_rec})" "Выберите:" \
        "zram" "ZRAM" "1024" "1ГБ" "2048" "2ГБ" "none" "Без swap") || OPT_SWAP_SIZE="$swap_rec"
    fi
  fi

  # Внешний диск
  if [ -z "$OPT_DATA_DIR" ]; then
    local disk_warn=""
    [ "$disk_mb" -lt 20000 ] && disk_warn=" (ВНИМАНИЕ: только ${disk_mb}МБ свободно!)"
    local use_ext=false
    if [ "$HAS_WHIPTAIL" = true ]; then
      whiptail --title "Внешний диск" --yesno "Использовать внешний диск?${disk_warn}\n\nПеренесёт Docker+HA на внешний носитель." 12 60 --defaultno && use_ext=true
    else
      text_yesno "Внешний диск для данных?${disk_warn}" "n" && use_ext=true
    fi
    if [ "$use_ext" = true ]; then
      local mounts_info
      mounts_info=$(lsblk -o NAME,SIZE,MOUNTPOINT,FSTYPE 2>/dev/null | grep -E "sd|nvme" | head -10)
      if [ "$HAS_WHIPTAIL" = true ]; then
        OPT_DATA_DIR=$(whiptail --title "Путь к данным" --inputbox "Путь монтирования:\n\n${mounts_info}" 18 70 "/mnt/data" 3>&1 1>&2 2>&3) || OPT_DATA_DIR=""
      else
        [ -n "$mounts_info" ] && { echo -e "\n   Обнаруженные диски:" >&2; echo "$mounts_info" | while IFS= read -r l; do echo "   $l" >&2; done; }
        OPT_DATA_DIR=$(text_input "Путь к каталогу данных" "/mnt/data")
      fi
    fi
  fi

  # WiFi
  if [ -z "$OPT_WIFI_SSID" ]; then
    local has_wifi=false
    { iw dev 2>/dev/null | grep -q Interface || ip link 2>/dev/null | grep -q wlan; } && has_wifi=true
    if [ "$has_wifi" = true ]; then
      local setup_wifi_now=false
      if [ "$HAS_WHIPTAIL" = true ]; then
        whiptail --title "WiFi" --yesno "Обнаружен WiFi-адаптер. Настроить?" 8 50 --defaultno && setup_wifi_now=true
      else
        text_yesno "WiFi-адаптер найден. Настроить?" "n" && setup_wifi_now=true
      fi
      if [ "$setup_wifi_now" = true ]; then
        local wifi_list
        wifi_list=$(nmcli -t -f SSID dev wifi list 2>/dev/null | sort -u | head -10 | tr '\n' ', ') || wifi_list=""
        if [ "$HAS_WHIPTAIL" = true ]; then
          OPT_WIFI_SSID=$(whiptail --title "WiFi SSID" --inputbox "Имя сети:\n\nРядом: ${wifi_list}" 14 60 3>&1 1>&2 2>&3) || OPT_WIFI_SSID=""
          [ -n "$OPT_WIFI_SSID" ] && {
            OPT_WIFI_PASS=$(whiptail --title "Пароль WiFi" --passwordbox "Пароль:" 10 50 3>&1 1>&2 2>&3) || OPT_WIFI_SSID=""
          }
        else
          [ -n "$wifi_list" ] && echo -e "   Рядом: ${wifi_list}" >&2
          OPT_WIFI_SSID=$(text_input "SSID" "")
          [ -n "$OPT_WIFI_SSID" ] && OPT_WIFI_PASS=$(text_password "Пароль WiFi")
        fi
      fi
    fi
  fi

  # Зеркало Docker (только эксперт)
  if [ -z "$OPT_DOCKER_MIRROR" ] && [ "$wizard_mode" = "expert" ]; then
    local use_mirror=false
    if [ "$HAS_WHIPTAIL" = true ]; then
      whiptail --title "Зеркало Docker" --yesno "Использовать зеркало?\n(Только если Docker Hub заблокирован)" 10 60 --defaultno && use_mirror=true
    else
      text_yesno "Зеркало Docker? (если заблокирован)" "n" && use_mirror=true
    fi
    if [ "$use_mirror" = true ]; then
      if [ "$HAS_WHIPTAIL" = true ]; then
        OPT_DOCKER_MIRROR=$(whiptail --title "URL зеркала" --inputbox "URL:" 10 65 3>&1 1>&2 2>&3) || OPT_DOCKER_MIRROR=""
      else
        OPT_DOCKER_MIRROR=$(text_input "URL зеркала Docker" "")
      fi
    fi
  fi

  # Уведомления
  if [ "$OPT_TELEGRAM" != true ] && [ -z "$OPT_WEBHOOK_URL" ]; then
    local notif=""
    if [ "$HAS_WHIPTAIL" = true ]; then
      notif=$(whiptail --title "Уведомления" --menu "Способ оповещения:" 16 60 5 \
        "none" "Без уведомлений" "telegram" "Telegram" "ntfy" "ntfy.sh (бесплатно)" \
        "discord" "Discord" "custom" "Свой webhook" \
        3>&1 1>&2 2>&3) || notif="none"
    else
      notif=$(text_menu "Уведомления" "Способ:" \
        "none" "Без уведомлений" "telegram" "Telegram" "ntfy" "ntfy.sh" \
        "discord" "Discord" "custom" "Свой URL") || notif="none"
    fi
    case "$notif" in
      telegram)
        OPT_TELEGRAM=true
        if [ "$HAS_WHIPTAIL" = true ]; then
          TG_TOKEN=$(whiptail --title "Telegram" --inputbox "Токен бота:" 10 60 3>&1 1>&2 2>&3) || TG_TOKEN=""
          TG_CHAT=$(whiptail --title "Telegram" --inputbox "Chat ID:" 10 60 3>&1 1>&2 2>&3) || TG_CHAT=""
        else
          TG_TOKEN=$(text_input "Токен бота" "")
          TG_CHAT=$(text_input "Chat ID" "")
        fi
        { [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ]; } && OPT_TELEGRAM=false
        ;;
      ntfy)
        local topic
        if [ "$HAS_WHIPTAIL" = true ]; then
          topic=$(whiptail --title "ntfy.sh" --inputbox "Название темы:" 10 50 "ha-$(hostname 2>/dev/null || echo box)" 3>&1 1>&2 2>&3) || topic=""
        else
          topic=$(text_input "Тема ntfy.sh" "ha-$(hostname 2>/dev/null || echo box)")
        fi
        [ -n "$topic" ] && OPT_WEBHOOK_URL="https://ntfy.sh/${topic}"
        ;;
      discord|custom)
        if [ "$HAS_WHIPTAIL" = true ]; then
          OPT_WEBHOOK_URL=$(whiptail --title "Webhook URL" --inputbox "URL:" 10 70 3>&1 1>&2 2>&3) || OPT_WEBHOOK_URL=""
        else
          OPT_WEBHOOK_URL=$(text_input "Webhook URL" "")
        fi
        ;;
    esac
  fi

  # Восстановление бэкапа
  if [ -z "$OPT_RESTORE_BACKUP" ]; then
    local do_restore=false
    if [ "$HAS_WHIPTAIL" = true ]; then
      whiptail --title "Восстановление" --yesno "Восстановить бэкап после установки?" 8 50 --defaultno && do_restore=true
    else
      text_yesno "Восстановить бэкап после установки?" "n" && do_restore=true
    fi
    if [ "$do_restore" = true ]; then
      local found=""
      for d in /mnt /media /tmp /var/backups; do
        local fb
        fb=$(find "$d" -maxdepth 3 -name "ha_config_*.tar.gz" -type f 2>/dev/null | head -3)
        [ -n "$fb" ] && found="${found}${fb}"$'\n'
      done
      if [ "$HAS_WHIPTAIL" = true ]; then
        local hint=""
        [ -n "$found" ] && hint="\nНайдены:\n${found}"
        OPT_RESTORE_BACKUP=$(whiptail --title "Файл бэкапа" --inputbox "Путь к .tar.gz:${hint}" 16 70 3>&1 1>&2 2>&3) || OPT_RESTORE_BACKUP=""
      else
        [ -n "$found" ] && { echo -e "   Найденные бэкапы:" >&2; echo "$found" | while IFS= read -r l; do [ -n "$l" ] && echo "   $l" >&2; done; }
        OPT_RESTORE_BACKUP=$(text_input "Путь к бэкапу (.tar.gz)" "")
      fi
      [ -n "$OPT_RESTORE_BACKUP" ] && [ ! -f "$OPT_RESTORE_BACKUP" ] && {
        msg_warn "Файл не найден: ${OPT_RESTORE_BACKUP}"
        OPT_RESTORE_BACKUP=""
      }
    fi
  fi

  # Статический IP
  if [ "$OPT_STATIC_IP" = true ] && [ -z "$STATIC_IP" ]; then
    local cip2; cip2=$(hostname -I 2>/dev/null | awk '{print $1}') || cip2=""
    local cgw2; cgw2=$(ip route 2>/dev/null | awk '/default/{print $3}' | head -1) || cgw2=""
    while true; do
      if [ "$HAS_WHIPTAIL" = true ]; then
        STATIC_IP=$(whiptail --title "Статический IP" --inputbox "IP-адрес:" 10 50 "$cip2" 3>&1 1>&2 2>&3) || { OPT_STATIC_IP=false; break; }
      else
        STATIC_IP=$(text_input "Статический IP" "$cip2"); [ -z "$STATIC_IP" ] && { OPT_STATIC_IP=false; break; }
      fi
      validate_ip "$STATIC_IP" && break; msg_warn "Неверный IP"
    done
    if [ "$OPT_STATIC_IP" = true ]; then
      while true; do
        if [ "$HAS_WHIPTAIL" = true ]; then
          STATIC_GW=$(whiptail --title "Шлюз" --inputbox "Шлюз:" 10 50 "$cgw2" 3>&1 1>&2 2>&3) || { STATIC_GW="$cgw2"; break; }
        else
          STATIC_GW=$(text_input "Шлюз" "$cgw2")
        fi
        validate_gw "$STATIC_GW" && break; msg_warn "Неверный шлюз"
      done
      while true; do
        if [ "$HAS_WHIPTAIL" = true ]; then
          STATIC_DNS=$(whiptail --title "DNS" --inputbox "DNS (через запятую):" 10 50 "8.8.8.8,1.1.1.1" 3>&1 1>&2 2>&3) || { STATIC_DNS="8.8.8.8,1.1.1.1"; break; }
        else
          STATIC_DNS=$(text_input "DNS (через запятую)" "8.8.8.8,1.1.1.1")
        fi
        validate_dns_list "$STATIC_DNS" && break; msg_warn "Неверный DNS"
      done
    fi
  fi

  # Обратный прокси
  [ "$OPT_REVERSE_PROXY" = true ] && [ -z "$PROXY_DOMAIN" ] && {
    if [ "$HAS_WHIPTAIL" = true ]; then
      PROXY_DOMAIN=$(whiptail --title "Прокси" --inputbox "Домен:" 10 60 3>&1 1>&2 2>&3) || OPT_REVERSE_PROXY=false
    else
      PROXY_DOMAIN=$(text_input "Домен прокси" ""); [ -z "$PROXY_DOMAIN" ] && OPT_REVERSE_PROXY=false
    fi
  }

  # Удалённый бэкап
  [ "$OPT_REMOTE_BACKUP" = true ] && [ -z "$REMOTE_BACKUP_TARGET" ] && {
    if [ "$HAS_WHIPTAIL" = true ]; then
      REMOTE_BACKUP_TARGET=$(whiptail --title "Удал. бэкап" --inputbox "ssh://user@host:/path:" 10 70 3>&1 1>&2 2>&3) || OPT_REMOTE_BACKUP=false
    else
      REMOTE_BACKUP_TARGET=$(text_input "Удал. бэкап (ssh://...)" ""); [ -z "$REMOTE_BACKUP_TARGET" ] && OPT_REMOTE_BACKUP=false
    fi
  }

  # Авто-перезагрузка
  if [ "$OPT_AUTO_REBOOT" != true ]; then
    if [ "$HAS_WHIPTAIL" = true ]; then
      whiptail --title "Авто-перезагрузка" --yesno "Разрешить авто-перезагрузку при необходимости?\n(AppArmor может потребовать)" 10 55 && OPT_AUTO_REBOOT=true
    else
      text_yesno "Авто-перезагрузка при необходимости?" "y" && OPT_AUTO_REBOOT=true
    fi
  fi

  # === ПОДТВЕРЖДЕНИЕ ===
  local s="Установка Home Assistant Supervised\n\n"
  s+="  Профиль:     ${PROFILE}\n"
  s+="  Часовой пояс: ${OPT_TIMEZONE:-авто}\n"
  s+="  Swap:         ${OPT_SWAP_SIZE:-zram}\n"
  [ -n "$OPT_DATA_DIR" ]         && s+="  Данные:       ${OPT_DATA_DIR}\n"
  [ -n "$OPT_WIFI_SSID" ]        && s+="  WiFi:         ${OPT_WIFI_SSID}\n"
  [ -n "$OPT_DOCKER_MIRROR" ]    && s+="  Зеркало:      да\n"
  [ -n "$OPT_RESTORE_BACKUP" ]   && s+="  Восстановить: $(basename "$OPT_RESTORE_BACKUP")\n"
  [ -n "$OPT_LOCALE" ]           && s+="  Локаль:       ${OPT_LOCALE}\n"
  [ "$OPT_AUTO_REBOOT" = true ]  && s+="  Перезагрузка: авто\n"
  [ "$OPT_TELEGRAM" = true ]     && s+="  Telegram:     да\n"
  [ -n "$OPT_WEBHOOK_URL" ]      && s+="  Webhook:      да\n"
  [ "$OPT_STATIC_IP" = true ]    && s+="  IP:           ${STATIC_IP}\n"
  s+="\nНачать установку?"

  if [ "$HAS_WHIPTAIL" = true ]; then
    whiptail --title "Подтверждение" --yesno "$s" 28 60 || { echo "Отменено."; exit 0; }
  else
    echo -e "\n$s" >&2
    text_yesno "Начать?" "y" || { echo "Отменено."; exit 0; }
  fi
}

# ============================================================================
# ГЛАВНОЕ МЕНЮ
# ============================================================================
show_main_menu() {
  # Нужен интерактивный терминал
  [ ! -t 0 ] && return 1
  [ ! -t 1 ] && return 1

  local choice
  if command -v whiptail &>/dev/null; then
    # Проверить что whiptail может работать
    choice=$(whiptail --title "HA Установщик v${SCRIPT_VERSION}" --menu "Действие:" 22 60 14 \
      "install"   "Установить HA Supervised" \
      "check"     "Диагностика" \
      "status"    "Мониторинг (live)" \
      "update"    "Обновить HA + OS-Agent" \
      "backup"    "Создать бэкап" \
      "restore"   "Восстановить бэкап" \
      "health"    "Отчёт о здоровье" \
      "benchmark" "Тест железа" \
      "export"    "Экспорт конфига" \
      "history"   "История запусков" \
      "uninstall" "Удалить HA" \
      "selftest"  "Самотест" \
      "help"      "Помощь" \
      3>&1 1>&2 2>&3) || return 1
  else
    choice=$(text_menu "HA Установщик v${SCRIPT_VERSION}" "Действие:" \
      "install"   "Установить HA" \
      "check"     "Диагностика" \
      "status"    "Мониторинг" \
      "update"    "Обновить HA" \
      "backup"    "Создать бэкап" \
      "restore"   "Восстановить бэкап" \
      "health"    "Отчёт о здоровье" \
      "benchmark" "Тест железа" \
      "export"    "Экспорт конфига" \
      "history"   "История" \
      "uninstall" "Удалить" \
      "selftest"  "Самотест" \
      "help"      "Помощь") || return 1
  fi

  # Если whiptail вернул пустоту (не смог отобразить)
  [ -z "$choice" ] && return 1

  case "$choice" in
    install)   RUN_WIZARD=true;;
    check)     CHECK_ONLY=true; RUN_WIZARD=false;;
    status)    SHOW_STATUS=true; RUN_WIZARD=false;;
    update)    DO_UPDATE=true; RUN_WIZARD=false;;
    backup)
      if [ -x /usr/local/bin/ha-backup ]; then /usr/local/bin/ha-backup; exit $?
      else msg_error "ha-backup не установлен"; exit 1; fi;;
    restore)
      if [ -x /usr/local/bin/ha-restore ]; then /usr/local/bin/ha-restore; exit $?
      else msg_error "ha-restore не установлен"; exit 1; fi;;
    health)
      if [ -x /usr/local/bin/ha-health ]; then /usr/local/bin/ha-health; exit $?
      else msg_error "ha-health не установлен"; exit 1; fi;;
    benchmark) DO_BENCHMARK=true; RUN_WIZARD=false;;
    export)    DO_EXPORT_CONFIG=true; RUN_WIZARD=false;;
    history)   DO_SHOW_HISTORY=true; RUN_WIZARD=false;;
    uninstall) UNINSTALL=true; RUN_WIZARD=false;;
    selftest)  DO_SELF_TEST=true; RUN_WIZARD=false;;
    help)      show_help; exit 0;;
  esac
}

# ============================================================================
# ШАГ: ПРЕДВАРИТЕЛЬНАЯ ПРОВЕРКА
# ============================================================================
step_preflight() {
  local sid="preflight"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] ПРЕДВАРИТЕЛЬНАЯ ПРОВЕРКА"
  detect_system_info; local err=0 wrn=0

  [ "$CACHED_ARCH" = "unknown" ] && { msg_error "Архитектура: ${CACHED_MACHINE_ARCH}"; err=$((err+1)); } \
    || msg_ok "Архитектура: ${CACHED_MACHINE_ARCH} (${CACHED_ARCH})"
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

  # Проверка версии Docker если уже установлен
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
  [ -n "$OPT_RESTORE_BACKUP" ] && [ ! -f "$OPT_RESTORE_BACKUP" ] && { msg_error "Бэкап не найден: ${OPT_RESTORE_BACKUP}"; err=$((err+1)); }

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
  setup_timezone
  setup_locale
  setup_wifi
  if [ "$SKIP_UPDATE" = false ]; then
    run_cmd_fatal "apt update" apt_safe update -y
    run_cmd "apt upgrade" apt_safe upgrade -y -o Dpkg::Options::="--force-confold"
  else
    msg_warn "Пропущено (--skip-update)"
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
    libglib2.0-bin network-manager nfs-common systemd-timesyncd udisks2 usbutils wget qrencode)

  for p in lsb-release systemd-resolved systemd-journal-remote; do
    pkg_available "$p" && pkgs+=("$p")
  done

  if [ "$OPT_ZRAM" = true ]; then
    if is_armbian && is_pkg_installed armbian-zram-config; then true
    elif pkg_available zram-tools; then pkgs+=(zram-tools)
    elif pkg_available systemd-zram-generator; then pkgs+=(systemd-zram-generator)
    fi
  fi

  [ "$OPT_UFW" = true ]           && pkgs+=(ufw fail2ban)
  [ "$OPT_AUTOUPDATE" = true ]    && pkgs+=(unattended-upgrades)
  [ "$OPT_BACKUP" = true ]        && pkg_available pigz && pkgs+=(pigz)
  [ "$OPT_REVERSE_PROXY" = true ] && pkgs+=(nginx certbot python3-certbot-nginx)

  is_armbian && systemctl is-active --quiet armbian-hardware-optimization 2>/dev/null || {
    for p in linux-cpupower cpufrequtils; do pkg_available "$p" && pkgs+=("$p"); done
  }

  local ti=()
  for p in "${pkgs[@]}"; do is_pkg_installed "$p" || ti+=("$p"); done

  if [ ${#ti[@]} -eq 0 ]; then
    msg_ok "Все пакеты установлены"
  else
    apt_wait_lock || { msg_error "apt заблокирован"; return 1; }
    local total=${#ti[@]} f=()
    msg_action "Установка ${total} пакетов..."
    if apt_safe install -y "${ti[@]}" &>/dev/null; then
      msg_ok "Установлено: ${total}"
    else
      msg_warn "Пакетная установка не удалась, поштучно..."
      local i=0
      for p in "${ti[@]}"; do
        i=$((i+1)); progress_bar $i $total "$p"
        apt_safe install -y "$p" &>/dev/null || f+=("$p")
      done
      progress_clear
      [ ${#f[@]} -gt 0 ] && msg_warn "Не установлены: ${f[*]}" || msg_ok "Установлено: ${total}"
    fi
  fi

  run_cmd "apt fix" apt_safe -f install -y
  [ "$OPT_EMMC_TUNING" = true ] && apt-get clean 2>/dev/null || true
  setup_swap
  mark_done "$sid"
}

# ============================================================================
# ШАГ: СЕТЬ
# ============================================================================
step_configure_network() {
  local sid="network"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] НАСТРОЙКА СЕТИ"

  mkdir -p "$BACKUP_DIR" /etc/NetworkManager/conf.d
  push_rollback 'rollback_network'

  local cip; cip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -n "$cip" ] && msg_info "Текущий IP: ${cip}"

  printf '[keyfile]\nunmanaged-devices=none\n[device]\nwifi.scan-rand-mac-address=no\n' \
    > /etc/NetworkManager/conf.d/10-ha-managed.conf
  printf '[main]\ndns=systemd-resolved\n' \
    > /etc/NetworkManager/conf.d/10-dns-resolved.conf

  [ -f /etc/network/interfaces ] && cp /etc/network/interfaces "$BACKUP_DIR/interfaces.bak" 2>/dev/null
  printf 'source /etc/network/interfaces.d/*\nauto lo\niface lo inet loopback\n' > /etc/network/interfaces

  systemctl is-active --quiet systemd-resolved 2>/dev/null || {
    systemctl enable systemd-resolved 2>/dev/null || true
    systemctl start systemd-resolved 2>/dev/null || true
  }

  local rt; rt=$(readlink -f /etc/resolv.conf 2>/dev/null)
  [[ "$rt" != */run/systemd/resolve/* ]] && {
    cp /etc/resolv.conf "${BACKUP_DIR}/resolv.conf.bak" 2>/dev/null
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null
  }

  if who 2>/dev/null | grep -q pts; then
    msg_warn "SSH-сессия! Переключение сети через 15с..."
    sleep 15
  fi

  systemctl list-unit-files networking.service &>/dev/null && \
    systemctl is-active --quiet networking 2>/dev/null && \
    systemctl disable networking 2>/dev/null || true
  systemctl enable NetworkManager 2>/dev/null || true
  systemctl restart NetworkManager 2>/dev/null || true

  if [ "$OPT_STATIC_IP" = true ] && [ -n "$STATIC_IP" ]; then
    sleep 3
    local ac; ac=$(nmcli -t -f NAME con show --active 2>/dev/null | head -1)
    [ -n "$ac" ] && {
      local pf; pf=$(get_current_prefix); [ -z "$pf" ] && pf="24"
      nmcli con mod "$ac" ipv4.addresses "${STATIC_IP}/${pf}" \
        ipv4.gateway "$STATIC_GW" ipv4.dns "$STATIC_DNS" ipv4.method manual 2>/dev/null
      nmcli con up "$ac" 2>/dev/null
      msg_ok "Стат. IP: ${STATIC_IP}/${pf}"
    }
  fi

  local r=0 ni=""
  while [ $r -lt 6 ]; do
    sleep 5
    ni=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -n "$ni" ] && { msg_ok "Сеть: ${ni}"; break; }
    r=$((r+1))
  done

  if [ $r -ge 6 ]; then
    rollback_network; sleep 5
    ni=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -n "$ni" ] && msg_ok "Восстановлено: ${ni}" || { msg_error "Нет сети!"; return 1; }
  fi

  mark_done "$sid"
}

# ============================================================================
# ШАГ: APPARMOR
# ============================================================================
step_configure_apparmor() {
  local sid="apparmor"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] APPARMOR"

  local aa; aa=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) || aa="N"

  if [ "$aa" = "Y" ]; then
    msg_ok "AppArmor активен"
  else
    local patched=false
    for f in /boot/armbianEnv.txt /boot/uEnv.txt /boot/extlinux/extlinux.conf; do
      [ -f "$f" ] || continue
      cp "$f" "${BACKUP_DIR}/$(basename "$f").bak" 2>/dev/null
      grep -q "apparmor=1" "$f" && { patched=true; continue; }
      if [[ "$f" == *extlinux.conf ]]; then
        sed -i '/^[[:space:]]*append/ s/$/ apparmor=1 security=apparmor/' "$f"
      else
        grep -q "^extraargs=" "$f" && \
          sed -i 's|^extraargs=.*|& apparmor=1 security=apparmor|' "$f" || \
          echo "extraargs=apparmor=1 security=apparmor" >> "$f"
      fi
      msg_ok "$(basename "$f")"
      patched=true
    done

    if [ "$patched" = true ]; then
      msg_warn "AppArmor требует перезагрузки"
      if [ "$OPT_AUTO_REBOOT" = true ]; then
        msg_action "Авто-перезагрузка через 10с..."
        if setup_reboot_continue; then
          sleep 10
          reboot
          exit 0
        else
          msg_warn "Не удалось настроить продолжение, работаем дальше"
        fi
      fi
    else
      msg_error "Конфиг загрузчика не найден"
    fi
  fi

  systemctl enable apparmor 2>/dev/null || true
  systemctl start apparmor 2>/dev/null || true
  mark_done "$sid"
}

# ============================================================================
# ШАГ: ПРОИЗВОДИТЕЛЬНОСТЬ
# ============================================================================
step_performance() {
  local sid="perf"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] ПРОИЗВОДИТЕЛЬНОСТЬ"

  # ZRAM
  if [ "$OPT_ZRAM" = true ]; then
    [ -f /swapfile ] && [ "$OPT_SWAP_SIZE" != "none" ] && {
      swapoff /swapfile 2>/dev/null; rm -f /swapfile; sed -i '/swapfile/d' /etc/fstab
    }

    if is_armbian && is_pkg_installed armbian-zram-config; then
      msg_ok "ZRAM: Armbian"
    elif is_pkg_installed zram-tools; then
      printf 'ALGO=lz4\nPERCENT=60\n' > /etc/default/zramswap
      systemctl enable zramswap 2>/dev/null || true
      systemctl restart zramswap 2>/dev/null || true
      msg_ok "ZRAM"
    elif is_pkg_installed systemd-zram-generator; then
      mkdir -p /etc/systemd/zram-generator.conf.d
      printf '[zram0]\nzram-size = ram * 0.6\ncompression-algorithm = lz4\n' \
        > /etc/systemd/zram-generator.conf.d/ha.conf
      schedule_daemon_reload; flush_daemon_reload
      msg_ok "ZRAM"
    elif modprobe zram 2>/dev/null && [ -b /dev/zram0 ]; then
      local rb; rb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
      echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
      echo $((rb*1024*60/100)) > /sys/block/zram0/disksize 2>/dev/null || true
      mkswap /dev/zram0 >/dev/null 2>&1 && swapon -p 100 /dev/zram0 2>/dev/null
      msg_ok "ZRAM (вручную)"
    else
      msg_warn "ZRAM недоступен"
    fi
  fi

  # CPU
  if is_armbian && systemctl is-active --quiet armbian-hardware-optimization 2>/dev/null; then
    msg_dim "CPU: управляется Armbian"
  elif command -v cpupower &>/dev/null; then
    cpupower frequency-set -g schedutil 2>/dev/null || cpupower frequency-set -g ondemand 2>/dev/null || true
    msg_ok "CPU: schedutil"
  elif command -v cpufreq-set &>/dev/null; then
    echo 'GOVERNOR="schedutil"' > /etc/default/cpufrequtils
    msg_ok "CPU: schedutil"
  else
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
      [ -f "$g" ] && { echo schedutil > "$g" 2>/dev/null || echo ondemand > "$g" 2>/dev/null; }
    done
  fi

  # eMMC
  if [ "$OPT_EMMC_TUNING" = true ]; then
    echo "vm.swappiness=10" > /etc/sysctl.d/99-ha-swap.conf
    sysctl -p /etc/sysctl.d/99-ha-swap.conf >/dev/null 2>&1 || true

    grep -q noatime /etc/fstab 2>/dev/null || {
      cp /etc/fstab "${BACKUP_DIR}/fstab.bak" 2>/dev/null
      sed -i '/^\//s/defaults/defaults,noatime,commit=600/' /etc/fstab 2>/dev/null || true
    }

    mkdir -p /etc/systemd/journald.conf.d
    is_armbian && is_pkg_installed armbian-ramlog || {
      printf '[Journal]\nSystemMaxUse=50M\nSystemMaxFileSize=10M\nMaxRetentionSec=7day\nCompress=yes\nStorage=persistent\nSystemKeepFree=100M\n' \
        > /etc/systemd/journald.conf.d/ha-tuning.conf
      systemctl restart systemd-journald 2>/dev/null || true
    }

    local rd="" rs=""
    rs=$(findmnt -n -o SOURCE / 2>/dev/null)
    [ -n "$rs" ] && [ -b "$rs" ] && rd=$(lsblk -no PKNAME "$rs" 2>/dev/null | head -1)
    if [ -n "$rd" ] && [ "$(cat "/sys/block/${rd}/queue/rotational" 2>/dev/null)" = "0" ]; then
      [[ "$rd" == nvme* ]] && echo none > "/sys/block/${rd}/queue/scheduler" 2>/dev/null || true
      [[ "$rd" == mmcblk* || "$rd" == sd* ]] && echo mq-deadline > "/sys/block/${rd}/queue/scheduler" 2>/dev/null || true
    fi
    msg_ok "Тюнинг eMMC"
  fi

  # USB
  [ "$OPT_USB_POWER" = true ] && {
    for d in /sys/bus/usb/devices/*/power/autosuspend; do
      [ -f "$d" ] && echo -1 > "$d" 2>/dev/null
    done
    echo 'ACTION=="add", SUBSYSTEM=="usb", ATTR{power/autosuspend}="-1"' \
      > /etc/udev/rules.d/99-ha-usb-power.rules
    udevadm control --reload-rules 2>/dev/null || true
    msg_ok "USB питание"
  }

  mark_done "$sid"
}

# ============================================================================
# ШАГ: DOCKER
# ============================================================================
step_install_docker() {
  local sid="docker"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] DOCKER"

  require_disk_space 2000 "Docker" || { msg_error "Нет места для Docker"; exit 1; }
  push_rollback 'apt-get remove -y docker-ce docker-ce-cli containerd.io 2>/dev/null; rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc'
  setup_docker_mirror

  if command -v docker &>/dev/null; then
    msg_ok "Docker: $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
    local drv; drv=$(docker info --format '{{.Driver}}' 2>/dev/null || echo "unknown")
    msg_info "Storage driver: ${drv}"
    [ "$drv" != "overlay2" ] && msg_warn "Рекомендуется overlay2 (сейчас: ${drv})"
  else
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    detect_system_info
    local codename="${CACHED_CODENAME}"
    [[ "$codename" == "trixie" ]] && codename="bookworm"

    local docker_ok=false
    if command -v curl &>/dev/null; then
      spinner_start "Docker (официальный репо)"
      install -m 0755 -d /etc/apt/keyrings 2>/dev/null
      if curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc 2>/dev/null; then
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${codename} stable" \
          > /etc/apt/sources.list.d/docker.list
        apt-get update -qq 2>/dev/null
        apt_safe install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin &>/dev/null && docker_ok=true
      fi
      spinner_stop
    fi

    if [ "$docker_ok" = false ]; then
      msg_warn "Официальный репо не сработал -> get.docker.com"
      spinner_start "Docker (get.docker.com)"
      curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || { spinner_stop; msg_error "Docker не установился!"; exit 1; }
      spinner_stop
    fi

    hash -r 2>/dev/null
    msg_ok "Docker установлен"
    local drv; drv=$(docker info --format '{{.Driver}}' 2>/dev/null || echo "unknown")
    msg_info "Storage driver: ${drv}"
  fi

  mkdir -p /etc/docker
  [ ! -f /etc/docker/daemon.json ] && \
    echo '{"log-driver":"journald","storage-driver":"overlay2"}' > /etc/docker/daemon.json

  systemctl enable docker 2>/dev/null || true
  systemctl restart docker 2>/dev/null || true

  local dw=0
  while ! docker info &>/dev/null; do
    sleep 2; dw=$((dw+2))
    [ $dw -ge 30 ] && { msg_error "Docker не запустился!"; exit 1; }
  done

  setup_data_dir
  prefetch_docker_images
  mark_done "$sid"
}

# ============================================================================
# ШАГ: ВЕРСИИ
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
# ШАГ: ЗАГРУЗКА
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
# ШАГ: HOME ASSISTANT SUPERVISED
# ============================================================================
step_install_ha() {
  local sid="ha"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] HOME ASSISTANT SUPERVISED"

  require_disk_space 1500 "HA" || { msg_error "Нет места для HA"; exit 1; }
  mkdir -p "$BACKUP_DIR"
  push_rollback 'dpkg --purge homeassistant-supervised 2>/dev/null'

  if os_release_needs_faking; then
    msg_warn "Подмена os-release"
    fake_os_release
  else
    msg_ok "os-release OK"
    backup_os_release
  fi

  wait_prefetch
  msg_action "Установка HA (5-15 мин)..."
  msg_dim "Машина: ${HA_MACHINE}"
  export MACHINE="$HA_MACHINE"

  set +o pipefail
  DEBIAN_FRONTEND=noninteractive dpkg -i "${HA_TMP}/ha.deb" 2>&1 \
    | grep --line-buffered -iE "(pull|download|unpack|setting up|error|warn)" \
    | grep -vi "cgroup v1" \
    | while IFS= read -r l; do echo -e "   ${BLUE}|${NC} ${l}"; done
  local -a _ps=("${PIPESTATUS[@]}")
  local de=${_ps[0]}
  set -o pipefail

  [ $de -ne 0 ] && { msg_warn "dpkg код ${de}"; apt-get install -f -y >/dev/null 2>&1 || true; }

  if [ "$OS_RELEASE_FAKED" = true ]; then
    mkdir -p /etc/systemd/system/hassio-supervisor.service.d
    cat > /etc/systemd/system/hassio-supervisor.service.d/fix-os-release.conf << DROPIN
[Service]
ExecStartPre=/bin/bash -c 'F="${BACKUP_DIR}/os-release.faked"; [ -f "\$F" ] && cp "\$F" /etc/os-release'
ExecStopPost=/bin/bash -c 'O="${BACKUP_DIR}/os-release.original"; [ -f "\$O" ] && cp "\$O" /etc/os-release'
DROPIN
    schedule_daemon_reload
    flush_daemon_reload
    restore_os_release
    msg_info "Drop-in: подмена при старте, восстановление при остановке"
  fi

  msg_action "Ожидание supervisor..."
  local sw=0
  while ! systemctl is-active --quiet hassio-supervisor 2>/dev/null; do
    sleep 5; sw=$((sw+5))
    [ $sw -ge 120 ] && { msg_warn "Таймаут ожидания supervisor"; break; }
    [ $((sw%15)) -eq 0 ] && msg_dim "${sw}с..."
  done
  [ $sw -lt 120 ] && msg_ok "hassio-supervisor активен"

  touch "$GRACE_MARKER"
  save_config
  msg_ok "HA Supervised установлен"
  mark_done "$sid"
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
    ufw status 2>/dev/null | grep -q "Status: active" || {
      ufw --force reset >/dev/null 2>&1
      ufw default deny incoming >/dev/null 2>&1
      ufw default allow outgoing >/dev/null 2>&1
      ufw default allow routed >/dev/null 2>&1
    }

    for r in "22/tcp SSH" "8123/tcp HA" "4357/tcp ESPHome" "5353/udp mDNS" "5683/udp HomeKit"; do
      local port="${r%% *}"
      ufw status 2>/dev/null | grep -q "$port" || ufw allow "$port" comment "${r#* }" >/dev/null 2>&1
    done
    [ "$OPT_REVERSE_PROXY" = true ] && {
      ufw status 2>/dev/null | grep -q "443/tcp" || ufw allow 443/tcp comment "HTTPS" >/dev/null 2>&1
    }
    ufw --force enable >/dev/null 2>&1
    msg_ok "UFW"

    if ! grep -q "# BEGIN HA-INSTALLER DOCKER-USER" /etc/ufw/after.rules 2>/dev/null; then
      local iok=true
      command -v iptables &>/dev/null && iptables --version 2>/dev/null | grep -q legacy && iok=false
      if $iok; then
        cat >> /etc/ufw/after.rules << 'U'
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
U
        ufw reload >/dev/null 2>&1
        msg_ok "DOCKER-USER правила"
      else
        msg_warn "DOCKER-USER пропущен (legacy iptables)"
      fi
    fi

    if is_trixie || [ ! -f /var/log/auth.log ]; then
      printf '[sshd]\nenabled=true\nport=ssh\nfilter=sshd\nbackend=systemd\nmaxretry=5\nbantime=3600\nfindtime=600\n' \
        > /etc/fail2ban/jail.local
    else
      printf '[sshd]\nenabled=true\nport=ssh\nfilter=sshd\nlogpath=/var/log/auth.log\nbackend=auto\nmaxretry=5\nbantime=3600\nfindtime=600\n' \
        > /etc/fail2ban/jail.local
    fi
    systemctl enable fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
    msg_ok "Fail2Ban"
  fi

  if [ "$OPT_SSH_HARDENING" = true ]; then
    any=true
    mkdir -p /etc/ssh/sshd_config.d
    cp /etc/ssh/sshd_config "${BACKUP_DIR}/sshd_config.bak" 2>/dev/null
    printf 'PermitRootLogin prohibit-password\nMaxAuthTries 3\nClientAliveInterval 300\nClientAliveCountMax 2\nX11Forwarding no\n' \
      > /etc/ssh/sshd_config.d/99-ha-hardening.conf
    systemctl list-unit-files ssh.service &>/dev/null && systemctl reload ssh 2>/dev/null || \
      systemctl reload sshd 2>/dev/null || true
    msg_ok "SSH защищён"
  fi

  if [ "$OPT_AUTOUPDATE" = true ]; then
    any=true
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'U'
Unattended-Upgrade::Allowed-Origins { "${distro_id}:${distro_codename}-security"; };
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
U
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\nAPT::Periodic::AutocleanInterval "7";\n' \
      > /etc/apt/apt.conf.d/20auto-upgrades
    msg_ok "Автообновления"
  fi

  $any || msg_warn "Пропущено"
  mark_done "$sid"
}

# ============================================================================
# ШАГ: УТИЛИТЫ
# ============================================================================
step_extras() {
  local sid="extras"; is_done "$sid" && return 0
  header "[${CURRENT_STEP_NUM}/${TOTAL_STEPS}] УТИЛИТЫ"

  [ "$OPT_HOSTNAME" = true ] && {
    hostnamectl set-hostname homeassistant 2>/dev/null || true
    msg_ok "Имя хоста: homeassistant"
  }

  systemctl enable avahi-daemon >/dev/null 2>&1 || true
  systemctl start avahi-daemon >/dev/null 2>&1 || true
  msg_ok "mDNS (avahi)"

  # --- ha-notify (только root) ---
  cat > /usr/local/bin/ha-notify << NTEOF
#!/bin/bash
MSG="\${1:-}"; [ -z "\$MSG" ] && exit 0
RF="/tmp/.ha_notify_rate"; NOW=\$(date +%s); LAST=\$(cat "\$RF" 2>/dev/null || echo 0)
[ \$((NOW - LAST)) -lt 30 ] && exit 0; echo "\$NOW" > "\$RF"
TG_TOKEN="${TG_TOKEN}"; TG_CHAT="${TG_CHAT}"; WEBHOOK="${OPT_WEBHOOK_URL}"
if [ -n "\$TG_TOKEN" ] && [ -n "\$TG_CHAT" ]; then
  curl -s -X POST "https://api.telegram.org/bot\$TG_TOKEN/sendMessage" \
    --data-urlencode "chat_id=\$TG_CHAT" --data-urlencode "text=HA (\$(hostname)): \$MSG" >/dev/null 2>&1
fi
if [ -n "\$WEBHOOK" ]; then
  curl -s -X POST "\$WEBHOOK" -H "Content-Type: application/json" \
    -d "{\"text\":\"HA (\$(hostname)): \$MSG\"}" >/dev/null 2>&1 || \
  curl -s -X POST "\$WEBHOOK" -d "HA (\$(hostname)): \$MSG" >/dev/null 2>&1 || true
fi
NTEOF
  chmod 700 /usr/local/bin/ha-notify

  # --- Watchdog ---
  if [ "$OPT_WATCHDOG" = true ]; then
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
else
  fails=0; backoff=5
fi
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
    msg_ok "Watchdog (экспон. откат)"
  fi

  # --- Термомонитор ---
  if [ "$OPT_THERMAL" = true ]; then
    cat > /usr/local/bin/ha-thermal << 'S'
#!/bin/bash
[ ! -f /sys/class/thermal/thermal_zone0/temp ] && exit 0
t=$(($(cat /sys/class/thermal/thermal_zone0/temp)/1000))
[ "$t" -ge 80 ] && /usr/local/bin/ha-notify "КРИТИЧ. ТЕМП: ${t}C!"
[ "$t" -ge 70 ] && [ "$t" -lt 80 ] && /usr/local/bin/ha-notify "ВЫСОКАЯ ТЕМП: ${t}C"
S
    chmod +x /usr/local/bin/ha-thermal
    msg_ok "Термомонитор"
  fi

  # --- ha-health ---
  cat > /usr/local/bin/ha-health << 'S'
#!/bin/bash
echo "===== Здоровье HA ($(date)) ====="
printf " %-12s %s\n" \
  Хост: "$(hostname)" \
  IP: "$(hostname -I 2>/dev/null | awk '{print $1}')" \
  Аптайм: "$(uptime -p 2>/dev/null)" \
  Ядро: "$(uname -r)"
[ -f /sys/class/thermal/thermal_zone0/temp ] && \
  printf " %-12s %dC\n" CPU: "$(($(cat /sys/class/thermal/thermal_zone0/temp)/1000))"
free -h | awk '/Mem:/{printf " %-12s %s/%s\n","RAM:",$3,$2} /Swap:/{printf " %-12s %s/%s\n","Swap:",$3,$2}'
df -h / | awk 'NR==2{printf " %-12s %s/%s (%s)\n","Диск:",$3,$2,$5}'
echo "-- Контейнеры --"
docker ps --format " {{.Names}}: {{.Status}}" 2>/dev/null || echo " н/д"
echo "-- Docker диск --"
docker system df 2>/dev/null || echo " н/д"
printf " %-12s %s\n" "HA:" "$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://localhost:8123 2>/dev/null || echo 000)"
echo "========================="
S
  chmod +x /usr/local/bin/ha-health
  msg_ok "ha-health"

  # --- Еженедельный отчёт ---
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
R="${R}"$'\n'"Аптайм: ${uptime_info}"
R="${R}"$'\n'"Контейнеры: ${containers}"
/usr/local/bin/ha-notify "$R"
S
  chmod +x /usr/local/bin/ha-weekly-report
  msg_ok "Еженедельный отчёт"

  # --- Бэкап ---
  if [ "$OPT_BACKUP" = true ]; then
    mkdir -p "$HA_BACKUP_DIR"
    cat > /usr/local/bin/ha-backup << BEOF
#!/bin/bash
set -f
BD="${HA_BACKUP_DIR}"; HD="${HASSIO_DIR}"; KD=30
TS=\$(date +%Y%m%d_%H%M%S); mkdir -p "\$BD"
[ ! -d "\${HD}/homeassistant" ] && exit 1
EX="--exclude=*.db --exclude=*.db-shm --exclude=*.db-wal --exclude=home-assistant_v2.db* --exclude=tts --exclude=deps --exclude=__pycache__"
command -v pigz &>/dev/null \
  && tar -I pigz -cf "\${BD}/ha_config_\${TS}.tar.gz" \$EX -C "\$HD" homeassistant 2>/dev/null \
  || tar czf "\${BD}/ha_config_\${TS}.tar.gz" \$EX -C "\$HD" homeassistant 2>/dev/null
find "\$BD" -name "ha_config_*.tar.gz" -mtime +\$KD -delete 2>/dev/null
/usr/local/bin/ha-notify "Бэкап: \$(du -sh "\${BD}/ha_config_\${TS}.tar.gz" 2>/dev/null | awk '{print \$1}')"
BEOF

    cat > /usr/local/bin/ha-restore << REOF
#!/bin/bash
[ -z "\$BASH_VERSION" ] && { echo "Нужен bash!"; exit 1; }
BD="${HA_BACKUP_DIR}"; HD="${HASSIO_DIR}"
mapfile -t F < <(ls -1t "\$BD"/ha_config_*.tar.gz 2>/dev/null)
[ \${#F[@]} -eq 0 ] && { echo "Бэкапы не найдены"; exit 1; }
for i in "\${!F[@]}"; do
  printf " %d) %s (%s)\n" "\$((i+1))" "\$(basename "\${F[\$i]}")" "\$(du -sh "\${F[\$i]}" | awk '{print \$1}')"
done
read -p "Номер: " n
[[ ! "\$n" =~ ^[0-9]+\$ ]] || [ "\$n" -lt 1 ] || [ "\$n" -gt \${#F[@]} ] && exit 1
read -p "Подтвердить? (yes/no): " c; [ "\$c" != yes ] && exit 0
echo "Проверка..."; tar tzf "\${F[\$((n-1))]}" >/dev/null 2>&1 || { echo "Архив повреждён!"; exit 1; }
echo "Бэкап текущего..."; docker stop homeassistant 2>/dev/null
ts=\$(date +%Y%m%d_%H%M%S)
tar czf "\${BD}/ha_pre_restore_\${ts}.tar.gz" -C "\$HD" homeassistant 2>/dev/null
echo "Восстановление..."; tar xzf "\${F[\$((n-1))]}" -C "\$HD"
docker start homeassistant 2>/dev/null; echo "Готово!"
REOF
    chmod +x /usr/local/bin/ha-backup /usr/local/bin/ha-restore
    msg_ok "Система бэкапов"
  fi

  # --- Удалённый бэкап ---
  if [ "$OPT_REMOTE_BACKUP" = true ] && [ -n "$REMOTE_BACKUP_TARGET" ]; then
    cat > /usr/local/bin/ha-backup-remote << RBEOF
#!/bin/bash
BD="${HA_BACKUP_DIR}"; REMOTE="${REMOTE_BACKUP_TARGET}"
LATEST=\$(ls -1t "\$BD"/ha_config_*.tar.gz 2>/dev/null | head -1)
[ -z "\$LATEST" ] && exit 1
case "\$REMOTE" in
  ssh://*) scp -o StrictHostKeyChecking=no "\$LATEST" "\${REMOTE#ssh://}" 2>/dev/null \
    && /usr/local/bin/ha-notify "Бэкап -> SSH OK" ;;
  *) /usr/local/bin/ha-notify "Неизвестный протокол бэкапа" ;;
esac
RBEOF
    chmod +x /usr/local/bin/ha-backup-remote
    msg_ok "Удалённый бэкап"
  fi

  # --- Мониторинг Prometheus ---
  if [ "$OPT_MONITORING" = true ]; then
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
    msg_ok "Метрики Prometheus"
  fi

  # --- Восстановление загрузки ---
  if [ "$OPT_BOOT_RECOVERY" = true ]; then
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
    msg_ok "Восстановление загрузки"
  fi

  # --- Обратный прокси ---
  if [ "$OPT_REVERSE_PROXY" = true ] && [ -n "$PROXY_DOMAIN" ]; then
    cat > /etc/nginx/sites-available/homeassistant << NGINX
server {
    server_name ${PROXY_DOMAIN};
    location / {
        proxy_pass http://127.0.0.1:8123;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGINX
    ln -sf /etc/nginx/sites-available/homeassistant /etc/nginx/sites-enabled/ 2>/dev/null
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null
    nginx -t 2>/dev/null && systemctl restart nginx 2>/dev/null && msg_ok "Nginx -> ${PROXY_DOMAIN}"
    certbot --nginx -d "$PROXY_DOMAIN" --non-interactive --agree-tos \
      --register-unsafely-without-email --redirect 2>/dev/null \
      && msg_ok "SSL: ${PROXY_DOMAIN}" \
      || msg_warn "SSL не удалось (позже: certbot --nginx -d ${PROXY_DOMAIN})"
  fi

  detect_usb_dongles

  # --- Cron ---
  {
    echo "# HA Installer v${SCRIPT_VERSION}"
    [ "$OPT_WATCHDOG" = true ] && printf '*/5 * * * * root /usr/local/bin/ha-watchdog >/dev/null 2>&1\n*/10 * * * * root /usr/local/bin/ha-net-recovery >/dev/null 2>&1\n30 3 * * * root /usr/local/bin/ha-cleanup >/dev/null 2>&1\n'
    [ "$OPT_THERMAL" = true ]      && echo '*/5 * * * * root /usr/local/bin/ha-thermal >/dev/null 2>&1'
    [ "$OPT_BACKUP" = true ]       && echo '0 4 * * 0 root /usr/local/bin/ha-backup >/dev/null 2>&1'
    [ "$OPT_REMOTE_BACKUP" = true ] && echo '30 4 * * 0 root /usr/local/bin/ha-backup-remote >/dev/null 2>&1'
    [ "$OPT_MONITORING" = true ]   && echo '* * * * * root /usr/local/bin/ha-metrics >/dev/null 2>&1'
    echo '0 9 * * 1 root /usr/local/bin/ha-weekly-report >/dev/null 2>&1'
  } > /etc/cron.d/ha-tools
  chmod 644 /etc/cron.d/ha-tools
  msg_ok "Задания cron"

  mark_done "$sid"
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
  wait_ha_ready 300 || { msg_warn "Таймаут"; mark_done "$sid"; return 0; }

  local cw=0
  while ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^homeassistant$'; do
    sleep 5; cw=$((cw+5))
    [ $cw -gt 60 ] && { mark_done "$sid"; return 0; }
  done

  docker exec homeassistant bash -c "wget -q -O- https://get.hacs.xyz | bash -" &>/dev/null &
  local hp=$! hw=0
  while kill -0 "$hp" 2>/dev/null; do
    sleep 5; hw=$((hw+5))
    [ $hw -ge 120 ] && { kill "$hp" 2>/dev/null; mark_done "$sid"; return 0; }
  done

  wait "$hp" 2>/dev/null && {
    docker restart homeassistant >/dev/null 2>&1
    msg_ok "HACS установлен!"
  } || msg_warn "HACS: ошибка (можно установить позже)"

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
# ОПЕРАЦИИ: МОНИТОРИНГ (live)
# ============================================================================
do_status() {
  while true; do
    clear; show_banner
    local ip t
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="?"
    t=$(get_cpu_temp)
    echo -e "   ${BOLD}IP:${NC} $ip  ${BOLD}CPU:${NC} ${t:-?}C  ${BOLD}Аптайм:${NC} $(uptime -p 2>/dev/null || echo ?)"
    echo -e "   ${BOLD}RAM:${NC} $(free -h | awk '/Mem:/{printf "%s/%s",$3,$2}')  ${BOLD}Swap:${NC} $(free -h | awk '/Swap:/{printf "%s/%s",$3,$2}')"
    separator
    docker ps --format ' {{.Names}}|{{.Status}}' 2>/dev/null | while IFS='|' read -r n s; do
      echo "$s" | grep -q Up \
        && echo -e "   ${CHECK} ${n} ${DIM}${s}${NC}" \
        || echo -e "   ${CROSS} ${n} ${RED}${s}${NC}"
    done
    local hc
    hc=$(curl -s -o /dev/null -w "%{http_code}" -m 3 http://localhost:8123 2>/dev/null || echo 000)
    separator
    [ "$hc" != "000" ] && echo -e "   ${CHECK} HA: ${GREEN}${hc}${NC}" || echo -e "   ${CROSS} HA: ${RED}недоступен${NC}"
    echo -e "   ${DIM}Обновление каждые 5с. Ctrl+C для выхода${NC}"
    sleep 5
  done
}

# ============================================================================
# ОПЕРАЦИИ: УДАЛЕНИЕ
# ============================================================================
do_uninstall() {
  header "УДАЛЕНИЕ HA SUPERVISED"
  local ok=false
  if command -v whiptail &>/dev/null; then
    whiptail --title "Удаление" --yesno "Удалить Home Assistant Supervised?" 8 50 && ok=true
  else
    echo -en "   ${WARN} Удалить HA? (yes/no): " >&2
    local r; read -r r; [ "$r" = yes ] && ok=true
  fi
  [ "$ok" != true ] && { msg_info "Отменено."; exit 0; }

  systemctl stop hassio-supervisor hassio-apparmor 2>/dev/null || true

  docker ps -a --filter "label=io.hass.type" --format '{{.Names}}' 2>/dev/null | while IFS= read -r c; do
    docker rm -f "$c" 2>/dev/null
  done
  for c in homeassistant hassio_supervisor hassio_cli hassio_audio hassio_dns hassio_multicast hassio_observer; do
    docker rm -f "$c" 2>/dev/null || true
  done
  docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -iE "homeassistant|hassio|home-assistant" | while IFS= read -r i; do
    docker rmi -f "$i" 2>/dev/null
  done

  for svc in hassio-supervisor hassio-apparmor ha-boot-check "${REBOOT_CONTINUE_SVC}"; do
    systemctl disable "$svc" 2>/dev/null
    rm -f "/etc/systemd/system/${svc}.service"
  done
  rm -rf /etc/systemd/system/hassio-supervisor.service.d
  systemctl daemon-reload 2>/dev/null || true

  dpkg --purge homeassistant-supervised os-agent 2>/dev/null || true

  rm -f /usr/local/bin/ha-notify /usr/local/bin/ha-watchdog /usr/local/bin/ha-cleanup \
    /usr/local/bin/ha-net-recovery /usr/local/bin/ha-backup /usr/local/bin/ha-restore \
    /usr/local/bin/ha-health /usr/local/bin/ha-thermal /usr/local/bin/ha-metrics \
    /usr/local/bin/ha-boot-check /usr/local/bin/ha-backup-remote /usr/local/bin/ha-weekly-report \
    /etc/cron.d/ha-tools /etc/udev/rules.d/99-ha-usb-power.rules \
    /etc/ssh/sshd_config.d/99-ha-hardening.conf /etc/sysctl.d/99-ha-swap.conf \
    /etc/systemd/journald.conf.d/ha-tuning.conf "$HA_INFO_FILE" "$SAFE_SCRIPT_PATH" 2>/dev/null

  [ -f /etc/ufw/after.rules ] && {
    sed -i '/# BEGIN HA-INSTALLER DOCKER-USER/,/# END HA-INSTALLER DOCKER-USER/d' /etc/ufw/after.rules 2>/dev/null
    ufw reload 2>/dev/null || true
  }
  [ -f /etc/nginx/sites-enabled/homeassistant ] && {
    rm -f /etc/nginx/sites-enabled/homeassistant /etc/nginx/sites-available/homeassistant
    systemctl reload nginx 2>/dev/null || true
  }

  [ -d "$HASSIO_DIR" ] && {
    echo -en "   ${WARN} Удалить данные HA? (yes/no): " >&2
    local r; read -r r; [ "$r" = yes ] && rm -rf "$HASSIO_DIR"
  }
  [ -d "$HA_BACKUP_DIR" ] && {
    echo -en "   ${WARN} Удалить бэкапы? (yes/no): " >&2
    local r; read -r r; [ "$r" = yes ] && rm -rf "$HA_BACKUP_DIR"
  }

  restore_os_release
  rm -f "$FAKED_OS_RELEASE" 2>/dev/null
  rm -rf "$HA_INSTALLER_DIR" /root/.ha_install_state /root/.ha_install_backup 2>/dev/null
  docker system prune -f 2>/dev/null || true
  rm -f "$GRACE_MARKER" 2>/dev/null

  header "УДАЛЕНО"
}

# ============================================================================
# ОПЕРАЦИИ: ОБНОВЛЕНИЕ
# ============================================================================
do_update() {
  header "ОБНОВЛЕНИЕ"
  load_config; detect_system_info

  # Автобэкап перед обновлением
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
    [ "$OS_RELEASE_FAKED" = true ] && restore_os_release
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
  local latest; latest=$(get_latest_release "$INSTALLER_REPO")
  [ -z "$latest" ] && { msg_warn "Не удалось проверить"; return; }
  [ "$SCRIPT_VERSION" = "$latest" ] && { msg_ok "Актуальная версия: ${SCRIPT_VERSION}"; return; }
  msg_info "Доступно: ${SCRIPT_VERSION} -> ${latest}"

  if [ -t 0 ]; then
    echo -en "   ${ARROW} Обновить? (д/н): " >&2
    local ans; read -r ans
    [ "$ans" != "y" ] && [ "$ans" != "Y" ] && [ "$ans" != "д" ] && [ "$ans" != "Д" ] && return
  fi

  local nf="${0}.new"
  wget -q -O "$nf" "https://raw.githubusercontent.com/${INSTALLER_REPO}/main/install.sh" 2>/dev/null || { msg_error "Загрузка не удалась"; return; }
  bash -n "$nf" 2>/dev/null || { msg_error "Синтаксическая ошибка"; rm -f "$nf"; return; }
  grep -q "SCRIPT_VERSION=" "$nf" || { msg_error "Некорректный файл"; rm -f "$nf"; return; }
  local sz; sz=$(wc -c < "$nf")
  [ "$sz" -lt 10000 ] && { msg_error "Файл слишком мал (${sz}б)"; rm -f "$nf"; return; }
  mv "$nf" "$0"; chmod +x "$0"
  msg_ok "Обновлён до ${latest}. Перезапустите скрипт."
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

  # Тест состояния
  local tsf="/tmp/ha_test_$$"
  local orig="$STATE_FILE"; STATE_FILE="$tsf"; rm -f "$tsf"
  mark_done "test_step"
  is_done "test_step" && { msg_ok "Состояние: ок"; pass=$((pass+1)); } || { msg_error "Состояние: ошибка"; fail=$((fail+1)); }
  rm -f "$tsf" "${tsf}.lock"; STATE_FILE="$orig"

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
HA Установщик v${SCRIPT_VERSION}

  sudo ./install.sh                     Интерактивный мастер/меню

  РЕЖИМЫ:
    -c, --check                         Диагностика системы
    -s, --status                        Мониторинг (live)
    -u, --uninstall                     Удаление HA
    --update                            Обновление HA + OS-Agent
    --self-update                       Обновление скрипта
    --self-test                         Самотестирование
    --benchmark                         Тест производительности
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

  ФАЙЛЫ:
    ${HA_INSTALLER_DIR}/                Конфигурация и состояние
    ${HA_BACKUP_DIR}/                   Бэкапы
    ${HA_INFO_FILE}                     Информация об установке

  ПРИМЕРЫ:
    sudo ./install.sh                                   Мастер установки
    sudo ./install.sh --profile standard                Стандартный профиль
    sudo ./install.sh --profile standard --timezone Europe/Moscow
    sudo ./install.sh --check                           Диагностика
    sudo ./install.sh --update                          Обновить HA
    sudo ./install.sh --benchmark                       Тест железа
    sudo ./install.sh --profile full --data-dir /mnt/ssd --auto-reboot
    sudo ./install.sh --restore-backup /mnt/usb/ha_config_20250101.tar.gz

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
    echo -e "${BLUE}  _   _                         _            _     _              _   ${NC}"
    echo -e "${BLUE} | | | | ___  _ __ ___   ___   / \\   ___ ___(_)___| |_ __ _ _ __ | |_ ${NC}"
    echo -e "${BLUE} | |_| |/ _ \\| '_ \` _ \\ / _ \\ / _ \\ / __/ __| / __| __/ _\` | '_ \\| __|${NC}"
    echo -e "${BLUE} |  _  | (_) | | | | | |  __// ___ \\\\__ \\__ \\ \\__ \\ || (_| | | | | |_ ${NC}"
    echo -e "${BLUE} |_| |_|\\___/|_| |_| |_|\\___/_/   \\_\\___/___/_|___/\\__\\__,_|_| |_|\\__|${NC}"
    echo -e "${WHITE}${BOLD}     ULTIMATE INSTALLER v${SCRIPT_VERSION}${NC}"
    separator
  }
}

# ============================================================================
# ФИНАЛЬНЫЙ ОТЧЁТ
# ============================================================================
show_final() {
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"
  local now; now=$(date +%s)
  local el=$(( now - ${INSTALL_START:-$now} ))
  local em=$((el/60)) es=$((el%60))

  header "УСТАНОВКА ЗАВЕРШЕНА! (${em}м ${es}с)"

  echo -e "   ${GREEN}=> http://${ip}:8123${NC}"
  [ "$OPT_HOSTNAME" = true ] && echo -e "   ${GREEN}=> http://homeassistant.local:8123${NC}"
  [ "$OPT_REVERSE_PROXY" = true ] && [ -n "$PROXY_DOMAIN" ] && echo -e "   ${GREEN}=> https://${PROXY_DOMAIN}${NC}"

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
  [ "$OPT_REVERSE_PROXY" = true ] && echo -e "   ${CHECK} Прокси: ${PROXY_DOMAIN}"
  [ -n "$OPT_RESTORE_BACKUP" ]    && echo -e "   ${CHECK} Восстановлено: $(basename "$OPT_RESTORE_BACKUP")"
  [ "$OS_RELEASE_FAKED" = true ]   && echo -e "   ${WARN} os-release подменяется при старте supervisor"

  # Время шагов
  separator
  echo -e "   ${BOLD}Время шагов:${NC}"
  for s in "${ALL_STEPS[@]}"; do
    local st="${STEP_TIMES[$s]:-0}"
    [ "$st" -gt 0 ] && printf "   %-15s %dс\n" "${s}" "$st"
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
  send_notification "HA установлен: http://${ip}:8123"
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

  ORIGINAL_ARGS="$*"
  parse_args "$@"
  setup_dirs
  migrate_legacy_paths
  log_run_history "$*"

  # Очистка сервиса продолжения после ребута
  remove_reboot_continue

  # Импорт конфигурации
  [ -n "$IMPORT_CONFIG" ] && import_config "$IMPORT_CONFIG"

  # Явные режимы (без wizard)
  [ "$CHECK_ONLY" = true ]      && { show_banner; do_check; exit 0; }
  [ "$SHOW_STATUS" = true ]     && { do_status; exit 0; }
  [ "$UNINSTALL" = true ]       && { show_banner; acquire_lock; do_uninstall; exit 0; }
  [ "$DO_UPDATE" = true ]       && { show_banner; acquire_lock; do_update; exit 0; }
  [ "$DO_SELF_UPDATE" = true ]  && { show_banner; do_self_update; exit 0; }
  [ "$DO_SELF_TEST" = true ]    && { show_banner; do_self_test; exit $?; }
  [ "$DO_BENCHMARK" = true ]    && { show_banner; do_benchmark; exit 0; }
  [ "$DO_EXPORT_CONFIG" = true ] && { show_banner; export_config; exit 0; }
  [ "$DO_SHOW_HISTORY" = true ] && { show_banner; show_history; exit 0; }

  # Профиль из CLI
  [ -n "$PROFILE" ] && apply_profile "$PROFILE"

  # Интерактив: меню если без аргументов
  if [ $# -eq 0 ] && [ "$RUN_WIZARD" = true ]; then
    if [ -t 0 ] && [ -t 1 ]; then
      show_main_menu || true
    fi
  fi
  [ "$RUN_WIZARD" = true ] && [ "$DRY_RUN" = false ] && run_wizard

  # Nohup ДО логирования
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
