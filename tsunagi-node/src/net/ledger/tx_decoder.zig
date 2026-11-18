const std = @import("std");
const compat = @import("compat");
const cbor = @import("../cbor/term.zig");
const tx_decode = @import("tx_decode.zig");

/// Maximum number of per-tx summaries retained per block.
/// If a block contains more transactions, the first MAX_TX_PER_BLOCK
/// are stored and `truncated` is set to true.
pub const MAX_TX_PER_BLOCK: u32 = 32;

/// Summary of a single transaction within a block.
/// Fixed-size, no heap allocations.
pub const TxSummary = struct {
    index: u32,
    inputs: u32,
    outputs: u32,
    fee: ?u64,
    has_metadata: bool,
    withdrawal_count: u32 = 0,
    withdrawal_lovelace: u64 = 0,
    // TX intelligence flags (additive, not exclusive)
    has_certificates: bool = false, // key 3: pool reg, delegation, retirement
    cert_summary: CertificateSummary = .{}, // parsed certificate type breakdown
    has_collateral: bool = false, // key 13: collateral inputs (script validation)
    has_scripts: bool = false, // key 11: script data hash present
    output_lovelace: u64 = 0, // sum of output lovelace across all outputs
};

/// Summary of a decoded block including per-tx summaries.
/// Fixed-size array storage — no dynamic allocation.
pub const BlockDecodeSummary = struct {
    slot: u64,
    block_no: u64,
    block_hash_hex: [64]u8,
    tx_count: u32,
    txs: [MAX_TX_PER_BLOCK]TxSummary,
    txs_len: u32,
    truncated: bool,
    timestamp_unix: i64,
};

/// Result of extracting per-tx summaries from a block.
pub const BlockTxResult = struct {
    summaries: [MAX_TX_PER_BLOCK]TxSummary,
    count: u32,
    truncated: bool,
    block_total_fee_lovelace: u64 = 0,
    // Block-level insight aggregates
    block_total_output_lovelace: u64 = 0,
    block_cert_tx_count: u32 = 0,
    block_cert_summary: CertificateSummary = .{}, // aggregate across all txs in block
    block_script_tx_count: u32 = 0,
    block_collateral_tx_count: u32 = 0,
    // Stake distribution: per-output (stake_credential, lovelace) pairs
    output_stakes: [MAX_OUTPUT_STAKES]OutputStakeEntry = [_]OutputStakeEntry{.{}} ** MAX_OUTPUT_STAKES,
    output_stake_count: u32 = 0,
};

/// Summary of certificate types found in a single transaction.
/// Counts each certificate type individually from the CBOR key-3 array.
/// Maximum delegation entries extracted per certificate array.
const MAX_DELEGATIONS_PER_TX: usize = 4;

pub const DelegationEntry = struct {
    credential_hash: [28]u8 = std.mem.zeroes([28]u8),
    pool_id: [28]u8 = std.mem.zeroes([28]u8),
    valid: bool = false,
};

pub const CertificateSummary = struct {
    stake_registration: u16 = 0,
    stake_deregistration: u16 = 0,
    stake_delegation: u16 = 0,
    pool_registration: u16 = 0,
    pool_retirement: u16 = 0,
    other: u16 = 0,
    total: u16 = 0,
    // Extracted delegation data (type-2 certs)
    delegations: [MAX_DELEGATIONS_PER_TX]DelegationEntry = [_]DelegationEntry{.{}} ** MAX_DELEGATIONS_PER_TX,
    delegation_count: u16 = 0,
};

const WithdrawalResult = struct {
    count: u32 = 0,
    lovelace: u64 = 0,
};

/// Fallback: detect withdrawal presence from the Term layer.
/// The Term decoder strips bytes-keyed entries, so this only detects presence.
fn extractWithdrawalsFromTerm(term_opt: ?cbor.Term) WithdrawalResult {
    const term = term_opt orelse return .{};
    if (term == .map_u64) {
        var total: u64 = 0;
        for (term.map_u64) |entry| {
            if (entry.value == .u64) total += entry.value.u64;
        }
        const count: u32 = if (term.map_u64.len > 0) @intCast(term.map_u64.len) else 1;
        return .{ .count = count, .lovelace = total };
    }
    if (term != .null) return .{ .count = 1, .lovelace = 0 };
    return .{};
}

/// Extract withdrawal count and total lovelace by parsing raw CBOR bytes directly.
/// This bypasses the Term layer, which strips bytes-keyed map entries.
///
/// For map-form tx bodies: finds key `target_key` in the CBOR map, then iterates
/// the withdrawal sub-map counting entries and summing u64 values.
/// For array-form tx bodies: skips to index `target_key` and does the same.
///
/// Returns {0, 0} if key not found or parse fails. Never errors — purely best-effort.
fn extractWithdrawalsFromRaw(alloc: std.mem.Allocator, raw: []const u8, target_key: u64) WithdrawalResult {
    // Decode the full tx body to find key 5's raw position.
    // We re-decode here but this time we intercept the withdrawal map manually.
    var fbs = compat.fixedBufferStream(raw);
    const reader = fbs.reader();

    // Read initial byte to determine if map or array
    const initial = reader.readByte() catch return .{};
    const major = initial >> 5;
    const addl = initial & 0x1f;

    if (major == 5) {
        // Map: iterate key-value pairs, find key == target_key
        const map_len = decodeCborLen(addl, reader) catch return .{};
        var i: u64 = 0;
        while (i < map_len) : (i += 1) {
            const key_val = decodeCborUint(reader) catch return .{};
            if (key_val.is_uint and key_val.value == target_key) {
                return parseWithdrawalMap(reader);
            } else {
                // Skip this value
                skipCborValue(reader) catch return .{};
            }
        }
    } else if (major == 4) {
        // Array: skip to index target_key
        const arr_len = decodeCborLen(addl, reader) catch return .{};
        if (target_key >= arr_len) return .{};
        var i: u64 = 0;
        while (i < target_key) : (i += 1) {
            skipCborValue(reader) catch return .{};
        }
        // Now at index target_key — parse withdrawal map
        return parseWithdrawalMap(reader);
    }

    _ = alloc;
    return .{};
}

/// Extract certificate type counts by parsing raw CBOR bytes directly.
/// Certificates are in tx body key 3 as a CBOR array of certificate entries.
/// Each certificate is a CBOR array where [0] is the certificate type tag:
///   0 = StakeRegistration, 1 = StakeDeregistration, 2 = StakeDelegation,
///   3 = PoolRegistration, 4 = PoolRetirement, 5+ = other (Conway governance, etc.)
///
/// Returns null if key 3 not found or parse fails. Never errors — purely best-effort.
fn extractCertificatesFromRaw(alloc: std.mem.Allocator, raw: []const u8, target_key: u64) ?CertificateSummary {
    _ = alloc;
    var fbs = compat.fixedBufferStream(raw);
    const reader = fbs.reader();

    const initial = reader.readByte() catch return null;
    const major = initial >> 5;
    const addl = initial & 0x1f;

    if (major == 5) {
        // Map: iterate key-value pairs, find key == target_key
        const map_len = decodeCborLen(addl, reader) catch return null;
        var i: u64 = 0;
        while (i < map_len) : (i += 1) {
            const key_val = decodeCborUint(reader) catch return null;
            if (key_val.is_uint and key_val.value == target_key) {
                return parseCertificateArray(reader);
            } else {
                skipCborValue(reader) catch return null;
            }
        }
    } else if (major == 4) {
        // Array: skip to index target_key
        const arr_len = decodeCborLen(addl, reader) catch return null;
        if (target_key >= arr_len) return null;
        var i: u64 = 0;
        while (i < target_key) : (i += 1) {
            skipCborValue(reader) catch return null;
        }
        return parseCertificateArray(reader);
    }

    return null;
}

