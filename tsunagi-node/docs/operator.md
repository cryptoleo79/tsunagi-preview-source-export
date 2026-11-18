# Operator Guide

## Endpoints

| Endpoint | Format | Purpose | Status |
|---|---|---|---|
| /state | JSON | Full node state | Implemented |
| /status | Text | Operator summary | Implemented |
| /metrics | Prometheus | Counters and gauges | Implemented |

## Required environment variables

| Variable | Purpose |
|---|---|
| TSUNAGI_HOME | Node home directory |
| TSUNAGI_VRF_SKEY_PATH | VRF signing key |
| TSUNAGI_KES_SKEY_PATH | KES signing key |
| TSUNAGI_OPCERT_PATH | Operational certificate |
| TSUNAGI_POOL_ID_HEX | Pool ID (hex) |
| TSUNAGI_COLD_VK_HEX | Cold verification key (hex) |
| TSUNAGI_OPCERT_SIGMA_HEX | OPCERT sigma (hex) |
| TSUNAGI_OPCERT_SEQ | OPCERT sequence number |
| TSUNAGI_EPOCH_NONCE_HEX | Epoch nonce (hex, rotated per epoch) |
| TSUNAGI_KES_START_PERIOD | KES start period (must match opcert) |
| TSUNAGI_STAKE_FRACTION_X1E9 | Pool stake fraction × 1e9 |

## Tuning variables

| Variable | Default | Purpose |
|---|---|---|
| TSUNAGI_PROTOCOL_MAJOR | 10 | Protocol version major |
| TSUNAGI_PROTOCOL_MINOR | 2 | Protocol version minor |
| TSUNAGI_KES_MAX_PERIODS | 64 | Sum6Kes max evolutions |
| TSUNAGI_PRAOS_ENABLE | 1 | Enable Praos checks |
| TSUNAGI_METRICS_PORT | 9081 | Metrics listen port |

## Running

### Node

```
tsunagi-node run --net preview --lang en
```

### Propagation server

```
tsunagi-node propagate-serve \
  --net preview \
  --artifact-dir <path> \
  --allowlist <ip> \
  --port 3033
```

Do not restart propagate-serve while a relay connection is in
LIVE_PUSH state.

### Forge watcher

```
TSUNAGI_HOME=~/tsunagi-home-preview \
  bash scripts/strict-forge-watch.sh \
  >> ~/tsunagi-home-preview/logs/strict-forge-watch.log 2>&1 &
```

## Epoch nonce rotation

Preview epochs are 86400 slots (1 day). Query current nonce:

```
# Replace 1248 with the current epoch number
curl -sf "https://preview.koios.rest/api/v1/epoch_params?_epoch_no=1248" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['nonce'])"
```

Update TSUNAGI_EPOCH_NONCE_HEX and restart the service.

## Failure diagnosis

```
grep -E 'LOOP_EXIT_TRUTH|LIVE_PUSH_SEND|bf_rx|bf_tx|served_block' <logfile>
```

| Signal | Meaning | Next step |
|---|---|---|
| bf_rx=0 | Relay did not initiate BlockFetch | Check header validity (VRF/KES), consensus eligibility (threshold, nonce), and ChainSync progression |
| bf_tx=0, bf_rx>0 | Server couldn't serve block | Check block availability |
| served_block=false, bf_tx>0 | Sent but not confirmed | Check encoding |

Standalone verifiers:

```
cd src/producer/crypto
./verify_vrf
./verify_forged
```
