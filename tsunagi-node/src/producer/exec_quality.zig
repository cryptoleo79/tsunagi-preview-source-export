// Phase 8.6 — Execution Quality Engine
//
// Observability-only scorer that answers "if a leader slot fires right
// now, how well are we positioned to land a block?" Combines three
// running metrics:
//   1. parent_gap    — probe_tip - selected_parent_slot (slots behind)
//   2. probe_advantage — % of recent updates where probe beat primary
//   3. latency_ms    — wall-clock from probe update → PARENT_SELECTED
//
// Purely passive: it watches other modules' signals and computes a
// score. Nothing here ever affects forge or VRF.

const std = @import("std");
const compat = @import("compat");

/// Sliding window size for probe_advantage tracking.
const PROBE_WINDOW: usize = 100;

pub const Rating = enum(u8) {
    low = 0,
    medium = 1,
    high = 2,

    pub fn str(self: Rating) []const u8 {
        return switch (self) {
            .low => "LOW",
            .medium => "MEDIUM",
            .high => "HIGH",
        };
    }
};

pub const Snapshot = struct {
    parent_gap: i32 = 0,
    probe_advantage: i32 = 0, // 0..100 (percent)
    latency_ms: u32 = 0,
    score: i32 = 0,
    rating: Rating = .low,
};

const State = struct {
    mu: compat.Mutex = .{},

    // Latest observed values
    last_primary_block: u64 = 0,
    last_primary_slot: u64 = 0,
    last_probe_block: u64 = 0,
    last_probe_slot: u64 = 0,
    last_probe_unix_ms: i64 = 0,

    // Sliding window: 1 bit per sample — 1 = probe beat primary
    window: [PROBE_WINDOW]u8 = [_]u8{0} ** PROBE_WINDOW,
    window_head: u32 = 0,
    window_count: u32 = 0,
    window_wins: u32 = 0,

    // Latest measured pipeline latency
    latest_latency_ms: u32 = 0,

    // EMA'd parent gap (probe_block - primary_block at moment of probe update)
    parent_gap: i32 = 0,
    parent_gap_samples: u64 = 0,
    parent_gap_update_total: u64 = 0,
    latency_update_total: u64 = 0,
};

var g_state: State = .{};

fn nowUnixMs() i64 {
    return @intCast(@divFloor(compat.nanoTimestamp(), std.time.ns_per_ms));
}

/// Called from updateRxFromPeer with peer_id and new block_no.
pub fn recordPeerUpdate(peer_id: []const u8, slot: u64, block_no: u64) void {
    const is_probe = std.mem.eql(u8, peer_id, "probe");
    g_state.mu.lock();
    defer g_state.mu.unlock();

    if (is_probe) {
        g_state.last_probe_block = block_no;
        g_state.last_probe_slot = slot;
        g_state.last_probe_unix_ms = nowUnixMs();

        // Measure gap vs current primary — positive means probe is fresher.
        const gap: i32 = if (g_state.last_primary_block != 0)
            @intCast(@as(i64, @intCast(block_no)) - @as(i64, @intCast(g_state.last_primary_block)))
        else
            0;
        g_state.parent_gap = gap;
        g_state.parent_gap_samples += 1;
        g_state.parent_gap_update_total += 1;

        // Sliding window: did probe beat primary?
        const beat: u8 = if (gap > 0) 1 else 0;
        const idx = g_state.window_head % PROBE_WINDOW;
        if (g_state.window_count == PROBE_WINDOW) {
            // Evict oldest
            g_state.window_wins -= g_state.window[idx];
        } else {
            g_state.window_count += 1;
        }
        g_state.window[idx] = beat;
        g_state.window_wins += beat;
        g_state.window_head +%= 1;
    } else {
        g_state.last_primary_block = block_no;
        g_state.last_primary_slot = slot;
    }
}

/// Called from producer.executeTick after PARENT_SELECTED fires. Measures
/// wall-clock from last probe update to this parent selection — proxy for
/// how long probe data takes to propagate into forge-path reads.
pub fn recordParentSelected() void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    if (g_state.last_probe_unix_ms == 0) return;
    const now = nowUnixMs();
    const delta = now - g_state.last_probe_unix_ms;
    if (delta < 0 or delta > 600_000) return; // sanity: drop >10min samples
    g_state.latest_latency_ms = @intCast(delta);
    g_state.latency_update_total += 1;
}

/// Compute score + rating from current state. Locks for the read.
pub fn currentScore() Snapshot {
    g_state.mu.lock();
    defer g_state.mu.unlock();

    const gap = g_state.parent_gap;
    const latency = g_state.latest_latency_ms;
    const advantage: i32 = if (g_state.window_count == 0)
        0
    else
        @intCast((@as(u64, g_state.window_wins) * 100) / @as(u64, g_state.window_count));

    // score = (probe_advantage * 2) - parent_gap - (latency_ms / 10)
    const lat_penalty: i32 = @intCast(latency / 10);
    const score = (advantage * 2) - gap - lat_penalty;

    const rating: Rating = if (score > 50) .high else if (score > 10) .medium else .low;

    return .{
        .parent_gap = gap,
        .probe_advantage = advantage,
        .latency_ms = latency,
        .score = score,
        .rating = rating,
    };
}

/// Append snapshot fields to `buf` starting at offset `pos`. Writes fields
/// suitable for inline embedding into a leader's JSON object (no braces,
/// leading comma). Returns new position.
pub fn renderInlineJson(buf: []u8, pos: usize) usize {
    const snap = currentScore();
    const out = std.fmt.bufPrint(buf[pos..],
        \\,"score":{d},"rating":"{s}","parent_gap":{d},"probe_advantage":{d},"latency_ms":{d}
    , .{ snap.score, snap.rating.str(), snap.parent_gap, snap.probe_advantage, snap.latency_ms }) catch
        return pos;
    return pos + out.len;
}

test "score bands" {
    const S = struct {
        fn rate(score: i32) Rating {
            return if (score > 50) .high else if (score > 10) .medium else .low;
        }
    };
    try std.testing.expectEqual(Rating.high, S.rate(51));
    try std.testing.expectEqual(Rating.medium, S.rate(11));
    try std.testing.expectEqual(Rating.low, S.rate(10));
    try std.testing.expectEqual(Rating.low, S.rate(-1000));
}
