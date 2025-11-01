#!/usr/bin/env bash
# ================================================================
#  Workstation Analyzer Final (Deep Seek - Console Only, VPN-capacity)
#  One run → full printed report → single verdict.
#  Includes: CPU/Mem/Disk/Net/Stability + VPN Capacity (WG/OpenVPN/IPsec).
#  Robust disk parsing (dd+fio), geo fallbacks, triple-run medians+CV%.
# ================================================================

# Do not exit on single test failure (we want a full printed report)
set -uo pipefail
IFS=$'\n\t'

has() { command -v "$1" >/dev/null 2>&1; }
num() { awk '{gsub(/[^0-9.]/,"",$1); if($1=="")print 0; else print $1}' <<< "$1"; }
median() { awk '{a[NR]=$1} END{ if(NR==0){print 0; exit}; asort(a); if (NR%2){print a[(NR+1)/2]} else {print (a[NR/2]+a[NR/2+1])/2} }'; }
cv_percent() { awk 'BEGIN{s=0;ss=0;n=0}{v=$1+0;s+=v;ss+=v*v;n++}END{if(n<2){print 0;exit}m=s/n;var=(ss-n*m*m)/(n-1);if(m==0){print 0;exit}cv=sqrt(var)/m*100;printf "%.1f",cv}'; }
timeout_cmd() { timeout "$@"; }
clamp100() { awk -v v="$1" 'BEGIN{ if(v>100)print 100; else if(v<0)print 0; else print v }'; }

echo "================== WORKSTATION ANALYZER FINAL =================="
echo "[*] Running Deep Seek full system analysis (console-only)..."
echo ""

# --------------------- Dependencies (silent) ---------------------
if has apt-get; then
  sudo apt-get update -qq || true
  sudo apt-get install -y -qq sysbench bc curl jq fio stress-ng iputils-ping netcat-openbsd openssl >/dev/null 2>&1 || true
elif has dnf; then
  sudo dnf -y install sysbench bc curl jq fio stress-ng iputils nmap-ncat openssl >/dev/null 2>&1 || true
elif has yum; then
  sudo yum -y install sysbench bc curl jq fio stress-ng iputils nmap-ncat openssl >/dev/null 2>&1 || true
fi

# --------------------- Inputs (optional CLI) ---------------------
# Usage: workstation-analyzer-final.sh [--vpn-users N] [--per-user-mbps X]
VPN_USERS=100
PER_USER_MBPS=1.0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vpn-users) VPN_USERS="${2:-100}"; shift 2;;
    --per-user-mbps) PER_USER_MBPS="${2:-1.0}"; shift 2;;
    *) shift;;
  esac
done

# --------------------- System Info ---------------------
HOST="$(hostname -s)"
OS="$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "Unknown OS")"
KERNEL="$(uname -r || echo "Unknown")"
CPU_MODEL="$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null | xargs || echo "Unknown CPU")"
VCPUS="$(nproc 2>/dev/null || echo 1)"
RAM_MB="$(free -m 2>/dev/null | awk '/Mem:/ {print $2}' || echo 0)"
DISK_TOTAL="$(df -h / 2>/dev/null | awk 'NR==2 {print $2}' || echo "N/A")"
UPTIME="$(uptime -p 2>/dev/null || echo "N/A")"

IPV4="$(curl -4 -s --max-time 5 ifconfig.me || echo "N/A")"
IPV6="$(curl -6 -s --max-time 5 ifconfig.me || echo "N/A")"

geo_try() {
  local ip="$1" val=""
  val="$(curl -s --max-time 5 "https://ipapi.co/${ip}/json/" | jq -r '[.city // "", .region // "", .country_name // "", .org // "Unknown ISP"] | join(", ")' 2>/dev/null)"
  [[ -n "$val" && ! "$val" =~ ^[[:space:],]*$ ]] && { echo "$val"; return; }
  val="$(curl -s --max-time 5 "https://ipinfo.io/${ip}/json"        | jq -r '[.city // "", .region // "", .country // "", .org // "Unknown ISP"] | join(", ")' 2>/dev/null)"
  [[ -n "$val" && ! "$val" =~ ^[[:space:],]*$ ]] && { echo "$val"; return; }
  val="$(curl -s --max-time 5 "http://ip-api.com/json/${ip}"        | jq -r '[.city // "", .regionName // "", .country // "", .isp // "Unknown ISP"] | join(", ")' 2>/dev/null)"
  [[ -n "$val" && ! "$val" =~ ^[[:space:],]*$ ]] && { echo "$val"; return; }
  echo "Unknown"
}
GEO_INFO="Unknown"
if [[ "$IPV4" != "N/A" && -n "$IPV4" ]]; then GEO_INFO="$(geo_try "$IPV4")"; fi

