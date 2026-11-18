# evidence-pack -- Offline Legitimacy Bundle (v3.7.0)

## Purpose

Produces a deterministic, shareable "legitimacy bundle" directory proving
Tsunagi correctness properties from offline artifacts and existing harnesses.

Operator-grade release evidence: reproducible outputs, stable filenames/schema,
SHA256 integrity, bounded reporting.

## Non-Goals

- No forging, no broadcast, no chain injection, no gossip
- No changes to scheduler/VRF/Praos/KES verify logic
- No changes to producer runtime behavior
- No baseline edits
- Not a backup tool — contains only verification results

## Usage

```
tsunagi-node evidence-pack \
    --home <TSUNAGI_HOME> \
    --net <preview|preprod|mainnet|sancho> \
    [--out <dir>] \
    [--limit <N>] \
    [--strict] \
    [--port <N>] \
    [--consensus-vectors <path>] \
    [--readiness-vectors <path>]
```

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--home <path>` | `$TSUNAGI_HOME` | Node state directory (required) |
| `--net <name>` | (required) | Network: preview, preprod, mainnet, sancho |
| `--out <dir>` | `/tmp` | Base output directory |
| `--limit <N>` | 50 | Max block candidates to process |
| `--strict` | off | Strict mode: missing dirs/files become FAIL |
| `--port <N>` | (none) | Enable guardian deploy-check (localhost only) |
| `--consensus-vectors <path>` | (generate) | Use pre-generated consensus vectors |
| `--readiness-vectors <path>` | (generate) | Use pre-generated readiness vectors |

### Quick Start (Preview)

```bash
# Build
cd ~/src/tsunagi-follower/tsunagi-node
zig build -Doptimize=ReleaseSafe

# Run (offline, no --port)
./zig-out/bin/tsunagi-node evidence-pack \
    --home ~/tsunagi-home-preview \
    --net preview \
    --out /tmp \
    --limit 50

# Verify
cd /tmp/tsunagi_evidence_preview_<unix>/
sha256sum -c SHA256SUMS
```

## Output Directory Structure

```
tsunagi_evidence_<net>_<unix>/
  manifest.json
  SHA256SUMS
  version.txt
  checks/
    consensus_align_summary.txt
    readiness_sim_report_1.json
    readiness_sim_report_2.json
    forge_sim_report.json          (only if block dirs exist)
    ledger_digest.json             (only if lmdb exists)
    guardian_deploy_check.txt      (only if --port provided)
  inputs/
    consensus_vectors.jsonl
    readiness_vectors.jsonl
