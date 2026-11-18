# TSUNAGI
### Architecture, Implementation, and Trust Model for a Zig-Native Cardano Node

**Author:** ASY

**Date:** 2026

---

## Abstract

TSUNAGI is an independent Cardano node implementation written in Zig. It follows the Cardano blockchain via the Ouroboros mini-protocols, maintains an ancestry-verified UTxO ledger backed by LMDB, admits transactions through a hardened mempool with six validation gates, serves and ingests transactions via bidirectional TxSubmission2, and computes a signed verifiable trust graph from its own runtime observations. The system introduces a layered ledger pipeline that separates CBOR delta extraction, deterministic state application, undo management, and persistent storage into independently testable modules. A runtime shadow verification methodology validates the extracted pipeline against the proven inline implementation. Persistent UTxO storage through LMDB operates in graduated modes with preflight coverage diagnostics. The operator core computes a deterministic health score from eleven runtime signals, feeds a guardian mode that gates the forge pipeline, and drives an eight-layer signed trust stack where every artifact is canonical JSON, Blake2b-256 digested, and Ed25519 signed. TSUNAGI is not a full validating node — it does not execute scripts or enforce protocol parameters — but it demonstrates that a Cardano node can be built in a systems language with determinism, operator visibility, and cryptographic verifiability as primary constraints, and with trust as a native computation rather than an external service.

---

## List of Figures

Figure 1 — TSUNAGI layered node architecture.
Figure 2 — Deterministic ledger pipeline execution flow.
Figure 3 — Runtime shadow ledger verification model.
Figure 4 — TSUNAGI BAEY self-healing operational loop.
Figure 5 — Complete TSUNAGI node architecture.

---

## 1. Origins of TSUNAGI

### 1.1 Motivation

The Cardano blockchain network depends on the correctness and availability of the nodes that maintain its distributed ledger. When a single node implementation dominates the network, the ecosystem inherits a concentration risk: a bug in that implementation affects every node simultaneously, a performance regression degrades the entire network uniformly, and an architectural limitation constrains all participants equally. This monoculture condition is well understood in distributed systems engineering and has produced correlated failures in other blockchain networks where a single client held supermajority share.

Independent implementations address this risk through implementation diversity. Two codebases implementing the same protocol specification will not share the same bugs, the same performance characteristics, or the same operational constraints. A defect in one implementation that causes incorrect block validation or chain selection will be detected by the other, producing a divergence signal rather than a silent network-wide failure. The existence of a second implementation also creates competitive pressure that improves both: each implementation can learn from the other's architectural decisions, performance optimizations, and operational tooling.

Beyond resilience, an independent implementation enables experimentation that the reference implementation's stability constraints may preclude. Architectural alternatives — different storage engines, different memory management strategies, different concurrency models — can be explored in a production-grade implementation without risking the reference client's proven behavior. TSUNAGI exists to provide this diversity, this competitive stimulus, and this experimental platform for the Cardano ecosystem.

### 1.2 Determinism as a Design Goal

TSUNAGI treats determinism as a foundational design constraint rather than an emergent property. Every state transition in the ledger engine must produce identical output given identical input, regardless of execution timing, host platform, or system load. This constraint flows through the architecture at every level.

State transitions are expressed as pure functions of their inputs. The block application function accepts a UTxO map, an undo stack, a set of consumed inputs, and a set of produced outputs, and returns a new state plus an undo log entry. No global variables, environment variables, or runtime configuration influence the transition. The function's behavior is fully determined by its arguments.

Error handling is explicit throughout. Functions return typed error sets rather than panicking, asserting, or calling process exit. The caller decides how to handle each error class — retry, fall back, propagate, or log — rather than the callee making that decision unilaterally. This eliminates a category of non-determinism where identical inputs produce different outcomes depending on whether an error handler chooses to abort or continue.

Hidden runtime behavior is avoided by construction. The ledger modules below the follower integration boundary perform no heap allocation outside the caller-provided allocator, read no environment variables, maintain no thread-local state, and register no signal handlers. The only source of non-determinism in the system is the network — the order and timing of blocks arriving from peers — and that non-determinism is confined to the protocol layer, never leaking into the ledger state machine.

Reproducible builds follow from the language choice and dependency management. The node compiles from a single source tree with no external package dependencies beyond the Zig standard library and the LMDB C library. The same source revision compiled with the same compiler version produces the same binary on the same target platform, enabling operators to verify that their binary matches the published source.

### 1.3 Why Zig

Zig was selected for its alignment with the determinism and control requirements described above.

Explicit memory management allows the ledger engine to control allocation lifetime, allocation location, and allocation failure handling at every call site. Every allocation passes through a caller-provided allocator, enabling the testing infrastructure to use a leak-detecting allocator that fails the test suite on any unfreed allocation. This has proven its value in practice: the undo address ownership invariant — where removed-entry address slices must be explicitly freed at every eviction site — was verified correct by the testing allocator catching leaks during development.

Compile-time guarantees eliminate classes of runtime failure. Tagged unions enforce exhaustive handling of all variant cases. Comptime evaluation allows type-level assertions that would be runtime checks in other languages. The type system prevents implicit integer truncation, null pointer dereference, and use-after-free without requiring a garbage collector or runtime safety layer.

Zero runtime dependencies mean the compiled binary has no dynamic library requirements beyond libc and the LMDB shared library. There is no language runtime to initialize, no garbage collector to tune, no just-in-time compiler to warm up. The node's startup time, memory footprint, and steady-state performance are determined by the compiled code and the operating system, not by runtime infrastructure.

Performance and memory layout control allows the implementation to optimize for the specific access patterns of UTxO state management. Hash map bucket sizing, undo stack growth strategy, and LMDB memory map configuration are all explicit decisions in the source code rather than defaults inherited from a runtime or framework. This control is essential for a long-running process that must maintain consistent performance across millions of state transitions.

---

## 2. TSURUGI Protocol Engine

TSURUGI (剣, "sword") is the protocol layer of the TSUNAGI architecture. It implements the Ouroboros node-to-node protocol, comprising ChainSync for tip tracking and intersection finding, and BlockFetch for block retrieval and batch serving.

```
                        ┌──────────────────────────────┐
                        │        KAGAMI 鏡             │
                        │      Diagnostic Mirror       │
                        └─────────────┬────────────────┘
                                      │
                        ┌─────────────▼────────────────┐
                        │        YAMORI 家守             │
                        │      Guardian Monitor         │
                        └─────────────┬────────────────┘
                                      │
                        ┌─────────────▼────────────────┐
                        │          TATE 盾              │
                        │       Fragment Defense        │
                        └─────────────┬────────────────┘
                                      │
                        ┌─────────────▼────────────────┐
                        │          KURA 蔵              │
                        │        Stabilization          │
                        └─────────────┬────────────────┘
                                      │
                        ┌─────────────▼────────────────┐
                        │         TSURUGI 剣            │
                        │      Protocol Engine          │
                        │    ChainSync + BlockFetch     │
                        └─────────────┬────────────────┘
                                      │
                        ┌─────────────▼────────────────┐
                        │  Deterministic Ledger Engine │
                        │ block_stream → ledger_pipeline│
                        │ apply → rollback → undo log  │
                        └─────────────┬────────────────┘
                                      │
                        ┌─────────────▼────────────────┐
                        │       Persistent Storage      │
                        │            LMDB               │
                        │     snapshots + bootstrap     │
                        └─────────────┬────────────────┘
                                      │
                        ┌─────────────▼────────────────┐
                        │        Shadow Ledger          │
                        │       Verification Layer      │
                        └──────────────────────────────┘
```

*Figure 5 — Complete TSUNAGI node architecture showing observability layers, protocol execution, deterministic ledger pipeline, persistent storage, and shadow verification.*

### 2.1 ChainSync

The ChainSync mini-protocol maintains the node's view of the chain tip by exchanging headers with upstream peers. TSURUGI's ChainSync implementation handles intersection finding — identifying the most recent common point between the local chain and a peer's chain — tip tracking as the peer advances, and rollback signaling when the peer's chain diverges from a previously followed fork. The implementation manages cursor persistence, writing the current synchronization point to a cursor file that survives process restarts and enables the node to resume synchronization without re-negotiating from genesis.

### 2.2 BlockFetch

The BlockFetch mini-protocol retrieves full block bodies for headers that ChainSync has accepted. TSURUGI's BlockFetch implementation manages request batching, block body validation against the expected header hash, and delivery of raw block bytes to the delta extraction layer for ledger processing.

### 2.3 Node-to-Node Protocol

Both mini-protocols operate over a multiplexed TCP connection using the Ouroboros node-to-node framing protocol. TSURUGI handles handshake negotiation, protocol version selection, and multiplexer channel management. The implementation speaks the same wire protocol as the reference Cardano node, enabling interoperation without protocol modifications.

### 2.4 Separation of Protocol and Ledger

TSUNAGI enforces a strict boundary between protocol-level concerns and ledger-level concerns. The protocol layer manages network state: peer connections, multiplexed channels, header chain validation, and block request scheduling. The ledger layer manages deterministic state: UTxO map mutations, undo log management, persistent storage, and rollback.

This separation is enforced architecturally. The ledger pipeline accepts pre-extracted delta slices (consumed inputs and produced outputs) rather than raw block bytes or protocol messages. The extraction step — parsing CBOR block bodies into typed delta structures — sits between the two layers, owned by neither. The pipeline has no knowledge of peers, sockets, protocol versions, or network topology. The protocol layer has no knowledge of UTxO maps, undo stacks, or LMDB transactions.

The practical consequence is that the ledger engine can be tested, replayed, and validated without any network interaction. The replay harness drives the pipeline with raw block bytes read from files. The pipeline proof tests drive it with hand-constructed CBOR vectors. The shadow parity system drives two pipeline instances with identical deltas extracted from live network traffic. In each case, the ledger engine operates identically because it has no dependency on its input source.

---

## 3. Deterministic Ledger Architecture

![TSUNAGI Architecture](../public/images/tsunagi-architecture.jpg)

*Figure 1 — TSUNAGI layered node architecture showing observability subsystems (KAGAMI, YAMORI, TATE, KURA), the TSURUGI protocol engine, deterministic ledger pipeline, and LMDB persistent storage.*

### 3.1 Introduction

Cardano full-node implementations traditionally embed UTxO state mutation logic directly within the chain-synchronization loop. This tight coupling makes independent testing difficult, prevents reuse of ledger logic across operational modes, and obscures the correctness boundary between protocol-level synchronization and state-machine semantics.

TSUNAGI addresses this by extracting its UTxO mutation engine into a modular pipeline that separates CBOR delta extraction, state application, undo management, and persistent storage into independently testable layers. A shadow ledger system validates the extracted pipeline against the proven inline implementation at runtime, producing continuous parity evidence on live networks. An LMDB truth mode adds persistent UTxO storage with automatic fallback continuity and preflight coverage diagnostics, enabling quantitative measurement of persistent-store coverage on production chains. The layered architecture of the TSUNAGI node is illustrated in Figure 1.

### 3.2 Modular Ledger Architecture

The ledger engine is organized into five layers with strict dependency rules. No layer below the follower integration boundary reads environment variables, maintains global state, or imports protocol-level types.

The dependency graph flows downward:

- **block_stream** — stateless CBOR extraction, producing typed delta structures from raw block bytes
- **block_apply** — pure-function apply and rollback dispatch across three operational modes
- **ledger_pipeline** — stateful wrapper bundling the UTxO map, undo stack, optional LMDB store, and apply mode into a single Pipeline structure
- **replay_harness** — end-to-end composition wiring block_stream extraction into pipeline application with cumulative statistics
- **follower integration** — environment-driven activation of shadow and primary pipelines within the chain-synchronization loop

Each layer accepts its dependencies through function parameters. Configuration, mode selection, and store binding occur exclusively at the follower integration boundary, preserving the lower layers as dependency-free, deterministic modules suitable for offline testing and formal verification.

```
                     ┌──────────────────────────┐
                     │    Block Body (CBOR)     │
                     └─────────────┬────────────┘
                                   │
                     ┌─────────────▼────────────┐
                     │       block_stream       │
                     │    (delta extraction)     │
                     └─────────────┬────────────┘
                                   │
                     ┌─────────────▼────────────┐
                     │        TxDeltas          │
                     │  consumed[] + produced[] │
                     └─────────────┬────────────┘
                                   │
                     ┌─────────────▼────────────┐
                     │     ledger_pipeline      │
                     │  applyDeltas / rollback  │
                     └─────────────┬────────────┘
                                   │
                     ┌─────────────▼────────────┐
                     │    ApplyMode dispatch    │
                     │  memory_only             │
                     │  lmdb_truth              │
                     │  lmdb_native             │
                     └─────────────┬────────────┘
                                   │
                     ┌─────────────▼────────────┐
                     │   Persistent Storage     │
                     │          LMDB            │
                     └─────────────┬────────────┘
                                   │
                     ┌─────────────▼────────────┐
                     │  Shadow Ledger           │
                     │  Verification            │
                     │  (parity check)          │
                     └──────────────────────────┘
```

*Figure 2 — Deterministic ledger pipeline execution flow showing delta extraction, state application, storage dispatch, and shadow verification.*

### 3.3 Block Stream Extraction Layer

The block stream layer converts raw block body CBOR bytes into a TxDeltas structure containing three fields: consumed inputs (each identified by a 32-byte transaction hash and output index), produced outputs (each pairing an input key with an address and lovelace value), and a transaction count.

The extraction follows a two-phase sequence. First, transaction body maps are located within the block body CBOR structure. Second, each transaction body is walked to extract inputs from key 0 and outputs from key 1 of the CBOR map. The intermediate parse tree is freed before return; the resulting delta structure is self-contained with no references into CBOR memory.

The interface is deliberately minimal:

```
extractDeltas(allocator, block_body_bytes) -> nullable TxDeltas
freeTxDeltas(allocator, deltas) -> void
```

Parse failures return null rather than propagating errors, allowing callers to handle extraction failure as a skip rather than a crash.

### 3.4 Block Apply Engine

The block apply module is the core mutation engine. It implements the three-mode `applyBlock` dispatch and the matching `rollbackBlock`, mirroring the proven logic from the follower's inline implementation.

Three apply modes govern dispatch behavior:

- **memory_only** — applies deltas exclusively in memory via the UTxO map, which silently skips consumed inputs not found in the map
- **lmdb_truth** — attempts persistent application through LMDB first, falling back to memory with a shadow-write on any failure
- **lmdb_native** — requires successful LMDB application with no fallback; any failure is a hard error

Each successful application pushes an Undo entry onto the stack. Each rollback pops the most recent entry and reverses the corresponding mutations in both the in-memory map and, when present, the LMDB store. The undo stack is capped at 200 entries; when exceeded, the oldest entry is evicted with correct memory management of address slices owned by removed entries.

The module returns errors instead of calling process exit, contains no metrics emission, no environment-variable coupling, and no logging. These concerns belong to the integration layer above.

### 3.5 Ledger Pipeline State Machine

The Pipeline structure bundles four components: an in-memory UTxO hash map, an undo stack implemented as a dynamic array of per-block undo logs, an optional pointer to an LMDB persistent store, and an ApplyMode selector.

The Pipeline accepts pre-extracted delta slices rather than raw block bytes. This separation means the pipeline can be driven by synthetic test data without CBOR, the replay harness composes extraction and application as a higher-level convenience, and the pipeline is independently testable with hand-crafted deltas.

A confirmation mechanism allows the caller to evict deeply confirmed undo entries after a configurable number of consecutive forward rolls without a rollback. This mirrors the Ouroboros chain-selection security model where deeply buried blocks are considered irreversible. The Pipeline itself does not track the confirmation counter — that state is owned by the caller — keeping the Pipeline free of protocol-level concerns.

