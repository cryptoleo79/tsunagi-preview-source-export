const std = @import("std");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;
const Ed25519 = std.crypto.sign.Ed25519;

/// SumKES verification for ed25519_kes_2^6 (verify-only, no signing).
/// Depth 6, 64 total periods, 448-byte signature.
/// Full depth-6 correctness validated only via external reference vectors.

pub const KES_DEPTH: u32 = 6;
pub const KES_TOTAL_PERIODS: u32 = 64; // 2^6
pub const ED25519_SIG_LEN: usize = 64;
pub const PK_LEN: usize = 32;

/// Signature size at a given depth: sig_size(0)=64, sig_size(d)=sig_size(d-1)+64
pub fn sigSize(depth: u32) usize {
    return (@as(usize, depth) + 1) * ED25519_SIG_LEN;
}

/// Sum6Kes signature length = sigSize(6) = 448 bytes
pub const SUM6_KES_SIG_LEN: usize = 448; // (6+1)*64

pub const KesVerifyResult = enum {
    ok,
    bad_sig_len,
    bad_pk_len,
    period_out_of_range,
    pk_mismatch,
    ed25519_fail,
};

/// hash_pair: Blake2b256(lhs_pk || rhs_pk) → 32-byte digest.
pub fn hashPair(lhs: [32]u8, rhs: [32]u8) [32]u8 {
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..32], &lhs);
    @memcpy(buf[32..64], &rhs);
    var digest: [32]u8 = undefined;
    Blake2b256.hash(&buf, &digest, .{});
    return digest;
}

/// Recursive SumKES verification.
/// At depth 0: Ed25519 verify_strict.
/// At depth d>0: split sig into inner_sig + lhs_pk + rhs_pk,
///   check blake2b_256(lhs_pk||rhs_pk) == pk, then recurse.
fn verifySumKes(depth: u32, pk: [32]u8, period: u32, msg: []const u8, sig: []const u8) KesVerifyResult {
    if (depth == 0) {
        if (sig.len < ED25519_SIG_LEN) return .bad_sig_len;
        const ed_sig = Ed25519.Signature.fromBytes(sig[0..ED25519_SIG_LEN].*);
        const pub_key = Ed25519.PublicKey.fromBytes(pk) catch return .ed25519_fail;
        ed_sig.verify(msg, pub_key) catch return .ed25519_fail;
        return .ok;
    }

    const inner_sig_len = sigSize(depth - 1);
    const total_needed = inner_sig_len + 64;
    if (sig.len < total_needed) return .bad_sig_len;

    var lhs_pk: [32]u8 = undefined;
    var rhs_pk: [32]u8 = undefined;
    @memcpy(&lhs_pk, sig[inner_sig_len .. inner_sig_len + 32]);
    @memcpy(&rhs_pk, sig[inner_sig_len + 32 .. inner_sig_len + 64]);

    const computed_pk = hashPair(lhs_pk, rhs_pk);
    if (!std.mem.eql(u8, &computed_pk, &pk)) return .pk_mismatch;

    const half: u32 = @as(u32, 1) << @intCast(depth - 1);
    if (period < half) {
        return verifySumKes(depth - 1, lhs_pk, period, msg, sig[0..inner_sig_len]);
    } else {
        return verifySumKes(depth - 1, rhs_pk, period - half, msg, sig[0..inner_sig_len]);
    }
}

/// Verify a Sum6Kes signature (depth=6, 448 bytes, 64 periods).
pub fn verifySum6Kes(pk: [32]u8, period: u32, msg: []const u8, sig: []const u8) KesVerifyResult {
    if (sig.len != SUM6_KES_SIG_LEN) return .bad_sig_len;
    if (period >= KES_TOTAL_PERIODS) return .period_out_of_range;
    return verifySumKes(KES_DEPTH, pk, period, msg, sig);
}

