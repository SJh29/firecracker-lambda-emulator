#!/usr/bin/env python3
"""
fc_proc.py — sample /proc/<pid>/{stat,status,io,net/dev} → CSV.
Gives per-process CPU%, memory, IO bytes, net bytes — no external tools needed.

Usage: sudo fc_proc.py [--socket PATH] [--interval SECS] [--duration SECS] [--out CSV]
"""

import argparse, csv, os, re, shutil, subprocess, sys, time
from datetime import datetime, timezone
from pathlib import Path

CLK = os.sysconf("SC_CLK_TCK")

def find_pid(socket_path):
    # Prefer the shared fc_pid.sh resolver (verifies comm == firecracker).
    here = Path(__file__).resolve().parent
    fc_pid_sh = here / "fc_pid.sh"
    if fc_pid_sh.exists():
        try:
            out = subprocess.check_output(
                ["bash", str(fc_pid_sh), socket_path],
                stderr=subprocess.DEVNULL, timeout=10).decode().strip()
            if out and out.split("\n")[0].isdigit():
                return int(out.split("\n")[0])
        except Exception:
            pass
    # Fallbacks if fc_pid.sh is unavailable
    if shutil.which("lsof"):
        try:
            out = subprocess.check_output(["lsof","-t","-U",socket_path],
                                          stderr=subprocess.DEVNULL, timeout=3).decode()
            if out.strip(): return int(out.split()[0])
        except: pass
    if shutil.which("ss"):
        try:
            out = subprocess.check_output(["ss","-xp"], stderr=subprocess.DEVNULL,
                                          timeout=3).decode()
            for line in out.splitlines():
                if socket_path in line:
                    m = re.search(r"pid=(\d+)", line)
                    if m: return int(m.group(1))
        except: pass
    for d in Path("/proc").iterdir():
        if not d.name.isdigit(): continue
        try:
            if "firecracker" in (d/"comm").read_text(): return int(d.name)
        except: pass
    return None

def stat(pid):
    try: return Path(f"/proc/{pid}/stat").read_text().split()
    except: return None

def status(pid):
    out = {}
    try:
        for ln in Path(f"/proc/{pid}/status").read_text().splitlines():
            if ":" in ln:
                k, v = ln.split(":", 1)
                out[k.strip()] = v.strip()
    except: pass
    return out

def io_stats(pid):
    out = {}
    try:
        for ln in Path(f"/proc/{pid}/io").read_text().splitlines():
            if ":" in ln:
                k, v = ln.split(":", 1)
                try: out[k.strip()] = int(v.strip())
                except: pass
    except: pass
    return out

def net_bytes(pid):
    rx = tx = 0
    try:
        for ln in Path(f"/proc/{pid}/net/dev").read_text().splitlines()[2:]:
            p = ln.split()
            if len(p) >= 10:
                rx += int(p[1]); tx += int(p[9])
    except: pass
    return rx, tx

def cpu_pct(prev, curr, dt):
    if not prev or not curr or dt <= 0: return 0.0
    d = (int(curr[13]) + int(curr[14])) - (int(prev[13]) + int(prev[14]))
    return 100.0 * (d / CLK) / dt

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", default="/tmp/firecracker/0.socket")
    ap.add_argument("--interval", "-i", type=float, default=1.0)
    ap.add_argument("--duration", "-d", type=float, default=60.0)
    ap.add_argument("--out", "-o",
                    default=f"proc_{datetime.now(timezone.utc):%Y%m%d_%H%M%S}.csv")
    args = ap.parse_args()

    pid = find_pid(args.socket)
    if not pid:
        sys.exit(f"ERROR: no Firecracker PID for socket {args.socket}")
    print(f"[proc] PID={pid} (socket={args.socket})")
    print(f"[proc] {args.interval}s × {args.duration}s → {args.out}")

    cols = ["timestamp","elapsed_s","cpu_pct","threads",
            "vmrss_kb","vmpeak_kb","vmswap_kb","rss_anon_kb",
            "read_bytes","write_bytes","syscr","syscw",
            "net_rx_bytes_d","net_tx_bytes_d","fd_count",
            "voluntary_ctxt_switches","nonvoluntary_ctxt_switches"]

    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        prev_stat = stat(pid)
        prev_net = net_bytes(pid)
        t0 = last = time.monotonic()
        while True:
            time.sleep(max(0, args.interval - (time.monotonic() - last)))
            now = time.monotonic()
            dt = now - last
            if not Path(f"/proc/{pid}").exists():
                print("[proc] PID exited"); break
            cs = stat(pid)
            st = status(pid)
            io = io_stats(pid)
            rx, tx = net_bytes(pid)
            row = {
                "timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
                "elapsed_s": round(now - t0, 3),
                "cpu_pct":   round(cpu_pct(prev_stat, cs, dt), 2),
                "threads":   int(cs[19]) if cs else None,
                "vmrss_kb":  int(st.get("VmRSS","0").split()[0]) if "VmRSS" in st else None,
                "vmpeak_kb": int(st.get("VmPeak","0").split()[0]) if "VmPeak" in st else None,
                "vmswap_kb": int(st.get("VmSwap","0").split()[0]) if "VmSwap" in st else None,
                "rss_anon_kb": int(st.get("RssAnon","0").split()[0]) if "RssAnon" in st else None,
                "read_bytes":  io.get("read_bytes"),
                "write_bytes": io.get("write_bytes"),
                "syscr": io.get("syscr"), "syscw": io.get("syscw"),
                "net_rx_bytes_d": rx - prev_net[0],
                "net_tx_bytes_d": tx - prev_net[1],
                "fd_count": sum(1 for _ in Path(f"/proc/{pid}/fd").iterdir())
                            if Path(f"/proc/{pid}/fd").exists() else None,
                "voluntary_ctxt_switches": int(st.get("voluntary_ctxt_switches","0").split()[0])
                            if "voluntary_ctxt_switches" in st else None,
                "nonvoluntary_ctxt_switches": int(st.get("nonvoluntary_ctxt_switches","0").split()[0])
                            if "nonvoluntary_ctxt_switches" in st else None,
            }
            w.writerow(row); f.flush()
            prev_stat = cs; prev_net = (rx, tx); last = now
            if (now - t0) >= args.duration: break

    print(f"[proc] Done → {args.out}")

if __name__ == "__main__":
    main()