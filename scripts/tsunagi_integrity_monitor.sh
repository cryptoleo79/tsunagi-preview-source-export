#!/usr/bin/env bash
set -euo pipefail

# Tsunagi Integrity Monitor — operator-level drift and stall detection.
# Polls /status on mainnet, preview, and sancho every 60 seconds.
# Read-only monitoring. No runtime modification.

NETS=("mainnet:9080" "preview:9081" "sancho:9082")
OUTDIR="${TSUNAGI_INTEGRITY_DIR:-$HOME/tsunagi-integrity}"
LOG="$OUTDIR/integrity.log"

mkdir -p "$OUTDIR"

echo "=== TSUNAGI INTEGRITY MONITOR STARTED ===" >> "$LOG"
echo "UTC $(date -u)" >> "$LOG"
echo >> "$LOG"

declare -A LAST_DIGEST
declare -A LAST_SLOT
declare -A LAST_STABLE
declare -A LAST_SLOT_TIME

while true; do
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  NOW_EPOCH="$(date +%s)"

  for entry in "${NETS[@]}"; do
    IFS=":" read -r net port <<< "$entry"

    STATUS_JSON="$(curl -s "http://127.0.0.1:${port}/status" || true)"
    if [ -z "$STATUS_JSON" ]; then
      echo "$NOW [$net] ERROR: no /status response" >> "$LOG"
      continue
    fi

    digest="$(echo "$STATUS_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["digest"])')"
    slot="$(echo "$STATUS_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["slot"])')"
    stable="$(echo "$STATUS_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["header_stable"])')"

    # Digest drift check
    if [[ -n "${LAST_DIGEST[$net]:-}" && "${LAST_DIGEST[$net]}" != "$digest" ]]; then
      echo "$NOW [$net] INFO: digest changed (normal chain progress)" >> "$LOG"
    fi

    # Slot stall detection (>120s)
    if [[ -n "${LAST_SLOT[$net]:-}" && "${LAST_SLOT[$net]}" == "$slot" ]]; then
      last_time="${LAST_SLOT_TIME[$net]:-0}"
      delta=$((NOW_EPOCH - last_time))
      if (( delta > 120 )); then
        echo "$NOW [$net] WARNING: slot stalled for ${delta}s (slot=$slot)" >> "$LOG"
      fi
    else
      LAST_SLOT_TIME[$net]="$NOW_EPOCH"
    fi

    # header_stable drop detection
    if [[ -n "${LAST_STABLE[$net]:-}" && "${LAST_STABLE[$net]}" == "1" && "$stable" == "0" ]]; then
      echo "$NOW [$net] WARNING: header_stable dropped to 0" >> "$LOG"
    fi

    LAST_DIGEST[$net]="$digest"
    LAST_SLOT[$net]="$slot"
    LAST_STABLE[$net]="$stable"
  done

  sleep 60
done
