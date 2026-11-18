// Integration tests for the remediation modules:
//   - stake_source (σ chain-source loader)
//   - acceptance_tracker (forge state machine + Koios poller) — mocked here
//     because the real module is being developed in parallel.
//   - producer-side σ drift / nonce currency / orphan watchdog gates —
//     mocked at file level (gate logic is a pure function over a small
//     context, so we replicate the contract here without dragging in
//     producer.zig's full linkage surface).
//
// Self-contained: the only real-module import is stake_source. Everything
// else is a file-local mock that mirrors the contract under test so the
// test-suite is decoupled from the parallel work-stream's exact symbol
// names. When the real modules land they can either (a) be swapped in
// behind the same shape, or (b) the gate functions can be lifted out of
// here and reused.

const std = @import("std");
const compat = @import("compat");
const stake_source = @import("producer/stake_source.zig");

// ── TEST 1: stake_source unit tests ─────────────────────────────────
//
// Koios `/pool_info` σ is the live current value, and `active_epoch_no`
// is a registration-era marker (kept as pool_reg_epoch for telemetry).
// Epoch matching was removed from forgeStakeSnapshot; freshness lives
// in snapshotAge() (60s poll cadence).

test "stake_source: forgeStakeSnapshot returns NoSnapshot when uninitialized" {
    stake_source.g_snapshot_mu.lock();
    stake_source.g_active_snapshot = null;
    stake_source.g_snapshot_mu.unlock();

    if (compat.getenv("TSUNAGI_SIGMA_X1E9") == null) {
        try std.testing.expectError(error.NoSnapshot, stake_source.forgeStakeSnapshot(1285));
    }
}

test "stake_source: forgeStakeSnapshot returns the active snapshot when fresh" {
    stake_source.g_snapshot_mu.lock();
    stake_source.g_active_snapshot = .{
        .sigma_x1e9 = 744_000,
        .asc_x1e6 = 50_000,
        .pool_reg_epoch = 1273,
        .fetched_unix = compat.timestamp(),
        .source = .koios_pool_info,
    };
    stake_source.g_snapshot_mu.unlock();
    defer {
        stake_source.g_snapshot_mu.lock();
        stake_source.g_active_snapshot = null;
        stake_source.g_snapshot_mu.unlock();
    }

    // Snapshot returned regardless of caller's current_epoch.
    const s = try stake_source.forgeStakeSnapshot(1288);
    try std.testing.expectEqual(@as(u64, 744_000), s.sigma_x1e9);
    try std.testing.expectEqual(@as(u64, 1273), s.pool_reg_epoch);

    const age = stake_source.snapshotAge();
    try std.testing.expect(age >= 0 and age < 5); // just-set
}

test "stake_source: snapshot returned when pool_reg_epoch lags current_epoch" {
    // Regression: previously errored with SnapshotEpochMismatch when
    // active_epoch_no (pool registration era) was treated as snapshot epoch
    // and didn't match current_epoch. This deterministically refused every
    // legitimate leader fire under TSUNAGI_SIGMA_STRICT=1. Live σ is still
    // valid; pool_reg_epoch is a static registration marker.
    stake_source.g_snapshot_mu.lock();
    stake_source.g_active_snapshot = .{
        .sigma_x1e9 = 419_850,
        .asc_x1e6 = 50_000,
        .pool_reg_epoch = 1273,
        .fetched_unix = compat.timestamp(),
        .source = .koios_pool_info,
    };
    stake_source.g_snapshot_mu.unlock();
    defer {
        stake_source.g_snapshot_mu.lock();
        stake_source.g_active_snapshot = null;
        stake_source.g_snapshot_mu.unlock();
    }

    const s = try stake_source.forgeStakeSnapshot(1294);
    try std.testing.expectEqual(@as(u64, 419_850), s.sigma_x1e9);
}

// ── TEST 2: σ drift detection ───────────────────────────────────────
//
// Pure function under test: given a producer's local σ estimate and the
// chain-derived snapshot, flag drift > 5% as refuse=true.

const SigmaGate = struct {
    refuse: bool,
    drift_pct: f64,
    reason: ?[]const u8,
};

