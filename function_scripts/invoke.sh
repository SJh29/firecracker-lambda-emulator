#!/usr/bin/env bash

# invoke.sh — Invoke the Lambda function via the RIE HTTP endpoint.
#
# POSTs the JSON payload directly to the RIE invocation endpoint over the TAP
# network. Prints the response body and exits non-zero on function errors.
#
# Usage: ./invoke.sh [-i INSTANCE] [-a] [-p PAYLOAD] [-t TIMEOUT]
#   -i INSTANCE  Instance id to invoke (default: 0)
#   -a           Invoke every running instance concurrently and wait for all of
#                them. Exits non-zero if any invocation fails.
#   -p PAYLOAD   JSON payload (default: the chacha20 benchmark below)
#   -t TIMEOUT   Seconds to wait for a response (default: 300)

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

INSTANCE=0
ALL=0
PAYLOAD='{"method": "chacha20", "rounds": 100000, "password": "benchmarkpass", "seed": 42}'
TIMEOUT=300

while getopts "i:ap:t:h" opt; do
    case $opt in
        i) INSTANCE=$OPTARG ;;
        a) ALL=1 ;;
        p) PAYLOAD=$OPTARG ;;
        t) TIMEOUT=$OPTARG ;;
        h) sed -n 's/^# \?//p' "$0" | head -n 12; exit 0 ;;
    esac
done

# Invoke one instance. Prints its response; returns non-zero on transport
# failure or on a Lambda-level error in the body.
invoke_one() {
    local k="$1"
    local url="http://$(fc_guest_ip "$k"):${LAMBDA_PORT}/2015-03-31/functions/function/invocations"
    local response rc

    log "instance $k → $url"
    response=$(curl -sf \
        --max-time "$TIMEOUT" \
        -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD")
    rc=$?

    {
        echo
        echo "── Lambda Response (instance $k) ────────────────────────"
        echo "$response" | jq . 2>/dev/null || echo "$response"
        echo "─────────────────────────────────────────────────────────"
    }

    if [[ $rc -ne 0 ]]; then
        error "instance $k: curl failed with exit code $rc (timeout or connection error)"
        return 1
    fi

    # RIE returns {"errorMessage": ..., "errorType": ...} on handler exceptions
    if echo "$response" | jq -e '.errorMessage' &>/dev/null; then
        error "instance $k: function returned an error (see response above)"
        return 1
    fi
    return 0
}

if (( ALL )); then
    TARGETS=($(fc_instances))
    (( ${#TARGETS[@]} )) || { error "no running instances found in $API_SOCKET_FOLDER"; exit 1; }
else
    fc_check_instance "$INSTANCE" || exit 1
    [[ -S "$(fc_socket "$INSTANCE")" ]] || { error "instance $INSTANCE is not running ($(fc_socket "$INSTANCE") missing)"; exit 1; }
    TARGETS=("$INSTANCE")
fi

log "Invoking ${#TARGETS[@]} instance(s)"
log "Payload : $PAYLOAD"

# Fan out concurrently so N instances are measured under simultaneous load
# rather than one after another. Each response is buffered to a temp file and
# flushed in instance order, so parallel output doesn't interleave.
TMPDIR_OUT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_OUT"' EXIT

PIDS=()
for k in "${TARGETS[@]}"; do
    invoke_one "$k" > "$TMPDIR_OUT/$k.out" 2>"$TMPDIR_OUT/$k.err" &
    PIDS+=($!)
done

FAILED=0
for i in "${!TARGETS[@]}"; do
    wait "${PIDS[$i]}" || FAILED=1
done

for k in "${TARGETS[@]}"; do
    cat "$TMPDIR_OUT/$k.out"
    cat "$TMPDIR_OUT/$k.err" >&2
done

if (( FAILED )); then
    error "one or more invocations failed"
    exit 1
fi

success "Invocation successful on ${#TARGETS[@]} instance(s)"
