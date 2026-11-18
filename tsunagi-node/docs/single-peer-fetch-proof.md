# Single-Peer Fetch-Proof Isolation Runbook

**Version:** v4.5.22
**Purpose:** Prove whether relay sends MsgRequestRange to TSUNAGI when TSUNAGI is the only local-root candidate.
**Scope:** Preview network only. Temporary topology change. Restore after test.

---

## A) Why current tests are noisy

v4.5.21 proved TSUNAGI advertises a strictly-ahead candidate:

```
candidate: ... tsunagi_ahead=true equal_tip=false strictly_ahead=true
```

Yet the relay still logged `FetchDeclineChainNotPlausible` for TSUNAGI.

Relay logs from the same decision window show another peer being selected
with a stronger candidate (`Right [At (Block ...)]`). The relay's
BlockFetchDecision logic compares all candidates in a single evaluation.
When a competing peer already covers the same or better chain, the relay
has no reason to fetch from TSUNAGI — even if TSUNAGI is strictly ahead
of the relay's previously-known tip.

**Conclusion:** `FetchDeclineChainNotPlausible` is not decisive evidence of
a TSUNAGI protocol defect. The relay simply preferred another peer. To
prove whether the relay *can* fetch from TSUNAGI, we must eliminate all
competing peers and rerun the test.

---

## B) Safety note

- Preview network only. Never apply this procedure to mainnet.
- This is a temporary topology change for a single proof test.
- Original topology must be restored immediately after the test.
- All log extractions are bounded (no `tail -f`, no streaming).
- The relay will be offline or isolated for the duration of the test only.

---

## C) Backup step

Before modifying the relay topology, back up the current configuration.

On the relay machine:

```bash
# Identify the current topology file path.
# Common locations (adjust to your actual path):
#   /home/<user>/cardano/preview/topology.json
#   /opt/cardano/preview/topology.json
#   /etc/cardano-node/preview-topology.json
#
# Replace TOPOLOGY_PATH below with your actual path.

TOPOLOGY_PATH="/path/to/preview/topology.json"

cp "$TOPOLOGY_PATH" "${TOPOLOGY_PATH}.bak.$(date +%Y%m%d_%H%M%S)"
ls -la "${TOPOLOGY_PATH}.bak."*
```

Verify the backup exists and is non-empty before proceeding.

---

## D) Temporary relay isolation method

### D1. Stop the relay

```bash
# On the relay machine:
sudo systemctl stop cardano-node-preview
# or: systemctl --user stop cardano-node-preview
# Adjust unit name to match your relay's actual service name.
```

### D2. Create isolated topology

The goal: make TSUNAGI (152.53.155.36:3033) the only local-root peer.

Open the backed-up topology file to see its current format, then create
a temporary topology with only the TSUNAGI entry. The standard
cardano-node P2P topology format is:

```json
{
  "localRoots": [
    {
      "accessPoints": [
        {
          "address": "152.53.155.36",
          "port": 3033
        }
      ],
      "advertise": false,
      "valency": 1,
      "trustable": false
    }
  ],
  "publicRoots": [],
  "useLedgerAfterSlot": -1
}
```

Key points:
- `localRoots` contains ONLY the TSUNAGI peer.
- `publicRoots` is empty — no IOG/CF bootstrap peers.
- `useLedgerAfterSlot: -1` disables ledger peer discovery.
- This ensures the relay has no other candidate source.

If your relay uses a different topology format (non-P2P legacy, or
custom wrapper), duplicate your current format but keep only the
TSUNAGI entry and remove all other peers and public roots.

Write the isolated topology:

```bash
cat > "$TOPOLOGY_PATH" << 'TOPO'
{
  "localRoots": [
    {
      "accessPoints": [
        {
          "address": "152.53.155.36",
          "port": 3033
        }
      ],
      "advertise": false,
      "valency": 1,
      "trustable": false
    }
  ],
  "publicRoots": [],
  "useLedgerAfterSlot": -1
}
TOPO
```

### D3. Start the relay

```bash
sudo systemctl start cardano-node-preview
# or: systemctl --user start cardano-node-preview

# Verify it is running:
systemctl status cardano-node-preview | head -5
```

### D4. Verify isolation

```bash
# Confirm the relay loaded the isolated topology.
# Check recent logs for peer count / topology loading:
journalctl -u cardano-node-preview --since "1 min ago" --no-pager | grep -i -E "topology|local.root|peer" | head -10
```

The relay should show only one local root: 152.53.155.36:3033.

---

## E) TSUNAGI-side run

On the TSUNAGI machine (152.53.155.36):

### E1. Stop any existing propagate-serve

```bash
pkill -f "propagate-serve" 2>/dev/null; sleep 1
pgrep -fa "propagate-serve" || echo "propagate-serve stopped"
```

### E2. Seal a fresh artifact

```bash
~/.local/tsunagi/v3.8.1/bin/tsunagi-node guardian seal-tip \
    --net preview \
    --home ~/tsunagi-home-preview 2>&1 | tail -20
```

### E3. Start propagate-serve

```bash
RELAY_IP="<relay_ip_here>"

~/.local/tsunagi/v3.8.1/bin/tsunagi-node propagate-serve \
    --net preview \
    --artifact-dir ~/tsunagi-home-preview/propagation_artifact \
    --allowlist "$RELAY_IP" \
    --port 3033 2>&1 | tee /tmp/tsunagi-fetch-proof.log &

SERVE_PID=$!
echo "propagate-serve PID: $SERVE_PID"
```

