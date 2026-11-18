const std = @import("std");
const tx_decoder = @import("tx_decoder.zig");

pub const TxSummary = tx_decoder.TxSummary;
pub const MAX_TX_PER_BLOCK = tx_decoder.MAX_TX_PER_BLOCK;

/// Capacity of the ring buffer — stores the most recent N block decode records.
pub const CAPACITY: u32 = 100;

/// Combined block record: delta fields + per-tx decode summaries.
/// All fields are value types — no heap allocations.
pub const StoredBlockDecode = struct {
    slot: u64,
    block_no: u64,
    block_hash_hex: [64]u8,
    tx_count: u32,
    utxo_consumed: u32,
    utxo_produced: u32,
    utxo_delta: i32,
    txs: [MAX_TX_PER_BLOCK]TxSummary,
    txs_len: u32,
    truncated: bool,
    timestamp_unix: i64,
};

/// Fixed-capacity FIFO ring buffer for recent block decode records.
/// Deterministic, bounded memory, no dynamic resizing.
pub const BlockDecodeStore = struct {
    entries: [CAPACITY]StoredBlockDecode = undefined,
    head: u32 = 0,
    len: u32 = 0,

    pub fn init() BlockDecodeStore {
        return .{};
    }

    /// Append a new block decode record. Overwrites oldest when full.
    pub fn append(self: *BlockDecodeStore, record: StoredBlockDecode) void {
        self.entries[self.head] = record;
        self.head = (self.head + 1) % CAPACITY;
        if (self.len < CAPACITY) {
            self.len += 1;
        }
    }

    /// Number of entries currently stored.
    pub fn count(self: *const BlockDecodeStore) u32 {
        return self.len;
    }

    /// Get the most recent entry, or null if empty.
    pub fn latest(self: *const BlockDecodeStore) ?StoredBlockDecode {
        if (self.len == 0) return null;
        const idx = (self.head + CAPACITY - 1) % CAPACITY;
        return self.entries[idx];
    }

    /// Copy up to `max_count` recent entries into `buf`, newest first.
    /// Returns the number of entries written.
    pub fn getRecent(self: *const BlockDecodeStore, buf: []StoredBlockDecode, max_count: u32) u32 {
        const n = @min(self.len, @min(max_count, @as(u32, @intCast(buf.len))));
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const idx = (self.head + CAPACITY - 1 - i) % CAPACITY;
            buf[i] = self.entries[idx];
        }
        return n;
    }

    /// Look up a block decode record by block number.
    /// Returns null if not found in the ring buffer.
    pub fn lookupByBlock(self: *const BlockDecodeStore, block_no: u64) ?StoredBlockDecode {
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

fn testRecord(slot: u64, block_no: u64, delta: i32, tx_count: u32) StoredBlockDecode {
    return .{
        .slot = slot,
        .block_no = block_no,
        .block_hash_hex = [_]u8{'a'} ** 64,
        .tx_count = tx_count,
        .utxo_consumed = if (delta < 0) @intCast(-delta) else 0,
        .utxo_produced = if (delta > 0) @intCast(delta) else 0,
        .utxo_delta = delta,
        .txs = undefined,
        .txs_len = 0,
        .truncated = false,
        .timestamp_unix = @intCast(slot),
    };
}

test "init returns empty store" {
    const s = BlockDecodeStore.init();
    try std.testing.expectEqual(@as(u32, 0), s.count());
    try std.testing.expect(s.latest() == null);
}

test "append and count" {
    var s = BlockDecodeStore.init();
    s.append(testRecord(100, 1, 3, 2));
    try std.testing.expectEqual(@as(u32, 1), s.count());
    s.append(testRecord(200, 2, -1, 5));
    try std.testing.expectEqual(@as(u32, 2), s.count());
}

test "latest returns newest entry" {
    var s = BlockDecodeStore.init();
    s.append(testRecord(100, 1, 3, 2));
    s.append(testRecord(200, 2, -1, 5));
    const l = s.latest().?;
    try std.testing.expectEqual(@as(u64, 200), l.slot);
    try std.testing.expectEqual(@as(u64, 2), l.block_no);
    try std.testing.expectEqual(@as(i32, -1), l.utxo_delta);
    try std.testing.expectEqual(@as(u32, 5), l.tx_count);
}

test "getRecent returns newest first" {
    var s = BlockDecodeStore.init();
    s.append(testRecord(100, 1, 3, 2));
    s.append(testRecord(200, 2, -1, 5));
    s.append(testRecord(300, 3, 5, 1));

    var buf: [10]StoredBlockDecode = undefined;
    const n = s.getRecent(&buf, 10);
    try std.testing.expectEqual(@as(u32, 3), n);
    try std.testing.expectEqual(@as(u64, 300), buf[0].slot);
    try std.testing.expectEqual(@as(u64, 200), buf[1].slot);
    try std.testing.expectEqual(@as(u64, 100), buf[2].slot);
}

test "getRecent respects max_count" {
    var s = BlockDecodeStore.init();
    s.append(testRecord(100, 1, 3, 2));
    s.append(testRecord(200, 2, -1, 5));
    s.append(testRecord(300, 3, 5, 1));

    var buf: [10]StoredBlockDecode = undefined;
    const n = s.getRecent(&buf, 2);
    try std.testing.expectEqual(@as(u32, 2), n);
    try std.testing.expectEqual(@as(u64, 300), buf[0].slot);
    try std.testing.expectEqual(@as(u64, 200), buf[1].slot);
}

test "lookupByBlock finds existing entry" {
    var s = BlockDecodeStore.init();
    s.append(testRecord(100, 1, 3, 2));
    s.append(testRecord(200, 2, -1, 5));
    s.append(testRecord(300, 3, 5, 1));

    const found = s.lookupByBlock(2).?;
    try std.testing.expectEqual(@as(u64, 200), found.slot);
    try std.testing.expectEqual(@as(i32, -1), found.utxo_delta);

    try std.testing.expect(s.lookupByBlock(999) == null);
}

test "ring buffer wraps at capacity" {
    var s = BlockDecodeStore.init();
    var i: u64 = 0;
    while (i < CAPACITY + 5) : (i += 1) {
        s.append(testRecord(i * 100, i, @intCast(i % 7), @intCast(i % 10)));
    }
    try std.testing.expectEqual(CAPACITY, s.count());

    const l = s.latest().?;
    try std.testing.expectEqual((CAPACITY + 4) * 100, l.slot);

    // Oldest accessible should be entry #5 (0-4 were overwritten)
    var buf: [CAPACITY]StoredBlockDecode = undefined;
    const n = s.getRecent(&buf, CAPACITY);
    try std.testing.expectEqual(CAPACITY, n);
    try std.testing.expectEqual((CAPACITY + 4) * 100, buf[0].slot);
    try std.testing.expectEqual(@as(u64, 5 * 100), buf[n - 1].slot);
}
