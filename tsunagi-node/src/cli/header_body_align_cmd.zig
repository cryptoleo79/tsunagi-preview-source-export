const std = @import("std");
const compat = @import("compat");
const cbor_hdr_body = @import("../producer/cbor_block_header_body.zig");

/// Header-body alignment CLI (Phase A verification).
///
/// For each vector extracted from real chain captures:
///   1) Parse all header body fields from the JSONL vector.
///   2) Reconstruct header_body CBOR using our builder (cbor_block_header_body.zig).
///   3) Compare byte-for-byte against header_body_cbor_hex.
///   4) Additionally verify prev_hash and body_hash extraction.
///
/// Fail-fast on first mismatch (exit 2).
/// Exit codes: 0=all match, 2=mismatch, 3=parse/file/IO error.

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

    std.debug.print("=== Header-Body Alignment (Phase A) ===\n\n", .{});

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

        const vec = parseVector(content) orelse {
            std.debug.print("ERROR: cannot parse vector at line {d}\n", .{total + 1});
            return 3;
        };

        // Reconstruct header body CBOR using our builder
        const built = cbor_hdr_body.buildHeaderBodyCborV2(
            vec.block_no,
            vec.slot,
            vec.prev_hash,
            vec.issuer_vk,
            vec.vrf_vkey,
            vec.vrf_output,
            vec.vrf_proof,
            vec.block_body_size,
            vec.body_hash,
            .{
                .hot_vk = vec.opcert_hot_vk,
                .seq_no = vec.opcert_seq_no,
                .kes_period = vec.opcert_kes_period,
                .sigma = vec.opcert_sigma,
            },
            .{ .major = vec.pv_major, .minor = vec.pv_minor },
        );

        // Compare byte-for-byte
        const built_bytes = built.bytes[0..built.len];
        const expected_bytes = vec.header_body_cbor[0..vec.header_body_cbor_len];

        const bytes_match = built.len == vec.header_body_cbor_len and
            std.mem.eql(u8, built_bytes, expected_bytes);

        if (bytes_match) {
            std.debug.print("  vector[{d}]: slot={d} block_no={d} {d} bytes PASS\n", .{
                total, vec.slot, vec.block_no, built.len,
            });
        } else {
            std.debug.print("  vector[{d}]: slot={d} block_no={d} FAIL\n", .{
                total, vec.slot, vec.block_no,
            });
            std.debug.print("    built:    {d} bytes\n", .{built.len});
            std.debug.print("    expected: {d} bytes\n", .{vec.header_body_cbor_len});
            if (built.len > 0 and vec.header_body_cbor_len > 0) {
                // Find first mismatch byte
                const min_len = @min(built.len, vec.header_body_cbor_len);
                for (0..min_len) |i| {
                    if (built_bytes[i] != expected_bytes[i]) {
                        std.debug.print("    first diff at byte {d}: built=0x{x:0>2} expected=0x{x:0>2}\n", .{
                            i, built_bytes[i], expected_bytes[i],
                        });
                        break;
                    }
                }
            }
            mismatches += 1;
            // Fail-fast
            std.debug.print("\nHEADER-BODY-ALIGN: vectors={d} mismatches={d} EXIT=2\n", .{ total + 1, mismatches });
            return 2;
        }

        total += 1;
    }

    if (total == 0) {
        std.debug.print("ERROR: no vectors found in {s}\n", .{path});
        return 3;
    }

    const exit_code: u8 = if (mismatches > 0) 2 else 0;
    std.debug.print("\nHEADER-BODY-ALIGN: vectors={d} mismatches={d} EXIT={d}\n", .{ total, mismatches, exit_code });
    return exit_code;
}

// ── Parsed vector ─────────────────────────────────────────────────────

const ParsedVector = struct {
    slot: u64,
    block_no: u64,
    prev_hash: [32]u8,
    body_hash: [32]u8,
    issuer_vk: [32]u8,
    vrf_vkey: [32]u8,
    vrf_output: [64]u8,
    vrf_proof: [80]u8,
    block_body_size: u64,
    opcert_hot_vk: [32]u8,
    opcert_seq_no: u64,
    opcert_kes_period: u64,
    opcert_sigma: [64]u8,
    pv_major: u64,
    pv_minor: u64,
    header_body_cbor: [1024]u8,
    header_body_cbor_len: usize,
};

