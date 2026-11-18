# v1.4.0 — Alignment Proof Milestone (Header + VRF Equivalence)

**Date:** 2026-02-24
**Status:** Release

---

## What Is Proven

Tsunagi v1.4.0 ships with reproducible evidence that two core computations produce identical results to cardano-node for all tested mainnet blocks:

- **Header hashing:** Blake2b256 over Cardano CBOR header bytes. 120 mainnet block headers tested. Zero mismatches.
- **VRF-to-u mapping:** Conversion of 64-byte VRF output to a u scalar in [1, 1e12]. 120 mainnet VRF outputs tested. Zero mismatches.

Evidence is produced by offline harnesses reading JSONL vectors captured from real mainnet block data. The harnesses are deterministic and require no network access.

## What Is Measured (Praos Delta)

The Praos threshold harness (`praos-align`) is implemented and functional. It performs a three-way comparison:

1. **tsunagi** — existing `computeThreshX1e12()` (linear approximation)
2. **expected** — cardano-node reference value from vector
3. **reference** — exact formula `T = 1 - (1-f)^σ` computed inside the harness

In this release, the praos vectors contain `expected_threshold_x1e12 = null` because computing reference values requires querying cardano-node's ledger state for per-pool stake fractions. The harness reports `SKIPPED_EXPECTED_NULL`. When reference values are provided, the harness will quantify the exact delta.

## What Is Not Yet Changed

v1.4.0 makes no changes to runtime computation. The following functions are unchanged:

- `computeThreshX1e12()` — Praos threshold
- `vrfOutputToU_x1e12()` — VRF output to u scalar
- VRF prove/verify — libsodium IETF draft-03
- Block production scheduler
- Follower chain sync

All changes in v1.3.0–v1.4.0 are harness code, scripts, and documentation.

## Reproduction

```bash
# Prerequisites: tsunagi-node built, TSUNAGI_HOME with captures
export TSUNAGI_HOME=~/tsunagi-home-mainnet

# 1. Capture 120+ vectors from mainnet block data
python3 scripts/capture_vectors.py \
  --out $TSUNAGI_HOME/regress/alignment \
  --count 120

# 2. Run alignment suite (header + VRF + praos)
python3 scripts/run_alignment_suite.py --home $TSUNAGI_HOME

# 3. Package proof bundle
python3 scripts/make_proof_bundle.py --home $TSUNAGI_HOME

# Output: tsunagi-alignment-proof-v1.4.0.zip
```

The proof bundle zip contains:

| File | Content |
|------|---------|
| `metadata.json` | Bundle version, git tag, timestamps, per-harness status |
| `results.json` | Machine-readable suite results |
| `summary.md` | Human-readable summary table |
| `command_log.txt` | Full stdout/stderr from each harness invocation |

## Security Posture

- No private keys are included in any artifact
- No signing, forging, or broadcast capability
- Harnesses are offline-only and read-only against vector files
- Proof bundles contain only hashes, scalars, and metadata
- All scripts use Python stdlib only (no third-party dependencies)

## Release Assets

| Asset | Description |
|-------|-------------|
| `tsunagi-node-v1.4.0-linux-amd64.tar.gz` | Linux amd64 binary (ReleaseSafe) |
| `SHA256SUMS` | Checksums for all assets |
| `tsunagi-alignment-proof-v1.4.0.zip` | Alignment proof bundle |
