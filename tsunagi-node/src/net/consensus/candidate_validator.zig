const std = @import("std");
const compat = @import("compat");
const block_hash = @import("../ledger/block_hash.zig");
const kes_verify = @import("../../producer/crypto/kes_verify.zig");
const sodium_vrf = @import("../../producer/crypto/sodium_vrf.zig");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

// ── Types ──

pub const ValidationState = enum {
    valid,
    invalid_structure,
    invalid_hash,
    invalid_signature,
    invalid_consistency,
    error_state,
};

pub const ValidationReport = struct {
    state: ValidationState,

    header_cbor_ok: bool,
    block_cbor_ok: bool,

    header_hash_ok: bool,
    body_hash_ok: bool,
    block_hash_ok: bool,

    kes_signature_ok: bool,
    consistency_ok: bool,

    expected_header_hash_hex: [64]u8,
    actual_header_hash_hex: [64]u8,

    expected_body_hash_hex: [64]u8,
    actual_body_hash_hex: [64]u8,

    kes_verify_detail: kes_verify.KesVerifyResult,
};

// ── Public API ──

/// Validate a shadow-produced candidate artifact bundle.
///
/// Inputs:
///   header_cbor  — raw Cardano header CBOR bytes: [header_body, bstr(448)]
///   block_cbor   — raw full block CBOR bytes: [era, [header, tx_bodies, ...]]
///   expected_block_hash — 32-byte expected blake2b256(header_cbor)
///   expected_body_hash  — 32-byte expected merkle-style body hash
///
/// All checks are pure computation. No IO, no allocation.
pub fn validate(
    header_cbor: []const u8,
    block_cbor: []const u8,
    expected_block_hash: [32]u8,
    expected_body_hash: [32]u8,
) ValidationReport {
    var report = ValidationReport{
        .state = .valid,
        .header_cbor_ok = false,
        .block_cbor_ok = false,
        .header_hash_ok = false,
        .body_hash_ok = false,
        .block_hash_ok = false,
        .kes_signature_ok = false,
        .consistency_ok = false,
        .expected_header_hash_hex = hexEncode(expected_block_hash),
        .actual_header_hash_hex = [_]u8{'0'} ** 64,
        .expected_body_hash_hex = hexEncode(expected_body_hash),
        .actual_body_hash_hex = [_]u8{'0'} ** 64,
        .kes_verify_detail = .bad_sig_len,
    };

    // CHECK 1: header CBOR structure — parse as [header_body, kes_sig]
    const header_split = splitHeaderCbor(header_cbor) orelse {
        report.state = .invalid_structure;
        return report;
    };
    report.header_cbor_ok = true;

    // CHECK 2: header hash = blake2b256(header_cbor) matches expected_block_hash
    const actual_header_hash = block_hash.blake2b256(header_cbor);
    report.actual_header_hash_hex = hexEncode(actual_header_hash);
    report.header_hash_ok = std.mem.eql(u8, &actual_header_hash, &expected_block_hash);
    if (!report.header_hash_ok) {
        report.state = .invalid_hash;
        report.block_hash_ok = false;
        // Continue remaining checks for diagnostic completeness
    } else {
        report.block_hash_ok = true;
    }

    // CHECK 3: block CBOR structure — extractBodyParts validates structure
    const body_parts = block_hash.extractBodyParts(block_cbor) orelse {
        if (report.state == .valid) report.state = .invalid_structure;
        return report;
    };
    report.block_cbor_ok = true;

    // CHECK 4: body hash = computeBodyHash(parts) matches expected_body_hash
    const actual_body_hash = block_hash.computeBodyHash(body_parts);
    report.actual_body_hash_hex = hexEncode(actual_body_hash);
    report.body_hash_ok = std.mem.eql(u8, &actual_body_hash, &expected_body_hash);
    if (!report.body_hash_ok and report.state == .valid) {
        report.state = .invalid_hash;
    }

    // CHECK 5: header embedded in block matches provided header_cbor
    const header_region = extractHeaderRegion(block_cbor) orelse {
        if (report.state == .valid) report.state = .invalid_consistency;
        return report;
    };
    report.consistency_ok = (header_region.len == header_cbor.len and
        std.mem.eql(u8, header_region, header_cbor));
    if (!report.consistency_ok and report.state == .valid) {
        report.state = .invalid_consistency;
    }

    // CHECK 6: body hash committed in header_body matches computed body hash
    // Header body is a CBOR array; body_hash is at index 7 (Conway/Babbage 10-element)
    const committed_body_hash = extractBodyHashFromHeaderBody(header_split.header_body);
    if (committed_body_hash) |cbh| {
        if (!std.mem.eql(u8, &cbh, &actual_body_hash)) {
            if (report.state == .valid) report.state = .invalid_consistency;
            report.consistency_ok = false;
        }
    }
    // If extraction fails, skip — not all header formats may have it parseable
    // without the full CBOR decoder. The other checks still provide coverage.

    // CHECK 7: KES signature verification
    const opcert = extractOpCertFromHeaderBody(header_split.header_body);
    if (opcert) |oc| {
        const kes_result = kes_verify.verifySum6Kes(
            oc.kes_pk,
            oc.kes_period,
            header_split.header_body,
            header_split.kes_sig,
        );
        report.kes_verify_detail = kes_result;
        report.kes_signature_ok = (kes_result == .ok);
        if (!report.kes_signature_ok and report.state == .valid) {
            report.state = .invalid_signature;
        }
    } else {
        // Cannot extract OpCert — structural issue
        report.kes_verify_detail = .bad_pk_len;
        if (report.state == .valid) report.state = .invalid_signature;
    }

    return report;
}

