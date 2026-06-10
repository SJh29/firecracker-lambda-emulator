#!/usr/bin/env python3
"""
fc_analyze_pkg.py — PACKAGE-POWER variant of fc_analyze.py.

Identical to fc_analyze.py except it uses the RAPL 'package' domain as the
power target instead of 'core'. Kept for side-by-side comparison of the two
power signals. All other logic (wall-clock invocation alignment, perf feature
pivoting, the graph set) is the same.

Usage:
  python3 fc_analyze_pkg.py EXP_DIR [EXP_DIR ...] [--out PLOTS_DIR]

  Single run:  python3 fc_analyze_pkg.py run6 --out plots_pkg
  Compare:     python3 fc_analyze.py     run6 --out plots_core
               python3 fc_analyze_pkg.py run6 --out plots_pkg

Generates PNGs in --out (default: ./plots/) for the feasibility-study
graphs:

  01_power_timeline.png        — power vs time, invocation bands (graph 1)
  02_idle_vs_active.png        — distribution comparison (graph 2)
  03_repeatability.png         — joules-per-invocation across runs (graph 3)
  04_energy_per_invocation.png — per-invocation energy histogram (graph 4)
  05_cpu_vs_power_scatter.png  — graph 5
  06_linear_baseline.png       — residuals over time (graph 6)
  07_correlation_heatmap.png   — features × power (graph 7)
  08_ipc_vs_power.png          — strongest PMU feature scatter (graph 8)
  09_rapl_domains_stack.png    — package + dram + core stacked area (graph 9)
  10_workload_comparison.png   — across labelled experiments (graph 10)
  11_cross_run_stats.png       — mean/std/CV of runtime, power, CPU across runs (graph 11)

How cross-run statistics are calculated (graph 11 / console table)
--------------------------------------------------------------------
SAAF telemetry (per-invocation JSON in [EXP_DIR]/invocations/*.stdlog) is the
primary source for runtime and CPU utilisation.  Cold starts (newcontainer==1)
are excluded so only warm-start invocations contribute.

  Runtime   — SAAF "runtime" field (ms → s).  We take the mean of all
               warm-start invocations in a run to get one value per run.

  CPU util  — SAAF cpu jiffies captured during the invocation window:
               active = cpuUsr + cpuNice + cpuKrn + cpuIowait
                      + cpuIrq + cpuSoftIrq + vmcpusteal
               total  = active + cpuIdle
               cpu%   = active / total * 100
               Mean across warm invocations → one value per run.

  Power     — mean package-power (W) during active windows from RAPL/turbostat
               (SAAF does not report power).  One value per run.

With one value per run for each metric we have a small sample
  x₁, x₂, …, xₙ   (n = number of experiment dirs)

  cross-run mean  μ  = (1/n) Σ xᵢ
  cross-run std   σ  = sqrt[ (1/(n-1)) Σ (xᵢ − μ)² ]   (sample std, ddof=1)
  CV              c  = σ / μ × 100  (%)

CV < 5 % → highly repeatable; 5–15 % → moderate; > 15 % → noisy.
"""

import argparse, csv, json, re as _re, sys
from pathlib import Path
from statistics import mean

try:
    import matplotlib
    matplotlib.use("Agg")   # non-interactive; writes PNGs without a display
    import matplotlib.pyplot as plt
    import numpy as np
except ImportError:
    sys.exit("ERROR: pip install matplotlib numpy")

# np.trapz was renamed to np.trapezoid in NumPy 2.0
_trapz = getattr(np, "trapezoid", None) or getattr(np, "trapz")

# ── I/O ─────────────────────────────────────────────────────

def load_csv(path):
    if not path.exists(): return []
    with open(path) as f:
        return list(csv.DictReader(f))

def load_power(exp_dir):
    """Power-source rows in the rapl.csv schema (timestamp, elapsed_s, *_watts).
    Prefer RAPL; fall back to turbostat.csv (normalized to the same schema by
    fc_turbostat_to_csv.py) on hosts without RAPL sysfs, e.g. EC2 .metal."""
    rows = load_csv(exp_dir / "rapl.csv")
    if rows:
        return rows
    return load_csv(exp_dir / "turbostat.csv")

def num(v):
    try: return float(v)
    except: return None

def parse_iso(s):
    """Parse an ISO-8601 timestamp to epoch seconds. Handles 'Z' and +00:00."""
    if not s:
        return None
    s = s.strip()
    try:
        # datetime.fromisoformat handles +00:00; normalize trailing Z
        from datetime import datetime
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        return datetime.fromisoformat(s).timestamp()
    except Exception:
        return None

def colvals(rows, key):
    """Return (xs, ys) pairs filtering None."""
    out_x, out_y = [], []
    for r in rows:
        x = num(r.get("elapsed_s"))
        y = num(r.get(key))
        if x is not None and y is not None:
            out_x.append(x); out_y.append(y)
    return np.array(out_x), np.array(out_y)

