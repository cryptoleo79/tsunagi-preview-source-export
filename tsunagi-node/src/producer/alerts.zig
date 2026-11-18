// Phase 9.5 — Slot Alert System
//
// Proactive notification of upcoming leader slots. Driven by leader_schedule
// — when a leader is found in the scan and eta_sec drops past configured
// thresholds (300s warn, 120s critical), we:
//
//   1. emit SLOT_ALERT / SLOT_CRITICAL to stdout (once per slot per tier)
//   2. POST a JSON body to TSUNAGI_ALERT_WEBHOOK if set (once per slot,
//      at the moment we first cross either threshold)
//   3. expose the next slot + eta + confidence at /status/full.alerts
//
// Webhook delivery is a detached thread with a 5s timeout. Failure never
// affects forge; a FAIL line is logged.

const std = @import("std");
const compat = @import("compat");

pub const State = struct {
    mu: compat.Mutex = .{},
    webhook: [256]u8 = [_]u8{0} ** 256,
    webhook_len: u16 = 0,

    // Next-slot snapshot (updated every fire).
    next_slot: u64 = 0,
    next_eta_sec: i64 = 0,
    next_confidence: [16]u8 = [_]u8{0} ** 16,
    next_confidence_len: u8 = 0,

    // Dedup: tracks the last slot for which we've emitted each tier.
    alert_emitted_slot: u64 = 0,
    critical_emitted_slot: u64 = 0,
    webhook_emitted_slot: u64 = 0,

    // Counters.
    alerts_total: u64 = 0,
    critical_total: u64 = 0,
    webhook_ok_total: u64 = 0,
    webhook_fail_total: u64 = 0,
};

pub var g_state: State = .{};

pub fn initFromEnv() void {
    var url_slice: []const u8 = "";
    if (compat.getenv("TSUNAGI_ALERT_WEBHOOK")) |v| {
        url_slice = std.mem.trim(u8, v, " \t\r\n");
    }
    g_state.mu.lock();
    defer g_state.mu.unlock();
    const n = @min(url_slice.len, g_state.webhook.len);
    @memcpy(g_state.webhook[0..n], url_slice[0..n]);
    g_state.webhook_len = @intCast(n);
    if (n > 0) {
        std.debug.print("ALERTS_CONFIG: webhook set ({d} bytes)\n", .{n});
    } else {
        std.debug.print("ALERTS_CONFIG: webhook disabled\n", .{});
    }
}

/// Called from leader_schedule.checkImminent for the next upcoming leader.
/// Fires SLOT_ALERT at T-300 and SLOT_CRITICAL at T-120. Idempotent per
/// (slot, tier).
pub fn onUpcomingLeader(slot: u64, eta_sec: i64, confidence: []const u8) void {
    g_state.mu.lock();

    // Always update snapshot.
    g_state.next_slot = slot;
    g_state.next_eta_sec = eta_sec;
    const cn = @min(confidence.len, g_state.next_confidence.len);
    @memcpy(g_state.next_confidence[0..cn], confidence[0..cn]);
    g_state.next_confidence_len = @intCast(cn);

    const fire_alert = eta_sec <= 300 and eta_sec > 0 and slot != g_state.alert_emitted_slot;
    const fire_critical = eta_sec <= 120 and eta_sec > 0 and slot != g_state.critical_emitted_slot;
    const fire_webhook = (fire_alert or fire_critical) and slot != g_state.webhook_emitted_slot and g_state.webhook_len > 0;

    if (fire_alert) {
        g_state.alert_emitted_slot = slot;
        g_state.alerts_total += 1;
    }
    if (fire_critical) {
        g_state.critical_emitted_slot = slot;
        g_state.critical_total += 1;
    }
    if (fire_webhook) {
        g_state.webhook_emitted_slot = slot;
    }

    // Snapshot webhook url while we still hold the lock.
    var url_buf: [256]u8 = undefined;
    var url_len: u16 = 0;
    if (fire_webhook) {
        @memcpy(url_buf[0..g_state.webhook_len], g_state.webhook[0..g_state.webhook_len]);
        url_len = g_state.webhook_len;
    }

    g_state.mu.unlock();

    if (fire_alert) {
        std.debug.print("SLOT_ALERT: slot={d} eta={d} confidence={s}\n", .{ slot, eta_sec, confidence[0..cn] });
    }
    if (fire_critical) {
        std.debug.print("SLOT_CRITICAL: slot={d} eta={d}\n", .{ slot, eta_sec });
    }
    if (fire_webhook) {
        deliverWebhook(url_buf[0..url_len], slot, eta_sec, confidence[0..cn]);
    }
}