echo "Host: $HOST"
echo "OS: $OS | Kernel: $KERNEL"
echo "CPU: $CPU_MODEL ($VCPUS cores)"
echo "RAM: ${RAM_MB} MB | Disk: ${DISK_TOTAL}"
echo "IPv4: $IPV4 | IPv6: $IPV6"
echo "Geo: $GEO_INFO"
echo "Uptime: $UPTIME"
echo ""

# --------------------- CPU (3×) ---------------------
echo "[*] CPU test (3 runs × 5s)..."
CPU_RUNS=()
if has sysbench; then
  for i in 1 2 3; do
    v="$(timeout_cmd 8 sysbench cpu --threads="$VCPUS" --time=5 run 2>/dev/null | awk -F: '/events per second/ {print $2}' | xargs || echo 0)"
    v="$(num "$v")"; CPU_RUNS+=("$v"); printf "  - run %d: %s e/s\n" "$i" "$v"
  done
else CPU_RUNS=(0 0 0); echo "  ! sysbench missing → CPU=0"; fi
CPU_MED="$(printf "%s\n" "${CPU_RUNS[@]}" | median)"
CPU_CV="$(printf "%s\n" "${CPU_RUNS[@]}" | cv_percent)"
CPU_PERCORE_EFF="$(awk -v e="$CPU_MED" -v c="$VCPUS" 'BEGIN{ if(c<=0){print 0}else{printf "%.1f", (e/(4000*c))*100}}')"
echo "CPU median: $CPU_MED e/s | per-core efficiency: $CPU_PERCORE_EFF% | consistency (CV): ${CPU_CV}%"

# --------------------- Memory (3×) ---------------------
echo "[*] Memory throughput (3 runs × 128MB)..."
MEM_RUNS=()
if has sysbench; then
  for i in 1 2 3; do
    v="$(timeout_cmd 15 sysbench memory --memory-block-size=1M --memory-total-size=128M run 2>/dev/null \
       | grep -Eo '[0-9]+(\.[0-9]+)? (MiB|MB)/sec' | awk '{print $1}' | tail -1)"
    v="$(num "$v")"; MEM_RUNS+=("$v"); printf "  - run %d: %s MiB/s\n" "$i" "$v"
  done
else MEM_RUNS=(0 0 0); echo "  ! sysbench missing → Memory=0"; fi
MEM_MED="$(printf "%s\n" "${MEM_RUNS[@]}" | median)"
MEM_CV="$(printf "%s\n" "${MEM_RUNS[@]}" | cv_percent)"
echo "Memory median: $MEM_MED MiB/s | consistency (CV): ${MEM_CV}%"

# --------------------- Disk (write+read+IOPS) ---------------------
TESTFILE="/tmp/deepseek_dd_test"
parse_speed() { grep -Eo '[0-9]+(\.[0-9]+)? (MiB|MB)/s' | tail -1 | awk '{print $1}'; }

disk_write_once() {
  out="$(LC_ALL=C timeout_cmd 12 dd if=/dev/zero of="$TESTFILE" bs=1M count=256 oflag=direct 2>&1 || true)"
  v="$(echo "$out" | parse_speed)"
  if [[ -z "$v" || "$v" == "0" || "$out" == *"Invalid argument"* ]]; then
    out="$(LC_ALL=C timeout_cmd 12 dd if=/dev/zero of="$TESTFILE" bs=1M count=256 conv=fdatasync 2>&1 || true)"
    v="$(echo "$out" | parse_speed)"
  fi
  if [[ -z "$v" || "$v" == "0" ]]; then
    if has fio; then
      fio_out="$(timeout_cmd 15 fio --name=seqwrite --rw=write --bs=1M --size=256M --ioengine=sync --time_based --runtime=8s --group_reporting 2>/dev/null || true)"
      # fio shows "bw=xxxMiB/s" → extract number
      v="$(echo "$fio_out" | grep -Eo 'bw=[0-9]+(\.[0-9]+)?(MiB|MB)/s' | head -1 | grep -Eo '[0-9]+(\.[0-9]+)?')"
    fi
  fi
  echo "$(num "$v")"
}

