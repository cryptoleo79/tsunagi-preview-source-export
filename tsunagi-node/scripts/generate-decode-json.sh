#!/usr/bin/env bash
# -----------------------------------------------------------------
# generate-decode-json.sh
# Generates decode.json from TSUNAGI tx_decode.ndjson.
#
# Reads the most recent tx_decode events and outputs a JSON file
# with per-block, per-transaction decode summaries produced by the
# runtime pipeline (tx_decoder.zig → journal.appendTxDecode).
#
# Data source:
#   tx_decode.ndjson -- per-block tx decode events
#
# Usage:
#   ./scripts/generate-decode-json.sh [output-path]
#
# Environment:
#   TSUNAGI_HOME    -- node state directory (default: ~/tsunagi-home-preview)
#   TSUNAGI_NETWORK -- network name (default: preview)
# -----------------------------------------------------------------
set -euo pipefail

TSUNAGI_HOME="${TSUNAGI_HOME:-$HOME/tsunagi-home-preview}"
NETWORK="${TSUNAGI_NETWORK:-preview}"
OUTPUT="${1:-decode.json}"
RECENT_COUNT=50

# -- jq detection --
HAS_JQ=false
if command -v jq &>/dev/null; then
  HAS_JQ=true
fi

# -- Portable JSON extraction --
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

# -- Read tx_decode.ndjson --
DECODE_FILE="$TSUNAGI_HOME/tx_decode.ndjson"

BLOCKS_JSON="[]"

if [ -f "$DECODE_FILE" ]; then
  RECENT_LINES=$(grep '"type":"tx_decode"' "$DECODE_FILE" 2>/dev/null | tail -"$RECENT_COUNT" || echo "")

  if [ -n "$RECENT_LINES" ]; then
    if $HAS_JQ; then
      BLOCKS_JSON=$(echo "$RECENT_LINES" | jq -s '[.[] | {
        slot: .slot,
        block: .block_no,
        block_hash: (.block_hash // null),
        tx_count: (.tx_count // 0),
        truncated: (.truncated // false),
        transactions: [(.txs // [])[] | {
          index: .idx,
          inputs: .in,
          outputs: .out,
          fee: .fee,
          metadata: .meta
        }]
      }] | reverse' 2>/dev/null || echo "[]")
    else
      # Build blocks array without jq (newest first)
      BLOCKS_JSON="["
      FIRST=true
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        B_SLOT=$(extract_num "$line" "slot")
        B_BLOCK=$(extract_num "$line" "block_no")
        B_HASH=$(extract_str "$line" "block_hash")
        B_TX=$(extract_num "$line" "tx_count")
        B_TRUNC=$(extract_bool "$line" "truncated")
        B_TXS=$(extract_txs_array "$line")
        [ -z "$B_SLOT" ] && B_SLOT="null"
        [ -z "$B_BLOCK" ] && B_BLOCK="null"
        [ -z "$B_TX" ] && B_TX="0"
        [ -z "$B_TRUNC" ] && B_TRUNC="false"
        [ -z "$B_TXS" ] && B_TXS="[]"
        if [ -n "$B_HASH" ]; then
          B_HASH_JSON="\"$B_HASH\""
        else
          B_HASH_JSON="null"
        fi
        # Reformat txs: {idx->index, in->inputs, out->outputs, fee->fee, meta->metadata}
        B_TXS_FMT=$(echo "$B_TXS" | sed 's/"idx"/"index"/g;s/"in"/"inputs"/g;s/"out"/"outputs"/g;s/"meta"/"metadata"/g')
        if $FIRST; then
          FIRST=false
        else
          BLOCKS_JSON="$BLOCKS_JSON,"
        fi
        BLOCKS_JSON="$BLOCKS_JSON{\"slot\":$B_SLOT,\"block\":$B_BLOCK,\"block_hash\":$B_HASH_JSON,\"tx_count\":$B_TX,\"truncated\":$B_TRUNC,\"transactions\":$B_TXS_FMT}"
      done <<< "$(echo "$RECENT_LINES" | tac)"
      BLOCKS_JSON="$BLOCKS_JSON]"
    fi
  fi
fi

# -- generated_at --
GENERATED_AT=$(date -u "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "null")

# -- Write JSON --
cat > "$OUTPUT" <<ENDJSON
{
  "network": "$NETWORK",
  "generated_at": "$GENERATED_AT",
  "blocks": $BLOCKS_JSON
}
ENDJSON

echo "Written: $OUTPUT"
