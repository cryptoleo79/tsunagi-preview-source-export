//! Fragmentation regression test for the net/metrics HTTP server read path.
//!
//! AUDIT CONTEXT (Zig 0.16 net-runtime): http_metrics.zig::Server.handleConn
//! reads an HTTP request over a 0.16 socket using a PERSISTENT connection-owned
//! reader: it constructs exactly one `compat.NetStream.Reader.init(stream, io,
//! &rbuf)` per accepted connection and threads its `interface` through every
//! read (request line, headers, body) via `ConnReader`:
//!   - request line + headers  -> iface.takeByte() loop (readUntilDelimiterOrEof)
//!   - Content-Length body      -> iface.readSliceShort(buf)  (readAll)
//! Both operate on the SAME persistent buffer, so bytes the kernel handed us
//! beyond one read boundary are preserved for the next read. A fresh per-call
//! reader would discard them.
//!
//! This test reproduces that exact read sequence against a REAL loopback TCP
//! socket whose payload is delivered in 1-byte and odd-sized split chunks (TCP
//! segmentation forced via flush + tiny sleeps). It asserts the request line,
//! every header (incl. Content-Length parse), and the full body reassemble with
//! ZERO loss / truncation / over-read — i.e. the property handleConn depends on.
//!
//! It deliberately uses the production primitives (compat.NetStream.Reader +
//! readSliceShort/takeByte over one persistent buffer) rather than copying byte
//! values, so a regression in those primitives' reassembly behavior fails here.

const std = @import("std");
const compat = @import("compat");

// Mirror of http_metrics.zig::Server.ConnReader read semantics, bound to a
// single persistent std.Io.Reader interface (the production pattern).
const ConnReader = struct {
    iface: *std.Io.Reader,

    fn readUntilDelimiterOrEof(self: ConnReader, buf: []u8, delimiter: u8) !?[]u8 {
        var i: usize = 0;
        while (true) {
            const byte = self.iface.takeByte() catch |err| switch (err) {
                error.EndOfStream => {
                    if (i == 0) return null;
                    return buf[0..i];
                },
                else => return err,
            };
            if (byte == delimiter) return buf[0..i];
            if (i >= buf.len) return error.StreamTooLong;
            buf[i] = byte;
            i += 1;
        }
    }

    fn readAll(self: ConnReader, buf: []u8) !usize {
        return self.iface.readSliceShort(buf);
    }
};

/// Result captured by the server side so the test thread can assert on it.
const Captured = struct {
    method: [16]u8 = undefined,
    method_len: usize = 0,
    path: [64]u8 = undefined,
    path_len: usize = 0,
    content_length: usize = 0,
    body: [4096]u8 = undefined,
    body_len: usize = 0,
    saw_custom_header: bool = false,
    err: bool = false,
};

/// Runs the EXACT handleConn read sequence over an accepted stream.
fn serveOnce(stream: compat.NetStream, out: *Captured) void {
    var rbuf: [4096]u8 = undefined; // persistent connection-owned buffer
    var conn_sr = compat.NetStream.Reader.init(stream, compat.defaultIo(), &rbuf);
    const r = ConnReader{ .iface = &conn_sr.interface };

    var req_line_buf: [512]u8 = undefined;
    const line = (r.readUntilDelimiterOrEof(&req_line_buf, '\n') catch {
        out.err = true;
        return;
    }) orelse {
        out.err = true;
        return;
    };

    var it = std.mem.tokenizeAny(u8, line, " \r\n\t");
    const method = std.mem.trimEnd(u8, it.next() orelse {
        out.err = true;
        return;
    }, "\r\n\t ");
    const path = std.mem.trimEnd(u8, it.next() orelse {
        out.err = true;
        return;
    }, "\r\n\t ");
    @memcpy(out.method[0..method.len], method);
    out.method_len = method.len;
    @memcpy(out.path[0..path.len], path);
    out.path_len = path.len;

    // Header loop (same shape as handleConn POST path).
    var hdr_buf: [512]u8 = undefined;
    while (true) {
        const hdr = (r.readUntilDelimiterOrEof(&hdr_buf, '\n') catch break) orelse break;
        const trimmed = std.mem.trim(u8, hdr, " \r\n\t");
        if (trimmed.len == 0) break;
        if (trimmed.len >= 15 and
            (std.mem.startsWith(u8, trimmed, "Content-Length:") or
                std.mem.startsWith(u8, trimmed, "content-length:")))
        {
            const val = std.mem.trim(u8, trimmed[15..], " ");
            out.content_length = std.fmt.parseInt(usize, val, 10) catch 0;
        }
        if (std.mem.startsWith(u8, trimmed, "X-Tsunagi-Test:")) out.saw_custom_header = true;
    }

    if (out.content_length > 0 and out.content_length <= out.body.len) {
        out.body_len = r.readAll(out.body[0..out.content_length]) catch {
            out.err = true;
            return;
        };
    }
}

const ServerCtx = struct {
    listener: *std.Io.net.Server,
    out: *Captured,
};

