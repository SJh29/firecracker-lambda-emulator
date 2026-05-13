"""
fc_proc.py - process /proc/<pid>/{stat, status, io, net/dev} -> CSV
Gives Per process CPU, Memory, IO, and Network usage in CSV format.

"""

import argparse, csv, os, re, time, shutil, sys, subprocess
from datetime import datetime, timezone
from pathlib import Path

CLK = os.sysconf(os.sysconf_names['SC_CLK_TCK'])

"""
Use socket path to find the pid of the process that is listening on that socket.
Primarily used since turbostat uses socket to monitor a process, and I want to have a singular format for any script for monitoring.
"""
def find_pid_by_sock(socket_path):
    if shutil.which("lsof"):
        try:
            out = subprocess.check_output(["lsof", "-t", "-U", socket_path], stderr=subprocess.DEVNULL, timeout=3, text=True)
            return int(out.strip())
        except (subprocess.CalledProcessError, ValueError):
            pass
    if shutil.which("ss"):
        try:
            out = subprocess.check_output(["ss", "-xp"], stderr=subprocess.DEVNULL, timeout=3, text=True)
            for line in out.splitlines():
                if socket_path in line:
                    match = re.search(r"pid=(\d+)", line)
                    if match:
                        return int(match.group(1))
        except subprocess.CalledProcessError:
            pass
    for d in Path("/proc").iterdir():
        if d.is_dir() and d.name.isdigit():
            pid = int(d.name)
            try:
                for fd_path in (d / "fdinfo").iterdir():
                    with open(fd_path, "r") as f:
                        for line in f:
                            if socket_path in line:
                                return pid
            except (FileNotFoundError, PermissionError):
                continue
    raise RuntimeError(f"Could not find PID for socket: {socket_path}")

def status(pid):
    out = {}
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if ':' in line:
                    key, value = line.split(':', 1)
                    out[key.strip()] = value.strip()
    except:
        pass
    return out

def stat(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().split()
    except:
        return None

def io_stats(pid):
    out = {}
    try:
        with open(f"/proc/{pid}/io") as f:
            for line in f:
                if ':' in line:
                    key, value = line.split(':', 1)
                    out[key.strip()] = value.strip()
    except:
        pass
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
    ap.add_argument("--socket", default="/tmp/firecracker.socket")
    ap.add_argument("--interval", "-i", type=float, default=1.0)
    ap.add_argument("--duration", "-d", type=float, default=60.0)
    ap.add_argument("--out", "-o",
                    default=f"proc_{datetime.now(timezone.utc):%Y%m%d_%H%M%S}.csv")
    args = ap.parse_args()
 
    pid = find_pid_by_sock(args.socket)
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
 
