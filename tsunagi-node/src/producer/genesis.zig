const std = @import("std");
const compat = @import("compat");

// Error codes for genesis loading
pub const ERR_OK: u64 = 0;
pub const ERR_PATH_MISSING: u64 = 1;
pub const ERR_READ_ERROR: u64 = 2;
pub const ERR_SYSTEM_START_MISSING: u64 = 3;
pub const ERR_SYSTEM_START_PARSE_FAIL: u64 = 4;
pub const ERR_SLOT_LENGTH_MISSING: u64 = 5;
pub const ERR_SLOT_LENGTH_PARSE_FAIL: u64 = 6;
pub const ERR_NETWORK_MAGIC_MISMATCH: u64 = 7;

pub const MAINNET_MAGIC: u64 = 764_824_073;

pub const GenesisConfig = struct {
    genesis_unix: i64,
    slot_length_s: i64,
    network_magic: u64,
    parsed_ok: bool,
    path_ok: bool,
    last_error_code: u64,
    // Protocol parameters (from protocolParams in shelley-genesis.json)
    min_fee_a: u64 = 0, // fee per byte
    min_fee_b: u64 = 0, // fixed fee component
    min_utxo_value: u64 = 0, // minimum output lovelace
    max_tx_size: u64 = 0, // maximum tx size in bytes
    /// nOpt — the desired (saturation) number of pools. Used to compute
    /// per-pool saturation as `pool_stake / (total_supply / n_opt)`. Defaults
    /// to 500 (Cardano mainnet pre-Voltaire setting) when missing from the
    /// shelley genesis file.
    n_opt: u64 = 500,
};

const DEFAULTS = GenesisConfig{
    .genesis_unix = 0,
    .slot_length_s = 1,
    .network_magic = 0,
    .parsed_ok = false,
    .path_ok = false,
    .last_error_code = ERR_PATH_MISSING,
};

/// Resolve genesis file path from env or strict per-network auto-discovery.
/// Returns owned path (caller must free) or null.
pub fn resolveGenesisPath(alloc: std.mem.Allocator, genesis_dir_name: []const u8) ?[]u8 {
    // 1) Explicit env — always takes priority
    if (compat.getEnvVarOwned(alloc, "TSUNAGI_GENESIS_PATH") catch null) |p| {
        if (p.len > 0) return p;
        alloc.free(p);
    }

    // 2) Strict per-network: $TSUNAGI_HOME/genesis/<net>/shelley-genesis.json
    const home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
    defer if (home) |h| alloc.free(h);

    if (home) |h| {
        const try_path = std.fmt.allocPrint(alloc, "{s}/genesis/{s}/shelley-genesis.json", .{ h, genesis_dir_name }) catch return null;
        if (compat.fs.cwd().openFile(try_path, .{})) |f| {
            var fv = f;
            fv.close();
            return try_path;
        } else |_| {
            alloc.free(try_path);
        }
        std.debug.print("GENESIS: missing {s}/genesis/{s}/shelley-genesis.json (or set TSUNAGI_GENESIS_PATH)\n", .{ h, genesis_dir_name });
    }

    return null;
}

pub fn loadGenesis(alloc: std.mem.Allocator, path: []const u8) GenesisConfig {
    return loadGenesisInner(alloc, path, null);
}

pub fn loadGenesisForNet(alloc: std.mem.Allocator, path: []const u8, expected_magic: u64) GenesisConfig {
    return loadGenesisInner(alloc, path, expected_magic);
}

