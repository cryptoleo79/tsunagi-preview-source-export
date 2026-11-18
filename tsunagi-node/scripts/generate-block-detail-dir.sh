#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# generate-block-detail-dir.sh
# Generates static per-block detail JSON files from journal.
#
# Reads the most recent roll_forward events and writes one
# JSON file per block into a target directory.
#
# Usage:
#   ./scripts/generate-block-detail-dir.sh [output-dir]
#
# Environment:
#   TSUNAGI_HOME    — node state directory (default: ~/tsunagi-home-preview)
#   TSUNAGI_NETWORK — network name (default: preview)
# ─────────────────────────────────────────────────────────────
set -euo pipefail

TSUNAGI_HOME="${TSUNAGI_HOME:-$HOME/tsunagi-home-preview}"
NETWORK="${TSUNAGI_NETWORK:-preview}"
OUTPUT_DIR="${1:-block-detail}"
RECENT_COUNT=50
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$OUTPUT_DIR"

JOURNAL_FILE="$TSUNAGI_HOME/journal.ndjson"

if [ ! -f "$JOURNAL_FILE" ]; then
  echo "Warning: journal not found at $JOURNAL_FILE" >&2
  exit 0
fi

RECENT_LINES=$(grep '"type":"roll_forward"' "$JOURNAL_FILE" 2>/dev/null | tail -"$RECENT_COUNT" || echo "")

if [ -z "$RECENT_LINES" ]; then
  echo "No recent roll_forward events found"
  exit 0
fi

COUNT=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  # Extract block_no to determine filename
  BLOCK_NO=$(echo "$line" | sed -n 's/.*"block_no"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
  [ -z "$BLOCK_NO" ] && continue

  TSUNAGI_HOME="$TSUNAGI_HOME" TSUNAGI_NETWORK="$NETWORK" \
    "$SCRIPT_DIR/generate-block-detail-json.sh" "$BLOCK_NO" "$OUTPUT_DIR/${BLOCK_NO}.json" 2>/dev/null || continue
  COUNT=$((COUNT + 1))
done <<< "$RECENT_LINES"

echo "Generated $COUNT block detail files in $OUTPUT_DIR/"