fn parseVector(line: []const u8) ?ParsedVector {
    // We parse the header_body_cbor_hex and decode all fields from it,
    // since the JSONL only has the hex-encoded CBOR and a few extracted fields.
    const cbor_hex = parseHexField(line, "\"header_body_cbor_hex\":\"") orelse return null;
    if (cbor_hex.len < 2 or cbor_hex.len > 2048 or cbor_hex.len % 2 != 0) return null;

    const cbor_len = cbor_hex.len / 2;
    var cbor_bytes: [1024]u8 = undefined;
    if (!hexToBytes(cbor_hex, cbor_bytes[0..cbor_len])) return null;

    // Parse the 10-element CBOR array to extract all fields
    var pos: usize = 0;

    // array(10) header
    const arr_hdr = readCborHdr(cbor_bytes[0..cbor_len], pos) orelse return null;
    if (arr_hdr.major != 4 or arr_hdr.value != 10) return null;
    pos = arr_hdr.new_pos;

    // [0] block_number
    const block_no_r = readCborUint(cbor_bytes[0..cbor_len], pos) orelse return null;
    pos = block_no_r.new_pos;

    // [1] slot
    const slot_r = readCborUint(cbor_bytes[0..cbor_len], pos) orelse return null;
    pos = slot_r.new_pos;

    // [2] prev_hash: bstr(32)
    const prev_hash_r = readCborBytes32(cbor_bytes[0..cbor_len], pos) orelse return null;
    pos = prev_hash_r.new_pos;

    // [3] issuer_vk: bstr(32)
    const issuer_vk_r = readCborBytes32(cbor_bytes[0..cbor_len], pos) orelse return null;
    pos = issuer_vk_r.new_pos;

    // [4] vrf_vkey: bstr(32)
    const vrf_vkey_r = readCborBytes32(cbor_bytes[0..cbor_len], pos) orelse return null;
    pos = vrf_vkey_r.new_pos;

    // [5] vrf_result: array(2)
    const vrf_arr = readCborHdr(cbor_bytes[0..cbor_len], pos) orelse return null;
    if (vrf_arr.major != 4 or vrf_arr.value != 2) return null;
    pos = vrf_arr.new_pos;

    // vrf_output: bstr(64)
    const vrf_out_r = readCborBytesN(cbor_bytes[0..cbor_len], pos, 64) orelse return null;
    pos = vrf_out_r.new_pos;
    var vrf_output: [64]u8 = undefined;
    @memcpy(&vrf_output, vrf_out_r.data[0..64]);

    // vrf_proof: bstr(80)
    const vrf_proof_r = readCborBytesN(cbor_bytes[0..cbor_len], pos, 80) orelse return null;
    pos = vrf_proof_r.new_pos;
    var vrf_proof: [80]u8 = undefined;
    @memcpy(&vrf_proof, vrf_proof_r.data[0..80]);

    // [6] block_body_size
    const body_size_r = readCborUint(cbor_bytes[0..cbor_len], pos) orelse return null;
    pos = body_size_r.new_pos;

    // [7] block_body_hash: bstr(32)
    const body_hash_r = readCborBytes32(cbor_bytes[0..cbor_len], pos) orelse return null;
    pos = body_hash_r.new_pos;

    // [8] operational_cert: array(4)
    const opcert_arr = readCborHdr(cbor_bytes[0..cbor_len], pos) orelse return null;
    if (opcert_arr.major != 4 or opcert_arr.value != 4) return null;
    pos = opcert_arr.new_pos;

    // hot_vk: bstr(32)
    const hot_vk_r = readCborBytes32(cbor_bytes[0..cbor_len], pos) orelse return null;
    pos = hot_vk_r.new_pos;

    // seq_no: uint
    const seq_no_r = readCborUint(cbor_bytes[0..cbor_len], pos) orelse return null;
    pos = seq_no_r.new_pos;

    // kes_period: uint
    const kes_period_r = readCborUint(cbor_bytes[0..cbor_len], pos) orelse return null;
    pos = kes_period_r.new_pos;

    // sigma: bstr(64)
    const sigma_r = readCborBytesN(cbor_bytes[0..cbor_len], pos, 64) orelse return null;
    pos = sigma_r.new_pos;
    var opcert_sigma: [64]u8 = undefined;
    @memcpy(&opcert_sigma, sigma_r.data[0..64]);

    // [9] protocol_version: array(2)
    const pv_arr = readCborHdr(cbor_bytes[0..cbor_len], pos) orelse return null;
    if (pv_arr.major != 4 or pv_arr.value != 2) return null;
    pos = pv_arr.new_pos;

    const pv_major_r = readCborUint(cbor_bytes[0..cbor_len], pos) orelse return null;
    pos = pv_major_r.new_pos;

    const pv_minor_r = readCborUint(cbor_bytes[0..cbor_len], pos) orelse return null;

    return ParsedVector{
        .slot = slot_r.value,
        .block_no = block_no_r.value,
        .prev_hash = prev_hash_r.data,
        .body_hash = body_hash_r.data,
        .issuer_vk = issuer_vk_r.data,
        .vrf_vkey = vrf_vkey_r.data,
        .vrf_output = vrf_output,
        .vrf_proof = vrf_proof,
        .block_body_size = body_size_r.value,
        .opcert_hot_vk = hot_vk_r.data,
        .opcert_seq_no = seq_no_r.value,
        .opcert_kes_period = kes_period_r.value,
        .opcert_sigma = opcert_sigma,
        .pv_major = pv_major_r.value,
        .pv_minor = pv_minor_r.value,
        .header_body_cbor = cbor_bytes,
        .header_body_cbor_len = cbor_len,
    };
}

