// Connection state registry — surfaces incoming/outgoing peer connection
// states (cold/warm/hot) and direction overlap (duplex/bi-dir) for
// /status/full.
//
// Semantics (from Cardano Praos node):
//   cold:  registered but no handshake yet (TCP only or listener slot)
//   warm:  handshake done, no recent mini-protocol payload activity
//   hot:   handshake done AND recent (<= IDLE_S seconds) protocol activity
//   duplex / bi-dir: same remote_addr present in both incoming AND outgoing
//
// This module is observation-only. recordActivity is on the mux send/recv
// hot path, so it MUST stay cheap: one mutex lock + two field writes + an
// OR. If it ever becomes a perf concern, last_proto_activity_unix can be
// promoted to a relaxed atomic and the mutex dropped for that field.
//
// Failures: every public function is total. If the id has already been
// unregistered, recordActivity / markHandshakeDone no-op silently — they
// MUST NEVER crash the caller.

const std = @import("std");
const compat = @import("compat");

pub const MAX_CONNECTIONS: usize = 64;
pub const IDLE_S: i64 = 10;

pub const Direction = enum(u8) { incoming = 0, outgoing = 1 };

pub const ConnectionState = enum(u8) { cold = 0, warm = 1, hot = 2 };

// Active mini-protocol bitmask — OR'd into active_protos_bitmask on each
// segment. Keepalive sets the bit but does NOT bump last_proto_activity_unix,
// so a peer that only exchanges keepalives stays warm, not hot.
pub const PROTO_CHAINSYNC: u8 = 1 << 0;
pub const PROTO_BLOCKFETCH: u8 = 1 << 1;
pub const PROTO_TXSUBMISSION: u8 = 1 << 2;
pub const PROTO_KEEPALIVE: u8 = 1 << 3;

pub const Connection = struct {
    id: u64 = 0,
    direction: Direction = .incoming,
    remote_addr: [128]u8 = [_]u8{0} ** 128,
    addr_len: u8 = 0,
    tcp_connected_unix: i64 = 0,
    handshake_done_unix: i64 = 0,
    last_proto_activity_unix: i64 = 0,
    active_protos_bitmask: u8 = 0,
    used: bool = false,
};

const State = struct {
    mu: compat.Mutex = .{},
    slots: [MAX_CONNECTIONS]Connection = [_]Connection{.{}} ** MAX_CONNECTIONS,
    next_id: u64 = 1,
};

var g_state: State = .{};

/// Register a new connection. Returns the id (>0) or 0 if the registry is full.
/// remote_addr_str is copied; caller does not need to keep the buffer alive.
pub fn register(direction: Direction, remote_addr_str: []const u8) u64 {
    g_state.mu.lock();
    defer g_state.mu.unlock();

    var i: usize = 0;
    while (i < MAX_CONNECTIONS) : (i += 1) {
        if (!g_state.slots[i].used) {
            const id = g_state.next_id;
            g_state.next_id += 1;
            const now = compat.timestamp();
            const copy_len = @min(remote_addr_str.len, g_state.slots[i].remote_addr.len);
            @memcpy(g_state.slots[i].remote_addr[0..copy_len], remote_addr_str[0..copy_len]);
            g_state.slots[i] = .{
                .id = id,
                .direction = direction,
                .remote_addr = g_state.slots[i].remote_addr,
                .addr_len = @intCast(copy_len),
                .tcp_connected_unix = now,
                .handshake_done_unix = 0,
                .last_proto_activity_unix = 0,
                .active_protos_bitmask = 0,
                .used = true,
            };
            return id;
        }
    }
    return 0; // registry full — caller proceeds without telemetry
}

pub fn markHandshakeDone(id: u64) void {
    if (id == 0) return;
    g_state.mu.lock();
    defer g_state.mu.unlock();
    if (findSlot(id)) |idx| {
        g_state.slots[idx].handshake_done_unix = compat.timestamp();
    }
}

