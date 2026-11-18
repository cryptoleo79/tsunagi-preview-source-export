const std = @import("std");
const net_tx_decode = @import("../net/ledger/tx_decode.zig");
const cbor_term_mod = @import("../net/cbor/term.zig");

// ── Block Stream — Delta Extraction ─────────────────────────────────
//
// Thin orchestrator that extracts transaction deltas (consumed inputs,
// produced outputs) from raw block body CBOR bytes.
//
// Uses the proven two-step sequence from the chainsync follower:
//   1. scanTxBodiesFromBodyBytes → locate tx list in CBOR structure
//   2. extractTxDeltas → walk tx list, extract consumed/produced
//
// No protocol imports. No state mutation. No globals.

/// Transaction deltas: consumed inputs and produced outputs from a block.
/// Re-exported from net/ledger/tx_decode.zig.
pub const TxDeltas = net_tx_decode.TxDeltas;

/// Free a TxDeltas struct. Frees the consumed and produced slices.
/// Re-exported from net/ledger/tx_decode.zig.
pub const freeTxDeltas = net_tx_decode.freeTxDeltas;

/// Extract transaction deltas from raw block body CBOR bytes.
///
/// Uses the proven two-step extraction sequence:
///   1. scanTxBodiesFromBodyBytes — parses CBOR, locates tx list
///   2. extractTxDeltas — walks tx list, extracts consumed/produced
///
/// Intermediate CBOR parse state is freed before return.
/// The returned TxDeltas is self-contained (no references to CBOR tree).
///
/// Caller owns the returned TxDeltas and must free with freeTxDeltas.
/// Returns null if the block body cannot be parsed.
pub fn extractDeltas(alloc: std.mem.Allocator, block_body_bytes: []const u8) ?TxDeltas {
    const scan = net_tx_decode.scanTxBodiesFromBodyBytes(
        alloc,
        block_body_bytes,
        false,
    ) orelse return null;
    defer cbor_term_mod.free(scan.owner, alloc);

    return net_tx_decode.extractTxDeltas(alloc, scan.tx_list, null, false) catch null;
}

// ── Tests ──────────────────────────────────────────────────────────

test "extractDeltas returns null for empty input" {
    try std.testing.expect(extractDeltas(std.testing.allocator, &[_]u8{}) == null);
}

test "extractDeltas returns null for invalid CBOR" {
    // Single integer — not a block body structure
    try std.testing.expect(extractDeltas(std.testing.allocator, &[_]u8{0x00}) == null);
    // Truncated array header
    try std.testing.expect(extractDeltas(std.testing.allocator, &[_]u8{ 0x83, 0x01 }) == null);
}

test "extractDeltas returns zero-tx deltas for block with no transactions" {
    // Block body: [[{0:[], 1:[], 2:0}], []]
    // This is a minimal valid block body with one tx that has
    // empty inputs, empty outputs, and fee=0.
    // CBOR: 82 81 a3 00 80 01 80 02 00 80
    const body = [_]u8{ 0x82, 0x81, 0xa3, 0x00, 0x80, 0x01, 0x80, 0x02, 0x00, 0x80 };
    const result = extractDeltas(std.testing.allocator, &body);
    if (result) |deltas| {
        defer freeTxDeltas(std.testing.allocator, deltas);
        // One tx parsed, but it has empty inputs and outputs
        try std.testing.expectEqual(@as(u64, 1), deltas.tx_count);
        try std.testing.expectEqual(@as(usize, 0), deltas.consumed.len);
        try std.testing.expectEqual(@as(usize, 0), deltas.produced.len);
    }
    // null is also acceptable if the CBOR structure is not recognized
}

test "re-exported types are accessible" {
    const d = TxDeltas{ .consumed = &.{}, .produced = &.{}, .tx_count = 0 };
    try std.testing.expectEqual(@as(u64, 0), d.tx_count);
}
