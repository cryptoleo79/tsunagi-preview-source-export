# Propagation Architecture — ADR (v4.4.0)

**Status:** Accepted
**Scope:** Design decision for real block propagation via Tsunagi.
**Audience:** Operators, contributors, auditors.

---

## A) Terminology

**Propagation** — An operator-controlled cardano-node relay learns a new header
from Tsunagi over ChainSync (server), requests the matching block bytes over
BlockFetch (server), validates, then propagates onward using cardano-node's
existing network. This is real N2N block transport.

**Injection** — Writing forged blocks into Tsunagi's own follower chain
selection or tip. Explicitly forbidden in all phases.

**Forging** — Local block construction (forge-sim). Produces artifacts on disk.
Forging is NOT propagation; propagation is serving those artifacts to a relay.

**ChainSync server** — Tsunagi acts as a miniprotocol server: advertises
headers to a connected peer via RollForward messages.

**BlockFetch server** — Tsunagi serves block bytes when a peer requests a
specific point range.

**Preview-only propagation harness** — A guarded mode where propagation is
enabled only on preview network, behind explicit operator opt-in, with
allowlisted peers and fail-closed safety gates.

**Relay boundary model** — Tsunagi serves only operator-controlled relay(s).
Those relays handle onward propagation to the wider Cardano network. Tsunagi
never acts as a general-purpose relay.

---

## B) Current State (v4.4.0)

Tsunagi can:

- Forge-sim locally (dry-run block construction from LMDB + mempool artifacts)
- Verify KES signatures, body hashes, tx inclusion
- Write forge-sim artifacts to disk
- Produce strict evidence-pack envelopes with SHA256SUMS
- Notarize envelopes with GPG detached signatures (v4.4.0)
- Cold-start determinism proofs, signed snapshot envelopes, mutation suites

Tsunagi does NOT:

- Provide an N2N server for ChainSync or BlockFetch
- Transport block bytes to any peer
- Implement a "broadcast gate" on the wire — current discipline is
  receipts/evidence only, not on-wire block transport

TxSubmission is NOT block propagation. Submitting a transaction to a node's
mempool is unrelated to advertising and serving a newly forged block.

---

## C) Cardano N2N Reality (Load-Bearing)

For a cardano-node relay to accept and propagate a block produced by Tsunagi,
the following N2N flow must occur:

1. **ChainSync**: The relay connects to Tsunagi. Tsunagi sends a RollForward
   message containing the new block header. The relay learns the header.
2. **BlockFetch**: The relay requests the full block bytes for the header's
   point (slot + hash). Tsunagi serves the exact block CBOR.
3. **Validation + propagation**: The relay validates the block (header hash,
   body hash, KES, VRF, ledger rules). On success, it advertises the header
   to its own peers, who fetch from it in turn.

**Conclusion:** To propagate a block, Tsunagi must implement at minimum
ChainSync server + BlockFetch server over N2N mux framing.

---

## D) Design Goals

- **Minimal protocols**: ChainSync server + BlockFetch server. KeepAlive only
  if the peer requires it to maintain the connection.
- **Minimal peers**: Serve only operator-controlled relay(s) via allowlist
  (IP/CIDR or explicit address list). Default: no peers allowed.
- **Preview-first**: Initial implementation restricted to preview network.
- **No injection**: Tsunagi MUST NOT feed forged blocks into its own follower
  chain selection or tip. The NO_INJECT invariant is always on.
- **Determinism**: Serve exact bytes from forge-sim artifacts on disk. Never
  re-encode or re-serialize block CBOR.
- **Operator observability**: Write receipts for every served header and block.
  Bounded logs. Fail-closed on any error.

---

## E) Threat Model + Safety Gates

Hard refuses for the implementation phase:

| Gate | Condition | Action |
|------|-----------|--------|
| Network guard | `net != preview` | Refuse to start propagation server |
| TxSub conflict | `TSUNAGI_TXSUB_BROADCAST` is set | Refuse (mutually exclusive modes) |
| Fork readiness | `fork_readiness` not PASS | Refuse to serve blocks |
| Guardian arm | No valid guardian arm token (TTL-based) | Refuse to serve blocks |
| Peer allowlist | Connecting peer not in allowlist | Drop connection immediately |
| KES validity | KES key invalid or within expiry threshold | Refuse to serve blocks |
| NO_INJECT | Always | Never write served blocks into own chain state |

All gates are fail-closed: if any check cannot be evaluated, propagation
does not proceed. No fallback, no override.

---

## F) Architectural Options

### Option 1 (Recommended): Relay-boundary propagation harness

Tsunagi runs an N2N server (ChainSync + BlockFetch) and serves only
operator-controlled relay(s). Those relays propagate to the network.