```

## Checks

### Required (must PASS)

1. **consensus-align**: Runs on vectors from block candidates. Header vectors required.
2. **readiness-sim**: Runs twice with same vectors. Both must PASS. Rolling digests must match.

### Required (SKIP allowed without --strict)

3. **ledger digest**: Computes deterministic ledger digest from LMDB. SKIP if lmdb/ missing.

### Optional (PASS or SKIP)

4. **guardian deploy-check**: Only runs if `--port` provided.
5. **forge-sim**: Only runs if block candidate directories exist.

### Strict Mode

With `--strict`:
- Missing required directories/files become FAIL instead of SKIP
- deploy-check must PASS if --port provided

## Manifest Schema

```json
{
  "version": "tsunagi-node dev (unknown) ReleaseSafe",
  "net": "preview",
  "home": "/home/user/tsunagi-home-preview",
  "unix": 1709337600,
  "limit": 50,
  "inputs": {
    "consensus_vectors": "inputs/consensus_vectors.jsonl",
    "readiness_vectors": "inputs/readiness_vectors.jsonl"
  },
  "results": {
    "guardian_deploy_check": "SKIP",
    "consensus_align": "PASS",
    "readiness_sim": "PASS",
    "forge_sim": "PASS",
    "ledger_digest": "PASS"
  },
  "rolling_digest_hex": "<64 hex chars>",
  "notes": ["guardian deploy-check skipped (no --port)"]
}
```

## SHA256SUMS

- SHA256 hash for every file in the evidence directory (excluding SHA256SUMS itself)
- Sorted by relative path for determinism
- Compatible with `sha256sum -c SHA256SUMS`

## Determinism

The `rolling_digest_hex` field comes from the readiness-sim report. It is a
Blake2b256 hash computed over canonical 75-byte entries per verified vector
(slot + header_hash + body_hash + check results).

**Same inputs always produce the same rolling_digest_hex.** The evidence-pack
runs readiness-sim twice and verifies the digests match. A mismatch is a FAIL.

Timestamps and output directory names will differ between runs, but:
- `rolling_digest_hex` is identical for identical inputs
- All check outcomes (PASS/FAIL/SKIP) are identical for identical inputs
- SHA256SUMS are deterministic per run

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All required checks PASS |
| 2 | One or more required checks FAIL |
| 3 | Missing required files or directories |
| 4 | Parse or validation errors |

## Sharing

The evidence directory is a self-contained bundle. To share:
```bash
cd /tmp
tar czf tsunagi_evidence_preview_1709337600.tar.gz tsunagi_evidence_preview_1709337600/
```

No secrets are included by design — only verification results, vectors, and metadata.

## v3.9.0 — Mainnet Readiness Envelope

### Changes

- **Alignment fallback**: When `producer_dryrun/blocks/` is absent (e.g. mainnet),
  vectors are generated from `regress/alignment/header_hash.jsonl` instead.
  The Python scripts decode Cardano header CBOR to extract all required fields
  (slot, block_no, body_hash, KES key/sig/period, header_body_cbor).

- **readiness-sim `--header-only`**: When running on alignment-derived vectors
  (no full block CBOR), CHECK B uses `extractBodyHashFromHeader()` from decoded
  header CBOR instead of computing body hash from block body parts.
  CHECK A (header hash) and CHECK C (KES verify) are unchanged.
  Rolling digest schema is unchanged.

- **Strict mode enforcement**: With `--strict`, required checks MUST NOT SKIP.
  Required: consensus-align PASS, readiness-sim PASS, ledger_digest PASS (if lmdb exists).
  Optional: forge-sim SKIP ok, deploy-check SKIP ok (unless --port provided).
  Manifest includes `"strict": true/false` field.

- **Zero-secrets scan**: Before writing manifest/SHA256SUMS, the evidence directory
  is scanned for forbidden files. FAIL if any filename matches `*.skey`/`*.vkey`/`*.cert`,
  contains "key", or exceeds 5MB.

- **Slot-ascending sort**: All generated vectors are sorted by slot ascending
  (previously sorted by directory name, which was lexicographic).

### Mainnet Usage

```bash
./zig-out/bin/tsunagi-node evidence-pack \
    --home ~/tsunagi-home-mainnet \
    --net mainnet \
    --strict \
    --limit 50
```

This will:
1. Detect missing `producer_dryrun/blocks/` and fall back to alignment vectors
2. Run consensus-align on header vectors (header hash + body hash from CBOR + KES verify)
3. Run readiness-sim twice with `--header-only` (deterministic rolling digest)
4. Run ledger digest if `lmdb/` exists
5. Scan for secrets, write manifest with `"strict": true`, write SHA256SUMS

### Updated Manifest Schema

```json
{
  "version": "...",
  "net": "mainnet",
  "home": "...",
  "unix": 1709337600,
  "limit": 50,
  "strict": true,
  "inputs": { ... },
  "results": { ... },
  "rolling_digest_hex": "<64 hex chars>",
  "notes": [...]
}
```

## v4.0.0 — Cold-Start Determinism Envelope

### Purpose

Proves Tsunagi can cold-start deterministically from a portable TSF snapshot:
offline import into fresh LMDB, deterministic ledger digest, two independent
runs produce identical digest. Publishable envelope with zero secrets.

Tooling-only. No runtime changes. No forging/broadcast/injection.

### Cold-Start Mode

```bash
tsunagi-node evidence-pack \
    --cold-start \
    --snapshot <path/to/snapshot.tsf> \
    --net <preview|preprod|mainnet|sancho> \
    [--out <dir>] \
    [--strict]
