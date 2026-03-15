#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="1.1.0"
DEFAULT_BASELINE_FILE="/opt/server-perf-baseline.json"
WORK_DIR="/tmp/server-perf-$$"
PING_TARGET="1.1.1.1"
DOWNLOAD_URL="https://proof.ovh.net/files/100Mb.dat"
FIO_SIZE="512M"
FIO_RUNTIME=12

INSTALL_DEPS=true
SET_BASELINE=false
BASELINE_FILE="$DEFAULT_BASELINE_FILE"
BASELINE_SCORE=""
BASELINE_ADJUST_PCT=30
LABEL="$(hostname)"

SEQ_WRITE_MBPS=0
SEQ_READ_MBPS=0
RAND_READ_IOPS=0
DOWNLOAD_MBPS=0
PING_AVG_MS=0
PING_JITTER_MS=0

DISK_WRITE_SCORE=0
DISK_READ_SCORE=0
RAND_IOPS_SCORE=0
DOWNLOAD_SCORE=0
PING_SCORE=0
JITTER_SCORE=0
COMPOSITE_SCORE=0
RAW_IMPROVEMENT_PCT=0
EFFECTIVE_BASELINE_SCORE=""
EFFECTIVE_IMPROVEMENT_PCT=0
CATEGORY="As Good"

CPU_MODEL="Unknown"
CPU_CORES=0
CPU_THREADS=0
CPU_CUR_GHZ=0
CPU_MAX_GHZ=0
RAM_TOTAL_GB=0
RAM_USED_GB=0
RAM_FREE_GB=0
STORAGE_TOTAL_GB=0
STORAGE_USED_GB=0
STORAGE_FREE_GB=0

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
BOLD='\033[1m'
RESET='\033[0m'

usage() {
  cat <<USAGE
Usage: sudo bash server_perf_tester.sh [options]

Options:
  --set-baseline                 Save current server score as baseline JSON.
  --baseline-file <path>         Baseline file path (default: ${DEFAULT_BASELINE_FILE}).
  --baseline-score <score>       Compare against explicit baseline score.
  --baseline-adjust-pct <n>      Reduce baseline by n% for category logic (default: ${BASELINE_ADJUST_PCT}).
  --no-install-deps              Skip auto-install of benchmark dependencies.
  --quick                        Faster test mode (smaller/shorter fio).
  --label <name>                 Friendly name for this server in output.
  --download-url <url>           File URL for download speed test.
  --ping-target <host>           Ping target for latency/jitter test.
  --help                         Show help.

Category logic vs effective baseline:
  As Good: < 50% better
  Very Good: >= 50% better
  Excellent: around 100% better (95% to 100%)
  Pro Level: > 100% better

One-command (GitHub raw):
  Set baseline:
    curl -fsSL https://raw.githubusercontent.com/malikarslan699/scripts/main/server_perf_tester.sh | sudo bash -s -- --set-baseline
  Compare with saved baseline:
    curl -fsSL https://raw.githubusercontent.com/malikarslan699/scripts/main/server_perf_tester.sh | sudo bash -s --
  Quick mode compare:
    curl -fsSL https://raw.githubusercontent.com/malikarslan699/scripts/main/server_perf_tester.sh | sudo bash -s -- --quick

Safety:
  Existing baseline file is preserved with a timestamped backup before rewrite.
USAGE
}

log() {
  local level="$1"
  shift
  local color="$BLUE"
  case "$level" in
    INFO) color="$BLUE" ;;
    WARN) color="$YELLOW" ;;
    ERROR) color="$RED" ;;
    SUCCESS) color="$GREEN" ;;
  esac
  printf "%b[%s] %s%b\n" "$color" "$level" "$*" "$RESET"
}

