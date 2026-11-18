# TSUNAGI — Architecture and Current State

**A Deterministic Cardano Node in Zig**

---

## 1. What TSUNAGI Is Today

TSUNAGI is an independent Cardano node implementation written in Zig 0.13.0.
It synchronizes the Cardano blockchain, maintains a live UTxO set, and provides
deep runtime observability through bounded stores, append-only journals, and a
deterministic health engine.

TSUNAGI is operational on the Cardano preview network. It follows the chain,
decodes transactions, tracks mempool submissions, correlates transaction
confirmations, monitors peer behavior, and evaluates slot rhythm — all through
passive observation with zero external dependencies beyond libc, LMDB, and
libsodium.

### Current capabilities

- Full Ouroboros NodeToNode protocol: ChainSync, BlockFetch, TxSubmission, KeepAlive
- Deterministic ledger pipeline with shadow verification
- LMDB-backed UTxO persistence with snapshot bootstrap
- Block processing with per-transaction decode summaries
- Mempool submission capture and decode
- Confirmation correlation (mempool tx → block inclusion tracking)
- Transaction propagation lifecycle tracking
- Slot-level timing observation
- Peer connection and block reception tracking
- Composite health scoring engine
- Producer readiness evaluation harness (offline-only)
- Offline candidate artifact bundle (near-term)
- Operator dashboard, block explorer, and labs experiments
- 46 CLI subcommands for diagnostics, alignment, and regression testing

### What TSUNAGI is not yet

- **Not a producing node.** TSUNAGI does not produce blocks on any network.
  The producer readiness harness evaluates readiness offline but does not
  activate block production.
- **Not a mainnet validator.** Current validation is on the preview testnet.
  Mainnet operation requires additional testing and hardening.
- **Not a full indexer.** Observability is bounded and recent-only. TSUNAGI
  tracks the last N events, not the complete chain history.

---

## 2. Architecture

### 2.1 Runtime Layers

```
┌──────────────────────────────────────────────────────────────┐
│                     OPERATOR LAYER                           │
│  CLI commands · JSON generators · Web dashboards             │
├──────────────────────────────────────────────────────────────┤
│                   OBSERVABILITY LAYER                        │
│  Health engine · Slot observatory · Peer observatory         │
│  Confirmation tracker · Propagation tracker · Mempool stores │
├──────────────────────────────────────────────────────────────┤
│                    PROCESSING LAYER                          │
│  Block decode · TX summaries · UTxO delta extraction         │
│  Journal appenders · Bounded runtime stores                  │
├──────────────────────────────────────────────────────────────┤
│                     PIPELINE LAYER                           │
│  Follower · ChainSync · BlockFetch · TxSubmission            │
│  Ledger pipeline · Shadow verification · LMDB persistence    │
├──────────────────────────────────────────────────────────────┤
│                    PROTOCOL LAYER                            │
│  Mux bearer · Handshake · Message codec · Framing            │
├──────────────────────────────────────────────────────────────┤
│                    TRANSPORT LAYER                           │
│  TCP · TLS · Byte transport · Memory transport (testing)     │
└──────────────────────────────────────────────────────────────┘
```

### 2.2 Named Subsystems

| Name | Role |
|------|------|
| TSURUGI | Protocol engine: ChainSync, BlockFetch server and client |
| TATE | Rollback resilience: undo stack, fragment defense, ancestry verification |
| YAMORI | Guardian: health checks, event memory, safe-mode engagement |
| KURA | Storage: LMDB persistence, retention, stabilization |
| KAGAMI | Diagnostics: health snapshots, telemetry, operator reporting |
| BAeY | Bayesian peer scoring and anomaly detection |

### 2.3 Bounded Runtime Stores

All runtime stores use fixed-capacity arrays. No dynamic allocation.

| Store | Module | Capacity |
|-------|--------|----------|
| Block delta history | `delta_history.zig` | 200 |
| Block decode store | `block_decode_store.zig` | 100 |
| TX summary history | `tx_summary_history.zig` | 50 |
| Mempool capture | `mempool_capture.zig` | 256 |
| Mempool summaries | `mempool_summary_history.zig` | 128 |
| Confirmation tracker | `confirmation_tracker.zig` | 256 pending / 256 confirmed |
| Propagation tracker | `propagation_tracker.zig` | 256 |
| Slot observatory | `slot_observatory.zig` | 512 |
| Peer observatory | `peer_observatory.zig` | 512 |

### 2.4 Append-Only Journals

Journals are NDJSON files written by `journal.zig`. One line per event.

