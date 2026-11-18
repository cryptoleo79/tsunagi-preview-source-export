#!/usr/bin/env bash
# -----------------------------------------------------------------
# generate-confirmation-json.sh
# Generates confirmation.json from TSUNAGI confirmation.ndjson
# and mempool.ndjson.
#
# Reads recent confirmed tx events and recent pending mempool txs
# (excluding those already confirmed). Outputs a JSON file for
# the confirmation observatory page.
#
# Data sources:
#   confirmation.ndjson -- per-tx confirmation events
#   mempool.ndjson      -- per-tx mempool submission events
#
# Usage:
#   ./scripts/generate-confirmation-json.sh [output-path]
#
# Environment:
#   TSUNAGI_HOME    -- node state directory (default: ~/tsunagi-home-preview)
#   TSUNAGI_NETWORK -- network name (default: preview)
# -----------------------------------------------------------------
set -euo pipefail

TSUNAGI_HOME="${TSUNAGI_HOME:-$HOME/tsunagi-home-preview}"
NETWORK="${TSUNAGI_NETWORK:-preview}"
OUTPUT="${1:-confirmation.json}"
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

# -- Read confirmation.ndjson --
CONFIRM_FILE="$TSUNAGI_HOME/confirmation.ndjson"
MEMPOOL_FILE="$TSUNAGI_HOME/mempool.ndjson"

CONFIRMED_COUNT=0
CONFIRMED_JSON="[]"
PENDING_COUNT=0
PENDING_JSON="[]"

# -- Build confirmed list --
if [ -f "$CONFIRM_FILE" ]; then
  CONFIRMED_COUNT=$(grep -c '"type":"confirmed_tx"' "$CONFIRM_FILE" 2>/dev/null || echo "0")
  RECENT_CONFIRMED=$(grep '"type":"confirmed_tx"' "$CONFIRM_FILE" 2>/dev/null | tail -"$RECENT_COUNT" || echo "")

  if [ -n "$RECENT_CONFIRMED" ]; then
    if $HAS_JQ; then
      CONFIRMED_JSON=$(echo "$RECENT_CONFIRMED" | jq -s '[.[] | {
        txid: .txid,
        block: .block,
        slot: .slot,
        confirmation_seconds: .seconds,
        fee: .fee,
        timestamp: (.confirmed | todate)
      }] | reverse' 2>/dev/null || echo "[]")
    else
      CONFIRMED_JSON="["
      FIRST=true
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        C_TXID=$(extract_str "$line" "txid")
        C_BLOCK=$(extract_num "$line" "block")
        C_SLOT=$(extract_num "$line" "slot")
        C_SECS=$(extract_num "$line" "seconds")
        C_FEE=$(extract_num "$line" "fee")
        C_CONFIRMED=$(extract_num "$line" "confirmed")
        [ -z "$C_BLOCK" ] && C_BLOCK="0"
        [ -z "$C_SLOT" ] && C_SLOT="0"
        [ -z "$C_SECS" ] && C_SECS="0"
        [ -z "$C_FEE" ] && C_FEE="null"
        TIMESTAMP="null"
        if [ -n "$C_CONFIRMED" ] && [ "$C_CONFIRMED" != "0" ]; then
          TIMESTAMP="\"$(date -u -d "@$C_CONFIRMED" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")\""
        fi
        TXID_JSON="null"
        if [ -n "$C_TXID" ]; then
          TXID_JSON="\"$C_TXID\""
        fi
        if $FIRST; then
          FIRST=false
        else
          CONFIRMED_JSON="$CONFIRMED_JSON,"
        fi
        CONFIRMED_JSON="$CONFIRMED_JSON{\"txid\":$TXID_JSON,\"block\":$C_BLOCK,\"slot\":$C_SLOT,\"confirmation_seconds\":$C_SECS,\"fee\":$C_FEE,\"timestamp\":$TIMESTAMP}"
      done <<< "$(echo "$RECENT_CONFIRMED" | tac)"
      CONFIRMED_JSON="$CONFIRMED_JSON]"
    fi
  fi
