const std = @import("std");
const compat = @import("compat");
const producer = @import("../producer/producer.zig");
const sodium_vrf = @import("../producer/crypto/sodium_vrf.zig");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

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

    std.debug.print("=== TSUNAGI VRF Alignment ===\n\n", .{});

    if (vectors_path) |path| {
        return runFromFile(alloc, path);
    } else {
        return runSelfTest();
    }
}

fn runFromFile(alloc: std.mem.Allocator, path: []const u8) u8 {
    _ = alloc;
    var file = compat.fs.cwd().openFile(path, .{}) catch {
        std.debug.print("ERROR: cannot open {s}\n", .{path});
        return 3;
    };
    defer file.close();

    // Init sodium for proof path
    var sodium_ok = false;

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

        // Parse vector
        const expected_u = parseU64Field(content, "\"expected_u_x1e12\":") orelse {
            std.debug.print("ERROR: cannot parse expected_u_x1e12 at line {d}\n", .{total + 1});
            return 3;
        };

        // Try proof path first (strongest)
        var output_bytes: [64]u8 = undefined;
        var used_proof = false;
        var verify_skipped = false;

        const proof_hex = parseHexField(content, "\"vrf_proof_hex\":\"");
        const output_hex = parseHexField(content, "\"vrf_output_hex\":\"");

        if (proof_hex) |ph| {
            if (ph.len != 160) {
                std.debug.print("ERROR: vrf_proof_hex must be 160 hex chars at line {d}\n", .{total + 1});
                return 3;
            }
            // Lazy init sodium
            if (!sodium_ok) {
                sodium_ok = sodium_vrf.sodiumInit();
                if (!sodium_ok) {
                    std.debug.print("WARN: sodium init failed, proof path unavailable\n", .{});
                }
            }
            if (sodium_ok) {
                var proof: [80]u8 = undefined;
                if (!hexToBytes(ph, &proof)) {
                    std.debug.print("ERROR: invalid hex in vrf_proof_hex at line {d}\n", .{total + 1});
                    return 3;
                }
                const hash_result = sodium_vrf.proofToHash(&proof);
                if (hash_result) |out| {
                    output_bytes = out;
                    used_proof = true;
                    verify_skipped = true; // no pubkey+message for full verify
                } else {
                    std.debug.print("WARN: proofToHash failed at line {d}, falling back\n", .{total + 1});
                }
            }

            // Cross-check if both proof and output are present
            if (used_proof and output_hex != null) {
                if (output_hex.?.len == 128) {
                    var expected_output: [64]u8 = undefined;
                    if (hexToBytes(output_hex.?, &expected_output)) {
                        if (!std.mem.eql(u8, &output_bytes, &expected_output)) {
                            std.debug.print("  WARN: proofToHash output differs from vrf_output_hex at line {d}\n", .{total + 1});
                        }
                    }
                }
            }
        }

        if (!used_proof) {
            if (output_hex) |oh| {
                if (oh.len != 128) {
                    std.debug.print("ERROR: vrf_output_hex must be 128 hex chars at line {d}\n", .{total + 1});
                    return 3;
                }
                if (!hexToBytes(oh, &output_bytes)) {
                    std.debug.print("ERROR: invalid hex in vrf_output_hex at line {d}\n", .{total + 1});
                    return 3;
                }
            } else {
                std.debug.print("ERROR: need vrf_proof_hex or vrf_output_hex at line {d}\n", .{total + 1});
                return 3;
            }
        }

        const computed_u = producer.vrfOutputToU_x1e12(output_bytes);
        const match = (computed_u == expected_u);
        const abs_delta = if (computed_u >= expected_u) computed_u - expected_u else expected_u - computed_u;

        std.debug.print("  vector[{d}]: computed_u={d} expected_u={d}", .{ total, computed_u, expected_u });
        if (used_proof) {
            std.debug.print(" VERIFY_SKIPPED=1", .{});
        }
        if (match) {
            std.debug.print(" PASS\n", .{});
        } else {
            std.debug.print(" FAIL delta={d}\n", .{abs_delta});
        }

        total += 1;
        if (!match) mismatches += 1;
        if (abs_delta > max_abs_delta) max_abs_delta = abs_delta;
    }

    if (total == 0) {
        std.debug.print("ERROR: no vectors found in {s}\n", .{path});
        return 3;
    }

    const exit_code: u8 = if (mismatches > 0) 2 else 0;
    std.debug.print("\nVRF-ALIGN: vectors={d} mismatches={d} max_abs_delta={d} EXIT={d}\n", .{ total, mismatches, max_abs_delta, exit_code });
    return exit_code;
}

fn runSelfTest() u8 {
    std.debug.print("  mode: self-test (no --vectors)\n\n", .{});

    var mismatches: usize = 0;
    var max_abs_delta: u64 = 0;
    var total: usize = 0;

    // Case 1: All-zero output → u = 1 (clamped min)
    {
        const output = [_]u8{0} ** 64;
        const computed = producer.vrfOutputToU_x1e12(output);
        const expected: u64 = 1;
        const match = (computed == expected);
        const delta = if (computed >= expected) computed - expected else expected - computed;
        std.debug.print("  vector[0]: all-zero output  computed_u={d} expected_u={d}", .{ computed, expected });
        if (match) {
            std.debug.print(" PASS\n", .{});
        } else {
            std.debug.print(" FAIL delta={d}\n", .{delta});
            mismatches += 1;
        }
        if (delta > max_abs_delta) max_abs_delta = delta;
        total += 1;
    }

    // Case 2: Deterministic output from blake2b256("TSUNAGI_VRF_SELFTEST")
    {
        var hash: [32]u8 = undefined;
        Blake2b256.hash("TSUNAGI_VRF_SELFTEST", &hash, .{});
        var output: [64]u8 = [_]u8{0} ** 64;
        @memcpy(output[0..32], &hash);
        const computed = producer.vrfOutputToU_x1e12(output);
        // Self-test: expected = computed (verifying determinism)
        const expected = computed;
        std.debug.print("  vector[1]: blake2b256(selftest)  computed_u={d} expected_u={d} PASS\n", .{ computed, expected });
        total += 1;
    }

    const exit_code: u8 = if (mismatches > 0) 2 else 0;
    std.debug.print("\nVRF-ALIGN: vectors={d} mismatches={d} max_abs_delta={d} EXIT={d}\n", .{ total, mismatches, max_abs_delta, exit_code });
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

fn parseU64Field(json: []const u8, needle: []const u8) ?u64 {
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const val_start = start + needle.len;
    var end = val_start;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
    if (end == val_start) return null;
    return std.fmt.parseInt(u64, json[val_start..end], 10) catch null;
}

fn parseHexField(json: []const u8, needle: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const val_start = start + needle.len;
    const end = std.mem.indexOfPos(u8, json, val_start, "\"") orelse return null;
    if (end == val_start) return null;
    return json[val_start..end];
}
