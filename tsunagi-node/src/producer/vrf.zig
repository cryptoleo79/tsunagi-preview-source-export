const std = @import("std");
const compat = @import("compat");
const sodium_vrf = @import("crypto/sodium_vrf.zig");

// Reason codes (v0.8.95)
// 0 = ok
// 1 = disabled
// 2 = missing_key_path
// 3 = missing_key_file
// 4 = bad_perms
// 5 = unreadable
// 6 = test_stub (unused — real VRF now)
// 7 = clock_bad
// 8 = init_failed
// 9 = bad_seed
// 10 = prove_failed

pub const VrfConfig = struct {
    enabled: bool,
    parse_ok: bool,
    key_path: ?[]const u8,
    reason_code_last: u8,
    // v0.8.95: real VRF state
    init_ok: bool,
    seed: ?[32]u8,
    pk: ?[32]u8,
    sk: ?[64]u8,
};

pub const VrfResult = struct {
    attempted: bool,
    checked: bool,
    eligible: bool,
    proof_present: bool,
    output_present: bool,
    probability_x1e6: u64,
    reason_code: u8,
    // v0.8.95: real VRF
    verify_ok: bool,
    output_prefix: u64,
    // v0.9.8: raw proof/output bytes for persistence
    proof_bytes: [sodium_vrf.PROOFBYTES]u8,
    output_bytes: [sodium_vrf.OUTPUTBYTES]u8,
    proof_len: u64,
    output_len: u64,
    proof_prefix: u64,
};

fn defaultResult() VrfResult {
    return VrfResult{
        .attempted = false,
        .checked = false,
        .eligible = false,
        .proof_present = false,
        .output_present = false,
        .probability_x1e6 = 0,
        .reason_code = 0,
        .verify_ok = false,
        .output_prefix = 0,
        .proof_bytes = [_]u8{0} ** sodium_vrf.PROOFBYTES,
        .output_bytes = [_]u8{0} ** sodium_vrf.OUTPUTBYTES,
        .proof_len = 0,
        .output_len = 0,
        .proof_prefix = 0,
    };
}

