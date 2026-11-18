const std = @import("std");
const compat = @import("compat");
const i18n = @import("i18n.zig");
const builtin = @import("builtin");

const REPO = "cryptoleo79/tsunagi-follower";
const API_BASE = "https://api.github.com/repos/" ++ REPO;
const DL_BASE = "https://github.com/" ++ REPO ++ "/releases/download";

pub const InstallResult = struct {
    tag: []const u8,
    arch: []const u8,
    install_dir: []const u8,
};

fn p(lang: i18n.Lang, en: []const u8, ja: []const u8) []const u8 {
    return if (lang == .ja) ja else en;
}

pub fn detectArch() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "linux-arm64",
        else => "linux-amd64",
    };
}

fn runOk(alloc: std.mem.Allocator, argv: []const []const u8) bool {
    var child = compat.Child.init(argv, alloc);
    const term = child.spawnAndWait() catch return false;
    return switch (term) {
        .exited => |c| c == 0,
        else => false,
    };
}

fn runOrFail(alloc: std.mem.Allocator, argv: []const []const u8) !void {
    var child = compat.Child.init(argv, alloc);
    const term = child.spawnAndWait() catch return error.CommandFailed;
    switch (term) {
        .exited => |c| {
            if (c != 0) return error.CommandFailed;
        },
        else => return error.CommandFailed,
    }
}

// ── HTTP helper ──────────────────────────────────────────────────────

const FetchResult = struct {
    status: u16,
    body: ?[]u8,
};

/// Fetch URL via curl with GitHub API headers.
/// Only sends Authorization if TSUNAGI_GITHUB_TOKEN is set.
fn curlFetch(alloc: std.mem.Allocator, url: []const u8, out_path: []const u8, auth_header: ?[]const u8) !FetchResult {
    var argv_buf: [14][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = "curl";
    argc += 1;
    argv_buf[argc] = "-sS";
    argc += 1;
    argv_buf[argc] = "-L";
    argc += 1;
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = "User-Agent: tsunagi-node";
    argc += 1;
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = "Accept: application/vnd.github+json";
    argc += 1;
    if (auth_header) |h| {
        argv_buf[argc] = "-H";
        argc += 1;
        argv_buf[argc] = h;
        argc += 1;
    }
    argv_buf[argc] = "-w";
    argc += 1;
    argv_buf[argc] = "%{http_code}";
    argc += 1;
    argv_buf[argc] = "-o";
    argc += 1;
    argv_buf[argc] = out_path;
    argc += 1;
    argv_buf[argc] = url;
    argc += 1;

    var child = compat.Child.init(argv_buf[0..argc], alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    child.spawn() catch return error.CommandFailed;

    var status_buf: [16]u8 = undefined;
    const n = child.stdout.?.read(&status_buf) catch 0;
    const term = child.wait() catch return error.CommandFailed;
    switch (term) {
        .exited => {},
        else => return error.CommandFailed,
    }

    const status_str = std.mem.trimEnd(u8, status_buf[0..n], &[_]u8{ '\n', '\r', ' ', 0 });
    const status = std.fmt.parseInt(u16, status_str, 10) catch 0;

    const body: ?[]u8 = blk: {
        var f = compat.fs.cwd().openFile(out_path, .{}) catch break :blk null;
        defer f.close();
        break :blk f.readToEndAlloc(alloc, 4 * 1024 * 1024) catch null;
    };
    return FetchResult{ .status = status, .body = body };
}

// ── JSON parsers ─────────────────────────────────────────────────────

fn parseJsonStringValue(json: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, json, key) orelse return null;
    const after = json[key_pos + key.len ..];
    const colon = std.mem.indexOf(u8, after, ":") orelse return null;
    const q1 = std.mem.indexOfPos(u8, after, colon, "\"") orelse return null;
    const start = q1 + 1;
    const q2 = std.mem.indexOfPos(u8, after, start, "\"") orelse return null;
    return after[start..q2];
}

/// Find an asset "name" whose value ends with `suffix`, within the "assets" array.
fn findAssetBySuffix(json: []const u8, suffix: []const u8) ?[]const u8 {
    const assets_start = std.mem.indexOf(u8, json, "\"assets\"") orelse return null;
    const section = json[assets_start..];

    const key = "\"name\"";
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, section, search_from, key)) |key_pos| {
        const rest = section[key_pos + key.len ..];
        const colon = std.mem.indexOf(u8, rest, ":") orelse break;
        const q1 = std.mem.indexOfPos(u8, rest, colon, "\"") orelse break;
        const val_start = q1 + 1;
        const q2 = std.mem.indexOfPos(u8, rest, val_start, "\"") orelse break;
        const name = rest[val_start..q2];

        if (name.len >= suffix.len and std.mem.eql(u8, name[name.len - suffix.len ..], suffix)) {
            return name;
        }
        search_from = key_pos + key.len + q2 + 1;
    }
    return null;
}

