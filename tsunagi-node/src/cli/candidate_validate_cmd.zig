const std = @import("std");
const compat = @import("compat");
const candidate_validator = @import("../net/consensus/candidate_validator.zig");

/// Candidate artifact bundle validation CLI.
///
/// Validates a locally produced candidate artifact bundle from disk.
/// Supports two naming conventions:
///   Shadow bundle:   shadow-candidate-header.cbor, shadow-candidate-block.cbor, shadow-candidate-hashes.json
///   Producer bundle: candidate-header.cbor, candidate-block.cbor, candidate-hashes.json
///
/// Usage:
///   tsunagi-node candidate-validate --bundle-dir <path> [--out <path>]
///
/// Exit codes: 0 = valid, 2 = validation failed, 3 = missing files/args.
pub fn run(_: std.mem.Allocator, args_it: anytype) u8 {
    var bundle_dir: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bundle-dir")) {
            bundle_dir = args_it.next() orelse {
                std.debug.print("ERROR: --bundle-dir requires a path\n", .{});
                return 3;
            };
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_path = args_it.next() orelse {
                std.debug.print("ERROR: --out requires a path\n", .{});
                return 3;
            };
        }
    }

    const dir = bundle_dir orelse {
        std.debug.print(
            \\Usage: tsunagi-node candidate-validate --bundle-dir <path> [--out <path>]
            \\
            \\Validates a candidate artifact bundle from disk.
            \\Supports shadow bundle (shadow-candidate-*) and producer bundle (candidate-*) naming.
            \\
        , .{});
        return 3;
    };

    // Detect bundle naming convention
    const convention = detectConvention(dir);
    if (convention == .none) {
        std.debug.print("ERROR: no candidate artifact bundle found in {s}\n", .{dir});
        std.debug.print("  Expected either:\n", .{});
        std.debug.print("    shadow-candidate-header.cbor + shadow-candidate-block.cbor + shadow-candidate-hashes.json\n", .{});
        std.debug.print("    candidate-header.cbor + candidate-block.cbor + candidate-hashes.json\n", .{});
        return 3;
    }

    const conv_label = switch (convention) {
        .shadow => "shadow",
        .producer => "producer",
        .none => unreachable,
    };
    std.debug.print("=== Candidate Validate ===\ndir={s}\nconvention={s}\n\n", .{ dir, conv_label });

    // Read artifact files
    var header_buf: [4096]u8 = undefined;
    const header_name = switch (convention) {
        .shadow => "shadow-candidate-header.cbor",
        .producer => "candidate-header.cbor",
        .none => unreachable,
    };
    const header_len = readFile(dir, header_name, &header_buf) orelse {
        std.debug.print("ERROR: cannot read {s}/{s}\n", .{ dir, header_name });
        return 3;
    };

    var block_buf: [8192]u8 = undefined;
    const block_name = switch (convention) {
        .shadow => "shadow-candidate-block.cbor",
        .producer => "candidate-block.cbor",
        .none => unreachable,
    };
    const block_len = readFile(dir, block_name, &block_buf) orelse {
        std.debug.print("ERROR: cannot read {s}/{s}\n", .{ dir, block_name });
        return 3;
    };

    var hashes_buf: [4096]u8 = undefined;
    const hashes_name = switch (convention) {
        .shadow => "shadow-candidate-hashes.json",
        .producer => "candidate-hashes.json",
        .none => unreachable,
    };
    const hashes_len = readFile(dir, hashes_name, &hashes_buf) orelse {
        std.debug.print("ERROR: cannot read {s}/{s}\n", .{ dir, hashes_name });
        return 3;
    };
    const hashes_json = hashes_buf[0..hashes_len];

    // Parse expected hashes from JSON
    const block_hash_hex = findJsonStringValue(hashes_json, "block_hash") orelse {
        std.debug.print("ERROR: {s} missing block_hash field\n", .{hashes_name});
        return 3;
    };
    if (block_hash_hex.len != 64) {
        std.debug.print("ERROR: block_hash is {d} hex chars, expected 64\n", .{block_hash_hex.len});
        return 3;
    }
    var expected_block_hash: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected_block_hash, block_hash_hex) catch {
        std.debug.print("ERROR: block_hash contains invalid hex\n", .{});
        return 3;
    };

    const body_hash_hex = findJsonStringValue(hashes_json, "body_hash") orelse {
        std.debug.print("ERROR: {s} missing body_hash field\n", .{hashes_name});
        return 3;
    };
    if (body_hash_hex.len != 64) {
        std.debug.print("ERROR: body_hash is {d} hex chars, expected 64\n", .{body_hash_hex.len});
        return 3;
    }
    var expected_body_hash: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected_body_hash, body_hash_hex) catch {
        std.debug.print("ERROR: body_hash contains invalid hex\n", .{});
        return 3;
    };

    // Run validation
    const report = candidate_validator.validate(
        header_buf[0..header_len],
        block_buf[0..block_len],
        expected_block_hash,
        expected_body_hash,
    );

    // Format JSON report
    var json_buf: [2048]u8 = undefined;
    const json_str = candidate_validator.formatReportJson(&report, &json_buf) orelse {
        std.debug.print("ERROR: report JSON formatting failed\n", .{});
        return 3;
    };

    // Print report
    std.debug.print("{s}\n", .{json_str});

    // Write to file if --out specified
    if (out_path) |op| {
        var f = compat.fs.cwd().createFile(op, .{}) catch {
            std.debug.print("ERROR: cannot create output file {s}\n", .{op});
            return 3;
        };
        defer f.close();
        _ = f.write(json_str) catch {
            std.debug.print("ERROR: cannot write to {s}\n", .{op});
            return 3;
        };
        _ = f.write("\n") catch {};
        std.debug.print("report written to {s}\n", .{op});
    }

    // Exit code
    if (report.state == .valid) {
        std.debug.print("\nPASS: candidate validation succeeded ({s} bundle)\n", .{conv_label});
        return 0;
    } else {
        const state_label = switch (report.state) {
            .valid => "valid",
            .invalid_structure => "invalid_structure",
            .invalid_hash => "invalid_hash",
            .invalid_signature => "invalid_signature",
            .invalid_consistency => "invalid_consistency",
            .error_state => "error_state",
        };
        std.debug.print("\nFAIL: candidate validation failed — {s}\n", .{state_label});
        return 2;
    }
}

