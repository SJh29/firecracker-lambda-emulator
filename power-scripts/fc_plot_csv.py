#!/usr/bin/env python3
"""
fc_plot_csv.py -- plot a fc_rapl.py or fc_perf.sh CSV.

Auto-detects format:
  - fc_rapl.py CSV: wide format with *_watts columns
  - fc_perf.sh CSV: long format (time_s, value, unit, event, ...)

Usage:
  python3 fc_plot_csv.py rapl.csv                  # plot power
  python3 fc_plot_csv.py perf.csv                  # plot perf events
  python3 fc_plot_csv.py perf.csv --events cycles,instructions  # subset
  python3 fc_plot_csv.py perf.csv --rate           # plot as per-second rate
  python3 fc_plot_csv.py rapl.csv --out power.png
  python3 fc_plot_csv.py rapl.csv --domains package-0_watts
  python3 fc_plot_csv.py rapl.csv --no-show
"""

import argparse, csv, sys
from collections import defaultdict
from pathlib import Path

def load(path):
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            rows.append(r)
    if not rows:
        sys.exit("ERROR: empty CSV")
    return rows

def num(v):
    try: return float(v)
    except: return None

def detect_format(rows):
    """Return 'rapl' if any *_watts column exists, 'perf' if event column, else 'unknown'."""
    cols = rows[0].keys()
    if any(c.endswith("_watts") for c in cols):
        return "rapl"
    if "event" in cols and "value" in cols and "time_s" in cols:
        return "perf"
    return "unknown"

def plot_rapl(rows, args, plt):
    watt_cols = [c for c in rows[0] if c.endswith("_watts")]
    if args.domains:
        watt_cols = [c for c in watt_cols if c in args.domains]
    if not watt_cols:
        sys.exit("ERROR: no *_watts columns found")

    t = [num(r["elapsed_s"]) for r in rows]
    t = [x for x in t if x is not None]
    if not t:
        sys.exit("ERROR: no elapsed_s values")
    duration = t[-1] - t[0]

    fig, ax = plt.subplots(figsize=(11, 5))
    for col in watt_cols:
        y = [num(r.get(col)) for r in rows]
        pairs = [(tt, yy) for tt, yy in zip(t, y) if yy is not None]
        if not pairs: continue
        xs, ys = zip(*pairs)
        avg = sum(ys) / len(ys)
        energy_j = avg * duration
        peak = max(ys)
        label = f"{col}  avg={avg:.2f}W  peak={peak:.2f}W  ≈{energy_j:.1f}J"
        ax.plot(xs, ys, linewidth=1.3, label=label)

    ax.set_xlabel("Elapsed (s)")
    ax.set_ylabel("Power (W)")
    ax.set_title(args.title or f"RAPL power -- {Path(args.csv).name}")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="best", fontsize=9)
    fig.tight_layout()
    return fig

def plot_perf(rows, args, plt):
    """perf CSV is long-format: pivot to one series per event."""
    # Group by event
    series = defaultdict(list)  # event -> list of (time_s, value)
    runtime_by_event = defaultdict(list)
    for r in rows:
        t = num(r.get("time_s"))
        v = num(r.get("value"))
        ev = (r.get("event") or "").strip()
        rt = num(r.get("runtime_ns"))
        if t is None or v is None or not ev: continue
        series[ev].append((t, v))
        if rt is not None:
            runtime_by_event[ev].append((t, rt))

    if not series:
        sys.exit("ERROR: no perf data parsed")

    # Filter by --events if given
    if args.events:
        wanted = set(args.events.split(","))
        series = {k: v for k, v in series.items() if k in wanted}
        if not series:
            sys.exit(f"ERROR: no matching events. Available: {list(series.keys())}")

    events = sorted(series.keys())
    n = len(events)

    fig, axes = plt.subplots(n, 1, figsize=(12, 2.2 * n), sharex=True)
    if n == 1: axes = [axes]
    fig.suptitle(args.title or f"perf events -- {Path(args.csv).name}",
                 fontsize=13, fontweight="bold")

    for ax, ev in zip(axes, events):
        pts = sorted(series[ev])
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]

        if args.rate:
            # convert to per-second rate using runtime_ns deltas if available,
            # otherwise assume sample interval = time delta
            rates = []
            for i, (t, v) in enumerate(pts):
                if i == 0:
                    dt = t  # first interval starts at 0
                else:
                    dt = t - pts[i-1][0]
                rates.append(v / dt if dt > 0 else 0)
            ys = rates
            ylabel = f"{ev}/s"
        else:
            ylabel = ev

        avg = sum(ys) / len(ys) if ys else 0
        peak = max(ys) if ys else 0
        ax.plot(xs, ys, linewidth=1.2, color="#1f77b4")
        ax.fill_between(xs, ys, alpha=0.15, color="#1f77b4")
        ax.set_ylabel(ylabel, fontsize=9)
        ax.grid(True, alpha=0.3)
        ax.text(0.99, 0.95, f"avg={avg:,.0f}  peak={peak:,.0f}",
                transform=ax.transAxes, ha="right", va="top", fontsize=8,
                bbox=dict(facecolor="white", alpha=0.7, edgecolor="none"))

    axes[-1].set_xlabel("Elapsed (s)")
    fig.tight_layout()
    return fig

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", help="CSV from fc_rapl.py or fc_perf.sh")
    ap.add_argument("--out", "-o", default=None,
                    help="Output image path (default: <csv-stem>.png)")
    ap.add_argument("--domains", nargs="+", default=None,
                    help="(rapl) Restrict to specific *_watts columns")
    ap.add_argument("--events", default=None,
                    help="(perf) Comma-separated list of events to plot")
    ap.add_argument("--rate", action="store_true",
                    help="(perf) Plot as per-second rate instead of per-interval counts")
    ap.add_argument("--format", choices=["rapl", "perf", "auto"], default="auto",
                    help="Force a CSV format (default: auto-detect)")
    ap.add_argument("--no-show", action="store_true",
                    help="Don't open a window, just save")
    ap.add_argument("--title", default=None)
    args = ap.parse_args()

    try:
        import matplotlib.pyplot as plt
    except ImportError:
        sys.exit("ERROR: matplotlib not installed. Run: pip install matplotlib")

    rows = load(args.csv)
    fmt = args.format
    if fmt == "auto":
        fmt = detect_format(rows)
        if fmt == "unknown":
            sys.exit("ERROR: could not detect CSV format. Use --format rapl|perf")
        print(f"[fc_plot_csv] detected format: {fmt}")

    if fmt == "rapl":
        fig = plot_rapl(rows, args, plt)
    elif fmt == "perf":
        fig = plot_perf(rows, args, plt)

    out = args.out or str(Path(args.csv).with_suffix(".png"))
    fig.savefig(out, dpi=140)
    print(f"[fc_plot_csv] saved → {out}")

    if not args.no_show:
        try: plt.show()
        except Exception: pass

if __name__ == "__main__":
    main()