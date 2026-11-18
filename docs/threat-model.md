# Tsunagi Threat Model and Trust Boundaries

**Version:** 1.2.1
**Date:** 2026-02-23
**Status:** Active

---

## A. System Overview

### What Tsunagi Is

Tsunagi is a Zig-native Cardano node that operates as a **Node-to-Node (NtN) ChainSync follower** with **producer observability**. It connects to Cardano relay peers via the Ouroboros mini-protocol multiplexer, follows the chain, and evaluates the full Praos leader election pipeline for a configured stake pool — without ever producing or broadcasting blocks.

### What Tsunagi Is NOT

- **Not a block-producing node.** No block construction or emission code exists.
- **Not a relay.** Does not re-serve chain data to other peers.
- **Not a wallet.** Holds no spending keys and cannot sign transactions on behalf of users.
- **Not a consensus participant.** Observes consensus outcomes but does not vote, propose, or finalize.

### Key Components

| Component | Purpose |
|-----------|---------|
| NtN ChainSync follower | Follows chain tip from upstream relay peers |
| Producer decision surface | VRF prove/verify, Praos threshold math, KES lifecycle enforcement |
| Artifact system (Pack v3) | Cryptographically closed proof bundles (header, body, VRF, KES, signatures) |
| Regression harnesses | Deterministic self-tests: `schedule-regress`, `praos-regress`, `kes-selftest`, `producer-regress` |
| Metrics surface | `/state` (JSON) and `/metrics` (Prometheus) on `127.0.0.1:9080` |
| LMDB state store | Local ledger state for chain validation and replay |

### Core Safety Invariants

Every Tsunagi build enforces two non-negotiable invariants:

- **`no_forging = true`** — No block header is ever constructed for chain submission.
- **`no_broadcast = true`** — No block, transaction, or protocol message is ever broadcast to the network.

These invariants are encoded in every Pack v3 metadata snapshot and verified by `pack-verify` (21 integrity checks). Violation of either invariant causes verification failure.

---

## B. Assets to Protect

### Cryptographic Keys

| Asset | Risk Level | Description |
|-------|------------|-------------|
| VRF secret key (`vrf.skey`) | **High** | Proves slot leader eligibility. Leakage allows eligibility computation by third parties. |
| KES secret key | **Medium** (currently placeholder) | Used for block header signing. Currently placeholder-only (Ed25519). Future real KES evolution will elevate risk to **Critical**. |
| Pool operator ID | **Low** | Public identifier. Not secret, but links observations to a specific pool. |

### Operational State

| Asset | Description |
|-------|-------------|
| `$TSUNAGI_HOME` | Root directory containing LMDB databases, proof packs, snapshots, captures, and regression baselines. Compromise allows state manipulation. |
| LMDB databases | Chain state, UTXO sets, block index. Corruption requires full resync or snapshot restore. |
| Pack artifacts | Proof bundles under `$TSUNAGI_HOME/producer/pack/`. Contain VRF proofs, KES signatures, and candidate headers. |
| Regression baselines | `$TSUNAGI_HOME/regress/*.json`. Poisoning causes false-positive regression passes. |

### Release Artifacts

| Asset | Description |
|-------|-------------|
| GitHub Release tarball | `tsunagi-node-vX.Y.Z-linux-amd64.tar.gz` — compiled binary. |
| SHA256SUMS | Integrity file for release verification. |

### Operator Truth Surface

| Asset | Description |
|-------|-------------|
| `/state` endpoint | JSON representation of full node state. Operator decisions rely on its accuracy. |
| `/metrics` endpoint | Prometheus-compatible metrics. Monitoring and alerting depend on its integrity. |

---

## C. Trust Boundaries

### 1. Network Boundary

**Principle:** All data received from peers is untrusted.

Tsunagi connects to Cardano relay nodes via NtN ChainSync. Peer data MUST be validated before any internal state update.

**Implemented guards:**

| Guard | Limit | Source |
|-------|-------|--------|
| Transaction size | 64 KB max | `mempool.zig` |
| Block fetch message | 2 MB max | `blockfetch.zig` |
| Mempool capacity | 1,024 items / 8 MB | `mempool.zig` |
| Witness items per tx | 64 max | `mempool.zig` |
| Rollback flap detection | >5 rollbacks per 60s window | `follower.zig` |
| Chain density guard | EMA-smoothed density with violation streaks and escalating penalties | `follower.zig` |
| Convergence gate | 600-second stability window before state transitions | `follower.zig` |
| Body hash verification | Blake2b256 recompute on every fetched block (era-aware) | `block_hash.zig` |
| Transaction broadcast | Disabled by default (`TSUNAGI_TXSUB_BROADCAST` env gate, default OFF) | `txsubmission.zig` |

