const std = @import("std");

/// Lightweight metadata for a recently submitted mempool transaction.
/// No raw bytes retained — decode happens immediately at submission time.
pub const MempoolTx = struct {
    txid_hex: [64]u8,
    received_unix: i64,
    size_bytes: u32,
};

/// Capacity of the ring buffer — stores metadata for the most recent N submissions.
pub const CAPACITY: u32 = 256;

/// Fixed-capacity FIFO ring buffer for recent mempool tx metadata.
/// Deterministic, bounded memory, no dynamic resizing.
pub const MempoolBuffer = struct {
    entries: [CAPACITY]MempoolTx = undefined,
    head: u32 = 0,
    len: u32 = 0,

    pub fn init() MempoolBuffer {
        return .{};
    }

    /// Append a new entry. Overwrites oldest when full.
    pub fn append(self: *MempoolBuffer, tx: MempoolTx) void {
        self.entries[self.head] = tx;
        self.head = (self.head + 1) % CAPACITY;
        if (self.len < CAPACITY) {
            self.len += 1;
        }
    }

    /// Number of entries currently stored.
    pub fn count(self: *const MempoolBuffer) u32 {
        return self.len;
    }

    /// Get the most recent entry, or null if empty.
    pub fn latest(self: *const MempoolBuffer) ?MempoolTx {
        if (self.len == 0) return null;
        const idx = (self.head + CAPACITY - 1) % CAPACITY;
        return self.entries[idx];
    }

    /// Copy up to `max_count` recent entries into `buf`, newest first.
    /// Returns the number of entries written.
    pub fn getRecent(self: *const MempoolBuffer, buf: []MempoolTx, max_count: u32) u32 {
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

fn testTx(txid_byte: u8, ts: i64, size: u32) MempoolTx {
    return .{
        .txid_hex = [_]u8{txid_byte} ** 64,
        .received_unix = ts,
        .size_bytes = size,
    };
}

test "init returns empty buffer" {
    const b = MempoolBuffer.init();
    try std.testing.expectEqual(@as(u32, 0), b.count());
    try std.testing.expect(b.latest() == null);
}

test "append and count" {
    var b = MempoolBuffer.init();
    b.append(testTx('a', 1000, 400));
    try std.testing.expectEqual(@as(u32, 1), b.count());
    b.append(testTx('b', 2000, 500));
    try std.testing.expectEqual(@as(u32, 2), b.count());
}

test "latest returns newest entry" {
    var b = MempoolBuffer.init();
    b.append(testTx('a', 1000, 400));
    b.append(testTx('b', 2000, 500));
    const l = b.latest().?;
    try std.testing.expectEqual(@as(i64, 2000), l.received_unix);
    try std.testing.expectEqual(@as(u32, 500), l.size_bytes);
    try std.testing.expectEqual(@as(u8, 'b'), l.txid_hex[0]);
}

test "getRecent returns newest first" {
    var b = MempoolBuffer.init();
    b.append(testTx('a', 1000, 100));
    b.append(testTx('b', 2000, 200));
    b.append(testTx('c', 3000, 300));

    var buf: [10]MempoolTx = undefined;
    const n = b.getRecent(&buf, 10);
    try std.testing.expectEqual(@as(u32, 3), n);
    try std.testing.expectEqual(@as(i64, 3000), buf[0].received_unix);
    try std.testing.expectEqual(@as(i64, 2000), buf[1].received_unix);
    try std.testing.expectEqual(@as(i64, 1000), buf[2].received_unix);
}

test "ring buffer wraps at capacity" {
    var b = MempoolBuffer.init();
    var i: u32 = 0;
    while (i < CAPACITY + 5) : (i += 1) {
        b.append(testTx(@intCast(i % 256), @intCast(i * 100), i * 10));
    }
    try std.testing.expectEqual(CAPACITY, b.count());

    const l = b.latest().?;
    try std.testing.expectEqual(@as(i64, (CAPACITY + 4) * 100), l.received_unix);

    // Oldest accessible should be entry #5 (0-4 were overwritten)
    var buf: [CAPACITY]MempoolTx = undefined;
    const n = b.getRecent(&buf, CAPACITY);
    try std.testing.expectEqual(CAPACITY, n);
    try std.testing.expectEqual(@as(i64, (CAPACITY + 4) * 100), buf[0].received_unix);
    try std.testing.expectEqual(@as(i64, 5 * 100), buf[n - 1].received_unix);
}
