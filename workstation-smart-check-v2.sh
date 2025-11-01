#!/usr/bin/env bash
# workstation-smart-check-v2.sh
# Comprehensive VPS/Server Compatibility Benchmark
# Author: Malik Saqib

set -euo pipefail
IFS=$'\n\t'

echo "================= WORKSTATION COMPATIBILITY TEST v2 ================="

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
echo "OS: $OS"
echo "Kernel: $KERNEL"
echo "CPU: $CPU_MODEL ($VCPUS cores)"
echo "RAM: ${RAM_MB} MB"
echo "Disk: ${DISK_TOTAL}"
echo "Public IP: $IP"
echo "Uptime: $UPTIME"
echo ""

# ---------------- Thresholds (adaptive by cores) ----------------
if (( VCPUS <= 2 )); then
  CPU_REQ=3500; MEM_REQ=10000; DISK_REQ=200; NET_REQ=10; RAM_REQ=2000
elif (( VCPUS <= 4 )); then
  CPU_REQ=6000; MEM_REQ=18000; DISK_REQ=300; NET_REQ=20; RAM_REQ=6000
else
  CPU_REQ=8000; MEM_REQ=25000; DISK_REQ=500; NET_REQ=30; RAM_REQ=8000
fi

# ---------------- CPU Test ----------------
CPU_SCORE=$(sysbench cpu --time=3 run 2>/dev/null | awk -F: '/events per second/ {print $2}' | xargs)
CPU_SCORE=${CPU_SCORE:-0}
CPU_RESULT=$(awk -v v="$CPU_SCORE" -v r="$CPU_REQ" 'BEGIN{if(v>=r)print"✅ Pass";else print"❌ Fail"}')

# ---------------- Memory Test ----------------
MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
if (( MEM_TOTAL < 2000 )); then MEM_SIZE=64; else MEM_SIZE=256; fi
MEM_SPEED=$(sysbench memory --memory-total-size=${MEM_SIZE}M run 2>/dev/null | awk -F: '/MiB\/sec/ {print $2}' | xargs)
MEM_SPEED=${MEM_SPEED:-0}
MEM_RESULT=$(awk -v v="$MEM_SPEED" -v r="$MEM_REQ" 'BEGIN{if(v>=r)print"✅ Pass";else print"❌ Fail"}')

# ---------------- Disk Test ----------------
DISK_SPEED=$( (dd if=/dev/zero of=/tmp/testfile bs=1M count=256 oflag=direct conv=fdatasync 2>&1) | awk -F, '/copied/ {print $(NF)}' | awk '{print $1}')
rm -f /tmp/testfile >/dev/null 2>&1
DISK_SPEED=${DISK_SPEED:-0}
DISK_RESULT=$(awk -v v="$DISK_SPEED" -v r="$DISK_REQ" 'BEGIN{if(v>=r)print"✅ Pass";else print"❌ Fail"}')

# ---------------- Network Test ----------------
NET_SPEED=$(curl -s -o /dev/null -w '%{speed_download}' http://ipv4.download.thinkbroadband.com/100MB.zip | awk '{printf "%.2f\n", $1/1024/1024}')
NET_SPEED=${NET_SPEED:-0}
NET_RESULT=$(awk -v v="$NET_SPEED" -v r="$NET_REQ" 'BEGIN{if(v>=r)print"✅ Pass";else print"❌ Fail"}')

# ---------------- Load Ratio ----------------
LOAD_AVG=$(awk '{print $1}' /proc/loadavg)
LOAD_RATIO=$(awk -v l="$LOAD_AVG" -v c="$VCPUS" 'BEGIN{printf "%.2f", l/c}')
LOAD_RESULT=$(awk -v r="$LOAD_RATIO" 'BEGIN{if(r<=0.8)print"✅ Pass";else print"⚠️  High"}')

# ---------------- Tier Classification ----------------
if (( VCPUS >= 8 )) && (( RAM_MB >= 16000 )) && (( $(echo "$CPU_SCORE > 8000" | bc -l) )); then
  TIER="POWER"
elif (( VCPUS >= 4 )) && (( RAM_MB >= 6000 )); then
  TIER="STANDARD"
else
  TIER="LIMITED"
fi

# ---------------- Suitability Matrix ----------------
function check_suit() {
  local cpu="$1" mem="$2" disk="$3" net="$4"
  if (( $(echo "$cpu >= $CPU_REQ" | bc -l) )) && (( $(echo "$mem >= $MEM_REQ" | bc -l) )) && (( $(echo "$disk >= $DISK_REQ" | bc -l) )) && (( $(echo "$net >= $NET_REQ" | bc -l) )); then
    echo "✅ Suitable"
  else
    echo "⚠️  Limited"
  fi
}

SUIT_VSCODE=$(check_suit "$CPU_SCORE" "$MEM_SPEED" "$DISK_SPEED" "$NET_SPEED")
SUIT_DOCKER=$(check_suit "$CPU_SCORE" "$MEM_SPEED" "$DISK_SPEED" "$NET_SPEED")
SUIT_XRDP=$(check_suit "$CPU_SCORE" "$MEM_SPEED" "$DISK_SPEED" "$NET_SPEED")
SUIT_FULL=$(check_suit "$CPU_SCORE" "$MEM_SPEED" "$DISK_SPEED" "$NET_SPEED")

# ---------------- Report ----------------
echo ""
echo "================= PERFORMANCE RESULTS ================="
printf "%-20s %-12s %s\n" "CPU Score:" "$CPU_SCORE" "$CPU_RESULT"
printf "%-20s %-12s %s\n" "Memory Speed:" "$MEM_SPEED MiB/s" "$MEM_RESULT"
printf "%-20s %-12s %s\n" "Disk Write:" "$DISK_SPEED MB/s" "$DISK_RESULT"
printf "%-20s %-12s %s\n" "Network Speed:" "$NET_SPEED MB/s" "$NET_RESULT"
printf "%-20s %-12s %s\n" "Load Ratio:" "$LOAD_RATIO" "$LOAD_RESULT"
echo ""
echo "================= CAPABILITY SUMMARY ================="
printf "%-30s %s\n" "VSCode / Cursor IDE:" "$SUIT_VSCODE"
printf "%-30s %s\n" "Docker + N8N Workflows:" "$SUIT_DOCKER"
printf "%-30s %s\n" "XRDP GUI / Remote Desktop:" "$SUIT_XRDP"
printf "%-30s %s\n" "Full Stack Multitasking:" "$SUIT_FULL"
echo ""
echo "================= FINAL VERDICT ================="
echo "Tier: $TIER"
if [[ "$TIER" == "POWER" ]]; then
  echo "💪 POWER Tier — Excellent for full workstation and automation workloads"
elif [[ "$TIER" == "STANDARD" ]]; then
  echo "✅ STANDARD Tier — Suitable for development, Docker, GUI remote"
else
  echo "⚠️  LIMITED Tier — Basic workloads only; upgrade recommended"
fi
echo "=================================================================="
