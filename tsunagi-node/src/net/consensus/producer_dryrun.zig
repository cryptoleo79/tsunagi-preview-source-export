const std = @import("std");
const shadow_producer = @import("shadow_producer.zig");
const candidate_validator = @import("candidate_validator.zig");

/// Producer dry-run engine — bounded result-model layer for local-only
/// producer cycle telemetry.
///
/// Derives DryRunEvent from an existing ShadowEvent plus optional
/// ValidationState. Never duplicates Praos/VRF/KES/candidate logic.
/// Never broadcasts. Never mutates consensus. Pure result model.
///
/// State mapping:
///   ShadowState.disabled              → DryRunState.disabled
///   ShadowState.not_configured        → DryRunState.not_configured
///   ShadowState.not_leader            → DryRunState.not_leader
///   ShadowState.local_candidate_ready + valid     → DryRunState.candidate_ready
///   ShadowState.local_candidate_ready + invalid   → DryRunState.candidate_invalid
///   ShadowState.local_candidate_failed            → DryRunState.candidate_failed

// ───────────────────────────────────────────────────────────
//  Types
// ───────────────────────────────────────────────────────────

pub const DryRunState = enum {
    disabled,
    not_configured,
    not_leader,
    candidate_ready,
    candidate_invalid,
    candidate_failed,

    pub fn label(self: DryRunState) []const u8 {
        return switch (self) {
            .disabled => "DISABLED",
            .not_configured => "NOT_CONFIGURED",
            .not_leader => "NOT_LEADER",
            .candidate_ready => "CANDIDATE_READY",
            .candidate_invalid => "CANDIDATE_INVALID",
            .candidate_failed => "CANDIDATE_FAILED",
        };
    }
};

pub const DryRunEvent = struct {
    slot: u64,
    epoch: u64,
    slot_in_epoch: u64,
    block_no: u64,
    timestamp_unix: i64,

    state: DryRunState,
    leadership: bool,
    candidate_built: bool,
    candidate_valid: bool,

    /// Header hash hex from shadow event (zero-filled if no candidate).
    header_hash_hex: [64]u8,
    /// Body hash hex from shadow event (zero-filled if no candidate).
    body_hash_hex: [64]u8,

    /// Validation state from candidate_validator (null if not validated).
    validation_state: ?candidate_validator.ValidationState,
};

pub const DryRunConfig = struct {
    enabled: bool = false,
    report_dir: ?[]const u8 = null,
    artifact_dir: ?[]const u8 = null,
};

// ───────────────────────────────────────────────────────────
//  Core derivation
// ───────────────────────────────────────────────────────────

/// Derive a DryRunEvent from a pre-computed ShadowEvent plus optional
/// validation results. Zero duplication — all Praos/VRF/KES/candidate
/// logic stays in shadow_producer and candidate_validator.
///
/// Parameters:
///   shadow_event    — result of shadow_producer.evaluate()
///   validation_state — result of candidate_validator.validate().state,
///                      or null if validation was not performed
///   candidate_valid  — true if validation_state == .valid, false otherwise.
///                      Ignored when validation_state is null.
pub fn fromShadowAndValidation(
    shadow_event: shadow_producer.ShadowEvent,
    validation_state: ?candidate_validator.ValidationState,
    candidate_valid: bool,
) DryRunEvent {
    const header_hex = std.fmt.bytesToHex(shadow_event.header_hash, .lower);
    const body_hex = std.fmt.bytesToHex(shadow_event.body_hash, .lower);

    const state: DryRunState = switch (shadow_event.state) {
        .disabled => .disabled,
        .not_configured => .not_configured,
        .not_leader => .not_leader,
        .local_candidate_ready => if (validation_state) |_|
            (if (candidate_valid) DryRunState.candidate_ready else DryRunState.candidate_invalid)
        else
            // Candidate ready but not validated — treat as ready
            DryRunState.candidate_ready,
        .local_candidate_failed => .candidate_failed,
    };

    return .{
        .slot = shadow_event.slot,
        .epoch = shadow_event.epoch,
        .slot_in_epoch = shadow_event.slot_in_epoch,
        .block_no = shadow_event.block_no,
        .timestamp_unix = shadow_event.timestamp_unix,
        .state = state,
        .leadership = shadow_event.leadership,
        .candidate_built = shadow_event.candidate_built,
        .candidate_valid = candidate_valid and (validation_state != null),
        .header_hash_hex = header_hex,
        .body_hash_hex = body_hex,
        .validation_state = validation_state,
    };
}

