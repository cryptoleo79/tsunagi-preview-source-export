# TSUNAGI Architecture Overview

Canonical reference for the current TSUNAGI system structure.

---

## System Overview Diagram

```
                        ┌─────────────────────────────────┐
                        │         WEB LAYER               │
                        │  Homepage · Operator · Explorer  │
                        │  Labs (confirmation, mempool,    │
                        │   network, slots, cbor)          │
                        └────────────────┬────────────────┘
                                         │ fetches JSON
                        ┌────────────────▼────────────────┐
                        │       JSON GENERATOR LAYER      │
                        │  12 shell scripts (jq/sed)       │
                        │  status · delta · blocks · decode│
                        │  mempool · confirmation · network│
                        │  slots · operator · health       │
                        └────────────────┬────────────────┘
                                         │ reads journals
                        ┌────────────────▼────────────────┐
                        │       JOURNAL LAYER             │
                        │  journal.ndjson (blocks/rollbacks│
                        │   tx_decode, slots, peers)       │
                        │  mempool.ndjson (submissions)    │
                        │  confirmation.ndjson (confirmed) │
                        │  propagation.ndjson (lifecycle)  │
                        └────────────────┬────────────────┘
                                         │ appended by
          ┌──────────────────────────────┼──────────────────────────┐
          │                              │                          │
┌─────────▼──────────┐  ┌───────────────▼──────────┐  ┌───────────▼──────────┐
│  BOUNDED STORES    │  │   OBSERVABILITY LAYER    │  │   BLOCK PROCESSING   │
│                    │  │                          │  │                      │
│  DeltaHistory  200 │  │  HealthEngine            │  │  TX decode summaries │
│  BlockDecode   100 │  │  SlotObservatory    512  │  │  UTxO delta extract  │
│  TxSummary      50 │  │  PeerObservatory    512  │  │  Block hash compute  │
│  MempoolCapt   256 │  │  ConfirmTracker    256+  │  │  Journal appenders   │
│  MempoolSum    128 │  │  PropagTracker     256   │  │                      │
└────────────────────┘  └──────────────────────────┘  └──────────┬───────────┘
                                                                  │
                        ┌─────────────────────────────────────────▼───────┐
                        │              FOLLOWER PIPELINE                  │
                        │  ChainSync · BlockFetch · TxSubmission          │
                        │  Ledger pipeline · Shadow verification          │
                        │  LMDB persistence · Snapshot bootstrap          │
                        │  on_roll_forward callback chain                 │
                        └─────────────────────┬──────────────────────────┘
                                              │
                        ┌─────────────────────▼──────────────────────────┐
                        │              PROTOCOL LAYER                    │
                        │  Mux bearer · Handshake · Message codec        │
                        │  Length-prefix framing · Protocol messages      │
                        └─────────────────────┬──────────────────────────┘
                                              │
                        ┌─────────────────────▼──────────────────────────┐
                        │              TRANSPORT LAYER                   │
                        │  TCP · TLS · Byte transport                    │
                        └────────────────────────────────────────────────┘
```

---

## Subsystem Map

### Runtime Core (`src/net/`)

| Directory | Subsystem | Key Modules |
|-----------|-----------|-------------|
| `chainsync/` | Chain following | `follower.zig`, `chainsync_mux_smoke.zig` |
| `ledger/` | Block processing | `tx_decode.zig`, `tx_decoder.zig`, `journal.zig`, `delta_history.zig` |
| `consensus/` | Consensus evaluation | `producer_readiness.zig`, `slot_observatory.zig` |
| `mempool/` | Mempool tracking | `confirmation_tracker.zig`, `propagation_tracker.zig`, `mempool_decoder.zig` |
| `network/` | Peer tracking | `peer_observatory.zig` |
| `health/` | Health scoring | `health_engine.zig` |
| `metrics/` | HTTP metrics | `http_metrics.zig` |
| `transport/` | TCP/byte transport | `tcp_byte_transport.zig`, `tcp_framed.zig` |
| `muxwire/` | Protocol multiplexing | `mux_bearer.zig`, `mux_header.zig` |
| `handshake/` | Network handshake | `handshake_codec.zig` |
| `codec/` | Message serialization | `message_codec.zig` |
| `cbor/` | CBOR encoding/decoding | `term.zig` |

### Producer Infrastructure (`src/producer/`)

| Module | Purpose |
|--------|---------|
| `producer.zig` | Core producer logic (VRF, scheduling, leadership) |
| `crypto/praos_threshold_e34.zig` | E34 fixed-point Praos threshold |
| `crypto/kes_sign.zig` | Sum6Kes signing |
| `crypto/kes_verify.zig` | Sum6Kes verification |
| `crypto/kes_evolve.zig` | KES key evolution |
| `crypto/sodium_vrf.zig` | libsodium VRF prove/verify |
| `header_candidate.zig` | Block header candidate (198 bytes) |
| `body_candidate.zig` | Block body candidate (≤128 bytes) |
| `cbor_block_header_body.zig` | Header body CBOR (10-element array, ≤1024 bytes) |
| `cbor_block_body.zig` | Block body CBOR (4-part body) |
| `cbor_block_full.zig` | Full block CBOR assembly |
| `kes_keyfile.zig` | cardano-cli key file parsing |
| `leader_model.zig` | Stake configuration |

### CLI Commands (`src/cli/`)

46 subcommands organized by domain:

