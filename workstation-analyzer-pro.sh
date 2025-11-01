#!/usr/bin/env bash
# ===============================================================
#  Workstation Analyzer Pro (Deep Seek Edition)
#  Author: Malik Saqib
#  Purpose: Full VPS hardware analysis with Power Score (0–100)
# ===============================================================

set -euo pipefail
IFS=$'\n\t'

echo "=================== WORKSTATION ANALYZER PRO ==================="
echo "[*] Performing deep hardware & performance analysis..."
echo ""

# ----------------- Dependencies -----------------
if ! command -v sysbench &>/dev/null || ! command -v bc &>/dev/null || ! command -v curl &>/dev/null; then
  echo "[*] Installing required tools..."
  apt-get update -qq && apt-get install -y sysbench bc curl jq >/dev/null 2>&1
fi

# ----------------- System Info -----------------
HOST=$(hostname)
OS=$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
KERNEL=$(uname -r)
CPU_MODEL=$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | xargs)
VCPUS=$(nproc)
RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
UPTIME=$(uptime -p || echo "N/A")

# IPv4 / IPv6 Detection
IPV4=$(curl -4 -s ifconfig.me || echo "N/A")
IPV6=$(curl -6 -s ifconfig.me || echo "N/A")

# Geo Lookup (using IPv4 if available)
GEO_INFO="N/A"
if [[ "$IPV4" != "N/A" ]]; then
  GEO_INFO=$(curl -s "https://ipapi.co/${IPV4}/json/" | jq -r '.city, .country_name, .org' | paste -sd ', ' -)
fi

echo "Host: $HOST"
echo "OS: $OS | Kernel: $KERNEL"
echo "CPU: $CPU_MODEL ($VCPUS cores)"
echo "RAM: ${RAM_MB} MB | Disk: ${DISK_TOTAL}"
echo "Public IPv4: $IPV4"
echo "Public IPv6: $IPV6"
echo "Geo Info: $GEO_INFO"
echo "Uptime: $UPTIME"
echo ""

# ----------------- CPU Benchmark -----------------
echo "[*] Running CPU test (5s)..."
CPU_SCORE=$(sysbench cpu --threads="$VCPUS" --time=5 run 2>/dev/null | awk -F: '/events per second/ {print $2}' | xargs)
CPU_SCORE=${CPU_SCORE:-0}
echo "CPU Performance: $CPU_SCORE events/sec"

