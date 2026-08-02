# Power Measurement Scripts

Scripts in `power-scripts/` for measuring CPU power, frequency, and per-process resource usage while Firecracker microVMs are running, plus a pipeline for turning the results into plots. Everything except `fc_arch.sh`, `fc_pid.sh`, and `fc_analyze_pkg.py` takes a Firecracker API socket path as its first argument and uses it to identify the target process.

Start with `fc_arch.sh` on a new host to see which collectors will actually work there.

## Concurrent instances

Sockets are per-instance: `/tmp/firecracker/<k>.socket` (see [function_scripts.md](function_scripts.md#concurrency-model)). Every script here defaults to instance 0 — pass another socket path to target a different VM:

```
sudo ./power-scripts/fc_pidstat.sh /tmp/firecracker/2.socket 1 60 vm2.csv
```

The collectors fall into two groups, and `fc_experiment.sh` runs them accordingly:

| Scope | Scripts | Behaviour with N VMs |
|---|---|---|
| **Per-PID / per-cgroup** | `fc_proc.py`, `fc_pidstat.sh`, `fc_perf.sh`, `fc_ml_metrics.sh`, `fc_pressure.py` | One collector per VM. Each resolves its socket to that VM's PID (and its `/sys/fs/cgroup/firecracker/vm<k>` cgroup), so the traces stay cleanly separated. |
| **Host-wide** | `fc_rapl.py`, `fc_turbostat.sh`, `fc_arm_power.py` | One collector for the whole host. RAPL, turbostat, and hwmon measure the CPU package (or board), not a process, so N copies would just re-read the same counters. Their totals cover all VMs together — attribute per-VM energy using the per-instance `proc`/`perf` traces. |

`fc_pid.sh` refuses to guess when it can't map a socket to a PID and more than one Firecracker is running, rather than silently attaching the collectors to the wrong VM. Install `fuser`, `ss` or `lsof` so the socket owner can always be resolved exactly.

---

## [power-scripts/fc_arch.sh](../power-scripts/fc_arch.sh)

Detects host architecture and which power/telemetry sources are actually available, and recommends which collectors to use.

**Usage:**
```
./power-scripts/fc_arch.sh
```

Checks for RAPL (`/sys/class/powercap/intel-rapl*`), hwmon energy sensors, a battery, `turbostat`, and `perf`, then prints a recommendation per collector (works / doesn't / warn) and a machine-readable summary line:

```
FCTOOLS_ENV: family=x86 arch=x86_64 rapl=True hwmon=False battery=False turbostat=True perf=True
```

Notably, `fc_turbostat.sh` is marked incompatible whenever the CPU vendor is `AuthenticAMD` (turbostat is Intel-focused) even if `turbostat` itself is installed — use `fc_rapl.py` there instead.

---

## [power-scripts/fc_pid.sh](../power-scripts/fc_pid.sh)

Shared helper: resolves the PID of the Firecracker process that owns a given API socket. Used internally by `fc_pidstat.sh`, `fc_perf.sh`, `fc_ml_metrics.sh`, `fc_proc.py`, `fc_pressure.py`, and `fc_experiment.sh` — you won't normally call it directly.

**Usage:**
```
./power-scripts/fc_pid.sh [SOCKET_PATH]   # default: /tmp/firecracker/0.socket
```

Resolution order: `fuser` → `ss -xlp` → `lsof -t -U` → (only if exactly one Firecracker process exists) `pgrep -x firecracker`. Every candidate PID is verified against `/proc/<pid>/comm` (must be `firecracker` or `jailer`) before being accepted. If the socket can't be mapped to a PID and more than one Firecracker process is running, it refuses to guess and exits non-zero with diagnostics — install `fuser`, `ss`, or `lsof` so this never has to happen.

---

## [power-scripts/fc_turbostat.sh](../power-scripts/fc_turbostat.sh)

Records system-wide CPU power draw, frequency, temperature, and C-state residency using `turbostat`. x86 only — exits cleanly (code 0) on ARM with a pointer to `fc_arm_power.py`.

**Requires:** `linux-tools-*` (`turbostat`), `sudo`.

**Usage:**
```
sudo ./power-scripts/fc_turbostat.sh [SOCKET] [INTERVAL_SECS] [DURATION_SECS] [OUT_CSV]
```

| Argument | Description | Default |
|---|---|---|
| `SOCKET` | Firecracker API socket path (informational) | `/tmp/firecracker/0.socket` |
| `INTERVAL_SECS` | Sampling interval in seconds (fractional allowed, e.g. `0.01` for 100 Hz) | `1` |
| `DURATION_SECS` | Total recording duration in seconds | `60` |
| `OUT_CSV` | Output CSV path | `turbostat_<timestamp>.csv` |

**Output columns:** `timestamp`, `elapsed_s`, `package_watts`, `dram_watts`, `PkgTmp`, `Busy%`, `Bzy_MHz`, `TSC_MHz`, `CPU%c1`, `CPU%c6` — normalized by `fc_turbostat_to_csv.py` (below) into the same `*_watts` schema `fc_rapl.py` emits, so downstream tools can treat either as the power source.

The script attempts three fallback strategies when `turbostat` encounters a `rapl_perf_init` assertion failure (common on some EC2 metal CPUs):
1. Full columns with default RAPL path.
2. `--no-perf` flag to force MSR-only RAPL access.
3. Drop power columns and keep only frequency/temperature/C-states (use `fc_rapl.py` for power in this case).

---

## [power-scripts/fc_turbostat_to_csv.py](../power-scripts/fc_turbostat_to_csv.py)

Internal helper piped into by `fc_turbostat.sh`; not normally run standalone. Reads `turbostat --Summary`'s whitespace-delimited output on stdin and writes it as `timestamp,elapsed_s,<col>...` CSV, renaming `PkgWatt`/`CorWatt`/`RAMWatt`/`GFXWatt` to `package_watts`/`core_watts`/`dram_watts`/`gfx_watts` so the result matches `fc_rapl.py`'s column convention.

**Usage:**
```
turbostat ... | python3 power-scripts/fc_turbostat_to_csv.py OUT_CSV [INTERVAL_SECS]
```

---

## [power-scripts/fc_rapl.py](../power-scripts/fc_rapl.py)

Samples RAPL (Running Average Power Limit) energy counters from `/sys/class/powercap` and emits per-domain wattage as a CSV. The most reliable power source when available; use `fc_turbostat.sh` or `fc_arm_power.py` as fallbacks when it isn't (no RAPL sysfs, or ARM).

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

Handles counter wraparound (32-bit rollover at 2³²). Exits with an error pointing at `fc_arm_power.py` if no RAPL domains are found on an ARM host.

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

`pidstat` only takes whole-second intervals — sub-second `INTERVAL_SECS` still works elsewhere in the pipeline (e.g. `fc_experiment.sh` at 100 Hz) but this collector is capped at 1 Hz.

---

## [power-scripts/fc_proc.py](../power-scripts/fc_proc.py)

Samples the Firecracker process directly from `/proc/<pid>/` without external tools. Useful when `pidstat` or `turbostat` are unavailable.

**Requires:** Python 3. PID resolution prefers `fc_pid.sh` (bash, same directory); if that's unavailable it falls back to `lsof -t -U` → `ss -xp` → scanning `/proc/*/comm` for a `firecracker` process.

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

---

## [power-scripts/fc_perf.sh](../power-scripts/fc_perf.sh)

Streams hardware PMU counters for the Firecracker process via `perf stat -I` — cycles, instructions, cache references/misses, branch misses, context switches, CPU migrations, and `kvm:kvm_exit`. Not RAPL — power comes from `fc_rapl.py`/`fc_turbostat.sh`, run alongside this rather than combined into one `perf` invocation (a `perf stat -p PID` run can't also read RAPL cleanly).

**Requires:** `perf`, `sudo`, `fc_pid.sh`.

**Usage:**
```
sudo ./power-scripts/fc_perf.sh [SOCKET] [INTERVAL_MS] [DURATION_SECS] [OUT_CSV]
```

| Argument | Description | Default |
|---|---|---|
| `SOCKET` | Firecracker API socket path | `/tmp/firecracker/0.socket` |
| `INTERVAL_MS` | Sampling interval in milliseconds | `1000` |
| `DURATION_SECS` | Total recording duration in seconds | `300` |
| `OUT_CSV` | Output CSV path | `perf_<timestamp>.csv` |

**Output columns (long format, one row per event per interval):** `time_s`, `value`, `unit`, `event`, `runtime_ns`, `pct_running`, `metric_value`, `metric_unit`. Written incrementally — a killed process still leaves partial data on disk. `<OUT_CSV base>.errlog` captures perf's own stderr for diagnostics.

---

## [power-scripts/fc_ml_metrics.sh](../power-scripts/fc_ml_metrics.sh)

A second, `perf`-based collector curated for power modeling: cycles, instructions, cache references/misses, LLC loads/misses (x86) or branch stats (ARM), branch instructions/misses, context switches, CPU migrations, and page faults, chosen per Bircher & John and McCullough et al. as the events that capture most CPU-power variance. Unlike `fc_perf.sh`'s long-format output, this pivots to one **wide** row per interval — more directly usable as ML features.

**Requires:** `perf`, `sudo`, `fc_pid.sh`, Python 3 (used internally for the pivot).

**Usage:**
```
sudo ./power-scripts/fc_ml_metrics.sh [SOCKET] [INTERVAL_MS] [DURATION_SECS] [OUT_CSV]
```

| Argument | Description | Default |
|---|---|---|
| `SOCKET` | Firecracker API socket path | `/tmp/firecracker/0.socket` |
| `INTERVAL_MS` | Sampling interval in milliseconds | `1000` |
| `DURATION_SECS` | Total recording duration in seconds | `60` |
| `OUT_CSV` | Output CSV path | `ml_features_<timestamp>.csv` |

**Output columns:** `elapsed_s`, one column per event (dashes replaced with underscores), plus derived `ipc` (instructions/cycles), `llc_miss_rate` (x86 only), and `branch_miss_rate`.

---

## [power-scripts/fc_pressure.py](../power-scripts/fc_pressure.py)

Samples cgroup v2 PSI (Pressure Stall Information) for the Firecracker process's cgroup — the fraction of time it was stalled on CPU, memory, or IO. High pressure correlates with power-saving C-state residency.

**Requires:** Python 3, cgroup v2, `fc_pid.sh` or `lsof` for PID resolution.

**Usage:**
```
sudo python3 power-scripts/fc_pressure.py [--socket PATH] [--interval SECS] [--duration SECS] [--out CSV]
```

| Argument | Description | Default |
|---|---|---|
| `--socket` | Firecracker API socket path | `/tmp/firecracker/0.socket` |
| `--interval` | Sampling interval in seconds | `1.0` |
| `--duration` | Total recording duration in seconds | `60.0` |
| `--out` | Output CSV path | `pressure_<timestamp>.csv` |

**Output columns:** `timestamp`, `elapsed_s`, then for each of `cpu`/`memory`/`io` that has a PSI file in the process's cgroup: `<resource>_some_avg10`, `_some_avg60`, `_full_avg10`, `_full_avg60`, `_some_total`, `_full_total`.

---

## [power-scripts/fc_arm_power.py](../power-scripts/fc_arm_power.py)

Power/sensor monitor for ARM hosts (Graviton, etc.), which don't expose RAPL. Reads whatever `/sys/class/hwmon/hwmon*/{energy,power,temp,in,fan}*_input` sensors exist. **On AWS Graviton metal there is currently no public per-socket power counter** — this will still run and capture temperatures/fan speeds/voltage rails if present, but may find nothing to report.

**Requires:** Python 3.

**Usage:**
```
sudo python3 power-scripts/fc_arm_power.py [--socket PATH] [--interval SECS] [--duration SECS] [--out CSV]
```

| Argument | Description | Default |
|---|---|---|
| `--socket` | Firecracker API socket path (informational only) | `/tmp/firecracker/0.socket` |
| `--interval` | Sampling interval in seconds | `1.0` |
| `--duration` | Total recording duration in seconds | `60.0` |
| `--out` | Output CSV path | `hwmon_<timestamp>.csv` |

**Output columns:** `timestamp`, `elapsed_s`, one column per discovered sensor (named `<chip>_<label>_{energy_uj,power_w,temp_c,volt_v,fan_rpm}`), plus a derived `..._derived_watts` column for each energy sensor (computed from the energy delta between samples, like `fc_rapl.py`).

---

## [power-scripts/fc_plot_csv.py](../power-scripts/fc_plot_csv.py)

Quick-look plotter for a single `fc_rapl.py`/`fc_turbostat.sh` CSV (wide, `*_watts` columns) or a single `fc_perf.sh` CSV (long format). Auto-detects which one it's looking at. For plotting a full `fc_experiment.sh` output directory instead, use `fc_analyze_pkg.py` below.

**Requires:** Python 3, `matplotlib`.

**Usage:**
```
python3 power-scripts/fc_plot_csv.py rapl.csv                            # plot power
python3 power-scripts/fc_plot_csv.py perf.csv                            # plot perf events
python3 power-scripts/fc_plot_csv.py perf.csv --events cycles,instructions
python3 power-scripts/fc_plot_csv.py perf.csv --rate                     # per-second rate instead of per-interval counts
python3 power-scripts/fc_plot_csv.py rapl.csv --out power.png --domains package-0_watts --no-show
```

| Argument | Description | Default |
|---|---|---|
| `csv` | Input CSV from `fc_rapl.py`/`fc_turbostat.sh` or `fc_perf.sh` | *(required)* |
| `--out` | Output image path | `<csv-stem>.png` |
| `--domains` | (rapl) Restrict plot to specific `*_watts` columns | all detected |
| `--events` | (perf) Comma-separated list of events to plot | all detected |
| `--rate` | (perf) Plot as per-second rate instead of raw per-interval counts | off |
| `--format` | Force `rapl` or `perf` instead of auto-detecting | `auto` |
| `--no-show` | Save image without opening a display window | off |
| `--title` | Custom plot title | `RAPL power — <filename>` / `perf events — <filename>` |

RAPL plots annotate each curve with average wattage, peak wattage, and total energy in joules (average × duration).

---

## [power-scripts/fc_experiment.sh](../power-scripts/fc_experiment.sh)

Runs an end-to-end power-measurement experiment: launches the microVMs, starts every applicable collector, invokes the function N times, then stops the collectors and shuts the VMs down.

**Requires:** `bc`, `sudo`, plus whichever collectors are installed (it skips the ones that aren't — see the scope table above for which run per-instance vs. host-wide).

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

With a single VM (`-N 1`, the default) the per-instance CSVs stay flat in the output directory instead of under `vm0/`, so `fc_analyze_pkg.py` and the other analyzers keep working unchanged.

If instances are already running it reuses them and leaves them up afterwards; if it launched them itself it tears them down via `kill_firecracker.sh`. It refuses to start when the number of running instances is non-zero but smaller than `-N`, rather than half-using a stale set.

---

## [power-scripts/fc_analyze_pkg.py](../power-scripts/fc_analyze_pkg.py)

Turns one or more `fc_experiment.sh` output directories into plots and summary statistics. This is the actual results pipeline — everything above just collects CSVs; this is what reads them back.

> Its own docstring describes it as the "package-power variant of `fc_analyze.py`" for side-by-side comparison — **`fc_analyze.py` is an older script and has been removed as core power was inaccurate to cpu based invocations in firecracker** Use the `--power-domain` flag below (`package` or `core`) on this script instead; it covers both cases.

**Requires:** Python 3, `matplotlib`, `numpy`.

**Usage:**
```
python3 power-scripts/fc_analyze_pkg.py EXP_DIR [EXP_DIR ...] [--out PLOTS_DIR] [--power-domain package|core] [--labels L1 L2 ...] [--timeline-zoom-n N]
```

| Argument | Description | Default |
|---|---|---|
| `dirs` | One or more experiment directories from `fc_experiment.sh` | *(required)* |
| `--out`, `-o` | Output directory for PNGs and stats files | `plots/` |
| `--power-domain` | RAPL domain to analyze: `package` (includes uncore, dominated by C-state residency) or `core`/pp0 (tracks core compute more directly) | `package` |
| `--labels` | Labels for the workload-comparison graph, one per dir | dir names |
| `--timeline-zoom-n` | Invocations shown in the full-resolution timeline zoom | `12` |

Power data comes from `rapl.csv`, falling back to `turbostat.csv` (normalized by `fc_turbostat_to_csv.py`) when RAPL sysfs isn't available — e.g. on EC2 `.metal`. Invocation windows are read from `invocations.csv` and aligned onto the power trace's clock via shared wall-clock timestamps. SAAF telemetry, when present under `EXP_DIR/invocations/*.stdout.log`, supplies runtime and CPU-utilization numbers directly from the function's own reporting; cold starts (`newcontainer=1`) are excluded from all statistics.

**Output** (in `--out`, default `plots/`):

| File | Contents |
|---|---|
| `01_power_timeline.png` / `01b_..._zoom.png` | Power vs. time, invocation bands; overview (decimated) and a full-resolution zoom of the first N invocations |
| `02_idle_vs_active.png` | Idle vs. active power distribution |
| `03_repeatability.png` | Energy-per-invocation across runs (needs 2+ `EXP_DIR`) |
| `04_energy_per_invocation.png` | Per-invocation energy histogram |
| `05_cpu_vs_power_scatter.png` | CPU% vs. power, linear fit |
| `06_linear_baseline.png` / `06b_..._zoom.png` | Residuals of the CPU% linear model over time |
| `07_correlation_heatmap.png` | Correlation of `proc.csv`/`pressure.csv`/`perf.csv` features against power |
| `08_ipc_vs_power.png` | Strongest correlated feature vs. power |
| `09_rapl_domains_stack.png` / `09b_..._zoom.png` | Stacked RAPL domains (needs 2+ domains in the CSV) |
| `10_workload_comparison.png` | Energy across labelled experiments (needs 2+ `EXP_DIR`) |
| `11_cross_run_stats.png` | Mean/std/CV of runtime, power, CPU across runs (needs 2+ `EXP_DIR`) |
| `invocation_stats.txt` / `.md` / `.csv` | Per-invocation mean/std/CV for runtime, CPU%, energy, and power, pooled across all given dirs |

A graph is silently skipped (with a one-line note on stdout) when its required input file or minimum sample count isn't met — e.g. no `07_correlation_heatmap.png` without `proc.csv`, no multi-run graphs with only one `EXP_DIR`.
