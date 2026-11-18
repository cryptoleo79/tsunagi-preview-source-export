const std = @import("std");
const block_stream = @import("block_stream.zig");
const ledger_pipeline = @import("ledger_pipeline.zig");

// ── Pipeline Proof Harness ──────────────────────────────────────────
//
// Integration proof: synthetic CBOR block body bytes flow through
// block_stream.extractDeltas into ledger_pipeline.applyDeltas and
// back via rollback. Proves the full path without touching the live
// follower loop or any protocol code.
//
// CBOR blocks are hand-constructed to match the format validated by
// the proven tx_decode scanner (scanTxBodiesFromBodyBytes fast-path)
// and parser (looksLikeTxBodyMap + parseOutputs).
//
// Block body structure: [[tx_body_map, ...], witnesses_array]
//   tx_body_map = {0: inputs, 1: outputs, 2: fee}
//   input  = [tx_hash_bytes_32, index_u64]
//   output = [address_bytes, lovelace_u64]

// ── CBOR test vectors ───────────────────────────────────────────────

/// Block body with one tx: empty inputs, empty outputs, fee=0.
/// CBOR: 82 81 a3 00 80 01 80 02 00 80
///   82       outer array(2)
///   81       tx_bodies array(1)
///   a3       tx_body map(3)
///     00 80    key 0 → [] (inputs)
///     01 80    key 1 → [] (outputs)
///     02 00    key 2 → 0  (fee)
///   80       witnesses array(0)
const BLOCK_EMPTY_TX = [_]u8{
    0x82, 0x81, 0xa3, 0x00, 0x80, 0x01, 0x80, 0x02, 0x00, 0x80,
};

/// Block body with one tx: empty inputs, two outputs, fee=0.
/// Output 0: [bytes(0xAA), u64(1000)]
/// Output 1: [bytes(0xBB), u64(2000)]
/// CBOR: 82 81 a3 00 80 01 82 82 41 AA 19 03 E8 82 41 BB 19 07 D0 02 00 80
///   82           outer array(2)
///   81           tx_bodies array(1)
///   a3           tx_body map(3)
///     00 80        key 0 → [] (inputs)
///     01 82        key 1 → array(2) (outputs)
///       82 41 AA 19 03 E8   output 0: [bytes(0xAA), u64(1000)]
///       82 41 BB 19 07 D0   output 1: [bytes(0xBB), u64(2000)]
///     02 00        key 2 → 0 (fee)
///   80           witnesses array(0)
const BLOCK_TWO_OUTPUTS = [_]u8{
    0x82, 0x81, 0xa3, 0x00, 0x80, 0x01, 0x82,
    0x82, 0x41, 0xAA, 0x19, 0x03, 0xE8,
    0x82, 0x41, 0xBB, 0x19, 0x07, 0xD0,
    0x02, 0x00, 0x80,
};

/// Block body with one tx: empty inputs, one output, fee=1.
/// Fee differs from BLOCK_TWO_OUTPUTS so tx_hash is distinct.
/// Output 0: [bytes(0xCC), u64(500)]
/// CBOR: 82 81 a3 00 80 01 81 82 41 CC 19 01 F4 02 01 80
///   82           outer array(2)
///   81           tx_bodies array(1)
///   a3           tx_body map(3)
///     00 80        key 0 → [] (inputs)
///     01 81        key 1 → array(1) (outputs)
///       82 41 CC 19 01 F4   output 0: [bytes(0xCC), u64(500)]
///     02 01        key 2 → 1 (fee)
///   80           witnesses array(0)
const BLOCK_ONE_OUTPUT = [_]u8{
    0x82, 0x81, 0xa3, 0x00, 0x80, 0x01, 0x81,
    0x82, 0x41, 0xCC, 0x19, 0x01, 0xF4,
    0x02, 0x01, 0x80,
};

// ── Proof tests ─────────────────────────────────────────────────────

test "proof: extract then apply empty block" {
    const alloc = std.testing.allocator;

    // Extract
    const deltas = block_stream.extractDeltas(alloc, &BLOCK_EMPTY_TX) orelse
        return error.ExtractionFailed;
    defer block_stream.freeTxDeltas(alloc, deltas);

    try std.testing.expectEqual(@as(u64, 1), deltas.tx_count);
    try std.testing.expectEqual(@as(usize, 0), deltas.consumed.len);
    try std.testing.expectEqual(@as(usize, 0), deltas.produced.len);

    // Apply
    var p = ledger_pipeline.Pipeline.init(alloc, .memory_only, null);
    defer p.deinit();

    const result = try p.applyDeltas(deltas.consumed, deltas.produced);
    try std.testing.expectEqual(@as(usize, 0), result.consumed_count);
    try std.testing.expectEqual(@as(usize, 0), result.produced_count);
    try std.testing.expectEqual(@as(usize, 0), p.count());
    try std.testing.expectEqual(@as(usize, 1), p.undoDepth());

    // Rollback restores empty state
    try p.rollback();
    try std.testing.expectEqual(@as(usize, 0), p.count());
    try std.testing.expectEqual(@as(usize, 0), p.undoDepth());
}

