#!/bin/bash
# fc_arch.sh — detect arch and available power sources.
# Prints a short summary and a JSON-ish line for scripting.
#
# Usage: ./fc_arch.sh

set -e

ARCH=$(uname -m)
KERNEL=$(uname -r)
VENDOR=$(grep -m1 "vendor_id\|CPU implementer" /proc/cpuinfo 2>/dev/null \
            | awk -F: '{print $2}' | xargs || echo "unknown")
MODEL=$(grep -m1 "model name\|Processor" /proc/cpuinfo 2>/dev/null \
            | awk -F: '{print $2}' | xargs || echo "unknown")

# Detect power sources
HAS_RAPL=False
HAS_HWMON_ENERGY=False
HAS_BATTERY=False
HAS_TURBOSTAT=False
HAS_PERF=False

[[ -d /sys/class/powercap ]] && \
    ls /sys/class/powercap/ 2>/dev/null | grep -q intel-rapl && HAS_RAPL=True

if ls /sys/class/hwmon/hwmon*/energy*_input &>/dev/null; then
    HAS_HWMON_ENERGY=True
fi

ls /sys/class/power_supply/BAT* &>/dev/null && HAS_BATTERY=True
command -v turbostat &>/dev/null && HAS_TURBOSTAT=True
command -v perf &>/dev/null      && HAS_PERF=True

# Decide arch family
case "$ARCH" in
    x86_64|amd64)  FAMILY=x86 ;;
    aarch64|arm64) FAMILY=arm ;;
    *)             FAMILY=unknown ;;
esac

cat <<EOF
-----------------------------------------------------------
  Platform detection
-----------------------------------------------------------
  arch     : $ARCH ($FAMILY)
  kernel   : $KERNEL
  vendor   : $VENDOR
  model    : $MODEL

  Power sources:
    RAPL (sysfs)      : $HAS_RAPL
    hwmon energy      : $HAS_HWMON_ENERGY
    battery           : $HAS_BATTERY

  Tools:
    turbostat         : $HAS_TURBOSTAT
    perf              : $HAS_PERF
-----------------------------------------------------------
EOF

# Recommendations
echo "  Recommended scripts for this host:"
echo -e "    \xe2\x9c\x93 fc_proc.py        (always works)"
echo -e "    \xe2\x9c\x93 fc_pidstat.sh     (always works, needs sysstat)"
if [[ "$HAS_PERF" == True ]]; then
    echo -e "    \xe2\x9c\x93 fc_perf.sh        (works, arch-aware events)"
else
    echo -e "    \xC3\x97 fc_perf.sh        (perf not installed)"
fi
if [[ "$FAMILY" == x86 && "$HAS_RAPL" == True ]]; then
    echo -e "    \xe2\x9c\x93 fc_rapl.py        (x86 RAPL available)"
else
    echo -e "    \xC3\x97 fc_rapl.py        (no x86 RAPL on this host)"
fi
if [[ "$FAMILY" == arm ]]; then
    if [[ "$HAS_HWMON_ENERGY" == True ]]; then
        echo -e "    \xe2\x9c\x93 fc_arm_power.py   (hwmon energy sensors found)"
    else
        echo "    WARN: fc_arm_power.py   (no hwmon energy sensors — may run empty)"
    fi
fi
if [[ "$FAMILY" == x86 && "$HAS_TURBOSTAT" == True &&  ! "$VENDOR" == "AuthenticAMD" ]]; then
    echo -e "    \xe2\x9c\x93 fc_turbostat.sh   (x86 + turbostat installed)"
else
    echo "    Turbostat Incompatible With Vendor"
    HAS_TURBOSTAT=False
fi

# Machine-readable line
echo
echo "FCTOOLS_ENV: family=$FAMILY arch=$ARCH rapl=$HAS_RAPL hwmon=$HAS_HWMON_ENERGY battery=$HAS_BATTERY turbostat=$HAS_TURBOSTAT perf=$HAS_PERF"