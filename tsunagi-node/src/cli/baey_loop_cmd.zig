const std = @import("std");
const compat = @import("compat");

// ── Action enum ─────────────────────────────────────────────────────

pub const Action = enum {
    Chill,
    Probe,
    SwitchPeer,
    ThrottleBackfill,
    SafeMode,
    Restart,

    pub fn label(self: Action) []const u8 {
        return switch (self) {
            .Chill => "Chill",
            .Probe => "Probe",
            .SwitchPeer => "SwitchPeer",
            .ThrottleBackfill => "ThrottleBackfill",
            .SafeMode => "SafeMode",
            .Restart => "Restart",
        };
    }
};

// ── Health Score ───────────────────────────────────────────────────

pub const HealthReason = enum(u8) {
    nominal = 0,
    stall = 1,
    ancestry_break = 2,
    density_low = 3,
    authority_low = 4,
    finality_low = 5,
    reorg_active = 6,
    decode_fail = 7,
    keepalive_timeout = 8,
    header_errors = 9,
    gap_losing = 10,
    insight_low_blocks = 11,

    pub fn label(self: HealthReason) []const u8 {
        return switch (self) {
            .nominal => "nominal",
            .stall => "stall",
            .ancestry_break => "ancestry_break",
            .density_low => "density_low",
            .authority_low => "authority_low",
            .finality_low => "finality_low",
            .reorg_active => "reorg_active",
            .decode_fail => "decode_fail",
            .keepalive_timeout => "keepalive_timeout",
            .header_errors => "header_errors",
            .gap_losing => "gap_losing",
            .insight_low_blocks => "insight_low_blocks",
        };
    }
};

pub const HealthResult = struct {
    score: u64,
    primary_reason: HealthReason,
    reason_flags: u16,

    pub fn band(self: HealthResult) []const u8 {
        if (self.score >= 80) return "GREEN";
        if (self.score >= 60) return "YELLOW";
        if (self.score >= 30) return "ORANGE";
        return "RED";
    }
};

fn computeHealth(input: PolicyInput) HealthResult {
    var score: u64 = 100;
    var flags: u16 = 0;
    var primary: HealthReason = .nominal;
    var primary_ded: u64 = 0;

    const Rule = struct { cond: bool, ded: u64, reason: HealthReason };
    const rules = [_]Rule{
        .{ .cond = input.stall_active > 0, .ded = 30, .reason = .stall },
        .{ .cond = input.ancestry_skip_delta > 0, .ded = 25, .reason = .ancestry_break },
        .{ .cond = input.density_rec_min > 0.0 and input.density_smoothed < input.density_rec_min, .ded = 20, .reason = .density_low },
        .{ .cond = input.authority_reorg_events_5m > 0, .ded = 20, .reason = .reorg_active },
        .{ .cond = input.authority_confidence < 0.95, .ded = 15, .reason = .authority_low },
        .{ .cond = input.authority_finality < 0.50, .ded = 15, .reason = .finality_low },
        .{ .cond = input.decode_fail_delta > 0, .ded = 15, .reason = .decode_fail },
        .{ .cond = input.keepalive_to_delta_5m > 0, .ded = 10, .reason = .keepalive_timeout },
        .{ .cond = input.header_err_delta_5m > 0, .ded = 10, .reason = .header_errors },
        .{ .cond = input.gap_win_rate < 0.30 and input.gap_keys_delta_5m > 0, .ded = 10, .reason = .gap_losing },
        .{ .cond = input.insight_blocks_last > 0 and input.insight_blocks_last < 3, .ded = 10, .reason = .insight_low_blocks },
    };

    inline for (rules) |r| {
        if (r.cond) {
            score -|= r.ded;
            flags |= @as(u16, 1) << @as(u4, @intCast(@intFromEnum(r.reason)));
            if (r.ded > primary_ded) {
                primary_ded = r.ded;
                primary = r.reason;
            }
        }
    }

    return .{ .score = score, .primary_reason = primary, .reason_flags = flags };
}

// ── Runtime State ──────────────────────────────────────────────────

pub const RuntimeState = enum(u8) {
    Healthy = 0,
    Degraded = 1,
    SafeMode = 2,
    Recovering = 3,

    pub fn label(self: RuntimeState) []const u8 {
        return switch (self) {
            .Healthy => "HEALTHY",
            .Degraded => "DEGRADED",
            .SafeMode => "SAFE_MODE",
            .Recovering => "RECOVERING",
        };
    }
};

const RuntimeStateMemory = struct {
    var g_state: RuntimeState = .Healthy;
    var g_ticks: u16 = 0;
    var g_healthy_streak: u8 = 0;
    var g_trend_down: u8 = 0;
    var g_prev_score_x1e6: u32 = 0;
    // Cached for writeLoopStats (set by step)
    var g_reason: []const u8 = "init";
    var g_health_score: u64 = 100;
    var g_health_band: []const u8 = "GREEN";
    var g_health_primary: []const u8 = "nominal";
    var g_health_flags: u16 = 0;

    fn step(policy_score: f64, health_score: u64, safe_mode_active: bool) []const u8 {
        const score_x1e6: u32 = @intFromFloat(@max(0.0, @min(1.0, policy_score)) * 1_000_000.0);

        // Track trend
        if (score_x1e6 < g_prev_score_x1e6) {
            g_trend_down +|= 1;
        } else {
            g_trend_down = 0;
        }

        // Track healthy streak
        if (health_score >= 90) {
            g_healthy_streak +|= 1;
        } else {
            g_healthy_streak = 0;
        }

        g_prev_score_x1e6 = score_x1e6;

        // Hard reset: any → Healthy if health ≥ 95 for 5+ ticks
        if (health_score >= 95 and g_healthy_streak >= 5) {
            return trans(.Healthy, "hard_reset");
        }

        return switch (g_state) {
            .Healthy => {
                if (safe_mode_active) return trans(.SafeMode, "safe_mode_file");
                if (policy_score > 0.20 or health_score < 80) return trans(.Degraded, "score_or_health");
                return stay("nominal");
            },
            .Degraded => {
                if (safe_mode_active) return trans(.SafeMode, "safe_mode_triggered");
                if (g_trend_down >= 3) return trans(.Recovering, "trend_improving");
                return stay("monitoring");
            },
            .SafeMode => {
                if (!safe_mode_active and policy_score < 0.40) return trans(.Recovering, "safe_mode_cleared");
                return stay("gated");
            },
            .Recovering => {
                if (safe_mode_active) return trans(.SafeMode, "safe_mode_reactivated");
                if (policy_score > 0.20 or health_score < 80) return trans(.Degraded, "regression");
                if (g_healthy_streak >= 3 and health_score >= 90) return trans(.Healthy, "recovered");
                return stay("improving");
            },
        };
    }

    fn trans(new: RuntimeState, reason: []const u8) []const u8 {
        g_state = new;
        g_ticks = 0;
        return reason;
    }

    fn stay(reason: []const u8) []const u8 {
        g_ticks +|= 1;
        return reason;
    }
};

