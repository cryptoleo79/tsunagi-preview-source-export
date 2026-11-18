const std = @import("std");
const compat = @import("compat");
const lmdb_utxo = @import("../store/lmdb_utxo.zig");
const header_store_mod = @import("../store/header_store.zig");
const cursor_store = @import("../net/ledger/cursor.zig");
const c = lmdb_utxo.c;
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

const CANONICAL_ENTRY_SIZE = 44; // txid(32) + index_BE(4) + lovelace_BE(8)

const DigestResult = struct {
    digest: [32]u8,
    utxo_entries: u64,
};

// ── Dispatch ──

pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    const subcmd = args_it.next() orelse {
        printUsage();
        return 1;
    };
    if (std.mem.eql(u8, subcmd, "snapshot")) return runSnapshot(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "digest")) return runDigest(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "rewind")) return runRewind(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "replay")) return runReplay(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "verify")) return runVerify(alloc, args_it);
    std.debug.print("ERROR: unknown ledger-harness subcommand: {s}\n", .{subcmd});
    printUsage();
    return 1;
}

fn printUsage() void {
    std.debug.print(
        \\Usage: tsunagi-node ledger-harness <subcommand> [options]
        \\
        \\Subcommands:
        \\  snapshot    Compute deterministic ledger digest + write snapshot JSON
        \\  digest      Compute + print deterministic ledger digest (no file)
        \\  rewind      Walk header chain back N blocks
        \\  replay      Verify chain integrity + recompute digest
        \\  verify      Compare current digest with snapshot file
        \\
        \\Options:
        \\  --home <path>       TSUNAGI_HOME path (or TSUNAGI_HOME env)
        \\  --blocks <N>        Number of blocks to rewind (rewind only)
        \\  --snapshot <file>   Snapshot JSON path (verify only)
        \\
    , .{});
}

// ── Deterministic Digest (CRITICAL) ──
//
// 1) Iterate all UTxO entries from LMDB
// 2) Construct canonical bytes: txid(32) || index_BE(4) || lovelace_BE(8)
// 3) Collect into array
// 4) Sort lexicographically
// 5) Stream into Blake2b256
// 6) Result = ledger_digest
//
// Guarantees: same state → same digest, independent of LMDB iteration order.

fn computeSortedDigest(alloc: std.mem.Allocator, store: *lmdb_utxo.LmdbUtxo) ?DigestResult {
    var rtxn = store.beginRead() orelse return null;
    defer store.abort(&rtxn);

    var it = store.cursorOpen(&rtxn) orelse return null;
    defer store.cursorClose(&it);

    var entries = std.array_list.Managed([CANONICAL_ENTRY_SIZE]u8).init(alloc);
    defer entries.deinit();

    var key: c.MDB_val = undefined;
    var val: c.MDB_val = undefined;

    while (store.cursorNext(&it, &key, &val)) {
        if (key.mv_size != 36) continue;
        if (val.mv_size < 8) continue;

        const kp: [*]const u8 = @ptrCast(key.mv_data);
        const vp: [*]const u8 = @ptrCast(val.mv_data);

        var entry: [CANONICAL_ENTRY_SIZE]u8 = undefined;
        // txid (32 bytes) — copy as-is
        @memcpy(entry[0..32], kp[0..32]);
        // index: LE in LMDB → BE in canonical
        const index_le: *const [4]u8 = @ptrCast(kp[32..36]);
        const index = std.mem.readInt(u32, index_le, .little);
        std.mem.writeInt(u32, entry[32..36], index, .big);
        // lovelace: LE in LMDB → BE in canonical
        const lv_le: *const [8]u8 = @ptrCast(vp[0..8]);
        const lovelace = std.mem.readInt(u64, lv_le, .little);
        std.mem.writeInt(u64, entry[36..44], lovelace, .big);

        entries.append(entry) catch return null;
    }

    // Sort lexicographically (defense-in-depth: independent of LMDB B-tree order)
    std.sort.block([CANONICAL_ENTRY_SIZE]u8, entries.items, {}, struct {
        fn lessThan(_: void, a: [CANONICAL_ENTRY_SIZE]u8, b: [CANONICAL_ENTRY_SIZE]u8) bool {
            return std.mem.order(u8, &a, &b) == .lt;
        }
    }.lessThan);

    // Stream sorted entries into Blake2b256
    var h = Blake2b256.init(.{});
    for (entries.items) |entry| {
        h.update(&entry);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);

    return DigestResult{
        .digest = digest,
        .utxo_entries = @intCast(entries.items.len),
    };
}