pub fn loadConfig(alloc: std.mem.Allocator) VrfConfig {
    const env_enable = compat.getEnvVarOwned(alloc, "TSUNAGI_VRF_ENABLE") catch null;
    const enabled = if (env_enable) |v| blk: {
        defer alloc.free(v);
        break :blk std.mem.eql(u8, v, "1");
    } else false;

    if (!enabled) {
        std.debug.print("VRF: enabled=0 ok=1 reason=1 path=n/a\n", .{});
        return VrfConfig{
            .enabled = false,
            .parse_ok = true,
            .key_path = null,
            .reason_code_last = 1,
            .init_ok = false,
            .seed = null,
            .pk = null,
            .sk = null,
        };
    }

    // Support both TSUNAGI_VRF_SKEY_PATH and TSUNAGI_VRF_KEY_PATH for compatibility
    const key_path = (compat.getEnvVarOwned(alloc, "TSUNAGI_VRF_SKEY_PATH") catch null) orelse
        (compat.getEnvVarOwned(alloc, "TSUNAGI_VRF_KEY_PATH") catch null);

    if (key_path == null or key_path.?.len == 0) {
        std.debug.print("VRF: enabled=1 ok=0 reason=2 path=n/a\n", .{});
        return VrfConfig{
            .enabled = true,
            .parse_ok = false,
            .key_path = null,
            .reason_code_last = 2,
            .init_ok = false,
            .seed = null,
            .pk = null,
            .sk = null,
        };
    }

    const path = key_path.?;

    // Check file exists
    const file_exists = blk: {
        var f = compat.fs.cwd().openFile(path, .{}) catch break :blk false;
        f.close();
        break :blk true;
    };
    if (!file_exists) {
        std.debug.print("VRF: enabled=1 ok=0 reason=3 path={s}\n", .{path});
        return VrfConfig{
            .enabled = true,
            .parse_ok = false,
            .key_path = key_path,
            .reason_code_last = 3,
            .init_ok = false,
            .seed = null,
            .pk = null,
            .sk = null,
        };
    }

    // Check permissions (0600)
    const perms_ok = blk: {
        const stat = compat.fs.cwd().statFile(path) catch break :blk false;
        break :blk (stat.permissions.toMode() & 0o077) == 0;
    };
    if (!perms_ok) {
        std.debug.print("VRF: enabled=1 ok=0 reason=4 path={s}\n", .{path});
        return VrfConfig{
            .enabled = true,
            .parse_ok = false,
            .key_path = key_path,
            .reason_code_last = 4,
            .init_ok = false,
            .seed = null,
            .pk = null,
            .sk = null,
        };
    }

    // Check readable + read content for seed extraction
    const file_content = blk: {
        var f = compat.fs.cwd().openFile(path, .{ .mode = .read_only }) catch {
            std.debug.print("VRF: enabled=1 ok=0 reason=5 path={s}\n", .{path});
            break :blk null;
        };
        defer f.close();
        break :blk f.readToEndAlloc(alloc, 8192) catch null;
    };
    if (file_content == null) {
        return VrfConfig{
            .enabled = true,
            .parse_ok = false,
            .key_path = key_path,
            .reason_code_last = 5,
            .init_ok = false,
            .seed = null,
            .pk = null,
            .sk = null,
        };
    }
    const content = file_content.?;

    // Parse seed from cborHex in JSON envelope
    const seed_opt = parseCborHexSeed(content);
    if (seed_opt == null) {
        std.debug.print("VRF: enabled=1 ok=1 reason=9 path={s} (bad_seed)\n", .{path});
        return VrfConfig{
            .enabled = true,
            .parse_ok = true,
            .key_path = key_path,
            .reason_code_last = 9,
            .init_ok = false,
            .seed = null,
            .pk = null,
            .sk = null,
        };
    }
    const seed = seed_opt.?;

    // Initialize libsodium
    if (!sodium_vrf.sodiumInit()) {
        std.debug.print("VRF: enabled=1 ok=1 reason=8 path={s} (sodium_init failed)\n", .{path});
        return VrfConfig{
            .enabled = true,
            .parse_ok = true,
            .key_path = key_path,
            .reason_code_last = 8,
            .init_ok = false,
            .seed = seed,
            .pk = null,
            .sk = null,
        };
    }

    // Derive keypair from seed
    const kp = sodium_vrf.keypairFromSeed(&seed) orelse {
        std.debug.print("VRF: enabled=1 ok=1 reason=8 path={s} (keypair_from_seed failed)\n", .{path});
        return VrfConfig{
            .enabled = true,
            .parse_ok = true,
            .key_path = key_path,
            .reason_code_last = 8,
            .init_ok = false,
            .seed = seed,
            .pk = null,
            .sk = null,
        };
    };

    std.debug.print("VRF: enabled=1 ok=1 reason=0 path={s} init_ok=1\n", .{path});
    return VrfConfig{
        .enabled = true,
        .parse_ok = true,
        .key_path = key_path,
        .reason_code_last = 0,
        .init_ok = true,
        .seed = seed,
        .pk = kp.pk,
        .sk = kp.sk,
    };
}

