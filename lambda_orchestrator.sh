#!/usr/bin/env bash
# =============================================================================
# lambda_orchestrator.sh — Terminal 2 orchestrator
#
# Requires start_firecracker.sh to already be running in another terminal.
#
# Calls each stage script in order:
#   01_tap_setup.sh       Host TAP interface + NAT
#   02_configure_vm.sh    Logger, kernel, rootfs, NIC via API socket
#   03_start_vm.sh        InstanceStart
#   04_guest_network.sh   SSH wait, default route, DNS
#   05_deploy_function.sh SCP runtime + function, start HTTP server
#   06_invoke.sh          POST payload, print response
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



SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# defaults
FUNCTION_FILE="./function.py"
PAYLOAD='{"key": "value"}'
PAYLOAD_FILE=""
TIMEOUT=30
KEEP_ALIVE=false

# argument parsing
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--function)     FUNCTION_FILE="$2"; shift 2 ;;
        -p|--payload)      PAYLOAD="$2";        shift 2 ;;
        -P|--payload-file) PAYLOAD_FILE="$2";   shift 2 ;;
        -t|--timeout)      TIMEOUT="$2";        shift 2 ;;
        -k|--keep-alive)   KEEP_ALIVE=true;     shift   ;;
        -h|--help) sed -n '3,20p' "$0" | sed 's/^# \{0,2\}//'; exit 0 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -n "$PAYLOAD_FILE" ]] && PAYLOAD="$(cat "$PAYLOAD_FILE")"

# ── Preflight checks ──────────────────────────────────────────────────────────
[[ -S "$API_SOCKET" ]] || {
    error "Firecracker API socket not found at $API_SOCKET"
    error "Run ./start_firecracker.sh in another terminal first."
    exit 1
}

KERNEL="./$(ls vmlinux* 2>/dev/null | tail -1 || true)"
ROOTFS="./$(ls *.ext4  2>/dev/null | tail -1 || true)"
KEY_NAME="./$(ls *.id_rsa 2>/dev/null | tail -1 || true)"

for f in "$KERNEL" "$ROOTFS" "$KEY_NAME" "$FUNCTION_FILE" "./$RUNTIME_SCRIPT"; do
    [[ -f "$f" ]] || { error "Required file not found: $f"; exit 1; }
done

log "Kernel  : $KERNEL"
log "Rootfs  : $ROOTFS"
log "SSH key : $KEY_NAME"
log "Function: $FUNCTION_FILE"

# Export variables that stage scripts read from the environment
export KERNEL ROOTFS KEY_NAME FUNCTION_FILE PAYLOAD TIMEOUT

# run script stages in order
run_stage() {
    local script="$SCRIPT_DIR/stages/$1"
    [[ -x "$script" ]] || chmod +x "$script"
    bash "$script"
}

echo
echo "** Firecracker Lambda Emulator **"
echo

run_stage 01_tap_setup.sh
run_stage 02_configure_vm.sh
run_stage 03_start_vm.sh
run_stage 04_guest_network.sh
run_stage 05_deploy_function.sh
run_stage 06_invoke.sh

# ── Shutdown ──────────────────────────────────────────────────────────────────
if $KEEP_ALIVE; then
    warn "VM left running (--keep-alive). SSH: ssh -i $KEY_NAME root@$GUEST_IP"
    warn "Kill Firecracker with Ctrl-C in terminal 1 when you're done."
else
    log "Rebooting VM to trigger shutdown (reboot=k treats this as halt) …"
    ssh_guest "reboot" 2>/dev/null || true
    success "Done. Firecracker in terminal 1 will exit on its own."
fi