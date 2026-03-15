#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="3.0.0"
START_TIME=$(date +%s)
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
SCRIPT_NAME=$(basename "$0")

DRY_RUN=false
RESUME=false
WITH_UPGRADE=false
PROFILE="core-security"
WITH_FIREFOX=false
WITH_COCKPIT=false
WITHOUT_FAIL2BAN=false
WITHOUT_TOOLS=false
SSH_PORT=22
RDP_PORT=3389
RDP_USER="rdpadmin"
TIMEZONE="Asia/Dubai"
SWAP_SIZE="2G"
RDP_PASSWORD="${RDP_PASSWORD:-}"

INSTALL_FIREFOX=false
INSTALL_COCKPIT=false
INSTALL_FAIL2BAN=true
INSTALL_TOOLS=true
RUN_FIREWALL=true

LOG_DIR="/var/log/vps-desktop-setup"
STATE_DIR="/var/lib/vps-desktop-setup"
RUN_ID=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${LOG_DIR}/setup-${RUN_ID}.log"
REPORT_FILE="${LOG_DIR}/report-${RUN_ID}.txt"
PHASE_STATE_FILE="${STATE_DIR}/phase-state.txt"
LAST_CMD_OUTPUT=""

SCRIPT_EXIT_CODE=0
CLEANUP_DONE=false
REPORT_GENERATED=false
ERROR_COUNT=0
PREFLIGHT_HARD_FAIL=false
PUBLIC_IP="Unavailable"
FIREFOX_BIN="Unavailable"
FIREFOX_VERSION="Unavailable"

SYS_CPU_MODEL="Unknown"
SYS_CPU_CORES=0
SYS_CPU_THREADS=0
SYS_CPU_CUR_GHZ=0
SYS_CPU_MAX_GHZ=0
SYS_RAM_TOTAL_GB=0
SYS_RAM_USED_GB=0
SYS_RAM_FREE_GB=0
SYS_DISK_TOTAL_GB=0
SYS_DISK_USED_GB=0
SYS_DISK_FREE_GB=0

PREFLIGHT_RESULTS=()
PREFLIGHT_ORDER=()

COMP_XFCE="[ ] XFCE"
COMP_XRDP="[ ] XRDP"
COMP_FIREFOX="[ ] Firefox"
COMP_UFW="[ ] UFW"
COMP_FAIL2BAN="[ ] Fail2ban"
COMP_SWAP="[ ] Swap"
COMP_COCKPIT="[ ] Cockpit"

if [[ -t 1 ]]; then
  BOLD='\033[1m'
  RESET='\033[0m'
  RED='\033[31m'
  GREEN='\033[32m'
  YELLOW='\033[33m'
  BLUE='\033[34m'
else
  BOLD=''
  RESET=''
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
fi

usage() {
  cat <<USAGE
Usage: sudo bash ${SCRIPT_NAME} [options]

Options:
  --dry-run                 Show planned actions without making changes.
  --resume                  Skip completed phases from previous run.
  --with-upgrade            Run apt upgrade (default is skipped).
  --profile <name>          Install profile: core-security|full|core (default: core-security).
  --with-firefox            Force Firefox installation.
  --with-cockpit            Force Cockpit installation.
  --without-fail2ban        Disable fail2ban installation.
  --without-tools           Skip extra desktop/admin tool installation.
  --ssh-port <port>         SSH port to allow in UFW (default: 22).
  --rdp-port <port>         XRDP port to configure (default: 3389).
  --rdp-user <username>     Desktop login user (default: rdpadmin).
  --timezone <tz>           System timezone (default: Asia/Dubai).
  --swap-size <size>        Swap size (e.g. 1G, 2048M) (default: 2G).
  --rdp-password <pass>     Password for --rdp-user (or set env RDP_PASSWORD).
  --help                    Show this help.

Notes:
  - In non-interactive mode, password must be provided by --rdp-password or RDP_PASSWORD env var.
  - Default profile is safe for servers: XRDP + XFCE + swap + UFW + fail2ban.
  - Existing files are preserved via backup paths (non-destructive mode).
  - One-command from GitHub:
    curl -fsSL https://raw.githubusercontent.com/malikarslan699/scripts/main/xrdp_setup_script.sh | sudo bash -s -- --profile core-security
USAGE
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        ;;
      --resume)
        RESUME=true
        ;;
      --with-upgrade)
        WITH_UPGRADE=true
        ;;
      --profile)
        [[ $# -ge 2 ]] || { echo "Missing value for --profile"; exit 1; }
        PROFILE="$2"
        shift
        ;;
      --with-firefox)
        WITH_FIREFOX=true
        ;;
      --with-cockpit)
        WITH_COCKPIT=true
        ;;
      --without-fail2ban)
        WITHOUT_FAIL2BAN=true
        ;;
      --without-tools)
        WITHOUT_TOOLS=true
        ;;
      --ssh-port)
        [[ $# -ge 2 ]] || { echo "Missing value for --ssh-port"; exit 1; }
        SSH_PORT="$2"
        shift
        ;;
      --rdp-port)
        [[ $# -ge 2 ]] || { echo "Missing value for --rdp-port"; exit 1; }
        RDP_PORT="$2"
        shift
        ;;
      --rdp-user)
        [[ $# -ge 2 ]] || { echo "Missing value for --rdp-user"; exit 1; }
        RDP_USER="$2"
        shift
        ;;
      --timezone)
        [[ $# -ge 2 ]] || { echo "Missing value for --timezone"; exit 1; }
        TIMEZONE="$2"
        shift
        ;;
      --swap-size)
        [[ $# -ge 2 ]] || { echo "Missing value for --swap-size"; exit 1; }
        SWAP_SIZE="$2"
        shift
        ;;
      --rdp-password)
        [[ $# -ge 2 ]] || { echo "Missing value for --rdp-password"; exit 1; }
        RDP_PASSWORD="$2"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
    shift
  done
}

apply_profile_defaults() {
  case "$PROFILE" in
    core-security)
      RUN_FIREWALL=true
      INSTALL_FAIL2BAN=true
      INSTALL_FIREFOX=true
      INSTALL_COCKPIT=false
      INSTALL_TOOLS=true
      ;;
    full)
      RUN_FIREWALL=true
      INSTALL_FAIL2BAN=true
      INSTALL_FIREFOX=true
      INSTALL_COCKPIT=true
      INSTALL_TOOLS=true
      ;;
    core)
      RUN_FIREWALL=false
      INSTALL_FAIL2BAN=false
      INSTALL_FIREFOX=false
      INSTALL_COCKPIT=false
      INSTALL_TOOLS=false
      ;;
    *)
      echo "Invalid profile '${PROFILE}'. Use: core-security|full|core"
      exit 1
      ;;
  esac

  if $WITH_FIREFOX; then
    INSTALL_FIREFOX=true
  fi
  if $WITH_COCKPIT; then
    INSTALL_COCKPIT=true
  fi
  if $WITHOUT_FAIL2BAN; then
    INSTALL_FAIL2BAN=false
  fi
  if $WITHOUT_TOOLS; then
    INSTALL_TOOLS=false
  fi
}

validate_numeric_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  ((port >= 1 && port <= 65535))
}

seconds_to_human() {
  local total="$1"
  local h=$((total / 3600))
  local m=$(((total % 3600) / 60))
  local s=$((total % 60))
  printf "%02dh %02dm %02ds" "$h" "$m" "$s"
}

timestamp_id() {
  date +%Y%m%d-%H%M%S-%N
}

backup_existing_path() {
  local target="$1"
  local backup

  if [[ ! -e "$target" ]]; then
    return 0
  fi

  backup="${target}.backup.$(timestamp_id)"
  if $DRY_RUN; then
    log INFO "[dry-run] Would preserve existing path: ${target} -> ${backup}"
    return 0
  fi

  mv "$target" "$backup"
  log WARN "Preserved existing path by backup: ${target} -> ${backup}"
}

backup_existing_file() {
  local target="$1"
  if [[ -e "$target" ]]; then
    backup_existing_path "$target"
  fi
}

setup_logging() {
  if $DRY_RUN; then
    mkdir -p "$LOG_DIR" "$STATE_DIR"
  else
    mkdir -p "$LOG_DIR" "$STATE_DIR"
  fi
  : >"$LOG_FILE"
}

print_header() {
  cat <<HDR
${BOLD}============================================================${RESET}
${BOLD}      VPS Desktop + XRDP Setup Script (v${SCRIPT_VERSION})${RESET}
${BOLD}============================================================${RESET}
HDR
}

log() {
  local level="$1"
  shift
  local msg="$*"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')

  local color=""
  case "$level" in
    INFO) color="$BLUE" ;;
    WARN) color="$YELLOW" ;;
    ERROR) color="$RED" ;;
    SUCCESS) color="$GREEN" ;;
    *) color="" ;;
  esac

  printf "%b[%s] [%s] %s%b\n" "$color" "$ts" "$level" "$msg" "$RESET"
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf "[%s] [%s] %s\n" "$ts" "$level" "$msg" >>"$LOG_FILE"
  fi

  if [[ "$level" == "ERROR" ]]; then
    ERROR_COUNT=$((ERROR_COUNT + 1))
  fi
}

