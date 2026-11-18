// ---------------------------------------------------------------------------
// Phase 49: Observe-Only Decision Advisory Layer
// Derives a deterministic advisory output from trust score and decision metrics.
// Answers "what would the node conclude?" — NOT "what will the node do?"
//
// This is transparent, stateless, and non-mutating.
// No adaptive policy, no autonomous decisions, no feedback loops.
// ---------------------------------------------------------------------------

const std = @import("std");
const compat = @import("compat");
const decision_metrics = @import("decision_metrics.zig");

/// What the evidence suggests about the current state.
pub const DecisionStance = enum(u8) {
    positive = 0, // evidence favors positive outcomes
    neutral = 1, // evidence is balanced or insufficient
    negative = 2, // evidence favors negative outcomes
};

/// How strongly the evidence supports the stance.
/// Based on abs(llr_x1e6):
///   low:    < 500000   (weak signal)
///   medium: < 1500000  (moderate signal)
///   high:   >= 1500000 (strong signal)
pub const ConfidenceBand = enum(u8) {
    low = 0,
    medium = 1,
    high = 2,
};

/// How much action a Kelly-style allocator would suggest.
/// Based on kelly_x1e6:
///   zero:     = 0         (no edge)
///   light:    < 250000    (small edge)
///   moderate: < 750000    (meaningful edge)
///   strong:   >= 750000   (large edge)
pub const AllocationBand = enum(u8) {
    zero = 0,
    light = 1,
    moderate = 2,
    strong = 3,
};

/// Action mode — always observe_only in this phase.
pub const ActionMode = enum(u8) {
    observe_only = 0,
};

/// Complete advisory output from one forge cycle.
pub const DecisionAdvisory = struct {
    stance: DecisionStance = .neutral,
    confidence: ConfidenceBand = .low,
    allocation: AllocationBand = .zero,
    action_mode: ActionMode = .observe_only,
    score: i64 = 0,
    posterior_x1e6: u64 = 500000,
    ev_x1e6: i64 = 0,
    kelly_x1e6: u64 = 0,
    llr_x1e6: i64 = 0,

    /// Emit a stable, grep-friendly summary line.
    pub fn emitSummary(self: *const DecisionAdvisory, w: anytype) void {
        w.print("DECISION_ADVISORY: stance={s} confidence={s} allocation={s} action=observe_only score={d} posterior_x1e6={d} ev_x1e6={d} kelly_x1e6={d} llr_x1e6={d}\n", .{
            stanceName(self.stance),
            confidenceName(self.confidence),
            allocationName(self.allocation),
            self.score,
            self.posterior_x1e6,
            self.ev_x1e6,
            self.kelly_x1e6,
            self.llr_x1e6,
        }) catch {};
    }
};

/// Build a deterministic advisory from decision metrics.
/// Pure function — no side effects, no state, no allocation.
pub fn buildAdvisory(dm: *const decision_metrics.DecisionMetrics) DecisionAdvisory {
    // Stance: requires agreement across score, posterior, and EV
    const stance: DecisionStance = if (dm.ev_x1e6 > 0 and dm.posterior_mean_x1e6 > 500000 and
        @as(i64, @intCast(dm.positive)) - @as(i64, @intCast(dm.negative)) > 0)
        .positive
    else if (dm.ev_x1e6 < 0 and dm.posterior_mean_x1e6 < 500000 and
        @as(i64, @intCast(dm.positive)) - @as(i64, @intCast(dm.negative)) < 0)
        .negative
    else
        .neutral;

    // Confidence: based on absolute LLR strength
    const abs_llr: u64 = if (dm.llr_x1e6 >= 0)
        @intCast(dm.llr_x1e6)
    else
        @intCast(-dm.llr_x1e6);
    const confidence: ConfidenceBand = if (abs_llr >= 1_500_000)
        .high
    else if (abs_llr >= 500_000)
        .medium
    else
        .low;

    // Allocation: based on Kelly fraction
    const allocation: AllocationBand = if (dm.kelly_x1e6 >= 750_000)
        .strong
    else if (dm.kelly_x1e6 >= 250_000)
        .moderate
    else if (dm.kelly_x1e6 > 0)
        .light
    else
        .zero;

    return .{
        .stance = stance,
        .confidence = confidence,
        .allocation = allocation,
        .action_mode = .observe_only,
        .score = @as(i64, @intCast(dm.positive)) - @as(i64, @intCast(dm.negative)),
        .posterior_x1e6 = dm.posterior_mean_x1e6,
        .ev_x1e6 = dm.ev_x1e6,
        .kelly_x1e6 = dm.kelly_x1e6,
        .llr_x1e6 = dm.llr_x1e6,
    };
}

fn stanceName(s: DecisionStance) []const u8 {
    return switch (s) { .positive => "positive", .neutral => "neutral", .negative => "negative" };
}

fn confidenceName(c: ConfidenceBand) []const u8 {
    return switch (c) { .low => "low", .medium => "medium", .high => "high" };
}

