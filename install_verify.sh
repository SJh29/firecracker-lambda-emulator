#!/usr/bin/env bash
#
# Part 3 of 3: Verify that all required artifacts are present and valid.
#
# Checks:
#   - Kernel binary (vmlinux-*) exists
#   - Rootfs (*.ext4) exists and is a valid ext4 filesystem
#   - firecracker binary is present (in current dir or release-* folder)
#   - jailer binary is present (in current dir or release-* folder)
#
# Exits non-zero if any check fails.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build.env"

fail=0

echo "The following files were downloaded and set up:"

# ─── Kernel ──────────────────────────────────────────────────────────────────
KERNEL=$(ls vmlinux-* 2>/dev/null | tail -1)
if [[ -n "$KERNEL" && -f "$KERNEL" ]]; then
  echo "Kernel: $KERNEL"
else
  echo "ERROR: Kernel vmlinux-* does not exist"
  fail=1
fi

# ─── Rootfs ──────────────────────────────────────────────────────────────────
ROOTFS=$(ls *.ext4 2>/dev/null | tail -1)
if [[ -n "$ROOTFS" ]] && e2fsck -fn "$ROOTFS" &>/dev/null; then
  echo "Rootfs: $ROOTFS"
else
  echo "ERROR: ${ROOTFS:-*.ext4} is not a valid ext4 fs"
  fail=1
fi

# ─── Firecracker + jailer binaries ───────────────────────────────────────────
folder="release-${LATEST_VERSION}-${ARCH}"
FIRECRACKER_RELEASE="${folder}/firecracker-${LATEST_VERSION}-${ARCH}"
JAILER_RELEASE="${folder}/jailer-${LATEST_VERSION}-${ARCH}"

if [[ -f "firecracker" ]]; then
  echo "Firecracker Found: '$LATEST_VERSION' (./firecracker)"
elif [[ -f "$FIRECRACKER_RELEASE" ]]; then
  echo "Firecracker Found: '$LATEST_VERSION' ($FIRECRACKER_RELEASE)"
else
  echo "Error: Firecracker not found in current dir or '$folder'." >&2
  fail=1
fi

if [[ -f "jailer" ]]; then
  echo "Jailer Found: ./jailer"
elif [[ -f "$JAILER_RELEASE" ]]; then
  echo "Jailer Found: $JAILER_RELEASE"
else
  echo "Error: Jailer not found in current dir or '$folder'." >&2
  fail=1
fi

# ─── cgroup v2 prerequisites for per-instance CPU quota ──────────────────────
FS_TYPE="$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)"
if [[ "$FS_TYPE" == "cgroup2fs" ]] \
   && grep -qw cpu /sys/fs/cgroup/cgroup.controllers 2>/dev/null \
   && grep -qw cpu /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
  echo "cgroup v2 + cpu controller ready (run_firecracker.sh will set cpu.max per instance)"
else
  echo "ERROR: cgroup v2 cpu controller not ready. Run ./install_cgroup.sh." >&2
  fail=1
fi

echo
if [[ $fail -eq 0 ]]; then
  echo "Firecracker installation verified"
  exit 0
else
  echo "Verification FAILED" >&2
  exit 1
fi