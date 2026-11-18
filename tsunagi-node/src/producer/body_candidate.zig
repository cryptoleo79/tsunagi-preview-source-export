const std = @import("std");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

pub const DOMAIN = "TSUNAGI_BODY_V1";
pub const BODY_V1_MAX_LEN: usize = 128;

pub const BodyCandidateV1 = struct {
    cbor_len: u64,
    cbor_bytes: [BODY_V1_MAX_LEN]u8,
    body_hash: [32]u8,
};

// --- Minimal CBOR encoder helpers (stack only, no allocations) ---

fn cborEncodeArrayHeader(buf: []u8, off: *usize, n: u8) void {
    buf[off.*] = 0x80 | (n & 0x1f);
    off.* += 1;
}

fn cborEncodeTextString(buf: []u8, off: *usize, s: []const u8) void {
    if (s.len < 24) {
        buf[off.*] = 0x60 | @as(u8, @intCast(s.len));
        off.* += 1;
    } else {
        buf[off.*] = 0x78;
        buf[off.* + 1] = @as(u8, @intCast(s.len));
        off.* += 2;
    }
    @memcpy(buf[off.*..][0..s.len], s);
    off.* += s.len;
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
    } else {
        buf[off.*] = 0x58;
        buf[off.* + 1] = @as(u8, @intCast(data.len));
        off.* += 2;
    }
    @memcpy(buf[off.*..][0..data.len], data);
    off.* += data.len;
}

/// Build canonical empty body v1:
/// CBOR array ["TSUNAGI_BODY_V1", net_magic, slot, tip_block, parent_hash(32), tx_count=0, txs=[]]
/// body_hash = blake2b256(cbor_bytes[0..cbor_len])
pub fn buildEmptyBodyV1(
    net_magic: u32,
    slot: u64,
    tip_block: u64,
    parent_hash: [32]u8,
) BodyCandidateV1 {
    var buf: [BODY_V1_MAX_LEN]u8 = [_]u8{0} ** BODY_V1_MAX_LEN;
    var off: usize = 0;

    // Array of 7 items
    cborEncodeArrayHeader(&buf, &off, 7);
    // Domain string "TSUNAGI_BODY_V1" (16 chars)
    cborEncodeTextString(&buf, &off, DOMAIN);
    // net_magic (u32)
    cborEncodeUint(&buf, &off, @as(u64, net_magic));
    // slot (u64)
    cborEncodeUint(&buf, &off, slot);
    // tip_block (u64)
    cborEncodeUint(&buf, &off, tip_block);
    // parent_hash (32 bytes)
    cborEncodeByteString(&buf, &off, &parent_hash);
    // tx_count = 0
    cborEncodeUint(&buf, &off, 0);
    // txs = empty array
    cborEncodeArrayHeader(&buf, &off, 0);

    // Hash
    var body_hash: [32]u8 = undefined;
    Blake2b256.hash(buf[0..off], &body_hash, .{});

    return BodyCandidateV1{
        .cbor_len = @intCast(off),
        .cbor_bytes = buf,
        .body_hash = body_hash,
    };
}
