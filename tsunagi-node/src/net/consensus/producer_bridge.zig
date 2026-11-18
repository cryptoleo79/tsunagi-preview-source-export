const std = @import("std");
const readiness = @import("producer_readiness.zig");

/// Producer integration bridge — maps runtime-shaped inputs to
/// the existing producer readiness evaluation module.
///
/// Pure computation. No file IO. No network IO. No broadcast.
/// No side effects. No proven-file dependencies.
///
/// This module bridges between:
///   - runtime state (slot from cursor, config from ENV, keys from disk)
///   - standalone readiness evaluation (producer_readiness.evaluate)
///
/// The CLI command (producer_bridge_cmd.zig) handles all IO and
/// passes resolved inputs to this module.

// ───────────────────────────────────────────────────────────
//  Types
// ───────────────────────────────────────────────────────────

pub const BridgeState = enum {
    idle,
    not_configured,
    not_leader,
    ready_local_candidate,
    error_state,

    pub fn label(self: BridgeState) []const u8 {
        return switch (self) {
            .idle => "IDLE",
            .not_configured => "NOT_CONFIGURED",
            .not_leader => "NOT_LEADER",
            .ready_local_candidate => "READY_LOCAL_CANDIDATE",
            .error_state => "ERROR",
        };
    }
};

pub const BridgeInputs = struct {
    slot: u64,
    epoch: u64,
    slot_in_epoch: u64,

    tip_block_no: u64,
    tip_hash32: [32]u8,

    has_vrf: bool,
    has_kes: bool,
    has_pool_id: bool,
    has_stake: bool,

    stake_fraction_x1e9: u64,
    asc_x1e6: u64,

    current_kes_period: u32,
    opcert_start_period: u32,
    max_kes_evolutions: u32,

    net_magic: u32,
};

pub const BridgeResult = struct {
    state: BridgeState,
    slot: u64,
    leadership: bool,
    candidate_built: bool,

    header_hash: [32]u8,
    body_hash: [32]u8,

    tx_count: u32,
    header_size_bytes: u32,
    body_size_bytes: u32,

    /// Underlying readiness report for full detail access.
    report: ?readiness.ReadinessReport,
};

// ───────────────────────────────────────────────────────────
//  Core function
// ───────────────────────────────────────────────────────────

/// Evaluate producer readiness from bridge-shaped runtime inputs.
///
/// Maps BridgeInputs to producer_readiness.evaluate() parameters.
/// Requires pre-loaded VRF output and KES key state from the caller.
///
/// Pure computation. No IO. No broadcast.
pub fn evaluateFromInputs(
    inputs: BridgeInputs,
    vrf_output: [64]u8,
    kes_key_state: ?[]const u8,
    kes_pk: [32]u8,
    pool_id: [32]u8,
) BridgeResult {
    // Gate: not configured
    if (!inputs.has_stake and !inputs.has_vrf and !inputs.has_kes) {
        return notConfigured(inputs.slot);
    }

    const state_digest = [_]u8{0} ** 32;

    const report = readiness.evaluate(
        inputs.slot,
        inputs.epoch,
        inputs.slot_in_epoch,
        vrf_output,
        inputs.stake_fraction_x1e9,
        inputs.asc_x1e6,
        inputs.has_vrf,
        inputs.current_kes_period,
        inputs.opcert_start_period,
        inputs.max_kes_evolutions,
        kes_key_state,
        kes_pk,
        inputs.net_magic,
        inputs.tip_block_no,
        inputs.tip_hash32,
        state_digest,
        pool_id,
    );

    const bridge_state: BridgeState = switch (report.state) {
        .ready => .ready_local_candidate,
        .not_leader => .not_leader,
        .not_ready => if (!inputs.has_stake and !inputs.has_vrf and !inputs.has_kes)
            .not_configured
        else
            .error_state,
    };

    return .{
        .state = bridge_state,
        .slot = inputs.slot,
        .leadership = report.leadership.is_leader,
        .candidate_built = report.candidate.status == .pass,
        .header_hash = report.candidate.header_hash,
        .body_hash = report.candidate.body_hash,
        .tx_count = 0, // empty block
        .header_size_bytes = @intCast(report.candidate.header_bytes_len),
        .body_size_bytes = @intCast(report.candidate.body_bytes_len),
        .report = report,
    };
}