/// Parse 32-byte seed from Cardano VRF skey JSON envelope cborHex field.
/// cborHex is CBOR-encoded: prefix "5820" (byte string, 32 bytes) + 64 hex chars.
fn parseCborHexSeed(content: []const u8) ?[32]u8 {
    // Try both "cborHex":"..." and "cborHex": "..." (with optional space)
    const marker_nospace = "\"cborHex\":\"";
    const marker_space = "\"cborHex\": \"";
    var hex_start: usize = 0;
    if (std.mem.indexOf(u8, content, marker_nospace)) |s| {
        hex_start = s + marker_nospace.len;
    } else if (std.mem.indexOf(u8, content, marker_space)) |s| {
        hex_start = s + marker_space.len;
    } else return null;
    const hex_end = std.mem.indexOfPos(u8, content, hex_start, "\"") orelse return null;
    const hex_str = content[hex_start..hex_end];

    // Accept CBOR prefix 5820 (32-byte seed) or 5840 (64-byte expanded VRF key)
    if (hex_str.len >= 132 and std.mem.eql(u8, hex_str[0..4], "5840")) {
        // VrfSigningKey_PraosVRF: 64 bytes — first 32 are the seed
        var seed: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&seed, hex_str[4..68]) catch return null;
        return seed;
    }

    // 5820: 32-byte seed directly
    if (hex_str.len < 68) return null;
    if (!std.mem.eql(u8, hex_str[0..4], "5820")) return null;

    var seed: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&seed, hex_str[4..68]) catch return null;
    return seed;
}

pub fn checkLeader(cfg: *const VrfConfig, slot: u64, epoch_nonce: ?*const [32]u8, prob_x1e6: u64, clock_ok: bool) VrfResult {
    if (!cfg.enabled) {
        var r = defaultResult();
        r.reason_code = 1;
        return r;
    }

    if (!clock_ok) {
        var r = defaultResult();
        r.attempted = true;
        r.probability_x1e6 = prob_x1e6;
        r.reason_code = 7;
        return r;
    }

    if (!cfg.parse_ok) {
        var r = defaultResult();
        r.attempted = true;
        r.probability_x1e6 = prob_x1e6;
        r.reason_code = cfg.reason_code_last;
        return r;
    }

    if (!cfg.init_ok) {
        var r = defaultResult();
        r.attempted = true;
        r.probability_x1e6 = prob_x1e6;
        r.reason_code = cfg.reason_code_last; // 8 or 9
        return r;
    }

    const nonce = epoch_nonce orelse {
        var r = defaultResult();
        r.attempted = true;
        r.probability_x1e6 = prob_x1e6;
        r.reason_code = 11; // missing epoch nonce
        return r;
    };

    // Praos VRF input: blake2b256(word64BE(slot) || epoch_nonce(32))
    // Ref: Ouroboros.Consensus.Protocol.Praos.VRF mkInputVRF
    // Note: "L"/"N" prefixes apply to VRF OUTPUT hashing, not to input.
    var seed_preimage: [8 + 32]u8 = undefined;
    std.mem.writeInt(u64, seed_preimage[0..8], slot, .big);
    @memcpy(seed_preimage[8..40], nonce);
    const Blake2b256 = std.crypto.hash.blake2.Blake2b256;
    var msg: [32]u8 = undefined;
    Blake2b256.hash(&seed_preimage, &msg, .{});

    // Prove
    const prove_result = sodium_vrf.prove(&cfg.sk.?, &msg) orelse {
        var r = defaultResult();
        r.attempted = true;
        r.probability_x1e6 = prob_x1e6;
        r.reason_code = 10;
        return r;
    };

    // Self-verify
    const verify_result = sodium_vrf.verify(&cfg.pk.?, &prove_result.proof, &msg);
    const verify_ok = verify_result != null;

    // Extract output prefix (first 8 bytes of VRF output as u64 big-endian)
    const output_prefix = std.mem.readInt(u64, prove_result.output[0..8], .big);

    return VrfResult{
        .attempted = true,
        .checked = true,
        .eligible = false, // NEVER eligible — observability only
        .proof_present = true,
        .output_present = true,
        .probability_x1e6 = prob_x1e6,
        .reason_code = 0,
        .verify_ok = verify_ok,
        .output_prefix = output_prefix,
        .proof_bytes = prove_result.proof,
        .output_bytes = prove_result.output,
        .proof_len = sodium_vrf.PROOFBYTES,
        .output_len = sodium_vrf.OUTPUTBYTES,
        .proof_prefix = std.mem.readInt(u64, prove_result.proof[0..8], .big),
    };
}
