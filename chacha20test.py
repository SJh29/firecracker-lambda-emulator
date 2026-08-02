#!/usr/bin/env python3
"""
chacha20_local_timer.py — run the ChaCha20/OpenSSL benchmark locally (e.g. on
WSL) and time each phase, WITHOUT SAAF or Firecracker.

This mirrors the workload in function.py so you can get a full-vCPU runtime
baseline on your own machine before the .metal run. It breaks the time down by
phase so you can see where the time actually goes (spoiler: probably the Python
random-string generation, not the encryption).

Usage:
  python3 chacha20_local_timer.py
  python3 chacha20_local_timer.py --method chacha20 --rounds 100000 --seed 42
  python3 chacha20_local_timer.py --repeat 5            # average over 5 runs
  python3 chacha20_local_timer.py --urandom             # fast payload gen (os.urandom)
  python3 chacha20_local_timer.py --blocksize 8192000   # payload size in bytes

Notes:
  - Requires the `openssl` CLI on PATH (preinstalled on most WSL distros).
  - In OpenSSL 3.x the cipher must be passed as a flag (e.g. -chacha20), not as
    a bare positional arg; this script normalizes that for you.
  - Hardware crypto acceleration is disabled (OPENSSL_ia32cap / OPENSSL_armcap)
    to match the cross-architecture benchmark.
"""

import argparse
import os
import random
import subprocess
import sys
import tempfile
import time


def human(sec):
    return f"{sec*1000:8.1f} ms" if sec < 1 else f"{sec:8.3f} s "


def run_once(args, tmpdir):
    method = args.method if args.method.startswith('-') else '-' + args.method
    rounds = str(args.rounds)
    password = args.password
    cleartext_path = os.path.join(tmpdir, "cleartext")
    cipher_path = os.path.join(tmpdir, "ciphertext")

    timings = {}

    # ── Phase 1: generate the cleartext payload ──────────────────────────────
    t0 = time.perf_counter()
    if args.urandom:
        # Fast, NON-deterministic path (os.urandom). Cipher-dominated.
        data = os.urandom(args.blocksize)
        with open(cleartext_path, "wb") as f:
            f.write(data)
    else:
        # Deterministic AND fast: seeded random.randbytes (matches function.py).
        # Same seed -> byte-identical payload every run, but ~35x faster than
        # random.choices, so the cipher dominates the measured time.
        random.seed(args.seed)
        data = random.randbytes(args.blocksize)
        with open(cleartext_path, "wb") as f:
            f.write(data)
    timings["payload_gen+write"] = time.perf_counter() - t0

    # ── Disable CPU crypto acceleration ──────────────────────────────────────
    env = dict(os.environ)
    env["OPENSSL_armcap"] = "0"
    env["OPENSSL_ia32cap"] = "~0x20000000"

    # ── Phase 2: openssl version (cheap, but recorded like the function) ─────
    t0 = time.perf_counter()
    ver = subprocess.run(['openssl', 'version'], check=True,
                         stdout=subprocess.PIPE, env=env).stdout.decode().strip()
    timings["openssl_version"] = time.perf_counter() - t0

    # ── Phase 3: the cipher benchmark ────────────────────────────────────────
    t0 = time.perf_counter()
    subprocess.run(
        ['openssl', 'enc', method, '-salt', '-pbkdf2', '-iter', rounds,
         '-in', cleartext_path, '-out', cipher_path, '-pass', 'pass:' + password],
        check=True, stdout=subprocess.PIPE, env=env)
    timings["openssl_encrypt"] = time.perf_counter() - t0

    out_size = os.path.getsize(cipher_path)
    return timings, ver, out_size, method


def main():
    p = argparse.ArgumentParser(description="Local timer for the chacha20 benchmark.")
    p.add_argument('--method', default='chacha20', help="OpenSSL cipher (default chacha20)")
    p.add_argument('--rounds', type=int, default=100000, help="PBKDF2 iterations")
    p.add_argument('--password', default='benchmarkpass')
    p.add_argument('--seed', type=int, default=42)
    p.add_argument('--blocksize', type=int, default=8192000, help="payload bytes (default 8MB)")
    p.add_argument('--repeat', type=int, default=1, help="number of timed runs to average")
    p.add_argument('--urandom', action='store_true',
                   help="generate payload with os.urandom (fast; cipher-dominated)")
    args = p.parse_args()

    if not (args.repeat >= 1):
        sys.exit("--repeat must be >= 1")

    print("=" * 60)
    print("  ChaCha20 / OpenSSL local benchmark timer")
    print("=" * 60)
    print(f"  method      : {args.method}")
    print(f"  rounds      : {args.rounds}")
    print(f"  blocksize   : {args.blocksize:,} bytes ({args.blocksize/1e6:.1f} MB)")
    print(f"  payload gen : {'os.urandom (non-deterministic)' if args.urandom else 'seeded random.randbytes (deterministic)'}")
    print(f"  repeats     : {args.repeat}")
    print("-" * 60)

    totals = {}
    wall_times = []
    ver = ""
    out_size = 0
    method = args.method

    with tempfile.TemporaryDirectory() as tmpdir:
        for i in range(args.repeat):
            run_t0 = time.perf_counter()
            timings, ver, out_size, method = run_once(args, tmpdir)
            wall = time.perf_counter() - run_t0
            wall_times.append(wall)
            for k, v in timings.items():
                totals[k] = totals.get(k, 0.0) + v
            if args.repeat > 1:
                print(f"  run {i+1:>2}: {human(wall)} total")

    n = args.repeat
    print("-" * 60)
    print(f"  openssl     : {ver}")
    print(f"  cipher flag : {method}")
    print(f"  ciphertext  : {out_size:,} bytes")
    print("-" * 60)
    print("  Average per-phase timing:")
    for k in ["payload_gen+write", "openssl_version", "openssl_encrypt"]:
        if k in totals:
            print(f"    {k:<20}: {human(totals[k]/n)}")
    avg_wall = sum(wall_times) / n
    print(f"    {'TOTAL (wall)':<20}: {human(avg_wall)}")
    print("=" * 60)

    # Lambda-tier projection from this machine's (assumed ~full-core) time.
    print("  Rough Lambda projection (linear CPU scaling, 1769 MB = 1 vCPU):")
    print("  NOTE: assumes this machine ran at ~1 full vCPU and the work is")
    print("        CPU-bound. Treat as order-of-magnitude only.")
    for mem in (128, 256, 512, 1024, 1739, 1769, 3538):
        frac = mem / 1769.0
        proj = avg_wall / frac
        print(f"    {mem:>5} MB (~{frac:4.2f} vCPU): ~{proj:6.2f} s")
    print("=" * 60)


if __name__ == "__main__":
    main()