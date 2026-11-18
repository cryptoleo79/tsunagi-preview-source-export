# BAeY Contract Specification

**Behavioral Analysis Engine — Peer Connection Management**

**Version:** 1 (`baey_schema_version: 1`)
**Date:** 2026-02-23
**Status:** Frozen

---

## Safety Boundary

BAeY is strictly a **connection management brain**. It controls peer choice, reconnect timing, probe cadence, and safe-mode markers.

BAeY **MUST NOT** influence:
- Chain selection or fork choice
- Ledger validity or UTXO evaluation
- Header authority correctness
- Any consensus decision

BAeY **MAY** influence:
- Which relay peer is selected for ChainSync
- When to probe an alternate peer
- When to throttle backfill
- When to activate safe mode (marker file only)
- Reconnect timing after failures

---

## 1. State Definition (Per Peer)

Tsunagi maintains a Bayesian peer scoring model for 5 mainnet relay peers.

### Per-Peer Variables

| Variable | Type | Init | Cap | Storage | Description |
|----------|------|------|-----|---------|-------------|
| `alpha[i]` | f64 | 1.0 | 50.0 | RAM | Beta distribution success parameter |
| `beta_val[i]` | f64 | 1.0 | 50.0 | RAM | Beta distribution failure parameter |
| `sample[i]` | f64 | 0.0 | — | RAM | Last Thompson sample |
| `selected[i]` | u64 | 0 | — | RAM | Times selected (cumulative) |
| `peer_cooldown_until[i]` | i64 | 0 | — | RAM | Unix timestamp until cooldown expires (v1.2.2) |
| `last_penalty_unix[i][type]` | i64 | 0 | — | RAM | Per-event-type rate limiter timestamp (v1.2.2) |

### Global Variables

| Variable | Type | Init | Description |
|----------|------|------|-------------|
| `rng` | DefaultPrng | nanoTimestamp seed | Thompson sampling RNG |
| `last_log_unix` | i64 | 0 | Rate limiter for selection logs |
| `last_alpha_reward_unix` | i64 | 0 | Rate limiter for decode rewards |
| `last_perf_nudge_unix` | i64 | 0 | Rate limiter for performance nudges |

### Storage and Restart Behavior

- **Storage:** RAM only. No persistence to disk.
- **Restart:** Cold start. All peers reset to Beta(1, 1) — uniform prior.
- **Implication:** Score history is lost on restart. First selection after restart is purely random (uniform Thompson samples).

### External State (baey-loop policy engine)

The `baey-loop` timer service maintains additional state on disk at `$TSUNAGI_HOME/baey/`:

| File | Purpose | Atomic Write |
|------|---------|-------------|
| `events.log` | JSONL audit trail (append-only) | No (append) |
| `weights.json` | Adaptive policy weights | Yes (.tmp + rename) |
| `loop_stats.json` | Last loop performance | Yes (.tmp + rename) |
| `cooldown.json` | Action cooldowns (probe/switch/throttle/safe) | Yes (.tmp + rename) |
| `switch_peer.json` | Marker: request peer switch | Consumed + deleted |
| `probe_request.json` | Marker: request header probe | Consumed + deleted |
| `backfill_override.json` | Marker: throttle backfill | Expires by timestamp |
| `safe_mode.json` | Marker: activate safe mode | Read on demand |

---

## 2. Update Rules (Event Taxonomy)

### Penalty Events (Increase `beta_val`)

All penalties are rate-limited (v1.2.2): max one penalty of each type per peer per `PENALTY_RATE_WINDOW_S` (10 seconds).

| Event | Increment | Type Code | Hard Fault | Source |
|-------|-----------|-----------|------------|--------|
| TCP connect failed | +1.0 | `connect_fail` | Yes | follower.zig:5210 |
| Handshake failed | +1.0 | `handshake_fail` | Yes | follower.zig:5247 |
| Handshake not accepted | +1.0 | `handshake_fail` | Yes | follower.zig:5260 |
| Keepalive strict (2 consecutive) | +0.2 | `keepalive_timeout` | Yes | follower.zig:5351 |
| Stream read error | +0.2 | `stream_error` | No | follower.zig:5379 |
| Socket closed | +0.2 | `stream_error` | No | follower.zig:5440, 5468 |
| CBOR decode error | +0.02 | `cbor_error` | No | follower.zig:5773, 5783 |
| Rollback flap triggered | +0.5 | `other` | No | follower.zig:6683 |
| Probe integrity fail | +0.5 | `authority_fail` | No | follower.zig:2334 |
| Peer switch penalty | +0.2 | `other` | No | follower.zig:2417, 2559 |
| Density violation (escalating) | +0.2/0.4/0.8 | `density_violation` | No | follower.zig:6519 |
| Max density violation | +0.2 | `density_violation` | No | follower.zig:6531 |
| Performance nudge slow | +0.01 | `other` | No | follower.zig:6065 |
| Header authority fail | +0.5 | `authority_fail` | No | follower.zig:6715, 6758 |
| Convergence regression | +0.2 | `other` | No | follower.zig:6790 |

### Reward Events (Increase `alpha`)

| Event | Increment | Rate Limit | Source |
|-------|-----------|-----------|--------|
| Successful block decode | +0.02 | 60s | follower.zig:6049 |
| Performance nudge fast | +0.005 | 60s | follower.zig:6061 |
| Probe triggered switch | +0.1 | One-time | follower.zig:2418 |
| Stall triggered switch | +0.1 | One-time | follower.zig:2560 |

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `SCORE_CAP` | 50.0 | Maximum alpha or beta value |
| `PENALTY_RATE_WINDOW_S` | 10 | Seconds between same-type penalties per peer |
| `PEER_PENALTY_COOLDOWN_S` | 30 | Seconds peer is in cooldown after hard fault |

