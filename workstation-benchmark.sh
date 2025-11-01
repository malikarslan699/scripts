#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

AUTO_YES=false
QUICK=false

# ---------- UI ----------
ok(){ echo -e "\033[1;32m[OK]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
info(){ echo -e "\033[1;34m[INFO]\033[0m $*"; }

ask(){
  local m=${1:-Proceed?}
  if $AUTO_YES || [[ -n "${ASSUME_YES:-}" ]] || [[ -n "${YES:-}" ]] || [[ ! -t 0 ]]; then
    info "$m [auto-yes]"
    return 0
  fi
  read -r -p "$m [Y/n]: " r || true; r=${r:-Y}; [[ $r =~ ^[Yy]$ ]]
}

parse_args(){
  for a in "$@"; do
    case "$a" in
      -y|--yes) AUTO_YES=true;;
      --quick) QUICK=true;;
      -h|--help)
        cat <<H
Usage: sudo ./workstation-benchmark.sh [--yes] [--quick]
- Default: single-run accurate (3 rounds/median per metric)
- --quick: 1 round, smaller payload (fast screen)
Creates: vps-benchmark-report.txt, vps-report-<hostname>.md, vps-report-<hostname>.json
H
        exit 0;;
      *) warn "Unknown option: $a";;
    esac
  done
}

# ---------- Packages (Ubuntu/Debian) ----------
wait_for_apt(){ local t=30; while ((t--)); do
  fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || return 0; sleep 1
done; }
ensure_tools(){
  info "Installing tools (curl, jq, sysbench, iproute2)"
  wait_for_apt || true
  apt-get update -y >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl jq sysbench iproute2 >/dev/null 2>&1 || true
}

# ---------- Helpers ----------
fmt_mb_gb_tb(){ # input MB -> MB/GB/TB
  local mb; mb=$(printf '%.2f' "${1:-0}")
  awk -v mb="$mb" 'BEGIN{
    if (mb<1024) {printf("%.0f MB", mb); exit}
    gb=mb/1024.0
    if (gb<1024) {printf("%.1f GB", gb); exit}
    printf("%.2f TB", gb/1024.0)
  }'
}
fmt_mb_gb(){ # MB -> MB/GB
  local mb; mb=$(printf '%.2f' "${1:-0}")
  awk -v mb="$mb" 'BEGIN{ if (mb<1024) printf("%.0f MB", mb); else printf("%.1f GB", mb/1024.0) }'
}
median_stdin(){ sort -n | awk '{a[NR]=$1} END{ if(NR==0){print 0; exit} if (NR%2) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2 }'; }
min_stdin(){ sort -n | head -n1; }
max_stdin(){ sort -n | tail -n1; }

