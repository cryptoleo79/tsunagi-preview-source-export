// ---------------------------------------------------------------------------
// Phase 18: External-Process Evaluator Backend Prototype
// Proves the backend boundary by serializing PlutusExecutionContext,
// spawning an external evaluator binary, and parsing the result.
// TSUNAGI does not execute Plutus — this is transport/protocol only.
// ---------------------------------------------------------------------------

const std = @import("std");
const compat = @import("compat");
const tx_decode = @import("tx_decode.zig");

const PlutusExecutionContext = tx_decode.PlutusExecutionContext;
const ExecutionResult = tx_decode.ExecutionResult;
const EvalErrorCode = tx_decode.EvalErrorCode;

const MAX_SERIAL_BUF = 4096;
const MAX_RESULT_BUF = 512;
const EVAL_BIN_NAME = "plutus-evaluator";

/// TSUNAGI external evaluator protocol version.
/// Both request and response must include this exact version.
/// No feature negotiation. No backward compatibility. Strict match required.
pub const PROTOCOL_VERSION: u32 = 1;

/// Resolve evaluator binary path from $TSUNAGI_HOME/bin/plutus-evaluator.
/// Returns null if TSUNAGI_HOME is unset or path would overflow buffer.
pub fn resolveEvaluatorPath(buf: *[512]u8) ?[]const u8 {
    const home = compat.getenv("TSUNAGI_HOME") orelse return null;
    const suffix = "/bin/" ++ EVAL_BIN_NAME;
    if (home.len + suffix.len >= buf.len) return null;
    @memcpy(buf[0..home.len], home);
    @memcpy(buf[home.len..][0..suffix.len], suffix);
    return buf[0 .. home.len + suffix.len];
}

/// Serialize PlutusExecutionContext to a fixed buffer as deterministic JSON.
/// Includes protocol_version as first field. Fixed field ordering, no dynamic keys, no allocator.
/// Returns bytes written, or null on buffer overflow.
pub fn serializeContext(ctx: *const PlutusExecutionContext, buf: *[MAX_SERIAL_BUF]u8) ?usize {
    var stream = compat.fixedBufferStream(buf);
    const w = stream.writer();
    w.print(
        "{{" ++
            "\"protocol_version\":{d}," ++
            "\"input_count\":{d}," ++
            "\"collateral_count\":{d}," ++
            "\"ref_input_count\":{d}," ++
            "\"script_count\":{d}," ++
            "\"redeemer_count\":{d}," ++
            "\"datum_count\":{d}," ++
            "\"requires_plutus\":{s}," ++
            "\"has_total_collateral\":{s}," ++
            "\"total_collateral\":{d}," ++
            "\"has_collateral_return\":{s}," ++
            "\"spend_redeemers_mapped\":{d}" ++
            "}}",
        .{
            PROTOCOL_VERSION,
            ctx.input_count,
            ctx.collateral_count,
            ctx.ref_input_count,
            ctx.script_count,
            ctx.redeemer_count,
            ctx.datum_count,
            if (ctx.requires_plutus) "true" else "false",
            if (ctx.has_total_collateral) "true" else "false",
            ctx.total_collateral,
            if (ctx.has_collateral_return) "true" else "false",
            ctx.spend_redeemers_mapped,
        },
    ) catch return null;
    return stream.pos;
}

/// Parse an ExecutionResult from JSON bytes.
/// Minimal byte-level scanner — no std.json, no allocator.
/// Requires protocol_version to match PROTOCOL_VERSION exactly.
/// Returns backend_invalid_response on malformed input or version mismatch.
pub fn parseResult(data: []const u8) ExecutionResult {
    if (data.len == 0) return .{ .error_code = .backend_invalid_response };

    // Protocol version gate — must be present and must match exactly.
    // No feature negotiation, no backward compatibility.
    if (findNumberAfter(data, "\"protocol_version\":")) |v| {
        if (v != PROTOCOL_VERSION) return .{ .error_code = .backend_invalid_response };
    } else {
        return .{ .error_code = .backend_invalid_response };
    }

    var result = ExecutionResult{
        .success = false,
        .error_code = .backend_invalid_response,
        .ex_units_mem = 0,
        .ex_units_steps = 0,
    };

    // Scan for "success":true/false
    if (findField(data, "\"success\":true")) {
        result.success = true;
        result.error_code = .none;
    } else if (findField(data, "\"success\":false")) {
        result.success = false;
    } else {
        return result; // malformed — no success field
    }

    // Scan for "error_code":N
    if (findNumberAfter(data, "\"error_code\":")) |code| {
        if (code <= @intFromEnum(EvalErrorCode.backend_invalid_response)) {
            result.error_code = @enumFromInt(@as(u8, @intCast(code)));
        }
    }

    // Scan for "ex_units_mem":N
    if (findNumberAfter(data, "\"ex_units_mem\":")) |v| {
        result.ex_units_mem = v;
    }

    // Scan for "ex_units_steps":N
    if (findNumberAfter(data, "\"ex_units_steps\":")) |v| {
        result.ex_units_steps = v;
    }

    return result;
}

/// Check if a literal substring exists in data.
fn findField(data: []const u8, needle: []const u8) bool {
    if (data.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= data.len) : (i += 1) {
        if (std.mem.eql(u8, data[i..][0..needle.len], needle)) return true;
    }
    return false;
}

/// Find a number immediately after a literal key string.
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

// ---------------------------------------------------------------------------
// Phase 21: Minimal Rule-Based Evaluator (Embedded Backend)
// First real execution experiment. NOT Plutus. Deterministic rules only.
// Proves the embedded backend path without process spawning.
// ---------------------------------------------------------------------------

/// Structured rule-based evaluator — NOT Plutus.
/// Applies deterministic rules directly to PlutusExecutionContext.
/// Same rules as tools/plutus-evaluator.zig and tools/plutus-evaluator.sh.
pub fn evaluateMinimalRules(ctx: *const PlutusExecutionContext) ExecutionResult {
    // Rule 1: no redeemers → script_failed
    if (ctx.redeemer_count == 0) return .{
        .success = false,
        .error_code = .script_failed,
        .ex_units_mem = 0,
        .ex_units_steps = 0,
    };
    // Rule 2: no scripts → missing_context
    if (ctx.script_count == 0) return .{
        .success = false,
        .error_code = .missing_context,
        .ex_units_mem = 0,
        .ex_units_steps = 0,
    };
    // Rule 3: redeemers + scripts present but zero spend redeemers mapped → invalid_redeemer
    if (ctx.spend_redeemers_mapped == 0) return .{
        .success = false,
        .error_code = .invalid_redeemer,
        .ex_units_mem = 0,
        .ex_units_steps = 0,
    };
    // Rule 4: no datums with scripts present → missing_context
    if (ctx.datum_count == 0) return .{
        .success = false,
        .error_code = .missing_context,
        .ex_units_mem = 0,
        .ex_units_steps = 0,
    };
    // Rule 5: success — deterministic ex_units
    const r = @as(u64, ctx.redeemer_count);
    const s = @as(u64, ctx.script_count);
    return .{
        .success = true,
        .error_code = .none,
        .ex_units_mem = r * 1000 + s * 500,
        .ex_units_steps = r * 2000 + s * 1000,
    };
}

