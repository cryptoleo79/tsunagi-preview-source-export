#!/bin/bash
# Canonical protocol fixture runner for TSUNAGI external evaluator.
# Dev/test helper only — not part of TSUNAGI runtime behavior.
#
# Runs the compiled evaluator binary against each canonical fixture
# and compares stdout byte-for-byte against the expected response.
# Reports all results before exiting (does not stop at first mismatch).
#
# Evaluator selection:
#   1. EVALUATOR env var (if set)
#   2. zig-out/bin/plutus-evaluator
#
# Usage: bash tools/eval-fixture-runner.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES_DIR="${SCRIPT_DIR}/eval-fixtures"
BINARY="${SCRIPT_DIR}/../zig-out/bin/plutus-evaluator"

# Evaluator selection
if [ -n "$EVALUATOR" ]; then
    : # use EVALUATOR as-is from env
elif [ -x "$BINARY" ]; then
    EVALUATOR="$BINARY"
else
    echo "FAIL: evaluator binary not found at $BINARY"
    echo "      run 'zig build' first or set EVALUATOR env var"
    exit 1
fi

if [ ! -x "$EVALUATOR" ]; then
    echo "FAIL: evaluator not executable at $EVALUATOR"
    exit 1
fi

PASS=0
FAIL=0

# Fixed deterministic fixture order — do not rely on shell glob ordering
FIXTURES="valid-context no-redeemers no-scripts invalid-redeemer no-datums wrong-version known-case-v1-spend"

echo "TSUNAGI protocol fixture runner"
echo "evaluator: $EVALUATOR"
echo "fixtures:  $FIXTURES_DIR"
echo "---"

for name in $FIXTURES; do
    input="${FIXTURES_DIR}/${name}.json"
    expected="${FIXTURES_DIR}/${name}.expected.json"

    if [ ! -f "$input" ]; then
        echo "FAIL $name: input fixture not found ($input)"
        FAIL=$((FAIL + 1))
        continue
    fi
    if [ ! -f "$expected" ]; then
        echo "FAIL $name: expected fixture not found ($expected)"
        FAIL=$((FAIL + 1))
        continue
    fi

    actual=$("$EVALUATOR" < "$input")
    expected_content=$(cat "$expected")

    if [ "$actual" = "$expected_content" ]; then
        echo "PASS $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL $name"
        echo "  expected: $expected_content"
        echo "  got:      $actual"
        FAIL=$((FAIL + 1))
    fi
done

echo "---"
echo "total: $((PASS + FAIL)) | pass: $PASS | fail: $FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
