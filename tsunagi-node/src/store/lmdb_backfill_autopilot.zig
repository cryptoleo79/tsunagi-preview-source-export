const std = @import("std");
const compat = @import("compat");
const lmdb_utxo = @import("lmdb_utxo.zig");
const tx_decode = @import("../net/ledger/tx_decode.zig");
const utxo_mod = @import("../net/ledger/utxo.zig");
const cbor = @import("../net/cbor/term.zig");
const capture_mod = @import("../replay/capture.zig");

/// Incremental LMDB backfill from capture directory.
///
/// Designed for periodic runs via systemd timer. Features:
///   - JSON cursor file tracks progress (file + offset + cumulative totals)
///   - JSON stats bridge file lets the running node export backfill metrics
///   - Atomic writes via .tmp rename
///   - Process-level lock file prevents concurrent runs
///   - Bounded runs (max blocks, max seconds)
///   - Idempotent: safe to re-process blocks

const DEFAULT_MAX_BLOCKS: usize = 500;
const DEFAULT_MAX_SECONDS: i64 = 20;
const CURSOR_SAVE_INTERVAL: usize = 50;

// Cursor resync constants
const RECORD_MIN_LEN: u32 = 200;
const RECORD_MAX_LEN: u32 = 8 * 1024 * 1024; // 8MB
const RESYNC_SCAN_MAX: u64 = 32 * 1024 * 1024; // 32MB

fn isCaptureFile(name: []const u8) bool {
    return capture_mod.isCaptureFile(name);
}

/// Returns true for rotated capture segments: <net>.<digits>.bin (NOT <net>.bin)
fn isRotatedSegment(name: []const u8) bool {
    return capture_mod.isRotatedCapture(name);
}

fn getStateDir(alloc: std.mem.Allocator) ![]u8 {
    const env_dir = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_dir) |dir| {
        if (dir.len > 0) return dir;
        alloc.free(dir);
    }

    const home = compat.getEnvVarOwned(alloc, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (home) |dir| {
        defer alloc.free(dir);
        return try std.fs.path.join(alloc, &[_][]const u8{ dir, ".tsunagi" });
    }
    return error.EnvironmentVariableNotFound;
}

fn getDefaultLmdbDir(alloc: std.mem.Allocator) ![]u8 {
    const env_dir = compat.getEnvVarOwned(alloc, "TSUNAGI_LMDB") catch null;
    if (env_dir) |d| return d;

    const state_dir = getStateDir(alloc) catch return error.EnvironmentVariableNotFound;
    defer alloc.free(state_dir);
    return try std.fs.path.join(alloc, &[_][]const u8{ state_dir, "lmdb" });
}

/// Read TSUNAGI_CAPTURE_ROTATE_MB from env (same clamp rules as capture.zig: 16..4096, default 256).
fn getEffectiveRotateBytes(alloc: std.mem.Allocator) u64 {
    const default_bytes: u64 = 256 * 1024 * 1024;
    const v = compat.getEnvVarOwned(alloc, "TSUNAGI_CAPTURE_ROTATE_MB") catch return default_bytes;
    defer alloc.free(v);
    const mb = std.fmt.parseUnsigned(u64, std.mem.trim(u8, v, " \t\r\n"), 10) catch return default_bytes;
    const clamped_max: u64 = @min(mb, @as(u64, 4096));
    const clamped: u64 = @max(@as(u64, 16), clamped_max);
    return clamped * @as(u64, 1024) * @as(u64, 1024);
}

/// Decode block payload bytes -> TxDeltas (same logic as lmdb_backfill)
fn decodePayloadToDeltas(alloc: std.mem.Allocator, payload: []const u8, debug: bool) !tx_decode.TxDeltas {
    var fbs = compat.fixedBufferStream(payload);
    const term = try cbor.decode(alloc, fbs.reader());
    defer cbor.free(term, alloc);

    if (term != .array or term.array.len < 2) return error.InvalidBlockShape;

    const block_content = term.array[1];
    const scan = tx_decode.extractTxListFromTermPublic(alloc, block_content) orelse {
        return tx_decode.TxDeltas{ .consumed = &[_]utxo_mod.TxIn{}, .produced = &[_]utxo_mod.Produced{}, .tx_count = 0 };
    };
    const tx_list = scan.tx_list;
    if (tx_list.len == 0) return tx_decode.TxDeltas{ .consumed = &[_]utxo_mod.TxIn{}, .produced = &[_]utxo_mod.Produced{}, .tx_count = 0 };

    return try tx_decode.extractTxDeltas(alloc, tx_list, null, debug);
}

// ── JSON helpers (lightweight, no dependency) ────────────────────────

/// Extract a u64 value for a known key from flat JSON. Returns 0 if not found.
pub fn parseJsonU64(data: []const u8, key: []const u8) u64 {
    var search_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return 0;
    const idx = std.mem.indexOf(u8, data, needle) orelse return 0;
    const after = data[idx + needle.len ..];
    const trimmed = std.mem.trimStart(u8, after, " \t");
    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] >= '0' and trimmed[end] <= '9') : (end += 1) {}
    if (end == 0) return 0;
    return std.fmt.parseInt(u64, trimmed[0..end], 10) catch 0;
}

/// Extract a string value for a known key from flat JSON. Caller owns returned slice.
fn parseJsonStr(alloc: std.mem.Allocator, data: []const u8, key: []const u8) ?[]u8 {
    var search_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, data, needle) orelse return null;
    const after = data[idx + needle.len ..];
    const end_quote = std.mem.indexOfScalar(u8, after, '"') orelse return null;
    return alloc.dupe(u8, after[0..end_quote]) catch null;
}

// ── Cursor (JSON) ────────────────────────────────────────────────────

const CursorData = struct {
    file_name: []u8,
    byte_offset: u64,
    blocks_applied_total: u64,
    runs_total: u64,
};

const CursorError = error{
    FileNotFound,
    InvalidCursor,
};

fn readCursorJson(alloc: std.mem.Allocator, path: []const u8) CursorError!CursorData {
    var f = compat.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => CursorError.FileNotFound,
            else => CursorError.InvalidCursor,
        };
    };
    defer f.close();
    const data = f.deprecatedReader().readAllAlloc(alloc, 8192) catch return CursorError.InvalidCursor;
    defer alloc.free(data);

    if (data.len == 0) return CursorError.InvalidCursor;

    // Detect format: JSON starts with '{', old format starts with filename
    if (data[0] == '{') {
        // JSON cursor
        const name = parseJsonStr(alloc, data, "file") orelse return CursorError.InvalidCursor;
        return CursorData{
            .file_name = name,
            .byte_offset = parseJsonU64(data, "offset"),
            .blocks_applied_total = parseJsonU64(data, "blocks_applied_total"),
            .runs_total = parseJsonU64(data, "runs_total"),
        };
    }

    // Legacy 2-line format: "filename\noffset\n"
    const trimmed = std.mem.trim(u8, data, " \r\n\t");
    const nl = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return CursorError.InvalidCursor;
    const file_line = trimmed[0..nl];
    const offset_line = std.mem.trim(u8, trimmed[nl + 1 ..], " \r\n\t");
    if (file_line.len == 0 or offset_line.len == 0) return CursorError.InvalidCursor;

    const offset = std.fmt.parseInt(u64, offset_line, 10) catch return CursorError.InvalidCursor;
    const name = alloc.dupe(u8, file_line) catch return CursorError.InvalidCursor;
    return CursorData{ .file_name = name, .byte_offset = offset, .blocks_applied_total = 0, .runs_total = 0 };
}

fn writeCursorJson(alloc: std.mem.Allocator, path: []const u8, file_name: []const u8, byte_offset: u64, blocks_total: u64, runs_total: u64) void {
    const tmp_path = std.fmt.allocPrint(alloc, "{s}.tmp", .{path}) catch return;
    defer alloc.free(tmp_path);

    var f = compat.fs.cwd().createFile(tmp_path, .{}) catch return;
    const now: u64 = @intCast(compat.timestamp());
    f.deprecatedWriter().print("{{\"file\":\"{s}\",\"offset\":{d},\"blocks_applied_total\":{d},\"runs_total\":{d},\"updated_unix\":{d}}}\n", .{
        file_name,
        byte_offset,
        blocks_total,
        runs_total,
        now,
    }) catch {
        f.close();
        return;
    };
    f.close();

    compat.fs.cwd().rename(tmp_path, path) catch {};
}

// ── Stats bridge (JSON) ──────────────────────────────────────────────

