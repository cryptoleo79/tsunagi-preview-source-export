# KURA (蔵) — Retention + Safe Pruning

## Purpose

Prevent disk bloat from operational artifacts without risking data integrity.
KURA is a guardian-only, offline, filesystem-only tool with a plan/review/apply
workflow. It never touches consensus state, never runs during production, and
never modifies runtime behavior.

## Safety Invariants

1. **Never touch protected paths**: `lmdb/`, `genesis/`, `keys/`, `utxo.snapshot`
2. **Never follow symlinks**: symlinks are skipped and warned about
3. **Never operate outside `--home` prefix**: every candidate path is verified
4. **No `..` in paths**: any path component containing `..` is refused
5. **Plan TTL**: apply refuses plans older than 15 minutes
6. **Explicit confirmation**: apply requires `--apply` flag
7. **Dry-run by default**: plan only writes metadata, never deletes

## Target Directories

| Target | Rel Path | Type | Default Keep |
|--------|----------|------|-------------|
| captures | `captures/` | files | 4 (+ last 2 days) |
| blocks | `producer_dryrun/blocks/` | dirs | 50 (+ bundle-referenced + newest 2) |
| candidates | `producer_dryrun/candidates/` | dirs | 50 |
| bundles | `producer_dryrun/blocks_proof_bundles/` | files (.zip) | 30 (+ SHA256SUMS + newest 2) |
| forge_sim | `producer_forge_sim/` | dirs | unlimited |
| snapshots | `ledger_snapshots/` | files | 5 |
| gaps | `gaps/` | files | skip (requires --prune-gaps) |
| harness | `ledger_harness/` | files | N/A (scanned only) |
| fork_readiness | `regress/fork_readiness/` | dirs | 50 |
| yamori_events | `guardian/yamori_events.jsonl` | single file | rotate at 1MB |

## Policy Override Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--keep-captures <N>` | 4 | Number of capture files to retain |
| `--keep-blocks <N>` | 50 | Number of dryrun block dirs to retain |
| `--keep-candidates <N>` | 50 | Number of candidate dirs to retain |
| `--keep-bundles <N>` | 30 | Number of proof bundle zips to retain |
| `--keep-snapshots <N>` | 5 | Number of ledger snapshots to retain |
| `--max-forge-dirs <N>` | 999999 | Max forge sim dirs (unlimited by default) |
| `--rotate-yamori-mb <N>` | 1 | Yamori log rotation threshold in MB |
| `--prune-gaps` | off | Enable gap file pruning |
| `--i-know-what-im-doing` | off | Required for --prune-gaps |
| `--apply` | off | Required for apply subcommand |

## Workflow

```
# 1. Survey current disk usage
tsunagi-node guardian kura scan --home ~/tsunagi-home-preview

# 2. Compute deletion plan (writes JSON, deletes nothing)
tsunagi-node guardian kura plan --home ~/tsunagi-home-preview

# 3. Review the plan
cat ~/tsunagi-home-preview/guardian/kura_plan.json | python3 -m json.tool

# 4. Execute (must be within 15 minutes of plan)
tsunagi-node guardian kura apply --home ~/tsunagi-home-preview --apply

# 5. Verify
tsunagi-node guardian kura scan --home ~/tsunagi-home-preview

# 6. Health check
tsunagi-node guardian kura doctor --home ~/tsunagi-home-preview
```

## Captures Retention Logic

Captures use a dual-criteria keep policy: the keep set is the **union** of:
- Last N files by count (sorted by name, which embeds timestamps)
- Files modified within the last 2 days

The newest file is always protected. This ensures both count-based and
time-based safety.

## Blocks Protection Logic

Block directories have extra protection:
- Newest 2 directories are always kept
- Directories referenced by proof bundles (matched by filename prefix) are kept
- Remaining directories are kept up to the configured limit

## Plan/Apply JSON Schema

### kura_plan.json
```json
{
  "unix": 1709337600,
  "home": "/path/to/home",
  "policy": { "keep_captures": 4, "keep_blocks": 50, ... },
  "candidates": ["captures/old_file.bin", "producer_dryrun/blocks/123_456", ...],
  "candidate_count": 12,
  "bytes_to_free": 15728640,
  "yamori_rotate": false
}
```

### kura_apply.json
```json
{
  "unix": 1709337700,
  "deleted": 12,
  "bytes_freed": 15728640,
  "failures": []
}
```

## Non-Goals

- **Not a backup tool**: KURA deletes; it does not archive or copy
- **No consensus impact**: never touches lmdb, genesis, keys, or UTXO state
- **No network operations**: purely offline, filesystem-only
- **No automatic scheduling**: operator must invoke manually or via cron
- **No cross-node coordination**: operates on a single home directory
- **No runtime integration**: guardian CLI only, never called by the node process
