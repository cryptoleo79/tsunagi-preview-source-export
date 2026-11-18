const std = @import("std");

/// Bounded in-memory chain index for recent block metadata.
/// Fixed-size ring buffer. No allocator. No IO.
/// Supports rollback via pop() and lookup by hash/slot/block_no.

pub const CAPACITY: u32 = 200;

pub const ChainEntry = struct {
    slot: u64,
    block_no: u64,
    hash: [32]u8,
    prev_hash: [32]u8,
};

pub const ChainIndex = struct {
    entries: [CAPACITY]ChainEntry = undefined,
    head: u32 = 0,
    len: u32 = 0,

    pub fn init() ChainIndex {
        return .{};
    }

    pub fn append(self: *ChainIndex, entry: ChainEntry) void {
        self.entries[self.head] = entry;
        self.head = (self.head + 1) % CAPACITY;
        if (self.len < CAPACITY) self.len += 1;
    }

    /// Remove most recent entry (for rollback). Returns the removed entry or null if empty.
    pub fn pop(self: *ChainIndex) ?ChainEntry {
        if (self.len == 0) return null;
        const idx = if (self.head == 0) CAPACITY - 1 else self.head - 1;
        const entry = self.entries[idx];
        self.head = idx;
        self.len -= 1;
        return entry;
    }

    pub fn latest(self: *const ChainIndex) ?ChainEntry {
        if (self.len == 0) return null;
        const idx = if (self.head == 0) CAPACITY - 1 else self.head - 1;
        return self.entries[idx];
    }

    pub fn count(self: *const ChainIndex) u32 {
        return self.len;
    }

    /// Returns recent entries newest-first into caller buffer. Returns count written.
    pub fn getRecent(self: *const ChainIndex, buf: []ChainEntry, max: u32) u32 {
        const n = @min(self.len, max, @as(u32, @intCast(buf.len)));
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const raw = if (self.head >= i + 1) self.head - i - 1 else CAPACITY - (i + 1 - self.head);
            buf[i] = self.entries[raw];
        }
        return n;
    }

    pub fn lookupByHash(self: *const ChainIndex, hash: [32]u8) ?ChainEntry {
        if (self.len == 0) return null;
        var i: u32 = 0;
        while (i < self.len) : (i += 1) {
            const raw = if (self.head >= i + 1) self.head - i - 1 else CAPACITY - (i + 1 - self.head);
            if (std.mem.eql(u8, &self.entries[raw].hash, &hash)) return self.entries[raw];
        }
        return null;
    }

    pub fn lookupBySlot(self: *const ChainIndex, slot: u64) ?ChainEntry {
        if (self.len == 0) return null;
        var i: u32 = 0;
        while (i < self.len) : (i += 1) {
            const raw = if (self.head >= i + 1) self.head - i - 1 else CAPACITY - (i + 1 - self.head);
            if (self.entries[raw].slot == slot) return self.entries[raw];
        }
        return null;
    }

    pub fn lookupByBlockNo(self: *const ChainIndex, block_no: u64) ?ChainEntry {
        if (self.len == 0) return null;
        var i: u32 = 0;
        while (i < self.len) : (i += 1) {
            const raw = if (self.head >= i + 1) self.head - i - 1 else CAPACITY - (i + 1 - self.head);
            if (self.entries[raw].block_no == block_no) return self.entries[raw];
        }
        return null;
    }

    /// Verify chain continuity: each entry's prev_hash == predecessor's hash.
    /// Returns the number of contiguous entries from latest backwards.
    pub fn contiguousDepth(self: *const ChainIndex) u32 {
        if (self.len <= 1) return self.len;
        var depth: u32 = 1;
        var i: u32 = 0;
        while (i + 1 < self.len) : (i += 1) {
            const newer = if (self.head >= i + 1) self.head - i - 1 else CAPACITY - (i + 1 - self.head);
            const older = if (self.head >= i + 2) self.head - i - 2 else CAPACITY - (i + 2 - self.head);
            if (!std.mem.eql(u8, &self.entries[newer].prev_hash, &self.entries[older].hash)) break;
            depth += 1;
        }
        return depth;
    }
};

// ── Tests ──

fn makeEntry(slot: u64, block_no: u64, hash_seed: u8, prev_seed: u8) ChainEntry {
    return .{
        .slot = slot,
        .block_no = block_no,
        .hash = [_]u8{hash_seed} ** 32,
        .prev_hash = [_]u8{prev_seed} ** 32,
    };
}

test "chain_index: append and retrieve" {
    var idx = ChainIndex.init();
    try std.testing.expectEqual(@as(u32, 0), idx.count());
    try std.testing.expect(idx.latest() == null);

    idx.append(makeEntry(100, 1, 0xAA, 0x00));
    try std.testing.expectEqual(@as(u32, 1), idx.count());
    const e = idx.latest().?;
    try std.testing.expectEqual(@as(u64, 100), e.slot);
    try std.testing.expectEqual(@as(u64, 1), e.block_no);
    try std.testing.expectEqual(@as(u8, 0xAA), e.hash[0]);
}

