const std = @import("std");
const compat = @import("compat");

pub const CAPTURE_MAX_TOTAL_BYTES_DEFAULT: u64 = 10 * 1024 * 1024 * 1024; // 10GB

const DEFAULT_ROTATE_BYTES: u64 = 256 * 1024 * 1024; // 256MB
const MIN_ROTATE_MB: u64 = 1;
const MAX_ROTATE_MB: u64 = 4096;

var g_rotate_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_rotate_logged: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_override_last_check_unix: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);
const OVERRIDE_MIN_MB: u64 = 16;
const OVERRIDE_MAX_MB: u64 = 256;

// --- Network prefix for capture filenames ---
// Default "mainnet" for backward compatibility; set via setNetPrefix() at startup.
var g_net_prefix: []const u8 = "mainnet";

/// Set the network prefix used for capture filenames (e.g. "preview", "sancho").
/// Must be called once at startup before any capture I/O.
pub fn setNetPrefix(name: []const u8) void {
    g_net_prefix = name;
}

/// Return the active network prefix (e.g. "mainnet", "preview").
pub fn netPrefix() []const u8 {
    return g_net_prefix;
}

fn getRotationBytes() u64 {
    const cached = g_rotate_bytes.load(.acquire);
    if (cached > 0) return cached;

    const v = compat.getEnvVarOwned(std.heap.page_allocator, "TSUNAGI_CAPTURE_ROTATE_MB") catch {
        g_rotate_bytes.store(DEFAULT_ROTATE_BYTES, .release);
        return DEFAULT_ROTATE_BYTES;
    };
    defer std.heap.page_allocator.free(v);

    const mb = std.fmt.parseUnsigned(u64, std.mem.trim(u8, v, " \t\r\n"), 10) catch {
        std.debug.print("CAPTURE: invalid TSUNAGI_CAPTURE_ROTATE_MB=\"{s}\", using default 256MB\n", .{v});
        g_rotate_bytes.store(DEFAULT_ROTATE_BYTES, .release);
        return DEFAULT_ROTATE_BYTES;
    };
    const clamped_min: u64 = @min(mb, MAX_ROTATE_MB);
    const clamped: u64 = @max(MIN_ROTATE_MB, clamped_min);
    const result: u64 = clamped * 1024 * 1024;
    g_rotate_bytes.store(result, .release);

    if (g_rotate_logged.load(.acquire) == 0) {
        g_rotate_logged.store(1, .release);
        std.debug.print("CAPTURE: rotate_bytes={d} (env={d}MB)\n", .{ result, clamped });
    }
    return result;
}

/// Return the active rotation threshold in bytes (reads env once, then cached).
pub fn rotateBytes() u64 {
    return getRotationBytes();
}

/// Re-read $TSUNAGI_HOME/capture.rotate_mb override file (every 60s).
/// If file exists with valid number, overrides rotation threshold (clamped 16..256 MB).
/// If file absent, reverts to env-driven or default value.
pub fn reloadRotateOverride(state_dir: []const u8) void {
    const now = compat.timestamp();
    const last = g_override_last_check_unix.load(.acquire);
    if (now - last < 60) return;
    g_override_last_check_unix.store(now, .release);

    const override_path = std.fs.path.join(std.heap.page_allocator, &[_][]const u8{ state_dir, "capture.rotate_mb" }) catch return;
    defer std.heap.page_allocator.free(override_path);

    var file = compat.fs.cwd().openFile(override_path, .{}) catch {
        // File absent — no override active; leave current setting
        return;
    };
    defer file.close();
    var buf: [32]u8 = undefined;
    const n = file.deprecatedReader().read(&buf) catch return;
    if (n == 0) return;
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    const mb = std.fmt.parseUnsigned(u64, trimmed, 10) catch return;
    const clamped: u64 = @max(OVERRIDE_MIN_MB, @min(mb, OVERRIDE_MAX_MB));
    const result: u64 = clamped * 1024 * 1024;
    const prev = g_rotate_bytes.load(.acquire);
    if (prev != result) {
        g_rotate_bytes.store(result, .release);
        std.debug.print("CAPTURE: rotate override={d}MB (file={s})\n", .{ clamped, override_path });
    }
}

