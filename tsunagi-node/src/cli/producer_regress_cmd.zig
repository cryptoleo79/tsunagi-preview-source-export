const std = @import("std");
const compat = @import("compat");
const producer = @import("../producer/producer.zig");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

// Fixed synthetic parameters for deterministic reproducibility
const REGRESS_STAKE_X1E9: u64 = 100_000;
const REGRESS_ASC_X1E6: u64 = 50_000;
const SLOTS_PER_KES_PERIOD: u64 = 129600;
const KES_START_PERIOD: u64 = 0;
const KES_MAX_PERIODS: u64 = 62;

pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var num_slots: u64 = 2000;
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

    std.debug.print("=== TSUNAGI Producer Regression ===\n\n", .{});
    std.debug.print("  slots:  {d}\n", .{num_slots});
    std.debug.print("  stake:  {d} (x1e9)\n", .{REGRESS_STAKE_X1E9});
    std.debug.print("  asc:    {d} (x1e6)\n\n", .{REGRESS_ASC_X1E6});

    const thresh_x1e12 = producer.computeThreshX1e12(REGRESS_STAKE_X1E9, REGRESS_ASC_X1E6);

    // Deterministic seed
    var base_seed: [32]u8 = undefined;
    Blake2b256.hash("TSUNAGI_PRODUCER_REGRESS_V1", &base_seed, .{});

    // Running hasher over full decision surface
    var hasher = Blake2b256.init(.{});

    // Accumulated state_digest (starts as zeros, chains across slots)
    var state_digest: [32]u8 = [_]u8{0} ** 32;

    for (0..num_slots) |slot_usize| {
        const slot: u64 = @intCast(slot_usize);

        // Per-slot synthetic VRF: blake2b256(base_seed ++ slot_le) → 64 bytes
        var input: [40]u8 = undefined;
        @memcpy(input[0..32], &base_seed);
        std.mem.writeInt(u64, input[32..40], slot, .little);
        var slot_hash: [32]u8 = undefined;
        Blake2b256.hash(&input, &slot_hash, .{});
        var vrf_output: [64]u8 = [_]u8{0} ** 64;
        @memcpy(vrf_output[0..32], &slot_hash);

        const u_x1e12 = producer.vrfOutputToU_x1e12(vrf_output);
        const u_lt_t: u64 = if (u_x1e12 < thresh_x1e12) 1 else 0;
        const delta_x1e12: u64 = if (thresh_x1e12 > u_x1e12) thresh_x1e12 - u_x1e12 else 0;
        const kes_period: u64 = slot / SLOTS_PER_KES_PERIOD;
        const kes_valid: u64 = if (kes_period >= KES_START_PERIOD and kes_period < KES_START_PERIOD + KES_MAX_PERIODS) 1 else 0;
        const leader_last: u64 = u_lt_t;

        // 12-field digest (same encoding as runtime, 144 bytes)
        var digest_hasher = Blake2b256.init(.{});
        var dbuf: [8]u8 = undefined;

        // 1. last_checked_slot (8 LE)
        std.mem.writeInt(u64, &dbuf, slot, .little);
        digest_hasher.update(&dbuf);
        // 2. u_x1e12 (8 LE)
        std.mem.writeInt(u64, &dbuf, u_x1e12, .little);
        digest_hasher.update(&dbuf);
        // 3. threshold_x1e12 (8 LE)
        std.mem.writeInt(u64, &dbuf, thresh_x1e12, .little);
        digest_hasher.update(&dbuf);
        // 4. u_lt_t (8 LE)
        std.mem.writeInt(u64, &dbuf, u_lt_t, .little);
        digest_hasher.update(&dbuf);
        // 5. delta_x1e12 (8 LE)
        std.mem.writeInt(u64, &dbuf, delta_x1e12, .little);
        digest_hasher.update(&dbuf);
        // 6. kes_period (8 LE)
        std.mem.writeInt(u64, &dbuf, kes_period, .little);
        digest_hasher.update(&dbuf);
        // 7. kes_valid (8 LE)
        std.mem.writeInt(u64, &dbuf, kes_valid, .little);
        digest_hasher.update(&dbuf);
        // 8. leader_last (8 LE)
        std.mem.writeInt(u64, &dbuf, leader_last, .little);
        digest_hasher.update(&dbuf);
        // 9. header_hash (32 bytes: 4x8 LE — zeros in synthetic mode)
        const zero8 = [_]u8{0} ** 8;
        digest_hasher.update(&zero8); // w0
        digest_hasher.update(&zero8); // w1
        digest_hasher.update(&zero8); // w2
        digest_hasher.update(&zero8); // w3
        // 10. state_digest (32 bytes raw — chained from previous slot)
        digest_hasher.update(&state_digest);
        // 11. pack_schema_version (8 LE)
        std.mem.writeInt(u64, &dbuf, producer.PACK_SCHEMA_VERSION, .little);
        digest_hasher.update(&dbuf);
        // 12. state_schema_version (8 LE)
        std.mem.writeInt(u64, &dbuf, producer.STATE_SCHEMA_VERSION, .little);
        digest_hasher.update(&dbuf);

        // Per-slot digest
        var slot_digest: [32]u8 = undefined;
        digest_hasher.final(&slot_digest);
        state_digest = slot_digest;

        // Feed slot digest into running hasher
        hasher.update(&slot_digest);
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

    // Build path: $TSUNAGI_HOME/regress/producer_baseline.json
    const regress_dir = std.fmt.allocPrint(alloc, "{s}/regress", .{home}) catch return 1;
    defer alloc.free(regress_dir);
    const baseline_path = std.fmt.allocPrint(alloc, "{s}/producer_baseline.json", .{regress_dir}) catch return 1;
    defer alloc.free(baseline_path);

    if (init_baseline) {
        compat.fs.cwd().makePath(regress_dir) catch |e| {
            std.debug.print("ERROR: cannot create {s}: {any}\n", .{ regress_dir, e });
            return 1;
        };
        const json = std.fmt.allocPrint(alloc, "{{\"slots\":{d},\"blake2b256\":\"{s}\"}}\n", .{ num_slots, &hex }) catch return 1;
        defer alloc.free(json);
        var file = compat.fs.cwd().createFile(baseline_path, .{}) catch |e| {
            std.debug.print("ERROR: cannot write {s}: {any}\n", .{ baseline_path, e });
            return 1;
        };
        defer file.close();
        file.writeAll(json) catch return 1;
        std.debug.print("  baseline: written to {s}\n\n", .{baseline_path});
        std.debug.print("=== Producer Regression: BASELINE CREATED ===\n", .{});
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
        std.debug.print("=== Producer Regression: PASS ===\n", .{});
        return 0;
    } else {
        std.debug.print("=== Producer Regression: FAIL ===\n", .{});
        return 1;
    }
}
