#!/bin/bash
# run_firecracker.sh — must be run with sudo (Firecracker needs root for /dev/kvm)
#
# Usage: sudo ./run_firecracker.sh [-m MEM_MIB] [-n NUM_INSTANCES] [-S SCRATCH_MB]
#   -m MEM_MIB        Override guest memory (MiB). Also updates func_mem_size in
#                     boot_args so the guest init agrees with machine-config.
#   -n NUM_INSTANCES  Number of concurrent microVMs (default 1). Each gets its
#                     own socket, scratch drive, TAP device, MAC and guest IP —
#                     see the addressing table in common.sh.
#   -S SCRATCH_MB     Size of each VM's writable /tmp scratch drive (default 128).
#
# The rootfs and function drive are shared read-only across all instances — one
# copy, mounted read-only, so concurrent VMs can't corrupt them. The only
# per-instance writable surface is a small scratch drive mounted at /tmp in the
# guest (freshly mkfs'd, nodatacow on btrfs). Networking is isolated too: one
# TAP per VM on its own point-to-point /30.
set -e

# Resolve project root from the script's own location. Works under sudo because
# it doesn't rely on $HOME or $USER — only on where this script physically lives.
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$HERE/common.sh"
source "$HERE/config.sh"

MEM_OVERRIDE=""
NUM_INSTANCES=1
SCRATCH_MB=128
while getopts "m:n:S:h" opt; do
    case $opt in
        m) MEM_OVERRIDE=$OPTARG ;;
        n) NUM_INSTANCES=$OPTARG ;;
        S) SCRATCH_MB=$OPTARG ;;
        h) sed -n 's/^# \?//p' "$0" | head -n 14; exit 0 ;;
    esac
done

[[ "$SCRATCH_MB" =~ ^[0-9]+$ ]] && (( SCRATCH_MB >= 1 )) \
    || { error "-S must be a positive integer (got '$SCRATCH_MB')"; exit 1; }

[[ "$NUM_INSTANCES" =~ ^[0-9]+$ ]] && (( NUM_INSTANCES >= 1 )) \
    || { error "-n must be a positive integer (got '$NUM_INSTANCES')"; exit 1; }
fc_check_instance "$(( NUM_INSTANCES - 1 ))" || exit 1

BASE_ROOTFS="$HERE/$ROOTFS_IMAGE"
[[ -f "$BASE_ROOTFS" ]] || { error "base rootfs not found: $BASE_ROOTFS (run install_build.sh)"; exit 1; }
[[ -f "$HERE/function.ext4" ]] || { error "function drive not found: $HERE/function.ext4 (run function_scripts/build_function.sh)"; exit 1; }

# Each VM pins ~1 vCPU (plus a VMM thread), so oversubscribing the host makes
# the power numbers meaningless. Warn rather than refuse — it's still runnable.
NPROC=$(nproc)
if (( NUM_INSTANCES * 2 > NPROC )); then
    warn "$NUM_INSTANCES instances need $(( NUM_INSTANCES * 2 )) CPUs but the host has $NPROC — measurements will be contended."
fi

# Clean any stale sockets (Firecracker refuses to start if a socket already
# exists) and any scratch drives left behind by a previous run.
sudo rm -rf "$API_SOCKET_FOLDER" "$FC_RUN_DIR"
sudo mkdir -p "$API_SOCKET_FOLDER" "$FC_RUN_DIR"

# On btrfs, mark the scratch dir nodatacow so the write-heavy /tmp images don't
# fragment or pay per-write checksum/CoW overhead — that overhead lands in host
# package power (RAPL/turbostat) and would contaminate the measurement. chattr
# +C only takes effect on files created afterward, so it must precede the mkfs
# below. No-op on filesystems without CoW.
command -v chattr &>/dev/null && sudo chattr +C "$FC_RUN_DIR" 2>/dev/null || true

# ── Host networking ─────────────────────────────────────────────────────────
# One TAP per instance. Idempotent, so re-running is safe.
sudo bash "$HERE/function_scripts/setup_tap.sh" -n "$NUM_INSTANCES"

# ── Per-instance CPU quota via cgroup v2 ────────────────────────────────────
# Allocate 1 full vCPU of host CPU time per 1769 MB of guest memory (AWS Lambda
# ratio). vm_config's vcpu_count only creates virtual CPUs inside the guest; the
# real host CPU allocation is enforced here via cpu.max. When guest memory
# crosses 1769 MB the quota exceeds 1 vCPU, so bump vcpu_count to ceil(mem/1769)
# so the guest can actually schedule across more than one host CPU.
#
# Each VM lands in its own leaf cgroup (firecracker/vm<k>) so the quota is
# per-instance. cgroup v2 forbids processes in a cgroup that has children, so
# this shell stays out of the parent and each child enrolls itself below.
MEM_MIB=$(jq -r '."machine-config".mem_size_mib' "$HERE/vm_config.template.json")
[[ -n "$MEM_OVERRIDE" ]] && MEM_MIB="$MEM_OVERRIDE"

CPU_PERIOD_US=100000
CPU_QUOTA_US=$((MEM_MIB * CPU_PERIOD_US / 1769))
((CPU_QUOTA_US > 0)) || CPU_QUOTA_US=1000

VCPU_COUNT=$(jq -r '."machine-config".vcpu_count' "$HERE/vm_config.template.json")
if ((MEM_MIB > 1769)); then
  VCPU_COUNT=$(((MEM_MIB + 1768) / 1769)) # ceil(MEM_MIB / 1769)
fi

# Replace "max" with "$CPU_QUOTA_US" to enable memory-based CPU allocation.
CPU_MAX="${CPU_MAX:-max}"

