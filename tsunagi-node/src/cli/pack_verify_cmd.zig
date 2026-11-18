const std = @import("std");
const compat = @import("compat");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;
const sodium_vrf = @import("../producer/crypto/sodium_vrf.zig");
const producer = @import("../producer/producer.zig");
const Ed25519 = std.crypto.sign.Ed25519;

const hex_chars = "0123456789abcdef";

fn findJsonNumValue(json: []const u8, key: []const u8) ?u64 {
    var search_buf: [128]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, json, search) orelse return null;
    var i = pos + search.len;
    while (i < json.len and json[i] == ' ') : (i += 1) {}
    if (i >= json.len) return null;
    var end = i;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
    if (end == i) return null;
    return std.fmt.parseUnsigned(u64, json[i..end], 10) catch null;
}

fn findJsonStrValue(json: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [128]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, json, search) orelse return null;
    const val_start = pos + search.len;
    const val_end = std.mem.indexOfScalarPos(u8, json, val_start, '"') orelse return null;
    return json[val_start..val_end];
}

/// Check if JSON contains "key":true (boolean true, not string)
fn findJsonBoolTrue(json: []const u8, key: []const u8) bool {
    var search_buf: [128]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\":true", .{key}) catch return false;
    return std.mem.indexOf(u8, json, search) != null;
}

fn readFileFromDir(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ?[]const u8 {
    const path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name }) catch return null;
    defer alloc.free(path);
    var file = compat.fs.cwd().openFile(path, .{ .mode = .read_only }) catch return null;
    defer file.close();
    return file.readToEndAlloc(alloc, 4 * 1024 * 1024) catch null;
}

fn hexEncodeBytes(buf: []u8, data: []const u8) void {
    for (data, 0..) |b, i| {
        buf[i * 2] = hex_chars[b >> 4];
        buf[i * 2 + 1] = hex_chars[b & 0xf];
    }
}

fn hashAndHex(buf: *[64]u8, data: []const u8) void {
    var digest: [32]u8 = undefined;
    Blake2b256.hash(data, &digest, .{});
    hexEncodeBytes(buf, &digest);
}

/// Parse one file entry from the "files" array starting at pos.
/// Returns (name, size, hash_hex, end_pos) or null.
fn parseFileEntry(json: []const u8, start: usize) ?struct { name: []const u8, size: u64, hash_hex: []const u8, end_pos: usize } {
    // Find next {"name":"
    const marker = "{\"name\":\"";
    const pos = std.mem.indexOfPos(u8, json, start, marker) orelse return null;
    const name_start = pos + marker.len;
    const name_end = std.mem.indexOfScalarPos(u8, json, name_start, '"') orelse return null;
    const name = json[name_start..name_end];

    // Find "size":
    const size_marker = "\"size\":";
    const size_pos = std.mem.indexOfPos(u8, json, name_end, size_marker) orelse return null;
    var si = size_pos + size_marker.len;
    while (si < json.len and json[si] == ' ') : (si += 1) {}
    var se = si;
    while (se < json.len and json[se] >= '0' and json[se] <= '9') : (se += 1) {}
    const size = std.fmt.parseUnsigned(u64, json[si..se], 10) catch return null;

    // Find "blake2b256":"
    const hash_marker = "\"blake2b256\":\"";
    const hash_pos = std.mem.indexOfPos(u8, json, se, hash_marker) orelse return null;
    const hash_start = hash_pos + hash_marker.len;
    const hash_end = std.mem.indexOfScalarPos(u8, json, hash_start, '"') orelse return null;
    const hash_hex = json[hash_start..hash_end];

    // Find closing }
    const close = std.mem.indexOfScalarPos(u8, json, hash_end, '}') orelse return null;

    return .{ .name = name, .size = size, .hash_hex = hash_hex, .end_pos = close + 1 };
}

pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var dir: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dir")) {
            dir = args_it.next();
        }
    }

    if (dir == null) {
        std.debug.print("Usage: tsunagi-node pack-verify --dir <pack-directory>\n", .{});
        return 1;
    }

    const pack_dir = dir.?;
    std.debug.print("=== TSUNAGI Pack Verify ===\nDir: {s}\n\n", .{pack_dir});

    var checks_total: u32 = 0;
    var checks_pass: u32 = 0;
    var files_ok: u32 = 0;
    var hashes_ok: u32 = 0;
    var invariants_ok: u32 = 0;

    // 1. Read pack.json
    const pack_json = readFileFromDir(alloc, pack_dir, "pack.json");
    if (pack_json == null) {
        std.debug.print("  pack.json:              FAIL (not found or unreadable)\n", .{});
        checks_total += 1;
        printSummary(checks_pass, checks_total, files_ok, hashes_ok, 0, invariants_ok);
        return 1;
    }
    defer alloc.free(pack_json.?);
    const json = pack_json.?;

    const version = findJsonNumValue(json, "version") orelse 0;
    if (version != 1 and version != 2 and version != 3) {
        std.debug.print("  pack.json:              FAIL (version={d}, expected 1, 2, or 3)\n", .{version});
        checks_total += 1;
        printSummary(checks_pass, checks_total, files_ok, hashes_ok, 0, invariants_ok);
        return 1;
    }
    std.debug.print("  pack.json:              ok (version={d})\n", .{version});
    checks_total += 1;
    checks_pass += 1;

    // Soft-check: if pack_schema_version is present, it must be 1
    const pack_schema_ver = findJsonNumValue(json, "pack_schema_version");
    if (pack_schema_ver) |psv| {
        if (psv != 1) {
            std.debug.print("  pack_schema_version:    WARNING (got {d}, expected 1)\n", .{psv});
        } else {
            std.debug.print("  pack_schema_version:    ok (1)\n", .{});
        }
    }

    // Parse expected values
    const exp_hdr_len = findJsonNumValue(json, "hdr_bytes_len") orelse 0;
    const exp_body_len = findJsonNumValue(json, "body_cbor_len") orelse 0;
    const exp_hdr_hash_hex = findJsonStrValue(json, "hdr_hash_hex");
    const exp_body_hash_hex = findJsonStrValue(json, "body_hash_hex");
    const exp_vrf_proof_len = findJsonNumValue(json, "vrf_proof_len") orelse 0;
    const exp_vrf_output_len = findJsonNumValue(json, "vrf_output_len") orelse 0;
    const exp_sig_len = findJsonNumValue(json, "sig_len") orelse 0;

    // 2. candidate_hdr_198.bin
    const hdr_data = readFileFromDir(alloc, pack_dir, "candidate_hdr_198.bin");
    if (hdr_data == null) {
        std.debug.print("  candidate_hdr_198.bin:  FAIL (not found)\n", .{});
        checks_total += 1;
    } else {
        defer alloc.free(hdr_data.?);
        const hdr = hdr_data.?;
        if (hdr.len != exp_hdr_len) {
            std.debug.print("  candidate_hdr_198.bin:  FAIL (size={d}, expected {d})\n", .{ hdr.len, exp_hdr_len });
            checks_total += 1;
        } else {
            std.debug.print("  candidate_hdr_198.bin:  ok ({d} bytes)\n", .{hdr.len});
            checks_total += 1;
            checks_pass += 1;
        }

        // 3. Check domain bytes
        if (hdr.len >= 26) {
            const domain_len = std.mem.readInt(u16, hdr[0..2], .little);
            const expected_domain = "TSUNAGI_HDR_CANDIDATE_V2";
            if (domain_len == expected_domain.len and std.mem.eql(u8, hdr[2..26], expected_domain)) {
                std.debug.print("  header domain:          ok (\"{s}\")\n", .{expected_domain});
                checks_total += 1;
                checks_pass += 1;
            } else {
                std.debug.print("  header domain:          FAIL (domain_len={d})\n", .{domain_len});
                checks_total += 1;
            }
        } else {
            std.debug.print("  header domain:          FAIL (header too short)\n", .{});
            checks_total += 1;
        }

        // 4. Recompute header hash
        if (hdr.len == 198 and exp_hdr_hash_hex != null) {
            var recomputed: [32]u8 = undefined;
            Blake2b256.hash(hdr[0..198], &recomputed, .{});
            var recomputed_hex: [64]u8 = undefined;
            hexEncodeBytes(&recomputed_hex, &recomputed);
            if (std.mem.eql(u8, &recomputed_hex, exp_hdr_hash_hex.?)) {
                std.debug.print("  header hash:            ok (match pack.json)\n", .{});
                checks_total += 1;
                checks_pass += 1;
            } else {
                std.debug.print("  header hash:            FAIL (mismatch)\n", .{});
                std.debug.print("    expected: {s}\n", .{exp_hdr_hash_hex.?});
                std.debug.print("    got:      {s}\n", .{&recomputed_hex});
                checks_total += 1;
            }
        }
    }

    // 5. candidate_body.cbor
    const body_data = readFileFromDir(alloc, pack_dir, "candidate_body.cbor");
    if (body_data == null) {
        std.debug.print("  candidate_body.cbor:    FAIL (not found)\n", .{});
        checks_total += 1;
    } else {
        defer alloc.free(body_data.?);
        const body = body_data.?;
        if (body.len != exp_body_len) {
            std.debug.print("  candidate_body.cbor:    FAIL (size={d}, expected {d})\n", .{ body.len, exp_body_len });
            checks_total += 1;
        } else {
            std.debug.print("  candidate_body.cbor:    ok ({d} bytes)\n", .{body.len});
            checks_total += 1;
            checks_pass += 1;
        }

        // 6. candidate_body_hash.bin
        const hash_data = readFileFromDir(alloc, pack_dir, "candidate_body_hash.bin");
        if (hash_data == null) {
            std.debug.print("  candidate_body_hash.bin: FAIL (not found)\n", .{});
            checks_total += 1;
        } else {
            defer alloc.free(hash_data.?);
            const hash_bin = hash_data.?;
            if (hash_bin.len != 32) {
                std.debug.print("  candidate_body_hash.bin: FAIL (size={d}, expected 32)\n", .{hash_bin.len});
                checks_total += 1;
            } else {
                std.debug.print("  candidate_body_hash.bin: ok (32 bytes)\n", .{});
                checks_total += 1;
                checks_pass += 1;
            }

            // 7. Recompute body hash
            var body_recomputed: [32]u8 = undefined;
            Blake2b256.hash(body, &body_recomputed, .{});
            if (hash_bin.len == 32 and std.mem.eql(u8, &body_recomputed, hash_bin[0..32])) {
                std.debug.print("  body hash recompute:    ok (match body_hash.bin)\n", .{});
                checks_total += 1;
                checks_pass += 1;
            } else {
                std.debug.print("  body hash recompute:    FAIL (mismatch vs body_hash.bin)\n", .{});
                checks_total += 1;
            }

            // 8. Body hash vs pack.json
            if (exp_body_hash_hex) |expected_hex| {
                var body_hex: [64]u8 = undefined;
                hexEncodeBytes(&body_hex, &body_recomputed);
                if (std.mem.eql(u8, &body_hex, expected_hex)) {
                    std.debug.print("  body hash vs pack.json: ok (match)\n", .{});
                    checks_total += 1;
                    checks_pass += 1;
                } else {
                    std.debug.print("  body hash vs pack.json: FAIL (mismatch)\n", .{});
                    std.debug.print("    expected: {s}\n", .{expected_hex});
                    std.debug.print("    got:      {s}\n", .{&body_hex});
                    checks_total += 1;
                }
            }
        }
    }

    // 9. VRF proof (presence/length check only)
    if (exp_vrf_proof_len > 0) {
        const vrf_data = readFileFromDir(alloc, pack_dir, "vrf_proof.bin");
        if (vrf_data == null) {
            std.debug.print("  vrf_proof.bin:          FAIL (not found, expected {d} bytes)\n", .{exp_vrf_proof_len});
            checks_total += 1;
        } else {
            defer alloc.free(vrf_data.?);
            if (vrf_data.?.len != exp_vrf_proof_len) {
                std.debug.print("  vrf_proof.bin:          FAIL (size={d}, expected {d})\n", .{ vrf_data.?.len, exp_vrf_proof_len });
                checks_total += 1;
            } else {
                std.debug.print("  vrf_proof.bin:          ok ({d} bytes)\n", .{vrf_data.?.len});
                checks_total += 1;
                checks_pass += 1;
            }
        }
    }

    // 10. VRF output
    if (exp_vrf_output_len > 0) {
        const vrf_out = readFileFromDir(alloc, pack_dir, "vrf_output.bin");
        if (vrf_out == null) {
            std.debug.print("  vrf_output.bin:         FAIL (not found, expected {d} bytes)\n", .{exp_vrf_output_len});
            checks_total += 1;
        } else {
            defer alloc.free(vrf_out.?);
            if (vrf_out.?.len != exp_vrf_output_len) {
                std.debug.print("  vrf_output.bin:         FAIL (size={d}, expected {d})\n", .{ vrf_out.?.len, exp_vrf_output_len });
                checks_total += 1;
            } else {
                std.debug.print("  vrf_output.bin:         ok ({d} bytes)\n", .{vrf_out.?.len});
                checks_total += 1;
                checks_pass += 1;
            }
        }
    }

    // 11. Signature
    if (exp_sig_len > 0) {
        const sig_data = readFileFromDir(alloc, pack_dir, "candidate_sig_64.bin");
        if (sig_data == null) {
            std.debug.print("  candidate_sig_64.bin:   FAIL (not found, expected {d} bytes)\n", .{exp_sig_len});
            checks_total += 1;
        } else {
            defer alloc.free(sig_data.?);
            if (sig_data.?.len != exp_sig_len) {
                std.debug.print("  candidate_sig_64.bin:   FAIL (size={d}, expected {d})\n", .{ sig_data.?.len, exp_sig_len });
                checks_total += 1;
            } else {
                std.debug.print("  candidate_sig_64.bin:   ok ({d} bytes)\n", .{sig_data.?.len});
                checks_total += 1;
                checks_pass += 1;
            }
        }
    }

    // === V2+ checks (per-file hashes + invariants) ===
    var crypto_ok: u32 = 0;
    if (version >= 2) {
        std.debug.print("\n  --- v2 checks ---\n", .{});

        // 12. Per-file hash verification from "files" array
        {
            var scan_pos: usize = 0;
            // Find "files":[ to start scanning
            if (std.mem.indexOf(u8, json, "\"files\":[")) |fp| {
                scan_pos = fp;
            }
            while (parseFileEntry(json, scan_pos)) |entry| {
                scan_pos = entry.end_pos;
                // Read the file
                const file_data = readFileFromDir(alloc, pack_dir, entry.name);
                if (file_data == null) {
                    std.debug.print("  file {s}: FAIL (not found)\n", .{entry.name});
                    checks_total += 1;
                    continue;
                }
                defer alloc.free(file_data.?);
                const fd = file_data.?;
                // Check size
                if (fd.len != entry.size) {
                    std.debug.print("  file {s}: FAIL (size={d}, expected {d})\n", .{ entry.name, fd.len, entry.size });
                    checks_total += 1;
                    continue;
                }
                files_ok += 1;
                // Check hash
                var computed_hash: [64]u8 = undefined;
                hashAndHex(&computed_hash, fd);
                if (entry.hash_hex.len == 64 and std.mem.eql(u8, &computed_hash, entry.hash_hex)) {
                    std.debug.print("  file {s}: ok (size={d}, hash match)\n", .{ entry.name, fd.len });
                    checks_total += 1;
                    checks_pass += 1;
                    hashes_ok += 1;
                } else {
                    std.debug.print("  file {s}: FAIL (hash mismatch)\n", .{entry.name});
                    std.debug.print("    expected: {s}\n", .{entry.hash_hex});
                    std.debug.print("    got:      {s}\n", .{&computed_hash});
                    checks_total += 1;
                }
            }
        }

        // 13. Safety invariants
        {
            const no_forging = findJsonBoolTrue(json, "no_forging");
            const no_broadcast = findJsonBoolTrue(json, "no_broadcast");
            if (no_forging and no_broadcast) {
                std.debug.print("  safety invariants:      ok (no_forging=true, no_broadcast=true)\n", .{});
                checks_total += 1;
                checks_pass += 1;
                invariants_ok += 1;
            } else {
                std.debug.print("  safety invariants:      FAIL (no_forging={}, no_broadcast={})\n", .{ no_forging, no_broadcast });
                checks_total += 1;
            }
        }
    }

    // === V3-only checks: cryptographic verification ===
    if (version >= 3) {
        std.debug.print("\n  --- v3 crypto checks ---\n", .{});

        // Read files needed for crypto checks
        const v3_vrf_pk_data = readFileFromDir(alloc, pack_dir, "vrf_pk.bin");
        defer if (v3_vrf_pk_data) |d| alloc.free(d);
        const v3_vrf_proof_data = readFileFromDir(alloc, pack_dir, "vrf_proof.bin");
        defer if (v3_vrf_proof_data) |d| alloc.free(d);
        const v3_vrf_output_data = readFileFromDir(alloc, pack_dir, "vrf_output.bin");
        defer if (v3_vrf_output_data) |d| alloc.free(d);
        const v3_kes_pk_data = readFileFromDir(alloc, pack_dir, "kes_pk.bin");
        defer if (v3_kes_pk_data) |d| alloc.free(d);
        const v3_sig_data = readFileFromDir(alloc, pack_dir, "candidate_sig_64.bin");
        defer if (v3_sig_data) |d| alloc.free(d);
        const v3_hdr_data = readFileFromDir(alloc, pack_dir, "candidate_hdr_198.bin");
        defer if (v3_hdr_data) |d| alloc.free(d);

        // 14. VRF proof verification
        vrf_verify_blk: {
            if (v3_vrf_pk_data == null or v3_vrf_pk_data.?.len != 32) {
                std.debug.print("  vrf proof verify:       skip (vrf_pk.bin absent or wrong size)\n", .{});
                break :vrf_verify_blk;
            }
            if (v3_vrf_proof_data == null or v3_vrf_proof_data.?.len != 80) {
                std.debug.print("  vrf proof verify:       skip (vrf_proof.bin absent or wrong size)\n", .{});
                break :vrf_verify_blk;
            }
            if (v3_vrf_output_data == null or v3_vrf_output_data.?.len != 64) {
                std.debug.print("  vrf proof verify:       skip (vrf_output.bin absent or wrong size)\n", .{});
                break :vrf_verify_blk;
            }
            // Check if pk is all zeros (not configured)
            var pk_zero = true;
            for (v3_vrf_pk_data.?) |b| {
                if (b != 0) { pk_zero = false; break; }
            }
            if (pk_zero) {
                std.debug.print("  vrf proof verify:       skip (vrf_pk all zeros)\n", .{});
                break :vrf_verify_blk;
            }

            // Init libsodium
            if (!sodium_vrf.sodiumInit()) {
                std.debug.print("  vrf proof verify:       FAIL (sodium init failed)\n", .{});
                checks_total += 1;
                break :vrf_verify_blk;
            }

            // Build VRF input message: epoch(u64 BE) || slot(u64 BE)
            const vrf_input_epoch = findJsonNumValue(json, "input_epoch") orelse 0;
            const vrf_input_slot = findJsonNumValue(json, "input_slot") orelse 0;
            var vrf_msg: [16]u8 = undefined;
            std.mem.writeInt(u64, vrf_msg[0..8], vrf_input_epoch, .big);
            std.mem.writeInt(u64, vrf_msg[8..16], vrf_input_slot, .big);

            const pk_ptr: *const [32]u8 = @ptrCast(v3_vrf_pk_data.?.ptr);
            const proof_ptr: *const [80]u8 = @ptrCast(v3_vrf_proof_data.?.ptr);

            const verify_result = sodium_vrf.verify(pk_ptr, proof_ptr, &vrf_msg);
            if (verify_result) |vr| {
                // Compare output with vrf_output.bin
                if (std.mem.eql(u8, &vr.output, v3_vrf_output_data.?[0..64])) {
                    std.debug.print("  vrf proof verify:       ok (proof valid, output match)\n", .{});
                    checks_total += 1;
                    checks_pass += 1;
                    crypto_ok += 1;
                } else {
                    std.debug.print("  vrf proof verify:       FAIL (proof valid but output mismatch)\n", .{});
                    checks_total += 1;
                }
            } else {
                std.debug.print("  vrf proof verify:       FAIL (proof invalid)\n", .{});
                checks_total += 1;
            }
        }

        // 15. Praos re-evaluation
        praos_reeval_blk: {
            if (v3_vrf_output_data == null or v3_vrf_output_data.?.len != 64) {
                std.debug.print("  praos re-eval:          skip (vrf_output.bin absent)\n", .{});
                break :praos_reeval_blk;
            }

            const ps_stake = findJsonNumValue(json, "stake_fraction_x1e9") orelse 0;
            const ps_asc = findJsonNumValue(json, "asc_x1e6") orelse 0;
            if (ps_stake == 0 or ps_asc == 0) {
                std.debug.print("  praos re-eval:          skip (stake=0 or asc=0)\n", .{});
                break :praos_reeval_blk;
            }

            // Recompute u_x1e12
            var vrf_out_bytes: [64]u8 = undefined;
            @memcpy(&vrf_out_bytes, v3_vrf_output_data.?[0..64]);
            const recomp_u = producer.vrfOutputToU_x1e12(vrf_out_bytes);

            // Recompute threshold (same u128 math as producer.zig)
            const f_x1e12: u128 = @as(u128, ps_asc) * 1_000_000;
            const sigma_x1e12: u128 = @as(u128, ps_stake) * 1_000;
            const thresh_128: u128 = (f_x1e12 * sigma_x1e12) / 1_000_000_000_000;
            const recomp_t: u64 = @intCast(@min(thresh_128, 1_000_000_000_000));
            const recomp_leader: u64 = if (recomp_u < recomp_t) 1 else 0;

            // Compare with pack.json values
            const exp_u = findJsonNumValue(json, "u_x1e12") orelse 0;
            const exp_t = findJsonNumValue(json, "thresh_x1e12") orelse 0;
            const exp_leader = findJsonNumValue(json, "leader") orelse 0;

            if (recomp_u == exp_u and recomp_t == exp_t and recomp_leader == exp_leader) {
                std.debug.print("  praos re-eval:          ok (u={d}, T={d}, leader={d})\n", .{ recomp_u, recomp_t, recomp_leader });
                checks_total += 1;
                checks_pass += 1;
                crypto_ok += 1;
            } else {
                std.debug.print("  praos re-eval:          FAIL\n", .{});
                std.debug.print("    u_x1e12:    computed={d} expected={d}\n", .{ recomp_u, exp_u });
                std.debug.print("    thresh:     computed={d} expected={d}\n", .{ recomp_t, exp_t });
                std.debug.print("    leader:     computed={d} expected={d}\n", .{ recomp_leader, exp_leader });
                checks_total += 1;
            }
        }

        // 16. KES signature verification (Ed25519)
        kes_verify_blk: {
            if (v3_kes_pk_data == null or v3_kes_pk_data.?.len != 32) {
                std.debug.print("  kes sig verify:         skip (kes_pk.bin absent or wrong size)\n", .{});
                break :kes_verify_blk;
            }
            if (v3_sig_data == null or v3_sig_data.?.len != 64) {
                std.debug.print("  kes sig verify:         skip (candidate_sig_64.bin absent or wrong size)\n", .{});
                break :kes_verify_blk;
            }
            if (v3_hdr_data == null or v3_hdr_data.?.len != 198) {
                std.debug.print("  kes sig verify:         skip (candidate_hdr_198.bin absent or wrong size)\n", .{});
                break :kes_verify_blk;
            }
            // Check if pk is all zeros (not configured)
            var kes_pk_zero = true;
            for (v3_kes_pk_data.?) |b| {
                if (b != 0) { kes_pk_zero = false; break; }
            }
            if (kes_pk_zero) {
                std.debug.print("  kes sig verify:         skip (kes_pk all zeros)\n", .{});
                break :kes_verify_blk;
            }

            const sig_bytes_arr: [64]u8 = v3_sig_data.?[0..64].*;
            const sig = Ed25519.Signature.fromBytes(sig_bytes_arr);
            const pk_bytes_arr: [32]u8 = v3_kes_pk_data.?[0..32].*;
            const pubkey = Ed25519.PublicKey.fromBytes(pk_bytes_arr) catch {
                std.debug.print("  kes sig verify:         FAIL (invalid public key)\n", .{});
                checks_total += 1;
                break :kes_verify_blk;
            };

            sig.verify(v3_hdr_data.?[0..198], pubkey) catch {
                std.debug.print("  kes sig verify:         FAIL (signature invalid)\n", .{});
                checks_total += 1;
                break :kes_verify_blk;
            };

            std.debug.print("  kes sig verify:         ok (Ed25519 signature valid)\n", .{});
            checks_total += 1;
            checks_pass += 1;
            crypto_ok += 1;
        }
    }

    printSummary(checks_pass, checks_total, files_ok, hashes_ok, crypto_ok, invariants_ok);
    return if (checks_pass == checks_total) 0 else 1;
}

fn printSummary(pass: u32, total: u32, files_ok: u32, hashes_ok: u32, crypto_ok_count: u32, invariants_ok: u32) void {
    if (pass == total) {
        std.debug.print("\n=== Pack Verify: PASS ({d}/{d} checks", .{ pass, total });
    } else {
        std.debug.print("\n=== Pack Verify: FAIL ({d}/{d} checks", .{ pass, total });
    }
    if (files_ok > 0 or hashes_ok > 0 or crypto_ok_count > 0 or invariants_ok > 0) {
        std.debug.print(", files_ok={d}, hashes_ok={d}, crypto_ok={d}, invariants_ok={d}", .{ files_ok, hashes_ok, crypto_ok_count, invariants_ok });
    }
    std.debug.print(") ===\n", .{});
}
