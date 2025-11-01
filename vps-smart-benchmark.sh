#!/usr/bin/env bash
# vps-smart-benchmark.sh
# Run as root (recommended) or user with sudo.
# Produces Markdown and JSON reports with unit conversion and ratings.

set -euo pipefail
IFS=$'\n\t'

########## Configuration ##########
# Mirrors to test download speed from (multiple geographic mirrors)
MIRRORS=(
  "http://cachefly.cachefly.net/100mb.test"
  "http://ipv4.download.thinkbroadband.com/100MB.zip"
  "https://proof.ovh.net/files/100Mb.dat"
  "http://speedtest.tele2.net/100MB.zip"
  "http://speed.hetzner.de/100MB.bin"
)

# Destinations for port checks (host:port)
PORT_CHECKS=(
  "google.com:80"
  "google.com:443"
  "1.1.1.1:53"
  "8.8.8.8:53"
)

# Disk test file (in /tmp, auto removed)
DISK_TEST_FILE="/tmp/vpsbench_dd_test_file"

# sysbench test durations (short quick tests)
SYSBENCH_CPU_TIME=3   # seconds for CPU test (quick)
SYSBENCH_MEM_BLOCK=16 # block size KB for memory test (sysbench legacy compatibility)
SYSBENCH_MEM_TOTAL=256  # MiB for memory test

# Output locations
HOSTNAME="$(hostname -s)"
TIMESTAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_MD="/tmp/vps-benchmark-${HOSTNAME}-${TIMESTAMP}.md"
OUT_JSON="/tmp/vps-benchmark-${HOSTNAME}-${TIMESTAMP}.json"

########## Helpers ##########
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Safe run of a command, capturing output and returning non-zero not fatal
try_cmd() {
  local out
  if out="$("$@" 2>&1)"; then
    echo "$out"
    return 0
  else
    echo "$out"
    return 1
  fi
}

# Unit conversion: input in MB. Output string with MB/GB/TB and numeric value in that unit.
convert_size() {
  # $1 = size in MB (integer or float)
  local mb="$1"
  # Use awk for float math
  if awk "BEGIN{exit !($mb >= 1024*1024)}"; then
    # >= 1024 GB -> TB
    printf "%.2f TB" "$(awk "BEGIN{printf %f, $mb/1024/1024}")"
  elif awk "BEGIN{exit !($mb >= 1024)}"; then
    # >= 1024 MB -> GB
    printf "%.2f GB" "$(awk "BEGIN{printf %f, $mb/1024}")"
  else
    printf "%.0f MB" "$(awk "BEGIN{printf %f, $mb}")"
  fi
}

# Rating thresholds (numerical thresholds as in spec)
rate_cpu() {
  # events/sec
  local v="$1"
  awk -v v="$v" 'BEGIN{
    if(v > 8000) print "Excellent";
    else if(v >= 5000) print "Good";
    else if(v >= 2500) print "Fair";
    else print "Poor";
  }'
}
rate_mem() {
  # MiB/sec
  local v="$1"
  awk -v v="$v" 'BEGIN{
    if(v > 20000) print "Excellent";
    else if(v >= 10000) print "Good";
    else if(v >= 5000) print "Fair";
    else print "Poor";
  }'
}
rate_disk() {
  # MB/s
  local v="$1"
  awk -v v="$v" 'BEGIN{
    if(v > 500) print "Excellent";
    else if(v >= 300) print "Good";
    else if(v >= 100) print "Fair";
    else print "Poor";
  }'
}
rate_net() {
  # MB/s avg
  local v="$1"
  awk -v v="$v" 'BEGIN{
    if(v > 20) print "Excellent";
    else if(v >= 10) print "Good";
    else if(v >= 5) print "Fair";
    else print "Poor";
  }'
}
rate_multitask() {
  # ratio = load_avg / vcpu
  local r="$1"
  awk -v r="$r" 'BEGIN{
    if(r <= 0.5) print "Excellent";
    else if(r <= 0.9) print "Good";
    else if(r <= 1.2) print "Moderate";
    else print "Poor";
  }'
}

# numeric conversion helpers
to_number() {
  # remove trailing non-numeric
  echo "$1" | awk '{gsub(/[^0-9.]/,""); if($0=="") print "0"; else print $0}'
}

