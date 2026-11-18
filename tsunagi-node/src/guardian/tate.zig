const std = @import("std");

// ── TATE 盾 — Fragment Defense Evaluator ───────────────────────────
//
// Pure evaluation module for propagation/fragment safety assessment.
// Takes structured input, returns verdicts and recommendations.
// No file I/O, no protocol imports, no side effects.

pub const Verdict = enum { ok, warn, crit, skip };

// ── Thresholds ──

pub const ARTIFACT_AGE_OK: i64 = 300;
pub const ARTIFACT_AGE_WARN: i64 = 1800;
pub const DEPTH_OK: u64 = 100;
pub const DEPTH_WARN: u64 = 10;
pub const TIP_AGE_OK: i64 = 120;
pub const TIP_AGE_WARN: i64 = 600;
pub const GAP_OK: i64 = 60;
pub const GAP_WARN: i64 = 300;

pub const MAX_RECS = 8;

pub const Input = struct {
    /// cursor.json was found and readable
    cursor_present: bool,
    /// Chain tip slot from cursor.json
    cursor_slot: ?u64,
    /// Unix timestamp of last cursor update
    cursor_updated_unix: ?i64,

    /// propagation_artifact/ directory exists
    artifact_exists: bool,
    /// Unix timestamp from meta.json (null if missing)
    artifact_unix: ?i64,

    /// coverage.json was found and parseable
    coverage_present: bool,
    /// Fields from coverage.json (null if coverage absent)
    usable_depth: ?u64,
    break_count: ?u64,
    newest_slot: ?u64,
    oldest_slot: ?u64,

    /// Current wall-clock unix timestamp
    now: i64,
};

pub const Report = struct {
    artifact_present: Verdict,
    artifact_age: Verdict,
    usable_depth: Verdict,
    break_count: Verdict,
    follower_tip_age: Verdict,
    tip_artifact_gap: Verdict,
    coverage_metadata: Verdict,
    overall: Verdict,

    /// Computed values for display (null = not computable)
    artifact_age_secs: ?i64,
    tip_age_secs: ?i64,
    gap_slots: ?i64,
    depth_value: ?u64,
    break_value: ?u64,

    /// Operator recommendations
    recs: [MAX_RECS][]const u8,
    rec_count: usize,
};