fn evalSigmaDriftGate(local_sigma_x1e9: u64, chain_sigma_x1e9: u64, threshold_pct: f64) SigmaGate {
    if (chain_sigma_x1e9 == 0) {
        return .{ .refuse = true, .drift_pct = 100.0, .reason = "chain_sigma_zero" };
    }
    const lf: f64 = @floatFromInt(local_sigma_x1e9);
    const cf: f64 = @floatFromInt(chain_sigma_x1e9);
    const diff = if (lf > cf) lf - cf else cf - lf;
    const pct = (diff / cf) * 100.0;
    if (pct > threshold_pct) {
        return .{ .refuse = true, .drift_pct = pct, .reason = "sigma_drift" };
    }
    return .{ .refuse = false, .drift_pct = pct, .reason = null };
}

test "sigma drift: 744e6 local vs 420e6 chain triggers refuse" {
    const g = evalSigmaDriftGate(744_000_000, 420_000_000, 5.0);
    try std.testing.expect(g.refuse);
    try std.testing.expect(g.drift_pct > 5.0);
    try std.testing.expect(g.drift_pct > 70.0); // ~77%
    try std.testing.expect(g.reason != null);
    try std.testing.expect(std.mem.eql(u8, g.reason.?, "sigma_drift"));
}

test "sigma drift: matching values pass" {
    const g = evalSigmaDriftGate(420_000_000, 420_000_000, 5.0);
    try std.testing.expect(!g.refuse);
    try std.testing.expectEqual(@as(f64, 0.0), g.drift_pct);
}

test "sigma drift: small jitter under threshold passes" {
    // 2% drift — under 5% threshold.
    const g = evalSigmaDriftGate(420_000_000, 411_764_706, 5.0);
    try std.testing.expect(!g.refuse);
    try std.testing.expect(g.drift_pct < 5.0);
}

// ── TEST 3: nonce currency gate ─────────────────────────────────────
//
// Pure function: refuse forge if nonce_state.nonce_epoch lags the
// follower's epoch_last (i.e. we'd VRF against a stale epoch nonce).

const NonceGate = struct {
    pass: bool,
    refuse: bool,
    reason: ?[]const u8,
};

const MockNonceState = struct { nonce_epoch: u64 };
const MockProducerCtx = struct {
    nonce_state: MockNonceState,
    epoch_last: u64,
};

fn evalNonceCurrencyGate(ctx: MockProducerCtx) NonceGate {
    if (ctx.nonce_state.nonce_epoch != ctx.epoch_last) {
        return .{ .pass = false, .refuse = true, .reason = "epoch_mismatch" };
    }
    return .{ .pass = true, .refuse = false, .reason = null };
}

test "nonce currency: stale nonce_epoch triggers epoch_mismatch refusal" {
    const ctx = MockProducerCtx{
        .nonce_state = .{ .nonce_epoch = 1288 },
        .epoch_last = 1292,
    };
    const g = evalNonceCurrencyGate(ctx);
    try std.testing.expect(g.refuse);
    try std.testing.expect(!g.pass);
    try std.testing.expect(g.reason != null);
    try std.testing.expect(std.mem.eql(u8, g.reason.?, "epoch_mismatch"));
}

test "nonce currency: matching epoch passes" {
    const ctx = MockProducerCtx{
        .nonce_state = .{ .nonce_epoch = 1292 },
        .epoch_last = 1292,
    };
    const g = evalNonceCurrencyGate(ctx);
    try std.testing.expect(g.pass);
    try std.testing.expect(!g.refuse);
    try std.testing.expect(g.reason == null);
}

// ── TEST 4: orphan watchdog state transitions ───────────────────────

const OrphanState = enum { ARMED, SUSPECT_DIV, CONFIRMED_WIN, CONFIRMED_LOSS };

const KoiosLookup = enum { UNKNOWN, FOUND, NOT_FOUND };

const OrphanWatchdog = struct {
    state: OrphanState = .ARMED,
    suspect_slot: ?u64 = null,
    suspect_at_unix: ?i64 = null,
    rollback_executed: bool = false,

    const SUSPECT_WAIT_SLOTS: u64 = 30;

    fn observeProbeDivergence(self: *OrphanWatchdog, slot: u64, now_unix: i64) void {
        if (self.state == .ARMED) {
            self.state = .SUSPECT_DIV;
            self.suspect_slot = slot;
            self.suspect_at_unix = now_unix;
        }
    }

    fn tick(self: *OrphanWatchdog, current_slot: u64, koios: KoiosLookup) void {
        if (self.state != .SUSPECT_DIV) return;
        const ss = self.suspect_slot orelse return;
        if (current_slot < ss + SUSPECT_WAIT_SLOTS) return;
        // Wait elapsed — query Koios verdict.
        switch (koios) {
            .UNKNOWN => {}, // stay SUSPECT_DIV
            .FOUND => {
                self.state = .CONFIRMED_WIN;
                self.rollback_executed = false;
            },
            .NOT_FOUND => {
                self.state = .CONFIRMED_LOSS;
                self.rollback_executed = true;
            },
        }
    }
};

