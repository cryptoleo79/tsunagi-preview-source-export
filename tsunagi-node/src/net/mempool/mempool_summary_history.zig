const std = @import("std");
const mempool_decoder = @import("mempool_decoder.zig");

pub const MempoolTxSummary = mempool_decoder.MempoolTxSummary;

/// Capacity of the ring buffer — stores the most recent N decoded tx summaries.
pub const CAPACITY: u32 = 128;

/// Fixed-capacity FIFO ring buffer for recent decoded mempool tx summaries.
/// Deterministic, bounded memory, no dynamic resizing.
pub const MempoolSummaryStore = struct {
    entries: [CAPACITY]MempoolTxSummary = undefined,
    head: u32 = 0,
    len: u32 = 0,

    pub fn init() MempoolSummaryStore {
        return .{};
    }

    /// Append a new summary. Overwrites oldest when full.
    pub fn append(self: *MempoolSummaryStore, summary: MempoolTxSummary) void {
        self.entries[self.head] = summary;
        self.head = (self.head + 1) % CAPACITY;
        if (self.len < CAPACITY) {
            self.len += 1;
        }
    }

    /// Number of entries currently stored.
    pub fn count(self: *const MempoolSummaryStore) u32 {
        return self.len;
    }

    /// Get the most recent entry, or null if empty.
    pub fn latest(self: *const MempoolSummaryStore) ?MempoolTxSummary {
        if (self.len == 0) return null;
        const idx = (self.head + CAPACITY - 1) % CAPACITY;
        return self.entries[idx];
    }

    /// Copy up to `max_count` recent entries into `buf`, newest first.
    /// Returns the number of entries written.
    pub fn getRecent(self: *const MempoolSummaryStore, buf: []MempoolTxSummary, max_count: u32) u32 {
        const n = @min(self.len, @min(max_count, @as(u32, @intCast(buf.len))));
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const idx = (self.head + CAPACITY - 1 - i) % CAPACITY;
            buf[i] = self.entries[idx];
        }
        return n;
    }
};

// ── Inline Tests ──────────────────────────────────────────

fn testSummary(txid_byte: u8, ts: i64, inputs: u32, outputs: u32) MempoolTxSummary {
    return .{
        .txid_hex = [_]u8{txid_byte} ** 64,
        .inputs = inputs,
        .outputs = outputs,
        .fee = 170000,
        .has_metadata = false,
        .size_bytes = 400,
        .received_unix = ts,
    };
}

test "init returns empty store" {
    const s = MempoolSummaryStore.init();
    try std.testing.expectEqual(@as(u32, 0), s.count());
    try std.testing.expect(s.latest() == null);
}

test "append and count" {
    var s = MempoolSummaryStore.init();
    s.append(testSummary('a', 1000, 2, 3));
    try std.testing.expectEqual(@as(u32, 1), s.count());
    s.append(testSummary('b', 2000, 1, 2));
    try std.testing.expectEqual(@as(u32, 2), s.count());
}

test "latest returns newest entry" {
    var s = MempoolSummaryStore.init();
    s.append(testSummary('a', 1000, 2, 3));
    s.append(testSummary('b', 2000, 1, 2));
    const l = s.latest().?;
    try std.testing.expectEqual(@as(i64, 2000), l.received_unix);
    try std.testing.expectEqual(@as(u32, 1), l.inputs);
    try std.testing.expectEqual(@as(u32, 2), l.outputs);
    try std.testing.expectEqual(@as(u8, 'b'), l.txid_hex[0]);
}

test "getRecent returns newest first" {
    var s = MempoolSummaryStore.init();
    s.append(testSummary('a', 1000, 2, 3));
    s.append(testSummary('b', 2000, 1, 2));
    s.append(testSummary('c', 3000, 4, 5));

    var buf: [10]MempoolTxSummary = undefined;
    const n = s.getRecent(&buf, 10);
    try std.testing.expectEqual(@as(u32, 3), n);
    try std.testing.expectEqual(@as(i64, 3000), buf[0].received_unix);
    try std.testing.expectEqual(@as(i64, 2000), buf[1].received_unix);
    try std.testing.expectEqual(@as(i64, 1000), buf[2].received_unix);
}

test "ring buffer wraps at capacity" {
    var s = MempoolSummaryStore.init();
    var i: u32 = 0;
    while (i < CAPACITY + 5) : (i += 1) {
        s.append(testSummary(@intCast(i % 256), @intCast(i * 100), i % 5, i % 8));
    }
    try std.testing.expectEqual(CAPACITY, s.count());

    const l = s.latest().?;
    try std.testing.expectEqual(@as(i64, (CAPACITY + 4) * 100), l.received_unix);

    // Oldest accessible should be entry #5 (0-4 were overwritten)
    var buf: [CAPACITY]MempoolTxSummary = undefined;
    const n = s.getRecent(&buf, CAPACITY);
    try std.testing.expectEqual(CAPACITY, n);
    try std.testing.expectEqual(@as(i64, (CAPACITY + 4) * 100), buf[0].received_unix);
    try std.testing.expectEqual(@as(i64, 5 * 100), buf[n - 1].received_unix);
}
