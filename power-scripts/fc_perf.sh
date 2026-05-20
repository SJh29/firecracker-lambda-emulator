#!/bin/bash
# fc_perf.sh — sample hardware PMU counters with perf stat -I.
# RAPL is handled by fc_rapl.py, not here (can't combine with -p PID).
#
# Usage: sudo fc_perf.sh [SOCKET] [INTERVAL_MS] [DURATION_SECS] [OUT_CSV]
#   defaults: /tmp/firecracker.socket  1000  60  perf_<ts>.csv

set -e
SOCKET="${1:-/tmp/firecracker.socket}"
INTERVAL_MS="${2:-1000}"
DURATION="${3:-60}"
OUT="${4:-perf_$(date -u +%Y%m%d_%H%M%S).csv}"

if ! command -v perf &>/dev/null; then
    echo "ERROR: perf not installed" >&2; exit 1
fi

PID=$("$(dirname "$0")/fc_pid.sh" "$SOCKET")
ARCH=$(uname -m)

# Per-process events only. RAPL energy-pkg/energy-ram are system-wide PMUs
# and cannot be combined with -p PID; use fc_rapl.py for those.
# Set /proc/sys/kernel/perf_event_paranoid <=1 for Tracepoints (kvm:kvm_exit)
EVENTS="cycles,instructions,cache-references,cache-misses,branch-misses,context-switches,cpu-migrations,kvm:kvm_exit"

echo "[perf] arch=$ARCH PID=$PID  ${INTERVAL_MS}ms × ${DURATION}s → $OUT"
echo "[perf] events: $EVENTS"

ERRLOG="${OUT%.csv}.errlog"
RAW="${OUT%.csv}.raw"
trap "rm -f $RAW" EXIT

# perf stat writes data to stderr by default. --output FILE sends it to FILE
# instead, leaving stderr for actual error messages.
sudo timeout --signal=INT "$DURATION" perf stat \
    -I "$INTERVAL_MS" -x , \
    -e "$EVENTS" \
    -p "$PID" \
    --output "$RAW" 2> "$ERRLOG" || true

# Header + filtered rows
{
    echo "time_s,value,unit,event,runtime_ns,pct_running,metric_value,metric_unit"
    awk -F, '
        !/^#/ && NF>=4 {
            if ($2 == "<not counted>") $2 = "0"
            if ($2 == "<not supported>") $2 = ""
            OFS=","
            print
        }
    ' "$RAW"
} > "$OUT"

LINES=$(($(wc -l < "$OUT") - 1))
echo "[perf] Done → $OUT ($LINES data rows)"

# Real errors (not the data perf accidentally puts on stderr in some versions)
if [[ -s "$ERRLOG" ]] && grep -qiE 'error|invalid|unable|permission|cannot' "$ERRLOG"; then
    echo "[perf] WARNING: perf reported issues, see $ERRLOG:" >&2
    head -5 "$ERRLOG" >&2
fi

if [[ $LINES -eq 0 ]]; then
    echo "[perf] ERROR: no data captured. See $ERRLOG and $RAW" >&2
    exit 1
fi