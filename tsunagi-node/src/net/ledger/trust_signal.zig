// ---------------------------------------------------------------------------
// Phase 44: Trust Signal Foundation (Observe-Only)
// Converts observed forge/external outcomes into explicit trust-relevant
// evidence structures. Deterministic, node-local, lightweight.
//
// This is NOT trust scoring, BAeY, EV, Kelly, LLR, or adaptive behavior.
// Those are future-compatible architectural targets, not implemented here.
// This module provides the evidence encoding layer that future decision-
// theoretic work will consume.
// ---------------------------------------------------------------------------

const std = @import("std");
const compat = @import("compat");

/// Source of a trust-relevant observation.
pub const SignalSource = enum(u8) {
    forge_external = 0, // from external evaluator boundary check in forge path
    mempool = 1, // from mempool validation outcomes
};

/// Observed outcome class from the signal source.
/// Maps 1:1 from ExternalBoundaryResult for forge_external source.
pub const ObservedOutcome = enum(u8) {
    supported_pass = 0,
    supported_fail = 1,
    backend_unavailable = 2,
    case_not_supported = 3,
    invalid_response = 4,
};

/// Accumulated trust-signal evidence from a single forge cycle.
/// Fixed-size, no allocator, deterministic.
pub const ForgeSignalSnapshot = struct {
    source: SignalSource = .forge_external,
    checked: u32 = 0,
    supported_pass: u32 = 0,
    supported_fail: u32 = 0,
    backend_unavailable: u32 = 0,
    case_not_supported: u32 = 0,
    invalid_response: u32 = 0,

    /// Emit a stable, grep-friendly summary line to the provided writer.
    pub fn emitSummary(self: *const ForgeSignalSnapshot, w: anytype) void {
        w.print("TRUST_SIGNAL: source=forge_external category=execution supported_pass={d} supported_fail={d} backend_unavailable={d} case_not_supported={d} invalid_response={d}\n", .{
            self.supported_pass,
            self.supported_fail,
            self.backend_unavailable,
            self.case_not_supported,
            self.invalid_response,
        }) catch {};
    }
};

/// Build a ForgeSignalSnapshot from already-accumulated Phase 42 counters.
/// Pure function — no side effects.
pub fn buildForgeSignal(
    checked: u32,
    supported_pass: u32,
    supported_fail: u32,
    backend_unavailable: u32,
    case_not_supported: u32,
    invalid_response: u32,
) ForgeSignalSnapshot {
    return .{
        .source = .forge_external,
        .checked = checked,
        .supported_pass = supported_pass,
        .supported_fail = supported_fail,
        .backend_unavailable = backend_unavailable,
        .case_not_supported = case_not_supported,
        .invalid_response = invalid_response,
    };
}

// ---------------------------------------------------------------------------
// Phase 45: Mempool Validation Signal (Second Source)
// Maps existing mempool counters into normalized trust-signal evidence.
// Read-only on mempool state — no mutation.
// ---------------------------------------------------------------------------

const mempool_mod = @import("mempool.zig");

/// Accumulated trust-signal evidence from mempool validation outcomes.
/// All counters map directly to existing Mempool struct fields.
/// Fixed-size, no allocator, deterministic.
pub const MempoolSignalSnapshot = struct {
    source: SignalSource = .mempool,
    accepted: u64 = 0,
    rejected_total: u64 = 0,
    rejected_conflict: u64 = 0,
    rejected_missing_input: u64 = 0,
    rejected_balance: u64 = 0,
    rejected_validity: u64 = 0, // ttl_expired + validity_start_future
    rejected_plutus_unsupported: u64 = 0,

    /// Emit a stable, grep-friendly summary line to the provided writer.
    pub fn emitSummary(self: *const MempoolSignalSnapshot, w: anytype) void {
        w.print("TRUST_SIGNAL: source=mempool category=validation accepted={d} rejected_total={d} rejected_conflict={d} rejected_missing_input={d} rejected_balance={d} rejected_validity={d} rejected_plutus_unsupported={d}\n", .{
            self.accepted,
            self.rejected_total,
            self.rejected_conflict,
            self.rejected_missing_input,
            self.rejected_balance,
            self.rejected_validity,
            self.rejected_plutus_unsupported,
        }) catch {};
    }
};

