#!/bin/bash
# run_firecracker.sh -- launch N concurrent Firecracker microVMs and block until
# they exit. Must be run with sudo; Firecracker needs root for /dev/kvm.
#
# Usage: sudo ./run_firecracker.sh [-m MEM_MIB] [-n NUM_INSTANCES] [-S SCRATCH_MB] [-u]
#   -m MEM_MIB        Guest memory (MiB). Also rewrites func_mem_size in
#                     boot_args so the guest init agrees with machine-config.
#   -n NUM_INSTANCES  Number of concurrent microVMs (default 1).
#   -S SCRATCH_MB     Size of each VM's writable /tmp scratch drive (default 128).
#   -u                Run unmetered (cpu.max=max). Default enforces the Lambda
#                     quota of mem/1769 vCPUs per instance.
# 
# Env:
#   PIN_CPUS          1/0 to force per-instance CPU pinning on/off. Defaults to
#                     on at >= 1769 MiB, off below it (quota only).
#   CPU_MAX           Raw cpu.max quota; overrides both the default and -u.
#
# ── Design ──────────────────────────────────────────────────────────────────
# Every resource a VM touches is either shared and read-only, or private to that
# instance, so N VMs can run at once without interfering:
#
#   shared, read-only   rootfs (aws_baseimage.ext4), function drive
#   per-instance        API socket, scratch drive, TAP device, MAC, guest IP,
#                       cgroup, CPU set, generated config, console log
#
# A guest's only writable surface is its scratch drive, mounted at /tmp and
# mkfs'd fresh each launch, so a run can neither corrupt the shared images nor
# carry state into the next one. Per-instance names all derive from the instance
# id k via the helpers in common.sh -- see the addressing table there.
set -e

# Resolved from the script's own path rather than $PWD or $HOME, so it stays
# correct under sudo.
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$HERE/common.sh"
source "$HERE/config.sh"

MEM_OVERRIDE=""
NUM_INSTANCES=1
SCRATCH_MB=128
UNMETERED=0
while getopts "m:n:S:uh" opt; do
    case $opt in
        m) MEM_OVERRIDE=$OPTARG ;;
        n) NUM_INSTANCES=$OPTARG ;;
        S) SCRATCH_MB=$OPTARG ;;
        u) UNMETERED=1 ;;
        h) sed -n '/^# Usage:/,/^#$/{ s/^# \?//; p; }' "$0"; exit 0 ;;
    esac
done

# ── Preflight ───────────────────────────────────────────────────────────────
[[ "$SCRATCH_MB" =~ ^[0-9]+$ ]] && (( SCRATCH_MB >= 1 )) \
    || { error "-S must be a positive integer (got '$SCRATCH_MB')"; exit 1; }

[[ "$NUM_INSTANCES" =~ ^[0-9]+$ ]] && (( NUM_INSTANCES >= 1 )) \
    || { error "-n must be a positive integer (got '$NUM_INSTANCES')"; exit 1; }
fc_check_instance "$(( NUM_INSTANCES - 1 ))" || exit 1

BASE_ROOTFS="$HERE/$ROOTFS_IMAGE"
[[ -f "$BASE_ROOTFS" ]] || { error "base rootfs not found: $BASE_ROOTFS (run install_build.sh)"; exit 1; }
[[ -f "$HERE/function.ext4" ]] || { error "function drive not found: $HERE/function.ext4 (run function_scripts/build_function.sh)"; exit 1; }

# Each VM pins ~1 vCPU plus a VMM thread, so oversubscribing the host makes the
# power numbers meaningless. Warn rather than refuse -- it's still runnable.
NPROC=$(nproc)
if (( NUM_INSTANCES * 2 > NPROC )); then
    warn "$NUM_INSTANCES instances need $(( NUM_INSTANCES * 2 )) CPUs but the host has $NPROC -- measurements will be contended."
fi

