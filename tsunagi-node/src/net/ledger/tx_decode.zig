const std = @import("std");
const compat = @import("compat");
const cbor = @import("../cbor/term.zig");
const cbor_term = @import("../cbor/term.zig");
const utxo = @import("utxo.zig");
const block_hash = @import("block_hash.zig");
const insight_window = @import("insight_window.zig");

fn txExtractVerboseEnabled() bool {
    return compat.hasEnvVar(std.heap.page_allocator, "TSUNAGI_TX_EXTRACT_VERBOSE");
}

/// TX decode failure counters (module-level, monotonic).
/// Queried by metrics layer via getDecodeCounters().
pub const DecodeCounters = struct {
    decode_fail: u64 = 0, // tx item not decodable (CBOR parse error)
    input_parse_fail: u64 = 0, // parseInputs returned null
    output_parse_fail: u64 = 0, // parseOutputs returned null
    hash_fail: u64 = 0, // txid hash computation failed
    txid_count_mismatch: u64 = 0, // canonical txid count != tx list count
    blocks_total: u64 = 0, // total blocks processed through extractTxDeltas
    ancestry_skip: u64 = 0, // delta apply skipped due to ancestry break
    block_total_fee_last: u64 = 0, // total fee lovelace in most recent decoded block
    block_total_output_last: u64 = 0, // total output lovelace in most recent decoded block
    withdrawal_txs_total: u64 = 0, // txs with at least one withdrawal (across all blocks)
    cert_txs_total: u64 = 0, // txs with certificates (across all blocks)
    // Certificate type breakdown (cumulative across all blocks)
    cert_stake_reg_total: u64 = 0,
    cert_stake_dereg_total: u64 = 0,
    cert_delegation_total: u64 = 0,
    cert_pool_reg_total: u64 = 0,
    cert_pool_retire_total: u64 = 0,
    cert_other_total: u64 = 0,
    cert_total: u64 = 0, // sum of all individual certificate actions
    script_txs_total: u64 = 0, // txs with script data hash (across all blocks)
    collateral_txs_total: u64 = 0, // txs with collateral inputs (across all blocks)
    // Validation envelope v0
    balance_violation_total: u64 = 0, // blocks rejected for lovelace balance violation
    address_malformed_total: u64 = 0, // outputs skipped for malformed address
    input_duplicate_total: u64 = 0, // txs rejected for duplicate inputs
    validity_ttl_fail: u64 = 0, // txs with expired TTL (invalid_hereafter < block_slot)
    validity_start_fail: u64 = 0, // txs with future validity_start (invalid_before > block_slot)
    fee_zero_total: u64 = 0, // txs with fee == 0
};

const Counters = struct {
    var c: DecodeCounters = .{};
};

pub fn getDecodeCounters() DecodeCounters {
    return Counters.c;
}

pub fn incrementBalanceViolation() void {
    Counters.c.balance_violation_total += 1;
}

pub fn incrementAddressMalformed() void {
    Counters.c.address_malformed_total += 1;
}

const InsightState = struct {
    var ring: insight_window.InsightRing = insight_window.InsightRing.init();
};

pub fn getInsightRing() *const insight_window.InsightRing {
    return &InsightState.ring;
}

pub fn incrAncestrySkip() void {
    Counters.c.ancestry_skip += 1;
}

/// Update fee/withdrawal counters from a decoded block's tx summaries.
pub fn updateBlockSummaryCounters(result: @import("tx_decoder.zig").BlockTxResult) void {
    Counters.c.block_total_fee_last = result.block_total_fee_lovelace;
    Counters.c.block_total_output_last = result.block_total_output_lovelace;
    var wdrl_count: u32 = 0;
    var i: u32 = 0;
    while (i < result.count) : (i += 1) {
        const s = result.summaries[i];
        if (s.withdrawal_count > 0) { Counters.c.withdrawal_txs_total += 1; wdrl_count += 1; }
        if (s.has_certificates) {
            Counters.c.cert_txs_total += 1;
            Counters.c.cert_stake_reg_total += s.cert_summary.stake_registration;
            Counters.c.cert_stake_dereg_total += s.cert_summary.stake_deregistration;
            Counters.c.cert_delegation_total += s.cert_summary.stake_delegation;
            Counters.c.cert_pool_reg_total += s.cert_summary.pool_registration;
            Counters.c.cert_pool_retire_total += s.cert_summary.pool_retirement;
            Counters.c.cert_other_total += s.cert_summary.other;
            Counters.c.cert_total += s.cert_summary.total;
        }
        if (s.has_scripts) Counters.c.script_txs_total += 1;
        if (s.has_collateral) Counters.c.collateral_txs_total += 1;
    }

    // Record into insight ring buffer
    InsightState.ring.record(
        compat.timestamp(),
        result.count,
        result.block_total_fee_lovelace,
        result.block_total_output_lovelace,
        result.block_script_tx_count,
        result.block_cert_tx_count,
        result.block_collateral_tx_count,
        wdrl_count,
    );
}

pub const TxDeltas = struct {
    consumed: []const utxo.TxIn,
    produced: []const utxo.Produced,
    tx_count: u64,
};

pub const TxBodyScan = struct {
    tx_list: []cbor.Term,
    owner: cbor.Term,
};

const TxBodyDecode = struct {
    term: cbor.Term,
    allocated: bool,
};

pub fn freeTxDeltas(alloc: std.mem.Allocator, d: TxDeltas) void {
    // Free duped address bytes in each produced output
    for (d.produced) |p| {
        if (p.output.address.len > 0) {
            alloc.free(@constCast(p.output.address));
        }
    }
    alloc.free(@constCast(d.consumed));
    alloc.free(@constCast(d.produced));
}

fn isTag24Bytes(t: cbor.Term) bool {
    return t == .tag and t.tag.tag == 24 and t.tag.value.* == .bytes;
}

fn unwrapTag24Bytes(t: cbor.Term) ?[]const u8 {
    if (t == .bytes) return t.bytes;
    if (isTag24Bytes(t)) return t.tag.value.*.bytes;
    return null;
}

fn termKindName(t: cbor.Term) []const u8 {
    return switch (t) {
        .u64 => "u64",
        .i64 => "i64",
        .bool => "bool",
        .null => "null",
        .bytes => "bytes",
        .text => "text",
        .array => "array",
        .map_u64 => "map_u64",
        .tag => "tag",
    };
}

fn decodeCborFromBytes(alloc: std.mem.Allocator, bytes: []const u8) anyerror!cbor.Term {
    if (bytes.len == 0) return error.EndOfStream;
    var fbs = compat.fixedBufferStream(bytes);
    const reader = fbs.reader();
    const tx_term = cbor.decode(alloc, reader) catch |err| {
        if (err == error.UnsupportedCborType) {
            // Fallback: preserve raw CBOR bytes (indefinite arrays / maps)
            return try cbor_term.decodeOrRaw(alloc, bytes);
        }
        return err;
    };
    return tx_term;
}

/// Validate that a map looks like a real Cardano transaction body
// Helper: unwrap array-like terms (array or tag-wrapped array)
fn unwrapArrayLike(term: cbor.Term) ?[]cbor.Term {
    if (term == .array) return term.array;
    if (term == .tag and term.tag.value.* == .array) return term.tag.value.*.array;
    return null;
}

// Helper: find value for a key in map_u64
fn findMapKey(m: []const cbor.MapEntry, key: u64) ?cbor.Term {
    for (m) |entry| {
        if (entry.key == key) return entry.value;
    }
    return null;
}

// Public version for external use
pub fn findMapKeyPublic(m: []const cbor.MapEntry, key: u64) ?cbor.Term {
    return findMapKey(m, key);
}

/// Extract consumed input references (tx_hash, index) from raw tx CBOR bytes.
/// Used by mempool eviction to check if a tx's inputs overlap with a block's consumed set.
/// Returns null if the tx cannot be parsed. Caller must free the returned slice.
pub fn extractTxInputsFromBytes(alloc: std.mem.Allocator, tx_bytes: []const u8) ?[]utxo.TxIn {
    // Decode tx: [body, witnesses, ...] or {0: body, 1: witnesses, ...}
    var fbs = compat.fixedBufferStream(tx_bytes);
    const term = cbor.decode(alloc, fbs.reader()) catch return null;
    defer cbor.free(term, alloc);

    // Extract tx body
    const body: cbor.Term = if (term == .array and term.array.len >= 1) blk: {
        const b = term.array[0];
        // Body may be direct map or CBOR-in-CBOR bytes
        if (b == .map_u64) break :blk b;
        if (b == .bytes and b.bytes.len > 50) {
            var inner_fbs = compat.fixedBufferStream(b.bytes);
            const inner = cbor.decode(alloc, inner_fbs.reader()) catch break :blk b;
            // Don't defer free — we'll use the outer term's lifetime
            _ = inner;
            break :blk b;
        }
        break :blk b;
    } else if (term == .map_u64) blk: {
        if (findMapKey(term.map_u64, 0) != null) break :blk term;
        break :blk term;
    } else return null;

    // Get inputs from key 0
    const inputs_term = if (body == .map_u64)
        findMapKey(body.map_u64, 0) orelse return null
    else if (body == .array and body.array.len > 0)
        body.array[0]
    else
        return null;

    const inputs_array = unwrapArrayLike(inputs_term) orelse return null;

    var out = std.array_list.Managed(utxo.TxIn).init(alloc);
    for (inputs_array) |inp| {
        if (inp != .array or inp.array.len < 2) continue;
        if (inp.array[1] != .u64) continue;
        var ref_hash: [32]u8 = std.mem.zeroes([32]u8);
        if (inp.array[0] == .bytes and inp.array[0].bytes.len == 32) {
            @memcpy(&ref_hash, inp.array[0].bytes);
        }
        out.append(.{ .tx_hash = ref_hash, .index = @intCast(inp.array[1].u64) }) catch continue;
    }

    return out.toOwnedSlice() catch null;
}

/// Vkey witness signature precheck.
/// Verifies Ed25519 signatures in vkey witnesses (witness map key 0) over blake2b256(tx_body).
/// Does NOT verify witness coverage (that the correct keys signed).
/// Does NOT verify bootstrap (Byron) witnesses.
/// Returns: null = no vkeys or parse inconclusive, true = all verified, false = at least one failed.
pub fn verifyVkeyWitnesses(tx_bytes: []const u8) ?bool {
    const parts = block_hash_mod.decomposeTx(tx_bytes) orelse return null;

    // Compute tx body hash (the message that vkeys sign)
    var body_hash: [32]u8 = undefined;
    Blake2b256.hash(parts.tx_body, &body_hash, .{});

    // Decode witnesses CBOR to get vkey witness array (key 0)
    const wit_hdr = block_hash_mod.readCborHdr(parts.witnesses) orelse return null;
    if (wit_hdr.major != 5) return null; // must be a map
    // Walk the map to find key 0
    var pos: usize = wit_hdr.hdr_len;
    var found_vkeys: bool = false;
    var vkey_start: usize = 0;
    var vkey_count: u64 = 0;
    var i: u64 = 0;
    while (i < wit_hdr.value and pos < parts.witnesses.len) : (i += 1) {
        // Read key
        const k_hdr = block_hash_mod.readCborHdr(parts.witnesses[pos..]) orelse return null;
        const k_val = if (k_hdr.major == 0 and k_hdr.value < 256) k_hdr.value else 999;
        pos += block_hash_mod.skipCborElement(parts.witnesses[pos..]) orelse return null;
        // Read value
        if (k_val == 0) {
            // Found vkey witnesses — should be an array
            const v_hdr = block_hash_mod.readCborHdr(parts.witnesses[pos..]) orelse return null;
            if (v_hdr.major == 4) {
                found_vkeys = true;
                vkey_start = pos + v_hdr.hdr_len;
                vkey_count = v_hdr.value;
            }
        }
        pos += block_hash_mod.skipCborElement(parts.witnesses[pos..]) orelse return null;
    }

    if (!found_vkeys or vkey_count == 0) return null;

    // Verify each vkey witness: [vkey_bytes(32), sig_bytes(64)]
    var wpos = vkey_start;
    var verified: u32 = 0;
    var j: u64 = 0;
    while (j < vkey_count and wpos < parts.witnesses.len) : (j += 1) {
        // Each witness is a 2-element array
        const w_hdr = block_hash_mod.readCborHdr(parts.witnesses[wpos..]) orelse return null;
        if (w_hdr.major != 4 or w_hdr.value != 2) {
            wpos += block_hash_mod.skipCborElement(parts.witnesses[wpos..]) orelse return null;
            continue;
        }
        const inner_start = wpos + w_hdr.hdr_len;

        // vkey: bytes(32)
        const vk_hdr = block_hash_mod.readCborHdr(parts.witnesses[inner_start..]) orelse return null;
        if (vk_hdr.major != 2 or vk_hdr.value != 32) {
            wpos += block_hash_mod.skipCborElement(parts.witnesses[wpos..]) orelse return null;
            continue;
        }
        const vk_start = inner_start + vk_hdr.hdr_len;
        if (vk_start + 32 > parts.witnesses.len) return null;
        const vkey = parts.witnesses[vk_start..][0..32];

        // sig: bytes(64)
        const sig_pos = vk_start + 32;
        const s_hdr = block_hash_mod.readCborHdr(parts.witnesses[sig_pos..]) orelse return null;
        if (s_hdr.major != 2 or s_hdr.value != 64) {
            wpos += block_hash_mod.skipCborElement(parts.witnesses[wpos..]) orelse return null;
            continue;
        }
        const sig_start = sig_pos + s_hdr.hdr_len;
        if (sig_start + 64 > parts.witnesses.len) return null;
        const sig_bytes = parts.witnesses[sig_start..][0..64];

        // Verify Ed25519
        const pk = Ed25519.PublicKey.fromBytes(vkey.*) catch return false;
        const sig = Ed25519.Signature.fromBytes(sig_bytes.*);
        sig.verify(&body_hash, pk) catch return false;

        verified += 1;
        wpos += block_hash_mod.skipCborElement(parts.witnesses[wpos..]) orelse return null;
    }

    if (verified == 0) return null;
    return true;
}

