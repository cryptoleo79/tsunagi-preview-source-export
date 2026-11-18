const std = @import("std");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

/// Cardano block body CBOR builder (era 7 / Conway2, 4-part body).
///
/// Block body structure on wire (Alonzo+):
///   block_content = [header, tx_bodies, witnesses, aux_data, invalid_txs]
///
/// The body hash is computed as:
///   blake2b256(blake2b256(tx_bodies) || blake2b256(witnesses) || blake2b256(aux_data) || blake2b256(invalid_txs))
///
/// For empty blocks (no transactions):
///   tx_bodies   = 0x80 (empty array)
///   witnesses   = 0x80 (empty array)
///   aux_data    = 0xa0 (empty map)
///   invalid_txs = 0x80 (empty array)
///   block_body_size = 4
///
/// For non-empty blocks: txs sorted by tx_hash (lexicographic byte order).
///
/// NO runtime changes. Used only by dryrun block candidate construction.

pub const BODY_MAX_LEN: usize = 4 * 1024 * 1024; // 4 MB max body

pub const BodyResult = struct {
    /// Body parts concatenated for the wire format.
    /// Layout: [tx_bodies_cbor][witnesses_cbor][aux_data_cbor][invalid_txs_cbor]
    tx_bodies_cbor: []const u8,
    witnesses_cbor: []const u8,
    aux_data_cbor: []const u8,
    invalid_txs_cbor: []const u8,
    body_hash: [32]u8,
    body_size: u64, // total bytes of all 4 body parts
};

/// Empty body parts (proven from real chain captures).
const EMPTY_ARRAY: [1]u8 = .{0x80}; // CBOR empty array
const EMPTY_MAP: [1]u8 = .{0xa0}; // CBOR empty map

/// Build an empty block body (no transactions).
/// Returns static slices and precomputed body hash.
pub fn buildEmptyBody() BodyResult {
    // Body hash = blake2b256(h0 || h1 || h2 || h3)
    // where h0..h3 are blake2b256 of each body part
    var h0: [32]u8 = undefined;
    var h1: [32]u8 = undefined;
    var h2: [32]u8 = undefined;
    var h3: [32]u8 = undefined;

    Blake2b256.hash(&EMPTY_ARRAY, &h0, .{});
    Blake2b256.hash(&EMPTY_ARRAY, &h1, .{});
    Blake2b256.hash(&EMPTY_MAP, &h2, .{});
    Blake2b256.hash(&EMPTY_ARRAY, &h3, .{});

    var combined: [128]u8 = undefined;
    @memcpy(combined[0..32], &h0);
    @memcpy(combined[32..64], &h1);
    @memcpy(combined[64..96], &h2);
    @memcpy(combined[96..128], &h3);

    var body_hash: [32]u8 = undefined;
    Blake2b256.hash(&combined, &body_hash, .{});

    return .{
        .tx_bodies_cbor = &EMPTY_ARRAY,
        .witnesses_cbor = &EMPTY_ARRAY,
        .aux_data_cbor = &EMPTY_MAP,
        .invalid_txs_cbor = &EMPTY_ARRAY,
        .body_hash = body_hash,
        .body_size = 4, // 1+1+1+1
    };
}

/// Compute the 4-part body hash from raw body part CBOR slices.
pub fn computeBodyHash(
    tx_bodies: []const u8,
    witnesses: []const u8,
    aux_data: []const u8,
    invalid_txs: []const u8,
) [32]u8 {
    var h0: [32]u8 = undefined;
    var h1: [32]u8 = undefined;
    var h2: [32]u8 = undefined;
    var h3: [32]u8 = undefined;

    Blake2b256.hash(tx_bodies, &h0, .{});
    Blake2b256.hash(witnesses, &h1, .{});
    Blake2b256.hash(aux_data, &h2, .{});
    Blake2b256.hash(invalid_txs, &h3, .{});

    var combined: [128]u8 = undefined;
    @memcpy(combined[0..32], &h0);
    @memcpy(combined[32..64], &h1);
    @memcpy(combined[64..96], &h2);
    @memcpy(combined[96..128], &h3);

    var body_hash: [32]u8 = undefined;
    Blake2b256.hash(&combined, &body_hash, .{});
    return body_hash;
}

// ---- v2.1.2: Tx-embedded body builder ----

/// Result of building a block body with embedded transactions.
/// Caller must free tx_bodies_cbor, witnesses_cbor, and aux_data_cbor with the
/// same allocator. aux_data_cbor is always heap-allocated (it is the encoded
/// auxiliary_data_set: a single 0xa0 byte when no included tx carries metadata,
/// otherwise the {tx_index => auxiliary_data} map).
pub const DynBodyResult = struct {
    tx_bodies_cbor: []u8,
    witnesses_cbor: []u8,
    aux_data_cbor: []u8,
    body_hash: [32]u8,
    body_size: u64,
};