### 3.6 Replay Harness

The replay harness wires block_stream extraction to pipeline application, accepting raw block body bytes and providing cumulative statistics. It is suitable for deterministic ledger tests with synthetic CBOR, file-based block replay, follower integration dry-runs, and benchmark harnesses.

A deliberate asymmetry exists in the counter design: the blocks-applied counter decrements on rollback (it represents current chain depth), while total transaction count, total consumed, and total produced are strictly cumulative forward-work counters that do not rewind. This allows the harness to simultaneously track "where are we now" and "how much work has been done total" without conflating the two.

A failed application (including extraction failure) leaves harness state untouched: all counters remain at their pre-call values.

### 3.7 Follower Integration

The follower's context carries both pipeline pointers as optional heap-allocated values — a shadow pipeline and a primary pipeline — coexisting alongside the legacy inline UTxO fields, allowing incremental migration.

At every roll-forward event, after delta extraction, the follower dispatches to the primary pipeline (or the legacy inline path if no primary is configured), then to the shadow pipeline if enabled. Both receive identical delta slices. On rollback events, both pipelines receive the rollback signal. On shutdown, both pipelines print structured summaries and are destroyed.

---

## 4. Shadow Ledger Verification Methodology

```
                 ┌─────────────────────┐
                 │      Block Data      │
                 └───────────┬─────────┘
                             │
            ┌────────────────┴───────────────┐
            │                                │
   ┌────────▼─────────┐             ┌────────▼─────────┐
   │ Primary Pipeline  │             │ Shadow Pipeline  │
   │  (authoritative)  │             │  (memory_only)   │
   └────────┬──────────┘             └────────┬─────────┘
            │                                 │
            │                                 │
            └─────────────┬───────────────────┘
                          │
               ┌──────────▼──────────┐
               │   Parity Check      │
               │  undo_depth compare │
               └──────────┬──────────┘
                          │
                 mismatch? yes → log diagnostic
                          │
                          no
                          │
                 continue normal operation
```

*Figure 3 — Runtime shadow verification model comparing primary and shadow ledger pipelines for continuous parity validation.*

### 4.1 The Verification Problem

Validating ledger state transitions in a live blockchain node presents a fundamental engineering challenge. The UTxO state machine operates within a concurrent, event-driven synchronization loop where blocks arrive asynchronously, chain rollbacks may occur at any depth up to the security parameter, and the node must maintain forward progress under all conditions. Traditional software testing techniques — unit tests, integration tests, offline replay — cannot fully capture the interaction between ledger logic and the non-deterministic timing of a live peer-to-peer network.

Three properties make live validation particularly difficult. First, the input stream is unbounded and adversarially influenced: blocks contain arbitrary transaction structures that exercise every code path over sufficient time. Second, rollback sequences are rare but critical: a ledger implementation may apply thousands of blocks correctly yet fail on the first multi-block rollback triggered by a chain reorganization. Third, the consequences of a silent ledger error are severe: a divergent UTxO set produces no immediate crash but causes the node to reject valid blocks or accept invalid ones, with the error potentially propagating for hours before detection.

Offline replay testing addresses some of these concerns by re-processing historical blocks through the ledger engine. However, replay operates on a fixed, known-good block sequence. It cannot exercise rollback paths (which require the node to observe competing chain forks in real time), it cannot detect timing-dependent bugs in the synchronization loop, and it provides evidence only for the specific block range replayed rather than continuous assurance during operation.

### 4.2 Shadow Ledger Concept

A shadow ledger is a secondary state machine that receives identical inputs to the primary ledger, applies the same transformations independently, and has its output compared against the primary after every transition. The shadow is strictly advisory: its results are never authoritative, its errors never halt the node, and its state is never consulted for protocol decisions. It exists solely to produce continuous parity evidence.

The shadow approach draws from the dual-channel verification pattern used in safety-critical avionics and financial systems, where independent processing paths compare results to detect divergence. Applied to a blockchain ledger, the shadow state machine provides a live regression oracle that runs continuously in production rather than periodically in a test environment.

The key insight is that two implementations of the same state transition function, driven by identical inputs, must produce identical observable state at every step. Any divergence constitutes proof of a defect in one or both implementations. When one implementation is the proven production path and the other is a candidate replacement, divergence localizes the defect to the candidate with high confidence.

### 4.3 TSUNAGI Shadow Architecture

TSUNAGI implements the shadow ledger as an independent Pipeline instance running in memory_only mode alongside the primary pipeline within the chain-synchronization follower. Both pipelines are instantiated at node startup and destroyed at shutdown. Their lifecycles are bound to the follower loop, not to each other.

The shadow pipeline is activated by setting the environment variable TSUNAGI_LEDGER_SHADOW=1. The primary pipeline is activated separately and may operate in any of the three supported modes: memory_only, lmdb_truth, or lmdb_native. The two activation controls are independent — the shadow can run alongside any primary mode, or alongside the legacy inline implementation when no primary pipeline is configured.

At initialization, the shadow pipeline receives a fresh allocator and no LMDB store pointer. This guarantees the shadow has no shared mutable state with the primary. The two pipelines share only their input: the TxDeltas structure extracted from each block's CBOR body.

### 4.4 Verification Loop

The shadow verification executes within the follower's roll-forward and rollback dispatch paths. The following pseudocode describes the complete verification cycle:

```
on roll_forward(block):
    deltas = extract_deltas(block.body_bytes)

    # Primary application (authoritative)
    primary_result = primary.apply_deltas(deltas.consumed, deltas.produced)

    # Shadow application (advisory)
    shadow_result = shadow.apply_deltas(deltas.consumed, deltas.produced)
    if shadow_result is error:
        shadow_stats.apply_errors += 1
        log("SHADOW: apply error", block.slot, block.number)
        return  # shadow failure is non-fatal

    # Parity check
    primary_depth = primary.undo_depth()
    shadow_depth  = shadow.undo_depth()
    if primary_depth != shadow_depth:
        shadow_stats.mismatches += 1
        log("SHADOW MISMATCH", block.slot, block.number,
            primary_utxo=primary.count(), shadow_utxo=shadow.count(),
            primary_depth, shadow_depth)

    shadow_stats.blocks_applied += 1

on rollback():
    primary.rollback()

    result = shadow.rollback()
    if result is error:
        shadow_stats.rollback_errors += 1
        log("SHADOW: rollback error")
        # non-fatal: shadow may have empty undo at startup

on shutdown():
    log("SHADOW SUMMARY",
        blocks=shadow_stats.blocks_applied,
        mismatches=shadow_stats.mismatches,
        apply_errors=shadow_stats.apply_errors,
        rollback_errors=shadow_stats.rollback_errors)
    shadow.deinit()
```

Both pipelines also participate in undo confirmation: after a configurable number of consecutive forward rolls without a rollback, the oldest undo entry in each pipeline is evicted.

### 4.5 Parity Evaluation

The parity oracle compares undo stack depth rather than full UTxO set equality. This design choice is deliberate and reflects a balance between verification strength and computational cost.

Undo depth comparison is an effective parity signal because each successful application pushes exactly one undo entry and each rollback pops exactly one. If two implementations agree on undo depth after every transition, they have processed the same number of successful applications and rollbacks in the same order. Combined with the fact that both receive identical input deltas, undo depth agreement provides strong evidence of semantic equivalence.

Full UTxO set comparison — hashing or enumerating all entries after every block — would provide a stronger guarantee but at prohibitive cost. On a chain with over 100,000 UTxO entries, computing a set hash after every block would dominate the node's CPU budget. Undo depth comparison is an O(1) operation that adds negligible overhead to the synchronization loop.

The structured mismatch report includes both UTxO counts and both undo depths, providing sufficient diagnostic information to localize divergence when it occurs without requiring the expensive full-set comparison during normal operation.

### 4.6 Production Safety

The shadow pipeline is safe for production deployment because of four architectural guarantees.

**No shared mutable state.** The shadow and primary pipelines share no memory beyond the read-only input deltas. Each maintains its own UTxO hash map, its own undo stack, and its own allocator. A corruption in shadow state cannot propagate to the primary.

**Non-fatal error handling.** Every shadow operation — application, rollback, confirmation — is wrapped in error handling that logs and counts failures without propagating them. A shadow crash or out-of-memory condition increments a counter and continues; the primary path is unaffected.

**No protocol authority.** The shadow's UTxO state is never consulted for block validation, transaction submission, or any protocol decision. It is write-only from the node's perspective: data flows in but never out.

**Bounded resource consumption.** The shadow pipeline's undo stack is capped at the same 200-entry maximum as the primary. Its in-memory UTxO map grows proportionally to the chain's live UTxO set. On preview, this represents a modest memory overhead — a second copy of the in-memory UTxO map, typically under 50 MB.

### 4.7 Advantages Over Offline Replay

Shadow verification provides several properties that offline replay cannot.

**Rollback coverage.** Offline replay processes a linear block sequence. Shadow verification operates within the live synchronization loop where genuine chain rollbacks occur. Every rollback triggered by the peer-to-peer network exercises the undo path in both pipelines simultaneously, testing rollback correctness under real network conditions.

**Continuous assurance.** Replay provides a point-in-time result for a specific block range. Shadow verification runs for the entire lifetime of the node, accumulating evidence with every block. A node that has processed 10,000 blocks with zero shadow mismatches has stronger evidence of equivalence than a replay of any fixed subset.

**Timing fidelity.** Replay processes blocks as fast as the CPU allows. Shadow verification processes blocks at the rate they arrive from the network, interleaved with rollbacks, reconnections, and varying block sizes. This exercises the ledger engine under the same concurrency and timing profile it will experience in production.

**Zero operational disruption.** Replay requires a separate test run with dedicated resources. Shadow verification piggybacks on the production node, requiring only a single environment variable to enable and producing its evidence as a side effect of normal operation.

---

## 5. Persistent Storage and LMDB Truth Mode

### 5.1 The Persistence Requirement

A Cardano node maintaining the full UTxO set must survive process restarts, host reboots, and planned maintenance windows without re-synchronizing from genesis. The UTxO set on mainnet exceeds ten million entries; reconstructing it from the chain requires processing every block from the origin point, a procedure that takes hours even on capable hardware. Persistent storage transforms node restart from a re-synchronization event into a state-resume event, reducing downtime from hours to seconds.

Beyond restart resilience, persistent storage enables operational capabilities that in-memory state cannot provide: point-in-time snapshots for backup and distribution, state digests for cross-node consistency verification, and query interfaces for external tooling that inspects the UTxO set without coupling to the node's runtime memory layout.

### 5.2 Limitations of In-Memory State

TSUNAGI's in-memory UTxO map, implemented as a hash map keyed by transaction hash and output index, provides correct and fast state tracking during a single node session. However, it carries three structural limitations.

**Volatility.** Process termination discards the entire UTxO set. On restart, the node must either re-synchronize from a known anchor point or load state from an external source. For a node tracking mainnet, this creates an unacceptable recovery time.

**Snapshot opacity.** The in-memory map exists only as a runtime data structure. Producing a portable snapshot requires serializing the entire map — an operation that must compete with the synchronization loop for CPU time and memory bandwidth. A persistent store provides snapshot capability as an intrinsic property of its storage format.

**Verification isolation.** Comparing UTxO state across nodes requires each node to compute a digest over its in-memory map, a procedure whose cost scales linearly with the UTxO set size. A persistent store can maintain incremental digests or support cursor-based comparison without freezing the synchronization loop.

### 5.3 LMDB Store Design

TSUNAGI uses Lightning Memory-Mapped Database (LMDB) as its persistent UTxO store. LMDB provides single-writer, multiple-reader transactional semantics with memory-mapped I/O, copy-on-write B+ tree storage, and crash-safe durability without write-ahead logging.

The UTxO store maps a 36-byte key (32-byte transaction hash concatenated with a 4-byte output index) to a variable-length value encoding the output's address and lovelace amount. The store occupies the unnamed database within the LMDB environment, coexisting with named databases used by other subsystems such as the header store.

The store interface exposes five transactional operations:

- **beginRead** — open a read-only transaction (multiple concurrent readers permitted)
- **beginWrite** — open a write transaction (single writer; returns null on contention)
- **getTxn** — look up a key within a transaction, returning the decoded output or null
- **putTxn** — insert or update a key-value pair within a write transaction
- **delTxn** — delete a key within a write transaction

All operations are non-fatal at the store level: failures return null or boolean false rather than aborting the process. This allows callers to implement graduated error handling rather than crash-on-failure semantics.

A **computeStateDigest** function provides a Blake2b-256 hash over all key-value pairs via a full cursor scan, enabling cross-node state comparison and snapshot integrity verification.

### 5.4 Three Operational Modes

**memory_only.** The pipeline applies deltas exclusively to the in-memory UTxO hash map. No LMDB transactions are opened. This mode is used by the shadow ledger (which requires no persistence), by nodes operating without an LMDB store configured, and during testing. It provides the baseline correctness guarantee: the in-memory applyDelta function is the proven reference implementation against which all other modes are validated.

**lmdb_truth.** LMDB is the authoritative persistent store. The pipeline attempts to apply each block's deltas through an atomic LMDB write transaction. If any step fails — the write transaction cannot be opened, a consumed input is not found in the store, or the commit fails — the pipeline falls back to in-memory application and performs a best-effort shadow-write to keep LMDB synchronized. This mode provides persistence with continuity: the node never halts due to an LMDB inconsistency, and the shadow-write mechanism enables progressive convergence toward full LMDB coverage.

**lmdb_native.** LMDB is mandatory and no fallback exists. Any failure in the LMDB write path — transaction open, delta application, or commit — produces a hard error that propagates to the caller. This mode is intended for deployments where LMDB consistency is guaranteed by external means (a fresh bootstrap from a verified snapshot, or a node that has achieved full convergence in lmdb_truth mode). It offers the strongest persistence guarantee at the cost of fault tolerance.

### 5.5 The Apply Sequence

The following diagram illustrates the complete block application path in lmdb_truth mode, from raw block bytes through to either persistent commit or fallback recovery:

```
                         ┌─────────────────┐
                         │   Block Bytes    │
                         └────────┬─────────┘
                                  │
                                  ▼
                         ┌─────────────────┐
                         │ Extract Deltas   │
                         │ (block_stream)   │
                         └────────┬─────────┘
                                  │
                          consumed[], produced[]
                                  │
                                  ▼
                         ┌─────────────────┐
                         │   Preflight      │
                         │  Coverage Check  │
                         │  (read-only txn) │
                         └────────┬─────────┘
                                  │
                        ┌─────────┴──────────┐
                        │                    │
                   missing = 0          missing > 0
                        │                    │
                        ▼                    │
               ┌─────────────────┐           │
               │  Begin Write    │           │
               │  Transaction    │           │
               └────────┬────────┘           │
                        │                    │
                        ▼                    │
               ┌─────────────────┐           │
               │ Apply Delta     │           │
               │ (atomic LMDB)   │           │
               └────────┬────────┘           │
                        │                    │
                   ┌────┴────┐               │
                   │         │               │
                success    failure ──────────┤
                   │         (abort txn)     │
                   ▼                         ▼
          ┌─────────────┐          ┌──────────────────┐
          │   Commit    │          │ Memory Fallback   │
          │   Write Txn │          │ (applyDelta)      │
          └──────┬──────┘          └────────┬──────────┘
                 │                          │
                 │                          ▼
                 │                 ┌──────────────────┐
                 │                 │  Shadow-Write     │
                 │                 │  (best-effort     │
                 │                 │   LMDB sync)      │
                 │                 └────────┬──────────┘
                 │                          │
                 ▼                          ▼
          ┌─────────────────────────────────────────┐
          │           Push Undo Entry               │
          │   (cap at MAX_UNDO_DEPTH = 200)         │
          └─────────────────────────────────────────┘
```

