const std = @import("std");
const cbor = @import("../cbor/term.zig");

/// Compute blake2b-256 hash.
pub fn blake2b256(data: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(data, &digest, .{});
    return digest;
}

/// Extract committed body hash from decoded header term.
/// Header structure: [header_body, header_sig] where header_body is an array.
/// For Babbage/Conway (10 items): body_hash at index 7
/// For Shelley/Allegra/Mary/Alonzo (15 items): body_hash at index 8
pub fn extractBodyHashFromHeader(header_term: cbor.Term) ?[32]u8 {
    if (header_term != .array) return null;
    const hdr = header_term.array;
    if (hdr.len < 2 or hdr[0] != .array) return null;
    const body_fields = hdr[0].array;

    const idx: ?usize = if (body_fields.len == 10)
        7 // Babbage/Conway
    else if (body_fields.len == 15)
        8 // Shelley/Allegra/Mary/Alonzo
    else if (body_fields.len >= 8)
        7 // best guess for unknown era
    else
        null;

    if (idx) |i| {
        return extract32ByteHash(body_fields[i]);
    }
    return null;
}

/// Extract a 32-byte hash from bytes or tag-wrapped bytes.
fn extract32ByteHash(term: cbor.Term) ?[32]u8 {
    if (term == .bytes and term.bytes.len == 32) {
        var out: [32]u8 = undefined;
        @memcpy(&out, term.bytes[0..32]);
        return out;
    }
    if (term == .tag) {
        const inner = term.tag.value.*;
        if (inner == .bytes and inner.bytes.len == 32) {
            var out: [32]u8 = undefined;
            @memcpy(&out, inner.bytes[0..32]);
            return out;
        }
    }
    return null;
}

/// Body part boundaries within block bytes.
/// Each slice points into the original block_bytes.
pub const BodyParts = struct {
    tx_bodies: []const u8,
    witnesses: []const u8,
    aux_data: []const u8,
    invalid_txs: ?[]const u8, // Alonzo+ only (4th part); null for Shelley (3-part blocks)
};

/// Extract the individual body part byte regions from raw block bytes.
/// Block bytes encode [era, [header, tx_bodies, witnesses, aux_data, invalid_txs?]]
/// Returns slices into the original block_bytes for each body component.
pub fn extractBodyParts(block_bytes: []const u8) ?BodyParts {
    if (block_bytes.len < 4) return null;

    var pos: usize = 0;

    // Parse outer array header: [era, block_content]
    const outer_hdr = readCborHdr(block_bytes[pos..]) orelse return null;
    if (outer_hdr.major != 4 or outer_hdr.value < 2) return null;
    pos += outer_hdr.hdr_len;

    // Skip era element
    const era_size = skipCborElement(block_bytes[pos..]) orelse return null;
    pos += era_size;

    // Parse inner array header: [header, tx_bodies, witnesses, aux_data, invalid_txs?]
    if (pos >= block_bytes.len) return null;
    const inner_hdr = readCborHdr(block_bytes[pos..]) orelse return null;
    if (inner_hdr.major != 4 or inner_hdr.value < 4) return null; // need at least 4 elements (header + 3 body parts)
    const n_parts = inner_hdr.value - 1; // body part count (excluding header)
    pos += inner_hdr.hdr_len;

    // Skip header element (block_content[0])
    if (pos >= block_bytes.len) return null;
    const header_size = skipCborElement(block_bytes[pos..]) orelse return null;
    pos += header_size;

    // Now parse each body part boundary
    if (pos >= block_bytes.len) return null;
    const part0_start = pos;
    const part0_size = skipCborElement(block_bytes[pos..]) orelse return null;
    pos += part0_size;

    if (pos >= block_bytes.len) return null;
    const part1_start = pos;
    const part1_size = skipCborElement(block_bytes[pos..]) orelse return null;
    pos += part1_size;

    if (pos >= block_bytes.len) return null;
    const part2_start = pos;
    const part2_size = skipCborElement(block_bytes[pos..]) orelse return null;
    pos += part2_size;

    // 4th part (invalid_txs) present in Alonzo+ blocks (5-element inner array)
    var part3: ?[]const u8 = null;
    if (n_parts >= 4 and pos < block_bytes.len) {
        const part3_start = pos;
        const part3_size = skipCborElement(block_bytes[pos..]) orelse return null;
        part3 = block_bytes[part3_start .. part3_start + part3_size];
    }

    return .{
        .tx_bodies = block_bytes[part0_start .. part0_start + part0_size],
        .witnesses = block_bytes[part1_start .. part1_start + part1_size],
        .aux_data = block_bytes[part2_start .. part2_start + part2_size],
        .invalid_txs = part3,
    };
}

