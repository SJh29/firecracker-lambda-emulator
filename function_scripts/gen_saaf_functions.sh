#!/usr/bin/env bash
# gen_saaf_functions.sh — write one SAAF function JSON per running instance.
#
# Each file points at that VM's RIE endpoint, so a separate faas_runner process
# can be aimed at each one.
#
# Usage: ./gen_saaf_functions.sh [-o OUTDIR] [-N NAME]
#   -o OUTDIR  Directory to write into (default: <repo>/saaf/functions).
#   -N NAME    Base function name (default: firecracker).

set -e
source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

OUTDIR="$SCRIPT_DIR/saaf/functions"
NAME="firecracker"

while getopts "o:N:h" opt; do
  case $opt in
  o) OUTDIR=$OPTARG ;;
  N) NAME=$OPTARG ;;
  h)
    sed -n '/^# Usage:/,/^$/{ s/^# \?//; p; }' "$0"
    exit 0
    ;;
  esac
done

TARGETS=($(fc_instances))
((${#TARGETS[@]})) || {
  error "no running instances found in $API_SOCKET_FOLDER"
  exit 1
}

mkdir -p "$OUTDIR"
rm -f "$OUTDIR"/vm*.json

for k in "${TARGETS[@]}"; do
  out="$OUTDIR/vm$k.json"
  jq -n \
    --arg function "$NAME-vm$k" \
    --arg endpoint "http://$(fc_guest_ip "$k"):${LAMBDA_PORT}/2015-03-31/functions/function/invocations" \
    '{ function: $function, platform: "HTTP", source: "", endpoint: $endpoint }' \
    >"$out"
  log "instance $k → $out"
done

success "wrote ${#TARGETS[@]} function file(s) to $OUTDIR"
