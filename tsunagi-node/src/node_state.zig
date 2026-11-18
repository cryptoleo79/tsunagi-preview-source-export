const std = @import("std");
const compat = @import("compat");

/// Global node state — single source of truth for the /status endpoint.
///
/// Thread safety: fields are written from the follower thread (slot/block/utxo),
/// producer tick (leader_last/last_forge_slot), and propagation server thread
/// (last_accept_slot). Reads happen from the HTTP server thread.
///
/// We use a mutex rather than atomics because some fields (tip_hash[32]) are
/// larger than a cache line and must update coherently. Lock hold time is < 1µs.
pub const NodeState = struct {
    mu: compat.Mutex = .{},

    // Chain state (updated by follower)
    slot: u64 = 0,
    block_no: u64 = 0,
    tip_hash: [32]u8 = [_]u8{0} ** 32,
    utxo_size: u64 = 0,

    // Consensus state (updated by producer tick)
    nonce_epoch: u64 = 0,
    sigma_x1e9: u64 = 0,
    leader_last: bool = false,

    // Forge outcomes (updated by producer / propagation)
    last_forge_slot: u64 = 0,
    last_forge_unix: i64 = 0,
    last_accept_slot: u64 = 0,
    last_accept_unix: i64 = 0,

    // Mempool summary (updated by follower)
    mempool_items: u64 = 0,
    mempool_bytes: u64 = 0,
};

pub var g_node_state: NodeState = .{};

/// Update chain tip fields. Call from follower on each block apply.
pub fn updateTip(slot: u64, block_no: u64, tip_hash: [32]u8, utxo_size: u64) void {
    g_node_state.mu.lock();
    defer g_node_state.mu.unlock();
    g_node_state.slot = slot;
    g_node_state.block_no = block_no;
    g_node_state.tip_hash = tip_hash;
    g_node_state.utxo_size = utxo_size;
}

/// Update only the live slot/block_no — the freshest header observed via
/// ChainSync, BEFORE BlockFetch completes. Wired from
/// `updateRxFromPeer` (PARENT_SOURCE_UPDATE writer) so /status/full reflects
/// the live chain even when BlockFetch hasn't yet applied. Preserves
/// tip_hash and utxo_size — those remain owned by the applied path
/// (`updateTip` in follower.onBlockFetched).
pub fn updateLiveTip(slot: u64, block_no: u64) void {
    g_node_state.mu.lock();
    defer g_node_state.mu.unlock();
    // Forward-only: never regress slot/block_no if a later applied tip
    // happens to lag a momentary peer-probe value. Strict monotonic.
    if (slot > g_node_state.slot) g_node_state.slot = slot;
    if (block_no > g_node_state.block_no) g_node_state.block_no = block_no;
}

/// Update the live tip_hash from the freshest peer header observed via
/// ChainSync (PARENT_SOURCE_UPDATE writer). The applied path
/// (`follower.onBlockFetched`) currently writes zeros for tip_hash, so
/// without this writer /status/full.tip_hash is permanently zeros. The
/// hash is always overwritten — peer hashes carry no monotonic ordering,
/// they're fresh-or-stale based on the slot/block_no companion fields.
pub fn updateLiveTipHash(tip_hash: [32]u8) void {
    g_node_state.mu.lock();
    defer g_node_state.mu.unlock();
    g_node_state.tip_hash = tip_hash;
}

/// Update consensus state. Call from producer tick after praos check.
pub fn updateConsensus(nonce_epoch: u64, sigma_x1e9: u64, leader_last: bool) void {
    g_node_state.mu.lock();
    defer g_node_state.mu.unlock();
    g_node_state.nonce_epoch = nonce_epoch;
    g_node_state.sigma_x1e9 = sigma_x1e9;
    g_node_state.leader_last = leader_last;
}

/// Record a successful forge. Call from producer after EVENT_BLOCK_BUILD.
pub fn updateForge(slot: u64, now_unix: i64) void {
    g_node_state.mu.lock();
    defer g_node_state.mu.unlock();
    g_node_state.last_forge_slot = slot;
    g_node_state.last_forge_unix = now_unix;
}

/// Record a block accepted (relay fetched our block). Call from propagation.
pub fn updateAccept(slot: u64, now_unix: i64) void {
    g_node_state.mu.lock();
    defer g_node_state.mu.unlock();
    g_node_state.last_accept_slot = slot;
    g_node_state.last_accept_unix = now_unix;
}