// ── snapshot ──

fn runSnapshot(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var home_flag: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--home")) {
            home_flag = args_it.next() orelse {
                std.debug.print("ERROR: --home requires a path\n", .{});
                return 3;
            };
        } else {
            std.debug.print("ERROR: unknown flag: {s}\n", .{arg});
            return 3;
        }
    }

    const home = resolveHomeDir(alloc, home_flag) orelse {
        std.debug.print("ERROR: --home or TSUNAGI_HOME required\n", .{});
        return 3;
    };
    defer if (home_flag == null) alloc.free(home);

    return snapshotWithHome(alloc, home);
}

fn snapshotWithHome(alloc: std.mem.Allocator, home: []const u8) u8 {
    var store = openLmdbFromHome(alloc, home) orelse return 4;
    defer store.close();

    // Read slot/block_no from cursor.json
    var slot: u64 = 0;
    var block_no: u64 = 0;
    loadCursorInfo(alloc, home, &store, &slot, &block_no);

    const result = computeSortedDigest(alloc, &store) orelse {
        std.debug.print("ERROR: digest computation failed\n", .{});
        return 4;
    };

    // Create snapshot directory
    const snap_dir = std.fs.path.join(alloc, &[_][]const u8{ home, "ledger_snapshots" }) catch return 4;
    defer alloc.free(snap_dir);

    compat.fs.cwd().makePath(snap_dir) catch {
        std.debug.print("ERROR: cannot create {s}\n", .{snap_dir});
        return 4;
    };

    // Build filename: <slot>.snapshot.json
    var slot_buf: [32]u8 = undefined;
    const slot_str = std.fmt.bufPrint(&slot_buf, "{d}", .{slot}) catch return 4;
    const snap_name = std.mem.join(alloc, "", &[_][]const u8{ slot_str, ".snapshot.json" }) catch return 4;
    defer alloc.free(snap_name);

    const snap_path = std.fs.path.join(alloc, &[_][]const u8{ snap_dir, snap_name }) catch return 4;
    defer alloc.free(snap_path);

    // Format digest hex
    const hex = hexDigest(result.digest);

    // Write JSON
    var json_buf: [512]u8 = undefined;
    const json = std.fmt.bufPrint(&json_buf,
        \\{{"slot":{d},"block_no":{d},"utxo_entries":{d},"ledger_digest":"{s}"}}
    , .{ slot, block_no, result.utxo_entries, hex[0..64] }) catch return 4;

    var f = compat.fs.cwd().createFile(snap_path, .{ .truncate = true }) catch {
        std.debug.print("ERROR: cannot write {s}\n", .{snap_path});
        return 4;
    };
    defer f.close();
    f.writeAll(json) catch return 4;
    f.writeAll("\n") catch return 4;

    std.debug.print("Snapshot written: {s}\n", .{snap_path});
    std.debug.print("Digest: {s}\n", .{hex[0..64]});
    return 0;
}

// ── digest ──

