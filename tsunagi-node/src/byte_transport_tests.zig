const std = @import("std");
const compat = @import("compat");
const mem_bt = @import("net/transport/memory_byte_transport.zig");
const ByteTransport = @import("net/transport/byte_transport.zig").ByteTransport;
const ByteTransportVTable = @import("net/transport/byte_transport.zig").ByteTransportVTable;
const mux_bearer = @import("net/muxwire/mux_bearer.zig");
const mux_header = @import("net/muxwire/mux_header.zig");

test "memory byte transport roundtrip" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var t: ByteTransport = mem_bt.init(alloc, 64);
    defer t.deinit();

    const msg = "hello-tsunagi";
    try t.writeAll(msg);

    var buf: [32]u8 = undefined;
    const n = try t.readAtMost(&buf);

    try std.testing.expectEqual(@as(usize, msg.len), n);
    try std.testing.expectEqualStrings(msg, buf[0..n]);
}

test "memory byte transport enforces capacity" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var t: ByteTransport = mem_bt.init(alloc, 8);
    defer t.deinit();

    // try to overflow
    const big = "0123456789abcdef";
    try std.testing.expectError(error.NoSpace, t.writeAll(big));
}

// ── fragmented-stream regression for the chainsync/miniproto read path ─────────
// Models the exact 0.16 socket hazard: the kernel hands the protocol layer FEWER
// bytes than it asked for (or, worse, bytes beyond the current request that a
// fresh per-call reader would discard). The chainsync follower, peer_probe, and
// NTC paths all read a length-prefixed mux segment as TWO logical reads — an
// 8-byte header, then `hdr.len` body bytes — via mux_bearer.recvSegment*, which
// loops ByteTransport.readAtMost to fill each exact-size buffer. This transport
// returns at most `chunk` bytes per readAtMost call to force fragmentation, so a
// real mux segment must reassemble across many readAtMost calls with no loss.
const FragmentTransport = struct {
    data: []const u8,
    pos: usize = 0,
    chunk: usize, // max bytes returned per readAtMost (1 = byte-at-a-time)

    fn writeAll(ctx: *anyopaque, data: []const u8) anyerror!void {
        _ = ctx;
        _ = data;
        // Not exercised by the recv path; reject so a regression is loud.
        return error.NotImplemented;
    }

    fn readAtMost(ctx: *anyopaque, out: []u8) anyerror!usize {
        const self: *FragmentTransport = @ptrCast(@alignCast(ctx));
        if (self.pos >= self.data.len) return 0; // EOF
        const remaining = self.data.len - self.pos;
        const n = @min(@min(self.chunk, out.len), remaining);
        @memcpy(out[0..n], self.data[self.pos .. self.pos + n]);
        self.pos += n;
        return n;
    }

    fn deinit(ctx: *anyopaque) void {
        _ = ctx;
    }

    const vtable = ByteTransportVTable{
        .writeAll = writeAll,
        .readAtMost = readAtMost,
        .deinit = deinit,
    };

    fn transport(self: *FragmentTransport) ByteTransport {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

fn buildSegment(alloc: std.mem.Allocator, proto: u16, payload: []const u8) ![]u8 {
    var hdr: [8]u8 = undefined;
    try mux_header.encode(.{
        .tx_time = 0,
        .dir = .responder,
        .proto = proto,
        .len = @intCast(payload.len),
    }, &hdr);
    var out = try alloc.alloc(u8, 8 + payload.len);
    @memcpy(out[0..8], &hdr);
    @memcpy(out[8..], payload);
    return out;
}

test "fragmented mux segment reassembles byte-at-a-time" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const payload = "tsunagi-chainsync-rollforward-body-0123456789";
    const wire = try buildSegment(alloc, 2, payload);
    defer alloc.free(wire);

    var ft = FragmentTransport{ .data = wire, .chunk = 1 }; // 1 byte per read
    var bt = ft.transport();

    const seg = (try mux_bearer.recvSegment(alloc, &bt)) orelse return error.UnexpectedNull;
    defer alloc.free(seg.payload);

    try std.testing.expectEqual(@as(u16, 2), seg.hdr.proto);
    try std.testing.expectEqual(@as(u16, payload.len), seg.hdr.len);
    try std.testing.expectEqualStrings(payload, seg.payload);
    // The whole wire stream must be consumed exactly, no surplus, no truncation.
    try std.testing.expectEqual(wire.len, ft.pos);
}

test "fragmented mux segment reassembles across arbitrary split chunks" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const payload = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" ** 4;

    // Sweep chunk sizes that split the header mid-way, straddle the
    // header/body boundary, and split the body — all the over-read /
    // truncation surfaces a non-persistent per-call reader would corrupt.
    const chunk_sizes = [_]usize{ 1, 3, 7, 8, 9, 13, 64, 1024 };
    for (chunk_sizes) |cs| {
        const wire = try buildSegment(alloc, 5, payload);
        defer alloc.free(wire);

        var ft = FragmentTransport{ .data = wire, .chunk = cs };
        var bt = ft.transport();

        const seg = (try mux_bearer.recvSegment(alloc, &bt)) orelse return error.UnexpectedNull;
        defer alloc.free(seg.payload);

        try std.testing.expectEqual(@as(u16, 5), seg.hdr.proto);
        try std.testing.expectEqualStrings(payload, seg.payload);
        try std.testing.expectEqual(wire.len, ft.pos);
    }
}