/// Evaluate via external process backend.
/// Resolves evaluator path, serializes context, spawns process, parses result.
/// Returns backend_unavailable if binary not found or not configured.
/// Returns backend_invalid_response if output is malformed.
pub fn evaluateExternal(ctx: *const PlutusExecutionContext) ExecutionResult {
    // Resolve evaluator binary path
    var path_buf: [512]u8 = undefined;
    const path = resolveEvaluatorPath(&path_buf) orelse return .{
        .success = false,
        .error_code = .backend_unavailable,
        .ex_units_mem = 0,
        .ex_units_steps = 0,
    };

    // Check binary exists
    compat.fs.accessAbsolute(path, .{}) catch return .{
        .success = false,
        .error_code = .backend_unavailable,
        .ex_units_mem = 0,
        .ex_units_steps = 0,
    };

    // Serialize context
    var serial_buf: [MAX_SERIAL_BUF]u8 = undefined;
    const serial_len = serializeContext(ctx, &serial_buf) orelse return .{
        .success = false,
        .error_code = .missing_context,
        .ex_units_mem = 0,
        .ex_units_steps = 0,
    };

    // Spawn external evaluator — page_allocator for Child plumbing only
    const alloc = std.heap.page_allocator;
    var child = compat.Child.init(
        &[_][]const u8{ path, "--evaluate" },
        alloc,
    );
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Close;

    child.spawn() catch return .{
        .success = false,
        .error_code = .backend_unavailable,
        .ex_units_mem = 0,
        .ex_units_steps = 0,
    };

    // Write serialized context to stdin, then close
    if (child.stdin) |stdin| {
        stdin.writeAll(serial_buf[0..serial_len]) catch {};
        stdin.close();
        child.stdin = null;
    }

    // Read result from stdout to fixed buffer
    var result_buf: [MAX_RESULT_BUF]u8 = undefined;
    var total_read: usize = 0;
    if (child.stdout) |stdout| {
        while (total_read < result_buf.len) {
            const n = stdout.read(result_buf[total_read..]) catch break;
            if (n == 0) break;
            total_read += n;
        }
    }

    // Wait for child to finish
    _ = child.wait() catch {};

    if (total_read == 0) return .{
        .success = false,
        .error_code = .backend_invalid_response,
        .ex_units_mem = 0,
        .ex_units_steps = 0,
    };

    return parseResult(result_buf[0..total_read]);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "serializeContext: deterministic JSON output" {
    var ctx = PlutusExecutionContext{};
    ctx.input_count = 2;
    ctx.collateral_count = 1;
    ctx.ref_input_count = 0;
    ctx.script_count = 1;
    ctx.redeemer_count = 1;
    ctx.datum_count = 1;
    ctx.requires_plutus = true;
    ctx.has_total_collateral = true;
    ctx.total_collateral = 500000;
    ctx.has_collateral_return = false;
    ctx.spend_redeemers_mapped = 1;

    var buf: [MAX_SERIAL_BUF]u8 = undefined;
    const len = serializeContext(&ctx, &buf) orelse return error.TestUnexpectedResult;
    const json = buf[0..len];

    // Verify protocol_version is first and fields are present
    try std.testing.expect(findField(json, "\"protocol_version\":1"));
    try std.testing.expect(findField(json, "\"input_count\":2"));
    try std.testing.expect(findField(json, "\"collateral_count\":1"));
    try std.testing.expect(findField(json, "\"script_count\":1"));
    try std.testing.expect(findField(json, "\"requires_plutus\":true"));
    try std.testing.expect(findField(json, "\"total_collateral\":500000"));
    try std.testing.expect(findField(json, "\"has_collateral_return\":false"));
}

test "parseResult: valid JSON" {
    const json = "{\"protocol_version\":1,\"success\":false,\"error_code\":1,\"ex_units_mem\":1024,\"ex_units_steps\":2048}";
    const result = parseResult(json);

    try std.testing.expectEqual(false, result.success);
    try std.testing.expectEqual(EvalErrorCode.evaluator_not_implemented, result.error_code);
    try std.testing.expectEqual(@as(u64, 1024), result.ex_units_mem);
    try std.testing.expectEqual(@as(u64, 2048), result.ex_units_steps);
}

test "parseResult: success true" {
    const json = "{\"protocol_version\":1,\"success\":true,\"error_code\":0,\"ex_units_mem\":65536,\"ex_units_steps\":131072}";
    const result = parseResult(json);

    try std.testing.expectEqual(true, result.success);
    try std.testing.expectEqual(EvalErrorCode.none, result.error_code);
    try std.testing.expectEqual(@as(u64, 65536), result.ex_units_mem);
    try std.testing.expectEqual(@as(u64, 131072), result.ex_units_steps);
}

test "parseResult: malformed returns backend_invalid_response" {
    const result = parseResult("garbage");
    try std.testing.expectEqual(false, result.success);
    try std.testing.expectEqual(EvalErrorCode.backend_invalid_response, result.error_code);
}

test "parseResult: empty returns backend_invalid_response" {
    const result = parseResult("");
    try std.testing.expectEqual(EvalErrorCode.backend_invalid_response, result.error_code);
}

test "evaluateExternal: no TSUNAGI_HOME returns backend_unavailable" {
    // In test env, TSUNAGI_HOME may or may not be set.
    // If evaluator binary doesn't exist, should get backend_unavailable.
    var ctx = PlutusExecutionContext{};
    ctx.requires_plutus = true;
    const result = evaluateExternal(&ctx);
    // Must be either backend_unavailable (no binary) or a valid response
    try std.testing.expect(
        result.error_code == .backend_unavailable or
            result.error_code == .backend_invalid_response or
            result.error_code == .evaluator_not_implemented,
    );
}

// ---------------------------------------------------------------------------
// Phase 19: Deterministic Harness
// Golden output, idempotency, malformed input, and adapter dispatch tests.
// ---------------------------------------------------------------------------

test "serializeContext: idempotent — same input produces identical bytes" {
    var ctx = PlutusExecutionContext{};
    ctx.input_count = 3;
    ctx.collateral_count = 1;
    ctx.script_count = 2;
    ctx.redeemer_count = 2;
    ctx.datum_count = 1;
    ctx.requires_plutus = true;
    ctx.has_total_collateral = true;
    ctx.total_collateral = 750000;

    var buf1: [MAX_SERIAL_BUF]u8 = undefined;
    var buf2: [MAX_SERIAL_BUF]u8 = undefined;
    const len1 = serializeContext(&ctx, &buf1) orelse return error.TestUnexpectedResult;
    const len2 = serializeContext(&ctx, &buf2) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(len1, len2);
    try std.testing.expectEqualSlices(u8, buf1[0..len1], buf2[0..len2]);
}

test "serializeContext: golden output — zero context" {
    var ctx = PlutusExecutionContext{};
    var buf: [MAX_SERIAL_BUF]u8 = undefined;
    const len = serializeContext(&ctx, &buf) orelse return error.TestUnexpectedResult;

    const expected =
        "{" ++
        "\"protocol_version\":1," ++
        "\"input_count\":0," ++
        "\"collateral_count\":0," ++
        "\"ref_input_count\":0," ++
        "\"script_count\":0," ++
        "\"redeemer_count\":0," ++
        "\"datum_count\":0," ++
        "\"requires_plutus\":false," ++
        "\"has_total_collateral\":false," ++
        "\"total_collateral\":0," ++
        "\"has_collateral_return\":false," ++
        "\"spend_redeemers_mapped\":0" ++
        "}";
    try std.testing.expectEqualSlices(u8, expected, buf[0..len]);
}

test "serializeContext: golden output — typical Plutus context" {
    var ctx = PlutusExecutionContext{};
    ctx.input_count = 2;
    ctx.collateral_count = 1;
    ctx.ref_input_count = 1;
    ctx.script_count = 1;
    ctx.redeemer_count = 1;
    ctx.datum_count = 1;
    ctx.requires_plutus = true;
    ctx.has_total_collateral = true;
    ctx.total_collateral = 500000;
    ctx.has_collateral_return = true;
    ctx.spend_redeemers_mapped = 1;

    var buf: [MAX_SERIAL_BUF]u8 = undefined;
    const len = serializeContext(&ctx, &buf) orelse return error.TestUnexpectedResult;

    const expected =
        "{" ++
        "\"protocol_version\":1," ++
        "\"input_count\":2," ++
        "\"collateral_count\":1," ++
        "\"ref_input_count\":1," ++
        "\"script_count\":1," ++
        "\"redeemer_count\":1," ++
        "\"datum_count\":1," ++
        "\"requires_plutus\":true," ++
        "\"has_total_collateral\":true," ++
        "\"total_collateral\":500000," ++
        "\"has_collateral_return\":true," ++
        "\"spend_redeemers_mapped\":1" ++
        "}";
    try std.testing.expectEqualSlices(u8, expected, buf[0..len]);
}

test "serializeContext: golden output — max counts" {
    var ctx = PlutusExecutionContext{};
    ctx.input_count = PlutusExecutionContext.MAX_INPUTS;
    ctx.collateral_count = PlutusExecutionContext.MAX_COLLATERAL;
    ctx.ref_input_count = PlutusExecutionContext.MAX_REF_INPUTS;
    ctx.script_count = PlutusExecutionContext.MAX_SCRIPTS;
    ctx.redeemer_count = PlutusExecutionContext.MAX_REDEEMERS;
    ctx.datum_count = 255;
    ctx.requires_plutus = true;
    ctx.has_total_collateral = true;
    ctx.total_collateral = 18446744073709551615; // u64 max
    ctx.has_collateral_return = true;
    ctx.spend_redeemers_mapped = PlutusExecutionContext.MAX_REDEEMERS;

    var buf: [MAX_SERIAL_BUF]u8 = undefined;
    const len = serializeContext(&ctx, &buf) orelse return error.TestUnexpectedResult;

    const expected =
        "{" ++
        "\"protocol_version\":1," ++
        "\"input_count\":64," ++
        "\"collateral_count\":8," ++
        "\"ref_input_count\":8," ++
        "\"script_count\":16," ++
        "\"redeemer_count\":32," ++
        "\"datum_count\":255," ++
        "\"requires_plutus\":true," ++
        "\"has_total_collateral\":true," ++
        "\"total_collateral\":18446744073709551615," ++
        "\"has_collateral_return\":true," ++
        "\"spend_redeemers_mapped\":32" ++
        "}";
    try std.testing.expectEqualSlices(u8, expected, buf[0..len]);
}

test "parseResult: truncated JSON" {
    const result = parseResult("{\"success\":fal");
    try std.testing.expectEqual(false, result.success);
    try std.testing.expectEqual(EvalErrorCode.backend_invalid_response, result.error_code);
}

test "parseResult: missing error_code uses default" {
    const json = "{\"protocol_version\":1,\"success\":false}";
    const result = parseResult(json);
    try std.testing.expectEqual(false, result.success);
    // success:false found, but no error_code → stays at backend_invalid_response default
    // because parseResult initializes error_code to backend_invalid_response and only
    // overrides to .none when success:true is found
    try std.testing.expectEqual(EvalErrorCode.backend_invalid_response, result.error_code);
}

test "parseResult: extra unknown fields ignored" {
    const json = "{\"protocol_version\":1,\"success\":true,\"error_code\":0,\"extra\":999,\"ex_units_mem\":100,\"ex_units_steps\":200}";
    const result = parseResult(json);
    try std.testing.expectEqual(true, result.success);
    try std.testing.expectEqual(EvalErrorCode.none, result.error_code);
    try std.testing.expectEqual(@as(u64, 100), result.ex_units_mem);
    try std.testing.expectEqual(@as(u64, 200), result.ex_units_steps);
}

test "parseResult: large ex_units near u64 max" {
    const json = "{\"protocol_version\":1,\"success\":true,\"error_code\":0,\"ex_units_mem\":9999999999999,\"ex_units_steps\":8888888888888}";
    const result = parseResult(json);
    try std.testing.expectEqual(true, result.success);
    try std.testing.expectEqual(@as(u64, 9999999999999), result.ex_units_mem);
    try std.testing.expectEqual(@as(u64, 8888888888888), result.ex_units_steps);
}

test "parseResult: all-zero response" {
    const json = "{\"protocol_version\":1,\"success\":false,\"error_code\":0,\"ex_units_mem\":0,\"ex_units_steps\":0}";
    const result = parseResult(json);
    try std.testing.expectEqual(false, result.success);
    try std.testing.expectEqual(EvalErrorCode.none, result.error_code);
    try std.testing.expectEqual(@as(u64, 0), result.ex_units_mem);
    try std.testing.expectEqual(@as(u64, 0), result.ex_units_steps);
}

test "parseResult: golden stub evaluator output" {
    // Exact output from tools/stub-evaluator.sh (protocol v1)
    const stub_output = "{\"protocol_version\":1,\"success\":false,\"error_code\":1,\"ex_units_mem\":0,\"ex_units_steps\":0}";
    const result = parseResult(stub_output);
    try std.testing.expectEqual(false, result.success);
    try std.testing.expectEqual(EvalErrorCode.evaluator_not_implemented, result.error_code);
    try std.testing.expectEqual(@as(u64, 0), result.ex_units_mem);
    try std.testing.expectEqual(@as(u64, 0), result.ex_units_steps);
}

test "parseResult: only whitespace" {
    const result = parseResult("   \n  ");
    try std.testing.expectEqual(EvalErrorCode.backend_invalid_response, result.error_code);
}

test "evaluateWithAdapter: external_process dispatches to evaluateExternal" {
    var ctx = PlutusExecutionContext{};
    ctx.requires_plutus = true;

    const adapter_result = tx_decode.evaluateWithAdapter(&ctx, .external_process);
    const direct_result = evaluateExternal(&ctx);

    // Both paths should produce identical results (no binary → same error)
    try std.testing.expectEqual(direct_result.success, adapter_result.success);
    try std.testing.expectEqual(direct_result.error_code, adapter_result.error_code);
    try std.testing.expectEqual(direct_result.ex_units_mem, adapter_result.ex_units_mem);
    try std.testing.expectEqual(direct_result.ex_units_steps, adapter_result.ex_units_steps);
}

// ---------------------------------------------------------------------------
// Phase 20: Protocol Version Gate Tests
// ---------------------------------------------------------------------------

test "parseResult: missing protocol_version rejected" {
    // Valid fields but no protocol_version → rejected
    const json = "{\"success\":true,\"error_code\":0,\"ex_units_mem\":100,\"ex_units_steps\":200}";
    const result = parseResult(json);
    try std.testing.expectEqual(false, result.success);
    try std.testing.expectEqual(EvalErrorCode.backend_invalid_response, result.error_code);
}

test "parseResult: wrong protocol_version rejected" {
    const json = "{\"protocol_version\":999,\"success\":true,\"error_code\":0,\"ex_units_mem\":100,\"ex_units_steps\":200}";
    const result = parseResult(json);
    try std.testing.expectEqual(false, result.success);
    try std.testing.expectEqual(EvalErrorCode.backend_invalid_response, result.error_code);
}

test "parseResult: protocol_version 0 rejected" {
    const json = "{\"protocol_version\":0,\"success\":true,\"error_code\":0,\"ex_units_mem\":0,\"ex_units_steps\":0}";
    const result = parseResult(json);
    try std.testing.expectEqual(EvalErrorCode.backend_invalid_response, result.error_code);
}

test "parseResult: protocol_version 2 rejected" {
    const json = "{\"protocol_version\":2,\"success\":false,\"error_code\":1,\"ex_units_mem\":0,\"ex_units_steps\":0}";
    const result = parseResult(json);
    try std.testing.expectEqual(EvalErrorCode.backend_invalid_response, result.error_code);
}

test "serializeContext: protocol_version is first field" {
    var ctx = PlutusExecutionContext{};
    var buf: [MAX_SERIAL_BUF]u8 = undefined;
    const len = serializeContext(&ctx, &buf) orelse return error.TestUnexpectedResult;
    // Must start with {"protocol_version":1,
    try std.testing.expectEqualSlices(u8, "{\"protocol_version\":1,", buf[0..22]);
    _ = len;
}

// ---------------------------------------------------------------------------
// Phase 21: Minimal Rule-Based Evaluator Tests
// ---------------------------------------------------------------------------

test "evaluateMinimalRules: no redeemers returns script_failed" {
    var ctx = PlutusExecutionContext{};
    ctx.requires_plutus = true;
    ctx.script_count = 2;
    ctx.redeemer_count = 0;

    const result = evaluateMinimalRules(&ctx);
    try std.testing.expectEqual(false, result.success);
    try std.testing.expectEqual(EvalErrorCode.script_failed, result.error_code);
    try std.testing.expectEqual(@as(u64, 0), result.ex_units_mem);
    try std.testing.expectEqual(@as(u64, 0), result.ex_units_steps);
}

test "evaluateMinimalRules: no scripts returns missing_context" {
    var ctx = PlutusExecutionContext{};
    ctx.requires_plutus = true;
    ctx.script_count = 0;
    ctx.redeemer_count = 3;

    const result = evaluateMinimalRules(&ctx);
    try std.testing.expectEqual(false, result.success);
    try std.testing.expectEqual(EvalErrorCode.missing_context, result.error_code);
    try std.testing.expectEqual(@as(u64, 0), result.ex_units_mem);
    try std.testing.expectEqual(@as(u64, 0), result.ex_units_steps);
}

test "evaluateMinimalRules: valid context returns success with deterministic ex_units" {
    var ctx = PlutusExecutionContext{};
    ctx.requires_plutus = true;
    ctx.script_count = 1;
    ctx.redeemer_count = 5;
    ctx.spend_redeemers_mapped = 3;
    ctx.datum_count = 2;

    const result = evaluateMinimalRules(&ctx);
    try std.testing.expectEqual(true, result.success);
    try std.testing.expectEqual(EvalErrorCode.none, result.error_code);
    // mem = 5*1000 + 1*500 = 5500, steps = 5*2000 + 1*1000 = 11000
    try std.testing.expectEqual(@as(u64, 5500), result.ex_units_mem);
    try std.testing.expectEqual(@as(u64, 11000), result.ex_units_steps);
}

test "evaluateMinimalRules: deterministic — same input same output" {
    var ctx = PlutusExecutionContext{};
    ctx.requires_plutus = true;
    ctx.script_count = 2;
    ctx.redeemer_count = 3;
    ctx.spend_redeemers_mapped = 1;
    ctx.datum_count = 1;

    const r1 = evaluateMinimalRules(&ctx);
    const r2 = evaluateMinimalRules(&ctx);

    try std.testing.expectEqual(r1.success, r2.success);
    try std.testing.expectEqual(r1.error_code, r2.error_code);
    try std.testing.expectEqual(r1.ex_units_mem, r2.ex_units_mem);
    try std.testing.expectEqual(r1.ex_units_steps, r2.ex_units_steps);
}

test "evaluateMinimalRules: single redeemer golden values" {
    var ctx = PlutusExecutionContext{};
    ctx.script_count = 1;
    ctx.redeemer_count = 1;
    ctx.spend_redeemers_mapped = 1;
    ctx.datum_count = 1;

    const result = evaluateMinimalRules(&ctx);
    try std.testing.expectEqual(true, result.success);
    // mem = 1*1000 + 1*500 = 1500, steps = 1*2000 + 1*1000 = 3000
    try std.testing.expectEqual(@as(u64, 1500), result.ex_units_mem);
    try std.testing.expectEqual(@as(u64, 3000), result.ex_units_steps);
}

test "evaluateMinimalRules: invalid_redeemer when spend_mapped is zero" {
    var ctx = PlutusExecutionContext{};
    ctx.requires_plutus = true;
    ctx.script_count = 1;
    ctx.redeemer_count = 2;
    ctx.spend_redeemers_mapped = 0;
    ctx.datum_count = 1;

    const result = evaluateMinimalRules(&ctx);
    try std.testing.expectEqual(false, result.success);
    try std.testing.expectEqual(EvalErrorCode.invalid_redeemer, result.error_code);
    try std.testing.expectEqual(@as(u64, 0), result.ex_units_mem);
    try std.testing.expectEqual(@as(u64, 0), result.ex_units_steps);
}

test "evaluateMinimalRules: no datums with scripts returns missing_context" {
    var ctx = PlutusExecutionContext{};
    ctx.requires_plutus = true;
    ctx.script_count = 1;
    ctx.redeemer_count = 1;
    ctx.spend_redeemers_mapped = 1;
    ctx.datum_count = 0;

    const result = evaluateMinimalRules(&ctx);
    try std.testing.expectEqual(false, result.success);
    try std.testing.expectEqual(EvalErrorCode.missing_context, result.error_code);
    try std.testing.expectEqual(@as(u64, 0), result.ex_units_mem);
    try std.testing.expectEqual(@as(u64, 0), result.ex_units_steps);
}

test "evaluateWithAdapter: embedded dispatches to evaluateMinimalRules" {
    var ctx = PlutusExecutionContext{};
    ctx.requires_plutus = true;
    ctx.script_count = 1;
    ctx.redeemer_count = 2;
    ctx.spend_redeemers_mapped = 1;
    ctx.datum_count = 1;

    const adapter_result = tx_decode.evaluateWithAdapter(&ctx, .embedded);
    const direct_result = evaluateMinimalRules(&ctx);

    try std.testing.expectEqual(direct_result.success, adapter_result.success);
    try std.testing.expectEqual(direct_result.error_code, adapter_result.error_code);
    try std.testing.expectEqual(direct_result.ex_units_mem, adapter_result.ex_units_mem);
    try std.testing.expectEqual(direct_result.ex_units_steps, adapter_result.ex_units_steps);
}

test "evaluateMinimalRules: cross-backend golden — matches expected external output" {
    // Verify embedded result matches what plutus-evaluator.sh would produce
    // for the same context (protocol v1 golden comparison)
    var ctx = PlutusExecutionContext{};
    ctx.script_count = 2;
    ctx.redeemer_count = 4;
    ctx.spend_redeemers_mapped = 2;
    ctx.datum_count = 1;

    const result = evaluateMinimalRules(&ctx);

    // External evaluator output: mem=4*1000+2*500=5000, steps=4*2000+2*1000=10000
    const expected_external = "{\"protocol_version\":1,\"success\":true,\"error_code\":0,\"ex_units_mem\":5000,\"ex_units_steps\":10000}";
    const parsed = parseResult(expected_external);

    try std.testing.expectEqual(result.success, parsed.success);
    try std.testing.expectEqual(result.error_code, parsed.error_code);
    try std.testing.expectEqual(result.ex_units_mem, parsed.ex_units_mem);
    try std.testing.expectEqual(result.ex_units_steps, parsed.ex_units_steps);
}

// ---------------------------------------------------------------------------
// Phase 22: Embedded Backend Iteration Determinism Tests
// Proves evaluateMinimalRules produces identical output across 100 runs.
// ---------------------------------------------------------------------------

test "evaluateMinimalRules: 100-iteration determinism — valid context" {
    var ctx = PlutusExecutionContext{};
    ctx.script_count = 1;
    ctx.redeemer_count = 3;
    ctx.spend_redeemers_mapped = 1;
    ctx.datum_count = 1;

    const golden = evaluateMinimalRules(&ctx);
    // Golden: success=true, none, mem=3*1000+1*500=3500, steps=3*2000+1*1000=7000
    try std.testing.expectEqual(true, golden.success);
    try std.testing.expectEqual(EvalErrorCode.none, golden.error_code);
    try std.testing.expectEqual(@as(u64, 3500), golden.ex_units_mem);
    try std.testing.expectEqual(@as(u64, 7000), golden.ex_units_steps);

    for (0..100) |_| {
        const r = evaluateMinimalRules(&ctx);
        try std.testing.expectEqual(golden.success, r.success);
        try std.testing.expectEqual(golden.error_code, r.error_code);
        try std.testing.expectEqual(golden.ex_units_mem, r.ex_units_mem);
        try std.testing.expectEqual(golden.ex_units_steps, r.ex_units_steps);
    }
}

test "evaluateMinimalRules: 100-iteration determinism — no redeemers" {
    var ctx = PlutusExecutionContext{};
    ctx.script_count = 2;
    ctx.redeemer_count = 0;

    const golden = evaluateMinimalRules(&ctx);
    try std.testing.expectEqual(false, golden.success);
    try std.testing.expectEqual(EvalErrorCode.script_failed, golden.error_code);
    try std.testing.expectEqual(@as(u64, 0), golden.ex_units_mem);
    try std.testing.expectEqual(@as(u64, 0), golden.ex_units_steps);

    for (0..100) |_| {
        const r = evaluateMinimalRules(&ctx);
        try std.testing.expectEqual(golden.success, r.success);
        try std.testing.expectEqual(golden.error_code, r.error_code);
        try std.testing.expectEqual(golden.ex_units_mem, r.ex_units_mem);
        try std.testing.expectEqual(golden.ex_units_steps, r.ex_units_steps);
    }
}

test "evaluateMinimalRules: 100-iteration determinism — no scripts" {
    var ctx = PlutusExecutionContext{};
    ctx.script_count = 0;
    ctx.redeemer_count = 2;

    const golden = evaluateMinimalRules(&ctx);
    try std.testing.expectEqual(false, golden.success);
    try std.testing.expectEqual(EvalErrorCode.missing_context, golden.error_code);
    try std.testing.expectEqual(@as(u64, 0), golden.ex_units_mem);
    try std.testing.expectEqual(@as(u64, 0), golden.ex_units_steps);

    for (0..100) |_| {
        const r = evaluateMinimalRules(&ctx);
        try std.testing.expectEqual(golden.success, r.success);
        try std.testing.expectEqual(golden.error_code, r.error_code);
        try std.testing.expectEqual(golden.ex_units_mem, r.ex_units_mem);
        try std.testing.expectEqual(golden.ex_units_steps, r.ex_units_steps);
    }
}

// ---------------------------------------------------------------------------
// Phase 39: Known-Case Plutus Boundary Proof
// Proves TSUNAGI's execution pipeline handles a structurally authentic
// Plutus transaction with declared provenance. NOT general Plutus execution.
// ---------------------------------------------------------------------------

const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

/// Declared provenance of a known-case result.
pub const KnownCaseProvenance = enum(u8) {
    synthetic_structural = 0, // hand-crafted CBOR, structurally authentic, not from chain
    trusted_vector = 1, // from published test vector or specification
    external_evaluator_verified = 2, // verified by a real external evaluator
};

/// Outcome of a known-case boundary lookup.
pub const KnownCaseBoundaryResult = enum(u8) {
    known_case_pass = 0,
    known_case_fail = 1,
    known_case_not_supported = 2,
};

/// Detailed result of a known-case boundary proof.
pub const KnownCaseBoundaryDetail = struct {
    result: KnownCaseBoundaryResult = .known_case_not_supported,
    provenance: KnownCaseProvenance = .synthetic_structural,
    ex_units_mem: u64 = 0,
    ex_units_steps: u64 = 0,
};

const KnownCaseEntry = struct {
    fingerprint: [32]u8, // blake2b256(full tx bytes)
    provenance: KnownCaseProvenance,
    success: bool,
    ex_units_mem: u64,
    ex_units_steps: u64,
};

/// Known-case table. Each entry is backed by a reproducible fixture
/// with a declared provenance. Fingerprint is blake2b256 of full tx bytes.
const KNOWN_CASES: []const KnownCaseEntry = &.{
    // Synthetic Plutus V1 spending tx (from buildPlutusContext test fixture):
    // 1 input, 1 V1 script, 1 spend redeemer, 1 datum, 1 collateral, total_collateral=500000
    // Provenance: synthetic_structural — hand-crafted CBOR, not from chain
    // Ex_units from evaluateMinimalRules: mem=1*1000+1*500=1500, steps=1*2000+1*1000=3000
    .{
        .fingerprint = .{ 0x50, 0x43, 0x5d, 0xac, 0x72, 0xd1, 0xb4, 0x3c, 0x04, 0x5c, 0xd4, 0x6f, 0xf8, 0x5e, 0x64, 0x03, 0x41, 0x49, 0xba, 0x1f, 0xb2, 0xa5, 0xe7, 0xcf, 0x7c, 0x82, 0x6a, 0x94, 0xa9, 0xe5, 0x5e, 0x4e },
        .provenance = .synthetic_structural,
        .success = true,
        .ex_units_mem = 1500,
        .ex_units_steps = 3000,
    },
};

/// Evaluate a transaction against the known-case boundary table.
/// Computes blake2b256(tx_bytes) and looks up the fingerprint.
/// Returns known_case_not_supported if no match.
/// This is NOT general Plutus execution — it is a known-case boundary proof.
pub fn evaluateKnownCaseBoundary(tx_bytes: []const u8) KnownCaseBoundaryDetail {
    if (tx_bytes.len == 0) return .{};
    var fingerprint: [32]u8 = undefined;
    Blake2b256.hash(tx_bytes, &fingerprint, .{});
    for (KNOWN_CASES) |entry| {
        if (std.mem.eql(u8, &fingerprint, &entry.fingerprint)) {
            return .{
                .result = if (entry.success) .known_case_pass else .known_case_fail,
                .provenance = entry.provenance,
                .ex_units_mem = entry.ex_units_mem,
                .ex_units_steps = entry.ex_units_steps,
            };
        }
    }
    return .{};
}

// ---------------------------------------------------------------------------
// Known-Case Boundary Tests
// ---------------------------------------------------------------------------

/// Helper: construct the synthetic Plutus V1 spending tx (same bytes as buildPlutusContext test).
fn buildSyntheticPlutusV1Tx(buf: *[256]u8) usize {
    var w: usize = 0;
    buf[w] = 0x82;
    w += 1; // array(2)
    buf[w] = 0xA4;
    w += 1; // body map(4)
    buf[w] = 0x00;
    w += 1; // key 0: inputs
    buf[w] = 0x81;
    w += 1;
    buf[w] = 0x82;
    w += 1;
    buf[w] = 0x58;
    w += 1;
    buf[w] = 0x20;
    w += 1;
    @memset(buf[w..][0..32], 0x00);
    w += 32;
    buf[w] = 0x03;
    w += 1;
    buf[w] = 0x0B;
    w += 1; // key 11: script_data_hash
    buf[w] = 0x58;
    w += 1;
    buf[w] = 0x20;
    w += 1;
    @memset(buf[w..][0..32], 0x11);
    w += 32;
    buf[w] = 0x0D;
    w += 1; // key 13: collateral
    buf[w] = 0x81;
    w += 1;
    buf[w] = 0x82;
    w += 1;
    buf[w] = 0x58;
    w += 1;
    buf[w] = 0x20;
    w += 1;
    @memset(buf[w..][0..32], 0xFF);
    w += 32;
    buf[w] = 0x00;
    w += 1;
    buf[w] = 0x11;
    w += 1; // key 17: total_collateral
    buf[w] = 0x1A;
    w += 1;
    buf[w] = 0x00;
    w += 1;
    buf[w] = 0x07;
    w += 1;
    buf[w] = 0xA1;
    w += 1;
    buf[w] = 0x20;
    w += 1;
    buf[w] = 0xA3;
    w += 1; // witness map(3)
    buf[w] = 0x03;
    w += 1; // key 3: plutus v1 scripts
    buf[w] = 0x81;
    w += 1;
    buf[w] = 0x43;
    w += 1;
    buf[w] = 0xAA;
    w += 1;
    buf[w] = 0xBB;
    w += 1;
    buf[w] = 0xCC;
    w += 1;
    buf[w] = 0x04;
    w += 1; // key 4: datums
    buf[w] = 0x81;
    w += 1;
    buf[w] = 0x41;
    w += 1;
    buf[w] = 0xDD;
    w += 1;
    buf[w] = 0x05;
    w += 1; // key 5: redeemers
    buf[w] = 0x81;
    w += 1;
    buf[w] = 0x84;
    w += 1;
    buf[w] = 0x00;
    w += 1;
    buf[w] = 0x00;
    w += 1;
    buf[w] = 0x41;
    w += 1;
    buf[w] = 0xEE;
    w += 1;
    buf[w] = 0x82;
    w += 1;
    buf[w] = 0x1A;
    w += 1;
    buf[w] = 0x00;
    w += 1;
    buf[w] = 0x01;
    w += 1;
    buf[w] = 0x00;
    w += 1;
    buf[w] = 0x00;
    w += 1;
    buf[w] = 0x1A;
    w += 1;
    buf[w] = 0x00;
    w += 1;
    buf[w] = 0x02;
    w += 1;
    buf[w] = 0x00;
    w += 1;
    buf[w] = 0x00;
    w += 1;
    return w;
}

test "evaluateKnownCaseBoundary: supported synthetic V1 spend — full pipeline" {
    var buf: [256]u8 = undefined;
    const len = buildSyntheticPlutusV1Tx(&buf);
    const tx_bytes = buf[0..len];

    // Step 1: Verify fingerprint matches known-case table
    var fingerprint: [32]u8 = undefined;
    Blake2b256.hash(tx_bytes, &fingerprint, .{});
    try std.testing.expectEqualSlices(u8, &KNOWN_CASES[0].fingerprint, &fingerprint);

    // Step 2: Verify buildPlutusContext succeeds (real CBOR parsing)
    const ctx = tx_decode.buildPlutusContext(tx_bytes) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 1), ctx.input_count);
    try std.testing.expectEqual(@as(u32, 1), ctx.script_count);
    try std.testing.expectEqual(@as(u32, 1), ctx.redeemer_count);
    try std.testing.expectEqual(@as(u32, 1), ctx.datum_count);
    try std.testing.expectEqual(@as(u32, 1), ctx.spend_redeemers_mapped);
    try std.testing.expect(ctx.requires_plutus);

    // Step 3: Verify evaluateMinimalRules produces matching ex_units
    const eval_result = evaluateMinimalRules(&ctx);
    try std.testing.expectEqual(true, eval_result.success);
    try std.testing.expectEqual(@as(u64, 1500), eval_result.ex_units_mem);
    try std.testing.expectEqual(@as(u64, 3000), eval_result.ex_units_steps);

    // Step 4: Known-case boundary lookup
    const boundary = evaluateKnownCaseBoundary(tx_bytes);
    try std.testing.expectEqual(KnownCaseBoundaryResult.known_case_pass, boundary.result);
    try std.testing.expectEqual(KnownCaseProvenance.synthetic_structural, boundary.provenance);
    try std.testing.expectEqual(@as(u64, 1500), boundary.ex_units_mem);
    try std.testing.expectEqual(@as(u64, 3000), boundary.ex_units_steps);

    // Step 5: Cross-verify boundary ex_units match evaluator ex_units
    try std.testing.expectEqual(eval_result.ex_units_mem, boundary.ex_units_mem);
    try std.testing.expectEqual(eval_result.ex_units_steps, boundary.ex_units_steps);
}

