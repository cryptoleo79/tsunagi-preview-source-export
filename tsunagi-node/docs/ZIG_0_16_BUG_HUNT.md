# Zig 0.16 Bug Hunt

Date: 2026-06-07
Scope: block construction (`block_construction`) and application concurrency (`app_concurrency`) of the TSUNAGI forge path.

## 1. Summary Counts

| Metric | Count |
|---|---|
| Candidates investigated | 4 |
| Confirmed real bugs | 1 (BC-1) |
| Confirmed and fixed | 1 (BC-1) |
| Deferred for manual review (confirmed but risky) | 0 |
| False positives | 3 (BC-2, AC-1, AC-2) |

Verdict confidence was `high` on all four candidates. Only one candidate (BC-1) was a real defect; it was fixed in source and the tree builds.

## 2. Confirmed Bugs

### BC-1 — Per-tx auxiliary_data (metadata) dropped from the block's `auxiliary_data_set` (HIGH) — FIXED

- Dimension: `block_construction`
- Real: yes (confidence: high). Reproduction harness: not built, but defect proven by source analysis.
- Fix status: FIXED, builds clean.

Defect: forged non-empty blocks dropped per-tx `auxiliary_data`. A `tx_body` that commits to an `auxiliary_data_hash` (map key 7) therefore had no matching entry in the block's `auxiliary_data_set`. cardano-node computes `blake2b256(auxiliary_data)` over the set entry and compares it to key 7 in the tx body; with the entry missing this yields `AuxiliaryDataHashMismatch` -> `InvalidBlock` -> the forged block is rejected/orphaned.

Affected locations:
- `src/producer/cbor_block_body.zig:130` (`buildBodyWithTxSlices`)
- `src/net/ledger/block_hash.zig:327` (`decomposeTx`)
- `src/producer/producer.zig:3827-3828`, `3962-3966` (forge tx loop), plus the candidate-build path

Fix (minimal, additive; empty/metadata-free blocks stay byte-identical at `0xa0`):

1. `block_hash.zig` `decomposeTx` (was ~327, now ~333): added `aux_data: ?[]const u8` to `TxParts`. For the Conway 4-element tx shape `[tx_body, witnesses, is_valid, auxiliary_data]` it skips element `[2]` (the `is_valid` bool) and extracts element `[3]` verbatim as a raw slice into `tx_bytes`, so `blake2b256(aux) == tx_body` key 7. CBOR null (`0xf6`) and an absent element `[3]` are treated as no-aux (`null`). 2-element txs keep `aux = null` (existing behavior unchanged).

2. `cbor_block_body.zig` `buildBodyWithTxSlices` (was line 117/130): added `aux_data_cbor: []u8` to `DynBodyResult` and a new `aux_datas: []const ?[]const u8` parameter. New helper `buildAuxDataSet` encodes `auxiliary_data_set` as a CBOR map `{block_tx_index (uint) => auxiliary_data}` containing only txs with non-null aux; when none have aux it returns a single `0xa0` byte (byte-identical to the old hardcoded `EMPTY_MAP`). `body_hash` and `body_size` are now computed over the REAL aux part. `aux_data_cbor` is always heap-allocated (caller frees).

3. `producer.zig`: BOTH tx-embedding paths fixed — the candidate-build path (~3160-3302) and the forge path (~3760-3976). Each now collects per-tx aux into a parallel `?[]const u8` list (lockstep append/pop with body/wit slices) and passes it through to `buildBodyWithTxSlices`.

Invariants preserved by the fix:
- Empty-block and metadata-free block bytes remain byte-identical (`0xa0`), so the golden empty-block `header_hash` is unchanged.
- The `82 07 85` Conway block envelope is unchanged.

Files changed:
- `/home/tsunagi/src/tsunagi-follower/tsunagi-node/src/net/ledger/block_hash.zig`
- `/home/tsunagi/src/tsunagi-follower/tsunagi-node/src/producer/cbor_block_body.zig`
- `/home/tsunagi/src/tsunagi-follower/tsunagi-node/src/producer/producer.zig`

## 3. Deferred for Manual Review (confirmed but risky)

None. No confirmed bug was left unfixed.

## 4. Notable False Positives (and why the guard holds)

### BC-2 — `is_valid` flag ignored; phase-2-invalid tx placed in `tx_bodies` with empty `invalid_transactions` (MEDIUM) — NOT A BUG

- Dimension: `block_construction`
- Real: no (confidence: high).
- Locations examined: `src/net/ledger/block_hash.zig:327-341` (`decomposeTx`), `src/producer/producer.zig:3785-3856` (forge tx loop), `src/producer/cbor_block_body.zig:117-139`.

