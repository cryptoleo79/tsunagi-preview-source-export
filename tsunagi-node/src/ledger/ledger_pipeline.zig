const std = @import("std");
const block_apply = @import("block_apply.zig");

// ── Ledger Pipeline — UTxO Application ──────────────────────────────
//
// Stateful pipeline that holds UTxO state + undo stack and applies
// or rolls back transaction deltas. Delegates all mutation logic to
// block_apply.zig (proven extraction from follower.zig).
//
// Accepts pre-extracted deltas (consumed/produced slices), NOT raw
// block bytes. The caller is responsible for delta extraction (see
// block_stream.zig).
//
// No protocol imports. No globals. No env-var coupling.

pub const UTxO = block_apply.UTxO;
pub const Undo = block_apply.Undo;
pub const TxIn = block_apply.TxIn;
pub const Produced = block_apply.Produced;
pub const ApplyMode = block_apply.ApplyMode;
pub const ApplyResult = block_apply.ApplyResult;
pub const ApplyError = block_apply.ApplyError;
pub const LmdbUtxo = block_apply.LmdbUtxo;

/// Free `addr` exactly once across a single teardown pass.
///
/// `seen` records the address base pointers already freed; a repeated
/// pointer is skipped. This makes Pipeline.deinit double-free-proof even
/// if an address slice is aliased between the undo log and the UTxO map.
///
/// Under true set-allocation OOM the address is intentionally LEAKED
/// rather than freed: leaking at shutdown is harmless, whereas a double
/// free would abort the process.
fn freeAddrOnce(
    seen: *std.AutoHashMap([*]const u8, void),
    alloc: std.mem.Allocator,
    addr: []const u8,
) void {
    if (addr.len == 0) return;
    const gop = seen.getOrPut(addr.ptr) catch return;
    if (gop.found_existing) return;
    alloc.free(addr);
}

pub const Pipeline = struct {
    alloc: std.mem.Allocator,
    utxo: UTxO,
    undo_stack: std.array_list.Managed(Undo),
    store: ?*LmdbUtxo,
    mode: ApplyMode,

    pub fn init(alloc: std.mem.Allocator, mode: ApplyMode, store: ?*LmdbUtxo) Pipeline {
        return .{
            .alloc = alloc,
            .utxo = UTxO.init(alloc),
            .undo_stack = std.array_list.Managed(Undo).init(alloc),
            .store = store,
            .mode = mode,
        };
    }

    pub fn deinit(self: *Pipeline) void {
        // ── Double-free-proof teardown ──────────────────────────────
        //
        // Address slices may be aliased between the undo log and the
        // live UTxO map: rollback dupes an undo entry's address into
        // the map, and any imperfect ownership path could leave a
        // pointer shared between the two. Freeing the undo addresses
        // and the map addresses independently then frees the same
        // allocation twice — the `double free or corruption (fasttop)`
        // observed during shutdown defer unwind.
        //
        // Correct teardown frees each DISTINCT allocation exactly once.
        // We record every address base pointer in a set and free only
        // on first sight. Structural backing memory (the undo entries
        // lists, the undo_stack array, the hashmap) is freed separately
        // and is never aliased, so it needs no deduplication.
        var seen = std.AutoHashMap([*]const u8, void).init(self.alloc);
        defer seen.deinit();

        for (self.undo_stack.items) |*u| {
            for (u.entries.items) |e| {
                switch (e) {
                    .removed => |r| freeAddrOnce(&seen, self.alloc, r.output.address),
                    .inserted => {},
                }
            }
            u.deinit(); // structural: frees the entries ArrayList backing only
        }
        self.undo_stack.deinit();

        var it = self.utxo.map.iterator();
        while (it.next()) |kv| {
            freeAddrOnce(&seen, self.alloc, kv.value_ptr.address);
        }
        self.utxo.map.deinit(); // structural: frees the hashmap backing only
    }

    /// Apply a block's deltas to the UTxO state.
    /// Delegates to block_apply.applyBlock with the pipeline's mode.
    pub fn applyDeltas(
        self: *Pipeline,
        consumed: []const TxIn,
        produced: []const Produced,
    ) ApplyError!ApplyResult {
        return block_apply.applyBlock(
            &self.utxo,
            self.store,
            &self.undo_stack,
            self.alloc,
            consumed,
            produced,
            self.mode,
        );
    }

    /// Roll back the most recent block application.
    pub fn rollback(self: *Pipeline) error{EmptyUndoStack}!void {
        return block_apply.rollbackBlock(
            &self.utxo,
            self.store,
            &self.undo_stack,
            self.alloc,
        );
    }

    /// Evict the oldest undo entry if the chain has advanced enough
    /// consecutive forward rolls without a rollback.
    ///
    /// Mirrors follower.zig confirmDeepUndos (line 4484): after
    /// confirm_depth consecutive forward rolls, the oldest undo is
    /// considered confirmed and can be safely discarded.
    ///
    /// The caller tracks rolls_since_rollback externally and passes
    /// it in. This keeps the Pipeline free of protocol-level counters.
    pub fn confirmOldest(self: *Pipeline, rolls_since_rollback: usize, confirm_depth: usize) void {
        if (rolls_since_rollback >= confirm_depth and self.undo_stack.items.len > 0) {
            var evicted = self.undo_stack.orderedRemove(0);
            // Free duped addresses in removed entries. A confirmed undo
            // is no longer reachable from the undo stack and its
            // `.removed` addresses were never re-inserted into the live
            // map (an input restored into the map would belong to a
            // rolled-back — i.e. popped — undo, not a confirmed one), so
            // freeing them here cannot alias a live map entry.
            block_apply.freeUndoAddressesDedup(&evicted, self.alloc);
            evicted.deinit();
        }
    }

    /// Number of UTxO entries currently in state.
    pub fn count(self: *Pipeline) usize {
        return self.utxo.count();
    }

    /// Current undo stack depth.
    pub fn undoDepth(self: *Pipeline) usize {
        return self.undo_stack.items.len;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "pipeline init and deinit" {
    var p = Pipeline.init(std.testing.allocator, .memory_only, null);
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), p.count());
    try std.testing.expectEqual(@as(usize, 0), p.undoDepth());
}