/// Parse a CBOR array of certificates. Each element is expected to be
/// a CBOR array where [0] is a uint certificate type tag.
fn parseCertificateArray(reader: FbsReader) ?CertificateSummary {
    const initial = reader.readByte() catch return null;
    const major = initial >> 5;
    const addl = initial & 0x1f;

    if (major != 4) return null; // Not an array
    const arr_len = decodeCborLen(addl, reader) catch return null;
    if (arr_len == 0) return null;

    var summary = CertificateSummary{};
    var i: u64 = 0;
    while (i < arr_len) : (i += 1) {
        // Each certificate is a CBOR array: [type_tag, ...]
        const cert_initial = reader.readByte() catch return summary;
        const cert_major = cert_initial >> 5;
        const cert_addl = cert_initial & 0x1f;

        if (cert_major != 4) {
            // Not an array — skip and count as other
            skipCborValueAfterInitial(cert_major, cert_addl, reader) catch return summary;
            summary.other += 1;
            summary.total += 1;
            continue;
        }

        const cert_len = decodeCborLen(cert_addl, reader) catch return summary;
        if (cert_len == 0) {
            summary.other += 1;
            summary.total += 1;
            continue;
        }

        // Read the type tag (first element)
        const tag_result = decodeCborUint(reader) catch return summary;
        if (tag_result.is_uint) {
            switch (tag_result.value) {
                0 => {
                    summary.stake_registration += 1;
                    // Skip remaining: [credential]
                    var j: u64 = 1;
                    while (j < cert_len) : (j += 1) skipCborValue(reader) catch return summary;
                },
                1 => {
                    summary.stake_deregistration += 1;
                    var j: u64 = 1;
                    while (j < cert_len) : (j += 1) skipCborValue(reader) catch return summary;
                },
                2 => {
                    // Delegation: [2, credential, pool_keyhash(28)]
                    summary.stake_delegation += 1;
                    if (cert_len >= 3) {
                        const cred_hash = readCborCredential(reader);
                        const pool_id = readCborBstr28(reader);
                        if (cred_hash != null and pool_id != null and summary.delegation_count < MAX_DELEGATIONS_PER_TX) {
                            const idx = summary.delegation_count;
                            summary.delegations[idx] = .{
                                .credential_hash = cred_hash.?,
                                .pool_id = pool_id.?,
                                .valid = true,
                            };
                            summary.delegation_count += 1;
                        }
                        // Skip any remaining elements
                        var j: u64 = 3;
                        while (j < cert_len) : (j += 1) skipCborValue(reader) catch return summary;
                    } else {
                        var j: u64 = 1;
                        while (j < cert_len) : (j += 1) skipCborValue(reader) catch return summary;
                    }
                },
                3 => {
                    summary.pool_registration += 1;
                    var j: u64 = 1;
                    while (j < cert_len) : (j += 1) skipCborValue(reader) catch return summary;
                },
                4 => {
                    summary.pool_retirement += 1;
                    var j: u64 = 1;
                    while (j < cert_len) : (j += 1) skipCborValue(reader) catch return summary;
                },
                else => {
                    summary.other += 1;
                    var j: u64 = 1;
                    while (j < cert_len) : (j += 1) skipCborValue(reader) catch return summary;
                },
            }
        } else {
            summary.other += 1;
            var j: u64 = 1;
            while (j < cert_len) : (j += 1) skipCborValue(reader) catch return summary;
        }
        summary.total += 1;
    }

    return if (summary.total > 0) summary else null;
}

/// Read a CBOR bytestring of exactly 28 bytes. Returns null on any mismatch.
fn readCborBstr28(reader: FbsReader) ?[28]u8 {
    const b = reader.readByte() catch return null;
    const major = b >> 5;
    const addl = b & 0x1f;
    if (major != 2) {
        // Not a bytestring — skip remainder
        skipCborValueAfterInitial(major, addl, reader) catch {};
        return null;
    }
    const len = decodeCborLen(addl, reader) catch return null;
    if (len != 28) {
        // Wrong length — skip payload
        var remaining: u64 = len;
        var skip_buf: [256]u8 = undefined;
        while (remaining > 0) {
            const n: usize = @intCast(@min(remaining, skip_buf.len));
            _ = reader.readAll(skip_buf[0..n]) catch return null;
            remaining -= n;
        }
        return null;
    }
    var result: [28]u8 = undefined;
    _ = reader.readAll(&result) catch return null;
    return result;
}

/// Read a CBOR credential: [type_tag, keyhash(28)] → returns the 28-byte keyhash.
fn readCborCredential(reader: FbsReader) ?[28]u8 {
    const b = reader.readByte() catch return null;
    const major = b >> 5;
    const addl = b & 0x1f;
    if (major != 4) {
        skipCborValueAfterInitial(major, addl, reader) catch {};
        return null;
    }
    const arr_len = decodeCborLen(addl, reader) catch return null;
    if (arr_len < 2) {
        var k: u64 = 0;
        while (k < arr_len) : (k += 1) skipCborValue(reader) catch {};
        return null;
    }
    // Skip type tag
    skipCborValue(reader) catch return null;
    // Read keyhash
    const hash = readCborBstr28(reader);
    // Skip any remaining
    var k: u64 = 2;
    while (k < arr_len) : (k += 1) skipCborValue(reader) catch {};
    return hash;
}

const UintResult = struct { value: u64, is_uint: bool };

/// Read a CBOR item and return its value if it's a uint. Otherwise return is_uint=false.
fn decodeCborUint(reader: FbsReader) !UintResult {
    const b = try reader.readByte();
    const major = b >> 5;
    const addl = b & 0x1f;
    if (major == 0) {
        // Unsigned integer
        const val = try decodeCborLen(addl, reader);
        return .{ .value = val, .is_uint = true };
    }
    // Not a uint — need to skip the rest of this item.
    // We already consumed the initial byte, so skip based on major/addl.
    skipCborValueAfterInitial(major, addl, reader) catch {};
    return .{ .value = 0, .is_uint = false };
}

/// Parse a CBOR map as a withdrawal map: map<any_key → u64>.
/// Counts entries and sums the u64 values.
fn parseWithdrawalMap(reader: FbsReader) WithdrawalResult {
    const initial = reader.readByte() catch return .{};
    const major = initial >> 5;
    const addl = initial & 0x1f;

    if (major != 5) return .{}; // Not a map
    const map_len = decodeCborLen(addl, reader) catch return .{};

    var count: u32 = 0;
    var total: u64 = 0;
    var i: u64 = 0;
    while (i < map_len) : (i += 1) {
        // Skip key (bytes stake address)
        skipCborValue(reader) catch return .{ .count = count, .lovelace = total };
        // Read value (lovelace u64)
        const vb = reader.readByte() catch return .{ .count = count, .lovelace = total };
        const v_major = vb >> 5;
        const v_addl = vb & 0x1f;
        if (v_major == 0) {
            // Unsigned integer
            const val = decodeCborLen(v_addl, reader) catch return .{ .count = count, .lovelace = total };
            total += val;
            count += 1;
        } else if (v_major == 6) {
            // Tag-wrapped value (e.g., tag(2, bytes) for bignum)
            // Skip the tag number, then try to read the inner value
            _ = decodeCborLen(v_addl, reader) catch return .{ .count = count, .lovelace = total };
            const inner_b = reader.readByte() catch return .{ .count = count, .lovelace = total };
            const inner_major = inner_b >> 5;
            const inner_addl = inner_b & 0x1f;
            if (inner_major == 0) {
                const val = decodeCborLen(inner_addl, reader) catch return .{ .count = count, .lovelace = total };
                total += val;
            } else {
                skipCborValueAfterInitial(inner_major, inner_addl, reader) catch return .{ .count = count, .lovelace = total };
            }
            count += 1;
        } else {
            // Not a uint value — skip
            skipCborValueAfterInitial(v_major, v_addl, reader) catch return .{ .count = count, .lovelace = total };
            count += 1;
        }
    }
    return .{ .count = count, .lovelace = total };
}

