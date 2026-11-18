const std = @import("std");
const compat = @import("compat");
const tsf = @import("tsf.zig");
const snapshot_cmd = @import("snapshot_cmd.zig");
const Ed25519 = std.crypto.sign.Ed25519;

fn defaultKeyDir(alloc: std.mem.Allocator) ![]u8 {
    const home = try compat.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(home);
    return try std.fs.path.join(alloc, &[_][]const u8{ home, ".local", "tsunagi", "keys" });
}

fn defaultKeyPath(alloc: std.mem.Allocator) ![]u8 {
    const dir = try defaultKeyDir(alloc);
    defer alloc.free(dir);
    return try std.fs.path.join(alloc, &[_][]const u8{ dir, "snapshot_ed25519.key" });
}

fn defaultPubPath(alloc: std.mem.Allocator) ![]u8 {
    const dir = try defaultKeyDir(alloc);
    defer alloc.free(dir);
    return try std.fs.path.join(alloc, &[_][]const u8{ dir, "snapshot_ed25519.pub" });
}

/// Public wrapper for importSnapshot to check default pubkey path.
pub fn defaultPubPathAlloc(alloc: std.mem.Allocator) ![]u8 {
    return defaultPubPath(alloc);
}

fn readHexKey32(alloc: std.mem.Allocator, path: []const u8) ![32]u8 {
    var f = try compat.fs.cwd().openFile(path, .{});
    defer f.close();
    const raw = try f.readToEndAlloc(alloc, 4096);
    defer alloc.free(raw);
    // Trim whitespace/newlines
    const hex = std.mem.trim(u8, raw, " \t\r\n");
    if (hex.len != 64) return error.InvalidKeyLength;
    var out: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, hex);
    return out;
}

fn writeHexKey32(alloc: std.mem.Allocator, path: []const u8, key: [32]u8) !void {
    _ = alloc;
    if (std.fs.path.dirname(path)) |dir| {
        compat.fs.cwd().makePath(dir) catch {};
    }
    var f = try compat.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();
    try f.deprecatedWriter().print("{x}\n", .{&key});
}

/// Compute Blake2b-256 digest of TSF file (excluding footer).
pub fn computeTsfDigest(alloc: std.mem.Allocator, path: []const u8) ![32]u8 {
    var f = try compat.fs.cwd().openFile(path, .{});
    defer f.close();
    const bytes = try f.readToEndAlloc(alloc, 2 * 1024 * 1024 * 1024);
    defer alloc.free(bytes);
    if (bytes.len < @sizeOf(tsf.Header) + @sizeOf(tsf.Footer)) return error.InvalidSnapshot;
    const payload = bytes[0 .. bytes.len - @sizeOf(tsf.Footer)];
    var h = std.crypto.hash.blake2.Blake2b256.init(.{});
    h.update(payload);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return digest;
}

/// Sign a 32-byte digest using an Ed25519 seed and write base64 signature to sig_path.
pub fn signDigest(alloc: std.mem.Allocator, digest: [32]u8, key_path_opt: ?[]const u8, sig_path: []const u8) !void {
    const key_path = if (key_path_opt) |p|
        try alloc.dupe(u8, p)
    else blk: {
        const env = compat.getEnvVarOwned(alloc, "TSUNAGI_SNAPSHOT_KEY") catch null;
        if (env) |e| break :blk e;
        break :blk try defaultKeyPath(alloc);
    };
    defer alloc.free(key_path);

    const seed = readHexKey32(alloc, key_path) catch |err| {
        std.debug.print("snapshot-sign: cannot read key {s}: {s}\n", .{ key_path, @errorName(err) });
        return err;
    };

    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const sig = try kp.sign(&digest, null);

    // Base64 encode the 64-byte signature
    const enc = std.base64.standard.Encoder;
    var b64_buf: [enc.calcSize(64)]u8 = undefined;
    const b64 = enc.encode(&b64_buf, &sig.toBytes());

    // Atomic write: write to .tmp then rename
    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{sig_path});
    defer alloc.free(tmp_path);

    {
        var f = try compat.fs.cwd().createFile(tmp_path, .{ .truncate = true });
        defer f.close();
        try f.deprecatedWriter().print("{x}\n", .{b64});
    }

    // Rename .tmp → final path
    compat.fs.cwd().rename(tmp_path, sig_path) catch |err| {
        // Fallback: if rename fails (cross-device), write directly
        std.debug.print("snapshot-sign: rename failed ({s}), writing directly\n", .{@errorName(err)});
        compat.fs.cwd().deleteFile(tmp_path) catch {};
        var f2 = try compat.fs.cwd().createFile(sig_path, .{ .truncate = true });
        defer f2.close();
        try f2.deprecatedWriter().print("{x}\n", .{b64});
    };

    std.debug.print("snapshot-sign: signature written {s}\n", .{sig_path});
}

