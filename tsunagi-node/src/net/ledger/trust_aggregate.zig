// ---------------------------------------------------------------------------
// Phase 46: Trust Signal Aggregation (Observe-Only)
// Normalizes per-source trust-signal snapshots into a deterministic
// aggregate evidence view with fixed (source, category, outcome, count)
// entries. No scoring, no weighting, no decision authority.
//
// BAeY, EV, Kelly, LLR are NOT implemented here.
// This module provides normalized aggregate evidence that future
// decision-theoretic work will consume.
// ---------------------------------------------------------------------------

const std = @import("std");
const compat = @import("compat");
const trust_signal = @import("trust_signal.zig");

/// Signal category for normalized aggregate entries.
pub const SignalCategory = enum(u8) {
    execution = 0,
    validation = 1,
};

/// Signal outcome for normalized aggregate entries.
/// Covers all currently real outcomes from forge_external and mempool sources.
pub const SignalOutcome = enum(u8) {
    // forge_external / execution outcomes
    supported_pass = 0,
    supported_fail = 1,
    backend_unavailable = 2,
    case_not_supported = 3,
    invalid_response = 4,
    // mempool / validation outcomes
    accepted = 5,
    rejected_total = 6,
    rejected_conflict = 7,
    rejected_missing_input = 8,
    rejected_balance = 9,
    rejected_validity = 10,
    rejected_plutus_unsupported = 11,
};

/// A single normalized aggregate entry.
pub const SignalCountEntry = struct {
    source: trust_signal.SignalSource,
    category: SignalCategory,
    outcome: SignalOutcome,
    count: u64,
};

/// Maximum entries: 5 forge + 7 mempool = 12.
pub const MAX_ENTRIES: u32 = 12;

/// Deterministic aggregate snapshot across trust-signal sources.
/// Fixed-size, no allocator.
pub const TrustAggregateSnapshot = struct {
    entries: [MAX_ENTRIES]SignalCountEntry = undefined,
    entry_count: u32 = 0,
    total_count: u64 = 0,

    /// Emit stable aggregate output to the provided writer.
    pub fn emitEntries(self: *const TrustAggregateSnapshot, w: anytype) void {
        for (self.entries[0..self.entry_count]) |e| {
            w.print("TRUST_AGGREGATE: source={s} category={s} outcome={s} count={d}\n", .{
                sourceName(e.source),
                categoryName(e.category),
                outcomeName(e.outcome),
                e.count,
            }) catch {};
        }
        w.print("TRUST_AGGREGATE_SUMMARY: entries={d} total={d}\n", .{
            self.entry_count, self.total_count,
        }) catch {};
    }
};

/// Build an aggregate snapshot from forge and mempool signal snapshots.
/// Fixed ordering: forge entries first, then mempool entries.
/// Includes zero-count entries for stable ordering.
pub fn buildAggregate(
    forge: *const trust_signal.ForgeSignalSnapshot,
    mempool: *const trust_signal.MempoolSignalSnapshot,
) TrustAggregateSnapshot {
    var snap = TrustAggregateSnapshot{};
    var i: u32 = 0;

    // Forge external / execution entries (fixed order)
    snap.entries[i] = .{ .source = .forge_external, .category = .execution, .outcome = .supported_pass, .count = forge.supported_pass };
    i += 1;
    snap.entries[i] = .{ .source = .forge_external, .category = .execution, .outcome = .supported_fail, .count = forge.supported_fail };
    i += 1;
    snap.entries[i] = .{ .source = .forge_external, .category = .execution, .outcome = .backend_unavailable, .count = forge.backend_unavailable };
    i += 1;
    snap.entries[i] = .{ .source = .forge_external, .category = .execution, .outcome = .case_not_supported, .count = forge.case_not_supported };
    i += 1;
    snap.entries[i] = .{ .source = .forge_external, .category = .execution, .outcome = .invalid_response, .count = forge.invalid_response };
    i += 1;

    // Mempool / validation entries (fixed order)
    snap.entries[i] = .{ .source = .mempool, .category = .validation, .outcome = .accepted, .count = mempool.accepted };
    i += 1;
    snap.entries[i] = .{ .source = .mempool, .category = .validation, .outcome = .rejected_total, .count = mempool.rejected_total };
    i += 1;
    snap.entries[i] = .{ .source = .mempool, .category = .validation, .outcome = .rejected_conflict, .count = mempool.rejected_conflict };
    i += 1;
    snap.entries[i] = .{ .source = .mempool, .category = .validation, .outcome = .rejected_missing_input, .count = mempool.rejected_missing_input };
    i += 1;
    snap.entries[i] = .{ .source = .mempool, .category = .validation, .outcome = .rejected_balance, .count = mempool.rejected_balance };
    i += 1;
    snap.entries[i] = .{ .source = .mempool, .category = .validation, .outcome = .rejected_validity, .count = mempool.rejected_validity };
    i += 1;
    snap.entries[i] = .{ .source = .mempool, .category = .validation, .outcome = .rejected_plutus_unsupported, .count = mempool.rejected_plutus_unsupported };
    i += 1;

    snap.entry_count = i;

    // Total count
    var total: u64 = 0;
    for (snap.entries[0..i]) |e| total += e.count;
    snap.total_count = total;

    return snap;
}

fn sourceName(s: trust_signal.SignalSource) []const u8 {
    return switch (s) {
        .forge_external => "forge_external",
        .mempool => "mempool",
    };
}