echo "[*] Collecting system info..."
OS_INFO="$(try_cmd lsb_release -ds || try_cmd cat /etc/os-release || echo "unknown")"
KERNEL="$(uname -r || echo "unknown")"
VIRT_TYPE="$(try_cmd systemd-detect-virt || echo "unknown")"
CPU_MODEL="$(try_cmd lscpu | awk -F: '/Model name|Model/ {print $2; exit}' || echo "unknown")"
CPU_COUNT="$(try_cmd nproc || echo "0")"
RAM_MB="$(free -m | awk '/Mem:/ {print $2}' 2>/dev/null || echo "0")"
DISK_TOTAL_KB="$(df --output=size -k / | sed -n 2p 2>/dev/null || echo "0")"
DISK_TOTAL_MB="$(awk "BEGIN { printf \"%.0f\", ${DISK_TOTAL_KB}/1024 }")"
UPTIME_STR="$(uptime -p || echo "unknown")"
PUBLIC_IP="$(try_cmd curl -s --max-time 5 ifconfig.me || try_cmd curl -s --max-time 5 ipinfo.io/ip || echo "unknown")"

# Normalize CPU model whitespace
CPU_MODEL="$(echo "$CPU_MODEL" | sed -E 's/^[ \t]+//;s/[ \t]+$//')"

########## CPU Bench (sysbench or fallback) ##########
CPU_EVENTS="N/A"
if command_exists sysbench; then
  echo "[*] Running sysbench CPU test (${SYSBENCH_CPU_TIME}s)..."
  # try old and new CLI variants (sysbench 1.x vs 0.4)
  if sysbench --version 2>/dev/null | grep -qE '^0\.'; then
    # legacy
    CPU_OUTPUT="$(try_cmd sysbench --test=cpu --cpu-max-prime=20000 run 2>&1 | tee /tmp/.vps_cpu_out || true)"
    CPU_EVENTS="$(echo "$CPU_OUTPUT" | awk -F: '/events per second/ {gsub(/ /,""); print $2; exit}')"
  else
    # sysbench >=1.0
    # run a quick cpu test with time
    CPU_OUTPUT="$(try_cmd sysbench cpu --time="$SYSBENCH_CPU_TIME" run 2>&1 || true)"
    CPU_EVENTS="$(echo "$CPU_OUTPUT" | awk -F: '/events per second/ {gsub(/ /,""); print $2; exit}')"
    # fallback if different label:
    if [ -z "$CPU_EVENTS" ]; then
      CPU_EVENTS="$(echo "$CPU_OUTPUT" | awk '/events\:/ {print $(NF)}' | head -n1 || true)"
    fi
  fi
  CPU_EVENTS="$(to_number "$CPU_EVENTS")"
else
  echo "[!] sysbench not installed. Skipping CPU detailed test."
  CPU_EVENTS="0"
fi

########## Memory Bench (sysbench) ##########
MEM_MBPS="N/A"
if command_exists sysbench; then
  echo "[*] Running sysbench memory test (${SYSBENCH_MEM_TOTAL} MiB, quick)..."
  if sysbench --version 2>/dev/null | grep -qE '^0\.'; then
    MEM_OUTPUT="$(try_cmd sysbench --test=memory --memory-total-size=${SYSBENCH_MEM_TOTAL}M run || true)"
    MEM_MBPS="$(echo "$MEM_OUTPUT" | awk -F: '/transferred/ {print $2; exit}' || true)"
  else
    MEM_OUTPUT="$(try_cmd sysbench memory --memory-total-size=${SYSBENCH_MEM_TOTAL}M --time=3 run || true)"
    MEM_MBPS="$(echo "$MEM_OUTPUT" | awk -F: '/MiB\/s/ {print $2; exit}' || true)"
    # fallback search
    if [ -z "$MEM_MBPS" ]; then
      MEM_MBPS="$(echo "$MEM_OUTPUT" | awk '/transferred|MiB/' | tail -n1 | sed -E 's/.* ([0-9.]+) MiB.*/\1/; s/.*:\s*([0-9.]+)/\1/')"
    fi
  fi
  MEM_MBPS="$(to_number "$MEM_MBPS")"
else
  echo "[!] sysbench not installed. Skipping memory detailed test."
  MEM_MBPS="0"
fi

