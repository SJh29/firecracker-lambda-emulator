# Power Measurement Scripts

Scripts in `power-scripts/` for measuring CPU power, frequency, and per-process resource usage while a Firecracker microVM is running. All scripts take a Firecracker API socket path as their first argument and use it to identify the target process.

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
| `SOCKET` | Firecracker API socket path (informational) | `/tmp/firecracker.socket` |
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
| `--socket` | Firecracker API socket path (informational only) | `/tmp/firecracker.socket` |
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
| `SOCKET` | Firecracker API socket path | `/tmp/firecracker.socket` |
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
| `--socket` | Firecracker API socket path used to locate the process PID | `/tmp/firecracker.socket` |
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
