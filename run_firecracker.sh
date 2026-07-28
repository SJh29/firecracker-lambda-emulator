#!/bin/bash
# run_firecracker.sh — launch N concurrent Firecracker microVMs and block until
# they exit. Must be run with sudo; Firecracker needs root for /dev/kvm.
#
# Usage: sudo ./run_firecracker.sh [-m MEM_MIB] [-n NUM_INSTANCES] [-S SCRATCH_MB]
#   -m MEM_MIB        Guest memory (MiB). Also rewrites func_mem_size in
#                     boot_args so the guest init agrees with machine-config.
#   -n NUM_INSTANCES  Number of concurrent microVMs (default 1).
#   -S SCRATCH_MB     Size of each VM's writable /tmp scratch drive (default 128).
#
# ── Design ──────────────────────────────────────────────────────────────────
# Every resource a VM touches is either shared and read-only, or private to that
# instance, so N VMs can run at once without interfering:
#
#   shared, read-only   rootfs (aws_baseimage.ext4), function drive
#   per-instance        API socket, scratch drive, TAP device, MAC, guest IP,
#                       cgroup, generated config, console log
#
# A guest's only writable surface is its scratch drive, mounted at /tmp and
# mkfs'd fresh each launch, so a run can neither corrupt the shared images nor
# carry state into the next one. Per-instance names all derive from the instance
# id k via the helpers in common.sh — see the addressing table there.
set -e

# Resolved from the script's own path rather than $PWD or $HOME, so it stays
# correct under sudo.
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
# power numbers meaningless. Warn rather than refuse — it's still runnable.
NPROC=$(nproc)
if (( NUM_INSTANCES * 2 > NPROC )); then
    warn "$NUM_INSTANCES instances need $(( NUM_INSTANCES * 2 )) CPUs but the host has $NPROC — measurements will be contended."
fi

# ── Run directories ─────────────────────────────────────────────────────────
# Firecracker refuses to start if its socket already exists, so the previous
# run's state is cleared rather than reused.
#
# Console logs are the exception: they live outside FC_RUN_DIR so that
# cleanup(), which wipes that directory, can't delete the logs of the run it is
# tearing down. One timestamped directory per launch, plus a `latest` symlink,
# owned by the invoking user so reading them doesn't need sudo.
sudo rm -rf "$API_SOCKET_FOLDER" "$FC_RUN_DIR"
sudo mkdir -p "$API_SOCKET_FOLDER" "$FC_RUN_DIR"

LOG_DIR="$(fc_log_dir)"
LOG_OWNER="${SUDO_USER:-root}"
sudo mkdir -p "$LOG_DIR"
sudo ln -sfn "$LOG_DIR" "$FC_LOG_ROOT/latest"
sudo chown -R "$LOG_OWNER" "$FC_LOG_ROOT" 2>/dev/null || true

# nodatacow keeps the write-heavy /tmp images from fragmenting or paying btrfs
# per-write checksum/CoW overhead, which would land in host package power
# (RAPL/turbostat) and contaminate the measurement. Only affects files created
# afterward, so it has to precede the mkfs below.
command -v chattr &>/dev/null && sudo chattr +C "$FC_RUN_DIR" 2>/dev/null || true

# ── Host networking ─────────────────────────────────────────────────────────
# One TAP per instance; idempotent, so re-running is safe.
sudo bash "$HERE/function_scripts/setup_tap.sh" -n "$NUM_INSTANCES"

# ── Per-instance CPU quota (cgroup v2) ──────────────────────────────────────
# Allocate 1 full vCPU of host CPU time per 1769 MB of guest memory (AWS Lambda
# ratio). vm_config's vcpu_count only creates virtual CPUs inside the guest; the
# real host CPU allocation is enforced here via cpu.max. When guest memory
# crosses 1769 MB the quota exceeds 1 vCPU, so vcpu_count is bumped to
# ceil(mem/1769) or the guest can't schedule across more than one host CPU.
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

# Set to "$CPU_QUOTA_US" to enforce the quota; "max" leaves the VMs unmetered.
CPU_MAX="${CPU_MAX:-max}"

CGROUP=/sys/fs/cgroup/firecracker
CGROUP_OK=1
sudo mkdir -p "$CGROUP" || CGROUP_OK=0
# The parent has to delegate cpu before its children can set cpu.max. Non-fatal:
# with CPU_MAX=max there's no quota to enforce anyway.
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

# ── Per-instance scratch drives and configs ─────────────────────────────────
# The scratch image is mkfs'd every launch so runs stay comparable — the same
# empty filesystem each time, rather than divergence accumulating across runs.
#
# func_mem_size is a kernel boot arg the guest init reads, so it has to track
# mem_size_mib; both are rewritten from the same $MEM_MIB below.
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
    done
}
trap cleanup EXIT INT TERM

# ── Launch ──────────────────────────────────────────────────────────────────
# Consoles go to one file per instance instead of this terminal. Firecracker
# sets its own stdout non-blocking, so once that fd's buffer fills the output is
# dropped with "Failed the write to serial: ... WouldBlock" — which a terminal
# or a pipe shared by N VMs does readily. Writes to a regular file never return
# EAGAIN, so this removes the failure mode rather than hiding it, and keeps
# terminal rendering out of the power measurement.
#
# Firecracker's own diagnostics land in the same file, so a VM that dies at
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
            sudo mkdir -p "$CGROUP/vm$k"
            # Non-fatal: an unmetered VM still runs.
            echo "$CPU_MAX $CPU_PERIOD_US" | sudo tee "$CGROUP/vm$k/cpu.max" >/dev/null \
                || warn "instance $k: could not set cpu.max — running without a CPU quota."
            echo "$vm_pid" | sudo tee "$CGROUP/vm$k/cgroup.procs" >/dev/null \
                || warn "instance $k: could not join $CGROUP/vm$k — running without a CPU quota."
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