const StatsData = struct {
    runs_total: u64 = 0,
    blocks_total: u64 = 0,
    errors_total: u64 = 0,
    busy_total: u64 = 0,
    // Adaptive throttle: last-seen pressure counters
    last_peer_closed_total: u64 = 0,
    last_keepalive_timeouts_total: u64 = 0,
    last_block_total_us: u64 = 0,
    last_recommended_blocks: u64 = 0,
    last_recommended_seconds: u64 = 0,
    // Cursor resync counters
    cursor_desync_total: u64 = 0,
    cursor_resync_total: u64 = 0,
    cursor_resync_fail_total: u64 = 0,
    cursor_resync_last_unix: u64 = 0,
    // EOF idle
    eof_idle_total: u64 = 0,
    eof_idle_last_unix: u64 = 0,
    // Segment cleanup
    segments_deleted_total: u64 = 0,
    segments_deleted_bytes_total: u64 = 0,
    // Idle skip
    idle_skips_total: u64 = 0,
    idle_last_unix: u64 = 0,
    // Gap hunter
    gap_resolved_total: u64 = 0,
    gap_resolved_last: u64 = 0,
    gap_unresolved_last: u64 = 0,
    // Gap recommendation
    recommend_profile_code: u64 = 1,
    recommend_blocks: u64 = 500,
    recommend_seconds: u64 = 20,
    recommend_pressure: u64 = 1,
    // Gap steering
    gap_keys_loaded_last: u64 = 0,
    produced_total_last: u64 = 0,
    gap_hit_ratio_last_x1e6: u64 = 0,
    // Gap consumed coverage
    gap_consumed_seen_last: u64 = 0,
    gap_consumed_resolved_last: u64 = 0,
    gap_consumed_seen_total: u64 = 0,
    gap_consumed_resolved_total: u64 = 0,
    // Autotune
    autotune_enabled_last: u64 = 0,
    autotune_profile_current: u64 = 0,
    autotune_last_change_unix: u64 = 0,
    autotune_switch_total: u64 = 0,
    autotune_reason_code_last: u64 = 0,
};

fn readStatsJson(alloc: std.mem.Allocator, path: []const u8) StatsData {
    var f = compat.fs.cwd().openFile(path, .{}) catch return StatsData{};
    defer f.close();
    const data = f.deprecatedReader().readAllAlloc(alloc, 8192) catch return StatsData{};
    defer alloc.free(data);
    return StatsData{
        .runs_total = parseJsonU64(data, "runs_total"),
        .blocks_total = parseJsonU64(data, "blocks_total"),
        .errors_total = parseJsonU64(data, "errors_total"),
        .busy_total = parseJsonU64(data, "busy_total"),
        .last_peer_closed_total = parseJsonU64(data, "last_peer_closed_total"),
        .last_keepalive_timeouts_total = parseJsonU64(data, "last_keepalive_timeouts_total"),
        .last_block_total_us = parseJsonU64(data, "last_block_total_us"),
        .last_recommended_blocks = parseJsonU64(data, "last_recommended_blocks"),
        .last_recommended_seconds = parseJsonU64(data, "last_recommended_seconds"),
        .cursor_desync_total = parseJsonU64(data, "cursor_desync_total"),
        .cursor_resync_total = parseJsonU64(data, "cursor_resync_total"),
        .cursor_resync_fail_total = parseJsonU64(data, "cursor_resync_fail_total"),
        .cursor_resync_last_unix = parseJsonU64(data, "cursor_resync_last_unix"),
        .eof_idle_total = parseJsonU64(data, "eof_idle_total"),
        .eof_idle_last_unix = parseJsonU64(data, "eof_idle_last_unix"),
        .segments_deleted_total = parseJsonU64(data, "segments_deleted_total"),
        .segments_deleted_bytes_total = parseJsonU64(data, "segments_deleted_bytes_total"),
        .idle_skips_total = parseJsonU64(data, "idle_skips_total"),
        .idle_last_unix = parseJsonU64(data, "idle_last_unix"),
        .gap_resolved_total = parseJsonU64(data, "gap_resolved_total"),
        .gap_resolved_last = parseJsonU64(data, "gap_resolved_last"),
        .gap_unresolved_last = parseJsonU64(data, "gap_unresolved_last"),
        .recommend_profile_code = parseJsonU64(data, "recommend_profile_code"),
        .recommend_blocks = parseJsonU64(data, "recommend_blocks"),
        .recommend_seconds = parseJsonU64(data, "recommend_seconds"),
        .recommend_pressure = parseJsonU64(data, "recommend_pressure"),
        .gap_keys_loaded_last = parseJsonU64(data, "gap_keys_loaded_last"),
        .produced_total_last = parseJsonU64(data, "produced_total_last"),
        .gap_hit_ratio_last_x1e6 = parseJsonU64(data, "gap_hit_ratio_last_x1e6"),
        .gap_consumed_seen_last = parseJsonU64(data, "gap_consumed_seen_last"),
        .gap_consumed_resolved_last = parseJsonU64(data, "gap_consumed_resolved_last"),
        .gap_consumed_seen_total = parseJsonU64(data, "gap_consumed_seen_total"),
        .gap_consumed_resolved_total = parseJsonU64(data, "gap_consumed_resolved_total"),
        .autotune_enabled_last = parseJsonU64(data, "autotune_enabled_last"),
        .autotune_profile_current = parseJsonU64(data, "autotune_profile_current"),
        .autotune_last_change_unix = parseJsonU64(data, "autotune_last_change_unix"),
        .autotune_switch_total = parseJsonU64(data, "autotune_switch_total"),
        .autotune_reason_code_last = parseJsonU64(data, "autotune_reason_code_last"),
    };
}

// ── Adaptive throttle ────────────────────────────────────────────────

fn findMetricLine(raw: []const u8, key: []const u8) u64 {
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, key)) {
            const val_str = std.mem.trimStart(u8, line[key.len..], " ");
            return std.fmt.parseUnsigned(u64, val_str, 10) catch 0;
        }
    }
    return 0;
}

fn fetchMetrics(alloc: std.mem.Allocator, url: []const u8) ?[]u8 {
    const argv = [_][]const u8{ "curl", "-s", "--max-time", "5", url };
    var child = compat.Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch return null;
    const stdout = child.stdout orelse return null;
    const output = stdout.readToEndAlloc(alloc, 256 * 1024) catch null;
    _ = child.wait() catch {};
    return output;
}

fn findMetricLineRatioX1e6(raw: []const u8, key: []const u8) u64 {
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, key)) {
            const val_str = std.mem.trimStart(u8, line[key.len..], " ");
            const f = std.fmt.parseFloat(f64, val_str) catch return 0;
            if (f < 0.0) return 0;
            return @intFromFloat(f * 1_000_000.0);
        }
    }
    return 0;
}

fn findMetricLineSigned(raw: []const u8, key: []const u8) i64 {
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, key)) {
            const val_str = std.mem.trimStart(u8, line[key.len..], " ");
            return std.fmt.parseInt(i64, val_str, 10) catch 0;
        }
    }
    return 0;
}

const GapRecommendation = struct {
    profile_code: u64, // 0=cautious 1=normal 2=aggressive
    blocks: u64,
    seconds: u64,
    pressure: u64, // clamped to 0
};

fn computeGapRecommendation(alloc: std.mem.Allocator, metrics_url: []const u8, adapt: ?AdaptResult) GapRecommendation {
    const default_rec = GapRecommendation{ .profile_code = 1, .blocks = 500, .seconds = 20, .pressure = 1 };

    const raw = fetchMetrics(alloc, metrics_url) orelse return default_rec;
    defer alloc.free(raw);

    const repeat_ratio_x1e6 = findMetricLineRatioX1e6(raw, "tsunagi_gap_repeat_ratio ");
    const hot_top_age = findMetricLine(raw, "tsunagi_gap_hot_top_age_seconds ");
    const hot_top_count = findMetricLine(raw, "tsunagi_gap_hot_top_count ");

    var pressure: i32 = 0;
    if (repeat_ratio_x1e6 >= 600_000) pressure += 2; // >= 0.60
    if (hot_top_age >= 600) pressure += 2;
    if (hot_top_count >= 10) pressure += 1;

    // Negative pressure from load signals
    if (adapt) |a| {
        if (a.block_total_us >= 10_000) pressure -= 1;
        if (a.keepalive_delta > 0 or a.peer_closed_delta > 0) pressure -= 1;
    }

    const pressure_u: u64 = if (pressure >= 0) @intCast(pressure) else 0;

    if (pressure >= 3) {
        std.debug.print("BACKFILL RECOMMEND: aggressive (pressure={d}) repeat_ratio={d}e-6 hot_age={d} hot_count={d}\n", .{ pressure, repeat_ratio_x1e6, hot_top_age, hot_top_count });
        return .{ .profile_code = 2, .blocks = 1200, .seconds = 25, .pressure = pressure_u };
    } else if (pressure <= 0) {
        return .{ .profile_code = 0, .blocks = 200, .seconds = 10, .pressure = pressure_u };
    } else {
        return .{ .profile_code = 1, .blocks = 500, .seconds = 20, .pressure = pressure_u };
    }
}

// ── BAEY audit log (backfill) ────────────────────────────────────────

