const std = @import("std");
const compat = @import("compat");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;
const block_hash = @import("../net/ledger/block_hash.zig");
const kes_verify = @import("../producer/crypto/kes_verify.zig");

/// Forge simulation harness — offline, disk-only, no network, no broadcast.
///
/// Validates a block candidate directory for forge readiness:
///   CHECK A: blake2b256(block_header.cbor) == header_hash.hex
///   CHECK B: computeBodyHash(extractBodyParts(block.cbor)) == body_hash.hex
///   CHECK C: verifySum6Kes(kes_pk, kes_period_offset, header_body.cbor, signature.bin)
///   CHECK D: tx inclusion integrity (conditional on included_tx_hashes.json)
///
/// Usage: tsunagi-node forge-sim --dir <dryrun_slot_dir> --out <report.json>
///
/// Exit codes: 0=PASS, 2=FAIL, 3=missing files, 4=parse errors.

pub fn run(_: std.mem.Allocator, args_it: anytype) u8 {
    var dir_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dir")) {
            dir_path = args_it.next() orelse {
                std.debug.print("ERROR: --dir requires a path\n", .{});
                return 4;
            };
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_path = args_it.next() orelse {
                std.debug.print("ERROR: --out requires a path\n", .{});
                return 4;
            };
        }
    }

    const dir = dir_path orelse {
        std.debug.print("ERROR: --dir <path> is required\n", .{});
        return 4;
    };

    const out = out_path orelse {
        std.debug.print("ERROR: --out <report.json> is required\n", .{});
        return 4;
    };

    // ── Read REQUIRED artifacts ──────────────────────────────────────

    var block_buf: [64 * 1024]u8 = undefined;
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

    var hdr_body_buf: [4096]u8 = undefined;
    const hdr_body_len = readArtifact(dir, "header_body.cbor", &hdr_body_buf) orelse {
        std.debug.print("ERROR: cannot read {s}/header_body.cbor\n", .{dir});
        return 3;
    };
    const header_body_cbor = hdr_body_buf[0..hdr_body_len];

    var sig_buf: [512]u8 = undefined;
    const sig_len = readArtifact(dir, "signature.bin", &sig_buf) orelse {
        std.debug.print("ERROR: cannot read {s}/signature.bin\n", .{dir});
        return 3;
    };
    const sig_bytes = sig_buf[0..sig_len];

    var hdr_hash_buf: [128]u8 = undefined;
    const hdr_hash_len = readArtifact(dir, "block_header_hash.hex", &hdr_hash_buf) orelse {
        std.debug.print("ERROR: cannot read {s}/block_header_hash.hex\n", .{dir});
        return 3;
    };
    const hdr_hash_hex = std.mem.trimEnd(u8, hdr_hash_buf[0..hdr_hash_len], "\n\r ");

    var body_hash_buf: [128]u8 = undefined;
    const body_hash_len = readArtifact(dir, "block_body_hash.hex", &body_hash_buf) orelse {
        std.debug.print("ERROR: cannot read {s}/block_body_hash.hex\n", .{dir});
        return 3;
    };
    const body_hash_hex = std.mem.trimEnd(u8, body_hash_buf[0..body_hash_len], "\n\r ");

    var meta_buf: [4096]u8 = undefined;
    const meta_len = readArtifact(dir, "meta.json", &meta_buf) orelse {
        std.debug.print("ERROR: cannot read {s}/meta.json\n", .{dir});
        return 3;
    };
    const meta_data = meta_buf[0..meta_len];

    // ── Parse meta.json ──────────────────────────────────────────────

    const kes_pk_hex_str = extractJsonString(meta_data, "\"kes_pk_hex\":\"") orelse {
        std.debug.print("ERROR: meta.json missing kes_pk_hex\n", .{});
        return 4;
    };
    if (kes_pk_hex_str.len != 64) {
        std.debug.print("ERROR: kes_pk_hex must be 64 hex chars, got {d}\n", .{kes_pk_hex_str.len});
        return 4;
    }
    var kes_pk: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&kes_pk, kes_pk_hex_str) catch {
        std.debug.print("ERROR: kes_pk_hex invalid hex\n", .{});
        return 4;
    };

    const kes_period_offset = extractJsonUint(meta_data, "\"kes_period_offset\":") orelse {
        std.debug.print("ERROR: meta.json missing kes_period_offset\n", .{});
        return 4;
    };

    // Best-effort: slot, block_no
    const slot = extractJsonUint(meta_data, "\"slot\":");
    const block_no = extractJsonUint(meta_data, "\"block_no\":");

    // ── CHECK A: Header hash ─────────────────────────────────────────

    var check_a: CheckResult = .fail;
    var computed_hdr_hash_hex: [64]u8 = undefined;
    {
        var computed: [32]u8 = undefined;
        Blake2b256.hash(header_cbor, &computed, .{});
        computed_hdr_hash_hex = std.fmt.bytesToHex(computed, .lower);
        if (hdr_hash_hex.len >= 64 and std.mem.eql(u8, &computed_hdr_hash_hex, hdr_hash_hex[0..64])) {
            check_a = .pass;
        }
    }

    // ── CHECK B: Body hash (proven code path) ────────────────────────

    var check_b: CheckResult = .fail;
    var computed_body_hash_hex: [64]u8 = undefined;
    if (block_hash.extractBodyParts(block_cbor)) |parts| {
        const computed = block_hash.computeBodyHash(parts);
        computed_body_hash_hex = std.fmt.bytesToHex(computed, .lower);
        if (body_hash_hex.len >= 64 and std.mem.eql(u8, &computed_body_hash_hex, body_hash_hex[0..64])) {
            check_b = .pass;
        }
    } else {
        computed_body_hash_hex = std.mem.zeroes([64]u8);
    }

    // ── CHECK C: KES signature verify ────────────────────────────────

    var check_c: CheckResult = .fail;
    var kes_result_str: []const u8 = "unknown";
    {
        const result = kes_verify.verifySum6Kes(
            kes_pk,
            @intCast(kes_period_offset),
            header_body_cbor,
            sig_bytes,
        );
        kes_result_str = kes_verify.resultStr(result);
        if (result == .ok) {
            check_c = .pass;
        }
    }

    // ── CHECK D: Tx inclusion integrity (conditional) ────────────────

    var check_d: CheckResult = .skip;
    var tx_count: ?u64 = null;
    {
        var tx_hashes_buf: [64 * 1024]u8 = undefined;
        const tx_hashes_len = readArtifact(dir, "included_tx_hashes.json", &tx_hashes_buf);
        if (tx_hashes_len) |tlen| {
            // included_tx_hashes.json exists — FAIL-CLOSED if we can't verify
            const tx_json = tx_hashes_buf[0..tlen];

            // Parse expected txids from JSON array
            var expected_txids: [256][64]u8 = undefined;
            var n_expected: usize = 0;
            {
                var pos: usize = 0;
                while (pos < tx_json.len) : (pos += 1) {
                    if (tx_json[pos] == '"') {
                        const start = pos + 1;
                        const end_q = std.mem.indexOfPos(u8, tx_json, start, "\"") orelse break;
                        const hex_str = tx_json[start..end_q];
                        if (hex_str.len == 64 and n_expected < expected_txids.len) {
                            @memcpy(&expected_txids[n_expected], hex_str);
                            n_expected += 1;
                        }
                        pos = end_q;
                    }
                }
            }
            tx_count = n_expected;

            if (n_expected == 0) {
                // Empty array — trivially passes
                check_d = .pass;
            } else {
                // Try to verify from block body using proven code path
                if (block_hash.extractBodyParts(block_cbor)) |parts| {
                    if (parts.tx_bodies.len > 1) {
                        // Body has txs — verify each expected txid
                        var all_found = true;
                        for (0..n_expected) |i| {
                            if (!block_hash.findTxidInBodies(parts.tx_bodies, &expected_txids[i])) {
                                all_found = false;
                                break;
                            }
                        }
                        check_d = if (all_found) .pass else .fail;
                    } else {
                        // Body is empty but included_tx_hashes.json exists with txids
                        // FAIL-CLOSED: cannot verify tx inclusion
                        check_d = .fail;
                    }
                } else {
                    // Cannot parse block body — FAIL-CLOSED
                    check_d = .fail;
                }
            }
        }
        // If included_tx_hashes.json doesn't exist: check_d stays .skip
    }

    // ── Overall result ───────────────────────────────────────────────

    const required_pass = (check_a == .pass and check_b == .pass and check_c == .pass);
    const d_ok = (check_d == .skip or check_d == .pass);
    const overall_pass = required_pass and d_ok;

    // ── Write report JSON ────────────────────────────────────────────

    var report_buf: [2048]u8 = undefined;

    // Build notes (one line per failed check max, bounded)
    var notes_buf: [256]u8 = undefined;
    var notes_len: usize = 0;
    if (check_a == .fail) notes_len += (std.fmt.bufPrint(notes_buf[notes_len..], "A: header_hash mismatch", .{}) catch @as([]const u8, &.{})).len;
    if (check_b == .fail) {
        if (notes_len > 0) notes_len += (std.fmt.bufPrint(notes_buf[notes_len..], "; ", .{}) catch @as([]const u8, &.{})).len;
        notes_len += (std.fmt.bufPrint(notes_buf[notes_len..], "B: body_hash mismatch", .{}) catch @as([]const u8, &.{})).len;
    }
    if (check_c == .fail) {
        if (notes_len > 0) notes_len += (std.fmt.bufPrint(notes_buf[notes_len..], "; ", .{}) catch @as([]const u8, &.{})).len;
        notes_len += (std.fmt.bufPrint(notes_buf[notes_len..], "C: kes_verify={s}", .{kes_result_str}) catch @as([]const u8, &.{})).len;
    }
    if (check_d == .fail) {
        if (notes_len > 0) notes_len += (std.fmt.bufPrint(notes_buf[notes_len..], "; ", .{}) catch @as([]const u8, &.{})).len;
        notes_len += (std.fmt.bufPrint(notes_buf[notes_len..], "D: tx_inclusion fail", .{}) catch @as([]const u8, &.{})).len;
    }

    // Format slot/block_no/tx_count as number or null
    var slot_str_buf: [24]u8 = undefined;
    const slot_str = if (slot) |s| (std.fmt.bufPrint(&slot_str_buf, "{d}", .{s}) catch "null") else "null";
    var bno_str_buf: [24]u8 = undefined;
    const bno_str = if (block_no) |b| (std.fmt.bufPrint(&bno_str_buf, "{d}", .{b}) catch "null") else "null";
    var txc_str_buf: [24]u8 = undefined;
    const txc_str = if (tx_count) |t| (std.fmt.bufPrint(&txc_str_buf, "{d}", .{t}) catch "null") else "null";

    // Body hash for report: use computed if available, else use on-disk hex
    const body_hash_report: []const u8 = if (check_b == .pass) @as([]const u8, &computed_body_hash_hex) else body_hash_hex;

    // Format notes suffix
    var notes_suffix_buf: [300]u8 = undefined;
    const notes_suffix = if (notes_len > 0)
        (std.fmt.bufPrint(&notes_suffix_buf, ",\"notes\":\"{s}\"", .{notes_buf[0..notes_len]}) catch "")
    else
        @as([]const u8, "");

    const report = std.fmt.bufPrint(&report_buf,
        \\{{"dir":"{s}","slot":{s},"block_no":{s},"kes_period_offset":{d},"header_hash":"{s}","body_hash":"{s}","tx_count":{s},"checks":{{"A_header_hash":"{s}","B_body_hash":"{s}","C_kes_verify":"{s}","D_tx_inclusion":"{s}"}},"overall":"{s}"{s}}}
    , .{
        dir,
        slot_str,
        bno_str,
        kes_period_offset,
        @as([]const u8, &computed_hdr_hash_hex),
        body_hash_report,
        txc_str,
        checkStr(check_a),
        checkStr(check_b),
        checkStr(check_c),
        checkStr(check_d),
        if (overall_pass) "PASS" else "FAIL",
        notes_suffix,
    }) catch {
        std.debug.print("ERROR: report buffer overflow\n", .{});
        return 4;
    };

    // Write report file
    var out_file = compat.fs.cwd().createFile(out, .{}) catch {
        std.debug.print("ERROR: cannot create {s}\n", .{out});
        return 4;
    };
    defer out_file.close();
    out_file.writeAll(report) catch {
        std.debug.print("ERROR: cannot write {s}\n", .{out});
        return 4;
    };

    // ── Bounded stdout ───────────────────────────────────────────────

    std.debug.print("{s}\n", .{if (overall_pass) "PASS" else "FAIL"});
    std.debug.print("report: {s}\n", .{out});
    if (report.len <= 300) {
        std.debug.print("{s}\n", .{report});
    } else {
        std.debug.print("{s}...\n", .{report[0..300]});
    }

    if (overall_pass) return 0;
    return 2;
}

// ── Helpers ──────────────────────────────────────────────────────────

const CheckResult = enum { pass, fail, skip };

fn checkStr(r: CheckResult) []const u8 {
    return switch (r) {
        .pass => "PASS",
        .fail => "FAIL",
        .skip => "SKIP",
    };
}

fn readArtifact(dir: []const u8, name: []const u8, buf: []u8) ?usize {
    var path_buf: [600]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return null;
    var f = compat.fs.cwd().openFile(path, .{ .mode = .read_only }) catch return null;
    defer f.close();
    const n = f.readAll(buf) catch return null;
    return n;
}

fn extractJsonString(data: []const u8, key: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, data, key) orelse return null;
    const start = pos + key.len;
    if (start >= data.len) return null;
    const end = std.mem.indexOfPos(u8, data, start, "\"") orelse return null;
    return data[start..end];
}

fn extractJsonUint(data: []const u8, key: []const u8) ?u64 {
    const pos = std.mem.indexOf(u8, data, key) orelse return null;
    const start = pos + key.len;
    if (start >= data.len) return null;
    var end = start;
    while (end < data.len and data[end] >= '0' and data[end] <= '9') : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(u64, data[start..end], 10) catch null;
}
