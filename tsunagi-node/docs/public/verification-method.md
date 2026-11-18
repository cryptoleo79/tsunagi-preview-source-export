# TSUNAGI — Shadow Ledger Verification Methodology

⚠️ TSUNAGI is under active development and the repository is currently private until the architecture stabilizes.

## Problem

How do you verify a new ledger implementation safely?

A Cardano node's correctness depends on its UTxO state transitions matching the protocol specification exactly. A single incorrect application — a consumed input not removed, a produced output with a wrong address, a rollback that fails to restore prior state — can cause the node's view of the chain to diverge silently from the network. In a production environment, this divergence may not manifest until blocks later, when a transaction references state that the node believes exists but the network does not, or vice versa.

Traditional testing — unit tests, integration tests, replay tests — can verify known scenarios but cannot cover the full space of block sequences, rollback patterns, and edge cases that the live network produces. The verification problem requires a method that operates continuously during live synchronization, covers every block the node processes, and detects divergence immediately when it occurs.

## Solution

Run two independent pipeline instances in parallel on every block.

TSUNAGI instantiates two ledger pipelines that process identical transaction deltas extracted from each block received during chain synchronization:

**Primary Pipeline.** The authoritative ledger instance responsible for the node's UTxO state. Operates in the configured apply mode (memory-only, LMDB truth, or LMDB native) and produces the state that the node uses for all subsequent operations.

**Shadow Pipeline.** An independent verification instance running in memory-only mode. Receives the same consumed-input and produced-output slices as the primary. Maintains its own UTxO map, its own undo stack, and its own allocator. Its results are never used as input to any other computation.

After every block application — whether forward (RollForward) or backward (RollBackward) — the follower compares the undo stack depth of both pipelines. A match confirms that both implementations agree on the number of successful state transitions. A mismatch triggers an immediate diagnostic report.

## Comparison Points

The shadow verification system compares:

- **Undo depth** — The number of entries in the undo stack after each block application. This is the primary parity signal. Agreement on undo depth implies agreement on the number of successful forward applications and rollbacks.
- **Block application sequence** — Both pipelines process every block in the same order. The shadow receives its deltas from the same extraction that feeds the primary, ensuring input identity.
- **Rollback behavior** — When the protocol signals a rollback, both pipelines pop their most recent undo entry and reverse the corresponding state changes. The shadow's rollback operates on its own independent state.

## Key Properties

**The shadow is advisory only.** It never affects the primary pipeline's behavior. The primary path executes identically whether the shadow is enabled or disabled. The shadow's output is read for comparison and then discarded.

**It never affects the primary path.** The two pipelines share no mutable state. The shadow maintains its own UTxO map, its own undo stack, and its own allocator. A crash, out-of-memory condition, or logic error in the shadow cannot propagate to the primary because there is no shared memory, no shared reference, and no shared control flow.

**Mismatches are logged immediately.** A divergence is detected and reported at the block and slot where it occurs, not at a later checkpoint or audit point. The diagnostic includes the block number, slot, and both pipeline depths, enabling precise root-cause analysis.

**This allows continuous runtime verification.** The shadow operates during live synchronization with negligible performance overhead. Every block the node processes is verified — not a sample, not a periodic check, but every single block for the entire duration of operation.

## Verification Loop

The following pseudocode illustrates the shadow verification logic:

```
initialize primary_pipeline(configured_mode, lmdb_store)
initialize shadow_pipeline(memory_only, no_store)

for each block received from ChainSync:
    deltas = extract_deltas(block)

    if block is RollForward:
        primary_result = primary_pipeline.apply(deltas)
        shadow_result  = shadow_pipeline.apply(deltas)

    if block is RollBackward:
        primary_pipeline.rollback()
        shadow_pipeline.rollback()

    if primary_pipeline.undo_depth != shadow_pipeline.undo_depth:
        log_mismatch(
            block_number,
            slot,
            primary_depth = primary_pipeline.undo_depth,
            shadow_depth  = shadow_pipeline.undo_depth
        )
        increment mismatch_counter
```

## Validation Results

Extended validation sessions on the Cardano preview network have confirmed:

- Zero shadow mismatches across hundreds of blocks
- Zero apply errors in both pipelines
- Zero rollback errors during chain reorganization events
- Shadow parity maintained continuously through forward and backward transitions

The shadow verification system provides the confidence foundation for all subsequent integration work, including LMDB persistent storage, preflight coverage diagnostics, and mode promotion decisions.
