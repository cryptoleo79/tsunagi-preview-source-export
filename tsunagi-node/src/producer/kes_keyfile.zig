const std = @import("std");

/// Classification of KES key file contents.
pub const KesKeyKind = enum {
    placeholder_seed, // raw 32-byte seed or 64 hex chars
    cardano_kes, // cardano-cli JSON with cborHex, decoded len != 32
    unknown,
};

/// Parsed cardano-cli JSON key envelope.
pub const KeyFile = struct {
    type_str: []const u8,
    description: []const u8,
    cbor_hex: []const u8,
};

/// Read a cardano-cli JSON key file and extract type, description, cborHex.
/// Uses simple substring parsing (no std.json).
pub fn readKeyJson(content: []const u8) ?KeyFile {
    const type_str = findJsonStringValue(content, "type") orelse return null;
    const cbor_hex = findJsonStringValue(content, "cborHex") orelse return null;
    const description = findJsonStringValue(content, "description") orelse "";
    return KeyFile{
        .type_str = type_str,
        .description = description,
        .cbor_hex = cbor_hex,
    };
}

/// Decode a cborHex string to raw bytes.
/// Strips the leading CBOR length prefix (e.g. 5820, 5840, 590100, etc.)
/// and returns the payload bytes written into the provided buffer.
/// Returns number of bytes decoded, or null on error.
pub fn decodeCborHex(hex: []const u8, out: []u8) ?usize {
    if (hex.len < 4) return null;
    if (hex.len % 2 != 0) return null;

    // Full hex decode first into a temp area
    const total_bytes = hex.len / 2;
    if (total_bytes > out.len) return null;

    var tmp: [4096]u8 = undefined;
    if (total_bytes > tmp.len) return null;
    _ = std.fmt.hexToBytes(tmp[0..total_bytes], hex) catch return null;

    // Parse CBOR byte string prefix to find payload offset
    const payload_offset = parseCborByteStringPrefix(tmp[0..total_bytes]) orelse return null;
    const payload_len = total_bytes - payload_offset;

    @memcpy(out[0..payload_len], tmp[payload_offset .. payload_offset + payload_len]);
    return payload_len;
}

/// Classify a KES key based on type string and decoded payload length.
pub fn classifyKesKey(type_str: []const u8, decoded_len: usize) KesKeyKind {
    if (decoded_len == 32) return .placeholder_seed;

    // Real Cardano KES keys are MMM-based sum composition trees.
    // Typical sizes: 608 bytes (depth 6), ~1200+ (depth 7).
    // Accept any key with a known Cardano KES type string and reasonable length.
    if (isCardanoKesType(type_str) and decoded_len > 32 and decoded_len <= 8192) {
        return .cardano_kes;
    }

    return .unknown;
}

/// Check if a type string looks like a Cardano KES signing key.
fn isCardanoKesType(type_str: []const u8) bool {
    // cardano-cli produces: "KesSigningKey_ed25519_kes_2^6"
    // or "KesSigningKey_..." variants
    if (std.mem.startsWith(u8, type_str, "KesSigningKey")) return true;
    if (std.mem.indexOf(u8, type_str, "kes") != null) return true;
    if (std.mem.indexOf(u8, type_str, "Kes") != null) return true;
    if (std.mem.indexOf(u8, type_str, "KES") != null) return true;
    return false;
}

/// Detect if file content is a cardano-cli JSON key envelope.
/// Returns true if content starts with '{' and contains "cborHex".
pub fn isJsonKeyFile(content: []const u8) bool {
    var i: usize = 0;
    while (i < content.len and (content[i] == ' ' or content[i] == '\n' or content[i] == '\r' or content[i] == '\t')) : (i += 1) {}
    if (i >= content.len or content[i] != '{') return false;
    return std.mem.indexOf(u8, content, "\"cborHex\"") != null;
}

/// Parse CBOR byte string prefix and return the offset where payload begins.
/// Handles major type 2 (byte string): 58xx (1-byte len), 59xxxx (2-byte len).
fn parseCborByteStringPrefix(bytes: []const u8) ?usize {
    if (bytes.len < 2) return null;
    const major = bytes[0] & 0xe0; // top 3 bits
    const info = bytes[0] & 0x1f; // bottom 5 bits
    if (major != 0x40) return null; // must be major type 2 (byte string)

    if (info < 24) {
        // length is info itself (0-23 bytes)
        return 1;
    } else if (info == 24) {
        // next 1 byte is length
        if (bytes.len < 2) return null;
        return 2;
    } else if (info == 25) {
        // next 2 bytes are length
        if (bytes.len < 3) return null;
        return 3;
    } else if (info == 26) {
        // next 4 bytes are length
        if (bytes.len < 5) return null;
        return 5;
    }
    return null;
}

/// Find a JSON string value for a given key using simple substring search.
fn findJsonStringValue(json: []const u8, key: []const u8) ?[]const u8 {
    // Try both "key":"value" and "key": "value" (with optional space)
    var search_buf: [128]u8 = undefined;

    // Try without space
    const needle1 = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    if (std.mem.indexOf(u8, json, needle1)) |pos| {
        const start = pos + needle1.len;
        const end = std.mem.indexOf(u8, json[start..], "\"") orelse return null;
        return json[start .. start + end];
    }

    // Try with space after colon
    var search_buf2: [128]u8 = undefined;
    const needle2 = std.fmt.bufPrint(&search_buf2, "\"{s}\": \"", .{key}) catch return null;
    if (std.mem.indexOf(u8, json, needle2)) |pos| {
        const start = pos + needle2.len;
        const end = std.mem.indexOf(u8, json[start..], "\"") orelse return null;
        return json[start .. start + end];
    }

    return null;
}