# ── Run directories ─────────────────────────────────────────────────────────
# Firecracker refuses to start if its socket already exists, so the previous
# run's state is cleared rather than reused.
sudo rm -rf "$API_SOCKET_FOLDER" "$FC_RUN_DIR"
sudo mkdir -p "$API_SOCKET_FOLDER" "$FC_RUN_DIR"

LOG_DIR="$(fc_log_dir)"
LOG_OWNER="${SUDO_USER:-root}"
sudo mkdir -p "$LOG_DIR"
sudo ln -sfn "$LOG_DIR" "$FC_LOG_ROOT/latest"
sudo chown -R "$LOG_OWNER" "$FC_LOG_ROOT" 2>/dev/null || true

# nodatacow keeps the write-heavy /tmp images from fragmenting or paying btrfs
# per-write checksum/CoW overhead
command -v chattr &>/dev/null && sudo chattr +C "$FC_RUN_DIR" 2>/dev/null || true

# ── Host networking ─────────────────────────────────────────────────────────
# One TAP per instance; idempotent, so re-running is safe.
sudo bash "$HERE/function_scripts/setup_tap.sh" -n "$NUM_INSTANCES"

# ── Per-instance CPU quota (cgroup v2) ──────────────────────────────────────
# Allocate 1 full vCPU of host CPU time per 1769 MB of guest memory (AWS Lambda
# ratio). vm_config's vcpu_count only creates virtual CPUs inside the guest; the
# real host CPU allocation is enforced here via cpu.max. 

MEM_MIB=$(jq -r '."machine-config".mem_size_mib' "$HERE/vm_config.template.json")
[[ -n "$MEM_OVERRIDE" ]] && MEM_MIB="$MEM_OVERRIDE"

CPU_PERIOD_US=100000
CPU_QUOTA_US=$((MEM_MIB * CPU_PERIOD_US / 1769))
((CPU_QUOTA_US > 0)) || CPU_QUOTA_US=1000

# When guest memory crosses 1769 MB the quota exceeds 1 vCPU, 
# so vcpu_count is bumped to ceil(mem/1769) or the guest can't
# schedule across more than one host CPU.

VCPU_COUNT=$(jq -r '."machine-config".vcpu_count' "$HERE/vm_config.template.json")
if ((MEM_MIB > 1769)); then
  VCPU_COUNT=$(((MEM_MIB + 1768) / 1769)) # ceil(MEM_MIB / 1769)
fi

# The quota is enforced by default; -u sets "max" (unmetered) and the CPU_MAX
# env var overrides both.
if (( UNMETERED )); then
    CPU_MAX="${CPU_MAX:-max}"
else
    CPU_MAX="${CPU_MAX:-$CPU_QUOTA_US}"
fi

CGROUP="$FC_CGROUP"
CGROUP_OK=1
sudo mkdir -p "$CGROUP" || CGROUP_OK=0
# The parent has to delegate cpu before its children can set cpu.max. Non-fatal:
# with CPU_MAX=max there's no quota to enforce anyway.
if (( CGROUP_OK )) && ! grep -qw cpu "$CGROUP/cgroup.subtree_control" 2>/dev/null; then
    echo "+cpu" | sudo tee "$CGROUP/cgroup.subtree_control" >/dev/null 2>&1 || {
        warn "could not enable the cpu controller on $CGROUP -- running without a CPU quota."
        warn "run ./install_cgroup.sh to fix; VMs will still start."
        CGROUP_OK=0
    }
fi
(( CGROUP_OK )) \
    && echo "Firecracker cgroup: $CGROUP/vm<k>  cpu.max=$CPU_MAX $CPU_PERIOD_US  (MEM=${MEM_MIB} MiB, vcpu=${VCPU_COUNT})" \
    || echo "Firecracker cgroup: disabled  (MEM=${MEM_MIB} MiB, vcpu=${VCPU_COUNT})"

