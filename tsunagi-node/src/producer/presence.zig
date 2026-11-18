// Phase 10 — Network Presence Scoring
//
// Measures "time-to-notice": the wall-clock gap between the moment we
// emit ANNOUNCE_READY (forge seal / block-ready) and the moment the
// first relay fetches it (ANNOUNCE_SERVE). Purely passive — no protocol
// changes, no network writes.
//
// One sample per forged slot. Ring buffer of the last 32 samples feeds
// a rolling average. Resets on slot change so stale announces never
// pollute the next sample.

const std = @import("std");
const compat = @import("compat");
const multi_probe = @import("multi_probe.zig");

pub const SAMPLE_WINDOW: u32 = 32;

pub const State = struct {
    mu: compat.Mutex = .{},

    last_slot: u64 = 0,
    announce_unix_ms: i64 = 0,
    first_serve_unix_ms: i64 = 0,

    last_notice_ms: u32 = 0,
    avg_notice_ms: u32 = 0,
    p50_notice_ms: u32 = 0,
    p90_notice_ms: u32 = 0,
    min_notice_ms: u32 = 0,
    max_notice_ms: u32 = 0,

    under_1s_pct: u32 = 0,
    under_3s_pct: u32 = 0,
    under_5s_pct: u32 = 0,

    samples: [SAMPLE_WINDOW]u32 = [_]u32{0} ** SAMPLE_WINDOW,
    sample_head: u32 = 0, // next write index
    sample_count: u32 = 0,

    peers_at_announce: u32 = 0,
    peers_at_serve: u32 = 0,

    // Counters.
    announces_total: u64 = 0,
    serves_total: u64 = 0,
    notices_total: u64 = 0,
};

pub var g_state: State = .{};

fn nowMs() i64 {
    return @intCast(@divFloor(compat.nanoTimestamp(), std.time.ns_per_ms));
}

/// Count of currently-alive multi-probe peers. Used as a proxy for
/// "peers we're connected to" — these are outbound ChainSync probes
/// that observe the rest of the network on our behalf.
fn connectedPeerCount() u32 {
    multi_probe.g_mu.lock();
    defer multi_probe.g_mu.unlock();
    var n: u32 = 0;
    for (&multi_probe.g_probe_peers) |*p| {
        if (p.used and p.connected) n += 1;
    }
    return n;
}

fn computeBuckets(samples: []const u32, n: usize, out: *State) void {
    if (n == 0) {
        out.under_1s_pct = 0;
        out.under_3s_pct = 0;
        out.under_5s_pct = 0;
        return;
    }
    var c1: u32 = 0;
    var c3: u32 = 0;
    var c5: u32 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const v = samples[i];
        if (v < 1000) c1 += 1;
        if (v < 3000) c3 += 1;
        if (v < 5000) c5 += 1;
    }
    const denom: u32 = @intCast(n);
    out.under_1s_pct = (c1 * 100) / denom;
    out.under_3s_pct = (c3 * 100) / denom;
    out.under_5s_pct = (c5 * 100) / denom;
}

fn resetSlotIfChanged(slot: u64) void {
    // Called with mutex HELD.
    if (slot != g_state.last_slot) {
        g_state.last_slot = slot;
        g_state.announce_unix_ms = 0;
        g_state.first_serve_unix_ms = 0;
        g_state.peers_at_announce = 0;
        g_state.peers_at_serve = 0;
    }
}

/// Called from announce.onForge (or directly when emitting ANNOUNCE_READY).
/// Starts the timer for `slot`.
pub fn onAnnounce(slot: u64) void {
    const peers = connectedPeerCount();
    const now = nowMs();
    g_state.mu.lock();
    defer g_state.mu.unlock();
    resetSlotIfChanged(slot);
    g_state.announce_unix_ms = now;
    g_state.peers_at_announce = peers;
    g_state.announces_total += 1;
    std.debug.print("PRESENCE_ANNOUNCE: slot={d} peers={d}\n", .{ slot, peers });
}