/// Format a ValidationReport as a JSON string into the provided buffer.
/// Returns the formatted slice, or null if buffer is too small.
pub fn formatReportJson(report: *const ValidationReport, buf: []u8) ?[]const u8 {
    const state_label = switch (report.state) {
        .valid => "valid",
        .invalid_structure => "invalid_structure",
        .invalid_hash => "invalid_hash",
        .invalid_signature => "invalid_signature",
        .invalid_consistency => "invalid_consistency",
        .error_state => "error_state",
    };
    const kes_detail = kes_verify.resultStr(report.kes_verify_detail);

    const result = std.fmt.bufPrint(buf,
        \\{{"state":"{s}","header_cbor_ok":{s},"block_cbor_ok":{s},"header_hash_ok":{s},"body_hash_ok":{s},"block_hash_ok":{s},"kes_signature_ok":{s},"consistency_ok":{s},"expected_header_hash":"{s}","actual_header_hash":"{s}","expected_body_hash":"{s}","actual_body_hash":"{s}","kes_verify_detail":"{s}"}}
    , .{
        state_label,
        if (report.header_cbor_ok) "true" else "false",
        if (report.block_cbor_ok) "true" else "false",
        if (report.header_hash_ok) "true" else "false",
        if (report.body_hash_ok) "true" else "false",
        if (report.block_hash_ok) "true" else "false",
        if (report.kes_signature_ok) "true" else "false",
        if (report.consistency_ok) "true" else "false",
        report.expected_header_hash_hex[0..],
        report.actual_header_hash_hex[0..],
        report.expected_body_hash_hex[0..],
        report.actual_body_hash_hex[0..],
        kes_detail,
    }) catch return null;

    return result;
}

// ── Internal helpers ──

const HeaderSplit = struct {
    header_body: []const u8,
    kes_sig: []const u8,
};

/// Split header CBOR into [header_body, kes_sig].
/// Header CBOR is a 2-element CBOR array: array(2) [ header_body_cbor, bstr(448) ].
fn splitHeaderCbor(header_cbor: []const u8) ?HeaderSplit {
    if (header_cbor.len < 3) return null;

    // Must start with array(2): 0x82
    if (header_cbor[0] != 0x82) return null;

    // First element: header_body (a CBOR array itself)
    const body_size = block_hash.skipCborElement(header_cbor[1..]) orelse return null;
    const body_start: usize = 1;
    const body_end = body_start + body_size;
    if (body_end >= header_cbor.len) return null;

    // Second element: KES signature as bstr(448)
    const sig_start = body_end;
    const sig_size = block_hash.skipCborElement(header_cbor[sig_start..]) orelse return null;
    const sig_end = sig_start + sig_size;

    // The sig element is a CBOR bstr. Parse its header to get the raw bytes.
    const sig_raw = extractBstrPayload(header_cbor[sig_start..sig_end]) orelse return null;
    if (sig_raw.len != kes_verify.SUM6_KES_SIG_LEN) return null;

    return .{
        .header_body = header_cbor[body_start..body_end],
        .kes_sig = sig_raw,
    };
}

