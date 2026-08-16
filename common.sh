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
#   subnet    172.16.<hi>.<lo>/30  →  host 172.16.<hi>.<lo+1>, guest 172.16.<hi>.<lo+2>
#   guest MAC 06:00:AC:10:<hi>:<lo+2>   (last 4 octets encode the guest IP)
#
#   where    hi = k / 64            (third octet)
#            lo = 4 * (k % 64)      (base of that instance's /30)
#
# Each instance holds its own point-to-point /30, so the host routing table
# stays unambiguous and no two guests share a broadcast domain. A /24 holds 64
# such subnets and the third octet supplies 256 of those, so k tops out at
# 16383 → 16384 instances, the whole of 172.16.0.0/16.
#
# The rootfs (aws_baseimage.ext4) and the function drive (function.ext4) are
# NOT per-instance.  Only writable state is a per-instance scratch drive mounted at /tmp inside the guest.

API_SOCKET_FOLDER="${API_SOCKET_FOLDER:-/tmp/firecracker}"
LOGFILE="./firecracker.log"

# Parent cgroup for the per-instance leaves (firecracker/vm<k>).
FC_CGROUP="${FC_CGROUP:-/sys/fs/cgroup/firecracker}"

# First two octets of the guest network; the last two are derived from k.
NET_PREFIX="172.16"
MASK_SHORT="/30"
MAX_INSTANCES=16384

# ─── Host capacity ───────────────────────────────────────────────────────────
# Memory held back for the host itself -- page cache, the collectors, the load
# generator -- and Firecracker's own per-VM footprint on top of guest RAM.
# Together these set how many instances run_firecracker.sh will launch before it
# refuses; see fc_mem_capacity.
FC_HOST_RESERVE_MIB="${FC_HOST_RESERVE_MIB:-2048}"
FC_VMM_OVERHEAD_MIB="${FC_VMM_OVERHEAD_MIB:-8}"

LAMBDA_PORT=8080
RUNTIME_SCRIPT="lambda_runtime.py"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Per-instance scratch drives and generated configs.
FC_RUN_DIR="${FC_RUN_DIR:-$SCRIPT_DIR/instances}"

# Console logs
FC_LOG_ROOT="${FC_LOG_ROOT:-$SCRIPT_DIR/logs}"
fc_log_dir()  { echo "$FC_LOG_ROOT/$(date +%Y%m%d-%H%M%S)"; }
fc_console()  { echo "$1/console-${2:-0}.log"; }  # <run-dir> <instance>

# Per-instance resource names. Each takes an instance id (default 0).
fc_socket()   { echo "$API_SOCKET_FOLDER/${1:-0}.socket"; }
fc_config()   { echo "$FC_RUN_DIR/vm_config-${1:-0}.json"; }
fc_scratch()  { echo "$FC_RUN_DIR/scratch-${1:-0}.ext4"; }
fc_rootfs()   { echo "$FC_RUN_DIR/rootfs-${1:-0}.ext4"; }  # reflink benchmark only
fc_tap()      { echo "tap${1:-0}"; }
fc_host_ip()  { echo "$NET_PREFIX.$(( ${1:-0} / 64 )).$(( 4 * (${1:-0} % 64) + 1 ))"; }
fc_guest_ip() { echo "$NET_PREFIX.$(( ${1:-0} / 64 )).$(( 4 * (${1:-0} % 64) + 2 ))"; }
fc_mac()      { printf '06:00:AC:10:%02X:%02X\n' "$(( ${1:-0} / 64 ))" "$(( 4 * (${1:-0} % 64) + 2 ))"; }

# Reject instance ids that would run past the end of 172.16.0.0/16.
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

# ─── Host memory capacity ────────────────────────────────────────────────────

# Total host RAM in MiB.
fc_host_mem_mib() { awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo; }

# How many instances of $1 MiB of guest memory the host can carry, given the
# reserve it keeps for itself and Firecracker's per-VM overhead.
#
# MemTotal rather than MemAvailable: the answer has to be the same every run,
# not a function of how full the page cache happens to be. Prints 0 when a
# single instance does not fit, which callers report separately.
fc_mem_capacity() {
    local mem_mib="$1" total per_vm usable
    total="$(fc_host_mem_mib)"
    [[ -n "$total" ]] || { echo 0; return 0; }
    per_vm=$(( mem_mib + FC_VMM_OVERHEAD_MIB ))
    (( per_vm > 0 )) || { echo 0; return 0; }
    usable=$(( total - FC_HOST_RESERVE_MIB ))
    (( usable > 0 )) || { echo 0; return 0; }
    echo $(( usable / per_vm ))
}

