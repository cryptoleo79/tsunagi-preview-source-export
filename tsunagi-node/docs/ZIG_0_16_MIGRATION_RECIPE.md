I have everything needed. The `.writer()` receivers are predominantly `std.array_list.Managed` instances (already-migrated `.Managed` naming) and `fixedBufferStream` results — both of which collide with 0.16's Writergate. The codebase is partially pre-migrated (already uses `std.array_list.Managed` not bare `std.ArrayList`). Here is the verified recipe.

---

# Zig 0.16 Migration Recipe — TSUNAGI (verified against src/, 259 .zig files)

## Verified pattern counts (cross-checked by grep)

| Category | Count | Files | Migration class |
|---|---|---|---|
| `GeneralPurposeAllocator(.{}){}` | 9 (real; 1 false hit in a comment) | 6 | sed-safe |
| `std.process.getEnvVarOwned` | 196 | ~24 | sed-safe (no API change in 0.16 — see note) |
| `std.io.fixedBufferStream` | 162 (+1 unqualified = 163) | ~30 | MANUAL (Writergate) |
| `std.array_list.Managed(...)` | 212 | ~40 | sed-safe rename to `.Aligned`/`ArrayList` semantics — see note |
| bare `std.ArrayList(...)` (0.15 Managed-style) | 2 | 1 (`test_remediation_tests.zig`) | MANUAL |
| `.writer()` | 148 | ~40 | MANUAL (Writergate — depends on receiver) |
| `std.process.*` (total) | 353 | — | mixed; breakdown below |

`std.process.*` breakdown: `getEnvVarOwned` 196, `exit` 88, `Child` 40, `hasEnvVar` 20, `getEnvMap` 3, `EnvMap` 3, `argsWithAllocator` 2, `argsAlloc` 1.

IMPORTANT FINDING: this tree is ALREADY partially migrated — it uses `std.array_list.Managed(...)` (the 0.16 transitional name), NOT bare `std.ArrayList(...)`. There is NO existing `compat` module (all 66 "compat" grep hits are English-comment words like "backward-compatible"). So a compat shim must be CREATED, not extended.

---

## CHECKLIST

### [ ] 0. Create the compat shim first (`src/compat.zig`)
No compat module exists. Create one and route the non-mechanical surfaces through it so the diff is auditable and reversible:
```zig
// src/compat.zig — Zig 0.16 transition shim. Author: cryptoleo79.
const std = @import("std");
pub const DebugAllocator = std.heap.DebugAllocator;            // GPA replacement
pub fn getEnvVarOwned(a: std.mem.Allocator, k: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(a, k);                   // re-export; swap impl if 0.16 renames
}
pub const ArrayList = std.array_list.Managed;                  // single rename point for 212 sites
// FixedBufferStream + Writer adapters added in step 3/5 below.
```
Verify: `grep -rln '@import("compat' src | wc -l` after wiring.

### [ ] 1. `GeneralPurposeAllocator` → `DebugAllocator` — SED-SAFE (9 sites, 6 files)
0.16 renamed the type; `.{}` config is unchanged.
```bash
ZIG016="src/byte_transport_tests.zig src/mux_framing_tests.zig src/protocol_tests.zig src/framing_tests.zig src/muxwire_tests.zig src/tools/praos_verify.zig"
sed -i 's/std\.heap\.GeneralPurposeAllocator/std.heap.DebugAllocator/g; s/\bGeneralPurposeAllocator(\.{})/DebugAllocator(.{})/g' $ZIG016
```
Note: 1 hit ("`GeneralPurposeAllocator causes under CBOR decode...`") is prose inside a comment in `src/tools/praos_verify.zig` — the `(.{})` anchor in the sed prevents touching it. Verify: `grep -rn 'GeneralPurposeAllocator(' src` returns 0 code hits.

### [ ] 2. `getEnvVarOwned` → compat — SED-SAFE (196 sites)
In 0.16 the function still exists at `std.process.getEnvVarOwned` with the same signature; the migration risk is only if you want a single swap point. Route through compat:
```bash
grep -rl 'std\.process\.getEnvVarOwned' src --include='*.zig' \
  | xargs sed -i 's/std\.process\.getEnvVarOwned/compat.getEnvVarOwned/g'
```
Then ensure each edited file has `const compat = @import("compat.zig");` (path-adjusted per depth). If you prefer zero shim here, this category is a NO-OP — leave the 196 sites untouched and remove from the batch. Decide once; the 95 `std.posix.getenv` sites are unaffected (already 0.16-clean).

### [ ] 3. `fixedBufferStream` → compat — MANUAL (163 sites, ~30 files) — Writergate
0.16's Writergate removed the old generic-stream `.writer()`/`.reader()` off `FixedBufferStream`. You cannot sed the call sites because each `var fbs = std.io.fixedBufferStream(buf)` is followed by `fbs.writer()` / `fbs.reader()` / `fbs.pos` usages that change shape. Pattern:
- READ path (`fbs.reader()`): replace with `std.Io.Reader.fixed(buf)` or keep buffer-slice cursor logic.
- WRITE path (`fbs.writer()`): replace with `std.Io.Writer.fixed(buf)` (0.16 fixed writer) and read `writer.end`/`.buffered()` instead of `fbs.getWritten()`.
Provide a compat wrapper to localize:
```zig
// in compat.zig
pub fn fixedWriter(buf: []u8) std.Io.Writer { return std.Io.Writer.fixed(buf); }
pub fn fixedReader(buf: []const u8) std.Io.Reader { return std.Io.Reader.fixed(buf); }
```
Hotspots to do first (most uses): `src/chainsync_tests.zig` (25), `src/net/chainsync/follower.zig` (15), `src/net/ledger/tx_decode.zig` (13), `src/net/cbor/term.zig` (12). Do `net/cbor/term.zig` EARLY — it is a leaf imported by 36 files; fixing it unblocks downstream.