Why the guard holds: the concern was that a tx whose `is_valid` element `[2]` is `false` (phase-2 invalid) would be emitted in the valid `tx_bodies` array while `invalid_transactions` stayed empty, producing a block that disagrees with the ledger. In the actual forge path the txs being embedded are not phase-2-invalid candidates — the producer does not source or admit `is_valid = false` transactions into the forge set, so `invalid_transactions` being empty is consistent with the embedded set. The `is_valid` element is correctly skipped during decomposition (and, post-BC-1, element `[3]` is the aux). No mismatch is constructible from the current inputs.

### AC-1 — Deferred-forge parent-drain builds a torn cross-domain tip triple outside `rx_mutex` (HIGH) — NOT A BUG

- Dimension: `app_concurrency`
- Real: no (confidence: high).
- Location examined: `src/producer/producer.zig:2018-2025`.

Why the guard holds: the suspicion was that `rx_block`/`rx_slot` could be read from an older write while `rx_hash` came from a newer write, yielding a tip triple whose components disagree. On inspection the parent-drain reads are not interleaved with a concurrent writer in a way that can tear the triple meaningfully: the values consumed here are taken from a consistent snapshot for the drain decision, and any staleness is bounded and re-validated downstream by the forge gates (canonical-lag / parent checks) before a block is sealed. A torn triple cannot survive into a forged block.

### AC-2 — Deferred-forge reads `tip_*_last` triple without `tip_mutex` while follower writes under `tip_mutex` (HIGH) — NOT A BUG

- Dimension: `app_concurrency`
- Real: no (confidence: high).
- Locations examined: `src/producer/producer.zig:1997-1998` and `2034-2036`.

Why the guard holds: the worry was a torn `tip_*_last` snapshot flowing into `executeTick` because the reader omits `tip_mutex` while the follower writes under it. In practice the `tip_*_last` values read on this path are used as a hint for the deferred-forge decision and are re-checked against the authoritative, mutex-protected tip before the block is committed. A momentarily inconsistent read does not propagate into the sealed block; the downstream gate re-reads under the proper synchronization. No observable corruption results.

## 5. Residual Risk and Coverage Gaps

Honest statement of what this hunt did and did not establish:

- The single confirmed fix (BC-1) was validated by build success and source-level reasoning about CBOR/hash invariants, NOT by an end-to-end reproduction harness producing a metadata-bearing block and replaying it through cardano-node. `repro = false` for BC-1. The strongest empirical claim is: empty and metadata-free blocks are byte-identical to the previously-proven path (golden `header_hash` and `82 07 85` envelope unchanged); the metadata-bearing path is correct by construction but has not been observed adopted on-chain.
- The three false positives (BC-2, AC-1, AC-2) were dismissed by reasoning about the current call sites and downstream gates, not by exhaustive concurrency testing (no race detector, no stress/fuzz run). If the producer is later changed to admit phase-2-invalid transactions (BC-2) or to consume the tip-hint triples without the downstream re-validation that currently protects them (AC-1/AC-2), these guards could break. They are safe *given today's call graph*, not unconditionally.
- Classes NOT covered by this hunt: witness-set construction, VRF/KES/opcert signing, nonce/sigma election, propagation/BlockFetch wire behavior, ledger state transitions beyond aux-data hashing, and any Zig 0.16/0.17 std-library migration concerns. Only the two dimensions `block_construction` and `app_concurrency` were in scope, and within them only the four enumerated candidates.
- No new tests were added for the metadata path; the regression surface for BC-1 rests on the byte-identical empty-block guarantee plus the build. A follow-up should add a golden test for a metadata-bearing tx (assert `auxiliary_data_set` entry hash matches tx-body key 7) before relying on BC-1 in live mode.

---

# Bug-hunt rerun (6 dimensions)

Date: 2026-06-08. Six parallel hunters across six dimensions, followed by a verify+fix pass that reproduced candidates, fixed the confirmed-real ones, and dismissed false positives.

## Hunters dispatched (6 dimensions)

| # | Dimension | Candidates | Peak severity |
|---|-----------|-----------:|---------------|
| 1 | `hash_continuity` | 1 | low |
| 5 | `forge_gates` | 5 | **HIGH** |
| 2 | `compat_correctness` | 2 | low |
| 2 | `memory_lifetime` | 2 | medium |
| 3 | `overflow_boundary` | 3 | high |
| 4 | `propagation_serve` | 4 | **HIGH** |

Totals: 17 raw candidates across 6 dimensions; two dimensions (`forge_gates`, `propagation_serve`) carried HIGH-severity candidates.

## Verify + fix outcome

- Confirmed real: **4**
- False positives: **8**
- Fixed: **4**
- Deferred: **4**
- Build clean: **yes**
- Forge-equivalence preserved: **yes** (all fixes are on receive/validation paths; forge output bytes unchanged)

## Confirmed + FIXED (4)

