//! NET-RUNTIME AUDIT regression — fragmented socket-read reassembly for the
//! blockfetch_server + propagation_server serve loop (0.16).
//!
//! AUDIT FINDING (no code defect): every socket read in the propagation serve
//! loop flows through `StreamBtImpl.readAtMost` -> raw `std.posix.read(fd, out)`
//! (net/propagation_server.zig:2462). A raw read(2) returns at most `out.len`
//! bytes and leaves the surplus in the KERNEL socket receive buffer for the next
//! read — there is no userspace buffer that could discard over-read bytes. The
//! mux layer (`mux_bearer.recvSegment`) reads a length-prefixed message in two
//! phases (8-byte header, then `hdr.len` payload) by looping `bt.readAtMost`
//! inside `readExactOrNull`. Correctness therefore hinges on `readAtMost`
//! preserving bytes across calls — which raw read(2) does.
//!
//! This test pins that invariant. It drives the REAL `mux_bearer.recvSegment`
//! (the exact function the serve loop and handshake call) through a transport
//! that faithfully models kernel read(2) semantics: a single growable byte
//! reservoir, `readAtMost` hands back at most `chunk` bytes per call and retains
//! the rest. We deliver a length-prefixed segment in 1-byte chunks and in
//! adversarial odd-sized splits and assert the full header+payload reassembles
//! byte-for-byte with zero loss. A regression to a per-call non-persistent
//! reader (e.g. a fresh `NetStream.Reader.init` whose 4096-byte buffer is
//! dropped each call) would surface here as truncated/garbled payloads.
//!
//! Author: cryptoleo79.

const std = @import("std");
const ByteTransport = @import("net/transport/byte_transport.zig").ByteTransport;
const ByteTransportVTable = @import("net/transport/byte_transport.zig").ByteTransportVTable;
const mux_bearer = @import("net/muxwire/mux_bearer.zig");
const mux_header = @import("net/muxwire/mux_header.zig");

/// Transport that models a kernel socket receive buffer for reads: all bytes
/// pushed via `feed` accumulate in `reservoir`; `readAtMost` returns at most
/// `chunk` bytes per call (and never more than requested), advancing a read
/// cursor — surplus bytes survive to the next call, exactly like read(2).
const FragmentingTransport = struct {
    alloc: std.mem.Allocator,
    reservoir: std.array_list.Managed(u8),
    read_pos: usize = 0,
    chunk: usize, // max bytes handed back per readAtMost (1 = byte-at-a-time)

    fn init(alloc: std.mem.Allocator, chunk: usize) FragmentingTransport {
        return .{
            .alloc = alloc,
            .reservoir = std.array_list.Managed(u8).init(alloc),
            .chunk = chunk,
        };
    }

    fn feed(self: *FragmentingTransport, bytes: []const u8) !void {
        try self.reservoir.appendSlice(bytes);
    }

    fn writeAll(ctx: *anyopaque, data: []const u8) anyerror!void {
        _ = ctx;
        _ = data; // serve-loop sends are not under test here
    }

    fn readAtMost(ctx: *anyopaque, out: []u8) anyerror!usize {
        const self: *FragmentingTransport = @ptrCast(@alignCast(ctx));
        const available = self.reservoir.items.len - self.read_pos;
        if (available == 0) return 0; // EOF, as a drained socket would report
        const n = @min(@min(out.len, self.chunk), available);
        @memcpy(out[0..n], self.reservoir.items[self.read_pos .. self.read_pos + n]);
        self.read_pos += n;
        return n;
    }

    fn deinit(ctx: *anyopaque) void {
        const self: *FragmentingTransport = @ptrCast(@alignCast(ctx));
        self.reservoir.deinit();
    }

    const vtable = ByteTransportVTable{
        .writeAll = writeAll,
        .readAtMost = readAtMost,
        .deinit = deinit,
    };

    fn transport(self: *FragmentingTransport) ByteTransport {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

/// Encode an on-wire mux segment (8-byte header + payload), as `sendSegment`
/// would put it on the socket, so we can feed the exact bytes back in fragments.
fn encodeSegment(buf_list: *std.array_list.Managed(u8), proto: u16, payload: []const u8) !void {
    var header_buf: [8]u8 = undefined;
    try mux_header.encode(.{
        .tx_time = 0,
        .dir = .initiator,
        .proto = proto,
        .len = @intCast(payload.len),
    }, &header_buf);
    try buf_list.appendSlice(&header_buf);
    try buf_list.appendSlice(payload);
}

fn runReassembly(alloc: std.mem.Allocator, payload: []const u8, proto: u16, chunk: usize) !void {
    // Build the wire bytes once.
    var wire = std.array_list.Managed(u8).init(alloc);
    defer wire.deinit();
    try encodeSegment(&wire, proto, payload);

    // Feed them through a transport that hands them out in `chunk`-sized pieces.
    var ft = FragmentingTransport.init(alloc, chunk);
    var bt = ft.transport();
    defer bt.deinit();
    try ft.feed(wire.items);

    // Drive the REAL serve-loop recv path.
    const seg = (try mux_bearer.recvSegment(alloc, &bt)) orelse
        return error.UnexpectedNullSegment;
    defer alloc.free(seg.payload);

    try std.testing.expectEqual(proto, seg.hdr.proto);
    try std.testing.expectEqual(@as(u16, @intCast(payload.len)), seg.hdr.len);
    try std.testing.expectEqualSlices(u8, payload, seg.payload);
}

test "serve-loop recvSegment reassembles a 1-byte-fragmented length-prefixed message" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // A representative BlockFetch MsgRequestRange-ish payload (content is opaque
    // to the mux layer; only exact reassembly matters).
    const payload = "\x83\x00\x82\x1a\x06\xc9\x3a\x0d\x58\x20" ++
        ("\xab" ** 32) ++ "\x82\x1a\x06\xc9\x3a\x0d\x58\x20" ++ ("\xcd" ** 32);
    // chunk = 1 -> the segment arrives one byte per read, the worst case for any
    // reader that fails to drain/preserve across calls.
    try runReassembly(alloc, payload, 3, 1);
}

test "serve-loop recvSegment reassembles across odd split-chunk sizes" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const payload = "\x84\x04\xd8\x18\x58\x40" ++ ("\x5a" ** 64);
    // Sweep chunk sizes that straddle the 8-byte header/payload boundary and
    // land mid-payload, so a non-persistent reader would lose the tail.
    const chunks = [_]usize{ 2, 3, 5, 7, 8, 9, 13, 64, 4096 };
    for (chunks) |c| {
        try runReassembly(alloc, payload, 3, c);
    }
}

