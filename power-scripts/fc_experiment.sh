#!/bin/bash
# fc_experiment.sh — run an end-to-end power-measurement experiment.
#
# 1. Launch run_firecracker.sh in a separate terminal
# 2. Wait for the socket
# 3. Start collectors at 1 Hz
# 4. Invoke ../function-scripts/invoke.sh N times
# 5. Stop collectors
# 6. Kill Firecracker
#
# Each invocation's stdout/stderr is captured to invocations/<n>.log
# and start/end timestamps go to invocations.csv so you can correlate
# with power traces.
#
# Usage:
#   sudo ./fc_experiment.sh [OPTIONS]
#
# Options:
#   -n COUNT            Number of invocations  (default: 10)
#   -s SOCKET           Firecracker socket  (default: /tmp/firecracker.socket)
#   -l LAUNCH_SCRIPT    run_firecracker.sh path  (default: ./run_firecracker.sh)
#   -I INVOKE_SCRIPT    invoke.sh path  (default: ../function-scripts/invoke.sh)
#   -d DELAY            Seconds between invocations  (default: 2)
#   -E EST_SECS         Estimated seconds per invocation; sizes how long the
#                       collectors run so they outlast the experiment (default: 10)
#   -o OUTDIR           Output dir  (default: experiment_<ts>)
#   -t TERMINAL         gnome-terminal | konsole | xterm | tmux | screen | bg
#                       default: auto
#   -q                  Don't capture invocation stdout/stderr per file

set -e

# Resolve script location and project root up front so defaults don't
# depend on the current working directory.
DIR="$(cd "$(dirname "$0")" && pwd)"   # power-scripts/
ROOT="$(cd "$DIR/.." && pwd)"          # project root

# ── defaults ─────────────────────────────────────────────
COUNT=10
SOCKET=/tmp/firecracker.socket
LAUNCH="$ROOT/run_firecracker.sh"
INVOKE="$ROOT/function_scripts/invoke.sh"
DELAY=2
OUTDIR=""
TERM_KIND=auto
CAPTURE=1
EST_INVOKE_SECS=10   # estimated seconds per invocation; sizes collector duration

while getopts "n:s:l:I:d:o:t:E:qh" opt; do
    case $opt in
        n) COUNT=$OPTARG ;;
        s) SOCKET=$OPTARG ;;
        l) LAUNCH=$OPTARG ;;
        I) INVOKE=$OPTARG ;;
        d) DELAY=$OPTARG ;;
        o) OUTDIR=$OPTARG ;;
        t) TERM_KIND=$OPTARG ;;
        E) EST_INVOKE_SECS=$OPTARG ;;
        q) CAPTURE=0 ;;
        h) sed -n 's/^# \?//p' "$0" | head -n 32; exit 0 ;;
    esac
done

OUTDIR=${OUTDIR:-experiment_$(date -u +%Y%m%d_%H%M%S)}
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"   # absolute path so collectors (esp. perf --output) resolve it correctly
[[ $CAPTURE -eq 1 ]] && mkdir -p "$OUTDIR/invocations"

[[ -f "$LAUNCH" ]] || { echo "ERROR: launch script not found: $LAUNCH" >&2; exit 1; }
[[ -f "$INVOKE" ]] || { echo "ERROR: invoke script not found: $INVOKE" >&2; exit 1; }

echo "═══════════════════════════════════════════════════════════"
echo "  fc_experiment"
echo "═══════════════════════════════════════════════════════════"
echo "  launch    : $LAUNCH"
echo "  invoke    : $INVOKE"
echo "  socket    : $SOCKET"
echo "  count     : $COUNT × (${DELAY}s gap)"
echo "  capture   : $([[ $CAPTURE -eq 1 ]] && echo yes || echo no)"
echo "  output    : $OUTDIR"
echo "═══════════════════════════════════════════════════════════"
echo