echo "[*] Disk write (3 runs, robust dd → dd(fdatasync) → fio)..."
DISK_W_RUNS=()
for i in 1 2 3; do
  v="$(disk_write_once)"; DISK_W_RUNS+=("$v"); printf "  - write run %d: %s MB/s\n" "$i" "$v"
done
DISK_W_MED="$(printf "%s\n" "${DISK_W_RUNS[@]}" | median)"
DISK_W_CV="$(printf "%s\n" "${DISK_W_RUNS[@]}" | cv_percent)"

echo "[*] Disk read (3 runs, dd 256MB)..."
DISK_R_RUNS=()
for i in 1 2 3; do
  out="$(LC_ALL=C timeout_cmd 10 dd if="$TESTFILE" of=/dev/null bs=1M count=256 2>&1 || true)"
  v="$(echo "$out" | parse_speed)"
  v="$(num "$v")"; DISK_R_RUNS+=("$v"); printf "  - read run %d: %s MB/s\n" "$i" "$v"
done
rm -f "$TESTFILE" >/dev/null 2>&1
DISK_R_MED="$(printf "%s\n" "${DISK_R_RUNS[@]}" | median)"
DISK_R_CV="$(printf "%s\n" "${DISK_R_RUNS[@]}" | cv_percent)"

# Random IOPS (short)
IOPS="0"
if has fio; then
  fio_out="$(timeout_cmd 12 fio --name=rand4k --rw=randread --bs=4k --iodepth=1 --size=128M --time_based --runtime=8s --group_reporting 2>/dev/null || true)"
  IOPS="$(echo "$fio_out" | grep -oE 'IOPS=.*' | head -1 | grep -oE '[0-9]+' | head -1)"
  IOPS="${IOPS:-0}"
fi

EST_NOTE=""
if (( $(echo "$DISK_W_MED <= 0" | bc -l) )) && (( $(echo "$DISK_R_MED <= 0" | bc -l) )) && [[ "$IOPS" =~ ^[0-9]+$ ]] && (( IOPS > 0 )); then
  DISK_W_MED="$(awk -v i="$IOPS" 'BEGIN{printf "%.2f", (i*4096)/1000000}')"  # MB/s approx from 4k IOPS
  EST_NOTE="(estimated from IOPS; dd/fio summary suppressed by hypervisor)"
fi
echo "Disk median write: $DISK_W_MED MB/s (CV ${DISK_W_CV}%) | read: $DISK_R_MED MB/s (CV ${DISK_R_CV}%) | rand IOPS: ${IOPS} $EST_NOTE"

# --------------------- Network (multi-mirror) ---------------------
echo "[*] Network (per mirror: 3 runs → median):"
MIRRORS=("http://cachefly.cachefly.net/100mb.test" "http://ipv4.download.thinkbroadband.com/100MB.zip" "https://proof.ovh.net/files/100Mb.dat")
NET_ALL=()
for u in "${MIRRORS[@]}"; do
  R=()
  for i in 1 2 3; do
    s="$(timeout_cmd 25 curl -s -o /dev/null -w '%{speed_download}' "$u" | awk '{printf "%.2f", $1/1024/1024}' || echo 0)"
    s="$(num "$s")"; R+=("$s"); NET_ALL+=("$s"); printf "  - %s run %d: %s MB/s\n" "$u" "$i" "$s"
  done
  med_u="$(printf "%s\n" "${R[@]}" | median)"
  echo "    → median: ${med_u} MB/s"
done
NET_MED="$(printf "%s\n" "${NET_ALL[@]}" | median)"
NET_BEST="$(printf "%s\n" "${NET_ALL[@]}" | awk 'BEGIN{m=0} {if($1>m)m=$1} END{print m}')"
NET_CV="$(printf "%s\n" "${NET_ALL[@]}" | cv_percent)"