/// Find an asset "name" whose value exactly equals `target`.
fn findAssetByExact(json: []const u8, target: []const u8) ?[]const u8 {
    const assets_start = std.mem.indexOf(u8, json, "\"assets\"") orelse return null;
    const section = json[assets_start..];

    const key = "\"name\"";
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, section, search_from, key)) |key_pos| {
        const rest = section[key_pos + key.len ..];
        const colon = std.mem.indexOf(u8, rest, ":") orelse break;
        const q1 = std.mem.indexOfPos(u8, rest, colon, "\"") orelse break;
        const val_start = q1 + 1;
        const q2 = std.mem.indexOfPos(u8, rest, val_start, "\"") orelse break;
        const name = rest[val_start..q2];

        if (std.mem.eql(u8, name, target)) {
            return name;
        }
        search_from = key_pos + key.len + q2 + 1;
    }
    return null;
}

/// Collect all asset "name" values for error reporting.
fn collectAssetNames(alloc: std.mem.Allocator, json: []const u8) ![][]const u8 {
    const assets_start = std.mem.indexOf(u8, json, "\"assets\"") orelse return &[_][]const u8{};
    const section = json[assets_start..];

    var names = std.array_list.Managed([]const u8).init(alloc);
    const key = "\"name\"";
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, section, search_from, key)) |key_pos| {
        const rest = section[key_pos + key.len ..];
        const colon = std.mem.indexOf(u8, rest, ":") orelse break;
        const q1 = std.mem.indexOfPos(u8, rest, colon, "\"") orelse break;
        const val_start = q1 + 1;
        const q2 = std.mem.indexOfPos(u8, rest, val_start, "\"") orelse break;
        const name = rest[val_start..q2];
        try names.append(name);
        search_from = key_pos + key.len + q2 + 1;
    }
    return names.toOwnedSlice();
}

// ── Release resolution ───────────────────────────────────────────────

const ReleaseInfo = struct {
    tag: []const u8,
    tarball_name: []const u8,
    sums_name: ?[]const u8,
};

