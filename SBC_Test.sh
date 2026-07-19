#!/usr/bin/env bash
# SBC_Test.sh — Comprehensive SBC sanity test (sysbench + telemetry + ping + report)
set -euo pipefail

# ---------- Config ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LOG_DIR="$SCRIPT_DIR/Logs"
THREADS="$(nproc --all)"

# Durations for CPU/threads/mutex passes (seconds)
CPU_PASS_SECS=300
THREADS_PASS_SECS=180
MUTEX_PASS_SECS=180

# Memory sweep settings
MEM_TOTAL_SIZE="4G"       # amount to process per subtest (not resident at once)
MEM_BLOCK_SIZES=("4K" "64K" "1M")
MEM_ACCESS_MODES=("seq" "rnd")
MEM_OPS=("read" "write")

# Optional: enable file I/O test (heavy wear on flash) by setting to 1
ENABLE_FILEIO=0
FILEIO_TOTAL_SIZE="2G"    # total test file size
FILEIO_MODE="rndrw"       # rndrd|rndwr|rndrw|seqrd|seqwr
FILEIO_DURATION=180

# ---------- Helpers ----------
cecho() { # cecho <color> <text>
  local c="$1"; shift
  local reset="\033[0m"
  local green="\033[32m"; local yellow="\033[33m"; local red="\033[31m"; local cyan="\033[36m"
  case "$c" in
    green) printf "%b%s%b\n" "$green" "$*" "$reset" ;;
    yellow) printf "%b%s%b\n" "$yellow" "$*" "$reset" ;;
    red) printf "%b%s%b\n" "$red" "$*" "$reset" ;;
    cyan) printf "%b%s%b\n" "$cyan" "$*" "$reset" ;;
    *) echo "$*";;
  esac
}

# ---------- Prep ----------
mkdir -p "$LOG_DIR"
echo "[$(date '+%F %T')] ➤ Logs: $LOG_DIR"
: > "$LOG_DIR/updates.log"

echo "[$(date '+%F %T')] ➤ apt update & full-upgrade"
sudo apt update 2>&1 | tee -a "$LOG_DIR/updates.log"
sudo apt full-upgrade -y 2>&1 | tee -a "$LOG_DIR/updates.log"

echo "[$(date '+%F %T')] ➤ Ensure tools exist"
if ! command -v sysbench >/dev/null; then
  sudo apt install -y sysbench 2>&1 | tee -a "$LOG_DIR/updates.log"
fi
if ! command -v fastfetch >/dev/null; then
  FASTFETCH_URL="https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-aarch64.deb"
  curl -L --retry 3 "$FASTFETCH_URL" -o "$LOG_DIR/fastfetch.deb" 2>&1 | tee -a "$LOG_DIR/updates.log"
  sudo dpkg -i "$LOG_DIR/fastfetch.deb" 2>&1 | tee -a "$LOG_DIR/updates.log" || true
  sudo apt -f install -y 2>&1 | tee -a "$LOG_DIR/updates.log"
  rm -f "$LOG_DIR/fastfetch.deb"
fi

# ---------- Telemetry (runs in background during tests) ----------
TELEM_LOG="$LOG_DIR/telemetry.csv"
echo "timestamp,temp_c,arm_hz,throttled,loadavg1,loadavg5,loadavg15" > "$TELEM_LOG"

telemetry() {
  while :; do
    ts="$(date '+%F %T')"
    if command -v vcgencmd >/dev/null; then
      temp_c="$(vcgencmd measure_temp 2>/dev/null | sed -E 's/[^0-9.]//g')"
      arm_hz="$(vcgencmd measure_clock arm 2>/dev/null | awk -F= '{print $2}')"
      throttled="$(vcgencmd get_throttled 2>/dev/null | awk -F= '{print $2}')"
    else
      raw="$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)"
      temp_c="$(awk -v r="$raw" 'BEGIN{printf "%.1f", r/1000}')"
      arm_hz="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)"
      throttled="N/A"
    fi
    read -r l1 l5 l15 _ < /proc/loadavg
    echo "$ts,$temp_c,$arm_hz,$throttled,$l1,$l5,$l15" >> "$TELEM_LOG"
    sleep 1
  done
}
telemetry &
TELEM_PID=$!
cleanup() { kill "$TELEM_PID" 2>/dev/null || true; }
trap cleanup EXIT

