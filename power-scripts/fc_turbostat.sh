#!/bin/bash
# fc_turbostat.sh — record CPU power & frequency with turbostat.
# Tries fallbacks for the rapl_perf_init assertion bug on some CPUs.
#
# Usage: sudo fc_turbostat.sh [SOCKET] [INTERVAL_SECS] [DURATION_SECS] [OUT_CSV]
#   defaults: /tmp/firecracker.socket  1  60  turbostat_<ts>.csv

set -e
SOCKET="${1:-/tmp/firecracker.socket}"
INTERVAL="${2:-1}"
DURATION="${3:-60}"
OUT="${4:-turbostat_$(date -u +%Y%m%d_%H%M%S).csv}"

if ! command -v turbostat &>/dev/null; then
    echo "ERROR: turbostat not installed" >&2
    exit 1
fi

ITERS=$(( DURATION / INTERVAL ))
ERR=/tmp/turbo_err_$$
trap "rm -f $ERR" EXIT

run_turbo () {
    local cols="$1"; shift
    sudo turbostat "$@" \
        --quiet --Summary \
        --show "$cols" \
        --interval "$INTERVAL" \
        --num_iterations "$ITERS" \
        --out "$OUT" 2>"$ERR"
}

echo "[turbostat] Sampling every ${INTERVAL}s for ${DURATION}s → $OUT"

# Attempt 1: full columns, default RAPL path
if run_turbo "PkgWatt,RAMWatt,PkgTmp,Busy%,Bzy_MHz,TSC_MHz,CPU%c1,CPU%c6"; then
    echo "[turbostat] Done → $OUT"; exit 0
fi

# Attempt 2: --no-perf forces MSR-only RAPL (skips the failing perf init path)
if grep -q "rapl_perf_init" "$ERR"; then
    echo "[turbostat] perf-RAPL init failed; retrying with --no-perf"
    if run_turbo "PkgWatt,RAMWatt,PkgTmp,Busy%,Bzy_MHz" --no-perf; then
        echo "[turbostat] Done (--no-perf) → $OUT"; exit 0
    fi
fi

# Attempt 3: drop power columns; keep freq/temp/C-states
echo "[turbostat] retrying without power columns"
if run_turbo "PkgTmp,Busy%,Bzy_MHz,TSC_MHz,CPU%c1,CPU%c6"; then
    echo "[turbostat] Done (no power columns) → $OUT"
    echo "[turbostat] NOTE: use fc_rapl.py for power data"
    exit 0
fi

echo "[turbostat] FAILED on this CPU. Use fc_rapl.py for power." >&2
cat "$ERR" >&2
exit 1