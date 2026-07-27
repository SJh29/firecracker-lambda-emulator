# Function Setup Scripts

Scripts for launching Firecracker microVMs and invoking a Lambda function inside them. Run these after the install scripts have completed.

Typical order: `build_function.sh` → `run_firecracker.sh` (separate terminal) → `invoke.sh`. Use `kill_firecracker.sh` to stop the VMs. `run_firecracker.sh` calls `setup_tap.sh` for you.

---

## Concurrency model

Every VM is identified by an integer **instance id** `k`, starting at 0. All of its host-side resources are derived from `k`, so no two instances collide:

| Resource | Instance `k` | Instance 0 | Instance 1 |
|---|---|---|---|
| API socket | `/tmp/firecracker/<k>.socket` | `/tmp/firecracker/0.socket` | `/tmp/firecracker/1.socket` |
| Scratch (`/tmp`) | `instances/scratch-<k>.ext4` | `instances/scratch-0.ext4` | `instances/scratch-1.ext4` |
| Config | `instances/vm_config-<k>.json` | `instances/vm_config-0.json` | `instances/vm_config-1.json` |
| TAP device | `tap<k>` | `tap0` | `tap1` |
| Host IP | `172.16.0.<4k+1>` | `172.16.0.1` | `172.16.0.5` |
| Guest IP | `172.16.0.<4k+2>` | `172.16.0.2` | `172.16.0.6` |
| Guest MAC | `06:00:AC:10:00:<4k+2>` | `...:02` | `...:06` |
| cgroup | `/sys/fs/cgroup/firecracker/vm<k>` | `.../vm0` | `.../vm1` |

**Drive layout — what's shared vs. per-instance:**

| Drive | Guest mount | Sharing | Why |
|---|---|---|---|
| rootfs (`aws_baseimage.ext4`) | `/` | **one shared copy, read-only** | Read-only makes sharing safe and forces all writable state onto `/tmp`, exactly as real Lambda does |
| function (`function.ext4`) | `/var/task` | **one shared copy, read-only** | Function code; Lambda's task root is read-only too |
| scratch (`scratch-<k>.ext4`) | `/tmp` | **per-instance, writable** | The guest's only writable path. Fresh `mkfs` each launch, `nodatacow` on btrfs to keep the write-heavy path off CoW |

Each VM also gets its **own point-to-point /30**, so the host routing table stays unambiguous. Nothing writable is shared, so concurrent VMs can't corrupt each other's disk.

Instance 0 resolves to exactly the old single-VM values, so the previous setup is just the `k=0` case of this one. The last usable /30 is `172.16.0.252`, capping the design at **64 instances** (`k` = 0..63).

The addressing helpers (`fc_socket`, `fc_scratch`, `fc_tap`, `fc_host_ip`, `fc_guest_ip`, `fc_mac`, `fc_instances`) all live in [common.sh](../common.sh) — no script hardcodes these paths.

> A separate benchmark, [temp_reflink_setup.sh](../temp_reflink_setup.sh), instead gives each VM a `cp --reflink=auto` **writable** clone of the whole rootfs (`instances/rootfs-<k>.ext4`) and times create→first-invocation. It's the alternative this shared-rootfs + scratch layout was chosen over; keep it only for the comparison.

---

## [run_firecracker.sh](../run_firecracker.sh)

Starts one or more Firecracker microVMs, each bound to its own API socket and config.

**Requires:** `./firecracker` binary, `./vm_config.template.json`, `aws_baseimage.ext4`, `function.ext4`, `jq`.

Run this in a dedicated terminal — it blocks until the VMs are stopped, and cleans up sockets, scratch drives and TAP devices on exit (including Ctrl-C). The shared read-only rootfs is never touched.

```
sudo ./run_firecracker.sh                    # 1 VM
sudo ./run_firecracker.sh -n 4               # 4 concurrent VMs
sudo ./run_firecracker.sh -n 4 -m 1024       # 4 VMs, 1024 MiB each
sudo ./run_firecracker.sh -n 4 -S 256        # 4 VMs, 256 MiB /tmp each
```

| Flag | Description | Default |
|---|---|---|
| `-n NUM_INSTANCES` | Number of concurrent microVMs (1–64) | `1` |
| `-m MEM_MIB` | Guest memory per VM; also rewrites `func_mem_size` in the boot args | from template (`3538`) |
| `-S SCRATCH_MB` | Size of each VM's writable `/tmp` scratch drive | `128` |