pub fn renderJson(buf: []u8) usize {
    g_state.mu.lock();
    defer g_state.mu.unlock();

    // Derive alert "level" from the snapshot: critical if eta<=120, alert if
    // eta<=300, otherwise none. Active if level != none and slot is in future.
    const level: []const u8 = if (g_state.next_slot == 0 or g_state.next_eta_sec <= 0)
        "none"
    else if (g_state.next_eta_sec <= 120)
        "critical"
    else if (g_state.next_eta_sec <= 300)
        "alert"
    else
        "none";
    const active: bool = !std.mem.eql(u8, level, "none");

    var w = compat.fixedBufferStream(buf);
    w.writer().print(
        \\{{"active":{s},"level":"{s}","next_slot":{d},"eta_sec":{d},"confidence":"{s}","webhook_enabled":{s},"alerts_total":{d},"critical_total":{d},"webhook_ok_total":{d},"webhook_fail_total":{d}}}
    , .{
        if (active) "true" else "false",
        level,
        g_state.next_slot,
        g_state.next_eta_sec,
        g_state.next_confidence[0..g_state.next_confidence_len],
        if (g_state.webhook_len > 0) "true" else "false",
        g_state.alerts_total,
        g_state.critical_total,
        g_state.webhook_ok_total,
        g_state.webhook_fail_total,
    }) catch {};
    return w.pos;
}

// ── Webhook delivery ──
// Fire-and-forget curl invocation via a detached thread. Uses the system
// curl binary so we don't have to pull a TLS stack into the node. Failure
// only updates counters; no retries.

const WebhookCtx = struct {
    url: [256]u8,
    url_len: u16,
    slot: u64,
    eta_sec: i64,
    confidence: [16]u8,
    confidence_len: u8,
};

fn deliverWebhook(url: []const u8, slot: u64, eta_sec: i64, confidence: []const u8) void {
    const alloc = std.heap.page_allocator;
    const ctx = alloc.create(WebhookCtx) catch return;
    ctx.* = .{
        .url = undefined,
        .url_len = @intCast(url.len),
        .slot = slot,
        .eta_sec = eta_sec,
        .confidence = undefined,
        .confidence_len = @intCast(confidence.len),
    };
    @memcpy(ctx.url[0..url.len], url);
    @memcpy(ctx.confidence[0..confidence.len], confidence);

    const thread = std.Thread.spawn(.{}, webhookThread, .{ctx}) catch {
        alloc.destroy(ctx);
        std.debug.print("WEBHOOK_SPAWN_FAIL: slot={d}\n", .{slot});
        return;
    };
    thread.detach();
}

fn webhookThread(ctx: *WebhookCtx) void {
    const alloc = std.heap.page_allocator;
    defer alloc.destroy(ctx);

    var body_buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{{\"slot\":{d},\"eta_sec\":{d},\"confidence\":\"{s}\"}}", .{
        ctx.slot, ctx.eta_sec, ctx.confidence[0..ctx.confidence_len],
    }) catch {
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
        std.debug.print("WEBHOOK_FAIL: slot={d} err={s}\n", .{ ctx.slot, @errorName(err) });
        recordFail();
        return;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    const ok = result.term == .exited and result.term.exited == 0;
    if (ok) {
        recordOk();
        std.debug.print("WEBHOOK_OK: slot={d} eta={d}\n", .{ ctx.slot, ctx.eta_sec });
    } else {
        recordFail();
        std.debug.print("WEBHOOK_FAIL: slot={d} exit={d} stderr_len={d}\n", .{
            ctx.slot,
            if (result.term == .exited) @as(u32, result.term.exited) else 255,
            result.stderr.len,
        });
    }
}

fn recordOk() void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.webhook_ok_total += 1;
}

fn recordFail() void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.webhook_fail_total += 1;
}

test "onUpcomingLeader fires SLOT_ALERT once per slot" {
    g_state = .{};
    onUpcomingLeader(1000, 250, "medium");
    try std.testing.expectEqual(@as(u64, 1), g_state.alerts_total);
    // Same slot — no new fire.
    onUpcomingLeader(1000, 200, "medium");
    try std.testing.expectEqual(@as(u64, 1), g_state.alerts_total);
    // Cross critical threshold — fires critical once.
    onUpcomingLeader(1000, 100, "medium");
    try std.testing.expectEqual(@as(u64, 1), g_state.critical_total);
    onUpcomingLeader(1000, 50, "medium");
    try std.testing.expectEqual(@as(u64, 1), g_state.critical_total);
}

test "onUpcomingLeader outside thresholds does not fire" {
    g_state = .{};
    onUpcomingLeader(2000, 500, "strong");
    try std.testing.expectEqual(@as(u64, 0), g_state.alerts_total);
    try std.testing.expectEqual(@as(u64, 0), g_state.critical_total);
    // But snapshot is updated.
    try std.testing.expectEqual(@as(u64, 2000), g_state.next_slot);
}
