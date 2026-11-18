// Pool stats aggregator.
//
// Combines:
//   - g_stake_dist (live local follower state) → our_pool_lovelace,
//     total_staked_lovelace, delegator count
//   - tryFetchPoolParams (NtC → Koios fallback) → pledge / fixed_fee / margin
//   - genesis nOpt → for saturation math
//
// Cached behind a mutex so /status/full hits never trigger network IO. Refresh
// is explicit (epoch boundary or operator trigger). All fields zero by default
// — module renders "{...}" with zeroes if no refresh has happened yet, never
// crashes.
//
// Saturation math (matches Cardano gLiveView):
//   target_per_pool = total_supply / n_opt
//   saturation_x1e9 = (our_pool_lovelace * 1e9) / target_per_pool
// Total supply: 45e15 lovelace (45 B ADA mainnet hard-cap). For preview /
// preprod the absolute value differs but the relative saturation is still
// informational; the dashboard caller may override later.

const std = @import("std");
const compat = @import("compat");
const protocol_manager = @import("protocol_manager.zig");

/// Live stake snapshot supplied by the caller (typically the chainsync
/// follower passing a const pointer to its `g_stake_dist`). Decoupled here
/// so this module's tests do not have to depend on the follower's heavy
/// transitive deps. All fields zero-default; renderJson tolerates a nil
/// pointer gracefully.
pub const LiveStakeView = struct {
    our_pool_lovelace: u64 = 0,
    total_staked_lovelace: u64 = 0,
    credential_count: u32 = 0,
};

/// Function-pointer hook the caller installs to feed live stake numbers
/// without forcing a hard dependency on follower internals. Returning a
/// zero-init LiveStakeView is fine when the source is not yet ready.
pub const LiveStakeFn = *const fn () LiveStakeView;

var g_live_fn: ?LiveStakeFn = null;

/// Install the live-stake source. Pass null to detach (test reset).
pub fn setLiveSource(fn_ptr: ?LiveStakeFn) void {
    g_live_fn = fn_ptr;
}

fn liveSnapshot() LiveStakeView {
    if (g_live_fn) |f| return f();
    return .{};
}

/// Cardano hard-capped total supply in lovelace (45 B ADA). Treated as a
/// constant for the purposes of saturation display; ideally this would come
/// from an LSQ GetTotalSupply / GetCirculatingSupply query. Dashboard
/// consumers should treat the value as informational.
pub const TOTAL_SUPPLY_LOVELACE: u64 = 45_000_000_000_000_000;

pub const PoolStats = struct {
    pledge: u64 = 0,
    fixed_fee: u64 = 0,
    margin_x1e9: u64 = 0,
    our_pool_lovelace: u64 = 0,
    total_staked: u64 = 0,
    n_opt: u64 = 500,
    delegators: u64 = 0,
    saturation_x1e9: u64 = 0,
};

var g_mu: compat.Mutex = .{};
var g_stats: PoolStats = .{};
var g_last_refresh_unix: i64 = 0;

/// Compute saturation_x1e9 given the stake we own and the protocol target.
/// Pure function — exposed for test coverage.
pub fn computeSaturation(our_lovelace: u64, total_supply: u64, n_opt: u64) u64 {
    if (n_opt == 0 or total_supply == 0) return 0;
    const target_per_pool: u128 = @as(u128, total_supply) / @as(u128, n_opt);
    if (target_per_pool == 0) return 0;
    const num: u128 = @as(u128, our_lovelace) * 1_000_000_000;
    const sat = num / target_per_pool;
    // Cap at u64 max so callers don't have to worry about overflow display.
    return @intCast(@min(sat, std.math.maxInt(u64)));
}

/// Reset to zero. Test helper.
pub fn resetForTest() void {
    g_mu.lock();
    defer g_mu.unlock();
    g_stats = .{};
    g_last_refresh_unix = 0;
}

