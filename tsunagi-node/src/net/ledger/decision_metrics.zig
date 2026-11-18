// ---------------------------------------------------------------------------
// Phase 48: BAeY / EV / Kelly / LLR Decision Metrics (Observe-Only)
// Derives explicit decision-theoretic metrics from current evidence counts.
// Transparent, deterministic, local. No adaptive behavior, no policy mutation.
//
// These are first-step observe-only metrics, not a full adaptive decision
// system. BAeY / EV / Kelly / LLR are computed and emitted but do not
// influence forge, ordering, enforcement, or mempool behavior.
// ---------------------------------------------------------------------------

const std = @import("std");
const compat = @import("compat");
const trust_score = @import("trust_score.zig");

/// Decision metrics derived from evidence counts.
/// All scaled outputs use x1e6 (millionths) for integer-safe fixed-point.
pub const DecisionMetrics = struct {
    // Evidence inputs (carried forward for transparency)
    positive: u64 = 0,
    negative: u64 = 0,
    neutral: u64 = 0,

    // BAeY-compatible Beta posterior parameters
    // alpha = 1 + positive (prior: Beta(1,1) = uniform)
    // beta_ = 1 + negative
    alpha: u64 = 1,
    beta_: u64 = 1, // named beta_ to avoid shadowing keyword

    // Posterior mean = alpha / (alpha + beta_), scaled x1e6
    posterior_mean_x1e6: u64 = 500000,

    // Even-odds EV = 2 * posterior_mean - 1, scaled x1e6
    // Range: -1e6 to +1e6. Positive means net positive expectation.
    ev_x1e6: i64 = 0,

    // Even-odds Kelly fraction = clamp(ev, 0, 1e6), scaled x1e6
    // Represents the fraction of available action a Kelly criterion would allocate.
    kelly_x1e6: u64 = 0,

    // Log-likelihood ratio = ln(alpha / beta_), scaled x1e6
    // Positive means evidence favors positive outcomes.
    // Zero when alpha == beta_. Undefined (set to 0) when beta_ == 0.
    llr_x1e6: i64 = 0,

    /// Emit a stable, grep-friendly summary line.
    pub fn emitSummary(self: *const DecisionMetrics, w: anytype) void {
        w.print("DECISION_METRICS: positive={d} negative={d} neutral={d} alpha={d} beta={d} posterior_x1e6={d} ev_x1e6={d} kelly_x1e6={d} llr_x1e6={d}\n", .{
            self.positive,
            self.negative,
            self.neutral,
            self.alpha,
            self.beta_,
            self.posterior_mean_x1e6,
            self.ev_x1e6,
            self.kelly_x1e6,
            self.llr_x1e6,
        }) catch {};
    }
};

