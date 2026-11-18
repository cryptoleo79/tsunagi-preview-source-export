// Hardfork Readiness Layer — Protocol Watcher
//
// Background thread that queries Koios every 60s for current epoch_params,
// parses protocol version + block/tx size limits, updates g_protocol_params,
// and sets g_fork_state.fork_pending when major version increments.
//
// Failsafe: Koios failure leaves existing params intact. Genesis/file sources
// remain authoritative when Koios is unavailable.

const std = @import("std");
const compat = @import("compat");
const shutdown = @import("../ops/shutdown.zig");
const mempool_mod = @import("../net/ledger/mempool.zig");
const ntc_client = @import("../net/ntc/ntc_client.zig");

pub const PoolParams = ntc_client.PoolParams;

const REFRESH_INTERVAL_S: u64 = 60;
const INITIAL_WAIT_S: u64 = 5;

fn curlFetch(alloc: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    var child = compat.Child.init(argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;
    const stdout_file = child.stdout orelse {
        _ = child.wait() catch {};
        return null;
    };
    var response_buf: [32768]u8 = undefined;
    const n = stdout_file.readAll(&response_buf) catch {
        _ = child.wait() catch {};
        return null;
    };
    const result = child.wait() catch return null;
    const exited_ok = switch (result) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited_ok or n == 0) return null;
    return alloc.dupe(u8, response_buf[0..n]) catch null;
}

fn parseU64Field(body: []const u8, key: []const u8) ?u64 {
    if (std.mem.indexOf(u8, body, key)) |idx| {
        const start = idx + key.len;
        var end = start;
        // Skip leading quote if present
        var ps = start;
        if (ps < body.len and body[ps] == '"') ps += 1;
        end = ps;
        while (end < body.len and body[end] >= '0' and body[end] <= '9') end += 1;
        if (end > ps) return std.fmt.parseUnsigned(u64, body[ps..end], 10) catch null;
    }
    return null;
}

fn koiosBase(net: []const u8) []const u8 {
    if (std.mem.eql(u8, net, "preview")) return "https://preview.koios.rest";
    if (std.mem.eql(u8, net, "preprod")) return "https://preprod.koios.rest";
    return "https://api.koios.rest";
}

/// Try the local cardano-node NtC socket first. Returns true only if we
/// fetched and installed authoritative protocol params from the local node.
/// Falls through to Koios on null (socket missing, version mismatch, LSQ
/// codec incomplete). TSUNAGI_NTC_ENABLE=1 + TSUNAGI_NTC_SOCKET required.
fn tryFetchViaNtc(alloc: std.mem.Allocator, net: []const u8) bool {
    const socket_path = ntc_client.enabledSocketPath() orelse return false;
    const magic: u64 = if (std.mem.eql(u8, net, "mainnet")) 764824073 else 2;
    const pp = ntc_client.tryFetchProtocolParams(alloc, socket_path, magic) orelse return false;

    mempool_mod.g_protocol_params = .{
        .min_fee_a = pp.min_fee_a,
        .min_fee_b = pp.min_fee_b,
        .min_utxo_value = 0,
        .max_tx_size = pp.max_tx_size,
        .utxo_cost_per_byte = pp.coins_per_utxo_byte,
        .source = 3,
        .reload_unix = compat.timestamp(),
        .protocol_major = pp.protocol_major,
        .protocol_minor = pp.protocol_minor,
        .max_block_body_size = pp.max_block_body_size,
    };
    mempool_mod.g_fork_state.last_known_major = pp.protocol_major;
    mempool_mod.g_fork_state.last_known_minor = pp.protocol_minor;

    std.debug.print("PROTOCOL_UPDATE: major={d} minor={d} max_block={d} max_tx={d} source=ntc net={s}\n", .{
        pp.protocol_major, pp.protocol_minor, pp.max_block_body_size, pp.max_tx_size, net,
    });
    std.debug.print("PROTOCOL_SOURCE: source=ntc\n", .{});
    return true;
}