---

## 3. Selection Algorithm

### Thompson Sampling (Beta-Bernoulli)

```
For each peer i in [0..4]:
    sample[i] = Beta(alpha[i], beta_val[i])   // Gamma-based sampling

If peer i is in cooldown (peer_cooldown_until[i] > now):
    Mark as cooldown-active but still sample

selected = argmax(sample[i]) among non-cooldown peers
If ALL peers in cooldown:
    selected = argmax(sample[i]) among all peers  // best available
```

### Properties

- **No exploration floor.** A peer with high beta can still win if it samples highest.
- **No epsilon-greedy.** Pure Thompson sampling at all times.
- **No sticky logic.** Every selection re-samples all 5 peers.
- **Cooldown skip (v1.2.2).** Peers in cooldown are skipped unless all are in cooldown.

### Beta Distribution Sampling

Beta(a, b) = X / (X + Y) where X ~ Gamma(a), Y ~ Gamma(b).
Gamma sampling uses Marsaglia-Tsang method with Box-Muller normal inputs.

---

## 4. Failure Modes

### Thrash Risk

**Symptom:** Rapid peer switching back and forth.
**Cause:** Multiple peers accumulating similar penalty scores, Thompson sampling has high variance.
**Mitigation (v1.2.2):**
- Per-peer cooldown (30s) after hard faults prevents immediate reselection
- Per-event rate limiting (10s window) prevents penalty explosion from repeated transient failures
- Chain select cooldown (300s) already limits score-based switches
- Stall switch cooldown (300s) limits stall-triggered switches

### Lock-On Risk

**Symptom:** One peer accumulates high alpha, Thompson sampling always selects it even when degraded.
**Cause:** Alpha grows from continuous successful decode rewards (+0.02 every 60s).
**Mitigation:** SCORE_CAP=50.0 bounds alpha. Beta penalties of +1.0 (connect fail) are 50x the reward rate, ensuring failures override accumulated reward within a few events.

### Bootstrap False Positives

**Symptom:** Penalties applied during initial sync when chain is not yet converged.
**Cause:** Density and authority signals are unreliable during bootstrap.
**Mitigation:** Convergence gate (600s stability window) must latch before authority/density signals drive peer selection.

---

## 5. Metrics Contract (Frozen)

### Prometheus Gauges (MUST NOT rename)

| Metric | Type | Description |
|--------|------|-------------|
| `tsunagi_peer_alpha{index="N"}` | gauge | Bayesian alpha (x1e3) |
| `tsunagi_peer_beta{index="N"}` | gauge | Bayesian beta (x1e3) |
| `tsunagi_peer_score_sample{index="N"}` | gauge | Last Thompson sample (x1e3) |
| `tsunagi_peer_selected_total{index="N"}` | counter | Selection count |
| `tsunagi_peer_perf_reward_total{index="N"}` | counter | Performance reward count |
| `tsunagi_peer_perf_penalty_total{index="N"}` | counter | Performance penalty count |
| `tsunami_baey_events_total` | counter | Audit events written |
| `tsunagi_baey_last_event_unix` | gauge | Last event timestamp |
| `tsunagi_baey_safe_mode_enabled` | gauge | Safe mode active (0/1) |
| `tsunagi_baey_weight_stall` | gauge | Adaptive weight: stall (x1e6) |
| `tsunagi_baey_weight_density` | gauge | Adaptive weight: density (x1e6) |
| `tsunagi_baey_weight_header` | gauge | Adaptive weight: header_err (x1e6) |
| `tsunagi_baey_weight_keepalive` | gauge | Adaptive weight: keepalive (x1e6) |
| `tsunagi_baey_weight_gap` | gauge | Adaptive weight: gap (x1e6) |
| `tsunagi_baey_weight_authority` | gauge | Adaptive weight: authority (x1e6) |
| `tsunagi_baey_weight_finality` | gauge | Adaptive weight: finality (x1e6) |
| `tsunagi_baey_loop_fetch_ms_last` | gauge | Loop fetch latency |
| `tsunagi_baey_loop_total_ms_last` | gauge | Loop total time |
| `tsunagi_baey_loop_parse_ok` | gauge | Loop parse success |
| `tsunagi_baey_switches_total` | counter | Peer switch count (v1.2.2) |
| `tsunagi_baey_penalty_rate_limited_total` | counter | Penalties skipped by rate limiter (v1.2.2) |

### /state JSON (Stable)

```json
{
  "baey_schema_version": 1,
  "baey": {
    "enabled": 1,
    "last_policy_tick_unix": 1771864554,
    "selected_peer_index": 2,
    "cooldown_active": 0,
    "last_switch_reason_code": 1,
    "last_switch_unix": 1771863980
  },
  "baey_policy": { ... }
}
```

---

## 6. Test Harness (baey-regress)

### Command

```bash
tsunagi-node baey-regress --seed <N> [--events <path>] [--init-baseline]
```

### Determinism Invariant

Same seed + same events = same digest. The harness uses synthetic monotonic timestamps and a seeded RNG. No wall-clock time.

### No-Thrash Invariant

Switches per window MUST be bounded unless hard fault events exceed a threshold. Violation = FAIL with "thrash detected".

### Safety Invariant

BAeY decisions never change consensus correctness. This is structurally guaranteed: the regress harness operates only on peer selection, not on chain data.

### Baseline

`$TSUNAGI_HOME/regress/baey_baseline.json` — written by `--init-baseline`, compared on normal runs.

---

## Document History

| Version | Date | Change |
|---------|------|--------|
| 1 | 2026-02-23 | Initial contract freeze (v1.2.2) |
