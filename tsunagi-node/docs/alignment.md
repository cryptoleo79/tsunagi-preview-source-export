# Cardano-node Alignment Harnesses

**Version:** 1.3.0
**Date:** 2026-02-24
**Status:** Harness-only (no runtime changes)

---

## Purpose

Tsunagi provides three offline alignment harnesses that quantify differences between Tsunagi's implementations and cardano-node reference values. These harnesses read JSONL vector files and report matches, mismatches, and deltas without modifying any runtime computation.

- **praos-align** quantifies differences between Tsunagi's threshold implementation and cardano-node expected values; it also reports delta vs exact reference formula.
- **vrf-align** compares Tsunagi's VRF output-to-u scalar mapping against expected values.
- **header-align** verifies Blake2b256 hash computation over header bytes in two explicit modes.

---

## Methodology

### Vector Format

All harnesses read JSONL (one JSON object per line). Each line is self-contained.

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | PASS — all vectors match expected values |
| 2 | Mismatch — at least one vector differs from expected |
| 3 | Input error — file missing, parse failure, or invalid arguments |

### Self-Test Mode

When invoked without `--vectors`, praos-align and vrf-align run embedded deterministic self-tests. header-align requires `--candidate-v2` for self-test mode (the `--cardano-header-bytes` mode requires externally generated vectors).

---

## Harness Reference

### praos-align

```bash
tsunagi-node praos-align [--vectors <path.jsonl>]
```

**Vector schema:**
```jsonl
{"stake_fraction_x1e9":500000000,"asc_x1e6":50000,"expected_threshold_x1e12":25000000000}
```

**Three-way comparison per vector:**
1. `tsunagi` — calls existing `computeThreshX1e12()` (unchanged)
2. `expected` — from vector (cardano-node reference value)
3. `reference` — exact Praos formula `T = 1 - (1-f)^σ` computed inside harness only

**Summary line:**
```
PRAOS-ALIGN: vectors=N mismatches=N max_abs_delta=N EXIT=N
```

### vrf-align

```bash
tsunagi-node vrf-align [--vectors <path.jsonl>]
```

**Vector schema (either or both fields):**
```jsonl
{"vrf_output_hex":"<128 hex>","expected_u_x1e12":123456789012}
{"vrf_proof_hex":"<160 hex>","expected_u_x1e12":123456789012}
```

When `vrf_proof_hex` is provided, the harness uses `proofToHash()` (strongest available path) and prints `VERIFY_SKIPPED=1` since full verification requires a public key and message not present in the vector.

**Summary line:**
```
VRF-ALIGN: vectors=N mismatches=N max_abs_delta=N EXIT=N
```

### header-align

```bash
tsunagi-node header-align --candidate-v2 [--vectors <path.jsonl>]
tsunagi-node header-align --cardano-header-bytes [--vectors <path.jsonl>]
```

**Mode selection is required.** The tool makes no cross-system claims — it reports which mode is active and the input assumptions.

**`--candidate-v2`** — Tsunagi's own 198-byte canonical header format:
```jsonl
{"header_bytes_hex":"<396 hex>","expected_hash_hex":"<64 hex>"}
```

**`--cardano-header-bytes`** — Cardano CBOR header bytes (variable length):
```jsonl
{"header_bytes_hex":"<variable hex>","expected_header_hash_hex":"<64 hex>"}
```

**Summary line:**
```
HEADER-ALIGN[mode]: vectors=N mismatches=N max_abs_delta=0 EXIT=N
```

---

## Status

| Harness | What it tests | Status |
|---------|--------------|--------|
| praos-align | Threshold: tsunagi vs expected vs exact reference | Implemented (v1.3.0) |
| vrf-align | VRF output to u scalar mapping | Implemented (v1.3.0) |
| header-align | Blake2b256(header bytes) to hash (two modes) | Implemented (v1.3.0) |

---

## Vector Generation

Generating JSONL vectors from cardano-node is out of scope for v1.3.0. Operators can produce vectors by:

1. **praos-align:** Query cardano-node for stake distribution + active slots coefficient per epoch, compute expected threshold using the exact Praos formula.
2. **vrf-align:** Extract VRF proofs and outputs from cardano-node block headers, compute expected u values.
3. **header-align:** Extract raw header bytes (CBOR) from cardano-node blocks, compute expected Blake2b256 hashes.

---

## Safety

v1.3.0 is strictly harness-only. No runtime computation changes were made. The functions `computeThreshX1e12()`, `vrfOutputToU_x1e12()`, VRF prove/verify, and the scheduler are unchanged.

---

## v1.4.0 Alignment Proof Results

v1.4.0 packages real alignment evidence produced by running the v1.3.0 harnesses against vectors captured from mainnet block data via `capture_vectors.py` (v1.3.1) and the alignment suite runner (v1.3.2).

### Vector Counts

| Harness | Vectors | Status |
|---------|---------|--------|
| header-align (cardano-header-bytes) | 120 | PASS (0 mismatches) |
| vrf-align | 120 | PASS (0 mismatches) |
| praos-align | 6 | SKIPPED (expected_threshold_x1e12 = null) |

### What Is Proven

- **Header hashing equivalence:** Tsunagi's Blake2b256 computation over Cardano CBOR header bytes produces identical hashes for all 120 mainnet block headers tested. Zero mismatches.
- **VRF-to-u mapping equivalence:** Tsunagi's `vrfOutputToU_x1e12()` produces identical u scalars for all 120 mainnet VRF outputs tested. Zero mismatches.

### What Is Measured (Not Yet Aligned)

- **Praos threshold delta:** The praos-align harness is implemented and functional, but the captured vectors contain `expected_threshold_x1e12 = null` because computing reference threshold values requires querying cardano-node's ledger state for per-pool stake fractions. The harness was skipped in this run. When reference values become available, praos-align will quantify the delta between Tsunagi's linear approximation and the exact Praos formula.

### Reproduction

```bash
# 1. Capture vectors from mainnet block data
export TSUNAGI_HOME=~/tsunagi-home-mainnet
python3 scripts/capture_vectors.py \
  --out $TSUNAGI_HOME/regress/alignment \
  --count 120

# 2. Run the alignment suite
python3 scripts/run_alignment_suite.py --home $TSUNAGI_HOME

# 3. Package proof bundle
python3 scripts/make_proof_bundle.py --home $TSUNAGI_HOME
```

The proof bundle (zip) contains `metadata.json`, `results.json`, `summary.md`, and `command_log.txt`. These are operator-specific runtime artifacts and are not committed to the repository.
