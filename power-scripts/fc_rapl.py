#!/usr/bin/env python3
"""
fc_rapl.py — sample RAPL power-cap energy counters and emit CSV.

RAPL is socket-wide, but it's the most reliable source of real power data
when turbostat isn't usable.

Usage: sudo fc_rapl.py [--socket PATH] [--interval SECS] [--duration SECS] [--out CSV]
   default socket:   /tmp/firecracker.socket
   default interval: 1.0 s
   default duration: 60 s
"""

import argparse, csv, os, platform, sys, time
from datetime import datetime, timezone
from pathlib import Path

RAPL = Path("/sys/class/powercap")
ARCH = platform.machine()

def domains():
    d = {}
    if RAPL.exists():
        for p in RAPL.iterdir():
            e, n = p/"energy_uj", p/"name"
            if e.exists() and n.exists():
                d[n.read_text().strip()] = e
    return d

def read(doms):
    return {n: int(p.read_text()) for n, p in doms.items() if p.exists()}

def watts(prev, curr, dt):
    out = {}
    for n in curr:
        if n in prev and dt > 0:
            delta = curr[n] - prev[n]
            if delta < 0: delta += 2**32
            out[n] = (delta / 1e6) / dt
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", default="/tmp/firecracker.socket",
                    help="Firecracker socket (informational only)")
    ap.add_argument("--interval", "-i", type=float, default=1.0)
    ap.add_argument("--duration", "-d", type=float, default=60.0)
    ap.add_argument("--out", "-o",
                    default=f"rapl_{datetime.now(timezone.utc):%Y%m%d_%H%M%S}.csv")
    args = ap.parse_args()

    doms = domains()
    if not doms:
        if ARCH in ("aarch64", "arm64"):
            sys.exit(f"ERROR: no RAPL on ARM ({ARCH}). Use fc_arm_power.py instead.")
        sys.exit("ERROR: no RAPL domains found at /sys/class/powercap "
                 "(missing permissions, or RAPL not supported on this CPU)")
    print(f"[rapl] socket={args.socket}  domains: {', '.join(doms)}")
    print(f"[rapl] {args.interval}s × {args.duration}s → {args.out}")

    cols = ["timestamp", "elapsed_s"] + [f"{n}_watts" for n in doms]
    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        prev = read(doms)
        t0 = time.monotonic()
        last = t0
        while True:
            time.sleep(max(0, args.interval - (time.monotonic() - last)))
            now = time.monotonic()
            curr = read(doms)
            dt = now - last
            powers = watts(prev, curr, dt)
            w.writerow({
                "timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
                "elapsed_s": round(now - t0, 3),
                **{f"{n}_watts": round(v, 3) for n, v in powers.items()},
            })
            f.flush()
            prev = curr
            last = now
            if (now - t0) >= args.duration:
                break
    print(f"[rapl] Done → {args.out}")

if __name__ == "__main__":
    main()