### 2. File Boundary

**Principle:** `$TSUNAGI_HOME` MUST be under the operator's exclusive control.

The systemd service unit restricts filesystem access:

| Directive | Effect |
|-----------|--------|
| `ProtectHome=true` | Hides home directory from process |
| `ProtectSystem=strict` | Read-only root filesystem |
| `ReadWritePaths=%h/tsunagi-home-mainnet` | Only explicit paths writable |
| `ReadOnlyPaths=%h/.local/tsunagi` | Binary installation read-only |
| `PrivateTmp=true` | Isolated temporary directory |

Operators SHOULD ensure `$TSUNAGI_HOME` is owned by the service user with mode `0700` or `0750`.

### 3. Crypto Boundary

**Principle:** All cryptographic proofs MUST be verifiable offline.

| Proof | Verification |
|-------|-------------|
| VRF proof | Verified via libsodium `crypto_vrf_ietfdraft13_verify` against VRF public key |
| Body hash | Blake2b256 recomputed from raw CBOR and compared against header |
| Pack file hashes | Per-file Blake2b256 recorded in `pack.json`, verified by `pack-verify` |
| Producer state digest | 12-field deterministic Blake2b256 per tick, reproducible via `producer-regress` |
| Header hash | Blake2b256 of raw header bytes, verified against `pack.json` |

### 4. Release Boundary

**Principle:** Release artifacts MUST be traceable to a specific commit and verifiable.

| Control | Description |
|---------|-------------|
| Milestone gate | Only `.0` tags trigger GitHub Releases (build + publish workflow) |
| SHA256SUMS | Published alongside every release tarball |
| Tag signing | Annotated tags (`git tag -a`) with descriptive messages |
| CI pipeline | Build, runtime smoke test, package, and publish in isolated GitHub Actions runners |

---

## D. Attacker Model

### 1. Malicious Relay / Peer

**Access:** Network-level. Can send arbitrary Ouroboros protocol messages.

**Capabilities:**
- Send malformed or oversized CBOR
- Trigger rapid rollbacks (rollback storms)
- Manipulate chain density (withhold or flood blocks)
- Send blocks with invalid body hashes

**Constraints:**
- Cannot inject data into `$TSUNAGI_HOME` directly
- Cannot bypass CBOR size guards
- Cannot influence VRF/KES key material

### 2. Local Attacker (User-Level Access)

**Access:** Shell access on the same machine, same or different user.

**Capabilities:**
- Read key files if permissions are lax
- Modify `$TSUNAGI_HOME` contents (LMDB, packs, baselines)
- Tamper with regression baselines to mask divergence
- Replace the binary or symlink target

**Constraints:**
- Cannot bypass systemd sandboxing if running as a different user
- Cannot modify files outside `ReadWritePaths` while service is running

### 3. Remote Attacker (No Shell Access)

**Access:** Network only. No SSH, no local account.

**Capabilities:**
- Port scan; discover 9080 if exposed beyond localhost
- Read `/state` and `/metrics` if port 9080 is reachable (information disclosure)

**Constraints:**
- Port 9080 binds to `127.0.0.1` by default — not externally reachable without explicit forwarding
- No write endpoints exist on the HTTP server
- Cannot influence node state via HTTP

### 4. Supply Chain Attacker

**Access:** Compromise of build pipeline, GitHub account, or dependency.

**Capabilities:**
- Publish a tampered release tarball
- Modify SHA256SUMS to match tampered binary
- Inject malicious code into a dependency

**Constraints:**
- Zig-only policy eliminates most dependency attack surface (no npm, pip, cargo)
- Only one external C library (IOHK libsodium for VRF) — built from source in CI
- SHA256SUMS allows independent verification
- Milestone gate limits release frequency to intentional milestones

### 5. Key Compromise Attacker

**Access:** Possession of stolen VRF and/or KES secret keys.

See Section F for detailed scenarios.

---

## E. Threats and Mitigations

