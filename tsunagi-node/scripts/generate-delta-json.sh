#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# generate-delta-json.sh
# Generates delta.json from TSUNAGI journal.ndjson.
#
# Reads the most recent roll_forward events from the journal
# and outputs a JSON file with the latest block delta and a
# recent history array.
#
# Data source:
#   journal.ndjson — last N roll_forward events
#
# Usage:
#   ./scripts/generate-delta-json.sh [output-path]
#
# Environment:
#   TSUNAGI_HOME    — node state directory (default: ~/tsunagi-home-preview)
#   TSUNAGI_NETWORK — network name (default: preview)
# ─────────────────────────────────────────────────────────────
set -euo pipefail

TSUNAGI_HOME="${TSUNAGI_HOME:-$HOME/tsunagi-home-preview}"
NETWORK="${TSUNAGI_NETWORK:-preview}"
OUTPUT="${1:-delta.json}"
RECENT_COUNT=50

# ── jq detection ──────────────────────────────────────────────
HAS_JQ=false
if command -v jq &>/dev/null; then
  HAS_JQ=true
fi

# ── Portable JSON extraction (no jq needed) ───────────────────
extract_num() {
  echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p" | head -1
}

# ── Read journal.ndjson ────────────────────────────────────────
JOURNAL_FILE="$TSUNAGI_HOME/journal.ndjson"

LATEST_SLOT="null"
LATEST_BLOCK="null"
LATEST_TX="null"
LATEST_CONSUMED="null"
LATEST_PRODUCED="null"
LATEST_DELTA="null"

RECENT_JSON="[]"

if [ -f "$JOURNAL_FILE" ]; then
  # Get last RECENT_COUNT roll_forward events
  RECENT_LINES=$(grep '"type":"roll_forward"' "$JOURNAL_FILE" 2>/dev/null | tail -"$RECENT_COUNT" || echo "")

  if [ -n "$RECENT_LINES" ]; then
    # Extract latest (last line)
    LAST_LINE=$(echo "$RECENT_LINES" | tail -1)

    if $HAS_JQ; then
      LATEST_SLOT=$(echo "$LAST_LINE" | jq '.slot // null' 2>/dev/null || echo "null")
      LATEST_BLOCK=$(echo "$LAST_LINE" | jq '.block_no // null' 2>/dev/null || echo "null")
      LATEST_TX=$(echo "$LAST_LINE" | jq '.tx_count // null' 2>/dev/null || echo "null")
      LATEST_CONSUMED=$(echo "$LAST_LINE" | jq '.utxo_consumed // null' 2>/dev/null || echo "null")
      LATEST_PRODUCED=$(echo "$LAST_LINE" | jq '.utxo_produced // null' 2>/dev/null || echo "null")
      LATEST_DELTA=$(echo "$LAST_LINE" | jq '.utxo_delta // null' 2>/dev/null || echo "null")

      # Build recent array with jq
      RECENT_JSON=$(echo "$RECENT_LINES" | jq -s '[.[] | {slot: .slot, block: .block_no, tx_count: .tx_count, utxo_consumed: (.utxo_consumed // 0), utxo_produced: (.utxo_produced // 0), delta: (.utxo_delta // 0)}] | reverse' 2>/dev/null || echo "[]")
    else
      LATEST_SLOT=$(extract_num "$LAST_LINE" "slot")
      LATEST_BLOCK=$(extract_num "$LAST_LINE" "block_no")
      LATEST_TX=$(extract_num "$LAST_LINE" "tx_count")
      LATEST_CONSUMED=$(extract_num "$LAST_LINE" "utxo_consumed")
      LATEST_PRODUCED=$(extract_num "$LAST_LINE" "utxo_produced")
      LATEST_DELTA=$(extract_num "$LAST_LINE" "utxo_delta")

      [ -z "$LATEST_SLOT" ] && LATEST_SLOT="null"
      [ -z "$LATEST_BLOCK" ] && LATEST_BLOCK="null"
      [ -z "$LATEST_TX" ] && LATEST_TX="null"
      [ -z "$LATEST_CONSUMED" ] && LATEST_CONSUMED="null"
      [ -z "$LATEST_PRODUCED" ] && LATEST_PRODUCED="null"
      [ -z "$LATEST_DELTA" ] && LATEST_DELTA="null"

      # Build recent array without jq (reverse order — newest first)
      RECENT_JSON="["
      FIRST=true
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        R_SLOT=$(extract_num "$line" "slot")
        R_BLOCK=$(extract_num "$line" "block_no")
        R_TX=$(extract_num "$line" "tx_count")
        R_CONSUMED=$(extract_num "$line" "utxo_consumed")
        R_PRODUCED=$(extract_num "$line" "utxo_produced")
        R_DELTA=$(extract_num "$line" "utxo_delta")
        [ -z "$R_SLOT" ] && R_SLOT="null"
        [ -z "$R_BLOCK" ] && R_BLOCK="null"
        [ -z "$R_TX" ] && R_TX="null"
        [ -z "$R_CONSUMED" ] && R_CONSUMED="0"
        [ -z "$R_PRODUCED" ] && R_PRODUCED="0"
        [ -z "$R_DELTA" ] && R_DELTA="0"
        if $FIRST; then
          FIRST=false
        else
          RECENT_JSON="$RECENT_JSON,"
        fi
        RECENT_JSON="$RECENT_JSON{\"slot\":$R_SLOT,\"block\":$R_BLOCK,\"tx_count\":$R_TX,\"utxo_consumed\":$R_CONSUMED,\"utxo_produced\":$R_PRODUCED,\"delta\":$R_DELTA}"
      done <<< "$(echo "$RECENT_LINES" | tac)"
      RECENT_JSON="$RECENT_JSON]"
    fi
  fi
fi

# ── generated_at ──────────────────────────────────────────────
GENERATED_AT=$(date -u "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "null")

# ── Write JSON ────────────────────────────────────────────────
cat > "$OUTPUT" <<ENDJSON
{
  "network": "$NETWORK",
  "generated_at": "$GENERATED_AT",
  "latest": {
    "slot": $LATEST_SLOT,
    "block": $LATEST_BLOCK,
    "tx_count": $LATEST_TX,
    "utxo_consumed": $LATEST_CONSUMED,
    "utxo_produced": $LATEST_PRODUCED,
    "utxo_delta": $LATEST_DELTA
  },
  "recent": $RECENT_JSON
}
ENDJSON

echo "Written: $OUTPUT"
