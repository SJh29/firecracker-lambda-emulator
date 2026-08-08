# Installation Scripts

Run these scripts in order on a fresh Ubuntu 22.04 host before launching any microVMs:
`install_deps.sh` → `install_download.sh` → `install_build.sh` → `install_cgroup.sh` → `install_verify.sh`.

---

## [install_deps.sh](../install_deps.sh)

Installs all host-side APT packages required by the remaining scripts. Must be run first.

| Package | Purpose |
|---|---|
| `git`, `git-lfs` | Clone and LFS-pull the Lambda base image repo |
| `curl`, `wget` | Download kernel, busybox, and Firecracker release archive |
| `jq` | Detect host network interface (TAP setup) and format Lambda responses |
| `iproute2` | `ip` commands for TAP device creation and routing |
| `iptables` | NAT masquerade for guest outbound traffic |
| `e2fsprogs` | `mkfs.ext4` (rootfs/function drive creation) and `e2fsck` (verification) |
| `sysstat` | `pidstat` for per-process CPU/memory/IO sampling |
| `linux-tools-common`, `linux-tools-generic` | `turbostat` for CPU power and frequency sampling |
| `lsof` | Resolve Firecracker PID from its API socket path |
| `python3-matplotlib` | Plot RAPL power CSV output |

If an exact `linux-tools-$(uname -r)` package exists it is also installed so that `turbostat` matches the running kernel.

> `install_build.sh` vendors prebuilt static `openssl`/`sysbench`/`fio` binaries from `static_build/` -- no compiler toolchain needed on this host to run it. Rebuilding those binaries (see [docs/static_binaries.md](./static_binaries.md)) is a separate, one-off step and needs its own toolchain.

---

## [install_download.sh](../install_download.sh)

Downloads all binary artifacts needed to build the microVM environment.

**Produces:**

| Output | Description |
|---|---|
| `vmlinux-<version>` | Latest Firecracker CI kernel for the host architecture |
| `aws-lambda-base-images/` | Cloned Lambda base image repo with LFS objects pulled |
| `firecracker-<version>-<arch>.tgz` | Firecracker release archive |
| `firecracker-<version>-<arch>.tgz.sha256.txt` | Checksum file for the archive |
| `tmp/busybox` | Static busybox binary injected into the guest rootfs (repo-local, git-ignored) |
| `build.env` | Resolved `ARCH`, `LATEST_VERSION`, `CI_VERSION`, and `KERNEL_FILENAME` for use by parts 2 and 3 |

`openssl`/`sysbench`/`fio` are **not** downloaded here -- they're prebuilt static binaries checked into `static_build/` (see [docs/static_binaries.md](./static_binaries.md)), vendored directly by `install_build.sh`.

**Notes:**
- Skips any artifact that already exists in the expected location.
- `git-lfs` is installed automatically if missing.
- If `git lfs pull` produces LFS pointer stubs instead of real tar files, the script falls back to the GitHub API. Set `GITHUB_TOKEN` in `.env` to avoid rate-limiting on this fallback.


---

## [install_build.sh](../install_build.sh)

Builds the rootfs image from the downloaded Lambda base image layers and extracts the Firecracker binaries.

**Requires:** `aws-lambda-base-images/` (or a pre-built `aws_baseimage.ext4`), Firecracker archive + checksum, `tmp/busybox`, `static_build/{openssl,sysbench,fio}`, and `build.env` -- all produced by `install_download.sh` except `static_build/`, which is checked into the repo (see [docs/static_binaries.md](./static_binaries.md)). No compiler toolchain is needed to run this script.

**Produces:**

| Output | Description |
|---|---|
| `aws_baseimage.ext4` | 1.5 GB ext4 rootfs image with Lambda runtime, bootstrap wrapper, and the static `openssl`/`sysbench`/`fio` binaries injected |
| `release-<version>-<arch>/` | Extracted Firecracker release directory |
| `firecracker` | Renamed Firecracker binary in the current directory |
| `jailer` | Renamed jailer binary in the current directory |

**Build steps:**
1. Checks that `static_build/openssl`, `static_build/sysbench`, and `static_build/fio` all exist, failing fast with a pointer to [docs/static_binaries.md](./static_binaries.md) if not. The AWS base image ships none of them, and the guest benchmarks that shell out to them (`function/benchmark/chacha20.py`, `prime_number.py`, `thread.py`, `readdisk.py`) would otherwise fail at runtime.
2. Extracts all `x86_64/*.tar.xz` layers from `aws-lambda-base-images/` into a staging directory.
3. Creates a 1.5 GB ext4 image from the staging directory with `mkfs.ext4`.
4. Mounts the image and copies in the static `busybox`, `openssl`, `sysbench`, and `fio` binaries, then injects a bootstrap wrapper at `/var/runtime/bootstrap` that mounts pseudo-filesystems, configures the guest network, mounts the function drive read-only (`/dev/vdb → /var/task`) and the writable scratch drive (`/dev/vdc → /tmp`), and then execs the Lambda entrypoint. It also bakes a static `/etc/resolv.conf` into the image at build time so the read-only rootfs never needs a runtime DNS write.
5. Vendors any guest Python packages listed in `guest-requirements.txt` (e.g. `igraph`, `numpy`, `pandas`, `chameleon`, `requests`, `Pillow`) into the rootfs by chrooting into the mounted image and running its own `/var/lang/bin/pip`. Using the guest's pip guarantees the wheels match the guest interpreter (CPython 3.10 / manylinux2014 / x86_64) with no host pip or cross-compilation. The packages land in the guest site-packages, importable by any function.
6. Verifies the Firecracker archive SHA256 checksum, extracts it, and renames the binaries.

