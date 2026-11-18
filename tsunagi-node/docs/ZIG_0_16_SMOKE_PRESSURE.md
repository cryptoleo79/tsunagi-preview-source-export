# Zig 0.16.0 — Consolidated SMOKE + PRESSURE Report

Date: 2026-06-07
Toolchain: `/home/tsunagi/opt/zig-x86_64-linux-0.16.0/zig`
Subject: TSUNAGI node + tooling built under Zig 0.16.0; compat-layer concurrency and memory stability.

---

## Overall Verdict: ALL GOOD

Every smoke binary started and exited without crash, panic, segfault, or abort. Both pressure tests
passed: zero ThreadSanitizer races (under a *proven-functional* TSan configuration) and zero memory
leaks across runs up to 1,000,000 iterations. No crash, leak, race, or genuine UB was found anywhere.

One **methodology caveat** (not a defect in the code under test) was surfaced and resolved honestly:
Debug-mode `-fsanitize-thread` does NOT instrument Zig code on this 0.16.0 toolchain, making a naive
Debug TSan pass vacuous. The load-bearing race result was re-derived under the proven-functional
`-OReleaseSafe -fsanitize-thread` configuration. See the Pressure section and Residual Risks.

---

## SMOKE — Binary Run Results

Build: Zig 0.16.0, `rc=0`. Binaries at
`/home/tsunagi/src/tsunagi-follower/tsunagi-node/zig-out/bin/`
(`tsunagi-node`, `plutus-evaluator`, `praos-verify`, `tsunagi-slot-index-reset`).

Crash scan across all captured outputs (grep for segmentation / segfault / panic / SIGSEGV / SIGABRT /
illegal-instruction): **ZERO real hits** (the only apparent "UB" matches were substrings, not actual UB).

| # | Binary / invocation | Exit | First line / output | Verdict |
|---|---|---|---|---|
| 1 | `tsunagi-node --help` | 1 (usage convention) | `TSUNAGI Node (Zig-only)`, 84 lines of usage | PASS — no crash |
| 2 | `tsunagi-node` (no-arg) | 0 | `framed mux start (D.3.3)` -> chainsync `find_intersect` -> `request_next` -> blockfetch `request_range` -> `framed mux done (D.3.3)` | PASS — clean start-and-exit |
| 3 | `plutus-evaluator` (no-arg) | 0 | JSON `{"protocol_version":1,"success":false,"error_code":6,"ex_units_mem":0,"ex_units_steps":0}` | PASS |
| 4 | `praos-verify` (no-arg) | 1 | `error: MissingSlot` then `Usage: praos-verify --slot N --epoch-nonce-hex HEX --sigma-x1e9 N --vrf-skey PATH [--asc-x1e6 N]` | PASS — prints usage as expected |
| 5 | `tsunagi-slot-index-reset` (no-arg) | 1 | `RESET_SLOT_INDEX: ensure no live tsunagi-node...` -> `ERROR - TSUNAGI_LMDB_DIR unset and no argv[1]` -> `error: MissingLmdbDir` with Zig error-return trace | PASS — normal error-return trace from `return error.MissingLmdbDir`, NOT a panic/segfault |
| 6 | `tsunagi-node-stale-parent-fix --help` (deployed 0.15.2-fix) | 1 | `TSUNAGI Node (Zig-only)`, 81 lines usage | PASS — no crash |

Notes:
- Items 1, 4, 5 exit non-zero by design (usage / missing-argument conventions), not due to faults.
- Item 6 ran the standalone binary file at
  `/home/tsunagi/.milestone-stale-parent-fix-0.15.2-2026-06-07/tsunagi-node-stale-parent-fix`. It did
  **NOT** touch the live relay process.

---

## PRESSURE — Stress Test Results

| Test | Pass | Crashes | Leaks / Races | Iterations / Duration |
|---|---|---|---|---|
| concurrency_stress | YES | 0 | 0 ThreadSanitizer races; counter exact (no lost updates) every run | 3 runs >=10s: ReleaseSafe 163021 iters/10005ms; TSan-Debug (vacuous) 155121 iters/10004ms; TSan-ReleaseSafe (valid) 155949 iters/10006ms |
| memory_stability | YES | 0 | 0 leaks; `DebugAllocator(.{.safety=true}).deinit()` -> `.ok` every run | 1,000,000 iters in 66.6s; also 200,000 in 13.1s; 1,000 smoke |

### concurrency_stress (detail)

Harness `src/compat_concurrency_stress_test.zig` (now deleted): 64 OS threads via `std.Thread.spawn`,
each looping until a shared 10s wall-clock deadline performing:
- (a) `compat.nanoTimestamp` / `milliTimestamp` / `timestamp`
- (b) `compat.Mutex` lock/unlock x2 around shared `g_counter`
- (c) `compat.fs` createFile/writeAll/sync/close + openFile/readToEndAlloc/close roundtrip in
  `std.testing.tmpDir`

Build flags: `-lc -I/usr/local/include -L/usr/local/lib -lsodium`.

- **RUN1 ReleaseSafe** (`zig test -OReleaseSafe`): EXIT=0.
  `STRESS_RESULT threads=64 iters_total=163021 mutex_ops=326042 counter=326042 fs_roundtrips=163021 elapsed_ms=10005`.
  All 13 tests passed. Exact counter assert (`total_mutex_ops == g_counter`) held.