// ── JSON helpers (lightweight substring parsing, no std.json) ───────

fn jsExtractU64(body: []const u8, key: []const u8) ?u64 {
    const pos = std.mem.indexOf(u8, body, key) orelse return null;
    var i = pos + key.len;
    // skip : whitespace optional "
    while (i < body.len and (body[i] == ':' or body[i] == ' ' or body[i] == '\t' or body[i] == '"')) : (i += 1) {}
    if (i >= body.len) return null;
    const start = i;
    while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseUnsigned(u64, body[start..i], 10) catch null;
}

fn jsExtractI64(body: []const u8, key: []const u8) ?i64 {
    const pos = std.mem.indexOf(u8, body, key) orelse return null;
    var i = pos + key.len;
    while (i < body.len and (body[i] == ':' or body[i] == ' ' or body[i] == '\t' or body[i] == '"')) : (i += 1) {}
    if (i >= body.len) return null;
    const neg = body[i] == '-';
    if (neg) i += 1;
    const start = i;
    while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    const val = std.fmt.parseUnsigned(u64, body[start..i], 10) catch return null;
    return if (neg) -@as(i64, @intCast(val)) else @as(i64, @intCast(val));
}

fn jsExtractF64(body: []const u8, key: []const u8) ?f64 {
    const pos = std.mem.indexOf(u8, body, key) orelse return null;
    var i = pos + key.len;
    // skip : whitespace and opening " (handles both "0.123" and raw 0.123)
    while (i < body.len and (body[i] == ':' or body[i] == ' ' or body[i] == '\t' or body[i] == '"')) : (i += 1) {}
    if (i >= body.len) return null;
    const start = i;
    while (i < body.len and ((body[i] >= '0' and body[i] <= '9') or body[i] == '.' or body[i] == '-')) : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseFloat(f64, body[start..i]) catch null;
}

// ── Adaptive Weights ────────────────────────────────────────────────

const AdaptiveWeights = struct {
    stall: f64 = 0.70,
    density: f64 = 0.90,
    header_err: f64 = 0.40,
    keepalive: f64 = 0.60,
    gap: f64 = 0.50,
    authority: f64 = 0.80,
    finality: f64 = 0.40,
};

fn clampWeight(v: f64, lo: f64, hi: f64) f64 {
    return @max(lo, @min(hi, v));
}

fn loadWeights(alloc: std.mem.Allocator, baey_dir: []const u8) AdaptiveWeights {
    var w = AdaptiveWeights{};
    const path = std.fmt.allocPrint(alloc, "{s}/weights.json", .{baey_dir}) catch return w;
    defer alloc.free(path);

    var f = compat.fs.cwd().openFile(path, .{}) catch return w;
    defer f.close();
    const data = f.deprecatedReader().readAllAlloc(alloc, 4096) catch return w;
    defer alloc.free(data);

    w.stall = parseJsonF64(data, "\"stall\"") orelse 0.70;
    w.density = parseJsonF64(data, "\"density\"") orelse 0.90;
    w.header_err = parseJsonF64(data, "\"header_err\"") orelse 0.40;
    w.keepalive = parseJsonF64(data, "\"keepalive\"") orelse 0.60;
    w.gap = parseJsonF64(data, "\"gap\"") orelse 0.50;
    w.authority = parseJsonF64(data, "\"authority\"") orelse 0.80;
    w.finality = parseJsonF64(data, "\"finality\"") orelse 0.40;

    w.stall = clampWeight(w.stall, 0.20, 0.95);
    w.density = clampWeight(w.density, 0.30, 0.95);
    w.header_err = clampWeight(w.header_err, 0.20, 0.95);
    w.keepalive = clampWeight(w.keepalive, 0.20, 0.95);
    w.gap = clampWeight(w.gap, 0.30, 0.80);
    w.authority = clampWeight(w.authority, 0.30, 0.95);
    w.finality = clampWeight(w.finality, 0.10, 0.80);

    return w;
}

fn saveWeights(alloc: std.mem.Allocator, baey_dir: []const u8, w: *const AdaptiveWeights) void {
    const path = std.fmt.allocPrint(alloc, "{s}/weights.json", .{baey_dir}) catch return;
    defer alloc.free(path);
    const tmp = std.fmt.allocPrint(alloc, "{s}/weights.json.tmp", .{baey_dir}) catch return;
    defer alloc.free(tmp);

    var f = compat.fs.cwd().createFile(tmp, .{}) catch return;
    const s_x1e6: u64 = @intFromFloat(w.stall * 1_000_000.0);
    const d_x1e6: u64 = @intFromFloat(w.density * 1_000_000.0);
    const h_x1e6: u64 = @intFromFloat(w.header_err * 1_000_000.0);
    const k_x1e6: u64 = @intFromFloat(w.keepalive * 1_000_000.0);
    const g_x1e6: u64 = @intFromFloat(w.gap * 1_000_000.0);
    const a_x1e6: u64 = @intFromFloat(w.authority * 1_000_000.0);
    const fn_x1e6: u64 = @intFromFloat(w.finality * 1_000_000.0);
    const wr = f.deprecatedWriter();
    wr.print(
        \\{{"stall":{d}.{d:0>6},"density":{d}.{d:0>6},"header_err":{d}.{d:0>6},"keepalive":{d}.{d:0>6},"gap":{d}.{d:0>6},
    , .{
        s_x1e6 / 1_000_000, s_x1e6 % 1_000_000,
        d_x1e6 / 1_000_000, d_x1e6 % 1_000_000,
        h_x1e6 / 1_000_000, h_x1e6 % 1_000_000,
        k_x1e6 / 1_000_000, k_x1e6 % 1_000_000,
        g_x1e6 / 1_000_000, g_x1e6 % 1_000_000,
    }) catch {};
    wr.print(
        \\"authority":{d}.{d:0>6},"finality":{d}.{d:0>6}}}
        \\
    , .{
        a_x1e6 / 1_000_000, a_x1e6 % 1_000_000,
        fn_x1e6 / 1_000_000, fn_x1e6 % 1_000_000,
    }) catch {};
    f.close();
    compat.fs.cwd().rename(tmp, path) catch {};
}

