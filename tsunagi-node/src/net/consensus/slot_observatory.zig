const std = @import("std");

/// Classification of a slot-level observation.
/// Currently only observed_block is emitted from runtime.
/// empty_gap and local_candidate are reserved for future use
/// and included in the enum so the model does not need a
/// breaking change when they are enabled.
pub const SlotObservationKind = enum {
    observed_block,
    empty_gap,
    local_candidate,
};

/// A single slot-level observation in the chain rhythm timeline.
pub const SlotObservation = struct {
    slot: u64,
    block_no: ?u64,
    observed_unix: i64,
    kind: SlotObservationKind,
    /// Number of empty slots between this block and the previous block.
    /// Computed as current_slot - last_block_slot - 1.
    /// 0 means consecutive blocks. Null when there is no prior block
    /// or for empty_gap entries.
    gap_from_prev_block: ?u64,
};

pub const CAPACITY: u32 = 512;

/// Bounded ring buffer for recent slot-level observations.
/// Passive observability only — no consensus side effects.
pub const SlotObservatory = struct {
    entries: [CAPACITY]SlotObservation = undefined,
    head: u32 = 0,
    len: u32 = 0,
    /// Slot of the most recently observed block, used to compute gaps.
    last_block_slot: ?u64 = null,

    pub fn init() SlotObservatory {
        return .{};
    }

    /// Record an observed block at the given slot.
    /// Computes gap_from_prev_block from the last observed block slot.
    pub fn appendObservedBlock(
        self: *SlotObservatory,
        slot: u64,
        block_no: u64,
        observed_unix: i64,
    ) void {
        const gap: ?u64 = if (self.last_block_slot) |prev|
            if (slot > prev) slot - prev - 1 else null
        else
            null;
        self.appendEntry(.{
            .slot = slot,
            .block_no = block_no,
            .observed_unix = observed_unix,
            .kind = .observed_block,
            .gap_from_prev_block = gap,
        });
        self.last_block_slot = slot;
    }

    /// Record an empty gap observation at a slot with no block.
    /// Reserved for future use — not emitted by current runtime.
    pub fn appendEmptyGap(
        self: *SlotObservatory,
        slot: u64,
        observed_unix: i64,
    ) void {
        self.appendEntry(.{
            .slot = slot,
            .block_no = null,
            .observed_unix = observed_unix,
            .kind = .empty_gap,
            .gap_from_prev_block = null,
        });
    }

    /// Get the most recent observation, or null if empty.
    pub fn latest(self: *const SlotObservatory) ?SlotObservation {
        if (self.len == 0) return null;
        const idx = (self.head + CAPACITY - 1) % CAPACITY;
        return self.entries[idx];
    }

    /// Copy up to `max` recent entries into `buf`, newest first.
    /// Returns the number of entries written.
    pub fn getRecent(self: *const SlotObservatory, buf: []SlotObservation, max: u32) u32 {
        const n = @min(self.len, @min(max, @as(u32, @intCast(buf.len))));
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const idx = (self.head + CAPACITY - 1 - i) % CAPACITY;
            buf[i] = self.entries[idx];
        }
        return n;
    }

    /// Number of entries currently stored.
    pub fn count(self: *const SlotObservatory) u32 {
        return self.len;
    }

    // -- internal --

    fn appendEntry(self: *SlotObservatory, obs: SlotObservation) void {
        self.entries[self.head] = obs;
        self.head = (self.head + 1) % CAPACITY;
        if (self.len < CAPACITY) {
            self.len += 1;
        }
    }
};

// ── Inline Tests ──────────────────────────────────────────

test "init returns empty observatory" {
    const o = SlotObservatory.init();
    try std.testing.expectEqual(@as(u32, 0), o.count());
    try std.testing.expect(o.latest() == null);
}