const OpCertInfo = struct {
    kes_pk: [32]u8,
    kes_period: u32,
};

/// Extract KES public key and period from header body CBOR.
/// Header body is a 10-element array (Conway/Babbage):
///   [0] block_number, [1] slot, [2] prev_hash, [3] issuer_vk,
///   [4] vrf_vkey, [5] vrf_result, [6] body_size, [7] body_hash,
///   [8] operational_cert, [9] protocol_version
/// OpCert at index 8 is: [hot_vk(32), seq_no, kes_period, sigma(64)]
fn extractOpCertFromHeaderBody(header_body: []const u8) ?OpCertInfo {
    if (header_body.len < 2) return null;

    // header_body is itself a CBOR array; parse its header
    const hdr = readCborHdr(header_body) orelse return null;
    if (hdr.major != 4) return null; // must be array
    if (hdr.value < 9) return null; // need at least 9 elements (up to opcert)

    // Skip elements 0..7 to reach index 8 (opcert)
    var pos: usize = hdr.hdr_len;
    var idx: usize = 0;
    while (idx < 8) : (idx += 1) {
        if (pos >= header_body.len) return null;
        const elem_size = block_hash.skipCborElement(header_body[pos..]) orelse return null;
        pos += elem_size;
    }

    // Now at opcert — must be array(4): [hot_vk, seq_no, kes_period, sigma]
    if (pos >= header_body.len) return null;
    const opcert_hdr = readCborHdr(header_body[pos..]) orelse return null;
    if (opcert_hdr.major != 4 or opcert_hdr.value < 3) return null;
    var opos = pos + opcert_hdr.hdr_len;

    // opcert[0] = hot_vk (bstr 32 bytes) — this is the KES root public key
    const hot_vk = extractBstrPayload(header_body[opos..]) orelse return null;
    if (hot_vk.len != 32) return null;
    var kes_pk: [32]u8 = undefined;
    @memcpy(&kes_pk, hot_vk[0..32]);

    const hot_vk_size = block_hash.skipCborElement(header_body[opos..]) orelse return null;
    opos += hot_vk_size;

    // opcert[1] = seq_no (uint) — skip
    if (opos >= header_body.len) return null;
    const seq_size = block_hash.skipCborElement(header_body[opos..]) orelse return null;
    opos += seq_size;

    // opcert[2] = kes_period (uint)
    if (opos >= header_body.len) return null;
    const period_hdr = readCborHdr(header_body[opos..]) orelse return null;
    if (period_hdr.major != 0) return null; // must be unsigned int
    // Guard the narrowing cast: attacker-supplied kes_period > maxInt(u32) would
    // panic (ReleaseSafe) or silently truncate (ReleaseFast). Real values are tiny.
    if (period_hdr.value > std.math.maxInt(u32)) return null;
    const kes_period: u32 = @intCast(period_hdr.value);

    return .{
        .kes_pk = kes_pk,
        .kes_period = kes_period,
    };
}

/// Extract body hash committed at index 7 of header body array.
/// Returns the 32-byte hash, or null if parsing fails.
fn extractBodyHashFromHeaderBody(header_body: []const u8) ?[32]u8 {
    if (header_body.len < 2) return null;

    const hdr = readCborHdr(header_body) orelse return null;
    if (hdr.major != 4) return null;
    if (hdr.value < 8) return null; // need at least 8 elements (up to body_hash at index 7)

    var pos: usize = hdr.hdr_len;
    var idx: usize = 0;
    while (idx < 7) : (idx += 1) {
        if (pos >= header_body.len) return null;
        const elem_size = block_hash.skipCborElement(header_body[pos..]) orelse return null;
        pos += elem_size;
    }

    // Index 7 = body_hash (bstr 32 bytes)
    if (pos >= header_body.len) return null;
    const bh = extractBstrPayload(header_body[pos..]) orelse return null;
    if (bh.len != 32) return null;
    var result: [32]u8 = undefined;
    @memcpy(&result, bh[0..32]);
    return result;
}

