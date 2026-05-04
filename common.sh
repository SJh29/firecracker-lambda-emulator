#!/usr/bin/env bash
# network constants 
API_SOCKET="/tmp/firecracker.socket"
LOGFILE="./firecracker.log"

TAP_DEV="tap0"
TAP_IP="172.16.0.1"
MASK_SHORT="/30"

FC_MAC="06:00:AC:10:00:02"
GUEST_IP="172.16.0.2"

LAMBDA_PORT=8080
RUNTIME_SCRIPT="lambda_runtime.py"

# helper functions for logging and API calls
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log()     { echo -e "${BLUE}[lambda]${NC} $*"; }
success() { echo -e "${GREEN}[lambda]${NC} $*"; }
warn()    { echo -e "${YELLOW}[lambda]${NC} $*"; }
error()   { echo -e "${RED}[lambda]${NC} $*" >&2; }

# firecracker API helper function
# Usage: fc_api <METHOD> <PATH> <JSON_BODY>
fc_api() {
    local method="$1" path="$2" data="$3"
    sudo curl -sS -X "$method" --unix-socket "$API_SOCKET" \
        --data "$data" \
        "http://localhost${path}"
}

# ssh/scp helper for guest access. It is expected to run with 
# KEY_NAME must be set before these are called (done in lambda_orchestrator.sh).
ssh_guest() {
    ssh -i "$KEY_NAME" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=5 \
        root@"$GUEST_IP" "$@"
}

scp_to_guest() {
    scp -i "$KEY_NAME" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "$1" root@"$GUEST_IP":"$2"
}