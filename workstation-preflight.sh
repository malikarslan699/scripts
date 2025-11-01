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
Usage: sudo ./workstation-preflight.sh [--yes] [--quick]
Runs pre-setup benchmarks (network via Ookla/HTTP, CPU/memory/disk). Use --quick for fast, low‑volume tests.
H
exit 0;; *) warn "Unknown option: $a";; esac; done; }

wait_for_apt(){ local retries=30 delay=2; for i in $(seq 1 $retries); do if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then sleep $delay; else return 0; fi; done; return 1; }
apt_update(){ wait_for_apt; apt-get update -y; }
install_pkgs(){ wait_for_apt; DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; }

ensure_tools(){
  info "Installing required tools (jq, sysbench, iperf3, Ookla speedtest)"
  apt_update || true
  install_pkgs ca-certificates curl jq sysbench iperf3 || true
  # Install Ookla speedtest (official)
  if ! command -v speedtest >/dev/null 2>&1; then
    curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash || warn "Ookla repo script failed"
    apt_update || true
    install_pkgs speedtest || warn "Ookla speedtest install failed"
  fi
  command -v jq >/dev/null 2>&1 && command -v sysbench >/dev/null 2>&1 || fail "Required tools missing"
}

run_speedtest(){
  if ! command -v speedtest >/dev/null 2>&1; then
    warn "Ookla speedtest not installed; skipping network benchmark"
    return 1
  fi
  info "Running Ookla speedtest (this can take up to 1 minute)"
  # Accept license/GDPR non-interactively
  speedtest --accept-license --accept-gdpr --format=json --progress=no > /tmp/_speedtest.json || { warn "Speedtest failed"; return 1; }
}

run_http_tests(){
  info "Running HTTP download tests (multiple mirrors)"
  local urls=(
    "http://speedtest.tele2.net/100MB.zip"
    "http://ipv4.download.thinkbroadband.com/100MB.zip"
    "http://cachefly.cachefly.net/100mb.test"
    "http://proof.ovh.net/files/100Mb.dat"
    "http://speed.hetzner.de/100MB.bin"
  )
  : > /tmp/_http.txt
  for u in "${urls[@]}"; do
    local line
    line=$(curl --max-time 15 -L -o /dev/null -s -w "URL:%{url_effective} SPEED:%{speed_download} TIME:%{time_total}\n" "$u" || true)
    echo "$line" | tee -a /tmp/_http.txt >/dev/null
  done
}

run_http_tests_quick(){
  info "Running QUICK HTTP tests (10MB range)"
  local urls=(
    "http://cachefly.cachefly.net/100mb.test"
    "http://ipv4.download.thinkbroadband.com/100MB.zip"
    "http://proof.ovh.net/files/100Mb.dat"
  )
  : > /tmp/_http.txt
  for u in "${urls[@]}"; do
    local line
    line=$(curl --max-time 8 -L -r 0-10485759 -o /dev/null -s -w "URL:%{url_effective} SPEED:%{speed_download} TIME:%{time_total}\n" "$u" || true)
    echo "$line" | tee -a /tmp/_http.txt >/dev/null
  done
}

run_iperf_tests(){
  info "Running iperf3 tests (best-effort)"
  : > /tmp/_iperf.txt
  if command -v iperf3 >/dev/null 2>&1; then
    { echo "== download =="; iperf3 -4 -c iperf3.iperf.fr -p 5201 -P 4 -t 5 2>&1 || true; echo; echo "== upload =="; iperf3 -4 -R -c bouygues.iperf.fr -p 5201 -P 4 -t 5 2>&1 || true; } | tee /tmp/_iperf.txt >/dev/null
  fi
}

run_disk_test(){
  local count_mb
  count_mb=${DISK_COUNT_MB:-1024}
  info "Running disk write test (${count_mb} MiB)"
  : > /tmp/_disk.txt
  sync; dd if=/dev/zero of=/tmp/io.test bs=1M count=${count_mb} oflag=direct status=none 2> /tmp/_disk.txt || true
  sync; rm -f /tmp/io.test || true
}

run_cpu_bench(){
  local threads time_s
  threads=$(nproc || echo 1)
  time_s=${CPU_TIME_SECONDS:-10}
  info "CPU benchmark (sysbench cpu, threads=$threads, ${time_s}s)"
  sysbench cpu --cpu-max-prime=20000 --threads="$threads" --time="$time_s" run > /tmp/_cpu.txt || true
}

run_mem_bench(){
  local threads total
  threads=$(nproc || echo 1)
  total=${MEM_TOTAL_SIZE:-2G}
  info "Memory benchmark (sysbench memory, ${total} total, threads=$threads)"
  sysbench memory --memory-total-size="$total" --memory-block-size=1M --threads="$threads" run > /tmp/_mem.txt || true
}

human_mbps(){ awk '{printf "%.1f", ($1*8)/1000000 }'; }