const FbsReader = compat.FixedBufferStream([]const u8).Reader;

/// Decode a CBOR additional info length value.
fn decodeCborLen(addl: u8, reader: FbsReader) !u64 {
    if (addl < 24) return @as(u64, addl);
    if (addl == 24) return @as(u64, try reader.readByte());
    if (addl == 25) {
        var buf: [2]u8 = undefined;
        try reader.readNoEof(&buf);
        return std.mem.readInt(u16, &buf, .big);
    }
    if (addl == 26) {
        var buf: [4]u8 = undefined;
        try reader.readNoEof(&buf);
        return std.mem.readInt(u32, &buf, .big);
    }
    if (addl == 27) {
        var buf: [8]u8 = undefined;
        try reader.readNoEof(&buf);
        return std.mem.readInt(u64, &buf, .big);
    }
    return error.InvalidCbor;
}

/// Skip one CBOR value from the reader.
const SkipError = error{ InvalidCbor, EndOfStream };

fn skipCborValue(reader: FbsReader) SkipError!void {
    const b = reader.readByte() catch return error.EndOfStream;
    const major = b >> 5;
    const addl = b & 0x1f;
    try skipCborValueAfterInitial(major, addl, reader);
}

/// Skip the remainder of a CBOR value after the initial byte has been read.
fn skipCborValueAfterInitial(major: u8, addl: u8, reader: FbsReader) SkipError!void {
    switch (major) {
        0, 1 => {
            // uint / nint: skip additional length bytes
            if (addl >= 24 and addl <= 27) {
                const skip: u8 = @as(u8, 1) << @intCast(addl - 24);
                var buf: [8]u8 = undefined;
                _ = try reader.readAll(buf[0..skip]);
            }
        },
        2, 3 => {
            // bytes / text: skip length then payload
            if (addl == 31) {
                // Indefinite: skip chunks until break
                while (true) {
                    const chunk_b = try reader.readByte();
                    if (chunk_b == 0xff) break;
                    const chunk_addl = chunk_b & 0x1f;
                    const chunk_len = try decodeCborLen(chunk_addl, reader);
                    var remaining: u64 = chunk_len;
                    var skip_buf: [256]u8 = undefined;
                    while (remaining > 0) {
                        const n = @min(remaining, skip_buf.len);
                        _ = try reader.readAll(skip_buf[0..@intCast(n)]);
                        remaining -= n;
                    }
                }
            } else {
                const len = try decodeCborLen(addl, reader);
                var remaining: u64 = len;
                var skip_buf: [256]u8 = undefined;
                while (remaining > 0) {
                    const n = @min(remaining, skip_buf.len);
                    _ = try reader.readAll(skip_buf[0..@intCast(n)]);
                    remaining -= n;
                }
            }
        },
        4 => {
            // Array: skip N items
            if (addl == 31) {
                while (true) {
                    const item_b = try reader.readByte();
                    if (item_b == 0xff) break;
                    try skipCborValueAfterInitial(item_b >> 5, item_b & 0x1f, reader);
                }
            } else {
                const len = try decodeCborLen(addl, reader);
                var j: u64 = 0;
                while (j < len) : (j += 1) try skipCborValue(reader);
            }
        },
        5 => {
            // Map: skip N key-value pairs
            if (addl == 31) {
                while (true) {
                    const k_b = try reader.readByte();
                    if (k_b == 0xff) break;
                    try skipCborValueAfterInitial(k_b >> 5, k_b & 0x1f, reader);
                    try skipCborValue(reader);
                }
            } else {
                const len = try decodeCborLen(addl, reader);
                var j: u64 = 0;
                while (j < len) : (j += 1) {
                    try skipCborValue(reader);
                    try skipCborValue(reader);
                }
            }
        },
        6 => {
            // Tag: skip tag value then skip content
            if (addl >= 24 and addl <= 27) {
                const skip: u8 = @as(u8, 1) << @intCast(addl - 24);
                var buf: [8]u8 = undefined;
                _ = try reader.readAll(buf[0..skip]);
            }
            try skipCborValue(reader);
        },
        7 => {
            // Simple / float: skip additional bytes
            if (addl >= 24 and addl <= 27) {
                const skip: u8 = @as(u8, 1) << @intCast(addl - 24);
                var buf: [8]u8 = undefined;
                _ = try reader.readAll(buf[0..skip]);
            }
        },
        else => {},
    }
}

/// Sum lovelace across all outputs in an outputs array term.
/// Handles both legacy [addr, value] and post-Alonzo {0: addr, 1: value} forms.
fn sumOutputLovelace(outputs_term: ?cbor.Term) u64 {
    const term = outputs_term orelse return 0;
    const items = if (term == .array) term.array else if (term == .tag and term.tag.value.* == .array) term.tag.value.*.array else return 0;
    var total: u64 = 0;
    for (items) |out| {
        if (out == .array and out.array.len >= 2) {
            // Legacy: [addr, value]
            total += extractOutputLovelace(out.array[1]);
        } else if (out == .map_u64) {
            // Post-Alonzo: {0: addr, 1: value, ...}
            if (tx_decode.findMapKeyPublic(out.map_u64, 1)) |val| {
                total += extractOutputLovelace(val);
            }
        }
    }
    return total;
}

/// Extract lovelace from an output value term.
/// Value is either u64 (lovelace only) or [lovelace, multiasset_map].
fn extractOutputLovelace(val: cbor.Term) u64 {
    if (val == .u64) return val.u64;
    if (val == .array and val.array.len >= 1 and val.array[0] == .u64) return val.array[0].u64;
    return 0;
}

/// Output stake entry: (stake_credential, lovelace) extracted from an output address.
pub const OutputStakeEntry = struct {
    stake_credential: [28]u8 = std.mem.zeroes([28]u8),
    lovelace: u64 = 0,
    valid: bool = false,
};

pub const MAX_OUTPUT_STAKES: usize = 32;

pub const OutputStakeResult = struct {
    entries: [MAX_OUTPUT_STAKES]OutputStakeEntry = [_]OutputStakeEntry{.{}} ** MAX_OUTPUT_STAKES,
    count: u32 = 0,
};

/// Extract (stake_credential, lovelace) pairs from all outputs in a block.
/// Only extracts from Shelley base addresses (57+ bytes, type 0-3).
pub fn extractOutputStakes(outputs_term: ?cbor.Term) OutputStakeResult {
    var result = OutputStakeResult{};
    const term = outputs_term orelse return result;
    const items = if (term == .array) term.array else if (term == .tag and term.tag.value.* == .array) term.tag.value.*.array else return result;

    for (items) |out| {
        if (result.count >= MAX_OUTPUT_STAKES) break;

        var addr_bytes: ?[]const u8 = null;
        var lovelace: u64 = 0;

        if (out == .array and out.array.len >= 2) {
            // Legacy: [addr, value]
            if (out.array[0] == .bytes) addr_bytes = out.array[0].bytes;
            lovelace = extractOutputLovelace(out.array[1]);
        } else if (out == .map_u64) {
            // Post-Alonzo: {0: addr, 1: value}
            if (tx_decode.findMapKeyPublic(out.map_u64, 0)) |a| {
                if (a == .bytes) addr_bytes = a.bytes;
            }
            if (tx_decode.findMapKeyPublic(out.map_u64, 1)) |v| {
                lovelace = extractOutputLovelace(v);
            }
        }

        if (addr_bytes) |ab| {
            if (ab.len >= 57) {
                const addr_type = ab[0] >> 4;
                if (addr_type <= 3 and lovelace > 0) {
                    var entry = &result.entries[result.count];
                    @memcpy(&entry.stake_credential, ab[29..57]);
                    entry.lovelace = lovelace;
                    entry.valid = true;
                    result.count += 1;
                }
            }
        }
    }
    return result;
}