fn parseJsonF64(data: []const u8, key: []const u8) ?f64 {
    const pos = std.mem.indexOf(u8, data, key) orelse return null;
    var i = pos + key.len;
    while (i < data.len and (data[i] == ':' or data[i] == ' ')) : (i += 1) {}
    if (i >= data.len) return null;
    const start = i;
    while (i < data.len and ((data[i] >= '0' and data[i] <= '9') or data[i] == '.' or data[i] == '-')) : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseFloat(f64, data[start..i]) catch null;
}

fn adaptWeights(w: *AdaptiveWeights, input: PolicyInput, header_err_zero_minutes: u64) void {
    // Rule 1: consensus_health_score < 40 (density below threshold = poor health)
    if (input.density_rec_min > 0.0 and input.density_smoothed < input.density_rec_min * 0.40) {
        w.stall = clampWeight(w.stall + 0.05, 0.20, 0.95);
    }

    // Rule 2: gap losing (keys growing)
    if (input.gap_keys_delta_5m > 0) {
        w.gap = clampWeight(w.gap + 0.05, 0.30, 0.80);
    }

    // Rule 3: gap winning strongly
    if (input.gap_win_rate > 0.75) {
        w.gap = clampWeight(w.gap - 0.03, 0.30, 0.80);
    }

    // Rule 4: header errors quiet for 10+ minutes
    if (header_err_zero_minutes >= 10) {
        w.header_err = clampWeight(w.header_err - 0.02, 0.20, 0.95);
    }

    // Rule 5: authority confidence low → increase authority weight
    if (input.authority_confidence < 0.90) {
        w.authority = clampWeight(w.authority + 0.03, 0.30, 0.95);
    }

    // Rule 6: active reorgs → increase authority weight
    if (input.authority_reorg_events_5m > 0) {
        w.authority = clampWeight(w.authority + 0.05, 0.30, 0.95);
    }

    // Rule 7: high finality + no reorgs → relax authority weight
    if (input.authority_finality > 0.80 and input.authority_reorg_events_5m == 0) {
        w.authority = clampWeight(w.authority - 0.02, 0.30, 0.95);
    }
}

fn exportWeightsToMetrics(w: *const AdaptiveWeights) void {
    // Write to globals that http_metrics can read
    g_weight_stall = @intFromFloat(w.stall * 1_000_000.0);
    g_weight_density = @intFromFloat(w.density * 1_000_000.0);
    g_weight_header = @intFromFloat(w.header_err * 1_000_000.0);
    g_weight_keepalive = @intFromFloat(w.keepalive * 1_000_000.0);
    g_weight_gap = @intFromFloat(w.gap * 1_000_000.0);
    g_weight_authority = @intFromFloat(w.authority * 1_000_000.0);
    g_weight_finality = @intFromFloat(w.finality * 1_000_000.0);
}

// Global weight gauges (x1e6 encoded, read by http_metrics)
pub var g_weight_stall: u64 = 700_000;
pub var g_weight_density: u64 = 900_000;
pub var g_weight_header: u64 = 400_000;
pub var g_weight_keepalive: u64 = 600_000;
pub var g_weight_gap: u64 = 500_000;
pub var g_weight_authority: u64 = 800_000;
pub var g_weight_finality: u64 = 400_000;

// ── Policy engine ───────────────────────────────────────────────────

const PolicyInput = struct {
    stall_active: u64,
    density_smoothed: f64,
    density_rec_min: f64,
    header_err_delta_5m: u64,
    keepalive_to_delta_5m: u64,
    gap_win_rate: f64,
    gap_keys_delta_5m: i64,
    authority_confidence: f64,
    authority_finality: f64,
    authority_reorg_events_5m: u64,
    authority_fork_events_total: u64,
    // Producer leader signals
    producer_epoch: u64,
    producer_slot_in_epoch: u64,
    producer_eligible: u64,
    producer_prob_x1e6: u64,
    producer_expected_epoch: u64,
    producer_reason_code: u64,
    producer_stake_x1e9: u64,
    // Decode health signals (delta from previous tick)
    decode_fail_delta: u64 = 0,
    ancestry_skip_delta: u64 = 0,
    // Insight anomaly signals
    insight_blocks_last: u32 = 0, // blocks in last completed 5m window
    insight_fees_last: u64 = 0, // fees in last completed 5m window
};

const PolicyResult = struct {
    score: f64,
    action: Action,
};

