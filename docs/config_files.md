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
| `BUSYBOX_PATH` | Destination path for the downloaded busybox binary on the host | `/tmp/busybox` |
| `ROOTFS_IMAGE` | Filename of the ext4 rootfs image produced by `install_build.sh` | `aws_baseimage.ext4` |

---

## [common.sh](../common.sh)

Network constants and helper functions sourced by the operational scripts (`run_firecracker.sh`, `kill_firecracker.sh`, and everything under `function_scripts/`).

### Network Constants

| Variable | Description | Default |
|---|---|---|
| `API_SOCKET` | Path to the Firecracker Unix API socket | `/tmp/firecracker.socket` |
| `LOGFILE` | Path for Firecracker log output | `./firecracker.log` |
| `TAP_DEV` | Name of the host TAP device bridging host and guest | `tap0` |
| `TAP_IP` | Host-side IP address on the TAP interface | `172.16.0.1` |
| `MASK_SHORT` | Subnet mask in CIDR notation for the TAP network | `/30` |
| `FC_MAC` | Guest MAC address assigned to the virtual network interface | `06:00:AC:10:00:02` |
| `GUEST_IP` | Guest-side IP address inside the microVM | `172.16.0.2` |
| `LAMBDA_PORT` | Port the Lambda Runtime Interface Emulator listens on inside the guest | `8080` |

### Helper Functions

| Function | Signature | Description |
|---|---|---|
| `log` | `log <msg>` | Print an info message in blue |
| `success` | `success <msg>` | Print a success message in green |
| `warn` | `warn <msg>` | Print a warning in yellow |
| `error` | `error <msg>` | Print an error to stderr in red |
| `fc_api` | `fc_api <METHOD> <PATH> <JSON>` | Send a request to the Firecracker API over `$API_SOCKET` via `curl --unix-socket` |
| `ssh_guest` | `ssh_guest [cmd]` | SSH into the guest at `$GUEST_IP` using `$KEY_NAME` with strict-host-checking disabled |
| `scp_to_guest` | `scp_to_guest <local> <remote>` | Copy a file into the guest at `$GUEST_IP` using `$KEY_NAME` |

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

## [vm_config.json](../vm_config.json)

Static Firecracker VM configuration passed to the `--config-file` flag at launch. Edit to change vCPU count, memory, drive paths, or boot arguments.

### `boot-source`

| Field | Description | Value |
|---|---|---|
| `kernel_image_path` | Path to the guest kernel binary | `./vmlinux-6.1.155` |
| `boot_args` | Kernel command-line arguments | See below |
| `initrd_path` | Optional initrd image | `null` |

**`boot_args` parameters:**

| Parameter | Description |
|---|---|
| `console=ttyS0` | Route kernel console output to the first serial port |
| `reboot=k`, `panic=1` | On panic, print a message and halt rather than rebooting |
| `init=/var/runtime/bootstrap` | Use the injected bootstrap wrapper as PID 1 |
| `handler=function.handler` | Lambda handler passed via `/proc/cmdline` to the bootstrap |
| `func_mem_size=256` | Memory size (MB) exposed to the Lambda runtime via `$AWS_LAMBDA_FUNCTION_MEMORY_SIZE` |
| `func_timeout=300` | Timeout (s) exposed to the Lambda runtime via `$AWS_LAMBDA_FUNCTION_TIMEOUT` |
| `nohz=off` | Disable the tickless kernel to improve timer accuracy inside the guest |
| `clocksource=kvm-clock` | Use the KVM paravirtual clock for accurate timekeeping |

### `drives`

| drive_id | `is_root_device` | Path | Description |
|---|---|---|---|
| `rootfs` | `true` | `aws_baseimage.ext4` | Lambda runtime rootfs; mounted as `/dev/vda` inside the guest |
| `function` | `false` | `function.ext4` | Function code drive; mounted at `/var/task` as `/dev/vdb` by the bootstrap |

### `machine-config`

| Field | Description | Value |
|---|---|---|
| `vcpu_count` | Number of virtual CPUs | `2` |
| `mem_size_mib` | Guest memory in MiB | `512` |
| `smt` | Simultaneous multi-threading (hyper-threading) | `false` |
| `track_dirty_pages` | Enable dirty page tracking (for live migration) | `false` |
| `huge_pages` | Huge page backing | `None` |

### `network-interfaces`

| Field | Description | Value |
|---|---|---|
| `iface_id` | Interface identifier | `net1` |
| `host_dev_name` | Host TAP device to attach | `tap0` |
| `guest_mac` | MAC address assigned inside the guest | `06:00:AC:10:00:02` |

---

## [.env](../.env)

Stores a `GITHUB_TOKEN` used as a bearer token when falling back to the GitHub API to download Lambda base image layers. Only needed if `git lfs pull` fails and the repo is being accessed without authentication (subject to GitHub rate limits).

| Variable | Description |
|---|---|
| `GITHUB_TOKEN` | Personal access token with at least `public_repo` read scope |