test "appendObservedBlock records entry" {
    var o = SlotObservatory.init();
    o.appendObservedBlock(100, 1, 1000);
    try std.testing.expectEqual(@as(u32, 1), o.count());

    const l = o.latest().?;
    try std.testing.expectEqual(@as(u64, 100), l.slot);
    try std.testing.expectEqual(@as(u64, 1), l.block_no.?);
    try std.testing.expectEqual(SlotObservationKind.observed_block, l.kind);
    // First block has no gap
    try std.testing.expect(l.gap_from_prev_block == null);
}

test "gap_from_prev_block computed correctly" {
    var o = SlotObservatory.init();
    o.appendObservedBlock(100, 1, 1000);
    o.appendObservedBlock(103, 2, 1003);

    const l = o.latest().?;
    // slot 103 - 100 - 1 = 2 empty slots between blocks
    try std.testing.expectEqual(@as(u64, 2), l.gap_from_prev_block.?);

    o.appendObservedBlock(104, 3, 1004);
    const l2 = o.latest().?;
    // slot 104 - 103 - 1 = 0 empty slots (consecutive blocks)
    try std.testing.expectEqual(@as(u64, 0), l2.gap_from_prev_block.?);
}

test "latest returns newest entry" {
    var o = SlotObservatory.init();
    o.appendObservedBlock(100, 1, 1000);
    o.appendObservedBlock(105, 2, 1005);
    o.appendObservedBlock(110, 3, 1010);

    const l = o.latest().?;
    try std.testing.expectEqual(@as(u64, 110), l.slot);
    try std.testing.expectEqual(@as(u64, 3), l.block_no.?);
}

test "getRecent returns newest first" {
    var o = SlotObservatory.init();
    o.appendObservedBlock(100, 1, 1000);
    o.appendObservedBlock(103, 2, 1003);
    o.appendObservedBlock(110, 3, 1010);

    var buf: [10]SlotObservation = undefined;
    const n = o.getRecent(&buf, 10);
    try std.testing.expectEqual(@as(u32, 3), n);
    try std.testing.expectEqual(@as(u64, 110), buf[0].slot);
    try std.testing.expectEqual(@as(u64, 103), buf[1].slot);
    try std.testing.expectEqual(@as(u64, 100), buf[2].slot);
}

test "ring buffer wraps at capacity" {
    var o = SlotObservatory.init();
    var i: u32 = 0;
    while (i < CAPACITY + 5) : (i += 1) {
        o.appendObservedBlock(@intCast(i * 3), @intCast(i + 1), @intCast(i * 100));
    }
    try std.testing.expectEqual(CAPACITY, o.count());

    // Newest should be the last one added
    const last_i = CAPACITY + 4;
    const l = o.latest().?;
    try std.testing.expectEqual(@as(u64, last_i * 3), l.slot);
    try std.testing.expectEqual(@as(u64, last_i + 1), l.block_no.?);

    // Oldest accessible should be entry #5
    var full_buf: [CAPACITY]SlotObservation = undefined;
    const m = o.getRecent(&full_buf, CAPACITY);
    try std.testing.expectEqual(CAPACITY, m);
    try std.testing.expectEqual(@as(u64, 5 * 3), full_buf[m - 1].slot);
}

test "appendEmptyGap records with null block_no" {
    var o = SlotObservatory.init();
    o.appendObservedBlock(100, 1, 1000);
    o.appendEmptyGap(101, 1001);

    try std.testing.expectEqual(@as(u32, 2), o.count());

    const l = o.latest().?;
    try std.testing.expectEqual(@as(u64, 101), l.slot);
    try std.testing.expect(l.block_no == null);
    try std.testing.expectEqual(SlotObservationKind.empty_gap, l.kind);
    try std.testing.expect(l.gap_from_prev_block == null);

    // last_block_slot should still be 100 (empty gap doesn't update it)
    o.appendObservedBlock(105, 2, 1005);
    const l2 = o.latest().?;
    // slot 105 - 100 - 1 = 4 empty slots (empty gap doesn't update last_block_slot)
    try std.testing.expectEqual(@as(u64, 4), l2.gap_from_prev_block.?);
}