/// Extract the header CBOR region (raw bytes slice) from full block bytes.
/// Block = [era, [header, tx_bodies, witnesses, aux_data, invalid_txs?]]
/// Returns a slice into block_bytes spanning the header element, suitable for
/// blake2b256() to recompute the announced block header hash.
pub fn extractHeaderRegion(block_bytes: []const u8) ?[]const u8 {
    if (block_bytes.len < 4) return null;
    var pos: usize = 0;

    const outer_hdr = readCborHdr(block_bytes[pos..]) orelse return null;
    if (outer_hdr.major != 4 or outer_hdr.value < 2) return null;
    pos += outer_hdr.hdr_len;

    // Skip era element
    const era_size = skipCborElement(block_bytes[pos..]) orelse return null;
    pos += era_size;

    // Inner array: [header, tx_bodies, witnesses, aux_data, invalid_txs?]
    if (pos >= block_bytes.len) return null;
    const inner_hdr = readCborHdr(block_bytes[pos..]) orelse return null;
    if (inner_hdr.major != 4 or inner_hdr.value < 4) return null;
    pos += inner_hdr.hdr_len;

    // Header element
    if (pos >= block_bytes.len) return null;
    const header_start = pos;
    const header_size = skipCborElement(block_bytes[pos..]) orelse return null;
    if (header_start + header_size > block_bytes.len) return null;
    return block_bytes[header_start .. header_start + header_size];
}

/// Compute the Cardano block body hash (merkle-style hash of hashes).
///
/// Shelley (3 parts): blake2b256(blake2b256(tx_bodies) || blake2b256(witnesses) || blake2b256(aux_data))
/// Alonzo+ (4 parts): blake2b256(blake2b256(tx_bodies) || blake2b256(witnesses) || blake2b256(aux_data) || blake2b256(invalid_txs))
pub fn computeBodyHash(parts: BodyParts) [32]u8 {
    const h0 = blake2b256(parts.tx_bodies);
    const h1 = blake2b256(parts.witnesses);
    const h2 = blake2b256(parts.aux_data);

    if (parts.invalid_txs) |itx| {
        // Alonzo/Babbage/Conway: 4-part hash
        const h3 = blake2b256(itx);
        var combined: [128]u8 = undefined;
        @memcpy(combined[0..32], &h0);
        @memcpy(combined[32..64], &h1);
        @memcpy(combined[64..96], &h2);
        @memcpy(combined[96..128], &h3);
        return blake2b256(&combined);
    } else {
        // Shelley: 3-part hash
        var combined: [96]u8 = undefined;
        @memcpy(combined[0..32], &h0);
        @memcpy(combined[32..64], &h1);
        @memcpy(combined[64..96], &h2);
        return blake2b256(&combined);
    }
}

// ---- CBOR element skipper (no allocation, byte-level parsing) ----

pub const CborHdr = struct {
    major: u3,
    hdr_len: usize,
    value: usize,
};

pub fn readCborHdr(bytes: []const u8) ?CborHdr {
    if (bytes.len == 0) return null;
    const initial = bytes[0];
    const major: u3 = @truncate(initial >> 5);
    const addl: u5 = @truncate(initial & 0x1f);

    if (addl < 24) return .{ .major = major, .hdr_len = 1, .value = addl };
    if (addl == 24 and bytes.len >= 2) return .{ .major = major, .hdr_len = 2, .value = bytes[1] };
    if (addl == 25 and bytes.len >= 3) return .{ .major = major, .hdr_len = 3, .value = (@as(usize, bytes[1]) << 8) | bytes[2] };
    if (addl == 26 and bytes.len >= 5) return .{ .major = major, .hdr_len = 5, .value = (@as(usize, bytes[1]) << 24) | (@as(usize, bytes[2]) << 16) | (@as(usize, bytes[3]) << 8) | bytes[4] };
    if (addl == 27 and bytes.len >= 9) {
        var val: u64 = 0;
        for (1..9) |i| {
            val = (val << 8) | bytes[i];
        }
        // Block sizes fit in usize on 64-bit
        return .{ .major = major, .hdr_len = 9, .value = @truncate(val) };
    }
    return null;
}

