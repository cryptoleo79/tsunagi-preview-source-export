// ---------------------------------------------------------------------------
// Phase 52/54: Preview-Only Policy-Coupled Experiments
// Pure helpers for determining whether shadow policy impact should activate
// existing proven paths (reorder, enforce_safe) for a forge cycle.
//
// These are the first points where policy output may couple to runtime behavior.
// Must be: preview-only, operator-enabled, domain-specific, deterministic.
//
// NOT adaptive policy. NOT autonomous. NOT self-healing.
// ---------------------------------------------------------------------------

const std = @import("std");
const compat = @import("compat");
const policy_impact = @import("policy_impact.zig");
const policy_preview = @import("policy_preview.zig");

/// Result of the policy-apply activation check.
pub const PolicyApplyResult = struct {
    active: bool = false,
    reason: []const u8 = "none",
    strength: []const u8 = "none",
};

/// Determine whether the policy-coupled ordering experiment should activate.
/// Pure function — no side effects, no state, no allocation.
///
/// Activation requires ALL of:
///   1. experiment_enabled = true (TSUNAGI_POLICY_EXPERIMENT=ordering_bias_preview)
///   2. preview_only = true (TSUNAGI_FORGE_PREVIEW_ONLY=1)
///   3. impact.impact_kind = .ordering_bias
///   4. impact.touch_ordering = true
///
/// If any condition is false, returns inactive.
pub fn shouldActivateOrdering(
    experiment_enabled: bool,
    preview_only: bool,
    impact: *const policy_impact.PolicyImpact,
) PolicyApplyResult {
    if (!experiment_enabled) return .{};
    if (!preview_only) return .{};
    if (impact.impact_kind != .ordering_bias) return .{};
    if (!impact.touch_ordering) return .{};

    return .{
        .active = true,
        .reason = "ordering_bias",
        .strength = switch (impact.strength) {
            .none => "none",
            .light => "light",
            .moderate => "moderate",
            .strong => "strong",
        },
    };
}

/// Determine whether the policy-coupled enforcement experiment should activate.
/// Pure function — no side effects, no state, no allocation.
///
/// Activation requires ALL of:
///   1. experiment_enabled = true (TSUNAGI_POLICY_EXPERIMENT=enforcement_bias_preview)
///   2. preview_only = true (TSUNAGI_FORGE_PREVIEW_ONLY=1)
///   3. impact.impact_kind = .enforcement_bias
///   4. impact.touch_enforcement = true
///
/// If any condition is false, returns inactive.
pub fn shouldActivateEnforcement(
    experiment_enabled: bool,
    preview_only: bool,
    impact: *const policy_impact.PolicyImpact,
) PolicyApplyResult {
    if (!experiment_enabled) return .{};
    if (!preview_only) return .{};
    if (impact.impact_kind != .enforcement_bias) return .{};
    if (!impact.touch_enforcement) return .{};

    return .{
        .active = true,
        .reason = "enforcement_bias",
        .strength = switch (impact.strength) {
            .none => "none",
            .light => "light",
            .moderate => "moderate",
            .strong => "strong",
        },
    };
}

/// Emit a stable, grep-friendly policy-apply summary line for ordering domain.
pub fn emitApplySummary(result: *const PolicyApplyResult, w: anytype) void {
    w.print("POLICY_APPLY: domain=ordering experiment=ordering_bias_preview active={d} reason={s} strength={s} mode=preview_only\n", .{
        @as(u32, if (result.active) 1 else 0),
        result.reason,
        result.strength,
    }) catch {};
}

