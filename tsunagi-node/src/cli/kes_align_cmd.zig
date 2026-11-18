const std = @import("std");
const compat = @import("compat");
const kes_verify = @import("../producer/crypto/kes_verify.zig");

/// JSONL alignment harness for SumKES verification vectors.
/// Exit codes: 0 = all pass, 2 = mismatch, 3 = missing args/files.
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

    if (vectors_path == null) {
        std.debug.print("Usage: tsunagi-node kes-align --vectors <path.jsonl>\n", .{});
        return 3;
    }

    const path = vectors_path.?;
    std.debug.print("=== TSUNAGI KES Alignment ===\n\n", .{});

    var file = compat.fs.cwd().openFile(path, .{}) catch {
        std.debug.print("ERROR: cannot open {s}\n", .{path});
        return 3;
    };
    defer file.close();

    var total: usize = 0;
    var mismatches: usize = 0;
    var line_buf: [16384]u8 = undefined;
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

        // Parse required fields
        const pk_hex = parseHexField(content, "\"kes_pk_hex\":\"") orelse {
            std.debug.print("ERROR: cannot parse kes_pk_hex at line {d}\n", .{total + 1});
            return 3;
        };
        if (pk_hex.len != 64) {
            std.debug.print("ERROR: kes_pk_hex must be 64 hex chars at line {d}, got {d}\n", .{ total + 1, pk_hex.len });
            return 3;
        }

        const period_val = parseU64Field(content, "\"kes_period\":") orelse {
            std.debug.print("ERROR: cannot parse kes_period at line {d}\n", .{total + 1});
            return 3;
        };
        if (period_val >= 64) {
            std.debug.print("ERROR: kes_period must be 0..63 at line {d}, got {d}\n", .{ total + 1, period_val });
            return 3;
        }
        const period: u32 = @intCast(period_val);

        const sig_hex = parseHexField(content, "\"kes_sig_hex\":\"") orelse {
            std.debug.print("ERROR: cannot parse kes_sig_hex at line {d}\n", .{total + 1});
            return 3;
        };
        if (sig_hex.len != 896) {
            std.debug.print("ERROR: kes_sig_hex must be 896 hex chars at line {d}, got {d}\n", .{ total + 1, sig_hex.len });
            return 3;
        }

        const expected_result_str = parseHexField(content, "\"expected_result\":\"") orelse {
            std.debug.print("ERROR: cannot parse expected_result at line {d}\n", .{total + 1});
            return 3;
        };

        // Optional msg_hex (defaults to empty)
        const msg_hex = parseHexField(content, "\"msg_hex\":\"");

        // Decode pk
        var pk: [32]u8 = undefined;
        if (!hexToBytes(pk_hex, &pk)) {
            std.debug.print("ERROR: invalid hex in kes_pk_hex at line {d}\n", .{total + 1});
            return 3;
        }

        // Decode sig
        var sig: [448]u8 = undefined;
        if (!hexToBytes(sig_hex, &sig)) {
            std.debug.print("ERROR: invalid hex in kes_sig_hex at line {d}\n", .{total + 1});
            return 3;
        }

        // Decode msg
        var msg_buf: [8192]u8 = undefined;
        var msg_len: usize = 0;
        if (msg_hex) |mh| {
            if (mh.len % 2 != 0 or mh.len / 2 > msg_buf.len) {
                std.debug.print("ERROR: invalid msg_hex length at line {d}\n", .{total + 1});
                return 3;
            }
            msg_len = mh.len / 2;
            if (!hexToBytes(mh, msg_buf[0..msg_len])) {
                std.debug.print("ERROR: invalid hex in msg_hex at line {d}\n", .{total + 1});
                return 3;
            }
        }

        // Verify
        const result = kes_verify.verifySum6Kes(pk, period, msg_buf[0..msg_len], &sig);
        const got_str = kes_verify.resultStr(result);

        const match = std.mem.eql(u8, got_str, expected_result_str);
        std.debug.print("  vector[{d}]: period={d} msg_len={d}", .{ total, period, msg_len });
        if (match) {
            std.debug.print(" PASS ({s})\n", .{got_str});
        } else {
            std.debug.print(" FAIL (got {s}, expected {s})\n", .{ got_str, expected_result_str });
            mismatches += 1;
        }

        total += 1;
    }

    if (total == 0) {
        std.debug.print("ERROR: no vectors found in {s}\n", .{path});
        return 3;
    }

    const exit_code: u8 = if (mismatches > 0) 2 else 0;
    std.debug.print("\nKES-ALIGN: vectors={d} mismatches={d} EXIT={d}\n", .{ total, mismatches, exit_code });
    return exit_code;
}

// --- Hex utilities ---

fn hexToBytes(hex: []const u8, out: []u8) bool {
    if (hex.len != out.len * 2) return false;
    for (0..out.len) |i| {
        const hi = hexDigit(hex[i * 2]) orelse return false;
        const lo = hexDigit(hex[i * 2 + 1]) orelse return false;
        out[i] = (@as(u8, hi) << 4) | @as(u8, lo);
    }
    return true;
}

fn hexDigit(ch: u8) ?u4 {
    if (ch >= '0' and ch <= '9') return @intCast(ch - '0');
    if (ch >= 'a' and ch <= 'f') return @intCast(ch - 'a' + 10);
    if (ch >= 'A' and ch <= 'F') return @intCast(ch - 'A' + 10);
    return null;
}

// --- JSONL parsing ---

fn parseHexField(json: []const u8, needle: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const val_start = start + needle.len;
    const end = std.mem.indexOfPos(u8, json, val_start, "\"") orelse return null;
    if (end == val_start) return null;
    return json[val_start..end];
}

fn parseU64Field(json: []const u8, needle: []const u8) ?u64 {
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const val_start = start + needle.len;
    var end = val_start;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
    if (end == val_start) return null;
    return std.fmt.parseInt(u64, json[val_start..end], 10) catch null;
}
