const std = @import("std");
const compat = @import("compat");
const replay_run_cmd = @import("../replay/replay_run_cmd.zig");

pub fn run(
    alloc: std.mem.Allocator,
    file_path: []const u8,
    out_dir: []const u8,
    baseline_json: []const u8,
    max_blocks: usize,
    repeat: usize,
    regress_threshold: u64,
    trend: bool,
) u8 {
    // Build current report dir
    const current_dir = std.fmt.allocPrint(alloc, "{s}/current", .{out_dir}) catch {
        std.debug.print("REGRESS: alloc failed\n", .{});
        return 1;
    };
    defer alloc.free(current_dir);

    // Create output directory
    compat.fs.cwd().makePath(current_dir) catch |err| {
        std.debug.print("REGRESS: cannot create {s}: {s}\n", .{ current_dir, @errorName(err) });
        return 1;
    };

    // Verify baseline exists
    var bf = compat.fs.cwd().openFile(baseline_json, .{}) catch {
        std.debug.print("REGRESS: baseline not found: {s}\n", .{baseline_json});
        return 1;
    };
    bf.close();

    // Build temp LMDB dir
    const lmdb_dir = std.fmt.allocPrint(alloc, "{s}/current/lmdb-tmp", .{out_dir}) catch return 1;
    defer alloc.free(lmdb_dir);

    std.debug.print(
        \\
        \\╔══════════════════════════════════════╗
        \\║  REPLAY REGRESSION                   ║
        \\╚══════════════════════════════════════╝
        \\
        \\  file:       {s}
        \\  out-dir:    {s}
        \\  baseline:   {s}
        \\  max-blocks: {d}
        \\  repeat:     {d}
        \\  threshold:  {d}%
        \\
    , .{ file_path, current_dir, baseline_json, max_blocks, repeat, regress_threshold });

    // Delegate to replay-run with regression defaults
    const exit_code = replay_run_cmd.run(
        alloc,
        file_path,
        lmdb_dir,
        max_blocks,
        0, // from_offset
        false, // strict
        false, // debug
        current_dir, // report_dir
        null, // report_prefix
        repeat,
        true, // fresh
        true, // perf
        true, // quiet
        baseline_json,
        regress_threshold,
        trend,
    );

    if (exit_code == 0) {
        std.debug.print("\nREGRESS: results in {s}/\n", .{current_dir});
    }
    return exit_code;
}
