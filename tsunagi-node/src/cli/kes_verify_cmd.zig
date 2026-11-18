const std = @import("std");
const kes_verify = @import("../producer/crypto/kes_verify.zig");

/// Single KES signature verification or self-test.
/// Exit codes: 0 = OK/PASS, 1 = selftest failure, 2 = verification failed,
///             3 = missing args, 4 = malformed hex.
pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var opt_pk: ?[]const u8 = null;
    var opt_period: ?u32 = null;
    var opt_msg: ?[]const u8 = null;
    var opt_sig: ?[]const u8 = null;
    var selftest = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--selftest")) {
            selftest = true;
        } else if (std.mem.eql(u8, arg, "--pk")) {
            opt_pk = args_it.next() orelse {
                std.debug.print("ERROR: --pk requires a hex value\n", .{});
                return 3;
            };
        } else if (std.mem.eql(u8, arg, "--period")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --period requires a value\n", .{});
                return 3;
            };
            opt_period = std.fmt.parseInt(u32, val, 10) catch {
                std.debug.print("ERROR: invalid --period value: {s}\n", .{val});
                return 3;
            };
        } else if (std.mem.eql(u8, arg, "--msg")) {
            opt_msg = args_it.next() orelse {
                std.debug.print("ERROR: --msg requires a hex value\n", .{});
                return 3;
            };
        } else if (std.mem.eql(u8, arg, "--sig")) {
            opt_sig = args_it.next() orelse {
                std.debug.print("ERROR: --sig requires a hex value\n", .{});
                return 3;
            };
        }
    }

    if (selftest) {
        return runSelfTest();
    }

    // Require all args for single verification
    if (opt_pk == null or opt_period == null or opt_sig == null) {
        std.debug.print("Usage: tsunagi-node kes-verify --pk <64hex> --period <N> --msg <hex> --sig <896hex>\n", .{});
        std.debug.print("       tsunagi-node kes-verify --selftest\n", .{});
        return 3;
    }

    const pk_hex = opt_pk.?;
    const period = opt_period.?;
    const sig_hex = opt_sig.?;

    // Decode pk (64 hex → 32 bytes)
    if (pk_hex.len != 64) {
        std.debug.print("ERROR: --pk must be 64 hex chars (32 bytes), got {d}\n", .{pk_hex.len});
        return 4;
    }
    var pk: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&pk, pk_hex) catch {
        std.debug.print("ERROR: --pk contains invalid hex\n", .{});
        return 4;
    };

    // Decode sig (896 hex → 448 bytes)
    if (sig_hex.len != 896) {
        std.debug.print("ERROR: --sig must be 896 hex chars (448 bytes), got {d}\n", .{sig_hex.len});
        return 4;
    }
    var sig: [448]u8 = undefined;
    _ = std.fmt.hexToBytes(&sig, sig_hex) catch {
        std.debug.print("ERROR: --sig contains invalid hex\n", .{});
        return 4;
    };

    // Decode msg (variable length hex → bytes)
    var msg_buf: [8192]u8 = undefined;
    var msg_len: usize = 0;
    if (opt_msg) |msg_hex| {
        if (msg_hex.len % 2 != 0) {
            std.debug.print("ERROR: --msg hex length must be even, got {d}\n", .{msg_hex.len});
            return 4;
        }
        msg_len = msg_hex.len / 2;
        if (msg_len > msg_buf.len) {
            std.debug.print("ERROR: --msg too long ({d} bytes, max {d})\n", .{ msg_len, msg_buf.len });
            return 4;
        }
        _ = std.fmt.hexToBytes(msg_buf[0..msg_len], msg_hex) catch {
            std.debug.print("ERROR: --msg contains invalid hex\n", .{});
            return 4;
        };
    }

    _ = alloc;

    const result = kes_verify.verifySum6Kes(pk, period, msg_buf[0..msg_len], &sig);
    const result_str = kes_verify.resultStr(result);

    std.debug.print("KES-VERIFY: result={s} pk={s} period={d} msg_len={d} sig_len=448\n", .{
        result_str,
        pk_hex,
        period,
        msg_len,
    });

    if (result == .ok) {
        return 0;
    } else {
        return 2;
    }
}

fn runSelfTest() u8 {
    std.debug.print("=== TSUNAGI KES Verify Self-Test (4 vectors) ===\n\n", .{});
    std.debug.print("  NOTE: tests input validation + base-case Ed25519 (depth 0) only.\n", .{});
    std.debug.print("  Full depth-6 correctness requires external reference vectors.\n\n", .{});

    const result = kes_verify.selfTest();
    const total = result.pass + result.fail;

    std.debug.print("\n=== KES Verify Self-Test: {s} ({d}/{d} passed) ===\n", .{
        if (result.fail == 0) "PASS" else "FAIL",
        result.pass,
        total,
    });

    if (result.fail == 0) {
        return 0;
    } else {
        return 1;
    }
}
