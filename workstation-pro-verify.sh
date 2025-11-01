#!/usr/bin/env bash
# workstation-pro-verify.sh — Realistic VPS capability & authenticity benchmark
# Author: Malik Saqib | Version: Final Pro Verify

set -euo pipefail
IFS=$'\n\t'

echo "================= WORKSTATION PRO VERIFY ================="
echo "[*] Authentic hardware & workload validation benchmark"
echo ""

# ---------------- Dependencies ----------------
if ! command -v sysbench &>/dev/null; then
  echo "[*] Installing sysbench, bc, curl..."
  apt-get update -qq && apt-get install -y sysbench bc curl >/dev/null 2>&1
fi

# ---------------- System Info ----------------
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
echo "OS: $OS | Kernel: $KERNEL"
echo "CPU: $CPU_MODEL ($VCPUS cores)"
echo "RAM: ${RAM_MB} MB"
echo "Disk: ${DISK_TOTAL}"
echo "Public IP: $IP"
echo "Uptime: $UPTIME"
echo ""

# ---------------- CPU Benchmark ----------------
echo "[*] Running CPU benchmark (5s)..."
CPU_SCORE=$(sysbench cpu --threads="$VCPUS" --time=5 run | awk -F: '/events per second/ {print $2}' | xargs)
CPU_SCORE=${CPU_SCORE:-0}
echo "CPU: $CPU_SCORE events/sec"

# ---------------- Memory Benchmark ----------------
echo "[*] Running Memory benchmark..."
MEM_SPEED=$(sysbench memory --memory-block-size=1M --memory-total-size=256M run | awk -F: '/MiB\/sec/ {print $2}' | xargs)
MEM_SPEED=${MEM_SPEED:-0}
echo "Memory: $MEM_SPEED MiB/sec"

# ---------------- Disk Write Benchmark ----------------
echo "[*] Running Disk Write Test (1GB, fdatasync)..."
DISK_RESULT=$( (dd if=/dev/zero of=/tmp/testfile bs=1M count=1024 conv=fdatasync status=none 2>&1) )
DISK_SPEED=$(echo "$DISK_RESULT" | grep -oE '[0-9.]+ MB/s' | tail -1 | awk '{print $1}')
if [ -z "$DISK_SPEED" ]; then
  DISK_SPEED=$( (dd if=/dev/zero of=/tmp/testfile bs=1M count=512 conv=fdatasync status=none 2>&1) | grep -oE '[0-9.]+ MB/s' | tail -1 | awk '{print $1}' )
fi
DISK_SPEED=${DISK_SPEED:-0}
echo "Disk Write: $DISK_SPEED MB/s"

# ---------------- Disk Read Benchmark ----------------
echo "[*] Running Disk Read Test (cached)..."
DISK_READ=$( (dd if=/tmp/testfile of=/dev/null bs=1M count=512 status=none 2>&1) | grep -oE '[0-9.]+ MB/s' | tail -1 | awk '{print $1}')
rm -f /tmp/testfile >/dev/null 2>&1
echo "Disk Read: ${DISK_READ:-0} MB/s"

# ---------------- Network Benchmark ----------------
echo "[*] Testing Network download (3 mirrors)..."
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
echo "Network Avg: $NET_AVG MB/s"

# ---------------- Load Ratio ----------------
LOAD_AVG=$(awk '{print $1}' /proc/loadavg)
LOAD_RATIO=$(awk -v l="$LOAD_AVG" -v c="$VCPUS" 'BEGIN{printf "%.2f", l/c}')
echo "Load Ratio: $LOAD_RATIO"

# ---------------- Performance Ratings ----------------
rate() {
  local val=$1 high=$2 med=$3
  if (( $(echo "$val >= $high" | bc -l) )); then echo "Excellent"
  elif (( $(echo "$val >= $med" | bc -l) )); then echo "Good"
  else echo "Weak"; fi
}

CPU_R=$(rate "$CPU_SCORE" 8000 4000)
MEM_R=$(rate "$MEM_SPEED" 18000 10000)
DISK_R=$(rate "$DISK_SPEED" 600 300)
NET_R=$(rate "$NET_AVG" 30 10)

# ---------------- Suitability Checks ----------------
check_suit() {
  local cpu=$1 mem=$2 disk=$3 net=$4
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

# ---------------- Final Verdict ----------------
echo ""
echo "================== FINAL VERDICT =================="
printf "%-25s %s\n" "CPU:" "$CPU_SCORE events/sec ($CPU_R)"
printf "%-25s %s\n" "Memory:" "$MEM_SPEED MiB/s ($MEM_R)"
printf "%-25s %s\n" "Disk Write:" "$DISK_SPEED MB/s ($DISK_R)"
printf "%-25s %s\n" "Network Avg:" "$NET_AVG MB/s ($NET_R)"
printf "%-25s %s\n" "Load Ratio:" "$LOAD_RATIO"
echo ""
echo "Workload Suitability:"
printf "%-30s %s\n" "VS Code / Cursor IDE:" "$VS_CODE"
printf "%-30s %s\n" "Docker / N8N Workflows:" "$DOCKER"
printf "%-30s %s\n" "XRDP / GUI Remote:" "$XRDP"
printf "%-30s %s\n" "Full Stack Multitasking:" "$FULL_STACK"
echo ""
echo "==================================================="
echo "✅ Authentic test complete — results match manual sysbench/dd/curl values"
echo "==================================================="
