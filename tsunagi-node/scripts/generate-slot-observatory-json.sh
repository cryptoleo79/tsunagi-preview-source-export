#!/usr/bin/env bash
# -----------------------------------------------------------------
# generate-slot-observatory-json.sh
# Generates slot-observatory.json from TSUNAGI slot_observatory.ndjson.
#
# Reads recent slot-level observations (block arrivals with gap
# computation). Only observed_block entries are emitted by the
# current runtime. local_candidate is deferred — the enum exists
# for forward compatibility but is not populated.
#
# Data source:
#   slot_observatory.ndjson -- per-block slot rhythm observations
#
# Usage:
#   ./scripts/generate-slot-observatory-json.sh [output-path]
#
# Environment:
#   TSUNAGI_HOME    -- node state directory (default: ~/tsunagi-home-preview)
#   TSUNAGI_NETWORK -- network name (default: preview)
# -----------------------------------------------------------------
set -euo pipefail

TSUNAGI_HOME="${TSUNAGI_HOME:-$HOME/tsunagi-home-preview}"
NETWORK="${TSUNAGI_NETWORK:-preview}"
OUTPUT="${1:-slot-observatory.json}"
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

# -- Read slot_observatory.ndjson --
SLOT_FILE="$TSUNAGI_HOME/slot_observatory.ndjson"

OBSERVATION_COUNT=0
OBSERVATIONS_JSON="[]"
LATEST_SLOT="null"
LATEST_BLOCK="null"
LATEST_GAP="null"
AVG_GAP="null"

if [ -f "$SLOT_FILE" ]; then
  OBSERVATION_COUNT=$(grep -c '"type":"slot_observation"' "$SLOT_FILE" 2>/dev/null || echo "0")
  RECENT_LINES=$(grep '"type":"slot_observation"' "$SLOT_FILE" 2>/dev/null | tail -"$RECENT_COUNT" || echo "")

  if [ -n "$RECENT_LINES" ]; then
    if $HAS_JQ; then
      OBSERVATIONS_JSON=$(echo "$RECENT_LINES" | jq -s '[.[] | {
        slot: .slot,
        block: .block,
        kind: .kind,
        gap_from_prev_block: .gap_from_prev_block,
        observed_at: (.observed_unix | todate)
      }] | reverse' 2>/dev/null || echo "[]")

      # Latest entry
      LATEST_SLOT=$(echo "$RECENT_LINES" | tail -1 | jq '.slot' 2>/dev/null || echo "null")
      LATEST_BLOCK=$(echo "$RECENT_LINES" | tail -1 | jq '.block // null' 2>/dev/null || echo "null")
      LATEST_GAP=$(echo "$RECENT_LINES" | tail -1 | jq '.gap_from_prev_block // null' 2>/dev/null || echo "null")

      # Average gap (only where gap is non-null and kind is observed_block)
      AVG_GAP=$(echo "$RECENT_LINES" | jq -s '
        [.[] | select(.kind == "observed_block" and .gap_from_prev_block != null) | .gap_from_prev_block]
        | if length > 0 then (add / length * 100 | round / 100) else null end
      ' 2>/dev/null || echo "null")
    else
      # sed fallback
      OBSERVATIONS_JSON="["
      FIRST=true
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        O_SLOT=$(extract_num "$line" "slot")
        O_BLOCK=$(extract_num "$line" "block")
        O_KIND=$(extract_str "$line" "kind")
        O_GAP=$(extract_num "$line" "gap_from_prev_block")
        O_UNIX=$(extract_num "$line" "observed_unix")

        [ -z "$O_SLOT" ] && O_SLOT="0"
        [ -z "$O_BLOCK" ] && O_BLOCK="null"
        [ -z "$O_KIND" ] && O_KIND="unknown"
        [ -z "$O_GAP" ] && O_GAP="null"

        OBSERVED_AT="null"
        if [ -n "$O_UNIX" ] && [ "$O_UNIX" != "0" ]; then
          OBSERVED_AT="\"$(date -u -d "@$O_UNIX" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")\""
        fi

        if $FIRST; then
          FIRST=false
        else
          OBSERVATIONS_JSON="$OBSERVATIONS_JSON,"
        fi
        OBSERVATIONS_JSON="$OBSERVATIONS_JSON{\"slot\":$O_SLOT,\"block\":$O_BLOCK,\"kind\":\"$O_KIND\",\"gap_from_prev_block\":$O_GAP,\"observed_at\":$OBSERVED_AT}"
      done <<< "$(echo "$RECENT_LINES" | tac)"
      OBSERVATIONS_JSON="$OBSERVATIONS_JSON]"

      # Latest entry from last line
      LAST_LINE=$(echo "$RECENT_LINES" | tail -1)
      if [ -n "$LAST_LINE" ]; then
        LATEST_SLOT=$(extract_num "$LAST_LINE" "slot")
        LATEST_BLOCK=$(extract_num "$LAST_LINE" "block")
        LATEST_GAP=$(extract_num "$LAST_LINE" "gap_from_prev_block")
        [ -z "$LATEST_SLOT" ] && LATEST_SLOT="null"
        [ -z "$LATEST_BLOCK" ] && LATEST_BLOCK="null"
        [ -z "$LATEST_GAP" ] && LATEST_GAP="null"
      fi

      # Average gap via sed (simple integer average)
      GAP_SUM=0
      GAP_COUNT=0
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        G=$(extract_num "$line" "gap_from_prev_block")
        if [ -n "$G" ]; then
          GAP_SUM=$((GAP_SUM + G))
          GAP_COUNT=$((GAP_COUNT + 1))
        fi
      done <<< "$RECENT_LINES"
      if [ "$GAP_COUNT" -gt 0 ]; then
        AVG_GAP=$((GAP_SUM / GAP_COUNT))
      fi
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
  "observation_count": $OBSERVATION_COUNT,
  "latest_slot": $LATEST_SLOT,
  "latest_block": $LATEST_BLOCK,
  "latest_gap": $LATEST_GAP,
  "avg_gap": $AVG_GAP,
  "recent_observations": $OBSERVATIONS_JSON
}
ENDJSON

echo "Written: $OUTPUT"