print_step() { log INFO "$1"; }
print_phase() { printf "\n%b>>> %s%b\n" "$BOLD" "$1" "$RESET"; }
print_ok() { log SUCCESS "$1"; }
print_warn() { log WARN "$1"; }
print_fail() { log ERROR "$1"; }

phase_header() {
  local num="$1"
  local name="$2"
  printf "\n%b[Phase %s] %s%b\n" "$BOLD" "$num" "$name" "$RESET"
}

progress_bar() {
  local current="$1"
  local total="$2"
  local label="$3"

  if ! [[ -t 1 ]]; then
    return 0
  fi
  ((total > 0)) || total=1
  if ((current < 0)); then
    current=0
  fi
  if ((current > total)); then
    current=$total
  fi

  local width=32
  local filled=$((current * width / total))
  local empty=$((width - filled))
  local pct=$((current * 100 / total))

  printf "\r%-40s [" "$label"
  printf "%0.s#" $(seq 1 "$filled")
  printf "%0.s-" $(seq 1 "$empty")
  printf "] %3d%%" "$pct"

  if ((current == total)); then
    printf "\n"
  fi
}

confirm_continue() {
  local prompt="$1"
  if [[ ! -t 0 ]]; then
    return 1
  fi

  local ans
  read -r -p "$prompt [y/N]: " ans
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

set_preflight_result() {
  local name="$1"
  local status="$2"
  local detail="$3"
  PREFLIGHT_RESULTS+=("${name}|${status}|${detail}")
  PREFLIGHT_ORDER+=("$name")

  if [[ "$status" == "FAIL" ]]; then
    PREFLIGHT_HARD_FAIL=true
  fi
}

print_preflight_summary() {
  printf "\n%bPre-flight Summary%b\n" "$BOLD" "$RESET"
  printf "%b+----------------------+--------+----------------------------------+%b\n" "$BOLD" "$RESET"
  printf "%b| Check                | Status | Details                          |%b\n" "$BOLD" "$RESET"
  printf "%b+----------------------+--------+----------------------------------+%b\n" "$BOLD" "$RESET"

  local item name status detail
  for item in "${PREFLIGHT_RESULTS[@]}"; do
    IFS='|' read -r name status detail <<<"$item"
    printf "| %-20s | %-6s | %-32s |\n" "$name" "$status" "$detail"
  done

  printf "%b+----------------------+--------+----------------------------------+%b\n" "$BOLD" "$RESET"
  printf "\n%bSystem Snapshot%b\n" "$BOLD" "$RESET"
  printf "  CPU: %s | %s cores / %s threads | %s/%s GHz (cur/max)\n" \
    "$SYS_CPU_MODEL" "$SYS_CPU_CORES" "$SYS_CPU_THREADS" "$SYS_CPU_CUR_GHZ" "$SYS_CPU_MAX_GHZ"
  printf "  RAM (GB): total %s | used %s | free %s\n" \
    "$SYS_RAM_TOTAL_GB" "$SYS_RAM_USED_GB" "$SYS_RAM_FREE_GB"
  printf "  Storage / (GB): total %s | used %s | free %s\n" \
    "$SYS_DISK_TOTAL_GB" "$SYS_DISK_USED_GB" "$SYS_DISK_FREE_GB"
}

ensure_line_in_file() {
  local line="$1"
  local file="$2"

  touch "$file"
  if ! grep -Fxq "$line" "$file"; then
    printf "%s\n" "$line" >>"$file"
  fi
}

set_config_kv() {
  local file="$1"
  local key="$2"
  local value="$3"

  touch "$file"
  local escaped_key
  escaped_key=$(printf '%s' "$key" | sed -E 's/[][(){}.+*^$?|\\/]/\\&/g')

  if grep -Eq "^[[:space:]#]*${escaped_key}[[:space:]]*=" "$file"; then
    sed -i -E "s|^[[:space:]#]*${escaped_key}[[:space:]]*=.*|${key}=${value}|" "$file"
  else
    printf "%s=%s\n" "$key" "$value" >>"$file"
  fi
}

size_to_bytes() {
  local size
  size=$(printf "%s" "$1" | tr '[:lower:]' '[:upper:]')

  if [[ "$size" =~ ^([0-9]+)([KMGT]?)$ ]]; then
    local num="${BASH_REMATCH[1]}"
    local unit="${BASH_REMATCH[2]}"
    case "$unit" in
      "") echo "$num" ;;
      K) echo $((num * 1024)) ;;
      M) echo $((num * 1024 * 1024)) ;;
      G) echo $((num * 1024 * 1024 * 1024)) ;;
      T) echo $((num * 1024 * 1024 * 1024 * 1024)) ;;
      *) return 1 ;;
    esac
  else
    return 1
  fi
}

has_internet() {
  ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 || \
    curl -fsS --max-time 5 https://1.1.1.1 >/dev/null 2>&1
}

get_public_ip() {
  local ip
  ip=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
  if [[ -n "$ip" ]]; then
    printf "%s" "$ip"
    return 0
  fi

  ip=$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)
  if [[ -n "$ip" ]]; then
    printf "%s" "$ip"
    return 0
  fi

  printf "Unavailable"
}

