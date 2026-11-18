#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# generate-recent-blocks-json.sh
# Generates recent-blocks.json from TSUNAGI /chain/recent endpoint.
#
# Data source: http://127.0.0.1:{port}/chain/recent
# Output: recent-blocks.json with 50 most recent blocks (newest-first)
#
# Usage:
#   ./scripts/generate-recent-blocks-json.sh [output-path]
#
# Environment:
#   TSUNAGI_METRICS_PORT — metrics port (default: 8081)
#   TSUNAGI_NETWORK      — network name (default: preview)
# ─────────────────────────────────────────────────────────────
set -euo pipefail

METRICS_PORT="${TSUNAGI_METRICS_PORT:-8081}"
NETWORK="${TSUNAGI_NETWORK:-preview}"
OUTPUT="${1:-recent-blocks.json}"
GENERATED_AT=$(date -u "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "null")

DATA=$(curl -sf --max-time 5 "http://127.0.0.1:${METRICS_PORT}/chain/recent" 2>/dev/null) || DATA=""

if [ -z "$DATA" ]; then
  cat > "$OUTPUT" <<ENDJSON
{
  "network": "$NETWORK",
  "generated_at": "$GENERATED_AT",
  "count": 0,
  "recent": []
}
ENDJSON
  echo "Written: $OUTPUT (endpoint unreachable)"
  exit 0
fi

# Wrap with network + generated_at
if command -v jq &>/dev/null; then
  echo "$DATA" | jq --arg net "$NETWORK" --arg gen "$GENERATED_AT" \
    '. + {network: $net, generated_at: $gen}' > "$OUTPUT"
else
  # Inject network + generated_at into existing JSON
  echo "$DATA" | sed "s/^{/{\"network\":\"$NETWORK\",\"generated_at\":\"$GENERATED_AT\",/" > "$OUTPUT"
fi

echo "Written: $OUTPUT"