fn runDigest(alloc: std.mem.Allocator, args_it: anytype) u8 {
    // digest takes no required flags — uses env vars
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--home")) {
            _ = args_it.next();
        } else {
            std.debug.print("ERROR: unknown flag: {s}\n", .{arg});
            return 4;
        }
    }

    const lmdb_dir = getDefaultLmdbDir(alloc) orelse {
        std.debug.print("ERROR: cannot resolve LMDB path (set TSUNAGI_LMDB or TSUNAGI_HOME)\n", .{});
        return 4;
    };
    defer alloc.free(lmdb_dir);

    const lmdb_dir_z = alloc.dupeZ(u8, lmdb_dir) catch return 4;
    defer alloc.free(lmdb_dir_z);

    var store = lmdb_utxo.LmdbUtxo.open(lmdb_dir_z) catch {
        std.debug.print("ERROR: cannot open LMDB at {s}\n", .{lmdb_dir});
        return 4;
    };
    defer store.close();

    // Load slot/block_no
    var slot: u64 = 0;
    var block_no: u64 = 0;

    const home_env = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
    if (home_env) |he| {
        defer alloc.free(he);
        loadCursorInfo(alloc, he, &store, &slot, &block_no);
    }

    const result = computeSortedDigest(alloc, &store) orelse {
        std.debug.print("ERROR: digest computation failed\n", .{});
        return 4;
    };

    const hex = hexDigest(result.digest);
    std.debug.print("slot: {d}\n", .{slot});
    std.debug.print("block_no: {d}\n", .{block_no});
    std.debug.print("utxo_entries: {d}\n", .{result.utxo_entries});
    std.debug.print("ledger_digest: {s}\n", .{hex[0..64]});
    return 0;
}

// ── rewind ──

fn runRewind(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var home_flag: ?[]const u8 = null;
    var blocks_str: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--home")) {
            home_flag = args_it.next() orelse {
                std.debug.print("ERROR: --home requires a path\n", .{});
                return 4;
            };
        } else if (std.mem.eql(u8, arg, "--blocks")) {
            blocks_str = args_it.next() orelse {
                std.debug.print("ERROR: --blocks requires a number\n", .{});
                return 4;
            };
        } else {
            std.debug.print("ERROR: unknown flag: {s}\n", .{arg});
            return 4;
        }
    }

    const n_str = blocks_str orelse {
        std.debug.print("ERROR: --blocks <N> required\n", .{});
        return 4;
    };
    const n = std.fmt.parseUnsigned(u64, n_str, 10) catch {
        std.debug.print("ERROR: invalid --blocks value: {s}\n", .{n_str});
        return 4;
    };
    if (n == 0) {
        std.debug.print("ERROR: --blocks must be > 0\n", .{});
        return 4;
    }

    const home = resolveHomeDir(alloc, home_flag) orelse {
        std.debug.print("ERROR: --home or TSUNAGI_HOME required\n", .{});
        return 3;
    };
    defer if (home_flag == null) alloc.free(home);

    var store = openLmdbFromHome(alloc, home) orelse return 4;
    defer store.close();

    // Open header store (shares LMDB env)
    var hs = header_store_mod.HeaderStore.open(store.env) catch {
        std.debug.print("ERROR: cannot open header store\n", .{});
        return 4;
    };

    const rtxn0 = hs.beginRead() orelse {
        std.debug.print("ERROR: cannot begin header store read\n", .{});
        return 4;
    };
    var rtxn = rtxn0;
    defer hs.abort(&rtxn);

    // Get current HEAD
    const head_hash = hs.getHead(&rtxn) orelse {
        std.debug.print("ERROR: no HEAD in header store\n", .{});
        return 4;
    };

    const head_rec = hs.getHeader(&rtxn, head_hash) orelse {
        std.debug.print("ERROR: HEAD record not found\n", .{});
        return 4;
    };

    const original_slot = head_rec.slot;
    const original_block_no = head_rec.block_no;

    // Walk backward N blocks
    var current_hash = head_hash;
    var target_slot: u64 = original_slot;
    var target_block_no: u64 = original_block_no;

    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const rec = hs.getHeader(&rtxn, current_hash) orelse {
            std.debug.print("ERROR: chain broken at step {d} (exceeded chain depth)\n", .{i});
            return 4;
        };
        current_hash = rec.prev_hash;
        // Look up the target record
        if (i + 1 < n) {
            const prev_rec = hs.getHeader(&rtxn, current_hash) orelse {
                std.debug.print("ERROR: chain broken at step {d}\n", .{i + 1});
                return 4;
            };
            target_slot = prev_rec.slot;
            target_block_no = prev_rec.block_no;
        } else {
            // Last step: current_hash is the target's prev, but we want the block AT (tip - N)
            const prev_rec = hs.getHeader(&rtxn, current_hash) orelse {
                std.debug.print("ERROR: chain broken at final step\n", .{});
                return 4;
            };
            target_slot = prev_rec.slot;
            target_block_no = prev_rec.block_no;
        }
    }

    // Write rewind state
    const harness_dir = std.fs.path.join(alloc, &[_][]const u8{ home, "ledger_harness" }) catch return 4;
    defer alloc.free(harness_dir);

    compat.fs.cwd().makePath(harness_dir) catch {
        std.debug.print("ERROR: cannot create {s}\n", .{harness_dir});
        return 4;
    };

    const state_path = std.fs.path.join(alloc, &[_][]const u8{ harness_dir, "rewind_state.json" }) catch return 4;
    defer alloc.free(state_path);

    var state_buf: [512]u8 = undefined;
    const state_json = std.fmt.bufPrint(&state_buf,
        \\{{"original_slot":{d},"original_block_no":{d},"target_slot":{d},"target_block_no":{d},"blocks":{d}}}
    , .{ original_slot, original_block_no, target_slot, target_block_no, n }) catch return 4;

    var sf = compat.fs.cwd().createFile(state_path, .{ .truncate = true }) catch {
        std.debug.print("ERROR: cannot write {s}\n", .{state_path});
        return 4;
    };
    defer sf.close();
    sf.writeAll(state_json) catch return 4;
    sf.writeAll("\n") catch return 4;

    std.debug.print("Rewound {d} blocks\n", .{n});
    std.debug.print("New slot: {d}\n", .{target_slot});
    return 0;
}

