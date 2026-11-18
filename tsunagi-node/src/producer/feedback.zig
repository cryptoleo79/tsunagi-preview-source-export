// Phase 9.8 — Acceptance Feedback Loop
//
// Records per-forge outcome (accepted / missed) alongside the exec-quality
// snapshot and the adaptive delay that was applied. Provides the raw signal
// downstream tuners will consume to adjust delay + peer weighting.
//
// State tracks only the LAST forge. Counters accumulate.

const std = @import("std");
const compat = @import("compat");
const autotune = @import("autotune.zig");
const exec_quality = @import("exec_quality.zig");
const decision_mod = @import("decision.zig");

pub const State = struct {
    mu: compat.Mutex = .{},

    // Snapshot of the most recent forge.
    last_slot: u64 = 0,
    last_block: u64 = 0,
    last_parent_gap: i32 = 0,
    last_delay_ms: u32 = 0,

    // Decision snapshot captured at forge time — used for CORRELATION_RESULT log.
    last_llr_x1000: i32 = 0,
    last_ev_x1000: i32 = 0,
    last_kelly_x1000: i32 = 0,
    last_posterior_x1000: u32 = 0,

    // Accept/miss recorded as an i8: 0 = pending, 1 = accepted, -1 = missed.
    last_outcome: i8 = 0,
    last_update_unix: i64 = 0,

    // Counters.
    forged_total: u64 = 0,
    accepted_total: u64 = 0,
    missed_total: u64 = 0,
};

pub var g_state: State = .{};

/// Called at EVENT_BLOCK_BUILD — record the snapshot that produced this block.
pub fn onForge(slot: u64, block_no: u64, parent_gap: i32, delay_ms: u32) void {
    // Capture decision snapshot for CORRELATION logs.
    const dec = decision_mod.currentSnapshot();
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.last_slot = slot;
    g_state.last_block = block_no;
    g_state.last_parent_gap = parent_gap;
    g_state.last_delay_ms = delay_ms;
    g_state.last_llr_x1000 = dec.llr_x1000;
    g_state.last_ev_x1000 = dec.ev_x1000;
    g_state.last_kelly_x1000 = dec.kelly_x1000;
    g_state.last_posterior_x1000 = dec.posterior_x1000;
    g_state.last_outcome = 0;
    g_state.last_update_unix = compat.timestamp();
    g_state.forged_total += 1;
    std.debug.print("FEEDBACK: slot={d} accepted=pending gap={d} delay={d}\n", .{ slot, parent_gap, delay_ms });
    std.debug.print("CORRELATION: slot={d} llr={d} ev={d} kelly={d} posterior={d}\n", .{
        slot, dec.llr_x1000, dec.ev_x1000, dec.kelly_x1000, dec.posterior_x1000,
    });
}

/// Called at EVENT_BLOCK_ACCEPTED — mark the matching forge as accepted.
pub fn onAccept(slot: u64) void {
    var should_autotune = false;
    var at_gap: i32 = 0;
    var at_delay: u32 = 0;
    g_state.mu.lock();
    if (g_state.last_slot == slot and g_state.last_outcome != 1) {
        g_state.last_outcome = 1;
        g_state.last_update_unix = compat.timestamp();
        g_state.accepted_total += 1;
        at_gap = g_state.last_parent_gap;
        at_delay = g_state.last_delay_ms;
        should_autotune = true;
    }
    g_state.mu.unlock();
    if (should_autotune) {
        std.debug.print("FEEDBACK: slot={d} accepted=1 gap={d} delay={d}\n", .{ slot, at_gap, at_delay });
        std.debug.print("CORRELATION_RESULT: slot={d} llr={d} ev={d} kelly={d} posterior={d} accepted=1\n", .{
            slot, g_state.last_llr_x1000, g_state.last_ev_x1000, g_state.last_kelly_x1000, g_state.last_posterior_x1000,
        });
        const eq = exec_quality.currentScore();
        autotune.recordSample(slot, true, at_gap, at_delay, eq.latency_ms);
    }
}

/// Called from prearm when a leader slot passes without a matching execute.
/// slot is the target_slot that was armed.
pub fn onMiss(slot: u64) void {
    var should_autotune = false;
    var at_gap: i32 = 0;
    var at_delay: u32 = 0;
    g_state.mu.lock();
    if (!(g_state.last_outcome == -1 and g_state.last_slot == slot)) {
        g_state.last_slot = slot;
        g_state.last_outcome = -1;
        g_state.last_update_unix = compat.timestamp();
        g_state.missed_total += 1;
        at_gap = g_state.last_parent_gap;
        at_delay = g_state.last_delay_ms;
        should_autotune = true;
    }
    g_state.mu.unlock();
    if (should_autotune) {
        std.debug.print("FEEDBACK: slot={d} accepted=0 gap={d} delay={d}\n", .{ slot, at_gap, at_delay });
        std.debug.print("CORRELATION_RESULT: slot={d} llr={d} ev={d} kelly={d} posterior={d} accepted=0\n", .{
            slot, g_state.last_llr_x1000, g_state.last_ev_x1000, g_state.last_kelly_x1000, g_state.last_posterior_x1000,
        });
        const eq = exec_quality.currentScore();
        autotune.recordSample(slot, false, at_gap, at_delay, eq.latency_ms);
    }
}

pub fn renderJson(buf: []u8) usize {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    var w = compat.fixedBufferStream(buf);
    const outcome_str: []const u8 = switch (g_state.last_outcome) {
        1 => "accepted",
        -1 => "missed",
        else => "pending",
    };
    const accepted_bool: []const u8 = if (g_state.last_outcome == 1) "true" else "false";
    w.writer().print(
        "{{\"last_slot\":{d},\"last_block\":{d},\"accepted\":{s},\"outcome\":\"{s}\",\"gap\":{d},\"delay\":{d},\"last_update_unix\":{d},\"forged_total\":{d},\"accepted_total\":{d},\"missed_total\":{d}}}",
        .{
            g_state.last_slot,
            g_state.last_block,
            accepted_bool,
            outcome_str,
            g_state.last_parent_gap,
            g_state.last_delay_ms,
            g_state.last_update_unix,
            g_state.forged_total,
            g_state.accepted_total,
            g_state.missed_total,
        },
    ) catch {};
    return w.pos;
}

test "onForge then onAccept marks accepted" {
    g_state = .{};
    onForge(100, 10, 2, 120);
    try std.testing.expectEqual(@as(u64, 1), g_state.forged_total);
    try std.testing.expectEqual(@as(i8, 0), g_state.last_outcome);
    onAccept(100);
    try std.testing.expectEqual(@as(i8, 1), g_state.last_outcome);
    try std.testing.expectEqual(@as(u64, 1), g_state.accepted_total);
}

test "onAccept for stale slot is ignored" {
    g_state = .{};
    onForge(100, 10, 2, 120);
    onAccept(99);
    try std.testing.expectEqual(@as(i8, 0), g_state.last_outcome);
    try std.testing.expectEqual(@as(u64, 0), g_state.accepted_total);
}

test "onMiss marks accepted=false" {
    g_state = .{};
    onForge(200, 20, 3, 150);
    onMiss(200);
    try std.testing.expectEqual(@as(i8, -1), g_state.last_outcome);
    try std.testing.expectEqual(@as(u64, 1), g_state.missed_total);
}