/// Skip one complete CBOR element, returning byte count consumed.
/// Handles both definite-length and indefinite-length arrays, maps,
/// byte/text strings, tags, ints, and simple values.
pub fn skipCborElement(bytes: []const u8) ?usize {
    if (bytes.len == 0) return null;
    const initial = bytes[0];
    const major: u3 = @truncate(initial >> 5);
    const addl: u5 = @truncate(initial & 0x1f);

    switch (major) {
        0, 1 => {
            // unsigned int / negative int: header only
            return intHdrLen(addl);
        },
        2, 3 => {
            // byte string / text string
            if (addl == 31) {
                // indefinite-length: 0x5f or 0x7f, skip chunks until 0xff break
                var pos: usize = 1;
                while (pos < bytes.len) {
                    if (bytes[pos] == 0xff) return pos + 1; // include break byte
                    const chunk = skipCborElement(bytes[pos..]) orelse return null;
                    pos += chunk;
                }
                return null;
            }
            const hdr = readCborHdr(bytes) orelse return null;
            // Overflow-safe bounds check: hdr.hdr_len + hdr.value can wrap usize
            // when hdr.value is attacker-supplied near maxInt(u64) (8-byte length,
            // addl=27). Compare via saturating subtraction so a wrapped sum cannot
            // bypass the guard.
            if (hdr.value > bytes.len -| hdr.hdr_len) return null;
            return hdr.hdr_len + hdr.value;
        },
        4 => {
            // array
            if (addl == 31) {
                // indefinite-length array: 0x9f, elements until 0xff break
                var pos: usize = 1;
                while (pos < bytes.len) {
                    if (bytes[pos] == 0xff) return pos + 1;
                    const elem = skipCborElement(bytes[pos..]) orelse return null;
                    pos += elem;
                }
                return null;
            }
            const hdr = readCborHdr(bytes) orelse return null;
            var pos: usize = hdr.hdr_len;
            for (0..hdr.value) |_| {
                if (pos >= bytes.len) return null;
                const elem = skipCborElement(bytes[pos..]) orelse return null;
                pos += elem;
            }
            return pos;
        },
        5 => {
            // map
            if (addl == 31) {
                // indefinite-length map: 0xbf, key-value pairs until 0xff break
                var pos: usize = 1;
                while (pos < bytes.len) {
                    if (bytes[pos] == 0xff) return pos + 1;
                    const k = skipCborElement(bytes[pos..]) orelse return null;
                    pos += k;
                    if (pos >= bytes.len) return null;
                    const v = skipCborElement(bytes[pos..]) orelse return null;
                    pos += v;
                }
                return null;
            }
            const hdr = readCborHdr(bytes) orelse return null;
            var pos: usize = hdr.hdr_len;
            for (0..hdr.value) |_| {
                if (pos >= bytes.len) return null;
                const k = skipCborElement(bytes[pos..]) orelse return null;
                pos += k;
                if (pos >= bytes.len) return null;
                const v = skipCborElement(bytes[pos..]) orelse return null;
                pos += v;
            }
            return pos;
        },
        6 => {
            // tag: header + one content element
            const hdr_len = intHdrLen(addl) orelse return null;
            if (hdr_len >= bytes.len) return null;
            const content = skipCborElement(bytes[hdr_len..]) orelse return null;
            return hdr_len + content;
        },
        7 => {
            // simple / float: header only (or break 0xff handled by callers)
            return intHdrLen(addl);
        },
    }
}

fn intHdrLen(addl: u5) ?usize {
    if (addl < 24) return 1;
    return switch (addl) {
        24 => 2,
        25 => 3,
        26 => 5,
        27 => 9,
        else => null,
    };
}

// ---- TX decomposition (v2.1.0-a) ----

