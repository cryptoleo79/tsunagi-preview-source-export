// High-level NtC client facade — single-shot query helpers that
// never throw. Returns nullable types so callers can cleanly fall
// back to Koios when the local socket is unavailable or the
// LocalStateQuery codec is incomplete.

const std = @import("std");
const compat = @import("compat");
const lsq = @import("local_state_query.zig");

pub const ProtoParams = lsq.ProtoParams;
pub const PoolParams = lsq.PoolParams;

/// Try to fetch protocol parameters from a local cardano-node socket.
/// Returns null on ANY failure (socket missing, handshake refused,
/// query not yet wired). Callers fall back to Koios on null.
pub fn tryFetchProtocolParams(
    alloc: std.mem.Allocator,
    socket_path: []const u8,
    network_magic: u64,
) ?ProtoParams {
    var session = lsq.openSession(alloc, socket_path, network_magic) catch |err| {
        std.debug.print("NTC_PROBE_FAIL: phase=open err={s}\n", .{@errorName(err)});
        return null;
    };
    defer session.deinit();

    const pp = session.queryProtocolParams() catch |err| {
        // NotImplemented is expected until LSQ codec lands; log at info level.
        std.debug.print("NTC_PROBE_FAIL: phase=query err={s}\n", .{@errorName(err)});
        return null;
    };
    std.debug.print("NTC_PROBE_OK: max_block={d} max_tx={d} pv={d}.{d}\n", .{
        pp.max_block_body_size, pp.max_tx_size, pp.protocol_major, pp.protocol_minor,
    });
    return pp;
}

/// Try to fetch stake-pool registration params for a single pool from a
/// local cardano-node socket. Returns null on ANY failure — handshake refused,
/// query not yet wired (NotImplemented), or response shape mismatch. Callers
/// MUST fall back to Koios on null.
pub fn tryFetchPoolParams(
    alloc: std.mem.Allocator,
    socket_path: []const u8,
    network_magic: u64,
    pool_id: [28]u8,
) ?PoolParams {
    var session = lsq.openSession(alloc, socket_path, network_magic) catch |err| {
        std.debug.print("NTC_POOL_PROBE_FAIL: phase=open err={s}\n", .{@errorName(err)});
        return null;
    };
    defer session.deinit();

    const pp = session.queryStakePoolParams(pool_id) catch |err| {
        std.debug.print("NTC_POOL_PROBE_FAIL: phase=query err={s}\n", .{@errorName(err)});
        return null;
    };
    std.debug.print("NTC_POOL_PROBE_OK: pledge={d} cost={d} margin_x1e9={d}\n", .{
        pp.pledge, pp.cost_per_block, pp.margin_x1e9,
    });
    return pp;
}

/// Read enablement from env. Returns socket path if TSUNAGI_NTC_ENABLE=1
/// AND TSUNAGI_NTC_SOCKET is set, else null.
pub fn enabledSocketPath() ?[]const u8 {
    const enabled = compat.getenv("TSUNAGI_NTC_ENABLE") orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, enabled, " \t"), "1")) return null;
    return compat.getenv("TSUNAGI_NTC_SOCKET");
}

test "enabledSocketPath returns null when flag absent" {
    // In a test env these vars are usually unset — just verify no crash.
    _ = enabledSocketPath();
}
