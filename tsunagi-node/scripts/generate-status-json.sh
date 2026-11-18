#!/usr/bin/env bash
set -euo pipefail

# generate-status-json.sh
# Generates status.json from TSUNAGI runtime state files.

TSUNAGI_HOME="${TSUNAGI_PREVIEW_HOME:-$HOME/tsunagi-home-preview}"
OUTPUT="${1:-status.json}"

# ✅ FIX: default metrics port → 9081
METRICS_PORT="${TSUNAGI_METRICS_PORT:-9081}"

CURSOR_FILE="$TSUNAGI_HOME/cursor.json"
JOURNAL_FILE="$TSUNAGI_HOME/journal.ndjson"

now_unix=$(date +%s)

slot=$(jq -r '.slot' "$CURSOR_FILE")
block=$(jq -r '.block_no' "$CURSOR_FILE")
tip_hash=$(jq -r '.tip_hash_hex' "$CURSOR_FILE")
fwd=$(jq -r '.roll_forward_count' "$CURSOR_FILE")
back=$(jq -r '.roll_backward_count' "$CURSOR_FILE")
updated_unix=$(jq -r '.updated_unix' "$CURSOR_FILE")

tip_age=$((now_unix - updated_unix))

tx_count=$(tail -1 "$JOURNAL_FILE" 2>/dev/null | jq -r '.tx_count // 0')
utxo=$(tail -1 "$JOURNAL_FILE" 2>/dev/null | jq -r '.utxo // 0')
consumed=$(tail -1 "$JOURNAL_FILE" 2>/dev/null | jq -r '.consumed // 0')
produced=$(tail -1 "$JOURNAL_FILE" 2>/dev/null | jq -r '.produced // 0')
delta=$((produced - consumed))

# --- truth metrics ---
metrics=$(curl -s "http://127.0.0.1:${METRICS_PORT}/metrics" || true)

truth_ratio=$(awk '$1=="tsunagi_lmdb_truth_ratio" {print $2; exit}' <<< "$metrics")
truth_blocks=$(awk '$1=="tsunagi_lmdb_truth_blocks_total" {print $2; exit}' <<< "$metrics")
fallback_blocks=$(awk '$1=="tsunagi_lmdb_fallback_blocks_total" {print $2; exit}' <<< "$metrics")

if [[ -z "$truth_ratio" ]]; then
  truth_status="unknown"
elif (( $(echo "$truth_ratio > 0.8" | bc -l) )); then
  truth_status="truth_strong"
elif (( $(echo "$truth_ratio > 0.2" | bc -l) )); then
  truth_status="mixed"
else
  truth_status="fallback_heavy"
fi

# --- status classification ---
status="warn"

if [[ -z "$tip_age" ]]; then
  status="critical"
elif (( tip_age > 600 )); then
  status="critical"
elif (( tip_age > 120 )); then
  status="warn"
elif [[ "$truth_status" == "truth_strong" ]]; then
  status="healthy"
elif [[ "$truth_status" == "mixed" || "$truth_status" == "fallback_heavy" ]]; then
  status="converging"
else
  status="warn"
fi

cat > "$OUTPUT" <<JSON
{
  "network": "preview",
  "slot": $slot,
  "block": $block,
  "tip_hash": "$tip_hash",
  "fwd": $fwd,
  "back": $back,
  "utxo": $utxo,
  "status": "$status",
  "tip_age_seconds": $tip_age,
  "tx_count": $tx_count,
  "utxo_consumed": $consumed,
  "utxo_produced": $produced,
  "utxo_delta": $delta,
  "truth": {
    "truth_blocks": ${truth_blocks:-null},
    "fallback_blocks": ${fallback_blocks:-null},
    "truth_ratio": ${truth_ratio:-null},
    "status": "$truth_status"
  }
}
JSON

echo "Written: $OUTPUT"