test "evaluateKnownCaseBoundary: unsupported tx returns known_case_not_supported" {
    var buf: [64]u8 = undefined;
    var w: usize = 0;
    buf[w] = 0x82;
    w += 1;
    buf[w] = 0xA1;
    w += 1;
    buf[w] = 0x00;
    w += 1;
    buf[w] = 0x81;
    w += 1;
    buf[w] = 0x82;
    w += 1;
    buf[w] = 0x58;
    w += 1;
    buf[w] = 0x20;
    w += 1;
    @memset(buf[w..][0..32], 0xBB);
    w += 32;
    buf[w] = 0x00;
    w += 1;
    buf[w] = 0xA0;
    w += 1;

    const boundary = evaluateKnownCaseBoundary(buf[0..w]);
    try std.testing.expectEqual(KnownCaseBoundaryResult.known_case_not_supported, boundary.result);
}

test "evaluateKnownCaseBoundary: empty bytes returns known_case_not_supported" {
    const boundary = evaluateKnownCaseBoundary(&[_]u8{});
    try std.testing.expectEqual(KnownCaseBoundaryResult.known_case_not_supported, boundary.result);
}

test "evaluateKnownCaseBoundary: malformed bytes returns known_case_not_supported" {
    const boundary = evaluateKnownCaseBoundary(&[_]u8{ 0xFF, 0xFE, 0xFD });
    try std.testing.expectEqual(KnownCaseBoundaryResult.known_case_not_supported, boundary.result);
}

