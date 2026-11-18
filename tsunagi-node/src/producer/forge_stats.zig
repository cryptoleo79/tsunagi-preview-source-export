// Forge statistics tracker — per-epoch block-production counters.
//
// Reports per-epoch counters operators expect from a Cardano stake pool:
//   Leader     — slots we won the VRF leader check this epoch
//   Adopted    — blocks observed entering our own chain after forging
//   Confirmed  — adopted blocks with K=2160 rollforwards on top (PHASE 2 stub)
//   Ideal      — expected leaders ≈ sigma * slots_per_epoch * f
//   Luck %     — leader_total / ideal * 100
//   Lost       — leaders where forge did NOT succeed (refused or no attempt)
//
// Observational only. NEVER mutates the forge path. All hooks no-op on
// internal failure (lock contention is impossible — single mutex, short crit).

const std = @import("std");
const compat = @import("compat");

pub const LeaderSlotRecord = struct {
    slot: u64 = 0,
    was_leader: bool = false,
    forge_attempted: bool = false,
    forge_ok: bool = false,
    adopted: bool = false,
    adopted_slot_when: u64 = 0,
};

// Ring sized for ~12h of leader records on preview at f=0.05 — plenty.
// Fixed-size: no allocator.
pub const RING_LEN: usize = 4096;

pub const State = struct {
    mu: compat.Mutex = .{},

    // Epoch geometry — set on epoch boundary.
    epoch: u64 = 0,
    sigma_x1e9: u64 = 0,
    slots_per_epoch: u64 = 0,
    f_coef_x1e6: u64 = 50_000, // 0.05 active slot coefficient (Cardano default)

    // Per-epoch counters — reset on onEpochBoundary().
    leader_total: u64 = 0,
    forge_attempts_total: u64 = 0,
    forge_ok_total: u64 = 0,
    adopted_total: u64 = 0,
    lost_total: u64 = 0,

    // Phase-2 placeholder — not computed yet.
    confirmed_total: u64 = 0,

    // Ring buffer of recent leader/forge outcomes.
    ring: [RING_LEN]LeaderSlotRecord = [_]LeaderSlotRecord{.{}} ** RING_LEN,
    ring_idx: u32 = 0,
};

pub var g_state: State = .{};

// Find existing entry in ring with matching slot, or return null.
fn findSlotIdx(slot: u64) ?usize {
    var i: usize = 0;
    while (i < RING_LEN) : (i += 1) {
        if (g_state.ring[i].slot == slot and g_state.ring[i].was_leader) return i;
    }
    return null;
}

// Append a fresh ring entry; bumps ring_idx with wraparound.
fn appendRing(rec: LeaderSlotRecord) void {
    const idx: usize = @intCast(g_state.ring_idx % RING_LEN);
    g_state.ring[idx] = rec;
    g_state.ring_idx +%= 1;
}

/// Called when leader-check determines we won this slot.
pub fn onLeader(slot: u64) void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.leader_total += 1;
    appendRing(.{
        .slot = slot,
        .was_leader = true,
    });
}

/// Called after each forge attempt — both successful KES sign and refusal.
/// `ok=true` from sign_log.record site; `ok=false` from forge_refused_total sites.
pub fn onForgeAttempt(slot: u64, ok: bool) void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.forge_attempts_total += 1;
    if (ok) {
        g_state.forge_ok_total += 1;
    } else {
        g_state.lost_total += 1;
    }
    if (findSlotIdx(slot)) |i| {
        g_state.ring[i].forge_attempted = true;
        g_state.ring[i].forge_ok = ok;
    } else {
        // No matching leader entry; record forge attempt anyway for debug.
        appendRing(.{
            .slot = slot,
            .was_leader = false,
            .forge_attempted = true,
            .forge_ok = ok,
        });
    }
}

/// Called when our own block is observed entering the chain
/// (relay pull / EVENT_BLOCK_ACCEPTED).
pub fn onAdopted(slot: u64) void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    if (findSlotIdx(slot)) |i| {
        if (!g_state.ring[i].adopted) {
            g_state.ring[i].adopted = true;
            g_state.ring[i].adopted_slot_when = slot;
            g_state.adopted_total += 1;
        }
    }
}

