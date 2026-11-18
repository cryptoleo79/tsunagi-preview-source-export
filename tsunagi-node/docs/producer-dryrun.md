# Producer Dry-Run Mode (v1.8.0, v1.8.6, v1.8.7, v1.8.8)

## Purpose

Prove the producer candidate pipeline end-to-end — leadership evaluation,
candidate header construction, body hash, and placeholder Ed25519 signing —
without forging, broadcasting, or injecting blocks into the chain.

When enabled, each leader slot writes a set of artifacts to disk and performs
local self-verification (hash match + signature check).

## Safety Invariants

- **NO forging.** Tsunagi does NOT support block forging. `TSUNAGI_FORGE_ENABLE`
  is a hard FATAL guard (exit 99).
- **NO broadcast.** Candidate artifacts are written to local disk only.
- **NO chain injection.** Artifacts are never fed back into chainsync or any
  peer protocol.
- **OFF by default.** Dry-run mode is disabled unless `TSUNAGI_PRODUCER_DRYRUN=1`.
- **Preview only.** Setting `TSUNAGI_PRODUCER_DRYRUN=1` on any network other than
  `preview` causes a FATAL exit (exit 98).

## Environment Variables

| Variable | Values | Description |
|----------|--------|-------------|
| `TSUNAGI_PRODUCER_DRYRUN` | `1` to enable, unset/other to disable | Enable dry-run artifact write + verify |
| `TSUNAGI_FORGE_ENABLE` | **FATAL if set** | Hard safety guard — Tsunagi does not support forging |

## Network Restriction

Dry-run mode is restricted to `--net preview`. Attempting to enable it on
mainnet, sancho, or any other network will cause an immediate exit:

```
FATAL: TSUNAGI_PRODUCER_DRYRUN=1 is only allowed on --net preview
Current network: mainnet
```

## Artifacts

When the producer detects a leader slot in dry-run mode, artifacts are written to:

```
$TSUNAGI_HOME/producer_dryrun/candidates/<unix>_<slot>/
```

Each directory contains:

| File | Description |
|------|-------------|
| `header.cbor` | Raw 198-byte CandidateV2 header encoding |
| `header_hash.hex` | 64 hex characters — blake2b256 of header.cbor |
| `body_hash.hex` | 64 hex characters — body hash (empty CBOR) |
| `signature.bin` | Raw signature (64 bytes for placeholder, 448 bytes for real_kes) |
| `header_body.cbor` | Raw CBOR header body (real_kes only — the signed message) |
| `meta.json` | Metadata: unix, net, slot, block_no, sig_kind, pool_id_hex, etc. |
| `verify.json` | Local verification result: hash_match, sig_verify_ok, sig_kind |

## sig_kind

| Value | Version | Description |
|-------|---------|-------------|
| `none` | v1.8.0 | Hash-only verification, no signature check |
| `placeholder_ed25519` | v1.8.0 | Placeholder Ed25519 signature derived from pool ID |
| `real_kes` | v1.8.6+ | Real Sum6Kes signature (448 bytes, depth 6, 64 periods) |

For v1.8.0, `sig_kind` is `"placeholder_ed25519"` — a placeholder Ed25519
signature derived from the pool ID. This is NOT a real KES signature.

For v1.8.6, `sig_kind` `"real_kes"` uses the actual Sum6Kes verification
algorithm against the raw CBOR header body (direct mode). The signature
is 448 bytes, verified with the KES public key and period offset from meta.json.

For v1.8.7, the producer dryrun pipeline SIGNS with real Sum6Kes when a
`cardano_kes` key is loaded (ed25519_kes_2^6, 608/612 bytes). The signed
message is a simplified CBOR header body. Signatures are immediately
self-verified; FATAL exit(97) on failure or period mismatch.

## CLI: candidate-verify

Offline verification of a candidate artifact directory:

```bash
tsunagi-node candidate-verify --dir <artifact-dir>
```

Exit codes:

| Code | Meaning |
|------|---------|
| 0 | PASS — all checks succeeded |
| 2 | FAIL — verification error (hash mismatch, sig invalid, missing metadata) |
| 3 | ERROR — missing files or invalid arguments |

The verifier:
1. Reads `header.cbor` (must be exactly 198 bytes)
2. Reads `header_hash.hex` and verifies `blake2b256(header.cbor) == header_hash.hex`
3. Reads `meta.json` and detects `sig_kind`
4. Dispatches based on `sig_kind`:
   - **`real_kes`** (v1.8.6): Reads `header_body.cbor` (signed message),
     `signature.bin` (448 bytes), `kes_pk_hex` and `kes_period_offset` from
     `meta.json`. Verifies with Sum6Kes.
   - **`placeholder_ed25519`**: Reads `pool_id_hex` from `meta.json` (preferred)
     or falls back to header byte offset 134..166. Derives Ed25519 keypair from
     pool ID and verifies signature over `header.cbor`.
   - **`none`** or unknown: Hash-only verification (no signature check).
5. Checks required metadata fields (unix, net, slot, sig_kind, candidate_version)

## Prometheus Metrics

10 metrics with prefix `tsunagi_producer_dryrun_`:

| Metric | Type | Description |
|--------|------|-------------|
| `tsunagi_producer_dryrun_enabled` | gauge | 1 if dry-run mode enabled |
| `tsunagi_producer_dryrun_slots_checked_total` | counter | Total slots evaluated |
| `tsunagi_producer_dryrun_leader_slots_total` | counter | Leader slots found |
| `tsunagi_producer_dryrun_candidates_built_total` | counter | Artifacts written |
| `tsunagi_producer_dryrun_candidates_verified_total` | counter | Artifacts locally verified |
| `tsunagi_producer_dryrun_last_leader_slot` | gauge | Most recent leader slot |
| `tsunagi_producer_dryrun_last_candidate_unix` | gauge | Unix time of last artifact |
| `tsunagi_producer_dryrun_last_verify_ok` | gauge | 1 if last verify passed |
| `tsunagi_producer_dryrun_candidates_signed_total` | counter | Candidates signed with real KES (v1.8.7) |
| `tsunagi_producer_dryrun_last_sign_verify_ok` | gauge | 1 if last real KES sign+verify passed (v1.8.7) |

## /state JSON

The `/state` endpoint includes a `producer_dryrun` section:

```json
{
  "producer_dryrun": {
    "enabled": 0,
    "slots_checked_total": 0,
    "leader_slots_total": 0,
    "candidates_built_total": 0,
    "candidates_verified_total": 0,
    "last_leader_slot": 0,
    "last_candidate_unix": 0,
    "last_verify_ok": 0,
    "candidates_signed_total": 0,
    "last_sign_verify_ok": 0
  }
}
```

## Real Cardano KES Keys (v1.8.2)

Real Cardano KES signing keys are stored as JSON with a `cborHex` field
(cardano-cli envelope format). v1.8.2 can ingest and inspect these keys:

```bash
tsunagi-node kes-inspect --key ~/tsunagi-keys/preview-bp/kes.skey
```

The node classifies keys as `placeholder_seed` (32-byte Ed25519 seed),
`cardano_kes` (real MMM-based KES key), or `unknown`.

## Real KES Verification in candidate-verify (v1.8.6)

v1.8.6 extends `candidate-verify` to verify real KES signatures (Sum6Kes,
depth 6, 448 bytes) when `sig_kind` is `"real_kes"` in meta.json.

Additional meta.json fields for real_kes:

| Field | Description |
|-------|-------------|
| `kes_pk_hex` | 64 hex chars — 32-byte KES public key |
| `kes_period_offset` | KES period offset from opcert start (0..63) |
| `signed_msg_mode` | `"direct"` — raw CBOR header body is the signed message |

Additional artifact for real_kes:

| File | Description |
|-------|-------------|
| `header_body.cbor` | Raw CBOR header body bytes (the signed message) |
| `signature.bin` | 448 bytes (Sum6Kes signature, replaces 64-byte placeholder) |

This is verify-only. NO signing, NO forging, NO broadcast.

## Real KES Signing in Producer Dry-Run (v1.8.7)

v1.8.7 adds real Sum6Kes signing to the dryrun pipeline. When a `cardano_kes`
key is loaded (ed25519_kes_2^6, 608 or 612 bytes decoded from cborHex), the
producer signs a simplified CBOR header body with the real key state.

### Key State Format

The key state is a recursive structure (depth 6, 608 bytes + 4-byte period):

```
skSize(d) = 32 + d*96
Depth d: [sub_key(skSize(d-1)) | stored_seed(32) | lhs_pk(32) | rhs_pk(32)]
Depth 0: [Ed25519_secret: 32 bytes]
```

Sizes: sk(0)=32, sk(1)=128, sk(2)=224, ..., sk(6)=608.
With period (big-endian u32): 612 bytes total.

Root PK = blake2b256(lhs_pk || rhs_pk) at the top level (offsets 544..576, 576..608).

### Signed Message

The signed message is a simplified CBOR header body:

```cbor
array(4): [block_number(uint), slot(uint), prev_hash(bstr 32), body_hash(bstr 32)]
```

This is written as `header_body.cbor` in the artifact directory.

### KES Period

```
kes_period_offset = kes_current_period - kes_start_period
```

Where `kes_current_period = slot / 129600` and `kes_start_period` is
`TSUNAGI_KES_START_PERIOD` (corresponds to opcert_kes_period).

The key state's stored period MUST match this offset. FATAL exit(97) on mismatch.

### Key Evolution (v1.8.8)

v1.8.8 adds automatic KES key evolution at runtime. When the key state's
stored period does not match the target offset, the key is evolved forward
using the Cardano KES evolution algorithm:

- `seedSplit(seed)`: `left = blake2b256(0x01 || seed)`, `right = blake2b256(0x02 || seed)`
- At crossing points (left→right half), the right child key state is generated
  from the stored seed, and the stored seed is zeroed (forward security).
- Root PK stability is validated after evolution.

Evolution happens lazily on the first leader slot. 608-byte keys are normalized
to 612-byte form (period suffix initialized to 0) at load time.

Offline CLI: `tsunagi-node kes-evolve --key <kes.skey> --to-period-offset <N> --out <evolved.bin> [--verify]`

### FATAL Exit Codes

| Code | Condition |
|------|-----------|
| 97 | Sum6Kes signing failed, period mismatch, self-verify failure, or evolution failure |
| 98 | Dryrun enabled on non-preview network |
| 99 | TSUNAGI_FORGE_ENABLE set (forging not supported) |

### New Metrics (v1.8.7)

| Metric | Type | Description |
|--------|------|-------------|
| `tsunagi_producer_dryrun_candidates_signed_total` | counter | Candidates signed with real KES |
| `tsunagi_producer_dryrun_last_sign_verify_ok` | gauge | 1 if last real KES sign+verify passed |

## What This Is NOT

- This is NOT a block forge. No blocks are created or broadcast.
- This is NOT a stake pool operator tool. It does not interact with the Cardano network.
- This is NOT production block production. Real KES signing (v1.8.7) produces
  verifiable signatures but the simplified CBOR header body is not a full
  Cardano block header.
- Candidates produced in dry-run mode cannot be submitted to any chain.
