const std = @import("std");
const body_candidate = @import("../producer/body_candidate.zig");

pub fn run(_: std.mem.Allocator) u8 {
    std.debug.print("=== TSUNAGI Body Hash Self-Test ===\n\n", .{});

    // Test with known inputs
    const net_magic: u32 = 764824073; // mainnet
    const slot: u64 = 999999;
    const tip_block: u64 = 12345;
    var parent_hash: [32]u8 = undefined;
    for (0..32) |i| {
        parent_hash[i] = @as(u8, @intCast(i));
    }

    std.debug.print("  net_magic:    {d}\n", .{net_magic});
    std.debug.print("  slot:         {d}\n", .{slot});
    std.debug.print("  tip_block:    {d}\n", .{tip_block});
    std.debug.print("  parent_hash:  0x", .{});
    const hex_chars = "0123456789abcdef";
    for (parent_hash) |b| {
        std.debug.print("{c}{c}", .{ hex_chars[b >> 4], hex_chars[b & 0xf] });
    }
    std.debug.print("\n\n", .{});

    const body = body_candidate.buildEmptyBodyV1(net_magic, slot, tip_block, parent_hash);

    std.debug.print("  cbor_len:     {d}\n", .{body.cbor_len});
    std.debug.print("  cbor_hex:     ", .{});
    const cbor_len: usize = @intCast(body.cbor_len);
    for (body.cbor_bytes[0..cbor_len]) |b| {
        std.debug.print("{c}{c}", .{ hex_chars[b >> 4], hex_chars[b & 0xf] });
    }
    std.debug.print("\n", .{});

    std.debug.print("  body_hash:    0x", .{});
    for (body.body_hash) |b| {
        std.debug.print("{c}{c}", .{ hex_chars[b >> 4], hex_chars[b & 0xf] });
    }
    std.debug.print("\n", .{});

    // Verify determinism: build again with same inputs
    const body2 = body_candidate.buildEmptyBodyV1(net_magic, slot, tip_block, parent_hash);
    if (!std.mem.eql(u8, &body.body_hash, &body2.body_hash)) {
        std.debug.print("\nFAIL: non-deterministic body hash\n", .{});
        return 1;
    }
    std.debug.print("\n  determinism:  ok (same inputs → same hash)\n", .{});

    // Verify different inputs produce different hash
    const body3 = body_candidate.buildEmptyBodyV1(net_magic, slot + 1, tip_block, parent_hash);
    if (std.mem.eql(u8, &body.body_hash, &body3.body_hash)) {
        std.debug.print("\nFAIL: different inputs produced same hash\n", .{});
        return 2;
    }
    std.debug.print("  sensitivity:  ok (different slot → different hash)\n", .{});

    // Verify CBOR structure
    if (body.cbor_len == 0) {
        std.debug.print("\nFAIL: cbor_len is 0\n", .{});
        return 3;
    }
    // First byte should be 0x87 (CBOR array of 7 items)
    if (body.cbor_bytes[0] != 0x87) {
        std.debug.print("\nFAIL: CBOR does not start with 0x87 (got 0x{x:0>2})\n", .{body.cbor_bytes[0]});
        return 4;
    }
    std.debug.print("  cbor_check:   ok (starts with 0x87 = array(7))\n", .{});

    std.debug.print("\n=== Body Hash Self-Test PASSED ===\n", .{});
    return 0;
}
