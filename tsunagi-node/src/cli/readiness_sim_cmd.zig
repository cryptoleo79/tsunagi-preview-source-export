const std = @import("std");
const compat = @import("compat");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;
const block_hash = @import("../net/ledger/block_hash.zig");
const kes_verify = @import("../producer/crypto/kes_verify.zig");
const cbor = @import("../net/cbor/term.zig");

/// Readiness simulation — batch offline verification of block candidate vectors.
///
/// Processes JSONL vectors and produces a deterministic rolling digest:
///   CHECK A: blake2b256(block_header_cbor) == block_header_hash_hex
///   CHECK B: computeBodyHash(extractBodyParts(block_cbor)) == block_body_hash_hex
///   CHECK C: verifySum6Kes(kes_pk, kes_period_offset, header_body_cbor, sig)
///
/// Usage: tsunagi-node readiness-sim --vectors <file.jsonl> --out <report.json>
///
/// Exit codes: 0=all pass, 2=any check failed, 3=IO/parse error.

pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var vectors_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var header_only = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--vectors")) {
            vectors_path = args_it.next() orelse {
                std.debug.print("ERROR: --vectors requires a path\n", .{});
                return 3;
            };
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_path = args_it.next() orelse {
                std.debug.print("ERROR: --out requires a path\n", .{});
                return 3;
            };
        } else if (std.mem.eql(u8, arg, "--header-only")) {
            header_only = true;
        }
    }

    const vpath = vectors_path orelse {
        std.debug.print("ERROR: --vectors <path.jsonl> is required\n", .{});
        return 3;
    };

    const opath = out_path orelse {
        std.debug.print("ERROR: --out <report.json> is required\n", .{});
        return 3;
    };

    var file = compat.fs.cwd().openFile(vpath, .{}) catch {
        std.debug.print("ERROR: cannot open {s}\n", .{vpath});
        return 3;
    };
    defer file.close();

    std.debug.print("=== Readiness-Sim (batch offline verification) ===\n\n", .{});

    // Rolling digest
    var rolling = Blake2b256.init(.{});

    // Counters
    var total: usize = 0;
    var pass_a: usize = 0;
    var pass_b: usize = 0;
    var pass_c: usize = 0;
    var any_fail = false;

    var line_buf: [65536]u8 = undefined;
    const buf_reader = file.deprecatedReader();
    var reader = buf_reader;

    while (true) {
        const line = reader.readUntilDelimiterOrEof(&line_buf, '\n') catch {
            std.debug.print("ERROR: read error at line {d}\n", .{total + 1});
            return 3;
        };
        if (line == null) break;
        const content = line.?;
        if (content.len == 0) continue;

        // Parse vector fields
        const slot = parseUintField(content, "\"slot\":") orelse {
            std.debug.print("FAIL: vector[{d}] missing slot\n", .{total});
            return 3;
        };

        const block_no = parseUintField(content, "\"block_no\":") orelse 0;

        // Parse kes_pk_hex (64 hex = 32 bytes)
        const kes_pk_hex = parseHexField(content, "\"kes_pk_hex\":\"") orelse {
            std.debug.print("FAIL: vector[{d}] missing kes_pk_hex\n", .{total});
            return 3;
        };
        if (kes_pk_hex.len != 64) {
            std.debug.print("FAIL: vector[{d}] kes_pk_hex len={d}\n", .{ total, kes_pk_hex.len });
            return 3;
        }
        var kes_pk: [32]u8 = undefined;
        if (!hexToBytes(kes_pk_hex, &kes_pk)) {
            std.debug.print("FAIL: vector[{d}] kes_pk_hex decode\n", .{total});
            return 3;
        }

        const kes_period_offset = parseUintField(content, "\"kes_period_offset\":") orelse {
            std.debug.print("FAIL: vector[{d}] missing kes_period_offset\n", .{total});
            return 3;
        };

        // Parse sig_hex (896 hex = 448 bytes)
        const sig_hex = parseHexField(content, "\"sig_hex\":\"") orelse {
            std.debug.print("FAIL: vector[{d}] missing sig_hex\n", .{total});
            return 3;
        };
        if (sig_hex.len != 896) {
            std.debug.print("FAIL: vector[{d}] sig_hex len={d}\n", .{ total, sig_hex.len });
            return 3;
        }
        var sig: [448]u8 = undefined;
        if (!hexToBytes(sig_hex, &sig)) {
            std.debug.print("FAIL: vector[{d}] sig_hex decode\n", .{total});
            return 3;
        }

        // Parse block_header_cbor_hex (variable length)
        const hdr_cbor_hex = parseHexField(content, "\"block_header_cbor_hex\":\"") orelse {
            std.debug.print("FAIL: vector[{d}] missing block_header_cbor_hex\n", .{total});
            return 3;
        };
        if (hdr_cbor_hex.len < 2 or hdr_cbor_hex.len > 8192 or hdr_cbor_hex.len % 2 != 0) {
            std.debug.print("FAIL: vector[{d}] block_header_cbor_hex len={d}\n", .{ total, hdr_cbor_hex.len });
            return 3;
        }
        const hdr_cbor_len = hdr_cbor_hex.len / 2;
        var hdr_cbor_buf: [4096]u8 = undefined;
        if (!hexToBytes(hdr_cbor_hex, hdr_cbor_buf[0..hdr_cbor_len])) {
            std.debug.print("FAIL: vector[{d}] block_header_cbor_hex decode\n", .{total});
            return 3;
        }
        const block_header_cbor = hdr_cbor_buf[0..hdr_cbor_len];

        // Parse block_header_hash_hex (64 hex = 32 bytes)
        const hdr_hash_hex = parseHexField(content, "\"block_header_hash_hex\":\"") orelse {
            std.debug.print("FAIL: vector[{d}] missing block_header_hash_hex\n", .{total});
            return 3;
        };
        if (hdr_hash_hex.len != 64) {
            std.debug.print("FAIL: vector[{d}] block_header_hash_hex len={d}\n", .{ total, hdr_hash_hex.len });
            return 3;
        }
        var block_header_hash: [32]u8 = undefined;
        if (!hexToBytes(hdr_hash_hex, &block_header_hash)) {
            std.debug.print("FAIL: vector[{d}] block_header_hash_hex decode\n", .{total});
            return 3;
        }

        // Parse block_cbor_hex (variable length; may be null in header-only mode)
        const blk_cbor_hex = parseHexField(content, "\"block_cbor_hex\":\"");
        var blk_cbor_buf: [65536]u8 = undefined;
        var block_cbor: ?[]const u8 = null;
        if (blk_cbor_hex) |hex| {
            if (hex.len >= 2 and hex.len <= 131072 and hex.len % 2 == 0) {
                const blk_cbor_len = hex.len / 2;
                if (hexToBytes(hex, blk_cbor_buf[0..blk_cbor_len])) {
                    block_cbor = blk_cbor_buf[0..blk_cbor_len];
                }
            }
        }
        if (block_cbor == null and !header_only) {
            std.debug.print("FAIL: vector[{d}] missing block_cbor_hex (not in --header-only mode)\n", .{total});
            return 3;
        }

        // Parse block_body_hash_hex (64 hex = 32 bytes)
        const body_hash_hex = parseHexField(content, "\"block_body_hash_hex\":\"") orelse {
            std.debug.print("FAIL: vector[{d}] missing block_body_hash_hex\n", .{total});
            return 3;
        };
        if (body_hash_hex.len != 64) {
            std.debug.print("FAIL: vector[{d}] block_body_hash_hex len={d}\n", .{ total, body_hash_hex.len });
            return 3;
        }
        var block_body_hash: [32]u8 = undefined;
        if (!hexToBytes(body_hash_hex, &block_body_hash)) {
            std.debug.print("FAIL: vector[{d}] block_body_hash_hex decode\n", .{total});
            return 3;
        }

        // Parse header_body_cbor_hex (variable length)
        const hb_cbor_hex = parseHexField(content, "\"header_body_cbor_hex\":\"") orelse {
            std.debug.print("FAIL: vector[{d}] missing header_body_cbor_hex\n", .{total});
            return 3;
        };
        if (hb_cbor_hex.len < 2 or hb_cbor_hex.len > 8192 or hb_cbor_hex.len % 2 != 0) {
            std.debug.print("FAIL: vector[{d}] header_body_cbor_hex len={d}\n", .{ total, hb_cbor_hex.len });
            return 3;
        }
        const hb_cbor_len = hb_cbor_hex.len / 2;
        var hb_cbor_buf: [4096]u8 = undefined;
        if (!hexToBytes(hb_cbor_hex, hb_cbor_buf[0..hb_cbor_len])) {
            std.debug.print("FAIL: vector[{d}] header_body_cbor_hex decode\n", .{total});
            return 3;
        }
        const header_body_cbor = hb_cbor_buf[0..hb_cbor_len];

        // ── CHECK A: Header hash ─────────────────────────────────────
        var check_a = false;
        {
            var computed: [32]u8 = undefined;
            Blake2b256.hash(block_header_cbor, &computed, .{});
            check_a = std.mem.eql(u8, &computed, &block_header_hash);
        }

        // ── CHECK B: Body hash ───────────────────────────────────────
        var check_b = false;
        if (block_cbor) |bc| {
            // Full block mode: compute body hash from block body parts
            if (block_hash.extractBodyParts(bc)) |parts| {
                const computed = block_hash.computeBodyHash(parts);
                check_b = std.mem.eql(u8, &computed, &block_body_hash);
            }
        } else {
            // Header-only mode: extract body_hash from decoded header CBOR
            if (cbor.decodeOrRaw(alloc, block_header_cbor)) |header_term| {
                defer cbor.free(header_term, alloc);
                if (block_hash.extractBodyHashFromHeader(header_term)) |extracted| {
                    check_b = std.mem.eql(u8, &extracted, &block_body_hash);
                }
            } else |_| {
                std.debug.print("FAIL: vector[{d}] header-only CBOR decode failed\n", .{total});
            }
        }

        // ── CHECK C: KES signature ───────────────────────────────────
        var check_c = false;
        {
            const result = kes_verify.verifySum6Kes(
                kes_pk,
                @intCast(kes_period_offset),
                header_body_cbor,
                &sig,
            );
            check_c = (result == .ok);
        }

        // ── Update counters ──────────────────────────────────────────
        if (check_a) pass_a += 1;
        if (check_b) pass_b += 1;
        if (check_c) pass_c += 1;
        if (!check_a or !check_b or !check_c) any_fail = true;

        // ── Rolling digest: 75-byte canonical entry ──────────────────
        var entry: [75]u8 = undefined;
        std.mem.writeInt(u64, entry[0..8], slot, .big);
        @memcpy(entry[8..40], &block_header_hash);
        @memcpy(entry[40..72], &block_body_hash);
        entry[72] = if (check_a) 1 else 0;
        entry[73] = if (check_b) 1 else 0;
        entry[74] = if (check_c) 1 else 0;
        rolling.update(&entry);

        // ── Per-vector output ────────────────────────────────────────
        std.debug.print("  vector[{d}]: slot={d} block_no={d} A={s} B={s} C={s}\n", .{
            total,
            slot,
            block_no,
            if (check_a) "PASS" else "FAIL",
            if (check_b) "PASS" else "FAIL",
            if (check_c) "PASS" else "FAIL",
        });

        total += 1;
    }

    if (total == 0) {
        std.debug.print("ERROR: no vectors found in {s}\n", .{vpath});
        return 3;
    }

    // ── Finalize rolling digest ──────────────────────────────────────
    var digest: [32]u8 = undefined;
    rolling.final(&digest);
    const digest_hex = std.fmt.bytesToHex(digest, .lower);

    // ── Write report JSON ────────────────────────────────────────────
    var report_buf: [2048]u8 = undefined;
    const report = std.fmt.bufPrint(&report_buf,
        \\{{"vectors_processed":{d},"all_pass":{s},"rolling_digest_hex":"{s}","checks":{{"A_header_hash":{d},"B_body_hash":{d},"C_kes_verify":{d}}}}}
    , .{
        total,
        if (!any_fail) "true" else "false",
        @as([]const u8, &digest_hex),
        pass_a,
        pass_b,
        pass_c,
    }) catch {
        std.debug.print("ERROR: report buffer overflow\n", .{});
        return 3;
    };

    var out_file = compat.fs.cwd().createFile(opath, .{}) catch {
        std.debug.print("ERROR: cannot create {s}\n", .{opath});
        return 3;
    };
    defer out_file.close();
    out_file.writeAll(report) catch {
        std.debug.print("ERROR: cannot write {s}\n", .{opath});
        return 3;
    };

    // ── Summary ──────────────────────────────────────────────────────
    std.debug.print("\nREADINESS-SIM: vectors={d} digest={s} {s}\n", .{
        total,
        @as([]const u8, &digest_hex),
        if (!any_fail) "ALL PASS EXIT=0" else "FAIL EXIT=2",
    });
    std.debug.print("report: {s}\n", .{opath});

    if (any_fail) return 2;
    return 0;
}

// ── JSON field parsers ────────────────────────────────────────────────

fn parseHexField(json: []const u8, needle: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const val_start = start + needle.len;
    const end = std.mem.indexOfPos(u8, json, val_start, "\"") orelse return null;
    if (end == val_start) return null;
    return json[val_start..end];
}

fn parseUintField(json: []const u8, needle: []const u8) ?u64 {
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    var pos = start + needle.len;
    while (pos < json.len and json[pos] == ' ') pos += 1;
    if (pos >= json.len) return null;
    var val: u64 = 0;
    var found = false;
    while (pos < json.len and json[pos] >= '0' and json[pos] <= '9') {
        val = val *% 10 +% (json[pos] - '0');
        found = true;
        pos += 1;
    }
    if (!found) return null;
    return val;
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