// ── CBOR reading helpers ──────────────────────────────────────────────

const CborHdrResult = struct { major: u3, value: usize, new_pos: usize };
const CborUintResult = struct { value: u64, new_pos: usize };
const CborBytes32Result = struct { data: [32]u8, new_pos: usize };
const CborBytesNResult = struct { data: [128]u8, len: usize, new_pos: usize };

fn readCborHdr(bytes: []const u8, pos: usize) ?CborHdrResult {
    if (pos >= bytes.len) return null;
    const initial = bytes[pos];
    const major: u3 = @truncate(initial >> 5);
    const addl: u5 = @truncate(initial & 0x1f);

    if (addl < 24) return .{ .major = major, .value = addl, .new_pos = pos + 1 };
    if (addl == 24 and pos + 1 < bytes.len) return .{ .major = major, .value = bytes[pos + 1], .new_pos = pos + 2 };
    if (addl == 25 and pos + 2 < bytes.len) {
        return .{ .major = major, .value = (@as(usize, bytes[pos + 1]) << 8) | bytes[pos + 2], .new_pos = pos + 3 };
    }
    if (addl == 26 and pos + 4 < bytes.len) {
        return .{ .major = major, .value = (@as(usize, bytes[pos + 1]) << 24) | (@as(usize, bytes[pos + 2]) << 16) | (@as(usize, bytes[pos + 3]) << 8) | bytes[pos + 4], .new_pos = pos + 5 };
    }
    if (addl == 27 and pos + 8 < bytes.len) {
        var val: u64 = 0;
        for (1..9) |i| {
            val = (val << 8) | bytes[pos + i];
        }
        return .{ .major = major, .value = @truncate(val), .new_pos = pos + 9 };
    }
    return null;
}

fn readCborUint(bytes: []const u8, pos: usize) ?CborUintResult {
    const hdr = readCborHdr(bytes, pos) orelse return null;
    if (hdr.major != 0) return null;
    return .{ .value = @intCast(hdr.value), .new_pos = hdr.new_pos };
}

fn readCborBytes32(bytes: []const u8, pos: usize) ?CborBytes32Result {
    const hdr = readCborHdr(bytes, pos) orelse return null;
    if (hdr.major != 2 or hdr.value != 32) return null;
    if (hdr.new_pos + 32 > bytes.len) return null;
    var data: [32]u8 = undefined;
    @memcpy(&data, bytes[hdr.new_pos..][0..32]);
    return .{ .data = data, .new_pos = hdr.new_pos + 32 };
}

fn readCborBytesN(bytes: []const u8, pos: usize, n: usize) ?CborBytesNResult {
    const hdr = readCborHdr(bytes, pos) orelse return null;
    if (hdr.major != 2 or hdr.value != n) return null;
    if (hdr.new_pos + n > bytes.len) return null;
    var data: [128]u8 = [_]u8{0} ** 128;
    @memcpy(data[0..n], bytes[hdr.new_pos..][0..n]);
    return .{ .data = data, .len = n, .new_pos = hdr.new_pos + n };
}

// ── Hex utilities ─────────────────────────────────────────────────────

fn parseHexField(json: []const u8, needle: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const val_start = start + needle.len;
    const end = std.mem.indexOfPos(u8, json, val_start, "\"") orelse return null;
    if (end == val_start) return null;
    return json[val_start..end];
}

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
