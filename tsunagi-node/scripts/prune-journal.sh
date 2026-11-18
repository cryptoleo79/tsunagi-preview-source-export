#!/usr/bin/env bash
set -euo pipefail

LIMIT="${1:-10000}"
FILE="${TSUNAGI_HOME}/journal.ndjson"

[ -f "$FILE" ] || exit 0

LINES=$(wc -l < "$FILE")

if [ "$LINES" -le "$LIMIT" ]; then
  exit 0
fi

TMP="${FILE}.tmp"

tail -n "$LIMIT" "$FILE" > "$TMP"

mv "$TMP" "$FILE"

echo "pruned journal.ndjson to $LIMIT lines"
