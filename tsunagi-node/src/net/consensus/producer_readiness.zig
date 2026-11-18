const std = @import("std");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;
const Ed25519 = std.crypto.sign.Ed25519;
const praos_e34 = @import("../../producer/crypto/praos_threshold_e34.zig");
const kes_sign = @import("../../producer/crypto/kes_sign.zig");
const kes_verify = @import("../../producer/crypto/kes_verify.zig");
const header_candidate = @import("../../producer/header_candidate.zig");
const body_candidate = @import("../../producer/body_candidate.zig");
const cbor_block_body = @import("../../producer/cbor_block_body.zig");
const cbor_hdr = @import("../../producer/cbor_block_header_body.zig");
const cbor_block_full = @import("../../producer/cbor_block_full.zig");

/// Producer readiness evaluation — standalone, local-only, no broadcast, no network IO.
///
/// Evaluates whether a pool operator's node is ready to produce a block
/// at a given slot. Combines leadership check (Praos threshold), KES key
/// validity, KES sign+verify, and local candidate assembly.
///
/// All functions are pure computation. Inputs (VRF output, KES key state)
/// must be pre-computed/pre-loaded by the caller.

// ───────────────────────────────────────────────────────────
//  Types
// ───────────────────────────────────────────────────────────

pub const ReadinessState = enum {
    ready, // Leader for given slot, all checks pass
    not_leader, // All checks pass but not elected leader
    not_ready, // One or more prerequisite checks fail

    pub fn label(self: ReadinessState) []const u8 {
        return switch (self) {
            .ready => "READY",
            .not_leader => "NOT_LEADER",
            .not_ready => "NOT_READY",
        };
    }
};

pub const CheckStatus = enum {
    pass,
    fail,
    skip,

    pub fn label(self: CheckStatus) []const u8 {
        return switch (self) {
            .pass => "PASS",
            .fail => "FAIL",
            .skip => "SKIP",
        };
    }
};

pub const LeadershipCheck = struct {
    status: CheckStatus,
    u_x1e12: u64,
    thresh_x1e12: u64,
    is_leader: bool,
    /// 0=leader, 5=stake_zero, 6=not_leader
    reason: u8,
};

pub const KesCheck = struct {
    status: CheckStatus,
    current_period: u32,
    start_period: u32,
    remaining_periods: u32,
    max_periods: u32,
    expired: bool,
};

pub const SignVerifyCheck = struct {
    status: CheckStatus,
    sign_ok: bool,
    verify_ok: bool,
    verify_detail: kes_verify.KesVerifyResult,
};

pub const CandidateCheck = struct {
    status: CheckStatus,
    header_hash: [32]u8,
    body_hash: [32]u8,
    header_bytes_len: u64,
    body_bytes_len: u64,
};

pub const ReadinessReport = struct {
    state: ReadinessState,
    slot: u64,
    epoch: u64,
    slot_in_epoch: u64,
    leadership: LeadershipCheck,
    kes: KesCheck,
    sign_verify: SignVerifyCheck,
    candidate: CandidateCheck,
};

// ───────────────────────────────────────────────────────────
//  Core functions
// ───────────────────────────────────────────────────────────

/// Map first 8 bytes of VRF output to uniform scalar u in [0, 1) * 1e12.
/// Identical to producer.zig:vrfOutputToU_x1e12 (replicated to avoid
/// importing the 97KB producer.zig with its runtime dependencies).
pub fn vrfOutputToU_x1e12(output_bytes: [64]u8) u64 {
    const r = std.mem.readInt(u64, output_bytes[0..8], .big);
    const u_128: u128 = (@as(u128, r) * 1_000_000_000_000) / @as(u128, std.math.maxInt(u64));
    return @intCast(@max(1, u_128));
}