- **RUN2 TSan Debug** (`-fsanitize-thread`, Debug): EXIT=0, counter=310242 exact, 0 race reports —
  **but later found VACUOUS** (see methodology finding).
- **RUN3 TSan VALID** (`-fsanitize-thread -OReleaseSafe`): EXIT=0.
  `STRESS_RESULT threads=64 iters_total=155949 mutex_ops=311898 counter=311898 fs_roundtrips=155949 elapsed_ms=10006`.
  `grep 'ThreadSanitizer: data race'` = 0. All 13 tests passed.

No crash / panic / UB in any run. Compat paths exercised — `compat.zig:686-743` (time / Mutex over
`std.Io.Threaded.global_single_threaded.io()`) and `compat.zig:1372-1438` (`fs.Dir` over global Io) —
are concurrency-safe under amplified 64-thread sustained load.

### memory_stability (detail)

Allocator: `std.heap.DebugAllocator(.{.safety=true})`. `deinit()` returned `.ok` on every run
(1k, 200k, 1M iterations). Harness exits 2 on leak; observed **exit 0 every time**. Each iteration
drives multiple allocation-heavy compat paths. Largest run: 1,000,000 iterations in 66.6s; also
200,000 in 13.1s and a 1,000-iteration smoke. **0 leaks.**

---

## Crash / Leak / Race / UB Findings

**None.** No crash, no segfault, no panic, no abort, no memory leak, no genuine UB, and no data race
(under proven-functional TSan) was observed in any smoke or pressure run.

The single deliberately-induced race (the verification probe `race_probe2.zig`) is described below as
part of validating that TSan was actually working — it is NOT a defect in the code under test.

---

## CRITICAL METHODOLOGY FINDING (honest disclosure)

On this Zig 0.16.0 toolchain, `-fsanitize-thread` in **DEBUG** mode does **NOT** instrument Zig code:
- `nm` showed **0** `__tsan_*` calls in the Debug-TSan build.
- A deliberate heap data-race probe (`race_probe2.zig`, 8 threads doing RMW on a shared `*u64`) did
  **NOT** fire (exit 0) under Debug TSan.

Therefore a naive Debug TSan pass is meaningless / vacuous (this is why RUN2 above is flagged vacuous).

TSan was verified **functional** under `-OReleaseSafe -fsanitize-thread`:
- That build emits `__tsan_*` instrumentation (11+ calls).
- The same deliberate-race probe correctly fired:
  `WARNING: ThreadSanitizer: data race ... race_probe2.zig:6`, exit 1.
- C-level `zig cc -fsanitize=thread` also fired (exit 66).

The real harness was then re-run under the proven-functional config (ReleaseSafe + sanitize-thread)
and produced **0 races** — this is the load-bearing concurrency result.

**Repro (race detection sanity / proof TSan works):**
1. Build a probe with two+ threads doing unsynchronized RMW on a shared `*u64`.
2. Compile with `zig test -OReleaseSafe -fsanitize-thread ...` -> expect
   `WARNING: ThreadSanitizer: data race`, non-zero exit.
3. Confirm `__tsan_*` symbols present via `nm`. (Under Debug `-fsanitize-thread`, `nm` shows zero
   `__tsan_*` and the probe will not fire — do NOT trust Debug TSan on this toolchain.)

**Cleanup:** `src/compat_concurrency_stress_test.zig` and all `/tmp` probes were removed; `git status`
shows no leftover from this session (`build.zig` / `fuzz_codec_harness.zig` pre-existed, not from this
work).

---

## Residual Risks

1. **Debug TSan is blind on Zig 0.16.0.** Any future concurrency testing on this toolchain MUST use
   `-OReleaseSafe -fsanitize-thread` (and confirm `__tsan_*` symbols), or it will silently pass
   nothing. This is a toolchain property, not a code defect, but it is a standing trap for future runs.
2. **Test scope is the compat layer, not the full node under live load.** Pressure tests exercise
   `compat.zig` time/Mutex/fs paths under amplified synthetic load; they do not exercise the full
   forge/propagation pipeline end-to-end under network conditions.
3. **Smoke is start-and-exit, not sustained operation.** The smoke set confirms binaries launch and
   terminate cleanly; it does not confirm long-running forge correctness (covered by the separate
   live/forge campaign, not by this report).
4. **Deleted harness.** The concurrency harness was removed after the run, so re-verification requires
   recreating it from the description above.

---

## Production-Readiness Statement for Zig 0.16

The 0.16.0 build is `rc=0`; all binaries run cleanly; the compat layer is concurrency-safe (0 races
under proven-functional TSan) and leak-free (0 leaks at 1M iterations). On the evidence in this report,
Zig 0.16.0 introduces **no new crash, leak, race, or UB** in the smoke surface or the compat layer.

**Does this change the CONDITIONAL-GO verdict?** No — it does not downgrade it. These results are
consistent with, and supportive of, the existing CONDITIONAL-GO posture: they remove concurrency- and
memory-stability concerns for the compat layer under 0.16. The verdict remains CONDITIONAL-GO because
the conditions are out of scope here (full end-to-end forge/propagation under live network load and the
existing forge-path freeze/blockers), not because anything in this report failed. Nothing here clears
those conditions, and nothing here adds a new blocker.

One operational guardrail is now mandatory regardless of GO/NO-GO: on Zig 0.16.0, only trust
ThreadSanitizer results produced under `-OReleaseSafe -fsanitize-thread`.