def rapl_clock_origin(exp_dir):
    """
    Return the epoch time corresponding to RAPL elapsed_s = 0.
    RAPL rows have both an absolute 'timestamp' and a relative 'elapsed_s';
    origin_epoch = timestamp_epoch - elapsed_s for any row.
    """
    rows = load_power(exp_dir)
    for r in rows:
        ep = parse_iso(r.get("timestamp"))
        el = num(r.get("elapsed_s"))
        if ep is not None and el is not None:
            return ep - el
    return None

def load_invocation_windows(exp_dir):
    """
    Return invocation windows as (start, end) tuples expressed in the SAME
    elapsed_s timeline as rapl.csv.

    invocations.csv and rapl.csv use independent elapsed_s origins (the
    collectors start a few seconds before the invocation loop). We reconcile
    them via the shared wall-clock timestamps:

        invocation_elapsed_in_rapl_frame = invocation_epoch - rapl_origin_epoch

    Falls back to raw start/end_elapsed_s if timestamps are unavailable.
    """
    rows = load_csv(exp_dir / "invocations.csv")
    if not rows:
        return []

    rapl_origin = rapl_clock_origin(exp_dir)
    out = []

    if rapl_origin is not None:
        # Align via wall clock — the correct path.
        for r in rows:
            s_ep = parse_iso(r.get("start_iso"))
            e_ep = parse_iso(r.get("end_iso"))
            if s_ep is not None and e_ep is not None:
                out.append((s_ep - rapl_origin, e_ep - rapl_origin))
        if out:
            return out

    # Fallback: assume the two elapsed_s clocks share an origin (legacy behavior).
    for r in rows:
        s = num(r.get("start_elapsed_s"))
        e = num(r.get("end_elapsed_s"))
        if s is not None and e is not None:
            out.append((s, e))
    return out

def load_perf_wide(exp_dir):
    """
    fc_perf.sh writes long-format CSV (one row per event per interval):
       time_s,value,unit,event,runtime_ns,pct_running,...
    Pivot to {event_name: (xs, ys)} plus derive ipc / miss-rates.
    Returns a dict: event_or_derived -> (np.array xs, np.array ys)
    """
    rows = load_csv(exp_dir / "perf.csv")
    if not rows:
        return {}
    # group value by event over time
    series = {}  # event -> list[(t, v)]
    for r in rows:
        t = num(r.get("time_s"))
        v = num(r.get("value"))
        ev = (r.get("event") or "").strip()
        if t is None or v is None or not ev:
            continue
        series.setdefault(ev, []).append((t, v))

    out = {}
    for ev, pts in series.items():
        pts.sort()
        xs = np.array([p[0] for p in pts])
        ys = np.array([p[1] for p in pts])
        out[ev] = (xs, ys)

    # Derived features (only if the inputs exist and align in length)
    def derive(name, num_ev, den_ev):
        if num_ev in out and den_ev in out:
            nx, nv = out[num_ev]
            dx, dv = out[den_ev]
            if len(nv) == len(dv) and len(nv) > 0:
                with np.errstate(divide="ignore", invalid="ignore"):
                    ratio = np.where(dv != 0, nv / dv, 0.0)
                out[name] = (nx, ratio)

    derive("ipc", "instructions", "cycles")
    derive("llc_miss_rate", "LLC-load-misses", "cache-references")
    derive("branch_miss_rate", "branch-misses", "instructions")
    return out

def power_col(rapl_rows):
    """
    PACKAGE-POWER VARIANT. Picks the 'package' domain as the power target.

    This is the original behaviour, kept for comparison against the core-power
    analysis. On Intel RAPL the 'package' domain includes uncore + core and is
    dominated by package C-state residency; the 'core' (pp0) domain tracks core
    compute more directly. Use fc_analyze.py for the core-power view.
    """
    if not rapl_rows:
        return None
    cols = list(rapl_rows[0].keys())
    watt_cols = [c for c in cols if c.endswith("_watts")]
    if not watt_cols:
        return None
    # 1. prefer a 'package' domain
    for c in watt_cols:
        if "package" in c.lower():
            return c
    # 2. then core
    for c in watt_cols:
        if "core" in c.lower():
            return c
    # 3. otherwise first available
    return watt_cols[0]

# ── SAAF log parsing ────────────────────────────────────────

_RESP_START = _re.compile(r"^──+\s*Lambda Response\s*──+")
_RESP_END   = _re.compile(r"^──+\s*$")

