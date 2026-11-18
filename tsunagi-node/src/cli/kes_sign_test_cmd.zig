const std = @import("std");
const compat = @import("compat");
const kes_keyfile = @import("../producer/kes_keyfile.zig");
const kes_sign = @import("../producer/crypto/kes_sign.zig");
const kes_verify = @import("../producer/crypto/kes_verify.zig");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

/// Offline KES sign+verify harness with depth-by-depth PK diagnostics.
/// Loads key_state, signs a test message, verifies, prints intermediate values.
/// Exit codes: 0=PASS, 2=FAIL, 3=ERROR (missing files/args)
pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var key_path: ?[]const u8 = null;
    var period_offset: ?u32 = null;
    var allow_mismatch = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--key")) {
            key_path = args_it.next() orelse {
                std.debug.print("ERROR: --key requires a path\n", .{});
                return 3;
            };
        } else if (std.mem.eql(u8, arg, "--period-offset")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --period-offset requires a value (0..63)\n", .{});
                return 3;
            };
            period_offset = std.fmt.parseUnsigned(u32, val, 10) catch {
                std.debug.print("ERROR: invalid --period-offset '{s}'\n", .{val});
                return 3;
            };
        } else if (std.mem.eql(u8, arg, "--allow-mismatch")) {
            allow_mismatch = true;
        }
    }

    if (key_path == null or period_offset == null) {
        std.debug.print("Usage: tsunagi-node kes-sign-test --key <path> --period-offset <0..63> [--allow-mismatch]\n", .{});
        return 3;
    }
    const path = key_path.?;
    const req_period = period_offset.?;

    if (req_period >= 64) {
        std.debug.print("ERROR: --period-offset must be 0..63 (got {d})\n", .{req_period});
        return 3;
    }

    // --- Load key file ---
    std.debug.print("=== KES Sign Test ===\n", .{});
    std.debug.print("key_path: {s}\n", .{path});
    std.debug.print("requested_period_offset: {d}\n", .{req_period});
    std.debug.print("allow_mismatch: {}\n\n", .{allow_mismatch});

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

    const key_state = decoded_buf[0..decoded_len];

    // --- Period check ---
    std.debug.print("\n--- Period ---\n", .{});
    if (decoded_len == kes_sign.SK_FULL_SIZE_6) {
        const embedded = std.mem.readInt(u32, key_state[kes_sign.SK_SIZE_6..][0..4], .big);
        std.debug.print("embedded_key_period: {d}\n", .{embedded});
        if (embedded != req_period) {
            std.debug.print("MISMATCH: embedded_key_period ({d}) != requested_period_offset ({d})\n", .{ embedded, req_period });
            if (!allow_mismatch) {
                std.debug.print("FATAL: period mismatch (use --allow-mismatch to override)\n", .{});
                return 2;
            }
            std.debug.print("WARNING: proceeding with --allow-mismatch\n", .{});
        } else {
            std.debug.print("period_match: OK\n", .{});
        }
    } else {
        std.debug.print("embedded_key_period: n/a (608 bytes, no period suffix)\n", .{});
    }

    // --- Key state depth-by-depth PK dump ---
    std.debug.print("\n--- Key State PKs (depth 6..1) ---\n", .{});
    var d: u32 = 6;
    while (d >= 1) : (d -= 1) {
        const sub = kes_sign.skSize(d - 1);
        const ks_lhs_off = sub + 32;
        const ks_rhs_off = sub + 64;
        // Navigate to the right offset within the key state for this depth
        // At depth 6: offsets are directly in key_state
        // At depth 5: offsets are within key_state[0..skSize(5)]
        // etc — but all are the ACTIVE sub-key path, so offsets accumulate
        // Actually the key_state is a flat buffer where depth d's lhs/rhs are at:
        //   base(d) = skSize(d-1) for the ACTIVE path (always sk[0..skSize(d-1)] recurse)
        // So depth 6 lhs = key_state[skSize(5)+32..+64] = key_state[544..576]
        //    depth 5 lhs = key_state[skSize(4)+32..+64] = key_state[448..480]
        //    depth 4 lhs = key_state[skSize(3)+32..+64] = key_state[352..384]
        // This only works because the active sub-key is always at offset 0 of each level
        if (ks_rhs_off + 32 > kes_sign.SK_SIZE_6) {
            std.debug.print("  depth {d}: (out of bounds)\n", .{d});
            continue;
        }
        var ks_lhs: [32]u8 = undefined;
        var ks_rhs: [32]u8 = undefined;
        @memcpy(&ks_lhs, key_state[ks_lhs_off..][0..32]);
        @memcpy(&ks_rhs, key_state[ks_rhs_off..][0..32]);
        const ks_hash = kes_verify.hashPair(ks_lhs, ks_rhs);
        const ks_lhs_hex = std.fmt.bytesToHex(ks_lhs, .lower);
        const ks_rhs_hex = std.fmt.bytesToHex(ks_rhs, .lower);
        const ks_hash_hex = std.fmt.bytesToHex(ks_hash, .lower);
        std.debug.print("  depth {d}:\n", .{d});
        std.debug.print("    ks_lhs_pk: {s}\n", .{&ks_lhs_hex});
        std.debug.print("    ks_rhs_pk: {s}\n", .{&ks_rhs_hex});
        std.debug.print("    hashPair:  {s}\n", .{&ks_hash_hex});
    }

    // --- Root PK ---
    std.debug.print("\n--- Root PK ---\n", .{});
    const root_pk = kes_sign.extractRootPk(key_state) catch {
        std.debug.print("ERROR: cannot extract root PK\n", .{});
        return 3;
    };
    const root_pk_hex = std.fmt.bytesToHex(root_pk, .lower);
    std.debug.print("root_pk (hashPair of depth-6 lhs||rhs): {s}\n", .{&root_pk_hex});

    // --- Test message ---
    const test_msg = "kes-sign-test-offline-v1.8.7";
    std.debug.print("\n--- Message ---\n", .{});
    std.debug.print("msg_len: {d}\n", .{test_msg.len});
    const msg_hex = std.fmt.bytesToHex(test_msg[0..@min(16, test_msg.len)].*, .lower);
    std.debug.print("msg_first_16_hex: {s}\n", .{&msg_hex});

    // --- Sign ---
    std.debug.print("\n--- Sign ---\n", .{});
    var sig: [kes_sign.SUM6_KES_SIG_LEN]u8 = undefined;
    var out_period: u32 = 0;
    kes_sign.signSum6Kes(key_state, test_msg, &sig, &out_period) catch |err| {
        std.debug.print("ERROR: signSum6Kes failed: {}\n", .{err});
        return 2;
    };
    std.debug.print("sign: OK\n", .{});
    std.debug.print("out_period: {d}\n", .{out_period});
    std.debug.print("sig_len: {d}\n", .{sig.len});
    const sig_prefix_hex = std.fmt.bytesToHex(sig[0..8].*, .lower);
    std.debug.print("sig_prefix: {s}\n", .{&sig_prefix_hex});

    // --- Signature depth-by-depth PK dump ---
    std.debug.print("\n--- Signature PKs (depth 6..1) ---\n", .{});
    {
        var sd: u32 = 6;
        while (sd >= 1) : (sd -= 1) {
            const inner_sig_len = kes_verify.sigSize(sd - 1);
            if (inner_sig_len + 64 > sig.len) {
                std.debug.print("  depth {d}: (out of bounds in sig)\n", .{sd});
                continue;
            }
            var sig_lhs: [32]u8 = undefined;
            var sig_rhs: [32]u8 = undefined;
            @memcpy(&sig_lhs, sig[inner_sig_len..][0..32]);
            @memcpy(&sig_rhs, sig[inner_sig_len + 32 ..][0..32]);
            const sig_hash = kes_verify.hashPair(sig_lhs, sig_rhs);
            const sig_lhs_hex = std.fmt.bytesToHex(sig_lhs, .lower);
            const sig_rhs_hex = std.fmt.bytesToHex(sig_rhs, .lower);
            const sig_hash_hex = std.fmt.bytesToHex(sig_hash, .lower);
            std.debug.print("  depth {d}:\n", .{sd});
            std.debug.print("    sig_lhs_pk: {s}\n", .{&sig_lhs_hex});
            std.debug.print("    sig_rhs_pk: {s}\n", .{&sig_rhs_hex});
            std.debug.print("    hashPair:   {s}\n", .{&sig_hash_hex});
        }
    }

    // --- Compare sig PKs vs key state PKs ---
    std.debug.print("\n--- PK Comparison (sig vs key_state, depth 6..1) ---\n", .{});
    {
        var cd: u32 = 6;
        while (cd >= 1) : (cd -= 1) {
            const inner_sig_len = kes_verify.sigSize(cd - 1);
            const sub = kes_sign.skSize(cd - 1);
            const ks_lhs_off = sub + 32;
            const ks_rhs_off = sub + 64;

            if (inner_sig_len + 64 > sig.len or ks_rhs_off + 32 > kes_sign.SK_SIZE_6) {
                std.debug.print("  depth {d}: SKIP (out of bounds)\n", .{cd});
                continue;
            }

            const sig_lhs_match = std.mem.eql(u8, sig[inner_sig_len..][0..32], key_state[ks_lhs_off..][0..32]);
            const sig_rhs_match = std.mem.eql(u8, sig[inner_sig_len + 32 ..][0..32], key_state[ks_rhs_off..][0..32]);
            std.debug.print("  depth {d}: lhs_match={} rhs_match={}\n", .{ cd, sig_lhs_match, sig_rhs_match });
        }
    }

    // --- Verify ---
    std.debug.print("\n--- Verify ---\n", .{});
    std.debug.print("verify_pk: {s}\n", .{&root_pk_hex});
    std.debug.print("verify_period: {d}\n", .{req_period});
    const vr = kes_verify.verifySum6Kes(root_pk, req_period, test_msg, &sig);
    std.debug.print("verify_result: {s}\n", .{kes_verify.resultStr(vr)});

    if (vr == .ok) {
        std.debug.print("\n=== PASS ===\n", .{});
        return 0;
    }

    // --- Diagnosis for PK_MISMATCH ---
    if (vr == .pk_mismatch) {
        std.debug.print("\n--- PK_MISMATCH Diagnosis ---\n", .{});
        // Trace the verification path to find where mismatch occurs
        std.debug.print("Verification traversal (period={d}):\n", .{req_period});
        var trace_pk = root_pk;
        var trace_period: u32 = req_period;
        var trace_depth: u32 = 6;
        while (trace_depth >= 1) : (trace_depth -= 1) {
            const inner_len = kes_verify.sigSize(trace_depth - 1);
            if (inner_len + 64 > sig.len) break;
            var t_lhs: [32]u8 = undefined;
            var t_rhs: [32]u8 = undefined;
            @memcpy(&t_lhs, sig[inner_len..][0..32]);
            @memcpy(&t_rhs, sig[inner_len + 32 ..][0..32]);
            const computed = kes_verify.hashPair(t_lhs, t_rhs);
            const match = std.mem.eql(u8, &computed, &trace_pk);
            const half: u32 = @as(u32, 1) << @intCast(trace_depth - 1);
            const go_right = trace_period >= half;
            const trace_pk_hex = std.fmt.bytesToHex(trace_pk, .lower);
            const computed_hex = std.fmt.bytesToHex(computed, .lower);
            std.debug.print("  depth {d}: period={d} half={d} go={s} pk_match={}\n", .{
                trace_depth, trace_period, half, if (go_right) "RIGHT" else "LEFT ", match,
            });
            if (!match) {
                std.debug.print("    expected_pk: {s}\n", .{&trace_pk_hex});
                std.debug.print("    computed_pk: {s}\n", .{&computed_hex});
                std.debug.print("    >>> MISMATCH at depth {d} <<<\n", .{trace_depth});
                break;
            }
            // Descend
            if (go_right) {
                trace_pk = t_rhs;
                trace_period -= half;
            } else {
                trace_pk = t_lhs;
            }
        }
    }

    std.debug.print("\n=== FAIL: {s} ===\n", .{kes_verify.resultStr(vr)});
    return 2;
}
