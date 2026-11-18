// Acceptance-frontier reproduction — slot 114191515 (epoch 1321).
//
// PURPOSE
// -------
// Replayable unit reconstruction of the epoch-1321 acceptance frontier, where
// every real elected slot died at FORGE_REFUSE_STALE_PARENT. The decisive live
// evidence (decoded from the 0.15.2 relay log; identical logic in this 0.16
// tree) for slot 114191515:
//
//   applied tip:  tip_block=4358272 tip_slot=114191374 tip_hash_first8=1077ffc8
//   received:     rx_block=4358273  rx_slot=114191424  rx_prev_first8=ea6fe12b
//   forge_slot=114191515 parent_gap_slots=141 rx_prev_known=true
//   hashes_equal=false parent_source=applied_tip_fallback
//   fallback_reason=rx_hash_mismatch
//
// Across all 7 elected slots in epoch 1321 the pattern was systematic:
// rx_block ALWAYS == tip_block+1 and the hashes ALWAYS mismatched. That is not
// fork noise; it is a deterministic corruption.
//
// ROOT CAUSE (per diagnosis)
// --------------------------
// The applied-tip triple is corrupted at the SOURCE by CROSS-DOMAIN MIXING in
// the RollForward handler (src/net/chainsync/follower.zig:8108-8117, the write
// into ProducerContext.{tip_slot_last, tip_block_last, tip_hash_last}):
//
//   - tip_slot_last / tip_block_last come from getTipSlotBlock(roll_forward.tip)
//     — the PEER's far chain-tip claim (block N).
//   - tip_hash_last comes from header_hash32_value — the hash of the header
//     actually DELIVERED in this same message (block N+1 during catch-up / at
//     the frontier).
//
// Result: applied tip is stored as (block_no = N, hash = hash(N+1)). The live
// evidence confirms it exactly: tip_block=4358272 but tip_hash 1077ffc8 is the
// canonical hash of block 4358273, not 4358272. Meanwhile rx carries the
// internally-consistent delivered-domain values, so rx_prev (= hash of 4358272,
// ea6fe12b) never equals the corrupted tip_hash (1077ffc8). selectFreshestParent
// then refuses on the Stage-2 1-step hash check and falls back to applied_tip
// with fallback_reason="rx_hash_mismatch" — the FORGE_REFUSE_STALE_PARENT death.
//
// selectFreshestParent / fccConsultPure are NOT the bug; they behave correctly
// given corrupted input. The defect is the cross-domain write that produces the
// corrupted input. This test therefore drives the SAME pure write helper the
// runtime uses (follower.appliedTipTripleForRollForward) to compute the stored
// tip triple, then runs selectFreshestParent and asserts the correct outcome.
//
// RECONSTRUCTION FIDELITY
// -----------------------
// The decisive-datum is not the full 32-byte canonical bytes (the live log only
// recorded the first-8-byte prefixes 1077ffc8.. and ea6fe12b..). This is a
// FAITHFUL RECONSTRUCTION: two distinct, deterministic 32-byte hashes are
// synthesized whose first 8 bytes match the logged prefixes exactly
// (1077ffc8.. for block 4358273, ea6fe12b.. for block 4358272), and all
// block_no / slot values are the exact logged values. The header-chain linkage
// invariant proven stable in production — hash(N) == prev_hash(N+1) — is
// preserved: rx_prev is set to the canonical hash of block N (4358272), which
// equals the delivered-header hash stored when block N was rolled forward.
//
// EXPECTED RESULT
// ---------------
// Pre-fix: appliedTipTripleForRollForward mixes domains -> stored tip_hash =
//   hash(4358273) -> selectFreshestParent refuses -> source=applied_tip_fallback
//   reason=rx_hash_mismatch. The asserts below FAIL (the test captures the bug).
// Post-fix: the helper returns the internally-consistent delivered-domain triple
//   for block N -> stored tip_hash = hash(4358272) == rx_prev -> Stage-2 1-step
//   rule matches -> source=rx_validated, hashes equal, no stale fallback. Asserts PASS.

const std = @import("std");
const producer = @import("producer/producer.zig");
// The production applied-tip write helper, factored out of the chainsync
// RollForward handler (follower.zig RollForward calls this exact function and
// stores its result into ProducerContext.{tip_slot_last, tip_block_last,
// tip_hash_last}). Importing the small helper module rather than follower.zig
// keeps the replay self-contained while still tracking the production code path.
const applied_tip_select = @import("net/chainsync/applied_tip_select.zig");

// ── Logged identities for slot 114191515 (epoch 1321) ───────────────────────
const TIP_SLOT: u64 = 114191374; // applied-tip slot (block N)
const TIP_BLOCK: u64 = 4358272; //  applied-tip block_no (block N)
const RX_SLOT: u64 = 114191424; //  received header slot (block N+1)
const RX_BLOCK: u64 = 4358273; //   received header block_no (block N+1)
const FORGE_SLOT: u64 = 114191515; // our elected leader slot

// Canonical 32-byte hashes (reconstruction): first 8 bytes match the live log
// prefixes exactly; remaining bytes are deterministic fillers distinct per block.
fn canonicalHashBlockN() [32]u8 { // block 4358272, log prefix ea6fe12b..
    var h = [_]u8{0} ** 32;
    const prefix = [_]u8{ 0xea, 0x6f, 0xe1, 0x2b, 0x00, 0x00, 0x00, 0x00 };
    @memcpy(h[0..8], &prefix);
    var i: usize = 8;
    while (i < 32) : (i += 1) h[i] = 0x72; // 'r' filler, block-N marker
    return h;
}