/// Build a block body from pre-decomposed tx body, witness, and auxiliary_data
/// CBOR slices. tx_bodies[i], witnesses[i], and aux_datas[i] correspond to the
/// same transaction (by block tx index). aux_datas[i] is null for txs without
/// metadata. The emitted auxiliary_data_set is a CBOR map keyed by the block tx
/// index, containing only entries whose aux_datas[i] != null. When every entry
/// is null the set is the empty map (0xa0), keeping empty/metadata-free block
/// output byte-identical to the prior behaviour.
/// invalid_txs = empty array (0x80).
/// Returns null if inputs are empty, mismatched, or allocation fails.
pub fn buildBodyWithTxSlices(
    alloc: std.mem.Allocator,
    tx_bodies: []const []const u8,
    witnesses: []const []const u8,
    aux_datas: []const ?[]const u8,
) ?DynBodyResult {
    if (tx_bodies.len == 0 or tx_bodies.len != witnesses.len) return null;
    if (aux_datas.len != tx_bodies.len) return null;

    const tb_cbor = buildCborArray(alloc, tx_bodies) orelse return null;
    const wt_cbor = buildCborArray(alloc, witnesses) orelse {
        alloc.free(tb_cbor);
        return null;
    };
    const ad_cbor = buildAuxDataSet(alloc, aux_datas) orelse {
        alloc.free(tb_cbor);
        alloc.free(wt_cbor);
        return null;
    };

    const bh = computeBodyHash(tb_cbor, wt_cbor, ad_cbor, &EMPTY_ARRAY);
    const bs: u64 = @intCast(tb_cbor.len + wt_cbor.len + ad_cbor.len + 1); // +1 EMPTY_ARRAY (invalid_txs)

    return .{
        .tx_bodies_cbor = tb_cbor,
        .witnesses_cbor = wt_cbor,
        .aux_data_cbor = ad_cbor,
        .body_hash = bh,
        .body_size = bs,
    };
}

/// Encode the block's auxiliary_data_set : {tx_index (uint) => auxiliary_data}.
/// Only txs with non-null aux_datas[i] contribute an entry. Keys are the block
/// tx index i (ascending, canonical CBOR order). aux_datas[i] is copied verbatim
/// so blake2b256(aux) matches the tx_body auxiliary_data_hash. Returns a single
/// 0xa0 (empty map) when no entry exists. Heap-allocated; caller frees.
fn buildAuxDataSet(alloc: std.mem.Allocator, aux_datas: []const ?[]const u8) ?[]u8 {
    var count: usize = 0;
    var payload_len: usize = 0;
    for (aux_datas, 0..) |maybe_aux, i| {
        if (maybe_aux) |aux| {
            count += 1;
            payload_len += cborUintLen(i) + aux.len;
        }
    }

    if (count == 0) {
        // Empty map — byte-identical to the prior hardcoded 0xa0.
        const buf = alloc.alloc(u8, 1) catch return null;
        buf[0] = 0xa0;
        return buf;
    }
    if (count > 65535) return null;

    const hdr_len: usize = if (count < 24) 1 else if (count < 256) 2 else 3;
    const buf = alloc.alloc(u8, hdr_len + payload_len) catch return null;

    // Map header (major type 5).
    if (count < 24) {
        buf[0] = @as(u8, @intCast(0xa0 + count));
    } else if (count < 256) {
        buf[0] = 0xb8;
        buf[1] = @as(u8, @intCast(count));
    } else {
        buf[0] = 0xb9;
        buf[1] = @as(u8, @intCast(count >> 8));
        buf[2] = @as(u8, @intCast(count & 0xff));
    }

    var off: usize = hdr_len;
    for (aux_datas, 0..) |maybe_aux, i| {
        if (maybe_aux) |aux| {
            off += writeCborUint(buf[off..], i);
            @memcpy(buf[off..][0..aux.len], aux);
            off += aux.len;
        }
    }

    return buf;
}

/// Byte length of an unsigned int encoded as CBOR major type 0.
fn cborUintLen(v: usize) usize {
    if (v < 24) return 1;
    if (v < 0x100) return 2;
    if (v < 0x10000) return 3;
    if (v < 0x100000000) return 5;
    return 9;
}

