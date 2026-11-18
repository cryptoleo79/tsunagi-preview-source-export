# TSUNAGI — Deterministic Cardano Node Architecture

⚠️ TSUNAGI is under active development and the repository is currently private until the architecture stabilizes.

## Overview

TSUNAGI is an independent Cardano node architecture written entirely in Zig. The system implements the Ouroboros node-to-node protocols — ChainSync and BlockFetch — and maintains a live UTxO set through a deterministic ledger pipeline with persistent storage, runtime verification, and structured operator observability.

The implementation compiles to a single static binary with two external library dependencies (LMDB and libsodium). There is no runtime interpreter, garbage collector, or dynamically loaded framework. Every function receives its dependencies through explicit parameters, every error is represented in the return type, and every heap allocation passes through a caller-provided allocator.

TSUNAGI is designed for operators who value clarity, determinism, and the ability to diagnose their node's behavior from its own output.

## Architecture Layers

TSUNAGI is organized into five major architectural layers, each with a distinct responsibility and explicit interface boundaries.

### TSURUGI (剣) — Protocol Engine

The network protocol layer responsible for peer communication and chain synchronization. TSURUGI implements the Ouroboros node-to-node handshake (v14), multiplexed bearer transport, ChainSync for tip tracking and header delivery, and BlockFetch for full block retrieval. The protocol engine manages peer selection, connection lifecycle, and intersection negotiation independently of the ledger layer.

### Ledger Pipeline — Deterministic State Machine

The modular ledger engine that applies transaction deltas to the UTxO set. The pipeline separates delta extraction (parsing CBOR block bodies into typed inputs and outputs), state mutation (applying or rolling back UTxO changes), undo management (bounded stack of reversible per-block logs), and persistent storage into independently testable components. Given identical inputs, the pipeline produces identical outputs regardless of execution timing, host platform, or concurrent activity.

### Shadow Ledger — Runtime Verification

An independent pipeline instance running alongside the primary ledger in memory-only mode. The shadow receives identical transaction deltas from every block and verifies parity with the primary pipeline after each application. The shadow operates in complete isolation — it maintains its own UTxO map, its own undo stack, and its own allocator. It never influences the primary path. Divergence is detected within one block of occurrence.

### LMDB Truth Mode — Persistent Storage

A graduated persistence strategy using LMDB as the authoritative UTxO store. The system performs a read-only preflight scan to assess coverage before opening write transactions, falls back to memory application when coverage gaps exist, and performs shadow-writes that progressively converge the store with live chain state. Three operational modes — memory-only, LMDB truth, and LMDB native — allow operators to select the persistence guarantee appropriate to their deployment.

### Observability Stack — KAGAMI / YAMORI / TATE / KURA

Four layered observability subsystems providing structured diagnostics, health evaluation, integrity verification, and artifact management.

| Subsystem | Name | Function |
|-----------|------|----------|
| **KAGAMI** | 鏡 (Mirror) | Diagnostic snapshots, JSON telemetry, real-time state queries |
| **YAMORI** | 家守 (Guardian) | Health evaluation, event memory, threshold-based safe-mode. In TSUNAGI, YAMORI is written as 家守 ("house guardian") to emphasize its role as the protective health-monitoring subsystem. |
| **TATE** | 盾 (Shield) | Fragment defense, propagation artifact integrity verification |
| **KURA** | 蔵 (Storehouse) | Stabilization, retention policy enforcement, archive management |

## SPO-Friendly Design

TSUNAGI is designed with stake pool operators (SPOs) in mind.

A core design goal of the project is to reduce operational complexity and infrastructure overhead for relay and block-producing nodes while maintaining deterministic ledger correctness and full protocol compatibility with the Cardano network.

Several architectural choices support this goal:

- Zig-based runtime with no garbage collector or interpreter
- Deterministic ledger pipeline with explicit memory ownership
- Modular architecture separating protocol, ledger, storage, and observability
- Efficient persistent storage via LMDB with fallback continuity
- Built-in observability systems that simplify operational monitoring