| Journal | Entry Type | Content |
|---------|-----------|---------|
| `journal.ndjson` | `roll_forward` | Block accepted: slot, block_no, tx_count, utxo_delta |
| `journal.ndjson` | `roll_backward` | Rollback: slot, block_no |
| `journal.ndjson` | `tx_decode` | Per-block TX summaries: inputs, outputs, fee, metadata |
| `journal.ndjson` | `slot_observation` | Slot timing: gap_from_prev_block, observed_unix |
| `journal.ndjson` | `peer_event` | Peer connect/disconnect/block_received |
| `mempool.ndjson` | `mempool_tx` | Submitted TX: txid, inputs, outputs, fee, size |
| `confirmation.ndjson` | `confirmed_tx` | Mempool TX confirmed in block: confirmation_seconds |
| `propagation.ndjson` | `propagation_tx` | TX lifecycle: submitted → observed → confirmed |

### 2.5 JSON Generator Layer

Shell scripts read journals and produce JSON files served by the web layer.

| Script | Output | Source |
|--------|--------|--------|
| `generate-status-json.sh` | `status.json` | `journal.ndjson` |
| `generate-delta-json.sh` | `delta.json` | `journal.ndjson` |
| `generate-blocks-json.sh` | `blocks.json` | `journal.ndjson` |
| `generate-block-detail-json.sh` | `block-detail-*.json` | `journal.ndjson` |
| `generate-decode-json.sh` | `decode.json` | `journal.ndjson` |
| `generate-mempool-json.sh` | `mempool.json` | `mempool.ndjson` |
| `generate-confirmation-json.sh` | `confirmation.json` | `confirmation.ndjson` |
| `generate-network-json.sh` | `network.json` | `journal.ndjson` |
| `generate-slot-observatory-json.sh` | `slot-observatory.json` | `journal.ndjson` |
| `generate-operator-json.sh` | `operator.json` | aggregated JSON |
| `generate-health-json.sh` | `health.json` | aggregated JSON |

All scripts follow the jq-first, sed-fallback pattern with integer-only arithmetic.

---

## 3. Observability Architecture

### 3.1 Health Engine

The health engine (`health_engine.zig`) computes a composite health score
from five components. All arithmetic is integer-only. No floating point.

| Component | Weight | Inputs | Scoring |
|-----------|--------|--------|---------|
| Peer stability | 25% | connect_count, disconnect_count | Disconnect rate penalty |
| Slot rhythm | 20% | avg_gap (×10 for integer) | Gap deviation from ideal |
| Block stability | 25% | blocks_processed, rollbacks | Rollback rate penalty |
| Confirmation latency | 15% | avg_confirmation_seconds | Latency tier scoring |
| Mempool pressure | 15% | pending_count | Queue depth penalty |

**State thresholds:** excellent (≥90), healthy (≥75), degraded (≥60), critical (<60).

Missing data yields a neutral score of 80 per component.

### 3.2 Confirmation Correlation

The confirmation tracker (`confirmation_tracker.zig`) correlates locally
submitted transactions with their appearance in blocks.

1. Transaction submitted via POST → `addPending(txid, metadata)`
2. Each new block scanned for pending txids using `findTxidInBodies()`
3. Match found → `markConfirmed(txid, block_no, slot, timestamp)`
4. Confirmation latency = `confirmed_unix - received_unix`

Matching uses exact txid comparison: `blake2b256(tx_body)`. No heuristic
or structural matching.

### 3.3 Propagation Tracking

The propagation tracker (`propagation_tracker.zig`) records the full
lifecycle of locally submitted transactions:

```
local_submitted → block_observed → confirmed
```

Each stage records a unix timestamp. Confirmation seconds are computed
as `confirmed_unix - local_submitted_unix`.

### 3.4 Slot Observatory

The slot observatory (`slot_observatory.zig`) records when blocks arrive
relative to their slot. Computes inter-block gaps (how many slots elapsed
between consecutive blocks). Used by the health engine to assess slot
rhythm regularity.

### 3.5 Peer Observatory

The peer observatory (`peer_observatory.zig`) records peer connect,
disconnect, and block_received events. Used by the health engine to
assess peer stability.

---

## 4. Producer Readiness Harness

The producer readiness harness is an **offline-only** evaluation tool.
It does not produce blocks. It does not transmit data. It does not
activate any forge path.

### 4.1 Module: `producer_readiness.zig`

Pure-computation module. No IO. No network. No side effects.

**Evaluation checks:**

| Check | What it verifies |
|-------|-----------------|
| Leadership | Praos threshold: `u_x1e12 < thresh_x1e12` via E34 fixed-point |
| KES validity | Current period within `[opcert_start, opcert_start + max_evolutions)` |
| Sign + Verify | Sum6Kes sign on header body CBOR, then verify with root PK |
| Candidate build | Local header + body candidate assembly (TSUNAGI domain types) |

