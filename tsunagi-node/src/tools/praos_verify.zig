// PRAOS BIT-EQUIVALENCE HARNESS — standalone diagnostic binary.
//
// Reads CLI inputs (slot, epoch_nonce, sigma, asc, vrf_skey_path), computes
// TSUNAGI's exact Praos leader-eligibility path stage-by-stage, and prints
// every intermediate byte for spec equivalence archaeology.
//
// DOES NOT touch the live validator runtime.
// DOES NOT mutate any state.
// DOES NOT open sockets, broadcast, or write any files.
// DOES NOT take or modify keys other than reading the VRF skey for VRF.prove.
//
// Stage 1 (VRF input)    bit-mirror of  src/producer/vrf.zig:301-309
// Stage 2-3 (VRF prove)  direct call to src/producer/crypto/sodium_vrf.zig
// Stage 4 (leader value) bit-mirror of  src/producer/producer.zig:4659-4670
// Stage 5 (threshold)    direct call to src/producer/crypto/praos_threshold_e34.zig
// Stage 6 (compare)      bit-mirror of  src/producer/producer.zig:4714-4718
//
// Build: zig build praos-verify
// Run:
//   ./zig-out/bin/praos-verify \
//       --slot 112242644 \
//       --epoch-nonce-hex 0063be7469282807cd974a8948dcab91d0cab36b65efdff52a4066f8dd97b7fd \
//       --sigma-x1e9 480577 \
//       --asc-x1e6 50000 \
//       --vrf-skey /path/to/preview-bp/vrf.skey

const std = @import("std");
const compat = @import("compat");
// Named module imports (see build.zig praos-verify target).
// These modules are the EXACT same source files the runtime uses:
//   sodium_vrf -> src/producer/crypto/sodium_vrf.zig
//   praos_e34  -> src/producer/crypto/praos_threshold_e34.zig
const sodium_vrf = @import("sodium_vrf");
const praos_e34 = @import("praos_e34");

const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

const Args = struct {
    slot: u64,
    nonce_hex: []const u8,
    sigma_x1e9: u64,
    asc_x1e6: u64,
    vrf_skey_path: []const u8,
};

fn printHex(bytes: []const u8) void {
    for (bytes) |b| std.debug.print("{x:0>2}", .{b});
}

fn printHelp() void {
    const txt =
        \\Usage: praos-verify --slot N --epoch-nonce-hex HEX --sigma-x1e9 N --vrf-skey PATH [--asc-x1e6 N]
        \\
        \\Required:
        \\  --slot N                Slot to evaluate (u64)
        \\  --epoch-nonce-hex HEX   32-byte epoch nonce as 64 hex chars
        \\  --sigma-x1e9 N          Pool stake fraction, scaled by 1e9
        \\  --vrf-skey PATH         Path to cardano VRF skey (JSON envelope with cborHex 5840.. or 5820..)
        \\
        \\Optional:
        \\  --asc-x1e6 N            Active slot coefficient, scaled by 1e6 (default 50000 = 0.05)
        \\
        \\Output: per-stage bytes printed to stdout for spec equivalence comparison.
        \\
        \\This tool is read-only with respect to all TSUNAGI runtime state. It does not
        \\interact with the live validator, does not broadcast, and does not write files.
        \\
    ;
    std.debug.print("{s}", .{txt});
}

fn parseArgs(allocator: std.mem.Allocator) !Args {
    var slot: ?u64 = null;
    var nonce_hex: ?[]const u8 = null;
    var sigma: ?u64 = null;
    var asc: ?u64 = null;
    var vrf_path: ?[]const u8 = null;

    const args = try compat.argsAlloc(allocator);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--slot")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            slot = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--epoch-nonce-hex")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            nonce_hex = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--sigma-x1e9")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            sigma = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--asc-x1e6")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            asc = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--vrf-skey")) {
            i += 1;
            if (i >= args.len) return error.MissingArg;
            vrf_path = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            std.process.exit(0);
        }
    }

    return Args{
        .slot = slot orelse return error.MissingSlot,
        .nonce_hex = nonce_hex orelse return error.MissingNonce,
        .sigma_x1e9 = sigma orelse return error.MissingSigma,
        .asc_x1e6 = asc orelse 50000,
        .vrf_skey_path = vrf_path orelse return error.MissingVrfSkey,
    };
}

