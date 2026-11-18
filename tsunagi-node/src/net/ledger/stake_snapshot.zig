// Cardano mark/set/go stake snapshots.
//
// Praos does not use live stake for leader election. At specific slots
// within each epoch, a SNAPSHOT of the live stake distribution is frozen,
// then promoted through three stages:
//
//   Epoch N slot 100k  → take MARK (freeze current live distribution)
//   Epoch N slot 150k  → promote MARK → SET
//   Epoch N slot 180k  → promote SET  → GO (becomes active for epoch N+1)
//
// Leader-check for slots in epoch N+1 reads the GO snapshot.
//
// Safety rules:
//   - Module is OBSERVE-ONLY by default. `TSUNAGI_SNAPSHOT_ENABLE=1`
//     gates producer's read of `go()` as the authoritative sigma.
//   - When the flag is off, the existing `ctx.ledger_sigma_x1e9` path is
//     untouched and producer.zig behaves identically to pre-Task-8.
//   - Fallback chain on read: `go().valid` → `ledger_sigma_x1e9` →
//     `stake_fraction_x1e9` (env).

const std = @import("std");
const compat = @import("compat");
const stake_distribution = @import("stake_distribution.zig");

/// Default mark/set/go boundaries on preview + mainnet. Configurable via
/// TSUNAGI_SNAPSHOT_MARK_SLOT / _SET_SLOT / _GO_SLOT env (applied at init).
pub const DEFAULT_MARK_SLOT_IN_EPOCH: u64 = 100_000;
pub const DEFAULT_SET_SLOT_IN_EPOCH: u64 = 150_000;
pub const DEFAULT_GO_SLOT_IN_EPOCH: u64 = 180_000;

pub const Snapshot = struct {
    epoch: u64 = 0,
    our_pool_lovelace: u64 = 0,
    total_staked_lovelace: u64 = 0,
    sigma_x1e9: u64 = 0,
    taken_at_unix: i64 = 0,
    taken_at_slot: u64 = 0,
    valid: bool = false,
};

pub const SnapshotRing = struct {
    mu: compat.Mutex = .{},
    mark: Snapshot = .{}, // frozen in epoch N at slot 100k
    set: Snapshot = .{}, // promoted from prior mark at slot 150k
    go: Snapshot = .{}, // promoted from prior set at slot 180k (active in N+1)
    current_epoch: u64 = 0,

    // Configurable slot boundaries (read at init from env).
    mark_slot: u64 = DEFAULT_MARK_SLOT_IN_EPOCH,
    set_slot: u64 = DEFAULT_SET_SLOT_IN_EPOCH,
    go_slot: u64 = DEFAULT_GO_SLOT_IN_EPOCH,

    // Counters for /status/full.
    takes_total: u64 = 0,
    promotes_set_total: u64 = 0,
    promotes_go_total: u64 = 0,
    rollback_invalidations_total: u64 = 0,
};

pub var g_snapshots: SnapshotRing = .{};
pub var g_enabled: bool = false;

pub fn initFromEnv() void {
    var enabled = false;
    if (compat.getenv("TSUNAGI_SNAPSHOT_ENABLE")) |v| {
        enabled = std.mem.eql(u8, std.mem.trim(u8, v, " \t"), "1");
    }
    g_snapshots.mu.lock();
    defer g_snapshots.mu.unlock();
    if (compat.getenv("TSUNAGI_SNAPSHOT_MARK_SLOT")) |v| {
        g_snapshots.mark_slot = std.fmt.parseUnsigned(u64, std.mem.trim(u8, v, " \t"), 10) catch DEFAULT_MARK_SLOT_IN_EPOCH;
    }
    if (compat.getenv("TSUNAGI_SNAPSHOT_SET_SLOT")) |v| {
        g_snapshots.set_slot = std.fmt.parseUnsigned(u64, std.mem.trim(u8, v, " \t"), 10) catch DEFAULT_SET_SLOT_IN_EPOCH;
    }
    if (compat.getenv("TSUNAGI_SNAPSHOT_GO_SLOT")) |v| {
        g_snapshots.go_slot = std.fmt.parseUnsigned(u64, std.mem.trim(u8, v, " \t"), 10) catch DEFAULT_GO_SLOT_IN_EPOCH;
    }
    g_enabled = enabled;
    std.debug.print("STAKE_SNAPSHOT_CONFIG: enabled={s} mark={d} set={d} go={d}\n", .{
        if (enabled) "true" else "false",
        g_snapshots.mark_slot,
        g_snapshots.set_slot,
        g_snapshots.go_slot,
    });
}

