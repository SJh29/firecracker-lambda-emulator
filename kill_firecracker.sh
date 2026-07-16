#!/usr/bin/env bash
# kill_firecracker.sh — Cleanly stop all running Firecracker microVMs
#
# Discovers the running instances from the sockets on disk (rather than being
# told how many there are), sends each one a graceful shutdown, then removes the
# host-side resources they owned: sockets, per-instance rootfs copies, generated
# configs, and TAP devices.
#
# Usage: sudo ./kill_firecracker.sh [-k]
#   -k   Keep the per-instance rootfs copies and configs (for post-mortem).

set -e
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$HERE/common.sh"

KEEP_STATE=0
while getopts "kh" opt; do
    case $opt in
        k) KEEP_STATE=1 ;;
        h) sed -n 's/^# \?//p' "$0" | head -n 9; exit 0 ;;
    esac
done

INSTANCES=($(fc_instances))

if (( ${#INSTANCES[@]} == 0 )); then
  sudo pkill -f "firecracker --api-sock" \
    && echo "No sockets found; killed stray Firecracker process(es)." \
    || echo "No Firecracker Process Found"
else
  for k in "${INSTANCES[@]}"; do
    fc_api PUT /actions '{ "action_type" : "SendCtrlAltDel" }' "$k" >/dev/null 2>&1 \
      && echo "Shutdown signal sent for instance $k" \
      || warn "instance $k did not accept the shutdown request"
  done

  # Give the guests a moment to halt, then make sure the VMMs are actually gone.
  # A guest that ignores Ctrl-Alt-Del would otherwise keep its rootfs and TAP
  # pinned, and the next run would collide with it.
  sleep 3
  for k in "${INSTANCES[@]}"; do
    pidfile="$API_SOCKET_FOLDER/$k.pid"
    [[ -f "$pidfile" ]] || continue
    pid="$(cat "$pidfile")"
    if sudo kill -0 "$pid" 2>/dev/null; then
      warn "instance $k (pid $pid) still up after Ctrl-Alt-Del — killing"
      sudo kill -9 "$pid" 2>/dev/null || true
    fi
  done
fi

# Tear down host resources. TAPs are removed for every instance id that could
# have been created, not just the ones with live sockets, so a crashed run
# doesn't leave a stale tap behind to poison the next launch.
for (( k=0; k<MAX_INSTANCES; k++ )); do
  ip link show "$(fc_tap "$k")" &>/dev/null || continue
  sudo ip link del "$(fc_tap "$k")" 2>/dev/null || true
  echo "Removed $(fc_tap "$k")"
done

sudo rm -rf "$API_SOCKET_FOLDER"
if (( KEEP_STATE )); then
  echo "Kept per-instance state in $FC_RUN_DIR"
else
  sudo rm -rf "$FC_RUN_DIR"
fi

echo "Firecracker stopped."
