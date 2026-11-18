// Phase 8.5 — Leader Schedule Engine
//
// Self-contained VRF-based leader-slot scanner for operator visibility.
// Runs as a detached background thread, scans the remainder of the current
// epoch once, caches results, and re-scans on epoch boundary / sigma change.
//
// This is ADVISORY. It does NOT feed into forge-path leader detection —
// the producer's per-slot VRF check remains the source of truth for forging.

const std = @import("std");
const compat = @import("compat");
const shutdown = @import("../ops/shutdown.zig");
const vrf = @import("vrf.zig");
const producer = @import("producer.zig");
const exec_quality = @import("exec_quality.zig");
const prearm = @import("prearm.zig");
const alerts = @import("alerts.zig");

const MAX_LEADERS: usize = 100;
/// How many slots ahead to scan. 43,200 = 12 hours of preview slots.
const SCAN_HORIZON: u64 = 43_200;
/// Refresh cadence when no trigger (epoch/sigma change) fires.
const REFRESH_INTERVAL_S: u64 = 300;
/// Threshold for "sigma changed significantly" (delta in x1e9 units).
const SIGMA_CHANGE_DELTA: u64 = 1_000_000; // 0.1% of 1.0

pub const LeaderSlot = struct {
    slot: u64 = 0,
    time_unix: i64 = 0,
    u_x1e12: u64 = 0,
    thresh_x1e12: u64 = 0,
    margin: i64 = 0, // thresh - u (positive = leader win)
};

pub const Schedule = struct {
    mu: compat.Mutex = .{},
    leaders: [MAX_LEADERS]LeaderSlot = [_]LeaderSlot{.{}} ** MAX_LEADERS,
    count: u32 = 0,
    last_scan_epoch: u64 = 0,
    last_scan_sigma_x1e9: u64 = 0,
    last_scan_unix: i64 = 0,
    scan_range_start: u64 = 0,
    scan_range_end: u64 = 0,
    scans_total: u64 = 0,
    /// Set when the next leader slot has fewer than 120s remaining AND
    /// we've emitted EVENT_LEADER_IMMINENT for it — prevents duplicate emits.
    imminent_emitted_slot: u64 = 0,
};

pub var g_schedule: Schedule = .{};

/// Compute the unix timestamp for an absolute slot on preview.
/// Preview genesis slot-0 = unix 1666656000; 1 slot = 1s.
fn slotToUnix(slot: u64) i64 {
    return @as(i64, @intCast(slot)) + 1666656000;
}

fn unixNow() i64 {
    return compat.timestamp();
}

/// Spawn the background scanner. Reads everything from producer_ctx.
pub fn spawnBackground(alloc: std.mem.Allocator, ctx: *producer.ProducerContext) bool {
    const thread = std.Thread.spawn(.{}, scanThread, .{ctx}) catch {
        std.debug.print("LEADER_SCHEDULE_SPAWN: thread spawn failed\n", .{});
        return false;
    };
    thread.detach();
    _ = alloc;
    std.debug.print("LEADER_SCHEDULE_SPAWN: ready horizon={d} slots refresh={d}s\n", .{
        SCAN_HORIZON, REFRESH_INTERVAL_S,
    });
    return true;
}

fn scanThread(ctx: *producer.ProducerContext) void {
    // Initial wait — let nonce bootstrap and sigma stabilise.
    compat.sleep(10 * std.time.ns_per_s);
    while (true) {
        if (shutdown.stopRequested()) return;
        if (shouldRescan(ctx)) {
            runScan(ctx);
        }
        compat.sleep(REFRESH_INTERVAL_S * std.time.ns_per_s);
    }
}

fn shouldRescan(ctx: *producer.ProducerContext) bool {
    g_schedule.mu.lock();
    const last_epoch = g_schedule.last_scan_epoch;
    const last_sigma = g_schedule.last_scan_sigma_x1e9;
    const last_unix = g_schedule.last_scan_unix;
    g_schedule.mu.unlock();

    // Never scanned → yes.
    if (last_unix == 0) return true;

    // Epoch changed → yes.
    if (ctx.nonce_state.nonce_epoch != 0 and ctx.nonce_state.nonce_epoch != last_epoch) return true;

    // Sigma changed significantly → yes.
    const cur_sigma: u64 = producer.resolveAuthoritativeSigma(ctx).sigma_x1e9; // Variant B
    const diff: u64 = if (cur_sigma > last_sigma) cur_sigma - last_sigma else last_sigma - cur_sigma;
    if (diff > SIGMA_CHANGE_DELTA) return true;

    return false;
}

