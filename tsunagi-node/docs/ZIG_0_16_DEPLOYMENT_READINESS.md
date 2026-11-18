# TSUNAGI on Zig 0.16 — Deployment-Readiness Report (Relay Producer)

**Date:** 2026-06-07
**Scope:** Migration of `tsunagi-node` from Zig 0.15.2 to Zig 0.16.0, assessed for use as a relay/producer node.
**Toolchain:** `/home/tsunagi/opt/zig-x86_64-linux-0.16.0/zig` (reports `0.16.0`).
**Baseline (acceptance) tree:** `/home/tsunagi/zig016-equiv/baseline-0.15.2/tsunagi-node` (Zig 0.15.2).
**Migrated tree:** `/home/tsunagi/src/tsunagi-follower/tsunagi-node` (Zig 0.16.0).
**HARD RULE observed throughout:** validation only; no forge/crypto/threshold/nonce/VRF/KES/opcert/CBOR logic was modified; no live keys or network used; probe files cleaned up.

---

## 1. Executive Verdict

**Is Zig 0.16 byte-equivalent on the forge path? — PARTIAL (proven where it counts; one dimension is DEFERRED for lack of a corpus).**

The forge **output** path is byte-equivalent and **PROVEN** across the two toolchains by construction with fixed golden inputs: candidate header body CBOR, full block envelope (and its Blake2b256), VRF output, and the Praos leader threshold all matched bit-for-bit between the 0.15.2 baseline binary and the 0.16 migrated binary. The Conway era tag is 7 in both trees and the envelope prefix `82 07 85` (`PREFIX_OK=true`) is confirmed in both.

The migration is, by audit, a **pure compat-shim swap**: the changed files contain only `std.*` → `compat.*` API substitutions and `const`→`var` handle aliasing. A filtered diff scan found **zero added lines outside known compat patterns** — specifically **no** threshold, nonce, sigma, VRF, KES, opcert, or CBOR-value change. The four forge-marker-emitting code blocks in `producer.zig` (`forgeInternalGate`, `logForgeGate`, `FORGE_SELF_VERIFY`, `FORGE_BLOCK_ENVELOPE_OK`) are **byte-identical** between baseline and migrated trees.

**What is NOT proven:** end-to-end **runtime** equivalence of the four live forge markers (`EVENT_LEADER_DETECTED`, `FORGE_GATE_DECISION`, `FORGE_SELF_VERIFY`, `FORGE_BLOCK_ENVELOPE_OK`) emitted from a real elected slot. No forge-decision replay corpus exists, and the HARD RULE forbids driving the live forge loop (which requires live KES keys/opcert/ledger sigma/network tip). Runtime equivalence rests on the **source-diff identity** of the marker-emitting blocks plus the proven output equivalence — strong circumstantial evidence, but **not a live runtime A/B**.

**Bottom line:** The 0.16 binary is a credible **parallel-track** candidate. It is **not** authorized as the acceptance/deployment binary. The 0.15.2 Variant B binary remains the sole acceptance binary (see §6).

---

## 2. Equivalence Matrix

