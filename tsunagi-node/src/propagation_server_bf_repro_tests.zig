// Focused reproduction test: BlockFetch handleMessage codec path.
//
// Goal: prove or disprove the live-network bug where a relay's
// MsgRequestRange does not yield StartBatch+Block+BatchDone. If this test
// passes, the codec/serve path is healthy and the bug must be upstream of
// `handleMessage` — i.e. inside propagation_server.zig's gating
// (allowlist, arm token, no-inject, sealed.block_cbor presence, etc).
//
// Read-only scope: we ONLY exercise BlockFetchServer.handleMessage with
// known SealedBlock fixtures. No production behavior is touched.

const std = @import("std");
const compat = @import("compat");

const cbor = @import("net/cbor/term.zig");
const blockfetch_server = @import("protocols/blockfetch_server.zig");

fn encodeToBytes(alloc: std.mem.Allocator, term: cbor.Term) ![]u8 {
    var list = std.array_list.Managed(u8).init(alloc);
    errdefer list.deinit();
    try cbor.encode(term, compat.listWriter(&list));
    return list.toOwnedSlice();
}

fn dumpBytes(label: []const u8, bytes: []const u8) void {
    std.debug.print("{s} len={d} bytes=", .{ label, bytes.len });
    for (bytes) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});
}

test "BF_REPRO: handleMessage with matching point returns 3-message batch" {
    const alloc = std.testing.allocator;

    // Fixture: a single sealed block at slot=12345, hash=all-0xAB.
    var block_hash: [32]u8 = undefined;
    @memset(&block_hash, 0xAB);
    const block_cbor = "tsunagi-test-block-cbor-payload";

    var blocks = [_]blockfetch_server.SealedBlock{
        .{ .slot = 12345, .hash = block_hash, .block_cbor = block_cbor },
    };
    var server = blockfetch_server.BlockFetchServer.init(&blocks);

    // Craft MsgRequestRange = [0, [slot, hash], [slot, hash]] with matching hash.
    var pt_from: [2]cbor.Term = .{ .{ .u64 = 12345 }, .{ .bytes = &block_hash } };
    var pt_to: [2]cbor.Term = .{ .{ .u64 = 12345 }, .{ .bytes = &block_hash } };
    var msg: [3]cbor.Term = .{
        .{ .u64 = 0 },
        .{ .array = &pt_from },
        .{ .array = &pt_to },
    };
    const msg_bytes = try encodeToBytes(alloc, cbor.Term{ .array = &msg });
    defer alloc.free(msg_bytes);

    dumpBytes("BF_REPRO_REQUEST", msg_bytes);

    const responses_opt = server.handleMessage(alloc, msg_bytes);
    if (responses_opt == null) {
        std.debug.print("BF_REPRO_FAIL: handleMessage returned null on matching hash\n", .{});
        return error.HandleMessageReturnedNull;
    }
    const responses = responses_opt.?;
    defer alloc.free(responses);
    defer for (responses) |r| alloc.free(r);

    std.debug.print("BF_REPRO_RESPONSES_LEN={d}\n", .{responses.len});
    for (responses, 0..) |r, i| {
        std.debug.print("BF_REPRO_RESPONSE[{d}] ", .{i});
        dumpBytes("payload", r);
    }

    if (responses.len != 3) {
        std.debug.print("BF_REPRO_FAIL: expected 3 responses (StartBatch+Block+BatchDone), got {d}\n", .{responses.len});
    }
    try std.testing.expectEqual(@as(usize, 3), responses.len);

    // [0] = MsgStartBatch [2]
    var fbs0 = compat.fixedBufferStream(responses[0]);
    const t0 = cbor.decode(alloc, fbs0.reader()) catch |e| {
        std.debug.print("BF_REPRO_FAIL: response[0] cbor decode failed: {s}\n", .{@errorName(e)});
        return e;
    };
    defer cbor.free(t0, alloc);
    try std.testing.expect(t0 == .array);
    try std.testing.expect(t0.array.len >= 1);
    try std.testing.expect(t0.array[0] == .u64);
    if (t0.array[0].u64 != 2) {
        std.debug.print("BF_REPRO_FAIL: response[0] tag expected=2 (MsgStartBatch) actual={d}\n", .{t0.array[0].u64});
    }
    try std.testing.expectEqual(@as(u64, 2), t0.array[0].u64);

    // [1] = MsgBlock [4, tag(24, bytes(block_cbor))]
    var fbs1 = compat.fixedBufferStream(responses[1]);
    const t1 = cbor.decode(alloc, fbs1.reader()) catch |e| {
        std.debug.print("BF_REPRO_FAIL: response[1] cbor decode failed: {s}\n", .{@errorName(e)});
        return e;
    };
    defer cbor.free(t1, alloc);
    try std.testing.expect(t1 == .array);
    try std.testing.expect(t1.array.len >= 2);
    try std.testing.expectEqual(@as(u64, 4), t1.array[0].u64);
    try std.testing.expect(t1.array[1] == .tag);
    try std.testing.expectEqual(@as(u64, 24), t1.array[1].tag.tag);
    try std.testing.expect(t1.array[1].tag.value.* == .bytes);
    if (!std.mem.eql(u8, block_cbor, t1.array[1].tag.value.*.bytes)) {
        std.debug.print("BF_REPRO_FAIL: block_cbor body mismatch\n", .{});
        dumpBytes("expected", block_cbor);
        dumpBytes("actual  ", t1.array[1].tag.value.*.bytes);
    }
    try std.testing.expectEqualSlices(u8, block_cbor, t1.array[1].tag.value.*.bytes);

    // [2] = MsgBatchDone [5]
    var fbs2 = compat.fixedBufferStream(responses[2]);
    const t2 = cbor.decode(alloc, fbs2.reader()) catch |e| {
        std.debug.print("BF_REPRO_FAIL: response[2] cbor decode failed: {s}\n", .{@errorName(e)});
        return e;
    };
    defer cbor.free(t2, alloc);
    try std.testing.expect(t2 == .array);
    try std.testing.expect(t2.array.len >= 1);
    try std.testing.expectEqual(@as(u64, 5), t2.array[0].u64);

    try std.testing.expect(server.served_block);

    std.debug.print("BF_REPRO_PASS_MATCH: codec serves StartBatch+Block+BatchDone correctly\n", .{});
}

