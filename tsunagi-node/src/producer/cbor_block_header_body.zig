const std = @import("std");

/// Cardano block header body CBOR builder (era 7 / Conway2, 10-element format).
///
/// Header body layout (from real chain, proven by Phase A alignment):
///   [0]  block_number     : uint
///   [1]  slot             : uint
///   [2]  prev_hash        : bstr(32)
///   [3]  issuer_vk        : bstr(32)   (cold verification key)
///   [4]  vrf_vkey         : bstr(32)   (VRF verification key)
///   [5]  vrf_result       : [bstr(64), bstr(80)]  (output, proof)
///   [6]  block_body_size  : uint
///   [7]  block_body_hash  : bstr(32)
///   [8]  operational_cert : [bstr(32), uint, uint, bstr(64)]  (hot_vk, seq_no, kes_period, sigma)
///   [9]  protocol_version : [uint, uint]  (major, minor)
///
/// This is the signed message for real KES signatures.
/// The KES signature covers the raw CBOR bytes of this 10-element array.
///
/// NO runtime changes. This file is used only by dryrun + alignment tooling.

pub const HEADER_BODY_MAX_LEN: usize = 1024;

pub const HeaderBodyCbor = struct {
    len: usize,
    bytes: [HEADER_BODY_MAX_LEN]u8,
};

pub const OpCert = struct {
    hot_vk: [32]u8,
    seq_no: u64,
    kes_period: u64,
    sigma: [64]u8,
};

pub const ProtocolVersion = struct {
    major: u64,
    minor: u64,
};

/// Build Cardano header body CBOR (10-element array, era 7).
pub fn buildHeaderBodyCborV2(
    block_number: u64,
    slot: u64,
    prev_hash: [32]u8,
    issuer_vk: [32]u8,
    vrf_vkey: [32]u8,
    vrf_output: [64]u8,
    vrf_proof: [80]u8,
    block_body_size: u64,
    block_body_hash: [32]u8,
    opcert: OpCert,
    pv: ProtocolVersion,
) HeaderBodyCbor {
    var buf: [HEADER_BODY_MAX_LEN]u8 = [_]u8{0} ** HEADER_BODY_MAX_LEN;
    var off: usize = 0;

    // array(10) = 0x8a
    cborEncodeArrayHeader(&buf, &off, 10);

    // [0] block_number
    cborEncodeUint(&buf, &off, block_number);

    // [1] slot
    cborEncodeUint(&buf, &off, slot);

    // [2] prev_hash: bstr(32)
    cborEncodeByteString(&buf, &off, &prev_hash);

    // [3] issuer_vk: bstr(32)
    cborEncodeByteString(&buf, &off, &issuer_vk);

    // [4] vrf_vkey: bstr(32)
    cborEncodeByteString(&buf, &off, &vrf_vkey);

    // [5] vrf_result: [bstr(64), bstr(80)]
    cborEncodeArrayHeader(&buf, &off, 2);
    cborEncodeByteString(&buf, &off, &vrf_output);
    cborEncodeByteString(&buf, &off, &vrf_proof);

    // [6] block_body_size
    cborEncodeUint(&buf, &off, block_body_size);

    // [7] block_body_hash: bstr(32)
    cborEncodeByteString(&buf, &off, &block_body_hash);

    // [8] operational_cert: [bstr(32), uint, uint, bstr(64)]
    cborEncodeArrayHeader(&buf, &off, 4);
    cborEncodeByteString(&buf, &off, &opcert.hot_vk);
    cborEncodeUint(&buf, &off, opcert.seq_no);
    cborEncodeUint(&buf, &off, opcert.kes_period);
    cborEncodeByteString(&buf, &off, &opcert.sigma);

    // [9] protocol_version: [uint, uint]
    cborEncodeArrayHeader(&buf, &off, 2);
    cborEncodeUint(&buf, &off, pv.major);
    cborEncodeUint(&buf, &off, pv.minor);

    return .{ .len = off, .bytes = buf };
}

// --- Minimal CBOR encoder helpers (stack only, no allocations) ---

fn cborEncodeArrayHeader(buf: []u8, off: *usize, n: u8) void {
    if (n < 24) {
        buf[off.*] = 0x80 | (n & 0x1f);
        off.* += 1;
    } else {
        buf[off.*] = 0x98;
        buf[off.* + 1] = n;
        off.* += 2;
    }
}

fn cborEncodeUint(buf: []u8, off: *usize, v: u64) void {
    if (v < 24) {
        buf[off.*] = @as(u8, @intCast(v));
        off.* += 1;
    } else if (v < 0x100) {
        buf[off.*] = 0x18;
        buf[off.* + 1] = @as(u8, @intCast(v));
        off.* += 2;
    } else if (v < 0x10000) {
        buf[off.*] = 0x19;
        std.mem.writeInt(u16, buf[off.* + 1 ..][0..2], @as(u16, @intCast(v)), .big);
        off.* += 3;
    } else if (v < 0x100000000) {
        buf[off.*] = 0x1a;
        std.mem.writeInt(u32, buf[off.* + 1 ..][0..4], @as(u32, @intCast(v)), .big);
        off.* += 5;
    } else {
        buf[off.*] = 0x1b;
        std.mem.writeInt(u64, buf[off.* + 1 ..][0..8], v, .big);
        off.* += 9;
    }
}

fn cborEncodeByteString(buf: []u8, off: *usize, data: []const u8) void {
    if (data.len < 24) {
        buf[off.*] = 0x40 | @as(u8, @intCast(data.len));
        off.* += 1;
    } else if (data.len < 0x100) {
        buf[off.*] = 0x58;
        buf[off.* + 1] = @as(u8, @intCast(data.len));
        off.* += 2;
    } else {
        buf[off.*] = 0x59;
        std.mem.writeInt(u16, buf[off.* + 1 ..][0..2], @as(u16, @intCast(data.len)), .big);
        off.* += 3;
    }
    @memcpy(buf[off.*..][0..data.len], data);
    off.* += data.len;
}
