const std = @import("std");

pub const MAGIC = "TSF2";
pub const VERSION: u32 = 2;

pub const Header = extern struct {
    magic: [4]u8,
    version: u32,
    network_magic: u32,
    reserved: u32,
    slot: u64,
    block_no: u64,
    tip_hash: [32]u8,
    header_head: [32]u8,
    header_height: u64,
};

pub const Footer = extern struct {
    digest: [32]u8, // blake2b-256 over file bytes excluding this footer
};

pub fn writeHeader(w: anytype, network_magic: u32, slot: u64, block_no: u64, tip_hash: *const [32]u8, header_head: *const [32]u8, header_height: u64) !void {
    var h = Header{
        .magic = MAGIC.*,
        .version = VERSION,
        .network_magic = network_magic,
        .reserved = 0,
        .slot = slot,
        .block_no = block_no,
        .tip_hash = tip_hash.*,
        .header_head = header_head.*,
        .header_height = header_height,
    };
    try w.writeAll(std.mem.asBytes(&h));
}

pub fn readHeader(r: anytype) !Header {
    var h: Header = undefined;
    try r.readNoEof(std.mem.asBytes(&h));
    return h;
}

// Record format: [u32 le key_len=36][36B key][u32 le val_len][val bytes]
pub fn writeRecord(w: anytype, key36: *const [36]u8, val: []const u8) !void {
    var buf4: [4]u8 = undefined;

    std.mem.writeInt(u32, &buf4, 36, .little);
    try w.writeAll(&buf4);
    try w.writeAll(key36);

    std.mem.writeInt(u32, &buf4, @intCast(val.len), .little);
    try w.writeAll(&buf4);
    try w.writeAll(val);
}

pub fn readU32le(r: anytype) !u32 {
    var buf: [4]u8 = undefined;
    try r.readNoEof(&buf);
    return std.mem.readInt(u32, &buf, .little);
}

pub fn writeFooter(w: anytype, digest: *const [32]u8) !void {
    var f = Footer{ .digest = digest.* };
    try w.writeAll(std.mem.asBytes(&f));
}

pub fn readFooter(r: anytype) !Footer {
    var f: Footer = undefined;
    try r.readNoEof(std.mem.asBytes(&f));
    return f;
}

pub fn networkName(magic: u32) []const u8 {
    return switch (magic) {
        764_824_073 => "mainnet",
        2 => "preview",
        1 => "preprod",
        else => "unknown",
    };
}
