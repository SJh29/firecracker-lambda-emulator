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
#   CPU_POOL          The set of host CPUs the whole fleet shares, as either a
#                     cpuset list ("0-23,48-71") or a count of CPUs. Unset: the
#                     fleet may run anywhere on the host.
#   OVERSUB           Requested vCPUs per pool CPU; sizes the pool to
#                     ceil(N * vcpu_count / OVERSUB). 1 gives the fleet exactly
#                     as many CPUs as it requests, 2 gives it half. Ignored when
#                     CPU_POOL is set.
#   CPU_MAX           Raw cpu.max quota; overrides both the default and -u.
#
# ── Design ──────────────────────────────────────────────────────────────────
# Every resource a VM touches is either shared and read-only, or private to that
# instance, so N VMs can run at once without interfering:
#
#   shared, read-only   rootfs (aws_baseimage.ext4), function drive
#   shared              the CPU pool, when one is set
#   per-instance        API socket, scratch drive, TAP device, MAC, guest IP,
#                       cgroup, CPU quota, generated config, console log
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

# ── Shared CPU pool (cgroup v2 cpuset) ──────────────────────────────────────
# cpu.max caps how much CPU time each VM gets; the pool caps which host CPUs the
# fleet as a whole may run on. It is set once on the parent cgroup and inherited
# by every instance, so instances contend for the pool the way co-tenant
# functions contend for a host rather than each owning private cores. This
# mirrors AWS Lambda, which meters CPU time by memory size and leaves placement
# to the host scheduler.
#
# With no pool set the fleet may run anywhere on the host, and the quota alone
# does the work. Sizing the pool below what the fleet requests oversubscribes it
# by a known ratio, which is what turns co-tenancy into a controlled variable.
POOL_CPUS=""; POOL_MEMS=""

# OVERSUB is a ratio, so the arithmetic is awk's rather than the shell's.
if [[ -z "${CPU_POOL:-}" && -n "${OVERSUB:-}" ]]; then
    CPU_POOL="$(awk -v n="$(( NUM_INSTANCES * VCPU_COUNT ))" -v r="$OVERSUB" \
        'BEGIN { if (r !~ /^[0-9.]+$/ || r + 0 <= 0) exit 1
                 c = int(n / r); if (c < n / r) c++
                 print (c < 1 ? 1 : c) }')" \
        || { error "OVERSUB must be a positive number (got '$OVERSUB')"; exit 1; }
fi

# Cleared unconditionally first: the pool lives on the parent cgroup, which
# outlives a run, so one left behind would silently constrain the next.
if (( CGROUP_OK )) && [[ -e "$CGROUP/cpuset.cpus" ]]; then
    echo "" | sudo tee "$CGROUP/cpuset.cpus" >/dev/null 2>&1 || true
fi

if [[ -n "${CPU_POOL:-}" ]]; then
    if ! (( CGROUP_OK )); then
        warn "no cgroup available -- ignoring CPU_POOL, the fleet may run anywhere."
    elif [[ ! -e "$CGROUP/cpuset.cpus" ]]; then
        warn "the cpuset controller is not delegated to $CGROUP -- ignoring CPU_POOL."
        warn "run ./install_cgroup.sh to fix; VMs will still start."
    else
        # A bare integer is a CPU count; anything else is a literal cpuset list.
        # A single-CPU pool therefore has to be written as a range, "3-3".
        if [[ "$CPU_POOL" =~ ^[0-9]+$ ]]; then
            read -r POOL_CPUS POOL_MEMS < <(fc_cpu_pool "$CPU_POOL") || {
                error "a pool of $CPU_POOL CPUs was requested but the host has $(nproc --all)"
                exit 1
            }
        else
            POOL_CPUS="$CPU_POOL"
            POOL_MEMS="$(fc_cpu_nodes "$POOL_CPUS")"
            [[ -n "$POOL_MEMS" ]] || { error "CPU_POOL matches no CPU on this host: '$CPU_POOL'"; exit 1; }
        fi

        echo "$POOL_CPUS" | sudo tee "$CGROUP/cpuset.cpus" >/dev/null || {
            error "could not set the CPU pool to '$POOL_CPUS'"; exit 1; }
        # Bind memory to the nodes the pool sits on, so cross-node access does
        # not add variance that belongs to the host rather than to the workload.
        echo "$POOL_MEMS" | sudo tee "$CGROUP/cpuset.mems" >/dev/null \
            || warn "could not set cpuset.mems -- memory is not node-bound."
    fi
fi

# Aggregate demand against the CPUs actually available to it. The quota, not
# vcpu_count, is what the fleet can really consume, so the ratio is computed
# from it -- an unmetered run has no ceiling and is simply reported as such.
POOL_SIZE=$(( $(fc_cpu_count "$POOL_CPUS") ))
(( POOL_SIZE )) || POOL_SIZE=$(nproc --all)

if [[ -n "$POOL_CPUS" ]]; then
    echo "CPU pool: $POOL_CPUS  ($POOL_SIZE cpus, node(s) $POOL_MEMS)"
else
    echo "CPU pool: whole host ($POOL_SIZE cpus)"
fi

if [[ "$CPU_MAX" == max ]]; then
    warn "instances are unmetered (cpu.max=max) -- they are not held to the Lambda CPU allocation."
else
    DEMAND="$(awk -v q="$CPU_MAX" -v p="$CPU_PERIOD_US" -v n="$NUM_INSTANCES" \
        'BEGIN { printf "%.2f", n * q / p }')"
    RATIO="$(awk -v d="$DEMAND" -v c="$POOL_SIZE" 'BEGIN { printf "%.2f", d / c }')"
    echo "Requested CPU: $DEMAND vcpu over $POOL_SIZE cpus (${RATIO}x)"
    if awk -v r="$RATIO" 'BEGIN { exit !(r > 1) }'; then
        warn "the fleet requests more CPU than the pool holds -- instances will contend."
    fi
fi

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
        sudo rmdir "$CGROUP/vm$k" 2>/dev/null || true
    done
    # Releases the pool back to the whole host, which fc_reserved_cpus reads.
    [[ -e "$CGROUP/cpuset.cpus" ]] && { echo "" | sudo tee "$CGROUP/cpuset.cpus" >/dev/null 2>&1 || true; }
    return 0
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
    echo "Starting Firecracker instance $k on $SOCKET (guest $(fc_guest_ip "$k") via $(fc_tap "$k")) → $console"
    # The subshell enrolls itself, then execs, so the quota binds to the VM
    # process rather than to this launcher.
    (
        if (( CGROUP_OK )); then
            # Read $BASHPID before the pipeline below: in `echo $BASHPID | ...`
            # bash forks for the echo, so it would expand to a child that has
            # already exited, and the kernel rejects a dead PID with ESRCH.
            vm_pid=$BASHPID
            # The pool is inherited from the parent cgroup, so a leaf only has
            # to carry its own quota.
            sudo mkdir -p "$CGROUP/vm$k"
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