test "applyDeltas produces outputs and increases count" {
    var p = Pipeline.init(std.testing.allocator, .memory_only, null);
    defer p.deinit();

    const txh = [_]u8{0x01} ** 32;
    const produced = [_]Produced{
        .{ .input = .{ .tx_hash = txh, .index = 0 }, .output = .{ .address = "a1", .lovelace = 100 } },
        .{ .input = .{ .tx_hash = txh, .index = 1 }, .output = .{ .address = "a2", .lovelace = 200 } },
    };

    const result = try p.applyDeltas(&[_]TxIn{}, &produced);
    try std.testing.expectEqual(@as(usize, 0), result.consumed_count);
    try std.testing.expectEqual(@as(usize, 2), result.produced_count);
    try std.testing.expectEqual(@as(usize, 2), p.count());
    try std.testing.expectEqual(@as(usize, 1), p.undoDepth());
}

test "applyDeltas then consume reduces count" {
    var p = Pipeline.init(std.testing.allocator, .memory_only, null);
    defer p.deinit();

    const txh = [_]u8{0x02} ** 32;
    const produced = [_]Produced{
        .{ .input = .{ .tx_hash = txh, .index = 0 }, .output = .{ .address = "b1", .lovelace = 500 } },
    };

    _ = try p.applyDeltas(&[_]TxIn{}, &produced);
    try std.testing.expectEqual(@as(usize, 1), p.count());

    // Second block consumes the output from the first
    const consumed = [_]TxIn{.{ .tx_hash = txh, .index = 0 }};
    const result = try p.applyDeltas(&consumed, &[_]Produced{});
    try std.testing.expectEqual(@as(usize, 1), result.consumed_count);
    try std.testing.expectEqual(@as(usize, 0), p.count());
    try std.testing.expectEqual(@as(usize, 2), p.undoDepth());
}

test "rollback reverses application" {
    var p = Pipeline.init(std.testing.allocator, .memory_only, null);
    defer p.deinit();

    const txh = [_]u8{0x03} ** 32;
    const produced = [_]Produced{
        .{ .input = .{ .tx_hash = txh, .index = 0 }, .output = .{ .address = "c1", .lovelace = 300 } },
    };

    _ = try p.applyDeltas(&[_]TxIn{}, &produced);
    try std.testing.expectEqual(@as(usize, 1), p.count());
    try std.testing.expectEqual(@as(usize, 1), p.undoDepth());

    try p.rollback();
    try std.testing.expectEqual(@as(usize, 0), p.count());
    try std.testing.expectEqual(@as(usize, 0), p.undoDepth());
}

