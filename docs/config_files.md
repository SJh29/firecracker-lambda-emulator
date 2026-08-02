# Configuration Files

---

## [config.sh](../config.sh)

Static configuration sourced by all three install scripts. Edit this file to change download targets or switch Lambda runtime.

| Variable | Description | Default |
|---|---|---|
| `RELEASE_URL` | Base GitHub URL for Firecracker releases | `https://github.com/firecracker-microvm/firecracker/releases` |
| `KERNEL_S3_BUCKET_URL` | S3 bucket listing endpoint used to discover the latest `vmlinux-*` key | `http://spec.ccfc.min.s3.amazonaws.com` |
| `KERNEL_DOWNLOAD_BASE` | S3 base URL for downloading a specific kernel key | `https://s3.amazonaws.com/spec.ccfc.min` |
| `LAMBDA_REPO_URL` | AWS Lambda base image source repository | `https://github.com/aws/aws-lambda-base-images.git` |
| `LAMBDA_REPO_BRANCH` | Branch that selects the function language runtime | `python3.10` |
| `LAMBDA_REPO_ARCH_DIR` | Subdirectory within the repo that holds architecture-specific layer tarballs | `x86_64` |
| `LAMBDA_API_URL` | GitHub API base URL used as fallback when `git lfs pull` produces pointer stubs | `https://api.github.com/repos/aws/aws-lambda-base-images` |
| `BUSYBOX_URL` | URL for the static busybox binary injected into the guest rootfs | `https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox` |
| `TMP_DIR` | Repo-local scratch directory for downloads that aren't checked in (git-ignored) | `<repo>/tmp` |
| `BUSYBOX_PATH` | Destination path for the downloaded busybox binary on the host | `${TMP_DIR}/busybox` |
| `OPENSSL_URL` | Source tarball URL for the OpenSSL version `install_build.sh` compiles statically | `openssl-3.5.7` release tarball |
| `OPENSSL_TARBALL` | Download destination for the OpenSSL source tarball | `/tmp/openssl-3.5.7.tar.gz` |
| `OPENSSL_SRC_DIR` | Directory the tarball is extracted into and built from | `/tmp/openssl` |
| `OPENSSL_BIN` | Path to the resulting static `openssl` binary, copied into the rootfs at build time | `/tmp/openssl/apps/openssl` |
| `ROOTFS_IMAGE` | Filename of the ext4 rootfs image produced by `install_build.sh` | `aws_baseimage.ext4` |

---

## [common.sh](../common.sh)

Network constants and helper functions sourced by the operational scripts (`run_firecracker.sh`, `kill_firecracker.sh`, and everything under `function_scripts/`).

### Network Constants

| Variable | Description | Default |
|---|---|---|
| `API_SOCKET_FOLDER` | Directory holding the per-instance API sockets (`<k>.socket`) | `/tmp/firecracker` |
| `FC_RUN_DIR` | Directory holding the per-instance scratch drives and generated configs | `<repo>/instances` |
| `LOGFILE` | Path for Firecracker log output | `./firecracker.log` |
| `NET_PREFIX` | First three octets of the guest network | `172.16.0` |
| `MASK_SHORT` | Subnet mask in CIDR notation for each TAP network | `/30` |
| `MAX_INSTANCES` | Instance-id ceiling (last usable /30 is `172.16.0.252`) | `64` |
| `LAMBDA_PORT` | Port the Lambda Runtime Interface Emulator listens on inside the guest | `8080` |
| `TAP_DEV`, `TAP_IP`, `GUEST_IP`, `FC_MAC` | Back-compat aliases for instance 0 (`tap0`, `172.16.0.1`, `172.16.0.2`, `06:00:AC:10:00:02`) | — |

The rootfs and function drive are **not** per-instance — every VM mounts one shared copy read-only. The only per-instance disk is a small writable **scratch** drive (`scratch-<k>.ext4`) that the guest mounts at `/tmp`; it lives in `FC_RUN_DIR` and is freshly `mkfs`'d each launch. Keeping it out of `/tmp` on the host avoids paying for the copy out of tmpfs/RAM, and on btrfs `run_firecracker.sh` marks the directory `nodatacow` so the write-heavy path doesn't fragment or pay CoW/checksum overhead.

### Instance Addressing