fn runScan(ctx: *producer.ProducerContext) void {
    // Prerequisites: nonce + VRF + stake present.
    if (!ctx.nonce_initialized) {
        std.debug.print("LEADER_SCHEDULE_SKIP: nonce_not_initialized\n", .{});
        return;
    }
    if (!ctx.vrf_cfg.init_ok or !ctx.vrf_cfg.parse_ok) {
        std.debug.print("LEADER_SCHEDULE_SKIP: vrf_not_ready\n", .{});
        return;
    }
    const sig_res = producer.resolveAuthoritativeSigma(ctx); // Variant B: shared resolver
    const sigma: u64 = sig_res.sigma_x1e9;
    if (sigma == 0) {
        std.debug.print("LEADER_SCHEDULE_SKIP: sigma_zero\n", .{});
        return;
    }

    const thresh = producer.computeThreshX1e12(sigma, ctx.stake_cfg.asc_x1e6);
    if (thresh == 0) {
        std.debug.print("LEADER_SCHEDULE_SKIP: thresh_zero\n", .{});
        return;
    }

    // Compute scan range: [now_slot, min(now + horizon, epoch_end)]
    const now_unix = unixNow();
    const now_slot: u64 = if (now_unix > 1666656000) @intCast(now_unix - 1666656000) else 0;
    if (now_slot == 0) {
        std.debug.print("LEADER_SCHEDULE_SKIP: pre_genesis\n", .{});
        return;
    }
    // Use ACTUAL current epoch from slot math (not nonce_epoch which lags
    // by 1 across the boundary until the auto-fetch runs).
    const shelley_slot = if (now_slot > ctx.shelley_start_slot) now_slot - ctx.shelley_start_slot else 0;
    const current_epoch = ctx.shelley_start_epoch + (shelley_slot / ctx.slots_per_epoch);
    // Refuse to scan with a stale nonce — would produce candidates that
    // forge against epoch N-1's nonce, which cardano-node rejects.
    if (ctx.nonce_state.nonce_epoch != current_epoch) {
        std.debug.print("LEADER_SCHEDULE_SKIP: nonce_stale nonce_epoch={d} current_epoch={d}\n", .{
            ctx.nonce_state.nonce_epoch, current_epoch,
        });
        return;
    }
    const epoch_end_slot = (current_epoch + 1) * ctx.slots_per_epoch;
    var end_slot = now_slot + SCAN_HORIZON;
    if (end_slot > epoch_end_slot) end_slot = epoch_end_slot;
    if (end_slot <= now_slot) {
        std.debug.print("LEADER_SCHEDULE_SKIP: range_empty now={d} end={d}\n", .{ now_slot, end_slot });
        return;
    }

    // Nonce pointer
    const nonce_ptr: *const [32]u8 = &ctx.nonce_state.epoch_nonce;

    // Scan. VRF prove is slow-ish (~0.5ms each). 43K slots = ~21s.
    const t_start = compat.nanoTimestamp();
    var leaders_buf: [MAX_LEADERS]LeaderSlot = undefined;
    var lcount: u32 = 0;
    var s: u64 = now_slot;
    while (s < end_slot and lcount < MAX_LEADERS) : (s += 1) {
        const res = vrf.checkLeader(&ctx.vrf_cfg, s, nonce_ptr, 0, true);
        if (!res.checked or !res.output_present) continue;
        const u = producer.vrfOutputToU_x1e12(res.output_bytes);
        if (u < thresh) {
            leaders_buf[lcount] = .{
                .slot = s,
                .time_unix = slotToUnix(s),
                .u_x1e12 = u,
                .thresh_x1e12 = thresh,
                .margin = @as(i64, @intCast(thresh)) - @as(i64, @intCast(u)),
            };
            lcount += 1;
        }
    }
    const t_end = compat.nanoTimestamp();
    const elapsed_ms: u64 = @intCast(@max(0, @divFloor(t_end - t_start, 1_000_000)));

    // Commit under lock.
    g_schedule.mu.lock();
    {
        var i: u32 = 0;
        while (i < lcount) : (i += 1) g_schedule.leaders[i] = leaders_buf[i];
        g_schedule.count = lcount;
        g_schedule.last_scan_epoch = current_epoch;
        g_schedule.last_scan_sigma_x1e9 = sigma;
        g_schedule.last_scan_unix = now_unix;
        g_schedule.scan_range_start = now_slot;
        g_schedule.scan_range_end = end_slot;
        g_schedule.scans_total += 1;
        // Reset imminent guard if the slot we emitted for is now behind us.
        if (g_schedule.imminent_emitted_slot != 0 and now_slot > g_schedule.imminent_emitted_slot) {
            g_schedule.imminent_emitted_slot = 0;
        }
    }
    g_schedule.mu.unlock();

    // Log summary — next leader + count + scan duration.
    // Emit EXEC_SCORE alongside schedule — single source of current readiness.
    const qsnap = exec_quality.currentScore();
    if (lcount == 0) {
        std.debug.print("LEADER_SCHEDULE: scanned={d} slots range=[{d},{d}) found=0 sigma={d} sigma_source={s} thresh_x1e12={d} elapsed_ms={d}\n", .{
            end_slot - now_slot, now_slot, end_slot, sigma, sig_res.source.name(), thresh, elapsed_ms,
        });
        // Phase 9.5: operator visibility — always communicate scan outcome.
        std.debug.print("SCHEDULE_EMPTY: window_slots={d} range=[{d},{d})\n", .{
            end_slot - now_slot, now_slot, end_slot,
        });
    } else {
        const nxt = leaders_buf[0];
        const eta = nxt.time_unix - now_unix;
        std.debug.print("LEADER_SCHEDULE: next_slot={d} eta_sec={d} margin={d} count={d} sigma={d} sigma_source={s} range=[{d},{d}) elapsed_ms={d}\n", .{
            nxt.slot, eta, nxt.margin, lcount, sigma, sig_res.source.name(), now_slot, end_slot, elapsed_ms,
        });
        std.debug.print("EXEC_SCORE: slot={d} score={d} rating={s} gap={d} advantage={d} latency={d}\n", .{
            nxt.slot, qsnap.score, qsnap.rating.str(), qsnap.parent_gap, qsnap.probe_advantage, qsnap.latency_ms,
        });
        // Phase 9.5: operator visibility — always show next slot after each scan.
        const conf = confidenceLabel(nxt.margin, nxt.thresh_x1e12);
        std.debug.print("SCHEDULE_NEXT: slot={d} eta_sec={d} confidence={s}\n", .{
            nxt.slot, eta, conf,
        });
    }
}