/// Take a snapshot of `dist` into `ring.mark`. Idempotent within an epoch.
fn takeMark(dist: *const stake_distribution.StakeDistribution, ring: *SnapshotRing, epoch: u64, slot_in_epoch: u64) void {
    ring.mark = .{
        .epoch = epoch,
        .our_pool_lovelace = dist.our_pool_lovelace,
        .total_staked_lovelace = dist.total_staked_lovelace,
        .sigma_x1e9 = dist.sigma_x1e9,
        .taken_at_unix = compat.timestamp(),
        .taken_at_slot = slot_in_epoch,
        .valid = true,
    };
    ring.takes_total += 1;
    std.debug.print("STAKE_SNAPSHOT_MARK: epoch={d} slot_in_epoch={d} sigma_x1e9={d} pool_lovelace={d}\n", .{
        epoch, slot_in_epoch, dist.sigma_x1e9, dist.our_pool_lovelace,
    });
}

fn promoteSet(ring: *SnapshotRing, epoch: u64, slot_in_epoch: u64) void {
    if (!ring.mark.valid or ring.mark.epoch != epoch) return;
    ring.set = ring.mark;
    ring.set.taken_at_slot = slot_in_epoch;
    ring.promotes_set_total += 1;
    std.debug.print("STAKE_SNAPSHOT_PROMOTE_SET: epoch={d} slot_in_epoch={d} sigma_x1e9={d}\n", .{
        epoch, slot_in_epoch, ring.set.sigma_x1e9,
    });
}

fn promoteGo(ring: *SnapshotRing, epoch: u64, slot_in_epoch: u64) void {
    if (!ring.set.valid or ring.set.epoch != epoch) return;
    ring.go = ring.set;
    ring.go.taken_at_slot = slot_in_epoch;
    ring.promotes_go_total += 1;
    std.debug.print("STAKE_SNAPSHOT_PROMOTE_GO: epoch={d} slot_in_epoch={d} sigma_x1e9={d}\n", .{
        epoch, slot_in_epoch, ring.go.sigma_x1e9,
    });
}

/// Called from follower on every block apply. epoch = current epoch,
/// slot_in_epoch = slot offset within that epoch.
pub fn onSlotProgress(
    dist: *const stake_distribution.StakeDistribution,
    ring: *SnapshotRing,
    epoch: u64,
    slot_in_epoch: u64,
) void {
    ring.mu.lock();
    defer ring.mu.unlock();

    if (epoch != ring.current_epoch) ring.current_epoch = epoch;

    if ((!ring.mark.valid or ring.mark.epoch < epoch) and slot_in_epoch >= ring.mark_slot) {
        takeMark(dist, ring, epoch, slot_in_epoch);
    }
    if (ring.set.epoch < epoch and ring.mark.valid and ring.mark.epoch == epoch and slot_in_epoch >= ring.set_slot) {
        promoteSet(ring, epoch, slot_in_epoch);
    }
    if (ring.go.epoch < epoch and ring.set.valid and ring.set.epoch == epoch and slot_in_epoch >= ring.go_slot) {
        promoteGo(ring, epoch, slot_in_epoch);
    }
}

/// Active snapshot for leader check. Caller copies out under the mutex.
pub fn go(ring: *SnapshotRing) Snapshot {
    ring.mu.lock();
    defer ring.mu.unlock();
    return ring.go;
}

/// Cold-start seed from Koios bootstrap: if no snapshot exists yet,
/// populate `go` directly so producer has usable sigma within ~1 min of boot.
pub fn seedGoFromFallback(ring: *SnapshotRing, seed: Snapshot) void {
    ring.mu.lock();
    defer ring.mu.unlock();
    if (ring.go.valid) return; // don't overwrite a real snapshot
    ring.go = seed;
    ring.go.valid = true;
    std.debug.print("STAKE_SNAPSHOT_SEED: epoch={d} sigma_x1e9={d} (fallback bootstrap)\n", .{
        seed.epoch, seed.sigma_x1e9,
    });
}

/// Invalidate `mark` on deep rollback below its taken_at_slot. `set` and
/// `go` are frozen by design and never rolled back.
pub fn onRollback(ring: *SnapshotRing, target_slot_in_epoch: u64, target_epoch: u64) void {
    ring.mu.lock();
    defer ring.mu.unlock();
    if (target_epoch < ring.current_epoch) {
        ring.mark.valid = false;
        ring.rollback_invalidations_total += 1;
        std.debug.print("STAKE_SNAPSHOT_ROLLBACK_INVALIDATE: reason=epoch_backwards target_epoch={d} current_epoch={d}\n", .{
            target_epoch, ring.current_epoch,
        });
        return;
    }
    if (ring.mark.valid and target_slot_in_epoch < ring.mark.taken_at_slot) {
        ring.mark.valid = false;
        ring.rollback_invalidations_total += 1;
        std.debug.print("STAKE_SNAPSHOT_ROLLBACK_INVALIDATE: reason=before_mark target_slot={d} mark_slot={d}\n", .{
            target_slot_in_epoch, ring.mark.taken_at_slot,
        });
    }
}

