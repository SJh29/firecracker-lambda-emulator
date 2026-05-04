#!/usr/bin/env bash

# stages/05_wait_for_rie.sh — Stage 5: Wait for Lambda RIE to be ready
#
# Polls the RIE ping endpoint over the TAP IP until the guest runtime is
# accepting requests. No SSH required — all communication is HTTP via TAP.
#
# The RIE exposes:
#   GET  http://<guest>:8080/2018-06-01/ping          — health check
#   POST http://<guest>:8080/2015-03-31/functions/function/invocations — invoke

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

RIE_PING="http://${GUEST_IP}:${LAMBDA_PORT}/2018-06-01/ping"

log "Stage 5: Waiting for Lambda RIE at ${RIE_PING}"

attempts=0
max=60

until curl -sf --max-time 1 "$RIE_PING" &>/dev/null; do
    sleep 1
    (( attempts++ ))
    if (( attempts >= max )); then
        error "Lambda RIE never became ready after ${max}s"
        error "Check Firecracker logs: $LOGFILE"
        error "Hint: ensure the guest mounts /dev/vdb at /var/task before bootstrap runs"
        exit 1
    fi
    log "Waiting for RIE... ($attempts/${max})"
done

success "Stage 5 complete: Lambda RIE is ready"