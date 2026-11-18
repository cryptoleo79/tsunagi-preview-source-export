const std = @import("std");
const compat = @import("compat");

fn fileExists(path: []const u8) bool {
    var f = compat.fs.cwd().openFile(path, .{}) catch return false;
    f.close();
    return true;
}

fn getTsunagiHome(alloc: std.mem.Allocator) ![]u8 {
    const env_dir = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            const home = try compat.getEnvVarOwned(alloc, "HOME");
            defer alloc.free(home);
            return try std.fs.path.join(alloc, &[_][]const u8{ home, "tsunagi-home-mainnet" });
        },
        else => return err,
    };
    return env_dir;
}

fn autoswitchEnabled() bool {
    const v = compat.getEnvVarOwned(std.heap.page_allocator, "TSUNAGI_AUTOSWITCH") catch return false;
    defer std.heap.page_allocator.free(v);
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

pub fn run(alloc: std.mem.Allocator) !void {
    const home = try getTsunagiHome(alloc);
    defer alloc.free(home);

    const marker = try std.fs.path.join(alloc, &[_][]const u8{ home, "native_ready.json" });
    defer alloc.free(marker);

    if (!fileExists(marker)) {
        std.debug.print("autoswitch-apply: no marker found ({s})\n", .{marker});
        return;
    }

    if (!autoswitchEnabled()) {
        std.debug.print("autoswitch-apply: marker exists but TSUNAGI_AUTOSWITCH not enabled; skipping\n", .{});
        return;
    }

    // Create systemd drop-in that enables truth/native mode
    const user_home = try compat.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(user_home);

    const dropin_dir = try std.fs.path.join(alloc, &[_][]const u8{
        user_home, ".config", "systemd", "user", "tsunagi-mainnet.service.d",
    });
    defer alloc.free(dropin_dir);

    try compat.fs.cwd().makePath(dropin_dir);

    const dropin_path = try std.fs.path.join(alloc, &[_][]const u8{ dropin_dir, "99-native.conf" });
    defer alloc.free(dropin_path);

    // Check if drop-in already exists (idempotent)
    if (fileExists(dropin_path)) {
        std.debug.print("autoswitch-apply: drop-in already exists ({s}); no action needed\n", .{dropin_path});
        return;
    }

    var f = try compat.fs.cwd().createFile(dropin_path, .{ .truncate = true });
    defer f.close();

    try f.writeAll(
        \\[Service]
        \\Environment=TSUNAGI_LMDB_TRUTH=1
        \\Environment=TSUNAGI_LMDB_AUTHORITY=1
        \\Environment=TSUNAGI_MODE=lmdb_native
        \\
    );

    std.debug.print("autoswitch-apply: wrote {s}\n", .{dropin_path});
    std.debug.print("autoswitch-apply: running daemon-reload + restart\n", .{});

    // Execute systemctl commands
    var reload = compat.Child.init(
        &[_][]const u8{ "systemctl", "--user", "daemon-reload" },
        alloc,
    );
    _ = reload.spawnAndWait() catch {};

    var restart = compat.Child.init(
        &[_][]const u8{ "systemctl", "--user", "restart", "tsunagi-mainnet.service" },
        alloc,
    );
    _ = restart.spawnAndWait() catch {};

    std.debug.print("autoswitch-apply: done\n", .{});
}