/// Update mempool summary. Call from follower after evict/sweep.
pub fn updateMempool(items: u64, bytes: u64) void {
    g_node_state.mu.lock();
    defer g_node_state.mu.unlock();
    g_node_state.mempool_items = items;
    g_node_state.mempool_bytes = bytes;
}

/// Render current state as JSON. Caller provides buffer.
/// Returns the written slice. Acquires mu for a snapshot read.
pub fn renderJson(buf: []u8) ![]u8 {
    g_node_state.mu.lock();
    // Copy fields under lock so JSON format doesn't hold the mutex during I/O.
    const snap = g_node_state;
    g_node_state.mu.unlock();

    var tip_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&tip_hex, "{x}", .{&snap.tip_hash}) catch {};

    return std.fmt.bufPrint(buf,
        \\{{"slot":{d},"block_no":{d},"tip_hash":"{s}","utxo_size":{d},"nonce_epoch":{d},"sigma_x1e9":{d},"leader_last":{s},"last_forge_slot":{d},"last_forge_unix":{d},"last_accept_slot":{d},"last_accept_unix":{d},"mempool_items":{d},"mempool_bytes":{d}}}
    , .{
        snap.slot,
        snap.block_no,
        @as([]const u8, &tip_hex),
        snap.utxo_size,
        snap.nonce_epoch,
        snap.sigma_x1e9,
        if (snap.leader_last) "true" else "false",
        snap.last_forge_slot,
        snap.last_forge_unix,
        snap.last_accept_slot,
        snap.last_accept_unix,
        snap.mempool_items,
        snap.mempool_bytes,
    });
}

test "renderJson produces valid output" {
    g_node_state.slot = 100;
    g_node_state.block_no = 42;
    g_node_state.nonce_epoch = 1276;
    g_node_state.sigma_x1e9 = 636000;
    g_node_state.leader_last = true;

    var buf: [1024]u8 = undefined;
    const out = try renderJson(&buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"slot\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"block_no\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"nonce_epoch\":1276") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"leader_last\":true") != null);
}

test "updateLiveTip wires live PARENT_SOURCE_UPDATE slot to render output" {
    // Reset to a known baseline.
    g_node_state.slot = 0;
    g_node_state.block_no = 0;
    g_node_state.tip_hash = [_]u8{0} ** 32;
    g_node_state.utxo_size = 0;

    // Simulate a PARENT_SOURCE_UPDATE write — header observed via ChainSync,
    // BlockFetch has not completed yet (so tip_hash/utxo_size remain zeros).
    updateLiveTip(12345, 67);

    var buf: [1024]u8 = undefined;
    const out = try renderJson(&buf);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"slot\":12345") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"block_no\":67") != null);

    // Forward-only: a stale peer value must NOT regress the live slot.
    updateLiveTip(100, 1);
    try std.testing.expectEqual(@as(u64, 12345), g_node_state.slot);
    try std.testing.expectEqual(@as(u64, 67), g_node_state.block_no);

    // A fresher value must advance.
    updateLiveTip(20000, 100);
    try std.testing.expectEqual(@as(u64, 20000), g_node_state.slot);
    try std.testing.expectEqual(@as(u64, 100), g_node_state.block_no);
}

test "updateLiveTipHash wires PARENT_SOURCE_UPDATE hash to render output" {
    // Reset to a known baseline.
    g_node_state.tip_hash = [_]u8{0} ** 32;

    // Fresh peer hash (deterministic byte pattern for assertion).
    var fresh: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) fresh[i] = @intCast(i + 1);
    updateLiveTipHash(fresh);

    var buf: [1024]u8 = undefined;
    const out = try renderJson(&buf);
    // The hash 0x01..0x20 renders as the leading hex string "0102030405..."
    try std.testing.expect(std.mem.indexOf(u8, out, "\"tip_hash\":\"0102030405") != null);

    // A second update overwrites — peer hashes have no monotonic ordering.
    const other: [32]u8 = [_]u8{0xab} ** 32;
    updateLiveTipHash(other);
    const out2 = try renderJson(&buf);
    try std.testing.expect(std.mem.indexOf(u8, out2, "\"tip_hash\":\"abababab") != null);
}