- **Pros**: Minimal attack surface. Real end-to-end N2N propagation.
  Tsunagi stays lightweight — it is a block producer, not a relay.
  Operator retains full control of relay topology.
- **Cons**: Requires net/* server implementation (handshake, mux, ChainSync
  server, BlockFetch server). Non-trivial but bounded.

### Option 2: Full relay mode

Tsunagi becomes a general relay peer — accepts inbound connections from
arbitrary nodes, serves blocks to anyone.

- **Pros**: Pure Tsunagi propagation without relay dependency.
- **Cons**: Massive scope increase. Tsunagi becomes a full relay node.
  Contradicts "keep node non-gigantic" goal. Large attack surface.

### Option 3: Out-of-band propagation

Copy forge-sim artifacts to disk, then inject into a cardano-node using
external tooling (cardano-cli, custom scripts).

- **Pros**: Minimal code changes to Tsunagi.
- **Cons**: Not real N2N propagation. Fragile integration. No receipt chain.
  Operator must manually bridge artifacts. Not auditable as a single flow.

### Decision

**Option 1 — Relay-boundary propagation harness.**

Provides real block propagation with minimal surface. Tsunagi serves exactly
one purpose (produce + serve blocks to operator relays) and the relay handles
network-wide propagation. This preserves Tsunagi's lightweight architecture
while achieving genuine N2N block transport.

---

## G) Protocol Plan (Minimum Viable Correctness)

No code in this section — message-level needs only.

**Handshake server**: Accept N2N handshake from relay peer. Negotiate preview
network magic + protocol versions. Reject non-preview. Existing mux/framing
infrastructure is reusable.

**ChainSync server**:

- `MsgFindIntersect`: Respond with intersection point from Tsunagi's known
  chain. Required for the relay to synchronize.
- `MsgRollForward`: Advertise the new block header when a forge-sim artifact
  is armed and ready. Include slot, hash, and header bytes.
- `MsgRollBackward`: Minimal handling — if Tsunagi's view changes (e.g.,
  the operator disarms), send rollback to the previous stable point.
  Bounded history (last N headers served).

**BlockFetch server**:

- `MsgRequestRange`: Relay requests block bytes for a point range.
- `MsgBlock`: Serve the exact `block.cbor` bytes from the forge-sim artifact
  directory. No re-encoding.
- `MsgBatchDone`: Signal end of batch.

**KeepAlive**: Respond to KeepAlive pings if the relay sends them. Required
to prevent connection timeout on idle connections.

---

## H) Acceptance Criteria (v4.5.0)

With preview forge enabled and guardian-armed:

1. Tsunagi writes forge-sim artifacts (existing flow, unchanged)
2. Operator-controlled relay connects to Tsunagi N2N server
3. Relay receives RollForward with the forged block header
4. Relay requests block via BlockFetch and receives exact `block.cbor` bytes
5. Relay logs show block acceptance and onward propagation to its peers
6. No injection occurs in Tsunagi (NO_INJECT invariant holds)
7. Allowlist is enforced — non-allowlisted connections are dropped
8. Receipts are written: `served_header` + `served_block` with timestamps
9. Evidence-pack can include propagation receipts in a future envelope version

---

## I) Milestone Roadmap

| Version | Title | Scope |
|---------|-------|-------|
| **v4.5.0** | Preview-only relay-boundary propagation harness | ChainSync + BlockFetch server; peer allowlist; NO_INJECT invariant; receipts; preview network only. |
| **v4.6.0** | Minimal rollback support for served headers | RollBackward handling; bounded header history; graceful disarm mid-serve. |
| **v4.7.0** | Mainnet guarded propagation harness | Mainnet network guard unlock; requires strict envelopes + signed snapshots + GPG notarization stabilized; additional guardian gates. |

---

## v4.5.0 — Implementation Run

### Command

```bash
tsunagi-node propagate-serve \
    --net preview \
    --artifact-dir <forge_sim/UNIX_SLOT/> \
    --allowlist <ip1,ip2,...> \
    [--port 3033] \
    [--arm-token <path>] \
    [--receipts-dir <dir>]
```

### Flags

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--net` | yes | — | Must be `preview` (hard refuse otherwise) |
| `--artifact-dir` | yes | — | Sealed forge-sim directory (must contain header.cbor, block.cbor, meta.json) |
| `--allowlist` | yes | — | Comma-separated peer IPs allowed to connect |
| `--port` | no | 3033 | TCP listen port for N2N server |
| `--arm-token` | no | — | Guardian arm token file (unix_expiry on first line) |
| `--receipts-dir` | no | artifact-dir | Where to write propagation_receipt.json |

### Safety Gates

All gates are fail-closed. Propagation harness refuses unless:

1. `--net preview` (hard refuse for any other network)
2. `TSUNAGI_TXSUB_BROADCAST` is NOT set
3. `--artifact-dir` exists and contains header.cbor + block.cbor + meta.json
4. `--allowlist` is non-empty and connecting peer IP matches
5. `--arm-token` valid and not expired (if provided)
6. NO_INJECT: follower tip must not change during serve

### Sealed Artifact Directory

```
forge_sim/<unix>_<slot>/
  header.cbor     — exact header bytes (served via ChainSync RollForward)
  block.cbor      — exact block bytes (served via BlockFetch)
  meta.json       — {"slot": N, "header_hash": "<64hex>", ...}
```

Bytes are served exactly as on disk. No re-encoding.

### Receipt

Written to `<receipts-dir>/propagation_receipt.json`:

```json
{
  "peer_ip": "10.0.0.2",
  "served_slot": 12345,
  "served_header_hash_hex": "abcd...",
  "served_header": true,
  "served_block": true,
  "tip_before": "<sha256hex>",
  "tip_after": "<sha256hex>",
  "no_inject_ok": true
}
```

`no_inject_ok` is true if and only if `tip_before == tip_after`.

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Served successfully, no_inject_ok |
| 1 | Safety gate refused |
| 2 | Serve error or NO_INJECT violation |
| 3 | Missing artifact files |
| 4 | Parse / argument errors |

### Protocol Flow

1. Relay connects to Tsunagi on `--port`
2. Tsunagi receives N2N Propose, verifies preview magic, sends Accept
3. Relay sends ChainSync FindIntersect → Tsunagi responds IntersectNotFound + tip
4. Relay sends RequestNext → Tsunagi sends RollForward with sealed header
5. Relay sends BlockFetch RequestRange for the header's point → Tsunagi sends StartBatch + Block + BatchDone
6. Tsunagi writes receipt with no_inject_ok check and exits

---

## J) v4.5.24 — Fragment Skip Revert and Fetchable-Body Guardrail

**Status:** Accepted (revert) + Future constraint documented

### What happened

v4.5.23 attempted to skip fragment successor headers in ChainSync RollForward
to avoid advertising headers without fetchable block bodies. This violated
ChainSync header continuity: the relay expects the contiguous successor chain
after RollBackward. Jumping from the intersection point directly to the sealed
tip caused `HeaderEnvelopeError (UnexpectedBlockNo)` because intermediate
block numbers were missing.

### v4.5.24 action

Reverted fragment-skip. Fragment successor headers are served contiguously
via RollForward after RollBackward, followed by the sealed tip header.

### Constraint for next milestone

TSUNAGI must not advertise headers unless their block bodies are fetchable
via BlockFetch. The relay will request block bodies for every RollForward'd
header. Currently, only the sealed tip has a block body (`block.cbor`);
fragment entries have header CBOR only.

The correct solution is NOT to skip headers (breaks continuity) but to
provide bounded block bodies for all advertised successor headers. This
requires a **body-strip artifact**: `seal-tip` must capture block bodies
for fragment successor entries, not just headers. Scope is bounded — only
the contiguous fragment between intersection and sealed tip needs bodies,
typically 10-30 blocks.

---

## K) v4.5.31 — Propagation Milestone Achieved

**Status:** Complete. Tagged v4.5.31.

### Proof

Live test against a cardano-node preview relay (fully synced, isolated
topology with TSUNAGI as the only peer):

| Protocol step | Result |
|---------------|--------|
| Handshake | Accepted (preview magic=2) |
| ChainSync FindIntersect | `result=found` via fragment hash match |
| ChainSync RollForward | Header served (`served_header=true`) |
| BlockFetch RequestRange | Relay requested block (`bf_rx=1`) |
| BlockFetch StartBatch + Block + BatchDone | Block served (`bf_tx=3`, `served_block=true`) |

### Version lineage

| Version | Contribution |
|---------|-------------|
| v4.5.25 | Bounded fetchable fragment bodies |
| v4.5.26 | Fragment cap 128 to 2160 |
| v4.5.27 | Rollback-stable fragment anchoring |
| v4.5.28 | Header CBOR archive in LMDB |
| v4.5.29 | Fragment-aware ChainSync/BlockFetch serving, persistent loop, ancestor seeding |
| v4.5.30 | Raw-copy fallback stale artifact fix |
| v4.5.31 | Milestone tag (no code change) |

### What this proves

TSUNAGI can serve both headers and blocks to a production cardano-node
over the standard NodeToNode protocol. The relay accepted the header via
ChainSync, requested the block via BlockFetch, and received the complete
block body. This is the acceptance criteria defined in section H.
