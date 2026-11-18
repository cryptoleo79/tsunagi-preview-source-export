#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# generate-block-detail-json.sh
# Generates a single block detail JSON from journal.ndjson and
# tx_decode.ndjson.
#
# Searches recent journal history for a specific block number,
# then enriches with per-tx decode summaries from tx_decode.ndjson.
#
# Usage:
#   ./scripts/generate-block-detail-json.sh <block_no> [output-path]
#
# Environment:
#   TSUNAGI_HOME    — node state directory (default: ~/tsunagi-home-preview)
#   TSUNAGI_NETWORK — network name (default: preview)
# ─────────────────────────────────────────────────────────────
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <block_no> [output-path]" >&2
  exit 1
fi

BLOCK_NO="$1"
OUTPUT="${2:-block-detail-${BLOCK_NO}.json}"
TSUNAGI_HOME="${TSUNAGI_HOME:-$HOME/tsunagi-home-preview}"
NETWORK="${TSUNAGI_NETWORK:-preview}"

# ── jq detection ──────────────────────────────────────────────
HAS_JQ=false
if command -v jq &>/dev/null; then
  HAS_JQ=true
fi

# ── Portable JSON extraction ─────────────────────────────────
extract_num() {
  echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p" | head -1
}
extract_str() {
  echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}
extract_bool() {
  echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p" | head -1
}
extract_txs_array() {
  echo "$1" | sed -n 's/.*"txs":\(\[.*\]\).*/\1/p' | head -1
}

# ── Search journal.ndjson ─────────────────────────────────────
JOURNAL_FILE="$TSUNAGI_HOME/journal.ndjson"
DECODE_FILE="$TSUNAGI_HOME/tx_decode.ndjson"

if [ ! -f "$JOURNAL_FILE" ]; then
  echo "Error: journal not found at $JOURNAL_FILE" >&2
  exit 1
fi

# Find the matching roll_forward entry (last occurrence wins)
MATCH=$(grep '"type":"roll_forward"' "$JOURNAL_FILE" 2>/dev/null | grep "\"block_no\":${BLOCK_NO}[,}]" | tail -1 || echo "")

if [ -z "$MATCH" ]; then
  echo "Error: block $BLOCK_NO not found in recent journal history" >&2
  exit 1
fi

# ── Extract base fields from journal ─────────────────────────
if $HAS_JQ; then
  SLOT=$(echo "$MATCH" | jq '.slot // null' 2>/dev/null || echo "null")
  BLOCK=$(echo "$MATCH" | jq '.block_no // null' 2>/dev/null || echo "null")
  BLOCK_HASH=$(echo "$MATCH" | jq -r '.header_hash_hex // empty' 2>/dev/null || echo "")
  TIP_HASH=$(echo "$MATCH" | jq -r '.tip_hash_hex // empty' 2>/dev/null || echo "")
  TX_COUNT=$(echo "$MATCH" | jq '.tx_count // null' 2>/dev/null || echo "null")
  UTXO_CONSUMED=$(echo "$MATCH" | jq '.utxo_consumed // null' 2>/dev/null || echo "null")
  UTXO_PRODUCED=$(echo "$MATCH" | jq '.utxo_produced // null' 2>/dev/null || echo "null")
  UTXO_DELTA=$(echo "$MATCH" | jq '.utxo_delta // null' 2>/dev/null || echo "null")
  UTXO_COUNT=$(echo "$MATCH" | jq '.utxo_count // null' 2>/dev/null || echo "null")
  TS=$(echo "$MATCH" | jq -r '.ts // empty' 2>/dev/null || echo "")
