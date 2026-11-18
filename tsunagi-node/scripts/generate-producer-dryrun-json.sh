#!/usr/bin/env bash
# -----------------------------------------------------------------
# generate-producer-dryrun-json.sh
# Generates producer-dryrun.json from runtime dry-run output.
#
# Reads the bounded overwrite file written by the producer dry-run
# engine (producer-dryrun-last.json). This file contains the most
# recent DryRunEvent — one JSON object per slot evaluation.
#
# Summary fields reflect ONLY the last event. No historical counting.
# If the source file is missing, emits an enabled:false stub.
#
# Data source:
#   producer-dryrun-last.json — single overwrite file from runtime
#
# Usage:
#   ./scripts/generate-producer-dryrun-json.sh [output-path]
#
# Environment:
#   TSUNAGI_HOME    -- node state directory (default: ~/tsunagi-home-preview)
#   TSUNAGI_NETWORK -- network name (default: preview)
# -----------------------------------------------------------------
set -euo pipefail

TSUNAGI_HOME="${TSUNAGI_HOME:-$HOME/tsunagi-home-preview}"
NETWORK="${TSUNAGI_NETWORK:-preview}"
OUTPUT="${1:-producer-dryrun.json}"

# -- jq detection --
HAS_JQ=false
if command -v jq &>/dev/null; then
  HAS_JQ=true
fi

# -- Portable JSON extraction (no jq needed) --
extract_num() {
  echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p" | head -1
}
extract_str() {
  echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}
extract_bool() {
  echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p" | head -1
}