const Ed25519 = std.crypto.sign.Ed25519;
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;
const block_hash_mod = @import("block_hash.zig");

/// Payment keyhash witness coverage precheck.
/// For each consumed input with a key-controlled address (types 0,2,4,6),
/// verifies that blake2b224(vkey) matches the payment keyhash for at least one vkey witness.
/// Skips script-payment addresses (types 1,3,5,7).
/// Does NOT validate bootstrap witnesses, multisig thresholds, or script authorization.
/// Returns: null = no key inputs or parse inconclusive, true = all covered, false = gap found.
pub fn checkWitnessCoverage(
    alloc: std.mem.Allocator,
    tx_bytes: []const u8,
    keyhash_fn: ?*const fn ([32]u8, u32) ?[28]u8,
) ?bool {
    const lookup = keyhash_fn orelse return null;

    // Parse inputs from tx
    const inputs = extractTxInputsFromBytes(alloc, tx_bytes) orelse return null;
    defer alloc.free(inputs);
    if (inputs.len == 0) return null;

    // Parse vkey witnesses and compute keyhashes
    const parts = block_hash_mod.decomposeTx(tx_bytes) orelse return null;
    const wit_hdr = block_hash_mod.readCborHdr(parts.witnesses) orelse return null;
    if (wit_hdr.major != 5) return null;

    // Collect vkey keyhashes (blake2b224 of each vkey)
    const MAX_VKEYS: usize = 32;
    var vkey_hashes: [MAX_VKEYS][28]u8 = undefined;
    var vkey_count: usize = 0;

    var pos: usize = wit_hdr.hdr_len;
    var mi: u64 = 0;
    while (mi < wit_hdr.value and pos < parts.witnesses.len) : (mi += 1) {
        const k_hdr = block_hash_mod.readCborHdr(parts.witnesses[pos..]) orelse break;
        const k_val = if (k_hdr.major == 0 and k_hdr.value < 256) k_hdr.value else 999;
        pos += block_hash_mod.skipCborElement(parts.witnesses[pos..]) orelse break;

        if (k_val == 0) {
            // Vkey witnesses array
            const v_hdr = block_hash_mod.readCborHdr(parts.witnesses[pos..]) orelse break;
            if (v_hdr.major == 4) {
                var wpos = pos + v_hdr.hdr_len;
                var wi: u64 = 0;
                while (wi < v_hdr.value and wpos < parts.witnesses.len and vkey_count < MAX_VKEYS) : (wi += 1) {
                    const w_hdr = block_hash_mod.readCborHdr(parts.witnesses[wpos..]) orelse break;
                    if (w_hdr.major == 4 and w_hdr.value == 2) {
                        const inner = wpos + w_hdr.hdr_len;
                        const vk_hdr = block_hash_mod.readCborHdr(parts.witnesses[inner..]) orelse break;
                        if (vk_hdr.major == 2 and vk_hdr.value == 32) {
                            const vk_start = inner + vk_hdr.hdr_len;
                            if (vk_start + 32 <= parts.witnesses.len) {
                                const Blake2b224 = std.crypto.hash.blake2.Blake2b(224);
                                Blake2b224.hash(parts.witnesses[vk_start..][0..32], &vkey_hashes[vkey_count], .{});
                                vkey_count += 1;
                            }
                        }
                    }
                    wpos += block_hash_mod.skipCborElement(parts.witnesses[wpos..]) orelse break;
                }
            }
        }
        pos += block_hash_mod.skipCborElement(parts.witnesses[pos..]) orelse break;
    }

    if (vkey_count == 0) return null;

    // Check coverage: each key-controlled input must have a matching keyhash
    var key_inputs: u32 = 0;
    for (inputs) |inp| {
        const required_kh = lookup(inp.tx_hash, inp.index) orelse continue; // null = script or unavailable
        key_inputs += 1;

        var found = false;
        for (vkey_hashes[0..vkey_count]) |vkh| {
            if (std.mem.eql(u8, &vkh, &required_kh)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }

    if (key_inputs == 0) return null;
    return true;
}

/// Native script evaluator with full RequireSignature support.
/// All 6 native script types evaluated: RequireSignature, RequireAllOf,
/// RequireAnyOf, RequireMOf, TimelockStart, TimelockExpiry.
/// Returns: null = inconclusive/unsupported, true = satisfied, false = not satisfied.

const MAX_SCRIPT_DEPTH: u8 = 8;

const VkeyHashSet = struct {
    hashes: [32][28]u8 = undefined,
    count: usize = 0,

    fn contains(self: *const VkeyHashSet, kh: []const u8) bool {
        for (self.hashes[0..self.count]) |h| {
            if (std.mem.eql(u8, &h, kh)) return true;
        }
        return false;
    }
};

fn evaluateNativeScript(script: cbor.Term, current_slot: u64, vkeys: *const VkeyHashSet, depth: u8) ?bool {
    if (depth > MAX_SCRIPT_DEPTH) return null;
    if (script != .array or script.array.len < 2) return null;
    if (script.array[0] != .u64) return null;

    return switch (script.array[0].u64) {
        0 => blk: {
            // RequireSignature [0, keyhash(28)]: true if keyhash in vkey witness set
            if (script.array[1] != .bytes or script.array[1].bytes.len != 28) break :blk null;
            break :blk vkeys.contains(script.array[1].bytes[0..28]);
        },
        1 => blk: {
            const children = if (script.array[1] == .array) script.array[1].array else break :blk null;
            var has_null = false;
            for (children) |child| {
                const r = evaluateNativeScript(child, current_slot, vkeys, depth + 1);
                if (r != null and r.? == false) break :blk false;
                if (r == null) has_null = true;
            }
            break :blk if (has_null) null else true;
        },
        2 => blk: {
            const children = if (script.array[1] == .array) script.array[1].array else break :blk null;
            var has_null = false;
            for (children) |child| {
                const r = evaluateNativeScript(child, current_slot, vkeys, depth + 1);
                if (r != null and r.? == true) break :blk true;
                if (r == null) has_null = true;
            }
            break :blk if (has_null) null else false;
        },
        3 => blk: {
            if (script.array.len < 3) break :blk null;
            const m = if (script.array[1] == .u64) script.array[1].u64 else break :blk null;
            const children = if (script.array[2] == .array) script.array[2].array else break :blk null;
            var true_count: u64 = 0;
            var null_count: u64 = 0;
            for (children) |child| {
                const r = evaluateNativeScript(child, current_slot, vkeys, depth + 1);
                if (r != null and r.? == true) { true_count += 1; }
                else if (r == null) { null_count += 1; }
            }
            if (true_count >= m) break :blk true;
            if (true_count + null_count < m) break :blk false;
            break :blk null;
        },
        4 => blk: {
            const slot = if (script.array[1] == .u64) script.array[1].u64 else break :blk null;
            break :blk current_slot >= slot;
        },
        5 => blk: {
            const slot = if (script.array[1] == .u64) script.array[1].u64 else break :blk null;
            break :blk current_slot <= slot;
        },
        else => null,
    };
}

/// Evaluate all native scripts in the tx witness section.
/// Builds vkey keyhash set from witness key 0, evaluates each native script
/// with full RequireSignature support.
/// Returns: null = no native scripts or inconclusive, true = all satisfied,
///          false = at least one script not satisfied.
pub fn evaluateWitnessNativeScripts(alloc: std.mem.Allocator, tx_bytes: []const u8, current_slot: u64) ?bool {
    var fbs = compat.fixedBufferStream(tx_bytes);
    const term = cbor.decode(alloc, fbs.reader()) catch return null;
    defer cbor.free(term, alloc);

    const witnesses: cbor.Term = if (term == .array and term.array.len >= 2)
        term.array[1]
    else if (term == .map_u64)
        (findMapKey(term.map_u64, 1) orelse return null)
    else
        return null;

    if (witnesses != .map_u64) return null;

    // Build vkey keyhash set from witness key 0
    var vkeys = VkeyHashSet{};
    if (findMapKey(witnesses.map_u64, 0)) |vkey_term| {
        if (vkey_term == .array) {
            for (vkey_term.array) |wit| {
                if (vkeys.count >= 32) break;
                if (wit != .array or wit.array.len < 1) continue;
                if (wit.array[0] != .bytes or wit.array[0].bytes.len != 32) continue;
                const Blake2b224 = std.crypto.hash.blake2.Blake2b(224);
                Blake2b224.hash(wit.array[0].bytes[0..32], &vkeys.hashes[vkeys.count], .{});
                vkeys.count += 1;
            }
        }
    }

    // Get native scripts from witness key 1
    const scripts_term: cbor.Term = findMapKey(witnesses.map_u64, 1) orelse return null;
    const scripts = if (scripts_term == .array) scripts_term.array else return null;
    if (scripts.len == 0) return null;

    var any_evaluated = false;
    for (scripts) |script| {
        const result = evaluateNativeScript(script, current_slot, &vkeys, 0);
        if (result != null) {
            any_evaluated = true;
            if (result.? == false) return false;
        }
    }

    return if (any_evaluated) true else null;
}

/// Extract total output lovelace and fee from raw tx CBOR bytes.
/// Used by mempool admission for balance validation.
pub const OutputFeeResult = struct { output_total: u64, fee: u64 };

pub fn extractOutputTotalAndFee(alloc: std.mem.Allocator, tx_bytes: []const u8) ?OutputFeeResult {
    // Decode tx: [body, witnesses, ...] or {0: body, 1: witnesses, ...}
    var fbs = compat.fixedBufferStream(tx_bytes);
    const term = cbor.decode(alloc, fbs.reader()) catch return null;
    defer cbor.free(term, alloc);

    // Extract tx body
    const body: cbor.Term = if (term == .array and term.array.len >= 1) blk: {
        const b = term.array[0];
        if (b == .map_u64) break :blk b;
        if (b == .bytes and b.bytes.len > 50) {
            var inner_fbs = compat.fixedBufferStream(b.bytes);
            const inner = cbor.decode(alloc, inner_fbs.reader()) catch break :blk b;
            if (inner == .map_u64) break :blk inner;
            break :blk b;
        }
        break :blk b;
    } else if (term == .map_u64)
        term
    else
        return null;

    if (body != .map_u64) return null;

    // Fee: key 2
    const fee: u64 = if (findMapKey(body.map_u64, 2)) |f| (if (f == .u64) f.u64 else 0) else 0;

    // Outputs: key 1
    const outputs_term = findMapKey(body.map_u64, 1) orelse return OutputFeeResult{ .output_total = 0, .fee = fee };
    const outputs_array = if (outputs_term == .array) outputs_term.array else if (outputs_term == .tag and outputs_term.tag.value.* == .array) outputs_term.tag.value.*.array else return OutputFeeResult{ .output_total = 0, .fee = fee };

    var total: u64 = 0;
    for (outputs_array) |o| {
        if (o == .array and o.array.len >= 2) {
            total +|= extractLovelace(o.array[1]);
        } else if (o == .map_u64) {
            if (findMapValue(o.map_u64, 1)) |val| total +|= extractLovelace(val);
        }
    }

    return OutputFeeResult{ .output_total = total, .fee = fee };
}

/// Extract validity interval (TTL and validity_start) from raw tx CBOR bytes.
pub const ValidityInterval = struct { ttl: ?u64, validity_start: ?u64 };

pub fn extractValidityInterval(alloc: std.mem.Allocator, tx_bytes: []const u8) ?ValidityInterval {
    var fbs = compat.fixedBufferStream(tx_bytes);
    const term = cbor.decode(alloc, fbs.reader()) catch return null;
    defer cbor.free(term, alloc);

    const body: cbor.Term = if (term == .array and term.array.len >= 1) blk: {
        const b = term.array[0];
        if (b == .map_u64) break :blk b;
        if (b == .bytes and b.bytes.len > 50) {
            var inner_fbs = compat.fixedBufferStream(b.bytes);
            const inner = cbor.decode(alloc, inner_fbs.reader()) catch break :blk b;
            if (inner == .map_u64) break :blk inner;
            break :blk b;
        }
        break :blk b;
    } else if (term == .map_u64) term else return null;

    if (body != .map_u64) return null;

    const ttl: ?u64 = if (findMapKey(body.map_u64, 3)) |t| (if (t == .u64) t.u64 else null) else null;
    const vs: ?u64 = if (findMapKey(body.map_u64, 8)) |t| (if (t == .u64) t.u64 else null) else null;

    return .{ .ttl = ttl, .validity_start = vs };
}

/// Per-output size info for min-ADA calculation.
pub const OutputSizeInfo = struct { lovelace: u64, cbor_size: u64 };

/// Extract per-output lovelace + exact CBOR byte size from raw tx bytes.
/// Uses the original CBOR byte stream to measure each output's serialized size
/// precisely — no approximation, no re-serialization.
pub fn extractOutputSizeInfo(alloc: std.mem.Allocator, tx_bytes: []const u8) ?[]OutputSizeInfo {
    const parts = block_hash_mod.decomposeTx(tx_bytes) orelse return null;
    const body = parts.tx_body;

    // Navigate raw CBOR body map to find key 1 (outputs)
    const body_hdr = block_hash_mod.readCborHdr(body) orelse return null;
    if (body_hdr.major != 5) return null; // must be a map

    var pos: usize = body_hdr.hdr_len;
    var outputs_pos: ?usize = null;

    var mi: u64 = 0;
    while (mi < body_hdr.value and pos < body.len) : (mi += 1) {
        // Read key
        const k_hdr = block_hash_mod.readCborHdr(body[pos..]) orelse break;
        const k_val = if (k_hdr.major == 0 and k_hdr.value < 256) k_hdr.value else 999;
        pos += block_hash_mod.skipCborElement(body[pos..]) orelse break;
        // If key == 1, record the value position
        if (k_val == 1) {
            outputs_pos = pos;
        }
        pos += block_hash_mod.skipCborElement(body[pos..]) orelse break;
    }

    const out_start = outputs_pos orelse return null;
    const out_hdr = block_hash_mod.readCborHdr(body[out_start..]) orelse return null;
    if (out_hdr.major != 4) return null; // outputs must be array

    // Also decode via Term for lovelace extraction (reuse existing logic)
    var fbs = compat.fixedBufferStream(tx_bytes);
    const term_v = cbor.decode(alloc, fbs.reader()) catch return null;
    defer cbor.free(term_v, alloc);

    const body_term: cbor.Term = if (term_v == .array and term_v.array.len >= 1) blk: {
        const b = term_v.array[0];
        if (b == .map_u64) break :blk b;
        if (b == .bytes and b.bytes.len > 50) {
            var inner_fbs = compat.fixedBufferStream(b.bytes);
            const inner = cbor.decode(alloc, inner_fbs.reader()) catch break :blk b;
            if (inner == .map_u64) break :blk inner;
            break :blk b;
        }
        break :blk b;
    } else if (term_v == .map_u64) term_v else return null;

    if (body_term != .map_u64) return null;
    const outputs_term = findMapKey(body_term.map_u64, 1) orelse return null;
    const outputs_array = if (outputs_term == .array) outputs_term.array
        else if (outputs_term == .tag and outputs_term.tag.value.* == .array) outputs_term.tag.value.*.array
        else return null;

    // Measure each output's exact CBOR byte size from raw body
    var list = std.array_list.Managed(OutputSizeInfo).init(alloc);
    var elem_pos: usize = out_start + out_hdr.hdr_len;

    for (outputs_array, 0..) |o, idx| {
        _ = idx;
        // Exact CBOR size from raw bytes
        const elem_size = block_hash_mod.skipCborElement(body[elem_pos..]) orelse break;

        // Lovelace from decoded Term
        var lv: u64 = 0;
        if (o == .array and o.array.len >= 2) {
            lv = extractLovelace(o.array[1]);
        } else if (o == .map_u64) {
            if (findMapValue(o.map_u64, 1)) |v| lv = extractLovelace(v);
        }

        list.append(.{ .lovelace = lv, .cbor_size = elem_size }) catch continue;
        elem_pos += elem_size;
    }

    return list.toOwnedSlice() catch null;
}

/// Extract per-output lovelace values from raw tx CBOR bytes.
/// Returns a caller-owned slice of u64 lovelace values, one per output.
/// Classification of a transaction's script involvement.
/// Used to determine whether Plutus execution would be required.
pub const TxScriptClassification = struct {
    // Body indicators
    has_script_data_hash: bool = false, // key 11: definitive Plutus indicator
    has_collateral: bool = false, // key 13: collateral inputs
    has_collateral_return: bool = false, // key 16: collateral return output
    has_total_collateral: bool = false, // key 17: total collateral amount
    has_reference_inputs: bool = false, // key 18: reference inputs (Babbage+)
    collateral_count: u32 = 0, // number of collateral inputs
    reference_input_count: u32 = 0, // number of reference inputs
    // Witness indicators + counts
    has_native_scripts: bool = false, // key 1
    has_plutus_v1: bool = false, // key 3
    has_plutus_data: bool = false, // key 4: datums
    has_redeemers: bool = false, // key 5: redeemers
    has_plutus_v2: bool = false, // key 6
    has_plutus_v3: bool = false, // key 7
    plutus_v1_count: u32 = 0,
    plutus_v2_count: u32 = 0,
    plutus_v3_count: u32 = 0,
    redeemer_count: u32 = 0,
    datum_count: u32 = 0,
    /// True only when script_data_hash is present.
    requires_plutus_definitive: bool = false,
    /// 0=not_applicable, 1=partial, 2=missing_redeemers,
    /// 3=missing_scripts, 4=evaluator_absent
    plutus_readiness: u8 = 0,

    /// Structured summary of what a Plutus evaluator would need.
    /// This is informational only — TSUNAGI does not execute Plutus.
    pub fn executionSummary(self: *const TxScriptClassification) ExecutionSkeleton {
        return .{
            .requires_plutus = self.requires_plutus_definitive,
            .script_versions_present = @as(u8, if (self.has_plutus_v1) 1 else 0) |
                @as(u8, if (self.has_plutus_v2) 2 else 0) |
                @as(u8, if (self.has_plutus_v3) 4 else 0),
            .total_scripts = self.plutus_v1_count + self.plutus_v2_count + self.plutus_v3_count,
            .total_redeemers = self.redeemer_count,
            .total_datums = self.datum_count,
            .has_collateral = self.has_collateral,
            .has_reference_inputs = self.has_reference_inputs,
            .readiness = self.plutus_readiness,
            .missing_evaluator = self.plutus_readiness == 4,
            .missing_cost_model = true, // TSUNAGI does not load cost models yet
        };
    }
};

/// Informational skeleton of what Plutus execution would require.
/// TSUNAGI does not execute Plutus — this describes the gap precisely.
pub const ExecutionSkeleton = struct {
    requires_plutus: bool,
    script_versions_present: u8, // bitmask: 1=V1, 2=V2, 4=V3
    total_scripts: u32,
    total_redeemers: u32,
    total_datums: u32,
    has_collateral: bool,
    has_reference_inputs: bool,
    readiness: u8, // 0-4 from classification
    missing_evaluator: bool, // always true until UPLC is implemented
    missing_cost_model: bool, // always true until cost models are loaded
};

/// Classify a transaction's script involvement from raw CBOR.
/// Checks body keys 11/13/16/17/18 and witness keys 1/3/4/5/6/7.
/// Populates boolean flags and element counts for Plutus execution skeleton.
/// Returns null if parse fails.
pub fn classifyTxScripts(tx_bytes: []const u8) ?TxScriptClassification {
    const parts = block_hash_mod.decomposeTx(tx_bytes) orelse return null;
    var c = TxScriptClassification{};

    // Scan body map for keys 11 and 13
    const body_hdr = block_hash_mod.readCborHdr(parts.tx_body) orelse return null;
    if (body_hdr.major == 5) {
        var pos: usize = body_hdr.hdr_len;
        var i: u64 = 0;
        while (i < body_hdr.value and pos < parts.tx_body.len) : (i += 1) {
            const k_hdr = block_hash_mod.readCborHdr(parts.tx_body[pos..]) orelse break;
            const k_val = if (k_hdr.major == 0 and k_hdr.value < 256) k_hdr.value else 999;
            pos += block_hash_mod.skipCborElement(parts.tx_body[pos..]) orelse break;
            if (k_val == 11) c.has_script_data_hash = true;
            if (k_val == 13) {
                c.has_collateral = true;
                const val_hdr = block_hash_mod.readCborHdr(parts.tx_body[pos..]);
                if (val_hdr) |vh| { if (vh.major == 4) c.collateral_count = @intCast(vh.value); }
            }
            if (k_val == 16) c.has_collateral_return = true;
            if (k_val == 17) c.has_total_collateral = true;
            if (k_val == 18) {
                c.has_reference_inputs = true;
                const val_hdr = block_hash_mod.readCborHdr(parts.tx_body[pos..]);
                if (val_hdr) |vh| { if (vh.major == 4) c.reference_input_count = @intCast(vh.value); }
            }
            pos += block_hash_mod.skipCborElement(parts.tx_body[pos..]) orelse break;
        }
    }

    // Scan witness map for keys 1, 3, 6, 7
    const wit_hdr = block_hash_mod.readCborHdr(parts.witnesses) orelse return c;
    if (wit_hdr.major == 5) {
        var pos: usize = wit_hdr.hdr_len;
        var i: u64 = 0;
        while (i < wit_hdr.value and pos < parts.witnesses.len) : (i += 1) {
            const k_hdr = block_hash_mod.readCborHdr(parts.witnesses[pos..]) orelse break;
            const k_val = if (k_hdr.major == 0 and k_hdr.value < 256) k_hdr.value else 999;
            pos += block_hash_mod.skipCborElement(parts.witnesses[pos..]) orelse break;
            if (k_val == 1) c.has_native_scripts = true;
            if (k_val == 3) {
                c.has_plutus_v1 = true;
                const vh = block_hash_mod.readCborHdr(parts.witnesses[pos..]);
                if (vh) |h| { if (h.major == 4) c.plutus_v1_count = @intCast(h.value); }
            }
            if (k_val == 4) {
                c.has_plutus_data = true;
                const vh = block_hash_mod.readCborHdr(parts.witnesses[pos..]);
                if (vh) |h| { if (h.major == 4) c.datum_count = @intCast(h.value); }
            }
            if (k_val == 5) {
                c.has_redeemers = true;
                const vh = block_hash_mod.readCborHdr(parts.witnesses[pos..]);
                if (vh) |h| {
                    if (h.major == 4) c.redeemer_count = @intCast(h.value); // array of redeemers
                    if (h.major == 5) c.redeemer_count = @intCast(h.value); // map of redeemers (Conway)
                }
            }
            if (k_val == 6) {
                c.has_plutus_v2 = true;
                const vh = block_hash_mod.readCborHdr(parts.witnesses[pos..]);
                if (vh) |h| { if (h.major == 4) c.plutus_v2_count = @intCast(h.value); }
            }
            if (k_val == 7) {
                c.has_plutus_v3 = true;
                const vh = block_hash_mod.readCborHdr(parts.witnesses[pos..]);
                if (vh) |h| { if (h.major == 4) c.plutus_v3_count = @intCast(h.value); }
            }
            pos += block_hash_mod.skipCborElement(parts.witnesses[pos..]) orelse break;
        }
    }

    // Definitive Plutus requirement: script_data_hash (key 11) is the canonical indicator.
    c.requires_plutus_definitive = c.has_script_data_hash;

    // Plutus readiness classification
    const has_any_plutus_script = c.has_plutus_v1 or c.has_plutus_v2 or c.has_plutus_v3;
    if (!c.requires_plutus_definitive) {
        c.plutus_readiness = 0; // not_applicable
    } else if (!has_any_plutus_script) {
        c.plutus_readiness = 3; // missing_scripts (script_data_hash present but no script witness)
    } else if (!c.has_redeemers) {
        c.plutus_readiness = 2; // missing_redeemers
    } else if (has_any_plutus_script and c.has_redeemers and c.has_collateral) {
        c.plutus_readiness = 4; // evaluator_absent (all prerequisites present, no engine)
    } else {
        c.plutus_readiness = 1; // has_scripts_and_redeemers (partial)
    }

    return c;
}

// ---------------------------------------------------------------------------
// Phase 15: Plutus Execution Context Builder
// Structures and extracts Plutus witness material into a deterministic,
// fixed-size context without executing Plutus.
// ---------------------------------------------------------------------------

/// Redeemer purpose tag per Cardano ledger spec.
pub const RedeemerTag = enum(u8) {
    spend = 0, // index → tx input index
    mint = 1, // index → policy position in mint map
    cert = 2, // index → certificate index
    reward = 3, // index → reward account index
    unknown = 255,

    pub fn fromU64(v: u64) RedeemerTag {
        return switch (v) {
            0 => .spend,
            1 => .mint,
            2 => .cert,
            3 => .reward,
            else => .unknown,
        };
    }
};

/// A single redeemer extracted from witness key 5.
pub const RedeemerEntry = struct {
    tag: RedeemerTag = .unknown,
    index: u32 = 0,
    ex_units_mem: u64 = 0,
    ex_units_steps: u64 = 0,
};

/// A single Plutus script witness (V1/V2/V3).
pub const ScriptEntry = struct {
    version: u8 = 0, // 1=V1, 2=V2, 3=V3
    body_offset: u32 = 0, // byte offset within witness slice
    body_len: u32 = 0, // byte length of script CBOR element
};

/// A consumed input reference (no allocator).
pub const InputRef = struct {
    tx_hash: [32]u8 = .{0} ** 32,
    index: u32 = 0,
};

/// Complete Plutus execution context — informational only.
/// TSUNAGI does not execute Plutus. This describes what an evaluator would receive.
pub const PlutusExecutionContext = struct {
    pub const MAX_INPUTS: u32 = 64;
    pub const MAX_COLLATERAL: u32 = 8;
    pub const MAX_REF_INPUTS: u32 = 8;
    pub const MAX_SCRIPTS: u32 = 16;
    pub const MAX_REDEEMERS: u32 = 32;

    // Consumed inputs (body key 0)
    input_count: u32 = 0,
    inputs: [MAX_INPUTS]InputRef = undefined,

    // Reference inputs (body key 18)
    ref_input_count: u32 = 0,
    ref_inputs: [MAX_REF_INPUTS]InputRef = undefined,

    // Collateral (body key 13)
    collateral_count: u32 = 0,
    collateral_inputs: [MAX_COLLATERAL]InputRef = undefined,

    // Collateral metadata (body keys 16/17)
    has_total_collateral: bool = false,
    total_collateral: u64 = 0,
    has_collateral_return: bool = false,

    // Scripts by version (witness keys 3/6/7)
    script_count: u32 = 0,
    scripts: [MAX_SCRIPTS]ScriptEntry = undefined,

    // Redeemers (witness key 5)
    redeemer_count: u32 = 0,
    redeemers: [MAX_REDEEMERS]RedeemerEntry = undefined,

    // Datums (witness key 4)
    datum_count: u32 = 0,

    // Mapping: how many spend-tagged redeemers have index < input_count
    spend_redeemers_mapped: u32 = 0,

    // Whether this tx requires Plutus at all (script_data_hash present)
    requires_plutus: bool = false,

    /// Fraction of redeemers that resolved to known targets.
    pub fn mappingCoverage(self: *const PlutusExecutionContext) f32 {
        if (self.redeemer_count == 0) return 0.0;
        return @as(f32, @floatFromInt(self.spend_redeemers_mapped)) /
            @as(f32, @floatFromInt(self.redeemer_count));
    }
};

/// Parse an array of input references [tx_hash, index] from CBOR into fixed-size buffer.
/// Returns the number of inputs parsed.
fn parseInputRefsRaw(body: []const u8, arr_start: usize, buf: []InputRef, max: u32) u32 {
    const arr_hdr = block_hash_mod.readCborHdr(body[arr_start..]) orelse return 0;
    if (arr_hdr.major != 4) return 0;
    var count: u32 = 0;
    var pos: usize = arr_start + arr_hdr.hdr_len;
    var elem: u64 = 0;
    while (elem < arr_hdr.value and pos < body.len and count < max) : (elem += 1) {
        // Each input is a 2-element array: [hash(bstr32), index(uint)]
        const inp_hdr = block_hash_mod.readCborHdr(body[pos..]) orelse break;
        if (inp_hdr.major != 4 or inp_hdr.value < 2) {
            pos += block_hash_mod.skipCborElement(body[pos..]) orelse break;
            continue;
        }
        const inner_start = pos + inp_hdr.hdr_len;
        // Read hash (bstr)
        const hash_hdr = block_hash_mod.readCborHdr(body[inner_start..]) orelse break;
        if (hash_hdr.major != 2 or hash_hdr.value != 32) {
            pos += block_hash_mod.skipCborElement(body[pos..]) orelse break;
            continue;
        }
        const hash_data_start = inner_start + hash_hdr.hdr_len;
        if (hash_data_start + 32 > body.len) break;
        var ref: InputRef = .{};
        @memcpy(&ref.tx_hash, body[hash_data_start..][0..32]);
        // Read index (uint)
        const idx_pos = hash_data_start + 32;
        const idx_hdr = block_hash_mod.readCborHdr(body[idx_pos..]) orelse break;
        if (idx_hdr.major != 0) {
            pos += block_hash_mod.skipCborElement(body[pos..]) orelse break;
            continue;
        }
        ref.index = @intCast(idx_hdr.value);
        buf[count] = ref;
        count += 1;
        pos += block_hash_mod.skipCborElement(body[pos..]) orelse break;
    }
    return count;
}

/// Parse redeemers from witness key 5.
/// Pre-Conway: array of 4-tuples [tag, index, data, ex_units]
/// Conway+: map of [tag, index] → [data, ex_units]
fn parseRedeemersRaw(wit: []const u8, val_start: usize, buf: []RedeemerEntry, max: u32) u32 {
    const hdr = block_hash_mod.readCborHdr(wit[val_start..]) orelse return 0;
    var count: u32 = 0;

    if (hdr.major == 4) {
        // Array of 4-tuples: [tag, index, data, ex_units]
        var pos: usize = val_start + hdr.hdr_len;
        var elem: u64 = 0;
        while (elem < hdr.value and pos < wit.len and count < max) : (elem += 1) {
            const t_hdr = block_hash_mod.readCborHdr(wit[pos..]) orelse break;
            if (t_hdr.major != 4 or t_hdr.value < 4) {
                pos += block_hash_mod.skipCborElement(wit[pos..]) orelse break;
                continue;
            }
            const inner = pos + t_hdr.hdr_len;
            // tag (uint)
            const tag_h = block_hash_mod.readCborHdr(wit[inner..]) orelse break;
            const tag_val = if (tag_h.major == 0) tag_h.value else 255;
            const after_tag = inner + tag_h.hdr_len;
            // index (uint)
            const idx_h = block_hash_mod.readCborHdr(wit[after_tag..]) orelse break;
            const idx_val = if (idx_h.major == 0) idx_h.value else 0;
            const after_idx = after_tag + idx_h.hdr_len;
            // skip data
            const data_skip = block_hash_mod.skipCborElement(wit[after_idx..]) orelse break;
            const exu_pos = after_idx + data_skip;
            // ex_units: [mem, steps]
            var mem: u64 = 0;
            var steps: u64 = 0;
            const exu_hdr = block_hash_mod.readCborHdr(wit[exu_pos..]) orelse break;
            if (exu_hdr.major == 4 and exu_hdr.value >= 2) {
                const m_pos = exu_pos + exu_hdr.hdr_len;
                const m_h = block_hash_mod.readCborHdr(wit[m_pos..]) orelse break;
                if (m_h.major == 0) mem = m_h.value;
                const s_pos = m_pos + m_h.hdr_len;
                const s_h = block_hash_mod.readCborHdr(wit[s_pos..]) orelse break;
                if (s_h.major == 0) steps = s_h.value;
            }
            buf[count] = .{
                .tag = RedeemerTag.fromU64(tag_val),
                .index = @intCast(idx_val),
                .ex_units_mem = mem,
                .ex_units_steps = steps,
            };
            count += 1;
            pos += block_hash_mod.skipCborElement(wit[pos..]) orelse break;
        }
    } else if (hdr.major == 5) {
        // Map: [tag, index] → [data, ex_units] (Conway encoding)
        var pos: usize = val_start + hdr.hdr_len;
        var elem: u64 = 0;
        while (elem < hdr.value and pos < wit.len and count < max) : (elem += 1) {
            // Key: 2-element array [tag, index]
            const k_hdr = block_hash_mod.readCborHdr(wit[pos..]) orelse break;
            if (k_hdr.major != 4 or k_hdr.value < 2) {
                pos += block_hash_mod.skipCborElement(wit[pos..]) orelse break;
                pos += block_hash_mod.skipCborElement(wit[pos..]) orelse break;
                continue;
            }
            const k_inner = pos + k_hdr.hdr_len;
            const tag_h = block_hash_mod.readCborHdr(wit[k_inner..]) orelse break;
            const tag_val = if (tag_h.major == 0) tag_h.value else 255;
            const idx_pos = k_inner + tag_h.hdr_len;
            const idx_h = block_hash_mod.readCborHdr(wit[idx_pos..]) orelse break;
            const idx_val = if (idx_h.major == 0) idx_h.value else 0;
            pos += block_hash_mod.skipCborElement(wit[pos..]) orelse break; // skip key

            // Value: 2-element array [data, ex_units]
            const v_hdr = block_hash_mod.readCborHdr(wit[pos..]) orelse break;
            var mem: u64 = 0;
            var steps: u64 = 0;
            if (v_hdr.major == 4 and v_hdr.value >= 2) {
                const v_inner = pos + v_hdr.hdr_len;
                const data_skip = block_hash_mod.skipCborElement(wit[v_inner..]) orelse break;
                const exu_pos = v_inner + data_skip;
                const exu_hdr = block_hash_mod.readCborHdr(wit[exu_pos..]) orelse break;
                if (exu_hdr.major == 4 and exu_hdr.value >= 2) {
                    const m_pos = exu_pos + exu_hdr.hdr_len;
                    const m_h = block_hash_mod.readCborHdr(wit[m_pos..]) orelse break;
                    if (m_h.major == 0) mem = m_h.value;
                    const s_pos = m_pos + m_h.hdr_len;
                    const s_h = block_hash_mod.readCborHdr(wit[s_pos..]) orelse break;
                    if (s_h.major == 0) steps = s_h.value;
                }
            }
            buf[count] = .{
                .tag = RedeemerTag.fromU64(tag_val),
                .index = @intCast(idx_val),
                .ex_units_mem = mem,
                .ex_units_steps = steps,
            };
            count += 1;
            pos += block_hash_mod.skipCborElement(wit[pos..]) orelse break; // skip value
        }
    }
    return count;
}

/// Build a complete Plutus execution context from raw CBOR transaction bytes.
/// Returns null on parse failure. Informational only — no Plutus execution.
pub fn buildPlutusContext(tx_bytes: []const u8) ?PlutusExecutionContext {
    const parts = block_hash_mod.decomposeTx(tx_bytes) orelse return null;
    var ctx = PlutusExecutionContext{};

    // --- Body scan ---
    const body_hdr = block_hash_mod.readCborHdr(parts.tx_body) orelse return null;
    if (body_hdr.major != 5) return null;

    var pos: usize = body_hdr.hdr_len;
    var i: u64 = 0;
    while (i < body_hdr.value and pos < parts.tx_body.len) : (i += 1) {
        const k_hdr = block_hash_mod.readCborHdr(parts.tx_body[pos..]) orelse break;
        const k_val = if (k_hdr.major == 0 and k_hdr.value < 256) k_hdr.value else 999;
        pos += block_hash_mod.skipCborElement(parts.tx_body[pos..]) orelse break;

        // key 0: inputs
        if (k_val == 0) {
            ctx.input_count = parseInputRefsRaw(parts.tx_body, pos, &ctx.inputs, PlutusExecutionContext.MAX_INPUTS);
        }
        // key 11: script_data_hash → Plutus required
        if (k_val == 11) ctx.requires_plutus = true;
        // key 13: collateral inputs
        if (k_val == 13) {
            ctx.collateral_count = parseInputRefsRaw(parts.tx_body, pos, &ctx.collateral_inputs, PlutusExecutionContext.MAX_COLLATERAL);
        }
        // key 16: collateral return
        if (k_val == 16) ctx.has_collateral_return = true;
        // key 17: total collateral (uint)
        if (k_val == 17) {
            const tc_hdr = block_hash_mod.readCborHdr(parts.tx_body[pos..]);
            if (tc_hdr) |h| {
                if (h.major == 0) {
                    ctx.has_total_collateral = true;
                    ctx.total_collateral = h.value;
                }
            }
        }
        // key 18: reference inputs
        if (k_val == 18) {
            ctx.ref_input_count = parseInputRefsRaw(parts.tx_body, pos, &ctx.ref_inputs, PlutusExecutionContext.MAX_REF_INPUTS);
        }

        pos += block_hash_mod.skipCborElement(parts.tx_body[pos..]) orelse break;
    }

    // --- Witness scan ---
    const wit_hdr = block_hash_mod.readCborHdr(parts.witnesses) orelse return ctx;
    if (wit_hdr.major != 5) return ctx;

    pos = wit_hdr.hdr_len;
    i = 0;
    while (i < wit_hdr.value and pos < parts.witnesses.len) : (i += 1) {
        const k_hdr = block_hash_mod.readCborHdr(parts.witnesses[pos..]) orelse break;
        const k_val = if (k_hdr.major == 0 and k_hdr.value < 256) k_hdr.value else 999;
        pos += block_hash_mod.skipCborElement(parts.witnesses[pos..]) orelse break;

        // key 3: Plutus V1 scripts, key 6: V2, key 7: V3
        if (k_val == 3 or k_val == 6 or k_val == 7) {
            const version: u8 = if (k_val == 3) 1 else if (k_val == 6) 2 else 3;
            const arr_hdr = block_hash_mod.readCborHdr(parts.witnesses[pos..]);
            if (arr_hdr) |ah| {
                if (ah.major == 4) {
                    var spos: usize = pos + ah.hdr_len;
                    var se: u64 = 0;
                    while (se < ah.value and spos < parts.witnesses.len and ctx.script_count < PlutusExecutionContext.MAX_SCRIPTS) : (se += 1) {
                        const elem_size = block_hash_mod.skipCborElement(parts.witnesses[spos..]) orelse break;
                        ctx.scripts[ctx.script_count] = .{
                            .version = version,
                            .body_offset = @intCast(spos),
                            .body_len = @intCast(elem_size),
                        };
                        ctx.script_count += 1;
                        spos += elem_size;
                    }
                }
            }
        }

        // key 4: datums
        if (k_val == 4) {
            const d_hdr = block_hash_mod.readCborHdr(parts.witnesses[pos..]);
            if (d_hdr) |h| {
                if (h.major == 4) ctx.datum_count = @intCast(h.value);
            }
        }

        // key 5: redeemers
        if (k_val == 5) {
            ctx.redeemer_count = parseRedeemersRaw(parts.witnesses, pos, &ctx.redeemers, PlutusExecutionContext.MAX_REDEEMERS);
        }

        pos += block_hash_mod.skipCborElement(parts.witnesses[pos..]) orelse break;
    }

    // --- Cross-reference: spend redeemer → input mapping ---
    var mapped: u32 = 0;
    for (0..ctx.redeemer_count) |ri| {
        if (ctx.redeemers[ri].tag == .spend and ctx.redeemers[ri].index < ctx.input_count) {
            mapped += 1;
        }
    }
    ctx.spend_redeemers_mapped = mapped;

    return ctx;
}

// ---------------------------------------------------------------------------
// Phase 16: Plutus Evaluator Interface
// Defines the contract between TSUNAGI and a future Plutus evaluator.
// Stub only — TSUNAGI does not execute Plutus.
// ---------------------------------------------------------------------------

/// Error codes returned by the Plutus evaluator interface.
pub const EvalErrorCode = enum(u8) {
    none = 0,
    evaluator_not_implemented = 1,
    missing_context = 2,
    invalid_redeemer = 3,
    script_failed = 4,
    backend_unavailable = 5,
    backend_invalid_response = 6,
};

/// Result of a Plutus evaluation attempt.
pub const ExecutionResult = struct {
    success: bool = false,
    error_code: EvalErrorCode = .evaluator_not_implemented,
    ex_units_mem: u64 = 0,
    ex_units_steps: u64 = 0,
};

/// Evaluate Plutus scripts against a given execution context.
/// STUB: TSUNAGI does not execute Plutus yet.
/// Always returns evaluator_not_implemented.
pub fn evaluatePlutus(context: *const PlutusExecutionContext) ExecutionResult {
    _ = context;
    return .{
        .success = false,
        .error_code = .evaluator_not_implemented,
        .ex_units_mem = 0,
        .ex_units_steps = 0,
    };
}

const eval_external = @import("eval_external.zig");

// ---------------------------------------------------------------------------
// Phase 17: Plutus Evaluator Adapter Layer
// Backend selection for a future real evaluator.
// ---------------------------------------------------------------------------

/// Available evaluator backend modes.
pub const EvalBackend = enum(u8) {
    none = 0,
    external_process = 1,
    ffi = 2,
    wasm = 3,
    embedded = 4,
};

/// Evaluate Plutus via selected backend adapter.
/// No backends are implemented yet — all return an appropriate error.
pub fn evaluateWithAdapter(
    context: *const PlutusExecutionContext,
    backend: EvalBackend,
) ExecutionResult {
    return switch (backend) {
        .none => evaluatePlutus(context),
        .external_process => eval_external.evaluateExternal(context),
        .embedded => eval_external.evaluateMinimalRules(context),
        .ffi, .wasm => .{
            .success = false,
            .error_code = .backend_unavailable,
            .ex_units_mem = 0,
            .ex_units_steps = 0,
        },
    };
}

/// Per-input spending path classification.
pub const InputPathCounts = struct {
    key_controlled: u32 = 0,
    script_non_plutus: u32 = 0,
    plutus_definitive: u32 = 0,
    unknown: u32 = 0,
    total: u32 = 0,
};

/// Classify each consumed input's spending path using existing callbacks.
/// Combines UTxO lookup (existence), keyhash lookup (key vs script address),
/// and script classification (Plutus vs native).
pub fn classifyInputPaths(
    alloc: std.mem.Allocator,
    tx_bytes: []const u8,
    lookup_fn: ?*const fn ([32]u8, u32) ?u64,
    keyhash_fn: ?*const fn ([32]u8, u32) ?[28]u8,
) ?InputPathCounts {
    const inputs = extractTxInputsFromBytes(alloc, tx_bytes) orelse return null;
    defer alloc.free(inputs);
    if (inputs.len == 0) return null;

    const sc = classifyTxScripts(tx_bytes);
    const is_plutus = if (sc) |s| s.requires_plutus_definitive else false;

    var counts = InputPathCounts{};
    counts.total = @intCast(inputs.len);

    for (inputs) |inp| {
        // Check if UTxO exists
        const exists = if (lookup_fn) |lf| (lf(inp.tx_hash, inp.index) != null) else false;
        if (!exists) {
            counts.unknown += 1;
            continue;
        }

        // Check if key-controlled
        const has_keyhash = if (keyhash_fn) |kf| (kf(inp.tx_hash, inp.index) != null) else false;
        if (has_keyhash) {
            counts.key_controlled += 1;
        } else if (is_plutus) {
            counts.plutus_definitive += 1;
        } else {
            counts.script_non_plutus += 1;
        }
    }

    return counts;
}

pub fn extractOutputLovelaces(alloc: std.mem.Allocator, tx_bytes: []const u8) ?[]u64 {
    var fbs = compat.fixedBufferStream(tx_bytes);
    const term = cbor.decode(alloc, fbs.reader()) catch return null;
    defer cbor.free(term, alloc);

    const body: cbor.Term = if (term == .array and term.array.len >= 1) blk: {
        const b = term.array[0];
        if (b == .map_u64) break :blk b;
        if (b == .bytes and b.bytes.len > 50) {
            var inner_fbs = compat.fixedBufferStream(b.bytes);
            const inner = cbor.decode(alloc, inner_fbs.reader()) catch break :blk b;
            if (inner == .map_u64) break :blk inner;
            break :blk b;
        }
        break :blk b;
    } else if (term == .map_u64) term else return null;

    if (body != .map_u64) return null;

    const outputs_term = findMapKey(body.map_u64, 1) orelse return null;
    const outputs_array = if (outputs_term == .array) outputs_term.array else if (outputs_term == .tag and outputs_term.tag.value.* == .array) outputs_term.tag.value.*.array else return null;

    var list = std.array_list.Managed(u64).init(alloc);
    for (outputs_array) |o| {
        if (o == .array and o.array.len >= 2) {
            list.append(extractLovelace(o.array[1])) catch continue;
        } else if (o == .map_u64) {
            if (findMapValue(o.map_u64, 1)) |val| {
                list.append(extractLovelace(val)) catch continue;
            }
        }
    }
    return list.toOwnedSlice() catch null;
}

// Canonical tx body detector: must have inputs (key 0), outputs (key 1), AND fee (key 2)
fn looksLikeTxBodyMap(m: []const cbor.MapEntry) bool {
    if (m.len == 0) return false;

    // Key 0: inputs (array or tag-wrapped array)
    const key0 = findMapKey(m, 0);
    const has_inputs = if (key0) |k0| unwrapArrayLike(k0) != null else false;

    // Key 1: outputs (array or tag-wrapped array)
    const key1 = findMapKey(m, 1);
    const has_outputs = if (key1) |k1|
        (k1 == .array or (k1 == .tag and k1.tag.value.* == .array))
    else
        false;

    // Key 2: fee (must be u64)
    const key2 = findMapKey(m, 2);
    const has_fee = if (key2) |k2| k2 == .u64 else false;

    // Real tx body MUST have all three
    return has_inputs and has_outputs and has_fee;
}

// Old validation function (keep for backwards compatibility during transition)
fn looksLikeRealTxMap(m: []const cbor.MapEntry) bool {
    return looksLikeTxBodyMap(m);
}

/// Turn one tx-body item (bytes/tag/map/array) into a tx-body map_u64 or array term.
/// Returns struct with term and allocated flag. If allocated=true, caller must free.
fn decodeTxBodyItemToMap(alloc: std.mem.Allocator, item: cbor.Term) ?TxBodyDecode {
    return decodeTxBodyItemToMapInner(alloc, item, 0);
}

fn decodeTxBodyItemToMapInner(alloc: std.mem.Allocator, item: cbor.Term, depth: u32) ?TxBodyDecode {
    if (depth > 10) return null; // Prevent infinite recursion

    // 1. Direct map_u64 - validate it's a real tx body
    if (item == .map_u64) {
        if (looksLikeRealTxMap(item.map_u64)) {
            return .{ .term = item, .allocated = false };
        }
        return null; // Reject empty or invalid maps
    }

    // 2. Tag wrapper - unwrap and recurse
    if (item == .tag) {
        return decodeTxBodyItemToMapInner(alloc, item.tag.value.*, depth + 1);
    }

    // 3. Bytes - decode and recurse (skip if looks like 32-byte hash)
    if (item == .bytes) {
        // Skip 32-byte hashes (likely tx hash, not tx body CBOR)
        if (item.bytes.len == 32) return null;

        // Only decode if bytes are large enough to be a tx body
        if (item.bytes.len < 50) return null;

        const decoded = decodeCborFromBytes(alloc, item.bytes) catch return null;
        const result = decodeTxBodyItemToMapInner(alloc, decoded, depth + 1);
        if (result == null) {
            cbor.free(decoded, alloc);
        }
        return result;
    }

    // 4. Array - could be tx body array format or container
    if (item == .array) {
        const arr = item.array;
        if (arr.len == 0) return null;

        // Check if this looks like a tx body array (first element is inputs array)
        const first = arr[0];
        if (first == .array or (first == .tag and first.tag.value.* == .array)) {
            if (arr.len >= 2) {
                // Likely a tx body in array format [inputs, outputs, ...]
                return .{ .term = item, .allocated = false };
            }
        }

        // Otherwise, iterate elements and recurse
        // Skip u64 elements (era markers)
        // Skip 32-byte hashes
        for (arr) |elem| {
            if (elem == .u64) continue;
            if (elem == .bytes and elem.bytes.len == 32) continue;

            if (decodeTxBodyItemToMapInner(alloc, elem, depth + 1)) |result| {
                return result;
            }
        }
    }

    return null;
}

fn findMapValue(entries: []const cbor.MapEntry, key: u64) ?cbor.Term {
    for (entries) |e| {
        if (e.key == key) return e.value;
    }
    return null;
}

fn looksLikeTxList(items: []cbor.Term) bool {
    if (items.len == 0) return false;
    const first = items[0];

    // HARD RULE: tx list items are NEVER u64
    if (first == .u64) return false;

    // Direct map_u64 is always a TX body (Byron/Shelley era)
    if (first == .map_u64) return true;

    // Array-encoded TX body (Conway/Babbage era)
    // TX bodies are arrays with multiple fields (typically 8+ elements)
    if (first == .array) {
        // Heuristic: TX body arrays have multiple fields (inputs, outputs, fee, etc.)
        // Single-element arrays or very short arrays are likely not TX bodies
        if (first.array.len >= 3) return true;
    }

    // Tag-wrapped (tag24 or Conway tags like 258/259)
    if (first == .tag) {
        const inner = first.tag.value.*;
        // Tag wrapping map_u64 directly
        if (inner == .map_u64) return true;
        // Tag wrapping array (Conway TX bodies)
        if (inner == .array and inner.array.len >= 3) return true;
        // Tag wrapping bytes (likely CBOR-encoded map)
        if (inner == .bytes and inner.bytes.len > 32) return true; // TX bodies are >32 bytes
    }

    // Direct bytes that are likely TX bodies (not 32-byte hashes)
    if (first == .bytes) {
        // Heuristic: TX bodies are typically >100 bytes, hashes are 32 bytes
        if (first.bytes.len > 32) return true;
    }

    return false;
}

fn extractTxListFromTerm(alloc: std.mem.Allocator, term: cbor.Term) ?[]cbor.Term {
    return extractTxListFromTermInner(alloc, term);
}

pub fn looksLikeTxListPublic(items: []cbor.Term) bool {
    return looksLikeTxList(items);
}

pub fn extractTxListFromTermPublic(alloc: std.mem.Allocator, term: cbor.Term) ?TxBodyScan {
    const tx_list = extractTxListFromTermInner(alloc, term) orelse return null;
    return .{ .tx_list = tx_list, .owner = term };
}

// Score a candidate tx list - higher score = more likely to be real tx bodies
fn scoreTxList(items: []cbor.Term) u32 {
    var score: u32 = 0;
    const check_count = @min(items.len, 5); // Check first 5 items

    for (items[0..check_count]) |item| {
        // Check if it looks like a tx body map
        if (item == .map_u64 and looksLikeTxBodyMap(item.map_u64)) {
            score += 10; // Strong signal
        }
        // Check if it's a hash-only entry (reject these lists)
        else if (item == .bytes and item.bytes.len == 32) {
            if (score >= 5) score -= 5;
        }
        // Check if it's [u64, bytes32, ...] pattern (hash-only)
        else if (item == .array and item.array.len >= 2) {
            const arr = item.array;
            if (arr[0] == .u64 and arr[1] == .bytes and arr[1].bytes.len == 32) {
                if (score >= 5) score -= 5;
            }
        }
    }

    return score;
}

fn extractTxListFromTermInner(
    alloc: std.mem.Allocator,
    term: cbor.Term,
) ?[]cbor.Term {
    _ = alloc; // May be used in future for dynamic allocation
    if (term == .array) {
        const a = term.array;

        // Conway payload detection: [u64, bytes, array, array, array]
        // TX bodies are in items[2] sections (array[0] or array[1])
        if (a.len == 5 and a[0] == .u64 and a[1] == .bytes and a[2] == .array) {
            const container = a[2].array;
            var best_sec: ?[]cbor.Term = null;
            var best_score: u32 = 0;
            var best_idx: usize = 0;

            // Score container[0]
            if (container.len > 0 and container[0] == .array) {
                const sec0 = container[0].array;
                if (looksLikeTxList(sec0)) {
                    const score = scoreTxList(sec0);
                    if (score > best_score) {
                        best_score = score;
                        best_sec = sec0;
                        best_idx = 0;
                    }
                }
            }
            // Score container[1]
            if (container.len > 1 and container[1] == .array) {
                const sec1 = container[1].array;
                if (looksLikeTxList(sec1)) {
                    const score = scoreTxList(sec1);
                    if (score > best_score) {
                        best_score = score;
                        best_sec = sec1;
                        best_idx = 1;
                    }
                }
            }
            if (best_sec) |sec| {
                if (txExtractVerboseEnabled()) std.debug.print("TX_EXTRACT: Conway path container[{d}] score={d}\n", .{ best_idx, best_score });
                return sec;
            }
        }

        // DO NOT accept arrays of u64
        if (looksLikeTxList(a)) {
            if (txExtractVerboseEnabled()) std.debug.print("TX_EXTRACT: Direct array path\n", .{});
            return a;
        }

        // Scan children - use scoring to pick best candidate
        var best_idx: ?usize = null;
        var best_list: ?[]cbor.Term = null;
        var best_score: u32 = 0;
        for (a, 0..) |child, idx| {
            if (child == .array and looksLikeTxList(child.array)) {
                const score = scoreTxList(child.array);
                if (score > best_score) {
                    best_score = score;
                    best_idx = idx;
                    best_list = child.array;
                }
            }
        }
        if (best_idx) |idx| {
            if (txExtractVerboseEnabled()) std.debug.print("TX_EXTRACT: Scan path index={d} score={d}\n", .{ idx, best_score });
            return best_list.?;
        }

        // Also check for maps containing arrays
        for (a) |child| {
            if (child == .map_u64) {
                for (child.map_u64) |e| {
                    const v = e.value;
                    if (v == .array and looksLikeTxList(v.array))
                        return v.array;
                }
            }
        }
        return null;
    }

    if (term == .map_u64) {
        for (term.map_u64) |e| {
            const v = e.value;
            if (v == .array and looksLikeTxList(v.array))
                return v.array;
        }
    }

    return null;
}

pub fn scanTxBodiesFromBodyBytes(
    alloc: std.mem.Allocator,
    block_body_bytes: []const u8,
    debug: bool,
) ?TxBodyScan {
    const term = cbor_term.decodeOrRaw(alloc, block_body_bytes) catch |err| {
        if (err == error.EndOfStream) return null;
        if (debug) std.debug.print("TX_SEQ: decode err={any}\n", .{err});
        return null;
    };

    if (debug) {
        const top_kind = @tagName(term);
        if (term == .array) {
            const a = term.array;
            const a0 = if (a.len > 0) @tagName(a[0]) else "none";
            const a1 = if (a.len > 1) @tagName(a[1]) else "none";
            std.debug.print("TX_SHAPE: top={s} len={d} a0={s} a1={s}\n", .{ top_kind, a.len, a0, a1 });
        } else {
            std.debug.print("TX_SHAPE: top={s}\n", .{top_kind});
        }
    }

    if (debug) std.debug.print("TX_SEQ: top_kind={s}\n", .{termKindName(term)});
    if (debug) {
        if (unwrapTag24Bytes(term)) |raw| {
            const first_byte: u8 = if (raw.len > 0) raw[0] else 0;
            std.debug.print("TX_SEQ: raw_len={d} first_byte=0x{x}\n", .{ raw.len, first_byte });
        }
    }

    if (term == .tag and term.tag.tag == 24 and term.tag.value.* == .bytes) {
        // tag24 unwrap
        const inner = term.tag.value.*;
        if (inner == .bytes) {
            // decode bytes again
            return scanTxBodiesFromBodyBytes(alloc, inner.bytes, debug);
        }
    }

    // Conway payload: [u64, bytes, array, array, array] -> tx bodies in items[2] sections
    if (term == .array) {
        const a = term.array;
        if (a.len == 5 and a[0] == .u64 and a[1] == .bytes and a[2] == .array) {
            const container = a[2].array;
            // Try container[0] if it's an array
            if (container.len > 0 and container[0] == .array) {
                const sec0 = container[0].array;
                if (looksLikeTxList(sec0)) {
                    if (debug) std.debug.print("TX_SEQ: conway items[2][0] tx_list_len={d}\n", .{sec0.len});
                    return .{ .tx_list = sec0, .owner = term };
                }
            }
            // Try container[1] as fallback
            if (container.len > 1 and container[1] == .array) {
                const sec1 = container[1].array;
                if (looksLikeTxList(sec1)) {
                    if (debug) std.debug.print("TX_SEQ: conway items[2][1] tx_list_len={d}\n", .{sec1.len});
                    return .{ .tx_list = sec1, .owner = term };
                }
            }
        }
    }

    // Fast path: many eras encode tx body bytes as [ tx_bodies, witnesses ]
    if (term == .array and term.array.len == 2 and term.array[0] == .array) {
        const maybe_txs = term.array[0].array;
        if (maybe_txs.len > 0) {
            // if first item looks like a tx-body container, accept it
            const first = maybe_txs[0];
            if (first == .map_u64 or first == .bytes or (first == .tag and first.tag.tag == 24 and first.tag.value.* == .bytes)) {
                if (debug) std.debug.print("TX_SEQ: fastpath array[0] tx_list len={d}\n", .{maybe_txs.len});
                return .{ .tx_list = maybe_txs, .owner = term };
            }
        }
    }

    if (term == .bytes) {
        const inner = cbor_term.decodeOrRaw(alloc, term.bytes) catch |err| {
            if (debug) std.debug.print("TX_SEQ: decode err={any}\n", .{err});
            cbor.free(term, alloc);
            return null;
        };
        if (extractTxListFromTerm(alloc, inner)) |txs| {
            if (debug) std.debug.print("TX_SEQ: FOUND tx_list len={d} via inner\n", .{txs.len});
            cbor.free(term, alloc);
            return .{ .tx_list = txs, .owner = inner };
        }
        cbor.free(inner, alloc);
    }

    if (extractTxListFromTerm(alloc, term)) |txs| {
        if (debug) std.debug.print("TX_SEQ: FOUND tx_list len={d} via top\n", .{txs.len});
        return .{ .tx_list = txs, .owner = term };
    }

    cbor.free(term, alloc);
    return null;
}

/// Compute a temporary tx hash from a tx-body map by CBOR-encoding it and blake2b256.
/// (This is *not* the canonical txid yet; good enough for UTxO scaffolding.)
fn hashTxBodyMap(alloc: std.mem.Allocator, tx_map: []const cbor.MapEntry) ?[32]u8 {
    var list = std.array_list.Managed(u8).init(alloc);
    defer list.deinit();
    cbor.encode(cbor.Term{ .map_u64 = @constCast(tx_map) }, compat.listWriter(&list)) catch return null;

    var out: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(list.items, &out, .{});
    return out;
}

/// Compute a temporary tx hash from a tx-body array (Conway era) by CBOR-encoding and blake2b256.
fn hashTxBodyArray(alloc: std.mem.Allocator, tx_array: []const cbor.Term) ?[32]u8 {
    var list = std.array_list.Managed(u8).init(alloc);
    defer list.deinit();
    cbor.encode(cbor.Term{ .array = @constCast(tx_array) }, compat.listWriter(&list)) catch return null;

    var out: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(list.items, &out, .{});
    return out;
}

fn parseInputs(alloc: std.mem.Allocator, tx_hash: [32]u8, tx_term: cbor.Term) ?[]utxo.TxIn {
    // Cardano tx-body key/index 0 = inputs (array or tag-wrapped array)
    const inputs_term = if (tx_term == .map_u64)
        findMapValue(tx_term.map_u64, 0) orelse return null
    else if (tx_term == .array and tx_term.array.len > 0)
        tx_term.array[0]
    else
        return null;

    // Unwrap tag-wrapped arrays (e.g., tag 258 for sets)
    const inputs_array = unwrapArrayLike(inputs_term) orelse return null;

    // We don't have real txid yet for referenced inputs inside the tx,
    // so we just store (tx_hash, index) placeholder when we can parse index.
    // Many formats are [ txid, ix ] but txid itself is bytes32.
    var out = std.array_list.Managed(utxo.TxIn).init(alloc);
    errdefer out.deinit();

    for (inputs_array) |inp| {
        if (inp != .array or inp.array.len < 2) continue;

        const ix_term = inp.array[1];
        if (ix_term != .u64) continue;

        // Use the actual referenced tx hash from the input structure
        var ref_hash: [32]u8 = tx_hash;
        const ref_term = inp.array[0];
        if (ref_term == .bytes and ref_term.bytes.len == 32) {
            @memcpy(&ref_hash, ref_term.bytes);
        }

        out.append(.{ .tx_hash = ref_hash, .index = @intCast(ix_term.u64) }) catch return null;
    }

    return out.toOwnedSlice() catch null;
}

/// Extract lovelace from an amount term.
/// Amount is either u64 (lovelace only) or [lovelace, multiasset_map].
/// Structural validation for Cardano address bytes.
/// Checks header byte type nibble and plausible length.
/// Does NOT validate cryptographic content or bech32 encoding.
/// Addresses shorter than 29 bytes are passed through (test/synthetic addresses).
fn isPlausibleAddress(addr: []const u8) bool {
    // Short addresses (< 29 bytes) are below any real Cardano address minimum.
    // Accept them to avoid rejecting test/synthetic data.
    if (addr.len < 29) return true;
    const header = addr[0];
    const addr_type = header >> 4;
    return switch (addr_type) {
        0, 1, 2, 3 => addr.len >= 57 and addr.len <= 65, // Shelley base (payment + stake)
        4, 5 => addr.len >= 29 and addr.len <= 33, // Shelley enterprise (payment only)
        6, 7 => addr.len >= 29, // Shelley pointer (variable)
        8 => addr.len >= 33, // Byron bootstrap (variable, typically 76+)
        14, 15 => addr.len >= 29, // Shelley reward account
        else => false, // types 9-13 are reserved/unused
    };
}

fn extractLovelace(amt: cbor.Term) u64 {
    if (amt == .u64) return amt.u64;
    // [lovelace, multiasset_map] — first element is lovelace
    if (amt == .array and amt.array.len >= 1 and amt.array[0] == .u64) return amt.array[0].u64;
    return 0;
}

fn parseOutputs(alloc: std.mem.Allocator, tx_hash: [32]u8, tx_term: cbor.Term) ?[]utxo.Produced {
    // Cardano tx-body key/index 1 = outputs (array or tag-wrapped array)
    const outputs_term = if (tx_term == .map_u64)
        findMapValue(tx_term.map_u64, 1) orelse return null
    else if (tx_term == .array and tx_term.array.len > 1)
        tx_term.array[1]
    else
        return null;

    // Unwrap tag-wrapped arrays
    const outputs_array = unwrapArrayLike(outputs_term) orelse return null;

    var out = std.array_list.Managed(utxo.Produced).init(alloc);
    errdefer out.deinit();

    var out_index: u32 = 0;
    for (outputs_array) |o| {
        var lovelace: u64 = 0;
        var addr_raw: []const u8 = "";

        if (o == .array and o.array.len >= 2) {
            // Legacy/Shelley/Allegra/Mary/Alonzo: [addr_bytes, amount, ?datum_hash]
            const addr_term = o.array[0];
            if (addr_term == .bytes) addr_raw = addr_term.bytes;

            const amt = o.array[1];
            lovelace = extractLovelace(amt);
        } else if (o == .map_u64) {
            // Post-Alonzo (Babbage/Conway): {0: addr, 1: value, 2?: datum_option, 3?: script_ref}
            if (findMapValue(o.map_u64, 0)) |addr_term| {
                if (addr_term == .bytes) addr_raw = addr_term.bytes;
            }
            if (findMapValue(o.map_u64, 1)) |val_term| {
                lovelace = extractLovelace(val_term);
            }
        }

        // V1: Address structural validation
        if (addr_raw.len > 0 and !isPlausibleAddress(addr_raw)) {
            Counters.c.address_malformed_total += 1;
            // Skip this output — do not produce a UTxO with a malformed address
            out_index += 1;
            continue;
        }

        // Dupe address bytes so they survive CBOR term freeing
        const addr_owned: []const u8 = if (addr_raw.len > 0)
            alloc.dupe(u8, addr_raw) catch return null
        else
            "";

        const produced = utxo.Produced{
            .input = .{ .tx_hash = tx_hash, .index = out_index },
            .output = .{ .address = addr_owned, .lovelace = lovelace },
        };

        out.append(produced) catch return null;
        out_index += 1;
    }

    return out.toOwnedSlice() catch null;
}

/// Extract deltas from a tx-list (array items) where each item is bytes/tag24/map.
/// - Never panics; best-effort.
/// - Returns empty deltas if we can't decode.
/// - canonical_txids: optional pre-computed canonical txids from byte-level extraction.
///   When provided, must cover ALL tx items (all-or-nothing per block).
///   If count mismatches tx_list length, the entire set is discarded.
pub fn extractTxDeltas(
    alloc: std.mem.Allocator,
    tx_source: anytype,
    canonical_txids: ?[]const [32]u8,
    debug: bool,
) !TxDeltas {
    return extractTxDeltasWithSlot(alloc, tx_source, canonical_txids, debug, 0);
}

/// extractTxDeltas with block_slot for validity interval enforcement.
pub fn extractTxDeltasWithSlot(
    alloc: std.mem.Allocator,
    tx_source: anytype,
    canonical_txids: ?[]const [32]u8,
    debug: bool,
    block_slot: u64,
) !TxDeltas {
    var consumed_list = std.array_list.Managed(utxo.TxIn).init(alloc);
    errdefer consumed_list.deinit();
    var produced_list = std.array_list.Managed(utxo.Produced).init(alloc);
    errdefer produced_list.deinit();

    var tx_count: u64 = 0;

    const SourceT = @TypeOf(tx_source);
    var tx_list_items: []cbor.Term = &[_]cbor.Term{};
    const seq_owner: ?cbor.Term = null;
    if (SourceT == []const u8) {
        // === Step 2: robust tx body decode with raw CBOR fallback (Babbage) ===

        const body_bytes = tx_source;
        var tx_list: ?[]cbor.Term = null;
        var tx_list_kind: []const u8 = "unknown";

        var term: cbor.Term = try cbor_term.decodeOrRaw(alloc, body_bytes);
        defer cbor.free(term, alloc);

        // if wrapped as raw bytes, decode AGAIN to reach real structure
        if (term == .bytes) {
            var inner_fbs = compat.fixedBufferStream(term.bytes);
            const inner_r = inner_fbs.reader();
            term = try cbor.decode(alloc, inner_r);
        }

        // === Babbage tx bodies live at map[0] ===
        if (term == .map_u64) {
            const entries = term.map_u64;
            if (findMapValue(entries, 0)) |txs_term| {
                if (txs_term == .array) {
                    tx_list = txs_term.array;
                    tx_list_kind = "babbage-map-0";
                }
            }
        }

        // optional debug
        if (debug) {
            std.debug.print(
                "TX_DECODE: tx_list_kind={s} len={d}\n",
                .{
                    tx_list_kind,
                    if (tx_list) |l| l.len else 0,
                },
            );
        }

        if (tx_list) |items| {
            tx_list_items = items;
        } else {
            return .{
                .consumed = try consumed_list.toOwnedSlice(),
                .produced = try produced_list.toOwnedSlice(),
                .tx_count = 0,
            };
        }
    } else if (SourceT == []cbor.Term) {
        tx_list_items = tx_source;
    } else {
        @compileError("extractTxDeltas expects []const u8 or []cbor.Term");
    }
    defer if (seq_owner) |t| cbor.free(t, alloc);

    // Task A: Debug first TX item shape (once per process, bounded)
    const print_first_item = blk: {
        const State = struct {
            var printed: bool = false;
        };
        if (!State.printed and debug and tx_list_items.len > 0) {
            State.printed = true;
            break :blk true;
        }
        break :blk false;
    };

    if (print_first_item) {
        const item0 = tx_list_items[0];
        std.debug.print("TX_ITEM0: kind={s}", .{@tagName(item0)});

        if (item0 == .bytes) {
            const b0 = if (item0.bytes.len > 0) item0.bytes[0] else 0;
            const b1 = if (item0.bytes.len > 1) item0.bytes[1] else 0;
            std.debug.print(" len={d} first2=0x{x:0>2}{x:0>2}", .{ item0.bytes.len, b0, b1 });
        } else if (item0 == .tag) {
            std.debug.print(" tag={d} inner={s}", .{ item0.tag.tag, @tagName(item0.tag.value.*) });
            if (item0.tag.value.* == .bytes) {
                const inner_b = item0.tag.value.*.bytes;
                const b0 = if (inner_b.len > 0) inner_b[0] else 0;
                const b1 = if (inner_b.len > 1) inner_b[1] else 0;
                std.debug.print(" inner_len={d} first2=0x{x:0>2}{x:0>2}", .{ inner_b.len, b0, b1 });
            }
        } else if (item0 == .array) {
            const arr = item0.array;
            std.debug.print(" len={d}", .{arr.len});
            const max_show = @min(3, arr.len);
            var i: usize = 0;
            while (i < max_show) : (i += 1) {
                const elem = arr[i];
                std.debug.print(" [{d}]={s}", .{ i, @tagName(elem) });
                if (elem == .bytes) {
                    const b0 = if (elem.bytes.len > 0) elem.bytes[0] else 0;
                    const b1 = if (elem.bytes.len > 1) elem.bytes[1] else 0;
                    std.debug.print("(len={d},0x{x:0>2}{x:0>2})", .{ elem.bytes.len, b0, b1 });
                } else if (elem == .tag) {
                    std.debug.print("(tag={d},{s})", .{ elem.tag.tag, @tagName(elem.tag.value.*) });
                    if (elem.tag.value.* == .bytes) {
                        const tb = elem.tag.value.*.bytes;
                        const b0 = if (tb.len > 0) tb[0] else 0;
                        const b1 = if (tb.len > 1) tb[1] else 0;
                        std.debug.print("(len={d},0x{x:0>2}{x:0>2})", .{ tb.len, b0, b1 });
                    }
                }
            }
        }
        std.debug.print("\n", .{});
    }

    // All-or-nothing canonical txid validation:
    // If canonical_txids is provided but count doesn't match tx_list length,
    // discard the entire set and fall back for the whole block.
    const use_canonical = if (canonical_txids) |ids| blk: {
        if (ids.len == tx_list_items.len) {
            break :blk true;
        } else {
            std.debug.print(
                "TXID_PATH: FALLBACK (count mismatch canonical={d} tx_list={d})\n",
                .{ ids.len, tx_list_items.len },
            );
            Counters.c.txid_count_mismatch += 1;
            break :blk false;
        }
    } else false;

    std.debug.print("CANON_PROBE: tx_count={d} canonical_ids={d} ids_match={} use={}\n", .{
        tx_list_items.len,
        if (canonical_txids) |ids| ids.len else @as(usize, 0),
        if (canonical_txids) |ids| ids.len == tx_list_items.len else false,
        use_canonical,
    });

    // Instrumentation: log canonical vs fallback path per block (rate-limited, 30s)
    {
        const CanonLog = struct {
            var last_unix: i64 = 0;
            var canonical_blocks: u64 = 0;
            var fallback_blocks: u64 = 0;
        };
        if (use_canonical) {
            CanonLog.canonical_blocks += 1;
        } else if (tx_list_items.len > 0) {
            CanonLog.fallback_blocks += 1;
        }
        const now_cl = compat.timestamp();
        if (now_cl - CanonLog.last_unix >= 30 and tx_list_items.len > 0) {
            CanonLog.last_unix = now_cl;
            std.debug.print(
                "TXID_PATH: canonical_blocks={d} fallback_blocks={d} tx_count={d} canonical_ids={d} use={}\n",
                .{
                    CanonLog.canonical_blocks,
                    CanonLog.fallback_blocks,
                    tx_list_items.len,
                    if (canonical_txids) |ids| ids.len else 0,
                    use_canonical,
                },
            );
        }
    }

    Counters.c.blocks_total += 1;

    for (tx_list_items, 0..) |item, tx_index| {
        tx_count += 1;

        // Decode to a tx-body map or array
        const decoded_opt = decodeTxBodyItemToMap(alloc, item);
        if (decoded_opt == null) {
            if (debug) std.debug.print("TX_DECODE: skip tx_item (not decodable)\n", .{});
            Counters.c.decode_fail += 1;
            continue;
        }
        const decoded = decoded_opt.?;
        const tx_term = decoded.term;

        if (decoded.allocated) {
            defer cbor.free(tx_term, alloc);
        }

        if (debug) {
            std.debug.print("TX_DECODE: got tx_term kind={s}", .{@tagName(tx_term)});
            if (tx_term == .map_u64) {
                std.debug.print(" map_len={d}", .{tx_term.map_u64.len});
            } else if (tx_term == .array) {
                std.debug.print(" array_len={d}", .{tx_term.array.len});
            }
            std.debug.print("\n", .{});
        }

        // Compute tx hash: canonical if available, else re-encode fallback
        const tx_hash: [32]u8 = if (use_canonical) canonical_txids.?[tx_index] else blk: {
            const h_opt = if (tx_term == .map_u64)
                hashTxBodyMap(alloc, tx_term.map_u64)
            else if (tx_term == .array)
                hashTxBodyArray(alloc, tx_term.array)
            else
                null;
            if (h_opt == null) {
                if (debug) std.debug.print("TX_DECODE: hash failed (not map/array or hash error)\n", .{});
                Counters.c.hash_fail += 1;
                continue;
            }
            break :blk h_opt.?;
        };

        // --- PROBE: print first tx map keys / types once per run ---
        const TxMapProbe = struct {
            var done: bool = false;
        };
        if (debug and !TxMapProbe.done and tx_term == .map_u64) {
            TxMapProbe.done = true;
            const m = tx_term.map_u64;

            var has0: bool = false;
            var has1: bool = false;

            std.debug.print("\nTX_MAP_PROBE: map_len={d}\n", .{m.len});

            // print first ~12 keys (sorted order in CBOR isn't guaranteed, but enough for diagnosis)
            const maxk = @min(@as(usize, 12), m.len);
            var i: usize = 0;
            while (i < maxk) : (i += 1) {
                const e = m[i];
                std.debug.print("  key={d} kind={s}", .{ e.key, @tagName(e.value) });
                if (e.value == .tag) {
                    std.debug.print(" tag={d} inner={s}", .{ e.value.tag.tag, @tagName(e.value.tag.value.*) });
                } else if (e.value == .bytes) {
                    std.debug.print(" bytes_len={d}", .{e.value.bytes.len});
                } else if (e.value == .array) {
                    std.debug.print(" array_len={d}", .{e.value.array.len});
                    if (e.value.array.len > 0) {
                        std.debug.print(" a0={s}", .{@tagName(e.value.array[0])});
                    }
                }
                std.debug.print("\n", .{});

                if (e.key == 0) has0 = true;
                if (e.key == 1) has1 = true;
            }

            std.debug.print("TX_MAP_PROBE: has_key0={} has_key1={}\n\n", .{ has0, has1 });
        }
        // --- END PROBE ---

        // Parse inputs/outputs
        const ins = parseInputs(alloc, tx_hash, tx_term) orelse {
            if (debug) std.debug.print("TX_DECODE: parseInputs returned null\n", .{});
            Counters.c.input_parse_fail += 1;
            continue;
        };
        defer alloc.free(ins);

        const outs = parseOutputs(alloc, tx_hash, tx_term) orelse {
            if (debug) std.debug.print("TX_DECODE: parseOutputs returned null\n", .{});
            Counters.c.output_parse_fail += 1;
            continue;
        };
        defer alloc.free(outs);

        // ── Validation Envelope v0 ──

        // V0-A: Input uniqueness (O(n²), no allocator)
        var has_dup = false;
        for (ins, 0..) |a, ai| {
            for (ins[ai + 1 ..]) |b| {
                if (a.index == b.index and std.mem.eql(u8, &a.tx_hash, &b.tx_hash)) {
                    has_dup = true;
                    break;
                }
            }
            if (has_dup) break;
        }
        if (has_dup) {
            Counters.c.input_duplicate_total += 1;
            if (debug) std.debug.print("TX_VALIDATE: REJECT duplicate input\n", .{});
            continue;
        }

        // V0-B: Validity interval (TTL + validity_start)
        // key 3 = TTL (invalid_hereafter): tx invalid if block_slot >= TTL
        // key 8 = validity_start (invalid_before): tx invalid if block_slot < validity_start
        // Skip when block_slot == 0 (caller did not provide slot context)
        if (block_slot > 0 and tx_term == .map_u64) {
            if (findMapKeyPublic(tx_term.map_u64, 3)) |ttl_term| {
                if (ttl_term == .u64 and block_slot >= ttl_term.u64) {
                    Counters.c.validity_ttl_fail += 1;
                    if (debug) std.debug.print("TX_VALIDATE: REJECT TTL={d} block_slot={d}\n", .{ ttl_term.u64, block_slot });
                    continue;
                }
            }
            if (findMapKeyPublic(tx_term.map_u64, 8)) |vs_term| {
                if (vs_term == .u64 and block_slot < vs_term.u64) {
                    Counters.c.validity_start_fail += 1;
                    if (debug) std.debug.print("TX_VALIDATE: REJECT validity_start={d} block_slot={d}\n", .{ vs_term.u64, block_slot });
                    continue;
                }
            }
        }

        // V0-C: Fee sanity (observability only, no rejection)
        if (tx_term == .map_u64) {
            if (findMapKeyPublic(tx_term.map_u64, 2)) |fee_term| {
                if (fee_term == .u64 and fee_term.u64 == 0) {
                    Counters.c.fee_zero_total += 1;
                }
            }
        }

        if (debug) {
            std.debug.print("TX_DECODE: SUCCESS consumed={d} produced={d}\n", .{ ins.len, outs.len });
        }

        for (ins) |i| try consumed_list.append(i);
        for (outs) |o| try produced_list.append(o);
    }

    return .{
        .consumed = try consumed_list.toOwnedSlice(),
        .produced = try produced_list.toOwnedSlice(),
        .tx_count = tx_count,
    };
}

// ── Tests: parseOutputs ──────────────────────────────────────────

test "parseOutputs array-form extracts address and lovelace" {
    const alloc = std.testing.allocator;
    const txh = [_]u8{0xAA} ** 32;

    // Build tx body map: {0: inputs, 1: outputs, 2: fee}
    // inputs: one dummy input
    var inp_items = [_]cbor.Term{ .{ .bytes = &([_]u8{0} ** 32) }, .{ .u64 = 0 } };
    var inp_arr = [_]cbor.Term{cbor.Term{ .array = &inp_items }};

    // outputs: one [addr_bytes, lovelace]
    const addr_bytes = "addr_test1qz";
    var out_items = [_]cbor.Term{ .{ .bytes = addr_bytes }, .{ .u64 = 2_500_000 } };
    var out_arr = [_]cbor.Term{cbor.Term{ .array = &out_items }};

    var entries = [_]cbor.MapEntry{
        .{ .key = 0, .value = cbor.Term{ .array = &inp_arr } },
        .{ .key = 1, .value = cbor.Term{ .array = &out_arr } },
        .{ .key = 2, .value = .{ .u64 = 170000 } },
    };
    const tx_body = cbor.Term{ .map_u64 = &entries };

    const outs = parseOutputs(alloc, txh, tx_body) orelse {
        return error.TestUnexpectedResult;
    };
    defer {
        for (outs) |p| {
            if (p.output.address.len > 0) alloc.free(@constCast(p.output.address));
        }
        alloc.free(outs);
    }

    try std.testing.expectEqual(@as(usize, 1), outs.len);
    try std.testing.expectEqual(@as(u64, 2_500_000), outs[0].output.lovelace);
    try std.testing.expectEqualStrings("addr_test1qz", outs[0].output.address);
    try std.testing.expectEqual(@as(u32, 0), outs[0].input.index);
}

test "parseOutputs map-form (Conway) extracts address and lovelace" {
    const alloc = std.testing.allocator;
    const txh = [_]u8{0xBB} ** 32;

    // inputs
    var inp_items = [_]cbor.Term{ .{ .bytes = &([_]u8{0} ** 32) }, .{ .u64 = 0 } };
    var inp_arr = [_]cbor.Term{cbor.Term{ .array = &inp_items }};

    // output as map: {0: addr, 1: lovelace}
    const addr_bytes = "addr_conway1";
    var out_map_entries = [_]cbor.MapEntry{
        .{ .key = 0, .value = .{ .bytes = addr_bytes } },
        .{ .key = 1, .value = .{ .u64 = 5_000_000 } },
    };
    var out_arr = [_]cbor.Term{cbor.Term{ .map_u64 = &out_map_entries }};

    var entries = [_]cbor.MapEntry{
        .{ .key = 0, .value = cbor.Term{ .array = &inp_arr } },
        .{ .key = 1, .value = cbor.Term{ .array = &out_arr } },
        .{ .key = 2, .value = .{ .u64 = 185000 } },
    };
    const tx_body = cbor.Term{ .map_u64 = &entries };

    const outs = parseOutputs(alloc, txh, tx_body) orelse {
        return error.TestUnexpectedResult;
    };
    defer {
        for (outs) |p| {
            if (p.output.address.len > 0) alloc.free(@constCast(p.output.address));
        }
        alloc.free(outs);
    }

    try std.testing.expectEqual(@as(usize, 1), outs.len);
    try std.testing.expectEqual(@as(u64, 5_000_000), outs[0].output.lovelace);
    try std.testing.expectEqualStrings("addr_conway1", outs[0].output.address);
}

test "parseOutputs map-form with multiasset value [lovelace, policy_map]" {
    const alloc = std.testing.allocator;
    const txh = [_]u8{0xCC} ** 32;

    var inp_items = [_]cbor.Term{ .{ .bytes = &([_]u8{0} ** 32) }, .{ .u64 = 0 } };
    var inp_arr = [_]cbor.Term{cbor.Term{ .array = &inp_items }};

    // value = [lovelace, multiasset_map]
    var policy_map = [_]cbor.MapEntry{};
    var value_arr = [_]cbor.Term{ .{ .u64 = 3_000_000 }, cbor.Term{ .map_u64 = &policy_map } };

    const addr_bytes = "addr_ma1";
    var out_map_entries = [_]cbor.MapEntry{
        .{ .key = 0, .value = .{ .bytes = addr_bytes } },
        .{ .key = 1, .value = cbor.Term{ .array = &value_arr } },
    };
    var out_arr = [_]cbor.Term{cbor.Term{ .map_u64 = &out_map_entries }};

    var entries = [_]cbor.MapEntry{
        .{ .key = 0, .value = cbor.Term{ .array = &inp_arr } },
        .{ .key = 1, .value = cbor.Term{ .array = &out_arr } },
        .{ .key = 2, .value = .{ .u64 = 200000 } },
    };
    const tx_body = cbor.Term{ .map_u64 = &entries };

    const outs = parseOutputs(alloc, txh, tx_body) orelse {
        return error.TestUnexpectedResult;
    };
    defer {
        for (outs) |p| {
            if (p.output.address.len > 0) alloc.free(@constCast(p.output.address));
        }
        alloc.free(outs);
    }

    try std.testing.expectEqual(@as(usize, 1), outs.len);
    try std.testing.expectEqual(@as(u64, 3_000_000), outs[0].output.lovelace);
    try std.testing.expectEqualStrings("addr_ma1", outs[0].output.address);
}

test "parseOutputs array-form with multiasset [lovelace, policy_map]" {
    const alloc = std.testing.allocator;
    const txh = [_]u8{0xDD} ** 32;

    var inp_items = [_]cbor.Term{ .{ .bytes = &([_]u8{0} ** 32) }, .{ .u64 = 0 } };
    var inp_arr = [_]cbor.Term{cbor.Term{ .array = &inp_items }};

    // output: [addr, [lovelace, multiasset]]
    const addr_bytes = "addr_legacy_ma";
    var policy_map = [_]cbor.MapEntry{};
    var value_arr = [_]cbor.Term{ .{ .u64 = 7_000_000 }, cbor.Term{ .map_u64 = &policy_map } };
    var out_items = [_]cbor.Term{ .{ .bytes = addr_bytes }, cbor.Term{ .array = &value_arr } };
    var out_arr = [_]cbor.Term{cbor.Term{ .array = &out_items }};

    var entries = [_]cbor.MapEntry{
        .{ .key = 0, .value = cbor.Term{ .array = &inp_arr } },
        .{ .key = 1, .value = cbor.Term{ .array = &out_arr } },
        .{ .key = 2, .value = .{ .u64 = 190000 } },
    };
    const tx_body = cbor.Term{ .map_u64 = &entries };

    const outs = parseOutputs(alloc, txh, tx_body) orelse {
        return error.TestUnexpectedResult;
    };
    defer {
        for (outs) |p| {
            if (p.output.address.len > 0) alloc.free(@constCast(p.output.address));
        }
        alloc.free(outs);
    }

    try std.testing.expectEqual(@as(usize, 1), outs.len);
    try std.testing.expectEqual(@as(u64, 7_000_000), outs[0].output.lovelace);
    try std.testing.expectEqualStrings("addr_legacy_ma", outs[0].output.address);
}

test "parseOutputs mixed array and map outputs in same block" {
    const alloc = std.testing.allocator;
    const txh = [_]u8{0xEE} ** 32;

    var inp_items = [_]cbor.Term{ .{ .bytes = &([_]u8{0} ** 32) }, .{ .u64 = 0 } };
    var inp_arr = [_]cbor.Term{cbor.Term{ .array = &inp_items }};

    // output 0: array form
    const addr0 = "addr_arr";
    var out0_items = [_]cbor.Term{ .{ .bytes = addr0 }, .{ .u64 = 1_000_000 } };

    // output 1: map form
    const addr1 = "addr_map";
    var out1_map = [_]cbor.MapEntry{
        .{ .key = 0, .value = .{ .bytes = addr1 } },
        .{ .key = 1, .value = .{ .u64 = 2_000_000 } },
    };

    var out_arr = [_]cbor.Term{
        cbor.Term{ .array = &out0_items },
        cbor.Term{ .map_u64 = &out1_map },
    };

    var entries = [_]cbor.MapEntry{
        .{ .key = 0, .value = cbor.Term{ .array = &inp_arr } },
        .{ .key = 1, .value = cbor.Term{ .array = &out_arr } },
        .{ .key = 2, .value = .{ .u64 = 180000 } },
    };
    const tx_body = cbor.Term{ .map_u64 = &entries };

    const outs = parseOutputs(alloc, txh, tx_body) orelse {
        return error.TestUnexpectedResult;
    };
    defer {
        for (outs) |p| {
            if (p.output.address.len > 0) alloc.free(@constCast(p.output.address));
        }
        alloc.free(outs);
    }

    try std.testing.expectEqual(@as(usize, 2), outs.len);
    try std.testing.expectEqual(@as(u64, 1_000_000), outs[0].output.lovelace);
    try std.testing.expectEqualStrings("addr_arr", outs[0].output.address);
    try std.testing.expectEqual(@as(u32, 0), outs[0].input.index);
    try std.testing.expectEqual(@as(u64, 2_000_000), outs[1].output.lovelace);
    try std.testing.expectEqualStrings("addr_map", outs[1].output.address);
    try std.testing.expectEqual(@as(u32, 1), outs[1].input.index);
}

test "buildPlutusContext: synthetic Plutus tx" {
    // Hand-crafted CBOR: [body_map, witness_map]
    // body_map = {0: [input], 11: bstr32(script_data_hash), 13: [collateral], 17: 500000}
    // witness_map = {3: [script_bstr], 4: [datum_bstr], 5: [redeemer_tuple]}
    //
    // CBOR encoding (hex):
    // 82 -- array(2)
    //   A4 -- map(4)
    //     00 -- key 0 (inputs)
    //       81 -- array(1)
    //         82 -- array(2)
    //           5820 <32 zero bytes> -- bstr(32)
    //           03 -- uint(3) index
    //     0B -- key 11 (script_data_hash)
    //       5820 <32 zero bytes> -- bstr(32)
    //     0D -- key 13 (collateral)
    //       81 -- array(1)
    //         82 -- array(2)
    //           5820 <32 0xFF bytes> -- bstr(32)
    //           00 -- uint(0) index
    //     11 -- key 17 (total_collateral)
    //       1A 0007A120 -- uint(500000)
    //   A3 -- map(3)
    //     03 -- key 3 (plutus v1 scripts)
    //       81 -- array(1)
    //         43 AABBCC -- bstr(3) script body
    //     04 -- key 4 (datums)
    //       81 -- array(1)
    //         41 DD -- bstr(1) datum
    //     05 -- key 5 (redeemers)
    //       81 -- array(1)
    //         84 -- array(4)
    //           00 -- tag=spend
    //           00 -- index=0
    //           41 EE -- data bstr(1)
    //           82 1A00010000 1A00020000 -- [65536, 131072]

    var tx_bytes: [256]u8 = undefined;
    var w: usize = 0;

    // Top-level: array(2)
    tx_bytes[w] = 0x82;
    w += 1;

    // --- Body map(4) ---
    tx_bytes[w] = 0xA4;
    w += 1;

    // key 0: inputs
    tx_bytes[w] = 0x00;
    w += 1;
    // array(1)
    tx_bytes[w] = 0x81;
    w += 1;
    // input: array(2)
    tx_bytes[w] = 0x82;
    w += 1;
    // bstr(32) - tx hash (all zeros)
    tx_bytes[w] = 0x58;
    w += 1;
    tx_bytes[w] = 0x20;
    w += 1;
    @memset(tx_bytes[w..][0..32], 0x00);
    w += 32;
    // index = 3
    tx_bytes[w] = 0x03;
    w += 1;

    // key 11: script_data_hash
    tx_bytes[w] = 0x0B;
    w += 1;
    // bstr(32)
    tx_bytes[w] = 0x58;
    w += 1;
    tx_bytes[w] = 0x20;
    w += 1;
    @memset(tx_bytes[w..][0..32], 0x11);
    w += 32;

    // key 13: collateral
    tx_bytes[w] = 0x0D;
    w += 1;
    // array(1)
    tx_bytes[w] = 0x81;
    w += 1;
    // collateral input: array(2)
    tx_bytes[w] = 0x82;
    w += 1;
    // bstr(32) - tx hash (all 0xFF)
    tx_bytes[w] = 0x58;
    w += 1;
    tx_bytes[w] = 0x20;
    w += 1;
    @memset(tx_bytes[w..][0..32], 0xFF);
    w += 32;
    // index = 0
    tx_bytes[w] = 0x00;
    w += 1;

    // key 17: total_collateral = 500000
    tx_bytes[w] = 0x11;
    w += 1;
    // uint32: 1A 0007A120
    tx_bytes[w] = 0x1A;
    w += 1;
    tx_bytes[w] = 0x00;
    w += 1;
    tx_bytes[w] = 0x07;
    w += 1;
    tx_bytes[w] = 0xA1;
    w += 1;
    tx_bytes[w] = 0x20;
    w += 1;

    // --- Witness map(3) ---
    tx_bytes[w] = 0xA3;
    w += 1;

    // key 3: plutus v1 scripts
    tx_bytes[w] = 0x03;
    w += 1;
    // array(1)
    tx_bytes[w] = 0x81;
    w += 1;
    // bstr(3) script body
    tx_bytes[w] = 0x43;
    w += 1;
    tx_bytes[w] = 0xAA;
    w += 1;
    tx_bytes[w] = 0xBB;
    w += 1;
    tx_bytes[w] = 0xCC;
    w += 1;

    // key 4: datums
    tx_bytes[w] = 0x04;
    w += 1;
    // array(1)
    tx_bytes[w] = 0x81;
    w += 1;
    // bstr(1) datum
    tx_bytes[w] = 0x41;
    w += 1;
    tx_bytes[w] = 0xDD;
    w += 1;

    // key 5: redeemers
    tx_bytes[w] = 0x05;
    w += 1;
    // array(1) of 4-tuples
    tx_bytes[w] = 0x81;
    w += 1;
    // redeemer: array(4)
    tx_bytes[w] = 0x84;
    w += 1;
    // tag = 0 (spend)
    tx_bytes[w] = 0x00;
    w += 1;
    // index = 0
    tx_bytes[w] = 0x00;
    w += 1;
    // data: bstr(1)
    tx_bytes[w] = 0x41;
    w += 1;
    tx_bytes[w] = 0xEE;
    w += 1;
    // ex_units: array(2)
    tx_bytes[w] = 0x82;
    w += 1;
    // mem = 65536 (1A 00010000)
    tx_bytes[w] = 0x1A;
    w += 1;
    tx_bytes[w] = 0x00;
    w += 1;
    tx_bytes[w] = 0x01;
    w += 1;
    tx_bytes[w] = 0x00;
    w += 1;
    tx_bytes[w] = 0x00;
    w += 1;
    // steps = 131072 (1A 00020000)
    tx_bytes[w] = 0x1A;
    w += 1;
    tx_bytes[w] = 0x00;
    w += 1;
    tx_bytes[w] = 0x02;
    w += 1;
    tx_bytes[w] = 0x00;
    w += 1;
    tx_bytes[w] = 0x00;
    w += 1;

    const ctx = buildPlutusContext(tx_bytes[0..w]) orelse {
        return error.TestUnexpectedResult;
    };

    // Verify inputs
    try std.testing.expectEqual(@as(u32, 1), ctx.input_count);
    try std.testing.expectEqual(@as(u32, 3), ctx.inputs[0].index);

    // Verify collateral
    try std.testing.expectEqual(@as(u32, 1), ctx.collateral_count);
    try std.testing.expectEqual(@as(u32, 0), ctx.collateral_inputs[0].index);
    try std.testing.expectEqual(@as(u8, 0xFF), ctx.collateral_inputs[0].tx_hash[0]);

    // Verify total collateral
    try std.testing.expect(ctx.has_total_collateral);
    try std.testing.expectEqual(@as(u64, 500000), ctx.total_collateral);

    // Verify Plutus required
    try std.testing.expect(ctx.requires_plutus);

    // Verify scripts
    try std.testing.expectEqual(@as(u32, 1), ctx.script_count);
    try std.testing.expectEqual(@as(u8, 1), ctx.scripts[0].version); // V1

    // Verify datums
    try std.testing.expectEqual(@as(u32, 1), ctx.datum_count);

    // Verify redeemers
    try std.testing.expectEqual(@as(u32, 1), ctx.redeemer_count);
    try std.testing.expectEqual(RedeemerTag.spend, ctx.redeemers[0].tag);
    try std.testing.expectEqual(@as(u32, 0), ctx.redeemers[0].index);
    try std.testing.expectEqual(@as(u64, 65536), ctx.redeemers[0].ex_units_mem);
    try std.testing.expectEqual(@as(u64, 131072), ctx.redeemers[0].ex_units_steps);

    // Verify mapping coverage: spend redeemer index=0, input_count=1, so mapped=1
    try std.testing.expectEqual(@as(u32, 1), ctx.spend_redeemers_mapped);

    // Coverage should be 1.0 (1 mapped / 1 total redeemer)
    const cov = ctx.mappingCoverage();
    try std.testing.expect(cov > 0.99 and cov < 1.01);
}

test "evaluatePlutus: stub returns evaluator_not_implemented" {
    // Build a minimal context (empty is fine — stub ignores content)
    var ctx = PlutusExecutionContext{};
    ctx.requires_plutus = true;

    const result = evaluatePlutus(&ctx);

    try std.testing.expectEqual(false, result.success);
    try std.testing.expectEqual(EvalErrorCode.evaluator_not_implemented, result.error_code);
    try std.testing.expectEqual(@as(u64, 0), result.ex_units_mem);
    try std.testing.expectEqual(@as(u64, 0), result.ex_units_steps);
}

test "evaluateWithAdapter: none delegates to stub" {
    var ctx = PlutusExecutionContext{};
    ctx.requires_plutus = true;

    const result = evaluateWithAdapter(&ctx, .none);
    try std.testing.expectEqual(false, result.success);
    try std.testing.expectEqual(EvalErrorCode.evaluator_not_implemented, result.error_code);
}

test "evaluateWithAdapter: ffi returns backend_unavailable" {
    var ctx = PlutusExecutionContext{};
    ctx.requires_plutus = true;

    const result = evaluateWithAdapter(&ctx, .ffi);
    try std.testing.expectEqual(false, result.success);
    try std.testing.expectEqual(EvalErrorCode.backend_unavailable, result.error_code);
    try std.testing.expectEqual(@as(u64, 0), result.ex_units_mem);
    try std.testing.expectEqual(@as(u64, 0), result.ex_units_steps);
}
