#!/usr/bin/env bash
# run_saaf_experiment.sh — drive every running microVM with saaf_driver.py.
#
# Discovers the running instances, generates their function JSONs, pins the
# driver to CPUs no guest is using, and runs it.
#
# Usage: ./run_saaf_experiment.sh [-e EXPERIMENT] [-o OUTDIR] [-N NAME]
#   -e EXPERIMENT  Experiment JSON (default: <repo>/saaf/experiment-fidelity.json).
#   -o OUTDIR      Results directory (default: <repo>/saaf/results/<timestamp>).
#   -N NAME        Report file prefix (default: firecracker).
#
# Env: SAAF_DIR  Path to the SAAF checkout (default: <repo>/SAAF).

set -e
source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

SAAF_DIR="${SAAF_DIR:-$SCRIPT_DIR/SAAF}"
EXPERIMENT="$SCRIPT_DIR/saaf-experiment/experiment-fidelity.json"
OUTDIR=""
NAME="firecracker"

while getopts "e:o:N:h" opt; do
  case $opt in
  e) EXPERIMENT=$OPTARG ;;
  o) OUTDIR=$OPTARG ;;
  N) NAME=$OPTARG ;;
  h)
    sed -n '/^# Usage:/,/^$/{ s/^# \?//; p; }' "$0"
    exit 0
    ;;
  esac
done

OUTDIR="${OUTDIR:-$SCRIPT_DIR/saaf/results/$(date +%Y%m%d-%H%M%S)}"

# ── Preflight ───────────────────────────────────────────────────────────────
[[ -f "$SAAF_DIR/test/tools/report_generator.py" ]] || {
  error "SAAF not found at $SAAF_DIR (expected $SAAF_DIR/test/tools/report_generator.py)"
  error "initialize the submodule with: git submodule update --init"
  exit 1
}
[[ -f "$EXPERIMENT" ]] || { error "experiment file not found: $EXPERIMENT"; exit 1; }

python3 -c 'import requests' 2>/dev/null || {
  error "the python3 'requests' module is required"
  exit 1
}

TARGETS=($(fc_instances))
((${#TARGETS[@]})) || {
  error "no running instances found in $API_SOCKET_FOLDER — start them with run_firecracker.sh"
  exit 1
}

# An unmetered guest is not held to the Lambda CPU allocation, so its durations
# are not comparable against real Lambda.
for k in "${TARGETS[@]}"; do
  quota="$(cat "$FC_CGROUP/vm$k/cpu.max" 2>/dev/null || echo unknown)"
  if [[ "$quota" == max* ]]; then
    warn "instance $k has cpu.max=max — durations will not be comparable. Relaunch without -u."
    break
  fi
done

# ── Run ─────────────────────────────────────────────────────────────────────
FUNCDIR="$OUTDIR/functions"
mkdir -p "$FUNCDIR"
bash "$SCRIPT_DIR/function_scripts/gen_saaf_functions.sh" -o "$FUNCDIR" -N "$NAME" >/dev/null

FUNCS=()
for k in "${TARGETS[@]}"; do FUNCS+=("$FUNCDIR/vm$k.json"); done

CLIENT_CPUS="$(fc_free_cpus)"
[[ -n "$CLIENT_CPUS" ]] || warn "instances are not pinned — the driver will share cores with the guests."

log "instances : ${#TARGETS[@]} (${TARGETS[*]})"
log "experiment: $EXPERIMENT"
log "driver cpus: ${CLIENT_CPUS:-unrestricted}"
log "output    : $OUTDIR"

CMD=(python3 "$SCRIPT_DIR/function_scripts/saaf_driver.py"
  -f "${FUNCS[@]}"
  -e "$EXPERIMENT"
  -o "$OUTDIR"
  --saaf "$SAAF_DIR"
  --name "$NAME")
[[ -n "$CLIENT_CPUS" ]] && CMD=(taskset -c "$CLIENT_CPUS" "${CMD[@]}")

"${CMD[@]}" 2>&1 | tee "$OUTDIR/driver.log"
rc="${PIPESTATUS[0]}"

((rc == 0)) || { error "saaf_driver.py failed (exit $rc) — see $OUTDIR/driver.log"; exit "$rc"; }
success "experiment complete → $OUTDIR"
