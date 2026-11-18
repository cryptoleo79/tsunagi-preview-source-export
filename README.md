# TSUNAGI

**TSUNAGI — a Zig-native Cardano node implementation focused on deterministic networking, ancestry-verified LMDB-backed ledger state, hardened transaction handling, operator visibility, and a verifiable trust stack.**

日本語版はこちら → [README.ja.md](README.ja.md)

> **Status and review entry points (2026-11-18).** This is the source for the public
> TSUNAGI **Preview** binaries. It is evaluation software: **not qualified for Mainnet,
> stake-pool or production use.** Public source access does not change that.
>
> This repository is a **source export**: its Git history was created for publication and
> is not the original development history. See [`SOURCE-EXPORT.md`](SOURCE-EXPORT.md).
>
> That is a statement of qualification status, not a license condition. This source is
> licensed under **MIT OR Apache-2.0** ([`LICENSE`](LICENSE)). The prebuilt Preview binaries
> are published separately in
> [`cryptoleo79/tsunagi-preview`](https://github.com/cryptoleo79/tsunagi-preview) under that
> repository's own Preview evaluation license, which continues to apply to the binaries
> distributed there.
>
> - Which source built which binary: [`docs/SOURCE-RELEASE-MAP.md`](docs/SOURCE-RELEASE-MAP.md)
> - Build and test: [`BUILD.md`](BUILD.md)
> - Source map, maturity levels, known limitations: [`docs/REVIEW-GUIDE.md`](docs/REVIEW-GUIDE.md)
> - Reporting a vulnerability: [`SECURITY.md`](SECURITY.md) · Third-party notices: [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)
>
> The rest of this README was last revised before June 2026. Where it describes status —
> for example block production as "not yet proven" — the review guide carries the later,
> dated statement.

## Project definition

TSUNAGI is a Zig-native Cardano node implementation in active development. It is built for operators and engineers who care about correctness, determinism, auditability, and operational clarity.

Its current trajectory is:

**light follower → snapshot/bootstrap/operator node → LMDB truth-backed node → fuller Zig-native Cardano node**

TSUNAGI is already materially beyond a minimal ChainSync follower, but it does **not** yet claim accepted forged block production, consensus parity, or production-ready block producer status.

## Reading the evidence

This repository contains runtime code, verification, and research. A test pass, protocol check, or observed relay interaction supports only the assertion and environment in its cited record. Network-accepted forging, consensus parity, full validation, and production block-producer readiness remain open until independently evidenced; do not infer them from a narrower milestone.

Use the [documentation directory](docs/) for detailed records, the [Japanese README](README.ja.md) for the translated overview, and [contribution guidance](CONTRIBUTING.md) for changes. For an operational claim, follow its receipt and independent audit to the exact commit and network.

## What TSUNAGI is

TSUNAGI is an operator-node and node-implementation effort for Cardano, written in Zig, with emphasis on:

- deterministic Node-to-Node behavior
- rollback-aware chain following
- ancestry-verified LMDB-backed ledger state
- hardened local transaction handling
- operator-first observability and control surfaces
- signed, verifiable trust-state direction

It is designed to stay lightweight, exact, and inspectable.

## What is currently proven

The following capabilities are supportable today:

- Node-to-Node handshake and chain following
- ChainSync progression with rollback-aware persistent state
- BlockFetch path
- ancestry-verified LMDB-backed UTxO / ledger application path
- local transaction admission and mempool visibility
- localhost submit surface for operator-controlled transaction submission
- TxSubmission2 serving and ingestion path
- operator HTTP / control-plane surfaces
- trust-stack direction with verifiable runtime artifacts
- preview-only controlled producer / propagation path components under guarded conditions
- propagation artifact coherence at forge promotion time
- per-connection acceptance tracing and receipt instrumentation for relay interactions

These are real engineering milestones. They are **not** the same as claiming full validating-node completeness or accepted block production.

## Current live target

The current live target is operational and explicit:

1. `relay_ahead=false` at connection time
2. `MsgRequestNext` observed after intersect
3. `MsgRollBackward` / `MsgRollForward` progression
4. BlockFetch request arrival
5. eventual proof of a network-accepted forged block

The first four are the immediate runtime path targets. The fifth remains **not yet proven**.

## What is not yet proven

TSUNAGI does **not** currently claim:

- network-accepted forged block production on Cardano
- consensus parity with `cardano-node`
- production-ready block producer status
- full validating-node completeness in the strongest Cardano sense

Those boundaries are intentional and should be read strictly.

## Key capabilities

### Deterministic networking and chain progression
TSUNAGI speaks Cardano Node-to-Node protocols with a strong focus on explicit state handling, rollback awareness, and operator-visible behavior.

### LMDB-backed truth-oriented state
TSUNAGI maintains ancestry-verified LMDB-backed state and is converging toward a stronger truth-backed node architecture rather than a transient follower-only model.

### Hardened transaction handling
TSUNAGI includes local transaction admission, mempool visibility, localhost submission, and TxSubmission2 path work aimed at safe, inspectable transaction flow.

### Operator-first visibility
TSUNAGI exposes practical control and inspection surfaces for status, mempool, state, metrics, and runtime diagnostics. Recent work includes artifact coherence proofing and acceptance-trace observability for relay interactions.

### Preview-only controlled producer path
Preview-only controlled producer and propagation experimentation exists behind guarded conditions. This work is valuable and real, but accepted forged block production is not yet proven, and public production-BP claims are intentionally withheld.

## Quick setup / operator workflows

### Relay setup
TSUNAGI includes a role-based installer for relay-oriented deployment.

```bash
./zig-out/bin/tsunagi-node setup --role relay
```

This installs the systemd user service, enables the relevant timers, starts the node, and prints useful status / log / metrics commands.

### Install from GitHub Release
```bash
./zig-out/bin/tsunagi-node setup --role relay --install latest
```

Downloads the latest release from GitHub, verifies SHA256, and installs to `~/.local/tsunagi/`. To pin a version:

```bash
./zig-out/bin/tsunagi-node setup --role relay --install v0.7.42
```

### Optional AutoSwitch
```bash
./zig-out/bin/tsunagi-node setup --role relay --autoswitch
```

Enables the AutoSwitch timer, which can move the node into LMDB-native mode after convergence conditions are met.

### Tools-only
```bash
./zig-out/bin/tsunagi-node setup --role tools
```

Installs operational tooling without starting the node service.

### Console / operator menu
```bash
./zig-out/bin/tsunagi-node console --lang en
./zig-out/bin/tsunagi-node console --lang ja
```

Interactive SSH-first operator menu for checking status, logs, metrics, timers, updates, and rollback paths.

### Producer / BP workflow

TSUNAGI includes preview-only guarded producer / propagation experimentation, but this is **not yet a publicly supported production BP workflow**. Production-ready block producer claims are intentionally withheld until live proof reaches the required standard.

## Local submit API

The running node exposes a localhost-only control plane on `127.0.0.1:9080`.

Submit a transaction as hex:

```bash
echo -n '83a100...' | curl -sS -H 'Content-Type: text/plain' -X POST --data-binary @- http://127.0.0.1:9080/tx/submit
```

Submit a transaction as raw CBOR:

```bash
curl -sS -H 'Content-Type: application/octet-stream' --data-binary @tx.cbor http://127.0.0.1:9080/tx/submit
```

Query mempool:

```bash
curl -sS http://127.0.0.1:9080/mempool
```

CLI equivalents:

```bash
./zig-out/bin/tsunagi-node submit-tx --hex 83a100...
./zig-out/bin/tsunagi-node submit-tx --file tx.cbor
./zig-out/bin/tsunagi-node submit-tx --file tx.cbor --offline
./zig-out/bin/tsunagi-node mempool
```

Safety boundary: localhost only (`127.0.0.1`). Hard limits: 64 KB per tx, 1024 items, 8 MB total.

## Networks and TSUNAGI_HOME isolation

TSUNAGI supports strict per-network state isolation.

```bash
tsunagi-node run --net preview
tsunagi-node run --net preprod
tsunagi-node run --net mainnet
tsunagi-node run --net sancho
```

Or use `TSUNAGI_NET` instead of `--net`.

Default homes:

| Network | TSUNAGI_HOME |
|---|---|
| mainnet | `~/tsunagi-home-mainnet` |
| preprod | `~/tsunagi-home-preprod` |
| preview | `~/tsunagi-home-preview` |
| sancho | `~/tsunagi-home-sancho` |

State isolation includes LMDB, captures, regress baselines, BAeY events, and genesis files. Do not reuse LMDB directories across networks.

Override: `TSUNAGI_HOME=/path/to/dir tsunagi-node run --net preview`

## Requirements

- Zig **0.15.2**
- Linux / macOS
- liblmdb, libsodium (IOHK VRF fork)
- Outbound TCP access to Cardano relays

## Build and test

```bash
cd tsunagi-node
zig build test
zig build -Doptimize=ReleaseSafe
```

## Operator and diagnostic surfaces

Read-only state query:

```bash
curl -s http://127.0.0.1:9080/state | python3 -m json.tool | head -n 60
```

This is an operator endpoint, not a wallet API. It returns runtime and state information such as tip, header authority, convergence, backfill, and gap metrics.

Footprint report:

```bash
./zig-out/bin/tsunagi-node footprint
```

Replay baseline / regression:

```bash
./zig-out/bin/tsunagi-node replay-baseline \
  --file ~/tsunagi-home-mainnet/captures/mainnet.bin \
  --out-dir /tmp/ts-bench

./zig-out/bin/tsunagi-node replay-regress \
  --file ~/tsunagi-home-mainnet/captures/mainnet.bin \
  --out-dir /tmp/ts-bench
```

## Documentation

- Vision / roadmap → [VISION.md](VISION.md)
- Manifesto → [MANIFESTO.md](MANIFESTO.md)
- Threat model → [docs/threat-model.md](docs/threat-model.md)
- Networks and `TSUNAGI_HOME` isolation → see the section above in this README
- Fork readiness proof → [docs/fork-ready-proof.md](docs/fork-ready-proof.md)

## Status note / truthful boundary

TSUNAGI has outgrown the label of "light ChainSync follower," but it has **not** yet reached the point where accepted forged block production, consensus parity, or production-ready BP status should be claimed.

By default, TSUNAGI is operated conservatively. Preview-only controlled producer and propagation experiments exist, but network-accepted forged block production is not yet proven and production BP claims are intentionally withheld.

The current public position is:

- substantial operator-node and node-path functionality is proven
- preview-only controlled producer / propagation work exists and is advancing
- artifact coherence and acceptance observability have materially improved the live path
- final proof of network-accepted forged block production is still pending

TSUNAGI should therefore be understood as a serious Zig-native Cardano node implementation in progress — already operationally meaningful, but still deliberately bounded in its public claims.
