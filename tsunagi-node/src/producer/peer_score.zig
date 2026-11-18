// Phase 8.8 — Multi-Peer Weighted Selection (observe-only)
//
// Fixed-size table of up to 32 peers, scored on freshness / latency /
// reliability. We identify peers by their short string id used in
// updateRxFromPeer ("primary", "probe", or a host:port label).
//
// SELECTION IS OBSERVE-ONLY — the best peer is logged but parent selection
// logic in producer.zig is unchanged. Activation gated behind future env
// flag TSUNAGI_MODE=adaptive (not implemented here).

const std = @import("std");
const compat = @import("compat");

const MAX_PEERS: usize = 32;
const ID_LEN: usize = 32;

pub const PeerScore = struct {
    id_buf: [ID_LEN]u8 = std.mem.zeroes([ID_LEN]u8),
    id_len: u8 = 0,

    active: bool = false,

    // Samples
    total_updates: u64 = 0,
    freshness_wins: u64 = 0, // delivered a block ahead of all known peers
    latency_sum_ms: u64 = 0,
    latency_samples: u64 = 0,
    disconnects: u32 = 0,
    connects: u32 = 0,

    // Derived scores (0..100)
    freshness_score: u32 = 0,
    latency_score: u32 = 0,
    reliability_score: u32 = 0,
    total_score: u32 = 0,

    // Last update time
    last_update_unix: i64 = 0,
    last_block_no: u64 = 0,
};

const State = struct {
    mu: compat.Mutex = .{},
    peers: [MAX_PEERS]PeerScore = [_]PeerScore{.{}} ** MAX_PEERS,
    best_peer_idx: i32 = -1,
    last_log_unix: i64 = 0,
};

var g_state: State = .{};

const LOG_THROTTLE_S: i64 = 60;

fn findOrCreate(id: []const u8) *PeerScore {
    // Linear search — fine for <=32 peers
    for (&g_state.peers) |*p| {
        if (p.active and p.id_len == id.len and std.mem.eql(u8, p.id_buf[0..p.id_len], id)) return p;
    }
    for (&g_state.peers) |*p| {
        if (!p.active) {
            const len = @min(id.len, ID_LEN);
            @memcpy(p.id_buf[0..len], id[0..len]);
            p.id_len = @intCast(len);
            p.active = true;
            return p;
        }
    }
    // Overflow — reuse slot 0
    return &g_state.peers[0];
}

/// Called on every peer header update. `is_fresh_win` = this peer's block_no
/// is strictly greater than the previous known tip from any peer.
pub fn recordUpdate(peer_id: []const u8, block_no: u64, is_fresh_win: bool) void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    const p = findOrCreate(peer_id);
    p.total_updates += 1;
    if (is_fresh_win) p.freshness_wins += 1;
    p.last_update_unix = compat.timestamp();
    p.last_block_no = block_no;
    recomputeScores();
}

pub fn recordLatency(peer_id: []const u8, latency_ms: u32) void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    const p = findOrCreate(peer_id);
    p.latency_sum_ms += latency_ms;
    p.latency_samples += 1;
    recomputeScores();
}

pub fn recordConnect(peer_id: []const u8) void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    const p = findOrCreate(peer_id);
    p.connects += 1;
    recomputeScores();
}

pub fn recordDisconnect(peer_id: []const u8) void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    const p = findOrCreate(peer_id);
    p.disconnects += 1;
    recomputeScores();
}

fn recomputeScores() void {
    // Global freshness baseline: max updates across peers (normaliser).
    var max_updates: u64 = 1;
    for (&g_state.peers) |*p| {
        if (p.active and p.total_updates > max_updates) max_updates = p.total_updates;
    }

    var best_idx: i32 = -1;
    var best_score: u32 = 0;
    var i: u32 = 0;
    while (i < MAX_PEERS) : (i += 1) {
        var p = &g_state.peers[i];
        if (!p.active) continue;

        // freshness: % of updates that were fresh wins
        const fresh: u32 = if (p.total_updates == 0) 0 else @intCast(@min(100, (p.freshness_wins * 100) / p.total_updates));
        p.freshness_score = fresh;

        // latency: 0ms→100, 1000ms→0 linear
        const avg_lat: u64 = if (p.latency_samples == 0) 1000 else p.latency_sum_ms / p.latency_samples;
        const lat_score: u32 = if (avg_lat >= 1000) 0 else @intCast(100 - (avg_lat / 10));
        p.latency_score = lat_score;

        // reliability: connects / (connects + disconnects), default 100 if no data
        const rel_num: u64 = @as(u64, p.connects) * 100;
        const rel_den: u64 = @as(u64, p.connects) + @as(u64, p.disconnects);
        const rel_score: u32 = if (rel_den == 0) 100 else @intCast(@min(100, rel_num / rel_den));
        p.reliability_score = rel_score;

        // total = 0.5 fresh + 0.3 latency + 0.2 reliability, in x100
        const total: u32 = (fresh * 5 + lat_score * 3 + rel_score * 2) / 10;
        p.total_score = total;

        if (total > best_score) {
            best_score = total;
            best_idx = @intCast(i);
        }
    }
    g_state.best_peer_idx = best_idx;
}

/// Called periodically to emit throttled PEER_SCORE / PEER_BEST_CANDIDATE logs.
pub fn maybeLog() void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    const now = compat.timestamp();
    if (now - g_state.last_log_unix < LOG_THROTTLE_S) return;
    g_state.last_log_unix = now;

    for (&g_state.peers) |*p| {
        if (!p.active) continue;
        std.debug.print("PEER_SCORE: peer={s} total={d} freshness={d} latency={d} reliability={d} updates={d}\n", .{
            p.id_buf[0..p.id_len], p.total_score, p.freshness_score, p.latency_score, p.reliability_score, p.total_updates,
        });
    }
    if (g_state.best_peer_idx >= 0) {
        const p = &g_state.peers[@intCast(g_state.best_peer_idx)];
        std.debug.print("PEER_BEST_CANDIDATE: peer={s} score={d}\n", .{
            p.id_buf[0..p.id_len], p.total_score,
        });
    }
}

/// Render peers array for /status. Returns bytes written.
pub fn renderJson(buf: []u8) usize {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    var w = compat.fixedBufferStream(buf);
    const out = w.writer();
    out.writeAll("[") catch return w.pos;
    var first = true;
    for (&g_state.peers) |*p| {
        if (!p.active) continue;
        if (!first) out.writeAll(",") catch return w.pos;
        first = false;
        out.print(
            \\{{"id":"{s}","score":{d},"freshness":{d},"latency":{d},"reliability":{d},"updates":{d}}}
        , .{ p.id_buf[0..p.id_len], p.total_score, p.freshness_score, p.latency_score, p.reliability_score, p.total_updates }) catch return w.pos;
    }
    out.writeAll("]") catch return w.pos;
    return w.pos;
}
