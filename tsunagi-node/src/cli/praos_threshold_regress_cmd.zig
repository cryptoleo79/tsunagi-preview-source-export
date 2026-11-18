const std = @import("std");
const compat = @import("compat");
const producer = @import("../producer/producer.zig");

/// Praos Threshold Drift Guard — oracle regression lock-in (v1.9.5).
///
/// Compares computeThreshX1e12() output against expected_threshold_x1e12
/// from cardano-node oracle vectors.
///
/// - expected_threshold_x1e12 == null → SKIP (not failure)
/// - Fails immediately if any mismatch.
/// - No exact_reference. No float diagnostics. No delta printing.
/// - Pure oracle lock-in command.
///
/// Exit codes: 0=no mismatches, 2=mismatch found, 3=parse/file/IO error

pub fn run(_: std.mem.Allocator, args_it: anytype) u8 {
    var vectors_path: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--vectors")) {
            vectors_path = args_it.next() orelse {
                std.debug.print("ERROR: --vectors requires a path\n", .{});
                return 3;
            };
        }
    }

    const path = vectors_path orelse {
        std.debug.print("ERROR: --vectors <path.jsonl> is required\n", .{});
        return 3;
    };

    var file = compat.fs.cwd().openFile(path, .{}) catch {
        std.debug.print("ERROR: cannot open {s}\n", .{path});
        return 3;
    };
    defer file.close();

    var total: usize = 0;
    var mismatches: usize = 0;
    var skipped: usize = 0;

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

        total += 1;

        if (vec.expected_is_null) {
            skipped += 1;
            continue;
        }

        const tsu = producer.computeThreshX1e12(vec.stake_fraction_x1e9, vec.asc_x1e6);
        if (tsu != vec.expected_threshold_x1e12) {
            mismatches += 1;
        }
    }

    if (total == 0) {
        std.debug.print("ERROR: no vectors found in {s}\n", .{path});
        return 3;
    }

    const exit_code: u8 = if (mismatches > 0) 2 else 0;

    std.debug.print("=== Praos Threshold Drift Guard ===\n", .{});
    std.debug.print("vectors={d} mismatches={d} skipped={d}\n", .{ total, mismatches, skipped });
    std.debug.print("EXIT={d}\n", .{exit_code});

    return exit_code;
}

// ── JSONL parsing ─────────────────────────────────────────────────────

const ParsedVector = struct {
    stake_fraction_x1e9: u64,
    asc_x1e6: u64,
    expected_is_null: bool,
    expected_threshold_x1e12: u64,
};

fn parseVector(line: []const u8) ?ParsedVector {
    const stake = parseU64Field(line, "\"stake_fraction_x1e9\":") orelse return null;
    const asc = parseU64Field(line, "\"asc_x1e6\":") orelse return null;

    var expected_is_null = false;
    var expected_value: u64 = 0;

    const needle = "\"expected_threshold_x1e12\":";
    if (std.mem.indexOf(u8, line, needle)) |start| {
        const val_start = start + needle.len;
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
    while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) : (pos += 1) {}
    var end = pos;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
    if (end == pos) return null;
    return std.fmt.parseInt(u64, json[pos..end], 10) catch null;
}
