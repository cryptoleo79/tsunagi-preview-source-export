// Phase 8.65 + 8.66 — Signal Layer with Validation
//
// Normalizes raw metrics from exec_quality + adaptive + internal fork
// counter into [0,1] signals. Each signal is traceable:
//   - raw source logged (SIGNAL_RAW)
//   - normalization method logged (SIGNAL_NORM)
//   - out-of-bound / anomaly guards (SIGNAL_ERROR/SIGNAL_WARNING)
//   - cross-signal conflicts (SIGNAL_CONFLICT)
//   - historical drift (SIGNAL_DRIFT)
//   - per-signal confidence (1 - variance / max_variance)
//
// Observation-only. Does not mutate upstream modules.

const std = @import("std");
const compat = @import("compat");
const exec_quality = @import("exec_quality.zig");
const adaptive = @import("adaptive.zig");

/// Fork event ring — recent fork timestamps.
const FORK_WINDOW: usize = 32;
const FORK_LOOKBACK_S: i64 = 100;

/// Drift / confidence history window per signal.
const HISTORY_LEN: usize = 50;

/// Throttle for SIGNAL_EMIT / SIGNAL_RAW / SIGNAL_NORM log emission.
const LOG_THROTTLE_S: i64 = 60;

/// Drift threshold: |current - mean| > 0.2 emits SIGNAL_DRIFT.
const DRIFT_THRESHOLD: f64 = 0.2;

pub const SignalName = enum(u8) {
    parent_freshness = 0,
    latency = 1,
    acceptance = 2,
    probe_advantage = 3,
    fork_density = 4,
    stability = 5,

    pub fn str(self: SignalName) []const u8 {
        return switch (self) {
            .parent_freshness => "parent_freshness",
            .latency => "latency",
            .acceptance => "acceptance",
            .probe_advantage => "probe_advantage",
            .fork_density => "fork_density",
            .stability => "stability",
        };
    }
};

pub const Signal = struct {
    name: SignalName,
    value: f64, // normalized [0,1]
    weight: f64,
    confidence: f64, // [0,1]
    raw: f64,
    mean: f64,
    drift: f64,
};

pub const Conflict = struct {
    name_buf: [48]u8 = std.mem.zeroes([48]u8),
    name_len: u8 = 0,
};

pub const DriftItem = struct {
    name: SignalName,
    drift: f64,
};

/// Fixed weights (sum = 1.0).
const W_PARENT_FRESHNESS: f64 = 0.25;
const W_LATENCY: f64 = 0.15;
const W_ACCEPTANCE: f64 = 0.25;
const W_PROBE_ADVANTAGE: f64 = 0.10;
const W_FORK_DENSITY: f64 = 0.15;
const W_STABILITY: f64 = 0.10;

/// Max variance for a random variable in [0,1]: 0.25 (half-at-0, half-at-1).
const MAX_VARIANCE: f64 = 0.25;

const ForkState = struct {
    mu: compat.Mutex = .{},
    ring: [FORK_WINDOW]i64 = [_]i64{0} ** FORK_WINDOW,
    head: u32 = 0,
    total: u64 = 0,
};

const HistoryState = struct {
    mu: compat.Mutex = .{},
    rings: [6][HISTORY_LEN]f64 = [_][HISTORY_LEN]f64{[_]f64{0} ** HISTORY_LEN} ** 6,
    heads: [6]u32 = [_]u32{0} ** 6,
    counts: [6]u32 = [_]u32{0} ** 6,
    last_log_unix: i64 = 0,
};

var g_fork: ForkState = .{};
var g_hist: HistoryState = .{};

fn nowUnixS() i64 {
    return compat.timestamp();
}

fn clamp01(x: f64) f64 {
    if (x < 0.0) return 0.0;
    if (x > 1.0) return 1.0;
    return x;
}

pub fn recordForkEvent() void {
    g_fork.mu.lock();
    defer g_fork.mu.unlock();
    const idx = g_fork.head % FORK_WINDOW;
    g_fork.ring[idx] = nowUnixS();
    g_fork.head +%= 1;
    g_fork.total += 1;
}