# ─── Host CPU topology ───────────────────────────────────────────────────────

# Every logical CPU as "<cpu> <node>" per line, ordered by NUMA node, then
# socket, then core, then thread. Taking the first M of these therefore fills
# whole cores and whole nodes before spilling onto the next, so a pool sized by
# count lands on as few nodes as possible.
fc_cpu_list() {
    lscpu -p=CPU,CORE,SOCKET,NODE 2>/dev/null \
      | grep -v '^#' \
      | awk -F, '{ print $1, ($4 == "" ? 0 : $4), $3, $2 }' \
      | sort -k2,2n -k3,3n -k4,4n -k1,1n \
      | awk '{ print $1, $2 }'
}

# The first $1 logical CPUs from fc_cpu_list, printed as "<cpus> <nodes>" where
# both are cpuset lists. Fails if the host has fewer CPUs than requested.
fc_cpu_pool() {
    local want="$1" n=0 cpu node
    local -a cpus=() nodes=()
    [[ "$want" =~ ^[0-9]+$ ]] && (( want >= 1 )) || return 1
    while read -r cpu node; do
        (( n < want )) || break
        cpus+=("$cpu"); nodes+=("$node"); n=$(( n + 1 ))
    done < <(fc_cpu_list)
    (( n == want )) || return 1
    printf '%s %s\n' \
        "$(IFS=,; echo "${cpus[*]}")" \
        "$(printf '%s\n' "${nodes[@]}" | sort -n -u | paste -sd,)"
}

# NUMA nodes spanned by a cpuset list, itself as a cpuset list.
fc_cpu_nodes() {
    local -a sel; local cpu node
    mapfile -t sel < <(fc_cpu_expand "$1")
    fc_cpu_list | while read -r cpu node; do
        [[ " ${sel[*]} " == *" $cpu "* ]] && echo "$node"
    done | sort -n -u | paste -sd,
}

# Number of CPUs in a cpuset list. Zero for an empty list, so it stays safe to
# call under `set -e`.
fc_cpu_count() { fc_cpu_expand "$1" | wc -l; }

# Expand a cpuset list ("0-3,8") to one CPU id per line.
fc_cpu_expand() {
    local -a parts; local part lo hi c
    IFS=',' read -ra parts <<< "$1"
    for part in "${parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            lo="${part%%-*}"; hi="${part##*-}"
            for (( c = lo; c <= hi; c++ )); do echo "$c"; done
        elif [[ -n "$part" ]]; then
            echo "$part"
        fi
    done
}

# CPUs sharing a physical core with CPU $1, as a cpuset list.
fc_thread_siblings() {
    local f="/sys/devices/system/cpu/cpu$1/topology/thread_siblings_list"
    if [[ -r "$f" ]]; then cat "$f"; else echo "$1"; fi
}

# Every CPU in the microVM pool plus their hyperthread siblings, ascending. The
# siblings are included because a task on one shares execution units with the
# pool CPU it partners, so it is not free of the guests either.
#
# Reads cpuset.cpus, not cpuset.cpus.effective, so a run with no pool set
# reports nothing rather than the whole host.
fc_reserved_cpus() {
    local cpus c
    [[ -r "$FC_CGROUP/cpuset.cpus" ]] || return 0
    cpus="$(<"$FC_CGROUP/cpuset.cpus")"
    [[ -n "$cpus" ]] || return 0
    for c in $(fc_cpu_expand "$cpus"); do
        fc_cpu_expand "$(fc_thread_siblings "$c")"
    done | sort -n -u
}

# CPUs not in fc_reserved_cpus, as a cpuset list. Empty if no pool is set.
fc_free_cpus() {
    local -a reserved; local c out=""
    mapfile -t reserved < <(fc_reserved_cpus)
    (( ${#reserved[@]} )) || return 0
    for (( c = 0; c < $(nproc --all); c++ )); do
        [[ " ${reserved[*]} " == *" $c "* ]] && continue
        out+="${out:+,}$c"
    done
    echo "$out"
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