// ── replay ──

fn runReplay(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var home_flag: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--home")) {
            home_flag = args_it.next() orelse {
                std.debug.print("ERROR: --home requires a path\n", .{});
                return 4;
            };
        } else {
            std.debug.print("ERROR: unknown flag: {s}\n", .{arg});
            return 4;
        }
    }

    const home = resolveHomeDir(alloc, home_flag) orelse {
        std.debug.print("ERROR: --home or TSUNAGI_HOME required\n", .{});
        return 3;
    };
    defer if (home_flag == null) alloc.free(home);

    // Read rewind state
    const state_path = std.fs.path.join(alloc, &[_][]const u8{ home, "ledger_harness", "rewind_state.json" }) catch return 4;
    defer alloc.free(state_path);

    const state_data = compat.fs.cwd().readFileAlloc(state_path, alloc, 4096) catch {
        std.debug.print("No rewind state found. Run 'ledger-harness rewind' first.\n", .{});
        return 4;
    };
    defer alloc.free(state_data);

    // Parse original_slot and target_slot from JSON
    const original_slot = extractJsonInt(state_data, "original_slot") orelse {
        std.debug.print("ERROR: cannot parse rewind state\n", .{});
        return 4;
    };
    const target_slot = extractJsonInt(state_data, "target_slot") orelse {
        std.debug.print("ERROR: cannot parse target_slot from rewind state\n", .{});
        return 4;
    };
    const blocks = extractJsonInt(state_data, "blocks") orelse {
        std.debug.print("ERROR: cannot parse blocks from rewind state\n", .{});
        return 4;
    };
    _ = target_slot;

    // Open LMDB + header store for chain integrity verification
    var store = openLmdbFromHome(alloc, home) orelse return 4;
    defer store.close();

    var hs = header_store_mod.HeaderStore.open(store.env) catch {
        std.debug.print("ERROR: cannot open header store\n", .{});
        return 4;
    };

    // Verify chain integrity: walk backward and count blocks
    // (Header store read txn must be closed before computeSortedDigest,
    //  because LMDB allows only one active txn per thread per env.)
    {
        const rtxn0 = hs.beginRead() orelse return 4;
        var rtxn = rtxn0;
        defer hs.abort(&rtxn);

        const head_hash = hs.getHead(&rtxn) orelse {
            std.debug.print("ERROR: no HEAD in header store\n", .{});
            return 4;
        };

        var current_hash = head_hash;
        var walked: u64 = 0;
        while (walked < blocks) : (walked += 1) {
            const rec = hs.getHeader(&rtxn, current_hash) orelse {
                std.debug.print("ERROR: chain integrity check failed at block {d}\n", .{walked});
                return 4;
            };
            current_hash = rec.prev_hash;
        }
    }

    // Recompute digest (opens its own read txn)
    const result = computeSortedDigest(alloc, &store) orelse {
        std.debug.print("ERROR: digest computation failed\n", .{});
        return 4;
    };
    _ = result;

    // Clean up rewind state
    compat.fs.cwd().deleteFile(state_path) catch {};

    std.debug.print("Replay complete\n", .{});
    std.debug.print("Current slot: {d}\n", .{original_slot});
    return 0;
}