get_hostname(){ hostname; }
get_public_ip(){ curl -fsS ifconfig.me || echo "unknown"; }
get_geo(){ curl -fsS https://ipinfo.io 2>/dev/null | jq -r '"\(.city // "?"), \(.region // "?"), \(.country // "?")"' | sed 's/^null.*$/unknown/'; }
get_virt(){ (systemd-detect-virt 2>/dev/null || echo unknown); }
get_os(){ . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}"; }
get_kernel(){ uname -r; }
get_cpu(){ lscpu | awk -F: '/Model name/{gsub(/^ +/,"",$2); print $2; exit}'; }
get_vcpu(){ nproc; }
get_uptime(){ uptime -p 2>/dev/null || echo "unknown"; }
get_mem_mb(){ free -m | awk '/Mem:/{print $2" "$7}'; }
get_disk_b(){ df -B1 / | awk 'NR==2{print $2" "$4}'; }
load_ratio(){ local l=$(awk '{print $1}' /proc/loadavg); local v=$(nproc); awk -v l="$l" -v v="$v" 'BEGIN{ if(v==0){print 0}else printf("%.2f", l/v)}'; }

# ---------- Ports ----------
tcp_check(){ local h=$1 p=$2; timeout 2 bash -c "</dev/tcp/$h/$p" >/dev/null 2>&1 && echo ok || echo blocked; }

# ---------- HTTP mirrors ----------
http_round(){ local url=$1 max_time=$2 range=$3; curl --max-time "$max_time" -L $range -o /dev/null -s -w "%{speed_download}\n" "$url" 2>/dev/null || echo 0; }
http_suite(){
  local quick=$1; local max_time range; if $quick; then max_time=8; range='-r 0-10485759'; else max_time=12; range='-r 0-20971519'; fi
  local urls=( "http://cachefly.cachefly.net/100mb.test" "http://ipv4.download.thinkbroadband.com/100MB.zip" "http://proof.ovh.net/files/100Mb.dat" "http://speedtest.tele2.net/100MB.zip" "http://speed.hetzner.de/100MB.bin" )
  : > /tmp/_http_summary.txt
  for u in "${urls[@]}"; do
    local Rounds=3; $quick && Rounds=1
    : > /tmp/_one.tmp
    for _ in $(seq 1 $Rounds); do http_round "$u" "$max_time" "$range" >> /tmp/_one.tmp; done
    awk '{print $1/1000000}' /tmp/_one.tmp > /tmp/_one_mb.tmp
    local med=$(cat /tmp/_one_mb.tmp | median_stdin)
    local mn=$(cat /tmp/_one_mb.tmp | min_stdin)
    local mx=$(cat /tmp/_one_mb.tmp | max_stdin)
    printf "url=%s median=%.2fMB/s min=%.2f max=%.2f\n" "$u" "$med" "$mn" "$mx" | tee -a /tmp/_http_summary.txt >/dev/null
  done
}

# ---------- sysbench suites ----------
cpu_suite(){ local secs=10; $QUICK && secs=3; local Rounds=3; $QUICK && Rounds=1; : > /tmp/_cpu_eps.txt
  for _ in $(seq 1 $Rounds); do sysbench cpu --cpu-max-prime=20000 --threads=$(nproc) --time="$secs" run | awk -F: '/events per second/{gsub(/^[ \t]+/,"",$2); print $2}' >> /tmp/_cpu_eps.txt; done
  awk '{print $1}' /tmp/_cpu_eps.txt | median_stdin; }
mem_suite(){ local total=2G; $QUICK && total=256M; local Rounds=3; $QUICK && Rounds=1; : > /tmp/_mem_rate.txt
  for _ in $(seq 1 $Rounds); do sysbench memory --memory-total-size="$total" --memory-block-size=1M --threads=$(nproc) run | awk '{if ($0 ~ /MiB transferred/){ if (match($0, /\(([0-9.]+) MiB\/sec\)/, m)) print m[1]; }}' >> /tmp/_mem_rate.txt; done
  awk '{print $1}' /tmp/_mem_rate.txt | median_stdin; }
disk_suite(){ local MiB=1024; $QUICK && MiB=256; local Rounds=3; $QUICK && Rounds=1; : > /tmp/_disk_rate.txt
  for _ in $(seq 1 $Rounds); do sync; dd if=/dev/zero of=/tmp/io.test bs=1M count="$MiB" oflag=direct status=none 2> /tmp/_dd.tmp || true; sync
    awk -F, '/copied/ {gsub(/^ +/,"",$3); print $3}' /tmp/_dd.tmp | awk '{print $1}' >> /tmp/_disk_rate.txt; rm -f /tmp/io.test >/dev/null 2>&1 || true; done
  awk '{print $1}' /tmp/_disk_rate.txt | median_stdin; }

# ---------- Ratings ----------
rate_cpu(){ local v=$1; if (( $(printf '%.0f' "$v") > 8000 )); then echo Excellent; elif (( $(printf '%.0f' "$v") >= 5000 )); then echo Good; elif (( $(printf '%.0f' "$v") >= 2500 )); then echo Fair; else echo Poor; fi; }
rate_mem(){ local v=$1; if (( $(printf '%.0f' "$v") > 20000 )); then echo Excellent; elif (( $(printf '%.0f' "$v") >= 10000 )); then echo Good; elif (( $(printf '%.0f' "$v") >= 5000 )); then echo Fair; else echo Poor; fi; }
rate_disk(){ local v=$1; if (( $(printf '%.0f' "$v") > 500 )); then echo Excellent; elif (( $(printf '%.0f' "$v") >= 300 )); then echo Good; elif (( $(printf '%.0f' "$v") >= 100 )); then echo Fair; else echo Poor; fi; }
rate_net(){ local v=$1; if (( $(printf '%.0f' "$v") > 20 )); then echo Excellent; elif (( $(printf '%.0f' "$v") >= 10 )); then echo Good; elif (( $(printf '%.0f' "$v") >= 5 )); then echo Fair; else echo Poor; fi; }
rate_multi(){ local r=$1; awk -v x="$r" 'BEGIN{ if (x<=0.50) print "Excellent"; else if (x<=0.90) print "Good"; else if (x<=1.20) print "Moderate"; else print "Poor" }'; }
score_map(){ case "$1" in Excellent) echo 100;; Good) echo 80;; Fair) echo 60;; Moderate) echo 60;; Poor) echo 40;; *) echo 60;; esac; }
overall_score(){ awk -v a="$1" -v b="$2" -v c="$3" -v d="$4" -v e="$5" 'BEGIN{printf("%.0f", a*0.25 + b*0.20 + c*0.20 + d*0.20 + e*0.15)}'; }
overall_label(){ local s=$1; if (( s>=90 )); then echo EXCELLENT; elif (( s>=75 )); then echo GOOD; elif (( s>=60 )); then echo FAIR; else echo POOR; fi; }

