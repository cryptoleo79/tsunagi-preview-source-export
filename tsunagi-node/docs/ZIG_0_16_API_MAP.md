# Zig 0.16 — verified API map for the TSUNAGI migration (2026-06-07)

Reverse-engineered against `/home/tsunagi/opt/zig-x86_64-linux-0.16.0/lib/std` and
**compile-proven**. This SUPERSEDES the earlier `ZIG_0_16_MIGRATION_RECIPE.md`,
which contained three wrong assumptions (getEnvVarOwned/posix.getenv/array_list
were claimed unchanged — only the last is true).

The whole strategy: a single `src/compat.zig` module (build-wired as `@import("compat")`)
provides drop-in replacements that preserve the OLD call shapes. Migration is then
mostly `sed` + add the import. `src/compat.zig` already compiles+passes 7 tests
under 0.16 (`zig test src/compat.zig -lc`).

## What actually changed (proven)

| 0.15 symbol | 0.16 reality | compat replacement | class |
|---|---|---|---|
| `std.heap.GeneralPurposeAllocator` | renamed `std.heap.DebugAllocator` (same `.{}`) | `compat.DebugAllocator` | sed |
| `std.array_list.Managed(T)` | **UNCHANGED — still exists** | leave as-is | no-op |
| bare `std.ArrayList(T)` | now UNMANAGED | `std.array_list.Managed(T)` | manual (2 sites) |
| `std.process.getEnvVarOwned` | **REMOVED** | `compat.getEnvVarOwned` | sed |
| `std.process.hasEnvVar` | **REMOVED** | `compat.hasEnvVar` (returns `bool`, drop `try`) | sed+ |
| `std.posix.getenv` | **REMOVED** | (use compat env) | — |
| `std.posix.pread/pwrite/fstat/lseek` | **REMOVED** (no posix file escape hatch) | via compat.fs (global Io) | — |
| `std.process.argsWithAllocator/argsAlloc` | removed | `compat.argsAlloc(arena)` | manual |
| `std.io.fixedBufferStream` | **REMOVED** (Writergate) | `compat.fixedBufferStream` | sed |
| `std.io.FixedBufferStream` (type) | removed | `compat.FixedBufferStream` | sed |
| `std.io.GenericWriter(net.Stream,...)` | removed | `compat.streamWriter(stream)` | manual (14) |
| `std.io.GenericReader(net.Stream,...)` | removed | `compat.streamReader(stream)` | manual |
| `std.fs.File` (type) | moved → `std.Io.File` (io-threaded methods) | `compat.fs.File` (wrapper) | sed |
| `std.fs.Dir` (type) | moved → `std.Io.Dir` (io-threaded methods) | `compat.fs.Dir` (wrapper) | sed |
| `std.fs.cwd()` | moved → `std.Io.Dir.cwd()` | `compat.fs.cwd()` | sed |
| `std.fs.openFileAbsolute/createFileAbsolute/deleteFileAbsolute` | io-threaded | `compat.fs.*` | sed |
| `std.fs.path` | **UNCHANGED** | leave (or `compat.fs.path`) | no-op |
| `<arraylist>.writer()` | Managed lost `.writer()` | `compat.listWriter(&list)` | manual |
| `.writeInt(`/`.readInt(` on values | these are ALL `std.mem.writeInt/readInt` (free fns) — **UNCHANGED** | leave | no-op |
| `std.debug.print` | **UNCHANGED** | leave | no-op |
| `std.io.getStdOut/Err/In` | **0 uses in our tree** | n/a | — |

## Io.Writer / Io.Reader method names (for any code touching the new vtable directly)
- Writer HAS: `writeAll`, `writeByte`, `print`, `splatByte`(was writeByteNTimes), `flush`, `writeInt`? NO — use `std.mem.writeInt` into a temp then writeAll. `fixed(buf)`, `Allocating` (ArrayList-backed: `.init(alloc)`, `.writer` field, `.written()`, `.toOwnedSlice()`).
- Reader HAS: `take(n)`, `takeArray(n)`, `takeByte`(was readByte), `readSliceAll`(was readNoEof), `allocRemaining(gpa, limit)`/`readAlloc`(was readAllAlloc), `discard`, `peek`. NO `readByte`/`readInt`/`readNoEof`.
- NOTE: compat.FixedBufferStream.Reader/Writer already expose the OLD names, so code going through compat needs NO reader/writer method renames.

## File / Dir model (the big one — everything needs an Io)
- Global Io: `std.Io.Threaded.global_single_threaded.io()` → a usable `std.Io`. compat exposes `compat.defaultIo()`.
- `std.Io.Dir.cwd()` — no io. Methods needing io:
  - `openFile(io, sub, OpenFileOptions{.mode=.read_only|.read_write|.write_only})`
  - `createFile(io, sub, CreateFileOptions{.read,.truncate,.exclusive})`
  - `createDirPath(io, sub)` ← **this is the old `makePath`**
  - `createDir(io, sub, Permissions)` ← old `makeDir`
  - `openDir(io, sub, OpenOptions)`, `deleteFile(io,sub)`, `deleteTree(io,sub)`,
    `access(io,sub,opts)`, `statFile(io,sub,opts)`, `rename(io,...)`,
    `readFileAlloc(io, sub, gpa, Io.Limit)`, `readFile(io, path, buf)`, `writeFile(io, WriteFileOptions)`,
    `close(io)`.
  - `iterate()` (no io) → `Iterator`; `Iterator.next(io)` needs io.
- `std.Io.File`: field `handle: std.posix.fd_t`. Methods: `stat(io)`, `close(io)`, `sync(io)`,
  `reader(io, buffer) → File.Reader`, `writer(io, buffer) → File.Writer`. Assoc types: `OpenMode`, `Stat`, `OpenError`, `SeekError`.
  NO direct `readAll/readToEndAlloc/writeAll/write/read/seekTo` — go through reader/writer.
  - `File.Reader{ .file, .io, .interface: Io.Reader, .pos, .size, seekTo(), seekBy(), getSize() }`; read-all via `fr.interface.allocRemaining(gpa, limit)`.
  - `File.Writer{ .file, .io, .interface: Io.Writer, .pos, init(file,io,buffer) }`; write via `fw.interface.writeAll(...)` then `fw.interface.flush()`.
- `Io.Limit`: use `std.Io.Limit` (`.limited(n)` / `.unlimited`). Verify constructor at use.

## Verified call-site counts (grep, src/, 284 files)
fixedBufferStream 165 · GenericWriter 10 · GenericReader 4 · getEnvVarOwned ~196
· GPA 9 · fs.cwd 614 · openFile 168 · createFile 141 · makePath 99 · openDir 60
· deleteTree 40 · rename 37 · statFile 34 · close 454 · writer() 160 · reader() 121
· readToEndAlloc 45 · readAll 56 · writeAll 191 · iterate 49 · list.writer() ~70.
All `.writeInt`/`.readInt` (170/92) are `std.mem.*` → DO NOT TOUCH.

## Migration order (leaves first; each file: sed → add `const compat = @import("compat");` → fix residual → `zig 0.16 ast-check`)
net/cbor/* (leaf, imported by 36) → net/ledger/* → net/miniproto/* → protocols/* →
net/mux.zig, net/chainsync/follower.zig → producer/* → net/propagation_server.zig,
net/metrics/http_metrics.zig → cli/* → tools/* → replay/* → main.zig → *_tests.zig (last).

Final gate: `/home/tsunagi/opt/zig-x86_64-linux-0.16.0/zig build` (all targets) +
test roots. Compare behavior against the 0.15.2 build — forge/crypto byte output MUST be identical.
