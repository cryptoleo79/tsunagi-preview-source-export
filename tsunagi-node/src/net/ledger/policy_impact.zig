// ---------------------------------------------------------------------------
// Phase 51: Shadow Policy Impact Simulation (Shadow-Only)
// Derives a deterministic impact simulation from the policy preview.
// Answers "if this preview policy were active, what domain would it touch?"
// Does NOT answer "what will the node do now?"
//
// This is a shadow output: transparent, stateless, non-mutating.
// No adaptive behavior, no feedback loops, no runtime authority.
// ---------------------------------------------------------------------------

const std = @import("std");
const compat = @import("compat");
const policy_preview = @import("policy_preview.zig");
const decision_advisory = @import("decision_advisory.zig");

/// What domain the simulated policy would have touched.
pub const ImpactKind = enum(u8) {
    none = 0, // no runtime domain would be affected
    ordering_bias = 1, // candidate ordering would be influenced
    enforcement_bias = 2, // enforcement decisions would be influenced
};

/// Action mode — always shadow_only in this phase.
pub const ImpactActionMode = enum(u8) {
    shadow_only = 0,
};

/// Complete shadow policy impact simulation from one forge cycle.
pub const PolicyImpact = struct {
    impact_kind: ImpactKind = .none,
    touch_ordering: bool = false,
    touch_enforcement: bool = false,
    touch_mempool: bool = false, // always false in this phase
    action_mode: ImpactActionMode = .shadow_only,
    // Carried context
    recommendation: policy_preview.PolicyRecommendation = .hold,
    strength: policy_preview.PolicyStrength = .none,
    stance: decision_advisory.DecisionStance = .neutral,
    confidence: decision_advisory.ConfidenceBand = .low,
    allocation: decision_advisory.AllocationBand = .zero,
    score: i64 = 0,
    posterior_x1e6: u64 = 500000,
    ev_x1e6: i64 = 0,
    kelly_x1e6: u64 = 0,
    llr_x1e6: i64 = 0,

    /// Emit a stable, grep-friendly summary line.
    pub fn emitSummary(self: *const PolicyImpact, w: anytype) void {
        w.print("POLICY_IMPACT: kind={s} touch_ordering={s} touch_enforcement={s} touch_mempool={s} action=shadow_only recommendation={s} strength={s} stance={s} confidence={s} allocation={s} score={d} posterior_x1e6={d} ev_x1e6={d} kelly_x1e6={d} llr_x1e6={d}\n", .{
            kindName(self.impact_kind),
            boolName(self.touch_ordering),
            boolName(self.touch_enforcement),
            boolName(self.touch_mempool),
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

/// Build a deterministic shadow policy impact from a policy preview.
/// Pure function — no side effects, no state, no allocation.
///
/// Mapping rules:
///
/// 1. recommendation=favor:
///    strength=none  -> kind=none
///    strength>none  -> kind=ordering_bias, touch_ordering=true
///
/// 2. recommendation=hold:
///    always kind=none, no touches
///
/// 3. recommendation=caution or avoid:
///    strength=none  -> kind=none
///    strength>none  -> kind=enforcement_bias, touch_enforcement=true
///
/// 4. touch_mempool: always false in this phase
/// 5. action_mode: always shadow_only
pub fn buildImpact(pp: *const policy_preview.PolicyPreview) PolicyImpact {
    var impact = PolicyImpact{
        .action_mode = .shadow_only,
        .recommendation = pp.recommendation,
        .strength = pp.strength,
        .stance = pp.stance,
        .confidence = pp.confidence,
        .allocation = pp.allocation,
        .score = pp.score,
        .posterior_x1e6 = pp.posterior_x1e6,
        .ev_x1e6 = pp.ev_x1e6,
        .kelly_x1e6 = pp.kelly_x1e6,
        .llr_x1e6 = pp.llr_x1e6,
    };

    const has_strength = pp.strength != .none;

    switch (pp.recommendation) {
        .favor => {
            if (has_strength) {
                impact.impact_kind = .ordering_bias;
                impact.touch_ordering = true;
            }
        },
        .hold => {},
        .caution, .avoid => {
            if (has_strength) {
                impact.impact_kind = .enforcement_bias;
                impact.touch_enforcement = true;
            }
        },
    }

    return impact;
}

fn kindName(k: ImpactKind) []const u8 {
    return switch (k) { .none => "none", .ordering_bias => "ordering_bias", .enforcement_bias => "enforcement_bias" };
}
fn boolName(b: bool) []const u8 {
    return if (b) "true" else "false";
}
fn recName(r: policy_preview.PolicyRecommendation) []const u8 {
    return switch (r) { .favor => "favor", .hold => "hold", .caution => "caution", .avoid => "avoid" };
}
fn strName(s: policy_preview.PolicyStrength) []const u8 {
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

test "buildImpact: favor/moderate -> ordering_bias" {
    const pp = policy_preview.PolicyPreview{
        .recommendation = .favor, .strength = .moderate,
        .stance = .positive, .confidence = .medium, .allocation = .moderate,
        .score = 8, .posterior_x1e6 = 750000, .ev_x1e6 = 500000, .kelly_x1e6 = 500000, .llr_x1e6 = 1098612,
    };
    const imp = buildImpact(&pp);
    try std.testing.expectEqual(ImpactKind.ordering_bias, imp.impact_kind);
    try std.testing.expectEqual(true, imp.touch_ordering);
    try std.testing.expectEqual(false, imp.touch_enforcement);
    try std.testing.expectEqual(false, imp.touch_mempool);
    try std.testing.expectEqual(ImpactActionMode.shadow_only, imp.action_mode);
}

test "buildImpact: favor/strong -> ordering_bias" {
    const pp = policy_preview.PolicyPreview{
        .recommendation = .favor, .strength = .strong,
        .stance = .positive, .confidence = .high, .allocation = .strong,
    };
    const imp = buildImpact(&pp);
    try std.testing.expectEqual(ImpactKind.ordering_bias, imp.impact_kind);
    try std.testing.expectEqual(true, imp.touch_ordering);
    try std.testing.expectEqual(false, imp.touch_enforcement);
}

test "buildImpact: favor/none -> no impact" {
    const pp = policy_preview.PolicyPreview{
        .recommendation = .favor, .strength = .none,
    };
    const imp = buildImpact(&pp);
    try std.testing.expectEqual(ImpactKind.none, imp.impact_kind);
    try std.testing.expectEqual(false, imp.touch_ordering);
}

test "buildImpact: hold -> no impact" {
    const pp = policy_preview.PolicyPreview{
        .recommendation = .hold, .strength = .none,
        .stance = .neutral,
    };
    const imp = buildImpact(&pp);
    try std.testing.expectEqual(ImpactKind.none, imp.impact_kind);
    try std.testing.expectEqual(false, imp.touch_ordering);
    try std.testing.expectEqual(false, imp.touch_enforcement);
    try std.testing.expectEqual(false, imp.touch_mempool);
}

test "buildImpact: caution/light -> enforcement_bias" {
    const pp = policy_preview.PolicyPreview{
        .recommendation = .caution, .strength = .light,
        .stance = .negative, .confidence = .low, .allocation = .light,
    };
    const imp = buildImpact(&pp);
    try std.testing.expectEqual(ImpactKind.enforcement_bias, imp.impact_kind);
    try std.testing.expectEqual(false, imp.touch_ordering);
    try std.testing.expectEqual(true, imp.touch_enforcement);
    try std.testing.expectEqual(false, imp.touch_mempool);
}

test "buildImpact: avoid/strong -> enforcement_bias" {
    const pp = policy_preview.PolicyPreview{
        .recommendation = .avoid, .strength = .strong,
        .stance = .negative, .confidence = .high, .allocation = .strong,
    };
    const imp = buildImpact(&pp);
    try std.testing.expectEqual(ImpactKind.enforcement_bias, imp.impact_kind);
    try std.testing.expectEqual(true, imp.touch_enforcement);
    try std.testing.expectEqual(false, imp.touch_ordering);
}

test "buildImpact: avoid/none -> no impact" {
    const pp = policy_preview.PolicyPreview{
        .recommendation = .avoid, .strength = .none,
    };
    const imp = buildImpact(&pp);
    try std.testing.expectEqual(ImpactKind.none, imp.impact_kind);
    try std.testing.expectEqual(false, imp.touch_enforcement);
}

test "buildImpact: touch_mempool always false" {
    const cases = [_]policy_preview.PolicyRecommendation{ .favor, .hold, .caution, .avoid };
    const strengths = [_]policy_preview.PolicyStrength{ .none, .light, .moderate, .strong };
    for (cases) |rec| {
        for (strengths) |str| {
            const pp = policy_preview.PolicyPreview{ .recommendation = rec, .strength = str };
            const imp = buildImpact(&pp);
            try std.testing.expectEqual(false, imp.touch_mempool);
        }
    }
}

test "buildImpact: idempotent" {
    const pp = policy_preview.PolicyPreview{
        .recommendation = .favor, .strength = .moderate,
        .score = 4, .ev_x1e6 = 400000,
    };
    const a = buildImpact(&pp);
    const b = buildImpact(&pp);
    try std.testing.expectEqual(a.impact_kind, b.impact_kind);
    try std.testing.expectEqual(a.touch_ordering, b.touch_ordering);
    try std.testing.expectEqual(a.touch_enforcement, b.touch_enforcement);
    try std.testing.expectEqual(a.score, b.score);
}

test "emitSummary: stable format" {
    const imp = PolicyImpact{
        .impact_kind = .ordering_bias,
        .touch_ordering = true,
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
    var buf: [400]u8 = undefined;
    var stream = compat.fixedBufferStream(&buf);
    imp.emitSummary(stream.writer());
    const output = buf[0..stream.pos];
    const expected = "POLICY_IMPACT: kind=ordering_bias touch_ordering=true touch_enforcement=false touch_mempool=false action=shadow_only recommendation=favor strength=moderate stance=positive confidence=medium allocation=moderate score=8 posterior_x1e6=750000 ev_x1e6=500000 kelly_x1e6=500000 llr_x1e6=1098612\n";
    try std.testing.expectEqualSlices(u8, expected, output);
}
