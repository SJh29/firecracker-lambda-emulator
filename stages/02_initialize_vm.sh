#!/usr/bin/env bash

# stages/04_initialize_vm.sh — Stage 4: Boot microVM
#
# Sends the InstanceStart action to Firecracker. This is asynchronous;
# stage 05 polls the RIE health endpoint to detect when the guest is ready.

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

log "Stage 2: Booting microVM"

fc_api PUT /actions '{ "action_type": "InstanceStart" }'

# InstanceStart is asynchronous. The guest kernel + RIE bootstrap typically
# takes a few seconds; stage 05 will poll until the RIE is ready.
sleep 0.15

success "Stage 4 complete: InstanceStart sent"