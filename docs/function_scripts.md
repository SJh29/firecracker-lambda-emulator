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
| CPU set | `vcpu_count` whole physical cores | e.g. `0,2` | e.g. `4,6` |

**Drive layout -- what's shared vs. per-instance:**

| Drive | Guest mount | Sharing | Why |
|---|---|---|---|
| rootfs (`aws_baseimage.ext4`) | `/` | **one shared copy, read-only** | Read-only makes sharing safe and forces all writable state onto `/tmp`, exactly as real Lambda does |
| function (`function.ext4`) | `/var/task` | **one shared copy, read-only** | Function code; Lambda's task root is read-only too |
| scratch (`scratch-<k>.ext4`) | `/tmp` | **per-instance, writable** | The guest's only writable path. Fresh `mkfs` each launch, `nodatacow` on btrfs to keep the write-heavy path off CoW |

Each VM also gets its **own point-to-point /30**, so the host routing table stays unambiguous. Nothing writable is shared, so concurrent VMs can't corrupt each other's disk.

Instance 0 resolves to exactly the old single-VM values, so the previous setup is just the `k=0` case of this one. The last usable /30 is `172.16.0.252`, capping the design at **64 instances** (`k` = 0..63).

The addressing helpers (`fc_socket`, `fc_scratch`, `fc_tap`, `fc_host_ip`, `fc_guest_ip`, `fc_mac`, `fc_instances`) all live in [common.sh](../common.sh) -- no script hardcodes these paths. The CPU topology helpers (`fc_core_pool`, `fc_reserved_cpus`, `fc_free_cpus`) live there too.

> A separate benchmark, [temp_reflink_setup.sh](../temp_reflink_setup.sh), instead gives each VM a `cp --reflink=auto` **writable** clone of the whole rootfs (`instances/rootfs-<k>.ext4`) and times create→first-invocation. It's the alternative this shared-rootfs + scratch layout was chosen over; keep it only for the comparison.

---

## [run_firecracker.sh](../run_firecracker.sh)

Starts one or more Firecracker microVMs, each bound to its own API socket and config.

**Requires:** `./firecracker` binary, `./vm_config.template.json`, `aws_baseimage.ext4`, `function.ext4`, `jq`.

Run this in a dedicated terminal -- it blocks until the VMs are stopped, and cleans up sockets, scratch drives and TAP devices on exit (including Ctrl-C). The shared read-only rootfs is never touched.

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
| `-u` | Run unmetered (`cpu.max=max`) instead of enforcing the Lambda quota | off |

| Env | Description | Default |
|---|---|---|
| `PIN_CPUS` | `1`/`0` forces per-instance CPU pinning on/off | on at ≥ 1769 MiB, off below |
| `CPU_MAX` | Raw `cpu.max` quota; overrides both the default and `-u` | -- |

**What it does, per instance:**
1. Creates a fresh `${SCRATCH_MB}` MiB ext4 scratch image → `instances/scratch-<k>.ext4` (`mkfs.ext4` each launch, so `/tmp` starts empty and identical every run). The rootfs is **not** copied -- all instances share `aws_baseimage.ext4` read-only.
2. Renders `vm_config.template.json` → `instances/vm_config-<k>.json`, substituting the scratch path, TAP device, MAC, and the `guest_ip=`/`gateway=` kernel boot args.
3. Creates the leaf cgroup `/sys/fs/cgroup/firecracker/vm<k>` and enrolls that VM in it, so the CPU quota is per-instance rather than shared.
4. Launches Firecracker on `/tmp/firecracker/<k>.socket`, with its console redirected to `logs/<timestamp>/console-<k>.log`.

### CPU quota and pinning

`cpu.max` is set to `mem_size_mib / 1769` vCPUs per instance -- AWS Lambda's CPU-per-memory ratio -- so a guest gets the same share of a core that the equivalent Lambda would. `-u` removes the cap; use it only when the run is not being compared against Lambda.

The quota governs *how much* CPU a VM gets, not *which* CPUs it runs on, so each instance also gets a `cpuset` of `vcpu_count` whole physical cores. Hyperthread siblings are left idle and a VM's cores never straddle a NUMA node, which keeps concurrent instances from contending for execution units and keeps core assignment stable between runs. Pinning is skipped with a warning if the host has fewer physical cores than `N × vcpu_count`.

Pinning is **off by default below 1769 MiB**. At that point the quota is already less than one full vCPU, so a dedicated core per instance would sit mostly idle and would cap the instance count at the host's physical core count for no benefit -- the quota alone is enough. Above it, set `PIN_CPUS=0` to turn pinning off, or `PIN_CPUS=1` to force it on at low memory.

Both need the `cpu` and `cpuset` controllers delegated -- run [install_cgroup.sh](../install_cgroup.sh) once to check.

It also invokes `setup_tap.sh -n N` first, marks the scratch directory `nodatacow` on btrfs, and warns if `2 × N` exceeds the host CPU count (contended VMs make the power numbers meaningless).

### Console logs