/// Evaluate Praos leadership for a given VRF output and stake parameters.
/// Uses E34 fixed-point threshold computation matching cardano-node exactly.
pub fn evaluateLeadership(
    vrf_output: [64]u8,
    stake_fraction_x1e9: u64,
    asc_x1e6: u64,
) LeadershipCheck {
    if (stake_fraction_x1e9 == 0) {
        return .{
            .status = .fail,
            .u_x1e12 = 0,
            .thresh_x1e12 = 0,
            .is_leader = false,
            .reason = 5,
        };
    }

    const u_x1e12 = vrfOutputToU_x1e12(vrf_output);
    const thresh_x1e12 = praos_e34.computeThresholdX1e12(stake_fraction_x1e9, asc_x1e6);

    if (thresh_x1e12 == 0) {
        return .{
            .status = .fail,
            .u_x1e12 = u_x1e12,
            .thresh_x1e12 = 0,
            .is_leader = false,
            .reason = 5,
        };
    }

    const is_leader = u_x1e12 < thresh_x1e12;
    return .{
        .status = .pass,
        .u_x1e12 = u_x1e12,
        .thresh_x1e12 = thresh_x1e12,
        .is_leader = is_leader,
        .reason = if (is_leader) 0 else 6,
    };
}

/// Evaluate KES key period validity.
/// Checks whether the current KES period falls within the valid range
/// defined by the operational certificate start period and max evolutions.
pub fn evaluateKesValidity(
    current_kes_period: u32,
    opcert_start_period: u32,
    max_kes_evolutions: u32,
) KesCheck {
    const end_period = opcert_start_period + max_kes_evolutions;

    if (current_kes_period < opcert_start_period) {
        return .{
            .status = .fail,
            .current_period = current_kes_period,
            .start_period = opcert_start_period,
            .remaining_periods = 0,
            .max_periods = max_kes_evolutions,
            .expired = false,
        };
    }

    if (current_kes_period >= end_period) {
        return .{
            .status = .fail,
            .current_period = current_kes_period,
            .start_period = opcert_start_period,
            .remaining_periods = 0,
            .max_periods = max_kes_evolutions,
            .expired = true,
        };
    }

    const remaining = end_period - current_kes_period;
    return .{
        .status = .pass,
        .current_period = current_kes_period,
        .start_period = opcert_start_period,
        .remaining_periods = remaining,
        .max_periods = max_kes_evolutions,
        .expired = false,
    };
}

/// Sign a message with Sum6Kes and verify the signature.
/// Returns pass only if both sign and verify succeed.
pub fn signAndVerify(
    kes_key_state: []const u8,
    kes_pk: [32]u8,
    msg: []const u8,
) SignVerifyCheck {
    var sig: [kes_sign.SUM6_KES_SIG_LEN]u8 = undefined;
    var period: u32 = 0;

    kes_sign.signSum6Kes(kes_key_state, msg, &sig, &period) catch {
        return .{
            .status = .fail,
            .sign_ok = false,
            .verify_ok = false,
            .verify_detail = .bad_sig_len,
        };
    };

    const verify_result = kes_verify.verifySum6Kes(kes_pk, period, msg, &sig);
    const verify_ok = verify_result == .ok;

    return .{
        .status = if (verify_ok) .pass else .fail,
        .sign_ok = true,
        .verify_ok = verify_ok,
        .verify_detail = verify_result,
    };
}

/// Build a local candidate block (header + empty body).
/// Purely local — no network, no broadcast.
pub fn buildLocalCandidate(
    net_magic: u32,
    epoch: u64,
    slot: u64,
    slot_in_epoch: u64,
    tip_block: u64,
    tip_hash: [32]u8,
    state_digest: [32]u8,
    vrf_output_prefix: [8]u8,
    pool_id: [32]u8,
) CandidateCheck {
    const body = body_candidate.buildEmptyBodyV1(net_magic, slot, tip_block, tip_hash);

    const hdr = header_candidate.buildCandidateV2(
        net_magic,
        epoch,
        slot,
        slot_in_epoch,
        tip_block,
        tip_hash,
        state_digest,
        vrf_output_prefix,
        pool_id,
        body.body_hash,
    );

    return .{
        .status = .pass,
        .header_hash = hdr.header_hash,
        .body_hash = body.body_hash,
        .header_bytes_len = hdr.bytes_len,
        .body_bytes_len = body.cbor_len,
    };
}