fn notConfigured(slot: u64) BridgeResult {
    return .{
        .state = .not_configured,
        .slot = slot,
        .leadership = false,
        .candidate_built = false,
        .header_hash = [_]u8{0} ** 32,
        .body_hash = [_]u8{0} ** 32,
        .tx_count = 0,
        .header_size_bytes = 0,
        .body_size_bytes = 0,
        .report = null,
    };
}

// ───────────────────────────────────────────────────────────
//  Epoch / KES period helpers (same formulas as producer.zig)
// ───────────────────────────────────────────────────────────

pub const SLOTS_PER_EPOCH_MAINNET: u64 = 432_000;
pub const SHELLEY_START_SLOT_MAINNET: u64 = 4_492_800;
pub const SHELLEY_START_EPOCH_MAINNET: u64 = 208;
pub const SLOTS_PER_KES_PERIOD: u64 = 129_600;

/// Compute epoch and slot_in_epoch from absolute slot.
/// Uses same formula as producer.zig:807-809.
pub fn computeEpochFromSlot(slot: u64, is_mainnet: bool) struct { epoch: u64, slot_in_epoch: u64 } {
    if (is_mainnet) {
        if (slot < SHELLEY_START_SLOT_MAINNET) {
            return .{ .epoch = 0, .slot_in_epoch = slot };
        }
        const shelley_slot = slot - SHELLEY_START_SLOT_MAINNET;
        return .{
            .epoch = SHELLEY_START_EPOCH_MAINNET + (shelley_slot / SLOTS_PER_EPOCH_MAINNET),
            .slot_in_epoch = shelley_slot % SLOTS_PER_EPOCH_MAINNET,
        };
    } else {
        // Testnets: simple division (no Byron era offset)
        // Testnet slots_per_epoch varies but preview uses 86400
        // The CLI caller should pass the correct value; this is a fallback
        const testnet_slots_per_epoch: u64 = 86_400;
        return .{
            .epoch = slot / testnet_slots_per_epoch,
            .slot_in_epoch = slot % testnet_slots_per_epoch,
        };
    }
}

/// Compute current KES period from absolute slot.
/// Same formula as producer.zig:965.
pub fn computeKesPeriod(slot: u64) u32 {
    return @intCast(slot / SLOTS_PER_KES_PERIOD);
}

// ───────────────────────────────────────────────────────────
//  Inline tests
// ───────────────────────────────────────────────────────────

test "bridge — not configured when no material" {
    const inputs = BridgeInputs{
        .slot = 50000,
        .epoch = 0,
        .slot_in_epoch = 50000,
        .tip_block_no = 1000,
        .tip_hash32 = [_]u8{0xAA} ** 32,
        .has_vrf = false,
        .has_kes = false,
        .has_pool_id = false,
        .has_stake = false,
        .stake_fraction_x1e9 = 0,
        .asc_x1e6 = 50_000,
        .current_kes_period = 0,
        .opcert_start_period = 0,
        .max_kes_evolutions = 62,
        .net_magic = 2,
    };

    const result = evaluateFromInputs(
        inputs,
        [_]u8{0} ** 64,
        null,
        [_]u8{0} ** 32,
        [_]u8{0} ** 32,
    );

    try std.testing.expectEqual(BridgeState.not_configured, result.state);
    try std.testing.expectEqual(false, result.leadership);
    try std.testing.expectEqual(false, result.candidate_built);
    try std.testing.expect(result.report == null);
}

test "bridge — not_leader with valid material but high VRF" {
    const inputs = BridgeInputs{
        .slot = 50000,
        .epoch = 0,
        .slot_in_epoch = 50000,
        .tip_block_no = 1000,
        .tip_hash32 = [_]u8{0xAA} ** 32,
        .has_vrf = true,
        .has_kes = false,
        .has_pool_id = true,
        .has_stake = true,
        .stake_fraction_x1e9 = 1_000,
        .asc_x1e6 = 50_000,
        .current_kes_period = 10,
        .opcert_start_period = 5,
        .max_kes_evolutions = 62,
        .net_magic = 2,
    };

    // Max VRF output → not leader with tiny stake
    const result = evaluateFromInputs(
        inputs,
        [_]u8{0xFF} ** 64,
        null,
        [_]u8{0xDD} ** 32,
        [_]u8{0xCC} ** 32,
    );

    try std.testing.expectEqual(BridgeState.not_leader, result.state);
    try std.testing.expectEqual(false, result.leadership);
    try std.testing.expectEqual(true, result.candidate_built);
    try std.testing.expect(result.report != null);
    try std.testing.expectEqual(readiness.ReadinessState.not_leader, result.report.?.state);
}