/// Decomposed parts of a Cardano transaction.
/// Extracts tx_body (first element) and witnesses (second element) from
/// the Conway tx shape [tx_body, witnesses, is_valid, auxiliary_data / null].
/// aux_data carries element [3] verbatim (raw CBOR slice into tx_bytes) so that
/// blake2b256(aux_data) matches the auxiliary_data_hash committed in tx_body key 7.
/// aux_data is null when the tx omits element [3] or encodes it as CBOR null (0xf6).
pub const TxParts = struct {
    tx_body: []const u8, // raw CBOR of first array element (tx body)
    witnesses: []const u8, // raw CBOR of second array element (witnesses)
    aux_data: ?[]const u8 = null, // raw CBOR of element [3] (auxiliary_data), null if absent/null
};

/// Extract tx_body, witnesses, and (if present) auxiliary_data from a full Cardano tx.
/// Tx is expected to be a CBOR array with at least 2 elements:
///   Conway: [tx_body, witnesses, is_valid_bool, auxiliary_data / null]
/// Returns slices into tx_bytes. No allocation.
/// Returns null if tx_bytes is not a valid CBOR array or too short.
pub fn decomposeTx(tx_bytes: []const u8) ?TxParts {
    if (tx_bytes.len < 2) return null;
    const hdr = readCborHdr(tx_bytes) orelse return null;
    if (hdr.major != 4 or hdr.value < 2) return null; // must be array with >= 2 elements
    const body_start = hdr.hdr_len;
    if (body_start >= tx_bytes.len) return null;
    const body_size = skipCborElement(tx_bytes[body_start..]) orelse return null;
    const wit_start = body_start + body_size;
    if (wit_start >= tx_bytes.len) return null;
    const wit_size = skipCborElement(tx_bytes[wit_start..]) orelse return null;

    // Element [2] = is_valid (bool), element [3] = auxiliary_data (or CBOR null).
    // Only the Conway 4-element shape carries auxiliary_data inline. Extract it
    // verbatim so blake2b256(aux_data) equals tx_body key 7 (auxiliary_data_hash).
    var aux: ?[]const u8 = null;
    if (hdr.value >= 4) {
        const isvalid_start = wit_start + wit_size;
        if (isvalid_start >= tx_bytes.len) return null;
        const isvalid_size = skipCborElement(tx_bytes[isvalid_start..]) orelse return null;
        const aux_start = isvalid_start + isvalid_size;
        if (aux_start >= tx_bytes.len) return null;
        const aux_size = skipCborElement(tx_bytes[aux_start..]) orelse return null;
        if (aux_start + aux_size > tx_bytes.len) return null;
        const aux_slice = tx_bytes[aux_start .. aux_start + aux_size];
        // CBOR null (0xf6) means "no metadata" — treat as absent.
        if (!(aux_slice.len == 1 and aux_slice[0] == 0xf6)) aux = aux_slice;
    }

    return .{
        .tx_body = tx_bytes[body_start .. body_start + body_size],
        .witnesses = tx_bytes[wit_start .. wit_start + wit_size],
        .aux_data = aux,
    };
}

/// Search for a txid (as 64-char hex) in a CBOR array of tx bodies.
/// Iterates the tx_bodies array, computes blake2b256(element) for each,
/// and returns true if any matches expected_hex.
pub fn findTxidInBodies(tx_bodies_cbor: []const u8, expected_hex: []const u8) bool {
    if (expected_hex.len < 64) return false;
    const hdr = readCborHdr(tx_bodies_cbor) orelse return false;
    if (hdr.major != 4 or hdr.value == 0) return false;
    var pos = hdr.hdr_len;
    for (0..hdr.value) |_| {
        if (pos >= tx_bodies_cbor.len) break;
        const elem_start = pos;
        const elem_size = skipCborElement(tx_bodies_cbor[pos..]) orelse break;
        const txid = blake2b256(tx_bodies_cbor[elem_start .. elem_start + elem_size]);
        const txid_hex = std.fmt.bytesToHex(txid, .lower);
        if (std.mem.eql(u8, &txid_hex, expected_hex[0..64])) return true;
        pos += elem_size;
    }
    return false;
}

/// Compute the canonical Cardano txid = blake2b256(tx_body_cbor).
/// Returns null if the tx cannot be decomposed.
pub fn computeCanonicalTxid(tx_bytes: []const u8) ?[32]u8 {
    const parts = decomposeTx(tx_bytes) orelse return null;
    return blake2b256(parts.tx_body);
}

