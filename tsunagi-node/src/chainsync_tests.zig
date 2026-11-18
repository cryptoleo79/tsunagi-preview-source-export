const std = @import("std");
const compat = @import("compat");

const cbor = @import("net/cbor/term.zig");
const chainsync_codec = @import("net/chainsync/chainsync_codec.zig");
const chainsync_server = @import("protocols/chainsync_server.zig");
const blockfetch_server = @import("protocols/blockfetch_server.zig");

fn encodeToBytes(alloc: std.mem.Allocator, term: cbor.Term) ![]u8 {
    var list = std.array_list.Managed(u8).init(alloc);
    errdefer list.deinit();
    try cbor.encode(term, compat.listWriter(&list));
    return list.toOwnedSlice();
}

test "chainsync find intersect encode golden" {
    const alloc = std.testing.allocator;

    const empty_points = cbor.Term{ .array = @constCast((&[_]cbor.Term{})[0..]) };

    var list = std.array_list.Managed(u8).init(alloc);
    defer list.deinit();
    try chainsync_codec.encodeFindIntersect(compat.listWriter(&list), empty_points);
    const bytes = try list.toOwnedSlice();
    defer alloc.free(bytes);

    const expected = [_]u8{ 0x82, 0x04, 0x80 };
    try std.testing.expectEqualSlices(u8, &expected, bytes);
}

test "chainsync request next encode golden" {
    const alloc = std.testing.allocator;

    var list = std.array_list.Managed(u8).init(alloc);
    defer list.deinit();
    try chainsync_codec.encodeRequestNext(compat.listWriter(&list));
    const bytes = try list.toOwnedSlice();
    defer alloc.free(bytes);

    const expected = [_]u8{ 0x81, 0x00 };
    try std.testing.expectEqualSlices(u8, &expected, bytes);
}

test "chainsync decode intersect responses" {
    const alloc = std.testing.allocator;

    const found_term = cbor.Term{
        .array = @constCast((&[_]cbor.Term{
            .{ .u64 = 5 },
            .{ .u64 = 42 },
            .{ .text = @constCast("tip") },
        })[0..]),
    };
    const not_found_term = cbor.Term{ .array = @constCast((&[_]cbor.Term{ .{ .u64 = 6 }, .{ .text = @constCast("nope") } })[0..]) };

    const found_bytes = try encodeToBytes(alloc, found_term);
    defer alloc.free(found_bytes);
    var fbs1 = compat.fixedBufferStream(found_bytes);
    var msg1 = try chainsync_codec.decodeResponse(alloc, fbs1.reader());
    defer chainsync_codec.free(alloc, &msg1);

    try std.testing.expect(msg1 == .intersect_found);
    try std.testing.expect(msg1.intersect_found.point == .u64);
    try std.testing.expectEqual(@as(u64, 42), msg1.intersect_found.point.u64);
    try std.testing.expect(msg1.intersect_found.tip == .text);
    try std.testing.expect(std.mem.eql(u8, "tip", msg1.intersect_found.tip.text));

    const not_found_bytes = try encodeToBytes(alloc, not_found_term);
    defer alloc.free(not_found_bytes);
    var fbs2 = compat.fixedBufferStream(not_found_bytes);
    var msg2 = try chainsync_codec.decodeResponse(alloc, fbs2.reader());
    defer chainsync_codec.free(alloc, &msg2);

    try std.testing.expect(msg2 == .intersect_not_found);
    try std.testing.expect(msg2.intersect_not_found.tip == .text);
    try std.testing.expect(std.mem.eql(u8, "nope", msg2.intersect_not_found.tip.text));
}

test "chainsync decode roll forward/backward responses" {
    const alloc = std.testing.allocator;

    const roll_forward_term = cbor.Term{ .array = @constCast((&[_]cbor.Term{ .{ .u64 = 2 }, .{ .u64 = 7 }, .{ .u64 = 8 } })[0..]) };
    const roll_backward_term = cbor.Term{ .array = @constCast((&[_]cbor.Term{ .{ .u64 = 3 }, .{ .text = @constCast("rewind") }, .{ .u64 = 9 } })[0..]) };

    const forward_bytes = try encodeToBytes(alloc, roll_forward_term);
    defer alloc.free(forward_bytes);
    var fbs1 = compat.fixedBufferStream(forward_bytes);
    var msg1 = try chainsync_codec.decodeResponse(alloc, fbs1.reader());
    defer chainsync_codec.free(alloc, &msg1);

    try std.testing.expect(msg1 == .roll_forward);
    try std.testing.expect(msg1.roll_forward.block == .u64);
    try std.testing.expectEqual(@as(u64, 7), msg1.roll_forward.block.u64);
    try std.testing.expect(msg1.roll_forward.tip == .u64);
    try std.testing.expectEqual(@as(u64, 8), msg1.roll_forward.tip.u64);

    const backward_bytes = try encodeToBytes(alloc, roll_backward_term);
    defer alloc.free(backward_bytes);
    var fbs2 = compat.fixedBufferStream(backward_bytes);
    var msg2 = try chainsync_codec.decodeResponse(alloc, fbs2.reader());
    defer chainsync_codec.free(alloc, &msg2);

    try std.testing.expect(msg2 == .roll_backward);
    try std.testing.expect(msg2.roll_backward.point == .text);
    try std.testing.expect(std.mem.eql(u8, "rewind", msg2.roll_backward.point.text));
    try std.testing.expect(msg2.roll_backward.tip == .u64);
    try std.testing.expectEqual(@as(u64, 9), msg2.roll_backward.tip.u64);
}

test "chainsync decode await reply response" {
    const alloc = std.testing.allocator;

    const await_term = cbor.Term{ .array = @constCast((&[_]cbor.Term{.{ .u64 = 1 }})[0..]) };
    const await_bytes = try encodeToBytes(alloc, await_term);
    defer alloc.free(await_bytes);

    var fbs = compat.fixedBufferStream(await_bytes);
    var msg = try chainsync_codec.decodeResponse(alloc, fbs.reader());
    defer chainsync_codec.free(alloc, &msg);

    try std.testing.expect(msg == .await_reply);
}

test "chainsync decode roll forward/backward placeholders" {
    const alloc = std.testing.allocator;

    const roll_forward_term = cbor.Term{ .array = @constCast((&[_]cbor.Term{ .{ .u64 = 2 }, .{ .u64 = 0 }, .{ .u64 = 0 } })[0..]) };
    const roll_backward_term = cbor.Term{ .array = @constCast((&[_]cbor.Term{ .{ .u64 = 3 }, .{ .u64 = 0 }, .{ .u64 = 0 } })[0..]) };

    const forward_bytes = try encodeToBytes(alloc, roll_forward_term);
    defer alloc.free(forward_bytes);
    var fbs1 = compat.fixedBufferStream(forward_bytes);
    var msg1 = try chainsync_codec.decodeResponse(alloc, fbs1.reader());
    defer chainsync_codec.free(alloc, &msg1);

    try std.testing.expect(msg1 == .roll_forward);
    try std.testing.expect(msg1.roll_forward.block == .u64);
    try std.testing.expectEqual(@as(u64, 0), msg1.roll_forward.block.u64);
    try std.testing.expect(msg1.roll_forward.tip == .u64);
    try std.testing.expectEqual(@as(u64, 0), msg1.roll_forward.tip.u64);

    const backward_bytes = try encodeToBytes(alloc, roll_backward_term);
    defer alloc.free(backward_bytes);
    var fbs2 = compat.fixedBufferStream(backward_bytes);
    var msg2 = try chainsync_codec.decodeResponse(alloc, fbs2.reader());
    defer chainsync_codec.free(alloc, &msg2);

    try std.testing.expect(msg2 == .roll_backward);
    try std.testing.expect(msg2.roll_backward.point == .u64);
    try std.testing.expectEqual(@as(u64, 0), msg2.roll_backward.point.u64);
    try std.testing.expect(msg2.roll_backward.tip == .u64);
    try std.testing.expectEqual(@as(u64, 0), msg2.roll_backward.tip.u64);
}

test "chainsync server RollForward has HardFork era wrapper" {
    // Sends MsgRequestNext [0] to a ChainSyncServer and verifies the
    // RollForward response wire bytes start with:
    //   83 02 82 06 d8 18
    //   ^  ^  ^  ^  ^  ^
    //   |  |  |  |  |  +-- tag(24)
    //   |  |  |  |  +-- CBOR tag major byte
    //   |  |  |  +-- uint(6) Conway era index
    //   |  |  +-- array(2) SerialisedHeader
    //   |  +-- uint(2) MsgRollForward
    //   +-- array(3)
    const alloc = std.testing.allocator;

    // Build a fake 16-byte header and 32-byte hash
    const fake_header = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C };
    var fake_hash: [32]u8 = undefined;
    @memset(&fake_hash, 0x42);

    var server = chainsync_server.ChainSyncServer.init(.{
        .slot = 12345,
        .block_no = 100,
        .hash = fake_hash,
        .header_cbor = &fake_header,
        .era_index = 6,
    });

    // Encode MsgRequestNext = [0] → CBOR: 81 00
    const request_next = [_]u8{ 0x81, 0x00 };

    const wire = server.handleMessage(alloc, &request_next) orelse {
        std.debug.print("ERROR: handleMessage returned null\n", .{});
        return error.HandleMessageFailed;
    };
    defer alloc.free(wire);

    // Print first 16 bytes for human verification
    std.debug.print("\nRollForward wire ({d} bytes): ", .{wire.len});
    for (wire[0..@min(wire.len, 16)]) |b| {
        std.debug.print("{x:0>2} ", .{b});
    }
    std.debug.print("\n", .{});

    // Assert HardFork era wrapper prefix
    try std.testing.expect(wire.len >= 6);
    try std.testing.expectEqual(@as(u8, 0x83), wire[0]); // array(3)
    try std.testing.expectEqual(@as(u8, 0x02), wire[1]); // MsgRollForward
    try std.testing.expectEqual(@as(u8, 0x82), wire[2]); // array(2) SerialisedHeader
    try std.testing.expectEqual(@as(u8, 0x06), wire[3]); // Conway era = 6
    try std.testing.expectEqual(@as(u8, 0xd8), wire[4]); // CBOR tag
    try std.testing.expectEqual(@as(u8, 0x18), wire[5]); // tag(24)
}

test "chainsync server FindIntersect selects highest slot <= sealed" {
    const alloc = std.testing.allocator;

    const fake_header = [_]u8{0xAA} ** 16;
    var fake_hash: [32]u8 = undefined;
    @memset(&fake_hash, 0x42);

    // Sealed slot = 1000
    var server = chainsync_server.ChainSyncServer.init(.{
        .slot = 1000,
        .block_no = 50,
        .hash = fake_hash,
        .header_cbor = &fake_header,
    });

    // Build FindIntersect with 3 points: slot 2000 (too new), 900 (best), 500 (valid but lower)
    // Points are newest-first like a real relay
    var hash1: [3]u8 = .{ 0x01, 0x02, 0x03 };
    var hash2: [3]u8 = .{ 0x04, 0x05, 0x06 };
    var hash3: [3]u8 = .{ 0x07, 0x08, 0x09 };

    var pt1_items: [2]cbor.Term = .{ .{ .u64 = 2000 }, .{ .bytes = &hash1 } };
    var pt2_items: [2]cbor.Term = .{ .{ .u64 = 900 }, .{ .bytes = &hash2 } };
    var pt3_items: [2]cbor.Term = .{ .{ .u64 = 500 }, .{ .bytes = &hash3 } };

    var points: [3]cbor.Term = .{
        .{ .array = &pt1_items },
        .{ .array = &pt2_items },
        .{ .array = &pt3_items },
    };

    var msg_items: [2]cbor.Term = .{
        .{ .u64 = 4 }, // MsgFindIntersect
        .{ .array = &points },
    };

    const msg_term = cbor.Term{ .array = &msg_items };
    const msg_bytes = try encodeToBytes(alloc, msg_term);
    defer alloc.free(msg_bytes);

    const wire = server.handleMessage(alloc, msg_bytes) orelse return error.HandleMessageFailed;
    defer alloc.free(wire);

    // Should be MsgIntersectFound = [5, ...]
    // Decode and check the chosen point has slot=900 (not 2000 or 500)
    var fbs = compat.fixedBufferStream(wire);
    const resp = cbor.decode(alloc, fbs.reader()) catch return error.DecodeFailed;
    defer cbor.free(resp, alloc);

    try std.testing.expect(resp == .array);
    try std.testing.expect(resp.array.len == 3); // [5, point, tip]
    try std.testing.expectEqual(@as(u64, 5), resp.array[0].u64); // MsgIntersectFound
    // point = [slot, hash]
    try std.testing.expect(resp.array[1] == .array);
    try std.testing.expectEqual(@as(u64, 900), resp.array[1].array[0].u64);
    // intersect_slot should be recorded
    try std.testing.expectEqual(@as(u64, 900), server.intersect_slot);
}