// ---------------------------------------------------------------------------
// Phase 41: External Boundary Result Ingestion
// Invokes the external evaluator binary for a known-case tx, parses the
// response, and classifies against the declared known-case expectation.
// NOT general Plutus execution — known serialized-context boundary only.
// ---------------------------------------------------------------------------

/// Outcome of external boundary result ingestion.
pub const ExternalBoundaryResult = enum(u8) {
    supported_pass = 0, // external result matches known-case expectation
    supported_fail = 1, // external result diverges from known-case expectation
    backend_unavailable = 2, // evaluator binary not found or spawn failed
    case_not_supported = 3, // tx does not match any known case
    invalid_response = 4, // external response malformed or unparseable
};

/// Detailed result of external boundary ingestion.
/// provenance is only meaningful when result is supported_pass or supported_fail.
pub const ExternalBoundaryDetail = struct {
    result: ExternalBoundaryResult = .case_not_supported,
    /// Only set when result is supported_pass or supported_fail.
    /// Null for case_not_supported, backend_unavailable, invalid_response.
    provenance: ?KnownCaseProvenance = null,
    ex_units_mem: u64 = 0,
    ex_units_steps: u64 = 0,
};

/// Invoke the external evaluator binary for a known-case Plutus-shaped tx.
/// 1. Fingerprint tx_bytes → if no known-case match → case_not_supported
/// 2. Build PlutusExecutionContext from CBOR → if fails → case_not_supported
/// 3. Call evaluateExternal() (existing process machinery) → classify errors
/// 4. Compare external result against known-case entry → supported_pass or supported_fail
///
/// This is NOT general Plutus execution — known serialized-context boundary only.
pub fn evaluateKnownCaseExternal(tx_bytes: []const u8) ExternalBoundaryDetail {
    if (tx_bytes.len == 0) return .{};

    // Step 1: fingerprint check against known-case table
    var fp: [32]u8 = undefined;
    Blake2b256.hash(tx_bytes, &fp, .{});
    var matched_entry: ?KnownCaseEntry = null;
    for (KNOWN_CASES) |entry| {
        if (std.mem.eql(u8, &fp, &entry.fingerprint)) {
            matched_entry = entry;
            break;
        }
    }
    const known = matched_entry orelse return .{};

    // Step 2: build execution context from raw CBOR
    const ctx = tx_decode.buildPlutusContext(tx_bytes) orelse return .{};

    // Step 3: call external evaluator binary
    const ext = evaluateExternal(&ctx);

    // Classify backend errors
    if (ext.error_code == .backend_unavailable) return .{ .result = .backend_unavailable };
    if (ext.error_code == .backend_invalid_response) return .{ .result = .invalid_response };

    // Step 4: compare external result against known-case expectation
    if (ext.success == known.success and
        ext.ex_units_mem == known.ex_units_mem and
        ext.ex_units_steps == known.ex_units_steps)
    {
        return .{
            .result = .supported_pass,
            .provenance = known.provenance,
            .ex_units_mem = ext.ex_units_mem,
            .ex_units_steps = ext.ex_units_steps,
        };
    }

    return .{
        .result = .supported_fail,
        .provenance = known.provenance,
        .ex_units_mem = ext.ex_units_mem,
        .ex_units_steps = ext.ex_units_steps,
    };
}