// ---- Canonical txid extraction from block body bytes ----

pub const MAX_TX_HASHES: usize = 256;

/// Extract tx_bodies byte region from block content bytes.
/// Block content is [header, tx_bodies, witnesses, metadata, ...] (4 or 5 elements).
/// Returns a slice pointing into the original bytes for the tx_bodies element,
/// or null if the structure is unrecognized.
pub fn extractTxBodiesBytes(block_content: []const u8) ?[]const u8 {
    if (block_content.len < 2) return null;

    const outer = readCborHdr(block_content) orelse return null;
    if (outer.major != 4) return null;
    if (outer.value < 4 or outer.value > 5) return null;

    var pos: usize = outer.hdr_len;

    // Skip element[0] (header)
    if (pos >= block_content.len) return null;
    const hdr_size = skipCborElement(block_content[pos..]) orelse return null;
    pos += hdr_size;

    // Element[1] = tx_bodies
    if (pos >= block_content.len) return null;
    const tx_size = skipCborElement(block_content[pos..]) orelse return null;
    return block_content[pos .. pos + tx_size];
}

/// Extract canonical txids from a tx_bodies CBOR array.
/// Input must be the raw CBOR bytes of the tx_bodies array itself
/// (not the full block content — use extractBodyParts to isolate tx_bodies first).
///
/// Walks the array at the byte level, hashing each element with blake2b256.
/// Returns count of txids written to `out`. Returns 0 on any structural
/// ambiguity (fail-closed).
pub fn extractTxBodyHashes(
    tx_bodies_bytes: []const u8,
    out: *[MAX_TX_HASHES][32]u8,
) usize {
    if (tx_bodies_bytes.len < 1) return 0;

    const hdr = readCborHdr(tx_bodies_bytes) orelse return 0;
    if (hdr.major != 4) return 0; // Must be a CBOR array
    if (hdr.value > MAX_TX_HASHES) return 0; // Sanity cap

    var pos: usize = hdr.hdr_len;
    var count: usize = 0;

    for (0..hdr.value) |_| {
        if (pos >= tx_bodies_bytes.len) return 0; // Truncated — fail closed
        const elem_start = pos;
        const elem_size = skipCborElement(tx_bodies_bytes[pos..]) orelse return 0;
        out[count] = blake2b256(tx_bodies_bytes[elem_start .. elem_start + elem_size]);
        count += 1;
        pos += elem_size;
    }

    return count;
}

// ---- Tests ----

test "blake2b256 empty" {
    const digest = blake2b256(&[_]u8{});
    // blake2b-256 of empty input is a known constant
    try std.testing.expect(digest[0] == 0x0e);
}

test "skipCborElement uint" {
    // 0x05 = unsigned 5 (1 byte)
    try std.testing.expectEqual(@as(?usize, 1), skipCborElement(&[_]u8{0x05}));
    // 0x18 0x19 = unsigned 25 (2 bytes)
    try std.testing.expectEqual(@as(?usize, 2), skipCborElement(&[_]u8{ 0x18, 0x19 }));
}

test "skipCborElement bytes" {
    // 0x43 = 3-byte string, needs 1 + 3 = 4 bytes total
    try std.testing.expectEqual(@as(?usize, 4), skipCborElement(&[_]u8{ 0x43, 0xAA, 0xBB, 0xCC }));
}

test "skipCborElement array" {
    // 0x82 = 2-element array of [0x01, 0x02]
    try std.testing.expectEqual(@as(?usize, 3), skipCborElement(&[_]u8{ 0x82, 0x01, 0x02 }));
}

test "skipCborElement nested" {
    // [1, [2, 3]] = 0x82, 0x01, 0x82, 0x02, 0x03
    try std.testing.expectEqual(@as(?usize, 5), skipCborElement(&[_]u8{ 0x82, 0x01, 0x82, 0x02, 0x03 }));
}

test "skipCborElement map" {
    // {1: 2} = 0xa1, 0x01, 0x02
    try std.testing.expectEqual(@as(?usize, 3), skipCborElement(&[_]u8{ 0xa1, 0x01, 0x02 }));
}

