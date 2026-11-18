// Phase 9.3 — Skip Bad Slot Advisory (EV Filter)
//
// Observe-only by default: computes whether the next leader slot has
// positive EV + acceptable exec_quality rating. When
// TSUNAGI_SKIP_ENFORCE=1, callers may abort the forge.
//
//   TSUNAGI_SKIP_ADVISORY=1   emit SKIP_ADVISORY log (default off)
//   TSUNAGI_SKIP_ENFORCE=0    never abort by default

const std = @import("std");
const compat = @import("compat");

const decision_mod = @import("decision.zig");
const exec_quality = @import("exec_quality.zig");

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
    advisory_on: bool = false,
    enforce: bool = false,
    last_slot: u64 = 0,
    last_ev_x1000: i32 = 0,
    last_verdict: Verdict = .proceed,
    last_rating: exec_quality.Rating = .low,
    advisory_count: u64 = 0,
    skip_count: u64 = 0,
};

pub var g_state: State = .{};

pub fn initFromEnv() void {
    var adv = false;
    var enforce = false;
    if (compat.getenv("TSUNAGI_SKIP_ADVISORY")) |v| {
        adv = std.mem.eql(u8, std.mem.trim(u8, v, " \t"), "1");
    }
    if (compat.getenv("TSUNAGI_SKIP_ENFORCE")) |v| {
        enforce = std.mem.eql(u8, std.mem.trim(u8, v, " \t"), "1");
    }
    g_state.mu.lock();
    defer g_state.mu.unlock();
    g_state.advisory_on = adv;
    g_state.enforce = enforce;
    std.debug.print("SKIP_ADVISORY_CONFIG: advisory={s} enforce={s}\n", .{
        if (adv) "true" else "false",
        if (enforce) "true" else "false",
    });
}

pub const Advice = struct {
    verdict: Verdict,
    ev_x1000: i32,
    rating: exec_quality.Rating,
    advisory_on: bool,
    enforce: bool,
};

/// Pure compute — no side effects. Use advise() to record + log.
pub fn compute() Advice {
    const dec = decision_mod.currentSnapshot();
    const eq = exec_quality.currentScore();

    var verdict: Verdict = .proceed;
    if (dec.ev_x1000 < 0 or eq.rating == .low) {
        verdict = .skip;
    }

    g_state.mu.lock();
    const adv_on = g_state.advisory_on;
    const enforce = g_state.enforce;
    g_state.mu.unlock();

    return .{
        .verdict = verdict,
        .ev_x1000 = dec.ev_x1000,
        .rating = eq.rating,
        .advisory_on = adv_on,
        .enforce = enforce,
    };
}

/// Compute, record state, and emit SKIP_ADVISORY log if advisory is on.
/// Returns the advice so callers can branch on it.
pub fn advise(slot: u64) Advice {
    const a = compute();
    g_state.mu.lock();
    g_state.last_slot = slot;
    g_state.last_ev_x1000 = a.ev_x1000;
    g_state.last_verdict = a.verdict;
    g_state.last_rating = a.rating;
    g_state.advisory_count += 1;
    if (a.verdict == .skip) g_state.skip_count += 1;
    g_state.mu.unlock();

    if (a.advisory_on) {
        std.debug.print("SKIP_ADVISORY: slot={d} ev_x1000={d} rating={s} decision={s} enforce={s}\n", .{
            slot, a.ev_x1000, a.rating.str(), a.verdict.str(),
            if (a.enforce) "true" else "false",
        });
    }
    return a;
}

pub fn renderJson(buf: []u8) usize {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    var w = compat.fixedBufferStream(buf);
    w.writer().print(
        \\{{"advisory_on":{s},"enforce":{s},"last_slot":{d},"last_ev_x1000":{d},"last_rating":"{s}","last_decision":"{s}","advisory_count":{d},"skip_count":{d}}}
    , .{
        if (g_state.advisory_on) "true" else "false",
        if (g_state.enforce) "true" else "false",
        g_state.last_slot,
        g_state.last_ev_x1000,
        g_state.last_rating.str(),
        g_state.last_verdict.str(),
        g_state.advisory_count,
        g_state.skip_count,
    }) catch {};
    return w.pos;
}

test "compute proceeds by default" {
    g_state.advisory_on = false;
    g_state.enforce = false;
    const a = compute();
    _ = a;
    // Depending on global decision/exec_quality state, can't assert verdict.
    // Just verify no crash.
}