########## Disk Write Test (dd) ##########
echo "[*] Running disk write test (256 MiB direct write)..."
# Use dd with oflag=direct if possible; fallback to buffered
DD_SIZE_MB=256
rm -f "$DISK_TEST_FILE" 2>/dev/null || true
set +e
if dd --version >/dev/null 2>&1; then
  dd_out=$( (time dd if=/dev/zero of="$DISK_TEST_FILE" bs=1M count=$DD_SIZE_MB oflag=direct conv=fdatasync) 2>&1 )
  status=$?
  if [ $status -ne 0 ]; then
    # try without direct
    dd_out=$( (time dd if=/dev/zero of="$DISK_TEST_FILE" bs=1M count=$DD_SIZE_MB conv=fdatasync) 2>&1 ) || true
  fi
else
  dd_out="dd not available"
fi
set -e
# parse dd MB/s from dd_out: look for bytes/sec or copied and time
DISK_MBPS="$(echo "$dd_out" | awk -F, '/copied/ {for(i=1;i<=NF;i++){ if($i ~ /copied/) {print $(i+1)} }}' | head -n1 | sed -E 's/.* ([0-9.]+) MB\/s.*/\1/; s/.* ([0-9.]+) bytes\/s.*/\1/' || true)"
# fallback: attempt to parse "s" and "bytes"
if [ -z "$DISK_MBPS" ]; then
  # try extracting speed like "X MB/s"
  DISK_MBPS="$(echo "$dd_out" | tr '\n' ' ' | sed -E 's/.* ([0-9.]+) MB\/s.*/\1/; s/.* ([0-9.]+) bytes\/s.*/\1/' || true)"
fi
DISK_MBPS="$(to_number "$DISK_MBPS")"
# remove test file
rm -f "$DISK_TEST_FILE" 2>/dev/null || true

########## Network HTTP Download Tests ##########
echo "[*] Testing download speeds from mirrors..."
MIRROR_RESULTS=()
TOTAL_NET_MBPS=0
COUNT_NET=0
for url in "${MIRRORS[@]}"; do
  # Use curl to measure speed_download
  # silent, write to /dev/null, with max time
  speed_output="$(try_cmd curl -s -L --max-time 30 -w '%{speed_download}\n' -o /dev/null "$url" || echo "0")"
  speed_bps="$(to_number "$speed_output")" # bytes/sec
  # convert to MB/s
  speed_mbps="$(awk "BEGIN{printf \"%.3f\", $speed_bps/1024/1024}")"
  # time estimation: if speed 0 then failed
  if awk "BEGIN{exit !($speed_mbps > 0)}"; then
    mirr_label="$(echo "$url" | awk -F/ '{print $3}')"
    MIRROR_RESULTS+=("$mirr_label|$speed_mbps")
    TOTAL_NET_MBPS="$(awk "BEGIN{printf \"%.6f\", $TOTAL_NET_MBPS + $speed_mbps}")"
    COUNT_NET=$((COUNT_NET+1))
  else
    mirr_label="$(echo "$url" | awk -F/ '{print $3}')"
    MIRROR_RESULTS+=("$mirr_label|0")
  fi
done

if [ "$COUNT_NET" -gt 0 ]; then
  AVG_NET_MBPS="$(awk "BEGIN{printf \"%.3f\", $TOTAL_NET_MBPS / $COUNT_NET}")"
else
  AVG_NET_MBPS=0
fi

########## Outbound Port Checks ##########
echo "[*] Checking outbound ports..."
PORT_RESULTS=()
for hp in "${PORT_CHECKS[@]}"; do
  host="${hp%%:*}"
  port="${hp##*:}"
  ok=0
  # Try nc if available
  if command_exists nc; then
    if nc -z -w 3 "$host" "$port" >/dev/null 2>&1; then ok=1; fi
  else
    # Try bash /dev/tcp fallback
    (exec 3<>/dev/tcp/"$host"/"$port") >/dev/null 2>&1 && ok=1 || ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    PORT_RESULTS+=("$host:$port|OK")
  else
    PORT_RESULTS+=("$host:$port|BLOCKED")
  fi
done

########## Listening Services (top) ##########
echo "[*] Capturing listening services (ss)..."
LISTENING="$(try_cmd ss -tulnp 2>/dev/null | head -n 200 || try_cmd netstat -tulnp || echo "ss/netstat not available")"

########## Multitasking / Load ##########
LOAD_AVG="$(cat /proc/loadavg | awk '{print $1}')"
# compute ratio = load_avg / vcpu_count
if awk "BEGIN{exit !($CPU_COUNT > 0)}"; then
  LOAD_RATIO="$(awk -v la="$LOAD_AVG" -v v="$CPU_COUNT" 'BEGIN{printf "%.3f", la / v}')"
