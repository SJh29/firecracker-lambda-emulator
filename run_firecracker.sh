#!/bin/bash
# run_firecracker.sh — must be run with sudo (Firecracker needs root for /dev/kvm)
set -e

# Resolve project root from the script's own location. Works under sudo because
# it doesn't rely on $HOME or $USER — only on where this script physically lives.
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

SOCKET="${SOCKET:-/tmp/firecracker.socket}"

# Clean any stale socket (Firecracker refuses to start if it already exists)
sudo rm -f "$SOCKET"

# Generate the runtime config with absolute paths derived from HERE
sed "s|@ROOT@|$HERE|g" "$HERE/vm_config.template.json" > "$HERE/vm_config.json"

exec "$HERE/firecracker" \
    --api-sock "$SOCKET" \
    --config-file "$HERE/vm_config.json"

#sudo $DIR/firecracker --api-sock "${API_SOCKET}" --enable-pci --config-file $DIR/vm_config.json