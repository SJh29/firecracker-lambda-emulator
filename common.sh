#!/usr/bin/env bash
# Shared constants and helpers for the Firecracker tooling.
#
# ─── Instance addressing ─────────────────────────────────────────────────────
# Every VM is identified by an integer instance id k, starting at 0. All of a
# VM's host-side resources are derived from k, so no two instances collide:
#
#   socket    /tmp/firecracker/<k>.socket
#   config    <repo>/instances/vm_config-<k>.json
#   scratch   <repo>/instances/scratch-<k>.ext4  (private writable /tmp drive)
#   tap dev   tap<k>
#   subnet    172.16.0.<4k>/30  →  host 172.16.0.<4k+1>, guest 172.16.0.<4k+2>
#   guest MAC 06:00:AC:10:00:<4k+2>   (last 4 octets encode the guest IP)
#
# The rootfs (aws_baseimage.ext4) and the function drive (function.ext4) are
# NOT per-instance: every VM mounts them read-only and shares one copy. Only
# writable state is per-instance — a small scratch drive mounted at /tmp inside
# the guest. This keeps the write-heavy path off any shared file (so no ext4
# corruption) and, on btrfs, off the copy-on-write path (fresh mkfs, nodatacow),
# so repeated writes don't fragment a reflinked image and skew measurements.
#
# scratch drives live in FC_RUN_DIR beside the base image. fc_rootfs() is kept
# for the reflink benchmark (temp_reflink_setup.sh), which clones the rootfs
# per instance instead of sharing it — the alternative this layout replaced.
#
# One /30 per VM gives each guest its own point-to-point link to the host, so
# the host routing table stays unambiguous. Instance 0 resolves to the original
# single-VM values (tap0, 172.16.0.1/172.16.0.2), so the old setup is just the
# k=0 case of the new one.
#
# The last usable /30 is 172.16.0.252, so k tops out at 63 → 64 instances.

API_SOCKET_FOLDER="${API_SOCKET_FOLDER:-/tmp/firecracker}"
LOGFILE="./firecracker.log"

NET_PREFIX="172.16.0"
MASK_SHORT="/30"
MAX_INSTANCES=64

LAMBDA_PORT=8080
RUNTIME_SCRIPT="lambda_runtime.py"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Per-instance scratch drives and generated configs.
FC_RUN_DIR="${FC_RUN_DIR:-$SCRIPT_DIR/instances}"

# Per-instance resource names. Each takes an instance id (default 0).
fc_socket()   { echo "$API_SOCKET_FOLDER/${1:-0}.socket"; }
fc_config()   { echo "$FC_RUN_DIR/vm_config-${1:-0}.json"; }
fc_scratch()  { echo "$FC_RUN_DIR/scratch-${1:-0}.ext4"; }
fc_rootfs()   { echo "$FC_RUN_DIR/rootfs-${1:-0}.ext4"; }  # reflink benchmark only
fc_tap()      { echo "tap${1:-0}"; }
fc_host_ip()  { echo "$NET_PREFIX.$(( 4 * ${1:-0} + 1 ))"; }
fc_guest_ip() { echo "$NET_PREFIX.$(( 4 * ${1:-0} + 2 ))"; }
fc_mac()      { printf '06:00:AC:10:00:%02X\n' "$(( 4 * ${1:-0} + 2 ))"; }

# Reject instance ids that would run past the end of 172.16.0.0/24.
fc_check_instance() {
    local k="$1"
    if ! [[ "$k" =~ ^[0-9]+$ ]] || (( k >= MAX_INSTANCES )); then
        error "invalid instance id '$k' (must be 0..$(( MAX_INSTANCES - 1 )))"
        return 1
    fi
}

# Instance ids of the VMs that are currently up, ascending, one per line.
# Derived from the sockets on disk rather than a variable, so any script can
# discover the running set without being told how many were launched.
fc_instances() {
    local had_nullglob=0 s id
    shopt -q nullglob && had_nullglob=1
    shopt -s nullglob
    for s in "$API_SOCKET_FOLDER"/*.socket; do
        id="${s##*/}"; id="${id%.socket}"
        [[ "$id" =~ ^[0-9]+$ ]] && echo "$id"
    done | sort -n
    (( had_nullglob )) || shopt -u nullglob
}

# Backwards-compatible single-VM aliases (instance 0).
TAP_DEV="$(fc_tap 0)"
TAP_IP="$(fc_host_ip 0)"
GUEST_IP="$(fc_guest_ip 0)"
FC_MAC="$(fc_mac 0)"

# ─── logging ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log()     { echo -e "${BLUE}[lambda]${NC} $*"; }
success() { echo -e "${GREEN}[lambda]${NC} $*"; }
warn()    { echo -e "${YELLOW}[lambda]${NC} $*"; }
error()   { echo -e "${RED}[lambda]${NC} $*" >&2; }

# firecracker API helper function
# Usage: fc_api <METHOD> <PATH> <JSON_BODY> [INSTANCE]   (instance defaults to 0)
fc_api() {
    local method="$1" path="$2" data="$3" instance="${4:-0}"
    sudo curl -sS -X "$method" --unix-socket "$(fc_socket "$instance")" \
        --data "$data" \
        "http://localhost${path}"
}

# ssh/scp helper for guest access.
# KEY_NAME must be set before these are called.
# Usage: ssh_guest [-i INSTANCE] <command...>
ssh_guest() {
    local instance=0
    [[ "$1" == "-i" ]] && { instance="$2"; shift 2; }
    ssh -i "$KEY_NAME" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=5 \
        root@"$(fc_guest_ip "$instance")" "$@"
}

# Usage: scp_to_guest [-i INSTANCE] <local> <remote>
scp_to_guest() {
    local instance=0
    [[ "$1" == "-i" ]] && { instance="$2"; shift 2; }
    scp -i "$KEY_NAME" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "$1" root@"$(fc_guest_ip "$instance")":"$2"
}
