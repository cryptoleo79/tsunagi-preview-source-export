// ---------------------------------------------------------------------------
// Phase 50: Shadow Policy Preview (Observe-Only)
// Derives a deterministic policy recommendation from the decision advisory.
// Answers "what policy would the node prefer?" — NOT "what will it do?"
//
// This is a shadow output: transparent, stateless, non-mutating.
// No adaptive behavior, no feedback loops, no runtime authority.
// ---------------------------------------------------------------------------

const std = @import("std");
const compat = @import("compat");
const decision_advisory = @import("decision_advisory.zig");

/// What the node would recommend under current evidence.
pub const PolicyRecommendation = enum(u8) {
    favor = 0, // evidence supports action
    hold = 1, // evidence is insufficient or balanced
    caution = 2, // evidence suggests wariness
    avoid = 3, // evidence supports inaction or rejection
};

/// How strongly the recommendation applies.
pub const PolicyStrength = enum(u8) {
    none = 0,
    light = 1,
    moderate = 2,
    strong = 3,
};

/// Action mode — always shadow_only in this phase.
pub const PolicyActionMode = enum(u8) {
    shadow_only = 0,
};

/// Complete shadow policy preview output from one forge cycle.
pub const PolicyPreview = struct {
    recommendation: PolicyRecommendation = .hold,
    strength: PolicyStrength = .none,
    action_mode: PolicyActionMode = .shadow_only,
    // Carried context from advisory
    stance: decision_advisory.DecisionStance = .neutral,
    confidence: decision_advisory.ConfidenceBand = .low,
    allocation: decision_advisory.AllocationBand = .zero,
    score: i64 = 0,
    posterior_x1e6: u64 = 500000,
    ev_x1e6: i64 = 0,
    kelly_x1e6: u64 = 0,
    llr_x1e6: i64 = 0,

    /// Emit a stable, grep-friendly summary line.
    pub fn emitSummary(self: *const PolicyPreview, w: anytype) void {
        w.print("POLICY_PREVIEW: recommendation={s} strength={s} action=shadow_only stance={s} confidence={s} allocation={s} score={d} posterior_x1e6={d} ev_x1e6={d} kelly_x1e6={d} llr_x1e6={d}\n", .{
            recName(self.recommendation),
            strName(self.strength),
            stanceName(self.stance),
            confName(self.confidence),
            allocName(self.allocation),
            self.score,
            self.posterior_x1e6,
            self.ev_x1e6,
            self.kelly_x1e6,
            self.llr_x1e6,
        }) catch {};
    }
};

/// Build a deterministic shadow policy preview from a decision advisory.
/// Pure function — no side effects, no state, no allocation.
///
/// Mapping rules:
///
/// 1. Base recommendation from stance + confidence:
///    positive + low    -> hold      positive + medium -> favor     positive + high -> favor
///    neutral + any     -> hold
///    negative + low    -> caution   negative + medium -> avoid     negative + high -> avoid
///
/// 2. Base strength from confidence:
///    low -> light, medium -> moderate, high -> strong
///    neutral stance always -> none
///
/// 3. Allocation cap (conservative guardrail):
///    allocation=zero     -> cap strength to none
///    allocation=light    -> cap strength to light
///    allocation=moderate -> cap strength to moderate
///    allocation=strong   -> allow full mapped strength
///
/// 4. Action mode: always shadow_only.
pub fn buildPreview(adv: *const decision_advisory.DecisionAdvisory) PolicyPreview {
    // Step 1: base recommendation + strength from stance + confidence
    var rec: PolicyRecommendation = .hold;
    var str: PolicyStrength = .none;

    switch (adv.stance) {
        .positive => {
            switch (adv.confidence) {
                .low => {
                    rec = .hold;
                    str = .light;
                },
                .medium => {
                    rec = .favor;
                    str = .moderate;
                },
                .high => {
                    rec = .favor;
                    str = .strong;
                },
            }
        },
        .neutral => {
            rec = .hold;
            str = .none;
        },
        .negative => {
            switch (adv.confidence) {
                .low => {
                    rec = .caution;
                    str = .light;
                },
                .medium => {
                    rec = .avoid;
                    str = .moderate;
                },
                .high => {
                    rec = .avoid;
                    str = .strong;
                },
            }
        },
    }

    // Step 2: allocation cap (conservative guardrail)
    // When Kelly allocation is low, cap strength regardless of confidence.
    const max_strength: PolicyStrength = switch (adv.allocation) {
        .zero => .none,
        .light => .light,
        .moderate => .moderate,
        .strong => .strong,
    };
    if (@intFromEnum(str) > @intFromEnum(max_strength)) {
        str = max_strength;
    }

    // If strength was capped to none and recommendation was favor, downgrade to hold
    if (str == .none and rec == .favor) rec = .hold;
    // If strength was capped to none and recommendation was avoid, downgrade to caution
    if (str == .none and rec == .avoid) rec = .caution;

    return .{
        .recommendation = rec,
        .strength = str,
        .action_mode = .shadow_only,
        .stance = adv.stance,
        .confidence = adv.confidence,
        .allocation = adv.allocation,
        .score = adv.score,
        .posterior_x1e6 = adv.posterior_x1e6,
        .ev_x1e6 = adv.ev_x1e6,
        .kelly_x1e6 = adv.kelly_x1e6,
        .llr_x1e6 = adv.llr_x1e6,
    };
}

