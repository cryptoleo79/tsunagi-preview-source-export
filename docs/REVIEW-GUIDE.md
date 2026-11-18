# Review guide

A starting point for someone reading this source for the first time, in particular for
conformance review against a published TSUNAGI Preview binary. It is an index over
documents that already exist in the tree. Where this page and an older document disagree
about *status*, treat this page as the later statement and the older document as a dated
record.

Written 2026-11-18 against the October 2026 Preview follower source (original commit
`4cdcde42`; in this repository, tag `october-2026-follower-source`). This repository is a
source export with listed differences from that commit: see
[`../SOURCE-EXPORT.md`](../SOURCE-EXPORT.md).

## Read these first

| Question | Document |
|---|---|
| Which source built which binary? | [`SOURCE-RELEASE-MAP.md`](SOURCE-RELEASE-MAP.md) |
| How do I build and test it? | [`../BUILD.md`](../BUILD.md) |
| How is the system laid out? | [`../tsunagi-node/docs/TSUNAGI_ARCHITECTURE_OVERVIEW.md`](../tsunagi-node/docs/TSUNAGI_ARCHITECTURE_OVERVIEW.md), [`TSUNAGI_NODE_ARCHITECTURE.md`](TSUNAGI_NODE_ARCHITECTURE.md) |
| What does the project say it does not do? | [`../README.md`](../README.md) ("What is not yet proven"), [`threat-model.md`](threat-model.md) |
| What went wrong, and when? | [`../tsunagi-node/docs/incidents/`](../tsunagi-node/docs/incidents/), [`../tsunagi-node/docs/ZIG_0_16_BUG_HUNT.md`](../tsunagi-node/docs/ZIG_0_16_BUG_HUNT.md) |
| How do I report a vulnerability? | [`../SECURITY.md`](../SECURITY.md) |

## Source map

All node code is under `tsunagi-node/`. Sizes are lines of Zig at this commit; "tests" counts
`test "…"` blocks in that directory. There are no Zig package dependencies.

| Path | Role | Lines | Tests |
|---|---|---:|---:|
| `src/main.zig` and other top-level `src/*.zig` | Entry point, command dispatch, protocol smoke tools, test roots | 8,933 | 120 |
| `src/net/chainsync/` | ChainSync client and the follower loop (rollback handling, recovery, cursor) | 13,582 | 5 |
| `src/net/miniproto/`, `handshake/`, `muxwire/`, `framing/`, `transport/`, `codec/`, `cbor/` | Node-to-Node handshake, mux, BlockFetch, TxSubmission2, CBOR | 3,675 | 6 |
| `src/net/ledger/` | Transaction decode, UTxO application, trust and belief-state modules | 13,343 | 251 |
| `src/net/consensus/` | Header, VRF, KES and Praos threshold checks | 2,933 | 70 |
| `src/net/mempool/` | Local mempool and propagation tracking | 974 | 30 |
| `src/net/metrics/`, `health/`, `network/` | HTTP status and metrics surfaces, health engine, peer observatory | 6,878 | 3 |
| `src/net/ntc/` | Node-to-Client local state query client | 604 | 4 |
| `src/net/*.zig` | Peer configuration, rotation, connection registry, propagation server | 3,811 | 19 |
| `src/protocols/` | ChainSync and BlockFetch *server* sides | 1,418 | 6 |
| `src/producer/` | Preview block production: leader check, nonce, KES, forge gates, acceptance tracking | 17,532 | 93 |
| `src/store/` | LMDB UTxO store, header store, snapshots, backfill | 3,917 | 0 |
| `src/ledger/` | Block stream and ledger harness | 1,988 | 39 |
| `src/replay/`, `src/archive/` | Capture and replay, fragment coverage | 2,442 | 13 |
| `src/guardian/`, `src/kagami/` | Operator guardian CLI (`TATE`, `KURA`), `KAGAMI` snapshot | 1,050 | 20 |
| `src/cli/` | Operator commands, alignment and regression harnesses, BAeY loop | 28,026 | 23 |
| `src/ops/` | Shutdown, allocator counting, autonomy flags | 310 | 0 |
| `tools/` | `plutus-evaluator`, `praos-verify`, evaluator fixtures | — | — |

Outside `tsunagi-node/src`: `scripts/` (Python and shell helpers, a Haskell arithmetic
oracle), `web/` (a snapshot of the project website), `docs/`, `ops/systemd/` (example
units) and `evidence/` (recorded artifacts).

## Maturity

Five separate levels. A component at one level has not thereby reached the next.

1. **Implemented** — code exists in this tree.
2. **Integrated** — reachable from the `tsunagi-node` executable.
3. **Tested** — covered by `zig build test` or a recorded regression harness.
4. **Independently accepted** — checked by someone other than the maintainer.
5. **Deployed** — run by the maintainer against a live network.

