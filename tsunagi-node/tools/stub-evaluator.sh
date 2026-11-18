#!/bin/bash
# Dev/test helper only — not part of TSUNAGI runtime behavior.
# Reads serialized PlutusExecutionContext from stdin,
# returns a fixed ExecutionResult JSON on stdout.
# Protocol version must match TSUNAGI external evaluator protocol v1.
read -r _input
echo '{"protocol_version":1,"success":false,"error_code":1,"ex_units_mem":0,"ex_units_steps":0}'