fn loadGenesisInner(alloc: std.mem.Allocator, path: []const u8, expected_magic: ?u64) GenesisConfig {
    var file = compat.fs.cwd().openFile(path, .{}) catch {
        std.debug.print("GENESIS: path={s} ok=0 err=2 (read_error: cannot open)\n", .{path});
        return GenesisConfig{
            .genesis_unix = 0,
            .slot_length_s = 1,
            .network_magic = 0,
            .parsed_ok = false,
            .path_ok = true,
            .last_error_code = ERR_READ_ERROR,
        };
    };
    defer file.close();

    const raw = file.readToEndAlloc(alloc, 2 * 1024 * 1024) catch {
        std.debug.print("GENESIS: path={s} ok=0 err=2 (read_error: too large or I/O)\n", .{path});
        return GenesisConfig{
            .genesis_unix = 0,
            .slot_length_s = 1,
            .network_magic = 0,
            .parsed_ok = false,
            .path_ok = true,
            .last_error_code = ERR_READ_ERROR,
        };
    };
    defer alloc.free(raw);

    // Extract systemStart
    const system_start_str = extractJsonString(raw, "\"systemStart\"") orelse {
        std.debug.print("GENESIS: path={s} ok=0 err=3 (systemStart_missing)\n", .{path});
        return GenesisConfig{
            .genesis_unix = 0,
            .slot_length_s = 1,
            .network_magic = extractJsonU64(raw, "\"networkMagic\""),
            .parsed_ok = false,
            .path_ok = true,
            .last_error_code = ERR_SYSTEM_START_MISSING,
        };
    };
    const genesis_unix = parseIso8601ZToUnix(system_start_str) orelse {
        std.debug.print("GENESIS: path={s} ok=0 err=4 (systemStart_parse_fail: {s})\n", .{ path, system_start_str });
        return GenesisConfig{
            .genesis_unix = 0,
            .slot_length_s = 1,
            .network_magic = extractJsonU64(raw, "\"networkMagic\""),
            .parsed_ok = false,
            .path_ok = true,
            .last_error_code = ERR_SYSTEM_START_PARSE_FAIL,
        };
    };

    // Extract slotLength (int or float-like)
    const slot_length = blk: {
        if (extractJsonInt(raw, "\"slotLength\"")) |v| {
            break :blk @max(1, @min(60, v));
        }
        // Try float-like (e.g. "1.0")
        if (extractJsonFloat(raw, "\"slotLength\"")) |fv| {
            const iv: i64 = @intFromFloat(@max(1.0, @min(60.0, fv)));
            break :blk iv;
        }
        std.debug.print("GENESIS: path={s} ok=0 err=5 (slotLength_missing)\n", .{path});
        return GenesisConfig{
            .genesis_unix = genesis_unix,
            .slot_length_s = 1,
            .network_magic = extractJsonU64(raw, "\"networkMagic\""),
            .parsed_ok = false,
            .path_ok = true,
            .last_error_code = ERR_SLOT_LENGTH_MISSING,
        };
    };

    // Optional: networkMagic
    const network_magic = extractJsonU64(raw, "\"networkMagic\"");

    // Validate network magic if expected value provided
    if (expected_magic) |em| {
        if (network_magic != 0 and network_magic != em) {
            std.debug.print("GENESIS: path={s} ok=0 err=7 (network_magic_mismatch: got={d} expected={d})\n", .{ path, network_magic, em });
            return GenesisConfig{
                .genesis_unix = genesis_unix,
                .slot_length_s = slot_length,
                .network_magic = network_magic,
                .parsed_ok = false,
                .path_ok = true,
                .last_error_code = ERR_NETWORK_MAGIC_MISMATCH,
            };
        }
    }

    // Extract protocol parameters (scoped to protocolParams object)
    var min_fee_a: u64 = 0;
    var min_fee_b: u64 = 0;
    var min_utxo_value: u64 = 0;
    var max_tx_size: u64 = 0;
    var n_opt: u64 = 500;
    if (std.mem.indexOf(u8, raw, "\"protocolParams\"")) |pp_pos| {
        const pp_sub = raw[pp_pos..];
        min_fee_a = extractJsonU64(pp_sub, "\"minFeeA\"");
        min_fee_b = extractJsonU64(pp_sub, "\"minFeeB\"");
        min_utxo_value = extractJsonU64(pp_sub, "\"minUTxOValue\"");
        max_tx_size = extractJsonU64(pp_sub, "\"maxTxSize\"");
        const parsed_n_opt = extractJsonU64(pp_sub, "\"nOpt\"");
        if (parsed_n_opt > 0) n_opt = parsed_n_opt;
    }

    std.debug.print("GENESIS: path={s} ok=1 start_unix={d} slot_len={d}s magic={d} minFeeA={d} minFeeB={d} minUTxO={d} maxTx={d} nOpt={d} err=0\n", .{
        path, genesis_unix, slot_length, network_magic, min_fee_a, min_fee_b, min_utxo_value, max_tx_size, n_opt,
    });

    return GenesisConfig{
        .genesis_unix = genesis_unix,
        .slot_length_s = slot_length,
        .network_magic = network_magic,
        .parsed_ok = true,
        .path_ok = true,
        .last_error_code = ERR_OK,
        .min_fee_a = min_fee_a,
        .min_fee_b = min_fee_b,
        .min_utxo_value = min_utxo_value,
        .max_tx_size = max_tx_size,
        .n_opt = n_opt,
    };
}

