// Operator-grade autonomy primitives — PR-A.
//
// Self-contained runtime hardening that does NOT touch consensus, forge,
// or ChainSync logic:
//
//   - acquireLock:    flock(${TSUNAGI_HOME}/lock) — refuse second instance.
//   - installLogTee:  tee stdout/stderr to ${TSUNAGI_HOME}/logs/node.log
//                     with 5MB × 5-file rotation.
//   - markActive / markClean: shutdown marker for downstream recovery.
//
// Follower's own SIGINT/SIGTERM handlers (follower.zig:700) already drain
// ChainSync cleanly and return through main(). PR-A relies on that path:
// markClean is invoked via `defer` once chainsync returns, so an operator
// `kill -TERM` produces an ordered teardown without runtime changes.

const std = @import("std");
const compat = @import("compat");

extern "c" fn flock(fd: c_int, op: c_int) c_int;
extern "c" fn dup(oldfd: c_int) c_int;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;
extern "c" fn pipe(fds: *[2]c_int) c_int;

const LOCK_EX: c_int = 2;
const LOCK_NB: c_int = 4;

const LOG_ROTATE_BYTES: u64 = 5 * 1024 * 1024;
const LOG_KEEP: u8 = 5;

// Held for process lifetime.
var g_lock_fd: c_int = -1;

// Logging globals — set once by installLogTee, read by writer thread.
var g_orig_stderr_fd: c_int = -1;
var g_log_fd: c_int = -1;
var g_pipe_read: c_int = -1;
var g_log_path_buf: [512]u8 = undefined;
var g_log_path_len: usize = 0;

pub const Error = error{
    LockOpenFailed,
    AlreadyRunning,
    LogOpenFailed,
    DupFailed,
    PipeFailed,
    Dup2Failed,
    HomeTooLong,
};

/// flock ${home}/lock with LOCK_EX|LOCK_NB. If another tsunagi-node already
/// holds it, prints a clear message and returns AlreadyRunning. Lock fd is
/// retained for the lifetime of the process; kernel releases on exit.
pub fn acquireLock(home: []const u8) Error!void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/lock", .{home}) catch return Error.LockOpenFailed;

    compat.fs.cwd().makePath(home) catch {};

    const O = std.c.O;
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true }, @as(std.c.mode_t, 0o644));
    _ = O;
    if (fd < 0) {
        std.debug.print("LOCK_OPEN_FAIL: path={s}\n", .{path});
        return Error.LockOpenFailed;
    }

    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        std.debug.print("ANOTHER_INSTANCE_HOLDS_LOCK: path={s} — refusing to start\n", .{path});
        return Error.AlreadyRunning;
    }
    g_lock_fd = fd;
    std.debug.print("LOCK_ACQUIRED: path={s}\n", .{path});
}

/// Remove ${home}/clean if present. Call once active state begins.
pub fn markActive(home: []const u8) void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/clean", .{home}) catch return;
    compat.fs.cwd().deleteFile(path) catch {};
}

/// Write ${home}/clean with a unix timestamp. Call from defer on graceful exit.
/// Absence on next boot signals to PR-F that integrity verification is needed.
pub fn markClean(home: []const u8) void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/clean", .{home}) catch return;
    var f = compat.fs.cwd().createFile(path, .{}) catch return;
    defer f.close();
    var line_buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "clean unix={d}\n", .{compat.timestamp()}) catch return;
    _ = f.writeAll(line) catch {};
    std.debug.print("CLEAN_MARKER_WRITTEN: path={s}\n", .{path});
}

fn rotateIfNeeded(log_path: []const u8) void {
    const stat = compat.fs.cwd().statFile(log_path) catch return;
    if (stat.size < LOG_ROTATE_BYTES) return;

    // .{N-1} → .N, .{N-2} → .{N-1} … .1 → .2; then base → .1.
    var i: u8 = LOG_KEEP;
    while (i > 1) : (i -= 1) {
        var sb: [512]u8 = undefined;
        var db: [512]u8 = undefined;
        const src = std.fmt.bufPrint(&sb, "{s}.{d}", .{ log_path, i - 1 }) catch continue;
        const dst = std.fmt.bufPrint(&db, "{s}.{d}", .{ log_path, i }) catch continue;
        compat.fs.cwd().rename(src, dst) catch {};
    }
    var db: [512]u8 = undefined;
    const dst = std.fmt.bufPrint(&db, "{s}.1", .{log_path}) catch return;
    compat.fs.cwd().rename(log_path, dst) catch {};
}

