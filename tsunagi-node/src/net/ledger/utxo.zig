const std = @import("std");

pub const TxIn = struct {
    tx_hash: [32]u8,
    index: u32,
};

pub const TxOut = struct {
    // For now we keep address as raw bytes (CBOR bytes or bech32 later).
    address: []const u8,
    lovelace: u64,
};

pub const Produced = struct {
    input: TxIn,
    output: TxOut,
};

pub const UndoEntry = union(enum) {
    // We inserted a new UTxO in this block; rollback should remove it.
    inserted: TxIn,
    // We removed a spent UTxO in this block; rollback should restore it.
    removed: struct { input: TxIn, output: TxOut },
};

pub const Undo = struct {
    entries: std.array_list.Managed(UndoEntry),

    pub fn init(alloc: std.mem.Allocator) Undo {
        return .{ .entries = std.array_list.Managed(UndoEntry).init(alloc) };
    }

    pub fn deinit(self: *Undo) void {
        self.entries.deinit();
    }

    /// Free duped addresses in .removed entries, then deinit.
    /// Call instead of deinit() when undo was populated by applyDelta
    /// (which dupes addresses into the undo log).
    pub fn deinitFreeAddresses(self: *Undo) void {
        const a = self.entries.allocator;
        for (self.entries.items) |entry| {
            switch (entry) {
                .removed => |r| {
                    if (r.output.address.len > 0) {
                        a.free(r.output.address);
                    }
                },
                .inserted => {},
            }
        }
        self.entries.deinit();
    }
};

pub const UTxO = struct {
    alloc: std.mem.Allocator,
    map: std.AutoHashMap(TxIn, TxOut),

    pub fn init(alloc: std.mem.Allocator) UTxO {
        return .{ .alloc = alloc, .map = std.AutoHashMap(TxIn, TxOut).init(alloc) };
    }

    pub fn deinit(self: *UTxO) void {
        // NOTE: address slices are owned by us (dupes), free them.
        var it = self.map.iterator();
        while (it.next()) |kv| {
            self.alloc.free(kv.value_ptr.address);
        }
        self.map.deinit();
    }

    fn dupeOut(self: *UTxO, out: TxOut) !TxOut {
        return .{
            .address = try self.alloc.dupe(u8, out.address),
            .lovelace = out.lovelace,
        };
    }

    /// Apply a "delta" of consumed inputs and produced outputs.
    /// This returns an Undo log that can revert this delta exactly.
    pub fn applyDelta(
        self: *UTxO,
        consumed: []const TxIn,
        produced: []const Produced,
    ) !Undo {
        var undo = Undo.init(self.alloc);
        errdefer undo.deinit();

        // 1) Consume inputs (remove from UTxO)
        for (consumed) |input| {
            if (self.map.fetchRemove(input)) |removed| {
                // Save removed output for rollback.
                const saved = try self.dupeOut(removed.value);
                try undo.entries.append(.{ .removed = .{ .input = input, .output = saved } });
                // Free stored output address from map removal result.
                self.alloc.free(removed.value.address);
            } else {
                // Input not found — for now we treat as non-fatal in this phase.
                // Later, ledger validation decides if this is invalid.
            }
        }

        // 2) Produce new outputs (insert into UTxO)
        for (produced) |p| {
            const out_copy = try self.dupeOut(p.output);

            // Insert; if existing, free old and overwrite.
            if (try self.map.fetchPut(p.input, out_copy)) |old| {
                self.alloc.free(old.value.address);
            }

            // Mark insertion for rollback.
            try undo.entries.append(.{ .inserted = p.input });
        }

        return undo;
    }

    /// Apply a delta using LMDB as the authoritative store.
    /// Produces an Undo log just like applyDelta, but reads/writes go through LMDB.
    pub fn applyDeltaLmdb(
        self: *UTxO,
        store: anytype,
        alloc_for_store: std.mem.Allocator,
        txn_in: anytype,
        consumed: []const TxIn,
        produced: []const Produced,
    ) !Undo {
        var undo = Undo.init(self.alloc);
        errdefer undo.deinit();

        var t = txn_in;

        // 1) Consume inputs: require existence in LMDB (truth)
        var consumed_lovelace: u64 = 0;
        for (consumed) |input| {
            const raw = store.getTxn(&t, input.tx_hash, input.index) orelse {
                return error.LedgerViolation;
            };

            const dec = store.decodeTxOutValue(self.alloc, raw) orelse {
                return error.LedgerViolation;
            };
            defer self.alloc.free(dec.address);

            consumed_lovelace +|= dec.lovelace;

            // Save removed output for rollback
            const saved = TxOut{ .address = dec.address, .lovelace = dec.lovelace };
            const saved_dup = try self.dupeOut(saved);
            try undo.entries.append(.{ .removed = .{ .input = input, .output = saved_dup } });

            // Delete from LMDB
            store.delTxn(&t, input.tx_hash, input.index);
        }

        // 2) Produce outputs: must NOT exist already in LMDB
        var produced_lovelace: u64 = 0;
        for (produced) |p| {
            const exists = store.getTxn(&t, p.input.tx_hash, p.input.index) != null;
            if (exists) return error.LedgerViolation;

            produced_lovelace +|= p.output.lovelace;
            store.putTxn(alloc_for_store, &t, p.input.tx_hash, p.input.index, p.output);
            try undo.entries.append(.{ .inserted = p.input });
        }

        // 3) Block-level lovelace balance sanity (observability):
        // consumed >= produced (deficit = fees + minting effects)
        // Violation means more lovelace produced than consumed.
        // This is a counter/signal, not a hard rejection — upstream blocks
        // are already validated by cardano-node. Minting can also cause
        // produced > consumed legitimately.
        if (consumed.len > 0 and consumed_lovelace < produced_lovelace) {
            const tx_decode = @import("tx_decode.zig");
            tx_decode.incrementBalanceViolation();
        }

        return undo;
    }

    /// Roll back a previously applied delta using its Undo log.
    pub fn rollbackDelta(self: *UTxO, undo: *Undo) void {
        // Reverse order to undo correctly.
        var i: usize = undo.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = undo.entries.items[i];
            switch (e) {
                .inserted => |input| {
                    if (self.map.fetchRemove(input)) |removed| {
                        self.alloc.free(removed.value.address);
                    }
                },
                .removed => |r| {
                    // Restore removed output.
                    //
                    // The map MUST own an address copy that is independent
                    // of the undo entry's slice. Aliasing the undo entry's
                    // own pointer into the map (the previous
                    // `dupe(...) catch r.output.address` fallback) makes the
                    // same allocation reachable from both the undo log and
                    // the map — teardown then frees it twice
                    // (`double free or corruption (fasttop)`).
                    const dup_addr = self.alloc.dupe(u8, r.output.address) catch {
                        // OOM — cannot safely restore this entry. Skip it:
                        // the undo entry keeps sole ownership of its
                        // address and no alias is created.
                        continue;
                    };
                    const restored = TxOut{
                        .address = dup_addr,
                        .lovelace = r.output.lovelace,
                    };
                    if (self.map.fetchPut(r.input, restored)) |maybe_old| {
                        // If something existed there, free its address.
                        if (maybe_old) |old| self.alloc.free(old.value.address);
                    } else |_| {
                        // fetchPut failed — `restored` never entered the
                        // map. Free our dup so it does not leak.
                        self.alloc.free(dup_addr);
                    }
                },
            }
        }
    }

    pub fn count(self: *UTxO) usize {
        return self.map.count();
    }
};

