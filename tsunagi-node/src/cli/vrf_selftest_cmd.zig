const std = @import("std");
const vrf = @import("../producer/vrf.zig");
const sodium_vrf = @import("../producer/crypto/sodium_vrf.zig");

pub fn run(alloc: std.mem.Allocator) u8 {
    std.debug.print("=== TSUNAGI VRF Self-Test ===\n\n", .{});

    // Load VRF config (reads TSUNAGI_VRF_ENABLE + key path / seed)
    const cfg = vrf.loadConfig(alloc);

    std.debug.print("  enabled:    {s}\n", .{if (cfg.enabled) "yes" else "no"});
    std.debug.print("  parse_ok:   {s}\n", .{if (cfg.parse_ok) "yes" else "no"});
    std.debug.print("  init_ok:    {s}\n", .{if (cfg.init_ok) "yes" else "no"});
    std.debug.print("  reason:     {d}\n", .{cfg.reason_code_last});
    if (cfg.key_path) |p| {
        std.debug.print("  key_path:   {s}\n", .{p});
    } else {
        std.debug.print("  key_path:   n/a\n", .{});
    }

    if (!cfg.enabled) {
        std.debug.print("\nVRF is disabled (set TSUNAGI_VRF_ENABLE=1)\n", .{});
        return 1;
    }

    if (!cfg.parse_ok) {
        std.debug.print("\nVRF config parse failed (reason={d})\n", .{cfg.reason_code_last});
        return 2;
    }

    if (!cfg.init_ok) {
        std.debug.print("\nVRF init failed (reason={d})\n", .{cfg.reason_code_last});
        return 3;
    }

    // Perform exactly one prove + verify + proof_to_hash
    const test_epoch: u64 = 999;
    const test_slot: u64 = 999999;

    std.debug.print("\n  test input: epoch={d} slot={d}\n", .{ test_epoch, test_slot });

    // Build VRF input message: epoch(u64 BE) || slot(u64 BE)
    var msg: [16]u8 = undefined;
    std.mem.writeInt(u64, msg[0..8], test_epoch, .big);
    std.mem.writeInt(u64, msg[8..16], test_slot, .big);

    // Prove
    const prove_result = sodium_vrf.prove(&cfg.sk.?, &msg) orelse {
        std.debug.print("\nFAIL: VRF prove() returned error\n", .{});
        return 4;
    };
    std.debug.print("  prove:      ok (proof={d} bytes, output={d} bytes)\n", .{ prove_result.proof.len, prove_result.output.len });

    // Self-verify
    const verify_result = sodium_vrf.verify(&cfg.pk.?, &prove_result.proof, &msg);
    if (verify_result == null) {
        std.debug.print("\nFAIL: VRF verify() returned error\n", .{});
        return 5;
    }
    std.debug.print("  verify:     ok\n", .{});

    // Output prefix
    const output_prefix = std.mem.readInt(u64, prove_result.output[0..8], .big);
    std.debug.print("  output_pfx: 0x{x:0>16}\n", .{output_prefix});

    // PK hex
    var pk_hex: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (cfg.pk.?, 0..) |byte, i| {
        pk_hex[i * 2] = hex_chars[byte >> 4];
        pk_hex[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    std.debug.print("  pk:         {s}\n", .{&pk_hex});

    std.debug.print("\n=== VRF Self-Test PASSED ===\n", .{});
    return 0;
}