Every host resource a VM owns is derived from its instance id, so no two instances collide. See [function_scripts.md](function_scripts.md#concurrency-model) for the full table.

| Function | Signature | Returns for `k` | Instance 0 |
|---|---|---|---|
| `fc_socket` | `fc_socket [k]` | `/tmp/firecracker/<k>.socket` | `/tmp/firecracker/0.socket` |
| `fc_config` | `fc_config [k]` | `instances/vm_config-<k>.json` | `instances/vm_config-0.json` |
| `fc_scratch` | `fc_scratch [k]` | `instances/scratch-<k>.ext4` (writable `/tmp` drive) | `instances/scratch-0.ext4` |
| `fc_rootfs` | `fc_rootfs [k]` | `instances/rootfs-<k>.ext4` — used **only** by the reflink benchmark (`temp_reflink_setup.sh`); the main path shares one read-only rootfs | `instances/rootfs-0.ext4` |
| `fc_tap` | `fc_tap [k]` | `tap<k>` | `tap0` |
| `fc_host_ip` | `fc_host_ip [k]` | `172.16.0.<4k+1>` | `172.16.0.1` |
| `fc_guest_ip` | `fc_guest_ip [k]` | `172.16.0.<4k+2>` | `172.16.0.2` |
| `fc_mac` | `fc_mac [k]` | `06:00:AC:10:00:<4k+2>` | `06:00:AC:10:00:02` |
| `fc_instances` | `fc_instances` | Ids of the VMs currently up, ascending, one per line — derived from the sockets on disk, so any script can discover the running set without being told how many were launched | — |
| `fc_check_instance` | `fc_check_instance <k>` | Non-zero (with an error) if `k` is not an integer in `0..63` | — |

### Helper Functions

| Function | Signature | Description |
|---|---|---|
| `log` | `log <msg>` | Print an info message in blue |
| `success` | `success <msg>` | Print a success message in green |
| `warn` | `warn <msg>` | Print a warning in yellow |
| `error` | `error <msg>` | Print an error to stderr in red |
| `fc_api` | `fc_api <METHOD> <PATH> <JSON> [INSTANCE]` | Send a request to instance `INSTANCE`'s Firecracker API (default `0`) via `curl --unix-socket` |
| `ssh_guest` | `ssh_guest [-i INSTANCE] [cmd]` | SSH into instance `INSTANCE`'s guest using `$KEY_NAME` with strict-host-checking disabled |
| `scp_to_guest` | `scp_to_guest [-i INSTANCE] <local> <remote>` | Copy a file into instance `INSTANCE`'s guest using `$KEY_NAME` |

---

## [build.env](../build.env)

Intermediate environment variables written by `install_download.sh` and sourced by `install_build.sh` and `install_verify.sh`. Not intended to be edited manually.

| Variable | Description |
|---|---|
| `ARCH` | Host machine architecture (e.g. `x86_64`) |
| `LATEST_VERSION` | Latest Firecracker release tag (e.g. `v1.15.1`) |
| `CI_VERSION` | Version string without patch level, used to locate kernel artifacts on S3 |
| `KERNEL_FILENAME` | Resolved kernel filename (e.g. `vmlinux-6.1.155`) |

---

## [vm_config.template.json](../vm_config.template.json)

The Firecracker VM configuration **template**. Edit this to change vCPU count, memory, drive settings, or boot arguments.

`run_firecracker.sh` renders one config per instance from it — `instances/vm_config-<k>.json` — substituting the placeholders below, and passes each to the matching Firecracker process via `--config-file`. The rendered files are generated artifacts: don't edit them, they're overwritten on every launch and deleted on shutdown.

| Placeholder | Replaced with | Example (`k=1`) |
|---|---|---|
| `@ROOT@` | Absolute path to the repo | `/home/ubuntu/tooling-setup` |
| `@ROOTFS@` | The shared read-only base rootfs (same for every instance) | `.../aws_baseimage.ext4` |
| `@SCRATCH@` | That instance's private writable `/tmp` scratch drive | `.../instances/scratch-1.ext4` |
| `@TAP@` | That instance's TAP device | `tap1` |
| `@MAC@` | That instance's guest MAC | `06:00:AC:10:00:06` |
| `@GUEST_IP@` | That instance's guest IP | `172.16.0.6` |
| `@HOST_IP@` | That instance's host IP (the guest's gateway) | `172.16.0.5` |

