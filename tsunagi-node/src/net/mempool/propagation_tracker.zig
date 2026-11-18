const std = @import("std");

/// Observable stages a locally submitted tx passes through.
/// Derived from which nullable fields are populated on PropagationTx.
pub const PropagationStage = enum {
    local_submitted,
    block_observed,
    confirmed,
};

/// A transaction's propagation lifecycle record.
/// Fields start null and are filled as stages are observed.
pub const PropagationTx = struct {
    txid_hex: [64]u8,
    local_submitted_unix: i64,
    block_observed_unix: ?i64 = null,
    block_no: ?u64 = null,
    slot: ?u64 = null,
    confirmed_unix: ?i64 = null,
    confirmation_seconds: ?i64 = null,

    /// Derive current stage from populated fields.
    pub fn stage(self: *const PropagationTx) PropagationStage {
        if (self.confirmed_unix != null) return .confirmed;
        if (self.block_observed_unix != null) return .block_observed;
        return .local_submitted;
    }
};

pub const CAPACITY: u32 = 256;

/// Bounded ring buffer for transaction propagation lifecycle tracking.
/// Local observability only — records what this node has seen.
///
/// Duplicate policy: if addLocalSubmission is called with a txid that
/// already exists in the buffer, the existing entry is updated with
/// the new submission timestamp. This handles tx resubmissions without
/// creating duplicate entries. The entry retains any previously
/// observed block/confirmation state.
pub const PropagationTracker = struct {
    entries: [CAPACITY]PropagationTx = undefined,
    head: u32 = 0,
    len: u32 = 0,

    pub fn init() PropagationTracker {
        return .{};
    }

    /// Record a local tx submission. If the txid already exists,
    /// updates the submission timestamp (resubmission). Otherwise
    /// appends to the ring buffer, overwriting the oldest entry
    /// when full.
    pub fn addLocalSubmission(self: *PropagationTracker, tx: PropagationTx) void {
        // Check for existing entry with same txid
        if (self.lookupByTxid(tx.txid_hex)) |existing| {
            existing.local_submitted_unix = tx.local_submitted_unix;
            return;
        }
        self.entries[self.head] = tx;
        self.head = (self.head + 1) % CAPACITY;
        if (self.len < CAPACITY) {
            self.len += 1;
        }
    }

    /// Find an entry by txid. Returns a mutable pointer so callers
    /// can update fields in place. Returns null if not found.
    pub fn lookupByTxid(self: *PropagationTracker, txid_hex: [64]u8) ?*PropagationTx {
        if (self.len == 0) return null;
        var i: u32 = 0;
        while (i < self.len) : (i += 1) {
            const idx = (self.head + CAPACITY - 1 - i) % CAPACITY;
            if (std.mem.eql(u8, &self.entries[idx].txid_hex, &txid_hex)) {
                return &self.entries[idx];
            }
        }
        return null;
    }

    /// Mark a tx as observed in a block. Returns true if the txid
    /// was found and updated, false otherwise.
    pub fn markBlockObserved(
        self: *PropagationTracker,
        txid_hex: [64]u8,
        block_no: u64,
        slot: u64,
        ts: i64,
    ) bool {
        const entry = self.lookupByTxid(txid_hex) orelse return false;
        entry.block_observed_unix = ts;
        entry.block_no = block_no;
        entry.slot = slot;
        return true;
    }

    /// Mark a tx as confirmed. Returns true if the txid was found
    /// and updated, false otherwise.
    pub fn markConfirmed(
        self: *PropagationTracker,
        txid_hex: [64]u8,
        confirmed_unix: i64,
        confirmation_seconds: i64,
    ) bool {
        const entry = self.lookupByTxid(txid_hex) orelse return false;
        entry.confirmed_unix = confirmed_unix;
        entry.confirmation_seconds = confirmation_seconds;
        return true;
    }

    /// Copy up to `max` recent entries into `buf`, newest first.
    /// Returns the number of entries written.
    pub fn getRecent(self: *const PropagationTracker, buf: []PropagationTx, max: u32) u32 {
        const n = @min(self.len, @min(max, @as(u32, @intCast(buf.len))));
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const idx = (self.head + CAPACITY - 1 - i) % CAPACITY;
            buf[i] = self.entries[idx];
        }
        return n;
    }

    /// Number of entries currently stored.
    pub fn count(self: *const PropagationTracker) u32 {
        return self.len;
    }
};

// ── Inline Tests ──────────────────────────────────────────

fn testPropTx(txid_byte: u8, ts: i64) PropagationTx {
    return .{
        .txid_hex = [_]u8{txid_byte} ** 64,
        .local_submitted_unix = ts,
    };
}

/// Create a PropagationTx with a unique txid from a u32 index.
/// Encodes low byte at all positions, high byte at position 0.
fn testPropTxU32(i: u32, ts: i64) PropagationTx {
    var txid: [64]u8 = [_]u8{@intCast(i & 0xff)} ** 64;
    txid[0] = @intCast((i >> 8) & 0xff);
    return .{
        .txid_hex = txid,
        .local_submitted_unix = ts,
    };
}

test "init returns empty tracker" {
    const t = PropagationTracker.init();
    try std.testing.expectEqual(@as(u32, 0), t.count());
}

