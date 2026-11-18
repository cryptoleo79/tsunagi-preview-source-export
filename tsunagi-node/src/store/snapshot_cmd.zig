const std = @import("std");
const compat = @import("compat");
const tsf = @import("tsf.zig");
const lmdb_utxo = @import("lmdb_utxo.zig");
const header_store_mod = @import("header_store.zig");
const snapshot_sign = @import("snapshot_sign.zig");
const cursor_store = @import("../net/ledger/cursor.zig");

fn defaultLmdbDir(alloc: std.mem.Allocator) ![]u8 {
    const env = compat.getEnvVarOwned(alloc, "TSUNAGI_LMDB") catch null;
    if (env) |d| return d;
    const home = try compat.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(home);
    return try std.fs.path.join(alloc, &[_][]const u8{ home, "tsunagi-home-mainnet", "lmdb" });
}

fn defaultStateDir(alloc: std.mem.Allocator) ![]u8 {
    const env = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
    if (env) |d| return d;
    const home = try compat.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(home);
    return try std.fs.path.join(alloc, &[_][]const u8{ home, "tsunagi-home-mainnet" });
}

fn detectNetworkMagic(state_dir: []const u8) u32 {
    if (std.mem.indexOf(u8, state_dir, "mainnet") != null) return 764_824_073;
    if (std.mem.indexOf(u8, state_dir, "preprod") != null) return 1;
    return 2; // preview default
}

fn hexToDigest32(hex: []const u8, out: *[32]u8) !void {
    if (hex.len != 64) return error.InvalidDigest;
    _ = try std.fmt.hexToBytes(out, hex);
}

// Hashing writer wrapper — writes to inner writer while updating blake2b hash
fn HashWriter(comptime W: type) type {
    return struct {
        inner: W,
        h: *std.crypto.hash.blake2.Blake2b256,

        const Self = @This();

        pub fn writeAll(self: Self, bytes: []const u8) !void {
            self.h.update(bytes);
            try self.inner.writeAll(bytes);
        }
    };
}

pub fn printAnchor(hdr: tsf.Header) void {
    std.debug.print("  network: {s} (magic={d})\n", .{ tsf.networkName(hdr.network_magic), hdr.network_magic });
    std.debug.print("  slot:    {d}\n", .{hdr.slot});
    std.debug.print("  block:   {d}\n", .{hdr.block_no});
    std.debug.print("  tip:     {x}\n", .{&hdr.tip_hash});
    std.debug.print("  header_head:   {x}\n", .{&hdr.header_head});
    std.debug.print("  header_height: {d}\n", .{hdr.header_height});
}

