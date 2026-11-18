const std = @import("std");
const compat = @import("compat");
const build_info = @import("../build_info.zig");

// ── build-info command (v4.2.0) ────────────────────────────────────
//
// Prints build identity. Bounded output. No network, no secrets.

pub fn run(_: std.mem.Allocator, args_it: anytype) u8 {
    var json = false;
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        }
    }

    var stdout_file = compat.fs.File.stdout();
    const stdout = stdout_file.writer();
    if (json) {
        build_info.printJson(stdout) catch return 1;
    } else {
        build_info.printVersionLine(stdout) catch return 1;
    }
    return 0;
}
