#!/usr/bin/env bash
# =============================================================================
# run_firecracker.sh — Terminal 1
#
# Starts the Firecracker binary bound to an API socket. 
# Requires a separate terminal to run.
# =============================================================================

API_SOCKET="/tmp/firecracker.socket"

# Remove stale API socket from a previous run
sudo rm -f "$API_SOCKET"

echo "[firecracker] Starting on socket $API_SOCKET"
echo "[firecracker] Leave this terminal open. Ctrl-C to stop."
echo

# Run firecracker (blocks)
sudo ./firecracker --api-sock "${API_SOCKET}" --enable-pci