# ---------- CPU tests ----------
echo "[$(date '+%F %T')] ➤ sysbench CPU (baseline)"
sysbench cpu --cpu-max-prime=360000 --threads=8 --time=0 --events=10000 --verbosity=5 run \
  2>&1 | tee "$LOG_DIR/sysbench_cpu_baseline.log"

echo "[$(date '+%F %T')] ➤ sysbench CPU (${THREADS} threads, ${CPU_PASS_SECS}s)"
sysbench cpu --cpu-max-prime=600000 --threads="$THREADS" --time=$CPU_PASS_SECS --events=0 --verbosity=5 run \
  2>&1 | tee "$LOG_DIR/sysbench_cpu_nt.log"

echo "[$(date '+%F %T')] ➤ sysbench CPU ($((THREADS*2)) threads, ${CPU_PASS_SECS}s)"
sysbench cpu --cpu-max-prime=600000 --threads="$((THREADS*2))" --time=$CPU_PASS_SECS --events=0 --verbosity=5 run \
  2>&1 | tee "$LOG_DIR/sysbench_cpu_2nt.log"

# ---------- Memory tests ----------
echo "[$(date '+%F %T')] ➤ sysbench MEMORY sweep"
for bs in "${MEM_BLOCK_SIZES[@]}"; do
  for mode in "${MEM_ACCESS_MODES[@]}"; do
    for op in "${MEM_OPS[@]}"; do
      name="mem_${op}_${mode}_${bs}"
      echo "[$(date '+%F %T')]  • $name total=$MEM_TOTAL_SIZE threads=$THREADS"
      sysbench memory \
        --threads="$THREADS" --time=0 --events=0 --verbosity=5 \
        --memory-total-size="$MEM_TOTAL_SIZE" \
        --memory-block-size="$bs" \
        --memory-access-mode="$mode" \
        --memory-oper="$op" \
        run 2>&1 | tee "$LOG_DIR/sysbench_${name}.log"
    done
  done
done

# ---------- Threads test (modern sysbench: no extra knobs) ----------
echo "[$(date '+%F %T')] ➤ sysbench THREADS (${THREADS_PASS_SECS}s)"
sysbench threads \
  --threads="$THREADS" --time=$THREADS_PASS_SECS --events=0 --verbosity=5 \
  run 2>&1 | tee "$LOG_DIR/sysbench_threads.log"

# ---------- Mutex test ----------
echo "[$(date '+%F %T')] ➤ sysbench MUTEX (${MUTEX_PASS_SECS}s)"
sysbench mutex \
  --threads="$THREADS" --time=$MUTEX_PASS_SECS --events=0 --verbosity=5 \
  --mutex-num=4096 --mutex-locks=200000 --mutex-loops=10000 \
  run 2>&1 | tee "$LOG_DIR/sysbench_mutex.log"

# ---------- Optional: File I/O ----------
if [[ "$ENABLE_FILEIO" -eq 1 ]]; then
  echo "[$(date '+%F %T')] ➤ sysbench FILEIO (may wear flash!)"
  pushd "$LOG_DIR" >/dev/null
  sysbench fileio --file-total-size="$FILEIO_TOTAL_SIZE" --file-test-mode=$FILEIO_MODE prepare
  sysbench fileio --file-total-size="$FILEIO_TOTAL_SIZE" --file-test-mode=$FILEIO_MODE \
    --time=$FILEIO_DURATION --events=0 --verbosity=5 --threads="$THREADS" --file-io-mode=async \
    --file-extra-flags=direct --file-fsync-freq=0 run | tee "$LOG_DIR/sysbench_fileio.log"
  sysbench fileio --file-total-size="$FILEIO_TOTAL_SIZE" --file-test-mode=$FILEIO_MODE cleanup
  popd >/dev/null
fi

# ---------- Network sanity ----------
echo "[$(date '+%F %T')] ➤ Pinging 8.8.8.8 every 1s for 10m"
set +e
ping -i 1 -w 180 8.8.8.8 2>&1 | tee "$LOG_DIR/ping.log"
PING_EXIT=${PIPESTATUS[0]}
set -e
echo "Ping exit status: $PING_EXIT" | tee -a "$LOG_DIR/ping.log"

