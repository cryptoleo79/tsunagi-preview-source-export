# cold-start — Deterministic TSF Import + Ledger Digest

## Purpose

Import a TSF snapshot into a fresh LMDB directory and compute the KIZUNA
ledger digest. Designed for offline, deterministic cold-start verification.

Same inputs always produce the same ledger digest.

## Non-Goals

- No forging, no broadcast, no chain injection, no gossip
- No runtime changes
- No baseline edits
- Does not re-implement digest logic — reuses existing CLI commands as subprocesses

## Usage

```
tsunagi-node cold-start \
    --snapshot <path/to/snapshot.tsf> \
    --out-lmdb <dir> \
    [--verify-digest <hex64>] \
    [--strict] \
    [--out <path>]
```

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--snapshot <path>` | (required) | Path to TSF snapshot file |
| `--out-lmdb <dir>` | (required) | Output LMDB directory |
| `--verify-digest <hex64>` | (none) | Expected ledger digest (64 hex chars) |
| `--strict` | off | Require out-lmdb to be empty or nonexistent |
| `--out <path>` | (none) | Write JSON report to file |

## How It Works

1. Open snapshot, read TSF header, validate magic == `TSF2`
2. If `--strict`: verify out-lmdb is empty or does not exist
3. Subprocess: `snapshot-import --file <snap> --lmdb <out-lmdb> --strict --allow-unsigned`
4. Subprocess: `ledger-harness digest` with env `TSUNAGI_LMDB=<out-lmdb>`
5. Parse stderr output for `ledger_digest:` and `utxo_entries:`
6. If `--verify-digest`: compare computed digest against expected
7. Print results to stdout, optionally write JSON report

The digest computation uses the existing `ledger-harness digest` code path
(canonical sorted Blake2b-256 over UTxO entries). Cannot drift from the
production digest implementation.

## Stdout Output

```
out_lmdb=/path/to/lmdb
slot=123456
block_no=12345
utxo_entries=662403
ledger_digest_hex=b8eb99a7d7585b0cc25b1bc53323909491ba99def741a220669b7b878fd0ed02
EXIT=0
```

## JSON Report (--out)

```json
{"out_lmdb":"/path/to/lmdb","slot":123456,"block_no":12345,"utxo_entries":662403,"ledger_digest_hex":"b8eb99a7..."}
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Import + digest succeeded |
| 2 | Digest mismatch (--verify-digest) |
| 3 | Argument or strict-mode error |
| 4 | IO, parse, or subprocess error |

## Strict Mode

With `--strict`, the out-lmdb directory must be empty or nonexistent. This
prevents accidental overwrite of existing LMDB data and ensures the digest
is computed from a clean import.

## Integration with evidence-pack

The `evidence-pack --cold-start` mode runs `cold-start` twice as a subprocess
with independent temp LMDB directories, compares the resulting digests, and
produces a publishable evidence envelope proving determinism.

See [evidence-pack.md](evidence-pack.md) for details.
