#!/usr/bin/env bash
# run_all.sh
# Runs experiments A, B, C (Erlang + eFLINT), 3 runs each, stores raw ms to results/.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ERL_DIR="$SCRIPT_DIR/erlang"
RESULTS_DIR="$SCRIPT_DIR/results"
# RESULTS_DIR="$SCRIPT_DIR/results/erlang_scaling/b"
mkdir -p "$RESULTS_DIR"

# SIZES=(1000 2000 3000 4000 5000 6000 7000 8000 9000 10000)
# experiment B 
# SIZES=(500 1000 1500 2000 2500 3000 3500 4000 4500 5000)
SIZES=(0 20 30 40 50 60 70 80 90 100)
RUNS=3

# ---------------------------------------------------------------------------
# Compile
# ---------------------------------------------------------------------------
echo "=== Compiling Erlang ==="
(cd "$ERL_DIR" && erlc eflint.erl scenario_hwh_pairs.erl scenario_hwh_duties.erl scenario_voting.erl)
echo "Compilation done."
echo ""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run one erl invocation and echo elapsed ms to stdout.
timed_erl() {
    local module=$1 n=$2
    local t0 t1
    t0=$(date +%s%3N)
    (cd $ERL_DIR; erl -noshell -eval "${module}:run(${n})" -s init stop)
    t1=$(date +%s%3N)
    echo $(( t1 - t0 ))
}

# Run one eflint-repl invocation and echo elapsed ms to stdout.
timed_eflint() {
    local file=$1
    local t0 t1
    t0=$(date +%s%3N)
    eflint-repl "$file" --test-mode >/dev/null 2>&1
    t1=$(date +%s%3N)
    echo $(( t1 - t0 ))
}

# Run one experiment for both Erlang and eFLINT, writing two result files:
#   results/exp_<ID>_erlang.txt
#   results/exp_<ID>_eflint.txt
# File format (tab-separated, one row per N):
#   N    run1_ms    run2_ms    run3_ms
run_experiment() {
    local exp_id=$1 module=$2
    local exp_lower
    exp_lower=$(echo "$exp_id" | tr '[:upper:]' '[:lower:]')

    local erl_out="$RESULTS_DIR/exp_${exp_id}_erlang.txt"
    local efl_out="$RESULTS_DIR/exp_${exp_id}_eflint.txt"

    printf "# Experiment %s Erlang  module=%s  runs=%d\n" "$exp_id" "$module" "$RUNS" > "$erl_out"
    printf "# N\trun1_ms\trun2_ms\trun3_ms\n" >> "$erl_out"

    printf "# Experiment %s eFLINT  runs=%d\n" "$exp_id" "$RUNS" > "$efl_out"
    printf "# N\trun1_ms\trun2_ms\trun3_ms\n" >> "$efl_out"

    echo "=== Experiment $exp_id: $module (Erlang + eFLINT) ==="

    for n in "${SIZES[@]}"; do
        erl_row="$n"
        efl_row="$n"
        local eflint_file="$SCRIPT_DIR/eflint/exp_${exp_lower}_${n}.eflint"

        printf "  N=%-4d  [erlang] " "$n"
        for (( r=1; r<=RUNS; r++ )); do
            ms=$(timed_erl "$module" "$n")
            erl_row="$erl_row\t$ms"
            printf "run%d: %5dms  " "$r" "$ms"
        done
        printf "\n"

        printf "  N=%-4d  [eflint] " "$n"
        for (( r=1; r<=RUNS; r++ )); do
            ms=$(timed_eflint "$eflint_file")
            efl_row="$efl_row\t$ms"
            printf "run%d: %5dms  " "$r" "$ms"
        done
        printf "\n"

        printf "%b\n" "$erl_row" >> "$erl_out"
        printf "%b\n" "$efl_row" >> "$efl_out"
    done

    echo "  -> saved to $erl_out"
    echo "  -> saved to $efl_out"
    echo ""
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
run_experiment "A" "scenario_hwh_pairs"
run_experiment "B" "scenario_hwh_duties"
run_experiment "C" "scenario_voting"

echo "=== Done. Raw results in $RESULTS_DIR/ ==="