# ----------------- Memory Benchmark -----------------
echo "[*] Running Memory throughput test..."
MEM_SPEED=$(timeout 15 sysbench memory --memory-block-size=1M --memory-total-size=128M run 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+ (MiB|MB)/sec' | awk '{print $1}' | tail -1)
MEM_SPEED=${MEM_SPEED:-0}
echo "Memory Speed: $MEM_SPEED MiB/sec"

# ----------------- Disk Benchmark -----------------
echo "[*] Running Disk Write test (1GB, fdatasync)..."
DISK_RESULT=$(timeout 30 dd if=/dev/zero of=/tmp/testfile bs=1M count=1024 conv=fdatasync status=none 2>&1 || echo "Disk test timeout")
DISK_SPEED=$(echo "$DISK_RESULT" | grep -oE '[0-9.]+ MB/s' | tail -1 | awk '{print $1}')
DISK_SPEED=${DISK_SPEED:-0}
echo "Disk Write: $DISK_SPEED MB/s"

# Disk Read
echo "[*] Running Disk Read test..."
DISK_READ=$(timeout 20 dd if=/tmp/testfile of=/dev/null bs=1M count=512 status=none 2>&1 | grep -oE '[0-9.]+ MB/s' | tail -1 | awk '{print $1}')
rm -f /tmp/testfile >/dev/null 2>&1
DISK_READ=${DISK_READ:-0}
echo "Disk Read: $DISK_READ MB/s"

# ----------------- Network Benchmark -----------------
echo "[*] Running Network speed test (3 mirrors)..."
declare -a urls=("http://cachefly.cachefly.net/100mb.test" \
"http://ipv4.download.thinkbroadband.com/100MB.zip" \
"https://proof.ovh.net/files/100Mb.dat")

TOTAL_NET=0
for u in "${urls[@]}"; do
  SPEED=$(curl -s -o /dev/null -w '%{speed_download}' --max-time 25 "$u" | awk '{printf "%.2f", $1/1024/1024}')
  echo " - $u => ${SPEED:-0} MB/s"
  TOTAL_NET=$(echo "$TOTAL_NET + ${SPEED:-0}" | bc)
done
NET_AVG=$(echo "$TOTAL_NET / ${#urls[@]}" | bc -l)
NET_AVG=$(printf "%.2f" "$NET_AVG")
echo "Network Average: $NET_AVG MB/s"
echo ""

# ----------------- Stability (Stress Test) -----------------
echo "[*] Performing short stress stability test..."
if ! command -v stress-ng &>/dev/null; then apt-get install -y stress-ng >/dev/null 2>&1; fi
timeout 10 stress-ng --cpu "$VCPUS" --timeout 10s >/dev/null 2>&1
LOAD_AVG=$(awk '{print $1}' /proc/loadavg)
LOAD_RATIO=$(awk -v l="$LOAD_AVG" -v c="$VCPUS" 'BEGIN{printf "%.2f", l/c}')

if (( $(echo "$LOAD_RATIO <= 0.8" | bc -l) )); then STAB_SCORE=95
elif (( $(echo "$LOAD_RATIO <= 1.2" | bc -l) )); then STAB_SCORE=80
else STAB_SCORE=60; fi
echo "Load Ratio: $LOAD_RATIO | Stability Score: $STAB_SCORE"
echo ""

# ----------------- Normalized Scores -----------------
norm() {
  local val=$1 max=$2
  echo "$(awk -v v="$val" -v m="$max" 'BEGIN{if(v>=m)print 100;else print (v/m*100)}')"
}

CPU_N=$(norm "$CPU_SCORE" 18000)
MEM_N=$(norm "$MEM_SPEED" 18000)
DISK_N=$(norm "$DISK_SPEED" 700)
NET_N=$(norm "$NET_AVG" 30)

# Weighted Power Index
POWER_SCORE=$(awk -v c="$CPU_N" -v m="$MEM_N" -v d="$DISK_N" -v n="$NET_N" -v s="$STAB_SCORE" \
'BEGIN{printf "%.1f", (0.35*c)+(0.15*m)+(0.25*d)+(0.10*n)+(0.15*s)}')

if (( $(echo "$POWER_SCORE >= 85" | bc -l) )); then VERDICT="💪 Excellent (Workstation Class)"
elif (( $(echo "$POWER_SCORE >= 70" | bc -l) )); then VERDICT="🟢 Strong (Stable for Dev & Docker)"
elif (( $(echo "$POWER_SCORE >= 55" | bc -l) )); then VERDICT="🟡 Moderate (Light workloads only)"
else VERDICT="🔴 Weak (Not recommended for production)"; fi

# ----------------- Final Report -----------------
echo "=================== FINAL ANALYSIS REPORT ==================="
printf "%-25s %s\n" "CPU Strength:" "$CPU_SCORE events/sec (Score: ${CPU_N%.*}/100)"
printf "%-25s %s\n" "Memory Throughput:" "$MEM_SPEED MiB/s (Score: ${MEM_N%.*}/100)"
printf "%-25s %s\n" "Disk Write:" "$DISK_SPEED MB/s (Score: ${DISK_N%.*}/100)"
printf "%-25s %s\n" "Network Avg:" "$NET_AVG MB/s (Score: ${NET_N%.*}/100)"
printf "%-25s %s\n" "Stability:" "$LOAD_RATIO load ratio (Score: ${STAB_SCORE}/100)"
echo "---------------------------------------------------------------"
printf "%-25s %s\n" "Power Score:" "$POWER_SCORE / 100"
printf "%-25s %s\n" "Verdict:" "$VERDICT"
echo "==============================================================="

# ----------------- Save Reports -----------------
REPORT_PATH="/tmp/workstation-analysis-${HOST}-$(date +%Y%m%dT%H%M%SZ)"
{
  echo "Host: $HOST"
  echo "IPv4: $IPV4"
  echo "IPv6: $IPV6"
  echo "Geo: $GEO_INFO"
  echo "CPU Score: $CPU_SCORE"
  echo "Memory Speed: $MEM_SPEED"
  echo "Disk Write: $DISK_SPEED"
  echo "Disk Read: $DISK_READ"
  echo "Network: $NET_AVG"
  echo "Stability: $STAB_SCORE"
  echo "Power Score: $POWER_SCORE"
  echo "Verdict: $VERDICT"
} >"${REPORT_PATH}.md"

jq -n --arg host "$HOST" \
  --arg ipv4 "$IPV4" \
  --arg ipv6 "$IPV6" \
  --arg geo "$GEO_INFO" \
  --arg cpu "$CPU_SCORE" \
  --arg mem "$MEM_SPEED" \
  --arg disk "$DISK_SPEED" \
  --arg net "$NET_AVG" \
  --arg stab "$STAB_SCORE" \
  --arg power "$POWER_SCORE" \
  --arg verdict "$VERDICT" \
  '{host:$host,ipv4:$ipv4,ipv6:$ipv6,geo:$geo,cpu:$cpu,mem:$mem,disk:$disk,network:$net,stability:$stab,power_score:$power,verdict:$verdict}' \
  >"${REPORT_PATH}.json"

echo ""
echo "Reports saved:"
echo " - ${REPORT_PATH}.md"
echo " - ${REPORT_PATH}.json"
echo "==============================================================="
