// TSUNAGI Health Engine — deterministic health scoring from observability data.
//
// Pure scoring logic. No file IO, no web, no runtime hooks, no allocations.
// Consumes structured inputs derived from existing JSON endpoints and produces
// a bounded integer health report.
//
// Scoring is heuristic operator guidance, not protocol truth.
// Sparse data early after startup yields neutral/default scoring.

pub const HealthState = enum {
    excellent,
    healthy,
    degraded,
    critical,

    pub fn label(self: HealthState) []const u8 {
        return switch (self) {
            .excellent => "excellent",
            .healthy => "healthy",
            .degraded => "degraded",
            .critical => "critical",
        };
    }
};

pub const HealthInputs = struct {
    // Peer stability: from network.json
    connect_count: u32 = 0,
    disconnect_count: u32 = 0,

    // Slot rhythm: from slot-observatory.json
    // avg gap scaled by 10 to avoid float (e.g. 12 = 1.2s avg gap)
    // null means no slot data available yet
    avg_gap_x10: ?u32 = null,

    // Block stability: from operator.json pipeline
    blocks_processed: u64 = 0,
    rollbacks: u32 = 0,

    // Confirmation latency: from confirmation.json
    // null means no confirmations observed yet
    avg_confirmation_seconds: ?u32 = null,

    // Mempool pressure: from mempool.json
    mempool_pending_count: u32 = 0,
};

pub const HealthReport = struct {
    score: u8,
    state: HealthState,

    peer_score: u8,
    slot_score: u8,
    block_score: u8,
    confirmation_score: u8,
    mempool_score: u8,
};

// Neutral default score for components with no data yet.
const NEUTRAL: u8 = 80;

/// Compute a health report from observability inputs.
/// Pure function. No side effects, no allocations.
pub fn compute(inputs: HealthInputs) HealthReport {
    const peer = computePeerScore(inputs);
    const slot = computeSlotScore(inputs);
    const block = computeBlockScore(inputs);
    const confirmation = computeConfirmationScore(inputs);
    const mempool = computeMempoolScore(inputs);

    // Weighted average: peer 25, slot 20, block 25, confirmation 15, mempool 15
    const weighted: u32 = @as(u32, peer) * 25 +
        @as(u32, slot) * 20 +
        @as(u32, block) * 25 +
        @as(u32, confirmation) * 15 +
        @as(u32, mempool) * 15;
    const score: u8 = @intCast(weighted / 100);

    return .{
        .score = score,
        .state = stateFromScore(score),
        .peer_score = peer,
        .slot_score = slot,
        .block_score = block,
        .confirmation_score = confirmation,
        .mempool_score = mempool,
    };
}

fn stateFromScore(score: u8) HealthState {
    if (score >= 90) return .excellent;
    if (score >= 75) return .healthy;
    if (score >= 60) return .degraded;
    return .critical;
}

fn computePeerScore(inputs: HealthInputs) u8 {
    // No connection data yet — neutral
    if (inputs.connect_count == 0 and inputs.disconnect_count == 0) return NEUTRAL;

    // Connected with no disconnects — perfect
    if (inputs.disconnect_count == 0 and inputs.connect_count > 0) return 100;

    // Compute disconnect rate (integer percentage)
    // disconnect_rate = disconnect_count * 100 / max(connect_count, 1)
    const denom = if (inputs.connect_count > 0) inputs.connect_count else 1;
    const rate: u32 = (inputs.disconnect_count * 100) / denom;

    // rate 0% = 100, rate >= 100% = 30, linear between
    if (rate >= 100) return 30;
    // score = 100 - (rate * 70 / 100)
    return @intCast(100 - (rate * 70) / 100);
}

fn computeSlotScore(inputs: HealthInputs) u8 {
    const gap_x10 = inputs.avg_gap_x10 orelse return NEUTRAL;

    // Ideal: gap around 10-30 (1.0s - 3.0s). Cardano slot interval is 1s,
    // but not every slot has a block; typical gaps are 1-20s on preview.
    // gap_x10 <= 30 (3.0s): excellent (100)
    // gap_x10 30-100 (3.0-10.0s): linear 100->70
    // gap_x10 100-300 (10.0-30.0s): linear 70->40
    // gap_x10 >= 300 (30.0s+): 40
    if (gap_x10 <= 30) return 100;
    if (gap_x10 <= 100) {
        // linear from 100 to 70 over range 30..100
        const offset = gap_x10 - 30;
        return @intCast(100 - (offset * 30) / 70);
    }
    if (gap_x10 <= 300) {
        // linear from 70 to 40 over range 100..300
        const offset = gap_x10 - 100;
        return @intCast(70 - (offset * 30) / 200);
    }
    return 40;
}

fn computeBlockScore(inputs: HealthInputs) u8 {
    // No blocks processed yet — neutral
    if (inputs.blocks_processed == 0) return NEUTRAL;

    // No rollbacks — perfect
    if (inputs.rollbacks == 0) return 100;

    // Rollback rate per 10000 blocks (integer)
    const bp = if (inputs.blocks_processed > 0) inputs.blocks_processed else 1;
    // Cap blocks_processed for the ratio to avoid overflow
    const bp_capped: u32 = if (bp > 1_000_000) 1_000_000 else @intCast(bp);
    const rate_per_10k: u32 = (@as(u32, inputs.rollbacks) * 10_000) / bp_capped;

    // rate 0 = 100, rate >= 100 per 10k = 40, linear between
    if (rate_per_10k >= 100) return 40;
    // score = 100 - (rate_per_10k * 60 / 100)
    return @intCast(100 - (rate_per_10k * 60) / 100);
}

