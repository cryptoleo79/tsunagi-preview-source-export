# Full Block Candidate Assembly (v2.0.0-alpha)

## Purpose

Produce a full Cardano block candidate (real header + real body + full CBOR
block bytes) during producer dryrun. The block matches the on-wire format
of era 7 (Conway2) blocks from the preview network.

**NO forging. NO broadcast.** Artifacts are written to local disk only.

## Block Wire Format

```
block = [era, [header, tx_bodies, witnesses, aux_data, invalid_txs]]
header = [header_body, kes_sig(448)]
```

### Header Body (10-element CBOR array, era 7)

| Index | Field | Type |
|-------|-------|------|
| 0 | block_number | uint |
| 1 | slot | uint |
| 2 | prev_hash | bstr(32) |
| 3 | issuer_vk | bstr(32) — cold verification key |
| 4 | vrf_vkey | bstr(32) |
| 5 | vrf_result | [bstr(64), bstr(80)] — output, proof |
| 6 | block_body_size | uint |
| 7 | block_body_hash | bstr(32) |
| 8 | operational_cert | [bstr(32), uint, uint, bstr(64)] — hot_vk, seq_no, kes_period, sigma |
| 9 | protocol_version | [uint, uint] — major, minor |

### Hashing

- **header_hash** = blake2b-256 of full header CBOR bytes
- **body_hash** = blake2b-256(blake2b-256(tx_bodies) || blake2b-256(witnesses) || blake2b-256(aux_data) || blake2b-256(invalid_txs))

### Empty Block Body

| Part | CBOR | Bytes |
|------|------|-------|
| tx_bodies | `0x80` | empty array |
| witnesses | `0x80` | empty array |
| aux_data | `0xa0` | empty map |
| invalid_txs | `0x80` | empty array |
| body_size | 4 | |
| body_hash | `29571d16f081709b3c48651860077bebf9340abb3fc7133443c54f1f5a5edcf1` | proven from real chain |

## Environment Variables

All existing dryrun env vars apply. Additional vars for block candidate:

| Variable | Required | Description |
|----------|----------|-------------|
| `TSUNAGI_COLD_VK_HEX` | yes | Cold verification key (64 hex chars = 32 bytes) |
| `TSUNAGI_OPCERT_SEQ` | yes | Operational certificate sequence number |
| `TSUNAGI_OPCERT_SIGMA_HEX` | yes | OpCert sigma / cold key signature (128 hex chars = 64 bytes) |
| `TSUNAGI_PROTOCOL_MAJOR` | no | Protocol version major (default: 10) |
| `TSUNAGI_PROTOCOL_MINOR` | no | Protocol version minor (default: 0) |

Block candidate assembly is enabled only when all required env vars are set
AND `TSUNAGI_PRODUCER_DRYRUN=1` AND the KES key kind is `cardano_kes`.

## Dryrun Artifacts

When a leader slot fires with block candidate enabled, the following
additional artifacts are written to `$TSUNAGI_HOME/producer_dryrun/blocks/<slot>/`:

| File | Content |
|------|---------|
| `block.cbor` | Full block CBOR (era 7 wire format) |
| `block_header.cbor` | Header CBOR: [header_body, kes_sig] |
| `block_header_hash.hex` | blake2b-256 of header CBOR (64 hex chars) |
| `block_body_hash.hex` | 4-part merkle body hash (64 hex chars) |

These are in addition to the existing v1.8 artifacts (header.cbor, meta.json, etc.).

## Self-Verification

The producer performs FATAL (exit 97) self-verification at build time:

1. KES signature on the 10-element header body is verified immediately
2. Header hash recomputed from assembled header CBOR must match
3. Any mismatch triggers `std.process.exit(97)`

## CLI Verification

```
zig build run -- block-candidate-verify --dir <dryrun_slot_dir>
```

Performs 3 checks:
- CHECK 1: blake2b-256(block_header.cbor) == block_header_hash.hex
- CHECK 2: extractBodyParts(block.cbor) body hash == block_body_hash.hex
- CHECK 3: header region in block.cbor == block_header.cbor (byte-for-byte)

