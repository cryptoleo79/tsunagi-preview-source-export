const std = @import("std");
const compat = @import("compat");

// Error codes (v0.8.90)
pub const ERR_OK: u32 = 0;
pub const ERR_DISABLED: u32 = 1;
pub const ERR_MISSING_POOL_ID: u32 = 2;
pub const ERR_BAD_POOL_ID_HEX: u32 = 3;
pub const ERR_MISSING_KES_KEY: u32 = 4;
pub const ERR_MISSING_VRF_KEY: u32 = 5;
pub const ERR_PERMS_NOT_0600: u32 = 6;
pub const ERR_NOT_READABLE: u32 = 7;
pub const ERR_STAT_FAILED: u32 = 8;

pub const KeyCfg = struct {
    enabled: bool,
    parse_ok: bool,
    kes_skey_path: ?[]const u8,
    vrf_skey_path: ?[]const u8,
    pool_id_hex: ?[]const u8,
    last_error_code: u32,
};

pub const ValidateResult = struct {
    pool_ok: bool,
    kes_ok: bool,
    vrf_ok: bool,
    perms_ok: bool,
    readable_ok: bool,
    err_code: u32,
};

pub fn loadConfig(alloc: std.mem.Allocator) KeyCfg {
    // Check enable flag
    const env_enable = compat.getEnvVarOwned(alloc, "TSUNAGI_PRODUCER_ENABLE") catch null;
    const enabled = if (env_enable) |v| blk: {
        defer alloc.free(v);
        break :blk std.mem.eql(u8, v, "1");
    } else false;

    if (!enabled) {
        return KeyCfg{
            .enabled = false,
            .parse_ok = true,
            .kes_skey_path = null,
            .vrf_skey_path = null,
            .pool_id_hex = null,
            .last_error_code = ERR_DISABLED,
        };
    }

    // Read paths
    const kes_path = compat.getEnvVarOwned(alloc, "TSUNAGI_KES_SKEY_PATH") catch null;
    const vrf_path = compat.getEnvVarOwned(alloc, "TSUNAGI_VRF_SKEY_PATH") catch null;
    const pool_id = compat.getEnvVarOwned(alloc, "TSUNAGI_POOL_ID_HEX") catch null;

    return KeyCfg{
        .enabled = true,
        .parse_ok = true,
        .kes_skey_path = kes_path,
        .vrf_skey_path = vrf_path,
        .pool_id_hex = pool_id,
        .last_error_code = ERR_OK,
    };
}

