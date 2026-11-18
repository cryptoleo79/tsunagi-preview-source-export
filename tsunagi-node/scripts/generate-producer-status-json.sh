#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# generate-producer-status-json.sh
# Generates producer-status.json from the producer-bridge CLI.
#
# This is the first generate script that invokes the tsunagi-node
# binary rather than reading journal/ndjson files directly.
# The producer-bridge command reads cursor.json, genesis config,
# and ENV vars, then evaluates offline readiness.
#
# Data sources (via producer-bridge CLI):
#   cursor.json          — chain tip (slot, block, hash)
#   shelley-genesis.json — network magic, slot length
#   ENV vars             — VRF/KES key paths, stake, pool ID
#
# Usage:
#   ./scripts/generate-producer-status-json.sh [output-path]
#
# Environment:
#   TSUNAGI_HOME       — node state directory (default: ~/tsunagi-home-preview)
#   TSUNAGI_NETWORK    — network name (default: preview)
#   TSUNAGI_BIN        — path to tsunagi-node binary (default: tsunagi-node)
#
# Exit codes from producer-bridge (all are valid states):
#   0 = READY_LOCAL_CANDIDATE
#   1 = NOT_LEADER
#   2 = NOT_CONFIGURED / IDLE
#   3 = usage error
#   4 = IO error
#   5 = internal error
# ─────────────────────────────────────────────────────────────
set -euo pipefail

TSUNAGI_HOME="${TSUNAGI_HOME:-$HOME/tsunagi-home-preview}"
NETWORK="${TSUNAGI_NETWORK:-preview}"
OUTPUT="${1:-producer-status.json}"
BINARY="${TSUNAGI_BIN:-tsunagi-node}"

# ── jq detection ──────────────────────────────────────────────
HAS_JQ=false
if command -v jq &>/dev/null; then
  HAS_JQ=true
fi

# ── Portable JSON extraction (no jq needed) ───────────────────
extract_num() {
  echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p" | head -1
}
extract_str() {
  echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}
extract_bool() {
  echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p" | head -1
}

# ── Timestamps ────────────────────────────────────────────────
GENERATED_AT=$(date -u "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")

# ── Run producer-bridge CLI ───────────────────────────────────
BRIDGE_TMP="$TSUNAGI_HOME/.producer-bridge-tmp.json"

set +e
"$BINARY" producer-bridge \
  --state-dir "$TSUNAGI_HOME" \
  --net "$NETWORK" \
  --out "$BRIDGE_TMP" 2>/dev/null
EXIT_CODE=$?
set -e