pub fn renderJson(buf: []u8) usize {
    g_snapshots.mu.lock();
    defer g_snapshots.mu.unlock();
    var w = compat.fixedBufferStream(buf);
    w.writer().print(
        "{{\"enabled\":{s},\"current_epoch\":{d},\"mark_slot\":{d},\"set_slot\":{d},\"go_slot\":{d},\"mark\":{{\"valid\":{s},\"epoch\":{d},\"sigma_x1e9\":{d}}},\"set\":{{\"valid\":{s},\"epoch\":{d},\"sigma_x1e9\":{d}}},\"go\":{{\"valid\":{s},\"epoch\":{d},\"sigma_x1e9\":{d}}},\"takes_total\":{d},\"promotes_set_total\":{d},\"promotes_go_total\":{d},\"rollback_invalidations_total\":{d}}}",
        .{
            if (g_enabled) "true" else "false",
            g_snapshots.current_epoch,
            g_snapshots.mark_slot, g_snapshots.set_slot, g_snapshots.go_slot,
            if (g_snapshots.mark.valid) "true" else "false", g_snapshots.mark.epoch, g_snapshots.mark.sigma_x1e9,
            if (g_snapshots.set.valid) "true" else "false", g_snapshots.set.epoch, g_snapshots.set.sigma_x1e9,
            if (g_snapshots.go.valid) "true" else "false", g_snapshots.go.epoch, g_snapshots.go.sigma_x1e9,
            g_snapshots.takes_total, g_snapshots.promotes_set_total, g_snapshots.promotes_go_total,
            g_snapshots.rollback_invalidations_total,
        },
    ) catch {};
    return w.pos;
}

test "onSlotProgress promotes mark → set → go at boundaries" {
    g_snapshots = .{};
    var dist: stake_distribution.StakeDistribution = .{};
    dist.our_pool_lovelace = 1_000_000;
    dist.total_staked_lovelace = 10_000_000_000;
    dist.sigma_x1e9 = 100_000;

    // Before mark slot — no snapshot.
    onSlotProgress(&dist, &g_snapshots, 1, 50_000);
    try std.testing.expect(!g_snapshots.mark.valid);

    // At mark slot — mark taken.
    onSlotProgress(&dist, &g_snapshots, 1, 100_000);
    try std.testing.expect(g_snapshots.mark.valid);
    try std.testing.expectEqual(@as(u64, 100_000), g_snapshots.mark.sigma_x1e9);

    // At set slot — mark promoted to set.
    onSlotProgress(&dist, &g_snapshots, 1, 150_000);
    try std.testing.expect(g_snapshots.set.valid);

    // At go slot — set promoted to go.
    onSlotProgress(&dist, &g_snapshots, 1, 180_000);
    try std.testing.expect(g_snapshots.go.valid);
    try std.testing.expectEqual(@as(u64, 100_000), g_snapshots.go.sigma_x1e9);
}

test "seedGoFromFallback does not overwrite valid go" {
    g_snapshots = .{};
    g_snapshots.go = .{ .epoch = 5, .sigma_x1e9 = 123, .valid = true };
    seedGoFromFallback(&g_snapshots, .{ .epoch = 10, .sigma_x1e9 = 999, .valid = true });
    try std.testing.expectEqual(@as(u64, 123), g_snapshots.go.sigma_x1e9);
}

test "onRollback invalidates mark but preserves set/go" {
    g_snapshots = .{};
    g_snapshots.current_epoch = 5;
    g_snapshots.mark = .{ .epoch = 5, .sigma_x1e9 = 100, .taken_at_slot = 100_000, .valid = true };
    g_snapshots.set = .{ .epoch = 5, .sigma_x1e9 = 100, .taken_at_slot = 150_000, .valid = true };
    g_snapshots.go = .{ .epoch = 5, .sigma_x1e9 = 100, .taken_at_slot = 180_000, .valid = true };

    // Rollback to slot before mark — invalidate mark only.
    onRollback(&g_snapshots, 50_000, 5);
    try std.testing.expect(!g_snapshots.mark.valid);
    try std.testing.expect(g_snapshots.set.valid);
    try std.testing.expect(g_snapshots.go.valid);
}
