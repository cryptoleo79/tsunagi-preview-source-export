// Phase B'''' — slot_index_reset utility (separable from runtime).
//
// Purpose: rollback-recovery — clears the SLOT_INDEX_SCHEMA sentinel and
// empties the slot_index DBI so the *next* binary that opens this LMDB
// env will treat slot_index as un-migrated and walk-rebuild it.
//
// Usage:
//   TSUNAGI_LMDB_DIR=/path/to/lmdb tsunagi-slot-index-reset
//   tsunagi-slot-index-reset /path/to/lmdb
//
// Environment:
//   TSUNAGI_LMDB_DIR    LMDB directory (env path). Required unless argv[1].
//   TSUNAGI_LMDB_MAP_GB Map size in GB; parsed identically to lmdb_utxo.zig
//                       (default 256, clamp [1, 1024]).
//
// FORBIDDEN: do NOT run this utility against an env held by a live
// post-fix tsunagi-node binary. The post-fix runtime caches its own
// open DBI handles and writes through them; an external mdb_drop would
// produce a torn read window. Operator runbook covers ordering.

const std = @import("std");
const compat = @import("compat");

const c = @cImport({
    @cInclude("lmdb.h");
});

const DEFAULT_MAP_GB: u64 = 256;
const SENTINEL_KEY: []const u8 = "SLOT_INDEX_SCHEMA";

