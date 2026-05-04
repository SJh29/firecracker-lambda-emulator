#!/usr/bin/env bash

# stages/02_build_function_drive.sh — Stage 2: Build function ext4 drive
#
# Creates a small ext4 image containing the user's function.py at the path
# the Lambda RIE expects: /var/task/function.py
#
# The drive is mounted read-only by the guest at /var/task, which is the
# standard Lambda task root. The RIE will import handler from function.py.
#
# FUNCTION_FILE must be set in the environment (done by lambda_orchestrator.sh).

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

log "Stage 2: Building function drive"

FUNCTION_DRIVE="${SCRIPT_DIR}/function.ext4"
FUNCTION_STAGING="${SCRIPT_DIR}/function-staging"

# Clean up any previous staging dir or drive
rm -rf "$FUNCTION_STAGING"
rm -f  "$FUNCTION_DRIVE"

# Build staging directory matching Lambda's expected task layout
mkdir -p "$FUNCTION_STAGING/var/task"
cp "$FUNCTION_FILE" "$FUNCTION_STAGING/var/task/function.py"
log "Staged function: $FUNCTION_FILE → /var/task/function.py"

# Create a small ext4 image (32M is plenty for a function file)
truncate -s 32M "$FUNCTION_DRIVE"
mkfs.ext4 -d "$FUNCTION_STAGING" -F "$FUNCTION_DRIVE" &>/dev/null

# Clean up staging dir
rm -rf "$FUNCTION_STAGING"

# Export for use by stage 03
export FUNCTION_DRIVE

log "Function drive: $FUNCTION_DRIVE"
success "Stage 2 complete: function drive ready"