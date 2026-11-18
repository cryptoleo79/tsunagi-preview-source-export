const std = @import("std");
const chain_index = @import("chain_index.zig");
const delta_history = @import("delta_history.zig");
const utxo_mod = @import("utxo.zig");
const cursor_mod = @import("cursor.zig");
const node_state = @import("node_state.zig");

/// Read-only accessor for unified queries across existing in-memory stores.
/// No new storage. Pure computation over borrowed references.
pub const DataAccess = struct {
    chain_idx: *const chain_index.ChainIndex,
    cursor: *const cursor_mod.Cursor,
    delta_hist: *const delta_history.DeltaHistory,
    utxo: *const utxo_mod.UTxO,

    /// Derive current node state from all stores.
    /// now_unix must be caller-provided (no IO).
    pub fn nodeState(self: DataAccess, now_unix: i64, was_following: bool) node_state.NodeState {
        const tip_age = if (self.cursor.updated_unix > 0 and now_unix > self.cursor.updated_unix)
            now_unix - self.cursor.updated_unix
        else
            0;

        // Decode tip hash from cursor hex
        var tip_hash: [32]u8 = [_]u8{0} ** 32;
        _ = std.fmt.hexToBytes(&tip_hash, &self.cursor.header_hash_hex) catch {};

        return .{
            .sync_state = node_state.deriveSyncState(tip_age, self.cursor.roll_forward_count, was_following),
            .tip_slot = self.cursor.slot,
            .tip_block_no = self.cursor.block_no,
            .tip_hash = tip_hash,
            .tip_age_seconds = tip_age,
            .chain_depth = self.chain_idx.count(),
            .contiguous_depth = self.chain_idx.contiguousDepth(),
            .utxo_count = self.utxo.map.count(),
            .roll_forward_count = self.cursor.roll_forward_count,
            .roll_backward_count = self.cursor.roll_backward_count,
        };
    }

    pub fn tipEntry(self: DataAccess) ?chain_index.ChainEntry {
        return self.chain_idx.latest();
    }

    pub fn recentBlocks(self: DataAccess, buf: []chain_index.ChainEntry, max: u32) u32 {
        return self.chain_idx.getRecent(buf, max);
    }

    pub fn blockByHash(self: DataAccess, hash: [32]u8) ?chain_index.ChainEntry {
        return self.chain_idx.lookupByHash(hash);
    }

    pub fn blockBySlot(self: DataAccess, slot: u64) ?chain_index.ChainEntry {
        return self.chain_idx.lookupBySlot(slot);
    }

    pub fn deltaByBlock(self: DataAccess, block_no: u64) ?delta_history.BlockDelta {
        return self.delta_hist.lookupByBlock(block_no);
    }

    pub fn utxoCount(self: DataAccess) usize {
        return self.utxo.map.count();
    }
};

// ── Tests ──

fn makeTestAccess() struct { da: DataAccess, ci: chain_index.ChainIndex, dh: delta_history.DeltaHistory, ut: utxo_mod.UTxO, cur: cursor_mod.Cursor } {
    return .{
        .ci = chain_index.ChainIndex.init(),
        .dh = delta_history.DeltaHistory.init(),
        .ut = utxo_mod.UTxO.init(std.heap.page_allocator),
        .cur = .{
            .slot = 0,
            .block_no = 0,
            .tip_hash_hex = [_]u8{'0'} ** 64,
            .header_hash_hex = [_]u8{'0'} ** 64,
            .roll_forward_count = 0,
            .roll_backward_count = 0,
            .updated_unix = 0,
        },
        .da = undefined,
    };
}

test "data_access: nodeState offline" {
    var t = makeTestAccess();
    defer t.ut.deinit();
    t.da = .{ .chain_idx = &t.ci, .cursor = &t.cur, .delta_hist = &t.dh, .utxo = &t.ut };

    const ns = t.da.nodeState(1000, false);
    try std.testing.expectEqual(node_state.NodeSyncState.offline, ns.sync_state);
    try std.testing.expectEqual(@as(usize, 0), ns.utxo_count);
}