else
  SLOT=$(extract_num "$MATCH" "slot")
  BLOCK=$(extract_num "$MATCH" "block_no")
  BLOCK_HASH=$(extract_str "$MATCH" "header_hash_hex")
  TIP_HASH=$(extract_str "$MATCH" "tip_hash_hex")
  TX_COUNT=$(extract_num "$MATCH" "tx_count")
  UTXO_CONSUMED=$(extract_num "$MATCH" "utxo_consumed")
  UTXO_PRODUCED=$(extract_num "$MATCH" "utxo_produced")
  UTXO_DELTA=$(extract_num "$MATCH" "utxo_delta")
  UTXO_COUNT=$(extract_num "$MATCH" "utxo_count")
  TS=$(extract_num "$MATCH" "ts")
fi

[ -z "$SLOT" ] && SLOT="null"
[ -z "$BLOCK" ] && BLOCK="null"
[ -z "$TX_COUNT" ] && TX_COUNT="null"
[ -z "$UTXO_CONSUMED" ] && UTXO_CONSUMED="null"
[ -z "$UTXO_PRODUCED" ] && UTXO_PRODUCED="null"
[ -z "$UTXO_DELTA" ] && UTXO_DELTA="null"
[ -z "$UTXO_COUNT" ] && UTXO_COUNT="null"

# Format strings
if [ -n "$BLOCK_HASH" ]; then
  BLOCK_HASH_JSON="\"$BLOCK_HASH\""
else
  BLOCK_HASH_JSON="null"
fi

if [ -n "$TIP_HASH" ]; then
  TIP_HASH_JSON="\"$TIP_HASH\""
else
  TIP_HASH_JSON="null"
fi

TIMESTAMP_JSON="null"
if [ -n "$TS" ] && [ "$TS" != "0" ]; then
  TIMESTAMP_JSON="\"$(date -u -d "@$TS" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "null")\""
fi

# ── Search tx_decode.ndjson for per-tx data ──────────────────
TRUNCATED="false"
TRANSACTIONS_JSON="null"

if [ -f "$DECODE_FILE" ]; then
  DECODE_MATCH=$(grep '"type":"tx_decode"' "$DECODE_FILE" 2>/dev/null | grep "\"block_no\":${BLOCK_NO}[,}]" | tail -1 || echo "")

  if [ -n "$DECODE_MATCH" ]; then
    if $HAS_JQ; then
      TRUNCATED=$(echo "$DECODE_MATCH" | jq '.truncated // false' 2>/dev/null || echo "false")
      TRANSACTIONS_JSON=$(echo "$DECODE_MATCH" | jq '[(.txs // [])[] | {
        index: .idx,
        inputs: .in,
        outputs: .out,
        fee: .fee,
        metadata: .meta
      }]' 2>/dev/null || echo "null")
    else
      T_VAL=$(extract_bool "$DECODE_MATCH" "truncated")
      [ -n "$T_VAL" ] && TRUNCATED="$T_VAL"
      # Reformat txs array: idx->index, in->inputs, out->outputs, meta->metadata
      RAW_TXS=$(extract_txs_array "$DECODE_MATCH")
      if [ -n "$RAW_TXS" ]; then
        TRANSACTIONS_JSON=$(echo "$RAW_TXS" | sed 's/"idx"/"index"/g;s/"in"/"inputs"/g;s/"out"/"outputs"/g;s/"meta"/"metadata"/g')
      fi
    fi
  fi
fi

# ── Write JSON ────────────────────────────────────────────────
cat > "$OUTPUT" <<ENDJSON
{
  "network": "$NETWORK",
  "block": $BLOCK,
  "slot": $SLOT,
  "block_hash": $BLOCK_HASH_JSON,
  "tip_hash": $TIP_HASH_JSON,
  "tx_count": $TX_COUNT,
  "utxo_consumed": $UTXO_CONSUMED,
  "utxo_produced": $UTXO_PRODUCED,
  "utxo_delta": $UTXO_DELTA,
  "utxo_set_size": $UTXO_COUNT,
  "truncated": $TRUNCATED,
  "transactions": $TRANSACTIONS_JSON,
  "timestamp": $TIMESTAMP_JSON,
  "source": "journal.ndjson + tx_decode.ndjson"
}
ENDJSON

echo "Written: $OUTPUT"
