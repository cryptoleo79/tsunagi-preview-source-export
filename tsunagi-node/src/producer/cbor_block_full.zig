const std = @import("std");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

/// Full Cardano block CBOR assembly (era tag 7 / Conway).
///
/// Wire format: [era_tag, [header, tx_bodies, witnesses, aux_data, invalid_txs]]
///
/// header = [header_body, kes_sig]
///   header_body = 10-element CBOR array (built by cbor_block_header_body.zig)
///   kes_sig = bstr(448)  (Sum6Kes signature)
///
/// header_hash = blake2b256(header_cbor_bytes)
///
/// NO runtime changes. Used only by dryrun block candidate construction.

pub const BLOCK_MAX_LEN: usize = 4 * 1024 * 1024; // 4 MB

/// HardFork combinator era tag for a Conway *block* on the NodeToNode/BlockFetch wire.
///
/// THIS IS 7, NOT 6. The block-envelope tag scheme is Byron-EBB-aware: Byron occupies
/// TWO tags (0 = Byron EBB, 1 = Byron regular block), which shifts every Shelley-based
/// era up by one. So: Shelley=2, Allegra=3, Mary=4, Alonzo=5, Babbage=6, Conway=7.
/// Source: ouroboros-consensus `Ouroboros/Consensus/Cardano/Node.hs`,
/// `SerialiseHFC (CardanoEras c)` — `BlockConway -> prependTag 7`; decoder `7 -> BlockConway`.
/// Golden vector `CardanoNodeToNodeVersion2/Block_Conway` = `82 07 85 …`.
///
/// DO NOT confuse this with the ChainSync *header* era index, which uses a DIFFERENT
/// scheme — a plain 0-based NS index (`nsToIndex`) where Conway = 6. The header path
/// (chainsync_server.zig `era_index = 6`) is correct and must stay 6. Tagging a Conway
/// block with 6 routes it to the Babbage decoder on the relay → the block is rejected
/// in the BlockFetch client (era-mismatch `InvalidBody`, or `DeserialiseFailure`) BEFORE
/// ChainDB admission, with no ChainDB trace — the empirically observed orphan signature.
pub const CONWAY_BLOCK_ERA_TAG: u8 = 7;

/// Assemble block header CBOR: [header_body_cbor, kes_sig]
/// Returns bytes and length. Also computes header_hash.
pub fn assembleHeader(
    buf: []u8,
    header_body_cbor: []const u8,
    kes_sig: [448]u8,
) struct { len: usize, header_hash: [32]u8 } {
    var off: usize = 0;

    // array(2)
    buf[off] = 0x82;
    off += 1;

    // header_body_cbor (embedded raw, not wrapped)
    @memcpy(buf[off..][0..header_body_cbor.len], header_body_cbor);
    off += header_body_cbor.len;

    // kes_sig: bstr(448) — 0x59 0x01 0xc0 prefix (2-byte length, 448 = 0x01c0)
    buf[off] = 0x59;
    off += 1;
    std.mem.writeInt(u16, buf[off..][0..2], 448, .big);
    off += 2;
    @memcpy(buf[off..][0..448], &kes_sig);
    off += 448;

    // header_hash = blake2b256(entire header CBOR)
    var header_hash: [32]u8 = undefined;
    Blake2b256.hash(buf[0..off], &header_hash, .{});

    return .{ .len = off, .header_hash = header_hash };
}