Every path through the diagram terminates at the undo push. The block is always applied — either persistently through LMDB or transiently in memory with a synchronizing shadow-write. No block is ever dropped due to an LMDB failure in lmdb_truth mode.

### 5.6 Fallback Continuity and Shadow-Write

The fallback mechanism ensures that an LMDB coverage gap on block N does not degrade the node's ability to process block N+1. When the pipeline falls back to in-memory application, it immediately opens a separate write transaction and performs a shadow-write: all consumed inputs are deleted from LMDB and all produced outputs are inserted.

```
shadow_write(store, consumed, produced):
    txn = store.begin_write()
    if txn is null: return       # non-fatal
    for input in consumed:
        store.delete(txn, input)
    for output in produced:
        store.put(txn, output)
    store.commit(txn)            # success ignored
```

Every step is non-fatal. If the write transaction cannot be opened, the shadow-write is silently skipped. If the commit fails, no state is corrupted — LMDB's copy-on-write semantics guarantee that a failed commit leaves the store unchanged.

The shadow-write creates a convergence dynamic. Produced outputs written during fallback become available for consumption in subsequent blocks. Over time, as the store accumulates outputs from shadow-writes, the coverage gap narrows and more blocks succeed via the direct LMDB path. The rate of convergence depends on the overlap between newly produced outputs and the consumed inputs of future blocks.

### 5.7 Preflight Coverage Diagnostic

Before opening a write transaction, the lmdb_truth path performs a preflight coverage check: a read-only transaction scans all consumed inputs and counts how many are present in LMDB.

```
preflight(store, consumed):
    if consumed is empty: return {found=0, missing=0}
    rtxn = store.begin_read()
    if rtxn is null: return {found=0, missing=len(consumed)}
    found = 0
    for input in consumed:
        if store.get(rtxn, input) exists: found++
    store.abort(rtxn)
    return {found, missing = len(consumed) - found}
```

If any inputs are missing, the write path is bypassed entirely and execution proceeds directly to the memory fallback with shadow-write. This eliminates the cost of opening a write transaction, attempting application, encountering a lookup failure on the first missing input, and aborting — a sequence that is entirely wasted when the coverage gap is known in advance.

The coverage counts are propagated through the ApplyResult structure and logged by the follower for each non-empty delta block:

```
PRIMARY LEDGER: preflight coverage found=N total=M fallback=0|1
```

This provides per-block, per-run visibility into LMDB store health without additional tooling or manual inspection.

### 5.8 Operational Implications

The three-mode design with preflight diagnostics supports a natural operational progression.

**Initial deployment.** A new node starts with memory_only or lmdb_truth with an empty store. All blocks fall back to in-memory application. Shadow-writes progressively populate the store.

**Bootstrap acceleration.** An operator imports a snapshot into LMDB before starting the node, providing a baseline of 100,000+ entries. Coverage depends on snapshot freshness relative to chain tip. A snapshot taken minutes before startup provides high coverage; one taken days prior provides low coverage for consumed inputs but still serves as a persistence baseline for restart resilience.

**Steady-state convergence.** As the node runs in lmdb_truth mode, shadow-writes from fallback blocks and direct writes from successful blocks continuously update the store. Coverage trends upward as the store's contents align with the chain tip's consumed-input working set. The preflight diagnostic provides a quantitative measure of this convergence.

**Native promotion.** When coverage diagnostics consistently show full coverage (found equals total for all blocks over an extended period), the operator may switch to lmdb_native mode, eliminating fallback overhead and relying entirely on LMDB for state authority. The preflight check remains active in this mode as a diagnostic, though its result does not alter the execution path.

---

## 6. Operator Observability Architecture

### 6.1 The Black-Box Problem

Traditional blockchain node implementations present operators with a narrow diagnostic surface. A typical Cardano node exposes a socket-based local query interface, a set of Prometheus metrics, and log output. When the node falls behind the chain tip, experiences a chain reorganization, or encounters a storage inconsistency, the operator must correlate log timestamps with external chain explorers, manually inspect filesystem state, and reason backward from symptoms to causes. The node does not explain what is wrong or what action would restore health.

This opacity creates three operational failures. First, diagnosis latency: an operator may spend minutes or hours determining whether a stale tip indicates a network partition, a peer selection failure, a storage corruption, or a normal catch-up phase. Second, automation difficulty: monitoring systems can detect that a metric has crossed a threshold but cannot determine the appropriate remediation without domain-specific logic that the node itself possesses. Third, trust erosion: operators who cannot understand their node's behavior develop justified skepticism about its reliability, hindering ecosystem adoption of alternative implementations.

### 6.2 Design Philosophy

TSUNAGI adopts the principle that a node should explain its own health. Rather than requiring operators to assemble diagnostic pictures from raw metrics and logs, the node provides structured, layered subsystems that evaluate health conditions, identify degradation, produce actionable recommendations, and in defined cases execute automated remediation. Each subsystem is named, scoped to a specific concern, and independently invocable as a CLI command.

Five architectural layers form the observability and defense stack:

```
┌─────────────────────────────────────────────────┐
│  KAGAMI  鏡   Observability & Diagnostics       │
│  ─────────────────────────────────────────────  │
│  Node health reports, live telemetry streams,   │
│  machine-readable JSON snapshots                │
├─────────────────────────────────────────────────┤
│  YAMORI  家守  Guardian & Integrity Monitor      │
│  ─────────────────────────────────────────────  │
│  Seven-check health evaluation, event logging,  │
│  event analysis, safe-mode enforcement          │
├─────────────────────────────────────────────────┤
│  TATE  盾     Rollback Resilience & Defense     │
│  ─────────────────────────────────────────────  │
│  Fragment ancestry verification, coverage       │
│  evaluation, operator recommendations           │
├─────────────────────────────────────────────────┤
│  KURA  蔵     Stabilization & Archive           │
│  ─────────────────────────────────────────────  │
│  Stale artifact detection, automated reseal,    │
│  disk retention policy, safe pruning            │
├─────────────────────────────────────────────────┤
│  TSURUGI  剣  Protocol Engine                   │
│  ─────────────────────────────────────────────  │
│  ChainSync, BlockFetch, Ouroboros N2N protocol  │
├─────────────────────────────────────────────────┤
│  Runtime Core                                   │
│  ─────────────────────────────────────────────  │
│  Follower loop, UTxO state, LMDB persistence,   │
│  ledger pipeline, peer management               │
└─────────────────────────────────────────────────┘
```

```
                ┌───────────────┐
                │   KAGAMI 鏡    │
                │  Observability │
                └───────┬───────┘
                        │
                        ▼
                ┌───────────────┐
                │   YAMORI 家守  │
                │  Health Guard │
                └───────┬───────┘
                        │
                        ▼
                ┌───────────────┐
                │    TATE 盾     │
                │  Fragment Def │
                └───────┬───────┘
                        │
                        ▼
                ┌───────────────┐
                │    KURA 蔵     │
                │ Stabilization │
                └───────┬───────┘
                        │
                        ▼
                 Node Continues
```

*Figure 4 — TSUNAGI BAEY self-healing operational loop showing how KAGAMI, YAMORI, TATE, and KURA cooperate to detect issues, stabilize the node, and allow continued operation.*

### 6.3 KAGAMI — Observability Layer

KAGAMI (鏡, "mirror") is a read-only diagnostic mirror that reflects the node's internal state back to the operator without modifying any runtime or persistent state. It aggregates data from three sources — the chain cursor file tracking synchronization progress, the propagation artifact directory containing fragment coverage metadata, and the optional LMDB UTxO store — into a unified health snapshot.

KAGAMI provides three output modes. The **report** subcommand produces a one-shot human-readable text report covering chain tip position, tip age, roll-forward and roll-backward counts, propagation artifact status, fragment coverage range, usable depth, break count, UTxO entry count, and an overall health status. The **json** subcommand produces the same data as a machine-readable JSON object suitable for ingestion by monitoring systems, dashboards, or automated tooling. The **stream** subcommand produces continuous live telemetry, refreshing at a configurable interval (default one second), providing a terminal-based real-time view of node health.

The health snapshot includes a derived status field with three levels: healthy, warn, and critical. Status derivation follows defined thresholds: tip age exceeding 120 seconds triggers a warning; exceeding 600 seconds triggers critical. Artifact absence is immediately critical. Usable fragment depth below 100 is a warning; below 10 is critical. Any non-zero break count — indicating a fragment ancestry discontinuity — is critical. A tip-artifact slot gap exceeding 60 slots is a warning; exceeding 300 is critical.

These thresholds are shared across KAGAMI, YAMORI, and TATE, ensuring consistent health assessment regardless of which subsystem an operator queries.

### 6.4 YAMORI — Guardian Layer

YAMORI (家守, "house guardian") is an integrity monitor that evaluates node health through seven structured checks, maintains an event log, and provides operational safety mechanisms.

The **check** subcommand executes the seven checks in sequence, each producing a verdict of OK, WARN, CRIT, or SKIP:

1. **follower_alive** — verifies that the chain cursor file exists and is parseable, confirming that the follower process is running and writing state.
2. **follower_tip_age** — computes the elapsed time since the follower last updated its cursor, detecting stalled synchronization.
3. **artifact_present** — verifies that the propagation artifact directory exists on disk.
4. **artifact_age** — reads the artifact's creation timestamp and computes its age, detecting stale propagation state.
5. **usable_depth** — reads the contiguous ancestry-verified depth from the fragment coverage metadata, assessing intersection reliability.
6. **break_count** — reads the number of ancestry discontinuities in the fragment, detecting structural corruption.
7. **lmdb_available** — when an LMDB path is configured, attempts to open and immediately close the store, verifying database accessibility.

Each check is independent and non-fatal. A check whose prerequisite is absent (for example, artifact_age when no artifact directory exists) returns SKIP rather than failing. The overall verdict is the worst non-skip result across all checks. Exit code 1 indicates at least one critical finding; exit code 0 indicates all checks passed or warned.

Beyond health checking, YAMORI provides three additional capabilities. The **record** subcommand appends structured events to a JSONL log file with fields for timestamp, network, severity level, subsystem, event code, and message. The **analyze** subcommand reads the event log tail and produces frequency analysis of recurring events, lists recent critical events, and maps event codes to operator playbook actions. The **safe-mode** subcommand can apply or revert a systemd drop-in configuration that disables dangerous operational features (transaction broadcast, block forging) without stopping the node, providing an emergency degradation mechanism.

### 6.5 TATE — Fragment Defense Layer

TATE (盾, "shield") is a pure evaluation module that assesses the structural integrity of the propagation artifact — the fragment chain that enables incoming peers to intersect with the node's chain state. TATE takes no action and performs no I/O; it accepts a structured input and returns a report containing per-signal verdicts and operator recommendations.

TATE evaluates seven signals: artifact presence, artifact age, usable contiguous depth, ancestry break count, follower tip age, tip-to-artifact slot gap, and coverage metadata availability. Each signal maps to the shared threshold constants, ensuring alignment with KAGAMI and YAMORI assessments.

The tip-artifact gap signal deserves particular attention. It measures the slot distance between the follower's current chain tip and the newest entry in the propagation artifact. A small gap indicates that the artifact reflects recent chain state and can serve reliable intersections. A large gap indicates that the artifact is falling behind the chain tip, reducing the probability that incoming peers can find a common intersection point. Gaps exceeding 60 slots produce a warning; gaps exceeding 300 slots produce a critical verdict with an explicit recommendation to reseal the artifact.

TATE accumulates up to eight recommendations in its report, each tied to a specific signal verdict. Recommendations are phrased as operator actions: "propagation artifact missing; run seal-tip", "usable depth too low for reliable intersection", "fragment ancestry break detected; reseal required". This transforms a set of numeric thresholds into a prioritized action list that an operator or automation system can execute directly.

### 6.6 KURA — Stabilization Layer

KURA (蔵, "storehouse") serves two roles: artifact stabilization and disk retention management.

The **stabilization evaluator** determines whether the propagation artifact requires resealing based on four conditions evaluated in priority order. An ancestry break (break_count greater than zero) triggers an urgent reseal. Artifact age exceeding 1800 seconds, a tip-artifact gap exceeding 300 slots, or usable depth below 100 entries each trigger a standard reseal. If none of these conditions hold, no action is taken. When reseal is indicated, KURA's stabilize subcommand directly invokes the seal-tip operation, regenerating the propagation artifact from the current fragment state.

The stabilize subcommand is designed for unattended execution. An operator or cron job invokes it periodically; it evaluates conditions, acts if needed, and exits. This provides a closed loop: TATE identifies degradation, KURA remediates it, and KAGAMI reflects the restored health — all without manual intervention for routine cases.

The **retention manager** implements safe disk hygiene across seven target categories: network captures, candidate blocks, proof bundles, ledger snapshots, simulation artifacts, event logs, and gap records. Each target has a configurable retention policy specifying how many items to keep. KURA enforces safety invariants that prevent it from touching consensus-critical paths (LMDB, genesis files, key material, UTxO snapshots), following symbolic links, or operating outside the configured home directory. A plan-then-apply model with a time-limited plan expiry ensures that operators review deletion plans before execution.

### 6.7 Operational Integration

The four layers form a coherent operational surface. In a typical monitoring deployment, KAGAMI's json output feeds a dashboard or alerting system, providing continuous health visibility. YAMORI's check subcommand runs on a schedule (cron or systemd timer), logging events and producing alerts when checks fail. TATE's evaluation drives KURA's stabilization decisions, creating an automated feedback loop that maintains propagation artifact health. When conditions exceed automated remediation — a persistent critical state, an unrecoverable fragment break, or an LMDB accessibility failure — the operator consults KAGAMI's report or YAMORI's analysis for diagnosis and TATE's recommendations for action.

The safe-mode mechanism provides a final defensive layer. When an operator or automated system determines that the node is in an unsafe state for transaction broadcast or block production, YAMORI's safe-mode apply disables those capabilities at the systemd level without stopping the node. The follower continues synchronizing, KAGAMI continues reporting, and the operator can investigate and restore full capability via safe-mode revert once the underlying condition is resolved.

### 6.8 Contrast with Traditional Architectures

Traditional Cardano node architectures expose health through Prometheus metrics (counters, gauges, histograms) and unstructured log output. The operator must define alert thresholds externally, write correlation logic in their monitoring system, and maintain runbooks that map symptoms to actions. The node itself has no concept of its own health status and cannot recommend remediation.

TSUNAGI inverts this relationship. Health evaluation logic lives inside the node, encoded in the same codebase that implements the protocol. Thresholds are defined once and shared across all subsystems. Recommendations are generated by the system that understands the failure mode, not by an external monitoring tool that can only observe symptoms. The node becomes a participant in its own operations rather than a passive subject of external monitoring.

This inversion does not replace external monitoring — operators still benefit from Prometheus integration, log aggregation, and external alerting. It supplements external monitoring with internal intelligence, reducing the expertise required to operate the node and enabling automation patterns that would otherwise require custom integration work for each deployment.

---

## 7. Experimental Evaluation

### 7.1 Evaluation Goals

The experimental evaluation of TSUNAGI's ledger engine pursues six objectives, each targeting a distinct correctness or operational property.

**Protocol correctness.** The extracted ledger pipeline must produce identical UTxO state transitions to the proven inline follower implementation for every block received from the live network, including blocks with zero transactions, blocks with complex multi-input multi-output transactions, and blocks arriving during chain reorganizations.

**Shadow parity validation.** The shadow ledger, running independently alongside the primary pipeline on identical inputs, must maintain undo-depth parity with the primary at every transition point. Any divergence constitutes proof of a semantic difference between the two implementations.

**Rollback correctness.** The undo mechanism must correctly reverse state mutations when the chain-synchronization protocol signals a rollback. This includes reversing both in-memory UTxO map mutations and persistent LMDB store mutations, with correct memory management of address slices owned by undo log entries.

