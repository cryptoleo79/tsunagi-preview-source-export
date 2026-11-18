// Phase 9 — Decision Engine (Bayesian + EV + Kelly + LLR)
//
// Observe-only decision-theoretic summary of forge outcomes. Tracks success/
// failure as Beta(alpha, beta) posterior; derives EV, Kelly fraction, LLR.
// Emits advisories when EV crosses user-set thresholds. Never affects forge.

const std = @import("std");
const compat = @import("compat");

const LOG_THROTTLE_S: i64 = 60;
const EV_REWARD: f64 = 1.0;
const EV_COST: f64 = 1.0;
const EV_UNFAVORABLE_BELOW: f64 = -0.1;
const EV_FAVORABLE_ABOVE: f64 = 0.5;

pub const Advisory = enum(u8) {
    none = 0,
    unfavorable = 1,
    favorable = 2,
};

pub const Snapshot = struct {
    alpha: u64 = 1, // prior +1 smoothing (Beta(1,1) uniform)
    beta: u64 = 1,
    posterior_x1000: u32 = 500,
    ev_x1000: i32 = 0,
    kelly_x1000: i32 = 0,
    llr_x1000: i32 = 0,
    advisory: Advisory = .none,
};

const State = struct {
    mu: compat.Mutex = .{},
    alpha: u64 = 1,
    beta: u64 = 1,
    last_log_unix: i64 = 0,
};

var g_state: State = .{};

pub fn onSuccess() void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.alpha += 1;
}

pub fn onFailure() void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.beta += 1;
}

fn computeUnlocked() Snapshot {
    const a: f64 = @floatFromInt(g_state.alpha);
    const b: f64 = @floatFromInt(g_state.beta);
    const posterior = a / (a + b);
    const ev = (posterior * EV_REWARD) - ((1.0 - posterior) * EV_COST);
    // kelly = posterior - (1 - posterior) / odds
    // For even odds (odds=1), kelly = 2p - 1, clamp to [-1, 1]
    const odds: f64 = 1.0;
    var kelly = posterior - (1.0 - posterior) / odds;
    if (kelly > 1.0) kelly = 1.0;
    if (kelly < -1.0) kelly = -1.0;
    // LLR: log(p / (1-p)), with small epsilon to avoid log(0)
    const eps = 1e-9;
    const p_safe = @min(@max(posterior, eps), 1.0 - eps);
    const llr = @log(p_safe / (1.0 - p_safe));

    var advisory: Advisory = .none;
    if (ev < EV_UNFAVORABLE_BELOW) advisory = .unfavorable;
    if (ev > EV_FAVORABLE_ABOVE) advisory = .favorable;

    return .{
        .alpha = g_state.alpha,
        .beta = g_state.beta,
        .posterior_x1000 = @intFromFloat(@min(1000.0, @round(posterior * 1000.0))),
        .ev_x1000 = @intFromFloat(@round(ev * 1000.0)),
        .kelly_x1000 = @intFromFloat(@round(kelly * 1000.0)),
        .llr_x1000 = @intFromFloat(@round(llr * 1000.0)),
        .advisory = advisory,
    };
}

pub fn currentSnapshot() Snapshot {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    return computeUnlocked();
}

pub fn maybeLog() void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    const now = compat.timestamp();
    if (now - g_state.last_log_unix < LOG_THROTTLE_S) return;
    g_state.last_log_unix = now;

    const snap = computeUnlocked();
    std.debug.print("DECISION_METRICS: alpha={d} beta={d} posterior_x1000={d} ev_x1000={d} kelly_x1000={d} llr_x1000={d}\n", .{
        snap.alpha, snap.beta, snap.posterior_x1000, snap.ev_x1000, snap.kelly_x1000, snap.llr_x1000,
    });
    switch (snap.advisory) {
        .unfavorable => std.debug.print("DECISION_ADVISORY: unfavorable ev_x1000={d}\n", .{snap.ev_x1000}),
        .favorable => std.debug.print("DECISION_ADVISORY: favorable ev_x1000={d}\n", .{snap.ev_x1000}),
        .none => {},
    }
}

/// Render decision section for /status. Returns bytes written.
pub fn renderJson(buf: []u8) usize {
    const snap = currentSnapshot();
    var w = compat.fixedBufferStream(buf);
    w.writer().print(
        \\{{"alpha":{d},"beta":{d},"posterior_x1000":{d},"ev_x1000":{d},"kelly_x1000":{d},"llr_x1000":{d},"advisory":"{s}"}}
    , .{
        snap.alpha, snap.beta, snap.posterior_x1000, snap.ev_x1000, snap.kelly_x1000, snap.llr_x1000,
        switch (snap.advisory) {
            .none => "none",
            .unfavorable => "unfavorable",
            .favorable => "favorable",
        },
    }) catch {};
    return w.pos;
}

test "posterior with no data is 0.5" {
    // Reset
    g_state.alpha = 1;
    g_state.beta = 1;
    const s = currentSnapshot();
    try std.testing.expectEqual(@as(u32, 500), s.posterior_x1000);
}

test "posterior after successes > 0.5" {
    g_state.alpha = 10;
    g_state.beta = 2;
    const s = currentSnapshot();
    try std.testing.expect(s.posterior_x1000 > 500);
}
