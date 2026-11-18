const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const kes_verify = @import("kes_verify.zig");

/// Sum6Kes signing from key state bytes (verify-only dryrun, no forging, no broadcast).
/// Depth 6, 64 total periods, 448-byte signature, 608-byte key state (+4 period).
///
/// Key state layout at depth d (skSize(d) = 32 + d*96 bytes):
///   [0 .. skSize(d-1))           sub-key (active child, recursive)
///   [skSize(d-1) .. +32)         stored_seed
///   [skSize(d-1)+32 .. +64)      lhs_pk
///   [skSize(d-1)+64 .. +96)      rhs_pk
/// Depth 0: [Ed25519_secret: 32 bytes]

pub const KES_DEPTH: u32 = 6;
pub const KES_TOTAL_PERIODS: u32 = 64;
pub const SUM6_KES_SIG_LEN: usize = kes_verify.SUM6_KES_SIG_LEN; // 448

/// Secret key size at depth d: 32 + d*96
pub fn skSize(depth: u32) usize {
    return 32 + @as(usize, depth) * 96;
}

pub const SK_SIZE_6: usize = skSize(KES_DEPTH); // 608
pub const SK_FULL_SIZE_6: usize = SK_SIZE_6 + 4; // 612 (with period)

/// Recursive signing from key state bytes.
/// At depth 0: Ed25519 sign with sk[0..32] seed.
/// At depth d>0: recursively sign with sub-key, then append lhs_pk and rhs_pk.
fn signFromKeyState(depth: u32, sk: []const u8, msg: []const u8, out_sig: []u8) !void {
    if (depth == 0) {
        if (sk.len < 32) return error.InvalidKeySize;
        const kp = try Ed25519.KeyPair.generateDeterministic(sk[0..32].*);
        const sig = kp.sign(msg, null) catch return error.SignFailed;
        @memcpy(out_sig[0..64], &sig.toBytes());
        return;
    }

    const sub_size = skSize(depth - 1);
    const inner_sig_len = kes_verify.sigSize(depth - 1);

    if (sk.len < sub_size + 96) return error.InvalidKeySize;

    // Recursively sign with sub-key
    try signFromKeyState(depth - 1, sk[0..sub_size], msg, out_sig[0..inner_sig_len]);

    // Append lhs_pk and rhs_pk from key state
    @memcpy(out_sig[inner_sig_len..][0..32], sk[sub_size + 32 ..][0..32]);
    @memcpy(out_sig[inner_sig_len + 32 ..][0..32], sk[sub_size + 64 ..][0..32]);
}

/// Sign with Sum6Kes from key state bytes.
/// key_state: 608 or 612 bytes. If 612, last 4 are period (big-endian u32).
/// out_period: the period extracted from the key state (or 0 if 608 bytes).
pub fn signSum6Kes(
    key_state: []const u8,
    msg: []const u8,
    out_sig: *[SUM6_KES_SIG_LEN]u8,
    out_period: *u32,
) !void {
    if (key_state.len != SK_SIZE_6 and key_state.len != SK_FULL_SIZE_6)
        return error.InvalidKeySize;

    // Extract period
    if (key_state.len == SK_FULL_SIZE_6) {
        out_period.* = std.mem.readInt(u32, key_state[SK_SIZE_6..][0..4], .big);
    } else {
        out_period.* = 0;
    }
    if (out_period.* >= KES_TOTAL_PERIODS) return error.PeriodOutOfRange;

    try signFromKeyState(KES_DEPTH, key_state[0..SK_SIZE_6], msg, out_sig);
}

/// Extract root PK from key state: hashPair(lhs_pk, rhs_pk) at top level.
pub fn extractRootPk(key_state: []const u8) ![32]u8 {
    if (key_state.len < SK_SIZE_6) return error.InvalidKeySize;
    const sub5 = skSize(KES_DEPTH - 1); // 512
    var lhs_pk: [32]u8 = undefined;
    var rhs_pk: [32]u8 = undefined;
    @memcpy(&lhs_pk, key_state[sub5 + 32 ..][0..32]);
    @memcpy(&rhs_pk, key_state[sub5 + 64 ..][0..32]);
    return kes_verify.hashPair(lhs_pk, rhs_pk);
}

/// Extract period from key state (last 4 bytes, big-endian u32).
pub fn extractPeriod(key_state: []const u8) !u32 {
    if (key_state.len < SK_FULL_SIZE_6) return error.InvalidKeySize;
    return std.mem.readInt(u32, key_state[SK_SIZE_6..][0..4], .big);
}
