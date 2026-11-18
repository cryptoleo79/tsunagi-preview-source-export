const std = @import("std");
const block_stream = @import("block_stream.zig");
const ledger_pipeline = @import("ledger_pipeline.zig");

// ── Replay Harness — Deterministic Multi-Block Replay ───────────────
//
// Reusable harness that applies block body bytes in sequence through
// block_stream.extractDeltas → ledger_pipeline.applyDeltas, tracking
// cumulative replay statistics.
//
// Designed for:
//   - deterministic ledger tests with synthetic CBOR
//   - file-based block replay (accepts any []const u8 block body)
//   - future follower integration dry-runs
//   - benchmark harnesses
//
// Counter semantics:
//   blocks_applied   — current applied depth; increments on apply,
//                      decrements on rollback
//   total_tx_count   — cumulative forward-work counter; increments
//                      on apply, does NOT decrement on rollback
//   total_consumed   — cumulative forward-work counter; same
//   total_produced   — cumulative forward-work counter; same
//
// No protocol imports. No globals. No env-var coupling.

pub const ReplayResult = struct {
    /// Current applied block depth (decrements on rollback).
    blocks_applied: usize,
    /// Cumulative transaction count across all applied blocks (forward-only).
    total_tx_count: u64,
    /// Cumulative consumed inputs across all applied blocks (forward-only).
    total_consumed: usize,
    /// Cumulative produced outputs across all applied blocks (forward-only).
    total_produced: usize,
    /// Current undo stack depth (mirrors blocks_applied).
    undo_depth: usize,
};

pub const ReplayError = error{
    ExtractionFailed,
} || ledger_pipeline.ApplyError;

pub const ReplayHarness = struct {
    alloc: std.mem.Allocator,
    pipeline: ledger_pipeline.Pipeline,
    blocks_applied: usize,
    total_tx_count: u64,
    total_consumed: usize,
    total_produced: usize,

    pub fn init(
        alloc: std.mem.Allocator,
        mode: ledger_pipeline.ApplyMode,
        store: ?*ledger_pipeline.LmdbUtxo,
    ) ReplayHarness {
        return .{
            .alloc = alloc,
            .pipeline = ledger_pipeline.Pipeline.init(alloc, mode, store),
            .blocks_applied = 0,
            .total_tx_count = 0,
            .total_consumed = 0,
            .total_produced = 0,
        };
    }

    pub fn deinit(self: *ReplayHarness) void {
        self.pipeline.deinit();
    }

    /// Apply a single block's body bytes through the full extraction
    /// and application path. Extracts deltas via block_stream, applies
    /// via ledger_pipeline, accumulates forward-work counters.
    pub fn applyBlockBytes(self: *ReplayHarness, block_body_bytes: []const u8) ReplayError!void {
        const deltas = block_stream.extractDeltas(self.alloc, block_body_bytes) orelse
            return error.ExtractionFailed;
        defer block_stream.freeTxDeltas(self.alloc, deltas);

        _ = try self.pipeline.applyDeltas(deltas.consumed, deltas.produced);

        self.blocks_applied += 1;
        self.total_tx_count += deltas.tx_count;
        self.total_consumed += deltas.consumed.len;
        self.total_produced += deltas.produced.len;
    }

    /// Roll back the most recent block application.
    /// Decrements blocks_applied. Forward-work counters are NOT reversed.
    pub fn rollbackOne(self: *ReplayHarness) error{EmptyUndoStack}!void {
        try self.pipeline.rollback();
        self.blocks_applied -= 1;
    }

    /// Current UTxO entry count in pipeline state.
    pub fn utxoCount(self: *ReplayHarness) usize {
        return self.pipeline.count();
    }

    /// Current undo stack depth.
    pub fn undoDepth(self: *ReplayHarness) usize {
        return self.pipeline.undoDepth();
    }

    /// Snapshot of current replay state and cumulative counters.
    pub fn summary(self: *ReplayHarness) ReplayResult {
        return .{
            .blocks_applied = self.blocks_applied,
            .total_tx_count = self.total_tx_count,
            .total_consumed = self.total_consumed,
            .total_produced = self.total_produced,
            .undo_depth = self.pipeline.undoDepth(),
        };
    }
};

// ── CBOR test vectors ───────────────────────────────────────────────
// Same synthetic block bodies used in pipeline_proof_test.zig.
// Block body structure: [[tx_body_map, ...], witnesses_array]
//   tx_body_map = {0: inputs, 1: outputs, 2: fee}

/// One tx: no inputs, no outputs, fee=0.
const BLOCK_EMPTY_TX = [_]u8{
    0x82, 0x81, 0xa3, 0x00, 0x80, 0x01, 0x80, 0x02, 0x00, 0x80,
};

/// One tx: no inputs, two outputs [bytes(0xAA),1000] [bytes(0xBB),2000], fee=0.
const BLOCK_TWO_OUTPUTS = [_]u8{
    0x82, 0x81, 0xa3, 0x00, 0x80, 0x01, 0x82,
    0x82, 0x41, 0xAA, 0x19, 0x03, 0xE8,
    0x82, 0x41, 0xBB, 0x19, 0x07, 0xD0,
    0x02, 0x00, 0x80,
};

/// One tx: no inputs, one output [bytes(0xCC),500], fee=1 (distinct hash).
const BLOCK_ONE_OUTPUT = [_]u8{
    0x82, 0x81, 0xa3, 0x00, 0x80, 0x01, 0x81,
    0x82, 0x41, 0xCC, 0x19, 0x01, 0xF4,
    0x02, 0x01, 0x80,
};

