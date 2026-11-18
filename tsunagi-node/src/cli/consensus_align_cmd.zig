const std = @import("std");
const compat = @import("compat");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;
const producer = @import("../producer/producer.zig");
const kes_verify = @import("../producer/crypto/kes_verify.zig");
const block_hash = @import("../net/ledger/block_hash.zig");
const cbor = @import("../net/cbor/term.zig");

/// Consensus equivalence verification harness (v3.2.0).
///
/// Verifies Tsunagi's Praos threshold, VRF→u mapping, and Header/Body/KES
/// computations against oracle-provided expected values from JSONL vectors.
///
/// Offline, deterministic, fail-fast. No forging, no broadcast, no injection.
///
/// Exit codes: 0=PASS, 2=mismatch, 3=file/args error, 4=parse/validation error.

const Mode = enum { praos, vrf, header, tx, all };

const VectorResult = enum { pass, fail, parse_error };

pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var vectors_path: ?[]const u8 = null;
    var mode: ?Mode = null;
    var verbose: bool = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--vectors")) {
            vectors_path = args_it.next() orelse {
                std.debug.print("ERROR: --vectors requires a path\n", .{});
                return 3;
            };
        } else if (std.mem.eql(u8, arg, "--mode")) {
            const mode_str = args_it.next() orelse {
                std.debug.print("ERROR: --mode requires praos|vrf|header|all\n", .{});
                return 3;
            };
            if (std.mem.eql(u8, mode_str, "praos")) {
                mode = .praos;
            } else if (std.mem.eql(u8, mode_str, "vrf")) {
                mode = .vrf;
            } else if (std.mem.eql(u8, mode_str, "header")) {
                mode = .header;
            } else if (std.mem.eql(u8, mode_str, "tx")) {
                mode = .tx;
            } else if (std.mem.eql(u8, mode_str, "all")) {
                mode = .all;
            } else {
                std.debug.print("ERROR: unknown mode '{s}', expected praos|vrf|header|tx|all\n", .{mode_str});
                return 3;
            }
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        }
    }

    const path = vectors_path orelse {
        std.debug.print("ERROR: --vectors <path.jsonl> is required\n", .{});
        return 3;
    };

    const m = mode orelse {
        std.debug.print("ERROR: --mode <praos|vrf|header|tx|all> is required\n", .{});
        return 3;
    };

    var file = compat.fs.cwd().openFile(path, .{}) catch {
        std.debug.print("ERROR: cannot open {s}\n", .{path});
        return 3;
    };
    defer file.close();

    std.debug.print("=== Consensus Align Harness ===\n", .{});
    std.debug.print("vectors: {s}\n", .{path});
    std.debug.print("mode: {s}\n\n", .{modeStr(m)});

    return processVectors(alloc, &file, m, verbose);
}

fn modeStr(m: Mode) []const u8 {
    return switch (m) {
        .praos => "praos",
        .vrf => "vrf",
        .header => "header",
        .tx => "tx",
        .all => "all",
    };
}

