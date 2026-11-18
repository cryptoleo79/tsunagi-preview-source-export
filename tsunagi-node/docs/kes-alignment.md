# KES Verification & Alignment (v1.8.3 / v1.8.5)

## Overview

Implements a SumKES verify candidate for `ed25519_kes_2^6`; validated via
real Cardano block header vectors from preview and mainnet.

- **Depth:** 6 levels
- **Total periods:** 64 (2^6)
- **Signature size:** 448 bytes
- **Public key size:** 32 bytes

This is verify-only. NO signing, NO forging, NO broadcast.

## Algorithm

Recursive sum-composition verification:

```
verify(depth, pk, period, msg, sig):
  if depth == 0:
    Ed25519 verify_strict(pk, msg, sig[0..64])
    return

  inner_sig = sig[0 .. sig_size(depth-1)]
  lhs_pk    = sig[sig_size(depth-1)     .. +32]
  rhs_pk    = sig[sig_size(depth-1) + 32 .. +64]

  check: blake2b_256(lhs_pk || rhs_pk) == pk

  half = 2^(depth-1)
  if period < half:
    recurse(depth-1, lhs_pk, period, msg, inner_sig)
  else:
    recurse(depth-1, rhs_pk, period - half, msg, inner_sig)
```

Where `sig_size(d) = (d + 1) * 64`. So depth 6 = 448 bytes.

`hash_pair` uses Blake2b-256 on the 64-byte concatenation of two 32-byte keys.

## CLI: kes-verify

Single KES signature verification:

```bash
tsunagi-node kes-verify --pk <64hex> --period <N> --msg <hex> --sig <896hex>
```

Self-test (input validation + base-case Ed25519 depth 0 only):

```bash
tsunagi-node kes-verify --selftest
```

Exit codes:

| Code | Meaning |
|------|---------|
| 0 | OK (verification passed, or self-test passed) |
| 1 | Self-test failure |
| 2 | Verification failed |
| 3 | Missing arguments |
| 4 | Malformed hex input |

## CLI: kes-align

JSONL alignment harness for batch verification against reference vectors:

```bash
tsunagi-node kes-align --vectors <path.jsonl>
```

### JSONL format

Each line is a JSON object:

```json
{"kes_pk_hex":"<64>","kes_period":<N>,"msg_hex":"<hex>","kes_sig_hex":"<896>","expected_result":"OK"}
```

| Field | Required | Description |
|-------|----------|-------------|
| `kes_pk_hex` | yes | 64 hex chars (32-byte top-level KES public key) |
| `kes_period` | yes | KES period (0..63) |
| `kes_sig_hex` | yes | 896 hex chars (448-byte SumKES signature) |
| `expected_result` | yes | Expected result string: `OK`, `ED25519_FAIL`, `PK_MISMATCH`, etc. |
| `msg_hex` | no | Hex-encoded signed message (defaults to empty) |

Exit codes:

| Code | Meaning |
|------|---------|
| 0 | All vectors match |
| 2 | One or more mismatches |
| 3 | Missing args or file errors |

Output format:

```
KES-ALIGN: vectors=N mismatches=0 EXIT=0
```

## Self-Test Scope

`kes-verify --selftest` tests:
1. Length rejection (447-byte sig → BAD_SIG_LEN)
2. Period rejection (period=64 → PERIOD_OUT_OF_RANGE)
3. Base-case Ed25519 verify at depth 0 (known seed → OK)
4. Tampered message at depth 0 (→ ED25519_FAIL)

These verify input validation and the Ed25519 leaf path only. Full depth-6
correctness requires external reference vectors via `kes-align`.

## Result Codes

| Result | Description |
|--------|-------------|
| `OK` | Verification passed |
| `BAD_SIG_LEN` | Signature not 448 bytes |
| `BAD_PK_LEN` | Public key not 32 bytes |
| `PERIOD_OUT_OF_RANGE` | Period >= 64 |
| `PK_MISMATCH` | blake2b_256(lhs\|\|rhs) != pk at some tree level |
| `ED25519_FAIL` | Base Ed25519 verification failed |

## Signed Message Mode (v1.8.5)

v1.8.5 empirically determined the exact message bytes that Cardano signs
with KES by testing two candidate modes against 50 real preview block
headers and 20 real mainnet block headers.

**Result: `direct` mode — the signed message is the raw CBOR-encoded
header body bytes.**

| Mode | Preview (50 vectors) | Mainnet (20 vectors) |
|------|---------------------|---------------------|
| `direct` (raw header_body CBOR) | 50/50 PASS | 20/20 PASS |
| `blake2b256` (hash of header_body) | 0/50 PASS | not tested |

The `kes_period` parameter for verification is the **offset** from the
opcert start period: `slot / 129600 - opcert_kes_period`. This value
is in the range 0..63.

### Derivation workflow

```bash
# 1. Extract vectors from captures (v1.8.4)
python3 scripts/extract_kes_vectors.py --home ~/tsunagi-home-preview --net preview

# 2. Derive msg_hex with confirmed mode
python3 scripts/kes_align_from_vectors.py \
  --vectors ~/tsunagi-home-preview/regress/kes/kes_vectors.jsonl \
  --mode direct

# 3. Verify with kes-align
tsunagi-node kes-align \
  --vectors ~/tsunagi-home-preview/regress/kes/kes_vectors_derived.direct.jsonl
# Expected: mismatches=0 EXIT=0
```

## What This Is NOT

- This is NOT a signing implementation. Only verification.
- This is NOT a block forge. No blocks are created or broadcast.
- Full depth-6 correctness validated via real chain vectors (preview + mainnet).