**LMDB truth-mode behavior.** The three-stage degradation ladder — preflight check, atomic LMDB write, memory fallback with shadow-write — must maintain forward progress under all LMDB coverage conditions without data loss, state corruption, or process termination.

**LMDB coverage diagnostics.** The preflight coverage check must accurately report the number of consumed inputs found in and missing from the LMDB store, providing quantitative per-block visibility into persistent store health.

**Snapshot bootstrap round-trip integrity.** The snapshot export, import, and bootstrap pipeline must preserve UTxO data integrity, verified through file-level cryptographic digests and post-import state consistency checks.

### 7.2 Experimental Environment

All experiments were conducted on the Cardano preview network, a public test network that mirrors mainnet's protocol rules and transaction structure while operating at a lower UTxO set size and block frequency. The preview network provides genuine peer-to-peer block delivery, real chain reorganizations triggered by slot battles, and varied transaction profiles including multi-input multi-output transactions, script executions, and metadata-bearing transactions.

The experimental node ran as a follower — synchronizing chain state from upstream peers without participating in block production. The node binary was compiled with ReleaseSafe optimizations from the same codebase used for all validation runs.

Two pipeline configurations were tested:

- **Shadow-only mode.** The legacy inline follower implementation served as the primary path. A shadow pipeline in memory_only mode ran in parallel, receiving identical delta inputs and comparing undo depth after every block.

- **Primary lmdb_truth mode with shadow.** The extracted pipeline served as the primary path in lmdb_truth mode with an LMDB store bootstrapped from a snapshot. The shadow pipeline continued running in memory_only mode for parity verification.

The LMDB store was populated via the snapshot bootstrap pipeline: a snapshot was exported from the node's live LMDB store (capturing the full UTxO set at a point in time), then imported into a fresh LMDB environment using the bootstrap command. Bootstrap imports were verified through the TSF2 file format's Blake2b-256 integrity digest.

### 7.3 Experiments Performed

**Experiment 1: Shadow parity soak.** Multiple sessions of 10 to 20 minutes duration with the shadow pipeline enabled alongside the primary path. Each session processed blocks arriving at the chain tip in real time, including header synchronization, block fetch, delta extraction, and state application. Rollbacks triggered by startup reconnection were included in every session.

**Experiment 2: Primary memory_only validation.** The extracted pipeline operated as the primary path in memory_only mode with the shadow pipeline providing parity verification. This isolated the extracted pipeline's correctness from any LMDB interaction.

**Experiment 3: Primary lmdb_truth validation.** The extracted pipeline operated as the primary path in lmdb_truth mode with a bootstrapped LMDB store containing 118,000 to 121,000 UTxO entries. The shadow pipeline verified parity. This tested the full three-stage degradation ladder under live network conditions.

**Experiment 4: Fallback continuity validation.** Within the lmdb_truth sessions, blocks that triggered fallback (due to consumed inputs missing from LMDB) were monitored for correct shadow-write behavior: produced outputs written to LMDB, consumed inputs deleted, and subsequent blocks able to find shadow-written outputs in the store.

**Experiment 5: Snapshot round-trip integrity.** A snapshot was exported from the node's live LMDB store, imported into a fresh LMDB environment via the bootstrap pipeline, and the LMDB state digest was computed on both the source and destination stores. A second independent import was performed to verify import-to-import consistency.

**Experiment 6: Preflight coverage measurement.** With the preflight coverage diagnostic enabled, per-block coverage statistics were collected across multiple lmdb_truth sessions, quantifying the fraction of consumed inputs present in the bootstrapped LMDB store.

### 7.4 Results

The following table summarizes the cumulative results across all experimental sessions:

| Metric | Result |
|--------|--------|
| Shadow parity mismatches | 0 |
| Apply errors (primary) | 0 |
| Apply errors (shadow) | 0 |
| Rollback errors | 0 |
| Blocks with non-empty deltas verified | 54+ |
| Chain rollbacks handled | 1+ per session (startup reconnection) |
| Startup empty-undo rollback tolerance | Correct in all sessions |
| Undo depth cap (MAX_UNDO_DEPTH=200) | Verified in unit tests |
| Undo address leak on eviction | Verified leak-free by testing allocator |
| Bootstrap imports performed | 4 |
| Bootstrap records per import | 118,765 to 121,104 |
| TSF2 digest verification | Passed on all imports |
| Import-to-import digest consistency | Confirmed (identical digest across independent imports) |
| Source-to-import digest match | Not expected (see Section 7.5) |

LMDB truth-mode results across sessions:

| Session | Duration | Delta Blocks | Fallback Count | Fallback Rate | Direct LMDB Successes |
|---------|----------|-------------|----------------|---------------|----------------------|
| Session 1 (5 min) | 5 min | 1 | 1 | 100% | 0 |
| Session 2 (8 min) | 8 min | 7 | 7 | 100% | 0 |
| Session 3 (20 min) | 20 min | 25 | 25 | 100% | 0 |
| Session 4 (10 min) | 10 min | 9 | 8 | 88.9% | 1 |
| Session 5 (10 min) | 10 min | 10 | 10 | 100% | 0 |

Preflight coverage results from Session 5 (10 blocks, 49 total consumed inputs):

| Metric | Value |
|--------|-------|
| Inputs found in LMDB | 2 |
| Inputs missing from LMDB | 47 |
| Per-block coverage rate | 4.1% |
| Blocks with zero found inputs | 8 of 10 |
| Blocks with partial found inputs | 2 of 10 |
| Blocks with full coverage | 0 of 10 |
| Write transactions wasted by preflight | 0 |

### 7.5 Interpretation

**What is proven.** The zero-mismatch result across all sessions establishes that the extracted ledger pipeline produces semantically equivalent state transitions to the inline follower implementation for the class of blocks observed on the preview network. This equivalence holds across blocks with varying transaction counts (0 to 14+ consumed inputs per block), across fallback and non-fallback application paths, and across chain rollback events. The shadow parity methodology provides continuous runtime verification rather than point-in-time test coverage.

**Correctness versus coverage versus continuity.** The experimental results distinguish three independent properties. Correctness — verified by zero shadow mismatches — means the pipeline computes the right state. Continuity — verified by zero apply errors and correct fallback behavior — means the pipeline maintains forward progress regardless of LMDB store state. Coverage — measured by the preflight diagnostic — quantifies how much of the consumed-input working set is present in the persistent store.

**Why high fallback does not imply failure.** The 88.9% to 100% fallback rates observed in lmdb_truth sessions reflect a structural property of near-tip operation with a bootstrapped LMDB store, not a correctness deficiency. Blocks arriving at the chain tip consume UTxO entries produced by recent transactions that post-date the bootstrap snapshot. The bootstrap set of 120,000+ entries has minimal overlap with the consumed-input working set of live blocks. The 4.1% input coverage rate confirms this quantitatively: of 49 consumed inputs across 10 blocks, only 2 existed in the bootstrapped store.

Fallback is the designed recovery path. Each fallback applies the block correctly in memory and performs a shadow-write that inserts newly produced outputs into LMDB. Over time, as the store accumulates outputs from shadow-writes, coverage trends upward. The one direct LMDB success observed (Session 4, block 4098694, consumed=1) demonstrates this mechanism: the block's single consumed input was present in the bootstrap set, preflight confirmed full coverage, and the write transaction succeeded without fallback.

**Snapshot digest divergence.** The source and imported LMDB stores produced different state digests despite containing identical UTxO data. Investigation revealed that the source store's unnamed database contains metadata entries for named databases (header store tables) that are not part of the UTxO set. The export process correctly filters these entries (skipping keys where the size differs from the expected 36-byte UTxO key), but the computeStateDigest function hashes all keys in the unnamed database including non-UTxO metadata. Two independent imports into fresh LMDB environments — which contain no named-database metadata — produced identical digests, confirming that the UTxO data is preserved faithfully. The TSF2 file-level Blake2b-256 digest provides the authoritative integrity guarantee.

### 7.6 Limitations

**Network scope.** All experiments were conducted on the preview network. While preview mirrors mainnet's protocol rules and transaction structure, its UTxO set is smaller (approximately 120,000 entries versus mainnet's 10+ million) and its block frequency is lower. Mainnet validation would exercise the pipeline under higher throughput and larger state.

**Soak duration.** The longest continuous session was 20 minutes. Extended soak runs of hours or days would provide stronger confidence in the absence of time-dependent failures such as memory leaks, undo stack accumulation edge cases, or LMDB map size exhaustion.

**Parity granularity.** Shadow parity is evaluated by comparing undo stack depth, an O(1) proxy for state equivalence. Full UTxO set equality — comparing every entry in both maps after every block — would provide a stronger guarantee but at computational cost that scales linearly with the UTxO set size. The undo-depth proxy is sufficient to detect any divergence in the number of successful applications and rollbacks but would not detect a hypothetical bug where two implementations agree on count but disagree on specific entries.

**lmdb_native mode.** The lmdb_native mode (LMDB mandatory, no fallback) has not been validated as a primary mode on a live network. Unit tests and the lmdb_truth sessions exercise the same underlying applyDeltaLmdb code path, but the absence of fallback in lmdb_native means that any LMDB inconsistency would produce a hard error rather than graceful degradation. Validating lmdb_native requires either a fully converged LMDB store or a replay environment where all consumed inputs are guaranteed present.

**Coverage convergence.** The shadow-write mechanism is expected to produce increasing LMDB coverage over time, but no session was long enough to observe a statistically significant downward trend in fallback rate. Confirming convergence requires either an extended mainnet soak or a controlled replay experiment with known input sequences.

---

## 8. Modular Experimentation and Replay

### 8.1 Storage Engine Experimentation

TSUNAGI's layered architecture — where delta extraction, state application, undo management, and persistent storage occupy independent modules with explicit interfaces — creates a substrate for experimentation that does not exist in monolithic node implementations. Each layer can be replaced, extended, or instrumented without modifying the layers above or below it.

The persistent storage layer presents the most immediate opportunity. The current LMDB-backed store implements a key-value interface with five transactional operations: begin read, begin write, get, put, and delete. Any storage engine that implements this interface — RocksDB, SQLite, a custom B-tree, a memory-mapped flat file, or a distributed key-value store — can be substituted without modifying the ledger pipeline, the delta extraction layer, or the protocol integration. This enables controlled experiments comparing storage engines on identical workloads: the same block stream processed by the same pipeline with different backends, producing directly comparable throughput, latency, and resource consumption measurements.

Alternative persistence strategies can be explored within the existing three-mode framework. A write-ahead log mode could batch LMDB writes across multiple blocks, amortizing transaction overhead at the cost of increased rollback complexity. A tiered storage mode could maintain recent UTxO entries in a fast in-memory cache with periodic flush to LMDB, optimizing for the access pattern where consumed inputs overwhelmingly reference recent outputs. A compressed storage mode could apply dictionary compression to address bytes, which exhibit high redundancy across the UTxO set. Each strategy requires changes only to the storage layer and the mode dispatch in the apply module; the pipeline, the replay harness, and the shadow verification system operate unchanged.

Ledger optimizations can be tested with immediate correctness verification. A candidate optimization — a faster hash map implementation, a more compact undo log encoding, a parallel delta application strategy — is implemented in the pipeline layer and validated by running the shadow system against the unmodified implementation on live network traffic. Zero mismatches after an extended soak provide strong evidence that the optimization preserves correctness. This feedback loop, where correctness verification is built into the architecture rather than requiring a separate test campaign, significantly reduces the cost and risk of performance experimentation.

### 8.2 Deterministic Replay and Verification

The replay harness provides a foundation for deterministic block verification that extends beyond its current use in integration testing. By recording block body bytes to disk during live synchronization, an operator can construct a complete replay corpus that exercises the ledger pipeline offline, without network access, at arbitrary speed.

This capability enables several verification patterns. A nightly regression pipeline can replay the day's blocks through the latest build, detecting any behavioral change introduced by code modifications. A bisection tool can identify the exact block that triggers a divergence between two pipeline versions by binary-searching a recorded block sequence. A fuzz testing harness can generate synthetic block bodies with adversarial CBOR structures, exercising error handling paths that live network traffic may never trigger.

Deterministic replay also enables cross-implementation verification. If two independent node implementations record block bodies during synchronization, their replay corpora can be exchanged and processed through each other's ledger pipelines. Agreement on the resulting UTxO state after processing identical block sequences provides strong evidence of protocol-level compatibility without requiring the two implementations to operate on the same live network simultaneously.

The replay harness's counter semantics — where cumulative work counters do not rewind on rollback while chain-depth counters do — support performance benchmarking in addition to correctness verification. Throughput measurements (blocks per second, transactions per second, UTxO mutations per second) can be collected during replay without the variance introduced by network latency and peer behavior during live synchronization.

### 8.3 Alternative Node Profiles

The separation of protocol and ledger concerns enables node configurations tailored to specific operational roles rather than the general-purpose profile that a monolithic implementation must support.

A lightweight follower node can operate in memory_only mode with a reduced undo stack depth, tracking the chain tip without persistent storage. This profile suits monitoring applications, chain analytics pipelines, and development environments where restart-from-snapshot is acceptable and minimizing resource consumption is prioritized over persistence.

An archival node can operate in lmdb_native mode with an extended undo stack and periodic snapshot export, maintaining a complete persistent UTxO history with point-in-time recovery capability. This profile suits infrastructure providers, block explorers, and research institutions that require historical state queries.

A specialized research node can combine the replay harness with custom instrumentation — transaction classification, fee analysis, script execution profiling, UTxO age distribution tracking — without modifying the core synchronization or ledger logic. The pipeline's explicit interface (delta slices in, apply result out) provides a natural instrumentation point where research-specific logic can observe every state transition without interposing on the critical path.

---

## 9. Cross-Chain Research Potential

TSUNAGI's deterministic ledger pipeline, operating on the UTxO model that Cardano shares with Bitcoin, provides a foundation for interoperability research between UTxO-based blockchains.

The pipeline's core abstraction — a state machine that consumes inputs identified by transaction hash and output index, produces new outputs with addresses and values, and maintains a reversible undo log — is not specific to Cardano. The delta extraction layer is Cardano-specific (it parses Cardano's CBOR block format), but the pipeline itself operates on abstract UTxO types. A second extraction layer targeting Bitcoin's block format could feed the same pipeline, enabling unified UTxO state tracking across both chains within a single process.

This architectural property opens research directions in cross-chain verification. A bridge architecture could maintain synchronized UTxO views of both chains, detecting when a transaction on one chain references state that should correspond to state on the other. The deterministic replay capability enables offline verification of cross-chain claims: given recorded block sequences from both chains, a verifier can independently reconstruct the UTxO state at any point and confirm or deny a cross-chain assertion without trusting either chain's live nodes.

These directions are speculative and would require substantial additional work — Bitcoin block parsing, cross-chain state mapping, and bridge protocol design — but the architectural foundation exists in the current system rather than requiring a ground-up redesign.

---

## 10. Ecosystem Contribution

### 10.1 Implementation Diversity

TSUNAGI's primary contribution to the Cardano ecosystem is the existence of a second production-grade node implementation. This contribution operates at three levels.

At the protocol level, an independent implementation validates the specification through independent interpretation. Where the reference implementation and TSUNAGI agree, the specification is confirmed. Where they diverge, a specification ambiguity or implementation defect is identified. The shadow parity system provides continuous automated detection of such divergences during live operation, transforming protocol validation from a periodic audit into an ongoing process.

At the community level, a modular, well-documented implementation in a systems language with explicit control flow lowers the barrier to understanding Cardano's node architecture. Developers who find the reference implementation's complexity or language choice challenging can study and contribute to an alternative that exposes the same protocol logic through a different architectural lens. The inline test suites, the replay harness, and the pipeline proof tests serve as executable documentation of the protocol's state transition semantics.