// ───────────────────────────────────────────────────────────
//  Bounded history (ring buffer)
// ───────────────────────────────────────────────────────────

pub const HISTORY_CAPACITY: u32 = 16;

pub const DryRunHistory = struct {
    events: [HISTORY_CAPACITY]DryRunEvent = undefined,
    head: u32 = 0,
    len: u32 = 0,

    pub fn init() DryRunHistory {
        return .{};
    }

    pub fn append(self: *DryRunHistory, event: DryRunEvent) void {
        self.events[self.head] = event;
        self.head = (self.head + 1) % HISTORY_CAPACITY;
        if (self.len < HISTORY_CAPACITY) self.len += 1;
    }

    /// Returns the most recent event, or null if empty.
    pub fn latest(self: *const DryRunHistory) ?DryRunEvent {
        if (self.len == 0) return null;
        const idx = if (self.head == 0) HISTORY_CAPACITY - 1 else self.head - 1;
        return self.events[idx];
    }

    /// Returns recent events newest-first into caller buffer.
    /// Returns number of events written.
    pub fn getRecent(self: *const DryRunHistory, buf: []DryRunEvent, max: u32) u32 {
        const n = @min(self.len, max, @as(u32, @intCast(buf.len)));
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const raw = if (self.head >= i + 1) self.head - i - 1 else HISTORY_CAPACITY - (i + 1 - self.head);
            buf[i] = self.events[raw];
        }
        return n;
    }

    pub fn count(self: *const DryRunHistory) u32 {
        return self.len;
    }
};

// ───────────────────────────────────────────────────────────
//  JSON report formatting
// ───────────────────────────────────────────────────────────

/// Format a DryRunEvent as a JSON line for journal output.
/// Writes into caller-provided buffer. Returns the written slice.
pub fn formatEventJson(event: DryRunEvent, buf: []u8) ![]const u8 {
    const vs_label: []const u8 = if (event.validation_state) |vs| switch (vs) {
        .valid => "valid",
        .invalid_structure => "invalid_structure",
        .invalid_hash => "invalid_hash",
        .invalid_signature => "invalid_signature",
        .invalid_consistency => "invalid_consistency",
        .error_state => "error_state",
    } else "null";

    const len = (try std.fmt.bufPrint(buf,
        \\{{"type":"dryrun_event","slot":{d},"epoch":{d},"slot_in_epoch":{d},"block_no":{d},"timestamp_unix":{d},"state":"{s}","leadership":{s},"candidate_built":{s},"candidate_valid":{s},"validation_state":"{s}","header_hash":"{s}","body_hash":"{s}"}}
    , .{
        event.slot,
        event.epoch,
        event.slot_in_epoch,
        event.block_no,
        event.timestamp_unix,
        event.state.label(),
        if (event.leadership) "true" else "false",
        if (event.candidate_built) "true" else "false",
        if (event.candidate_valid) "true" else "false",
        vs_label,
        event.header_hash_hex[0..],
        event.body_hash_hex[0..],
    })).len;
    return buf[0..len];
}

// ───────────────────────────────────────────────────────────
//  Inline tests
// ───────────────────────────────────────────────────────────

