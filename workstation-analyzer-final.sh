#!/usr/bin/env bash
# ================================================================
#  Workstation Analyzer Final (Deep Seek Procurement Edition)
#  Author: Malik Saqib
#  Deep, authentic system evaluation with Power Score + Issues
# ================================================================

set -euo pipefail
IFS=$'\n\t'

START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOST="$(hostname -s)"
REPORT_BASE="/tmp/deepseek-${HOST}-$(date +%Y%m%dT%H%M%SZ)"
LOG_FILE="${REPORT_BASE}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "================== WORKSTATION ANALYZER FINAL =================="
echo "[*] Running Deep Seek full system analysis..."
echo ""

# --------------------- Small helpers ---------------------
has() { command -v "$1" >/dev/null 2>&1; }
median() { awk ' {a[NR]=$1} END{ if(NR==0){print 0; exit}; asort(a); if (NR%2){print a[(NR+1)/2]} else {print (a[NR/2]+a[NR/2+1])/2} }'; }
cv_percent() { # arg: numbers via stdin
  awk 'BEGIN{s=0;ss=0;n=0}
       {v=$1;s+=v;ss+=v*v;n++}
       END{
         if(n<2){print 0; exit}
         m=s/n; var=(ss - n*m*m)/(n-1);
         if (m==0){print 0; exit}
         cv=sqrt(var)/m*100;
         printf "%.1f", cv
       }'
}
num() { awk '{gsub(/[^0-9.]/,"",$1); if($1=="")print 0; else print $1}' <<< "$1"; }

timeout_cmd() { # timeout seconds...; returns stdout
  timeout "$@"
}

# --------------------- Install deps (silent) ---------------------
if ! has sysbench || ! has bc || ! has curl || ! has jq; then
  echo "[*] Installing required tools..."
  apt-get update -qq || true
  apt-get install -y -qq sysbench bc curl jq >/dev/null 2>&1 || true
fi
# Optional tools
for pkg in stress-ng fio iputils-ping iproute2 netcat-openbsd; do
  has "${pkg%%-*}" || apt-get install -y -qq "$pkg" >/dev/null 2>&1 || true
done

# --------------------- System Info ---------------------
OS="$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
KERNEL="$(uname -r)"
CPU_MODEL="$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | xargs || true)"
VCPUS="$(nproc || echo 1)"
RAM_MB="$(free -m | awk '/Mem:/ {print $2}' 2>/dev/null || echo 0)"
DISK_TOTAL="$(df -h / | awk 'NR==2 {print $2}' 2>/dev/null || echo "N/A")"
UPTIME="$(uptime -p || echo "N/A")"

IPV4="$(curl -4 -s --max-time 5 ifconfig.me || echo "N/A")"
IPV6="$(curl -6 -s --max-time 5 ifconfig.me || echo "N/A")"
GEO_INFO="Unknown"
if [[ "$IPV4" != "N/A" && "$IPV4" != "" ]]; then
  GEO_INFO="$(curl -s --max-time 5 "https://ipapi.co/${IPV4}/json/" \
    | jq -r '[.city // "", .region // "", .country_name // "", .org // "Unknown ISP"] | join(", ")' 2>/dev/null || echo "Unknown")"
fi

echo "Host: $HOST"
echo "OS: $OS | Kernel: $KERNEL"
echo "CPU: $CPU_MODEL ($VCPUS cores)"
echo "RAM: ${RAM_MB} MB | Disk: ${DISK_TOTAL}"
echo "IPv4: $IPV4 | IPv6: $IPV6"
echo "Geo Info: $GEO_INFO"
echo "Uptime: $UPTIME"
echo ""

# --------------------- Bench: CPU (3x median) ---------------------
echo "[*] CPU test (3 runs × 5s)..."
CPU_RUNS=()
for i in 1 2 3; do
  v="$(timeout_cmd 8 sysbench cpu --threads="$VCPUS" --time=5 run 2>/dev/null | awk -F: '/events per second/ {print $2}' | xargs || echo 0)"
  v="$(num "$v")"; CPU_RUNS+=("$v"); echo "  - run $i: $v e/s"