fn processVectors(alloc: std.mem.Allocator, file: *compat.fs.File, mode: Mode, verbose: bool) u8 {
    var line_buf: [32768]u8 = undefined;
    const buf_reader = file.deprecatedReader();
    var reader = buf_reader;

    var line_idx: usize = 0;
    var processed: usize = 0;
    var pass_count: usize = 0;
    var fail_count: usize = 0;
    var ignored: usize = 0;

    // Per-kind counters for --mode all
    var praos_count: usize = 0;
    var vrf_count: usize = 0;
    var header_count: usize = 0;
    var tx_count: usize = 0;

    while (true) {
        const line = reader.readUntilDelimiterOrEof(&line_buf, '\n') catch {
            std.debug.print("ERROR: read error at line {d}\n", .{line_idx + 1});
            return 3;
        };
        if (line == null) break;
        const content = line.?;
        if (content.len == 0) {
            line_idx += 1;
            continue;
        }

        // Parse kind field
        const kind_str = parseHexField(content, "\"kind\":\"") orelse {
            std.debug.print("ERROR: missing \"kind\" field at line {d}\n", .{line_idx + 1});
            return 4;
        };

        // Determine if this vector should be processed
        const is_praos = std.mem.eql(u8, kind_str, "praos");
        const is_vrf = std.mem.eql(u8, kind_str, "vrf");
        const is_header = std.mem.eql(u8, kind_str, "header");
        const is_tx = std.mem.eql(u8, kind_str, "tx");

        const should_process = switch (mode) {
            .praos => is_praos,
            .vrf => is_vrf,
            .header => is_header,
            .tx => is_tx,
            .all => is_praos or is_vrf or is_header or is_tx,
        };

        if (!should_process) {
            ignored += 1;
            line_idx += 1;
            continue;
        }

        // Dispatch to kind-specific processor
        const result: VectorResult = if (is_praos) blk: {
            praos_count += 1;
            break :blk processPraos(content, processed);
        } else if (is_vrf) blk: {
            vrf_count += 1;
            break :blk processVrf(content, processed);
        } else if (is_header) blk: {
            header_count += 1;
            break :blk processHeader(alloc, content, processed);
        } else if (is_tx) blk: {
            tx_count += 1;
            break :blk processTx(alloc, content, processed);
        } else {
            // Unknown kind in --mode all: ignore
            ignored += 1;
            line_idx += 1;
            continue;
        };

        switch (result) {
            .pass => {
                pass_count += 1;
                if (verbose) {
                    std.debug.print("  vector[{d}]: kind={s} PASS\n", .{ processed, kind_str });
                }
            },
            .fail => {
                fail_count += 1;
                // Fail details already printed by processor
                std.debug.print("\nCONSENSUS-ALIGN: mode={s} processed={d} pass={d} fail=1 ignored={d} EXIT=2\n", .{
                    modeStr(mode), processed + 1, pass_count, ignored,
                });
                return 2;
            },
            .parse_error => {
                std.debug.print("  at line {d}\n", .{line_idx + 1});
                return 4;
            },
        }

        processed += 1;
        line_idx += 1;
    }

    if (processed == 0) {
        std.debug.print("ERROR: no matching vectors found\n", .{});
        return 3;
    }

    const exit_code: u8 = if (fail_count > 0) 2 else 0;
    std.debug.print("\nCONSENSUS-ALIGN: mode={s} processed={d} pass={d} fail={d} ignored={d} EXIT={d}\n", .{
        modeStr(mode), processed, pass_count, fail_count, ignored, exit_code,
    });

    if (mode == .all) {
        std.debug.print("  per-kind: praos={d} vrf={d} header={d} tx={d}\n", .{ praos_count, vrf_count, header_count, tx_count });
    }

    return exit_code;
}

// ── Mode A: Praos ────────────────────────────────────────────────────

fn processPraos(line: []const u8, idx: usize) VectorResult {
    // Parse required fields
    const slot = parseU64Field(line, "\"slot\":") orelse {
        std.debug.print("ERROR: missing slot in praos vector[{d}]\n", .{idx});
        return .parse_error;
    };
    const stake = parseU64Field(line, "\"stake_fraction_x1e9\":") orelse {
        std.debug.print("ERROR: missing stake_fraction_x1e9 in praos vector[{d}]\n", .{idx});
        return .parse_error;
    };
    const asc = parseU64Field(line, "\"asc_x1e6\":") orelse {
        std.debug.print("ERROR: missing asc_x1e6 in praos vector[{d}]\n", .{idx});
        return .parse_error;
    };
    const vrf_hex = parseHexField(line, "\"vrf_output_hex\":\"") orelse {
        std.debug.print("ERROR: missing vrf_output_hex in praos vector[{d}]\n", .{idx});
        return .parse_error;
    };
    if (vrf_hex.len != 128) {
        std.debug.print("ERROR: vrf_output_hex must be 128 hex chars in praos vector[{d}]\n", .{idx});
        return .parse_error;
    }
    const expected_thresh = parseU64Field(line, "\"expected_threshold_x1e12\":") orelse {
        std.debug.print("ERROR: missing expected_threshold_x1e12 in praos vector[{d}]\n", .{idx});
        return .parse_error;
    };
    const expected_u = parseU64Field(line, "\"expected_u_x1e12\":") orelse {
        std.debug.print("ERROR: missing expected_u_x1e12 in praos vector[{d}]\n", .{idx});
        return .parse_error;
    };
    const expected_leader = parseBoolField(line, "\"expected_is_leader\":") orelse {
        std.debug.print("ERROR: missing expected_is_leader in praos vector[{d}]\n", .{idx});
        return .parse_error;
    };

    // Pre-validation: consistency check
    const consistent_leader = (expected_u < expected_thresh);
    if (expected_leader != consistent_leader) {
        std.debug.print("ERROR: expected_is_leader inconsistent with expected_u < expected_threshold in praos vector[{d}]\n", .{idx});
        return .parse_error;
    }

    // Decode VRF output
    var vrf_bytes: [64]u8 = undefined;
    if (!hexToBytes(vrf_hex, &vrf_bytes)) {
        std.debug.print("ERROR: invalid hex in vrf_output_hex in praos vector[{d}]\n", .{idx});
        return .parse_error;
    }

    // Check 1: threshold
    const computed_thresh = producer.computeThreshX1e12(stake, asc);
    if (computed_thresh != expected_thresh) {
        std.debug.print("FAIL: praos vector[{d}] slot={d} threshold mismatch: computed={d} expected={d}\n", .{
            idx, slot, computed_thresh, expected_thresh,
        });
        return .fail;
    }

    // Check 2: u
    const computed_u = producer.vrfOutputToU_x1e12(vrf_bytes);
    if (computed_u != expected_u) {
        std.debug.print("FAIL: praos vector[{d}] slot={d} u mismatch: computed={d} expected={d}\n", .{
            idx, slot, computed_u, expected_u,
        });
        return .fail;
    }

    // Check 3: is_leader
    const computed_leader = (computed_u < computed_thresh);
    if (computed_leader != expected_leader) {
        std.debug.print("FAIL: praos vector[{d}] slot={d} is_leader mismatch: computed={} expected={}\n", .{
            idx, slot, computed_leader, expected_leader,
        });
        return .fail;
    }

    return .pass;
}