fn makeShadowEvent(state: shadow_producer.ShadowState, slot: u64) shadow_producer.ShadowEvent {
    return .{
        .slot = slot,
        .epoch = 0,
        .slot_in_epoch = slot,
        .state = state,
        .leadership = (state == .local_candidate_ready or state == .local_candidate_failed),
        .candidate_built = (state == .local_candidate_ready),
        .block_no = 1000,
        .timestamp_unix = 1710000000,
        .header_hash = [_]u8{0xAB} ** 32,
        .body_hash = [_]u8{0xCD} ** 32,
    };
}

test "dryrun — disabled maps to disabled" {
    const se = makeShadowEvent(.disabled, 100);
    const dr = fromShadowAndValidation(se, null, false);
    try std.testing.expectEqual(DryRunState.disabled, dr.state);
    try std.testing.expectEqual(false, dr.leadership);
    try std.testing.expectEqual(false, dr.candidate_valid);
    try std.testing.expectEqual(@as(u64, 100), dr.slot);
}

test "dryrun — not_configured maps to not_configured" {
    const se = makeShadowEvent(.not_configured, 200);
    const dr = fromShadowAndValidation(se, null, false);
    try std.testing.expectEqual(DryRunState.not_configured, dr.state);
}

test "dryrun — not_leader maps to not_leader" {
    const se = makeShadowEvent(.not_leader, 300);
    const dr = fromShadowAndValidation(se, null, false);
    try std.testing.expectEqual(DryRunState.not_leader, dr.state);
    try std.testing.expectEqual(false, dr.leadership);
    try std.testing.expectEqual(false, dr.candidate_valid);
}

test "dryrun — candidate_ready with valid validation" {
    const se = makeShadowEvent(.local_candidate_ready, 400);
    const dr = fromShadowAndValidation(se, .valid, true);
    try std.testing.expectEqual(DryRunState.candidate_ready, dr.state);
    try std.testing.expectEqual(true, dr.leadership);
    try std.testing.expectEqual(true, dr.candidate_built);
    try std.testing.expectEqual(true, dr.candidate_valid);
    try std.testing.expectEqual(candidate_validator.ValidationState.valid, dr.validation_state.?);
}

test "dryrun — candidate_ready with invalid validation" {
    const se = makeShadowEvent(.local_candidate_ready, 500);
    const dr = fromShadowAndValidation(se, .invalid_hash, false);
    try std.testing.expectEqual(DryRunState.candidate_invalid, dr.state);
    try std.testing.expectEqual(true, dr.leadership);
    try std.testing.expectEqual(true, dr.candidate_built);
    try std.testing.expectEqual(false, dr.candidate_valid);
    try std.testing.expectEqual(candidate_validator.ValidationState.invalid_hash, dr.validation_state.?);
}

test "dryrun — candidate_ready without validation (null)" {
    const se = makeShadowEvent(.local_candidate_ready, 550);
    const dr = fromShadowAndValidation(se, null, false);
    try std.testing.expectEqual(DryRunState.candidate_ready, dr.state);
    try std.testing.expectEqual(true, dr.candidate_built);
    try std.testing.expectEqual(false, dr.candidate_valid);
    try std.testing.expect(dr.validation_state == null);
}

test "dryrun — candidate_failed maps to candidate_failed" {
    const se = makeShadowEvent(.local_candidate_failed, 600);
    const dr = fromShadowAndValidation(se, null, false);
    try std.testing.expectEqual(DryRunState.candidate_failed, dr.state);
    try std.testing.expectEqual(true, dr.leadership);
    try std.testing.expectEqual(false, dr.candidate_built);
}

test "dryrun — state labels" {
    try std.testing.expectEqualStrings("DISABLED", DryRunState.disabled.label());
    try std.testing.expectEqualStrings("NOT_CONFIGURED", DryRunState.not_configured.label());
    try std.testing.expectEqualStrings("NOT_LEADER", DryRunState.not_leader.label());
    try std.testing.expectEqualStrings("CANDIDATE_READY", DryRunState.candidate_ready.label());
    try std.testing.expectEqualStrings("CANDIDATE_INVALID", DryRunState.candidate_invalid.label());
    try std.testing.expectEqualStrings("CANDIDATE_FAILED", DryRunState.candidate_failed.label());
}

