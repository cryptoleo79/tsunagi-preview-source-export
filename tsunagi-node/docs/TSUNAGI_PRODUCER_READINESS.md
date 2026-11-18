# TSUNAGI Producer Readiness

Complete reference for the offline-only producer readiness harness,
the READY/NOT_LEADER/NOT_READY contract, and the candidate artifact
bundle.

---

## 1. Scope and Safety Guarantee

The producer readiness harness is an **offline evaluation tool**. It
answers the question: "Would this node be ready to produce a block at
slot N, given these keys and stake parameters?"

### What it does

- Evaluates Praos leadership for a given slot
- Checks KES key validity (period range, expiration)
- Performs KES sign + verify round trip
- Assembles a local candidate block (header + empty body)
- Reports deterministic pass/fail for each check
- Optionally writes offline artifact files

### What it does NOT do

- **No broadcast.** No data is transmitted to any network peer.
- **No peer send.** No socket writes. No protocol messages emitted.
- **No forge path activation.** The follower runtime loop is not modified.
- **No mempool mutation.** Mempool state is not altered.
- **No runtime loop changes.** This is a CLI command, not a runtime subsystem.
- **No block production.** TSUNAGI does not produce blocks on any network.

---

## 2. Module: producer_readiness.zig

**Path:** `src/net/consensus/producer_readiness.zig`

Pure-computation module. No IO. No network. No side effects. No allocator.

### 2.1 Types

```
ReadinessState   { ready, not_leader, not_ready }
CheckStatus      { pass, fail, skip }
LeadershipCheck  { status, u_x1e12, thresh_x1e12, is_leader, reason }
KesCheck         { status, current_period, start_period, remaining_periods, max_periods, expired }
SignVerifyCheck  { status, sign_ok, verify_ok, verify_detail }
CandidateCheck   { status, header_hash, body_hash, header_bytes_len, body_bytes_len }
ReadinessReport  { state, slot, epoch, slot_in_epoch, leadership, kes, sign_verify, candidate }
```

### 2.2 Core Functions

| Function | Purpose |
|----------|---------|
| `vrfOutputToU_x1e12` | Map VRF output to uniform scalar in [0,1) × 1e12 |
| `evaluateLeadership` | Praos threshold check via E34 fixed-point |
| `evaluateKesValidity` | KES period range check |
| `signAndVerify` | Sum6Kes sign on message, then verify with root PK |
| `buildLocalCandidate` | Assemble TSUNAGI header + body candidate |
| `evaluate` | Full evaluation combining all checks |

### 2.3 Dependencies

| Module | What is used |
|--------|-------------|
| `praos_threshold_e34.zig` | `computeThresholdX1e12(stake_x1e9, asc_x1e6)` |
| `kes_sign.zig` | `signSum6Kes`, `extractRootPk` |
| `kes_verify.zig` | `verifySum6Kes` |
| `header_candidate.zig` | `buildCandidateV2` (198-byte header) |
| `body_candidate.zig` | `buildEmptyBodyV1` (≤128-byte body) |
| `cbor_block_body.zig` | `buildEmptyBody` (4-byte wire body) |
| `cbor_block_header_body.zig` | `buildHeaderBodyCborV2` (≤1024-byte header body) |
| `cbor_block_full.zig` | `assembleHeader`, `assembleFullBlock` |

### 2.4 Tests

16 inline tests covering:
- Leadership with zero stake, large stake (leader), max u (not leader)
- KES validity: valid range, expired, before start, boundary
- VRF output boundary values
- Candidate determinism
- Sum6Kes sign + verify round trip
- Wrong PK detection
- Full evaluate: not_leader, not_ready (expired KES), ready (valid key state)
- State and status label strings

---

## 3. ReadinessState Contract

### READY

All of the following must be true:

1. `vrf_available == true` (VRF key loaded and prove succeeded)
2. `leadership.status == .pass` (stake > 0, threshold computed)
3. `leadership.is_leader == true` (u_x1e12 < thresh_x1e12)
4. `kes.status == .pass` (period within valid range)
5. `sign_verify.status == .pass` (not .fail, not .skip)
6. `candidate.status == .pass`

If any condition fails, the state is NOT READY.

### NOT_LEADER

All of the following must be true:

1. `leadership.status == .pass`
2. `leadership.is_leader == false` (u_x1e12 >= thresh_x1e12)
3. `kes.status == .pass`
4. `vrf_available == true`

The node has all material, but the VRF output does not meet the Praos
threshold for this slot.

