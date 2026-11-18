const std = @import("std");
const tx_decoder = @import("tx_decoder.zig");

pub const BlockDecodeSummary = tx_decoder.BlockDecodeSummary;
pub const TxSummary = tx_decoder.TxSummary;

/// Capacity of the ring buffer — stores the most recent N block decode summaries.
pub const CAPACITY: u32 = 50;

/// Fixed-capacity FIFO ring buffer for recent block decode summaries.
/// Deterministic, bounded memory, no dynamic resizing.
pub const TxSummaryHistory = struct {
    entries: [CAPACITY]BlockDecodeSummary = undefined,
    head: u32 = 0,
    len: u32 = 0,

    pub fn init() TxSummaryHistory {
        return .{};
    }

    /// Append a new block decode summary. Overwrites oldest when full.
    pub fn append(self: *TxSummaryHistory, summary: BlockDecodeSummary) void {
        self.entries[self.head] = summary;
        self.head = (self.head + 1) % CAPACITY;
        if (self.len < CAPACITY) {
            self.len += 1;
        }
    }

    /// Number of entries currently stored.
    pub fn count(self: *const TxSummaryHistory) u32 {
        return self.len;
    }

    /// Get the most recent entry, or null if empty.
    pub fn latest(self: *const TxSummaryHistory) ?BlockDecodeSummary {
        if (self.len == 0) return null;
        const idx = (self.head + CAPACITY - 1) % CAPACITY;
        return self.entries[idx];
    }

    /// Copy up to `max_count` recent entries into `buf`, newest first.
    /// Returns the number of entries written.
    pub fn getRecent(self: *const TxSummaryHistory, buf: []BlockDecodeSummary, max_count: u32) u32 {
        const n = @min(self.len, @min(max_count, @as(u32, @intCast(buf.len))));
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const idx = (self.head + CAPACITY - 1 - i) % CAPACITY;
            buf[i] = self.entries[idx];
        }
        return n;
    }

    /// Look up a block decode summary by block number.
    pub fn lookupByBlock(self: *const TxSummaryHistory, block_no: u64) ?BlockDecodeSummary {
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

fn testSummary(slot: u64, block_no: u64, tx_count: u32) BlockDecodeSummary {
    return .{
        .slot = slot,
        .block_no = block_no,
        .block_hash_hex = [_]u8{'a'} ** 64,
        .tx_count = tx_count,
        .txs = undefined,
        .txs_len = 0,
        .truncated = false,
        .timestamp_unix = @intCast(slot),
    };
}

test "init returns empty history" {
    const h = TxSummaryHistory.init();
    try std.testing.expectEqual(@as(u32, 0), h.count());
    try std.testing.expect(h.latest() == null);
}

test "append and count" {
    var h = TxSummaryHistory.init();
    h.append(testSummary(100, 1, 3));
    try std.testing.expectEqual(@as(u32, 1), h.count());
    h.append(testSummary(200, 2, 5));
    try std.testing.expectEqual(@as(u32, 2), h.count());
}

test "latest returns newest entry" {
    var h = TxSummaryHistory.init();
    h.append(testSummary(100, 1, 3));
    h.append(testSummary(200, 2, 5));
    const l = h.latest().?;
    try std.testing.expectEqual(@as(u64, 200), l.slot);
    try std.testing.expectEqual(@as(u64, 2), l.block_no);
    try std.testing.expectEqual(@as(u32, 5), l.tx_count);
}

test "getRecent returns newest first" {
    var h = TxSummaryHistory.init();
    h.append(testSummary(100, 1, 3));
    h.append(testSummary(200, 2, 5));
    h.append(testSummary(300, 3, 7));

    var buf: [10]BlockDecodeSummary = undefined;
    const n = h.getRecent(&buf, 10);
    try std.testing.expectEqual(@as(u32, 3), n);
    try std.testing.expectEqual(@as(u64, 300), buf[0].slot);
    try std.testing.expectEqual(@as(u64, 200), buf[1].slot);
    try std.testing.expectEqual(@as(u64, 100), buf[2].slot);
}

test "ring buffer wraps at capacity" {
    var h = TxSummaryHistory.init();
    var i: u64 = 0;
    while (i < CAPACITY + 5) : (i += 1) {
        h.append(testSummary(i * 100, i, @intCast(i % 10)));
    }
    try std.testing.expectEqual(CAPACITY, h.count());

    const l = h.latest().?;
    try std.testing.expectEqual((CAPACITY + 4) * 100, l.slot);

    var buf: [CAPACITY]BlockDecodeSummary = undefined;
    const n = h.getRecent(&buf, CAPACITY);
    try std.testing.expectEqual(CAPACITY, n);
    try std.testing.expectEqual((CAPACITY + 4) * 100, buf[0].slot);
    try std.testing.expectEqual(@as(u64, 5 * 100), buf[n - 1].slot);
}