done
CPU_MED="$(printf "%s\n" "${CPU_RUNS[@]}" | median)"
CPU_CV="$(printf "%s\n" "${CPU_RUNS[@]}" | cv_percent)"
CPU_PERCORE_EFF="$(awk -v e="$CPU_MED" -v c="$VCPUS" 'BEGIN{ if(c<=0){print 0}else{printf "%.1f", (e/(4000*c))*100}}')"
echo "CPU median: $CPU_MED e/s | per-core efficiency: $CPU_PERCORE_EFF% | consistency (CV): ${CPU_CV}%"

# --------------------- Bench: Memory (3x median, safe) ---------------------
echo "[*] Memory throughput (3 runs × 128MB)..."
MEM_RUNS=()
for i in 1 2 3; do
  v="$(timeout_cmd 15 sysbench memory --memory-block-size=1M --memory-total-size=128M run 2>/dev/null \
     | grep -Eo '[0-9]+\.[0-9]+ (MiB|MB)/sec' | awk '{print $1}' | tail -1)"
  v="$(num "$v")"; MEM_RUNS+=("$v"); echo "  - run $i: $v MiB/s"
done
MEM_MED="$(printf "%s\n" "${MEM_RUNS[@]}" | median)"
MEM_CV="$(printf "%s\n" "${MEM_RUNS[@]}" | cv_percent)"
echo "Memory median: $MEM_MED MiB/s | consistency (CV): ${MEM_CV}%"

# --------------------- Bench: Disk (super-safe write + read + IOPS) ---------------------
echo "[*] Disk write (super-safe, dd 256MB oflag=direct + fio fallback)..."
DISK_W_RUNS=()
for i in 1 2 3; do
  out="$(timeout_cmd 12 dd if=/dev/zero of=/tmp/deepseek_dd_test bs=1M count=256 oflag=direct status=none 2>&1 || echo "timeout")"
  v="$(echo "$out" | grep -oE '[0-9.]+ MB/s' | tail -1 | awk '{print $1}')"
  if [[ -z "$v" || "$v" == "0" ]]; then
    fio_out="$(timeout_cmd 15 fio --name=seqwrite --rw=write --bs=1M --size=256M --ioengine=sync --time_based --runtime=8s --group_reporting 2>/dev/null || true)"
    v="$(echo "$fio_out" | grep -oE '[0-9.]+ MB/s' | tail -1 | awk '{print $1}')"
  fi
  v="$(num "$v")"; DISK_W_RUNS+=("$v"); echo "  - write run $i: $v MB/s"
done
DISK_W_MED="$(printf "%s\n" "${DISK_W_RUNS[@]}" | median)"
DISK_W_CV="$(printf "%s\n" "${DISK_W_RUNS[@]}" | cv_percent)"
echo "[*] Disk read (dd 256MB)..."
DISK_R_RUNS=()
for i in 1 2 3; do
  out="$(timeout_cmd 10 dd if=/tmp/deepseek_dd_test of=/dev/null bs=1M count=256 status=none 2>&1 || true)"
  v="$(echo "$out" | grep -oE '[0-9.]+ MB/s' | tail -1 | awk '{print $1}')"
  v="$(num "$v")"; DISK_R_RUNS+=("$v"); echo "  - read run $i: $v MB/s"
done
rm -f /tmp/deepseek_dd_test >/dev/null 2>&1
DISK_R_MED="$(printf "%s\n" "${DISK_R_RUNS[@]}" | median)"
DISK_R_CV="$(printf "%s\n" "${DISK_R_RUNS[@]}" | cv_percent)"

echo "[*] Disk random 4k IOPS (fio, 8s)..."
IOPS=0
if has fio; then
  fio_out="$(timeout_cmd 12 fio --name=rand4k --rw=randread --bs=4k --iodepth=1 --size=128M --time_based --runtime=8s --group_reporting 2>/dev/null || true)"
  IOPS="$(echo "$fio_out" | grep -oE 'IOPS=.*' | head -1 | grep -oE '[0-9]+' | head -1)"
  IOPS="${IOPS:-0}"
fi

echo "Disk median write: $DISK_W_MED MB/s (CV ${DISK_W_CV}%) | read: $DISK_R_MED MB/s (CV ${DISK_R_CV}%) | rand IOPS: ${IOPS}"

