# TSUNAGI — Vision & Roadmap

**Tsunagi — Connecting the world from Japan, with the precision of code and the spirit of omotenashi.**

> A Zig-only Cardano light node that follows the chain and maintains local UTxO state.

## Why

Cardano's reference node (cardano-node) is written in Haskell, requires ~24 GB RAM
for a full sync, and is difficult to embed or cross-compile. We want a minimal,
dependency-free alternative that:

* runs on a $5/month VPS (≤2 GB RAM, 1 vCPU),
* follows the tip of the chain via ChainSync/BlockFetch,
* maintains a live LMDB-backed UTxO set that can answer balance queries,
* exports/imports snapshots in a compact binary format (TSF), and
* is fully written in Zig (no C/Haskell/Rust dependencies beyond libc+lmdb).

## Phases

| Phase | Tag | Description |
|-------|-----|-------------|
| f1 | v0.7.0–v0.7.9 | Zig mini-protocol stack: TCP framed mux, Handshake, ChainSync, BlockFetch |
| f2 | v0.7.10–v0.7.14 | CBOR decoder, tx_decode, in-memory UTxO, undo stack, capture files |
| f3 | v0.7.15–v0.7.20 | LMDB UTxO store: truth/fallback, seed, backfill, observability, TSF snapshots |
| **f4** | **v0.7.21** | **Bootstrap command, VISION.md, public-ready packaging** |
| f5 | — | Full UTxO convergence: truth_ratio → 1.0 via larger snapshots |
| f6 | — | Balance query HTTP API: GET /utxo/:address |
| f7 | — | Multi-asset support (native tokens in UTxO values) |
| f8 | — | Stake / delegation tracking |

## Architecture

```
┌───────────────────────────────────────────┐
│                main.zig                    │
│   CLI: run | bootstrap | snapshot-*        │
│         replay | lmdb-seed | backfill      │
└────────────┬──────────────────────────────┘
             │
     ┌───────▼────────┐     ┌──────────────┐
     │  follower.zig   │────▶│ http_metrics  │
     │  ChainSync loop │     │  :9080        │
     └───────┬─────────┘     └──────────────┘
             │
     ┌───────▼────────┐
     │  tx_decode.zig  │  CBOR → TxDeltas (consumed/produced)
     └───────┬─────────┘
             │
     ┌───────▼────────┐     ┌──────────────┐
     │   utxo.zig      │────▶│  lmdb_utxo   │
     │   in-memory      │     │  on-disk      │
     └─────────────────┘     └──────────────┘
```

## Bootstrap Quick Start

```bash
# 1. Build
cd tsunagi-node && zig build -Doptimize=ReleaseSafe

# 2. Bootstrap from a TSF snapshot
./zig-out/bin/tsunagi-node bootstrap --file utxo-mainnet.tsf

# 3. Run
./zig-out/bin/tsunagi-node run --net mainnet --lang en
```

## License

MIT