LAT_MS="NA"
if has ping && [[ "$IPV4" != "N/A" ]]; then LAT_MS="$(ping -c 3 -n 1.1.1.1 2>/dev/null | awk -F'/' '/rtt/ {printf "%.1f", $5}' || echo "NA")"; fi
echo "Network median: $NET_MED MB/s | best: $NET_BEST MB/s | CV: ${NET_CV}% | ping: ${LAT_MS} ms"

# Outbound ports
echo "[*] Outbound ports..."
check_port() {
  local h="$1" p="$2"
  if has nc; then nc -z -w3 "$h" "$p" >/dev/null 2>&1 && echo ok || echo blocked
  else (exec 3<>/dev/tcp/"$h"/"$p") >/dev/null 2>&1 && echo ok || echo blocked
  fi
}
P80="$(check_port google.com 80)"; P443="$(check_port google.com 443)"
P531="$(check_port 1.1.1.1 53)"; P532="$(check_port 8.8.8.8 53)"
echo "Outbound: 80=$P80  443=$P443  53(1.1.1.1)=$P531  53(8.8.8.8)=$P532"

# --------------------- Stability (stress) ---------------------
echo "[*] Stress (10s CPU burst)..."
has stress-ng && timeout_cmd 12 stress-ng --cpu "$VCPUS" --timeout 10s >/dev/null 2>&1 || true
LOAD_AVG="$(awk '{print $1}' /proc/loadavg)"
LOAD_RATIO="$(awk -v l="$LOAD_AVG" -v c="$VCPUS" 'BEGIN{ if(c<=0){print 0}else{printf "%.2f", l/c}}')"
if (( $(echo "$LOAD_RATIO <= 0.8" | bc -l) )); then STAB_SCORE=95
elif (( $(echo "$LOAD_RATIO <= 1.2" | bc -l) )); then STAB_SCORE=80
else STAB_SCORE=60; fi
echo "Stability: load ratio $LOAD_RATIO → score $STAB_SCORE"
echo ""

# --------------------- VPN Capacity Estimator (3–4 min) ---------------------
echo "[*] VPN capacity estimation (OpenSSL crypto + network):"
# OpenSSL speed (multi-core), parse last column (usually 16384 bytes)
CHAKB="$(timeout_cmd 12 openssl speed -multi "$VCPUS" -seconds 3 chacha20-poly1305 2>/dev/null | awk '/chacha20-poly1305/ {last=$NF} END{gsub(/k/,"",last); print last+0}')"
AESKB="$(timeout_cmd 12 openssl speed -multi "$VCPUS" -seconds 3 aes-256-gcm 2>/dev/null | awk '/aes-256-gcm/ {last=$NF} END{gsub(/k/,"",last); print last+0}')"
# Convert kB/s → Mbps
CHA_Mbps="$(awk -v k="$CHAKB" 'BEGIN{printf "%.0f", (k/1024)*8}')"
AES_Mbps="$(awk -v k="$AESKB" 'BEGIN{printf "%.0f", (k/1024)*8}')"
NET_Mbps="$(awk -v m="$NET_MED" 'BEGIN{printf "%.0f", m*8}')"

# Efficiency factors (conservative):
# WireGuard (kernel, chacha) ~0.7; OpenVPN (user-space AES-GCM) ~0.5; IPsec AES-GCM ~0.8
WG_CPU_CAP="$(awk -v x="$CHA_Mbps" 'BEGIN{printf "%.0f", x*0.70}')"
OVPN_CPU_CAP="$(awk -v x="$AES_Mbps" 'BEGIN{printf "%.0f", x*0.50}')"
IPSEC_CPU_CAP="$(awk -v x="$AES_Mbps" 'BEGIN{printf "%.0f", x*0.80}')"

WG_TOTAL_Mbps="$(awk -v a="$WG_CPU_CAP" -v b="$NET_Mbps" 'BEGIN{print (a<b)?a:b}')"
OVPN_TOTAL_Mbps="$(awk -v a="$OVPN_CPU_CAP" -v b="$NET_Mbps" 'BEGIN{print (a<b)?a:b}')"
IPSEC_TOTAL_Mbps="$(awk -v a="$IPSEC_CPU_CAP" -v b="$NET_Mbps" 'BEGIN{print (a<b)?a:b}')"

