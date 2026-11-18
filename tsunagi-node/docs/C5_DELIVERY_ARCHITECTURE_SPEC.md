# C5 Delivery Architecture Spec — Active Block Delivery (Acceptance Frontier #7B)

**Status:** design document only. No code, no implementation, no patches, no runtime change.
**Basis:** deployed binary `932dc5008169ffc9f449bb6ec4a0474be839b94c96bf0b912e617d5539018dd9` (0.15.2, base `9182326` + applied-tip fix). Source paths below are relative to `tsunagi-node/`. Verified identical on `chore/zig-0.16-migration-2026-06-07`.
**Evidence slot:** 114284040 (block 4361767, hash `1d40f74a336c8854`).

## Context — what is already closed
Forge correctness, opcert, era-7 envelope, sigma gate, and promotion frontiers are all proven on slot 114284040:
`FORGE_SELF_VERIFY pass=YES seq=0` → `FORGE_BLOCK_ENVELOPE_OK era_tag=7 prefix=820785` → `FORGE_PROMOTE_ATOMIC block_no=4361767` → `FORGE_PROMOTE_FRAGMENT … artifact_coherent=true degraded_mode=false`. The block is valid and on disk at **+1 s**.

Observed timeline (producer clock, `unix = 1666656000 + slot`):
```
+1s   FORGE_PROMOTE_ATOMIC / artifact exists + coherent
+6s   competing block observed (4361767 / aff6f743 @ slot 114284046; ROLLBACK_SUSPECT)
+9s   first meaningful propagation contact (conn #247, accepted_unix=1780940049)
+37s  ROLLBACK_CONFIRMED (koios_confirmed_loss)
```
Frontier **#7B = delivery latency**: TSUNAGI forges a valid block, but the network learns of it too late. Visibility fixes (C1–C4) alone do **not** change slot 114284040 — at first inbound contact cardano-node already held `relay_newest_slot=114284046` vs `sealed_slot=114284040`, so `FetchDeclineChainNotPlausible` was the expected, correct decision.

---

## 1. CURRENT ARCHITECTURE

Two threads in one process; the handoff between them is a **disk artifact + an atomic counter**, with no thread wakeup.

```
PRODUCER THREAD  (producer.zig)                  PROP THREAD  (net/propagation_server.zig)
──────────────────────────────────              ────────────────────────────────────────────
FORGE_PROMOTE_ATOMIC                              while (true):                            [L339]
  write meta.json / block.cbor / *.hex             pre-accept load (loadArtifactSnapshotEx) [L362]
copyFragmentDir(260)            [L4422,L5009]       ┌ inner: server.accept()  ← BLOCKS       [L394]
appendFragmentEntry             [L4441,L5103]       │   no timeout, no notify integration
write .ready sentinel           [L4468-4477]        │ doServerHandshake (v15)                [L415]
FORGE_PROMOTE_FRAGMENT          [L4456]             └ post-accept load → PROP_ARTIFACT_READY [L455-458]
forge_notify.notify()           [L4488]             serveMuxLoop (ChainSync/BlockFetch)
   = g_seq.fetchAdd(1,.release) [forge_notify.zig]    served_block/SERVE_DECISION            [L531-558]
NOTIFY_WAKE: slot=…             [L4489]              close → loop
```

Exact source references:
- `forge_notify.zig` (whole file): `pub fn notify() { _ = g_seq.fetchAdd(1, .release); }`, `pub fn loadSeq()`. No futex/condvar/eventfd.
- `producer.zig:4488` — the only `notify()` call. `producer.zig:4456` — `FORGE_PROMOTE_FRAGMENT`. `producer.zig:4468-4477` — `.ready`/`.ready.tmp` two-phase sentinel.
- `net/propagation_server.zig:394` — `conn = server.accept()` (blocking; comment L300-310 documents it is intentionally artifact-independent).
- `net/propagation_server.zig:314 / 364 / 456` — `loadArtifactSnapshotEx`; `:316 / 366 / 458` — `PROP_ARTIFACT_READY`; `:989` — `loadSealedArtifact`; `:704-720` — `.ready` sentinel gate.
- `net/propagation_server.zig:1501 / 1526` — the only `forge_notify.loadSeq()` consumers, **inside `serveMuxLoop`**, gated `if (fresh_path_complete and !served_block.*)` on a recv timeout (L1513).

