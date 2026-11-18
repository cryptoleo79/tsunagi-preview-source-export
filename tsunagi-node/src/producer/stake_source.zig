// σ chain-source loader.
//
// Background poller that periodically fetches our pool's on-chain σ
// (active stake fraction) from Koios and exposes a thread-safe snapshot
// for forge-time consumption. ASC (active slot coefficient) is read from
// loaded protocol params if available, else env TSUNAGI_ASC_X1E6 (default
// 50000 = 0.05).
//
// External I/O is via curl (consistent with nonce_evolution.zig) — keeps
// the build TLS-free and the runtime dependencies minimal.
//
// The poller runs every 60s. Each successful fetch updates g_active_snapshot
// under g_snapshot_mu. forgeStakeSnapshot() is the read-side entry point;
// it errors if no usable snapshot exists.

const std = @import("std");
const compat = @import("compat");
const mempool_mod = @import("../net/ledger/mempool.zig");

pub const StakeSnapshot = struct {
    sigma_x1e9: u64,
    asc_x1e6: u64,
    /// Pool's last-registration epoch (Koios `active_epoch_no`). Static for a
    /// given pool until it re-registers. NOT the live stake-snapshot epoch —
    /// kept for telemetry only. Do NOT use for gate freshness; rely on
    /// fetched_unix / snapshotAge() instead.
    pool_reg_epoch: u64,
    fetched_unix: i64,
    source: enum { koios_pool_info, env_fallback, ntc_localstate },
};

pub var g_active_snapshot: ?StakeSnapshot = null;
pub var g_snapshot_mu: compat.Mutex = .{};

const POLL_INTERVAL_MS: u64 = 60 * 1000;
const DEFAULT_ASC_X1E6: u64 = 50_000; // 0.05

const PollerCtx = struct {
    alloc: std.mem.Allocator,
    pool_bech32: [128]u8 = [_]u8{0} ** 128,
    pool_bech32_len: usize = 0,
    net: [16]u8 = [_]u8{0} ** 16,
    net_len: usize = 0,
};

var g_poller_ctx: PollerCtx = .{ .alloc = undefined };
var g_poller_started: bool = false;

fn currentNet() []const u8 {
    if (compat.getenv("TSUNAGI_NETWORK")) |v| {
        const t = std.mem.trim(u8, v, " \t");
        if (t.len > 0) return t;
    }
    return "preview";
}

fn currentAscX1e6() u64 {
    // Prefer loaded protocol params if a future field exposes ASC; today
    // ProtocolParams has no asc field, so this is a forward-looking hook.
    // (Keeping the dispatch here so the call site remains stable.)
    if (mempool_mod.g_protocol_params) |_| {
        // No asc field in ProtocolParams yet — fall through to env.
    }
    if (compat.getenv("TSUNAGI_ASC_X1E6")) |v| {
        const t = std.mem.trim(u8, v, " \t");
        if (std.fmt.parseUnsigned(u64, t, 10)) |n| {
            if (n > 0) return n;
        } else |_| {}
    }
    return DEFAULT_ASC_X1E6;
}

/// Convert a float-string sigma like "0.00041985" to u64 sigma_x1e9.
/// Truncates extra fractional digits past 1e-9. Returns null on parse error.
pub fn parseSigmaX1e9(s: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n\"");
    if (trimmed.len == 0) return null;

    var int_part: u64 = 0;
    var frac_digits: [9]u8 = [_]u8{'0'} ** 9;
    var seen_dot: bool = false;
    var frac_idx: usize = 0;

    for (trimmed) |c| {
        if (c == '.') {
            if (seen_dot) return null;
            seen_dot = true;
            continue;
        }
        if (c < '0' or c > '9') return null;
        if (!seen_dot) {
            int_part = int_part *% 10 +% @as(u64, c - '0');
        } else if (frac_idx < 9) {
            frac_digits[frac_idx] = c;
            frac_idx += 1;
        } else {
            // truncate further digits
        }
    }

    var frac_x1e9: u64 = 0;
    for (frac_digits) |d| {
        frac_x1e9 = frac_x1e9 * 10 + @as(u64, d - '0');
    }
    return int_part * 1_000_000_000 + frac_x1e9;
}