// ── Protocol params file loader ────────────────────────────────────

const mempool_mod = @import("../net/ledger/mempool.zig");

/// Load protocol parameters from $TSUNAGI_HOME/protocol-params.json.
/// Uses cardano-cli field names: txFeePerByte, txFeeFixed, utxoCostPerByte, maxTxSize.
/// Returns null if file missing or unparseable. Caller should fall back to genesis values.
pub fn loadProtocolParamsFile(alloc: std.mem.Allocator, home_path: []const u8) ?mempool_mod.ProtocolParams {
    const path = std.fmt.allocPrint(alloc, "{s}/protocol-params.json", .{home_path}) catch return null;
    defer alloc.free(path);

    var f = compat.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    const raw = f.readToEndAlloc(alloc, 64 * 1024) catch return null;
    defer alloc.free(raw);

    const fee_a = extractJsonU64(raw, "\"txFeePerByte\"");
    const fee_b = extractJsonU64(raw, "\"txFeeFixed\"");
    const cost_per_byte = extractJsonU64(raw, "\"utxoCostPerByte\"");
    const max_tx = extractJsonU64(raw, "\"maxTxSize\"");

    // Also check legacy field names from shelley-genesis format
    const fee_a_final = if (fee_a > 0) fee_a else extractJsonU64(raw, "\"minFeeA\"");
    const fee_b_final = if (fee_b > 0) fee_b else extractJsonU64(raw, "\"minFeeB\"");
    const min_utxo = extractJsonU64(raw, "\"minUTxOValue\"");
    const max_tx_final = if (max_tx > 0) max_tx else extractJsonU64(raw, "\"maxTxSize\"");

    if (fee_a_final == 0 and fee_b_final == 0 and max_tx_final == 0) return null;

    const now: i64 = compat.timestamp();
    std.debug.print("PROTOCOL_PARAMS_FILE: path={s} fee_a={d} fee_b={d} cost_per_byte={d} max_tx={d} min_utxo={d}\n", .{
        path, fee_a_final, fee_b_final, cost_per_byte, max_tx_final, min_utxo,
    });

    return .{
        .min_fee_a = fee_a_final,
        .min_fee_b = fee_b_final,
        .min_utxo_value = if (min_utxo > 0) min_utxo else 1_000_000, // default 1 ADA
        .max_tx_size = max_tx_final,
        .utxo_cost_per_byte = cost_per_byte,
        .source = 1, // file
        .reload_unix = now,
    };
}

// ── JSON helpers (substring-based, no std.json) ─────────────────────

