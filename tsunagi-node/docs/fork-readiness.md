# Fork Readiness Checklist

Tsunagi includes a daily-runnable fork-readiness checker that produces timestamped
evidence bundles. These bundles demonstrate that alignment proofs, offline regressions,
and runtime health remain stable through network upgrades and hard forks.

The checker is a Python 3 script with no external dependencies.

---

## Bootstrapping a New Network Home

Before running fork-readiness checks on a new network, initialize the TSUNAGI_HOME
with regression baselines and alignment vectors:

```bash
python3 scripts/bootstrap_network_home.py \
  --home ~/tsunagi-home-preview \
  --net preview \
  --count 120
```

The bootstrap script:

1. Creates required directories (`regress/`, `regress/alignment/`, etc.)
2. Initializes regression baselines (`praos-regress --init-baseline`, etc.)
3. Captures alignment vectors from block captures (if available)
4. Runs the alignment suite against captured vectors

If no block captures exist yet (new node that hasn't run), baselines are still
created and the fork-readiness checker will report **WARN** instead of FAIL.
After the node runs and captures blocks, re-run the bootstrap to capture vectors.

### Bootstrap Examples

```bash
# Preview
python3 scripts/bootstrap_network_home.py --home ~/tsunagi-home-preview --net preview

# Sancho
python3 scripts/bootstrap_network_home.py --home ~/tsunagi-home-sancho --net sancho

# Mainnet (vectors from existing captures)
python3 scripts/bootstrap_network_home.py --home ~/tsunagi-home-mainnet --net mainnet --count 120
```

---

## Quick Start

```bash
python3 scripts/fork_readiness_check.py \
  --home ~/tsunagi-home-preview \
  --net preview \
  --bin ./zig-out/bin/tsunagi-node \
  --state-url http://127.0.0.1:9080/state \
  --metrics-url http://127.0.0.1:9080/metrics
```

## Per-Network Examples

### Preview

```bash
python3 scripts/fork_readiness_check.py \
  --home ~/tsunagi-home-preview \
  --net preview \
  --bin ~/.local/tsunagi/current/bin/tsunagi-node \
  --state-url http://127.0.0.1:9080/state \
  --metrics-url http://127.0.0.1:9080/metrics
```

### Sancho (SanchoNet)

```bash
python3 scripts/fork_readiness_check.py \
  --home ~/tsunagi-home-sancho \
  --net sancho \
  --bin ~/.local/tsunagi/current/bin/tsunagi-node \
  --state-url http://127.0.0.1:9080/state \
  --metrics-url http://127.0.0.1:9080/metrics
```

### Mainnet

```bash
python3 scripts/fork_readiness_check.py \
  --home ~/tsunagi-home-mainnet \
  --net mainnet \
  --bin ~/.local/tsunagi/current/bin/tsunagi-node \
  --state-url http://127.0.0.1:9080/state \
  --metrics-url http://127.0.0.1:9080/metrics
```

### Offline Only (No Running Node)

```bash
python3 scripts/fork_readiness_check.py \
  --home ~/tsunagi-home-mainnet \
  --net mainnet \
  --bin ./zig-out/bin/tsunagi-node
```

---

## CLI Reference

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--home` | yes | — | TSUNAGI_HOME directory |
| `--net` | yes | — | Network name: mainnet, preprod, preview, sancho |
| `--bin` | no | `~/.local/tsunagi/current/bin/tsunagi-node` | Path to tsunagi-node binary |
| `--state-url` | no | — | URL for /state probe |
| `--metrics-url` | no | — | URL for /metrics probe |
| `--min-header` | no | 100 | Minimum header alignment vectors required |
| `--min-vrf` | no | 100 | Minimum VRF alignment vectors required |

---

## Output

Evidence is written to:

```
$TSUNAGI_HOME/regress/fork_readiness/<YYYYMMDDTHHMMSSZ>/
  results.json       # machine-readable results
  summary.md         # human-readable report
  command_log.txt    # raw command outputs
  state.json         # /state snapshot (if --state-url provided)
  metrics.txt        # /metrics snapshot (if --metrics-url provided)
```

### Overall Status Rules

| Overall | Condition |
|---------|-----------|
| **PASS** | All offline regressions pass AND alignment vectors sufficient and passing |
| **WARN** | Executed regressions pass but baselines missing, alignment vectors insufficient, or runtime probe missing |
| **FAIL** | Any executed regression fails (true mismatch) or alignment fails with sufficient vectors |

**Note:** Missing baselines (`SKIP_NO_BASELINE`) cause WARN, not FAIL.
Run `bootstrap_network_home.py` to initialize baselines.

---

## Checklist Steps

### A) Environment Validation

- Verifies TSUNAGI_HOME exists
- Verifies tsunagi-node binary exists and is executable
- Detects version (via `--version` or git tag)

### B) Offline Regressions

Runs these commands with `TSUNAGI_HOME` set:

1. `schedule-regress`
2. `kes-selftest`
3. `praos-regress`
4. `producer-regress`
5. `baey-regress`

Any failure causes overall FAIL.

### C) Alignment Suite

Runs against vectors in `$TSUNAGI_HOME/regress/alignment/`:

1. `header-align --cardano-header-bytes` (requires `header_hash.jsonl`)
2. `vrf-align` (requires `vrf_u.jsonl`)

If vectors are missing or below `--min-header`/`--min-vrf` thresholds,
status is INSUFFICIENT_VECTORS (overall WARN, not FAIL).

### D) Runtime Health Probe (Optional)

If `--state-url` is provided:
- Fetches /state JSON
- Checks for required keys: `state_schema_version`, `producer_state_digest`,
  `producer_praos`, `producer_kes_period`
- Records tip slot and producer state digest

If `--metrics-url` is provided:
- Fetches Prometheus metrics
- Counts lines matching required prefixes:
  `tsunagi_state_schema_version`, `tsunagi_peer_alpha`,
  `tsunagi_producer_schedule_`, `tsunagi_praos_`, `tsunagi_kes_`

---

## Suggested Schedule

| Network | Frequency | Notes |
|---------|-----------|-------|
| preview | daily | First to see hard fork changes |
| sancho | daily | SanchoNet governance fork testing |
| mainnet | weekly | Stable baseline; increase to daily before known forks |
| preprod | weekly | Pre-production validation |

Use `scripts/fork_readiness_cron.sh` or systemd timers (recommended) to automate.

---

## Systemd Timer Setup

Systemd user timers provide hands-off daily/weekly fork readiness checks with
journal logging and persistent scheduling (catches up after downtime).

### Install

Copy the unit files into your user systemd directory:

```bash
mkdir -p ~/.config/systemd/user

# Preview (daily, port 9081)
cp docs/systemd/tsunagi-fork-readiness-preview.service ~/.config/systemd/user/
cp docs/systemd/tsunagi-fork-readiness-preview.timer ~/.config/systemd/user/

# Sancho (daily, port 9082)
cp docs/systemd/tsunagi-fork-readiness-sancho.service ~/.config/systemd/user/
cp docs/systemd/tsunagi-fork-readiness-sancho.timer ~/.config/systemd/user/

# Mainnet (weekly, port 9080)
cp docs/systemd/tsunagi-fork-readiness-mainnet.service ~/.config/systemd/user/
cp docs/systemd/tsunagi-fork-readiness-mainnet.timer ~/.config/systemd/user/
```

### Enable

```bash
systemctl --user daemon-reload

systemctl --user enable --now tsunagi-fork-readiness-preview.timer
systemctl --user enable --now tsunagi-fork-readiness-sancho.timer
systemctl --user enable --now tsunagi-fork-readiness-mainnet.timer
```

### Verify

```bash
# List active timers
systemctl --user list-timers | grep tsunagi-fork-readiness

# Run one manually
systemctl --user start tsunagi-fork-readiness-preview.service

# Check logs
journalctl --user -u tsunagi-fork-readiness-preview.service --no-pager -n 30

# Check evidence
ls ~/tsunagi-home-preview/regress/fork_readiness/
```

### Port Assignments

Each readiness service probes its network's metrics endpoint:

| Network | Metrics Port | Schedule |
|---------|-------------|----------|
| mainnet | 9080 | weekly |
| preview | 9081 | daily |
| sancho | 9082 | daily |

To change mainnet to daily before a known fork, edit the timer:

```bash
systemctl --user edit tsunagi-fork-readiness-mainnet.timer
# Change OnCalendar=weekly to OnCalendar=daily
systemctl --user daemon-reload
```

---

## What to Watch

**Before a hard fork:**
- Handshake failures (connection refused, magic mismatch)
- Rollback flaps (frequent RollBackward events)
- CBOR guard violations (new block format not recognized)
- Digest instability (producer_state_digest changing unexpectedly)
- Alignment regression (header-align or vrf-align failures)

**After a hard fork:**
- All offline regressions should still pass (deterministic, era-independent)
- Alignment vectors from the new era should be captured and verified
- Runtime probe should show stable tip advancement

---

## How to Share Proof

Attach `summary.md` and `results.json` from the evidence bundle. These files
contain only operational metrics and test results.

**Never share:**
- Private keys or signing keys
- Full LMDB databases
- Node credentials or peer secrets

The evidence bundle is designed to be safe to share publicly.

---

## Cron Wrapper

A convenience wrapper is provided at `scripts/fork_readiness_cron.sh`:

```bash
# Run for preview and sancho (daily)
./scripts/fork_readiness_cron.sh
```

Customize the networks and paths inside the script as needed.
