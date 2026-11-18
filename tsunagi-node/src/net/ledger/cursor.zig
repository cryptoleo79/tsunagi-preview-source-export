const std = @import("std");
const compat = @import("compat");

/// Phase B'''': the cursor surface is DELIVERED-DOMAIN.
///
/// `slot`, `block_no`, and `tip_hash_hex` describe the latest delivered
/// header that the follower has applied — parsed from the on-the-wire
/// header CBOR, NOT taken from the peer's RollForward envelope tip.
///
/// Peer-tip values (which may describe a strictly LATER block than the
/// delivered header) flow through the separate `peer_tip_*` gauges in
/// http_metrics and the `Context.peer_tip_*` fields in follower.zig.
///
/// The intersect contract is preserved: (delivered.slot, delivered.hash)
/// is always a valid resumption point because the delivered header was
/// the *most recently applied* block. Resumption never requires a
/// peer-tip-domain point.
pub const Cursor = struct {
    slot: u64,
    block_no: u64,
    tip_hash_hex: [64]u8,
    header_hash_hex: [64]u8,
    roll_forward_count: u64,
    roll_backward_count: u64,
    updated_unix: i64,
    /// Cursor JSON schema version. v1 (pre-B'''') = peer-tip domain.
    /// v2 (post-B'''') = delivered domain. Bumped atomically with the
    /// commit that shifts the on-disk representation.
    cursor_schema_version: u32 = 2,
};

const CursorJson = struct {
    slot: ?u64 = null,
    block_no: ?u64 = null,
    tip_hash_hex: ?[]const u8 = null,
    header_hash_hex: ?[]const u8 = null,
    roll_forward_count: ?u64 = null,
    roll_backward_count: ?u64 = null,
    updated_unix: ?i64 = null,
    cursor_schema_version: ?u32 = null,
};

fn copyHex(dest: *[64]u8, src: []const u8) !void {
    if (src.len != dest.len) return error.InvalidCursor;
    std.mem.copyForwards(u8, dest[0..], src);
}

fn zeroCursor() Cursor {
    var cursor = std.mem.zeroes(Cursor);
    @memset(cursor.tip_hash_hex[0..], '0');
    @memset(cursor.header_hash_hex[0..], '0');
    cursor.cursor_schema_version = 2;
    return cursor;
}

pub fn loadOrInit(alloc: std.mem.Allocator, path: []const u8) !Cursor {
    var file = compat.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return zeroCursor(),
        else => return err,
    };
    defer file.close();

    const data = try file.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(data);

    var parsed = try std.json.parseFromSlice(CursorJson, alloc, data, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var cursor = zeroCursor();
    const value = parsed.value;
    if (value.slot) |slot| cursor.slot = slot;
    if (value.block_no) |block_no| cursor.block_no = block_no;
    if (value.tip_hash_hex) |hex| try copyHex(&cursor.tip_hash_hex, hex);
    if (value.header_hash_hex) |hex| try copyHex(&cursor.header_hash_hex, hex);
    if (value.roll_forward_count) |count| cursor.roll_forward_count = count;
    if (value.roll_backward_count) |count| cursor.roll_backward_count = count;
    if (value.updated_unix) |ts| cursor.updated_unix = ts;
    if (value.cursor_schema_version) |v| cursor.cursor_schema_version = v;

    return cursor;
}

pub fn save(cursor: Cursor, path: []const u8) !void {
    var file = try compat.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();

    const out = CursorJson{
        .slot = cursor.slot,
        .block_no = cursor.block_no,
        .tip_hash_hex = cursor.tip_hash_hex[0..],
        .header_hash_hex = cursor.header_hash_hex[0..],
        .roll_forward_count = cursor.roll_forward_count,
        .roll_backward_count = cursor.roll_backward_count,
        .updated_unix = cursor.updated_unix,
        .cursor_schema_version = cursor.cursor_schema_version,
    };

    const json_bytes = try std.json.Stringify.valueAlloc(std.heap.page_allocator, out, .{ .whitespace = .indent_2 });
    defer std.heap.page_allocator.free(json_bytes);
    const w = file.deprecatedWriter();
    try w.writeAll(json_bytes);
    try w.writeByte('\n');
}
