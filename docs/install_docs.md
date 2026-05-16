# Installation Scripts

Run these four scripts in order on a fresh Ubuntu 22.04 host before launching any microVMs.

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
| `/tmp/busybox` | Static busybox binary injected into the guest rootfs |
| `build.env` | Resolved `ARCH`, `LATEST_VERSION`, `CI_VERSION`, and `KERNEL_FILENAME` for use by parts 2 and 3 |

**Notes:**
- Skips any artifact that already exists in the expected location.
- `git-lfs` is installed automatically if missing.
- If `git lfs pull` produces LFS pointer stubs instead of real tar files, the script falls back to the GitHub API. Set `GITHUB_TOKEN` in `.env` to avoid rate-limiting on this fallback.


---

## [install_build.sh](../install_build.sh)

Builds the rootfs image from the downloaded Lambda base image layers and extracts the Firecracker binaries.

**Requires:** `aws-lambda-base-images/` (or a pre-built `aws_baseimage.ext4`), Firecracker archive + checksum, `/tmp/busybox`, and `build.env` — all produced by `install_download.sh`.

**Produces:**

| Output | Description |
|---|---|
| `aws_baseimage.ext4` | 1 GB ext4 rootfs image with Lambda runtime and bootstrap wrapper injected |
| `release-<version>-<arch>/` | Extracted Firecracker release directory |
| `firecracker` | Renamed Firecracker binary in the current directory |
| `jailer` | Renamed jailer binary in the current directory |

**Build steps:**
1. Extracts all `x86_64/*.tar.xz` layers from `aws-lambda-base-images/` into a staging directory.
2. Creates a 1 GB ext4 image from the staging directory with `mkfs.ext4`.
3. Mounts the image and injects a bootstrap wrapper at `/var/runtime/bootstrap` that mounts pseudo-filesystems, configures the guest network (`172.16.0.2/30`), mounts the function drive (`/dev/vdb → /var/task`), and then execs the Lambda entrypoint.
4. Verifies the Firecracker archive SHA256 checksum, extracts it, and renames the binaries.

**Notes:**
- Busybox is necessary as a standalone binary to set up ip and mount the function drive.
- Alternative rootfs may have these binaries present, but python3.10 AWS Baseimage used in this repository doesn't.
---

## [install_verify.sh](../install_verify.sh)

Validates that all required artifacts are present and well-formed. Exits non-zero if any check fails.

| Check | Pass condition |
|---|---|
| Kernel | A `vmlinux-*` file exists |
| Rootfs | A `*.ext4` file exists and passes `e2fsck -fn` |
| Firecracker binary | `./firecracker` or `release-*/firecracker-*` exists |
| Jailer binary | `./jailer` or `release-*/jailer-*` exists |