/// Full readiness evaluation combining all checks.
///
/// Parameters:
///   vrf_output          — pre-computed VRF output (64 bytes from VRF prove)
///   kes_key_state       — pre-loaded KES key state (608 or 612 bytes), null to skip sign+verify
///   kes_pk              — KES root public key (32 bytes)
///
/// Returns a ReadinessReport with per-check results and overall state.
/// No network IO, no broadcast, no side effects.
pub fn evaluate(
    slot: u64,
    epoch: u64,
    slot_in_epoch: u64,
    // VRF + stake
    vrf_output: [64]u8,
    stake_fraction_x1e9: u64,
    asc_x1e6: u64,
    vrf_available: bool,
    // KES
    current_kes_period: u32,
    opcert_start_period: u32,
    max_kes_evolutions: u32,
    kes_key_state: ?[]const u8,
    kes_pk: [32]u8,
    // Chain state
    net_magic: u32,
    tip_block: u64,
    tip_hash: [32]u8,
    state_digest: [32]u8,
    pool_id: [32]u8,
) ReadinessReport {
    // 1. Leadership
    const leadership = evaluateLeadership(vrf_output, stake_fraction_x1e9, asc_x1e6);

    // 2. KES validity
    const kes = evaluateKesValidity(current_kes_period, opcert_start_period, max_kes_evolutions);

    // 3. Sign + verify (requires valid key state)
    var vrf_output_prefix: [8]u8 = undefined;
    @memcpy(&vrf_output_prefix, vrf_output[0..8]);

    const sign_verify: SignVerifyCheck = if (kes_key_state) |ks| blk: {
        // Build header body CBOR as the message to sign
        const empty_body = cbor_block_body.buildEmptyBody();
        const hdr_body = cbor_hdr.buildHeaderBodyCborV2(
            tip_block + 1,
            slot,
            tip_hash,
            pool_id, // issuer_vk placeholder
            kes_pk, // vrf_vkey placeholder
            vrf_output,
            [_]u8{0} ** 80, // vrf_proof placeholder
            empty_body.body_size,
            empty_body.body_hash,
            .{
                .hot_vk = kes_pk,
                .seq_no = 0,
                .kes_period = opcert_start_period,
                .sigma = [_]u8{0} ** 64,
            },
            .{ .major = 10, .minor = 0 },
        );
        break :blk signAndVerify(ks, kes_pk, hdr_body.bytes[0..hdr_body.len]);
    } else SignVerifyCheck{
        .status = .skip,
        .sign_ok = false,
        .verify_ok = false,
        .verify_detail = .bad_sig_len,
    };

    // 4. Candidate build
    const candidate = buildLocalCandidate(
        net_magic,
        epoch,
        slot,
        slot_in_epoch,
        tip_block,
        tip_hash,
        state_digest,
        vrf_output_prefix,
        pool_id,
    );

    // 5. Overall state
    const state: ReadinessState = if (leadership.status == .fail or kes.status == .fail or !vrf_available)
        .not_ready
    else if (!leadership.is_leader)
        .not_leader
    else if (sign_verify.status == .fail or sign_verify.status == .skip)
        .not_ready
    else
        .ready;

    return .{
        .state = state,
        .slot = slot,
        .epoch = epoch,
        .slot_in_epoch = slot_in_epoch,
        .leadership = leadership,
        .kes = kes,
        .sign_verify = sign_verify,
        .candidate = candidate,
    };
}

// ───────────────────────────────────────────────────────────
//  Artifact bundle — raw candidate bytes for offline export
// ───────────────────────────────────────────────────────────

/// Maximum header CBOR size: array(2) prefix (1) + header_body (≤1024) + bstr prefix (3) + sig (448) = 1476
const HEADER_CBOR_MAX: usize = 1536;
/// Maximum block CBOR size: outer array+era (≤11) + header + body (4 bytes empty) = ~1552
const BLOCK_CBOR_MAX: usize = 2048;

