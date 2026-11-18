#!/bin/bash
# ══════════════════════════════════════════════════════════════
# TSUNAGI — Epoch Nonce Auto-Update
# Queries the current preview epoch nonce from Koios and updates
# the TSUNAGI preview service if the nonce has changed.
#
# Designed to run via systemd timer every 5 minutes.
# Only restarts the service when the nonce actually changes.
# ══════════════════════════════════════════════════════════════
set -u

CONF="$HOME/.config/systemd/user/tsunagi-preview.service.d/98-epoch-stake.conf"
KOIOS_BASE="https://preview.koios.rest/api/v1"
LOG_PREFIX="NONCE_UPDATE"

# Get current epoch from Koios tip
CURRENT_EPOCH=$(curl -sS --max-time 10 "$KOIOS_BASE/tip" 2>/dev/null | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['epoch_no'])" 2>/dev/null)

if [ -z "$CURRENT_EPOCH" ]; then
    echo "$LOG_PREFIX: ERROR could not query current epoch from Koios"
    exit 1
fi

# Get nonce for current epoch
REMOTE_NONCE=$(curl -sS --max-time 10 "$KOIOS_BASE/epoch_params?_epoch_no=$CURRENT_EPOCH" 2>/dev/null | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['nonce'])" 2>/dev/null)

if [ -z "$REMOTE_NONCE" ] || [ ${#REMOTE_NONCE} -ne 64 ]; then
    echo "$LOG_PREFIX: ERROR could not query nonce for epoch $CURRENT_EPOCH (got: '${REMOTE_NONCE:-empty}')"
    exit 1
fi

# Get currently configured nonce
LOCAL_NONCE=$(grep 'TSUNAGI_EPOCH_NONCE_HEX=' "$CONF" 2>/dev/null | sed 's/.*TSUNAGI_EPOCH_NONCE_HEX=//')

if [ "$LOCAL_NONCE" = "$REMOTE_NONCE" ]; then
    echo "$LOG_PREFIX: OK epoch=$CURRENT_EPOCH nonce unchanged"
    exit 0
fi

# Nonce changed — update config and restart
echo "$LOG_PREFIX: UPDATING epoch=$CURRENT_EPOCH old=${LOCAL_NONCE:-unset} new=$REMOTE_NONCE"
sed -i "s/TSUNAGI_EPOCH_NONCE_HEX=.*/TSUNAGI_EPOCH_NONCE_HEX=$REMOTE_NONCE/" "$CONF"
systemctl --user daemon-reload
systemctl --user restart tsunagi-preview.service
sleep 3

# Verify
LOADED=$(systemctl --user show tsunagi-preview.service -p Environment --no-pager 2>/dev/null | \
    tr ' ' '\n' | grep 'TSUNAGI_EPOCH_NONCE_HEX=' | sed 's/.*=//')

if [ "$LOADED" = "$REMOTE_NONCE" ]; then
    echo "$LOG_PREFIX: SUCCESS epoch=$CURRENT_EPOCH nonce=$REMOTE_NONCE service_restarted=true"
else
    echo "$LOG_PREFIX: WARN config written but loaded nonce mismatch (loaded=$LOADED)"
fi
