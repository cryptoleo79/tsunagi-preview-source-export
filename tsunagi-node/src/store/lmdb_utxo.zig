const std = @import("std");
const compat = @import("compat");
const utxo_mod = @import("../net/ledger/utxo.zig");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

pub const c = @cImport({
    @cInclude("lmdb.h");
});

const DEFAULT_MAP_GB: u64 = 256;

pub var g_map_size_bytes: usize = DEFAULT_MAP_GB * 1024 * 1024 * 1024;
pub var g_map_gb_effective: u64 = DEFAULT_MAP_GB;
pub var g_map_gb_raw_parse_ok: u64 = 1; // 1 = ok (default used), 0 = env parse failed

fn resolveMapSize() usize {
    const raw = compat.getEnvVarOwned(std.heap.page_allocator, "TSUNAGI_LMDB_MAP_GB") catch {
        const default_bytes: u64 = DEFAULT_MAP_GB * 1024 * 1024 * 1024;
        g_map_gb_effective = DEFAULT_MAP_GB;
        g_map_gb_raw_parse_ok = 1;
        std.debug.print("LMDB MAP: raw='(unset)' parsed_ok=1 gb={d} bytes={d}\n", .{ DEFAULT_MAP_GB, default_bytes });
        return @intCast(default_bytes);
    };
    defer std.heap.page_allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const gb = std.fmt.parseUnsigned(u64, trimmed, 10) catch {
        const default_bytes: u64 = DEFAULT_MAP_GB * 1024 * 1024 * 1024;
        g_map_gb_effective = DEFAULT_MAP_GB;
        g_map_gb_raw_parse_ok = 0;
        std.debug.print("LMDB MAP: invalid TSUNAGI_LMDB_MAP_GB='{s}' -> default {d}GB\n", .{ raw, DEFAULT_MAP_GB });
        std.debug.print("LMDB MAP: raw='{s}' parsed_ok=0 gb={d} bytes={d}\n", .{ raw, DEFAULT_MAP_GB, default_bytes });
        return @intCast(default_bytes);
    };
    const clamped = @max(1, @min(1024, gb));
    // Use u128 to avoid overflow on multiplication
    const bytes_u128: u128 = @as(u128, clamped) * 1024 * 1024 * 1024;
    const bytes: u64 = if (bytes_u128 > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(bytes_u128);
    g_map_gb_effective = clamped;
    g_map_gb_raw_parse_ok = 1;
    std.debug.print("LMDB MAP: raw='{s}' parsed_ok=1 gb={d} bytes={d}\n", .{ raw, clamped, bytes });
    return @intCast(bytes);
}

pub const Txn = struct {
    txn: ?*c.MDB_txn,
    dbi: c.MDB_dbi,
};

pub const LmdbUtxo = struct {
    env: ?*c.MDB_env,
    dbi: c.MDB_dbi,

    pub fn open(path: [:0]const u8) !LmdbUtxo {
        var env: ?*c.MDB_env = null;

        if (c.mdb_env_create(&env) != 0) return error.LmdbCreateFailed;
        g_map_size_bytes = resolveMapSize();
        if (c.mdb_env_set_mapsize(env, g_map_size_bytes) != 0) return error.LmdbMapSizeFailed;
        if (c.mdb_env_set_maxdbs(env, 4) != 0) return error.LmdbMaxDbsFailed;

        if (c.mdb_env_open(env, path.ptr, c.MDB_NORDAHEAD, 0o644) != 0) {
            return error.LmdbOpenFailed;
        }

        var txn: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(env, null, 0, &txn) != 0) return error.LmdbTxnBeginFailed;

        var dbi: c.MDB_dbi = undefined;
        if (c.mdb_dbi_open(txn, null, 0, &dbi) != 0) {
            c.mdb_txn_abort(txn);
            return error.LmdbDbiOpenFailed;
        }

        if (c.mdb_txn_commit(txn) != 0) return error.LmdbCommitFailed;

        return .{
            .env = env,
            .dbi = dbi,
        };
    }

    pub fn close(self: *LmdbUtxo) void {
        c.mdb_dbi_close(self.env, self.dbi);
        c.mdb_env_close(self.env);
    }

    fn encodeKey(tx_hash: [32]u8, index: u32, buf: *[36]u8) void {
        std.mem.copyForwards(u8, buf[0..32], tx_hash[0..]);
        std.mem.writeInt(u32, buf[32..36], index, .little);
    }

    fn encodeTxOut(alloc: std.mem.Allocator, out: utxo_mod.TxOut) ![]u8 {
        // Value format: [u64 lovelace LE][u32 addr_len LE][addr bytes...]
        const addr_len: u32 = @intCast(out.address.len);
        const total = 8 + 4 + out.address.len;
        const buf = try alloc.alloc(u8, total);
        std.mem.writeInt(u64, buf[0..8], out.lovelace, .little);
        std.mem.writeInt(u32, buf[8..12], addr_len, .little);
        if (out.address.len > 0) {
            std.mem.copyForwards(u8, buf[12..], out.address);
        }
        return buf;
    }

    pub const DecodedTxOut = struct {
        lovelace: u64,
        address: []u8,
    };

    pub fn decodeTxOutValue(self: *LmdbUtxo, alloc: std.mem.Allocator, bytes: []const u8) ?DecodedTxOut {
        _ = self;
        if (bytes.len < 12) return null;
        const lovelace = std.mem.readInt(u64, bytes[0..8], .little);
        const addr_len = std.mem.readInt(u32, bytes[8..12], .little);
        if (bytes.len < 12 + addr_len) return null;
        const address = alloc.dupe(u8, bytes[12 .. 12 + addr_len]) catch return null;
        return DecodedTxOut{ .lovelace = lovelace, .address = address };
    }

    // --- Txn API (batch writes per block) ---

    pub fn beginWrite(self: *LmdbUtxo) ?Txn {
        var txn: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.env, null, 0, &txn) != 0) return null;
        return Txn{ .txn = txn, .dbi = self.dbi };
    }

    pub fn commit(_: *LmdbUtxo, t: *Txn) bool {
        return c.mdb_txn_commit(t.txn) == 0;
    }

    pub fn abort(_: *LmdbUtxo, t: *Txn) void {
        c.mdb_txn_abort(t.txn);
    }

    pub fn putTxn(self: *LmdbUtxo, alloc: std.mem.Allocator, t: *Txn, key_hash: [32]u8, index: u32, out: utxo_mod.TxOut) void {
        _ = self;
        var key_buf: [36]u8 = undefined;
        encodeKey(key_hash, index, &key_buf);

        var key = c.MDB_val{
            .mv_size = 36,
            .mv_data = &key_buf,
        };

        const val_buf = encodeTxOut(alloc, out) catch return;
        defer alloc.free(val_buf);

        var val = c.MDB_val{
            .mv_size = val_buf.len,
            .mv_data = @constCast(val_buf.ptr),
        };

        _ = c.mdb_put(t.txn, t.dbi, &key, &val, 0);
    }

    pub fn delTxn(self: *LmdbUtxo, t: *Txn, key_hash: [32]u8, index: u32) void {
        _ = self;
        var key_buf: [36]u8 = undefined;
        encodeKey(key_hash, index, &key_buf);

        var key = c.MDB_val{
            .mv_size = 36,
            .mv_data = &key_buf,
        };

        _ = c.mdb_del(t.txn, t.dbi, &key, null);
    }

    // --- Read API ---

    pub fn beginRead(self: *LmdbUtxo) ?Txn {
        var txn: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.env, null, c.MDB_RDONLY, &txn) != 0) return null;
        return Txn{ .txn = txn, .dbi = self.dbi };
    }

    pub fn getTxn(self: *LmdbUtxo, t: *Txn, tx_hash: [32]u8, index: u32) ?[]u8 {
        _ = self;
        var key_buf: [36]u8 = undefined;
        encodeKey(tx_hash, index, &key_buf);

        var key = c.MDB_val{
            .mv_size = 36,
            .mv_data = &key_buf,
        };

        var val: c.MDB_val = undefined;
        const rc = c.mdb_get(t.txn, t.dbi, &key, &val);
        if (rc != 0) return null;

        const ptr: [*]u8 = @ptrCast(val.mv_data);
        return ptr[0..val.mv_size];
    }

    // --- Raw put API (for snapshot import) ---

    pub fn putRawTxn(self: *LmdbUtxo, t: *Txn, key36: *const [36]u8, val: []const u8) void {
        _ = self;
        var key = c.MDB_val{ .mv_size = 36, .mv_data = @constCast(key36) };
        var v = c.MDB_val{ .mv_size = val.len, .mv_data = @constCast(val.ptr) };
        _ = c.mdb_put(t.txn, t.dbi, &key, &v, 0);
    }

    // --- Cursor API (for snapshot export) ---

    pub const CursorIter = struct {
        cur: ?*c.MDB_cursor,
        first: bool = true,
    };

    pub fn cursorOpen(self: *LmdbUtxo, t: *Txn) ?CursorIter {
        var cur: ?*c.MDB_cursor = null;
        if (c.mdb_cursor_open(t.txn, self.dbi, &cur) != 0) return null;
        return .{ .cur = cur, .first = true };
    }

    pub fn cursorClose(_: *LmdbUtxo, it: *CursorIter) void {
        if (it.cur) |cur| c.mdb_cursor_close(cur);
    }

    pub fn cursorNext(_: *LmdbUtxo, it: *CursorIter, key: *c.MDB_val, val: *c.MDB_val) bool {
        const op: c_uint = if (it.first) c.MDB_FIRST else c.MDB_NEXT;
        it.first = false;
        return c.mdb_cursor_get(it.cur, key, val, op) == 0;
    }

    // --- Canonical state digest ---

    pub fn computeStateDigest(self: *LmdbUtxo) ?[32]u8 {
        var txn = self.beginRead() orelse return null;
        defer c.mdb_txn_abort(txn.txn);

        var it = self.cursorOpen(&txn) orelse return null;
        defer self.cursorClose(&it);

        var h = Blake2b256.init(.{});
        var key: c.MDB_val = undefined;
        var val: c.MDB_val = undefined;

        while (self.cursorNext(&it, &key, &val)) {
            const kp: [*]const u8 = @ptrCast(key.mv_data);
            h.update(kp[0..key.mv_size]);
            const vp: [*]const u8 = @ptrCast(val.mv_data);
            h.update(vp[0..val.mv_size]);
        }

        var digest: [32]u8 = undefined;
        h.final(&digest);
        return digest;
    }
};
