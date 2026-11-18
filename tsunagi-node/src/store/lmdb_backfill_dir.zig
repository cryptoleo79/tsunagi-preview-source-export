const std = @import("std");
const compat = @import("compat");
const lmdb_backfill = @import("lmdb_backfill.zig");
const capture_mod = @import("../replay/capture.zig");

pub fn run(
    alloc: std.mem.Allocator,
    captures_dir: []const u8,
    lmdb_dir_opt: ?[]const u8,
    max_per_file_opt: ?usize,
    strict: bool,
    net_opt: ?[]const u8,
) !void {
    if (net_opt) |net| capture_mod.setNetPrefix(net);
    std.debug.print("lmdb-backfill-dir: dir={s} net={s}\n", .{ captures_dir, capture_mod.netPrefix() });
    if (lmdb_dir_opt) |p| std.debug.print("lmdb-backfill-dir: lmdb={s}\n", .{p});
    if (max_per_file_opt) |m| std.debug.print("lmdb-backfill-dir: max-per-file={d}\n", .{m});
    std.debug.print("lmdb-backfill-dir: strict={}\n", .{strict});

    var dir = try compat.fs.cwd().openDir(captures_dir, .{ .iterate = true });
    defer dir.close();

    var names = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (names.items) |s| alloc.free(s);
        names.deinit();
    }

    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind != .file) continue;
        if (!capture_mod.isCaptureFile(e.name)) continue;
        try names.append(try alloc.dupe(u8, e.name));
    }

    if (names.items.len == 0) {
        std.debug.print("lmdb-backfill-dir: no capture files found\n", .{});
        return;
    }

    // Sort: rotated files (<net>.<timestamp>.bin) first in lex order,
    // then <net>.bin last (it's the active/current segment).
    std.sort.insertion([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            const a_active = !capture_mod.isRotatedCapture(a);
            const b_active = !capture_mod.isRotatedCapture(b);
            if (a_active and !b_active) return false;
            if (!a_active and b_active) return true;
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var total_files: usize = 0;

    for (names.items) |n| {
        total_files += 1;
        const full_path = try std.fs.path.join(alloc, &[_][]const u8{ captures_dir, n });
        defer alloc.free(full_path);

        std.debug.print("\n=== BACKFILL FILE [{d}/{d}] {s} ===\n", .{ total_files, names.items.len, full_path });

        try lmdb_backfill.run(alloc, full_path, lmdb_dir_opt, max_per_file_opt, strict);
    }

    std.debug.print("\nlmdb-backfill-dir: done files={d}\n", .{names.items.len});
}
