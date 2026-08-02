#!/bin/bash
# fc_turbostat.sh -- record CPU power & frequency with turbostat.
# x86 only. Skips cleanly on ARM. Falls back through RAPL issues on AMD/Intel.
#
# Usage: sudo fc_turbostat.sh [SOCKET] [INTERVAL_SECS] [DURATION_SECS] [OUT_CSV]
#   defaults: /tmp/firecracker/0.socket  1  60  turbostat_<ts>.csv
#   INTERVAL_SECS may be fractional (e.g. 0.01 for 100 Hz sampling).

set -e
set -o pipefail   # so a turbostat failure isn't masked by the converter exiting 0
DIR="$(cd "$(dirname "$0")" && pwd)"
SOCKET="${1:-/tmp/firecracker/0.socket}"
INTERVAL="${2:-1}"
DURATION="${3:-60}"
OUT="${4:-turbostat_$(date -u +%Y%m%d_%H%M%S).csv}"

ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" && "$ARCH" != "amd64" ]]; then
    echo "[turbostat] skipping -- turbostat is x86 only (arch=$ARCH)"
    echo "[turbostat] use fc_arm_power.py for ARM hosts"
    exit 0
fi

if ! command -v turbostat &>/dev/null; then
    echo "ERROR: turbostat not installed (apt install linux-tools-common linux-tools-\$(uname -r))" >&2
    exit 1
fi

# turbostat's --interval accepts fractional seconds (e.g. 0.01 for 100 Hz), but
# --num_iterations must be an integer. Compute it with float math and round up
# so the run still covers the full DURATION; floor at 1 iteration.
ITERS=$(awk -v d="$DURATION" -v i="$INTERVAL" \
    'BEGIN { n = d / i; k = int(n); if (n > k) k++; if (k < 1) k = 1; print k }')
ERR=/tmp/turbo_err_$$
trap "rm -f $ERR" EXIT

# Stream turbostat's summary table through the normalizer so $OUT lands in the
# same schema fc_rapl.py emits (timestamp,elapsed_s,*_watts). turbostat flushes
# each interval, so the converter records real per-row wall-clock timestamps.
run_turbo () {
    local cols="$1"; shift
    sudo turbostat "$@" \
        --quiet --Summary \
        --show "$cols" \
        --interval "$INTERVAL" \
        --num_iterations "$ITERS" 2>"$ERR" \
        | python3 "$DIR/fc_turbostat_to_csv.py" "$OUT" "$INTERVAL"
}

echo "[turbostat] Sampling every ${INTERVAL}s for ${DURATION}s → $OUT"

# Attempt 1: full columns
if run_turbo "PkgWatt,RAMWatt,PkgTmp,Busy%,Bzy_MHz,TSC_MHz,CPU%c1,CPU%c6"; then
    echo "[turbostat] Done → $OUT"; exit 0
fi

# Attempt 2: --no-perf workaround (some AMD/Alder Lake CPUs)
if grep -q "rapl_perf_init\|rapl" "$ERR" 2>/dev/null; then
    echo "[turbostat] RAPL init failed; retrying with --no-perf"
    if run_turbo "PkgWatt,RAMWatt,PkgTmp,Busy%,Bzy_MHz" --no-perf; then
        echo "[turbostat] Done (--no-perf) → $OUT"; exit 0
    fi
fi

# Attempt 3: no power columns
echo "[turbostat] dropping power columns; keeping freq/temp/C-states"
if run_turbo "PkgTmp,Busy%,Bzy_MHz,TSC_MHz,CPU%c1,CPU%c6"; then
    echo "[turbostat] Done (no power) → $OUT"
    echo "[turbostat] NOTE: use fc_rapl.py or perf events for power"
    exit 0
fi

echo "[turbostat] FAILED -- turbostat not usable on this CPU." >&2
cat "$ERR" >&2
exit 1