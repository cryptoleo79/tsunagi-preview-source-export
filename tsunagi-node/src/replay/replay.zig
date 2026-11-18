const std = @import("std");
const compat = @import("compat");
const follower = @import("../net/chainsync/follower.zig");
const i18n = @import("../cli/i18n.zig");

fn fileExists(path: []const u8) bool {
    var f = compat.fs.cwd().openFile(path, .{}) catch return false;
    f.close();
    return true;
}

fn getStateDir(alloc: std.mem.Allocator) ![]u8 {
    const env_dir = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
    if (env_dir) |d| return d;
    const home = try compat.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(home);
    return try std.fs.path.join(alloc, &[_][]const u8{ home, ".tsunagi" });
}

fn parseTxInKey(line: []const u8) !?follower.utxo_mod.TxIn {
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
    const left = line[0..sp];
    const colon = std.mem.indexOfScalar(u8, left, ':') orelse return null;

    const hex = left[0..colon];
    const idx_str = left[colon + 1 ..];

    if (hex.len != 64) return null;

    var hash: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&hash, hex) catch return null;

    const idx = std.fmt.parseInt(u32, idx_str, 10) catch return null;

    return follower.utxo_mod.TxIn{ .tx_hash = hash, .index = idx };
}

fn seedKeySetFromSnapshot(alloc: std.mem.Allocator, ctx: *follower.ReplayCtx, snapshot_path: []const u8) !usize {
    var f = try compat.fs.cwd().openFile(snapshot_path, .{});
    defer f.close();

    const data = try f.readToEndAlloc(alloc, 64 * 1024 * 1024);
    defer alloc.free(data);

    var it = std.mem.splitScalar(u8, data, '\n');
    var count: usize = 0;

    while (it.next()) |line0| {
        const line = std.mem.trim(u8, line0, " \r\t");
        if (line.len == 0) continue;
        const txin_opt = parseTxInKey(line) catch continue;
        if (txin_opt) |txin| {
            ctx.utxo_keys.put(txin, {}) catch continue;
            count += 1;
        }
    }
    return count;
}

pub fn run(
    alloc: std.mem.Allocator,
    file_path: []const u8,
    lang: i18n.Lang,
    debug: bool,
) !void {
    _ = lang;

    std.debug.print("TSUNAGI Replay v0\n", .{});
    std.debug.print("File: {s}\n\n", .{file_path});

    var file = try compat.fs.cwd().openFile(file_path, .{});
    defer file.close();

    var reader = file.reader();

    var ctx = try follower.ReplayCtx.init(alloc, debug);
    defer ctx.deinit();

    const state_dir = getStateDir(alloc) catch null;
    defer if (state_dir) |sd| alloc.free(sd);

    if (state_dir) |sd| {
        const snapshot_path = std.fs.path.join(alloc, &[_][]const u8{ sd, "utxo.snapshot" }) catch null;
        defer if (snapshot_path) |sp| alloc.free(sp);

        if (snapshot_path) |sp| {
            if (fileExists(sp)) {
                const seeded = seedKeySetFromSnapshot(alloc, &ctx, sp) catch 0;
                std.debug.print("REPLAY seed: loaded {d} keys from {s}\n", .{ seeded, sp });
            } else {
                std.debug.print("REPLAY seed: no snapshot found at {s} (strict mode will likely fail on first consume)\n", .{sp});
            }
        }
    }

    var total_blocks: usize = 0;
    var total_txs: usize = 0;

    while (true) {
        var len_buf: [4]u8 = undefined;
        const n = try file.readAll(&len_buf);
        if (n == 0) break;
        if (n != 4) return error.InvalidReplayFile;

        const len = std.mem.readInt(u32, &len_buf, .little);
        if (len == 0) continue;

        const payload = try alloc.alloc(u8, len);
        defer alloc.free(payload);

        try reader.readNoEof(payload);

        const synthetic_slot = total_blocks + 1;
        const synthetic_block = total_blocks + 1;

        const result = follower.replayProcessBlock(
            alloc,
            &ctx,
            synthetic_slot,
            synthetic_block,
            payload,
        ) catch |err| {
            std.debug.print("REPLAY ABORT: {s}\n", .{@errorName(err)});
            var hex: [64]u8 = undefined;
            const d = follower.replayDigestHex(&ctx, &hex);
            std.debug.print("FINAL DIGEST (partial): {s}\n", .{d});
            return err;
        };

        total_blocks += 1;
        total_txs += result.tx_count;

        if (debug) {
            var hex: [64]u8 = undefined;
            const d = follower.replayDigestHex(&ctx, &hex);
            std.debug.print(
                "REPLAY block[{d}] txs={d} utxo={d} undo={d}\n",
                .{
                    total_blocks,
                    result.tx_count,
                    ctx.utxo.count(),
                    ctx.undo_stack.items.len,
                },
            );
            std.debug.print("REPLAY digest={s}\n", .{d});
        }
    }

    var final_hex: [64]u8 = undefined;
    const final_digest = follower.replayDigestHex(&ctx, &final_hex);

    std.debug.print(
        "\nREPLAY DONE\nblocks={d} txs={d} utxo={d} undo_depth={d}\ndigest={s}\n",
        .{
            total_blocks,
            total_txs,
            ctx.utxo.count(),
            ctx.undo_stack.items.len,
            final_digest,
        },
    );
}
