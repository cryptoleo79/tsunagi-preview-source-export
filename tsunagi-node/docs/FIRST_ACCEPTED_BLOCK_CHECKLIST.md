# First Accepted Block — Operator Checklist

The exact, minimal checklist for the next elected slot. Goal: forge a block that cardano-node accepts
and that appears on-chain. Work top to bottom. Abort markers are called out; if you see one, stop and
consult `docs/operator/opcert-troubleshooting.md` or `docs/ACCEPTANCE_FRONTIER_STATUS.md`.

`H = $TSUNAGI_HOME` (confirm from `start-relay-forge.sh` — currently `…/tsunagi-home-colo`).
`L = ~/tsunagi-logs/forge.log` (or `$H/logs/node.log`).

---

## PRE-FORGE (before the elected slot)

**1. Sigma source** — launcher exports the real opcert sigma (env-only; no file source):
```bash
grep -o 'TSUNAGI_OPCERT_SIGMA_HEX=[0-9a-f]*' /home/cardano/start-relay-forge.sh
# must be 128 hex, first8 = 5e3c8839   (NOT 28a96940)
python3 scripts/extract-opcert-sigma.py --verify /home/cardano/tsunagi-keys-tsng/node.cert
# expect: SELF-VERIFY PARITY ... PASS
```

**2. Opcert state** — seq equals the cert counter (file wins over env):
```bash
cat "$H/opcert_state.json"                 # {"seq_no":0,...}
grep "OPCERT_STATE" "$L" | tail -1         # current=0 source=file last_persisted=0
```

**3. Sigma bytes loaded by the runtime** — boot echo matches the cert:
```bash
grep "TSUNAGI_OPCERT_SIGMA_HEX" "$L" | tail -1     # first8 = 5e3c8839
```

**4. Leader schedule** — an elected slot is queued:
```bash
grep -E "LEADER_SCHEDULE:|SCHEDULE_NEXT:" "$L" | tail -2
# note next_slot + eta_sec; confidence=strong
```

> Go/no-go: STEP 1 PASS + seq=0 + sigma first8 `5e3c8839` + a scheduled slot. If any fail, fix before
> the slot — do not burn the elected slot on a known-bad config.

---

## AT SLOT (watch live)

```bash
tail -f "$L" | grep -E "EVENT_LEADER_DETECTED|FORGE_GATE_DECISION|FORGE_SELF_VERIFY|FORGE_BLOCK_ENVELOPE|FORGE_PROMOTE_ATOMIC|FORGE_PROMOTE_FRAGMENT|BF_SERVE_BLOCK|PROPAGATION_SEND|FORGE_REFUSE|ACCEPTANCE_VERDICT"
```

Expected sequence (each must appear; the `FORGE_REFUSE_*` / `*_FAIL` forms are abort markers):

| # | marker | expected |
|---|--------|----------|
| 1 | `EVENT_LEADER_DETECTED` | leader=true at the elected slot |
| 2 | `FORGE_GATE_DECISION` | `ALLOW` (nonce/sigma/canonical-lag pass) |
| 3 | `FORGE_SELF_VERIFY` | `gate=opcert pass=YES seq=0 period=846` ← the opcert frontier |
| 4 | `FORGE_BLOCK_ENVELOPE` | OK — block begins `82 07 85` (Conway era 7) |
| 5 | `FORGE_PROMOTE_ATOMIC` | sealed block written |
| 6 | `BF_SERVE_BLOCK` | body served to cardano-node (`served_block=true`, `blockfetch_rx_total>0`) |

Abort markers (stop, diagnose, do not expect acceptance):
`FORGE_GATE_*` refuse · `FORGE_SELF_VERIFY_FAIL` · `FORGE_BLOCK_ENVELOPE_FAIL` · `FORGE_REFUSE_STALE_PARENT`.

---

## POST SLOT (confirm acceptance)

**1. Acceptance verdict (node-internal):**
```bash
grep -E "ACCEPTANCE_VERDICT|CANONICAL_CONFIRMED" "$L" | tail -5
# target: ACCEPTANCE_VERDICT result=ADOPTED
```

**2. cardano-node journal** — no rejection around the slot time:
```bash
journalctl -u cardano-node --since "5 min ago" | grep -iE "chainsync|blockfetch|invalid|reject|AddedToCurrentChain|SwitchedToAFork"
# want AddedToCurrentChain with our hash; NOT DeserialiseFailure / invalid / reject
```

**3. cardano-cli tip** — chain tip shows our forged hash/block:
```bash
cardano-cli query tip --testnet-magic 2
# compare 'hash'/'block' to the forged values in FORGE_PROMOTE_ATOMIC
```

**4. Koios verification** — block recorded for the pool:
```bash
curl -s "https://preview.koios.rest/api/v1/pool_blocks?_pool_bech32=<POOL_ID>" | head
# our block_no appears in the current epoch
```

---

## If accepted

Record the slot, block_no, and hash. Note: the live binary still bumps the opcert counter after a
completed forge (`932dc500`) — reset `"$H/opcert_state.json"` to `{"seq_no":0,"last_slot":0}` before
the next slot, or deploy the opcert-pin binary (`OPCERT_PIN`) to make it durable. See
`docs/ACCEPTANCE_FRONTIER_STATUS.md` (frontier 5).
