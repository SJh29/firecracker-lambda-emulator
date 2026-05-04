#!/usr/bin/env bash

# stages/06_invoke.sh — Stage 6: Invoke Lambda function via RIE HTTP endpoint
#
# POSTs the JSON payload directly to the RIE invocation endpoint over the TAP
# network. Prints the response body and exits non-zero on function errors.
#
# PAYLOAD and TIMEOUT must be set in the environment (done by lambda_orchestrator.sh).

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

INVOKE_URL="http://${GUEST_IP}:${LAMBDA_PORT}/2015-03-31/functions/function/invocations"

log "Stage 6: Invoking Lambda function"
log "Endpoint : $INVOKE_URL"
log "Payload  : $PAYLOAD"

RESPONSE=$(curl -sf \
    --max-time "$TIMEOUT" \
    -X POST "$INVOKE_URL" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")

EXIT_CODE=$?

echo
echo "── Lambda Response ──────────────────────────────────────"
echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
echo "─────────────────────────────────────────────────────────"
echo

# Check for a Lambda-level error in the response body
# RIE returns {"errorMessage": ..., "errorType": ...} on handler exceptions
if echo "$RESPONSE" | jq -e '.errorMessage' &>/dev/null; then
    error "Function returned an error (see response above)"
    exit 1
fi

if [[ $EXIT_CODE -ne 0 ]]; then
    error "curl failed with exit code $EXIT_CODE (timeout or connection error)"
    exit 1
fi

success "Stage 6 complete: invocation successful"