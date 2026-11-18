// Tests for producer.heartbeatKesPeriod — wall-clock KES period bookkeeping
// independent of block arrival.
const std = @import("std");
const producer = @import("producer/producer.zig");

test "heartbeatKesPeriod computes period from slot" {
    var ctx: producer.ProducerContext = std.mem.zeroes(producer.ProducerContext);
    // Enable signing and set a wide validity window so the slot under test
    // falls inside [start, start+max).
    ctx.kes_sign_enabled = true;
    ctx.kes_start_period = 0;
    ctx.kes_max_periods = 10_000;

    const slot: u64 = 110_438_405;
    producer.heartbeatKesPeriod(&ctx, slot);

    // 110_438_405 / 129_600 = 852
    try std.testing.expectEqual(@as(u64, 852), ctx.kes_current_period_last);
    try std.testing.expectEqual(@as(u64, 1), ctx.kes_period_valid_last);
    try std.testing.expectEqual(@as(u64, 0), ctx.kes_period_reason_code_last);
    try std.testing.expect(ctx.kes_period_seen);
}

test "heartbeatKesPeriod with signing disabled sets reason_code=1" {
    var ctx: producer.ProducerContext = std.mem.zeroes(producer.ProducerContext);
    ctx.kes_sign_enabled = false;
    ctx.kes_start_period = 0;
    ctx.kes_max_periods = 10_000;

    producer.heartbeatKesPeriod(&ctx, 110_438_405);

    try std.testing.expectEqual(@as(u64, 852), ctx.kes_current_period_last);
    try std.testing.expectEqual(@as(u64, 0), ctx.kes_period_valid_last);
    try std.testing.expectEqual(@as(u64, 1), ctx.kes_period_reason_code_last);
}
