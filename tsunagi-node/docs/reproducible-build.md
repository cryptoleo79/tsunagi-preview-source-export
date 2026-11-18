# Reproducible Build — Layer A (Identity / Provenance)

**Version:** v4.2.0
**Scope:** Build identity embedding and environment reporting.
This is Layer A only — no general bit-for-bit reproducibility claim is made.

> **Status note (2026-11-18).** This document was written for v4.2.0 on Zig 0.13.0. The
> tree was migrated to Zig 0.16.0 in June 2026 and `zig.version` was left stale until it
> was corrected alongside this note. For the exact toolchain, flags and observed rebuild
> result of each public Preview binary, see
> [`docs/SOURCE-RELEASE-MAP.md`](../../docs/SOURCE-RELEASE-MAP.md) and
> [`BUILD.md`](../../BUILD.md) at the repository root. One independent rebuild of the
> `v2026.10.05-preview-portable-x86_64` artifact matched the published SHA-256; that is a
> single observation for one artifact, not a guarantee for other commits, flags or hosts.

## Zig Version

The required Zig compiler version is pinned in `zig.version`:

```
cat zig.version
# 0.16.0
```

## Build Command

```bash
cd tsunagi-node

# Minimal build (no identity stamping):
zig build -Doptimize=ReleaseSafe

# Full identity build (recommended):
zig build -Doptimize=ReleaseSafe \
  -Dcommit="$(git rev-parse --short HEAD)" \
  -Dversion="$(git describe --tags --always)" \
  -Dtsunagi_git_tag="$(git describe --tags --exact-match 2>/dev/null || echo untagged)" \
  -Dtsunagi_source_dirty="$(git diff --quiet && echo false || echo true)"
```

### Optional: controlled build epoch

To embed a controlled timestamp (unix seconds):

```bash
zig build -Doptimize=ReleaseSafe \
  -Dtsunagi_build_epoch="$(date +%s)"
```

Or via environment variable style (pass as `-D` flag):

```bash
zig build -Doptimize=ReleaseSafe -Dtsunagi_build_epoch=1709500000
```

The default is `0` (absent). No uncontrolled timestamps are embedded.

## Inspecting Build Identity

### One-line version

```bash
./zig-out/bin/tsunagi-node --version
# tsunagi-node v4.2.0 (abc1234) ReleaseSafe x86_64-linux-gnu zig=0.13.0 dirty=0
```

### Full JSON

```bash
./zig-out/bin/tsunagi-node build-info --json
```

Output:

```json
{"git_commit":"abc1234","git_tag":"v4.2.0","source_dirty":false,"zig_version":"0.13.0","build_mode":"ReleaseSafe","target_triple":"x86_64-linux-gnu","build_epoch":0}
```

## Reproducibility Report

```bash
./zig-out/bin/tsunagi-node repro-report --json
```

Reports (read-only, no network, no secrets):

- Build identity (all embedded fields)
- libsodium version (from `sodium_version_string()`)
- LMDB version (best-effort; "unknown" if unavailable)
- OS / architecture / ABI
- Binary SHA256 (Linux only, via `/proc/self/exe`; "unsupported" elsewhere)

## Evidence Pack Integration

When running `evidence-pack`, the envelope automatically includes:

```
<envelope>/checks/build_info.json
```

This file is included in `SHA256SUMS` and can be verified:

```bash
cd <envelope_dir>
sha256sum -c SHA256SUMS
cat checks/build_info.json
```

### Comparing rolling_digest_hex

```bash
# Run evidence-pack in strict mode:
./zig-out/bin/tsunagi-node evidence-pack \
  --home ~/tsunagi-home-preview --net preview \
  --out /tmp --limit 50 --strict

# The last stdout line is the envelope directory.
# Verify SHA256SUMS:
cd <envelope_dir>
sha256sum -c SHA256SUMS

# Extract rolling_digest_hex from manifest:
grep rolling_digest_hex manifest.json
```

## Layer A vs Layer B

| Aspect | Layer A (v4.2.0) | Layer B (future) |
|--------|------------------|-------------------|
| Build identity | Embedded | Embedded |
| Environment report | Yes | Yes |
| Bit-for-bit claim | **No** | Yes |
| Nix / Docker pinning | No | Yes |
| SOURCE_DATE_EPOCH | Optional | Required |

Layer A provides provenance — "what was this binary built from?"
Layer B (future) will provide determinism — "can I reproduce this exact binary?"

## v4.3.0 — Pubkey Distribution

Evidence envelopes now include `inputs/snapshot_pubkey.pub` (the Ed25519 public
key used for snapshot signing). Distribute this file alongside envelopes to
enable portable, detached verification without requiring local keydir access.

## v4.4.0 — Notarization

For publishable envelopes, GPG notarization is recommended. Use
`--notarize-gpg --gpg-armor` with `evidence-pack` to produce detached
signatures (`manifest.json.asc`, `SHA256SUMS.asc`). See `docs/evidence-pack.md`
for details.
