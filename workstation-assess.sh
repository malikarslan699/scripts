#!/usr/bin/env bash

set -Eeuo pipefail
trap 'echo "[ERROR] Command failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

AUTO_YES=false
QUICK=false

GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; BLUE="\033[1;34m"; RESET="\033[0m"
ok(){ echo -e "${GREEN}[OK]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
info(){ echo -e "${BLUE}[INFO]${RESET} $*"; }
fail(){ echo -e "${RED}[FAIL]${RESET} $*"; }

ask(){
  local m=${1:-Proceed?}
  if $AUTO_YES || [[ -n "${ASSUME_YES:-}" ]] || [[ -n "${YES:-}" ]] || [[ ! -t 0 ]]; then
    info "$m [auto-yes]"
    return 0
  fi
  read -r -p "$m [Y/n]: " r || true; r=${r:-Y}; [[ $r =~ ^[Yy]$ ]]
}

parse_args(){ for a in "$@"; do case "$a" in -y|--yes) AUTO_YES=true;; --quick) QUICK=true;; -h|--help) cat <<H
Usage: sudo ./workstation-assess.sh [--yes] [--quick]
Performs pre-setup assessment (trusted HTTP mirrors, CPU/memory/disk), prints smart, unit-aware summary.
H
exit 0;; *) warn "Unknown option: $a";; esac; done; }

wait_for_apt(){ local retries=30 delay=2; for i in $(seq 1 $retries); do if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then sleep $delay; else return 0; fi; done; return 1; }
apt_update(){ wait_for_apt; apt-get update -y; }
install_pkgs(){ wait_for_apt; DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; }

ensure_tools(){
  info "Installing required tools (curl, jq, sysbench)"
  apt_update || true
  install_pkgs ca-certificates curl jq sysbench >/dev/null 2>&1 || true
}

# Helpers
fmt_mb_gb(){ # input: MB (integer/float) -> prints MB if <1024 else GB with 1 decimal
  local mb; mb=$(printf '%.2f' "$1" 2>/dev/null || echo 0)
  awk -v mb="$mb" 'BEGIN{ if (mb<1024) printf("%.0f MB", mb); else printf("%.1f GB", mb/1024.0) }'
}
fmt_bytes_speed(){ # input: bytes/sec -> prints "X.Y MB/s (Z.Y Gbps)"
  local bps; bps=${1:-0}
  awk -v bps="$bps" 'BEGIN{ mbps=bps/1000000.0; gbps=(bps*8)/1e9; printf("%.1f MB/s (%.2f Gbps)", mbps, gbps) }'
}

# System info
get_cpu_model(){ lscpu | awk -F: '/Model name/{gsub(/^ +/,"",$2); print $2; exit}'; }
get_mem_mb(){ free -m | awk '/Mem:/{print $2" "$7}'; }
get_disk_root_bytes(){ df -B1 / | awk 'NR==2{print $2" "$4}'; }

# HTTP mirror tests (range requests for speed, short timeouts)
run_http_tests(){
  local quick=$1
  info "Running HTTP download tests (trusted mirrors)"
  local urls=(
    "http://cachefly.cachefly.net/100mb.test"
    "http://ipv4.download.thinkbroadband.com/100MB.zip"
    "http://proof.ovh.net/files/100Mb.dat"
    "http://speedtest.tele2.net/100MB.zip"
    "http://speed.hetzner.de/100MB.bin"
  )
  : > /tmp/_http.txt
  local max_time range_arg
  if $quick; then max_time=8; range_arg='-r 0-10485759'; else max_time=15; range_arg='-r 0-20971519'; fi
  for u in "${urls[@]}"; do
    local line; line=$(curl --max-time "$max_time" -L $range_arg -o /dev/null -s -w "URL:%{url_effective} SPEED:%{speed_download} TIME:%{time_total}\n" "$u" || true)
    echo "$line" >> /tmp/_http.txt
  done
}

run_cpu_bench(){ local t=${1:-10}; info "CPU benchmark (sysbench ${t}s, all cores)"; sysbench cpu --cpu-max-prime=20000 --threads=$(nproc) --time="$t" run > /tmp/_cpu.txt || true; }
run_mem_bench(){ local total=${1:-2G}; info "Memory benchmark (sysbench ${total})"; sysbench memory --memory-total-size="$total" --memory-block-size=1M --threads=$(nproc) run > /tmp/_mem.txt || true; }
run_disk_test(){ local mib=${1:-1024}; info "Disk write test (${mib} MiB, direct I/O)"; : > /tmp/_disk.txt; sync; dd if=/dev/zero of=/tmp/io.test bs=1M count="$mib" oflag=direct status=none 2> /tmp/_disk.txt || true; sync; rm -f /tmp/io.test || true; }