| # | Threat | Impact | Mitigation | Residual Risk |
|---|--------|--------|------------|---------------|
| 1 | **Replay attack** — old pack reintroduced as current | Operator sees stale eligibility data | Pack contains `slot`, `epoch`, `unix` timestamps; slot monotonicity detectable. Per-file Blake2b256 prevents content substitution. | Low — requires file-level access to TSUNAGI_HOME |
| 2 | **VRF manipulation** — invalid proof injected into pack | False eligibility claim | `pack-verify` validates VRF proof against public key via libsodium. Invalid proof = FAIL. | Low — cryptographic guarantee |
| 3 | **KES misuse** — signing outside valid period | Invalid signature in pack | KES lifecycle enforcement (v1.1.2): period bounds checked every tick, out-of-range signing refused, `kes_out_of_range_total` metric incremented. | Low — currently placeholder only; future real KES requires renewed attention |
| 4 | **Pack tampering** — file edits or swaps | Corrupted proof bundle | `pack-verify` performs 21 checks: file sizes, Blake2b256 hashes, VRF proof verification, body hash recompute, safety invariant check. Any mismatch = FAIL. | Very low |
| 5 | **State digest drift** — silent regression in decision logic | Producer pipeline produces different results after rebuild | `producer-regress` hashes full 12-field decision surface (144 bytes/tick) across 2000 slots. Baseline comparison detects any drift. Three additional harnesses cover schedule, Praos, and KES independently. | Very low — 4 independent regression harnesses |
| 6 | **DoS via oversized CBOR** — peer sends large payloads | Memory exhaustion, crash | Hard limits enforced: 64 KB per transaction, 2 MB per block fetch message, 8 MB mempool total, 64 witness items max. Exceeding any limit = immediate rejection. | Low |
| 7 | **Sandbox escape** — process breaks systemd confinement | Arbitrary file access | 11 hardening directives: `NoNewPrivileges`, `MemoryDenyWriteExecute` (W^X), `ProtectSystem=strict`, `ProtectHome=true`, `RestrictNamespaces`, `RestrictSUIDSGID`, `LockPersonality`, `SystemCallArchitectures=native`, `PrivateTmp`, `ReadWritePaths` (explicit allowlist), `MemoryMax=6G`. | Very low — defense in depth via kernel enforcement |
| 8 | **Accidental forging** — code path creates a valid block | Unauthorized block on network | `no_forging=true` invariant hardcoded. No block construction code exists in the codebase. `pack-verify` rejects packs where `no_forging` is false. `no_broadcast=true` prevents any network emission even if a block were somehow constructed. | Negligible — structural impossibility |

---

## F. Key Compromise Scenarios

### VRF Secret Key Leaked

**What the attacker CAN do:**
- Compute slot eligibility for any epoch using the leaked key
- Generate valid VRF proofs for arbitrary slots
- Determine the pool's leader schedule in advance

**What the attacker CANNOT do:**
- Broadcast blocks — `no_broadcast=true` is enforced at the protocol layer
- Forge blocks — `no_forging=true`; no block construction code exists
- Modify the on-chain stake distribution or pool registration
- Sign blocks with the pool's KES key (separate key material)

**Impact:** Information disclosure (leader schedule). No direct chain impact.

### KES Secret Key Leaked

**Current state (placeholder signing):**
- KES signing uses `KES_PLACEHOLDER_ED25519` — a deterministic Ed25519 scheme
- No real KES evolution is implemented
- Leaked placeholder key allows signature reproduction but these signatures have no on-chain validity

**Future state (real KES):**
- A leaked real KES key combined with a leaked VRF key would allow block forging by a separate node
- This risk is mitigated by the `no_forging` and `no_broadcast` invariants in Tsunagi itself, but an attacker with both keys could use a different tool to forge

**Impact:** Currently negligible (placeholder). Future real KES elevates to critical if both VRF and KES are compromised.

### Recommended Operator Response

If key compromise is suspected:

1. **Rotate keys immediately.** Generate new VRF and KES key pairs. Update pool registration on-chain.
2. **Invalidate affected packs.** Delete pack artifacts generated with the compromised keys from `$TSUNAGI_HOME/producer/pack/`.
3. **Re-seed TSUNAGI_HOME.** Regenerate regression baselines (`--init-baseline` for all harnesses).
4. **Audit access logs.** Review systemd journal and file modification timestamps.
5. **Rebuild and redeploy.** Build from a known-good commit. Verify SHA256SUMS.

---

## G. Future Hardening Roadmap

| Area | Status | Notes |
|------|--------|-------|
| Real KES evolution | Planned | Replace placeholder Ed25519 with proper KES key evolution. Elevates KES key to critical asset. |
| Formal pack/snapshot signatures | Planned | Ed25519 signatures over pack.json and snapshot manifests. Enables third-party verification without trusting the filesystem. |
| NtC hardening | Future | Node-to-Client protocol surface for local tools. Requires separate threat analysis. |
| Mempool observer surface | Future | Read-only mempool observation introduces new information disclosure vectors. |
| Forge gate (v2.0.0) | Design phase | Opt-in block production capability. MUST be disabled by default. MUST require explicit operator action to enable. Activation SHOULD require multi-step confirmation. |

---

## Document History

| Version | Date | Change |
|---------|------|--------|
| 1.2.1 | 2026-02-23 | Initial threat model |
