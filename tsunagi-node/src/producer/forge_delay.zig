// Phase 9.2 — Adaptive Forge Delay
//
// Computes a per-slot forge delay (ms) from live network signals. Wraps
// the Phase 8.9 non-blocking gate with explicit env-driven tuning:
//
//   TSUNAGI_FORGE_DELAY_MS          base ms (default 0 = disabled)
//   TSUNAGI_FORGE_DELAY_ADAPTIVE    1 = adapt on signals (default 1 if base>0)
//   TSUNAGI_FORGE_DELAY_MIN_MS      floor (default 80)
//   TSUNAGI_FORGE_DELAY_MAX_MS      ceiling (default 300)
//
// Never blocks — compute() is pure. Hardfork guard caps delay at 150ms
// when the caller passes fork_pending=true.

const std = @import("std");
const compat = @import("compat");

const exec_quality = @import("exec_quality.zig");
const signals_mod = @import("signals.zig");
const presence = @import("presence.zig");

pub const Config = struct {
    base_ms: u32 = 0,
    adaptive: bool = false,
    min_ms: u32 = 80,
    max_ms: u32 = 300,
    presence_aware: bool = false,
};

pub const State = struct {
    mu: compat.Mutex = .{},
    cfg: Config = .{},
    last_delay_ms: u32 = 0,
    last_reason: [32]u8 = [_]u8{0} ** 32,
    last_reason_len: u8 = 0,
    last_slot: u64 = 0,
    last_presence_adjustment_ms: i32 = 0,
    last_presence_p50_ms: u32 = 0,
    last_presence_p90_ms: u32 = 0,
};

pub var g_state: State = .{};

pub fn initFromEnv() void {
    var cfg = Config{};
    if (compat.getenv("TSUNAGI_FORGE_DELAY_MS")) |v| {
        cfg.base_ms = std.fmt.parseUnsigned(u32, std.mem.trim(u8, v, " \t"), 10) catch 0;
    }
    if (compat.getenv("TSUNAGI_FORGE_DELAY_ADAPTIVE")) |v| {
        cfg.adaptive = std.mem.eql(u8, std.mem.trim(u8, v, " \t"), "1");
    } else {
        // Default: adaptive on when base>0
        cfg.adaptive = cfg.base_ms > 0;
    }
    if (compat.getenv("TSUNAGI_FORGE_DELAY_MIN_MS")) |v| {
        cfg.min_ms = std.fmt.parseUnsigned(u32, std.mem.trim(u8, v, " \t"), 10) catch 80;
    }
    if (compat.getenv("TSUNAGI_FORGE_DELAY_MAX_MS")) |v| {
        cfg.max_ms = std.fmt.parseUnsigned(u32, std.mem.trim(u8, v, " \t"), 10) catch 300;
    }
    if (cfg.max_ms < cfg.min_ms) cfg.max_ms = cfg.min_ms;
    // Safety lock: default OFF. Operator must explicitly opt in via
    // TSUNAGI_FORGE_DELAY_PRESENCE=1. Even when enabled, presence adjustment
    // only activates once sample_count >= 3 inside compute(), and the result
    // stays within [min_ms, max_ms].
    cfg.presence_aware = false;
    if (compat.getenv("TSUNAGI_FORGE_DELAY_PRESENCE")) |v| {
        cfg.presence_aware = std.mem.eql(u8, std.mem.trim(u8, v, " \t"), "1");
    }

    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.cfg = cfg;

    if (cfg.base_ms > 0) {
        std.debug.print("FORGE_DELAY_CONFIG: base_ms={d} adaptive={s} presence={s} min_ms={d} max_ms={d}\n", .{
            cfg.base_ms,
            if (cfg.adaptive) "true" else "false",
            if (cfg.presence_aware) "true" else "false",
            cfg.min_ms,
            cfg.max_ms,
        });
    }
}

pub fn config() Config {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    return g_state.cfg;
}

pub const Decision = struct {
    delay_ms: u32,
    reason: []const u8,
    base_ms: u32,
    gap: i32,
    latency_ms: u32,
    advantage: i32,
    confidence_x1000: u32,
    presence_adjustment_ms: i32 = 0,
    presence_p50_ms: u32 = 0,
    presence_p90_ms: u32 = 0,
};

