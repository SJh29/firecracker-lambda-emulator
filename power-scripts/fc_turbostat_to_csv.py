#!/usr/bin/env python3
"""
fc_turbostat_to_csv.py — normalize turbostat --Summary output into the same
CSV schema fc_rapl.py emits, so fc_analyze.py / fc_analyze_pkg.py can consume
turbostat as a power source on hosts without RAPL sysfs (e.g. EC2 .metal).

Reads turbostat's whitespace-delimited summary table on stdin and writes
`timestamp,elapsed_s,<col>...` CSV to OUT. turbostat power columns are renamed
to the rapl `*_watts` convention (PkgWatt->package_watts, RAMWatt->dram_watts,
CorWatt->core_watts, GFXWatt->gfx_watts) so power_col()/the RAPL-stack plot
pick them up unchanged. Per-row timestamps are real wall-clock (turbostat
flushes each interval), which is what the analyzer's wall-clock alignment needs.

Usage: turbostat ... | fc_turbostat_to_csv.py OUT_CSV [INTERVAL_SECS]
"""

import csv, sys, time
from datetime import datetime, timezone

WATT_MAP = {
    "PkgWatt": "package_watts",
    "CorWatt": "core_watts",
    "RAMWatt": "dram_watts",
    "GFXWatt": "gfx_watts",
}


def sanitize(col):
    if col in WATT_MAP:
        return WATT_MAP[col]
    return col.replace("%", "_pct").replace("/", "_").lower()


def is_header(tokens):
    """A data row starts with a numeric value; a header row does not."""
    try:
        float(tokens[0])
        return False
    except ValueError:
        return True


def main():
    out_path = sys.argv[1]
    interval = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0

    fieldnames = None
    writer = None
    f = None
    cur_cols = None
    t0 = None

    for line in sys.stdin:
        toks = line.split()
        if not toks:
            continue
        if is_header(toks):
            cur_cols = toks
            if writer is None:
                fieldnames = ["timestamp", "elapsed_s"] + [sanitize(c) for c in cur_cols]
                f = open(out_path, "w", newline="")
                writer = csv.DictWriter(f, fieldnames=fieldnames)
                writer.writeheader()
            continue
        if writer is None:
            continue  # data before any header — skip
        now = time.monotonic()
        if t0 is None:
            t0 = now - interval  # first sample lands at ~interval, matching fc_rapl.py
        row = {
            "timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
            "elapsed_s": round(now - t0, 3),
        }
        for col, val in zip(cur_cols, toks):
            key = sanitize(col)
            if key in fieldnames:
                row[key] = val
        writer.writerow(row)
        f.flush()

    if f:
        f.close()


if __name__ == "__main__":
    main()