pub fn enabled() bool {
    const v = compat.getEnvVarOwned(std.heap.page_allocator, "TSUNAGI_CAPTURE") catch return false;
    defer std.heap.page_allocator.free(v);
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

/// Return the active capture filename for the current network (e.g. "preview.bin").
pub fn activeFileName() []const u8 {
    return g_active_name_buf[0..g_active_name_len];
}

var g_active_name_buf: [64]u8 = undefined;
var g_active_name_len: usize = 0;

fn ensureActiveNameCached() []const u8 {
    if (g_active_name_len > 0) return g_active_name_buf[0..g_active_name_len];
    const result = std.fmt.bufPrint(&g_active_name_buf, "{s}.bin", .{g_net_prefix}) catch "mainnet.bin";
    g_active_name_len = result.len;
    return result;
}

/// Append one record to ${TSUNAGI_HOME}/captures/<net>.bin
/// Format: [u32 little-endian length][payload bytes]
/// Rotation: if file > 256MB, rename to <net>.<unix>.bin and start new.
/// Retention: after rotation, enforce max total size across all segments.
pub fn appendRecord(
    alloc: std.mem.Allocator,
    state_dir: []const u8,
    payload: []const u8,
) !void {
    const caps_dir = try std.fs.path.join(alloc, &[_][]const u8{ state_dir, "captures" });
    defer alloc.free(caps_dir);

    try compat.fs.cwd().makePath(caps_dir);

    const active_name = ensureActiveNameCached();
    const path = try std.fs.path.join(alloc, &[_][]const u8{ caps_dir, active_name });
    defer alloc.free(path);

    // Check for runtime override from fastsync controller
    reloadRotateOverride(state_dir);

    const max_bytes: u64 = getRotationBytes();

    // Check file size for rotation
    if (compat.fs.cwd().openFile(path, .{})) |stat_file| {
        var sf = stat_file;
        const st = sf.stat() catch {
            sf.close();
            return;
        };
        sf.close();
        if (st.size > max_bytes) {
            var rbuf: [128]u8 = undefined;
            const ts = compat.timestamp();
            const rotated_name = std.fmt.bufPrint(&rbuf, "{s}.{d}.bin", .{ g_net_prefix, ts }) catch return;
            const rotated_path = std.fs.path.join(alloc, &[_][]const u8{ caps_dir, rotated_name }) catch return;
            defer alloc.free(rotated_path);
            if (compat.fs.cwd().rename(path, rotated_path)) {
                std.debug.print("CAPTURE: rotated -> {s}\n", .{rotated_name});
                enforceRetention(alloc, caps_dir, CAPTURE_MAX_TOTAL_BYTES_DEFAULT);
            } else |_| {}
        }
    } else |_| {
        // File doesn't exist yet, that's fine
    }

    var f = try compat.fs.cwd().createFile(path, .{ .truncate = false });
    defer f.close();

    const end_pos = (try f.stat()).size;
    try f.seekTo(end_pos);

    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(payload.len), .little);
    try f.writeAll(&len_buf);
    try f.writeAll(payload);
}

/// Check if a filename is a rotated capture segment for the current network.
pub fn isRotatedCapture(name: []const u8) bool {
    const prefix = g_net_prefix;
    // Must start with "<net>."
    if (name.len <= prefix.len + 1) return false;
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    if (name[prefix.len] != '.') return false;
    if (!std.mem.endsWith(u8, name, ".bin")) return false;
    // Exclude active file (<net>.bin)
    if (name.len == prefix.len + 4 and std.mem.endsWith(u8, name, ".bin")) return false;
    return true;
}

/// Check if a filename matches the capture pattern for the current network.
pub fn isCaptureFile(name: []const u8) bool {
    const prefix = g_net_prefix;
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    if (name.len <= prefix.len) return false;
    if (name[prefix.len] != '.') return false;
    if (!std.mem.endsWith(u8, name, ".bin")) return false;
    return true;
}

fn enforceRetention(alloc: std.mem.Allocator, caps_dir: []const u8, max_total: u64) void {
    var dir = compat.fs.cwd().openDir(caps_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    const active_name = ensureActiveNameCached();

    // Collect rotated file names
    var names = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (names.items) |s| alloc.free(s);
        names.deinit();
    }

    var it = dir.iterate();
    while (it.next() catch null) |e| {
        if (e.kind != .file) continue;
        if (!isRotatedCapture(e.name)) continue;
        names.append(alloc.dupe(u8, e.name) catch continue) catch continue;
    }

    // Sort ascending (oldest timestamp first)
    std.sort.insertion([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // Compute total size (active + all rotated)
    var total: u64 = 0;
    if (dir.statFile(active_name)) |st| {
        total += st.size;
    } else |_| {}
    for (names.items) |n| {
        if (dir.statFile(n)) |st| {
            total += st.size;
        } else |_| {}
    }

    // Delete oldest rotated files until within limit
    var idx: usize = 0;
    while (total > max_total and idx < names.items.len) {
        const name = names.items[idx];
        const file_size: u64 = if (dir.statFile(name)) |st| st.size else |_| 0;
        dir.deleteFile(name) catch {
            idx += 1;
            continue;
        };
        std.debug.print("CAPTURE: retention total={d} limit={d} deleted={s}\n", .{ total, max_total, name });
        total -|= file_size;
        idx += 1;
    }
}

/// Public entry point for manual / CLI retention enforcement.
pub fn enforceRetentionPublic(alloc: std.mem.Allocator, caps_dir: []const u8, max_total: u64) void {
    // Report current state before enforcement
    var dir = compat.fs.cwd().openDir(caps_dir, .{ .iterate = true }) catch {
        std.debug.print("CAPTURE: cannot open dir {s}\n", .{caps_dir});
        return;
    };

    var total: u64 = 0;
    var file_count: usize = 0;
    var dir_it = dir.iterate();
    while (dir_it.next() catch null) |e| {
        if (e.kind != .file) continue;
        if (!isCaptureFile(e.name)) continue;
        if (dir.statFile(e.name)) |st| {
            total += st.size;
            file_count += 1;
        } else |_| {}
    }
    dir.close();

    std.debug.print("CAPTURE: pre-retention files={d} total={d} limit={d}\n", .{ file_count, total, max_total });

    enforceRetention(alloc, caps_dir, max_total);

    // Re-scan after
    var dir2 = compat.fs.cwd().openDir(caps_dir, .{ .iterate = true }) catch return;
    var total2: u64 = 0;
    var count2: usize = 0;
    var dir_it2 = dir2.iterate();
    while (dir_it2.next() catch null) |e| {
        if (e.kind != .file) continue;
        if (!isCaptureFile(e.name)) continue;
        if (dir2.statFile(e.name)) |st| {
            total2 += st.size;
            count2 += 1;
        } else |_| {}
    }
    dir2.close();

    std.debug.print("CAPTURE: post-retention files={d} total={d}\n", .{ count2, total2 });
}
