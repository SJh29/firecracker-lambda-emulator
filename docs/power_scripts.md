# Power Measurement Scripts

Scripts in `power-scripts/` for measuring CPU power, frequency, and per-process resource usage while Firecracker microVMs are running. All scripts take a Firecracker API socket path as their first argument and use it to identify the target process.

## Concurrent instances

Sockets are per-instance: `/tmp/firecracker/<k>.socket` (see [function_scripts.md](function_scripts.md#concurrency-model)). Every script here defaults to instance 0 — pass another socket path to target a different VM:

```
sudo ./power-scripts/fc_pidstat.sh /tmp/firecracker/2.socket 1 60 vm2.csv
```

The collectors fall into two groups, and `fc_experiment.sh` runs them accordingly:

| Scope | Scripts | Behaviour with N VMs |
|---|---|---|
| **Per-PID / per-cgroup** | `fc_proc.py`, `fc_pidstat.sh`, `fc_perf.sh`, `fc_ml_metrics.sh`, `fc_pressure.py` | One collector per VM. Each resolves its socket to that VM's PID (and its `/sys/fs/cgroup/firecracker/vm<k>` cgroup), so the traces stay cleanly separated. |
| **Host-wide** | `fc_rapl.py`, `fc_turbostat.sh`, `fc_arm_power.py`, `fc_battery.py` | One collector for the whole host. RAPL and turbostat measure the CPU package, not a process, so N copies would just re-read the same counters. Their totals cover all VMs together — attribute per-VM energy using the per-instance `proc`/`perf` traces. |

`fc_pid.sh` refuses to guess when it can't map a socket to a PID and more than one Firecracker is running, rather than silently attaching the collectors to the wrong VM. Install `fuser`, `ss` or `lsof` so the socket owner can always be resolved exactly.

---

## [power-scripts/fc_turbostat.sh](../power-scripts/fc_turbostat.sh)

Records system-wide CPU power draw, frequency, temperature, and C-state residency using `turbostat`.

**Requires:** `linux-tools-*` (`turbostat`), `sudo`.

**Usage:**
```
sudo ./power-scripts/fc_turbostat.sh [SOCKET] [INTERVAL_SECS] [DURATION_SECS] [OUT_CSV]
```

| Argument | Description | Default |
|---|---|---|
| `SOCKET` | Firecracker API socket path (informational) | `/tmp/firecracker/0.socket` |
| `INTERVAL_SECS` | Sampling interval in seconds | `1` |
| `DURATION_SECS` | Total recording duration in seconds | `60` |
| `OUT_CSV` | Output CSV path | `turbostat_<timestamp>.csv` |

**Output columns:** `PkgWatt`, `RAMWatt`, `PkgTmp`, `Busy%`, `Bzy_MHz`, `TSC_MHz`, `CPU%c1`, `CPU%c6`

The script attempts three fallback strategies when `turbostat` encounters a `rapl_perf_init` assertion failure (common on some EC2 metal CPUs):
1. Full columns with default RAPL path.
2. `--no-perf` flag to force MSR-only RAPL access.
3. Drop power columns and keep only frequency/temperature/C-states (use `fc_rapl.py` for power in this case).

---

## [power-scripts/fc_rapl.py](../power-scripts/fc_rapl.py)

Samples RAPL (Running Average Power Limit) energy counters from `/sys/class/powercap` and emits per-domain wattage as a CSV. Useful as a fallback when `turbostat` cannot access RAPL.

**Requires:** Python 3, `sudo` (for `/sys/class/powercap` access on some systems).

**Usage:**
```
sudo python3 power-scripts/fc_rapl.py [--socket PATH] [--interval SECS] [--duration SECS] [--out CSV]
```

| Argument | Description | Default |
|---|---|---|
| `--socket` | Firecracker API socket path (informational only) | `/tmp/firecracker/0.socket` |
| `--interval` | Sampling interval in seconds | `1.0` |
| `--duration` | Total recording duration in seconds | `60.0` |
| `--out` | Output CSV path | `rapl_<timestamp>.csv` |

**Output columns:** `timestamp`, `elapsed_s`, `<domain>_watts` (one column per discovered RAPL domain, e.g. `package-0_watts`, `dram_watts`).

Handles counter wraparound (32-bit rollover at 2³²).

---

## [power-scripts/fc_pidstat.sh](../power-scripts/fc_pidstat.sh)

Records per-process CPU, memory, disk I/O, and context-switch statistics for the Firecracker process using `pidstat`.

**Requires:** `sysstat` (`pidstat`), `sudo`, `fc_pid.sh` (resolves PID from socket).

**Usage:**
```
sudo ./power-scripts/fc_pidstat.sh [SOCKET] [INTERVAL_SECS] [DURATION_SECS] [OUT_CSV]
```

| Argument | Description | Default |
|---|---|---|
| `SOCKET` | Firecracker API socket path | `/tmp/firecracker/0.socket` |
| `INTERVAL_SECS` | Sampling interval in seconds | `1` |
| `DURATION_SECS` | Total recording duration in seconds | `60` |
| `OUT_CSV` | Output CSV path | `pidstat_<timestamp>.csv` |

**Output columns:** `epoch`, `UID`, `PID`, `%usr`, `%system`, `%guest`, `%wait`, `%CPU`, `CPU_id`, `minflt_s`, `majflt_s`, `VSZ_KB`, `RSS_KB`, `%MEM`, `kB_rd_s`, `kB_wr_s`, `kB_ccwr_s`, `iodelay`, `cswch_s`, `nvcswch_s`, `Command`

---

## [power-scripts/fc_proc.py](../power-scripts/fc_proc.py)

Samples the Firecracker process directly from `/proc/<pid>/` without external tools. Useful when `pidstat` or `turbostat` are unavailable.

**Requires:** Python 3, `lsof` or `ss` (for PID resolution; falls back to scanning `/proc` if neither is available).

**Usage:**
```
python3 power-scripts/fc_proc.py [--socket PATH] [--interval SECS] [--duration SECS] [--out CSV]
```

| Argument | Description | Default |
|---|---|---|
| `--socket` | Firecracker API socket path used to locate the process PID | `/tmp/firecracker/0.socket` |
| `--interval` | Sampling interval in seconds | `1.0` |
| `--duration` | Total recording duration in seconds | `60.0` |
| `--out` | Output CSV path | `proc_<timestamp>.csv` |

**Output columns:** `timestamp`, `elapsed_s`, `cpu_pct`, `threads`, `vmrss_kb`, `vmpeak_kb`, `vmswap_kb`, `rss_anon_kb`, `read_bytes`, `write_bytes`, `syscr`, `syscw`, `net_rx_bytes_d`, `net_tx_bytes_d`, `fd_count`, `voluntary_ctxt_switches`, `nonvoluntary_ctxt_switches`

PID resolution order: `lsof -t -U <socket>` → `ss -xp` → scan `/proc/*/fdinfo`.

---

## [power-scripts/fc_plot_csv.py](../power-scripts/fc_plot_csv.py)

Plots power-over-time from a `fc_rapl.py` CSV and saves it as a PNG. Auto-detects all `*_watts` columns and annotates each curve with average wattage, peak wattage, and total energy in joules.

**Requires:** Python 3, `python3-matplotlib`.

**Usage:**
```
python3 power-scripts/fc_plot_csv.py <CSV> [--out PNG] [--domains COL ...] [--no-show] [--title TEXT]
```

| Argument | Description | Default |
|---|---|---|
| `CSV` | Input CSV from `fc_rapl.py` | *(required)* |
| `--out` | Output image path | `<csv-stem>.png` |
| `--domains` | Restrict plot to specific `*_watts` columns | all detected |
| `--no-show` | Save image without opening a display window | off |
| `--title` | Custom plot title | `RAPL power — <filename>` |

---

## [power-scripts/fc_experiment.sh](../power-scripts/fc_experiment.sh)

Runs an end-to-end power-measurement experiment: launches the microVMs, starts every applicable collector, invokes the function N times, then stops the collectors and shuts the VMs down.

**Requires:** `bc`, `sudo`, plus whichever collectors are installed (it skips the ones that aren't).

**Usage:**
```
sudo ./power-scripts/fc_experiment.sh [OPTIONS]
```

| Flag | Description | Default |
|---|---|---|
| `-n COUNT` | Number of invocation rounds | `10` |
| `-N NUM_VMS` | Concurrent microVMs (1–64) | `1` |
| `-s SOCKET_DIR` | Firecracker socket directory | `/tmp/firecracker` |
| `-l LAUNCH_SCRIPT` | Path to `run_firecracker.sh` | `../run_firecracker.sh` |
| `-I INVOKE_SCRIPT` | Path to `invoke.sh` | `../function_scripts/invoke.sh` |
| `-d DELAY` | Seconds between rounds | `2` |
| `-r RATE_HZ` | Collector sampling rate (perf floors at 10 ms, so 100 Hz is the practical ceiling) | `100` |
| `-E EST_SECS` | Estimated seconds per invocation; sizes how long collectors run so they outlast the experiment | `10` |
| `-m MEM_MIB` | Guest memory tier, forwarded to `run_firecracker.sh -m` | template default |
| `-o OUTDIR` | Output directory | `experiment_<ts>` |
| `-t TERMINAL` | `gnome-terminal`, `konsole`, `xterm`, `tmux`, `screen`, or `bg` | `auto` |
| `-q` | Don't capture per-invocation stdout/stderr | off |

With `-N > 1`, **each round fires all N instances simultaneously** rather than one after another, so the VMs contend for the host the way a real concurrent workload would. A serial loop would measure something else entirely.

```
sudo ./power-scripts/fc_experiment.sh -N 4 -n 20 -m 1024
```

**Output layout:**

```
experiment_<ts>/
  invocations.csv          # round, instance, start/end ISO + elapsed, duration, exit_code
  invocations/<n>.<k>.*.log
  rapl.csv turbostat.csv   # host-wide, one copy
  vm0/  proc.csv pidstat.csv perf.csv ml_features.csv pressure.csv
  vm1/  ...                # one dir per instance
```

With a single VM (`-N 1`, the default) the per-instance CSVs stay flat in the output directory instead of under `vm0/`, so the existing analyzers keep working unchanged.

If instances are already running it reuses them and leaves them up afterwards; if it launched them itself it tears them down via `kill_firecracker.sh`. It refuses to start when the number of running instances is non-zero but smaller than `-N`, rather than half-using a stale set.
