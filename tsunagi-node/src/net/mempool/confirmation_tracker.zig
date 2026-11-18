const std = @import("std");

/// A transaction awaiting block inclusion.
pub const PendingTx = struct {
    txid_hex: [64]u8,
    received_unix: i64,
    inputs: u32,
    outputs: u32,
    fee: ?u64,
    has_metadata: bool,
    size_bytes: u32,
};

/// A transaction that was found in a block after being submitted locally.
pub const ConfirmedTx = struct {
    txid_hex: [64]u8,
    received_unix: i64,
    confirmed_unix: i64,
    confirmation_seconds: i64,
    block_no: u64,
    slot: u64,
    inputs: u32,
    outputs: u32,
    fee: ?u64,
    has_metadata: bool,
    size_bytes: u32,
};

pub const PENDING_CAPACITY: u32 = 256;
pub const CONFIRMED_CAPACITY: u32 = 256;

/// Bounded, local-only confirmation tracker.
/// Pending uses a bounded array (oldest-first, shift on remove).
/// Confirmed uses a ring buffer (newest-first retrieval).
pub const ConfirmationTracker = struct {
    pending: [PENDING_CAPACITY]PendingTx = undefined,
    pending_len: u32 = 0,
    confirmed: [CONFIRMED_CAPACITY]ConfirmedTx = undefined,
    confirmed_head: u32 = 0,
    confirmed_len: u32 = 0,

    pub fn init() ConfirmationTracker {
        return .{};
    }

    /// Add a newly submitted tx to pending set.
    /// If pending is full, evict oldest (index 0).
    pub fn addPending(self: *ConfirmationTracker, tx: PendingTx) void {
        if (self.pending_len >= PENDING_CAPACITY) {
            // Shift left by 1 — evict oldest
            var i: u32 = 1;
            while (i < PENDING_CAPACITY) : (i += 1) {
                self.pending[i - 1] = self.pending[i];
            }
            self.pending_len = PENDING_CAPACITY - 1;
        }
        self.pending[self.pending_len] = tx;
        self.pending_len += 1;
    }

    /// Look up a pending tx by txid. Returns copy if found.
    pub fn lookupPendingByTxid(self: *const ConfirmationTracker, txid_hex: [64]u8) ?PendingTx {
        var i: u32 = 0;
        while (i < self.pending_len) : (i += 1) {
            if (std.mem.eql(u8, &self.pending[i].txid_hex, &txid_hex)) {
                return self.pending[i];
            }
        }
        return null;
    }

    /// Mark a pending tx as confirmed. Removes from pending,
    /// appends to confirmed ring buffer.
    /// Returns the ConfirmedTx if found in pending, null otherwise.
    pub fn markConfirmed(
        self: *ConfirmationTracker,
        txid_hex: [64]u8,
        block_no: u64,
        slot: u64,
        confirmed_unix: i64,
    ) ?ConfirmedTx {
        // Find in pending
        var found_idx: ?u32 = null;
        var i: u32 = 0;
        while (i < self.pending_len) : (i += 1) {
            if (std.mem.eql(u8, &self.pending[i].txid_hex, &txid_hex)) {
                found_idx = i;
                break;
            }
        }
        const idx = found_idx orelse return null;
        const p = self.pending[idx];

        // Build confirmed entry
        const c = ConfirmedTx{
            .txid_hex = p.txid_hex,
            .received_unix = p.received_unix,
            .confirmed_unix = confirmed_unix,
            .confirmation_seconds = confirmed_unix - p.received_unix,
            .block_no = block_no,
            .slot = slot,
            .inputs = p.inputs,
            .outputs = p.outputs,
            .fee = p.fee,
            .has_metadata = p.has_metadata,
            .size_bytes = p.size_bytes,
        };

        // Remove from pending (shift left)
        var j: u32 = idx + 1;
        while (j < self.pending_len) : (j += 1) {
            self.pending[j - 1] = self.pending[j];
        }
        self.pending_len -= 1;

        // Append to confirmed ring buffer
        self.confirmed[self.confirmed_head] = c;
        self.confirmed_head = (self.confirmed_head + 1) % CONFIRMED_CAPACITY;
        if (self.confirmed_len < CONFIRMED_CAPACITY) {
            self.confirmed_len += 1;
        }

        return c;
    }

    /// Get pending txs (oldest first). Returns count written.
    pub fn getPending(self: *const ConfirmationTracker, buf: []PendingTx, max: u32) u32 {
        const n = @min(self.pending_len, @min(max, @as(u32, @intCast(buf.len))));
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            buf[i] = self.pending[i];
        }
        return n;
    }

    /// Get recent confirmed txs (newest first). Returns count written.
    pub fn getRecentConfirmed(self: *const ConfirmationTracker, buf: []ConfirmedTx, max: u32) u32 {
        const n = @min(self.confirmed_len, @min(max, @as(u32, @intCast(buf.len))));
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const idx = (self.confirmed_head + CONFIRMED_CAPACITY - 1 - i) % CONFIRMED_CAPACITY;
            buf[i] = self.confirmed[idx];
        }
        return n;
    }

    pub fn pendingCount(self: *const ConfirmationTracker) u32 {
        return self.pending_len;
    }

    pub fn confirmedCount(self: *const ConfirmationTracker) u32 {
        return self.confirmed_len;
    }
};

// ── Inline Tests ──────────────────────────────────────────

fn testPending(txid_byte: u8, ts: i64) PendingTx {
    return .{
        .txid_hex = [_]u8{txid_byte} ** 64,
        .received_unix = ts,
        .inputs = 2,
        .outputs = 3,
        .fee = 170000,
        .has_metadata = false,
        .size_bytes = 400,
    };
}