pub fn evaluate(input: Input) Report {
    var r = Report{
        .artifact_present = .ok,
        .artifact_age = .ok,
        .usable_depth = .ok,
        .break_count = .ok,
        .follower_tip_age = .ok,
        .tip_artifact_gap = .ok,
        .coverage_metadata = .ok,
        .overall = .ok,
        .artifact_age_secs = null,
        .tip_age_secs = null,
        .gap_slots = null,
        .depth_value = null,
        .break_value = null,
        .recs = [_][]const u8{""} ** MAX_RECS,
        .rec_count = 0,
    };

    // ── Signal 1: artifact_present ──
    if (!input.artifact_exists) {
        r.artifact_present = .crit;
        appendRec(&r, "propagation artifact missing; run seal-tip");
    }

    // ── Signal 2: artifact_age ──
    if (!input.artifact_exists) {
        r.artifact_age = .skip;
    } else if (input.artifact_unix) |unix| {
        const age = input.now - unix;
        r.artifact_age_secs = age;
        if (age <= ARTIFACT_AGE_OK) {
            r.artifact_age = .ok;
        } else if (age <= ARTIFACT_AGE_WARN) {
            r.artifact_age = .warn;
            appendRec(&r, "artifact is aging; run seal-tip soon");
        } else {
            r.artifact_age = .crit;
            appendRec(&r, "reseal propagation artifact immediately");
        }
    } else {
        r.artifact_age = .warn;
        appendRec(&r, "meta.json missing; cannot determine artifact age");
    }

    // ── Signal 3: usable_depth ──
    if (!input.artifact_exists) {
        r.usable_depth = .skip;
    } else if (input.usable_depth) |depth| {
        r.depth_value = depth;
        if (depth >= DEPTH_OK) {
            r.usable_depth = .ok;
        } else if (depth >= DEPTH_WARN) {
            r.usable_depth = .warn;
            appendRec(&r, "usable depth reduced; intersection reliability reduced");
        } else {
            r.usable_depth = .crit;
            appendRec(&r, "usable depth too low for reliable intersection");
        }
    } else {
        r.usable_depth = .warn;
        appendRec(&r, "coverage metadata missing; cannot assess depth");
    }

    // ── Signal 4: break_count ──
    if (!input.artifact_exists) {
        r.break_count = .skip;
    } else if (input.break_count) |bc| {
        r.break_value = bc;
        if (bc == 0) {
            r.break_count = .ok;
        } else {
            r.break_count = .crit;
            appendRec(&r, "fragment ancestry break detected; reseal required");
        }
    } else {
        r.break_count = .warn;
        appendRec(&r, "coverage metadata missing; cannot assess breaks");
    }

    // ── Signal 5: follower_tip_age ──
    if (!input.cursor_present) {
        r.follower_tip_age = .crit;
        appendRec(&r, "cursor.json missing; follower may not be running");
    } else if (input.cursor_updated_unix) |updated| {
        const age = input.now - updated;
        r.tip_age_secs = age;
        if (age <= TIP_AGE_OK) {
            r.follower_tip_age = .ok;
        } else if (age <= TIP_AGE_WARN) {
            r.follower_tip_age = .warn;
        } else {
            r.follower_tip_age = .crit;
            appendRec(&r, "follower tip stale; chain may be disconnected");
        }
    } else {
        r.follower_tip_age = .crit;
        appendRec(&r, "cursor has no update timestamp");
    }

    // ── Signal 6: tip_artifact_gap ──
    if (!input.artifact_exists) {
        r.tip_artifact_gap = .skip;
    } else if (input.cursor_slot != null and input.newest_slot != null) {
        const tip: i64 = @intCast(input.cursor_slot.?);
        const newest: i64 = @intCast(input.newest_slot.?);
        const gap = tip - newest;
        r.gap_slots = gap;
        if (gap <= GAP_OK) {
            r.tip_artifact_gap = .ok;
        } else if (gap <= GAP_WARN) {
            r.tip_artifact_gap = .warn;
            appendRec(&r, "tip ahead of artifact; propagation confidence reduced");
        } else {
            r.tip_artifact_gap = .crit;
            appendRec(&r, "tip far ahead of artifact; reseal recommended");
        }
    } else {
        r.tip_artifact_gap = .warn;
        appendRec(&r, "cannot compute tip-artifact gap");
    }

    // ── Signal 7: coverage_metadata ──
    if (!input.artifact_exists) {
        r.coverage_metadata = .skip;
    } else if (input.coverage_present) {
        r.coverage_metadata = .ok;
    } else {
        r.coverage_metadata = .warn;
        appendRec(&r, "coverage metadata missing; regenerate artifact");
    }

    // ── Overall verdict ──
    r.overall = worstNonSkip(&r);

    return r;
}

fn appendRec(r: *Report, rec: []const u8) void {
    if (r.rec_count < MAX_RECS) {
        r.recs[r.rec_count] = rec;
        r.rec_count += 1;
    }
}

fn worstNonSkip(r: *const Report) Verdict {
    const signals = [_]Verdict{
        r.artifact_present,
        r.artifact_age,
        r.usable_depth,
        r.break_count,
        r.follower_tip_age,
        r.tip_artifact_gap,
        r.coverage_metadata,
    };
    var worst: Verdict = .ok;
    for (signals) |s| {
        if (s == .skip) continue;
        if (@intFromEnum(s) > @intFromEnum(worst)) {
            worst = s;
        }
    }
    return worst;
}

// ── Tests ──────────────────────────────────────────────────────────

fn healthyInput() Input {
    return .{
        .cursor_present = true,
        .cursor_slot = 1000,
        .cursor_updated_unix = 99990,
        .artifact_exists = true,
        .artifact_unix = 99900,
        .coverage_present = true,
        .usable_depth = 2160,
        .break_count = 0,
        .newest_slot = 990,
        .oldest_slot = 100,
        .now = 100000,
    };
}

test "all signals OK" {
    const r = evaluate(healthyInput());
    try std.testing.expectEqual(Verdict.ok, r.artifact_present);
    try std.testing.expectEqual(Verdict.ok, r.artifact_age);
    try std.testing.expectEqual(Verdict.ok, r.usable_depth);
    try std.testing.expectEqual(Verdict.ok, r.break_count);
    try std.testing.expectEqual(Verdict.ok, r.follower_tip_age);
    try std.testing.expectEqual(Verdict.ok, r.tip_artifact_gap);
    try std.testing.expectEqual(Verdict.ok, r.coverage_metadata);
    try std.testing.expectEqual(Verdict.ok, r.overall);
    try std.testing.expectEqual(@as(usize, 0), r.rec_count);
}

