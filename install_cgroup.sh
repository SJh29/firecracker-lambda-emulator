#!/usr/bin/env bash
#
# install_cgroup.sh -- Verify cgroup v2 prerequisites for per-instance Firecracker
#                     CPU quota enforcement.
#
# Each microVM is launched by run_firecracker.sh inside its own leaf cgroup,
# /sys/fs/cgroup/firecracker/vm<k>, with cpu.max derived from the template's
# mem_size_mib (1 full vCPU per 1769 MB, matching AWS Lambda's CPU-per-memory
# ratio), so concurrent instances each get an independent quota. The parent
# cgroup carries the cpuset naming the CPU pool they share. The cgroups
# themselves are created at run time by run_firecracker.sh; this script's job is
# to confirm the host supports it:
#   - cgroup v2 unified hierarchy mounted at /sys/fs/cgroup
#   - cpu and cpuset controllers available
#   - both enabled in /sys/fs/cgroup/cgroup.subtree_control
#     (required so /sys/fs/cgroup/firecracker can hold a cpuset and its
#      children can set cpu.max)

set -euo pipefail

# ─── 1. Verify cgroup v2 ─────────────────────────────────────────────────────
FS_TYPE="$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)"
if [[ "$FS_TYPE" != "cgroup2fs" ]]; then
    echo "ERROR: /sys/fs/cgroup is not cgroup v2 (got: $FS_TYPE)" >&2
    echo "  On Ubuntu, enable v2 by adding systemd.unified_cgroup_hierarchy=1" >&2
    echo "  to GRUB_CMDLINE_LINUX_DEFAULT and rebuilding GRUB, then reboot." >&2
    exit 1
fi
echo "cgroup v2 confirmed at /sys/fs/cgroup"

# ─── 2. Verify cpu and cpuset controllers available on the host ──────────────
# cpuset backs the shared CPU pool; cpu backs the per-instance quota.
for CTRL in cpu cpuset; do
    if ! grep -qw "$CTRL" /sys/fs/cgroup/cgroup.controllers; then
        echo "ERROR: $CTRL controller not exposed in /sys/fs/cgroup/cgroup.controllers" >&2
        echo "  controllers: $(cat /sys/fs/cgroup/cgroup.controllers)" >&2
        exit 1
    fi
    echo "$CTRL controller available on host"
done

# ─── 3. Ensure cpu and cpuset are enabled in subtree_control ─────────────────
# A cgroup only gets a controller's knobs if its parent has that controller
# enabled for its descendants via subtree_control. Enabling both at the root is
# what gives /sys/fs/cgroup/firecracker its cpuset.cpus and lets its children
# set cpu.max. On systemd hosts this is usually already on; if not, enable it.
for CTRL in cpu cpuset; do
    if grep -qw "$CTRL" /sys/fs/cgroup/cgroup.subtree_control; then
        echo "$CTRL controller already enabled in cgroup.subtree_control"
        continue
    fi
    echo "Enabling $CTRL controller in /sys/fs/cgroup/cgroup.subtree_control..."
    if ! echo "+$CTRL" | sudo tee /sys/fs/cgroup/cgroup.subtree_control >/dev/null 2>&1; then
        echo "ERROR: failed to enable $CTRL in root subtree_control." >&2
        echo "  This usually means the root cgroup still has internal processes," >&2
        echo "  which cgroup v2 forbids when enabling controllers. Re-run this" >&2
        echo "  script after the host has booted, or enable $CTRL on the parent" >&2
        echo "  slice that this shell belongs to (cat /proc/self/cgroup)." >&2
        exit 1
    fi
    echo "$CTRL controller enabled."
done

echo
echo "cgroup prerequisites OK. Per-instance CPU quota is applied at run time"
echo "by run_firecracker.sh, derived from vm_config.template.json mem_size_mib."