fn allocationName(a: AllocationBand) []const u8 {
    return switch (a) { .zero => "zero", .light => "light", .moderate => "moderate", .strong => "strong" };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const trust_score = @import("trust_score.zig");

test "buildAdvisory: positive case" {
    const score = trust_score.TrustScoreSummary{ .positive = 20, .negative = 2, .neutral = 3, .score = 18 };
    const dm = decision_metrics.buildMetrics(&score);
    const adv = buildAdvisory(&dm);

    try std.testing.expectEqual(DecisionStance.positive, adv.stance);
    try std.testing.expectEqual(ActionMode.observe_only, adv.action_mode);
    try std.testing.expect(adv.ev_x1e6 > 0);
    try std.testing.expect(adv.kelly_x1e6 > 0);
}

test "buildAdvisory: negative case" {
    const score = trust_score.TrustScoreSummary{ .positive = 1, .negative = 9, .neutral = 0, .score = -8 };
    const dm = decision_metrics.buildMetrics(&score);
    const adv = buildAdvisory(&dm);

    try std.testing.expectEqual(DecisionStance.negative, adv.stance);
    try std.testing.expectEqual(AllocationBand.zero, adv.allocation);
    try std.testing.expect(adv.ev_x1e6 < 0);
}

test "buildAdvisory: neutral case — balanced" {
    const score = trust_score.TrustScoreSummary{ .positive = 5, .negative = 5, .neutral = 10, .score = 0 };
    const dm = decision_metrics.buildMetrics(&score);
    const adv = buildAdvisory(&dm);

    try std.testing.expectEqual(DecisionStance.neutral, adv.stance);
    try std.testing.expectEqual(AllocationBand.zero, adv.allocation);
}

test "buildAdvisory: neutral case — zero evidence" {
    const score = trust_score.TrustScoreSummary{};
    const dm = decision_metrics.buildMetrics(&score);
    const adv = buildAdvisory(&dm);

    try std.testing.expectEqual(DecisionStance.neutral, adv.stance);
    try std.testing.expectEqual(ConfidenceBand.low, adv.confidence);
    try std.testing.expectEqual(AllocationBand.zero, adv.allocation);
    try std.testing.expectEqual(ActionMode.observe_only, adv.action_mode);
}

test "buildAdvisory: confidence thresholds" {
    // Low confidence: small LLR
    const score_low = trust_score.TrustScoreSummary{ .positive = 3, .negative = 2, .score = 1 };
    const dm_low = decision_metrics.buildMetrics(&score_low);
    const adv_low = buildAdvisory(&dm_low);
    try std.testing.expectEqual(ConfidenceBand.low, adv_low.confidence);

    // High confidence: large LLR (20 positive, 1 negative → ln(21/2) ≈ 2.35 → 2350000)
    const score_high = trust_score.TrustScoreSummary{ .positive = 20, .negative = 1, .score = 19 };
    const dm_high = decision_metrics.buildMetrics(&score_high);
    const adv_high = buildAdvisory(&dm_high);
    try std.testing.expectEqual(ConfidenceBand.high, adv_high.confidence);
}

test "buildAdvisory: allocation thresholds" {
    // Zero allocation: balanced evidence
    const score_zero = trust_score.TrustScoreSummary{ .positive = 5, .negative = 5, .score = 0 };
    const dm_zero = decision_metrics.buildMetrics(&score_zero);
    const adv_zero = buildAdvisory(&dm_zero);
    try std.testing.expectEqual(AllocationBand.zero, adv_zero.allocation);

    // Strong allocation: 20 pos / 2 neg → kelly ≈ 750000
    const score_strong = trust_score.TrustScoreSummary{ .positive = 20, .negative = 2, .score = 18 };
    const dm_strong = decision_metrics.buildMetrics(&score_strong);
    const adv_strong = buildAdvisory(&dm_strong);
    try std.testing.expectEqual(AllocationBand.strong, adv_strong.allocation);
}

test "buildAdvisory: idempotent" {
    const score = trust_score.TrustScoreSummary{ .positive = 7, .negative = 3, .neutral = 5, .score = 4 };
    const dm = decision_metrics.buildMetrics(&score);
    const a = buildAdvisory(&dm);
    const b = buildAdvisory(&dm);
    try std.testing.expectEqual(a.stance, b.stance);
    try std.testing.expectEqual(a.confidence, b.confidence);
    try std.testing.expectEqual(a.allocation, b.allocation);
    try std.testing.expectEqual(a.score, b.score);
    try std.testing.expectEqual(a.ev_x1e6, b.ev_x1e6);
}

test "emitSummary: stable format" {
    const adv = DecisionAdvisory{
        .stance = .positive,
        .confidence = .medium,
        .allocation = .moderate,
        .action_mode = .observe_only,
        .score = 8,
        .posterior_x1e6 = 750000,
        .ev_x1e6 = 500000,
        .kelly_x1e6 = 500000,
        .llr_x1e6 = 1098612,
    };
    var buf: [256]u8 = undefined;
    var stream = compat.fixedBufferStream(&buf);
    adv.emitSummary(stream.writer());
    const output = buf[0..stream.pos];
    const expected = "DECISION_ADVISORY: stance=positive confidence=medium allocation=moderate action=observe_only score=8 posterior_x1e6=750000 ev_x1e6=500000 kelly_x1e6=500000 llr_x1e6=1098612\n";
    try std.testing.expectEqualSlices(u8, expected, output);
}