pub fn resultStr(r: KesVerifyResult) []const u8 {
    return switch (r) {
        .ok => "OK",
        .bad_sig_len => "BAD_SIG_LEN",
        .bad_pk_len => "BAD_PK_LEN",
        .period_out_of_range => "PERIOD_OUT_OF_RANGE",
        .pk_mismatch => "PK_MISMATCH",
        .ed25519_fail => "ED25519_FAIL",
    };
}

/// Self-test: input validation + base-case Ed25519 (depth 0) only.
/// Does NOT test full depth-6 correctness — that requires external vectors.
pub fn selfTest() struct { pass: u32, fail: u32 } {
    var pass: u32 = 0;
    var fail: u32 = 0;

    // Test 1: bad_sig_len (447 bytes instead of 448)
    {
        var dummy_pk: [32]u8 = undefined;
        @memset(&dummy_pk, 0);
        var short_sig: [447]u8 = undefined;
        @memset(&short_sig, 0);
        const r = verifySum6Kes(dummy_pk, 0, "test", &short_sig);
        const ok = r == .bad_sig_len;
        if (ok) pass += 1 else fail += 1;
        std.debug.print("  [1] bad_sig_len (447 bytes):   {s} (got {s})\n", .{ if (ok) "PASS" else "FAIL", resultStr(r) });
    }

    // Test 2: period_out_of_range (period=64)
    {
        var dummy_pk: [32]u8 = undefined;
        @memset(&dummy_pk, 0);
        var dummy_sig: [448]u8 = undefined;
        @memset(&dummy_sig, 0);
        const r = verifySum6Kes(dummy_pk, 64, "test", &dummy_sig);
        const ok = r == .period_out_of_range;
        if (ok) pass += 1 else fail += 1;
        std.debug.print("  [2] period_out_of_range (64):  {s} (got {s})\n", .{ if (ok) "PASS" else "FAIL", resultStr(r) });
    }

    // Test 3: base-case depth 0 — valid Ed25519 signature
    {
        const seed: [32]u8 = [_]u8{0x42} ** 32;
        const msg = "kes selftest message";
        const kp = Ed25519.KeyPair.generateDeterministic(seed) catch {
            fail += 1;
            std.debug.print("  [3] ed25519 base ok:           FAIL (keypair create)\n", .{});
            return .{ .pass = pass, .fail = fail };
        };
        const sig = kp.sign(msg, null) catch {
            fail += 1;
            std.debug.print("  [3] ed25519 base ok:           FAIL (sign)\n", .{});
            return .{ .pass = pass, .fail = fail };
        };
        const sig_bytes = sig.toBytes();
        const r = verifySumKes(0, kp.public_key.bytes, 0, msg, &sig_bytes);
        const ok = r == .ok;
        if (ok) pass += 1 else fail += 1;
        std.debug.print("  [3] ed25519 base ok:           {s} (got {s})\n", .{ if (ok) "PASS" else "FAIL", resultStr(r) });
    }

    // Test 4: base-case depth 0 — tampered message → ed25519_fail
    {
        const seed: [32]u8 = [_]u8{0x42} ** 32;
        const msg = "kes selftest message";
        const kp = Ed25519.KeyPair.generateDeterministic(seed) catch {
            fail += 1;
            std.debug.print("  [4] ed25519 tampered msg:      FAIL (keypair create)\n", .{});
            return .{ .pass = pass, .fail = fail };
        };
        const sig = kp.sign(msg, null) catch {
            fail += 1;
            std.debug.print("  [4] ed25519 tampered msg:      FAIL (sign)\n", .{});
            return .{ .pass = pass, .fail = fail };
        };
        const sig_bytes = sig.toBytes();
        const r = verifySumKes(0, kp.public_key.bytes, 0, "tampered message", &sig_bytes);
        const ok = r == .ed25519_fail;
        if (ok) pass += 1 else fail += 1;
        std.debug.print("  [4] ed25519 tampered msg:      {s} (got {s})\n", .{ if (ok) "PASS" else "FAIL", resultStr(r) });
    }

    return .{ .pass = pass, .fail = fail };
}
