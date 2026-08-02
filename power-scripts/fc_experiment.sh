#!/bin/bash
# fc_experiment.sh — run an end-to-end power-measurement experiment.
#
# 1. Launch run_firecracker.sh (N concurrent microVMs) in a separate terminal
# 2. Wait for every socket
# 3. Start collectors at the configured sampling rate (default 100 Hz)
# 4. Invoke ../function_scripts/invoke.sh COUNT times; with N>1 every round
#    fires all N instances concurrently, so the VMs are measured under
#    simultaneous load rather than one after another
# 5. Stop collectors
# 6. Kill Firecracker
#
# Per-PID collectors (proc, pidstat, perf, ml_features, pressure) run once per
# instance; host-wide ones (rapl, turbostat, arm_power, battery) run once for
# the whole host, since RAPL and turbostat measure the package, not a process.
# With N>1, per-instance output lands in <outdir>/vm<k>/; with N=1 it stays flat
# so the existing analyzers keep working unchanged.
#
# Each invocation's stdout/stderr is captured to invocations/<n>.<k>.log
# and start/end timestamps go to invocations.csv so you can correlate
# with power traces.
#
# Usage:
#   sudo ./fc_experiment.sh [OPTIONS]
#
# Options:
#   -n COUNT            Number of invocation rounds  (default: 10)
#   -N NUM_VMS          Concurrent microVMs  (default: 1)
#   -s SOCKET_DIR       Firecracker socket dir  (default: /tmp/firecracker)
#   -l LAUNCH_SCRIPT    run_firecracker.sh path  (default: ../run_firecracker.sh)
#   -I INVOKE_SCRIPT    invoke.sh path  (default: ../function_scripts/invoke.sh)
#   -d DELAY            Seconds between rounds  (default: 2)
#   -r RATE_HZ          Collector sampling rate in Hz (default: 100). At 100 Hz
#                       a 0.3s invocation gets ~30 samples. perf's floor is
#                       10ms, so 100 Hz is the practical ceiling; pidstat stays
#                       at 1 Hz (integer-second tool).
#   -E EST_SECS         Estimated seconds per invocation; sizes how long the
#                       collectors run so they outlast the experiment (default: 10)
#   -m MEM_MIB          Guest memory tier (MiB), passed through to run_firecracker.sh -m
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
NUM_VMS=1
SOCKET_DIR=/tmp/firecracker
LAUNCH="$ROOT/run_firecracker.sh"
INVOKE="$ROOT/function_scripts/invoke.sh"
DELAY=2
OUTDIR=""
TERM_KIND=auto
CAPTURE=1
EST_INVOKE_SECS=10   # estimated seconds per invocation; sizes collector duration
MEM_MIB=""           # if set, forwarded to run_firecracker.sh as `-m MEM_MIB`
RATE_HZ=100          # collector sampling rate; see -r. Sub-second invocations
                     # need many samples per window — 1 Hz is far too coarse.

while getopts "n:N:s:l:I:d:r:o:t:E:m:qh" opt; do
    case $opt in
        n) COUNT=$OPTARG ;;
        N) NUM_VMS=$OPTARG ;;
        s) SOCKET_DIR=$OPTARG ;;
        l) LAUNCH=$OPTARG ;;
        I) INVOKE=$OPTARG ;;
        d) DELAY=$OPTARG ;;
        r) RATE_HZ=$OPTARG ;;
        o) OUTDIR=$OPTARG ;;
        t) TERM_KIND=$OPTARG ;;
        E) EST_INVOKE_SECS=$OPTARG ;;
        m) MEM_MIB=$OPTARG ;;
        q) CAPTURE=0 ;;
        h) sed -n 's/^# \?//p' "$0" | head -n 40; exit 0 ;;
    esac
done

# Instance addressing (fc_socket, fc_guest_ip, fc_instances, ...) comes from
# common.sh, which honours API_SOCKET_FOLDER — set it before sourcing.
export API_SOCKET_FOLDER="$SOCKET_DIR"
source "$ROOT/common.sh"

[[ "$NUM_VMS" =~ ^[0-9]+$ ]] && (( NUM_VMS >= 1 )) \
    || { echo "ERROR: -N must be a positive integer (got '$NUM_VMS')" >&2; exit 1; }
fc_check_instance "$(( NUM_VMS - 1 ))" || exit 1

# Derive per-collector interval arguments from the sampling rate.
#   SEC_INT  — float seconds for the Python collectors (proc/pressure/rapl)
#   MS_INT   — integer milliseconds for perf (-I); perf's floor is 10ms
#   COARSE_INT — integer seconds for pidstat/battery, which take whole-second
#                intervals (their scripts do integer division on it)
SEC_INT=$(echo "scale=6; 1/$RATE_HZ" | bc -l)
MS_INT=$(printf '%.0f' "$(echo "1000/$RATE_HZ" | bc -l)")
(( MS_INT < 10 )) && MS_INT=10            # perf rejects intervals below 10ms
COARSE_INT=$(printf '%.0f' "$SEC_INT")
(( COARSE_INT < 1 )) && COARSE_INT=1

