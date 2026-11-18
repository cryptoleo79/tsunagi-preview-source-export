# Alignment Vector Capture Pipeline

**Version:** 1.3.1
**Date:** 2026-02-24
**Status:** Data pipeline (no runtime changes)

---

## Overview

v1.3.1 provides a reproducible pipeline to capture real reference vectors from Cardano block data. These vectors feed the alignment harnesses shipped in v1.3.0 (`praos-align`, `vrf-align`, `header-align`).

Vectors are runtime data stored under `$TSUNAGI_HOME/regress/alignment/`. They are NOT committed to the repository.

**v1.3.1 is a data pipeline. Proof of correctness requires real reference vectors.**

---

## Quick Start

### 1. Capture Vectors

```bash
export TSUNAGI_HOME=~/tsunagi-home-mainnet

python3 scripts/capture_vectors.py \
  --out $TSUNAGI_HOME/regress/alignment \
  --count 50
```

The script reads block capture files from `$TSUNAGI_HOME/captures/` and produces three JSONL files.

### 2. Run Harnesses

```bash
cd tsunagi-node

# Header hash alignment (highest confidence)
./zig-out/bin/tsunagi-node header-align \
  --cardano-header-bytes \
  --vectors $TSUNAGI_HOME/regress/alignment/header_hash.jsonl

# VRF u-mapping alignment
./zig-out/bin/tsunagi-node vrf-align \
  --vectors $TSUNAGI_HOME/regress/alignment/vrf_u.jsonl

# Praos threshold alignment (requires completed vectors; see below)
./zig-out/bin/tsunagi-node praos-align \
  --vectors $TSUNAGI_HOME/regress/alignment/praos_threshold.jsonl
```

---

## Script Reference

```
scripts/capture_vectors.py

  --capture-dir <path>   Tsunagi captures directory
                         (default: $TSUNAGI_HOME/captures/)
  --out <dir>            Output directory (required)
  --count <N>            Max vectors per file (default: 50)
  --mode <net>           mainnet|preprod|preview|sancho (default: mainnet)
  --node-socket <path>   cardano-node socket (optional; future use)
```

### Input: Tsunagi Capture Files

The script reads binary capture files (`*.bin`) in the format produced by Tsunagi's block capture system: `[u32-LE length][CBOR block payload]` repeated.

These files are rotated automatically and stored in `$TSUNAGI_HOME/captures/`.

### Output Files

| File | Content | Status |
|------|---------|--------|
| `header_hash.jsonl` | Header CBOR bytes + blake2b256 hash | Complete |
| `vrf_u.jsonl` | VRF output/proof + u scalar mapping | Complete |
| `praos_threshold.jsonl` | Stake/ASC params + threshold | Skeleton (expected=null) |

---

## JSONL Schemas

### header_hash.jsonl

```json
{
  "kind": "header_hash",
  "mode": "cardano-header-bytes",
  "header_bytes_hex": "<variable-length hex>",
  "expected_header_hash_hex": "<64 hex chars>",
  "note": "slot=N block=N era=N net=mainnet"
}
```

- `header_bytes_hex`: Raw CBOR encoding of the Cardano block header (header_body + signature)
- `expected_header_hash_hex`: blake2b256 of the header bytes, computed by the capture script
- Consumed by: `tsunagi-node header-align --cardano-header-bytes --vectors <path>`

### vrf_u.jsonl

```json
{
  "kind": "vrf_u",
  "vrf_output_hex": "<128 hex chars>",
  "vrf_proof_hex": "<160 hex chars>",
  "expected_u_x1e12": 123456789012,
  "note": "slot=N block=N era=N net=mainnet"
}
```

- `vrf_output_hex`: 64-byte VRF output from header VRF cert
- `vrf_proof_hex`: 80-byte VRF proof (when available)
- `expected_u_x1e12`: Computed using integer formula: `max(1, (r * 1e12) // (2^64 - 1))` where `r` = first 8 bytes big-endian. This is the same formula used by Tsunagi; for cross-system alignment, cardano-node reference values are needed.
- Consumed by: `tsunagi-node vrf-align --vectors <path>`

### praos_threshold.jsonl

```json
{
  "kind": "praos_threshold",
  "stake_fraction_x1e9": 500000000,
  "asc_x1e6": 50000,
  "expected_threshold_x1e12": null,
  "note": "sigma=50% net=mainnet ..."
}
```