# RAM headroom (70% usable)
RAM_HEAD_MB="$(awk -v r="$RAM_MB" 'BEGIN{printf "%.0f", r*0.7}')"
WG_RAM_LIMIT="$(awk -v r="$RAM_HEAD_MB" 'BEGIN{print int(r/1)}')"   # ~1 MB per peer
OVPN_RAM_LIMIT="$(awk -v r="$RAM_HEAD_MB" 'BEGIN{print int(r/5)}')" # ~5 MB per peer
IPSEC_RAM_LIMIT="$(awk -v r="$RAM_HEAD_MB" 'BEGIN{print int(r/2)}')"# ~2 MB per peer

# Users at given avg Mbps with 30% safety (÷1.3)
WG_USERS_CAP="$(awk -v cap="$WG_TOTAL_Mbps" -v pu="$PER_USER_MBPS" -v rl="$WG_RAM_LIMIT" 'BEGIN{u=int(cap/(pu*1.3)); if(u>rl)u=rl; print u}')"
OVPN_USERS_CAP="$(awk -v cap="$OVPN_TOTAL_Mbps" -v pu="$PER_USER_MBPS" -v rl="$OVPN_RAM_LIMIT" 'BEGIN{u=int(cap/(pu*1.3)); if(u>rl)u=rl; print u}')"
IPSEC_USERS_CAP="$(awk -v cap="$IPSEC_TOTAL_Mbps" -v pu="$PER_USER_MBPS" -v rl="$IPSEC_RAM_LIMIT" 'BEGIN{u=int(cap/(pu*1.3)); if(u>rl)u=rl; print u}')"

printf "%-28s %s\n" "ChaCha (OpenSSL, Mbps):" "${CHA_Mbps}"
printf "%-28s %s\n" "AES-256-GCM (Mbps):"     "${AES_Mbps}"
printf "%-28s %s\n" "Network (median, Mbps):" "${NET_Mbps}"
echo "→ Effective capacity (min of CPU & Network):"
printf "%-28s %s\n" "  WireGuard total Mbps:" "${WG_TOTAL_Mbps}"
printf "%-28s %s\n" "  OpenVPN total Mbps:"   "${OVPN_TOTAL_Mbps}"
printf "%-28s %s\n" "  IPsec total Mbps:"     "${IPSEC_TOTAL_Mbps}"
echo "→ Estimated concurrent users (@ ${PER_USER_MBPS} Mbps avg, 30% headroom, RAM-limited):"
printf "%-28s %s\n" "  WireGuard users:"      "${WG_USERS_CAP}"
printf "%-28s %s\n" "  OpenVPN users:"        "${OVPN_USERS_CAP}"
printf "%-28s %s\n" "  IPsec users:"          "${IPSEC_USERS_CAP}"
echo ""

# --------------------- Scoring & Decision (Workstation) ---------------------
CPU_N_RAW="$(awk -v e="$CPU_MED" -v c="$VCPUS" 'BEGIN{ if(c<=0)print 0; else printf "%.1f", (e/(4000*c))*100 }')"
CPU_N="$(clamp100 "$CPU_N_RAW")"
MEM_N="$(clamp100 "$(awk -v v="$MEM_MED" 'BEGIN{printf "%.1f", (v/18000)*100}')")"
BEST_DISK="$(awk -v w="$DISK_W_MED" -v r="$DISK_R_MED" 'BEGIN{if(w>=r)print w; else print r}')"
DISK_N="$(clamp100 "$(awk -v v="$BEST_DISK" 'BEGIN{printf "%.1f", (v/700)*100}')")"
NET_N="$(clamp100 "$(awk -v v="$NET_MED" 'BEGIN{printf "%.1f", (v/30)*100}')")"

POWER_SCORE="$(awk -v c="$CPU_N" -v m="$MEM_N" -v d="$DISK_N" -v n="$NET_N" -v s="$STAB_SCORE" \
'BEGIN{printf "%.1f", (0.35*c)+(0.15*m)+(0.25*d)+(0.10*n)+(0.15*s)}')"

passfail() { local x="$1" thr="$2" dir="${3:-ge}"; if [[ "$dir" == "ge" ]]; then
  (( $(echo "$x >= $thr" | bc -l) )) && echo "✅ PASS" || echo "❌ FAIL"
else
  (( $(echo "$x <= $thr" | bc -l) )) && echo "✅ PASS" || echo "❌ FAIL"
fi; }

