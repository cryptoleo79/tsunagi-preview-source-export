# TSUNAGI — Zig 0.16.0 Production Sign-Off

**Date:** 2026-06-07
**Subject:** Final production sign-off for the migration of `tsunagi-node` (Cardano preview block-producer) from Zig 0.15.2 to Zig 0.16.0 via the compat shim.
**Build under sign-off:** branch `chore/zig-0.16-migration-2026-06-07`, commit `358297b76604e7cd70b33f6f50bef60a939491c5`, `dirty=0` (binary self-report).
**Toolchain:** `/home/tsunagi/opt/zig-x86_64-linux-0.16.0/zig`, version **0.16.0**, target `x86_64-linux.5.15...5.15-gnu.2.35`.
**Reference toolchain:** `/home/tsunagi/opt/zig-x86_64-linux-0.15.2/zig`, version 0.15.2.

---

## 1. Executive verdict

**PRODUCTION-READY: CONDITIONAL (GO for parallel-track / preview soak; NOT yet authorized as the sole acceptance/forge binary).**

The Zig 0.16.0 build is **runtime-correct** for everything that can be proven on this host without the live forge path:

- It **builds clean** in ReleaseSafe and Debug.
- It **passes the entire test suite** (1482 tests, 0 failures) including the 4 previously-failing `propagation_server` coherence tests, which were root-caused and fixed.
- It performs **real socket protocol I/O end-to-end** against a live Cardano preview peer (handshake → keepalive → chainsync header sync → BlockFetch body decode), with **0 panics / 0 EAGAIN panics / 0 core dumps** over a full 120 s run.
- The `std.Io.Threaded.global_single_threaded.io()` concurrency model used by the compat shim is **proven safe** for all operation classes the shim invokes from multiple OS threads.
- The **forge byte-path is PROVEN equivalent** to 0.15.2 across all 7 dimensions (header body CBOR, full block envelope + Blake2b256, VRF output, Praos leader threshold, era tag, prefix, KES sig assembly).

**Why CONDITIONAL and not unconditional GO:**

| Gating item | Status | Why it gates full production authorization |
|---|---|---|
| **G1 — Live elected-slot forge under 0.16** | OPEN (cannot be proven on this host) | No block has been forged and network-adopted by the 0.16 binary. The forge loop requires live keys + an elected slot + the operator-frozen forge path. Byte-equivalence is proven by construction with golden inputs, but a live `FORGE_PROMOTE_ATOMIC → PROPAGATION_SEND → ACCEPTANCE_VERDICT=ADOPTED` under 0.16 has **not** been observed. |
| **G2 — opcert ed25519 self-verify under 0.16** | OPEN (inferred, not A/B run) | The `FORGE_SELF_VERIFY` opcert/ed25519 path is byte-identical in source across both trees, but no live ed25519 opcert self-verify was executed under 0.16 (needs live opcert + the forbidden live forge loop). Equivalence is **inferred from source identity**, not demonstrated by a live run. |
| **G3 — Multi-hour soak under 0.16** | OPEN | Longest proven continuous 0.16 network run is 120 s (live-sync test). No multi-hour / multi-epoch soak has been run to surface slow leaks, fd exhaustion, or epoch-boundary behavior under the new `std.Io` call shapes. |

These gating items are **independent of the toolchain quality** — G1/G2 are blocked by the operator-frozen live-forge path (the same freeze that applies to 0.15.2), and G3 is simply a soak that has not yet been run. None of them indicates a defect found in the 0.16 build.

**Bottom line:** The 0.16 binary is authorized as a **parallel-track / preview-soak candidate**. The **Zig 0.15.2 "Variant B" build remains the sole acceptance/forge binary** until G1 (live adopted block under 0.16) and ideally G3 (soak) are closed. Promotion of 0.16 to acceptance binary requires the operator to (a) unfreeze the forge path for a controlled 0.16 elected-slot test and (b) accept the soak result.

---

## 2. Runtime-correctness evidence matrix