def load_saaf_logs(exp_dir):
    """
    Parse every *.stdlog under [exp_dir]/invocations/ and return a list of
    SAAF result dicts (one per successfully parsed invocation).

    Log format:
        ── Lambda Response ──────────────────────────────────────
        { ...JSON... }
        ─────────────────────────────────────────────────────────

    Cold starts (newcontainer == 1) are excluded so callers only see
    warm-start observations.
    """
    inv_dir = exp_dir / "invocations"
    if not inv_dir.is_dir():
        return []

    results = []
    for log_file in sorted(inv_dir.glob("*.stdlog")):
        try:
            text = log_file.read_text(errors="replace")
        except OSError:
            continue

        lines = text.splitlines()
        in_block = False
        block_lines = []

        for line in lines:
            if not in_block:
                if _RESP_START.match(line.strip()):
                    in_block = True
                    block_lines = []
            else:
                if _RESP_END.match(line.strip()):
                    # Try to parse accumulated JSON
                    blob = "\n".join(block_lines).strip()
                    try:
                        obj = json.loads(blob)
                        # Exclude cold starts
                        if int(obj.get("newcontainer", 0)) == 0:
                            results.append(obj)
                    except (json.JSONDecodeError, ValueError):
                        pass
                    in_block = False
                else:
                    block_lines.append(line)

    return results

def saaf_runtimes(saaf_records):
    """Return list of warm-start runtimes in seconds (SAAF reports ms)."""
    out = []
    for r in saaf_records:
        v = r.get("runtime")
        if v is not None:
            try:
                out.append(float(v) / 1000.0)
            except (TypeError, ValueError):
                pass
    return out

def saaf_cpu_pcts(saaf_records):
    """
    Return list of warm-start CPU utilisation percentages derived from SAAF
    jiffies fields captured during the invocation window.

    active = cpuUsr + cpuNice + cpuKrn + cpuIowait + cpuIrq + cpuSoftIrq + vmcpusteal
    cpu%   = active / (active + cpuIdle) * 100
    """
    def _f(r, k):
        try: return float(r.get(k, 0) or 0)
        except (TypeError, ValueError): return 0.0

    out = []
    for r in saaf_records:
        active = (_f(r, "cpuUsr") + _f(r, "cpuNice") + _f(r, "cpuKrn") +
                  _f(r, "cpuIowait") + _f(r, "cpuIrq") +
                  _f(r, "cpuSoftIrq") + _f(r, "vmcpusteal"))
        idle   = _f(r, "cpuIdle")
        total  = active + idle
        if total > 0:
            out.append(active / total * 100.0)
    return out

# ── window classification ───────────────────────────────────

def split_active_idle(xs, ys, windows, pad=0.5):
    """Bucket samples into 'active' (inside any window ± pad) or 'idle'."""
    active, idle = [], []
    for x, y in zip(xs, ys):
        is_active = any(s - pad <= x <= e + pad for s, e in windows)
        (active if is_active else idle).append(y)
    return np.array(active), np.array(idle)

def integrate_per_window(xs, ys, windows):
    """Trapezoidal integration of watts within each window → joules."""
    js = []
    for s, e in windows:
        mask = (xs >= s) & (xs <= e)
        if mask.sum() < 2: continue
        js.append(float(_trapz(ys[mask], xs[mask])))
    return np.array(js)

# ── individual plots ────────────────────────────────────────

def plot_timeline(exp_dir, out_dir):
    """Graph 1: power timeline with invocation bands."""
    rapl = load_power(exp_dir)
    if not rapl:
        print("  skip 01: no rapl.csv"); return
    pkg = power_col(rapl)
    if not pkg:
        print("  skip 01: no package power column"); return
    xs, ys = colvals(rapl, pkg)
    windows = load_invocation_windows(exp_dir)

    fig, ax = plt.subplots(figsize=(12, 5))
    ax.plot(xs, ys, linewidth=1.2, color="#1f77b4", label=pkg)
    for s, e in windows:
        ax.axvspan(s, e, alpha=0.15, color="orange")
    if windows:
        ax.axvspan(0, 0, alpha=0.15, color="orange", label="invocation")
    # Idle baseline = median of samples that fall OUTSIDE any invocation window.
    if windows:
        _, idle_samples = split_active_idle(xs, ys, windows)
        idle_baseline = np.median(idle_samples) if len(idle_samples) else np.median(ys)
    else:
        idle_baseline = np.median(ys[:10]) if len(ys) > 10 else np.median(ys)
    ax.axhline(idle_baseline, linestyle="--", color="grey", linewidth=1,
               label=f"idle ~{idle_baseline:.2f}W")
    ax.set_xlabel("Elapsed (s)"); ax.set_ylabel("Power (W)")
    ax.set_title(f"Power timeline with invocations — {exp_dir.name}  [{pkg}]")
    ax.grid(True, alpha=0.3); ax.legend(loc="best", fontsize=9)
    fig.tight_layout()
    fig.savefig(out_dir / "01_power_timeline.png", dpi=140)
    plt.close(fig); print("  ✓ 01_power_timeline.png")

