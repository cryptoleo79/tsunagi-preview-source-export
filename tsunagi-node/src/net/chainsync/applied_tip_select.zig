//! Applied-tip triple selection for the chainsync RollForward handler.
//!
//! Extracted into a small, dependency-free module so the acceptance-frontier
//! scenario (slot 114191515, epoch 1321) is replayable in a unit test that
//! drives selectFreshestParent with exactly the applied-tip triple the runtime
//! stores. follower.zig RollForward calls `appliedTipTripleForRollForward` and
//! writes the result into ProducerContext.{tip_slot_last, tip_block_last,
//! tip_hash_last}.

/// Internally-consistent producer applied-tip triple, computed from a single
/// RollForward message.
pub const AppliedTipTriple = struct {
    slot: u64,
    block_no: u64,
    hash: [32]u8,
};

/// Pure helper for the RollForward applied-tip write.
///
/// Two provenance domains are available at the write site:
///   - PEER-TIP domain: `peer_tip_slot` / `peer_tip_block`, parsed from the
///     RollForward `tip` field (getTipSlotBlock). This is the peer's far
///     chain-tip *claim* (block N); during catch-up / at the frontier it is
///     routinely one block AHEAD of the header actually delivered in this same
///     message.
///   - DELIVERED-HEADER domain: `delivered_slot` / `delivered_block` /
///     `delivered_hash` (parseHeaderSlotAndBlockNo + computeHeaderHash32 of the
///     header carried in THIS RollForward, block N+1). These are the values
///     already plumbed into rx via updateRxFromPeer and into the header store;
///     they are internally consistent (hash(N) == prev_hash(N+1)).
///
/// FIX (acceptance frontier, epoch 1321): return a SINGLE-DOMAIN, internally
/// consistent applied-tip triple sourced entirely from the DELIVERED-HEADER
/// domain — `(delivered_slot, delivered_block, delivered_hash)`.
///
/// The pre-fix inline write at follower.zig mixed domains: slot/block came from
/// the PEER-TIP claim (block N) while hash came from the delivered header (block
/// N+1), storing the impossible triple (block_no = N, hash = hash(N+1)). That
/// corruption is the acceptance-frontier root cause: selectFreshestParent's
/// Stage-2 1-step rule checks `rx_prev == tip_hash`, and rx_prev (= hash(N) =
/// prev_hash(N+1)) can never equal the corrupted tip_hash (= hash(N+1)), so
/// every elected slot fell through to source=applied_tip_fallback
/// reason=rx_hash_mismatch → FORGE_REFUSE_STALE_PARENT.
///
/// The delivered header IS the freshest block this node has actually received
/// and validated in this RollForward; its (slot, block_no, hash) are all from
/// the same provenance and satisfy the header-chain linkage invariant
/// hash(N) == prev_hash(N+1) that the rx path and header store already rely on.
/// Storing it as the applied tip makes the applied-tip identity self-consistent.
/// When the delivered block equals the peer-tip claim (steady state) the two
/// domains coincide and behavior is unchanged; only the frontier 1-step-ahead
/// case (where the cross-domain mix was corrupting the hash) is corrected.
///
/// The peer-tip slot/block are intentionally NOT used for the stored identity;
/// they remain available to callers for telemetry. This does not touch forged
/// block serialization — it only fixes which (consistent) parent identity the
/// forge path reads, correcting the parent-hash reference as required.
pub fn appliedTipTripleForRollForward(
    peer_tip_slot: u64,
    peer_tip_block: u64,
    delivered_slot: u64,
    delivered_block: u64,
    delivered_hash: [32]u8,
) AppliedTipTriple {
    _ = peer_tip_slot;
    _ = peer_tip_block;
    return .{
        .slot = delivered_slot,
        .block_no = delivered_block,
        .hash = delivered_hash,
    };
}
