const std = @import("std");

/// Threshold for tip age: above this the node is considered syncing, not following.
pub const TIP_AGE_THRESHOLD_S: i64 = 120;

pub const NodeSyncState = enum {
    offline,
    syncing,
    following,
    stale,

    pub fn label(self: NodeSyncState) []const u8 {
        return switch (self) {
            .offline => "OFFLINE",
            .syncing => "SYNCING",
            .following => "FOLLOWING",
            .stale => "STALE",
        };
    }
};

pub const NodeState = struct {
    sync_state: NodeSyncState,
    tip_slot: u64,
    tip_block_no: u64,
    tip_hash: [32]u8,
    tip_age_seconds: i64,
    chain_depth: u32,
    contiguous_depth: u32,
    utxo_count: usize,
    roll_forward_count: u64,
    roll_backward_count: u64,
};

/// Derive NodeSyncState from tip age and roll counts.
///   - no rolls at all → offline
///   - tip_age > threshold → syncing (if recent rolls) or stale (if no recent activity)
///   - tip_age <= threshold → following
pub fn deriveSyncState(
    tip_age_seconds: i64,
    roll_forward_count: u64,
    was_following: bool,
) NodeSyncState {
    if (roll_forward_count == 0) return .offline;
    if (tip_age_seconds <= TIP_AGE_THRESHOLD_S) return .following;
    if (was_following) return .stale;
    return .syncing;
}

// ── Tests ──

test "node_state: offline when no rolls" {
    try std.testing.expectEqual(NodeSyncState.offline, deriveSyncState(0, 0, false));
    try std.testing.expectEqual(NodeSyncState.offline, deriveSyncState(999, 0, false));
}

test "node_state: following when tip fresh" {
    try std.testing.expectEqual(NodeSyncState.following, deriveSyncState(0, 100, false));
    try std.testing.expectEqual(NodeSyncState.following, deriveSyncState(TIP_AGE_THRESHOLD_S, 100, false));
}

test "node_state: syncing when tip old and never followed" {
    try std.testing.expectEqual(NodeSyncState.syncing, deriveSyncState(TIP_AGE_THRESHOLD_S + 1, 100, false));
    try std.testing.expectEqual(NodeSyncState.syncing, deriveSyncState(600, 50, false));
}

test "node_state: stale when was following but tip aged" {
    try std.testing.expectEqual(NodeSyncState.stale, deriveSyncState(TIP_AGE_THRESHOLD_S + 1, 100, true));
    try std.testing.expectEqual(NodeSyncState.stale, deriveSyncState(300, 1000, true));
}

test "node_state: labels" {
    try std.testing.expectEqualStrings("OFFLINE", NodeSyncState.offline.label());
    try std.testing.expectEqualStrings("SYNCING", NodeSyncState.syncing.label());
    try std.testing.expectEqualStrings("FOLLOWING", NodeSyncState.following.label());
    try std.testing.expectEqualStrings("STALE", NodeSyncState.stale.label());
}