def plot_idle_vs_active(exp_dir, out_dir):
    """Graph 2: idle vs active distribution."""
    rapl = load_power(exp_dir)
    if not rapl: return
    pkg = power_col(rapl)
    if not pkg: return
    xs, ys = colvals(rapl, pkg)
    windows = load_invocation_windows(exp_dir)
    if not windows:
        print("  skip 02: no invocations.csv"); return
    active, idle = split_active_idle(xs, ys, windows)
    if len(active) < 2 or len(idle) < 2:
        print("  skip 02: not enough samples"); return

    fig, ax = plt.subplots(figsize=(8, 5))
    ax.violinplot([idle, active], showmeans=True, showmedians=True)
    ax.set_xticks([1, 2]); ax.set_xticklabels(["idle", "active"])
    ax.set_ylabel("Power (W)")
    ax.set_title(f"Idle vs active power — {exp_dir.name}\n"
                 f"gap = {active.mean()-idle.mean():.2f}W "
                 f"({100*(active.mean()-idle.mean())/idle.mean():.1f}%)")
    ax.grid(True, alpha=0.3, axis="y")
    fig.tight_layout()
    fig.savefig(out_dir / "02_idle_vs_active.png", dpi=140)
    plt.close(fig); print("  ✓ 02_idle_vs_active.png")

def plot_repeatability(exp_dirs, out_dir):
    """Graph 3: energy-per-invocation distributions across runs."""
    if len(exp_dirs) < 2:
        print("  skip 03: needs 2+ experiment dirs"); return
    datasets = []
    labels = []
    for d in exp_dirs:
        rapl = load_power(d)
        if not rapl: continue
        pkg = power_col(rapl)
        if not pkg: continue
        xs, ys = colvals(rapl, pkg)
        windows = load_invocation_windows(d)
        if not windows: continue
        js = integrate_per_window(xs, ys, windows)
        if len(js) >= 2:
            datasets.append(js); labels.append(d.name)
    if len(datasets) < 2:
        print("  skip 03: not enough usable runs"); return

    fig, ax = plt.subplots(figsize=(10, 5))
    parts = ax.violinplot(datasets, showmeans=True, showmedians=True)
    ax.set_xticks(range(1, len(datasets) + 1))
    ax.set_xticklabels(labels, rotation=20, ha="right")
    ax.set_ylabel("Energy per invocation (J)")
    means = [d.mean() for d in datasets]
    stds  = [d.std()  for d in datasets]
    spread = (max(means) - min(means)) / mean(means) * 100
    ax.set_title(f"Repeatability across runs\n"
                 f"mean spread = {spread:.1f}% across {len(datasets)} runs")
    ax.grid(True, alpha=0.3, axis="y")
    fig.tight_layout()
    fig.savefig(out_dir / "03_repeatability.png", dpi=140)
    plt.close(fig); print("  ✓ 03_repeatability.png")

def plot_energy_distribution(exp_dir, out_dir):
    """Graph 4: per-invocation energy histogram."""
    rapl = load_power(exp_dir)
    if not rapl: return
    pkg = power_col(rapl)
    if not pkg: return
    xs, ys = colvals(rapl, pkg)
    windows = load_invocation_windows(exp_dir)
    js = integrate_per_window(xs, ys, windows)
    if len(js) < 2:
        print("  skip 04: not enough invocations"); return

    fig, ax = plt.subplots(figsize=(9, 5))
    ax.hist(js, bins=min(20, max(5, len(js)//2)),
            color="#2ca02c", edgecolor="white", alpha=0.85)
    ax.axvline(js.mean(), color="black", linestyle="--",
               label=f"mean = {js.mean():.2f} J")
    ax.set_xlabel("Energy per invocation (J)")
    ax.set_ylabel("Count")
    cv = js.std() / js.mean() * 100 if js.mean() else 0
    ax.set_title(f"Per-invocation energy — {exp_dir.name}\n"
                 f"n={len(js)}, mean={js.mean():.2f}J, "
                 f"std={js.std():.2f}J, CV={cv:.1f}%")
    ax.legend(); ax.grid(True, alpha=0.3, axis="y")
    fig.tight_layout()
    fig.savefig(out_dir / "04_energy_per_invocation.png", dpi=140)
    plt.close(fig); print("  ✓ 04_energy_per_invocation.png")

def plot_cpu_vs_power(exp_dir, out_dir):
    """Graph 5: cpu% vs power scatter, with linear fit."""
    rapl = load_power(exp_dir)
    proc = load_csv(exp_dir / "proc.csv")
    if not rapl or not proc: return
    pkg = power_col(rapl)
    if not pkg: return

    # Align by elapsed_s (nearest neighbour, 1Hz both)
    xs_p, ws = colvals(rapl, pkg)
    xs_c, cpu = colvals(proc, "cpu_pct")
    if len(xs_p) < 5 or len(xs_c) < 5: return
    # interpolate cpu onto power timestamps
    cpu_aligned = np.interp(xs_p, xs_c, cpu)

    fit = np.polyfit(cpu_aligned, ws, 1)
    r = np.corrcoef(cpu_aligned, ws)[0, 1]

    fig, ax = plt.subplots(figsize=(9, 6))
    ax.scatter(cpu_aligned, ws, alpha=0.5, s=22, color="#1f77b4")
    xx = np.linspace(cpu_aligned.min(), cpu_aligned.max(), 50)
    ax.plot(xx, np.polyval(fit, xx), color="red", linewidth=1.5,
            label=f"linear fit: W = {fit[0]:.3f}·cpu% + {fit[1]:.2f}\n"
                  f"r = {r:.3f}, R² = {r**2:.3f}")
    ax.set_xlabel("CPU %"); ax.set_ylabel("Package power (W)")
    ax.set_title(f"CPU% vs power — {exp_dir.name}")
    ax.legend(loc="best"); ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_dir / "05_cpu_vs_power_scatter.png", dpi=140)
    plt.close(fig); print("  ✓ 05_cpu_vs_power_scatter.png")
    return fit, r  # for reuse in graph 6

def plot_baseline_residuals(exp_dir, out_dir, fit=None):
    """Graph 6: residuals of linear cpu% baseline over time."""
    rapl = load_power(exp_dir)
    proc = load_csv(exp_dir / "proc.csv")
    if not rapl or not proc: return
    pkg = power_col(rapl)
    if not pkg: return
    xs_p, ws = colvals(rapl, pkg)
    xs_c, cpu = colvals(proc, "cpu_pct")
    if len(xs_p) < 5 or len(xs_c) < 5: return
    cpu_aligned = np.interp(xs_p, xs_c, cpu)
    if fit is None:
        fit = np.polyfit(cpu_aligned, ws, 1)
    predicted = np.polyval(fit, cpu_aligned)
    residuals = ws - predicted

    windows = load_invocation_windows(exp_dir)

    fig, ax = plt.subplots(figsize=(12, 5))
    ax.plot(xs_p, residuals, linewidth=1.2, color="#d62728")
    ax.axhline(0, color="black", linewidth=0.8)
    ax.fill_between(xs_p, residuals, 0, where=residuals > 0, alpha=0.25,
                    color="#d62728", label="model under-predicts")
    ax.fill_between(xs_p, residuals, 0, where=residuals < 0, alpha=0.25,
                    color="#1f77b4", label="model over-predicts")
    for s, e in windows:
        ax.axvspan(s, e, alpha=0.08, color="grey")
    ax.set_xlabel("Elapsed (s)"); ax.set_ylabel("Actual − predicted (W)")
    rmse = np.sqrt((residuals**2).mean())
    ax.set_title(f"Linear-baseline residuals — {exp_dir.name}\n"
                 f"RMSE = {rmse:.3f} W "
                 f"(model: W = {fit[0]:.3f}·cpu% + {fit[1]:.2f})")
    ax.legend(loc="best", fontsize=9); ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_dir / "06_linear_baseline.png", dpi=140)
    plt.close(fig); print("  ✓ 06_linear_baseline.png")

