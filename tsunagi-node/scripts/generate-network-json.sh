#!/usr/bin/env bash
# -----------------------------------------------------------------
# generate-network-json.sh
# Generates network.json from TSUNAGI peer_observatory.ndjson.
#
# Reads recent peer/network events (connect, disconnect, block
# received). Only events actually emitted by the runtime are
# included. tx_seen is not emitted and not counted.
#
# Data source:
#   peer_observatory.ndjson -- per-event peer/network observations
#
# Usage:
#   ./scripts/generate-network-json.sh [output-path]
#
# Environment:
#   TSUNAGI_HOME    -- node state directory (default: ~/tsunagi-home-preview)
#   TSUNAGI_NETWORK -- network name (default: preview)
# -----------------------------------------------------------------
set -euo pipefail

TSUNAGI_HOME="${TSUNAGI_HOME:-$HOME/tsunagi-home-preview}"
NETWORK="${TSUNAGI_NETWORK:-preview}"
OUTPUT="${1:-network.json}"
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

# -- Read peer_observatory.ndjson --
PEER_FILE="$TSUNAGI_HOME/peer_observatory.ndjson"

EVENT_COUNT=0
CONNECT_COUNT=0
DISCONNECT_COUNT=0
BLOCK_EVENT_COUNT=0
EVENTS_JSON="[]"

if [ -f "$PEER_FILE" ]; then
  EVENT_COUNT=$(grep -c '"type":"peer_event"' "$PEER_FILE" 2>/dev/null || echo "0")
  CONNECT_COUNT=$(grep -c '"event":"peer_connect"' "$PEER_FILE" 2>/dev/null || echo "0")
  DISCONNECT_COUNT=$(grep -c '"event":"peer_disconnect"' "$PEER_FILE" 2>/dev/null || echo "0")
  BLOCK_EVENT_COUNT=$(grep -c '"event":"block_received"' "$PEER_FILE" 2>/dev/null || echo "0")

  RECENT_LINES=$(grep '"type":"peer_event"' "$PEER_FILE" 2>/dev/null | tail -"$RECENT_COUNT" || echo "")

  if [ -n "$RECENT_LINES" ]; then
    if $HAS_JQ; then
      EVENTS_JSON=$(echo "$RECENT_LINES" | jq -s '[.[] | {
        peer: .peer,
        event: .event,
        slot: .slot,
        block: .block,
        latency_ms: .latency_ms,
        reason: .reason,
        timestamp: (.ts | todate)
      }] | reverse' 2>/dev/null || echo "[]")
    else
      EVENTS_JSON="["
      FIRST=true
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        E_PEER=$(extract_str "$line" "peer")
        E_EVENT=$(extract_str "$line" "event")
        E_SLOT=$(extract_num "$line" "slot")
        E_BLOCK=$(extract_num "$line" "block")
        E_LAT=$(extract_num "$line" "latency_ms")
        E_REASON=$(extract_str "$line" "reason")
        E_TS=$(extract_num "$line" "ts")

        [ -z "$E_PEER" ] && E_PEER="unknown"
        [ -z "$E_EVENT" ] && E_EVENT="unknown"
        [ -z "$E_SLOT" ] && E_SLOT="null"
        [ -z "$E_BLOCK" ] && E_BLOCK="null"
        [ -z "$E_LAT" ] && E_LAT="null"

        REASON_JSON="null"
        if [ -n "$E_REASON" ]; then
          REASON_JSON="\"$E_REASON\""
        fi

        TIMESTAMP="null"
        if [ -n "$E_TS" ] && [ "$E_TS" != "0" ]; then
          TIMESTAMP="\"$(date -u -d "@$E_TS" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")\""
        fi

        if $FIRST; then
          FIRST=false
        else
          EVENTS_JSON="$EVENTS_JSON,"
        fi
        EVENTS_JSON="$EVENTS_JSON{\"peer\":\"$E_PEER\",\"event\":\"$E_EVENT\",\"slot\":$E_SLOT,\"block\":$E_BLOCK,\"latency_ms\":$E_LAT,\"reason\":$REASON_JSON,\"timestamp\":$TIMESTAMP}"
      done <<< "$(echo "$RECENT_LINES" | tac)"
      EVENTS_JSON="$EVENTS_JSON]"
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
  "event_count": $EVENT_COUNT,
  "connect_count": $CONNECT_COUNT,
  "disconnect_count": $DISCONNECT_COUNT,
  "block_event_count": $BLOCK_EVENT_COUNT,
  "recent_events": $EVENTS_JSON
}
ENDJSON

echo "Written: $OUTPUT"