test "two back-to-back segments in one stream both reassemble (no body bleed)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Two segments concatenated: proves that when readAtMost over-delivers
    // (chunk spans the first segment's body AND the second's header), the
    // second recvSegment still frames correctly — the surplus from segment 1
    // is not lost. This is the precise persistent-reader invariant.
    const p1 = "first-segment-payload";
    const p2 = "second-segment-payload-which-is-longer-0123456789";
    const w1 = try buildSegment(alloc, 2, p1);
    defer alloc.free(w1);
    const w2 = try buildSegment(alloc, 3, p2);
    defer alloc.free(w2);

    var both = try alloc.alloc(u8, w1.len + w2.len);
    defer alloc.free(both);
    @memcpy(both[0..w1.len], w1);
    @memcpy(both[w1.len..], w2);

    // chunk large enough that a single readAtMost spans the segment boundary.
    var ft = FragmentTransport{ .data = both, .chunk = 4096 };
    var bt = ft.transport();

    const s1 = (try mux_bearer.recvSegment(alloc, &bt)) orelse return error.UnexpectedNull;
    defer alloc.free(s1.payload);
    try std.testing.expectEqual(@as(u16, 2), s1.hdr.proto);
    try std.testing.expectEqualStrings(p1, s1.payload);

    const s2 = (try mux_bearer.recvSegment(alloc, &bt)) orelse return error.UnexpectedNull;
    defer alloc.free(s2.payload);
    try std.testing.expectEqual(@as(u16, 3), s2.hdr.proto);
    try std.testing.expectEqualStrings(p2, s2.payload);

    try std.testing.expectEqual(both.len, ft.pos);
}