/// Verify a TSF file's digest against a base64 signature and Ed25519 public key.
pub fn verifyDigest(
    alloc: std.mem.Allocator,
    digest: [32]u8,
    sig_path: []const u8,
    pubkey_hex_opt: ?[]const u8,
    pubkey_file_opt: ?[]const u8,
) !bool {
    // Load signature from file
    var sig_f = compat.fs.cwd().openFile(sig_path, .{}) catch |err| {
        std.debug.print("snapshot-verify: cannot open signature file {s}: {s}\n", .{ sig_path, @errorName(err) });
        return err;
    };
    defer sig_f.close();
    const sig_raw = try sig_f.readToEndAlloc(alloc, 4096);
    defer alloc.free(sig_raw);
    const sig_b64 = std.mem.trim(u8, sig_raw, " \t\r\n");

    // Validate base64 length and padding before decoding
    // Ed25519 sig = 64 bytes → base64 = 88 chars with "==" padding
    const expected_b64_len = std.base64.standard.Encoder.calcSize(64);
    if (sig_b64.len != expected_b64_len) {
        std.debug.print("snapshot-verify: invalid signature length (expected {d} base64 chars, got {d})\n", .{ expected_b64_len, sig_b64.len });
        return false;
    }

    // Check decoded size matches 64 bytes (padding determines exact size)
    // 64 bytes: 64 mod 3 = 1, so valid encoding has "==" padding
    const decoded_size = blk: {
        var pad: usize = 0;
        if (sig_b64.len > 0 and sig_b64[sig_b64.len - 1] == '=') pad += 1;
        if (sig_b64.len > 1 and sig_b64[sig_b64.len - 2] == '=') pad += 1;
        break :blk sig_b64.len / 4 * 3 - pad;
    };
    if (decoded_size != 64) {
        std.debug.print("snapshot-verify: invalid signature: decoded size {d} != 64\n", .{decoded_size});
        return false;
    }

    // Base64 decode
    const dec = std.base64.standard.Decoder;
    var sig_bytes: [64]u8 = undefined;
    dec.decode(&sig_bytes, sig_b64) catch {
        std.debug.print("snapshot-verify: invalid base64 in signature file\n", .{});
        return false;
    };

    // Load public key
    var pub_bytes: [32]u8 = undefined;
    if (pubkey_hex_opt) |hex| {
        if (hex.len != 64) {
            std.debug.print("snapshot-verify: pubkey hex must be 64 chars\n", .{});
            return false;
        }
        _ = std.fmt.hexToBytes(&pub_bytes, hex) catch {
            std.debug.print("snapshot-verify: invalid pubkey hex\n", .{});
            return false;
        };
    } else if (pubkey_file_opt) |p| {
        // Explicit --pubkey-file: propagate error (exit 1) if unreadable
        const pub_path = try alloc.dupe(u8, p);
        defer alloc.free(pub_path);
        pub_bytes = readHexKey32(alloc, pub_path) catch |err| {
            std.debug.print("snapshot-verify: cannot read pubkey file {s}: {s}\n", .{ pub_path, @errorName(err) });
            return err;
        };
    } else {
        const pub_path = defaultPubPath(alloc) catch {
            std.debug.print("snapshot-verify: no pubkey specified and default not found\n", .{});
            return false;
        };
        defer alloc.free(pub_path);
        pub_bytes = readHexKey32(alloc, pub_path) catch |err| {
            std.debug.print("snapshot-verify: cannot read pubkey {s}: {s}\n", .{ pub_path, @errorName(err) });
            return false;
        };
    }

    // Verify
    const sig = Ed25519.Signature.fromBytes(sig_bytes);
    const pk = Ed25519.PublicKey.fromBytes(pub_bytes) catch {
        std.debug.print("snapshot-verify: invalid public key\n", .{});
        return false;
    };
    sig.verify(&digest, pk) catch return false;
    return true;
}