- **Chain/setup:** `setup_cmd`, `console_cmd`, `cold_start_cmd`
- **Cryptography:** `vrf_selftest_cmd`, `vrf_align_cmd`, `kes_selftest_cmd`, `kes_inspect_cmd`, `kes_verify_cmd`, `kes_sign_test_cmd`, `kes_evolve_cmd`, `kes_align_cmd`
- **Producer:** `producer_ready_cmd`, `producer_regress_cmd`, `readiness_sim_cmd`, `forge_sim_cmd`
- **Candidate:** `block_candidate_verify_cmd`, `block_candidate_regress_cmd`, `header_align_cmd`, `header_body_align_cmd`, `candidate_verify_cmd`, `consensus_align_cmd`
- **Body/hash:** `bodyhash_selftest_cmd`
- **Praos:** `praos_selftest_cmd`, `praos_align_cmd`, `praos_exact_align_cmd`, `praos_regress_cmd`, `praos_threshold_regress_cmd`
- **Evidence:** `pack_verify_cmd`, `pack_now_cmd`, `evidence_pack_cmd`, `snapshot_proof_cmd`
- **Replay:** `replay_baseline_cmd`, `replay_regress_cmd`, `schedule_regress_cmd`
- **Guardian:** `guardian_cmd`
- **Ledger:** `ledger_harness_cmd`, `baey_loop_cmd`, `baey_regress_cmd`
- **Snapshot:** `kagami_cmd`
- **Utility:** `build_info_cmd`, `footprint_cmd`, `repro_report_cmd`

### Guardian and Storage

| Module | Path | Purpose |
|--------|------|---------|
| Guardian | `src/guardian/guardian.zig` | Operator oversight automation |
| Chain monitor | `src/guardian/tate.zig` | Chain state monitoring |
| Stabilizer | `src/guardian/kura_stabilizer.zig` | Artifact stabilization |
| LMDB UTxO | `src/store/lmdb_utxo.zig` | Persistent UTxO storage |
| Headers | `src/store/header_store.zig` | Header persistence |
| Snapshots | `src/store/snapshot_*.zig` | Snapshot generation/signing |

---

## Block Processing Pipeline

```
  Upstream Peer
       │
       ▼
  ┌─────────────┐
  │  ChainSync  │  MsgRollForward / MsgRollBackward
  └──────┬──────┘
         │
         ▼
  ┌─────────────────────┐
  │  on_roll_forward()  │  Callback in chainsync_mux_smoke.zig
  │                     │
  │  1. Extract header  │
  │  2. Decode TX       │──→ TxSummary[32] per block
  │  3. UTxO deltas     │──→ BlockDelta (consumed/produced)
  │  4. Block hash      │
  │  5. Store updates   │──→ DeltaHistory, BlockDecodeStore, TxSummaryHistory
  │  6. Journal append  │──→ journal.ndjson (roll_forward, tx_decode, slot, peer)
  │  7. Confirmation    │──→ Scan pending txids against block tx_bodies
  │     correlation     │    Match → confirmation.ndjson
  │  8. Slot observe    │──→ SlotObservatory ring buffer
  │  9. Peer observe    │──→ PeerObservatory ring buffer
  └─────────────────────┘
         │
         ▼
  ┌─────────────────────┐
  │  Ledger Pipeline    │  Shadow verification
  │  block_apply()      │  LMDB persistence
  │  undo management    │  Rollback resilience
  └─────────────────────┘
```

---

## Observability Data Flow

```
  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
  │ Runtime      │    │ Runtime      │    │ Runtime      │
  │ Stores       │    │ Journals     │    │ Callback     │
  │ (ring bufs)  │    │ (NDJSON)     │    │ Chain        │
  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘
         │                   │                   │
         │    ┌──────────────▼──────────────┐    │
         │    │     JSON Generator Layer    │    │
         │    │  (cron: every N seconds)    │    │
         │    │                            │    │
         │    │  journal.ndjson ──→ status.json, delta.json, blocks.json,  │
         │    │                    decode.json, network.json,              │
         │    │                    slot-observatory.json                   │
         │    │  mempool.ndjson ──→ mempool.json                          │
         │    │  confirm.ndjson ──→ confirmation.json                     │
         │    │  *.json ──────────→ operator.json, health.json            │
         │    └──────────────┬──────────────┘    │
         │                   │                   │
         │    ┌──────────────▼──────────────┐    │
         │    │       Web Layer             │    │
         │    │  (static HTML, XHR poll)    │    │
         │    │                            │    │
         │    │  / ──────────→ Homepage     │    │
         │    │  /operator/ ──→ Operator    │    │
         │    │  /explorer/ ──→ Explorer    │    │
         │    │  /labs/*  ────→ Experiments │    │
         │    └─────────────────────────────┘    │
         │                                       │
         ▼                                       ▼
  HTTP /metrics endpoint              Health engine (pure computation)
  (runtime store snapshots)            Reads JSON files → composite score
```

---

## Current Boundaries

### What runs in the Zig binary

- Chain following (ChainSync, BlockFetch)
- Block processing (TX decode, UTxO deltas, hash computation)
- Runtime stores (all ring buffers)
- Journal appenders (NDJSON writes)
- HTTP metrics endpoint (serves runtime store snapshots)
- Mempool TX capture (on TxSubmission accept)
- Confirmation correlation (on each new block)
- Slot and peer observation (on each event)
- Producer readiness evaluation (CLI only, not runtime loop)

### What runs outside the binary

- JSON generator scripts (shell, cron-scheduled)
- Health engine scoring (shell script reads JSON, mirrors Zig health_engine.zig)
- Web pages (static HTML served by nginx/caddy)
- Journal pruning scripts (retention management)

### What does not exist yet

- Live block production runtime loop
- Mainnet validation
- Full TX indexing
- WebSocket streaming
- External API (REST/gRPC)
- Multi-peer block propagation with TSUNAGI as source
