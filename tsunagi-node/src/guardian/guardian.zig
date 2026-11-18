const std = @import("std");
const compat = @import("compat");

pub fn run(alloc: std.mem.Allocator) !void {
    const state_dir = try getStateDir(alloc);
    defer alloc.free(state_dir);

    const guardian_dir = try std.fs.path.join(alloc, &[_][]const u8{ state_dir, "guardian" });
    defer alloc.free(guardian_dir);

    try compat.fs.cwd().makePath(guardian_dir);

    const events_path = try std.fs.path.join(alloc, &[_][]const u8{ guardian_dir, "events.jsonl" });
    defer alloc.free(events_path);

    std.debug.print("TSUNAGI Guardian started\n", .{});
    std.debug.print("State dir: {s}\n", .{state_dir});

    var last_slot: u64 = 0;
    var last_snapshot_mtime: i128 = 0;

    while (true) {
        const now = compat.timestamp();

        const cursor_info = try readCursor(state_dir, alloc);
        const utxo_info = try readSnapshot(state_dir, alloc);

        var health: []const u8 = "Healthy";

        if (cursor_info.slot <= last_slot) {
            health = "Degraded";
        }

        if (utxo_info.mtime <= last_snapshot_mtime) {
            health = "Degraded";
        }

        if (now - cursor_info.updated_unix > 120) {
            health = "Critical";
        }

        last_slot = cursor_info.slot;
        last_snapshot_mtime = utxo_info.mtime;

        std.debug.print(
            "HEALTH: {s} | slot={d} | utxo_snapshot_mtime={d}\n",
            .{ health, cursor_info.slot, utxo_info.mtime },
        );

        try appendEvent(events_path, alloc, now, health, cursor_info.slot);

        compat.sleep(5 * std.time.ns_per_s);
    }
}

fn readCursor(state_dir: []const u8, alloc: std.mem.Allocator) !struct {
    slot: u64,
    updated_unix: i64,
} {
    const cursor_path = try std.fs.path.join(alloc, &[_][]const u8{ state_dir, "cursor.json" });
    defer alloc.free(cursor_path);

    var file = try compat.fs.cwd().openFile(cursor_path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(alloc, 4096);
    defer alloc.free(contents);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, contents, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;

    const slot = obj.get("slot").?.integer;
    const updated = obj.get("updated_unix").?.integer;

    return .{
        .slot = @intCast(slot),
        .updated_unix = @intCast(updated),
    };
}

fn readSnapshot(state_dir: []const u8, alloc: std.mem.Allocator) !struct {
    mtime: i128,
} {
    const snapshot_path = try std.fs.path.join(alloc, &[_][]const u8{ state_dir, "utxo.snapshot" });
    defer alloc.free(snapshot_path);

    var file = try compat.fs.cwd().openFile(snapshot_path, .{});
    defer file.close();

    const stat = try file.stat();

    return .{
        .mtime = stat.mtime,
    };
}

fn appendEvent(path: []const u8, alloc: std.mem.Allocator, ts: i64, state: []const u8, slot: u64) !void {
    var file = try compat.fs.cwd().createFile(path, .{ .truncate = false });
    defer file.close();

    const end_pos = try file.getEndPos();
    try file.seekTo(end_pos);

    const line = try std.fmt.allocPrint(
        alloc,
        "{{\"ts\":{d},\"state\":\"{s}\",\"slot\":{d}}}\n",
        .{ ts, state, slot },
    );
    defer alloc.free(line);

    try file.writeAll(line);
}

fn getStateDir(alloc: std.mem.Allocator) ![]u8 {
    const env_dir = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
    if (env_dir) |dir| return dir;

    const home = try compat.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(home);

    return try std.fs.path.join(alloc, &[_][]const u8{ home, ".tsunagi" });
}