/// Refresh the cache. Reads g_stake_dist locally and may issue a single
/// outbound NtC + Koios fetch for pool params. Cheap when called at most
/// once per epoch boundary; do NOT call from /status/full hot path.
pub fn refresh(
    alloc: std.mem.Allocator,
    net: []const u8,
    pool_bech32: []const u8,
    pool_id: [28]u8,
    n_opt: u64,
) void {
    // Pull live numbers from the registered LiveStakeView FIRST so we always
    // have something to render even if the network leg fails.
    const live = liveSnapshot();
    const our_lovelace: u64 = live.our_pool_lovelace;
    const total_staked: u64 = live.total_staked_lovelace;
    const delegators: u64 = live.credential_count;

    var pledge: u64 = 0;
    var fixed_fee: u64 = 0;
    var margin_x1e9: u64 = 0;
    if (protocol_manager.tryFetchPoolParams(alloc, net, pool_bech32, pool_id)) |pp| {
        pledge = pp.pledge;
        fixed_fee = pp.cost_per_block;
        margin_x1e9 = pp.margin_x1e9;
    } else {
        // Preserve last-known values across refreshes when both NtC and Koios
        // are unavailable; a transient network blip should not zero the UI.
        g_mu.lock();
        pledge = g_stats.pledge;
        fixed_fee = g_stats.fixed_fee;
        margin_x1e9 = g_stats.margin_x1e9;
        g_mu.unlock();
    }

    const effective_n_opt: u64 = if (n_opt == 0) 500 else n_opt;
    const sat = computeSaturation(our_lovelace, TOTAL_SUPPLY_LOVELACE, effective_n_opt);

    g_mu.lock();
    defer g_mu.unlock();
    g_stats = .{
        .pledge = pledge,
        .fixed_fee = fixed_fee,
        .margin_x1e9 = margin_x1e9,
        .our_pool_lovelace = our_lovelace,
        .total_staked = total_staked,
        .n_opt = effective_n_opt,
        .delegators = delegators,
        .saturation_x1e9 = sat,
    };
    g_last_refresh_unix = compat.timestamp();
    std.debug.print("POOL_STATS_REFRESH: pledge={d} fixed_fee={d} margin_x1e9={d} our={d} total={d} n_opt={d} delegators={d} sat_x1e9={d}\n", .{
        pledge, fixed_fee, margin_x1e9, our_lovelace, total_staked,
        effective_n_opt, delegators, sat,
    });
}

/// Render the JSON body. Always emits a complete object; never panics.
/// Reads live stake fields from g_stake_dist on every call (cheap, no IO);
/// pledge / fixed_fee / margin come from the last cached refresh.
pub fn renderJson(buf: []u8) usize {
    g_mu.lock();
    var snap = g_stats;
    const refresh_unix = g_last_refresh_unix;
    g_mu.unlock();

    // Always overlay the freshest local numbers — operators expect them to
    // update independently of the cached pool-params refresh cadence.
    const live = liveSnapshot();
    snap.our_pool_lovelace = live.our_pool_lovelace;
    snap.total_staked = live.total_staked_lovelace;
    snap.delegators = live.credential_count;
    if (snap.n_opt == 0) snap.n_opt = 500;
    snap.saturation_x1e9 = computeSaturation(snap.our_pool_lovelace, TOTAL_SUPPLY_LOVELACE, snap.n_opt);

    const sat_pct: f64 = @as(f64, @floatFromInt(snap.saturation_x1e9)) / 1e7;
    var w = compat.fixedBufferStream(buf);
    const out = w.writer();
    out.print(
        \\{{"pledge":{d},"fixed_fee":{d},"margin_x1e9":{d},"our_pool_lovelace":{d},"total_staked":{d},"n_opt":{d},"delegators":{d},"saturation_x1e9":{d},"saturation_pct":{d:.4},"refresh_unix":{d}}}
    , .{
        snap.pledge, snap.fixed_fee, snap.margin_x1e9,
        snap.our_pool_lovelace, snap.total_staked,
        snap.n_opt, snap.delegators, snap.saturation_x1e9,
        sat_pct, refresh_unix,
    }) catch {};
    return w.pos;
}

// ── Tests ───────────────────────────────────────────────────────────

test "computeSaturation: half-target stake yields 0.5e9" {
    // total_supply=1000, n_opt=2 → target=500. our=250 → 250/500 = 0.5 → 5e8.
    const sat = computeSaturation(250, 1000, 2);
    try std.testing.expectEqual(@as(u64, 500_000_000), sat);
}

test "computeSaturation: at target yields 1e9" {
    const sat = computeSaturation(500, 1000, 2);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), sat);
}

test "computeSaturation: zero n_opt yields zero" {
    const sat = computeSaturation(500, 1000, 0);
    try std.testing.expectEqual(@as(u64, 0), sat);
}

test "computeSaturation: realistic mainnet-ish numbers" {
    // ~70 M ADA pool, 45 B ADA supply, n_opt=500 → target = 90 M ADA.
    // 70/90 = 0.7777 → ~777_777_777 in x1e9.
    const our: u64 = 70_000_000_000_000; // 70 M ADA in lovelace
    const sat = computeSaturation(our, TOTAL_SUPPLY_LOVELACE, 500);
    try std.testing.expect(sat >= 770_000_000 and sat <= 780_000_000);
}

test "renderJson emits keys we expect" {
    resetForTest();
    var buf: [512]u8 = undefined;
    const n = renderJson(&buf);
    try std.testing.expect(n > 0);
    const s = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, s, "\"pledge\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"saturation_x1e9\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"saturation_pct\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"delegators\":") != null);
}
