const std = @import("std");
const capture = @import("../replay/capture.zig");

pub fn run(alloc: std.mem.Allocator, dir: []const u8, max_bytes: u64) !void {
    std.debug.print("capture-retention: dir={s}\n", .{dir});
    std.debug.print("capture-retention: max_bytes={d}\n", .{max_bytes});
    capture.enforceRetentionPublic(alloc, dir, max_bytes);
    std.debug.print("capture-retention: done\n", .{});
}
