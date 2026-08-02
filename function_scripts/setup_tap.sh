#!/usr/bin/env bash

# setup_tap.sh — Host TAP interfaces + NAT
#
# Creates one TAP device per Firecracker instance, each on its own /30 so the
# host has an unambiguous route to every guest. Instance k gets tap<k> with host
# address 172.16.0.<4k+1>, facing guest 172.16.0.<4k+2>. See common.sh.
#
# Usage: sudo ./setup_tap.sh [-n NUM_INSTANCES]   (default: 1)
#
# Safe to re-run: each TAP is torn down and recreated, and the NAT rule is
# deleted before being re-added. run_firecracker.sh calls this automatically.
#
# Requires: ip, iptables, jq

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

NUM_INSTANCES=1
while getopts "n:h" opt; do
    case $opt in
        n) NUM_INSTANCES=$OPTARG ;;
        h) sed -n 's/^# \?//p' "$0" | head -n 12; exit 0 ;;
    esac
done

fc_check_instance "$(( NUM_INSTANCES - 1 ))" || exit 1

log "TAP setup for $NUM_INSTANCES instance(s)"

# requirements check
if ! command -v jq &>/dev/null; then
  error "jq is required to detect the host network interface."
  error "Install with: sudo apt-get install jq"
  exit 1
fi

for (( k=0; k<NUM_INSTANCES; k++ )); do
  tap="$(fc_tap "$k")"
  host_ip="$(fc_host_ip "$k")"

  # Delete any stale tap from a previous run, then recreate it cleanly.
  sudo ip link del "$tap" 2>/dev/null || true
  sudo ip tuntap add dev "$tap" mode tap
  sudo ip addr add "${host_ip}${MASK_SHORT}" dev "$tap"
  sudo ip link set dev "$tap" up
  log "TAP $tap up at ${host_ip}${MASK_SHORT} (guest $(fc_guest_ip "$k"))"
done

# Without this the kernel drops packets that arrive on a tap but are destined
# for a different interface rather than forwarding them.
sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
sudo iptables -P FORWARD ACCEPT
log "IP forwarding enabled"

# Rewrite the source IP of outbound guest traffic to the host's public IP so
# replies can find their way back (same as a home router doing NAT). One
# masquerade rule on the egress interface covers every tap.
HOST_IFACE=$(ip -j route list default | jq -r '.[0].dev')
sudo iptables -t nat -D POSTROUTING -o "$HOST_IFACE" -j MASQUERADE 2>/dev/null || true
sudo iptables -t nat -A POSTROUTING -o "$HOST_IFACE" -j MASQUERADE
log "NAT masquerade enabled on $HOST_IFACE"

success "TAP and NAT ready for $NUM_INSTANCES instance(s)"