pub fn validate(cfg: KeyCfg) ValidateResult {
    const disabled_result = ValidateResult{
        .pool_ok = false, .kes_ok = false, .vrf_ok = false,
        .perms_ok = false, .readable_ok = false, .err_code = ERR_DISABLED,
    };
    if (!cfg.enabled) {
        logKeys(cfg.enabled, disabled_result);
        return disabled_result;
    }

    // 1) Pool ID validation
    const pool_ok = blk: {
        const pid = cfg.pool_id_hex orelse break :blk false;
        if (pid.len == 0) break :blk false;
        // Must be even-length hex
        if (pid.len % 2 != 0) break :blk false;
        const byte_len = pid.len / 2;
        // Accept 28-byte (56 hex) or 32-byte (64 hex) pool IDs
        if (byte_len != 28 and byte_len != 32) break :blk false;
        // Verify hex decodes
        var buf: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&buf, pid) catch break :blk false;
        break :blk true;
    };

    if (cfg.pool_id_hex == null or cfg.pool_id_hex.?.len == 0) {
        const r = ValidateResult{
            .pool_ok = false, .kes_ok = false, .vrf_ok = false,
            .perms_ok = false, .readable_ok = false, .err_code = ERR_MISSING_POOL_ID,
        };
        logKeys(cfg.enabled, r);
        return r;
    }
    if (!pool_ok) {
        const r = ValidateResult{
            .pool_ok = false, .kes_ok = false, .vrf_ok = false,
            .perms_ok = false, .readable_ok = false, .err_code = ERR_BAD_POOL_ID_HEX,
        };
        logKeys(cfg.enabled, r);
        return r;
    }

    // 2) KES key file
    const kes_exists = if (cfg.kes_skey_path) |p| (if (p.len > 0) fileExists(p) else false) else false;
    if (!kes_exists) {
        const r = ValidateResult{
            .pool_ok = true, .kes_ok = false, .vrf_ok = false,
            .perms_ok = false, .readable_ok = false, .err_code = ERR_MISSING_KES_KEY,
        };
        logKeys(cfg.enabled, r);
        return r;
    }

    // 3) VRF key file
    const vrf_exists = if (cfg.vrf_skey_path) |p| (if (p.len > 0) fileExists(p) else false) else false;
    if (!vrf_exists) {
        const r = ValidateResult{
            .pool_ok = true, .kes_ok = true, .vrf_ok = false,
            .perms_ok = false, .readable_ok = false, .err_code = ERR_MISSING_VRF_KEY,
        };
        logKeys(cfg.enabled, r);
        return r;
    }

    // 4) Permissions (0600 — no group/other access)
    const kes_perms = checkPerms0600(cfg.kes_skey_path.?);
    const vrf_perms = checkPerms0600(cfg.vrf_skey_path.?);
    if (kes_perms == null or vrf_perms == null) {
        const r = ValidateResult{
            .pool_ok = true, .kes_ok = true, .vrf_ok = true,
            .perms_ok = false, .readable_ok = false, .err_code = ERR_STAT_FAILED,
        };
        logKeys(cfg.enabled, r);
        return r;
    }
    if (!kes_perms.? or !vrf_perms.?) {
        const r = ValidateResult{
            .pool_ok = true, .kes_ok = true, .vrf_ok = true,
            .perms_ok = false, .readable_ok = false, .err_code = ERR_PERMS_NOT_0600,
        };
        logKeys(cfg.enabled, r);
        return r;
    }

    // 5) Readable
    const kes_read = checkReadable(cfg.kes_skey_path.?);
    const vrf_read = checkReadable(cfg.vrf_skey_path.?);
    if (!kes_read or !vrf_read) {
        const r = ValidateResult{
            .pool_ok = true, .kes_ok = true, .vrf_ok = true,
            .perms_ok = true, .readable_ok = false, .err_code = ERR_NOT_READABLE,
        };
        logKeys(cfg.enabled, r);
        return r;
    }

    const r = ValidateResult{
        .pool_ok = true, .kes_ok = true, .vrf_ok = true,
        .perms_ok = true, .readable_ok = true, .err_code = ERR_OK,
    };
    logKeys(cfg.enabled, r);
    return r;
}

fn logKeys(enabled: bool, r: ValidateResult) void {
    const ok: u8 = if (r.err_code == ERR_OK) 1 else 0;
    const en: u8 = if (enabled) 1 else 0;
    std.debug.print("KEYS: enabled={d} ok={d} err={d} pool_ok={d} kes_ok={d} vrf_ok={d} perms_ok={d} read_ok={d}\n", .{
        en,
        ok,
        r.err_code,
        @as(u8, if (r.pool_ok) 1 else 0),
        @as(u8, if (r.kes_ok) 1 else 0),
        @as(u8, if (r.vrf_ok) 1 else 0),
        @as(u8, if (r.perms_ok) 1 else 0),
        @as(u8, if (r.readable_ok) 1 else 0),
    });
}

fn fileExists(path: []const u8) bool {
    var f = compat.fs.cwd().openFile(path, .{}) catch return false;
    f.close();
    return true;
}

fn checkReadable(path: []const u8) bool {
    var f = compat.fs.cwd().openFile(path, .{ .mode = .read_only }) catch return false;
    defer f.close();
    var buf: [1]u8 = undefined;
    _ = f.read(&buf) catch return false;
    return true;
}

/// Returns null if stat fails, true if perms are 0600, false otherwise.
fn checkPerms0600(path: []const u8) ?bool {
    const stat = compat.fs.cwd().statFile(path) catch return null;
    return (stat.permissions.toMode() & 0o077) == 0;
}