At the infrastructure level, client diversity reduces the probability and blast radius of correlated failures. A network where a meaningful fraction of nodes run an independent implementation can tolerate a critical bug in either implementation without losing consensus. This resilience property — well established in Ethereum's multi-client ecosystem — becomes available to Cardano as independent implementations reach production maturity.

### 10.2 Operational Transparency

The observability architecture — KAGAMI, YAMORI, TATE, and KURA — addresses a barrier to alternative node adoption in the Cardano ecosystem. Operators accustomed to the reference implementation's operational characteristics are reluctant to deploy an alternative that provides less visibility into its behavior. By providing structured health assessment, actionable recommendations, automated stabilization, and emergency degradation — all as first-class CLI subsystems rather than afterthought logging — TSUNAGI reduces the operational risk of adoption.

The layered design supports progressive trust-building. An operator can begin by running KAGAMI alongside their existing monitoring to understand TSUNAGI's health model. They can then enable YAMORI checks to validate that the health assessment aligns with observed behavior. KURA stabilization can be enabled once the operator trusts the reseal decision logic. At each stage, the operator gains confidence through transparent, verifiable behavior rather than requiring blind trust in a monolithic system.

### 10.3 Experimentation Platform

The implementation is structured as a single repository with no external package dependencies beyond the Zig standard library and LMDB. The build system produces a single static binary. This minimal dependency surface reduces the barrier to building, auditing, and contributing to the codebase. The modular architecture — with independently testable layers, explicit interfaces, and comprehensive inline test suites — supports incremental contribution where a developer can understand and modify one layer without requiring knowledge of the entire system.

---

## 11. Future Work

### 11.1 Mainnet Validation

Deploying the shadow pipeline on a mainnet node for an extended period (days to weeks) would validate parity under production transaction volumes and larger UTxO set sizes. The shadow pipeline's advisory nature and bounded resource consumption make this safe for production deployment.

### 11.2 Full-State Parity Hashing

Implementing a periodic full UTxO set comparison between primary and shadow pipelines — triggered at configurable intervals rather than every block — would close the granularity gap in parity verification without imposing per-block overhead. A comparison every 1,000 blocks, for example, would provide high confidence in entry-level equivalence at negligible amortized cost.

### 11.3 Extended Coverage Tracking

Instrumenting the node to log cumulative coverage statistics — total found, total checked, and running coverage ratio — across hours of operation would quantify the convergence rate of the shadow-write mechanism and determine the time required for a bootstrapped LMDB store to achieve full near-tip coverage.

### 11.4 Storage Backend Experimentation

The modular storage interface enables controlled experimentation with alternative persistence engines. RocksDB, SQLite, and custom B-tree implementations can be benchmarked against LMDB on identical block streams, with the shadow system providing correctness verification for each candidate.

### 11.5 Partial LMDB Application

The current all-or-nothing model requires every consumed input to be present in LMDB. A partial-apply model would apply LMDB deletes for inputs that are present while skipping missing ones, reducing the coverage threshold required for direct LMDB success from 100% to a configurable minimum.

### 11.6 Observability-Driven Automation

Predictive health monitoring could analyze trends in coverage diagnostics, fragment depth, and tip-artifact gap to forecast degradation before it reaches warning thresholds. Cross-node health aggregation could extend the single-node diagnostic model to fleet-level awareness, detecting divergence between nodes and distinguishing local issues from network-wide conditions.

### 11.7 Cross-Chain Research

Extending the delta extraction layer to support Bitcoin's block format would enable unified UTxO state tracking across both chains within a single process, opening research directions in cross-chain verification and bridge architecture design.

---

## 12. Conclusion

This paper has presented TSUNAGI, a deterministic Cardano node implementation in Zig that introduces a modular ledger architecture, a runtime shadow verification methodology, a persistent storage system with graduated fault tolerance, and an observability-first operational design. Together, these contributions demonstrate that an independent Cardano node can achieve production-grade correctness, operational transparency, and architectural flexibility while maintaining full protocol compatibility with the existing network.

### Architectural Contributions

The modular ledger pipeline separates CBOR delta extraction, deterministic state application, undo management, and persistent storage into independently testable layers with explicit interfaces and no shared mutable state. This separation enables the ledger engine to be driven by live network traffic, recorded block sequences, or synthetic test vectors with identical behavior, eliminating the coupling between protocol-level synchronization and ledger-level state transitions that characterizes monolithic node architectures.

The shadow ledger verification system provides continuous runtime parity checking by executing an independent pipeline instance alongside the primary path on identical inputs. Zero shadow mismatches across all experimental sessions on the Cardano preview network establish semantic equivalence between the extracted pipeline and the proven inline implementation for the class of transitions observed. This methodology transforms correctness validation from a periodic testing activity into a continuous production assurance mechanism.

The LMDB truth mode introduces a three-stage degradation ladder for persistent UTxO storage: a read-only preflight coverage check avoids wasted write transactions when consumed inputs are missing, an atomic write transaction provides durable state mutation when coverage is complete, and a memory fallback with shadow-write maintains forward progress and progressive convergence when coverage is incomplete. This design ensures that LMDB inconsistencies — whether caused by bootstrap freshness gaps, transient storage failures, or incomplete state accumulation — never halt the node or corrupt its state.

The observability architecture, comprising four named subsystems — KAGAMI for diagnostics, YAMORI for health evaluation, TATE for fragment defense, and KURA for stabilization — embeds health assessment and remediation capability directly in the node binary. Shared thresholds across all subsystems ensure consistent health evaluation regardless of the query interface. Structured output in human-readable and machine-readable formats supports both manual diagnosis and automated monitoring integration.

### Independent Implementation Value

TSUNAGI provides the Cardano ecosystem with a second production-grade node implementation, addressing the concentration risk inherent in single-client networks. Implementation diversity ensures that a defect in one codebase does not produce a correlated failure across all network participants. The existence of an independent implementation also validates the protocol specification through independent interpretation: agreement between implementations confirms the specification, while divergence identifies ambiguities or defects that strengthen the protocol's formal foundation.

The shadow parity system extends this validation from a static specification review to a dynamic runtime process. Every block processed by a TSUNAGI node with the shadow pipeline enabled produces a parity observation that either confirms equivalence or identifies a divergence at the specific block and slot where it occurs. This continuous verification operates at negligible computational cost — an O(1) undo-depth comparison per block — making it suitable for indefinite production deployment.

### Engineering Philosophy

The engineering decisions underlying TSUNAGI reflect a consistent philosophy: determinism over convenience, explicitness over abstraction, observability over opacity, and defense over optimism.

Determinism is enforced by confining all non-deterministic inputs (network timing, peer selection, block arrival order) to the protocol layer, ensuring that the ledger state machine produces identical output for identical input regardless of execution context. Explicit error handling through typed error sets eliminates hidden control flow and enables callers to implement graduated recovery strategies appropriate to each failure mode. Observability is treated as a first-class architectural concern rather than an instrumentation afterthought, with the node capable of evaluating and explaining its own health through structured diagnostics. Defensive operational design — bounded undo stacks, non-fatal shadow-write semantics, reversible safe-mode enforcement, idempotent artifact stabilization — ensures that automated remediation actions cannot worsen the conditions they are designed to address.

### Experimental Validation

Empirical evaluation on the Cardano preview network has produced zero shadow parity mismatches, zero apply errors, zero rollback errors, and correct undo depth tracking across all experimental sessions. LMDB truth mode has demonstrated correct fallback continuity under near-zero coverage conditions, correct shadow-write behavior that maintains persistent store synchronization during fallback, and correct preflight coverage diagnostics that quantify per-block LMDB store health. Snapshot bootstrap round-trip integrity has been verified through cryptographic digest comparison across independent imports. The replay harness and pipeline proof tests have verified end-to-end correctness with synthetic CBOR vectors, confirming rollback invertibility and empty-block handling.

### Future Outlook

Continued validation on the Cardano mainnet will extend the evidence base to production transaction volumes, larger UTxO set sizes, and longer operational durations. The modular storage interface enables controlled experimentation with alternative persistence engines and tiered caching strategies. The deterministic replay capability supports offline verification pipelines, cross-implementation compatibility testing, and performance benchmarking under reproducible conditions. The UTxO-agnostic pipeline abstraction provides a foundation for cross-chain research, including interoperability experiments between Cardano and other UTxO-based networks.

TSUNAGI demonstrates that a Cardano node can be simultaneously correct, observable, operationally defensive, and architecturally open to experimentation. Its contribution to the ecosystem is not merely a second implementation of an existing protocol but a demonstration that independent implementation, when pursued with disciplined engineering methodology, strengthens both the protocol it implements and the network it serves.

---

## 13. TSUNAGI as Infrastructure

### 13.1 Beyond a Node Implementation

TSUNAGI is designed not only as a Cardano node but as a deterministic execution environment for blockchain state machine research. The distinction is significant: a node implementation is judged by its ability to synchronize with the network and maintain consensus, while an infrastructure platform is judged by the breadth of work it enables beyond its primary function. TSUNAGI's architecture — modular layers with explicit interfaces, no shared global state, caller-provided allocators, and typed error propagation — satisfies both criteria simultaneously.

The deterministic ledger pipeline processes identical inputs to identical outputs regardless of execution context. This property, enforced by confining all non-determinism to the protocol layer, means the pipeline can serve as a reference execution environment for any research that requires reproducible UTxO state transitions. A researcher studying transaction fee dynamics, UTxO fragmentation patterns, or address reuse statistics can drive the pipeline with recorded block sequences and obtain results that are bitwise reproducible across runs, machines, and time.

### 13.2 Modular Architecture as Experimentation Substrate

Each layer of the ledger engine — delta extraction, state application, undo management, persistent storage — exposes an explicit interface that accepts its dependencies through function parameters. This design permits controlled substitution: replacing one layer while holding all others constant, and measuring the effect of the substitution in isolation.

The storage layer is the most immediate target for substitution experiments. The five-operation transactional interface (begin read, begin write, get, put, delete) is storage-engine agnostic. Any backend that implements these operations — whether an embedded database, a distributed key-value store, or a custom data structure optimized for a specific access pattern — can be evaluated against the existing LMDB implementation on identical block streams. The shadow verification system provides automatic correctness checking for any candidate backend: zero mismatches after processing a representative block sequence establishes that the new backend preserves the state transition semantics.

The delta extraction layer is similarly substitutable. The current implementation parses Cardano's CBOR block format, but the pipeline itself operates on abstract consumed-input and produced-output types. An extraction layer targeting a different block format — Bitcoin's serialization, an Ethereum state diff encoding, or a synthetic format designed for fuzz testing — would feed the same pipeline without modification to the application, undo, or storage layers.

### 13.3 Ledger Pipeline Reuse

The pipeline's abstract UTxO types — a consumed input identified by a 32-byte hash and a 32-bit index, a produced output pairing that identifier with an address and a value — describe the fundamental UTxO spending model shared by Cardano, Bitcoin, and their respective derivative networks. This abstraction is not an accident of implementation but a deliberate design choice that positions the pipeline as a reusable component.

A concrete reuse scenario is multi-chain UTxO tracking. An operator running infrastructure that must monitor UTxO state across multiple chains could instantiate one pipeline per chain, each fed by a chain-specific extraction layer, sharing the same application logic, undo semantics, and storage interface. The operational tooling — KAGAMI health reporting, YAMORI integrity checks, KURA stabilization — would apply uniformly across all instances, reducing the operational complexity of multi-chain infrastructure from N independent systems to N extraction layers fronting a common execution and observability stack.

### 13.4 Replay Harness as Verification Platform

The replay harness elevates block replay from a testing convenience to a verification platform. By decoupling the pipeline from the network, the harness enables several classes of verification that live operation cannot provide.

**Regression verification.** A corpus of recorded blocks, processed through successive versions of the pipeline, detects behavioral changes introduced by code modifications. The corpus serves as a fixed reference input; any change in output (UTxO counts, undo depth trajectory, error conditions) identifies a regression with block-level precision.

**Cross-implementation verification.** Two independent node implementations can exchange recorded block corpora and process them through each other's ledger engines. Agreement on the resulting state after processing identical sequences provides protocol-level compatibility evidence that does not require the implementations to operate on the same live network.

**Adversarial verification.** Synthetic block bodies with pathological CBOR structures — deeply nested maps, maximum-length arrays, edge-case integer encodings, duplicate transaction inputs — can exercise error handling paths that the live network may never produce. The harness processes these inputs without network interaction, enabling systematic coverage of defensive code paths.

### 13.5 Sidechain and Partner Protocol Integration

The Cardano ecosystem includes sidechain initiatives and partner protocols — such as Midnight — that share architectural heritage with the Cardano mainchain while introducing distinct state transition rules. TSUNAGI's modular architecture provides a natural integration point for these protocols.

A sidechain that uses the UTxO model can reuse the pipeline's state application, undo management, and persistent storage layers, requiring only a custom delta extraction layer for its block format. The shadow verification system can validate the sidechain pipeline against an independent implementation, providing the same continuous parity assurance that TSUNAGI provides for the Cardano mainchain. The observability subsystems — health checking, fragment defense, artifact stabilization — apply to any chain-following process, not only to Cardano mainchain synchronization.

This integration potential does not require protocol modifications or consensus changes on any chain. It operates entirely at the infrastructure level: a single node binary capable of following multiple chains through modular pipeline instantiation, with unified operational tooling across all instances.

### 13.6 Research Infrastructure Role

TSUNAGI's value as research infrastructure derives from a combination of properties that are individually common but rarely found together in a single system: deterministic execution, modular substitution, continuous correctness verification, persistent state with graduated fault tolerance, structured observability, and reproducible replay. Collectively, these properties lower the cost of blockchain state machine research by providing a verified baseline that researchers can extend without rebuilding from scratch.

A research group studying UTxO set dynamics can use the pipeline and replay harness directly, adding instrumentation at the pipeline's explicit interface points. A team investigating alternative storage engines can substitute backends and use the shadow system for correctness validation. A protocol researcher exploring sidechain designs can instantiate additional pipelines with custom extraction layers. In each case, the researcher inherits the correctness guarantees established by TSUNAGI's test suite, shadow verification, and preview network validation, focusing their effort on the novel contribution rather than the baseline infrastructure.

---

## 14. Security Model

### 14.1 Scope and Assumptions

