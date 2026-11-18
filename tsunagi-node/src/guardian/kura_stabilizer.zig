const std = @import("std");

// ── KURA 蔵 — Stabilization Evaluator ──────────────────────────────
//
// Pure evaluation module that determines whether the propagation
// artifact should be resealed. No file I/O, no protocol imports,
// no side effects.
//
// Decision rules:
//   break_count > 0           → reseal_urgent
//   artifact_age_seconds > 1800 → reseal
//   tip_artifact_gap_slots > 300  → reseal
//   usable_depth < 100          → reseal
//   otherwise                   → none

pub const StabilizeAction = enum {
    none,
    reseal,
    reseal_urgent,
};

pub const Input = struct {
    artifact_age_seconds: u64,
    tip_artifact_gap_slots: u64,
    usable_depth: u64,
    break_count: u64,
};

// Thresholds
pub const AGE_RESEAL: u64 = 1800;
pub const GAP_RESEAL: u64 = 300;
pub const DEPTH_RESEAL: u64 = 100;

pub fn evaluate(input: Input) StabilizeAction {
    // Urgent takes priority
    if (input.break_count > 0) return .reseal_urgent;

    // Any stale/degraded signal triggers reseal
    if (input.artifact_age_seconds > AGE_RESEAL) return .reseal;
    if (input.tip_artifact_gap_slots > GAP_RESEAL) return .reseal;
    if (input.usable_depth < DEPTH_RESEAL) return .reseal;

    return .none;
}

// ── Tests ──────────────────────────────────────────────────────────

test "healthy state returns none" {
    const result = evaluate(.{
        .artifact_age_seconds = 120,
        .tip_artifact_gap_slots = 30,
        .usable_depth = 2160,
        .break_count = 0,
    });
    try std.testing.expectEqual(StabilizeAction.none, result);
}

test "stale artifact triggers reseal" {
    const result = evaluate(.{
        .artifact_age_seconds = 2400,
        .tip_artifact_gap_slots = 30,
        .usable_depth = 2160,
        .break_count = 0,
    });
    try std.testing.expectEqual(StabilizeAction.reseal, result);
}

test "large gap triggers reseal" {
    const result = evaluate(.{
        .artifact_age_seconds = 120,
        .tip_artifact_gap_slots = 500,
        .usable_depth = 2160,
        .break_count = 0,
    });
    try std.testing.expectEqual(StabilizeAction.reseal, result);
}

test "low depth triggers reseal" {
    const result = evaluate(.{
        .artifact_age_seconds = 120,
        .tip_artifact_gap_slots = 30,
        .usable_depth = 50,
        .break_count = 0,
    });
    try std.testing.expectEqual(StabilizeAction.reseal, result);
}

test "ancestry break triggers reseal_urgent" {
    const result = evaluate(.{
        .artifact_age_seconds = 120,
        .tip_artifact_gap_slots = 30,
        .usable_depth = 2160,
        .break_count = 2,
    });
    try std.testing.expectEqual(StabilizeAction.reseal_urgent, result);
}

test "break_count takes priority over stale" {
    const result = evaluate(.{
        .artifact_age_seconds = 2400,
        .tip_artifact_gap_slots = 500,
        .usable_depth = 50,
        .break_count = 1,
    });
    try std.testing.expectEqual(StabilizeAction.reseal_urgent, result);
}

test "boundary: exact threshold values" {
    // At boundary — not exceeded
    try std.testing.expectEqual(StabilizeAction.none, evaluate(.{
        .artifact_age_seconds = 1800,
        .tip_artifact_gap_slots = 300,
        .usable_depth = 100,
        .break_count = 0,
    }));

    // Just past boundary
    try std.testing.expectEqual(StabilizeAction.reseal, evaluate(.{
        .artifact_age_seconds = 1801,
        .tip_artifact_gap_slots = 300,
        .usable_depth = 100,
        .break_count = 0,
    }));
}
