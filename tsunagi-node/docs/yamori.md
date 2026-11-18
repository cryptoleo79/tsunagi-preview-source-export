# YAMORI Shield (家守) — v3.3.0

## Purpose

Operator-first protective layer for the Guardian CLI. Bounded event memory
(JSONL), recovery suggestions (static playbook), and preview-safe systemd
drop-ins.

**Guardian/tooling only.** No consensus, no producer, no runtime changes.

## Non-Goals

- No BAeY overlap (peer scoring is BAeY's domain)
- No wallet management or key generation
- No remote calls beyond localhost `/status` and `/state`
- No streaming output (tail -f, journalctl follow)
- No baseline init/update modes
- No consensus or producer code changes

## Event Taxonomy

### Subsystems

| Subsystem | Scope |
|-----------|-------|
| `TXSUB` | Transaction submission pipeline |
| `KES` | KES key lifecycle and period validity |
| `VRF` | VRF key operations |
| `PRAOS` | Praos leader election |
| `LEDGER` | Ledger state and validation |
| `DEPLOY` | Binary deployment and service management |
| `FORGE` | Block forging operations |
| `HEALTH` | General node health and reachability |

### Levels

| Level | Meaning |
|-------|---------|
| `INFO` | Informational events, normal operations |
| `WARN` | Conditions that may require attention |
| `CRIT` | Critical conditions requiring immediate action |

### Example Codes

| Code | Subsystem | Level | Description |
|------|-----------|-------|-------------|
| `TXSUB_BROADCAST_ON` | TXSUB | WARN | Broadcast flag is enabled |
| `TXSUB_REJECT_INVALID` | TXSUB | WARN | Invalid tx rejected |
| `KES_PERIOD_INVALID` | KES | CRIT | KES period out of valid range |
| `KES_INVALID_PERIOD` | KES | CRIT | KES period alignment error |
| `DEPLOY_TEXT_FILE_BUSY` | DEPLOY | CRIT | Binary overwrite while in use |
| `FORGE_ARM_TOKEN_EXPIRED` | FORGE | WARN | Guardian forge-arm token expired |
| `FORGE_MISS` | FORGE | CRIT | Missed leader slot |
| `HEALTH_ENDPOINT_FAIL` | HEALTH | WARN | Node HTTP endpoint unreachable |
| `LEDGER_VIOLATION_SPIKE` | LEDGER | WARN | Spike in ledger violations |

## Event JSONL Schema

Events are stored in `$TSUNAGI_HOME/guardian/yamori_events.jsonl`, one JSON
object per line:

```json
{"unix":1709312345,"net":"preview","level":"WARN","subsys":"TXSUB","code":"TXSUB_BROADCAST_ON","msg":"broadcast env detected"}
```

| Field | Type | Description |
|-------|------|-------------|
| `unix` | integer | Unix epoch timestamp |
| `net` | string | Network label (from `/status` or "unknown") |
| `level` | string | `INFO`, `WARN`, or `CRIT` |
| `subsys` | string | Subsystem identifier |
| `code` | string | Event code (uppercase, underscore-separated) |
| `msg` | string | Free-text message (max 160 chars, no `"` or `\`) |

### Message Constraints

- Maximum 160 characters
- `\r`, `\n`, `\t` replaced with space
- `"` and `\` characters are rejected (not stripped)

## Playbook

Static code-to-suggestion mapping used by `yamori analyze`:

| Code | Suggestion |
|------|------------|
| `TXSUB_BROADCAST_ON` | Disable TSUNAGI_TXSUB_BROADCAST; safe-mode apply can enforce this. |
| `DEPLOY_TEXT_FILE_BUSY` | Deploy into versioned dir; never overwrite in-use binaries; use ExecStart override. |
| `FORGE_ARM_TOKEN_EXPIRED` | Re-run guardian forge-arm; token TTL is 10 minutes. |
| `HEALTH_ENDPOINT_FAIL` | Check service active; run guardian doctor; verify port. |
| `KES_PERIOD_INVALID` | Check opcert counter and KES period alignment. |
| `KES_INVALID_PERIOD` | Check opcert counter and KES period alignment. |
| `FORGE_MISS` | Missed leader slot. Check KES validity and clock sync. |
| `LEDGER_VIOLATION_SPIKE` | Check for malformed transactions; review BAeY peer scores. |
| `TXSUB_REJECT_INVALID` | Verify tx CBOR structure; check cardano-cli version. |
| (unknown) | See docs/yamori.md for taxonomy. |

## Safe-Mode

### Philosophy

- Preview-only by default (refuses non-preview services without `--i-know-what-im-doing`)
- Reversible: drop-in file can be removed cleanly
- Environment-unset only: does not add or modify environment variables
- User-scope systemd only (`systemctl --user`)

### Drop-in Content

File: `~/.config/systemd/user/<service>.d/99-yamori-safe.conf`

```ini
[Service]
UnsetEnvironment=TSUNAGI_TXSUB_BROADCAST
UnsetEnvironment=TSUNAGI_FORGE_ENABLE
UnsetEnvironment=TSUNAGI_FORGE_PREVIEW_ONLY
UnsetEnvironment=TSUNAGI_FORGE_NO_BROADCAST
UnsetEnvironment=TSUNAGI_FORGE_REQUIRE_GUARDIAN_CONFIRM
```
