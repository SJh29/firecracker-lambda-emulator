#!/bin/bash
# fc_pidstat.sh — record per-process CPU, memory, IO, threads with pidstat.
#
# Usage: sudo fc_pidstat.sh [SOCKET] [INTERVAL_SECS] [DURATION_SECS] [OUT_CSV]
#   defaults: /tmp/firecracker/0.socket  1  60  pidstat_<ts>.csv

set -e
SOCKET="${1:-/tmp/firecracker/0.socket}"
INTERVAL="${2:-1}"
DURATION="${3:-60}"
OUT="${4:-pidstat_$(date -u +%Y%m%d_%H%M%S).csv}"

if ! command -v pidstat &>/dev/null; then
    echo "ERROR: pidstat not installed (apt install sysstat)" >&2
    exit 1
fi

PID=$("$(dirname "$0")/fc_pid.sh" "$SOCKET")
COUNT=$(( DURATION / INTERVAL ))
echo "[pidstat] PID=$PID, ${INTERVAL}s × ${COUNT} → $OUT"

# -u CPU, -r memory, -d disk IO, -w context switches, -h tabular, -H epoch
{
    echo "epoch,UID,PID,%usr,%system,%guest,%wait,%CPU,CPU_id,minflt_s,majflt_s,VSZ_KB,RSS_KB,%MEM,kB_rd_s,kB_wr_s,kB_ccwr_s,iodelay,cswch_s,nvcswch_s,Command"
    sudo pidstat -h -H -u -r -d -w -p "$PID" "$INTERVAL" "$COUNT" \
      | awk 'NR>2 && !/^#/ && NF>2 {
            for (i=1; i<=NF; i++) printf "%s%s", $i, (i<NF?",":"\n")
        }'
} > "$OUT"

echo "[pidstat] Done → $OUT"