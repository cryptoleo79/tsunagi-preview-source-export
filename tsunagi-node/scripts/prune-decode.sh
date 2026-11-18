#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# prune-decode.sh
# Retention tool for tx_decode.ndjson.
#
# Keeps the most recent N lines and discards the rest.
# Uses a safe temp-file-then-mv pattern to prevent corruption.
#
# Usage:
#   ./scripts/prune-decode.sh [max-lines]
#
# Environment:
#   TSUNAGI_HOME — node state directory (default: ~/tsunagi-home-preview)
#
# Default retention: 5000 lines (~5000 blocks of decode data)
# ─────────────────────────────────────────────────────────────
set -euo pipefail

TSUNAGI_HOME="${TSUNAGI_HOME:-$HOME/tsunagi-home-preview}"
MAX_LINES="${1:-5000}"
DECODE_FILE="$TSUNAGI_HOME/tx_decode.ndjson"

if [ ! -f "$DECODE_FILE" ]; then
  echo "No decode file at $DECODE_FILE — nothing to prune"
  exit 0
fi

CURRENT_LINES=$(wc -l < "$DECODE_FILE")

if [ "$CURRENT_LINES" -le "$MAX_LINES" ]; then
  echo "tx_decode.ndjson: $CURRENT_LINES lines (within $MAX_LINES limit) — no pruning needed"
  exit 0
fi

PRUNE_COUNT=$((CURRENT_LINES - MAX_LINES))

# Safe temp file in same directory (ensures same filesystem for mv)
TEMP_FILE="${DECODE_FILE}.prune.$$"

tail -"$MAX_LINES" "$DECODE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$DECODE_FILE"

echo "Pruned tx_decode.ndjson: removed $PRUNE_COUNT lines, retained $MAX_LINES (was $CURRENT_LINES)"
