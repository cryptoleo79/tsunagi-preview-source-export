#!/usr/bin/env bash
# -----------------------------------------------------------------
# generate-mempool-json.sh
# Generates mempool.json from TSUNAGI mempool.ndjson.
#
# Reads the most recent mempool tx events and outputs a JSON file
# with per-transaction decode summaries produced by the runtime
# pipeline (mempool_decoder.zig → journal.appendMempoolTx).
#
# Data source:
#   mempool.ndjson -- per-tx mempool decode events
#
# Usage:
#   ./scripts/generate-mempool-json.sh [output-path]
#
# Environment:
#   TSUNAGI_HOME    -- node state directory (default: ~/tsunagi-home-preview)
#   TSUNAGI_NETWORK -- network name (default: preview)
# -----------------------------------------------------------------
set -euo pipefail

TSUNAGI_HOME="${TSUNAGI_HOME:-$HOME/tsunagi-home-preview}"
NETWORK="${TSUNAGI_NETWORK:-preview}"
OUTPUT="${1:-mempool.json}"
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

# -- Read mempool.ndjson --
MEMPOOL_FILE="$TSUNAGI_HOME/mempool.ndjson"

TX_COUNT=0
RECENT_JSON="[]"

if [ -f "$MEMPOOL_FILE" ]; then
  TX_COUNT=$(grep -c '"type":"mempool_tx"' "$MEMPOOL_FILE" 2>/dev/null || echo "0")
  RECENT_LINES=$(grep '"type":"mempool_tx"' "$MEMPOOL_FILE" 2>/dev/null | tail -"$RECENT_COUNT" || echo "")

  if [ -n "$RECENT_LINES" ]; then
    if $HAS_JQ; then
      RECENT_JSON=$(echo "$RECENT_LINES" | jq -s '[.[] | {
        txid: .txid,
        inputs: .in,
        outputs: .out,
        fee: .fee,
        metadata: .meta,
        size: .size,
        timestamp: (.ts | todate)
      }] | reverse' 2>/dev/null || echo "[]")
    else
      # Build array without jq (newest first)
      RECENT_JSON="["
      FIRST=true
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        T_TXID=$(extract_str "$line" "txid")
        T_IN=$(extract_num "$line" "in")
        T_OUT=$(extract_num "$line" "out")
        T_FEE=$(extract_num "$line" "fee")
        T_META=$(extract_bool "$line" "meta")
        T_SIZE=$(extract_num "$line" "size")
        T_TS=$(extract_num "$line" "ts")
        [ -z "$T_IN" ] && T_IN="0"
        [ -z "$T_OUT" ] && T_OUT="0"
        [ -z "$T_FEE" ] && T_FEE="null"
        [ -z "$T_META" ] && T_META="false"
        [ -z "$T_SIZE" ] && T_SIZE="0"
        TIMESTAMP="null"
        if [ -n "$T_TS" ] && [ "$T_TS" != "0" ]; then
          TIMESTAMP="\"$(date -u -d "@$T_TS" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")\""
        fi
        TXID_JSON="null"
        if [ -n "$T_TXID" ]; then
          TXID_JSON="\"$T_TXID\""
        fi
        if $FIRST; then
          FIRST=false
        else
          RECENT_JSON="$RECENT_JSON,"
        fi
        RECENT_JSON="$RECENT_JSON{\"txid\":$TXID_JSON,\"inputs\":$T_IN,\"outputs\":$T_OUT,\"fee\":$T_FEE,\"metadata\":$T_META,\"size\":$T_SIZE,\"timestamp\":$TIMESTAMP}"
      done <<< "$(echo "$RECENT_LINES" | tac)"
      RECENT_JSON="$RECENT_JSON]"
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
  "tx_count": $TX_COUNT,
  "recent": $RECENT_JSON
}
ENDJSON

echo "Written: $OUTPUT"