// ------------------
// Unit tests (local)
// ------------------

test "utxo applyDelta + rollbackDelta roundtrip" {
    const alloc = std.heap.page_allocator;

    var utxo = UTxO.init(alloc);
    defer utxo.deinit();

    const txh1 = [_]u8{1} ** 32;
    const txh2 = [_]u8{2} ** 32;

    const in1 = TxIn{ .tx_hash = txh1, .index = 0 };
    const in2 = TxIn{ .tx_hash = txh2, .index = 1 };

    // Produce two outputs
    var produced = [_]Produced{
        .{ .input = in1, .output = .{ .address = "addr1", .lovelace = 100 } },
        .{ .input = in2, .output = .{ .address = "addr2", .lovelace = 200 } },
    };

    var undo1 = try utxo.applyDelta(&[_]TxIn{}, &produced);
    defer undo1.deinit();

    try std.testing.expectEqual(@as(usize, 2), utxo.count());

    // Consume one and produce one new
    const txh3 = [_]u8{3} ** 32;
    const in3 = TxIn{ .tx_hash = txh3, .index = 0 };

    const consumed = [_]TxIn{in1};
    var produced2 = [_]Produced{
        .{ .input = in3, .output = .{ .address = "addr3", .lovelace = 300 } },
    };

    var undo2 = try utxo.applyDelta(&consumed, &produced2);
    defer undo2.deinit();

    try std.testing.expectEqual(@as(usize, 2), utxo.count());

    // Roll back second delta
    utxo.rollbackDelta(&undo2);
    try std.testing.expectEqual(@as(usize, 2), utxo.count());

    // Roll back first delta
    utxo.rollbackDelta(&undo1);
    try std.testing.expectEqual(@as(usize, 0), utxo.count());
}