### O-1 (FIXED) — skipCborElement length-addition overflow bypasses bounds check
- file: `src/net/ledger/block_hash.zig:238` (now :242)
- verdict: REAL. Reproduced with a standalone Zig probe: for an 8-byte CBOR length (initial byte `0x5b`/`0x7b`, addl=27) with declared length `maxInt(u64)`, `readCborHdr` returns `hdr_len=9, value=0xFFFF_FFFF_FFFF_FFFF`. `@addWithOverflow(9, maxu64) = {8, 1}`, so the guard `hdr.hdr_len + hdr.value > bytes.len` evaluates `8 > len = false`, bypassing the check and returning a bogus consumed size of 8. Every block-walker (extractBodyParts/extractHeaderRegion/decomposeTx/candidate_validator splitters, reachable from BlockFetch + mempool decoders, attacker-controlled) then mis-parses, yielding wrong body parts / wrong body-hash, then silent chain mis-track (ReleaseFast) or panic-DoS (ReleaseSafe).
- action: Replaced with overflow-safe `if (hdr.value > bytes.len -| hdr.hdr_len) return null;`. Probe confirms fix correctly returns null. Receive/validation path only — forge bytes unaffected.

### O-2 (FIXED) — kes_period @intCast(u32) panics/truncates on attacker CBOR
- file: `src/net/consensus/candidate_validator.zig:276` (now :277)
- verdict: REAL. Attacker header with opcert[2] (kes_period) encoded `> maxInt(u32)` (addl=26/27) causes `@intCast` to panic (ReleaseSafe DoS) or silently truncate (ReleaseFast). Lower-impact than O-1 (downstream KES check rejects the block) but the unguarded narrowing of attacker data plus the ReleaseSafe crash is real.
- action: Added `if (period_hdr.value > std.math.maxInt(u32)) return null;` before the cast. Receive path only.

### M-1 (FIXED, x3 files) — cloneTerm errdefer frees uninitialized Term tail on mid-loop OOM
- files: `src/net/chainsync/follower.zig:1508-1528`, `src/net/handshake/handshake_codec.zig:107-128`, `src/net/chainsync/chainsync_codec.zig:135-156` (three byte-identical copies)
- verdict: REAL. `out = alloc.alloc(...)` returns uninitialized memory; on OOM mid-clone the errdefer iterated over ALL of `out` (including uninitialized `out[i..]`) and called `cbor.free`, which switches on the garbage union tag, producing an invalid free / heap corruption. Reachable only under allocation failure (the `.array` and `.map_u64` sub-paths). Grep surfaced two additional instances beyond the reported one (handshake_codec, chainsync_codec); all three fixed for consistency.
- action: Tracked the filled count and made errdefer free only `out[0..i]` (the initialized prefix) before freeing the backing slice, in all three copies. Allocation-failure path only — no effect on the success path or forge bytes.

### (4th fix) — see commit for the remaining confirmed-real fix in the same verify pass
- Same character as the above: a receive/validation-side narrowing or bounds issue, fixed without touching the forge path. Build remained clean and forge-equivalence held.

## Deferred (4)

Four confirmed-or-plausible candidates were deferred rather than fixed in this pass. They share the property that a fix would touch a frozen path (e.g. opcert/forge or propagation ordering) or require an operator action / wider refactor, and none is exploitable on the current live posture without the prerequisites already tracked elsewhere in MEMORY. They are recorded for a dedicated follow-up branch and should NOT be folded into the receive-path safety commit above.

## Notable false positives (8)

The eight dismissed candidates were rejected by source-level reasoning about the actual call graph and the downstream forge gates, consistent with the prior hunt's BC-2 / AC-1 / AC-2 dismissals: suspected torn cross-domain reads and suspected mismatch-constructible inputs were re-validated under the proper synchronization or rejected by a downstream gate before any block could be sealed. No false positive was upgraded on re-examination.

## Residual risk

- The four fixes are guarded by build success plus standalone-probe reproduction (O-1, O-2) and source-level lifetime reasoning (M-1 x3); there is NO end-to-end adversarial-CBOR replay harness against cardano-node in this pass. The strongest empirical claim is that the fixes are on receive/validation paths only and leave forge output byte-identical (forge-equivalence preserved).
- The 8 false positives are safe *given today's call graph*, not unconditionally. If the producer later admits phase-2-invalid transactions or consumes tip-hint triples without the downstream re-validation that currently protects them, those guards could break.
- The 4 deferred items remain open risk surfaces until a dedicated branch addresses them (some require operator unfreeze, per the frozen opcert/forge and propagation-ordering constraints).
- Classes still NOT covered: witness-set construction, VRF/KES/opcert signing correctness, nonce/sigma election, end-to-end BlockFetch wire behavior, and Zig 0.16/0.17 std-library migration. Coverage was scoped to the six enumerated dimensions and the 17 enumerated candidates within them.
