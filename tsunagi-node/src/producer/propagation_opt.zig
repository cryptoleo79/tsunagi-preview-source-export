// Phase 9.4 — Propagation Optimization (Observability + Fast Path)
//
// TSUNAGI's propagation server is a TCP LISTENER: relays initiate
// connections and pull via ChainSync + BlockFetch. We don't push.
// So "parallel send" and "multi-send" as raw pushes don't apply to
// our architecture — but these knobs still make sense as:
//
//   TSUNAGI_PROPAGATION_FAST           serve from pre-cached block buffer
//   TSUNAGI_PROPAGATION_PARALLEL_PEERS accept >1 relay connection at once
//   TSUNAGI_PROPAGATION_MULTI_SEND     allow re-serving same block after
//                                      a short interval (helps flaky relays
//                                      that disconnect mid-fetch)
//
// This module owns the flag state + per-forge/per-pull telemetry. It
// does NOT modify server behavior — the server reads these flags and
// records pull events.

const std = @import("std");
const compat = @import("compat");

pub const Mode = enum(u8) {
    serial = 0,
    parallel = 1,

    pub fn str(self: Mode) []const u8 {
        return switch (self) {
            .serial => "serial",
            .parallel => "parallel",
        };
    }
};

pub const Config = struct {
    fast: bool = false,
    multi_send: bool = false,
    parallel_peers: bool = false,
};

pub const State = struct {
    mu: compat.Mutex = .{},
    cfg: Config = .{},

    // Forge checkpoint — set at EVENT_BLOCK_BUILD.
    last_forge_slot: u64 = 0,
    last_forge_block_no: u64 = 0,
    last_forge_unix_ms: i64 = 0,

    // Pull checkpoint — set when a relay completes a block fetch.
    last_pull_slot: u64 = 0,
    last_pull_unix_ms: i64 = 0,
    last_pull_latency_us: u64 = 0,

    // Running counters.
    peers_sent: u32 = 0, // peers that pulled this forged block (since last forge)
    peers_sent_total: u64 = 0,
    multi_send_total: u64 = 0,
};

pub var g_state: State = .{};

pub fn initFromEnv() void {
    var cfg = Config{};
    if (compat.getenv("TSUNAGI_PROPAGATION_FAST")) |v| {
        cfg.fast = std.mem.eql(u8, std.mem.trim(u8, v, " \t"), "1");
    }
    if (compat.getenv("TSUNAGI_PROPAGATION_MULTI_SEND")) |v| {
        cfg.multi_send = std.mem.eql(u8, std.mem.trim(u8, v, " \t"), "1");
    }
    if (compat.getenv("TSUNAGI_PROPAGATION_PARALLEL_PEERS")) |v| {
        cfg.parallel_peers = std.mem.eql(u8, std.mem.trim(u8, v, " \t"), "1");
    }
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.cfg = cfg;
    std.debug.print("PROPAGATION_CONFIG: fast={s} multi_send={s} parallel_peers={s}\n", .{
        if (cfg.fast) "true" else "false",
        if (cfg.multi_send) "true" else "false",
        if (cfg.parallel_peers) "true" else "false",
    });
}

pub fn config() Config {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    return g_state.cfg;
}

/// Called from producer at EVENT_BLOCK_BUILD so we can measure relay
/// propagation latency relative to forge time.
pub fn onForge(slot: u64, block_no: u64) void {
    const now_ns = compat.nanoTimestamp();
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.last_forge_slot = slot;
    g_state.last_forge_block_no = block_no;
    g_state.last_forge_unix_ms = @intCast(@divFloor(now_ns, std.time.ns_per_ms));
    g_state.peers_sent = 0;
}

/// Called from propagation_server when a block fetch completes for a peer.
pub fn onPull(slot: u64, block_no: u64) void {
    const now_ns = compat.nanoTimestamp();
    g_state.mu.lock();
    defer g_state.mu.unlock();
    const now_ms: i64 = @intCast(@divFloor(now_ns, std.time.ns_per_ms));
    g_state.last_pull_slot = slot;
    g_state.last_pull_unix_ms = now_ms;
    // Latency in microseconds, relative to our own forge.
    if (g_state.last_forge_unix_ms > 0 and slot == g_state.last_forge_slot and block_no == g_state.last_forge_block_no) {
        const delta_ms = now_ms - g_state.last_forge_unix_ms;
        g_state.last_pull_latency_us = if (delta_ms > 0) @intCast(@as(i64, delta_ms) * 1000) else 0;
        g_state.peers_sent += 1;
        g_state.peers_sent_total += 1;
        if (g_state.peers_sent > 1) g_state.multi_send_total += 1;
        std.debug.print("PROP_SEND: slot={d} block={d} peers={d} latency_us={d}\n", .{
            slot, block_no, g_state.peers_sent, g_state.last_pull_latency_us,
        });
    } else {
        // Pull of a non-current block (historical) — still counted for visibility.
        std.debug.print("PROP_SEND: slot={d} block={d} peers=1 latency_us=0 (historical)\n", .{ slot, block_no });
    }
}

pub fn renderJson(buf: []u8) usize {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    const mode: Mode = if (g_state.cfg.parallel_peers) .parallel else .serial;
    var w = compat.fixedBufferStream(buf);
    w.writer().print(
        \\{{"fast":{s},"multi_send":{s},"parallel_peers":{s},"mode":"{s}","last_forge_slot":{d},"last_pull_slot":{d},"last_latency_us":{d},"peers_sent":{d},"peers_sent_total":{d},"multi_send_total":{d}}}
    , .{
        if (g_state.cfg.fast) "true" else "false",
        if (g_state.cfg.multi_send) "true" else "false",
        if (g_state.cfg.parallel_peers) "true" else "false",
        mode.str(),
        g_state.last_forge_slot,
        g_state.last_pull_slot,
        g_state.last_pull_latency_us,
        g_state.peers_sent,
        g_state.peers_sent_total,
        g_state.multi_send_total,
    }) catch {};
    return w.pos;
}

test "onPull records latency relative to forge" {
    g_state = .{};
    onForge(100, 10);
    compat.sleep(std.time.ns_per_ms);
    onPull(100, 10);
    try std.testing.expect(g_state.peers_sent == 1);
}