fn extractJsonString(raw: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, raw, key) orelse return null;
    var i = key_pos + key.len;
    // Skip : and whitespace
    while (i < raw.len and (raw[i] == ':' or raw[i] == ' ' or raw[i] == '\t' or raw[i] == '\n' or raw[i] == '\r')) : (i += 1) {}
    if (i >= raw.len or raw[i] != '"') return null;
    i += 1;
    const val_start = i;
    const val_end = std.mem.indexOfPos(u8, raw, val_start, "\"") orelse return null;
    return raw[val_start..val_end];
}

fn extractJsonInt(raw: []const u8, key: []const u8) ?i64 {
    const key_pos = std.mem.indexOf(u8, raw, key) orelse return null;
    var i = key_pos + key.len;
    while (i < raw.len and (raw[i] == ':' or raw[i] == ' ' or raw[i] == '\t' or raw[i] == '\n' or raw[i] == '\r')) : (i += 1) {}
    if (i >= raw.len) return null;
    const num_start = i;
    while (i < raw.len and ((raw[i] >= '0' and raw[i] <= '9') or raw[i] == '-')) : (i += 1) {}
    if (i == num_start) return null;
    return std.fmt.parseInt(i64, raw[num_start..i], 10) catch null;
}

fn extractJsonFloat(raw: []const u8, key: []const u8) ?f64 {
    const key_pos = std.mem.indexOf(u8, raw, key) orelse return null;
    var i = key_pos + key.len;
    while (i < raw.len and (raw[i] == ':' or raw[i] == ' ' or raw[i] == '\t' or raw[i] == '\n' or raw[i] == '\r')) : (i += 1) {}
    if (i >= raw.len) return null;
    const start = i;
    while (i < raw.len and ((raw[i] >= '0' and raw[i] <= '9') or raw[i] == '.' or raw[i] == '-')) : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseFloat(f64, raw[start..i]) catch null;
}

fn extractJsonU64(raw: []const u8, key: []const u8) u64 {
    const v = extractJsonInt(raw, key) orelse return 0;
    return if (v >= 0) @intCast(v) else 0;
}

// ── Minimal ISO8601 parser (UTC "Z" only, years >= 2000) ────────────

fn parseIso8601ZToUnix(s: []const u8) ?i64 {
    // Expect: YYYY-MM-DDTHH:MM:SSZ or YYYY-MM-DDTHH:MM:SS.sssZ
    if (s.len < 20) return null; // "2000-01-01T00:00:00Z" = 20 chars

    const year = std.fmt.parseUnsigned(u16, s[0..4], 10) catch return null;
    if (s[4] != '-') return null;
    const month = std.fmt.parseUnsigned(u8, s[5..7], 10) catch return null;
    if (s[7] != '-') return null;
    const day = std.fmt.parseUnsigned(u8, s[8..10], 10) catch return null;
    if (s[10] != 'T') return null;
    const hour = std.fmt.parseUnsigned(u8, s[11..13], 10) catch return null;
    if (s[13] != ':') return null;
    const minute = std.fmt.parseUnsigned(u8, s[14..16], 10) catch return null;
    if (s[16] != ':') return null;
    const second = std.fmt.parseUnsigned(u8, s[17..19], 10) catch return null;
    // Must end with Z (possibly after fractional seconds)
    const has_z = (s[19] == 'Z') or (s.len > 20 and s[s.len - 1] == 'Z');
    if (!has_z) return null;

    // Validate ranges
    if (year < 2000 or year > 2100) return null;
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > 31) return null;
    if (hour > 23) return null;
    if (minute > 59) return null;
    if (second > 60) return null; // allow leap second

    // Days from epoch (1970-01-01) to start of year
    var days: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) {
        days += if (isLeapYear(y)) @as(i64, 366) else @as(i64, 365);
    }

    // Days for months in target year
    const month_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        days += month_days[m - 1];
        if (m == 2 and isLeapYear(year)) days += 1;
    }

    days += @as(i64, day) - 1;

    return days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
}

fn isLeapYear(y: u16) bool {
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
}