fn serverThread(ctx: ServerCtx) void {
    const stream = ctx.listener.accept(compat.defaultIo()) catch {
        ctx.out.err = true;
        return;
    };
    defer stream.close(compat.defaultIo());
    serveOnce(stream, ctx.out);
}

/// 0.16 std.Io.net.Server exposes no bound-address query, so bind a fixed
/// loopback port, walking upward if it is already taken (parallel test runs).
fn bindLoopback(io: std.Io) !struct { server: std.Io.net.Server, port: u16 } {
    var port: u16 = 39871;
    while (port < 39971) : (port += 1) {
        const addr: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } };
        const server = addr.listen(io, .{ .reuse_address = true }) catch |err| switch (err) {
            error.AddressInUse, error.AddressUnavailable => continue,
            else => return err,
        };
        return .{ .server = server, .port = port };
    }
    return error.AddressInUse;
}

fn connectLoopback(io: std.Io, port: u16) !compat.NetStream {
    const addr: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } };
    return addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
}

/// Writes `bytes` to the socket in fragments: first N bytes one-at-a-time, then
/// the rest in small odd-sized chunks, flushing + sleeping between each to force
/// the kernel to deliver them as separate TCP segments.
fn writeFragmented(stream: compat.NetStream, bytes: []const u8) !void {
    var wbuf: [256]u8 = undefined;
    var w = compat.NetStream.Writer.init(stream, compat.defaultIo(), &wbuf);
    var i: usize = 0;
    const one_byte_prefix: usize = @min(bytes.len, 24);
    while (i < one_byte_prefix) : (i += 1) {
        try w.interface.writeAll(bytes[i .. i + 1]);
        try w.interface.flush();
        compat.sleep(300_000); // 0.3ms
    }
    var chunk: usize = 3;
    while (i < bytes.len) {
        const end = @min(bytes.len, i + chunk);
        try w.interface.writeAll(bytes[i..end]);
        try w.interface.flush();
        compat.sleep(300_000);
        i = end;
        chunk = if (chunk >= 7) 1 else chunk + 2; // vary 3,5,7,1,3,5,7,...
    }
}

test "metrics http read path reassembles a fragmented request with no loss" {
    const io = compat.defaultIo();

    const bound = try bindLoopback(io);
    var listener = bound.server;
    defer listener.deinit(io);

    var captured = Captured{};
    const th = try std.Thread.spawn(.{}, serverThread, .{ServerCtx{
        .listener = &listener,
        .out = &captured,
    }});

    // Client connects and sends a POST with a multi-byte body, fragmented.
    const body = "DEADBEEFCAFEBABE0011223344556677889900AABBCCDDEEFF" ** 4; // 200 bytes
    var req_buf: [1024]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf,
        "POST /tx/submit HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "X-Tsunagi-Test: frag\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: {d}\r\n" ++
        "\r\n" ++
        "{s}", .{ body.len, body });

    const client = try connectLoopback(io, bound.port);
    try writeFragmented(client, req);
    // Half-close write side so any final readSliceShort sees EOF promptly.
    client.close(io);

    th.join();

    try std.testing.expect(!captured.err);
    try std.testing.expectEqualStrings("POST", captured.method[0..captured.method_len]);
    try std.testing.expectEqualStrings("/tx/submit", captured.path[0..captured.path_len]);
    try std.testing.expect(captured.saw_custom_header);
    try std.testing.expectEqual(body.len, captured.content_length);
    // The critical assertion: full body reassembled, byte-exact, no truncation.
    try std.testing.expectEqual(body.len, captured.body_len);
    try std.testing.expectEqualStrings(body, captured.body[0..captured.body_len]);
}

test "metrics http read path: 1-byte-at-a-time entire request" {
    const io = compat.defaultIo();
    const bound = try bindLoopback(io);
    var listener = bound.server;
    defer listener.deinit(io);

    var captured = Captured{};
    const th = try std.Thread.spawn(.{}, serverThread, .{ServerCtx{
        .listener = &listener,
        .out = &captured,
    }});

    const body = "0123456789abcdef"; // 16 bytes
    var req_buf: [512]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf,
        "POST /tx/submit HTTP/1.1\r\n" ++
        "Content-Length: {d}\r\n" ++
        "\r\n" ++
        "{s}", .{ body.len, body });

    const client = try connectLoopback(io, bound.port);
    // Send the ENTIRE request one byte at a time.
    var wbuf: [64]u8 = undefined;
    var w = compat.NetStream.Writer.init(client, io, &wbuf);
    for (req) |b| {
        try w.interface.writeAll(&[_]u8{b});
        try w.interface.flush();
        compat.sleep(200_000);
    }
    client.close(io);
    th.join();

    try std.testing.expect(!captured.err);
    try std.testing.expectEqual(body.len, captured.content_length);
    try std.testing.expectEqual(body.len, captured.body_len);
    try std.testing.expectEqualStrings(body, captured.body[0..captured.body_len]);
}
