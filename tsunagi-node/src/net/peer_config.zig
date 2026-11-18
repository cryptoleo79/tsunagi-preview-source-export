const std = @import("std");
const compat = @import("compat");

/// Maximum number of peers that can be loaded from config.
pub const MAX_PEERS: usize = 8;

/// A single peer entry with bounded host storage.
pub const PeerEntry = struct {
    host_buf: [64]u8 = undefined,
    host_len: u8 = 0,
    port: u16 = 3001,

    pub fn host(self: *const PeerEntry) []const u8 {
        return self.host_buf[0..self.host_len];
    }
};

/// Result of loading peers from config.
pub const PeerList = struct {
    entries: [MAX_PEERS]PeerEntry = undefined,
    count: usize = 0,
};

/// Try to load peers from {home_dir}/peers.json.
/// Returns null if file not found, unreadable, or unparseable.
/// Uses page_allocator for temporary file read; result is self-contained (no allocations to free).
pub fn loadPeers(home_dir: []const u8) ?PeerList {
    const alloc = std.heap.page_allocator;
    const path = std.fs.path.join(alloc, &[_][]const u8{ home_dir, "peers.json" }) catch return null;
    defer alloc.free(path);

    var file = compat.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    // Read up to 4KB — plenty for 8 peer entries
    var buf: [4096]u8 = undefined;
    const len = file.readAll(&buf) catch return null;
    if (len == 0) return null;

    const data = buf[0..len];
    return parsePeersJson(data);
}

/// Parse peers JSON: {"peers": [{"host": "...", "port": N}, ...]}
/// Substring-based parser — no allocator needed.
fn parsePeersJson(data: []const u8) ?PeerList {
    var result = PeerList{};

    // Find "peers" array
    const peers_key = std.mem.indexOf(u8, data, "\"peers\"") orelse return null;
    const after_key = data[peers_key + 7 ..];
    const arr_start = std.mem.indexOfScalar(u8, after_key, '[') orelse return null;
    const arr_data = after_key[arr_start + 1 ..];

    // Parse each object in the array
    var pos: usize = 0;
    while (result.count < MAX_PEERS) {
        // Find next object
        const obj_start = std.mem.indexOfScalarPos(u8, arr_data, pos, '{') orelse break;
        const obj_end = std.mem.indexOfScalarPos(u8, arr_data, obj_start, '}') orelse break;
        const obj = arr_data[obj_start .. obj_end + 1];
        pos = obj_end + 1;

        var entry = PeerEntry{};

        // Extract host
        if (extractStringValue(obj, "host")) |h| {
            if (h.len > 0 and h.len <= 64) {
                @memcpy(entry.host_buf[0..h.len], h);
                entry.host_len = @intCast(h.len);
            } else continue; // skip invalid
        } else continue; // skip entries without host

        // Extract port
        if (extractIntValue(obj, "port")) |p| {
            if (p > 0 and p <= 65535) {
                entry.port = @intCast(p);
            }
            // else keep default 3001
        }

        result.entries[result.count] = entry;
        result.count += 1;
    }

    if (result.count == 0) return null;
    return result;
}

/// Extract a string value for a given key from a JSON-like substring.
/// e.g. extractStringValue('{"host": "1.2.3.4"}', "host") -> "1.2.3.4"
fn extractStringValue(obj: []const u8, key: []const u8) ?[]const u8 {
    // Search for "key"
    var search_buf: [68]u8 = undefined;
    if (key.len + 2 > search_buf.len) return null;
    search_buf[0] = '"';
    @memcpy(search_buf[1 .. 1 + key.len], key);
    search_buf[1 + key.len] = '"';
    const needle = search_buf[0 .. key.len + 2];

    const key_pos = std.mem.indexOf(u8, obj, needle) orelse return null;
    const after = obj[key_pos + needle.len ..];

    // Skip colon and whitespace
    var i: usize = 0;
    while (i < after.len and (after[i] == ':' or after[i] == ' ' or after[i] == '\t')) : (i += 1) {}
    if (i >= after.len or after[i] != '"') return null;
    i += 1; // skip opening quote

    const val_start = i;
    while (i < after.len and after[i] != '"') : (i += 1) {}
    if (i >= after.len) return null;

    return after[val_start..i];
}

/// Extract an integer value for a given key.
fn extractIntValue(obj: []const u8, key: []const u8) ?u64 {
    var search_buf: [68]u8 = undefined;
    if (key.len + 2 > search_buf.len) return null;
    search_buf[0] = '"';
    @memcpy(search_buf[1 .. 1 + key.len], key);
    search_buf[1 + key.len] = '"';
    const needle = search_buf[0 .. key.len + 2];

    const key_pos = std.mem.indexOf(u8, obj, needle) orelse return null;
    const after = obj[key_pos + needle.len ..];

    // Skip colon and whitespace
    var i: usize = 0;
    while (i < after.len and (after[i] == ':' or after[i] == ' ' or after[i] == '\t')) : (i += 1) {}
    if (i >= after.len) return null;

    // Parse digits
    const val_start = i;
    while (i < after.len and after[i] >= '0' and after[i] <= '9') : (i += 1) {}
    if (i == val_start) return null;

    return std.fmt.parseUnsigned(u64, after[val_start..i], 10) catch null;
}

// --- Tests ---

test "parsePeersJson basic" {
    const json =
        \\{"peers": [{"host": "1.2.3.4", "port": 3001}, {"host": "5.6.7.8", "port": 3002}]}
    ;
    const result = parsePeersJson(json) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqualStrings("1.2.3.4", result.entries[0].host());
    try std.testing.expectEqual(@as(u16, 3001), result.entries[0].port);
    try std.testing.expectEqualStrings("5.6.7.8", result.entries[1].host());
    try std.testing.expectEqual(@as(u16, 3002), result.entries[1].port);
}

test "parsePeersJson default port" {
    const json =
        \\{"peers": [{"host": "10.0.0.1"}]}
    ;
    const result = parsePeersJson(json) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqualStrings("10.0.0.1", result.entries[0].host());
    try std.testing.expectEqual(@as(u16, 3001), result.entries[0].port);
}

test "parsePeersJson max peers" {
    const json =
        \\{"peers": [
        \\  {"host": "1.0.0.1", "port": 3001},
        \\  {"host": "1.0.0.2", "port": 3001},
        \\  {"host": "1.0.0.3", "port": 3001},
        \\  {"host": "1.0.0.4", "port": 3001},
        \\  {"host": "1.0.0.5", "port": 3001},
        \\  {"host": "1.0.0.6", "port": 3001},
        \\  {"host": "1.0.0.7", "port": 3001},
        \\  {"host": "1.0.0.8", "port": 3001},
        \\  {"host": "1.0.0.9", "port": 3001}
        \\]}
    ;
    const result = parsePeersJson(json) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(usize, 8), result.count); // capped at MAX_PEERS
}

test "parsePeersJson empty" {
    const json = "{}";
    try std.testing.expect(parsePeersJson(json) == null);
}

test "parsePeersJson no peers key" {
    const json =
        \\{"relays": [{"host": "1.2.3.4"}]}
    ;
    try std.testing.expect(parsePeersJson(json) == null);
}

test "parsePeersJson empty array" {
    const json =
        \\{"peers": []}
    ;
    try std.testing.expect(parsePeersJson(json) == null);
}
