#!/bin/bash
# fc_perf.sh — sample hardware PMU counters with perf stat -I.
# RAPL is handled by fc_rapl.py, not here (can't combine with -p PID).
#
# CSV is written incrementally (streamed) so a SIGKILL mid-run still leaves
# the data captured so far on disk — no end-of-run conversion step to skip.
#
# Usage: sudo fc_perf.sh [SOCKET] [INTERVAL_MS] [DURATION_SECS] [OUT_CSV]
#   defaults: /tmp/firecracker/0.socket  1000  300  perf_<ts>.csv

set -e
SOCKET="${1:-/tmp/firecracker/0.socket}"
INTERVAL_MS="${2:-1000}"
DURATION="${3:-300}"
OUT="${4:-perf_$(date -u +%Y%m%d_%H%M%S).csv}"

if ! command -v perf &>/dev/null; then
    echo "ERROR: perf not installed" >&2; exit 1
fi

PID=$(bash "$(dirname "$0")/fc_pid.sh" "$SOCKET" 2>/dev/null || true)
if [[ -z "$PID" ]]; then
    echo "[perf] ERROR: could not resolve Firecracker PID for socket $SOCKET" >&2
    echo "[perf]        (fc_pid.sh returned nothing — is Firecracker running?)" >&2
    exit 1
fi

ARCH=$(uname -m)
mkdir -p "$(dirname "$OUT")"   # perf/awk won't create the dir

# Same event set as the standalone version the user confirmed works,
# including kvm:kvm_exit.
EVENTS="cycles,instructions,cache-references,cache-misses,branch-misses,context-switches,cpu-migrations,kvm:kvm_exit"

echo "[perf] arch=$ARCH PID=$PID  ${INTERVAL_MS}ms × ${DURATION}s → $OUT"
echo "[perf] events: $EVENTS"

ERRLOG="${OUT%.csv}.errlog"

# Write header, then stream perf rows straight into the CSV. perf's interval
# rows appear on stderr in this build, so merge 2>&1, tee to ERRLOG for
# diagnostics, and let awk keep only timestamped data rows.
echo "time_s,value,unit,event,runtime_ns,pct_running,metric_value,metric_unit" > "$OUT"

sudo timeout --signal=INT "$DURATION" perf stat \
    -I "$INTERVAL_MS" -x , \
    -e "$EVENTS" \
    -p "$PID" 2>&1 \
  | stdbuf -oL tee "$ERRLOG" \
  | stdbuf -oL awk -F, '
        !/^#/ && NF>=4 && $1 ~ /^[0-9]+\.[0-9]+$/ {
            if ($2 == "<not counted>")   $2 = "0"
            if ($2 == "<not supported>") $2 = ""
            OFS=","; print; fflush()
        }
    ' >> "$OUT" || true

LINES=$(($(wc -l < "$OUT") - 1))
echo "[perf] Done → $OUT ($LINES data rows)"

if [[ $LINES -eq 0 && -s "$ERRLOG" ]]; then
    echo "[perf] WARNING: no data rows. perf stderr:" >&2
    head -8 "$ERRLOG" >&2
fi