fn baeyLogBackfill(alloc: std.mem.Allocator, state_dir: []const u8, kind: []const u8, reason: []const u8, profile: u64, max_blocks: u64, max_seconds: u64, pressure: u64, win_rate_x1e6: u64, keys_delta_raw: u64) void {
    const baey_dir = std.fmt.allocPrint(alloc, "{s}/baey", .{state_dir}) catch return;
    defer alloc.free(baey_dir);
    compat.fs.cwd().makePath(baey_dir) catch {};
    const path = std.fmt.allocPrint(alloc, "{s}/events.log", .{baey_dir}) catch return;
    defer alloc.free(path);

    var file = compat.fs.cwd().openFile(path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => compat.fs.cwd().createFile(path, .{}) catch return,
        else => return,
    };
    defer file.close();
    file.seekFromEnd(0) catch return;

    const now: u64 = @intCast(@max(0, compat.timestamp()));
    const delta_signed: i64 = @as(i64, @intCast(keys_delta_raw)) - 10_000_000;
    const wr_x1e6 = win_rate_x1e6;

    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buf,
        \\{{"unix":{d},"kind":"{s}","reason":"{s}","profile":{d},"max_blocks":{d},"max_seconds":{d},"pressure":{d},"win_rate":"{d}.{d:0>6}","keys_delta":{d}}}
        \\
    , .{ now, kind, reason, profile, max_blocks, max_seconds, pressure, wr_x1e6 / 1_000_000, wr_x1e6 % 1_000_000, delta_signed }) catch return;
    _ = file.write(line) catch {};
}

// ── Autotune ─────────────────────────────────────────────────────────

fn backfillAutotuneEnabled() bool {
    const v = compat.getEnvVarOwned(std.heap.page_allocator, "TSUNAGI_BACKFILL_AUTOTUNE") catch return false;
    defer std.heap.page_allocator.free(v);
    if (v.len == 0) return false;
    if (std.mem.eql(u8, v, "0")) return false;
    return true;
}

const AutotuneResult = struct {
    profile: u64,
    max_blocks: u64,
    max_seconds: u64,
    reason: u64,
    did_switch: bool,
};

fn computeAutotuneDecision(
    now_unix: u64,
    enabled: bool,
    rec_profile: u64,
    rec_blocks: u64,
    rec_seconds: u64,
    rec_pressure: u64,
    peer_closed_delta: u64,
    keepalive_timeouts_delta: u64,
    block_total_us: u64,
    prev_profile: u64,
    prev_change_unix: u64,
    win_rate_x1e6: u64,
    keys_delta_5m_raw: u64,
) AutotuneResult {
    _ = rec_blocks;
    _ = rec_seconds;
    _ = rec_profile;
    _ = rec_pressure;
    if (!enabled) return .{ .profile = prev_profile, .max_blocks = profileBlocks(prev_profile), .max_seconds = profileSeconds(prev_profile), .reason = 0, .did_switch = false };

    // Safety first (reason=4)
    if (peer_closed_delta > 0 or keepalive_timeouts_delta > 0 or block_total_us >= 20_000) {
        const switched = prev_profile != 0 and (now_unix -| prev_change_unix) >= 60;
        return .{ .profile = 0, .max_blocks = 200, .max_seconds = 10, .reason = 4, .did_switch = switched };
    }

    const cooldown_ok = (now_unix -| prev_change_unix) >= 60;

    // Gap trend policy (reasons 5/6/7) — override recommendation when win_rate is available
    // keys_delta_5m_raw uses offset encoding: 10_000_000 = zero, >10M = growing, <10M = shrinking
    const keys_delta_positive = keys_delta_5m_raw > 10_000_000;

    if (win_rate_x1e6 >= 800_000 and !keys_delta_positive) {
        // Winning: win_rate >= 0.80 AND keys not growing → aggressive
        const profile: u64 = 2;
        const switched = profile != prev_profile and cooldown_ok;
        const active_profile = if (switched) profile else prev_profile;
        return .{ .profile = active_profile, .max_blocks = profileBlocks(active_profile), .max_seconds = profileSeconds(active_profile), .reason = 5, .did_switch = switched };
    } else if (win_rate_x1e6 < 400_000 or keys_delta_positive) {
        // Losing: win_rate < 0.40 OR keys growing → cautious
        const profile: u64 = 0;
        const switched = profile != prev_profile and cooldown_ok;
        const active_profile = if (switched) profile else prev_profile;
        return .{ .profile = active_profile, .max_blocks = profileBlocks(active_profile), .max_seconds = profileSeconds(active_profile), .reason = 7, .did_switch = switched };
    } else {
        // Mixed: 0.40 <= win_rate < 0.80 → normal
        const profile: u64 = 1;
        const switched = profile != prev_profile and cooldown_ok;
        const active_profile = if (switched) profile else prev_profile;
        return .{ .profile = active_profile, .max_blocks = profileBlocks(active_profile), .max_seconds = profileSeconds(active_profile), .reason = 6, .did_switch = switched };
    }
}

fn profileBlocks(p: u64) u64 {
    return switch (p) {
        0 => 200,
        1 => 500,
        2 => 1000,
        else => 500,
    };
}

fn profileSeconds(p: u64) u64 {
    return switch (p) {
        0 => 10,
        1 => 20,
        2 => 30,
        else => 20,
    };
}

const AdaptResult = struct {
    max_blocks: usize,
    max_seconds: i64,
    block_total_us: u64,
    peer_closed_total: u64,
    keepalive_timeouts_total: u64,
    peer_closed_delta: u64,
    keepalive_delta: u64,
};

fn computeAdaptiveThrottle(
    alloc: std.mem.Allocator,
    metrics_url: []const u8,
    prev: StatsData,
    user_max_blocks: ?usize,
    user_max_seconds: ?i64,
) AdaptResult {
    const raw = fetchMetrics(alloc, metrics_url) orelse {
        std.debug.print("BACKFILL ADAPT: metrics unavailable -> defaults\n", .{});
        return .{
            .max_blocks = @min(user_max_blocks orelse 500, 500),
            .max_seconds = @min(user_max_seconds orelse 20, 20),
            .block_total_us = 0,
            .peer_closed_total = prev.last_peer_closed_total,
            .keepalive_timeouts_total = prev.last_keepalive_timeouts_total,
            .peer_closed_delta = 0,
            .keepalive_delta = 0,
        };
    };
    defer alloc.free(raw);

    const block_total_us = findMetricLine(raw, "tsunagi_perf_block_total_us ");
    const peer_closed = findMetricLine(raw, "tsunagi_peer_closed_total ");
    const keepalive_to = findMetricLine(raw, "tsunagi_keepalive_timeouts_total ");

    const peer_delta = if (peer_closed > prev.last_peer_closed_total) peer_closed - prev.last_peer_closed_total else 0;
    const ka_delta = if (keepalive_to > prev.last_keepalive_timeouts_total) keepalive_to - prev.last_keepalive_timeouts_total else 0;

    var rec_blocks: usize = 500;
    var rec_seconds: i64 = 20;

    if (ka_delta > 0) {
        rec_blocks = 200;
        rec_seconds = 10;
    } else if (peer_delta > 0) {
        rec_blocks = 200;
        rec_seconds = 10;
    } else if (block_total_us >= 20_000) {
        rec_blocks = 200;
        rec_seconds = 10;
    } else if (block_total_us >= 5_000) {
        rec_blocks = 500;
        rec_seconds = 20;
    } else if (block_total_us > 0) {
        rec_blocks = 800;
        rec_seconds = 25;
    }
    // block_total_us == 0 means no data yet → keep defaults

    // Apply hard caps from user flags
    if (user_max_blocks) |ub| rec_blocks = @min(rec_blocks, ub);
    if (user_max_seconds) |us| rec_seconds = @min(rec_seconds, us);

    // Enforce floor
    rec_blocks = @max(rec_blocks, 50);
    rec_seconds = @max(rec_seconds, 5);

    std.debug.print("BACKFILL ADAPT: block_total_us={d} peer_closed_delta={d} keepalive_timeout_delta={d} -> max_blocks={d} max_seconds={d}\n", .{
        block_total_us,
        peer_delta,
        ka_delta,
        rec_blocks,
        rec_seconds,
    });

    return .{
        .max_blocks = rec_blocks,
        .max_seconds = rec_seconds,
        .block_total_us = block_total_us,
        .peer_closed_total = peer_closed,
        .keepalive_timeouts_total = keepalive_to,
        .peer_closed_delta = peer_delta,
        .keepalive_delta = ka_delta,
    };
}

