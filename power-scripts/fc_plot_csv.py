#!/usr/bin/env python3
"""
fc_plot.py — plot power over time from a fc_rapl.py CSV.

Auto-detects all *_watts columns. Computes total energy (joules) per domain
and shows it in the legend.

Usage:
  python3 fc_plot.py rapl.csv
  python3 fc_plot.py rapl.csv --out power.png
  python3 fc_plot.py rapl.csv --domains package-0_watts   # only one curve
  python3 fc_plot.py rapl.csv --no-show                    # save only
"""

import argparse, csv, sys
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

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", help="CSV from fc_rapl.py")
    ap.add_argument("--out", "-o", default=None,
                    help="Output image path (default: <csv-stem>.png)")
    ap.add_argument("--domains", nargs="+", default=None,
                    help="Restrict to specific *_watts columns")
    ap.add_argument("--no-show", action="store_true",
                    help="Don't open a window, just save")
    ap.add_argument("--title", default=None)
    args = ap.parse_args()

    try:
        import matplotlib.pyplot as plt
    except ImportError:
        sys.exit("ERROR: matplotlib not installed. Run: pip install matplotlib")

    rows = load(args.csv)
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
        # drop None pairs
        pairs = [(tt, yy) for tt, yy in zip(t, y) if yy is not None]
        if not pairs: continue
        xs, ys = zip(*pairs)
        avg = sum(ys) / len(ys)
        energy_j = avg * duration  # ≈ ∫W dt, assuming uniform sampling
        peak = max(ys)
        label = f"{col}  avg={avg:.2f}W  peak={peak:.2f}W  ≈{energy_j:.1f}J"
        ax.plot(xs, ys, linewidth=1.3, label=label)

    ax.set_xlabel("Elapsed (s)")
    ax.set_ylabel("Power (W)")
    ax.set_title(args.title or f"RAPL power — {Path(args.csv).name}")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="best", fontsize=9)
    fig.tight_layout()

    out = args.out or str(Path(args.csv).with_suffix(".png"))
    fig.savefig(out, dpi=140)
    print(f"[fc_plot] saved → {out}")

    if not args.no_show:
        try: plt.show()
        except Exception: pass

if __name__ == "__main__":
    main()