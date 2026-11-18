# FIRST BLOCK — BlockFetch-Serve GO / NO-GO Readiness

**Date:** 2026-06-07
**Scope:** Validation/analysis only. No deployed binary, forge/crypto/propagation/blockfetch serve logic, or `forge.env` was modified to produce this document.
**Subject binary (deployed ACCEPTANCE):** source at `/home/tsunagi/zig016-equiv/baseline-0.15.2/tsunagi-node`, commit `9182326`, built with Zig 0.15.2 (`/home/tsunagi/opt/zig-x86_64-linux-0.15.2/zig`). Carries: era-tag-7, sigma gate, authoritative sigma resolver, `.ready` two-phase propagation commit, B2/B3 ordering, opcert self-verify, full BlockFetch-serve hardening.
**Goal:** the FIRST network-accepted block at the next elected slot.

---

## (1) Verdict

**GO — conditional.** The deployed binary is offline-proven correct on every block-#1 root-cause and on the full BlockFetch serve codec path. The three failure surfaces that orphaned block #1 (era-tag mis-route, fragment-write race, BlockFetch body never served) are each closed in source with imported-real-source harness evidence. **What remains genuinely unproven is wire-level transmission to a real cardano-node over a live socket** — every offline proof stops at the codec/byte-construction boundary and faithfully *models* (does not execute) cardano-node's HFC per-era router. Therefore the verdict is GO with the explicit understanding that the **next elected slot is the first and only test of the live socket path**: `mux_bearer.sendSegment` actually transmitting StartBatch+Block+BatchDone, the relay actually fetching the body, and `ACCEPTANCE_VERDICT=ADOPTED`.

No offline blocker remains. The honest residual is irreducibly live (Section 3).

---

## (2) Root-cause closure table — block-#1 orphan

| # | Root cause (block #1, slot 113310132) | Status | Proof basis | Residual |
|---|---------------------------------------|--------|-------------|----------|
| 1 | **Era tag 6 vs 7.** Block envelope was tagged era-6 (Babbage) instead of era-7 (Conway); cardano-node routed it to the Babbage decoder → `DeserialiseFailure` → served header but never fetched body (`served_block=false`, `peer_disconnect`). | **CLOSED (offline)** | Proof `era7_body_deserialize` (proven=true). Harness imported REAL deployed sources (`cbor_block_full.zig`, `net/ledger/block_hash.zig`, `net/cbor/term.zig`). Output: `PREFIX=820785 ok=true`; `HEADER_RT extracted=82a0a0 golden=82a0a0 match=true`; `TERM_DECODE era_term=7 parses_as_conway=true`; `NODE_ROUTE era=7->Conway->ADOPTED`; flip `only_byte1(7->6)` → `block6=820685` → `NODE_ROUTE era=6->Babbage->failed=true err=DeserialiseFailure`. Committed guard test `cbor_block_full` asserts era tag=7 and passes. | The era-6→Babbage→`DeserialiseFailure` step uses a **faithful MODEL** of cardano-node's HFC `SerialiseHFC` per-era router, NOT cardano-node itself. TSUNAGI's own decoder is era-AGNOSTIC (skips the era element) so it cannot reproduce node-side rejection locally. **Live slot needed** to confirm a real era-7 block makes the real relay fire `served_block=true` / `blockfetch_rx_total>0` / `ACCEPTANCE_VERDICT=ADOPTED`. |
| 2 | **Fragment-write race.** propagation_server's `loadArtifactSnapshotEx` polled between the sealed-block write and `copyFragmentDir`/`appendFragmentEntry`, observing `fragment_depth=0` while disk had the full fragment (block #1 saw `fragment_depth=0` on initial ARTIFACT_LOAD). | **CLOSED (offline)** | `.ready` two-phase commit is in the subject binary (commit 9182326). Producer clears `.ready` at FORGE_PROMOTE_ATOMIC start, writes `.ready.tmp` and atomically `rename()`s to `.ready` only AFTER FORGE_PROMOTE_FRAGMENT; `loadArtifactSnapshotEx` refuses to load (logs `ARTIFACT_LOAD_NOT_READY`) for gen>0 while `.ready` is absent. B2 ordering (forge_notify after fragment) is also carried. | Race is eliminated by construction (atomic rename + load gate). No additional live confirmation required beyond observing a clean `ARTIFACT_LOAD ... coherent=true fragment_depth>0` (no `fragment_depth=0` flap) at the elected slot. |
| 3 | **BlockFetch body never served.** Even on a correct header, the serve path must reach `served_block=true` and emit MsgBlock body bytes on the wire. | **CLOSED at codec (offline); OPEN at wire** | Proof `bf_served_block_true` (proven=true) + `bodyhash_match` (proven=true). `src/propagation_server_bf_repro_tests.zig` ran under Zig 0.15.2 `-lsodium`: "All 12 tests passed". Test "matching point returns 3-message batch" drives RequestRange `[0,[12345,0xAB..],[12345,0xAB..]]`, `handleMessage` returns 3 responses, asserts `server.served_block` (passes). RESPONSE[1] = `8204d818581f7473756e6167692d...` = `MsgBlock[4, tag24(bytes len31)]`, wire len=37. `bodyhash_match`: golden block `evidence/preview-first-forge/1773630105_106974087/block.cbor` (864B, envelope `82 07 85`); harness independently re-parses served CBOR, extracts `header_body[7]=29571d16f081709b...`, recomputes blake2b256 over served body bytes → PASS across empty/non-empty paths; tamper detected. | Offline proves the codec reaches `served_block=true` and produces correct body bytes whose hash matches `header[7]`. **Live slot needed** to confirm `mux_bearer.sendSegment` actually transmits StartBatch+Block+BatchDone over a real socket and the relay fetches the body (`served_block=true` on wire, `blockfetch_rx_total>0`, no `peer_disconnect`) for the REAL era-7 sealed artifact. |

