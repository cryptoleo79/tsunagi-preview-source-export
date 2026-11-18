const std = @import("std");
const compat = @import("compat");
const utxo_types = @import("../net/ledger/utxo.zig");
const lmdb_utxo = @import("../store/lmdb_utxo.zig");

/// Re-exports from net/ledger/utxo.zig (via utxo_types indirection).
pub const UTxO = utxo_types.UTxO;
pub const Undo = utxo_types.Undo;
pub const TxIn = utxo_types.TxIn;
pub const TxOut = utxo_types.TxOut;
pub const Produced = utxo_types.Produced;

/// Re-export from store/lmdb_utxo.zig.
pub const LmdbUtxo = lmdb_utxo.LmdbUtxo;

const c = lmdb_utxo.c;

/// Maximum undo stack depth before oldest entries are evicted.
/// Matches follower.zig line 41: const MAX_UNDO_DEPTH: usize = 200.
pub const MAX_UNDO_DEPTH: usize = 200;

/// Free `r.output.address` for every `.removed` entry in `undo`, deduplicating
/// by pointer so an aliased address slice (same `ptr+len` referenced from two
/// `.removed` entries, or from another already-freed undo) is never freed
/// twice. Stability hardening for shutdown unwinding — prevents glibc
/// `double free or corruption (fasttop)` if upstream paths ever produced
/// pointer aliasing in undo `.removed` entries.
///
/// The seen-set is keyed by the slice base pointer + len: identical
/// (ptr,len) pairs are considered the same slice. Zero-length slices are
/// always freed (no-op for most allocators) — the dedupe only short-circuits
/// repeated frees of the exact same nonzero-length allocation.
pub fn freeUndoAddressesDedup(
    undo: *Undo,
    alloc: std.mem.Allocator,
) void {
    const Seen = struct {
        ptr: [*]const u8,
        len: usize,
    };
    // Stack-allocated seen array: realistic per-undo .removed count is small
    // (transactions per block × inputs per tx). 1024 covers extreme blocks.
    // If exceeded, fall back to non-deduped free for the overflow (the
    // common case of pointer aliasing is N=2..few).
    var seen_buf: [1024]Seen = undefined;
    var seen_count: usize = 0;
    for (undo.entries.items) |e| {
        switch (e) {
            .removed => |r| {
                const a = r.output.address;
                if (a.len == 0) {
                    alloc.free(a);
                    continue;
                }
                const p: [*]const u8 = a.ptr;
                var dup = false;
                var i: usize = 0;
                while (i < seen_count) : (i += 1) {
                    if (seen_buf[i].ptr == p and seen_buf[i].len == a.len) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
                if (seen_count < seen_buf.len) {
                    seen_buf[seen_count] = .{ .ptr = p, .len = a.len };
                    seen_count += 1;
                }
                alloc.free(a);
            },
            .inserted => {},
        }
    }
}

pub const ApplyMode = enum {
    /// In-memory only. No LMDB. Returns error on failure.
    memory_only,
    /// LMDB is authoritative store. Falls back to memory_only on LMDB failure.
    lmdb_truth,
    /// LMDB mandatory. No fallback. Hard error on any failure.
    lmdb_native,
};

pub const ApplyResult = struct {
    consumed_count: usize,
    produced_count: usize,
    used_fallback: bool,
    undo_stack_depth: usize,
    coverage_found: usize = 0,
    coverage_total: usize = 0,
};

pub const ApplyError = error{
    LmdbStoreRequired,
    LmdbBeginWriteFailed,
    LmdbApplyFailed,
    LmdbCommitFailed,
    MemoryApplyFailed,
    UndoAppendFailed,
};

/// Apply a block's deltas to the UTxO state.
///
/// Mirrors follower.zig applyPreviewUtxo() (lines 1251–1451) and
/// applyPreviewUtxoFallback() (lines 1195–1249).
///
/// Mode determines behavior:
/// - memory_only: apply in-memory via UTxO.applyDelta
/// - lmdb_truth: apply via UTxO.applyDeltaLmdb, fallback to memory on failure
/// - lmdb_native: apply via UTxO.applyDeltaLmdb, error on failure (no fallback)
///
/// Manages undo stack: pushes new undo, caps at MAX_UNDO_DEPTH.
/// Returns errors instead of calling std.process.exit.
/// No metrics emission, no env-var coupling, no logging.
pub fn applyBlock(
    utxo: *UTxO,
    store: ?*LmdbUtxo,
    undo_stack: *std.array_list.Managed(Undo),
    alloc: std.mem.Allocator,
    consumed: []const TxIn,
    produced: []const Produced,
    mode: ApplyMode,
) ApplyError!ApplyResult {
    switch (mode) {
        .lmdb_native => return applyLmdbNative(utxo, store, undo_stack, alloc, consumed, produced),
        .lmdb_truth => return applyLmdbTruth(utxo, store, undo_stack, alloc, consumed, produced),
        .memory_only => return applyMemoryOnly(utxo, undo_stack, alloc, consumed, produced),
    }
}

/// Roll back the most recent block application.
/// Pops the last undo from the stack, reverses in-memory state,
/// and reverses LMDB state if a store is available.
///
/// Mirrors follower.zig lines 6780–6797 (rollback call site)
/// and lmdbApplyUndoRollback() (lines 4451–4479).
pub fn rollbackBlock(
    utxo: *UTxO,
    store: ?*LmdbUtxo,
    undo_stack: *std.array_list.Managed(Undo),
    alloc: std.mem.Allocator,
) error{EmptyUndoStack}!void {
    if (undo_stack.items.len == 0) return error.EmptyUndoStack;
    var undo = undo_stack.pop().?;
    defer {
        // Free duped addresses in removed entries (deduped by pointer to
        // harden against any upstream aliasing — obs6 stability hardening).
        freeUndoAddressesDedup(&undo, alloc);
        undo.deinit();
    }

    // In-memory rollback (mirrors follower.zig line 6785)
    utxo.rollbackDelta(&undo);

    // LMDB rollback (mirrors lmdbApplyUndoRollback, lines 4451–4479)
    if (store) |s| {
        lmdbRollback(s, alloc, &undo);
    }
}

// --- Internal helpers ---

/// LMDB-native mode: LMDB is mandatory, no fallback.
/// Mirrors follower.zig lines 1263–1315.
fn applyLmdbNative(
    utxo: *UTxO,
    store_opt: ?*LmdbUtxo,
    undo_stack: *std.array_list.Managed(Undo),
    alloc: std.mem.Allocator,
    consumed: []const TxIn,
    produced: []const Produced,
) ApplyError!ApplyResult {
    const store = store_opt orelse return error.LmdbStoreRequired;

    var txn = store.beginWrite() orelse return error.LmdbBeginWriteFailed;

    var undo = utxo.applyDeltaLmdb(store, alloc, txn, consumed, produced) catch {
        store.abort(&txn);
        return error.LmdbApplyFailed;
    };

    if (!store.commit(&txn)) {
        undo.deinit();
        return error.LmdbCommitFailed;
    }

    return pushUndo(undo_stack, alloc, undo, consumed.len, produced.len, false);
}

/// LMDB-truth mode: LMDB is authoritative, falls back to memory on failure.
/// On fallback, performs a best-effort shadow-write to keep LMDB in sync
/// so that subsequent blocks can find newly produced outputs.
///
/// Preflight: before opening a write transaction, performs a read-only scan
/// of consumed inputs. If any are missing from LMDB, skips the write txn
/// entirely and goes straight to memory fallback + shadow-write. This avoids
/// the wasted beginWrite + abort cycle when coverage is incomplete.
///
/// Mirrors follower.zig lines 1318–1426 + applyPreviewUtxoFallback shadow-write.
fn applyLmdbTruth(
    utxo: *UTxO,
    store_opt: ?*LmdbUtxo,
    undo_stack: *std.array_list.Managed(Undo),
    alloc: std.mem.Allocator,
    consumed: []const TxIn,
    produced: []const Produced,
) ApplyError!ApplyResult {
    const store = store_opt orelse {
        // No store available — fall back to memory (no shadow-write possible)
        return applyMemoryOnlyFallback(utxo, undo_stack, alloc, consumed, produced);
    };

    // Preflight: read-only scan of consumed inputs. If any are missing
    // from LMDB, skip the write txn entirely and go straight to fallback.
    const coverage = lmdbPreflightCoverage(store, consumed);
    if (coverage.missing > 0) {
        var result = try applyMemoryOnlyFallback(utxo, undo_stack, alloc, consumed, produced);
        lmdbShadowWrite(store, alloc, consumed, produced);
        result.coverage_found = coverage.found;
        result.coverage_total = consumed.len;
        return result;
    }

    var txn = store.beginWrite() orelse {
        // beginWrite failed — fall back to memory + shadow-write
        var result = try applyMemoryOnlyFallback(utxo, undo_stack, alloc, consumed, produced);
        lmdbShadowWrite(store, alloc, consumed, produced);
        result.coverage_found = coverage.found;
        result.coverage_total = consumed.len;
        return result;
    };

    var undo = utxo.applyDeltaLmdb(store, alloc, txn, consumed, produced) catch {
        // applyDeltaLmdb failed — abort txn, fall back to memory + shadow-write
        store.abort(&txn);
        var result = try applyMemoryOnlyFallback(utxo, undo_stack, alloc, consumed, produced);
        lmdbShadowWrite(store, alloc, consumed, produced);
        result.coverage_found = coverage.found;
        result.coverage_total = consumed.len;
        return result;
    };

    if (!store.commit(&txn)) {
        undo.deinit();
        // Commit failed — fall back to memory + shadow-write
        var result = try applyMemoryOnlyFallback(utxo, undo_stack, alloc, consumed, produced);
        lmdbShadowWrite(store, alloc, consumed, produced);
        result.coverage_found = coverage.found;
        result.coverage_total = consumed.len;
        return result;
    }

    var result = try pushUndo(undo_stack, alloc, undo, consumed.len, produced.len, false);
    result.coverage_found = coverage.found;
    result.coverage_total = consumed.len;
    return result;
}

/// Memory-only fallback with used_fallback=true.
fn applyMemoryOnlyFallback(
    utxo: *UTxO,
    undo_stack: *std.array_list.Managed(Undo),
    alloc: std.mem.Allocator,
    consumed: []const TxIn,
    produced: []const Produced,
) ApplyError!ApplyResult {
    var result = try applyMemoryOnly(utxo, undo_stack, alloc, consumed, produced);
    result.used_fallback = true;
    return result;
}

/// Memory-only mode: in-memory applyDelta.
/// Mirrors follower.zig lines 1428–1445.
fn applyMemoryOnly(
    utxo: *UTxO,
    undo_stack: *std.array_list.Managed(Undo),
    alloc: std.mem.Allocator,
    consumed: []const TxIn,
    produced: []const Produced,
) ApplyError!ApplyResult {
    const undo = utxo.applyDelta(consumed, produced) catch {
        return error.MemoryApplyFailed;
    };

    return pushUndo(undo_stack, alloc, undo, consumed.len, produced.len, false);
}

/// Push undo to stack and cap at MAX_UNDO_DEPTH.
/// Mirrors follower.zig lines 1215–1218, 1293–1296, 1356–1359, 1442–1445.
fn pushUndo(
    undo_stack: *std.array_list.Managed(Undo),
    alloc: std.mem.Allocator,
    undo: Undo,
    consumed_count: usize,
    produced_count: usize,
    used_fallback: bool,
) ApplyError!ApplyResult {
    undo_stack.append(undo) catch {
        var u = undo;
        u.deinit();
        return error.UndoAppendFailed;
    };

    // Cap at MAX_UNDO_DEPTH — evict oldest.
    // Free duped addresses in removed entries before deinit, since
    // Undo.deinit only frees the ArrayList backing memory.
    if (undo_stack.items.len > MAX_UNDO_DEPTH) {
        var evicted = undo_stack.orderedRemove(0);
        freeUndoAddressesDedup(&evicted, alloc);
        evicted.deinit();
    }

    return ApplyResult{
        .consumed_count = consumed_count,
        .produced_count = produced_count,
        .used_fallback = used_fallback,
        .undo_stack_depth = undo_stack.items.len,
    };
}

/// Reverse an undo against LMDB (non-fatal on failure).
/// Mirrors follower.zig lmdbApplyUndoRollback() lines 4451–4479.
fn lmdbRollback(store: *LmdbUtxo, alloc: std.mem.Allocator, undo: *Undo) void {
    var txn = store.beginWrite() orelse return;

    // Reverse iteration (same as follower.zig lines 4458–4471)
    var i: usize = undo.entries.items.len;
    while (i > 0) {
        i -= 1;
        const e = undo.entries.items[i];
        switch (e) {
            // Inserted during forward → remove from LMDB on rollback
            .inserted => |input| {
                store.delTxn(&txn, input.tx_hash, input.index);
            },
            // Removed during forward → restore into LMDB on rollback
            .removed => |r| {
                store.putTxn(alloc, &txn, r.input.tx_hash, r.input.index, r.output);
            },
        }
    }

    _ = store.commit(&txn);
}

/// Best-effort shadow-write to LMDB after a memory-only fallback.
/// Keeps LMDB in sync so subsequent applyDeltaLmdb calls can find
/// newly produced outputs. Non-fatal at every stage.
/// Mirrors follower.zig applyPreviewUtxoFallback() lines 1232–1245.
fn lmdbShadowWrite(
    store: *LmdbUtxo,
    alloc: std.mem.Allocator,
    consumed: []const TxIn,
    produced: []const Produced,
) void {
    var txn = store.beginWrite() orelse return;
    for (consumed) |con| {
        store.delTxn(&txn, con.tx_hash, con.index);
    }
    for (produced) |p| {
        store.putTxn(alloc, &txn, p.input.tx_hash, p.input.index, p.output);
    }
    _ = store.commit(&txn);
}

/// Read-only LMDB scan to check how many consumed inputs exist in the store.
/// Returns the count of found and missing inputs. Used by applyLmdbTruth to
/// skip the write transaction path when inputs are missing (avoids wasted
/// beginWrite + abort cycle).
fn lmdbPreflightCoverage(store: *LmdbUtxo, consumed: []const TxIn) struct { found: usize, missing: usize } {
    if (consumed.len == 0) return .{ .found = 0, .missing = 0 };
    var rtxn = store.beginRead() orelse return .{ .found = 0, .missing = consumed.len };
    defer store.abort(&rtxn);
    var found: usize = 0;
    for (consumed) |con| {
        if (store.getTxn(&rtxn, con.tx_hash, con.index) != null) {
            found += 1;
        }
    }
    return .{ .found = found, .missing = consumed.len - found };
}

// --- Tests ---

test "applyBlock memory_only produces correct undo and rollback reverses it" {
    const alloc = std.testing.allocator;

    var utxo = UTxO.init(alloc);
    defer utxo.deinit();

    var undo_stack = std.array_list.Managed(Undo).init(alloc);
    defer {
        for (undo_stack.items) |*u| {
            for (u.entries.items) |e| {
                switch (e) {
                    .removed => |r| alloc.free(r.output.address),
                    .inserted => {},
                }
            }
            u.deinit();
        }
        undo_stack.deinit();
    }

    const txh1 = [_]u8{0x01} ** 32;
    const txh2 = [_]u8{0x02} ** 32;
    const in1 = TxIn{ .tx_hash = txh1, .index = 0 };
    const in2 = TxIn{ .tx_hash = txh2, .index = 1 };

    // Produce two outputs
    const produced = [_]Produced{
        .{ .input = in1, .output = .{ .address = "addr1", .lovelace = 100 } },
        .{ .input = in2, .output = .{ .address = "addr2", .lovelace = 200 } },
    };

    const result = try applyBlock(&utxo, null, &undo_stack, alloc, &[_]TxIn{}, &produced, .memory_only);
    try std.testing.expectEqual(@as(usize, 0), result.consumed_count);
    try std.testing.expectEqual(@as(usize, 2), result.produced_count);
    try std.testing.expect(!result.used_fallback);
    try std.testing.expectEqual(@as(usize, 1), result.undo_stack_depth);
    try std.testing.expectEqual(@as(usize, 2), utxo.count());

    // Rollback
    try rollbackBlock(&utxo, null, &undo_stack, alloc);
    try std.testing.expectEqual(@as(usize, 0), utxo.count());
    try std.testing.expectEqual(@as(usize, 0), undo_stack.items.len);
}

test "applyBlock with empty deltas returns zero counts" {
    const alloc = std.testing.allocator;

    var utxo = UTxO.init(alloc);
    defer utxo.deinit();

    var undo_stack = std.array_list.Managed(Undo).init(alloc);
    defer {
        for (undo_stack.items) |*u| {
            for (u.entries.items) |e| {
                switch (e) {
                    .removed => |r| alloc.free(r.output.address),
                    .inserted => {},
                }
            }
            u.deinit();
        }
        undo_stack.deinit();
    }

    const result = try applyBlock(&utxo, null, &undo_stack, alloc, &[_]TxIn{}, &[_]Produced{}, .memory_only);
    try std.testing.expectEqual(@as(usize, 0), result.consumed_count);
    try std.testing.expectEqual(@as(usize, 0), result.produced_count);
    try std.testing.expect(!result.used_fallback);
    try std.testing.expectEqual(@as(usize, 1), result.undo_stack_depth);
}

test "undo depth cap at MAX_UNDO_DEPTH" {
    const alloc = std.testing.allocator;

    var utxo = UTxO.init(alloc);
    defer utxo.deinit();

    var undo_stack = std.array_list.Managed(Undo).init(alloc);
    defer {
        for (undo_stack.items) |*u| {
            for (u.entries.items) |e| {
                switch (e) {
                    .removed => |r| alloc.free(r.output.address),
                    .inserted => {},
                }
            }
            u.deinit();
        }
        undo_stack.deinit();
    }

    // Push MAX_UNDO_DEPTH + 1 blocks
    for (0..MAX_UNDO_DEPTH + 1) |_| {
        _ = try applyBlock(&utxo, null, &undo_stack, alloc, &[_]TxIn{}, &[_]Produced{}, .memory_only);
    }

    // Stack must never exceed MAX_UNDO_DEPTH
    try std.testing.expectEqual(@as(usize, MAX_UNDO_DEPTH), undo_stack.items.len);
}

test "pushUndo eviction frees duped addresses in removed entries" {
    const alloc = std.testing.allocator;

    var utxo = UTxO.init(alloc);
    defer utxo.deinit();

    var undo_stack = std.array_list.Managed(Undo).init(alloc);
    defer {
        for (undo_stack.items) |*u| {
            for (u.entries.items) |e| {
                switch (e) {
                    .removed => |r| alloc.free(r.output.address),
                    .inserted => {},
                }
            }
            u.deinit();
        }
        undo_stack.deinit();
    }

    // Block 0: produce one output.
    const txh0 = [_]u8{0xA0} ** 32;
    const produced0 = [_]Produced{
        .{ .input = .{ .tx_hash = txh0, .index = 0 }, .output = .{ .address = "addr0", .lovelace = 100 } },
    };
    _ = try applyBlock(&utxo, null, &undo_stack, alloc, &[_]TxIn{}, &produced0, .memory_only);

    // Block 1: consume block 0's output. This undo has a .removed entry
    // with a duped address that must be freed on eviction.
    const consumed1 = [_]TxIn{.{ .tx_hash = txh0, .index = 0 }};
    const txh1 = [_]u8{0xA1} ** 32;
    const produced1 = [_]Produced{
        .{ .input = .{ .tx_hash = txh1, .index = 0 }, .output = .{ .address = "addr1", .lovelace = 200 } },
    };
    _ = try applyBlock(&utxo, null, &undo_stack, alloc, &consumed1, &produced1, .memory_only);

    // Now the undo at position 0 (block 0) has .inserted only.
    // The undo at position 1 (block 1) has .removed with duped address.
    try std.testing.expectEqual(@as(usize, 2), undo_stack.items.len);

    // Push MAX_UNDO_DEPTH - 1 more empty blocks to fill the stack.
    // After this, stack has MAX_UNDO_DEPTH + 1 entries total, but each
    // push beyond MAX_UNDO_DEPTH evicts the oldest.
    // Block 0's undo (position 0, .inserted only) gets evicted first.
    for (0..MAX_UNDO_DEPTH - 1) |_| {
        _ = try applyBlock(&utxo, null, &undo_stack, alloc, &[_]TxIn{}, &[_]Produced{}, .memory_only);
    }
    // Stack is full at MAX_UNDO_DEPTH. Block 1's undo (with .removed)
    // is now the oldest entry at position 0.
    try std.testing.expectEqual(@as(usize, MAX_UNDO_DEPTH), undo_stack.items.len);

    // Push one more block. This evicts block 1's undo which contains
    // a .removed entry with a duped address. If pushUndo doesn't free
    // the address, the testing allocator will detect the leak.
    _ = try applyBlock(&utxo, null, &undo_stack, alloc, &[_]TxIn{}, &[_]Produced{}, .memory_only);
    try std.testing.expectEqual(@as(usize, MAX_UNDO_DEPTH), undo_stack.items.len);
}

// --- LMDB tests ---

const test_lmdb_dir = "/tmp/tsunagi_test_block_apply";

fn openTestStore() !LmdbUtxo {
    compat.fs.cwd().deleteTree(test_lmdb_dir) catch {};
    try compat.fs.cwd().makePath(test_lmdb_dir);
    return LmdbUtxo.open(test_lmdb_dir);
}

/// Helper: check if a key exists in LMDB via a read txn.
fn lmdbKeyExists(store: *LmdbUtxo, tx_hash: [32]u8, index: u32) bool {
    var rtxn = store.beginRead() orelse return false;
    defer store.abort(&rtxn);
    return store.getTxn(&rtxn, tx_hash, index) != null;
}

/// Undo cleanup helper for tests with LMDB store.
fn cleanupUndoStack(undo_stack: *std.array_list.Managed(Undo), alloc: std.mem.Allocator) void {
    for (undo_stack.items) |*u| {
        for (u.entries.items) |e| {
            switch (e) {
                .removed => |r| alloc.free(r.output.address),
                .inserted => {},
            }
        }
        u.deinit();
    }
    undo_stack.deinit();
}

test "lmdb_truth applies directly to LMDB and consumes correctly" {
    const alloc = std.testing.allocator;

    var store = try openTestStore();
    defer {
        store.close();
        compat.fs.cwd().deleteTree(test_lmdb_dir) catch {};
    }

    var utxo = UTxO.init(alloc);
    defer utxo.deinit();

    var undo_stack = std.array_list.Managed(Undo).init(alloc);
    defer cleanupUndoStack(&undo_stack, alloc);

    // Block 1: produce two outputs via lmdb_truth.
    // With empty LMDB and no consumed inputs, applyDeltaLmdb should succeed
    // (no inputs to look up, just inserts).
    const txh1 = [_]u8{0xB1} ** 32;
    const produced1 = [_]Produced{
        .{ .input = .{ .tx_hash = txh1, .index = 0 }, .output = .{ .address = "sw1", .lovelace = 100 } },
        .{ .input = .{ .tx_hash = txh1, .index = 1 }, .output = .{ .address = "sw2", .lovelace = 200 } },
    };
    const r1 = try applyBlock(&utxo, &store, &undo_stack, alloc, &[_]TxIn{}, &produced1, .lmdb_truth);
    try std.testing.expectEqual(@as(usize, 2), r1.produced_count);
    try std.testing.expect(!r1.used_fallback);

    // Verify outputs are in LMDB (applyDeltaLmdb writes to LMDB, not in-memory)
    try std.testing.expect(lmdbKeyExists(&store, txh1, 0));
    try std.testing.expect(lmdbKeyExists(&store, txh1, 1));

    // Block 2: consume one output from block 1 and produce a new one.
    // applyDeltaLmdb should succeed (consumed input is in LMDB).
    const consumed2 = [_]TxIn{.{ .tx_hash = txh1, .index = 0 }};
    const txh2 = [_]u8{0xB2} ** 32;
    const produced2 = [_]Produced{
        .{ .input = .{ .tx_hash = txh2, .index = 0 }, .output = .{ .address = "sw3", .lovelace = 300 } },
    };
    const r2 = try applyBlock(&utxo, &store, &undo_stack, alloc, &consumed2, &produced2, .lmdb_truth);
    try std.testing.expectEqual(@as(usize, 1), r2.consumed_count);
    try std.testing.expectEqual(@as(usize, 1), r2.produced_count);
    try std.testing.expect(!r2.used_fallback);

    // Consumed key removed from LMDB, new key present
    try std.testing.expect(!lmdbKeyExists(&store, txh1, 0));
    try std.testing.expect(lmdbKeyExists(&store, txh1, 1));
    try std.testing.expect(lmdbKeyExists(&store, txh2, 0));

    try std.testing.expectEqual(@as(usize, 2), undo_stack.items.len);
}

test "lmdb_truth fallback shadow-write enables subsequent LMDB apply" {
    const alloc = std.testing.allocator;

    var store = try openTestStore();
    defer {
        store.close();
        compat.fs.cwd().deleteTree(test_lmdb_dir) catch {};
    }

    var utxo = UTxO.init(alloc);
    defer utxo.deinit();

    var undo_stack = std.array_list.Managed(Undo).init(alloc);
    defer cleanupUndoStack(&undo_stack, alloc);

    // Seed LMDB with one output directly (simulates pre-existing state).
    const seed_txh = [_]u8{0xC0} ** 32;
    {
        var wtxn = store.beginWrite() orelse return error.LmdbBeginWriteFailed;
        store.putTxn(alloc, &wtxn, seed_txh, 0, .{ .address = "seed", .lovelace = 50 });
        try std.testing.expect(store.commit(&wtxn));
    }

    // Block 1: consume the seed output + produce a new output.
    // applyDeltaLmdb succeeds because seed exists in LMDB.
    const consumed1 = [_]TxIn{.{ .tx_hash = seed_txh, .index = 0 }};
    const txh1 = [_]u8{0xC1} ** 32;
    const produced1 = [_]Produced{
        .{ .input = .{ .tx_hash = txh1, .index = 0 }, .output = .{ .address = "c1", .lovelace = 100 } },
    };
    const r1 = try applyBlock(&utxo, &store, &undo_stack, alloc, &consumed1, &produced1, .lmdb_truth);
    try std.testing.expect(!r1.used_fallback);
    try std.testing.expect(lmdbKeyExists(&store, txh1, 0));

    // Now remove txh1 from LMDB manually to force a fallback on the next block.
    // This simulates a scenario where applyDeltaLmdb would fail (e.g., missing input).
    {
        var wtxn = store.beginWrite() orelse return error.LmdbBeginWriteFailed;
        store.delTxn(&wtxn, txh1, 0);
        try std.testing.expect(store.commit(&wtxn));
    }
    try std.testing.expect(!lmdbKeyExists(&store, txh1, 0));

    // Block 2: consume txh1:0 (which we just removed from LMDB) + produce txh2:0.
    // applyDeltaLmdb will fail (LedgerViolation: consumed input not in LMDB).
    // Fallback should: (1) apply in-memory, (2) shadow-write to LMDB.
    const consumed2 = [_]TxIn{.{ .tx_hash = txh1, .index = 0 }};
    const txh2 = [_]u8{0xC2} ** 32;
    const produced2 = [_]Produced{
        .{ .input = .{ .tx_hash = txh2, .index = 0 }, .output = .{ .address = "c2", .lovelace = 200 } },
    };
    const r2 = try applyBlock(&utxo, &store, &undo_stack, alloc, &consumed2, &produced2, .lmdb_truth);
    try std.testing.expect(r2.used_fallback);
    try std.testing.expectEqual(@as(usize, 1), r2.consumed_count);
    try std.testing.expectEqual(@as(usize, 1), r2.produced_count);

    // Shadow-write should have written txh2:0 to LMDB
    try std.testing.expect(lmdbKeyExists(&store, txh2, 0));

    // Block 3: consume txh2:0 (shadow-written by block 2) + produce txh3:0.
    // applyDeltaLmdb should now SUCCEED because the shadow-write kept LMDB in sync.
    const consumed3 = [_]TxIn{.{ .tx_hash = txh2, .index = 0 }};
    const txh3 = [_]u8{0xC3} ** 32;
    const produced3 = [_]Produced{
        .{ .input = .{ .tx_hash = txh3, .index = 0 }, .output = .{ .address = "c3", .lovelace = 300 } },
    };
    const r3 = try applyBlock(&utxo, &store, &undo_stack, alloc, &consumed3, &produced3, .lmdb_truth);
    // This is the key assertion: no fallback because shadow-write kept LMDB current
    try std.testing.expect(!r3.used_fallback);
    try std.testing.expect(lmdbKeyExists(&store, txh3, 0));
    try std.testing.expect(!lmdbKeyExists(&store, txh2, 0));
}

test "rollback after shadow-write reverses LMDB state" {
    const alloc = std.testing.allocator;

    var store = try openTestStore();
    defer {
        store.close();
        compat.fs.cwd().deleteTree(test_lmdb_dir) catch {};
    }

    var utxo = UTxO.init(alloc);
    defer utxo.deinit();

    var undo_stack = std.array_list.Managed(Undo).init(alloc);
    defer cleanupUndoStack(&undo_stack, alloc);

    // Seed LMDB with one output.
    const seed_txh = [_]u8{0xD0} ** 32;
    {
        var wtxn = store.beginWrite() orelse return error.LmdbBeginWriteFailed;
        store.putTxn(alloc, &wtxn, seed_txh, 0, .{ .address = "rseed", .lovelace = 77 });
        try std.testing.expect(store.commit(&wtxn));
    }
    // Also insert into in-memory UTxO so applyDelta can consume it.
    {
        const seed_produced = [_]Produced{
            .{ .input = .{ .tx_hash = seed_txh, .index = 0 }, .output = .{ .address = "rseed", .lovelace = 77 } },
        };
        _ = try applyBlock(&utxo, &store, &undo_stack, alloc, &[_]TxIn{}, &seed_produced, .memory_only);
    }
    try std.testing.expectEqual(@as(usize, 1), utxo.count());
    try std.testing.expect(lmdbKeyExists(&store, seed_txh, 0));

    // Remove seed from LMDB to force fallback on the next block.
    {
        var wtxn = store.beginWrite() orelse return error.LmdbBeginWriteFailed;
        store.delTxn(&wtxn, seed_txh, 0);
        try std.testing.expect(store.commit(&wtxn));
    }

    // Block 2: consume seed + produce new. Will fallback + shadow-write.
    const consumed2 = [_]TxIn{.{ .tx_hash = seed_txh, .index = 0 }};
    const txh2 = [_]u8{0xD2} ** 32;
    const produced2 = [_]Produced{
        .{ .input = .{ .tx_hash = txh2, .index = 0 }, .output = .{ .address = "d2", .lovelace = 88 } },
    };
    const r2 = try applyBlock(&utxo, &store, &undo_stack, alloc, &consumed2, &produced2, .lmdb_truth);
    try std.testing.expect(r2.used_fallback);
    try std.testing.expect(lmdbKeyExists(&store, txh2, 0));
    try std.testing.expectEqual(@as(usize, 1), utxo.count()); // seed consumed, d2 produced

    // Rollback block 2. Should reverse both in-memory and LMDB state.
    try rollbackBlock(&utxo, &store, &undo_stack, alloc);

    // In-memory: seed_txh:0 restored (from undo .removed), txh2:0 removed (from undo .inserted)
    try std.testing.expectEqual(@as(usize, 1), utxo.count());

    // LMDB: txh2:0 should be removed (rollback reverses the shadow-write insertion)
    try std.testing.expect(!lmdbKeyExists(&store, txh2, 0));
    // LMDB: seed_txh:0 should be restored (rollback reverses the shadow-write deletion)
    try std.testing.expect(lmdbKeyExists(&store, seed_txh, 0));
}

test "lmdb preflight coverage detects missing inputs" {
    const alloc = std.testing.allocator;

    var store = try openTestStore();
    defer {
        store.close();
        compat.fs.cwd().deleteTree(test_lmdb_dir) catch {};
    }

    // Seed LMDB with one output.
    const txhP1 = [_]u8{0xE0} ** 32;
    {
        var wtxn = store.beginWrite() orelse return error.LmdbBeginWriteFailed;
        store.putTxn(alloc, &wtxn, txhP1, 0, .{ .address = "p1", .lovelace = 10 });
        try std.testing.expect(store.commit(&wtxn));
    }

    // Check coverage: one present, one missing.
    const txhP2 = [_]u8{0xE1} ** 32;
    const consumed = [_]TxIn{
        .{ .tx_hash = txhP1, .index = 0 },
        .{ .tx_hash = txhP2, .index = 0 },
    };
    const cov = lmdbPreflightCoverage(&store, &consumed);
    try std.testing.expectEqual(@as(usize, 1), cov.found);
    try std.testing.expectEqual(@as(usize, 1), cov.missing);
}

test "lmdb preflight coverage detects all present" {
    const alloc = std.testing.allocator;

    var store = try openTestStore();
    defer {
        store.close();
        compat.fs.cwd().deleteTree(test_lmdb_dir) catch {};
    }

    // Seed LMDB with two outputs.
    const txhQ1 = [_]u8{0xF0} ** 32;
    const txhQ2 = [_]u8{0xF1} ** 32;
    {
        var wtxn = store.beginWrite() orelse return error.LmdbBeginWriteFailed;
        store.putTxn(alloc, &wtxn, txhQ1, 0, .{ .address = "q1", .lovelace = 10 });
        store.putTxn(alloc, &wtxn, txhQ2, 0, .{ .address = "q2", .lovelace = 20 });
        try std.testing.expect(store.commit(&wtxn));
    }

    // Check coverage: both present.
    const consumed = [_]TxIn{
        .{ .tx_hash = txhQ1, .index = 0 },
        .{ .tx_hash = txhQ2, .index = 0 },
    };
    const cov = lmdbPreflightCoverage(&store, &consumed);
    try std.testing.expectEqual(@as(usize, 2), cov.found);
    try std.testing.expectEqual(@as(usize, 0), cov.missing);
}

test "lmdb_truth skips write txn when preflight detects missing coverage" {
    const alloc = std.testing.allocator;

    var store = try openTestStore();
    defer {
        store.close();
        compat.fs.cwd().deleteTree(test_lmdb_dir) catch {};
    }

    var utxo = UTxO.init(alloc);
    defer utxo.deinit();

    var undo_stack = std.array_list.Managed(Undo).init(alloc);
    defer cleanupUndoStack(&undo_stack, alloc);

    // Seed LMDB with one output (txhR1:0).
    const txhR1 = [_]u8{0xE5} ** 32;
    {
        var wtxn = store.beginWrite() orelse return error.LmdbBeginWriteFailed;
        store.putTxn(alloc, &wtxn, txhR1, 0, .{ .address = "r1", .lovelace = 100 });
        try std.testing.expect(store.commit(&wtxn));
    }

    // Block: consume txhR1:0 (in LMDB) + txhR2:0 (missing), produce txhR3:0.
    // Preflight will find 1 of 2 → fallback path.
    const txhR2 = [_]u8{0xE6} ** 32;
    const txhR3 = [_]u8{0xE7} ** 32;
    const consumed = [_]TxIn{
        .{ .tx_hash = txhR1, .index = 0 },
        .{ .tx_hash = txhR2, .index = 0 },
    };
    const produced = [_]Produced{
        .{ .input = .{ .tx_hash = txhR3, .index = 0 }, .output = .{ .address = "r3", .lovelace = 300 } },
    };
    const result = try applyBlock(&utxo, &store, &undo_stack, alloc, &consumed, &produced, .lmdb_truth);

    // Fallback used because preflight detected missing input.
    try std.testing.expect(result.used_fallback);
    try std.testing.expectEqual(@as(usize, 1), result.coverage_found);
    try std.testing.expectEqual(@as(usize, 2), result.coverage_total);

    // Shadow-write should have written produced output to LMDB.
    try std.testing.expect(lmdbKeyExists(&store, txhR3, 0));
}
