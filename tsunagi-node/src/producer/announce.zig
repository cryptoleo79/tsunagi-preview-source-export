// Phase 9.6 — Safe Announce (protocol-compliant observability)
//
// TSUNAGI is a TCP listener for ChainSync; relays initiate and pull. We
// never send unsolicited protocol messages. This module tracks "readiness"
// — the state of having a freshly-forged block available for serving — and
// logs the moment we become ready and the moment a peer fetches it.
//
// It is pure observability. It does NOT touch the network stack, does NOT
// alter the ChainSync state machine, and does NOT buffer block bytes
// (those live on disk via the sealed artifact path; the server loads them
// on accept).

const std = @import("std");
const compat = @import("compat");
const presence = @import("presence.zig");

pub const State = struct {
    mu: compat.Mutex = .{},

    // Readiness markers.
    ready: bool = false,
    last_slot: u64 = 0,
    last_block_no: u64 = 0,
    last_header_size: u32 = 0,
    last_body_size: u32 = 0,
    last_total_size: u32 = 0,
    ready_unix: i64 = 0,

    // Prearm.final timestamp — when the pre-arm system told us a forge is
    // imminent, so we can measure "ready-before-slot" latency.
    prearm_final_slot: u64 = 0,
    prearm_final_unix: i64 = 0,

    // Serve markers.
    last_serve_slot: u64 = 0,
    last_serve_unix: i64 = 0,
    last_serve_peer_id: [64]u8 = [_]u8{0} ** 64,
    last_serve_peer_id_len: u8 = 0,

    // Counters.
    ready_total: u64 = 0,
    serve_total: u64 = 0,
};

pub var g_state: State = .{};

/// Called from prearm when stage transitions to .final. Observational only —
/// we haven't forged anything yet, but pre-arm is indicating a slot is close.
pub fn onPrearmFinal(slot: u64) void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.prearm_final_slot = slot;
    g_state.prearm_final_unix = compat.timestamp();
}

/// Called at EVENT_BLOCK_BUILD. Marks the last-forged block as ready for
/// serving. `header_size`/`body_size` come from the producer's own forge
/// counters — no parsing, no allocation.
pub fn onForge(slot: u64, block_no: u64, header_size: u32, body_size: u32, total_size: u32) void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.ready = true;
    g_state.last_slot = slot;
    g_state.last_block_no = block_no;
    g_state.last_header_size = header_size;
    g_state.last_body_size = body_size;
    g_state.last_total_size = total_size;
    g_state.ready_unix = compat.timestamp();
    g_state.ready_total += 1;
    std.debug.print("ANNOUNCE_READY: slot={d} block={d} size={d} header={d} body={d}\n", .{
        slot, block_no, total_size, header_size, body_size,
    });
    // Phase 10: mark this slot as the current presence sample.
    presence.onAnnounce(slot);
}

/// Called from propagation_server when a relay completes a block-fetch for
/// our sealed tip. peer_id is the relay's IP:port string.
pub fn onServe(slot: u64, peer_id: []const u8) void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.last_serve_slot = slot;
    g_state.last_serve_unix = compat.timestamp();
    const n = @min(peer_id.len, g_state.last_serve_peer_id.len);
    @memcpy(g_state.last_serve_peer_id[0..n], peer_id[0..n]);
    g_state.last_serve_peer_id_len = @intCast(n);
    g_state.serve_total += 1;
    std.debug.print("ANNOUNCE_SERVE: slot={d} peer_id={s}\n", .{ slot, peer_id[0..n] });
    // Phase 10: presence — first-serve yields a notice-latency sample.
    presence.onServe(slot, peer_id[0..n]);
}

pub fn renderJson(buf: []u8) usize {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    var w = compat.fixedBufferStream(buf);
    w.writer().print(
        "{{\"ready\":{s},\"last_slot\":{d},\"last_block\":{d},\"total_size\":{d},\"header_size\":{d},\"body_size\":{d},\"ready_unix\":{d},\"prearm_final_slot\":{d},\"prearm_final_unix\":{d},\"last_serve_slot\":{d},\"last_serve_peer\":\"{s}\",\"last_serve_unix\":{d},\"ready_total\":{d},\"serve_total\":{d}}}",
        .{
            if (g_state.ready) "true" else "false",
            g_state.last_slot,
            g_state.last_block_no,
            g_state.last_total_size,
            g_state.last_header_size,
            g_state.last_body_size,
            g_state.ready_unix,
            g_state.prearm_final_slot,
            g_state.prearm_final_unix,
            g_state.last_serve_slot,
            g_state.last_serve_peer_id[0..g_state.last_serve_peer_id_len],
            g_state.last_serve_unix,
            g_state.ready_total,
            g_state.serve_total,
        },
    ) catch {};
    return w.pos;
}

test "onForge marks ready and increments counter" {
    g_state = .{};
    onForge(100, 10, 80, 1024, 1104);
    try std.testing.expect(g_state.ready);
    try std.testing.expectEqual(@as(u64, 100), g_state.last_slot);
    try std.testing.expectEqual(@as(u32, 1104), g_state.last_total_size);
    try std.testing.expectEqual(@as(u64, 1), g_state.ready_total);
}

test "onServe records peer_id" {
    g_state = .{};
    onServe(200, "127.0.0.1:3001");
    try std.testing.expectEqual(@as(u64, 200), g_state.last_serve_slot);
    try std.testing.expectEqual(@as(u64, 1), g_state.serve_total);
}