// ── Mode B: VRF ──────────────────────────────────────────────────────

fn processVrf(line: []const u8, idx: usize) VectorResult {
    const vrf_hex = parseHexField(line, "\"vrf_output_hex\":\"") orelse {
        std.debug.print("ERROR: missing vrf_output_hex in vrf vector[{d}]\n", .{idx});
        return .parse_error;
    };
    if (vrf_hex.len != 128) {
        std.debug.print("ERROR: vrf_output_hex must be 128 hex chars in vrf vector[{d}]\n", .{idx});
        return .parse_error;
    }
    const expected_u = parseU64Field(line, "\"expected_u_x1e12\":") orelse {
        std.debug.print("ERROR: missing expected_u_x1e12 in vrf vector[{d}]\n", .{idx});
        return .parse_error;
    };

    var vrf_bytes: [64]u8 = undefined;
    if (!hexToBytes(vrf_hex, &vrf_bytes)) {
        std.debug.print("ERROR: invalid hex in vrf_output_hex in vrf vector[{d}]\n", .{idx});
        return .parse_error;
    }

    const computed_u = producer.vrfOutputToU_x1e12(vrf_bytes);
    if (computed_u != expected_u) {
        std.debug.print("FAIL: vrf vector[{d}] u mismatch: computed={d} expected={d}\n", .{
            idx, computed_u, expected_u,
        });
        return .fail;
    }

    return .pass;
}

// ── Mode C: Header/Body/KES ─────────────────────────────────────────

