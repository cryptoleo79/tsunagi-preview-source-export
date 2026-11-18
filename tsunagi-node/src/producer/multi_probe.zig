// Phase 9.1 — Multi-Probe Fanout + Best-Tip Fusion
//
// Per-peer state for header-only ChainSync probes. Each peer_probe thread
// is identified by a `probe_id` (0..MAX_PROBES-1) and records its own
// last_slot / last_block / latency / connected into g_probe_peers.
//
// getBestTip() picks the peer with max(last_slot); tie-break by lowest
// latency. Used by prearm + forge as a parent-selection hint. Existing
// producer.updateRxFromPeer path is unchanged — multi_probe is an
// observation layer on top.

const std = @import("std");
const compat = @import("compat");

pub const MAX_PROBES: u32 = 8;

pub const ProbePeer = struct {
    id: u32 = 0,
    addr: [128]u8 = [_]u8{0} ** 128,
    addr_len: u8 = 0,
    last_slot: u64 = 0,
    last_block: u64 = 0,
    last_hash: [32]u8 = [_]u8{0} ** 32,
    last_update_unix: i64 = 0,
    latency_ms: u32 = 0,
    connected: bool = false,
    used: bool = false,
    headers_total: u64 = 0,
    timeouts_total: u64 = 0,
};

pub var g_mu: compat.Mutex = .{};
pub var g_probe_peers: [MAX_PROBES]ProbePeer = [_]ProbePeer{.{}} ** MAX_PROBES;

/// Phase 10.2: global enable flag for biased peer selection.
pub var g_bias_enabled: bool = false;

pub fn initBiasFromEnv() void {
    if (compat.getenv("TSUNAGI_PEER_BIAS")) |v| {
        g_bias_enabled = std.mem.eql(u8, std.mem.trim(u8, v, " \t"), "1");
    }
    std.debug.print("PEER_BIAS_CONFIG: enabled={s}\n", .{if (g_bias_enabled) "true" else "false"});
}

pub fn registerPeer(id: u32, addr: []const u8) void {
    g_mu.lock();
    defer g_mu.unlock();
    if (id >= MAX_PROBES) return;
    const p = &g_probe_peers[id];
    p.id = id;
    p.used = true;
    p.connected = false;
    const n = @min(addr.len, p.addr.len);
    @memcpy(p.addr[0..n], addr[0..n]);
    p.addr_len = @intCast(n);
    p.last_update_unix = compat.timestamp();
}

pub fn markConnected(id: u32) void {
    g_mu.lock();
    defer g_mu.unlock();
    if (id >= MAX_PROBES) return;
    g_probe_peers[id].connected = true;
    g_probe_peers[id].last_update_unix = compat.timestamp();
}

pub fn markDisconnected(id: u32) void {
    g_mu.lock();
    defer g_mu.unlock();
    if (id >= MAX_PROBES) return;
    g_probe_peers[id].connected = false;
}

pub fn recordHeader(id: u32, slot: u64, block: u64, latency_ms: u32) void {
    recordHeaderWithHash(id, slot, block, latency_ms, [_]u8{0} ** 32);
}

pub fn recordHeaderWithHash(id: u32, slot: u64, block: u64, latency_ms: u32, hash: [32]u8) void {
    g_mu.lock();
    defer g_mu.unlock();
    if (id >= MAX_PROBES) return;
    const p = &g_probe_peers[id];
    p.used = true;
    p.connected = true;
    p.last_slot = slot;
    p.last_block = block;
    p.last_hash = hash;
    p.latency_ms = latency_ms;
    p.last_update_unix = compat.timestamp();
    p.headers_total += 1;
}

pub const BestTip = struct {
    valid: bool = false,
    slot: u64 = 0,
    block: u64 = 0,
    peer_id: u32 = 0,
    latency_ms: u32 = 0,
    score: f32 = 0.0,
};

/// Select peer with max(last_slot); tie-break on lowest latency.
/// Only considers peers that are connected AND updated within 60s.
pub fn getBestTip() BestTip {
    g_mu.lock();
    defer g_mu.unlock();
    const now = compat.timestamp();
    var best: BestTip = .{};
    for (&g_probe_peers) |*p| {
        if (!p.used or !p.connected) continue;
        if (now - p.last_update_unix > 60) continue;
        if (p.last_block == 0) continue;
        if (!best.valid) {
            best = .{ .valid = true, .slot = p.last_slot, .block = p.last_block, .peer_id = p.id, .latency_ms = p.latency_ms };
            continue;
        }
        const fresher = p.last_slot > best.slot;
        const tie = p.last_slot == best.slot and p.latency_ms < best.latency_ms;
        if (fresher or tie) {
            best = .{ .valid = true, .slot = p.last_slot, .block = p.last_block, .peer_id = p.id, .latency_ms = p.latency_ms };
        }
    }
    return best;
}