# ── Per-instance CPU pinning (cgroup v2 cpuset) ─────────────────────────────
# cpu.max caps how much CPU time a VM gets, not which CPUs it runs on. Each
# instance is given VCPU_COUNT whole physical cores from fc_core_pool -- one core
# per vCPU, hyperthread siblings left idle -- allocated so a VM's cores never
# straddle a NUMA node. Pinning is skipped entirely if the host is too small.
#
# Below 1769 MB the quota is a fraction of one vCPU, so a dedicated core per
# instance would idle most of that core and cap the instance count for nothing;
# the quota alone is left to do the work. Setting PIN_CPUS explicitly overrides
# this in either direction.
PIN_OFF_REASON=""
if (( MEM_MIB < 1769 )); then
    PIN_CPUS="${PIN_CPUS:-0}"
    (( PIN_CPUS )) || PIN_OFF_REASON="quota only below 1769 MiB; PIN_CPUS=1 to force"
else
    PIN_CPUS="${PIN_CPUS:-1}"
fi
VM_CPUS=(); VM_NODE=()

if (( CGROUP_OK )) && (( PIN_CPUS )); then
    if ! grep -qw cpuset "$CGROUP/cgroup.subtree_control" 2>/dev/null; then
        echo "+cpuset" | sudo tee "$CGROUP/cgroup.subtree_control" >/dev/null 2>&1 || {
            warn "could not enable the cpuset controller on $CGROUP -- running unpinned."
            PIN_CPUS=0
        }
    fi
fi