fn recName(r: PolicyRecommendation) []const u8 {
    return switch (r) { .favor => "favor", .hold => "hold", .caution => "caution", .avoid => "avoid" };
}
fn strName(s: PolicyStrength) []const u8 {
    return switch (s) { .none => "none", .light => "light", .moderate => "moderate", .strong => "strong" };
}
fn stanceName(s: decision_advisory.DecisionStance) []const u8 {
    return switch (s) { .positive => "positive", .neutral => "neutral", .negative => "negative" };
}
fn confName(c: decision_advisory.ConfidenceBand) []const u8 {
    return switch (c) { .low => "low", .medium => "medium", .high => "high" };
}
fn allocName(a: decision_advisory.AllocationBand) []const u8 {
    return switch (a) { .zero => "zero", .light => "light", .moderate => "moderate", .strong => "strong" };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "buildPreview: positive/medium/moderate -> favor/moderate" {
    const adv = decision_advisory.DecisionAdvisory{
        .stance = .positive, .confidence = .medium, .allocation = .moderate,
        .score = 8, .posterior_x1e6 = 750000, .ev_x1e6 = 500000, .kelly_x1e6 = 500000, .llr_x1e6 = 1098612,
    };
    const pp = buildPreview(&adv);
    try std.testing.expectEqual(PolicyRecommendation.favor, pp.recommendation);
    try std.testing.expectEqual(PolicyStrength.moderate, pp.strength);
    try std.testing.expectEqual(PolicyActionMode.shadow_only, pp.action_mode);
}

test "buildPreview: positive/low/light -> hold/light" {
    const adv = decision_advisory.DecisionAdvisory{
        .stance = .positive, .confidence = .low, .allocation = .light,
        .score = 1, .posterior_x1e6 = 550000, .ev_x1e6 = 100000, .kelly_x1e6 = 100000, .llr_x1e6 = 200000,
    };
    const pp = buildPreview(&adv);
    try std.testing.expectEqual(PolicyRecommendation.hold, pp.recommendation);
    try std.testing.expectEqual(PolicyStrength.light, pp.strength);
}

test "buildPreview: positive/high/strong -> favor/strong" {
    const adv = decision_advisory.DecisionAdvisory{
        .stance = .positive, .confidence = .high, .allocation = .strong,
        .score = 19, .posterior_x1e6 = 916666, .ev_x1e6 = 833332, .kelly_x1e6 = 833332, .llr_x1e6 = 2350000,
    };
    const pp = buildPreview(&adv);
    try std.testing.expectEqual(PolicyRecommendation.favor, pp.recommendation);
    try std.testing.expectEqual(PolicyStrength.strong, pp.strength);
}

test "buildPreview: neutral -> hold/none" {
    const adv = decision_advisory.DecisionAdvisory{
        .stance = .neutral, .confidence = .medium, .allocation = .moderate,
    };
    const pp = buildPreview(&adv);
    try std.testing.expectEqual(PolicyRecommendation.hold, pp.recommendation);
    try std.testing.expectEqual(PolicyStrength.none, pp.strength);
}

test "buildPreview: negative/low/light -> caution/light" {
    const adv = decision_advisory.DecisionAdvisory{
        .stance = .negative, .confidence = .low, .allocation = .light,
        .score = -2, .ev_x1e6 = -200000, .kelly_x1e6 = 0, .llr_x1e6 = -300000,
    };
    const pp = buildPreview(&adv);
    try std.testing.expectEqual(PolicyRecommendation.caution, pp.recommendation);
    try std.testing.expectEqual(PolicyStrength.light, pp.strength);
}

test "buildPreview: negative/high/strong -> avoid/strong" {
    const adv = decision_advisory.DecisionAdvisory{
        .stance = .negative, .confidence = .high, .allocation = .strong,
        .score = -15, .ev_x1e6 = -800000, .kelly_x1e6 = 0, .llr_x1e6 = -2000000,
    };
    const pp = buildPreview(&adv);
    try std.testing.expectEqual(PolicyRecommendation.avoid, pp.recommendation);
    try std.testing.expectEqual(PolicyStrength.strong, pp.strength);
}

test "buildPreview: allocation cap — positive/high but allocation=zero -> hold/none" {
    const adv = decision_advisory.DecisionAdvisory{
        .stance = .positive, .confidence = .high, .allocation = .zero,
        .score = 5, .posterior_x1e6 = 800000, .ev_x1e6 = 600000, .kelly_x1e6 = 0, .llr_x1e6 = 1600000,
    };
    const pp = buildPreview(&adv);
    // Strong confidence but zero allocation → strength capped to none → favor downgrades to hold
    try std.testing.expectEqual(PolicyRecommendation.hold, pp.recommendation);
    try std.testing.expectEqual(PolicyStrength.none, pp.strength);
}

test "buildPreview: allocation cap — positive/high but allocation=light -> favor/light" {
    const adv = decision_advisory.DecisionAdvisory{
        .stance = .positive, .confidence = .high, .allocation = .light,
        .score = 5, .posterior_x1e6 = 800000, .ev_x1e6 = 600000, .kelly_x1e6 = 100000, .llr_x1e6 = 1600000,
    };
    const pp = buildPreview(&adv);
    // Strong mapped to light by allocation cap
    try std.testing.expectEqual(PolicyRecommendation.favor, pp.recommendation);
    try std.testing.expectEqual(PolicyStrength.light, pp.strength);
}

test "buildPreview: idempotent" {
    const adv = decision_advisory.DecisionAdvisory{
        .stance = .positive, .confidence = .medium, .allocation = .moderate,
        .score = 4, .posterior_x1e6 = 700000, .ev_x1e6 = 400000, .kelly_x1e6 = 400000, .llr_x1e6 = 800000,
    };
    const a = buildPreview(&adv);
    const b = buildPreview(&adv);
    try std.testing.expectEqual(a.recommendation, b.recommendation);
    try std.testing.expectEqual(a.strength, b.strength);
    try std.testing.expectEqual(a.score, b.score);
}

test "emitSummary: stable format" {
    const pp = PolicyPreview{
        .recommendation = .favor,
        .strength = .moderate,
        .stance = .positive,
        .confidence = .medium,
        .allocation = .moderate,
        .score = 8,
        .posterior_x1e6 = 750000,
        .ev_x1e6 = 500000,
        .kelly_x1e6 = 500000,
        .llr_x1e6 = 1098612,
    };
    var buf: [300]u8 = undefined;
    var stream = compat.fixedBufferStream(&buf);
    pp.emitSummary(stream.writer());
    const output = buf[0..stream.pos];
    const expected = "POLICY_PREVIEW: recommendation=favor strength=moderate action=shadow_only stance=positive confidence=medium allocation=moderate score=8 posterior_x1e6=750000 ev_x1e6=500000 kelly_x1e6=500000 llr_x1e6=1098612\n";
    try std.testing.expectEqualSlices(u8, expected, output);
}