fi

# -- Build pending list (mempool txs not yet confirmed) --
if [ -f "$MEMPOOL_FILE" ]; then
  # Collect confirmed txids for exclusion
  CONFIRMED_TXIDS=""
  if [ -f "$CONFIRM_FILE" ]; then
    if $HAS_JQ; then
      CONFIRMED_TXIDS=$(grep '"type":"confirmed_tx"' "$CONFIRM_FILE" 2>/dev/null | jq -r '.txid' 2>/dev/null || echo "")
    else
      CONFIRMED_TXIDS=$(grep '"type":"confirmed_tx"' "$CONFIRM_FILE" 2>/dev/null | sed -n 's/.*"txid"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || echo "")
    fi
  fi

  RECENT_MEMPOOL=$(grep '"type":"mempool_tx"' "$MEMPOOL_FILE" 2>/dev/null | tail -"$RECENT_COUNT" || echo "")

  if [ -n "$RECENT_MEMPOOL" ]; then
    NOW=$(date +%s 2>/dev/null || echo "0")
    if $HAS_JQ; then
      # Pass confirmed txids as a filter
      if [ -n "$CONFIRMED_TXIDS" ]; then
        CONFIRMED_SET=$(echo "$CONFIRMED_TXIDS" | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
      else
        CONFIRMED_SET="[]"
      fi
      PENDING_JSON=$(echo "$RECENT_MEMPOOL" | jq -s --argjson confirmed "$CONFIRMED_SET" --argjson now "$NOW" '[.[] | select(.txid as $t | $confirmed | index($t) | not) | {
        txid: .txid,
        age_seconds: ($now - .ts),
        fee: .fee,
        inputs: .in,
        outputs: .out
      }] | reverse' 2>/dev/null || echo "[]")
      PENDING_COUNT=$(echo "$PENDING_JSON" | jq 'length' 2>/dev/null || echo "0")
    else
      PENDING_JSON="["
      FIRST=true
      P_COUNT=0
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        P_TXID=$(extract_str "$line" "txid")
        # Skip if confirmed
        if [ -n "$P_TXID" ] && echo "$CONFIRMED_TXIDS" | grep -qF "$P_TXID" 2>/dev/null; then
          continue
        fi
        P_IN=$(extract_num "$line" "in")
        P_OUT=$(extract_num "$line" "out")
        P_FEE=$(extract_num "$line" "fee")
        P_TS=$(extract_num "$line" "ts")
        [ -z "$P_IN" ] && P_IN="0"
        [ -z "$P_OUT" ] && P_OUT="0"
        [ -z "$P_FEE" ] && P_FEE="null"
        AGE="0"
        if [ -n "$P_TS" ] && [ "$P_TS" != "0" ] && [ "$NOW" != "0" ]; then
          AGE=$((NOW - P_TS))
        fi
        TXID_JSON="null"
        if [ -n "$P_TXID" ]; then
          TXID_JSON="\"$P_TXID\""
        fi
        if $FIRST; then
          FIRST=false
        else
          PENDING_JSON="$PENDING_JSON,"
        fi
        PENDING_JSON="$PENDING_JSON{\"txid\":$TXID_JSON,\"age_seconds\":$AGE,\"fee\":$P_FEE,\"inputs\":$P_IN,\"outputs\":$P_OUT}"
        P_COUNT=$((P_COUNT + 1))
      done <<< "$(echo "$RECENT_MEMPOOL" | tac)"
      PENDING_JSON="$PENDING_JSON]"
      PENDING_COUNT=$P_COUNT
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
  "pending_count": $PENDING_COUNT,
  "confirmed_count": $CONFIRMED_COUNT,
  "recent_confirmed": $CONFIRMED_JSON,
  "recent_pending": $PENDING_JSON
}
ENDJSON

echo "Written: $OUTPUT"