# Args forwarded to the launch script. This stays a single string because all
# terminal backends below interpolate $LAUNCH_CMD into bash -c.
LAUNCH_ARGS="-n $NUM_VMS"
[[ -n "$MEM_MIB" ]] && LAUNCH_ARGS="$LAUNCH_ARGS -m $MEM_MIB"
LAUNCH_CMD="$LAUNCH $LAUNCH_ARGS"

OUTDIR=${OUTDIR:-experiment_$(date -u +%Y%m%d_%H%M%S)}
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"   # absolute path so collectors (esp. perf --output) resolve it correctly
[[ $CAPTURE -eq 1 ]] && mkdir -p "$OUTDIR/invocations"

[[ -f "$LAUNCH" ]] || { echo "ERROR: launch script not found: $LAUNCH" >&2; exit 1; }
[[ -f "$INVOKE" ]] || { echo "ERROR: invoke script not found: $INVOKE" >&2; exit 1; }

# Per-instance output prefix: flat for a single VM (so existing analyzers see
# the filenames they expect), one subdir per VM when running concurrently.
vm_out() {
    local k="$1"
    if (( NUM_VMS == 1 )); then echo "$OUTDIR"
    else mkdir -p "$OUTDIR/vm$k"; echo "$OUTDIR/vm$k"; fi
}

echo "═══════════════════════════════════════════════════════════"
echo "  fc_experiment"
echo "═══════════════════════════════════════════════════════════"
echo "  launch    : $LAUNCH_CMD"
echo "  invoke    : $INVOKE"
echo "  sockets   : $SOCKET_DIR/{0..$(( NUM_VMS - 1 ))}.socket"
echo "  vms       : $NUM_VMS"
echo "  rounds    : $COUNT × (${DELAY}s gap)"
[[ -n "$MEM_MIB" ]] && echo "  mem       : ${MEM_MIB} MiB"
echo "  capture   : $([[ $CAPTURE -eq 1 ]] && echo yes || echo no)"
echo "  output    : $OUTDIR"
echo "═══════════════════════════════════════════════════════════"
echo

# ── 1. Launch Firecracker (or reuse running instances) ───
echo "[1/6] Checking for existing Firecracker instances in $SOCKET_DIR ..."
FC_STARTED=0
FC_LOG="$OUTDIR/firecracker.log"
RUNNING=($(fc_instances))

# Diagnostics on a failed launch have to come from two places. FC_LOG captures
# the launcher's own messages, but Firecracker's log lines and the guest console
# no longer flow through this pipe — run_firecracker.sh redirects each instance
# to logs/<timestamp>/console-<k>.log, because its stdout is non-blocking and a
# full pipe would silently drop those bytes with EAGAIN. So tail both.
fc_log_tail() {
    echo "  Launcher log tail ($FC_LOG):" >&2
    tail -20 "$FC_LOG" 2>/dev/null | sed 's/^/    /' >&2
    local c
    for c in "$FC_LOG_ROOT"/latest/console-*.log; do
        [[ -f "$c" ]] || continue     # unmatched glob stays literal; skip it
        echo "  Console tail ($c):" >&2
        tail -20 "$c" 2>/dev/null | sed 's/^/    /' >&2
    done
}

if (( ${#RUNNING[@]} >= NUM_VMS )); then
    echo "      reusing ${#RUNNING[@]} running instance(s); skipping launch"
else
    if (( ${#RUNNING[@]} > 0 )); then
        echo "ERROR: found ${#RUNNING[@]} running instance(s) but need $NUM_VMS." >&2
        echo "  Stop them first: sudo $ROOT/kill_firecracker.sh" >&2
        exit 1
    fi
    echo "      no running Firecracker found — launching $NUM_VMS instance(s)..."
    if [[ "$TERM_KIND" == "auto" ]]; then
        if   command -v gnome-terminal &>/dev/null; then TERM_KIND=gnome-terminal
        elif command -v konsole        &>/dev/null; then TERM_KIND=konsole
        elif command -v xterm          &>/dev/null; then TERM_KIND=xterm
        elif command -v tmux           &>/dev/null; then TERM_KIND=tmux
        elif command -v screen         &>/dev/null; then TERM_KIND=screen
        else TERM_KIND=bg; fi
    fi
    echo "      terminal: $TERM_KIND"

    case "$TERM_KIND" in
        gnome-terminal) gnome-terminal -- bash -c "$LAUNCH_CMD 2>&1 | tee $FC_LOG; exec bash" ;;
        konsole)        konsole -e bash -c "$LAUNCH_CMD 2>&1 | tee $FC_LOG" & ;;
        xterm)          xterm -hold -e "bash -c '$LAUNCH_CMD 2>&1 | tee $FC_LOG'" & ;;
        tmux)           tmux new-session -d -s fc_exp "$LAUNCH_CMD 2>&1 | tee $FC_LOG" ;;
        screen)         screen -dmS fc_exp bash -c "$LAUNCH_CMD 2>&1 | tee $FC_LOG" ;;
        bg)             nohup bash "$LAUNCH" $LAUNCH_ARGS >"$FC_LOG" 2>&1 &
                        echo "$!" > "$OUTDIR/firecracker.pid" ;;
        *)              echo "ERROR: unknown terminal $TERM_KIND"; exit 1 ;;
    esac
    FC_STARTED=1
