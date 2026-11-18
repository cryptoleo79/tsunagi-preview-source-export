# Fork Readiness Proof

**Version:** 1.6.0

---

## What Is Being Proven

Tsunagi demonstrates correct chain-following behavior across multiple Cardano networks
by validating:

1. **Header hash alignment** — Zig-native Blake2b-256 header hashing matches Cardano
   reference values extracted from live chain captures.

2. **VRF proof alignment** — Verifiable Random Function output computation matches
   reference proofs from live blocks.

3. **Offline regression determinism** — Schedule computation, KES period gating,
   Praos leader checks, producer candidate building, and BAeY peer selection all
   produce bit-identical results across builds.

4. **Runtime health** — Live nodes on each network report correct state schema,
   producer state digest, and Praos/KES metrics via the `/state` endpoint.

---

## Networks Tested

| Network | Magic | Metrics Port | Alignment Vectors |
|---------|-------|-------------|-------------------|
| mainnet | 764824073 | 9080 | 260+ header, 260+ VRF |
| preview | 2 | 9081 | 100+ header, 100+ VRF |
| sancho  | 4 | 9082 | 100+ header, 100+ VRF |

All three networks run concurrently on the same host with strict state isolation
(separate TSUNAGI_HOME directories).

---

## Alignment Methodology

Alignment vectors are extracted from live capture segments using
`scripts/auto_capture_vectors.py`. Each vector contains a block's raw header bytes
and the expected cryptographic output.

The Zig-native harnesses (`header-align`, `vrf-align`) process these vectors and
compare computed results against reference values. Zero mismatches are required for
a PASS.

Vectors accumulate over time via nightly systemd timers. The minimum threshold for
fork readiness is 100 vectors per harness per network.

---

## Rollback Stabilization

Since v1.5.9, Tsunagi includes a rollback stabilization window (60 seconds) that
suppresses header mismatch penalties and chain-select switching immediately after
rollbacks. This reduces false peer churn caused by normal Cardano rollback behavior.

Single rollbacks (count <= 1 in a 10-minute window) do not penalize peer scoring.
This reflects the reality that rollbacks are routine events on all Cardano networks.

These are control-flow guards only. No consensus math is modified.

---

## How to Reproduce

### Fork Readiness Check

Run per network:

```bash
python3 scripts/fork_readiness_check.py \
  --home ~/tsunagi-home-mainnet --net mainnet \
  --bin ~/.local/tsunagi/current/bin/tsunagi-node \
  --state-url http://127.0.0.1:9080/state \
  --metrics-url http://127.0.0.1:9080/metrics

python3 scripts/fork_readiness_check.py \
  --home ~/tsunagi-home-preview --net preview \
  --bin ~/.local/tsunagi/current/bin/tsunagi-node \
  --state-url http://127.0.0.1:9081/state \
  --metrics-url http://127.0.0.1:9081/metrics

python3 scripts/fork_readiness_check.py \
  --home ~/tsunagi-home-sancho --net sancho \
  --bin ~/.local/tsunagi/current/bin/tsunagi-node \
  --state-url http://127.0.0.1:9082/state \
  --metrics-url http://127.0.0.1:9082/metrics
```

### Alignment Suite

```bash
python3 scripts/run_alignment_suite.py --home ~/tsunagi-home-mainnet
python3 scripts/run_alignment_suite.py --home ~/tsunagi-home-preview
python3 scripts/run_alignment_suite.py --home ~/tsunagi-home-sancho
```

### Build Proof Bundle

```bash
python3 scripts/build_v160_proof_release.py
```

This generates `tsunagi-fork-proof-v1.6.0.zip` containing evidence from all networks.

---

## What Is NOT Included

- No block forging or block production
- No transaction broadcast or mempool injection
- No implicit signing of any kind
- No consensus algorithm modifications
- No protocol parameter changes

This is a verification harness. It proves that Tsunagi correctly follows and validates
the chain. It does not create, modify, or broadcast any on-chain data.