fn resolveMapSize() usize {
    const raw = compat.getEnvVarOwned(std.heap.page_allocator, "TSUNAGI_LMDB_MAP_GB") catch {
        const default_bytes: u64 = DEFAULT_MAP_GB * 1024 * 1024 * 1024;
        std.debug.print("RESET_SLOT_INDEX: TSUNAGI_LMDB_MAP_GB unset; using default {d}GB\n", .{DEFAULT_MAP_GB});
        return @intCast(default_bytes);
    };
    defer std.heap.page_allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const gb = std.fmt.parseUnsigned(u64, trimmed, 10) catch {
        const default_bytes: u64 = DEFAULT_MAP_GB * 1024 * 1024 * 1024;
        std.debug.print("RESET_SLOT_INDEX: invalid TSUNAGI_LMDB_MAP_GB='{s}' — using default {d}GB\n", .{ raw, DEFAULT_MAP_GB });
        return @intCast(default_bytes);
    };
    const clamped = @max(1, @min(1024, gb));
    const bytes_u128: u128 = @as(u128, clamped) * 1024 * 1024 * 1024;
    const bytes: u64 = if (bytes_u128 > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(bytes_u128);
    std.debug.print("RESET_SLOT_INDEX: TSUNAGI_LMDB_MAP_GB='{s}' parsed gb={d} bytes={d}\n", .{ raw, clamped, bytes });
    return @intCast(bytes);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    std.debug.print("RESET_SLOT_INDEX: ensure no live tsunagi-node holds this env; concurrent mutation is undefined behaviour.\n", .{});

    // Resolve LMDB dir.
    var path_buf: ?[]u8 = null;
    defer if (path_buf) |p| std.heap.page_allocator.free(p);
    const path: []const u8 = blk: {
        if (compat.getEnvVarOwned(std.heap.page_allocator, "TSUNAGI_LMDB_DIR")) |v| {
            path_buf = v;
            break :blk v;
        } else |_| {
            // try argv[1]
            const args = try compat.argsAlloc(alloc);
            if (args.len >= 2) break :blk args[1];
            std.debug.print("RESET_SLOT_INDEX: ERROR — TSUNAGI_LMDB_DIR unset and no argv[1]\n", .{});
            return error.MissingLmdbDir;
        }
    };
    std.debug.print("RESET_SLOT_INDEX: target_dir='{s}'\n", .{path});

    // Make NUL-terminated for LMDB C API.
    const path_z = try std.heap.page_allocator.allocSentinel(u8, path.len, 0);
    defer std.heap.page_allocator.free(path_z);
    @memcpy(path_z, path);

    // Open env.
    var env: ?*c.MDB_env = null;
    if (c.mdb_env_create(&env) != 0) {
        std.debug.print("RESET_SLOT_INDEX: mdb_env_create failed\n", .{});
        return error.LmdbCreateFailed;
    }
    defer c.mdb_env_close(env);
    const map_size = resolveMapSize();
    if (c.mdb_env_set_mapsize(env, map_size) != 0) {
        std.debug.print("RESET_SLOT_INDEX: mdb_env_set_mapsize failed\n", .{});
        return error.LmdbMapSizeFailed;
    }
    if (c.mdb_env_set_maxdbs(env, 8) != 0) {
        std.debug.print("RESET_SLOT_INDEX: mdb_env_set_maxdbs failed\n", .{});
        return error.LmdbMaxDbsFailed;
    }
    if (c.mdb_env_open(env, path_z.ptr, c.MDB_NORDAHEAD, 0o644) != 0) {
        std.debug.print("RESET_SLOT_INDEX: mdb_env_open failed for '{s}'\n", .{path});
        return error.LmdbEnvOpenFailed;
    }
    std.debug.print("RESET_SLOT_INDEX: env opened\n", .{});

    // Begin write txn.
    var txn: ?*c.MDB_txn = null;
    if (c.mdb_txn_begin(env, null, 0, &txn) != 0) {
        std.debug.print("RESET_SLOT_INDEX: mdb_txn_begin failed\n", .{});
        return error.LmdbTxnFailed;
    }

    // Open headers DBI (MDB_CREATE — informational if pre-existing).
    var hdr_dbi: c.MDB_dbi = undefined;
    if (c.mdb_dbi_open(txn, "headers", c.MDB_CREATE, &hdr_dbi) != 0) {
        std.debug.print("RESET_SLOT_INDEX: open headers DBI failed\n", .{});
        c.mdb_txn_abort(txn);
        return error.HeadersOpenFailed;
    }

    // Delete sentinel (tolerate MDB_NOTFOUND).
    {
        var key_buf: [17]u8 = undefined;
        @memcpy(key_buf[0..17], SENTINEL_KEY);
        var key = c.MDB_val{ .mv_size = 17, .mv_data = &key_buf };
        const rc = c.mdb_del(txn, hdr_dbi, &key, null);
        if (rc == 0) {
            std.debug.print("RESET_SLOT_INDEX: sentinel deleted\n", .{});
        } else if (rc == c.MDB_NOTFOUND) {
            std.debug.print("RESET_SLOT_INDEX: sentinel not present (already-fresh env, treated as success)\n", .{});
        } else {
            std.debug.print("RESET_SLOT_INDEX: sentinel delete rc={d}\n", .{rc});
            c.mdb_txn_abort(txn);
            return error.SentinelDeleteFailed;
        }
    }

    // Open slot_index with MDB_CREATE (creates if absent on fresh envs).
    var slot_dbi: c.MDB_dbi = undefined;
    if (c.mdb_dbi_open(txn, "slot_index", c.MDB_CREATE, &slot_dbi) != 0) {
        std.debug.print("RESET_SLOT_INDEX: open slot_index DBI failed\n", .{});
        c.mdb_txn_abort(txn);
        return error.SlotIndexOpenFailed;
    }

    // Empty slot_index (retain DBI).
    if (c.mdb_drop(txn, slot_dbi, 0) != 0) {
        std.debug.print("RESET_SLOT_INDEX: mdb_drop slot_index failed\n", .{});
        c.mdb_txn_abort(txn);
        return error.SlotIndexDropFailed;
    }
    std.debug.print("RESET_SLOT_INDEX: slot_index cleared (DBI retained)\n", .{});

    if (c.mdb_txn_commit(txn) != 0) {
        std.debug.print("RESET_SLOT_INDEX: commit failed\n", .{});
        return error.CommitFailed;
    }
    std.debug.print("RESET_SLOT_INDEX: commit OK — next binary boot will rebuild slot_index\n", .{});
}