/// Write an unsigned int as CBOR major type 0 into buf. Returns bytes written.
fn writeCborUint(buf: []u8, v: usize) usize {
    if (v < 24) {
        buf[0] = @as(u8, @intCast(v));
        return 1;
    } else if (v < 0x100) {
        buf[0] = 0x18;
        buf[1] = @as(u8, @intCast(v));
        return 2;
    } else if (v < 0x10000) {
        buf[0] = 0x19;
        std.mem.writeInt(u16, buf[1..3], @as(u16, @intCast(v)), .big);
        return 3;
    } else if (v < 0x100000000) {
        buf[0] = 0x1a;
        std.mem.writeInt(u32, buf[1..5], @as(u32, @intCast(v)), .big);
        return 5;
    } else {
        buf[0] = 0x1b;
        std.mem.writeInt(u64, buf[1..9], @as(u64, v), .big);
        return 9;
    }
}

/// Encode a list of raw CBOR elements into a CBOR definite-length array.
/// Returns heap-allocated buffer, or null on failure.
fn buildCborArray(alloc: std.mem.Allocator, items: []const []const u8) ?[]u8 {
    if (items.len > 65535) return null;

    var total_len: usize = 0;
    for (items) |item| total_len += item.len;

    const n = items.len;
    const hdr_len: usize = if (n < 24) 1 else if (n < 256) 2 else 3;

    const buf = alloc.alloc(u8, hdr_len + total_len) catch return null;

    if (n < 24) {
        buf[0] = @as(u8, @intCast(0x80 + n));
    } else if (n < 256) {
        buf[0] = 0x98;
        buf[1] = @as(u8, @intCast(n));
    } else {
        buf[0] = 0x99;
        buf[1] = @as(u8, @intCast(n >> 8));
        buf[2] = @as(u8, @intCast(n & 0xff));
    }

    var off: usize = hdr_len;
    for (items) |item| {
        @memcpy(buf[off..][0..item.len], item);
        off += item.len;
    }

    return buf;
}

test "buildBodyWithTxSlices no aux is byte-identical to 0xa0 (BC-1 regression)" {
    const alloc = std.testing.allocator;
    const tb = [_]u8{ 0xa0, 0x00 }; // stand-in tx body
    const wt = [_]u8{ 0xa0, 0x01 }; // stand-in witnesses
    const bodies = [_][]const u8{&tb};
    const wits = [_][]const u8{&wt};
    const auxes = [_]?[]const u8{null};
    const res = buildBodyWithTxSlices(alloc, &bodies, &wits, &auxes).?;
    defer alloc.free(res.tx_bodies_cbor);
    defer alloc.free(res.witnesses_cbor);
    defer alloc.free(res.aux_data_cbor);

    // aux part must be exactly the empty map 0xa0 — preserves prior on-chain bytes.
    try std.testing.expectEqualSlices(u8, &[_]u8{0xa0}, res.aux_data_cbor);
    // body_hash must match the 4-part hash computed over 0xa0 aux + 0x80 invalid.
    const expect = computeBodyHash(res.tx_bodies_cbor, res.witnesses_cbor, &EMPTY_MAP, &EMPTY_ARRAY);
    try std.testing.expectEqualSlices(u8, &expect, &res.body_hash);
}

test "buildBodyWithTxSlices emits auxiliary_data_set keyed by tx index (BC-1)" {
    const alloc = std.testing.allocator;
    const tb0 = [_]u8{0xa0};
    const tb1 = [_]u8{0xa1};
    const wt0 = [_]u8{0xa0};
    const wt1 = [_]u8{0xa0};
    const aux1 = [_]u8{ 0xa1, 0x00, 0x01 }; // metadata for tx index 1 only
    const bodies = [_][]const u8{ &tb0, &tb1 };
    const wits = [_][]const u8{ &wt0, &wt1 };
    const auxes = [_]?[]const u8{ null, &aux1 };
    const res = buildBodyWithTxSlices(alloc, &bodies, &wits, &auxes).?;
    defer alloc.free(res.tx_bodies_cbor);
    defer alloc.free(res.witnesses_cbor);
    defer alloc.free(res.aux_data_cbor);

    // auxiliary_data_set = map(1) { 1 => 0xa1 0x00 0x01 } = 0xa1 0x01 0xa1 0x00 0x01
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xa1, 0x01, 0xa1, 0x00, 0x01 }, res.aux_data_cbor);
    // The committed body_hash must be computed over the SAME aux bytes we emit.
    const expect = computeBodyHash(res.tx_bodies_cbor, res.witnesses_cbor, res.aux_data_cbor, &EMPTY_ARRAY);
    try std.testing.expectEqualSlices(u8, &expect, &res.body_hash);
    // body_size accounts for the real aux part length.
    try std.testing.expectEqual(
        @as(u64, @intCast(res.tx_bodies_cbor.len + res.witnesses_cbor.len + res.aux_data_cbor.len + 1)),
        res.body_size,
    );
}