/// Count elements in an array-like term (array or tag-wrapped array).
fn countArrayLike(term: cbor.Term) ?u32 {
    if (term == .array) return @intCast(term.array.len);
    if (term == .tag and term.tag.value.* == .array) return @intCast(term.tag.value.*.array.len);
    return null;
}

const DecodedTxItem = struct { term: cbor.Term, allocated: bool };

/// Try to decode a tx item (bytes/tag) into a usable tx body Term.
/// Returns the term and whether it was newly allocated (caller must free if so).
fn decodeTxItem(alloc: std.mem.Allocator, item: cbor.Term) ?DecodedTxItem {
    return decodeTxItemInner(alloc, item, 0);
}

fn decodeTxItemInner(alloc: std.mem.Allocator, item: cbor.Term, depth: u32) ?DecodedTxItem {
    if (depth > 10) return null;

    // Direct map_u64 — validate it has inputs/outputs/fee
    if (item == .map_u64) {
        if (isValidTxBodyMap(item.map_u64)) {
            return .{ .term = item, .allocated = false };
        }
        return null;
    }

    // Tag wrapper — unwrap and recurse
    if (item == .tag) {
        return decodeTxItemInner(alloc, item.tag.value.*, depth + 1);
    }

    // Bytes — decode CBOR-in-CBOR
    if (item == .bytes) {
        if (item.bytes.len < 50 or item.bytes.len == 32) return null;
        const decoded = cbor.decodeOrRaw(alloc, item.bytes) catch return null;
        const result = decodeTxItemInner(alloc, decoded, depth + 1);
        if (result == null) {
            cbor.free(decoded, alloc);
        }
        return result;
    }

    // Array — could be tx body array format [inputs, outputs, fee, ...]
    if (item == .array) {
        const arr = item.array;
        if (arr.len >= 3) {
            const first = arr[0];
            if (first == .array or (first == .tag and first.tag.value.* == .array)) {
                return .{ .term = item, .allocated = false };
            }
        }
    }

    return null;
}

/// Check if a map looks like a valid tx body (has keys 0, 1, 2).
fn isValidTxBodyMap(m: []const cbor.MapEntry) bool {
    if (m.len == 0) return false;
    const key0 = tx_decode.findMapKeyPublic(m, 0);
    const has_inputs = if (key0) |k| countArrayLike(k) != null else false;
    const key1 = tx_decode.findMapKeyPublic(m, 1);
    const has_outputs = if (key1) |k| (k == .array or (k == .tag and k.tag.value.* == .array)) else false;
    const key2 = tx_decode.findMapKeyPublic(m, 2);
    const has_fee = if (key2) |k| k == .u64 else false;
    return has_inputs and has_outputs and has_fee;
}

/// Extract a TxSummary from a decoded tx body Term.
/// raw_cbor: optional raw CBOR bytes for targeted withdrawal parsing.
fn summarizeTx(alloc: std.mem.Allocator, tx_term: cbor.Term, index: u32, raw_cbor: ?[]const u8) ?TxSummary {
    if (tx_term == .map_u64) {
        const m = tx_term.map_u64;
        const inputs = blk: {
            const key0 = tx_decode.findMapKeyPublic(m, 0) orelse break :blk @as(u32, 0);
            break :blk countArrayLike(key0) orelse 0;
        };
        const outputs = blk: {
            const key1 = tx_decode.findMapKeyPublic(m, 1) orelse break :blk @as(u32, 0);
            break :blk countArrayLike(key1) orelse 0;
        };
        const fee: ?u64 = blk: {
            const key2 = tx_decode.findMapKeyPublic(m, 2) orelse break :blk null;
            if (key2 == .u64) break :blk key2.u64;
            break :blk null;
        };
        const has_metadata = tx_decode.findMapKeyPublic(m, 7) != null;

        // Withdrawals: extract from raw CBOR (key 5 has bytes-keyed map entries
        // that the Term decoder strips). Fall back to Term-based detection.
        const wdrl = if (raw_cbor) |raw|
            extractWithdrawalsFromRaw(alloc, raw, 5)
        else
            extractWithdrawalsFromTerm(tx_decode.findMapKeyPublic(m, 5));

        // TX intelligence flags
        const has_certificates = tx_decode.findMapKeyPublic(m, 3) != null;
        const has_collateral = tx_decode.findMapKeyPublic(m, 13) != null;
        const has_scripts = tx_decode.findMapKeyPublic(m, 11) != null;
        const out_ada = sumOutputLovelace(tx_decode.findMapKeyPublic(m, 1));

        // Certificate type breakdown (from raw CBOR, key 3)
        const cert_summary: CertificateSummary = if (has_certificates and raw_cbor != null)
            (extractCertificatesFromRaw(alloc, raw_cbor.?, 3) orelse CertificateSummary{})
        else
            CertificateSummary{};

        return .{
            .index = index,
            .inputs = inputs,
            .outputs = outputs,
            .fee = fee,
            .has_metadata = has_metadata,
            .withdrawal_count = wdrl.count,
            .withdrawal_lovelace = wdrl.lovelace,
            .has_certificates = has_certificates,
            .cert_summary = cert_summary,
            .has_collateral = has_collateral,
            .has_scripts = has_scripts,
            .output_lovelace = out_ada,
        };
    }

    if (tx_term == .array) {
        const arr = tx_term.array;
        if (arr.len < 3) return null;
        const inputs = countArrayLike(arr[0]) orelse 0;
        const outputs = countArrayLike(arr[1]) orelse 0;
        const fee: ?u64 = if (arr[2] == .u64) arr[2].u64 else null;
        const has_metadata = arr.len > 7 and arr[7] != .null;

        const wdrl = if (raw_cbor) |raw|
            extractWithdrawalsFromRaw(alloc, raw, 5)
        else if (arr.len > 5)
            extractWithdrawalsFromTerm(arr[5])
        else
            WithdrawalResult{};

        // TX intelligence flags (array form)
        const has_certificates = arr.len > 3 and arr[3] != .null and
            !(arr[3] == .array and arr[3].array.len == 0);
        const has_collateral = arr.len > 13 and arr[13] != .null;
        const has_scripts = arr.len > 11 and arr[11] != .null;
        const out_ada = sumOutputLovelace(arr[1]);

        // Certificate type breakdown (from raw CBOR, key 3)
        const cert_summary: CertificateSummary = if (has_certificates and raw_cbor != null)
            (extractCertificatesFromRaw(alloc, raw_cbor.?, 3) orelse CertificateSummary{})
        else
            CertificateSummary{};

        return .{
            .index = index,
            .inputs = inputs,
            .outputs = outputs,
            .fee = fee,
            .has_metadata = has_metadata,
            .withdrawal_count = wdrl.count,
            .withdrawal_lovelace = wdrl.lovelace,
            .has_certificates = has_certificates,
            .cert_summary = cert_summary,
            .has_collateral = has_collateral,
            .has_scripts = has_scripts,
            .output_lovelace = out_ada,
        };
    }

    return null;
}

/// Extract per-tx summaries from a tx list (individual CBOR Terms).
/// Operates on the same tx_list_items that extractTxDeltas uses.
/// Fixed-size output — stores up to MAX_TX_PER_BLOCK summaries.
pub fn extractTxSummaries(
    alloc: std.mem.Allocator,
    tx_list_items: []cbor.Term,
) BlockTxResult {
    return extractTxSummariesWithRaw(alloc, tx_list_items, null);
}