else
  LOAD_RATIO=0
fi

########## Ratings ##########
CPU_RATING="$(rate_cpu "$CPU_EVENTS")"
MEM_RATING="$(rate_mem "$MEM_MBPS")"
DISK_RATING="$(rate_disk "$DISK_MBPS")"
NET_RATING="$(rate_net "$AVG_NET_MBPS")"
MULTI_RATING="$(rate_multitask "$LOAD_RATIO")"

########## Overall Score (weighted) ##########
# Map textual rating to numeric
map_rating_num() {
  case "$1" in
    Excellent) echo 100 ;;
    Good) echo 80 ;;
    Moderate) echo 60 ;; # used for multitasking "Moderate"
    Fair) echo 60 ;;
    Poor) echo 40 ;;
    *) echo 0 ;;
  esac
}
CPU_NUM=$(map_rating_num "$CPU_RATING")
MEM_NUM=$(map_rating_num "$MEM_RATING")
DISK_NUM=$(map_rating_num "$DISK_RATING")
NET_NUM=$(map_rating_num "$NET_RATING")
MULTI_NUM=$(map_rating_num "$MULTI_RATING")

# Weighted sum: CPU 25%, Memory 20%, Disk 20%, Network 20%, Multitasking 15%
OVERALL_SCORE=$(awk -v c="$CPU_NUM" -v m="$MEM_NUM" -v d="$DISK_NUM" -v n="$NET_NUM" -v t="$MULTI_NUM" 'BEGIN{printf "%.1f", c*0.25 + m*0.20 + d*0.20 + n*0.20 + t*0.15}')
# map numeric overall to textual
if awk "BEGIN{exit !($OVERALL_SCORE >= 90)}"; then OVERALL_TEXT="Excellent"
elif awk "BEGIN{exit !($OVERALL_SCORE >= 75)}"; then OVERALL_TEXT="Good"
elif awk "BEGIN{exit !($OVERALL_SCORE >= 55)}"; then OVERALL_TEXT="Fair"
else OVERALL_TEXT="Poor"
fi

########## Prepare outputs ##########
echo "[*] Preparing report files..."
RAM_DISPLAY="$(convert_size "$RAM_MB")"
DISK_DISPLAY="$(convert_size "$DISK_TOTAL_MB")"

# Build Mirror table string
MIRROR_TABLE=""
for m in "${MIRROR_RESULTS[@]}"; do
  label="${m%%|*}"
  spd="${m##*|}"
  MIRROR_TABLE+="- ${label}: ${spd} MB/s\n"
done

# Build port table string
PORT_TABLE=""
for p in "${PORT_RESULTS[@]}"; do
  hp="${p%%|*}"
  st="${p##*|}"
  PORT_TABLE+="- ${hp} → ${st}\n"
done

# Listening snippet (first 20 lines)
LISTEN_SNIPPET="$(echo "$LISTENING" | sed -n '1,20p')"

# Markdown report
cat > "$OUT_MD" <<EOF
# VPS PERFORMANCE REPORT
**Host:** ${HOSTNAME}  
**Public IP:** ${PUBLIC_IP}  
**Datacenter / Virtualization:** ${VIRT_TYPE}  
**OS / Kernel:** ${OS_INFO} | ${KERNEL}  
**CPU:** ${CPU_MODEL} | vCPUs: ${CPU_COUNT}  
**RAM:** ${RAM_DISPLAY}  
**Disk (root):** ${DISK_DISPLAY}  
**Uptime:** ${UPTIME_STR}  
**Date (UTC):** $(date -u +"%Y-%m-%d %H:%M:%SZ")

---

## Performance Summary
- **CPU (sysbench):** ${CPU_EVENTS} events/sec → **${CPU_RATING}**
- **Memory (sysbench):** ${MEM_MBPS} MiB/sec → **${MEM_RATING}**
- **Disk Write:** ${DISK_MBPS} MB/s → **${DISK_RATING}**
- **Multitasking (load ratio = load_avg / vCPU):** ${LOAD_RATIO} → **${MULTI_RATING}**

## Network (HTTP download tests)
Average across responsive mirrors: **${AVG_NET_MBPS} MB/s** → **${NET_RATING}**

${MIRROR_TABLE}

## Outbound Port Checks
${PORT_TABLE}