/// Fetch + parse. Returns true on success (g_protocol_params updated).
/// Prefers local cardano-node NtC socket (via TSUNAGI_NTC_ENABLE=1) and
/// falls back to Koios for backward compat.
pub fn fetchOnce(alloc: std.mem.Allocator, net: []const u8, epoch: u64) bool {
    if (tryFetchViaNtc(alloc, net)) return true;
    const base = koiosBase(net);
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/api/v1/epoch_params?_epoch_no={d}", .{ base, epoch }) catch return false;
    const argv = [_][]const u8{ "curl", "-sf", url };
    const resp = curlFetch(alloc, &argv) orelse {
        std.debug.print("PROTOCOL_FETCH_FAIL: curl_error epoch={d}\n", .{epoch});
        return false;
    };
    defer alloc.free(resp);

    // Parse fields we care about. Koios returns quoted strings for u64 values.
    const pmaj = parseU64Field(resp, "\"protocol_major\":") orelse 0;
    const pmin = parseU64Field(resp, "\"protocol_minor\":") orelse 0;
    const mbsz = parseU64Field(resp, "\"max_block_size\":") orelse 0;
    const mtxsz = parseU64Field(resp, "\"max_tx_size\":") orelse 0;
    const fee_a = parseU64Field(resp, "\"min_fee_a\":") orelse 0;
    const fee_b = parseU64Field(resp, "\"min_fee_b\":") orelse 0;
    const min_utxo = parseU64Field(resp, "\"min_utxo_value\":") orelse 0;
    const cost_per_byte = parseU64Field(resp, "\"coins_per_utxo_size\":") orelse
        (parseU64Field(resp, "\"utxo_cost_per_byte\":") orelse 0);

    if (pmaj == 0) {
        std.debug.print("PROTOCOL_FETCH_FAIL: parse_error epoch={d} body_len={d}\n", .{ epoch, resp.len });
        return false;
    }

    // Detect fork: compare new major against last-known (current).
    const last_major = mempool_mod.g_fork_state.last_known_major;
    if (last_major != 0 and pmaj > last_major) {
        mempool_mod.g_fork_state.fork_pending = true;
        mempool_mod.g_fork_state.next_major = @intCast(pmaj);
        mempool_mod.g_fork_state.next_minor = @intCast(pmin);
        mempool_mod.g_fork_state.fork_detected_unix = compat.timestamp();
        std.debug.print("HARDFORK_DETECTED: from={d} to={d}.{d} max_block={d} epoch={d}\n", .{
            last_major, pmaj, pmin, mbsz, epoch,
        });
    }
    mempool_mod.g_fork_state.last_known_major = @intCast(pmaj);
    mempool_mod.g_fork_state.last_known_minor = @intCast(pmin);

    // Update global protocol params. Koios is source=2.
    mempool_mod.g_protocol_params = .{
        .min_fee_a = fee_a,
        .min_fee_b = fee_b,
        .min_utxo_value = min_utxo,
        .max_tx_size = mtxsz,
        .utxo_cost_per_byte = cost_per_byte,
        .source = 2,
        .reload_unix = compat.timestamp(),
        .protocol_major = @intCast(pmaj),
        .protocol_minor = @intCast(pmin),
        .max_block_body_size = mbsz,
    };

    std.debug.print("PROTOCOL_UPDATE: major={d} minor={d} max_block={d} max_tx={d} fee_a={d} fee_b={d} source=koios epoch={d}\n", .{
        pmaj, pmin, mbsz, mtxsz, fee_a, fee_b, epoch,
    });
    std.debug.print("PROTOCOL_SOURCE: source=koios\n", .{});
    return true;
}

const WatcherCfg = struct {
    alloc: std.mem.Allocator,
    net: []u8,
    epoch_fn: *const fn () u64,
};

fn watcherThread(cfg: *WatcherCfg) void {
    compat.sleep(INITIAL_WAIT_S * std.time.ns_per_s);
    while (true) {
        if (shutdown.stopRequested()) return;
        const epoch = cfg.epoch_fn();
        if (epoch > 0) _ = fetchOnce(cfg.alloc, cfg.net, epoch);
        compat.sleep(REFRESH_INTERVAL_S * std.time.ns_per_s);
    }
}

pub fn spawnBackground(
    alloc: std.mem.Allocator,
    net: []const u8,
    epoch_fn: *const fn () u64,
) bool {
    const net_copy = alloc.dupe(u8, net) catch return false;
    const cfg = alloc.create(WatcherCfg) catch {
        alloc.free(net_copy);
        return false;
    };
    cfg.* = .{ .alloc = alloc, .net = net_copy, .epoch_fn = epoch_fn };
    const thread = std.Thread.spawn(.{}, watcherThread, .{cfg}) catch {
        alloc.free(net_copy);
        alloc.destroy(cfg);
        return false;
    };
    thread.detach();
    std.debug.print("PROTOCOL_WATCHER_SPAWN: net={s} interval={d}s\n", .{ net, REFRESH_INTERVAL_S });
    return true;
}

// ── Pool params (pledge / fixed cost / margin) ──────────────────────