### `boot-source`

| Field | Description | Value |
|---|---|---|
| `kernel_image_path` | Path to the guest kernel binary | `./vmlinux-6.1.155` |
| `boot_args` | Kernel command-line arguments | See below |
| `initrd_path` | Optional initrd image | `null` |

**`boot_args` parameters:**

| Parameter | Description |
|---|---|
| `console=ttyS0` | Route kernel console output to the first serial port. Firecracker forwards that port to its own stdout, which `run_firecracker.sh` redirects to `logs/<timestamp>/console-<k>.log`. Since PID 1 is the bootstrap wrapper, it inherits this console, so the wrapper's output and the Lambda RIE's `START`/`END`/`REPORT` lines end up in the same file |
| `reboot=k`, `panic=1` | On panic, print a message and halt rather than rebooting |
| `init=/var/runtime/bootstrap` | Use the injected bootstrap wrapper as PID 1 |
| `handler=function.handler` | Lambda handler passed via `/proc/cmdline` to the bootstrap |
| `func_mem_size=3538` | Memory size (MB) exposed to the Lambda runtime via `$AWS_LAMBDA_FUNCTION_MEMORY_SIZE`. Kept in sync with `mem_size_mib` by `run_firecracker.sh -m` |
| `func_timeout=300` | Timeout (s) exposed to the Lambda runtime via `$AWS_LAMBDA_FUNCTION_TIMEOUT` |
| `guest_ip=@GUEST_IP@` | Guest IP the bootstrap assigns to `eth0`. Per-instance, so concurrent VMs don't collide |
| `gateway=@HOST_IP@` | Default route the bootstrap installs (the host end of that VM's /30) |
| `nohz=off` | Disable the tickless kernel to improve timer accuracy inside the guest |
| `clocksource=kvm-clock` | Use the KVM paravirtual clock for accurate timekeeping |

The bootstrap parses `guest_ip` and `gateway` out of `/proc/cmdline`, falling back to `172.16.0.2`/`172.16.0.1` if absent — so a rootfs built before this change still boots as instance 0.

### `drives`

| drive_id | `is_root_device` | `is_read_only` | Path | Description |
|---|---|---|---|---|
| `rootfs` | `true` | `true` | `@ROOTFS@` → `aws_baseimage.ext4` | Lambda runtime rootfs, mounted as `/dev/vda`. **Shared read-only** — one copy for all instances. Read-only is what makes sharing safe, and it forces all writable state onto `/tmp` (the scratch drive), matching real Lambda |
| `function` | `false` | `true` | `function.ext4` | Function code drive, mounted at `/var/task` as `/dev/vdb`. **Shared** across all instances — read-only, as Lambda's task root is |
| `scratch` | `false` | `false` | `@SCRATCH@` → `instances/scratch-<k>.ext4` | Writable scratch, mounted at `/tmp` as `/dev/vdc`. **Per-instance** — the guest's only writable path. Freshly `mkfs`'d each launch (`-S` sets the size, default 128 MiB); `nodatacow` on btrfs |

### `machine-config`

| Field | Description | Value |
|---|---|---|
| `vcpu_count` | Number of virtual CPUs. Raised to `ceil(mem_size_mib / 1769)` by `run_firecracker.sh` when memory exceeds 1769 MB | `2` |
| `mem_size_mib` | Guest memory in MiB (per instance) | `3538` |
| `smt` | Simultaneous multi-threading (hyper-threading) | `false` |
| `track_dirty_pages` | Enable dirty page tracking (for live migration) | `false` |
| `huge_pages` | Huge page backing | `None` |

### `network-interfaces`

| Field | Description | Value |
|---|---|---|
| `iface_id` | Interface identifier | `net1` |
| `host_dev_name` | Host TAP device to attach | `@TAP@` → `tap<k>` |
| `guest_mac` | MAC address assigned inside the guest | `@MAC@` → `06:00:AC:10:00:<4k+2>` |

---

## [.env](../.env)

Stores a `GITHUB_TOKEN` used as a bearer token when falling back to the GitHub API to download Lambda base image layers. Only needed if `git lfs pull` fails and the repo is being accessed without authentication (subject to GitHub rate limits).

| Variable | Description |
|---|---|
| `GITHUB_TOKEN` | Personal access token with at least `public_repo` read scope |