/// PHASE 2 — confirmed (K=2160 rollforwards). Records placeholder; not counted.
pub fn onConfirmed(slot: u64, k_rollforwards: u32) void {
    _ = slot;
    _ = k_rollforwards;
    // intentional no-op — phase 2 work
}

/// Called once at the epoch boundary. Resets per-epoch counters and recomputes
/// the geometry used to derive `ideal`. Idempotent for same epoch — only the
/// first call per epoch resets counters; subsequent calls in the same epoch
/// refresh sigma/geometry only.
pub fn onEpochBoundary(new_epoch: u64, sigma_x1e9: u64, slots_per_epoch: u64, f_coef_x1e6: u64) void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    const epoch_changed = (g_state.epoch != new_epoch);
    g_state.epoch = new_epoch;
    g_state.sigma_x1e9 = sigma_x1e9;
    g_state.slots_per_epoch = slots_per_epoch;
    g_state.f_coef_x1e6 = f_coef_x1e6;
    if (epoch_changed) {
        g_state.leader_total = 0;
        g_state.forge_attempts_total = 0;
        g_state.forge_ok_total = 0;
        g_state.adopted_total = 0;
        g_state.lost_total = 0;
        // confirmed_total carries over (phase 2)
    }
}

/// Compute ideal leaders this epoch ≈ sigma * slots_per_epoch * f.
/// All inputs are fixed-point (sigma_x1e9, f_coef_x1e6); compute in u128 to
/// avoid overflow, then divide by 1e9 * 1e6.
fn computeIdeal(sigma_x1e9: u64, slots_per_epoch: u64, f_coef_x1e6: u64) u64 {
    if (sigma_x1e9 == 0 or slots_per_epoch == 0 or f_coef_x1e6 == 0) return 0;
    const num: u128 = @as(u128, sigma_x1e9) * @as(u128, slots_per_epoch) * @as(u128, f_coef_x1e6);
    const denom: u128 = 1_000_000_000 * 1_000_000;
    return @intCast(num / denom);
}

/// Render JSON status. Returns bytes written.
pub fn renderJson(buf: []u8) usize {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    const ideal = computeIdeal(g_state.sigma_x1e9, g_state.slots_per_epoch, g_state.f_coef_x1e6);
    // luck_pct as integer-scaled x100 (two-decimal). Avoid division by zero.
    const luck_x100: u64 = if (ideal == 0) 0 else (g_state.leader_total * 10000) / ideal;
    var w = compat.fixedBufferStream(buf);
    w.writer().print(
        "{{\"epoch\":{d},\"leader_total\":{d},\"forge_attempts_total\":{d},\"forge_ok_total\":{d},\"adopted_total\":{d},\"lost_total\":{d},\"confirmed_total\":{d},\"ideal\":{d},\"luck_pct_x100\":{d},\"sigma_x1e9\":{d},\"slots_per_epoch\":{d},\"f_coef_x1e6\":{d}}}",
        .{
            g_state.epoch,
            g_state.leader_total,
            g_state.forge_attempts_total,
            g_state.forge_ok_total,
            g_state.adopted_total,
            g_state.lost_total,
            g_state.confirmed_total,
            ideal,
            luck_x100,
            g_state.sigma_x1e9,
            g_state.slots_per_epoch,
            g_state.f_coef_x1e6,
        },
    ) catch {};
    return w.pos;
}

// ─── Tests ────────────────────────────────────────────────────────────────

test "onLeader increments leader_total and writes ring" {
    g_state = .{};
    onLeader(100);
    onLeader(200);
    onLeader(300);
    try std.testing.expectEqual(@as(u64, 3), g_state.leader_total);
    try std.testing.expectEqual(@as(u32, 3), g_state.ring_idx);
    try std.testing.expectEqual(@as(u64, 100), g_state.ring[0].slot);
    try std.testing.expect(g_state.ring[0].was_leader);
}

test "onForgeAttempt ok=false bumps lost_total" {
    g_state = .{};
    onLeader(500);
    onForgeAttempt(500, false);
    try std.testing.expectEqual(@as(u64, 1), g_state.forge_attempts_total);
    try std.testing.expectEqual(@as(u64, 0), g_state.forge_ok_total);
    try std.testing.expectEqual(@as(u64, 1), g_state.lost_total);
    // Ring entry updated in-place (not appended) since slot matches.
    try std.testing.expectEqual(@as(u32, 1), g_state.ring_idx);
    try std.testing.expect(g_state.ring[0].forge_attempted);
    try std.testing.expect(!g_state.ring[0].forge_ok);
}

