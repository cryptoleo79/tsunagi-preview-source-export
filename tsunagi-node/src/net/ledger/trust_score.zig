// ---------------------------------------------------------------------------
// Phase 47: Simple Pre-Bayesian Trust Scoring (Observe-Only)
// Derives a deterministic score from aggregate trust evidence.
// No posterior math, no weights, no adaptive behavior.
//
// BAeY, EV, Kelly, LLR are NOT implemented here.
// This is a transparent additive score from observed evidence.
// ---------------------------------------------------------------------------

const std = @import("std");
const compat = @import("compat");
const trust_aggregate = @import("trust_aggregate.zig");

/// Simple trust score summary derived from aggregate evidence.
/// Positive outcomes contribute +1 each. Negative outcomes contribute -1 each.
/// Neutral/unavailable outcomes contribute 0.
/// score = positive - negative. Unbounded integer (can be negative).
pub const TrustScoreSummary = struct {
    positive: u64 = 0,
    negative: u64 = 0,
    neutral: u64 = 0,
    score: i64 = 0,

    /// Emit a stable, grep-friendly summary line.
    pub fn emitSummary(self: *const TrustScoreSummary, w: anytype) void {
        w.print("TRUST_SCORE: positive={d} negative={d} neutral={d} score={d}\n", .{
            self.positive,
            self.negative,
            self.neutral,
            self.score,
        }) catch {};
    }
};

/// Classify an aggregate outcome as positive, negative, or neutral.
/// Mapping is transparent and deterministic:
///   positive:  supported_pass, accepted
///   negative:  supported_fail, invalid_response, rejected_conflict,
///              rejected_missing_input, rejected_balance, rejected_validity,
///              rejected_plutus_unsupported
///   neutral:   backend_unavailable, case_not_supported, rejected_total
///              (rejected_total is a summary counter, not an independent signal)
pub fn classifyOutcome(outcome: trust_aggregate.SignalOutcome) enum { positive, negative, neutral } {
    return switch (outcome) {
        .supported_pass, .accepted => .positive,
        .supported_fail, .invalid_response, .rejected_conflict, .rejected_missing_input, .rejected_balance, .rejected_validity, .rejected_plutus_unsupported => .negative,
        .backend_unavailable, .case_not_supported, .rejected_total => .neutral,
    };
}

/// Build a simple trust score from an aggregate snapshot.
/// Pure function — no side effects, no allocation.
pub fn buildScore(agg: *const trust_aggregate.TrustAggregateSnapshot) TrustScoreSummary {
    var s = TrustScoreSummary{};
    for (agg.entries[0..agg.entry_count]) |entry| {
        switch (classifyOutcome(entry.outcome)) {
            .positive => s.positive += entry.count,
            .negative => s.negative += entry.count,
            .neutral => s.neutral += entry.count,
        }
    }
    s.score = @as(i64, @intCast(s.positive)) - @as(i64, @intCast(s.negative));
    return s;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const trust_signal = @import("trust_signal.zig");

test "buildScore: deterministic from aggregate" {
    const forge = trust_signal.ForgeSignalSnapshot{
        .checked = 5,
        .supported_pass = 2,
        .supported_fail = 1,
        .backend_unavailable = 1,
        .case_not_supported = 1,
        .invalid_response = 0,
    };
    const mempool = trust_signal.MempoolSignalSnapshot{
        .accepted = 10,
        .rejected_total = 3,
        .rejected_conflict = 1,
        .rejected_missing_input = 1,
        .rejected_balance = 1,
        .rejected_validity = 0,
        .rejected_plutus_unsupported = 0,
    };
    const agg = trust_aggregate.buildAggregate(&forge, &mempool);
    const score = buildScore(&agg);

    // positive: supported_pass(2) + accepted(10) = 12
    // negative: supported_fail(1) + rejected_conflict(1) + rejected_missing_input(1) + rejected_balance(1) = 4
    // neutral: backend_unavailable(1) + case_not_supported(1) + rejected_total(3) = 5
    try std.testing.expectEqual(@as(u64, 12), score.positive);
    try std.testing.expectEqual(@as(u64, 4), score.negative);
    try std.testing.expectEqual(@as(u64, 5), score.neutral);
    try std.testing.expectEqual(@as(i64, 8), score.score);
}

test "buildScore: zero aggregate" {
    const forge = trust_signal.ForgeSignalSnapshot{};
    const mempool = trust_signal.MempoolSignalSnapshot{};
    const agg = trust_aggregate.buildAggregate(&forge, &mempool);
    const score = buildScore(&agg);

    try std.testing.expectEqual(@as(u64, 0), score.positive);
    try std.testing.expectEqual(@as(u64, 0), score.negative);
    try std.testing.expectEqual(@as(u64, 0), score.neutral);
    try std.testing.expectEqual(@as(i64, 0), score.score);
}

test "buildScore: idempotent" {
    const forge = trust_signal.ForgeSignalSnapshot{ .checked = 3, .supported_pass = 1, .supported_fail = 1, .case_not_supported = 1 };
    const mempool = trust_signal.MempoolSignalSnapshot{ .accepted = 5, .rejected_total = 2, .rejected_balance = 2 };
    const agg = trust_aggregate.buildAggregate(&forge, &mempool);
    const a = buildScore(&agg);
    const b = buildScore(&agg);
    try std.testing.expectEqual(a.positive, b.positive);
    try std.testing.expectEqual(a.negative, b.negative);
    try std.testing.expectEqual(a.neutral, b.neutral);
    try std.testing.expectEqual(a.score, b.score);
}

test "buildScore: negative score possible" {
    const forge = trust_signal.ForgeSignalSnapshot{ .checked = 3, .supported_fail = 3 };
    const mempool = trust_signal.MempoolSignalSnapshot{ .rejected_total = 5, .rejected_conflict = 2, .rejected_balance = 3 };
    const agg = trust_aggregate.buildAggregate(&forge, &mempool);
    const score = buildScore(&agg);

    // positive: 0, negative: 3+2+3=8, score = -8
    try std.testing.expectEqual(@as(u64, 0), score.positive);
    try std.testing.expectEqual(@as(u64, 8), score.negative);
    try std.testing.expectEqual(@as(i64, -8), score.score);
}

test "emitSummary: stable format" {
    const s = TrustScoreSummary{ .positive = 10, .negative = 3, .neutral = 2, .score = 7 };
    var buf: [128]u8 = undefined;
    var stream = compat.fixedBufferStream(&buf);
    s.emitSummary(stream.writer());
    const output = buf[0..stream.pos];
    const expected = "TRUST_SCORE: positive=10 negative=3 neutral=2 score=7\n";
    try std.testing.expectEqualSlices(u8, expected, output);
}

test "classifyOutcome: all outcomes classified" {
    // Verify every outcome has a classification (exhaustive switch)
    const outcomes = [_]trust_aggregate.SignalOutcome{
        .supported_pass, .supported_fail, .backend_unavailable,
        .case_not_supported, .invalid_response, .accepted,
        .rejected_total, .rejected_conflict, .rejected_missing_input,
        .rejected_balance, .rejected_validity, .rejected_plutus_unsupported,
    };
    for (outcomes) |o| {
        _ = classifyOutcome(o);
    }
}
