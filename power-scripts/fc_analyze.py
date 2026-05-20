#!/usr/bin/env python3
"""
fc_analyze.py — produce the feasibility-deck graphs from one or more
experiment directories created by fc_experiment.sh.

Usage:
  python3 fc_analyze.py EXP_DIR [EXP_DIR ...] [--out PLOTS_DIR]

  Single run:  python3 fc_analyze.py experiment_20260514_120000
  Repeat runs: python3 fc_analyze.py run1 run2 run3
  Workloads:   python3 fc_analyze.py cpu_bound mem_bound io_bound --labels cpu mem io

Generates PNGs in --out (default: ./plots/) for the feasibility-study
graphs:

  01_power_timeline.png        — power vs time, invocation bands (graph 1)
  02_idle_vs_active.png        — distribution comparison (graph 2)
  03_repeatability.png         — joules-per-invocation across runs (graph 3)
  04_energy_per_invocation.png — per-invocation energy histogram (graph 4)
  05_cpu_vs_power_scatter.png  — graph 5
  06_linear_baseline.png       — residuals over time (graph 6)
  07_correlation_heatmap.png   — features: x power (graph 7)
  08_ipc_vs_power.png          — strongest PMU feature scatter (graph 8)
  09_rapl_domains_stack.png    — package + dram + core stacked area (graph 9)
  10_workload_comparison.png   — across labelled experiments (graph 10)
"""

import argparse, csv, sys
from pathlib import Path
from statistics import mean

try:
    import matplotlib.pyplot as plt
    import numpy as np
except ImportError:
    sys.exit("ERROR: pip install matplotlib numpy")

# ── I/O ─────────────────────────────────────────────────────

def load_csv(path):
    if not path.exists(): return []
    with open(path) as f:
        return list(csv.DictReader(f))

def num(v):
    try: return float(v)
    except: return None

def colvals(rows, key):
    """Return (xs, ys) pairs filtering None."""
    out_x, out_y = [], []
    for r in rows:
        x = num(r.get("elapsed_s"))
        y = num(r.get(key))
        if x is not None and y is not None:
            out_x.append(x); out_y.append(y)
    return np.array(out_x), np.array(out_y)

def load_invocation_windows(exp_dir):
    """Return list of (start_elapsed_s, end_elapsed_s) tuples."""
    rows = load_csv(exp_dir / "invocations.csv")
    out = []
    for r in rows:
        s = num(r.get("start_elapsed_s"))
        e = num(r.get("end_elapsed_s"))
        if s is not None and e is not None:
            out.append((s, e))
    return out

def power_col(rapl_rows):
    """Pick the best 'package' power column from rapl.csv."""
    if not rapl_rows: return None
    cands = [c for c in rapl_rows[0]
             if c.endswith("_watts") and "package" in c.lower()]
    if cands: return cands[0]
    # fall back to first *_watts
    cands = [c for c in rapl_rows[0] if c.endswith("_watts")]
    return cands[0] if cands else None

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
        js.append(float(np.trapz(ys[mask], xs[mask])))
    return np.array(js)

# ── individual plots ────────────────────────────────────────

def plot_timeline(exp_dir, out_dir):
    """Graph 1: power timeline with invocation bands."""
    rapl = load_csv(exp_dir / "rapl.csv")
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
    idle_baseline = np.median(ys[:10]) if len(ys) > 10 else np.median(ys)
    ax.axhline(idle_baseline, linestyle="--", color="grey", linewidth=1,
               label=f"idle ~{idle_baseline:.1f}W")
    ax.set_xlabel("Elapsed (s)"); ax.set_ylabel("Power (W)")
    ax.set_title(f"Power timeline with invocations — {exp_dir.name}")
    ax.grid(True, alpha=0.3); ax.legend(loc="best", fontsize=9)
    fig.tight_layout()
    fig.savefig(out_dir / "01_power_timeline.png", dpi=140)
    plt.close(fig); print("  ✓ 01_power_timeline.png")

def plot_idle_vs_active(exp_dir, out_dir):
    """Graph 2: idle vs active distribution."""
    rapl = load_csv(exp_dir / "rapl.csv")
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
        rapl = load_csv(d / "rapl.csv")
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
    rapl = load_csv(exp_dir / "rapl.csv")
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
    rapl = load_csv(exp_dir / "rapl.csv")
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
    rapl = load_csv(exp_dir / "rapl.csv")
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
    rapl = load_csv(exp_dir / "rapl.csv")
    if not rapl: return
    pkg = power_col(rapl)
    if not pkg: return
    xs_p, ws = colvals(rapl, pkg)
    if len(xs_p) < 5: return

    # Candidate features from various CSVs
    feature_specs = [
        ("proc.csv",        "cpu_pct"),
        ("proc.csv",        "vmrss_kb"),
        ("proc.csv",        "read_bytes"),
        ("proc.csv",        "write_bytes"),
        ("proc.csv",        "net_rx_bytes_d"),
        ("proc.csv",        "net_tx_bytes_d"),
        ("proc.csv",        "threads"),
        ("ml_features.csv", "ipc"),
        ("ml_features.csv", "llc_miss_rate"),
        ("ml_features.csv", "branch_miss_rate"),
        ("ml_features.csv", "instructions"),
        ("ml_features.csv", "cycles"),
        ("ml_features.csv", "cache_misses"),
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
        ys_aligned = np.interp(xs_p, xs_f, ys_f)
        labels.append(col)
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
    rapl = load_csv(exp_dir / "rapl.csv")
    if not rapl: return
    pkg = power_col(rapl)
    if not pkg: return
    xs_p, ws = colvals(rapl, pkg)

    # find which csv has the feature
    for fname in ("ml_features.csv", "proc.csv", "pressure.csv"):
        rows = load_csv(exp_dir / fname)
        if rows and feature in rows[0]:
            xs_f, ys_f = colvals(rows, feature)
            break
    else:
        return
    if len(xs_f) < 5: return
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
    rapl = load_csv(exp_dir / "rapl.csv")
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
        rapl = load_csv(d / "rapl.csv")
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
    plt.close(fig); print("  Done: 10_workload_comparison.png")

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

    # multi-run graphs
    if len(args.dirs) >= 2:
        plot_repeatability(args.dirs, args.out)
        plot_workload_comparison(args.dirs, args.labels, args.out)

    print(f"\n[fc_analyze] Done → {args.out}/")

if __name__ == "__main__":
    main()