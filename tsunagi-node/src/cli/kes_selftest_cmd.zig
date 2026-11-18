const std = @import("std");

const SLOTS_PER_KES_PERIOD: u64 = 129600;

const Reason = enum(u8) {
    OK = 0,
    OUT_OF_RANGE = 3,
};

const TestVector = struct {
    slot: u64,
    start_period: u64,
    max_periods: u64,
    expected_period: u64,
    expected_start_slot: u64,
    expected_end_slot: u64,
    expected_valid: bool,
    expected_reason: Reason,
};

const vectors = [_]TestVector{
    // slot=0, start=0, max=1 → valid true, period 0
    .{
        .slot = 0,
        .start_period = 0,
        .max_periods = 1,
        .expected_period = 0,
        .expected_start_slot = 0,
        .expected_end_slot = 129599,
        .expected_valid = true,
        .expected_reason = .OK,
    },
    // slot=129599, start=0, max=1 → valid true, period 0
    .{
        .slot = 129599,
        .start_period = 0,
        .max_periods = 1,
        .expected_period = 0,
        .expected_start_slot = 0,
        .expected_end_slot = 129599,
        .expected_valid = true,
        .expected_reason = .OK,
    },
    // slot=129600, start=0, max=1 → valid false, period 1 (OUT_OF_RANGE)
    .{
        .slot = 129600,
        .start_period = 0,
        .max_periods = 1,
        .expected_period = 1,
        .expected_start_slot = 129600,
        .expected_end_slot = 259199,
        .expected_valid = false,
        .expected_reason = .OUT_OF_RANGE,
    },
    // slot=129600, start=1, max=1 → valid true, period 1
    .{
        .slot = 129600,
        .start_period = 1,
        .max_periods = 1,
        .expected_period = 1,
        .expected_start_slot = 129600,
        .expected_end_slot = 259199,
        .expected_valid = true,
        .expected_reason = .OK,
    },
    // slot=259200, start=1, max=1 → valid false, period 2 (OUT_OF_RANGE)
    .{
        .slot = 259200,
        .start_period = 1,
        .max_periods = 1,
        .expected_period = 2,
        .expected_start_slot = 259200,
        .expected_end_slot = 388799,
        .expected_valid = false,
        .expected_reason = .OUT_OF_RANGE,
    },
};

pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    _ = alloc;

    // Parse optional --slot, --start-period, --max-periods
    var opt_slot: ?u64 = null;
    var opt_start_period: u64 = 0;
    var opt_max_periods: u64 = 62;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--slot")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --slot requires a value\n", .{});
                return 1;
            };
            opt_slot = std.fmt.parseInt(u64, val, 10) catch {
                std.debug.print("ERROR: invalid --slot value: {s}\n", .{val});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--start-period")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --start-period requires a value\n", .{});
                return 1;
            };
            opt_start_period = std.fmt.parseInt(u64, val, 10) catch {
                std.debug.print("ERROR: invalid --start-period value: {s}\n", .{val});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--max-periods")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --max-periods requires a value\n", .{});
                return 1;
            };
            opt_max_periods = std.fmt.parseInt(u64, val, 10) catch {
                std.debug.print("ERROR: invalid --max-periods value: {s}\n", .{val});
                return 1;
            };
        }
    }

    if (opt_slot) |slot| {
        // Single slot test
        std.debug.print("=== TSUNAGI KES Self-Test ===\n\n", .{});
        const result = computeKes(slot, opt_start_period, opt_max_periods);
        printResult(slot, opt_start_period, opt_max_periods, result);
        return 0;
    }

    // Run all built-in test vectors
    std.debug.print("=== TSUNAGI KES Self-Test (5 vectors) ===\n\n", .{});
    var failures: u32 = 0;

    for (vectors, 0..) |v, i| {
        const result = computeKes(v.slot, v.start_period, v.max_periods);
        const pass = result.period == v.expected_period and
            result.start_slot == v.expected_start_slot and
            result.end_slot == v.expected_end_slot and
            result.valid == v.expected_valid and
            result.reason == v.expected_reason;

        const status: []const u8 = if (pass) "PASS" else "FAIL";
        std.debug.print("  vector[{d}]: slot={d} start={d} max={d} → period={d} valid={s} reason={s} [{s}]\n", .{
            i,
            v.slot,
            v.start_period,
            v.max_periods,
            result.period,
            if (result.valid) "true" else "false",
            reasonStr(result.reason),
            status,
        });

        if (!pass) failures += 1;
    }

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("=== KES Self-Test: PASS (5/5) ===\n", .{});
        return 0;
    } else {
        std.debug.print("=== KES Self-Test: FAIL ({d}/5 failed) ===\n", .{failures});
        return 1;
    }
}

const KesResult = struct {
    period: u64,
    start_slot: u64,
    end_slot: u64,
    valid: bool,
    reason: Reason,
};

fn computeKes(slot: u64, start_period: u64, max_periods: u64) KesResult {
    const period = slot / SLOTS_PER_KES_PERIOD;
    const start_slot = period * SLOTS_PER_KES_PERIOD;
    const end_slot = start_slot + SLOTS_PER_KES_PERIOD - 1;
    const end_period_exclusive = start_period + max_periods;

    const valid = period >= start_period and period < end_period_exclusive;
    const reason: Reason = if (valid) .OK else .OUT_OF_RANGE;

    return .{
        .period = period,
        .start_slot = start_slot,
        .end_slot = end_slot,
        .valid = valid,
        .reason = reason,
    };
}

fn reasonStr(r: Reason) []const u8 {
    return switch (r) {
        .OK => "OK",
        .OUT_OF_RANGE => "OUT_OF_RANGE",
    };
}

fn printResult(slot: u64, start_period: u64, max_periods: u64, r: KesResult) void {
    std.debug.print("  slot:              {d}\n", .{slot});
    std.debug.print("  kes_period:        {d}\n", .{r.period});
    std.debug.print("  period_start_slot: {d}\n", .{r.start_slot});
    std.debug.print("  period_end_slot:   {d}\n", .{r.end_slot});
    std.debug.print("  start_period:      {d} (config)\n", .{start_period});
    std.debug.print("  max_periods:       {d} (config)\n", .{max_periods});
    std.debug.print("  kes_valid:         {s}\n", .{if (r.valid) "true" else "false"});
    std.debug.print("  kes_reason:        {s}\n", .{reasonStr(r.reason)});
}