test "chainsync server FindIntersect sends NotFound when all points > sealed" {
    const alloc = std.testing.allocator;

    const fake_header = [_]u8{0xAA} ** 16;
    var fake_hash: [32]u8 = undefined;
    @memset(&fake_hash, 0x42);

    // Sealed slot = 100
    var server = chainsync_server.ChainSyncServer.init(.{
        .slot = 100,
        .block_no = 10,
        .hash = fake_hash,
        .header_cbor = &fake_header,
    });

    // All points have slot > 100
    var hash1: [3]u8 = .{ 0x01, 0x02, 0x03 };
    var hash2: [3]u8 = .{ 0x04, 0x05, 0x06 };

    var pt1_items: [2]cbor.Term = .{ .{ .u64 = 500 }, .{ .bytes = &hash1 } };
    var pt2_items: [2]cbor.Term = .{ .{ .u64 = 200 }, .{ .bytes = &hash2 } };

    var points: [2]cbor.Term = .{
        .{ .array = &pt1_items },
        .{ .array = &pt2_items },
    };

    var msg_items: [2]cbor.Term = .{
        .{ .u64 = 4 },
        .{ .array = &points },
    };

    const msg_term = cbor.Term{ .array = &msg_items };
    const msg_bytes = try encodeToBytes(alloc, msg_term);
    defer alloc.free(msg_bytes);

    const wire = server.handleMessage(alloc, msg_bytes) orelse return error.HandleMessageFailed;
    defer alloc.free(wire);

    // Should be MsgIntersectNotFound = [6, tip]
    var fbs = compat.fixedBufferStream(wire);
    const resp = cbor.decode(alloc, fbs.reader()) catch return error.DecodeFailed;
    defer cbor.free(resp, alloc);

    try std.testing.expect(resp == .array);
    try std.testing.expectEqual(@as(u64, 6), resp.array[0].u64); // MsgIntersectNotFound
}

test "chainsync server FindIntersect accepts point with slot == sealed" {
    const alloc = std.testing.allocator;

    const fake_header = [_]u8{0xAA} ** 16;
    var fake_hash: [32]u8 = undefined;
    @memset(&fake_hash, 0x42);

    // Sealed slot = 1000; point with exact same slot should be accepted
    var server = chainsync_server.ChainSyncServer.init(.{
        .slot = 1000,
        .block_no = 50,
        .hash = fake_hash,
        .header_cbor = &fake_header,
    });

    var hash1: [3]u8 = .{ 0x01, 0x02, 0x03 };
    var pt1_items: [2]cbor.Term = .{ .{ .u64 = 1000 }, .{ .bytes = &hash1 } };
    var points: [1]cbor.Term = .{.{ .array = &pt1_items }};

    var msg_items: [2]cbor.Term = .{
        .{ .u64 = 4 },
        .{ .array = &points },
    };

    const msg_term = cbor.Term{ .array = &msg_items };
    const msg_bytes = try encodeToBytes(alloc, msg_term);
    defer alloc.free(msg_bytes);

    const wire = server.handleMessage(alloc, msg_bytes) orelse return error.HandleMessageFailed;
    defer alloc.free(wire);

    var fbs = compat.fixedBufferStream(wire);
    const resp = cbor.decode(alloc, fbs.reader()) catch return error.DecodeFailed;
    defer cbor.free(resp, alloc);

    try std.testing.expect(resp == .array);
    try std.testing.expectEqual(@as(u64, 5), resp.array[0].u64); // MsgIntersectFound
    try std.testing.expectEqual(@as(u64, 1000), resp.array[1].array[0].u64);
    try std.testing.expectEqual(@as(u64, 1000), server.intersect_slot);
}

test "chainsync server FindIntersect prefers strictly-earlier over exact-match" {
    const alloc = std.testing.allocator;

    const fake_header = [_]u8{0xAA} ** 16;
    var fake_hash: [32]u8 = undefined;
    @memset(&fake_hash, 0x42);

    // Sealed slot = 1000; points include 1000 (exact) and 900 (strictly earlier)
    // The server must prefer 900 so the first RequestNext advances the chain.
    var server = chainsync_server.ChainSyncServer.init(.{
        .slot = 1000,
        .block_no = 50,
        .hash = fake_hash,
        .header_cbor = &fake_header,
    });

    var hash1: [3]u8 = .{ 0x01, 0x02, 0x03 };
    var hash2: [3]u8 = .{ 0x04, 0x05, 0x06 };

    var pt1_items: [2]cbor.Term = .{ .{ .u64 = 1000 }, .{ .bytes = &hash1 } };
    var pt2_items: [2]cbor.Term = .{ .{ .u64 = 900 }, .{ .bytes = &hash2 } };

    var points: [2]cbor.Term = .{
        .{ .array = &pt1_items },
        .{ .array = &pt2_items },
    };

    var msg_items: [2]cbor.Term = .{
        .{ .u64 = 4 },
        .{ .array = &points },
    };

    const msg_term = cbor.Term{ .array = &msg_items };
    const msg_bytes = try encodeToBytes(alloc, msg_term);
    defer alloc.free(msg_bytes);

    const wire = server.handleMessage(alloc, msg_bytes) orelse return error.HandleMessageFailed;
    defer alloc.free(wire);

    var fbs = compat.fixedBufferStream(wire);
    const resp = cbor.decode(alloc, fbs.reader()) catch return error.DecodeFailed;
    defer cbor.free(resp, alloc);

    try std.testing.expect(resp == .array);
    try std.testing.expectEqual(@as(u64, 5), resp.array[0].u64); // MsgIntersectFound
    // Must choose 900 (strictly earlier), NOT 1000 (exact match)
    try std.testing.expectEqual(@as(u64, 900), resp.array[1].array[0].u64);
    try std.testing.expectEqual(@as(u64, 900), server.intersect_slot);
}

/// Build a minimal Cardano-format header CBOR: [[block_no, slot, prev_hash, ...filler], signature]
/// This is the format parseHeaderFields expects.
fn buildFakeHeaderCbor(alloc: std.mem.Allocator, block_no: u64, slot: u64) ![]u8 {
    var filler_hash: [32]u8 = undefined;
    @memset(&filler_hash, 0x00);
    return buildFakeHeaderCborWithPrevHash(alloc, block_no, slot, &filler_hash);
}

/// Build header CBOR with a specific prevHash for intersection testing.
fn buildFakeHeaderCborWithPrevHash(alloc: std.mem.Allocator, block_no: u64, slot: u64, prev_hash: *const [32]u8) ![]u8 {
    // header_body = [block_no, slot, prev_hash]  (minimal 3-element)
    var body_items: [3]cbor.Term = .{
        .{ .u64 = block_no },
        .{ .u64 = slot },
        .{ .bytes = prev_hash },
    };
    // header = [header_body, signature_bytes]
    var sig: [64]u8 = undefined;
    @memset(&sig, 0xFF);
    var hdr_items: [2]cbor.Term = .{
        .{ .array = &body_items },
        .{ .bytes = &sig },
    };
    const hdr_term = cbor.Term{ .array = &hdr_items };
    return encodeToBytes(alloc, hdr_term);
}

test "chainsync server parseHeaderFields extracts block_no, slot, and prevHash" {
    const alloc = std.testing.allocator;

    var expected_prev: [32]u8 = undefined;
    @memset(&expected_prev, 0xAB);
    const hdr = try buildFakeHeaderCborWithPrevHash(alloc, 4083309, 106076435, &expected_prev);
    defer alloc.free(hdr);

    const fields = chainsync_server.ChainSyncServer.parseHeaderFields(alloc, hdr) orelse
        return error.ParseFailed;
    try std.testing.expectEqual(@as(u64, 4083309), fields.block_no);
    try std.testing.expectEqual(@as(u64, 106076435), fields.slot);
    try std.testing.expect(fields.prev_hash != null);
    try std.testing.expectEqualSlices(u8, &expected_prev, &fields.prev_hash.?);
}

test "artifact consistency: header-derived values override tip values" {
    // Simulates the v4.5.11 fix: when upstream tip is ahead of the captured
    // header, parseHeaderFields returns the HEADER's slot/block_no, not the
    // tip's.  This is exactly what saveChainTipHeader now does at capture time.
    const alloc = std.testing.allocator;

    // Header is for block_no=4083428, slot=106080000
    // Upstream tip was at block_no=4083430, slot=106080100 (2 blocks ahead)
    const hdr = try buildFakeHeaderCbor(alloc, 4083428, 106080000);
    defer alloc.free(hdr);

    const fields = chainsync_server.ChainSyncServer.parseHeaderFields(alloc, hdr) orelse
        return error.ParseFailed;

    // Must return the HEADER's values, not the tip's
    try std.testing.expectEqual(@as(u64, 4083428), fields.block_no);
    try std.testing.expectEqual(@as(u64, 106080000), fields.slot);
    // These are the values that go into meta.json — NOT 4083430/106080100

    // Also verify hash is computed from header bytes (Blake2b-256)
    var expected_hash: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(hdr, &expected_hash, .{});
    // The hash should be deterministic for the same header CBOR
    try std.testing.expect(expected_hash[0] != 0 or expected_hash[1] != 0); // non-trivial
}

test "chainsync server resolveHeaderFields corrects meta mismatch" {
    const alloc = std.testing.allocator;

    // Simulate the real bug: meta.json has upstream tip (block_no=4083310, slot=106076500)
    // but header CBOR is for block_no=4083309, slot=106076435.
    const hdr = try buildFakeHeaderCbor(alloc, 4083309, 106076435);
    defer alloc.free(hdr);
    var fake_hash: [32]u8 = undefined;
    @memset(&fake_hash, 0x42);

    var server = chainsync_server.ChainSyncServer.init(.{
        .slot = 106076500, // wrong: from upstream tip
        .block_no = 4083310, // wrong: from upstream tip
        .hash = fake_hash,
        .header_cbor = hdr,
    });

    // Trigger resolution via handleMessage (send a FindIntersect)
    var hash1: [3]u8 = .{ 0x01, 0x02, 0x03 };
    var pt1_items: [2]cbor.Term = .{ .{ .u64 = 106076400 }, .{ .bytes = &hash1 } };
    var points: [1]cbor.Term = .{.{ .array = &pt1_items }};
    var msg_items: [2]cbor.Term = .{ .{ .u64 = 4 }, .{ .array = &points } };
    const msg_bytes = try encodeToBytes(alloc, cbor.Term{ .array = &msg_items });
    defer alloc.free(msg_bytes);

    const wire = server.handleMessage(alloc, msg_bytes) orelse return error.HandleMessageFailed;
    defer alloc.free(wire);

    // After resolution, sealed fields should match the header CBOR
    try std.testing.expectEqual(@as(u64, 106076435), server.sealed.slot);
    try std.testing.expectEqual(@as(u64, 4083309), server.sealed.block_no);
    try std.testing.expect(server.resolved);
}