/// Extract tx summaries with optional raw tx_bodies bytes for withdrawal extraction.
/// When raw_tx_bodies is provided, per-tx raw CBOR is extracted from it to parse
/// bytes-keyed withdrawal maps that the Term decoder strips.
pub fn extractTxSummariesWithRaw(
    alloc: std.mem.Allocator,
    tx_list_items: []cbor.Term,
    raw_tx_bodies: ?[]const u8,
) BlockTxResult {
    var result: BlockTxResult = .{
        .summaries = undefined,
        .count = 0,
        .truncated = false,
    };

    // Pre-compute raw CBOR offsets per tx from raw_tx_bodies (if provided).
    // tx_bodies is a CBOR array: header byte(s) followed by N elements.
    var raw_offsets: [MAX_TX_PER_BLOCK]usize = undefined;
    var raw_sizes: [MAX_TX_PER_BLOCK]usize = undefined;
    var raw_count: u32 = 0;
    if (raw_tx_bodies) |rtb| {
        const block_hash_mod = @import("../ledger/block_hash.zig");
        const hdr = block_hash_mod.readCborHdr(rtb);
        if (hdr) |h| {
            if (h.major == 4) {
                var pos: usize = h.hdr_len;
                var ri: u32 = 0;
                while (ri < h.value and ri < MAX_TX_PER_BLOCK and pos < rtb.len) : (ri += 1) {
                    const elem_size = block_hash_mod.skipCborElement(rtb[pos..]) orelse break;
                    raw_offsets[ri] = pos;
                    raw_sizes[ri] = elem_size;
                    raw_count = ri + 1;
                    pos += elem_size;
                }
            }
        }
    }

    for (tx_list_items, 0..) |item, idx| {
        if (result.count >= MAX_TX_PER_BLOCK) {
            result.truncated = true;
            break;
        }

        // Extract raw CBOR bytes for targeted key-5 parsing (withdrawal map).
        // Priority: item.bytes (ChainSync), then raw_tx_bodies slice (BlockFetch).
        const raw_cbor: ?[]const u8 = if (item == .bytes and item.bytes.len > 50)
            item.bytes
        else if (item == .tag and item.tag.value.* == .bytes and item.tag.value.*.bytes.len > 50)
            item.tag.value.*.bytes
        else if (raw_tx_bodies != null and idx < raw_count)
            raw_tx_bodies.?[raw_offsets[idx] .. raw_offsets[idx] + raw_sizes[idx]]
        else
            null;

        const decoded_opt = decodeTxItem(alloc, item);
        if (decoded_opt == null) continue;
        const decoded = decoded_opt.?;
        defer if (decoded.allocated) cbor.free(decoded.term, alloc);

        if (summarizeTx(alloc, decoded.term, @intCast(idx), raw_cbor)) |summary| {
            result.summaries[result.count] = summary;
            result.count += 1;
            if (summary.fee) |f| result.block_total_fee_lovelace += f;
            result.block_total_output_lovelace += summary.output_lovelace;
            if (summary.has_certificates) {
                result.block_cert_tx_count += 1;
                // Aggregate per-tx cert summary into block-level totals
                result.block_cert_summary.stake_registration += summary.cert_summary.stake_registration;
                result.block_cert_summary.stake_deregistration += summary.cert_summary.stake_deregistration;
                result.block_cert_summary.stake_delegation += summary.cert_summary.stake_delegation;
                result.block_cert_summary.pool_registration += summary.cert_summary.pool_registration;
                result.block_cert_summary.pool_retirement += summary.cert_summary.pool_retirement;
                result.block_cert_summary.other += summary.cert_summary.other;
                result.block_cert_summary.total += summary.cert_summary.total;
                // Aggregate delegation entries
                for (summary.cert_summary.delegations[0..summary.cert_summary.delegation_count]) |deleg| {
                    if (deleg.valid and result.block_cert_summary.delegation_count < MAX_DELEGATIONS_PER_TX) {
                        result.block_cert_summary.delegations[result.block_cert_summary.delegation_count] = deleg;
                        result.block_cert_summary.delegation_count += 1;
                    }
                }
            }
            if (summary.has_scripts) result.block_script_tx_count += 1;
            if (summary.has_collateral) result.block_collateral_tx_count += 1;

            // Extract output stake entries (stake_credential, lovelace)
            const outputs_term = if (decoded.term == .map_u64)
                tx_decode.findMapKeyPublic(decoded.term.map_u64, 1)
            else if (decoded.term == .array and decoded.term.array.len >= 2)
                decoded.term.array[1]
            else
                null;
            if (outputs_term != null) {
                const stakes = extractOutputStakes(outputs_term);
                for (stakes.entries[0..stakes.count]) |entry| {
                    if (entry.valid and result.output_stake_count < MAX_OUTPUT_STAKES) {
                        result.output_stakes[result.output_stake_count] = entry;
                        result.output_stake_count += 1;
                    }
                }
            }
        }
    }

    return result;
}

// ── Inline Tests ──────────────────────────────────────────
// All test Terms are constructed on the stack — no heap allocation,
// no cbor.free needed. extractTxSummaries only reads the Terms.

test "extractTxSummaries with map_u64 tx body" {
    // inputs: 2-element array of [hash, index] pairs
    var inp0_items = [_]cbor.Term{ .{ .bytes = &([_]u8{0} ** 32) }, .{ .u64 = 0 } };
    var inp1_items = [_]cbor.Term{ .{ .bytes = &([_]u8{0} ** 32) }, .{ .u64 = 1 } };
    const inp0 = cbor.Term{ .array = &inp0_items };
    const inp1 = cbor.Term{ .array = &inp1_items };
    var input_items = [_]cbor.Term{ inp0, inp1 };
    const inputs = cbor.Term{ .array = &input_items };

    // outputs: 3-element array
    var out0_items = [_]cbor.Term{ .{ .bytes = "addr" }, .{ .u64 = 1000000 } };
    var out1_items = [_]cbor.Term{ .{ .bytes = "addr" }, .{ .u64 = 2000000 } };
    var out2_items = [_]cbor.Term{ .{ .bytes = "addr" }, .{ .u64 = 3000000 } };
    const out0 = cbor.Term{ .array = &out0_items };
    const out1 = cbor.Term{ .array = &out1_items };
    const out2 = cbor.Term{ .array = &out2_items };
    var output_items = [_]cbor.Term{ out0, out1, out2 };
    const outputs = cbor.Term{ .array = &output_items };

    // tx body map {0: inputs, 1: outputs, 2: fee}
    var entries = [_]cbor.MapEntry{
        .{ .key = 0, .value = inputs },
        .{ .key = 1, .value = outputs },
        .{ .key = 2, .value = .{ .u64 = 170000 } },
    };
    const tx_body = cbor.Term{ .map_u64 = &entries };

    var tx_list = [_]cbor.Term{tx_body};
    const result = extractTxSummaries(std.testing.allocator, &tx_list);

    try std.testing.expectEqual(@as(u32, 1), result.count);
    try std.testing.expect(!result.truncated);
    try std.testing.expectEqual(@as(u32, 0), result.summaries[0].index);
    try std.testing.expectEqual(@as(u32, 2), result.summaries[0].inputs);
    try std.testing.expectEqual(@as(u32, 3), result.summaries[0].outputs);
    try std.testing.expectEqual(@as(?u64, 170000), result.summaries[0].fee);
    try std.testing.expect(!result.summaries[0].has_metadata);
}

test "extractTxSummaries detects metadata" {
    var inp_inner = [_]cbor.Term{ .{ .bytes = &([_]u8{0} ** 32) }, .{ .u64 = 0 } };
    var inp_arr = [_]cbor.Term{cbor.Term{ .array = &inp_inner }};
    const inputs = cbor.Term{ .array = &inp_arr };

    var out_inner = [_]cbor.Term{ .{ .bytes = "addr" }, .{ .u64 = 1000000 } };
    var out_arr = [_]cbor.Term{cbor.Term{ .array = &out_inner }};
    const outputs = cbor.Term{ .array = &out_arr };

    // Map with key 7 (metadata) present
    var entries = [_]cbor.MapEntry{
        .{ .key = 0, .value = inputs },
        .{ .key = 1, .value = outputs },
        .{ .key = 2, .value = .{ .u64 = 200000 } },
        .{ .key = 7, .value = .{ .u64 = 42 } },
    };
    const tx_body = cbor.Term{ .map_u64 = &entries };

    var tx_list = [_]cbor.Term{tx_body};
    const result = extractTxSummaries(std.testing.allocator, &tx_list);

    try std.testing.expectEqual(@as(u32, 1), result.count);
    try std.testing.expect(result.summaries[0].has_metadata);
    try std.testing.expectEqual(@as(?u64, 200000), result.summaries[0].fee);
}

