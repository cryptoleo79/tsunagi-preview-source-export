# Incident — Slot 114284040 Propagation Race (forge success / adoption failure)

**Status:** Frontier #7B (delivery / adoption latency) — Active
**Date:** 2026-06-08 (preview)
**Pool:** preview-tsunagi-pool · **Binary:** `932dc500` (PID 2517350) · **TSUNAGI_HOME:** /home/cardano/tsunagi-home-colo
**Block:** block_no **4361767**, hash **`1d40f74a336c8854`**, slot **114284040**
**Result:** **FORGE SUCCESS · ADOPTION FAILURE**

---

## 1. Summary

The first fully-clean forge after the compound opcert frontier was closed. Every forge-correctness gate
passed and a valid, coherent Conway block was sealed at +1 s. It was **never adopted**: a competing block
at the same height reached cardano-node first, and by the time TSUNAGI's block was served, cardano-node
declined to fetch it (`FetchDeclineChainNotPlausible`). The block was orphaned. This isolates the
remaining frontier as **delivery latency**, not forge correctness.

## 2. Timeline (producer clock, `unix = 1666656000 + slot`; log timestamps only)

| event | unix | Δ from slot | source anchor |
|-------|------|-------------|----------------|
| slot 114284040 start | 1780940040 | 0 s | `FORGE_WAIT_SLOT_UTC now_unix=1780940025 @ wall 114284025` |
| EVENT_LEADER_DETECTED (pre-arm) | 1780939953 | −87 s | candidate dir `candidates/1780939953_114284040` |
| FORGE_SELF_VERIFY pass=YES (seq=0 period=846) | 1780940041 | +1 s | forge cluster `…/1780940041_…`; `FORGE_AT_SLOT current_slot=114284041` |
| FORGE_BLOCK_ENVELOPE_OK (era_tag=7 prefix=820785) | 1780940041 | +1 s | same cluster |
| FORGE_PROMOTE_ATOMIC (block_no=4361767) | 1780940041 | +1 s | same cluster |
| FORGE_PROMOTE_FRAGMENT (copied=1295, depth=260, coherent=true) | 1780940041 | +1 s | same cluster |
| **artifact exists + coherent on disk** | 1780940041 | **+1 s** | `FORGE_PROMOTE_FRAGMENT artifact_coherent=true degraded_mode=false` |
| **competing block observed** (4361767 / `aff6f743` @ slot 114284046) | 1780940046 | **+6 s** | `PEER_PROBE_HEADER slot=114284046 hash=aff6f743…`; `ROLLBACK_SUSPECT`; `CHAIN_TIP_BLOCK enter now=1780940046` |
| **first meaningful propagation contact** (conn #247) + PROP_ARTIFACT_READY | 1780940049 | **+9 s** | `ACCEPTANCE_CONN_TRUTH connection_id=247 accepted_unix=1780940049` |
| peer disconnect (header-only, `bf_rx=0`) | ~1780940049–50 | +9–10 s | `LOOP_EXIT_TRUTH reason=peer_disconnect … bf_rx=0`; `SERVE_DECISION kind=header_only_disconnect` |
| ROLLBACK_SUSPECT | 1780940046 | +6 s | (see competitor row) |
| **ROLLBACK_CONFIRMED** (koios_confirmed_loss) | 1780940077 | **+37 s** | quarantine dir `propagation_artifact.orphan.1780940077`; `FORGE_ORPHAN_ROLLBACK restored_tip_slot=114284025` |

Deltas: slot→promote **1 s** · promote→artifact-ready **8 s** · artifact-ready→first-peer **0 s** · slot→rollback **37 s**.

## 3. Artifact visibility timing (Frontier #7A — proven, not the sole cause)

The artifact was complete and coherent on disk at **+1 s** but first became *visible to the propagation
server* (`PROP_ARTIFACT_READY`) only at **+9 s** — the next inbound cardano-node dial. Cause
(source-established): `forge_notify.notify()` is an atomic `fetchAdd` (`net/forge_notify.zig`) that cannot
wake the propagation server blocked in `server.accept()` (`net/propagation_server.zig:394`); the load that
emits `PROP_ARTIFACT_READY` (`:455–458`) runs only post-accept. Full proof and breakdown:
`/home/tsunagi/SESSION_SLOT_114284040_FORENSIC.md` and
`/home/tsunagi/ARCH_MEMO_propagation_visibility_2026_06_08.md`.

**Why visibility alone did not lose this slot:** there was no inbound connection between +1 s and +9 s
(pre-forge connections were `PROPAGATION_HANDSHAKE_ONLY … no_artifact_yet` and closed). Even with instant
visibility (C1–C4), the first serve opportunity was still +9 s, by which point cardano-node was already at
slot 114284046. The decisive loss was *delivery*, not visibility.

## 4. Competitor arrival (Frontier #7B — the active cause)

A second block at the same height — block_no 4361767, hash `aff6f743`, slot **114284046** (6 slots after
TSUNAGI's 114284040) — was observed on the wire at **+6 s** and adopted by cardano-node before TSUNAGI's
block was ever served. At the first dial (#247, +9 s), TSUNAGI's own logs show cardano-node already ahead:

```
chainsync: CHAIN_POSITION relay_newest_slot=114284046 sealed_slot=114284040 gap=-6 relay_ahead=true
candidate: … relay_ahead=true tsunagi_ahead=false equal_tip=false strictly_ahead=false
chainsync: STALE_TIP relay_newest_slot=114284046 sealed_slot=114284040 (relay ahead …)
```

cardano-node's BlockFetch decision (its own trace) returned `FetchDeclineChainNotPlausible` for peer
`127.0.0.1:3033` on every cycle — the body was never requested. TSUNAGI served the header only
(`served_header=true served_block=false`, `blockfetch_rx_total=0`).

## 5. Rollback evidence

```
ROLLBACK_SUSPECT: probe_block=4361767 probe_hash=aff6f743… armed_hash=1d40f74a336c8854 settle_slots=30   (+6s)
KOIOS_CONFIRMATION_PENDING: armed_slot=114284040 suspect_slot=114284047 settle_remaining=29 → 1
ROLLBACK_CONFIRMED: reason=koios_confirmed_loss armed_hash=1d40f74a336c8854                              (+37s)
FORGE_ORPHAN_ARTIFACT_QUARANTINED: dst=…/propagation_artifact.orphan.1780940077 reason=probe_divergence
FORGE_ORPHAN_ROLLBACK: armed_slot=114284040 armed_block_no=4361767 restored_tip_slot=114284025 restored_opcert=0
```

The orphan outcome was decided at +6 s (competitor on wire) and confirmed at +37 s (Koios). The block was
quarantined and the tip rolled back to 4361766; opcert restored to 0.

## 6. Conclusion

- Forge correctness, opcert, era-7, sigma, and promotion are all **proven** on this slot.
- The block was lost to **delivery latency**: first serve at +9 s vs competitor at +6 s; cardano-node
  declined the late, now-behind tip.
- Remaining frontier: **#7B (delivery / adoption latency)**. Smallest protocol-compliant remedy (design
  only, no code): active delivery — see `docs/C5_DELIVERY_ARCHITECTURE_SPEC.md`.

See also: `docs/ACCEPTANCE_FRONTIER_STATUS.md` (#7A/#7B),
`docs/incidents/2026-06-opcert-self-verify-root-cause.md` (the frontier this slot proved closed).
