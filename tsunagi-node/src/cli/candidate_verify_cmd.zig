const std = @import("std");
const compat = @import("compat");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;
const Ed25519 = std.crypto.sign.Ed25519;
const header_candidate = @import("../producer/header_candidate.zig");
const kes_verify = @import("../producer/crypto/kes_verify.zig");

/// Offline candidate artifact verification (v1.8.0, v1.8.6).
/// Supports sig_kind: none, placeholder_ed25519, real_kes.
/// Exit codes: 0 = PASS, 2 = verification failed, 3 = missing files/args.
pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    _ = alloc;
    var dir_path: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dir")) {
            dir_path = args_it.next() orelse {
                std.debug.print("ERROR: --dir requires a path\n", .{});
                return 3;
            };
        }
    }

    if (dir_path == null) {
        std.debug.print("Usage: tsunagi-node candidate-verify --dir <artifact-dir>\n", .{});
        return 3;
    }
    const dir = dir_path.?;

    // Read header.cbor (must be exactly 198 bytes)
    var header_buf: [header_candidate.CANDIDATE_V2_BYTES_LEN]u8 = undefined;
    const header_len = readFile(dir, "header.cbor", &header_buf) orelse {
        std.debug.print("FAIL: cannot read header.cbor from {s}\n", .{dir});
        return 3;
    };
    if (header_len != header_candidate.CANDIDATE_V2_BYTES_LEN) {
        std.debug.print("FAIL: header.cbor is {d} bytes, expected {d}\n", .{ header_len, header_candidate.CANDIDATE_V2_BYTES_LEN });
        return 2;
    }

    // Read header_hash.hex (64 hex chars)
    var hash_hex_buf: [128]u8 = undefined;
    const hash_hex_len = readFile(dir, "header_hash.hex", &hash_hex_buf) orelse {
        std.debug.print("FAIL: cannot read header_hash.hex from {s}\n", .{dir});
        return 3;
    };
    if (hash_hex_len != 64) {
        std.debug.print("FAIL: header_hash.hex is {d} chars, expected 64\n", .{hash_hex_len});
        return 2;
    }

    // Read meta.json
    var meta_buf: [8192]u8 = undefined;
    const meta_len = readFile(dir, "meta.json", &meta_buf) orelse {
        std.debug.print("FAIL: cannot read meta.json from {s}\n", .{dir});
        return 3;
    };
    const meta_str = meta_buf[0..meta_len];

    // Verify hash: blake2b256(header.cbor) == hex_decode(header_hash.hex)
    var computed_hash: [32]u8 = undefined;
    Blake2b256.hash(&header_buf, &computed_hash, .{});

    var expected_hash: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected_hash, hash_hex_buf[0..64]) catch {
        std.debug.print("FAIL: header_hash.hex contains invalid hex\n", .{});
        return 2;
    };

    if (!std.mem.eql(u8, &computed_hash, &expected_hash)) {
        std.debug.print("FAIL: header hash mismatch\n", .{});
        std.debug.print("  computed: {s}\n", .{std.fmt.bytesToHex(computed_hash, .lower)});
        std.debug.print("  expected: {s}\n", .{hash_hex_buf[0..64]});
        return 2;
    }
    std.debug.print("OK: header hash verified\n", .{});

    // Detect sig_kind from meta.json
    const is_real_kes = std.mem.indexOf(u8, meta_str, "\"real_kes\"") != null;
    const is_placeholder = std.mem.indexOf(u8, meta_str, "\"placeholder_ed25519\"") != null;

    if (is_real_kes) {
        return verifyRealKes(dir, meta_str);
    } else if (is_placeholder) {
        return verifyPlaceholder(dir, &header_buf, meta_str);
    } else {
        // sig_kind "none" or unknown — hash-only verification
        std.debug.print("INFO: sig_kind is not placeholder_ed25519 or real_kes, hash-only verification\n", .{});
    }

    // Check required metadata fields
    if (!checkRequiredFields(meta_str)) return 2;

    std.debug.print("\nPASS: candidate artifact verification succeeded\n", .{});
    std.debug.print("  dir: {s}\n", .{dir});
    return 0;
}

