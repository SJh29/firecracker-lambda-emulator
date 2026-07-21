#!/usr/bin/env bash
# temp_reflink_setup.sh — THROWAWAY benchmark. Safe to delete.
#
# Measures how long it takes to go from "create" to "first invocation" for N
# concurrent microVMs when each VM's rootfs is a `cp --reflink=auto` clone of
# the base image (copy-on-write on btrfs, full copy elsewhere — --reflink=auto
# falls back, and the timings show you which you got).
#
# Per instance it records the phases of a cold start:
#   clone_ms          reflink the base rootfs → instances clone
#   config_ms         render vm_config for this instance
#   launch_to_sock_ms firecracker exec → API socket appears
#   sock_to_first_ms  socket appears → first HTTP 200 from the RIE
#                     (guest boot finish + runtime init + the first, cold call)
#   total_ms          clone start → first successful invocation  ← headline
#
# All N are launched concurrently, so per-instance times inflate with N exactly
# the way real setup contention does — that is the point of the sweep.
#
# Usage: sudo ./temp_reflink_setup.sh [-n N] [-m MEM_MIB] [-p PAYLOAD] [-o CSV]
#   -n N          Instances to launch (default 1; ≤8 on a laptop, more on EC2)
#   -m MEM_MIB    Guest memory per VM (default: template value)
#   -p PAYLOAD    Invocation JSON (default: the chacha20 benchmark)
#   -o CSV        Output CSV (default: reflink_bench_<ts>.csv)
#
# NOTE: for N>1 the rootfs must be the rebuilt image that reads guest_ip= from
# the kernel cmdline; otherwise every guest comes up as 172.16.0.2 and only
# instance 0 answers (the rest time out).
set -e

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# Isolate this benchmark from any real run: its own socket dir and clone dir,
# so it never clobbers /tmp/firecracker or instances/ from run_firecracker.sh.
export API_SOCKET_FOLDER="/tmp/firecracker-bench"
export FC_RUN_DIR="$HERE/bench-instances"
source "$HERE/common.sh"
source "$HERE/config.sh"

NUM=1
MEM_OVERRIDE=""
PAYLOAD='{"method": "chacha20", "rounds": 100000, "password": "benchmarkpass", "seed": 42}'
OUT="reflink_bench_$(date -u +%Y%m%d_%H%M%S).csv"
BOOT_TIMEOUT=60      # seconds to wait for the API socket
READY_TIMEOUT=180    # seconds to wait for the first successful invocation

while getopts "n:m:p:o:h" opt; do
    case $opt in
        n) NUM=$OPTARG ;;
        m) MEM_OVERRIDE=$OPTARG ;;
        p) PAYLOAD=$OPTARG ;;
        o) OUT=$OPTARG ;;
        h) sed -n 's/^# \?//p' "$0" | head -n 30; exit 0 ;;
    esac
done

[[ "$NUM" =~ ^[0-9]+$ ]] && (( NUM >= 1 )) || { error "-n must be a positive integer (got '$NUM')"; exit 1; }
fc_check_instance "$(( NUM - 1 ))" || exit 1

BASE_ROOTFS="$HERE/$ROOTFS_IMAGE"
[[ -f "$BASE_ROOTFS" ]]        || { error "base rootfs not found: $BASE_ROOTFS (run install_build.sh)"; exit 1; }
[[ -f "$HERE/function.ext4" ]] || { error "function drive not found: $HERE/function.ext4 (run build_function.sh)"; exit 1; }
command -v bc &>/dev/null      || { error "bc is required"; exit 1; }

(( $(fc_instances 2>/dev/null | wc -l) == 0 )) || warn "benchmark uses its own socket dir; a real run under /tmp/firecracker is unaffected but shares tap<k> — don't run both at once."

NPROC=$(nproc)
(( NUM * 2 > NPROC )) && warn "$NUM instances want $(( NUM * 2 )) CPUs but the host has $NPROC — boot times will be contended (which is what you're measuring)."

# ── timing helpers ──────────────────────────────────────
now() { date +%s.%N; }
ms()  { printf '%.1f' "$(echo "($2 - $1) * 1000" | bc -l)"; }

# ── memory / vcpu, read from the template (never a stale generated config) ──
MEM_MIB=$(jq -r '."machine-config".mem_size_mib' "$HERE/vm_config.template.json")
[[ -n "$MEM_OVERRIDE" ]] && MEM_MIB="$MEM_OVERRIDE"
VCPU=$(jq -r '."machine-config".vcpu_count' "$HERE/vm_config.template.json")
(( MEM_MIB > 1769 )) && VCPU=$(( (MEM_MIB + 1768) / 1769 ))

# ── clean slate ─────────────────────────────────────────
sudo rm -rf "$API_SOCKET_FOLDER" "$FC_RUN_DIR"
sudo mkdir -p "$API_SOCKET_FOLDER" "$FC_RUN_DIR"
: > "$FC_RUN_DIR/pids"

# On btrfs, keep the clone dir out of datacow so the writable clones don't
# fragment mid-benchmark and skew later instances. Harmless (no-op) elsewhere.
command -v chattr &>/dev/null && sudo chattr +C "$FC_RUN_DIR" 2>/dev/null || true

sudo bash "$HERE/function_scripts/setup_tap.sh" -n "$NUM" >/dev/null

cleanup() {
    trap - EXIT INT TERM
    echo
    echo "cleaning up..."
    while read -r pid; do [[ -n "$pid" ]] && sudo kill -9 "$pid" 2>/dev/null || true; done < "$FC_RUN_DIR/pids" 2>/dev/null
    for (( k=0; k<NUM; k++ )); do sudo ip link del "$(fc_tap "$k")" 2>/dev/null || true; done
    sudo rm -rf "$API_SOCKET_FOLDER" "$FC_RUN_DIR"
}
trap cleanup EXIT INT TERM

