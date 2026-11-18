#!/usr/bin/env bash
# -----------------------------------------------------------------
# generate-health-json.sh
# Generates health.json from existing TSUNAGI JSON endpoints.
#
# Computes a composite health score and per-component scores
# from existing observability data. Scoring logic mirrors
# src/net/health/health_engine.zig (canonical reference).
#
# Data sources (all pre-generated JSON files):
#   operator.json          → blocks_processed, rollbacks
#   network.json           → connect_count, disconnect_count
#   slot-observatory.json  → avg_gap
#   confirmation.json      → pending_count, recent_confirmed[].confirmation_seconds
#
# Usage:
#   ./scripts/generate-health-json.sh [output-path]
#
# Environment:
#   TSUNAGI_WEB     -- web root where JSON files are served (default: /var/www/tsunagi)
#   TSUNAGI_NETWORK -- network name (default: preview)
#
# Scoring reference:
#   All scoring uses integer arithmetic only. Weights:
#   peer 25%, slot 20%, block 25%, confirmation 15%, mempool 15%.
#   State: >=90 excellent, >=75 healthy, >=60 degraded, <60 critical.
#   Missing data yields neutral score (80) per component.
# -----------------------------------------------------------------
set -euo pipefail

TSUNAGI_WEB="${TSUNAGI_WEB:-/var/www/tsunagi}"
NETWORK="${TSUNAGI_NETWORK:-preview}"
OUTPUT="${1:-health.json}"
NEUTRAL=80

# -- jq detection --
HAS_JQ=false
if command -v jq &>/dev/null; then
  HAS_JQ=true
fi

# -- Portable JSON extraction --
extract_num() {
  echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p" | head -1
}
extract_float() {
  echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9][0-9]*\.\{0,1\}[0-9]*\).*/\1/p" | head -1
}

# -- Read source JSON files --
read_json() {
  local f="$TSUNAGI_WEB/$1"
  if [ -f "$f" ]; then
    cat "$f"
  else
    echo "{}"
  fi
}

OPERATOR_JSON=$(read_json "operator.json")
NETWORK_JSON=$(read_json "network.json")
SLOT_JSON=$(read_json "slot-observatory.json")
CONFIRM_JSON=$(read_json "confirmation.json")

# -- Extract inputs --

# Network: connect_count, disconnect_count
if $HAS_JQ; then
  CONNECT_COUNT=$(echo "$NETWORK_JSON" | jq -r '.connect_count // 0' 2>/dev/null || echo "0")
  DISCONNECT_COUNT=$(echo "$NETWORK_JSON" | jq -r '.disconnect_count // 0' 2>/dev/null || echo "0")
else
  CONNECT_COUNT=$(extract_num "$NETWORK_JSON" "connect_count")
  DISCONNECT_COUNT=$(extract_num "$NETWORK_JSON" "disconnect_count")
fi
CONNECT_COUNT="${CONNECT_COUNT:-0}"
DISCONNECT_COUNT="${DISCONNECT_COUNT:-0}"

# Slot: avg_gap → avg_gap_x10 (multiply by 10, truncate to integer)
AVG_GAP_X10=""
if $HAS_JQ; then
  AVG_GAP_RAW=$(echo "$SLOT_JSON" | jq -r 'if .avg_gap != null then .avg_gap else "null" end' 2>/dev/null || echo "null")
else
  AVG_GAP_RAW=$(extract_float "$SLOT_JSON" "avg_gap")
  [ -z "$AVG_GAP_RAW" ] && AVG_GAP_RAW="null"
fi
if [ "$AVG_GAP_RAW" != "null" ] && [ -n "$AVG_GAP_RAW" ]; then
  # Multiply by 10 and truncate. Handle both int and float.
  # Shell note: uses awk for float-to-int conversion.
  AVG_GAP_X10=$(echo "$AVG_GAP_RAW" | awk '{printf "%d", $1 * 10}' 2>/dev/null || echo "")
fi

# Block: blocks_processed, rollbacks
if $HAS_JQ; then
  BLOCKS_PROCESSED=$(echo "$OPERATOR_JSON" | jq -r '.pipeline.blocks_processed // 0' 2>/dev/null || echo "0")
  ROLLBACKS=$(echo "$OPERATOR_JSON" | jq -r '.pipeline.rollbacks // 0' 2>/dev/null || echo "0")
else
  BLOCKS_PROCESSED=$(extract_num "$OPERATOR_JSON" "blocks_processed")
  ROLLBACKS=$(extract_num "$OPERATOR_JSON" "rollbacks")
fi
BLOCKS_PROCESSED="${BLOCKS_PROCESSED:-0}"
ROLLBACKS="${ROLLBACKS:-0}"