test "orphan watchdog: ARMED → SUSPECT_DIV on probe divergence" {
    var wd = OrphanWatchdog{};
    try std.testing.expectEqual(OrphanState.ARMED, wd.state);

    wd.observeProbeDivergence(110_944_068, 1_700_000_000);
    try std.testing.expectEqual(OrphanState.SUSPECT_DIV, wd.state);
    try std.testing.expectEqual(@as(u64, 110_944_068), wd.suspect_slot.?);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), wd.suspect_at_unix.?);
}

test "orphan watchdog: stays SUSPECT_DIV during 30-slot wait" {
    var wd = OrphanWatchdog{};
    wd.observeProbeDivergence(100, 1_700_000_000);

    // Within wait window — UNKNOWN does not transition.
    wd.tick(120, .UNKNOWN);
    try std.testing.expectEqual(OrphanState.SUSPECT_DIV, wd.state);
    try std.testing.expect(!wd.rollback_executed);

    // Even past the window, UNKNOWN keeps us in SUSPECT_DIV.
    wd.tick(200, .UNKNOWN);
    try std.testing.expectEqual(OrphanState.SUSPECT_DIV, wd.state);
    try std.testing.expect(!wd.rollback_executed);
}

test "orphan watchdog: Koios FOUND → CONFIRMED_WIN, no rollback" {
    var wd = OrphanWatchdog{};
    wd.observeProbeDivergence(100, 1_700_000_000);
    // Past the 30-slot wait
    wd.tick(140, .FOUND);
    try std.testing.expectEqual(OrphanState.CONFIRMED_WIN, wd.state);
    try std.testing.expect(!wd.rollback_executed);
}

test "orphan watchdog: Koios NOT_FOUND → CONFIRMED_LOSS, rollback executed" {
    var wd = OrphanWatchdog{};
    wd.observeProbeDivergence(100, 1_700_000_000);
    wd.tick(140, .NOT_FOUND);
    try std.testing.expectEqual(OrphanState.CONFIRMED_LOSS, wd.state);
    try std.testing.expect(wd.rollback_executed);
}

// ── TEST 5: acceptance tracker state machine ────────────────────────
//
// Mock of the parallel-developed acceptance_tracker module. Forges flow
// FORGED → CANONICAL (Koios pool_blocks contains our hash) or FORGED →
// ORPHANED (different hash at our block_no with confs >= 2). Verdict
// events are emitted on every state change.

const ForgeState = enum { FORGED, CANONICAL, ORPHANED };

const VerdictEvent = struct {
    block_no: u64,
    block_hash: [32]u8,
    state: ForgeState,
};

const PoolBlock = struct {
    block_no: u64,
    block_hash: [32]u8,
    confirmations: u32,
};

const AcceptanceTracker = struct {
    forge_block_no: u64 = 0,
    forge_hash: [32]u8 = [_]u8{0} ** 32,
    state: ForgeState = .FORGED,
    events: std.ArrayList(VerdictEvent),

    const MIN_CONFIRMATIONS: u32 = 2;

    fn init(alloc: std.mem.Allocator) AcceptanceTracker {
        return .{
            .events = std.ArrayList(VerdictEvent).initCapacity(alloc, 0) catch unreachable,
        };
    }

    fn deinit(self: *AcceptanceTracker, alloc: std.mem.Allocator) void {
        self.events.deinit(alloc);
    }

    fn registerForge(self: *AcceptanceTracker, alloc: std.mem.Allocator, block_no: u64, hash: [32]u8) !void {
        self.forge_block_no = block_no;
        self.forge_hash = hash;
        self.state = .FORGED;
        try self.events.append(alloc, .{ .block_no = block_no, .block_hash = hash, .state = .FORGED });
    }

    fn poll(self: *AcceptanceTracker, alloc: std.mem.Allocator, pool_blocks: []const PoolBlock) !void {
        if (self.state != .FORGED) return;
        // Look for our exact hash.
        for (pool_blocks) |pb| {
            if (pb.block_no == self.forge_block_no and std.mem.eql(u8, &pb.block_hash, &self.forge_hash)) {
                self.state = .CANONICAL;
                try self.events.append(alloc, .{
                    .block_no = self.forge_block_no,
                    .block_hash = self.forge_hash,
                    .state = .CANONICAL,
                });
                return;
            }
        }
        // No match — look for a different, sufficiently-confirmed block at our height.
        for (pool_blocks) |pb| {
            if (pb.block_no == self.forge_block_no and pb.confirmations >= MIN_CONFIRMATIONS and
                !std.mem.eql(u8, &pb.block_hash, &self.forge_hash))
            {
                self.state = .ORPHANED;
                try self.events.append(alloc, .{
                    .block_no = self.forge_block_no,
                    .block_hash = self.forge_hash,
                    .state = .ORPHANED,
                });
                return;
            }
        }
    }
};