Exit codes: 0=pass, 2=mismatch, 3=IO/parse error.

## Phase A: Header Body Alignment

The 10-element header body builder was proven by aligning against 100 real
chain vectors byte-for-byte:

```
zig build run -- header-body-align --vectors <vectors.jsonl>
```

Vectors are extracted from capture .bin files using:

```
python3 scripts/extract_header_body_bytes.py <capture.bin> > vectors.jsonl
```

## Files

| File | Purpose |
|------|---------|
| `src/producer/cbor_block_header_body.zig` | 10-element header body CBOR builder |
| `src/producer/cbor_block_body.zig` | Block body builder (empty body + body hash) |
| `src/producer/cbor_block_full.zig` | Full block CBOR assembly |
| `src/cli/header_body_align_cmd.zig` | Phase A alignment CLI |
| `src/cli/block_candidate_verify_cmd.zig` | Block candidate verification CLI |
| `scripts/extract_header_body_bytes.py` | Python extraction script for capture .bin |

---

# Block Candidate Proof Bundle + Drift Guard (v2.0.1)

## Purpose

Tooling-only release. Adds proof bundling for block candidates and an
oracle-based drift guard CLI. No runtime producer changes. No baselines.

## Proof Bundle

Package the latest real-KES block candidate into a shareable evidence ZIP:

```bash
python3 scripts/make_block_candidate_proof_bundle.py --home $TSUNAGI_HOME
```

Searches `$TSUNAGI_HOME/producer_dryrun/blocks/` for the latest directory
where `meta.json` has `sig_kind == "real_kes"`, `verify.json` has
`sig_ok == true`, and `block.cbor` exists.

**Output**: `<home>/producer_dryrun/blocks_proof_bundles/<ts>_<slot>_block_candidate.zip`

**Safety**: rejects symlinks, rejects secret patterns (`.skey`, `.vkey`,
`opcert`, etc.), deterministic ZIP (sorted entries, fixed timestamp),
internal SHA256SUMS, external sha256(zip).

**Exit codes**: 0=success, 2=no candidate, 3=validation fail, 4=JSON parse fail

## Block Candidate Regress (Oracle Lock-in)

Oracle-based drift guard — verifies Sum6Kes signatures from JSONL vectors
extracted from real block candidate artifacts. **No baselines. No --init mode.**

```bash
zig build run -- block-candidate-regress --vectors <path.jsonl>
```

### JSONL Vector Schema

```json
{"slot":<u64>,"header_hash_hex":"<64hex>","body_hash_hex":"<64hex>","kes_pk_hex":"<hex>","kes_period_offset":<u64>,"sig_hex":"<hex>","header_body_cbor_hex":"<hex>"}
```

### Behavior

- Parses each JSONL line
- Decodes hex fields to bytes
- Verifies `Sum6Kes(kes_pk, kes_period_offset, header_body_cbor, sig)`
- **Fail-fast** on first verification failure

**Exit codes**: 0=all pass, 2=verification failure, 3=parse/file/IO error

### Generating Vectors

Extract vectors from a block candidate artifact directory:

```bash
python3 scripts/gen_block_candidate_regress_vectors.py \
    --dir $TSUNAGI_HOME/producer_dryrun/blocks/<unix>_<slot> \
    --out /tmp/vectors.jsonl
```

## Files (v2.0.1)

| File | Purpose |
|------|---------|
| `scripts/make_block_candidate_proof_bundle.py` | Proof bundle packager |
| `scripts/gen_block_candidate_regress_vectors.py` | JSONL vector extractor |
| `src/cli/block_candidate_regress_cmd.zig` | Oracle lock-in drift guard CLI |

---

# TX Inclusion Metadata — Phase A Only (v2.1.0-a)

## Purpose

Record which mempool transactions **would** be included in a dryrun block
candidate. Phase A writes metadata only — **no tx bytes are embedded in
block_body.cbor**. Tx embedding in the body is gated on proven era-specific
tx-list encoding + body-hash semantics (reserved for a future phase).