fn writeStatsJson(
    alloc: std.mem.Allocator,
    path: []const u8,
    runs_total: u64,
    blocks_total: u64,
    last_blocks: u64,
    last_errors: u64,
    busy_total: u64,
    errors_total: u64,
    cursor_file: []const u8,
    cursor_offset: u64,
    elapsed_ms: u64,
    file_count: u64,
    file_index: u64,
    file_size_bytes: u64,
    segment_done_x1e6: u64,
    adapt: ?AdaptResult,
    p_desync_total: u64,
    p_resync_total: u64,
    p_resync_fail_total: u64,
    p_resync_last_unix: u64,
    p_eof_idle_total: u64,
    p_eof_idle_last_unix: u64,
    p_seg_deleted_total: u64,
    p_seg_deleted_bytes_total: u64,
    p_current_file_is_active: u64,
    p_idle_skips_total: u64,
    p_idle_last_unix: u64,
    p_gap_resolved_total: u64,
    p_gap_resolved_last: u64,
    p_gap_unresolved_last: u64,
    p_rec_profile_code: u64,
    p_rec_blocks: u64,
    p_rec_seconds: u64,
    p_rec_pressure: u64,
    p_gap_keys_loaded_last: u64,
    p_produced_total_last: u64,
    p_gap_hit_ratio_last_x1e6: u64,
    p_gap_consumed_seen_last: u64,
    p_gap_consumed_resolved_last: u64,
    p_gap_consumed_seen_total: u64,
    p_gap_consumed_resolved_total: u64,
    p_autotune_enabled_last: u64,
    p_autotune_profile_current: u64,
    p_autotune_last_change_unix: u64,
    p_autotune_switch_total: u64,
    p_autotune_reason_code_last: u64,
) void {
    const tmp_path = std.fmt.allocPrint(alloc, "{s}.tmp", .{path}) catch return;
    defer alloc.free(tmp_path);

    var f = compat.fs.cwd().createFile(tmp_path, .{}) catch return;
    const now: u64 = @intCast(compat.timestamp());
    const a = adapt orelse AdaptResult{
        .max_blocks = 0,
        .max_seconds = 0,
        .block_total_us = 0,
        .peer_closed_total = 0,
        .keepalive_timeouts_total = 0,
        .peer_closed_delta = 0,
        .keepalive_delta = 0,
    };
    f.deprecatedWriter().print("{{\"updated_unix\":{d},\"runs_total\":{d},\"blocks_total\":{d},\"last_blocks\":{d},\"last_errors\":{d},\"busy_total\":{d},\"errors_total\":{d},\"cursor_file\":\"{s}\",\"cursor_offset\":{d},\"last_elapsed_ms\":{d},\"file_count\":{d},\"file_index\":{d},\"file_size_bytes\":{d},\"segment_done_x1e6\":{d},\"last_peer_closed_total\":{d},\"last_keepalive_timeouts_total\":{d},\"last_block_total_us\":{d},\"last_recommended_blocks\":{d},\"last_recommended_seconds\":{d},\"cursor_desync_total\":{d},\"cursor_resync_total\":{d},\"cursor_resync_fail_total\":{d},\"cursor_resync_last_unix\":{d},\"eof_idle_total\":{d},\"eof_idle_last_unix\":{d},\"segments_deleted_total\":{d},\"segments_deleted_bytes_total\":{d},\"current_file_is_active\":{d},\"idle_skips_total\":{d},\"idle_last_unix\":{d},", .{
        now,
        runs_total,
        blocks_total,
        last_blocks,
        last_errors,
        busy_total,
        errors_total,
        cursor_file,
        cursor_offset,
        elapsed_ms,
        file_count,
        file_index,
        file_size_bytes,
        segment_done_x1e6,
        a.peer_closed_total,
        a.keepalive_timeouts_total,
        a.block_total_us,
        a.max_blocks,
        @as(u64, @intCast(a.max_seconds)),
        p_desync_total,
        p_resync_total,
        p_resync_fail_total,
        p_resync_last_unix,
        p_eof_idle_total,
        p_eof_idle_last_unix,
        p_seg_deleted_total,
        p_seg_deleted_bytes_total,
        p_current_file_is_active,
        p_idle_skips_total,
        p_idle_last_unix,
    }) catch {
        f.close();
        return;
    };
    f.deprecatedWriter().print("\"gap_resolved_total\":{d},\"gap_resolved_last\":{d},\"gap_unresolved_last\":{d},\"recommend_profile_code\":{d},\"recommend_blocks\":{d},\"recommend_seconds\":{d},\"recommend_pressure\":{d},\"gap_keys_loaded_last\":{d},\"produced_total_last\":{d},\"gap_hit_ratio_last_x1e6\":{d},\"gap_consumed_seen_last\":{d},\"gap_consumed_resolved_last\":{d},\"gap_consumed_seen_total\":{d},\"gap_consumed_resolved_total\":{d},\"autotune_enabled_last\":{d},\"autotune_profile_current\":{d},\"autotune_last_change_unix\":{d},\"autotune_switch_total\":{d},\"autotune_reason_code_last\":{d}}}\n", .{
        p_gap_resolved_total,
        p_gap_resolved_last,
        p_gap_unresolved_last,
        p_rec_profile_code,
        p_rec_blocks,
        p_rec_seconds,
        p_rec_pressure,
        p_gap_keys_loaded_last,
        p_produced_total_last,
        p_gap_hit_ratio_last_x1e6,
        p_gap_consumed_seen_last,
        p_gap_consumed_resolved_last,
        p_gap_consumed_seen_total,
        p_gap_consumed_resolved_total,
        p_autotune_enabled_last,
        p_autotune_profile_current,
        p_autotune_last_change_unix,
        p_autotune_switch_total,
        p_autotune_reason_code_last,
    }) catch {};
    f.close();

    compat.fs.cwd().rename(tmp_path, path) catch {};
}

// ── Lock ─────────────────────────────────────────────────────────────

fn tryAcquireLock(lock_path: []const u8, max_age_s: i64) bool {
    if (compat.fs.cwd().openFile(lock_path, .{})) |f| {
        var file = f;
        defer file.close();
        var buf: [32]u8 = undefined;
        const n = file.deprecatedReader().readAll(&buf) catch 0;
        if (n > 0) {
            const ts_str = std.mem.trim(u8, buf[0..n], " \n\r\t");
            const ts = std.fmt.parseInt(i64, ts_str, 10) catch 0;
            const now = compat.timestamp();
            if (ts > 0 and (now - ts) < max_age_s) {
                return false;
            }
        }
    } else |_| {}

    var nf = compat.fs.cwd().createFile(lock_path, .{}) catch return false;
    nf.deprecatedWriter().print("{d}\n", .{compat.timestamp()}) catch {};
    nf.close();
    return true;
}

fn releaseLock(lock_path: []const u8) void {
    compat.fs.cwd().deleteFile(lock_path) catch {};
}

// ── Cursor resync ────────────────────────────────────────────────────

fn isPlausibleRecord(file_path: []const u8, pos: u64, file_size: u64) bool {
    var f = compat.fs.cwd().openFile(file_path, .{}) catch return false;
    defer f.close();
    f.seekTo(pos) catch return false;
    var hdr: [6]u8 = undefined;
    const n = f.deprecatedReader().readAll(&hdr) catch return false;
    if (n < 6) return false;
    const len = std.mem.readInt(u32, hdr[0..4], .little);
    if (len < RECORD_MIN_LEN or len > RECORD_MAX_LEN) return false;
    if (pos + 4 + len > file_size) return false;
    // Check CBOR prefix: 0x82 = 2-element array (block wrapper)
    return (hdr[4] == 0x82);
}

fn resyncCursorForward(file_path: []const u8, start_offset: u64, file_size: u64) ?u64 {
    if (start_offset >= file_size) return null;
    var f = compat.fs.cwd().openFile(file_path, .{}) catch return null;
    defer f.close();

    const scan_end = @min(start_offset + RESYNC_SCAN_MAX, file_size);
    var pos = start_offset;

    // Read a window and scan byte-by-byte
    var buf: [4096 + 6]u8 = undefined; // extra for header peek at end of window

    while (pos < scan_end) {
        f.seekTo(pos) catch return null;
        const to_read = @min(buf.len, scan_end - pos + 6);
        const got = f.deprecatedReader().readAll(buf[0..to_read]) catch return null;
        if (got < 6) return null;

        const scan_limit = if (got > 6) got - 6 else 0;
        var i: usize = 0;
        while (i < scan_limit) : (i += 1) {
            const candidate_pos = pos + i;
            const len = std.mem.readInt(u32, buf[i..][0..4], .little);
            if (len < RECORD_MIN_LEN or len > RECORD_MAX_LEN) continue;
            if (candidate_pos + 4 + len > file_size) continue;
            // CBOR prefix: 0x82 = 2-element array
            if (buf[i + 4] != 0x82) continue;
            return candidate_pos;
        }

        // Advance window (overlap by 5 to avoid missing boundary)
        pos += if (scan_limit > 0) scan_limit else 1;
    }
    return null;
}

