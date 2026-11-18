const std = @import("std");
const compat = @import("compat");
const lmdb_utxo = @import("../store/lmdb_utxo.zig");

/// Re-exports from store/lmdb_utxo.zig.
pub const LmdbUtxo = lmdb_utxo.LmdbUtxo;
pub const DecodedTxOut = lmdb_utxo.LmdbUtxo.DecodedTxOut;
pub const Txn = lmdb_utxo.Txn;

const c = lmdb_utxo.c;

/// Lookup a single UTxO by transaction hash and output index.
/// Opens a read-only LMDB transaction, performs the lookup, aborts the txn.
/// Returns null if the UTxO is not found or the store is unavailable.
/// Caller owns the returned DecodedTxOut.address allocation.
pub fn lookupByTxIn(store: *LmdbUtxo, alloc: std.mem.Allocator, tx_hash: [32]u8, index: u32) ?DecodedTxOut {
    var txn = store.beginRead() orelse return null;
    defer c.mdb_txn_abort(txn.txn);
    const raw = store.getTxn(&txn, tx_hash, index) orelse return null;
    return store.decodeTxOutValue(alloc, raw);
}

/// Count all UTxO entries via read-only cursor walk.
pub fn countUtxos(store: *LmdbUtxo) u64 {
    var txn = store.beginRead() orelse return 0;
    defer c.mdb_txn_abort(txn.txn);
    var it = store.cursorOpen(&txn) orelse return 0;
    defer store.cursorClose(&it);
    var count: u64 = 0;
    var key: c.MDB_val = undefined;
    var val: c.MDB_val = undefined;
    while (store.cursorNext(&it, &key, &val)) {
        count += 1;
    }
    return count;
}

/// Compute the canonical Blake2b-256 state digest over all UTxO entries.
/// Wraps LmdbUtxo.computeStateDigest.
pub fn utxoDigest(store: *LmdbUtxo) ?[32]u8 {
    return store.computeStateDigest();
}

/// Raw key-value entry from the UTxO store cursor.
pub const RawEntry = struct {
    /// 36 bytes: [32]tx_hash ++ [4]index (little-endian)
    key: [36]u8,
    /// Raw encoded value bytes. Valid only until next() or close().
    val_ptr: [*]const u8,
    val_len: usize,
};

/// Iterator over all UTxO entries. Holds a read-only LMDB transaction
/// and cursor. Must be closed with close() when done.
pub const UtxoIterator = struct {
    store: *LmdbUtxo,
    txn: Txn,
    iter: LmdbUtxo.CursorIter,

    /// Advance to the next entry. Returns null when exhausted.
    pub fn next(self: *UtxoIterator) ?RawEntry {
        var key: c.MDB_val = undefined;
        var val: c.MDB_val = undefined;
        if (!self.store.cursorNext(&self.iter, &key, &val)) return null;
        const kp: [*]const u8 = @ptrCast(key.mv_data);
        var entry: RawEntry = undefined;
        @memcpy(&entry.key, kp[0..36]);
        entry.val_ptr = @ptrCast(val.mv_data);
        entry.val_len = val.mv_size;
        return entry;
    }

    /// Release the cursor and read transaction.
    pub fn close(self: *UtxoIterator) void {
        self.store.cursorClose(&self.iter);
        c.mdb_txn_abort(self.txn.txn);
    }
};

/// Open an iterator over all UTxO entries (read-only).
/// Returns null if the store cannot be read.
/// Caller must call close() on the returned iterator when done.
pub fn iterateAll(store: *LmdbUtxo) ?UtxoIterator {
    var txn = store.beginRead() orelse return null;
    const it = store.cursorOpen(&txn) orelse {
        c.mdb_txn_abort(txn.txn);
        return null;
    };
    return UtxoIterator{ .store = store, .txn = txn, .iter = it };
}

// --- Tests ---

const test_lmdb_dir = "/tmp/tsunagi_test_utxo_extract";

fn openTestStore() !LmdbUtxo {
    compat.fs.cwd().deleteTree(test_lmdb_dir) catch {};
    try compat.fs.cwd().makePath(test_lmdb_dir);
    return LmdbUtxo.open(test_lmdb_dir);
}

test "lookupByTxIn returns null on empty store" {
    var store = try openTestStore();
    defer {
        store.close();
        compat.fs.cwd().deleteTree(test_lmdb_dir) catch {};
    }
    const tx_hash = [_]u8{0xaa} ** 32;
    const result = lookupByTxIn(&store, std.testing.allocator, tx_hash, 0);
    try std.testing.expect(result == null);
}

test "countUtxos returns 0 on empty store" {
    var store = try openTestStore();
    defer {
        store.close();
        compat.fs.cwd().deleteTree(test_lmdb_dir) catch {};
    }
    try std.testing.expectEqual(@as(u64, 0), countUtxos(&store));
}

test "utxoDigest returns hash on empty store" {
    var store = try openTestStore();
    defer {
        store.close();
        compat.fs.cwd().deleteTree(test_lmdb_dir) catch {};
    }
    const digest = utxoDigest(&store);
    try std.testing.expect(digest != null);
}

test "iterateAll returns empty iterator on empty store" {
    var store = try openTestStore();
    defer {
        store.close();
        compat.fs.cwd().deleteTree(test_lmdb_dir) catch {};
    }
    var it = iterateAll(&store) orelse {
        try std.testing.expect(false);
        return;
    };
    defer it.close();
    try std.testing.expect(it.next() == null);
}