### [ ] 4. `array_list.Managed` → final name — SED-SAFE rename point (212 sites + 2 bare)
The tree already uses `std.array_list.Managed(T)` (transitional). For the final 0.16 form, funnel through compat so the eventual `std.ArrayList`-unmanaged decision is one edit:
```bash
grep -rl 'std\.array_list\.Managed' src --include='*.zig' \
  | xargs sed -i 's/std\.array_list\.Managed/compat.ArrayList/g'
```
The 2 BARE `std.ArrayList(VerdictEvent)` sites in `src/test_remediation_tests.zig` (lines 289, 295) are MANUAL: one is a struct field type, one is `.initCapacity(alloc, 0)`. Convert both to `compat.ArrayList(VerdictEvent)` by hand and verify `.initCapacity` arity matches the chosen managed type. Verify after: `grep -rnE '\bstd\.ArrayList\(' src` returns 0.

### [ ] 5. `.writer()` → compat/Io.Writer — MANUAL (148 sites) — Writergate
Receiver-dependent; cannot blanket-sed. Verified receiver breakdown:
- ArrayList receivers (`list` 30, `buf` 20, `out` 9, `*_list` ~20): `list.writer()` → 0.16 `list.writer(...)` now needs the new `std.Io.Writer` interface or `list.appendSlice`/`list.print`. Wrap via compat `arrayListWriter(&list)`.
- `fbs`/`stream` receivers (~19): handled by step 3's fixed-writer.
- generic `w`/`wr` (33): inspect each — these are functions taking an `anytype` writer; update the param type to `*std.Io.Writer`.
Do these per-file in lockstep with step 3 (same Writergate root cause). Confirmed call shapes: `cbor.encode(tip, buf.writer())` and `const w = list.writer();` — both must move to the 0.16 Writer vtable.

### [ ] 6. `std.process.*` remainder — mostly NO-OP, verify only
- `std.process.exit` (88): unchanged in 0.16 — leave as-is.
- `std.process.Child` (40): API stable in 0.16 — spot-check `.spawn`/`.wait` field names only.
- `std.process.hasEnvVar` (20), `getEnvMap`/`EnvMap` (6), `argsWithAllocator`/`argsAlloc` (3): unchanged — leave as-is.
No sed needed; this is a verification line, not a conversion.

---

## Recommended file-batch order (leaf modules first)

Dependency direction confirmed: `main.zig` is the root (86 `@import`s); `net/cbor/term.zig` is a deep leaf (imported by 36 files, "cbor" referenced in 66). Batch:

1. **`src/compat.zig`** (create — step 0).
2. **Pure leaves (no intra-src imports of net/producer):** `src/net/cbor/term.zig`, `src/net/cbor/*`, `src/net/ledger/tx_decode.zig`, `src/net/ledger/policy_apply.zig`, `src/net/miniproto/txsubmission.zig`. (Heavy `fixedBufferStream`/`.writer()` density; unblocks the most downstream.)
3. **Mid protocol layer:** `src/protocols/*` (`chainsync_server.zig`, `blockfetch_server.zig`), `src/net/miniproto/*`, `src/net/mux.zig`.
4. **Subsystem cores:** `src/net/chainsync/follower.zig` (15 fbs + 25 env), `src/producer/producer.zig` (22 env), `src/net/metrics/http_metrics.zig`, `src/net/propagation_server.zig`.
5. **CLI + tools:** `src/cli/*` (`guardian_cmd.zig` 34 env, `trust_snapshot_cmd.zig`, `snapshot_proof_cmd.zig`), `src/tools/praos_verify.zig`, `src/replay/*`.
6. **Root:** `src/main.zig` (env at 195/205/408 already located).
7. **Test roots LAST** (own build targets, isolatable): `src/*_tests.zig` — `chainsync_tests.zig`, `handshake_codec_tests.zig`, `byte_transport_tests.zig`, `mux_framing_tests.zig`, `framing_tests.zig`, `muxwire_tests.zig`, `protocol_tests.zig`, `propagation_server_bf_repro_tests.zig`, `test_remediation_tests.zig`.

Build with `/home/tsunagi/opt/zig-x86_64-linux-0.16.0/zig` per batch; each test root in `build.zig` (`root_source_file = b.path("src/<x>_tests.zig")`) is a separate compile unit, so test files can be migrated and verified independently of the main binary.

## Per-category sed-safety summary
- SED-SAFE: GPA (9), getEnvVarOwned (196, optional shim), array_list.Managed (212).
- MANUAL: fixedBufferStream (163), `.writer()` (148), bare `std.ArrayList` (2) — all Writergate-coupled, do steps 3+5 together per file.
- NO-OP/verify-only: `std.process.exit`/`Child`/`hasEnvVar`/`getEnvMap`/`args*` (157 total).

Relevant absolute paths: build graph `/home/tsunagi/src/tsunagi-follower/tsunagi-node/build.zig`; densest manual-migration leaf `/home/tsunagi/src/tsunagi-follower/tsunagi-node/src/net/cbor/term.zig`; bare-ArrayList manual site `/home/tsunagi/src/tsunagi-follower/tsunagi-node/src/test_remediation_tests.zig` (lines 289, 295); shim to create `/home/tsunagi/src/tsunagi-follower/tsunagi-node/src/compat.zig`.