### NOT_READY

Any of:

- `vrf_available == false` (no VRF key loaded)
- `leadership.status == .fail` (zero stake or zero threshold)
- `kes.status == .fail` (period out of range or expired)
- `sign_verify.status == .fail` (sign or verify error)
- `sign_verify.status == .skip` (no KES key loaded)

### State Logic (exact)

```
state = if (leadership.fail or kes.fail or !vrf_available)
            NOT_READY
        else if (!leadership.is_leader)
            NOT_LEADER
        else if (sign_verify.fail or sign_verify.skip)
            NOT_READY
        else
            READY
```

---

## 4. CLI: producer-ready

**Path:** `src/cli/producer_ready_cmd.zig`

### Usage

```
tsunagi-node producer-ready --slot <N> [options]

Required:
  --slot <N>                  Target slot number

Key material:
  --vrf-skey <path>           VRF signing key file (cardano-cli JSON envelope)
  --kes-skey <path>           KES signing key file (cardano-cli JSON envelope)
  --pool-id <64 hex>          Pool ID (cold verification key hash)

Stake parameters:
  --stake-x1e9 <N>            Stake fraction × 1e9 (e.g., 1000000 = 0.1%)
  --asc-x1e6 <N>              Active slot coefficient × 1e6 (default: 50000)
  --epoch <N>                 Epoch number (default: 0)
  --slots-per-epoch <N>       Slots per epoch (default: 86400)

KES parameters:
  --kes-period <N>            Current KES period (default: 0)
  --opcert-start-period <N>   OpCert start period (default: 0)
  --max-kes-evolutions <N>    Max KES evolutions (default: 62)

Chain state:
  --net-magic <N>             Network magic (default: 2 = preview)
  --tip-block <N>             Tip block number (default: 0)
  --tip-hash <64 hex>         Tip block hash (default: zeros)

Output:
  --out <path>                Write JSON report to file
  --bundle-dir <path>         Write artifact bundle when READY (5 files)
```

### Exit Codes

| Code | State | Meaning |
|------|-------|---------|
| 0 | READY | Leader for slot, all checks pass |
| 1 | NOT_LEADER | Not elected leader for this slot |
| 2 | NOT_READY | Missing material or failed check |
| 3 | (usage) | Invalid arguments |
| 4 | (IO) | File read/write error |

### Sample Output (NOT_READY, no keys)

```json
{
  "slot": 50000,
  "state": "NOT_READY",
  "leadership": { "status": "PASS", "is_leader": true, "u_x1e12": 1, "thresh_x1e12": 51293 },
  "kes": { "status": "PASS", "current_period": 10, "remaining_periods": 57, "expired": false },
  "sign_verify": { "status": "SKIP", "sign_ok": false, "verify_ok": false },
  "candidate": { "status": "PASS", "header_hash": "aea6...", "body_hash": "301b..." },
  "availability": { "has_vrf": false, "has_kes": false, "has_pool_id": false, "has_stake": true }
}
```

State is NOT_READY because `has_vrf: false` triggers `!vrf_available` gate.

---

## 5. Offline Candidate Artifact Bundle

### 5.1 ArtifactBundle Type

**Path:** `producer_readiness.zig` (additive, no modification to evaluate or ReadinessReport)

```
ArtifactBundle
  header_cbor       [1536]u8    Cardano header CBOR (header_body + KES sig bstr)
  header_cbor_len   usize       Actual length
  block_hash        [32]u8      blake2b256(header_cbor) — block identifier on wire
  body_tx_bodies    []const u8  Wire body part (0x80 for empty)
  body_witnesses    []const u8  Wire body part (0x80 for empty)
  body_aux_data     []const u8  Wire body part (0xa0 for empty)
  body_invalid_txs  []const u8  Wire body part (0x80 for empty)
  body_hash         [32]u8      4-part body hash
  body_size         u64         Total body bytes
  block_cbor        [2048]u8    Full block CBOR: [era, [header, body parts...]]
  block_cbor_len    usize       Actual length
  candidate_header  [198]u8     TSUNAGI domain header candidate
  candidate_header_hash [32]u8  Hash of TSUNAGI candidate header
  candidate_body    [128]u8     TSUNAGI domain body candidate (max)
  candidate_body_len u64        Actual length
  candidate_body_hash [32]u8    Hash of TSUNAGI candidate body
```

### 5.2 buildArtifactBundle Function

