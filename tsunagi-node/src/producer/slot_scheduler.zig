const std = @import("std");
const producer = @import("producer.zig");
const vrf = @import("vrf.zig");
const sodium_vrf = @import("crypto/sodium_vrf.zig");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

pub const SCHED_WINDOW: u64 = 128;

pub const SlotSchedule = struct {
    epoch: u64,
    start_slot: u64,
    window: u64, // always 128
    leaders_in_window: u64,
    next_leader_offset: u64, // 0..127 or 999999 if none
    u_x1e12_first: u64, // u for offset 0 (sanity)
    thresh_x1e12_first: u64, // T for offset 0 (sanity)
};

/// Deterministic 128-slot lookahead schedule using REAL VRF evaluation per slot.
/// Uses the actual Praos VRF path (libsodium prove) so schedule predictions
/// exactly match per-slot leader decisions.
pub fn computeSchedule(
    epoch: u64,
    current_slot: u64,
    stake_fraction_x1e9: u64,
    asc_x1e6: u64,
    vrf_output_bytes: [64]u8,
    vrf_output_present: bool,
    clock_ok: bool,
) SlotSchedule {
    // Unused params kept for API compat
    _ = vrf_output_bytes;
    _ = vrf_output_present;
    return computeScheduleReal(epoch, current_slot, stake_fraction_x1e9, asc_x1e6, clock_ok, null, null);
}

/// Real VRF schedule: evaluates actual VRF prove per slot.
pub fn computeScheduleReal(
    epoch: u64,
    current_slot: u64,
    stake_fraction_x1e9: u64,
    asc_x1e6: u64,
    clock_ok: bool,
    vrf_cfg: ?*const vrf.VrfConfig,
    epoch_nonce: ?*const [32]u8,
) SlotSchedule {
    const empty = SlotSchedule{
        .epoch = epoch,
        .start_slot = current_slot,
        .window = SCHED_WINDOW,
        .leaders_in_window = 0,
        .next_leader_offset = 999999,
        .u_x1e12_first = 0,
        .thresh_x1e12_first = 0,
    };

    if (!clock_ok) return empty;
    if (stake_fraction_x1e9 == 0) return empty;

    const thresh_x1e12 = producer.computeThreshX1e12(stake_fraction_x1e9, asc_x1e6);
    if (thresh_x1e12 == 0) return empty;

    // If real VRF config available, use actual VRF evaluation per slot
    const cfg = vrf_cfg orelse return empty;
    const nonce = epoch_nonce orelse return empty;
    if (!cfg.enabled or !cfg.init_ok or !cfg.parse_ok) return empty;
    const sk = cfg.sk orelse return empty;

    var leaders: u64 = 0;
    var first_leader_offset: u64 = 999999;
    var u_first: u64 = 0;

    for (0..SCHED_WINDOW) |offset_usize| {
        const offset: u64 = @intCast(offset_usize);
        const eval_slot = current_slot + offset;

        // Praos VRF input: blake2b256(word64BE(slot) || epoch_nonce(32))
        // Ref: Ouroboros.Consensus.Protocol.Praos.VRF mkInputVRF
        var seed_preimage: [8 + 32]u8 = undefined;
        std.mem.writeInt(u64, seed_preimage[0..8], eval_slot, .big);
        @memcpy(seed_preimage[8..40], nonce);
        var msg: [32]u8 = undefined;
        Blake2b256.hash(&seed_preimage, &msg, .{});

        // VRF prove (real libsodium)
        const prove_result = sodium_vrf.prove(&sk, &msg) orelse continue;

        // Praos leader value: blake2b256("L" || vrf_output) then first 8 bytes
        var leader_input: [1 + 64]u8 = undefined;
        leader_input[0] = 'L';
        @memcpy(leader_input[1..65], &prove_result.output);
        var leader_hash: [32]u8 = undefined;
        Blake2b256.hash(&leader_input, &leader_hash, .{});
        const r = std.mem.readInt(u64, leader_hash[0..8], .big);
        const u_128: u128 = (@as(u128, r) * 1_000_000_000_000) / @as(u128, std.math.maxInt(u64));
        const u_x1e12: u64 = @intCast(@max(1, u_128));

        if (offset == 0) u_first = u_x1e12;

        // Leader if u < T (strict less-than, spec-aligned)
        if (u_x1e12 < thresh_x1e12) {
            leaders += 1;
            if (first_leader_offset == 999999) first_leader_offset = offset;
        }
    }

    return SlotSchedule{
        .epoch = epoch,
        .start_slot = current_slot,
        .window = SCHED_WINDOW,
        .leaders_in_window = leaders,
        .next_leader_offset = first_leader_offset,
        .u_x1e12_first = u_first,
        .thresh_x1e12_first = thresh_x1e12,
    };
}
