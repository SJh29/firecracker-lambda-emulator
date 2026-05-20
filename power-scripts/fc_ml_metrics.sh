#!/bin/bash
# fc_ml_features.sh — perf events curated for power modeling.
# Captures cycles, instructions, cache, memory, branch — outputs wide CSV
# with one row per interval (suitable for ML ingestion).
#
# Usage: sudo fc_ml_features.sh [SOCKET] [INTERVAL_MS] [DURATION_SECS] [OUT_CSV]
#   defaults: /tmp/firecracker.socket  1000  60  ml_features_<ts>.csv

set -e
SOCKET="${1:-/tmp/firecracker.socket}"
INTERVAL_MS="${2:-1000}"
DURATION="${3:-60}"
OUT="${4:-ml_features_$(date -u +%Y%m%d_%H%M%S).csv}"

if ! command -v perf &>/dev/null; then
    echo "ERROR: perf not installed" >&2; exit 1
fi

PID=$("$(dirname "$0")/fc_pid.sh" "$SOCKET")
ARCH=$(uname -m)

# Arch-specific event sets. Each list is comma-separated, no spaces.
# Events confirmed by Bircher & John and McCullough et al. to capture
# most variance in CPU power.
case "$ARCH" in
    x86_64|amd64)
        EVENTS="cycles,instructions,cache-references,cache-misses,\
LLC-loads,LLC-load-misses,branch-instructions,branch-misses,\
context-switches,cpu-migrations,page-faults"
        ;;
    aarch64|arm64)
        # Graviton / ARMv8 PMU events
        EVENTS="cycles,instructions,cache-references,cache-misses,\
branch-instructions,branch-misses,\
context-switches,cpu-migrations,page-faults"
        ;;
    *)
        EVENTS="cycles,instructions,cache-misses,branch-misses,\
context-switches,page-faults"
        ;;
esac

echo "[ml_features] arch=$ARCH PID=$PID ${INTERVAL_MS}ms × ${DURATION}s → $OUT"
echo "[ml_features] events: $EVENTS"

# perf stat -I prints one block per interval. We collect raw -x , output
# then pivot to wide CSV with one row per interval.
RAW=$(mktemp)
trap "rm -f $RAW" EXIT

sudo timeout "$DURATION" perf stat \
    -I "$INTERVAL_MS" -x , \
    -e "$EVENTS" \
    -p "$PID" 2>&1 \
  | grep -v '^#' \
  | grep -v 'not counted' \
  | grep -v 'not supported' \
  > "$RAW" || true

# Pivot: each interval timestamp gets one row across all events.
python3 - "$RAW" "$OUT" "$EVENTS" <<'PY'
import sys, csv
from collections import defaultdict

raw, out, events_csv = sys.argv[1], sys.argv[2], sys.argv[3]
events = events_csv.replace("\\\n","").split(",")
event_keys = [e.replace("-","_") for e in events]

by_time = defaultdict(dict)
with open(raw) as f:
    for line in f:
        parts = line.strip().split(",")
        if len(parts) < 4: continue
        try:
            t = float(parts[0])
            val = parts[1].replace(",","")
            ev = parts[3].replace("-","_")
            try: v = float(val)
            except: v = None
            by_time[t][ev] = v
        except: continue

times = sorted(by_time)
cols = ["elapsed_s"] + event_keys
# derived columns
cols += ["ipc", "llc_miss_rate", "branch_miss_rate"]

with open(out, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
    w.writeheader()
    for t in times:
        row = {"elapsed_s": t}
        for ev in event_keys:
            row[ev] = by_time[t].get(ev)
        # derived metrics
        try:
            if row.get("cycles"):
                row["ipc"] = round(row["instructions"] / row["cycles"], 4)
        except: pass
        try:
            if row.get("LLC_loads"):
                row["llc_miss_rate"] = round(row["LLC_load_misses"] / row["LLC_loads"], 4)
        except: pass
        try:
            if row.get("branch_instructions"):
                row["branch_miss_rate"] = round(row["branch_misses"] / row["branch_instructions"], 4)
        except: pass
        w.writerow(row)

print(f"[ml_features] wrote {len(times)} rows to {out}")
PY

echo "[ml_features] Done → $OUT"