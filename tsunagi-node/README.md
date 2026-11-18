<p align="center"><img src="docs/assets/logo/tsunagi-logo-dark.png" width="420"></p>

# TSUNAGI

An independent Cardano node, written from scratch in Zig.

## What it is

TSUNAGI implements the Cardano Ouroboros Praos consensus protocol natively in Zig, with no dependency on the Haskell reference implementation or its runtime. The current capability cycle targets the **preview** testnet: block forging, header propagation, and chain following against live preview relays. It is a clean-room implementation built for operational transparency and minimal runtime footprint.

## What it is NOT

- **Not** a fork of `cardano-node` (the Haskell reference implementation). No shared code, no shared runtime, no IOG packages.
- **Not** mainnet-ready. Preview-only for the foreseeable future.
- **Not** a wallet, **not** an explorer, **not** a developer SDK.
- **Not** a drop-in replacement for `cardano-node`. The operational model, config surface, and on-disk layout are intentionally different.

## Current capability

- Conway-era block forging (header construction, body assembly, KES signing)
- ChainSync and BlockFetch server roles (Node-to-Node mini-protocols)
- VRF leadership evaluation against the active stake distribution
- KES hot-key signing with opcert counter tracking
- Mempool admission with transaction validation and decoding
- Sealed-artifact persistence and replay for forged blocks

## Quick start

Requires **Zig 0.15.2**, **lmdb**, and **libsodium** on the host.

```sh
git clone https://github.com/<org>/tsunagi-node.git && cd tsunagi-node
/path/to/zig-0.15.2/zig build -Doptimize=ReleaseSafe
TSUNAGI_HOME=/path/to/home ./zig-out/bin/tsunagi-node run --net preview --peer <host:port>
```

The default mode is `preview_safe` — TSUNAGI will forge locally and write sealed artifacts to `${TSUNAGI_HOME}` but will **not** broadcast to the network. Set `TSUNAGI_MODE=live` only after reading [`docs/operator-guide.md`](docs/operator-guide.md).

## Configuration

The canonical configuration file is `${TSUNAGI_HOME}/forge.env`, auto-loaded at startup. Format is plain `KEY=VALUE` lines; values from this file overwrite the inherited shell environment (`setenv` with `overwrite=1`), so the file is authoritative. Most operators only need to set:

| Variable | Purpose |
|---|---|
| `TSUNAGI_MODE` | `preview_safe` (default, no broadcast) or `live` (forge + broadcast). Single switch. |
| `TSUNAGI_FORGE_ENABLE` | Master enable for the forge path. |
| `TSUNAGI_FORGE_REQUIRE_GUARDIAN_CONFIRM` | Operator confirmation gate before signing. |
| Key paths | KES, VRF, opcert, cold-key delegate paths. |

Runtime hygiene handled automatically:

- **Single-instance lock** at `${TSUNAGI_HOME}/lock` (flock); a second instance refuses to start.
- **Log rotation** to `${TSUNAGI_HOME}/logs/node.log`, 5 MB × 5 files, tee'd from stdout/stderr.
- **Clean shutdown marker** at `${TSUNAGI_HOME}/clean` written on graceful exit; absence indicates a crash.

A safe starting template lives at [`docs/forge.env.example`](docs/forge.env.example).

### Local consensus state sources

TSUNAGI prefers local authoritative sources for forge-critical consensus inputs (canonical tip and current-epoch leader-election nonce) and treats external HTTP indexers as fallback / observability only. When the operator sets `TSUNAGI_CARDANO_NODE_SOCKET` to a reachable cardano-node socket, TSUNAGI reads both via `cardano-cli` directly:

| Input | Tier 1 (local) | Tier 2 (HTTP) | Tier 3 (cached) |
|---|---|---|---|
| canonical tip | `cardano-cli query tip` | Koios | n/a |
| epoch nonce | `cardano-cli query protocol-state` (`epochNonce` field) | Koios `epoch_params` | `nonce_state.json` |

Relevant env:

| Variable | Default | Purpose |
|---|---|---|
| `TSUNAGI_CARDANO_NODE_SOCKET` | unset | Path to local cardano-node socket. When set, enables Tier-1 cli fallback for tip + nonce. |
| `TSUNAGI_CARDANO_CLI` | `cardano-cli` | Override the cli binary path (defaults to PATH lookup). |
| `TSUNAGI_TESTNET_MAGIC` | `2` | Network magic for cli queries (preview = 2). |

Rate-limiting or outage on Koios no longer blocks consensus-critical state evaluation when the local socket is configured. State writes are monotonic in epoch — older nonces cannot overwrite newer ones, eliminating the boundary-oscillation class of bugs.

## Documentation

| File | Contents |
|---|---|
| [`docs/operator-guide.md`](docs/operator-guide.md) | Install, first run, lifecycle, mode transitions |
| [`docs/architecture.md`](docs/architecture.md) | Pipeline stages and control flow |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | Failure-mode table and recovery steps |
| [`docs/forge.env.example`](docs/forge.env.example) | Annotated configuration template |

## License and contributing

See `LICENSE` and `CONTRIBUTING.md` in the repository root. Issues and pull requests are welcome; please read the contributing guide before opening a PR — squash-merge with imperative `<scope>: <action>` titles is the house style.
