const std = @import("std");

/// Capacity of the ring buffer — stores the most recent N block deltas.
pub const CAPACITY: u32 = 200;

/// Summary of a single block's ledger delta.
/// All fields are value types — no heap allocations.
pub const BlockDelta = struct {
    slot: u64,
    block_no: u64,
    block_hash_hex: [64]u8,
    tx_count: u32,
    utxo_consumed: u32,
    utxo_produced: u32,
    utxo_delta: i32,
    timestamp_unix: i64,
};

/// Fixed-capacity FIFO ring buffer for recent block deltas.
/// Deterministic, bounded memory, no dynamic resizing.
pub const DeltaHistory = struct {
    entries: [CAPACITY]BlockDelta = undefined,
    head: u32 = 0,
    len: u32 = 0,

    pub fn init() DeltaHistory {
        return .{};
    }

    /// Append a new delta to the ring buffer.
    /// Overwrites the oldest entry when full.
    pub fn append(self: *DeltaHistory, delta: BlockDelta) void {
        self.entries[self.head] = delta;
        self.head = (self.head + 1) % CAPACITY;
        if (self.len < CAPACITY) {
            self.len += 1;
        }
    }

    /// Number of entries currently stored.
    pub fn count(self: *const DeltaHistory) u32 {
        return self.len;
    }

    /// Copy up to `max_count` recent entries into `buf`, newest first.
    /// Returns the number of entries written.
    pub fn getRecent(self: *const DeltaHistory, buf: []BlockDelta, max_count: u32) u32 {
        const n = @min(self.len, @min(max_count, @as(u32, @intCast(buf.len))));
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            // Walk backwards from head
            const idx = (self.head + CAPACITY - 1 - i) % CAPACITY;
            buf[i] = self.entries[idx];
        }
        return n;
    }

    /// Get the most recent entry, or null if empty.
    pub fn latest(self: *const DeltaHistory) ?BlockDelta {
        if (self.len == 0) return null;
        const idx = (self.head + CAPACITY - 1) % CAPACITY;
        return self.entries[idx];
    }

    /// Look up a block by block number in the retained history.
    /// Returns null if the block is not in the ring buffer.
    pub fn lookupByBlock(self: *const DeltaHistory, block_no: u64) ?BlockDelta {
        if (self.len == 0) return null;
        var i: u32 = 0;
        while (i < self.len) : (i += 1) {
            const idx = (self.head + CAPACITY - 1 - i) % CAPACITY;
            if (self.entries[idx].block_no == block_no) {
                return self.entries[idx];
            }
        }
        return null;
    }
};

// ── Inline Tests ──────────────────────────────────────────

fn testDelta(slot: u64, block_no: u64, delta: i32) BlockDelta {
    return .{
        .slot = slot,
        .block_no = block_no,
        .block_hash_hex = [_]u8{'a'} ** 64,
        .tx_count = 1,
        .utxo_consumed = if (delta < 0) @intCast(-delta) else 0,
        .utxo_produced = if (delta > 0) @intCast(delta) else 0,
        .utxo_delta = delta,
        .timestamp_unix = @intCast(slot),
    };
}

test "init returns empty history" {
    const h = DeltaHistory.init();
    try std.testing.expectEqual(@as(u32, 0), h.count());
    try std.testing.expect(h.latest() == null);
}

test "append and count" {
    var h = DeltaHistory.init();
    h.append(testDelta(100, 1, 3));
    try std.testing.expectEqual(@as(u32, 1), h.count());
    h.append(testDelta(200, 2, -1));
    try std.testing.expectEqual(@as(u32, 2), h.count());
}

test "latest returns newest entry" {
    var h = DeltaHistory.init();
    h.append(testDelta(100, 1, 3));
    h.append(testDelta(200, 2, -1));
    const l = h.latest().?;
    try std.testing.expectEqual(@as(u64, 200), l.slot);
    try std.testing.expectEqual(@as(u64, 2), l.block_no);
    try std.testing.expectEqual(@as(i32, -1), l.utxo_delta);
}

test "getRecent returns newest first" {
    var h = DeltaHistory.init();
    h.append(testDelta(100, 1, 3));
    h.append(testDelta(200, 2, -1));
    h.append(testDelta(300, 3, 5));

    var buf: [10]BlockDelta = undefined;
    const n = h.getRecent(&buf, 10);
    try std.testing.expectEqual(@as(u32, 3), n);
    try std.testing.expectEqual(@as(u64, 300), buf[0].slot);
    try std.testing.expectEqual(@as(u64, 200), buf[1].slot);
    try std.testing.expectEqual(@as(u64, 100), buf[2].slot);
}

test "getRecent respects max_count" {
    var h = DeltaHistory.init();
    h.append(testDelta(100, 1, 3));
    h.append(testDelta(200, 2, -1));
    h.append(testDelta(300, 3, 5));

    var buf: [10]BlockDelta = undefined;
    const n = h.getRecent(&buf, 2);
    try std.testing.expectEqual(@as(u32, 2), n);
    try std.testing.expectEqual(@as(u64, 300), buf[0].slot);
    try std.testing.expectEqual(@as(u64, 200), buf[1].slot);
}

test "lookupByBlock finds existing entry" {
    var h = DeltaHistory.init();
    h.append(testDelta(100, 1, 3));
    h.append(testDelta(200, 2, -1));
    h.append(testDelta(300, 3, 5));

    const found = h.lookupByBlock(2).?;
    try std.testing.expectEqual(@as(u64, 200), found.slot);
    try std.testing.expectEqual(@as(i32, -1), found.utxo_delta);

    try std.testing.expect(h.lookupByBlock(999) == null);
}

test "ring buffer wraps at capacity" {
    var h = DeltaHistory.init();
    // Fill to capacity + 5 (overwrites first 5)
    var i: u64 = 0;
    while (i < CAPACITY + 5) : (i += 1) {
        h.append(testDelta(i * 100, i, @intCast(i % 7)));
    }
    try std.testing.expectEqual(CAPACITY, h.count());

    // Latest should be the last appended
    const l = h.latest().?;
    try std.testing.expectEqual((CAPACITY + 4) * 100, l.slot);

    // Oldest accessible should be entry #5 (0-4 were overwritten)
    var buf: [CAPACITY]BlockDelta = undefined;
    const n = h.getRecent(&buf, CAPACITY);
    try std.testing.expectEqual(CAPACITY, n);
    // First in buf is newest
    try std.testing.expectEqual((CAPACITY + 4) * 100, buf[0].slot);
    // Last in buf is oldest surviving
    try std.testing.expectEqual(@as(u64, 5 * 100), buf[n - 1].slot);
}