# --------------------- Bench: Network (multi-mirror, medians + latency + ports) ---------------------
echo "[*] Network tests (per mirror: 3 runs; median):"
MIRRORS=("http://cachefly.cachefly.net/100mb.test" "http://ipv4.download.thinkbroadband.com/100MB.zip" "https://proof.ovh.net/files/100Mb.dat")
NET_ALL_RUNS=()
declare -A MIR_MED
for u in "${MIRRORS[@]}"; do
  R=()
  for i in 1 2 3; do
    s="$(timeout_cmd 25 curl -s -o /dev/null -w '%{speed_download}' "$u" | awk '{printf "%.2f", $1/1024/1024}' || echo 0)"
    s="$(num "$s")"; R+=("$s"); NET_ALL_RUNS+=("$s"); echo "  - $u run $i: $s MB/s"
  done
  MIR_MED["$u"]="$(printf "%s\n" "${R[@]}" | median)"
done
NET_MED="$(printf "%s\n" "${NET_ALL_RUNS[@]}" | median)"
NET_BEST="$(printf "%s\n" "${NET_ALL_RUNS[@]}" | awk 'BEGIN{m=0} {if($1>m)m=$1} END{print m}')"
NET_CV="$(printf "%s\n" "${NET_ALL_RUNS[@]}" | cv_percent)"

LAT_MS="NA"
if has ping && [[ "$IPV4" != "N/A" ]]; then
  LAT_MS="$(ping -c 3 -n 1.1.1.1 2>/dev/null | awk -F'/' '/rtt/ {printf "%.1f", $5}' || echo "NA")"
fi

echo "Network median: $NET_MED MB/s | best: $NET_BEST MB/s | CV: ${NET_CV}% | ping: ${LAT_MS} ms"

# Outbound ports
echo "[*] Outbound port checks..."
check_port() { local h="$1" p="$2"; if has nc && nc -z -w3 "$h" "$p" 2>/dev/null; then echo "ok"; else (exec 3<>/dev/tcp/"$h"/"$p") >/dev/null 2>&1 && echo "ok" || echo "blocked"; fi; }
P80="$(check_port google.com 80)"; P443="$(check_port google.com 443)"; P531="$(check_port 1.1.1.1 53)"; P532="$(check_port 8.8.8.8 53)"
echo "Outbound: 80=$P80  443=$P443  53(1.1.1.1)=$P531  53(8.8.8.8)=$P532"

# --------------------- Stability (stress) ---------------------
echo "[*] Stress-ng CPU burst (10s)..."
has stress-ng && timeout_cmd 12 stress-ng --cpu "$VCPUS" --timeout 10s >/dev/null 2>&1 || true
LOAD_AVG="$(awk '{print $1}' /proc/loadavg)"
LOAD_RATIO="$(awk -v l="$LOAD_AVG" -v c="$VCPUS" 'BEGIN{ if(c<=0){print 0}else{printf "%.2f", l/c}}')"
if (( $(echo "$LOAD_RATIO <= 0.8" | bc -l) )); then STAB_SCORE=95
elif (( $(echo "$LOAD_RATIO <= 1.2" | bc -l) )); then STAB_SCORE=80
else STAB_SCORE=60; fi
echo "Load ratio: $LOAD_RATIO → Stability Score: $STAB_SCORE"

# --------------------- Per-core normalized scoring ---------------------
clamp100() { awk -v v="$1" 'BEGIN{ if(v>100)print 100; else if(v<0)print 0; else print v }'; }
CPU_N_RAW="$(awk -v e="$CPU_MED" -v c="$VCPUS" 'BEGIN{ if(c<=0)print 0; else printf "%.1f", (e/(4000*c))*100 }')"
CPU_N="$(clamp100 "$CPU_N_RAW")"
MEM_N="$(clamp100 "$(awk -v v="$MEM_MED" 'BEGIN{printf "%.1f", (v/18000)*100}')")"
DISK_N="$(clamp100 "$(awk -v v="$DISK_W_MED" 'BEGIN{printf "%.1f", (v/700)*100}')")"
NET_N="$(clamp100 "$(awk -v v="$NET_MED" 'BEGIN{printf "%.1f", (v/30)*100}')")"

POWER_SCORE="$(awk -v c="$CPU_N" -v m="$MEM_N" -v d="$DISK_N" -v n="$NET_N" -v s="$STAB_SCORE" \
'BEGIN{printf "%.1f", (0.35*c)+(0.15*m)+(0.25*d)+(0.10*n)+(0.15*s)}')"

if (( $(echo "$POWER_SCORE >= 85" | bc -l) )); then VERDICT="💪 Excellent — Workstation Class"
elif (( $(echo "$POWER_SCORE >= 70" | bc -l) )); then VERDICT="🟢 Strong — Developer Grade"
elif (( $(echo "$POWER_SCORE >= 55" | bc -l) )); then VERDICT="🟡 Moderate — Light workloads"
else VERDICT="🔴 Weak — Not Recommended"; fi

