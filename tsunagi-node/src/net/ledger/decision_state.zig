// ---------------------------------------------------------------------------
// Phase 53: Decision Stack Operator Surface
// Exposes the full decision pipeline state for operator visibility.
// No new behavior coupling. Pure visibility/auditability.
// ---------------------------------------------------------------------------

const std = @import("std");
const compat = @import("compat");

/// Snapshot of the full decision stack from one forge cycle.
/// Written by the producer, readable by /decision endpoint and Prometheus.
/// All fields are atomic-safe via copy-on-write (producer writes, reader copies).
pub const DecisionStackSnapshot = struct {
    // Trust score
    trust_positive: u64 = 0,
    trust_negative: u64 = 0,
    trust_neutral: u64 = 0,
    trust_score: i64 = 0,

    // Decision metrics (BAeY / EV / Kelly / LLR)
    alpha: u64 = 1,
    beta: u64 = 1,
    posterior_x1e6: u64 = 500000,
    ev_x1e6: i64 = 0,
    kelly_x1e6: u64 = 0,
    llr_x1e6: i64 = 0,

    // Advisory
    stance: u8 = 1, // 0=positive, 1=neutral, 2=negative
    confidence: u8 = 0, // 0=low, 1=medium, 2=high
    allocation: u8 = 0, // 0=zero, 1=light, 2=moderate, 3=strong

    // Policy preview
    recommendation: u8 = 1, // 0=favor, 1=hold, 2=caution, 3=avoid
    strength: u8 = 0, // 0=none, 1=light, 2=moderate, 3=strong

    // Policy impact
    impact_kind: u8 = 0, // 0=none, 1=ordering_bias, 2=enforcement_bias
    touch_ordering: bool = false,
    touch_enforcement: bool = false,
    touch_mempool: bool = false,

    // Policy apply
    apply_active: bool = false,
    enforce_apply_active: bool = false,
    experiment_ordering_enabled: bool = false,
    experiment_enforcement_enabled: bool = false,
    preview_guard_passed: bool = false,

    // Cycle metadata
    cycle_unix: i64 = 0,
};

/// Global snapshot — written by producer, read by operator surfaces.
/// Not atomic per-field (producer writes complete struct, reader copies complete struct).
/// Safe because: producer is single-threaded forge loop, reader is HTTP handler
/// that copies the entire struct before formatting.
pub var g_decision_state: DecisionStackSnapshot = .{};

/// Write the decision stack as JSON to any writer.
pub fn writeJson(state: *const DecisionStackSnapshot, w: anytype) void {
    w.print(
        \\{{"decision_stack":{{"cycle_unix":{d},
        \\"trust":{{"positive":{d},"negative":{d},"neutral":{d},"score":{d}}},
        \\"metrics":{{"alpha":{d},"beta":{d},"posterior_x1e6":{d},"ev_x1e6":{d},"kelly_x1e6":{d},"llr_x1e6":{d}}},
        \\"advisory":{{"stance":"{s}","confidence":"{s}","allocation":"{s}"}},
        \\"preview":{{"recommendation":"{s}","strength":"{s}"}},
        \\"impact":{{"kind":"{s}","touch_ordering":{s},"touch_enforcement":{s},"touch_mempool":{s}}},
        \\"apply":{{"active":{s},"enforce_active":{s},"experiment_ordering_enabled":{s},"experiment_enforcement_enabled":{s},"preview_guard_passed":{s}}}}}}}
    , .{
        state.cycle_unix,
        state.trust_positive, state.trust_negative, state.trust_neutral, state.trust_score,
        state.alpha, state.beta, state.posterior_x1e6, state.ev_x1e6, state.kelly_x1e6, state.llr_x1e6,
        stanceName(state.stance), confName(state.confidence), allocName(state.allocation),
        recName(state.recommendation), strName(state.strength),
        impactName(state.impact_kind), boolStr(state.touch_ordering), boolStr(state.touch_enforcement), boolStr(state.touch_mempool),
        boolStr(state.apply_active), boolStr(state.enforce_apply_active), boolStr(state.experiment_ordering_enabled), boolStr(state.experiment_enforcement_enabled), boolStr(state.preview_guard_passed),
    }) catch {};
}

fn stanceName(v: u8) []const u8 { return switch (v) { 0 => "positive", 2 => "negative", else => "neutral" }; }
fn confName(v: u8) []const u8 { return switch (v) { 1 => "medium", 2 => "high", else => "low" }; }
fn allocName(v: u8) []const u8 { return switch (v) { 1 => "light", 2 => "moderate", 3 => "strong", else => "zero" }; }
fn recName(v: u8) []const u8 { return switch (v) { 0 => "favor", 2 => "caution", 3 => "avoid", else => "hold" }; }
fn strName(v: u8) []const u8 { return switch (v) { 1 => "light", 2 => "moderate", 3 => "strong", else => "none" }; }
fn impactName(v: u8) []const u8 { return switch (v) { 1 => "ordering_bias", 2 => "enforcement_bias", else => "none" }; }
fn boolStr(v: bool) []const u8 { return if (v) "true" else "false"; }

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "writeJson: default state" {
    var buf: [1024]u8 = undefined;
    var stream = compat.fixedBufferStream(&buf);
    const state = DecisionStackSnapshot{};
    writeJson(&state, stream.writer());
    const output = buf[0..stream.pos];
    // Verify it's valid-looking JSON with expected fields
    try std.testing.expect(std.mem.startsWith(u8, output, "{\"decision_stack\":{"));
    try std.testing.expect(std.mem.indexOf(u8, output, "\"trust\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"metrics\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"advisory\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"preview\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"impact\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"apply\":{") != null);
}

test "writeJson: non-default state" {
    const state = DecisionStackSnapshot{
        .trust_positive = 2, .trust_score = 2,
        .alpha = 3, .beta = 1, .posterior_x1e6 = 750000, .ev_x1e6 = 500000, .kelly_x1e6 = 500000, .llr_x1e6 = 1098612,
        .stance = 0, .confidence = 1, .allocation = 2,
        .recommendation = 0, .strength = 2,
        .impact_kind = 1, .touch_ordering = true,
        .apply_active = true, .experiment_ordering_enabled = true, .preview_guard_passed = true,
        .cycle_unix = 1775600000,
    };
    var buf: [1024]u8 = undefined;
    var stream = compat.fixedBufferStream(&buf);
    writeJson(&state, stream.writer());
    const output = buf[0..stream.pos];
    try std.testing.expect(std.mem.indexOf(u8, output, "\"stance\":\"positive\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"recommendation\":\"favor\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"kind\":\"ordering_bias\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"active\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"experiment_ordering_enabled\":true") != null);
}
