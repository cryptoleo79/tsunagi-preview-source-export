// Phase: first-accepted-block sprint — minimal doppelganger guard.
// Places a PID+start-time lockfile at $TSUNAGI_HOME/doppelganger.lock.
// If the file exists with a DIFFERENT live pid → log DOPPELGANGER_WARN.
// Does NOT abort forge. Observation-only.

const std = @import("std");
const compat = @import("compat");

pub fn check(alloc: std.mem.Allocator) void {
    const home = compat.getenv("TSUNAGI_HOME") orelse return;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/doppelganger.lock", .{home}) catch return;

    const pid: i32 = @intCast(std.os.linux.getpid());
    const now = compat.timestamp();

    // Check existing file
    if (compat.fs.cwd().openFile(path, .{})) |fc| {
        var f = fc;
        defer f.close();
        var buf: [128]u8 = undefined;
        const n = f.readAll(&buf) catch 0;
        if (n > 0) {
            var it = std.mem.tokenizeAny(u8, buf[0..n], " \t\r\n");
            if (it.next()) |pid_s| {
                const other_pid = std.fmt.parseInt(i32, pid_s, 10) catch 0;
                if (other_pid != 0 and other_pid != pid and pidAlive(other_pid)) {
                    std.debug.print("DOPPELGANGER_WARN: other_pid={d} our_pid={d} path={s}\n", .{
                        other_pid, pid, path,
                    });
                }
            }
        }
    } else |_| {}

    // Overwrite with our pid + start time
    if (compat.fs.cwd().createFile(path, .{ .truncate = true })) |fc| {
        var f = fc;
        defer f.close();
        var out_buf: [64]u8 = undefined;
        const out = std.fmt.bufPrint(&out_buf, "{d} {d}\n", .{ pid, now }) catch return;
        _ = f.writeAll(out) catch {};
    } else |_| {}
    _ = alloc;
}

fn pidAlive(pid: i32) bool {
    // Send signal 0 — succeeds only if process exists.
    std.posix.kill(pid, @enumFromInt(0)) catch return false;
    return true;
}

test "check does not panic without TSUNAGI_HOME" {
    check(std.testing.allocator);
}