# -- generated_at --
GENERATED_AT=$(date -u "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "null")

# -- Read source file --
DRYRUN_FILE="$TSUNAGI_HOME/producer-dryrun-last.json"

if [ ! -f "$DRYRUN_FILE" ]; then
  # No dry-run output — emit disabled stub
  cat > "$OUTPUT" <<ENDJSON
{
  "network": "$NETWORK",
  "generated_at": "$GENERATED_AT",
  "enabled": false,
  "last": {
    "slot": null,
    "epoch": null,
    "slot_in_epoch": null,
    "block_no": null,
    "state": null,
    "leadership": null,
    "candidate_built": null,
    "candidate_valid": null,
    "validation_state": null,
    "header_hash": null,
    "body_hash": null,
    "timestamp_unix": null
  },
  "summary": {
    "seen_last": false,
    "candidate_ready": 0,
    "candidate_invalid": 0,
    "candidate_failed": 0,
    "not_leader": 0,
    "not_configured": 0
  }
}
ENDJSON
  echo "Written: $OUTPUT (dry-run disabled / no source file)"
  exit 0
fi

# -- Source file exists — extract fields --
DRYRUN=$(cat "$DRYRUN_FILE" 2>/dev/null || echo "")

if [ -z "$DRYRUN" ]; then
  # Empty file — treat as disabled
  cat > "$OUTPUT" <<ENDJSON
{
  "network": "$NETWORK",
  "generated_at": "$GENERATED_AT",
  "enabled": false,
  "last": {
    "slot": null,
    "epoch": null,
    "slot_in_epoch": null,
    "block_no": null,
    "state": null,
    "leadership": null,
    "candidate_built": null,
    "candidate_valid": null,
    "validation_state": null,
    "header_hash": null,
    "body_hash": null,
    "timestamp_unix": null
  },
  "summary": {
    "seen_last": false,
    "candidate_ready": 0,
    "candidate_invalid": 0,
    "candidate_failed": 0,
    "not_leader": 0,
    "not_configured": 0
  }
}
ENDJSON
  echo "Written: $OUTPUT (dry-run file empty)"
  exit 0
fi

# -- Extract last event fields --
if $HAS_JQ; then
  SLOT=$(echo "$DRYRUN" | jq -r '.slot // "null"' 2>/dev/null || echo "null")
  EPOCH=$(echo "$DRYRUN" | jq -r '.epoch // "null"' 2>/dev/null || echo "null")
  SLOT_IN_EPOCH=$(echo "$DRYRUN" | jq -r '.slot_in_epoch // "null"' 2>/dev/null || echo "null")
  BLOCK_NO=$(echo "$DRYRUN" | jq -r '.block_no // "null"' 2>/dev/null || echo "null")
  STATE=$(echo "$DRYRUN" | jq -r '.state // "null"' 2>/dev/null || echo "null")
  LEADERSHIP=$(echo "$DRYRUN" | jq -r 'if .leadership == null then "null" else (.leadership | tostring) end' 2>/dev/null || echo "null")
  CANDIDATE_BUILT=$(echo "$DRYRUN" | jq -r 'if .candidate_built == null then "null" else (.candidate_built | tostring) end' 2>/dev/null || echo "null")
  CANDIDATE_VALID=$(echo "$DRYRUN" | jq -r 'if .candidate_valid == null then "null" else (.candidate_valid | tostring) end' 2>/dev/null || echo "null")
  VALIDATION_STATE=$(echo "$DRYRUN" | jq -r '.validation_state // "null"' 2>/dev/null || echo "null")
  HEADER_HASH=$(echo "$DRYRUN" | jq -r '.header_hash // "null"' 2>/dev/null || echo "null")
  BODY_HASH=$(echo "$DRYRUN" | jq -r '.body_hash // "null"' 2>/dev/null || echo "null")
  TIMESTAMP_UNIX=$(echo "$DRYRUN" | jq -r '.timestamp_unix // "null"' 2>/dev/null || echo "null")
else
  SLOT=$(extract_num "$DRYRUN" "slot")
  EPOCH=$(extract_num "$DRYRUN" "epoch")
  SLOT_IN_EPOCH=$(extract_num "$DRYRUN" "slot_in_epoch")
  BLOCK_NO=$(extract_num "$DRYRUN" "block_no")
  STATE=$(extract_str "$DRYRUN" "state")
  LEADERSHIP=$(extract_bool "$DRYRUN" "leadership")
  CANDIDATE_BUILT=$(extract_bool "$DRYRUN" "candidate_built")
  CANDIDATE_VALID=$(extract_bool "$DRYRUN" "candidate_valid")
  VALIDATION_STATE=$(extract_str "$DRYRUN" "validation_state")
  HEADER_HASH=$(extract_str "$DRYRUN" "header_hash")
  BODY_HASH=$(extract_str "$DRYRUN" "body_hash")
  TIMESTAMP_UNIX=$(extract_num "$DRYRUN" "timestamp_unix")
fi

# -- Defaults for missing fields --
[ -z "$SLOT" ] && SLOT="null"
[ -z "$EPOCH" ] && EPOCH="null"
[ -z "$SLOT_IN_EPOCH" ] && SLOT_IN_EPOCH="null"
[ -z "$BLOCK_NO" ] && BLOCK_NO="null"
[ -z "$STATE" ] && STATE="null"
[ -z "$LEADERSHIP" ] && LEADERSHIP="null"
[ -z "$CANDIDATE_BUILT" ] && CANDIDATE_BUILT="null"
[ -z "$CANDIDATE_VALID" ] && CANDIDATE_VALID="null"
[ -z "$VALIDATION_STATE" ] && VALIDATION_STATE="null"
[ -z "$HEADER_HASH" ] && HEADER_HASH="null"
[ -z "$BODY_HASH" ] && BODY_HASH="null"
[ -z "$TIMESTAMP_UNIX" ] && TIMESTAMP_UNIX="null"

# -- Format state/validation_state as quoted strings or null --
if [ "$STATE" != "null" ]; then
  STATE_JSON="\"$STATE\""
else
  STATE_JSON="null"
fi
if [ "$VALIDATION_STATE" != "null" ]; then
  VS_JSON="\"$VALIDATION_STATE\""
else
  VS_JSON="null"
fi
if [ "$HEADER_HASH" != "null" ]; then
  HH_JSON="\"$HEADER_HASH\""
else
  HH_JSON="null"
fi
if [ "$BODY_HASH" != "null" ]; then
  BH_JSON="\"$BODY_HASH\""
else
  BH_JSON="null"
fi

# -- Summary: single-event counts (0 or 1 based on last state) --
S_CANDIDATE_READY=0
S_CANDIDATE_INVALID=0
S_CANDIDATE_FAILED=0
S_NOT_LEADER=0
S_NOT_CONFIGURED=0

case "$STATE" in
  CANDIDATE_READY)   S_CANDIDATE_READY=1 ;;
  CANDIDATE_INVALID) S_CANDIDATE_INVALID=1 ;;
  CANDIDATE_FAILED)  S_CANDIDATE_FAILED=1 ;;
  NOT_LEADER)        S_NOT_LEADER=1 ;;
  NOT_CONFIGURED)    S_NOT_CONFIGURED=1 ;;
esac

# -- Write JSON --
cat > "$OUTPUT" <<ENDJSON
{
  "network": "$NETWORK",
  "generated_at": "$GENERATED_AT",
  "enabled": true,
  "last": {
    "slot": $SLOT,
    "epoch": $EPOCH,
    "slot_in_epoch": $SLOT_IN_EPOCH,
    "block_no": $BLOCK_NO,
    "state": $STATE_JSON,
    "leadership": $LEADERSHIP,
    "candidate_built": $CANDIDATE_BUILT,
    "candidate_valid": $CANDIDATE_VALID,
    "validation_state": $VS_JSON,
    "header_hash": $HH_JSON,
    "body_hash": $BH_JSON,
    "timestamp_unix": $TIMESTAMP_UNIX
  },
  "summary": {
    "seen_last": true,
    "candidate_ready": $S_CANDIDATE_READY,
    "candidate_invalid": $S_CANDIDATE_INVALID,
    "candidate_failed": $S_CANDIDATE_FAILED,
    "not_leader": $S_NOT_LEADER,
    "not_configured": $S_NOT_CONFIGURED
  }
}
ENDJSON

echo "Written: $OUTPUT"