// ── Gap Hunter helpers ───────────────────────────────────────────────

fn loadGapKeysBackfill(alloc: std.mem.Allocator, gap_dir: []const u8) ?std.AutoHashMap([36]u8, void) {
    const path = std.fmt.allocPrint(alloc, "{s}/missing_inputs.keys", .{gap_dir}) catch return null;
    defer alloc.free(path);

    var f = compat.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    const data = f.deprecatedReader().readAllAlloc(alloc, 512 * 1024) catch return null;
    defer alloc.free(data);

    var map = std.AutoHashMap([36]u8, void).init(alloc);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len < 72) continue;
        var key: [36]u8 = undefined;
        var valid = true;
        for (0..36) |i| {
            key[i] = std.fmt.parseInt(u8, line[i * 2 .. i * 2 + 2], 16) catch {
                valid = false;
                break;
            };
        }
        if (!valid) continue;
        map.put(key, {}) catch continue;
    }
    if (map.count() > 0) {
        std.debug.print("GAP HUNTER: loaded {d} keys for resolution\n", .{map.count()});
    }
    return map;
}

fn persistGapKeysBackfill(alloc: std.mem.Allocator, gap_dir: []const u8, gap_keys: *?std.AutoHashMap([36]u8, void)) void {
    const path = std.fmt.allocPrint(alloc, "{s}/missing_inputs.keys", .{gap_dir}) catch return;
    defer alloc.free(path);
    const tmp = std.fmt.allocPrint(alloc, "{s}/missing_inputs.keys.tmp", .{gap_dir}) catch return;
    defer alloc.free(tmp);

    const map = gap_keys.* orelse return;

    var f = compat.fs.cwd().createFile(tmp, .{}) catch return;
    const hex = "0123456789abcdef";
    var iter = map.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        var line: [73]u8 = undefined;
        for (0..36) |i| {
            line[i * 2] = hex[key[i] >> 4];
            line[i * 2 + 1] = hex[key[i] & 0xf];
        }
        line[72] = '\n';
        _ = f.write(&line) catch {};
    }
    f.close();
    compat.fs.cwd().rename(tmp, path) catch {};
}

// ── Main entry point ─────────────────────────────────────────────────

