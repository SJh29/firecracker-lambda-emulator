# Firecracker Based Lambda Emulator

An AWS Lambda emulator built on [Firecracker](https://github.com/firecracker-microvm/firecracker) microVMs, running actual AWS Lambda base images. In head-to-head benchmarking against real AWS Lambda on identical hardware, observed performance differs by approximately 0.5% in SAAF metrics overall.

## Fidelity vs. real AWS Lambda

SAAF telemetry from the 502.graph-mst benchmark ([`function/function.py`](./function/function.py)), Firecracker vs. real AWS Lambda on matching CPU hardware (`cpuType` `2.50GHz`, n=10000 Firecracker invocations vs. 7234 Lambda invocations):

<table>
<tr>
<td width="33%"><img src="docs/figs/fig3-runtime-ecdf-cpu-2.50GHz.png" alt="Runtime ECDF: Firecracker and AWS Lambda cumulative runtime distributions overlap almost exactly through the 99th percentile" width="100%"></td>
<td width="33%"><img src="docs/figs/fig2-core-timing-distributions-cpu-2.50GHz.png" alt="Core timing distributions: runtime and userRuntime differ by about 0.2%, process_time by about 3.5%, graph_generating_time by about 0.3%" width="100%"></td>
<td width="33%"><img src="docs/figs/fig1-percent-difference-cpu-2.50GHz.png" alt="Signed percent difference by SAAF metric, Firecracker relative to AWS Lambda" width="100%"></td>
</tr>
<tr>
<td align="center"><sub>Runtime ECDF</sub></td>
<td align="center"><sub>Core timing distributions</sub></td>
<td align="center"><sub>Signed % difference by metric</sub></td>
</tr>
</table>

The metrics that reflect actual work (`runtime`, `userRuntime`, `cpuUser`) agree within ~1.5% -- that's the basis for the ~0.5% figure above. The large deltas at the bottom of the third chart (`cpuSteal`, `cpuSoftIrq`, `cpuIdle`, ...) are host CPU-accounting fields read from `/proc/stat` (see [`function/Inspector.py`](./function/Inspector.py)), not workload duration -- a single-tenant Firecracker microVM has essentially no steal time or softirq load to report, so those fields diverge from a shared-tenant Lambda sandbox without implying the benchmark itself ran differently.

## Initialization

The repository contains Firecracker releases for x86_64 architecture, plus everything needed to build a Lambda-compatible guest rootfs from the real [`aws/aws-lambda-base-images`](https://github.com/aws/aws-lambda-base-images/tree/python3.10/x86_64) layers. Install scripts detect host architecture and resolve the matching release automatically.

## Install & Run

Run on a fresh Ubuntu 22.04 host (EC2 metal recommended so cgroup v2 + RAPL power counters are available):

```bash
# ── 0. Prerequisites (one-time, as a sudoer user) ──────────────────────────
sudo apt-get update -y
sudo apt-get install -y git git-lfs          # needed before clone
sudo apt-get install -y build-essential perl # needed by install_build.sh's
                                              # static OpenSSL build; not yet
                                              # installed by install_deps.sh

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
./function_scripts/invoke.sh   # should print the sebs502 mst graph gen benchmark result
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

Installed by `install_deps.sh`: `git`, `git-lfs`, `curl`, `wget`, `jq`, `iproute2`, `iptables`, `e2fsprogs`, `sysstat`, `linux-tools-*`, `lsof`, `python3-matplotlib`, `python3-numpy`.

Assumed already present on the host (not installed by any script here): `sha256sum`/`shasum`, `tar`, `sudo`.

**Not currently installed by any script, but required by `install_build.sh`'s static OpenSSL build:** `build-essential`, `perl`. Install these manually before running `install_build.sh` (see step 0 above) -- see [Install Scripts](./docs/install_docs.md) for detail.

## Concurrency

Instance `k` owns `/tmp/firecracker/<k>.socket`, a writable `/tmp` scratch drive `instances/scratch-<k>.ext4`, `tap<k>`, host IP `172.16.0.<4k+1>` and guest IP `172.16.0.<4k+2>`. The rootfs and function drive are shared read-only. 

## Documentation

- [Install Scripts](./docs/install_docs.md) -- per-script breakdown of `install_deps.sh` → `install_verify.sh`
- [Configuration Files](./docs/config_files.md)
- [Function Setup Scripts](./docs/function_scripts.md)
- [Power Measurement Scripts](./docs/power_scripts.md)