**FAIL-CLOSED discipline**: if txid computation or body-hash linkage cannot
be proven for the current era, the system logs once and proceeds with an
empty body. No guessing, no crashing.

## Canonical txid

```
txid = blake2b-256( tx_body_cbor )
```

Where `tx_body_cbor` is the raw CBOR bytes of the **first element** of
the full transaction CBOR array `[tx_body, witnesses, ...]`.

This is the **standard Cardano txid**, NOT `blake2b-256(full_tx_cbor)`.
The mempool's `Item.hash` stores `blake2b-256(full_tx_cbor)` for dedup —
that is a different value.

## New Metadata Artifacts

When the mempool is non-empty at leader time, the following files are
written to `$TSUNAGI_HOME/producer_dryrun/blocks/<unix>_<slot>/`:

| File | Content |
|------|---------|
| `included_tx_hashes.json` | JSON array of canonical txid hex strings, sorted lexicographically |
| `included_tx_count.txt` | Decimal tx count |
| `included_tx_total_bytes.txt` | Decimal total tx CBOR bytes |

The `block.cbor` body remains **empty** (0x80/0xa0 parts, body_hash unchanged).

## Environment Variables (v2.1.0-a)

| Variable | Default | Description |
|----------|---------|-------------|
| `TSUNAGI_DRYRUN_BLOCK_MAX_TX` | 50 | Max txs to include in metadata |
| `TSUNAGI_DRYRUN_BLOCK_MAX_BYTES` | 2097152 (2 MB) | Max cumulative tx bytes |

## CLI: `--expect-tx-hash`

```bash
zig build run -- block-candidate-verify --dir <path> --expect-tx-hash <64hex>
```

- CHECK 4: Verifies the given txid is present in `included_tx_hashes.json`.
- Does NOT extract tx bodies from `block_body.cbor` (Phase A: metadata only).
- Exit 0 = tx found in metadata + existing 3 checks pass.
- Exit 2 = mismatch (tx not found, or metadata file missing).

## Proof Bundle

Updated to include tx metadata files when present:
`included_tx_hashes.json`, `included_tx_count.txt`, `included_tx_total_bytes.txt`.

## Phase B (future)

Embed actual tx bytes in block_body.cbor with correct body hash. Requires
proven tx-list CBOR encoding + 4-part body-hash semantics for the current
era. Not included in v2.1.0-a.

---

# TX-in-Body Block Candidate — Real Embedding (v2.1.2)

## Purpose

Embed mempool transaction bytes into the dryrun block body with verified
body-hash linkage. The block body is no longer empty when mempool txs are
available — `tx_bodies` and `witnesses` CBOR arrays contain the decomposed
tx parts, and the body hash in the header reflects the actual body content.

**Phase A gate PASSED**: `extractBodyParts()` + `computeBodyHash()` correctly
reproduce the body hash for real preview-era blocks. This unlocks tx embedding.

**FAIL-CLOSED**: if tx decomposition fails for a transaction, that tx is
skipped. If all txs fail, the block falls back to an empty body.

**NO forging. NO broadcast. NO chain injection.** Preview-only, dryrun-only.

## Block Body with Transactions

When mempool txs are available:

| Part | Content |
|------|---------|
| tx_bodies | CBOR array of tx_body slices (first element of each tx) |
| witnesses | CBOR array of witness slices (second element of each tx) |
| aux_data | `0xa0` (empty map — aux data not extracted from txs) |
| invalid_txs | `0x80` (empty array) |
| body_size | sum of all 4 CBOR part sizes |
| body_hash | 4-part merkle hash of the actual body parts |

The CBOR array header uses definite-length encoding:
- N < 24: `0x80 | N` (1 byte)
- N < 256: `0x98, N` (2 bytes)
- N < 65536: `0x99, N_hi, N_lo` (3 bytes)

## TX Decomposition

Each full Cardano tx `[tx_body, witnesses, ...]` is decomposed using
`block_hash.decomposeTx()` which extracts:
- `tx_body`: raw CBOR of first array element
- `witnesses`: raw CBOR of second array element

The decomposition uses only proven CBOR element-boundary parsing
(`readCborHdr` + `skipCborElement`). No assumptions about internal tx
structure.