| Dimension | Verdict | Evidence (this host, this campaign) |
|---|---|---|
| **Concurrency (global Io thread-safety)** | **SAFE** | `std.Io.Threaded.global_single_threaded.io()` returns a **comptime-constant vtable** (`Threaded.io()` builds `&.{...}` of static fn pointers — reentrant, no per-call shared-state construction). The `single_threaded` name denotes an *instance carrying no worker-pool/async machinery*, **not** an unsafe synchronous vtable. The blocking syscall vtable fns are stateless-per-call: compat creates a **fresh on-stack `File.Reader`/`Writer` per call** and the underlying op reads/writes through a fresh on-stack buffer. Safe to call concurrently from many OS threads for every class the shim uses on Linux: file read/write/open/create/close/seek/stat/sync, clock/time, net connect, and `Mutex`/futex. |
| **Net fragmented-read / over-read retention** | **CORRECT** | Full audit of every socket read in `net/transport`. The only real-socket reader, `src/net/transport/tcp_byte_transport.zig`, uses a **persistent** `compat.StreamProtoReader` bound to a connection-lifetime `impl.read_buf[4096]` created **once at connect** (line 73). `readAtMost` → `proto_reader.read` → `Io.Reader.readSliceShort` drains the persistent buffer first and **retains kernel over-read surplus** (`NetStream.Reader.readVec` does `r.interface.end += n - data_size`). The Cardano mux path (`mux_bearer.zig recvSegment`: 8-byte header then `hdr.len` body via `readExactOrNull`) correctly depends on the persistent reader for its length-prefix-then-body two-read pattern — **no truncation, no over-read loss**. Verified subtlety: 0.16 `NetStream.Reader.readVec` recovers `*Reader` via `@fieldParentPtr("interface", io_r)` at call time, so the reader must not move after init; it lives inside the heap-allocated, address-stable `TcpByteTransportImpl` and is only ever invoked through that stable pointer. |
| **Live-sync (real protocol I/O)** | **PASS (with fixes)** | Connected to live Cardano preview peer `152.53.152.172:6000` (network_magic=2). Markers observed: `PRIMARY_HANDSHAKE_OK`; `KEEPALIVE: rx pong`; `PRIMARY_INTERSECT_FOUND tip_slot=114203516`; RollForward header sync advanced `4358847→4358855` (followed live tip); `BLOCKFETCH: full request` (8 requests, 10 bodies decoded); body `era=6 bytes=857 blake2b256=24739b2f…` matched the cursor header hash (body verified). **0 panics, 0 EAGAIN panics, 0 core dumps over 120 s.** Read-only preview_safe (no keys): 0 forge/broadcast markers, as expected. |
| **ReleaseSafe build** | **PASS** | `zig build -Doptimize=ReleaseSafe` exits 0, no diagnostics. Binary runs; `--version` self-reports `ReleaseSafe x86_64-linux-gnu zig=0.16.0 dirty=0`. |
| **Test suite** | **PASS — 1482/1482** | `zig build test --summary all`: 36 test binaries, **1482 tests, 0 failures** (measured this run; supersedes the earlier 1306/1310 and 1479 snapshots as tests were added during hardening). The 4 historical `propagation_server` coherence failures are **fixed**, not skipped (see §3). |
| **Forge byte-path** | **PROVEN equivalent** | All 7 dimensions byte-identical vs 0.15.2 baseline with fixed golden inputs (see §5). No compat-affected code on the byte-assembly path. |
| **stdin / interactive hardening** | **FIXED** | Real over-read bug in compat stdin path found and fixed (see §3). |

---

## 3. What changed this campaign

Diff vs the migration base (`git diff --stat`): **17 files, +622 / −303**. No on-disk format changed — only `std.*` → `compat.*` API call shapes plus targeted runtime fixes and added tests.

**Compat shim**
- `src/compat.zig` (+129): consolidated the fs/net/time/Mutex shims routing through `std.Io.Threaded.global_single_threaded.io()`. Removed the split files `src/compat/io_compat.zig` (−127) and `src/compat/proc_compat.zig` (−139), folding them in.

