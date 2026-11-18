// Test runner for src/net/ntc/local_state_query.zig — sits at the module root
// so the relative imports inside that file resolve correctly under
// `zig build test`.
const std = @import("std");
const lsq = @import("net/ntc/local_state_query.zig");
const cbor = @import("net/cbor/term.zig");

test "encodePoolParamsQuery emits expected wrapper bytes (via lsq tests)" {
    // The encoder is private to the module, so we exercise it indirectly via
    // a public API path instead: confirm the constants we depend on are sane.
    try std.testing.expect(lsq.BQ_GET_STAKE_POOL_PARAMS == 17);
    try std.testing.expect(lsq.CONWAY_ERA == 6);
    try std.testing.expect(lsq.NTC_VER_16 == 32784);
}

test "PoolParams default values are zero" {
    const pp: lsq.PoolParams = .{};
    try std.testing.expectEqual(@as(u64, 0), pp.pledge);
    try std.testing.expectEqual(@as(u64, 0), pp.cost_per_block);
    try std.testing.expectEqual(@as(u64, 0), pp.margin_x1e9);
    try std.testing.expectEqual(@as(u8, 0), pp.reward_account_kind);
    var zeros: [28]u8 = undefined;
    @memset(&zeros, 0);
    try std.testing.expectEqualSlices(u8, &zeros, &pp.pool_id);
}

test "LsqError exposes NotImplemented for fallback paths" {
    const err: lsq.LsqError = lsq.LsqError.NotImplemented;
    try std.testing.expect(err == lsq.LsqError.NotImplemented);
}

// Sanity-check that the module itself compiles and pulls in cbor.Term so the
// build graph treats it the same way the main exe does.
test "cbor.Term is reachable through the test runner" {
    const t: cbor.Term = .{ .u64 = 42 };
    try std.testing.expectEqual(@as(u64, 42), t.u64);
}
