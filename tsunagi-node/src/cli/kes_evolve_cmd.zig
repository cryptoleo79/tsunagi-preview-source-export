const std = @import("std");
const compat = @import("compat");
const kes_keyfile = @import("../producer/kes_keyfile.zig");
const kes_sign = @import("../producer/crypto/kes_sign.zig");
const kes_evolve = @import("../producer/crypto/kes_evolve.zig");
const kes_verify = @import("../producer/crypto/kes_verify.zig");

/// Offline KES key evolution harness.
/// Evolves a Cardano KES key state from its current period to a target period offset.
/// Validates root PK stability, then writes the evolved key state to --out.
/// Optionally runs sign+verify test at the target period.
///
/// Exit codes: 0=OK, 2=EVOLUTION_FAILED, 3=ERROR (missing files/args)
pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var key_path: ?[]const u8 = null;
    var target_offset: ?u32 = null;
    var out_path: ?[]const u8 = null;
    var verify_flag = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--key")) {
            key_path = args_it.next() orelse {
                std.debug.print("ERROR: --key requires a path\n", .{});
                return 3;
            };
        } else if (std.mem.eql(u8, arg, "--to-period-offset")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --to-period-offset requires a value (0..63)\n", .{});
                return 3;
            };
            target_offset = std.fmt.parseUnsigned(u32, val, 10) catch {
                std.debug.print("ERROR: invalid --to-period-offset '{s}'\n", .{val});
                return 3;
            };
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_path = args_it.next() orelse {
                std.debug.print("ERROR: --out requires a path\n", .{});
                return 3;
            };
        } else if (std.mem.eql(u8, arg, "--verify")) {
            verify_flag = true;
        }
    }

    if (key_path == null or target_offset == null or out_path == null) {
        std.debug.print("Usage: tsunagi-node kes-evolve --key <kes.skey> --to-period-offset <0..63> --out <evolved.bin> [--verify]\n", .{});
        return 3;
    }
    const path = key_path.?;
    const target = target_offset.?;
    const out = out_path.?;

    if (target >= 64) {
        std.debug.print("ERROR: --to-period-offset must be 0..63 (got {d})\n", .{target});
        return 3;
    }

    // --- Load key file ---
    std.debug.print("=== KES Evolve ===\n", .{});
    std.debug.print("key_path: {s}\n", .{path});
    std.debug.print("target_period_offset: {d}\n", .{target});
    std.debug.print("out_path: {s}\n", .{out});
    std.debug.print("verify: {}\n\n", .{verify_flag});

    var f = compat.fs.cwd().openFile(path, .{ .mode = .read_only }) catch {
        std.debug.print("ERROR: cannot open {s}\n", .{path});
        return 3;
    };
    defer f.close();
    const content = f.readToEndAlloc(alloc, 65536) catch {
        std.debug.print("ERROR: cannot read {s}\n", .{path});
        return 3;
    };
    defer alloc.free(content);

    if (!kes_keyfile.isJsonKeyFile(content)) {
        std.debug.print("ERROR: not a cardano-cli JSON key envelope\n", .{});
        return 3;
    }

    const kf = kes_keyfile.readKeyJson(content) orelse {
        std.debug.print("ERROR: malformed JSON key envelope\n", .{});
        return 3;
    };

    std.debug.print("type: {s}\n", .{kf.type_str});

    var decoded_buf: [4096]u8 = undefined;
    const decoded_len = kes_keyfile.decodeCborHex(kf.cbor_hex, &decoded_buf) orelse {
        std.debug.print("ERROR: malformed cborHex\n", .{});
        return 3;
    };

    std.debug.print("decoded_len: {d}\n", .{decoded_len});

    if (decoded_len != kes_sign.SK_SIZE_6 and decoded_len != kes_sign.SK_FULL_SIZE_6) {
        std.debug.print("ERROR: unexpected key state size {d} (expected {d} or {d})\n", .{ decoded_len, kes_sign.SK_SIZE_6, kes_sign.SK_FULL_SIZE_6 });
        return 3;
    }

    // --- Determine current period ---
    var current_period: u32 = 0;
    if (decoded_len == kes_sign.SK_FULL_SIZE_6) {
        current_period = std.mem.readInt(u32, decoded_buf[kes_sign.SK_SIZE_6..][0..4], .big);
        std.debug.print("embedded_period: {d}\n", .{current_period});
    } else {
        std.debug.print("embedded_period: n/a (608 bytes, assumed 0)\n", .{});
    }

    if (current_period >= target) {
        if (current_period == target) {
            std.debug.print("\nAlready at target period {d}. No evolution needed.\n", .{target});
        } else {
            std.debug.print("ERROR: current period ({d}) > target ({d}), cannot devolve\n", .{ current_period, target });
            return 2;
        }
    }

    // --- Root PK before ---
    const root_pk_before = kes_sign.extractRootPk(decoded_buf[0..decoded_len]) catch {
        std.debug.print("ERROR: cannot extract root PK\n", .{});
        return 3;
    };
    const root_hex_before = std.fmt.bytesToHex(root_pk_before, .lower);
    std.debug.print("\nroot_pk_before: {s}\n", .{&root_hex_before});

    // --- Evolve ---
    // Work on a copy that always has room for the period suffix
    var key_state: [kes_sign.SK_FULL_SIZE_6]u8 = std.mem.zeroes([kes_sign.SK_FULL_SIZE_6]u8);
    @memcpy(key_state[0..decoded_len], decoded_buf[0..decoded_len]);
    const work_len: usize = kes_sign.SK_FULL_SIZE_6; // always use 612-byte form

    // Ensure period suffix is set
    if (decoded_len == kes_sign.SK_SIZE_6) {
        std.mem.writeInt(u32, key_state[kes_sign.SK_SIZE_6..][0..4], current_period, .big);
    }

    if (current_period < target) {
        std.debug.print("evolving: {d} → {d} ({d} steps)\n", .{ current_period, target, target - current_period });

        kes_evolve.evolveToOffset(&key_state, work_len, current_period, target) catch |err| {
            std.debug.print("ERROR: evolution failed: {}\n", .{err});
            return 2;
        };
        std.debug.print("evolution: OK\n", .{});
    }

    // --- Root PK after ---
    const root_pk_after = kes_sign.extractRootPk(key_state[0..work_len]) catch {
        std.debug.print("ERROR: cannot extract root PK after evolution\n", .{});
        return 3;
    };
    const root_hex_after = std.fmt.bytesToHex(root_pk_after, .lower);
    std.debug.print("root_pk_after:  {s}\n", .{&root_hex_after});

    if (!std.mem.eql(u8, &root_pk_before, &root_pk_after)) {
        std.debug.print("FATAL: root PK changed during evolution!\n", .{});
        return 2;
    }
    std.debug.print("root_pk_stable: OK\n", .{});

    // --- Verify period suffix ---
    const final_period = std.mem.readInt(u32, key_state[kes_sign.SK_SIZE_6..][0..4], .big);
    std.debug.print("final_period: {d}\n", .{final_period});
    if (final_period != target) {
        std.debug.print("ERROR: final period ({d}) != target ({d})\n", .{ final_period, target });
        return 2;
    }

    // --- Write output ---
    var out_file = compat.fs.cwd().createFile(out, .{}) catch {
        std.debug.print("ERROR: cannot create {s}\n", .{out});
        return 3;
    };
    defer out_file.close();
    out_file.writeAll(key_state[0..work_len]) catch {
        std.debug.print("ERROR: cannot write {s}\n", .{out});
        return 3;
    };
    std.debug.print("\nwrote evolved key state ({d} bytes) to {s}\n", .{ work_len, out });

    // --- Optional sign+verify test ---
    if (verify_flag) {
        std.debug.print("\n--- Sign+Verify Test ---\n", .{});
        const test_msg = "kes-evolve-verify-v1.8.8";
        var sig: [kes_sign.SUM6_KES_SIG_LEN]u8 = undefined;
        var sig_period: u32 = 0;
        kes_sign.signSum6Kes(&key_state, test_msg, &sig, &sig_period) catch |err| {
            std.debug.print("ERROR: signSum6Kes failed: {}\n", .{err});
            return 2;
        };
        std.debug.print("sign: OK (period={d})\n", .{sig_period});

        const vr = kes_verify.verifySum6Kes(root_pk_after, target, test_msg, &sig);
        std.debug.print("verify: {s}\n", .{kes_verify.resultStr(vr)});

        if (vr != .ok) {
            std.debug.print("\n=== FAIL: sign+verify at period {d} ===\n", .{target});
            return 2;
        }
        std.debug.print("\n=== PASS: sign+verify at period {d} ===\n", .{target});
    } else {
        std.debug.print("\n=== OK ===\n", .{});
    }

    return 0;
}
