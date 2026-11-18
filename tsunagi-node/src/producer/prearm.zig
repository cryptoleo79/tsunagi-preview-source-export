// Phase 8.95 — Pre-Arm System
//
// Staged preparation for imminent leader slots. Driven by
// EVENT_LEADER_IMMINENT from leader_schedule. Progresses through:
//
//   idle  →  warmup  (T-120 → T-60)
//         →  lock    (T-60  → T-5)   parent + peer snapshot frozen
//         →  final   (T-5   → slot)  last-moment parent override
//         →  execute (slot)          hands off to deterministic forge
//         →  idle    (post-slot)
//
// Observability-only. Every stage is logged. NEVER blocks the forge path,
// NEVER alters VRF eligibility, NEVER overrides deterministic parent
// selection — it only records what the node intends to build on.

const std = @import("std");
const compat = @import("compat");
const feedback = @import("feedback.zig");
const announce = @import("announce.zig");

pub const Stage = enum(u8) {
    idle = 0,
    warmup = 1,
    lock = 2,
    final = 3,
    execute = 4,

    pub fn str(self: Stage) []const u8 {
        return switch (self) {
            .idle => "idle",
            .warmup => "warmup",
            .lock => "lock",
            .final => "final",
            .execute => "execute",
        };
    }
};

pub const State = struct {
    mu: compat.Mutex = .{},
    target_slot: u64 = 0,
    armed: bool = false,
    stage: Stage = .idle,
    last_update_unix: i64 = 0,

    // Locked snapshot taken during .lock stage
    locked_parent_block: u64 = 0,
    locked_parent_slot: u64 = 0,
    locked_parent_source_kind: u8 = 0, // 0=unknown, 1=primary, 2=probe
    lock_unix: i64 = 0,

    // Final-align overrides
    final_override_count: u32 = 0,
    final_last_override_block: u64 = 0,

    // Counters
    armed_total: u64 = 0,
    executed_total: u64 = 0,
    missed_total: u64 = 0, // armed but no execute by target slot + 30

    // Phase 9.5: throttled PREARM_STATE heartbeat.
    last_state_log_unix: i64 = 0,
};

pub var g_state: State = .{};

/// Called from leader_schedule.checkImminent() when EVENT_LEADER_IMMINENT fires.
/// `slot` is the upcoming target leader slot. Idempotent per slot.
pub fn onImminent(slot: u64) void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    if (g_state.armed and g_state.target_slot == slot) return; // already armed
    const now = compat.timestamp();
    g_state.target_slot = slot;
    g_state.armed = true;
    g_state.stage = .warmup;
    g_state.last_update_unix = now;
    g_state.locked_parent_block = 0;
    g_state.locked_parent_slot = 0;
    g_state.locked_parent_source_kind = 0;
    g_state.lock_unix = 0;
    g_state.final_override_count = 0;
    g_state.final_last_override_block = 0;
    g_state.armed_total += 1;
    const eta: i64 = @as(i64, @intCast(slot)) + 1666656000 - now;
    std.debug.print("PREARM_ARMED: slot={d} eta={d}\n", .{ slot, eta });
}

/// Called every producer tick. Transitions stages based on seconds until target.
/// Uses current_slot (unix-derived) rather than chain tip to avoid coupling to
/// the follower's block delivery cadence.
pub fn onTick(
    current_slot: u64,
    rx_block_last: u64,
    rx_slot_last: u64,
    probe_is_source: bool,
) void {
    g_state.mu.lock();
    defer g_state.mu.unlock();

    if (!g_state.armed) return;

    // Miss detection: 30 slots past target without execute → reset + count miss.
    if (current_slot > g_state.target_slot + 30 and g_state.stage != .execute) {
        g_state.missed_total += 1;
        const missed_slot = g_state.target_slot;
        std.debug.print("PREARM_MISSED: slot={d} stage={s} (no execute hook fired)\n", .{
            missed_slot, g_state.stage.str(),
        });
        g_state.armed = false;
        g_state.stage = .idle;
        g_state.target_slot = 0;
        // Phase 9.8: feedback — leader slot passed without forge/accept.
        // Capture the slot, release mutex (the defer re-acquires isn't right;
        // instead drop the deferred unlock by returning after manual unlock).
        g_state.mu.unlock();
        feedback.onMiss(missed_slot);
        g_state.mu.lock();
        return;
    }

    // Eta in slots (1 slot = 1s on preview).
    const eta_slots: i64 = @as(i64, @intCast(g_state.target_slot)) - @as(i64, @intCast(current_slot));
    const prev_stage = g_state.stage;
    var new_stage = prev_stage;

    if (eta_slots > 120) {
        // Should never happen (armed at T-120s) — reset defensively.
        return;
    } else if (eta_slots > 60) {
        new_stage = .warmup;
    } else if (eta_slots > 5) {
        new_stage = .lock;
    } else if (eta_slots >= 0) {
        new_stage = .final;
    } else {
        // Slot passed but no execute → will fall into miss detection on subsequent ticks.
        return;
    }

    // Transition into lock: freeze parent snapshot.
    if (prev_stage != .lock and new_stage == .lock) {
        g_state.locked_parent_block = rx_block_last;
        g_state.locked_parent_slot = rx_slot_last;
        g_state.locked_parent_source_kind = if (probe_is_source) 2 else 1;
        g_state.lock_unix = compat.timestamp();
        std.debug.print("PREARM_STAGE: lock slot={d} parent_block={d} parent_slot={d} source={s}\n", .{
            g_state.target_slot, rx_block_last, rx_slot_last,
            if (probe_is_source) "probe" else "primary",
        });
    } else if (prev_stage != .warmup and new_stage == .warmup) {
        std.debug.print("PREARM_STAGE: warmup slot={d}\n", .{g_state.target_slot});
    } else if (prev_stage != .final and new_stage == .final) {
        std.debug.print("PREARM_STAGE: final slot={d}\n", .{g_state.target_slot});
        // Phase 9.6: signal announce readiness pipeline that a forge is imminent.
        announce.onPrearmFinal(g_state.target_slot);
    }

    // In final stage, track last-moment parent overrides (probe wins race).
    if (new_stage == .final and rx_block_last > g_state.locked_parent_block) {
        g_state.final_override_count += 1;
        g_state.final_last_override_block = rx_block_last;
        g_state.locked_parent_block = rx_block_last;
        g_state.locked_parent_slot = rx_slot_last;
        g_state.locked_parent_source_kind = if (probe_is_source) 2 else 1;
    }

    g_state.stage = new_stage;
    g_state.last_update_unix = compat.timestamp();
}