**Proven defect:** `notify()` cannot return the prop thread from a blocking `accept()` syscall, and no consumer of the notify exists in the accept loop. A forged artifact is therefore first *loaded/announced* (`PROP_ARTIFACT_READY`) only **after** the next inbound dial. Runtime: artifact at +1 s, `PROP_ARTIFACT_READY` at +9 s (= conn #247 `accepted_unix=1780940049`).

---

## 2. CONNECTION MODEL

### N2N topology (observed)
```
cardano-node (127.0.0.1:6000)  ──dials──▶  TSUNAGI propagation listener (127.0.0.1:3033)
        INITIATOR / responder=TSUNAGI                RESPONDER
```
cardano-node opens the connection (`propagation: connection accepted from 127.0.0.1`, L400). TSUNAGI never dials out for block delivery.

### Roles (Ouroboros node-to-node)
| mini-protocol | id | cardano-node | TSUNAGI |
|---|---|---|---|
| Handshake | 0 | client (Propose) | server (Accept v15) |
| ChainSync | 2 | **client** (RequestNext / FindIntersect) | **server** (RollForward / RollBackward / AwaitReply) |
| BlockFetch | 3 | **client** (RequestRange) | **server** (StartBatch / Block / BatchDone) |
| TxSubmission2 | 4 | (inert here) | (inert) |
| KeepAlive | 8 | client | server |

Because cardano-node is the **initiator**, it is the **ChainSync client and BlockFetch client**; TSUNAGI is the **ChainSync server and BlockFetch server**. (Confirmed in logs: TSUNAGI emits `MsgIntersectFound` / `MsgRollBackward` / `MsgRollForward`; cardano-node sends `MsgFindIntersect` / `MsgRequestNext`.)

### Agency — who may legally send what, when
- **ChainSync:** client holds agency to send `MsgFindIntersect` / `MsgRequestNext`. After a `MsgRequestNext`, the **server** holds agency and replies `MsgRollForward` / `MsgRollBackward` *or*, when caught up, `MsgAwaitReply`. **After `MsgAwaitReply` the server RETAINS agency** and may send `MsgRollForward` the instant its chain advances — without a further client request. This is the protocol-sanctioned push point.
- **BlockFetch:** client holds agency to send `MsgRequestRange`. The server then streams `MsgStartBatch` → `MsgBlock`* → `MsgBatchDone` (or `MsgNoBlocks`).

**Current behavior wastes the agency:** TSUNAGI serves a snapshot up to the sealed tip, then closes (`SERVE_DECISION kind=header_only_disconnect`, L555). It never parks in `MsgAwaitReply` holding agency, so it never pushes a later forge on an open session.

---

## 3. C5 MODEL — persistent inbound ChainSync session with forge-triggered RollForward

C5 uses **no new connection and no new protocol** — only the agency already owned on the inbound session. The connection is **held open and parked in `MsgAwaitReply`**; on forge, TSUNAGI exercises its retained ChainSync-server agency to push `MsgRollForward`; cardano-node's BlockFetch client then pulls the body over the same connection.

### Steady state (before forge) — keep cardano-node caught up
```
cardano-node (CS client)                 TSUNAGI (CS server)
  MsgFindIntersect(points) ───────────▶
                          ◀─────────────  MsgIntersectFound(tip=current canonical)
  MsgRequestNext ─────────────────────▶
                          ◀─────────────  MsgRollForward(headers up to canonical tip)…
  MsgRequestNext ─────────────────────▶
                          ◀─────────────  MsgAwaitReply        ← server now PARKED, holds agency
  (connection stays OPEN; cardano-node tracking TSUNAGI as a candidate at the live tip)
```

### Forge instant (+1 s) — push
```
[ producer: FORGE_PROMOTE_ATOMIC → forge_notify advances ]
TSUNAGI (CS server, parked in AwaitReply) detects the advance and, holding agency:
                          ◀─────────────  MsgRollForward(header 4361767 @ slot 114284040)   ← ANNOUNCE
cardano-node validates header, prefers it (1-block forward extension of its tip 4361766):
  MsgRequestNext ─────────────────────▶  (resumes; or returns to AwaitReply)
```

### Body pull (+1.x s) — BlockFetch over the same connection
```
cardano-node (BF client)                 TSUNAGI (BF server)
  MsgRequestRange(4361767..4361767) ──▶
                          ◀─────────────  MsgStartBatch
                          ◀─────────────  MsgBlock(864-byte body of 4361767)
                          ◀─────────────  MsgBatchDone
cardano-node: AddedToCurrentChain(1d40f74a…)
```

**The only architectural deltas vs §1:** (a) do not close after the snapshot — park in `MsgAwaitReply` and keep the session; (b) serve the *live* canonical tip in steady state so cardano-node stays caught up; (c) on `forge_notify` advance, emit `MsgRollForward` of the new sealed tip on the already-open, caught-up session instead of waiting for a new dial. No new message types; identical wire encodings to those TSUNAGI already produces.

---

## 4. LATENCY BUDGET — slot 114284040

| stage | event | budget |
|---|---|---|
| forge | FORGE_PROMOTE_ATOMIC | observed +1 s (artifact coherent) |
| promotion | fragment copy(260)/.ready already done in the same forge step | included in +1 s (sub-log-second) |
| announcement | `MsgRollForward(header)` on parked session | forge-instant + wake of parked server thread + one loopback header send → **~+1 s** |
| fetch init | cardano-node `MsgRequestRange` | one loopback RTT after header validates → **~+1.0–1.5 s** |
| body transfer | `MsgBlock` 864 B over 127.0.0.1 | bounded by one loopback RTT (theoretical; not measured) → **delivery ≈ +1.1–1.5 s** |

Target: **delivery before competitor arrival (+6 s).** Achievable slack ≈ **4.5–5 s**. Theoretical floor = forge-instant + one localhost BlockFetch RTT. The controllable variable is *announcement timing* (move from +9 s inbound-dial to +1 s push); the body transfer is already trivial on loopback. This sits inside the forensic budget (≤6 s to tie, ≤~1–2 s to win).

---

## 5. PROTOCOL COMPLIANCE REVIEW

| message | sender / role | why compliant |
|---|---|---|
| `MsgRollForward` | TSUNAGI, ChainSync **server** | Sent only while the server holds agency after `MsgAwaitReply` — the exact state Ouroboros reserves for the server to announce new chain. Same message TSUNAGI already emits (`chainsync: tx MsgRollForward`), just on a parked session. |
| `MsgRequestRange` | cardano-node, BlockFetch **client** | Client-initiated; TSUNAGI only responds. Unchanged from today. |
| `MsgStartBatch` | TSUNAGI, BlockFetch **server** | Legal opening of a batch in response to a `MsgRequestRange` for an in-range, available block. |
| `MsgBlock` | TSUNAGI, BlockFetch **server** | Carries the same sealed 864-byte body already on disk; one per requested block. |
| `MsgBatchDone` | TSUNAGI, BlockFetch **server** | Legal batch terminator after the streamed blocks. |

No new mini-protocol, no new message, no agency violation: every send is in a state where the role already holds agency. Chain selection on cardano-node is unchanged (standard Ouroboros: prefer longer chain; do not switch between equal-length chains — first-received retained). C5 only changes *when* TSUNAGI's valid RollForward reaches a peer that is still at the parent.

---

## 6. FAILURE MODES

| failure | behavior under C5 | mitigation (design intent, not code) |
|---|---|---|
| connection drop | parked session lost; falls back to current snapshot-on-next-dial path | accept loop must re-establish + re-park; no worse than today |
| stale tip | if TSUNAGI's parked tip lags the network, RollForward is a non-preferred fork → `FetchDeclineChainNotPlausible` (today's outcome) | steady-state must serve the *live* canonical tip so the forge is a true forward extension |
| competing leader | a same-height block from another pool | C5's value is *timing*: deliver before +6 s so first-received wins under equal-length-no-switch; cannot help if competitor is genuinely earlier/strictly-longer |
| rollback | forged block later orphaned by the network | unchanged: orphan-watchdog (`FORGE_ORPHAN_WATCHDOG_ARMED`) + `ROLLBACK_CONFIRMED` still govern; C5 does not weaken rollback safety |
| duplicate announcements | RollForward emitted more than once for the same tip | announcement must be idempotent on (slot, hash); guard on the forge sequence already tracked by `forge_notify.loadSeq()` |
| race conditions | producer advancing `forge_notify` while server mid-serve | acquire-release ordering already in `forge_notify`; the parked server reads `loadSeq()` between sends; serve must read a coherent snapshot (the existing `.ready` two-phase sentinel, L704-720, already guards torn reads) |