test "chain_index: lookup by hash, slot, block_no" {
    var idx = ChainIndex.init();
    idx.append(makeEntry(100, 1, 0xAA, 0x00));
    idx.append(makeEntry(200, 2, 0xBB, 0xAA));
    idx.append(makeEntry(300, 3, 0xCC, 0xBB));

    // By hash
    const by_hash = idx.lookupByHash([_]u8{0xBB} ** 32);
    try std.testing.expect(by_hash != null);
    try std.testing.expectEqual(@as(u64, 200), by_hash.?.slot);

    // By slot
    const by_slot = idx.lookupBySlot(300);
    try std.testing.expect(by_slot != null);
    try std.testing.expectEqual(@as(u64, 3), by_slot.?.block_no);

    // By block_no
    const by_bn = idx.lookupByBlockNo(1);
    try std.testing.expect(by_bn != null);
    try std.testing.expectEqual(@as(u64, 100), by_bn.?.slot);

    // Not found
    try std.testing.expect(idx.lookupByHash([_]u8{0xFF} ** 32) == null);
    try std.testing.expect(idx.lookupBySlot(999) == null);
    try std.testing.expect(idx.lookupByBlockNo(999) == null);
}

test "chain_index: pop rollback" {
    var idx = ChainIndex.init();
    idx.append(makeEntry(100, 1, 0xAA, 0x00));
    idx.append(makeEntry(200, 2, 0xBB, 0xAA));
    idx.append(makeEntry(300, 3, 0xCC, 0xBB));
    try std.testing.expectEqual(@as(u32, 3), idx.count());

    // Pop most recent
    const popped = idx.pop().?;
    try std.testing.expectEqual(@as(u64, 300), popped.slot);
    try std.testing.expectEqual(@as(u32, 2), idx.count());

    // Latest is now entry 2
    try std.testing.expectEqual(@as(u64, 200), idx.latest().?.slot);

    // Pop again
    _ = idx.pop();
    try std.testing.expectEqual(@as(u32, 1), idx.count());
    try std.testing.expectEqual(@as(u64, 100), idx.latest().?.slot);

    // Pop last
    _ = idx.pop();
    try std.testing.expectEqual(@as(u32, 0), idx.count());
    try std.testing.expect(idx.latest() == null);

    // Pop empty
    try std.testing.expect(idx.pop() == null);
}

test "chain_index: ring wrap preserves order" {
    var idx = ChainIndex.init();

    // Fill beyond capacity
    var i: u32 = 0;
    while (i < CAPACITY + 10) : (i += 1) {
        idx.append(makeEntry(1000 + i, 100 + i, @truncate(i), if (i > 0) @as(u8, @truncate(i - 1)) else 0));
    }

    try std.testing.expectEqual(CAPACITY, idx.count());

    // Latest should be the last appended
    const latest = idx.latest().?;
    try std.testing.expectEqual(@as(u64, 1000 + CAPACITY + 9), latest.slot);

    // getRecent returns newest first
    var buf: [5]ChainEntry = undefined;
    const n = idx.getRecent(&buf, 5);
    try std.testing.expectEqual(@as(u32, 5), n);
    try std.testing.expectEqual(@as(u64, 1000 + CAPACITY + 9), buf[0].slot);
    try std.testing.expectEqual(@as(u64, 1000 + CAPACITY + 8), buf[1].slot);

    // Pop after wrap
    const p = idx.pop().?;
    try std.testing.expectEqual(@as(u64, 1000 + CAPACITY + 9), p.slot);
    try std.testing.expectEqual(CAPACITY - 1, idx.count());
}

test "chain_index: contiguous depth" {
    var idx = ChainIndex.init();

    // Build a contiguous chain: each entry's prev_hash == predecessor's hash
    idx.append(makeEntry(100, 1, 0xAA, 0x00));
    idx.append(makeEntry(200, 2, 0xBB, 0xAA)); // prev=AA matches hash of entry 1
    idx.append(makeEntry(300, 3, 0xCC, 0xBB)); // prev=BB matches hash of entry 2

    try std.testing.expectEqual(@as(u32, 3), idx.contiguousDepth());

    // Break continuity
    idx.append(makeEntry(400, 4, 0xDD, 0xFF)); // prev=FF does NOT match hash CC
    try std.testing.expectEqual(@as(u32, 1), idx.contiguousDepth());

    // Extend from break point
    idx.append(makeEntry(500, 5, 0xEE, 0xDD)); // prev=DD matches hash of entry 4
    try std.testing.expectEqual(@as(u32, 2), idx.contiguousDepth());
}