| Dimension | Status | Evidence |
|---|---|---|
| **header_body** | **PROVEN** | `cbor_block_header_body.zig` byte-identical across both trees (diff). Both toolchains emitted `EQ_HEADER_BODY_LEN=407` and the identical full 814-char hex string (verified equal byte-for-byte). Uses only `std.mem.writeInt` + stack buffers — no version-sensitive APIs. |
| **full_envelope** | **PROVEN** | All emitted fields byte-identical between baseline 0.15.2 and migrated 0.16. `CONWAY_BLOCK_ERA_TAG=7` in both; prefix `82 07 85` (`PREFIX_OK=true`). Header CBOR = `82` + raw header_body + `5901c0` (bstr len 448) + KES sig; `header_hash=edec1023…dbc37f` matched; full envelope blake2b256 `620e2116…37ef5c` matched. `assembleHeader`/`assembleFullBlock` are pure byte-assembly + Blake2b256, no compat-affected paths. Fixed golden inputs; no live keys/network. |
| **vrf_output** | **PROVEN** | `sodium_vrf.zig` byte-identical (diff) + empirically confirmed identical VRF outputs. `SK` (PK embedded in upper 32 bytes), `PROOF`/`BETA`/verify-output/`proof_to_hash` all matched bit-for-bit; `PK=8a88e3dd…6f5c` derived under both. Two inconsequential spec deviations, applied equally to both toolchains: seed is 32 bytes (actual `SEEDBYTES=32`, `keypairFromSeed` takes `*const [32]u8`), and `-lc` had to accompany `-lsodium` to avoid a libc-init segfault (link/env detail, not logic). |
| **praos_threshold** | **PROVEN** | `computeThresholdX1e12` is a pure function of `(sigma_x1e9, asc_x1e6)` via E34 fixed-point `ln'`/`exp'`; no VRF/u input of its own. Probe supplied `u` and compared against the x1e12 threshold (exercising the caller's leader comparison too). Equivalent across toolchains. |
| **kes_sign** | **PROVEN (verify-path) / partial (sign-path inferred)** | `verify_forged.zig` KES-verify + Blake2b256 logic untouched (only stdout/openFile/`const`→`var` compat swaps). KES signature bytes are part of the proven `full_envelope` (header CBOR includes `kes_sig`, `header_hash` matched). The **signing** call itself was not independently A/B-run against a live KES key (HARD RULE), but `kes.zig` changes are confined to env/file/perms compat swaps with no signing-math change. |
| **opcert_ed25519** | **PARTIAL / NOT independently A/B-tested** | The opcert/ed25519 `FORGE_SELF_VERIFY` marker block in `producer.zig` is byte-identical across trees (source diff). No live ed25519 opcert self-verify was executed under both toolchains (requires live opcert + the forbidden live forge loop). Equivalence is inferred from source identity, **not** proven by a live run. NOTE: opcert self-verify is independently subject to the 0.15.2-era 2nd-forge seq-bump blocker (see MEMORY); that is orthogonal to the toolchain. |
| **perm_gate** | **PROVEN (semantics) — small API delta noted** | Permission gate migrated from `stat.mode & 0o077` to `stat.permissions.toMode() & 0o077` at `vrf.zig:132`, `kes.zig:77`, `keys.zig:203`. Same `& 0o077` "group/other must be zero" check. Delta is purely the 0.16 API shape (`Permissions.toMode()` replacing the raw `mode` field); the masked comparison is identical. Verified by inspection of all three call sites. |
| **runtime markers** | **DEFERRED (NOT proven by live run)** | The four live forge markers were **not** replayed. **No forge-decision replay corpus exists.** Existing replay infra (`src/replay/replay.zig`, `replay_run_cmd.zig`, `src/replay/capture.zig`, `src/ledger/replay_harness.zig`) replays BlockFetch/UTxO payloads (`[u32le len][raw block bytes]`) for **ledger determinism only** — it does **not** emit the four forge markers. Those markers fire solely inside `producer.zig`'s live forge loop on a live `ProducerContext`, which the HARD RULE forbids exercising. Evidence is two-layer and positive but indirect: (1) source diff — the four marker-emitting blocks are byte-identical baseline↔migrated; (2) the proven output equivalence above. **This is the single open equivalence gap.** |

**Summary count:** PROVEN ×5 (header_body, full_envelope, vrf_output, praos_threshold, perm_gate) + kes_sign verify-path proven; PARTIAL/inferred ×2 (kes_sign sign-path, opcert_ed25519); DEFERRED ×1 (runtime markers).

---

## 3. What Remains Before a 0.16 Relay Deployment (Checklist)

- [ ] **Build a forge-marker replay corpus.** Capture (or synthesize from golden inputs) slot-decision inputs sufficient to drive `EVENT_LEADER_DETECTED`, `FORGE_GATE_DECISION`, `FORGE_SELF_VERIFY`, `FORGE_BLOCK_ENVELOPE_OK` deterministically **without** a live network/key. Run under both toolchains and diff markers. (Closes the one DEFERRED dimension.)
- [ ] **Live ed25519 opcert self-verify A/B.** Execute `FORGE_SELF_VERIFY gate=opcert` under both toolchains with a (test or controlled) opcert and confirm identical pass/sigma. (Upgrades opcert_ed25519 from inferred to proven.)
- [ ] **Live KES sign A/B.** Sign one fixed header body under both toolchains with the same KES key and confirm identical signature bytes. (Upgrades kes_sign sign-path.)
- [ ] **Network hot-path soak under 0.16.** Run the migrated binary as a relay (preview, MODE=preview_safe) long enough to exercise NtN/NtC handshakes, chainsync, and BlockFetch through the persistent-buffer `streamProtoReader/Writer` adapters under sustained traffic. Confirm zero framing/desync errors.
- [ ] **Confirm clean build is reproducible.** `BUILD_EXIT=0` producing `tsunagi-node`, `praos-verify` (a.k.a. plutus tools), `plutus-evaluator`, `tsunagi-slot-index-reset`. (Already observed once after compat scaffolding removal — re-verify on a clean checkout.)
- [ ] **Pin the exact 0.16 binary and record fingerprints** (md5/sha256) before any deploy, mirroring the milestone discipline used for the 0.15.2 binaries.
- [ ] **Operator authorization.** Deployment is operator-gated; the live forge/opcert path is currently frozen (see MEMORY blockers). No deploy without explicit unfreeze + authorization.

---

## 4. Exact Risks

### 4.1 Per-call buffered readers on network/stdin (HIGH-attention, currently MITIGATED on the hot path)
- 0.16's `std.Io.Reader` is buffered. The per-call adapter `compat.StreamReader.read` (and `readByte`/`readNoEof`/`readBytesNoEof`) **spins up a fresh 4096-byte `Io.Reader` on every call** (`src/compat.zig` ~L322–360). Any bytes buffered-but-unconsumed by one call would be **discarded** before the next — this is **only safe for a single read or a one-shot drain**.
- **Mitigation in place:** the Cardano wire hot paths use the **persistent-buffer** adapters, not the per-call ones:
  - `src/net/transport/tcp_byte_transport.zig:73–74` → `streamProtoReader`/`streamProtoWriter`
  - `src/net/ntc/unix_byte_transport.zig:67–68` → `streamProtoReader`/`streamProtoWriter`
  - These hold a single underlying `Io.Reader` so multi-message protocol framing does not lose buffered bytes.
- **Residual risk:** the per-call `compat.streamReader` is still used in `src/cli/trust_snapshot_cmd.zig:719` and `:1739`. This is a **CLI command path, not the forge/wire hot path**, but it relies on each `read` being effectively single-shot/drain-to-EOF. If any code there assumes streaming continuity across multiple `read` calls, it can silently drop bytes. **Unverified under load** — flag for the soak test.
- **stdin:** no evidence of a multi-read stdin streaming consumer in the forge path was found; file reads go through `readToEndAlloc` (one-shot). Treat any future per-call stdin streaming as the same hazard class.

### 4.2 `permissions.toMode()` delta (LOW)
- `stat.mode & 0o077` → `stat.permissions.toMode() & 0o077` at `vrf.zig:132`, `kes.zig:77`, `keys.zig:203`. The mask and the "no group/other bits" rejection are identical; the only change is the 0.16 API shape. Risk is limited to a future 0.16 `Permissions`-representation change; **no behavioral delta today**, verified by inspection.

### 4.3 VRF link detail (LOW — environmental, not logic)
- libsodium must be linked with `-lc` alongside `-lsodium` (else `sodium_init()` segfaults on libc runtime init). Applied equally to both toolchains. Ensure the 0.16 `build.zig` link flags carry `-lc`. Environmental, not a forge-logic risk.

### 4.4 Unproven dimensions (HONEST)
- **runtime forge markers** — DEFERRED; no live A/B (see §2 / §3).
- **live opcert ed25519 self-verify** — inferred from source identity only; NOT live-tested.
- **live KES signing** — sign-path inferred; only the verify-path and the resulting signature-in-envelope are proven.
- These are **NOT proven** and must be marked as such in any go/no-go decision.

### 4.5 Orthogonal (not a toolchain risk)
- The opcert 2nd-forge seq-bump repeatability blocker and the live forge/opcert freeze are **independent of the Zig version** and apply equally to 0.15.2 and 0.16. They are not introduced or fixed by this migration.

---

## 5. Verification Plan to Close the Gaps

### 5.1 Reproduce the proven output equivalences (fixed golden inputs, no network/keys)
- header_body / full_envelope: rebuild both trees and re-run the envelope probe; assert `EQ_HEADER_BODY_LEN=407`, prefix `82 07 85`, `header_hash=edec1023…dbc37f`, envelope blake2b256 `620e2116…37ef5c`.
- vrf_output: rebuild the VRF probe with `-lsodium -lc`; assert `PK=8a88e3dd…6f5c` and bit-identical `PROOF`/`BETA`/`proof_to_hash` across toolchains.
- praos_threshold: re-run the pure-function probe over the same `(sigma_x1e9, asc_x1e6, u)` triples; assert identical x1e12 thresholds and identical leader comparison.
- Tooling: build with `/home/tsunagi/opt/zig-x86_64-linux-0.16.0/zig build` (migrated) and the 0.15.2 toolchain (baseline at `/home/tsunagi/zig016-equiv/baseline-0.15.2/tsunagi-node`). `BUILD_EXIT` must be 0 for both.

### 5.2 Build the MISSING runtime forge-marker corpus (closes the DEFERRED dimension)
- The existing replay infra only replays ledger payloads (`[u32le len][raw block bytes]`) and does **not** emit forge markers. Build the smallest honest harness that feeds a **fixed, golden `ProducerContext` snapshot** (frozen KES key material, opcert, ledger sigma, nonce, and a captured network tip) into the marker-emitting blocks — **without** opening sockets or touching live keys.
- Capture the four markers (`EVENT_LEADER_DETECTED`, `FORGE_GATE_DECISION`, `FORGE_SELF_VERIFY`, `FORGE_BLOCK_ENVELOPE_OK`) under both toolchains and `diff` them line-for-line.
- Acceptance: markers byte-identical baseline↔migrated for ≥1 leader slot and ≥1 non-leader (missed) slot.

### 5.3 Live-key A/B (gated, controlled environment only)
- KES sign: sign one fixed header body under both toolchains, same key; `diff` signature bytes.
- opcert ed25519: run `FORGE_SELF_VERIFY gate=opcert` under both toolchains; assert identical `pass`/`seq`/`period`/`sigma_first8`.

### 5.4 Network hot-path soak
- Deploy migrated binary on preview in `MODE=preview_safe`; run through ≥1 epoch of chainsync + BlockFetch. Watch for framing/desync/`peer_disconnect` regressions attributable to the reader adapters. Confirm `streamProtoReader/Writer` carry sustained multi-message traffic with no dropped bytes.
- Also exercise `trust_snapshot_cmd` (the per-call `streamReader` consumer) under realistic input to confirm no silent byte loss.

### 5.5 Compat-debt confirmation (already applied — re-verify)
- Dead scaffolding `src/compat/io_compat.zig` and `src/compat/proc_compat.zig` deleted; `src/compat/` is now empty (verified: directory contains no `.zig` files). Real shim is `src/compat.zig`.
- Re-run the import check: `grep -rn 'io_compat|proc_compat' src --include=*.zig | grep -v 'src/compat/'` must return empty.
- `compat.DebugAllocator` alias inlined to `std.heap.DebugAllocator` at its test call sites (test-only; no runtime path).

---

## 6. Rollback Posture

- **Acceptance binary remains the Zig 0.15.2 Variant B build.** Per MEMORY, the 0.15.2 Variant B binary (authoritative active-stake sigma resolver, carrying all three fixes — era-tag, sigma-drift gate, election sigma sync; sha256 `eade3e8ed357e23cc0d882e6cb605c334c9f1315fb47f7a1bc82f01ac7e1ffc1`) is the campaign acceptance binary. **0.16 is parallel-track only.**
- **0.16 is NOT authorized for production forge/deploy.** It is a validation/portability track. Promotion requires: closing the runtime-marker corpus gap (§5.2), the live KES/opcert A/B (§5.3), a clean soak (§5.4), and explicit operator authorization (the live forge/opcert path is currently frozen).
- **Rollback is trivial because nothing 0.16 is deployed.** No relay touch is implied by this report. If a 0.16 parallel-track relay is ever stood up for soak, rollback = stop the 0.16 process and restore the 0.15.2 Variant B binary; no state migration is involved (the migration changed no on-disk formats — only `std.*`→`compat.*` API call shapes).
- **Prior rollback chain remains intact** for the 0.15.2 line (live-candidate `0bf9e62` → `20cd57a` preview_safe baseline), independent of this 0.16 work.

---

## Appendix A — Compat Migration Surface (audited)

Changed files (all "behavior_risk: none" per the source-identity audit; only `std.*`→`compat.*` swaps + `const`→`var` handle aliasing + `result.Exited`→`result.exited` + deprecated reader API replacement):
- `src/producer/producer.zig` — ~260-line diff, all compat swaps; **zero added lines outside known compat patterns**; no threshold/nonce/sigma/VRF/KES/opcert/CBOR-value change.
- `src/producer/crypto/verify_forged.zig` — stdout/openFile compat; KES verify + Blake2b256 untouched.
- `src/producer/crypto/verify_vrf.zig` — stdout/openFile compat; `sodium_vrf` + Blake2b256 unchanged.
- `src/producer/vrf.zig` — env/file compat; perm check `mode & 0o077` → `permissions.toMode() & 0o077`; no VRF proof/seed math change.
- `src/producer/nonce_evolution.zig` — fs/getenv/timestamp/Mutex/Child compat; `result.Exited`→`result.exited`; Blake2b256 nonce-evolution math unchanged.
- `src/producer/kes.zig` — env/file/perms compat; signing math unchanged.
- Network transports use persistent-buffer adapters (`tcp_byte_transport.zig`, `unix_byte_transport.zig`).

Compat-debt resolved: `src/compat/io_compat.zig` and `src/compat/proc_compat.zig` deleted (dead scaffolding, no external importers); `src/compat/` empty; `compat.DebugAllocator` test alias inlined. Clean rebuild observed with `BUILD_EXIT=0` producing `tsunagi-node`, `praos-verify`, `plutus-evaluator`, `tsunagi-slot-index-reset` (all four present in `zig-out/bin`).

## Appendix B — Honesty Ledger (what is NOT proven)

1. **Runtime forge markers** — NOT proven by live run; DEFERRED for lack of a forge-decision corpus. Inferred from byte-identical source + proven output equivalence.
2. **Live opcert ed25519 self-verify** — NOT independently A/B-tested; inferred from source identity.
3. **Live KES signing call** — sign-path NOT independently A/B-tested; verify-path and signature-in-envelope are proven.
4. **Per-call `streamReader` under sustained/multi-read CLI load** — NOT verified; mitigated on the hot path by persistent-buffer adapters, but the `trust_snapshot_cmd` consumers are unverified under load.