/// Compute adaptive delay in ms. Safe to call every tick.
/// fork_pending caps the result at 150 ms regardless of config.
pub fn compute(fork_pending: bool) Decision {
    const cfg = config();
    if (cfg.base_ms == 0) {
        return .{
            .delay_ms = 0,
            .reason = "disabled",
            .base_ms = 0,
            .gap = 0,
            .latency_ms = 0,
            .advantage = 0,
            .confidence_x1000 = 0,
        };
    }

    const eq = exec_quality.currentScore();
    const gap: i32 = eq.parent_gap;
    const lat: u32 = eq.latency_ms;
    const adv: i32 = eq.probe_advantage;

    // Aggregate confidence across 6 signals (simple arithmetic mean).
    const sigs = signals_mod.currentSignals();
    var conf_sum: f64 = 0.0;
    for (sigs) |s| conf_sum += s.confidence;
    const conf: f64 = conf_sum / 6.0;
    const conf_x1000: u32 = @intFromFloat(@round(conf * 1000.0));

    var delay: i64 = @intCast(cfg.base_ms);
    var reason: []const u8 = "base";

    if (!cfg.adaptive) {
        reason = "fixed";
    } else if (conf < 0.5) {
        // Noisy signals — fall back to base.
        reason = "low_confidence";
    } else if (adv >= 60 and gap <= 2) {
        delay = @as(i64, @intCast(cfg.base_ms)) - 40;
        reason = "probe_strong";
    } else if (adv < 30) {
        delay = @as(i64, @intCast(cfg.base_ms)) + 80;
        reason = "probe_weak";
    } else {
        // Mixed regime: scale on latency. lat is ms; /10 gives a mild ramp.
        delay = @as(i64, @intCast(cfg.base_ms)) + @divFloor(@as(i64, @intCast(@min(lat, 500))), 10);
        reason = "latency_scaled";
    }

    // Phase 10.1: presence-aware adjustment. Applied AFTER the adaptive
    // rules but BEFORE clamp/hardfork-guard, so the min/max still bind.
    // Only applied when sample_count >= 3 to avoid acting on noise.
    var presence_delta: i32 = 0;
    var presence_p50: u32 = 0;
    var presence_p90: u32 = 0;
    if (cfg.presence_aware) {
        presence.g_state.mu.lock();
        const p50 = presence.g_state.p50_notice_ms;
        const p90 = presence.g_state.p90_notice_ms;
        const samples = presence.g_state.sample_count;
        presence.g_state.mu.unlock();

        if (samples >= 3) {
            presence_p50 = p50;
            presence_p90 = p90;
            if (p50 > 200) {
                presence_delta += 20;
            } else if (p50 < 80 and p50 > 0) {
                presence_delta -= 10;
            }
            if (p90 > 500) {
                presence_delta += 30;
            }
            delay += presence_delta;
            if (presence_delta != 0) {
                // Reason string stays whatever adaptive logic picked, but we
                // surface the presence contribution separately for the log.
            }
        }
    }

    // Clamp.
    if (delay < @as(i64, @intCast(cfg.min_ms))) delay = @intCast(cfg.min_ms);
    if (delay > @as(i64, @intCast(cfg.max_ms))) delay = @intCast(cfg.max_ms);

    // Hardfork guard.
    if (fork_pending and delay > 150) {
        delay = 150;
        reason = "hardfork_guard";
    }

    return .{
        .delay_ms = @intCast(delay),
        .reason = reason,
        .base_ms = cfg.base_ms,
        .gap = gap,
        .latency_ms = lat,
        .advantage = adv,
        .confidence_x1000 = conf_x1000,
        .presence_adjustment_ms = presence_delta,
        .presence_p50_ms = presence_p50,
        .presence_p90_ms = presence_p90,
    };
}

/// Record the delay that was applied for a given slot (for status + dedup).
pub fn record(slot: u64, d: Decision) void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.last_slot = slot;
    g_state.last_delay_ms = d.delay_ms;
    const n = @min(d.reason.len, g_state.last_reason.len);
    @memcpy(g_state.last_reason[0..n], d.reason[0..n]);
    g_state.last_reason_len = @intCast(n);
    g_state.last_presence_adjustment_ms = d.presence_adjustment_ms;
    g_state.last_presence_p50_ms = d.presence_p50_ms;
    g_state.last_presence_p90_ms = d.presence_p90_ms;
}

pub fn renderJson(buf: []u8) usize {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    var w = compat.fixedBufferStream(buf);
    w.writer().print(
        \\{{"base_ms":{d},"adaptive":{s},"presence_aware":{s},"min_ms":{d},"max_ms":{d},"last_delay_ms":{d},"last_reason":"{s}","last_slot":{d},"presence_adjustment":{d},"presence_p50_ms":{d},"presence_p90_ms":{d}}}
    , .{
        g_state.cfg.base_ms,
        if (g_state.cfg.adaptive) "true" else "false",
        if (g_state.cfg.presence_aware) "true" else "false",
        g_state.cfg.min_ms,
        g_state.cfg.max_ms,
        g_state.last_delay_ms,
        g_state.last_reason[0..g_state.last_reason_len],
        g_state.last_slot,
        g_state.last_presence_adjustment_ms,
        g_state.last_presence_p50_ms,
        g_state.last_presence_p90_ms,
    }) catch {};
    return w.pos;
}

test "compute disabled when base_ms=0" {
    g_state.cfg = .{ .base_ms = 0, .adaptive = false, .min_ms = 80, .max_ms = 300 };
    const d = compute(false);
    try std.testing.expectEqual(@as(u32, 0), d.delay_ms);
    try std.testing.expectEqualStrings("disabled", d.reason);
}

test "hardfork guard caps at 150" {
    g_state.cfg = .{ .base_ms = 300, .adaptive = false, .min_ms = 80, .max_ms = 500 };
    const d = compute(true);
    try std.testing.expect(d.delay_ms <= 150);
}