def plot_correlation(exp_dir, out_dir):
    """Graph 7: correlation heatmap of features vs power."""
    rapl = load_power(exp_dir)
    if not rapl: return
    pkg = power_col(rapl)
    if not pkg: return
    xs_p, ws = colvals(rapl, pkg)
    if len(xs_p) < 5: return

    # Candidate features from proc.csv and pressure.csv
    feature_specs = [
        ("proc.csv",        "cpu_pct"),
        ("proc.csv",        "vmrss_kb"),
        ("proc.csv",        "read_bytes"),
        ("proc.csv",        "write_bytes"),
        ("proc.csv",        "net_rx_bytes_d"),
        ("proc.csv",        "net_tx_bytes_d"),
        ("proc.csv",        "threads"),
        ("pressure.csv",    "cpu_some_avg10"),
        ("pressure.csv",    "memory_some_avg10"),
        ("pressure.csv",    "io_some_avg10"),
    ]
    feature_cache = {}
    labels = []
    matrix_cols = []
    for fname, col in feature_specs:
        path = exp_dir / fname
        if not path.exists(): continue
        if fname not in feature_cache:
            feature_cache[fname] = load_csv(path)
        rows = feature_cache[fname]
        if not rows or col not in rows[0]: continue
        xs_f, ys_f = colvals(rows, col)
        if len(xs_f) < 5: continue
        # skip zero-variance columns (e.g. all-zero PSI) — they yield nan corr
        if np.nanstd(ys_f) == 0: continue
        ys_aligned = np.interp(xs_p, xs_f, ys_f)
        labels.append(col)
        matrix_cols.append(ys_aligned)

    # PMU features from perf.csv (long format), pivoted to per-event series
    perf_wide = load_perf_wide(exp_dir)
    for ev in ["cycles", "instructions", "cache-references", "cache-misses",
               "LLC-load-misses", "dTLB-load-misses", "branch-misses",
               "ipc", "llc_miss_rate", "branch_miss_rate"]:
        if ev not in perf_wide: continue
        xs_f, ys_f = perf_wide[ev]
        if len(xs_f) < 5: continue
        if np.nanstd(ys_f) == 0: continue
        ys_aligned = np.interp(xs_p, xs_f, ys_f)
        labels.append(ev)
        matrix_cols.append(ys_aligned)

    if len(matrix_cols) < 2:
        print("  skip 07: not enough features"); return

    # Compute pearson r against power
    rs = np.array([np.corrcoef(c, ws)[0, 1] for c in matrix_cols])

    # Build correlation matrix including watts column for reference
    matrix = np.column_stack(matrix_cols + [ws])
    labels_full = labels + [f"{pkg} (target)"]
    corr = np.corrcoef(matrix.T)

    fig, ax = plt.subplots(figsize=(max(8, len(labels)*0.6),
                                    max(8, len(labels)*0.6)))
    im = ax.imshow(corr, cmap="RdBu_r", vmin=-1, vmax=1)
    ax.set_xticks(range(len(labels_full)))
    ax.set_yticks(range(len(labels_full)))
    ax.set_xticklabels(labels_full, rotation=45, ha="right", fontsize=9)
    ax.set_yticklabels(labels_full, fontsize=9)
    for i in range(len(labels_full)):
        for j in range(len(labels_full)):
            ax.text(j, i, f"{corr[i,j]:.2f}", ha="center", va="center",
                    fontsize=8,
                    color="white" if abs(corr[i,j]) > 0.5 else "black")
    fig.colorbar(im, ax=ax, fraction=0.04)
    ax.set_title(f"Feature correlation — {exp_dir.name}")
    fig.tight_layout()
    fig.savefig(out_dir / "07_correlation_heatmap.png", dpi=140)
    plt.close(fig); print("  ✓ 07_correlation_heatmap.png")

    # Return best non-cpu_pct feature for graph 8
    candidates = [(l, r_) for l, r_ in zip(labels, rs)
                  if l not in ("cpu_pct",) and not np.isnan(r_)]
    if not candidates: return None
    candidates.sort(key=lambda kv: abs(kv[1]), reverse=True)
    return candidates[0][0]