fn categoryName(c: SignalCategory) []const u8 {
    return switch (c) {
        .execution => "execution",
        .validation => "validation",
    };
}

fn outcomeName(o: SignalOutcome) []const u8 {
    return switch (o) {
        .supported_pass => "supported_pass",
        .supported_fail => "supported_fail",
        .backend_unavailable => "backend_unavailable",
        .case_not_supported => "case_not_supported",
        .invalid_response => "invalid_response",
        .accepted => "accepted",
        .rejected_total => "rejected_total",
        .rejected_conflict => "rejected_conflict",
        .rejected_missing_input => "rejected_missing_input",
        .rejected_balance => "rejected_balance",
        .rejected_validity => "rejected_validity",
        .rejected_plutus_unsupported => "rejected_plutus_unsupported",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "buildAggregate: deterministic from forge + mempool" {
    const forge = trust_signal.ForgeSignalSnapshot{
        .checked = 5,
        .supported_pass = 1,
        .supported_fail = 0,
        .backend_unavailable = 1,
        .case_not_supported = 3,
        .invalid_response = 0,
    };
    const mempool = trust_signal.MempoolSignalSnapshot{
        .accepted = 20,
        .rejected_total = 4,
        .rejected_conflict = 1,
        .rejected_missing_input = 1,
        .rejected_balance = 1,
        .rejected_validity = 1,
        .rejected_plutus_unsupported = 0,
    };
    const agg = buildAggregate(&forge, &mempool);
    try std.testing.expectEqual(@as(u32, 12), agg.entry_count);
    // Forge entries first
    try std.testing.expectEqual(SignalOutcome.supported_pass, agg.entries[0].outcome);
    try std.testing.expectEqual(@as(u64, 1), agg.entries[0].count);
    try std.testing.expectEqual(SignalOutcome.case_not_supported, agg.entries[3].outcome);
    try std.testing.expectEqual(@as(u64, 3), agg.entries[3].count);
    // Mempool entries after
    try std.testing.expectEqual(SignalOutcome.accepted, agg.entries[5].outcome);
    try std.testing.expectEqual(@as(u64, 20), agg.entries[5].count);
    try std.testing.expectEqual(SignalOutcome.rejected_conflict, agg.entries[7].outcome);
    try std.testing.expectEqual(@as(u64, 1), agg.entries[7].count);
    // Total: forge(1+0+1+3+0=5) + mempool(20+4+1+1+1+1+0=28) = 33
    try std.testing.expectEqual(@as(u64, 33), agg.total_count);
}

test "buildAggregate: zero counters produce 12 zero entries" {
    const forge = trust_signal.ForgeSignalSnapshot{};
    const mempool = trust_signal.MempoolSignalSnapshot{};
    const agg = buildAggregate(&forge, &mempool);
    try std.testing.expectEqual(@as(u32, 12), agg.entry_count);
    try std.testing.expectEqual(@as(u64, 0), agg.total_count);
    for (agg.entries[0..12]) |e| {
        try std.testing.expectEqual(@as(u64, 0), e.count);
    }
}

test "buildAggregate: idempotent" {
    const forge = trust_signal.ForgeSignalSnapshot{ .checked = 3, .supported_pass = 2, .case_not_supported = 1 };
    const mempool = trust_signal.MempoolSignalSnapshot{ .accepted = 10 };
    const a = buildAggregate(&forge, &mempool);
    const b = buildAggregate(&forge, &mempool);
    try std.testing.expectEqual(a.entry_count, b.entry_count);
    try std.testing.expectEqual(a.total_count, b.total_count);
    for (0..12) |idx| {
        try std.testing.expectEqual(a.entries[idx].count, b.entries[idx].count);
    }
}

test "buildAggregate: fixed entry ordering" {
    const forge = trust_signal.ForgeSignalSnapshot{};
    const mempool = trust_signal.MempoolSignalSnapshot{};
    const agg = buildAggregate(&forge, &mempool);
    // Verify source ordering: 0-4 forge, 5-11 mempool
    for (0..5) |idx| {
        try std.testing.expectEqual(trust_signal.SignalSource.forge_external, agg.entries[idx].source);
        try std.testing.expectEqual(SignalCategory.execution, agg.entries[idx].category);
    }
    for (5..12) |idx| {
        try std.testing.expectEqual(trust_signal.SignalSource.mempool, agg.entries[idx].source);
        try std.testing.expectEqual(SignalCategory.validation, agg.entries[idx].category);
    }
}

test "emitEntries: stable format" {
    const forge = trust_signal.ForgeSignalSnapshot{ .checked = 2, .supported_pass = 1, .case_not_supported = 1 };
    const mempool = trust_signal.MempoolSignalSnapshot{ .accepted = 5, .rejected_total = 1, .rejected_balance = 1 };
    const agg = buildAggregate(&forge, &mempool);
    var buf: [2048]u8 = undefined;
    var stream = compat.fixedBufferStream(&buf);
    agg.emitEntries(stream.writer());
    const output = buf[0..stream.pos];
    // Check first and last entry lines + summary
    try std.testing.expect(std.mem.startsWith(u8, output, "TRUST_AGGREGATE: source=forge_external category=execution outcome=supported_pass count=1\n"));
    // forge(1+0+0+1+0=2) + mempool(5+1+0+0+1+0+0=7) = 9
    try std.testing.expect(std.mem.endsWith(u8, output, "TRUST_AGGREGATE_SUMMARY: entries=12 total=9\n"));
}