/// Verify real KES signature (v1.8.6).
/// Requires: header_body.cbor, signature.bin (448 bytes), meta.json with kes_pk_hex and kes_period_offset.
fn verifyRealKes(dir: []const u8, meta_str: []const u8) u8 {
    // Read header_body.cbor (variable length — the signed message)
    var msg_buf: [8192]u8 = undefined;
    const msg_len = readFile(dir, "header_body.cbor", &msg_buf) orelse {
        std.debug.print("FAIL: cannot read header_body.cbor from {s}\n", .{dir});
        std.debug.print("  real_kes requires header_body.cbor (the signed message)\n", .{});
        return 3;
    };
    if (msg_len == 0) {
        std.debug.print("FAIL: header_body.cbor is empty\n", .{});
        return 2;
    }
    std.debug.print("OK: header_body.cbor read ({d} bytes)\n", .{msg_len});

    // Read signature.bin (must be exactly 448 bytes for Sum6Kes)
    var sig_buf: [kes_verify.SUM6_KES_SIG_LEN]u8 = undefined;
    const sig_len = readFile(dir, "signature.bin", &sig_buf) orelse {
        std.debug.print("FAIL: cannot read signature.bin from {s}\n", .{dir});
        return 3;
    };
    if (sig_len != kes_verify.SUM6_KES_SIG_LEN) {
        std.debug.print("FAIL: signature.bin is {d} bytes, expected {d} for real_kes\n", .{ sig_len, kes_verify.SUM6_KES_SIG_LEN });
        return 2;
    }

    // Read kes_pk_hex from meta.json (64 hex chars → 32 bytes)
    const pk_hex = findJsonStringValue(meta_str, "kes_pk_hex") orelse {
        std.debug.print("FAIL: meta.json missing kes_pk_hex\n", .{});
        return 2;
    };
    if (pk_hex.len != 64) {
        std.debug.print("FAIL: kes_pk_hex is {d} hex chars, expected 64\n", .{pk_hex.len});
        return 2;
    }
    var pk: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&pk, pk_hex) catch {
        std.debug.print("FAIL: kes_pk_hex contains invalid hex\n", .{});
        return 2;
    };

    // Read kes_period_offset from meta.json
    const period_offset = findJsonIntValue(meta_str, "\"kes_period_offset\":") orelse {
        std.debug.print("FAIL: meta.json missing kes_period_offset\n", .{});
        return 2;
    };
    if (period_offset < 0 or period_offset >= 64) {
        std.debug.print("FAIL: kes_period_offset={d} out of range (0..63)\n", .{period_offset});
        return 2;
    }
    const period: u32 = @intCast(period_offset);

    // Verify with Sum6Kes
    const result = kes_verify.verifySum6Kes(pk, period, msg_buf[0..msg_len], &sig_buf);
    const result_str = kes_verify.resultStr(result);

    if (result == .ok) {
        std.debug.print("OK: real_kes signature verified (period_offset={d}, msg_len={d})\n", .{ period, msg_len });
    } else {
        std.debug.print("FAIL: real_kes verification failed: {s}\n", .{result_str});
        std.debug.print("  period_offset={d} msg_len={d} sig_len={d}\n", .{ period, msg_len, sig_len });
        return 2;
    }

    // Check required metadata fields
    if (!checkRequiredFields(meta_str)) return 2;

    std.debug.print("\nPASS: candidate artifact verification succeeded (real_kes)\n", .{});
    return 0;
}