test "extractTxSummaries with array-format tx body" {
    // Conway-style: [inputs, outputs, fee]
    var inp_inner = [_]cbor.Term{ .{ .bytes = &([_]u8{0} ** 32) }, .{ .u64 = 0 } };
    var inp_arr = [_]cbor.Term{cbor.Term{ .array = &inp_inner }};
    const inputs = cbor.Term{ .array = &inp_arr };

    var out0_items = [_]cbor.Term{ .{ .bytes = "addr" }, .{ .u64 = 500000 } };
    var out1_items = [_]cbor.Term{ .{ .bytes = "addr" }, .{ .u64 = 600000 } };
    var out_arr = [_]cbor.Term{
        cbor.Term{ .array = &out0_items },
        cbor.Term{ .array = &out1_items },
    };
    const outputs = cbor.Term{ .array = &out_arr };

    var body_items = [_]cbor.Term{ inputs, outputs, .{ .u64 = 185000 } };
    const tx_body = cbor.Term{ .array = &body_items };

    var tx_list = [_]cbor.Term{tx_body};
    const result = extractTxSummaries(std.testing.allocator, &tx_list);

    try std.testing.expectEqual(@as(u32, 1), result.count);
    try std.testing.expectEqual(@as(u32, 1), result.summaries[0].inputs);
    try std.testing.expectEqual(@as(u32, 2), result.summaries[0].outputs);
    try std.testing.expectEqual(@as(?u64, 185000), result.summaries[0].fee);
}

test "extractTxSummaries truncation" {
    var empty_list = [_]cbor.Term{};
    const result = extractTxSummaries(std.testing.allocator, &empty_list);
    try std.testing.expectEqual(@as(u32, 0), result.count);
    try std.testing.expect(!result.truncated);
}

test "extractTxSummaries empty tx list" {
    var list = [_]cbor.Term{};
    const result = extractTxSummaries(std.testing.allocator, &list);
    try std.testing.expectEqual(@as(u32, 0), result.count);
    try std.testing.expect(!result.truncated);
}

test "extractWithdrawalsFromRaw parses bytes-keyed withdrawal map" {
    // CBOR: map(4){0:[input],1:[output],2:170000,5:map(1){bytes(29):2500000}}
    // This has a bytes-keyed withdrawal map that the Term decoder would strip.
    const raw = [_]u8{
        0xa4, // map(4)
        0x00, 0x81, 0x82, 0x58, 0x20, // key 0, array(1), array(2), bytes(32)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, // index 0
        0x01, 0x81, 0x82, 0x58, 0x39, // key 1, array(1), array(2), bytes(57)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00,
        0x1a, 0x00, 0x4c, 0x4b, 0x40, // 5_000_000 lovelace
        0x02, 0x1a, 0x00, 0x02, 0x98, 0x10, // key 2, 170000 fee
        0x05, 0xa1, // key 5, map(1)
        0x58, 0x1d, // bytes(29) key
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00,
        0x1a, 0x00, 0x26, 0x25, 0xa0, // 2_500_000 lovelace
    };
    const alloc = std.testing.allocator;
    const result = extractWithdrawalsFromRaw(alloc, &raw, 5);
    try std.testing.expectEqual(@as(u32, 1), result.count);
    try std.testing.expectEqual(@as(u64, 2_500_000), result.lovelace);
}

// ── TX Intelligence Tests ────────────────────────────────────

test "intelligence flags detected in map_u64 body" {
    // Minimal valid tx body with keys 0,1,2 + intelligence keys 3,11,13
    var inp_inner = [_]cbor.Term{ .{ .bytes = &([_]u8{0} ** 32) }, .{ .u64 = 0 } };
    var inp_arr = [_]cbor.Term{cbor.Term{ .array = &inp_inner }};
    const inputs = cbor.Term{ .array = &inp_arr };

    var out_inner = [_]cbor.Term{ .{ .bytes = "addr" }, .{ .u64 = 1_000_000 } };
    var out_arr = [_]cbor.Term{cbor.Term{ .array = &out_inner }};
    const outputs = cbor.Term{ .array = &out_arr };

    // Certificate (key 3): non-empty array
    var cert_items = [_]cbor.Term{.{ .u64 = 0 }};
    // Collateral (key 13): array of [hash, index]
    var coll_inner = [_]cbor.Term{ .{ .bytes = &([_]u8{0} ** 32) }, .{ .u64 = 0 } };
    var coll_items = [_]cbor.Term{cbor.Term{ .array = &coll_inner }};

    var entries = [_]cbor.MapEntry{
        .{ .key = 0, .value = inputs },
        .{ .key = 1, .value = outputs },
        .{ .key = 2, .value = .{ .u64 = 200000 } },
        .{ .key = 3, .value = cbor.Term{ .array = &cert_items } },
        .{ .key = 11, .value = .{ .bytes = &([_]u8{0} ** 32) } }, // script data hash
        .{ .key = 13, .value = cbor.Term{ .array = &coll_items } },
    };
    const tx_body = cbor.Term{ .map_u64 = &entries };

    var tx_list = [_]cbor.Term{tx_body};
    const result = extractTxSummaries(std.testing.allocator, &tx_list);

    try std.testing.expectEqual(@as(u32, 1), result.count);
    try std.testing.expect(result.summaries[0].has_certificates);
    try std.testing.expect(result.summaries[0].has_scripts);
    try std.testing.expect(result.summaries[0].has_collateral);
    try std.testing.expectEqual(@as(?u64, 200000), result.summaries[0].fee);

    // Verify a plain tx does NOT set flags (existing test implicitly covers, but be explicit)
    var plain_entries = [_]cbor.MapEntry{
        .{ .key = 0, .value = inputs },
        .{ .key = 1, .value = outputs },
        .{ .key = 2, .value = .{ .u64 = 100000 } },
    };
    const plain_body = cbor.Term{ .map_u64 = &plain_entries };
    var plain_list = [_]cbor.Term{plain_body};
    const plain_result = extractTxSummaries(std.testing.allocator, &plain_list);
    try std.testing.expect(!plain_result.summaries[0].has_certificates);
    try std.testing.expect(!plain_result.summaries[0].has_scripts);
    try std.testing.expect(!plain_result.summaries[0].has_collateral);
}

