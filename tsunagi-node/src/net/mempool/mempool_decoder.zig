const std = @import("std");
const cbor = @import("../cbor/term.zig");
const block_hash = @import("../ledger/block_hash.zig");
const tx_decode = @import("../ledger/tx_decode.zig");

/// Decoded summary of a single mempool transaction.
/// Fixed-size, no heap allocations. Produced immediately at submission time.
pub const MempoolTxSummary = struct {
    txid_hex: [64]u8,
    inputs: u32,
    outputs: u32,
    fee: ?u64,
    has_metadata: bool,
    size_bytes: u32,
    received_unix: i64,
};

/// Count elements in an array-like term (array or tag-wrapped array).
fn countArrayLike(term: cbor.Term) ?u32 {
    if (term == .array) return @intCast(term.array.len);
    if (term == .tag and term.tag.value.* == .array) return @intCast(term.tag.value.*.array.len);
    return null;
}

/// Extract summary fields from a decoded tx body Term.
fn summarizeTxBody(tx_term: cbor.Term) ?struct { inputs: u32, outputs: u32, fee: ?u64, has_metadata: bool } {
    if (tx_term == .map_u64) {
        const m = tx_term.map_u64;
        const inputs = blk: {
            const key0 = tx_decode.findMapKeyPublic(m, 0) orelse break :blk @as(u32, 0);
            break :blk countArrayLike(key0) orelse 0;
        };
        const outputs = blk: {
            const key1 = tx_decode.findMapKeyPublic(m, 1) orelse break :blk @as(u32, 0);
            break :blk countArrayLike(key1) orelse 0;
        };
        const fee: ?u64 = blk: {
            const key2 = tx_decode.findMapKeyPublic(m, 2) orelse break :blk null;
            if (key2 == .u64) break :blk key2.u64;
            break :blk null;
        };
        const has_metadata = tx_decode.findMapKeyPublic(m, 7) != null;

        return .{
            .inputs = inputs,
            .outputs = outputs,
            .fee = fee,
            .has_metadata = has_metadata,
        };
    }

    if (tx_term == .array) {
        const arr = tx_term.array;
        if (arr.len < 3) return null;
        const inputs = countArrayLike(arr[0]) orelse 0;
        const outputs = countArrayLike(arr[1]) orelse 0;
        const fee: ?u64 = if (arr[2] == .u64) arr[2].u64 else null;
        const has_metadata = arr.len > 7 and arr[7] != .null;

        return .{
            .inputs = inputs,
            .outputs = outputs,
            .fee = fee,
            .has_metadata = has_metadata,
        };
    }

    return null;
}

/// Decode a single raw Cardano tx into a MempoolTxSummary.
/// Uses block_hash.decomposeTx to extract tx_body CBOR,
/// then cbor.decodeOrRaw to parse, then reads keys 0,1,2,7.
/// Returns null if the tx cannot be decomposed or decoded.
pub fn decodeMempoolTx(
    alloc: std.mem.Allocator,
    tx_bytes: []const u8,
    txid_hex: [64]u8,
    received_unix: i64,
) ?MempoolTxSummary {
    const parts = block_hash.decomposeTx(tx_bytes) orelse return null;

    const term = cbor.decodeOrRaw(alloc, parts.tx_body) catch return null;
    defer cbor.free(term, alloc);

    const summary = summarizeTxBody(term) orelse return null;

    return .{
        .txid_hex = txid_hex,
        .inputs = summary.inputs,
        .outputs = summary.outputs,
        .fee = summary.fee,
        .has_metadata = summary.has_metadata,
        .size_bytes = @intCast(tx_bytes.len),
        .received_unix = received_unix,
    };
}

// ── Inline Tests ──────────────────────────────────────────

test "decodeMempoolTx returns null for invalid bytes" {
    const result = decodeMempoolTx(
        std.testing.allocator,
        &[_]u8{ 0x00, 0x01, 0x02 },
        [_]u8{'0'} ** 64,
        1000,
    );
    try std.testing.expect(result == null);
}

test "decodeMempoolTx returns null for empty bytes" {
    const result = decodeMempoolTx(
        std.testing.allocator,
        &[_]u8{},
        [_]u8{'0'} ** 64,
        1000,
    );
    try std.testing.expect(result == null);
}

test "MempoolTxSummary fields have expected sizes" {
    const s = MempoolTxSummary{
        .txid_hex = [_]u8{'a'} ** 64,
        .inputs = 2,
        .outputs = 3,
        .fee = 170000,
        .has_metadata = false,
        .size_bytes = 432,
        .received_unix = 1710000000,
    };
    try std.testing.expectEqual(@as(u32, 2), s.inputs);
    try std.testing.expectEqual(@as(u32, 3), s.outputs);
    try std.testing.expectEqual(@as(?u64, 170000), s.fee);
    try std.testing.expectEqual(@as(u32, 432), s.size_bytes);
    try std.testing.expectEqual(@as(i64, 1710000000), s.received_unix);
    try std.testing.expect(!s.has_metadata);
}

test "summarizeTxBody with map_u64 tx body" {
    // inputs: 2-element array
    var inp0_items = [_]cbor.Term{ .{ .bytes = &([_]u8{0} ** 32) }, .{ .u64 = 0 } };
    var inp1_items = [_]cbor.Term{ .{ .bytes = &([_]u8{0} ** 32) }, .{ .u64 = 1 } };
    const inp0 = cbor.Term{ .array = &inp0_items };
    const inp1 = cbor.Term{ .array = &inp1_items };
    var input_items = [_]cbor.Term{ inp0, inp1 };
    const inputs = cbor.Term{ .array = &input_items };

    // outputs: 3-element array
    var out0_items = [_]cbor.Term{ .{ .bytes = "addr" }, .{ .u64 = 1000000 } };
    var out1_items = [_]cbor.Term{ .{ .bytes = "addr" }, .{ .u64 = 2000000 } };
    var out2_items = [_]cbor.Term{ .{ .bytes = "addr" }, .{ .u64 = 3000000 } };
    const out0 = cbor.Term{ .array = &out0_items };
    const out1 = cbor.Term{ .array = &out1_items };
    const out2 = cbor.Term{ .array = &out2_items };
    var output_items = [_]cbor.Term{ out0, out1, out2 };
    const outputs = cbor.Term{ .array = &output_items };

    // tx body map {0: inputs, 1: outputs, 2: fee, 7: metadata}
    var entries = [_]cbor.MapEntry{
        .{ .key = 0, .value = inputs },
        .{ .key = 1, .value = outputs },
        .{ .key = 2, .value = .{ .u64 = 170000 } },
        .{ .key = 7, .value = .{ .u64 = 42 } },
    };
    const tx_body = cbor.Term{ .map_u64 = &entries };

    const result = summarizeTxBody(tx_body).?;
    try std.testing.expectEqual(@as(u32, 2), result.inputs);
    try std.testing.expectEqual(@as(u32, 3), result.outputs);
    try std.testing.expectEqual(@as(?u64, 170000), result.fee);
    try std.testing.expect(result.has_metadata);
}