/// Called by the forge path just before BLOCK_BUILD when we actually fire.
/// `parent_block` is the block_no the forge selected.
pub fn onExecute(slot: u64, parent_block: u64) void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    if (!g_state.armed or g_state.target_slot != slot) return;
    g_state.stage = .execute;
    g_state.executed_total += 1;
    g_state.last_update_unix = compat.timestamp();
    const overrides = g_state.final_override_count;
    std.debug.print("PREARM_EXECUTE: slot={d} parent_block={d} lock_parent={d} overrides={d}\n", .{
        slot, parent_block, g_state.locked_parent_block, overrides,
    });
    // Reset to idle immediately — the forge owns the slot from here.
    g_state.armed = false;
    g_state.stage = .idle;
    g_state.target_slot = 0;
}

/// Phase 9.5 — emit PREARM_STATE at most once per minute (or immediately when
/// the stage changes). Gives operators continuous visibility even when idle.
pub fn maybeLogState() void {
    const throttle_s: i64 = 60;
    g_state.mu.lock();
    defer g_state.mu.unlock();
    const now = compat.timestamp();
    if (now - g_state.last_state_log_unix < throttle_s) return;
    g_state.last_state_log_unix = now;
    std.debug.print("PREARM_STATE: armed={s} stage={s} target_slot={d}\n", .{
        if (g_state.armed) "true" else "false",
        g_state.stage.str(),
        g_state.target_slot,
    });
}

/// Render JSON for /status/full.
pub fn renderJson(buf: []u8) usize {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    var w = compat.fixedBufferStream(buf);
    w.writer().print(
        \\{{"armed":{s},"stage":"{s}","target_slot":{d},"locked_parent_block":{d},"locked_parent_slot":{d},"lock_unix":{d},"final_override_count":{d},"final_last_override_block":{d},"armed_total":{d},"executed_total":{d},"missed_total":{d}}}
    , .{
        if (g_state.armed) "true" else "false",
        g_state.stage.str(),
        g_state.target_slot,
        g_state.locked_parent_block,
        g_state.locked_parent_slot,
        g_state.lock_unix,
        g_state.final_override_count,
        g_state.final_last_override_block,
        g_state.armed_total,
        g_state.executed_total,
        g_state.missed_total,
    }) catch {};
    return w.pos;
}

test "stages transition with eta" {
    // Reset
    g_state.armed = false;
    g_state.stage = .idle;

    onImminent(1000);
    try std.testing.expect(g_state.armed);
    try std.testing.expectEqual(Stage.warmup, g_state.stage);

    // T-100s → still warmup
    onTick(900, 0, 0, false);
    try std.testing.expectEqual(Stage.warmup, g_state.stage);

    // T-30s → lock
    onTick(970, 42, 970, true);
    try std.testing.expectEqual(Stage.lock, g_state.stage);
    try std.testing.expectEqual(@as(u64, 42), g_state.locked_parent_block);
    try std.testing.expectEqual(@as(u8, 2), g_state.locked_parent_source_kind);

    // T-2s → final
    onTick(998, 42, 970, true);
    try std.testing.expectEqual(Stage.final, g_state.stage);

    // Execute
    onExecute(1000, 42);
    try std.testing.expectEqual(Stage.idle, g_state.stage);
    try std.testing.expect(!g_state.armed);
    try std.testing.expectEqual(@as(u64, 1), g_state.executed_total);
}

test "miss detection" {
    g_state.armed = false;
    g_state.stage = .idle;
    g_state.missed_total = 0;

    onImminent(2000);
    // Jump to slot well past target without execute
    onTick(2050, 0, 0, false);
    try std.testing.expect(!g_state.armed);
    try std.testing.expectEqual(@as(u64, 1), g_state.missed_total);
}
