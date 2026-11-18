const std = @import("std");

/// Classification of peer/network events.
///
/// tx_seen is intentionally omitted. The TxSubmission protocol is
/// pull-based: peers request tx inventory from us. TSUNAGI does not
/// observe txs arriving from peers. Local tx submissions are tracked
/// separately by propagation_tracker and confirmation_tracker.
/// tx_seen will be added when a truthful inbound tx path exists.
pub const PeerEventKind = enum {
    peer_connect,
    peer_disconnect,
    block_received,
};

/// A single network event observation.
pub const PeerEvent = struct {
    /// Textual peer identifier (e.g. "3.135.125.51:3001").
    /// Fixed buffer; valid content is peer_label[0..peer_label_len].
    peer_label: [96]u8,
    peer_label_len: u8,
    kind: PeerEventKind,
    /// Slot associated with the event (block_received only).
    slot: ?u64,
    /// Block number associated with the event (block_received only).
    block_no: ?u64,
    /// Latency in milliseconds, if truthfully measured.
    /// Currently null — no block fetch timing is instrumented yet.
    latency_ms: ?u32,
    /// Unix timestamp when the event was observed.
    timestamp_unix: i64,

    /// Extract the peer label as a slice.
    pub fn peerLabel(self: *const PeerEvent) []const u8 {
        return self.peer_label[0..self.peer_label_len];
    }
};

pub const CAPACITY: u32 = 512;

/// Bounded ring buffer for recent network events.
/// Passive observability only — no protocol side effects.
pub const PeerObservatory = struct {
    entries: [CAPACITY]PeerEvent = undefined,
    head: u32 = 0,
    len: u32 = 0,

    pub fn init() PeerObservatory {
        return .{};
    }

    /// Record a network event.
    pub fn append(self: *PeerObservatory, ev: PeerEvent) void {
        self.entries[self.head] = ev;
        self.head = (self.head + 1) % CAPACITY;
        if (self.len < CAPACITY) {
            self.len += 1;
        }
    }

    /// Get the most recent event, or null if empty.
    pub fn latest(self: *const PeerObservatory) ?PeerEvent {
        if (self.len == 0) return null;
        const idx = (self.head + CAPACITY - 1) % CAPACITY;
        return self.entries[idx];
    }

    /// Copy up to `max` recent entries into `buf`, newest first.
    /// Returns the number of entries written.
    pub fn getRecent(self: *const PeerObservatory, buf: []PeerEvent, max: u32) u32 {
        const n = @min(self.len, @min(max, @as(u32, @intCast(buf.len))));
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const idx = (self.head + CAPACITY - 1 - i) % CAPACITY;
            buf[i] = self.entries[idx];
        }
        return n;
    }

    /// Number of entries currently stored.
    pub fn count(self: *const PeerObservatory) u32 {
        return self.len;
    }

    /// Count events of a specific kind.
    pub fn countByKind(self: *const PeerObservatory, kind: PeerEventKind) u32 {
        var c: u32 = 0;
        var i: u32 = 0;
        while (i < self.len) : (i += 1) {
            const idx = (self.head + CAPACITY - 1 - i) % CAPACITY;
            if (self.entries[idx].kind == kind) c += 1;
        }
        return c;
    }
};

// ── Helpers ──────────────────────────────────────────────────

/// Create a PeerEvent with a string label. Truncates if > 96 bytes.
pub fn makeEvent(
    label: []const u8,
    kind: PeerEventKind,
    slot: ?u64,
    block_no: ?u64,
    latency_ms: ?u32,
    timestamp_unix: i64,
) PeerEvent {
    var ev: PeerEvent = .{
        .peer_label = undefined,
        .peer_label_len = 0,
        .kind = kind,
        .slot = slot,
        .block_no = block_no,
        .latency_ms = latency_ms,
        .timestamp_unix = timestamp_unix,
    };
    const copy_len = @min(label.len, ev.peer_label.len);
    @memcpy(ev.peer_label[0..copy_len], label[0..copy_len]);
    ev.peer_label_len = @intCast(copy_len);
    return ev;
}