fn processHeader(alloc: std.mem.Allocator, line: []const u8, idx: usize) VectorResult {
    // Parse all required fields
    const slot = parseU64Field(line, "\"slot\":") orelse {
        std.debug.print("ERROR: missing slot in header vector[{d}]\n", .{idx});
        return .parse_error;
    };

    const header_hex = parseHexField(line, "\"header_bytes_hex\":\"") orelse {
        std.debug.print("ERROR: missing header_bytes_hex in header vector[{d}]\n", .{idx});
        return .parse_error;
    };
    if (header_hex.len % 2 != 0 or header_hex.len < 2 or header_hex.len > 16384) {
        std.debug.print("ERROR: invalid header_bytes_hex length in header vector[{d}]\n", .{idx});
        return .parse_error;
    }

    const header_hash_hex = parseHexField(line, "\"header_hash_hex\":\"") orelse {
        std.debug.print("ERROR: missing header_hash_hex in header vector[{d}]\n", .{idx});
        return .parse_error;
    };
    if (header_hash_hex.len != 64) {
        std.debug.print("ERROR: header_hash_hex must be 64 hex chars in header vector[{d}]\n", .{idx});
        return .parse_error;
    }

    const body_hash_hex = parseHexField(line, "\"body_hash_hex\":\"") orelse {
        std.debug.print("ERROR: missing body_hash_hex in header vector[{d}]\n", .{idx});
        return .parse_error;
    };
    if (body_hash_hex.len != 64) {
        std.debug.print("ERROR: body_hash_hex must be 64 hex chars in header vector[{d}]\n", .{idx});
        return .parse_error;
    }

    const kes_pk_hex = parseHexField(line, "\"kes_pk_hex\":\"") orelse {
        std.debug.print("ERROR: missing kes_pk_hex in header vector[{d}]\n", .{idx});
        return .parse_error;
    };
    if (kes_pk_hex.len != 64) {
        std.debug.print("ERROR: kes_pk_hex must be 64 hex chars in header vector[{d}]\n", .{idx});
        return .parse_error;
    }

    const kes_period_offset = parseU64Field(line, "\"kes_period_offset\":") orelse {
        std.debug.print("ERROR: missing kes_period_offset in header vector[{d}]\n", .{idx});
        return .parse_error;
    };

    const kes_sig_hex = parseHexField(line, "\"kes_sig_hex\":\"") orelse {
        std.debug.print("ERROR: missing kes_sig_hex in header vector[{d}]\n", .{idx});
        return .parse_error;
    };
    if (kes_sig_hex.len != 896) {
        std.debug.print("ERROR: kes_sig_hex must be 896 hex chars in header vector[{d}]\n", .{idx});
        return .parse_error;
    }

    const hdr_body_hex = parseHexField(line, "\"header_body_cbor_hex\":\"") orelse {
        std.debug.print("ERROR: missing header_body_cbor_hex in header vector[{d}]\n", .{idx});
        return .parse_error;
    };
    if (hdr_body_hex.len % 2 != 0 or hdr_body_hex.len < 2 or hdr_body_hex.len > 8192) {
        std.debug.print("ERROR: invalid header_body_cbor_hex length in header vector[{d}]\n", .{idx});
        return .parse_error;
    }

    // Decode hex fields to bytes
    const header_len = header_hex.len / 2;
    var header_bytes: [8192]u8 = undefined;
    if (!hexToBytes(header_hex, header_bytes[0..header_len])) {
        std.debug.print("ERROR: invalid hex in header_bytes_hex in header vector[{d}]\n", .{idx});
        return .parse_error;
    }

    var expected_header_hash: [32]u8 = undefined;
    if (!hexToBytes(header_hash_hex, &expected_header_hash)) {
        std.debug.print("ERROR: invalid hex in header_hash_hex in header vector[{d}]\n", .{idx});
        return .parse_error;
    }

    var expected_body_hash: [32]u8 = undefined;
    if (!hexToBytes(body_hash_hex, &expected_body_hash)) {
        std.debug.print("ERROR: invalid hex in body_hash_hex in header vector[{d}]\n", .{idx});
        return .parse_error;
    }

    var kes_pk: [32]u8 = undefined;
    if (!hexToBytes(kes_pk_hex, &kes_pk)) {
        std.debug.print("ERROR: invalid hex in kes_pk_hex in header vector[{d}]\n", .{idx});
        return .parse_error;
    }

    var kes_sig: [448]u8 = undefined;
    if (!hexToBytes(kes_sig_hex, &kes_sig)) {
        std.debug.print("ERROR: invalid hex in kes_sig_hex in header vector[{d}]\n", .{idx});
        return .parse_error;
    }

    const hdr_body_len = hdr_body_hex.len / 2;
    var hdr_body_bytes: [4096]u8 = undefined;
    if (!hexToBytes(hdr_body_hex, hdr_body_bytes[0..hdr_body_len])) {
        std.debug.print("ERROR: invalid hex in header_body_cbor_hex in header vector[{d}]\n", .{idx});
        return .parse_error;
    }

    // CHECK 1: header_hash = blake2b256(header_bytes)
    const computed_header_hash = block_hash.blake2b256(header_bytes[0..header_len]);
    if (!std.mem.eql(u8, &computed_header_hash, &expected_header_hash)) {
        var computed_hex: [64]u8 = undefined;
        bytesToHex(&computed_header_hash, &computed_hex);
        std.debug.print("FAIL: header vector[{d}] slot={d} header_hash mismatch\n", .{ idx, slot });
        std.debug.print("  computed: {s}\n", .{&computed_hex});
        std.debug.print("  expected: {s}\n", .{header_hash_hex});
        return .fail;
    }

    // CHECK 2: body_hash extracted from decoded header matches body_hash_hex
    const header_term = cbor.decodeOrRaw(alloc, header_bytes[0..header_len]) catch {
        std.debug.print("FAIL: header vector[{d}] slot={d} CBOR decode failed\n", .{ idx, slot });
        return .fail;
    };
    defer cbor.free(header_term, alloc);

    const extracted_body_hash = block_hash.extractBodyHashFromHeader(header_term) orelse {
        std.debug.print("FAIL: header vector[{d}] slot={d} could not extract body_hash from header\n", .{ idx, slot });
        return .fail;
    };
    if (!std.mem.eql(u8, &extracted_body_hash, &expected_body_hash)) {
        var computed_hex: [64]u8 = undefined;
        bytesToHex(&extracted_body_hash, &computed_hex);
        std.debug.print("FAIL: header vector[{d}] slot={d} body_hash mismatch\n", .{ idx, slot });
        std.debug.print("  computed: {s}\n", .{&computed_hex});
        std.debug.print("  expected: {s}\n", .{body_hash_hex});
        return .fail;
    }

    // CHECK 3: KES signature verification
    const kes_result = kes_verify.verifySum6Kes(
        kes_pk,
        @intCast(kes_period_offset),
        hdr_body_bytes[0..hdr_body_len],
        &kes_sig,
    );
    if (kes_result != .ok) {
        std.debug.print("FAIL: header vector[{d}] slot={d} kes_verify={s}\n", .{
            idx, slot, kes_verify.resultStr(kes_result),
        });
        return .fail;
    }

    return .pass;
}