**Runtime bug fixes (non-forge)**
- **stdin over-read fix (CONFIRMED real bug, FIXED).** In 0.16, `compat.fs.stdinReader()` returned a fresh struct per call; `File.read` for streams builds a **new** `Io.File.Reader.initStreaming` with a fresh stack `[4096]u8` on every call. `readVecStreaming` over-reads kernel surplus into that internal buffer (`r.interface.end += n - data_size`), and with a per-call reader the surplus is **discarded on return** — so a 1-byte `readByte` over a cooked TTY/pipe pulls the whole line (incl `\n`) into a throwaway buffer and loses everything past the first byte, breaking every multi-read interactive line consumer. Audited 4 interactive stdin consumers; `src/cli/console_cmd.zig` `readLine()`/`confirm()` were affected (lost `\n` / double-Enter / desync) and were re-routed through a persistent reader. Fixed.
- `src/net/propagation_server.zig` (+15) and `src/cli/view.zig`, `src/cli/correlation_export.zig`, `src/net/ledger/utxo_store.zig`, `src/tools/praos_verify.zig`: 0.16 std API adjustments (e.g. `std.json.ObjectMap.init` 3-arg signature, JSON/IO call-shape updates). The transient `view.zig:1517` compile error noted mid-campaign is **resolved** — the final ReleaseSafe build is clean.

**Net/transport**
- `src/net/transport/tcp_byte_transport.zig` (+31): persistent-reader correctness confirmed/cemented for the fragmented-read path (see §2).

**Tests added (this is most of the +622)**
- New: `src/compat_concurrency_test.zig`, `src/http_metrics_fragmentation_test.zig`, `src/mux_fragment_tests.zig`, `src/ntc_fragmented_read_tests.zig`, `src/serve_loop_fragmented_read_tests.zig`; expanded `src/byte_transport_tests.zig` (+335). These exercise the concurrency model and fragmented/over-read read paths that the migration most affected.
- **4 pre-existing `propagation_server` coherence test failures fixed.** Root cause: the 4 fixtures called `loadArtifactSnapshot(alloc, test_dir, 0)` expecting non-null, but `loadArtifactSnapshotEx`'s first action (the two-phase-publication guard) does `compat.fs.cwd().access(art_dir/.ready)` and returns null if the `.ready` sentinel is absent. The fixtures built a complete artifact dir but never wrote `.ready`, so the loader bailed **before** reaching the coherence logic the tests meant to exercise → null → `expect(result != null)` failed. Fixed by having the fixtures write the `.ready` sentinel (matching the real producer's two-phase commit). This is a **test-fixture fix, not a logic change** — the guard behavior is correct and unchanged.

**Nothing in forge/crypto/threshold/VRF/KES/opcert/CBOR logic was changed.** Forge byte output remains equivalent (see §5).

---

## 4. Residual risks (ranked)

| # | Rank | Risk | Confirmable only by | Mitigation |
|---|---|---|---|---|
| R1 | **HIGH** | **No live network-adopted block forged under 0.16** (gating item G1). Byte-equivalence is proven with golden inputs, but the full live chain `FORGE_PROMOTE_ATOMIC → PROPAGATION_SEND → ACCEPTANCE_VERDICT=ADOPTED` has never run under 0.16. | **Live network + an elected slot + operator unfreeze of the forge path.** Cannot be proven on this host. | Keep 0.15.2 Variant B as acceptance binary until a controlled 0.16 elected-slot test adopts a block. |
| R2 | **MEDIUM** | **opcert ed25519 self-verify under 0.16 inferred, not A/B-run** (G2). | Live opcert + the forbidden live forge loop. | Source is byte-identical across trees; treat as inferred until the G1 live test (which exercises self-verify) passes. |
| R3 | **MEDIUM** | **No multi-hour / multi-epoch soak under 0.16** (G3). Slow fd/memory leaks or epoch-boundary behavior under new `std.Io` call shapes are unobserved. Longest proven run = 120 s live-sync. | A multi-hour preview soak on a non-producing relay. | Run a ≥24 h preview soak (read-only / preview_safe) before authorizing as acceptance binary; watch RSS, fd count, panic/EAGAIN markers. |
| R4 | **LOW** | **Concurrency model relies on internal std invariants** (comptime-constant vtable, stateless-per-call syscall fns). A future std change could violate the safety argument. | Re-audit on any toolchain bump. | Pinned to 0.16.0 exactly; `src/compat_concurrency_test.zig` guards the assumption. |
| R5 | **LOW** | **`@fieldParentPtr` reader-address-stability invariant** in `tcp_byte_transport.zig` — the persistent reader must never be moved after init. | Code review on any refactor of `TcpByteTransportImpl` lifetime. | Reader lives inside the heap-allocated, address-stable impl; covered by fragmented-read tests. |
| R6 | **LOW** | **The 4 propagation_server tests now depend on the `.ready` sentinel fixture** — if the two-phase-commit protocol changes, fixtures must track it. | Test maintenance. | Documented in §3; fixtures mirror the real producer protocol. |
| R7 | **INFO** | Preview blocks observed at `era=6` on the wire during live-sync; this is the live preview chain's current era for fetched bodies and is **independent** of TSUNAGI's forge envelope, which is Conway `era=7` / prefix `82 07 85` (proven). Not a defect. | n/a | n/a |