/// Phase 9.5 snapshot of the next upcoming leader, or null if none.
/// Cheap — O(count) scan over cached leaders.
pub const NextLeader = struct {
    slot: u64,
    eta_sec: i64,
    confidence: []const u8,
};

pub fn nextLeader(now_slot: u64) ?NextLeader {
    g_schedule.mu.lock();
    defer g_schedule.mu.unlock();
    if (g_schedule.count == 0) return null;
    var i: u32 = 0;
    while (i < g_schedule.count) : (i += 1) {
        const L = g_schedule.leaders[i];
        if (L.slot <= now_slot) continue;
        return .{
            .slot = L.slot,
            .eta_sec = @as(i64, @intCast(L.slot)) - @as(i64, @intCast(now_slot)),
            .confidence = confidenceLabel(L.margin, L.thresh_x1e12),
        };
    }
    return null;
}

/// Called from producer tick every slot — emits EVENT_LEADER_IMMINENT at T-120s.
/// Cheap: O(count) linear scan over cached leaders, no VRF work.
pub fn checkImminent(now_slot: u64) void {
    // Snapshot the next leader (locked briefly), then release before side effects.
    var next: ?struct {
        slot: u64,
        eta: i64,
        margin: i64,
        thresh: u64,
        is_imminent: bool,
    } = null;
    g_schedule.mu.lock();
    if (g_schedule.count > 0) {
        var i: u32 = 0;
        while (i < g_schedule.count) : (i += 1) {
            const L = g_schedule.leaders[i];
            if (L.slot <= now_slot) continue;
            const eta: i64 = @as(i64, @intCast(L.slot)) - @as(i64, @intCast(now_slot));
            const is_imminent = eta <= 120 and L.slot != g_schedule.imminent_emitted_slot;
            if (is_imminent) g_schedule.imminent_emitted_slot = L.slot;
            next = .{
                .slot = L.slot,
                .eta = eta,
                .margin = L.margin,
                .thresh = L.thresh_x1e12,
                .is_imminent = is_imminent,
            };
            break;
        }
    }
    g_schedule.mu.unlock();

    if (next) |n| {
        const conf = confidenceLabel(n.margin, n.thresh);
        // Phase 9.5: drive alerts + status with every call (idempotent per slot/tier).
        alerts.onUpcomingLeader(n.slot, n.eta, conf);

        if (n.is_imminent) {
            const snap = exec_quality.currentScore();
            std.debug.print("EVENT_LEADER_IMMINENT: slot={d} eta={d} margin={d} score={d} rating={s}\n", .{
                n.slot, n.eta, n.margin, snap.score, snap.rating.str(),
            });
            // Phase 8.95: arm pre-arm system for this upcoming slot.
            prearm.onImminent(n.slot);
        }
    }
}

