# TSUNAGI — Architecture Summary

⚠️ TSUNAGI is under active development and the repository is currently private until the architecture stabilizes.

## Deterministic Ledger Pipeline

The TSUNAGI ledger engine is a deterministic state machine that processes Cardano blocks and maintains a live UTxO set. The architecture separates concerns into modular layers, each with explicit interfaces, no shared global state, and typed error propagation.

The design exists to satisfy four requirements simultaneously:

1. **Determinism.** Identical inputs produce identical outputs regardless of execution context. No global state, no environment coupling, no hidden control flow.
2. **Testability.** Each module is independently testable with inline tests that exercise specific behavioral properties in isolation.
3. **Replay capability.** Recorded block sequences can be replayed offline through the pipeline, producing bitwise reproducible results across builds, platforms, and time.
4. **Modular experimentation.** Any layer can be substituted while holding others constant, enabling controlled evaluation of alternative implementations.

## Module Structure

The ledger engine is composed of five modules with a clear data flow:

### Block Stream

The extraction layer. Converts raw CBOR block body bytes into typed delta structures: consumed inputs (transaction inputs being spent) and produced outputs (new UTxO entries being created). This is the boundary between untrusted protocol data and the trusted pipeline domain.

### Block Apply

The state transition engine. Applies consumed/produced deltas to the UTxO map across three operational modes:

- **memory_only** — Pure in-memory application with no persistence. Used by the shadow pipeline and for testing.
- **lmdb_truth** — LMDB serves as the authoritative store with automatic memory fallback when coverage gaps exist. Shadow-writes progressively converge the store.
- **lmdb_native** — LMDB is the sole state authority. Failures are hard errors.

Each application produces a typed result containing consumed count, produced count, undo log, fallback status, and preflight coverage metrics.

### Ledger Pipeline

The stateful wrapper that holds the UTxO map, undo stack, store pointer, and apply mode. Provides three operations: apply (forward), rollback (reverse), and confirm (evict oldest undo entry after sufficient chain depth).

### Replay Harness

The offline execution driver. Processes recorded block sequences through the pipeline without network interaction. Supports regression detection, cross-build verification, and adversarial testing with synthetic block structures.

### Follower Integration

The boundary where the extracted pipeline connects to the live ChainSync follower. The follower extracts deltas from each received block, drives both the primary and shadow pipelines, compares parity after every application, and emits diagnostic output.

## Why This Architecture Exists

### Independent Implementation Diversity

The Cardano ecosystem benefits from multiple independent node implementations. A second implementation derived independently from the protocol specification can confirm protocol assumptions, surface ambiguities in the specification, and provide network resilience against single-implementation defects.

### Alternative Storage Engines

The pipeline's storage interface is engine-agnostic. Any backend implementing the five transactional operations (begin read, begin write, get, put, delete) can be evaluated against the existing LMDB implementation on identical block streams. The shadow verification system provides automatic correctness checking for any candidate backend.

### Reproducible Verification

The deterministic pipeline and replay harness together enable verification that is reproducible across time, builds, and machines. A recorded block corpus processed through the pipeline produces identical results in every execution, supporting bisection to the exact commit that introduces any behavioral change.

## Architecture Diagram

```
┌──────────────────────────────────────────────────┐
│                   KAGAMI  鏡                      │
│          Observability & Diagnostics              │
├──────────────────────────────────────────────────┤
│    YAMORI 家守    │   TATE  盾   │   KURA  蔵     │
│  Guardian Health  │  Fragment    │ Stabilization  │
│  Event Memory     │  Defense     │ Archive Mgmt   │
├──────────────────────────────────────────────────┤
│              LEDGER PIPELINE                      │
│                                                   │
│  Block Stream ──► Block Apply ──► UTxO State      │
│                       │                           │
│                  Undo Stack                        │
│                       │                           │
│              ┌────────┴────────┐                  │
│              │  Shadow Ledger  │  (parity check)  │
│              └─────────────────┘                  │
├──────────────────────────────────────────────────┤
│              LMDB PERSISTENCE                     │
│                                                   │
│  Preflight ──► Write Txn ──► Commit               │
│      │              │                             │
│      └── coverage ──┘── fallback ──► Shadow-Write │
├──────────────────────────────────────────────────┤
│              TSURUGI  剣                          │
│       Protocol Engine: ChainSync & BlockFetch     │
├──────────────────────────────────────────────────┤
│              NETWORK                              │
│       Node-to-Node — TCP / MUX / Handshake        │
└──────────────────────────────────────────────────┘
```

## Design Constraints

- No global mutable state
- No environment variable coupling below the follower boundary
- Caller-provided allocators for all heap allocation
- Typed error returns — never panic, trap, or process exit
- Forward-only commits during development
- Zero modification to proven protocol files during extraction
