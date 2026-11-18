const std = @import("std");
const slot_scheduler = @import("../producer/slot_scheduler.zig");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

/// Expected digest — bootstrap: first run prints computed hash, then hard-code it here.
const EXPECTED_HEX = "58ffcee6f236129aad02ec22da889a5ba94d005876442385bdefa379b52739d1";

pub fn run(alloc: std.mem.Allocator) u8 {
    _ = alloc;

    std.debug.print("=== TSUNAGI Schedule Regression ===\n\n", .{});
    std.debug.print("  slots:  10000 (offset 0..9999)\n", .{});
    std.debug.print("  epoch:  500\n", .{});
    std.debug.print("  start:  100000000\n", .{});
    std.debug.print("  stake:  100000 (x1e9)\n", .{});
    std.debug.print("  asc:    50000 (x1e6)\n\n", .{});

    // Fixed synthetic VRF output: blake2b256("TSUNAGI_REGRESS_SEED_V1") zero-padded to 64 bytes
    var vrf_output_bytes: [64]u8 = [_]u8{0} ** 64;
    {
        var seed_hash: [32]u8 = undefined;
        Blake2b256.hash("TSUNAGI_REGRESS_SEED_V1", &seed_hash, .{});
        @memcpy(vrf_output_bytes[0..32], &seed_hash);
    }

    // Running blake2b256 hasher for overall digest
    var hasher = Blake2b256.init(.{});

    const epoch: u64 = 500;
    const start_slot: u64 = 100_000_000;
    const stake_fraction_x1e9: u64 = 100_000;
    const asc_x1e6: u64 = 50_000;

    for (0..10_000) |offset_usize| {
        const offset: u64 = @intCast(offset_usize);
        const current_slot = start_slot + offset;

        const sched = slot_scheduler.computeSchedule(
            epoch,
            current_slot,
            stake_fraction_x1e9,
            asc_x1e6,
            vrf_output_bytes,
            true, // vrf_output_present
            true, // clock_ok
        );

        // Feed each field as 8-byte LE into running hasher
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, sched.epoch, .little);
        hasher.update(&buf);
        std.mem.writeInt(u64, &buf, sched.start_slot, .little);
        hasher.update(&buf);
        std.mem.writeInt(u64, &buf, sched.window, .little);
        hasher.update(&buf);
        std.mem.writeInt(u64, &buf, sched.leaders_in_window, .little);
        hasher.update(&buf);
        std.mem.writeInt(u64, &buf, sched.next_leader_offset, .little);
        hasher.update(&buf);
        std.mem.writeInt(u64, &buf, sched.u_x1e12_first, .little);
        hasher.update(&buf);
        std.mem.writeInt(u64, &buf, sched.thresh_x1e12_first, .little);
        hasher.update(&buf);
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    // Hex-encode
    const hex_chars = "0123456789abcdef";
    var hex: [64]u8 = undefined;
    for (0..32) |i| {
        hex[i * 2] = hex_chars[digest[i] >> 4];
        hex[i * 2 + 1] = hex_chars[digest[i] & 0xf];
    }

    std.debug.print("  computed: {s}\n", .{&hex});
    std.debug.print("  expected: {s}\n\n", .{EXPECTED_HEX});

    if (std.mem.eql(u8, &hex, EXPECTED_HEX)) {
        std.debug.print("=== Schedule Regression: PASS ===\n", .{});
        return 0;
    } else {
        std.debug.print("=== Schedule Regression: FAIL ===\n", .{});
        return 1;
    }
}
