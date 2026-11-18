// Phase 9.9 — Auto-Tuner (Shadow)
//
// Learns from real outcomes and proposes better forge-delay values
// WITHOUT mutating any behavior. Every resolved feedback sample
// (accepted or missed) is pushed into a fixed-size ring buffer. Every
// 10 pushes we compute avg_gap / avg_delay / success_rate and emit an
// AUTOTUNE_RECOMMEND line with a suggested delay adjustment.
//
//   TSUNAGI_AUTOTUNE=1              enable (default off)
//   TSUNAGI_AUTOTUNE_WINDOW=50      capped at MAX_SAMPLES
//   TSUNAGI_AUTOTUNE_EMIT=1         emit recommendations on analyze
//
// No forge-path mutation. No side effects beyond logs + /status/full.

const std = @import("std");
const compat = @import("compat");

pub const MAX_SAMPLES: u32 = 50;
const ANALYZE_INTERVAL: u32 = 10;

pub const Sample = struct {
    slot: u64 = 0,
    accepted: bool = false,
    gap: i32 = 0,
    delay_ms: u32 = 0,
    latency_ms: u32 = 0,
    valid: bool = false,
};

pub const Recommendation = struct {
    delay_ms: i32 = 0, // suggested delta vs. the base delay
    reason_len: u8 = 0,
    reason: [32]u8 = [_]u8{0} ** 32,

    pub fn reasonStr(self: *const Recommendation) []const u8 {
        return self.reason[0..self.reason_len];
    }
};

pub const State = struct {
    mu: compat.Mutex = .{},

    enabled: bool = false,
    emit: bool = false,
    window: u32 = MAX_SAMPLES,

    samples: [MAX_SAMPLES]Sample = [_]Sample{.{}} ** MAX_SAMPLES,
    head: u32 = 0, // next write index
    count: u32 = 0, // saturates at window
    seen_since_analyze: u32 = 0,

    // Last analysis snapshot.
    avg_gap: f64 = 0.0,
    avg_delay_ms: f64 = 0.0,
    avg_latency_ms: f64 = 0.0,
    success_rate: f64 = 0.0,
    last_rec: Recommendation = .{},
    last_analyzed_unix: i64 = 0,
    analyze_total: u64 = 0,
    recommend_total: u64 = 0,
};

pub var g_state: State = .{};

pub fn initFromEnv() void {
    var enabled = false;
    var emit = false;
    var window: u32 = MAX_SAMPLES;
    if (compat.getenv("TSUNAGI_AUTOTUNE")) |v| {
        enabled = std.mem.eql(u8, std.mem.trim(u8, v, " \t"), "1");
    }
    if (compat.getenv("TSUNAGI_AUTOTUNE_EMIT")) |v| {
        emit = std.mem.eql(u8, std.mem.trim(u8, v, " \t"), "1");
    }
    if (compat.getenv("TSUNAGI_AUTOTUNE_WINDOW")) |v| {
        const n = std.fmt.parseUnsigned(u32, std.mem.trim(u8, v, " \t"), 10) catch MAX_SAMPLES;
        window = if (n == 0) MAX_SAMPLES else @min(n, MAX_SAMPLES);
    }
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.enabled = enabled;
    g_state.emit = emit;
    g_state.window = window;
    std.debug.print("AUTOTUNE_CONFIG: enabled={s} emit={s} window={d}\n", .{
        if (enabled) "true" else "false",
        if (emit) "true" else "false",
        window,
    });
}

/// Push a sample. Typically called from feedback.onAccept / onMiss once the
/// outcome is resolved. Idempotent per (slot, outcome).
pub fn recordSample(slot: u64, accepted: bool, gap: i32, delay_ms: u32, latency_ms: u32) void {
    g_state.mu.lock();
    const enabled = g_state.enabled;
    if (!enabled) {
        g_state.mu.unlock();
        return;
    }

    // Dedup: if the newest valid sample matches this slot+outcome, skip.
    if (g_state.count > 0) {
        const last_idx = (g_state.head + g_state.window - 1) % g_state.window;
        const prev = g_state.samples[last_idx];
        if (prev.valid and prev.slot == slot and prev.accepted == accepted) {
            g_state.mu.unlock();
            return;
        }
    }

    const idx = g_state.head % g_state.window;
    g_state.samples[idx] = .{
        .slot = slot,
        .accepted = accepted,
        .gap = gap,
        .delay_ms = delay_ms,
        .latency_ms = latency_ms,
        .valid = true,
    };
    g_state.head = (g_state.head + 1) % g_state.window;
    if (g_state.count < g_state.window) g_state.count += 1;
    g_state.seen_since_analyze += 1;

    const should_analyze = g_state.seen_since_analyze >= ANALYZE_INTERVAL and g_state.count >= ANALYZE_INTERVAL;
    if (should_analyze) g_state.seen_since_analyze = 0;
    g_state.mu.unlock();

    if (should_analyze) analyze();
}

