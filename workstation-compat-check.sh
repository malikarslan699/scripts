#!/usr/bin/env bash
# workstation-compat-check.sh
# Tests a VPS or server for workstation readiness (no installations required)
# Author: Malik Saqib

set -e

echo "================= WORKSTATION COMPATIBILITY TEST ================="
echo "[INFO] Running quick tests (no installation required)"
echo ""

# ----- 1. System Info -----
HOST=$(hostname)
OS=$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
KERNEL=$(uname -r)
CPU_MODEL=$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | xargs)
VCPUS=$(nproc)
RAM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
IP=$(curl -s ifconfig.me || echo "N/A")

echo "Host: $HOST"
echo "OS: $OS"
echo "Kernel: $KERNEL"
echo "CPU: $CPU_MODEL ($VCPUS vCPUs)"
echo "RAM: ${RAM_TOTAL} MB"
echo "Disk: ${DISK_TOTAL}"
echo "Public IP: $IP"
echo ""

# ----- 2. Requirements -----
CPU_REQ=6000
MEM_REQ=18000
DISK_REQ=300
NET_REQ=20
RAM_REQ=6000
VCPU_REQ=4

# ----- 3. CPU Test -----
CPU_SCORE=$(sysbench cpu --time=3 run 2>/dev/null | awk -F: '/events per second/ {print $2}' | xargs)
CPU_SCORE=${CPU_SCORE:-0}

if (( $(echo "$CPU_SCORE >= $CPU_REQ" | bc -l) )); then
    CPU_RESULT="✅ Pass"
else
    CPU_RESULT="❌ Fail"
fi

# ----- 4. Memory Test -----
MEM_SPEED=$(sysbench memory --memory-total-size=256M run 2>/dev/null | awk -F: '/MiB\/sec/ {print $2}' | xargs)
MEM_SPEED=${MEM_SPEED:-0}

if (( $(echo "$MEM_SPEED >= $MEM_REQ" | bc -l) )); then
    MEM_RESULT="✅ Pass"
else
    MEM_RESULT="❌ Fail"
fi

# ----- 5. Disk Write Test -----
DISK_SPEED=$( (dd if=/dev/zero of=/tmp/testfile bs=1M count=256 oflag=direct conv=fdatasync 2>&1) | awk -F, '/copied/ {print $(NF)}' | awk '{print $1}')
rm -f /tmp/testfile >/dev/null 2>&1
DISK_SPEED=${DISK_SPEED:-0}

if (( $(echo "$DISK_SPEED >= $DISK_REQ" | bc -l) )); then
    DISK_RESULT="✅ Pass"
else
    DISK_RESULT="❌ Fail"
fi

# ----- 6. Network Test -----
NET_SPEED=$(curl -s -o /dev/null -w '%{speed_download}' http://ipv4.download.thinkbroadband.com/100MB.zip | awk '{printf "%.2f\n", $1/1024/1024}')
NET_SPEED=${NET_SPEED:-0}

if (( $(echo "$NET_SPEED >= $NET_REQ" | bc -l) )); then
    NET_RESULT="✅ Pass"
else
    NET_RESULT="❌ Fail"
fi

# ----- 7. Multitasking / Load -----
LOAD_AVG=$(awk '{print $1}' /proc/loadavg)
LOAD_RATIO=$(echo "$LOAD_AVG / $VCPUS" | bc -l)
if (( $(echo "$LOAD_RATIO <= 0.8" | bc -l) )); then
    LOAD_RESULT="✅ Pass"
else
    LOAD_RESULT="❌ Fail"
fi

# ----- 8. Verdict -----
echo ""
echo "================= PERFORMANCE RESULTS ================="
printf "%-20s %-15s %s\n" "CPU Score:" "$CPU_SCORE" "$CPU_RESULT"
printf "%-20s %-15s %s\n" "Memory Speed:" "$MEM_SPEED MiB/s" "$MEM_RESULT"
printf "%-20s %-15s %s\n" "Disk Write:" "$DISK_SPEED MB/s" "$DISK_RESULT"
printf "%-20s %-15s %s\n" "Network Speed:" "$NET_SPEED MB/s" "$NET_RESULT"
printf "%-20s %-15s %s\n" "Load Ratio:" "$LOAD_RATIO" "$LOAD_RESULT"
echo ""

# ----- 9. Workstation Readiness -----
echo "================= CAPABILITY SUMMARY ================="
if [[ "$CPU_RESULT" == "✅ Pass" && "$MEM_RESULT" == "✅ Pass" && "$DISK_RESULT" == "✅ Pass" && "$NET_RESULT" == "✅ Pass" && "$LOAD_RESULT" == "✅ Pass" ]]; then
    echo "✅ This VPS meets all workstation requirements."
    echo "Suitable for: VSCode Remote, Docker/N8N, GUI (XRDP), multitasking."
else
    echo "⚠️  VPS does NOT fully meet workstation standards."
    echo "Review failing metrics above before using for heavy workloads."
fi
echo "================================================================"