// ── Mode D: TX-body inclusion ────────────────────────────────────────

fn processTx(alloc: std.mem.Allocator, line: []const u8, idx: usize) VectorResult {
    const slot = parseU64Field(line, "\"slot\":") orelse {
        std.debug.print("ERROR: missing slot in tx vector[{d}]\n", .{idx});
        return .parse_error;
    };
    const expected_tx_count = parseU64Field(line, "\"tx_count\":") orelse {
        std.debug.print("ERROR: missing tx_count in tx vector[{d}]\n", .{idx});
        return .parse_error;
    };

    // Parse included_tx_hashes array — store start offsets into line buffer
    var hash_offsets: [256]usize = undefined;
    var n_hashes: usize = 0;
    if (!parseTxHashArray(line, &hash_offsets, &n_hashes)) {
        std.debug.print("ERROR: cannot parse included_tx_hashes in tx vector[{d}]\n", .{idx});
        return .parse_error;
    }

    // Metadata validation
    if (n_hashes == 0) {
        if (expected_tx_count != 0) {
            std.debug.print("ERROR: tx_count={d} but included_tx_hashes is empty in tx vector[{d}]\n", .{ expected_tx_count, idx });
            return .parse_error;
        }
        // tx_count=0, PASS
        return .pass;
    }
    if (expected_tx_count != n_hashes) {
        std.debug.print("ERROR: tx_count={d} != included_tx_hashes.len={d} in tx vector[{d}]\n", .{ expected_tx_count, n_hashes, idx });
        return .parse_error;
    }

    // Load block bytes: try block_cbor_hex first, else block_dir/block.cbor
    var block_bytes_alloc: ?[]u8 = null;
    defer if (block_bytes_alloc) |b| alloc.free(b);

    var block_bytes: []const u8 = undefined;

    const cbor_hex = parseHexField(line, "\"block_cbor_hex\":\"");
    if (cbor_hex) |hex| {
        if (hex.len % 2 != 0 or hex.len < 2) {
            std.debug.print("ERROR: invalid block_cbor_hex length in tx vector[{d}]\n", .{idx});
            return .parse_error;
        }
        const byte_len = hex.len / 2;
        const buf = alloc.alloc(u8, byte_len) catch {
            std.debug.print("ERROR: alloc failed for block_cbor_hex in tx vector[{d}]\n", .{idx});
            return .parse_error;
        };
        block_bytes_alloc = buf;
        if (!hexToBytes(hex, buf)) {
            std.debug.print("ERROR: invalid hex in block_cbor_hex in tx vector[{d}]\n", .{idx});
            return .parse_error;
        }
        block_bytes = buf;
    } else {
        // Load from disk: block_dir/block.cbor
        const block_dir = parseHexField(line, "\"block_dir\":\"") orelse {
            std.debug.print("ERROR: missing block_dir in tx vector[{d}] (block_cbor_hex is null)\n", .{idx});
            return .parse_error;
        };
        const disk_bytes = readBlockFromDisk(alloc, block_dir) orelse {
            std.debug.print("FAIL: tx vector[{d}] slot={d} cannot read {s}/block.cbor\n", .{ idx, slot, block_dir });
            return .fail;
        };
        block_bytes_alloc = disk_bytes;
        block_bytes = disk_bytes;
    }

    // Extract body parts using proven code path
    const parts = block_hash.extractBodyParts(block_bytes) orelse {
        std.debug.print("FAIL: tx vector[{d}] slot={d} extractBodyParts failed (fail-closed)\n", .{ idx, slot });
        return .fail;
    };

    // Verify inclusion: every txid in included_tx_hashes must be present
    for (0..n_hashes) |i| {
        const hash_hex = line[hash_offsets[i] .. hash_offsets[i] + 64];
        if (!block_hash.findTxidInBodies(parts.tx_bodies, hash_hex)) {
            std.debug.print("FAIL: tx vector[{d}] slot={d} txid not found: {s}\n", .{ idx, slot, hash_hex });
            return .fail;
        }
    }

    return .pass;
}