pub fn run(
    alloc: std.mem.Allocator,
    captures_dir: []const u8,
    lmdb_dir_opt: ?[]const u8,
    max_blocks_opt: ?usize,
    max_seconds_opt: ?i64,
    cursor_path_opt: ?[]const u8,
    strict: bool,
    adaptive: bool,
    metrics_url: []const u8,
    reset_cursor: bool,
    net_opt: ?[]const u8,
) !void {
    if (net_opt) |net| capture_mod.setNetPrefix(net);
    var max_blocks = max_blocks_opt orelse DEFAULT_MAX_BLOCKS;
    var max_seconds = max_seconds_opt orelse DEFAULT_MAX_SECONDS;

    const lmdb_dir = if (lmdb_dir_opt) |p| try alloc.dupe(u8, p) else try getDefaultLmdbDir(alloc);
    defer alloc.free(lmdb_dir);

    try compat.fs.cwd().makePath(lmdb_dir);

    // Resolve state dir for cursor + stats (TSUNAGI_HOME or ~/.tsunagi)
    const state_dir = getStateDir(alloc) catch {
        std.debug.print("lmdb-backfill-inc: cannot resolve state dir (set TSUNAGI_HOME)\n", .{});
        return error.EnvironmentVariableNotFound;
    };
    defer alloc.free(state_dir);
    compat.fs.cwd().makePath(state_dir) catch {};

    const cursor_path = if (cursor_path_opt) |p|
        try alloc.dupe(u8, p)
    else
        try std.fs.path.join(alloc, &[_][]const u8{ state_dir, "backfill.cursor.json" });
    defer alloc.free(cursor_path);

    const stats_path = try std.fs.path.join(alloc, &[_][]const u8{ state_dir, "backfill.stats.json" });
    defer alloc.free(stats_path);

    const lock_path = try std.fs.path.join(alloc, &[_][]const u8{ lmdb_dir, ".backfill.lock" });
    defer alloc.free(lock_path);

    std.debug.print("lmdb-backfill-inc: dir={s} lmdb={s}\n", .{ captures_dir, lmdb_dir });
    std.debug.print("lmdb-backfill-inc: cursor={s} stats={s}\n", .{ cursor_path, stats_path });
    std.debug.print("lmdb-backfill-inc: max_blocks={d} max_seconds={d}\n", .{ max_blocks, max_seconds });

    // Read existing stats for cumulative counters
    var prev_stats = readStatsJson(alloc, stats_path);

    // Gap hunter: load missing input keys
    const gap_dir = std.fs.path.join(alloc, &[_][]const u8{ state_dir, "gaps" }) catch null;
    defer if (gap_dir) |gd| alloc.free(gd);
    var gap_keys: ?std.AutoHashMap([36]u8, void) = null;
    defer if (gap_keys) |*gk| gk.deinit();
    var gap_resolved_this_run: u64 = 0;
    var gap_keys_loaded_count: u64 = 0;
    var produced_total_this_run: u64 = 0;
    var gap_consumed_seen: u64 = 0;
    var gap_consumed_seen_keys = std.AutoHashMap([36]u8, void).init(alloc);
    defer gap_consumed_seen_keys.deinit();
    if (gap_dir) |gd| {
        compat.fs.cwd().makePath(gd) catch {};
        gap_keys = loadGapKeysBackfill(alloc, gd);
        if (gap_keys) |gk| gap_keys_loaded_count = @intCast(gk.count());
    }

    // Adaptive throttle: query node /metrics and tune run bounds
    var adapt_result: ?AdaptResult = null;
    if (adaptive and metrics_url.len > 0) {
        const ar = computeAdaptiveThrottle(alloc, metrics_url, prev_stats, max_blocks_opt, max_seconds_opt);
        adapt_result = ar;
        max_blocks = ar.max_blocks;
        max_seconds = ar.max_seconds;
    }

    // Autotune pre-run override (only when adaptive is enabled)
    if (adaptive and backfillAutotuneEnabled()) {
        const at_peer_d: u64 = if (adapt_result) |ar| ar.peer_closed_delta else 0;
        const at_ka_d: u64 = if (adapt_result) |ar| ar.keepalive_delta else 0;
        const at_blk_us: u64 = if (adapt_result) |ar| ar.block_total_us else 0;
        var pre_wr: u64 = 0;
        var pre_kd: u64 = 10_000_000;
        if (metrics_url.len > 0) {
            if (fetchMetrics(alloc, metrics_url)) |pre_raw| {
                defer alloc.free(pre_raw);
                pre_wr = findMetricLineRatioX1e6(pre_raw, "tsunagi_gap_win_rate ");
                const pre_delta = findMetricLineSigned(pre_raw, "tsunagi_gap_keys_delta_5m ");
                pre_kd = if (pre_delta >= 0) @as(u64, @intCast(pre_delta)) + 10_000_000 else 10_000_000 -| @as(u64, @intCast(-pre_delta));
            }
        }
        const pre_at = computeAutotuneDecision(@intCast(compat.timestamp()), true, prev_stats.recommend_profile_code, prev_stats.recommend_blocks, prev_stats.recommend_seconds, prev_stats.recommend_pressure, at_peer_d, at_ka_d, at_blk_us, prev_stats.autotune_profile_current, prev_stats.autotune_last_change_unix, pre_wr, pre_kd);
        max_blocks = @intCast(pre_at.max_blocks);
        max_seconds = @intCast(pre_at.max_seconds);
        std.debug.print("BACKFILL AUTOTUNE PRE: profile={d} caps={d}/{d}\n", .{ pre_at.profile, pre_at.max_blocks, pre_at.max_seconds });
    }

    // BAEY backfill override: if baey/backfill_override.json exists and unexpired,
    // cap to cautious limits (200 blocks / 10 seconds)
    blk_override: {
        if (state_dir.len == 0) break :blk_override;
        const override_path = std.fs.path.join(alloc, &[_][]const u8{ state_dir, "baey", "backfill_override.json" }) catch break :blk_override;
        defer alloc.free(override_path);
        var of = compat.fs.cwd().openFile(override_path, .{}) catch break :blk_override;
        const od = of.deprecatedReader().readAllAlloc(alloc, 4096) catch {
            of.close();
            break :blk_override;
        };
        of.close();
        defer alloc.free(od);
        const expires = parseJsonU64(od, "expires_unix");
        const now_unix: u64 = @intCast(@max(0, compat.timestamp()));
        if (expires > 0 and now_unix < expires) {
            max_blocks = @min(max_blocks, 200);
            max_seconds = @min(max_seconds, 10);
            std.debug.print("BACKFILL: BAEY override active, caps={d}/{d} (expires in {d}s)\n", .{ max_blocks, max_seconds, expires - now_unix });
        } else {
            // Expired: delete the file
            compat.fs.cwd().deleteFile(override_path) catch {};
        }
    }

    // Try process lock (stale threshold: 3x max_seconds, minimum 120s)
    const lock_age = @max(max_seconds * 3, 120);
    if (!tryAcquireLock(lock_path, lock_age)) {
        std.debug.print("lmdb-backfill-inc: BUSY (another instance running)\n", .{});
        prev_stats.busy_total += 1;
        writeStatsJson(alloc, stats_path, prev_stats.runs_total, prev_stats.blocks_total, 0, 0, prev_stats.busy_total, prev_stats.errors_total, "", 0, 0, 0, 0, 0, 0, null, prev_stats.cursor_desync_total, prev_stats.cursor_resync_total, prev_stats.cursor_resync_fail_total, prev_stats.cursor_resync_last_unix, prev_stats.eof_idle_total, prev_stats.eof_idle_last_unix, prev_stats.segments_deleted_total, prev_stats.segments_deleted_bytes_total, 0, prev_stats.idle_skips_total, prev_stats.idle_last_unix, prev_stats.gap_resolved_total, 0, prev_stats.gap_unresolved_last, prev_stats.recommend_profile_code, prev_stats.recommend_blocks, prev_stats.recommend_seconds, prev_stats.recommend_pressure, prev_stats.gap_keys_loaded_last, prev_stats.produced_total_last, prev_stats.gap_hit_ratio_last_x1e6, prev_stats.gap_consumed_seen_last, prev_stats.gap_consumed_resolved_last, prev_stats.gap_consumed_seen_total, prev_stats.gap_consumed_resolved_total, prev_stats.autotune_enabled_last, prev_stats.autotune_profile_current, prev_stats.autotune_last_change_unix, prev_stats.autotune_switch_total, prev_stats.autotune_reason_code_last);
        return;
    }
    defer releaseLock(lock_path);

    // Scan captures directory
    var dir = compat.fs.cwd().openDir(captures_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("lmdb-backfill-inc: cannot open dir: {s} ({s})\n", .{ captures_dir, @errorName(err) });
        return err;
    };
    defer dir.close();

    var names = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (names.items) |s| alloc.free(s);
        names.deinit();
    }

    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind != .file) continue;
        if (!isCaptureFile(e.name)) continue;
        try names.append(try alloc.dupe(u8, e.name));
    }

    if (names.items.len == 0) {
        std.debug.print("lmdb-backfill-inc: no capture files found\n", .{});
        return;
    }

    // Sort: rotated files (<net>.<ts>.bin) first in lex order, active <net>.bin last
    const active_name = capture_mod.activeFileName();
    std.sort.insertion([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            const a_active = !capture_mod.isRotatedCapture(a);
            const b_active = !capture_mod.isRotatedCapture(b);
            if (a_active and !b_active) return false;
            if (!a_active and b_active) return true;
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    std.debug.print("lmdb-backfill-inc: found {d} capture file(s)\n", .{names.items.len});

    // Operator hint: single active file below rotation threshold
    if (names.items.len == 1 and std.mem.eql(u8, names.items[0], active_name)) {
        const rot_bytes = getEffectiveRotateBytes(alloc);
        if (dir.statFile(active_name)) |st| {
            if (st.size < rot_bytes) {
                std.debug.print("BACKFILL: waiting for first rotation ({s} size={d}MB, rotate_at={d}MB)\n", .{ active_name, st.size / (1024 * 1024), rot_bytes / (1024 * 1024) });
            }
        } else |_| {}
    }

    // Read cursor
    var start_file_idx: usize = 0;
    var start_offset: u64 = 0;
    var cumul_blocks: u64 = prev_stats.blocks_total;
    var cumul_runs: u64 = prev_stats.runs_total;

    if (readCursorJson(alloc, cursor_path)) |cur| {
        defer alloc.free(cur.file_name);
        // Use cursor's cumulative totals if they're higher (authoritative)
        if (cur.blocks_applied_total > cumul_blocks) cumul_blocks = cur.blocks_applied_total;
        if (cur.runs_total > cumul_runs) cumul_runs = cur.runs_total;

        var found = false;
        for (names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, cur.file_name)) {
                start_file_idx = i;
                start_offset = cur.byte_offset;
                found = true;
                break;
            }
        }
        if (found) {
            std.debug.print("BACKFILL CURSOR: file={s} offset={d} runs={d} blocks={d}\n", .{ cur.file_name, cur.byte_offset, cur.runs_total, cur.blocks_applied_total });
        } else {
            std.debug.print("lmdb-backfill-inc: cursor file {s} not found in captures, starting from beginning\n", .{cur.file_name});
        }
    } else |err| switch (err) {
        CursorError.FileNotFound => {
            std.debug.print("lmdb-backfill-inc: no cursor file, starting from beginning\n", .{});
        },
        CursorError.InvalidCursor => {
            std.debug.print("BACKFILL CURSOR ERROR: {s} failed to parse (corrupt or unreadable)\n", .{cursor_path});
            // Rename bad cursor to <path>.bad.<unix>
            const now_ts: u64 = @intCast(compat.timestamp());
            const bad_path = std.fmt.allocPrint(alloc, "{s}.bad.{d}", .{ cursor_path, now_ts }) catch null;
            if (bad_path) |bp| {
                defer alloc.free(bp);
                compat.fs.cwd().rename(cursor_path, bp) catch {};
                std.debug.print("BACKFILL CURSOR ERROR: renamed to {s}\n", .{bp});
            }
            if (!reset_cursor) {
                std.debug.print("BACKFILL CURSOR ERROR: pass --reset-cursor to start from offset=0\n", .{});
                return error.InvalidCursor;
            }
            std.debug.print("BACKFILL CURSOR: --reset-cursor active, starting from offset=0\n", .{});
        },
    }

    // Idle skip: if cursor is on the last file and no new bytes exist, exit without counting as a run
    if (start_file_idx == names.items.len - 1 and start_offset > 0) {
        const skip_name = names.items[start_file_idx];
        const skip_path = std.fs.path.join(alloc, &[_][]const u8{ captures_dir, skip_name }) catch null;
        if (skip_path) |sp| {
            defer alloc.free(sp);
            if (compat.fs.cwd().openFile(sp, .{})) |sf| {
                var skip_file = sf;
                const skip_size: u64 = blk: {
                    const stat = skip_file.stat() catch break :blk 0;
                    break :blk stat.size;
                };
                skip_file.close();
                if (skip_size > 0 and skip_size <= start_offset + 4) {
                    // No new data — idle skip
                    const new_idle_skips = prev_stats.idle_skips_total + 1;
                    const now_idle: u64 = @intCast(compat.timestamp());
                    std.debug.print("BACKFILL: idle skip (no new bytes) file={s} offset={d} size={d}\n", .{ skip_name, start_offset, skip_size });
                    const cur_is_active: u64 = if (!capture_mod.isRotatedCapture(skip_name)) 1 else 0;
                    writeStatsJson(alloc, stats_path, cumul_runs, cumul_blocks, 0, 0, prev_stats.busy_total, prev_stats.errors_total, skip_name, start_offset, 0, names.items.len, start_file_idx, skip_size, if (skip_size > 0) @min(1_000_000, (start_offset * 1_000_000) / skip_size) else 0, adapt_result, prev_stats.cursor_desync_total, prev_stats.cursor_resync_total, prev_stats.cursor_resync_fail_total, prev_stats.cursor_resync_last_unix, prev_stats.eof_idle_total, prev_stats.eof_idle_last_unix, prev_stats.segments_deleted_total, prev_stats.segments_deleted_bytes_total, cur_is_active, new_idle_skips, now_idle, prev_stats.gap_resolved_total, 0, prev_stats.gap_unresolved_last, prev_stats.recommend_profile_code, prev_stats.recommend_blocks, prev_stats.recommend_seconds, prev_stats.recommend_pressure, prev_stats.gap_keys_loaded_last, prev_stats.produced_total_last, prev_stats.gap_hit_ratio_last_x1e6, prev_stats.gap_consumed_seen_last, prev_stats.gap_consumed_resolved_last, prev_stats.gap_consumed_seen_total, prev_stats.gap_consumed_resolved_total, prev_stats.autotune_enabled_last, prev_stats.autotune_profile_current, prev_stats.autotune_last_change_unix, prev_stats.autotune_switch_total, prev_stats.autotune_reason_code_last);
                    return;
                }
            } else |_| {}
        }
    }

    // Open LMDB
    const lmdb_dir_z = try alloc.dupeZ(u8, lmdb_dir);
    defer alloc.free(lmdb_dir_z);

    var store = lmdb_utxo.LmdbUtxo.open(lmdb_dir_z) catch |err| {
        std.debug.print("lmdb-backfill-inc: LMDB open failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer store.close();

    const start_time = compat.timestamp();
    var total_blocks: usize = 0;
    var total_applied: usize = 0;
    var total_errors: usize = 0;
    var last_file_name: []const u8 = "";
    var last_offset: u64 = 0;
    var desync_total: u64 = 0;
    var resync_total: u64 = 0;
    var resync_fail_total: u64 = 0;
    var resync_last_unix: u64 = 0;
    var eof_idle: bool = false;
    var eof_idle_file: []const u8 = "";
    var eof_idle_offset: u64 = 0;
    var eof_idle_file_size: u64 = 0;
    var segments_deleted: u64 = 0;
    var segments_deleted_bytes: u64 = 0;

    // Process files from cursor position
    var file_idx = start_file_idx;
    outer: while (file_idx < names.items.len) {
        const name = names.items[file_idx];
        const full_path = try std.fs.path.join(alloc, &[_][]const u8{ captures_dir, name });
        defer alloc.free(full_path);

        var f = compat.fs.cwd().openFile(full_path, .{}) catch |err| {
            std.debug.print("lmdb-backfill-inc: cannot open {s}: {s}\n", .{ name, @errorName(err) });
            file_idx += 1;
            continue;
        };
        defer f.close();

        // Get file size for desync detection
        const cur_file_size: u64 = blk: {
            const stat = f.stat() catch break :blk 0;
            break :blk stat.size;
        };

        // Seek if this is the cursor file
        var seek_offset: u64 = if (file_idx == start_file_idx) start_offset else 0;

        // Detect file-rotation: cursor offset exceeds file size → file was rotated, restart from 0
        if (seek_offset > 0 and cur_file_size > 0 and seek_offset > cur_file_size) {
            std.debug.print("BACKFILL: cursor offset={d} > file_size={d} for {s} (file rotated?), resetting to 0\n", .{ seek_offset, cur_file_size, name });
            seek_offset = 0;
        }

        if (seek_offset > 0) {
            f.seekTo(seek_offset) catch {
                std.debug.print("lmdb-backfill-inc: seek failed {s} offset={d}\n", .{ name, seek_offset });
                file_idx += 1;
                continue;
            };
        }

        var r = f.deprecatedReader();
        var current_offset: u64 = seek_offset;
        last_file_name = name;
        last_offset = seek_offset;

        while (true) {
            // Check stop conditions
            if (total_blocks >= max_blocks) break :outer;
            const elapsed = compat.timestamp() - start_time;
            if (elapsed >= max_seconds) break :outer;

            // Read record: [u32le len][payload]
            var len_buf: [4]u8 = undefined;
            const n = r.readAll(&len_buf) catch break;
            if (n == 0) {
                // EOF — no new records yet
                if (total_blocks == 0) {
                    eof_idle = true;
                    eof_idle_file = name;
                    eof_idle_offset = current_offset;
                    eof_idle_file_size = cur_file_size;
                }
                break;
            }
            if (n != 4) break; // truncated

            const len = std.mem.readInt(u32, &len_buf, .little);
            if (len == 0) {
                current_offset += 4;
                continue;
            }

            // Desync detection: implausible record length
            if (len < RECORD_MIN_LEN or len > RECORD_MAX_LEN or (cur_file_size > 0 and current_offset + 4 + len > cur_file_size)) {
                desync_total += 1;
                std.debug.print("BACKFILL DESYNC: offset={d} bad_len={d} file_size={d}\n", .{ current_offset, len, cur_file_size });

                // Attempt auto-resync
                if (resyncCursorForward(full_path, current_offset + 1, cur_file_size)) |new_off| {
                    resync_total += 1;
                    resync_last_unix = @intCast(compat.timestamp());
                    std.debug.print("BACKFILL RESYNC: old_off={d} new_off={d}\n", .{ current_offset, new_off });
                    // Update cursor and re-seek
                    current_offset = new_off;
                    last_offset = new_off;
                    writeCursorJson(alloc, cursor_path, name, new_off, cumul_blocks + total_applied, cumul_runs + 1);
                    f.seekTo(new_off) catch break;
                    r = f.deprecatedReader();
                    continue;
                } else {
                    resync_fail_total += 1;
                    std.debug.print("BACKFILL RESYNC FAIL: old_off={d} scanned={d} bytes\n", .{ current_offset, RESYNC_SCAN_MAX });
                    break; // Exit this file cleanly
                }
            }

            const payload = alloc.alloc(u8, len) catch break;
            defer alloc.free(payload);
            r.readNoEof(payload) catch break; // truncated trailing = EOF

            current_offset += 4 + len;
            last_offset = current_offset;
            total_blocks += 1;

            // Decode and apply
            const deltas = decodePayloadToDeltas(alloc, payload, false) catch |err| {
                total_errors += 1;
                if (strict) {
                    std.debug.print("lmdb-backfill-inc: decode fail block[{d}] err={s}\n", .{ total_blocks, @errorName(err) });
                    return error.DecodeError;
                }
                continue;
            };
            defer tx_decode.freeTxDeltas(alloc, deltas);

            const txn0 = store.beginWrite() orelse {
                total_errors += 1;
                if (strict) return error.LmdbTxnBeginFailed;
                continue;
            };
            var txn = txn0;

            for (deltas.consumed) |c0| {
                store.delTxn(&txn, c0.tx_hash, c0.index);
                // Gap coverage: check if this consumed TxIn is a known gap key
                if (gap_keys) |*gk| {
                    var ckey: [36]u8 = undefined;
                    @memcpy(ckey[0..32], c0.tx_hash[0..32]);
                    std.mem.writeInt(u32, ckey[32..36], c0.index, .little);
                    if (gk.get(ckey) != null) {
                        gap_consumed_seen += 1;
                        gap_consumed_seen_keys.put(ckey, {}) catch {};
                    }
                }
            }
            for (deltas.produced) |p0| {
                store.putTxn(alloc, &txn, p0.input.tx_hash, p0.input.index, p0.output);
                // Gap hunter: check if this produced output resolves a gap key
                if (gap_keys) |*gk| {
                    var key: [36]u8 = undefined;
                    @memcpy(key[0..32], p0.input.tx_hash[0..32]);
                    std.mem.writeInt(u32, key[32..36], p0.input.index, .little);
                    if (gk.remove(key)) {
                        gap_resolved_this_run += 1;
                    }
                }
            }
            produced_total_this_run += deltas.produced.len;

            const ok = store.commit(&txn);
            if (!ok) {
                total_errors += 1;
                if (strict) return error.LmdbCommitFailed;
                continue;
            }

            total_applied += 1;

            // Save cursor periodically
            if ((total_applied % CURSOR_SAVE_INTERVAL) == 0) {
                writeCursorJson(alloc, cursor_path, name, current_offset, cumul_blocks + total_applied, cumul_runs + 1);
                if ((total_applied % 100) == 0) {
                    std.debug.print("lmdb-backfill-inc: progress blocks={d} applied={d} file={s}\n", .{ total_blocks, total_applied, name });
                }
            }
        }

        // Save cursor at end of file
        last_file_name = name;
        last_offset = current_offset;

        // Check if rotated segment was fully consumed → eligible for deletion
        const fully_consumed = cur_file_size > 0 and current_offset >= cur_file_size;
        if (fully_consumed and isRotatedSegment(name)) {
            // Determine next file name for cursor advancement
            const next_idx = file_idx + 1;
            const next_name: []const u8 = if (next_idx < names.items.len) names.items[next_idx] else capture_mod.activeFileName();

            // Delete the consumed rotated segment
            const del_path = std.fs.path.join(alloc, &[_][]const u8{ captures_dir, name }) catch null;
            if (del_path) |dp| {
                defer alloc.free(dp);
                compat.fs.cwd().deleteFile(dp) catch |err| {
                    std.debug.print("BACKFILL CLEANUP: failed to delete {s}: {s}\n", .{ name, @errorName(err) });
                };
            }

            segments_deleted += 1;
            segments_deleted_bytes += cur_file_size;
            std.debug.print("BACKFILL CLEANUP: deleted={s} bytes={d} next={s}\n", .{ name, cur_file_size, next_name });

            // Advance cursor to next file at offset 0
            last_file_name = next_name;
            last_offset = 0;
            writeCursorJson(alloc, cursor_path, next_name, 0, cumul_blocks + total_applied, cumul_runs + 1);
        } else {
            writeCursorJson(alloc, cursor_path, name, current_offset, cumul_blocks + total_applied, cumul_runs + 1);
        }

        file_idx += 1;
    }

    // Final cursor + stats save (always, even if 0 blocks)
    const new_cumul_blocks = cumul_blocks + total_applied;
    const new_cumul_runs = cumul_runs + 1;
    const new_cumul_errors = prev_stats.errors_total + @as(u64, @intCast(total_errors));
    const elapsed_final = compat.timestamp() - start_time;
    const elapsed_ms: u64 = if (elapsed_final > 0) @intCast(elapsed_final * 1000) else 0;

    if (last_file_name.len > 0) {
        writeCursorJson(alloc, cursor_path, last_file_name, last_offset, new_cumul_blocks, new_cumul_runs);
    } else {
        // No files were processed — still write cursor with empty state
        writeCursorJson(alloc, cursor_path, "", 0, new_cumul_blocks, new_cumul_runs);
    }

    // Compute segment info for stats
    const seg_file_count: u64 = names.items.len;
    var seg_file_index: u64 = 0;
    var seg_file_size: u64 = 0;
    if (last_file_name.len > 0) {
        for (names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, last_file_name)) {
                seg_file_index = i;
                break;
            }
        }
        // Get file size via stat
        const seg_full_path = std.fs.path.join(alloc, &[_][]const u8{ captures_dir, last_file_name }) catch null;
        if (seg_full_path) |sfp| {
            defer alloc.free(sfp);
            if (compat.fs.cwd().openFile(sfp, .{})) |sf| {
                var sf_mut = sf;
                defer sf_mut.close();
                const stat = sf_mut.stat() catch null;
                if (stat) |s| seg_file_size = s.size;
            } else |_| {}
        }
    }
    const seg_done_x1e6: u64 = if (seg_file_size > 0)
        @min(1_000_000, (last_offset * 1_000_000) / seg_file_size)
    else
        0;

    const cumul_desync = prev_stats.cursor_desync_total + desync_total;
    const cumul_resync = prev_stats.cursor_resync_total + resync_total;
    const cumul_resync_fail = prev_stats.cursor_resync_fail_total + resync_fail_total;
    const cumul_resync_unix = if (resync_last_unix > 0) resync_last_unix else prev_stats.cursor_resync_last_unix;
    const cumul_eof_idle: u64 = prev_stats.eof_idle_total + @as(u64, if (eof_idle) @as(u64, 1) else 0);
    const now_eof: u64 = if (eof_idle) @intCast(compat.timestamp()) else prev_stats.eof_idle_last_unix;

    if (eof_idle) {
        std.debug.print("BACKFILL: EOF idle (no new records yet) file={s} offset={d} size={d}\n", .{ eof_idle_file, eof_idle_offset, eof_idle_file_size });
    }

    const cumul_seg_deleted = prev_stats.segments_deleted_total + segments_deleted;
    const cumul_seg_deleted_bytes = prev_stats.segments_deleted_bytes_total + segments_deleted_bytes;
    const cur_file_is_active: u64 = if (!capture_mod.isRotatedCapture(last_file_name)) 1 else 0;

    // Gap hunter: persist remaining keys, compute stats
    const gap_unresolved: u64 = if (gap_keys) |gk| @intCast(gk.count()) else 0;
    const cumul_gap_resolved = prev_stats.gap_resolved_total + gap_resolved_this_run;
    if (gap_dir) |gd| {
        persistGapKeysBackfill(alloc, gd, &gap_keys);
    }
    if (gap_resolved_this_run > 0) {
        std.debug.print("GAP HUNTER: resolved={d} unresolved={d} cumulative={d}\n", .{ gap_resolved_this_run, gap_unresolved, cumul_gap_resolved });
    }

    // Gap pressure recommendation
    const gap_rec = if (adaptive and metrics_url.len > 0)
        computeGapRecommendation(alloc, metrics_url, adapt_result)
    else
        GapRecommendation{ .profile_code = 1, .blocks = 500, .seconds = 20, .pressure = 1 };

    // Gap steering: compute hit ratio
    const produced_denom = if (produced_total_this_run > 0) produced_total_this_run else 1;
    const gap_hit_ratio_x1e6 = (gap_resolved_this_run * 1_000_000) / produced_denom;

    // Gap consumed coverage: check which seen consumed keys now exist in LMDB
    var gap_consumed_resolved: u64 = 0;
    if (gap_consumed_seen_keys.count() > 0) {
        if (store.beginRead()) |rtxn_val| {
            var rtxn = rtxn_val;
            var seen_it = gap_consumed_seen_keys.iterator();
            while (seen_it.next()) |entry| {
                const k = entry.key_ptr.*;
                if (store.getTxn(&rtxn, k[0..32].*, std.mem.readInt(u32, k[32..36], .little)) != null) {
                    gap_consumed_resolved += 1;
                }
            }
            store.abort(&rtxn);
        }
    }
    const cumul_consumed_seen = prev_stats.gap_consumed_seen_total + gap_consumed_seen;
    const cumul_consumed_resolved = prev_stats.gap_consumed_resolved_total + gap_consumed_resolved;

    // Autotune decision — fetch gap trend metrics for win-rate policy
    const autotune_on = backfillAutotuneEnabled();
    const now_at: u64 = @intCast(compat.timestamp());
    const at_peer_delta: u64 = if (adapt_result) |ar| ar.peer_closed_delta else 0;
    const at_ka_delta: u64 = if (adapt_result) |ar| ar.keepalive_delta else 0;
    const at_block_us: u64 = if (adapt_result) |ar| ar.block_total_us else 0;
    var at_win_rate_x1e6: u64 = 0;
    var at_keys_delta_raw: u64 = 10_000_000; // offset zero = no change
    if (autotune_on and adaptive and metrics_url.len > 0) {
        if (fetchMetrics(alloc, metrics_url)) |at_raw| {
            defer alloc.free(at_raw);
            at_win_rate_x1e6 = findMetricLineRatioX1e6(at_raw, "tsunagi_gap_win_rate ");
            const delta_signed = findMetricLineSigned(at_raw, "tsunagi_gap_keys_delta_5m ");
            at_keys_delta_raw = if (delta_signed >= 0) @as(u64, @intCast(delta_signed)) + 10_000_000 else 10_000_000 -| @as(u64, @intCast(-delta_signed));
        }
    }
    const at = computeAutotuneDecision(now_at, autotune_on, gap_rec.profile_code, gap_rec.blocks, gap_rec.seconds, gap_rec.pressure, at_peer_delta, at_ka_delta, at_block_us, prev_stats.autotune_profile_current, prev_stats.autotune_last_change_unix, at_win_rate_x1e6, at_keys_delta_raw);
    const at_enabled_u: u64 = if (autotune_on) 1 else 0;
    const at_change_unix = if (at.did_switch) now_at else prev_stats.autotune_last_change_unix;
    const at_switch_total = prev_stats.autotune_switch_total + @as(u64, if (at.did_switch) 1 else 0);

    if (autotune_on) {
        std.debug.print("BACKFILL AUTOTUNE: enabled=1 profile={d} caps={d}/{d} reason={d} switched={d}\n", .{ at.profile, at.max_blocks, at.max_seconds, at.reason, @as(u64, if (at.did_switch) 1 else 0) });
        const at_reason_str: []const u8 = if (at.did_switch) "profile_switch" else "profile_hold";
        baeyLogBackfill(alloc, state_dir, "backfill_autotune", at_reason_str, at.profile, at.max_blocks, at.max_seconds, gap_rec.pressure, at_win_rate_x1e6, at_keys_delta_raw);
    }

    writeStatsJson(alloc, stats_path, new_cumul_runs, new_cumul_blocks, @intCast(total_applied), @intCast(total_errors), prev_stats.busy_total, new_cumul_errors, last_file_name, last_offset, elapsed_ms, seg_file_count, seg_file_index, seg_file_size, seg_done_x1e6, adapt_result, cumul_desync, cumul_resync, cumul_resync_fail, cumul_resync_unix, cumul_eof_idle, now_eof, cumul_seg_deleted, cumul_seg_deleted_bytes, cur_file_is_active, prev_stats.idle_skips_total, prev_stats.idle_last_unix, cumul_gap_resolved, gap_resolved_this_run, gap_unresolved, gap_rec.profile_code, gap_rec.blocks, gap_rec.seconds, gap_rec.pressure, gap_keys_loaded_count, produced_total_this_run, gap_hit_ratio_x1e6, gap_consumed_seen, gap_consumed_resolved, cumul_consumed_seen, cumul_consumed_resolved, at_enabled_u, at.profile, at_change_unix, at_switch_total, at.reason);

    std.debug.print("lmdb-backfill-inc: DONE blocks={d} applied={d} errors={d} elapsed={d}s\n", .{
        total_blocks,
        total_applied,
        total_errors,
        elapsed_final,
    });
    std.debug.print("lmdb-backfill-inc: cumulative runs={d} blocks={d}\n", .{ new_cumul_runs, new_cumul_blocks });
    std.debug.print("BACKFILL GAP: keys_loaded={d} consumed_seen={d} consumed_resolved={d} produced={d} produced_hits={d} ratio=0.{d:0>6}\n", .{ gap_keys_loaded_count, gap_consumed_seen, gap_consumed_resolved, produced_total_this_run, gap_resolved_this_run, gap_hit_ratio_x1e6 });
}
