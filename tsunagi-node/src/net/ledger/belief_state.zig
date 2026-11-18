// ---------------------------------------------------------------------------
// Phase 45: BAeY-Compatible Belief Foundation (Observe-Only)
// Converts trust-signal evidence into explicit belief-ready state structures.
// Deterministic, node-local, lightweight.
//
// BAeY (Bayesian Evaluation), EV, Kelly Criterion, and LLR are NOT
// implemented here. They are future-compatible architectural targets.
// This module provides the belief-state encoding layer that future
// decision-theoretic work will consume.
// ---------------------------------------------------------------------------

const std = @import("std");
const compat = @import("compat");
const trust_signal = @import("trust_signal.zig");

/// Source of a belief observation.
pub const BeliefSource = enum(u8) {
    forge_external = 0, // from forge-path external evaluation evidence
};

/// Evidence category for BAeY-compatible belief mapping.
pub const EvidenceCategory = enum(u8) {
    confirming = 0, // evidence supporting expected behavior
    disconfirming = 1, // evidence contradicting expected behavior
    unavailable = 2, // backend was not reachable
    unsupported = 3, // case fell outside known boundary
    invalid = 4, // response was malformed
};

/// Accumulated belief-ready state from a single forge cycle.
/// Fixed-size, no allocator, deterministic.
/// This is NOT a posterior distribution — it is structured evidence
/// ready for future BAeY / EV / Kelly / LLR consumption.
pub const ForgeBeliefSnapshot = struct {
    source: BeliefSource = .forge_external,
    total_observations: u32 = 0,
    confirming: u32 = 0,
    disconfirming: u32 = 0,
    unavailable: u32 = 0,
    unsupported: u32 = 0,
    invalid: u32 = 0,

    /// Emit a stable, grep-friendly summary line to the provided writer.
    pub fn emitSummary(self: *const ForgeBeliefSnapshot, w: anytype) void {
        w.print("BELIEF_STATE: source=forge_external total={d} confirming={d} disconfirming={d} unavailable={d} unsupported={d} invalid={d}\n", .{
            self.total_observations,
            self.confirming,
            self.disconfirming,
            self.unavailable,
            self.unsupported,
            self.invalid,
        }) catch {};
    }
};

/// Build a ForgeBeliefSnapshot from a trust-signal ForgeSignalSnapshot.
/// Pure, deterministic mapping:
///   supported_pass    → confirming
///   supported_fail    → disconfirming
///   backend_unavailable → unavailable
///   case_not_supported  → unsupported
///   invalid_response    → invalid
pub fn buildBeliefFromSignal(sig: *const trust_signal.ForgeSignalSnapshot) ForgeBeliefSnapshot {
    return .{
        .source = .forge_external,
        .total_observations = sig.checked,
        .confirming = sig.supported_pass,
        .disconfirming = sig.supported_fail,
        .unavailable = sig.backend_unavailable,
        .unsupported = sig.case_not_supported,
        .invalid = sig.invalid_response,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "buildBeliefFromSignal: deterministic mapping" {
    const sig = trust_signal.ForgeSignalSnapshot{
        .checked = 10,
        .supported_pass = 3,
        .supported_fail = 1,
        .backend_unavailable = 2,
        .case_not_supported = 4,
        .invalid_response = 0,
    };
    const belief = buildBeliefFromSignal(&sig);
    try std.testing.expectEqual(BeliefSource.forge_external, belief.source);
    try std.testing.expectEqual(@as(u32, 10), belief.total_observations);
    try std.testing.expectEqual(@as(u32, 3), belief.confirming);
    try std.testing.expectEqual(@as(u32, 1), belief.disconfirming);
    try std.testing.expectEqual(@as(u32, 2), belief.unavailable);
    try std.testing.expectEqual(@as(u32, 4), belief.unsupported);
    try std.testing.expectEqual(@as(u32, 0), belief.invalid);
}

test "buildBeliefFromSignal: zero counters" {
    const sig = trust_signal.ForgeSignalSnapshot{};
    const belief = buildBeliefFromSignal(&sig);
    try std.testing.expectEqual(@as(u32, 0), belief.total_observations);
    try std.testing.expectEqual(@as(u32, 0), belief.confirming);
    try std.testing.expectEqual(@as(u32, 0), belief.disconfirming);
}

test "buildBeliefFromSignal: idempotent" {
    const sig = trust_signal.ForgeSignalSnapshot{
        .checked = 5,
        .supported_pass = 2,
        .supported_fail = 1,
        .backend_unavailable = 0,
        .case_not_supported = 2,
        .invalid_response = 0,
    };
    const a = buildBeliefFromSignal(&sig);
    const b = buildBeliefFromSignal(&sig);
    try std.testing.expectEqual(a.total_observations, b.total_observations);
    try std.testing.expectEqual(a.confirming, b.confirming);
    try std.testing.expectEqual(a.disconfirming, b.disconfirming);
    try std.testing.expectEqual(a.unavailable, b.unavailable);
    try std.testing.expectEqual(a.unsupported, b.unsupported);
    try std.testing.expectEqual(a.invalid, b.invalid);
}

test "emitSummary: stable format" {
    const sig = trust_signal.ForgeSignalSnapshot{
        .checked = 6,
        .supported_pass = 1,
        .supported_fail = 1,
        .backend_unavailable = 1,
        .case_not_supported = 2,
        .invalid_response = 1,
    };
    const belief = buildBeliefFromSignal(&sig);
    var buf: [256]u8 = undefined;
    var stream = compat.fixedBufferStream(&buf);
    belief.emitSummary(stream.writer());
    const output = buf[0..stream.pos];
    const expected = "BELIEF_STATE: source=forge_external total=6 confirming=1 disconfirming=1 unavailable=1 unsupported=2 invalid=1\n";
    try std.testing.expectEqualSlices(u8, expected, output);
}