print_summary(){
  echo
  echo "===================== PREFLIGHT SUMMARY ====================="
  echo "Host: $(hostname)"
  echo "OS: $(. /etc/os-release; echo "$PRETTY_NAME")  Kernel: $(uname -r)"
  echo "CPU: $(lscpu | awk -F: '/Model name/{gsub(/^ +/,"",$2); print $2; exit}')  vCPU: $(nproc)"
  echo "RAM: $(free -h | awk '/Mem:/ {print $2" total, " $7" available"}')"

  if [[ -s /tmp/_speedtest.json ]]; then
    local d_bw u_bw lat jit isp svr
    d_bw=$(jq -r '.download.bandwidth' /tmp/_speedtest.json 2>/dev/null || echo 0)
    u_bw=$(jq -r '.upload.bandwidth' /tmp/_speedtest.json 2>/dev/null || echo 0)
    lat=$(jq -r '.ping.latency' /tmp/_speedtest.json 2>/dev/null || echo 0)
    jit=$(jq -r '.ping.jitter' /tmp/_speedtest.json 2>/dev/null || echo 0)
    isp=$(jq -r '.isp' /tmp/_speedtest.json 2>/dev/null || echo "?")
    svr=$(jq -r '.server.name + ", " + .server.location' /tmp/_speedtest.json 2>/dev/null || echo "?")
    echo "Network (Ookla): Download ~ $(echo "$d_bw" | human_mbps) Mbps, Upload ~ $(echo "$u_bw" | human_mbps) Mbps, Latency ${lat} ms, Jitter ${jit} ms"
    echo "  ISP: ${isp}  Server: ${svr}"
  else
    echo "Network (Ookla): not available"
  fi

  if [[ -s /tmp/_cpu.txt ]]; then
    local eps
    eps=$(awk -F: '/events per second/ {gsub(/^[ \t]+/ , "", $2); print $2}' /tmp/_cpu.txt | tail -n1)
    [[ -n "$eps" ]] && echo "CPU perf: ${eps} events/sec (sysbench 10s, all cores)" || echo "CPU perf: n/a"
  fi

  if [[ -s /tmp/_mem.txt ]]; then
    local mem_rate
    mem_rate=$(awk '{if ($0 ~ /MiB transferred/){ if (match($0, /\(([0-9.]+) MiB\/sec\)/, m)) print m[1]; }}' /tmp/_mem.txt | tail -n1)
    [[ -n "${mem_rate:-}" ]] && echo "Memory throughput: ${mem_rate} MiB/sec (sysbench 2G)" || echo "Memory throughput: n/a"
  fi

  if [[ -s /tmp/_disk.txt ]]; then
    local disk_rate
    disk_rate=$(awk -F, '/copied/ {gsub(/^ +/ ,"", $3); print $3}' /tmp/_disk.txt | awk '{print $1" "$2}' | tail -n1)
    [[ -n "${disk_rate:-}" ]] && echo "Disk write: ${disk_rate} (dd oflag=direct)" || echo "Disk write: n/a"
  fi

  if [[ -s /tmp/_http.txt ]]; then
    echo "HTTP mirrors:"
    awk '{print "  "$0}' /tmp/_http.txt | sed 's/SPEED:/ speed=/; s/TIME:/ time=/; s/URL:/url=/'
  fi

  # Simple multitasking rating
  local vcpu eps_num mem_mib rating
  vcpu=$(nproc || echo 1)
  eps_num=$(awk -F: '/events per second/ {gsub(/^[ \t]+/ , "", $2); print $2}' /tmp/_cpu.txt | tail -n1 | awk '{print int($1+0)}')
  mem_mib=$(awk '{if ($0 ~ /MiB transferred/){ if (match($0, /\(([0-9.]+) MiB\/sec\)/, m)) print m[1]; }}' /tmp/_mem.txt | tail -n1 | awk -F. '{print $1}')
  rating="Good"
  if [[ -n "$eps_num" && -n "$mem_mib" ]]; then
    if (( vcpu >= 8 && eps_num >= 2000 && mem_mib >= 8000 )); then rating="Excellent";
    elif (( vcpu >= 4 && eps_num >= 800 && mem_mib >= 3000 )); then rating="Good";
    else rating="Basic"; fi
  fi
  echo "Multitasking (est.): ${rating}"

  # Simple overall suitability
  local net_ok="no"
  if [[ -s /tmp/_speedtest.json ]]; then
    local d_bw; d_bw=$(jq -r '.download.bandwidth' /tmp/_speedtest.json 2>/dev/null || echo 0)
    (( d_bw > 50000000 )) && net_ok="yes"  # ~400 Mbps
  elif [[ -s /tmp/_http.txt ]]; then
    # consider ok if any mirror > 10 MB/s
    awk '{for(i=1;i<=NF;i++){if($i ~ /^SPEED:/){split($i,a,":"); if (a[2]>10000000) exit 0}}} END{exit 1}' /tmp/_http.txt && net_ok="yes" || net_ok="no"
  fi
  echo "Network suitability: ${net_ok}"
  echo "============================================================="
}

main(){
  parse_args "$@"
  # First confirmation
  ask "Run preflight benchmarks (network + CPU + memory)?" || { warn "Aborted"; exit 0; }
  # Second confirmation about installing small tools
  ask "This will install small CLI tools (speedtest, sysbench, jq). Proceed?" || { warn "Aborted"; exit 0; }

  info "Preparing tools..."
  ensure_tools

  if $QUICK; then
    CPU_TIME_SECONDS=3 MEM_TOTAL_SIZE=256M DISK_COUNT_MB=256
    run_http_tests_quick || true
    run_cpu_bench || true
    run_mem_bench || true
    run_disk_test || true
  else
    run_speedtest || true
    run_http_tests || true
    run_iperf_tests || true
    run_cpu_bench || true
    run_mem_bench || true
    run_disk_test || true
  fi

  print_summary
}

main "$@"


