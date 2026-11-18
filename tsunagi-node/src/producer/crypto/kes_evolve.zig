const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;
const kes_sign = @import("kes_sign.zig");
const kes_verify = @import("kes_verify.zig");

/// Sum6Kes key evolution — advance key state from current period to target period.
/// Matches Cardano KES semantics (input-output-hk/kes).
///
/// Evolution advances the key state one period at a time. At crossing points
/// (left→right half), the right child key state is generated from the stored
/// seed, and the stored seed is zeroed for forward security.
///
/// Invariant: root PK (hashPair of top-level lhs_pk, rhs_pk) never changes.

/// Split seed into (left, right) using Blake2b256 domain separation.
/// left  = Blake2b256(0x01 || seed)
/// right = Blake2b256(0x02 || seed)
fn seedSplit(seed: [32]u8) [2][32]u8 {
    var result: [2][32]u8 = undefined;
    var left_input: [33]u8 = undefined;
    left_input[0] = 0x01;
    @memcpy(left_input[1..33], &seed);
    Blake2b256.hash(&left_input, &result[0], .{});
    var right_input: [33]u8 = undefined;
    right_input[0] = 0x02;
    @memcpy(right_input[1..33], &seed);
    Blake2b256.hash(&right_input, &result[1], .{});
    return result;
}

/// Compute public key from seed without generating full key state.
/// depth 0: Ed25519 PK from seed.
/// depth d: hashPair(pkFromSeed(d-1, left_seed), pkFromSeed(d-1, right_seed))
fn pkFromSeed(depth: u32, seed: [32]u8) ![32]u8 {
    if (depth == 0) {
        const kp = Ed25519.KeyPair.generateDeterministic(seed) catch return error.KeyPairCreateFailed;
        return kp.public_key.bytes;
    }
    const seeds = seedSplit(seed);
    const left_pk = try pkFromSeed(depth - 1, seeds[0]);
    const right_pk = try pkFromSeed(depth - 1, seeds[1]);
    return kes_verify.hashPair(left_pk, right_pk);
}

/// Extract public key from key state.
/// depth 0: derive Ed25519 PK from sk[0..32] seed.
/// depth d: hashPair(lhs_pk, rhs_pk) stored in key state.
fn extractPk(depth: u32, sk: []const u8) ![32]u8 {
    if (depth == 0) {
        if (sk.len < 32) return error.InvalidKeySize;
        const kp = Ed25519.KeyPair.generateDeterministic(sk[0..32].*) catch return error.KeyPairCreateFailed;
        return kp.public_key.bytes;
    }
    const sub_size = kes_sign.skSize(depth - 1);
    if (sk.len < sub_size + 96) return error.InvalidKeySize;
    var lhs_pk: [32]u8 = undefined;
    var rhs_pk: [32]u8 = undefined;
    @memcpy(&lhs_pk, sk[sub_size + 32 ..][0..32]);
    @memcpy(&rhs_pk, sk[sub_size + 64 ..][0..32]);
    return kes_verify.hashPair(lhs_pk, rhs_pk);
}

/// Generate full key state from seed (left child active, period 0).
/// depth 0: out = seed (32 bytes)
/// depth d: [keygenFromSeed(d-1, left_seed) | right_seed | left_pk | right_pk]
fn keygenFromSeed(depth: u32, seed: [32]u8, out: []u8) !void {
    if (depth == 0) {
        if (out.len < 32) return error.InvalidKeySize;
        @memcpy(out[0..32], &seed);
        return;
    }
    const sub_size = kes_sign.skSize(depth - 1);
    if (out.len < sub_size + 96) return error.InvalidKeySize;

    const seeds = seedSplit(seed);

    // Generate left child key state (active at period 0)
    try keygenFromSeed(depth - 1, seeds[0], out[0..sub_size]);

    // Store right seed
    @memcpy(out[sub_size..][0..32], &seeds[1]);

    // Left PK: extract from the generated left child key state
    const left_pk = try extractPk(depth - 1, out[0..sub_size]);
    @memcpy(out[sub_size + 32 ..][0..32], &left_pk);

    // Right PK: compute from seed (no full key state needed)
    const right_pk = try pkFromSeed(depth - 1, seeds[1]);
    @memcpy(out[sub_size + 64 ..][0..32], &right_pk);
}

/// Evolve key state by one step: advance from period t to t+1.
/// depth 0: error (cannot evolve a leaf)
/// depth d:
///   t < half-1 → recurse into sub-key (still in left half)
///   t == half-1 → cross boundary: generate right child from stored_seed, zero seed
///   t >= half → recurse into sub-key with local period (right half)
fn evolveOneStep(depth: u32, sk: []u8, current_period: u32) !void {
    if (depth == 0) return error.CannotEvolveLeaf;

    const half: u32 = @as(u32, 1) << @intCast(depth - 1);
    const max_period: u32 = @as(u32, 1) << @intCast(depth);
    if (current_period + 1 >= max_period) return error.PeriodOutOfRange;

    const sub_size = kes_sign.skSize(depth - 1);
    if (sk.len < sub_size + 96) return error.InvalidKeySize;

    if (current_period < half - 1) {
        // Still in left half, next period also in left half → recurse
        try evolveOneStep(depth - 1, sk[0..sub_size], current_period);
    } else if (current_period == half - 1) {
        // Crossing boundary: generate right child from stored seed
        var stored_seed: [32]u8 = undefined;
        @memcpy(&stored_seed, sk[sub_size..][0..32]);

        // Generate right child key state, overwriting sub-key region
        try keygenFromSeed(depth - 1, stored_seed, sk[0..sub_size]);

        // Zero stored seed for forward security
        @memset(sk[sub_size..][0..32], 0);

        // lhs_pk and rhs_pk remain unchanged (they're tree-level constants)
    } else {
        // In right half → recurse with local period
        const local_period = current_period - half;
        try evolveOneStep(depth - 1, sk[0..sub_size], local_period);
    }
}

/// Evolve Sum6Kes key state from current period to target period.
/// Validates root PK stability before and after evolution.
/// key_state must be 608 or 612 bytes. If 612, the period suffix is updated.
pub fn evolveToOffset(
    key_state: []u8,
    key_state_len: usize,
    current_offset: u32,
    target_offset: u32,
) !void {
    if (key_state_len != kes_sign.SK_SIZE_6 and key_state_len != kes_sign.SK_FULL_SIZE_6)
        return error.InvalidKeySize;
    if (target_offset >= kes_sign.KES_TOTAL_PERIODS) return error.PeriodOutOfRange;
    if (current_offset >= kes_sign.KES_TOTAL_PERIODS) return error.PeriodOutOfRange;
    if (target_offset < current_offset) return error.CannotDevolve;
    if (target_offset == current_offset) return; // nothing to do

    // Capture root PK before evolution
    const root_pk_before = try kes_sign.extractRootPk(key_state[0..key_state_len]);

    // Evolve step by step
    var period = current_offset;
    while (period < target_offset) : (period += 1) {
        try evolveOneStep(kes_sign.KES_DEPTH, key_state[0..kes_sign.SK_SIZE_6], period);
    }

    // Validate root PK stability
    const root_pk_after = try kes_sign.extractRootPk(key_state[0..key_state_len]);
    if (!std.mem.eql(u8, &root_pk_before, &root_pk_after))
        return error.RootPkChanged;

    // Update period suffix if present
    if (key_state_len == kes_sign.SK_FULL_SIZE_6) {
        std.mem.writeInt(u32, key_state[kes_sign.SK_SIZE_6..][0..4], target_offset, .big);
    }
}