CGROUP=/sys/fs/cgroup/firecracker
CGROUP_OK=1
sudo mkdir -p "$CGROUP" || CGROUP_OK=0
# The parent must delegate cpu to its children before they can set cpu.max.
# Non-fatal: with CPU_MAX=max there's no quota to enforce anyway, so a host
# without the cpu controller should still be able to run the VMs.
if (( CGROUP_OK )) && ! grep -qw cpu "$CGROUP/cgroup.subtree_control" 2>/dev/null; then
    echo "+cpu" | sudo tee "$CGROUP/cgroup.subtree_control" >/dev/null 2>&1 || {
        warn "could not enable the cpu controller on $CGROUP — running without a CPU quota."
        warn "run ./install_cgroup.sh to fix; VMs will still start."
        CGROUP_OK=0
    }
fi
(( CGROUP_OK )) \
    && echo "Firecracker cgroup: $CGROUP/vm<k>  cpu.max=$CPU_MAX $CPU_PERIOD_US  (MEM=${MEM_MIB} MiB, vcpu=${VCPU_COUNT})" \
    || echo "Firecracker cgroup: disabled  (MEM=${MEM_MIB} MiB, vcpu=${VCPU_COUNT})"

# ── Build the per-instance scratch drives and configs ───────────────────────
# All instances share $BASE_ROOTFS read-only, so there is nothing to clone —
# the only per-instance disk is a small, freshly formatted scratch image that
# the guest mounts at /tmp. mkfs each launch keeps it deterministic (same empty
# filesystem every run) instead of accumulating divergence across runs.
for (( k=0; k<NUM_INSTANCES; k++ )); do
    scratch="$(fc_scratch "$k")"
    config="$(fc_config "$k")"

    log "instance $k: creating ${SCRATCH_MB}MiB scratch → $scratch"
    sudo truncate -s "${SCRATCH_MB}M" "$scratch"
    sudo mkfs.ext4 -F -q -m 0 "$scratch"

    # Render the template, then apply memory/vcpu in the same pipeline: bump
    # mem_size_mib, the matching func_mem_size kernel arg, and vcpu_count so the
    # guest can use the whole quota. Piping into `sudo tee` keeps the write to
    # the (root-owned) run dir from depending on this shell's own privileges.
    sed -e "s|@ROOT@|$HERE|g" \
        -e "s|@ROOTFS@|$BASE_ROOTFS|g" \
        -e "s|@SCRATCH@|$scratch|g" \
        -e "s|@TAP@|$(fc_tap "$k")|g" \
        -e "s|@MAC@|$(fc_mac "$k")|g" \
        -e "s|@GUEST_IP@|$(fc_guest_ip "$k")|g" \
        -e "s|@HOST_IP@|$(fc_host_ip "$k")|g" \
        "$HERE/vm_config.template.json" \
      | jq --argjson m "$MEM_MIB" --argjson v "$VCPU_COUNT" '
            ."machine-config".mem_size_mib = $m
          | ."machine-config".vcpu_count   = $v
          | ."boot-source".boot_args |= sub("func_mem_size=[0-9]+"; "func_mem_size=\($m)")
        ' \
      | sudo tee "$config" >/dev/null
done

# ── Launch ──────────────────────────────────────────────────────────────────
PIDS=()
cleanup() {
    trap - EXIT INT TERM
    echo
    echo "Shutting down $NUM_INSTANCES instance(s)..."
    for pid in "${PIDS[@]}"; do sudo kill "$pid" 2>/dev/null || true; done
    sleep 1
    for pid in "${PIDS[@]}"; do sudo kill -9 "$pid" 2>/dev/null || true; done
    sudo rm -rf "$API_SOCKET_FOLDER" "$FC_RUN_DIR"
    for (( k=0; k<NUM_INSTANCES; k++ )); do
        sudo ip link del "$(fc_tap "$k")" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

for (( k=0; k<NUM_INSTANCES; k++ )); do
    SOCKET="$(fc_socket "$k")"
    echo "Starting Firecracker instance $k on $SOCKET (guest $(fc_guest_ip "$k") via $(fc_tap "$k"))"
    # Subshell enrolls itself in its own leaf cgroup, then becomes Firecracker,
    # so the quota applies to the VM process rather than to this launcher.
    (
        if (( CGROUP_OK )); then
            # Capture the PID *before* any pipeline: inside `echo $BASHPID | ...`
            # bash forks a child for the echo, so $BASHPID would expand to that
            # child — which has already exited by the time tee writes, and the
            # kernel rejects a dead PID with ESRCH ("No such process").
            vm_pid=$BASHPID
            sudo mkdir -p "$CGROUP/vm$k"
            echo "$CPU_MAX $CPU_PERIOD_US" | sudo tee "$CGROUP/vm$k/cpu.max" >/dev/null \
                || warn "instance $k: could not set cpu.max — running without a CPU quota."
            # Non-fatal: a VM outside its leaf cgroup is unmetered but still runs.
            echo "$vm_pid" | sudo tee "$CGROUP/vm$k/cgroup.procs" >/dev/null \
                || warn "instance $k: could not join $CGROUP/vm$k — running without a CPU quota."
        fi
        exec "$HERE/firecracker" \
            --api-sock "$SOCKET" \
            --config-file "$(fc_config "$k")"
    ) &
    PIDS+=($!)
    echo "$!" | sudo tee "$API_SOCKET_FOLDER/$k.pid" >/dev/null
done

echo "All $NUM_INSTANCES instance(s) running. Ctrl-C to stop."

# Wait for all launched instances to exit.
wait