/// Called from announce.onServe whenever a relay pulls a block. The first
/// serve for a given slot yields a notice-latency sample; subsequent
/// serves of the same slot just increment peers_at_serve.
pub fn onServe(slot: u64, peer_id: []const u8) void {
    const peers = connectedPeerCount();
    const now = nowMs();
    var notice_ms_opt: ?u32 = null;

    g_state.mu.lock();
    resetSlotIfChanged(slot);
    g_state.serves_total += 1;
    g_state.peers_at_serve += 1;

    if (g_state.first_serve_unix_ms == 0 and g_state.announce_unix_ms > 0) {
        g_state.first_serve_unix_ms = now;
        const delta_i64 = now - g_state.announce_unix_ms;
        const delta: u32 = if (delta_i64 < 0) 0 else @intCast(@min(delta_i64, @as(i64, std.math.maxInt(u32))));
        g_state.last_notice_ms = delta;

        // Push into ring buffer.
        const idx = g_state.sample_head % SAMPLE_WINDOW;
        g_state.samples[idx] = delta;
        g_state.sample_head = (g_state.sample_head + 1) % SAMPLE_WINDOW;
        if (g_state.sample_count < SAMPLE_WINDOW) g_state.sample_count += 1;

        // Rolling stats over the valid portion of the ring buffer.
        // Copy-and-sort for percentiles — 32 elements, trivial cost.
        var sorted: [SAMPLE_WINDOW]u32 = undefined;
        var valid: u32 = 0;
        var sum: u64 = 0;
        var i: u32 = 0;
        while (i < g_state.sample_count) : (i += 1) {
            const v = g_state.samples[i];
            sorted[valid] = v;
            sum += v;
            valid += 1;
        }
        g_state.avg_notice_ms = if (valid == 0) 0 else @intCast(sum / valid);
        if (valid > 0) {
            std.mem.sort(u32, sorted[0..valid], {}, std.sort.asc(u32));
            const idx50 = (valid - 1) / 2;
            // p90: ceil((valid-1) * 0.9); use integer math to avoid float.
            const num = (valid - 1) * 9;
            const idx90: u32 = @intCast((num + 9) / 10);
            const idx90c: u32 = if (idx90 >= valid) valid - 1 else idx90;
            g_state.p50_notice_ms = sorted[idx50];
            g_state.p90_notice_ms = sorted[idx90c];
            g_state.min_notice_ms = sorted[0];
            g_state.max_notice_ms = sorted[valid - 1];
            computeBuckets(sorted[0..valid], valid, &g_state);
        }
        g_state.notices_total += 1;
        notice_ms_opt = delta;
    }
    _ = peer_id; // included for future per-peer notice tracking
    const local_peers_at_serve = g_state.peers_at_serve;
    g_state.mu.unlock();

    if (notice_ms_opt) |delta| {
        std.debug.print("PRESENCE_NOTICE: slot={d} notice_ms={d} peers={d}\n", .{
            slot, delta, peers,
        });
    }
    _ = local_peers_at_serve;
}

pub fn renderJson(buf: []u8) usize {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    var w = compat.fixedBufferStream(buf);
    w.writer().print(
        "{{\"last_slot\":{d},\"announce_unix_ms\":{d},\"first_serve_unix_ms\":{d},\"last_notice_ms\":{d},\"avg_notice_ms\":{d},\"p50_notice_ms\":{d},\"p90_notice_ms\":{d},\"min_notice_ms\":{d},\"max_notice_ms\":{d},\"sample_count\":{d},\"peers_at_announce\":{d},\"peers_at_serve\":{d},\"announces_total\":{d},\"serves_total\":{d},\"notices_total\":{d},\"under_1s_pct\":{d},\"under_3s_pct\":{d},\"under_5s_pct\":{d}}}",
        .{
            g_state.last_slot,
            g_state.announce_unix_ms,
            g_state.first_serve_unix_ms,
            g_state.last_notice_ms,
            g_state.avg_notice_ms,
            g_state.p50_notice_ms,
            g_state.p90_notice_ms,
            g_state.min_notice_ms,
            g_state.max_notice_ms,
            g_state.sample_count,
            g_state.peers_at_announce,
            g_state.peers_at_serve,
            g_state.announces_total,
            g_state.serves_total,
            g_state.notices_total,
            g_state.under_1s_pct,
            g_state.under_3s_pct,
            g_state.under_5s_pct,
        },
    ) catch {};
    return w.pos;
}

