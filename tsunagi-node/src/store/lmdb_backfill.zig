const std = @import("std");
const compat = @import("compat");
const lmdb_utxo = @import("lmdb_utxo.zig");
const tx_decode = @import("../net/ledger/tx_decode.zig");
const utxo_mod = @import("../net/ledger/utxo.zig");
const cbor = @import("../net/cbor/term.zig");

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

// Decode block payload bytes -> TxDeltas (same shape assumptions as BlockFetch)
fn decodePayloadToDeltas(alloc: std.mem.Allocator, payload: []const u8, debug: bool) !tx_decode.TxDeltas {
    var fbs = compat.fixedBufferStream(payload);
    const term = try cbor.decode(alloc, fbs.reader());
    defer cbor.free(term, alloc);

    if (term != .array or term.array.len < 2) return error.InvalidBlockShape;

    // Block structure: [era, block_content]
    const block_content = term.array[1];
    const scan = tx_decode.extractTxListFromTermPublic(alloc, block_content) orelse {
        // No tx list => return empty deltas
        return tx_decode.TxDeltas{ .consumed = &[_]utxo_mod.TxIn{}, .produced = &[_]utxo_mod.Produced{}, .tx_count = 0 };
    };
    const tx_list = scan.tx_list;
    if (tx_list.len == 0) return tx_decode.TxDeltas{ .consumed = &[_]utxo_mod.TxIn{}, .produced = &[_]utxo_mod.Produced{}, .tx_count = 0 };

    return try tx_decode.extractTxDeltas(alloc, tx_list, null, debug);
}

pub fn run(
    alloc: std.mem.Allocator,
    capture_path: []const u8,
    lmdb_dir_opt: ?[]const u8,
    max_blocks_opt: ?usize,
    strict: bool,
) !void {
    if (!fileExists(capture_path)) {
        std.debug.print("lmdb-backfill: file not found: {s}\n", .{capture_path});
        return error.FileNotFound;
    }

    const lmdb_dir = if (lmdb_dir_opt) |p| try alloc.dupe(u8, p) else try getDefaultLmdbDir(alloc);
    defer alloc.free(lmdb_dir);

    try compat.fs.cwd().makePath(lmdb_dir);

    std.debug.print("lmdb-backfill: file={s}\n", .{capture_path});
    std.debug.print("lmdb-backfill: lmdb_dir={s}\n", .{lmdb_dir});
    if (max_blocks_opt) |m| std.debug.print("lmdb-backfill: max={d}\n", .{m});
    std.debug.print("lmdb-backfill: strict={}\n", .{strict});

    const lmdb_dir_z = try alloc.dupeZ(u8, lmdb_dir);
    defer alloc.free(lmdb_dir_z);

    var store = try lmdb_utxo.LmdbUtxo.open(lmdb_dir_z);
    defer store.close();

    var f = try compat.fs.cwd().openFile(capture_path, .{});
    defer f.close();
    var r = f.reader();

    const max_blocks = max_blocks_opt orelse std.math.maxInt(usize);

    var blocks: usize = 0;
    var applied: usize = 0;
    var skipped: usize = 0;

    while (blocks < max_blocks) {
        var len_buf: [4]u8 = undefined;
        const n = try r.readAll(&len_buf);
        if (n == 0) break;
        if (n != 4) return error.InvalidReplayFile;

        const len = std.mem.readInt(u32, &len_buf, .little);
        if (len == 0) continue;

        const payload = try alloc.alloc(u8, len);
        defer alloc.free(payload);
        r.readNoEof(payload) catch break; // truncated trailing entry = EOF

        blocks += 1;

        const deltas = decodePayloadToDeltas(alloc, payload, false) catch |err| {
            std.debug.print("lmdb-backfill: decode fail block[{d}] err={s}\n", .{ blocks, @errorName(err) });
            skipped += 1;
            if (strict) return err;
            continue;
        };
        defer tx_decode.freeTxDeltas(alloc, deltas);

        // One txn per block
        const txn0 = store.beginWrite() orelse {
            std.debug.print("lmdb-backfill: beginWrite failed\n", .{});
            if (strict) return error.LmdbTxnBeginFailed;
            skipped += 1;
            continue;
        };
        var txn = txn0;

        // Apply deletes first; if missing consumed, this will be NOTFOUND and is ok for backfill
        for (deltas.consumed) |c0| {
            store.delTxn(&txn, c0.tx_hash, c0.index);
        }
        for (deltas.produced) |p0| {
            store.putTxn(alloc, &txn, p0.input.tx_hash, p0.input.index, p0.output);
        }

        const ok_commit = store.commit(&txn);
        if (!ok_commit) {
            std.debug.print("lmdb-backfill: commit failed block[{d}]\n", .{blocks});
            if (strict) return error.LmdbCommitFailed;
            skipped += 1;
            continue;
        }

        applied += 1;

        if ((blocks % 25) == 0) {
            std.debug.print("lmdb-backfill: blocks={d} applied={d} skipped={d}\n", .{ blocks, applied, skipped });
        }
    }

    std.debug.print("lmdb-backfill: DONE blocks={d} applied={d} skipped={d}\n", .{ blocks, applied, skipped });
}
