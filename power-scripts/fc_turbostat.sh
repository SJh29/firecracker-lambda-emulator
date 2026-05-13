#!/bin/bash
# fc_turbostat.sh — record CPU power & frequency with turbostat.
# turbostat is system-wide (per-socket), so we just record while the VM runs.
#
# Usage: sudo fc_turbostat.sh [SOCKET] [INTERVAL_SECS] [DURATION_SECS] [OUT_CSV]
#   defaults: /tmp/firecracker.socket  1  60  turbostat_<ts>.csv

set -e
SOCKET="${1:-/tmp/firecracker.socket}"
INTERVAL="${2:-1}"
DURATION="${3:-60}"
OUT="${4:-turbostat_$(date -u +%Y%m%d_%H%M%S).csv}"

if ! command -v turbostat &>/dev/null; then
    echo "ERROR: turbostat not installed (apt install linux-tools-common linux-tools-\$(uname -r))" >&2
    exit 1
fi

PID=$("$(dirname "$0")/fc_pid.sh" "$SOCKET" 2>/dev/null || true)
[[ -n "$PID" ]] && echo "[turbostat] Firecracker PID: $PID (socket=$SOCKET)" || echo "[turbostat] No Firecracker found, recording anyway"

echo "[turbostat] Sampling every ${INTERVAL}s for ${DURATION}s → $OUT"

# Comma-separated for CSV. Quiet + Summary = one row per interval.
sudo turbostat \
    --quiet \
    --Summary \
    --show PkgWatt,RAMWatt,CorWatt,GFXWatt,PkgTmp,Busy%,Bzy_MHz,TSC_MHz,CPU%c1,CPU%c6 \
    --interval "$INTERVAL" \
    --num_iterations "$(( DURATION / INTERVAL ))" \
    --out "$OUT"

echo "[turbostat] Done → $OUT"