/// Fetch release info from GitHub API and select assets for `arch`.
/// For "latest": GET /releases?per_page=1
/// For explicit tag: GET /releases/tags/<tag>
fn fetchRelease(alloc: std.mem.Allocator, install_arg: []const u8, tmp_dir: []const u8, arch: []const u8, lang: i18n.Lang) !ReleaseInfo {
    const json_path = try std.fs.path.join(alloc, &[_][]const u8{ tmp_dir, "api.json" });
    defer alloc.free(json_path);

    const arch_suffix = try std.fmt.allocPrint(alloc, "{s}.tar.gz", .{arch});
    defer alloc.free(arch_suffix);

    // Only use TSUNAGI_GITHUB_TOKEN — never inherit ambient GITHUB_TOKEN
    const token: ?[]u8 = compat.getEnvVarOwned(alloc, "TSUNAGI_GITHUB_TOKEN") catch null;
    defer if (token) |t| alloc.free(t);

    const auth_header: ?[]u8 = if (token) |t|
        std.fmt.allocPrint(alloc, "Authorization: Bearer {s}", .{t}) catch null
    else
        null;
    defer if (auth_header) |h| alloc.free(h);

    // Build API URL
    const is_latest = std.mem.eql(u8, install_arg, "latest");
    const api_url: []const u8 = if (is_latest)
        try alloc.dupe(u8, API_BASE ++ "/releases?per_page=1")
    else
        try std.fmt.allocPrint(alloc, "{s}/releases/tags/{s}", .{ API_BASE, install_arg });
    defer alloc.free(api_url);

    std.debug.print("  GET {s}\n", .{api_url});

    const r = curlFetch(alloc, api_url, json_path, auth_header) catch {
        std.debug.print("  {s}\n  URL: {s}\n", .{
            p(lang, "Failed to connect to GitHub API.", "GitHub API への接続に失敗しました。"),
            api_url,
        });
        return error.FetchFailed;
    };
    defer if (r.body) |b| alloc.free(b);

    if (r.status != 200) {
        std.debug.print("  {s} HTTP {d}\n  URL: {s}\n", .{
            p(lang, "GitHub API error:", "GitHub API エラー:"),
            r.status,
            api_url,
        });
        if (r.status == 404) {
            if (is_latest) {
                std.debug.print("  {s}\n", .{p(lang, "No releases found. Create a release first.", "リリースが見つかりません。まずリリースを作成してください。")});
            } else {
                std.debug.print("  {s} {s}\n", .{ p(lang, "No release found for tag:", "指定タグのリリースが見つかりません:"), install_arg });
            }
        }
        return error.FetchFailed;
    }

    const body = r.body orelse {
        std.debug.print("  {s}\n", .{p(lang, "Empty response from GitHub API.", "GitHub API から空のレスポンス。")});
        return error.FetchFailed;
    };

    // Parse tag_name
    const tag_raw = parseJsonStringValue(body, "\"tag_name\"") orelse {
        std.debug.print("  {s}\n", .{p(lang, "Could not parse tag_name from API response.", "API レスポンスから tag_name を解析できませんでした。")});
        return error.ParseFailed;
    };
    const tag = try alloc.dupe(u8, tag_raw);

    // Find tarball asset matching arch
    const tarball_raw = findAssetBySuffix(body, arch_suffix) orelse {
        std.debug.print("  {s} {s}\n", .{
            p(lang, "No asset found matching:", "一致するアセットが見つかりません:"),
            arch_suffix,
        });
        // List available assets for debugging
        const asset_names = collectAssetNames(alloc, body) catch &[_][]const u8{};
        defer alloc.free(asset_names);
        if (asset_names.len > 0) {
            std.debug.print("  {s}\n", .{p(lang, "Available assets:", "利用可能なアセット:")});
            for (asset_names) |name| {
                std.debug.print("    - {s}\n", .{name});
            }
        } else {
            std.debug.print("  {s}\n", .{p(lang, "Release has no assets.", "リリースにアセットがありません。")});
        }
        return error.AssetNotFound;
    };
    const tarball_name = try alloc.dupe(u8, tarball_raw);

    // Find SHA256SUMS asset (optional)
    const sums_name: ?[]const u8 = if (findAssetByExact(body, "SHA256SUMS")) |n|
        try alloc.dupe(u8, n)
    else
        null;

    std.debug.print("  -> tag={s}\n", .{tag});
    std.debug.print("  -> tarball={s}\n", .{tarball_name});
    if (sums_name) |s| std.debug.print("  -> sums={s}\n", .{s});

    return ReleaseInfo{
        .tag = tag,
        .tarball_name = tarball_name,
        .sums_name = sums_name,
    };
}

// ── Checksum helpers ─────────────────────────────────────────────────

fn sha256File(path: []const u8) ![32]u8 {
    var f = try compat.fs.cwd().openFile(path, .{});
    defer f.close();
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try f.read(&buf);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return digest;
}

fn toHex(digest: [32]u8) [64]u8 {
    const hex_chars = "0123456789abcdef";
    var hex: [64]u8 = undefined;
    for (digest, 0..) |byte, idx| {
        hex[idx * 2] = hex_chars[byte >> 4];
        hex[idx * 2 + 1] = hex_chars[byte & 0xf];
    }
    return hex;
}

// ── Main install logic ───────────────────────────────────────────────