Pure computation. Same inputs as `evaluate()` minus the stake/threshold
parameters (those are only needed for leadership check). Requires valid
KES key state (cannot build artifacts without signing).

**Steps:**
1. Build empty Cardano body (4 bytes)
2. Build TSUNAGI candidate header + body
3. Build header body CBOR (10-element array, ≤1024 bytes)
4. KES sign header body CBOR
5. Assemble Cardano header CBOR (header_body + KES sig)
6. Assemble full block CBOR ([era, [header, body parts...]])
7. Return all raw bytes and hashes

Returns `null` if KES signing fails.

### 5.3 Artifact Files

Written to `--bundle-dir` when state == READY and `--bundle-dir` is provided.

| File | Content | Size (empty block) |
|------|---------|-------------------|
| `producer-report.json` | Full JSON readiness report | ~1KB |
| `candidate-header.cbor` | Cardano header CBOR bytes | ~1.5KB |
| `candidate-body.cbor` | 4 body parts concatenated | 4 bytes |
| `candidate-block.cbor` | Full block CBOR | ~1.5KB |
| `candidate-hashes.json` | block_hash, body_hash, candidate hashes | ~350 bytes |

### 5.4 Producer Readiness Harness Flow

```
  ┌────────────────────┐
  │  CLI Arguments     │
  │  --slot, --vrf-skey│
  │  --kes-skey, etc.  │
  └─────────┬──────────┘
            │
            ▼
  ┌────────────────────┐
  │  Load VRF Key      │  cardano-cli JSON → seed → keypair → prove
  │  Load KES Key      │  cardano-cli JSON → decode → classify → extract PK
  └─────────┬──────────┘
            │
            ▼
  ┌────────────────────┐
  │  evaluate()        │  Pure computation
  │                    │
  │  1. Leadership     │  VRF output → u_x1e12 vs thresh_x1e12
  │  2. KES validity   │  Period range check
  │  3. Sign + Verify  │  Sum6Kes round trip on header body CBOR
  │  4. Candidate      │  Header + body assembly
  │  5. State          │  READY / NOT_LEADER / NOT_READY
  └─────────┬──────────┘
            │
            ▼
  ┌────────────────────┐
  │  JSON Report       │  → stdout + optional --out file
  └─────────┬──────────┘
            │
            ▼ (only if READY + --bundle-dir)
  ┌────────────────────┐
  │  buildArtifact     │  Pure computation
  │  Bundle()          │
  │                    │
  │  body → header     │
  │  body CBOR →       │
  │  KES sign →        │
  │  Cardano header →  │
  │  full block CBOR   │
  └─────────┬──────────┘
            │
            ▼
  ┌────────────────────┐
  │  Write Artifacts   │  5 files to --bundle-dir
  │  (local disk only) │
  │  NO BROADCAST      │
  └────────────────────┘
```

---

## 6. Producer Status Surface

The producer readiness evaluation is surfaced to operators through a
JSON endpoint and web dashboard integration.

### 6.1 JSON Endpoint

**Generator:** `scripts/generate-producer-status-json.sh`

Invokes the `tsunagi-node producer-bridge` CLI and writes
`producer-status.json` to the web root. This is the first generator
script that invokes the binary directly (all other generators read
journal/ndjson files).

**Output fields:**

| Field | Type | Source |
|-------|------|--------|
| `bridge_state` | string | Bridge evaluation result |
| `reason` | string | Human-readable state explanation |
| `epoch` | int | Current epoch from cursor |
| `slot_in_epoch` | int | Slot position within epoch |
| `kes_period` | int | Current KES period |
| `tip_block` | int | Latest block number |
| `is_leader` | bool | Praos leadership for current slot |
| `candidate_built` | bool | Candidate block assembled |
| `material.vrf` | bool | VRF key available |
| `material.kes` | bool | KES key available |
| `material.pool_id` | bool | Pool ID configured |
| `material.stake` | bool | Stake parameter set |
| `material.count` | int | Available material count (0-4) |
| `material.total` | int | Total required (4) |

**Exit code handling:**

| Exit Code | Bridge State | Operational Meaning |
|-----------|-------------|---------------------|
| 0 | READY_LOCAL_CANDIDATE | Leader, candidate block assembled |
| 1 | NOT_LEADER | Valid material, not elected this slot |
| 2 | NOT_CONFIGURED | Missing VRF, KES, or stake config |
| 3-5 | ERROR / OFFLINE | Usage error, IO error, or binary unavailable |

### 6.2 Dashboard Integration