---

## 5. Forge bytes remain equivalent (explicit statement)

**The forge byte-output path of the Zig 0.16.0 build is byte-for-byte equivalent to the Zig 0.15.2 build.** This was proven by construction with fixed golden inputs across all 7 dimensions:

1. Candidate header **body CBOR** — bit-identical.
2. **Full block envelope** — bit-identical; `CONWAY_BLOCK_ERA_TAG=7`; prefix `82 07 85` (`PREFIX_OK=true`).
3. Full envelope **Blake2b256** — matched.
4. **VRF output** — matched.
5. **Praos leader threshold** — matched.
6. **Header CBOR assembly** (`82` + raw header_body + bstr len + KES sig) and **header hash** — matched.
7. **KES signature assembly** — matched.

`assembleHeader`/`assembleFullBlock` are pure byte-assembly + Blake2b256 with **no compat-affected paths**. No forge/crypto/threshold/VRF/KES/opcert/CBOR **logic** was modified this campaign. The opcert ed25519 self-verify block is byte-identical in source across both trees (see R2 for the inference caveat — it has not been A/B-run live).

---

## 6. Deploy runbook (operator-controlled — DO NOT auto-deploy)

> The relay and `forge.env` must NOT be touched by automation. The steps below are for the operator. The 0.16 binary is a **parallel-track candidate**; promoting it to the producing relay implies accepting residual risks R1–R3.

### 6.1 Deploy package (this host)
- Directory: `/home/tsunagi/.milestone-zig016-signoff-2026-06-07/`
  - Binary: `tsunagi-node-zig016`
    - sha256 `37e8881e85a33bd54cba4ca26ee7b9bcf0a2ff80153ea95d50f27f7efa8e325a`
    - md5 `088f1680498b2409f18befb1aba63056`
    - size `23571672`
  - Bundle: `tsunagi-node-zig016.tar.gz`
    - sha256 `4427330ed37c1e39b068696997d51f4331a53f0e34a5fd6cff0042897f5a8835`
    - md5 `5b8d4dfcaf5b2ceddf1e18dbee7880f0`
  - `fingerprints.txt` (same values)
- Source: branch `chore/zig-0.16-migration-2026-06-07`, commit `358297b76604e7cd70b33f6f50bef60a939491c5`, Zig 0.16.0 ReleaseSafe.

### 6.2 Pre-deploy verification (operator)
1. SCP the bundle to the relay (do **not** overwrite the running binary yet).
2. On the relay, verify the fingerprint **before** swapping:
   `sha256sum tsunagi-node-zig016` must equal `37e8881e85a33bd54cba4ca26ee7b9bcf0a2ff80153ea95d50f27f7efa8e325a`.
3. Confirm self-report: `./tsunagi-node-zig016 --version` → must show `ReleaseSafe ... zig=0.16.0 dirty=0`.

### 6.3 Preserve forge.env / MODE
- **Do NOT edit `forge.env`.** The 0.16 binary reads the same env contract as 0.15.2. Preserve all of: `TSUNAGI_MODE` (keep `live` if the relay is already live; for first 0.16 soak prefer `preview_safe`), `OPCERT_SEQ`, `KES_START_PERIOD`, `STALE_PARENT_MAX_SLOTS`, `TSUNAGI_HOME`, and the static opcert sigma.
- **Recommended first deploy = `preview_safe`** (read-only, wire suppressed) to satisfy soak (R3) before any live forge. Flip to `live` only after a clean soak and operator authorization.