# ---------- Summary/Export ----------
summaries(){
  local HN="$1" IP="$2" LOC="$3" OSN="$4" KRN="$5" VIRT="$6" CPU="$7" VCPU="$8" UPT="$9" DATE="${10}"
  local RAM_T_MB="${11}" RAM_A_MB="${12}" DISK_T_B="${13}" DISK_F_B="${14}"
  local CPU_MED="${15}" MEM_MED="${16}" DISK_MED="${17}" LOAD_RATIO="${18}"
  local HTTP_SUMMARY="${19}" NET_MED="${20}" NET_BEST="${21}" P80="${22}" P443="${23}" P53A="${24}" P53B="${25}"

  local RAM_T=$(fmt_mb_gb_tb "$RAM_T_MB"); local RAM_A=$(fmt_mb_gb_tb "$RAM_A_MB")
  local DISK_T_MB=$(awk -v b="$DISK_T_B" 'BEGIN{print b/1048576}')
  local DISK_F_MB=$(awk -v b="$DISK_F_B" 'BEGIN{print b/1048576}')
  local DISK_T=$(fmt_mb_gb_tb "$DISK_T_MB"); local DISK_F=$(fmt_mb_gb_tb "$DISK_F_MB")

  local CPU_RATE=$(rate_cpu "$CPU_MED"); local MEM_RATE=$(rate_mem "$MEM_MED"); local DISK_RATE=$(rate_disk "$DISK_MED")
  local NET_RATE=$(rate_net "$NET_MED"); local MULTI_RATE=$(rate_multi "$LOAD_RATIO")

  local SCPU=$(score_map "$CPU_RATE"); local SMEM=$(score_map "$MEM_RATE"); local SDISK=$(score_map "$DISK_RATE")
  local SNET=$(score_map "$NET_RATE"); local SMT=$(score_map "$MULTI_RATE")
  local OVR=$(overall_score "$SCPU" "$SMEM" "$SDISK" "$SNET" "$SMT"); local OLAB=$(overall_label "$OVR")

  # Connectivity score (safe with set -u)
  local CONN_CNT=0
  [[ "${P80:-blocked}"  == "ok" ]] && CONN_CNT=$((CONN_CNT+1))
  [[ "${P443:-blocked}" == "ok" ]] && CONN_CNT=$((CONN_CNT+1))
  [[ "${P53A:-blocked}" == "ok" ]] && CONN_CNT=$((CONN_CNT+1))
  [[ "${P53B:-blocked}" == "ok" ]] && CONN_CNT=$((CONN_CNT+1))
  local CONN_RATE; CONN_RATE=$(awk -v c="$CONN_CNT" 'BEGIN{printf("%.0f", (c/4)*100)}')

  # Plain text
  cat > "vps-benchmark-report.txt" <<TXT
===================== VPS PERFORMANCE REPORT =====================
Host: $HN
Public IP: $IP
Datacenter: $LOC
OS: $OSN | Kernel: $KRN | Virt: $VIRT
CPU: $CPU ($VCPU vCPU) | RAM: $RAM_T (avail $RAM_A) | Disk: $DISK_T (free $DISK_F)
Uptime: $UPT | Timestamp: $DATE

Performance:
- CPU: ${CPU_MED} events/sec => $CPU_RATE
- Memory: ${MEM_MED} MiB/sec => $MEM_RATE
- Disk Write: ${DISK_MED} MB/s => $DISK_RATE
- Multitasking (load/vCPU): $LOAD_RATIO => $MULTI_RATE

Network (HTTP mirrors, medians):
$HTTP_SUMMARY
- Network median: ${NET_MED} MB/s  | best: ${NET_BEST} MB/s => $NET_RATE
- Outbound ports: 80=$P80  443=$P443  53(1.1.1.1)=$P53A  53(8.8.8.8)=$P53B  (Connectivity ${CONN_RATE}%)

Overall: $OLAB (score $OVR)
==============================================================
TXT

  # Markdown
  cat > "vps-report-${HN}.md" <<MD
## VPS Performance Report

- **Host**: \`$HN\`
- **Public IP**: \`$IP\`
- **Datacenter**: \`$LOC\`
- **OS**: \`$OSN\` | **Kernel**: \`$KRN\` | **Virt**: \`$VIRT\`
- **CPU**: \`$CPU\` (\`$VCPU\` vCPU)
- **RAM**: \`$RAM_T\` (avail \`$RAM_A\`)
- **Disk**: \`$DISK_T\` (free \`$DISK_F\`)
- **Uptime**: \`$UPT\`
- **Timestamp**: \`$DATE\`

### Performance
- **CPU**: \`${CPU_MED} events/sec\` → **$CPU_RATE**
- **Memory**: \`${MEM_MED} MiB/sec\` → **$MEM_RATE**
- **Disk Write**: \`${DISK_MED} MB/s\` → **$DISK_RATE**
- **Multitasking (load/vCPU)**: \`${LOAD_RATIO}\` → **$MULTI_RATE**

### Network
- HTTP mirrors (median/min/max):
\`\`\`
$HTTP_SUMMARY
\`\`\`
- Network median: \`${NET_MED} MB/s\`, best: \`${NET_BEST} MB/s\` → **$NET_RATE**
- Outbound ports: \`80=$P80\`, \`443=$P443\`, \`53(1.1.1.1)=$P53A\`, \`53(8.8.8.8)=$P53B\` (Connectivity ${CONN_RATE}%)

### Overall
- **Score**: \`$OVR\` → **$OLAB**
MD

  # JSON
  jq -n --arg host "$HN" --arg ip "$IP" --arg loc "$LOC" \
    --arg os "$OSN" --arg kernel "$KRN" --arg virt "$VIRT" \
    --arg cpu_model "$CPU" --arg vcpu "$VCPU" --arg uptime "$UPT" --arg ts "$DATE" \
    --arg ram_total_mb "$RAM_T_MB" --arg ram_avail_mb "$RAM_A_MB" \
    --arg disk_total_b "$DISK_T_B" --arg disk_free_b "$DISK_F_B" \
    --arg cpu_eps "$CPU_MED" --arg mem_mibs "$MEM_MED" --arg disk_mb_s "$DISK_MED" \
    --arg load_ratio "$LOAD_RATIO" \
    --arg http_summary "$HTTP_SUMMARY" --arg net_median "$NET_MED" --arg net_best "$NET_BEST" \
    --arg p80 "$P80" --arg p443 "$P443" --arg p53a "$P53A" --arg p53b "$P53B" \
    --arg cpu_rate "$CPU_RATE" --arg mem_rate "$MEM_RATE" --arg disk_rate "$DISK_RATE" \
    --arg net_rate "$NET_RATE" --arg multi_rate "$MULTI_RATE" \
    --arg overall "$OLAB" --arg overall_score "$OVR" \
    '{server:{host:$host,ip:$ip,location:$loc,os:$os,kernel:$kernel,virt:$virt,cpu:$cpu_model,vcpu:($vcpu|tonumber),uptime:$uptime,timestamp:$ts},
      resources:{ram_mb:{total:($ram_total_mb|tonumber),available:($ram_avail_mb|tonumber)},
                 disk_b:{total:($disk_total_b|tonumber),free:($disk_free_b|tonumber)}},
      performance:{cpu_eps:($cpu_eps|tonumber),mem_mib_s:($mem_mibs|tonumber),disk_mb_s:($disk_mb_s|tonumber),load_ratio:($load_ratio|tonumber)},
      network:{http_summary:$http_summary,median_mb_s:($net_median|tonumber),best_mb_s:($net_best|tonumber),
               ports:{http:$p80,https:$p443,dns1:$p53a,dns2:$p53b}},
      ratings:{cpu:$cpu_rate,memory:$mem_rate,disk:$disk_rate,network:$net_rate,multitasking:$multi_rate},
      overall:{label:$overall,score:($overall_score|tonumber)}}' > "vps-report-${HN}.json"

  ok "Reports written: vps-benchmark-report.txt, vps-report-${HN}.md, vps-report-${HN}.json"
  # Auto-print the plain-text report
  echo
  cat vps-benchmark-report.txt
}

main(){
  parse_args "$@"
  ask "Run standardized VPS benchmark now?" || { warn "Aborted"; exit 0; }
  ask "This installs curl/jq/sysbench/iproute2. Proceed?" || { warn "Aborted"; exit 0; }
  ensure_tools

  HN=$(get_hostname)
  IP=$(get_public_ip)
  LOC=$(get_geo)
  OSN=$(get_os)
  KRN=$(get_kernel)
  VIRT=$(get_virt)
  CPU_MODEL=$(get_cpu)
  VCPU=$(get_vcpu)
  UPT=$(get_uptime)
  DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  read -r RAM_T_MB RAM_A_MB < <(get_mem_mb)
  read -r DISK_T_B DISK_F_B < <(get_disk_b)

  CPU_MED=$(cpu_suite)
  MEM_MED=$(mem_suite)
  DISK_MED=$(disk_suite)
  LOADR=$(load_ratio)

  http_suite $QUICK
  HTTP_SUMMARY=$(cat /tmp/_http_summary.txt)
  MEDS=$(awk -F'median=' '{if(NF>1){split($2,a,"MB/s"); gsub(/ /,"",a[1]); print a[1]}}' /tmp/_http_summary.txt | awk '$1>0')
  if [[ -n "${MEDS}" ]]; then
    NET_MED=$(printf "%s\n" $MEDS | median_stdin)
    NET_BEST=$(printf "%s\n" $MEDS | max_stdin)
  else
    NET_MED=0; NET_BEST=0
  fi

  P80=$(tcp_check google.com 80)
  P443=$(tcp_check google.com 443)
  P53A=$(tcp_check 1.1.1.1 53)
  P53B=$(tcp_check 8.8.8.8 53)

  summaries "$HN" "$IP" "$LOC" "$OSN" "$KRN" "$VIRT" "$CPU_MODEL" "$VCPU" "$UPT" "$DATE" \
            "$RAM_T_MB" "$RAM_A_MB" "$DISK_T_B" "$DISK_F_B" \
            "$CPU_MED" "$MEM_MED" "$DISK_MED" "$LOADR" \
            "$HTTP_SUMMARY" "$NET_MED" "$NET_BEST" "$P80" "$P443" "$P53A" "$P53B"
}

main "$@"