pub const ArtifactBundle = struct {
    /// Cardano header CBOR: [header_body_cbor, kes_sig_bstr]
    header_cbor_len: usize,
    header_cbor: [HEADER_CBOR_MAX]u8,
    /// blake2b256 of header_cbor — the block hash on the wire
    block_hash: [32]u8,
    /// Wire body parts (empty block: tx_bodies=0x80, witnesses=0x80, aux_data=0xa0, invalid_txs=0x80)
    body_tx_bodies: []const u8,
    body_witnesses: []const u8,
    body_aux_data: []const u8,
    body_invalid_txs: []const u8,
    body_hash: [32]u8,
    body_size: u64,
    /// Full block CBOR: [era, [header, tx_bodies, witnesses, aux_data, invalid_txs]]
    block_cbor_len: usize,
    block_cbor: [BLOCK_CBOR_MAX]u8,
    /// TSUNAGI candidate header bytes (198 bytes, domain-separated)
    candidate_header: [header_candidate.CANDIDATE_V2_BYTES_LEN]u8,
    candidate_header_hash: [32]u8,
    /// TSUNAGI candidate body CBOR (≤128 bytes)
    candidate_body_len: u64,
    candidate_body: [body_candidate.BODY_V1_MAX_LEN]u8,
    candidate_body_hash: [32]u8,
};

/// Build a complete offline artifact bundle from the same inputs as evaluate().
/// Call this separately, only when state == READY and artifacts are needed.
/// Pure computation — no IO, no broadcast, no side effects.
pub fn buildArtifactBundle(
    slot: u64,
    epoch: u64,
    slot_in_epoch: u64,
    vrf_output: [64]u8,
    kes_key_state: []const u8,
    kes_pk: [32]u8,
    opcert_start_period: u32,
    net_magic: u32,
    tip_block: u64,
    tip_hash: [32]u8,
    state_digest: [32]u8,
    pool_id: [32]u8,
) ?ArtifactBundle {
    // 1. Body (empty)
    const body = cbor_block_body.buildEmptyBody();

    // 2. TSUNAGI candidate (header + body)
    var vrf_output_prefix: [8]u8 = undefined;
    @memcpy(&vrf_output_prefix, vrf_output[0..8]);

    const cand_body = body_candidate.buildEmptyBodyV1(net_magic, slot, tip_block, tip_hash);
    const cand_hdr = header_candidate.buildCandidateV2(
        net_magic, epoch, slot, slot_in_epoch, tip_block,
        tip_hash, state_digest, vrf_output_prefix, pool_id,
        cand_body.body_hash,
    );

    // 3. Header body CBOR (the message KES signs)
    const hdr_body = cbor_hdr.buildHeaderBodyCborV2(
        tip_block + 1,
        slot,
        tip_hash,
        pool_id,
        kes_pk,
        vrf_output,
        [_]u8{0} ** 80, // vrf_proof placeholder
        body.body_size,
        body.body_hash,
        .{
            .hot_vk = kes_pk,
            .seq_no = 0,
            .kes_period = opcert_start_period,
            .sigma = [_]u8{0} ** 64,
        },
        .{ .major = 10, .minor = 0 },
    );

    // 4. KES sign
    var kes_sig: [kes_sign.SUM6_KES_SIG_LEN]u8 = undefined;
    var kes_period: u32 = 0;
    kes_sign.signSum6Kes(kes_key_state, hdr_body.bytes[0..hdr_body.len], &kes_sig, &kes_period) catch return null;

    // 5. Assemble Cardano header CBOR
    var header_cbor_buf: [HEADER_CBOR_MAX]u8 = undefined;
    const hdr_result = cbor_block_full.assembleHeader(&header_cbor_buf, hdr_body.bytes[0..hdr_body.len], kes_sig);

    // 6. Assemble full block CBOR
    var block_cbor_buf: [BLOCK_CBOR_MAX]u8 = undefined;
    const block_len = cbor_block_full.assembleFullBlock(
        &block_cbor_buf,
        cbor_block_full.CONWAY_BLOCK_ERA_TAG, // 7 — single source of truth (see constant doc)
        header_cbor_buf[0..hdr_result.len],
        body.tx_bodies_cbor,
        body.witnesses_cbor,
        body.aux_data_cbor,
        body.invalid_txs_cbor,
    );

    return ArtifactBundle{
        .header_cbor_len = hdr_result.len,
        .header_cbor = header_cbor_buf,
        .block_hash = hdr_result.header_hash,
        .body_tx_bodies = body.tx_bodies_cbor,
        .body_witnesses = body.witnesses_cbor,
        .body_aux_data = body.aux_data_cbor,
        .body_invalid_txs = body.invalid_txs_cbor,
        .body_hash = body.body_hash,
        .body_size = body.body_size,
        .block_cbor_len = block_len,
        .block_cbor = block_cbor_buf,
        .candidate_header = cand_hdr.bytes,
        .candidate_header_hash = cand_hdr.header_hash,
        .candidate_body_len = cand_body.cbor_len,
        .candidate_body = cand_body.cbor_bytes,
        .candidate_body_hash = cand_body.body_hash,
    };
}

