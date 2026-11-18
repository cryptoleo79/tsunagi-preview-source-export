#!/bin/bash
# Deterministic integration runner for TSUNAGI evaluator pipeline.
# Dev/test helper only — not part of TSUNAGI runtime behavior.
#
# Exercises the external evaluator with fixed test contexts across
# N iterations, verifying every output matches an explicit expected golden.
#
# Evaluator selection (in priority order):
#   1. EVALUATOR env var (if set)
#   2. zig-out/bin/plutus-evaluator (compiled binary)
#   3. tools/plutus-evaluator.sh (shell fallback)
#
# Usage: bash tools/eval-runner.sh [iterations]
# Default: 100 iterations

set -e

ITERATIONS=${1:-100}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
BINARY="${REPO_ROOT}/zig-out/bin/plutus-evaluator"
SHELL_EVAL="${SCRIPT_DIR}/plutus-evaluator.sh"

# Evaluator selection: env override > compiled binary > shell fallback
if [ -n "$EVALUATOR" ]; then
    : # use EVALUATOR as-is from env
elif [ -x "$BINARY" ]; then
    EVALUATOR="$BINARY"
elif [ -x "$SHELL_EVAL" ]; then
    EVALUATOR="$SHELL_EVAL"
else
    echo "FAIL: no evaluator found (set EVALUATOR, build binary, or check shell script)"
    exit 1
fi

if [ ! -x "$EVALUATOR" ]; then
    echo "FAIL: evaluator not executable at $EVALUATOR"
    exit 1
fi

PASS=0
FAIL=0

# Run a single context test: name, input JSON, expected golden output
run_test() {
    local name="$1"
    local input="$2"
    local expected="$3"

    # Verify first run matches explicit golden
    local first
    first=$(echo "$input" | "$EVALUATOR")
    if [ "$first" != "$expected" ]; then
        echo "FAIL $name: first run does not match expected golden"
        echo "  expected: $expected"
        echo "  got:      $first"
        FAIL=$((FAIL + 1))
        return
    fi

    # Verify all subsequent runs match the same golden
    local i=2
    while [ "$i" -le "$ITERATIONS" ]; do
        local result
        result=$(echo "$input" | "$EVALUATOR")
        if [ "$result" != "$expected" ]; then
            echo "FAIL $name: mismatch at iteration $i"
            echo "  expected: $expected"
            echo "  got:      $result"
            FAIL=$((FAIL + 1))
            return
        fi
        i=$((i + 1))
    done

    echo "PASS $name: $ITERATIONS iterations, deterministic"
    PASS=$((PASS + 1))
}

# --- Fixed test contexts (protocol v1) ---

CTX_VALID='{"protocol_version":1,"input_count":2,"collateral_count":1,"ref_input_count":0,"script_count":1,"redeemer_count":3,"datum_count":1,"requires_plutus":true,"has_total_collateral":true,"total_collateral":500000,"has_collateral_return":false,"spend_redeemers_mapped":1}'

CTX_NO_REDEEMERS='{"protocol_version":1,"input_count":1,"collateral_count":1,"ref_input_count":0,"script_count":2,"redeemer_count":0,"datum_count":0,"requires_plutus":true,"has_total_collateral":false,"total_collateral":0,"has_collateral_return":false,"spend_redeemers_mapped":0}'

CTX_NO_SCRIPTS='{"protocol_version":1,"input_count":1,"collateral_count":0,"ref_input_count":0,"script_count":0,"redeemer_count":2,"datum_count":1,"requires_plutus":true,"has_total_collateral":false,"total_collateral":0,"has_collateral_return":false,"spend_redeemers_mapped":0}'

CTX_INVALID_REDEEMER='{"protocol_version":1,"input_count":1,"collateral_count":1,"ref_input_count":0,"script_count":1,"redeemer_count":2,"datum_count":1,"requires_plutus":true,"has_total_collateral":false,"total_collateral":0,"has_collateral_return":false,"spend_redeemers_mapped":0}'

CTX_NO_DATUMS='{"protocol_version":1,"input_count":1,"collateral_count":0,"ref_input_count":0,"script_count":1,"redeemer_count":1,"datum_count":0,"requires_plutus":true,"has_total_collateral":false,"total_collateral":0,"has_collateral_return":false,"spend_redeemers_mapped":1}'

# --- Explicit expected golden outputs ---
# These must match the structured rules:
#   Rule 1: redeemer_count==0          → script_failed (4)
#   Rule 2: script_count==0            → missing_context (2)
#   Rule 3: spend_mapped==0 && r>0 s>0 → invalid_redeemer (3)
#   Rule 4: datum_count==0 && s>0      → missing_context (2)
#   Rule 5: success, mem=r*1000+s*500, steps=r*2000+s*1000

GOLDEN_VALID='{"protocol_version":1,"success":true,"error_code":0,"ex_units_mem":3500,"ex_units_steps":7000}'
GOLDEN_NO_REDEEMERS='{"protocol_version":1,"success":false,"error_code":4,"ex_units_mem":0,"ex_units_steps":0}'
GOLDEN_NO_SCRIPTS='{"protocol_version":1,"success":false,"error_code":2,"ex_units_mem":0,"ex_units_steps":0}'
GOLDEN_INVALID_REDEEMER='{"protocol_version":1,"success":false,"error_code":3,"ex_units_mem":0,"ex_units_steps":0}'
GOLDEN_NO_DATUMS='{"protocol_version":1,"success":false,"error_code":2,"ex_units_mem":0,"ex_units_steps":0}'

# --- Run ---

echo "TSUNAGI evaluator integration runner"
echo "iterations: $ITERATIONS"
echo "evaluator:  $EVALUATOR"
echo "---"

run_test "valid_context" "$CTX_VALID" "$GOLDEN_VALID"
run_test "no_redeemers" "$CTX_NO_REDEEMERS" "$GOLDEN_NO_REDEEMERS"
run_test "no_scripts" "$CTX_NO_SCRIPTS" "$GOLDEN_NO_SCRIPTS"
run_test "invalid_redeemer" "$CTX_INVALID_REDEEMER" "$GOLDEN_INVALID_REDEEMER"
run_test "no_datums" "$CTX_NO_DATUMS" "$GOLDEN_NO_DATUMS"

echo "---"
echo "total: $((PASS + FAIL)) | pass: $PASS | fail: $FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
