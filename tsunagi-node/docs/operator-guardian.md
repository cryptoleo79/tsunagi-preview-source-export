# Omotenashi Guardian — Operator CLI (v2.2.1)

## Purpose

Unified operator CLI for common node management tasks. Guardian is
orchestration-only: it queries the running node's HTTP API, invokes
external tools (cardano-cli, Python scripts), and displays bounded
status output. No runtime producer changes. Preview-safe.

## Usage

```
tsunagi-node guardian <subcommand> [options]
```

### Global Options

| Flag | Description |
|------|-------------|
| `--port <N>` | Node HTTP port (default: 9081) |

## Subcommands

### tx-build

Build a transaction via cardano-cli. Preview-only by default.

```
tsunagi-node guardian tx-build \
    --out <path> --from <addr> --to <addr> --ada <amount> \
    [--cardano-cli <path>] [--socket-path <path>] \
    [--i-know-what-im-doing]
```

| Flag | Required | Description |
|------|----------|-------------|
| `--out` | yes | Output tx file path |
| `--from` | yes | Source address (tx-in) |
| `--to` | yes | Destination address |
| `--ada` | yes | Amount in ADA |
| `--cardano-cli` | no | Path to cardano-cli (else `CARDANO_CLI` env, else PATH) |
| `--socket-path` | no | Node socket path (else `CARDANO_NODE_SOCKET_PATH` env; **required**) |
| `--i-know-what-im-doing` | no | Disable preview-only guard |

- Always passes `--testnet-magic 2` (preview) unless `--i-know-what-im-doing`
- Refuses to run without a socket path
- Exit 0 = success, 1 = error

### tx-submit

Submit a signed transaction to the local node.

```
tsunagi-node guardian tx-submit --file <tx-file> [--port <N>] [--debug]
```

| Flag | Required | Description |
|------|----------|-------------|
| `--file` | yes | Signed tx file (raw CBOR or TextEnvelope JSON) |
| `--port` | no | Node port (default: 9081) |
| `--debug` | no | Print full response body |

- Auto-detects TextEnvelope JSON (extracts `cborHex`)
- POSTs binary CBOR to `127.0.0.1:<port>/tx/submit`
- Default output: txid, HTTP status, tx size, result
- Exit 0 = HTTP 2xx, 1 = error

### tx-status

Query mempool for transaction status.

```
tsunagi-node guardian tx-status [--txid <64hex>] [--port <N>]
```

| Flag | Required | Description |
|------|----------|-------------|
| `--txid` | no | Transaction ID to search for |
| `--port` | no | Node port (default: 9081) |

- Without `--txid`: prints mempool summary (items, bytes, top entries)
- With `--txid`: reports whether the tx is found in mempool
- Exit 0 = success, 1 = error

### kes-status

Display KES key period and validity information.

```
tsunagi-node guardian kes-status [--port <N>]
```

- Queries `/state` and extracts `producer_kes_period` and `producer_kes` fields
- Shows: current/start/max periods, remaining periods, validity, slot range
- Exit 0 = success, 1 = error

### proof-latest

Package the latest block candidate proof bundle.

```
tsunagi-node guardian proof-latest [--home <path>] [--verify]
```

| Flag | Required | Description |
|------|----------|-------------|
| `--home` | no | TSUNAGI_HOME path (else `TSUNAGI_HOME` env; **required**) |
| `--verify` | no | Also run block-candidate-verify on latest block dir |

- Runs `scripts/make_block_candidate_proof_bundle.py`
- Exit codes follow the Python script (0=success, 2=no candidate, 3=validation fail)

### doctor

Run diagnostic checks against the running node. PASS/FAIL only.

```
tsunagi-node guardian doctor [--port <N>]
```

**No baseline init/update modes.** Any `--init-baseline` or `--update-baseline` flag
is refused with: `"REFUSED: baseline update is out of scope"`.

| Check | Method | PASS |
|-------|--------|------|
| Node reachable | GET /health | HTTP 200 |
| Tip advancing | /state → tip.slot | > 0 |
| KES keys loaded | /state → producer_keys.kes_ok | == 1 |
| VRF keys loaded | /state → producer_keys.vrf_ok | == 1 |
| KES period valid | /state → producer_kes_period.period_valid_last | == 1 |
| Dryrun enabled | /state → producer_dryrun.enabled | == 1 |
| Clock OK | /state → producer_clock.clock_ok | == 1 |
| Mempool accessible | GET /mempool | HTTP 200 |
| Broadcast flag | /status → broadcast | WARNING if ON |
| Stake fraction | /state → producer_stake.fraction | WARNING if 0 |

- Exit 0 = all checks pass, 1 = any check failed
- Checks 9-10 are warnings (printed as WARNING instead of FAIL) but do not affect exit code

