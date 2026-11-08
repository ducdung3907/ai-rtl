#!/usr/bin/env bash
# Run every testbench in tb/ (several N / MAC_LAT / PC speed settings) and
# exit with an error if any of them fails. Used locally and by GitHub Actions.
#
# Runs in parallel (JOBS=n to change, default = CPU cores).
# Usage (from the repository root):
#   ./sim/run_all.sh            # everything
#   ./sim/run_all.sh skew pe    # only runs whose name contains one of these words
#
# A run passes only if its log contains a line starting with "PASS" and no line
# starting with "FAIL". Logs go to sim/logs/ (ignored by git).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LOGS="sim/logs"
mkdir -p "$LOGS"

# Every design file is compiled into every run; -s picks the testbench as the
# top, so unused modules are simply ignored.
DESIGN=$(ls rtl/*.sv board/*.sv 2>/dev/null)

# name | testbench file | top module | -P overrides (space separated, may be empty)
RUNS=(
  "mac              | tb/tb_mac.sv       | tb_mac           | "
  "pe_lat1          | tb/tb_pe.sv        | tb_pe8           | MAC_LAT=1"
  "pe_lat2          | tb/tb_pe.sv        | tb_pe8           | MAC_LAT=2"
  "skew_n1          | tb/tb_skew.sv      | tb_skew          | N=1"
  "skew_n2          | tb/tb_skew.sv      | tb_skew          | N=2"
  "skew_n4          | tb/tb_skew.sv      | tb_skew          | N=4"
  "skew_n8          | tb/tb_skew.sv      | tb_skew          | N=8"
  "sa2x2            | tb/tb_sa2x2.sv     | tb_sa2x2         | "
  "asNxN_n2         | tb/tb_asNxN.sv     | tb_systolic_array| N=2"
  "asNxN_n4         | tb/tb_asNxN.sv     | tb_systolic_array| N=4"
  "asNxN_n8         | tb/tb_asNxN.sv     | tb_systolic_array| N=8"
  "sa_top_n2_lat1   | tb/tb_sa_top.sv    | tb_complete_sa   | N=2 MAC_LAT=1"
  "sa_top_n2_lat2   | tb/tb_sa_top.sv    | tb_complete_sa   | N=2 MAC_LAT=2"
  "sa_top_n4_lat1   | tb/tb_sa_top.sv    | tb_complete_sa   | N=4 MAC_LAT=1"
  "sa_top_n4_lat2   | tb/tb_sa_top.sv    | tb_complete_sa   | N=4 MAC_LAT=2"
  "sa_top_n8_lat2   | tb/tb_sa_top.sv    | tb_complete_sa   | N=8 MAC_LAT=2"
  "uart_tx          | tb/tb_uart_tx.sv   | tb_uart_tx       | "
  "uart_rx          | tb/tb_uart_rx.sv   | tb_uart_rx       | "
  "board_top        | tb/tb_board_top.sv | tb_board_top     | "
  "board_top_fast   | tb/tb_board_top.sv | tb_board_top     | PC_SPEED=1.005 GAPS=0"
  "board_top_slow   | tb/tb_board_top.sv | tb_board_top     | PC_SPEED=0.995 GAPS=0"
  "sa_ctrl_n4_lat2  | tb/tb_sa_ctrl.sv   | tb_sa_ctrl       | N=4 MAC_LAT=2"
  "sa_ctrl_n4_lat1  | tb/tb_sa_ctrl.sv   | tb_sa_ctrl       | N=4 MAC_LAT=1"
  "sa_ctrl_n2       | tb/tb_sa_ctrl.sv   | tb_sa_ctrl       | N=2"
  "sa_ctrl_n8       | tb/tb_sa_ctrl.sv   | tb_sa_ctrl       | N=8"
  "sa_board_top     | tb/tb_sa_board_top.sv  | tb_sa_board_top  | "
  "sa_board_top_w1  | tb/tb_sa_board_top.sv  | tb_sa_board_top  | WINDOW=1"
  "sa_board_top_fast| tb/tb_sa_board_top.sv  | tb_sa_board_top  | PC_SPEED=1.005"
  "res_buf_n1       | tb/tb_res_buf.sv       | tb_res_buf       | N=1"
  "res_buf_n2       | tb/tb_res_buf.sv       | tb_res_buf       | N=2"
  "res_buf_n4       | tb/tb_res_buf.sv       | tb_res_buf       | N=4"
  "res_buf_n8       | tb/tb_res_buf.sv       | tb_res_buf       | N=8"
  "sync_fifo        | tb/tb_sync_fifo.sv     | tb_sync_fifo     | "
  "requant          | tb/tb_requant.sv       | tb_requant       | "
  "argmax_w10       | tb/tb_argmax.sv        | tb_argmax        | WIDTH=10"
  "argmax_w4        | tb/tb_argmax.sv        | tb_argmax        | WIDTH=4"
  "dp_ram_784       | tb/tb_simple_dp_ram.sv | tb_simple_dp_ram | DEPTH=784"
  "dp_ram_64        | tb/tb_simple_dp_ram.sv | tb_simple_dp_ram | DEPTH=64"
  "weight_rom       | tb/tb_weight_rom.sv    | tb_weight_rom    | "
  "infer_core       | tb/tb_infer_core.sv    | tb_infer_core    | "
  "frame_rx_n784    | tb/tb_frame_rx.sv        | tb_frame_rx        | N_STEPS=784"
  "frame_rx_n16     | tb/tb_frame_rx.sv        | tb_frame_rx        | N_STEPS=16"
  "reply_tx         | tb/tb_reply_tx.sv        | tb_reply_tx        | "
  "infer_board_top  | tb/tb_infer_board_top.sv | tb_infer_board_top | "
)

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; echo "${s%"${s##*[![:space:]]}"}"; }

# Runs up to JOBS testbenches at once (default: number of CPU cores).
#   JOBS=1 ./sim/run_all.sh     # one at a time, like before
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

# Compile and run one entry. Writes its one-line verdict to $LOGS/<name>.result
# (PASS / FAIL / SKIP + text); the main loop prints them in list order afterwards.
run_one() {
    local entry="$1" name file top params
    IFS='|' read -r name file top params <<< "$entry"
    name=$(trim "$name"); file=$(trim "$file"); top=$(trim "$top"); params=$(trim "$params")
    local res="$LOGS/$name.result"

    # Skip testbenches that don't exist on this branch yet
    if [ ! -f "$file" ]; then
        echo "SKIP skip (no $file)" > "$res"; return
    fi

    # Skip a parameter override the testbench doesn't have (e.g. an older version)
    local pflags="" missing="" p pname
    for p in $params; do
        pname="${p%%=*}"
        if grep -qE "parameter[^;]*\b${pname}\b" "$file"; then pflags="$pflags -P${top}.${p}"
        else missing="$pname"; fi
    done
    if [ -n "$missing" ]; then
        echo "SKIP skip ($file has no $missing)" > "$res"; return
    fi

    local log="$LOGS/$name.log" vvp_file="$LOGS/$name.vvp"
    if ! iverilog -g2012 -I ml/mem -s "$top" $pflags -o "$vvp_file" $DESIGN "$file" > "$log" 2>&1; then
        echo "FAIL FAIL (compile, see $log)" > "$res"; return
    fi
    timeout 900 vvp -n "$vvp_file" >> "$log" 2>&1
    if grep -q "^PASS" "$log" && ! grep -q "^FAIL" "$log"; then
        echo "PASS PASS  $(grep -m1 '^PASS' "$log" | cut -c1-60)" > "$res"
    else
        echo "FAIL FAIL (see $log)" > "$res"
    fi
}

# Pick the runs (optional name filter from the command line), start them
selected=()
for entry in "${RUNS[@]}"; do
    IFS='|' read -r name _ <<< "$entry"; name=$(trim "$name")
    if [ $# -gt 0 ]; then
        keep=0; for w in "$@"; do [[ "$name" == *"$w"* ]] && keep=1; done
        [ $keep -eq 0 ] && continue
    fi
    rm -f "$LOGS/$name.result"
    selected+=("$name|$entry")
    run_one "$entry" &
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
done
wait

pass=0; fail=0; skip=0; failed=()
printf "%-18s %s\n" "run" "result"
printf "%-18s %s\n" "---" "------"
for item in "${selected[@]}"; do
    name="${item%%|*}"
    read -r kind text < "$LOGS/$name.result"
    printf "%-18s %s\n" "$name" "$text"
    case "$kind" in
        PASS) pass=$((pass+1)) ;;
        SKIP) skip=$((skip+1)) ;;
        *)    fail=$((fail+1)); failed+=("$name") ;;
    esac
done

echo
echo "passed: $pass   failed: $fail   skipped: $skip"
if [ $fail -gt 0 ]; then
    echo "failed runs: ${failed[*]}"
    exit 1
fi
