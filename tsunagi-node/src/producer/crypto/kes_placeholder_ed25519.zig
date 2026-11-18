const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;

// Reason codes:
// 0 = ok
// 1 = disabled
// 2 = empty_msg
// 3 = bad_key_read
// 4 = bad_key_len
// 5 = sign_fail

pub const KesSignResult = struct {
    ok: bool,
    reason: u8,
    sig: [64]u8,
    prefix_u64: u64,
};

/// Sign arbitrary-length candidate bytes using a 32-byte Ed25519 seed.
/// Returns detached 64-byte signature.
/// Label: KES_PLACEHOLDER_ED25519 (not real Cardano KES).
pub fn signCandidateBytes(sk_seed32: [32]u8, msg: []const u8) KesSignResult {
    var result = KesSignResult{
        .ok = false,
        .reason = 0,
        .sig = [_]u8{0} ** 64,
        .prefix_u64 = 0,
    };

    if (msg.len == 0) {
        result.reason = 2;
        return result;
    }

    const kp = Ed25519.KeyPair.generateDeterministic(sk_seed32) catch {
        result.reason = 5;
        return result;
    };

    const sig = kp.sign(msg, null) catch {
        result.reason = 5;
        return result;
    };

    result.sig = sig.toBytes();
    result.prefix_u64 = std.mem.readInt(u64, result.sig[0..8], .big);
    result.ok = true;
    result.reason = 0;
    return result;
}

/// Load a 32-byte seed from file content.
/// Accepts either 32 raw bytes or 64 hex chars (with optional trailing newline).
pub fn parseSeed(content: []const u8) ?[32]u8 {
    // Strip trailing newline/CR
    var trimmed = content;
    while (trimmed.len > 0 and (trimmed[trimmed.len - 1] == '\n' or trimmed[trimmed.len - 1] == '\r')) {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }

    if (trimmed.len == 32) {
        // Raw 32 bytes
        var seed: [32]u8 = undefined;
        @memcpy(&seed, trimmed[0..32]);
        return seed;
    }

    if (trimmed.len == 64) {
        // 64 hex chars → 32 bytes
        var seed: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&seed, trimmed) catch return null;
        return seed;
    }

    return null; // bad_key_len
}