**ReadinessState contract:**

| State | Meaning |
|-------|---------|
| `READY` | Leader for slot, all checks pass, all material present |
| `NOT_LEADER` | All material present, checks pass, but not elected leader |
| `NOT_READY` | Missing material, failed check, or skipped mandatory check |

`READY` requires: `vrf_available == true`, leadership pass, KES pass,
sign_verify pass (not skip, not fail), candidate pass.

### 4.2 CLI: `producer-ready`

```
tsunagi-node producer-ready --slot <N> [options]

Options:
  --vrf-skey <path>           VRF signing key file
  --kes-skey <path>           KES signing key file
  --pool-id <64 hex>          Pool ID
  --stake-x1e9 <N>            Stake fraction × 1e9
  --kes-period <N>            Current KES period
  --opcert-start-period <N>   OpCert start period
  --out <path>                Write JSON report to file
  --bundle-dir <path>         Write artifact bundle when READY

Exit codes: 0=READY, 1=NOT_LEADER, 2=NOT_READY, 3=usage, 4=IO
```

### 4.3 Offline Candidate Artifact Bundle

When `--bundle-dir` is provided and state is `READY`, the harness writes:

| File | Content |
|------|---------|
| `producer-report.json` | Full readiness evaluation report |
| `candidate-header.cbor` | Cardano header CBOR (header body + KES signature) |
| `candidate-body.cbor` | Body parts concatenated (tx_bodies, witnesses, aux_data, invalid_txs) |
| `candidate-block.cbor` | Full block CBOR: `[era, [header, body parts...]]` |
| `candidate-hashes.json` | block_hash, body_hash, candidate_header_hash, candidate_body_hash |

These artifacts are **never transmitted**. They exist for offline
verification, testing, and future integration planning.

---

## 5. Web and Operator Layer

### Dashboards

| Page | URL Path | Content |
|------|----------|---------|
| Homepage | `/` | Telemetry strip, delta pill, node status |
| Operator | `/operator/` | Pipeline stats, health score, block timeline |
| Explorer | `/explorer/` | Block list, TX decode drill-down, live TX flow |
| Status | `/status/` | Node sync status |

### Labs (Experimental)

| Page | URL Path | Content |
|------|----------|---------|
| Confirmation | `/labs/confirmation.html` | Confirmation latency, pending/confirmed lists |
| Mempool | `/labs/mempool.html` | Recent mempool submissions |
| Network | `/labs/network.html` | Peer events timeline |
| Slots | `/labs/slots.html` | Slot observation data |
| CBOR Playground | `/labs/cbor-playground.html` | Interactive CBOR decoder |

All pages are single-file HTML with inline CSS/JS, dark theme,
XMLHttpRequest polling. No external dependencies.

---

## 6. Roadmap Summary

### Completed

1. Deterministic node foundation (chain following, shadow verification)
2. Persistent ledger engine (LMDB, snapshots)
3. Self-healing infrastructure (KAGAMI, YAMORI, TATE, KURA)
4. Block processing pipeline (TX decode, UTxO deltas, journals)
5. Operator dashboard and explorer
6. Mempool observability (capture, decode, summary history)
7. Confirmation correlation (mempool → block inclusion tracking)
8. Propagation lifecycle tracking
9. Slot observatory and peer observatory
10. Composite health engine
11. Producer readiness harness (offline-only)

### Active

12. Offline candidate artifact bundle

### Next (ordered by dependency)

13. TX decode enrichment (txid in TxSummary)
14. Full KES evolution testing and alignment
15. Mainnet readiness validation
16. Live block production activation (requires all prior milestones)

### Path to Producing Node

```
Current state: Chain follower with deep observability
                        │
                        ▼
    Offline readiness harness ← DONE
                        │
                        ▼
    Offline candidate artifacts ← ACTIVE
                        │
                        ▼
    Full KES/VRF/OpCert alignment verification
                        │
                        ▼
    Mainnet shadow validation
                        │
                        ▼
    Controlled testnet block production
                        │
                        ▼
    Mainnet block production
```

Each step requires the previous step's verification criteria to be met.
No step is skipped. No shortcut.

---

## 7. Design Constraints

- **Zig 0.13.0.** Single static binary. No runtime interpreter.
- **Two C dependencies:** LMDB (persistence), libsodium (cryptography).
- **Bounded memory.** All runtime stores have compile-time capacity limits.
- **Integer arithmetic only** for scoring, thresholds, and consensus math.
- **Forward-only development.** No history rewriting. No force push.
- **Deterministic ledger pipeline.** Pure functions. No hidden state.
- **Observability is passive.** Never alters runtime behavior.
- **Producer readiness is offline-only.** No broadcast. No forge activation.