**Operator dashboard** (`web/operator/index.html`):

- Summary card (7th card in grid) showing state pill, epoch, KES
  period, and 4 material indicator dots (VRF/KES/Pool/Stake)
- Detail panel with full key-value table: state, reason, slot,
  epoch, KES period, tip block, leadership, candidate built,
  material availability, stake fraction
- Fetched alongside 7 other JSON endpoints via Promise.allSettled

**Explorer** (`web/explorer/index.html`):

- Compact "Chain Production Status" bar after Chain Health section
- State pill, epoch, KES period, and material indicators
- Fetched via XMLHttpRequest on 10s interval

**Labs index** (`web/labs/index.html`):

- Producer Readiness card in experiment grid, links to /operator/

### 6.3 Operator-Visible States

| State | Pill Color | Meaning |
|-------|-----------|---------|
| READY_LOCAL_CANDIDATE | Green | Leader for this slot, candidate assembled |
| NOT_LEADER | Blue | Valid material, not elected leader |
| NOT_CONFIGURED | Gray | Missing VRF, KES, pool, or stake config |
| ERROR | Red | Leader but sign/verify failed |
| IDLE | Gray | Bridge idle |
| OFFLINE | Gray | Binary unavailable or unreachable |

### 6.4 Safety Boundary

The status surface is **read-only observation**. It displays the
result of an offline evaluation. No runtime state is mutated, no
protocol messages are sent, and no broadcast path is activated.
The dashboard polls a static JSON file regenerated by cron or
manual script invocation.

---

## 7. Shadow Producer

**Path:** `src/net/consensus/shadow_producer.zig`

Runtime-integrated local-only candidate evaluation. Runs inside the
post-tick `onRollForward` callback in `chainsync_mux_smoke.zig`.
Reads producer state after `producer.tick()`, maps to bridge inputs,
evaluates readiness, and records a `ShadowEvent` per slot.

**Key difference from producer readiness:** Shadow producer runs
continuously at runtime (every slot), not on-demand via CLI. It
never broadcasts. Never sends protocol messages. Pure computation
plus optional local file output (`shadow-last.json`).

**States:** `disabled`, `not_configured`, `not_leader`,
`local_candidate_ready`, `local_candidate_failed`

**Env vars:**
- `TSUNAGI_SHADOW_PRODUCER_ENABLE=1` — enable shadow evaluation
- `TSUNAGI_SHADOW_REPORT_DIR` — directory for `shadow-last.json`
- `TSUNAGI_SHADOW_ARTIFACT_DIR` — directory for candidate CBOR artifacts

---

## 8. Producer Dry-Run Engine

**Path:** `src/net/consensus/producer_dryrun.zig`

Result-model layer that wraps shadow producer output with candidate
validation. Derives a `DryRunEvent` from an existing `ShadowEvent`
plus optional `ValidationState` from `candidate_validator.zig`.

### 8.1 How It Differs

| | Producer Readiness | Shadow Producer | Dry-Run Engine |
|---|---|---|---|
| Execution | CLI on-demand | Runtime per-slot | Runtime per-slot |
| Input | CLI args + keys | ProducerContext post-tick | ShadowEvent + validation |
| Validation | Sign+verify only | None | Full 7-check candidate validation |
| Output | JSON report + artifacts | ShadowEvent + shadow-last.json | DryRunEvent + producer-dryrun-last.json |
| Broadcast | No | No | No |

Dry-run does **not** duplicate Praos/VRF/KES/candidate logic. It
consumes the shadow producer's output and adds validation on top.

### 8.2 How It Differs from Live Production

Live production (future) would:
- Broadcast blocks to peers
- Participate in consensus protocol
- Mutate chain state

Dry-run does **none** of these. It is telemetry only. No broadcast,
no peer send, no mempool mutation, no consensus mutation. Disabled
by default.

### 8.3 Runtime Integration

Integrated in `chainsync_mux_smoke.zig` inside the existing shadow
producer block in `onRollForward`. Flow:

1. Shadow producer evaluates → `ShadowEvent`
2. If dry-run enabled and candidate ready: build artifact bundle,
   run `candidate_validator.validate()` inline
3. `fromShadowAndValidation(shadow_event, validation_state, candidate_valid)`
   → `DryRunEvent`
4. Append to bounded in-memory `DryRunHistory` (capacity 16)
5. Optionally overwrite `producer-dryrun-last.json` (single file, no growth)

No changes to `follower.zig`. No callback signature changes.