/// Extract the header CBOR region from full block bytes.
/// Block: array(2) [ era, array(5) [ header, tx_bodies, witnesses, aux_data, invalid_txs ] ]
fn extractHeaderRegion(block_bytes: []const u8) ?[]const u8 {
    if (block_bytes.len < 4) return null;
    var pos: usize = 0;

    // Outer array(2): 0x82
    if (block_bytes[pos] != 0x82) return null;
    pos += 1;

    // Skip era element
    const era_size = block_hash.skipCborElement(block_bytes[pos..]) orelse return null;
    pos += era_size;

    // Inner array (4 or 5 elements)
    if (pos >= block_bytes.len) return null;
    const inner_hdr = readCborHdr(block_bytes[pos..]) orelse return null;
    if (inner_hdr.major != 4 or inner_hdr.value < 4) return null;
    pos += inner_hdr.hdr_len;

    // Header element
    const header_start = pos;
    const header_size = block_hash.skipCborElement(block_bytes[pos..]) orelse return null;

    return block_bytes[header_start .. header_start + header_size];
}

/// Extract raw bytes payload from a CBOR byte string element.
fn extractBstrPayload(bytes: []const u8) ?[]const u8 {
    if (bytes.len == 0) return null;
    const hdr = readCborHdr(bytes) orelse return null;
    if (hdr.major != 2) return null; // must be bstr (major type 2)
    if (hdr.hdr_len + hdr.value > bytes.len) return null;
    return bytes[hdr.hdr_len .. hdr.hdr_len + hdr.value];
}

fn hexEncode(data: [32]u8) [64]u8 {
    return std.fmt.bytesToHex(data, .lower);
}

// Local copy of readCborHdr to avoid depending on block_hash private fn.
const CborHdr = struct {
    major: u3,
    hdr_len: usize,
    value: usize,
};

fn readCborHdr(bytes: []const u8) ?CborHdr {
    if (bytes.len == 0) return null;
    const initial = bytes[0];
    const major: u3 = @truncate(initial >> 5);
    const addl: u5 = @truncate(initial & 0x1f);

    if (addl < 24) return .{ .major = major, .hdr_len = 1, .value = addl };
    if (addl == 24 and bytes.len >= 2) return .{ .major = major, .hdr_len = 2, .value = bytes[1] };
    if (addl == 25 and bytes.len >= 3) return .{ .major = major, .hdr_len = 3, .value = (@as(usize, bytes[1]) << 8) | bytes[2] };
    if (addl == 26 and bytes.len >= 5) return .{ .major = major, .hdr_len = 5, .value = (@as(usize, bytes[1]) << 24) | (@as(usize, bytes[2]) << 16) | (@as(usize, bytes[3]) << 8) | bytes[4] };
    if (addl == 27 and bytes.len >= 9) {
        var val: u64 = 0;
        for (1..9) |i| {
            val = (val << 8) | bytes[i];
        }
        return .{ .major = major, .hdr_len = 9, .value = @truncate(val) };
    }
    return null;
}

// ── Inline Tests ──

test "splitHeaderCbor: valid 2-element array" {
    // Build a minimal header: array(2) [ array(1)[uint(42)], bstr(448) ]
    // array(1)[uint(42)] = 0x81 0x18 0x2a (3 bytes)
    // bstr(448) = 0x59 0x01 0xc0 + 448 zero bytes (451 bytes)
    var buf: [512]u8 = undefined;
    buf[0] = 0x82; // array(2)
    buf[1] = 0x81; // array(1)
    buf[2] = 0x18; // uint following byte
    buf[3] = 0x2a; // 42
    buf[4] = 0x59; // bstr 2-byte length
    buf[5] = 0x01;
    buf[6] = 0xc0; // 448
    @memset(buf[7..455], 0xab); // 448 bytes of sig data

    const result = splitHeaderCbor(buf[0..455]);
    try std.testing.expect(result != null);
    const split = result.?;
    try std.testing.expectEqual(@as(usize, 3), split.header_body.len);
    try std.testing.expectEqual(@as(usize, 448), split.kes_sig.len);
    try std.testing.expectEqual(@as(u8, 0xab), split.kes_sig[0]);
}