```

Cold-start mode bypasses the `--home` requirement. It uses the standalone
`cold-start` command as a subprocess to import the snapshot into fresh LMDB
and compute the KIZUNA ledger digest.

### How It Works

1. Validate snapshot file, compute SHA256, read TSF header (slot, block_no)
2. Write `inputs/snapshot_info.json` with snapshot metadata
3. Run `cold-start` subprocess twice with independent temp LMDB directories
4. Parse both JSON reports, extract `ledger_digest_hex`
5. Compare digests — identical = determinism PASS
6. On PASS: delete temp LMDB directories, run zero-secrets scan (20MB limit)
7. On FAIL: preserve temp LMDB directories for debugging, note paths in manifest
8. Write manifest with `"mode": "cold_start"`, SHA256SUMS

### Cold-Start Evidence Directory

```
tsunagi_evidence_coldstart_<net>_<unix>/
  manifest.json
  SHA256SUMS
  version.txt
  checks/
    cold_start_1.json
    cold_start_2.json
    ledger_digest.json
  inputs/
    snapshot_info.json
```

### Cold-Start Manifest Schema

```json
{
  "version": "...",
  "net": "mainnet",
  "unix": 1709337600,
  "strict": true,
  "mode": "cold_start",
  "snapshot": {
    "path": "/path/to/snapshot.tsf",
    "basename": "snapshot.tsf",
    "sha256": "<64 hex chars>",
    "bytes": 123456789,
    "slot": 123456,
    "block_no": 12345
  },
  "results": {
    "cold_start_1": "PASS",
    "cold_start_2": "PASS",
    "determinism": "PASS",
    "ledger_digest": "PASS"
  },
  "ledger_digest_hex": "<64 hex chars>",
  "notes": []
}
```

### Verification

```bash
cd ~/src/tsunagi-follower/tsunagi-node
zig build -Doptimize=ReleaseSafe

SNAP=~/tsunagi-home-mainnet/tsf/mainnet-20260302-030000.tsf
DIR=$(./zig-out/bin/tsunagi-node evidence-pack \
    --cold-start --snapshot "$SNAP" --net mainnet --out /tmp --strict \
    | tail -n 1)
echo "DIR=$DIR"
(cd "$DIR" && sha256sum -c SHA256SUMS)
python3 -c "import json; m=json.load(open('$DIR/manifest.json')); print(f'determinism={m[\"results\"][\"determinism\"]}'); print(f'digest={m[\"ledger_digest_hex\"]}')"
```

## v4.1.0 — Signed Snapshot Envelope + Mutation Suite

### Purpose

Proves Ed25519 snapshot signing and verification works correctly: sign a TSF,
verify it, run 7 adversarial mutations (all must be rejected), produce a
self-contained evidence directory. Zero secrets by design.

Tooling only. Offline. No runtime changes. No forging/broadcast/injection.

### Snapshot-Proof Mode

```bash
tsunagi-node evidence-pack \
    --snapshot-proof \
    --file <path/to/snapshot.tsf> \
    --keydir <dir> \
    --net <preview|preprod|mainnet|sancho> \
    [--out <dir>] \
    [--strict]
```

Or standalone:

```bash
tsunagi-node snapshot-proof \
    --file <path/to/snapshot.tsf> \
    --keydir <dir> \
    [--out <dir>] \
    [--net <name>] \
    [--strict]
```

### How It Works

1. Validate TSF, read header (slot, block_no), compute SHA256
2. Handle keys: check keydir, run `snapshot-keygen` if needed, write `pubkey_hex.txt`
3. Verify original TSF (may FAIL if unsigned — recorded but not fatal)
4. Sign TSF via `snapshot-sign` subprocess
5. Verify signed TSF (MUST PASS)
6. Run 7-mutation adversarial suite:

| Mutation | What | Expected Exit |
|----------|------|---------------|
| `tail_flip` | XOR byte at filesize-1024 | 2 (INVALID) |
| `head_flip` | XOR byte at offset 16 | 2 (INVALID) |
| `truncate` | Copy minus last byte | 2 (INVALID) |
| `append` | Copy + null byte at end | 2 (INVALID) |
| `random_sig` | Copy TSF + 89 random bytes as .sig | 2 (INVALID) |
| `missing_sig` | Copy TSF, no .sig | 1 (FileNotFound) |
| `sig_swap` | Copy TSF + another .tsf.sig | 2 (INVALID) or SKIP |

7. Zero-secrets scan (5MB, `pubkey_hex.txt` exception)
8. Write manifest, SHA256SUMS

### Snapshot-Proof Evidence Directory

```
tsunagi_snapshot_proof[_<net>]_<unix>/
  manifest.json
  SHA256SUMS
  version.txt
  checks/
    verify_original.txt
    verify_signed.txt
    mutation_report.json
  inputs/
    snapshot_info.json
    pubkey_hex.txt
