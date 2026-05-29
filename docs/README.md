# Documentation Table of Contents
1. [Install Scripts](./install_docs.md)
2. [Configuration Files](./config_files.md)
3. [Function Setup Scripts](./function_scripts.md)
4. [Power Measurement Scripts](./power_scripts.md)
# Install & Run
```bash
# ── 0. Prerequisites (one-time, as a sudoer user) ──────────────────────────
sudo apt-get update -y
sudo apt-get install -y git git-lfs                       
# needed before clone

git clone https://github.com/SJh29/firecracker-tooling-setup.git
git checkout x86_AWSBaseImageFS
cd firecracker-tooling-setup

# Confirm cgroup v2 is active (EC2 metal Ubuntu 22.04 default).
# If this prints anything other than `cgroup2fs`, reboot with
# systemd.unified_cgroup_hierarchy=1 in GRUB_CMDLINE_LINUX_DEFAULT.
stat -fc %T /sys/fs/cgroup

# Optional: load the GitHub token used as a fallback by install_download.sh
# (only matters if `git lfs pull` produces pointer stubs).
[[ -f .env ]] && set -a && source .env && set +a

# ── 1. Install (run in order) ──────────────────────────────────────────────
./install_deps.sh         
# APT packages (jq, sysstat, linux-tools-*, lsof, etc.)
./install_download.sh     
# kernel, Lambda base layers, firecracker tgz, busybox
./install_build.sh        
# rootfs ext4, firecracker/jailer binaries,
# setup_tap.sh (TAP+NAT), build_function.sh (function.ext4)
./install_cgroup.sh       
# cgroup v2 cpu controller in subtree_control
./install_verify.sh       
# checks kernel, rootfs, binaries, cgroup readiness

# ── 2. Smoke test: one full launch + one invocation ────────────────────────
# In a second terminal (or with -t bg) start Firecracker, then invoke.
sudo ./run_firecracker.sh &        
# writes /tmp/firecracker.socket
sleep 2
./function_scripts/invoke.sh       
# should print {"message":"Hello Sparsh!", ...}
sudo ./kill_firecracker.sh
sudo rm -f /tmp/firecracker.socket

# ── 3. Single experiment at the template defaults (128 MiB) ────────────────
# -t bg is required on a headless EC2 box (no X server for gnome-terminal/xterm).
# -n 30 invocations, -E 12 sets the per-invocation duration estimate so
# collectors run long enough for the whole sweep.
sudo power-scripts/fc_experiment.sh -n 30 -E 7 -t bg -o experiment_default

# ── 4. Full memory sweep — the cgroup work makes this the headline plot ────
# Each step:
#   * Kills any leftover firecracker so we don't reuse a stale instance
#   * Edits mem_size_mib in vm_config.template.json (run_firecracker.sh re-
#     emits vm_config.json each launch and auto-bumps vcpu_count when >1769)
#   * Runs the experiment into its own output directory
# Tiers cover the AWS Lambda breakpoints; trim if your instance is small.
for MEM in 128 256 512 1024 1769 3008 5308 10240; do
    sudo ./kill_firecracker.sh 2>/dev/null || true
    sudo rm -f /tmp/firecracker.socket
    sudo sed -i -E "s/(\"mem_size_mib\"[[:space:]]*:)[[:space:]]*[0-9]+/\1$MEM/" \
        vm_config.template.json
    sudo power-scripts/fc_experiment.sh \
        -n 30 -d 2 -E 12 -t bg \
        -o "experiment_mem${MEM}_$(date -u +%Y%m%d_%H%M%S)"
done

# ── 5. Tarball the results
tar -czvf all_exp.tar.gz experiment_*

```