/// Classify an external ExecutionResult against a known-case entry.
/// Separated from evaluateKnownCaseExternal for deterministic unit testing
/// without requiring a real external binary.
pub fn classifyExternalResult(
    ext: ExecutionResult,
    known: KnownCaseEntry,
) ExternalBoundaryDetail {
    if (ext.error_code == .backend_unavailable) return .{ .result = .backend_unavailable };
    if (ext.error_code == .backend_invalid_response) return .{ .result = .invalid_response };
    if (ext.success == known.success and
        ext.ex_units_mem == known.ex_units_mem and
        ext.ex_units_steps == known.ex_units_steps)
    {
        return .{
            .result = .supported_pass,
            .provenance = known.provenance,
            .ex_units_mem = ext.ex_units_mem,
            .ex_units_steps = ext.ex_units_steps,
        };
    }
    return .{
        .result = .supported_fail,
        .provenance = known.provenance,
        .ex_units_mem = ext.ex_units_mem,
        .ex_units_steps = ext.ex_units_steps,
    };
}

// ---------------------------------------------------------------------------
// External Boundary Tests — Deterministic Classification
// ---------------------------------------------------------------------------

test "classifyExternalResult: matching result returns supported_pass" {
    const known = KNOWN_CASES[0];
    const ext = ExecutionResult{
        .success = true,
        .error_code = .none,
        .ex_units_mem = 1500,
        .ex_units_steps = 3000,
    };
    const detail = classifyExternalResult(ext, known);
    try std.testing.expectEqual(ExternalBoundaryResult.supported_pass, detail.result);
    try std.testing.expectEqual(KnownCaseProvenance.synthetic_structural, detail.provenance.?);
    try std.testing.expectEqual(@as(u64, 1500), detail.ex_units_mem);
    try std.testing.expectEqual(@as(u64, 3000), detail.ex_units_steps);
}