```

### Snapshot-Proof Manifest Schema

```json
{
  "version": "...",
  "unix": 1709337600,
  "strict": true,
  "mode": "snapshot_proof",
  "snapshot": {
    "path": "/path/to/snapshot.tsf",
    "basename": "snapshot.tsf",
    "sha256": "<64 hex chars>",
    "bytes": 123456789,
    "slot": 123456,
    "block_no": 12345
  },
  "pubkey_hex": "<64 hex chars>",
  "results": {
    "verify_original": "PASS|FAIL",
    "verify_signed": "PASS",
    "mutation_suite": "PASS"
  },
  "notes": [...]
}
```

### Verification

```bash
cd ~/src/tsunagi-follower/tsunagi-node
zig build -Doptimize=ReleaseSafe

BIN=./zig-out/bin/tsunagi-node
TSF=~/tsunagi-home-mainnet/tsf/mainnet-20260303-074715.tsf
KEYDIR=~/.local/tsunagi/keys
DIR=$($BIN snapshot-proof --file "$TSF" --keydir "$KEYDIR" --out /tmp --strict | tail -n 1)
echo "DIR=$DIR"
(cd "$DIR" && sha256sum -c SHA256SUMS)
python3 -c "import json; print(json.dumps(json.load(open('$DIR/manifest.json')), indent=2))"
cat "$DIR/checks/mutation_report.json"
```

## v4.3.0 — Pubkey Embedding in Envelopes

Cold-start and snapshot-related evidence envelopes now include the snapshot
verification public key at:

```
inputs/snapshot_pubkey.pub
```

This is the hex-encoded Ed25519 public key (public information; no secrets).
The manifest records:

- `snapshot.pubkey_sha256` — SHA256 of the embedded pubkey file
- `snapshot.pubkey_path_in_envelope` — path within the envelope
- `snapshot.pubkey_len_bytes` — file size in bytes
- `snapshot.pubkey_format` — key format identifier

### Portable verification using the embedded pubkey

```bash
# After producing an envelope:
DIR=<envelope_dir>
cd "$DIR"
sha256sum -c SHA256SUMS

# Verify the snapshot using the embedded pubkey:
tsunagi-node snapshot-verify \
    --file <snapshot.tsf> \
    --pubkey-file "$DIR/inputs/snapshot_pubkey.pub"
```

## v4.4.0 — GPG Notarization (Detached Signatures)

### Purpose

Optionally notarize evidence envelopes with GPG detached signatures.
Makes envelopes cryptographically publishable: third parties can verify
both integrity (SHA256SUMS) and authorship (GPG signatures).

Tooling only. Offline. No secrets in envelope (only `.asc`/`.sig` files).

### New Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--notarize-gpg` | off | Enable GPG detached signing |
| `--gpg-key <id>` | (none) | Key ID or fingerprint passed to `gpg --local-user` |
| `--gpg-homedir <path>` | (none) | Custom GNUPGHOME passed to `gpg --homedir` |
| `--gpg-armor` | off | Produce ASCII-armored `.asc` files instead of binary `.sig` |

### Create a Notarized Envelope

```bash
./zig-out/bin/tsunagi-node evidence-pack \
    --home ~/tsunagi-home-mainnet \
    --net mainnet \
    --out /tmp \
    --limit 50 \
    --strict \
    --notarize-gpg \
    --gpg-homedir ~/.local/tsunagi/gpg-notary \
    --gpg-key <FINGERPRINT> \
    --gpg-armor
```

### Integrity Order

1. All envelope files are written (inputs, checks, manifest, version.txt)
2. SHA256SUMS is computed (excluding itself)
3. `manifest.json` and `SHA256SUMS` are signed (detached)
4. SHA256SUMS is recomputed to include the signature files

### Verify Integrity

```bash
cd <envelope_dir>
sha256sum -c SHA256SUMS
```

### Verify Signatures

```bash
gpg --verify manifest.json.asc manifest.json
gpg --verify SHA256SUMS.asc SHA256SUMS
```

(Use `.sig` instead of `.asc` if `--gpg-armor` was not used.)

### Notes

- If `--notarize-gpg` is not set, behavior is unchanged (no gpg calls).
- If `--notarize-gpg` is set and gpg is missing or signing fails, exit code is 2.
- Public key distribution is out-of-band; the envelope never contains private keys.