// ── REAL persistent-reader proof over an OS socket (0.16 NetStream.Reader) ──────
// The stub-transport tests above prove mux_bearer's reassembly LOGIC, but they
// never touch the actual 0.16 read primitive where the over-read/truncation
// hazard lives: compat.StreamProtoReader wraps NetStream.Reader, whose
// readSliceShort drains the persistent connection buffer FIRST and retains any
// bytes the kernel handed us beyond the current request. A fresh per-call reader
// (the anti-pattern this audit hunts) would discard that surplus.
//
// This wires the EXACT production read path tcp_byte_transport.zig uses —
// compat.streamProtoReader bound to a stable connection-lifetime buffer — onto a
// real AF_UNIX socketpair. A writer thread dribbles a length-prefixed mux segment
// in 1-byte and split chunks (real send(2) boundaries, so the kernel genuinely
// fragments delivery), and the reader reassembles it through the persistent
// reader. Proves no loss across kernel-fragmented reads AND that a single
// over-delivering read does not drop a following segment (the persistent-buffer
// invariant).
const StreamReaderTransport = struct {
    stream: compat.NetStream,
    read_buf: [4096]u8 = undefined, // connection-lifetime buffer (stable: heap impl)
    proto_reader: compat.StreamProtoReader = undefined,

    fn readAtMost(ctx: *anyopaque, out: []u8) anyerror!usize {
        const self: *StreamReaderTransport = @ptrCast(@alignCast(ctx));
        return self.proto_reader.read(out);
    }
    fn writeAll(ctx: *anyopaque, data: []const u8) anyerror!void {
        _ = ctx;
        _ = data;
        return error.NotImplemented;
    }
    fn deinit(ctx: *anyopaque) void {
        _ = ctx;
    }
    const vtable = ByteTransportVTable{
        .writeAll = writeAll,
        .readAtMost = readAtMost,
        .deinit = deinit,
    };
    fn transport(self: *StreamReaderTransport) ByteTransport {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

const Dribbler = struct {
    fd: std.posix.fd_t,
    wire: []const u8,
    chunk: usize,

    fn run(self: *Dribbler) void {
        var off: usize = 0;
        while (off < self.wire.len) {
            const n = @min(self.chunk, self.wire.len - off);
            var sent: usize = 0;
            while (sent < n) {
                // posixWrite is a stateless syscall: safe on a raw std.Thread
                // (no Io.Threaded threadlocal) and preserves the production
                // socket-write errno semantics.
                const w = compat.posixWrite(self.fd, self.wire[off + sent .. off + n]) catch |e| switch (e) {
                    error.WouldBlock => continue,
                    else => return,
                };
                if (w == 0) return;
                sent += w;
            }
            off += n;
            // Yield so the kernel delivers this chunk as its own readable event,
            // genuinely fragmenting the reader's view of the stream.
            compat.sleep(1 * std.time.ns_per_ms);
        }
        compat.closeSocket(self.fd);
    }
};

fn runRealSocketFragmentTest(alloc: std.mem.Allocator, payload: []const u8, chunk: usize) !void {
    var fds: [2]i32 = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return error.SocketpairFailed;
    const read_fd = fds[0];
    const write_fd = fds[1];

    const wire = try buildSegment(alloc, 7, payload);
    defer alloc.free(wire);

    // Reader side: production wiring — NetStream over the fd + persistent reader.
    const rt = try alloc.create(StreamReaderTransport);
    defer alloc.destroy(rt);
    rt.* = .{ .stream = .{ .socket = .{ .handle = read_fd, .address = undefined } } };
    rt.proto_reader = compat.streamProtoReader(rt.stream, &rt.read_buf);
    var bt = rt.transport();

    var dribbler = Dribbler{ .fd = write_fd, .wire = wire, .chunk = chunk };
    const th = try std.Thread.spawn(.{}, Dribbler.run, .{&dribbler});

    const seg = (try mux_bearer.recvSegment(alloc, &bt)) orelse {
        th.join();
        compat.closeSocket(read_fd);
        return error.UnexpectedNull;
    };
    defer alloc.free(seg.payload);

    th.join();
    compat.closeSocket(read_fd);

    try std.testing.expectEqual(@as(u16, 7), seg.hdr.proto);
    try std.testing.expectEqual(@as(u16, @intCast(payload.len)), seg.hdr.len);
    try std.testing.expectEqualStrings(payload, seg.payload);
}

test "real socket: 1-byte-fragmented mux segment reassembles through persistent reader" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    try runRealSocketFragmentTest(alloc, "tsunagi-real-socket-rollforward-0123456789abcdef", 1);
}

test "real socket: header/body-straddling chunks reassemble through persistent reader" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // chunk=5 splits the 8-byte header, then straddles the header/body boundary.
    try runRealSocketFragmentTest(alloc, "abcdefghijklmnopqrstuvwxyz" ** 6, 5);
}

test "real socket: over-delivering read keeps surplus (two segments, persistent buffer)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var fds: [2]i32 = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return error.SocketpairFailed;
    const read_fd = fds[0];
    const write_fd = fds[1];

    const p1 = "first-real-socket-payload";
    const p2 = "second-real-socket-payload-which-is-longer-0123456789";
    const w1 = try buildSegment(alloc, 2, p1);
    defer alloc.free(w1);
    const w2 = try buildSegment(alloc, 3, p2);
    defer alloc.free(w2);
    var both = try alloc.alloc(u8, w1.len + w2.len);
    defer alloc.free(both);
    @memcpy(both[0..w1.len], w1);
    @memcpy(both[w1.len..], w2);

    const rt = try alloc.create(StreamReaderTransport);
    defer alloc.destroy(rt);
    rt.* = .{ .stream = .{ .socket = .{ .handle = read_fd, .address = undefined } } };
    rt.proto_reader = compat.streamProtoReader(rt.stream, &rt.read_buf);
    var bt = rt.transport();

    // One big write so both segments land in the kernel buffer together; the
    // first recvSegment's readAtMost can over-deliver into the persistent
    // buffer. If the surplus were dropped, segment 2 would never frame.
    var dribbler = Dribbler{ .fd = write_fd, .wire = both, .chunk = both.len };
    const th = try std.Thread.spawn(.{}, Dribbler.run, .{&dribbler});

    const s1 = (try mux_bearer.recvSegment(alloc, &bt)) orelse {
        th.join();
        compat.closeSocket(read_fd);
        return error.UnexpectedNull;
    };
    defer alloc.free(s1.payload);
    const s2 = (try mux_bearer.recvSegment(alloc, &bt)) orelse {
        th.join();
        compat.closeSocket(read_fd);
        return error.UnexpectedNull;
    };
    defer alloc.free(s2.payload);

    th.join();
    compat.closeSocket(read_fd);

    try std.testing.expectEqual(@as(u16, 2), s1.hdr.proto);
    try std.testing.expectEqualStrings(p1, s1.payload);
    try std.testing.expectEqual(@as(u16, 3), s2.hdr.proto);
    try std.testing.expectEqualStrings(p2, s2.payload);
}
