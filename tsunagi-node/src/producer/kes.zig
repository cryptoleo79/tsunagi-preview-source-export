const std = @import("std");
const compat = @import("compat");

// Reason codes (v0.8.92)
// 0 = ok
// 1 = disabled
// 2 = missing_key_path
// 3 = missing_key_file
// 4 = bad_perms
// 5 = unreadable
// 6 = test_stub

pub const KesConfig = struct {
    enabled: bool,
    parse_ok: bool,
    key_path: ?[]const u8,
    reason_code_last: u8,
};

pub const KesResult = struct {
    attempted: bool,
    signed: bool,
    sig_present: bool,
    reason_code: u8,
};

pub fn loadConfig(alloc: std.mem.Allocator) KesConfig {
    const env_enable = compat.getEnvVarOwned(alloc, "TSUNAGI_KES_ENABLE") catch null;
    const enabled = if (env_enable) |v| blk: {
        defer alloc.free(v);
        break :blk std.mem.eql(u8, v, "1");
    } else false;

    if (!enabled) {
        std.debug.print("KES: enabled=0 ok=1 reason=1 path=n/a\n", .{});
        return KesConfig{
            .enabled = false,
            .parse_ok = true,
            .key_path = null,
            .reason_code_last = 1,
        };
    }

    const key_path = compat.getEnvVarOwned(alloc, "TSUNAGI_KES_SKEY_PATH") catch null;

    if (key_path == null or key_path.?.len == 0) {
        std.debug.print("KES: enabled=1 ok=0 reason=2 path=n/a\n", .{});
        return KesConfig{
            .enabled = true,
            .parse_ok = false,
            .key_path = null,
            .reason_code_last = 2,
        };
    }

    const path = key_path.?;

    // Check file exists
    const file_exists = blk: {
        var f = compat.fs.cwd().openFile(path, .{}) catch break :blk false;
        f.close();
        break :blk true;
    };
    if (!file_exists) {
        std.debug.print("KES: enabled=1 ok=0 reason=3 path={s}\n", .{path});
        return KesConfig{
            .enabled = true,
            .parse_ok = false,
            .key_path = key_path,
            .reason_code_last = 3,
        };
    }

    // Check permissions (0600)
    const perms_ok = blk: {
        const stat = compat.fs.cwd().statFile(path) catch break :blk false;
        break :blk (stat.permissions.toMode() & 0o077) == 0;
    };
    if (!perms_ok) {
        std.debug.print("KES: enabled=1 ok=0 reason=4 path={s}\n", .{path});
        return KesConfig{
            .enabled = true,
            .parse_ok = false,
            .key_path = key_path,
            .reason_code_last = 4,
        };
    }

    // Check readable
    const readable = blk: {
        var f = compat.fs.cwd().openFile(path, .{ .mode = .read_only }) catch break :blk false;
        defer f.close();
        var buf: [1]u8 = undefined;
        _ = f.read(&buf) catch break :blk false;
        break :blk true;
    };
    if (!readable) {
        std.debug.print("KES: enabled=1 ok=0 reason=5 path={s}\n", .{path});
        return KesConfig{
            .enabled = true,
            .parse_ok = false,
            .key_path = key_path,
            .reason_code_last = 5,
        };
    }

    std.debug.print("KES: enabled=1 ok=1 reason=0 path={s}\n", .{path});
    return KesConfig{
        .enabled = true,
        .parse_ok = true,
        .key_path = key_path,
        .reason_code_last = 0,
    };
}

pub fn signStub(cfg: *const KesConfig, msg: []const u8) KesResult {
    _ = msg;

    if (!cfg.enabled) {
        return KesResult{ .attempted = false, .signed = false, .sig_present = false, .reason_code = 1 };
    }

    if (!cfg.parse_ok) {
        return KesResult{ .attempted = true, .signed = false, .sig_present = false, .reason_code = cfg.reason_code_last };
    }

    // Enabled + parse_ok — stub (no real KES signing)
    return KesResult{ .attempted = true, .signed = false, .sig_present = false, .reason_code = 6 };
}