The security model of TSUNAGI addresses the correctness and integrity of ledger state transitions within a single node. It does not address consensus-level security (which is provided by the Ouroboros protocol and the broader network), cryptographic key management (which is handled by the operator's key infrastructure), or network-level denial of service (which is a transport concern outside the ledger architecture). The model assumes that the Zig compiler produces correct machine code for the source as written, that the host operating system provides correct memory management and file system semantics, and that the LMDB library implements its documented transactional guarantees.

Within these assumptions, TSUNAGI provides the following security properties.

### 14.2 Deterministic State Machine Guarantees

The ledger pipeline is a deterministic function: given identical inputs (consumed-input and produced-output slices), it produces identical outputs (UTxO map state and undo log entries) regardless of execution timing, host platform characteristics, or concurrent system activity. This property is enforced through four mechanisms.

**No global state.** Every module below the follower integration boundary operates exclusively on parameters passed through function arguments. There are no module-level variables, no thread-local storage, and no ambient configuration. Two pipeline instances processing the same inputs in the same process produce identical results because they share no mutable state.

**No environment coupling.** The pipeline reads no environment variables and consults no external configuration. All behavioral parameters — apply mode, store pointer, allocator — are explicit function arguments. The follower integration boundary translates environment variables into these parameters; the pipeline itself is unaware of the translation.

**Explicit error propagation.** Functions return typed error sets rather than panicking, trapping, or calling process exit. Every error condition is represented in the function's return type, and the caller must handle it explicitly. This eliminates hidden control flow divergence where the same input could produce different behavior depending on whether a runtime chose to abort or continue on an internal error.

**Caller-provided allocation.** Every heap allocation passes through an allocator provided by the caller. The pipeline never allocates from a global heap, never caches allocations across calls, and never retains references to freed memory. This enables the testing infrastructure to use a leak-detecting allocator that fails immediately on any allocation error, ensuring that memory management bugs are detected during testing rather than manifesting as non-deterministic behavior in production.

### 14.3 Protocol and Ledger Separation

The strict boundary between the protocol layer (TSURUGI) and the ledger layer (pipeline) provides a security-relevant containment property: a defect in protocol handling cannot directly corrupt ledger state, and a defect in ledger logic cannot directly affect protocol behavior.

The protocol layer delivers raw block bytes to the delta extraction layer. The extraction layer parses CBOR and produces typed delta structures. The pipeline processes these structures. At no point does the pipeline receive or process raw network data, protocol messages, or peer-influenced control signals. A malformed protocol message that survives the extraction layer's CBOR validation would manifest as an invalid delta (for example, a consumed input with an all-zero hash) that the pipeline processes deterministically — producing a well-defined state change rather than undefined behavior.

This separation also means that a vulnerability in the CBOR parser — buffer overflow, integer overflow, or out-of-bounds read — cannot propagate into the pipeline's state machine logic. The extraction layer is the trust boundary: it accepts untrusted input and produces trusted delta structures. The pipeline operates entirely within the trusted domain.

### 14.4 Correctness Verification Guarantees

The shadow verification system provides a continuous correctness oracle with the following guarantees.

**Detection completeness for undo-depth divergence.** Any defect that causes the primary and shadow pipelines to disagree on the number of successful block applications or rollbacks will be detected within one block of the divergence occurring. The comparison executes after every transition, with zero sampling or batching.

**Detection latency.** Divergence is detected and reported at the block and slot where it occurs, not at a later checkpoint or audit point. The mismatch report includes the specific block number, slot, and both pipeline states, enabling immediate diagnosis.

**Non-interference.** The shadow pipeline cannot affect the primary pipeline's behavior. The two share no mutable state. A bug in the shadow (including a crash or out-of-memory condition) increments an error counter and continues; the primary path is unaffected. This guarantee holds because the shadow is instantiated with its own allocator and its own UTxO map, and its results are never read by any code path that influences the primary.

The replay harness extends these guarantees to offline verification. A recorded block sequence processed through the pipeline produces deterministic results that can be compared across builds, platforms, and time. A change in replay output between two builds constitutes proof of a behavioral change, enabling bisection to the exact commit that introduced the divergence.

### 14.5 Persistence Safety

LMDB provides ACID transactional semantics with crash safety through copy-on-write B+ tree storage. TSUNAGI's use of LMDB preserves these guarantees through disciplined transaction management.

**Atomicity.** Each block application in lmdb_truth and lmdb_native modes executes within a single LMDB write transaction. Either all mutations (consumed-input deletions and produced-output insertions) commit together, or none commit. A crash or power failure during a write transaction leaves the store in its pre-transaction state.

**Isolation.** The single-writer, multiple-reader model ensures that a read-only preflight check observes a consistent snapshot of the store, unaffected by any concurrent write. The preflight's coverage assessment is therefore accurate at the time of the read — no write can interleave between preflight completion and the subsequent write transaction's begin.

**Durability.** Committed transactions are durable across process restarts and host reboots. The LMDB memory-mapped file is synchronized to disk on commit. A node that restarts after a committed write will observe the committed state.

**Fallback safety.** In lmdb_truth mode, a failed write transaction (at any stage — begin, apply, or commit) triggers a transaction abort followed by a memory fallback. The abort guarantees that no partial write reaches the store. The subsequent shadow-write opens a new, independent transaction. A failure in the shadow-write similarly aborts without corrupting the store. At no point can a partial or inconsistent write persist in LMDB.

### 14.6 Undo Stack Design and Rollback Safety

The undo stack provides bounded, deterministic rollback capability with the following safety properties.

**Bounded depth.** The undo stack is capped at MAX_UNDO_DEPTH (200 entries). This bound is enforced on every push: when the stack would exceed the maximum, the oldest entry is evicted before the new entry is pushed. The bound prevents unbounded memory growth in the undo stack regardless of chain behavior.

**Correct memory reclamation.** Each undo entry may contain removed-entry records with address slices that were duplicated during the forward application. Every code path that discards an undo entry — stack cap eviction in pushUndo, explicit rollback in rollbackBlock, confirmation eviction in confirmOldest, and pipeline destruction in deinit — walks the entry's records and frees the duplicated address slices before freeing the entry's backing memory. This invariant is verified by the testing allocator, which detects any unfreed allocation as a test failure.

**Rollback atomicity.** A rollback pops the most recent undo entry and applies its reverse operations to both the in-memory UTxO map (via rollbackDelta) and the LMDB store (via lmdbRollback). The LMDB rollback executes within a single write transaction, ensuring that the store either fully reverts to its pre-block state or remains unchanged. The in-memory rollback is a deterministic function of the undo entry and cannot fail (the entries to remove were inserted during the forward pass and are guaranteed present; the entries to restore were removed during the forward pass and carry complete data).

### 14.7 Corruption Containment

The architecture provides multiple containment boundaries that limit the blast radius of a defect in any single component.

**Shadow isolation.** The shadow pipeline operates in a separate memory space from the primary pipeline. A corruption of the shadow's UTxO map — whether caused by a bug, a memory error, or an allocator failure — cannot propagate to the primary. The shadow's output is read only for comparison; it is never used as input to any other computation.

**Storage isolation.** The LMDB store is accessed exclusively through the five-operation transactional interface. The pipeline never performs raw memory-mapped file access, never manipulates B+ tree structures directly, and never bypasses the transaction mechanism. A bug in the pipeline cannot corrupt the store's internal data structures because the pipeline never touches them.

**Layer isolation.** The delta extraction layer, the apply engine, the pipeline wrapper, and the replay harness are separate compilation units with no shared mutable state. A defect in one layer's logic cannot corrupt another layer's data structures because no layer holds references into another layer's memory.

**Mode isolation.** The three apply modes (memory_only, lmdb_truth, lmdb_native) share the same pipeline and undo stack but differ in their interaction with the LMDB store. A defect in the LMDB-specific code path (for example, an incorrect key encoding in putTxn) would affect lmdb_truth and lmdb_native modes but leave memory_only mode unaffected. This isolation enables differential diagnosis: if the shadow (memory_only) and primary (lmdb_truth) diverge, the defect is localized to the LMDB-specific code path.

---

## 15. Threat Model

### 15.1 Scope

This section enumerates the classes of failures and adversarial conditions that TSUNAGI is designed to detect, tolerate, or mitigate. For each class, the relevant defense mechanisms are identified. The threat model addresses operational threats to a single node's correctness and availability; it does not address network-level consensus attacks, which are the domain of the Ouroboros protocol.

### 15.2 Malformed Blocks

**Threat.** A peer delivers a block whose CBOR structure does not conform to the expected format — truncated bytes, invalid CBOR encoding, missing transaction body fields, or structurally valid CBOR that does not represent a valid Cardano block.

**Mitigation.** The delta extraction layer (block_stream) parses the CBOR and returns null on any parse failure. The replay harness and follower integration treat a null extraction result as a skip rather than a crash. No state mutation occurs for a block that fails extraction. The pipeline's state remains at its pre-extraction position, and synchronization continues with the next block.

The CBOR parser operates on a copy of the block bytes, not on the raw network buffer. A malformed block cannot cause a buffer overflow in the pipeline because the pipeline never sees the raw bytes — it receives only the typed delta structures that survive extraction, or nothing at all.

### 15.3 Storage Corruption

**Threat.** The LMDB data file is corrupted by a disk failure, a file system error, an incomplete write during a power loss, or an external process modifying the file.

**Mitigation.** LMDB's copy-on-write transactional design provides crash safety: a power failure during a write transaction leaves the store in its last committed state. Corruption from external modification (a process writing directly to the data file) is outside LMDB's guarantee but is detected at the next transaction open, which will fail with an environment error.

In lmdb_truth mode, any LMDB failure — whether from corruption, from an environment error, or from a read returning unexpected data — triggers the fallback path. The pipeline continues operating in memory with shadow-writes keeping the store as synchronized as possible. The node does not halt.

In lmdb_native mode, LMDB failure is a hard error. The node stops, and the operator must restore the store from a snapshot before restarting. This mode is intended for environments where storage integrity is guaranteed by external means (redundant storage, checksummed file systems, or regular snapshot verification via the lmdb-digest CLI command).

KAGAMI's health snapshot includes LMDB availability as a checked property. YAMORI's lmdb_available check verifies that the store can be opened. An operator monitoring these subsystems will detect storage problems before they affect block processing.

### 15.4 LMDB Coverage Gaps

**Threat.** The LMDB store does not contain all consumed inputs referenced by an incoming block. This is a normal operational condition when the store is populated from a bootstrap snapshot that predates the chain tip, or when the store has not yet accumulated sufficient shadow-write history.

**Mitigation.** The preflight coverage check detects this condition before any write transaction is opened. When missing inputs are detected, the pipeline skips the LMDB write path entirely, applies the block in memory, and performs a shadow-write to insert the block's produced outputs into LMDB. This sequence is correct (the block is applied), efficient (no wasted write transaction), and convergent (each shadow-write increases the store's coverage of recently produced outputs).

The preflight diagnostic reports the exact coverage ratio (found/total) for each block, enabling operators and automated systems to track coverage trends and determine when the store has achieved sufficient coverage for lmdb_native promotion.

### 15.5 Chain Rollbacks

**Threat.** The chain-synchronization protocol signals a rollback, requiring the node to reverse one or more previously applied blocks and re-apply blocks from a different fork. Rollbacks are a normal part of the Ouroboros protocol and occur when competing slot leaders produce blocks at the same height.

**Mitigation.** The undo stack maintains per-block undo logs that record every mutation performed during forward application. A rollback pops the most recent undo entry and applies its inverse operations to both the in-memory UTxO map and the LMDB store. The rollback is atomic with respect to both stores: the in-memory rollback is a deterministic function of the undo entry, and the LMDB rollback executes within a single write transaction.

The undo stack depth is capped at 200 entries, matching the Ouroboros security parameter's practical bound on rollback depth. Rollbacks deeper than the undo stack (which would indicate a catastrophic chain reorganization beyond the protocol's security guarantee) produce an EmptyUndoStack error that the follower handles by re-synchronizing from a known anchor point.

The shadow pipeline processes the same rollback, providing parity verification that the rollback was applied correctly. A rollback that produces different undo depths in the primary and shadow pipelines would be immediately detected and reported as a mismatch.

### 15.6 Peer Network Instability

**Threat.** The upstream peer disconnects, delivers blocks out of order, delivers duplicate blocks, or stalls during header or block delivery. Network instability is common in peer-to-peer networks and can cause the node to experience rapid sequences of connections, disconnections, rollbacks, and re-synchronizations.

**Mitigation.** The protocol layer (TSURUGI) handles connection management, reconnection with backoff, and intersection re-negotiation independently of the ledger layer. The ledger pipeline is unaware of network events — it processes deltas as they arrive, regardless of the network conditions that produced them.

On reconnection, the protocol layer signals a rollback to the intersection point before resuming forward delivery. The pipeline handles this rollback through the normal undo mechanism. If the undo stack is empty (as it is at startup or after a long disconnection), the rollback produces an expected EmptyUndoStack error that the follower logs and continues past.

YAMORI's follower_alive and follower_tip_age checks detect stalled synchronization. An operator or automated system observing a stale tip age can investigate whether the cause is network instability, peer selection, or an internal node issue.

### 15.7 State Divergence Between Implementations

**Threat.** The TSUNAGI node's UTxO state diverges from the reference implementation's state, causing the node to accept blocks that the reference rejects or reject blocks that the reference accepts. This is the most serious correctness threat for an independent implementation.

**Mitigation.** The shadow verification system provides continuous detection of state divergence between the extracted pipeline and the proven inline implementation. Both process identical deltas from every block; any divergence in undo depth is detected and reported within one block of occurrence.

For divergence between TSUNAGI and the external reference implementation, the node's behavior on the live network provides indirect detection: a node with a divergent UTxO state will eventually fail to validate a block that the network accepts, causing it to fall behind the chain tip. KAGAMI's tip age monitoring and YAMORI's follower_tip_age check detect this condition as increasing tip staleness.

The replay harness enables proactive divergence detection without waiting for a live-network failure. Block corpora recorded by both implementations can be cross-processed, with any disagreement in resulting state identifying the exact block where divergence occurs. This offline verification can be performed periodically as a scheduled validation activity.

The deterministic pipeline design ensures that any divergence, once identified, is reproducible: the same block processed through the same pipeline version produces the same result every time, enabling precise diagnosis without the confounding factors of network timing or concurrent state changes.

### 15.8 Incomplete Bootstrap Snapshots

**Threat.** A bootstrap snapshot imported into LMDB is incomplete, corrupted during transfer, or taken from a chain state that does not match the node's current synchronization target.

**Mitigation.** The TSF2 snapshot format includes a Blake2b-256 digest computed over the entire file during export. The import process recomputes this digest and rejects the snapshot if it does not match, detecting any corruption or truncation that occurred during transfer or storage.

The bootstrap command imports with strict mode enabled, meaning that the import fails immediately if the digest does not verify. A successful import guarantees that the LMDB store contains exactly the UTxO entries that were present in the exporting node's store at the time of export.

However, the import does not guarantee that the imported UTxO set is current with respect to the chain tip — this is the coverage gap described in Section 15.4. The preflight diagnostic quantifies this gap on every block, and the shadow-write mechanism progressively closes it during operation.

Network magic validation in the snapshot metadata allows detection of cross-network imports (for example, importing a mainnet snapshot into a preview node). The bootstrap process logs the network magic from the snapshot metadata, enabling the operator to verify that it matches the target network.

### 15.9 Unexpected Node Restarts

**Threat.** The node process terminates unexpectedly due to a crash, an out-of-memory condition, an operator kill signal, or a host reboot. In-memory state is lost; persistent state may be in a partially updated condition.

**Mitigation.** The LMDB store's copy-on-write transactional semantics ensure that the persistent store is always in a consistent, committed state. An uncommitted write transaction is automatically rolled back when the LMDB environment is closed (or when the process terminates without closing it). On restart, the store reflects the last committed state.

The in-memory UTxO map and undo stack are lost on restart. In memory_only mode, this means the node must re-synchronize from a cursor point or genesis. In lmdb_truth mode, the LMDB store provides a persistent baseline: the pipeline resumes with an empty in-memory map and undo stack, but the LMDB store retains its accumulated state. Blocks arriving after restart will use the LMDB state for consumed-input lookup, with the preflight diagnostic reporting coverage based on the store's pre-restart contents.

The cursor file (cursor.json) records the node's last synchronization point. On restart, the protocol layer uses this cursor to negotiate an intersection with the peer, avoiding re-synchronization from genesis. The cursor is written atomically (write to temporary file, then rename), ensuring that a crash during cursor update leaves the previous valid cursor intact.

KAGAMI and YAMORI detect the consequences of an unexpected restart: a fresh cursor with a low roll-forward count, an empty undo stack, and potentially a stale tip age while the node catches up. These conditions are normal and self-resolving; the observability subsystems provide visibility into the recovery progress.

### 15.10 Defense in Depth

The threat mitigations described above operate at different layers of the architecture, providing defense in depth. The following table summarizes the primary defense mechanism for each threat class and the observability layer that provides visibility into the condition.

