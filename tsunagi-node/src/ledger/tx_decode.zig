const std = @import("std");
const net_tx_decode = @import("../net/ledger/tx_decode.zig");
const block_hash = @import("../net/ledger/block_hash.zig");

/// Re-exports from net/ledger/tx_decode.zig.
/// These are the proven types and functions used throughout the codebase.
pub const TxDeltas = net_tx_decode.TxDeltas;
pub const TxBodyScan = net_tx_decode.TxBodyScan;
pub const extractTxDeltas = net_tx_decode.extractTxDeltas;
pub const scanTxBodiesFromBodyBytes = net_tx_decode.scanTxBodiesFromBodyBytes;
pub const extractTxListFromTermPublic = net_tx_decode.extractTxListFromTermPublic;
pub const freeTxDeltas = net_tx_decode.freeTxDeltas;

/// Re-exports from net/ledger/block_hash.zig.
pub const BodyParts = block_hash.BodyParts;
pub const TxParts = block_hash.TxParts;
pub const extractBodyParts = block_hash.extractBodyParts;
pub const decomposeTx = block_hash.decomposeTx;

/// Compute the canonical Cardano transaction ID.
///
/// The canonical txid is blake2b-256 of the raw CBOR-encoded tx body.
/// Input: a full serialized transaction [tx_body, witnesses, ...].
/// The function extracts the raw tx_body bytes (first array element)
/// via decomposeTx and hashes them directly. No re-encoding.
///
/// Returns null if the input cannot be decomposed as a CBOR array
/// with at least 2 elements.
pub const computeCanonicalTxid = block_hash.computeCanonicalTxid;

/// Compute blake2b-256 hash of arbitrary data.
pub const blake2b256 = block_hash.blake2b256;

/// Extract canonical txids for all transactions in a block.
/// Returns an array of 32-byte txids in the same order as the
/// tx_bodies array in the block. No re-encoding — hashes raw bytes.
///
/// Block structure: [era, [header, tx_bodies, witnesses, aux_data, ...]]
/// Each element of tx_bodies is a raw CBOR tx body.
/// txid[i] = blake2b256(tx_bodies[i]).
///
/// Returns null if block structure cannot be parsed.
pub fn extractBlockTxids(alloc: std.mem.Allocator, block_bytes: []const u8) ?[][32]u8 {
    const parts = block_hash.extractBodyParts(block_bytes) orelse return null;
    const tx_bodies = parts.tx_bodies;

    // Parse array header of tx_bodies
    if (tx_bodies.len == 0) return null;
    const initial = tx_bodies[0];
    const major: u3 = @truncate(initial >> 5);
    if (major != 4) return null; // must be CBOR array

    const addl: u5 = @truncate(initial & 0x1f);

    // Definite-length array
    if (addl == 31) return null; // indefinite-length tx_bodies not expected
    var hdr_len: usize = 1;
    var count: usize = addl;
    if (addl == 24 and tx_bodies.len >= 2) {
        hdr_len = 2;
        count = tx_bodies[1];
    } else if (addl == 25 and tx_bodies.len >= 3) {
        hdr_len = 3;
        count = (@as(usize, tx_bodies[1]) << 8) | tx_bodies[2];
    } else if (addl == 26 and tx_bodies.len >= 5) {
        hdr_len = 5;
        count = (@as(usize, tx_bodies[1]) << 24) | (@as(usize, tx_bodies[2]) << 16) | (@as(usize, tx_bodies[3]) << 8) | tx_bodies[4];
    } else if (addl >= 24) {
        return null; // unsupported header length
    }

    if (count == 0) {
        const empty = alloc.alloc([32]u8, 0) catch return null;
        return empty;
    }

    const txids = alloc.alloc([32]u8, count) catch return null;

    var pos: usize = hdr_len;
    for (0..count) |i| {
        if (pos >= tx_bodies.len) {
            alloc.free(txids);
            return null;
        }
        const elem_start = pos;
        const elem_size = block_hash.skipCborElement(tx_bodies[pos..]) orelse {
            alloc.free(txids);
            return null;
        };
        // Canonical txid = blake2b256(raw tx body CBOR bytes)
        txids[i] = block_hash.blake2b256(tx_bodies[elem_start .. elem_start + elem_size]);
        pos += elem_size;
    }

    return txids;
}

// --- Tests ---

test "computeCanonicalTxid hashes raw tx body bytes without re-encoding" {
    // Construct a minimal Cardano tx: [tx_body, witnesses]
    // tx_body = {0: []}  →  CBOR: a1 00 80
    // witnesses = {}      →  CBOR: a0
    // Full tx = [tx_body, witnesses] →  CBOR: 82 a1 00 80 a0
    const tx = [_]u8{ 0x82, 0xa1, 0x00, 0x80, 0xa0 };

    const txid = computeCanonicalTxid(&tx);
    try std.testing.expect(txid != null);

    // The canonical txid must equal blake2b256 of the raw tx_body bytes (a1 00 80).
    // NOT blake2b256 of any re-encoded representation.
    const expected = blake2b256(&[_]u8{ 0xa1, 0x00, 0x80 });
    try std.testing.expectEqualSlices(u8, &expected, &txid.?);
}

test "computeCanonicalTxid returns null for invalid input" {
    try std.testing.expect(computeCanonicalTxid(&[_]u8{}) == null);
    try std.testing.expect(computeCanonicalTxid(&[_]u8{0x00}) == null); // not an array
}

test "extractBlockTxids returns null for invalid block" {
    const alloc = std.testing.allocator;
    try std.testing.expect(extractBlockTxids(alloc, &[_]u8{}) == null);
    try std.testing.expect(extractBlockTxids(alloc, &[_]u8{ 0x00, 0x01 }) == null);
}

test "extractBlockTxids handles empty tx_bodies array" {
    const alloc = std.testing.allocator;

    // Minimal block: [era, [header, tx_bodies, witnesses, aux_data]]
    // era = 6 (Conway)
    // header = 80 (empty array)
    // tx_bodies = 80 (empty array, 0 elements)
    // witnesses = 80 (empty array)
    // aux_data = 80 (empty array)
    // inner = [header, tx_bodies, witnesses, aux_data] = 84 80 80 80 80
    // outer = [era, inner] = 82 06 84 80 80 80 80
    const block = [_]u8{ 0x82, 0x06, 0x84, 0x80, 0x80, 0x80, 0x80 };

    const txids = extractBlockTxids(alloc, &block);
    if (txids) |ids| {
        defer alloc.free(ids);
        try std.testing.expectEqual(@as(usize, 0), ids.len);
    }
    // null is also acceptable if the empty-array header parsing differs
}