test "splitHeaderCbor: rejects non-array" {
    var buf = [_]u8{0x00}; // uint 0, not an array
    try std.testing.expect(splitHeaderCbor(&buf) == null);
}

test "splitHeaderCbor: rejects wrong sig length" {
    // array(2) [ uint(1), bstr(32) ] — sig too short
    var buf: [64]u8 = undefined;
    buf[0] = 0x82; // array(2)
    buf[1] = 0x01; // uint(1)
    buf[2] = 0x58; // bstr 1-byte length
    buf[3] = 0x20; // 32 bytes
    @memset(buf[4..36], 0);

    try std.testing.expect(splitHeaderCbor(buf[0..36]) == null);
}

test "extractOpCertFromHeaderBody: valid 10-element header body" {
    // Build: array(10) [ 0,0,bstr(32),bstr(32),bstr(32),[bstr(64),bstr(80)],0,bstr(32), [bstr(32),0,5,bstr(64)], [9,0] ]
    // We need to reach index 8 (opcert). Minimal encoding:
    var buf: [512]u8 = undefined;
    var off: usize = 0;

    // array(10)
    buf[off] = 0x8a;
    off += 1;

    // [0] block_number = 0
    buf[off] = 0x00;
    off += 1;

    // [1] slot = 0
    buf[off] = 0x00;
    off += 1;

    // [2] prev_hash = bstr(32)
    buf[off] = 0x58;
    buf[off + 1] = 0x20;
    off += 2;
    @memset(buf[off .. off + 32], 0x11);
    off += 32;

    // [3] issuer_vk = bstr(32)
    buf[off] = 0x58;
    buf[off + 1] = 0x20;
    off += 2;
    @memset(buf[off .. off + 32], 0x22);
    off += 32;

    // [4] vrf_vkey = bstr(32)
    buf[off] = 0x58;
    buf[off + 1] = 0x20;
    off += 2;
    @memset(buf[off .. off + 32], 0x33);
    off += 32;

    // [5] vrf_result = array(2) [bstr(64), bstr(80)]
    buf[off] = 0x82; // array(2)
    off += 1;
    buf[off] = 0x58;
    buf[off + 1] = 0x40; // bstr(64)
    off += 2;
    @memset(buf[off .. off + 64], 0x44);
    off += 64;
    buf[off] = 0x58;
    buf[off + 1] = 0x50; // bstr(80)
    off += 2;
    @memset(buf[off .. off + 80], 0x55);
    off += 80;

    // [6] body_size = 0
    buf[off] = 0x00;
    off += 1;

    // [7] body_hash = bstr(32)
    buf[off] = 0x58;
    buf[off + 1] = 0x20;
    off += 2;
    @memset(buf[off .. off + 32], 0x77);
    off += 32;

    // [8] opcert = array(4) [bstr(32)=hot_vk, uint(0)=seq, uint(5)=kes_period, bstr(64)=sigma]
    buf[off] = 0x84; // array(4)
    off += 1;
    // hot_vk = bstr(32)
    buf[off] = 0x58;
    buf[off + 1] = 0x20;
    off += 2;
    @memset(buf[off .. off + 32], 0xAA);
    off += 32;
    // seq_no = 0
    buf[off] = 0x00;
    off += 1;
    // kes_period = 5
    buf[off] = 0x05;
    off += 1;
    // sigma = bstr(64)
    buf[off] = 0x58;
    buf[off + 1] = 0x40;
    off += 2;
    @memset(buf[off .. off + 64], 0xBB);
    off += 64;

    // [9] protocol_version = array(2) [9, 0]
    buf[off] = 0x82;
    off += 1;
    buf[off] = 0x09;
    off += 1;
    buf[off] = 0x00;
    off += 1;

    const result = extractOpCertFromHeaderBody(buf[0..off]);
    try std.testing.expect(result != null);
    const oc = result.?;
    try std.testing.expectEqual(@as(u32, 5), oc.kes_period);
    try std.testing.expectEqual(@as(u8, 0xAA), oc.kes_pk[0]);
    try std.testing.expectEqual(@as(u8, 0xAA), oc.kes_pk[31]);
}

