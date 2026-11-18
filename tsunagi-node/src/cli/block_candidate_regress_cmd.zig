const std = @import("std");
const compat = @import("compat");
const kes_verify = @import("../producer/crypto/kes_verify.zig");

/// Block candidate oracle lock-in CLI.
///
/// Verifies Sum6Kes signatures from JSONL vectors extracted from real
/// block candidate artifacts. Pure drift guard — no baselines, no init mode.
///
/// JSONL vector schema:
///   {"slot":<u64>,"header_hash_hex":"<64hex>","body_hash_hex":"<64hex>",
///    "kes_pk_hex":"<hex>","kes_period_offset":<u64>,"sig_hex":"<hex>",
///    "header_body_cbor_hex":"<hex>"}
///
/// Fail-fast on first mismatch (exit 2).
/// Exit codes: 0=all pass, 2=verification failure, 3=parse/file/IO error.

pub fn run(_: std.mem.Allocator, args_it: anytype) u8 {
    var vectors_path: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--vectors")) {
            vectors_path = args_it.next() orelse {
                std.debug.print("ERROR: --vectors requires a path\n", .{});
                return 3;
            };
        }
    }

    const path = vectors_path orelse {
        std.debug.print("ERROR: --vectors <path.jsonl> is required\n", .{});
        return 3;
    };

    var file = compat.fs.cwd().openFile(path, .{}) catch {
        std.debug.print("ERROR: cannot open {s}\n", .{path});
        return 3;
    };
    defer file.close();

    std.debug.print("=== Block Candidate Regress (Oracle Lock-in) ===\n\n", .{});

    var total: usize = 0;
    var line_buf: [32768]u8 = undefined;
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

        const vec = parseVector(content) orelse {
            std.debug.print("FAIL: vector[{d}] parse error\n", .{total});
            return 3;
        };

        // Verify Sum6Kes signature
        const result = kes_verify.verifySum6Kes(
            vec.kes_pk,
            @intCast(vec.kes_period_offset),
            vec.header_body_cbor[0..vec.header_body_cbor_len],
            &vec.sig,
        );

        if (result != .ok) {
            std.debug.print("FAIL: vector[{d}] slot={d} kes_verify={s}\n", .{
                total, vec.slot, kes_verify.resultStr(result),
            });
            std.debug.print("\nBLOCK-CANDIDATE-REGRESS: vectors={d} EXIT=2\n", .{total + 1});
            return 2;
        }

        std.debug.print("  vector[{d}]: slot={d} kes_period_offset={d} kes_verify=OK PASS\n", .{
            total, vec.slot, vec.kes_period_offset,
        });

        total += 1;
    }

    if (total == 0) {
        std.debug.print("ERROR: no vectors found in {s}\n", .{path});
        return 3;
    }

    std.debug.print("\nBLOCK-CANDIDATE-REGRESS: vectors={d} all PASS EXIT=0\n", .{total});
    return 0;
}

// ── Parsed vector ─────────────────────────────────────────────────────

const ParsedVector = struct {
    slot: u64,
    kes_period_offset: u64,
    kes_pk: [32]u8,
    sig: [448]u8,
    header_body_cbor: [4096]u8,
    header_body_cbor_len: usize,
};

fn parseVector(line: []const u8) ?ParsedVector {
    // Parse slot
    const slot = parseUintField(line, "\"slot\":") orelse return null;

    // Parse kes_period_offset
    const kes_period_offset = parseUintField(line, "\"kes_period_offset\":") orelse return null;

    // Parse kes_pk_hex (64 hex chars = 32 bytes)
    const kes_pk_hex = parseHexField(line, "\"kes_pk_hex\":\"") orelse return null;
    if (kes_pk_hex.len != 64) return null;
    var kes_pk: [32]u8 = undefined;
    if (!hexToBytes(kes_pk_hex, &kes_pk)) return null;

    // Parse sig_hex (896 hex chars = 448 bytes)
    const sig_hex = parseHexField(line, "\"sig_hex\":\"") orelse return null;
    if (sig_hex.len != 896) return null;
    var sig: [448]u8 = undefined;
    if (!hexToBytes(sig_hex, &sig)) return null;

    // Parse header_body_cbor_hex (variable length)
    const cbor_hex = parseHexField(line, "\"header_body_cbor_hex\":\"") orelse return null;
    if (cbor_hex.len < 2 or cbor_hex.len > 8192 or cbor_hex.len % 2 != 0) return null;
    const cbor_len = cbor_hex.len / 2;
    var cbor_bytes: [4096]u8 = undefined;
    if (!hexToBytes(cbor_hex, cbor_bytes[0..cbor_len])) return null;

    return ParsedVector{
        .slot = slot,
        .kes_period_offset = kes_period_offset,
        .kes_pk = kes_pk,
        .sig = sig,
        .header_body_cbor = cbor_bytes,
        .header_body_cbor_len = cbor_len,
    };
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
    // skip whitespace
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