| Area | Implemented | Integrated | Tested | Independently accepted | Deployed |
|---|---|---|---|---|---|
| NtN handshake, mux, ChainSync client, BlockFetch client | yes | yes (`run`) | unit tests; maintainer-recorded Preview qualification of the October binary | **no** — external conformance review pending | Preview (maintainer) |
| Transaction decode and UTxO application, LMDB persistence, cold reopen | yes | yes (`run`) | unit tests; maintainer-recorded Preview qualification | **no** | Preview (maintainer) |
| Header, VRF, KES, Praos threshold checks | yes | yes | unit tests and alignment harnesses against recorded vectors | **no** | Preview (maintainer) |
| Local mempool, localhost submit, TxSubmission2 | yes | yes | unit tests | **no** | Preview (maintainer) |
| ChainSync / BlockFetch server side, propagation server | yes | yes (`propagate-serve`) | unit tests | **no** | Preview (maintainer, June producer) |
| Block production (`src/producer/`) | yes | yes, behind `TSUNAGI_FORGE_ENABLE` and operator keys | unit tests | **no**. The maintainer records Preview blocks adopted on chain in June–July 2026; those records are checkable against public chain data and were not re-verified for this guide. | Preview (maintainer, June producer). **Excluded** from the October binary's stated scope. |
| Plutus script evaluation | **no general interpreter.** `tools/plutus-evaluator` and `src/net/ledger/eval_external.zig` answer known-case fingerprints and structural rules only. | partial | fixtures | **no** | no |
| Guardian CLI (`guardian`, `KURA`, `TATE`), `KAGAMI`, YAMORI | yes | yes (operator tooling; no consensus role) | unit tests | **no** | Preview (maintainer) |
| BAeY (peer-connection management) | yes | yes (`baey-loop`, `baey-regress`) | regression harness | **no** | Preview (maintainer) |
| `guardiand` supervisor and `cockpit` console (June release) | **not in this repository** | — | — | — | Preview (maintainer, June) |
| KINTSUGI | In this tree: an acceptance-history record only (`tsunagi-node/docs/kintsugi/`). No runtime component here. | — | — | — | — |
| Mainnet operation | Network profiles and example units exist. | selectable (`--net mainnet`); a fatal gate in `main.zig` refuses forge-enable outside Preview | **not qualified** | **no** | **no** |

"Deployed" here means the maintainer has run it. It is not a recommendation that anyone else
should.

"Not qualified" is a statement about testing and qualification status. It is not a license
condition. The source in this repository is licensed under MIT OR Apache-2.0
([`../LICENSE`](../LICENSE)), which does not restrict the network or purpose it is used for.
The prebuilt Preview binaries are published separately in
[`cryptoleo79/tsunagi-preview`](https://github.com/cryptoleo79/tsunagi-preview) under that
repository's own Preview evaluation license, which excludes Mainnet use and continues to
apply to the binaries distributed there. That repository's documentation likewise describes
them as Preview-only, not for Mainnet or production. Nothing in this guide changes either
license or the qualification status.

BAeY, the Guardian family and KINTSUGI are part of a wider design described in
[`baey.md`](baey.md), [`../tsunagi-node/docs/operator-guardian.md`](../tsunagi-node/docs/operator-guardian.md),
[`../tsunagi-node/docs/kura.md`](../tsunagi-node/docs/kura.md) and
[`../tsunagi-node/docs/yamori.md`](../tsunagi-node/docs/yamori.md). Those documents describe
intent as well as implementation. The table above is the statement of what exists in this
commit.

## Known limitations at this commit

- **Not a complete validating node.** The README's "What is not yet proven" list stands.
  No claim of consensus parity with `cardano-node` is made.
- **Plutus.** There is no general Plutus interpreter in this tree. The external evaluator
  recognises known serialized-context cases and applies structural rules. Transactions
  whose validity depends on executing a script are outside what this source can decide.
- **Stale documents.** Several documents and the `web/` snapshot predate the June 2026 move
  to Zig 0.16 and still name Zig 0.13 or 0.15.2, or describe block production as unproven.
  They are kept as dated records. `zig.version` and [`../BUILD.md`](../BUILD.md) are current.
- **Release workflows.** `.github/workflows/release.yml` and `release-arm64.yml` still
  install Zig 0.13 and would not build this tree. They are left unchanged pending a
  maintainer decision; `ci.yml` is the maintained workflow.
- **Hard-coded peers.** `src/net/chainsync/follower.zig` carries a fixed list of five public
  relay addresses. Prefer `--peer`.
- **Local paths in an optional helper.** The `evidence-pack` command searches a historical
  developer-home path before falling back to `$HOME`. It is not on the sync path.
- **June producer provenance.** The June 2026 binary has no recorded source commit. See
  [`SOURCE-RELEASE-MAP.md`](SOURCE-RELEASE-MAP.md).
- **Maintenance.** Maintained by A$Y (Tsunagi Project). Independent conformance review is
  welcome.

## Structural backlog (not part of this preparation change)

Proposed, in priority order. None of these is required before source review.

1. Bring `release.yml` / `release-arm64.yml` to the pinned Zig version, or retire them.
2. Record a provenance manifest (commit, flags, toolchain hash) for every future binary, as
   the October release did; add a `THIRD-PARTY-NOTICES` file to release assets.
3. Move the `web/` snapshot out of the source tree into a separate repository, by ordinary
   forward commits.
4. Replace the fixed relay list and the developer-home search path with configuration.
5. Split `src/cli/` (28k lines) and `src/net/chainsync/follower.zig` into reviewable units;
   add unit tests for `src/store/`.
6. Refresh or clearly date the Zig 0.13-era documents and the comparison page on the website
   branch (its description of other implementations' tooling should be re-checked against
   their current public documentation).
7. Pin GitHub Actions by commit SHA.