if (( CGROUP_OK )) && (( PIN_CPUS )); then
    POOL_CPU=(); POOL_NODE=()
    while read -r cpu node; do
        POOL_CPU+=("$cpu"); POOL_NODE+=("$node")
    done < <(fc_core_pool)

    NEED=$(( NUM_INSTANCES * VCPU_COUNT ))
    if (( ${#POOL_CPU[@]} < NEED )); then
        warn "pinning needs $NEED physical cores ($NUM_INSTANCES x $VCPU_COUNT vcpu) but the host has ${#POOL_CPU[@]} -- running unpinned."
        warn "lower -n, or set PIN_CPUS=0 to silence this."
        PIN_CPUS=0
    fi
fi

if (( CGROUP_OK )) && (( PIN_CPUS )); then
    idx=0
    for (( k=0; k<NUM_INSTANCES; k++ )); do
        # POOL_* is node-ordered, so a window that starts and ends on the same
        # node lies entirely within it.
        while (( idx + VCPU_COUNT <= ${#POOL_CPU[@]} )) \
              && [[ "${POOL_NODE[idx]}" != "${POOL_NODE[idx + VCPU_COUNT - 1]}" ]]; do
            idx=$(( idx + 1 ))
        done
        if (( idx + VCPU_COUNT > ${#POOL_CPU[@]} )); then
            warn "ran out of node-aligned cores at instance $k -- running unpinned."
            VM_CPUS=(); VM_NODE=()
            break
        fi
        cpus="${POOL_CPU[idx]}"
        for (( j=1; j<VCPU_COUNT; j++ )); do cpus+=",${POOL_CPU[idx + j]}"; done
        VM_CPUS[k]="$cpus"
        VM_NODE[k]="${POOL_NODE[idx]}"
        idx=$(( idx + VCPU_COUNT ))
    done
fi

(( ${#VM_CPUS[@]} )) \
    && echo "CPU pinning: one physical core per vCPU, HT siblings idle" \
    || echo "CPU pinning: disabled${PIN_OFF_REASON:+  ($PIN_OFF_REASON)}"

# ── Per-instance scratch drives and configs ─────────────────────────────────
# The scratch image is mkfs'd every launch so runs stay comparable -- the same
# empty filesystem each time, rather than divergence accumulating across runs.
#
# func_mem_size is a kernel boot arg the guest init reads, so it has to track
# mem_size_mib; 
for (( k=0; k<NUM_INSTANCES; k++ )); do
    scratch="$(fc_scratch "$k")"
    config="$(fc_config "$k")"

    log "instance $k: creating ${SCRATCH_MB}MiB scratch → $scratch"
    sudo truncate -s "${SCRATCH_MB}M" "$scratch"
    sudo mkfs.ext4 -F -q -m 0 "$scratch"

    # `sudo tee` rather than `>`: the run dir is root-owned, and this keeps the
    # write from depending on the shell's own privileges.
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

# ── Teardown ────────────────────────────────────────────────────────────────
# Registered before the first VM starts, so a failure part-way through the
# launch loop still tears down whatever is already running.
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
        # Leaves a stale cpuset behind otherwise, which fc_reserved_cpus reads.
        sudo rmdir "$CGROUP/vm$k" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

# ── Launch ──────────────────────────────────────────────────────────────────
# Consoles go to one file per instance instead of this terminal. Firecracker's own diagnostics land in the same file, so a VM that dies at
# startup explains itself there and not here.
for (( k=0; k<NUM_INSTANCES; k++ )); do
    SOCKET="$(fc_socket "$k")"
    console="$(fc_console "$LOG_DIR" "$k")"
    # Pre-created because the redirect below runs as root and would otherwise
    # leave a root-owned log behind.
    sudo install -o "$LOG_OWNER" -m 644 /dev/null "$console"
    pinmsg=""
    [[ -n "${VM_CPUS[k]:-}" ]] && pinmsg=" cpus ${VM_CPUS[k]} node ${VM_NODE[k]}"
    echo "Starting Firecracker instance $k on $SOCKET (guest $(fc_guest_ip "$k") via $(fc_tap "$k"))${pinmsg} → $console"
    # The subshell enrolls itself, then execs, so the quota binds to the VM
    # process rather than to this launcher.
    (
        if (( CGROUP_OK )); then
            # Read $BASHPID before the pipeline below: in `echo $BASHPID | ...`
            # bash forks for the echo, so it would expand to a child that has
            # already exited, and the kernel rejects a dead PID with ESRCH.
            vm_pid=$BASHPID
            sudo mkdir -p "$CGROUP/vm$k"
            # cpuset before cgroup.procs, so the VM never runs unpinned.
            if [[ -n "${VM_CPUS[k]:-}" ]]; then
                echo "${VM_CPUS[k]}" | sudo tee "$CGROUP/vm$k/cpuset.cpus" >/dev/null \
                    || warn "instance $k: could not set cpuset.cpus -- running unpinned."
                echo "${VM_NODE[k]}" | sudo tee "$CGROUP/vm$k/cpuset.mems" >/dev/null \
                    || warn "instance $k: could not set cpuset.mems -- memory not node-bound."
            fi
            # Non-fatal: an unmetered VM still runs.
            echo "$CPU_MAX $CPU_PERIOD_US" | sudo tee "$CGROUP/vm$k/cpu.max" >/dev/null \
                || warn "instance $k: could not set cpu.max -- running without a CPU quota."
            echo "$vm_pid" | sudo tee "$CGROUP/vm$k/cgroup.procs" >/dev/null \
                || warn "instance $k: could not join $CGROUP/vm$k -- running without a CPU quota."
        fi
        exec "$HERE/firecracker" \
            --api-sock "$SOCKET" \
            --config-file "$(fc_config "$k")" \
            >>"$console" 2>&1
    ) &
    PIDS+=($!)
    echo "$!" | sudo tee "$API_SOCKET_FOLDER/$k.pid" >/dev/null
done

echo "All $NUM_INSTANCES instance(s) running. Ctrl-C to stop."
echo "Consoles: $LOG_DIR/console-<k>.log  (also $FC_LOG_ROOT/latest)"
echo "  follow with: tail -f $FC_LOG_ROOT/latest/console-0.log"

wait
