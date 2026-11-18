const std = @import("std");

pub const c = @cImport({
    @cInclude("sodium.h");
});

pub const PROOFBYTES: usize = 80;
pub const OUTPUTBYTES: usize = 64;
pub const PUBLICKEYBYTES: usize = 32;
pub const SECRETKEYBYTES: usize = 64;
pub const SEEDBYTES: usize = 32;

pub const VrfKeypair = struct {
    pk: [PUBLICKEYBYTES]u8,
    sk: [SECRETKEYBYTES]u8,
};

pub const VrfProveResult = struct {
    proof: [PROOFBYTES]u8,
    output: [OUTPUTBYTES]u8,
};

pub const VrfVerifyResult = struct {
    output: [OUTPUTBYTES]u8,
};

/// Initialize libsodium. Must be called once before any VRF operations.
pub fn sodiumInit() bool {
    return c.sodium_init() >= 0;
}

/// Derive a full VRF keypair from a 32-byte seed.
pub fn keypairFromSeed(seed: *const [SEEDBYTES]u8) ?VrfKeypair {
    var kp = VrfKeypair{
        .pk = undefined,
        .sk = undefined,
    };
    const rc = c.crypto_vrf_ietfdraft03_keypair_from_seed(&kp.pk, &kp.sk, seed);
    if (rc != 0) return null;
    return kp;
}

/// Compute VRF proof for message using secret key.
/// Returns proof + output (proof_to_hash), or null on failure.
pub fn prove(sk: *const [SECRETKEYBYTES]u8, msg: []const u8) ?VrfProveResult {
    var result = VrfProveResult{
        .proof = undefined,
        .output = undefined,
    };
    const rc = c.crypto_vrf_ietfdraft03_prove(&result.proof, sk, msg.ptr, @intCast(msg.len));
    if (rc != 0) return null;
    const rc2 = c.crypto_vrf_ietfdraft03_proof_to_hash(&result.output, &result.proof);
    if (rc2 != 0) return null;
    return result;
}

/// Verify a VRF proof against a public key and message.
pub fn verify(pk: *const [PUBLICKEYBYTES]u8, proof: *const [PROOFBYTES]u8, msg: []const u8) ?VrfVerifyResult {
    var result = VrfVerifyResult{
        .output = undefined,
    };
    const rc = c.crypto_vrf_ietfdraft03_verify(&result.output, pk, proof, msg.ptr, @intCast(msg.len));
    if (rc != 0) return null;
    return result;
}

/// Derive VRF output hash from a proof (no verification, just hash extraction).
pub fn proofToHash(proof: *const [PROOFBYTES]u8) ?[OUTPUTBYTES]u8 {
    var output: [OUTPUTBYTES]u8 = undefined;
    const rc = c.crypto_vrf_ietfdraft03_proof_to_hash(&output, proof);
    if (rc != 0) return null;
    return output;
}
