#!/usr/bin/env bash
set -euo pipefail

TSUNAGI_HOME="${TSUNAGI_PREVIEW_HOME:-$HOME/tsunagi-home-preview}"
OUTPUT="${1:-operator.json}"

# ✅ FIX: default metrics port → 9081
METRICS_PORT="${TSUNAGI_METRICS_PORT:-9081}"

CURSOR_FILE="$TSUNAGI_HOME/cursor.json"

now_unix=$(date +%s)

slot=$(jq -r '.slot' "$CURSOR_FILE")
block=$(jq -r '.block_no' "$CURSOR_FILE")
tip_hash=$(jq -r '.tip_hash_hex' "$CURSOR_FILE")
updated_unix=$(jq -r '.updated_unix' "$CURSOR_FILE")

tip_age=$((now_unix - updated_unix))

metrics=$(curl -s "http://127.0.0.1:${METRICS_PORT}/metrics" || true)

truth_ratio=$(awk '$1=="tsunagi_lmdb_truth_ratio" {print $2; exit}' <<< "$metrics")

if [[ -z "$truth_ratio" ]]; then
  truth_status="unknown"
elif (( $(echo "$truth_ratio > 0.8" | bc -l) )); then
  truth_status="truth_strong"
elif (( $(echo "$truth_ratio > 0.2" | bc -l) )); then
  truth_status="mixed"
else
  truth_status="fallback_heavy"
fi

status="warn"

if (( tip_age > 600 )); then
  status="critical"
elif (( tip_age > 120 )); then
  status="warn"
elif [[ "$truth_status" == "truth_strong" ]]; then
  status="healthy"
elif [[ "$truth_status" == "mixed" || "$truth_status" == "fallback_heavy" ]]; then
  status="converging"
fi

cat > "$OUTPUT" <<JSON
{
  "node": "tsunagi-preview",
  "network": "preview",
  "sync": {
    "slot": $slot,
    "block": $block,
    "tip_hash": "$tip_hash",
    "tip_age_seconds": $tip_age,
    "status": "$status"
  },
  "truth": {
    "ratio": ${truth_ratio:-null},
    "status": "$truth_status"
  }
}
JSON

echo "Written: $OUTPUT"