test "addLocalSubmission and count" {
    var t = PropagationTracker.init();
    t.addLocalSubmission(testPropTx('a', 1000));
    try std.testing.expectEqual(@as(u32, 1), t.count());
    t.addLocalSubmission(testPropTx('b', 2000));
    try std.testing.expectEqual(@as(u32, 2), t.count());
}

test "lookupByTxid finds entry" {
    var t = PropagationTracker.init();
    t.addLocalSubmission(testPropTx('a', 1000));
    t.addLocalSubmission(testPropTx('b', 2000));

    const found = t.lookupByTxid([_]u8{'b'} ** 64);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(i64, 2000), found.?.local_submitted_unix);
    try std.testing.expectEqual(PropagationStage.local_submitted, found.?.stage());

    const miss = t.lookupByTxid([_]u8{'z'} ** 64);
    try std.testing.expect(miss == null);
}

test "markBlockObserved updates existing entry" {
    var t = PropagationTracker.init();
    t.addLocalSubmission(testPropTx('a', 1000));

    const updated = t.markBlockObserved([_]u8{'a'} ** 64, 500, 10000, 1014);
    try std.testing.expect(updated);

    const entry = t.lookupByTxid([_]u8{'a'} ** 64).?;
    try std.testing.expectEqual(@as(i64, 1014), entry.block_observed_unix.?);
    try std.testing.expectEqual(@as(u64, 500), entry.block_no.?);
    try std.testing.expectEqual(@as(u64, 10000), entry.slot.?);
    try std.testing.expectEqual(PropagationStage.block_observed, entry.stage());

    // Unknown txid returns false
    const not_found = t.markBlockObserved([_]u8{'z'} ** 64, 500, 10000, 1014);
    try std.testing.expect(!not_found);
}

test "markConfirmed updates existing entry" {
    var t = PropagationTracker.init();
    t.addLocalSubmission(testPropTx('a', 1000));
    _ = t.markBlockObserved([_]u8{'a'} ** 64, 500, 10000, 1014);
    const updated = t.markConfirmed([_]u8{'a'} ** 64, 1030, 30);
    try std.testing.expect(updated);

    const entry = t.lookupByTxid([_]u8{'a'} ** 64).?;
    try std.testing.expectEqual(@as(i64, 1030), entry.confirmed_unix.?);
    try std.testing.expectEqual(@as(i64, 30), entry.confirmation_seconds.?);
    try std.testing.expectEqual(PropagationStage.confirmed, entry.stage());

    // Unknown txid returns false
    const not_found = t.markConfirmed([_]u8{'z'} ** 64, 1030, 30);
    try std.testing.expect(!not_found);
}

test "ring buffer wraps at capacity" {
    var t = PropagationTracker.init();
    // Use testPropTxU32 to avoid txid collisions beyond 256
    var i: u32 = 0;
    while (i < CAPACITY + 5) : (i += 1) {
        t.addLocalSubmission(testPropTxU32(i, @intCast(i * 100)));
    }
    try std.testing.expectEqual(CAPACITY, t.count());

    // Newest entry should be the last one added
    var buf: [4]PropagationTx = undefined;
    const n = t.getRecent(&buf, 4);
    try std.testing.expectEqual(@as(u32, 4), n);
    try std.testing.expectEqual(@as(i64, (CAPACITY + 4) * 100), buf[0].local_submitted_unix);

    // Oldest accessible should be entry #5 (0-4 were overwritten)
    var full_buf: [CAPACITY]PropagationTx = undefined;
    const m = t.getRecent(&full_buf, CAPACITY);
    try std.testing.expectEqual(CAPACITY, m);
    try std.testing.expectEqual(@as(i64, 5 * 100), full_buf[m - 1].local_submitted_unix);
}

test "duplicate local submission updates timestamp" {
    var t = PropagationTracker.init();
    t.addLocalSubmission(testPropTx('a', 1000));
    _ = t.markBlockObserved([_]u8{'a'} ** 64, 500, 10000, 1014);

    // Resubmit same txid with new timestamp
    t.addLocalSubmission(testPropTx('a', 2000));

    // Should still be 1 entry, not 2
    try std.testing.expectEqual(@as(u32, 1), t.count());

    // Timestamp updated, but block observed state preserved
    const entry = t.lookupByTxid([_]u8{'a'} ** 64).?;
    try std.testing.expectEqual(@as(i64, 2000), entry.local_submitted_unix);
    try std.testing.expectEqual(@as(i64, 1014), entry.block_observed_unix.?);
    try std.testing.expectEqual(PropagationStage.block_observed, entry.stage());
}

test "getRecent returns newest first" {
    var t = PropagationTracker.init();
    t.addLocalSubmission(testPropTx('a', 1000));
    t.addLocalSubmission(testPropTx('b', 2000));
    t.addLocalSubmission(testPropTx('c', 3000));

    var buf: [10]PropagationTx = undefined;
    const n = t.getRecent(&buf, 10);
    try std.testing.expectEqual(@as(u32, 3), n);
    try std.testing.expectEqual(@as(i64, 3000), buf[0].local_submitted_unix);
    try std.testing.expectEqual(@as(i64, 2000), buf[1].local_submitted_unix);
    try std.testing.expectEqual(@as(i64, 1000), buf[2].local_submitted_unix);
}