/// Build a MempoolSignalSnapshot by reading existing mempool counters.
/// Pure read — no mempool mutation.
pub fn buildMempoolSignal(mp: *const mempool_mod.Mempool) MempoolSignalSnapshot {
    return .{
        .source = .mempool,
        .accepted = mp.accept_count,
        .rejected_total = mp.reject_count,
        .rejected_conflict = mp.conflict_reject_count,
        .rejected_missing_input = mp.missing_input_reject_count,
        .rejected_balance = mp.balance_reject_count,
        .rejected_validity = mp.ttl_reject_count + mp.validity_start_reject_count,
        .rejected_plutus_unsupported = mp.plutus_unsupported_reject_count,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "buildForgeSignal: maps counters deterministically" {
    const sig = buildForgeSignal(10, 1, 0, 2, 7, 0);
    try std.testing.expectEqual(SignalSource.forge_external, sig.source);
    try std.testing.expectEqual(@as(u32, 10), sig.checked);
    try std.testing.expectEqual(@as(u32, 1), sig.supported_pass);
    try std.testing.expectEqual(@as(u32, 0), sig.supported_fail);
    try std.testing.expectEqual(@as(u32, 2), sig.backend_unavailable);
    try std.testing.expectEqual(@as(u32, 7), sig.case_not_supported);
    try std.testing.expectEqual(@as(u32, 0), sig.invalid_response);
}

test "buildForgeSignal: zero counters" {
    const sig = buildForgeSignal(0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(u32, 0), sig.checked);
    try std.testing.expectEqual(@as(u32, 0), sig.supported_pass);
}

test "buildForgeSignal: idempotent — same inputs same output" {
    const a = buildForgeSignal(5, 2, 1, 0, 2, 0);
    const b = buildForgeSignal(5, 2, 1, 0, 2, 0);
    try std.testing.expectEqual(a.checked, b.checked);
    try std.testing.expectEqual(a.supported_pass, b.supported_pass);
    try std.testing.expectEqual(a.supported_fail, b.supported_fail);
    try std.testing.expectEqual(a.backend_unavailable, b.backend_unavailable);
    try std.testing.expectEqual(a.case_not_supported, b.case_not_supported);
    try std.testing.expectEqual(a.invalid_response, b.invalid_response);
}

test "emitSummary: stable format" {
    const sig = buildForgeSignal(3, 1, 0, 1, 1, 0);
    var buf: [256]u8 = undefined;
    var stream = compat.fixedBufferStream(&buf);
    sig.emitSummary(stream.writer());
    const output = buf[0..stream.pos];
    const expected = "TRUST_SIGNAL: source=forge_external category=execution supported_pass=1 supported_fail=0 backend_unavailable=1 case_not_supported=1 invalid_response=0\n";
    try std.testing.expectEqualSlices(u8, expected, output);
}

test "buildMempoolSignal: maps counters from mempool fields" {
    // Create a minimal mempool-like struct via direct field init.
    // We test buildMempoolSignal by constructing a Mempool with known counters.
    var mp = mempool_mod.Mempool.init(std.testing.allocator, 100, 1024 * 1024);
    defer mp.deinit();
    // Simulate counter state by writing directly (fields are pub)
    mp.accept_count = 50;
    mp.reject_count = 12;
    mp.conflict_reject_count = 3;
    mp.missing_input_reject_count = 2;
    mp.balance_reject_count = 1;
    mp.ttl_reject_count = 4;
    mp.validity_start_reject_count = 1;
    mp.plutus_unsupported_reject_count = 1;

    const sig = buildMempoolSignal(&mp);
    try std.testing.expectEqual(SignalSource.mempool, sig.source);
    try std.testing.expectEqual(@as(u64, 50), sig.accepted);
    try std.testing.expectEqual(@as(u64, 12), sig.rejected_total);
    try std.testing.expectEqual(@as(u64, 3), sig.rejected_conflict);
    try std.testing.expectEqual(@as(u64, 2), sig.rejected_missing_input);
    try std.testing.expectEqual(@as(u64, 1), sig.rejected_balance);
    try std.testing.expectEqual(@as(u64, 5), sig.rejected_validity); // 4 + 1
    try std.testing.expectEqual(@as(u64, 1), sig.rejected_plutus_unsupported);
}

test "buildMempoolSignal: zero counters" {
    var mp = mempool_mod.Mempool.init(std.testing.allocator, 10, 4096);
    defer mp.deinit();
    const sig = buildMempoolSignal(&mp);
    try std.testing.expectEqual(@as(u64, 0), sig.accepted);
    try std.testing.expectEqual(@as(u64, 0), sig.rejected_total);
}

test "MempoolSignalSnapshot emitSummary: stable format" {
    const sig = MempoolSignalSnapshot{
        .accepted = 10,
        .rejected_total = 5,
        .rejected_conflict = 1,
        .rejected_missing_input = 1,
        .rejected_balance = 1,
        .rejected_validity = 1,
        .rejected_plutus_unsupported = 1,
    };
    var buf: [512]u8 = undefined;
    var stream = compat.fixedBufferStream(&buf);
    sig.emitSummary(stream.writer());
    const output = buf[0..stream.pos];
    const expected = "TRUST_SIGNAL: source=mempool category=validation accepted=10 rejected_total=5 rejected_conflict=1 rejected_missing_input=1 rejected_balance=1 rejected_validity=1 rejected_plutus_unsupported=1\n";
    try std.testing.expectEqualSlices(u8, expected, output);
}