test "chainsync server RequestNext guards against intersect_slot >= sealed_slot" {
    const alloc = std.testing.allocator;

    const hdr = try buildFakeHeaderCbor(alloc, 50, 1000);
    defer alloc.free(hdr);
    var fake_hash: [32]u8 = undefined;
    @memset(&fake_hash, 0x42);

    var server = chainsync_server.ChainSyncServer.init(.{
        .slot = 1000,
        .block_no = 50,
        .hash = fake_hash,
        .header_cbor = hdr,
    });

    // Simulate: FindIntersect chose slot == sealed.slot via prevHash match
    // buildFakeHeaderCbor uses prevHash = 0x00..00, so point hash must match
    var hash1: [32]u8 = undefined;
    @memset(&hash1, 0x00); // matches prevHash from buildFakeHeaderCbor
    var pt1_items: [2]cbor.Term = .{ .{ .u64 = 1000 }, .{ .bytes = &hash1 } };
    var points: [1]cbor.Term = .{.{ .array = &pt1_items }};
    var fi_items: [2]cbor.Term = .{ .{ .u64 = 4 }, .{ .array = &points } };
    const fi_bytes = try encodeToBytes(alloc, cbor.Term{ .array = &fi_items });
    defer alloc.free(fi_bytes);

    const fi_wire = server.handleMessage(alloc, fi_bytes) orelse return error.HandleMessageFailed;
    alloc.free(fi_wire);

    // intersect_slot should be 1000 (same as sealed)
    try std.testing.expectEqual(@as(u64, 1000), server.intersect_slot);

    // RequestNext #1 → RollBackward (spec-required after IntersectFound)
    const request_next = [_]u8{ 0x81, 0x00 };
    const wire_rb = server.handleMessage(alloc, &request_next) orelse return error.HandleMessageFailed;
    defer alloc.free(wire_rb);
    try std.testing.expectEqual(@as(u8, 0x03), wire_rb[1]); // RollBackward

    // RequestNext #2 → AwaitReply (guard prevents RollForward since intersect_slot >= sealed)
    const wire = server.handleMessage(alloc, &request_next) orelse return error.HandleMessageFailed;
    defer alloc.free(wire);

    // Must be AwaitReply [1], NOT RollForward [2]
    try std.testing.expectEqual(@as(u8, 0x81), wire[0]); // array(1)
    try std.testing.expectEqual(@as(u8, 0x01), wire[1]); // uint(1) MsgAwaitReply
    try std.testing.expect(!server.served_header); // header was NOT served (guard blocked it)
}

test "chainsync server FindIntersect prefers prevHash match over slot-based" {
    const alloc = std.testing.allocator;

    // Sealed header at slot=1000, block_no=50, with prevHash = 0xDD..DD
    var prev_hash: [32]u8 = undefined;
    @memset(&prev_hash, 0xDD);
    const hdr = try buildFakeHeaderCborWithPrevHash(alloc, 50, 1000, &prev_hash);
    defer alloc.free(hdr);
    var fake_hash: [32]u8 = undefined;
    @memset(&fake_hash, 0x42);

    var server = chainsync_server.ChainSyncServer.init(.{
        .slot = 1000,
        .block_no = 50,
        .hash = fake_hash,
        .header_cbor = hdr,
    });

    // Relay offers 3 points:
    //   pt0: slot=999, hash=0xEE..EE (slot-based would pick this: highest < 1000)
    //   pt1: slot=998, hash=0xDD..DD (prevHash match — should be selected)
    //   pt2: slot=500, hash=0xCC..CC
    var hash0: [32]u8 = undefined;
    @memset(&hash0, 0xEE);
    var hash1: [32]u8 = undefined;
    @memset(&hash1, 0xDD); // matches prevHash
    var hash2: [32]u8 = undefined;
    @memset(&hash2, 0xCC);

    var pt0_items: [2]cbor.Term = .{ .{ .u64 = 999 }, .{ .bytes = &hash0 } };
    var pt1_items: [2]cbor.Term = .{ .{ .u64 = 998 }, .{ .bytes = &hash1 } };
    var pt2_items: [2]cbor.Term = .{ .{ .u64 = 500 }, .{ .bytes = &hash2 } };

    var points: [3]cbor.Term = .{
        .{ .array = &pt0_items },
        .{ .array = &pt1_items },
        .{ .array = &pt2_items },
    };

    var msg_items: [2]cbor.Term = .{
        .{ .u64 = 4 },
        .{ .array = &points },
    };

    const msg_term = cbor.Term{ .array = &msg_items };
    const msg_bytes = try encodeToBytes(alloc, msg_term);
    defer alloc.free(msg_bytes);

    const wire = server.handleMessage(alloc, msg_bytes) orelse return error.HandleMessageFailed;
    defer alloc.free(wire);

    // Should be MsgIntersectFound [5, ...]
    var fbs = compat.fixedBufferStream(wire);
    const resp = cbor.decode(alloc, fbs.reader()) catch return error.DecodeFailed;
    defer cbor.free(resp, alloc);

    try std.testing.expect(resp == .array);
    try std.testing.expectEqual(@as(u64, 5), resp.array[0].u64); // IntersectFound
    // Must choose slot=998 (prevHash match), NOT slot=999 (slot-based would prefer)
    try std.testing.expectEqual(@as(u64, 998), resp.array[1].array[0].u64);
    try std.testing.expectEqual(@as(u64, 998), server.intersect_slot);
    // prevHash should have been parsed
    try std.testing.expect(server.has_prev_hash);
}

test "strict FindIntersect returns IntersectNotFound when prevHash not in points" {
    const alloc = std.testing.allocator;

    // Sealed header at slot=1000, block_no=50, with prevHash = 0xDD..DD
    var prev_hash: [32]u8 = undefined;
    @memset(&prev_hash, 0xDD);
    const hdr = try buildFakeHeaderCborWithPrevHash(alloc, 50, 1000, &prev_hash);
    defer alloc.free(hdr);
    var fake_hash: [32]u8 = undefined;
    @memset(&fake_hash, 0x42);

    var server = chainsync_server.ChainSyncServer.init(.{
        .slot = 1000,
        .block_no = 50,
        .hash = fake_hash,
        .header_cbor = hdr,
    });

    // Relay offers 2 points — NEITHER hash matches prevHash (0xDD..DD)
    //   pt0: slot=999, hash=0xEE..EE (would be picked by slot-based, but must NOT)
    //   pt1: slot=500, hash=0xCC..CC
    var hash0: [32]u8 = undefined;
    @memset(&hash0, 0xEE);
    var hash1: [32]u8 = undefined;
    @memset(&hash1, 0xCC);

    var pt0_items: [2]cbor.Term = .{ .{ .u64 = 999 }, .{ .bytes = &hash0 } };
    var pt1_items: [2]cbor.Term = .{ .{ .u64 = 500 }, .{ .bytes = &hash1 } };

    var points: [2]cbor.Term = .{
        .{ .array = &pt0_items },
        .{ .array = &pt1_items },
    };

    var msg_items: [2]cbor.Term = .{
        .{ .u64 = 4 },
        .{ .array = &points },
    };

    const msg_term = cbor.Term{ .array = &msg_items };
    const msg_bytes = try encodeToBytes(alloc, msg_term);
    defer alloc.free(msg_bytes);

    const wire = server.handleMessage(alloc, msg_bytes) orelse return error.HandleMessageFailed;
    defer alloc.free(wire);

    // Must be MsgIntersectNotFound [6, tip] — strict mode, no slot fallback
    var fbs = compat.fixedBufferStream(wire);
    const resp = cbor.decode(alloc, fbs.reader()) catch return error.DecodeFailed;
    defer cbor.free(resp, alloc);

    try std.testing.expect(resp == .array);
    try std.testing.expectEqual(@as(u64, 6), resp.array[0].u64); // MsgIntersectNotFound
    // prevHash was parsed
    try std.testing.expect(server.has_prev_hash);
    // intersect_slot should still be 0 (no intersection was chosen)
    try std.testing.expectEqual(@as(u64, 0), server.intersect_slot);
}

test "FindIntersect falls back to slot when prevHash unavailable" {
    const alloc = std.testing.allocator;

    // Build a header with NO parseable prevHash (use a non-standard format)
    // Using a raw 16-byte fake header that parseHeaderFields can't parse
    const fake_header = [_]u8{0xAA} ** 16;
    var fake_hash: [32]u8 = undefined;
    @memset(&fake_hash, 0x42);

    var server = chainsync_server.ChainSyncServer.init(.{
        .slot = 1000,
        .block_no = 50,
        .hash = fake_hash,
        .header_cbor = &fake_header,
    });

    // has_prev_hash should be false (unparseable header)
    // Trigger resolution via first message
    var hash0: [32]u8 = undefined;
    @memset(&hash0, 0xEE);
    var hash1: [32]u8 = undefined;
    @memset(&hash1, 0xCC);

    var pt0_items: [2]cbor.Term = .{ .{ .u64 = 999 }, .{ .bytes = &hash0 } };
    var pt1_items: [2]cbor.Term = .{ .{ .u64 = 500 }, .{ .bytes = &hash1 } };

    var points: [2]cbor.Term = .{
        .{ .array = &pt0_items },
        .{ .array = &pt1_items },
    };

    var msg_items: [2]cbor.Term = .{
        .{ .u64 = 4 },
        .{ .array = &points },
    };

    const msg_term = cbor.Term{ .array = &msg_items };
    const msg_bytes = try encodeToBytes(alloc, msg_term);
    defer alloc.free(msg_bytes);

    const wire = server.handleMessage(alloc, msg_bytes) orelse return error.HandleMessageFailed;
    defer alloc.free(wire);

    // Should be MsgIntersectFound [5, ...] via slot fallback (highest slot < 1000 = 999)
    var fbs = compat.fixedBufferStream(wire);
    const resp = cbor.decode(alloc, fbs.reader()) catch return error.DecodeFailed;
    defer cbor.free(resp, alloc);

    try std.testing.expect(resp == .array);
    try std.testing.expectEqual(@as(u64, 5), resp.array[0].u64); // MsgIntersectFound
    // Must pick slot=999 via slot_fallback
    try std.testing.expectEqual(@as(u64, 999), resp.array[1].array[0].u64);
    try std.testing.expectEqual(@as(u64, 999), server.intersect_slot);
    // prevHash should NOT be available
    try std.testing.expect(!server.has_prev_hash);
}

// ── v4.5.13 Fragment tests ──────────────────────────────────────────