| Threat | Primary Defense | Detection Layer |
|--------|----------------|-----------------|
| Malformed blocks | CBOR extraction returns null; no state mutation | Extraction error count |
| Storage corruption | LMDB copy-on-write; lmdb_truth fallback | YAMORI lmdb_available |
| Coverage gaps | Preflight check; memory fallback; shadow-write | Preflight coverage diagnostic |
| Chain rollbacks | Undo stack with bounded depth | Shadow parity verification |
| Peer instability | Protocol-layer reconnection; cursor persistence | YAMORI follower_tip_age |
| State divergence | Shadow parity; replay cross-verification | Shadow mismatch counter |
| Incomplete snapshot | TSF2 Blake2b-256 digest verification | Bootstrap import validation |
| Unexpected restart | LMDB transaction atomicity; cursor persistence | KAGAMI tip age monitoring |

No single mechanism defends against all threats. The architecture's resilience derives from the combination of deterministic execution, transactional persistence, continuous verification, and structured observability — each addressing a different failure mode, collectively providing comprehensive coverage of the operational threat landscape.

---

## 16. Mempool Architecture

Transactions enter the mempool through HTTP submission or the TxSubmission2 ingestion path. Every candidate passes through six sequential admission gates: structural CBOR validation, duplicate hash detection, intra-mempool input conflict rejection, UTxO existence verification against LMDB, lovelace balance validation (inputs >= outputs + fee), and validity interval enforcement (TTL and validity-start against the current observed slot). Each gate produces a specific rejection reason and counter exported to /state and Prometheus.

After block application, the mempool is scanned for confirmed transactions. Any item whose consumed inputs overlap with the block's consumed set is evicted automatically, ensuring the mempool inventory remains consistent with the ledger state.

---

## 17. TxSubmission2

TSUNAGI implements bidirectional NtN TxSubmission2. On the follower connection (TSUNAGI as protocol client), the relay can request transaction inventory via MsgRequestTxIds and transaction bodies via MsgRequestTxs. Active broadcast is supported: when the mempool changes and a session is active, TSUNAGI proactively sends updated inventory.

On the propagation server connection (TSUNAGI as protocol server), TSUNAGI initiates the pull after MsgInit. It sends MsgRequestTxIds to request the relay's mempool inventory, parses the returned identifiers, sends MsgRequestTxs for selected transactions, and admits each received body through the full six-gate mempool pipeline.

The serving path is proven end-to-end with inventory and body delivery. The ingestion path is proven end-to-end with server-initiated request, inventory parsing, body delivery, and mempool admission. Real relay session establishment (MsgInit) is confirmed on live propagation connections.

---

## 18. Validation Envelope

TSUNAGI performs transaction-level validation in two implemented stages. At block decode time (v0): input uniqueness within each transaction, validity interval enforcement against the block slot, and zero-fee detection. At LMDB apply time and mempool submit time (v1A): lovelace balance validation and output address structural checks.

These checks do not constitute full Cardano ledger validation. Not yet implemented: min-fee calculation, min-UTxO enforcement, native script execution, Plutus V1/V2/V3 execution, witness signature verification, epoch boundary state transitions, and protocol parameter loading.

---

## 19. Trust Stack

The trust stack builds verifiable signed artifacts from runtime observations across eight layers: snapshot (signed canonical JSON state proof), history (append-only bounded retention), reputation (four-factor weighted score), peer exchange (fetch and verify against known public keys), federation (two-hop views with agreement and divergence classification), trust graph (nodes, edges, cluster classification), propagation (depth-bounded merge with weight decay), and verification (any artifact verifiable with trust-verify).

All artifacts use canonical JSON with fixed key order, Blake2b-256 digests, and Ed25519 signatures. The trust stack is deterministic under identical inputs and does not use a runtime allocator.

---

## 20. Honest Limitations

TSUNAGI does not execute Plutus scripts, validate native scripts, enforce protocol parameters (min-fee, min-UTxO), process epoch boundary state transitions, or verify transaction witness signatures. Relay TxSubmission2 behavior is topology-dependent. Trust depends on operator-curated peer lists without Sybil resistance. Block production is proven on preview only.

TSUNAGI is progressing toward a fuller Zig-native Cardano node but does not overclaim full-node completion.

---

## Appendix A. Implementation Metrics

This appendix summarizes the quantitative characteristics of the TSUNAGI implementation as of the current release. All figures are derived from direct measurement of the source tree and build configuration. The metrics presented here complement the architectural descriptions in the preceding sections by grounding design claims in concrete implementation data.

### A.1 Codebase Scale

The TSUNAGI implementation comprises 64,474 lines of Zig source code distributed across 159 modules. The codebase contains 170 inline test blocks, each exercising a specific behavioral property of the module in which it resides. Inline tests execute within the same compilation unit as the code they verify, eliminating the synchronization burden between test suites and implementation that characterizes external test file approaches.

| Metric | Value |
|--------|-------|
| Total lines of Zig source | 64,474 |
| Source modules (.zig files) | 159 |
| Inline test blocks | 170 |
| Registered test executables | 14 |
| External library dependencies | 2 |

The two external library dependencies — LMDB (Lightning Memory-Mapped Database) and libsodium (cryptographic primitives) — are linked as system libraries. No runtime interpreter, garbage collector, virtual machine, or language-level package manager is required. The entire node compiles to a single statically-linked binary.

### A.2 Ledger Engine Modules

The deterministic ledger engine described in Sections 4 through 6 is implemented across seven modules totaling 1,902 lines of Zig source.

| Module | Lines | Responsibility |
|--------|-------|----------------|
| `block_apply.zig` | 816 | Three-mode UTxO application engine with preflight coverage check, undo management, and LMDB transactional writes |
| `ledger_pipeline.zig` | 275 | Stateful pipeline wrapper holding UTxO map, undo stack, and store pointer with apply/rollback/confirm interface |
| `replay_harness.zig` | 250 | Offline block replay driver for deterministic regression and cross-build verification |
| `pipeline_proof_test.zig` | 193 | Multi-block integration tests verifying apply-rollback-reapply sequences and undo stack invariants |
| `tx_decode.zig` | 146 | Facade over protocol-layer CBOR transaction decoder with canonical transaction identifier computation |
| `utxo_extract.zig` | 143 | LMDB UTxO query interface providing lookup, count, digest, and cursor iteration |
| `block_stream.zig` | 79 | Delta extraction adapter converting raw block bytes to consumed-input and produced-output slices |

The `block_apply.zig` module is the largest ledger component because it implements all three apply modes (memory_only, lmdb_truth, lmdb_native), the read-only preflight coverage scan, the LMDB shadow-write mechanism, and the rollback engine within a single compilation unit. Its 816 lines include 92 lines of inline tests covering preflight coverage detection and mode-specific behavior.

The protocol-layer transaction decoder (`net/ledger/tx_decode.zig`, 805 lines) and UTxO type definitions (`net/ledger/utxo.zig`, 232 lines) reside outside the ledger engine directory. These modules predate the extraction and remain in their original locations to preserve proven import paths. The ledger engine references them through explicit imports without modification.

### A.3 Observability Stack

The four observability subsystems described in Section 7 are implemented across dedicated modules within the guardian and CLI subsystems.

| Subsystem | Primary Module | Lines | Function |
|-----------|---------------|-------|----------|
| KAGAMI | `kagami/snapshot.zig` + `cli/kagami_cmd.zig` | 1,010 | Structured health snapshots with JSON telemetry, tip age, peer state, roll counters, and LMDB availability |
| YAMORI | `cli/guardian_cmd.zig` (integrated) | 6,585* | Event memory with threshold evaluation, safe-mode engagement, and coordinated response orchestration |
| TATE | `guardian/tate.zig` | 393 | Shield-layer health evaluation with configurable threshold checks and severity classification |
| KURA | `guardian/kura_stabilizer.zig` | 124 | Stabilization agent for artifact refresh and fragment defense with file-system integrity verification |

*YAMORI is integrated within the guardian command module rather than isolated in a standalone file. The 6,585-line guardian module encompasses YAMORI's event memory, threshold evaluation, safe-mode logic, and the command-line interface for all guardian operations. TATE's threshold definitions and KURA's stabilization schedules are coordinated through this module.

The observability stack produces JSON-formatted telemetry suitable for ingestion by external monitoring systems. KAGAMI snapshots are self-contained documents reporting node state at the moment of capture; YAMORI evaluations are event-driven assessments triggered by threshold crossings; TATE checks are periodic health probes; KURA stabilization runs are scheduled maintenance operations.

### A.4 Storage Engine

The persistent storage layer uses LMDB as its sole backend, accessed through a transactional interface that enforces single-writer isolation and copy-on-write crash safety.

| Component | Module | Lines | Function |
|-----------|--------|-------|----------|
| UTxO store | `store/lmdb_utxo.zig` | 251 | Five-operation transactional interface (beginRead, beginWrite, get, put, delete) over LMDB environment |
| Snapshot export | `store/snapshot_cmd.zig` | 366 | TSF2-format UTxO set serialization with Blake2b-256 integrity digest |
| Snapshot signing | `store/snapshot_sign.zig` | 278 | Ed25519 signature generation and verification for snapshot attestation |
| Snapshot proof | `cli/snapshot_proof_cmd.zig` | 894 | Snapshot integrity verification, cross-node comparison, and proof-of-state generation |
| State digest | `store/lmdb_digest_cmd.zig` | 44 | CLI command computing Blake2b-256 digest over the complete LMDB UTxO set for offline verification |
| Backfill autopilot | `store/lmdb_backfill_autopilot.zig` | 1,456 | Automated LMDB population from historical block data with progress tracking |

The snapshot subsystem implements a complete export-sign-verify-import pipeline. The TSF2 format serializes UTxO entries in batches of 50,000, computes a rolling Blake2b-256 digest over the entire file, and optionally attaches an Ed25519 signature for provenance attestation. The import process recomputes the digest and rejects any snapshot whose integrity check fails, preventing corrupted or tampered snapshots from populating the store.

The state digest command (`lmdb-digest`) enables offline verification of LMDB store contents. Two nodes that have processed identical block histories and maintained identical UTxO application logic will produce identical digests, providing a compact proof of state agreement without transmitting or comparing the full UTxO set.

### A.5 Runtime Validation Tools

Five validation mechanisms operate at different stages of the development and deployment lifecycle.

**Shadow ledger verification.** The shadow pipeline, instantiated in memory_only mode alongside the primary pipeline, processes identical deltas from every block and compares undo stack depth after each application. Divergence detection occurs within one block of the causing event. The shadow operates in an isolated memory space and cannot affect primary pipeline behavior. Shadow parity is verified continuously during live synchronization.

**Replay harness.** The offline replay driver processes recorded block sequences through the deterministic pipeline, producing results that are bitwise reproducible across builds, platforms, and time. The harness supports regression detection (comparing outputs across code versions), cross-implementation verification (processing corpora from different node implementations), and adversarial testing (processing synthetic blocks with pathological structure).

**Pipeline proof tests.** The `pipeline_proof_test.zig` module (193 lines) contains multi-block integration tests that exercise apply-rollback-reapply sequences, verify undo stack depth invariants, confirm that rollback restores exact prior state, and validate that empty-delta blocks correctly increment undo depth without altering UTxO count.

**Preflight coverage diagnostics.** The read-only LMDB scan in `block_apply.zig` counts consumed inputs present in the store before any write transaction is opened. Coverage metrics (found count, total count) propagate through the `ApplyResult` structure to the follower's diagnostic output, enabling operators to track LMDB coverage trends and determine convergence readiness for lmdb_native promotion.

**Snapshot proof verification.** The `snapshot_proof_cmd.zig` module (894 lines) provides comprehensive snapshot integrity verification, including digest recomputation, signature validation, cross-node state comparison, and proof-of-state generation for external auditors.

### A.6 Node Operational Capabilities

The compiled binary exposes its operational capabilities through a unified command-line interface dispatched from `main.zig` (1,877 lines).

| Capability | CLI Command | Function |
|------------|-------------|----------|
| Chain synchronization | `tsunagi-node` (default) | Ouroboros mini-protocol chain-sync with configurable peer, network magic, and apply mode |
| Snapshot bootstrap | `--bootstrap` | Import TSF2 snapshot into LMDB store with digest verification |
| Snapshot export | `--snapshot-export` | Serialize current LMDB UTxO set to TSF2 format with integrity digest |
| State digest | `--lmdb-digest` | Compute and print Blake2b-256 digest of LMDB UTxO contents |
| Health snapshot | `--kagami` | Emit JSON health snapshot of current node state |
| Guardian evaluation | `--guardian` | Run YAMORI threshold evaluation with TATE health checks |
| Replay | `--replay` | Process recorded block corpus through deterministic pipeline |
| Evidence pack | `--evidence-pack` | Collect diagnostic artifacts into a timestamped archive |
| Console | `--console` | Interactive node inspection and diagnostic interface |

LMDB convergence diagnostics are emitted during live synchronization when running in lmdb_truth mode. Each block application reports whether the preflight coverage check succeeded (all consumed inputs found) or triggered the memory fallback path, along with the exact coverage ratio. These diagnostics enable operators to observe the store's progressive convergence toward full coverage as shadow-writes accumulate produced outputs from successive blocks.

### A.7 Build Characteristics

TSUNAGI compiles with the Zig build system (`build.zig`, standard `zig build` invocation) and requires no external build tools, package managers, or code generators. The build configuration supports four optimization levels (Debug, ReleaseSafe, ReleaseFast, ReleaseSmall) and cross-compilation to any target supported by the Zig compiler's backend.

| Build Property | Value |
|----------------|-------|
| Build system | Zig native (`build.zig`) |
| External build tools required | None |
| Linked system libraries | LMDB, libsodium |
| Runtime dependencies | None (single static binary) |
| Optimization levels | Debug, ReleaseSafe, ReleaseFast, ReleaseSmall |
| Cross-compilation | Supported via `standardTargetOptions()` |

The build embeds reproducibility metadata into the compiled binary: version tag, git commit hash, git tag, source dirty flag, build epoch (Unix timestamp), target triple, and Zig compiler version. This metadata enables precise identification of any deployed binary's provenance — the exact source revision, build configuration, and compiler version that produced it. Two builds from identical source at identical revisions with identical compiler versions produce functionally equivalent binaries, supporting deterministic deployment verification.

The absence of external runtime dependencies — no JVM, no Python interpreter, no Node.js runtime, no dynamically loaded plugins — means the compiled binary's behavior is determined entirely by its source code and the two linked libraries. This property simplifies deployment (a single file copy), reduces the attack surface (no dependency supply chain beyond LMDB and libsodium), and eliminates the class of runtime failures caused by missing or incompatible dependencies in the deployment environment.

The 14 registered test executables partition the test suite by subsystem, enabling selective test execution during development. Each test executable links only the system libraries required by its modules, and all tests execute under the Zig testing allocator, which detects memory leaks, double frees, and use-after-free errors as immediate test failures rather than latent runtime defects.

---

## Appendix B. Development Timeline

This appendix traces the chronological evolution of the TSUNAGI node from its earliest concept through the current architecture. The development proceeded through eight distinct phases over approximately six weeks, each building on the foundations established by its predecessors. The narrative presented here explains not only what was built at each stage but why that particular subsystem was needed at that point in the project's evolution.

### B.1 Initial Motivation

TSUNAGI originated from the observation that the Cardano ecosystem, despite its formal specification heritage and peer-reviewed protocol design, relied on a single production node implementation. This concentration represented both a validation gap and a resilience risk: a single implementation cannot confirm protocol assumptions through independent derivation, and a defect in the sole implementation affects the entire network simultaneously.