test "acceptance tracker: registerForge sets state=FORGED and emits event" {
    const alloc = std.testing.allocator;
    var t = AcceptanceTracker.init(alloc);
    defer t.deinit(alloc);

    var hash: [32]u8 = [_]u8{0} ** 32;
    hash[0] = 0xAB;
    try t.registerForge(alloc, 9_001_234, hash);

    try std.testing.expectEqual(ForgeState.FORGED, t.state);
    try std.testing.expectEqual(@as(usize, 1), t.events.items.len);
    try std.testing.expectEqual(ForgeState.FORGED, t.events.items[0].state);
    try std.testing.expectEqual(@as(u64, 9_001_234), t.events.items[0].block_no);
}

test "acceptance tracker: pool_blocks contains our hash → CANONICAL + verdict event" {
    const alloc = std.testing.allocator;
    var t = AcceptanceTracker.init(alloc);
    defer t.deinit(alloc);

    var our_hash: [32]u8 = [_]u8{0} ** 32;
    our_hash[0] = 0xAB;
    try t.registerForge(alloc, 9_001_234, our_hash);

    const pool = [_]PoolBlock{
        .{ .block_no = 9_001_234, .block_hash = our_hash, .confirmations = 4 },
    };
    try t.poll(alloc, &pool);

    try std.testing.expectEqual(ForgeState.CANONICAL, t.state);
    try std.testing.expectEqual(@as(usize, 2), t.events.items.len);
    try std.testing.expectEqual(ForgeState.CANONICAL, t.events.items[1].state);
}

test "acceptance tracker: different hash at block_no with confs>=2 → ORPHANED" {
    const alloc = std.testing.allocator;
    var t = AcceptanceTracker.init(alloc);
    defer t.deinit(alloc);

    var our_hash: [32]u8 = [_]u8{0} ** 32;
    our_hash[0] = 0xAB;
    var other_hash: [32]u8 = [_]u8{0} ** 32;
    other_hash[0] = 0xCD;

    try t.registerForge(alloc, 9_001_234, our_hash);

    const pool = [_]PoolBlock{
        .{ .block_no = 9_001_234, .block_hash = other_hash, .confirmations = 3 },
    };
    try t.poll(alloc, &pool);

    try std.testing.expectEqual(ForgeState.ORPHANED, t.state);
    try std.testing.expectEqual(@as(usize, 2), t.events.items.len);
    try std.testing.expectEqual(ForgeState.ORPHANED, t.events.items[1].state);
}

test "acceptance tracker: insufficient confirmations does NOT orphan" {
    const alloc = std.testing.allocator;
    var t = AcceptanceTracker.init(alloc);
    defer t.deinit(alloc);

    var our_hash: [32]u8 = [_]u8{0} ** 32;
    our_hash[0] = 0xAB;
    var other_hash: [32]u8 = [_]u8{0} ** 32;
    other_hash[0] = 0xCD;

    try t.registerForge(alloc, 9_001_234, our_hash);

    const pool = [_]PoolBlock{
        .{ .block_no = 9_001_234, .block_hash = other_hash, .confirmations = 1 },
    };
    try t.poll(alloc, &pool);

    // Stays FORGED — only one confirmation on the competitor.
    try std.testing.expectEqual(ForgeState.FORGED, t.state);
    try std.testing.expectEqual(@as(usize, 1), t.events.items.len);
}