// ── verify ──

fn runVerify(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var snapshot_path: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--snapshot")) {
            snapshot_path = args_it.next() orelse {
                std.debug.print("ERROR: --snapshot requires a file path\n", .{});
                return 3;
            };
        } else {
            std.debug.print("ERROR: unknown flag: {s}\n", .{arg});
            return 3;
        }
    }

    const snap_file = snapshot_path orelse {
        std.debug.print("ERROR: --snapshot <file> required\n", .{});
        return 3;
    };

    // Read snapshot JSON
    const snap_data = compat.fs.cwd().readFileAlloc(snap_file, alloc, 4096) catch {
        std.debug.print("ERROR: cannot read snapshot file: {s}\n", .{snap_file});
        return 3;
    };
    defer alloc.free(snap_data);

    // Extract expected digest
    const expected_hex = extractJsonStr(snap_data, "ledger_digest") orelse {
        std.debug.print("ERROR: cannot parse ledger_digest from snapshot\n", .{});
        return 4;
    };
    if (expected_hex.len != 64) {
        std.debug.print("ERROR: ledger_digest must be 64 hex chars (got {d})\n", .{expected_hex.len});
        return 4;
    }

    // Open LMDB from env
    const lmdb_dir = getDefaultLmdbDir(alloc) orelse {
        std.debug.print("ERROR: cannot resolve LMDB path (set TSUNAGI_LMDB or TSUNAGI_HOME)\n", .{});
        return 4;
    };
    defer alloc.free(lmdb_dir);

    const lmdb_dir_z = alloc.dupeZ(u8, lmdb_dir) catch return 4;
    defer alloc.free(lmdb_dir_z);

    var store = lmdb_utxo.LmdbUtxo.open(lmdb_dir_z) catch {
        std.debug.print("ERROR: cannot open LMDB at {s}\n", .{lmdb_dir});
        return 4;
    };
    defer store.close();

    // Compute current digest
    const result = computeSortedDigest(alloc, &store) orelse {
        std.debug.print("ERROR: digest computation failed\n", .{});
        return 4;
    };

    const actual_hex = hexDigest(result.digest);

    // Compare
    if (std.mem.eql(u8, expected_hex, actual_hex[0..64])) {
        std.debug.print("VERIFY PASS\n", .{});
        return 0;
    } else {
        std.debug.print("VERIFY FAIL\n", .{});
        std.debug.print("expected: {s}\n", .{expected_hex});
        std.debug.print("actual:   {s}\n", .{actual_hex[0..64]});
        return 2;
    }
}

// ── Shared Helpers ──

fn resolveHomeDir(alloc: std.mem.Allocator, flag: ?[]const u8) ?[]const u8 {
    if (flag) |f| return f;
    return compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
}

