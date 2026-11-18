# TSUNAGI Roadmap

This document describes the development phases of the TSUNAGI node architecture. Each phase builds on the foundations established by its predecessors, extending capability while preserving the deterministic execution guarantees and operational clarity that define the project.

Phases are ordered by dependency, not by calendar. A phase is complete when its verification criteria are satisfied, not when a deadline arrives.

---

## Phase 1 — Deterministic Node Foundation

**Status: Complete**

The foundational phase established the core architecture: a deterministic Cardano node written entirely in Zig, capable of following the chain, maintaining a live UTxO set, and verifying its own ledger transitions at runtime.

- **Zig-only architecture** — Single static binary with two external library dependencies (LMDB, libsodium). No runtime interpreter, garbage collector, or dynamic framework.
- **Deterministic ledger pipeline** — Modular state machine separating delta extraction (block_stream), state application (block_apply), undo management, and pipeline orchestration (ledger_pipeline) into independently testable components.
- **Shadow ledger verification** — Independent memory-only pipeline instance processing identical deltas on every block, with per-block undo-depth parity checking and immediate divergence detection.
- **Replay harness** — Offline execution driver for recorded block sequences, enabling deterministic regression testing, cross-build verification, and adversarial input testing.
- **Preview network validation** — Extended synchronization sessions on the Cardano preview network confirming zero shadow mismatches, zero apply errors, and zero rollback errors.

### Verification Criteria

- Shadow parity maintained across all observed blocks
- Replay harness produces bitwise reproducible results across executions
- All inline tests pass under the leak-detecting allocator
- Release build compiles without warnings

---

## Phase 2 — Persistent Ledger Engine

**Status: Complete**

The persistence phase connected the deterministic pipeline to durable storage, enabling the node to retain UTxO state across restarts and bootstrap from pre-computed snapshots.

- **LMDB truth mode** — Three-stage persistence strategy: read-only preflight scan, atomic LMDB write transaction, automatic memory fallback with shadow-write convergence. Three operational modes (memory_only, lmdb_truth, lmdb_native) allow operators to select persistence guarantees.
- **Snapshot bootstrap system** — TSF2 format for UTxO set serialization with Blake2b-256 integrity digest and Ed25519 signature attestation. Import recomputes the digest and rejects corrupted or tampered snapshots.
- **State digest verification** — CLI command computing a Blake2b-256 digest over the complete LMDB UTxO set, enabling offline cross-node state comparison without transmitting the full set.
- **Preflight coverage diagnostics** — Read-only LMDB scan counting consumed inputs present in the store before write transactions are opened. Coverage metrics (found/total) propagate through the result structure to operator diagnostics.
- **Storage reliability improvements** — Transaction abort on any write failure, shadow-write convergence mechanism, and bounded undo stack with correct memory reclamation across all eviction paths.

### Verification Criteria

- LMDB truth mode operates with zero data loss across process restarts
- Snapshot export-import round-trip preserves state digest
- Preflight diagnostics accurately report coverage ratios
- Shadow-write mechanism demonstrates measurable convergence over time

---

## Phase 3 — Self-Healing Infrastructure

**Status: Complete**

The observability phase embedded structured health evaluation, integrity verification, and automated stabilization directly into the node binary.

- **KAGAMI diagnostics** — Read-only diagnostic mirror producing JSON health snapshots, human-readable reports, and continuous telemetry streams. Captures tip age, roll counters, fragment coverage, LMDB availability, and derived health status.
- **YAMORI guardian monitor** — Threshold-based health evaluation with event memory and safe-mode engagement. Seven structured checks covering follower liveness, tip age, LMDB availability, fragment integrity, and artifact freshness.
- **TATE fragment defense** — Fragment ancestry verification, coverage evaluation, and operator recommendations. Detects discontinuities in the propagation fragment and assesses serving readiness for downstream peers.
- **KURA stabilization layer** — Automated artifact maintenance with retention policy enforcement, stale artifact detection, and scheduled stabilization runs.
- **BAEY self-healing operational loop** — Build-Analyze-Evolve-Yield cycle where the node builds state through deterministic processing, analyzes its own health, evolves its operational posture, and yields stable output.

### Verification Criteria

- KAGAMI snapshots accurately reflect node state at capture time
- YAMORI threshold crossings trigger appropriate event records
- TATE detects fragment ancestry breaks within one evaluation cycle
- KURA stabilization runs complete without operator intervention

---

## Phase 4 — Operator Infrastructure

**Status: In Progress**

The operator phase focuses on reducing the operational burden for stake pool operators and relay infrastructure administrators deploying TSUNAGI nodes.