### Serve-path mechanics (from RECON, for auditability)
- **Dispatch:** `BlockFetchServer.handleMessage` (blockfetch_server.zig:53) switches on wire tag `term.array[0].u64`: tag 0 → `handleRequestRange` (line 84); tag 1 (ClientDone) → null; else → null.
- **Hit path:** `handleRequestRange` decodes `MsgRequestRange=[0,point_from,point_to]`, calls `findBlock(point_from)` (line 113); on a hit builds the 3-message batch `[StartBatch(2), Block(4, tag24(block_cbor)), BatchDone(5)]`, sets `self.served_block=true` at **line 150 (the LAST statement)**, returns the responses.
- **Two distinct flags:** (a) codec-level `BlockFetchServer.served_block` set true only at blockfetch_server.zig:150, reached ONLY when `findBlock` matches; every miss/malformed/early-exit path returns `encodeNoBlocks` (1 msg) WITHOUT setting it. (b) loop-level flag set true only at propagation_server.zig:2015-2016 (`if bf_server.?.served_block`).
- **Live driver:** propagation_server.zig `serveMuxLoop` builds `bf_server` at lines 1453-1469 from `fetchable_buf`; blockfetch payloads dispatched at line 1759 (`proto==blockfetch_proto==3`); `handleMessage` called at line 1884; loop-level `served_block` set at 2015-2016; responses[1] → `BF_SERVE_BLOCK`+`PROPAGATION_SEND` (1981/2015), `served_block` field → `BF_TX`.

---

## (3) Residual live risks — ranked by probability

These are the items that **only a live elected slot can confirm**. Each is an honest gap between offline codec proof and on-wire behavior against a real cardano-node.

1. **(HIGHEST) Real cardano-node accepts the real era-7 block end-to-end.** Offline only *models* the HFC per-era router; TSUNAGI's own decoder is era-agnostic and cannot reproduce node-side rejection. The era-7 fix is the leading hypothesis for the block-#1 disconnect, but its sufficiency against the live Praos/Conway validator is unproven. *Confirmed by:* `served_block=true` on wire, `blockfetch_rx_total>0`, no `peer_disconnect`, `ACCEPTANCE_VERDICT=ADOPTED`.

2. **(HIGH) Wire transmission of the 3-message batch.** `mux_bearer.sendSegment` actually pushing StartBatch+Block+BatchDone over the real socket is untested offline (harness asserts response construction, not socket flush). A mux/segmentation or backpressure issue would surface only live. *Confirmed by:* `BF_SERVE_BLOCK` + `PROPAGATION_SEND` + `BF_TX` log lines at the elected slot.

3. **(MEDIUM) Connection lifecycle / timing.** Block #1 also showed reconnects with `tsunagi_ahead=true need_rollback_initial=true` and a disconnect ~3s after register. Even with era-7 correct, a lifecycle/timeout/RF_RESP-timing issue could prevent the body fetch independent of validation. *Confirmed by:* absence of `peer_disconnect` / `loop_exit_reason=peer_disconnect` during the serve window; `ACCEPTANCE_VERDICT` reaching `ADOPTED` rather than `state=pending`.

4. **(MEDIUM) Sealed era-7 artifact byte-identity vs. golden.** The golden block (`82 07 85` envelope) round-trips, but the live forged artifact must be the same era-7 shape under the live nonce/sigma/KES state. The authoritative-sigma resolver and opcert self-verify reduce this risk but it is only fully exercised at forge time. *Confirmed by:* `FORGE_BLOCK_ENVELOPE` gate passing (block starts `82 07 85`) and `FORGE_PROMOTE_FRAGMENT artifact_coherent=true degraded_mode=false`.

5. **(LOW) Slot contention.** Another pool wins the elected slot (ordinary Praos competition); not a TSUNAGI defect. *Confirmed by:* `cardano-cli query tip` / Koios showing whether TSUNAGI's hash is on chain.

---

## (4) Live-watch sequence + 3 confirmation oracles

### In-process log watch (expected chain at the elected slot)
Tail the deployed relay log and expect, in order:

