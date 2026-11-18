const std = @import("std");
const compat = @import("compat");
const build_info = @import("../build_info.zig");

// ── repro-report command (v4.2.0) ──────────────────────────────────
//
// Read-only environment reporter for reproducibility verification.
// No network calls. No secrets. Bounded output.

const c = @cImport({
    @cInclude("sodium.h");
});

pub fn run(_: std.mem.Allocator, args_it: anytype) u8 {
    var json = false;
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        }
    }

    // Gather fields
    const bi = build_info.info;
    const sodium_ver = getSodiumVersion();
    const lmdb_ver = "unknown"; // no public version API available at link time
    const os_info = getOsInfo();
    const binary_sha256 = getBinarySha256();

    var stdout_file = compat.fs.File.stdout();
    const stdout = stdout_file.writer();
    if (json) {
        printJson(stdout, &bi, sodium_ver, lmdb_ver, os_info, binary_sha256) catch return 1;
    } else {
        printHuman(stdout, &bi, sodium_ver, lmdb_ver, os_info, binary_sha256) catch return 1;
    }
    return 0;
}

fn getSodiumVersion() []const u8 {
    const ptr = c.sodium_version_string();
    if (ptr) |p| {
        return std.mem.span(p);
    }
    return "unknown";
}

fn getOsInfo() []const u8 {
    return build_info.info.target_triple;
}

fn getBinarySha256() [64]u8 {
    var hex: [64]u8 = .{'?'} ** 64;
    if (comptime @import("builtin").os.tag == .linux) {
        var f = compat.fs.openFileAbsolute("/proc/self/exe", .{}) catch return hex;
        defer f.close();
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = f.read(&buf) catch return hex;
            if (n == 0) break;
            hasher.update(buf[0..n]);
        }
        const digest = hasher.finalResult();
        hex = std.fmt.bytesToHex(digest, .lower);
    }
    return hex;
}

fn printJson(w: anytype, bi: *const build_info.BuildInfo, sodium_ver: []const u8, lmdb_ver: []const u8, os_info: []const u8, binary_sha256: [64]u8) !void {
    try w.print("{{", .{});
    // build identity block
    try w.print("\"build\":{{", .{});
    try w.print("\"git_commit\":\"{s}\",", .{bi.git_commit});
    try w.print("\"git_tag\":\"{s}\",", .{bi.git_tag});
    try w.print("\"source_dirty\":{s},", .{if (bi.source_dirty) "true" else "false"});
    try w.print("\"zig_version\":\"{s}\",", .{bi.zig_version});
    try w.print("\"build_mode\":\"{s}\",", .{bi.build_mode});
    try w.print("\"target_triple\":\"{s}\",", .{bi.target_triple});
    try w.print("\"build_epoch\":{d}", .{bi.build_epoch});
    try w.print("}},", .{});
    // dependencies
    try w.print("\"libsodium_version\":\"{s}\",", .{sodium_ver});
    try w.print("\"lmdb_version\":\"{s}\",", .{lmdb_ver});
    // environment
    try w.print("\"os_arch\":\"{s}\",", .{os_info});
    try w.print("\"binary_sha256\":\"{s}\"", .{binary_sha256});
    try w.print("}}\n", .{});
}

fn printHuman(w: anytype, bi: *const build_info.BuildInfo, sodium_ver: []const u8, lmdb_ver: []const u8, os_info: []const u8, binary_sha256: [64]u8) !void {
    try w.print("=== Reproducibility Report (Layer A) ===\n", .{});
    try w.print("git_commit:     {s}\n", .{bi.git_commit});
    try w.print("git_tag:        {s}\n", .{bi.git_tag});
    try w.print("source_dirty:   {s}\n", .{if (bi.source_dirty) "true" else "false"});
    try w.print("zig_version:    {s}\n", .{bi.zig_version});
    try w.print("build_mode:     {s}\n", .{bi.build_mode});
    try w.print("target_triple:  {s}\n", .{bi.target_triple});
    try w.print("build_epoch:    {d}\n", .{bi.build_epoch});
    try w.print("libsodium:      {s}\n", .{sodium_ver});
    try w.print("lmdb:           {s}\n", .{lmdb_ver});
    try w.print("os_arch:        {s}\n", .{os_info});
    try w.print("binary_sha256:  {s}\n", .{binary_sha256});
}
