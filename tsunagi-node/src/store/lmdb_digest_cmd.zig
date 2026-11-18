const std = @import("std");
const compat = @import("compat");
const lmdb_utxo = @import("lmdb_utxo.zig");

fn defaultLmdbDir(alloc: std.mem.Allocator) ![]u8 {
    const env = compat.getEnvVarOwned(alloc, "TSUNAGI_LMDB") catch null;
    if (env) |d| return d;
    const home = try compat.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(home);
    return try std.fs.path.join(alloc, &[_][]const u8{ home, "tsunagi-home-mainnet", "lmdb" });
}

pub fn run(alloc: std.mem.Allocator, lmdb_dir_opt: ?[]const u8) u8 {
    const lmdb_dir = if (lmdb_dir_opt) |p|
        (alloc.dupe(u8, p) catch {
            std.debug.print("lmdb-digest: alloc failed\n", .{});
            return 1;
        })
    else
        (defaultLmdbDir(alloc) catch {
            std.debug.print("lmdb-digest: could not resolve LMDB directory\n", .{});
            return 1;
        });
    defer alloc.free(lmdb_dir);

    const lmdb_dir_z = alloc.dupeZ(u8, lmdb_dir) catch {
        std.debug.print("lmdb-digest: alloc failed\n", .{});
        return 1;
    };
    defer alloc.free(lmdb_dir_z);

    var store = lmdb_utxo.LmdbUtxo.open(lmdb_dir_z) catch {
        std.debug.print("lmdb-digest: failed to open LMDB at {s}\n", .{lmdb_dir_z});
        return 1;
    };
    defer store.close();

    const digest = store.computeStateDigest() orelse {
        std.debug.print("lmdb-digest: failed to compute state digest\n", .{});
        return 1;
    };

    std.debug.print("{x}\n", .{&digest});
    return 0;
}