test "dryrun — config defaults to disabled" {
    const cfg = DryRunConfig{};
    try std.testing.expectEqual(false, cfg.enabled);
    try std.testing.expect(cfg.report_dir == null);
    try std.testing.expect(cfg.artifact_dir == null);
}

test "dryrun — history init empty" {
    const hist = DryRunHistory.init();
    try std.testing.expectEqual(@as(u32, 0), hist.count());
    try std.testing.expect(hist.latest() == null);
}

test "dryrun — history append and latest" {
    var hist = DryRunHistory.init();
    const se = makeShadowEvent(.not_leader, 100);
    const dr = fromShadowAndValidation(se, null, false);
    hist.append(dr);
    try std.testing.expectEqual(@as(u32, 1), hist.count());
    const latest = hist.latest().?;
    try std.testing.expectEqual(DryRunState.not_leader, latest.state);
    try std.testing.expectEqual(@as(u64, 100), latest.slot);
}

test "dryrun — history ring buffer wraps" {
    var hist = DryRunHistory.init();
    var i: u32 = 0;
    while (i < HISTORY_CAPACITY + 5) : (i += 1) {
        const se = makeShadowEvent(.not_leader, 1000 + i);
        const dr = fromShadowAndValidation(se, null, false);
        hist.append(dr);
    }
    try std.testing.expectEqual(HISTORY_CAPACITY, hist.count());
    const latest = hist.latest().?;
    try std.testing.expectEqual(@as(u64, 1000 + HISTORY_CAPACITY + 4), latest.slot);
}

test "dryrun — history getRecent returns newest first" {
    var hist = DryRunHistory.init();
    const slots = [_]u64{ 100, 200, 300 };
    for (slots) |s| {
        const se = makeShadowEvent(.not_leader, s);
        const dr = fromShadowAndValidation(se, null, false);
        hist.append(dr);
    }
    var buf: [10]DryRunEvent = undefined;
    const n = hist.getRecent(&buf, 10);
    try std.testing.expectEqual(@as(u32, 3), n);
    try std.testing.expectEqual(@as(u64, 300), buf[0].slot);
    try std.testing.expectEqual(@as(u64, 200), buf[1].slot);
    try std.testing.expectEqual(@as(u64, 100), buf[2].slot);
}

test "dryrun — formatEventJson produces valid line" {
    const se = makeShadowEvent(.not_leader, 42000);
    const dr = fromShadowAndValidation(se, null, false);

    var buf: [1024]u8 = undefined;
    const json = try formatEventJson(dr, &buf);

    try std.testing.expect(json.len > 0);
    try std.testing.expectEqual(@as(u8, '{'), json[0]);
    try std.testing.expectEqual(@as(u8, '}'), json[json.len - 1]);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dryrun_event\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"NOT_LEADER\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"slot\":42000") != null);
}

test "dryrun — formatEventJson with validation state" {
    const se = makeShadowEvent(.local_candidate_ready, 55000);
    const dr = fromShadowAndValidation(se, .valid, true);

    var buf: [1024]u8 = undefined;
    const json = try formatEventJson(dr, &buf);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"CANDIDATE_READY\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"candidate_valid\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"validation_state\":\"valid\"") != null);
}

test "dryrun — header/body hash hex encoding" {
    const se = makeShadowEvent(.local_candidate_ready, 700);
    const dr = fromShadowAndValidation(se, .valid, true);
    // header_hash was [0xAB]*32, body_hash was [0xCD]*32
    try std.testing.expect(std.mem.startsWith(u8, &dr.header_hash_hex, "abab"));
    try std.testing.expect(std.mem.startsWith(u8, &dr.body_hash_hex, "cdcd"));
}
