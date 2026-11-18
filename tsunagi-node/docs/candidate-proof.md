# Candidate Proof Bundle (v1.8.9)

## Purpose

Package the latest real-KES dryrun candidate into a shareable evidence bundle
(ZIP) that proves the producer pipeline signed a candidate with a real Sum6Kes
key — without exposing any private keys.

This is dryrun-only proof. NO forging. NO broadcast. Preview-only.

## What the Bundle Contains

Only public-safe evidence files from a single candidate directory:

| File | Description |
|------|-------------|
| `meta.json` | Candidate metadata: net, slot, block_no, kes_period_offset, pool_id_hex, sig_kind |
| `verify.json` | Local verification result: hash_match, sig_verify_ok, sig_kind |
| `header_body.cbor` | Raw CBOR header body bytes (the signed message) |
| `signature.bin` | 448-byte Sum6Kes signature (depth 6, 64 periods) |
| `header_hash.hex` | Blake2b256 hash of header.cbor (64 hex chars) |
| `body_hash.hex` | Body hash (64 hex chars) |
| `header.cbor` | Raw 198-byte CandidateV2 header (optional, included if present) |
| `summary.md` | Generated summary with hashes and verification instructions |
| `SHA256SUMS` | SHA256 checksums of all files in the bundle |

## What is NOT Included

The script enforces strict safety — these are **never** included:

- `*.skey` — signing keys (KES, VRF, cold)
- `*.vkey` — verification keys
- `node.cert`, `opcert*` — operational certificates
- `vrf_proof.bin`, `vrf_output.bin` — VRF proof data
- `genesis*` — genesis configuration
- Any symlinks (rejected outright)
- Any file not in the explicit allow list

## Creating a Bundle

```bash
python3 scripts/make_candidate_proof_bundle.py \
  --home ~/tsunagi-home-preview \
  --net preview
```

Options:

| Flag | Default | Description |
|------|---------|-------------|
| `--home` | (required) | TSUNAGI_HOME directory |
| `--net` | `preview` | Network name |
| `--out` | `<home>/producer_dryrun/proof_bundles/` | Output directory |
| `--latest` | (default) | Select latest real_kes candidate |

Output:
- `<out>/<timestamp>_<slot>_real_kes.zip` — the proof bundle
- `<out>/SHA256SUMS` — external checksum of the zip file

## Verifying a Bundle

### 1. Check external ZIP integrity

```bash
cd ~/tsunagi-home-preview/producer_dryrun/proof_bundles/
sha256sum -c SHA256SUMS
```

### 2. Extract and verify internal checksums

```bash
unzip <bundle>.zip -d proof/
cd proof/
sha256sum -c SHA256SUMS
```

### 3. Verify with candidate-verify (optional)

```bash
tsunagi-node candidate-verify --dir proof/
```

Expected output for a valid real_kes candidate:
```
OK: header hash verified
OK: header_body.cbor read (79 bytes)
OK: real_kes signature verified (period_offset=14, msg_len=79)
PASS: candidate artifact verification succeeded (real_kes)
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success — bundle created |
| 2 | No suitable real_kes candidate found |
| 3 | Missing/invalid files, failed validation, or unsafe file/symlink detected |
| 4 | Malformed JSON in meta.json or verify.json |

## Selection Criteria

The script selects the most recent candidate directory where:
1. `meta.json` has `sig_kind == "real_kes"`
2. `verify.json` has `sig_verify_ok == true` (or `sig_ok == true`)
3. `signature.bin` exists and is exactly 448 bytes
4. `header_body.cbor` exists and is non-empty

## Reproducibility

- ZIP entries are added in sorted filename order
- SHA256SUMS lines use the same sorted order
- ZIP entry timestamps are fixed (2025-01-01 00:00:00)

## Safety Reminders

- This tool produces proof artifacts only. It does NOT forge blocks.
- No private keys are ever read, copied, or included in the bundle.
- The preview network is the only supported target.
- Candidates produced in dryrun mode cannot be submitted to any chain.