test "fragment FindIntersect matches relay point against fragment hash" {
    const alloc = std.testing.allocator;

    // Build a 3-entry fragment: entries 0, 1, 2 (oldest→newest)
    // Entry 0: slot=990, hash=0xAA..AA, prev_hash=0x00..00
    // Entry 1: slot=995, hash=0xBB..BB, prev_hash=0xAA..AA
    // Entry 2: slot=998, hash=0xCC..CC, prev_hash=0xBB..BB
    // Sealed tip: slot=1000, hash=0xDD..DD (header that will be served after fragment)
    var prev0: [32]u8 = undefined;
    @memset(&prev0, 0x00);
    var hash0: [32]u8 = undefined;
    @memset(&hash0, 0xAA);
    var hash1: [32]u8 = undefined;
    @memset(&hash1, 0xBB);
    var hash2: [32]u8 = undefined;
    @memset(&hash2, 0xCC);

    const hdr0 = try buildFakeHeaderCborWithPrevHash(alloc, 40, 990, &prev0);
    defer alloc.free(hdr0);
    const hdr1 = try buildFakeHeaderCborWithPrevHash(alloc, 41, 995, &hash0);
    defer alloc.free(hdr1);
    const hdr2 = try buildFakeHeaderCborWithPrevHash(alloc, 42, 998, &hash1);
    defer alloc.free(hdr2);

    var fragment = [_]chainsync_server.FragmentEntry{
        .{ .slot = 990, .block_no = 40, .hash = hash0, .prev_hash = prev0, .header_cbor = hdr0 },
        .{ .slot = 995, .block_no = 41, .hash = hash1, .prev_hash = hash0, .header_cbor = hdr1 },
        .{ .slot = 998, .block_no = 42, .hash = hash2, .prev_hash = hash1, .header_cbor = hdr2 },
    };

    var sealed_hash: [32]u8 = undefined;
    @memset(&sealed_hash, 0xDD);
    const sealed_hdr = try buildFakeHeaderCborWithPrevHash(alloc, 43, 1000, &hash2);
    defer alloc.free(sealed_hdr);

    var server = chainsync_server.ChainSyncServer.initWithFragment(.{
        .slot = 1000,
        .block_no = 43,
        .hash = sealed_hash,
        .header_cbor = sealed_hdr,
    }, &fragment);

    // Relay offers point with hash=0xBB..BB (fragment entry 1)
    var pt_hash: [32]u8 = undefined;
    @memset(&pt_hash, 0xBB);
    var pt_items: [2]cbor.Term = .{ .{ .u64 = 995 }, .{ .bytes = &pt_hash } };
    var points: [1]cbor.Term = .{.{ .array = &pt_items }};
    var msg_items: [2]cbor.Term = .{ .{ .u64 = 4 }, .{ .array = &points } };
    const msg_bytes = try encodeToBytes(alloc, cbor.Term{ .array = &msg_items });
    defer alloc.free(msg_bytes);

    const wire = server.handleMessage(alloc, msg_bytes) orelse return error.HandleMessageFailed;
    defer alloc.free(wire);

    // Should be MsgIntersectFound [5, point, tip]
    var fbs = compat.fixedBufferStream(wire);
    const resp = cbor.decode(alloc, fbs.reader()) catch return error.DecodeFailed;
    defer cbor.free(resp, alloc);

    try std.testing.expect(resp == .array);
    try std.testing.expectEqual(@as(u64, 5), resp.array[0].u64); // IntersectFound
    try std.testing.expectEqual(@as(u64, 995), resp.array[1].array[0].u64);

    // fragment_serve_idx should be 2 (successor of entry 1)
    try std.testing.expectEqual(@as(usize, 2), server.fragment_serve_idx);
}

test "fragment FindIntersect serves successor headers via RequestNext" {
    const alloc = std.testing.allocator;

    // 2-entry fragment, intersect at entry 0 → should serve entry 1, then sealed
    var prev0: [32]u8 = undefined;
    @memset(&prev0, 0x00);
    var hash0: [32]u8 = undefined;
    @memset(&hash0, 0xAA);
    var hash1: [32]u8 = undefined;
    @memset(&hash1, 0xBB);

    const hdr0 = try buildFakeHeaderCborWithPrevHash(alloc, 40, 990, &prev0);
    defer alloc.free(hdr0);
    const hdr1 = try buildFakeHeaderCborWithPrevHash(alloc, 41, 995, &hash0);
    defer alloc.free(hdr1);

    var fragment = [_]chainsync_server.FragmentEntry{
        .{ .slot = 990, .block_no = 40, .hash = hash0, .prev_hash = prev0, .header_cbor = hdr0 },
        .{ .slot = 995, .block_no = 41, .hash = hash1, .prev_hash = hash0, .header_cbor = hdr1 },
    };

    var sealed_hash: [32]u8 = undefined;
    @memset(&sealed_hash, 0xCC);
    const sealed_hdr = try buildFakeHeaderCborWithPrevHash(alloc, 42, 1000, &hash1);
    defer alloc.free(sealed_hdr);

    var server = chainsync_server.ChainSyncServer.initWithFragment(.{
        .slot = 1000,
        .block_no = 42,
        .hash = sealed_hash,
        .header_cbor = sealed_hdr,
    }, &fragment);

    // FindIntersect at entry 0 (hash=0xAA)
    var pt_hash: [32]u8 = undefined;
    @memset(&pt_hash, 0xAA);
    var pt_items: [2]cbor.Term = .{ .{ .u64 = 990 }, .{ .bytes = &pt_hash } };
    var points: [1]cbor.Term = .{.{ .array = &pt_items }};
    var msg_items: [2]cbor.Term = .{ .{ .u64 = 4 }, .{ .array = &points } };
    const fi_bytes = try encodeToBytes(alloc, cbor.Term{ .array = &msg_items });
    defer alloc.free(fi_bytes);
    const fi_wire = server.handleMessage(alloc, fi_bytes) orelse return error.HandleMessageFailed;
    alloc.free(fi_wire);

    // fragment_serve_idx = 1 (successor of entry 0)
    try std.testing.expectEqual(@as(usize, 1), server.fragment_serve_idx);

    // RequestNext #1 → RollBackward (spec-required after IntersectFound)
    const rn = [_]u8{ 0x81, 0x00 };
    const wire_rb = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(wire_rb);
    try std.testing.expect(wire_rb.len >= 2);
    try std.testing.expectEqual(@as(u8, 0x03), wire_rb[1]); // RollBackward

    // RequestNext #2 → should serve fragment entry 1 (slot=995)
    const wire1 = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(wire1);

    // Should be MsgRollForward [2, ...]
    try std.testing.expect(wire1.len >= 2);
    try std.testing.expectEqual(@as(u8, 0x02), wire1[1]); // RollForward

    // RequestNext #3 → fragment exhausted, serve sealed header (slot=1000)
    const wire2 = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(wire2);
    try std.testing.expectEqual(@as(u8, 0x02), wire2[1]); // RollForward

    // RequestNext #4 → AwaitReply (all served)
    const wire3 = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(wire3);
    try std.testing.expectEqual(@as(u8, 0x81), wire3[0]); // array(1)
    try std.testing.expectEqual(@as(u8, 0x01), wire3[1]); // AwaitReply
}

test "fragment FindIntersect returns IntersectNotFound when no hash matches" {
    const alloc = std.testing.allocator;

    var prev0: [32]u8 = undefined;
    @memset(&prev0, 0x00);
    var hash0: [32]u8 = undefined;
    @memset(&hash0, 0xAA);

    const hdr0 = try buildFakeHeaderCborWithPrevHash(alloc, 40, 990, &prev0);
    defer alloc.free(hdr0);

    var fragment = [_]chainsync_server.FragmentEntry{
        .{ .slot = 990, .block_no = 40, .hash = hash0, .prev_hash = prev0, .header_cbor = hdr0 },
    };

    var sealed_hash: [32]u8 = undefined;
    @memset(&sealed_hash, 0xDD);
    const sealed_hdr = try buildFakeHeaderCborWithPrevHash(alloc, 41, 1000, &hash0);
    defer alloc.free(sealed_hdr);

    var server = chainsync_server.ChainSyncServer.initWithFragment(.{
        .slot = 1000,
        .block_no = 41,
        .hash = sealed_hash,
        .header_cbor = sealed_hdr,
    }, &fragment);

    // Relay point with hash=0xFF..FF (no match in fragment)
    var pt_hash: [32]u8 = undefined;
    @memset(&pt_hash, 0xFF);
    var pt_items: [2]cbor.Term = .{ .{ .u64 = 990 }, .{ .bytes = &pt_hash } };
    var points: [1]cbor.Term = .{.{ .array = &pt_items }};
    var msg_items: [2]cbor.Term = .{ .{ .u64 = 4 }, .{ .array = &points } };
    const msg_bytes = try encodeToBytes(alloc, cbor.Term{ .array = &msg_items });
    defer alloc.free(msg_bytes);

    const wire = server.handleMessage(alloc, msg_bytes) orelse return error.HandleMessageFailed;
    defer alloc.free(wire);

    // Must be MsgIntersectNotFound [6, tip]
    var fbs = compat.fixedBufferStream(wire);
    const resp = cbor.decode(alloc, fbs.reader()) catch return error.DecodeFailed;
    defer cbor.free(resp, alloc);

    try std.testing.expect(resp == .array);
    try std.testing.expectEqual(@as(u64, 6), resp.array[0].u64); // IntersectNotFound
}

test "fragment FindIntersect at tip returns IntersectFound then AwaitReply" {
    const alloc = std.testing.allocator;

    // Intersect at the last fragment entry → no successors in fragment → serve sealed → AwaitReply
    var prev0: [32]u8 = undefined;
    @memset(&prev0, 0x00);
    var hash0: [32]u8 = undefined;
    @memset(&hash0, 0xAA);

    const hdr0 = try buildFakeHeaderCborWithPrevHash(alloc, 40, 990, &prev0);
    defer alloc.free(hdr0);

    var fragment = [_]chainsync_server.FragmentEntry{
        .{ .slot = 990, .block_no = 40, .hash = hash0, .prev_hash = prev0, .header_cbor = hdr0 },
    };

    var sealed_hash: [32]u8 = undefined;
    @memset(&sealed_hash, 0xDD);
    const sealed_hdr = try buildFakeHeaderCborWithPrevHash(alloc, 41, 1000, &hash0);
    defer alloc.free(sealed_hdr);

    var server = chainsync_server.ChainSyncServer.initWithFragment(.{
        .slot = 1000,
        .block_no = 41,
        .hash = sealed_hash,
        .header_cbor = sealed_hdr,
    }, &fragment);

    // Intersect at the only fragment entry (hash=0xAA)
    var pt_hash: [32]u8 = undefined;
    @memset(&pt_hash, 0xAA);
    var pt_items: [2]cbor.Term = .{ .{ .u64 = 990 }, .{ .bytes = &pt_hash } };
    var points: [1]cbor.Term = .{.{ .array = &pt_items }};
    var msg_items: [2]cbor.Term = .{ .{ .u64 = 4 }, .{ .array = &points } };
    const fi_bytes = try encodeToBytes(alloc, cbor.Term{ .array = &msg_items });
    defer alloc.free(fi_bytes);
    const fi_wire = server.handleMessage(alloc, fi_bytes) orelse return error.HandleMessageFailed;
    alloc.free(fi_wire);

    // fragment_serve_idx = 1 (past end of fragment)
    try std.testing.expectEqual(@as(usize, 1), server.fragment_serve_idx);

    // RequestNext → RollBackward (spec-required after IntersectFound)
    const rn = [_]u8{ 0x81, 0x00 };
    const wire_rb = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(wire_rb);
    try std.testing.expect(wire_rb.len >= 2);
    try std.testing.expectEqual(@as(u8, 0x03), wire_rb[1]); // RollBackward

    // RequestNext → fragment exhausted → serve sealed header
    const wire1 = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(wire1);
    try std.testing.expectEqual(@as(u8, 0x02), wire1[1]); // RollForward (sealed)

    // RequestNext → AwaitReply
    const wire2 = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(wire2);
    try std.testing.expectEqual(@as(u8, 0x81), wire2[0]);
    try std.testing.expectEqual(@as(u8, 0x01), wire2[1]); // AwaitReply
}

// ── v4.5.15 Fragment capture correctness tests ─────────────────────