---

## 7. RISK ASSESSMENT

| option | what it changes | complexity | risk | expected benefit on slot 114284040 |
|---|---|---|---|---|
| C1 accept-timeout | visibility only (reuses existing pre-accept reload) | very low | **LOW** | none (delivery still +9 s; declined) |
| C2 notify-poll | C1 + cheaper change-detection via `loadSeq()` | low | LOW | none |
| C3 eventfd/futex | event-driven accept loop; instant visibility | medium | MED-HIGH | none (visibility, not delivery) |
| C4 eager publish | in-memory snapshot handoff; removes disk reload | medium | MEDIUM | none alone (needs a wake) |
| **C5 active delivery** | **persistent session + push-on-forge (delivery)** | **high** | **HIGH** | **the only option inside the +6 s budget — can win the slot** |

Ranking by risk (low→high): C1 < C2 < C4 < C3 < C5. Ranking by benefit-for-#7B: C5 ≫ (C1=C2=C3=C4=0). C1 remains worthwhile as a low-risk visibility de-risk and a prerequisite mindset for C5 (the server must be awake and current), but only C5 addresses delivery latency.

---

## 8. SUCCESS CRITERIA (measurable)

On a future elected slot with the C5 design realized, all of:
- **artifact visible < 1 s** — `PROP_ARTIFACT_READY` (or equivalent live-tip state) within 1 s of `FORGE_PROMOTE_ATOMIC`.
- **RollForward emitted < 2 s** — `chainsync: tx MsgRollForward(new tip)` on a parked session within 2 s of forge.
- **body fetch initiated < 3 s** — inbound `MsgRequestRange` for the forged block within 3 s of forge (i.e. `blockfetch_rx_total ≥ 1`, `served_block=true`).
- **accepted before competing height** — cardano-node `AddedToCurrentChain` for the forged hash before any same-height competitor; externally: `cardano-cli query tip` shows the forged hash, Koios `pool_blocks` lists it, and no `ROLLBACK_CONFIRMED reason=koios_confirmed_loss` for that slot.

Baseline for comparison (slot 114284040, measured): visible +9 s, no RollForward push, `bf_rx=0` / `served_block=false`, `FetchDeclineChainNotPlausible`, orphan at +37 s.

---

*Design document only. No source modified. No commit. Acceptance Frontier #7B (delivery latency) remains open; this spec defines the smallest protocol-compliant path to close it.*