test "skipCborElement tag" {
    // tag(24, bytes(3)) = 0xd8, 0x18, 0x43, 0xAA, 0xBB, 0xCC
    try std.testing.expectEqual(@as(?usize, 6), skipCborElement(&[_]u8{ 0xd8, 0x18, 0x43, 0xAA, 0xBB, 0xCC }));
}

test "skipCborElement indefinite array" {
    // 0x9f, 0x01, 0x02, 0xff = indefinite array [1, 2]
    try std.testing.expectEqual(@as(?usize, 4), skipCborElement(&[_]u8{ 0x9f, 0x01, 0x02, 0xff }));
}

test "skipCborElement indefinite map" {
    // 0xbf, 0x01, 0x02, 0xff = indefinite map {1: 2}
    try std.testing.expectEqual(@as(?usize, 4), skipCborElement(&[_]u8{ 0xbf, 0x01, 0x02, 0xff }));
}

test "skipCborElement indefinite bytes" {
    // 0x5f, 0x42, 0xAA, 0xBB, 0xff = indefinite bytes with one chunk
    try std.testing.expectEqual(@as(?usize, 5), skipCborElement(&[_]u8{ 0x5f, 0x42, 0xAA, 0xBB, 0xff }));
}

test "extractBodyParts simple" {
    // Build a minimal 5-element block: [era, [header, bodies, wits, aux, invalid]]
    // era = 6 (0x06)
    // inner = [header, bodies, wits, aux, invalid]
    //   header = [1] (0x81, 0x01)
    //   bodies = [2] (0x81, 0x02)
    //   wits   = [3] (0x81, 0x03)
    //   aux    = [4] (0x81, 0x04)
    //   invalid = [5] (0x81, 0x05)
    // Inner array: 0x85, 0x81,0x01, 0x81,0x02, 0x81,0x03, 0x81,0x04, 0x81,0x05
    // Outer array: 0x82, 0x06, 0x85, 0x81,0x01, 0x81,0x02, 0x81,0x03, 0x81,0x04, 0x81,0x05
    const block = [_]u8{ 0x82, 0x06, 0x85, 0x81, 0x01, 0x81, 0x02, 0x81, 0x03, 0x81, 0x04, 0x81, 0x05 };
    const parts = extractBodyParts(&block);
    try std.testing.expect(parts != null);
    const p = parts.?;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x02 }, p.tx_bodies);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x03 }, p.witnesses);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x04 }, p.aux_data);
    try std.testing.expect(p.invalid_txs != null);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x05 }, p.invalid_txs.?);
}

test "computeBodyHash simple" {
    // Verify the merkle-style hash: blake2b256(h0 || h1 || h2 || h3)
    const b0 = [_]u8{0x01};
    const b1 = [_]u8{0x02};
    const b2 = [_]u8{0x03};
    const b3 = [_]u8{0x04};

    const parts = BodyParts{
        .tx_bodies = &b0,
        .witnesses = &b1,
        .aux_data = &b2,
        .invalid_txs = &b3,
    };

    const h = computeBodyHash(parts);
    // Verify manually: compute expected hash
    const h0 = blake2b256(&b0);
    const h1 = blake2b256(&b1);
    const h2 = blake2b256(&b2);
    const h3 = blake2b256(&b3);
    var combined: [128]u8 = undefined;
    @memcpy(combined[0..32], &h0);
    @memcpy(combined[32..64], &h1);
    @memcpy(combined[64..96], &h2);
    @memcpy(combined[96..128], &h3);
    const expected = blake2b256(&combined);
    try std.testing.expectEqualSlices(u8, &expected, &h);
}

test "decomposeTx array tx" {
    // Minimal Cardano tx shape: [tx_body, witnesses] = [0xa0, 0xa0] (two empty maps)
    // CBOR: 0x82 (2-elem array), 0xa0 (empty map), 0xa0 (empty map)
    const tx = [_]u8{ 0x82, 0xa0, 0xa0 };
    const parts = decomposeTx(&tx);
    try std.testing.expect(parts != null);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xa0}, parts.?.tx_body);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xa0}, parts.?.witnesses);
    try std.testing.expect(parts.?.aux_data == null); // 2-element tx has no aux
}