fn analyze() void {
    // Copy samples under lock, then compute outside.
    var local: [MAX_SAMPLES]Sample = undefined;
    var n: u32 = 0;
    var emit: bool = false;
    g_state.mu.lock();
    {
        n = g_state.count;
        emit = g_state.emit;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            local[i] = g_state.samples[i];
        }
    }
    g_state.mu.unlock();

    if (n == 0) return;

    var sum_gap: i64 = 0;
    var sum_delay: u64 = 0;
    var sum_latency: u64 = 0;
    var accepted_count: u32 = 0;
    var valid_n: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const s = local[i];
        if (!s.valid) continue;
        sum_gap += s.gap;
        sum_delay += s.delay_ms;
        sum_latency += s.latency_ms;
        if (s.accepted) accepted_count += 1;
        valid_n += 1;
    }
    if (valid_n == 0) return;

    const avg_gap: f64 = @as(f64, @floatFromInt(sum_gap)) / @as(f64, @floatFromInt(valid_n));
    const avg_delay: f64 = @as(f64, @floatFromInt(sum_delay)) / @as(f64, @floatFromInt(valid_n));
    const avg_latency: f64 = @as(f64, @floatFromInt(sum_latency)) / @as(f64, @floatFromInt(valid_n));
    const success_rate: f64 = @as(f64, @floatFromInt(accepted_count)) / @as(f64, @floatFromInt(valid_n));

    // Decision rules.
    var rec: Recommendation = .{};
    var delta: i32 = 0;
    var reason_src: []const u8 = "stable";

    if (success_rate < 0.5) {
        if (avg_gap > 3.0) {
            delta = 20;
            reason_src = "gap_high_increase_delay";
        } else if (avg_gap < 1.0) {
            delta = -10;
            reason_src = "gap_low_decrease_delay";
        } else if (avg_latency > 200.0) {
            delta = 0;
            reason_src = "latency_high_prefer_probes";
        } else {
            delta = 0;
            reason_src = "low_success_no_clear_signal";
        }
    } else if (avg_latency > 300.0) {
        delta = 0;
        reason_src = "latency_high_prefer_probes";
    }

    rec.delay_ms = delta;
    const rlen = @min(reason_src.len, rec.reason.len);
    @memcpy(rec.reason[0..rlen], reason_src[0..rlen]);
    rec.reason_len = @intCast(rlen);

    g_state.mu.lock();
    g_state.avg_gap = avg_gap;
    g_state.avg_delay_ms = avg_delay;
    g_state.avg_latency_ms = avg_latency;
    g_state.success_rate = success_rate;
    g_state.last_rec = rec;
    g_state.last_analyzed_unix = compat.timestamp();
    g_state.analyze_total += 1;
    if (delta != 0 or !std.mem.eql(u8, reason_src, "stable")) g_state.recommend_total += 1;
    g_state.mu.unlock();

    if (emit) {
        std.debug.print("AUTOTUNE_RECOMMEND: samples={d} success_rate={d:.3} avg_gap={d:.2} avg_delay={d:.1} avg_latency={d:.1} delay_delta={d} reason={s}\n", .{
            valid_n, success_rate, avg_gap, avg_delay, avg_latency, delta, reason_src,
        });
    }
}

pub fn renderJson(buf: []u8) usize {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    var w = compat.fixedBufferStream(buf);
    w.writer().print(
        "{{\"enabled\":{s},\"emit\":{s},\"window\":{d},\"samples\":{d},\"success_rate\":{d:.3},\"avg_gap\":{d:.2},\"avg_delay\":{d:.1},\"avg_latency\":{d:.1},\"recommended_delay_delta\":{d},\"reason\":\"{s}\",\"last_analyzed_unix\":{d},\"analyze_total\":{d},\"recommend_total\":{d}}}",
        .{
            if (g_state.enabled) "true" else "false",
            if (g_state.emit) "true" else "false",
            g_state.window,
            g_state.count,
            g_state.success_rate,
            g_state.avg_gap,
            g_state.avg_delay_ms,
            g_state.avg_latency_ms,
            g_state.last_rec.delay_ms,
            g_state.last_rec.reasonStr(),
            g_state.last_analyzed_unix,
            g_state.analyze_total,
            g_state.recommend_total,
        },
    ) catch {};
    return w.pos;
}

test "records and analyzes after 10 samples" {
    g_state = .{};
    g_state.enabled = true;
    g_state.emit = false;
    g_state.window = MAX_SAMPLES;

    var i: u64 = 0;
    while (i < 12) : (i += 1) {
        // 40% success with high gap — should recommend increase.
        const accepted = i % 5 < 2;
        recordSample(100 + i, accepted, 5, 120, 80);
    }
    // After the 10th sample, analyze ran.
    try std.testing.expect(g_state.analyze_total >= 1);
    try std.testing.expect(g_state.last_rec.delay_ms > 0);
}

test "disabled autotune does nothing" {
    g_state = .{};
    g_state.enabled = false;
    recordSample(1, true, 1, 100, 50);
    try std.testing.expectEqual(@as(u32, 0), g_state.count);
}

test "high success ignores recommendation" {
    g_state = .{};
    g_state.enabled = true;
    g_state.emit = false;
    g_state.window = MAX_SAMPLES;
    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        recordSample(200 + i, true, 1, 100, 50);
    }
    try std.testing.expectEqual(@as(i32, 0), g_state.last_rec.delay_ms);
}