fn computePolicy(input: PolicyInput, weights: *const AdaptiveWeights) PolicyResult {
    var score: f64 = 0.0;

    if (input.stall_active > 0) {
        score = @max(score, weights.stall);
    }
    if (input.density_rec_min > 0.0 and input.density_smoothed < input.density_rec_min) {
        score = @max(score, weights.density);
    }
    if (input.header_err_delta_5m > 0) {
        score = @max(score, weights.header_err);
    }
    if (input.keepalive_to_delta_5m > 0) {
        score = @max(score, weights.keepalive);
    }
    if (input.gap_win_rate < 0.30 and input.gap_keys_delta_5m > 0) {
        score = @max(score, weights.gap);
    }

    // Authority confidence suspicion
    if (input.authority_confidence < 0.95) {
        const auth_sus = weights.authority * (0.95 - input.authority_confidence) / 0.95;
        score = @max(score, auth_sus);
    }

    // Finality suspicion
    if (input.authority_finality < 0.50) {
        const fin_sus = weights.finality * (0.50 - input.authority_finality) / 0.50;
        score = @max(score, fin_sus);
    }

    // Decode health: ancestry breaks or decode failures indicate data integrity issues
    if (input.ancestry_skip_delta > 0) {
        score = @max(score, 0.30);
    }
    if (input.decode_fail_delta > 0) {
        score = @max(score, 0.20);
    }

    // Insight anomaly: last completed window had very few blocks (possible stall)
    if (input.insight_blocks_last > 0 and input.insight_blocks_last < 3) {
        score = @max(score, 0.25);
    }

    score = @max(0.0, @min(1.0, score));

    const action: Action = if (score >= 0.85)
        .SwitchPeer
    else if (score >= 0.60)
        .Probe
    else if (score >= 0.40)
        .ThrottleBackfill
    else
        .Chill;

    return .{ .score = score, .action = action };
}

// ── Fetch /state from running node ──────────────────────────────────

fn fetchState(alloc: std.mem.Allocator) ?[]u8 {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 9080) catch return null;
    const stream = blk: {
        var a = addr;
        break :blk a.connect(compat.defaultIo(), .{ .mode = .stream }) catch return null;
    };
    defer stream.close(compat.defaultIo());

    const w = compat.streamWriter(stream);
    w.writeAll("GET /state HTTP/1.1\r\nHost: 127.0.0.1:9080\r\nConnection: close\r\n\r\n") catch return null;

    // Persistent buffer reader for the protocol read (do NOT create a fresh
    // reader per byte — that would lose buffered data).
    var rbuf: [4096]u8 = undefined;
    var sr = compat.NetStream.Reader.init(stream, compat.defaultIo(), &rbuf);
    const raw = sr.interface.allocRemaining(alloc, std.Io.Limit.limited(512 * 1024)) catch return null;

    if (std.mem.indexOf(u8, raw, "\r\n\r\n")) |hdr_end| {
        const body = raw[hdr_end + 4 ..];
        const body_copy = alloc.alloc(u8, body.len) catch {
            alloc.free(raw);
            return null;
        };
        @memcpy(body_copy, body);
        alloc.free(raw);
        return body_copy;
    }

    alloc.free(raw);
    return null;
}

// ── Timing helpers ──────────────────────────────────────────────────

fn milliTimestamp() u64 {
    return @intCast(@divFloor(compat.milliTimestamp(), 1));
}

// ── Loop stats persistence (read by http_metrics) ───────────────────

fn writeLoopStats(alloc: std.mem.Allocator, baey_dir: []const u8, fetch_ms: u64, total_ms: u64, parse_ok: u64) void {
    const path = std.fmt.allocPrint(alloc, "{s}/loop_stats.json", .{baey_dir}) catch return;
    defer alloc.free(path);
    const tmp = std.fmt.allocPrint(alloc, "{s}/loop_stats.json.tmp", .{baey_dir}) catch return;
    defer alloc.free(tmp);

    var f = compat.fs.cwd().createFile(tmp, .{}) catch return;
    const now: u64 = @intCast(@max(0, compat.timestamp()));
    f.deprecatedWriter().print(
        \\{{"unix":{d},"fetch_ms":{d},"total_ms":{d},"parse_ok":{d},"health_score":{d},"health_band":"{s}","health_primary":"{s}","health_flags":{d},"rt_state":"{s}","rt_ticks":{d},"rt_reason":"{s}"}}
        \\
    , .{
        now, fetch_ms, total_ms, parse_ok,
        RuntimeStateMemory.g_health_score, RuntimeStateMemory.g_health_band,
        RuntimeStateMemory.g_health_primary, RuntimeStateMemory.g_health_flags,
        RuntimeStateMemory.g_state.label(), RuntimeStateMemory.g_ticks, RuntimeStateMemory.g_reason,
    }) catch {};
    f.close();
    compat.fs.cwd().rename(tmp, path) catch {};
}

// ── BAEY log helpers (standalone, no Context) ───────────────────────

fn getBaeyDir(alloc: std.mem.Allocator) ?[]u8 {
    const home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch return null;
    defer alloc.free(home);
    const dir = std.fmt.allocPrint(alloc, "{s}/baey", .{home}) catch return null;
    compat.fs.cwd().makePath(dir) catch {};
    return dir;
}

fn openBaeyLog(alloc: std.mem.Allocator, baey_dir: []const u8) ?compat.fs.File {
    const path = std.fmt.allocPrint(alloc, "{s}/events.log", .{baey_dir}) catch return null;
    defer alloc.free(path);

    var file = compat.fs.cwd().openFile(path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => compat.fs.cwd().createFile(path, .{}) catch return null,
        else => return null,
    };
    file.seekFromEnd(0) catch {
        file.close();
        return null;
    };
    return file;
}

