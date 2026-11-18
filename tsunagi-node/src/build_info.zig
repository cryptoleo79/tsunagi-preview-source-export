const std = @import("std");
const compat = @import("compat");
const build_options = @import("build_options");

// ── Build Identity (v4.2.0 — Layer A) ──────────────────────────────
//
// Embedded at compile time. No network, no secrets, bounded output.

pub const BuildInfo = struct {
    git_commit: []const u8,
    git_tag: []const u8,
    source_dirty: bool,
    zig_version: []const u8,
    build_mode: []const u8,
    target_triple: []const u8,
    build_epoch: u64,
};

pub const info = BuildInfo{
    .git_commit = build_options.commit,
    .git_tag = build_options.git_tag,
    .source_dirty = build_options.source_dirty,
    .zig_version = build_options.zig_version,
    .build_mode = build_options.optimize,
    .target_triple = build_options.target_triple,
    .build_epoch = build_options.build_epoch,
};

/// One-line human-readable version string (bounded).
/// Format: tsunagi-node <tag> (<commit>) <mode> <target> zig=<ver> dirty=<0/1>
pub fn printVersionLine(writer: anytype) !void {
    try writer.print("tsunagi-node {s} ({s}) {s} {s} zig={s} dirty={d}\n", .{
        info.git_tag,
        info.git_commit,
        info.build_mode,
        info.target_triple,
        info.zig_version,
        @as(u8, if (info.source_dirty) 1 else 0),
    });
}

/// Stable JSON output (bounded).
pub fn printJson(writer: anytype) !void {
    try writer.print(
        \\{{"git_commit":"{s}","git_tag":"{s}","source_dirty":{s},"zig_version":"{s}","build_mode":"{s}","target_triple":"{s}","build_epoch":{d}}}
    , .{
        info.git_commit,
        info.git_tag,
        if (info.source_dirty) "true" else "false",
        info.zig_version,
        info.build_mode,
        info.target_triple,
        info.build_epoch,
    });
    try writer.print("\n", .{});
}

/// Write build-info JSON to a file at the given path.
pub fn writeJsonFile(path: []const u8) bool {
    var f = compat.fs.cwd().createFile(path, .{ .truncate = true }) catch return false;
    defer f.close();
    printJson(f.writer()) catch return false;
    return true;
}
