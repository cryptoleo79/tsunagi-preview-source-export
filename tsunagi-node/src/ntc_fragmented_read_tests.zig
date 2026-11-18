// NET-RUNTIME regression test — net/handshake + ntc read path over 0.16 sockets.
//
// PROVES: the ntc/transport read path reassembles a length-prefixed mux
// segment with ZERO byte loss when the bytes arrive FRAGMENTED (1-byte and
// split chunks), because every socket read goes through ONE persistent
// `compat.StreamProtoReader` bound to a connection-lifetime buffer (the exact
// pattern in net/transport/tcp_byte_transport.zig and
// net/ntc/unix_byte_transport.zig).
//
// Why this is the real path: ntc (local_state_query / ntc_client) reads every
// reply via `mux_bearer.recvSegment` / `recvSegmentWithTimeout`, which call
// `readExactOrNull[OrTimeout]` -> `ByteTransport.readAtMost` in a fill-loop:
// first an 8-byte mux header, THEN an `hdr.len`-byte payload. If the kernel
// hands us payload bytes while we are still reading the header, a FRESH
// per-call reader would discard them. The persistent reader keeps them.
//
// This test wires a real AF_UNIX socketpair into the same `ByteTransport`
// vtable the unix/tcp transports use, with the persistent StreamProtoReader
// bound to an impl-owned buffer, and dribbles the encoded segment 1 byte at a
// time from a background OS thread. It then asserts recvSegment returns the
// full header + payload byte-for-byte.
//
// Author: cryptoleo79.

const std = @import("std");
const compat = @import("compat");
const mux_bearer = @import("net/muxwire/mux_bearer.zig");
const mux_header = @import("net/muxwire/mux_header.zig");
const byte_transport = @import("net/transport/byte_transport.zig");

const ByteTransport = byte_transport.ByteTransport;
const ByteTransportVTable = byte_transport.ByteTransportVTable;

// A ByteTransport over a raw socket fd that mirrors UnixByteTransportImpl /
// TcpByteTransportImpl EXACTLY: one persistent StreamProtoReader + one
// persistent StreamProtoWriter bound to impl-owned buffers. The read buffer is
// intentionally large enough to over-read (so the persistent-buffer surplus
// path is exercised) but the correctness property holds for any size.
const SockByteTransportImpl = struct {
    stream: compat.NetStream,
    rbuf: [4096]u8 = undefined,
    wbuf: [4096]u8 = undefined,
    proto_reader: compat.StreamProtoReader = undefined,
    proto_writer: compat.StreamProtoWriter = undefined,

    fn writeAll(ctx: *anyopaque, data: []const u8) anyerror!void {
        const self: *SockByteTransportImpl = @ptrCast(@alignCast(ctx));
        try self.proto_writer.writeAll(data);
        try self.proto_writer.flush();
    }
    fn readAtMost(ctx: *anyopaque, out: []u8) anyerror!usize {
        const self: *SockByteTransportImpl = @ptrCast(@alignCast(ctx));
        return self.proto_reader.read(out);
    }
    fn deinit(ctx: *anyopaque) void {
        _ = ctx; // fd lifetime owned by the test; nothing to free here.
    }
    const vtable = ByteTransportVTable{
        .writeAll = writeAll,
        .readAtMost = readAtMost,
        .deinit = deinit,
    };
};

fn streamFromFd(fd: std.posix.fd_t) compat.NetStream {
    // `address` is only the resolved-peer record; the reader/writer vtable uses
    // only `handle`. A placeholder address keeps the socket struct well-formed.
    const placeholder = compat.IpAddress.parse("0.0.0.0", 0) catch unreachable;
    return .{ .socket = .{ .handle = fd, .address = placeholder } };
}

// 0.16 removed std.posix.socketpair / std.posix.close. Use the libc wrappers
// (the test module links libc). Returns {read_fd, write_fd}.
fn makeSocketpair() !struct { r: std.posix.fd_t, w: std.posix.fd_t } {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return error.SocketPairFailed;
    return .{ .r = fds[0], .w = fds[1] };
}

// Background writer: dribble `bytes` to `fd` ONE byte at a time, with a short
// yield between bytes, so the reader is forced to cross-call boundaries inside
// the header and inside the payload. This is the fragmentation the persistent
// reader must survive without loss.
const Dribbler = struct {
    fd: std.posix.fd_t,
    bytes: []const u8,

    fn run(self: *Dribbler) void {
        for (self.bytes) |b| {
            var off: usize = 0;
            const one = [_]u8{b};
            while (off < 1) {
                const n = compat.posixWrite(self.fd, one[off..]) catch |e| switch (e) {
                    error.WouldBlock => continue,
                    else => return,
                };
                off += n;
            }
            // Encourage the reader to observe a partial buffer between bytes.
            std.Thread.yield() catch {};
        }
    }
};