// ── Tests ───────────────────────────────────────────────────────────

test "apply one block" {
    var h = ReplayHarness.init(std.testing.allocator, .memory_only, null);
    defer h.deinit();

    try h.applyBlockBytes(&BLOCK_TWO_OUTPUTS);

    const s = h.summary();
    try std.testing.expectEqual(@as(usize, 1), s.blocks_applied);
    try std.testing.expectEqual(@as(u64, 1), s.total_tx_count);
    try std.testing.expectEqual(@as(usize, 0), s.total_consumed);
    try std.testing.expectEqual(@as(usize, 2), s.total_produced);
    try std.testing.expectEqual(@as(usize, 1), s.undo_depth);
    try std.testing.expectEqual(@as(usize, 2), h.utxoCount());
}

test "apply two blocks then rollback sequence" {
    var h = ReplayHarness.init(std.testing.allocator, .memory_only, null);
    defer h.deinit();

    // Block 1: two outputs
    try h.applyBlockBytes(&BLOCK_TWO_OUTPUTS);

    var s = h.summary();
    try std.testing.expectEqual(@as(usize, 1), s.blocks_applied);
    try std.testing.expectEqual(@as(u64, 1), s.total_tx_count);
    try std.testing.expectEqual(@as(usize, 2), s.total_produced);
    try std.testing.expectEqual(@as(usize, 2), h.utxoCount());
    try std.testing.expectEqual(@as(usize, 1), s.undo_depth);

    // Block 2: one output
    try h.applyBlockBytes(&BLOCK_ONE_OUTPUT);

    s = h.summary();
    try std.testing.expectEqual(@as(usize, 2), s.blocks_applied);
    try std.testing.expectEqual(@as(u64, 2), s.total_tx_count);
    try std.testing.expectEqual(@as(usize, 0), s.total_consumed);
    try std.testing.expectEqual(@as(usize, 3), s.total_produced);
    try std.testing.expectEqual(@as(usize, 3), h.utxoCount());
    try std.testing.expectEqual(@as(usize, 2), s.undo_depth);

    // Rollback block 2 → intermediate state after block 1
    try h.rollbackOne();

    s = h.summary();
    try std.testing.expectEqual(@as(usize, 1), s.blocks_applied);
    try std.testing.expectEqual(@as(usize, 2), h.utxoCount());
    try std.testing.expectEqual(@as(usize, 1), s.undo_depth);
    // Forward-work counters unchanged by rollback
    try std.testing.expectEqual(@as(u64, 2), s.total_tx_count);
    try std.testing.expectEqual(@as(usize, 3), s.total_produced);

    // Rollback block 1 → empty baseline
    try h.rollbackOne();

    s = h.summary();
    try std.testing.expectEqual(@as(usize, 0), s.blocks_applied);
    try std.testing.expectEqual(@as(usize, 0), h.utxoCount());
    try std.testing.expectEqual(@as(usize, 0), s.undo_depth);
    // Forward-work counters still unchanged
    try std.testing.expectEqual(@as(u64, 2), s.total_tx_count);
    try std.testing.expectEqual(@as(usize, 3), s.total_produced);
}

test "zero-delta block in sequence" {
    var h = ReplayHarness.init(std.testing.allocator, .memory_only, null);
    defer h.deinit();

    // Block 1: two outputs
    try h.applyBlockBytes(&BLOCK_TWO_OUTPUTS);
    try std.testing.expectEqual(@as(usize, 2), h.utxoCount());

    // Block 2: zero-delta (empty inputs/outputs, tx_count=1)
    try h.applyBlockBytes(&BLOCK_EMPTY_TX);

    const s = h.summary();
    try std.testing.expectEqual(@as(usize, 2), s.blocks_applied);
    try std.testing.expectEqual(@as(u64, 2), s.total_tx_count);
    try std.testing.expectEqual(@as(usize, 0), s.total_consumed);
    try std.testing.expectEqual(@as(usize, 2), s.total_produced);
    try std.testing.expectEqual(@as(usize, 2), h.utxoCount());
    try std.testing.expectEqual(@as(usize, 2), s.undo_depth);

    // Rollback zero-delta block — state unchanged
    try h.rollbackOne();
    try std.testing.expectEqual(@as(usize, 2), h.utxoCount());
    try std.testing.expectEqual(@as(usize, 1), h.undoDepth());
}

test "rollback on empty harness returns error" {
    var h = ReplayHarness.init(std.testing.allocator, .memory_only, null);
    defer h.deinit();

    try std.testing.expectError(error.EmptyUndoStack, h.rollbackOne());
}

test "apply invalid block bytes returns ExtractionFailed" {
    var h = ReplayHarness.init(std.testing.allocator, .memory_only, null);
    defer h.deinit();

    try std.testing.expectError(error.ExtractionFailed, h.applyBlockBytes(&[_]u8{0x00}));
    try std.testing.expectError(error.ExtractionFailed, h.applyBlockBytes(&[_]u8{}));

    // Harness state untouched after failed apply
    const s = h.summary();
    try std.testing.expectEqual(@as(usize, 0), s.blocks_applied);
    try std.testing.expectEqual(@as(u64, 0), s.total_tx_count);
    try std.testing.expectEqual(@as(usize, 0), h.utxoCount());
}