// ── Inline Tests ─────────────────────────────────────────────

fn testEvent(label: []const u8, kind: PeerEventKind, ts: i64) PeerEvent {
    return makeEvent(label, kind, null, null, null, ts);
}

fn testBlockEvent(label: []const u8, slot: u64, block_no: u64, ts: i64) PeerEvent {
    return makeEvent(label, .block_received, slot, block_no, null, ts);
}

test "init returns empty observatory" {
    const o = PeerObservatory.init();
    try std.testing.expectEqual(@as(u32, 0), o.count());
    try std.testing.expect(o.latest() == null);
}

test "append event and count" {
    var o = PeerObservatory.init();
    o.append(testEvent("relay-1:3001", .peer_connect, 1000));
    try std.testing.expectEqual(@as(u32, 1), o.count());

    o.append(testEvent("relay-1:3001", .peer_disconnect, 1010));
    try std.testing.expectEqual(@as(u32, 2), o.count());
}

test "latest returns newest event" {
    var o = PeerObservatory.init();
    o.append(testEvent("relay-1:3001", .peer_connect, 1000));
    o.append(testBlockEvent("relay-1:3001", 100, 1, 1005));
    o.append(testEvent("relay-1:3001", .peer_disconnect, 1010));

    const l = o.latest().?;
    try std.testing.expectEqual(PeerEventKind.peer_disconnect, l.kind);
    try std.testing.expectEqual(@as(i64, 1010), l.timestamp_unix);
}

test "getRecent returns newest first" {
    var o = PeerObservatory.init();
    o.append(testEvent("relay-1:3001", .peer_connect, 1000));
    o.append(testBlockEvent("relay-1:3001", 100, 1, 1005));
    o.append(testEvent("relay-1:3001", .peer_disconnect, 1010));

    var buf: [10]PeerEvent = undefined;
    const n = o.getRecent(&buf, 10);
    try std.testing.expectEqual(@as(u32, 3), n);
    try std.testing.expectEqual(@as(i64, 1010), buf[0].timestamp_unix);
    try std.testing.expectEqual(@as(i64, 1005), buf[1].timestamp_unix);
    try std.testing.expectEqual(@as(i64, 1000), buf[2].timestamp_unix);
}

test "ring buffer wraps at capacity" {
    var o = PeerObservatory.init();
    var i: u32 = 0;
    while (i < CAPACITY + 5) : (i += 1) {
        o.append(testBlockEvent("relay:3001", @intCast(i * 3), @intCast(i + 1), @intCast(i * 100)));
    }
    try std.testing.expectEqual(CAPACITY, o.count());

    const last_i = CAPACITY + 4;
    const l = o.latest().?;
    try std.testing.expectEqual(@as(u64, last_i * 3), l.slot.?);
    try std.testing.expectEqual(@as(u64, last_i + 1), l.block_no.?);

    var full_buf: [CAPACITY]PeerEvent = undefined;
    const m = o.getRecent(&full_buf, CAPACITY);
    try std.testing.expectEqual(CAPACITY, m);
    try std.testing.expectEqual(@as(u64, 5 * 3), full_buf[m - 1].slot.?);
}

test "peer label preserved correctly" {
    var o = PeerObservatory.init();
    const label = "3.135.125.51:3001";
    o.append(makeEvent(label, .peer_connect, null, null, null, 1000));

    const l = o.latest().?;
    try std.testing.expectEqualStrings(label, l.peerLabel());
}

test "countByKind filters correctly" {
    var o = PeerObservatory.init();
    o.append(testEvent("r1:3001", .peer_connect, 1000));
    o.append(testBlockEvent("r1:3001", 100, 1, 1005));
    o.append(testBlockEvent("r1:3001", 103, 2, 1008));
    o.append(testEvent("r1:3001", .peer_disconnect, 1010));

    try std.testing.expectEqual(@as(u32, 1), o.countByKind(.peer_connect));
    try std.testing.expectEqual(@as(u32, 2), o.countByKind(.block_received));
    try std.testing.expectEqual(@as(u32, 1), o.countByKind(.peer_disconnect));
}
