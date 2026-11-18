const std = @import("std");
const byte_transport = @import("../transport/byte_transport.zig");
const mux_header = @import("mux_header.zig");

fn readExactOrNull(bt: *byte_transport.ByteTransport, buf: []u8) !bool {
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = bt.readAtMost(buf[filled..]) catch |err| switch (err) {
            error.EndOfStream,
            error.ConnectionResetByPeer,
            error.ConnectionAborted,
            error.WouldBlock,
            error.TimedOut,
            error.ConnectionTimedOut,
            => {
                logReadFail(buf[0..filled], @errorName(err));
                return false;
            },
            else => return err,
        };
        if (n == 0) {
            logReadFail(buf[0..filled], "EOF");
            return false;
        }
        filled += n;
    }
    return true;
}

fn readExactOrNullOrTimeout(bt: *byte_transport.ByteTransport, buf: []u8) !?void {
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = bt.readAtMost(buf[filled..]) catch |err| switch (err) {
            error.EndOfStream,
            error.ConnectionResetByPeer,
            error.ConnectionAborted,
            => return null,
            error.WouldBlock,
            error.TimedOut,
            error.ConnectionTimedOut,
            => {
                // Only return TimedOut if no bytes consumed yet.
                // Mid-header timeout → treat as connection loss to prevent
                // mux framing corruption on the next recvSegment call.
                if (filled == 0) return error.TimedOut;
                return null;
            },
            else => return err,
        };
        if (n == 0) return null;
        filled += n;
    }
    return {};
}

fn logReadFail(partial: []const u8, reason: []const u8) void {
    const hex_chars = "0123456789abcdef";
    var hex: [16]u8 = undefined;
    const n = @min(partial.len, 8);
    for (partial[0..n], 0..) |b, i| {
        hex[i * 2] = hex_chars[b >> 4];
        hex[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    std.debug.print("mux: read-fail reason={s} filled={d} hex={s}\n", .{
        reason, partial.len, hex[0 .. n * 2],
    });
}

pub fn sendSegment(
    bt: *byte_transport.ByteTransport,
    dir: mux_header.MiniProtocolDir,
    proto: u16,
    payload: []const u8,
) !void {
    var header_buf: [8]u8 = undefined;
    try mux_header.encode(.{
        .tx_time = 0,
        .dir = dir,
        .proto = proto,
        .len = @intCast(payload.len),
    }, &header_buf);

    try bt.writeAll(&header_buf);
    try bt.writeAll(payload);
}

pub fn recvSegment(
    alloc: std.mem.Allocator,
    bt: *byte_transport.ByteTransport,
) !?struct { hdr: mux_header.Header, payload: []u8 } {
    var header_buf: [8]u8 = undefined;
    if (!try readExactOrNull(bt, &header_buf)) return null;

    const hdr = try mux_header.decode(&header_buf);
    const payload = try alloc.alloc(u8, hdr.len);
    if (hdr.len != 0) {
        if (!try readExactOrNull(bt, payload)) {
            alloc.free(payload);
            return null;
        }
    }

    return .{ .hdr = hdr, .payload = payload };
}

pub fn recvSegmentWithTimeout(
    alloc: std.mem.Allocator,
    bt: *byte_transport.ByteTransport,
) !?struct { hdr: mux_header.Header, payload: []u8 } {
    var header_buf: [8]u8 = undefined;
    if ((try readExactOrNullOrTimeout(bt, &header_buf)) == null) return null;

    const hdr = try mux_header.decode(&header_buf);
    const payload = try alloc.alloc(u8, hdr.len);
    if (hdr.len != 0) {
        const read_result = readExactOrNullOrTimeout(bt, payload) catch |err| {
            alloc.free(payload);
            return err;
        };
        if (read_result == null) {
            alloc.free(payload);
            return null;
        }
    }

    return .{ .hdr = hdr, .payload = payload };
}
