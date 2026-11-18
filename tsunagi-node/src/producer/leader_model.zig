const std = @import("std");
const compat = @import("compat");

pub const DEFAULT_ASC_X1E6: u64 = 50_000; // Active Slot Coefficient = 0.05

pub const StakeCfg = struct {
    stake_fraction_x1e9: u64,
    asc_x1e6: u64,
    parse_ok: bool,
    error_code: u32,
};

// Error codes (leader model specific)
pub const ERR_OK: u32 = 0;
pub const ERR_DISABLED: u32 = 1;
pub const ERR_MISSING_KEYS: u32 = 2;
pub const ERR_STAKE_MISSING: u32 = 3;
pub const ERR_STAKE_PARSE_FAIL: u32 = 4;
pub const ERR_CLOCK_BAD: u32 = 5;

pub fn loadStakeCfg(alloc: std.mem.Allocator) StakeCfg {
    // Read stake fraction
    const env_frac = compat.getEnvVarOwned(alloc, "TSUNAGI_STAKE_FRACTION_X1E9") catch null;
    const stake_fraction_x1e9: u64 = if (env_frac) |v| blk: {
        defer alloc.free(v);
        const raw = std.fmt.parseUnsigned(u64, v, 10) catch {
            std.debug.print("LEADER_MODEL: stake_fraction parse fail: {s}\n", .{v});
            return StakeCfg{ .stake_fraction_x1e9 = 0, .asc_x1e6 = DEFAULT_ASC_X1E6, .parse_ok = false, .error_code = ERR_STAKE_PARSE_FAIL };
        };
        break :blk @min(raw, 1_000_000_000);
    } else 0;

    // Read ASC override
    const env_asc = compat.getEnvVarOwned(alloc, "TSUNAGI_ACTIVE_SLOT_COEFF_X1E6") catch null;
    const asc_x1e6: u64 = if (env_asc) |v| blk: {
        defer alloc.free(v);
        const raw = std.fmt.parseUnsigned(u64, v, 10) catch DEFAULT_ASC_X1E6;
        break :blk @max(1, @min(raw, 1_000_000));
    } else DEFAULT_ASC_X1E6;

    const has_fraction = env_frac != null;
    if (!has_fraction) {
        return StakeCfg{ .stake_fraction_x1e9 = 0, .asc_x1e6 = asc_x1e6, .parse_ok = true, .error_code = ERR_STAKE_MISSING };
    }

    std.debug.print("LEADER_MODEL: stake_fraction_x1e9={d} asc_x1e6={d}\n", .{ stake_fraction_x1e9, asc_x1e6 });

    return StakeCfg{
        .stake_fraction_x1e9 = stake_fraction_x1e9,
        .asc_x1e6 = asc_x1e6,
        .parse_ok = true,
        .error_code = ERR_OK,
    };
}

/// Compute per-slot leader probability (x1e6) from stake fraction and ASC.
/// prob_x1e6 = (stake_fraction_x1e9 * asc_x1e6) / 1_000_000_000
pub fn computeProbX1e6(stake_fraction_x1e9: u64, asc_x1e6: u64) u64 {
    // Use u128 to avoid overflow: max = 1e9 * 1e6 = 1e15, fits in u64 but safer
    const prod: u128 = @as(u128, stake_fraction_x1e9) * @as(u128, asc_x1e6);
    const result: u64 = @intCast(prod / 1_000_000_000);
    return @min(result, 1_000_000);
}

/// Expected leaders per epoch = stake_fraction_x1e9 * active_slots_per_epoch / 1e9
/// active_slots_per_epoch = (SLOTS_PER_EPOCH * asc_x1e6) / 1e6
pub fn computeExpectedEpoch(stake_fraction_x1e9: u64, asc_x1e6: u64, slots_per_epoch: u64) u64 {
    const active_slots: u128 = (@as(u128, slots_per_epoch) * @as(u128, asc_x1e6)) / 1_000_000;
    const expected: u128 = (@as(u128, stake_fraction_x1e9) * active_slots) / 1_000_000_000;
    return @intCast(@min(expected, 1_000_000_000));
}
