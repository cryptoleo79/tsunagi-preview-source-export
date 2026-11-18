# KES Vector Extraction (v1.8.4)

## Purpose

Extract KES-related fields from real Cardano block headers captured by Tsunagi.
This produces a JSONL dataset for future verification alignment once the exact
"to-be-signed" message construction is implemented.

This is a prerequisite step: we extract the raw data now, verify later.

## What Is Extracted

From each Cardano block header (Babbage/Conway, 10-item header body):

| Field | Source | Description |
|-------|--------|-------------|
| `slot` | header_body[1] | Block slot number |
| `kes_period` | slot / 129600 | Current KES period for this block |
| `kes_pk_hex` | op_cert[0] (hot_vkey) | KES public key (32 bytes, 64 hex) |
| `kes_sig_hex` | header[1] | KES signature (448 bytes, 896 hex for depth-6) |
| `opcert_kes_period` | op_cert[2] | Opcert start KES period |
| `kes_period_offset` | kes_period - opcert_kes_period | Period offset for verification |
| `header_body_hash_hex` | blake2b_256(header_body_cbor) | Hash of header body CBOR bytes |
| `header_body_cbor_hex` | raw bytes | Full header body CBOR (candidate signed message) |
| `block_body_hash_hex` | header_body[7] | Block body hash from header |
| `header_hash` | blake2b_256(header_cbor) | Full header hash |
| `issuer_vkey_hex` | header_body[3] | Cold verification key (pool operator) |
| `opcert_sequence` | op_cert[1] | Operational certificate sequence number |

## Header Structure Reference

```
block         = [era, [header, tx_bodies, witnesses, aux_data, ...]]
header        = [header_body, kes_signature]
header_body   = [block_number, slot, prev_hash, issuer_vkey, vrf_vkey,
                 vrf_cert, body_size, body_hash, op_cert, proto_version]
op_cert       = [hot_vkey, sequence_number, kes_period, sigma]
```

## Usage

```bash
python3 scripts/extract_kes_vectors.py \
  --home ~/tsunagi-home-preview \
  --net preview \
  --count 50
```

### Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `--home` | `$TSUNAGI_HOME` | Tsunagi home directory |
| `--net` | `preview` | Network: mainnet, preview, sancho |
| `--capture-dir` | `$HOME/captures` | Capture file directory |
| `--out` | `$HOME/regress/kes` | Output directory |
| `--count` | `50` | Max vectors to extract |

### Output

```
$TSUNAGI_HOME/regress/kes/kes_vectors.jsonl
```

## JSONL Schema

One JSON object per line:

```json
{
  "net": "preview",
  "slot": 105440000,
  "block_number": 4061800,
  "era": 7,
  "kes_period": 813,
  "opcert_kes_period": 800,
  "kes_period_offset": 13,
  "kes_pk_hex": "<64 hex chars>",
  "kes_sig_hex": "<896 hex chars>",
  "header_body_hash_hex": "<64 hex chars>",
  "block_body_hash_hex": "<64 hex chars>",
  "header_body_cbor_hex": "<hex>",
  "header_hash": "<64 hex chars>",
  "issuer_vkey_hex": "<64 hex chars>",
  "opcert_sequence": 5,
  "note": "extracted from real block header"
}
```

## Deduplication

Vectors are deduplicated by `(kes_pk_hex, slot)`. Duplicate blocks from
overlapping capture files are automatically skipped.

## Why This Is Needed

Before we can run `kes-align` against real chain data, we need:

1. **This step (v1.8.4):** Extract raw KES fields from captured headers
2. **Next step:** Determine the exact "to-be-signed" message that Cardano
   uses for KES signing (likely the CBOR-encoded header_body, possibly with
   additional context)
3. **Final step:** Construct `msg_hex` for each vector and run `kes-align`
   to verify our Sum6Kes implementation against real chain signatures

The `header_body_cbor_hex` field preserves the raw header body bytes,
which is the most likely candidate for the signed message.

## What This Is NOT

- This does NOT verify KES signatures (that requires the signed message)
- This does NOT sign anything
- This does NOT forge blocks or broadcast data
- This is extraction and tooling only