/// Verify placeholder Ed25519 signature (existing v1.8.0 logic).
fn verifyPlaceholder(dir: []const u8, header_buf: *const [header_candidate.CANDIDATE_V2_BYTES_LEN]u8, meta_str: []const u8) u8 {
    // Read signature.bin (64 bytes for placeholder Ed25519)
    var sig_buf: [64]u8 = undefined;
    const sig_len = readFile(dir, "signature.bin", &sig_buf) orelse {
        std.debug.print("FAIL: cannot read signature.bin from {s}\n", .{dir});
        return 3;
    };
    if (sig_len != 64) {
        std.debug.print("FAIL: signature.bin is {d} bytes, expected 64\n", .{sig_len});
        return 2;
    }

    // Try to get pool_id_hex from meta.json (preferred source)
    var pool_id_seed: ?[32]u8 = null;

    if (findJsonStringValue(meta_str, "pool_id_hex")) |pid_hex| {
        if (pid_hex.len == 64) {
            var seed: [32]u8 = undefined;
            if (std.fmt.hexToBytes(&seed, pid_hex)) |_| {
                pool_id_seed = seed;
            } else |_| {
                std.debug.print("WARN: pool_id_hex in meta.json is invalid hex, trying header fallback\n", .{});
            }
        } else {
            std.debug.print("WARN: pool_id_hex in meta.json is {d} chars, expected 64\n", .{pid_hex.len});
        }
    }

    // Fallback: extract pool_id from header bytes offset 134..166
    if (pool_id_seed == null) {
        const POOL_ID_OFFSET = 134;
        if (header_buf.len >= POOL_ID_OFFSET + 32) {
            var seed: [32]u8 = undefined;
            @memcpy(&seed, header_buf[POOL_ID_OFFSET .. POOL_ID_OFFSET + 32]);
            pool_id_seed = seed;
            std.debug.print("INFO: using pool_id from header offset {d}..{d}\n", .{ POOL_ID_OFFSET, POOL_ID_OFFSET + 32 });
        }
    }

    if (pool_id_seed) |seed| {
        const kp = Ed25519.KeyPair.generateDeterministic(seed) catch {
            std.debug.print("FAIL: cannot derive Ed25519 keypair from pool_id\n", .{});
            return 2;
        };
        const sig = Ed25519.Signature.fromBytes(sig_buf);
        sig.verify(header_buf, kp.public_key) catch {
            std.debug.print("FAIL: Ed25519 signature verification failed\n", .{});
            return 2;
        };
        std.debug.print("OK: placeholder_ed25519 signature verified\n", .{});
    } else {
        std.debug.print("WARN: cannot extract pool_id, skipping signature verification\n", .{});
    }

    // Check required metadata fields
    if (!checkRequiredFields(meta_str)) return 2;

    std.debug.print("\nPASS: candidate artifact verification succeeded\n", .{});
    std.debug.print("  dir: {s}\n", .{dir});
    return 0;
}

/// Check required metadata fields in meta.json.
fn checkRequiredFields(meta_str: []const u8) bool {
    const required_fields = [_][]const u8{ "unix", "net", "slot", "sig_kind", "candidate_version" };
    for (required_fields) |field| {
        var search_buf: [64]u8 = undefined;
        const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{field}) catch continue;
        if (std.mem.indexOf(u8, meta_str, search_key) == null) {
            std.debug.print("FAIL: meta.json missing required field: {s}\n", .{field});
            return false;
        }
    }
    return true;
}

/// Read a file from a directory into the provided buffer. Returns bytes read or null on error.
fn readFile(dir: []const u8, name: []const u8, buf: []u8) ?usize {
    var path_buf: [600]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return null;
    var f = compat.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    const n = f.readAll(buf) catch return null;
    return n;
}

/// Find a JSON string value for a given key using simple substring search.
/// Handles both "key":"value" and "key": "value" (with optional space).
fn findJsonStringValue(json: []const u8, key: []const u8) ?[]const u8 {
    // Try without space: "key":"value"
    var search_buf: [128]u8 = undefined;
    const needle1 = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    if (std.mem.indexOf(u8, json, needle1)) |pos| {
        const start = pos + needle1.len;
        const end = std.mem.indexOf(u8, json[start..], "\"") orelse return null;
        return json[start .. start + end];
    }

    // Try with space: "key": "value"
    var search_buf2: [128]u8 = undefined;
    const needle2 = std.fmt.bufPrint(&search_buf2, "\"{s}\": \"", .{key}) catch return null;
    if (std.mem.indexOf(u8, json, needle2)) |pos| {
        const start = pos + needle2.len;
        const end = std.mem.indexOf(u8, json[start..], "\"") orelse return null;
        return json[start .. start + end];
    }

    return null;
}

/// Find a JSON integer value for a given key needle (e.g. "\"kes_period_offset\":").
/// Returns the parsed i64 or null.
fn findJsonIntValue(json: []const u8, needle: []const u8) ?i64 {
    const start_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    var pos = start_pos + needle.len;
    // Skip whitespace
    while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) : (pos += 1) {}
    // Check for negative
    var negative = false;
    if (pos < json.len and json[pos] == '-') {
        negative = true;
        pos += 1;
    }
    // Parse digits
    var end = pos;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
    if (end == pos) return null;
    const abs_val = std.fmt.parseInt(i64, json[pos..end], 10) catch return null;
    return if (negative) -abs_val else abs_val;
}