test "intelligence flags in array-format body with empty cert edge case" {
    // Array body: [inputs, outputs, fee, certs, ...]
    var inp_inner = [_]cbor.Term{ .{ .bytes = &([_]u8{0} ** 32) }, .{ .u64 = 0 } };
    var inp_arr = [_]cbor.Term{cbor.Term{ .array = &inp_inner }};
    const inputs = cbor.Term{ .array = &inp_arr };

    var out_inner = [_]cbor.Term{ .{ .bytes = "addr" }, .{ .u64 = 500000 } };
    var out_arr = [_]cbor.Term{cbor.Term{ .array = &out_inner }};
    const outputs = cbor.Term{ .array = &out_arr };

    // Non-empty certificates at index 3
    var cert_items = [_]cbor.Term{.{ .u64 = 1 }};

    // Collateral at index 13: need 14 elements
    var coll_inner = [_]cbor.Term{ .{ .bytes = &([_]u8{0} ** 32) }, .{ .u64 = 0 } };
    var coll_items = [_]cbor.Term{cbor.Term{ .array = &coll_inner }};

    var body_items = [_]cbor.Term{
        inputs, // 0
        outputs, // 1
        .{ .u64 = 185000 }, // 2: fee
        cbor.Term{ .array = &cert_items }, // 3: certs (non-empty)
        .{ .null = {} }, // 4
        .{ .null = {} }, // 5
        .{ .null = {} }, // 6
        .{ .null = {} }, // 7
        .{ .null = {} }, // 8
        .{ .null = {} }, // 9
        .{ .null = {} }, // 10
        .{ .bytes = &([_]u8{0} ** 32) }, // 11: script data hash
        .{ .null = {} }, // 12
        cbor.Term{ .array = &coll_items }, // 13: collateral
    };
    const tx_body = cbor.Term{ .array = &body_items };
    var tx_list = [_]cbor.Term{tx_body};
    const result = extractTxSummaries(std.testing.allocator, &tx_list);

    try std.testing.expectEqual(@as(u32, 1), result.count);
    try std.testing.expect(result.summaries[0].has_certificates);
    try std.testing.expect(result.summaries[0].has_scripts);
    try std.testing.expect(result.summaries[0].has_collateral);

    // Empty cert array at index 3 → has_certificates should be false
    var empty_certs = [_]cbor.Term{};
    var body_empty_cert = [_]cbor.Term{
        inputs,
        outputs,
        .{ .u64 = 185000 },
        cbor.Term{ .array = &empty_certs }, // 3: empty certs
    };
    const tx_body2 = cbor.Term{ .array = &body_empty_cert };
    var tx_list2 = [_]cbor.Term{tx_body2};
    const result2 = extractTxSummaries(std.testing.allocator, &tx_list2);
    try std.testing.expect(!result2.summaries[0].has_certificates);
}

test "output_lovelace sums across legacy, multi-asset, and post-Alonzo outputs" {
    var inp_inner = [_]cbor.Term{ .{ .bytes = &([_]u8{0} ** 32) }, .{ .u64 = 0 } };
    var inp_arr = [_]cbor.Term{cbor.Term{ .array = &inp_inner }};
    const inputs = cbor.Term{ .array = &inp_arr };

    // Output 0: legacy [addr, lovelace]
    var out0_items = [_]cbor.Term{ .{ .bytes = "addr0" }, .{ .u64 = 1_000_000 } };
    const out0 = cbor.Term{ .array = &out0_items };

    // Output 1: multi-asset [addr, [lovelace, multiasset_map]]
    var multiasset_entries = [_]cbor.MapEntry{
        .{ .key = 0, .value = .{ .u64 = 100 } },
    };
    var val1_items = [_]cbor.Term{ .{ .u64 = 2_000_000 }, cbor.Term{ .map_u64 = &multiasset_entries } };
    var out1_items = [_]cbor.Term{ .{ .bytes = "addr1" }, cbor.Term{ .array = &val1_items } };
    const out1 = cbor.Term{ .array = &out1_items };

    // Output 2: post-Alonzo map {0: addr, 1: lovelace}
    var out2_entries = [_]cbor.MapEntry{
        .{ .key = 0, .value = .{ .bytes = "addr2" } },
        .{ .key = 1, .value = .{ .u64 = 3_000_000 } },
    };
    const out2 = cbor.Term{ .map_u64 = &out2_entries };

    var output_items = [_]cbor.Term{ out0, out1, out2 };
    const outputs = cbor.Term{ .array = &output_items };

    var entries = [_]cbor.MapEntry{
        .{ .key = 0, .value = inputs },
        .{ .key = 1, .value = outputs },
        .{ .key = 2, .value = .{ .u64 = 170000 } },
    };
    const tx_body = cbor.Term{ .map_u64 = &entries };
    var tx_list = [_]cbor.Term{tx_body};
    const result = extractTxSummaries(std.testing.allocator, &tx_list);

    try std.testing.expectEqual(@as(u32, 1), result.count);
    try std.testing.expectEqual(@as(u64, 6_000_000), result.summaries[0].output_lovelace);
    try std.testing.expectEqual(@as(u32, 3), result.summaries[0].outputs);
}

test "block-level aggregates across multiple txs" {
    // TX 0: fee=170000, output=1M, has_certificates
    var inp_inner = [_]cbor.Term{ .{ .bytes = &([_]u8{0} ** 32) }, .{ .u64 = 0 } };
    var inp_arr = [_]cbor.Term{cbor.Term{ .array = &inp_inner }};
    const inputs = cbor.Term{ .array = &inp_arr };

    var out0_items = [_]cbor.Term{ .{ .bytes = "a" }, .{ .u64 = 1_000_000 } };
    var out0_arr = [_]cbor.Term{cbor.Term{ .array = &out0_items }};
    var cert_items = [_]cbor.Term{.{ .u64 = 0 }};
    var tx0_entries = [_]cbor.MapEntry{
        .{ .key = 0, .value = inputs },
        .{ .key = 1, .value = cbor.Term{ .array = &out0_arr } },
        .{ .key = 2, .value = .{ .u64 = 170000 } },
        .{ .key = 3, .value = cbor.Term{ .array = &cert_items } },
    };
    const tx0 = cbor.Term{ .map_u64 = &tx0_entries };

    // TX 1: fee=200000, output=2M, has_scripts + has_collateral
    var out1_items = [_]cbor.Term{ .{ .bytes = "b" }, .{ .u64 = 2_000_000 } };
    var out1_arr = [_]cbor.Term{cbor.Term{ .array = &out1_items }};
    var coll_inner = [_]cbor.Term{ .{ .bytes = &([_]u8{0} ** 32) }, .{ .u64 = 0 } };
    var coll_arr = [_]cbor.Term{cbor.Term{ .array = &coll_inner }};
    var tx1_entries = [_]cbor.MapEntry{
        .{ .key = 0, .value = inputs },
        .{ .key = 1, .value = cbor.Term{ .array = &out1_arr } },
        .{ .key = 2, .value = .{ .u64 = 200000 } },
        .{ .key = 11, .value = .{ .bytes = &([_]u8{0} ** 32) } },
        .{ .key = 13, .value = cbor.Term{ .array = &coll_arr } },
    };
    const tx1 = cbor.Term{ .map_u64 = &tx1_entries };

    // TX 2: fee=180000, output=3M, no flags
    var out2_items = [_]cbor.Term{ .{ .bytes = "c" }, .{ .u64 = 3_000_000 } };
    var out2_arr = [_]cbor.Term{cbor.Term{ .array = &out2_items }};
    var tx2_entries = [_]cbor.MapEntry{
        .{ .key = 0, .value = inputs },
        .{ .key = 1, .value = cbor.Term{ .array = &out2_arr } },
        .{ .key = 2, .value = .{ .u64 = 180000 } },
    };
    const tx2 = cbor.Term{ .map_u64 = &tx2_entries };

    var tx_list = [_]cbor.Term{ tx0, tx1, tx2 };
    const result = extractTxSummaries(std.testing.allocator, &tx_list);

    try std.testing.expectEqual(@as(u32, 3), result.count);
    try std.testing.expectEqual(@as(u64, 550000), result.block_total_fee_lovelace);
    try std.testing.expectEqual(@as(u64, 6_000_000), result.block_total_output_lovelace);
    try std.testing.expectEqual(@as(u32, 1), result.block_cert_tx_count);
    try std.testing.expectEqual(@as(u32, 1), result.block_script_tx_count);
    try std.testing.expectEqual(@as(u32, 1), result.block_collateral_tx_count);

    // Per-tx checks
    try std.testing.expect(result.summaries[0].has_certificates);
    try std.testing.expect(!result.summaries[0].has_scripts);
    try std.testing.expect(!result.summaries[1].has_certificates);
    try std.testing.expect(result.summaries[1].has_scripts);
    try std.testing.expect(result.summaries[1].has_collateral);
    try std.testing.expect(!result.summaries[2].has_certificates);
    try std.testing.expect(!result.summaries[2].has_scripts);
    try std.testing.expect(!result.summaries[2].has_collateral);
}