- `stake_fraction_x1e9`: Stake fraction scaled by 1e9 (500000000 = 50%)
- `asc_x1e6`: Active slots coefficient scaled by 1e6 (50000 = 0.05, mainnet default)
- `expected_threshold_x1e12`: **null** in skeleton vectors. Requires cardano-node reference.
- Consumed by: `tsunagi-node praos-align --vectors <path>`

---

## Capture Gaps

### Praos Threshold: expected_threshold_x1e12

The capture script generates skeleton vectors with known mainnet ASC (0.05) and sample stake fractions, but `expected_threshold_x1e12` is left null because:

1. The exact Praos formula `T = 1 - (1-f)^σ` is computed using rational arithmetic in cardano-node (Haskell)
2. Python float approximation may differ at the integer level
3. Real stake fractions require ledger state queries not available offline

**To complete these vectors:**
- Query cardano-node for per-pool stake fractions via `cardano-cli query stake-distribution`
- Compute expected threshold using cardano-node's own calculation (trace logs or a Haskell reference program)
- Or use the `praos-align` harness, which internally computes a reference value using the exact formula (f64 precision)

### VRF u-mapping: Cross-System Alignment

The `expected_u_x1e12` values in `vrf_u.jsonl` are computed using the same integer formula as Tsunagi. This verifies the Zig implementation matches the Python reference. For true cross-system alignment against cardano-node's VRF-to-natural mapping, reference values from cardano-node traces are needed.

---

## Recommended Sample Sizes

| Harness | Minimum | Recommended |
|---------|---------|-------------|
| header-align | 20 | 100-200 |
| vrf-align | 20 | 50-100 |
| praos-align | 6 | 20-50 (when expected values available) |

---

## Troubleshooting

### No .bin files found
Ensure `TSUNAGI_HOME` is set and the node has been running with capture enabled (`TSUNAGI_CAPTURE=1`).

### VRF vectors empty
VRF cert extraction requires Babbage/Conway era blocks (10-item header body). Older era blocks are skipped.

### praos-align fails with parse error
Skeleton vectors have `expected_threshold_x1e12: null`. The praos-align harness expects an integer. Complete the vectors with real reference values before running.

### Capture files too old
The script reads newest files first. Ensure recent captures exist. The node rotates capture files based on `TSUNAGI_CAPTURE_ROTATE_MB`.

---

## Alignment Suite Runner (v1.3.2)

The alignment suite runner automates running all harnesses and produces reproducible evidence artifacts.

### Run the Suite

```bash
# 1. Capture vectors (100+ recommended)
python3 scripts/capture_vectors.py \
  --out $TSUNAGI_HOME/regress/alignment \
  --count 120

# 2. Run suite
python3 scripts/run_alignment_suite.py --home $TSUNAGI_HOME
```

### Suite Options

```
scripts/run_alignment_suite.py

  --home <path>        TSUNAGI_HOME (default: $TSUNAGI_HOME)
  --bin <path>         tsunagi-node binary path
  --min-header <N>     Minimum header vectors required (default: 100)
  --min-vrf <N>        Minimum VRF vectors required (default: 100)
  --out <dir>          Output directory (default: $home/regress/alignment/results/<timestamp>)
```

### Output Artifacts

Written to `$TSUNAGI_HOME/regress/alignment/results/<timestamp>/`:

| File | Content |
|------|---------|
| `results.json` | Machine-readable results (version, inputs, per-harness status) |
| `summary.md` | Human-readable summary table with commands |
| `command_log.txt` | Full stdout/stderr from each harness invocation |

These files are runtime data and are NOT committed to the repository.

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | header + vrf PASS and minimum counts satisfied (praos may be skipped) |
| 2 | Any harness FAIL |
| 3 | Missing vectors or insufficient counts |
| 4 | tsunagi-node binary not found |

### Praos Skip Behavior

If `praos_threshold.jsonl` contains `expected_threshold_x1e12: null`, the suite records `SKIPPED_EXPECTED_NULL` and does not count it as a failure. Complete the vectors with cardano-node reference values to enable this harness.

### Attaching to Release Notes

The `results.json` and `summary.md` artifacts can be attached to release notes (e.g., v1.4.0) as evidence of alignment verification. Do not commit these files to the repository — they are operator-specific runtime data.