# ---------- fastfetch snapshot (end, like original) ----------
echo "[$(date '+%F %T')] ➤ Capturing system info with fastfetch"
fastfetch 2>&1 | tee "$LOG_DIR/fastfetch.log"

# ---------- Report generator ----------
REPORT="$LOG_DIR/report.txt"

# System info (OS, kernel, RAM, IP/adapters, storage)
OS_NAME="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Unknown}")"
KERNEL="$(uname -r)"
UPTIME="$(uptime -p || true)"
MEM_HUMAN="$(free -h | awk '/^Mem:/ {printf "Total: %s, Used: %s, Free: %s, Avail: %s", $2,$3,$4,$7}')"
SWAP_HUMAN="$(free -h | awk '/^Swap:/ {printf "Total: %s, Used: %s, Free: %s", $2,$3,$4}')"
ACTIVE_IFS="$(ip -br link 2>/dev/null | awk '$2=="UP"{print $1}' | grep -v '^lo$' || true)"
IP_TABLE=$(
  while read -r IF; do
    [[ -z "$IF" ]] && continue
    IP4="$(ip -4 -br addr show dev "$IF" 2>/dev/null | awk '{print $3}' | tr -d '\n')"
    IP6="$(ip -6 -br addr show dev "$IF" 2>/dev/null | awk '{print $3}' | tr -d '\n')"
    printf "%s  IPv4: %s  IPv6: %s\n" "$IF" "${IP4:-n/a}" "${IP6:-n/a}"
  done <<< "$ACTIVE_IFS"
)
DF_TABLE="$(df -hT)"
LSBLK_TABLE="$(lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL)"

# ---------- FIXED: Telemetry + parsing ----------
# Telemetry summary (max/avg temp, min/avg ARM clock)
read -r MAXT AVGT MINC AVGC <<<"$(
  awk -F, '
    NR>1 {
      t+=$2; c+=$3;
      if ($2>mt) mt=$2;
      if (minc==0 || $3<minc) minc=$3;
      n++
    }
    END {
      if (n==0) {
        print "0 0 0 0"
      } else {
        printf "%.1f %.1f %.0f %.0f\n", mt, t/n, minc, c/n
      }
    }
  ' "$TELEM_LOG"
)"

# Any non-zero throttling seen?
THROTTLING="$(
  awk -F, 'NR>1 && $4!="0x0" && $4!="N/A" {print $4; exit}' "$TELEM_LOG" 2>/dev/null
)"
[[ -z "$THROTTLING" ]] && THROTTLING="none"

# Ping summary (support both iputils output styles)
PING_SUMMARY="$(grep -E "packet loss|rtt min/avg/max|round-trip min/avg/max" "$LOG_DIR/ping.log" | tail -n 2 || true)"

# Sysbench parses
CPU_BASE_EPS="$(grep -m1 "events per second" "$LOG_DIR/sysbench_cpu_baseline.log" | awk -F: '{print $2}' | xargs || true)"
CPU_NT_EPS="$(grep -m1 "events per second" "$LOG_DIR/sysbench_cpu_nt.log"       | awk -F: '{print $2}' | xargs || true)"
CPU_2NT_EPS="$(grep -m1 "events per second" "$LOG_DIR/sysbench_cpu_2nt.log"     | awk -F: '{print $2}' | xargs || true)"
THREADS_EPS="$(grep -m1 "events per second" "$LOG_DIR/sysbench_threads.log"     | awk -F: '{print $2}' | xargs || true)"
MUTEX_TOTAL="$(grep -m1 "total time:"        "$LOG_DIR/sysbench_mutex.log"      | awk -F: '{print $2}' | xargs || true)"
MUTEX_AVG="$(grep -m1 "avg:"                 "$LOG_DIR/sysbench_mutex.log"      | awk -F: '{print $2}' | xargs || true)"

# Memory results (collect MiB/sec for each run)
MEM_RESULTS=$(
  shopt -s nullglob
  for f in "$LOG_DIR"/sysbench_mem_*.log "$LOG_DIR"/sysbench_memory_*.log; do
    b="$(basename "$f")"
    rate="$(grep -m1 -E "MiB/sec|MB/sec" "$f" | sed -E 's/.*\(([^)]*MiB\/sec)\).*/\1/;t; s/.* ([0-9.]+(MiB|MB)\/sec).*/\1/')" || true
    echo "$b: ${rate:-n/a}"
  done
)