test "proof: extract then apply block with outputs" {
    const alloc = std.testing.allocator;

    // Extract
    const deltas = block_stream.extractDeltas(alloc, &BLOCK_TWO_OUTPUTS) orelse
        return error.ExtractionFailed;
    defer block_stream.freeTxDeltas(alloc, deltas);

    try std.testing.expectEqual(@as(u64, 1), deltas.tx_count);
    try std.testing.expectEqual(@as(usize, 0), deltas.consumed.len);
    try std.testing.expectEqual(@as(usize, 2), deltas.produced.len);

    // Verify lovelace values survived the full extraction path
    try std.testing.expectEqual(@as(u64, 1000), deltas.produced[0].output.lovelace);
    try std.testing.expectEqual(@as(u64, 2000), deltas.produced[1].output.lovelace);

    // Verify output indices are sequential
    try std.testing.expectEqual(@as(u32, 0), deltas.produced[0].input.index);
    try std.testing.expectEqual(@as(u32, 1), deltas.produced[1].input.index);

    // Both outputs share the same tx_hash (one tx in the block)
    try std.testing.expectEqualSlices(
        u8,
        &deltas.produced[0].input.tx_hash,
        &deltas.produced[1].input.tx_hash,
    );

    // Apply
    var p = ledger_pipeline.Pipeline.init(alloc, .memory_only, null);
    defer p.deinit();

    const result = try p.applyDeltas(deltas.consumed, deltas.produced);
    try std.testing.expectEqual(@as(usize, 0), result.consumed_count);
    try std.testing.expectEqual(@as(usize, 2), result.produced_count);
    try std.testing.expectEqual(@as(usize, 2), p.count());
    try std.testing.expectEqual(@as(usize, 1), p.undoDepth());

    // Rollback restores empty state
    try p.rollback();
    try std.testing.expectEqual(@as(usize, 0), p.count());
    try std.testing.expectEqual(@as(usize, 0), p.undoDepth());
}

test "proof: multi-block extract-apply then rollback" {
    const alloc = std.testing.allocator;

    var p = ledger_pipeline.Pipeline.init(alloc, .memory_only, null);
    defer p.deinit();

    // Block 1: two outputs (lovelace 1000, 2000)
    {
        const deltas = block_stream.extractDeltas(alloc, &BLOCK_TWO_OUTPUTS) orelse
            return error.ExtractionFailed;
        defer block_stream.freeTxDeltas(alloc, deltas);

        try std.testing.expectEqual(@as(u64, 1), deltas.tx_count);
        try std.testing.expectEqual(@as(usize, 2), deltas.produced.len);

        const result = try p.applyDeltas(deltas.consumed, deltas.produced);
        try std.testing.expectEqual(@as(usize, 2), result.produced_count);
    }
    try std.testing.expectEqual(@as(usize, 2), p.count());
    try std.testing.expectEqual(@as(usize, 1), p.undoDepth());

    // Block 2: one output (lovelace 500, different tx body → different hash)
    {
        const deltas = block_stream.extractDeltas(alloc, &BLOCK_ONE_OUTPUT) orelse
            return error.ExtractionFailed;
        defer block_stream.freeTxDeltas(alloc, deltas);

        try std.testing.expectEqual(@as(u64, 1), deltas.tx_count);
        try std.testing.expectEqual(@as(usize, 1), deltas.produced.len);
        try std.testing.expectEqual(@as(u64, 500), deltas.produced[0].output.lovelace);

        const result = try p.applyDeltas(deltas.consumed, deltas.produced);
        try std.testing.expectEqual(@as(usize, 1), result.produced_count);
    }
    try std.testing.expectEqual(@as(usize, 3), p.count());
    try std.testing.expectEqual(@as(usize, 2), p.undoDepth());

    // Rollback block 2: restores state to after block 1
    try p.rollback();
    try std.testing.expectEqual(@as(usize, 2), p.count());
    try std.testing.expectEqual(@as(usize, 1), p.undoDepth());

    // Rollback block 1: restores to empty
    try p.rollback();
    try std.testing.expectEqual(@as(usize, 0), p.count());
    try std.testing.expectEqual(@as(usize, 0), p.undoDepth());
}
