#!/usr/bin/env bash
# stop_firecracker.sh — Cleanly stop a running Firecracker microVM

set -e 
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$HERE/common.sh"
if [[ -S "$API_SOCKET" ]]; then
  fc_api PUT /actions '{ "action_type" : "SendCtrlAltDel" }'
  echo "Shutdown Signal Sent"
else
  sudo pkill -f "firecracker --api-sock" && echo "Firecracker Process Killed." || echo "No Firecracker Process Found"
fi
