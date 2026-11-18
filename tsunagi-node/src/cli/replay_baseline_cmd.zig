const std = @import("std");
const compat = @import("compat");
const replay_run_cmd = @import("../replay/replay_run_cmd.zig");

pub fn run(
    alloc: std.mem.Allocator,
    file_path: []const u8,
    out_dir: []const u8,
    max_blocks: usize,
    repeat: usize,
    force: bool,
) u8 {
    // Build baseline report dir
    const baseline_dir = std.fmt.allocPrint(alloc, "{s}/baseline", .{out_dir}) catch {
        std.debug.print("BASELINE: alloc failed\n", .{});
        return 1;
    };
    defer alloc.free(baseline_dir);

    // Safety: refuse if baseline already exists unless --force
    if (!force) {
        const probe_path = std.fmt.allocPrint(alloc, "{s}/report.json", .{baseline_dir}) catch return 1;
        defer alloc.free(probe_path);
        if (compat.fs.cwd().openFile(probe_path, .{})) |f| {
            var ff = f;
            ff.close();
            std.debug.print("BASELINE: {s}/report.json already exists. Use --force to overwrite.\n", .{baseline_dir});
            return 1;
        } else |_| {}
    }

    // Create output directory
    compat.fs.cwd().makePath(baseline_dir) catch |err| {
        std.debug.print("BASELINE: cannot create {s}: {s}\n", .{ baseline_dir, @errorName(err) });
        return 1;
    };

    // Build temp LMDB dir
    const lmdb_dir = std.fmt.allocPrint(alloc, "{s}/baseline/lmdb-tmp", .{out_dir}) catch return 1;
    defer alloc.free(lmdb_dir);

    std.debug.print(
        \\
        \\╔══════════════════════════════════════╗
        \\║  REPLAY BASELINE                     ║
        \\╚══════════════════════════════════════╝
        \\
        \\  file:       {s}
        \\  out-dir:    {s}
        \\  max-blocks: {d}
        \\  repeat:     {d}
        \\
    , .{ file_path, baseline_dir, max_blocks, repeat });

    // Delegate to replay-run with benchmark defaults
    const exit_code = replay_run_cmd.run(
        alloc,
        file_path,
        lmdb_dir,
        max_blocks,
        0, // from_offset
        false, // strict
        false, // debug
        baseline_dir, // report_dir
        null, // report_prefix
        repeat,
        true, // fresh
        true, // perf
        true, // quiet
        null, // baseline_json (none — this IS the baseline)
        15, // regress_threshold
        false, // trend
    );

    if (exit_code == 0) {
        std.debug.print("\nBASELINE: written to {s}/\n", .{baseline_dir});
    }
    return exit_code;
}