test "bridge — error_state when leader but KES skipped" {
    var inputs = BridgeInputs{
        .slot = 50000,
        .epoch = 0,
        .slot_in_epoch = 50000,
        .tip_block_no = 1000,
        .tip_hash32 = [_]u8{0xAA} ** 32,
        .has_vrf = true,
        .has_kes = false,
        .has_pool_id = true,
        .has_stake = true,
        .stake_fraction_x1e9 = 500_000_000,
        .asc_x1e6 = 50_000,
        .current_kes_period = 10,
        .opcert_start_period = 5,
        .max_kes_evolutions = 62,
        .net_magic = 2,
    };
    _ = &inputs;

    // Small VRF output → would be leader
    var vrf_out: [64]u8 = [_]u8{0} ** 64;
    vrf_out[1] = 0x01;

    const result = evaluateFromInputs(
        inputs,
        vrf_out,
        null, // no KES key → sign_verify.skip → not_ready
        [_]u8{0xDD} ** 32,
        [_]u8{0xCC} ** 32,
    );

    // Would be leader, but sign_verify is skipped → not_ready → error_state
    try std.testing.expectEqual(BridgeState.error_state, result.state);
    try std.testing.expect(result.report != null);
    try std.testing.expectEqual(readiness.ReadinessState.not_ready, result.report.?.state);
}

test "bridge — epoch computation mainnet" {
    // Shelley start: slot 4,492,800, epoch 208
    const r1 = computeEpochFromSlot(4_492_800, true);
    try std.testing.expectEqual(@as(u64, 208), r1.epoch);
    try std.testing.expectEqual(@as(u64, 0), r1.slot_in_epoch);

    // One epoch later: 4,492,800 + 432,000 = 4,924,800
    const r2 = computeEpochFromSlot(4_924_800, true);
    try std.testing.expectEqual(@as(u64, 209), r2.epoch);
    try std.testing.expectEqual(@as(u64, 0), r2.slot_in_epoch);

    // Mid-epoch
    const r3 = computeEpochFromSlot(4_492_800 + 100_000, true);
    try std.testing.expectEqual(@as(u64, 208), r3.epoch);
    try std.testing.expectEqual(@as(u64, 100_000), r3.slot_in_epoch);
}

test "bridge — epoch computation testnet" {
    const r1 = computeEpochFromSlot(86_400, false);
    try std.testing.expectEqual(@as(u64, 1), r1.epoch);
    try std.testing.expectEqual(@as(u64, 0), r1.slot_in_epoch);

    const r2 = computeEpochFromSlot(50_000, false);
    try std.testing.expectEqual(@as(u64, 0), r2.epoch);
    try std.testing.expectEqual(@as(u64, 50_000), r2.slot_in_epoch);
}

test "bridge — KES period computation" {
    try std.testing.expectEqual(@as(u32, 0), computeKesPeriod(0));
    try std.testing.expectEqual(@as(u32, 0), computeKesPeriod(129_599));
    try std.testing.expectEqual(@as(u32, 1), computeKesPeriod(129_600));
    try std.testing.expectEqual(@as(u32, 10), computeKesPeriod(1_296_000));
}

test "bridge — state labels" {
    try std.testing.expectEqualStrings("IDLE", BridgeState.idle.label());
    try std.testing.expectEqualStrings("NOT_CONFIGURED", BridgeState.not_configured.label());
    try std.testing.expectEqualStrings("NOT_LEADER", BridgeState.not_leader.label());
    try std.testing.expectEqualStrings("READY_LOCAL_CANDIDATE", BridgeState.ready_local_candidate.label());
    try std.testing.expectEqualStrings("ERROR", BridgeState.error_state.label());
}
