#!/usr/bin/env bash

# stages/03_configure_vm.sh — Stage 3: Configure microVM via API socket
#
# Configures logger, kernel, rootfs (aws_baseimage.ext4), function drive, and
# network interface. The function drive is attached as a secondary read-only
# drive; the guest init is expected to mount it at /var/task before the RIE
# bootstrap runs.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../config.sh

log "Stage 3: Configuring microVM via API socket"

fc_api PUT /logger "{
    \"log_path\": \"${LOGFILE}\",
    \"level\": \"Debug\",
    \"show_level\": true,
    \"show_log_origin\": true
}"
log "Logger configured → $LOGFILE"

# console=ttyS0  — send kernel output to the serial console
# reboot=k       — treat a reboot syscall as a full halt (Firecracker exits)
# panic=1        — reboot (i.e. halt) 1 second after a kernel panic
KERNEL_BOOT_ARGS="console=ttyS0 reboot=k panic=1 init=/var/runtime/bootstrap handler=function.handler func_mem_size=${MEM_SIZE} func_timeout=${FUNC_TIMEOUT}"

# aarch64 needs keep_bootcon to preserve early boot messages on the console
if [ "$(uname -m)" = "aarch64" ]; then
  KERNEL_BOOT_ARGS="keep_bootcon ${KERNEL_BOOT_ARGS}"
fi

fc_api PUT /boot-source "{
    \"kernel_image_path\": \"${KERNEL}\",
    \"boot_args\": \"${KERNEL_BOOT_ARGS}\"
}"
log "Boot source set: $KERNEL"

# Root filesystem (Lambda base image)
fc_api PUT /drives/rootfs "{
    \"drive_id\": \"rootfs\",
    \"path_on_host\": \"${ROOTFS}\",
    \"is_root_device\": true,
    \"is_read_only\": false
}"
log "Rootfs set: $ROOTFS"

# Function drive — mounted read-only at /var/task inside the guest.
# The guest's init/rc script should mount /dev/vdb at /var/task before
# the RIE bootstrap runs.
fc_api PUT /drives/function "{
    \"drive_id\": \"function\",
    \"path_on_host\": \"${FUNCTION_DRIVE}\",
    \"is_root_device\": false,
    \"is_read_only\": true
}"
log "Function drive attached: $FUNCTION_DRIVE → /dev/vdb (guest mounts at /var/task)"

# Network interface
# The guest MAC 06:00:AC:10:00:02 is used to derive the static guest IP
# (172.16.0.2). Changing the MAC requires changing GUEST_IP in common.sh.
fc_api PUT /network-interfaces/net1 "{
    \"iface_id\": \"net1\",
    \"guest_mac\": \"$FC_MAC\",
    \"host_dev_name\": \"$TAP_DEV\"
}"
log "Network interface attached (MAC=$FC_MAC → $TAP_DEV)"

# Firecracker handles API requests asynchronously. Wait briefly so all config
# is applied before InstanceStart is sent in the next stage.
sleep 0.015

success "Stage 3 complete: microVM configured"