## Listening Services (top)
\`\`\`
${LISTEN_SNIPPET}
\`\`\`

## Scoring
- CPU Score: ${CPU_NUM}
- Memory Score: ${MEM_NUM}
- Disk Score: ${DISK_NUM}
- Network Score: ${NET_NUM}
- Multitasking Score: ${MULTI_NUM}

**Overall Score:** ${OVERALL_SCORE} → **${OVERALL_TEXT}**

**Overall Suitability:** 
- ${OVERALL_TEXT} — Suggested target workloads:
  - Excellent: Production web services, DBs, high-frequency tasks
  - Good: APIs, lightweight DBs, trading bots, background workers
  - Fair/Poor: Consider larger instance or different provider for heavy workloads

---

*Report generated by vps-smart-benchmark.sh*
EOF

# JSON report (simple, best-effort)
cat > "$OUT_JSON" <<EOF
{
  "host": "${HOSTNAME}",
  "public_ip": "${PUBLIC_IP}",
  "virt_type": "${VIRT_TYPE}",
  "os_info": "$(echo "$OS_INFO" | sed 's/"/'\''/g')",
  "kernel": "${KERNEL}",
  "cpu_model": "$(echo "$CPU_MODEL" | sed 's/"/'\''/g')",
  "vcpu_count": ${CPU_COUNT},
  "ram_mb": ${RAM_MB},
  "disk_total_mb": ${DISK_TOTAL_MB},
  "cpu_events_per_sec": ${CPU_EVENTS},
  "cpu_rating": "${CPU_RATING}",
  "memory_mib_per_sec": ${MEM_MBPS},
  "memory_rating": "${MEM_RATING}",
  "disk_mb_per_sec": ${DISK_MBPS},
  "disk_rating": "${DISK_RATING}",
  "network_avg_mbps": ${AVG_NET_MBPS},
  "network_rating": "${NET_RATING}",
  "multitasking_ratio": ${LOAD_RATIO},
  "multitasking_rating": "${MULTI_RATING}",
  "overall_score": ${OVERALL_SCORE},
  "overall_text": "${OVERALL_TEXT}",
  "mirror_results": [
EOF

# Append mirror results in JSON array
first=1
for m in "${MIRROR_RESULTS[@]}"; do
  label="${m%%|*}"
  spd="${m##*|}"
  if [ $first -eq 1 ]; then
    first=0
  else
    echo "," >> "$OUT_JSON"
  fi
  echo "    { \"mirror\": \"${label}\", \"mbps\": ${spd} }" >> "$OUT_JSON"
done

# Continue JSON
cat >> "$OUT_JSON" <<EOF
  ],
  "port_checks": [
EOF

first=1
for p in "${PORT_RESULTS[@]}"; do
  hp="${p%%|*}"
  st="${p##*|}"
  if [ $first -eq 1 ]; then first=0; else echo "," >> "$OUT_JSON"; fi
  echo "    { \"hostport\": \"${hp}\", \"status\": \"${st}\" }" >> "$OUT_JSON"
done

cat >> "$OUT_JSON" <<EOF
  ],
  "listening_services_snippet": "$(echo "$LISTEN_SNIPPET" | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/'\''/g')",
  "timestamp_utc": "${TIMESTAMP}"
}
EOF

echo "[*] Report saved to:"
echo "    - $OUT_MD"
echo "    - $OUT_JSON"
echo ""
echo "You can open the markdown file or convert it to PDF (e.g., using pandoc or Markdown editor)."
echo "Example convert to PDF (if pandoc and wkhtmltopdf available):"
echo "  pandoc \"$OUT_MD\" -o /tmp/vps-benchmark-${HOSTNAME}-${TIMESTAMP}.pdf"

# Print small summary to stdout
cat <<SUMMARY

================ SUMMARY (quick) ================
Host: ${HOSTNAME}   IP: ${PUBLIC_IP}
CPU: ${CPU_EVENTS} events/sec → ${CPU_RATING}
Memory: ${MEM_MBPS} MiB/s → ${MEM_RATING}
Disk: ${DISK_MBPS} MB/s → ${DISK_RATING}
Network avg: ${AVG_NET_MBPS} MB/s → ${NET_RATING}
Multitasking ratio: ${LOAD_RATIO} → ${MULTI_RATING}
Overall Score: ${OVERALL_SCORE} → ${OVERALL_TEXT}
Reports: ${OUT_MD} , ${OUT_JSON}
=================================================

SUMMARY

exit 0