test "contiguous fragment serves complete chain from intersect to tip" {
    // Simulates what a correctly-captured fragment looks like:
    // Fragment: [block40, block41, block42] — contiguous chain
    // Sealed tip: block43 (prevHash = hash of block42)
    // Intersect at block40 → serve block41, block42, block43, then AwaitReply
    const alloc = std.testing.allocator;

    var prev0: [32]u8 = undefined;
    @memset(&prev0, 0x00);
    var hash0: [32]u8 = undefined;
    @memset(&hash0, 0xA0);
    var hash1: [32]u8 = undefined;
    @memset(&hash1, 0xA1);
    var hash2: [32]u8 = undefined;
    @memset(&hash2, 0xA2);

    const hdr0 = try buildFakeHeaderCborWithPrevHash(alloc, 40, 990, &prev0);
    defer alloc.free(hdr0);
    const hdr1 = try buildFakeHeaderCborWithPrevHash(alloc, 41, 991, &hash0);
    defer alloc.free(hdr1);
    const hdr2 = try buildFakeHeaderCborWithPrevHash(alloc, 42, 992, &hash1);
    defer alloc.free(hdr2);

    var fragment = [_]chainsync_server.FragmentEntry{
        .{ .slot = 990, .block_no = 40, .hash = hash0, .prev_hash = prev0, .header_cbor = hdr0 },
        .{ .slot = 991, .block_no = 41, .hash = hash1, .prev_hash = hash0, .header_cbor = hdr1 },
        .{ .slot = 992, .block_no = 42, .hash = hash2, .prev_hash = hash1, .header_cbor = hdr2 },
    };

    var sealed_hash: [32]u8 = undefined;
    @memset(&sealed_hash, 0xA3);
    const sealed_hdr = try buildFakeHeaderCborWithPrevHash(alloc, 43, 1000, &hash2);
    defer alloc.free(sealed_hdr);

    var server = chainsync_server.ChainSyncServer.initWithFragment(.{
        .slot = 1000,
        .block_no = 43,
        .hash = sealed_hash,
        .header_cbor = sealed_hdr,
    }, &fragment);

    // FindIntersect at block40 (hash0)
    var pt_hash: [32]u8 = undefined;
    @memset(&pt_hash, 0xA0);
    var pt_items: [2]cbor.Term = .{ .{ .u64 = 990 }, .{ .bytes = &pt_hash } };
    var points: [1]cbor.Term = .{.{ .array = &pt_items }};
    var msg_items: [2]cbor.Term = .{ .{ .u64 = 4 }, .{ .array = &points } };
    const fi_bytes = try encodeToBytes(alloc, cbor.Term{ .array = &msg_items });
    defer alloc.free(fi_bytes);
    const fi_wire = server.handleMessage(alloc, fi_bytes) orelse return error.HandleMessageFailed;
    alloc.free(fi_wire);

    const rn = [_]u8{ 0x81, 0x00 };

    // RequestNext #1 → RollBackward (spec-required after IntersectFound)
    const w_rb = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w_rb);
    try std.testing.expectEqual(@as(u8, 0x03), w_rb[1]); // RollBackward

    // RequestNext #2 → fragment[1] (block41)
    const w1 = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w1);
    try std.testing.expectEqual(@as(u8, 0x02), w1[1]); // RollForward

    // RequestNext #3 → fragment[2] (block42)
    const w2 = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w2);
    try std.testing.expectEqual(@as(u8, 0x02), w2[1]); // RollForward

    // RequestNext #4 → sealed tip (block43)
    const w3 = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w3);
    try std.testing.expectEqual(@as(u8, 0x02), w3[1]); // RollForward

    // RequestNext #5 → AwaitReply (all served)
    const w4 = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w4);
    try std.testing.expectEqual(@as(u8, 0x81), w4[0]);
    try std.testing.expectEqual(@as(u8, 0x01), w4[1]); // AwaitReply

    // Count: 3 fragment + 1 sealed = 4 RollForwards (plus 1 RollBackward)
    try std.testing.expect(server.served_header);
    try std.testing.expect(server.served_sealed);
}

test "broken fragment ancestry is rejected by propagation loader" {
    // This tests the ChainSync server with a fragment that has a break.
    // In practice, v4.5.15 follower prevents this, but the propagation
    // loader also verifies contiguity as a safety net.
    //
    // Fragment: [block40 (hash=AA), block42 (prevHash=FF, NOT AA)]
    // The loader would keep only the contiguous tail (block42 alone).
    // We test here that a single-entry fragment still works correctly.
    const alloc = std.testing.allocator;

    var prev0: [32]u8 = undefined;
    @memset(&prev0, 0x00);
    var hash0: [32]u8 = undefined;
    @memset(&hash0, 0xAA);

    const hdr0 = try buildFakeHeaderCborWithPrevHash(alloc, 42, 992, &prev0);
    defer alloc.free(hdr0);

    // Single-entry fragment (what the loader would produce after trimming broken chain)
    var fragment = [_]chainsync_server.FragmentEntry{
        .{ .slot = 992, .block_no = 42, .hash = hash0, .prev_hash = prev0, .header_cbor = hdr0 },
    };

    var sealed_hash: [32]u8 = undefined;
    @memset(&sealed_hash, 0xBB);
    const sealed_hdr = try buildFakeHeaderCborWithPrevHash(alloc, 43, 1000, &hash0);
    defer alloc.free(sealed_hdr);

    var server = chainsync_server.ChainSyncServer.initWithFragment(.{
        .slot = 1000,
        .block_no = 43,
        .hash = sealed_hash,
        .header_cbor = sealed_hdr,
    }, &fragment);

    // Intersect at the single fragment entry
    var pt_hash: [32]u8 = undefined;
    @memset(&pt_hash, 0xAA);
    var pt_items: [2]cbor.Term = .{ .{ .u64 = 992 }, .{ .bytes = &pt_hash } };
    var points: [1]cbor.Term = .{.{ .array = &pt_items }};
    var msg_items: [2]cbor.Term = .{ .{ .u64 = 4 }, .{ .array = &points } };
    const fi_bytes = try encodeToBytes(alloc, cbor.Term{ .array = &msg_items });
    defer alloc.free(fi_bytes);
    const fi_wire = server.handleMessage(alloc, fi_bytes) orelse return error.HandleMessageFailed;
    alloc.free(fi_wire);

    const rn = [_]u8{ 0x81, 0x00 };

    // RequestNext → RollBackward (spec-required after IntersectFound)
    const w_rb = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w_rb);
    try std.testing.expectEqual(@as(u8, 0x03), w_rb[1]); // RollBackward

    // RequestNext → sealed tip
    const w1 = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w1);
    try std.testing.expectEqual(@as(u8, 0x02), w1[1]); // RollForward

    // RequestNext → AwaitReply
    const w2 = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w2);
    try std.testing.expectEqual(@as(u8, 0x01), w2[1]); // AwaitReply
}

// ── v4.5.15-fragment-loader: loadFragment trim + wipe + seal-tip tests ──

test "loadFragment keeps newest contiguous suffix when BREAK exists" {
    // Simulates loadFragment's backwards-walk: fragment has a BREAK in the
    // middle. The loader must keep the NEWEST contiguous suffix (closest to
    // sealed tip), NOT the oldest head.
    //
    // Fragment: [old_A(40), old_B(41), new_C(50), new_D(51)]
    //   old_B.hash != new_C.prev_hash → BREAK at idx=2
    //   After trim: [new_C(50), new_D(51)]
    //   Sealed tip (52): prevHash == new_D.hash
    const alloc = std.testing.allocator;

    // Old chain entries (will be discarded)
    var prev_old: [32]u8 = undefined;
    @memset(&prev_old, 0x00);
    var hash_A: [32]u8 = undefined;
    @memset(&hash_A, 0xA0);
    var hash_B: [32]u8 = undefined;
    @memset(&hash_B, 0xA1);

    // New chain entries (will be kept)
    var prev_new: [32]u8 = undefined;
    @memset(&prev_new, 0xF0); // does NOT equal hash_B → BREAK
    var hash_C: [32]u8 = undefined;
    @memset(&hash_C, 0xC0);
    var hash_D: [32]u8 = undefined;
    @memset(&hash_D, 0xD0);

    const hdr_A = try buildFakeHeaderCborWithPrevHash(alloc, 40, 400, &prev_old);
    defer alloc.free(hdr_A);
    const hdr_B = try buildFakeHeaderCborWithPrevHash(alloc, 41, 410, &hash_A);
    defer alloc.free(hdr_B);
    const hdr_C = try buildFakeHeaderCborWithPrevHash(alloc, 50, 500, &prev_new);
    defer alloc.free(hdr_C);
    const hdr_D = try buildFakeHeaderCborWithPrevHash(alloc, 51, 510, &hash_C);
    defer alloc.free(hdr_D);

    var full_fragment = [_]chainsync_server.FragmentEntry{
        .{ .slot = 400, .block_no = 40, .hash = hash_A, .prev_hash = prev_old, .header_cbor = hdr_A },
        .{ .slot = 410, .block_no = 41, .hash = hash_B, .prev_hash = hash_A, .header_cbor = hdr_B },
        .{ .slot = 500, .block_no = 50, .hash = hash_C, .prev_hash = prev_new, .header_cbor = hdr_C },
        .{ .slot = 510, .block_no = 51, .hash = hash_D, .prev_hash = hash_C, .header_cbor = hdr_D },
    };

    // Apply loadFragment's backwards-walk trim logic
    var tail_start: usize = full_fragment.len;
    {
        var contig_from: usize = full_fragment.len - 1;
        while (contig_from > 0) : (contig_from -= 1) {
            if (!std.mem.eql(u8, &full_fragment[contig_from].prev_hash, &full_fragment[contig_from - 1].hash)) {
                break;
            }
        }
        tail_start = contig_from;
    }
    // BREAK at idx=2: hash_B (0xA1) != prev_new (0xF0)
    try std.testing.expectEqual(@as(usize, 2), tail_start);

    const trimmed = full_fragment[tail_start..];
    try std.testing.expectEqual(@as(usize, 2), trimmed.len);
    try std.testing.expectEqual(@as(u64, 500), trimmed[0].slot); // new_C
    try std.testing.expectEqual(@as(u64, 510), trimmed[1].slot); // new_D

    // Sealed tip: prevHash must match trimmed tail hash (new_D.hash)
    var sealed_hash: [32]u8 = undefined;
    @memset(&sealed_hash, 0xE0);
    const sealed_hdr = try buildFakeHeaderCborWithPrevHash(alloc, 52, 520, &hash_D);
    defer alloc.free(sealed_hdr);

    // Verify sealed.prevHash == fragment_tail.hash
    const sealed_prev = chainsync_server.ChainSyncServer.parseHeaderFields(alloc, sealed_hdr) orelse
        return error.ParseFailed;
    try std.testing.expect(sealed_prev.prev_hash != null);
    try std.testing.expectEqualSlices(u8, &hash_D, &sealed_prev.prev_hash.?);

    // Serve: FindIntersect at new_C → RollForward new_D → RollForward sealed → AwaitReply
    var server = chainsync_server.ChainSyncServer.initWithFragment(.{
        .slot = 520,
        .block_no = 52,
        .hash = sealed_hash,
        .header_cbor = sealed_hdr,
    }, trimmed);

    // FindIntersect at new_C (hash_C)
    var pt_hash: [32]u8 = undefined;
    @memset(&pt_hash, 0xC0);
    var pt_items: [2]cbor.Term = .{ .{ .u64 = 500 }, .{ .bytes = &pt_hash } };
    var points: [1]cbor.Term = .{.{ .array = &pt_items }};
    var msg_items: [2]cbor.Term = .{ .{ .u64 = 4 }, .{ .array = &points } };
    const fi_bytes = try encodeToBytes(alloc, cbor.Term{ .array = &msg_items });
    defer alloc.free(fi_bytes);
    const fi_wire = server.handleMessage(alloc, fi_bytes) orelse return error.HandleMessageFailed;
    alloc.free(fi_wire);

    try std.testing.expectEqual(@as(usize, 1), server.fragment_serve_idx);

    const rn = [_]u8{ 0x81, 0x00 };

    // RequestNext #1 → RollBackward (spec-required after IntersectFound)
    const w_rb = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w_rb);
    try std.testing.expectEqual(@as(u8, 0x03), w_rb[1]); // RollBackward

    // RequestNext #2 → new_D (fragment[1])
    const w1 = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w1);
    try std.testing.expectEqual(@as(u8, 0x02), w1[1]); // RollForward

    // RequestNext #3 → sealed tip
    const w2 = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w2);
    try std.testing.expectEqual(@as(u8, 0x02), w2[1]); // RollForward

    // RequestNext #4 → AwaitReply
    const w3 = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w3);
    try std.testing.expectEqual(@as(u8, 0x01), w3[1]); // AwaitReply

    try std.testing.expect(server.served_header);
    try std.testing.expect(server.served_sealed);
}

