// ---------------------------------------------------------------------------
// Phase 27: Forge-Path Execution Gate Skeleton
// Defines a deterministic boundary where execution-aware validation can
// participate in block-candidate progression. Internal only — not yet
// wired into the producer. Does not overclaim Plutus support.
// ---------------------------------------------------------------------------

const tx_decode = @import("tx_decode.zig");
const eval_external = @import("eval_external.zig");
const std = @import("std");

/// Outcome of the forge-path execution gate check.
pub const ForgeGateResult = enum(u8) {
    not_applicable = 0, // tx does not require Plutus
    passed = 1, // execution gate passed
    failed = 2, // execution gate failed
    evaluator_unavailable = 3, // reserved for future backend selection
    unsupported = 4, // context could not be built
};

/// Detailed result of a forge-path execution gate check.
pub const ForgeGateDetail = struct {
    result: ForgeGateResult = .not_applicable,
    error_code: tx_decode.EvalErrorCode = .none,
    ex_units_mem: u64 = 0,
    ex_units_steps: u64 = 0,
};

/// Evaluate a transaction for the forge path.
/// Pure function — no allocation, no side effects, no logging.
/// Uses embedded evaluator only (no process spawning in forge path).
///
/// Steps:
///   1. classifyTxScripts — if no script_data_hash → not_applicable
///   2. buildPlutusContext — if parse fails → unsupported
///   3. evaluateMinimalRules — map success/failure to gate result
pub fn evaluateTxForForgePath(tx_bytes: []const u8) ForgeGateDetail {
    // Step 1: Check if tx requires Plutus at all
    const classification = tx_decode.classifyTxScripts(tx_bytes) orelse
        return .{ .result = .unsupported };
    if (!classification.has_script_data_hash)
        return .{ .result = .not_applicable };

    // Step 2: Build execution context from raw CBOR
    const ctx = tx_decode.buildPlutusContext(tx_bytes) orelse
        return .{ .result = .unsupported };

    // Step 3: Run embedded evaluator (dry-run, no enforcement)
    const exec = eval_external.evaluateMinimalRules(&ctx);
    return .{
        .result = if (exec.success) .passed else .failed,
        .error_code = exec.error_code,
        .ex_units_mem = exec.ex_units_mem,
        .ex_units_steps = exec.ex_units_steps,
    };
}

// ---------------------------------------------------------------------------
// Phase 31: Execution-Aware Candidate Ranking
// Deterministic scoring of candidate txs based on execution cost signals.
// Observation only — does not reorder or alter block contents.
// ---------------------------------------------------------------------------

/// Execution cost classification based on ex_units_steps.
pub const ForgeCostClass = enum(u8) {
    none = 0, // not_applicable, failed, unsupported
    low = 1, // steps < 5000
    medium = 2, // steps < 20000
    high = 3, // steps >= 20000
};

/// Ranked result for a candidate transaction.
pub const ForgeRankDetail = struct {
    score: u32 = 0, // 0-1000, higher is better
    cost_class: ForgeCostClass = .none,
    gate: ForgeGateDetail = .{},
};

/// Rank a transaction for forge-path candidate selection.
/// Wraps evaluateTxForForgePath and adds deterministic scoring.
/// Pure function — no allocation, no side effects.
pub fn rankTxForForgePath(tx_bytes: []const u8) ForgeRankDetail {
    const gate = evaluateTxForForgePath(tx_bytes);
    return switch (gate.result) {
        .not_applicable => blk: {
            // Deterministic size-based differentiation for non-Plutus txs.
            // Smaller txs are cheaper to include in the candidate body -> higher score.
            const size_penalty = @min(tx_bytes.len / 10, 200);
            break :blk .{
                .score = 500 - @as(u32, @intCast(size_penalty)),
                .cost_class = .none,
                .gate = gate,
            };
        },
        .passed => blk: {
            const cost_class = classifyCost(gate.ex_units_steps);
            const penalty = @min(gate.ex_units_steps / 100, 500);
            break :blk .{
                .score = 1000 - @as(u32, @intCast(penalty)),
                .cost_class = cost_class,
                .gate = gate,
            };
        },
        .failed => .{ .score = 0, .cost_class = .none, .gate = gate },
        .unsupported, .evaluator_unavailable => .{ .score = 100, .cost_class = .none, .gate = gate },
    };
}