# --------------------- Listening services snapshot ---------------------
echo "[*] Listening services (top 50):"
LSN="$(ss -tulnp 2>/dev/null | head -n 50 || netstat -tulnp 2>/dev/null | head -n 50 || echo "ss/netstat not available")"
echo "$LSN"

# --------------------- Issues list ---------------------
ISSUES=()
[[ "$P80" != "ok" ]]  && ISSUES+=("Outbound HTTP (80) blocked")
[[ "$P443" != "ok" ]] && ISSUES+=("Outbound HTTPS (443) blocked")
(( $(echo "$NET_MED < 10" | bc -l) )) && ISSUES+=("Network median < 10 MB/s (slow upstream)")
(( $(echo "$DISK_W_MED < 300" | bc -l) )) && ISSUES+=("Disk write < 300 MB/s (may throttle builds/containers)")
(( $(echo "$CPU_N_RAW < 80" | bc -l) )) && ISSUES+=("Per-core efficiency < 80% baseline")
(( $(echo "$STAB_SCORE < 80" | bc -l) )) && ISSUES+=("Stability score < 80 (high load ratio)")
(( $(echo "$CPU_CV > 12" | bc -l) )) && ISSUES+=("CPU variance high (noisy neighbor?)")
(( $(echo "$MEM_CV > 12" | bc -l) )) && ISSUES+=("Memory variance high")
(( $(echo "$DISK_W_CV > 12" | bc -l) )) && ISSUES+=("Disk write variance high")
(( $(echo "$NET_CV > 20" | bc -l) )) && ISSUES+=("Network variance very high")