fn baeyLogPolicyTick(
    alloc: std.mem.Allocator,
    baey_dir: []const u8,
    input: PolicyInput,
    computed: PolicyResult,
    final_action: Action,
    leader_guard: bool,
    leader_guard_score: f64,
    lg_reason: u64,
    apply_mode: bool,
    fetch_ms: u64,
    total_ms: u64,
    parse_ok: u64,
) void {
    var file = openBaeyLog(alloc, baey_dir) orelse return;
    defer file.close();

    const now: i64 = compat.timestamp();
    const score_x1e6: u64 = @intFromFloat(@max(0.0, @min(1.0, computed.score)) * 1_000_000.0);
    const ds_x1e6: u64 = @intFromFloat(@max(0.0, @min(1.0, input.density_smoothed)) * 1_000_000.0);
    const wr_x1e6: u64 = @intFromFloat(@max(0.0, @min(99.0, input.gap_win_rate)) * 1_000_000.0);
    const ac_x1e6: u64 = @intFromFloat(@max(0.0, @min(1.0, input.authority_confidence)) * 1_000_000.0);
    const af_x1e6: u64 = @intFromFloat(@max(0.0, @min(1.0, input.authority_finality)) * 1_000_000.0);
    const lg_x1e6: u64 = @intFromFloat(@max(0.0, @min(1.0, leader_guard_score)) * 1_000_000.0);
    const mode_str: []const u8 = if (apply_mode) "apply" else "dry_run";

    const fw = file.deprecatedWriter();
    fw.print(
        \\{{"unix":{d},"kind":"policy_tick","mode":"{s}","score":"{d}.{d:0>6}","action":"{s}","stall":{d},"density":"{d}.{d:0>6}","header_err_delta":{d},"keepalive_delta":{d},"gap_delta":{d},"win_rate":"{d}.{d:0>6}",
    , .{
        now, mode_str,
        score_x1e6 / 1_000_000, score_x1e6 % 1_000_000,
        computed.action.label(),
        input.stall_active,
        ds_x1e6 / 1_000_000, ds_x1e6 % 1_000_000,
        input.header_err_delta_5m,
        input.keepalive_to_delta_5m,
        input.gap_keys_delta_5m,
        wr_x1e6 / 1_000_000, wr_x1e6 % 1_000_000,
    }) catch return;
    fw.print(
        \\"auth_conf":"{d}.{d:0>6}","auth_fin":"{d}.{d:0>6}","auth_reorg5m":{d},"auth_forks":{d},
    , .{
        ac_x1e6 / 1_000_000, ac_x1e6 % 1_000_000,
        af_x1e6 / 1_000_000, af_x1e6 % 1_000_000,
        input.authority_reorg_events_5m,
        input.authority_fork_events_total,
    }) catch return;
    fw.print(
        \\"producer_epoch":{d},"producer_slot_in_epoch":{d},"producer_prob_x1e6":{d},"producer_eligible":{d},"producer_expected_epoch":{d},"producer_reason_code":{d},"producer_stake_x1e9":{d},
    , .{
        input.producer_epoch,
        input.producer_slot_in_epoch,
        input.producer_prob_x1e6,
        input.producer_eligible,
        input.producer_expected_epoch,
        input.producer_reason_code,
        input.producer_stake_x1e9,
    }) catch return;
    fw.print(
        \\"leader_guard":{d},"leader_guard_score":"{d}.{d:0>6}","lg_reason":{d},"computed_action":"{s}","final_action":"{s}",
    , .{
        @as(u64, if (leader_guard) 1 else 0),
        lg_x1e6 / 1_000_000, lg_x1e6 % 1_000_000,
        lg_reason,
        computed.action.label(),
        final_action.label(),
    }) catch return;
    fw.print(
        \\"fetch_ms":{d},"total_ms":{d},"parse_ok":{d}}}
        \\
    , .{ fetch_ms, total_ms, parse_ok }) catch return;
}

fn baeyLogAction(alloc: std.mem.Allocator, baey_dir: []const u8, kind: []const u8, action: Action, score: f64, reason: []const u8) void {
    var file = openBaeyLog(alloc, baey_dir) orelse return;
    defer file.close();

    const now: i64 = compat.timestamp();
    const score_x1e6: u64 = @intFromFloat(@max(0.0, @min(1.0, score)) * 1_000_000.0);

    file.deprecatedWriter().print(
        \\{{"unix":{d},"kind":"{s}","action":"{s}","score":"{d}.{d:0>6}","reason":"{s}"}}
        \\
    , .{
        now, kind, action.label(),
        score_x1e6 / 1_000_000, score_x1e6 % 1_000_000,
        reason,
    }) catch return;
}

// ── Cooldown tracking ───────────────────────────────────────────────

const Cooldowns = struct {
    probe_s: u64 = 300, // 5 min
    switch_s: u64 = 1800, // 30 min
    throttle_s: u64 = 300, // 5 min
    safe_s: u64 = 1800, // 30 min

    last_probe_unix: i64 = 0,
    last_switch_unix: i64 = 0,
    last_throttle_unix: i64 = 0,
    last_safe_unix: i64 = 0,
};

fn readCooldownState(alloc: std.mem.Allocator, baey_dir: []const u8) Cooldowns {
    var cd = Cooldowns{};
    const path = std.fmt.allocPrint(alloc, "{s}/cooldown.json", .{baey_dir}) catch return cd;
    defer alloc.free(path);

    var f = compat.fs.cwd().openFile(path, .{}) catch return cd;
    defer f.close();
    const data = f.deprecatedReader().readAllAlloc(alloc, 4096) catch return cd;
    defer alloc.free(data);

    cd.last_probe_unix = parseJsonI64(data, "\"last_probe_unix\"");
    cd.last_switch_unix = parseJsonI64(data, "\"last_switch_unix\"");
    cd.last_throttle_unix = parseJsonI64(data, "\"last_throttle_unix\"");
    cd.last_safe_unix = parseJsonI64(data, "\"last_safe_unix\"");
    return cd;
}

fn writeCooldownState(alloc: std.mem.Allocator, baey_dir: []const u8, cd: *const Cooldowns) void {
    const path = std.fmt.allocPrint(alloc, "{s}/cooldown.json", .{baey_dir}) catch return;
    defer alloc.free(path);
    const tmp = std.fmt.allocPrint(alloc, "{s}/cooldown.json.tmp", .{baey_dir}) catch return;
    defer alloc.free(tmp);

    var f = compat.fs.cwd().createFile(tmp, .{}) catch return;
    f.deprecatedWriter().print(
        \\{{"last_probe_unix":{d},"last_switch_unix":{d},"last_throttle_unix":{d},"last_safe_unix":{d}}}
        \\
    , .{ cd.last_probe_unix, cd.last_switch_unix, cd.last_throttle_unix, cd.last_safe_unix }) catch {};
    f.close();
    compat.fs.cwd().rename(tmp, path) catch {};
}

fn parseJsonI64(data: []const u8, key: []const u8) i64 {
    const pos = std.mem.indexOf(u8, data, key) orelse return 0;
    var i = pos + key.len;
    while (i < data.len and (data[i] == ':' or data[i] == ' ')) : (i += 1) {}
    if (i >= data.len) return 0;
    const neg = data[i] == '-';
    if (neg) i += 1;
    const start = i;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {}
    const val = std.fmt.parseUnsigned(u64, data[start..i], 10) catch return 0;
    return if (neg) -@as(i64, @intCast(val)) else @as(i64, @intCast(val));
}

