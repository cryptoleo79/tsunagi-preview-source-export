const std = @import("std");
const compat = @import("compat");
const cbor = @import("../cbor/term.zig");
const mux_bearer = @import("../muxwire/mux_bearer.zig");
const byte_transport = @import("../transport/byte_transport.zig");
const http_metrics = @import("../metrics/http_metrics.zig");

/// NtN KeepAlive mini-protocol (protocol ID 8)
///
/// Cardano KeepAlive message IDs:
///   0 = MsgKeepAlive         [0, cookie_u16]  (request)
///   1 = MsgKeepAliveResponse [1, cookie_u16]  (response)
///   2 = MsgDone              [2]              (terminate)
///
/// Tsunagi sends periodic pings (MsgKeepAlive) and responds to incoming pings
/// with MsgKeepAliveResponse echoing the cookie.

const KEEPALIVE_PROTO: u16 = 8;
const PING_INTERVAL_S: i64 = 30;
const PONG_TIMEOUT_S: i64 = 90;

pub var g_metrics: ?*http_metrics.Metrics = null;

// Module state
var g_last_ping_unix: i64 = 0;
var g_last_pong_unix: i64 = 0;
var g_ping_cookie: u16 = 0;
var g_awaiting_pong: bool = false;
var g_last_error_log_unix: i64 = 0;
var g_consecutive_timeouts: u32 = 0;

/// Handle an incoming KeepAlive mux segment.
/// Decodes CBOR, responds to pings, records pongs.
pub fn handleMessage(
    alloc: std.mem.Allocator,
    bt: *byte_transport.ByteTransport,
    payload: []const u8,
    debug: bool,
) void {
    if (payload.len == 0) return;

    var fbs = compat.fixedBufferStream(payload);
    const term = cbor.decode(alloc, fbs.reader()) catch {
        if (g_metrics) |m| {
            _ = m.keepalive_decode_errors_total.fetchAdd(1, .acq_rel);
        }
        rateLimitedLog("KEEPALIVE: decode error len={d}\n", .{payload.len});
        return;
    };
    defer cbor.free(term, alloc);

    if (term != .array or term.array.len == 0) {
        if (debug) std.debug.print("KEEPALIVE: non-array message {s}\n", .{@tagName(term)});
        return;
    }

    const msg_id: u64 = if (term.array[0] == .u64) term.array[0].u64 else {
        if (debug) std.debug.print("KEEPALIVE: msg_id not u64\n", .{});
        return;
    };

    switch (msg_id) {
        0 => {
            // MsgKeepAlive (ping from peer) — respond with MsgKeepAliveResponse
            var cookie: u16 = 0;
            if (term.array.len >= 2 and term.array[1] == .u64) {
                cookie = @truncate(term.array[1].u64);
            }
            if (debug) std.debug.print("KEEPALIVE: rx ping cookie={d}\n", .{cookie});

            sendPong(alloc, bt, cookie) catch |err| {
                if (debug) std.debug.print("KEEPALIVE: pong send error {}\n", .{err});
            };
        },
        1 => {
            // MsgKeepAliveResponse (pong from peer)
            g_last_pong_unix = compat.timestamp();
            g_awaiting_pong = false;
            g_consecutive_timeouts = 0;
            if (g_metrics) |m| {
                _ = m.keepalive_pongs_total.fetchAdd(1, .acq_rel);
            }
            if (debug) std.debug.print("KEEPALIVE: rx pong\n", .{});
        },
        2 => {
            // MsgDone — peer terminated keepalive
            if (debug) std.debug.print("KEEPALIVE: rx done\n", .{});
        },
        else => {
            if (g_metrics) |m| {
                _ = m.keepalive_decode_errors_total.fetchAdd(1, .acq_rel);
            }
            if (debug) std.debug.print("KEEPALIVE: unknown msg_id={d}\n", .{msg_id});
        },
    }
}

/// Send a MsgKeepAliveResponse [1, cookie] to the peer.
fn sendPong(alloc: std.mem.Allocator, bt: *byte_transport.ByteTransport, cookie: u16) !void {
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();

    var items: [2]cbor.Term = undefined;
    items[0] = cbor.Term{ .u64 = 1 };
    items[1] = cbor.Term{ .u64 = cookie };
    const term = cbor.Term{ .array = items[0..2] };

    try cbor.encode(term, compat.listWriter(&buf));
    try mux_bearer.sendSegment(bt, .responder, KEEPALIVE_PROTO, buf.items);
}