test "artifact missing produces CRIT with artifact-dependent skips" {
    var input = healthyInput();
    input.artifact_exists = false;
    input.artifact_unix = null;
    input.coverage_present = false;
    input.usable_depth = null;
    input.break_count = null;
    input.newest_slot = null;
    input.oldest_slot = null;

    const r = evaluate(input);
    try std.testing.expectEqual(Verdict.crit, r.artifact_present);
    try std.testing.expectEqual(Verdict.skip, r.artifact_age);
    try std.testing.expectEqual(Verdict.skip, r.usable_depth);
    try std.testing.expectEqual(Verdict.skip, r.break_count);
    try std.testing.expectEqual(Verdict.ok, r.follower_tip_age);
    try std.testing.expectEqual(Verdict.skip, r.tip_artifact_gap);
    try std.testing.expectEqual(Verdict.skip, r.coverage_metadata);
    try std.testing.expectEqual(Verdict.crit, r.overall);
}

test "break_count > 0 produces CRIT" {
    var input = healthyInput();
    input.break_count = 2;

    const r = evaluate(input);
    try std.testing.expectEqual(Verdict.crit, r.break_count);
    try std.testing.expectEqual(@as(?u64, 2), r.break_value);
    try std.testing.expectEqual(Verdict.crit, r.overall);
    try std.testing.expect(r.rec_count > 0);
}

test "stale artifact produces CRIT" {
    var input = healthyInput();
    input.artifact_unix = 97000; // 3000s ago > 1800

    const r = evaluate(input);
    try std.testing.expectEqual(Verdict.crit, r.artifact_age);
    try std.testing.expectEqual(@as(?i64, 3000), r.artifact_age_secs);
}

test "aging artifact produces WARN" {
    var input = healthyInput();
    input.artifact_unix = 99000; // 1000s, between 300 and 1800

    const r = evaluate(input);
    try std.testing.expectEqual(Verdict.warn, r.artifact_age);
    try std.testing.expectEqual(Verdict.warn, r.overall);
}

test "low depth produces WARN" {
    var input = healthyInput();
    input.usable_depth = 50;

    const r = evaluate(input);
    try std.testing.expectEqual(Verdict.warn, r.usable_depth);
    try std.testing.expectEqual(@as(?u64, 50), r.depth_value);
}

test "very low depth produces CRIT" {
    var input = healthyInput();
    input.usable_depth = 5;

    const r = evaluate(input);
    try std.testing.expectEqual(Verdict.crit, r.usable_depth);
}

test "large tip-artifact gap produces CRIT" {
    var input = healthyInput();
    input.cursor_slot = 1500; // gap = 1500 - 990 = 510 > 300

    const r = evaluate(input);
    try std.testing.expectEqual(Verdict.crit, r.tip_artifact_gap);
    try std.testing.expectEqual(@as(?i64, 510), r.gap_slots);
}

test "moderate tip-artifact gap produces WARN" {
    var input = healthyInput();
    input.cursor_slot = 1100; // gap = 1100 - 990 = 110

    const r = evaluate(input);
    try std.testing.expectEqual(Verdict.warn, r.tip_artifact_gap);
    try std.testing.expectEqual(@as(?i64, 110), r.gap_slots);
}

test "missing coverage with artifact produces WARN" {
    var input = healthyInput();
    input.coverage_present = false;
    input.usable_depth = null;
    input.break_count = null;
    input.newest_slot = null;
    input.oldest_slot = null;

    const r = evaluate(input);
    try std.testing.expectEqual(Verdict.warn, r.usable_depth);
    try std.testing.expectEqual(Verdict.warn, r.break_count);
    try std.testing.expectEqual(Verdict.warn, r.tip_artifact_gap);
    try std.testing.expectEqual(Verdict.warn, r.coverage_metadata);
    try std.testing.expectEqual(Verdict.warn, r.overall);
}

test "cursor missing produces CRIT for follower_tip_age" {
    var input = healthyInput();
    input.cursor_present = false;
    input.cursor_slot = null;
    input.cursor_updated_unix = null;

    const r = evaluate(input);
    try std.testing.expectEqual(Verdict.crit, r.follower_tip_age);
    try std.testing.expectEqual(Verdict.warn, r.tip_artifact_gap);
}

test "follower tip stale produces CRIT" {
    var input = healthyInput();
    input.cursor_updated_unix = 99000; // 1000s > 600

    const r = evaluate(input);
    try std.testing.expectEqual(Verdict.crit, r.follower_tip_age);
}

test "follower tip warm produces WARN" {
    var input = healthyInput();
    input.cursor_updated_unix = 99700; // 300s, between 120 and 600

    const r = evaluate(input);
    try std.testing.expectEqual(Verdict.warn, r.follower_tip_age);
}
