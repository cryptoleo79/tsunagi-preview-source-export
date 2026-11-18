# Building TSUNAGI — A Deterministic Cardano Node in Zig

## 1. Introduction

Most blockchain networks depend on a single node implementation. Every validator, every relay, and every block producer runs the same binary. When that binary has a bug, the bug affects the entire network simultaneously. When its diagnostic output is insufficient, every operator shares the same blind spot. When its architecture makes a particular class of experimentation difficult, the entire ecosystem loses access to that research direction.

This is infrastructure monoculture, and it is a structural weakness in systems that claim decentralization as a defining property.

Cardano is no exception. Despite its formally specified protocol design and peer-reviewed consensus mechanism, the network has historically relied on a single production node implementation. This concentration means that protocol assumptions go untested by independent derivation, operational tooling reflects the perspective of a single development team, and architectural alternatives remain unexplored.

TSUNAGI is an independent Cardano node architecture designed to address this gap.

## 2. Why TSUNAGI Exists

TSUNAGI exists because implementation diversity strengthens decentralized networks.

When two independent implementations, derived separately from the same protocol specification, produce identical state transitions across thousands of blocks, the protocol is validated more deeply than any single implementation can achieve on its own. When the implementations disagree, the disagreement surfaces a specification ambiguity, an implementation defect, or both — information that strengthens the protocol regardless of which side is correct.

Beyond protocol validation, an independent implementation introduces alternative perspectives on node architecture, operational tooling, and diagnostic methodology. TSUNAGI does not aim to replace existing Cardano nodes. It aims to provide an independent verification surface, an alternative operational experience, and a platform for infrastructure experimentation that a single-implementation ecosystem cannot support.

The project is developed independently, without Catalyst funding or governance grants, by a single engineer working from first principles against the Ouroboros protocol specification.

## 3. Determinism as a Design Principle

TSUNAGI is built on the principle that deterministic behavior is a prerequisite for trust.

A deterministic system produces identical outputs from identical inputs, every time, on every machine, in every execution context. This is not an optimization or a best-effort goal — it is an architectural invariant enforced through design decisions at every layer.

The ledger pipeline maintains no global mutable state. Every function receives its dependencies through explicit parameters. Every error is represented in the function's return type. Every heap allocation passes through a caller-provided allocator. There are no environment variable lookups below the integration boundary, no hidden caches, no implicit configuration, and no control flow that depends on timing or thread scheduling.

Zig was chosen as the implementation language because it aligns with these requirements. Zig provides explicit memory ownership without garbage collection — every allocation has a visible lifetime and a deterministic deallocation point. There are no finalizer ordering surprises, no garbage collector pauses introducing latency variance, and no hidden allocations behind syntactic convenience. The language compiles to a single static binary with no runtime interpreter or virtual machine. The resulting binary's behavior is determined entirely by its source code and its two linked libraries: LMDB for persistent storage and libsodium for cryptographic primitives.

The practical consequence of determinism is that the system can explain itself. A bug in a deterministic pipeline is reproducible: replay the same inputs, observe the same outputs, locate the divergence. A behavior change between two builds is detectable: process the same block corpus through both versions, compare the results. Determinism transforms debugging from forensic archaeology into systematic comparison.

## 4. Architecture Overview

TSUNAGI is organized as a layered stack where each subsystem addresses a specific operational concern. The layers interact through explicit interfaces with no shared global state between them.

At the top, the observability stack provides structured diagnostics and automated health management:

- **KAGAMI** (Mirror) — Produces point-in-time health snapshots as structured JSON, covering tip age, roll counters, fragment coverage, LMDB availability, and derived health status.
- **YAMORI** (Guardian) — Evaluates node health against configurable thresholds, maintains an event memory of adverse conditions, and engages defensive postures when degradation accumulates.
- **TATE** (Shield) — Verifies the integrity of propagation artifacts, checking fragment ancestry continuity and assessing serving readiness for downstream peers.
- **KURA** (Storehouse) — Manages artifact retention, detects stale state, and performs automated stabilization to maintain operational readiness.

Below the observability stack, **TSURUGI** (Sword) implements the Ouroboros node-to-node protocol: ChainSync for tip tracking and intersection finding, BlockFetch for block retrieval, multiplexed bearer transport, and versioned handshake negotiation.

The **Ledger Pipeline** receives raw block bytes from TSURUGI and processes them through a deterministic state machine: block_stream extracts typed delta structures from CBOR block bodies, block_apply dispatches state mutations across three operational modes, ledger_pipeline wraps the UTxO map and undo stack into a stateful container, and the replay harness enables offline execution of recorded block sequences.

At the base, **LMDB** provides persistent UTxO storage with ACID transactional semantics, copy-on-write crash safety, and single-writer isolation.

Each layer can be tested independently, substituted experimentally, and diagnosed through its own interface. A defect in one layer cannot corrupt another layer's data structures because no layer holds references into another layer's memory.

## 5. Shadow Ledger Verification

Verifying a new ledger implementation on a live network is inherently risky. A silent state divergence — where the node's UTxO set drifts from the network's consensus state — may not manifest until blocks later, when the node rejects a valid transaction or accepts an invalid one.

TSUNAGI addresses this with a shadow verification system. Two independent pipeline instances process identical transaction deltas from every block:

The **primary pipeline** operates in the configured mode (memory-only, LMDB truth, or LMDB native) and produces the authoritative UTxO state. The **shadow pipeline** operates in memory-only mode with its own UTxO map, its own undo stack, and its own allocator. After every block application — forward or backward — the follower compares the undo stack depth of both pipelines.

A match confirms agreement on the number of successful state transitions. A mismatch triggers an immediate diagnostic report identifying the exact block and slot where divergence occurred.

The shadow never influences the primary path. It shares no mutable state with the primary pipeline. A crash or error in the shadow increments a counter and continues — the primary path is unaffected. This design provides continuous runtime verification with the safety guarantee that the verification mechanism itself cannot introduce the failures it is designed to detect.

Extended validation on the Cardano preview network has produced zero shadow mismatches across all sessions.

## 6. Persistent Storage and LMDB Truth Mode

The pipeline supports three persistence modes that provide graduated storage guarantees.

In **memory-only** mode, the UTxO map exists only in process memory. This mode is used by the shadow pipeline and for testing. In **lmdb_native** mode, LMDB is the sole state authority — a storage failure is a hard error. In **lmdb_truth** mode, the system attempts LMDB persistence with automatic fallback to memory when storage conditions are not met.

The lmdb_truth mode implements a three-stage strategy. First, a read-only **preflight coverage check** scans the LMDB store to count how many of the block's consumed inputs are present. If any are missing — as expected when the store was populated from a snapshot that predates the chain tip — the pipeline skips the write path entirely, avoiding a wasted transaction. Second, if all inputs are present, the pipeline opens a write transaction, applies the mutations, and commits. Third, if any stage fails, the pipeline falls back to memory application and performs a **shadow-write** that inserts the block's produced outputs into LMDB.

The shadow-write mechanism is convergent: each block application increases the store's coverage of recently produced outputs, progressively closing the gap between the store's contents and the live chain state. The preflight diagnostic reports the exact coverage ratio for each block, enabling operators to track convergence and determine when the store is ready for promotion to lmdb_native mode.

## 7. Self-Healing Infrastructure

TSUNAGI's operational model follows the BAEY loop: Build, Analyze, Evolve, Yield.

The node **builds** its state through deterministic block processing. It **analyzes** its own health through the observability subsystems — KAGAMI captures state, YAMORI evaluates thresholds, TATE verifies fragment integrity, KURA checks artifact freshness. It **evolves** its operational posture in response to detected conditions — engaging safe-mode when adverse events accumulate, triggering stabilization when artifacts become stale. It **yields** stable, verified output to the network and the operator.

This is not external monitoring attached to a passive process. The health evaluation logic lives inside the node binary, executes as part of the node's operational cycle, and produces structured output that both humans and automation can consume directly. An operator running a TSUNAGI node does not need an external dashboard to know whether the node is healthy. The node tells them.

The design principle is straightforward: a node that understands its own health can protect itself. A node that cannot understand its own health depends on someone else to protect it, and that dependency is a single point of failure in a system designed to have none.

## 8. Operator Experience

TSUNAGI is designed for the people who run infrastructure under real constraints.

Stake pool operators maintain nodes on limited budgets, often as a secondary activity alongside other responsibilities. They need systems that are easy to deploy, easy to diagnose, and easy to trust overnight. A node that requires external scripts to evaluate health, custom dashboards to visualize state, and community forum posts to diagnose common failure modes has externalized its operational responsibility to its operators.

TSUNAGI internalizes that responsibility. Health evaluation is a CLI command. Diagnostics are structured JSON. Tip age, fragment coverage, storage availability, and artifact freshness are queryable from the binary itself. The node compiles to a single file, runs with minimal configuration, and reports its own state in a format suitable for both human reading and automated ingestion.

The goal is not to eliminate operational expertise. It is to ensure that the expertise required is about understanding the node's structured output, not about reverse-engineering its internal behavior from unstructured logs.

## 9. The Vision

TSUNAGI is not only a Cardano node. It is an architecture for infrastructure experimentation.

The modular pipeline — with explicit interfaces between extraction, application, undo management, and storage — permits controlled substitution of any layer. A researcher can replace the storage backend and use the shadow system for automatic correctness validation. A developer can feed synthetic block sequences through the replay harness and observe pipeline behavior under conditions the live network may never produce. An engineer can instantiate multiple pipelines with different configurations and compare their outputs on identical inputs.

The pipeline's abstract UTxO types — a consumed input identified by a hash and an index, a produced output pairing that identifier with an address and a value — describe the spending model shared by multiple blockchain families. This abstraction positions the pipeline as a reusable component for cross-chain research, not merely a Cardano-specific artifact.

The long-term vision is an ecosystem where multiple independent implementations validate each other continuously, where protocol changes are tested against diverse architectures before deployment, and where operators choose the node implementation that best fits their operational requirements and risk tolerance. TSUNAGI is one contribution toward that ecosystem.

## 10. Closing

TSUNAGI demonstrates that a Cardano node can be deterministic, observable, self-healing, and architecturally open to experimentation — simultaneously, without compromising on any axis.

The work continues. Extended mainnet validation, operator tooling, research collaboration, and cross-chain experimentation lie ahead. The methodology remains constant: build on verified foundations, measure before claiming, and design systems that earn the trust required to run unattended.

**Let It Run. Let It Resolve.**