```
EVENT_LEADER_DETECTED
FORGE_GATE_DECISION ALLOW leader=true
FORGE_GATE_NONCE pass=YES
FORGE_GATE_SIGMA  (SIGMA_AUTHORITATIVE present; drift within bound)
FORGE_GATE_CANONICAL_LAG pass
FORGE_SELF_VERIFY gate=opcert pass=YES seq=0 period=846
FORGE_BLOCK_ENVELOPE  (block starts 82 07 85 — era-7 guard)
FORGE_PROMOTE_ATOMIC
ACCEPTANCE_REGISTER
FORGE_PROMOTE_FRAGMENT artifact_coherent=true degraded_mode=false
  -> .ready written via atomic rename AFTER fragment
NOTIFY_WAKE  (after fragment — B2 ordering)
ARTIFACT_LOAD coherent=true fragment_depth>0  (NO fragment_depth=0 flap; .ready gate)
BF_SERVE_BLOCK  +  PROPAGATION_SEND  +  BF_TX   (served_block=true on wire)
ACCEPTANCE_VERDICT result=ADOPTED
CANONICAL_CONFIRMED
```

**Failure signatures to flag immediately:** `served_block=false`, `blockfetch_rx_total=0`, `loop_exit_reason=peer_disconnect`, `ARTIFACT_LOAD_NOT_READY` persisting, `ACCEPTANCE_VERDICT state=pending confidence=0`, any `FORGE_REFUSE` / `FORGE_SELF_VERIFY_FAIL` / `FORGE_BLOCK_ENVELOPE` reject.

### 3 external confirmation oracles
1. **cardano-cli tip:** `cardano-cli query tip` (preview magic) — the reported tip hash should equal TSUNAGI's forged `hash`. Block-#1 caveat: this is the authoritative on-chain check; it was never positively confirmed for block #1.
2. **cardano-node journal:** `journalctl` on the relay's cardano-node around the slot's UTC window — look for chainsync/blockfetch adoption of TSUNAGI's hash and the ABSENCE of `DeserialiseFailure` / invalid / reject for that header (block #1's hypothesized failure mode).
3. **Koios pool_blocks:** query Koios `pool_blocks` for the pool in the current epoch — the new block should appear within ~30–60s of forge if network-adopted.

A first network-accepted block requires **all three** oracles to agree: tip shows the hash, node journal shows adoption with no deserialise/reject, Koios lists the block.

---

## (5) Immediate post-first-block action — opcert 2nd-forge repeatability

**This is NOT a first-block blocker.** Block #1 forges correctly with the existing static `TSUNAGI_OPCERT_SIGMA_HEX` (signs seq=0). The defect blocks the SECOND forge and therefore Phase-1.5 repeatability (≥2 of next 3 elected slots), not the first.

**Mechanism:** after forge #1, `producer.zig` `OPCERT_INCREMENT` (~line 4280) bumps `dryrun_opcert_seq_no` 0→1 and persists `opcert_state.json`. The static `TSUNAGI_OPCERT_SIGMA_HEX` was signed for seq=0, so forge #2 rebuilds `sigma_msg` with seq=1 → `FORGE_SELF_VERIFY_FAIL ed25519_verify_failed`. The per-forge seq bump is itself the bug: a real Cardano operational certificate legitimately signs EVERY block in its KES window without bumping the cert sequence per block.

**Minimal fix (option b):** do NOT bump the opcert seq per forge — leave `dryrun_opcert_seq_no` stable across forges so the existing static sigma keeps verifying. This makes repeated forging work with no new sigma material.

**Constraints (per frozen-path policy):**
- PROPOSAL ONLY — the opcert/forge path is frozen; requires explicit operator unfreeze.
- One-time `opcert_state.json` reset to `{"seq_no":0}` after applying, so state matches the static sigma.
- Touches forge/crypto/opcert logic → out of scope for validation-only work; must be a separate, operator-authorized change AFTER the first block is confirmed on chain.

**Full proposal:** `/home/tsunagi/PROPOSAL_opcert_2nd_forge.md`.

---

## Appendix — honesty ledger (what is proven vs. modeled)

- **PROVEN OFFLINE (real imported sources, tests green):** era-7 round-trip & era-6 mis-route detection; `served_block=true` reached with correct 37-byte MsgBlock body; body-hash `header[7]` == blake2b256(served body) with tamper detection; 12/12 repro tests pass; committed `cbor_block_full` era-7 guard passes.
- **MODELED, NOT EXECUTED:** cardano-node's HFC `SerialiseHFC` per-era router (the era-6→Babbage→`DeserialiseFailure` step). TSUNAGI's own decoder is era-agnostic and cannot reproduce node-side rejection.
- **NOT TESTED OFFLINE (live-only):** `mux_bearer.sendSegment` socket transmission; real relay fetch of the body; `ACCEPTANCE_VERDICT=ADOPTED`; connection lifecycle against the live cardano-node; the live forged artifact's byte-identity under live nonce/sigma/KES.

**Bottom line:** Every root cause of the block-#1 orphan is closed in source with the strongest evidence obtainable offline. The deployed binary is GO. The first elected slot is the irreducible live test of the wire path; have all three oracles ready and watch for the failure signatures above.