test "serve-loop recvSegment reassembles a large payload split mid-body" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // 4096-byte body forces multiple readAtMost iterations inside readExactOrNull
    // even at large chunk sizes — proves the loop keeps consuming the kernel
    // buffer until the full declared length is assembled.
    var payload: [4096]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast(i & 0xff);

    const chunks = [_]usize{ 1, 17, 511, 1000, 1500, 4096 };
    for (chunks) |c| {
        try runReassembly(alloc, &payload, 3, c);
    }
}

test "serve-loop recvSegment reassembles two back-to-back segments without bleed" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Two segments delivered as one contiguous byte stream in 1-byte chunks.
    // The first recvSegment must consume EXACTLY its header+payload and leave
    // the second segment intact for the next call (this is the over-read /
    // truncation hazard the audit targets: a per-call reader that grabbed more
    // than the first segment would corrupt or lose the second).
    const p0 = "first-segment-payload";
    const p1 = "second-segment-payload-which-is-a-bit-longer";

    var wire = std.array_list.Managed(u8).init(alloc);
    defer wire.deinit();
    try encodeSegment(&wire, 3, p0);
    try encodeSegment(&wire, 7, p1);

    var ft = FragmentingTransport.init(alloc, 1); // byte-at-a-time
    var bt = ft.transport();
    defer bt.deinit();
    try ft.feed(wire.items);

    const seg0 = (try mux_bearer.recvSegment(alloc, &bt)) orelse return error.UnexpectedNullSegment;
    defer alloc.free(seg0.payload);
    try std.testing.expectEqual(@as(u16, 3), seg0.hdr.proto);
    try std.testing.expectEqualStrings(p0, seg0.payload);

    const seg1 = (try mux_bearer.recvSegment(alloc, &bt)) orelse return error.UnexpectedNullSegment;
    defer alloc.free(seg1.payload);
    try std.testing.expectEqual(@as(u16, 7), seg1.hdr.proto);
    try std.testing.expectEqualStrings(p1, seg1.payload);

    // Stream fully drained -> next recv reports clean EOF (null), no phantom bytes.
    try std.testing.expect((try mux_bearer.recvSegment(alloc, &bt)) == null);
}