test "data_access: nodeState following" {
    var t = makeTestAccess();
    defer t.ut.deinit();
    t.cur.roll_forward_count = 100;
    t.cur.updated_unix = 950;
    t.cur.slot = 5000;
    t.cur.block_no = 200;
    t.da = .{ .chain_idx = &t.ci, .cursor = &t.cur, .delta_hist = &t.dh, .utxo = &t.ut };

    const ns = t.da.nodeState(1000, false); // age = 50s < 120s
    try std.testing.expectEqual(node_state.NodeSyncState.following, ns.sync_state);
    try std.testing.expectEqual(@as(u64, 5000), ns.tip_slot);
    try std.testing.expectEqual(@as(u64, 200), ns.tip_block_no);
}

test "data_access: nodeState syncing" {
    var t = makeTestAccess();
    defer t.ut.deinit();
    t.cur.roll_forward_count = 100;
    t.cur.updated_unix = 500;
    t.da = .{ .chain_idx = &t.ci, .cursor = &t.cur, .delta_hist = &t.dh, .utxo = &t.ut };

    const ns = t.da.nodeState(1000, false); // age = 500s > 120s, never followed
    try std.testing.expectEqual(node_state.NodeSyncState.syncing, ns.sync_state);
}

test "data_access: nodeState stale" {
    var t = makeTestAccess();
    defer t.ut.deinit();
    t.cur.roll_forward_count = 100;
    t.cur.updated_unix = 500;
    t.da = .{ .chain_idx = &t.ci, .cursor = &t.cur, .delta_hist = &t.dh, .utxo = &t.ut };

    const ns = t.da.nodeState(1000, true); // age = 500s > 120s, was following
    try std.testing.expectEqual(node_state.NodeSyncState.stale, ns.sync_state);
}

test "data_access: tipEntry and recentBlocks" {
    var t = makeTestAccess();
    defer t.ut.deinit();

    t.ci.append(.{ .slot = 100, .block_no = 1, .hash = [_]u8{0xAA} ** 32, .prev_hash = [_]u8{0} ** 32 });
    t.ci.append(.{ .slot = 200, .block_no = 2, .hash = [_]u8{0xBB} ** 32, .prev_hash = [_]u8{0xAA} ** 32 });

    t.da = .{ .chain_idx = &t.ci, .cursor = &t.cur, .delta_hist = &t.dh, .utxo = &t.ut };

    const tip = t.da.tipEntry().?;
    try std.testing.expectEqual(@as(u64, 200), tip.slot);

    var buf: [5]chain_index.ChainEntry = undefined;
    const n = t.da.recentBlocks(&buf, 5);
    try std.testing.expectEqual(@as(u32, 2), n);
    try std.testing.expectEqual(@as(u64, 200), buf[0].slot);
    try std.testing.expectEqual(@as(u64, 100), buf[1].slot);
}

test "data_access: blockByHash and blockBySlot" {
    var t = makeTestAccess();
    defer t.ut.deinit();

    t.ci.append(.{ .slot = 100, .block_no = 1, .hash = [_]u8{0xAA} ** 32, .prev_hash = [_]u8{0} ** 32 });
    t.ci.append(.{ .slot = 200, .block_no = 2, .hash = [_]u8{0xBB} ** 32, .prev_hash = [_]u8{0xAA} ** 32 });

    t.da = .{ .chain_idx = &t.ci, .cursor = &t.cur, .delta_hist = &t.dh, .utxo = &t.ut };

    const by_hash = t.da.blockByHash([_]u8{0xAA} ** 32).?;
    try std.testing.expectEqual(@as(u64, 100), by_hash.slot);

    const by_slot = t.da.blockBySlot(200).?;
    try std.testing.expectEqual(@as(u64, 2), by_slot.block_no);

    try std.testing.expect(t.da.blockByHash([_]u8{0xFF} ** 32) == null);
    try std.testing.expect(t.da.blockBySlot(999) == null);
}

test "data_access: utxoCount passthrough" {
    var t = makeTestAccess();
    defer t.ut.deinit();
    t.da = .{ .chain_idx = &t.ci, .cursor = &t.cur, .delta_hist = &t.dh, .utxo = &t.ut };

    try std.testing.expectEqual(@as(usize, 0), t.da.utxoCount());

    // Add a UTxO entry directly
    var p = [_]utxo_mod.Produced{
        .{ .input = .{ .tx_hash = [_]u8{1} ** 32, .index = 0 }, .output = .{ .address = "a", .lovelace = 100 } },
    };
    var undo = try t.ut.applyDelta(&[_]utxo_mod.TxIn{}, &p);
    defer undo.deinit();

    try std.testing.expectEqual(@as(usize, 1), t.da.utxoCount());
}