### 8.4 Runtime File Output

**File:** `{REPORT_DIR}/producer-dryrun-last.json`

Single JSON line, overwritten on every evaluated slot. No append-only
growth. Written only when `TSUNAGI_PRODUCER_DRYRUN_REPORT_DIR` is set.

```json
{"type":"dryrun_event","slot":106903999,"epoch":1237,
 "slot_in_epoch":32199,"block_no":4108901,"timestamp_unix":1710002000,
 "state":"NOT_LEADER","leadership":false,"candidate_built":false,
 "candidate_valid":false,"validation_state":"null",
 "header_hash":"0000...","body_hash":"0000..."}
```

### 8.5 JSON Endpoint

**Generator:** `scripts/generate-producer-dryrun-json.sh`
**Output:** `producer-dryrun.json`
**Source:** `$TSUNAGI_HOME/producer-dryrun-last.json`

Reads the runtime overwrite file, extracts fields, emits stable JSON.
If source file is missing, emits `"enabled": false` stub. Summary
fields reflect only the last event — no historical counting.

### 8.6 Environment Variables

| Variable | Required | Purpose |
|----------|----------|---------|
| `TSUNAGI_PRODUCER_DRYRUN_ENABLE=1` | Yes | Enable dry-run engine. Auto-enables shadow producer if not already active. |
| `TSUNAGI_PRODUCER_DRYRUN_REPORT_DIR` | No | Directory for `producer-dryrun-last.json`. Created if missing. |
| `TSUNAGI_PRODUCER_DRYRUN_ARTIFACT_DIR` | No | Directory for candidate artifacts. Created if missing. |

### 8.7 Dry-Run States

| State | Meaning |
|-------|---------|
| `disabled` | Dry-run engine not enabled (env var unset) |
| `not_configured` | Shadow producer lacks required material (VRF, KES, pool, stake) |
| `not_leader` | Valid material, VRF output does not meet Praos threshold for this slot |
| `candidate_ready` | Leader, candidate built and validated successfully |
| `candidate_invalid` | Leader, candidate built but validation failed (hash/structure/KES) |
| `candidate_failed` | Leader, but candidate build failed (missing KES key state) |

### 8.8 State Mapping

```
ShadowState.disabled              → DryRunState.disabled
ShadowState.not_configured        → DryRunState.not_configured
ShadowState.not_leader            → DryRunState.not_leader
ShadowState.local_candidate_ready + valid     → DryRunState.candidate_ready
ShadowState.local_candidate_ready + invalid   → DryRunState.candidate_invalid
ShadowState.local_candidate_failed            → DryRunState.candidate_failed
```

### 8.9 Dashboard Integration

**Operator** (`web/operator/index.html`):
- Detail panel with state pill, slot, epoch, block, leadership,
  candidate built/valid, validation state, truncated hashes, age
- Fetched as 9th endpoint in `Promise.allSettled` refresh cycle
- Degrades to "Dry-run not enabled" when disabled or JSON missing

**Explorer** (`web/explorer/index.html`):
- Compact bar below Chain Production Status
- State pill, slot, valid/invalid, truncated header hash
- Fetched via XMLHttpRequest on 10s interval

**Labs** (`web/labs/index.html`):
- Producer Dry-Run card linking to /operator/

### 8.10 Safety Boundary

The dry-run engine is **telemetry only**. It:
- Does not broadcast blocks
- Does not send protocol messages
- Does not mutate mempool or chain state
- Does not activate any forge path
- Is disabled by default
- Requires explicit `TSUNAGI_PRODUCER_DRYRUN_ENABLE=1`
- Produces bounded output only (single overwrite file + 16-slot ring buffer)

---

## 9. Future Path

### Near-term: Artifact Bundle Verification

Once artifacts are written, verification commands can confirm:
- Header CBOR matches expected structure
- KES signature verifies against the PK in the header body
- Body hash matches the 4-part computation
- Block CBOR is valid Cardano era-7 encoding
- All hashes are deterministic (same inputs → same outputs)

### Medium-term: Full KES/VRF/OpCert Alignment

- Test with real preview testnet keys
- Verify KES evolution across multiple periods
- Confirm VRF alignment with cardano-node reference vectors

### Long-term: Live Block Production

Requires:
1. All alignment tests passing
2. Mainnet shadow validation
3. Controlled testnet block production with monitoring
4. Operator tooling for key rotation and monitoring

**Each step requires explicit approval. No automatic activation.**