fn computeConfirmationScore(inputs: HealthInputs) u8 {
    const avg = inputs.avg_confirmation_seconds orelse return NEUTRAL;

    // <= 30s: excellent (100)
    // 30-120s: linear 100->60
    // 120-300s: linear 60->30
    // >= 300s: 30
    if (avg <= 30) return 100;
    if (avg <= 120) {
        const offset = avg - 30;
        return @intCast(100 - (offset * 40) / 90);
    }
    if (avg <= 300) {
        const offset = avg - 120;
        return @intCast(60 - (offset * 30) / 180);
    }
    return 30;
}

fn computeMempoolScore(inputs: HealthInputs) u8 {
    const pending = inputs.mempool_pending_count;

    // 0 pending: perfect
    // 1-10: 95
    // 11-50: linear 95->70
    // 51-200: linear 70->40
    // >= 200: 40
    if (pending == 0) return 100;
    if (pending <= 10) return 95;
    if (pending <= 50) {
        const offset = pending - 10;
        return @intCast(95 - (offset * 25) / 40);
    }
    if (pending <= 200) {
        const offset = pending - 50;
        return @intCast(70 - (offset * 30) / 150);
    }
    return 40;
}

// ── Tests ──

const testing = @import("std").testing;

test "healthy scenario — all good data" {
    const r = compute(.{
        .connect_count = 10,
        .disconnect_count = 0,
        .avg_gap_x10 = 20, // 2.0s
        .blocks_processed = 50000,
        .rollbacks = 0,
        .avg_confirmation_seconds = 20,
        .mempool_pending_count = 0,
    });
    try testing.expect(r.score >= 90);
    try testing.expect(r.state == .excellent);
    try testing.expect(r.peer_score == 100);
    try testing.expect(r.slot_score == 100);
    try testing.expect(r.block_score == 100);
    try testing.expect(r.confirmation_score == 100);
    try testing.expect(r.mempool_score == 100);
}

test "degraded due to disconnects" {
    const r = compute(.{
        .connect_count = 10,
        .disconnect_count = 8,
        .avg_gap_x10 = 20,
        .blocks_processed = 50000,
        .rollbacks = 0,
        .avg_confirmation_seconds = 20,
        .mempool_pending_count = 0,
    });
    try testing.expect(r.peer_score < 50);
    try testing.expect(r.score < 90);
}

test "degraded due to large avg gap" {
    const r = compute(.{
        .connect_count = 10,
        .disconnect_count = 0,
        .avg_gap_x10 = 200, // 20.0s
        .blocks_processed = 50000,
        .rollbacks = 0,
        .avg_confirmation_seconds = 20,
        .mempool_pending_count = 0,
    });
    try testing.expect(r.slot_score < 70);
    try testing.expect(r.slot_score >= 40);
}

test "degraded due to rollbacks" {
    const r = compute(.{
        .connect_count = 10,
        .disconnect_count = 0,
        .avg_gap_x10 = 20,
        .blocks_processed = 10000,
        .rollbacks = 50, // 50 per 10k = rate 50
        .avg_confirmation_seconds = 20,
        .mempool_pending_count = 0,
    });
    try testing.expect(r.block_score < 80);
    try testing.expect(r.block_score >= 60);
}

test "degraded due to confirmation latency" {
    const r = compute(.{
        .connect_count = 10,
        .disconnect_count = 0,
        .avg_gap_x10 = 20,
        .blocks_processed = 50000,
        .rollbacks = 0,
        .avg_confirmation_seconds = 180, // 3 minutes
        .mempool_pending_count = 0,
    });
    try testing.expect(r.confirmation_score < 60);
    try testing.expect(r.confirmation_score >= 30);
}

test "degraded due to mempool pressure" {
    const r = compute(.{
        .connect_count = 10,
        .disconnect_count = 0,
        .avg_gap_x10 = 20,
        .blocks_processed = 50000,
        .rollbacks = 0,
        .avg_confirmation_seconds = 20,
        .mempool_pending_count = 150,
    });
    try testing.expect(r.mempool_score < 60);
    try testing.expect(r.mempool_score >= 40);
}

test "neutral — no data scenario" {
    const r = compute(.{});
    try testing.expect(r.peer_score == NEUTRAL);
    try testing.expect(r.slot_score == NEUTRAL);
    try testing.expect(r.block_score == NEUTRAL);
    try testing.expect(r.confirmation_score == NEUTRAL);
    try testing.expect(r.mempool_score == 100); // 0 pending = perfect
    // Overall: (80*25 + 80*20 + 80*25 + 80*15 + 100*15) / 100 = (2000+1600+2000+1200+1500)/100 = 83
    try testing.expect(r.score == 83);
    try testing.expect(r.state == .healthy);
}

test "state thresholds correct" {
    try testing.expect(stateFromScore(100) == .excellent);
    try testing.expect(stateFromScore(95) == .excellent);
    try testing.expect(stateFromScore(90) == .excellent);
    try testing.expect(stateFromScore(89) == .healthy);
    try testing.expect(stateFromScore(75) == .healthy);
    try testing.expect(stateFromScore(74) == .degraded);
    try testing.expect(stateFromScore(60) == .degraded);
    try testing.expect(stateFromScore(59) == .critical);
    try testing.expect(stateFromScore(0) == .critical);
}
