# Propagation Proof — TSUNAGI v4.5.30

**Date:** 2026-03-09
**Network:** Preview (magic=2)
**TSUNAGI version:** v4.5.30-raw-copy-cleanup
**Tagged:** v4.5.31

---

## Summary

TSUNAGI successfully served a block to a live cardano-node preview relay
over the standard Ouroboros NodeToNode protocol. The relay was temporarily
isolated (TSUNAGI as only peer) to force BlockFetch.

---

## Protocol Sequence

```
Handshake (preview magic=2, N2N)
  -> ChainSync FindIntersect (fragment hash match)
  -> IntersectFound
  -> RollBackward (spec-required after IntersectFound)
  -> RollForward (sealed tip header)
  -> BlockFetch MsgRequestRange (relay requests block)
  -> StartBatch
  -> Block (exact block CBOR served from artifact)
  -> BatchDone
```

---

## Log Evidence

```
chainsync: FindIntersect fragment_hash match
chainsync: FindIntersect ... result=found

chainsync: tx MsgRollForward slot=... block_no=...
chainsync: tx RollForward wire OK (HardFork wrapper present)
chainsync: handleRequestNext served_header=true served_sealed=true

blockfetch: decoded MsgRequestRange
blockfetch: StartBatch
blockfetch: BatchDone

propagation: serveMuxLoop exit ... served_header=true served_block=true
  cs_rx=4 cs_tx=4 bf_rx=1 bf_tx=3
  fresh_path_complete=true

served_header: true
served_block: true
```

---

## What This Proves

1. **ChainSync works end-to-end.** FindIntersect matches against the
   2160-entry rolling fragment. RollBackward and RollForward follow
   Ouroboros spec. The relay accepts the header.

2. **BlockFetch works end-to-end.** The relay requested a block via
   MsgRequestRange. TSUNAGI responded with StartBatch, the exact block
   CBOR bytes from the sealed artifact, and BatchDone. `bf_rx=1`
   confirms the relay sent one request. `bf_tx=3` confirms TSUNAGI
   sent three messages (StartBatch + Block + BatchDone).

3. **No injection.** TSUNAGI served bytes from disk artifacts only.
   The follower chain state was not modified.

---

## Test Configuration

| Component | Detail |
|-----------|--------|
| TSUNAGI host | 152.53.155.36 |
| TSUNAGI port | 3033 |
| Relay host | 152.53.152.172 |
| Relay port | 6000 |
| Relay topology | Isolated (TSUNAGI as only local-root peer) |
| Fragment depth | 2160 contiguous entries |
| Artifact | ~/tsunagi-home-preview/propagation_artifact/ |

---

## Prior Attempts

Before isolation, ChainSync succeeded but BlockFetch did not trigger
because the relay already had the block from other peers
(`equal_tip=true`, `FetchDeclineChainNotPlausible`). This is correct
relay behavior — it will not fetch a block it already has. Isolation
removed competing peers, forcing the relay to BlockFetch from TSUNAGI.

---

## Version Lineage

| Version | Contribution |
|---------|-------------|
| v4.5.25 | Bounded fetchable fragment bodies |
| v4.5.26 | Fragment cap 128 to 2160 |
| v4.5.27 | Rollback-stable fragment anchoring |
| v4.5.28 | Header CBOR archive in LMDB |
| v4.5.29 | Fragment-aware ChainSync/BlockFetch, persistent loop, ancestor seeding |
| v4.5.30 | Raw-copy fallback stale artifact fix |
| v4.5.31 | Milestone tag |
