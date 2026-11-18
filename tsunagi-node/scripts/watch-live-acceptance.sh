#!/bin/bash
# ══════════════════════════════════════════════════════════════
# TSUNAGI — Live Acceptance Watch
# Filters propagate-serve output to show only acceptance trace lines.
# Usage:
#   ./scripts/watch-live-acceptance.sh                  # tail journal
#   ./scripts/watch-live-acceptance.sh /path/to/log     # tail file
# ══════════════════════════════════════════════════════════════
set -u

FILTER='ACCEPTANCE_CONN_TRUTH|ACCEPTANCE_POSITION_TRUTH|ACCEPTANCE_INTERSECT_TRUTH|ACCEPTANCE_RESULT_TRUTH|ACCEPTANCE_BLOCKFETCH|CHAIN_POSITION|MsgRequestNext|MsgRollBackward|MsgRollForward|BlockFetch|ARTIFACT_COHERENCE_TRUTH|ARTIFACT_READY_TRUTH|FORGE_PROMOTE_FRAGMENT|SCHEDULED_LEADER'

if [ "${1:-}" != "" ] && [ -f "$1" ]; then
    echo "Watching file: $1"
    tail -f "$1" | grep --line-buffered -E "$FILTER"
else
    echo "Watching journal: tsunagi-preview.service"
    journalctl --user -u tsunagi-preview.service -f --no-pager 2>/dev/null | grep --line-buffered -E "$FILTER"
fi