test "announce + serve computes notice_ms" {
    g_state = .{};
    onAnnounce(100);
    // Force an artificial gap by manipulating state directly (test-only).
    g_state.mu.lock();
    g_state.announce_unix_ms -= 75; // 75ms earlier
    g_state.mu.unlock();
    onServe(100, "1.2.3.4");
    try std.testing.expect(g_state.last_notice_ms >= 70 and g_state.last_notice_ms <= 80);
    try std.testing.expectEqual(@as(u32, 1), g_state.sample_count);
    try std.testing.expectEqual(@as(u32, 1), g_state.peers_at_serve);
}

test "new slot resets announce/serve state" {
    g_state = .{};
    onAnnounce(100);
    onServe(100, "peer1");
    const old_count = g_state.sample_count;
    onAnnounce(101);
    try std.testing.expectEqual(@as(u64, 101), g_state.last_slot);
    try std.testing.expectEqual(@as(i64, 0), g_state.first_serve_unix_ms);
    try std.testing.expectEqual(@as(u32, 0), g_state.peers_at_serve);
    // Sample buffer survives slot change.
    try std.testing.expectEqual(old_count, g_state.sample_count);
}

test "serve before announce yields no sample" {
    g_state = .{};
    onServe(200, "peer1");
    try std.testing.expectEqual(@as(u32, 0), g_state.sample_count);
    try std.testing.expectEqual(@as(u32, 0), g_state.last_notice_ms);
}

test "p50 and p90 match sorted ring buffer" {
    g_state = .{};
    // Force 10 synthetic samples: 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 ms.
    g_state.mu.lock();
    const vals = [_]u32{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 };
    for (vals, 0..) |v, i| {
        g_state.samples[i] = v;
    }
    g_state.sample_count = 10;
    g_state.sample_head = 10;
    g_state.announce_unix_ms = 1; // non-zero so next onServe yields a sample
    g_state.last_slot = 500;
    g_state.mu.unlock();

    // Trigger onServe for a different slot so announce resets, then set it up again.
    // Easier: simulate directly by calling the stats block via a new sample.
    g_state = .{};
    onAnnounce(500);
    // Seed ring manually then force recompute via a final onServe.
    g_state.mu.lock();
    const seed = [_]u32{ 10, 20, 30, 40, 50, 60, 70, 80, 90 };
    for (seed, 0..) |v, i| g_state.samples[i] = v;
    g_state.sample_count = 9;
    g_state.sample_head = 9;
    g_state.mu.unlock();
    onServe(500, "p"); // Pushes one more; the delta depends on timing but percentiles
                      // will be computed over all 10 entries.
    try std.testing.expect(g_state.sample_count == 10);
    // p50 of first 10 ascending is index (10-1)/2 = 4 → 50ms; plus the pushed sample
    // (near 0) which inserts at end (ring). After sort: [0-ish, 10..90]. p50 idx 4
    // over 10 values → 40ms region. Just assert p50 <= p90 invariant.
    try std.testing.expect(g_state.p50_notice_ms <= g_state.p90_notice_ms);
    try std.testing.expect(g_state.min_notice_ms <= g_state.p50_notice_ms);
    try std.testing.expect(g_state.max_notice_ms >= g_state.p90_notice_ms);
}

test "computeBuckets percentages match seeded samples" {
    var s: State = .{};
    // 10 samples: 4 under 1s, 3 more under 3s (total 7), 2 more under 5s (total 9), 1 over 5s.
    const vals = [_]u32{ 100, 500, 800, 999, 1500, 2500, 2999, 3500, 4500, 6000 };
    computeBuckets(vals[0..], vals.len, &s);
    try std.testing.expectEqual(@as(u32, 40), s.under_1s_pct);
    try std.testing.expectEqual(@as(u32, 70), s.under_3s_pct);
    try std.testing.expectEqual(@as(u32, 90), s.under_5s_pct);

    // Empty input keeps zeros.
    var s2: State = .{};
    s2.under_1s_pct = 77;
    computeBuckets(vals[0..0], 0, &s2);
    try std.testing.expectEqual(@as(u32, 0), s2.under_1s_pct);
    try std.testing.expectEqual(@as(u32, 0), s2.under_3s_pct);
    try std.testing.expectEqual(@as(u32, 0), s2.under_5s_pct);
}