test "BF_REPRO: handleMessage with mismatched hash returns single MsgNoBlocks" {
    const alloc = std.testing.allocator;

    var block_hash: [32]u8 = undefined;
    @memset(&block_hash, 0xAB);
    const block_cbor = "tsunagi-test-block-cbor-payload";

    var blocks = [_]blockfetch_server.SealedBlock{
        .{ .slot = 12345, .hash = block_hash, .block_cbor = block_cbor },
    };
    var server = blockfetch_server.BlockFetchServer.init(&blocks);

    // Same slot, divergent hash — post-#140 + #147 contract: NoBlocks (1 reply)
    var bad_hash: [32]u8 = undefined;
    @memset(&bad_hash, 0xCD);
    var pt_from: [2]cbor.Term = .{ .{ .u64 = 12345 }, .{ .bytes = &bad_hash } };
    var pt_to: [2]cbor.Term = .{ .{ .u64 = 12345 }, .{ .bytes = &bad_hash } };
    var msg: [3]cbor.Term = .{
        .{ .u64 = 0 },
        .{ .array = &pt_from },
        .{ .array = &pt_to },
    };
    const msg_bytes = try encodeToBytes(alloc, cbor.Term{ .array = &msg });
    defer alloc.free(msg_bytes);

    dumpBytes("BF_REPRO_BAD_REQUEST", msg_bytes);

    const responses_opt = server.handleMessage(alloc, msg_bytes);
    if (responses_opt == null) {
        std.debug.print("BF_REPRO_FAIL: handleMessage returned null on mismatched hash (expected NoBlocks)\n", .{});
        return error.HandleMessageReturnedNullForMismatch;
    }
    const responses = responses_opt.?;
    defer alloc.free(responses);
    defer for (responses) |r| alloc.free(r);

    std.debug.print("BF_REPRO_MISMATCH_RESPONSES_LEN={d}\n", .{responses.len});
    for (responses, 0..) |r, i| {
        std.debug.print("BF_REPRO_MISMATCH_RESPONSE[{d}] ", .{i});
        dumpBytes("payload", r);
    }

    if (responses.len != 1) {
        std.debug.print("BF_REPRO_FAIL: expected 1 response (NoBlocks), got {d}\n", .{responses.len});
    }
    try std.testing.expectEqual(@as(usize, 1), responses.len);

    var fbs = compat.fixedBufferStream(responses[0]);
    const t = cbor.decode(alloc, fbs.reader()) catch |e| {
        std.debug.print("BF_REPRO_FAIL: NoBlocks response cbor decode failed: {s}\n", .{@errorName(e)});
        return e;
    };
    defer cbor.free(t, alloc);
    try std.testing.expect(t == .array);
    try std.testing.expect(t.array.len >= 1);
    try std.testing.expect(t.array[0] == .u64);
    if (t.array[0].u64 != 3) {
        std.debug.print("BF_REPRO_FAIL: response tag expected=3 (MsgNoBlocks) actual={d}\n", .{t.array[0].u64});
    }
    try std.testing.expectEqual(@as(u64, 3), t.array[0].u64);
    try std.testing.expect(!server.served_block);

    std.debug.print("BF_REPRO_PASS_MISMATCH: codec returns MsgNoBlocks on hash divergence\n", .{});
}

