const std = @import("std");
const compat = @import("compat");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;
const header_candidate = @import("../producer/header_candidate.zig");

const Mode = enum {
    candidate_v2,
    cardano_header_bytes,
};

pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var vectors_path: ?[]const u8 = null;
    var mode: ?Mode = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--vectors")) {
            vectors_path = args_it.next() orelse {
                std.debug.print("ERROR: --vectors requires a path\n", .{});
                return 3;
            };
        } else if (std.mem.eql(u8, arg, "--candidate-v2")) {
            mode = .candidate_v2;
        } else if (std.mem.eql(u8, arg, "--cardano-header-bytes")) {
            mode = .cardano_header_bytes;
        }
    }

    if (mode == null) {
        std.debug.print("ERROR: must specify --candidate-v2 or --cardano-header-bytes\n", .{});
        return 3;
    }

    const m = mode.?;
    const mode_str = switch (m) {
        .candidate_v2 => "candidate-v2",
        .cardano_header_bytes => "cardano-header-bytes",
    };

    std.debug.print("=== TSUNAGI Header Alignment [{s}] ===\n\n", .{mode_str});

    if (vectors_path) |path| {
        return runFromFile(alloc, path, m, mode_str);
    } else {
        if (m == .cardano_header_bytes) {
            std.debug.print("ERROR: --cardano-header-bytes requires --vectors (no self-test available)\n", .{});
            return 3;
        }
        return runSelfTest(mode_str);
    }
}

fn runFromFile(alloc: std.mem.Allocator, path: []const u8, mode: Mode, mode_str: []const u8) u8 {
    var file = compat.fs.cwd().openFile(path, .{}) catch {
        std.debug.print("ERROR: cannot open {s}\n", .{path});
        return 3;
    };
    defer file.close();

    var total: usize = 0;
    var mismatches: usize = 0;
    var line_buf: [16384]u8 = undefined; // larger for hex-encoded headers
    const buf_reader = file.deprecatedReader();
    var reader = buf_reader;

    // Allocate buffer for decoded bytes
    var decode_buf: [8192]u8 = undefined;

    while (true) {
        const line = reader.readUntilDelimiterOrEof(&line_buf, '\n') catch {
            std.debug.print("ERROR: read error at line {d}\n", .{total + 1});
            return 3;
        };
        if (line == null) break;
        const content = line.?;
        if (content.len == 0) continue;

        // Parse header_bytes_hex
        const bytes_hex = parseHexField(content, "\"header_bytes_hex\":\"") orelse {
            std.debug.print("ERROR: cannot parse header_bytes_hex at line {d}\n", .{total + 1});
            return 3;
        };

        // Parse expected hash (field name depends on mode)
        const expected_hex = switch (mode) {
            .candidate_v2 => parseHexField(content, "\"expected_hash_hex\":\""),
            .cardano_header_bytes => parseHexField(content, "\"expected_header_hash_hex\":\""),
        } orelse {
            const field_name = switch (mode) {
                .candidate_v2 => "expected_hash_hex",
                .cardano_header_bytes => "expected_header_hash_hex",
            };
            std.debug.print("ERROR: cannot parse {s} at line {d}\n", .{ field_name, total + 1 });
            return 3;
        };

        if (expected_hex.len != 64) {
            std.debug.print("ERROR: expected hash must be 64 hex chars at line {d}\n", .{total + 1});
            return 3;
        }

        if (bytes_hex.len % 2 != 0 or bytes_hex.len / 2 > decode_buf.len) {
            std.debug.print("ERROR: header_bytes_hex invalid length at line {d}\n", .{total + 1});
            return 3;
        }

        const byte_len = bytes_hex.len / 2;
        if (!hexToBytes(bytes_hex, decode_buf[0..byte_len])) {
            std.debug.print("ERROR: invalid hex in header_bytes_hex at line {d}\n", .{total + 1});
            return 3;
        }

        // Validate candidate-v2 size if in that mode
        if (mode == .candidate_v2 and byte_len != header_candidate.CANDIDATE_V2_BYTES_LEN) {
            std.debug.print("ERROR: candidate-v2 bytes must be {d} bytes, got {d} at line {d}\n", .{ header_candidate.CANDIDATE_V2_BYTES_LEN, byte_len, total + 1 });
            return 3;
        }

        // Compute hash
        var digest: [32]u8 = undefined;
        Blake2b256.hash(decode_buf[0..byte_len], &digest, .{});

        // Convert to hex
        const hex_chars = "0123456789abcdef";
        var computed_hex: [64]u8 = undefined;
        for (0..32) |i| {
            computed_hex[i * 2] = hex_chars[digest[i] >> 4];
            computed_hex[i * 2 + 1] = hex_chars[digest[i] & 0xf];
        }

        const match = std.mem.eql(u8, &computed_hex, expected_hex);
        std.debug.print("  vector[{d}]: {d} bytes", .{ total, byte_len });
        if (match) {
            std.debug.print(" PASS\n", .{});
        } else {
            std.debug.print(" FAIL\n", .{});
            std.debug.print("    computed: {s}\n", .{&computed_hex});
            std.debug.print("    expected: {s}\n", .{expected_hex});
            mismatches += 1;
        }

        total += 1;
    }

    _ = alloc;

    if (total == 0) {
        std.debug.print("ERROR: no vectors found in {s}\n", .{path});
        return 3;
    }

    const exit_code: u8 = if (mismatches > 0) 2 else 0;
    std.debug.print("\nHEADER-ALIGN[{s}]: vectors={d} mismatches={d} max_abs_delta=0 EXIT={d}\n", .{ mode_str, total, mismatches, exit_code });
    return exit_code;
}

