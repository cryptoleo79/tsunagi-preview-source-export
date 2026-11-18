# Zig 0.15.2 → 0.16.0 migration — scope + staged plan

> Branch `chore/zig-0.16-migration-2026-06-07` (off `9182326`, all 3 acceptance fixes).
> Status: **STARTED, NOT COMPLETE.** This is the "Writergate"/`Io` overhaul — a
> whole-codebase structural migration, not a mechanical pass. Acceptance binary
> remains on **0.15.2** (deployed); this branch is isolated and does not affect it.

## Why this is large (evidence, 0.16.0 stdlib vs this codebase)
Zig 0.16 removed `std.io` (now `std.Io` with non-generic `Io/Writer.zig` +
`Io/Reader.zig`), removed `std.io.fixedBufferStream`, made `std.process`
`Io`-threaded (env via `process.Environ`, args via `process.Args`, every call
takes `io: Io`), and changed the `array_list` model. Exposure in `src/`:

| API | files | kind |
|-----|-------|------|
| `std.io.*` | 71 | structural |
| `fixedBufferStream` | 65 | structural |
| `.writer()` | 60 | structural |
| `std.process.*` | 57 | thread `io: Io` |
| `array_list.Managed` | 40 | type-model |
| `getEnvVarOwned` | 39 | → `process.Environ` |
| `GeneralPurposeAllocator` | — | → `DebugAllocator` (mechanical) |

~100+ distinct files, including frozen consensus/forge code.

## Done on this branch
- `build.zig`: `exe.linkLibC()` → `exe.root_module.link_libc = true;` (0.16 form).

## Staged plan (recommended order; each a verifiable step)
1. **build.zig** — module link API (done). Confirm `zig build` reaches source compile.
2. **Mechanical renames (sed-able, low risk):**
   - `std.heap.GeneralPurposeAllocator` → `std.heap.DebugAllocator` (init pattern identical).
3. **process/env/args (57 files):** introduce a thin compat shim `src/compat/proc.zig`
   exposing `getEnvVarOwned`/args over the new `process.Environ`/`process.Args`+`Io`,
   so call sites change minimally. Requires one process-wide `Io` instance at startup.
4. **I/O overhaul (the bulk — 65–71 files):** the new `std.Io.Writer`/`Reader` is a
   different (non-generic, vtable) model. Options:
   a. Compat shim `src/compat/io.zig` providing a `fixedBufferStream`-alike + a
      `.writer()` adapter over `std.Io.Writer`, to localize churn; or
   b. Per-file rewrite to the native 0.16 Writer/Reader.
   Recommend (a) first to get a clean build, then (b) opportunistically.
5. **array_list.Managed (40 files):** map to `std.ArrayList` (unmanaged) + explicit
   allocator, or a `Managed` compat alias.
6. **Re-run full `zig build test`; re-fingerprint binary; re-verify each acceptance
   fix (era-tag 82 07 85, sigma gate, authoritative-sigma resolver) is behavior-identical.**

## Recommendation
Do this as a **dedicated, post-first-accepted-block effort**. It has zero mission
value for acceptance (the deployed 0.15.2 binary forges identically), it rewrites
frozen consensus code at structural depth, and the compat-shim approach (steps 3–4a)
is the only sane way to bound the risk. Do NOT rush it onto the acceptance code while
the live experiment is one elected slot from the first network-accepted block.