**What it does, per instance:**
1. Creates a fresh `${SCRATCH_MB}` MiB ext4 scratch image → `instances/scratch-<k>.ext4` (`mkfs.ext4` each launch, so `/tmp` starts empty and identical every run). The rootfs is **not** copied — all instances share `aws_baseimage.ext4` read-only.
2. Renders `vm_config.template.json` → `instances/vm_config-<k>.json`, substituting the scratch path, TAP device, MAC, and the `guest_ip=`/`gateway=` kernel boot args.
3. Creates the leaf cgroup `/sys/fs/cgroup/firecracker/vm<k>` and enrolls that VM in it, so the CPU quota is per-instance rather than shared.
4. Launches Firecracker on `/tmp/firecracker/<k>.socket`.

It also invokes `setup_tap.sh -n N` first, marks the scratch directory `nodatacow` on btrfs, and warns if `2 × N` exceeds the host CPU count (contended VMs make the power numbers meaningless).

> If a payload can write more than `-S` MiB to `/tmp` in one invocation, the guest hits `ENOSPC` mid-run — raise `-S`. The chacha20 default writes ~16 MiB, well under 128.

> **CPU quota is off by default.** `cpu.max` is written as `max <period>`. Set `CPU_MAX=$CPU_QUOTA_US` (or export `CPU_MAX`) to enable the memory-proportional quota of 1 vCPU per 1769 MB.

---

## [function_scripts/setup_tap.sh](../function_scripts/setup_tap.sh)

Creates one host TAP device per instance and configures NAT so the guests can reach the internet.

**Requires:** `iproute2` (`ip`), `iptables`, `jq`.

```
sudo ./function_scripts/setup_tap.sh -n 4
```

**What it does:**
1. For each `k` in `0..N-1`: deletes any stale `tap<k>`, then recreates it at `172.16.0.<4k+1>/30`.
2. Enables IPv4 forwarding (`/proc/sys/net/ipv4/ip_forward`).
3. Sets `iptables FORWARD` policy to `ACCEPT`.
4. Adds a single `MASQUERADE` NAT rule on the host's default interface — one rule covers every TAP.

`run_firecracker.sh` calls this automatically. Re-running is safe: stale devices and rules are removed first.

---

## [function_scripts/build_function.sh](../function_scripts/build_function.sh)

Packages everything in the `function/` folder into a small ext4 drive that the guests mount at `/var/task`.

**Requires:** `e2fsprogs` (`mkfs.ext4`), a non-empty `function/` directory.

**Produces:** `function.ext4` (32 MB ext4 image).

One image serves **every** concurrent microVM — the guests mount it read-only, so sharing it is safe and matches Lambda's read-only task root.

Re-run this whenever the function changes. The previous `function.ext4` is always replaced.

---

## [function_scripts/invoke.sh](../function_scripts/invoke.sh)

Sends a JSON payload to the Lambda Runtime Interface Emulator (RIE) inside a guest and prints the response.

**Requires:** A running VM reachable at `172.16.0.<4k+2>:8080`, `curl`, `jq`.

| Flag | Description | Default |
|---|---|---|
| `-i INSTANCE` | Instance id to invoke | `0` |
| `-a` | Invoke **every** running instance concurrently and wait for all of them | off |
| `-p PAYLOAD` | JSON body sent to the invocation endpoint | chacha20 benchmark |
| `-t TIMEOUT` | Maximum wait time in seconds | `300` |

```
./function_scripts/invoke.sh              # instance 0
./function_scripts/invoke.sh -i 2         # instance 2
./function_scripts/invoke.sh -a           # all running instances, in parallel
```

With `-a` the instances are fired simultaneously (not one after another), so they contend for the host the way a real concurrent workload would. Responses are buffered and printed in instance order so parallel output doesn't interleave. Exits non-zero if any response contains an `errorMessage` field or if `curl` times out.

---

## [kill_firecracker.sh](../kill_firecracker.sh)

Cleanly stops **all** running Firecracker microVMs.

Discovers the running instances from the sockets on disk (rather than being told how many there are), sends each a `SendCtrlAltDel`, then force-kills any VMM still alive 3 seconds later — a guest that ignores Ctrl-Alt-Del would otherwise keep its scratch drive and TAP pinned and poison the next launch. Finally it removes the sockets, the TAP devices, and the per-instance scratch drives and configs. The shared read-only rootfs and function drive are left untouched.

If no sockets are found, falls back to `pkill` on the Firecracker process.

| Flag | Description |
|---|---|
| `-k` | Keep the per-instance scratch drives and configs (for post-mortem) |

```
sudo ./kill_firecracker.sh
```