/// Parse a Koios pool_info response, extracting pledge / fixed_cost / margin.
/// Koios encodes pledge and fixed_cost as quoted-decimal strings (lovelace)
/// and margin as a JSON number in [0,1]. Returns null on parse failure.
fn parseKoiosPoolInfo(body: []const u8, pool_id: [28]u8) ?PoolParams {
    var out: PoolParams = .{ .pool_id = pool_id };
    out.pledge = parseU64Field(body, "\"pledge\":") orelse 0;
    out.cost_per_block = parseU64Field(body, "\"fixed_cost\":") orelse 0;
    // Margin: try "margin":0.034  (float) — convert to x1e9.
    if (std.mem.indexOf(u8, body, "\"margin\":")) |idx| {
        var i = idx + "\"margin\":".len;
        // Skip optional quote.
        if (i < body.len and body[i] == '"') i += 1;
        const start = i;
        while (i < body.len and ((body[i] >= '0' and body[i] <= '9') or body[i] == '.')) : (i += 1) {}
        if (i > start) {
            const f = std.fmt.parseFloat(f64, body[start..i]) catch 0.0;
            const clamped = @max(0.0, @min(1.0, f));
            out.margin_x1e9 = @intFromFloat(clamped * 1_000_000_000.0);
        }
    }
    if (out.pledge == 0 and out.cost_per_block == 0 and out.margin_x1e9 == 0) return null;
    return out;
}

fn fetchPoolParamsKoios(
    alloc: std.mem.Allocator,
    net: []const u8,
    pool_bech32: []const u8,
    pool_id: [28]u8,
) ?PoolParams {
    const base = koiosBase(net);
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/api/v1/pool_info", .{base}) catch return null;
    var body_buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{{\"_pool_bech32_ids\":[\"{s}\"]}}", .{pool_bech32}) catch return null;
    const argv = [_][]const u8{ "curl", "-sf", "-X", "POST", "-H", "Content-Type: application/json", "--data-binary", body, url };
    const resp = curlFetch(alloc, &argv) orelse {
        std.debug.print("POOL_PARAMS_FETCH_FAIL: koios curl_error pool={s}\n", .{pool_bech32});
        return null;
    };
    defer alloc.free(resp);
    const parsed = parseKoiosPoolInfo(resp, pool_id) orelse {
        std.debug.print("POOL_PARAMS_FETCH_FAIL: koios parse_error pool={s} body_len={d}\n", .{ pool_bech32, resp.len });
        return null;
    };
    std.debug.print("POOL_PARAMS_OK: source=koios pledge={d} cost={d} margin_x1e9={d}\n", .{
        parsed.pledge, parsed.cost_per_block, parsed.margin_x1e9,
    });
    return parsed;
}

/// Try the local cardano-node NtC socket first, then Koios. Returns null if
/// both paths fail. Caller treats null as "no fresh pool params this cycle"
/// and keeps any previously-cached values.
pub fn tryFetchPoolParams(
    alloc: std.mem.Allocator,
    net: []const u8,
    pool_bech32: []const u8,
    pool_id: [28]u8,
) ?PoolParams {
    if (ntc_client.enabledSocketPath()) |socket_path| {
        const magic: u64 = if (std.mem.eql(u8, net, "mainnet")) 764824073 else 2;
        if (ntc_client.tryFetchPoolParams(alloc, socket_path, magic, pool_id)) |pp| {
            std.debug.print("POOL_PARAMS_OK: source=ntc pledge={d} cost={d} margin_x1e9={d}\n", .{
                pp.pledge, pp.cost_per_block, pp.margin_x1e9,
            });
            return pp;
        }
    }
    return fetchPoolParamsKoios(alloc, net, pool_bech32, pool_id);
}

/// Render protocol section for /status. Returns bytes written.
pub fn renderJson(buf: []u8) usize {
    var w = compat.fixedBufferStream(buf);
    const out = w.writer();
    var src: []const u8 = "none";
    var major: u32 = 0;
    var minor: u32 = 0;
    var max_block: u64 = 0;
    if (mempool_mod.g_protocol_params) |pp| {
        src = switch (pp.source) {
            0 => "genesis",
            1 => "file",
            2 => "koios",
            3 => "ntc",
            else => "unknown",
        };
        major = pp.protocol_major;
        minor = pp.protocol_minor;
        max_block = pp.max_block_body_size;
    }
    out.print(
        \\{{"major":{d},"minor":{d},"max_block_size":{d},"source":"{s}","fork_pending":{s},"next_major":{d},"next_minor":{d}}}
    , .{
        major, minor, max_block, src,
        if (mempool_mod.g_fork_state.fork_pending) "true" else "false",
        mempool_mod.g_fork_state.next_major,
        mempool_mod.g_fork_state.next_minor,
    }) catch {};
    return w.pos;
}
