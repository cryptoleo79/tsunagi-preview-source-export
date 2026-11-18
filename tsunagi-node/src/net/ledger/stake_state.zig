const std = @import("std");
const compat = @import("compat");
const tx_decoder = @import("tx_decoder.zig");

/// Aggregate stake distribution state derived from on-chain certificates.
/// Tracks running totals of stake operations observed during chain following.
/// This is a monotonic accumulator — it does not track per-credential state,
/// only net counts. Full per-credential delegation maps are a future milestone.
pub const StakeState = struct {
    registered_credentials: u64 = 0,
    deregistered_credentials: u64 = 0,
    active_delegations: u64 = 0,
    pool_registrations: u64 = 0,
    pool_retirements: u64 = 0,
    other_certs: u64 = 0,
    total_certs: u64 = 0,
    blocks_with_certs: u64 = 0,
    last_update_slot: u64 = 0,
    last_update_unix: i64 = 0,
    updates_total: u64 = 0,

    /// Estimated net registered credentials (reg - dereg, saturating)
    pub fn netRegistered(self: *const StakeState) u64 {
        return if (self.registered_credentials > self.deregistered_credentials)
            self.registered_credentials - self.deregistered_credentials
        else
            0;
    }

    /// Estimated net active pools (reg - retire, saturating)
    pub fn netPools(self: *const StakeState) u64 {
        return if (self.pool_registrations > self.pool_retirements)
            self.pool_registrations - self.pool_retirements
        else
            0;
    }
};

/// Process a block's certificate summary into the stake state.
pub fn processBlock(state: *StakeState, slot: u64, unix: i64, summary: tx_decoder.CertificateSummary) void {
    if (summary.total == 0) return;

    state.registered_credentials += summary.stake_registration;
    state.deregistered_credentials += summary.stake_deregistration;
    state.active_delegations += summary.stake_delegation;
    state.pool_registrations += summary.pool_registration;
    state.pool_retirements += summary.pool_retirement;
    state.other_certs += summary.other;
    state.total_certs += summary.total;
    state.blocks_with_certs += 1;
    state.last_update_slot = slot;
    state.last_update_unix = unix;
    state.updates_total += 1;
}

/// Format stake state as JSON for operator surfaces.
pub fn formatJson(state: *const StakeState, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf,
        \\{{"net_registered":{d},"net_pools":{d},"registered":{d},"deregistered":{d},"delegations":{d},"pool_reg":{d},"pool_retire":{d},"other":{d},"total_certs":{d},"blocks_with_certs":{d},"last_slot":{d},"updates":{d}}}
    , .{
        state.netRegistered(),
        state.netPools(),
        state.registered_credentials,
        state.deregistered_credentials,
        state.active_delegations,
        state.pool_registrations,
        state.pool_retirements,
        state.other_certs,
        state.total_certs,
        state.blocks_with_certs,
        state.last_update_slot,
        state.updates_total,
    }) catch null;
}

/// Save stake state to a JSON file.
pub fn saveState(state: *const StakeState, path: []const u8) void {
    var buf: [512]u8 = undefined;
    const json = formatJson(state, &buf) orelse return;
    var f = compat.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer f.close();
    f.writeAll(json) catch {};
    std.debug.print("STAKE_STATE_SAVED: path={s} net_reg={d} net_pools={d} total_certs={d}\n", .{
        path, state.netRegistered(), state.netPools(), state.total_certs,
    });
}

