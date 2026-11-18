#!/bin/bash
# Backend conformance matrix for TSUNAGI external evaluator protocol.
# Dev/test helper only — not part of TSUNAGI runtime behavior.
#
# Runs each canonical fixture through both external evaluator backends
# (compiled binary + shell script) and compares byte-for-byte against
# the expected response fixture.
#
# Embedded backend conformance is verified by zig build test
# (100-iteration determinism tests in eval_external.zig).
#
# Usage: bash tools/eval-conformance-runner.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
FIXTURES_DIR="${SCRIPT_DIR}/eval-fixtures"
BINARY="${REPO_ROOT}/zig-out/bin/plutus-evaluator"
SHELL_EVAL="${SCRIPT_DIR}/plutus-evaluator.sh"

# Verify both backends exist
HAVE_BINARY=true
HAVE_SHELL=true

if [ ! -x "$BINARY" ]; then
    echo "WARN: compiled binary not found at $BINARY (run 'zig build' first)"
    HAVE_BINARY=false
fi
if [ ! -x "$SHELL_EVAL" ]; then
    echo "WARN: shell evaluator not found at $SHELL_EVAL"
    HAVE_SHELL=false
fi
if [ "$HAVE_BINARY" = false ] && [ "$HAVE_SHELL" = false ]; then
    echo "FAIL: no backends available"
    exit 1
fi

PASS=0
FAIL=0
SKIP=0

# Fixed deterministic fixture order
FIXTURES="valid-context no-redeemers no-scripts invalid-redeemer no-datums wrong-version"

echo "TSUNAGI backend conformance matrix"
echo "binary: $BINARY"
echo "shell:  $SHELL_EVAL"
echo "---"
printf "%-20s %-8s %-8s\n" "fixture" "binary" "shell"
printf "%-20s %-8s %-8s\n" "-------" "------" "-----"

for name in $FIXTURES; do
    input="${FIXTURES_DIR}/${name}.json"
    expected="${FIXTURES_DIR}/${name}.expected.json"

    if [ ! -f "$input" ] || [ ! -f "$expected" ]; then
        printf "%-20s %-8s %-8s\n" "$name" "MISS" "MISS"
        FAIL=$((FAIL + 2))
        continue
    fi

    expected_content=$(cat "$expected")

    # Binary backend
    if [ "$HAVE_BINARY" = true ]; then
        binary_result=$("$BINARY" < "$input")
        if [ "$binary_result" = "$expected_content" ]; then
            binary_status="PASS"
            PASS=$((PASS + 1))
        else
            binary_status="FAIL"
            FAIL=$((FAIL + 1))
        fi
    else
        binary_status="SKIP"
        SKIP=$((SKIP + 1))
    fi

    # Shell backend (printf adds trailing newline for read -r)
    if [ "$HAVE_SHELL" = true ]; then
        shell_result=$(printf '%s\n' "$(<"$input")" | "$SHELL_EVAL")
        if [ "$shell_result" = "$expected_content" ]; then
            shell_status="PASS"
            PASS=$((PASS + 1))
        else
            shell_status="FAIL"
            FAIL=$((FAIL + 1))
        fi
    else
        shell_status="SKIP"
        SKIP=$((SKIP + 1))
    fi

    printf "%-20s %-8s %-8s\n" "$name" "$binary_status" "$shell_status"

    # Print mismatch details
    if [ "$binary_status" = "FAIL" ]; then
        echo "  binary expected: $expected_content"
        echo "  binary got:      $binary_result"
    fi
    if [ "$shell_status" = "FAIL" ]; then
        echo "  shell expected:  $expected_content"
        echo "  shell got:       $shell_result"
    fi
done

echo "---"
echo "total: $((PASS + FAIL + SKIP)) | pass: $PASS | fail: $FAIL | skip: $SKIP"
echo "note: embedded backend conformance verified by zig build test"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