pub const PeerScoreBreakdown = struct {
    peer_id: u32 = 0,
    score: f32 = 0.0,
    freshness: f32 = 0.0,
    latency_score: f32 = 0.0,
    notice_score: f32 = 0.0,
    reliability: f32 = 0.0,
};

/// Phase 10.2 — dynamic peer bias. Scores each connected probe as:
///   0.35 * freshness + 0.25 * latency_score + 0.25 * notice_score + 0.15 * reliability
/// then returns the peer with highest score. `notice_ms_global` comes from
/// presence.avg_notice_ms (caller-provided to avoid cyclic imports).
///
/// Falls back to `.valid = false` if no probe qualifies.
pub fn getBestBiasedTip(notice_ms_global: u32) BestTip {
    g_mu.lock();
    defer g_mu.unlock();
    const now = compat.timestamp();

    // First pass: find max slot for freshness normalization.
    var max_slot: u64 = 0;
    for (&g_probe_peers) |*p| {
        if (!p.used or !p.connected) continue;
        if (now - p.last_update_unix > 60) continue;
        if (p.last_block == 0) continue;
        if (p.last_slot > max_slot) max_slot = p.last_slot;
    }
    if (max_slot == 0) return .{};

    var best: BestTip = .{};
    for (&g_probe_peers) |*p| {
        if (!p.used or !p.connected) continue;
        if (now - p.last_update_unix > 60) continue;
        if (p.last_block == 0) continue;

        const slot_delta: u64 = max_slot - p.last_slot;
        const freshness: f32 = if (slot_delta == 0) 1.0 else 1.0 / (1.0 + @as(f32, @floatFromInt(slot_delta)));
        const lat_score: f32 = 1.0 / (1.0 + @as(f32, @floatFromInt(p.latency_ms)));
        const notice_score: f32 = 1.0 / (1.0 + @as(f32, @floatFromInt(notice_ms_global)));
        const total_observed: u64 = p.headers_total + p.timeouts_total;
        const reliability: f32 = if (total_observed == 0) 1.0
        else @as(f32, @floatFromInt(p.headers_total)) / @as(f32, @floatFromInt(total_observed));

        const score: f32 =
            0.35 * freshness +
            0.25 * lat_score +
            0.25 * notice_score +
            0.15 * reliability;

        if (!best.valid or score > best.score) {
            best = .{
                .valid = true,
                .slot = p.last_slot,
                .block = p.last_block,
                .peer_id = p.id,
                .latency_ms = p.latency_ms,
                .score = score,
            };
        }
    }
    return best;
}

/// Snapshot per-peer scoring breakdown for logging + status endpoint.
/// Caller provides `notice_ms_global` (from presence) to avoid cyclic imports.
/// Returns the number of entries written to `out` (capped at out.len).
pub fn snapshotScores(notice_ms_global: u32, out: []PeerScoreBreakdown) u32 {
    g_mu.lock();
    defer g_mu.unlock();
    const now = compat.timestamp();
    var max_slot: u64 = 0;
    for (&g_probe_peers) |*p| {
        if (!p.used or !p.connected) continue;
        if (now - p.last_update_unix > 60) continue;
        if (p.last_slot > max_slot) max_slot = p.last_slot;
    }

    var written: u32 = 0;
    for (&g_probe_peers) |*p| {
        if (!p.used) continue;
        if (written >= out.len) break;
        const fresh_base: f32 = if (max_slot == 0) 0.0 else blk: {
            const delta: u64 = if (p.last_slot >= max_slot) 0 else max_slot - p.last_slot;
            break :blk if (delta == 0) 1.0 else 1.0 / (1.0 + @as(f32, @floatFromInt(delta)));
        };
        const lat_score: f32 = 1.0 / (1.0 + @as(f32, @floatFromInt(p.latency_ms)));
        const notice_score: f32 = 1.0 / (1.0 + @as(f32, @floatFromInt(notice_ms_global)));
        const total_observed: u64 = p.headers_total + p.timeouts_total;
        const reliability: f32 = if (total_observed == 0) 1.0
        else @as(f32, @floatFromInt(p.headers_total)) / @as(f32, @floatFromInt(total_observed));
        const score: f32 =
            0.35 * fresh_base +
            0.25 * lat_score +
            0.25 * notice_score +
            0.15 * reliability;
        out[written] = .{
            .peer_id = p.id,
            .score = score,
            .freshness = fresh_base,
            .latency_score = lat_score,
            .notice_score = notice_score,
            .reliability = reliability,
        };
        written += 1;
    }
    return written;
}