# ── 1. Launch Firecracker ────────────────────────────────
echo "[1/6] Launching Firecracker..."
if [[ "$TERM_KIND" == "auto" ]]; then
    if   command -v gnome-terminal &>/dev/null; then TERM_KIND=gnome-terminal
    elif command -v konsole        &>/dev/null; then TERM_KIND=konsole
    elif command -v xterm          &>/dev/null; then TERM_KIND=xterm
    elif command -v tmux           &>/dev/null; then TERM_KIND=tmux
    elif command -v screen         &>/dev/null; then TERM_KIND=screen
    else TERM_KIND=bg; fi
fi
echo "      terminal: $TERM_KIND"

FC_LOG="$OUTDIR/firecracker.log"
case "$TERM_KIND" in
    gnome-terminal) gnome-terminal -- bash -c "$LAUNCH 2>&1 | tee $FC_LOG; exec bash" ;;
    konsole)        konsole -e bash -c "$LAUNCH 2>&1 | tee $FC_LOG; exec bash" & ;;
    xterm)          xterm -hold -e "bash -c '$LAUNCH 2>&1 | tee $FC_LOG'" & ;;
    tmux)           tmux new-session -d -s fc_exp "$LAUNCH 2>&1 | tee $FC_LOG" ;;
    screen)         screen -dmS fc_exp bash -c "$LAUNCH 2>&1 | tee $FC_LOG" ;;
    bg)             nohup bash "$LAUNCH" >"$FC_LOG" 2>&1 &
                    echo "$!" > "$OUTDIR/firecracker.pid" ;;
    *)              echo "ERROR: unknown terminal $TERM_KIND"; exit 1 ;;
esac

# ── 2. Wait for socket ───────────────────────────────────
echo "[2/6] Waiting for $SOCKET ..."
for i in $(seq 1 30); do
    [[ -S "$SOCKET" ]] && break
    sleep 0.5
done
if [[ ! -S "$SOCKET" ]]; then
    echo "ERROR: socket never appeared at $SOCKET after 15s." >&2
    echo "  Check that run_firecracker.sh actually starts Firecracker on this socket." >&2
    echo "  Firecracker log tail:" >&2
    tail -20 "$FC_LOG" 2>/dev/null | sed 's/^/    /' >&2
    exit 1
fi
# Brief settle, then confirm Firecracker is actually alive
sleep 1
FC_PID=$(sudo bash "$DIR/fc_pid.sh" "$SOCKET" 2>/dev/null || true)
if [[ -z "$FC_PID" ]]; then
    echo "ERROR: socket exists but no firecracker process owns it." >&2
    echo "  Firecracker may have crashed after creating the socket. Log tail:" >&2
    tail -20 "$FC_LOG" 2>/dev/null | sed 's/^/    /' >&2
    exit 1
fi
echo "      Firecracker PID: $FC_PID"
echo

# ── 3. Start collectors ──────────────────────────────────
echo "[3/6] Starting collectors at 1 Hz..."
# Collectors must outlast the whole experiment. Each iteration costs
# roughly EST_INVOKE_SECS (the invocation) + DELAY (the gap). Add a margin
# for the 3s pre/post baseline sleeps plus startup overhead.
PER_ITER=$(echo "$EST_INVOKE_SECS + $DELAY" | bc -l)
TOTAL_DURATION=$(printf '%.0f' "$(echo "$COUNT * $PER_ITER + 30" | bc -l)")
echo "      est. per-invocation: ${EST_INVOKE_SECS}s, collectors run for ${TOTAL_DURATION}s"
COLLECTORS=()
start() {
    local name=$1; shift
    "$@" > "$OUTDIR/$name.log" 2>&1 &
    COLLECTORS+=($!)
    echo "      started: $name (pid $!)"
}

ARCH=$(uname -m)
start proc  sudo python3 "$DIR/fc_proc.py"  --socket "$SOCKET" -i 1 -d "$TOTAL_DURATION" -o "$OUTDIR/proc.csv"
command -v pidstat &>/dev/null && \
    start pidstat sudo bash "$DIR/fc_pidstat.sh" "$SOCKET" 1 "$TOTAL_DURATION" "$OUTDIR/pidstat.csv"
command -v perf &>/dev/null && \
    start perf sudo bash "$DIR/fc_perf.sh" "$SOCKET" 1000 "$TOTAL_DURATION" "$OUTDIR/perf.csv"