test "output_lovelace edge cases: zero, unrecognized format, empty outputs" {
    var inp_inner = [_]cbor.Term{ .{ .bytes = &([_]u8{0} ** 32) }, .{ .u64 = 0 } };
    var inp_arr = [_]cbor.Term{cbor.Term{ .array = &inp_inner }};
    const inputs = cbor.Term{ .array = &inp_arr };

    // Output 0: zero lovelace
    var out0_items = [_]cbor.Term{ .{ .bytes = "addr" }, .{ .u64 = 0 } };
    const out0 = cbor.Term{ .array = &out0_items };

    // Output 1: unrecognized value (bytes instead of u64)
    var out1_items = [_]cbor.Term{ .{ .bytes = "addr" }, .{ .bytes = "garbage" } };
    const out1 = cbor.Term{ .array = &out1_items };

    // Output 2: normal 500_000
    var out2_items = [_]cbor.Term{ .{ .bytes = "addr" }, .{ .u64 = 500_000 } };
    const out2 = cbor.Term{ .array = &out2_items };

    var output_items = [_]cbor.Term{ out0, out1, out2 };
    const outputs = cbor.Term{ .array = &output_items };

    var entries = [_]cbor.MapEntry{
        .{ .key = 0, .value = inputs },
        .{ .key = 1, .value = outputs },
        .{ .key = 2, .value = .{ .u64 = 150000 } },
    };
    const tx_body = cbor.Term{ .map_u64 = &entries };
    var tx_list = [_]cbor.Term{tx_body};
    const result = extractTxSummaries(std.testing.allocator, &tx_list);

    try std.testing.expectEqual(@as(u32, 1), result.count);
    // 0 + 0 (garbage ignored) + 500k = 500k
    try std.testing.expectEqual(@as(u64, 500_000), result.summaries[0].output_lovelace);
    try std.testing.expectEqual(@as(u32, 3), result.summaries[0].outputs);

    // Empty outputs array → output_lovelace should be 0
    var empty_outs = [_]cbor.Term{};
    var empty_entries = [_]cbor.MapEntry{
        .{ .key = 0, .value = inputs },
        .{ .key = 1, .value = cbor.Term{ .array = &empty_outs } },
        .{ .key = 2, .value = .{ .u64 = 100000 } },
    };
    const empty_body = cbor.Term{ .map_u64 = &empty_entries };
    var empty_list = [_]cbor.Term{empty_body};
    const empty_result = extractTxSummaries(std.testing.allocator, &empty_list);
    try std.testing.expectEqual(@as(u64, 0), empty_result.summaries[0].output_lovelace);
    try std.testing.expectEqual(@as(u32, 0), empty_result.summaries[0].outputs);
}

// ── Certificate Parsing Tests ────────────────────────────────

test "extractCertificatesFromRaw parses Shelley certificate types" {
    // CBOR: map(3){0:[input],1:[output],2:fee,3:[cert0,cert1,cert2]}
    // cert0 = [0, stake_cred]  (StakeRegistration)
    // cert1 = [2, stake_cred, pool_hash]  (StakeDelegation)
    // cert2 = [3, pool_params...]  (PoolRegistration)
    const raw = [_]u8{
        0xa4, // map(4)
        0x00, 0x81, 0x82, 0x58, 0x20, // key 0, array(1), array(2), bytes(32)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, // index 0
        0x01, 0x81, 0x82, 0x44, 0x61, 0x64, 0x64, 0x72, // key 1, array(1), array(2), bytes(4) "addr"
        0x1a, 0x00, 0x0f, 0x42, 0x40, // 1_000_000
        0x02, 0x1a, 0x00, 0x02, 0x98, 0x10, // key 2, fee = 170000
        0x03, 0x83, // key 3, array(3) — 3 certificates
        // cert0: [0, bytes(1)] — StakeRegistration
        0x82, 0x00, 0x41, 0xaa,
        // cert1: [2, bytes(1), bytes(1)] — StakeDelegation
        0x83, 0x02, 0x41, 0xbb, 0x41, 0xcc,
        // cert2: [3, bytes(1)] — PoolRegistration (simplified)
        0x82, 0x03, 0x41, 0xdd,
    };
    const alloc = std.testing.allocator;
    const result = extractCertificatesFromRaw(alloc, &raw, 3);
    try std.testing.expect(result != null);
    const cs = result.?;
    try std.testing.expectEqual(@as(u16, 1), cs.stake_registration);
    try std.testing.expectEqual(@as(u16, 0), cs.stake_deregistration);
    try std.testing.expectEqual(@as(u16, 1), cs.stake_delegation);
    try std.testing.expectEqual(@as(u16, 1), cs.pool_registration);
    try std.testing.expectEqual(@as(u16, 0), cs.pool_retirement);
    try std.testing.expectEqual(@as(u16, 0), cs.other);
    try std.testing.expectEqual(@as(u16, 3), cs.total);
}

test "extractCertificatesFromRaw handles Conway governance certs as other" {
    // CBOR: map(2){2:fee,3:[cert]} where cert = [7, bytes(1)] (Conway type)
    const raw = [_]u8{
        0xa2, // map(2)
        0x02, 0x1a, 0x00, 0x02, 0x98, 0x10, // key 2, fee
        0x03, 0x81, // key 3, array(1)
        0x82, 0x07, 0x41, 0xee, // [7, bytes(1)] — Conway governance cert
    };
    const alloc = std.testing.allocator;
    const result = extractCertificatesFromRaw(alloc, &raw, 3);
    try std.testing.expect(result != null);
    const cs = result.?;
    try std.testing.expectEqual(@as(u16, 0), cs.stake_registration);
    try std.testing.expectEqual(@as(u16, 1), cs.other);
    try std.testing.expectEqual(@as(u16, 1), cs.total);
}

test "extractCertificatesFromRaw returns null for missing key" {
    // CBOR: map(1){2:fee} — no key 3
    const raw = [_]u8{
        0xa1, // map(1)
        0x02, 0x1a, 0x00, 0x02, 0x98, 0x10, // key 2, fee
    };
    const alloc = std.testing.allocator;
    const result = extractCertificatesFromRaw(alloc, &raw, 3);
    try std.testing.expect(result == null);
}

test "extractCertificatesFromRaw returns null for empty cert array" {
    // CBOR: map(2){2:fee,3:[]} — empty cert array
    const raw = [_]u8{
        0xa2, // map(2)
        0x02, 0x1a, 0x00, 0x02, 0x98, 0x10, // key 2, fee
        0x03, 0x80, // key 3, array(0)
    };
    const alloc = std.testing.allocator;
    const result = extractCertificatesFromRaw(alloc, &raw, 3);
    try std.testing.expect(result == null);
}

test "extractCertificatesFromRaw handles deregistration and pool retirement" {
    // Two certs: [1, cred] (StakeDeregistration), [4, pool_hash, epoch] (PoolRetirement)
    const raw = [_]u8{
        0xa2, // map(2)
        0x02, 0x19, 0x01, 0x00, // key 2, fee = 256
        0x03, 0x82, // key 3, array(2)
        // cert0: [1, bytes(1)] — StakeDeregistration
        0x82, 0x01, 0x41, 0xaa,
        // cert1: [4, bytes(1), 100] — PoolRetirement
        0x83, 0x04, 0x41, 0xbb, 0x18, 0x64,
    };
    const alloc = std.testing.allocator;
    const result = extractCertificatesFromRaw(alloc, &raw, 3);
    try std.testing.expect(result != null);
    const cs = result.?;
    try std.testing.expectEqual(@as(u16, 1), cs.stake_deregistration);
    try std.testing.expectEqual(@as(u16, 1), cs.pool_retirement);
    try std.testing.expectEqual(@as(u16, 0), cs.stake_registration);
    try std.testing.expectEqual(@as(u16, 0), cs.stake_delegation);
    try std.testing.expectEqual(@as(u16, 0), cs.pool_registration);
    try std.testing.expectEqual(@as(u16, 2), cs.total);
}
