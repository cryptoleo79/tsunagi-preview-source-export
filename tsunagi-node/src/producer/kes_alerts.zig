// KES rotation early-warning module
//
// Cardano KES (Key Evolving Signature) keys rotate every 129600 slots
// (SLOTS_PER_KES_PERIOD). Once `cur_period >= start_period + max_periods`
// the operator MUST regenerate KES + opcert before the node can forge again
// or the relay layer will refuse to propagate any sealed block.
//
// Today TSUNAGI has no early warning — the first signal of trouble would be
// a forge failure. This module fires:
//
//   - KES_ALERT    when periods_remaining ≤ 10 and > 5 (operator action soon)
//   - KES_CRITICAL when periods_remaining ≤ 5  and > 0 (operator action now)
//
// Each alert tier dedupes against the period at which it was last dispatched
// so a given KES period only fires once even though the producer tick calls
// us hundreds of times. Webhook delivery mirrors `alerts.zig`: detached
// thread, system curl, 5s timeout, failure-counted but never crashing.
//
// Skipped entirely when signing is disabled — non-signing nodes have no
// opcert and don't care about KES expiry.

const std = @import("std");
const compat = @import("compat");

pub const Level = enum {
    none,
    alert,
    critical,
};

pub const State = struct {
    mu: compat.Mutex = .{},

    // Current period snapshot (for /status/full surfacing).
    current_period: u64 = 0,
    periods_remaining: u64 = 0,
    level: Level = .none,

    // Dedup: last period at which we dispatched each tier. Sentinel =
    // max(u64) means "never dispatched"; using 0 would collide with the
    // legitimate period 0 (genesis era).
    last_dispatched_period_alert: u64 = std.math.maxInt(u64),
    last_dispatched_period_critical: u64 = std.math.maxInt(u64),

    // Counters.
    alert_total: u64 = 0,
    critical_total: u64 = 0,
    webhook_total: u64 = 0,
    webhook_fail_total: u64 = 0,
};

pub var g_state: State = .{};

const ALERT_THRESHOLD: u64 = 10;
const CRITICAL_THRESHOLD: u64 = 5;

/// Called from the producer tick after the existing KES period validation
/// block. `current_period` is `current_slot / SLOTS_PER_KES_PERIOD`,
/// `periods_remaining` is `(start + max) - current_period` saturating at 0.
/// Idempotent per (period, tier).
pub fn onPeriodUpdate(current_period: u64, periods_remaining: u64, signing_enabled: bool) void {
    if (!signing_enabled) {
        // Non-signing nodes have no opcert. Keep the snapshot fresh so
        // /status/full reflects current_period but skip dispatch.
        g_state.mu.lock();
        g_state.current_period = current_period;
        g_state.periods_remaining = periods_remaining;
        g_state.level = .none;
        g_state.mu.unlock();
        return;
    }

    g_state.mu.lock();

    g_state.current_period = current_period;
    g_state.periods_remaining = periods_remaining;

    const new_level: Level = if (periods_remaining == 0)
        .none // already expired — nothing to warn about, the period gate handles this
    else if (periods_remaining <= CRITICAL_THRESHOLD)
        .critical
    else if (periods_remaining <= ALERT_THRESHOLD)
        .alert
    else
        .none;
    g_state.level = new_level;

    const fire_critical = new_level == .critical and g_state.last_dispatched_period_critical != current_period;
    const fire_alert = new_level == .alert and g_state.last_dispatched_period_alert != current_period;

    if (fire_critical) {
        g_state.last_dispatched_period_critical = current_period;
        g_state.critical_total += 1;
    }
    if (fire_alert) {
        g_state.last_dispatched_period_alert = current_period;
        g_state.alert_total += 1;
    }

    g_state.mu.unlock();

    if (fire_critical) {
        std.debug.print("KES_CRITICAL: current_period={d} periods_remaining={d}\n", .{ current_period, periods_remaining });
        deliverWebhook("KES_CRITICAL", current_period, periods_remaining);
    }
    if (fire_alert) {
        std.debug.print("KES_ALERT: current_period={d} periods_remaining={d}\n", .{ current_period, periods_remaining });
        deliverWebhook("KES_ALERT", current_period, periods_remaining);
    }
}

pub fn renderJson(buf: []u8) usize {
    g_state.mu.lock();
    defer g_state.mu.unlock();

    const level_str: []const u8 = switch (g_state.level) {
        .none => "none",
        .alert => "alert",
        .critical => "critical",
    };

    var w = compat.fixedBufferStream(buf);
    w.writer().print(
        \\{{"level":"{s}","current_period":{d},"periods_remaining":{d},"alert_total":{d},"critical_total":{d},"webhook_total":{d},"webhook_fail_total":{d}}}
    , .{
        level_str,
        g_state.current_period,
        g_state.periods_remaining,
        g_state.alert_total,
        g_state.critical_total,
        g_state.webhook_total,
        g_state.webhook_fail_total,
    }) catch {};
    return w.pos;
}

// ── Webhook delivery ──
// Mirrors alerts.zig: detached thread, system curl, 5s timeout. Read
// TSUNAGI_ALERT_WEBHOOK at fire time so operator can flip it without
// restart.

const WebhookCtx = struct {
    url: [256]u8,
    url_len: u16,
    reason: [16]u8,
    reason_len: u8,
    current_period: u64,
    periods_remaining: u64,
};