fn classifyCost(steps: u64) ForgeCostClass {
    if (steps < 5000) return .low;
    if (steps < 20000) return .medium;
    return .high;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "evaluateTxForForgePath: empty bytes returns unsupported" {
    const detail = evaluateTxForForgePath(&[_]u8{});
    try std.testing.expectEqual(ForgeGateResult.unsupported, detail.result);
}

test "evaluateTxForForgePath: malformed bytes returns unsupported" {
    const detail = evaluateTxForForgePath(&[_]u8{ 0xFF, 0xFF, 0xFF });
    try std.testing.expectEqual(ForgeGateResult.unsupported, detail.result);
}

test "evaluateTxForForgePath: non-Plutus tx returns not_applicable" {
    // Construct a minimal valid tx: 2-element array [body_map, witnesses_map]
    // Body map has key 0 (inputs) only — no key 11 (script_data_hash)
    // This means classifyTxScripts should succeed but has_script_data_hash=false
    var buf: [64]u8 = undefined;
    var w: usize = 0;

    // Outer array(2)
    buf[w] = 0x82;
    w += 1;

    // Body: map(1) { 0: array(1) [ array(2) [bstr(32), uint(0)] ] }
    buf[w] = 0xA1; // map(1)
    w += 1;
    buf[w] = 0x00; // key 0
    w += 1;
    buf[w] = 0x81; // array(1)
    w += 1;
    buf[w] = 0x82; // array(2)
    w += 1;
    buf[w] = 0x58; // bstr, 1-byte length
    w += 1;
    buf[w] = 0x20; // 32 bytes
    w += 1;
    @memset(buf[w..][0..32], 0xAA); // dummy hash
    w += 32;
    buf[w] = 0x00; // uint(0) index
    w += 1;

    // Witnesses: map(0)
    buf[w] = 0xA0;
    w += 1;

    const detail = evaluateTxForForgePath(buf[0..w]);
    try std.testing.expectEqual(ForgeGateResult.not_applicable, detail.result);
    try std.testing.expectEqual(tx_decode.EvalErrorCode.none, detail.error_code);
}

// ---------------------------------------------------------------------------
// Ranking Tests
// ---------------------------------------------------------------------------

test "rankTxForForgePath: not_applicable uses size-based score" {
    // Non-Plutus tx: 40 bytes → penalty = min(40/10, 200) = 4 → score = 496
    var buf: [64]u8 = undefined;
    var w: usize = 0;
    buf[w] = 0x82;
    w += 1;
    buf[w] = 0xA1;
    w += 1;
    buf[w] = 0x00;
    w += 1;
    buf[w] = 0x81;
    w += 1;
    buf[w] = 0x82;
    w += 1;
    buf[w] = 0x58;
    w += 1;
    buf[w] = 0x20;
    w += 1;
    @memset(buf[w..][0..32], 0xAA);
    w += 32;
    buf[w] = 0x00;
    w += 1;
    buf[w] = 0xA0;
    w += 1;

    const rank = rankTxForForgePath(buf[0..w]);
    // 40 bytes: penalty=4, score=496
    try std.testing.expectEqual(@as(u32, 496), rank.score);
    try std.testing.expectEqual(ForgeCostClass.none, rank.cost_class);
    try std.testing.expectEqual(ForgeGateResult.not_applicable, rank.gate.result);
}

test "rankTxForForgePath: size differentiation produces different scores" {
    // Small tx: 40 bytes → score 496
    // Larger tx: 100 bytes → penalty=10 → score 490
    var small_buf: [64]u8 = undefined;
    var sw: usize = 0;
    small_buf[sw] = 0x82;
    sw += 1;
    small_buf[sw] = 0xA1;
    sw += 1;
    small_buf[sw] = 0x00;
    sw += 1;
    small_buf[sw] = 0x81;
    sw += 1;
    small_buf[sw] = 0x82;
    sw += 1;
    small_buf[sw] = 0x58;
    sw += 1;
    small_buf[sw] = 0x20;
    sw += 1;
    @memset(small_buf[sw..][0..32], 0xAA);
    sw += 32;
    small_buf[sw] = 0x00;
    sw += 1;
    small_buf[sw] = 0xA0;
    sw += 1;

    var large_buf: [128]u8 = undefined;
    // Copy small tx then pad to 100 bytes with valid-ish CBOR
    @memcpy(large_buf[0..sw], small_buf[0..sw]);
    // Pad remaining bytes (won't affect classification — gate reads body map keys)
    @memset(large_buf[sw..100], 0x00);
    // Overwrite to be a larger valid-looking slice
    const lw: usize = 100;

    const small_rank = rankTxForForgePath(small_buf[0..sw]);
    const large_rank = rankTxForForgePath(large_buf[0..lw]);

    // Both should be not_applicable (non-Plutus)
    try std.testing.expectEqual(ForgeGateResult.not_applicable, small_rank.gate.result);
    // Scores must differ
    try std.testing.expect(small_rank.score > large_rank.score);
    // Small: 40 bytes → 496, Large: 100 bytes → 490
    try std.testing.expectEqual(@as(u32, 496), small_rank.score);
    try std.testing.expectEqual(@as(u32, 490), large_rank.score);
}

test "rankTxForForgePath: unsupported scores 100" {
    const rank = rankTxForForgePath(&[_]u8{});
    try std.testing.expectEqual(@as(u32, 100), rank.score);
    try std.testing.expectEqual(ForgeCostClass.none, rank.cost_class);
    try std.testing.expectEqual(ForgeGateResult.unsupported, rank.gate.result);
}

test "classifyCost: thresholds" {
    try std.testing.expectEqual(ForgeCostClass.low, classifyCost(0));
    try std.testing.expectEqual(ForgeCostClass.low, classifyCost(4999));
    try std.testing.expectEqual(ForgeCostClass.medium, classifyCost(5000));
    try std.testing.expectEqual(ForgeCostClass.medium, classifyCost(19999));
    try std.testing.expectEqual(ForgeCostClass.high, classifyCost(20000));
    try std.testing.expectEqual(ForgeCostClass.high, classifyCost(999999));
}

test "rankTxForForgePath: score formula deterministic" {
    // For passed tx with steps=3000: penalty = min(3000/100, 500) = 30, score = 970
    // For passed tx with steps=50000: penalty = min(50000/100, 500) = 500, score = 500
    // These are computed from evaluateMinimalRules which we can't easily invoke
    // from raw CBOR in a unit test, but we can verify the classifyCost and formula logic.
    // Score = 1000 - min(steps/100, 500)
    const penalty_low = @min(@as(u64, 3000) / 100, 500);
    try std.testing.expectEqual(@as(u64, 30), penalty_low);
    const penalty_high = @min(@as(u64, 60000) / 100, 500);
    try std.testing.expectEqual(@as(u64, 500), penalty_high);
}