/// Render the schedule block as JSON. ALWAYS returns a valid object even
/// on write failure or empty state. Fallback shape:
///   {"count":0,"scan_epoch":0,"scan_unix":0,"range":[0,0],"next_slot":0,
///    "eta_sec":0,"confidence":"none","leaders":[]}
pub fn renderJson(buf: []u8) usize {
    const safe_empty = "{\"count\":0,\"scan_epoch\":0,\"scan_unix\":0,\"range\":[0,0],\"next_slot\":0,\"eta_sec\":0,\"confidence\":\"none\",\"leaders\":[]}";

    // Snapshot everything we need under the lock, then release before
    // writing. This keeps lock hold time bounded and lets us retry the
    // write into `buf` without deadlock risk.
    var snap_count: u32 = 0;
    var snap_epoch: u64 = 0;
    var snap_unix: i64 = 0;
    var snap_range_start: u64 = 0;
    var snap_range_end: u64 = 0;
    const now = unixNow();
    const now_slot: u64 = if (now > 1666656000) @intCast(now - 1666656000) else 0;

    var top_next_slot: u64 = 0;
    var top_eta: i64 = 0;
    var top_conf: []const u8 = "none";

    // Copy up to max_render pending leaders for body emission.
    const max_render: u32 = 10;
    var pending: [max_render]LeaderSlot = undefined;
    var pending_n: u32 = 0;

    g_schedule.mu.lock();
    {
        snap_count = g_schedule.count;
        snap_epoch = g_schedule.last_scan_epoch;
        snap_unix = g_schedule.last_scan_unix;
        snap_range_start = g_schedule.scan_range_start;
        snap_range_end = g_schedule.scan_range_end;

        var i: u32 = 0;
        while (i < g_schedule.count) : (i += 1) {
            const L = g_schedule.leaders[i];
            if (L.slot <= now_slot) continue;
            if (top_next_slot == 0) {
                top_next_slot = L.slot;
                top_eta = L.time_unix - now;
                top_conf = confidenceLabel(L.margin, L.thresh_x1e12);
            }
            if (pending_n < max_render) {
                pending[pending_n] = L;
                pending_n += 1;
            } else break;
        }
    }
    g_schedule.mu.unlock();

    const snap = exec_quality.currentScore();

    var w = compat.fixedBufferStream(buf);
    const out = w.writer();

    // Single emit path. On ANY write failure, fall through to safe_empty.
    const ok = blk: {
        out.print(
            "{{\"count\":{d},\"scan_epoch\":{d},\"scan_unix\":{d},\"range\":[{d},{d}],\"next_slot\":{d},\"eta_sec\":{d},\"confidence\":\"{s}\",\"leaders\":[",
            .{
                snap_count,
                snap_epoch,
                snap_unix,
                snap_range_start,
                snap_range_end,
                top_next_slot,
                top_eta,
                top_conf,
            },
        ) catch break :blk false;

        var j: u32 = 0;
        while (j < pending_n) : (j += 1) {
            const L = pending[j];
            const eta: i64 = L.time_unix - now;
            if (j > 0) out.writeAll(",") catch break :blk false;
            out.print(
                "{{\"slot\":{d},\"eta_sec\":{d},\"margin\":{d},\"score\":{d},\"rating\":\"{s}\",\"parent_gap\":{d},\"probe_advantage\":{d},\"latency_ms\":{d}}}",
                .{
                    L.slot, eta, L.margin,
                    snap.score, snap.rating.str(), snap.parent_gap, snap.probe_advantage, snap.latency_ms,
                },
            ) catch break :blk false;
        }
        out.writeAll("]}") catch break :blk false;
        break :blk true;
    };

    if (ok) return w.pos;

    // Fallback: emit the canonical empty object so jq .schedule always works.
    const n = @min(buf.len, safe_empty.len);
    @memcpy(buf[0..n], safe_empty[0..n]);
    return n;
}