fn runSelfTest(mode_str: []const u8) u8 {
    std.debug.print("  mode: self-test (no --vectors)\n\n", .{});

    // Build a deterministic CandidateV2 and verify hash round-trips
    const net_magic: u32 = 764824073; // mainnet
    const epoch: u64 = 500;
    const slot: u64 = 123456789;
    const slot_in_epoch: u64 = 123456789 % 432000;
    const tip_block: u64 = 10000000;

    // Deterministic hashes
    var tip_hash: [32]u8 = undefined;
    Blake2b256.hash("TSUNAGI_ALIGN_TIP", &tip_hash, .{});

    var state_digest: [32]u8 = undefined;
    Blake2b256.hash("TSUNAGI_ALIGN_STATE", &state_digest, .{});

    var vrf_prefix: [8]u8 = undefined;
    var vrf_seed: [32]u8 = undefined;
    Blake2b256.hash("TSUNAGI_ALIGN_VRF", &vrf_seed, .{});
    @memcpy(&vrf_prefix, vrf_seed[0..8]);

    var pool_id: [32]u8 = undefined;
    Blake2b256.hash("TSUNAGI_ALIGN_POOL", &pool_id, .{});

    var body_hash: [32]u8 = undefined;
    Blake2b256.hash("TSUNAGI_ALIGN_BODY", &body_hash, .{});

    const candidate = header_candidate.buildCandidateV2(
        net_magic,
        epoch,
        slot,
        slot_in_epoch,
        tip_block,
        tip_hash,
        state_digest,
        vrf_prefix,
        pool_id,
        body_hash,
    );

    // Verify: re-hash the bytes and compare
    var recomputed: [32]u8 = undefined;
    Blake2b256.hash(&candidate.bytes, &recomputed, .{});

    const match = std.mem.eql(u8, &recomputed, &candidate.header_hash);

    const hex_chars = "0123456789abcdef";
    var hash_hex: [64]u8 = undefined;
    for (0..32) |i| {
        hash_hex[i * 2] = hex_chars[candidate.header_hash[i] >> 4];
        hash_hex[i * 2 + 1] = hex_chars[candidate.header_hash[i] & 0xf];
    }

    std.debug.print("  vector[0]: CandidateV2 {d} bytes  hash={s}", .{ candidate.bytes_len, &hash_hex });

    var mismatches: usize = 0;
    if (match) {
        std.debug.print(" PASS\n", .{});
    } else {
        std.debug.print(" FAIL (round-trip mismatch)\n", .{});
        mismatches = 1;
    }

    const exit_code: u8 = if (mismatches > 0) 2 else 0;
    std.debug.print("\nHEADER-ALIGN[{s}]: vectors=1 mismatches={d} max_abs_delta=0 EXIT={d}\n", .{ mode_str, mismatches, exit_code });
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