fn recentForkCount() u32 {
    g_fork.mu.lock();
    defer g_fork.mu.unlock();
    const cutoff = nowUnixS() - FORK_LOOKBACK_S;
    var n: u32 = 0;
    for (g_fork.ring) |t| {
        if (t > cutoff) n += 1;
    }
    return n;
}

// ── Normalizers (each returns [0,1], each has a named method) ──

fn parentFreshnessSignal(parent_gap: i32) f64 {
    if (parent_gap <= 0) return 1.0;
    if (parent_gap >= 20) return 0.0;
    return clamp01(1.0 - @as(f64, @floatFromInt(parent_gap)) / 20.0);
}
fn latencySignal(latency_ms: u32) f64 {
    if (latency_ms >= 1000) return 0.0;
    return clamp01(1.0 - @as(f64, @floatFromInt(latency_ms)) / 1000.0);
}
fn acceptanceSignal(rate_x1000: u32) f64 {
    return clamp01(@as(f64, @floatFromInt(rate_x1000)) / 1000.0);
}
fn probeAdvantageSignal(advantage: i32) f64 {
    if (advantage <= 0) return 0.0;
    if (advantage >= 100) return 1.0;
    return clamp01(@as(f64, @floatFromInt(advantage)) / 100.0);
}
fn forkDensitySignal(forks: u32) f64 {
    if (forks >= 10) return 0.0;
    return clamp01(1.0 - @as(f64, @floatFromInt(forks)) / 10.0);
}
fn stabilitySignal(built: u64, rejected: u64) f64 {
    const denom: u64 = if (built == 0) 1 else built;
    return clamp01(1.0 - @as(f64, @floatFromInt(rejected)) / @as(f64, @floatFromInt(denom)));
}

fn methodStr(n: SignalName) []const u8 {
    return switch (n) {
        .parent_freshness => "linear_gap_to_20",
        .latency => "linear_ms_to_1000_inverse",
        .acceptance => "rate_div_1000",
        .probe_advantage => "advantage_div_100",
        .fork_density => "linear_forks_to_10_inverse",
        .stability => "1_minus_rejected_over_built",
    };
}

// ── History / drift / variance ──

fn pushHistoryUnlocked(idx: usize, v: f64) void {
    const head = g_hist.heads[idx] % HISTORY_LEN;
    g_hist.rings[idx][head] = v;
    g_hist.heads[idx] +%= 1;
    if (g_hist.counts[idx] < HISTORY_LEN) g_hist.counts[idx] += 1;
}

fn meanAndVariance(idx: usize) struct { mean: f64, variance: f64 } {
    const count = g_hist.counts[idx];
    if (count == 0) return .{ .mean = 0.0, .variance = 0.0 };
    var sum: f64 = 0.0;
    var i: u32 = 0;
    while (i < count) : (i += 1) sum += g_hist.rings[idx][i];
    const mean = sum / @as(f64, @floatFromInt(count));
    var ss: f64 = 0.0;
    i = 0;
    while (i < count) : (i += 1) {
        const d = g_hist.rings[idx][i] - mean;
        ss += d * d;
    }
    const variance = ss / @as(f64, @floatFromInt(count));
    return .{ .mean = mean, .variance = variance };
}

// ── Sanity / anomaly on raw values ──

fn rawAnomaly(name: SignalName, raw: f64) bool {
    return switch (name) {
        .parent_freshness => raw > 1000.0 or raw < -1000.0, // slots
        .latency => raw > 60_000.0, // ms
        .acceptance => raw > 1001.0, // x1000 scale
        .probe_advantage => raw > 101.0 or raw < -1.0,
        .fork_density => raw > 1000.0,
        .stability => raw > 1.0 or raw < 0.0,
    };
}

// ── Public compute ──

