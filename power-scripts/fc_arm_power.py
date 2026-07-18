#!/usr/bin/env python3
"""
fc_arm_power.py — power monitor for ARM systems (Graviton, etc).

ARM CPUs don't expose RAPL. Power data, when available, comes from:
  - /sys/class/hwmon/hwmon*/energy*_input  (microjoules)
  - /sys/class/hwmon/hwmon*/power*_input   (microwatts)
  - BMC/ACPI sensors (varies by platform)

On AWS Graviton metal there is currently NO public per-socket power
counter. This script will still run and capture whatever hwmon sensors
exist (temperatures, fan speeds, sometimes voltage rails).

Usage: sudo fc_arm_power.py [--socket PATH] [--interval SECS] [--duration SECS] [--out CSV]
"""

import argparse, csv, sys, time
from datetime import datetime, timezone
from pathlib import Path

HWMON = Path("/sys/class/hwmon")

def discover_sensors():
    """Return list of (label, file_path, unit, divisor) tuples for available sensors."""
    sensors = []
    if not HWMON.exists(): return sensors
    for h in sorted(HWMON.iterdir()):
        try: name = (h / "name").read_text().strip()
        except: name = h.name

        for f in sorted(h.iterdir()):
            fn = f.name
            # energy*_input → µJ (we'll delta to compute watts)
            if fn.startswith("energy") and fn.endswith("_input"):
                lbl = _label(h, fn, "energy")
                sensors.append((f"{name}_{lbl}_energy_uj", f, "uj", 1))
            # power*_input → µW
            elif fn.startswith("power") and fn.endswith("_input"):
                lbl = _label(h, fn, "power")
                sensors.append((f"{name}_{lbl}_power_w", f, "uw", 1_000_000))
            # temp*_input → m°C
            elif fn.startswith("temp") and fn.endswith("_input"):
                lbl = _label(h, fn, "temp")
                sensors.append((f"{name}_{lbl}_temp_c", f, "mC", 1000))
            # in*_input → mV (voltage)
            elif fn.startswith("in") and fn.endswith("_input"):
                lbl = _label(h, fn, "in")
                sensors.append((f"{name}_{lbl}_volt_v", f, "mV", 1000))
            # fan*_input → RPM
            elif fn.startswith("fan") and fn.endswith("_input"):
                lbl = _label(h, fn, "fan")
                sensors.append((f"{name}_{lbl}_fan_rpm", f, "rpm", 1))
    return sensors

def _label(hwmon_dir, fname, prefix):
    """Try to read foo_label for human-readable names."""
    base = fname.replace("_input", "")
    label_file = hwmon_dir / f"{base}_label"
    if label_file.exists():
        try: return label_file.read_text().strip().replace(" ", "_")
        except: pass
    return base

def read_val(path):
    try: return int(path.read_text().strip())
    except: return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", default="/tmp/firecracker/0.socket",
                    help="informational only")
    ap.add_argument("--interval", "-i", type=float, default=1.0)
    ap.add_argument("--duration", "-d", type=float, default=60.0)
    ap.add_argument("--out", "-o",
                    default=f"hwmon_{datetime.now(timezone.utc):%Y%m%d_%H%M%S}.csv")
    args = ap.parse_args()

    sensors = discover_sensors()
    if not sensors:
        sys.exit("ERROR: no hwmon sensors found under /sys/class/hwmon. "
                 "On Graviton this is expected — power data is not exposed.")

    print(f"[arm_power] found {len(sensors)} sensors:")
    for label, _, _, _ in sensors[:20]:
        print(f"  - {label}")
    if len(sensors) > 20:
        print(f"  ... and {len(sensors)-20} more")
    print(f"[arm_power] {args.interval}s × {args.duration}s → {args.out}")

    # Energy sensors need delta math → derived watts column
    energy_sensors = [s for s in sensors if s[0].endswith("_energy_uj")]

    cols = ["timestamp", "elapsed_s"] + [s[0] for s in sensors]
    cols += [s[0].replace("_energy_uj", "_derived_watts") for s in energy_sensors]

    prev_energy = {s[0]: read_val(s[1]) for s in energy_sensors}
    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        t0 = last = time.monotonic()
        while True:
            time.sleep(max(0, args.interval - (time.monotonic() - last)))
            now = time.monotonic()
            dt = now - last
            row = {
                "timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
                "elapsed_s": round(now - t0, 3),
            }
            # raw values, scaled
            for label, path, unit, div in sensors:
                v = read_val(path)
                if v is None:
                    row[label] = None
                else:
                    row[label] = round(v / div, 4) if div != 1 else v

            # derived watts from energy deltas
            for label, path, _, _ in energy_sensors:
                v = read_val(path)
                prev = prev_energy.get(label)
                if v is not None and prev is not None and dt > 0:
                    delta = v - prev
                    if delta < 0: delta += 2**32   # wrap
                    row[label.replace("_energy_uj", "_derived_watts")] = round(
                        (delta / 1e6) / dt, 4
                    )
                prev_energy[label] = v

            w.writerow(row); f.flush()
            last = now
            if (now - t0) >= args.duration: break

    print(f"[arm_power] Done → {args.out}")

if __name__ == "__main__":
    main()