# Confirmation: avg_confirmation_seconds (computed from recent_confirmed)
AVG_CONFIRM=""
if $HAS_JQ; then
  AVG_CONFIRM=$(echo "$CONFIRM_JSON" | jq -r '
    [.recent_confirmed[]? | .confirmation_seconds // empty]
    | if length > 0 then (add / length | floor) else "null" end
  ' 2>/dev/null || echo "null")
  [ "$AVG_CONFIRM" = "null" ] && AVG_CONFIRM=""
else
  # sed fallback: extract confirmation_seconds from each entry, compute average
  CONF_SUM=0
  CONF_CNT=0
  CONF_LINES=$(echo "$CONFIRM_JSON" | tr '},{' '\n' | grep "confirmation_seconds" || echo "")
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    VAL=$(echo "$line" | sed -n 's/.*"confirmation_seconds"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    if [ -n "$VAL" ]; then
      CONF_SUM=$((CONF_SUM + VAL))
      CONF_CNT=$((CONF_CNT + 1))
    fi
  done <<< "$CONF_LINES"
  if [ "$CONF_CNT" -gt 0 ]; then
    AVG_CONFIRM=$((CONF_SUM / CONF_CNT))
  fi
fi

# Mempool pressure: pending_count from confirmation.json
if $HAS_JQ; then
  MEMPOOL_PENDING=$(echo "$CONFIRM_JSON" | jq -r '.pending_count // 0' 2>/dev/null || echo "0")
else
  MEMPOOL_PENDING=$(extract_num "$CONFIRM_JSON" "pending_count")
fi
MEMPOOL_PENDING="${MEMPOOL_PENDING:-0}"

# ---------------------------------------------------------------
# Scoring functions — mirrors health_engine.zig exactly
# All integer arithmetic.
# ---------------------------------------------------------------

# A. Peer score
compute_peer_score() {
  local conn="$CONNECT_COUNT"
  local disc="$DISCONNECT_COUNT"
  if [ "$conn" -eq 0 ] && [ "$disc" -eq 0 ]; then
    echo "$NEUTRAL"
    return
  fi
  if [ "$disc" -eq 0 ] && [ "$conn" -gt 0 ]; then
    echo "100"
    return
  fi
  local denom="$conn"
  [ "$denom" -eq 0 ] && denom=1
  local rate=$(( disc * 100 / denom ))
  if [ "$rate" -ge 100 ]; then
    echo "30"
    return
  fi
  echo $(( 100 - (rate * 70) / 100 ))
}

# B. Slot score
compute_slot_score() {
  if [ -z "$AVG_GAP_X10" ]; then
    echo "$NEUTRAL"
    return
  fi
  local g="$AVG_GAP_X10"
  if [ "$g" -le 30 ]; then
    echo "100"
    return
  fi
  if [ "$g" -le 100 ]; then
    local offset=$((g - 30))
    echo $(( 100 - (offset * 30) / 70 ))
    return
  fi
  if [ "$g" -le 300 ]; then
    local offset=$((g - 100))
    echo $(( 70 - (offset * 30) / 200 ))
    return
  fi
  echo "40"
}

# C. Block score
compute_block_score() {
  local bp="$BLOCKS_PROCESSED"
  local rb="$ROLLBACKS"
  if [ "$bp" -eq 0 ]; then
    echo "$NEUTRAL"
    return
  fi
  if [ "$rb" -eq 0 ]; then
    echo "100"
    return
  fi
  local bp_capped="$bp"
  [ "$bp_capped" -gt 1000000 ] && bp_capped=1000000
  local rate=$(( rb * 10000 / bp_capped ))
  if [ "$rate" -ge 100 ]; then
    echo "40"
    return
  fi
  echo $(( 100 - (rate * 60) / 100 ))
}

# D. Confirmation score
compute_confirmation_score() {
  if [ -z "$AVG_CONFIRM" ]; then
    echo "$NEUTRAL"
    return
  fi
  local avg="$AVG_CONFIRM"
  if [ "$avg" -le 30 ]; then
    echo "100"
    return
  fi
  if [ "$avg" -le 120 ]; then
    local offset=$((avg - 30))
    echo $(( 100 - (offset * 40) / 90 ))
    return
  fi
  if [ "$avg" -le 300 ]; then
    local offset=$((avg - 120))
    echo $(( 60 - (offset * 30) / 180 ))
    return
  fi
  echo "30"
}

# E. Mempool score
compute_mempool_score() {
  local p="$MEMPOOL_PENDING"
  if [ "$p" -eq 0 ]; then
    echo "100"
    return
  fi
  if [ "$p" -le 10 ]; then
    echo "95"
    return
  fi
  if [ "$p" -le 50 ]; then
    local offset=$((p - 10))
    echo $(( 95 - (offset * 25) / 40 ))
    return
  fi
  if [ "$p" -le 200 ]; then
    local offset=$((p - 50))
    echo $(( 70 - (offset * 30) / 150 ))
    return
  fi
  echo "40"
}

# -- Compute scores --
PEER_SCORE=$(compute_peer_score)
SLOT_SCORE=$(compute_slot_score)
BLOCK_SCORE=$(compute_block_score)
CONFIRM_SCORE=$(compute_confirmation_score)
MEMPOOL_SCORE=$(compute_mempool_score)

# -- Weighted average (peer 25, slot 20, block 25, confirm 15, mempool 15) --
WEIGHTED=$(( PEER_SCORE * 25 + SLOT_SCORE * 20 + BLOCK_SCORE * 25 + CONFIRM_SCORE * 15 + MEMPOOL_SCORE * 15 ))
SCORE=$(( WEIGHTED / 100 ))

# -- State --
if [ "$SCORE" -ge 90 ]; then
  STATE="excellent"
elif [ "$SCORE" -ge 75 ]; then
  STATE="healthy"
elif [ "$SCORE" -ge 60 ]; then
  STATE="degraded"
else
  STATE="critical"
fi

# -- generated_at --
GENERATED_AT=$(date -u "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "null")

# -- Write JSON --
cat > "$OUTPUT" <<ENDJSON
{
  "network": "$NETWORK",
  "generated_at": "$GENERATED_AT",
  "score": $SCORE,
  "state": "$STATE",
  "peer_score": $PEER_SCORE,
  "slot_score": $SLOT_SCORE,
  "block_score": $BLOCK_SCORE,
  "confirmation_score": $CONFIRM_SCORE,
  "mempool_score": $MEMPOOL_SCORE
}
ENDJSON

echo "Written: $OUTPUT"
