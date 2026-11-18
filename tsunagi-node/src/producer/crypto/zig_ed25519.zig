const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;

pub const ZigSigResult = struct {
    ok: bool,
    sig_present: bool,
    reason_code: u8, // 0=ok, 1=bad_seed
    sig: [64]u8,
};

/// Signs exactly 32 bytes using a 32-byte Ed25519 seed.
/// Returns detached 64-byte signature.
pub fn signHash32(hash32: [32]u8, seed32: [32]u8) ZigSigResult {
    var result = ZigSigResult{
        .ok = false,
        .sig_present = false,
        .reason_code = 0,
        .sig = [_]u8{0} ** 64,
    };

    const kp = Ed25519.KeyPair.generateDeterministic(seed32) catch {
        result.reason_code = 1;
        return result;
    };

    const sig = kp.sign(&hash32, null) catch {
        result.reason_code = 1;
        return result;
    };

    result.sig = sig.toBytes();
    result.ok = true;
    result.sig_present = true;
    return result;
}