test "extractOpCertFromHeaderBody: rejects short array" {
    // array(3) — too few elements
    var buf = [_]u8{ 0x83, 0x00, 0x00, 0x00 };
    try std.testing.expect(extractOpCertFromHeaderBody(&buf) == null);
}

test "extractBodyHashFromHeaderBody: valid extraction" {
    // Reuse the header body from the OpCert test above, check body_hash at index 7
    var buf: [512]u8 = undefined;
    var off: usize = 0;

    buf[off] = 0x8a; // array(10)
    off += 1;
    // [0] block_number
    buf[off] = 0x00;
    off += 1;
    // [1] slot
    buf[off] = 0x00;
    off += 1;
    // [2] prev_hash
    buf[off] = 0x58;
    buf[off + 1] = 0x20;
    off += 2;
    @memset(buf[off .. off + 32], 0x11);
    off += 32;
    // [3] issuer_vk
    buf[off] = 0x58;
    buf[off + 1] = 0x20;
    off += 2;
    @memset(buf[off .. off + 32], 0x22);
    off += 32;
    // [4] vrf_vkey
    buf[off] = 0x58;
    buf[off + 1] = 0x20;
    off += 2;
    @memset(buf[off .. off + 32], 0x33);
    off += 32;
    // [5] vrf_result = array(2) [bstr(64), bstr(80)]
    buf[off] = 0x82;
    off += 1;
    buf[off] = 0x58;
    buf[off + 1] = 0x40;
    off += 2;
    @memset(buf[off .. off + 64], 0x44);
    off += 64;
    buf[off] = 0x58;
    buf[off + 1] = 0x50;
    off += 2;
    @memset(buf[off .. off + 80], 0x55);
    off += 80;
    // [6] body_size
    buf[off] = 0x00;
    off += 1;
    // [7] body_hash = bstr(32) filled with 0x77
    buf[off] = 0x58;
    buf[off + 1] = 0x20;
    off += 2;
    @memset(buf[off .. off + 32], 0x77);
    off += 32;
    // [8] opcert (skip — just need to parse up to [7])
    buf[off] = 0x84;
    off += 1;
    buf[off] = 0x58;
    buf[off + 1] = 0x20;
    off += 2;
    @memset(buf[off .. off + 32], 0xAA);
    off += 32;
    buf[off] = 0x00;
    off += 1;
    buf[off] = 0x05;
    off += 1;
    buf[off] = 0x58;
    buf[off + 1] = 0x40;
    off += 2;
    @memset(buf[off .. off + 64], 0xBB);
    off += 64;
    // [9] protocol_version
    buf[off] = 0x82;
    off += 1;
    buf[off] = 0x09;
    off += 1;
    buf[off] = 0x00;
    off += 1;

    const result = extractBodyHashFromHeaderBody(buf[0..off]);
    try std.testing.expect(result != null);
    const bh = result.?;
    try std.testing.expectEqual(@as(u8, 0x77), bh[0]);
    try std.testing.expectEqual(@as(u8, 0x77), bh[31]);
}

test "extractBstrPayload: valid bstr" {
    // bstr(4) = 0x44 + 4 bytes
    var buf = [_]u8{ 0x44, 0xAA, 0xBB, 0xCC, 0xDD };
    const payload = extractBstrPayload(&buf);
    try std.testing.expect(payload != null);
    try std.testing.expectEqual(@as(usize, 4), payload.?.len);
    try std.testing.expectEqual(@as(u8, 0xAA), payload.?[0]);
}

test "extractBstrPayload: rejects non-bstr" {
    // uint(5) = 0x05
    var buf = [_]u8{0x05};
    try std.testing.expect(extractBstrPayload(&buf) == null);
}