// ── Apply-mode action executors (file markers only) ─────────────────

fn applyProbe(alloc: std.mem.Allocator, baey_dir: []const u8) void {
    // Probe trigger: write probe_request.json consumed by follower
    const path = std.fmt.allocPrint(alloc, "{s}/probe_request.json", .{baey_dir}) catch return;
    defer alloc.free(path);
    var f = compat.fs.cwd().createFile(path, .{}) catch return;
    defer f.close();
    const now: i64 = compat.timestamp();
    f.deprecatedWriter().print(
        \\{{"unix":{d},"reason":"baey"}}
        \\
    , .{now}) catch {};
}

fn applySwitchPeer(alloc: std.mem.Allocator, baey_dir: []const u8, score: f64) void {
    const path = std.fmt.allocPrint(alloc, "{s}/switch_peer.json", .{baey_dir}) catch return;
    defer alloc.free(path);
    var f = compat.fs.cwd().createFile(path, .{}) catch return;
    defer f.close();
    const now: i64 = compat.timestamp();
    const sc_x1e6: u64 = @intFromFloat(@max(0.0, @min(1.0, score)) * 1_000_000.0);
    f.deprecatedWriter().print(
        \\{{"unix":{d},"reason":"baey","score":"{d}.{d:0>6}"}}
        \\
    , .{ now, sc_x1e6 / 1_000_000, sc_x1e6 % 1_000_000 }) catch {};
}

fn applyThrottleBackfill(alloc: std.mem.Allocator, baey_dir: []const u8, reason: []const u8) void {
    const path = std.fmt.allocPrint(alloc, "{s}/backfill_override.json", .{baey_dir}) catch return;
    defer alloc.free(path);
    var f = compat.fs.cwd().createFile(path, .{}) catch return;
    defer f.close();
    const now: u64 = @intCast(@max(0, compat.timestamp()));
    const expires = now + 300; // 5 minutes
    f.deprecatedWriter().print(
        \\{{"profile":0,"expires_unix":{d},"reason":"{s}"}}
        \\
    , .{ expires, reason }) catch {};
}

fn applySafeMode(alloc: std.mem.Allocator, baey_dir: []const u8) void {
    const path = std.fmt.allocPrint(alloc, "{s}/safe_mode.json", .{baey_dir}) catch return;
    defer alloc.free(path);
    var f = compat.fs.cwd().createFile(path, .{}) catch return;
    defer f.close();
    const now: i64 = compat.timestamp();
    f.deprecatedWriter().print(
        \\{{"enabled":true,"unix":{d}}}
        \\
    , .{now}) catch {};
}

// ── Public entry point ──────────────────────────────────────────────

