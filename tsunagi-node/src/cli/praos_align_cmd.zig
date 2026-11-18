const std = @import("std");
const compat = @import("compat");
const producer = @import("../producer/producer.zig");

pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var vectors_path: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--vectors")) {
            vectors_path = args_it.next() orelse {
                std.debug.print("ERROR: --vectors requires a path\n", .{});
                return 3;
            };
        }
    }

    std.debug.print("=== TSUNAGI Praos Alignment ===\n\n", .{});

    if (vectors_path) |path| {
        return runFromFile(alloc, path);
    } else {
        return runSelfTest();
    }
}

const Vector = struct {
    stake_fraction_x1e9: u64,
    asc_x1e6: u64,
    expected_threshold_x1e12: u64,
};

fn runFromFile(_: std.mem.Allocator, path: []const u8) u8 {
    var file = compat.fs.cwd().openFile(path, .{}) catch {
        std.debug.print("ERROR: cannot open {s}\n", .{path});
        return 3;
    };
    defer file.close();

    var total: usize = 0;
    var mismatches: usize = 0;
    var max_abs_delta: u64 = 0;
    var line_buf: [4096]u8 = undefined;
    const buf_reader = file.deprecatedReader();
    var reader = buf_reader;

    while (true) {
        const line = reader.readUntilDelimiterOrEof(&line_buf, '\n') catch {
            std.debug.print("ERROR: read error at line {d}\n", .{total + 1});
            return 3;
        };
        if (line == null) break;
        const content = line.?;
        if (content.len == 0) continue;

        const vec = parseVector(content) orelse {
            std.debug.print("ERROR: cannot parse vector at line {d}\n", .{total + 1});
            return 3;
        };

        const result = evaluateVector(vec, total);
        total += 1;

        if (!result.match) {
            mismatches += 1;
        }
        if (result.abs_delta > max_abs_delta) {
            max_abs_delta = result.abs_delta;
        }
    }

    if (total == 0) {
        std.debug.print("ERROR: no vectors found in {s}\n", .{path});
        return 3;
    }

    const exit_code: u8 = if (mismatches > 0) 2 else 0;
    std.debug.print("\nPRAOS-ALIGN: vectors={d} mismatches={d} max_abs_delta={d} EXIT={d}\n", .{ total, mismatches, max_abs_delta, exit_code });
    return exit_code;
}

fn runSelfTest() u8 {
    std.debug.print("  mode: self-test (no --vectors)\n\n", .{});

    const cases = [_]Vector{
        // stake=0 → everything is 0
        .{ .stake_fraction_x1e9 = 0, .asc_x1e6 = 50000, .expected_threshold_x1e12 = 0 },
        // 100% stake, asc=0.05
        .{ .stake_fraction_x1e9 = 1_000_000_000, .asc_x1e6 = 50000, .expected_threshold_x1e12 = producer.computeThreshX1e12(1_000_000_000, 50000) },
        // 50% stake, asc=0.05
        .{ .stake_fraction_x1e9 = 500_000_000, .asc_x1e6 = 50000, .expected_threshold_x1e12 = producer.computeThreshX1e12(500_000_000, 50000) },
    };

    var mismatches: usize = 0;
    var max_abs_delta: u64 = 0;

    for (cases, 0..) |vec, i| {
        const result = evaluateVector(vec, i);
        if (!result.match) {
            mismatches += 1;
        }
        if (result.abs_delta > max_abs_delta) {
            max_abs_delta = result.abs_delta;
        }
    }

    const exit_code: u8 = if (mismatches > 0) 2 else 0;
    std.debug.print("\nPRAOS-ALIGN: vectors={d} mismatches={d} max_abs_delta={d} EXIT={d}\n", .{ cases.len, mismatches, max_abs_delta, exit_code });
    return exit_code;
}

const EvalResult = struct {
    match: bool,
    abs_delta: u64,
};

fn evaluateVector(vec: Vector, idx: usize) EvalResult {
    // 1. Tsunagi: call existing function (NO changes)
    const tsunagi = producer.computeThreshX1e12(vec.stake_fraction_x1e9, vec.asc_x1e6);

    // 2. Expected: from vector
    const expected = vec.expected_threshold_x1e12;

    // 3. Reference: exact Praos formula computed in harness only
    //    T = 1 - (1 - f)^σ  where f = asc/1e6, σ = stake/1e9
    const reference = computeExactThreshX1e12(vec.stake_fraction_x1e9, vec.asc_x1e6);

    const match = (tsunagi == expected);
    const abs_delta_vs_expected = if (tsunagi >= expected) tsunagi - expected else expected - tsunagi;
    const abs_delta_vs_reference = if (tsunagi >= reference) tsunagi - reference else reference - tsunagi;

    std.debug.print("  vector[{d}]: stake={d} asc={d}\n", .{ idx, vec.stake_fraction_x1e9, vec.asc_x1e6 });
    std.debug.print("    tsunagi={d}  expected={d}  reference={d}\n", .{ tsunagi, expected, reference });

    if (!match) {
        const sign_expected: u8 = if (tsunagi >= expected) '+' else '-';
        std.debug.print("    tsunagi_vs_expected: FAIL  delta={c}{d}\n", .{ sign_expected, abs_delta_vs_expected });
    } else {
        std.debug.print("    tsunagi_vs_expected: PASS\n", .{});
    }

    const sign_ref: u8 = if (tsunagi >= reference) '+' else '-';
    if (abs_delta_vs_reference > 0) {
        std.debug.print("    tsunagi_vs_reference: delta={c}{d}\n", .{ sign_ref, abs_delta_vs_reference });
    } else {
        std.debug.print("    tsunagi_vs_reference: delta=0\n", .{});
    }

    return .{
        .match = match,
        .abs_delta = abs_delta_vs_expected,
    };
}

/// Exact Praos threshold: T = 1 - (1 - f)^σ, scaled to x1e12.
/// Computed in harness only — does NOT replace runtime computeThreshX1e12.
fn computeExactThreshX1e12(stake_fraction_x1e9: u64, asc_x1e6: u64) u64 {
    if (stake_fraction_x1e9 == 0) return 0;
    const f: f64 = @as(f64, @floatFromInt(asc_x1e6)) / 1_000_000.0;
    const sigma: f64 = @as(f64, @floatFromInt(stake_fraction_x1e9)) / 1_000_000_000.0;
    const t: f64 = 1.0 - std.math.pow(f64, 1.0 - f, sigma);
    if (t <= 0.0) return 0;
    if (t >= 1.0) return 1_000_000_000_000;
    return @intFromFloat(t * 1_000_000_000_000.0);
}

// --- JSONL parsing (substring-based, matching codebase pattern) ---

fn parseVector(line: []const u8) ?Vector {
    const stake = parseU64Field(line, "\"stake_fraction_x1e9\":") orelse return null;
    const asc = parseU64Field(line, "\"asc_x1e6\":") orelse return null;
    const expected = parseU64Field(line, "\"expected_threshold_x1e12\":") orelse return null;
    return .{
        .stake_fraction_x1e9 = stake,
        .asc_x1e6 = asc,
        .expected_threshold_x1e12 = expected,
    };
}

fn parseU64Field(json: []const u8, needle: []const u8) ?u64 {
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const val_start = start + needle.len;
    var end = val_start;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
    if (end == val_start) return null;
    return std.fmt.parseInt(u64, json[val_start..end], 10) catch null;
}
