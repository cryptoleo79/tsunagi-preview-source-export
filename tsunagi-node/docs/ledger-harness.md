# Ledger Harness — Deterministic Ledger Snapshot + Rewind + Replay (v3.4.0)

## Purpose

Offline, deterministic, fail-fast harness that proves ledger state determinism
across rewind/replay using existing runtime logic.

**Verification-only. No forging. No broadcast. No chain injection. No gossip.**

## Deterministic Digest Algorithm

The digest is computed independently of LMDB iteration order:

1. Iterate all UTxO entries from LMDB storage
2. For each entry, construct canonical bytes:
   - `txid` (32 bytes)
   - `index` (u32, big-endian)
   - `lovelace` (u64, big-endian)
3. Collect all canonical entries into an array
4. Sort lexicographically by full serialized entry
5. Stream sorted entries into Blake2b256
6. Final hash = `ledger_digest`

**Guarantees:**
- Same state produces the same digest
- Rewind + replay produces an identical digest

## Subcommands

### snapshot

Compute deterministic digest and write snapshot JSON.

```
tsunagi-node ledger-harness snapshot --home <TSUNAGI_HOME>
```

Output file: `$TSUNAGI_HOME/ledger_snapshots/<slot>.snapshot.json`

Schema:
```json
{"slot":12345,"block_no":67890,"utxo_entries":34000,"ledger_digest":"<64hex>"}
```

### digest

Compute and print deterministic digest. No files written.

```
tsunagi-node ledger-harness digest
```

Uses `TSUNAGI_LMDB` or `TSUNAGI_HOME` environment variables.

Output:
```
slot: 12345
block_no: 67890
utxo_entries: 34000
ledger_digest: <64hex>
```

### rewind

Walk the header chain backward N blocks from current tip.

```
tsunagi-node ledger-harness rewind --blocks <N> --home <TSUNAGI_HOME>
```

Writes rewind state to `$TSUNAGI_HOME/ledger_harness/rewind_state.json`.

### replay

Verify chain integrity from rewind point to tip and recompute digest.

```
tsunagi-node ledger-harness replay --home <TSUNAGI_HOME>
```

Reads and cleans up the rewind state file.

### verify

Compare current ledger digest with a saved snapshot.

```
tsunagi-node ledger-harness verify --snapshot <file>
```

Uses `TSUNAGI_LMDB` or `TSUNAGI_HOME` environment variables for LMDB access.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | PASS |
| 2 | FAIL — digest mismatch |
| 3 | Missing file or invalid arguments |
| 4 | Parse/runtime error |

## Workflow

```bash
# 1. Take snapshot at current state
tsunagi-node ledger-harness snapshot --home $TSUNAGI_HOME

# 2. Rewind 20 blocks (header chain walk)
tsunagi-node ledger-harness rewind --blocks 20 --home $TSUNAGI_HOME

# 3. Replay (verify chain integrity + recompute digest)
tsunagi-node ledger-harness replay --home $TSUNAGI_HOME

# 4. Verify digest matches snapshot
tsunagi-node ledger-harness verify --snapshot $TSUNAGI_HOME/ledger_snapshots/<slot>.snapshot.json
```

## Non-Goals

- No forging
- No broadcast
- No chain injection
- No network protocol changes
- No producer logic changes
- No consensus modifications
- No scheduler/VRF/Praos/KES changes
