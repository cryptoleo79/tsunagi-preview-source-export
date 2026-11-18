# consensus-align — Consensus Equivalence Harness (v3.2.0)

## Purpose

Verification-only harness that proves Tsunagi's core consensus computations
match cardano-node behavior on real vectors.

**No forging. No broadcast. No chain injection. No gossip.**

Offline, deterministic, fail-fast. Same vectors always produce the same result.

## Modes

| Mode | Verifies |
|------|----------|
| `praos` | Praos threshold + leader eligibility (oracle-backed) |
| `vrf` | VRF output to u scalar mapping |
| `header` | Header hash + body hash extraction + KES signature |
| `tx` | TX-body inclusion + canonical txid computation |
| `all` | All of the above, with per-kind counters |

## Usage

```
tsunagi-node consensus-align --vectors <path.jsonl> --mode <praos|vrf|header|tx|all> [--verbose]
```

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | PASS — all processed vectors pass |
| 2 | FAIL — mismatch found (fail-fast on first) |
| 3 | Missing file or invalid arguments |
| 4 | Parse/validation error (missing required fields, inconsistent vector) |

## JSONL Vector Schemas

Every vector line MUST include `"kind"` and `"net"` fields.

### kind="praos"

```json
{
  "kind": "praos",
  "net": "preview",
  "slot": 12345,
  "stake_fraction_x1e9": 500000000,
  "asc_x1e6": 50000,
  "vrf_output_hex": "<128 hex chars>",
  "expected_threshold_x1e12": 123456789012,
  "expected_u_x1e12": 98765432100,
  "expected_is_leader": true
}
```

Consistency invariant enforced:
`expected_is_leader == (expected_u_x1e12 < expected_threshold_x1e12)`.
If inconsistent, the harness exits with code 4 (parse error).

Checks:
1. `computeThreshX1e12(stake, asc)` must equal `expected_threshold_x1e12`
2. `vrfOutputToU_x1e12(vrf_output)` must equal `expected_u_x1e12`
3. `(u < threshold)` must equal `expected_is_leader`

### kind="vrf"

```json
{
  "kind": "vrf",
  "net": "preview",
  "slot": null,
  "vrf_output_hex": "<128 hex chars>",
  "expected_u_x1e12": 98765432100
}
```

`slot` is optional (may be null or omitted).

Check: `vrfOutputToU_x1e12(vrf_output)` must exactly equal `expected_u_x1e12`.

### kind="header"

```json
{
  "kind": "header",
  "net": "preview",
  "slot": 12345,
  "block_no": 67890,
  "header_bytes_hex": "<hex>",
  "header_hash_hex": "<64 hex chars>",
  "body_hash_hex": "<64 hex chars>",
  "kes_pk_hex": "<64 hex chars>",
  "kes_period_offset": 15,
  "kes_sig_hex": "<896 hex chars>",
  "header_body_cbor_hex": "<hex>"
}
```

Checks (bytes from vectors only, no re-encoding):
1. `blake2b256(header_bytes)` must match `header_hash_hex`
2. Body hash extracted from decoded header CBOR must match `body_hash_hex`
3. `verifySum6Kes(kes_pk, offset, header_body_cbor, sig)` must return OK

## Kind Filtering

- `--mode praos`: processes only `kind="praos"` vectors; ignores others
- `--mode vrf`: processes only `kind="vrf"` vectors; ignores others
- `--mode header`: processes only `kind="header"` vectors; ignores others
- `--mode tx`: processes only `kind="tx"` vectors; ignores others
- `--mode all`: processes all known kinds; reports per-kind counters

Non-matching kinds are counted as `ignored` (not errors).

## Generating Vectors

### Header vectors (v3.1.0)

Use the included Python script to generate header vectors from captured
block artifacts:

```bash
python3 scripts/gen_consensus_vectors.py \
  --mode header \
  --artifacts-dir "$TSUNAGI_HOME/producer_dryrun/blocks" \
  --out /tmp/header_vectors.jsonl \
  --net preview
```

### Praos / VRF vectors

Praos and VRF vectors require oracle-provided expected values (from
cardano-node or equivalent reference implementation). The v3.1.0
generator does not compute these values.

To add kind/net fields to existing oracle JSONL:

```bash
python3 scripts/gen_consensus_vectors.py \
  --mode passthrough \
  --input existing_praos_vectors.jsonl \
  --add-kind praos \
  --out /tmp/praos_vectors.jsonl \
  --net preview
```

## Running

```bash
# Single mode
tsunagi-node consensus-align --vectors header_vectors.jsonl --mode header

# All modes on combined file
cat praos.jsonl vrf.jsonl header.jsonl > combined.jsonl
tsunagi-node consensus-align --vectors combined.jsonl --mode all --verbose
```

## Operator Discipline

- Preview vectors preferred for initial validation
- Offline execution only (no network access)
- Deterministic: same vectors always produce the same result
- Fail-fast: stops on first mismatch with diagnostic output
- Never include secrets (.skey, private keys) in vector files

---

## v3.2.0 — TX-Body Inclusion Mode

### kind="tx"

```json
{
  "kind": "tx",
  "net": "preview",
  "slot": 12345,
  "block_dir": "/absolute/path/to/block/artifacts",
  "included_tx_hashes": ["<64hex>", "<64hex>"],
  "tx_count": 2,
  "tx_total_bytes": 512,
  "block_cbor_hex": null
}
```

### Disk Loading

Block bytes are resolved in order:
1. If `block_cbor_hex` is a non-null hex string: decode hex to bytes
2. Otherwise: read `<block_dir>/block.cbor` from disk

### Checks

1. **Metadata validation**: if `included_tx_hashes` is empty, `tx_count` must be 0
   (else parse error, exit 4). If non-empty, `tx_count` must equal array length.
2. **Body extraction**: `extractBodyParts(block_bytes)` using the proven CBOR parser.
3. **TX inclusion**: for each txid in `included_tx_hashes`, compute
   `blake2b256(tx_body_cbor)` for each tx body element and verify the txid is present.
   Fail-fast on first missing txid.

### Fail-Closed Rule

If `included_tx_hashes` is non-empty but body part extraction fails
(e.g., unsupported era, malformed CBOR), the result is **FAIL** (exit 2),
not a parse error. The harness does not guess era rules.

### Generating TX Vectors

```bash
python3 scripts/gen_consensus_vectors.py \
  --mode tx \
  --blocks-dir "$TSUNAGI_HOME/producer_dryrun/blocks" \
  --out /tmp/tx_vectors.jsonl \
  --net preview
```

Only block directories containing `included_tx_hashes.json` will produce
vectors. Directories without this file are skipped (empty-tx blocks).

### Running

```bash
tsunagi-node consensus-align --vectors tx_vectors.jsonl --mode tx
```