pub fn exportSnapshot(alloc: std.mem.Allocator, out_path: []const u8, lmdb_dir_opt: ?[]const u8, signing_key_opt: ?[]const u8) !void {
    const lmdb_dir = if (lmdb_dir_opt) |p| try alloc.dupe(u8, p) else try defaultLmdbDir(alloc);
    defer alloc.free(lmdb_dir);

    const lmdb_dir_z = try alloc.dupeZ(u8, lmdb_dir);
    defer alloc.free(lmdb_dir_z);

    var store = try lmdb_utxo.LmdbUtxo.open(lmdb_dir_z);
    defer store.close();

    // Load anchor metadata from cursor.json
    const state_dir = try defaultStateDir(alloc);
    defer alloc.free(state_dir);

    const cursor_path = try std.fs.path.join(alloc, &[_][]const u8{ state_dir, "cursor.json" });
    defer alloc.free(cursor_path);

    const cursor = cursor_store.loadOrInit(alloc, cursor_path) catch blk: {
        std.debug.print("snapshot-export: warning: could not read cursor.json, using zeros\n", .{});
        break :blk std.mem.zeroes(cursor_store.Cursor);
    };

    const network_magic = detectNetworkMagic(state_dir);
    var tip_hash: [32]u8 = std.mem.zeroes([32]u8);
    hexToDigest32(&cursor.tip_hash_hex, &tip_hash) catch {
        std.debug.print("snapshot-export: warning: invalid tip_hash_hex in cursor, using zeros\n", .{});
    };

    // Read header authority from LMDB header store
    var header_head: [32]u8 = std.mem.zeroes([32]u8);
    var header_height: u64 = 0;
    {
        var hs = header_store_mod.HeaderStore.open(store.env) catch |err| blk: {
            std.debug.print("snapshot-export: warning: could not open header store: {s}\n", .{@errorName(err)});
            break :blk null;
        };
        if (hs) |*hst| {
            if (hst.beginRead()) |rtxn0| {
                var rtxn = rtxn0;
                defer hst.abort(&rtxn);
                if (hst.getHead(&rtxn)) |head| {
                    header_head = head;
                }
                header_height = hst.getHeight(&rtxn);
            }
        }
    }

    std.debug.print("snapshot-export: anchor metadata\n", .{});
    std.debug.print("  network_magic={d} slot={d} block_no={d}\n", .{ network_magic, cursor.slot, cursor.block_no });
    std.debug.print("  tip_hash={x}\n", .{&tip_hash});
    std.debug.print("snapshot-export: header authority anchor head={x} height={d}\n", .{
        header_head[0..4],
        header_height,
    });

    var out_f = try compat.fs.cwd().createFile(out_path, .{ .truncate = true });
    defer out_f.close();

    var h = std.crypto.hash.blake2.Blake2b256.init(.{});
    const w = out_f.deprecatedWriter();

    const hw = HashWriter(@TypeOf(w)){ .inner = w, .h = &h };

    try tsf.writeHeader(hw, network_magic, cursor.slot, cursor.block_no, &tip_hash, &header_head, header_height);

    const rtxn0 = store.beginRead() orelse return error.LmdbTxnBeginFailed;
    var rtxn = rtxn0;
    defer store.abort(&rtxn);

    var it = store.cursorOpen(&rtxn) orelse return error.LmdbCursorOpenFailed;
    defer store.cursorClose(&it);

    var k: lmdb_utxo.c.MDB_val = undefined;
    var v: lmdb_utxo.c.MDB_val = undefined;

    var count: usize = 0;

    while (store.cursorNext(&it, &k, &v)) {
        if (k.mv_size != 36) continue;
        var key36: [36]u8 = undefined;
        const kptr: [*]u8 = @ptrCast(k.mv_data);
        std.mem.copyForwards(u8, key36[0..], kptr[0..36]);

        const vptr: [*]u8 = @ptrCast(v.mv_data);
        const val_slice = vptr[0..v.mv_size];

        try tsf.writeRecord(hw, &key36, val_slice);

        count += 1;
        if ((count % 100000) == 0) {
            std.debug.print("snapshot-export: records={d}\n", .{count});
        }
    }

    // Finalize digest
    var digest: [32]u8 = undefined;
    h.final(&digest);

    // Footer (not hashed) — write directly to file
    try tsf.writeFooter(out_f.deprecatedWriter(), &digest);
    std.debug.print("snapshot-export: done records={d} out={s}\n", .{ count, out_path });
    std.debug.print("snapshot-export: digest={x}\n", .{&digest});

    // Sign if --signing-key was provided
    if (signing_key_opt) |key_path| {
        const sig_path = try std.fmt.allocPrint(alloc, "{s}.sig", .{out_path});
        defer alloc.free(sig_path);
        snapshot_sign.signDigest(alloc, digest, key_path, sig_path) catch |err| {
            std.debug.print("snapshot-export: signing failed: {s}\n", .{@errorName(err)});
            return err;
        };
    }
}

