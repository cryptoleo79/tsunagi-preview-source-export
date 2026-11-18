#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# generate-blocks-json.sh
# Generates blocks.json from TSUNAGI journal.ndjson and
# tx_decode.ndjson.
#
# Reads the most recent roll_forward events and merges per-tx
# decode metadata (truncated flag) from the decode stream.
#
# Data sources:
#   journal.ndjson   — block-level delta data
#   tx_decode.ndjson — per-tx decode metadata (truncated flag)
#
# Usage:
#   ./scripts/generate-blocks-json.sh [output-path]
#
# Environment:
#   TSUNAGI_HOME    — node state directory (default: ~/tsunagi-home-preview)
#   TSUNAGI_NETWORK — network name (default: preview)
# ─────────────────────────────────────────────────────────────
set -euo pipefail

TSUNAGI_HOME="${TSUNAGI_HOME:-$HOME/tsunagi-home-preview}"
NETWORK="${TSUNAGI_NETWORK:-preview}"
OUTPUT="${1:-blocks.json}"
RECENT_COUNT=50

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

# ── Data files ───────────────────────────────────────────────
JOURNAL_FILE="$TSUNAGI_HOME/journal.ndjson"
DECODE_FILE="$TSUNAGI_HOME/tx_decode.ndjson"

RECENT_JSON="[]"

if [ -f "$JOURNAL_FILE" ]; then
  RECENT_LINES=$(grep '"type":"roll_forward"' "$JOURNAL_FILE" 2>/dev/null | tail -"$RECENT_COUNT" || echo "")

  # Load decode lines for truncated lookup
  DECODE_LINES=""
  if [ -f "$DECODE_FILE" ]; then
    DECODE_LINES=$(grep '"type":"tx_decode"' "$DECODE_FILE" 2>/dev/null | tail -"$RECENT_COUNT" || echo "")
  fi

  if [ -n "$RECENT_LINES" ]; then
    if $HAS_JQ; then
      # Build journal array
      JOURNAL_ARR=$(echo "$RECENT_LINES" | jq -s '[.[] | {
        slot: .slot,
        block: .block_no,
        block_hash: (.header_hash_hex // null),
        tx_count: (.tx_count // 0),
        utxo_consumed: (.utxo_consumed // 0),
        utxo_produced: (.utxo_produced // 0),
        utxo_delta: (.utxo_delta // 0),
        timestamp: (if .ts then (.ts | todate) else null end)
      }]' 2>/dev/null || echo "[]")

      # Build decode lookup (block_no → truncated)
      DECODE_ARR="[]"
      if [ -n "$DECODE_LINES" ]; then
        DECODE_ARR=$(echo "$DECODE_LINES" | jq -s '[.[] | {block_no, truncated: (.truncated // false)}]' 2>/dev/null || echo "[]")
      fi

      # Merge: add truncated field, reverse to newest-first
      RECENT_JSON=$(jq -n --argjson j "$JOURNAL_ARR" --argjson d "$DECODE_ARR" '
        ($d | map({(.block_no | tostring): .truncated}) | add // {}) as $lookup |
        [$j[] | . + {truncated: ($lookup[(.block | tostring)] // false)}] | reverse
      ' 2>/dev/null || echo "$JOURNAL_ARR" | jq 'reverse' 2>/dev/null || echo "[]")
    else
      # Build recent array without jq (newest first)
      RECENT_JSON="["
      FIRST=true
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        R_SLOT=$(extract_num "$line" "slot")
        R_BLOCK=$(extract_num "$line" "block_no")
        R_HASH=$(extract_str "$line" "header_hash_hex")
        R_TX=$(extract_num "$line" "tx_count")
        R_CONSUMED=$(extract_num "$line" "utxo_consumed")
        R_PRODUCED=$(extract_num "$line" "utxo_produced")
        R_DELTA=$(extract_num "$line" "utxo_delta")
        R_TS=$(extract_num "$line" "ts")
        [ -z "$R_SLOT" ] && R_SLOT="null"
        [ -z "$R_BLOCK" ] && R_BLOCK="null"
        [ -z "$R_TX" ] && R_TX="0"
        [ -z "$R_CONSUMED" ] && R_CONSUMED="0"
        [ -z "$R_PRODUCED" ] && R_PRODUCED="0"
        [ -z "$R_DELTA" ] && R_DELTA="0"
        # Format hash
        if [ -n "$R_HASH" ]; then
          R_HASH_JSON="\"$R_HASH\""
        else
          R_HASH_JSON="null"
        fi
        # Format timestamp
        if [ -n "$R_TS" ] && [ "$R_TS" != "0" ]; then
          R_TS_JSON="\"$(date -u -d "@$R_TS" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "null")\""
        else
          R_TS_JSON="null"
        fi
        # Lookup truncated from decode stream
        R_TRUNC="false"
        if [ -n "$DECODE_LINES" ] && [ -n "$R_BLOCK" ] && [ "$R_BLOCK" != "null" ]; then
          DECODE_MATCH=$(echo "$DECODE_LINES" | grep "\"block_no\":${R_BLOCK}[,}]" | tail -1 || echo "")
          if [ -n "$DECODE_MATCH" ]; then
            R_TRUNC_VAL=$(extract_bool "$DECODE_MATCH" "truncated")
            [ -n "$R_TRUNC_VAL" ] && R_TRUNC="$R_TRUNC_VAL"
          fi
        fi
        if $FIRST; then
          FIRST=false
        else
          RECENT_JSON="$RECENT_JSON,"
        fi
        RECENT_JSON="$RECENT_JSON{\"slot\":$R_SLOT,\"block\":$R_BLOCK,\"block_hash\":$R_HASH_JSON,\"tx_count\":$R_TX,\"utxo_consumed\":$R_CONSUMED,\"utxo_produced\":$R_PRODUCED,\"utxo_delta\":$R_DELTA,\"truncated\":$R_TRUNC,\"timestamp\":$R_TS_JSON}"
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
  "recent": $RECENT_JSON
}
ENDJSON

echo "Written: $OUTPUT"
