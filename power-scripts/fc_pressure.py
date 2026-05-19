#!/usr/bin/env python3
"""
fc_pressure.py — sample cgroup PSI (Pressure Stall Information).

PSI shows what fraction of time the cgroup was stalled on CPU/memory/IO.
High pressure correlates with power-saving C-state residency.

Usage: sudo fc_pressure.py [--socket PATH] [--interval SECS] [--duration SECS] [--out CSV]
"""

import argparse, csv, re, shutil, subprocess, sys, time
from datetime import datetime, timezone
from pathlib import Path

def find_pid(socket_path):
    if shutil.which("lsof"):
        try:
            out = subprocess.check_output(["lsof","-t","-U",socket_path],
                                          stderr=subprocess.DEVNULL, timeout=3).decode()
            if out.strip(): return int(out.split()[0])
        except: pass
    for d in Path("/proc").iterdir():
        if not d.name.isdigit(): continue
        try:
            for fd in (d/"fd").iterdir():
                if socket_path in str(fd.resolve()): return int(d.name)
        except: pass
    return None

def find_cgroup(pid):
    """Get cgroup v2 path for pid."""
    try:
        for line in Path(f"/proc/{pid}/cgroup").read_text().splitlines():
            parts = line.split(":", 2)
            if len(parts) == 3 and parts[1] == "":
                return Path(f"/sys/fs/cgroup{parts[2].strip()}")
    except: pass
    return None

def parse_psi(text):
    """PSI files have lines like 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0'"""
    out = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 2: continue
        kind = parts[0]  # 'some' or 'full'
        for kv in parts[1:]:
            if "=" in kv:
                k, v = kv.split("=", 1)
                out[f"{kind}_{k}"] = float(v) if "." in v else int(v)
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", default="/tmp/firecracker.socket")
    ap.add_argument("--interval", "-i", type=float, default=1.0)
    ap.add_argument("--duration", "-d", type=float, default=60.0)
    ap.add_argument("--out", "-o",
                    default=f"pressure_{datetime.now(timezone.utc):%Y%m%d_%H%M%S}.csv")
    args = ap.parse_args()

    pid = find_pid(args.socket)
    if not pid: sys.exit(f"ERROR: no PID for {args.socket}")

    cg = find_cgroup(pid)
    if not cg or not cg.exists():
        sys.exit(f"ERROR: cgroup not found for PID {pid} (needs cgroup v2)")

    resources = []
    for r in ("cpu.pressure", "memory.pressure", "io.pressure"):
        if (cg/r).exists(): resources.append(r)
    if not resources:
        sys.exit(f"ERROR: no PSI files in {cg}")

    print(f"[pressure] PID={pid} cgroup={cg.name} tracking: {', '.join(resources)}")
    print(f"[pressure] {args.interval}s × {args.duration}s → {args.out}")

    # Build columns: for each resource, capture some_avg10 / full_avg10 / totals
    cols = ["timestamp", "elapsed_s"]
    for r in resources:
        prefix = r.split(".")[0]
        cols += [f"{prefix}_some_avg10", f"{prefix}_some_avg60",
                 f"{prefix}_full_avg10", f"{prefix}_full_avg60",
                 f"{prefix}_some_total", f"{prefix}_full_total"]

    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        t0 = last = time.monotonic()
        while True:
            time.sleep(max(0, args.interval - (time.monotonic() - last)))
            now = time.monotonic()
            row = {
                "timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
                "elapsed_s": round(now - t0, 3),
            }
            for r in resources:
                prefix = r.split(".")[0]
                try:
                    psi = parse_psi((cg/r).read_text())
                except Exception:
                    psi = {}
                row[f"{prefix}_some_avg10"] = psi.get("some_avg10")
                row[f"{prefix}_some_avg60"] = psi.get("some_avg60")
                row[f"{prefix}_full_avg10"] = psi.get("full_avg10")
                row[f"{prefix}_full_avg60"] = psi.get("full_avg60")
                row[f"{prefix}_some_total"] = psi.get("some_total")
                row[f"{prefix}_full_total"] = psi.get("full_total")
            w.writerow(row); f.flush()
            last = now
            if (now - t0) >= args.duration: break

    print(f"[pressure] Done → {args.out}")

if __name__ == "__main__":
    main()