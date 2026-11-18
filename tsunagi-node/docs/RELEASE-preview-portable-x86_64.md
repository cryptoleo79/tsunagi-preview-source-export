# TSUNAGI Preview — Portable x86-64 release

## What this release fixes
1. **Illegal-Instruction (SIGILL) on non-AVX-512 CPUs.** The previous public Preview binary was
   built with host-native CPU targeting on an AVX-512 machine, so it embedded AVX-512
   instructions and crashed with SIGILL on any x86-64 CPU without AVX-512. This release is built
   with an explicit **baseline** CPU target (`-Dcpu=baseline`, x86-64-v1/SSE2) — no AVX/AVX2/
   AVX-512.
2. **Clean-start ChainSync (this commit).** A genuinely empty follower (no saved cursor) could
   not begin syncing: the origin `FindIntersect` was encoded as `[4, []]` (an empty points list,
   3 bytes), which peers correctly answer with `IntersectNotFound`. It must send the origin
   **point** inside the points list — `[4, [ [] ]]` (4 bytes, `82 04 81 80`). Fixed in
   `chainsync_codec.encodeFindIntersectOrigin` and routed at every origin request site
   (`follower.zig`). A fresh follower now intersects at origin and begins receiving roll-forward
   blocks.

## Scope
Preview follower only. No producer, opcert, KES, forging, propagation-server, or consensus
changes. Change is 3 files: `net/chainsync/chainsync_codec.zig`, `net/chainsync/follower.zig`,
`chainsync_tests.zig`.

## Build (from a pristine checkout/archive of this commit)
```
zig build -Dcpu=baseline -Doptimize=ReleaseSafe \
  -Dcommit=<full release commit> \
  -Dtsunagi_git_tag=preview-portable-x86_64 \
  -Dtsunagi_source_dirty=false
```
Zig 0.16.0. Do NOT pass `-Dtarget=` (switches to cross mode and fails host lib linking); pass
only `-Dcpu=baseline`.

## Requirements
- CPU: any x86-64 (SSE2). No AVX/AVX2/AVX-512.
- glibc ≥ 2.34; `libsodium.so.23`; `liblmdb.so.0`.

## Clean-start / restart
```
# fresh empty home; observe-only follower (no forging)
TSUNAGI_HOME=/path/to/empty-home TSUNAGI_FORGE_ENABLE=0 \
  ./tsunagi-node run --net preview --lang en
# it intersects at origin, receives RollForward, and persists its cursor.
# on restart it resumes from the persisted cursor and continues advancing.
```

## Known limitations
- SHA-256 is build-directory-specific (the binary embeds absolute build paths); not yet a
  reproducible cross-host hash.
- aarch64: HOLD (no ARM64 runtime/deps verified).
- AVX2 variant (`-Dcpu=x86_64_v3`): optional, not published in this release.