pub fn run(alloc: std.mem.Allocator, apply_flag: bool) void {
    const t0 = milliTimestamp();

    // Determine effective apply mode: requires BOTH --apply AND TSUNAGI_BAEY_APPLY=1
    const env_apply = blk: {
        const v = compat.getEnvVarOwned(alloc, "TSUNAGI_BAEY_APPLY") catch break :blk false;
        defer alloc.free(v);
        break :blk !std.mem.eql(u8, v, "0") and v.len > 0;
    };
    const apply_mode = apply_flag and env_apply;

    if (apply_flag and !env_apply) {
        std.debug.print("BAEY Guardian: --apply set but TSUNAGI_BAEY_APPLY=1 not in env => dry-run\n", .{});
    }

    const mode_label: []const u8 = if (apply_mode) "APPLY" else "DRY-RUN";
    std.debug.print("BAEY Guardian [{s}]: fetching /state ...\n", .{mode_label});

    const raw = fetchState(alloc) orelse {
        std.debug.print("BAEY Guardian: cannot reach /state endpoint. Is the node running?\n", .{});
        return;
    };
    defer alloc.free(raw);
    const t_fetch = milliTimestamp();
    const fetch_ms = t_fetch - t0;

    // Parse inputs from /state JSON
    var parse_ok: u64 = 1;

    // Consensus block
    const stall = jsExtractU64(raw, "\"stall_active\"") orelse 0;
    const density_smoothed_opt = jsExtractF64(raw, "\"density_smoothed\"");
    const density_smoothed = density_smoothed_opt orelse 0.0;
    if (density_smoothed_opt == null) {
        std.debug.print("BAEY: parse missing consensus.density_smoothed, defaulting to 0.0\n", .{});
        parse_ok = 0;
    }
    const density_rec_min_opt = jsExtractF64(raw, "\"density_rec_min\"");
    const density_rec_min = density_rec_min_opt orelse 0.0;
    if (density_rec_min_opt == null) {
        std.debug.print("BAEY: parse missing consensus.density_rec_min, defaulting to 0.0\n", .{});
        parse_ok = 0;
    }
    const herr_delta = jsExtractU64(raw, "\"herr_delta_5m\"") orelse 0;
    const ka_delta = jsExtractU64(raw, "\"keepalive_to_delta_5m\"") orelse 0;

    // Gaps block
    const win_rate = jsExtractF64(raw, "\"win_rate\"") orelse 0.0;
    // delta_keys_5m is offset-encoded in /state: raw value has 10_000_000 added.
    // Decode: signed_delta = raw - 10_000_000
    const gap_delta_raw_u64 = jsExtractU64(raw, "\"delta_keys_5m\"") orelse 10_000_000;
    const gap_delta: i64 = @as(i64, @intCast(gap_delta_raw_u64)) - 10_000_000;

    // Authority block (real-time atomics)
    const auth_conf = jsExtractF64(raw, "\"confidence\"") orelse 0.0;
    const auth_fin = jsExtractF64(raw, "\"finality\"") orelse 0.0;
    const auth_reorg = jsExtractU64(raw, "\"reorg_events_5m\"") orelse 0;
    const auth_forks = jsExtractU64(raw, "\"fork_events_total\"") orelse 0;

    // Producer leader signals (from producer_leader block in /state)
    const prod_epoch = jsExtractU64(raw, "\"producer_epoch\"") orelse 0;
    const prod_sie = jsExtractU64(raw, "\"producer_slot_in_epoch\"") orelse 0;
    const prod_eligible = jsExtractU64(raw, "\"producer_eligible\"") orelse 0;
    const prod_prob = jsExtractU64(raw, "\"producer_prob_x1e6\"") orelse 0;
    const prod_exp_epoch = jsExtractU64(raw, "\"expected_leaders_per_epoch\"") orelse 0;
    const prod_reason = jsExtractU64(raw, "\"leader_reason_code\"") orelse 0;
    const prod_stake = jsExtractU64(raw, "\"stake_fraction_x1e9\"") orelse 0;

    // Decode health signals (delta from previous tick)
    const decode_fail_now = jsExtractU64(raw, "\"decode_fail\"") orelse 0;
    const ancestry_skip_now = jsExtractU64(raw, "\"ancestry_skip\"") orelse 0;
    const DecodeState = struct {
        var prev_decode_fail: u64 = 0;
        var prev_ancestry_skip: u64 = 0;
    };
    const decode_fail_delta = decode_fail_now -| DecodeState.prev_decode_fail;
    const ancestry_skip_delta = ancestry_skip_now -| DecodeState.prev_ancestry_skip;
    DecodeState.prev_decode_fail = decode_fail_now;
    DecodeState.prev_ancestry_skip = ancestry_skip_now;

    // Insight anomaly signals (from last completed 5m window)
    // Parse insight.last_completed.blocks and fees from /state JSON
    const insight_blocks: u32 = @intCast(jsExtractU64(raw, "\"last_completed\"") orelse 0);
    _ = insight_blocks;
    // Simple extraction: find "last_completed" then look for "blocks" and "fees" after it
    const insight_lc_blocks: u32 = blk_ins: {
        const lc_pos = std.mem.indexOf(u8, raw, "\"last_completed\"") orelse break :blk_ins 0;
        const sub = raw[lc_pos..];
        const b_val = jsExtractU64(sub, "\"blocks\"") orelse break :blk_ins 0;
        break :blk_ins @intCast(b_val);
    };
    const insight_lc_fees: u64 = blk_ins: {
        const lc_pos = std.mem.indexOf(u8, raw, "\"last_completed\"") orelse break :blk_ins 0;
        const sub = raw[lc_pos..];
        break :blk_ins jsExtractU64(sub, "\"fees\"") orelse 0;
    };

    const t_parse = milliTimestamp();
    const parse_ms = t_parse - t_fetch;

    const input = PolicyInput{
        .stall_active = stall,
        .density_smoothed = density_smoothed,
        .density_rec_min = density_rec_min,
        .header_err_delta_5m = herr_delta,
        .keepalive_to_delta_5m = ka_delta,
        .gap_win_rate = win_rate,
        .gap_keys_delta_5m = gap_delta,
        .authority_confidence = if (auth_conf == 0.0) 1.0 else auth_conf,
        .authority_finality = auth_fin,
        .authority_reorg_events_5m = auth_reorg,
        .authority_fork_events_total = auth_forks,
        .producer_epoch = prod_epoch,
        .producer_slot_in_epoch = prod_sie,
        .producer_eligible = prod_eligible,
        .producer_prob_x1e6 = prod_prob,
        .producer_expected_epoch = prod_exp_epoch,
        .producer_reason_code = prod_reason,
        .producer_stake_x1e9 = prod_stake,
        .decode_fail_delta = decode_fail_delta,
        .ancestry_skip_delta = ancestry_skip_delta,
        .insight_blocks_last = insight_lc_blocks,
        .insight_fees_last = insight_lc_fees,
    };

    // Get BAEY dir for logging + markers + weights
    const baey_dir = getBaeyDir(alloc) orelse {
        std.debug.print("BAEY Guardian: cannot resolve TSUNAGI_HOME/baey\n", .{});
        return;
    };
    defer alloc.free(baey_dir);

    // Load adaptive weights
    var weights = loadWeights(alloc, baey_dir);

    // Determine header_err_zero_minutes: if herr_delta==0, estimate from gate_stable_seconds
    const herr_zero_mins: u64 = if (herr_delta == 0)
        (jsExtractU64(raw, "\"gate_stable_seconds\"") orelse 0) / 60
    else
        0;

    // Adapt weights based on current inputs
    adaptWeights(&weights, input, herr_zero_mins);
    exportWeightsToMetrics(&weights);

    // Persist weights
    saveWeights(alloc, baey_dir, &weights);

    const computed = computePolicy(input, &weights);

    // Leader guard v2: protect leader windows from disruptive actions
    // lg_reason: 0=disabled, 1=config_bad (hard), 2=prob_high (soft), 3=exp_epoch_ge_1 (soft)
    var leader_guard_score: f64 = 0.0;
    var lg_reason: u64 = 0;
    if (input.producer_reason_code != 0) {
        // Hard guard: producer config is bad (missing keys, stake, genesis, etc.)
        // Score 0.95 to strongly bias toward Chill
        leader_guard_score = 0.95;
        lg_reason = 1; // config_bad
    } else if (input.producer_prob_x1e6 >= 1000) {
        // Soft guard: per-slot probability >= 0.001 (meaningful chance)
        leader_guard_score = 0.60;
        lg_reason = 2; // prob_high
    } else if (input.producer_expected_epoch >= 1) {
        // Soft guard: expected at least 1 leader slot per epoch
        leader_guard_score = 0.60;
        lg_reason = 3; // exp_epoch_ge_1
    }
    const leader_guard: bool = leader_guard_score > 0.0;
    const final_score: f64 = @max(computed.score, leader_guard_score);
    const final_action: Action = if (leader_guard) .Chill else computed.action;
    const result = PolicyResult{ .score = final_score, .action = final_action };

    // Health score + runtime state
    const health = computeHealth(input);
    const sm_active = blk_sm: {
        var sm_buf: [512]u8 = undefined;
        const sm_path = std.fmt.bufPrint(&sm_buf, "{s}/safe_mode.json", .{baey_dir}) catch break :blk_sm false;
        var sm_f = compat.fs.cwd().openFile(sm_path, .{}) catch break :blk_sm false;
        sm_f.close();
        break :blk_sm true;
    };
    const rt_reason = RuntimeStateMemory.step(final_score, health.score, sm_active);
    // Cache health for writeLoopStats
    RuntimeStateMemory.g_reason = rt_reason;
    RuntimeStateMemory.g_health_score = health.score;
    RuntimeStateMemory.g_health_band = health.band();
    RuntimeStateMemory.g_health_primary = health.primary_reason.label();
    RuntimeStateMemory.g_health_flags = health.reason_flags;

    const total_ms = milliTimestamp() - t0;

    const score_x1e6: u64 = @intFromFloat(@max(0.0, @min(1.0, final_score)) * 1_000_000.0);
    const computed_x1e6: u64 = @intFromFloat(@max(0.0, @min(1.0, computed.score)) * 1_000_000.0);
    const lg_x1e6: u64 = @intFromFloat(@max(0.0, @min(1.0, leader_guard_score)) * 1_000_000.0);
    std.debug.print("BAEY: fetch={d}ms parse={d}ms total={d}ms parse_ok={d}\n", .{ fetch_ms, parse_ms, total_ms, parse_ok });
    std.debug.print("BAEY Guardian: computed_score={d}.{d:0>6} computed_action={s} final_score={d}.{d:0>6} final_action={s} leader_guard={s} lg_score={d}.{d:0>6} lg_reason={d}\n", .{
        computed_x1e6 / 1_000_000, computed_x1e6 % 1_000_000,
        computed.action.label(),
        score_x1e6 / 1_000_000, score_x1e6 % 1_000_000,
        final_action.label(),
        if (leader_guard) @as([]const u8, "ON") else @as([]const u8, "OFF"),
        lg_x1e6 / 1_000_000, lg_x1e6 % 1_000_000,
        lg_reason,
    });

    // Log weight adaptation
    {
        const ws_x1e6: u64 = @intFromFloat(weights.stall * 1_000_000.0);
        const wg_x1e6: u64 = @intFromFloat(weights.gap * 1_000_000.0);
        const wh_x1e6: u64 = @intFromFloat(weights.header_err * 1_000_000.0);
        const wk_x1e6: u64 = @intFromFloat(weights.keepalive * 1_000_000.0);
        const wd_x1e6: u64 = @intFromFloat(weights.density * 1_000_000.0);
        const wa_x1e6: u64 = @intFromFloat(weights.authority * 1_000_000.0);
        const wf_x1e6: u64 = @intFromFloat(weights.finality * 1_000_000.0);
        std.debug.print("BAEY ADAPT: stall={d}.{d:0>2} gap={d}.{d:0>2} header={d}.{d:0>2} keepalive={d}.{d:0>2} density={d}.{d:0>2}\n", .{
            ws_x1e6 / 1_000_000, (ws_x1e6 % 1_000_000) / 10_000,
            wg_x1e6 / 1_000_000, (wg_x1e6 % 1_000_000) / 10_000,
            wh_x1e6 / 1_000_000, (wh_x1e6 % 1_000_000) / 10_000,
            wk_x1e6 / 1_000_000, (wk_x1e6 % 1_000_000) / 10_000,
            wd_x1e6 / 1_000_000, (wd_x1e6 % 1_000_000) / 10_000,
        });
        std.debug.print("BAEY ADAPT: authority={d}.{d:0>2} finality={d}.{d:0>2}\n", .{
            wa_x1e6 / 1_000_000, (wa_x1e6 % 1_000_000) / 10_000,
            wf_x1e6 / 1_000_000, (wf_x1e6 % 1_000_000) / 10_000,
        });
    }

    // Always log policy_tick
    baeyLogPolicyTick(alloc, baey_dir, input, computed, final_action, leader_guard, leader_guard_score, lg_reason, apply_mode, fetch_ms, total_ms, parse_ok);
    std.debug.print("BAEY Guardian: policy_tick logged\n", .{});

    // Write loop stats for http_metrics to pick up
    writeLoopStats(alloc, baey_dir, fetch_ms, total_ms, parse_ok);

    // Apply mode action execution
    if (apply_mode and result.action != .Chill) {
        const now: i64 = compat.timestamp();
        var cd = readCooldownState(alloc, baey_dir);

        const cooldown_ok = switch (result.action) {
            .Probe => (now - cd.last_probe_unix) >= @as(i64, @intCast(cd.probe_s)),
            .SwitchPeer => (now - cd.last_switch_unix) >= @as(i64, @intCast(cd.switch_s)),
            .ThrottleBackfill => (now - cd.last_throttle_unix) >= @as(i64, @intCast(cd.throttle_s)),
            .SafeMode => (now - cd.last_safe_unix) >= @as(i64, @intCast(cd.safe_s)),
            .Restart => true, // always "ok" but we only log
            .Chill => false,
        };

        if (result.action == .Restart) {
            // LOG ONLY — no execution
            baeyLogAction(alloc, baey_dir, "restart_requested", result.action, result.score, "log_only");
            std.debug.print("BAEY Guardian: restart_requested (LOG ONLY, no exec)\n", .{});
        } else if (cooldown_ok) {
            // Execute action via file marker
            switch (result.action) {
                .Probe => {
                    applyProbe(alloc, baey_dir);
                    cd.last_probe_unix = now;
                },
                .SwitchPeer => {
                    applySwitchPeer(alloc, baey_dir, result.score);
                    cd.last_switch_unix = now;
                },
                .ThrottleBackfill => {
                    applyThrottleBackfill(alloc, baey_dir, "suspicion_score");
                    cd.last_throttle_unix = now;
                },
                .SafeMode => {
                    applySafeMode(alloc, baey_dir);
                    cd.last_safe_unix = now;
                },
                else => {},
            }
            writeCooldownState(alloc, baey_dir, &cd);
            baeyLogAction(alloc, baey_dir, "action_applied", result.action, result.score, "cooldown_ok");
            std.debug.print("BAEY Guardian: action_applied {s}\n", .{result.action.label()});
        } else {
            baeyLogAction(alloc, baey_dir, "action_blocked", result.action, result.score, "cooldown_active");
            std.debug.print("BAEY Guardian: action_blocked {s} (cooldown)\n", .{result.action.label()});
        }
    }
}