test "classifyExternalResult: divergent ex_units returns supported_fail" {
    const known = KNOWN_CASES[0];
    const ext = ExecutionResult{
        .success = true,
        .error_code = .none,
        .ex_units_mem = 9999, // wrong
        .ex_units_steps = 3000,
    };
    const detail = classifyExternalResult(ext, known);
    try std.testing.expectEqual(ExternalBoundaryResult.supported_fail, detail.result);
    try std.testing.expectEqual(KnownCaseProvenance.synthetic_structural, detail.provenance.?);
    try std.testing.expectEqual(@as(u64, 9999), detail.ex_units_mem);
}

test "classifyExternalResult: divergent success returns supported_fail" {
    const known = KNOWN_CASES[0];
    const ext = ExecutionResult{
        .success = false,
        .error_code = .script_failed,
        .ex_units_mem = 0,
        .ex_units_steps = 0,
    };
    const detail = classifyExternalResult(ext, known);
    try std.testing.expectEqual(ExternalBoundaryResult.supported_fail, detail.result);
}

test "classifyExternalResult: backend_unavailable" {
    const known = KNOWN_CASES[0];
    const ext = ExecutionResult{
        .success = false,
        .error_code = .backend_unavailable,
        .ex_units_mem = 0,
        .ex_units_steps = 0,
    };
    const detail = classifyExternalResult(ext, known);
    try std.testing.expectEqual(ExternalBoundaryResult.backend_unavailable, detail.result);
    try std.testing.expectEqual(@as(?KnownCaseProvenance, null), detail.provenance);
}