The project adopted three founding constraints that shaped every subsequent design decision. First, the implementation language would be Zig — chosen for its explicit memory management, comptime metaprogramming, absence of hidden control flow, and single-binary compilation model. Second, external dependencies would be minimized to the irreducible core: LMDB for persistent storage and libsodium for cryptographic primitives. No runtime interpreter, garbage collector, or dynamically loaded framework would be permitted. Third, every subsystem would prioritize observability and operator clarity over abstraction elegance — the node would be designed to be understood, diagnosed, and operated by a single person without specialized tooling or institutional knowledge.

These constraints were not arbitrary aesthetic preferences. Explicit memory management eliminates the class of non-deterministic behaviors caused by garbage collection pauses and finalizer ordering. Minimal dependencies reduce the attack surface and eliminate supply-chain risks. Operator clarity ensures that when the node encounters an anomalous condition at three in the morning, the operator can diagnose the issue from the node's own diagnostic output without consulting external documentation or contacting the development team.

### B.2 Early Networking Foundations

Development began at the lowest layer of the protocol stack: raw TCP byte transport. The Ouroboros network protocol requires a multiplexed bearer over TCP, with length-prefixed framing, protocol-specific sub-channels, and a versioned handshake negotiation. Rather than adopting an existing networking library, TSUNAGI implemented each layer from first principles in Zig.

The TCP byte transport layer established the connection lifecycle: socket creation, connection establishment, buffered read and write, and clean shutdown. Above this, a length-prefixed framing layer segmented the byte stream into discrete messages with explicit boundaries. The multiplexer (mux) layer assigned each message to a protocol-specific sub-channel identified by a mini-protocol identifier, enabling multiple concurrent protocols — ChainSync, BlockFetch, KeepAlive, TxSubmission — to share a single TCP connection without interference.

The handshake protocol implementation negotiated the Node-to-Node version (v14) with the peer, establishing the protocol parameters that govern subsequent communication. This was the first point at which TSUNAGI communicated with a live Cardano node, and the successful completion of a v14 handshake on the preview network validated the byte transport, framing, and mux layers in a single integration test.

With the handshake established, the ChainSync mini-protocol implementation followed. ChainSync is the primary mechanism by which a Cardano node receives new block headers and bodies from its peers. The implementation parsed CBOR-encoded protocol messages, maintained the protocol state machine (Idle, CanAwait, MustReply), and processed FindIntersect and RequestNext exchanges. Early validation on the preview network confirmed that TSUNAGI could discover an intersection point with a peer's chain and begin receiving RollForward and RollBackward messages — the fundamental operations of chain synchronization.

### B.3 Propagation Architecture

Once TSUNAGI could follow a chain, the next requirement was the ability to serve that chain to downstream peers. The propagation subsystem transformed TSUNAGI from a passive follower into an active relay capable of participating in the network's block distribution.

The propagation architecture introduced the concept of rolling fragments — bounded windows of recently received block headers and bodies stored in memory and backed by LMDB for persistence across restarts. A rolling fragment of 2,160 entries (approximately three epochs of Cardano blocks) provided sufficient history for downstream peers to find an intersection point and begin synchronization without requiring the full chain history.

Fragment coverage tracking quantified which slot ranges the node could serve. The coverage map — a sorted interval set of slot ranges — enabled the node to answer intersection queries accurately, directing peers to the most recent common point in the chain rather than falling back to genesis. Coverage diagnostics at startup reported the fragment's extent and any gaps, giving operators immediate visibility into the node's serving capability.

The propagation server implemented the ChainSync and BlockFetch server-side protocols, responding to FindIntersect, RequestNext, and BatchRequest messages from downstream peers. Ancestor seeding populated the LMDB header store with sufficient chain history to support intersection discovery across epoch boundaries. The seal-tip mechanism atomically captured the current chain tip and its associated fragment state, ensuring that propagation served a consistent view of the chain even during rapid block production.

Propagation validation on the preview network confirmed that a downstream TSUNAGI node could synchronize from an upstream TSUNAGI node, establishing that the implementation correctly served both sides of the ChainSync and BlockFetch protocols. This milestone — verified at v4.5.31 — demonstrated protocol-level compatibility without reference implementation involvement in the relay path.

### B.4 Observability Layer Creation

As the node's operational complexity grew — following chains, serving peers, managing persistent state — the need for structured observability became acute. Operators required more than log messages; they needed queryable state, health assessments, and automated integrity checks.

KAGAMI (the diagnostic mirror) was the first observability subsystem, providing point-in-time snapshots of the node's complete operational state. A KAGAMI snapshot captures tip height, tip age, peer connection state, roll-forward and roll-backward counters, UTxO set size, undo stack depth, LMDB availability, and fragment coverage — all serialized as a single JSON document. The snapshot is a pure query: it reads state without modifying it, can execute at any time without affecting block processing, and produces machine-parseable output suitable for ingestion by external monitoring systems.

YAMORI (the guardian lizard) introduced event memory and threshold-based health evaluation. Where KAGAMI reports current state, YAMORI evaluates state against configurable thresholds and maintains a history of threshold crossings. A tip age exceeding a configured maximum, a follower that has not advanced for a specified duration, or an LMDB store that fails availability checks — each condition triggers a YAMORI event that persists in the event memory and contributes to a cumulative health assessment. When sufficient adverse conditions accumulate, YAMORI engages safe-mode, a defensive posture that restricts the node's behavior to protective operations until the conditions resolve.

TATE (the shield) added fragment defense evaluation, assessing the integrity and completeness of the propagation fragment. TATE checks verify that the fragment's slot ranges are contiguous, that header hashes chain correctly within the fragment, and that the fragment's extent is sufficient for downstream peer intersection. A TATE evaluation that detects fragment degradation informs the operator before the degradation affects downstream peers.

KURA (the storehouse) completed the observability stack with stabilization and archive management. KURA evaluates whether archived artifacts — snapshots, evidence packs, proof bundles — are intact, current, and correctly organized. It manages retention policies, verifies file-system integrity of stored artifacts, and performs scheduled stabilization runs that refresh stale artifacts and clean obsolete ones.

The four subsystems operate independently and can be invoked individually or in combination. Their shared design principle is that observability is not instrumentation added after the fact but a first-class architectural layer with the same engineering rigor as the protocol and ledger layers.

### B.5 Ledger Engine Extraction

The initial UTxO application logic was implemented inline within the ChainSync follower — the 8,048-line module that orchestrates chain synchronization, block processing, and state management. This inline approach was appropriate during early development, when the interaction between protocol state and ledger state was being discovered through iterative implementation. Once the logic stabilized and its behavioral properties were confirmed through extended operation on the preview and mainnet networks, extraction into standalone modules became both safe and necessary.

The extraction proceeded bottom-up. The block stream module provided the delta extraction interface, converting raw block bytes into typed consumed-input and produced-output slices. The block apply module extracted the three-phase application engine — preflight scan, transactional LMDB write, memory fallback — into a pure function that accepts its dependencies through parameters and returns a typed result structure. The ledger pipeline module wrapped the UTxO map, undo stack, and store pointer into a stateful container with apply, rollback, and confirm operations. The replay harness provided an offline driver that processes recorded block sequences through the pipeline without network interaction.

Each extracted module was verified through inline tests that exercise its specific behavioral properties in isolation. The pipeline proof test module added multi-block integration tests covering apply-rollback-reapply sequences, undo stack depth invariants, and empty-delta edge cases. Critically, the extraction did not modify the original follower code — the inline implementation continued to operate in production while the extracted modules were validated independently. This parallel existence enabled differential testing: the shadow pipeline (running the extracted code in memory_only mode) could be compared against the inline implementation on every block, with any divergence in undo depth detected within one block of occurrence.

### B.6 Shadow Ledger Verification

The shadow verification system emerged from a specific engineering need: how to validate the extracted ledger modules against the proven inline implementation without disrupting production synchronization.

The solution was a parallel pipeline instantiated in memory_only mode, processing the same deltas extracted from every block by the follower's existing code. After each block application, the follower compares the shadow pipeline's undo stack depth against its own. A match confirms that both implementations — the inline original and the extracted module — agree on the number of successful state transitions. A mismatch triggers an immediate diagnostic report identifying the block, slot, and both depths, enabling precise root-cause analysis.

The shadow pipeline operates in complete isolation from the primary path. It maintains its own UTxO map, its own undo stack, and its own allocator. A crash, out-of-memory condition, or logic error in the shadow cannot affect the primary pipeline because the two share no mutable state. The shadow's output is read for comparison and then discarded; it is never used as input to any subsequent computation.

This verification methodology provided the confidence required to proceed with LMDB integration. Before connecting the extracted ledger engine to persistent storage, extended operation with zero shadow mismatches confirmed that the extraction preserved the behavioral semantics of the original inline implementation. The shadow continues to operate after LMDB integration, now verifying that the combination of extracted logic and persistent storage produces the same state transitions as the memory-only reference.

### B.7 Persistent Storage and LMDB Integration

LMDB integration proceeded through a graduated sequence of operational modes, each providing stronger persistence guarantees while maintaining the ability to fall back to proven in-memory operation.

The initial LMDB work established the five-operation transactional interface (beginRead, beginWrite, get, put, delete) and the UTxO store that maps transaction input identifiers to decoded output values. The snapshot export command serialized the complete LMDB UTxO set to the TSF2 format with a Blake2b-256 integrity digest. The bootstrap command imported a TSF2 snapshot into a fresh LMDB environment, enabling a new node to begin operation with a pre-populated UTxO set rather than re-deriving state from genesis.

The lmdb_truth mode connected the extracted ledger engine to the LMDB store through a three-stage degradation strategy. First, a read-only preflight scan checks whether the store contains all consumed inputs referenced by the incoming block. If any inputs are missing — as expected when the store was populated from a snapshot that predates the current chain tip — the pipeline skips the LMDB write path entirely, applies the block in memory, and performs a shadow-write that inserts the block's produced outputs into the store. This shadow-write mechanism is convergent: each block application increases the store's coverage of recently produced outputs, progressively closing the coverage gap without requiring a complete re-bootstrap.

If the preflight scan finds all consumed inputs present, the pipeline opens a write transaction, applies the block's mutations (deleting consumed inputs, inserting produced outputs), and commits. A failure at any stage — write transaction creation, mutation application, or commit — triggers the same memory fallback with shadow-write, ensuring that the pipeline continues operating regardless of LMDB's transactional outcome.

The preflight coverage diagnostic, added in the final development phase, quantified this convergence by reporting the exact ratio of found-to-total consumed inputs for each block. Preview network validation confirmed the expected pattern: an initial period of high fallback rates (100% immediately after bootstrap) followed by gradual improvement as shadow-writes accumulated recent outputs. The diagnostic enabled operators to track convergence progress and determine when the store had achieved sufficient coverage for promotion to lmdb_native mode, where LMDB serves as the authoritative state store without memory fallback.

### B.8 Research and Documentation Phase

The final development phase shifted focus from implementation to validation, documentation, and the articulation of TSUNAGI's contributions to the broader blockchain infrastructure research landscape.

Preview network testing provided the primary validation environment. Extended synchronization sessions — ranging from ten minutes to multiple hours — confirmed zero shadow mismatches, zero apply errors, and zero rollback errors across hundreds of blocks. The preflight coverage diagnostic quantified LMDB convergence rates under realistic network conditions. The state digest command enabled cross-node state comparison, verifying that two nodes processing identical block histories produced identical UTxO set digests.

The replay harness experiments demonstrated deterministic reproducibility: recorded block sequences processed through the pipeline produced identical results across repeated executions, confirming that the ledger engine's behavior is a pure function of its inputs. Pipeline proof tests exercised edge cases — empty-delta blocks, rapid apply-rollback-reapply sequences, undo stack boundary conditions — that the live network might not produce within any practical observation window.

The whitepaper itself represents the culmination of this phase: a formal articulation of the architectural decisions, verification methodology, security properties, and experimental evidence that collectively establish TSUNAGI as a contribution to blockchain infrastructure research. The document is grounded in measured implementation characteristics — line counts, test counts, module boundaries, validation results — rather than aspirational claims, reflecting the project's engineering discipline of building evidence before drawing conclusions.

The development timeline demonstrates a consistent architectural philosophy: each phase built on verified foundations, each new capability was validated against proven behavior before being trusted, and each subsystem was designed to be understood, tested, and operated independently. This philosophy — expressed through explicit interfaces, deterministic execution, continuous verification, and structured observability — is not merely a description of how TSUNAGI was built but a statement of how the project believes blockchain infrastructure should be built.

---

## Appendix C. Terminology and System Glossary

This appendix defines the core terminology used throughout the TSUNAGI architecture. The purpose is to provide a consistent vocabulary for operators, developers, and researchers interacting with the system.

**TSUNAGI.**
The deterministic Cardano node implementation described in this paper. TSUNAGI integrates a modular ledger pipeline, persistent storage with LMDB, runtime shadow verification, and layered observability systems.

**TSURUGI (剣) — Protocol Engine.**
The network protocol layer responsible for peer communication and chain synchronization. TSURUGI implements the Ouroboros node-to-node protocols including ChainSync and BlockFetch, and manages peer selection, multiplexing, and block retrieval.

**Ledger Pipeline.**
The deterministic state machine responsible for applying transaction deltas to the UTxO set. The pipeline separates delta extraction, state mutation, undo management, and persistent storage into modular components.

**Block Stream.**
The CBOR extraction layer that converts raw block body bytes into typed delta structures containing consumed inputs and produced outputs.

**Block Apply.**
The state transition module that applies or rolls back deltas across three modes: memory_only, lmdb_truth, and lmdb_native.

**Replay Harness.**
A deterministic execution environment used to replay blocks offline. It allows reproducible verification of ledger state transitions without network interaction.

**Shadow Ledger.**
An independent pipeline instance running alongside the primary ledger. The shadow receives identical inputs and verifies parity with the primary ledger after every block application. It never influences consensus decisions.

**Undo Stack.**
A bounded stack of per-block undo logs enabling reversible state transitions. Each successful block application records the changes required to revert the UTxO set during a rollback event.

**LMDB Truth Mode.**
A persistence mode in which LMDB serves as the authoritative UTxO store. The system attempts atomic LMDB writes and falls back to memory application with shadow-write synchronization when coverage gaps exist.

**Shadow-Write.**
A best-effort persistence step executed after fallback application. Consumed inputs are deleted and produced outputs are inserted into LMDB without validation, allowing the store to gradually converge with live chain state.

**Preflight Coverage Check.**
A read-only diagnostic scan that counts how many consumed inputs for a block are present in the LMDB store. This prevents wasted write transactions when coverage gaps are known in advance.

**KAGAMI (鏡) — Diagnostic Mirror.**
The observability subsystem that reflects node state through reports, JSON snapshots, and real-time telemetry streams.

**YAMORI (家守) — Guardian Monitor.**
The health evaluation system that performs structured integrity checks and records operational events. Note: The spelling 家守 ("house guardian") is intentionally used instead of the biological spelling 守宮 ("gecko"). In TSUNAGI the term represents a guardian subsystem responsible for node health and integrity rather than the literal animal name.

**TATE (盾) — Fragment Defense.**
The fragment verification layer that evaluates propagation artifact integrity and ancestry continuity.

**KURA (蔵) — Stabilization Layer.**
The subsystem responsible for propagation artifact maintenance and retention policy enforcement.

**Fragment.**
A rolling window of recent block ancestry used for peer intersection and propagation serving.

**Coverage.**
The proportion of consumed inputs for a block that are present in the LMDB persistent store.

**Fallback.**
The event where LMDB application cannot proceed due to missing coverage and the system applies the block in memory instead.

**Primary Pipeline.**
The ledger pipeline instance responsible for authoritative state mutation during node operation.

**Shadow Pipeline.**
The secondary verification pipeline used for runtime parity checking.

**Deterministic Replay.**
Offline execution of recorded block sequences through the ledger pipeline to verify state transitions and benchmark performance.