fi

# ── 2. Wait for every socket ─────────────────────────────
echo "[2/6] Waiting for $NUM_VMS socket(s) ..."
for (( k=0; k<NUM_VMS; k++ )); do
    sock="$(fc_socket "$k")"
    for i in $(seq 1 60); do
        [[ -S "$sock" ]] && break
        sleep 0.5
    done
    if [[ ! -S "$sock" ]]; then
        echo "ERROR: socket never appeared at $sock after 30s." >&2
        fc_log_tail
        exit 1
    fi
done

# Brief settle, then confirm each Firecracker is actually alive.
sleep 1
FC_PIDS=()
for (( k=0; k<NUM_VMS; k++ )); do
    pid=$(sudo bash "$DIR/fc_pid.sh" "$(fc_socket "$k")" 2>/dev/null || true)
    if [[ -z "$pid" ]]; then
        echo "ERROR: socket $(fc_socket "$k") exists but no firecracker process owns it." >&2
        echo "  Firecracker may have crashed after creating the socket. Log tail:" >&2
        fc_log_tail
        exit 1
    fi
    FC_PIDS+=("$pid")
    echo "      instance $k: pid $pid, guest $(fc_guest_ip "$k")"
done
echo

# ── 3. Start collectors ──────────────────────────────────
echo "[3/6] Starting collectors at ${RATE_HZ} Hz (proc/pressure/rapl/turbostat=${SEC_INT}s, perf=${MS_INT}ms, pidstat=${COARSE_INT}s)..."
# Collectors must outlast the whole experiment. Each round costs roughly
# EST_INVOKE_SECS (the invocation) + DELAY (the gap). Add a margin for the
# pre/post baseline sleeps plus startup overhead.
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

# Per-instance collectors: one set per VM, scoped to that VM's PID/cgroup.
for (( k=0; k<NUM_VMS; k++ )); do
    sock="$(fc_socket "$k")"
    out="$(vm_out "$k")"
    tag=$( (( NUM_VMS == 1 )) && echo "" || echo ".vm$k" )

    start "proc$tag"     sudo python3 "$DIR/fc_proc.py"     --socket "$sock" -i "$SEC_INT" -d "$TOTAL_DURATION" -o "$out/proc.csv"
    start "pressure$tag" sudo python3 "$DIR/fc_pressure.py" --socket "$sock" -i "$SEC_INT" -d "$TOTAL_DURATION" -o "$out/pressure.csv"
    # pidstat takes whole-second intervals only, so it stays at COARSE_INT.
    command -v pidstat &>/dev/null && \
        start "pidstat$tag" sudo bash "$DIR/fc_pidstat.sh" "$sock" "$COARSE_INT" "$TOTAL_DURATION" "$out/pidstat.csv"
    command -v perf &>/dev/null && \
        start "perf$tag" sudo bash "$DIR/fc_perf.sh" "$sock" "$MS_INT" "$TOTAL_DURATION" "$out/perf.csv"
    command -v perf &>/dev/null && \
        start "ml_features$tag" sudo bash "$DIR/fc_ml_metrics.sh" "$sock" "$MS_INT" "$TOTAL_DURATION" "$out/ml_features.csv"
done