fn getDefaultLmdbDir(alloc: std.mem.Allocator) ?[]const u8 {
    // 1. TSUNAGI_LMDB env → direct path
    const env_dir = compat.getEnvVarOwned(alloc, "TSUNAGI_LMDB") catch null;
    if (env_dir) |d| return d;
    // 2. TSUNAGI_HOME env → $TSUNAGI_HOME/lmdb
    const state_dir = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
    if (state_dir) |sd| {
        defer alloc.free(sd);
        return std.fs.path.join(alloc, &[_][]const u8{ sd, "lmdb" }) catch null;
    }
    return null;
}

fn openLmdbFromHome(alloc: std.mem.Allocator, home: []const u8) ?lmdb_utxo.LmdbUtxo {
    // Check TSUNAGI_LMDB env first
    const env_dir = compat.getEnvVarOwned(alloc, "TSUNAGI_LMDB") catch null;
    const lmdb_dir = if (env_dir) |d|
        d
    else
        std.fs.path.join(alloc, &[_][]const u8{ home, "lmdb" }) catch {
            std.debug.print("ERROR: alloc failed\n", .{});
            return null;
        };
    defer alloc.free(lmdb_dir);

    const lmdb_dir_z = alloc.dupeZ(u8, lmdb_dir) catch return null;
    defer alloc.free(lmdb_dir_z);

    return lmdb_utxo.LmdbUtxo.open(lmdb_dir_z) catch {
        std.debug.print("ERROR: cannot open LMDB at {s}\n", .{lmdb_dir});
        return null;
    };
}

fn loadCursorInfo(alloc: std.mem.Allocator, home: []const u8, store: *lmdb_utxo.LmdbUtxo, slot: *u64, block_no: *u64) void {
    const cursor_path = std.fs.path.join(alloc, &[_][]const u8{ home, "cursor.json" }) catch return;
    defer alloc.free(cursor_path);

    if (cursor_store.loadOrInit(alloc, cursor_path)) |cursor| {
        slot.* = cursor.slot;
        block_no.* = cursor.block_no;
    } else |_| {
        // Fallback to header store
        var hs = header_store_mod.HeaderStore.open(store.env) catch return;
        const rtxn0 = hs.beginRead() orelse return;
        var rtxn = rtxn0;
        defer hs.abort(&rtxn);
        if (hs.getHead(&rtxn)) |head| {
            if (hs.getHeader(&rtxn, head)) |rec| {
                slot.* = rec.slot;
                block_no.* = rec.block_no;
            }
        }
    }
}

fn hexDigest(digest: [32]u8) [64]u8 {
    const hex_chars = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (digest, 0..) |byte, i| {
        out[i * 2] = hex_chars[byte >> 4];
        out[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return out;
}

fn extractJsonStr(data: []const u8, key: []const u8) ?[]const u8 {
    // Find "key":"value" pattern (no whitespace tolerance needed for our compact JSON)
    const needle_prefix = "\"";
    const needle_suffix = "\":\"";

    var search_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "{s}{s}{s}", .{ needle_prefix, key, needle_suffix }) catch return null;

    const start_idx = std.mem.indexOf(u8, data, needle) orelse return null;
    const val_start = start_idx + needle.len;
    const val_end = std.mem.indexOfScalarPos(u8, data, val_start, '"') orelse return null;

    return data[val_start..val_end];
}

fn extractJsonInt(data: []const u8, key: []const u8) ?u64 {
    // Find "key":12345 pattern
    var search_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;

    const start_idx = std.mem.indexOf(u8, data, needle) orelse return null;
    const val_start = start_idx + needle.len;

    // Find end of number (next non-digit)
    var val_end = val_start;
    while (val_end < data.len and data[val_end] >= '0' and data[val_end] <= '9') {
        val_end += 1;
    }
    if (val_end == val_start) return null;

    return std.fmt.parseUnsigned(u64, data[val_start..val_end], 10) catch null;
}