**Notes:**
- Busybox is necessary as a standalone binary to set up ip and mount the function drive; openssl, sysbench, and fio are necessary as standalone binaries for the chacha20, prime_number/thread, and readdisk benchmarks respectively.
- The rootfs is 1.5 GB to leave room for the vendored deps. The function's `/tmp` writes no longer land here -- they go to the per-instance scratch drive -- so this size is just runtime + deps. If a large `guest-requirements.txt` overflows it, raise the `truncate -s` size in `install_build.sh` and rebuild.
- Alternative rootfs may have these binaries present, but python3.10 AWS Baseimage used in this repository doesn't.
- The bootstrap takes the guest's address from the kernel cmdline (`guest_ip=` / `gateway=`, written per instance by `run_firecracker.sh`), falling back to `172.16.0.2/30` via `172.16.0.1` when they're absent. This is what lets concurrent microVMs each hold a distinct IP -- **a rootfs built before this change will bring every guest up as `172.16.0.2`, so rebuild it before running more than one instance.**
- **The rootfs is mounted read-only and shared by every concurrent microVM.** The guest's only writable path is `/tmp`, backed by a per-instance scratch drive (`/dev/vdc`) -- same constraint as real Lambda, where `/var/task` is read-only and `/tmp` is the sole writable location. A function that writes anywhere outside `/tmp` (e.g. next to its own code in `/var/task`) will get `EROFS`. `PYTHONDONTWRITEBYTECODE=1` is set so Python doesn't attempt `__pycache__` writes to the read-only rootfs on every cold start.
- The function drive is mounted read-only so a single `function.ext4` can be shared by every concurrent microVM (Lambda's `/var/task` is read-only anyway).
---

## [install_cgroup.sh](../install_cgroup.sh)

Verifies cgroup v2 prerequisites for per-instance CPU quota enforcement and enables the `cpu` controller in `cgroup.subtree_control` if it is not already on. Must be run between `install_build.sh` and `install_verify.sh`.

| Check / action | Detail |
|---|---|
| `/sys/fs/cgroup` is `cgroup2fs` | Aborts if the host is on cgroup v1 |
| `cpu` and `cpuset` listed in `/sys/fs/cgroup/cgroup.controllers` | Host kernel exposes both controllers -- `cpu` backs the quota, `cpuset` backs per-instance CPU pinning |
| `cpu` and `cpuset` listed in `/sys/fs/cgroup/cgroup.subtree_control` | Enables each via `echo +cpu` / `echo +cpuset` if not already set, so child cgroups can write `cpu.max` / `cpuset.cpus` |

The cgroups themselves are created on demand by `run_firecracker.sh`: each microVM gets its own leaf cgroup, `/sys/fs/cgroup/firecracker/vm<k>`, so concurrent instances get **independent** quotas and CPU pinning rather than sharing one. (cgroup v2 forbids processes in a cgroup that has children, so the launcher stays out of the parent and each VM enrols itself in its own leaf.) `cpu.max` is derived from `vm_config.template.json`'s `mem_size_mib` at the AWS Lambda ratio of **1 full vCPU per 1769 MB of guest memory**. When guest memory exceeds 1769 MB, `run_firecracker.sh` also raises `vcpu_count` to `ceil(mem_size_mib / 1769)` so the guest can use the additional host CPU time it has been granted.

> The quota is written as `max` by default (i.e. unlimited) -- set `CPU_MAX=$CPU_QUOTA_US` in `run_firecracker.sh`, or export `CPU_MAX`, to enforce it.

---

## [install_verify.sh](../install_verify.sh)

Validates that all required artifacts are present and well-formed. Exits non-zero if any check fails.

| Check | Pass condition |
|---|---|
| Kernel | A `vmlinux-*` file exists |
| Rootfs | A `*.ext4` file exists and passes `e2fsck -fn` |
| Firecracker binary | `./firecracker` or `release-*/firecracker-*` exists |
| Jailer binary | `./jailer` or `release-*/jailer-*` exists |
| cgroup v2 + cpu controller | `/sys/fs/cgroup` is `cgroup2fs` and `cpu` is enabled in both `cgroup.controllers` and `cgroup.subtree_control` |