// ── Bundle convention detection ──

const Convention = enum { shadow, producer, none };

fn detectConvention(dir: []const u8) Convention {
    // Try shadow naming first
    if (fileExists(dir, "shadow-candidate-header.cbor") and
        fileExists(dir, "shadow-candidate-block.cbor") and
        fileExists(dir, "shadow-candidate-hashes.json"))
    {
        return .shadow;
    }
    // Try producer naming
    if (fileExists(dir, "candidate-header.cbor") and
        fileExists(dir, "candidate-block.cbor") and
        fileExists(dir, "candidate-hashes.json"))
    {
        return .producer;
    }
    return .none;
}

fn fileExists(dir: []const u8, name: []const u8) bool {
    var path_buf: [600]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return false;
    var f = compat.fs.cwd().openFile(path, .{}) catch return false;
    f.close();
    return true;
}

// ── File reading ──

fn readFile(dir: []const u8, name: []const u8, buf: []u8) ?usize {
    var path_buf: [600]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return null;
    var f = compat.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    const n = f.readAll(buf) catch return null;
    return n;
}

// ── Minimal JSON string value parser ──

fn findJsonStringValue(json: []const u8, key: []const u8) ?[]const u8 {
    // Try "key":"value"
    var search_buf: [128]u8 = undefined;
    const needle1 = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    if (std.mem.indexOf(u8, json, needle1)) |pos| {
        const start = pos + needle1.len;
        const end = std.mem.indexOf(u8, json[start..], "\"") orelse return null;
        return json[start .. start + end];
    }
    // Try "key": "value" (with space)
    var search_buf2: [128]u8 = undefined;
    const needle2 = std.fmt.bufPrint(&search_buf2, "\"{s}\": \"", .{key}) catch return null;
    if (std.mem.indexOf(u8, json, needle2)) |pos| {
        const start = pos + needle2.len;
        const end = std.mem.indexOf(u8, json[start..], "\"") orelse return null;
        return json[start .. start + end];
    }
    return null;
}