test "ntc read path reassembles fragmented (1-byte) mux segment with no loss" {
    const alloc = std.testing.allocator;

    // 1) Build the canonical encoded segment: 8-byte mux header + payload.
    //    Payload spans more than one byte and more than the header so the
    //    fill-loop must make several readAtMost calls.
    const payload = "TSUNAGI-fragmented-payload-0123456789-abcdefghijklmnopqrstuvwxyz";
    var encoded = std.array_list.Managed(u8).init(alloc);
    defer encoded.deinit();
    {
        var hdr: [8]u8 = undefined;
        try mux_header.encode(.{
            .tx_time = 7,
            .dir = .responder,
            .proto = 7, // LSQ_PROTO — the ntc reply path
            .len = @intCast(payload.len),
        }, &hdr);
        try encoded.appendSlice(&hdr);
        try encoded.appendSlice(payload);
    }

    // 2) Real AF_UNIX socketpair. write_end is dribbled by a thread; read_end
    //    is wrapped in the persistent-reader ByteTransport (the path in scope).
    const pair = try makeSocketpair();
    const read_fd = pair.r;
    const write_fd = pair.w;
    defer compat.closeSocket(read_fd);
    defer compat.closeSocket(write_fd);

    var impl = SockByteTransportImpl{ .stream = streamFromFd(read_fd) };
    impl.proto_reader = compat.streamProtoReader(impl.stream, &impl.rbuf);
    impl.proto_writer = compat.streamProtoWriter(impl.stream, &impl.wbuf);
    var bt = ByteTransport{ .ctx = &impl, .vtable = &SockByteTransportImpl.vtable };

    // 3) Start dribbling 1 byte at a time from a background OS thread.
    var dribbler = Dribbler{ .fd = write_fd, .bytes = encoded.items };
    const t = try std.Thread.spawn(.{}, Dribbler.run, .{&dribbler});

    // 4) The exact ntc reply read path: recvSegment fills the header then the
    //    payload via readAtMost on the persistent reader.
    const res = try mux_bearer.recvSegment(alloc, &bt);
    t.join();

    try std.testing.expect(res != null);
    const seg = res.?;
    defer alloc.free(seg.payload);

    // 5) Assert FULL reassembly — no byte lost across the fragmentation
    //    boundaries (header/payload, and every 1-byte arrival).
    try std.testing.expectEqual(@as(u32, 7), seg.hdr.tx_time);
    try std.testing.expectEqual(mux_header.MiniProtocolDir.responder, seg.hdr.dir);
    try std.testing.expectEqual(@as(u16, 7), seg.hdr.proto);
    try std.testing.expectEqual(@as(u16, payload.len), seg.hdr.len);
    try std.testing.expectEqualSlices(u8, payload, seg.payload);
}

test "ntc read path reassembles two back-to-back segments delivered in split chunks" {
    const alloc = std.testing.allocator;

    // Two segments concatenated and delivered as awkward split chunks whose
    // boundaries do NOT align with header/payload boundaries. The first
    // recvSegment must over-read into the second segment's bytes and the
    // persistent reader must retain that surplus for the second recvSegment.
    const p1 = "first-segment-body";
    const p2 = "second-segment-body-which-is-longer-than-the-first-one";

    var wire = std.array_list.Managed(u8).init(alloc);
    defer wire.deinit();
    inline for (.{ p1, p2 }) |p| {
        var hdr: [8]u8 = undefined;
        try mux_header.encode(.{
            .tx_time = 0,
            .dir = .responder,
            .proto = 7,
            .len = @intCast(p.len),
        }, &hdr);
        try wire.appendSlice(&hdr);
        try wire.appendSlice(p);
    }

    const pair = try makeSocketpair();
    const read_fd = pair.r;
    const write_fd = pair.w;
    defer compat.closeSocket(read_fd);
    defer compat.closeSocket(write_fd);

    var impl = SockByteTransportImpl{ .stream = streamFromFd(read_fd) };
    impl.proto_reader = compat.streamProtoReader(impl.stream, &impl.rbuf);
    impl.proto_writer = compat.streamProtoWriter(impl.stream, &impl.wbuf);
    var bt = ByteTransport{ .ctx = &impl, .vtable = &SockByteTransportImpl.vtable };

    // Writer thread: deliver in 5-byte chunks that straddle the segment
    // boundary, with a yield between chunks.
    const ChunkWriter = struct {
        fd: std.posix.fd_t,
        bytes: []const u8,
        fn run(s: *@This()) void {
            var off: usize = 0;
            while (off < s.bytes.len) {
                const end = @min(off + 5, s.bytes.len);
                var w = off;
                while (w < end) {
                    const n = compat.posixWrite(s.fd, s.bytes[w..end]) catch |e| switch (e) {
                        error.WouldBlock => continue,
                        else => return,
                    };
                    w += n;
                }
                off = end;
                std.Thread.yield() catch {};
            }
        }
    };
    var cw = ChunkWriter{ .fd = write_fd, .bytes = wire.items };
    const t = try std.Thread.spawn(.{}, ChunkWriter.run, .{&cw});
    defer t.join();

    const r1 = try mux_bearer.recvSegment(alloc, &bt);
    try std.testing.expect(r1 != null);
    const s1 = r1.?;
    defer alloc.free(s1.payload);
    try std.testing.expectEqual(@as(u16, p1.len), s1.hdr.len);
    try std.testing.expectEqualSlices(u8, p1, s1.payload);

    const r2 = try mux_bearer.recvSegment(alloc, &bt);
    try std.testing.expect(r2 != null);
    const s2 = r2.?;
    defer alloc.free(s2.payload);
    try std.testing.expectEqual(@as(u16, p2.len), s2.hdr.len);
    try std.testing.expectEqualSlices(u8, p2, s2.payload);
}