command -v perf &>/dev/null && \
    start ml_features sudo bash "$DIR/fc_ml_metrics.sh" "$SOCKET" 1000 "$TOTAL_DURATION" "$OUTDIR/ml_features.csv"
start pressure sudo python3 "$DIR/fc_pressure.py" --socket "$SOCKET" -i 1 -d "$TOTAL_DURATION" -o "$OUTDIR/pressure.csv"

if [[ "$ARCH" == "x86_64" || "$ARCH" == "amd64" ]]; then
    [[ -d /sys/class/powercap ]] && ls /sys/class/powercap/ 2>/dev/null | grep -q intel-rapl && \
        start rapl sudo python3 "$DIR/fc_rapl.py" --socket "$SOCKET" -i 1 -d "$TOTAL_DURATION" -o "$OUTDIR/rapl.csv"
fi
if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    ls /sys/class/hwmon/hwmon*/*_input &>/dev/null && \
        start arm_power sudo python3 "$DIR/fc_arm_power.py" --socket "$SOCKET" -i 1 -d "$TOTAL_DURATION" -o "$OUTDIR/arm_power.csv"
fi
ls /sys/class/power_supply/BAT* &>/dev/null && \
    start battery sudo python3 "$DIR/fc_battery.py" --socket "$SOCKET" -i 1 -d "$TOTAL_DURATION" -o "$OUTDIR/battery.csv"

echo
sleep 3  # baseline samples before first invocation

# ── 4. Invocations ───────────────────────────────────────
echo "[4/6] Running $COUNT invocations of $INVOKE ..."
INV_CSV="$OUTDIR/invocations.csv"
echo "invocation,start_iso,start_elapsed_s,end_iso,end_elapsed_s,duration_s,exit_code" > "$INV_CSV"

T0=$(date +%s.%N)
for i in $(seq 1 "$COUNT"); do
    START_ISO=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    START=$(date +%s.%N)

    set +e
    if [[ $CAPTURE -eq 1 ]]; then
        "$INVOKE" \
            > "$OUTDIR/invocations/${i}.stdout.log" \
            2> "$OUTDIR/invocations/${i}.stderr.log"
    else
        "$INVOKE" >/dev/null 2>&1
    fi
    RC=$?
    set -e

    END_ISO=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    END=$(date +%s.%N)
    START_EL=$(echo "$START - $T0" | bc -l)
    END_EL=$(echo "$END - $T0" | bc -l)
    DUR=$(echo "$END - $START" | bc -l)
    printf "%d,%s,%.3f,%s,%.3f,%.3f,%d\n" \
        "$i" "$START_ISO" "$START_EL" "$END_ISO" "$END_EL" "$DUR" "$RC" >> "$INV_CSV"

    echo "      [$i/$COUNT] $(printf '%.2fs' $DUR) rc=$RC"
    sleep "$DELAY"
done
echo "      → $INV_CSV"
echo
sleep 3  # tail samples after last invocation

# ── 5. Stop collectors ───────────────────────────────────
echo "[5/6] Stopping collectors..."
for p in "${COLLECTORS[@]}"; do kill "$p" 2>/dev/null || true; done
sleep 1
for p in "${COLLECTORS[@]}"; do kill -9 "$p" 2>/dev/null || true; done
sudo pkill -P $$ 2>/dev/null || true
echo

# ── 6. Kill Firecracker ──────────────────────────────────
echo "[6/6] Stopping Firecracker..."
[[ -n "$FC_PID" ]] && { sudo kill "$FC_PID" 2>/dev/null || true; sleep 1; sudo kill -9 "$FC_PID" 2>/dev/null || true; }
case "$TERM_KIND" in
    tmux)   tmux kill-session -t fc_exp 2>/dev/null || true ;;
    screen) screen -S fc_exp -X quit 2>/dev/null || true ;;
    bg)     [[ -f "$OUTDIR/firecracker.pid" ]] && sudo kill "$(cat "$OUTDIR/firecracker.pid")" 2>/dev/null || true ;;
esac

echo
echo "═══════════════════════════════════════════════════════════"
echo "  Done — output: $OUTDIR/"
echo "═══════════════════════════════════════════════════════════"
ls -la "$OUTDIR/"