# --------------------- Final Summary ---------------------
echo "=================== FINAL SYSTEM ANALYSIS ==================="
printf "%-26s %s\n" "CPU median:" "$CPU_MED e/s  | per-core eff $CPU_PERCORE_EFF% | CV ${CPU_CV}%"
printf "%-26s %s\n" "Memory median:" "$MEM_MED MiB/s | CV ${MEM_CV}%"
printf "%-26s %s\n" "Disk write (med):" "$DISK_W_MED MB/s | CV ${DISK_W_CV}%"
printf "%-26s %s\n" "Disk read (med):" "$DISK_R_MED MB/s | CV ${DISK_R_CV}%"
printf "%-26s %s\n" "Rand IOPS 4k:" "${IOPS}"
printf "%-26s %s\n" "Network median:" "$NET_MED MB/s | best $NET_BEST | CV ${NET_CV}% | ping ${LAT_MS} ms"
printf "%-26s %s\n" "Outbound:" "80=$P80  443=$P443  53(1.1.1.1)=$P531  53(8.8.8.8)=$P532"
printf "%-26s %s\n" "Stability:" "load ratio $LOAD_RATIO  → score $STAB_SCORE"
echo "--------------------------------------------------------------"
printf "%-26s %s\n" "Power Score:" "$POWER_SCORE / 100"
printf "%-26s %s\n" "Verdict:" "$VERDICT"
printf "%-26s %s\n" "IPv4 / IPv6:" "$IPV4  /  $IPV6"
printf "%-26s %s\n" "Geo:" "$GEO_INFO"
echo "--------------------------------------------------------------"
if (( ${#ISSUES[@]} )); then
  echo "ISSUES:"
  for it in "${ISSUES[@]}"; do echo " - $it"; done
else
  echo "ISSUES: none"
fi
echo "=============================================================="

# --------------------- Save Reports ---------------------
MD="${REPORT_BASE}.md"
JSON="${REPORT_BASE}.json"

{
  echo "# Deep Seek Workstation Analysis — $HOST"
  echo "- Timestamp (UTC): $START_TS"
  echo "- OS/Kernel: $OS | $KERNEL"
  echo "- CPU: $CPU_MODEL ($VCPUS cores)"
  echo "- RAM/Disk: ${RAM_MB} MB | ${DISK_TOTAL}"
  echo "- IPv4/IPv6: $IPV4 | $IPV6"
  echo "- Geo: $GEO_INFO"
  echo "## Results"
  echo "- CPU median: $CPU_MED e/s (per-core $CPU_PERCORE_EFF%, CV ${CPU_CV}%)"
  echo "- Memory median: $MEM_MED MiB/s (CV ${MEM_CV}%)"
  echo "- Disk write median: $DISK_W_MED MB/s (CV ${DISK_W_CV}%)"
  echo "- Disk read median:  $DISK_R_MED MB/s (CV ${DISK_R_CV}%)"
  echo "- Random IOPS 4k: $IOPS"
  echo "- Network: median $NET_MED MB/s, best $NET_BEST, CV ${NET_CV}%, ping ${LAT_MS} ms"
  echo "- Outbound: 80=$P80, 443=$P443, 53(1.1.1.1)=$P531, 53(8.8.8.8)=$P532"
  echo "- Stability: load ratio $LOAD_RATIO → score $STAB_SCORE"
  echo "## Score"
  echo "- CPU=${CPU_N}  MEM=${MEM_N}  DISK=${DISK_N}  NET=${NET_N}  STAB=${STAB_SCORE}"
  echo "- **Power Score: $POWER_SCORE / 100**"
  echo "- **Verdict: $VERDICT**"
  echo "## Issues"
  if (( ${#ISSUES[@]} )); then for it in "${ISSUES[@]}"; do echo "- $it"; done; else echo "- none"; fi
  echo "## Listening services (top 50)"
  echo '```'
  echo "$LSN"
  echo '```'
} > "$MD"

jq -n --arg host "$HOST" \
  --arg ts "$START_TS" \
  --arg os "$OS" --arg kernel "$KERNEL" \
  --arg cpu_model "$CPU_MODEL" --arg vcpus "$VCPUS" \
  --arg ram_mb "$RAM_MB" --arg disk_total "$DISK_TOTAL" \
  --arg ipv4 "$IPV4" --arg ipv6 "$IPV6" --arg geo "$GEO_INFO" \
  --arg cpu_med "$CPU_MED" --arg cpu_cv "$CPU_CV" --arg cpu_eff "$CPU_PERCORE_EFF" \
  --arg mem_med "$MEM_MED" --arg mem_cv "$MEM_CV" \
  --arg dww "$DISK_W_MED" --arg dwcv "$DISK_W_CV" --arg drw "$DISK_R_MED" --arg drcv "$DISK_R_CV" --arg iops "$IOPS" \
  --arg net_med "$NET_MED" --arg net_best "$NET_BEST" --arg net_cv "$NET_CV" --arg ping "$LAT_MS" \
  --arg p80 "$P80" --arg p443 "$P443" --arg p531 "$P531" --arg p532 "$P532" \
  --arg load_ratio "$LOAD_RATIO" --arg stab "$STAB_SCORE" \
  --arg cpu_n "$CPU_N" --arg mem_n "$MEM_N" --arg disk_n "$DISK_N" --arg net_n "$NET_N" \
  --arg power "$POWER_SCORE" --arg verdict "$VERDICT" \
  --argjson issues "$(printf '%s\n' "${ISSUES[@]}" | jq -R . | jq -s .)" \
  '{host:$host,timestamp_utc:$ts,os:$os,kernel:$kernel,cpu_model:$cpu_model,vcpu:$vcpus,ram_mb:$ram_mb,disk_total:$disk_total,ipv4:$ipv4,ipv6:$ipv6,geo:$geo,
    cpu:{median:$cpu_med,cv_pct:$cpu_cv,per_core_eff_pct:$cpu_eff},
    memory:{median_mib_s:$mem_med,cv_pct:$mem_cv},
    disk:{write_mb_s:$dww,write_cv_pct:$dwcv,read_mb_s:$drw,read_cv_pct:$drcv,iops_4k:$iops},
    network:{median_mb_s:$net_med,best_mb_s:$net_best,cv_pct:$net_cv,ping_ms:$ping,ports:{p80:$p80,p443:$p443,p53_cf:$p531,p53_google:$p532}},
    stability:{load_ratio:$load_ratio,score:$stab},
    normalized:{cpu:$cpu_n,mem:$mem_n,disk:$disk_n,net:$net_n},
    power_score:$power,verdict:$verdict,issues:$issues}' > "${JSON}"

SHA="$(sha1sum "${JSON}" | awk '{print $1}')"
echo "Reports saved:"
echo " - ${MD}"
echo " - ${JSON}"
echo " - ${LOG_FILE}"
echo "Report ID (sha1 of JSON): ${SHA}"
echo "=============================================================="