num_or_zero() {
  local v="$1"
  if [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf "%s" "$v"
  else
    printf "0"
  fi
}

bytes_to_gb() {
  local bytes="$1"
  awk -v b="$bytes" 'BEGIN {printf "%.2f", b/1073741824}'
}

capture_system_snapshot() {
  local cpu_model
  local cpu_cores
  local cpu_threads
  local cur_mhz
  local max_mhz
  local ghz_hint
  local mem_total_b
  local mem_used_b
  local mem_free_b
  local disk_total_b
  local disk_used_b
  local disk_free_b

  cpu_model=$(lscpu | awk -F: '/^Model name:/ {print $2; exit}')
  if [[ -z "$cpu_model" ]]; then
    cpu_model=$(awk -F: '/^model name|^Hardware|^Processor/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
  fi
  SYS_CPU_MODEL=$(printf "%s" "${cpu_model:-Unknown}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')

  cpu_cores=$(lscpu | awk -F: '
    /^Core\(s\) per socket:/ {cores=$2}
    /^Socket\(s\):/ {sockets=$2}
    END {
      gsub(/^[ \t]+|[ \t]+$/, "", cores)
      gsub(/^[ \t]+|[ \t]+$/, "", sockets)
      if (cores ~ /^[0-9]+$/ && sockets ~ /^[0-9]+$/) {
        print cores * sockets
      }
    }')
  if [[ -z "$cpu_cores" ]]; then
    cpu_cores=$(lscpu | awk -F: '/^Core\(s\) per socket:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')
  fi
  if [[ -z "$cpu_cores" ]]; then
    cpu_cores=$(nproc --all 2>/dev/null || echo 0)
  fi
  SYS_CPU_CORES=$(num_or_zero "$cpu_cores")

  cpu_threads=$(nproc --all 2>/dev/null || echo 0)
  SYS_CPU_THREADS=$(num_or_zero "$cpu_threads")

  cur_mhz=$(awk -F: '/^cpu MHz/ {sum+=$2; n++} END {if (n>0) printf "%.2f", sum/n; else print "0"}' /proc/cpuinfo 2>/dev/null || echo 0)
  max_mhz=$(lscpu | awk -F: '/^CPU max MHz:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')
  if [[ -z "$max_mhz" ]]; then
    max_mhz=$(awk -F: '/^cpu MHz/ {if ($2>max) max=$2} END {if (max>0) printf "%.2f", max; else print "0"}' /proc/cpuinfo 2>/dev/null || echo 0)
  fi
  cur_mhz=$(num_or_zero "$cur_mhz")
  max_mhz=$(num_or_zero "$max_mhz")
  ghz_hint=$(lscpu | awk -F'@' '
    /@[[:space:]]*[0-9.]+GHz/ {
      if (match($2, /([0-9.]+)[[:space:]]*GHz/, m)) {
        print m[1]
        exit
      }
    }')
  ghz_hint=$(num_or_zero "$ghz_hint")
  SYS_CPU_CUR_GHZ=$(awk -v m="$cur_mhz" 'BEGIN {printf "%.2f", m/1000}')
  SYS_CPU_MAX_GHZ=$(awk -v m="$max_mhz" 'BEGIN {printf "%.2f", m/1000}')
  if awk -v v="$SYS_CPU_CUR_GHZ" 'BEGIN {exit !(v <= 0)}'; then
    SYS_CPU_CUR_GHZ=$(awk -v g="$ghz_hint" 'BEGIN {printf "%.2f", g}')
  fi
  if awk -v v="$SYS_CPU_MAX_GHZ" 'BEGIN {exit !(v <= 0)}'; then
    SYS_CPU_MAX_GHZ=$(awk -v g="$ghz_hint" 'BEGIN {printf "%.2f", g}')
  fi

  mem_total_b=$(free -b | awk '/^Mem:/ {print $2}')
  mem_used_b=$(free -b | awk '/^Mem:/ {print $3}')
  mem_free_b=$(free -b | awk '/^Mem:/ {print $4}')
  mem_total_b=$(num_or_zero "$mem_total_b")
  mem_used_b=$(num_or_zero "$mem_used_b")
  mem_free_b=$(num_or_zero "$mem_free_b")
  SYS_RAM_TOTAL_GB=$(bytes_to_gb "$mem_total_b")
  SYS_RAM_USED_GB=$(bytes_to_gb "$mem_used_b")
  SYS_RAM_FREE_GB=$(bytes_to_gb "$mem_free_b")

  disk_total_b=$(df -B1 / | awk 'NR==2 {print $2}')
  disk_used_b=$(df -B1 / | awk 'NR==2 {print $3}')
  disk_free_b=$(df -B1 / | awk 'NR==2 {print $4}')
  disk_total_b=$(num_or_zero "$disk_total_b")
  disk_used_b=$(num_or_zero "$disk_used_b")
  disk_free_b=$(num_or_zero "$disk_free_b")
  SYS_DISK_TOTAL_GB=$(bytes_to_gb "$disk_total_b")
  SYS_DISK_USED_GB=$(bytes_to_gb "$disk_used_b")
  SYS_DISK_FREE_GB=$(bytes_to_gb "$disk_free_b")
}

resolve_apt_locks() {
  local locks=(
    "/var/lib/dpkg/lock-frontend"
    "/var/lib/dpkg/lock"
    "/var/lib/apt/lists/lock"
    "/var/cache/apt/archives/lock"
  )

  local has_lock=false
  local lock

  for _ in {1..10}; do
    has_lock=false
    for lock in "${locks[@]}"; do
      if [[ -e "$lock" ]] && fuser "$lock" >/dev/null 2>&1; then
        has_lock=true
        break
      fi
    done

    if ! $has_lock; then
      return 0
    fi

    sleep 3
  done

  print_warn "Apt/dpkg locks still present after wait; attempting repair."

  if ! $DRY_RUN; then
    pkill -TERM -f 'apt.systemd.daily|unattended-upgrade|apt-get|apt|dpkg' >/dev/null 2>&1 || true
    sleep 2
    pkill -KILL -x apt-get >/dev/null 2>&1 || true
    pkill -KILL -x dpkg >/dev/null 2>&1 || true

    dpkg --configure -a >>"$LOG_FILE" 2>&1 || true
    env DEBIAN_FRONTEND=noninteractive apt-get -f install -y >>"$LOG_FILE" 2>&1 || true
  fi
}

check_root_access() {
  if [[ "$EUID" -eq 0 ]]; then
    set_preflight_result "Root" "PASS" "Running as root"
  else
    set_preflight_result "Root" "FAIL" "Must run as root"
  fi
}

check_os_version() {
  if [[ ! -f /etc/os-release ]]; then
    set_preflight_result "OS" "FAIL" "/etc/os-release missing"
    return
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    set_preflight_result "OS" "FAIL" "Unsupported (${PRETTY_NAME:-unknown})"
    return
  fi

  if [[ "${VERSION_ID:-}" == "24.04"* ]]; then
    set_preflight_result "OS" "PASS" "${PRETTY_NAME}"
  else
    set_preflight_result "OS" "WARN" "${PRETTY_NAME} (not 24.04)"
  fi
}

check_architecture() {
  if [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
    set_preflight_result "Architecture" "PASS" "$ARCH"
  else
    set_preflight_result "Architecture" "WARN" "$ARCH (tested on arm64)"
  fi
}

check_internet_connectivity() {
  if has_internet; then
    set_preflight_result "Internet" "PASS" "Reachable"
  else
    set_preflight_result "Internet" "FAIL" "No outbound connectivity"
  fi
}

check_dns_resolution() {
  if getent hosts archive.ubuntu.com >/dev/null 2>&1; then
    set_preflight_result "DNS" "PASS" "archive.ubuntu.com resolves"
  else
    set_preflight_result "DNS" "WARN" "DNS resolution failed"
  fi
}

check_disk_space() {
  local avail_mb
  avail_mb=$(df -Pm / | awk 'NR==2{print $4}')

  if ((avail_mb >= 5120)); then
    set_preflight_result "Disk" "PASS" "${avail_mb} MB free"
  elif ((avail_mb >= 2048)); then
    set_preflight_result "Disk" "WARN" "${avail_mb} MB free (low)"
  else
    set_preflight_result "Disk" "FAIL" "${avail_mb} MB free (too low)"
  fi
}

check_ram() {
  local ram_mb
  ram_mb=$(free -m | awk '/^Mem:/ {print $2}')

  if ((ram_mb >= 1024)); then
    set_preflight_result "RAM" "PASS" "${ram_mb} MB"
  else
    set_preflight_result "RAM" "WARN" "${ram_mb} MB (low RAM)"
  fi
}

check_dpkg_locks() {
  local locks=(
    "/var/lib/dpkg/lock-frontend"
    "/var/lib/dpkg/lock"
    "/var/lib/apt/lists/lock"
    "/var/cache/apt/archives/lock"
  )
  local has_lock=false
  local lock

  for lock in "${locks[@]}"; do
    if [[ -e "$lock" ]] && fuser "$lock" >/dev/null 2>&1; then
      has_lock=true
      break
    fi
  done

  if $has_lock; then
    log WARN "Package manager locks detected; running repair routine."
    resolve_apt_locks
  fi

  has_lock=false
  for lock in "${locks[@]}"; do
    if [[ -e "$lock" ]] && fuser "$lock" >/dev/null 2>&1; then
      has_lock=true
      break
    fi
  done

  if $has_lock; then
    set_preflight_result "dpkg Locks" "FAIL" "Locks still active"
  else
    set_preflight_result "dpkg Locks" "PASS" "Clear"
  fi
}

check_rdp_port() {
  local port_line
  port_line=$(ss -H -tlnp "sport = :${RDP_PORT}" 2>/dev/null | head -n1 || true)

  if [[ -n "$port_line" ]]; then
    print_warn "Port ${RDP_PORT} already in use: ${port_line}"

    if [[ "$port_line" == *xrdp* ]]; then
      set_preflight_result "Port ${RDP_PORT}" "WARN" "In use by xrdp (allowed)"
      return 0
    fi

    if confirm_continue "Continue even though port ${RDP_PORT} is in use?"; then
      set_preflight_result "Port ${RDP_PORT}" "WARN" "In use (user accepted)"
    else
      set_preflight_result "Port ${RDP_PORT}" "FAIL" "Port conflict"
    fi
  else
    set_preflight_result "Port ${RDP_PORT}" "PASS" "Available"
  fi
}

check_systemd_status() {
  local state

  if ! pidof systemd >/dev/null 2>&1; then
    set_preflight_result "Systemd" "FAIL" "systemd not running"
    return
  fi

  state=$(systemctl is-system-running 2>/dev/null || true)
  case "$state" in
    running)
      set_preflight_result "Systemd" "PASS" "Running"
      ;;
    degraded|starting|initializing)
      set_preflight_result "Systemd" "WARN" "$state"
      ;;
    *)
      set_preflight_result "Systemd" "WARN" "${state:-unknown}"
      ;;
  esac
}

check_timezone_value() {
  if [[ -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
    set_preflight_result "Timezone" "PASS" "$TIMEZONE"
  else
    set_preflight_result "Timezone" "WARN" "${TIMEZONE} (not found)"
  fi
}

phase_0_preflight_checks() {
  phase_header 0 "Pre-flight Checks"
  print_phase "Pre-flight validation"

  PREFLIGHT_RESULTS=()
  PREFLIGHT_ORDER=()
  PREFLIGHT_HARD_FAIL=false
  capture_system_snapshot

  check_root_access
  check_os_version
  check_architecture
  check_internet_connectivity
  check_dns_resolution
  check_disk_space
  check_ram
  check_dpkg_locks
  check_rdp_port
  check_systemd_status
  check_timezone_value

  print_preflight_summary

  if $PREFLIGHT_HARD_FAIL; then
    log ERROR "Pre-flight checks failed. Resolve failures and re-run."
    exit 1
  fi

  log SUCCESS "Pre-flight checks completed successfully."
}

run_command_with_progress() {
  local label="$1"
  shift

  LAST_CMD_OUTPUT=$(mktemp)

  if $DRY_RUN; then
    print_step "$label"
    log INFO "[dry-run] $*"
    progress_bar 40 40 "$label"
    return 0
  fi

  print_step "$label"

  set +e
  (
    "$@" 2>&1 | tee -a "$LOG_FILE" >"$LAST_CMD_OUTPUT"
  ) &
  local pid=$!
  local current=0
  local total=40

  while kill -0 "$pid" >/dev/null 2>&1; do
    local parsed=0
    if [[ -s "$LAST_CMD_OUTPUT" ]]; then
      parsed=$(grep -E -c '^(Get:|Hit:|Ign:|Fetched|Unpacking|Setting up|Selecting previously unselected package|Processing triggers for)' "$LAST_CMD_OUTPUT" || true)
    fi

    if ((parsed > 0)); then
      current=$parsed
      if ((current > total)); then
        total=$((current + 20))
      fi
    else
      current=$((current + 1))
      if ((current > total)); then
        current=0
      fi
    fi

    progress_bar "$current" "$total" "$label"
    sleep 1
  done

  wait "$pid"
  local rc=$?
  set -e

  if ((rc == 0)); then
    progress_bar "$total" "$total" "$label"
  else
    printf "\n"
  fi

  return "$rc"
}

recover_network_if_needed() {
  local attempt
  for attempt in 1 2 3; do
    if has_internet; then
      return 0
    fi
    log WARN "Internet check failed during install; retrying in 10s (${attempt}/3)."
    sleep 10
  done
  return 1
}

handle_apt_error_output() {
  local out_file="$1"
  [[ -f "$out_file" ]] || return 0

  if grep -qiE 'Could not get lock|Unable to acquire the dpkg frontend lock' "$out_file"; then
    log WARN "Detected apt lock issue. Running lock recovery."
    resolve_apt_locks
  fi

  if grep -qi 'Unable to fetch some archives' "$out_file"; then
    log WARN "Archive fetch issue detected. Running apt-get clean."
    if ! $DRY_RUN; then
      apt-get clean >>"$LOG_FILE" 2>&1 || true
    fi
  fi

  if grep -qi 'dpkg was interrupted' "$out_file"; then
    log WARN "dpkg interrupted state detected. Running dpkg --configure -a."
    if ! $DRY_RUN; then
      dpkg --configure -a >>"$LOG_FILE" 2>&1 || true
    fi
  fi

  if grep -qiE 'Temporary failure resolving|Could not resolve|Failed to fetch' "$out_file"; then
    log WARN "Network/DNS fetch issue detected. Testing connectivity."
    recover_network_if_needed || log ERROR "Internet is unavailable after retries."
  fi
}

run_apt_task() {
  local label="$1"
  local critical="$2"
  shift 2

  local tries=0
  local max_tries=2
  local rc=0

  while ((tries < max_tries)); do
    tries=$((tries + 1))
    if run_command_with_progress "${label} (attempt ${tries}/${max_tries})" "$@"; then
      print_ok "$label"
      rm -f "$LAST_CMD_OUTPUT" 2>/dev/null || true
      return 0
    fi

    rc=$?
    log WARN "${label} failed on attempt ${tries}."
    handle_apt_error_output "$LAST_CMD_OUTPUT"

    if ((tries < max_tries)); then
      log INFO "Retrying ${label}..."
      sleep 2
    fi
  done

  if [[ "$critical" == "true" ]]; then
    log ERROR "${label} failed after ${max_tries} attempts."
    return "$rc"
  fi

  log WARN "${label} failed, but this step is non-critical."
  return 0
}

apt_update() {
  run_apt_task \
    "Fetching package lists" \
    true \
    env DEBIAN_FRONTEND=noninteractive apt-get update
}

apt_upgrade() {
  run_apt_task \
    "Upgrading installed packages" \
    true \
    env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold
}

is_pkg_installed() {
  dpkg -s "$1" >/dev/null 2>&1
}

apt_install_packages() {
  local critical="$1"
  shift

  local to_install=()
  local pkg
  for pkg in "$@"; do
    if is_pkg_installed "$pkg"; then
      log INFO "Package already installed: ${pkg}"
    else
      to_install+=("$pkg")
    fi
  done

  if (( ${#to_install[@]} == 0 )); then
    print_ok "All requested packages are already installed."
    return 0
  fi

  run_apt_task \
    "Installing packages: ${to_install[*]}" \
    "$critical" \
    env DEBIAN_FRONTEND=noninteractive apt-get install -y \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      "${to_install[@]}"
}

mark_phase_complete() {
  local phase="$1"
  if $DRY_RUN; then
    return
  fi

  touch "$PHASE_STATE_FILE"
  if ! grep -Fxq "$phase" "$PHASE_STATE_FILE"; then
    printf "%s\n" "$phase" >>"$PHASE_STATE_FILE"
  fi
}

is_phase_complete() {
  local phase="$1"
  [[ -f "$PHASE_STATE_FILE" ]] && grep -Fxq "$phase" "$PHASE_STATE_FILE"
}

run_phase() {
  local num="$1"
  local name="$2"
  local fn="$3"

  if $RESUME && is_phase_complete "$num"; then
    phase_header "$num" "$name"
    log INFO "Resume mode: skipping already completed phase ${num}."
    return 0
  fi

  phase_header "$num" "$name"
  "$fn"
  mark_phase_complete "$num"
}

ensure_rdp_password() {
  if $DRY_RUN; then
    return 0
  fi

  if [[ -n "$RDP_PASSWORD" ]]; then
    return 0
  fi

  if [[ -n "${RDP_PASSWORD:-}" ]]; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    log ERROR "RDP password not provided. Use --rdp-password or RDP_PASSWORD env in non-interactive mode."
    return 1
  fi

  local p1 p2
  while true; do
    read -r -s -p "Set password for ${RDP_USER}: " p1
    echo
    read -r -s -p "Confirm password for ${RDP_USER}: " p2
    echo

    if [[ -z "$p1" ]]; then
      print_warn "Password cannot be empty."
      continue
    fi

    if [[ "$p1" != "$p2" ]]; then
      print_warn "Passwords do not match. Try again."
      continue
    fi

    RDP_PASSWORD="$p1"
    break
  done
}

ensure_rdp_user() {
  local user="$1"

  if ! id "$user" >/dev/null 2>&1; then
    print_step "Creating desktop user '${user}'"
    if ! $DRY_RUN; then
      useradd -m -s /bin/bash "$user"
    fi
  else
    print_ok "Desktop user '${user}' already exists"
  fi

  if ! $DRY_RUN && [[ -n "$RDP_PASSWORD" ]]; then
    print_step "Setting password for '${user}'"
    printf "%s:%s\n" "$user" "$RDP_PASSWORD" | chpasswd
  fi
}

user_home_dir() {
  local user="$1"
  getent passwd "$user" | awk -F: '{print $6}'
}

apply_xfce_user_config() {
  local user="$1"
  local home_dir
  home_dir=$(user_home_dir "$user")

  [[ -n "$home_dir" ]] || return 1

  if ! $DRY_RUN; then
    mkdir -p "$home_dir/.config/xfce4/xfconf/xfce-perchannel-xml"

    backup_existing_file "$home_dir/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"
    cat >"$home_dir/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
    <property name="theme" type="string" value="Default"/>
  </property>
</channel>
XML

    backup_existing_file "$home_dir/.xsession"
    printf 'xfce4-session\n' >"$home_dir/.xsession"
    chmod 644 "$home_dir/.xsession"

    # If panel file has no plugins defined, preserve it and let XFCE recreate defaults.
    local panel_xml="$home_dir/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
    if [[ -f "$panel_xml" ]] && ! grep -q 'plugin-' "$panel_xml"; then
      backup_existing_file "$panel_xml"
    fi

    mkdir -p "$home_dir/.config/autostart"
    backup_existing_file "$home_dir/.config/autostart/terminal.desktop"
    cat >"$home_dir/.config/autostart/terminal.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=XFCE Terminal
Exec=xfce4-terminal
X-GNOME-Autostart-enabled=true
DESKTOP

    ensure_line_in_file "xset s off" "$home_dir/.xsessionrc"
    ensure_line_in_file "xset -dpms" "$home_dir/.xsessionrc"

    chown -R "$user:$user" "$home_dir/.config" "$home_dir/.xsession" "$home_dir/.xsessionrc"
  else
    log INFO "[dry-run] Would write XFCE config for ${user}"
  fi
}

configure_xrdp_ini() {
  local file="/etc/xrdp/xrdp.ini"

  if [[ ! -f "$file" ]]; then
    log ERROR "xrdp.ini not found at ${file}"
    return 1
  fi

  if grep -q '^port=' "$file"; then
    sed -i -E "0,/^port=.*/s//port=${RDP_PORT}/" "$file"
  else
    printf "port=%s\n" "$RDP_PORT" >>"$file"
  fi

  if grep -q '^max_bpp=' "$file"; then
    sed -i 's/^max_bpp=.*/max_bpp=16/' "$file"
  else
    echo 'max_bpp=16' >>"$file"
  fi

  if grep -q '^xserverbpp=' "$file"; then
    sed -i 's/^xserverbpp=.*/xserverbpp=16/' "$file"
  else
    echo 'xserverbpp=16' >>"$file"
  fi

  # Favor responsiveness over extra virtual channels on low-bandwidth links.
  sed -i '/^\[Channels\]/,/^\[/ {
    s/^rdpdr=.*/rdpdr=false/
    s/^rdpsnd=.*/rdpsnd=false/
    s/^drdynvc=.*/drdynvc=false/
    s/^rail=.*/rail=false/
    s/^xrdpvr=.*/xrdpvr=false/
    s/^tcutils=.*/tcutils=false/
    s/^cliprdr=.*/cliprdr=true/
  }' "$file"
}

is_web_server_active() {
  if systemctl is-active --quiet nginx || systemctl is-active --quiet apache2; then
    return 0
  fi

  if ss -tlnp 2>/dev/null | grep -Eq ':(80|443)\b'; then
    return 0
  fi

  return 1
}

is_port_listening() {
  local port="$1"
  ss -H -tln "sport = :${port}" 2>/dev/null | awk 'NR==1 {found=1} END {exit(found ? 0 : 1)}'
}

wait_for_service_port() {
  local service="$1"
  local port="$2"
  local timeout="${3:-20}"
  local i

  for ((i = 1; i <= timeout; i++)); do
    if systemctl is-active --quiet "$service" && is_port_listening "$port"; then
      return 0
    fi
    sleep 1
  done

  return 1
}

phase_1_system_prep() {
  print_step "Preparing package manager state"

  if ! $DRY_RUN; then
    resolve_apt_locks
    dpkg --configure -a >>"$LOG_FILE" 2>&1 || true
    env DEBIAN_FRONTEND=noninteractive apt-get -f install -y >>"$LOG_FILE" 2>&1 || true
  else
    log INFO "[dry-run] Would repair apt/dpkg state if required."
  fi

  apt_update

  if $WITH_UPGRADE; then
    apt_upgrade
  else
    print_warn "Skipping apt upgrade (default). Use --with-upgrade to enable."
  fi

  apt_install_packages true \
    ca-certificates curl wget git nano htop net-tools software-properties-common gnupg lsb-release sudo

  apt_install_packages false \
    apt-transport-https lsof psmisc

  if [[ "$INSTALL_TOOLS" == "true" ]]; then
    apt_install_packages false \
      bash-completion unzip zip p7zip-full jq ripgrep tree tmux btop ncdu xdg-utils shellcheck
  else
    print_warn "Extra tools installation skipped by configuration"
  fi
}

phase_2_swap_setup() {
  local required_bytes
  local current_swap
  local needed_bytes
  local swap_target
  local mb_count

  required_bytes=$(size_to_bytes "$SWAP_SIZE")
  current_swap=$(swapon --show=SIZE --bytes --noheadings 2>/dev/null | awk '{sum+=$1} END{print sum+0}')

  if [[ -z "$current_swap" ]]; then
    current_swap=0
  fi

  if ((current_swap >= required_bytes)); then
    print_ok "Existing swap is already sufficient."
    COMP_SWAP="[OK] ${SWAP_SIZE} Swap (existing)"
    return 0
  fi

  needed_bytes=$((required_bytes - current_swap))
  if ((needed_bytes < 268435456)); then
    needed_bytes=268435456
  fi

  mb_count=$(((needed_bytes + 1048575) / 1048576))
  swap_target="/swapfile.vpsdesktop"
  if [[ -e "$swap_target" ]]; then
    swap_target="/swapfile.vpsdesktop.$(date +%s)"
  fi

  print_step "Creating additional non-destructive swap file (${mb_count}M)"
  if ! $DRY_RUN; then
    if ! fallocate -l "${mb_count}M" "$swap_target" 2>>"$LOG_FILE"; then
      dd if=/dev/zero of="$swap_target" bs=1M count="$mb_count" status=progress >>"$LOG_FILE" 2>&1
    fi

    chmod 600 "$swap_target"
    mkswap "$swap_target" >>"$LOG_FILE" 2>&1
    swapon "$swap_target"

    if ! awk -v s="$swap_target" '$1==s {found=1} END{exit(found?0:1)}' /etc/fstab; then
      printf '%s none swap sw 0 0\n' "$swap_target" >>/etc/fstab
    fi

    set_config_kv "/etc/sysctl.d/99-vps-desktop.conf" "vm.swappiness" "10"
    sysctl -w vm.swappiness=10 >>"$LOG_FILE" 2>&1 || true
  else
    log INFO "[dry-run] Would create and enable ${swap_target} (${mb_count}M) without deleting existing swap files."
  fi

  swapon --show >>"$LOG_FILE" 2>&1 || true
  free -h >>"$LOG_FILE" 2>&1 || true
  print_ok "Swap configured non-destructively (${swap_target})"
  COMP_SWAP="[OK] ${SWAP_SIZE} Swap (non-destructive)"
}

phase_3_desktop_xfce() {
  print_step "Installing desktop environment (XFCE)"
  apt_install_packages true \
    xfce4 xfce4-goodies xfce4-whiskermenu-plugin dbus-x11 x11-xserver-utils xfonts-base pulseaudio xfce4-terminal

  if $DRY_RUN; then
    log INFO "[dry-run] Skipping runtime XFCE binary verification and user configuration."
    COMP_XFCE="[OK] XFCE4 Desktop (dry-run)"
    return 0
  fi

  if command -v xfce4-session >/dev/null 2>&1; then
    print_ok "xfce4-session detected"
  else
    log ERROR "XFCE installation failed: xfce4-session not found"
    return 1
  fi

  ensure_rdp_password
  ensure_rdp_user "$RDP_USER"
  apply_xfce_user_config "$RDP_USER"

  COMP_XFCE="[OK] XFCE4 Desktop"
  print_ok "XFCE desktop installed and user config applied"
}

phase_4_xrdp_setup() {
  apt_install_packages true xrdp xorgxrdp

  print_step "Granting xrdp SSL cert group permission"
  if ! $DRY_RUN; then
    adduser xrdp ssl-cert >>"$LOG_FILE" 2>&1 || true
  else
    log INFO "[dry-run] Would add user xrdp to ssl-cert group."
  fi

  print_step "Configuring XRDP for XFCE and user ${RDP_USER}"
  if ! $DRY_RUN; then
    configure_xrdp_ini

    backup_existing_file "/etc/xrdp/startwm.sh"
    cat >/etc/xrdp/startwm.sh <<'SH'
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
[ -r "$HOME/.profile" ] && . "$HOME/.profile"
exec startxfce4
SH
    chmod 755 /etc/xrdp/startwm.sh

    systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true
    systemctl enable xrdp >>"$LOG_FILE" 2>&1
    systemctl restart xrdp
  else
    log INFO "[dry-run] Would configure /etc/xrdp/xrdp.ini and /etc/xrdp/startwm.sh"
  fi

  if $DRY_RUN; then
    print_ok "XRDP setup simulated"
    COMP_XRDP="[OK] XRDP (dry-run)"
    return 0
  fi

  if wait_for_service_port xrdp "$RDP_PORT" 20; then
    print_ok "XRDP service active and port ${RDP_PORT} listening"
    COMP_XRDP="[OK] XRDP"
  else
    log ERROR "XRDP failed to start correctly. Last logs:"
    journalctl -u xrdp --no-pager -n 40 >>"$LOG_FILE" 2>&1 || true
    journalctl -u xrdp --no-pager -n 20 || true
    return 1
  fi
}

install_firefox_mozilla_tarball() {
  local user="$1"
  local os_slug="linux64"
  local archive_url
  local tmp_archive
  local user_home

  if [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
    os_slug="linux64-aarch64"
  fi

  archive_url="https://download.mozilla.org/?product=firefox-latest&os=${os_slug}&lang=en-US"
  tmp_archive=$(mktemp /tmp/firefox-latest.XXXXXX.tar.xz)

  print_step "Installing Mozilla Firefox binary (${os_slug})"
  curl -fsSL "$archive_url" -o "$tmp_archive"
  backup_existing_path "/opt/firefox"
  tar -xJf "$tmp_archive" -C /opt
  rm -f "$tmp_archive"

  backup_existing_file "/usr/local/bin/firefox"
  cat >/usr/local/bin/firefox <<'SH'
#!/usr/bin/env bash
exec /opt/firefox/firefox "$@"
SH
  chmod +x /usr/local/bin/firefox

  backup_existing_file "/usr/share/applications/firefox-local.desktop"
  cat >/usr/share/applications/firefox-local.desktop <<'DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=Firefox
Comment=Web Browser
Exec=/usr/local/bin/firefox %u
Terminal=false
Icon=/opt/firefox/browser/chrome/icons/default/default128.png
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
StartupNotify=true
DESKTOP
  chmod 644 /usr/share/applications/firefox-local.desktop

  user_home=$(user_home_dir "$user")
  if [[ -n "$user_home" ]]; then
    mkdir -p "$user_home/Desktop"
    backup_existing_file "$user_home/Desktop/firefox.desktop"
    cat >"$user_home/Desktop/firefox.desktop" <<'DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=Firefox
Exec=/usr/local/bin/firefox
Icon=/opt/firefox/browser/chrome/icons/default/default128.png
Terminal=false
Categories=Network;WebBrowser;
DESKTOP
    chmod +x "$user_home/Desktop/firefox.desktop"
    chown "$user:$user" "$user_home/Desktop/firefox.desktop"
  fi
}

firefox_works() {
  local bin
  bin=$(resolve_firefox_binary) || return 1
  "$bin" --version >/dev/null 2>&1
}

resolve_firefox_binary() {
  local candidate
  local cmd_path

  cmd_path=$(command -v firefox 2>/dev/null || true)
  for candidate in "$cmd_path" /snap/bin/firefox /usr/local/bin/firefox /opt/firefox/firefox; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf "%s" "$candidate"
      return 0
    fi
  done

  return 1
}

record_firefox_details() {
  local bin
  local version

  if ! bin=$(resolve_firefox_binary); then
    FIREFOX_BIN="Unavailable"
    FIREFOX_VERSION="Unavailable"
    return 1
  fi

  version=$("$bin" --version 2>/dev/null | head -n1 || true)
  if [[ -z "$version" ]]; then
    FIREFOX_BIN="$bin"
    FIREFOX_VERSION="Unknown"
    return 1
  fi

  FIREFOX_BIN="$bin"
  FIREFOX_VERSION="$version"
  return 0
}

phase_5_firefox_setup() {
  if [[ "$INSTALL_FIREFOX" != "true" ]]; then
    print_warn "Firefox installation disabled by profile/flags"
    COMP_FIREFOX="[ ] Firefox (disabled)"
    return 0
  fi

  if firefox_works; then
    record_firefox_details || true
    print_ok "Firefox already installed"
    COMP_FIREFOX="[OK] Firefox (existing)"
    return 0
  fi

  print_step "Trying Firefox package-based install"
  apt_install_packages false firefox snapd

  if ! $DRY_RUN; then
    systemctl enable --now snapd.socket >>"$LOG_FILE" 2>&1 || true
    systemctl start snapd.apparmor >>"$LOG_FILE" 2>&1 || true
    sleep 5

    if command -v snap >/dev/null 2>&1; then
      snap wait system seed.loaded >>"$LOG_FILE" 2>&1 || true
      if ! firefox_works; then
        snap install firefox --stable >>"$LOG_FILE" 2>&1 || true
      fi
    fi
  else
    log INFO "[dry-run] Would install Firefox packages and verify startup"
  fi

  if $DRY_RUN || firefox_works; then
    record_firefox_details || true
    print_ok "Firefox installed"
    COMP_FIREFOX="[OK] Firefox"
  else
    log WARN "Package Firefox install unusable; applying Mozilla tarball fallback."
    if ! $DRY_RUN; then
      install_firefox_mozilla_tarball "$RDP_USER"
    fi

    if $DRY_RUN || firefox_works; then
      record_firefox_details || true
      print_ok "Firefox installed via Mozilla tarball fallback"
      COMP_FIREFOX="[OK] Firefox (mozilla-fallback)"
    else
      log WARN "Firefox installation failed in all methods; continuing (non-critical)."
      COMP_FIREFOX="[ ] Firefox (failed)"
    fi
  fi
}

phase_6_firewall_security() {
  if [[ "$RUN_FIREWALL" != "true" ]]; then
    print_warn "Firewall configuration disabled by profile"
    COMP_UFW="[ ] UFW (disabled)"
  else
    apt_install_packages true ufw

    print_step "Configuring UFW without reset (preserving existing rules)"
    if ! $DRY_RUN; then
      if ! ufw status | grep -q "Status: active"; then
        ufw default deny incoming >>"$LOG_FILE" 2>&1
        ufw default allow outgoing >>"$LOG_FILE" 2>&1
      fi

      ufw allow "${SSH_PORT}/tcp" comment "SSH" >>"$LOG_FILE" 2>&1 || true
      ufw allow "${RDP_PORT}/tcp" comment "XRDP Remote Desktop" >>"$LOG_FILE" 2>&1 || true

      if is_web_server_active; then
        ufw allow 80/tcp comment "HTTP" >>"$LOG_FILE" 2>&1 || true
        ufw allow 443/tcp comment "HTTPS" >>"$LOG_FILE" 2>&1 || true
        log INFO "Web service detected; ensured UFW allows 80/tcp and 443/tcp"
      fi

      ufw --force enable >>"$LOG_FILE" 2>&1 || true
      ufw status verbose >>"$LOG_FILE" 2>&1 || true
    else
      log INFO "[dry-run] Would ensure UFW rules for SSH/RDP and auto-allow 80/443 if web service detected."
    fi

    COMP_UFW="[OK] UFW Firewall"
    print_ok "UFW configured"
  fi

  if [[ "$INSTALL_FAIL2BAN" != "true" ]]; then
    print_warn "Fail2ban installation disabled by configuration"
    COMP_FAIL2BAN="[ ] Fail2ban (disabled)"
    return 0
  fi

  apt_install_packages false fail2ban

  print_step "Applying basic fail2ban protection"
  if ! $DRY_RUN; then
    mkdir -p /etc/fail2ban/jail.d
    backup_existing_file "/etc/fail2ban/jail.d/vps-desktop.local"
    {
      echo "[sshd]"
      echo "enabled = true"
      echo "port = ${SSH_PORT}"
      echo "maxretry = 5"
      echo "findtime = 10m"
      echo "bantime = 1h"
      if [[ -f /etc/fail2ban/filter.d/xrdp.conf ]]; then
        echo
        echo "[xrdp]"
        echo "enabled = true"
        echo "port = ${RDP_PORT}"
        echo "logpath = /var/log/xrdp.log"
        echo "maxretry = 5"
      fi
    } >/etc/fail2ban/jail.d/vps-desktop.local

    systemctl enable fail2ban >>"$LOG_FILE" 2>&1 || true
    systemctl restart fail2ban >>"$LOG_FILE" 2>&1 || true
  else
    log INFO "[dry-run] Would create /etc/fail2ban/jail.d/vps-desktop.local"
  fi

  COMP_FAIL2BAN="[OK] Fail2ban"
  print_ok "Fail2ban configured"
}

phase_7_system_optimization() {
  print_step "Applying kernel and system tuning"
  if ! $DRY_RUN; then
    set_config_kv "/etc/sysctl.d/99-vps-desktop.conf" "vm.swappiness" "10"
    set_config_kv "/etc/sysctl.d/99-vps-desktop.conf" "net.core.somaxconn" "65535"
    set_config_kv "/etc/sysctl.d/99-vps-desktop.conf" "fs.file-max" "65535"
    sysctl --system >>"$LOG_FILE" 2>&1 || true
  else
    log INFO "[dry-run] Would apply sysctl tuning values."
  fi

  print_step "Setting timezone to ${TIMEZONE}"
  if ! $DRY_RUN; then
    if [[ -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
      timedatectl set-timezone "$TIMEZONE" >>"$LOG_FILE" 2>&1 || true
    else
      log WARN "Timezone ${TIMEZONE} not found; skipping timezone update."
    fi
  else
    log INFO "[dry-run] Would run timedatectl set-timezone ${TIMEZONE}"
  fi

  print_step "Creating desktop connection guide"
  PUBLIC_IP=$(get_public_ip)
  if ! $DRY_RUN; then
    local user_home
    user_home=$(user_home_dir "$RDP_USER")
    if [[ -n "$user_home" ]]; then
      mkdir -p "$user_home/Desktop"
      chown "$RDP_USER:$RDP_USER" "$user_home/Desktop"
      backup_existing_file "$user_home/Desktop/HOW_TO_CONNECT.txt"
      cat >"$user_home/Desktop/HOW_TO_CONNECT.txt" <<TXT
VPS Remote Desktop Connection Guide
===================================

Windows:
  1) Press Win+R
  2) Type: mstsc
  3) Connect to: ${PUBLIC_IP}:${RDP_PORT}

Android/iOS:
  1) Install Microsoft Remote Desktop app
  2) Host: ${PUBLIC_IP}:${RDP_PORT}

Username: ${RDP_USER}
Password: [the password you set during installation]

Cockpit Web Panel (if installed):
  URL: https://${PUBLIC_IP}:9090
TXT
      chown "$RDP_USER:$RDP_USER" "$user_home/Desktop/HOW_TO_CONNECT.txt"
    fi
  else
    log INFO "[dry-run] Would create HOW_TO_CONNECT.txt for ${RDP_USER}."
  fi

  print_ok "System optimization completed"
}

phase_8_permanent_uptime() {
  print_step "Masking sleep/hibernate targets"
  if ! $DRY_RUN; then
    systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >>"$LOG_FILE" 2>&1 || true
  else
    log INFO "[dry-run] Would mask sleep/suspend/hibernate targets."
  fi

  print_step "Updating logind configuration"
  if ! $DRY_RUN; then
    set_config_kv "/etc/systemd/logind.conf" "IdleAction" "ignore"
    set_config_kv "/etc/systemd/logind.conf" "HandleLidSwitch" "ignore"
    set_config_kv "/etc/systemd/logind.conf" "HandleLidSwitchExternalPower" "ignore"
    set_config_kv "/etc/systemd/logind.conf" "HandleSuspendKey" "ignore"
    set_config_kv "/etc/systemd/logind.conf" "HandleHibernateKey" "ignore"
    set_config_kv "/etc/systemd/logind.conf" "HandlePowerKey" "ignore"
    systemctl restart systemd-logind >>"$LOG_FILE" 2>&1 || true
  else
    log INFO "[dry-run] Would update /etc/systemd/logind.conf"
  fi

  print_step "Disabling unattended automatic reboot"
  if ! $DRY_RUN; then
    touch /etc/apt/apt.conf.d/50unattended-upgrades
    if grep -Eq '^[[:space:]#]*Unattended-Upgrade::Automatic-Reboot' /etc/apt/apt.conf.d/50unattended-upgrades; then
      sed -i 's|^[[:space:]#]*Unattended-Upgrade::Automatic-Reboot.*|Unattended-Upgrade::Automatic-Reboot "false";|' /etc/apt/apt.conf.d/50unattended-upgrades
    else
      echo 'Unattended-Upgrade::Automatic-Reboot "false";' >>/etc/apt/apt.conf.d/50unattended-upgrades
    fi
  else
    log INFO "[dry-run] Would enforce Unattended-Upgrade::Automatic-Reboot \"false\";"
  fi

  if ! $DRY_RUN; then
    systemctl is-enabled sleep.target >>"$LOG_FILE" 2>&1 || true
    uptime >>"$LOG_FILE" 2>&1 || true
  fi

  print_ok "Permanent uptime protections applied"
}

phase_9_web_admin_panel() {
  if [[ "$INSTALL_COCKPIT" != "true" ]]; then
    print_warn "Cockpit installation disabled by profile/flags"
    COMP_COCKPIT="[ ] Cockpit (disabled)"
    return 0
  fi

  apt_install_packages false cockpit cockpit-packagekit

  print_step "Enabling cockpit.socket"
  if ! $DRY_RUN; then
    systemctl enable --now cockpit.socket >>"$LOG_FILE" 2>&1 || true

    if ufw status | grep -q "Status: active"; then
      ufw allow 9090/tcp comment "Cockpit Web Admin" >>"$LOG_FILE" 2>&1 || true
    fi
  else
    log INFO "[dry-run] Would enable cockpit.socket and allow 9090/tcp in UFW."
  fi

  if $DRY_RUN || (systemctl is-active --quiet cockpit.socket && ss -tlnp | grep -q ':9090\b'); then
    COMP_COCKPIT="[OK] Cockpit"
    print_ok "Cockpit web panel configured (https://<IP>:9090)"
  else
    COMP_COCKPIT="[ ] Cockpit (failed)"
    log WARN "Cockpit verification failed; check 'systemctl status cockpit.socket'."
  fi
}

phase_10_testing_and_verification() {
  if $DRY_RUN; then
    print_step "Dry-run verification"
    log INFO "Dry-run mode: runtime service checks skipped."
    generate_final_report
    print_ok "Testing and verification simulated"
    return 0
  fi

  print_step "Running service checks"
  local xrdp_state
  local sesman_state
  local ufw_state
  local fail2ban_state

  xrdp_state=$(systemctl is-active xrdp 2>/dev/null || echo "inactive")
  sesman_state=$(systemctl is-active xrdp-sesman 2>/dev/null || echo "inactive")
  ufw_state=$(systemctl is-active ufw 2>/dev/null || echo "inactive")
  fail2ban_state=$(systemctl is-active fail2ban 2>/dev/null || echo "inactive")

  printf "%b\n" "${BOLD}+----------------------+--------------------+${RESET}"
  printf "%b\n" "${BOLD}| Service              | Status             |${RESET}"
  printf "%b\n" "${BOLD}+----------------------+--------------------+${RESET}"
  printf "| %-20s | %-18s |\n" "xrdp" "$xrdp_state"
  printf "| %-20s | %-18s |\n" "xrdp-sesman" "$sesman_state"
  printf "| %-20s | %-18s |\n" "ufw" "$ufw_state"
  printf "| %-20s | %-18s |\n" "fail2ban" "$fail2ban_state"
  printf "%b\n" "${BOLD}+----------------------+--------------------+${RESET}"

  print_step "Port verification"
  if is_port_listening "$RDP_PORT"; then
    print_ok "Port ${RDP_PORT} is listening"
  else
    print_fail "Port ${RDP_PORT} is not listening"
  fi

  if [[ "$RUN_FIREWALL" == "true" ]]; then
    print_step "UFW rule verification"
    if ! $DRY_RUN; then
      ufw status numbered >>"$LOG_FILE" 2>&1 || true
    fi
  fi

  print_step "XFCE verification"
  if command -v xfce4-session >/dev/null 2>&1; then
    log SUCCESS "xfce4-session found at $(command -v xfce4-session)"
    xfce4-session --version >>"$LOG_FILE" 2>&1 || true
  else
    log ERROR "xfce4-session not found"
  fi

  if [[ "$INSTALL_FIREFOX" == "true" ]]; then
    print_step "Firefox verification"
    if record_firefox_details; then
      log SUCCESS "Firefox verified at ${FIREFOX_BIN}"
      printf "%s\n" "${FIREFOX_VERSION}" >>"$LOG_FILE"
    else
      log WARN "Firefox verification failed; attempting Mozilla tarball repair."
      install_firefox_mozilla_tarball "$RDP_USER" >>"$LOG_FILE" 2>&1 || true

      if record_firefox_details; then
        log SUCCESS "Firefox repaired at ${FIREFOX_BIN}"
        printf "%s\n" "${FIREFOX_VERSION}" >>"$LOG_FILE"
        COMP_FIREFOX="[OK] Firefox (repaired)"
      else
        log ERROR "Firefox still unusable after repair attempt."
        COMP_FIREFOX="[ ] Firefox (verification failed)"
      fi
    fi
  fi

  print_step "Swap and disk checks"
  swapon --show >>"$LOG_FILE" 2>&1 || true
  df -h / >>"$LOG_FILE" 2>&1 || true

  print_step "Log file summary"
  local log_lines
  local log_errors
  log_lines=$(wc -l <"$LOG_FILE" 2>/dev/null || echo 0)
  log_errors=$(grep -c "\[ERROR\]" "$LOG_FILE" 2>/dev/null || true)
  log_errors=${log_errors:-0}
  log INFO "Log lines: ${log_lines}"
  log INFO "Logged errors: ${log_errors}"

  generate_final_report
  print_ok "Testing and verification completed"
}

generate_final_report() {
  if [[ "$REPORT_GENERATED" == "true" ]]; then
    return 0
  fi
  REPORT_GENERATED=true

  local end_time
  local elapsed
  local elapsed_human
  local os_pretty
  local xrdp_version
  local log_errors

  end_time=$(date +%s)
  elapsed=$((end_time - START_TIME))
  elapsed_human=$(seconds_to_human "$elapsed")
  capture_system_snapshot

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    os_pretty="${PRETTY_NAME:-Unknown}"
  else
    os_pretty="Unknown"
  fi

  if [[ "$PUBLIC_IP" == "Unavailable" ]]; then
    PUBLIC_IP=$(get_public_ip)
  fi

  xrdp_version=$(xrdp --version 2>/dev/null | head -n1 || echo "Unknown")
  record_firefox_details || true
  log_errors=$(grep -c "\[ERROR\]" "$LOG_FILE" 2>/dev/null || true)
  log_errors=${log_errors:-$ERROR_COUNT}

  cat >"$REPORT_FILE" <<REPORT
============================================================
VPS DESKTOP SETUP REPORT
============================================================
Date: $(date '+%Y-%m-%d %H:%M:%S')
Script Version: ${SCRIPT_VERSION}
Total Time: ${elapsed_human}

SYSTEM INFO:
  OS: ${os_pretty}
  Arch: ${ARCH}
  CPU: ${SYS_CPU_MODEL}
  CPU Cores/Threads: ${SYS_CPU_CORES}/${SYS_CPU_THREADS}
  CPU GHz (cur/max): ${SYS_CPU_CUR_GHZ}/${SYS_CPU_MAX_GHZ}
  RAM GB (total/used/free): ${SYS_RAM_TOTAL_GB}/${SYS_RAM_USED_GB}/${SYS_RAM_FREE_GB}
  Storage / GB (total/used/free): ${SYS_DISK_TOTAL_GB}/${SYS_DISK_USED_GB}/${SYS_DISK_FREE_GB}
  IP: ${PUBLIC_IP}

CONFIG:
  Profile: ${PROFILE}
  SSH Port: ${SSH_PORT}
  RDP Port: ${RDP_PORT}
  Desktop User: ${RDP_USER}
  Timezone: ${TIMEZONE}
  Upgrade Enabled: ${WITH_UPGRADE}

INSTALLED COMPONENTS:
  ${COMP_XFCE}
  ${COMP_XRDP}
  ${COMP_FIREFOX}
  ${COMP_UFW}
  ${COMP_FAIL2BAN}
  ${COMP_SWAP}
  ${COMP_COCKPIT}
  XRDP Version: ${xrdp_version}
  Firefox Binary: ${FIREFOX_BIN}
  Firefox Version: ${FIREFOX_VERSION}

CONNECTION INFO:
  Windows: mstsc -> ${PUBLIC_IP}:${RDP_PORT}
  Username: ${RDP_USER}
  Password: [the password configured during setup]

  Mobile: Microsoft RDP app
  Host: ${PUBLIC_IP}:${RDP_PORT}

  Cockpit Panel (if installed):
  URL: https://${PUBLIC_IP}:9090

ERRORS ENCOUNTERED: ${log_errors}
Full log: ${LOG_FILE}
============================================================
REPORT

  log SUCCESS "Final report generated at ${REPORT_FILE}"
}

on_error() {
  local rc=$?
  local line="$1"
  SCRIPT_EXIT_CODE="$rc"
  log ERROR "Unhandled error at line ${line} (exit code ${rc})."
  exit "$rc"
}

cleanup() {
  if [[ "$CLEANUP_DONE" == "true" ]]; then
    return
  fi
  CLEANUP_DONE=true

  set +e
  if [[ -d "$LOG_DIR" ]]; then
    generate_final_report
  fi

  if ((SCRIPT_EXIT_CODE != 0)); then
    print_fail "Script failed. Check log: ${LOG_FILE}"
  else
    print_ok "Script completed successfully. Report: ${REPORT_FILE}"
  fi
}

on_exit() {
  SCRIPT_EXIT_CODE=$?
  cleanup
}

main() {
  parse_args "$@"
  apply_profile_defaults

  if ! validate_numeric_port "$SSH_PORT"; then
    echo "Invalid SSH port: ${SSH_PORT}"
    exit 1
  fi
  if ! validate_numeric_port "$RDP_PORT"; then
    echo "Invalid RDP port: ${RDP_PORT}"
    exit 1
  fi

  if [[ "$EUID" -ne 0 ]]; then
    echo "Please run as root: sudo bash ${SCRIPT_NAME}"
    exit 1
  fi

  print_header
  setup_logging

  log INFO "Starting setup (v${SCRIPT_VERSION})"
  log INFO "Options: dry_run=${DRY_RUN}, resume=${RESUME}, with_upgrade=${WITH_UPGRADE}, profile=${PROFILE}, ssh_port=${SSH_PORT}, rdp_port=${RDP_PORT}, rdp_user=${RDP_USER}, timezone=${TIMEZONE}"
  log INFO "Feature flags: firefox=${INSTALL_FIREFOX}, cockpit=${INSTALL_COCKPIT}, fail2ban=${INSTALL_FAIL2BAN}, firewall=${RUN_FIREWALL}"

  phase_0_preflight_checks

  if $DRY_RUN; then
    run_phase 1 "System Preparation" phase_1_system_prep
    run_phase 2 "Swap Memory Setup" phase_2_swap_setup
    run_phase 3 "Desktop Environment (XFCE4)" phase_3_desktop_xfce
    run_phase 4 "Remote Desktop (XRDP)" phase_4_xrdp_setup
    run_phase 5 "Firefox Browser" phase_5_firefox_setup
    run_phase 6 "Firewall and Security" phase_6_firewall_security
    run_phase 7 "System Optimization" phase_7_system_optimization
    run_phase 8 "Permanent Uptime" phase_8_permanent_uptime
    run_phase 9 "Web Admin Login Panel (Cockpit)" phase_9_web_admin_panel
    run_phase 10 "Testing and Verification" phase_10_testing_and_verification

    log SUCCESS "Dry-run complete. No changes were made."
    return 0
  fi

  run_phase 1 "System Preparation" phase_1_system_prep
  run_phase 2 "Swap Memory Setup" phase_2_swap_setup
  run_phase 3 "Desktop Environment (XFCE4)" phase_3_desktop_xfce
  run_phase 4 "Remote Desktop (XRDP)" phase_4_xrdp_setup
  run_phase 5 "Firefox Browser" phase_5_firefox_setup
  run_phase 6 "Firewall and Security" phase_6_firewall_security
  run_phase 7 "System Optimization" phase_7_system_optimization
  run_phase 8 "Permanent Uptime" phase_8_permanent_uptime
  run_phase 9 "Web Admin Login Panel (Cockpit)" phase_9_web_admin_panel
  run_phase 10 "Testing and Verification" phase_10_testing_and_verification

  log SUCCESS "All phases completed successfully."
}

trap 'on_error $LINENO' ERR
trap on_exit EXIT

main "$@"