test "classifyExternalResult: backend_invalid_response" {
    const known = KNOWN_CASES[0];
    const ext = ExecutionResult{
        .success = false,
        .error_code = .backend_invalid_response,
        .ex_units_mem = 0,
        .ex_units_steps = 0,
    };
    const detail = classifyExternalResult(ext, known);
    try std.testing.expectEqual(ExternalBoundaryResult.invalid_response, detail.result);
    try std.testing.expectEqual(@as(?KnownCaseProvenance, null), detail.provenance);
}

// ---------------------------------------------------------------------------
// External Boundary Tests — Availability-Dependent (Real Binary Path)
// ---------------------------------------------------------------------------

test "evaluateKnownCaseExternal: non-matching tx returns case_not_supported" {
    var buf: [64]u8 = undefined;
    var w: usize = 0;
    buf[w] = 0x82;
    w += 1;
    buf[w] = 0xA1;
    w += 1;
    buf[w] = 0x00;
    w += 1;
    buf[w] = 0x81;
    w += 1;
    buf[w] = 0x82;
    w += 1;
    buf[w] = 0x58;
    w += 1;
    buf[w] = 0x20;
    w += 1;
    @memset(buf[w..][0..32], 0xCC);
    w += 32;
    buf[w] = 0x00;
    w += 1;
    buf[w] = 0xA0;
    w += 1;

    const detail = evaluateKnownCaseExternal(buf[0..w]);
    try std.testing.expectEqual(ExternalBoundaryResult.case_not_supported, detail.result);
    try std.testing.expectEqual(@as(?KnownCaseProvenance, null), detail.provenance);
}

test "evaluateKnownCaseExternal: empty bytes returns case_not_supported" {
    const detail = evaluateKnownCaseExternal(&[_]u8{});
    try std.testing.expectEqual(ExternalBoundaryResult.case_not_supported, detail.result);
    try std.testing.expectEqual(@as(?KnownCaseProvenance, null), detail.provenance);
}

test "evaluateKnownCaseExternal: known-case tx — availability dependent" {
    // This test exercises the real external binary path.
    // Result depends on whether $TSUNAGI_HOME/bin/plutus-evaluator exists.
    var buf: [256]u8 = undefined;
    const len = buildSyntheticPlutusV1Tx(&buf);
    const detail = evaluateKnownCaseExternal(buf[0..len]);

    // Must be one of: supported_pass (binary present and matched),
    // backend_unavailable (binary not found), or supported_fail (binary diverged)
    try std.testing.expect(
        detail.result == .supported_pass or
            detail.result == .backend_unavailable or
            detail.result == .supported_fail,
    );
}
