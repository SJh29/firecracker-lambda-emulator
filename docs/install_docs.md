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

> **Gap:** `install_build.sh` compiles a static OpenSSL binary from source (`./Configure && make`) and this script does not install a compiler toolchain for it. Install `build-essential` and `perl` manually before running `install_build.sh` -- see its section below.

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
| OpenSSL source tarball (`config.sh`'s `OPENSSL_TARBALL`, `/tmp/openssl-3.5.7.tar.gz` by default) | Source for the static OpenSSL binary `install_build.sh` compiles for the guest's chacha20 benchmark |
| `build.env` | Resolved `ARCH`, `LATEST_VERSION`, `CI_VERSION`, and `KERNEL_FILENAME` for use by parts 2 and 3 |

**Notes:**
- Skips any artifact that already exists in the expected location.
- `git-lfs` is installed automatically if missing.
- If `git lfs pull` produces LFS pointer stubs instead of real tar files, the script falls back to the GitHub API. Set `GITHUB_TOKEN` in `.env` to avoid rate-limiting on this fallback.


---

## [install_build.sh](../install_build.sh)

Builds the rootfs image from the downloaded Lambda base image layers and extracts the Firecracker binaries.

**Requires:** `aws-lambda-base-images/` (or a pre-built `aws_baseimage.ext4`), Firecracker archive + checksum, `tmp/busybox`, OpenSSL source tarball, and `build.env` -- all produced by `install_download.sh`. **Also requires a C compiler toolchain (`build-essential`) and `perl` on the host**, for the static OpenSSL build below -- `install_deps.sh` does not currently install these; install them manually first (see [install_deps.sh](#install_depssh) above).

**Produces:**

| Output | Description |
|---|---|
| Static `openssl` binary (`config.sh`'s `OPENSSL_BIN`, `/tmp/openssl/apps/openssl` by default) | Built once, then copied into the rootfs at `/usr/bin/openssl` |
| `aws_baseimage.ext4` | 1.5 GB ext4 rootfs image with Lambda runtime, bootstrap wrapper, and static OpenSSL injected |
| `release-<version>-<arch>/` | Extracted Firecracker release directory |
| `firecracker` | Renamed Firecracker binary in the current directory |
| `jailer` | Renamed jailer binary in the current directory |

**Build steps:**
1. Builds a static OpenSSL binary from the source tarball (`./Configure no-shared no-dso -static linux-x86_64 && make`) -- skipped if `OPENSSL_BIN` already exists. The AWS base image ships no `openssl`, and the guest's chacha20 benchmark (`function/function.py`) shells out to it.
2. Extracts all `x86_64/*.tar.xz` layers from `aws-lambda-base-images/` into a staging directory.
3. Creates a 1.5 GB ext4 image from the staging directory with `mkfs.ext4`.
4. Mounts the image and copies in the static `busybox` and `openssl` binaries, then injects a bootstrap wrapper at `/var/runtime/bootstrap` that mounts pseudo-filesystems, configures the guest network, mounts the function drive read-only (`/dev/vdb → /var/task`) and the writable scratch drive (`/dev/vdc → /tmp`), and then execs the Lambda entrypoint. It also bakes a static `/etc/resolv.conf` into the image at build time so the read-only rootfs never needs a runtime DNS write.
5. Vendors any guest Python packages listed in `guest-requirements.txt` (e.g. `igraph`) into the rootfs by chrooting into the mounted image and running its own `/var/lang/bin/pip`. Using the guest's pip guarantees the wheels match the guest interpreter (CPython 3.10 / manylinux2014 / x86_64) with no host pip or cross-compilation. The packages land in the guest site-packages, importable by any function.
6. Verifies the Firecracker archive SHA256 checksum, extracts it, and renames the binaries.

**Notes:**
- Busybox is necessary as a standalone binary to set up ip and mount the function drive; openssl is necessary as a standalone binary for the chacha20 benchmark.
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
