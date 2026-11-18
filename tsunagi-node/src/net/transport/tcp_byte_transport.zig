const std = @import("std");
const compat = @import("compat");
const ByteTransport = @import("byte_transport.zig").ByteTransport;
const ByteTransportVTable = @import("byte_transport.zig").ByteTransportVTable;

// 0.16: std.net.Stream -> std.Io.net.Stream (compat.NetStream). Stream I/O now
// flows through Stream.Reader/Writer which carry a PERSISTENT buffer. This is the
// Cardano mux/protocol path: a single ByteTransport handles many length-prefixed
// reads/writes over the life of the connection, so the reader/writer (and their
// buffers) MUST persist on the impl — spinning up a fresh reader per call would
// discard bytes the kernel handed us beyond what the caller asked for.
const READ_BUF_LEN = 4096;
const WRITE_BUF_LEN = 4096;

const TcpByteTransportImpl = struct {
    alloc: std.mem.Allocator,
    stream: compat.NetStream,
    // Persistent buffers + reader/writer for the connection lifetime.
    read_buf: [READ_BUF_LEN]u8 = undefined,
    write_buf: [WRITE_BUF_LEN]u8 = undefined,
    proto_reader: compat.StreamProtoReader = undefined,
    proto_writer: compat.StreamProtoWriter = undefined,

    fn writeAll(ctx: *anyopaque, data: []const u8) anyerror!void {
        const self: *TcpByteTransportImpl = @ptrCast(@alignCast(ctx));
        // Old std.net.Stream.writeAll wrote straight through to the socket; the
        // persistent writer buffers, so flush at the call boundary to preserve
        // the exact "bytes are on the wire when writeAll returns" semantics.
        try self.proto_writer.writeAll(data);
        try self.proto_writer.flush();
    }

    fn readAtMost(ctx: *anyopaque, out: []u8) anyerror!usize {
        const self: *TcpByteTransportImpl = @ptrCast(@alignCast(ctx));
        if (out.len == 0) return 0;
        // SO_RCVTIMEO is set on this socket (setReadTimeout) so the mux bearer
        // can poll with a deadline. When the timeout fires the kernel returns
        // EAGAIN. Going through the std 0.16 net reader (readSliceShort ->
        // netReadPosix) turns that EAGAIN into a DEBUG-BUILD PANIC
        // ("programmer bug caused syscall error: AGAIN") instead of a
        // recoverable error — crashing the follower the moment a recv times
        // out. propagation_server hit the same wall and solved it with a raw
        // fd read; do the same here.
        //
        // The persistent StreamProtoReader buffer may still hold bytes the
        // kernel handed us beyond a prior caller's request, so drain that
        // first (mux framing relies on it). Only when the buffer is empty do
        // we issue a raw read() and map WouldBlock -> TimedOut, matching the
        // error set the mux bearer already handles.
        const iface = &self.proto_reader.inner.interface;
        const buffered = iface.buffered();
        if (buffered.len > 0) {
            const n = @min(buffered.len, out.len);
            @memcpy(out[0..n], buffered[0..n]);
            iface.toss(n);
            return n;
        }
        return std.posix.read(self.stream.socket.handle, out) catch |err| switch (err) {
            error.WouldBlock => error.TimedOut,
            else => err,
        };
    }

    fn deinit(ctx: *anyopaque) void {
        const self: *TcpByteTransportImpl = @ptrCast(@alignCast(ctx));
        self.stream.close(compat.defaultIo());
        self.alloc.destroy(self);
    }

    const vtable = ByteTransportVTable{
        .writeAll = writeAll,
        .readAtMost = readAtMost,
        .deinit = deinit,
    };
};

pub fn connect(alloc: std.mem.Allocator, host: []const u8, port: u16) !ByteTransport {
    std.debug.print("NET: dns resolve {s}:{d}\n", .{ host, port });
    var list = try compat.getAddressList(alloc, host, port);
    defer list.deinit();
    std.debug.print("NET: dns resolved {s}:{d} addrs={d}\n", .{ host, port, list.addrs.len });

    // Try each resolved address until one connects.
    var last_err: anyerror = error.ConnectionRefused;
    for (list.addrs) |addr| {
        const stream = compat.tcpConnectToAddress(addr) catch |e| {
            std.debug.print("NET: tcp connect attempt failed: {s}\n", .{@errorName(e)});
            last_err = e;
            continue;
        };

        const impl = try alloc.create(TcpByteTransportImpl);
        impl.* = .{ .alloc = alloc, .stream = stream };
        // Bind the persistent reader/writer to the impl's own buffers (only valid
        // after the impl has its final address — the buffers live inside it).
        impl.proto_reader = compat.streamProtoReader(impl.stream, &impl.read_buf);
        impl.proto_writer = compat.streamProtoWriter(impl.stream, &impl.write_buf);

        return .{
            .ctx = impl,
            .vtable = &TcpByteTransportImpl.vtable,
        };
    }
    return last_err;
}

pub fn setReadTimeout(bt: *ByteTransport, timeout_ms: u32) !void {
    const impl: *TcpByteTransportImpl = @ptrCast(@alignCast(bt.ctx));
    var tv = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    try std.posix.setsockopt(
        impl.stream.socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&tv),
    );
}