pub fn currentSignals() [6]Signal {
    const eq = exec_quality.currentScore();
    const ad = adaptive.currentSnapshot();
    const forks = recentForkCount();

    // Raw values (in their source units, not normalized)
    const raws: [6]f64 = .{
        @floatFromInt(eq.parent_gap),
        @floatFromInt(eq.latency_ms),
        @floatFromInt(ad.success_rate_x1000),
        @floatFromInt(eq.probe_advantage),
        @floatFromInt(forks),
        if (ad.blocks_built == 0) 1.0 else 1.0 - @as(f64, @floatFromInt(ad.blocks_rejected)) / @as(f64, @floatFromInt(ad.blocks_built)),
    };

    // Normalized values
    const vals: [6]f64 = .{
        parentFreshnessSignal(eq.parent_gap),
        latencySignal(eq.latency_ms),
        acceptanceSignal(ad.success_rate_x1000),
        probeAdvantageSignal(eq.probe_advantage),
        forkDensitySignal(forks),
        stabilitySignal(ad.blocks_built, ad.blocks_rejected),
    };

    const weights: [6]f64 = .{
        W_PARENT_FRESHNESS, W_LATENCY, W_ACCEPTANCE, W_PROBE_ADVANTAGE, W_FORK_DENSITY, W_STABILITY,
    };
    const names: [6]SignalName = .{
        .parent_freshness, .latency, .acceptance, .probe_advantage, .fork_density, .stability,
    };

    // Push into history, compute mean/variance/confidence.
    g_hist.mu.lock();
    defer g_hist.mu.unlock();

    var out: [6]Signal = undefined;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        pushHistoryUnlocked(i, vals[i]);
        const stat = meanAndVariance(i);
        const drift = @abs(vals[i] - stat.mean);
        const conf = clamp01(1.0 - stat.variance / MAX_VARIANCE);
        out[i] = .{
            .name = names[i],
            .value = vals[i],
            .weight = weights[i],
            .confidence = conf,
            .raw = raws[i],
            .mean = stat.mean,
            .drift = drift,
        };
    }
    return out;
}

// ── Conflict detection (cross-signal) ──

const ConflictList = struct {
    items: [4]Conflict = [_]Conflict{.{}} ** 4,
    count: u8 = 0,

    fn push(self: *ConflictList, name: []const u8) void {
        if (self.count >= 4) return;
        const len = @min(name.len, 48);
        @memcpy(self.items[self.count].name_buf[0..len], name[0..len]);
        self.items[self.count].name_len = @intCast(len);
        self.count += 1;
    }
};

fn detectConflicts(sigs: [6]Signal) ConflictList {
    var out = ConflictList{};
    const pf = sigs[0].value;
    const pa = sigs[3].value;
    const lat_raw = sigs[1].raw; // ms
    const pg_raw = sigs[0].raw; // slots

    // freshness high but probe_advantage low — probe isn't actually helping
    if (pf > 0.8 and pa < 0.2) out.push("freshness_vs_advantage");
    // latency low (good) but parent_gap high (bad) — measurement mismatch
    if (lat_raw < 100.0 and pg_raw > 10.0) out.push("latency_vs_gap");

    return out;
}

// ── Logging ──

pub fn maybeLog() void {
    g_hist.mu.lock();
    const now = nowUnixS();
    if (now - g_hist.last_log_unix < LOG_THROTTLE_S) {
        g_hist.mu.unlock();
        return;
    }
    g_hist.last_log_unix = now;
    g_hist.mu.unlock();

    const sigs = currentSignals();

    for (sigs) |s| {
        // SIGNAL_EMIT — back-compat summary
        std.debug.print("SIGNAL_EMIT: name={s} value={d:.3} weight={d:.2} confidence={d:.3}\n", .{
            s.name.str(), s.value, s.weight, s.confidence,
        });
        // SIGNAL_RAW — traceable raw source
        std.debug.print("SIGNAL_RAW: name={s} raw={d:.3}\n", .{ s.name.str(), s.raw });
        // SIGNAL_NORM — normalization trace
        std.debug.print("SIGNAL_NORM: name={s} raw={d:.3} normalized={d:.4} method={s}\n", .{
            s.name.str(), s.raw, s.value, methodStr(s.name),
        });
        // SIGNAL_CONFIDENCE — variance-derived
        std.debug.print("SIGNAL_CONFIDENCE: name={s} confidence={d:.3} mean={d:.3} drift={d:.3}\n", .{
            s.name.str(), s.confidence, s.mean, s.drift,
        });
        // Guards
        if (s.value < 0.0 or s.value > 1.0) {
            std.debug.print("SIGNAL_ERROR: out_of_bounds name={s} value={d}\n", .{ s.name.str(), s.value });
        }
        if (rawAnomaly(s.name, s.raw)) {
            std.debug.print("SIGNAL_WARNING: anomaly_detected name={s} raw={d:.3}\n", .{ s.name.str(), s.raw });
        }
        if (s.drift > DRIFT_THRESHOLD) {
            std.debug.print("SIGNAL_DRIFT: name={s} drift={d:.3} current={d:.3} mean={d:.3}\n", .{
                s.name.str(), s.drift, s.value, s.mean,
            });
        }
    }

    const conflicts = detectConflicts(sigs);
    var i: u8 = 0;
    while (i < conflicts.count) : (i += 1) {
        const c = conflicts.items[i];
        std.debug.print("SIGNAL_CONFLICT: {s}\n", .{c.name_buf[0..c.name_len]});
    }
}

