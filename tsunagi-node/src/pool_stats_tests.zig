// Test runner shim for src/producer/pool_stats.zig — sits at the module root
// so the relative imports inside that file resolve correctly under
// `zig build test`. The pool_stats inline tests cover computeSaturation and
// renderJson; this file imports the module so those tests get picked up.
//
// Note: protocol_manager pulls in mempool_mod, which transitively reaches
// LMDB-backed code. We compile against libc + lmdb (matching ledger_tests).
const std = @import("std");
const pool_stats = @import("producer/pool_stats.zig");

test "computeSaturation reachable through shim" {
    try std.testing.expectEqual(@as(u64, 1_000_000_000), pool_stats.computeSaturation(500, 1000, 2));
}

test "TOTAL_SUPPLY_LOVELACE matches mainnet hard cap" {
    try std.testing.expectEqual(@as(u64, 45_000_000_000_000_000), pool_stats.TOTAL_SUPPLY_LOVELACE);
}

test "renderJson without live source returns valid JSON" {
    pool_stats.setLiveSource(null);
    pool_stats.resetForTest();
    var buf: [512]u8 = undefined;
    const n = pool_stats.renderJson(&buf);
    try std.testing.expect(n > 0 and n < buf.len);
    try std.testing.expect(buf[0] == '{');
    try std.testing.expect(buf[n - 1] == '}');
}

test "live source feeds renderJson with non-zero values" {
    const Stub = struct {
        fn read() pool_stats.LiveStakeView {
            return .{
                .our_pool_lovelace = 70_000_000_000_000,
                .total_staked_lovelace = 1_000_000_000_000_000,
                .credential_count = 42,
            };
        }
    };
    pool_stats.setLiveSource(Stub.read);
    var buf: [512]u8 = undefined;
    const n = pool_stats.renderJson(&buf);
    const s = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, s, "\"delegators\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"our_pool_lovelace\":70000000000000") != null);
    pool_stats.setLiveSource(null);
}
