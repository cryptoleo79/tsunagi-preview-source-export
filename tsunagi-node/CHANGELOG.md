# Changelog

All notable changes are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Milestone — June 2026: Compound Opcert Corruption Frontier
The forge self-verify (opcert) frontier was diagnosed and cleared on the live preview relay. It was a
**compound** failure, not a single fault:
- **Seq drift** — per-forge `OPCERT_INCREMENT` walked `opcert_state.json` to `seq_no=15`; the cold-signed
  opcert counter is `0`. `opcert_state.json` (file) silently overrode `TSUNAGI_OPCERT_SEQ` (env).
- **Launcher sigma corruption** — `start-relay-forge.sh` / `tsunagi-auto.sh` exported a mis-sliced region
  of the `node.cert` cborHex (`28a96940…`) as `TSUNAGI_OPCERT_SIGMA_HEX` instead of the real signature
  (`5e3c8839…`). Resetting seq to 0 was necessary but not sufficient; slot 114278360 still failed at
  `seq=0` until the launcher sigma was corrected.
- **Diagnosis & correction** — decoded `node.cert` (counter 0, sigma `5e3c8839…`) as ground truth;
  offline ed25519 confirmed correct-sigma@seq=0 PASS / corrupt FAIL. Operator reset `opcert_state.json`
  to 0 and corrected the launcher sigma; runtime now loads the correct sigma + seq=0.
- **Durability** — the per-forge counter bump is replaced by an opcert counter **pin** (`OPCERT_PIN`,
  no bump). Forge bytes unchanged. See `docs/incidents/2026-06-opcert-self-verify-root-cause.md`,
  `docs/operator/opcert-troubleshooting.md`, `docs/ACCEPTANCE_FRONTIER_STATUS.md`.

### Milestone — June 2026: First Fully-Valid Forge Path / Frontier Moves to Delivery
With the compound opcert corruption resolved, slot **114284040** produced the first fully-clean forge:
`FORGE_SELF_VERIFY pass=YES seq=0` → `FORGE_BLOCK_ENVELOPE_OK era_tag=7` → `FORGE_PROMOTE_ATOMIC
block_no=4361767 hash=1d40f74a336c8854` → `FORGE_PROMOTE_FRAGMENT artifact_coherent=true`. All
forge-correctness frontiers (era tag, sigma gate, authoritative sigma, stale parent, opcert counter,
opcert sigma) are proven closed.
- **Result:** FORGE SUCCESS / ADOPTION FAILURE. The block was orphaned — a same-height competitor
  (`aff6f743` @ slot 114284046) reached cardano-node at +6 s; TSUNAGI's first propagation contact was at
  +9 s, by which point cardano-node was ahead (`relay_newest_slot=114284046`) and declined the body
  (`FetchDeclineChainNotPlausible`, `served_block=false`). `ROLLBACK_CONFIRMED reason=koios_confirmed_loss`.
- **Frontier shift:** the acceptance frontier has moved **from forge correctness to propagation/delivery**
  (Frontier #7A artifact visibility — proven; #7B delivery/adoption latency — active).
- Refs: `docs/incidents/2026-06-slot-114284040-propagation-race.md`,
  `docs/ACCEPTANCE_FRONTIER_STATUS.md`, `docs/C5_DELIVERY_ARCHITECTURE_SPEC.md`.

### Fixed
- Opcert counter pinned to the issued certificate value (no per-forge `OPCERT_INCREMENT`); prevents the seq-drift that broke forge self-verify
- Propagation artifact coherence: FORGE_PROMOTE_ATOMIC now publishes sealed block with coherent fragment ancestry (#68)
- Propagation server rejects incoherent fragment state instead of serving stale ancestry to relay
- ChainSync era index: 6 → 7 (Conway era on preview)
- Pipelining: process all CBOR messages in batched mux segments
- Forge slot: use current_slot (VRF-proven) instead of frag_tail + 1
- Protocol version: [10, 0] → [10, 2]

### Changed
- OPCERT kes_period aligned to runtime KES_START_PERIOD
- Epoch nonce sourced from environment variable
- Codebase migrated from Zig 0.13.0 to Zig 0.15.2 (#67)

### Added
- FORGE_PROMOTE_FRAGMENT: publish-time truth log with coherence verification fields
- ARTIFACT_COHERENCE_TRUTH: serve-time ancestry validation log
- ARTIFACT_READY_TRUTH: artifact readiness verdict with reason code
- Fragment copy uses staged atomic rename (fragment.staging) to prevent half-written state
- Regression tests for artifact coherence: stale fragment rejected, matching fragment preserved, single-header fallback, multi-entry continuity
- ERA_DIAG: construction-time era_index logging
- PIPELINE_TRUTH: pipelined message consumption logging
- Standalone KES verifier (verify_forged)
- Standalone VRF verifier (verify_vrf)
- `scripts/extract-opcert-sigma.py`: deterministic opcert decoder + self-verify parity check (replaces error-prone manual sigma slicing)
- OPCERT_PIN log: confirms the opcert counter is pinned (no per-forge bump)
- Docs: `docs/incidents/2026-06-opcert-self-verify-root-cause.md`, `docs/operator/opcert-troubleshooting.md`, `docs/ACCEPTANCE_FRONTIER_STATUS.md`
- Docs: `docs/C5_DELIVERY_ARCHITECTURE_SPEC.md` (active-delivery design for Frontier #7B), `docs/incidents/2026-06-slot-114284040-propagation-race.md`; Frontier #7A/#7B added to `docs/ACCEPTANCE_FRONTIER_STATUS.md`