# ---------- PASS/FAIL heuristics ----------
PASS_TEMP=1; PASS_THROT=1; PASS_PING=1
(( $(printf "%.0f" "${MAXT:-0}") <= 85 )) || PASS_TEMP=0
[[ "$THROTTLING" == "none" ]] || PASS_THROT=0
LOSS_PCT="$(echo "$PING_SUMMARY" | grep -m1 "packet loss" | sed -E 's/.* ([0-9]+)% packet loss.*/\1/' || echo 0)"
[[ -n "$LOSS_PCT" ]] || LOSS_PCT=0
(( LOSS_PCT == 0 )) || PASS_PING=0

# ---------- Build report ----------
{
  echo "==================== SBC TEST REPORT ===================="
  echo "Date: $(date)"
  echo
  echo "----- System Summary -----"
  echo "OS:        $OS_NAME"
  echo "Kernel:    $KERNEL"
  echo "Uptime:    $UPTIME"
  echo "CPU cores: $THREADS"
  echo "Memory:    $MEM_HUMAN"
  echo "Swap:      $SWAP_HUMAN"
  echo
  echo "Active Adapters & IPs:"
  if [[ -n "$IP_TABLE" ]]; then
    echo "$IP_TABLE"
  else
    echo "  (none UP)"
  fi
  echo
  echo "Storage (filesystems):"
  echo "$DF_TABLE"
  echo
  echo "Storage (block devices):"
  echo "$LSBLK_TABLE"
  echo
  echo "----- CPU TEST RESULTS -----"
  printf "Baseline (8t): %s\n" "${CPU_BASE_EPS:-n/a}"
  printf "N threads    : %s\n" "${CPU_NT_EPS:-n/a}"
  printf "2N threads   : %s\n" "${CPU_2NT_EPS:-n/a}"
  echo
  echo "----- MEMORY TEST RESULTS (MiB/sec) -----"
  if [[ -n "$MEM_RESULTS" ]]; then
    echo "$MEM_RESULTS"
  else
    echo "(no memory results parsed)"
  fi
  echo
  echo "----- THREADS TEST RESULTS -----"
  printf "Events/sec: %s\n" "${THREADS_EPS:-n/a}"
  echo
  echo "----- MUTEX TEST RESULTS -----"
  printf "Total time: %s | Avg: %s\n" "${MUTEX_TOTAL:-n/a}" "${MUTEX_AVG:-n/a}"
  echo
  echo "----- TEMPERATURE / CLOCK SUMMARY -----"
  printf "Max Temp: %.1f°C | Avg Temp: %.1f°C | Min ARM Clock: %.0f Hz | Avg ARM Clock: %.0f Hz\n" "${MAXT:-0}" "${AVGT:-0}" "${MINC:-0}" "${AVGC:-0}"
  echo "Throttling: $THROTTLING"
  echo
  echo "----- NETWORK TEST RESULTS -----"
  if [[ -n "$PING_SUMMARY" ]]; then
    echo "$PING_SUMMARY"
  else
    echo "(no ping summary parsed)"
  fi
  echo
  echo "----- fastfetch (hardware snapshot) -----"
  cat "$LOG_DIR/fastfetch.log" 2>/dev/null || echo "(fastfetch log missing)"
  echo "==========================================================="
} | tee "$REPORT" >/dev/null

# ---------- Colorized quick summary ----------
cecho cyan   "=== QUICK STATUS ==="
[[ $PASS_TEMP -eq 1 ]] && cecho green "Thermals: OK (max ${MAXT:-0}°C)" || cecho red "Thermals: HOT! (max ${MAXT:-0}°C)"
[[ $PASS_THROT -eq 1 ]] && cecho green "Throttling: none" || cecho red "Throttling flags: $THROTTLING"
[[ $PASS_PING -eq 1 ]] && cecho green "Network: OK (loss ${LOSS_PCT}%)" || cecho yellow "Network loss: ${LOSS_PCT}%"
echo
cecho cyan "Full report saved to: $REPORT"
echo

# ---------- Done ----------
echo "[$(date '+%F %T')] ➤ All done! Logs in $LOG_DIR"