pub fn recordActivity(id: u64, proto_bit: u8) void {
    if (id == 0) return;
    g_state.mu.lock();
    defer g_state.mu.unlock();
    if (findSlot(id)) |idx| {
        g_state.slots[idx].active_protos_bitmask |= proto_bit;
        // Keepalive does not promote the connection to hot — a peer that
        // only exchanges keepalives must stay warm. Only "real" mini-protocol
        // payloads bump last_proto_activity_unix.
        if (proto_bit != PROTO_KEEPALIVE) {
            g_state.slots[idx].last_proto_activity_unix = compat.timestamp();
        }
    }
}

pub fn unregister(id: u64) void {
    if (id == 0) return;
    g_state.mu.lock();
    defer g_state.mu.unlock();
    if (findSlot(id)) |idx| {
        g_state.slots[idx].used = false;
    }
}

/// Copy active connections into caller's buffer; returns count actually copied.
pub fn snapshot(buf: []Connection) usize {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    var n: usize = 0;
    var i: usize = 0;
    while (i < MAX_CONNECTIONS and n < buf.len) : (i += 1) {
        if (g_state.slots[i].used) {
            buf[n] = g_state.slots[i];
            n += 1;
        }
    }
    return n;
}

fn findSlot(id: u64) ?usize {
    var i: usize = 0;
    while (i < MAX_CONNECTIONS) : (i += 1) {
        if (g_state.slots[i].used and g_state.slots[i].id == id) return i;
    }
    return null;
}

fn deriveState(c: Connection, now: i64) ConnectionState {
    if (c.handshake_done_unix == 0) return .cold;
    const last = c.last_proto_activity_unix;
    if (last == 0) return .warm;
    if (now - last <= IDLE_S) return .hot;
    return .warm;
}

const PEER_CAP: usize = 5;

pub fn renderJson(buf: []u8) usize {
    var snap_buf: [MAX_CONNECTIONS]Connection = undefined;
    const n = snapshot(&snap_buf);
    const items = snap_buf[0..n];
    const now = compat.timestamp();

    // Aggregate per-direction counts and detect duplex.
    var in_warm: u32 = 0;
    var in_hot: u32 = 0;
    var out_warm: u32 = 0;
    var out_hot: u32 = 0;
    var in_bidir: u32 = 0;
    var out_bidir: u32 = 0;

    for (items) |c| {
        const st = deriveState(c, now);
        switch (c.direction) {
            .incoming => {
                if (st == .warm) in_warm += 1;
                if (st == .hot) in_hot += 1;
                if (hasDuplexMatch(items, c)) in_bidir += 1;
            },
            .outgoing => {
                if (st == .warm) out_warm += 1;
                if (st == .hot) out_hot += 1;
                if (hasDuplexMatch(items, c)) out_bidir += 1;
            },
        }
    }

    var w = compat.fixedBufferStream(buf);
    const wr = w.writer();
    wr.print("{{\"incoming\":{{\"warm\":{d},\"hot\":{d},\"bidir\":{d},\"duplex\":{d},\"peers\":[", .{
        in_warm, in_hot, in_bidir, in_bidir,
    }) catch return w.pos;
    writePeers(wr, items, .incoming, now) catch return w.pos;
    wr.print("]}},\"outgoing\":{{\"warm\":{d},\"hot\":{d},\"bidir\":{d},\"duplex\":{d},\"peers\":[", .{
        out_warm, out_hot, out_bidir, out_bidir,
    }) catch return w.pos;
    writePeers(wr, items, .outgoing, now) catch return w.pos;
    wr.writeAll("]}}") catch return w.pos;

    return w.pos;
}

fn hasDuplexMatch(items: []const Connection, c: Connection) bool {
    if (c.addr_len == 0) return false;
    const addr_a = c.remote_addr[0..c.addr_len];
    for (items) |o| {
        if (o.id == c.id) continue;
        if (o.direction == c.direction) continue;
        if (o.addr_len != c.addr_len) continue;
        const addr_b = o.remote_addr[0..o.addr_len];
        if (std.mem.eql(u8, addr_a, addr_b)) return true;
    }
    return false;
}