pub fn install(alloc: std.mem.Allocator, install_arg: []const u8, lang: i18n.Lang) !InstallResult {
    const arch = detectArch();

    // Check curl
    if (!runOk(alloc, &[_][]const u8{ "which", "curl" })) {
        std.debug.print("\n{s}\n  sudo apt-get update && sudo apt-get install -y curl\n\n", .{
            p(lang, "Error: curl not found. Please install:", "エラー: curl が見つかりません。インストールしてください:"),
        });
        return error.MissingTool;
    }

    // Resolve paths
    const home = try compat.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(home);

    const base_dir = try std.fs.path.join(alloc, &[_][]const u8{ home, ".local", "tsunagi" });
    defer alloc.free(base_dir);

    const tmp_dir = try std.fs.path.join(alloc, &[_][]const u8{ base_dir, "tmp" });
    defer alloc.free(tmp_dir);

    try compat.fs.cwd().makePath(tmp_dir);

    // Fetch release info from GitHub API (both latest and explicit tag)
    std.debug.print("{s}\n", .{p(lang, "Fetching release info from GitHub...", "GitHub からリリース情報を取得中...")});
    const info = try fetchRelease(alloc, install_arg, tmp_dir, arch, lang);

    const tag = info.tag;
    const tarball_name = info.tarball_name;
    defer alloc.free(tarball_name);

    const sums_name: []const u8 = info.sums_name orelse "SHA256SUMS";

    std.debug.print("\n", .{});

    // Build download URLs from release tag + asset names
    const tarball_url = try std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ DL_BASE, tag, tarball_name });
    defer alloc.free(tarball_url);

    const sums_url = try std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ DL_BASE, tag, sums_name });
    defer alloc.free(sums_url);

    const tarball_path = try std.fs.path.join(alloc, &[_][]const u8{ tmp_dir, tarball_name });
    defer alloc.free(tarball_path);

    const sums_path = try std.fs.path.join(alloc, &[_][]const u8{ tmp_dir, "SHA256SUMS" });
    defer alloc.free(sums_path);

    // Download tarball
    std.debug.print("{s}: {s}\n", .{ p(lang, "Downloading", "ダウンロード中"), tarball_name });
    runOrFail(alloc, &[_][]const u8{ "curl", "-fL", "-o", tarball_path, tarball_url }) catch {
        std.debug.print("  {s}\n  URL: {s}\n", .{
            p(lang, "Download failed.", "ダウンロード失敗。"),
            tarball_url,
        });
        return error.DownloadFailed;
    };

    // Download SHA256SUMS (best effort)
    std.debug.print("{s}\n", .{p(lang, "Downloading SHA256SUMS...", "SHA256SUMS をダウンロード中...")});
    const sums_ok = blk: {
        runOrFail(alloc, &[_][]const u8{ "curl", "-sSfL", "-o", sums_path, sums_url }) catch break :blk false;
        break :blk true;
    };

    // Verify checksum
    if (sums_ok) {
        verify: {
            var sf = compat.fs.cwd().openFile(sums_path, .{}) catch break :verify;
            defer sf.close();
            const sums_content = sf.readToEndAlloc(alloc, 1024 * 1024) catch break :verify;
            defer alloc.free(sums_content);

            var expected_hex: ?[]const u8 = null;
            var lines = std.mem.splitScalar(u8, sums_content, '\n');
            while (lines.next()) |line| {
                if (std.mem.indexOf(u8, line, tarball_name) != null and line.len >= 64) {
                    expected_hex = line[0..64];
                    break;
                }
            }

            if (expected_hex) |expected| {
                std.debug.print("{s}\n", .{p(lang, "Verifying checksum...", "チェックサムを検証中...")});
                const digest = sha256File(tarball_path) catch break :verify;
                const actual = toHex(digest);
                if (std.mem.eql(u8, expected, &actual)) {
                    std.debug.print("  {s}\n", .{p(lang, "SHA256 OK", "SHA256 検証 OK")});
                } else {
                    std.debug.print("  {s}\n", .{p(lang, "SHA256 MISMATCH — aborting!", "SHA256 不一致 — 中断します！")});
                    std.debug.print("  expected: {s}\n  actual:   {s}\n", .{ expected, &actual });
                    return error.ChecksumMismatch;
                }
            }
        }
    } else {
        std.debug.print("  {s}\n", .{p(lang, "SHA256SUMS not available; skipping verification.", "SHA256SUMS が利用不可。検証をスキップします。")});
    }

    // Extract
    const tag_dir = try std.fs.path.join(alloc, &[_][]const u8{ base_dir, tag });
    try compat.fs.cwd().makePath(tag_dir);

    std.debug.print("{s}\n", .{p(lang, "Extracting...", "展開中...")});
    try runOrFail(alloc, &[_][]const u8{ "tar", "xzf", tarball_path, "-C", tag_dir, "--strip-components=1" });

    // Ensure executable
    const bin_path = try std.fs.path.join(alloc, &[_][]const u8{ tag_dir, "tsunagi-node" });
    defer alloc.free(bin_path);
    runOrFail(alloc, &[_][]const u8{ "chmod", "+x", bin_path }) catch {};

    // Create/update symlink: current -> tag_dir
    const link_path = try std.fs.path.join(alloc, &[_][]const u8{ base_dir, "current" });
    defer alloc.free(link_path);
    runOrFail(alloc, &[_][]const u8{ "ln", "-sfn", tag_dir, link_path }) catch {};

    std.debug.print("  {s}: {s}\n", .{ p(lang, "Installed to", "インストール先"), tag_dir });
    std.debug.print("  {s}: {s}\n\n", .{ p(lang, "Symlink", "シンボリックリンク"), link_path });

    // Clean up tmp
    compat.fs.cwd().deleteFile(tarball_path) catch {};
    compat.fs.cwd().deleteFile(sums_path) catch {};

    return InstallResult{
        .tag = tag,
        .arch = arch,
        .install_dir = tag_dir,
    };
}

