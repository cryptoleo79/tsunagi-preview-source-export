const std = @import("std");
const bridge = @import("producer_bridge.zig");

/// Shadow producer — local-only candidate evaluation on live slot progression.
///
/// Reads post-tick producer state, maps to bridge inputs, evaluates readiness.
/// Never transmits blocks. Never sends protocol messages. Never mutates
/// peer/network behavior. Pure computation + optional local file output.
///
/// This is the final rehearsal stage: "Given real runtime state, would this
/// node have produced a candidate block for this slot?"

// ───────────────────────────────────────────────────────────
//  Types
// ───────────────────────────────────────────────────────────

pub const ShadowState = enum {
    disabled,
    not_configured,
    not_leader,
    local_candidate_ready,
    local_candidate_failed,

    pub fn label(self: ShadowState) []const u8 {
        return switch (self) {
            .disabled => "DISABLED",
            .not_configured => "NOT_CONFIGURED",
            .not_leader => "NOT_LEADER",
            .local_candidate_ready => "LOCAL_CANDIDATE_READY",
            .local_candidate_failed => "LOCAL_CANDIDATE_FAILED",
        };
    }
};

pub const ShadowEvent = struct {
    slot: u64,
    epoch: u64,
    slot_in_epoch: u64,
    state: ShadowState,
    leadership: bool,
    candidate_built: bool,
    block_no: u64,
    timestamp_unix: i64,

    /// Bridge result header hash (zero if no candidate).
    header_hash: [32]u8,
    /// Bridge result body hash (zero if no candidate).
    body_hash: [32]u8,
};

pub const ShadowConfig = struct {
    enabled: bool = false,
    report_dir: ?[]const u8 = null,
    artifact_dir: ?[]const u8 = null,
};

/// Runtime-shaped inputs for shadow evaluation.
///
/// The caller (chainsync_mux_smoke.zig) populates this from ProducerContext
/// fields that are already computed by producer.tick(). The shadow module
/// never imports or touches ProducerContext directly.
pub const ShadowInputs = struct {
    // Slot/epoch (from producer_ctx post-tick)
    slot: u64,
    epoch: u64,
    slot_in_epoch: u64,

    // Chain tip (from producer_ctx post-tick)
    tip_block_no: u64,
    tip_hash32: [32]u8,

    // Material availability (from key_cfg, vrf_cfg, stake_cfg)
    has_vrf: bool,
    has_kes: bool,
    has_pool_id: bool,
    has_stake: bool,

    // Stake parameters (from stake_cfg)
    stake_fraction_x1e9: u64,
    asc_x1e6: u64,

    // KES parameters (from producer_ctx post-tick)
    current_kes_period: u32,
    opcert_start_period: u32,
    max_kes_evolutions: u32,

    // Network
    net_magic: u32,

    // Pre-computed VRF output (from producer_ctx.vrf_output_bytes_last)
    vrf_output: [64]u8,

    // KES key state (from producer_ctx.kes_key_state)
    // Passed as optional slice to match bridge API.
    kes_key_state: ?[]const u8,

    // KES public key (from producer_ctx — extracted root PK)
    kes_pk: [32]u8,

    // Pool ID (from key_cfg.pool_id_hex → decoded)
    pool_id: [32]u8,

    // Timestamp for event recording
    timestamp_unix: i64,
};

// ───────────────────────────────────────────────────────────
//  Bounded last-event store
// ───────────────────────────────────────────────────────────

pub const HISTORY_CAPACITY: u32 = 16;

pub const ShadowHistory = struct {
    events: [HISTORY_CAPACITY]ShadowEvent = undefined,
    head: u32 = 0,
    len: u32 = 0,

    pub fn init() ShadowHistory {
        return .{};
    }

    pub fn append(self: *ShadowHistory, event: ShadowEvent) void {
        self.events[self.head] = event;
        self.head = (self.head + 1) % HISTORY_CAPACITY;
        if (self.len < HISTORY_CAPACITY) self.len += 1;
    }

    /// Returns the most recent event, or null if empty.
    pub fn latest(self: *const ShadowHistory) ?ShadowEvent {
        if (self.len == 0) return null;
        const idx = if (self.head == 0) HISTORY_CAPACITY - 1 else self.head - 1;
        return self.events[idx];
    }

    /// Returns recent events newest-first into caller buffer.
    /// Returns number of events written.
    pub fn getRecent(self: *const ShadowHistory, buf: []ShadowEvent, max: u32) u32 {
        const n = @min(self.len, max, @as(u32, @intCast(buf.len)));
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const raw = if (self.head >= i + 1) self.head - i - 1 else HISTORY_CAPACITY - (i + 1 - self.head);
            buf[i] = self.events[raw];
        }
        return n;
    }

    pub fn count(self: *const ShadowHistory) u32 {
        return self.len;
    }
};

// ───────────────────────────────────────────────────────────
//  Core evaluation
// ───────────────────────────────────────────────────────────