test "utxo apply multiple blocks then partial rollback then replay" {
    const alloc = std.heap.page_allocator;
    var u = UTxO.init(alloc);
    defer u.deinit();

    const txh1 = [_]u8{0x10} ** 32;
    const txh2 = [_]u8{0x20} ** 32;
    const txh3 = [_]u8{0x30} ** 32;

    // Block 1: produce 1
    var p1 = [_]Produced{.{ .input = .{ .tx_hash = txh1, .index = 0 }, .output = .{ .address = "a1", .lovelace = 100 } }};
    var undo1 = try u.applyDelta(&[_]TxIn{}, &p1);
    defer undo1.deinit();

    // Block 2: consume 1, produce 1
    var c2 = [_]TxIn{.{ .tx_hash = txh1, .index = 0 }};
    var p2 = [_]Produced{.{ .input = .{ .tx_hash = txh2, .index = 0 }, .output = .{ .address = "a2", .lovelace = 200 } }};
    var undo2 = try u.applyDelta(&c2, &p2);

    // Block 3: consume 1, produce 1
    var c3 = [_]TxIn{.{ .tx_hash = txh2, .index = 0 }};
    var p3 = [_]Produced{.{ .input = .{ .tx_hash = txh3, .index = 0 }, .output = .{ .address = "a3", .lovelace = 300 } }};
    var undo3 = try u.applyDelta(&c3, &p3);

    try std.testing.expectEqual(@as(usize, 1), u.count());
    try std.testing.expectEqual(@as(u64, 300), u.map.get(.{ .tx_hash = txh3, .index = 0 }).?.lovelace);

    // Rollback blocks 3, 2
    u.rollbackDelta(&undo3);
    undo3.deinit();
    u.rollbackDelta(&undo2);
    undo2.deinit();

    try std.testing.expectEqual(@as(usize, 1), u.count());
    try std.testing.expectEqual(@as(u64, 100), u.map.get(.{ .tx_hash = txh1, .index = 0 }).?.lovelace);

    // Replay blocks 2, 3
    var p2r = [_]Produced{.{ .input = .{ .tx_hash = txh2, .index = 0 }, .output = .{ .address = "a2", .lovelace = 200 } }};
    var c2r = [_]TxIn{.{ .tx_hash = txh1, .index = 0 }};
    var undo2r = try u.applyDelta(&c2r, &p2r);
    defer undo2r.deinit();

    var p3r = [_]Produced{.{ .input = .{ .tx_hash = txh3, .index = 0 }, .output = .{ .address = "a3", .lovelace = 300 } }};
    var c3r = [_]TxIn{.{ .tx_hash = txh2, .index = 0 }};
    var undo3r = try u.applyDelta(&c3r, &p3r);
    defer undo3r.deinit();

    // Identical final state
    try std.testing.expectEqual(@as(usize, 1), u.count());
    try std.testing.expectEqual(@as(u64, 300), u.map.get(.{ .tx_hash = txh3, .index = 0 }).?.lovelace);
}

test "utxo undo records all mutations" {
    const alloc = std.heap.page_allocator;
    var u = UTxO.init(alloc);
    defer u.deinit();

    const txh1 = [_]u8{0x01} ** 32;
    // Produce 3
    var p = [_]Produced{
        .{ .input = .{ .tx_hash = txh1, .index = 0 }, .output = .{ .address = "a", .lovelace = 10 } },
        .{ .input = .{ .tx_hash = txh1, .index = 1 }, .output = .{ .address = "b", .lovelace = 20 } },
        .{ .input = .{ .tx_hash = txh1, .index = 2 }, .output = .{ .address = "c", .lovelace = 30 } },
    };
    var undo1 = try u.applyDelta(&[_]TxIn{}, &p);
    defer undo1.deinit();
    try std.testing.expectEqual(@as(usize, 3), undo1.entries.items.len);

    // Consume 2, produce 1
    const txh2 = [_]u8{0x02} ** 32;
    var c = [_]TxIn{ .{ .tx_hash = txh1, .index = 0 }, .{ .tx_hash = txh1, .index = 1 } };
    var p2 = [_]Produced{.{ .input = .{ .tx_hash = txh2, .index = 0 }, .output = .{ .address = "d", .lovelace = 30 } }};
    var undo2 = try u.applyDelta(&c, &p2);
    defer undo2.deinit();
    // 2 removals + 1 insertion = 3
    try std.testing.expectEqual(@as(usize, 3), undo2.entries.items.len);
}

test "utxo empty delta is no-op" {
    const alloc = std.heap.page_allocator;
    var u = UTxO.init(alloc);
    defer u.deinit();

    var undo = try u.applyDelta(&[_]TxIn{}, &[_]Produced{});
    defer undo.deinit();
    try std.testing.expectEqual(@as(usize, 0), u.count());
    try std.testing.expectEqual(@as(usize, 0), undo.entries.items.len);
}

test "utxo consuming non-existent input is non-fatal" {
    const alloc = std.heap.page_allocator;
    var u = UTxO.init(alloc);
    defer u.deinit();

    var c = [_]TxIn{.{ .tx_hash = [_]u8{0xFF} ** 32, .index = 0 }};
    var undo = try u.applyDelta(&c, &[_]Produced{});
    defer undo.deinit();
    try std.testing.expectEqual(@as(usize, 0), u.count());
    try std.testing.expectEqual(@as(usize, 0), undo.entries.items.len);
}
