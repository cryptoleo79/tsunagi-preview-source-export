const std = @import("std");
const compat = @import("compat");
const producer = @import("../producer/producer.zig");

/// Praos exact threshold equivalence harness (verification-only).
///
/// 3-way comparison per vector:
///   A) tsunagi_threshold_x1e12 — existing Tsunagi function (unchanged)
///   B) exact_reference_threshold_x1e12 — continuous formula: T = -expm1(σ * log1p(-f))
///   C) expected_threshold_x1e12 — precomputed vectors from cardano-node (when available)
///
/// CRITICAL ORACLE RULE:
///   PASS/FAIL is determined ONLY by tsunagi vs expected.
///   exact_reference is DIAGNOSTIC ONLY — never used as oracle.
///   If expected is null → SKIP_EXPECTED_NULL (not a failure).
///
/// NO runtime changes. NO forging. NO broadcast.
///
/// Exit codes: 0=no mismatches, 2=mismatch found, 3=parse/file/IO error

pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    _ = alloc;
    var vectors_path: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--vectors")) {
            vectors_path = args_it.next() orelse {
                std.debug.print("ERROR: --vectors requires a path\n", .{});
                return 3;
            };
        }
    }

    std.debug.print("=== Praos Exact Threshold Equivalence ===\n\n", .{});

    if (vectors_path) |path| {
        return runFromFile(path);
    } else {
        return runSelfTest();
    }
}

// ── Summary statistics ────────────────────────────────────────────────

const Summary = struct {
    total: usize,
    mismatches: usize,
    skipped: usize,
    max_abs_delta_expected: u64,
    max_rel_delta_expected_ppm: u64,
    max_abs_delta_exact: u64,
    max_rel_delta_exact_ppm: u64,
};

fn initSummary() Summary {
    return .{
        .total = 0,
        .mismatches = 0,
        .skipped = 0,
        .max_abs_delta_expected = 0,
        .max_rel_delta_expected_ppm = 0,
        .max_abs_delta_exact = 0,
        .max_rel_delta_exact_ppm = 0,
    };
}

fn printSummary(s: Summary) void {
    const exit_code: u8 = if (s.mismatches > 0) 2 else 0;
    std.debug.print("\nvectors={d} mismatches={d} skipped={d}\n", .{ s.total, s.mismatches, s.skipped });
    std.debug.print("max_abs_delta_expected={d}\n", .{s.max_abs_delta_expected});
    std.debug.print("max_rel_delta_expected_ppm={d}\n", .{s.max_rel_delta_expected_ppm});
    std.debug.print("max_abs_delta_exact={d}\n", .{s.max_abs_delta_exact});
    std.debug.print("max_rel_delta_exact_ppm={d}\n", .{s.max_rel_delta_exact_ppm});
    std.debug.print("EXIT={d}\n", .{exit_code});
}

// ── File mode ─────────────────────────────────────────────────────────

fn runFromFile(path: []const u8) u8 {
    var file = compat.fs.cwd().openFile(path, .{}) catch {
        std.debug.print("ERROR: cannot open {s}\n", .{path});
        return 3;
    };
    defer file.close();

    var summary = initSummary();
    var line_buf: [4096]u8 = undefined;
    const buf_reader = file.deprecatedReader();
    var reader = buf_reader;

    while (true) {
        const line = reader.readUntilDelimiterOrEof(&line_buf, '\n') catch {
            std.debug.print("ERROR: read error at line {d}\n", .{summary.total + 1});
            return 3;
        };
        if (line == null) break;
        const content = line.?;
        if (content.len == 0) continue;

        const vec = parseVector(content) orelse {
            std.debug.print("ERROR: cannot parse vector at line {d}\n", .{summary.total + 1});
            return 3;
        };

        evaluateVector(vec, summary.total, &summary);
        summary.total += 1;
    }

    if (summary.total == 0) {
        std.debug.print("ERROR: no vectors found in {s}\n", .{path});
        return 3;
    }

    printSummary(summary);
    return if (summary.mismatches > 0) 2 else 0;
}

// ── Self-test mode (embedded sanity vectors, NOT equivalence proof) ───