test "onForgeAttempt ok=true bumps forge_ok_total, not lost" {
    g_state = .{};
    onLeader(700);
    onForgeAttempt(700, true);
    try std.testing.expectEqual(@as(u64, 1), g_state.forge_ok_total);
    try std.testing.expectEqual(@as(u64, 0), g_state.lost_total);
    try std.testing.expect(g_state.ring[0].forge_ok);
}

test "onAdopted finds matching ring entry and bumps adopted_total" {
    g_state = .{};
    onLeader(800);
    onForgeAttempt(800, true);
    onAdopted(800);
    try std.testing.expectEqual(@as(u64, 1), g_state.adopted_total);
    try std.testing.expect(g_state.ring[0].adopted);

    // Second onAdopted for the same slot is idempotent.
    onAdopted(800);
    try std.testing.expectEqual(@as(u64, 1), g_state.adopted_total);

    // onAdopted for unknown slot is a no-op.
    onAdopted(99999);
    try std.testing.expectEqual(@as(u64, 1), g_state.adopted_total);
}

test "onEpochBoundary resets per-epoch counters" {
    g_state = .{};
    onLeader(1000);
    onForgeAttempt(1000, false);
    try std.testing.expectEqual(@as(u64, 1), g_state.leader_total);
    try std.testing.expectEqual(@as(u64, 1), g_state.lost_total);

    onEpochBoundary(1275, 5_000_000, 432_000, 50_000);
    try std.testing.expectEqual(@as(u64, 1275), g_state.epoch);
    try std.testing.expectEqual(@as(u64, 5_000_000), g_state.sigma_x1e9);
    try std.testing.expectEqual(@as(u64, 0), g_state.leader_total);
    try std.testing.expectEqual(@as(u64, 0), g_state.lost_total);
    try std.testing.expectEqual(@as(u64, 0), g_state.adopted_total);
}

test "computeIdeal — sigma=0.1%, slots=86400, f=0.05" {
    // sigma = 0.001 → sigma_x1e9 = 1_000_000
    // slots = 86_400 (preview epoch)
    // f = 0.05 → f_coef_x1e6 = 50_000
    // ideal = 0.001 * 86_400 * 0.05 = 4.32 → integer 4
    const got = computeIdeal(1_000_000, 86_400, 50_000);
    try std.testing.expectEqual(@as(u64, 4), got);
}

test "computeIdeal handles zero inputs" {
    try std.testing.expectEqual(@as(u64, 0), computeIdeal(0, 86_400, 50_000));
    try std.testing.expectEqual(@as(u64, 0), computeIdeal(1_000_000, 0, 50_000));
    try std.testing.expectEqual(@as(u64, 0), computeIdeal(1_000_000, 86_400, 0));
}

test "ring overwrites at RING_LEN+1" {
    g_state = .{};
    var i: u64 = 0;
    while (i < RING_LEN) : (i += 1) {
        onLeader(i + 1);
    }
    try std.testing.expectEqual(@as(u32, RING_LEN), g_state.ring_idx);
    try std.testing.expectEqual(@as(u64, 1), g_state.ring[0].slot);

    // (RING_LEN+1)th entry overwrites slot 1 at index 0.
    onLeader(RING_LEN + 1);
    try std.testing.expectEqual(@as(u64, RING_LEN + 1), g_state.ring[0].slot);
    try std.testing.expectEqual(@as(u32, RING_LEN + 1), g_state.ring_idx);
}

test "renderJson emits well-formed shape" {
    g_state = .{};
    onEpochBoundary(1280, 2_000_000, 86_400, 50_000);
    onLeader(1);
    onLeader(2);
    onForgeAttempt(1, true);
    onForgeAttempt(2, false);
    var buf: [512]u8 = undefined;
    const len = renderJson(&buf);
    try std.testing.expect(len > 0);
    const s = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, s, "\"epoch\":1280") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"leader_total\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"forge_ok_total\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"lost_total\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"ideal\":") != null);
}
