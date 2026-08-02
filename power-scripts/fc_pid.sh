#!/bin/bash
# fc_pid.sh -- print the PID owning a Firecracker Unix socket.
# Verifies the candidate PID has comm == "firecracker" before returning it.
#
# Usage:  fc_pid.sh [SOCKET_PATH]
#         default: /tmp/firecracker/0.socket  (instance 0)

set -e
SOCKET="${1:-/tmp/firecracker/0.socket}"
if [[ ! -S "$SOCKET" ]]; then
    echo "ERROR: $SOCKET is not a socket" >&2
    exit 1
fi

verify() {
    local pid=$1
    [[ -z "$pid" || ! -d "/proc/$pid" ]] && return 1
    local comm
    comm=$(cat "/proc/$pid/comm" 2>/dev/null || true)
    [[ "$comm" == "firecracker" || "$comm" == "jailer" ]]
}

# fuser is the most reliable
if command -v fuser &>/dev/null; then
    for pid in $(sudo fuser "$SOCKET" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$'); do
        verify "$pid" && { echo "$pid"; exit 0; }
    done
fi

# ss listening sockets with verification
if command -v ss &>/dev/null; then
    for pid in $(sudo ss -xlp 2>/dev/null | grep -F "$SOCKET" | grep -oP 'pid=\K\d+' | sort -u); do
        verify "$pid" && { echo "$pid"; exit 0; }
    done
fi

# lsof with verification
if command -v lsof &>/dev/null; then
    for pid in $(sudo lsof -t -U "$SOCKET" 2>/dev/null); do
        verify "$pid" && { echo "$pid"; exit 0; }
    done
fi

# Last resort: by name -- only safe when exactly one Firecracker is running.
# With concurrent instances, picking the first match would silently attach the
# collectors to the wrong VM, so bail out instead and let the caller see why.
mapfile -t all_pids < <(pgrep -x firecracker)
if (( ${#all_pids[@]} == 1 )); then
    verify "${all_pids[0]}" && { echo "${all_pids[0]}"; exit 0; }
elif (( ${#all_pids[@]} > 1 )); then
    echo "ERROR: could not map $SOCKET to a PID, and ${#all_pids[@]} Firecracker" >&2
    echo "       processes are running -- refusing to guess. Install fuser, ss or" >&2
    echo "       lsof so the socket owner can be resolved exactly." >&2
    exit 1
fi

# Failure with diagnostics
{
    echo "ERROR: no firecracker process owning $SOCKET"
    echo "  pgrep firecracker  : $(pgrep -a firecracker || echo none)"
    echo "  ss -xlp filter     : $(sudo ss -xlp 2>/dev/null | grep -F "$SOCKET" || echo none)"
    echo "  fuser              : $(sudo fuser "$SOCKET" 2>&1 || echo none)"
} >&2
exit 1