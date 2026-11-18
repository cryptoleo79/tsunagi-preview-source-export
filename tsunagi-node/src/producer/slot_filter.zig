// Phase 10.3 — Slot Quality Filter (controlled gating)
//
// Scores a leader slot from composite runtime signals and recommends
// "proceed" / "skip". Observe-only by default (TSUNAGI_SLOT_FILTER=1);
// enforcement requires the explicit opt-in TSUNAGI_SLOT_FILTER_ENFORCE=1
// which lets the producer abort the forge.
//
// Rules (each worth +1 except rating HIGH = +2):
//   rating == HIGH              +2
//   ev_x1000 > 0                +1
//   p50_notice_ms < 150         +1
//   signal confidence > 0.6     +1
//
// quality_score <= 1 → skip;  >= 2 → proceed.

const std = @import("std");
const compat = @import("compat");

const decision_mod = @import("decision.zig");
const exec_quality = @import("exec_quality.zig");
const presence = @import("presence.zig");
const signals_mod = @import("signals.zig");

pub const Verdict = enum(u8) {
    proceed = 0,
    skip = 1,

    pub fn str(self: Verdict) []const u8 {
        return switch (self) {
            .proceed => "proceed",
            .skip => "skip",
        };
    }
};

pub const State = struct {
    mu: compat.Mutex = .{},
    enabled: bool = false,
    enforce: bool = false,
    last_slot: u64 = 0,
    last_score: u8 = 0,
    last_verdict: Verdict = .proceed,
    last_rating: exec_quality.Rating = .low,
    last_ev_x1000: i32 = 0,
    last_p50_notice_ms: u32 = 0,
    last_confidence_x1000: u32 = 0,
    filters_total: u64 = 0,
    skips_total: u64 = 0,
    enforced_total: u64 = 0,
};

pub var g_state: State = .{};

pub fn initFromEnv() void {
    var enabled = true; // default ON (observe-only)
    var enforce = false;
    if (compat.getenv("TSUNAGI_SLOT_FILTER")) |v| {
        enabled = std.mem.eql(u8, std.mem.trim(u8, v, " \t"), "1");
    }
    if (compat.getenv("TSUNAGI_SLOT_FILTER_ENFORCE")) |v| {
        enforce = std.mem.eql(u8, std.mem.trim(u8, v, " \t"), "1");
    }
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.enabled = enabled;
    g_state.enforce = enforce;
    std.debug.print("SLOT_FILTER_CONFIG: enabled={s} enforce={s}\n", .{
        if (enabled) "true" else "false",
        if (enforce) "true" else "false",
    });
}

pub const Advice = struct {
    verdict: Verdict,
    score: u8,
    rating: exec_quality.Rating,
    ev_x1000: i32,
    p50_notice_ms: u32,
    confidence_x1000: u32,
    enabled: bool,
    enforce: bool,
};

/// Pure compute, no side effects. `advise()` wraps this with logging +
/// counters for the producer hook.
pub fn compute() Advice {
    const eq = exec_quality.currentScore();
    const dec = decision_mod.currentSnapshot();
    const sigs = signals_mod.currentSignals();
    var conf_sum: f64 = 0.0;
    for (sigs) |s| conf_sum += s.confidence;
    const conf: f64 = conf_sum / 6.0;
    const conf_x1000: u32 = @intFromFloat(@round(conf * 1000.0));

    presence.g_state.mu.lock();
    const p50 = presence.g_state.p50_notice_ms;
    presence.g_state.mu.unlock();

    var score: u8 = 0;
    if (eq.rating == .high) score += 2;
    if (dec.ev_x1000 > 0) score += 1;
    if (p50 > 0 and p50 < 150) score += 1;
    if (conf > 0.6) score += 1;

    const verdict: Verdict = if (score <= 1) .skip else .proceed;

    g_state.mu.lock();
    const enabled = g_state.enabled;
    const enforce = g_state.enforce;
    g_state.mu.unlock();

    return .{
        .verdict = verdict,
        .score = score,
        .rating = eq.rating,
        .ev_x1000 = dec.ev_x1000,
        .p50_notice_ms = p50,
        .confidence_x1000 = conf_x1000,
        .enabled = enabled,
        .enforce = enforce,
    };
}

/// Compute + record + log. Returns the advice so the caller can branch.
pub fn advise(slot: u64) Advice {
    const a = compute();
    g_state.mu.lock();
    g_state.last_slot = slot;
    g_state.last_score = a.score;
    g_state.last_verdict = a.verdict;
    g_state.last_rating = a.rating;
    g_state.last_ev_x1000 = a.ev_x1000;
    g_state.last_p50_notice_ms = a.p50_notice_ms;
    g_state.last_confidence_x1000 = a.confidence_x1000;
    g_state.filters_total += 1;
    if (a.verdict == .skip) g_state.skips_total += 1;
    g_state.mu.unlock();

    if (a.enabled) {
        std.debug.print("SLOT_FILTER: slot={d} score={d} decision={s} rating={s} ev_x1000={d} p50_notice_ms={d} conf_x1000={d} enforce={s}\n", .{
            slot, a.score, a.verdict.str(), a.rating.str(),
            a.ev_x1000, a.p50_notice_ms, a.confidence_x1000,
            if (a.enforce) "true" else "false",
        });
    }
    return a;
}

pub fn markEnforced() void {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.enforced_total += 1;
}

pub fn renderJson(buf: []u8) usize {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    var w = compat.fixedBufferStream(buf);
    w.writer().print(
        "{{\"enabled\":{s},\"enforce\":{s},\"last_slot\":{d},\"last_score\":{d},\"last_decision\":\"{s}\",\"last_rating\":\"{s}\",\"last_ev_x1000\":{d},\"last_p50_notice_ms\":{d},\"last_confidence_x1000\":{d},\"filters_total\":{d},\"skips_total\":{d},\"enforced_total\":{d}}}",
        .{
            if (g_state.enabled) "true" else "false",
            if (g_state.enforce) "true" else "false",
            g_state.last_slot,
            g_state.last_score,
            g_state.last_verdict.str(),
            g_state.last_rating.str(),
            g_state.last_ev_x1000,
            g_state.last_p50_notice_ms,
            g_state.last_confidence_x1000,
            g_state.filters_total,
            g_state.skips_total,
            g_state.enforced_total,
        },
    ) catch {};
    return w.pos;
}