test "extractHeaderRegion: valid block structure" {
    // Build minimal block: array(2) [ uint(7), array(5) [ bstr(3)=header, 0x80, 0x80, 0xa0, 0x80 ] ]
    var buf: [32]u8 = undefined;
    var off: usize = 0;
    buf[off] = 0x82; // array(2)
    off += 1;
    buf[off] = 0x07; // era = 7
    off += 1;
    buf[off] = 0x85; // array(5)
    off += 1;
    // header = bstr(3) with bytes [0x01, 0x02, 0x03]
    buf[off] = 0x43; // bstr(3)
    off += 1;
    buf[off] = 0x01;
    off += 1;
    buf[off] = 0x02;
    off += 1;
    buf[off] = 0x03;
    off += 1;
    // tx_bodies = 0x80 (empty array)
    buf[off] = 0x80;
    off += 1;
    // witnesses = 0x80
    buf[off] = 0x80;
    off += 1;
    // aux_data = 0xa0 (empty map)
    buf[off] = 0xa0;
    off += 1;
    // invalid_txs = 0x80
    buf[off] = 0x80;
    off += 1;

    const region = extractHeaderRegion(buf[0..off]);
    try std.testing.expect(region != null);
    // header region should be bstr(3) = 4 bytes total (header 0x43 + 3 data bytes)
    try std.testing.expectEqual(@as(usize, 4), region.?.len);
    try std.testing.expectEqual(@as(u8, 0x43), region.?[0]);
}

test "validate: rejects empty header" {
    var header = [_]u8{};
    var block = [_]u8{};
    const report = validate(&header, &block, [_]u8{0} ** 32, [_]u8{0} ** 32);
    try std.testing.expectEqual(ValidationState.invalid_structure, report.state);
    try std.testing.expect(!report.header_cbor_ok);
}

test "hexEncode: produces lowercase hex" {
    const input = [_]u8{0xDE, 0xAD} ++ [_]u8{0} ** 30;
    const hex = hexEncode(input);
    try std.testing.expect(std.mem.startsWith(u8, &hex, "dead"));
}

test "formatReportJson: produces valid output" {
    var report = ValidationReport{
        .state = .valid,
        .header_cbor_ok = true,
        .block_cbor_ok = true,
        .header_hash_ok = true,
        .body_hash_ok = true,
        .block_hash_ok = true,
        .kes_signature_ok = true,
        .consistency_ok = true,
        .expected_header_hash_hex = [_]u8{'a'} ** 64,
        .actual_header_hash_hex = [_]u8{'b'} ** 64,
        .expected_body_hash_hex = [_]u8{'c'} ** 64,
        .actual_body_hash_hex = [_]u8{'d'} ** 64,
        .kes_verify_detail = .ok,
    };
    var buf: [2048]u8 = undefined;
    const json = formatReportJson(&report, &buf);
    try std.testing.expect(json != null);
    const s = json.?;
    try std.testing.expect(std.mem.indexOf(u8, s, "\"state\":\"valid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"kes_signature_ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"kes_verify_detail\":\"OK\"") != null);
}

// ── Incoming VRF Proof Verification ──────────────────────────────────

pub const VrfValidationStatus = enum {
    ok,
    skipped_no_nonce,
    skipped_parse_fail,
    invalid_proof,
};

pub const VrfValidationResult = struct {
    status: VrfValidationStatus,
    slot: u64,
};

