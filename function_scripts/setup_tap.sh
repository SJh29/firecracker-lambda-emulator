#!/usr/bin/env bash

# stages/01_tap_setup.sh - Stage 1: Host TAP interface + NAT
# Requires: ip, iptables, jq

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

log "Stage 1: TAP setup"

# requirements check
if ! command -v jq &>/dev/null; then
  error "jq is required to detect the host network interface."
  error "Install with: sudo apt-get install jq"
  exit 1
fi

# Delete any stale tap from a previous run, then recreate it cleanly.
sudo ip link del "$TAP_DEV" 2>/dev/null || true
sudo ip tuntap add dev "$TAP_DEV" mode tap
sudo ip addr add "${TAP_IP}${MASK_SHORT}" dev "$TAP_DEV"
sudo ip link set dev "$TAP_DEV" up
log "TAP device $TAP_DEV up at ${TAP_IP}${MASK_SHORT}"

# Without this the kernel drops packets that arrive on tap0 but are destined
# for a different interface rather than forwarding them.
sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
sudo iptables -P FORWARD ACCEPT
log "IP forwarding enabled"

# Rewrite the source IP of outbound guest traffic to the host's public IP so
# replies can find their way back (same as a home router doing NAT).
HOST_IFACE=$(ip -j route list default | jq -r '.[0].dev')
sudo iptables -t nat -D POSTROUTING -o "$HOST_IFACE" -j MASQUERADE 2>/dev/null || true
sudo iptables -t nat -A POSTROUTING -o "$HOST_IFACE" -j MASQUERADE
log "NAT masquerade enabled on $HOST_IFACE"

success "Stage 1 complete: TAP and NAT ready"