def plot_pmu_scatter(exp_dir, out_dir, feature):
    """Graph 8: strongest PMU feature vs power."""
    if not feature:
        print("  skip 08: no strong feature found"); return
    rapl = load_power(exp_dir)
    if not rapl: return
    pkg = power_col(rapl)
    if not pkg: return
    xs_p, ws = colvals(rapl, pkg)

    # find the feature: check perf.csv (wide) first, then proc/pressure
    xs_f = ys_f = None
    perf_wide = load_perf_wide(exp_dir)
    if feature in perf_wide:
        xs_f, ys_f = perf_wide[feature]
    else:
        for fname in ("proc.csv", "pressure.csv"):
            rows = load_csv(exp_dir / fname)
            if rows and feature in rows[0]:
                xs_f, ys_f = colvals(rows, feature)
                break
    if xs_f is None or len(xs_f) < 5: return
    ys_aligned = np.interp(xs_p, xs_f, ys_f)
    r = np.corrcoef(ys_aligned, ws)[0, 1]

    fig, ax = plt.subplots(figsize=(9, 6))
    ax.scatter(ys_aligned, ws, alpha=0.5, s=22, color="#9467bd")
    fit = np.polyfit(ys_aligned, ws, 1)
    xx = np.linspace(ys_aligned.min(), ys_aligned.max(), 50)
    ax.plot(xx, np.polyval(fit, xx), color="red", linewidth=1.5,
            label=f"r = {r:.3f}, R² = {r**2:.3f}")
    ax.set_xlabel(feature); ax.set_ylabel("Package power (W)")
    ax.set_title(f"{feature} vs power — {exp_dir.name}")
    ax.legend(loc="best"); ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_dir / "08_ipc_vs_power.png", dpi=140)
    plt.close(fig); print(f"  ✓ 08_ipc_vs_power.png (feature: {feature})")

def plot_rapl_stack(exp_dir, out_dir):
    """Graph 9: stacked RAPL domains."""
    rapl = load_power(exp_dir)
    if not rapl: return
    watt_cols = [c for c in rapl[0] if c.endswith("_watts")]
    if len(watt_cols) < 2:
        print("  skip 09: only one RAPL domain"); return

    xs = np.array([num(r["elapsed_s"]) for r in rapl
                   if num(r.get("elapsed_s")) is not None])
    series = {}
    for c in watt_cols:
        ys = np.array([num(r.get(c)) if num(r.get(c)) is not None else 0
                       for r in rapl])
        series[c] = ys[:len(xs)]

    fig, ax = plt.subplots(figsize=(12, 5))
    ax.stackplot(xs, *series.values(), labels=list(series.keys()), alpha=0.75)
    ax.set_xlabel("Elapsed (s)"); ax.set_ylabel("Power (W)")
    ax.set_title(f"RAPL domain breakdown — {exp_dir.name}")
    ax.legend(loc="upper right"); ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_dir / "09_rapl_domains_stack.png", dpi=140)
    plt.close(fig); print("  ✓ 09_rapl_domains_stack.png")

