const std = @import("std");
const producer = @import("../producer/producer.zig");

pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    _ = alloc;

    var stake_x1e9: ?u64 = null;
    var asc_x1e6: ?u64 = null;
    var vrf_hex: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--stake-x1e9")) {
            const v = args_it.next() orelse {
                std.debug.print("missing value for --stake-x1e9\n", .{});
                return 1;
            };
            stake_x1e9 = std.fmt.parseUnsigned(u64, v, 10) catch {
                std.debug.print("invalid --stake-x1e9: {s}\n", .{v});
                return 1;
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--asc-x1e6")) {
            const v = args_it.next() orelse {
                std.debug.print("missing value for --asc-x1e6\n", .{});
                return 1;
            };
            asc_x1e6 = std.fmt.parseUnsigned(u64, v, 10) catch {
                std.debug.print("invalid --asc-x1e6: {s}\n", .{v});
                return 1;
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--vrf-output-hex")) {
            vrf_hex = args_it.next() orelse {
                std.debug.print("missing value for --vrf-output-hex\n", .{});
                return 1;
            };
            continue;
        }
        std.debug.print("unknown arg: {s}\n", .{arg});
        return 1;
    }

    const s = stake_x1e9 orelse {
        std.debug.print("missing --stake-x1e9\n", .{});
        return 1;
    };
    const a = asc_x1e6 orelse {
        std.debug.print("missing --asc-x1e6\n", .{});
        return 1;
    };
    const hex = vrf_hex orelse {
        std.debug.print("missing --vrf-output-hex\n", .{});
        return 1;
    };

    if (hex.len != 128) {
        std.debug.print("--vrf-output-hex must be exactly 128 hex chars (64 bytes), got {d}\n", .{hex.len});
        return 1;
    }

    var vrf_bytes: [64]u8 = undefined;
    _ = std.fmt.hexToBytes(&vrf_bytes, hex) catch {
        std.debug.print("invalid hex in --vrf-output-hex\n", .{});
        return 1;
    };

    // Compute prob_x1e6 = (stake_x1e9 * asc_x1e6) / 1e9
    const prob_x1e6: u64 = @intCast((@as(u128, s) * @as(u128, a)) / 1_000_000_000);

    // Compute u_x1e12 using shared helper
    const u_x1e12 = producer.vrfOutputToU_x1e12(vrf_bytes);

    // Compute thresh_x1e12 using same math as computePraosLeaderDecision
    const f_x1e12: u128 = @as(u128, a) * 1_000_000;
    const sigma_x1e12: u128 = @as(u128, s) * 1_000;
    const thresh_128: u128 = (f_x1e12 * sigma_x1e12) / 1_000_000_000_000;
    const thresh_x1e12: u64 = @intCast(@min(thresh_128, 1_000_000_000_000));

    const leader = u_x1e12 < thresh_x1e12;

    // Format u and T as 0.NNNNNN
    var u_buf: [16]u8 = undefined;
    const u_display = std.fmt.bufPrint(&u_buf, "0.{d:0>6}", .{u_x1e12 / 1_000_000}) catch "?";
    var t_buf: [16]u8 = undefined;
    const t_display = std.fmt.bufPrint(&t_buf, "0.{d:0>6}", .{thresh_x1e12 / 1_000_000}) catch "?";

    std.debug.print("=== TSUNAGI Praos Self-Test ===\n\n", .{});
    std.debug.print("  stake_x1e9={d} asc_x1e6={d} prob_x1e6={d}\n", .{ s, a, prob_x1e6 });
    std.debug.print("  u_x1e12={d} ({s})\n", .{ u_x1e12, u_display });
    std.debug.print("  T_x1e12={d} ({s})\n", .{ thresh_x1e12, t_display });
    std.debug.print("  leader = (u < T) {s}\n", .{if (leader) "YES" else "NO"});

    return 0;
}