fn openLogFd(path_z: [*:0]const u8) c_int {
    return std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o644));
}

fn loggerThread() void {
    var buf: [4096]u8 = undefined;
    var since_check: u64 = 0;
    while (true) {
        const r = std.c.read(g_pipe_read, &buf, buf.len);
        if (r <= 0) break;
        const slice = buf[0..@as(usize, @intCast(r))];

        if (g_orig_stderr_fd >= 0) {
            _ = std.c.write(g_orig_stderr_fd, slice.ptr, slice.len);
        }
        if (g_log_fd >= 0) {
            _ = std.c.write(g_log_fd, slice.ptr, slice.len);
        }

        // Cheap rotation: every ~64KB written, stat and rotate if needed.
        since_check +%= slice.len;
        if (since_check >= 64 * 1024) {
            since_check = 0;
            const log_path = g_log_path_buf[0..g_log_path_len];
            const stat = compat.fs.cwd().statFile(log_path) catch continue;
            if (stat.size >= LOG_ROTATE_BYTES) {
                if (g_log_fd >= 0) _ = std.c.close(g_log_fd);
                g_log_fd = -1;
                rotateIfNeeded(log_path);

                var pz: [512]u8 = undefined;
                const path_z = std.fmt.bufPrintZ(&pz, "{s}", .{log_path}) catch continue;
                g_log_fd = openLogFd(path_z.ptr);
            }
        }
    }
}

/// Tee stdout+stderr through a pipe to (a) the original terminal/parent fd,
/// and (b) ${home}/logs/node.log. Rotates at LOG_ROTATE_BYTES, keeping
/// LOG_KEEP backups. Safe to call once at startup.
pub fn installLogTee(home: []const u8) Error!void {
    var dir_buf: [512]u8 = undefined;
    const logs_dir = std.fmt.bufPrint(&dir_buf, "{s}/logs", .{home}) catch return Error.HomeTooLong;
    compat.fs.cwd().makePath(logs_dir) catch {};

    const log_path = std.fmt.bufPrint(&g_log_path_buf, "{s}/logs/node.log", .{home}) catch return Error.HomeTooLong;
    g_log_path_len = log_path.len;

    rotateIfNeeded(log_path);

    var pz: [512]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&pz, "{s}", .{log_path}) catch return Error.HomeTooLong;
    const log_fd = openLogFd(path_z.ptr);
    if (log_fd < 0) {
        std.debug.print("LOG_OPEN_FAIL: path={s}\n", .{log_path});
        return Error.LogOpenFailed;
    }
    g_log_fd = log_fd;

    // Save original stderr so the writer thread can mirror to the operator's
    // terminal / parent-process redirection target.
    const orig = dup(2);
    if (orig < 0) return Error.DupFailed;
    g_orig_stderr_fd = orig;

    var pfds: [2]c_int = undefined;
    if (pipe(&pfds) != 0) return Error.PipeFailed;
    g_pipe_read = pfds[0];
    const pipe_write = pfds[1];

    if (dup2(pipe_write, 2) < 0) return Error.Dup2Failed;
    if (dup2(pipe_write, 1) < 0) return Error.Dup2Failed;
    _ = std.c.close(pipe_write);

    _ = std.Thread.spawn(.{}, loggerThread, .{}) catch {
        std.debug.print("LOG_TEE_THREAD_SPAWN_FAIL — file logging disabled\n", .{});
        return Error.LogOpenFailed;
    };

    std.debug.print("LOG_TEE_INSTALLED: file={s} rotate_mb={d} keep={d}\n", .{ log_path, LOG_ROTATE_BYTES / (1024 * 1024), LOG_KEEP });
}