These design decisions allow TSUNAGI nodes to run with reduced operational friction compared to traditional node architectures.

The objective is not to modify Cardano's consensus rules, but to provide an alternative implementation that emphasizes determinism, transparency, and operational clarity.

This makes TSUNAGI particularly suitable for SPO relay infrastructure, research environments, and deterministic node deployments.

## System Architecture Overview

The TSUNAGI node architecture is organized as a layered system where each subsystem is responsible for a specific operational concern.
This layered structure separates protocol execution, ledger state management, persistent storage, and operator observability into independent components.
The diagram below illustrates how these subsystems interact to form the complete TSUNAGI node runtime.

```
                     ┌──────────────────────────┐
                     │        KAGAMI 鏡         │
                     │   Diagnostic Mirror      │
                     └─────────────┬────────────┘
                                   │
                     ┌─────────────▼────────────┐
                     │        YAMORI 家守        │
                     │     Guardian Monitor     │
                     └─────────────┬────────────┘
                                   │
                     ┌─────────────▼────────────┐
                     │         TATE 盾          │
                     │     Fragment Defense     │
                     └─────────────┬────────────┘
                                   │
                     ┌─────────────▼────────────┐
                     │         KURA 蔵          │
                     │      Stabilization       │
                     └─────────────┬────────────┘
                                   │
                     ┌─────────────▼────────────┐
                     │       TSURUGI 剣         │
                     │      Protocol Engine     │
                     │   ChainSync + BlockFetch │
                     └─────────────┬────────────┘
                                   │
                     ┌─────────────▼────────────┐
                     │   Deterministic Ledger   │
                     │      Pipeline Engine     │
                     │ block_stream → apply →   │
                     │ rollback → verification  │
                     └─────────────┬────────────┘
                                   │
                     ┌─────────────▼────────────┐
                     │     Persistent Storage   │
                     │          LMDB            │
                     │   snapshots + bootstrap  │
                     └──────────────────────────┘
```

## Project Status

TSUNAGI is under active development and live validation on the Cardano preview network.

### Latest Milestone (#68): Propagation Artifact Coherence

Forge promotion now publishes a coherent sealed artifact with verified fragment ancestry. The propagation server validates ancestry coherence at serve time and rejects incoherent fragment state rather than serving stale ancestry to a connecting relay.

**What was fixed:** FORGE_PROMOTE_ATOMIC previously wrote only sealed block files to propagation_artifact/ without refreshing the fragment ancestry window. The stale fragment's tail hash did not match the promoted sealed block's parent hash. The relay saw TSUNAGI as stale at connection time (relay_ahead=true in the observed failing case) and disconnected after MsgIntersectFound before MsgRequestNext.

**What is proven now:**
- Publish-time artifact coherence (sealed + fragment published atomically)
- Serve-time coherence enforcement (incoherent fragment dropped, single-header fallback)
- Structured truth logs (FORGE_PROMOTE_FRAGMENT, ARTIFACT_COHERENCE_TRUTH, ARTIFACT_READY_TRUTH)
- Regression tests for coherence validation

**Current live target:** Observe relay path where CHAIN_POSITION shows relay_ahead=false and relay proceeds through MsgRequestNext, MsgRollBackward, MsgRollForward, and BlockFetch.

**Not yet proven:** Network-accepted forged block, consensus parity with cardano-node, full-node completeness, production-ready BP status.

### Previous Milestones

- Zig 0.15.2 toolchain migration (#67)
- Enforcement experiment with policy-alignment telemetry (#66)
- Decision stack operator surface (#64)
- Policy-coupled ordering experiment (#62)
- Eight-layer trust pipeline (signals through policy impact)
- VRF + KES block forge with deferred slot-time execution
- Six-gate hardened mempool with bidirectional TxSubmission2
- LMDB-backed ancestry-verified persistent ledger state

A complete whitepaper documenting the architecture, verification methodology, security model, and experimental results is available within the project repository.
