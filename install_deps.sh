#!/usr/bin/env bash
#
# install_deps.sh -- Install all host dependencies for firecracker-tooling-setup
#                   on Ubuntu 22.04 (EC2 .metal).
#
# Sources requiring each dependency:
#   git, git-lfs    -- install_download.sh  (Lambda base image repo + LFS pull)
#   curl, wget      -- install_download.sh  (kernel, busybox, Firecracker archive)
#   jq              -- function_scripts/setup_tap.sh  (detect host network iface)
#                     function_scripts/invoke.sh      (pretty-print Lambda response)
#   iproute2        -- function_scripts/setup_tap.sh  (ip tuntap/addr/link/route)
#   iptables        -- function_scripts/setup_tap.sh  (NAT masquerade)
#   e2fsprogs       -- install_build.sh               (mkfs.ext4)
#                     install_verify.sh               (e2fsck)
#                     function_scripts/build_function.sh (mkfs.ext4)
#   sysstat         -- power-scripts/fc_pidstat.sh    (pidstat)
#   linux-tools-*   -- power-scripts/fc_turbostat.sh  (turbostat)
#   lsof            -- power-scripts/fc_proc.py        (find PID from socket path)
#   python3-matplotlib -- power-scripts/fc_plot_csv.py (plot RAPL power CSV)

set -euo pipefail

# ─── APT packages ─────────────────────────────────────────────────────────────
APT_PKGS=(
    git
    git-lfs
    curl
    wget
    jq
    iproute2
    iptables
    e2fsprogs
    sysstat
    lsof
    linux-tools-common
    linux-tools-generic
    python3-matplotlib
    python3-numpy
)

echo "Updating package lists..."
sudo apt-get update -y

echo "Installing APT dependencies..."
sudo apt-get install -y "${APT_PKGS[@]}"

# ─── Kernel-matched turbostat ─────────────────────────────────────────────────
# turbostat ships with the kernel-version-specific linux-tools package.
# linux-tools-generic above pulls in a version; if the running kernel has an
# exact package, install it too so the turbostat binary matches the running kernel.
KVER="$(uname -r)"
if apt-cache show "linux-tools-${KVER}" &>/dev/null 2>&1; then
    echo "Installing kernel-matched tools: linux-tools-${KVER}"
    sudo apt-get install -y "linux-tools-${KVER}"
else
    echo "No exact linux-tools-${KVER} package found; linux-tools-generic covers turbostat."
fi

echo
echo "All dependencies installed successfully."
