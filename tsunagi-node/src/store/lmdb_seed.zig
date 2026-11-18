const std = @import("std");
const compat = @import("compat");
const lmdb_utxo = @import("lmdb_utxo.zig");
const utxo_mod = @import("../net/ledger/utxo.zig");

fn fileExists(path: []const u8) bool {
    var f = compat.fs.cwd().openFile(path, .{}) catch return false;
    f.close();
    return true;
}

fn getDefaultLmdbDir(alloc: std.mem.Allocator) ![]u8 {
    const env_dir = compat.getEnvVarOwned(alloc, "TSUNAGI_LMDB") catch null;
    if (env_dir) |d| return d;

    const state_dir = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
    if (state_dir) |sd| {
        defer alloc.free(sd);
        return try std.fs.path.join(alloc, &[_][]const u8{ sd, "lmdb" });
    }

    const home = try compat.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(home);

    return try std.fs.path.join(alloc, &[_][]const u8{ home, ".tsunagi", "lmdb" });
}

fn parseLineTxInAndLovelace(line: []const u8) ?struct { key: utxo_mod.TxIn, lovelace: u64 } {
    const trimmed = std.mem.trim(u8, line, " \r\t");
    if (trimmed.len == 0) return null;

    const sp = std.mem.indexOfScalar(u8, trimmed, ' ') orelse return null;
    const left = trimmed[0..sp];
    const rest = std.mem.trimStart(u8, trimmed[sp + 1 ..], " \t");

    const colon = std.mem.indexOfScalar(u8, left, ':') orelse return null;
    const hex = left[0..colon];
    const idx_str = left[colon + 1 ..];

    if (hex.len != 64) return null;

    var hash: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&hash, hex) catch return null;

    const idx = std.fmt.parseInt(u32, idx_str, 10) catch return null;

    // Parse lovelace — may have trailing fields, take first token
    const lov_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    const lovelace = std.fmt.parseInt(u64, rest[0..lov_end], 10) catch return null;

    return .{
        .key = utxo_mod.TxIn{ .tx_hash = hash, .index = idx },
        .lovelace = lovelace,
    };
}

pub fn run(
    alloc: std.mem.Allocator,
    snapshot_path: []const u8,
    lmdb_dir_opt: ?[]const u8,
    limit_opt: ?usize,
) !void {
    if (!fileExists(snapshot_path)) {
        std.debug.print("lmdb-seed: snapshot not found: {s}\n", .{snapshot_path});
        return error.FileNotFound;
    }

    const lmdb_dir = if (lmdb_dir_opt) |p| try alloc.dupe(u8, p) else try getDefaultLmdbDir(alloc);
    defer alloc.free(lmdb_dir);

    try compat.fs.cwd().makePath(lmdb_dir);

    std.debug.print("lmdb-seed: snapshot={s}\n", .{snapshot_path});
    std.debug.print("lmdb-seed: lmdb_dir={s}\n", .{lmdb_dir});
    if (limit_opt) |lim| std.debug.print("lmdb-seed: limit={d}\n", .{lim});

    const lmdb_dir_z = try alloc.dupeZ(u8, lmdb_dir);
    defer alloc.free(lmdb_dir_z);

    var store = try lmdb_utxo.LmdbUtxo.open(lmdb_dir_z);
    defer store.close();

    // One big write txn
    const txn0 = store.beginWrite() orelse return error.LmdbTxnBeginFailed;
    var txn = txn0;
    errdefer store.abort(&txn);

    var f = try compat.fs.cwd().openFile(snapshot_path, .{});
    defer f.close();

    const buf_reader = f.deprecatedReader();
    var r = buf_reader;

    var inserted: usize = 0;
    const limit = limit_opt orelse std.math.maxInt(usize);

    var line_buf: [512]u8 = undefined;

    while (inserted < limit) {
        const line = r.readUntilDelimiterOrEof(&line_buf, '\n') catch break;
        if (line == null) break;

        const parsed = parseLineTxInAndLovelace(line.?);
        if (parsed) |p| {
            const out = utxo_mod.TxOut{ .address = &[0]u8{}, .lovelace = p.lovelace };
            store.putTxn(alloc, &txn, p.key.tx_hash, p.key.index, out);
            inserted += 1;
        }
    }

    const ok = store.commit(&txn);
    if (!ok) return error.LmdbCommitFailed;

    std.debug.print("lmdb-seed: inserted={d}\n", .{inserted});
    std.debug.print("lmdb-seed: done\n", .{});
}