### forge-status

Pre-forging readiness dashboard. Preview-first refusal.

```
tsunagi-node guardian forge-status [--port <N>]
```

- Queries `/status` and `/state` endpoints
- Displays bounded sections: Network, TX Submission, Dryrun, Stake, KES, Latest Proof
- Preview-first: refuses to display if network is not `preview` unless environment indicates otherwise
- Exit 0 = success, 1 = error

### seal-latest

Verify, regress, and optionally bundle the latest block candidate.

```
tsunagi-node guardian seal-latest --home <path> [--make-bundle]
```

| Flag | Required | Description |
|------|----------|-------------|
| `--home` | yes | TSUNAGI_HOME path |
| `--make-bundle` | no | Also run proof bundle script and compute SHA256 |

- Finds the newest directory under `<home>/producer_dryrun/blocks/`
- Runs `block-candidate-verify` in-process (4 checks)
- Runs `block-candidate-regress` in-process if vectors exist at `/tmp/block_candidate_vectors_1.jsonl` or `/tmp/block_candidate_vectors.jsonl`
- With `--make-bundle`: runs `make_block_candidate_proof_bundle.py` and prints SHA256 of resulting zip
- Exit 0 = all checks pass, 1 = any check failed

### airgap-opcert

Print step-by-step opcert rotation ceremony instructions for air-gapped environments.

```
tsunagi-node guardian airgap-opcert [--lang <en|ja>]
```

| Flag | Required | Description |
|------|----------|-------------|
| `--lang` | no | Language: `en` (default) or `ja` |

- Pure instruction output — no network calls, no file modifications
- Covers: BP node stop, key generation on air-gapped machine, cert issuance, file transfer, restart, verification
- Exit 0 always

## forge-arm (v3.0.0)

Arm the forge gate by writing a time-limited arming token after comprehensive
pre-flight checks. Requires `--i-know-what-im-doing` flag.

```
tsunagi-node guardian forge-arm --port 9081 --i-know-what-im-doing [--home <path>]
```

### Pre-flight checks (ALL must pass)

1. Node reachable (HTTP 200)
2. Tip advancing (slot > 0)
3. KES keys loaded
4. VRF keys loaded
5. KES period valid
6. Dryrun enabled
7. Clock OK
8. Mempool accessible
9. Broadcast OFF (TSUNAGI_TXSUB_BROADCAST not set)
10. Network is preview

### Token

- Path: `$TSUNAGI_HOME/guardian/forge_arm.json`
- TTL: 10 minutes (consumed on first use by producer)
- Fields: `armed_at_unix`, `net`, `home`, `nonce`, `safety`

### Exit codes

- 0: token written successfully
- 1: pre-flight check failed or missing flag

## Prerequisites

- Running tsunagi-node with HTTP metrics enabled
- For tx-build: `cardano-cli` installed and a running Cardano node socket
- For proof-latest: Python 3.6+ and `scripts/make_block_candidate_proof_bundle.py`
- For seal-latest: block candidate directories under `TSUNAGI_HOME/producer_dryrun/blocks/`
- For forge-arm: all 4 `TSUNAGI_FORGE_*` env flags set, preview network only

---

## YAMORI Shield (v3.3.0)

Operator-first protective layer: bounded event memory (JSONL), recovery
suggestions (static playbook), and preview-safe systemd drop-ins.
Guardian/tooling only — no consensus, no producer, no runtime changes.

See `docs/yamori.md` for full taxonomy, schema, and playbook.

### yamori status

Read-only node health summary.

```
tsunagi-node guardian yamori status [--port <N>]
```

- Queries `/status`, `/state`, `/mempool`
- Shows: network, tip slot, header stable, txsub enabled, KES valid, broadcast flag, mempool stats
- Exit 0 = success, 1 = error

### yamori record

Append a structured event to JSONL.

```
tsunagi-node guardian yamori record --level <INFO|WARN|CRIT> --subsys <SUBSYS> --code <CODE> [--msg "text"] [--note "text"] [--port <N>] [--home <path>]
```

| Flag | Required | Description |
|------|----------|-------------|
| `--level` | yes | `INFO`, `WARN`, or `CRIT` |
| `--subsys` | yes | `TXSUB\|KES\|VRF\|PRAOS\|LEDGER\|DEPLOY\|FORGE\|HEALTH` |
| `--code` | yes | Event code string |
| `--msg` | no | Free-text message (max 160 chars) |
| `--note` | no | Alternative to --msg |
| `--home` | no | TSUNAGI_HOME path (else `TSUNAGI_HOME` env; required) |
| `--port` | no | Node port (default: 9081) |

