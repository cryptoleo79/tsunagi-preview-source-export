//! Pure formatter for the /status/full overflow fallback body.
//!
//! When the in-stack compose buffer overflows, the handler discards
//! the partial body (which would be a truncated mid-string and parse
//! as invalid JSON) and writes this minimal, always-parseable shape
//! instead.  Operators get a real document they can `jq` against and
//! `meta.ready=false`/`meta.truncated=true`/`meta.reason` mirror the
//! contract used by the existing structured fallback.
//!
//! The output is intentionally short and fixed-shape so 256 bytes of
//! scratch is always enough.  See test below for an exact-shape
//! assertion.

const std = @import("std");

pub const FALLBACK_REASON: []const u8 = "status_full_overflow";

/// Format the minimal overflow fallback into `dst`.  Returns the
/// written slice; `error.NoSpaceLeft` only when `dst.len < ~200` (the
/// fixed shape never exceeds ~200 bytes for reasonable u64 inputs).
pub fn format(
    dst: []u8,
    bytes_attempted: usize,
    buffer_bytes: usize,
    now_unix: i64,
) ![]u8 {
    return std.fmt.bufPrint(
        dst,
        "{{\"meta\":{{\"ready\":false,\"truncated\":true,\"reason\":\"" ++ FALLBACK_REASON ++ "\"," ++
            "\"bytes_attempted\":{d},\"buffer_bytes\":{d},\"now_unix\":{d}}}}}",
        .{ bytes_attempted, buffer_bytes, now_unix },
    );
}

test "status_fallback: exact minimal shape" {
    var buf: [256]u8 = undefined;
    const out = try format(&buf, 65537, 65536, 1_700_000_000);
    const expected =
        "{\"meta\":{\"ready\":false,\"truncated\":true,\"reason\":\"status_full_overflow\"," ++
        "\"bytes_attempted\":65537,\"buffer_bytes\":65536,\"now_unix\":1700000000}}";
    try std.testing.expectEqualStrings(expected, out);

    // Body must parse as JSON.  We cannot pull a JSON parser into a
    // pure-formatter test without bringing the std json module along,
    // but we can at least sanity-check the brace + quote structure.
    try std.testing.expect(out[0] == '{');
    try std.testing.expect(out[out.len - 1] == '}');
    try std.testing.expect(out[out.len - 2] == '}');
}

test "status_fallback: zero values still valid" {
    var buf: [256]u8 = undefined;
    const out = try format(&buf, 0, 0, 0);
    const expected =
        "{\"meta\":{\"ready\":false,\"truncated\":true,\"reason\":\"status_full_overflow\"," ++
        "\"bytes_attempted\":0,\"buffer_bytes\":0,\"now_unix\":0}}";
    try std.testing.expectEqualStrings(expected, out);
}

test "status_fallback: too-small destination errors cleanly" {
    var tiny: [16]u8 = undefined;
    const r = format(&tiny, 1, 2, 3);
    try std.testing.expectError(error.NoSpaceLeft, r);
}