fn runSelfTest() u8 {
    std.debug.print("  mode: self-test (no --vectors file)\n", .{});
    std.debug.print("  NOTE: self-test uses tsunagi output as expected (sanity check only)\n\n", .{});

    // Self-test vectors: expected = tsunagi's own output (not cardano-node)
    // These verify internal consistency, NOT external equivalence
    const cases = [_]RawVector{
        // Zero stake → T = 0
        .{ .stake_fraction_x1e9 = 0, .asc_x1e6 = 50000, .expected = .{ .value = 0 } },
        // Zero ASC → T = 0
        .{ .stake_fraction_x1e9 = 500_000_000, .asc_x1e6 = 0, .expected = .{ .value = 0 } },
        // 100% stake, asc=0.05 → tsunagi value
        .{ .stake_fraction_x1e9 = 1_000_000_000, .asc_x1e6 = 50000, .expected = .{ .value = producer.computeThreshX1e12(1_000_000_000, 50000) } },
        // 50% stake, asc=0.05 → tsunagi value
        .{ .stake_fraction_x1e9 = 500_000_000, .asc_x1e6 = 50000, .expected = .{ .value = producer.computeThreshX1e12(500_000_000, 50000) } },
        // Small stake (1%), asc=0.05 → tsunagi value
        .{ .stake_fraction_x1e9 = 10_000_000, .asc_x1e6 = 50000, .expected = .{ .value = producer.computeThreshX1e12(10_000_000, 50000) } },
        // null expected → SKIP_EXPECTED_NULL
        .{ .stake_fraction_x1e9 = 500_000_000, .asc_x1e6 = 50000, .expected = .{ .is_null = true } },
    };

    var summary = initSummary();
    for (cases, 0..) |raw, i| {
        const vec = ParsedVector{
            .stake_fraction_x1e9 = raw.stake_fraction_x1e9,
            .asc_x1e6 = raw.asc_x1e6,
            .expected_is_null = raw.expected.is_null,
            .expected_threshold_x1e12 = raw.expected.value,
        };
        evaluateVector(vec, i, &summary);
        summary.total += 1;
    }

    printSummary(summary);
    return if (summary.mismatches > 0) 2 else 0;
}

// Self-test helper types
const MaybeU64 = struct {
    value: u64 = 0,
    is_null: bool = false,
};
const RawVector = struct {
    stake_fraction_x1e9: u64,
    asc_x1e6: u64,
    expected: MaybeU64,
};

// ── Per-vector evaluation ─────────────────────────────────────────────

const ParsedVector = struct {
    stake_fraction_x1e9: u64,
    asc_x1e6: u64,
    expected_is_null: bool,
    expected_threshold_x1e12: u64,
};

fn evaluateVector(vec: ParsedVector, idx: usize, summary: *Summary) void {
    // A) Tsunagi: existing function (UNCHANGED)
    const tsu = producer.computeThreshX1e12(vec.stake_fraction_x1e9, vec.asc_x1e6);

    // B) Exact reference: numerically stable continuous formula (DIAGNOSTIC ONLY)
    const exact = exactReferenceThreshX1e12(vec.stake_fraction_x1e9, vec.asc_x1e6);

    // Delta vs exact (diagnostic)
    const abs_delta_exact = if (tsu >= exact) tsu - exact else exact - tsu;
    const rel_delta_exact_ppm = relDeltaPpm(tsu, exact);

    // Track exact diagnostics
    if (abs_delta_exact > summary.max_abs_delta_exact)
        summary.max_abs_delta_exact = abs_delta_exact;
    if (rel_delta_exact_ppm > summary.max_rel_delta_exact_ppm)
        summary.max_rel_delta_exact_ppm = rel_delta_exact_ppm;

    // C) Expected: from vector (oracle)
    if (vec.expected_is_null) {
        // SKIP_EXPECTED_NULL — no oracle, no PASS/FAIL
        summary.skipped += 1;
        std.debug.print("idx={d} stake_x1e9={d} asc_x1e6={d} tsu_x1e12={d} exact_x1e12={d} expected_x1e12=NULL status=SKIP_EXPECTED_NULL abs_delta_expected=0 rel_delta_expected_ppm=0 abs_delta_exact={d} rel_delta_exact_ppm={d}\n", .{
            idx, vec.stake_fraction_x1e9, vec.asc_x1e6,
            tsu, exact,
            abs_delta_exact, rel_delta_exact_ppm,
        });
        return;
    }

    const expected = vec.expected_threshold_x1e12;
    const abs_delta_expected = if (tsu >= expected) tsu - expected else expected - tsu;
    const rel_delta_expected_ppm = relDeltaPpm(tsu, expected);
    const match = (tsu == expected);

    // Track expected deltas
    if (abs_delta_expected > summary.max_abs_delta_expected)
        summary.max_abs_delta_expected = abs_delta_expected;
    if (rel_delta_expected_ppm > summary.max_rel_delta_expected_ppm)
        summary.max_rel_delta_expected_ppm = rel_delta_expected_ppm;

    if (!match) summary.mismatches += 1;

    const status_str: []const u8 = if (match) "PASS" else "FAIL";

    std.debug.print("idx={d} stake_x1e9={d} asc_x1e6={d} tsu_x1e12={d} exact_x1e12={d} expected_x1e12={d} status={s} abs_delta_expected={d} rel_delta_expected_ppm={d} abs_delta_exact={d} rel_delta_exact_ppm={d}\n", .{
        idx, vec.stake_fraction_x1e9, vec.asc_x1e6,
        tsu, exact, expected, status_str,
        abs_delta_expected, rel_delta_expected_ppm,
        abs_delta_exact, rel_delta_exact_ppm,
    });
}

