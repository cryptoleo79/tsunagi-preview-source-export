const std = @import("std");
const compat = @import("compat");
const kes_keyfile = @import("../producer/kes_keyfile.zig");

/// Inspect a KES key file and print metadata.
/// Exit codes: 0 = OK, 3 = missing file/args, 4 = malformed encoding.
pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var key_path: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--key")) {
            key_path = args_it.next() orelse {
                std.debug.print("ERROR: --key requires a path\n", .{});
                return 3;
            };
        }
    }

    if (key_path == null) {
        std.debug.print("Usage: tsunagi-node kes-inspect --key <path>\n", .{});
        return 3;
    }
    const path = key_path.?;

    // Read file
    var f = compat.fs.cwd().openFile(path, .{ .mode = .read_only }) catch {
        std.debug.print("ERROR: cannot open {s}\n", .{path});
        return 3;
    };
    defer f.close();
    const content = f.readToEndAlloc(alloc, 65536) catch {
        std.debug.print("ERROR: cannot read {s}\n", .{path});
        return 3;
    };
    defer alloc.free(content);

    std.debug.print("path: {s}\n", .{path});
    std.debug.print("file_size: {d}\n", .{content.len});

    // Check if JSON key file
    if (kes_keyfile.isJsonKeyFile(content)) {
        const kf = kes_keyfile.readKeyJson(content) orelse {
            std.debug.print("detected_format: cardano_json (malformed)\n", .{});
            std.debug.print("ERROR: failed to parse JSON key envelope\n", .{});
            return 4;
        };

        std.debug.print("detected_format: cardano_json\n", .{});
        std.debug.print("type: {s}\n", .{kf.type_str});
        if (kf.description.len > 0) {
            std.debug.print("description: {s}\n", .{kf.description});
        }
        std.debug.print("cbor_hex_len: {d}\n", .{kf.cbor_hex.len});

        // Decode cborHex
        var decoded_buf: [4096]u8 = undefined;
        const decoded_len = kes_keyfile.decodeCborHex(kf.cbor_hex, &decoded_buf) orelse {
            std.debug.print("decoded_len: ERROR (malformed cborHex)\n", .{});
            return 4;
        };

        std.debug.print("decoded_len: {d}\n", .{decoded_len});

        const kind = kes_keyfile.classifyKesKey(kf.type_str, decoded_len);
        const kind_str = switch (kind) {
            .placeholder_seed => "placeholder_seed",
            .cardano_kes => "cardano_kes",
            .unknown => "unknown",
        };
        std.debug.print("kes_key_kind: {s}\n", .{kind_str});

        return 0;
    }

    // Not JSON — check if placeholder seed
    var trimmed = content;
    while (trimmed.len > 0 and (trimmed[trimmed.len - 1] == '\n' or trimmed[trimmed.len - 1] == '\r')) {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }

    if (trimmed.len == 32 or trimmed.len == 64) {
        std.debug.print("detected_format: placeholder_seed\n", .{});
        std.debug.print("kes_key_kind: placeholder_seed\n", .{});
        std.debug.print("seed_input_len: {d}\n", .{trimmed.len});
        return 0;
    }

    std.debug.print("detected_format: unknown\n", .{});
    std.debug.print("kes_key_kind: unknown\n", .{});
    std.debug.print("content_len_trimmed: {d}\n", .{trimmed.len});
    return 0;
}
