const std = @import("std");
const compat = @import("compat");
const producer = @import("../producer/producer.zig");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var num_slots: u64 = 1000;
    var init_baseline = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--slots")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --slots requires a value\n", .{});
                return 1;
            };
            num_slots = std.fmt.parseInt(u64, val, 10) catch {
                std.debug.print("ERROR: invalid --slots value: {s}\n", .{val});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--init-baseline")) {
            init_baseline = true;
        }
    }

    std.debug.print("=== TSUNAGI Praos Regression ===\n\n", .{});
    std.debug.print("  slots:  {d}\n", .{num_slots});
    std.debug.print("  stake:  100000 (x1e9)\n", .{});
    std.debug.print("  asc:    50000 (x1e6)\n\n", .{});

    const stake_fraction_x1e9: u64 = 100_000;
    const asc_x1e6: u64 = 50_000;
    const thresh_x1e12 = producer.computeThreshX1e12(stake_fraction_x1e9, asc_x1e6);

    // Deterministic seed
    var base_seed: [32]u8 = undefined;
    Blake2b256.hash("TSUNAGI_PRAOS_REGRESS_V1", &base_seed, .{});

    // Running hasher
    var hasher = Blake2b256.init(.{});

    for (0..num_slots) |slot_usize| {
        const slot: u64 = @intCast(slot_usize);

        // Per-slot VRF output: blake2b256(base_seed ++ slot_le)
        var input: [40]u8 = undefined;
        @memcpy(input[0..32], &base_seed);
        std.mem.writeInt(u64, input[32..40], slot, .little);
        var slot_hash: [32]u8 = undefined;
        Blake2b256.hash(&input, &slot_hash, .{});
        var vrf_output: [64]u8 = [_]u8{0} ** 64;
        @memcpy(vrf_output[0..32], &slot_hash);

        const u_x1e12 = producer.vrfOutputToU_x1e12(vrf_output);
        const u_lt_t: u64 = if (u_x1e12 < thresh_x1e12) 1 else 0;

        // Feed into hasher
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, u_x1e12, .little);
        hasher.update(&buf);
        std.mem.writeInt(u64, &buf, thresh_x1e12, .little);
        hasher.update(&buf);
        std.mem.writeInt(u64, &buf, u_lt_t, .little);
        hasher.update(&buf);
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    const hex_chars = "0123456789abcdef";
    var hex: [64]u8 = undefined;
    for (0..32) |i| {
        hex[i * 2] = hex_chars[digest[i] >> 4];
        hex[i * 2 + 1] = hex_chars[digest[i] & 0xf];
    }

    std.debug.print("  computed: {s}\n", .{&hex});

    // Resolve TSUNAGI_HOME
    const home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch {
        if (init_baseline) {
            std.debug.print("ERROR: TSUNAGI_HOME not set (required for --init-baseline)\n", .{});
            return 1;
        }
        std.debug.print("  TSUNAGI_HOME not set — cannot compare baseline\n", .{});
        std.debug.print("  Use --init-baseline to create one\n", .{});
        return 1;
    };
    defer alloc.free(home);

    // Build path: $TSUNAGI_HOME/regress/praos_baseline.json
    const regress_dir = std.fmt.allocPrint(alloc, "{s}/regress", .{home}) catch return 1;
    defer alloc.free(regress_dir);
    const baseline_path = std.fmt.allocPrint(alloc, "{s}/praos_baseline.json", .{regress_dir}) catch return 1;
    defer alloc.free(baseline_path);

    if (init_baseline) {
        // Create regress dir if needed
        compat.fs.cwd().makePath(regress_dir) catch |e| {
            std.debug.print("ERROR: cannot create {s}: {any}\n", .{ regress_dir, e });
            return 1;
        };
        // Write baseline JSON
        const json = std.fmt.allocPrint(alloc, "{{\"slots\":{d},\"blake2b256\":\"{s}\"}}\n", .{ num_slots, &hex }) catch return 1;
        defer alloc.free(json);
        var file = compat.fs.cwd().createFile(baseline_path, .{}) catch |e| {
            std.debug.print("ERROR: cannot write {s}: {any}\n", .{ baseline_path, e });
            return 1;
        };
        defer file.close();
        file.writeAll(json) catch return 1;
        std.debug.print("  baseline: written to {s}\n\n", .{baseline_path});
        std.debug.print("=== Praos Regression: BASELINE CREATED ===\n", .{});
        return 0;
    }

    // Normal mode: read and compare
    var file = compat.fs.cwd().openFile(baseline_path, .{}) catch {
        std.debug.print("  baseline: not found at {s}\n", .{baseline_path});
        std.debug.print("  Run with --init-baseline to create one\n", .{});
        return 1;
    };
    defer file.close();
    var buf2: [1024]u8 = undefined;
    const len = file.readAll(&buf2) catch {
        std.debug.print("ERROR: cannot read {s}\n", .{baseline_path});
        return 1;
    };
    const content = buf2[0..len];

    // Extract blake2b256 value from JSON
    const needle = "\"blake2b256\":\"";
    const start = std.mem.indexOf(u8, content, needle) orelse {
        std.debug.print("ERROR: cannot parse baseline JSON\n", .{});
        return 1;
    };
    const hash_start = start + needle.len;
    if (hash_start + 64 > content.len) {
        std.debug.print("ERROR: baseline hash too short\n", .{});
        return 1;
    }
    const expected = content[hash_start .. hash_start + 64];

    std.debug.print("  expected: {s}\n\n", .{expected});

    if (std.mem.eql(u8, &hex, expected)) {
        std.debug.print("=== Praos Regression: PASS ===\n", .{});
        return 0;
    } else {
        std.debug.print("=== Praos Regression: FAIL ===\n", .{});
        return 1;
    }
}