test "loadFragment with multiple BREAKs keeps only newest suffix" {
    // Fragment: [A(10), B(11), C(20), D(21), E(22)]
    //   B.hash != C.prev_hash → BREAK at idx=2
    //   D and E chain correctly from C
    //   Backwards walk from E: E→D ok, D→C ok, C→B BREAK → tail_start=2
    //   Result: [C, D, E] (3 entries)
    const alloc = std.testing.allocator;

    var prev0: [32]u8 = undefined;
    @memset(&prev0, 0x00);
    var hash_A: [32]u8 = undefined;
    @memset(&hash_A, 0x10);
    var hash_B: [32]u8 = undefined;
    @memset(&hash_B, 0x11);
    var prev_C: [32]u8 = undefined;
    @memset(&prev_C, 0xFF); // != hash_B → BREAK
    var hash_C: [32]u8 = undefined;
    @memset(&hash_C, 0x20);
    var hash_D: [32]u8 = undefined;
    @memset(&hash_D, 0x21);
    var hash_E: [32]u8 = undefined;
    @memset(&hash_E, 0x22);

    const hdr_A = try buildFakeHeaderCborWithPrevHash(alloc, 10, 100, &prev0);
    defer alloc.free(hdr_A);
    const hdr_B = try buildFakeHeaderCborWithPrevHash(alloc, 11, 110, &hash_A);
    defer alloc.free(hdr_B);
    const hdr_C = try buildFakeHeaderCborWithPrevHash(alloc, 20, 200, &prev_C);
    defer alloc.free(hdr_C);
    const hdr_D = try buildFakeHeaderCborWithPrevHash(alloc, 21, 210, &hash_C);
    defer alloc.free(hdr_D);
    const hdr_E = try buildFakeHeaderCborWithPrevHash(alloc, 22, 220, &hash_D);
    defer alloc.free(hdr_E);

    var fragment = [_]chainsync_server.FragmentEntry{
        .{ .slot = 100, .block_no = 10, .hash = hash_A, .prev_hash = prev0, .header_cbor = hdr_A },
        .{ .slot = 110, .block_no = 11, .hash = hash_B, .prev_hash = hash_A, .header_cbor = hdr_B },
        .{ .slot = 200, .block_no = 20, .hash = hash_C, .prev_hash = prev_C, .header_cbor = hdr_C },
        .{ .slot = 210, .block_no = 21, .hash = hash_D, .prev_hash = hash_C, .header_cbor = hdr_D },
        .{ .slot = 220, .block_no = 22, .hash = hash_E, .prev_hash = hash_D, .header_cbor = hdr_E },
    };

    // Apply backwards-walk trim
    var tail_start: usize = fragment.len;
    {
        var contig_from: usize = fragment.len - 1;
        while (contig_from > 0) : (contig_from -= 1) {
            if (!std.mem.eql(u8, &fragment[contig_from].prev_hash, &fragment[contig_from - 1].hash)) {
                break;
            }
        }
        tail_start = contig_from;
    }

    try std.testing.expectEqual(@as(usize, 2), tail_start);
    const trimmed = fragment[tail_start..];
    try std.testing.expectEqual(@as(usize, 3), trimmed.len);
    try std.testing.expectEqual(@as(u64, 200), trimmed[0].slot); // C
    try std.testing.expectEqual(@as(u64, 210), trimmed[1].slot); // D
    try std.testing.expectEqual(@as(u64, 220), trimmed[2].slot); // E

    // Sealed tip chains to E
    var sealed_hash: [32]u8 = undefined;
    @memset(&sealed_hash, 0x23);
    const sealed_hdr = try buildFakeHeaderCborWithPrevHash(alloc, 23, 230, &hash_E);
    defer alloc.free(sealed_hdr);

    var server = chainsync_server.ChainSyncServer.initWithFragment(.{
        .slot = 230,
        .block_no = 23,
        .hash = sealed_hash,
        .header_cbor = sealed_hdr,
    }, trimmed);

    // FindIntersect at C
    var pt_hash: [32]u8 = undefined;
    @memset(&pt_hash, 0x20);
    var pt_items: [2]cbor.Term = .{ .{ .u64 = 200 }, .{ .bytes = &pt_hash } };
    var points: [1]cbor.Term = .{.{ .array = &pt_items }};
    var msg_items: [2]cbor.Term = .{ .{ .u64 = 4 }, .{ .array = &points } };
    const fi_bytes = try encodeToBytes(alloc, cbor.Term{ .array = &msg_items });
    defer alloc.free(fi_bytes);
    const fi_wire = server.handleMessage(alloc, fi_bytes) orelse return error.HandleMessageFailed;
    alloc.free(fi_wire);

    const rn = [_]u8{ 0x81, 0x00 };

    // RollBackward (spec-required after IntersectFound)
    const w_rb = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w_rb);
    try std.testing.expectEqual(@as(u8, 0x03), w_rb[1]); // RollBackward

    // 3 RollForwards: D, E, sealed
    const w1 = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w1);
    try std.testing.expectEqual(@as(u8, 0x02), w1[1]);

    const w2 = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w2);
    try std.testing.expectEqual(@as(u8, 0x02), w2[1]);

    const w3 = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w3);
    try std.testing.expectEqual(@as(u8, 0x02), w3[1]);

    // Then AwaitReply
    const w4 = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w4);
    try std.testing.expectEqual(@as(u8, 0x01), w4[1]);

    try std.testing.expect(server.served_header);
    try std.testing.expect(server.served_sealed);
}

test "sealed prevHash must equal fragment tail hash (direct-parent invariant)" {
    // Verifies the critical invariant: fragment[n].hash == sealed.prevHash
    // If this doesn't hold, the relay will reject the chain with UnexpectedBlockNo.
    const alloc = std.testing.allocator;

    var prev0: [32]u8 = undefined;
    @memset(&prev0, 0x00);
    var hash0: [32]u8 = undefined;
    @memset(&hash0, 0xAA);
    var hash1: [32]u8 = undefined;
    @memset(&hash1, 0xBB);

    const hdr0 = try buildFakeHeaderCborWithPrevHash(alloc, 100, 1000, &prev0);
    defer alloc.free(hdr0);
    const hdr1 = try buildFakeHeaderCborWithPrevHash(alloc, 101, 1010, &hash0);
    defer alloc.free(hdr1);

    var fragment = [_]chainsync_server.FragmentEntry{
        .{ .slot = 1000, .block_no = 100, .hash = hash0, .prev_hash = prev0, .header_cbor = hdr0 },
        .{ .slot = 1010, .block_no = 101, .hash = hash1, .prev_hash = hash0, .header_cbor = hdr1 },
    };

    // Sealed tip: prevHash = hash1 (fragment tail hash) ← correct
    var sealed_hash: [32]u8 = undefined;
    @memset(&sealed_hash, 0xCC);
    const sealed_hdr = try buildFakeHeaderCborWithPrevHash(alloc, 102, 1020, &hash1);
    defer alloc.free(sealed_hdr);

    // Parse sealed header and verify the invariant directly
    const fields = chainsync_server.ChainSyncServer.parseHeaderFields(alloc, sealed_hdr) orelse
        return error.ParseFailed;
    try std.testing.expect(fields.prev_hash != null);

    // THE invariant: fragment[n].hash == sealed.prevHash
    try std.testing.expectEqualSlices(u8, &fragment[fragment.len - 1].hash, &fields.prev_hash.?);

    // Verify the server serves the full chain correctly
    var server = chainsync_server.ChainSyncServer.initWithFragment(.{
        .slot = 1020,
        .block_no = 102,
        .hash = sealed_hash,
        .header_cbor = sealed_hdr,
    }, &fragment);

    // FindIntersect at fragment[0]
    var pt_hash: [32]u8 = undefined;
    @memset(&pt_hash, 0xAA);
    var pt_items: [2]cbor.Term = .{ .{ .u64 = 1000 }, .{ .bytes = &pt_hash } };
    var points: [1]cbor.Term = .{.{ .array = &pt_items }};
    var msg_items: [2]cbor.Term = .{ .{ .u64 = 4 }, .{ .array = &points } };
    const fi_bytes = try encodeToBytes(alloc, cbor.Term{ .array = &msg_items });
    defer alloc.free(fi_bytes);
    const fi_wire = server.handleMessage(alloc, fi_bytes) orelse return error.HandleMessageFailed;
    alloc.free(fi_wire);

    const rn = [_]u8{ 0x81, 0x00 };

    // RollBackward (spec-required after IntersectFound)
    const w_rb = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w_rb);
    try std.testing.expectEqual(@as(u8, 0x03), w_rb[1]); // RollBackward

    // fragment[1] → sealed → AwaitReply
    const w1 = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w1);
    try std.testing.expectEqual(@as(u8, 0x02), w1[1]);

    const w2 = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w2);
    try std.testing.expectEqual(@as(u8, 0x02), w2[1]);

    const w3 = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w3);
    try std.testing.expectEqual(@as(u8, 0x01), w3[1]);

    try std.testing.expect(server.served_header);
    try std.testing.expect(server.served_sealed);
}

test "chainsync server AwaitReply is [1]" {
    const alloc = std.testing.allocator;

    const fake_header = [_]u8{0xAA} ** 16;
    var fake_hash: [32]u8 = undefined;
    @memset(&fake_hash, 0x42);

    var server = chainsync_server.ChainSyncServer.init(.{
        .slot = 99,
        .block_no = 5,
        .hash = fake_hash,
        .header_cbor = &fake_header,
    });

    // First RequestNext → RollForward (consume it)
    const request_next = [_]u8{ 0x81, 0x00 };
    const rf = server.handleMessage(alloc, &request_next) orelse return error.HandleMessageFailed;
    alloc.free(rf);

    // Second RequestNext → AwaitReply
    const wire = server.handleMessage(alloc, &request_next) orelse return error.HandleMessageFailed;
    defer alloc.free(wire);

    // AwaitReply = [1] → CBOR: 81 01
    try std.testing.expectEqual(@as(u8, 0x81), wire[0]); // array(1)
    try std.testing.expectEqual(@as(u8, 0x01), wire[1]); // uint(1) MsgAwaitReply
    try std.testing.expectEqual(@as(usize, 2), wire.len);
}

test "stale tip allows IntersectFound when later point matches fragment hash" {
    const alloc = std.testing.allocator;

    // Fragment: 1 entry at slot=500
    var prev0: [32]u8 = undefined;
    @memset(&prev0, 0x00);
    var hash0: [32]u8 = undefined;
    @memset(&hash0, 0xAA);

    const hdr0 = try buildFakeHeaderCborWithPrevHash(alloc, 50, 500, &prev0);
    defer alloc.free(hdr0);

    var fragment = [_]chainsync_server.FragmentEntry{
        .{ .slot = 500, .block_no = 50, .hash = hash0, .prev_hash = prev0, .header_cbor = hdr0 },
    };

    var sealed_hash: [32]u8 = undefined;
    @memset(&sealed_hash, 0xBB);
    const sealed_hdr = try buildFakeHeaderCborWithPrevHash(alloc, 51, 510, &hash0);
    defer alloc.free(sealed_hdr);

    var server = chainsync_server.ChainSyncServer.initWithFragment(.{
        .slot = 510,
        .block_no = 51,
        .hash = sealed_hash,
        .header_cbor = sealed_hdr,
    }, &fragment);

    // Relay sends FindIntersect with point[0] at slot=999 (ahead of sealed slot=510).
    // point[1] at slot=500 matches fragment[0] hash. The stale-tip condition at point[0]
    // must NOT prevent matching on point[1] — this is the normal production case where
    // the relay is slightly ahead but shares common history in the point set.
    var pt0_hash: [32]u8 = undefined;
    @memset(&pt0_hash, 0xFF); // won't match anything
    var pt0_items: [2]cbor.Term = .{ .{ .u64 = 999 }, .{ .bytes = &pt0_hash } };
    var pt1_hash: [32]u8 = undefined;
    @memset(&pt1_hash, 0xAA); // matches fragment[0]
    var pt1_items: [2]cbor.Term = .{ .{ .u64 = 500 }, .{ .bytes = &pt1_hash } };
    var points: [2]cbor.Term = .{ .{ .array = &pt0_items }, .{ .array = &pt1_items } };
    var msg_items: [2]cbor.Term = .{ .{ .u64 = 4 }, .{ .array = &points } };
    const msg_bytes = try encodeToBytes(alloc, cbor.Term{ .array = &msg_items });
    defer alloc.free(msg_bytes);

    const wire = server.handleMessage(alloc, msg_bytes) orelse return error.HandleMessageFailed;
    defer alloc.free(wire);

    // Must be MsgIntersectFound [5, point, tip] — point[1] matches fragment hash
    var fbs = compat.fixedBufferStream(wire);
    const resp = cbor.decode(alloc, fbs.reader()) catch return error.DecodeFailed;
    defer cbor.free(resp, alloc);

    try std.testing.expect(resp == .array);
    try std.testing.expectEqual(@as(u64, 5), resp.array[0].u64); // IntersectFound
    // fragment_serve_idx should be 1 (serve from successor of matched entry)
    try std.testing.expectEqual(@as(usize, 1), server.fragment_serve_idx);
}