pub fn importSnapshot(
    alloc: std.mem.Allocator,
    in_path: []const u8,
    lmdb_dir_opt: ?[]const u8,
    verify_opt: ?[]const u8,
    strict: bool,
    pubkey_hex_opt: ?[]const u8,
    pubkey_file_opt: ?[]const u8,
    allow_unsigned: bool,
) !void {
    const lmdb_dir = if (lmdb_dir_opt) |p| try alloc.dupe(u8, p) else try defaultLmdbDir(alloc);
    defer alloc.free(lmdb_dir);

    const lmdb_dir_z = try alloc.dupeZ(u8, lmdb_dir);
    defer alloc.free(lmdb_dir_z);

    try compat.fs.cwd().makePath(lmdb_dir);

    var store = try lmdb_utxo.LmdbUtxo.open(lmdb_dir_z);
    defer store.close();

    var f = try compat.fs.cwd().openFile(in_path, .{});
    defer f.close();

    // Read whole file to verify digest
    const bytes = try f.readToEndAlloc(alloc, 2 * 1024 * 1024 * 1024); // 2GB cap
    defer alloc.free(bytes);

    if (bytes.len < @sizeOf(tsf.Header) + @sizeOf(tsf.Footer)) return error.InvalidSnapshot;

    // Verify digest
    const footer_off = bytes.len - @sizeOf(tsf.Footer);
    const payload = bytes[0..footer_off];
    const footer_bytes = bytes[footer_off..];

    var expected: [32]u8 = undefined;
    std.mem.copyForwards(u8, expected[0..], footer_bytes[0..32]);

    var h = std.crypto.hash.blake2.Blake2b256.init(.{});
    h.update(payload);
    var actual: [32]u8 = undefined;
    h.final(&actual);

    if (!std.mem.eql(u8, expected[0..], actual[0..])) {
        std.debug.print("snapshot-import: digest mismatch!\n", .{});
        std.debug.print("expected={x}\n", .{&expected});
        std.debug.print("actual  ={x}\n", .{&actual});
        return error.InvalidDigest;
    }

    std.debug.print("snapshot-import: digest verified OK\n", .{});

    if (verify_opt) |hex| {
        var want: [32]u8 = undefined;
        try hexToDigest32(hex, &want);
        if (!std.mem.eql(u8, want[0..], actual[0..])) {
            std.debug.print("snapshot-import: user-supplied digest mismatch\n", .{});
            return error.InvalidDigest;
        }
        std.debug.print("snapshot-import: user-supplied digest matches\n", .{});
    }

    // Verify Ed25519 signature if .sig file exists
    {
        const sig_path = try std.fmt.allocPrint(alloc, "{s}.sig", .{in_path});
        defer alloc.free(sig_path);
        const sig_exists = blk: {
            var sf = compat.fs.cwd().openFile(sig_path, .{}) catch break :blk false;
            sf.close();
            break :blk true;
        };

        if (sig_exists) {
            // .sig file found — must verify
            const has_pubkey = (pubkey_hex_opt != null) or (pubkey_file_opt != null);
            if (!has_pubkey) {
                // Try default pubkey path
                const default_pub = snapshot_sign.defaultPubPathAlloc(alloc) catch null;
                defer if (default_pub) |dp| alloc.free(dp);
                const default_exists = if (default_pub) |dp| blk2: {
                    var pf = compat.fs.cwd().openFile(dp, .{}) catch break :blk2 false;
                    pf.close();
                    break :blk2 true;
                } else false;

                if (default_exists) {
                    const valid = try snapshot_sign.verifyDigest(alloc, actual, sig_path, null, default_pub);
                    if (valid) {
                        std.debug.print("snapshot-import: signature VALID (default pubkey)\n", .{});
                    } else {
                        std.debug.print("snapshot-import: signature INVALID\n", .{});
                        return error.SignatureInvalid;
                    }
                } else {
                    std.debug.print("snapshot-import: .sig file exists but no pubkey available (use --pubkey or --pubkey-file)\n", .{});
                    return error.PubkeyRequired;
                }
            } else {
                const valid = try snapshot_sign.verifyDigest(alloc, actual, sig_path, pubkey_hex_opt, pubkey_file_opt);
                if (valid) {
                    std.debug.print("snapshot-import: signature VALID\n", .{});
                } else {
                    std.debug.print("snapshot-import: signature INVALID\n", .{});
                    return error.SignatureInvalid;
                }
            }
        } else {
            // No .sig file
            if (!allow_unsigned) {
                std.debug.print("snapshot-import: no .sig file found; use --allow-unsigned to import without signature\n", .{});
                return error.SignatureRequired;
            }
            std.debug.print("snapshot-import: no .sig file, --allow-unsigned set, proceeding\n", .{});
        }
    }

    // Parse header
    var fb = compat.fixedBufferStream(payload);
    const r = fb.reader();
    const hdr = try tsf.readHeader(r);
    if (std.mem.eql(u8, hdr.magic[0..], "TSF1") or std.mem.eql(u8, hdr.magic[0..], "TSF0")) {
        std.debug.print("snapshot-import: unsupported snapshot version: {s}. Please re-export with v0.7.57+\n", .{hdr.magic});
        return error.UnsupportedSnapshotVersion;
    }
    if (!std.mem.eql(u8, hdr.magic[0..], tsf.MAGIC)) return error.InvalidSnapshot;
    if (hdr.version != tsf.VERSION) return error.InvalidSnapshot;

    std.debug.print("snapshot-import: anchor metadata\n", .{});
    printAnchor(hdr);

    // Bulk import with batched transactions
    const batch_size: usize = 50000;
    var records: usize = 0;
    var maybe_txn: ?lmdb_utxo.Txn = null;

    while (fb.pos < payload.len) {
        if (payload.len - fb.pos < 8) break;

        const key_len = tsf.readU32le(r) catch break;
        if (key_len != 36) {
            if (strict) return error.InvalidSnapshot;
            break;
        }

        var key36: [36]u8 = undefined;
        r.readNoEof(&key36) catch break;

        const val_len = tsf.readU32le(r) catch break;
        if (val_len > 16 * 1024 * 1024) {
            if (strict) return error.InvalidSnapshot;
            break;
        }

        if (fb.pos + val_len > payload.len) break;
        const val = payload[fb.pos .. fb.pos + val_len];
        fb.pos += val_len;

        // Open txn at start of each batch
        if (maybe_txn == null) {
            maybe_txn = store.beginWrite() orelse {
                std.debug.print("snapshot-import: beginWrite failed at record {d}\n", .{records});
                if (strict) return error.LmdbTxnBeginFailed;
                break;
            };
        }

        store.putRawTxn(&maybe_txn.?, &key36, val);
        records += 1;

        // Commit at end of batch
        if ((records % batch_size) == 0) {
            if (!store.commit(&maybe_txn.?)) {
                std.debug.print("snapshot-import: commit failed at record {d}\n", .{records});
                if (strict) return error.LmdbCommitFailed;
                break;
            }
            maybe_txn = null;
            std.debug.print("snapshot-import: committed batch records={d}\n", .{records});
        }
    }

    // Commit final partial batch
    if (maybe_txn) |*txn| {
        if (!store.commit(txn)) {
            std.debug.print("snapshot-import: final commit failed\n", .{});
            if (strict) return error.LmdbCommitFailed;
        }
    }

    std.debug.print("snapshot-import: done records={d} from={s}\n", .{ records, in_path });
}