/// Load VRF seed from cardano-cli JSON envelope file.
/// Accepts cborHex prefixed with "5840" (64-byte expanded key — first 32 bytes are seed)
/// or "5820" (32-byte seed directly).
fn loadVrfSeed(path: []const u8, seed_out: *[sodium_vrf.SEEDBYTES]u8) !void {
    var file = try compat.fs.cwd().openFile(path, .{});
    defer file.close();
    var buf: [4096]u8 = undefined;
    const n = try file.readAll(&buf);
    const content = buf[0..n];

    const marker = "\"cborHex\"";
    const idx = std.mem.indexOf(u8, content, marker) orelse return error.NoCborHex;
    var rest = content[idx + marker.len ..];
    while (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t' or
        rest[0] == '\n' or rest[0] == ':' or rest[0] == '"'))
    {
        rest = rest[1..];
    }
    var end: usize = 0;
    while (end < rest.len and rest[end] != '"') : (end += 1) {}
    const cbor_hex = rest[0..end];

    if (std.mem.startsWith(u8, cbor_hex, "5840") and cbor_hex.len >= 4 + 64) {
        _ = try std.fmt.hexToBytes(seed_out, cbor_hex[4 .. 4 + 64]);
    } else if (std.mem.startsWith(u8, cbor_hex, "5820") and cbor_hex.len >= 4 + 64) {
        _ = try std.fmt.hexToBytes(seed_out, cbor_hex[4 .. 4 + 64]);
    } else {
        return error.UnknownVrfSkeyFormat;
    }
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = parseArgs(allocator) catch |e| {
        std.debug.print("error: {s}\n\n", .{@errorName(e)});
        printHelp();
        std.process.exit(1);
    };

    if (!sodium_vrf.sodiumInit()) {
        std.debug.print("error: libsodium init failed\n", .{});
        std.process.exit(1);
    }

    if (args.nonce_hex.len != 64) {
        std.debug.print("error: --epoch-nonce-hex must be 64 hex chars (32 bytes), got {d}\n", .{args.nonce_hex.len});
        std.process.exit(1);
    }
    var nonce: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&nonce, args.nonce_hex) catch {
        std.debug.print("error: invalid hex in --epoch-nonce-hex\n", .{});
        std.process.exit(1);
    };

    var seed: [sodium_vrf.SEEDBYTES]u8 = undefined;
    loadVrfSeed(args.vrf_skey_path, &seed) catch |e| {
        std.debug.print("error loading VRF skey from {s}: {s}\n", .{ args.vrf_skey_path, @errorName(e) });
        std.process.exit(1);
    };
    const kp = sodium_vrf.keypairFromSeed(&seed) orelse {
        std.debug.print("error: VRF keypair derivation failed\n", .{});
        std.process.exit(1);
    };

    // ── REPORT ─────────────────────────────────────────────────────────
    std.debug.print("PRAOS_VERIFY: slot={d}\n", .{args.slot});
    std.debug.print("  inputs:\n", .{});
    std.debug.print("    epoch_nonce_hex={s}\n", .{args.nonce_hex});
    std.debug.print("    sigma_x1e9={d}\n", .{args.sigma_x1e9});
    std.debug.print("    asc_x1e6={d}\n", .{args.asc_x1e6});
    std.debug.print("    vrf_skey_path={s}\n", .{args.vrf_skey_path});
    std.debug.print("    vrf_pubkey_hex=", .{});
    printHex(&kp.pk);
    std.debug.print("\n", .{});

    // ── Stage 1: VRF input construction ────────────────────────────────
    // Bit-for-bit mirror of src/producer/vrf.zig:301-309
    //   "Praos VRF input: blake2b256(word64BE(slot) || epoch_nonce(32))"
    //   Source comment: "L"/"N" prefixes apply to VRF OUTPUT hashing, not to input.
    var preimage: [8 + 32]u8 = undefined;
    std.mem.writeInt(u64, preimage[0..8], args.slot, .big);
    @memcpy(preimage[8..40], &nonce);
    var msg: [32]u8 = undefined;
    Blake2b256.hash(&preimage, &msg, .{});

    std.debug.print("  stage1_vrf_input:\n", .{});
    std.debug.print("    preimage_hex=", .{});
    printHex(&preimage);
    std.debug.print("\n", .{});
    std.debug.print("    msg_hex=", .{});
    printHex(&msg);
    std.debug.print("\n", .{});

    // ── Stage 2: VRF prove ─────────────────────────────────────────────
    const prove = sodium_vrf.prove(&kp.sk, &msg) orelse {
        std.debug.print("error: VRF prove failed (libsodium returned non-zero)\n", .{});
        std.process.exit(2);
    };

    std.debug.print("  stage2_vrf_prove:\n", .{});
    std.debug.print("    proof_hex=", .{});
    printHex(&prove.proof);
    std.debug.print("\n", .{});

    // ── Stage 3: VRF output ────────────────────────────────────────────
    std.debug.print("  stage3_vrf_output:\n", .{});
    std.debug.print("    output_hex=", .{});
    printHex(&prove.output);
    std.debug.print("\n", .{});

    const verify_ok = sodium_vrf.verify(&kp.pk, &prove.proof, &msg) != null;
    std.debug.print("    verify_ok={}\n", .{verify_ok});

    // ── Stage 4: Leader value ──────────────────────────────────────────
    // Bit-for-bit mirror of src/producer/producer.zig:4659-4670 (vrfOutputToU_x1e12)
    //   "Praos leader value: blake2b256('L' || vrf_output)"
    var leader_input: [1 + 64]u8 = undefined;
    leader_input[0] = 'L';
    @memcpy(leader_input[1..65], &prove.output);
    var leader_hash: [32]u8 = undefined;
    Blake2b256.hash(&leader_input, &leader_hash, .{});
    const r = std.mem.readInt(u64, leader_hash[0..8], .big);
    const u_128: u128 = (@as(u128, r) * 1_000_000_000_000) / @as(u128, std.math.maxInt(u64));
    const u_x1e12: u64 = @intCast(@max(@as(u128, 1), u_128));

    std.debug.print("  stage4_leader_value:\n", .{});
    std.debug.print("    leader_input_hex=", .{});
    printHex(&leader_input);
    std.debug.print("\n", .{});
    std.debug.print("    leader_hash_hex=", .{});
    printHex(&leader_hash);
    std.debug.print("\n", .{});
    std.debug.print("    leader_first8_hex=", .{});
    printHex(leader_hash[0..8]);
    std.debug.print("\n", .{});
    std.debug.print("    r_u64={d}\n", .{r});
    std.debug.print("    u_x1e12={d}\n", .{u_x1e12});

    // ── Stage 5: Threshold ─────────────────────────────────────────────
    // Direct call to runtime function (src/producer/crypto/praos_threshold_e34.zig).
    const thresh_x1e12 = praos_e34.computeThresholdX1e12(args.sigma_x1e9, args.asc_x1e6);

    std.debug.print("  stage5_threshold:\n", .{});
    std.debug.print("    thresh_x1e12={d}\n", .{thresh_x1e12});

    // ── Stage 6: Decide ────────────────────────────────────────────────
    // Bit-for-bit mirror of src/producer/producer.zig:4714-4718
    //   "Leader if u < T (strict less-than, spec-aligned)"
    const leader: u64 = if (u_x1e12 < thresh_x1e12) 1 else 0;
    const reason: u64 = if (leader == 1) 0 else 6;

    std.debug.print("  stage6_decide:\n", .{});
    std.debug.print("    leader={d}\n", .{leader});
    std.debug.print("    reason={d}\n", .{reason});

    std.debug.print("PRAOS_VERIFY_END\n", .{});
}
