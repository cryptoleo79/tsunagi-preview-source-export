#!/bin/bash
# Structured rule-based evaluator — NOT Plutus.
# Dev/test helper only — not part of TSUNAGI runtime behavior.
# Reads serialized PlutusExecutionContext JSON from stdin,
# applies deterministic rules, outputs ExecutionResult JSON.
# Same rules as evaluateMinimalRules() in eval_external.zig.
# Protocol version: 1 (TSUNAGI external evaluator protocol).

set -e
read -r input

# Extract fields from JSON (minimal grep-based, no jq dependency)
protocol_version=$(echo "$input" | grep -o '"protocol_version":[0-9]*' | grep -o '[0-9]*$')
redeemer_count=$(echo "$input" | grep -o '"redeemer_count":[0-9]*' | grep -o '[0-9]*$')
script_count=$(echo "$input" | grep -o '"script_count":[0-9]*' | grep -o '[0-9]*$')
datum_count=$(echo "$input" | grep -o '"datum_count":[0-9]*' | grep -o '[0-9]*$')
spend_mapped=$(echo "$input" | grep -o '"spend_redeemers_mapped":[0-9]*' | grep -o '[0-9]*$')

# Reject wrong or missing protocol version
if [ -z "$protocol_version" ] || [ "$protocol_version" != "1" ]; then
    echo '{"protocol_version":1,"success":false,"error_code":6,"ex_units_mem":0,"ex_units_steps":0}'
    exit 0
fi

# Default to 0 if fields missing
redeemer_count=${redeemer_count:-0}
script_count=${script_count:-0}
datum_count=${datum_count:-0}
spend_mapped=${spend_mapped:-0}

# Rule 1: no redeemers → script_failed (error_code=4)
if [ "$redeemer_count" -eq 0 ]; then
    echo '{"protocol_version":1,"success":false,"error_code":4,"ex_units_mem":0,"ex_units_steps":0}'
    exit 0
fi

# Rule 2: no scripts → missing_context (error_code=2)
if [ "$script_count" -eq 0 ]; then
    echo '{"protocol_version":1,"success":false,"error_code":2,"ex_units_mem":0,"ex_units_steps":0}'
    exit 0
fi

# Rule 3: redeemers + scripts but zero spend redeemers mapped → invalid_redeemer (error_code=3)
if [ "$spend_mapped" -eq 0 ]; then
    echo '{"protocol_version":1,"success":false,"error_code":3,"ex_units_mem":0,"ex_units_steps":0}'
    exit 0
fi

# Rule 4: no datums with scripts present → missing_context (error_code=2)
if [ "$datum_count" -eq 0 ]; then
    echo '{"protocol_version":1,"success":false,"error_code":2,"ex_units_mem":0,"ex_units_steps":0}'
    exit 0
fi

# Rule 5: success with deterministic ex_units
ex_units_mem=$((redeemer_count * 1000 + script_count * 500))
ex_units_steps=$((redeemer_count * 2000 + script_count * 1000))
echo "{\"protocol_version\":1,\"success\":true,\"error_code\":0,\"ex_units_mem\":${ex_units_mem},\"ex_units_steps\":${ex_units_steps}}"