/// Called from the main loop each tick. Sends a ping every PING_INTERVAL_S seconds.
/// Also checks for pong timeout (metric only, no disconnect in v1).
pub fn maybeSendPing(alloc: std.mem.Allocator, bt: *byte_transport.ByteTransport) void {
    const now = compat.timestamp();

    // Check pong timeout
    if (g_awaiting_pong and g_last_ping_unix > 0 and (now - g_last_ping_unix >= PONG_TIMEOUT_S)) {
        g_awaiting_pong = false;
        g_consecutive_timeouts += 1;
        if (g_metrics) |m| {
            _ = m.keepalive_timeouts_total.fetchAdd(1, .acq_rel);
        }
    }

    // Send ping if interval elapsed
    if (now - g_last_ping_unix < PING_INTERVAL_S) return;
    g_last_ping_unix = now;
    g_ping_cookie +%= 1;

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();

    var items: [2]cbor.Term = undefined;
    items[0] = cbor.Term{ .u64 = 0 };
    items[1] = cbor.Term{ .u64 = g_ping_cookie };
    const term = cbor.Term{ .array = items[0..2] };

    cbor.encode(term, compat.listWriter(&buf)) catch return;
    mux_bearer.sendSegment(bt, .responder, KEEPALIVE_PROTO, buf.items) catch return;

    g_awaiting_pong = true;
    if (g_metrics) |m| {
        _ = m.keepalive_pings_total.fetchAdd(1, .acq_rel);
    }
}

/// Returns true if strict mode is enabled AND 2+ consecutive timeouts occurred.
/// Consumes the signal (resets consecutive count) so caller can act on it once.
pub fn takeReconnectSignal(alloc: std.mem.Allocator) bool {
    if (g_consecutive_timeouts < 2) return false;
    const strict = compat.hasEnvVar(alloc, "TSUNAGI_KEEPALIVE_STRICT");
    if (!strict) return false;
    g_consecutive_timeouts = 0;
    return true;
}

/// Reset state on reconnect.
pub fn reset() void {
    g_last_ping_unix = 0;
    g_last_pong_unix = 0;
    g_ping_cookie = 0;
    g_awaiting_pong = false;
    g_consecutive_timeouts = 0;
}

fn rateLimitedLog(comptime fmt: []const u8, args: anytype) void {
    const now = compat.timestamp();
    if (now - g_last_error_log_unix < 60) return;
    g_last_error_log_unix = now;
    std.debug.print(fmt, args);
}

// ── Server-side handler (propagation harness) ───────────────────────
//
// When Tsunagi is the TCP acceptor (mux responder), KeepAlive pongs
// must be sent with .initiator direction (bit 1 = ResponderDir in
// Cardano mux framing). The client-side sendPong above uses .responder
// (bit 0 = InitiatorDir), which is correct when Tsunagi is the TCP
// initiator (follower). Using the wrong direction causes the relay's
// mux demuxer to route the pong to the wrong codec side, producing:
//   DecoderFailure (KeepAlive) ClientHasAgency ... unexpected key (1, 2)

/// Handle an incoming KeepAlive segment when Tsunagi is the SERVER
/// (TCP acceptor / mux responder). Same decode as handleMessage but
/// sends pong with .initiator direction (ResponderDir).
pub fn serverHandleMessage(
    alloc: std.mem.Allocator,
    bt: *byte_transport.ByteTransport,
    payload: []const u8,
) void {
    if (payload.len == 0) return;

    var fbs = compat.fixedBufferStream(payload);
    const term = cbor.decode(alloc, fbs.reader()) catch return;
    defer cbor.free(term, alloc);

    if (term != .array or term.array.len == 0) return;
    if (term.array[0] != .u64) return;

    switch (term.array[0].u64) {
        0 => {
            // MsgKeepAlive (ping) — respond with MsgKeepAliveResponse
            var cookie: u16 = 0;
            if (term.array.len >= 2 and term.array[1] == .u64) {
                cookie = @truncate(term.array[1].u64);
            }
            std.debug.print("keepalive: rx ping cookie={d}\n", .{cookie});
            sendServerPong(alloc, bt, cookie) catch |err| {
                std.debug.print("keepalive: pong send FAILED err={}\n", .{err});
            };
        },
        1 => {
            std.debug.print("keepalive: rx pong (server ignoring)\n", .{});
        },
        2 => {
            std.debug.print("keepalive: rx done\n", .{});
        },
        else => {
            std.debug.print("keepalive: rx unknown msg_id={d}\n", .{term.array[0].u64});
        },
    }
}

/// Send pong with .initiator direction (ResponderDir, bit 1).
/// This is the server-side variant — the TCP acceptor sends "from responder".
fn sendServerPong(alloc: std.mem.Allocator, bt: *byte_transport.ByteTransport, cookie: u16) !void {
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();

    var items: [2]cbor.Term = undefined;
    items[0] = cbor.Term{ .u64 = 1 };
    items[1] = cbor.Term{ .u64 = cookie };
    const term = cbor.Term{ .array = items[0..2] };

    try cbor.encode(term, compat.listWriter(&buf));
    std.debug.print("keepalive: tx pong cookie={d} len={d}\n", .{ cookie, buf.items.len });
    // .initiator = bit 1 = ResponderDir — correct for TCP acceptor (server)
    try mux_bearer.sendSegment(bt, .initiator, KEEPALIVE_PROTO, buf.items);
    std.debug.print("mux: tx proto=8 dir=1 len={d}\n", .{buf.items.len});
}