/// Extract the first JSON string value for a given key from a Koios response.
/// Looks for `"key":"<value>"` and returns <value> as a slice into `body`.
fn jsonStringField(body: []const u8, key: []const u8) ?[]const u8 {
    var pat_buf: [64]u8 = undefined;
    if (key.len + 4 > pat_buf.len) return null;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, body, pat) orelse return null;
    const start = idx + pat.len;
    if (start >= body.len) return null;
    const rel_end = std.mem.indexOfScalar(u8, body[start..], '"') orelse return null;
    return body[start .. start + rel_end];
}

/// Extract first JSON numeric value for `key`. Accepts integer, decimal,
/// or quoted form. Returns the slice (without quotes) into `body`.
fn jsonNumericField(body: []const u8, key: []const u8) ?[]const u8 {
    // Try quoted form first.
    if (jsonStringField(body, key)) |v| return v;

    var pat_buf: [64]u8 = undefined;
    if (key.len + 3 > pat_buf.len) return null;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, body, pat) orelse return null;
    var start = idx + pat.len;
    while (start < body.len and (body[start] == ' ' or body[start] == '\t')) : (start += 1) {}
    var end = start;
    while (end < body.len) : (end += 1) {
        const c = body[end];
        if ((c >= '0' and c <= '9') or c == '.' or c == '-' or c == '+' or c == 'e' or c == 'E') continue;
        break;
    }
    if (end == start) return null;
    return body[start..end];
}

/// Perform one fetch of pool_info from Koios. On success, writes a fresh
/// snapshot into g_active_snapshot under the mutex.
fn fetchOnce(ctx: *PollerCtx) bool {
    const pool = ctx.pool_bech32[0..ctx.pool_bech32_len];
    const net = ctx.net[0..ctx.net_len];

    const base = if (std.mem.eql(u8, net, "preview"))
        "https://preview.koios.rest"
    else if (std.mem.eql(u8, net, "preprod"))
        "https://preprod.koios.rest"
    else
        "https://api.koios.rest";

    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/api/v1/pool_info", .{base}) catch return false;

    var body_buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{{\"_pool_bech32_ids\":[\"{s}\"]}}", .{pool}) catch return false;

    var argv = [_][]const u8{
        "curl",
        "-sf",
        "-X",
        "POST",
        "-H",
        "Content-Type: application/json",
        "-d",
        body,
        url,
    };

    var child = compat.Child.init(&argv, std.heap.page_allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        std.debug.print("STAKE_SOURCE_FETCH: curl spawn failed pool={s}\n", .{pool});
        return false;
    };

    var resp_buf: [16384]u8 = undefined;
    const stdout_file = child.stdout orelse {
        _ = child.wait() catch {};
        return false;
    };
    const n = stdout_file.readAll(&resp_buf) catch {
        _ = child.wait() catch {};
        return false;
    };
    const result = child.wait() catch return false;
    const exited_ok = switch (result) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited_ok or n == 0) {
        std.debug.print("STAKE_SOURCE_FETCH: curl failed pool={s} exit={any} bytes={d}\n", .{ pool, result, n });
        return false;
    }
    const resp = resp_buf[0..n];

    const sigma_str = jsonNumericField(resp, "sigma") orelse {
        std.debug.print("STAKE_SOURCE_FETCH: missing sigma in response\n", .{});
        return false;
    };
    const sigma_x1e9 = parseSigmaX1e9(sigma_str) orelse {
        std.debug.print("STAKE_SOURCE_FETCH: bad sigma '{s}'\n", .{sigma_str});
        return false;
    };

    // Koios `active_epoch_no` is the pool's registration-activation epoch,
    // NOT the live stake-snapshot epoch. The σ returned by /pool_info IS the
    // current live σ, refreshed every Koios poll. We keep this value for
    // telemetry only (under name pool_reg_epoch) and never gate on it.
    var pool_reg_epoch: u64 = 0;
    if (jsonNumericField(resp, "active_epoch_no")) |s| {
        pool_reg_epoch = std.fmt.parseUnsigned(u64, std.mem.trim(u8, s, " \t\""), 10) catch 0;
    }

    const snap: StakeSnapshot = .{
        .sigma_x1e9 = sigma_x1e9,
        .asc_x1e6 = currentAscX1e6(),
        .pool_reg_epoch = pool_reg_epoch,
        .fetched_unix = compat.timestamp(),
        .source = .koios_pool_info,
    };

    g_snapshot_mu.lock();
    g_active_snapshot = snap;
    g_snapshot_mu.unlock();

    std.debug.print("STAKE_SOURCE_FETCH: success sigma_x1e9={d} asc_x1e6={d} pool_reg_epoch={d}\n", .{
        snap.sigma_x1e9, snap.asc_x1e6, snap.pool_reg_epoch,
    });
    return true;
}