/// Evaluate shadow producer state from post-tick runtime inputs.
///
/// Maps ShadowInputs to BridgeInputs, calls bridge.evaluateFromInputs(),
/// and translates the result to a ShadowEvent.
///
/// Pure computation. No IO. No broadcast. No protocol messages.
pub fn evaluate(inputs: ShadowInputs) ShadowEvent {
    const bridge_inputs = bridge.BridgeInputs{
        .slot = inputs.slot,
        .epoch = inputs.epoch,
        .slot_in_epoch = inputs.slot_in_epoch,
        .tip_block_no = inputs.tip_block_no,
        .tip_hash32 = inputs.tip_hash32,
        .has_vrf = inputs.has_vrf,
        .has_kes = inputs.has_kes,
        .has_pool_id = inputs.has_pool_id,
        .has_stake = inputs.has_stake,
        .stake_fraction_x1e9 = inputs.stake_fraction_x1e9,
        .asc_x1e6 = inputs.asc_x1e6,
        .current_kes_period = inputs.current_kes_period,
        .opcert_start_period = inputs.opcert_start_period,
        .max_kes_evolutions = inputs.max_kes_evolutions,
        .net_magic = inputs.net_magic,
    };

    const result = bridge.evaluateFromInputs(
        bridge_inputs,
        inputs.vrf_output,
        inputs.kes_key_state,
        inputs.kes_pk,
        inputs.pool_id,
    );

    const state: ShadowState = switch (result.state) {
        .idle => .disabled,
        .not_configured => .not_configured,
        .not_leader => .not_leader,
        .ready_local_candidate => if (result.candidate_built) .local_candidate_ready else .local_candidate_failed,
        .error_state => .local_candidate_failed,
    };

    return .{
        .slot = inputs.slot,
        .epoch = inputs.epoch,
        .slot_in_epoch = inputs.slot_in_epoch,
        .state = state,
        .leadership = result.leadership,
        .candidate_built = result.candidate_built,
        .block_no = inputs.tip_block_no,
        .timestamp_unix = inputs.timestamp_unix,
        .header_hash = result.header_hash,
        .body_hash = result.body_hash,
    };
}

// ───────────────────────────────────────────────────────────
//  JSON report formatting
// ───────────────────────────────────────────────────────────

/// Format a ShadowEvent as a JSON line for journal output.
/// Writes into caller-provided buffer. Returns the written slice.
pub fn formatEventJson(event: ShadowEvent, buf: []u8) ![]const u8 {
    var hdr_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hdr_hex, "{x}", .{&event.header_hash}) catch unreachable;
    var body_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&body_hex, "{x}", .{&event.body_hash}) catch unreachable;

    const len = (try std.fmt.bufPrint(buf,
        \\{{"type":"shadow_event","slot":{d},"epoch":{d},"slot_in_epoch":{d},"state":"{s}","leadership":{s},"candidate_built":{s},"block_no":{d},"timestamp_unix":{d},"header_hash":"{s}","body_hash":"{s}"}}
    , .{
        event.slot,
        event.epoch,
        event.slot_in_epoch,
        event.state.label(),
        if (event.leadership) "true" else "false",
        if (event.candidate_built) "true" else "false",
        event.block_no,
        event.timestamp_unix,
        hdr_hex[0..],
        body_hex[0..],
    })).len;
    return buf[0..len];
}

// ───────────────────────────────────────────────────────────
//  Inline tests
// ───────────────────────────────────────────────────────────

fn makeTestInputs() ShadowInputs {
    return .{
        .slot = 50000,
        .epoch = 0,
        .slot_in_epoch = 50000,
        .tip_block_no = 1000,
        .tip_hash32 = [_]u8{0xAA} ** 32,
        .has_vrf = false,
        .has_kes = false,
        .has_pool_id = false,
        .has_stake = false,
        .stake_fraction_x1e9 = 0,
        .asc_x1e6 = 50_000,
        .current_kes_period = 0,
        .opcert_start_period = 0,
        .max_kes_evolutions = 62,
        .net_magic = 2,
        .vrf_output = [_]u8{0} ** 64,
        .kes_key_state = null,
        .kes_pk = [_]u8{0} ** 32,
        .pool_id = [_]u8{0} ** 32,
        .timestamp_unix = 1710000000,
    };
}

test "shadow — not_configured when no material" {
    const inputs = makeTestInputs();
    const event = evaluate(inputs);

    try std.testing.expectEqual(ShadowState.not_configured, event.state);
    try std.testing.expectEqual(false, event.leadership);
    try std.testing.expectEqual(false, event.candidate_built);
    try std.testing.expectEqual(@as(u64, 50000), event.slot);
    try std.testing.expectEqual(@as(u64, 1000), event.block_no);
    try std.testing.expectEqual(@as(i64, 1710000000), event.timestamp_unix);
}