echo "═══════════════════════════════════════════════════════════"
echo "  temp_reflink_setup — create→first-invocation benchmark"
echo "  instances=$NUM  mem=${MEM_MIB}MiB  vcpu=$VCPU  host_cpus=$NPROC"
echo "═══════════════════════════════════════════════════════════"

# ── one instance: clone → configure → launch → wait → invoke ────────────────
# Runs entirely in the background; writes a single CSV row to row-<k>.csv.
bench_instance() {
    local k="$1"
    local rootfs config sock url row
    rootfs="$(fc_rootfs "$k")"
    config="$(fc_config "$k")"
    sock="$(fc_socket "$k")"
    url="http://$(fc_guest_ip "$k"):${LAMBDA_PORT}/2015-03-31/functions/function/invocations"
    row="$FC_RUN_DIR/row-$k.csv"

    local t0 t_clone t_cfg t_launch t_sock t_first rc="ok"
    t0=$(now)

    # 1. reflink clone (CoW on btrfs, full copy on fallback)
    sudo cp --reflink=auto --sparse=auto "$BASE_ROOTFS" "$rootfs"
    t_clone=$(now)

    # 2. render this instance's config
    sed -e "s|@ROOT@|$HERE|g" \
        -e "s|@ROOTFS@|$rootfs|g" \
        -e "s|@TAP@|$(fc_tap "$k")|g" \
        -e "s|@MAC@|$(fc_mac "$k")|g" \
        -e "s|@GUEST_IP@|$(fc_guest_ip "$k")|g" \
        -e "s|@HOST_IP@|$(fc_host_ip "$k")|g" \
        "$HERE/vm_config.template.json" \
      | jq --argjson m "$MEM_MIB" --argjson v "$VCPU" '
            ."machine-config".mem_size_mib = $m
          | ."machine-config".vcpu_count   = $v
          | ."boot-source".boot_args |= sub("func_mem_size=[0-9]+"; "func_mem_size=\($m)")
        ' \
      | sudo tee "$config" >/dev/null
    t_cfg=$(now)

    # 3. launch firecracker
    "$HERE/firecracker" --api-sock "$sock" --config-file "$config" >/dev/null 2>&1 &
    echo "$!" >> "$FC_RUN_DIR/pids"
    t_launch=$(now)

    # 4. wait for the API socket
    local i deadline
    deadline=$(echo "$t_launch + $BOOT_TIMEOUT" | bc -l)
    while [[ ! -S "$sock" ]]; do
        (( $(echo "$(now) > $deadline" | bc -l) )) && { rc="no_socket"; break; }
        sleep 0.02
    done
    t_sock=$(now)

    # 5. poll the RIE until the first invocation returns 200 (cold start incl.)
    if [[ "$rc" == "ok" ]]; then
        deadline=$(echo "$t_sock + $READY_TIMEOUT" | bc -l)
        while true; do
            if curl -sf --max-time 10 -X POST "$url" \
                    -H "Content-Type: application/json" -d "$PAYLOAD" >/dev/null 2>&1; then
                rc="ok"; break
            fi
            (( $(echo "$(now) > $deadline" | bc -l) )) && { rc="no_invoke"; break; }
            sleep 0.05
        done
    fi
    t_first=$(now)

    printf '%d,%s,%s,%s,%s,%s,%s\n' \
        "$k" \
        "$(ms "$t0" "$t_clone")" \
        "$(ms "$t_clone" "$t_cfg")" \
        "$(ms "$t_launch" "$t_sock")" \
        "$(ms "$t_sock" "$t_first")" \
        "$(ms "$t0" "$t_first")" \
        "$rc" > "$row"
}

# ── launch all instances concurrently, then wait ────────────────────────────
echo "launching $NUM instance(s) concurrently..."
T_START=$(now)
for (( k=0; k<NUM; k++ )); do bench_instance "$k" & done
wait
T_END=$(now)

# ── assemble results ────────────────────────────────────
{
    echo "instance,clone_ms,config_ms,launch_to_sock_ms,sock_to_first_ms,total_ms,status"
    for (( k=0; k<NUM; k++ )); do cat "$FC_RUN_DIR/row-$k.csv" 2>/dev/null; done
} > "$OUT"

echo
printf '%-9s %-10s %-10s %-16s %-16s %-11s %s\n' \
    instance clone_ms config_ms launch_to_sock sock_to_first total_ms status
printf '%.0s─' {1..86}; echo
sum_total=0; ok=0; worst=0
for (( k=0; k<NUM; k++ )); do
    IFS=, read -r i clone cfg l2s s2f tot st < "$FC_RUN_DIR/row-$k.csv"
    printf '%-9s %-10s %-10s %-16s %-16s %-11s %s\n' "$i" "$clone" "$cfg" "$l2s" "$s2f" "$tot" "$st"
    if [[ "$st" == "ok" ]]; then
        sum_total=$(echo "$sum_total + $tot" | bc -l); ok=$((ok+1))
        (( $(echo "$tot > $worst" | bc -l) )) && worst=$tot
    fi
done
printf '%.0s─' {1..86}; echo
echo
echo "instances ok           : $ok / $NUM"
(( ok > 0 )) && echo "mean total (create→1st): $(printf '%.1f' "$(echo "$sum_total / $ok" | bc -l)") ms"
(( ok > 0 )) && echo "slowest instance       : ${worst} ms"
echo "wall clock, all ready  : $(ms "$T_START" "$T_END") ms"
echo "CSV                    : $OUT"
echo
echo "(temporary benchmark — delete temp_reflink_setup.sh and $(basename "$FC_RUN_DIR")/ when done)"