test "init returns empty tracker" {
    const t = ConfirmationTracker.init();
    try std.testing.expectEqual(@as(u32, 0), t.pendingCount());
    try std.testing.expectEqual(@as(u32, 0), t.confirmedCount());
}

test "addPending and pendingCount" {
    var t = ConfirmationTracker.init();
    t.addPending(testPending('a', 1000));
    try std.testing.expectEqual(@as(u32, 1), t.pendingCount());
    t.addPending(testPending('b', 2000));
    try std.testing.expectEqual(@as(u32, 2), t.pendingCount());
}

test "lookupPendingByTxid finds entry" {
    var t = ConfirmationTracker.init();
    t.addPending(testPending('a', 1000));
    t.addPending(testPending('b', 2000));
    t.addPending(testPending('c', 3000));

    const found = t.lookupPendingByTxid([_]u8{'b'} ** 64);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(i64, 2000), found.?.received_unix);

    const miss = t.lookupPendingByTxid([_]u8{'z'} ** 64);
    try std.testing.expect(miss == null);
}

test "markConfirmed moves from pending to confirmed" {
    var t = ConfirmationTracker.init();
    t.addPending(testPending('a', 1000));
    t.addPending(testPending('b', 2000));

    const c = t.markConfirmed([_]u8{'a'} ** 64, 500, 10000, 1030);
    try std.testing.expect(c != null);
    try std.testing.expectEqual(@as(i64, 30), c.?.confirmation_seconds);
    try std.testing.expectEqual(@as(u64, 500), c.?.block_no);
    try std.testing.expectEqual(@as(u64, 10000), c.?.slot);
    try std.testing.expectEqual(@as(i64, 1000), c.?.received_unix);
    try std.testing.expectEqual(@as(i64, 1030), c.?.confirmed_unix);

    // Pending should now only have 'b'
    try std.testing.expectEqual(@as(u32, 1), t.pendingCount());
    try std.testing.expectEqual(@as(u32, 1), t.confirmedCount());
    try std.testing.expect(t.lookupPendingByTxid([_]u8{'a'} ** 64) == null);
    try std.testing.expect(t.lookupPendingByTxid([_]u8{'b'} ** 64) != null);
}

test "markConfirmed returns null for unknown txid" {
    var t = ConfirmationTracker.init();
    t.addPending(testPending('a', 1000));

    const c = t.markConfirmed([_]u8{'z'} ** 64, 500, 10000, 1030);
    try std.testing.expect(c == null);
    try std.testing.expectEqual(@as(u32, 1), t.pendingCount());
    try std.testing.expectEqual(@as(u32, 0), t.confirmedCount());
}

test "confirmed ring buffer wraps at capacity" {
    var t = ConfirmationTracker.init();

    // Fill confirmed ring buffer beyond capacity
    var i: u32 = 0;
    while (i < CONFIRMED_CAPACITY + 5) : (i += 1) {
        const byte: u8 = @intCast(i % 256);
        t.addPending(testPending(byte, @intCast(i * 100)));
        _ = t.markConfirmed(
            [_]u8{byte} ** 64,
            @intCast(i + 1000),
            @intCast(i * 200),
            @intCast(i * 100 + 30),
        );
    }

    try std.testing.expectEqual(@as(u32, 0), t.pendingCount());
    try std.testing.expectEqual(CONFIRMED_CAPACITY, t.confirmedCount());

    // Newest confirmed should be the last one added
    var buf: [4]ConfirmedTx = undefined;
    const n = t.getRecentConfirmed(&buf, 4);
    try std.testing.expectEqual(@as(u32, 4), n);

    const last_i = CONFIRMED_CAPACITY + 4;
    try std.testing.expectEqual(@as(i64, last_i * 100 + 30), buf[0].confirmed_unix);
    try std.testing.expectEqual(@as(u64, last_i + 1000), buf[0].block_no);
}

test "getPending returns oldest first" {
    var t = ConfirmationTracker.init();
    t.addPending(testPending('a', 1000));
    t.addPending(testPending('b', 2000));
    t.addPending(testPending('c', 3000));

    var buf: [10]PendingTx = undefined;
    const n = t.getPending(&buf, 10);
    try std.testing.expectEqual(@as(u32, 3), n);
    try std.testing.expectEqual(@as(i64, 1000), buf[0].received_unix);
    try std.testing.expectEqual(@as(i64, 2000), buf[1].received_unix);
    try std.testing.expectEqual(@as(i64, 3000), buf[2].received_unix);
}

test "pending evicts oldest when full" {
    var t = ConfirmationTracker.init();

    // Fill to capacity
    var i: u32 = 0;
    while (i < PENDING_CAPACITY) : (i += 1) {
        t.addPending(testPending(@intCast(i % 256), @intCast(i * 100)));
    }
    try std.testing.expectEqual(PENDING_CAPACITY, t.pendingCount());

    // Add one more — should evict oldest (i=0)
    t.addPending(testPending(0xff, 99999));
    try std.testing.expectEqual(PENDING_CAPACITY, t.pendingCount());

    // First entry should now be i=1 (i=0 was evicted)
    var buf: [1]PendingTx = undefined;
    _ = t.getPending(&buf, 1);
    try std.testing.expectEqual(@as(i64, 100), buf[0].received_unix);

    // Last entry should be the new one
    try std.testing.expect(t.lookupPendingByTxid([_]u8{0xff} ** 64) != null);
}