### 6.4 Swap procedure
1. Snapshot the currently-running binary path + sha256 (record for rollback).
2. Stop the running node (SIGTERM; escalate to SIGKILL only if TERM ignored).
3. Replace the binary at the relay's node path with `tsunagi-node-zig016` (keep the old one in place / renamed for rollback).
4. Start the node; tail the log.

### 6.5 Boot checks (must all be green before walking away)
- `EFFECTIVE_CONFIG ... mode=<expected> stale_parent_max=600`
- `FORGE GATE: active mode=<expected>`
- `KES PERIOD start=... max=...`
- `OPCERT_STATE current=0 source=file last_persisted=0` (or the operator's intended seq)
- `PRAOS_STATE nonce_epoch=<current> epoch_nonce=<hash> sigma_source=...`
- Network: `PRIMARY_HANDSHAKE_OK`, `KEEPALIVE: rx pong`, `PRIMARY_INTERSECT_FOUND`, header RollForward advancing, `BLOCKFETCH` bodies decoding.
- **Zero** of: `panic`, EAGAIN panic, core dump, `FORGE_REFUSE`, `FORGE_SELF_VERIFY_FAIL`, `ROLLBACK_TRIGGER`, corruption.

### 6.6 Soak (closes R3 before any live forge)
- Run ≥24 h in `preview_safe`. Watch RSS and fd count for monotonic growth; watch for any panic/EAGAIN markers. A clean soak is the precondition for an operator-authorized `MODE=live` flip.

### 6.7 First live elected-slot test (closes R1/R2 — requires operator forge unfreeze)
- Only after a clean soak: flip `MODE=live` and wait for the next elected slot. Watch for the full chain `EVENT_LEADER_DETECTED → FORGE_GATE_* pass → FORGE_SELF_VERIFY gate=opcert pass=YES → FORGE_PROMOTE_ATOMIC → FORGE_PROMOTE_FRAGMENT artifact_coherent=true → PROPAGATION_SEND → ACCEPTANCE_VERDICT result=ADOPTED → CANONICAL_CONFIRMED`. External confirm: `cardano-cli query tip` shows TSUNAGI's hash; Koios `pool_blocks` lists it. **This is the event that promotes 0.16 from CONDITIONAL to full production.**

### 6.8 Rollback to 0.15.2 Variant B
Rollback is **trivial — no state migration** (the migration changed no on-disk formats; only API call shapes).
1. Stop the 0.16 node.
2. Restore the **0.15.2 Variant B acceptance binary**:
   - Path on this host: `/home/tsunagi/.milestone-election-sigma-sync-2026-06-07/tsunagi-node-election-sigma-sync`
   - sha256 `eade3e8ed357e23cc0d882e6cb605c334c9f1315fb47f7a1bc82f01ac7e1ffc1`, md5 `14a46004a94414bd43f046b9e53bd7c2`
   - Carries all 3 fixes: Conway era-tag-7 + sigma-drift gate + authoritative active-stake sigma resolver (commit `9182326`).
3. Start; run the §6.5 boot checks. `forge.env` is unchanged, so no further config action is needed.
- Intermediate 0.15.2 fallback (era-tag + sigma-drift, without the election-sigma resolver): `/home/tsunagi/.milestone-sigma-fix-2026-06-06/tsunagi-node-sigma-fix`, sha256 `1db497e8acef441be3dc428b321413ec61c67ca227c4b7b9bf92bfb63c46ae3c`.

---

## 7. Honesty notes / what could NOT be proven here

- **G1 (live adopted block under 0.16)** and **G2 (live opcert self-verify under 0.16)** require the live network, live keys, an elected slot, and operator unfreeze of the forge path. They **cannot** be proven on this build host. Everything stated about them is by-construction byte-equivalence or source identity, explicitly flagged.
- **G3 (soak)** has not been run; the longest proven continuous 0.16 run is the 120 s live-sync.
- The live-sync test fetched preview bodies at `era=6` — that is the live chain's data, not TSUNAGI's forge envelope (which is `era=7`). Called out so it is not mistaken for a regression.
- Test count is reported as **measured this run** (1482/0), which differs from earlier campaign snapshots because tests were added during hardening; this is the current truth, not a contradiction.
