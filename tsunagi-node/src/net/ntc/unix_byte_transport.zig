// Unix-domain-socket byte transport — mirror of tcp_byte_transport but
// talks to a local cardano-node NtC socket at a path. Implements the
// same ByteTransport vtable so mux_bearer, handshake, etc. work
// unchanged.

const std = @import("std");
const compat = @import("compat");
const ByteTransport = @import("../transport/byte_transport.zig").ByteTransport;
const ByteTransportVTable = @import("../transport/byte_transport.zig").ByteTransportVTable;

// 0.16: std.net.Stream -> std.Io.net.Stream. The Stream no longer exposes
// blocking writeAll/read directly; I/O goes through persistent-buffer
// Stream.Reader/Stream.Writer (see compat.StreamProto{Reader,Writer}). Holding
// ONE reader and ONE writer per connection (with buffers that live as long as
// the impl) preserves protocol byte semantics: a read that pulls more off the
// socket than requested keeps the surplus buffered for the next call.
const ReadBufSize = 4096;
const WriteBufSize = 4096;

const UnixByteTransportImpl = struct {
    alloc: std.mem.Allocator,
    stream: compat.NetStream,
    rbuf: [ReadBufSize]u8 = undefined,
    wbuf: [WriteBufSize]u8 = undefined,
    proto_reader: compat.StreamProtoReader = undefined,
    proto_writer: compat.StreamProtoWriter = undefined,

    fn writeAll(ctx: *anyopaque, data: []const u8) anyerror!void {
        const self: *UnixByteTransportImpl = @ptrCast(@alignCast(ctx));
        // Buffered writer: write then flush at the boundary so the peer sees
        // exactly these bytes (preserves the old unbuffered writeAll semantics).
        try self.proto_writer.writeAll(data);
        try self.proto_writer.flush();
    }

    fn readAtMost(ctx: *anyopaque, out: []u8) anyerror!usize {
        const self: *UnixByteTransportImpl = @ptrCast(@alignCast(ctx));
        // Short read: returns whatever is available (possibly draining bytes
        // previously buffered by the persistent reader), matching Stream.read.
        return try self.proto_reader.read(out);
    }

    fn deinit(ctx: *anyopaque) void {
        const self: *UnixByteTransportImpl = @ptrCast(@alignCast(ctx));
        self.stream.close(compat.defaultIo());
        self.alloc.destroy(self);
    }

    const vtable = ByteTransportVTable{
        .writeAll = writeAll,
        .readAtMost = readAtMost,
        .deinit = deinit,
    };
};

/// Connect to a cardano-node Node-to-Client Unix socket.
pub fn connectUnix(alloc: std.mem.Allocator, path: []const u8) !ByteTransport {
    std.debug.print("NTC: connecting to unix socket {s}\n", .{path});
    // 0.16: std.net.connectUnixSocket(path) -> UnixAddress.init(path).connect(io).
    const ua = try std.Io.net.UnixAddress.init(path);
    const stream = try ua.connect(compat.defaultIo());
    const impl = try alloc.create(UnixByteTransportImpl);
    impl.* = .{ .alloc = alloc, .stream = stream };
    // Bind the persistent reader/writer to the impl-owned buffers AFTER the impl
    // is at its final address (the Stream.Reader/Writer interface vtables embed
    // a pointer into the buffer, which must not move).
    impl.proto_reader = compat.streamProtoReader(impl.stream, &impl.rbuf);
    impl.proto_writer = compat.streamProtoWriter(impl.stream, &impl.wbuf);
    return .{
        .ctx = impl,
        .vtable = &UnixByteTransportImpl.vtable,
    };
}

pub fn setReadTimeout(bt: *ByteTransport, timeout_ms: u32) !void {
    const impl: *UnixByteTransportImpl = @ptrCast(@alignCast(bt.ctx));
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