## CLI: `--expect-tx-hash` (v2.1.2)

```bash
zig build run -- block-candidate-verify --dir <path> --expect-tx-hash <64hex>
```

CHECK 4 behavior:
1. **Body verification** (v2.1.2 blocks): parse `tx_bodies` array from
   `block.cbor`, compute `blake2b256(element)` for each, match against
   expected txid.
2. **Metadata fallback** (v2.1.0-a blocks with empty body): falls back to
   `included_tx_hashes.json` substring search.

Body-hash linkage is verified by CHECK 2 (unchanged).

## Files Modified (v2.1.2)

| File | Change |
|------|--------|
| `src/net/ledger/block_hash.zig` | Extended TxParts with witnesses; added findTxidInBodies |
| `src/producer/cbor_block_body.zig` | Added DynBodyResult, buildBodyWithTxSlices, buildCborArray |
| `src/producer/producer.zig` | Tx decomposition, body embedding, dynamic full-block buffer |
| `src/cli/block_candidate_verify_cmd.zig` | CHECK 4 body verification with metadata fallback |

---

# Forge Simulation Harness (v2.3.0)

## Purpose

Offline, disk-only "forge readiness" validation from an existing
`blocks/<unix>_<slot>/` directory. Validates that a block candidate
passes all cryptographic checks required for real forging.

**NO broadcast. NO chain injection. NO network. Preview-only.**

This is a verifier/simulation tool. It does not produce or submit blocks.

## Usage

```bash
tsunagi-node forge-sim --dir <producer_dryrun/blocks/unix_slot> --out <report.json>
```

## Checks

| Check | Description | PASS condition |
|-------|-------------|----------------|
| A | Header hash | blake2b256(block_header.cbor) == block_header_hash.hex |
| B | Body hash | computeBodyHash(extractBodyParts(block.cbor)) == block_body_hash.hex |
| C | KES signature | verifySum6Kes(kes_pk, kes_period_offset, header_body.cbor, signature.bin) == OK |
| D | Tx inclusion | Every txid in included_tx_hashes.json found in block body (SKIP if file absent) |

Checks A, B, C are required. Check D is conditional: SKIP if no
`included_tx_hashes.json`, FAIL-CLOSED if the file exists but tx bodies
cannot be verified.

## Required Artifacts

| File | Description |
|------|-------------|
| `block.cbor` | Full block CBOR (era 7 wire format) |
| `block_header.cbor` | Header CBOR: [header_body, kes_sig] |
| `header_body.cbor` | Header body CBOR (10-element array) |
| `signature.bin` | KES signature (448 bytes) |
| `block_header_hash.hex` | blake2b-256 of header CBOR (64 hex chars) |
| `block_body_hash.hex` | 4-part merkle body hash (64 hex chars) |
| `meta.json` | Must include: kes_pk_hex, kes_period_offset |

## Report Output

JSON written to `--out` path with stable keys:

```json
{
  "dir": "<path>",
  "slot": 105681279,
  "block_no": 4071635,
  "kes_period_offset": 15,
  "header_hash": "<64hex>",
  "body_hash": "<64hex>",
  "tx_count": 1,
  "checks": {
    "A_header_hash": "PASS",
    "B_body_hash": "PASS",
    "C_kes_verify": "PASS",
    "D_tx_inclusion": "PASS"
  },
  "overall": "PASS"
}
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | PASS (A/B/C pass; D may be SKIP or PASS) |
| 2 | FAIL (any required check fails; or D fails) |
| 3 | Missing required artifact files |
| 4 | Parse errors (invalid JSON/hex/CBOR) |

## Example

```bash
DIR="$(ls -1t $TSUNAGI_HOME/producer_dryrun/blocks | head -n 1)"
tsunagi-node forge-sim \
  --dir $TSUNAGI_HOME/producer_dryrun/blocks/$DIR \
  --out /tmp/forge_sim_report.json
```

## Files (v2.3.0)

| File | Purpose |
|------|---------|
| `src/cli/forge_sim_cmd.zig` | Forge simulation harness CLI |