# Host-wide collectors: RAPL and turbostat measure the whole package, and the
# battery gauge the whole machine — one copy each, no matter how many VMs.
# With N>1 their totals cover all instances together; attribute per-VM energy
# using the per-instance proc/perf traces.
if [[ "$ARCH" == "x86_64" || "$ARCH" == "amd64" ]]; then
    [[ -d /sys/class/powercap ]] && ls /sys/class/powercap/ 2>/dev/null | grep -q intel-rapl && \
        start rapl sudo python3 "$DIR/fc_rapl.py" --socket "$(fc_socket 0)" -i "$SEC_INT" -d "$TOTAL_DURATION" -o "$OUTDIR/rapl.csv"
    # turbostat reads power from MSRs, so it works on hosts where RAPL sysfs is
    # absent (e.g. EC2 .metal). The analyzers fall back to turbostat.csv when
    # rapl.csv is missing. It accepts fractional intervals, so it follows the
    # configured rate (SEC_INT) like the other power collectors.
    command -v turbostat &>/dev/null && \
        start turbostat sudo bash "$DIR/fc_turbostat.sh" "$(fc_socket 0)" "$SEC_INT" "$TOTAL_DURATION" "$OUTDIR/turbostat.csv"
fi
if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    ls /sys/class/hwmon/hwmon*/*_input &>/dev/null && \
        start arm_power sudo python3 "$DIR/fc_arm_power.py" --socket "$(fc_socket 0)" -i "$SEC_INT" -d "$TOTAL_DURATION" -o "$OUTDIR/arm_power.csv"
fi
# Battery gauges refresh on the order of seconds, so sub-second sampling adds
# nothing — keep it at COARSE_INT.
ls /sys/class/power_supply/BAT* &>/dev/null && \
    start battery sudo python3 "$DIR/fc_battery.py" --socket "$(fc_socket 0)" -i "$COARSE_INT" -d "$TOTAL_DURATION" -o "$OUTDIR/battery.csv"

echo
sleep 8  # baseline samples before first invocation

# ── 4. Invocations ───────────────────────────────────────
echo "[4/6] Running $COUNT round(s) × $NUM_VMS instance(s) of $INVOKE ..."
INV_CSV="$OUTDIR/invocations.csv"
echo "round,instance,start_iso,start_elapsed_s,end_iso,end_elapsed_s,duration_s,exit_code" > "$INV_CSV"

# One invocation of instance $2 in round $1. Appends its own row to INV_CSV;
# rows are flushed one at a time so concurrent writers can't interleave a line.
invoke_vm() {
    local round="$1" k="$2" start_iso start end_iso end rc

    start_iso=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    start=$(date +%s.%N)

    set +e
    if [[ $CAPTURE -eq 1 ]]; then
        "$INVOKE" -i "$k" \
            > "$OUTDIR/invocations/${round}.${k}.stdout.log" \
            2> "$OUTDIR/invocations/${round}.${k}.stderr.log"
    else
        "$INVOKE" -i "$k" >/dev/null 2>&1
    fi
    rc=$?
    set -e

    end_iso=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    end=$(date +%s.%N)
    printf "%d,%d,%s,%.3f,%s,%.3f,%.3f,%d\n" \
        "$round" "$k" \
        "$start_iso" "$(echo "$start - $T0" | bc -l)" \
        "$end_iso"   "$(echo "$end - $T0" | bc -l)" \
        "$(echo "$end - $start" | bc -l)" "$rc" >> "$INV_CSV"

    echo "      [round $round | vm $k] $(printf '%.2fs' "$(echo "$end - $start" | bc -l)") rc=$rc"
    return $rc
}

T0=$(date +%s.%N)
for i in $(seq 1 "$COUNT"); do
    # Fire all instances at once so they contend for the host the way a real
    # concurrent workload would; a serial loop would measure something else.
    ROUND_PIDS=()
    for (( k=0; k<NUM_VMS; k++ )); do
        invoke_vm "$i" "$k" &
        ROUND_PIDS+=($!)
    done
    for p in "${ROUND_PIDS[@]}"; do wait "$p" || true; done
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
if (( FC_STARTED )); then
    # Graceful shutdown of every VM, plus teardown of taps and rootfs copies.
    # sudo drops the environment, so pass the socket dir through explicitly —
    # otherwise a custom -s would be lost and it would clean the default dir.
    sudo API_SOCKET_FOLDER="$SOCKET_DIR" bash "$ROOT/kill_firecracker.sh" || true
    for pid in "${FC_PIDS[@]}"; do
        sudo kill -9 "$pid" 2>/dev/null || true
    done
    case "$TERM_KIND" in
        tmux)   tmux kill-session -t fc_exp 2>/dev/null || true ;;
        screen) screen -S fc_exp -X quit 2>/dev/null || true ;;
        bg)     [[ -f "$OUTDIR/firecracker.pid" ]] && sudo kill "$(cat "$OUTDIR/firecracker.pid")" 2>/dev/null || true ;;
    esac
else
    echo "      instances were already running before this run — leaving them up"
fi

echo
echo "═══════════════════════════════════════════════════════════"
echo "  Done — output: $OUTDIR/"
echo "═══════════════════════════════════════════════════════════"
ls -la "$OUTDIR/"