/// Relative delta in parts-per-million.
/// Returns 0 if both values are 0.
fn relDeltaPpm(a: u64, b: u64) u64 {
    if (a == 0 and b == 0) return 0;
    const abs_delta = if (a >= b) a - b else b - a;
    const denom = @max(a, b);
    if (denom == 0) return 0;
    // ppm = (abs_delta / denom) * 1_000_000
    return @as(u64, @intCast((@as(u128, abs_delta) * 1_000_000) / @as(u128, denom)));
}

// ── Exact reference threshold ─────────────────────────────────────────

/// Exact Praos threshold: T = -expm1(σ * log1p(-f))
///
/// Numerically stable form of T = 1 - (1 - f)^σ using f64.
/// f128 is not available for log1p/expm1 in Zig 0.13.0.
///
/// This is DIAGNOSTIC ONLY — never used as the PASS/FAIL oracle.
///
/// Rounding: nearest-even (IEEE 754 default for @round / @intFromFloat
/// after adding 0.5, but we use @round which is round-half-away-from-zero
/// in Zig). Documented as round-half-away-from-zero.
///
/// Edge cases:
///   f == 0 or σ == 0 → T = 0
///   f == 1 and σ > 0 → T = 1
fn exactReferenceThreshX1e12(stake_fraction_x1e9: u64, asc_x1e6: u64) u64 {
    if (stake_fraction_x1e9 == 0) return 0;
    if (asc_x1e6 == 0) return 0;

    const f: f64 = @as(f64, @floatFromInt(asc_x1e6)) / 1_000_000.0;
    const sigma: f64 = @as(f64, @floatFromInt(stake_fraction_x1e9)) / 1_000_000_000.0;

    // Edge case: f == 1.0 (100% active slot coefficient)
    if (f >= 1.0) {
        return 1_000_000_000_000;
    }

    // T = -expm1(σ * log1p(-f))
    // log1p(-f) = ln(1-f), numerically stable for small f
    // expm1(x) = e^x - 1, numerically stable for small x
    // T = -(e^(σ*ln(1-f)) - 1) = 1 - (1-f)^σ
    const log_term: f64 = std.math.log1p(-f);
    const exp_arg: f64 = sigma * log_term;
    const t: f64 = -std.math.expm1(exp_arg);

    if (t <= 0.0) return 0;
    if (t >= 1.0) return 1_000_000_000_000;

    // Round half-away-from-zero (Zig @round behavior)
    return @intFromFloat(@round(t * 1_000_000_000_000.0));
}

// ── JSONL parsing (supports null for expected) ────────────────────────

fn parseVector(line: []const u8) ?ParsedVector {
    const stake = parseU64Field(line, "\"stake_fraction_x1e9\":") orelse return null;
    const asc = parseU64Field(line, "\"asc_x1e6\":") orelse return null;

    // expected_threshold_x1e12 can be null or a u64
    var expected_is_null = false;
    var expected_value: u64 = 0;

    const needle = "\"expected_threshold_x1e12\":";
    if (std.mem.indexOf(u8, line, needle)) |start| {
        const val_start = start + needle.len;
        // Skip whitespace
        var pos = val_start;
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}

        if (pos + 4 <= line.len and std.mem.eql(u8, line[pos..][0..4], "null")) {
            expected_is_null = true;
        } else {
            expected_value = parseU64At(line, pos) orelse return null;
        }
    } else {
        return null;
    }

    return .{
        .stake_fraction_x1e9 = stake,
        .asc_x1e6 = asc,
        .expected_is_null = expected_is_null,
        .expected_threshold_x1e12 = expected_value,
    };
}

fn parseU64Field(json: []const u8, needle: []const u8) ?u64 {
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const val_start = start + needle.len;
    return parseU64At(json, val_start);
}

fn parseU64At(json: []const u8, start: usize) ?u64 {
    var pos = start;
    // Skip whitespace
    while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) : (pos += 1) {}
    var end = pos;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
    if (end == pos) return null;
    return std.fmt.parseInt(u64, json[pos..end], 10) catch null;
}
