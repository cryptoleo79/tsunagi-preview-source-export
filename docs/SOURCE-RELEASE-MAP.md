# Source / release map

This page maps each public TSUNAGI Preview binary to the source it was built from, and says
how strongly each link is established. It was compiled on **2026-11-18** from the public
release assets, the project's original Git history, and one independent rebuild.

This repository is a source export ([`../SOURCE-EXPORT.md`](../SOURCE-EXPORT.md)). Commit ids
below that are marked *original* identify commits of the original history, which is not
part of this repository.

Three different things are easy to confuse. They are separate lines of work:

| Line | Where it lives | What it is |
|---|---|---|
| **June 2026 producer** | the original history, June 2026 state of the `release/preview-portable-x86_64` lineage; **not in this repository** | Preview block-producer build published 2026-06-19 |
| **October 2026 follower** | this repository, tag `october-2026-follower-source` (export of original commit `4cdcde42`, with listed differences) | Portable Preview follower build published 2026-10-05 |
| **Current Mainnet development** | a separate code line on a newer Zig toolchain, not in this repository | Under active development and audit. No public binary. Not described by this page. |

Nothing on this page is a statement about Mainnet readiness. See
[`REVIEW-GUIDE.md`](REVIEW-GUIDE.md) for maturity levels and known limitations.

## Which binary was tested?

| Field | Value |
|---|---|
| Binary identity used in external conformance testing | **UNKNOWN** — not yet supplied by the reviewer |

Until the tester supplies a SHA-256 (or the exact download URL and date), do not assume
which row below applies. `sha256sum <file>` on the tested executable settles it.

## Binary → source

### `v2026.10.05-preview-portable-x86_64` — October follower

| Field | Value | Status |
|---|---|---|
| Distribution | `cryptoleo79/tsunagi-preview`, release `v2026.10.05-preview-portable-x86_64`, published 2026-10-05T01:12:33Z | observed |
| Executable | `tsunagi-preview-v2026.10.05-linux-x86_64`, 5,798,056 bytes | observed |
| SHA-256 | `4919985711adbf8f59b07839752e605ac3d98d1df35a42f5f93ab2ff3985e08e` | matches `SHA256SUMS` and the GitHub asset digest |
| Source commit (original) | `4cdcde42d5cd5f097e50bf5212db671b25ee6947` | embedded in the binary; not in this repository |
| Source tree (original) | `02f603b30246da84d3cf9793162956a015ea8e00` | matches the commit |
| Source branch (original) | `release/preview-portable-x86_64` | observed |
| Export commit | `8b80c3b7f35dd16afca611cbef1c38ed19869999`, tag `october-2026-follower-source` | source of the original commit with the differences listed in [`../SOURCE-EXPORT.md`](../SOURCE-EXPORT.md); not byte-identical to it |
| Compiler | Zig `0.16.0`; `zig` executable SHA-256 `2317bbb91798556d9d0f38aabdac23db83f0979b25f767259ae474546724087c` | official tarball re-downloaded and matched |
| Build mode | `ReleaseSafe`, `-Dcpu=baseline`, target `x86_64-linux-gnu` | from the release provenance manifest |
| Post-processing | `objcopy --strip-debug` | from the release provenance manifest |
| Zig package dependencies | none (no `build.zig.zon`) | observed |
| Linked at run time | `liblmdb.so.0`, `libsodium.so.23`, `libc.so.6` (glibc ≥ 2.34) | observed in the ELF dynamic section |
| **Rebuild result** | **byte-identical** to the published executable | one independent rebuild of the original commit, 2026-11-18, different host, user and checkout path. The export commit differs in the text of two source comments and has not been rebuilt |

The rebuild used a clean `git archive` export of the original commit, an empty cache, the command in
[`BUILD.md`](../BUILD.md), and GNU objcopy 2.38. This is one observation for one artifact. It
is not a general reproducibility guarantee, and it says nothing about run-time behaviour.

A debug-symbol build of the same commit was also attached to a release of the original
private repository, `v2026.07.24-preview-portable-x86_64` (`tsunagi-preview-linux-x86_64-portable`, SHA-256
`dc38d13cabe8ebdb4dd4c98aa14ad5b4860d5054de1e3a8a34c589fbc3c0a66d`). It differs from the
October executable in the embedded version string and in carrying debug information.

### `v2026.06.18-preview` — June producer

| Field | Value | Status |
|---|---|---|
| Distribution | `cryptoleo79/tsunagi-preview`, release `v2026.06.18-preview`, published 2026-06-19T01:19:50Z | observed |
| Executable | `tsunagi-node-v2026.06.18-preview-linux-x86_64`, 23,650,688 bytes, with debug information | observed |
| SHA-256 | `b93a60fe731cc381633fc1b8170b66da9e03032a0ca71569ecf2bdb8e2047dd9` | matches `SHA256SUMS` and the GitHub asset digest |
| Source commit | **NOT RECORDED.** No commit id is embedded and no provenance manifest was published. | gap |
| Candidate source (original) | `4862e4e05979c9e4673d5a24fdd50a70039f107f` (tree `61d232cfce1793cfb19b1246c574880a974fbed1`, 2026-06-08) | **inferred, not verified**; not in this repository |
| Working tree clean at build? | **UNKNOWN** | gap |
| Compiler | Zig `0.16.0` | version string and standard-library paths in the binary |
| Build mode and flags | **UNKNOWN.** Host-native CPU: the binary contains AVX-512 instructions. | partly observed |
| Rebuild result | **not attempted** — commit, flags and build host are not established | gap |
| `cockpit` asset (v6.4, Python) | The asset is itself source. It is not in the original history either. | gap |
| `guardiand` supervisor named in the release notes | Not in the original history either. | gap |

Why `4862e4e0` is the candidate (all commit ids in this paragraph are original): it is the
last commit on that lineage before the release
date; the last change to `tsunagi-node/src` or `build.zig` before the release is `d02d9c7c`
(2026-06-08), and there are no code changes between that commit and `c8082152`
(2026-07-04). All 207 project source files named in the binary's debug line table exist in
that tree, while four of them are missing from `main`. This is consistency evidence only. It
does not rule out uncommitted changes on the build host.

The October follower source is this same code plus one change, `4cdcde42` (origin
`FindIntersect` encoding; four files).

## What is *not* in the selected source

- Signing keys, operational certificates, node state, and operator configuration.
- The Mainnet development line.
- The June `cockpit` console and the `guardiand` supervisor (see gaps above).
- The original commit history, and with it the June producer's candidate source.

## Reproduce the October executable

See [`BUILD.md`](../BUILD.md#reproduce-the-october-2026-follower-executable).