- Message must not contain `"` or `\` (rejected, not stripped)
- `\r`, `\n`, `\t` replaced with space
- Appends to `$TSUNAGI_HOME/guardian/yamori_events.jsonl`
- Exit 0 = success, 1 = error

### yamori analyze

Read-only analysis of recent events with playbook suggestions.

```
tsunagi-node guardian yamori analyze --home <path> [--last <N>]
```

| Flag | Required | Description |
|------|----------|-------------|
| `--home` | yes | TSUNAGI_HOME path (else `TSUNAGI_HOME` env) |
| `--last` | no | Number of recent events to analyze (default: 50) |

- Tail-reads event file (pure Zig, no shell)
- Shows: top 5 recurring (subsys, code) counts, last 5 CRIT events, suggested actions from playbook
- Exit 0 = success, 1 = error

### yamori safe-mode apply

Install systemd drop-in to unset forge/broadcast environment variables.

```
tsunagi-node guardian yamori safe-mode apply [--service <unit>] [--home <path>] [--i-know-what-im-doing]
```

| Flag | Required | Description |
|------|----------|-------------|
| `--service` | no | Service unit name (default: `tsunagi-preview.service`) |
| `--home` | no | Accepted but not used for systemd paths |
| `--i-know-what-im-doing` | no | Required for non-preview services |

- Writes `99-yamori-safe.conf` drop-in to `~/.config/systemd/user/<service>.d/`
- Runs `systemctl --user daemon-reload` + `restart`
- Unsets: `TSUNAGI_TXSUB_BROADCAST`, `TSUNAGI_FORGE_ENABLE`, `TSUNAGI_FORGE_PREVIEW_ONLY`, `TSUNAGI_FORGE_NO_BROADCAST`, `TSUNAGI_FORGE_REQUIRE_GUARDIAN_CONFIRM`
- Exit 0 = success, 1 = error

### yamori safe-mode revert

Remove the safe-mode drop-in and restart the service.

```
tsunagi-node guardian yamori safe-mode revert [--service <unit>] [--home <path>] [--i-know-what-im-doing]
```

- Removes `99-yamori-safe.conf` drop-in
- Runs `systemctl --user daemon-reload` + `restart`
- If already reverted (file not found), prints message and exits 0
- Exit 0 = success, 1 = error

---

## KURA (蔵) Retention + Safe Pruning (v3.6.0)

Operator-first disk hygiene for captures, dryrun blocks, proof bundles, forge
sim artifacts, snapshots, regress evidence, and yamori event logs.
Guardian/tooling only — no runtime changes, no consensus, no producer impact.

Safe-by-default: dry-run mode, plan/review/apply workflow, 15-minute plan TTL,
symlink refusal, path-prefix enforcement.

See `docs/kura.md` for retention defaults, safety invariants, and non-goals.

### kura scan

Read-only disk usage scan across all target directories.

```
tsunagi-node guardian kura scan --home <path>
```

- Shows per-target file/dir counts and byte totals
- Includes yamori_events.jsonl
- Warns on symlinks (skipped, not followed)
- Exit 0 = success

### kura plan

Compute deletion candidates and write plan JSON.

```
tsunagi-node guardian kura plan --home <path> [policy flags...]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--keep-captures <N>` | 4 | Captures to keep (also retains last 2 days) |
| `--keep-blocks <N>` | 50 | Dryrun block dirs to keep (protects bundle-referenced + newest 2) |
| `--keep-candidates <N>` | 50 | Candidate dirs to keep |
| `--keep-bundles <N>` | 30 | Proof bundle zips to keep (protects SHA256SUMS + newest 2) |
| `--keep-snapshots <N>` | 5 | Ledger snapshots to keep |
| `--max-forge-dirs <N>` | unlimited | Forge sim dirs to keep |
| `--rotate-yamori-mb <N>` | 1 | Yamori event log rotation threshold (MB) |
| `--prune-gaps` | off | Enable gap file pruning (requires `--i-know-what-im-doing`) |

- Writes `$TSUNAGI_HOME/guardian/kura_plan.json`
- Does NOT delete anything
- Exit 0 = plan written

### kura apply

Execute the plan (actually deletes files).

```
tsunagi-node guardian kura apply --home <path> --apply
```

- Requires `--apply` flag (refuses without it)
- Reads `kura_plan.json` — verifies home matches and plan age < 15 minutes
- Per-candidate safety: refuses `..`, symlinks, paths outside home prefix
- Handles yamori_events.jsonl rotation if plan indicates
- Writes `$TSUNAGI_HOME/guardian/kura_apply.json` report
- Exit 0 = all deleted, 1 = any failures

### kura revert

Remove plan/apply metadata files.

```
tsunagi-node guardian kura revert --home <path>
```

- Deletes `kura_plan.json` and `kura_apply.json`
- Does NOT recover deleted data
- Exit 0 = success

### kura doctor

Read-only health checks on target directories.

```
tsunagi-node guardian kura doctor --home <path>
```

| Check | Result |
|-------|--------|
| Symlinks in target dirs | FAIL if any found |
| Block artifacts (meta.json, verify.json) | WARN if missing |
| SHA256SUMS in bundles | WARN if missing |
| Disk usage | WARN if > 90% |

- Exit 0 = no FAIL checks, 1 = any FAIL

---

## Broadcast Gate (v3.8.0) — Controlled Preview-Only Block Announcement

### Purpose

Validate and prepare locally forged block bytes for operator-controlled relay transfer.
`bcast-push` is an **explicit operator action**, not a hot-loop operation.
**No chain injection** — the local tip is never modified. **No network protocols** — transfer is manual.

### Prerequisites

- v3.0.0 forge gate active (all 4 forge env flags set)
- Preview network only
- `TSUNAGI_TXSUB_BROADCAST` must NOT be set

### Environment Variables

All four must be set to `1` for the broadcast gate to activate:

| Variable | Purpose |
|----------|---------|
| `TSUNAGI_BCAST_ENABLE` | Master enable for broadcast gate |
| `TSUNAGI_BCAST_PREVIEW_ONLY` | Restrict to preview network |
| `TSUNAGI_BCAST_NO_INJECT` | Assert no chain injection |
| `TSUNAGI_BCAST_REQUIRE_GUARDIAN_CONFIRM` | Require guardian arming token |

### Commands

#### bcast-arm

Arm the broadcast gate with pre-flight checks and write a one-time arming token.

```
tsunagi-node guardian bcast-arm --port <N> --home <path> --i-know-what-im-doing
```

**Pre-flight checks (12):**
1. Node reachable
2. Tip advancing
3. KES keys loaded
4. VRF keys loaded
5. KES period valid
6. Dryrun enabled
7. Clock OK
8. TXSUB broadcast OFF
9. Network is preview
10. Forge gate active
11. Fork readiness evidence exists
12. No stale bcast token (warn only)

On success, writes `$TSUNAGI_HOME/guardian/bcast_arm.json` (TTL: 10 minutes).

#### bcast-status

Read-only status display of broadcast gate configuration.

```
tsunagi-node guardian bcast-status --port <N> --home <path>
```

Displays: env flags, arming token status, latest forge artifact, broadcast receipt.

#### bcast-push

Validate forge artifacts and print relay transfer instructions.
Direct N2N block announce is not yet available (requires Ouroboros mini-protocol wiring).

```
tsunagi-node guardian bcast-push --dir <forge_dir> --peer <host:port> --port <N> --home <path> --i-know-what-im-doing
```

**Required flags:** `--dir`, `--peer`, `--i-know-what-im-doing`

**Validation:** preview-only, no TXSUB_BROADCAST, valid arming token (< 10min), block.cbor + block_header_hash.hex + meta.json + broadcast_receipt.json all exist and are valid.

**Output:** Writes `broadcast_receipt.json` with `announced:false, error:"no_direct_transport"`, consumes arming token, prints `scp`/`rsync` commands for manual transfer. Exits nonzero.

### Workflow

```
forge-arm → wait for leader slot → bcast-arm → bcast-push → manual transfer
```

1. `guardian forge-arm --port 9081 --home <home> --i-know-what-im-doing`
2. Wait for leader slot — producer writes forge artifacts + `broadcast_receipt.json` (announced=false)
3. `guardian bcast-arm --port 9081 --home <home> --i-know-what-im-doing`
4. `guardian bcast-push --dir <forge_dir> --peer <relay:port> --port 9081 --home <home> --i-know-what-im-doing`
5. Transfer artifacts to relay using the printed scp/rsync command

### Broadcast Receipt Schema

```json
{
  "mode": "broadcast",
  "announced": false,
  "unix": 1700000000,
  "slot": 12345,
  "block_no": 6789,
  "peers": 0,
  "error": "no_direct_transport",
  "no_inject": true,
  "tip_before": null,
  "tip_after": null
}
```

### Safety Guarantees

- **No injection**: local chain state is never modified
- **No chain state mutation**: producer writes artifacts only, does not update its own tip
- **No network protocols**: bcast-push does not speak Ouroboros mini-protocols
- **Preview-only**: all paths enforce preview network restriction
- **One-time token**: arming token is consumed (deleted) after push
- **Guardian-gated**: requires explicit `--i-know-what-im-doing` confirmation
- **Fail-closed**: any validation failure aborts with non-zero exit and writes failure receipt