Each launch creates `logs/<YYYYmmdd-HHMMSS>/`, with one `console-<k>.log` per instance, plus a `logs/latest` symlink to the current run. Unlike `instances/`, these are **not** deleted on shutdown, and they are chowned back to `$SUDO_USER` so they can be read without sudo.

```
tail -f logs/latest/console-0.log
```

Each file holds that VM's guest kernel messages, the bootstrap wrapper's output (drive mounts, guest IP, handler), the Lambda RIE's per-invocation `START` / `END` / `REPORT` lines -- `REPORT` carries `Duration` and `Max Memory Used`, which pair naturally with the power traces -- and Firecracker's own log lines. **Nothing from the VMs appears on the launcher's terminal any more**, so check the log if an instance dies at startup.

> **Why files rather than the terminal.** Firecracker sets its own stdout to `O_NONBLOCK` at startup, because the 8250 serial device is written from the vCPU thread and a blocking write to a slow console would stall the guest. When the fd's buffer fills, `write()` returns `EAGAIN` and the bytes are silently dropped, logged as `Failed the write to serial: IOError(Os { code: 11, kind: WouldBlock, ... })`. A terminal or a pipe (`fc_experiment.sh` tees the launcher through one, 64 KiB buffer) fills easily -- all N VMs inherited a *single* stdout, and boot and invocation bursts are exactly when the consumer falls behind. Writes to a regular file ignore `O_NONBLOCK` and never return `EAGAIN`, so per-instance log files remove the failure mode instead of hiding it, while also de-interleaving concurrent guests and keeping terminal rendering out of the host power measurement.

> If a payload can write more than `-S` MiB to `/tmp` in one invocation, the guest hits `ENOSPC` mid-run -- raise `-S`. The chacha20 default writes ~16 MiB, well under 128.

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
4. Adds a single `MASQUERADE` NAT rule on the host's default interface -- one rule covers every TAP.

`run_firecracker.sh` calls this automatically. Re-running is safe: stale devices and rules are removed first.

---

## [function_scripts/build_function.sh](../function_scripts/build_function.sh)

Packages everything in the `function/` folder into a small ext4 drive that the guests mount at `/var/task`.

**Requires:** `e2fsprogs` (`mkfs.ext4`), a non-empty `function/` directory.

**Produces:** `function.ext4` (32 MB ext4 image).

One image serves **every** concurrent microVM -- the guests mount it read-only, so sharing it is safe and matches Lambda's read-only task root.

Re-run this whenever the function changes. The previous `function.ext4` is always replaced.

---

## [function_scripts/invoke.sh](../function_scripts/invoke.sh)

Sends a JSON payload to the Lambda Runtime Interface Emulator (RIE) inside a guest and prints the response.

**Requires:** A running VM reachable at `172.16.0.<4k+2>:8080`, `curl`, `jq`.

| Flag | Description | Default |
|---|---|---|
| `-i INSTANCE` | Instance id to invoke | `0` |
| `-a` | Invoke **every** running instance concurrently and wait for all of them | off |
| `-p PAYLOAD` | JSON body sent to the invocation endpoint | `{"method": "graph-mst", "size": "1000000"}` |
| `-t TIMEOUT` | Maximum wait time in seconds | `300` |

**What the default payload runs.** [`function/handler.py`](../function/handler.py) dispatches on the payload's `method` field against the benchmarks in [`function/benchmark/`](../function/benchmark/); a missing or unrecognized `method` returns an error instead of running anything. The default payload's `method: "graph-mst"` runs SeBS 502.graph-mst -- builds a Barabási–Albert graph of `size` vertices and computes its spanning tree. `size: 1000000` is a large graph; expect the default smoke-test invocation to take noticeably longer than the chacha20 path. To run the chacha20 benchmark instead:
```bash
./function_scripts/invoke.sh -p '{"method": "chacha20", "rounds": 100000, "password": "benchmarkpass", "seed": 42}'
```

```
./function_scripts/invoke.sh              # instance 0
./function_scripts/invoke.sh -i 2         # instance 2
./function_scripts/invoke.sh -a           # all running instances, in parallel
```

With `-a` the instances are fired simultaneously (not one after another), so they contend for the host the way a real concurrent workload would. Responses are buffered and printed in instance order so parallel output doesn't interleave. Exits non-zero if any response contains an `errorMessage` field or if `curl` times out.

---

## [function_scripts/gen_saaf_functions.sh](../function_scripts/gen_saaf_functions.sh)

Writes one SAAF function JSON per running instance, each pointing at that VM's RIE endpoint.

**Requires:** Running VMs, `jq`.

| Flag | Description | Default |
|---|---|---|
| `-o OUTDIR` | Directory to write into | `saaf/functions` |
| `-N NAME` | Base function name (files get a `-vm<k>` suffix) | `firecracker` |

---

## [function_scripts/run_saaf_experiment.sh](../function_scripts/run_saaf_experiment.sh)

Drives every running microVM concurrently with [saaf_driver.py](../function_scripts/saaf_driver.py) and writes SAAF reports.