fn deliverWebhook(reason: []const u8, current_period: u64, periods_remaining: u64) void {
    var url_slice: []const u8 = "";
    if (compat.getenv("TSUNAGI_ALERT_WEBHOOK")) |v| {
        url_slice = std.mem.trim(u8, v, " \t\r\n");
    }
    if (url_slice.len == 0) return;
    if (url_slice.len > 256) {
        recordFail();
        return;
    }
    if (reason.len > 16) {
        recordFail();
        return;
    }

    const alloc = std.heap.page_allocator;
    const ctx = alloc.create(WebhookCtx) catch {
        recordFail();
        return;
    };
    ctx.* = .{
        .url = undefined,
        .url_len = @intCast(url_slice.len),
        .reason = undefined,
        .reason_len = @intCast(reason.len),
        .current_period = current_period,
        .periods_remaining = periods_remaining,
    };
    @memcpy(ctx.url[0..url_slice.len], url_slice);
    @memcpy(ctx.reason[0..reason.len], reason);

    const thread = std.Thread.spawn(.{}, webhookThread, .{ctx}) catch {
        alloc.destroy(ctx);
        std.debug.print("KES_WEBHOOK_SPAWN_FAIL: period={d}\n", .{current_period});
        recordFail();
        return;
    };
    thread.detach();
}

fn webhookThread(ctx: *WebhookCtx) void {
    const alloc = std.heap.page_allocator;
    defer alloc.destroy(ctx);

    var body_buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(
        &body_buf,
        "{{\"slot\":{d},\"reason\":\"{s}\",\"periods_remaining\":{d}}}",
        .{ ctx.current_period, ctx.reason[0..ctx.reason_len], ctx.periods_remaining },
    ) catch {
        recordFail();
        return;
    };

    var argv = [_][]const u8{
        "curl",
        "-sS",
        "-m",
        "5",
        "-H",
        "Content-Type: application/json",
        "-X",
        "POST",
        "-d",
        body,
        "--",
        ctx.url[0..ctx.url_len],
    };

    const result = compat.childRun(.{
        .allocator = alloc,
        .argv = &argv,
        .max_output_bytes = 4096,
    }) catch |err| {
        std.debug.print("KES_WEBHOOK_FAIL: period={d} err={s}\n", .{ ctx.current_period, @errorName(err) });
        recordFail();
        return;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    const ok = result.term == .exited and result.term.exited == 0;
    if (ok) {
        recordOk();
        std.debug.print("KES_WEBHOOK_OK: period={d} reason={s}\n", .{ ctx.current_period, ctx.reason[0..ctx.reason_len] });
    } else {
        recordFail();
        std.debug.print("KES_WEBHOOK_FAIL: period={d} exit={d}\n", .{
            ctx.current_period,
            if (result.term == .exited) @as(u32, result.term.exited) else 255,
        });
    }
}

fn recordOk() void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.webhook_total += 1;
}

fn recordFail() void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.webhook_fail_total += 1;
}

// ── Tests ──
// Tests reset g_state before each scenario so they can run in any order.

test "fires KES_ALERT when periods_remaining=10" {
    g_state = .{};
    onPeriodUpdate(50, 10, true);
    try std.testing.expectEqual(@as(u64, 1), g_state.alert_total);
    try std.testing.expectEqual(@as(u64, 0), g_state.critical_total);
    try std.testing.expectEqual(Level.alert, g_state.level);
}

test "fires KES_CRITICAL when periods_remaining=5" {
    g_state = .{};
    onPeriodUpdate(57, 5, true);
    try std.testing.expectEqual(@as(u64, 0), g_state.alert_total);
    try std.testing.expectEqual(@as(u64, 1), g_state.critical_total);
    try std.testing.expectEqual(Level.critical, g_state.level);
}

test "dedup within same period does not refire" {
    g_state = .{};
    onPeriodUpdate(50, 10, true);
    onPeriodUpdate(50, 10, true);
    onPeriodUpdate(50, 9, true);
    onPeriodUpdate(50, 8, true);
    try std.testing.expectEqual(@as(u64, 1), g_state.alert_total);
    // Crossing into critical within the same period must still fire once.
    onPeriodUpdate(50, 5, true);
    onPeriodUpdate(50, 4, true);
    try std.testing.expectEqual(@as(u64, 1), g_state.critical_total);
    // Advancing the period re-arms both tiers.
    onPeriodUpdate(51, 5, true);
    try std.testing.expectEqual(@as(u64, 2), g_state.critical_total);
}

test "no fire when signing disabled" {
    g_state = .{};
    onPeriodUpdate(50, 3, false);
    onPeriodUpdate(50, 8, false);
    try std.testing.expectEqual(@as(u64, 0), g_state.alert_total);
    try std.testing.expectEqual(@as(u64, 0), g_state.critical_total);
    try std.testing.expectEqual(Level.none, g_state.level);
    // Snapshot still updated so /status/full reflects current state.
    try std.testing.expectEqual(@as(u64, 50), g_state.current_period);
    try std.testing.expectEqual(@as(u64, 8), g_state.periods_remaining);
}

test "no fire when comfortably above threshold" {
    g_state = .{};
    onPeriodUpdate(20, 42, true);
    try std.testing.expectEqual(@as(u64, 0), g_state.alert_total);
    try std.testing.expectEqual(@as(u64, 0), g_state.critical_total);
    try std.testing.expectEqual(Level.none, g_state.level);
}

test "no fire when already expired (periods_remaining=0)" {
    g_state = .{};
    onPeriodUpdate(80, 0, true);
    try std.testing.expectEqual(@as(u64, 0), g_state.alert_total);
    try std.testing.expectEqual(@as(u64, 0), g_state.critical_total);
    try std.testing.expectEqual(Level.none, g_state.level);
}

test "renderJson shape" {
    g_state = .{};
    onPeriodUpdate(50, 5, true);
    var buf: [256]u8 = undefined;
    const len = renderJson(&buf);
    const out = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, out, "\"level\":\"critical\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"current_period\":50") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"periods_remaining\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"critical_total\":1") != null);
}
