# TSUNAGI Roadmap

Current development state, completed milestones, active work, and
planned next steps. Ordered by dependency, not by calendar.

---

## Completed Milestones

### Phase 1 — Deterministic Node Foundation

- Zig-only Cardano node (Zig 0.13.0, single static binary)
- Full Ouroboros NodeToNode protocol: ChainSync, BlockFetch, TxSubmission, KeepAlive
- Deterministic ledger pipeline: delta extraction → state application → undo management
- Shadow ledger verification: independent pipeline instance, per-block parity checking
- Replay harness: offline deterministic regression testing
- Preview network validation: zero shadow mismatches, zero apply errors

### Phase 2 — Persistent Ledger Engine

- LMDB-backed UTxO persistence (three operational modes)
- Snapshot bootstrap system (TSF2 format, Blake2b-256 digest, Ed25519 signature)
- State digest verification (offline cross-node comparison)
- Preflight coverage diagnostics
- Shadow-write convergence mechanism

### Phase 3 — Self-Healing Infrastructure

- KAGAMI diagnostics: health snapshots, telemetry, operator reporting
- YAMORI guardian: threshold-based health evaluation, event memory, safe-mode
- TATE fragment defense: ancestry verification, coverage evaluation
- KURA stabilization: retention policy enforcement, automated maintenance
- BAeY self-healing loop: Build-Analyze-Evolve-Yield operational cycle

### Phase 4 — Block Processing Pipeline

- Per-transaction decode summaries (inputs, outputs, fee, metadata flag)
- UTxO delta extraction into callback chain
- Block delta ring buffer (DeltaHistory, capacity 200)
- Block decode store (BlockDecodeStore, capacity 100)
- TX summary history (TxSummaryHistory, capacity 50)
- Journal appenders: roll_forward, roll_backward, tx_decode
- JSON generators: status, delta, blocks, block-detail, decode
- Operator dashboard with pipeline stats and health score
- Block explorer with TX drill-down and per-block detail

### Phase 5 — Mempool Observability

- Mempool TX capture on submission (MempoolBuffer, capacity 256)
- Mempool decode: inputs, outputs, fee, metadata extraction
- Mempool summary history (MempoolSummaryStore, capacity 128)
- Journal appender: mempool_tx
- JSON generator: mempool.json
- Labs mempool explorer page

### Phase 6 — Confirmation Correlation

- Confirmation tracker: pending (256) + confirmed (256) ring buffer
- Exact txid matching: blake2b256(tx_body) correlation
- Block scan on roll_forward: findTxidInBodies for each pending tx
- Journal appender: confirmed_tx
- JSON generator: confirmation.json
- Labs confirmation page
- Explorer "Recent Confirmations" panel

### Phase 7 — Propagation Tracking

- Propagation tracker: full TX lifecycle (submit → observe → confirm)
- PropagationTracker ring buffer (capacity 256)
- Journal appender: propagation_tx
- Propagation server integration

### Phase 8 — Network Observability

- Slot observatory: inter-block gap tracking (capacity 512)
- Peer observatory: connect/disconnect/block_received events (capacity 512)
- Journal appenders: slot_observation, peer_event
- JSON generators: slot-observatory.json, network.json
- Labs pages: slots, network

### Phase 9 — Health Engine

- Composite health scoring: 5 components, weighted average
- Integer-only arithmetic: peer 25%, slot 20%, block 25%, confirm 15%, mempool 15%
- State classification: excellent/healthy/degraded/critical
- Zig reference implementation (health_engine.zig)
- Shell mirror implementation (generate-health-json.sh)
- Health score on operator dashboard

### Phase 10 — Producer Readiness Harness

- Standalone readiness evaluation module (producer_readiness.zig)
- Praos leadership check via E34 fixed-point threshold
- KES key validity check (period range, expiration)
- Sum6Kes sign + verify round trip
- Local candidate assembly (header + empty body)
- ReadinessState contract: READY / NOT_LEADER / NOT_READY
- CLI command: producer-ready with JSON report output
- 16 inline tests
- Offline-only: no broadcast, no forge activation

---

## Active Milestone

### Phase 11 — Offline Candidate Artifact Bundle

- ArtifactBundle type: header CBOR, body parts, full block CBOR, hashes
- buildArtifactBundle: pure computation, KES sign, full block assembly
- CLI --bundle-dir: write 5 artifact files when READY
- Files: producer-report.json, candidate-header.cbor, candidate-body.cbor,
  candidate-block.cbor, candidate-hashes.json
- Offline-only: artifacts written to disk, never transmitted

**Status:** Implementation complete, pending verification.

---

## Planned Milestones (ordered by dependency)

### Phase 12 — TX Decode Enrichment

- Add txid_hex to TxSummary struct
- Pass tx_bodies_cbor through decode pipeline
- Compute canonical txid per transaction during block decode
- Update tx_decode journal entries with txid field
- Update decode JSON generator
- Update explorer TX drill-down with txid display

### Phase 13 — Full KES/VRF Alignment Verification

- Test with real preview testnet VRF and KES key files
- Verify KES evolution across multiple periods
- Confirm VRF prove/verify alignment with cardano-node reference vectors
- Confirm header body CBOR alignment with cardano-node headers
- Regression test corpus for all producer crypto primitives

### Phase 14 — Mainnet Shadow Validation

- Extended synchronization on mainnet
- Shadow verification on mainnet blocks
- State digest comparison with cardano-node at known checkpoints
- Performance profiling under mainnet load

### Phase 15 — Controlled Testnet Block Production

- Activate forge path on preview testnet only
- Produce blocks using real keys with live stake
- Monitor produced blocks through the full pipeline
- Verify produced blocks are accepted by cardano-node peers
- Operational key rotation testing

### Phase 16 — Mainnet Block Production

- Full mainnet block production capability
- Operator tooling for key management and monitoring
- Production hardening based on testnet experience
- Independent operation as a Cardano block producer

---

## Path to Producing Node

```
  DONE  ──────────────────────────────────────────────
  │
  │  Phase 1-9: Follower + observability + health
  │  Phase 10: Offline readiness harness
  │
  ACTIVE ─────────────────────────────────────────────
  │
  │  Phase 11: Offline artifact bundle
  │
  NEXT  ──────────────────────────────────────────────
  │
  │  Phase 12: TX decode enrichment
  │  Phase 13: KES/VRF alignment verification
  │
  FUTURE ─────────────────────────────────────────────
  │
  │  Phase 14: Mainnet shadow validation
  │  Phase 15: Testnet block production
  │  Phase 16: Mainnet block production
  │
  ────────────────────────────────────────────────────
```

Each phase depends on the previous phase's verification criteria being
met. No phase is skipped. No shortcut.

---

## Guiding Principles

- **Forward-only progress.** Each phase builds on verified foundations.
- **Evidence before claims.** Capabilities are validated through measured
  results before being documented as complete.
- **Determinism is non-negotiable.** No phase introduces non-deterministic
  behavior into the ledger pipeline.
- **Operator clarity over developer convenience.** Design decisions favor
  operational transparency over implementation abstraction.
- **Minimal dependencies.** Zig, LMDB, libsodium. Nothing else unless
  there is a compelling case.
- **Offline before online.** Producer features are validated offline
  before any network activation.