/// Load stake state from a JSON file. Returns true if loaded successfully.
pub fn loadState(state: *StakeState, path: []const u8) bool {
    var f = compat.fs.cwd().openFile(path, .{}) catch return false;
    defer f.close();
    var buf: [512]u8 = undefined;
    const n = f.readAll(&buf) catch return false;
    const content = buf[0..n];

    // Keys must be unambiguous within the JSON produced by formatJson.
    // "registered" would match "net_registered", so we use comma-prefixed keys
    // for fields that share suffixes. First field uses opening brace prefix.
    state.registered_credentials = parseU64(content, ",\"registered\":") orelse
        (parseU64(content, "{\"registered\":") orelse return false);
    state.deregistered_credentials = parseU64(content, "\"deregistered\":") orelse 0;
    state.active_delegations = parseU64(content, "\"delegations\":") orelse 0;
    state.pool_registrations = parseU64(content, "\"pool_reg\":") orelse 0;
    state.pool_retirements = parseU64(content, "\"pool_retire\":") orelse 0;
    state.other_certs = parseU64(content, ",\"other\":") orelse 0;
    state.total_certs = parseU64(content, "\"total_certs\":") orelse 0;
    state.blocks_with_certs = parseU64(content, "\"blocks_with_certs\":") orelse 0;
    state.last_update_slot = parseU64(content, "\"last_slot\":") orelse 0;
    state.updates_total = parseU64(content, "\"updates\":") orelse 0;

    std.debug.print("STAKE_STATE_LOADED: path={s} net_reg={d} net_pools={d} total_certs={d}\n", .{
        path, state.netRegistered(), state.netPools(), state.total_certs,
    });
    return true;
}

fn parseU64(content: []const u8, key: []const u8) ?u64 {
    const idx = std.mem.indexOf(u8, content, key) orelse return null;
    const start = idx + key.len;
    var end = start;
    while (end < content.len and content[end] >= '0' and content[end] <= '9') : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(u64, content[start..end], 10) catch null;
}

// ── Tests ──────────────────────────────────────────────────────────

test "processBlock accumulates certificate counts" {
    var state = StakeState{};

    processBlock(&state, 100, 1000, .{
        .stake_registration = 3,
        .stake_deregistration = 1,
        .stake_delegation = 2,
        .pool_registration = 1,
        .pool_retirement = 0,
        .other = 0,
        .total = 7,
    });

    try std.testing.expectEqual(@as(u64, 3), state.registered_credentials);
    try std.testing.expectEqual(@as(u64, 1), state.deregistered_credentials);
    try std.testing.expectEqual(@as(u64, 2), state.netRegistered());
    try std.testing.expectEqual(@as(u64, 1), state.netPools());
    try std.testing.expectEqual(@as(u64, 7), state.total_certs);
    try std.testing.expectEqual(@as(u64, 1), state.blocks_with_certs);
}

test "processBlock skips zero-cert blocks" {
    var state = StakeState{};

    processBlock(&state, 200, 2000, .{
        .stake_registration = 0,
        .stake_deregistration = 0,
        .stake_delegation = 0,
        .pool_registration = 0,
        .pool_retirement = 0,
        .other = 0,
        .total = 0,
    });

    try std.testing.expectEqual(@as(u64, 0), state.updates_total);
    try std.testing.expectEqual(@as(u64, 0), state.blocks_with_certs);
}

test "netRegistered saturates at zero" {
    var state = StakeState{};
    state.deregistered_credentials = 10;
    state.registered_credentials = 3;
    try std.testing.expectEqual(@as(u64, 0), state.netRegistered());
}

test "formatJson produces valid output" {
    var state = StakeState{};
    state.registered_credentials = 5;
    state.active_delegations = 3;
    state.total_certs = 8;
    var buf: [512]u8 = undefined;
    const json = formatJson(&state, &buf);
    try std.testing.expect(json != null);
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"net_registered\":5") != null);
}

test "parseU64 extracts values from JSON" {
    const content = "{\"net_registered\":10,\"registered\":42,\"deregistered\":7}";
    try std.testing.expectEqual(@as(?u64, 42), parseU64(content, ",\"registered\":"));
    try std.testing.expectEqual(@as(?u64, 7), parseU64(content, "\"deregistered\":"));
    try std.testing.expectEqual(@as(?u64, null), parseU64(content, "\"missing\":"));
    // Verify net_registered is found with its own key
    try std.testing.expectEqual(@as(?u64, 10), parseU64(content, "\"net_registered\":"));
}