fn pollerThread(ctx: *PollerCtx) void {
    std.debug.print("STAKE_SOURCE_POLLER: started pool={s} net={s} interval_ms={d}\n", .{
        ctx.pool_bech32[0..ctx.pool_bech32_len],
        ctx.net[0..ctx.net_len],
        POLL_INTERVAL_MS,
    });
    while (true) {
        _ = fetchOnce(ctx);
        compat.sleep(POLL_INTERVAL_MS * std.time.ns_per_ms);
    }
}

/// Spawn the background poller. Idempotent; subsequent calls are no-ops.
pub fn spawnBackground(alloc: std.mem.Allocator, pool_bech32: []const u8) bool {
    if (g_poller_started) return true;
    if (pool_bech32.len == 0 or pool_bech32.len > g_poller_ctx.pool_bech32.len) {
        std.debug.print("STAKE_SOURCE_SPAWN: invalid pool bech32 len={d}\n", .{pool_bech32.len});
        return false;
    }

    g_poller_ctx.alloc = alloc;
    @memcpy(g_poller_ctx.pool_bech32[0..pool_bech32.len], pool_bech32);
    g_poller_ctx.pool_bech32_len = pool_bech32.len;

    const net = currentNet();
    const net_n = @min(net.len, g_poller_ctx.net.len);
    @memcpy(g_poller_ctx.net[0..net_n], net[0..net_n]);
    g_poller_ctx.net_len = net_n;

    const thread = std.Thread.spawn(.{}, pollerThread, .{&g_poller_ctx}) catch {
        std.debug.print("STAKE_SOURCE_SPAWN: thread spawn failed\n", .{});
        return false;
    };
    thread.detach();
    g_poller_started = true;
    std.debug.print("STAKE_SOURCE_SPAWN: ready pool={s} net={s}\n", .{ pool_bech32, net });
    return true;
}

pub const StakeSourceError = error{
    NoSnapshot,
    SnapshotEpochMismatch,
};

/// Read-side entry. Returns the active snapshot if one exists. The
/// `current_epoch` parameter is retained for API stability but no longer
/// gates on epoch matching — Koios `/pool_info` σ is always the live live
/// value and we have no per-epoch endpoint. Freshness is the caller's
/// responsibility via snapshotAge() (60s poll cadence).
/// Falls back to an env_fallback snapshot from TSUNAGI_SIGMA_X1E9 if set.
pub fn forgeStakeSnapshot(current_epoch: u64) !StakeSnapshot {
    _ = current_epoch;
    g_snapshot_mu.lock();
    const snap_opt = g_active_snapshot;
    g_snapshot_mu.unlock();

    if (snap_opt) |s| return s;

    if (compat.getenv("TSUNAGI_SIGMA_X1E9")) |v| {
        const t = std.mem.trim(u8, v, " \t");
        if (std.fmt.parseUnsigned(u64, t, 10)) |n| {
            return StakeSnapshot{
                .sigma_x1e9 = n,
                .asc_x1e6 = currentAscX1e6(),
                .pool_reg_epoch = 0,
                .fetched_unix = compat.timestamp(),
                .source = .env_fallback,
            };
        } else |_| {}
    }

    return error.NoSnapshot;
}

/// Seconds since the active snapshot was fetched. Returns -1 if none.
pub fn snapshotAge() i64 {
    g_snapshot_mu.lock();
    defer g_snapshot_mu.unlock();
    if (g_active_snapshot) |s| {
        return compat.timestamp() - s.fetched_unix;
    }
    return -1;
}