pub fn renderBiasJson(buf: []u8, notice_ms_global: u32) usize {
    var breakdowns: [MAX_PROBES]PeerScoreBreakdown = undefined;
    const n = snapshotScores(notice_ms_global, &breakdowns);
    var w = compat.fixedBufferStream(buf);
    _ = w.writer().write("[") catch return 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (i > 0) {
            _ = w.writer().write(",") catch break;
        }
        const b = breakdowns[i];
        w.writer().print(
            "{{\"peer_id\":{d},\"score\":{d:.4},\"freshness\":{d:.4},\"latency\":{d:.4},\"notice\":{d:.4},\"reliability\":{d:.4}}}",
            .{ b.peer_id, b.score, b.freshness, b.latency_score, b.notice_score, b.reliability },
        ) catch break;
    }
    _ = w.writer().write("]") catch {};
    return w.pos;
}

/// Sweep for stale peers (no update > 60s) and mark disconnected.
/// Emits PEER_PROBE_TIMEOUT once per transition.
pub fn tickHealth() void {
    g_mu.lock();
    defer g_mu.unlock();
    const now = compat.timestamp();
    for (&g_probe_peers) |*p| {
        if (!p.used) continue;
        if (p.connected and (now - p.last_update_unix > 60)) {
            p.connected = false;
            p.timeouts_total += 1;
            std.debug.print("PEER_PROBE_TIMEOUT: id={d}\n", .{p.id});
        }
    }
}

pub fn renderProbesJson(buf: []u8) usize {
    g_mu.lock();
    defer g_mu.unlock();
    var w = compat.fixedBufferStream(buf);
    _ = w.writer().write("[") catch return 0;
    var first = true;
    for (&g_probe_peers) |*p| {
        if (!p.used) continue;
        if (!first) {
            _ = w.writer().write(",") catch return w.pos;
        }
        first = false;
        w.writer().print("{{\"peer_id\":{d},\"peer\":\"{s}\",\"slot\":{d},\"block\":{d},\"latency_ms\":{d},\"headers\":{d},\"alive\":{s}}}", .{
            p.id,
            p.addr[0..p.addr_len],
            p.last_slot,
            p.last_block,
            p.latency_ms,
            p.headers_total,
            if (p.connected) "true" else "false",
        }) catch {};
    }
    _ = w.writer().write("]") catch {};
    return w.pos;
}

test "getBestTip picks freshest, ties on latency" {
    g_probe_peers = [_]ProbePeer{.{}} ** MAX_PROBES;
    registerPeer(0, "a:1");
    registerPeer(1, "b:2");
    registerPeer(2, "c:3");
    recordHeader(0, 100, 10, 50);
    recordHeader(1, 110, 11, 80);
    recordHeader(2, 110, 11, 40);
    const best = getBestTip();
    try std.testing.expect(best.valid);
    try std.testing.expectEqual(@as(u64, 110), best.slot);
    try std.testing.expectEqual(@as(u32, 2), best.peer_id); // lower latency wins tie
}

test "getBestTip skips disconnected" {
    g_probe_peers = [_]ProbePeer{.{}} ** MAX_PROBES;
    registerPeer(0, "a:1");
    registerPeer(1, "b:2");
    recordHeader(0, 100, 10, 50);
    recordHeader(1, 200, 20, 50);
    markDisconnected(1);
    const best = getBestTip();
    try std.testing.expect(best.valid);
    try std.testing.expectEqual(@as(u32, 0), best.peer_id);
}

test "getBestTip no probes returns invalid" {
    g_probe_peers = [_]ProbePeer{.{}} ** MAX_PROBES;
    const best = getBestTip();
    try std.testing.expect(!best.valid);
}