fn readBlockFromDisk(alloc: std.mem.Allocator, block_dir: []const u8) ?[]u8 {
    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/block.cbor", .{block_dir}) catch return null;
    var file = compat.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    // Allocate up to 128KB for block bytes
    const buf = alloc.alloc(u8, 131072) catch return null;
    const n = file.readAll(buf) catch {
        alloc.free(buf);
        return null;
    };
    if (n == 0) {
        alloc.free(buf);
        return null;
    }
    return buf[0..n];
}

/// Parse "included_tx_hashes":["<64hex>","<64hex>",...] from JSON line.
/// Stores the byte offset of each 64-char hex string in out_offsets.
/// Returns true on success, sets out_count to number of hashes found.
fn parseTxHashArray(json: []const u8, out_offsets: *[256]usize, out_count: *usize) bool {
    const needle = "\"included_tx_hashes\":[";
    const start = std.mem.indexOf(u8, json, needle) orelse return false;
    var pos = start + needle.len;
    var count: usize = 0;

    while (pos < json.len) {
        // Skip whitespace and commas
        while (pos < json.len and (json[pos] == ' ' or json[pos] == ',')) : (pos += 1) {}
        if (pos >= json.len) return false;
        if (json[pos] == ']') break;
        if (json[pos] != '"') return false;
        pos += 1; // skip opening quote

        if (pos + 64 > json.len) return false;
        if (count >= 256) return false;
        out_offsets[count] = pos;
        pos += 64;

        if (pos >= json.len or json[pos] != '"') return false;
        pos += 1; // skip closing quote
        count += 1;
    }

    out_count.* = count;
    return true;
}

// ── JSON field parsers ────────────────────────────────────────────────

fn parseU64Field(json: []const u8, needle: []const u8) ?u64 {
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const val_start = start + needle.len;
    var end = val_start;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
    if (end == val_start) return null;
    return std.fmt.parseInt(u64, json[val_start..end], 10) catch null;
}

fn parseHexField(json: []const u8, needle: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const val_start = start + needle.len;
    const end = std.mem.indexOfPos(u8, json, val_start, "\"") orelse return null;
    if (end == val_start) return null;
    return json[val_start..end];
}

fn parseBoolField(json: []const u8, needle: []const u8) ?bool {
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const val_start = start + needle.len;
    if (val_start + 4 <= json.len and std.mem.eql(u8, json[val_start .. val_start + 4], "true")) return true;
    if (val_start + 5 <= json.len and std.mem.eql(u8, json[val_start .. val_start + 5], "false")) return false;
    return null;
}

// ── Hex utilities ─────────────────────────────────────────────────────

fn hexToBytes(hex: []const u8, out: []u8) bool {
    if (hex.len != out.len * 2) return false;
    for (0..out.len) |i| {
        const hi = hexDigit(hex[i * 2]) orelse return false;
        const lo = hexDigit(hex[i * 2 + 1]) orelse return false;
        out[i] = (@as(u8, hi) << 4) | @as(u8, lo);
    }
    return true;
}

fn hexDigit(ch: u8) ?u4 {
    if (ch >= '0' and ch <= '9') return @intCast(ch - '0');
    if (ch >= 'a' and ch <= 'f') return @intCast(ch - 'a' + 10);
    if (ch >= 'A' and ch <= 'F') return @intCast(ch - 'A' + 10);
    return null;
}

fn bytesToHex(bytes: []const u8, out: []u8) void {
    const hex_chars = "0123456789abcdef";
    for (0..bytes.len) |i| {
        out[i * 2] = hex_chars[bytes[i] >> 4];
        out[i * 2 + 1] = hex_chars[bytes[i] & 0xf];
    }
}