/// Assemble full block CBOR: [era, [header, tx_bodies, witnesses, aux_data, invalid_txs]]
pub fn assembleFullBlock(
    buf: []u8,
    era: u8,
    header_cbor: []const u8,
    tx_bodies_cbor: []const u8,
    witnesses_cbor: []const u8,
    aux_data_cbor: []const u8,
    invalid_txs_cbor: []const u8,
) usize {
    var off: usize = 0;

    // Outer array(2): [era, block_content]
    buf[off] = 0x82;
    off += 1;

    // era: uint
    cborEncodeUint(buf, &off, era);

    // Inner array(5): [header, tx_bodies, witnesses, aux_data, invalid_txs]
    buf[off] = 0x85;
    off += 1;

    // header (raw CBOR)
    @memcpy(buf[off..][0..header_cbor.len], header_cbor);
    off += header_cbor.len;

    // tx_bodies
    @memcpy(buf[off..][0..tx_bodies_cbor.len], tx_bodies_cbor);
    off += tx_bodies_cbor.len;

    // witnesses
    @memcpy(buf[off..][0..witnesses_cbor.len], witnesses_cbor);
    off += witnesses_cbor.len;

    // aux_data
    @memcpy(buf[off..][0..aux_data_cbor.len], aux_data_cbor);
    off += aux_data_cbor.len;

    // invalid_txs
    @memcpy(buf[off..][0..invalid_txs_cbor.len], invalid_txs_cbor);
    off += invalid_txs_cbor.len;

    return off;
}

test "Conway block envelope uses era tag 7 (regression guard: NOT 6)" {
    // The Conway BlockFetch envelope MUST be [7, [header, ...]] → bytes 82 07 85.
    // Era tag 6 routes to the relay's Babbage decoder and is rejected before
    // ChainDB (silent orphan). This locks the value forever.
    try std.testing.expectEqual(@as(u8, 7), CONWAY_BLOCK_ERA_TAG);

    const cbor_block_body = @import("cbor_block_body.zig");
    const body = cbor_block_body.buildEmptyBody();
    // Minimal stand-in header CBOR: a 2-element array [a0, a0]. assembleFullBlock
    // embeds header bytes raw; structural validity of the header is tested elsewhere.
    const fake_header = [_]u8{ 0x82, 0xa0, 0xa0 };
    var buf: [256]u8 = undefined;
    const n = assembleFullBlock(
        &buf,
        CONWAY_BLOCK_ERA_TAG,
        &fake_header,
        body.tx_bodies_cbor,
        body.witnesses_cbor,
        body.aux_data_cbor,
        body.invalid_txs_cbor,
    );
    try std.testing.expect(n >= 3);
    try std.testing.expectEqual(@as(u8, 0x82), buf[0]); // outer array(2): [era, block]
    try std.testing.expectEqual(@as(u8, 0x07), buf[1]); // era tag 7 = Conway block
    try std.testing.expectEqual(@as(u8, 0x85), buf[2]); // inner array(5): [hdr,tb,wt,aux,inv]

    // Non-empty (dyn) body path: prefix must still be 82 07 85 regardless of body content.
    // (The forge path uses forge_dyn_body when txs are present; same assembleFullBlock call.)
    const tb = [_]u8{ 0x81, 0x01 }; // array(1) of a 1-byte item — stand-in tx bodies
    const wt = [_]u8{ 0x81, 0x02 }; // stand-in witnesses
    const n2 = assembleFullBlock(&buf, CONWAY_BLOCK_ERA_TAG, &fake_header, &tb, &wt, body.aux_data_cbor, body.invalid_txs_cbor);
    try std.testing.expect(n2 >= 3);
    try std.testing.expectEqual(@as(u8, 0x82), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x07), buf[1]);
    try std.testing.expectEqual(@as(u8, 0x85), buf[2]);
}

fn cborEncodeUint(buf: []u8, off: *usize, v: u64) void {
    if (v < 24) {
        buf[off.*] = @as(u8, @intCast(v));
        off.* += 1;
    } else if (v < 0x100) {
        buf[off.*] = 0x18;
        buf[off.* + 1] = @as(u8, @intCast(v));
        off.* += 2;
    } else if (v < 0x10000) {
        buf[off.*] = 0x19;
        std.mem.writeInt(u16, buf[off.* + 1 ..][0..2], @as(u16, @intCast(v)), .big);
        off.* += 3;
    } else if (v < 0x100000000) {
        buf[off.*] = 0x1a;
        std.mem.writeInt(u32, buf[off.* + 1 ..][0..4], @as(u32, @intCast(v)), .big);
        off.* += 5;
    } else {
        buf[off.*] = 0x1b;
        std.mem.writeInt(u64, buf[off.* + 1 ..][0..8], v, .big);
        off.* += 9;
    }
}
