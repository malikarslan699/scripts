#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
DEFAULT_BASELINE_FILE="/opt/server-perf-baseline.json"
WORK_DIR="/tmp/server-perf"
PING_TARGET="1.1.1.1"
DOWNLOAD_URL="https://proof.ovh.net/files/100Mb.dat"
FIO_SIZE="512M"
FIO_RUNTIME=12

INSTALL_DEPS=true
SET_BASELINE=false
BASELINE_FILE="$DEFAULT_BASELINE_FILE"
BASELINE_SCORE=""
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
IMPROVEMENT_PCT=0
CATEGORY="Good"

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
  --no-install-deps              Skip auto-install of benchmark dependencies.
  --quick                        Faster test mode (smaller/shorter fio).
  --label <name>                 Friendly name for this server in output.
  --download-url <url>           File URL for download speed test.
  --ping-target <host>           Ping target for latency/jitter test.
  --help                         Show help.

Category logic vs baseline:
  Good: < 50% better than baseline
  Very Good: >= 50% better
  Excellent: around 100% better (95% to 100%)
  Pro Level: > 100% better
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
  for c in fio curl jq bc ping awk sed grep; do
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
    CATEGORY="Good"
    IMPROVEMENT_PCT=0
    return
  fi

  IMPROVEMENT_PCT=$(awk -v c="$COMPOSITE_SCORE" -v b="$BASELINE_SCORE" 'BEGIN {printf "%.2f", ((c-b)/b)*100}')

  if awk -v v="$IMPROVEMENT_PCT" 'BEGIN {exit !(v > 100)}'; then
    CATEGORY="Pro Level"
  elif awk -v v="$IMPROVEMENT_PCT" 'BEGIN {exit !(v >= 95)}'; then
    CATEGORY="Excellent"
  elif awk -v v="$IMPROVEMENT_PCT" 'BEGIN {exit !(v >= 50)}'; then
    CATEGORY="Very Good"
  else
    CATEGORY="Good"
  fi
}

save_baseline() {
  mkdir -p "$(dirname "$BASELINE_FILE")"
  cat >"$BASELINE_FILE" <<JSON
{
  "label": "${LABEL}",
  "hostname": "$(hostname)",
  "timestamp": "$(date -Iseconds)",
  "composite_score": ${COMPOSITE_SCORE},
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
    printf "%-26s %12s\n" "Baseline score" "$BASELINE_SCORE"
    printf "%-26s %12s\n" "Improvement" "${IMPROVEMENT_PCT}%"
  else
    printf "%-26s %12s\n" "Baseline score" "(not set)"
  fi

  printf "%-26s %12s\n\n" "Category" "$CATEGORY"

  cat <<NOTE
Category meaning:
- Good: baseline level or less than 50% better
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
  score_results

  if $SET_BASELINE; then
    BASELINE_SCORE="$COMPOSITE_SCORE"
    IMPROVEMENT_PCT=0
    CATEGORY="Good"
    save_baseline
  else
    classify
  fi

  print_report
}

main "$@"