/// True iff a stake snapshot exists. Epoch matching was removed because
/// Koios `/pool_info` σ is always live (no per-epoch endpoint), and
/// pool_reg_epoch is a registration marker that does not advance every
/// epoch. The `epoch` parameter is retained for API stability.
pub fn snapshotMatchesEpoch(epoch: u64) bool {
    _ = epoch;
    g_snapshot_mu.lock();
    defer g_snapshot_mu.unlock();
    if (g_active_snapshot) |_| {
        return true;
    }
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────

test "parseSigmaX1e9 handles typical Koios value" {
    try std.testing.expectEqual(@as(u64, 419_850), parseSigmaX1e9("0.00041985").?);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), parseSigmaX1e9("1.0").?);
    try std.testing.expectEqual(@as(u64, 0), parseSigmaX1e9("0").?);
    try std.testing.expectEqual(@as(u64, 1_500_000_000), parseSigmaX1e9("1.5").?);
}

test "parseSigmaX1e9 rejects junk" {
    try std.testing.expect(parseSigmaX1e9("not a number") == null);
    try std.testing.expect(parseSigmaX1e9("1.2.3") == null);
    try std.testing.expect(parseSigmaX1e9("") == null);
}

test "parseSigmaX1e9 truncates beyond 1e-9" {
    // 0.0000000001 — past 1e-9 → truncates to 0
    try std.testing.expectEqual(@as(u64, 0), parseSigmaX1e9("0.0000000001").?);
    // 0.000000001 → exactly 1
    try std.testing.expectEqual(@as(u64, 1), parseSigmaX1e9("0.000000001").?);
}

test "jsonStringField extracts known key" {
    const body = "[{\"sigma\":\"0.00041985\",\"active_epoch_no\":1285}]";
    const v = jsonStringField(body, "sigma").?;
    try std.testing.expect(std.mem.eql(u8, v, "0.00041985"));
}

test "jsonNumericField handles unquoted integer" {
    const body = "[{\"sigma\":\"0.00041985\",\"active_epoch_no\":1285}]";
    const v = jsonNumericField(body, "active_epoch_no").?;
    try std.testing.expect(std.mem.eql(u8, v, "1285"));
}

test "forgeStakeSnapshot returns NoSnapshot when empty" {
    g_snapshot_mu.lock();
    g_active_snapshot = null;
    g_snapshot_mu.unlock();
    // Note: TSUNAGI_SIGMA_X1E9 may be unset in test env; this should NoSnapshot.
    if (compat.getenv("TSUNAGI_SIGMA_X1E9") == null) {
        try std.testing.expectError(error.NoSnapshot, forgeStakeSnapshot(0));
    }
}

test "forgeStakeSnapshot returns active snapshot regardless of current epoch" {
    g_snapshot_mu.lock();
    g_active_snapshot = .{
        .sigma_x1e9 = 419_850,
        .asc_x1e6 = 50_000,
        .pool_reg_epoch = 1273,
        .fetched_unix = 1_700_000_000,
        .source = .koios_pool_info,
    };
    g_snapshot_mu.unlock();

    // Snapshot must be returned for any current_epoch — pool_reg_epoch is
    // a registration marker, not a per-epoch snapshot tag.
    const s = try forgeStakeSnapshot(1285);
    try std.testing.expectEqual(@as(u64, 419_850), s.sigma_x1e9);

    const ahead = try forgeStakeSnapshot(1294);
    try std.testing.expectEqual(@as(u64, 419_850), ahead.sigma_x1e9);

    const any = try forgeStakeSnapshot(0);
    try std.testing.expectEqual(@as(u64, 419_850), any.sigma_x1e9);

    g_snapshot_mu.lock();
    g_active_snapshot = null;
    g_snapshot_mu.unlock();
}

test "snapshotMatchesEpoch returns true whenever a snapshot exists" {
    g_snapshot_mu.lock();
    g_active_snapshot = .{
        .sigma_x1e9 = 1,
        .asc_x1e6 = 50_000,
        .pool_reg_epoch = 1273,
        .fetched_unix = 0,
        .source = .koios_pool_info,
    };
    g_snapshot_mu.unlock();

    try std.testing.expect(snapshotMatchesEpoch(1285));
    try std.testing.expect(snapshotMatchesEpoch(1294));

    g_snapshot_mu.lock();
    g_active_snapshot = null;
    g_snapshot_mu.unlock();

    try std.testing.expect(!snapshotMatchesEpoch(1285));
}
