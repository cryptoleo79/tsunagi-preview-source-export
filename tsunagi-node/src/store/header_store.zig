const std = @import("std");
const lmdb_utxo = @import("lmdb_utxo.zig");
const c = lmdb_utxo.c;

pub const Txn = struct {
    txn: ?*c.MDB_txn,
    dbi: c.MDB_dbi,
};

pub const HeaderRec = struct {
    slot: u64,
    block_no: u64,
    height: u64,
    prev_hash: [32]u8,
};

const REC_SIZE: usize = 8 + 8 + 8 + 32; // 56 bytes

pub const HeaderStore = struct {
    env: ?*c.MDB_env,
    dbi: c.MDB_dbi,
    cbor_dbi: c.MDB_dbi,
    slot_dbi: c.MDB_dbi,
    has_cbor_db: bool,
    has_slot_db: bool,

    pub fn open(env: ?*c.MDB_env) !HeaderStore {
        var txn: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(env, null, 0, &txn) != 0) return error.HeaderStoreTxnFailed;

        var dbi: c.MDB_dbi = undefined;
        if (c.mdb_dbi_open(txn, "headers", c.MDB_CREATE, &dbi) != 0) {
            c.mdb_txn_abort(txn);
            return error.HeaderStoreDbiOpenFailed;
        }

        var cbor_dbi: c.MDB_dbi = undefined;
        var has_cbor = true;
        if (c.mdb_dbi_open(txn, "header_cbor", c.MDB_CREATE, &cbor_dbi) != 0) {
            std.debug.print("HEADER STORE: header_cbor db open failed (MDB_CREATE)\n", .{});
            has_cbor = false;
        }

        var slot_dbi: c.MDB_dbi = undefined;
        // Phase B'''': slot_dbi creation MANDATORY (D-3 fail-hard).
        // Silent fallback was footgun: sentinel writes would mark
        // migration "done" against absent slot_dbi, permanently
        // hiding /chain/header-by-slot lookups.
        if (c.mdb_dbi_open(txn, "slot_index", c.MDB_CREATE, &slot_dbi) != 0) {
            std.debug.print("HEADER STORE: slot_index db open failed (MDB_CREATE) — aborting\n", .{});
            c.mdb_txn_abort(txn);
            return error.HeaderStoreSlotIndexOpenFailed;
        }
        const has_slot = true;

        if (c.mdb_txn_commit(txn) != 0) return error.HeaderStoreCommitFailed;

        return .{
            .env = env,
            .dbi = dbi,
            .cbor_dbi = cbor_dbi,
            .slot_dbi = slot_dbi,
            .has_cbor_db = has_cbor,
            .has_slot_db = has_slot,
        };
    }

    /// Open for read-only access (no MDB_CREATE). Tolerates missing header_cbor/slot_index db.
    pub fn openReadOnly(env: ?*c.MDB_env) !HeaderStore {
        var txn: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(env, null, c.MDB_RDONLY, &txn) != 0) return error.HeaderStoreTxnFailed;

        var dbi: c.MDB_dbi = undefined;
        if (c.mdb_dbi_open(txn, "headers", 0, &dbi) != 0) {
            c.mdb_txn_abort(txn);
            return error.HeaderStoreDbiOpenFailed;
        }

        var cbor_dbi: c.MDB_dbi = undefined;
        var has_cbor = true;
        if (c.mdb_dbi_open(txn, "header_cbor", 0, &cbor_dbi) != 0) {
            has_cbor = false;
        }

        var slot_dbi: c.MDB_dbi = undefined;
        var has_slot = true;
        if (c.mdb_dbi_open(txn, "slot_index", 0, &slot_dbi) != 0) {
            has_slot = false;
        }

        if (c.mdb_txn_commit(txn) != 0) return error.HeaderStoreCommitFailed;

        return .{
            .env = env,
            .dbi = dbi,
            .cbor_dbi = cbor_dbi,
            .slot_dbi = slot_dbi,
            .has_cbor_db = has_cbor,
            .has_slot_db = has_slot,
        };
    }

    pub fn beginWrite(self: *HeaderStore) ?Txn {
        var txn: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.env, null, 0, &txn) != 0) return null;
        return Txn{ .txn = txn, .dbi = self.dbi };
    }

    pub fn beginRead(self: *HeaderStore) ?Txn {
        var txn: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.env, null, c.MDB_RDONLY, &txn) != 0) return null;
        return Txn{ .txn = txn, .dbi = self.dbi };
    }

    pub fn commit(_: *HeaderStore, t: *Txn) bool {
        return c.mdb_txn_commit(t.txn) == 0;
    }

    pub fn abort(_: *HeaderStore, t: *Txn) void {
        c.mdb_txn_abort(t.txn);
    }

    pub fn getHead(_: *HeaderStore, t: *Txn) ?[32]u8 {
        var key = c.MDB_val{ .mv_size = 4, .mv_data = @constCast(@ptrCast("HEAD")) };
        var val: c.MDB_val = undefined;
        if (c.mdb_get(t.txn, t.dbi, &key, &val) != 0) return null;
        if (val.mv_size != 32) return null;
        const ptr: [*]const u8 = @ptrCast(val.mv_data);
        var out: [32]u8 = undefined;
        @memcpy(&out, ptr[0..32]);
        return out;
    }

    pub fn setHead(_: *HeaderStore, t: *Txn, head: [32]u8) void {
        var key = c.MDB_val{ .mv_size = 4, .mv_data = @constCast(@ptrCast("HEAD")) };
        var head_copy = head;
        var val = c.MDB_val{ .mv_size = 32, .mv_data = &head_copy };
        _ = c.mdb_put(t.txn, t.dbi, &key, &val, 0);
    }

    pub fn getHeight(_: *HeaderStore, t: *Txn) u64 {
        var key = c.MDB_val{ .mv_size = 6, .mv_data = @constCast(@ptrCast("HEIGHT")) };
        var val: c.MDB_val = undefined;
        if (c.mdb_get(t.txn, t.dbi, &key, &val) != 0) return 0;
        if (val.mv_size != 8) return 0;
        const ptr: [*]const u8 = @ptrCast(val.mv_data);
        return std.mem.readInt(u64, ptr[0..8], .little);
    }

    pub fn setHeight(_: *HeaderStore, t: *Txn, h: u64) void {
        var key = c.MDB_val{ .mv_size = 6, .mv_data = @constCast(@ptrCast("HEIGHT")) };
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, h, .little);
        var val = c.MDB_val{ .mv_size = 8, .mv_data = &buf };
        _ = c.mdb_put(t.txn, t.dbi, &key, &val, 0);
    }

    pub fn putHeader(_: *HeaderStore, t: *Txn, header_hash: [32]u8, slot: u64, block_no: u64, height: u64, prev_hash: [32]u8) void {
        var key_buf = header_hash;
        var key = c.MDB_val{ .mv_size = 32, .mv_data = &key_buf };

        var val_buf: [REC_SIZE]u8 = undefined;
        std.mem.writeInt(u64, val_buf[0..8], slot, .little);
        std.mem.writeInt(u64, val_buf[8..16], block_no, .little);
        std.mem.writeInt(u64, val_buf[16..24], height, .little);
        @memcpy(val_buf[24..56], prev_hash[0..32]);

        var val = c.MDB_val{ .mv_size = REC_SIZE, .mv_data = &val_buf };
        _ = c.mdb_put(t.txn, t.dbi, &key, &val, 0);
    }

    pub fn getHeader(_: *HeaderStore, t: *Txn, header_hash: [32]u8) ?HeaderRec {
        var key_buf = header_hash;
        var key = c.MDB_val{ .mv_size = 32, .mv_data = &key_buf };

        var val: c.MDB_val = undefined;
        if (c.mdb_get(t.txn, t.dbi, &key, &val) != 0) return null;
        if (val.mv_size != REC_SIZE) return null;

        const ptr: [*]const u8 = @ptrCast(val.mv_data);
        var prev: [32]u8 = undefined;
        @memcpy(&prev, ptr[24..56]);

        return HeaderRec{
            .slot = std.mem.readInt(u64, ptr[0..8], .little),
            .block_no = std.mem.readInt(u64, ptr[8..16], .little),
            .height = std.mem.readInt(u64, ptr[16..24], .little),
            .prev_hash = prev,
        };
    }

    /// Hash-presence lookup. Returns true if a header record exists for
    /// the given hash. Used as a tertiary intersect backstop in ChainSync
    /// when the in-memory fragment cannot satisfy the relay's points.
    /// Single LMDB get keyed by 32-byte hash; bounded constant-time.
    pub fn containsHash(self: *HeaderStore, t: *Txn, header_hash: [32]u8) bool {
        return self.getHeader(t, header_hash) != null;
    }

    /// Archive raw header CBOR keyed by hash. No-op if header_cbor db unavailable.
    pub fn putHeaderCbor(self: *HeaderStore, t: *Txn, header_hash: [32]u8, header_cbor: []const u8) void {
        if (!self.has_cbor_db) return;
        var key_buf = header_hash;
        var key = c.MDB_val{ .mv_size = 32, .mv_data = &key_buf };
        var val = c.MDB_val{ .mv_size = header_cbor.len, .mv_data = @constCast(header_cbor.ptr) };
        const rc = c.mdb_put(t.txn, self.cbor_dbi, &key, &val, 0);
        if (rc != 0) {
            std.debug.print("HEADER STORE: putHeaderCbor failed rc={d} len={d}\n", .{ rc, header_cbor.len });
        }
    }

    /// Retrieve archived header CBOR by hash. Returns slice into LMDB mmap
    /// (valid only while the transaction is open). Returns null if not found
    /// or header_cbor db unavailable.
    pub fn getHeaderCbor(self: *HeaderStore, t: *Txn, header_hash: [32]u8) ?[]const u8 {
        if (!self.has_cbor_db) return null;
        var key_buf = header_hash;
        var key = c.MDB_val{ .mv_size = 32, .mv_data = &key_buf };
        var val: c.MDB_val = undefined;
        if (c.mdb_get(t.txn, self.cbor_dbi, &key, &val) != 0) return null;
        if (val.mv_size == 0) return null;
        const ptr: [*]const u8 = @ptrCast(val.mv_data);
        return ptr[0..val.mv_size];
    }

    /// Store slot → header_hash mapping. Key is slot as big-endian u64.
    /// Phase B'''': slot_dbi is mandatory at write open (open() fails hard
    /// if slot_index DBI cannot be created). No has_slot_db guard.
    pub fn putSlotIndex(self: *HeaderStore, t: *Txn, slot: u64, header_hash: [32]u8) void {
        var key_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &key_buf, slot, .big);
        var key = c.MDB_val{ .mv_size = 8, .mv_data = &key_buf };
        var hash_buf = header_hash;
        var val = c.MDB_val{ .mv_size = 32, .mv_data = &hash_buf };
        _ = c.mdb_put(t.txn, self.slot_dbi, &key, &val, 0);
    }

    /// Lookup header hash by slot. Returns null if not found.
    pub fn getSlotIndex(self: *HeaderStore, t: *Txn, slot: u64) ?[32]u8 {
        if (!self.has_slot_db) return null;
        var key_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &key_buf, slot, .big);
        var key = c.MDB_val{ .mv_size = 8, .mv_data = &key_buf };
        var val: c.MDB_val = undefined;
        if (c.mdb_get(t.txn, self.slot_dbi, &key, &val) != 0) return null;
        if (val.mv_size != 32) return null;
        var out: [32]u8 = undefined;
        @memcpy(&out, @as([*]const u8, @ptrCast(val.mv_data))[0..32]);
        return out;
    }

    /// Delete slot index entry. Used during rollback to maintain canonical view.
    /// Phase B'''': slot_dbi mandatory at write open — no has_slot_db guard.
    pub fn deleteSlotIndex(self: *HeaderStore, t: *Txn, slot: u64) void {
        var key_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &key_buf, slot, .big);
        var key = c.MDB_val{ .mv_size = 8, .mv_data = &key_buf };
        _ = c.mdb_del(t.txn, self.slot_dbi, &key, null);
    }

    // ─── Phase B'''': sentinel for slot_index migration ───────────────
    //
    // Sentinel encodes "slot_index has been rebuilt in delivered-domain".
    // Key: 17 ASCII bytes "SLOT_INDEX_SCHEMA" (no null terminator) in
    //      the `headers` DBI (re-used to avoid a 4th DBI).
    // Value: 5 bytes = [0x01 (presence byte), LE u32 schema_version=1].
    //
    // Absence (or any malformed value) means "not yet migrated" and
    // triggers rebuildSlotIndexIfNeeded on next boot. Persistence after
    // rollback is intentional: when the post-fix binary boots against
    // a previously-rolled-back env, the sentinel is present and we
    // SHORT-CIRCUIT — the operator runs the separable reset utility
    // first (see src/tools/slot_index_reset.zig + operator runbook).

    const SLOT_SENTINEL_KEY: []const u8 = "SLOT_INDEX_SCHEMA";

    pub fn slotIndexSentinelGet(self: *HeaderStore, t: *Txn) bool {
        var key_buf: [17]u8 = undefined;
        @memcpy(key_buf[0..17], SLOT_SENTINEL_KEY);
        var key = c.MDB_val{ .mv_size = 17, .mv_data = &key_buf };
        var val: c.MDB_val = undefined;
        if (c.mdb_get(t.txn, self.dbi, &key, &val) != 0) return false;
        if (val.mv_size != 5) return false;
        const ptr: [*]const u8 = @ptrCast(val.mv_data);
        if (ptr[0] != 0x01) return false;
        const schema = std.mem.readInt(u32, ptr[1..5], .little);
        return schema == 1;
    }

    pub fn slotIndexSentinelSet(self: *HeaderStore, t: *Txn) !void {
        var key_buf: [17]u8 = undefined;
        @memcpy(key_buf[0..17], SLOT_SENTINEL_KEY);
        var key = c.MDB_val{ .mv_size = 17, .mv_data = &key_buf };
        var val_buf: [5]u8 = .{ 0x01, 0x01, 0x00, 0x00, 0x00 };
        var val = c.MDB_val{ .mv_size = 5, .mv_data = &val_buf };
        if (c.mdb_put(t.txn, self.dbi, &key, &val, 0) != 0) {
            return error.SentinelWriteFailed;
        }
    }

    pub fn slotIndexSentinelDelete(self: *HeaderStore, t: *Txn) !void {
        var key_buf: [17]u8 = undefined;
        @memcpy(key_buf[0..17], SLOT_SENTINEL_KEY);
        var key = c.MDB_val{ .mv_size = 17, .mv_data = &key_buf };
        const rc = c.mdb_del(t.txn, self.dbi, &key, null);
        if (rc != 0 and rc != c.MDB_NOTFOUND) return error.SentinelDeleteFailed;
    }

    // ─── Phase B'''': cursor helpers for headers DBI walking ──────────

    pub const HeaderCursor = struct {
        cur: ?*c.MDB_cursor,
        first: bool,
    };

    pub fn headersDbiCursorOpen(self: *HeaderStore, t: *Txn) !HeaderCursor {
        var cur: ?*c.MDB_cursor = null;
        if (c.mdb_cursor_open(t.txn, self.dbi, &cur) != 0) {
            return error.CursorOpenFailed;
        }
        return .{ .cur = cur, .first = true };
    }

    pub fn headersDbiCursorClose(_: *HeaderStore, hc: *HeaderCursor) void {
        if (hc.cur) |cur| {
            c.mdb_cursor_close(cur);
            hc.cur = null;
        }
    }

    /// Advance cursor. Returns true if a record was retrieved.
    /// On true: out_hash holds the 32-byte key (only when the key is
    /// exactly 32 bytes — otherwise zero), and out_rec holds the parsed
    /// HeaderRec. mv_size==32 filter is enforced via out_rec_valid.
    /// Callers should check key mv_size externally if filtering needed.
    pub fn headersDbiCursorNext(
        _: *HeaderStore,
        hc: *HeaderCursor,
        out_hash: *[32]u8,
        out_rec: *HeaderRec,
        out_key_size: *usize,
    ) bool {
        const cur = hc.cur orelse return false;
        var key: c.MDB_val = undefined;
        var val: c.MDB_val = undefined;
        const op: c.MDB_cursor_op = if (hc.first) c.MDB_FIRST else c.MDB_NEXT;
        const rc = c.mdb_cursor_get(cur, &key, &val, op);
        hc.first = false;
        if (rc != 0) return false;
        out_key_size.* = key.mv_size;
        if (key.mv_size == 32) {
            const kptr: [*]const u8 = @ptrCast(key.mv_data);
            @memcpy(out_hash[0..32], kptr[0..32]);
        } else {
            @memset(out_hash[0..32], 0);
        }
        if (val.mv_size == REC_SIZE) {
            const vptr: [*]const u8 = @ptrCast(val.mv_data);
            out_rec.slot = std.mem.readInt(u64, vptr[0..8], .little);
            out_rec.block_no = std.mem.readInt(u64, vptr[8..16], .little);
            out_rec.height = std.mem.readInt(u64, vptr[16..24], .little);
            @memcpy(out_rec.prev_hash[0..32], vptr[24..56]);
        } else {
            out_rec.* = .{
                .slot = 0,
                .block_no = 0,
                .height = 0,
                .prev_hash = std.mem.zeroes([32]u8),
            };
        }
        return true;
    }

    // ─── Phase B'''': idempotent slot_index rebuild ───────────────────
    //
    // Migrates the on-disk slot_index from peer-tip-domain (legacy)
    // to delivered-domain (Phase B'''' coherent). Idempotent — guarded
    // by SLOT_INDEX_SCHEMA sentinel.
    //
    // Algorithm:
    //   1. Read-txn: if sentinel present → return (no-op).
    //   2. Write-txn:
    //      a. mdb_drop(slot_dbi, 0) — empties slot_index (DBI retained).
    //         Cleans residual entries from forward-after-rollback.
    //      b. Cursor-walk `headers` DBI; for each 32-byte key:
    //         - Look up header_cbor by hash.
    //         - If cbor present: parseHeaderSlotAndBlockNo, write
    //           slot_index[delivered.slot] = hash.
    //         - If cbor absent: fall back to rec.slot, increment
    //           legacy_no_cbor counter (HeaderRecs written before the
    //           cbor archive was introduced lack header_cbor entries).
    //         - If cbor present but parse fails: increment corrupt_cbor.
    //      c. slotIndexSentinelSet — mark migrated.
    //      d. Commit.
    //
    // The follower.zig parseHeaderSlotAndBlockNo helper is passed in
    // via parse_fn (avoids circular import header_store → follower).
    pub const ParsedHeaderFields = struct { slot: u64, block_no: u64 };
    pub const ParseHeaderFn = *const fn (header_cbor: []const u8) ?ParsedHeaderFields;

    pub fn rebuildSlotIndexIfNeeded(
        self: *HeaderStore,
        parse_fn: ParseHeaderFn,
    ) !void {
        // Fast path: sentinel present.
        {
            var rtxn = self.beginRead() orelse return error.RebuildBeginReadFailed;
            defer self.abort(&rtxn);
            if (self.slotIndexSentinelGet(&rtxn)) {
                return;
            }
        }

        // Slow path: walk + rebuild.
        var wtxn = self.beginWrite() orelse return error.RebuildBeginWriteFailed;
        // explicit drop (retain DBI), cleans residual entries.
        if (c.mdb_drop(wtxn.txn, self.slot_dbi, 0) != 0) {
            self.abort(&wtxn);
            return error.RebuildDropFailed;
        }

        var total_indexed: u64 = 0;
        var legacy_no_cbor_count: u64 = 0;
        var corrupt_cbor_count: u64 = 0;

        var hc = self.headersDbiCursorOpen(&wtxn) catch |err| {
            self.abort(&wtxn);
            return err;
        };
        defer self.headersDbiCursorClose(&hc);

        var key_hash: [32]u8 = undefined;
        var rec: HeaderRec = undefined;
        var key_size: usize = 0;
        while (self.headersDbiCursorNext(&hc, &key_hash, &rec, &key_size)) {
            // Filter to 32-byte hash keys only (skips HEAD/HEIGHT/SLOT_INDEX_SCHEMA).
            if (key_size != 32) continue;
            // Lookup cbor by hash to recover delivered (slot, block_no).
            var delivered_slot: u64 = rec.slot;
            var used_fallback = true;
            if (self.has_cbor_db) {
                var ckey_buf = key_hash;
                var ckey = c.MDB_val{ .mv_size = 32, .mv_data = &ckey_buf };
                var cval: c.MDB_val = undefined;
                if (c.mdb_get(wtxn.txn, self.cbor_dbi, &ckey, &cval) == 0 and cval.mv_size > 0) {
                    const cptr: [*]const u8 = @ptrCast(cval.mv_data);
                    const cbor_slice = cptr[0..cval.mv_size];
                    if (parse_fn(cbor_slice)) |fields| {
                        delivered_slot = fields.slot;
                        used_fallback = false;
                    } else {
                        corrupt_cbor_count += 1;
                    }
                } else {
                    legacy_no_cbor_count += 1;
                }
            } else {
                legacy_no_cbor_count += 1;
            }
            if (used_fallback) {
                // Fallback (no cbor or parse failure): we used rec.slot.
                // legacy_no_cbor_count or corrupt_cbor_count already
                // incremented; nothing else to do here. Variable retained
                // for future telemetry expansion (e.g. per-fallback log).
            }

            self.putSlotIndex(&wtxn, delivered_slot, key_hash);
            total_indexed += 1;
        }

        self.slotIndexSentinelSet(&wtxn) catch {
            self.abort(&wtxn);
            return error.RebuildSentinelFailed;
        };

        if (!self.commit(&wtxn)) {
            return error.RebuildCommitFailed;
        }

        std.debug.print(
            "SLOT_INDEX_REBUILD: total_indexed={d} legacy_no_cbor={d} corrupt_cbor={d}\n",
            .{ total_indexed, legacy_no_cbor_count, corrupt_cbor_count },
        );
    }
};
