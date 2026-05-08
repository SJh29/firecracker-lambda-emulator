#!/usr/bin/env bash
# =============================================================================
# lambda_orchestrator.sh — Terminal 2 orchestrator
#
# Requires run_firecracker.sh to already be running in another terminal.
#
# Calls each stage script in order:
#   01_tap_setup.sh            Host TAP interface + NAT
#   02_build_function_drive.sh Build ext4 drive containing function.py
#   03_configure_vm.sh         Logger, kernel, rootfs, function drive, NIC via API socket
#   04_initialize_vm.sh        InstanceStart
#   05_wait_for_rie.sh         Poll RIE /ping until guest runtime is ready
#   06_invoke.sh               POST payload, print response
#
# Usage:
#   ./lambda_orchestrator.sh [OPTIONS]
#
# Options:
#   -f, --function PATH     Python function file            (default: ./function.py)
#   -p, --payload JSON      JSON payload string             (default: '{"key":"value"}')
#   -P, --payload-file FILE JSON payload file               (overrides --payload)
#   -t, --timeout SECS      HTTP timeout for invocation     (default: 30)
#   -k, --keep-alive        Don't shut down the VM after invocation
#   -h, --help              Show this help
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# defaults
FUNCTION_FILE="./function.py"
PAYLOAD='{"key": "value"}'
PAYLOAD_FILE=""
TIMEOUT=30
KEEP_ALIVE=true

# argument parsing
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--function)     FUNCTION_FILE="$2"; shift 2 ;;
        -p|--payload)      PAYLOAD="$2";        shift 2 ;;
        -P|--payload-file) PAYLOAD_FILE="$2";   shift 2 ;;
        -t|--timeout)      TIMEOUT="$2";        shift 2 ;;
        -k|--keep-alive)   KEEP_ALIVE=true;     shift   ;;
        -h|--help) sed -n '3,22p' "$0" | sed 's/^# \{0,2\}//'; exit 0 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -n "$PAYLOAD_FILE" ]] && PAYLOAD="$(cat "$PAYLOAD_FILE")"

# ── Preflight checks ──────────────────────────────────────────────────────────
[[ -S "$API_SOCKET" ]] || {
    error "Firecracker API socket not found at $API_SOCKET"
    error "Run ./run_firecracker.sh in another terminal first."
    exit 1
}

KERNEL="$SCRIPT_DIR/$(ls "$SCRIPT_DIR"/vmlinux-* 2>/dev/null | tail -1 | xargs basename)"
ROOTFS="$SCRIPT_DIR/aws_baseimage.ext4"
FUNCTION_DRIVE="$SCRIPT_DIR/function.ext4"   # built by stage 02

for f in "$KERNEL" "$ROOTFS" "$FUNCTION_FILE"; do
    [[ -f "$f" ]] || { error "Required file not found: $f"; exit 1; }
done

log "Kernel  : $KERNEL"
log "Rootfs  : $ROOTFS"
log "Function: $FUNCTION_FILE"
log "Invoke  : http://${GUEST_IP}:${LAMBDA_PORT}/2015-03-31/functions/function/invocations"

# Export variables that stage scripts read from the environment
export KERNEL ROOTFS FUNCTION_FILE FUNCTION_DRIVE PAYLOAD TIMEOUT SCRIPT_DIR

# ── Stage runner ──────────────────────────────────────────────────────────────
run_stage() {
    local script="$SCRIPT_DIR/stages/$1"
    [[ -x "$script" ]] || chmod +x "$script"
    bash "$script"
}

echo
echo "** Firecracker Lambda Emulator **"
echo

run_stage 01_tap_setup.sh
run_stage 02_build_function_drive.sh
run_stage 03_configure_vm.sh
run_stage 04_initialize_vm.sh
run_stage 05_wait_for_rie.sh
run_stage 06_invoke.sh

# ── Shutdown ──────────────────────────────────────────────────────────────────
if $KEEP_ALIVE; then
    warn "VM left running (--keep-alive). Kill run_firecracker.sh with Ctrl-C in terminal 1 when done."
else
    log "Sending reboot to halt VM..."
    # reboot=k in kernel args means Firecracker exits cleanly on reboot syscall
    fc_api PUT /actions '{"action_type":"SendCtrlAltDel"}'
fi