test "decomposeTx extracts auxiliary_data (BC-1)" {
    // Conway tx shape: [tx_body, witnesses, is_valid, auxiliary_data]
    // CBOR: 0x84 (4-elem array), 0xa0 (body), 0xa0 (wits), 0xf5 (true), <aux>
    // aux = {0: 1} encoded as 0xa1 0x00 0x01 (stand-in metadata map)
    const tx = [_]u8{ 0x84, 0xa0, 0xa0, 0xf5, 0xa1, 0x00, 0x01 };
    const parts = decomposeTx(&tx);
    try std.testing.expect(parts != null);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xa0}, parts.?.tx_body);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xa0}, parts.?.witnesses);
    try std.testing.expect(parts.?.aux_data != null);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xa1, 0x00, 0x01 }, parts.?.aux_data.?);
}

test "decomposeTx treats CBOR null auxiliary_data as absent (BC-1)" {
    // Conway tx with no metadata: element [3] is CBOR null (0xf6).
    // CBOR: 0x84, 0xa0, 0xa0, 0xf4 (false=is_valid), 0xf6 (null aux)
    const tx = [_]u8{ 0x84, 0xa0, 0xa0, 0xf4, 0xf6 };
    const parts = decomposeTx(&tx);
    try std.testing.expect(parts != null);
    try std.testing.expect(parts.?.aux_data == null); // null aux => absent
}

test "findTxidInBodies" {
    // tx_bodies array with one tx_body = {0: []} = 0xa1 0x00 0x80
    // CBOR: 0x81 (1-elem array), 0xa1, 0x00, 0x80
    const bodies = [_]u8{ 0x81, 0xa1, 0x00, 0x80 };
    const txid = blake2b256(&[_]u8{ 0xa1, 0x00, 0x80 });
    const txid_hex = std.fmt.bytesToHex(txid, .lower);
    try std.testing.expect(findTxidInBodies(&bodies, &txid_hex));
    // Wrong txid should not match
    try std.testing.expect(!findTxidInBodies(&bodies, "0000000000000000000000000000000000000000000000000000000000000000"));
    // Empty array should not match
    try std.testing.expect(!findTxidInBodies(&[_]u8{0x80}, &txid_hex));
}

test "decomposeTx too short" {
    try std.testing.expect(decomposeTx(&[_]u8{0x82}) == null);
    try std.testing.expect(decomposeTx(&[_]u8{}) == null);
}

test "decomposeTx not array" {
    // 0xa1 0x00 0x01 = map {0: 1} — not an array
    try std.testing.expect(decomposeTx(&[_]u8{ 0xa1, 0x00, 0x01 }) == null);
}

test "computeCanonicalTxid" {
    // tx = [tx_body, witnesses] where tx_body = {0: []} = 0xa1 0x00 0x80
    // witnesses = {} = 0xa0
    const tx = [_]u8{ 0x82, 0xa1, 0x00, 0x80, 0xa0 };
    const txid = computeCanonicalTxid(&tx);
    try std.testing.expect(txid != null);
    // txid should equal blake2b256 of tx_body bytes (0xa1, 0x00, 0x80)
    const expected = blake2b256(&[_]u8{ 0xa1, 0x00, 0x80 });
    try std.testing.expectEqualSlices(u8, &expected, &txid.?);
}

test "extractTxBodyHashes two tx bodies" {
    // tx_bodies = array(2): [0x01, 0x02]
    const tx_bodies = [_]u8{ 0x82, 0x01, 0x02 };
    var out: [MAX_TX_HASHES][32]u8 = undefined;
    const count = extractTxBodyHashes(&tx_bodies, &out);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualSlices(u8, &blake2b256(&[_]u8{0x01}), &out[0]);
    try std.testing.expectEqualSlices(u8, &blake2b256(&[_]u8{0x02}), &out[1]);
}

test "extractTxBodyHashes single tx body" {
    // tx_bodies = array(1): [0x05]
    const tx_bodies = [_]u8{ 0x81, 0x05 };
    var out: [MAX_TX_HASHES][32]u8 = undefined;
    const count = extractTxBodyHashes(&tx_bodies, &out);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualSlices(u8, &blake2b256(&[_]u8{0x05}), &out[0]);
}