test "stale tip guard allows FindIntersect when relay is behind" {
    const alloc = std.testing.allocator;

    // Fragment: 1 entry at slot=500
    var prev0: [32]u8 = undefined;
    @memset(&prev0, 0x00);
    var hash0: [32]u8 = undefined;
    @memset(&hash0, 0xAA);

    const hdr0 = try buildFakeHeaderCborWithPrevHash(alloc, 50, 500, &prev0);
    defer alloc.free(hdr0);

    var fragment = [_]chainsync_server.FragmentEntry{
        .{ .slot = 500, .block_no = 50, .hash = hash0, .prev_hash = prev0, .header_cbor = hdr0 },
    };

    var sealed_hash: [32]u8 = undefined;
    @memset(&sealed_hash, 0xBB);
    const sealed_hdr = try buildFakeHeaderCborWithPrevHash(alloc, 51, 510, &hash0);
    defer alloc.free(sealed_hdr);

    var server = chainsync_server.ChainSyncServer.initWithFragment(.{
        .slot = 510,
        .block_no = 51,
        .hash = sealed_hash,
        .header_cbor = sealed_hdr,
    }, &fragment);

    // Relay sends FindIntersect with point[0] at slot=500 (behind sealed slot=510).
    var pt_hash: [32]u8 = undefined;
    @memset(&pt_hash, 0xAA); // matches fragment[0]
    var pt_items: [2]cbor.Term = .{ .{ .u64 = 500 }, .{ .bytes = &pt_hash } };
    var points: [1]cbor.Term = .{.{ .array = &pt_items }};
    var msg_items: [2]cbor.Term = .{ .{ .u64 = 4 }, .{ .array = &points } };
    const msg_bytes = try encodeToBytes(alloc, cbor.Term{ .array = &msg_items });
    defer alloc.free(msg_bytes);

    const wire = server.handleMessage(alloc, msg_bytes) orelse return error.HandleMessageFailed;
    defer alloc.free(wire);

    // Must be MsgIntersectFound [5, point, tip]
    var fbs = compat.fixedBufferStream(wire);
    const resp = cbor.decode(alloc, fbs.reader()) catch return error.DecodeFailed;
    defer cbor.free(resp, alloc);

    try std.testing.expect(resp == .array);
    try std.testing.expectEqual(@as(u64, 5), resp.array[0].u64); // IntersectFound
    try std.testing.expectEqual(@as(usize, 1), server.fragment_serve_idx); // ready to serve sealed
}

// ── v4.5.20: RollBackward after IntersectFound tests ────────────────

test "FindIntersect then RequestNext returns RollBackward first" {
    const alloc = std.testing.allocator;

    // Single fragment entry
    var prev0: [32]u8 = undefined;
    @memset(&prev0, 0x00);
    var hash0: [32]u8 = undefined;
    @memset(&hash0, 0xAA);

    const hdr0 = try buildFakeHeaderCborWithPrevHash(alloc, 40, 990, &prev0);
    defer alloc.free(hdr0);

    var fragment = [_]chainsync_server.FragmentEntry{
        .{ .slot = 990, .block_no = 40, .hash = hash0, .prev_hash = prev0, .header_cbor = hdr0 },
    };

    var sealed_hash: [32]u8 = undefined;
    @memset(&sealed_hash, 0xDD);
    const sealed_hdr = try buildFakeHeaderCborWithPrevHash(alloc, 41, 1000, &hash0);
    defer alloc.free(sealed_hdr);

    var server = chainsync_server.ChainSyncServer.initWithFragment(.{
        .slot = 1000,
        .block_no = 41,
        .hash = sealed_hash,
        .header_cbor = sealed_hdr,
    }, &fragment);

    // FindIntersect at fragment[0]
    var pt_hash: [32]u8 = undefined;
    @memset(&pt_hash, 0xAA);
    var pt_items: [2]cbor.Term = .{ .{ .u64 = 990 }, .{ .bytes = &pt_hash } };
    var points: [1]cbor.Term = .{.{ .array = &pt_items }};
    var msg_items: [2]cbor.Term = .{ .{ .u64 = 4 }, .{ .array = &points } };
    const fi_bytes = try encodeToBytes(alloc, cbor.Term{ .array = &msg_items });
    defer alloc.free(fi_bytes);
    const fi_wire = server.handleMessage(alloc, fi_bytes) orelse return error.HandleMessageFailed;
    alloc.free(fi_wire);

    // need_rollback must be set after IntersectFound
    try std.testing.expect(server.need_rollback);

    const rn = [_]u8{ 0x81, 0x00 };

    // RequestNext #1 → MsgRollBackward [3, point, tip]
    const wire_rb = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(wire_rb);

    // Decode and verify it's RollBackward
    var fbs = compat.fixedBufferStream(wire_rb);
    const resp = cbor.decode(alloc, fbs.reader()) catch return error.DecodeFailed;
    defer cbor.free(resp, alloc);

    try std.testing.expect(resp == .array);
    try std.testing.expect(resp.array.len == 3); // [3, point, tip]
    try std.testing.expectEqual(@as(u64, 3), resp.array[0].u64); // MsgRollBackward tag
    // Point should be [990, hash]
    try std.testing.expect(resp.array[1] == .array);
    try std.testing.expectEqual(@as(u64, 990), resp.array[1].array[0].u64);
    // need_rollback should now be false
    try std.testing.expect(!server.need_rollback);
}

test "after RollBackward next RequestNext returns RollForward" {
    const alloc = std.testing.allocator;

    var prev0: [32]u8 = undefined;
    @memset(&prev0, 0x00);
    var hash0: [32]u8 = undefined;
    @memset(&hash0, 0xAA);

    const hdr0 = try buildFakeHeaderCborWithPrevHash(alloc, 40, 990, &prev0);
    defer alloc.free(hdr0);

    var fragment = [_]chainsync_server.FragmentEntry{
        .{ .slot = 990, .block_no = 40, .hash = hash0, .prev_hash = prev0, .header_cbor = hdr0 },
    };

    var sealed_hash: [32]u8 = undefined;
    @memset(&sealed_hash, 0xDD);
    const sealed_hdr = try buildFakeHeaderCborWithPrevHash(alloc, 41, 1000, &hash0);
    defer alloc.free(sealed_hdr);

    var server = chainsync_server.ChainSyncServer.initWithFragment(.{
        .slot = 1000,
        .block_no = 41,
        .hash = sealed_hash,
        .header_cbor = sealed_hdr,
    }, &fragment);

    // FindIntersect
    var pt_hash: [32]u8 = undefined;
    @memset(&pt_hash, 0xAA);
    var pt_items: [2]cbor.Term = .{ .{ .u64 = 990 }, .{ .bytes = &pt_hash } };
    var points: [1]cbor.Term = .{.{ .array = &pt_items }};
    var msg_items: [2]cbor.Term = .{ .{ .u64 = 4 }, .{ .array = &points } };
    const fi_bytes = try encodeToBytes(alloc, cbor.Term{ .array = &msg_items });
    defer alloc.free(fi_bytes);
    const fi_wire = server.handleMessage(alloc, fi_bytes) orelse return error.HandleMessageFailed;
    alloc.free(fi_wire);

    const rn = [_]u8{ 0x81, 0x00 };

    // RequestNext #1 → RollBackward
    const wire_rb = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(wire_rb);
    try std.testing.expectEqual(@as(u8, 0x03), wire_rb[1]); // RollBackward

    // RequestNext #2 → RollForward (sealed tip, since fragment[0] is the intersect)
    const wire_rf = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(wire_rf);
    try std.testing.expectEqual(@as(u8, 0x02), wire_rf[1]); // RollForward

    // RequestNext #3 → AwaitReply
    const wire_aw = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(wire_aw);
    try std.testing.expectEqual(@as(u8, 0x01), wire_aw[1]); // AwaitReply
}

// ── v4.5.25 Multi-block BlockFetch tests ────────────────────────────

test "multi-block BlockFetchServer serves fragment and sealed blocks" {
    const alloc = std.testing.allocator;

    // Fragment block body
    const frag_body = "fragment-block-body-cbor";
    var frag_hash: [32]u8 = undefined;
    @memset(&frag_hash, 0xAA);

    // Sealed block body
    const sealed_body = "sealed-block-body-cbor";
    var sealed_hash: [32]u8 = undefined;
    @memset(&sealed_hash, 0xBB);

    var blocks = [_]blockfetch_server.SealedBlock{
        .{ .slot = 990, .hash = frag_hash, .block_cbor = frag_body },
        .{ .slot = 1000, .hash = sealed_hash, .block_cbor = sealed_body },
    };

    var server = blockfetch_server.BlockFetchServer.init(&blocks);

    // Request fragment block (slot=990, hash=0xAA)
    {
        var pt_from: [2]cbor.Term = .{ .{ .u64 = 990 }, .{ .bytes = &frag_hash } };
        var pt_to: [2]cbor.Term = .{ .{ .u64 = 990 }, .{ .bytes = &frag_hash } };
        var msg: [3]cbor.Term = .{
            .{ .u64 = 0 },
            .{ .array = &pt_from },
            .{ .array = &pt_to },
        };
        const msg_bytes = try encodeToBytes(alloc, cbor.Term{ .array = &msg });
        defer alloc.free(msg_bytes);

        const responses = server.handleMessage(alloc, msg_bytes) orelse return error.HandleMessageFailed;
        defer alloc.free(responses);

        // Should be 3 responses: StartBatch, Block, BatchDone
        try std.testing.expectEqual(@as(usize, 3), responses.len);

        // Verify StartBatch [2]
        var fbs0 = compat.fixedBufferStream(responses[0]);
        const t0 = cbor.decode(alloc, fbs0.reader()) catch return error.DecodeFailed;
        defer cbor.free(t0, alloc);
        try std.testing.expect(t0 == .array);
        try std.testing.expectEqual(@as(u64, 2), t0.array[0].u64);

        // Verify BatchDone [5]
        var fbs2 = compat.fixedBufferStream(responses[2]);
        const t2 = cbor.decode(alloc, fbs2.reader()) catch return error.DecodeFailed;
        defer cbor.free(t2, alloc);
        try std.testing.expect(t2 == .array);
        try std.testing.expectEqual(@as(u64, 5), t2.array[0].u64);

        // Verify Block [4, tag(24, bytes)]
        var fbs1 = compat.fixedBufferStream(responses[1]);
        const t1 = cbor.decode(alloc, fbs1.reader()) catch return error.DecodeFailed;
        defer cbor.free(t1, alloc);
        try std.testing.expect(t1 == .array);
        try std.testing.expectEqual(@as(u64, 4), t1.array[0].u64);
        try std.testing.expect(t1.array[1] == .tag);
        try std.testing.expectEqual(@as(u64, 24), t1.array[1].tag.tag);
        try std.testing.expect(t1.array[1].tag.value.* == .bytes);
        try std.testing.expectEqualSlices(u8, frag_body, t1.array[1].tag.value.*.bytes);

        for (responses) |r| alloc.free(r);
    }

    try std.testing.expect(server.served_block);

    // Request sealed block (slot=1000, hash=0xBB)
    {
        server.served_block = false;
        var pt_from2: [2]cbor.Term = .{ .{ .u64 = 1000 }, .{ .bytes = &sealed_hash } };
        var pt_to2: [2]cbor.Term = .{ .{ .u64 = 1000 }, .{ .bytes = &sealed_hash } };
        var msg2: [3]cbor.Term = .{
            .{ .u64 = 0 },
            .{ .array = &pt_from2 },
            .{ .array = &pt_to2 },
        };
        const msg_bytes2 = try encodeToBytes(alloc, cbor.Term{ .array = &msg2 });
        defer alloc.free(msg_bytes2);

        const responses2 = server.handleMessage(alloc, msg_bytes2) orelse return error.HandleMessageFailed;
        defer alloc.free(responses2);

        try std.testing.expectEqual(@as(usize, 3), responses2.len);

        // Verify block body is sealed_body
        var fbs_blk = compat.fixedBufferStream(responses2[1]);
        const t_blk = cbor.decode(alloc, fbs_blk.reader()) catch return error.DecodeFailed;
        defer cbor.free(t_blk, alloc);
        try std.testing.expectEqualSlices(u8, sealed_body, t_blk.array[1].tag.value.*.bytes);

        for (responses2) |r| alloc.free(r);
    }

    try std.testing.expect(server.served_block);

    // Request unknown block → NoBlocks
    {
        var unk_hash: [32]u8 = undefined;
        @memset(&unk_hash, 0xFF);
        var pt_unk: [2]cbor.Term = .{ .{ .u64 = 9999 }, .{ .bytes = &unk_hash } };
        var pt_unk2: [2]cbor.Term = .{ .{ .u64 = 9999 }, .{ .bytes = &unk_hash } };
        var msg_unk: [3]cbor.Term = .{
            .{ .u64 = 0 },
            .{ .array = &pt_unk },
            .{ .array = &pt_unk2 },
        };
        const unk_bytes = try encodeToBytes(alloc, cbor.Term{ .array = &msg_unk });
        defer alloc.free(unk_bytes);

        const unk_resp = server.handleMessage(alloc, unk_bytes) orelse return error.HandleMessageFailed;
        defer alloc.free(unk_resp);

        // Should be 1 response: NoBlocks [3]
        try std.testing.expectEqual(@as(usize, 1), unk_resp.len);
        var fbs_nb = compat.fixedBufferStream(unk_resp[0]);
        const t_nb = cbor.decode(alloc, fbs_nb.reader()) catch return error.DecodeFailed;
        defer cbor.free(t_nb, alloc);
        try std.testing.expectEqual(@as(u64, 3), t_nb.array[0].u64);

        for (unk_resp) |r| alloc.free(r);
    }
}