/// Build decision metrics from a trust score summary.
/// Pure function — no side effects, no allocation.
///
/// Formulas:
///   alpha = 1 + positive
///   beta_ = 1 + negative
///   posterior_mean = alpha / (alpha + beta_)
///   ev = 2 * posterior_mean - 1   (even-odds)
///   kelly = clamp(ev, 0, 1)       (even-odds)
///   llr = ln(alpha / beta_)
///
/// All scaled to x1e6 for integer arithmetic.
pub fn buildMetrics(score: *const trust_score.TrustScoreSummary) DecisionMetrics {
    const alpha: u64 = 1 + score.positive;
    const beta_: u64 = 1 + score.negative;
    const total: u64 = alpha + beta_;

    // Posterior mean x1e6 = (alpha * 1e6) / total
    const posterior_mean_x1e6: u64 = if (total > 0)
        (alpha * 1_000_000) / total
    else
        500_000;

    // EV x1e6 = 2 * posterior - 1e6
    const ev_x1e6: i64 = 2 * @as(i64, @intCast(posterior_mean_x1e6)) - 1_000_000;

    // Kelly x1e6 = clamp(ev, 0, 1e6)
    const kelly_x1e6: u64 = if (ev_x1e6 > 0)
        @intCast(@min(ev_x1e6, 1_000_000))
    else
        0;

    // LLR x1e6 = round(1e6 * ln(alpha / beta_))
    // Using integer approximation: ln(a/b) ≈ (a - b) / ((a + b) / 2) for a/b near 1
    // More accurate: use @log from std.math on f64 then scale back
    const llr_x1e6: i64 = blk: {
        if (alpha == 0 or beta_ == 0) break :blk 0;
        const ratio: f64 = @as(f64, @floatFromInt(alpha)) / @as(f64, @floatFromInt(beta_));
        const ln_ratio: f64 = @log(ratio);
        const scaled: i64 = @intFromFloat(@round(ln_ratio * 1_000_000.0));
        break :blk scaled;
    };

    return .{
        .positive = score.positive,
        .negative = score.negative,
        .neutral = score.neutral,
        .alpha = alpha,
        .beta_ = beta_,
        .posterior_mean_x1e6 = posterior_mean_x1e6,
        .ev_x1e6 = ev_x1e6,
        .kelly_x1e6 = kelly_x1e6,
        .llr_x1e6 = llr_x1e6,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "buildMetrics: balanced evidence" {
    const score = trust_score.TrustScoreSummary{ .positive = 10, .negative = 10, .neutral = 5, .score = 0 };
    const m = buildMetrics(&score);

    try std.testing.expectEqual(@as(u64, 11), m.alpha); // 1 + 10
    try std.testing.expectEqual(@as(u64, 11), m.beta_); // 1 + 10
    try std.testing.expectEqual(@as(u64, 500000), m.posterior_mean_x1e6); // 50%
    try std.testing.expectEqual(@as(i64, 0), m.ev_x1e6); // breakeven
    try std.testing.expectEqual(@as(u64, 0), m.kelly_x1e6); // no edge
    try std.testing.expectEqual(@as(i64, 0), m.llr_x1e6); // neutral
}

test "buildMetrics: positive-heavy evidence" {
    const score = trust_score.TrustScoreSummary{ .positive = 20, .negative = 2, .neutral = 3, .score = 18 };
    const m = buildMetrics(&score);

    try std.testing.expectEqual(@as(u64, 21), m.alpha);
    try std.testing.expectEqual(@as(u64, 3), m.beta_);
    // posterior = 21/24 = 0.875 → 875000
    try std.testing.expectEqual(@as(u64, 875000), m.posterior_mean_x1e6);
    // ev = 2*875000 - 1000000 = 750000
    try std.testing.expectEqual(@as(i64, 750000), m.ev_x1e6);
    // kelly = 750000
    try std.testing.expectEqual(@as(u64, 750000), m.kelly_x1e6);
    // llr = ln(21/3) = ln(7) ≈ 1.9459 → 1945910
    try std.testing.expect(m.llr_x1e6 > 1_900_000 and m.llr_x1e6 < 2_000_000);
}

test "buildMetrics: negative-heavy evidence" {
    const score = trust_score.TrustScoreSummary{ .positive = 1, .negative = 9, .neutral = 0, .score = -8 };
    const m = buildMetrics(&score);

    try std.testing.expectEqual(@as(u64, 2), m.alpha);
    try std.testing.expectEqual(@as(u64, 10), m.beta_);
    // posterior = 2/12 = 0.1667 → 166666
    try std.testing.expectEqual(@as(u64, 166666), m.posterior_mean_x1e6);
    // ev = 2*166666 - 1000000 = -666668
    try std.testing.expectEqual(@as(i64, -666668), m.ev_x1e6);
    // kelly = 0 (ev negative)
    try std.testing.expectEqual(@as(u64, 0), m.kelly_x1e6);
    // llr = ln(2/10) = ln(0.2) ≈ -1.6094 → -1609438
    try std.testing.expect(m.llr_x1e6 < -1_600_000 and m.llr_x1e6 > -1_700_000);
}

test "buildMetrics: zero evidence (prior only)" {
    const score = trust_score.TrustScoreSummary{};
    const m = buildMetrics(&score);

    try std.testing.expectEqual(@as(u64, 1), m.alpha);
    try std.testing.expectEqual(@as(u64, 1), m.beta_);
    try std.testing.expectEqual(@as(u64, 500000), m.posterior_mean_x1e6);
    try std.testing.expectEqual(@as(i64, 0), m.ev_x1e6);
    try std.testing.expectEqual(@as(u64, 0), m.kelly_x1e6);
    try std.testing.expectEqual(@as(i64, 0), m.llr_x1e6);
}

test "buildMetrics: idempotent" {
    const score = trust_score.TrustScoreSummary{ .positive = 5, .negative = 3, .neutral = 2, .score = 2 };
    const a = buildMetrics(&score);
    const b = buildMetrics(&score);
    try std.testing.expectEqual(a.alpha, b.alpha);
    try std.testing.expectEqual(a.beta_, b.beta_);
    try std.testing.expectEqual(a.posterior_mean_x1e6, b.posterior_mean_x1e6);
    try std.testing.expectEqual(a.ev_x1e6, b.ev_x1e6);
    try std.testing.expectEqual(a.kelly_x1e6, b.kelly_x1e6);
    try std.testing.expectEqual(a.llr_x1e6, b.llr_x1e6);
}

test "emitSummary: stable format" {
    const m = DecisionMetrics{
        .positive = 10,
        .negative = 3,
        .neutral = 2,
        .alpha = 11,
        .beta_ = 4,
        .posterior_mean_x1e6 = 733333,
        .ev_x1e6 = 466666,
        .kelly_x1e6 = 466666,
        .llr_x1e6 = 1011600,
    };
    var buf: [256]u8 = undefined;
    var stream = compat.fixedBufferStream(&buf);
    m.emitSummary(stream.writer());
    const output = buf[0..stream.pos];
    const expected = "DECISION_METRICS: positive=10 negative=3 neutral=2 alpha=11 beta=4 posterior_x1e6=733333 ev_x1e6=466666 kelly_x1e6=466666 llr_x1e6=1011600\n";
    try std.testing.expectEqualSlices(u8, expected, output);
}
