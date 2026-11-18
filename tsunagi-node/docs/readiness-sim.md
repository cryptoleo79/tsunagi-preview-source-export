# Readiness-Sim — Batch Offline Block Candidate Verification (v3.5.0)

## Purpose

Batch offline verification of block candidate artifacts producing a
deterministic rolling Blake2b256 digest. Proves that header hashing,
body hashing, and KES signature verification are consistent and
reproducible across runs.

**Verification-only. No forging. No broadcast. No network changes.**

## Quick Start

```bash
# 1. Generate vectors from block candidates
python3 scripts/gen_readiness_sim_vectors.py \
  --net preview \
  --blocks-dir $TSUNAGI_HOME/producer_dryrun/blocks \
  --out /tmp/readiness_sim.jsonl \
  --limit 100

# 2. Run simulation
tsunagi-node readiness-sim \
  --vectors /tmp/readiness_sim.jsonl \
  --out /tmp/readiness_report.json

# 3. Verify determinism (run twice, compare digest)
tsunagi-node readiness-sim --vectors /tmp/readiness_sim.jsonl --out /tmp/r1.json
tsunagi-node readiness-sim --vectors /tmp/readiness_sim.jsonl --out /tmp/r2.json
# rolling_digest_hex must match
```

## Vector Generation

```
python3 scripts/gen_readiness_sim_vectors.py \
  --net <preview|preprod|mainnet|sancho> \
  --blocks-dir <path> \
  --out <file.jsonl> \
  [--limit <N>]
```

| Flag | Required | Description |
|------|----------|-------------|
| `--net` | yes | Network filter |
| `--blocks-dir` | yes | Path to `producer_dryrun/blocks/` |
| `--out` | yes | Output JSONL file (overwrites) |
| `--limit` | no | Max vectors (default: 50) |

Filters: `sig_kind == "real_kes"`, `sig_verify_ok == true`, net matches.

## Simulation

```
tsunagi-node readiness-sim --vectors <file.jsonl> --out <report.json>
```

| Flag | Required | Description |
|------|----------|-------------|
| `--vectors` | yes | JSONL vector file |
| `--out` | yes | Output report JSON |

### Checks Per Vector

| Check | Method | PASS |
|-------|--------|------|
| A | blake2b256(block_header_cbor) | == block_header_hash_hex |
| B | computeBodyHash(extractBodyParts(block_cbor)) | == block_body_hash_hex |
| C | verifySum6Kes(kes_pk, offset, header_body_cbor, sig) | == ok |

All vectors are processed (no fail-fast) to produce the complete rolling digest.

## Rolling Digest Algorithm

Deterministic, independent of platform or runtime:

1. Initialize Blake2b256 hasher
2. For each vector in JSONL order, build a 75-byte canonical entry:
   - `slot` (8 bytes, big-endian)
   - `block_header_hash` (32 bytes)
   - `block_body_hash` (32 bytes)
   - `check_a` result (1 byte: 1=pass, 0=fail)
   - `check_b` result (1 byte)
   - `check_c` result (1 byte)
3. Update hasher with canonical entry
4. Final hash = `rolling_digest_hex`

**Guarantee:** Same vectors → same digest on every run.

## Report Schema

```json
{
  "vectors_processed": 47,
  "all_pass": true,
  "rolling_digest_hex": "<64hex>",
  "checks": {
    "A_header_hash": 47,
    "B_body_hash": 47,
    "C_kes_verify": 47
  }
}
```

## JSONL Vector Schema

```json
{
  "slot": 105665115,
  "block_no": 4071142,
  "net": "preview",
  "block_header_cbor_hex": "<hex>",
  "block_header_hash_hex": "<64hex>",
  "block_cbor_hex": "<hex>",
  "block_body_hash_hex": "<64hex>",
  "kes_pk_hex": "<64hex>",
  "kes_period_offset": 15,
  "sig_hex": "<896hex>",
  "header_body_cbor_hex": "<hex>"
}
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All checks pass |
| 2 | At least one check failed |
| 3 | IO error, parse error, or no vectors |

## Non-Goals

- No forging
- No broadcast
- No chain injection
- No network protocol changes
- No producer logic changes
- No consensus modifications
