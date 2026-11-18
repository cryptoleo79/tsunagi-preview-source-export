const std = @import("std");
const compat = @import("compat");
const kes_verify = @import("kes_verify.zig");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

pub fn main() !void {
    var stdout_file = compat.fs.File.stdout();
    const stdout = stdout_file.writer();

    // Read block_header.cbor
    var hdr_buf: [4096]u8 = undefined;
    var hdr_file = compat.fs.cwd().openFile("/home/tsunagi/tsunagi-home-preview/propagation_artifact/block_header.cbor", .{}) catch return;
    defer hdr_file.close();
    const hdr_len = try hdr_file.readAll(&hdr_buf);
    const hdr = hdr_buf[0..hdr_len];

    // Parse: array(2) = 0x82, then header_body, then 0x5901c0 + 448-byte sig
    const sig_marker_pos = std.mem.lastIndexOf(u8, hdr, &[_]u8{ 0x59, 0x01, 0xc0 }) orelse {
        try stdout.print("ERROR: no sig marker\n", .{});
        return;
    };
    const header_body = hdr[1..sig_marker_pos];
    const kes_sig = hdr[sig_marker_pos + 3 .. sig_marker_pos + 3 + 448];

    try stdout.print("header_len={d} body_len={d} sig_len={d}\n", .{ hdr_len, header_body.len, kes_sig.len });

    // Extract slot (element 1 of body: 8a <block_no:1a XXXX> <slot:1a XXXX>)
    const slot: u64 = if (header_body[0] == 0x8a and header_body[6] == 0x1a)
        std.mem.readInt(u32, header_body[7..11], .big)
    else
        0;
    const block_no: u64 = if (header_body[1] == 0x1a)
        std.mem.readInt(u32, header_body[2..6], .big)
    else
        0;
    try stdout.print("block_no={d} slot={d}\n", .{ block_no, slot });

    // KES period
    const current_kes_period: u32 = @intCast(slot / 129600);
    const kes_start: u32 = 800;
    const kes_offset: u32 = current_kes_period - kes_start;
    try stdout.print("kes_period={d} kes_offset={d}\n", .{ current_kes_period, kes_offset });

    // Extract hot_vk from opcert in header body
    // Search for 84 5820 pattern (opcert array(4) + bstr(32))
    const hot_vk_needle = [_]u8{ 0x84, 0x58, 0x20 };
    const opcert_pos = std.mem.lastIndexOf(u8, header_body, &hot_vk_needle) orelse {
        try stdout.print("ERROR: opcert not found\n", .{});
        return;
    };
    var hot_vk: [32]u8 = undefined;
    @memcpy(&hot_vk, header_body[opcert_pos + 3 .. opcert_pos + 35]);
    try stdout.print("hot_vk={x}\n", .{&hot_vk});

    // ── CHECK 1: KES signature verify ──
    const kes_result = kes_verify.verifySum6Kes(hot_vk, kes_offset, header_body, kes_sig);
    try stdout.print("\nKES_VERIFY: {s}\n", .{kes_verify.resultStr(kes_result)});

    // ── CHECK 2: Header hash ──
    var hdr_hash: [32]u8 = undefined;
    Blake2b256.hash(hdr, &hdr_hash, .{});
    try stdout.print("header_hash={x}\n", .{&hdr_hash});

    // Read meta.json for cross-check
    var meta_buf: [4096]u8 = undefined;
    var meta_file = compat.fs.cwd().openFile("/home/tsunagi/tsunagi-home-preview/propagation_artifact/meta.json", .{}) catch {
        try stdout.print("meta.json not readable\n", .{});
        return;
    };
    defer meta_file.close();
    const meta_len = try meta_file.readAll(&meta_buf);
    const meta = meta_buf[0..meta_len];
    try stdout.print("meta={s}\n", .{meta});
}
