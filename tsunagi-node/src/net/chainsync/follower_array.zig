// Multi-peer follower scaffold — infrastructure only.
//
// Goal: extend follower.zig (currently single-peer) to support 2-3
// parallel upstream relays with independent reconnect loops and
// unified tip selection. This file provides the shared data
// structures + env parser so the full extraction (runOneConnection
// from follower.run, FetchClaims de-dup, apply-mutex refactor) can
// land in a follow-up PR without further scaffolding churn.
//
// Status today (scaffold-only):
//   - Slot / TipBus / FetchClaimMap types defined
//   - env parser for TSUNAGI_FOLLOWER_PEERS = "host1:port1,host2:port2,..."
//   - parsePeers() validates + caps at MAX_SLOTS
//   - Unit tests for parser
//
// Not yet wired — follower.zig still runs its original single-peer
// loop. Extraction is blocked on careful audit of follower.zig module
// globals (g_nonce_state, g_stake_state, g_stake_dist) to add
// per-variable mutexes before multi-threaded apply goes live.
//
// Safety: this file is UNREFERENCED at build time until a future PR
// wires runMulti() into chainsync_mux_smoke.zig. Landing the scaffold
// now keeps the change reviewable and atomic.

const std = @import("std");
const compat = @import("compat");

pub const MAX_SLOTS: u32 = 3;

pub const Peer = struct {
    host: []u8,
    port: u16,
};

pub const Slot = struct {
    id: u32 = 0,
    peer: Peer = .{ .host = &.{}, .port = 0 },
    connected: std.atomic.Value(bool) = .{ .raw = false },
    last_activity_unix: std.atomic.Value(i64) = .{ .raw = 0 },
    reconnect_attempt: u64 = 0,
    disabled: bool = false,
    false_header_total: u64 = 0,
    mu: compat.Mutex = .{},
};

pub const TipBus = struct {
    mu: compat.Mutex = .{},
    slot: u64 = 0,
    block: u64 = 0,
    hash: [32]u8 = [_]u8{0} ** 32,
    contributor: u32 = 0,
};

pub const FetchClaim = struct {
    block_no: u64,
    owner_slot: u32,
    expires_unix: i64,
    active: bool = true,
};

pub const FetchClaimMap = struct {
    mu: compat.Mutex = .{},
    entries: [128]FetchClaim = [_]FetchClaim{.{ .block_no = 0, .owner_slot = 0, .expires_unix = 0, .active = false }} ** 128,
    default_ttl_s: i64 = 10,

    /// Try to claim a block for slot_id. Returns true if claimed (caller
    /// fetches) or false if another slot already owns an active claim.
    pub fn tryClaim(self: *FetchClaimMap, block_no: u64, slot_id: u32) bool {
        self.mu.lock();
        defer self.mu.unlock();
        const now = compat.timestamp();
        // Look for an active claim on the same block.
        for (&self.entries) |*e| {
            if (e.active and e.block_no == block_no) {
                if (e.expires_unix > now) return false; // still owned
                e.active = false; // expired; take over below
            }
        }
        // Find a free slot.
        for (&self.entries) |*e| {
            if (!e.active) {
                e.* = .{
                    .block_no = block_no,
                    .owner_slot = slot_id,
                    .expires_unix = now + self.default_ttl_s,
                    .active = true,
                };
                return true;
            }
        }
        return false; // table full — fall through
    }

    /// Caller evicts a claim after successful fetch.
    pub fn release(self: *FetchClaimMap, block_no: u64) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (&self.entries) |*e| {
            if (e.active and e.block_no == block_no) {
                e.active = false;
                return;
            }
        }
    }
};

pub const FollowerArray = struct {
    slots: [MAX_SLOTS]Slot = [_]Slot{.{}} ** MAX_SLOTS,
    count: u32 = 0,
    tip_bus: TipBus = .{},
    fetch_claims: FetchClaimMap = .{},
};

pub var g_follower_array: FollowerArray = .{};

/// Parse TSUNAGI_FOLLOWER_PEERS = "host1:port1,host2:port2,..." into a
/// bounded slice of Peer. Allocates host strings via the provided
/// allocator. Caller owns the returned peers and must call freePeers.
pub fn parsePeers(alloc: std.mem.Allocator, spec: []const u8) ![]Peer {
    var list = std.array_list.Managed(Peer).init(alloc);
    errdefer {
        for (list.items) |p| alloc.free(p.host);
        list.deinit();
    }
    var it = std.mem.tokenizeAny(u8, spec, ",;");
    while (it.next()) |raw| {
        if (list.items.len >= MAX_SLOTS) break;
        const entry = std.mem.trim(u8, raw, " \t\r\n");
        if (entry.len == 0) continue;
        const sep = std.mem.indexOfScalar(u8, entry, ':') orelse return error.InvalidPeerFormat;
        const host_src = entry[0..sep];
        const port = std.fmt.parseUnsigned(u16, entry[sep + 1 ..], 10) catch return error.InvalidPeerFormat;
        if (host_src.len == 0 or port == 0) return error.InvalidPeerFormat;
        const host_copy = try alloc.dupe(u8, host_src);
        try list.append(.{ .host = host_copy, .port = port });
    }
    return list.toOwnedSlice();
}

pub fn freePeers(alloc: std.mem.Allocator, peers: []Peer) void {
    for (peers) |p| alloc.free(p.host);
    alloc.free(peers);
}

test "parsePeers handles single peer" {
    const peers = try parsePeers(std.testing.allocator, "relay.example.com:3001");
    defer freePeers(std.testing.allocator, peers);
    try std.testing.expectEqual(@as(usize, 1), peers.len);
    try std.testing.expectEqualStrings("relay.example.com", peers[0].host);
    try std.testing.expectEqual(@as(u16, 3001), peers[0].port);
}

test "parsePeers caps at MAX_SLOTS" {
    const peers = try parsePeers(std.testing.allocator, "a:1,b:2,c:3,d:4,e:5");
    defer freePeers(std.testing.allocator, peers);
    try std.testing.expectEqual(@as(usize, 3), peers.len);
}

test "parsePeers rejects malformed entry" {
    const result = parsePeers(std.testing.allocator, "bad-entry");
    try std.testing.expectError(error.InvalidPeerFormat, result);
}

test "FetchClaimMap tryClaim prevents duplicate fetch" {
    var cm = FetchClaimMap{};
    try std.testing.expect(cm.tryClaim(100, 0));
    try std.testing.expect(!cm.tryClaim(100, 1)); // same block, different slot — rejected
    cm.release(100);
    try std.testing.expect(cm.tryClaim(100, 1)); // now available
}