fn writePeers(wr: anytype, items: []const Connection, dir: Direction, now: i64) !void {
    var emitted: usize = 0;
    for (items) |c| {
        if (c.direction != dir) continue;
        if (emitted >= PEER_CAP) break;
        if (emitted > 0) try wr.writeAll(",");
        const st = deriveState(c, now);
        const state_str: []const u8 = switch (st) {
            .cold => "cold",
            .warm => "warm",
            .hot => "hot",
        };
        const addr_slice = c.remote_addr[0..c.addr_len];
        try wr.print("{{\"id\":{d},\"addr\":\"{s}\",\"state\":\"{s}\",\"protos\":{d},\"hs_unix\":{d},\"last_act_unix\":{d}}}", .{
            c.id, addr_slice, state_str, c.active_protos_bitmask,
            c.handshake_done_unix, c.last_proto_activity_unix,
        });
        emitted += 1;
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

fn resetForTest() void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.next_id = 1;
    var i: usize = 0;
    while (i < MAX_CONNECTIONS) : (i += 1) {
        g_state.slots[i] = .{};
    }
}

test "register allocates id and unregister frees slot" {
    resetForTest();
    const id_a = register(.incoming, "1.2.3.4:3033");
    try std.testing.expect(id_a > 0);

    var snap_buf: [MAX_CONNECTIONS]Connection = undefined;
    try std.testing.expectEqual(@as(usize, 1), snapshot(&snap_buf));
    try std.testing.expectEqual(Direction.incoming, snap_buf[0].direction);
    try std.testing.expectEqualSlices(u8, "1.2.3.4:3033", snap_buf[0].remote_addr[0..snap_buf[0].addr_len]);

    unregister(id_a);
    try std.testing.expectEqual(@as(usize, 0), snapshot(&snap_buf));
}

test "state transitions cold -> warm -> hot" {
    resetForTest();
    const id = register(.outgoing, "10.0.0.1:3001");
    try std.testing.expect(id > 0);

    var snap_buf: [MAX_CONNECTIONS]Connection = undefined;
    _ = snapshot(&snap_buf);
    const now0 = compat.timestamp();
    try std.testing.expectEqual(ConnectionState.cold, deriveState(snap_buf[0], now0));

    markHandshakeDone(id);
    _ = snapshot(&snap_buf);
    try std.testing.expectEqual(ConnectionState.warm, deriveState(snap_buf[0], now0));

    recordActivity(id, PROTO_CHAINSYNC);
    _ = snapshot(&snap_buf);
    try std.testing.expectEqual(ConnectionState.hot, deriveState(snap_buf[0], now0));
    try std.testing.expect((snap_buf[0].active_protos_bitmask & PROTO_CHAINSYNC) != 0);

    // Simulate idle: state goes back to warm after IDLE_S seconds elapse.
    try std.testing.expectEqual(ConnectionState.warm, deriveState(snap_buf[0], snap_buf[0].last_proto_activity_unix + IDLE_S + 1));

    unregister(id);
}

test "duplex detection by remote_addr across directions" {
    resetForTest();
    const a = register(.incoming, "5.6.7.8:3033");
    const b = register(.outgoing, "5.6.7.8:3033");
    const c = register(.outgoing, "9.9.9.9:3001");
    try std.testing.expect(a > 0 and b > 0 and c > 0);

    var snap_buf: [MAX_CONNECTIONS]Connection = undefined;
    const n = snapshot(&snap_buf);
    const items = snap_buf[0..n];

    var in_match: u32 = 0;
    var out_match: u32 = 0;
    for (items) |conn| {
        if (hasDuplexMatch(items, conn)) {
            switch (conn.direction) {
                .incoming => in_match += 1,
                .outgoing => out_match += 1,
            }
        }
    }
    try std.testing.expectEqual(@as(u32, 1), in_match);
    try std.testing.expectEqual(@as(u32, 1), out_match);

    unregister(a);
    unregister(b);
    unregister(c);
}

test "recordActivity on stale id is no-op" {
    resetForTest();
    const id = register(.incoming, "127.0.0.1:3033");
    unregister(id);
    // Must not crash, must not resurrect a slot.
    recordActivity(id, PROTO_CHAINSYNC);
    markHandshakeDone(id);
    var snap_buf: [MAX_CONNECTIONS]Connection = undefined;
    try std.testing.expectEqual(@as(usize, 0), snapshot(&snap_buf));
}