**Requires:** Running VMs, the `SAAF` submodule (`git submodule update --init`), `python3` with `requests`, `jq`.

```
./function_scripts/run_saaf_experiment.sh
./function_scripts/run_saaf_experiment.sh -e saaf-experiment/my-experiment.json -o saaf/results/run1
```

| Flag | Description | Default |
|---|---|---|
| `-e EXPERIMENT` | SAAF experiment JSON | `saaf-experiment/experiment-fidelity.json` |
| `-o OUTDIR` | Results directory | `saaf/results/<timestamp>` |
| `-N NAME` | Report file prefix | `firecracker` |

`saaf-experiment/` holds checked-in experiment definitions (tracked in git); `saaf/functions/` and `saaf/results/` hold this script's generated output (git-ignored).

| Env | Description | Default |
|---|---|---|
| `SAAF_DIR` | Path to the SAAF checkout | `SAAF` |

The script itself only discovers instances, generates their function JSONs, and `taskset`s the driver onto CPUs no microVM is using -- the complement of every instance's `cpuset` plus their hyperthread siblings -- so the load generator never competes with a guest for a core. It warns if the instances aren't pinned, and if any has `cpu.max=max` (an unmetered guest isn't held to the Lambda CPU allocation, so its durations aren't comparable).

---

## [function_scripts/saaf_driver.py](../function_scripts/saaf_driver.py)

Replaces SAAF's `faas_runner.py`. Report generation is **not** reimplemented -- `report()` and `write_file()` are imported from the submodule, so the CSVs are the same ones SAAF would produce.

```
python3 function_scripts/saaf_driver.py -f FUNC.json [FUNC.json ...] \
    -e EXPERIMENT.json -o OUTDIR --saaf SAAF [--name PREFIX]
```

**Why not `faas_runner.py`.** It can only ever call `functions[0]`: `experiment_orchestrator.py` passes `callExperiment([func], exp)`, so the per-function fan-out inside `callExperiment` is unreachable and N endpoints cannot be driven from one invocation. Working around that meant one process per VM, flattening raw run directories to re-feed `compile_results.py`, and a no-op `xdg-open` on `PATH` because `compile_results.py` hardcodes `write_file(..., True)` and blocks forever on a headless host. Calling `report()` directly removes all three.

It also drops two upstream landmines: the payload list is sized to `runs` while the thread loop consumes `runs x endpoints` (`IndexError`, swallowed by a bare `except`, leaving threads unstarted), and responses are parsed with `ast.literal_eval`, which rejects JSON `null`/`true`/`false`. The driver sizes payloads correctly and uses `json.loads`.

**Semantics.** `runs` is the total across all endpoints and `threads` is the concurrency, exactly as in SAAF -- so one experiment file describes the same workload on Lambda and here. Each endpoint gets `runs / endpoints` sequential calls with one request in flight, because the RIE serves a single invocation at a time; concurrency comes from the VM count. If `threads` doesn't equal the number of endpoints, the driver says so and uses the endpoint count.

Per-run fields (`1_run_id`, `2_thread_id`, `zAll`, `roundTripTime`, `latency`, the `cpuType`/`cpuModel` concat, and the comma/tab/newline stripping that `report()`'s unquoted CSV writer needs) are ported from `callPostProcessor` unchanged, with one intentional difference: **`endpoint` is always recorded.** SAAF drops it whenever the response carries a `platform` field, which the Inspector always sets -- which is why it was missing from reports before.

**Reading the results.** Output layout:

```
saaf/results/<timestamp>/
  functions/vm<k>.json                  generated endpoints
  <name>-<experiment>-run<i>.csv        one report per iteration
  <name>-<experiment>-run<i>/           that iteration's raw run JSONs
  <name>-<experiment>-COMBINED.csv      iterations past warmupBuffer, merged
  driver.log
```

Group by **`endpoint`** or **`uuid`** -- not `vmID` or `containerID`. `containerID` is the RIE's fixed log-stream name and is identical in every VM; `vmID` is read from a cgroup v1 path the guest doesn't have and comes back empty. `uuid` comes from `/tmp/container-id` on the per-instance scratch drive, so it is unique per VM per launch. For the same reason `newcontainer=1` marks each VM's first call: the scratch drive is re-`mkfs`'d every launch, so a cold start needs a VM relaunch, not just another iteration.

---

## [kill_firecracker.sh](../kill_firecracker.sh)

Cleanly stops **all** running Firecracker microVMs.

Discovers the running instances from the sockets on disk (rather than being told how many there are), sends each a `SendCtrlAltDel`, then force-kills any VMM still alive 3 seconds later -- a guest that ignores Ctrl-Alt-Del would otherwise keep its scratch drive and TAP pinned and poison the next launch. Finally it removes the sockets, the TAP devices, and the per-instance scratch drives and configs. The shared read-only rootfs and function drive are left untouched.

If no sockets are found, falls back to `pkill` on the Firecracker process.

| Flag | Description |
|---|---|
| `-k` | Keep the per-instance scratch drives and configs (for post-mortem) |

```
sudo ./kill_firecracker.sh
```