// ── Version management helpers ──────────────────────────────────────

pub fn getInstallBase(alloc: std.mem.Allocator) ![]u8 {
    const home = try compat.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(home);
    return try std.fs.path.join(alloc, &[_][]const u8{ home, ".local", "tsunagi" });
}

pub fn listInstalledTags(alloc: std.mem.Allocator) ![][]u8 {
    const base = try getInstallBase(alloc);
    defer alloc.free(base);

    var dir = compat.fs.openDirAbsolute(base, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return try alloc.alloc([]u8, 0);
        return err;
    };
    defer dir.close();

    var tags = std.array_list.Managed([]u8).init(alloc);

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const name = entry.name;
        // Must start with v<digit>
        if (name.len < 2 or name[0] != 'v') continue;
        if (name[1] < '0' or name[1] > '9') continue;
        try tags.append(try alloc.dupe(u8, name));
    }

    const slice = try tags.toOwnedSlice();
    // Sort descending (insertion sort — fine for small N)
    if (slice.len > 1) {
        var si: usize = 1;
        while (si < slice.len) : (si += 1) {
            var sj = si;
            while (sj > 0) {
                if (std.mem.order(u8, slice[sj], slice[sj - 1]) == .gt) {
                    const tmp = slice[sj];
                    slice[sj] = slice[sj - 1];
                    slice[sj - 1] = tmp;
                    sj -= 1;
                } else break;
            }
        }
    }
    return slice;
}

pub fn getCurrentTag(alloc: std.mem.Allocator) ?[]u8 {
    const base = getInstallBase(alloc) catch return null;
    defer alloc.free(base);

    var dir = compat.fs.openDirAbsolute(base, .{}) catch return null;
    defer dir.close();

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = dir.readLink("current", &link_buf) catch return null;
    const basename = std.fs.path.basename(target);
    return alloc.dupe(u8, basename) catch null;
}

pub fn setCurrentTag(alloc: std.mem.Allocator, tag: []const u8) !void {
    const base = try getInstallBase(alloc);
    defer alloc.free(base);

    const tag_dir = try std.fs.path.join(alloc, &[_][]const u8{ base, tag });
    defer alloc.free(tag_dir);

    const link_path = try std.fs.path.join(alloc, &[_][]const u8{ base, "current" });
    defer alloc.free(link_path);

    try runOrFail(alloc, &[_][]const u8{ "ln", "-sfn", tag_dir, link_path });
}