### E4. Verify correct build

```bash
head -5 /tmp/tsunagi-fetch-proof.log | grep "build="
# Expected: build=v4.5.21-fetch-worthy-candidate-diag (or later)
```

### E5. Verify listener

```bash
ss -tlnp | grep 3033
# Expected: LISTEN on *:3033 or 0.0.0.0:3033
```

### E6. Wait for relay connection (bounded)

```bash
# Wait up to 120 seconds for the relay to connect.
# The relay should connect within ~30s of starting with TSUNAGI as its only local root.
timeout 120 tail -n +1 -f /tmp/tsunagi-fetch-proof.log | grep -m 1 "accepted connection"
echo "Connection received (or timeout after 120s)"
```

### E7. Wait for serve completion (bounded)

```bash
# Wait up to 180 seconds for the serve loop to complete.
timeout 180 tail -n +1 -f /tmp/tsunagi-fetch-proof.log | grep -m 1 "serveMuxLoop exit"
echo "Serve loop completed (or timeout after 180s)"
```

### E8. Extract decisive lines

```bash
grep -E "candidate:|MsgRequestRange|ClientDone|serveMuxLoop exit|ARTIFACT_READY|ARTIFACT_LOAD|bf_rx|bf_tx|StartBatch|BatchDone|BlockFetch" /tmp/tsunagi-fetch-proof.log
```

---

## F) Relay-side log extraction

On the relay machine, after the TSUNAGI serve completes:

```bash
# Extract only lines relevant to the TSUNAGI peer and BlockFetch decisions.
# Adjust time window to cover the test period.

journalctl -u cardano-node-preview --since "5 min ago" --no-pager \
    | grep -E "152\.53\.155\.36|BlockFetchDecision|FetchDecline|MsgRequestRange|MsgBlock|MsgBatchDone|fetchClientStateVars" \
    | head -50
```

If the relay uses file-based logging instead of journald:

```bash
# Adjust LOG_FILE to the relay's actual log path.
LOG_FILE="/var/log/cardano-node/preview.log"

tail -500 "$LOG_FILE" \
    | grep -E "152\.53\.155\.36|BlockFetchDecision|FetchDecline|MsgRequestRange|MsgBlock|MsgBatchDone" \
    | head -50
```

---

## G) Decision table

### CASE 1: TSUNAGI strictly_ahead=true, relay sends MsgRequestRange

TSUNAGI logs show:
```
candidate: ... strictly_ahead=true
```
```
bf_rx > 0 (MsgRequestRange received)
```

Relay logs show:
```
BlockFetchDecision ... Right [At (Block {slot} {hash})] ... 152.53.155.36
```

**Verdict:** Relay considers TSUNAGI fetch-worthy when no competing peers
exist. TSUNAGI has crossed the fetch-worthiness threshold. Next milestone
is BlockFetch serving validation (StartBatch + Block + BatchDone).

### CASE 2: TSUNAGI strictly_ahead=true, relay still declines

TSUNAGI logs show:
```
candidate: ... strictly_ahead=true
bf_rx=0
done_received=true (ClientDone only, no MsgRequestRange)
```

Relay logs show:
```
FetchDeclineChainNotPlausible ... 152.53.155.36
```
or no BlockFetchDecision line for TSUNAGI at all.

**Verdict:** The relay still does not consider TSUNAGI's candidate
plausible even without competition. This points to a deeper issue:
header validation failure, era mismatch, tip announcement format,
or candidate chain quality assessment. Next step is relay-side
trace-level BlockFetch logging to see the exact rejection reason.

### CASE 3: TSUNAGI strictly_ahead=false

TSUNAGI logs show:
```
candidate: ... strictly_ahead=false
```

**Verdict:** Test setup failure. TSUNAGI was not ahead of the relay
at the time of connection. Causes:
- Artifact was stale (relay already past TSUNAGI's sealed slot)
- seal-tip ran too early; relay caught up before connecting
- Relay retained chain state from before isolation

Fix: seal a new artifact closer to real-time, or restart the relay
with `--database-path` pointing to a fresh (empty) DB to force it
to start from genesis (extreme but decisive).

---

## H) Restore step

After the test, immediately restore the relay to its original topology.

### H1. Stop relay

```bash
sudo systemctl stop cardano-node-preview
```

### H2. Restore original topology

```bash
# Find the most recent backup:
ls -lt "${TOPOLOGY_PATH}.bak."* | head -1

# Restore it:
LATEST_BAK=$(ls -t "${TOPOLOGY_PATH}.bak."* | head -1)
cp "$LATEST_BAK" "$TOPOLOGY_PATH"
echo "Restored: $LATEST_BAK -> $TOPOLOGY_PATH"
```

### H3. Restart relay

```bash
sudo systemctl start cardano-node-preview
systemctl status cardano-node-preview | head -5
```

### H4. Verify restoration

```bash
journalctl -u cardano-node-preview --since "1 min ago" --no-pager \
    | grep -i -E "topology|local.root|peer" | head -10
```

Confirm the relay has loaded its original peer set (multiple peers visible).

### H5. Stop TSUNAGI propagate-serve (if still running)

```bash
# On the TSUNAGI machine:
kill "$SERVE_PID" 2>/dev/null || pkill -f "propagate-serve"
```