// Regression: MsgRequestRange with Origin (empty-array) points must produce a
// non-null response (MsgNoBlocks), NOT silently exit. Live failure mode was a
// relay sending [0, [], []] (tag 0 + Origin/Origin) being misclassified as
// MsgClientDone because bf_request_seen was inferred from extracted slot
// values rather than the wire tag. The codec layer is the second line of
// defence: even with no decoded points it must reply NoBlocks.
test "BF_REPRO: handleMessage tag-0 with Origin points returns NoBlocks (not null)" {
    const alloc = std.testing.allocator;

    // Single sealed block fixture — irrelevant content, only its presence matters.
    var block_hash: [32]u8 = undefined;
    @memset(&block_hash, 0xAB);
    const block_cbor = "tsunagi-test-block-cbor-payload";
    var blocks = [_]blockfetch_server.SealedBlock{
        .{ .slot = 12345, .hash = block_hash, .block_cbor = block_cbor },
    };
    var server = blockfetch_server.BlockFetchServer.init(&blocks);

    // Wire payload: 0x83 0x00 0x80 0x80 = [0, [], []] = MsgRequestRange with
    // two Origin points. cbor.encode of two empty arrays produces 0x80 each.
    const msg_bytes = [_]u8{ 0x83, 0x00, 0x80, 0x80 };
    dumpBytes("BF_REPRO_TAG0_ORIGIN_REQUEST", &msg_bytes);

    const responses_opt = server.handleMessage(alloc, &msg_bytes);
    if (responses_opt == null) {
        std.debug.print("BF_REPRO_FAIL: handleMessage returned null on tag-0 with Origin points\n", .{});
        return error.HandleMessageReturnedNullForTag0Origin;
    }
    const responses = responses_opt.?;
    defer alloc.free(responses);
    defer for (responses) |r| alloc.free(r);

    std.debug.print("BF_REPRO_TAG0_ORIGIN_RESPONSES_LEN={d}\n", .{responses.len});
    try std.testing.expect(responses.len >= 1);

    // First response must be MsgNoBlocks ([3]).
    var fbs = compat.fixedBufferStream(responses[0]);
    const t = cbor.decode(alloc, fbs.reader()) catch |e| {
        std.debug.print("BF_REPRO_FAIL: NoBlocks response cbor decode failed: {s}\n", .{@errorName(e)});
        return e;
    };
    defer cbor.free(t, alloc);
    try std.testing.expect(t == .array);
    try std.testing.expect(t.array.len >= 1);
    try std.testing.expect(t.array[0] == .u64);
    try std.testing.expectEqual(@as(u64, 3), t.array[0].u64);
    try std.testing.expect(!server.served_block);

    std.debug.print("BF_REPRO_PASS_TAG0_ORIGIN: tag-0 with Origin points returns MsgNoBlocks\n", .{});
}

// Regression: MsgClientDone (tag 1) MUST return null. This pairs with the
// tag-0/Origin test above to prove the classification is purely by wire tag,
// not by content.
test "BF_REPRO: handleMessage tag-1 ClientDone returns null" {
    const alloc = std.testing.allocator;

    var block_hash: [32]u8 = undefined;
    @memset(&block_hash, 0xAB);
    const block_cbor = "tsunagi-test-block-cbor-payload";
    var blocks = [_]blockfetch_server.SealedBlock{
        .{ .slot = 12345, .hash = block_hash, .block_cbor = block_cbor },
    };
    var server = blockfetch_server.BlockFetchServer.init(&blocks);

    // Wire payload: 0x81 0x01 = [1] = MsgClientDone.
    const msg_bytes = [_]u8{ 0x81, 0x01 };
    dumpBytes("BF_REPRO_TAG1_DONE_REQUEST", &msg_bytes);

    const responses_opt = server.handleMessage(alloc, &msg_bytes);
    if (responses_opt != null) {
        const r = responses_opt.?;
        std.debug.print("BF_REPRO_FAIL: handleMessage returned non-null on MsgClientDone (got {d} responses)\n", .{r.len});
        for (r) |b| alloc.free(b);
        alloc.free(r);
        return error.HandleMessageReturnedNonNullForClientDone;
    }
    try std.testing.expect(!server.served_block);

    std.debug.print("BF_REPRO_PASS_TAG1_DONE: tag-1 ClientDone correctly returns null\n", .{});
}