print_summary(){
  echo; echo "===================== ASSESSMENT SUMMARY ====================="
  echo "Host: $(hostname)"
  echo "OS: $(. /etc/os-release; echo "$PRETTY_NAME")  Kernel: $(uname -r)"
  echo "CPU: $(get_cpu_model)  vCPU: $(nproc)"

  # Memory
  read -r mem_total_mb mem_avail_mb < <(get_mem_mb)
  echo "RAM: $(fmt_mb_gb "$mem_total_mb") total, $(fmt_mb_gb "$mem_avail_mb") available"

  # Disk (/)
  read -r disk_total_b disk_free_b < <(get_disk_root_bytes)
  disk_total_mb=$(awk -v b=$disk_total_b 'BEGIN{print b/1048576}')
  disk_free_mb=$(awk -v b=$disk_free_b 'BEGIN{print b/1048576}')
  echo "Disk (/): $(fmt_mb_gb "$disk_total_mb") total, $(fmt_mb_gb "$disk_free_mb") free"

  # CPU perf
  if [[ -s /tmp/_cpu.txt ]]; then
    cpu_eps=$(awk -F: '/events per second/ {gsub(/^[ \t]+/,"",$2); print $2}' /tmp/_cpu.txt | tail -n1)
    [[ -n "${cpu_eps:-}" ]] && echo "CPU perf: ${cpu_eps} events/sec (sysbench)" || echo "CPU perf: n/a"
  fi

  # Memory throughput
  if [[ -s /tmp/_mem.txt ]]; then
    mem_rate=$(awk '{if ($0 ~ /MiB transferred/){ if (match($0, /\(([0-9.]+) MiB\/sec\)/, m)) print m[1]; }}' /tmp/_mem.txt | tail -n1)
    [[ -n "${mem_rate:-}" ]] && echo "Memory throughput: ${mem_rate} MiB/sec (sysbench)" || echo "Memory throughput: n/a"
  fi

  # Disk throughput
  if [[ -s /tmp/_disk.txt ]]; then
    disk_rate=$(awk -F, '/copied/ {gsub(/^ +/,"", $3); print $3}' /tmp/_disk.txt | awk '{print $1" "$2}' | tail -n1)
    [[ -n "${disk_rate:-}" ]] && echo "Disk write: ${disk_rate} (dd oflag=direct)" || echo "Disk write: n/a"
  fi

  # HTTP mirrors
  net_mb_s_median=""; net_mb_s_best=""; net_list=""
  if [[ -s /tmp/_http.txt ]]; then
    echo "HTTP mirrors:"
    # Build per-URL MB/s list
    mapfile -t lines < /tmp/_http.txt
    mb_list=()
    for ln in "${lines[@]}"; do
      url=$(echo "$ln" | sed -n 's/.*URL:\([^ ]*\).*/\1/p')
      sp=$(echo "$ln" | sed -n 's/.*SPEED:\([^ ]*\).*/\1/p')
      tm=$(echo "$ln" | sed -n 's/.*TIME:\([^ ]*\).*/\1/p')
      mbps=$(awk -v bps="$sp" 'BEGIN{print bps/1000000.0}')
      echo "  url=${url}  speed=$(printf '%.2f' "$mbps") MB/s  time=${tm}s"
      mb_list+=("$mbps")
    done
    # compute median and best
    if ((${#mb_list[@]}>0)); then
      sorted=$(printf '%s\n' "${mb_list[@]}" | sort -n)
      count=${#mb_list[@]}
      mid=$(( (count+1)/2 ))
      net_mb_s_median=$(printf '%s\n' $sorted | awk -v m=$mid 'NR==m{print $1}')
      net_mb_s_best=$(printf '%s\n' $sorted | tail -n1)
    fi
  fi

  # Multitasking rating
  rating="Basic"
  vcpu=$(nproc || echo 1)
  eps_num=$(printf '%.0f' "${cpu_eps:-0}" 2>/dev/null || echo 0)
  mem_num=$(printf '%.0f' "${mem_rate:-0}" 2>/dev/null || echo 0)
  if (( vcpu>=8 && eps_num>=2000 && mem_num>=6000 )); then rating="Excellent";
  elif (( vcpu>=4 && eps_num>=800 && mem_num>=3000 )); then rating="Good";
  else rating="Basic"; fi
  echo "Multitasking (est.): ${rating}"

  # Network suitability: require median >=10 MB/s and best >=20 MB/s
  net_ok="unknown"
  reason=""
  if [[ -n "${net_mb_s_median:-}" ]]; then
    awk -v med="$net_mb_s_median" -v best="$net_mb_s_best" 'BEGIN{ok=(med>=10 && best>=20); print ok?"yes":"no"}' | read -r net_ok
    if [[ "$net_ok" == "yes" ]]; then reason="median >= 10 MB/s & best >= 20 MB/s"; else reason="insufficient HTTP throughput"; fi
  fi
  echo "Network suitability: ${net_ok}${reason:+ (${reason})}"

  echo "=============================================================="
}

main(){
  parse_args "$@"
  ask "Run workstation assessment now?" || { warn "Aborted"; exit 0; }
  ask "This installs small tools (curl,jq,sysbench). Proceed?" || { warn "Aborted"; exit 0; }
  ensure_tools

  if $QUICK; then
    run_http_tests true || true
    run_cpu_bench 3 || true
    run_mem_bench 256M || true
    run_disk_test 256 || true
  else
    run_http_tests false || true
    run_cpu_bench 10 || true
    run_mem_bench 2G || true
    run_disk_test 1024 || true
  fi

  print_summary
}

main "$@"


