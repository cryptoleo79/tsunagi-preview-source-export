const std = @import("std");
const compat = @import("compat");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;
const block_hash = @import("../net/ledger/block_hash.zig");

/// Block candidate verification CLI (v2.0.0-alpha, B5; extended v2.1.0-a).
///
/// Verifies a block candidate directory written by the producer dryrun:
///   CHECK 1: blake2b256(block_header.cbor) == block_header_hash.hex
///   CHECK 2: computeBodyHash(extractBodyParts(block.cbor)) == block_body_hash.hex
///   CHECK 3: header region in block.cbor == block_header.cbor (byte-for-byte)
///   CHECK 4 (optional): --expect-tx-hash <hex> is found in included_tx_hashes.json
///
/// Usage: zig build run -- block-candidate-verify --dir <dryrun_slot_dir> [--expect-tx-hash <64hex>]
///
/// Exit codes: 0=all pass, 2=mismatch, 3=IO/parse error.

pub fn run(_: std.mem.Allocator, args_it: anytype) u8 {
    var dir_path: ?[]const u8 = null;
    var expect_tx_hash: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dir")) {
            dir_path = args_it.next() orelse {
                std.debug.print("ERROR: --dir requires a path\n", .{});
                return 3;
            };
        } else if (std.mem.eql(u8, arg, "--expect-tx-hash")) {
            expect_tx_hash = args_it.next() orelse {
                std.debug.print("ERROR: --expect-tx-hash requires a 64-char hex string\n", .{});
                return 3;
            };
        }
    }

    const dir = dir_path orelse {
        std.debug.print("ERROR: --dir <path> is required\n", .{});
        return 3;
    };

    // Read artifact files
    var block_buf: [8192]u8 = undefined;
    const block_len = readArtifact(dir, "block.cbor", &block_buf) orelse {
        std.debug.print("ERROR: cannot read {s}/block.cbor\n", .{dir});
        return 3;
    };
    const block_cbor = block_buf[0..block_len];

    var hdr_buf: [4096]u8 = undefined;
    const hdr_len = readArtifact(dir, "block_header.cbor", &hdr_buf) orelse {
        std.debug.print("ERROR: cannot read {s}/block_header.cbor\n", .{dir});
        return 3;
    };
    const header_cbor = hdr_buf[0..hdr_len];

    var hdr_hash_buf: [128]u8 = undefined;
    const hdr_hash_len = readArtifact(dir, "block_header_hash.hex", &hdr_hash_buf) orelse {
        std.debug.print("ERROR: cannot read {s}/block_header_hash.hex\n", .{dir});
        return 3;
    };

    var body_hash_buf: [128]u8 = undefined;
    const body_hash_len = readArtifact(dir, "block_body_hash.hex", &body_hash_buf) orelse {
        std.debug.print("ERROR: cannot read {s}/block_body_hash.hex\n", .{dir});
        return 3;
    };

    std.debug.print("=== Block Candidate Verify ===\ndir={s}\n\n", .{dir});

    var checks_pass: u32 = 0;
    var checks_fail: u32 = 0;

    // CHECK 1: header_hash = blake2b256(block_header.cbor) matches block_header_hash.hex
    {
        var computed: [32]u8 = undefined;
        Blake2b256.hash(header_cbor, &computed, .{});
        const computed_hex = std.fmt.bytesToHex(computed, .lower);
        if (hdr_hash_len >= 64 and std.mem.eql(u8, &computed_hex, hdr_hash_buf[0..64])) {
            checks_pass += 1;
            std.debug.print("CHECK 1 PASS: header_hash = blake2b256(block_header.cbor) [{d} bytes]\n", .{hdr_len});
        } else {
            checks_fail += 1;
            std.debug.print("CHECK 1 FAIL: header_hash mismatch\n  computed: {s}\n  expected: {s}\n", .{
                @as([]const u8, &computed_hex),
                hdr_hash_buf[0..@min(64, hdr_hash_len)],
            });
        }
    }

    // CHECK 2: body_hash from extractBodyParts(block.cbor) matches block_body_hash.hex
    if (block_hash.extractBodyParts(block_cbor)) |parts| {
        const computed = block_hash.computeBodyHash(parts);
        const computed_hex = std.fmt.bytesToHex(computed, .lower);
        if (body_hash_len >= 64 and std.mem.eql(u8, &computed_hex, body_hash_buf[0..64])) {
            checks_pass += 1;
            std.debug.print("CHECK 2 PASS: body_hash from extractBodyParts(block.cbor)\n", .{});
        } else {
            checks_fail += 1;
            std.debug.print("CHECK 2 FAIL: body_hash mismatch\n  computed: {s}\n  expected: {s}\n", .{
                @as([]const u8, &computed_hex),
                body_hash_buf[0..@min(64, body_hash_len)],
            });
        }
    } else {
        checks_fail += 1;
        std.debug.print("CHECK 2 FAIL: cannot parse block.cbor body parts\n", .{});
    }

    // CHECK 3: header region in block.cbor matches block_header.cbor
    if (extractHeaderRegion(block_cbor)) |region| {
        if (region.len == header_cbor.len and std.mem.eql(u8, region, header_cbor)) {
            checks_pass += 1;
            std.debug.print("CHECK 3 PASS: block.cbor header region == block_header.cbor ({d} bytes)\n", .{region.len});
        } else {
            checks_fail += 1;
            std.debug.print("CHECK 3 FAIL: header region mismatch (block.cbor={d} bytes, artifact={d} bytes)\n", .{ region.len, header_cbor.len });
        }
    } else {
        checks_fail += 1;
        std.debug.print("CHECK 3 FAIL: cannot parse block.cbor header region\n", .{});
    }

    // CHECK 4 (v2.1.2): --expect-tx-hash verified from block body (with metadata fallback)
    if (expect_tx_hash) |expected_hex| {
        if (expected_hex.len != 64) {
            checks_fail += 1;
            std.debug.print("CHECK 4 FAIL: --expect-tx-hash must be 64 hex chars, got {d}\n", .{expected_hex.len});
        } else {
            // Try body verification: extract tx_bodies from block.cbor, compute txid for each
            var body_verified = false;
            var body_has_txs = false;
            if (block_hash.extractBodyParts(block_cbor)) |parts| {
                if (parts.tx_bodies.len > 1) {
                    body_has_txs = true;
                    body_verified = block_hash.findTxidInBodies(parts.tx_bodies, expected_hex);
                }
            }

            if (body_verified) {
                checks_pass += 1;
                std.debug.print("CHECK 4 PASS: tx_hash {s} found in block body (txid verified from tx_bodies)\n", .{expected_hex});
            } else if (body_has_txs) {
                // Body has txs but expected txid not found — genuine failure
                checks_fail += 1;
                std.debug.print("CHECK 4 FAIL: tx_hash {s} NOT found in block body tx_bodies\n", .{expected_hex});
            } else {
                // Body is empty — fallback to metadata check (pre-v2.1.2 blocks)
                var tx_hashes_buf: [64 * 1024]u8 = undefined;
                const tx_hashes_len = readArtifact(dir, "included_tx_hashes.json", &tx_hashes_buf);
                if (tx_hashes_len) |tlen| {
                    const json_data = tx_hashes_buf[0..tlen];
                    if (std.mem.indexOf(u8, json_data, expected_hex) != null) {
                        checks_pass += 1;
                        std.debug.print("CHECK 4 PASS: tx_hash {s} found in included_tx_hashes.json (metadata-only, body empty)\n", .{expected_hex});
                    } else {
                        checks_fail += 1;
                        std.debug.print("CHECK 4 FAIL: tx_hash {s} NOT found in block body or metadata\n", .{expected_hex});
                    }
                } else {
                    checks_fail += 1;
                    std.debug.print("CHECK 4 FAIL: tx_hash {s} NOT found in block body, no metadata available\n", .{expected_hex});
                }
            }
        }
    }

    // Summary
    std.debug.print("\nchecks_pass={d} checks_fail={d}\n", .{ checks_pass, checks_fail });
    if (checks_fail > 0) {
        std.debug.print("EXIT=2\n", .{});
        return 2;
    }
    std.debug.print("EXIT=0\n", .{});
    return 0;
}

/// Extract the header CBOR region from full block bytes.
/// Block structure: 0x82 <era> 0x85 <header> <tx_bodies> <witnesses> <aux_data> <invalid_txs>
fn extractHeaderRegion(block_bytes: []const u8) ?[]const u8 {
    if (block_bytes.len < 4) return null;
    var pos: usize = 0;

    // Outer array(2): 0x82
    if (block_bytes[pos] != 0x82) return null;
    pos += 1;

    // Skip era element
    const era_size = block_hash.skipCborElement(block_bytes[pos..]) orelse return null;
    pos += era_size;

    // Inner array(5): 0x85
    if (pos >= block_bytes.len or block_bytes[pos] != 0x85) return null;
    pos += 1;

    // Header element
    const header_start = pos;
    const header_size = block_hash.skipCborElement(block_bytes[pos..]) orelse return null;

    return block_bytes[header_start .. header_start + header_size];
}

/// Read an artifact file from a directory into a stack buffer.
fn readArtifact(dir: []const u8, name: []const u8, buf: []u8) ?usize {
    var path_buf: [600]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return null;
    var f = compat.fs.cwd().openFile(path, .{ .mode = .read_only }) catch return null;
    defer f.close();
    const n = f.readAll(buf) catch return null;
    return n;
}
