#!/bin/bash
# ══════════════════════════════════════════════════════════════
# TSUNAGI — Show Latest Acceptance Receipt
# Reads and pretty-prints the most recent acceptance receipt.
# Usage:
#   ./scripts/show-latest-acceptance-receipt.sh
#   ./scripts/show-latest-acceptance-receipt.sh /path/to/propagation_artifact
# ══════════════════════════════════════════════════════════════
set -u

ART_DIR="${1:-${TSUNAGI_HOME:-$HOME/tsunagi-home-preview}/propagation_artifact}"
RECEIPT="$ART_DIR/acceptance_receipt.json"

if [ ! -f "$RECEIPT" ]; then
    echo "No acceptance receipt found at: $RECEIPT"
    exit 1
fi

echo "Receipt: $RECEIPT"
echo "Modified: $(stat --format='%y' "$RECEIPT" 2>/dev/null || stat -f '%Sm' "$RECEIPT" 2>/dev/null)"
echo "---"

if command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool "$RECEIPT"
elif command -v jq >/dev/null 2>&1; then
    jq . "$RECEIPT"
else
    cat "$RECEIPT"
fi

echo ""
echo "=== Quick Summary ==="
python3 -c "
import json, sys
try:
    d = json.load(open('$RECEIPT'))
    print(f'  connection_id:    {d.get(\"connection_id\", \"?\")}')
    print(f'  peer:             {d.get(\"peer_ip\", \"?\")}')
    print(f'  relay_ahead:      {d.get(\"relay_ahead\", \"?\")}')
    print(f'  intersect_found:  {d.get(\"intersect_result_found\", \"?\")}')
    print(f'  request_next_rx:  {d.get(\"msg_request_next_rx_total\", \"?\")}')
    print(f'  rollback_tx:      {d.get(\"rollback_tx_total\", \"?\")}')
    print(f'  rollforward_frag: {d.get(\"rollforward_fragment_tx_total\", \"?\")}')
    print(f'  rollforward_seal: {d.get(\"rollforward_sealed_tx_total\", \"?\")}')
    print(f'  blockfetch_rx:    {d.get(\"blockfetch_rx_total\", \"?\")}')
    print(f'  served_header:    {d.get(\"served_header\", \"?\")}')
    print(f'  served_block:     {d.get(\"served_block\", \"?\")}')
    print(f'  exit_reason:      {d.get(\"loop_exit_reason\", \"?\")}')
    # Milestone check
    rn = d.get('msg_request_next_rx_total', 0)
    rb = d.get('rollback_tx_total', 0)
    rf = d.get('rollforward_sealed_tx_total', 0)
    bf = d.get('blockfetch_rx_total', 0)
    if bf > 0:
        print('  >> MILESTONE: BlockFetch reached')
    elif rf > 0:
        print('  >> MILESTONE: Sealed RollForward sent')
    elif rb > 0:
        print('  >> MILESTONE: RollBackward sent')
    elif rn > 0:
        print('  >> MILESTONE: MsgRequestNext received')
    else:
        print('  >> STATUS: Disconnected before MsgRequestNext')
except Exception as e:
    print(f'  (parse error: {e})')
" 2>/dev/null || true