def plot_workload_comparison(exp_dirs, labels, out_dir):
    """Graph 10: energy-per-invocation across labelled workloads."""
    if len(exp_dirs) < 2: return
    datasets = []; lbls = []
    for d, lbl in zip(exp_dirs, labels or [d.name for d in exp_dirs]):
        rapl = load_power(d)
        if not rapl: continue
        pkg = power_col(rapl)
        if not pkg: continue
        xs, ys = colvals(rapl, pkg)
        windows = load_invocation_windows(d)
        if not windows: continue
        js = integrate_per_window(xs, ys, windows)
        if len(js) >= 2:
            datasets.append(js); lbls.append(lbl)
    if len(datasets) < 2: return

    fig, ax = plt.subplots(figsize=(10, 5))
    ax.boxplot(datasets, labels=lbls, patch_artist=True)
    ax.set_ylabel("Energy per invocation (J)")
    ax.set_title("Energy across workloads")
    ax.grid(True, alpha=0.3, axis="y")
    fig.tight_layout()
    fig.savefig(out_dir / "10_workload_comparison.png", dpi=140)
    plt.close(fig); print("  ✓ 10_workload_comparison.png")

# ── cross-run statistics ────────────────────────────────────

def _run_stat(vals):
    """
    Given a list of per-run mean values, return a summary dict or None if
    fewer than 2 runs have valid data (sample std requires n ≥ 2).
    """
    if len(vals) < 2:
        return None
    arr = np.array(vals, dtype=float)
    m  = float(arr.mean())
    sd = float(arr.std(ddof=1))          # sample standard deviation
    cv = sd / m * 100.0 if m != 0 else 0.0
    return {"per_run_means": vals, "mean": m, "std": sd, "cv": cv,
            "n_runs": len(vals)}

def compute_cross_run_stats(exp_dirs):
    """
    Aggregate per-run means for runtime, package power, and CPU utilisation,
    then compute cross-run mean / std / CV.

    Strategy per metric
    -------------------
    Runtime  : SAAF warm-start "runtime" (ms → s) → mean per run.
    CPU util : SAAF warm-start cpu-jiffies → cpu% → mean per run.
    Power    : mean RAPL/turbostat package power during active windows per run.

    Returns a dict keyed by metric name; each value is either None (< 2 valid
    runs) or a dict with keys: per_run_means, mean, std, cv, n_runs.
    """
    rt_means, cpu_means, pwr_means = [], [], []

    for d in exp_dirs:
        saaf = load_saaf_logs(d)

        # Runtime ─ prefer SAAF; fall back to invocations.csv timestamps
        rts = saaf_runtimes(saaf)
        if not rts:
            # fallback: wall-clock durations from invocations.csv
            inv_rows = load_csv(d / "invocations.csv")
            rapl_origin = rapl_clock_origin(d)
            for r in inv_rows:
                s_ep = parse_iso(r.get("start_iso"))
                e_ep = parse_iso(r.get("end_iso"))
                if s_ep is not None and e_ep is not None:
                    rts.append(e_ep - s_ep)
                else:
                    s = num(r.get("start_elapsed_s"))
                    e = num(r.get("end_elapsed_s"))
                    if s is not None and e is not None:
                        rts.append(e - s)
        if rts:
            rt_means.append(float(np.mean(rts)))

        # CPU utilisation ─ prefer SAAF; fall back to proc.csv active-window mean
        cpus = saaf_cpu_pcts(saaf)
        if not cpus:
            proc = load_csv(d / "proc.csv")
            if proc:
                xs_c, cpu_arr = colvals(proc, "cpu_pct")
                windows = load_invocation_windows(d)
                if len(xs_c) >= 2:
                    if windows:
                        active_cpu, _ = split_active_idle(xs_c, cpu_arr, windows)
                        if len(active_cpu):
                            cpus = list(active_cpu)
                    else:
                        cpus = list(cpu_arr)
        if cpus:
            cpu_means.append(float(np.mean(cpus)))

        # Power ─ RAPL/turbostat active-window mean
        rapl = load_power(d)
        if rapl:
            pkg = power_col(rapl)
            if pkg:
                xs_p, ws = colvals(rapl, pkg)
                windows = load_invocation_windows(d)
                if len(xs_p) >= 2:
                    if windows:
                        active_pwr, _ = split_active_idle(xs_p, ws, windows)
                        if len(active_pwr):
                            pwr_means.append(float(np.mean(active_pwr)))
                    else:
                        pwr_means.append(float(np.mean(ws)))

    return {
        "runtime": _run_stat(rt_means),
        "cpu":     _run_stat(cpu_means),
        "power":   _run_stat(pwr_means),
    }