fn canonicalHashBlockNPlus1() [32]u8 { // block 4358273, log prefix 1077ffc8..
    var h = [_]u8{0} ** 32;
    const prefix = [_]u8{ 0x10, 0x77, 0xff, 0xc8, 0x00, 0x00, 0x00, 0x00 };
    @memcpy(h[0..8], &prefix);
    var i: usize = 8;
    while (i < 32) : (i += 1) h[i] = 0x73; // 's' filler, block-(N+1) marker
    return h;
}

// Allocate + minimally initialize a ProducerContext for selectFreshestParent.
// std.mem.zeroInit is safe here: compat.Mutex wraps std.Io.Mutex whose `.init`
// state is all-zeros (verified empirically), so a zeroed mutex is lockable.
// selectFreshestParent only reads the tip_* / rx_* fields plus the FCC helpers;
// every other field is irrelevant to this path.
fn makeCtx(alloc: std.mem.Allocator) !*producer.ProducerContext {
    const ctx = try alloc.create(producer.ProducerContext);
    ctx.* = std.mem.zeroInit(producer.ProducerContext, .{});
    return ctx;
}

test "acceptance-frontier slot 114191515: rx must be usable as parent (no stale fallback)" {
    const alloc = std.testing.allocator;
    const ctx = try makeCtx(alloc);
    defer alloc.destroy(ctx);

    // ── Step 1: reproduce the RollForward applied-tip write ──────────────────
    // At the frontier the peer-tip CLAIM is block N (TIP_BLOCK) while the header
    // delivered in this RollForward is block N+1 (RX_BLOCK) whose hash is
    // canonicalHashBlockNPlus1(). The runtime computes the stored tip triple via
    // appliedTipTripleForRollForward(peer_tip_slot, peer_tip_block,
    //                                delivered_slot, delivered_block, delivered_hash).
    const delivered_hash = canonicalHashBlockNPlus1();
    const triple = applied_tip_select.appliedTipTripleForRollForward(
        TIP_SLOT, // peer-tip slot domain   (block N)
        TIP_BLOCK, // peer-tip block domain (block N)
        RX_SLOT, // delivered-header slot   (block N+1)
        RX_BLOCK, // delivered-header block (block N+1)
        delivered_hash, // delivered-header hash (block N+1)
    );

    // Store exactly as follower.zig:8108-8117 does (under the same mutex order).
    ctx.tip_mutex.lock();
    ctx.tip_slot_last = triple.slot;
    ctx.tip_block_last = triple.block_no;
    ctx.tip_hash_last = triple.hash;
    ctx.tip_mutex.unlock();

    // ── Step 2: rx carries the internally-consistent delivered-domain values ──
    // (this is what updateRxFromPeer plumbed in production: rx_block = N+1,
    //  rx_prev = canonical hash of N, rx_prev_known = true).
    ctx.rx_mutex.lock();
    ctx.rx_slot_last = RX_SLOT;
    ctx.rx_block_last = RX_BLOCK;
    ctx.rx_hash_last = canonicalHashBlockNPlus1();
    ctx.rx_prev_hash_last = canonicalHashBlockN(); // hash(N) == prev_hash(N+1)
    ctx.rx_prev_known_last = true;
    ctx.rx_mutex.unlock();

    // ── Step 3: run the failing unit ─────────────────────────────────────────
    const choice = producer.selectFreshestParent(ctx);

    // ── Sanity: the scenario is the logged 1-step frontier (independent of fix) ─
    try std.testing.expectEqual(@as(u64, TIP_BLOCK), choice.rx_observed_block - 1);
    try std.testing.expect(choice.rx_prev_known);

    // ── Assertions on the CORRECT outcome (fail pre-fix, pass post-fix) ──────
    //
    // These express the acceptance-frontier invariant in a FIX-SHAPE-AGNOSTIC
    // way: once the cross-domain corruption is removed the forge path must NOT
    // refuse with a stale applied_tip fallback, and the selected parent must be
    // the freshest delivered block (N+1) carrying its own internally-consistent
    // canonical hash. Two correct fix shapes both satisfy this:
    //   - store the delivered-domain triple as applied_tip  -> source=.applied_tip
    //     (rx == applied_tip, freshest block is the tip itself); OR
    //   - keep the corrected applied_tip = (N, hash(N)) so the Stage-2 1-step
    //     rule promotes rx                                   -> source=.rx_validated
    // Either way the parent is block N+1 with hash(N+1) and there is no stale
    // fallback. The pre-fix code produces source=.applied_tip_fallback with
    // block_no=N (the stale tip) — failing every assertion below.

    // A. No stale applied_tip fallback (this is the FORGE_REFUSE_STALE_PARENT
    //    death condition; it is the primary thing the fix must eliminate).
    try std.testing.expect(choice.source != .applied_tip_fallback);
    try std.testing.expect(!std.mem.eql(u8, choice.fallback_reason, "rx_hash_mismatch"));

    // B. The chosen parent is the freshest delivered block (N+1), NOT the stale
    //    applied tip (N). Pre-fix this is block N (the stale tip).
    try std.testing.expectEqual(@as(u64, RX_BLOCK), choice.block_no);
    try std.testing.expectEqual(@as(u64, RX_SLOT), choice.slot);

    // C. The chosen parent hash is block N+1's internally-consistent canonical
    //    hash (1077ffc8..). Pre-fix the chosen hash is the stale tip hash which,
    //    due to the cross-domain mix, is also hash(N+1) but bound to block N —
    //    so this passes pre-fix; it is asserted to pin the post-fix identity.
    try std.testing.expectEqualSlices(u8, canonicalHashBlockNPlus1()[0..], choice.hash[0..]);

    // D. The parent must be at least as fresh as rx — i.e. the forge can build
    //    on the delivered frontier block rather than a one-block-stale ancestor.
    try std.testing.expect(choice.block_no >= choice.rx_observed_block);
}
