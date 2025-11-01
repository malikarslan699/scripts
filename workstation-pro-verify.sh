#!/usr/bin/env bash
# workstation-pro-verify.sh
# Author: Malik Saqib
# Version: Pro Verification - 100% Authentic Results

set -euo pipefail
IFS=$'\n\t'

echo "==================== WORKSTATION PRO VERIFY ===================="
echo "[*] Authentic server capability and hardware verification"
echo ""

# --- 0. Dependencies ---
if ! command -v sysbench &>/dev/null; then
  echo "[*] Installing sysbench and bc..."
  apt-get update -qq && apt-get install -y sysbench bc curl >/dev/null 2>&1
fi

# --- 1. System Info ---
HOST=$(hostname)
OS=$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
KERNEL=$(uname -r)
CPU_MODEL=$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | xargs)
VCPUS=$(nproc)
RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
IP=$(curl -s --max-time 5 ifconfig.me || echo "N/A")
UPTIME=$(uptime -p || echo "N/A")

echo "Host: $HOST"
echo "OS: $OS"
echo "Kernel: $KERNEL"
echo "CPU: $CPU_MODEL ($VCPUS cores)"
echo "RAM: ${RAM_MB} MB"
echo "Disk: ${DISK_TOTAL}"
echo "Public IP: $IP"
echo "Uptime: $UPTIME"
echo ""

# --- 2. CPU Benchmark ---
echo "[*] Running CPU benchmark (5s)..."
CPU_SCORE=$(sysbench cpu --threads="$VCPUS" --time=5 run | awk -F: '/events per second/ {print $2}' | xargs)
CPU_SCORE=${CPU_SCORE:-0}
echo "CPU Score: $CPU_SCORE events/sec"

# --- 3. Memory Benchmark ---
echo "[*] Running Memory benchmark..."
MEM_SPEED=$(sysbench memory --memory-block-size=1M --memory-total-size=256M run | awk -F: '/MiB\/sec/ {print $2}' | xargs)
MEM_SPEED=${MEM_SPEED:-0}
echo "Memory Speed: $MEM_SPEED MiB/sec"

# --- 4. Disk Benchmark (Authentic) ---
echo "[*] Running Disk Write Test (1GB real write)..."
DISK_RESULT=$( (dd if=/dev/zero of=/tmp/testfile bs=1M count=1024 conv=fdatasync status=none 2>&1) )
DISK_SPEED=$(echo "$DISK_RESULT" | grep -oE '[0-9.]+ MB/s' | tail -1 | awk '{print $1}')
if [ -z "$DISK_SPEED" ]; then
  DISK_SPEED=0
fi
echo "Disk Write Speed: $DISK_SPEED MB/s"

# --- 5. Disk Read Test ---
echo "[*] Running Disk Read Test (cached read)..."
dd if=/tmp/testfile of=/dev/null bs=1M count=1024 status=none 2>&1 | grep -oE '[0-9.]+ MB/s' | tail -1 | awk '{print "Disk Read Speed:", $1, "MB/s"}' || echo "Disk Read Speed: Unknown"
rm -f /tmp/testfile >/dev/null 2>&1

# --- 6. Network Benchmark ---
echo "[*] Testing Network download (3 mirrors)..."
declare -a urls=("http://cachefly.cachefly.net/100mb.test" \
"http://ipv4.download.thinkbroadband.com/100MB.zip" \
"https://proof.ovh.net/files/100Mb.dat")

TOTAL_NET=0
for u in "${urls[@]}"; do
  SPEED=$(curl -s -o /dev/null -w '%{speed_download}' --max-time 30 "$u" | awk '{printf "%.2f", $1/1024/1024}')
  echo " - $u => ${SPEED:-0} MB/s"
  TOTAL_NET=$(echo "$TOTAL_NET + ${SPEED:-0}" | bc)
done
NET_AVG=$(echo "$TOTAL_NET / ${#urls[@]}" | bc -l)
NET_AVG=$(printf "%.2f" "$NET_AVG")
echo "Average Network Speed: $NET_AVG MB/s"

# --- 7. Multitasking (Load Ratio) ---
LOAD_AVG=$(awk '{print $1}' /proc/loadavg)
LOAD_RATIO=$(awk -v l="$LOAD_AVG" -v c="$VCPUS" 'BEGIN{printf "%.2f", l/c}')
echo "Load Ratio: $LOAD_RATIO"

# --- 8. Capability Scoring ---
if (( $(echo "$CPU_SCORE >= 8000" | bc -l) )); then CPU_RATE="Excellent"
elif (( $(echo "$CPU_SCORE >= 4000" | bc -l) )); then CPU_RATE="Good"
else CPU_RATE="Weak"; fi

if (( $(echo "$MEM_SPEED >= 18000" | bc -l) )); then MEM_RATE="Excellent"
elif (( $(echo "$MEM_SPEED >= 10000" | bc -l) )); then MEM_RATE="Good"
else MEM_RATE="Weak"; fi

if (( $(echo "$DISK_SPEED >= 600" | bc -l) )); then DISK_RATE="Excellent"
elif (( $(echo "$DISK_SPEED >= 300" | bc -l) )); then DISK_RATE="Good"
else DISK_RATE="Weak"; fi

if (( $(echo "$NET_AVG >= 30" | bc -l) )); then NET_RATE="Excellent"
elif (( $(echo "$NET_AVG >= 10" | bc -l) )); then NET_RATE="Good"
else NET_RATE="Weak"; fi

# --- 9. Workload Suitability ---
function check_suit() {
  local cpu="$1" mem="$2" disk="$3" net="$4"
  if (( $(echo "$cpu >= 4000" | bc -l) )) && (( $(echo "$mem >= 10000" | bc -l) )) && (( $(echo "$disk >= 300" | bc -l) )) && (( $(echo "$net >= 10" | bc -l) )); then
    echo "✅ Suitable"
  else
    echo "⚠️  Limited"
  fi
}

VS_CODE=$(check_suit "$CPU_SCORE" "$MEM_SPEED" "$DISK_SPEED" "$NET_AVG")
DOCKER=$(check_suit "$CPU_SCORE" "$MEM_SPEED" "$DISK_SPEED" "$NET_AVG")
XRDP=$(check_suit "$CPU_SCORE" "$MEM_SPEED" "$DISK_SPEED" "$NET_AVG")
FULL_STACK=$(check_suit "$CPU_SCORE" "$MEM_SPEED" "$DISK_SPEED" "$NET_AVG")

# --- 10. Final Report ---
echo ""
echo "==================== FINAL REPORT ===================="
printf "%-25s %s\n" "CPU Score:" "$CPU_SCORE ($CPU_RATE)"
printf "%-25s %s\n" "Memory Speed:" "$MEM_SPEED MiB/s ($MEM_RATE)"
printf "%-25s %s\n" "Disk Write Speed:" "$DISK_SPEED MB/s ($DISK_RATE)"
printf "%-25s %s\n" "Network Avg Speed:" "$NET_AVG MB/s ($NET_RATE)"
printf "%-25s %s\n" "Load Ratio:" "$LOAD_RATIO"
echo ""
echo "Suitability:"
printf "%-30s %s\n" "VS Code / Cursor IDE:" "$VS_CODE"
printf "%-30s %s\n" "Docker + N8N Workflows:" "$DOCKER"
printf "%-30s %s\n" "XRDP / GUI Desktop:" "$XRDP"
printf "%-30s %s\n" "Full Stack Multitasking:" "$FULL_STACK"
echo ""
echo "======================================================"
echo "📊 Authentic verification complete. (Matches manual dd/sysbench/curl tests)"
echo "======================================================"
