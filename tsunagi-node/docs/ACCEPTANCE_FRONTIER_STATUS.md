# TSUNAGI — Acceptance Frontier Status

This document tracks every distinct frontier that blocked TSUNAGI from forging and having a block
accepted on the live preview network. Each frontier is a separately-diagnosed root cause; clearing one
exposed the next. "Frontier" = the specific defect that the elected-slot forge died on.

Legend — **Status:** Fixed+Deployed · Fixed (built, not yet deployed) · Operator-corrected (live env)
· Residual (known, non-blocking).

| # | Frontier | Status |
|---|----------|--------|
| 1 | Conway era tag (6 → 7) | Fixed + Deployed |
| 2 | Sigma gate (sigma-drift forge refusal) | Fixed + Deployed |
| 3 | Authoritative sigma (election under-election) | Fixed + Deployed |
| 4 | Stale parent (applied-tip cross-domain) | Fixed + Deployed (residual intermittent refusal) |
| 5 | Opcert counter drift | Operator-corrected (live) · pin Fixed (built, not deployed) |
| 6 | Opcert sigma corruption | Operator-corrected (live) |
| 7A | Artifact visibility / accept-wait | **Proven** (root cause established; not the slot-114284040 cause alone) |
| 7B | Delivery / adoption latency | **Active** (current frontier — forge correct, network learns too late) |

---

## 1. Conway era tag (6 → 7)

- **Root cause:** the forged Conway block envelope was tagged era **6** (Babbage) instead of **7**
  (Conway; Byron consumes two of the era tags, so Conway = 7). cardano-node routed the block to its
  Babbage decoder → `DeserialiseFailure` in the BlockFetch codec **before** ChainDB. Symptom: no
  ChainDB trace, persistent `FetchDeclineInFlightThisPeer` / `CoolingToCold`, silent orphan.
- **Fix:** `CONWAY_BLOCK_ERA_TAG = 7` constant in `cbor_block_full.zig`; producer + readiness use it;
  added a `FORGE_BLOCK_ENVELOPE` self-verify gate (refuse unless the assembled block begins
  `82 07 85`) plus a regression test.
- **Current status:** Fixed + Deployed. The live binary emits `82 07 85`.

## 2. Sigma gate (sigma-drift forge refusal)

- **Root cause:** the forge gate `FORGE_GATE_SIGMA` compared a stale one-shot bootstrap `ledger_sigma`
  (env) against a fresh poller `chain_sigma`. Their drift exceeded the 15% guard, so the gate refused
  to forge even on legitimately-elected slots.
- **Fix:** gate prefers the freshest available value: `env = max(raw_env, chain)`.
- **Current status:** Fixed + Deployed (folded into the Variant B lineage).

## 3. Authoritative sigma (election under-election)

- **Root cause:** election / leader-schedule used a stale `ledger_sigma`, while the fresh
  `stake_source` poller fed **only** the forge gate. The two diverged, so the node was *under-elected*
  (~2.2 vs ~7.9 slots/epoch) — it rarely even got an elected slot to forge.