/// Phase 8.55: classify confidence by margin/threshold ratio.
fn confidenceLabel(margin: i64, threshold: u64) []const u8 {
    if (margin <= 0 or threshold == 0) return "tight";
    const ratio_bp: u64 = @intCast(@min(@as(u64, @intCast(margin)) * 10_000 / threshold, 10_000));
    if (ratio_bp < 200) return "tight"; // <2%
    if (ratio_bp < 1000) return "medium"; // <10%
    return "strong";
}

/// Phase 8.55: render leaders for the /schedule HTTP endpoint.
/// Serves from the background-scanned cache.
/// hours: scan window cap (default 12)
/// limit: max leader entries (default 32)
/// Writes up to buf.len bytes. Returns actual length.
pub fn renderScheduleApi(buf: []u8, hours: u32, limit: u32) usize {
    g_schedule.mu.lock();
    defer g_schedule.mu.unlock();

    const now = unixNow();
    const now_slot: u64 = if (now > 1666656000) @intCast(now - 1666656000) else 0;
    const window_end_slot: u64 = now_slot + @as(u64, hours) * 3600;
    const eff_limit: u32 = @min(limit, 100);

    var w = compat.fixedBufferStream(buf);
    const out = w.writer();

    out.print(
        \\{{"epoch":{d},"current_slot":{d},"range":[{d},{d}],"sigma_x1e9":{d},"scan_unix":{d},
    , .{
        g_schedule.last_scan_epoch, now_slot, now_slot, window_end_slot,
        g_schedule.last_scan_sigma_x1e9, g_schedule.last_scan_unix,
    }) catch return w.pos;

    if (g_schedule.last_scan_unix == 0) {
        out.writeAll("\"count\":0,\"scan_pending\":true,\"leaders\":[]}") catch return w.pos;
        return w.pos;
    }

    // First pass: count matching leaders
    var rendered: u32 = 0;
    var i: u32 = 0;
    out.writeAll("\"leaders\":[") catch return w.pos;
    while (i < g_schedule.count and rendered < eff_limit) : (i += 1) {
        const L = g_schedule.leaders[i];
        if (L.slot <= now_slot) continue; // passed
        if (L.slot > window_end_slot) break; // out of window (list is slot-sorted)
        if (rendered > 0) out.writeAll(",") catch return w.pos;
        const conf = confidenceLabel(L.margin, L.thresh_x1e12);
        const eta: i64 = L.time_unix - now;
        out.print(
            \\{{"slot":{d},"eta_sec":{d},"margin":{d},"u_x1e12":{d},"threshold_x1e12":{d},"confidence":"{s}"}}
        , .{ L.slot, eta, L.margin, L.u_x1e12, L.thresh_x1e12, conf }) catch return w.pos;
        rendered += 1;
    }
    out.print("],\"count\":{d}}}", .{rendered}) catch return w.pos;
    return w.pos;
}

test "slotToUnix is monotonic" {
    try std.testing.expect(slotToUnix(0) < slotToUnix(1));
    try std.testing.expectEqual(@as(i64, 1666656000), slotToUnix(0));
}

test "renderJson empty state yields valid JSON" {
    g_schedule = .{};
    var buf: [512]u8 = undefined;
    const n = renderJson(&buf);
    try std.testing.expect(n > 0);
    try std.testing.expectEqual(@as(u8, '{'), buf[0]);
    try std.testing.expectEqual(@as(u8, '}'), buf[n - 1]);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"leaders\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"count\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"confidence\":\"none\"") != null);
}

test "renderJson tiny buffer still returns JSON-shaped fallback" {
    g_schedule = .{};
    var tiny: [4]u8 = undefined;
    const n = renderJson(&tiny);
    try std.testing.expect(n > 0);
    try std.testing.expectEqual(@as(u8, '{'), tiny[0]);
}