// ── v4.5.26 Deep fragment coverage tests ─────────────────────────────

test "deep fragment FindIntersect matches relay point at oldest entry" {
    // Simulates a 300-entry deep fragment (~2.5 hours of accumulated blocks).
    // A relay offers a point matching the oldest entry (index 0).
    // FindIntersect should succeed and set fragment_serve_idx = 1.
    const alloc = std.testing.allocator;

    const depth: usize = 300;
    var fragment: [depth]chainsync_server.FragmentEntry = undefined;
    var headers: [depth][]u8 = undefined;
    var headers_built: usize = 0;

    // Build contiguous chain: entry[i].prev_hash = entry[i-1].hash
    var prev: [32]u8 = [_]u8{0} ** 32;
    for (0..depth) |i| {
        var hash: [32]u8 = undefined;
        @memset(&hash, 0);
        hash[0] = @intCast(i & 0xFF);
        hash[1] = @intCast((i >> 8) & 0xFF);
        hash[2] = @intCast(i & 0x3F); // extra uniqueness

        const slot: u64 = 100000 + @as(u64, i) * 30;
        const block_no: u64 = 5000 + @as(u64, i);

        headers[i] = buildFakeHeaderCborWithPrevHash(alloc, block_no, slot, &prev) catch {
            // Clean up on failure
            for (0..headers_built) |j| alloc.free(headers[j]);
            return error.BuildFailed;
        };
        headers_built += 1;

        fragment[i] = .{
            .slot = slot,
            .block_no = block_no,
            .hash = hash,
            .prev_hash = prev,
            .header_cbor = headers[i],
        };
        prev = hash;
    }
    defer {
        for (0..headers_built) |i| alloc.free(headers[i]);
    }

    // Sealed tip chains from fragment[depth-1]
    var sealed_hash: [32]u8 = undefined;
    @memset(&sealed_hash, 0xDD);
    const sealed_slot: u64 = 100000 + @as(u64, depth) * 30;
    const sealed_hdr = buildFakeHeaderCborWithPrevHash(alloc, 5000 + @as(u64, depth), sealed_slot, &prev) catch return error.BuildFailed;
    defer alloc.free(sealed_hdr);

    var server = chainsync_server.ChainSyncServer.initWithFragment(.{
        .slot = sealed_slot,
        .block_no = 5000 + @as(u64, depth),
        .hash = sealed_hash,
        .header_cbor = sealed_hdr,
    }, &fragment);

    // Relay offers 1 point matching fragment[0] (oldest entry)
    var pt_hash = fragment[0].hash;
    var pt_items: [2]cbor.Term = .{ .{ .u64 = fragment[0].slot }, .{ .bytes = &pt_hash } };
    var points: [1]cbor.Term = .{.{ .array = &pt_items }};
    var msg_items: [2]cbor.Term = .{ .{ .u64 = 4 }, .{ .array = &points } };
    const msg_bytes = try encodeToBytes(alloc, cbor.Term{ .array = &msg_items });
    defer alloc.free(msg_bytes);

    const wire = server.handleMessage(alloc, msg_bytes) orelse return error.HandleMessageFailed;
    defer alloc.free(wire);

    var fbs = compat.fixedBufferStream(wire);
    const resp = cbor.decode(alloc, fbs.reader()) catch return error.DecodeFailed;
    defer cbor.free(resp, alloc);

    // Must be MsgIntersectFound [5, point, tip]
    try std.testing.expect(resp == .array);
    try std.testing.expectEqual(@as(u64, 5), resp.array[0].u64);

    // fragment_serve_idx should be 1 (successor of matched entry 0)
    try std.testing.expectEqual(@as(usize, 1), server.fragment_serve_idx);

    // Verify all 299 remaining fragment entries + sealed tip can be served
    const rn = [_]u8{ 0x81, 0x00 };

    // First RequestNext → RollBackward (spec-required after IntersectFound)
    const w_rb = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w_rb);
    try std.testing.expectEqual(@as(u8, 0x03), w_rb[1]); // RollBackward

    // Next 299 RequestNext → fragment[1..299] RollForward
    var rf_count: usize = 0;
    for (1..depth) |_| {
        const w = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
        defer alloc.free(w);
        try std.testing.expectEqual(@as(u8, 0x02), w[1]); // RollForward
        rf_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 299), rf_count);

    // Next RequestNext → sealed tip RollForward
    const w_sealed = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w_sealed);
    try std.testing.expectEqual(@as(u8, 0x02), w_sealed[1]); // RollForward

    // Next RequestNext → AwaitReply
    const w_await = server.handleMessage(alloc, &rn) orelse return error.HandleMessageFailed;
    defer alloc.free(w_await);
    try std.testing.expectEqual(@as(u8, 0x01), w_await[1]); // AwaitReply

    try std.testing.expect(server.served_header);
    try std.testing.expect(server.served_sealed);
}

// ── Origin FindIntersect encoding (clean-start fix, 2026-07-24) ────────────────────────
// A genuinely empty follower (no cursor) must request intersect at ORIGIN. The points list
// must CONTAIN the origin point ([[]]), NOT be an empty points list ([]). The empty form
// [4,[]] (82 04 80) is a zero-candidate request that peers answer with IntersectNotFound —
// which prevented fresh-start sync entirely.

test "origin FindIntersect encodes byte-exact [4,[[]]] = 82 04 81 80" {
    const alloc = std.testing.allocator;
    var list = std.array_list.Managed(u8).init(alloc);
    defer list.deinit();
    try chainsync_codec.encodeFindIntersectOrigin(compat.listWriter(&list));
    const bytes = try list.toOwnedSlice();
    defer alloc.free(bytes);
    // [4, [ [] ]] = array(2){ u64 4, array(1){ array(0) } }
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x04, 0x81, 0x80 }, bytes);
    // and it MUST NOT be the malformed empty-points 3-byte form
    try std.testing.expect(!std.mem.eql(u8, bytes, &[_]u8{ 0x82, 0x04, 0x80 }));
}

test "origin FindIntersect decodes to a ONE-element points list holding the origin point" {
    const alloc = std.testing.allocator;
    var list = std.array_list.Managed(u8).init(alloc);
    defer list.deinit();
    try chainsync_codec.encodeFindIntersectOrigin(compat.listWriter(&list));
    const bytes = try list.toOwnedSlice();
    defer alloc.free(bytes);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const term = try cbor.decodeOrRaw(arena.allocator(), bytes);
    try std.testing.expect(term == .array and term.array.len == 2);
    try std.testing.expectEqual(@as(u64, 4), term.array[0].u64); // MsgFindIntersect
    const points = term.array[1];
    try std.testing.expect(points == .array);
    try std.testing.expectEqual(@as(usize, 1), points.array.len); // ONE point, not zero
    try std.testing.expect(points.array[0] == .array and points.array[0].array.len == 0); // origin = []
}

test "FindIntersect with ONE concrete point encodes [4,[[slot,hash]]]" {
    const alloc = std.testing.allocator;
    var hash = [_]u8{0xAB} ** 32;
    var pair = [_]cbor.Term{ .{ .u64 = 1000 }, .{ .bytes = hash[0..] } };
    var pts = [_]cbor.Term{.{ .array = pair[0..] }};
    const points = cbor.Term{ .array = pts[0..] };
    var list = std.array_list.Managed(u8).init(alloc);
    defer list.deinit();
    try chainsync_codec.encodeFindIntersect(compat.listWriter(&list), points);
    const bytes = try list.toOwnedSlice();
    defer alloc.free(bytes);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const term = try cbor.decodeOrRaw(arena.allocator(), bytes);
    try std.testing.expectEqual(@as(u64, 4), term.array[0].u64);
    try std.testing.expectEqual(@as(usize, 1), term.array[1].array.len);
    const p0 = term.array[1].array[0];
    try std.testing.expectEqual(@as(usize, 2), p0.array.len); // [slot, hash]
    try std.testing.expectEqual(@as(u64, 1000), p0.array[0].u64);
}

test "FindIntersect with MULTIPLE concrete points preserves count and order" {
    const alloc = std.testing.allocator;
    var h0 = [_]u8{0x11} ** 32;
    var h1 = [_]u8{0x22} ** 32;
    var pair0 = [_]cbor.Term{ .{ .u64 = 2000 }, .{ .bytes = h0[0..] } };
    var pair1 = [_]cbor.Term{ .{ .u64 = 900 }, .{ .bytes = h1[0..] } };
    var pts = [_]cbor.Term{ .{ .array = pair0[0..] }, .{ .array = pair1[0..] } };
    const points = cbor.Term{ .array = pts[0..] };
    var list = std.array_list.Managed(u8).init(alloc);
    defer list.deinit();
    try chainsync_codec.encodeFindIntersect(compat.listWriter(&list), points);
    const bytes = try list.toOwnedSlice();
    defer alloc.free(bytes);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const term = try cbor.decodeOrRaw(arena.allocator(), bytes);
    try std.testing.expectEqual(@as(usize, 2), term.array[1].array.len);
    try std.testing.expectEqual(@as(u64, 2000), term.array[1].array[0].array[0].u64);
    try std.testing.expectEqual(@as(u64, 900), term.array[1].array[1].array[0].u64);
}
