// Phase 8.7 — Adaptive Behavior Engine
//
// Observe-only: tracks per-slot outcomes, computes rates, emits advisories.
// Never mutates forge state.

const std = @import("std");
const compat = @import("compat");
const decision = @import("decision.zig");

/// Slots to wait before declaring a built-but-unaccepted block rejected.
const REJECT_TIMEOUT_SLOTS: u64 = 30;
/// Throttle for ADAPTIVE_STATE log emission.
const LOG_THROTTLE_S: i64 = 30;

pub const Advice = enum(u8) {
    none = 0,
    improve_peer_selection = 1,
    reduce_latency = 2,
};

pub const Snapshot = struct {
    leaders_detected: u64 = 0,
    blocks_built: u64 = 0,
    blocks_accepted: u64 = 0,
    blocks_rejected: u64 = 0,
    success_rate_x1000: u32 = 0, // 0..1000
    avg_latency_ms: u32 = 0,
    avg_parent_gap: i32 = 0,
    advice: Advice = .none,
};

const State = struct {
    mu: compat.Mutex = .{},

    leaders_detected: u64 = 0,
    blocks_built: u64 = 0,
    blocks_accepted: u64 = 0,
    blocks_rejected: u64 = 0,

    last_build_slot: u64 = 0,
    last_build_unresolved: bool = false, // true = built, not yet accepted/rejected

    // Running averages
    latency_sum_ms: u64 = 0,
    latency_samples: u64 = 0,
    parent_gap_sum: i64 = 0,
    parent_gap_samples: u64 = 0,

    last_log_unix: i64 = 0,
};

var g_state: State = .{};

pub fn onLeaderDetected() void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.leaders_detected += 1;
}

pub fn onBlockBuilt(slot: u64) void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.blocks_built += 1;
    g_state.last_build_slot = slot;
    g_state.last_build_unresolved = true;
}

pub fn onBlockAccepted() void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.blocks_accepted += 1;
    g_state.last_build_unresolved = false;
}

pub fn recordLatency(latency_ms: u32) void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.latency_sum_ms += latency_ms;
    g_state.latency_samples += 1;
}

pub fn recordParentGap(gap: i32) void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.parent_gap_sum += gap;
    g_state.parent_gap_samples += 1;
}

/// Called every tick. Detects rejection-by-timeout and emits throttled log.
pub fn onTick(current_slot: u64) void {
    g_state.mu.lock();
    defer g_state.mu.unlock();

    // Rejection detection: if we built a block and REJECT_TIMEOUT_SLOTS have
    // passed without an acceptance, count it as rejected.
    if (g_state.last_build_unresolved and current_slot > g_state.last_build_slot + REJECT_TIMEOUT_SLOTS) {
        g_state.blocks_rejected += 1;
        g_state.last_build_unresolved = false;
        // Phase 9: feed Bayesian posterior with a failure observation.
        decision.onFailure();
    }

    // Throttled log + advisory
    const now = compat.timestamp();
    if (now - g_state.last_log_unix < LOG_THROTTLE_S) return;
    g_state.last_log_unix = now;

    const snap = computeUnlocked();
    std.debug.print("ADAPTIVE_STATE: leaders={d} built={d} accepted={d} rejected={d} success_rate_x1000={d} avg_latency_ms={d} avg_parent_gap={d}\n", .{
        snap.leaders_detected, snap.blocks_built, snap.blocks_accepted, snap.blocks_rejected,
        snap.success_rate_x1000, snap.avg_latency_ms, snap.avg_parent_gap,
    });
    switch (snap.advice) {
        .improve_peer_selection => std.debug.print("ADAPTIVE_ADVICE: improve_peer_selection (success_rate<20%)\n", .{}),
        .reduce_latency => std.debug.print("ADAPTIVE_ADVICE: reduce_latency (avg_latency>500ms)\n", .{}),
        .none => {},
    }
}

fn computeUnlocked() Snapshot {
    const built = g_state.blocks_built;
    const accepted = g_state.blocks_accepted;
    const rate: u32 = if (built == 0) 0 else @intCast(@min(1000, (accepted * 1000) / built));
    const avg_lat: u32 = if (g_state.latency_samples == 0) 0 else @intCast(@min(g_state.latency_sum_ms / g_state.latency_samples, 1_000_000));
    const avg_gap: i32 = if (g_state.parent_gap_samples == 0) 0 else @intCast(@divTrunc(g_state.parent_gap_sum, @as(i64, @intCast(g_state.parent_gap_samples))));

    var advice: Advice = .none;
    if (built >= 5 and rate < 200) advice = .improve_peer_selection;
    if (avg_lat > 500) advice = .reduce_latency;

    return .{
        .leaders_detected = g_state.leaders_detected,
        .blocks_built = built,
        .blocks_accepted = accepted,
        .blocks_rejected = g_state.blocks_rejected,
        .success_rate_x1000 = rate,
        .avg_latency_ms = avg_lat,
        .avg_parent_gap = avg_gap,
        .advice = advice,
    };
}

pub fn currentSnapshot() Snapshot {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    return computeUnlocked();
}

/// Render adaptive section for /status. Returns bytes written.
pub fn renderJson(buf: []u8) usize {
    const snap = currentSnapshot();
    var w = compat.fixedBufferStream(buf);
    w.writer().print(
        \\{{"leaders_detected":{d},"blocks_built":{d},"blocks_accepted":{d},"blocks_rejected":{d},"success_rate":"{d}.{d:0>3}","avg_latency_ms":{d},"avg_parent_gap":{d},"advice":"{s}"}}
    , .{
        snap.leaders_detected, snap.blocks_built, snap.blocks_accepted, snap.blocks_rejected,
        snap.success_rate_x1000 / 1000, snap.success_rate_x1000 % 1000,
        snap.avg_latency_ms, snap.avg_parent_gap,
        switch (snap.advice) {
            .none => "none",
            .improve_peer_selection => "improve_peer_selection",
            .reduce_latency => "reduce_latency",
        },
    }) catch {};
    return w.pos;
}