CPU_V="$(passfail "$CPU_N_RAW" 80 ge)"
MEM_V="$(passfail "$MEM_MED" 10000 ge)"
DISK_V="$(passfail "$BEST_DISK" 300 ge)"
NET_V="$(passfail "$NET_MED" 15 ge)"
STAB_V="$(passfail "$STAB_SCORE" 80 ge)"
PORT_V=$([[ "$P80" == "ok" && "$P443" == "ok" && "$P531" == "ok" && "$P532" == "ok" ]] && echo "✅ PASS" || echo "❌ FAIL")

if (( $(echo "$POWER_SCORE >= 75" | bc -l) )) \
   && [[ "$CPU_V" == "✅ PASS" && "$MEM_V" == "✅ PASS" && "$DISK_V" == "✅ PASS" && "$NET_V" == "✅ PASS" && "$STAB_V" == "✅ PASS" && "$PORT_V" == "✅ PASS" ]]; then
  OVERALL="✅ KEEP / BUY — Suitable for long-term workstation use"
else
  OVERALL="❌ REJECT / SWITCH — Not strong or reliable enough"
fi

# --------------------- Final printed report ---------------------
echo "=================== FINAL DECISION REPORT ==================="
printf "%-26s %s\n" "CPU median:" "$CPU_MED e/s  | per-core eff $CPU_PERCORE_EFF% | CV ${CPU_CV}%  → $CPU_V"
printf "%-26s %s\n" "Memory median:" "$MEM_MED MiB/s | CV ${MEM_CV}%  → $MEM_V"
printf "%-26s %s\n" "Disk write (med):" "$DISK_W_MED MB/s | CV ${DISK_W_CV}%"
printf "%-26s %s\n" "Disk read (med):"  "$DISK_R_MED MB/s | CV ${DISK_R_CV}%"
printf "%-26s %s\n" "Best disk for score:" "$BEST_DISK MB/s  → $DISK_V"
printf "%-26s %s\n" "Rand IOPS 4k:" "${IOPS}"
printf "%-26s %s\n" "Network median:" "$NET_MED MB/s | best $NET_BEST | CV ${NET_CV}% | ping ${LAT_MS} ms  → $NET_V"
printf "%-26s %s\n" "Outbound ports:" "80=$P80  443=$P443  53(1.1.1.1)=$P531  53(8.8.8.8)=$P532  → $PORT_V"
printf "%-26s %s\n" "Stability:" "load ratio $LOAD_RATIO  → score $STAB_SCORE  → $STAB_V"
echo "--------------------------------------------------------------"
printf "%-26s %s\n" "Power Score:" "$POWER_SCORE / 100"
printf "%-26s %s\n" "Overall:" "$OVERALL"
printf "%-26s %s\n" "IPv4 / IPv6:" "$IPV4  /  $IPV6"
printf "%-26s %s\n" "Geo:" "$GEO_INFO"
echo "------------------- VPN Capacity (est.) ---------------------"
printf "%-26s %s\n" "WireGuard total Mbps:" "$WG_TOTAL_Mbps"
printf "%-26s %s\n" "OpenVPN total Mbps:"   "$OVPN_TOTAL_Mbps"
printf "%-26s %s\n" "IPsec total Mbps:"     "$IPSEC_TOTAL_Mbps"
printf "%-26s %s\n" "Users @${PER_USER_MBPS} Mbps:" "WG=$WG_USERS_CAP  |  OVPN=$OVPN_USERS_CAP  |  IPsec=$IPSEC_USERS_CAP"
REQ_USERS="$VPN_USERS"
WG_OK=$([[ $WG_USERS_CAP -ge $REQ_USERS ]] && echo "✅" || echo "❌")
OVPN_OK=$([[ $OVPN_USERS_CAP -ge $REQ_USERS ]] && echo "✅" || echo "❌")
IPSEC_OK=$([[ $IPSEC_USERS_CAP -ge $REQ_USERS ]] && echo "✅" || echo "❌")
printf "%-26s %s\n" "Target users:" "$REQ_USERS → WG $WG_OK  |  OVPN $OVPN_OK  |  IPsec $IPSEC_OK"
echo "=============================================================="