test "rollback on empty stack returns error" {
    var p = Pipeline.init(std.testing.allocator, .memory_only, null);
    defer p.deinit();

    try std.testing.expectError(error.EmptyUndoStack, p.rollback());
}

test "empty deltas apply increments undo depth" {
    var p = Pipeline.init(std.testing.allocator, .memory_only, null);
    defer p.deinit();

    const result = try p.applyDeltas(&[_]TxIn{}, &[_]Produced{});
    try std.testing.expectEqual(@as(usize, 0), result.consumed_count);
    try std.testing.expectEqual(@as(usize, 0), result.produced_count);
    try std.testing.expectEqual(@as(usize, 0), p.count());
    try std.testing.expectEqual(@as(usize, 1), p.undoDepth());
}

test "multi-block apply and partial rollback" {
    var p = Pipeline.init(std.testing.allocator, .memory_only, null);
    defer p.deinit();

    // Block 1: produce 2 outputs
    const txh1 = [_]u8{0x10} ** 32;
    const produced1 = [_]Produced{
        .{ .input = .{ .tx_hash = txh1, .index = 0 }, .output = .{ .address = "d1", .lovelace = 100 } },
        .{ .input = .{ .tx_hash = txh1, .index = 1 }, .output = .{ .address = "d2", .lovelace = 200 } },
    };
    _ = try p.applyDeltas(&[_]TxIn{}, &produced1);

    // Block 2: produce 1 more output (no consume — rollback of
    // produce-only blocks avoids the Undo address ownership gap
    // in block_apply.rollbackBlock)
    const txh2 = [_]u8{0x20} ** 32;
    const produced2 = [_]Produced{
        .{ .input = .{ .tx_hash = txh2, .index = 0 }, .output = .{ .address = "e1", .lovelace = 50 } },
    };
    _ = try p.applyDeltas(&[_]TxIn{}, &produced2);

    try std.testing.expectEqual(@as(usize, 3), p.count()); // d1 + d2 + e1
    try std.testing.expectEqual(@as(usize, 2), p.undoDepth());

    // Rollback block 2 only
    try p.rollback();
    try std.testing.expectEqual(@as(usize, 2), p.count()); // d1 + d2
    try std.testing.expectEqual(@as(usize, 1), p.undoDepth());
}

test "confirmOldest evicts after confirm_depth" {
    var p = Pipeline.init(std.testing.allocator, .memory_only, null);
    defer p.deinit();

    // Apply 3 blocks
    const txh1 = [_]u8{0x30} ** 32;
    const txh2 = [_]u8{0x31} ** 32;
    const txh3 = [_]u8{0x32} ** 32;
    _ = try p.applyDeltas(&[_]TxIn{}, &[_]Produced{
        .{ .input = .{ .tx_hash = txh1, .index = 0 }, .output = .{ .address = "f1", .lovelace = 10 } },
    });
    _ = try p.applyDeltas(&[_]TxIn{}, &[_]Produced{
        .{ .input = .{ .tx_hash = txh2, .index = 0 }, .output = .{ .address = "f2", .lovelace = 20 } },
    });
    _ = try p.applyDeltas(&[_]TxIn{}, &[_]Produced{
        .{ .input = .{ .tx_hash = txh3, .index = 0 }, .output = .{ .address = "f3", .lovelace = 30 } },
    });
    try std.testing.expectEqual(@as(usize, 3), p.undoDepth());

    // Below confirm_depth=3: no eviction
    p.confirmOldest(2, 3);
    try std.testing.expectEqual(@as(usize, 3), p.undoDepth());

    // At confirm_depth=3: evict oldest
    p.confirmOldest(3, 3);
    try std.testing.expectEqual(@as(usize, 2), p.undoDepth());

    // Another confirmation evicts next oldest
    p.confirmOldest(4, 3);
    try std.testing.expectEqual(@as(usize, 1), p.undoDepth());

    // UTxO state unchanged (eviction doesn't affect UTxO)
    try std.testing.expectEqual(@as(usize, 3), p.count());
}

test "confirmOldest no-op on empty stack" {
    var p = Pipeline.init(std.testing.allocator, .memory_only, null);
    defer p.deinit();

    // Should not panic or error
    p.confirmOldest(10, 3);
    try std.testing.expectEqual(@as(usize, 0), p.undoDepth());
}