def print_stats_table(stats, exp_dirs):
    """Print a formatted cross-run statistics summary to stdout."""
    print()
    print("┌──────────────────────────────────────────────────────────────────────────┐")
    print("│                      Cross-run statistics summary                        │")
    print("├─────────────────────┬──────────────────┬────────────────┬───────────────┤")
    print("│ Metric              │ Mean             │ Std Dev        │ CV (%)        │")
    print("├─────────────────────┼──────────────────┼────────────────┼───────────────┤")

    def _row(label, s, unit):
        if s is None:
            print(f"│ {label:<19} │ {'N/A (< 2 runs)':<16} │ {'—':<14} │ {'—':<13} │")
        else:
            print(f"│ {label:<19} │ {s['mean']:>10.4f} {unit:<5} │ "
                  f"{s['std']:>8.4f} {unit:<5} │ {s['cv']:>10.2f}%  │")

    _row("Runtime",        stats.get("runtime"), "s")
    _row("CPU util",       stats.get("cpu"),     "%")
    _row("Pkg Power",      stats.get("power"),   "W")

    print("└─────────────────────┴──────────────────┴────────────────┴───────────────┘")
    n = len(exp_dirs)
    print(f"  Runs included: {n}  |  "
          f"SAAF warm-start invocations only  |  "
          f"CV < 5% → repeatable, 5–15% → moderate, > 15% → noisy")
    print()

    # Per-run breakdown
    for metric, label, unit in [
        ("runtime", "Runtime (s)",   "s"),
        ("cpu",     "CPU util (%)", "%"),
        ("power",   "Pkg Power (W)", "W"),
    ]:
        s = stats.get(metric)
        if s is None:
            continue
        print(f"  {label}  per-run means:")
        for d, v in zip(exp_dirs, s["per_run_means"]):
            print(f"    {d.name:<30}  {v:.4f} {unit}")
    print()

def plot_cross_run_stats(exp_dirs, stats, out_dir):
    """Graph 11: bar-per-run with cross-run mean ± 1σ band."""
    metrics = []
    for key, label, unit in [("runtime", "Runtime (s)", "s"),
                              ("cpu",     "CPU util (%)", "%"),
                              ("power",   "Pkg Power (W)", "W")]:
        if stats.get(key):
            metrics.append((label, stats[key], unit))
    if not metrics:
        print("  skip 11: need ≥ 2 runs with valid data"); return

    n = len(metrics)
    fig, axes = plt.subplots(1, n, figsize=(5 * n, 5))
    if n == 1:
        axes = [axes]

    run_names = [d.name for d in exp_dirs]

    for ax, (label, s, unit) in zip(axes, metrics):
        vals  = s["per_run_means"]
        names = run_names[:len(vals)]
        x = np.arange(len(vals))

        ax.bar(x, vals, color="#1f77b4", alpha=0.75, edgecolor="white", zorder=2)
        ax.axhline(s["mean"], color="red", linestyle="--", linewidth=1.5, zorder=3,
                   label=f"μ = {s['mean']:.4f} {unit}")
        ax.fill_between([-0.5, len(vals) - 0.5],
                        s["mean"] - s["std"], s["mean"] + s["std"],
                        color="red", alpha=0.12, zorder=1,
                        label=f"±1σ = {s['std']:.4f} {unit}")

        ax.set_xticks(x)
        ax.set_xticklabels(names, rotation=20, ha="right", fontsize=8)
        ax.set_ylabel(label)
        ax.set_title(
            f"{label}\n"
            f"μ={s['mean']:.4f} {unit}  σ={s['std']:.4f} {unit}  CV={s['cv']:.1f}%",
            fontsize=9)
        ax.legend(fontsize=8)
        ax.grid(True, alpha=0.3, axis="y", zorder=0)

    fig.suptitle(
        f"Cross-run statistics — {len(exp_dirs)} run(s)  "
        f"[warm starts only, SAAF + RAPL]",
        fontsize=11)
    fig.tight_layout()
    fig.savefig(out_dir / "11_cross_run_stats.png", dpi=140)
    plt.close(fig)
    print("  ✓ 11_cross_run_stats.png")

# ── main ────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dirs", nargs="+", type=Path,
                    help="Experiment directories from fc_experiment.sh")
    ap.add_argument("--out", "-o", type=Path, default=Path("plots"),
                    help="Output directory for PNGs")
    ap.add_argument("--labels", nargs="+", default=None,
                    help="Labels for graph 10 (one per dir, in order)")
    args = ap.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    primary = args.dirs[0]
    print(f"[fc_analyze] primary: {primary}")
    print(f"[fc_analyze] output:  {args.out}")
    print()

    # single-run graphs (use primary)
    plot_timeline(primary, args.out)
    plot_idle_vs_active(primary, args.out)
    plot_energy_distribution(primary, args.out)
    fit_r = plot_cpu_vs_power(primary, args.out)
    fit = fit_r[0] if fit_r else None
    plot_baseline_residuals(primary, args.out, fit)
    best_feat = plot_correlation(primary, args.out)
    plot_pmu_scatter(primary, args.out, best_feat)
    plot_rapl_stack(primary, args.out)

    # multi-run graphs + cross-run statistics
    if len(args.dirs) >= 2:
        plot_repeatability(args.dirs, args.out)
        plot_workload_comparison(args.dirs, args.labels, args.out)
        stats = compute_cross_run_stats(args.dirs)
        print_stats_table(stats, args.dirs)
        plot_cross_run_stats(args.dirs, stats, args.out)

    print(f"\n[fc_analyze] Done → {args.out}/")

if __name__ == "__main__":
    main()