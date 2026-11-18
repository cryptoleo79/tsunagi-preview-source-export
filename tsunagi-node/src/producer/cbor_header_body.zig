const std = @import("std");

/// Simplified CBOR header body encoder for dry-run KES signing.
/// Produces: array(4): [block_number(uint), slot(uint), prev_hash(bstr 32), body_hash(bstr 32)]
/// This is the signed message for real KES signatures.

pub const HEADER_BODY_MAX_LEN: usize = 128;

pub const HeaderBodyCbor = struct {
    len: usize,
    bytes: [HEADER_BODY_MAX_LEN]u8,
};

/// Build simplified CBOR header body:
/// array(4): [block_number, slot, prev_hash(32), body_hash(32)]
pub fn buildHeaderBodyCbor(
    block_number: u64,
    slot: u64,
    prev_hash: [32]u8,
    body_hash: [32]u8,
) HeaderBodyCbor {
    var buf: [HEADER_BODY_MAX_LEN]u8 = [_]u8{0} ** HEADER_BODY_MAX_LEN;
    var off: usize = 0;
    cborEncodeArrayHeader(&buf, &off, 4);
    cborEncodeUint(&buf, &off, block_number);
    cborEncodeUint(&buf, &off, slot);
    cborEncodeByteString(&buf, &off, &prev_hash);
    cborEncodeByteString(&buf, &off, &body_hash);
    return .{ .len = off, .bytes = buf };
}

// --- Minimal CBOR encoder helpers (same pattern as body_candidate.zig) ---

fn cborEncodeArrayHeader(buf: []u8, off: *usize, n: u8) void {
    buf[off.*] = 0x80 | (n & 0x1f);
    off.* += 1;
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
