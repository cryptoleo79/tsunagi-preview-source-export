const std = @import("std");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

// --- v1 (kept for reference, unused) ---

pub const HeaderCandidate = struct {
    epoch: u64,
    slot: u64,
    slot_in_epoch: u64,
    parent_block: u64,
    parent_hash_prefix: [8]u8,
    state_digest_prefix: [8]u8,
    body_hash_prefix: [8]u8,
};

pub fn buildCandidate(
    epoch: u64,
    slot: u64,
    slot_in_epoch: u64,
    parent_block: u64,
    tip_hash: [32]u8,
    state_digest_prefix: [8]u8,
) HeaderCandidate {
    var parent_hash_prefix: [8]u8 = undefined;
    @memcpy(&parent_hash_prefix, tip_hash[0..8]);

    var h = Blake2b256.init(.{});
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, epoch, .big);
    h.update(&buf);
    std.mem.writeInt(u64, &buf, slot, .big);
    h.update(&buf);
    std.mem.writeInt(u64, &buf, parent_block, .big);
    h.update(&buf);
    h.update(&state_digest_prefix);
    var digest: [32]u8 = undefined;
    h.final(&digest);

    var body_hash_prefix: [8]u8 = undefined;
    @memcpy(&body_hash_prefix, digest[0..8]);

    return HeaderCandidate{
        .epoch = epoch,
        .slot = slot,
        .slot_in_epoch = slot_in_epoch,
        .parent_block = parent_block,
        .parent_hash_prefix = parent_hash_prefix,
        .state_digest_prefix = state_digest_prefix,
        .body_hash_prefix = body_hash_prefix,
    };
}

// --- v2: canonical header bytes + domain separation (v0.9.1) ---

pub const DOMAIN = "TSUNAGI_HDR_CANDIDATE_V2";

// Canonical encoding layout (all LE except raw byte arrays):
// [domain_len: u16 LE][domain: 24 bytes]
// [net_magic: u32 LE]
// [epoch: u64 LE]
// [slot: u64 LE]
// [slot_in_epoch: u64 LE]
// [tip_block: u64 LE]
// [tip_hash: 32 bytes]
// [state_digest: 32 bytes]
// [vrf_output_prefix: 8 bytes]
// [pool_id: 32 bytes]
// [body_hash: 32 bytes]              (v0.9.9)
// Total = 2 + 24 + 4 + 8 + 8 + 8 + 8 + 32 + 32 + 8 + 32 + 32 = 198 bytes
pub const CANDIDATE_V2_BYTES_LEN: u64 = 198;

pub const CandidateV2 = struct {
    bytes_len: u64,
    header_hash: [32]u8,
    bytes: [CANDIDATE_V2_BYTES_LEN]u8,
};

pub fn buildCandidateV2(
    net_magic: u32,
    epoch: u64,
    slot: u64,
    slot_in_epoch: u64,
    tip_block: u64,
    tip_hash: [32]u8,
    state_digest: [32]u8,
    vrf_output_prefix: [8]u8,
    pool_id: [32]u8,
    body_hash: [32]u8,
) CandidateV2 {
    var buf: [CANDIDATE_V2_BYTES_LEN]u8 = undefined;
    var off: usize = 0;

    // Domain length (u16 LE) + domain bytes
    std.mem.writeInt(u16, buf[off..][0..2], @as(u16, DOMAIN.len), .little);
    off += 2;
    @memcpy(buf[off..][0..DOMAIN.len], DOMAIN);
    off += DOMAIN.len;

    // net_magic (u32 LE)
    std.mem.writeInt(u32, buf[off..][0..4], net_magic, .little);
    off += 4;

    // epoch (u64 LE)
    std.mem.writeInt(u64, buf[off..][0..8], epoch, .little);
    off += 8;

    // slot (u64 LE)
    std.mem.writeInt(u64, buf[off..][0..8], slot, .little);
    off += 8;

    // slot_in_epoch (u64 LE)
    std.mem.writeInt(u64, buf[off..][0..8], slot_in_epoch, .little);
    off += 8;

    // tip_block (u64 LE)
    std.mem.writeInt(u64, buf[off..][0..8], tip_block, .little);
    off += 8;

    // tip_hash (32 bytes raw)
    @memcpy(buf[off..][0..32], &tip_hash);
    off += 32;

    // state_digest (32 bytes raw)
    @memcpy(buf[off..][0..32], &state_digest);
    off += 32;

    // vrf_output_prefix (8 bytes raw)
    @memcpy(buf[off..][0..8], &vrf_output_prefix);
    off += 8;

    // pool_id (32 bytes raw)
    @memcpy(buf[off..][0..32], &pool_id);
    off += 32;

    // body_hash (32 bytes raw) — v0.9.9
    @memcpy(buf[off..][0..32], &body_hash);
    off += 32;

    // Sanity check
    std.debug.assert(off == CANDIDATE_V2_BYTES_LEN);

    // Hash
    var header_hash: [32]u8 = undefined;
    Blake2b256.hash(&buf, &header_hash, .{});

    return CandidateV2{
        .bytes_len = CANDIDATE_V2_BYTES_LEN,
        .header_hash = header_hash,
        .bytes = buf,
    };
}