test "shadow — not_leader with valid material but high VRF" {
    var inputs = makeTestInputs();
    inputs.has_vrf = true;
    inputs.has_pool_id = true;
    inputs.has_stake = true;
    inputs.stake_fraction_x1e9 = 1_000;
    inputs.current_kes_period = 10;
    inputs.opcert_start_period = 5;
    inputs.vrf_output = [_]u8{0xFF} ** 64; // max VRF → not leader
    inputs.kes_pk = [_]u8{0xDD} ** 32;
    inputs.pool_id = [_]u8{0xCC} ** 32;

    const event = evaluate(inputs);

    try std.testing.expectEqual(ShadowState.not_leader, event.state);
    try std.testing.expectEqual(false, event.leadership);
    try std.testing.expectEqual(true, event.candidate_built);
}

test "shadow — local_candidate_failed when leader but KES skipped" {
    var inputs = makeTestInputs();
    inputs.has_vrf = true;
    inputs.has_kes = false;
    inputs.has_pool_id = true;
    inputs.has_stake = true;
    inputs.stake_fraction_x1e9 = 500_000_000;
    inputs.current_kes_period = 10;
    inputs.opcert_start_period = 5;
    // Small VRF output → would be leader
    inputs.vrf_output = [_]u8{0} ** 64;
    inputs.vrf_output[1] = 0x01;
    inputs.kes_pk = [_]u8{0xDD} ** 32;
    inputs.pool_id = [_]u8{0xCC} ** 32;

    const event = evaluate(inputs);

    // Would be leader, but sign_verify is skipped → not_ready → error_state → local_candidate_failed
    try std.testing.expectEqual(ShadowState.local_candidate_failed, event.state);
}

test "shadow — state labels" {
    try std.testing.expectEqualStrings("DISABLED", ShadowState.disabled.label());
    try std.testing.expectEqualStrings("NOT_CONFIGURED", ShadowState.not_configured.label());
    try std.testing.expectEqualStrings("NOT_LEADER", ShadowState.not_leader.label());
    try std.testing.expectEqualStrings("LOCAL_CANDIDATE_READY", ShadowState.local_candidate_ready.label());
    try std.testing.expectEqualStrings("LOCAL_CANDIDATE_FAILED", ShadowState.local_candidate_failed.label());
}

test "shadow — history init empty" {
    const hist = ShadowHistory.init();
    try std.testing.expectEqual(@as(u32, 0), hist.count());
    try std.testing.expect(hist.latest() == null);
}

test "shadow — history append and latest" {
    var hist = ShadowHistory.init();
    const inputs = makeTestInputs();
    const event = evaluate(inputs);

    hist.append(event);
    try std.testing.expectEqual(@as(u32, 1), hist.count());

    const latest = hist.latest().?;
    try std.testing.expectEqual(ShadowState.not_configured, latest.state);
    try std.testing.expectEqual(@as(u64, 50000), latest.slot);
}

test "shadow — history ring buffer wraps" {
    var hist = ShadowHistory.init();
    var inputs = makeTestInputs();

    // Fill beyond capacity
    var i: u32 = 0;
    while (i < HISTORY_CAPACITY + 5) : (i += 1) {
        inputs.slot = 50000 + i;
        const event = evaluate(inputs);
        hist.append(event);
    }

    try std.testing.expectEqual(HISTORY_CAPACITY, hist.count());

    // Latest should be the last appended
    const latest = hist.latest().?;
    try std.testing.expectEqual(@as(u64, 50000 + HISTORY_CAPACITY + 4), latest.slot);
}

test "shadow — history getRecent returns newest first" {
    var hist = ShadowHistory.init();
    var inputs = makeTestInputs();

    inputs.slot = 100;
    hist.append(evaluate(inputs));
    inputs.slot = 200;
    hist.append(evaluate(inputs));
    inputs.slot = 300;
    hist.append(evaluate(inputs));

    var buf: [10]ShadowEvent = undefined;
    const n = hist.getRecent(&buf, 10);
    try std.testing.expectEqual(@as(u32, 3), n);
    try std.testing.expectEqual(@as(u64, 300), buf[0].slot);
    try std.testing.expectEqual(@as(u64, 200), buf[1].slot);
    try std.testing.expectEqual(@as(u64, 100), buf[2].slot);
}

test "shadow — formatEventJson produces valid line" {
    const inputs = makeTestInputs();
    const event = evaluate(inputs);

    var buf: [1024]u8 = undefined;
    const json = try formatEventJson(event, &buf);

    // Should start with { and end with }
    try std.testing.expect(json.len > 0);
    try std.testing.expectEqual(@as(u8, '{'), json[0]);
    try std.testing.expectEqual(@as(u8, '}'), json[json.len - 1]);

    // Should contain key fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"shadow_event\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"NOT_CONFIGURED\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"slot\":50000") != null);
}

test "shadow — config defaults to disabled" {
    const cfg = ShadowConfig{};
    try std.testing.expectEqual(false, cfg.enabled);
    try std.testing.expect(cfg.report_dir == null);
    try std.testing.expect(cfg.artifact_dir == null);
}