- **Fix:** Variant B — a single read-only `resolveAuthoritativeSigma(ctx)` resolver used by
  `effective_sigma`, the leader schedule **and** the forge gate, so all three agree. No writes to
  `ledger_sigma`; cannot over-elect (the poller equals cardano-node's on-chain sigma).
- **Current status:** Fixed + Deployed. The deployed lineage is base `9182326` (Variant B).

## 4. Stale parent (applied-tip cross-domain corruption)

- **Root cause:** chainsync `RollForward` stored a **cross-domain** applied-tip triple — the
  slot/block came from the peer-tip claim (N) but the hash came from the delivered header (N+1),
  producing an impossible triple (`block_no=N` with `hash=hash(N+1)`). `selectFreshestParent`'s
  `rx_prev == tip_hash` one-step check could therefore never match → **systematic**
  `FORGE_REFUSE_STALE_PARENT` on every elected slot.
- **Fix:** `appliedTipTripleForRollForward` (`src/net/chainsync/applied_tip_select.zig`) stores a
  single-domain delivered-header triple. Producer/CBOR untouched (forge bytes byte-identical).
  Regression: `acceptance_frontier_parent_select_tests.zig`.
- **Current status:** Fixed + Deployed (in binary `932dc500`). **Residual:** occasional intermittent
  `FORGE_REFUSE_STALE_PARENT` where `parent_gap > stale_threshold` at the elected instant (node briefly
  behind the chain tip; `hashes_equal=false` is informational, not the trigger). This is a
  non-systematic freshness refusal, not the original corruption — to classify a specific case, read
  the full line's `fallback_reason` / `parent_source` / `parent_gap_slots`.

## 5. Opcert counter drift

- **Root cause:** a per-forge `OPCERT_INCREMENT` bumped `dryrun_opcert_seq_no` and persisted
  `opcert_state.json` after every local forge. Over months the counter walked **0 → 15**. The forge
  self-verify gate (added later) then failed for any `seq ≥ 1` and aborted **before** the increment,
  freezing the counter. `opcert_state.json` (file) wins over `TSUNAGI_OPCERT_SEQ` (env), so the
  launcher's `OPCERT_SEQ=0` was silently overridden. A real Cardano opcert signs every block in its KES
  window with the **same** counter; bumping it per-forge is the bug.
- **Fix:** (operator) reset `{TSUNAGI_HOME}/opcert_state.json` to the cert counter (`{"seq_no":0,…}`),
  restart. (code) **pin** the counter — `oc_new = oc_old` (logged `OPCERT_PIN`), no per-forge bump.
  Forge bytes unchanged (assembly reads the seq before the removed bump).
- **Current status:** Operator-corrected live (`OPCERT_STATE current=0`). Code pin built on the 0.15.2
  deployed lineage (binary sha256 `2ce4b642487253e1540f89ec00320f11ce4a9c7477aa6d302de5cecd25c28906`)
  and mirrored on the Zig 0.16 branch; **not yet deployed**.

## 6. Opcert sigma corruption

- **Root cause:** the launcher (`start-relay-forge.sh`, `tsunagi-auto.sh`) exported a
  `TSUNAGI_OPCERT_SIGMA_HEX` that was **not the opcert signature** but a mis-sliced region of the
  `node.cert` cborHex (`28a96940…`, a tail-slice = sigma tail + CBOR `5820` tag + cold vkey). The
  loader read its first 64 bytes as the sigma → self-verify failed even after `seq` was corrected to 0.
  The real sigma is `5e3c8839…` (between the cborHex `5840` and `5820` markers).
- **Fix:** correct the launcher value to the `node.cert` sigma, extracted deterministically via
  `scripts/extract-opcert-sigma.py` (never by hand-slicing). Restart.
- **Current status:** Operator-corrected live. The runtime now loads `sigma_first8=5e3c8839` and
  `seq=0`; all five self-verify inputs match the certificate. Full detail:
  `docs/incidents/2026-06-opcert-self-verify-root-cause.md`.

---

## 7A. Artifact visibility / accept-wait

- **Status:** Proven.
- **Root cause (source-established):**
  - `forge_notify.notify()` is an atomic `g_seq.fetchAdd(1, .release)` only (`net/forge_notify.zig`) — no
    futex/condvar/eventfd; it cannot return a thread from a blocking syscall.
  - The propagation server blocks in `server.accept()` (`net/propagation_server.zig:394`, no timeout); the
    notify is never consumed by that loop (its only `loadSeq()` consumer, `:1501/1526`, is inside
    `serveMuxLoop`, gated on an already-open connection).
  - `PROP_ARTIFACT_READY` (`:316/366/458`) is therefore emitted **only after the next inbound dial** — a
    freshly forged artifact sits invisible to the server until cardano-node connects.
- **Evidence (slot 114284040):** artifact coherent on disk at +1 s; `PROP_ARTIFACT_READY` at +9 s
  (= conn #247 `accepted_unix=1780940049`). The 8 s gap is idle wait in `accept()`, not compute.
- **Note:** Proven, but **not the cause of the slot-114284040 loss by itself** — candidate visibility fixes
  C1–C4 would not have changed the outcome (see 7B). Candidate designs: `docs/C5_DELIVERY_ARCHITECTURE_SPEC.md` §7.

## 7B. Delivery / adoption latency  ← current active frontier

- **Status:** Active.
- **Hypothesis:** TSUNAGI forges a valid block, but the network learns of it too late to adopt it.
- **Evidence (slot 114284040, block 4361767, hash `1d40f74a336c8854`):**
  - Forged successfully (`FORGE_PROMOTE_ATOMIC`/`FRAGMENT`, all gates green) at +1 s.
  - Competing block (4361767 / `aff6f743` @ slot 114284046) observed at +6 s (`ROLLBACK_SUSPECT`).
  - First meaningful propagation contact at +9 s.
  - At that contact cardano-node already had `relay_newest_slot=114284046` vs `sealed_slot=114284040` →
    `relay_ahead=true`, `strictly_ahead=false` → `FetchDeclineChainNotPlausible` (cardano-node never
    fetched the body; `served_block=false`, `bf_rx=0`).
  - `ROLLBACK_CONFIRMED reason=koios_confirmed_loss` at +37 s.
- **Result:** **FORGE SUCCESS / ADOPTION FAILURE.**
- **Smallest protocol-compliant remedy (design only, no code):** active delivery (C5) — persistent inbound
  ChainSync session parked in `MsgAwaitReply`, forge-triggered `MsgRollForward`, then BlockFetch over the
  same connection. Spec: `docs/C5_DELIVERY_ARCHITECTURE_SPEC.md`. Incident:
  `docs/incidents/2026-06-slot-114284040-propagation-race.md`.

## Frontier dependency note

Frontiers 5 and 6 are **independent and compound** — each alone fails the forge self-verify, and both
were present simultaneously. Frontier 4's residual is orthogonal to 5/6 (a parent-selection freshness
check, not opcert material). Frontiers 1–6 are all **forge-correctness** frontiers; clearing them moved
the acceptance frontier off forge correctness entirely. **#7A/#7B are the first propagation/delivery
frontiers** — the forge is proven (slot 114284040), and what remains is getting the valid block to the
network in time to be adopted. Tooling: `scripts/extract-opcert-sigma.py`. Operator procedure:
`docs/operator/opcert-troubleshooting.md`. Delivery design: `docs/C5_DELIVERY_ARCHITECTURE_SPEC.md`.
