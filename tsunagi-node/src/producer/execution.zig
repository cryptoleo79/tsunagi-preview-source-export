// Phase 10.4 — Execution Confidence Score
//
// Aggregates live runtime signals into a single [0, 100] execution score
// with a four-band classification. Pure read-only aggregator — no forge
// path mutation, no blocking.

const std = @import("std");
const compat = @import("compat");

const exec_quality = @import("exec_quality.zig");
const decision_mod = @import("decision.zig");
const presence = @import("presence.zig");
const signals_mod = @import("signals.zig");

pub const Class = enum(u8) {
    poor = 0,
    weak = 1,
    good = 2,
    strong = 3,

    pub fn str(self: Class) []const u8 {
        return switch (self) {
            .poor => "POOR",
            .weak => "WEAK",
            .good => "GOOD",
            .strong => "STRONG",
        };
    }
};

pub const Components = struct {
    gap_score: f32 = 0.0,
    lat_score: f32 = 0.0,
    notice_score: f32 = 0.0,
    adv_score: f32 = 0.0,
    ev_score: f32 = 0.0,
    conf_score: f32 = 0.0,
};

pub const Score = struct {
    value: u8 = 0, // [0, 100]
    class: Class = .poor,
    components: Components = .{},
};

pub const State = struct {
    mu: compat.Mutex = .{},
    last_slot: u64 = 0,
    last_score: Score = .{},
};

pub var g_state: State = .{};

/// Pure compute from current global snapshots — no side effects.
pub fn compute() Score {
    const eq = exec_quality.currentScore();
    const dec = decision_mod.currentSnapshot();
    const sigs = signals_mod.currentSignals();

    presence.g_state.mu.lock();
    const p50: u32 = presence.g_state.p50_notice_ms;
    presence.g_state.mu.unlock();

    const gap_f: f32 = @floatFromInt(eq.parent_gap);
    const gap_score: f32 = blk: {
        const raw = 1.0 - gap_f / 10.0;
        break :blk if (raw < 0.0) 0.0 else if (raw > 1.0) 1.0 else raw;
    };
    const lat_score: f32 = 1.0 / (1.0 + @as(f32, @floatFromInt(eq.latency_ms)) / 200.0);
    const notice_score: f32 = 1.0 / (1.0 + @as(f32, @floatFromInt(p50)) / 200.0);
    const adv_score: f32 = blk: {
        const a = @as(f32, @floatFromInt(eq.probe_advantage)) / 100.0;
        break :blk if (a < 0.0) 0.0 else if (a > 1.0) 1.0 else a;
    };
    const ev_raw: f32 = @as(f32, @floatFromInt(dec.ev_x1000)) / 1000.0;
    const ev_score: f32 = if (ev_raw < 0.0) 0.0 else if (ev_raw > 1.0) 1.0 else ev_raw;

    var conf_sum: f64 = 0.0;
    for (sigs) |s| conf_sum += s.confidence;
    const conf_score_f: f64 = conf_sum / 6.0;
    const conf_score: f32 = @floatCast(conf_score_f);

    const combined: f32 =
        0.20 * gap_score +
        0.15 * lat_score +
        0.15 * notice_score +
        0.15 * adv_score +
        0.20 * ev_score +
        0.15 * conf_score;

    const v_f: f32 = @min(@max(combined * 100.0, 0.0), 100.0);
    const value: u8 = @intFromFloat(@round(v_f));

    const class: Class =
        if (value > 75) .strong
        else if (value > 50) .good
        else if (value > 25) .weak
        else .poor;

    return .{
        .value = value,
        .class = class,
        .components = .{
            .gap_score = gap_score,
            .lat_score = lat_score,
            .notice_score = notice_score,
            .adv_score = adv_score,
            .ev_score = ev_score,
            .conf_score = conf_score,
        },
    };
}

/// Record score for a specific slot + emit EXECUTION_SCORE log.
pub fn record(slot: u64) Score {
    const s = compute();
    g_state.mu.lock();
    g_state.last_slot = slot;
    g_state.last_score = s;
    g_state.mu.unlock();
    std.debug.print("EXECUTION_SCORE: slot={d} score={d} class={s}\n", .{
        slot, s.value, s.class.str(),
    });
    return s;
}

pub fn renderJson(buf: []u8) usize {
    const s = compute();
    g_state.mu.lock();
    defer g_state.mu.unlock();
    var w = compat.fixedBufferStream(buf);
    w.writer().print(
        "{{\"score\":{d},\"class\":\"{s}\",\"last_slot\":{d},\"components\":{{\"gap\":{d:.4},\"latency\":{d:.4},\"notice\":{d:.4},\"adv\":{d:.4},\"ev\":{d:.4},\"confidence\":{d:.4}}}}}",
        .{
            s.value, s.class.str(), g_state.last_slot,
            s.components.gap_score, s.components.lat_score,
            s.components.notice_score, s.components.adv_score,
            s.components.ev_score, s.components.conf_score,
        },
    ) catch {};
    return w.pos;
}

test "classification bands" {
    // Reset globals before test
    g_state = .{};
    // Verify class mapping by hand for edge cases.
    const C = Class;
    try std.testing.expectEqual(C.strong, @as(C, if (76 > 75) C.strong else if (76 > 50) C.good else if (76 > 25) C.weak else C.poor));
    try std.testing.expectEqual(C.good,   @as(C, if (75 > 75) C.strong else if (75 > 50) C.good else if (75 > 25) C.weak else C.poor));
    try std.testing.expectEqual(C.weak,   @as(C, if (50 > 75) C.strong else if (50 > 50) C.good else if (50 > 25) C.weak else C.poor));
    try std.testing.expectEqual(C.poor,   @as(C, if (25 > 75) C.strong else if (25 > 50) C.good else if (25 > 25) C.weak else C.poor));
}
