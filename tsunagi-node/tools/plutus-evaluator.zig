// Standalone protocol-conformant external evaluator binary.
// Speaks TSUNAGI external evaluator protocol v1.
//
// Two evaluation paths:
//   1. Known-case: blake2b256 fingerprint of serialized context matches a
//      known boundary case. Returns pre-computed result. This is NOT general
//      Plutus execution — it is a known serialized-context boundary case.
//   2. Rule-based: structured deterministic rules identical to
//      evaluateMinimalRules() in eval_external.zig.
//
// Diagnostic: prints backend_mode to stderr (not in protocol response).
//
// Reads protocol v1 JSON from stdin, writes protocol v1 JSON to stdout.
// Pure Zig, no TSUNAGI module imports, no libc, no external dependencies.

const std = @import("std");
const compat = @import("compat");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

const PROTOCOL_VERSION: u32 = 1;
const MAX_INPUT: usize = 4096;

// Known-case fingerprint: blake2b256 of the serialized context JSON for the
// synthetic Plutus V1 spending tx (1 input, 1 collateral, 1 script, 1 redeemer,
// 1 datum, total_collateral=500000, spend_redeemers_mapped=1).
// Provenance: synthetic_structural — hand-crafted, not from chain.
const KNOWN_CASE_V1_SPEND_FP = [32]u8{
    0xbd, 0x70, 0x98, 0x82, 0xf8, 0xcc, 0x96, 0x5c,
    0xb9, 0x48, 0xd6, 0xb7, 0x12, 0x36, 0x8e, 0x6e,
    0x93, 0xff, 0x54, 0xf7, 0xf1, 0x74, 0x57, 0x27,
    0xd6, 0x48, 0xd4, 0xa0, 0x82, 0xa2, 0x61, 0xaa,
};
// Pre-computed result for this known case (from evaluateMinimalRules):
// mem = 1*1000 + 1*500 = 1500, steps = 1*2000 + 1*1000 = 3000
const KNOWN_CASE_V1_SPEND_MEM: u64 = 1500;
const KNOWN_CASE_V1_SPEND_STEPS: u64 = 3000;

pub fn main() !void {
    var stdin = compat.fs.File.stdin();
    var buf: [MAX_INPUT]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = stdin.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    const data = buf[0..total];
    var stdout_file = compat.fs.File.stdout();
    var stderr_file = compat.fs.File.stderr();
    const stdout = stdout_file.writer();
    const stderr = stderr_file.writer();

    // Validate protocol version — must be present and must match exactly
    const version = findNumberAfter(data, "\"protocol_version\":") orelse {
        try writeResult(stdout, false, 6, 0, 0);
        return;
    };
    if (version != PROTOCOL_VERSION) {
        try writeResult(stdout, false, 6, 0, 0);
        return;
    }

    // Known-case path: fingerprint match against known boundary cases
    if (total > 0) {
        var fingerprint: [32]u8 = undefined;
        Blake2b256.hash(data, &fingerprint, .{});
        if (std.mem.eql(u8, &fingerprint, &KNOWN_CASE_V1_SPEND_FP)) {
            stderr.print("EVAL_BACKEND: mode=known_case case=v1_spend\n", .{}) catch {};
            try writeResult(stdout, true, 0, KNOWN_CASE_V1_SPEND_MEM, KNOWN_CASE_V1_SPEND_STEPS);
            return;
        }
    }

    // Rule-based path: structured deterministic rules
    stderr.print("EVAL_BACKEND: mode=rule_based\n", .{}) catch {};

    const redeemer_count = findNumberAfter(data, "\"redeemer_count\":") orelse 0;
    const script_count = findNumberAfter(data, "\"script_count\":") orelse 0;
    const datum_count = findNumberAfter(data, "\"datum_count\":") orelse 0;
    const spend_mapped = findNumberAfter(data, "\"spend_redeemers_mapped\":") orelse 0;

    if (redeemer_count == 0) {
        try writeResult(stdout, false, 4, 0, 0);
    } else if (script_count == 0) {
        try writeResult(stdout, false, 2, 0, 0);
    } else if (spend_mapped == 0) {
        try writeResult(stdout, false, 3, 0, 0);
    } else if (datum_count == 0) {
        try writeResult(stdout, false, 2, 0, 0);
    } else {
        try writeResult(stdout, true, 0, redeemer_count * 1000 + script_count * 500, redeemer_count * 2000 + script_count * 1000);
    }
}

fn writeResult(w: anytype, success: bool, err_code: u64, mem: u64, steps: u64) !void {
    try w.print(
        "{{\"protocol_version\":1,\"success\":{s},\"error_code\":{d},\"ex_units_mem\":{d},\"ex_units_steps\":{d}}}",
        .{ if (success) "true" else "false", err_code, mem, steps },
    );
}

/// Find a number immediately after a literal key string.
/// Self-contained — no TSUNAGI module imports.
fn findNumberAfter(data: []const u8, key: []const u8) ?u64 {
    if (data.len < key.len) return null;
    var i: usize = 0;
    while (i + key.len <= data.len) : (i += 1) {
        if (std.mem.eql(u8, data[i..][0..key.len], key)) {
            const start = i + key.len;
            var end = start;
            while (end < data.len and data[end] >= '0' and data[end] <= '9') : (end += 1) {}
            if (end == start) return null;
            return std.fmt.parseUnsigned(u64, data[start..end], 10) catch null;
        }
    }
    return null;
}