# ── Handle result ─────────────────────────────────────────────
if [ $EXIT_CODE -le 2 ] && [ -f "$BRIDGE_TMP" ]; then
  # Valid operational output (READY, NOT_LEADER, or NOT_CONFIGURED)
  BRIDGE=$(cat "$BRIDGE_TMP" 2>/dev/null || echo "")
  rm -f "$BRIDGE_TMP"

  if [ -z "$BRIDGE" ]; then
    # Empty file — treat as offline
    cat > "$OUTPUT" <<ENDJSON
{
  "network": "$NETWORK",
  "generated_at": "$GENERATED_AT",
  "bridge_state": "OFFLINE",
  "reason": "empty_output"
}
ENDJSON
    echo "Written: $OUTPUT (offline — empty output)"
    exit 0
  fi

  # ── Extract fields ──────────────────────────────────────────
  if $HAS_JQ; then
    BRIDGE_STATE=$(echo "$BRIDGE" | jq -r '.bridge_state // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
    SLOT=$(echo "$BRIDGE" | jq '.slot // null' 2>/dev/null || echo "null")
    EPOCH=$(echo "$BRIDGE" | jq '.epoch // null' 2>/dev/null || echo "null")
    SLOT_IN_EPOCH=$(echo "$BRIDGE" | jq '.slot_in_epoch // null' 2>/dev/null || echo "null")
    KES_PERIOD=$(echo "$BRIDGE" | jq '.kes_period // null' 2>/dev/null || echo "null")
    TIP_BLOCK=$(echo "$BRIDGE" | jq '.tip_block // null' 2>/dev/null || echo "null")
    TIP_HASH=$(echo "$BRIDGE" | jq -r '.tip_hash // empty' 2>/dev/null || echo "")
    LEADERSHIP=$(echo "$BRIDGE" | jq '.leadership // false' 2>/dev/null || echo "false")
    CANDIDATE_BUILT=$(echo "$BRIDGE" | jq '.candidate_built // false' 2>/dev/null || echo "false")
    HEADER_HASH=$(echo "$BRIDGE" | jq -r '.header_hash // empty' 2>/dev/null || echo "")
    BODY_HASH=$(echo "$BRIDGE" | jq -r '.body_hash // empty' 2>/dev/null || echo "")
    TX_COUNT=$(echo "$BRIDGE" | jq '.tx_count // 0' 2>/dev/null || echo "0")
    HEADER_SIZE=$(echo "$BRIDGE" | jq '.header_size_bytes // 0' 2>/dev/null || echo "0")
    BODY_SIZE=$(echo "$BRIDGE" | jq '.body_size_bytes // 0' 2>/dev/null || echo "0")
    HAS_VRF=$(echo "$BRIDGE" | jq '.source.has_vrf // false' 2>/dev/null || echo "false")
    HAS_KES=$(echo "$BRIDGE" | jq '.source.has_kes // false' 2>/dev/null || echo "false")
    HAS_POOL_ID=$(echo "$BRIDGE" | jq '.source.has_pool_id // false' 2>/dev/null || echo "false")
    HAS_STAKE=$(echo "$BRIDGE" | jq '.source.has_stake // false' 2>/dev/null || echo "false")
    STAKE_X1E9=$(echo "$BRIDGE" | jq '.source.stake_x1e9 // 0' 2>/dev/null || echo "0")
    ASC_X1E6=$(echo "$BRIDGE" | jq '.source.asc_x1e6 // 0' 2>/dev/null || echo "0")
  else
    BRIDGE_STATE=$(extract_str "$BRIDGE" "bridge_state")
    SLOT=$(extract_num "$BRIDGE" "slot")
    EPOCH=$(extract_num "$BRIDGE" "epoch")
    SLOT_IN_EPOCH=$(extract_num "$BRIDGE" "slot_in_epoch")
    KES_PERIOD=$(extract_num "$BRIDGE" "kes_period")
    TIP_BLOCK=$(extract_num "$BRIDGE" "tip_block")
    TIP_HASH=$(extract_str "$BRIDGE" "tip_hash")
    LEADERSHIP=$(extract_bool "$BRIDGE" "leadership")
    CANDIDATE_BUILT=$(extract_bool "$BRIDGE" "candidate_built")
    HEADER_HASH=$(extract_str "$BRIDGE" "header_hash")
    BODY_HASH=$(extract_str "$BRIDGE" "body_hash")
    TX_COUNT=$(extract_num "$BRIDGE" "tx_count")
    HEADER_SIZE=$(extract_num "$BRIDGE" "header_size_bytes")
    BODY_SIZE=$(extract_num "$BRIDGE" "body_size_bytes")
    HAS_VRF=$(extract_bool "$BRIDGE" "has_vrf")
    HAS_KES=$(extract_bool "$BRIDGE" "has_kes")
    HAS_POOL_ID=$(extract_bool "$BRIDGE" "has_pool_id")
    HAS_STAKE=$(extract_bool "$BRIDGE" "has_stake")
    STAKE_X1E9=$(extract_num "$BRIDGE" "stake_x1e9")
    ASC_X1E6=$(extract_num "$BRIDGE" "asc_x1e6")
  fi

  # ── Defaults ────────────────────────────────────────────────
  [ -z "$BRIDGE_STATE" ] && BRIDGE_STATE="UNKNOWN"
  [ -z "$SLOT" ] && SLOT="null"
  [ -z "$EPOCH" ] && EPOCH="null"
  [ -z "$SLOT_IN_EPOCH" ] && SLOT_IN_EPOCH="null"
  [ -z "$KES_PERIOD" ] && KES_PERIOD="null"
  [ -z "$TIP_BLOCK" ] && TIP_BLOCK="null"
  [ -z "$LEADERSHIP" ] && LEADERSHIP="false"
  [ -z "$CANDIDATE_BUILT" ] && CANDIDATE_BUILT="false"
  [ -z "$TX_COUNT" ] && TX_COUNT="0"
  [ -z "$HEADER_SIZE" ] && HEADER_SIZE="0"
  [ -z "$BODY_SIZE" ] && BODY_SIZE="0"
  [ -z "$HAS_VRF" ] && HAS_VRF="false"
  [ -z "$HAS_KES" ] && HAS_KES="false"
  [ -z "$HAS_POOL_ID" ] && HAS_POOL_ID="false"
  [ -z "$HAS_STAKE" ] && HAS_STAKE="false"
  [ -z "$STAKE_X1E9" ] && STAKE_X1E9="0"
  [ -z "$ASC_X1E6" ] && ASC_X1E6="0"

  # ── Derive reason text ─────────────────────────────────────
  REASON=""
  case "$BRIDGE_STATE" in
    READY_LOCAL_CANDIDATE) REASON="Leader for this slot, candidate block assembled" ;;
    NOT_LEADER) REASON="Valid material, not elected leader for current slot" ;;
    NOT_CONFIGURED) REASON="Missing VRF, KES, or stake configuration" ;;
    ERROR) REASON="Leader but sign/verify failed (check KES key)" ;;
    IDLE) REASON="Bridge idle" ;;
    *) REASON="Unknown state" ;;
  esac

  # ── Compute material count ─────────────────────────────────
  MATERIAL_COUNT=0
  [ "$HAS_VRF" = "true" ] && MATERIAL_COUNT=$((MATERIAL_COUNT + 1))
  [ "$HAS_KES" = "true" ] && MATERIAL_COUNT=$((MATERIAL_COUNT + 1))
  [ "$HAS_POOL_ID" = "true" ] && MATERIAL_COUNT=$((MATERIAL_COUNT + 1))
  [ "$HAS_STAKE" = "true" ] && MATERIAL_COUNT=$((MATERIAL_COUNT + 1))

  # ── Format tip_hash as JSON string or null ──────────────────
  if [ -n "$TIP_HASH" ]; then
    TIP_HASH_JSON="\"$TIP_HASH\""
  else
    TIP_HASH_JSON="null"
  fi
  if [ -n "$HEADER_HASH" ]; then
    HEADER_HASH_JSON="\"$HEADER_HASH\""
  else
    HEADER_HASH_JSON="null"
  fi
  if [ -n "$BODY_HASH" ]; then
    BODY_HASH_JSON="\"$BODY_HASH\""
  else
    BODY_HASH_JSON="null"
  fi

  # ── Write output ────────────────────────────────────────────
  cat > "$OUTPUT" <<ENDJSON
{
  "network": "$NETWORK",
  "generated_at": "$GENERATED_AT",
  "bridge_state": "$BRIDGE_STATE",
  "reason": "$REASON",
  "slot": $SLOT,
  "epoch": $EPOCH,
  "slot_in_epoch": $SLOT_IN_EPOCH,
  "kes_period": $KES_PERIOD,
  "tip_block": $TIP_BLOCK,
  "tip_hash": $TIP_HASH_JSON,
  "leadership": $LEADERSHIP,
  "candidate_built": $CANDIDATE_BUILT,
  "candidate": {
    "header_hash": $HEADER_HASH_JSON,
    "body_hash": $BODY_HASH_JSON,
    "tx_count": $TX_COUNT,
    "header_size_bytes": $HEADER_SIZE,
    "body_size_bytes": $BODY_SIZE
  },
  "material": {
    "has_vrf": $HAS_VRF,
    "has_kes": $HAS_KES,
    "has_pool_id": $HAS_POOL_ID,
    "has_stake": $HAS_STAKE,
    "material_count": $MATERIAL_COUNT,
    "stake_x1e9": $STAKE_X1E9,
    "asc_x1e6": $ASC_X1E6
  }
}
ENDJSON

  echo "Written: $OUTPUT ($BRIDGE_STATE)"

else
  # Binary not found, IO error, or usage error
  rm -f "$BRIDGE_TMP"

  REASON="binary_unavailable"
  [ $EXIT_CODE -eq 3 ] && REASON="usage_error"
  [ $EXIT_CODE -eq 4 ] && REASON="io_error"
  [ $EXIT_CODE -eq 5 ] && REASON="internal_error"

  cat > "$OUTPUT" <<ENDJSON
{
  "network": "$NETWORK",
  "generated_at": "$GENERATED_AT",
  "bridge_state": "OFFLINE",
  "reason": "$REASON",
  "slot": null,
  "epoch": null,
  "slot_in_epoch": null,
  "kes_period": null,
  "tip_block": null,
  "tip_hash": null,
  "leadership": false,
  "candidate_built": false,
  "candidate": {
    "header_hash": null,
    "body_hash": null,
    "tx_count": 0,
    "header_size_bytes": 0,
    "body_size_bytes": 0
  },
  "material": {
    "has_vrf": false,
    "has_kes": false,
    "has_pool_id": false,
    "has_stake": false,
    "material_count": 0,
    "stake_x1e9": 0,
    "asc_x1e6": 0
  }
}
ENDJSON

  echo "Written: $OUTPUT (OFFLINE — $REASON)"
fi