// ───────────────────────────────────────────────────────────
//  Test helpers (keygen for sign+verify round-trip test)
// ───────────────────────────────────────────────────────────

fn testSeedSplit(seed: [32]u8) [2][32]u8 {
    var result: [2][32]u8 = undefined;
    var left_in: [33]u8 = undefined;
    left_in[0] = 0x01;
    @memcpy(left_in[1..33], &seed);
    Blake2b256.hash(&left_in, &result[0], .{});
    var right_in: [33]u8 = undefined;
    right_in[0] = 0x02;
    @memcpy(right_in[1..33], &seed);
    Blake2b256.hash(&right_in, &result[1], .{});
    return result;
}

fn testPkFromSeed(depth: u32, seed: [32]u8) ![32]u8 {
    if (depth == 0) {
        const kp = Ed25519.KeyPair.generateDeterministic(seed) catch return error.KeyPairCreateFailed;
        return kp.public_key.bytes;
    }
    const seeds = testSeedSplit(seed);
    const left_pk = try testPkFromSeed(depth - 1, seeds[0]);
    const right_pk = try testPkFromSeed(depth - 1, seeds[1]);
    return kes_verify.hashPair(left_pk, right_pk);
}

fn testExtractPk(depth: u32, sk: []const u8) ![32]u8 {
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

fn testKeygenFromSeed(depth: u32, seed: [32]u8, out: []u8) !void {
    if (depth == 0) {
        if (out.len < 32) return error.InvalidKeySize;
        @memcpy(out[0..32], &seed);
        return;
    }
    const sub_size = kes_sign.skSize(depth - 1);
    if (out.len < sub_size + 96) return error.InvalidKeySize;
    const seeds = testSeedSplit(seed);
    try testKeygenFromSeed(depth - 1, seeds[0], out[0..sub_size]);
    @memcpy(out[sub_size..][0..32], &seeds[1]);
    const left_pk = try testExtractPk(depth - 1, out[0..sub_size]);
    @memcpy(out[sub_size + 32 ..][0..32], &left_pk);
    const right_pk = try testPkFromSeed(depth - 1, seeds[1]);
    @memcpy(out[sub_size + 64 ..][0..32], &right_pk);
}

// ───────────────────────────────────────────────────────────
//  Inline tests
// ───────────────────────────────────────────────────────────

test "leadership — zero stake yields fail" {
    const result = evaluateLeadership([_]u8{0} ** 64, 0, 50_000);
    try std.testing.expectEqual(CheckStatus.fail, result.status);
    try std.testing.expectEqual(false, result.is_leader);
    try std.testing.expectEqual(@as(u8, 5), result.reason);
}

test "leadership — leader with large stake and small u" {
    // VRF output with very small first 8 bytes → small u_x1e12
    var vrf_out: [64]u8 = [_]u8{0} ** 64;
    vrf_out[1] = 0x01;
    // 50% stake
    const result = evaluateLeadership(vrf_out, 500_000_000, 50_000);
    try std.testing.expectEqual(CheckStatus.pass, result.status);
    try std.testing.expectEqual(true, result.is_leader);
    try std.testing.expectEqual(@as(u8, 0), result.reason);
    try std.testing.expect(result.u_x1e12 < result.thresh_x1e12);
}

test "leadership — not leader with max u and tiny stake" {
    const vrf_out = [_]u8{0xFF} ** 64;
    // 0.0001% stake
    const result = evaluateLeadership(vrf_out, 1_000, 50_000);
    try std.testing.expectEqual(CheckStatus.pass, result.status);
    try std.testing.expectEqual(false, result.is_leader);
    try std.testing.expectEqual(@as(u8, 6), result.reason);
    try std.testing.expect(result.u_x1e12 >= result.thresh_x1e12);
}

test "KES validity — valid range" {
    const result = evaluateKesValidity(10, 5, 62);
    try std.testing.expectEqual(CheckStatus.pass, result.status);
    try std.testing.expectEqual(false, result.expired);
    try std.testing.expectEqual(@as(u32, 57), result.remaining_periods);
}

test "KES validity — expired" {
    const result = evaluateKesValidity(70, 5, 62);
    try std.testing.expectEqual(CheckStatus.fail, result.status);
    try std.testing.expectEqual(true, result.expired);
    try std.testing.expectEqual(@as(u32, 0), result.remaining_periods);
}

test "KES validity — period before start" {
    const result = evaluateKesValidity(3, 5, 62);
    try std.testing.expectEqual(CheckStatus.fail, result.status);
    try std.testing.expectEqual(false, result.expired);
    try std.testing.expectEqual(@as(u32, 0), result.remaining_periods);
}

test "KES validity — exactly at boundary" {
    // period = start + max → expired (>= end_period)
    const result = evaluateKesValidity(67, 5, 62);
    try std.testing.expectEqual(CheckStatus.fail, result.status);
    try std.testing.expectEqual(true, result.expired);

    // period = start + max - 1 → last valid period, 1 remaining
    const result2 = evaluateKesValidity(66, 5, 62);
    try std.testing.expectEqual(CheckStatus.pass, result2.status);
    try std.testing.expectEqual(@as(u32, 1), result2.remaining_periods);
}

test "vrfOutputToU_x1e12 — boundary values" {
    // All zeros → minimal u (clamped to 1)
    const u_min = vrfOutputToU_x1e12([_]u8{0} ** 64);
    try std.testing.expectEqual(@as(u64, 1), u_min);

    // All 0xFF → near 1e12
    const u_max = vrfOutputToU_x1e12([_]u8{0xFF} ** 64);
    try std.testing.expect(u_max > 999_999_000_000);
    try std.testing.expect(u_max <= 1_000_000_000_000);
}

test "candidate build — deterministic output" {
    const tip_hash = [_]u8{0xAA} ** 32;
    const state_digest = [_]u8{0xBB} ** 32;
    const pool_id = [_]u8{0xCC} ** 32;
    const vrf_prefix = [_]u8{0xDD} ** 8;

    const c1 = buildLocalCandidate(2, 100, 50000, 50000, 4000000, tip_hash, state_digest, vrf_prefix, pool_id);
    const c2 = buildLocalCandidate(2, 100, 50000, 50000, 4000000, tip_hash, state_digest, vrf_prefix, pool_id);

    try std.testing.expectEqual(CheckStatus.pass, c1.status);
    try std.testing.expectEqualSlices(u8, &c1.header_hash, &c2.header_hash);
    try std.testing.expectEqualSlices(u8, &c1.body_hash, &c2.body_hash);
    try std.testing.expectEqual(@as(u64, header_candidate.CANDIDATE_V2_BYTES_LEN), c1.header_bytes_len);
    try std.testing.expect(c1.body_bytes_len > 0);
}

test "sign and verify — Sum6Kes round trip" {
    // Generate depth-6 key state from deterministic seed
    const seed = [_]u8{0x42} ** 32;
    var key_state: [kes_sign.SK_SIZE_6]u8 = undefined;
    try testKeygenFromSeed(kes_sign.KES_DEPTH, seed, &key_state);

    // Extract root PK
    const root_pk = try kes_sign.extractRootPk(&key_state);

    // Sign and verify
    const msg = "readiness test message";
    const result = signAndVerify(&key_state, root_pk, msg);

    try std.testing.expectEqual(CheckStatus.pass, result.status);
    try std.testing.expectEqual(true, result.sign_ok);
    try std.testing.expectEqual(true, result.verify_ok);
    try std.testing.expectEqual(kes_verify.KesVerifyResult.ok, result.verify_detail);
}

test "sign and verify — wrong PK fails" {
    const seed = [_]u8{0x42} ** 32;
    var key_state: [kes_sign.SK_SIZE_6]u8 = undefined;
    try testKeygenFromSeed(kes_sign.KES_DEPTH, seed, &key_state);

    // Use wrong PK
    const wrong_pk = [_]u8{0xFF} ** 32;
    const result = signAndVerify(&key_state, wrong_pk, "test msg");

    try std.testing.expectEqual(CheckStatus.fail, result.status);
    try std.testing.expectEqual(true, result.sign_ok);
    try std.testing.expectEqual(false, result.verify_ok);
}

test "full evaluate — not_leader state" {
    const vrf_out = [_]u8{0xFF} ** 64;
    const tip_hash = [_]u8{0xAA} ** 32;
    const state_digest = [_]u8{0xBB} ** 32;
    const pool_id = [_]u8{0xCC} ** 32;
    const kes_pk = [_]u8{0xDD} ** 32;

    const report = evaluate(
        50000, 100, 50000,
        vrf_out, 1_000, 50_000, true,
        10, 5, 62,
        null, kes_pk,
        2, 4000000, tip_hash, state_digest, pool_id,
    );

    try std.testing.expectEqual(ReadinessState.not_leader, report.state);
    try std.testing.expectEqual(@as(u64, 50000), report.slot);
    try std.testing.expectEqual(CheckStatus.pass, report.leadership.status);
    try std.testing.expectEqual(false, report.leadership.is_leader);
    try std.testing.expectEqual(CheckStatus.pass, report.kes.status);
    try std.testing.expectEqual(CheckStatus.skip, report.sign_verify.status);
    try std.testing.expectEqual(CheckStatus.pass, report.candidate.status);
}

test "full evaluate — not_ready due to expired KES" {
    var vrf_out: [64]u8 = [_]u8{0} ** 64;
    vrf_out[1] = 0x01; // small u → would be leader
    const tip_hash = [_]u8{0xAA} ** 32;
    const state_digest = [_]u8{0xBB} ** 32;
    const pool_id = [_]u8{0xCC} ** 32;
    const kes_pk = [_]u8{0xDD} ** 32;

    const report = evaluate(
        50000, 100, 50000,
        vrf_out, 500_000_000, 50_000, true,
        70, 5, 62, // period 70 with start 5, max 62 → expired
        null, kes_pk,
        2, 4000000, tip_hash, state_digest, pool_id,
    );

    try std.testing.expectEqual(ReadinessState.not_ready, report.state);
    try std.testing.expectEqual(CheckStatus.fail, report.kes.status);
    try std.testing.expectEqual(true, report.kes.expired);
}

test "full evaluate — ready with valid KES key state" {
    // Generate key state
    const seed = [_]u8{0x42} ** 32;
    var key_state: [kes_sign.SK_SIZE_6]u8 = undefined;
    try testKeygenFromSeed(kes_sign.KES_DEPTH, seed, &key_state);
    const root_pk = try kes_sign.extractRootPk(&key_state);

    // VRF output → small u (leader with large stake)
    var vrf_out: [64]u8 = [_]u8{0} ** 64;
    vrf_out[1] = 0x01;

    const tip_hash = [_]u8{0xAA} ** 32;
    const state_digest = [_]u8{0xBB} ** 32;
    const pool_id = [_]u8{0xCC} ** 32;

    const report = evaluate(
        50000, 100, 50000,
        vrf_out, 500_000_000, 50_000, true,
        10, 5, 62,
        &key_state, root_pk,
        2, 4000000, tip_hash, state_digest, pool_id,
    );

    try std.testing.expectEqual(ReadinessState.ready, report.state);
    try std.testing.expectEqual(CheckStatus.pass, report.leadership.status);
    try std.testing.expectEqual(true, report.leadership.is_leader);
    try std.testing.expectEqual(CheckStatus.pass, report.kes.status);
    try std.testing.expectEqual(CheckStatus.pass, report.sign_verify.status);
    try std.testing.expectEqual(CheckStatus.pass, report.candidate.status);
}

test "state labels" {
    try std.testing.expectEqualStrings("READY", ReadinessState.ready.label());
    try std.testing.expectEqualStrings("NOT_LEADER", ReadinessState.not_leader.label());
    try std.testing.expectEqualStrings("NOT_READY", ReadinessState.not_ready.label());
    try std.testing.expectEqualStrings("PASS", CheckStatus.pass.label());
    try std.testing.expectEqualStrings("FAIL", CheckStatus.fail.label());
    try std.testing.expectEqualStrings("SKIP", CheckStatus.skip.label());
}
