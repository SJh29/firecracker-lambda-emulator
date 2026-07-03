#!/usr/bin/env bash
# Creates a small ext4 image containing the user's function.py at the path
# the Lambda RIE expects: /var/task/function.py
#
# The drive is mounted by the guest at /var/task, which is the
# standard Lambda task root. The RIE will import handler from function.py.

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

log "Building function drive"

FUNCTION_DIR="${SCRIPT_DIR}/function"
FUNCTION_DRIVE="${SCRIPT_DIR}/function.ext4"
FUNCTION_STAGING="${SCRIPT_DIR}/function-staging"

# Clean up any previous staging dir or drive
rm -rf "$FUNCTION_STAGING"
rm -f  "$FUNCTION_DRIVE"

# The function folder must exist and contain at least one file to bundle
if [[ ! -d "$FUNCTION_DIR" ]]; then
    error "Function folder not found: $FUNCTION_DIR"
    exit 1
fi
if [[ -z "$(ls -A "$FUNCTION_DIR")" ]]; then
    error "Function folder is empty: $FUNCTION_DIR"
    exit 1
fi

# Build staging directory matching Lambda's expected task layout
# mkdir -p "$FUNCTION_STAGING/var/task"

# Bundle every file from the function folder (preserving any subfolders)
cp -a "$FUNCTION_DIR"/. "$FUNCTION_STAGING/"
while IFS= read -r f; do
    log "Staged: ${f#"$FUNCTION_DIR"/}"
done < <(find "$FUNCTION_DIR" -type f | sort)

# Create a small ext4 image (32M is plenty for a function file)
truncate -s 32M "$FUNCTION_DRIVE"
mkfs.ext4 -d "$FUNCTION_STAGING" -F "$FUNCTION_DRIVE" &>/dev/null

# Clean up staging dir
rm -rf "$FUNCTION_STAGING"

log "Function drive: $FUNCTION_DRIVE"
success "Function drive ready"