/// Verify the VRF proof in an incoming block header against the epoch nonce.
/// Returns ok if proof is valid, or a specific failure/skip reason.
/// epoch_nonce must be the 32-byte nonce for the current epoch; if null, validation is skipped.
pub fn validateVrf(alloc: std.mem.Allocator, header_cbor: []const u8, epoch_nonce: ?*const [32]u8) VrfValidationResult {
    const nonce = epoch_nonce orelse return .{ .status = .skipped_no_nonce, .slot = 0 };

    // Parse header body to extract slot, vrf_vkey, vrf_output, vrf_proof
    const vrf_data = extractVrfData(alloc, header_cbor) orelse return .{ .status = .skipped_parse_fail, .slot = 0 };

    // Compute Praos VRF input: blake2b256(word64BE(slot) || epoch_nonce(32))
    var seed_preimage: [8 + 32]u8 = undefined;
    std.mem.writeInt(u64, seed_preimage[0..8], vrf_data.slot, .big);
    @memcpy(seed_preimage[8..40], nonce);
    var vrf_input: [32]u8 = undefined;
    Blake2b256.hash(&seed_preimage, &vrf_input, .{});

    // Verify VRF proof
    const verify_result = sodium_vrf.verify(&vrf_data.vrf_vkey, &vrf_data.vrf_proof, &vrf_input);
    if (verify_result == null) {
        return .{ .status = .invalid_proof, .slot = vrf_data.slot };
    }

    return .{ .status = .ok, .slot = vrf_data.slot };
}

pub fn vrfStatusStr(status: VrfValidationStatus) []const u8 {
    return switch (status) {
        .ok => "ok",
        .skipped_no_nonce => "skipped_no_nonce",
        .skipped_parse_fail => "skipped_parse_fail",
        .invalid_proof => "invalid_proof",
    };
}

const VrfData = struct {
    slot: u64,
    vrf_vkey: [32]u8,
    vrf_output: [64]u8,
    vrf_proof: [80]u8,
};

/// Extract VRF fields from a raw header CBOR.
/// Header = [header_body, kes_sig]; header_body = array(10) where:
///   [1] = slot, [4] = vrf_vkey(32 bytes), [5] = [vrf_output(64), vrf_proof(80)]
fn extractVrfData(alloc: std.mem.Allocator, header_cbor: []const u8) ?VrfData {
    const cbor = @import("../cbor/term.zig");
    var fbs = compat.fixedBufferStream(header_cbor);
    const term = cbor.decode(alloc, fbs.reader()) catch return null;
    defer cbor.free(term, alloc);

    // Header = [body, sig]
    if (term != .array or term.array.len < 2) return null;
    const body = if (term.array[0] == .array) term.array[0] else return null;
    if (body.array.len < 6) return null;

    // [1] slot
    const slot = if (body.array[1] == .u64) body.array[1].u64 else return null;

    // [4] vrf_vkey (32 bytes)
    const vrf_vkey_bytes = if (body.array[4] == .bytes and body.array[4].bytes.len == 32)
        body.array[4].bytes
    else
        return null;

    // [5] vrf_result = [output(64), proof(80)]
    const vrf_result = if (body.array[5] == .array and body.array[5].array.len >= 2)
        body.array[5].array
    else
        return null;

    const vrf_output_bytes = if (vrf_result[0] == .bytes and vrf_result[0].bytes.len == 64)
        vrf_result[0].bytes
    else
        return null;

    const vrf_proof_bytes = if (vrf_result[1] == .bytes and vrf_result[1].bytes.len == 80)
        vrf_result[1].bytes
    else
        return null;

    var result: VrfData = undefined;
    result.slot = slot;
    @memcpy(&result.vrf_vkey, vrf_vkey_bytes[0..32]);
    @memcpy(&result.vrf_output, vrf_output_bytes[0..64]);
    @memcpy(&result.vrf_proof, vrf_proof_bytes[0..80]);
    return result;
}

test "validateVrf returns skipped_no_nonce when nonce is null" {
    const result = validateVrf(std.testing.allocator, &[_]u8{}, null);
    try std.testing.expectEqual(VrfValidationStatus.skipped_no_nonce, result.status);
}

test "validateVrf returns skipped_parse_fail on invalid header" {
    var nonce = [_]u8{0} ** 32;
    const result = validateVrf(std.testing.allocator, &[_]u8{ 0x82, 0x80, 0x40 }, &nonce);
    try std.testing.expectEqual(VrfValidationStatus.skipped_parse_fail, result.status);
}

test "vrfStatusStr returns correct labels" {
    try std.testing.expectEqualStrings("ok", vrfStatusStr(.ok));
    try std.testing.expectEqualStrings("invalid_proof", vrfStatusStr(.invalid_proof));
}