// ── /status JSON render ──

pub fn renderJson(buf: []u8) usize {
    const sigs = currentSignals();
    const conflicts = detectConflicts(sigs);
    var w = compat.fixedBufferStream(buf);
    const out = w.writer();
    out.writeAll("{\"signals\":[") catch return w.pos;
    for (sigs, 0..) |s, i| {
        if (i > 0) out.writeAll(",") catch return w.pos;
        out.print(
            \\{{"name":"{s}","value":{d:.4},"weight":{d:.2},"confidence":{d:.3},"raw":{d:.3},"mean":{d:.3},"drift":{d:.3}}}
        , .{ s.name.str(), s.value, s.weight, s.confidence, s.raw, s.mean, s.drift }) catch return w.pos;
    }
    out.writeAll("],\"conflicts\":[") catch return w.pos;
    var ci: u8 = 0;
    while (ci < conflicts.count) : (ci += 1) {
        if (ci > 0) out.writeAll(",") catch return w.pos;
        const c = conflicts.items[ci];
        out.print("\"{s}\"", .{c.name_buf[0..c.name_len]}) catch return w.pos;
    }
    out.writeAll("],\"drift\":[") catch return w.pos;
    var first_drift = true;
    for (sigs) |s| {
        if (s.drift > DRIFT_THRESHOLD) {
            if (!first_drift) out.writeAll(",") catch return w.pos;
            first_drift = false;
            out.print(
                \\{{"name":"{s}","drift":{d:.3}}}
            , .{ s.name.str(), s.drift }) catch return w.pos;
        }
    }
    out.print("],\"fork_events_total\":{d}}}", .{g_fork.total}) catch return w.pos;
    return w.pos;
}

// ── Tests ──

test "weights sum to 1.0" {
    const sum = W_PARENT_FRESHNESS + W_LATENCY + W_ACCEPTANCE + W_PROBE_ADVANTAGE + W_FORK_DENSITY + W_STABILITY;
    try std.testing.expect(sum > 0.999 and sum < 1.001);
}

test "parent freshness bounds" {
    try std.testing.expectEqual(@as(f64, 1.0), parentFreshnessSignal(0));
    try std.testing.expectEqual(@as(f64, 0.0), parentFreshnessSignal(20));
    try std.testing.expectEqual(@as(f64, 0.5), parentFreshnessSignal(10));
}

test "confidence: constant values → high confidence" {
    // Reset history
    g_hist.counts = [_]u32{0} ** 6;
    g_hist.heads = [_]u32{0} ** 6;
    // Push same value many times
    var i: u32 = 0;
    while (i < 30) : (i += 1) {
        g_hist.mu.lock();
        pushHistoryUnlocked(0, 0.5);
        g_hist.mu.unlock();
    }
    g_hist.mu.lock();
    const stat = meanAndVariance(0);
    g_hist.mu.unlock();
    try std.testing.expect(stat.variance < 0.001);
    const conf = clamp01(1.0 - stat.variance / MAX_VARIANCE);
    try std.testing.expect(conf > 0.99);
}
