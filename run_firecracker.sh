#!/bin/bash
# run_firecracker.sh — must be run with sudo (Firecracker needs root for /dev/kvm)
#
# Usage: sudo ./run_firecracker.sh [-m MEM_MIB]
#   -m MEM_MIB   Override guest memory (MiB). Also updates func_mem_size in
#                boot_args so the guest init agrees with machine-config.
set -e

# Resolve project root from the script's own location. Works under sudo because
# it doesn't rely on $HOME or $USER — only on where this script physically lives.
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

MEM_OVERRIDE=""
while getopts "m:h" opt; do
  case $opt in
  m) MEM_OVERRIDE=$OPTARG ;;
  h)
    sed -n 's/^# \?//p' "$0" | head -n 5
    exit 0
    ;;
  esac
done

SOCKET="${SOCKET:-/tmp/firecracker.socket}"

# Clean any stale socket (Firecracker refuses to start if it already exists)
sudo rm -f "$SOCKET"

# Generate the runtime config with absolute paths derived from HERE
sed "s|@ROOT@|$HERE|g" "$HERE/vm_config.template.json" >"$HERE/vm_config.json"

# Apply -m override: bump mem_size_mib and the matching func_mem_size kernel arg.
if [[ -n "$MEM_OVERRIDE" ]]; then
  tmp="$HERE/vm_config.json.tmp"
  jq --argjson m "$MEM_OVERRIDE" '
        ."machine-config".mem_size_mib = $m
        | ."boot-source".boot_args |= sub("func_mem_size=[0-9]+"; "func_mem_size=\($m)")
    ' "$HERE/vm_config.json" >"$tmp" && mv "$tmp" "$HERE/vm_config.json"
fi

# ── Per-instance CPU quota via cgroup v2 ────────────────────────────────────
# Allocate 1 full vCPU of host CPU time per 1769 MB of guest memory (AWS Lambda
# ratio). vm_config.json's vcpu_count only creates virtual CPUs inside the guest;
# the real host CPU allocation is enforced here via cpu.max. When guest memory
# crosses 1769 MB the quota exceeds 1 vCPU, so bump vcpu_count to ceil(mem/1769)
# so the guest can actually schedule across more than one host CPU.
MEM_MIB=$(jq -r '."machine-config".mem_size_mib' "$HERE/vm_config.json")
CPU_PERIOD_US=100000
CPU_QUOTA_US=$((MEM_MIB * CPU_PERIOD_US / 1769))
((CPU_QUOTA_US > 0)) || CPU_QUOTA_US=1000
if ((MEM_MIB > 1769)); then
  NEW_VCPU=$(((MEM_MIB + 1768) / 1769)) # ceil(MEM_MIB / 1769)
  tmp="$HERE/vm_config.json.tmp"
  jq --argjson v "$NEW_VCPU" '."machine-config".vcpu_count = $v' \
    "$HERE/vm_config.json" >"$tmp" && mv "$tmp" "$HERE/vm_config.json"
fi

CGROUP=/sys/fs/cgroup/firecracker
sudo mkdir -p "$CGROUP"
# Replace max with $CPU_QUOTA_US to enable memory based cpupower allocation.
echo "max $CPU_PERIOD_US" | sudo tee "$CGROUP/cpu.max" >/dev/null
echo $$ | sudo tee "$CGROUP/cgroup.procs" >/dev/null
echo "Firecracker cgroup: $CGROUP  cpu.max=$CPU_QUOTA_US/$CPU_PERIOD_US  (MEM=${MEM_MIB} MiB)"

exec "$HERE/firecracker" \
  --api-sock "$SOCKET" \
  --config-file "$HERE/vm_config.json"

#sudo $DIR/firecracker --api-sock "${API_SOCKET}" --enable-pci --config-file $DIR/vm_config.json