num_or_zero() {
  local v="$1"
  if [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf "%s" "$v"
  else
    printf "0"
  fi
}

calc() {
  awk "BEGIN {printf \"%.2f\", ($*)}"
}

cap100() {
  local value="$1"
  local cap="$2"
  awk -v v="$value" -v c="$cap" 'BEGIN {s=(c>0? (v/c)*100 : 0); if (s<0) s=0; if (s>100) s=100; printf "%.2f", s}'
}

bytes_to_gb() {
  local bytes="$1"
  awk -v b="$bytes" 'BEGIN {printf "%.2f", b/1073741824}'
}

json_escape() {
  printf "%s" "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

trim() {
  printf "%s" "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

timestamp_id() {
  date +%Y%m%d-%H%M%S-%N
}

backup_existing_file() {
  local target="$1"
  local backup

  if [[ ! -e "$target" ]]; then
    return 0
  fi

  backup="${target}.backup.$(timestamp_id)"
  mv "$target" "$backup"
  log WARN "Preserved existing file by backup: ${target} -> ${backup}"
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --set-baseline)
        SET_BASELINE=true
        ;;
      --baseline-file)
        [[ $# -ge 2 ]] || { echo "Missing value for --baseline-file"; exit 1; }
        BASELINE_FILE="$2"
        shift
        ;;
      --baseline-score)
        [[ $# -ge 2 ]] || { echo "Missing value for --baseline-score"; exit 1; }
        BASELINE_SCORE="$2"
        shift
        ;;
      --baseline-adjust-pct)
        [[ $# -ge 2 ]] || { echo "Missing value for --baseline-adjust-pct"; exit 1; }
        BASELINE_ADJUST_PCT="$2"
        shift
        ;;
      --no-install-deps)
        INSTALL_DEPS=false
        ;;
      --quick)
        FIO_SIZE="256M"
        FIO_RUNTIME=6
        ;;
      --label)
        [[ $# -ge 2 ]] || { echo "Missing value for --label"; exit 1; }
        LABEL="$2"
        shift
        ;;
      --download-url)
        [[ $# -ge 2 ]] || { echo "Missing value for --download-url"; exit 1; }
        DOWNLOAD_URL="$2"
        shift
        ;;
      --ping-target)
        [[ $# -ge 2 ]] || { echo "Missing value for --ping-target"; exit 1; }
        PING_TARGET="$2"
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

  if ! [[ "$BASELINE_ADJUST_PCT" =~ ^[0-9]+$ ]] || ((BASELINE_ADJUST_PCT >= 100)); then
    echo "Invalid --baseline-adjust-pct '${BASELINE_ADJUST_PCT}'. Use an integer from 0 to 99."
    exit 1
  fi
}

install_dependencies() {
  if ! $INSTALL_DEPS; then
    return 0
  fi

  if [[ "$EUID" -ne 0 ]]; then
    log ERROR "Dependency install needs root. Run with sudo or use --no-install-deps."
    exit 1
  fi

  log INFO "Installing benchmark dependencies (fio, curl, jq, bc, ping tools)..."
  env DEBIAN_FRONTEND=noninteractive apt-get update -y >/tmp/perf-apt-update.log 2>&1
  env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    fio curl jq bc iputils-ping ca-certificates >/tmp/perf-apt-install.log 2>&1
}

require_cmds() {
  local missing=0
  local c
  for c in fio curl jq bc ping awk sed grep df free lscpu nproc; do
    if ! command -v "$c" >/dev/null 2>&1; then
      log ERROR "Missing command: $c"
      missing=1
    fi
  done
  if ((missing)); then
    exit 1
  fi
}

measure_disk() {
  mkdir -p "$WORK_DIR"
  local fio_file="$WORK_DIR/fio.test"
  local out_write="$WORK_DIR/fio_seq_write.json"
  local out_read="$WORK_DIR/fio_seq_read.json"
  local out_rand="$WORK_DIR/fio_rand_read.json"

  log INFO "Disk test: sequential write"
  fio --name=seqwrite --filename="$fio_file" --size="$FIO_SIZE" --rw=write --bs=1M \
    --ioengine=libaio --direct=1 --iodepth=16 --numjobs=1 --group_reporting \
    --output-format=json >"$out_write"

  log INFO "Disk test: sequential read"
  fio --name=seqread --filename="$fio_file" --size="$FIO_SIZE" --rw=read --bs=1M \
    --ioengine=libaio --direct=1 --iodepth=16 --numjobs=1 --group_reporting \
    --output-format=json >"$out_read"

  log INFO "Disk test: random read IOPS"
  fio --name=randread --filename="$fio_file" --size="$FIO_SIZE" --rw=randread --bs=4k \
    --ioengine=libaio --direct=1 --iodepth=64 --numjobs=1 --time_based --runtime="$FIO_RUNTIME" \
    --group_reporting --output-format=json >"$out_rand"

  local write_bw read_bw rand_iops
  write_bw=$(jq -r '.jobs[0].write.bw_bytes // 0' "$out_write")
  read_bw=$(jq -r '.jobs[0].read.bw_bytes // 0' "$out_read")
  rand_iops=$(jq -r '.jobs[0].read.iops // 0' "$out_rand")

  SEQ_WRITE_MBPS=$(calc "$(num_or_zero "$write_bw") / 1048576")
  SEQ_READ_MBPS=$(calc "$(num_or_zero "$read_bw") / 1048576")
  RAND_READ_IOPS=$(num_or_zero "$rand_iops")

  rm -f "$fio_file"
}

measure_network() {
  log INFO "Network test: download speed"
  local speed_bps
  speed_bps=$(curl -L --silent --show-error --output /dev/null --max-time 90 \
    --write-out '%{speed_download}' "$DOWNLOAD_URL" 2>/dev/null || echo 0)
  speed_bps=$(num_or_zero "$speed_bps")

  if awk -v s="$speed_bps" 'BEGIN {exit !(s <= 0)}'; then
    speed_bps=$(curl -L --silent --show-error --output /dev/null --max-time 90 \
      --write-out '%{speed_download}' "https://proof.ovh.net/files/100Mb.dat" 2>/dev/null || echo 0)
    speed_bps=$(num_or_zero "$speed_bps")
  fi

  if awk -v s="$speed_bps" 'BEGIN {exit !(s <= 0)}'; then
    speed_bps=$(curl -k -L --silent --show-error --output /dev/null --max-time 90 \
      --write-out '%{speed_download}' "$DOWNLOAD_URL" 2>/dev/null || echo 0)
  fi

  speed_bps=$(num_or_zero "$speed_bps")
  DOWNLOAD_MBPS=$(calc "($speed_bps * 8) / 1000000")

  log INFO "Network test: ping latency/jitter"
  local ping_out
  ping_out=$(ping -c 10 -i 0.2 "$PING_TARGET" 2>/dev/null || true)
  if [[ -z "$ping_out" ]]; then
    ping_out=$(ping -c 10 -i 0.2 8.8.8.8 2>/dev/null || true)
  fi

  local rtt
  rtt=$(printf "%s\n" "$ping_out" | awk -F'=' '/rtt|round-trip/ {gsub(/ /, "", $2); print $2}' | sed -E 's/[^0-9./]//g')

  if [[ "$rtt" == */*/*/* ]]; then
    PING_AVG_MS=$(printf "%s" "$rtt" | cut -d'/' -f2)
    PING_JITTER_MS=$(printf "%s" "$rtt" | cut -d'/' -f4)
  else
    PING_AVG_MS=999
    PING_JITTER_MS=999
  fi

  PING_AVG_MS=$(num_or_zero "$PING_AVG_MS")
  PING_JITTER_MS=$(num_or_zero "$PING_JITTER_MS")
}

measure_system_snapshot() {
  local cpu_model
  local cpu_cores
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
  CPU_MODEL=$(trim "${cpu_model:-Unknown}")

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
  CPU_CORES=$(num_or_zero "$cpu_cores")
  CPU_THREADS=$(num_or_zero "$(nproc --all 2>/dev/null || echo 0)")

  cur_mhz=$(awk -F: '/^cpu MHz/ {sum+=$2; n++} END {if (n>0) printf "%.2f", sum/n; else print "0"}' /proc/cpuinfo 2>/dev/null || echo 0)
  max_mhz=$(lscpu | awk -F: '/^CPU max MHz:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')
  if [[ -z "$max_mhz" ]]; then
    max_mhz=$(awk -F: '/^cpu MHz/ {if ($2>max) max=$2} END {if (max>0) printf "%.2f", max; else print "0"}' /proc/cpuinfo 2>/dev/null || echo 0)
  fi
  cur_mhz=$(num_or_zero "$(trim "$cur_mhz")")
  max_mhz=$(num_or_zero "$(trim "$max_mhz")")

  ghz_hint=$(lscpu | awk -F'@' '
    /@[[:space:]]*[0-9.]+GHz/ {
      if (match($2, /([0-9.]+)[[:space:]]*GHz/, m)) {
        print m[1]
        exit
      }
    }')
  ghz_hint=$(num_or_zero "$(trim "${ghz_hint:-0}")")

  CPU_CUR_GHZ=$(calc "$cur_mhz / 1000")
  CPU_MAX_GHZ=$(calc "$max_mhz / 1000")
  if awk -v v="$CPU_CUR_GHZ" 'BEGIN {exit !(v <= 0)}'; then
    CPU_CUR_GHZ=$(calc "$ghz_hint")
  fi
  if awk -v v="$CPU_MAX_GHZ" 'BEGIN {exit !(v <= 0)}'; then
    CPU_MAX_GHZ=$(calc "$ghz_hint")
  fi

  mem_total_b=$(free -b | awk '/^Mem:/ {print $2}')
  mem_used_b=$(free -b | awk '/^Mem:/ {print $3}')
  mem_free_b=$(free -b | awk '/^Mem:/ {print $4}')
  mem_total_b=$(num_or_zero "$mem_total_b")
  mem_used_b=$(num_or_zero "$mem_used_b")
  mem_free_b=$(num_or_zero "$mem_free_b")

  RAM_TOTAL_GB=$(bytes_to_gb "$mem_total_b")
  RAM_USED_GB=$(bytes_to_gb "$mem_used_b")
  RAM_FREE_GB=$(bytes_to_gb "$mem_free_b")

  disk_total_b=$(df -B1 / | awk 'NR==2 {print $2}')
  disk_used_b=$(df -B1 / | awk 'NR==2 {print $3}')
  disk_free_b=$(df -B1 / | awk 'NR==2 {print $4}')
  disk_total_b=$(num_or_zero "$disk_total_b")
  disk_used_b=$(num_or_zero "$disk_used_b")
  disk_free_b=$(num_or_zero "$disk_free_b")

  STORAGE_TOTAL_GB=$(bytes_to_gb "$disk_total_b")
  STORAGE_USED_GB=$(bytes_to_gb "$disk_used_b")
  STORAGE_FREE_GB=$(bytes_to_gb "$disk_free_b")
}

score_results() {
  # Caps tuned for VPS class machines.
  DISK_WRITE_SCORE=$(cap100 "$SEQ_WRITE_MBPS" 300)
  DISK_READ_SCORE=$(cap100 "$SEQ_READ_MBPS" 600)
  RAND_IOPS_SCORE=$(cap100 "$RAND_READ_IOPS" 50000)
  DOWNLOAD_SCORE=$(cap100 "$DOWNLOAD_MBPS" 1000)

  PING_SCORE=$(awk -v p="$PING_AVG_MS" 'BEGIN {s=100-(p*2); if (s<0) s=0; if (s>100) s=100; printf "%.2f", s}')
  JITTER_SCORE=$(awk -v j="$PING_JITTER_MS" 'BEGIN {s=100-(j*5); if (s<0) s=0; if (s>100) s=100; printf "%.2f", s}')

  COMPOSITE_SCORE=$(awk \
    -v w="$DISK_WRITE_SCORE" \
    -v r="$DISK_READ_SCORE" \
    -v i="$RAND_IOPS_SCORE" \
    -v d="$DOWNLOAD_SCORE" \
    -v p="$PING_SCORE" \
    -v j="$JITTER_SCORE" \
    'BEGIN {printf "%.2f", (w*0.18) + (r*0.12) + (i*0.15) + (d*0.35) + (p*0.12) + (j*0.08)}')
}

load_baseline_score() {
  if [[ -n "$BASELINE_SCORE" ]]; then
    BASELINE_SCORE=$(num_or_zero "$BASELINE_SCORE")
    return 0
  fi

  if [[ -f "$BASELINE_FILE" ]]; then
    BASELINE_SCORE=$(jq -r '.composite_score // 0' "$BASELINE_FILE")
    BASELINE_SCORE=$(num_or_zero "$BASELINE_SCORE")
    return 0
  fi

  BASELINE_SCORE=""
}

classify() {
  load_baseline_score

  if [[ -z "$BASELINE_SCORE" || "$BASELINE_SCORE" == "0" ]]; then
    CATEGORY="As Good"
    EFFECTIVE_BASELINE_SCORE=""
    RAW_IMPROVEMENT_PCT=0
    EFFECTIVE_IMPROVEMENT_PCT=0
    return
  fi

  RAW_IMPROVEMENT_PCT=$(awk -v c="$COMPOSITE_SCORE" -v b="$BASELINE_SCORE" 'BEGIN {printf "%.2f", ((c-b)/b)*100}')
  EFFECTIVE_BASELINE_SCORE=$(awk -v b="$BASELINE_SCORE" -v p="$BASELINE_ADJUST_PCT" \
    'BEGIN {printf "%.2f", b * (1 - (p / 100))}')

  if awk -v b="$EFFECTIVE_BASELINE_SCORE" 'BEGIN {exit !(b <= 0)}'; then
    EFFECTIVE_BASELINE_SCORE="$BASELINE_SCORE"
  fi

  EFFECTIVE_IMPROVEMENT_PCT=$(awk -v c="$COMPOSITE_SCORE" -v b="$EFFECTIVE_BASELINE_SCORE" \
    'BEGIN {printf "%.2f", ((c-b)/b)*100}')

  if awk -v v="$EFFECTIVE_IMPROVEMENT_PCT" 'BEGIN {exit !(v > 100)}'; then
    CATEGORY="Pro Level"
  elif awk -v v="$EFFECTIVE_IMPROVEMENT_PCT" 'BEGIN {exit !(v >= 95)}'; then
    CATEGORY="Excellent"
  elif awk -v v="$EFFECTIVE_IMPROVEMENT_PCT" 'BEGIN {exit !(v >= 50)}'; then
    CATEGORY="Very Good"
  else
    CATEGORY="As Good"
  fi
}

save_baseline() {
  local cpu_model_json
  cpu_model_json=$(json_escape "$CPU_MODEL")

  mkdir -p "$(dirname "$BASELINE_FILE")"
  backup_existing_file "$BASELINE_FILE"
  cat >"$BASELINE_FILE" <<JSON
{
  "label": "${LABEL}",
  "hostname": "$(hostname)",
  "timestamp": "$(date -Iseconds)",
  "baseline_adjust_pct_default": ${BASELINE_ADJUST_PCT},
  "composite_score": ${COMPOSITE_SCORE},
  "hardware": {
    "cpu": {
      "model": "${cpu_model_json}",
      "cores": ${CPU_CORES},
      "threads": ${CPU_THREADS},
      "current_ghz": ${CPU_CUR_GHZ},
      "max_ghz": ${CPU_MAX_GHZ}
    },
    "ram_gb": {
      "total": ${RAM_TOTAL_GB},
      "used": ${RAM_USED_GB},
      "free": ${RAM_FREE_GB}
    },
    "storage_root_gb": {
      "total": ${STORAGE_TOTAL_GB},
      "used": ${STORAGE_USED_GB},
      "free": ${STORAGE_FREE_GB}
    }
  },
  "metrics": {
    "seq_write_mbps": ${SEQ_WRITE_MBPS},
    "seq_read_mbps": ${SEQ_READ_MBPS},
    "rand_read_iops": ${RAND_READ_IOPS},
    "download_mbps": ${DOWNLOAD_MBPS},
    "ping_avg_ms": ${PING_AVG_MS},
    "ping_jitter_ms": ${PING_JITTER_MS}
  }
}
JSON
  log SUCCESS "Baseline saved: ${BASELINE_FILE}"
}

print_report() {
  printf "\n%bServer Performance Report (v%s)%b\n" "$BOLD" "$SCRIPT_VERSION" "$RESET"
  printf "%bLabel:%b %s\n" "$BOLD" "$RESET" "$LABEL"
  printf "%bHost:%b %s\n" "$BOLD" "$RESET" "$(hostname)"
  printf "%bDate:%b %s\n\n" "$BOLD" "$RESET" "$(date '+%Y-%m-%d %H:%M:%S')"

  printf "%-26s %12s\n" "System Snapshot" ""
  printf "%-26s %12s\n" "--------------------------" "------------"
  printf "%-26s %12s\n" "CPU model" "$CPU_MODEL"
  printf "%-26s %12s\n" "CPU cores / threads" "${CPU_CORES}/${CPU_THREADS}"
  printf "%-26s %12s\n" "CPU GHz (cur/max)" "${CPU_CUR_GHZ}/${CPU_MAX_GHZ}"
  printf "%-26s %12s\n" "RAM GB (total/used/free)" "${RAM_TOTAL_GB}/${RAM_USED_GB}/${RAM_FREE_GB}"
  printf "%-26s %12s\n" "Disk GB / (tot/used/free)" "${STORAGE_TOTAL_GB}/${STORAGE_USED_GB}/${STORAGE_FREE_GB}"
  printf "\n"

  printf "%-26s %12s\n" "Metric" "Value"
  printf "%-26s %12s\n" "--------------------------" "------------"
  printf "%-26s %12s\n" "Seq write (MB/s)" "$SEQ_WRITE_MBPS"
  printf "%-26s %12s\n" "Seq read (MB/s)" "$SEQ_READ_MBPS"
  printf "%-26s %12s\n" "Random read (IOPS)" "$RAND_READ_IOPS"
  printf "%-26s %12s\n" "Download (Mb/s)" "$DOWNLOAD_MBPS"
  printf "%-26s %12s\n" "Ping avg (ms)" "$PING_AVG_MS"
  printf "%-26s %12s\n" "Ping jitter (ms)" "$PING_JITTER_MS"
  printf "\n%-26s %12s\n" "Composite score" "$COMPOSITE_SCORE"

  if [[ -n "$BASELINE_SCORE" ]]; then
    printf "%-26s %12s\n" "Baseline score (raw)" "$BASELINE_SCORE"
    printf "%-26s %12s\n" "Baseline score (effective)" "$EFFECTIVE_BASELINE_SCORE"
    printf "%-26s %12s\n" "Better than base (raw %)" "${RAW_IMPROVEMENT_PCT}%"
    printf "%-26s %12s\n" "Better than base (effective %)" "${EFFECTIVE_IMPROVEMENT_PCT}%"
    printf "%-26s %12s\n" "Baseline adjust pct" "${BASELINE_ADJUST_PCT}%"
  else
    printf "%-26s %12s\n" "Baseline score (raw)" "(not set)"
    printf "%-26s %12s\n" "Baseline score (effective)" "(not set)"
    printf "%-26s %12s\n" "Better than base (raw %)" "(not set)"
    printf "%-26s %12s\n" "Better than base (effective %)" "(not set)"
    printf "%-26s %12s\n" "Baseline adjust pct" "${BASELINE_ADJUST_PCT}%"
  fi

  printf "%-26s %12s\n\n" "Category" "$CATEGORY"

  cat <<NOTE
Category meaning:
- As Good: effective baseline level or less than 50% better
- Very Good: 50% to <95% better
- Excellent: ~100% better
- Pro Level: >100% better
NOTE
}

main() {
  parse_args "$@"
  install_dependencies
  require_cmds

  measure_disk
  measure_network
  measure_system_snapshot
  score_results

  if $SET_BASELINE; then
    BASELINE_SCORE="$COMPOSITE_SCORE"
    EFFECTIVE_BASELINE_SCORE=$(awk -v b="$BASELINE_SCORE" -v p="$BASELINE_ADJUST_PCT" \
      'BEGIN {printf "%.2f", b * (1 - (p / 100))}')
    RAW_IMPROVEMENT_PCT=0
    EFFECTIVE_IMPROVEMENT_PCT=0
    CATEGORY="As Good"
    save_baseline
  else
    classify
  fi

  print_report
}

main "$@"
