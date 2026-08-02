# Firecracker Based Lambda Emulator

An AWS Lambda emulator built on [Firecracker](https://github.com/firecracker-microvm/firecracker) microVMs, running actual AWS Lambda base images. In head-to-head benchmarking against real AWS Lambda on identical hardware, observed performance differs by approximately 0.5%.

## Initialization

The repository contains Firecracker releases for both ARM and x86_64 architectures, plus everything needed to build a Lambda-compatible guest rootfs from the real [`aws/aws-lambda-base-images`](https://github.com/aws/aws-lambda-base-images/tree/python3.10/x86_64) layers. Install scripts detect host architecture and resolve the matching release automatically.

## Install & Run

Run on a fresh Ubuntu 22.04 host (EC2 metal recommended so cgroup v2 + RAPL power counters are available):

```bash
# ── 0. Prerequisites (one-time, as a sudoer user) ──────────────────────────
sudo apt-get update -y
sudo apt-get install -y git git-lfs   # needed before clone

git clone https://github.com/SJh29/firecracker-lambda-emulator.git
cd firecracker-lambda-emulator

# Confirm cgroup v2 is active (EC2 metal Ubuntu 22.04 default).
# If this prints anything other than `cgroup2fs`, reboot with
# systemd.unified_cgroup_hierarchy=1 in GRUB_CMDLINE_LINUX_DEFAULT.
stat -fc %T /sys/fs/cgroup

# Optional: load the GitHub token used as a fallback by install_download.sh
# (only matters if `git lfs pull` produces pointer stubs).
[[ -f .env ]] && set -a && source .env && set +a

# ── 1. Install (run in order) ───────────────────────────────────────────────
./install_deps.sh       # APT packages (jq, sysstat, linux-tools-*, lsof, etc.)
./install_download.sh   # kernel, Lambda base layers, firecracker tgz, busybox
./install_build.sh      # rootfs ext4, firecracker/jailer binaries,
                         # setup_tap.sh (TAP+NAT), build_function.sh (function.ext4)
./install_cgroup.sh     # cgroup v2 cpu controller in subtree_control
./install_verify.sh     # checks kernel, rootfs, binaries, cgroup readiness
```
### Smoke test: one full launch + one invocation
```bash
sudo ./run_firecracker.sh &   # writes /tmp/firecracker/0.socket
sleep 2
./function_scripts/invoke.sh   # should print the chacha20 benchmark result
sudo ./kill_firecracker.sh

# ── 4 concurrent microVMs ────────────────────────────────────
sudo ./run_firecracker.sh -n 4 &
sleep 3
./function_scripts/invoke.sh -a     # fires all 4 in parallel
./function_scripts/invoke.sh -i 2   # or just instance 2
sudo ./kill_firecracker.sh
```

### Single experiment for general CPU metrics and power measurement at the template defaults
```bash
sudo power-scripts/fc_experiment.sh -n 30 -E 7 -t bg -o experiment_default
```
### Full memory sweep across the AWS Lambda memory breakpoints
```bash
for MEM in 128 256 512 1024 1769 3008 5308 10240; do
    sudo ./kill_firecracker.sh 2>/dev/null || true
    sudo sed -i -E "s/(\"mem_size_mib\"[[:space:]]*:)[[:space:]]*[0-9]+/\1$MEM/" \
        vm_config.template.json
    sudo power-scripts/fc_experiment.sh \
        -n 30 -d 2 -E 12 -t bg \
        -o "experiment_mem${MEM}_$(date -u +%Y%m%d_%H%M%S)"
done

# ── 5. Tarball the results ────────────────────────────────────────────────────
tar -czvf all_exp.tar.gz experiment_*
```

### Dependencies

`git`, `git-lfs`, `curl`, `wget`, `jq`, `iproute2`, `iptables`, `e2fsprogs`, `sysstat`, `linux-tools-*`, `lsof`, `python3-matplotlib`, `sha256sum` / `shasum`, `tar`, `sudo` — all installed by `install_deps.sh`.

## Concurrency

Instance `k` owns `/tmp/firecracker/<k>.socket`, a writable `/tmp` scratch drive `instances/scratch-<k>.ext4`, `tap<k>`, host IP `172.16.0.<4k+1>` and guest IP `172.16.0.<4k+2>`. The rootfs and function drive are shared read-only. 

## Documentation

- [Install Scripts](./docs/install_docs.md) — per-script breakdown of `install_deps.sh` → `install_verify.sh`
- [Configuration Files](./docs/config_files.md)
- [Function Setup Scripts](./docs/function_scripts.md)
- [Power Measurement Scripts](./docs/power_scripts.md)