- **SPO-friendly relay deployment** — Streamlined deployment workflow for operators running TSUNAGI as relay infrastructure. Reduced configuration surface with sensible defaults for common deployment scenarios.
- **Lightweight node runtime** — Optimization of memory footprint and startup time for resource-constrained environments. Efficient use of LMDB memory mapping for large UTxO sets without proportional heap allocation.
- **Deterministic observability tools** — Operator-facing CLI commands that produce structured, actionable output. Health evaluation, coverage assessment, and artifact status available as single-command queries.
- **Automated artifact stabilization** — End-to-end automation of fragment sealing, snapshot refresh, and coverage maintenance without manual intervention or external scheduling.

### Verification Criteria

- Node operates within defined memory bounds under sustained synchronization
- Operator can assess node health from CLI output without external tools
- Artifact stabilization maintains serving readiness across restart cycles
- Deployment requires no configuration beyond network selection and peer address

---

## Phase 5 — Research Platform

**Status: Planned**

The research phase positions the deterministic pipeline and its supporting infrastructure as a platform for blockchain state machine research.

- **Deterministic replay validation** — Expanded replay corpus covering edge cases, epoch boundaries, protocol parameter updates, and extended rollback sequences. Automated regression detection across code versions.
- **Alternative storage engines** — Evaluation of storage backends beyond LMDB using the five-operation transactional interface. Candidates include embedded key-value stores, append-only log structures, and tiered caching architectures. Shadow verification provides automatic correctness checking for any candidate.
- **Experimental node configurations** — Multi-pipeline instantiation for differential analysis. Concurrent operation of pipelines with different apply modes, storage backends, or configuration parameters on identical block streams.
- **Advanced observability tooling** — Extended diagnostic capabilities including UTxO set analytics, transaction pattern analysis, and long-duration operational trend reporting.

### Verification Criteria

- Replay corpus covers all Cardano eras and known edge cases
- At least one alternative storage backend passes shadow verification on a representative block sequence
- Multi-pipeline configuration produces comparable results to single-pipeline operation
- Observability extensions operate without measurable impact on synchronization performance

---

## Phase 6 — Ecosystem Contribution

**Status: Planned**

The ecosystem phase extends TSUNAGI's contributions beyond a single node implementation to the broader blockchain infrastructure landscape.

- **Long-term independent Cardano implementation** — Sustained operation as an independent node on the Cardano mainnet, providing ongoing protocol validation through implementation diversity. Continuous shadow verification and periodic cross-node state digest comparison.
- **Research collaboration** — Engagement with other independent implementation efforts, academic research groups, and protocol specification teams. Exchange of replay corpora, verification methodologies, and operational experience.
- **Cross-chain UTxO experimentation** — Exploration of the pipeline's abstract UTxO types as a common execution substrate for multiple UTxO-based blockchain families. Evaluation of shared application logic, undo semantics, and storage interfaces across chain-specific extraction layers.
- **Infrastructure resilience through client diversity** — Contribution to the Cardano ecosystem's structural resilience by maintaining a production-quality alternative implementation that can validate protocol changes, detect specification ambiguities, and provide operational diversity for network participants.

### Verification Criteria

- Sustained mainnet operation with zero state divergence from the reference implementation
- Published verification methodology and replay corpus available for community use
- At least one cross-chain pipeline instantiation processing non-Cardano block data
- Documented protocol specification feedback derived from independent implementation experience

---

## Phase 7 — Adaptive Architecture

**Status: Research Direction**

The adaptive phase extends TSUNAGI from a self-healing node toward a system capable of evidence-bounded operational adaptation and network-level structural observability.

- **Concentration measurement** — Observable stake distribution, delegation flow, and infrastructure diversity metrics at the protocol layer. Measurement infrastructure that governance mechanisms can consume, without implementing governance itself.
- **Evidence-bounded state transitions** — Controlled operational mode shifts triggered by operator-defined thresholds on measured conditions. Auditable transition records with full rollback capability.
- **Anti-capture observability** — Network-level structural health reporting that makes concentration vectors visible before they become irreversible.
- **Operator policy framework** — Declarative specification of transition boundaries, evidence thresholds, and authorized operational regimes, enabling adaptive behavior without autonomous decision-making.

### Verification Criteria

- Concentration metrics accurately reflect known stake distribution on test networks
- State transitions execute only within operator-defined boundaries and produce auditable records
- Adaptive decisions are fully reversible and rollback paths are verified
- No adaptive behavior occurs without explicit operator pre-authorization

---

## Guiding Principles

The following principles apply across all phases:

- **Forward-only progress.** Each phase builds on verified foundations. No phase compromises the guarantees established by its predecessors.
- **Evidence before claims.** Capabilities are validated through measured results before being documented as complete.
- **Determinism is non-negotiable.** No phase introduces non-deterministic behavior into the ledger pipeline.
- **Operator clarity over developer convenience.** Design decisions favor operational transparency over implementation abstraction.
- **Minimal dependencies.** New capabilities are implemented within the existing dependency set (Zig, LMDB, libsodium) unless a compelling case exists for an additional dependency.

**Let It Run. Let It Resolve.**