// ── CLI entry points ─────────────────────────────────────────────────

pub fn keygen(alloc: std.mem.Allocator) !void {
    const key_dir = try defaultKeyDir(alloc);
    defer alloc.free(key_dir);
    try compat.fs.cwd().makePath(key_dir);

    var seed: [32]u8 = undefined;
    compat.cryptoRandomBytes(&seed);

    const kp = try Ed25519.KeyPair.generateDeterministic(seed);

    const key_path = try std.fs.path.join(alloc, &[_][]const u8{ key_dir, "snapshot_ed25519.key" });
    defer alloc.free(key_path);
    try writeHexKey32(alloc, key_path, seed);

    // chmod 0600 on private key
    var key_file = compat.fs.cwd().openFile(key_path, .{}) catch |err| {
        std.debug.print("snapshot-keygen: warning: could not chmod key: {s}\n", .{@errorName(err)});
        return;
    };
    defer key_file.close();
    key_file.chmod(0o600) catch {};

    const pub_path = try std.fs.path.join(alloc, &[_][]const u8{ key_dir, "snapshot_ed25519.pub" });
    defer alloc.free(pub_path);
    try writeHexKey32(alloc, pub_path, kp.public_key.toBytes());

    std.debug.print("snapshot-keygen: keys written to {s}/\n", .{key_dir});
    std.debug.print("Public key (hex): {x}\n", .{&kp.public_key.toBytes()});
}

pub fn signFile(alloc: std.mem.Allocator, file_path: []const u8, key_path_opt: ?[]const u8) !void {
    const digest = try computeTsfDigest(alloc, file_path);
    std.debug.print("snapshot-sign: digest={x}\n", .{&digest});

    const sig_path = try std.fmt.allocPrint(alloc, "{s}.sig", .{file_path});
    defer alloc.free(sig_path);

    try signDigest(alloc, digest, key_path_opt, sig_path);
}

pub fn verifyFile(
    alloc: std.mem.Allocator,
    file_path: []const u8,
    sig_path_opt: ?[]const u8,
    pubkey_hex_opt: ?[]const u8,
    pubkey_file_opt: ?[]const u8,
) !bool {
    const digest = try computeTsfDigest(alloc, file_path);
    std.debug.print("snapshot-verify: digest={x}\n", .{&digest});

    const sig_path = if (sig_path_opt) |p|
        try alloc.dupe(u8, p)
    else
        try std.fmt.allocPrint(alloc, "{s}.sig", .{file_path});
    defer alloc.free(sig_path);

    const valid = try verifyDigest(alloc, digest, sig_path, pubkey_hex_opt, pubkey_file_opt);

    if (valid) {
        std.debug.print("Signature: VALID\n", .{});
    } else {
        std.debug.print("Signature: INVALID\n", .{});
    }

    // Print TSF2 anchors
    var f = compat.fs.cwd().openFile(file_path, .{}) catch return valid;
    defer f.close();
    const hdr = tsf.readHeader(f.deprecatedReader()) catch return valid;
    if (std.mem.eql(u8, hdr.magic[0..], tsf.MAGIC)) {
        std.debug.print("snapshot-verify: anchor metadata\n", .{});
        snapshot_cmd.printAnchor(hdr);
    }

    return valid;
}