test "extractTxBodyHashes compound tx body elements" {
    // tx_bodies = array(1): [ map{0: []} ]
    // map{0: []} = 0xa1 0x00 0x80
    const tx_bodies = [_]u8{ 0x81, 0xa1, 0x00, 0x80 };
    var out: [MAX_TX_HASHES][32]u8 = undefined;
    const count = extractTxBodyHashes(&tx_bodies, &out);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualSlices(u8, &blake2b256(&[_]u8{ 0xa1, 0x00, 0x80 }), &out[0]);
}

test "extractTxBodyHashes empty array returns 0" {
    const tx_bodies = [_]u8{0x80}; // array(0)
    var out: [MAX_TX_HASHES][32]u8 = undefined;
    const count = extractTxBodyHashes(&tx_bodies, &out);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "extractTxBodyHashes not array returns 0" {
    const tx_bodies = [_]u8{0x05}; // uint(5), not an array
    var out: [MAX_TX_HASHES][32]u8 = undefined;
    const count = extractTxBodyHashes(&tx_bodies, &out);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "extractTxBodyHashes truncated returns 0" {
    const tx_bodies = [_]u8{0x82}; // array(2) but no elements
    var out: [MAX_TX_HASHES][32]u8 = undefined;
    const count = extractTxBodyHashes(&tx_bodies, &out);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "extractTxBodyHashes via extractBodyParts round-trip" {
    // Full block: [era(7), [header(empty), tx_bodies([0x03]), witnesses, metadata]]
    // CBOR: 82 07 84 80 81 03 80 80
    const block = [_]u8{ 0x82, 0x07, 0x84, 0x80, 0x81, 0x03, 0x80, 0x80 };
    const parts = extractBodyParts(&block) orelse {
        return error.TestUnexpectedResult;
    };
    var out: [MAX_TX_HASHES][32]u8 = undefined;
    const count = extractTxBodyHashes(parts.tx_bodies, &out);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualSlices(u8, &blake2b256(&[_]u8{0x03}), &out[0]);
}

test "extractTxBodiesBytes from block content" {
    // Block content (no era wrapper): [header(empty), tx_bodies([0x03, 0x04]), witnesses, metadata]
    // CBOR: 84 80 82 03 04 80 80
    const content = [_]u8{ 0x84, 0x80, 0x82, 0x03, 0x04, 0x80, 0x80 };
    const tb = extractTxBodiesBytes(&content) orelse {
        return error.TestUnexpectedResult;
    };
    // tx_bodies bytes should be 82 03 04
    try std.testing.expectEqual(@as(usize, 3), tb.len);
    try std.testing.expectEqual(@as(u8, 0x82), tb[0]);
    try std.testing.expectEqual(@as(u8, 0x03), tb[1]);
    try std.testing.expectEqual(@as(u8, 0x04), tb[2]);

    // Hash them
    var out: [MAX_TX_HASHES][32]u8 = undefined;
    const count = extractTxBodyHashes(tb, &out);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualSlices(u8, &blake2b256(&[_]u8{0x03}), &out[0]);
    try std.testing.expectEqualSlices(u8, &blake2b256(&[_]u8{0x04}), &out[1]);
}

test "extractTxBodiesBytes with realistic header skip" {
    // Block content: [header([0x00, 0x01]), tx_bodies([0x05]), witnesses, metadata, invalid_txs]
    // header = 82 00 01
    // CBOR: 85 82 00 01 81 05 80 80 80
    const content = [_]u8{ 0x85, 0x82, 0x00, 0x01, 0x81, 0x05, 0x80, 0x80, 0x80 };
    const tb = extractTxBodiesBytes(&content) orelse {
        return error.TestUnexpectedResult;
    };
    // tx_bodies = 81 05
    try std.testing.expectEqual(@as(usize, 2), tb.len);
    var out: [MAX_TX_HASHES][32]u8 = undefined;
    const count = extractTxBodyHashes(tb, &out);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualSlices(u8, &blake2b256(&[_]u8{0x05}), &out[0]);
}

test "extractTxBodiesBytes too few elements returns null" {
    const content = [_]u8{ 0x83, 0x80, 0x80, 0x80 }; // array(3)
    try std.testing.expect(extractTxBodiesBytes(&content) == null);
}

test "extractTxBodiesBytes not array returns null" {
    const content = [_]u8{0x05}; // uint
    try std.testing.expect(extractTxBodiesBytes(&content) == null);
}