/// Emit a stable, grep-friendly policy-apply summary line for enforcement domain.
pub fn emitEnforcementApplySummary(result: *const PolicyApplyResult, w: anytype) void {
    w.print("POLICY_APPLY: domain=enforcement experiment=enforcement_bias_preview active={d} reason={s} strength={s} mode=preview_only\n", .{
        @as(u32, if (result.active) 1 else 0),
        result.reason,
        result.strength,
    }) catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn makeImpact(kind: policy_impact.ImpactKind, touch_ord: bool, str: policy_preview.PolicyStrength) policy_impact.PolicyImpact {
    return .{
        .impact_kind = kind,
        .touch_ordering = touch_ord,
        .strength = str,
    };
}

test "shouldActivateOrdering: all conditions met -> active" {
    const impact = makeImpact(.ordering_bias, true, .moderate);
    const result = shouldActivateOrdering(true, true, &impact);
    try std.testing.expectEqual(true, result.active);
    try std.testing.expectEqualSlices(u8, "ordering_bias", result.reason);
    try std.testing.expectEqualSlices(u8, "moderate", result.strength);
}

test "shouldActivateOrdering: experiment off -> inactive" {
    const impact = makeImpact(.ordering_bias, true, .moderate);
    const result = shouldActivateOrdering(false, true, &impact);
    try std.testing.expectEqual(false, result.active);
    try std.testing.expectEqualSlices(u8, "none", result.reason);
}

test "shouldActivateOrdering: not preview -> inactive" {
    const impact = makeImpact(.ordering_bias, true, .moderate);
    const result = shouldActivateOrdering(true, false, &impact);
    try std.testing.expectEqual(false, result.active);
}

test "shouldActivateOrdering: impact kind none -> inactive" {
    const impact = makeImpact(.none, false, .none);
    const result = shouldActivateOrdering(true, true, &impact);
    try std.testing.expectEqual(false, result.active);
}

test "shouldActivateOrdering: impact kind enforcement_bias -> inactive" {
    const impact = makeImpact(.enforcement_bias, false, .moderate);
    const result = shouldActivateOrdering(true, true, &impact);
    try std.testing.expectEqual(false, result.active);
}

test "shouldActivateOrdering: touch_ordering false -> inactive" {
    var impact = makeImpact(.ordering_bias, false, .moderate);
    impact.touch_ordering = false;
    const result = shouldActivateOrdering(true, true, &impact);
    try std.testing.expectEqual(false, result.active);
}

test "shouldActivateOrdering: strong strength carried through" {
    const impact = makeImpact(.ordering_bias, true, .strong);
    const result = shouldActivateOrdering(true, true, &impact);
    try std.testing.expectEqual(true, result.active);
    try std.testing.expectEqualSlices(u8, "strong", result.strength);
}

test "shouldActivateOrdering: idempotent" {
    const impact = makeImpact(.ordering_bias, true, .moderate);
    const a = shouldActivateOrdering(true, true, &impact);
    const b = shouldActivateOrdering(true, true, &impact);
    try std.testing.expectEqual(a.active, b.active);
    try std.testing.expectEqualSlices(u8, a.reason, b.reason);
    try std.testing.expectEqualSlices(u8, a.strength, b.strength);
}

test "emitApplySummary: active format" {
    const result = PolicyApplyResult{ .active = true, .reason = "ordering_bias", .strength = "moderate" };
    var buf: [200]u8 = undefined;
    var stream = compat.fixedBufferStream(&buf);
    emitApplySummary(&result, stream.writer());
    const output = buf[0..stream.pos];
    const expected = "POLICY_APPLY: domain=ordering experiment=ordering_bias_preview active=1 reason=ordering_bias strength=moderate mode=preview_only\n";
    try std.testing.expectEqualSlices(u8, expected, output);
}

test "emitApplySummary: inactive format" {
    const result = PolicyApplyResult{};
    var buf: [200]u8 = undefined;
    var stream = compat.fixedBufferStream(&buf);
    emitApplySummary(&result, stream.writer());
    const output = buf[0..stream.pos];
    const expected = "POLICY_APPLY: domain=ordering experiment=ordering_bias_preview active=0 reason=none strength=none mode=preview_only\n";
    try std.testing.expectEqualSlices(u8, expected, output);
}

// ---------------------------------------------------------------------------
// Phase 54: Enforcement Experiment Tests
// ---------------------------------------------------------------------------

fn makeEnforcementImpact(kind: policy_impact.ImpactKind, touch_enf: bool, str: policy_preview.PolicyStrength) policy_impact.PolicyImpact {
    return .{
        .impact_kind = kind,
        .touch_enforcement = touch_enf,
        .strength = str,
    };
}

test "shouldActivateEnforcement: all conditions met -> active" {
    const impact = makeEnforcementImpact(.enforcement_bias, true, .moderate);
    const result = shouldActivateEnforcement(true, true, &impact);
    try std.testing.expectEqual(true, result.active);
    try std.testing.expectEqualSlices(u8, "enforcement_bias", result.reason);
    try std.testing.expectEqualSlices(u8, "moderate", result.strength);
}

test "shouldActivateEnforcement: experiment off -> inactive" {
    const impact = makeEnforcementImpact(.enforcement_bias, true, .moderate);
    const result = shouldActivateEnforcement(false, true, &impact);
    try std.testing.expectEqual(false, result.active);
}

test "shouldActivateEnforcement: not preview -> inactive" {
    const impact = makeEnforcementImpact(.enforcement_bias, true, .moderate);
    const result = shouldActivateEnforcement(true, false, &impact);
    try std.testing.expectEqual(false, result.active);
}

test "shouldActivateEnforcement: impact kind none -> inactive" {
    const impact = makeEnforcementImpact(.none, false, .none);
    const result = shouldActivateEnforcement(true, true, &impact);
    try std.testing.expectEqual(false, result.active);
}

test "shouldActivateEnforcement: impact kind ordering_bias -> inactive" {
    const impact = makeEnforcementImpact(.ordering_bias, false, .moderate);
    const result = shouldActivateEnforcement(true, true, &impact);
    try std.testing.expectEqual(false, result.active);
}

test "shouldActivateEnforcement: touch_enforcement false -> inactive" {
    var impact = makeEnforcementImpact(.enforcement_bias, false, .moderate);
    impact.touch_enforcement = false;
    const result = shouldActivateEnforcement(true, true, &impact);
    try std.testing.expectEqual(false, result.active);
}

test "shouldActivateEnforcement: strong strength carried" {
    const impact = makeEnforcementImpact(.enforcement_bias, true, .strong);
    const result = shouldActivateEnforcement(true, true, &impact);
    try std.testing.expectEqual(true, result.active);
    try std.testing.expectEqualSlices(u8, "strong", result.strength);
}

test "shouldActivateEnforcement: idempotent" {
    const impact = makeEnforcementImpact(.enforcement_bias, true, .moderate);
    const a = shouldActivateEnforcement(true, true, &impact);
    const b = shouldActivateEnforcement(true, true, &impact);
    try std.testing.expectEqual(a.active, b.active);
    try std.testing.expectEqualSlices(u8, a.reason, b.reason);
}

test "emitEnforcementApplySummary: active format" {
    const result = PolicyApplyResult{ .active = true, .reason = "enforcement_bias", .strength = "moderate" };
    var buf: [200]u8 = undefined;
    var stream = compat.fixedBufferStream(&buf);
    emitEnforcementApplySummary(&result, stream.writer());
    const output = buf[0..stream.pos];
    const expected = "POLICY_APPLY: domain=enforcement experiment=enforcement_bias_preview active=1 reason=enforcement_bias strength=moderate mode=preview_only\n";
    try std.testing.expectEqualSlices(u8, expected, output);
}

test "emitEnforcementApplySummary: inactive format" {
    const result = PolicyApplyResult{};
    var buf: [200]u8 = undefined;
    var stream = compat.fixedBufferStream(&buf);
    emitEnforcementApplySummary(&result, stream.writer());
    const output = buf[0..stream.pos];
    const expected = "POLICY_APPLY: domain=enforcement experiment=enforcement_bias_preview active=0 reason=none strength=none mode=preview_only\n";
    try std.testing.expectEqualSlices(u8, expected, output);
}
