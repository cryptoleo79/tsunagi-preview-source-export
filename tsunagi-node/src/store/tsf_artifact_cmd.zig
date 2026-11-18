const std = @import("std");
const compat = @import("compat");
const snapshot_cmd = @import("snapshot_cmd.zig");
const bootstrap_cmd = @import("bootstrap_cmd.zig");
const snapshot_sign = @import("snapshot_sign.zig");
const tsf = @import("tsf.zig");

// ---------------------------------------------------------------------------
// Gap bundle helpers (all non-fatal)
// ---------------------------------------------------------------------------

fn copyFileIfExists(alloc: std.mem.Allocator, src_path: []const u8, dst_path: []const u8) void {
    _ = alloc;
    if (std.fs.path.dirname(dst_path)) |dir| {
        compat.fs.cwd().makePath(dir) catch {};
    }
    var src = compat.fs.cwd().openFile(src_path, .{}) catch {
        std.debug.print("GAPS: skip {s} (missing)\n", .{src_path});
        return;
    };
    defer src.close();
    var dst = compat.fs.cwd().createFile(dst_path, .{ .truncate = true }) catch |e| {
        std.debug.print("GAPS: skip {s} (create: {s})\n", .{ dst_path, @errorName(e) });
        return;
    };
    defer dst.close();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = src.read(&buf) catch |e| {
            std.debug.print("GAPS: skip {s} (read: {s})\n", .{ src_path, @errorName(e) });
            return;
        };
        if (n == 0) break;
        dst.writeAll(buf[0..n]) catch |e| {
            std.debug.print("GAPS: skip {s} (write: {s})\n", .{ dst_path, @errorName(e) });
            return;
        };
    }
}

fn tailCopyFile(alloc: std.mem.Allocator, src_path: []const u8, dst_path: []const u8, max_lines: usize) void {
    if (std.fs.path.dirname(dst_path)) |dir| {
        compat.fs.cwd().makePath(dir) catch {};
    }
    const data = blk: {
        var f = compat.fs.cwd().openFile(src_path, .{}) catch {
            std.debug.print("GAPS: skip {s} (missing)\n", .{src_path});
            return;
        };
        defer f.close();
        break :blk f.readToEndAlloc(alloc, 2 * 1024 * 1024) catch {
            std.debug.print("GAPS: skip {s} (too large)\n", .{src_path});
            return;
        };
    };
    defer alloc.free(data);

    // Scan backwards for last max_lines newlines
    var tail_start: usize = 0;
    if (data.len > 0) {
        var nl_count: usize = 0;
        var i: usize = data.len;
        while (i > 0) {
            i -= 1;
            if (data[i] == '\n') {
                nl_count += 1;
                if (nl_count > max_lines) {
                    tail_start = i + 1;
                    break;
                }
            }
        }
    }

    var dst = compat.fs.cwd().createFile(dst_path, .{ .truncate = true }) catch |e| {
        std.debug.print("GAPS: skip {s} (create: {s})\n", .{ dst_path, @errorName(e) });
        return;
    };
    defer dst.close();
    dst.writeAll(data[tail_start..]) catch |e| {
        std.debug.print("GAPS: skip {s} (write: {s})\n", .{ dst_path, @errorName(e) });
    };
}

fn shellCapture(alloc: std.mem.Allocator, cmd: []const u8) ?[]u8 {
    const result = compat.childRun(.{
        .allocator = alloc,
        .argv = &[_][]const u8{ "/bin/sh", "-c", cmd },
        .max_output_bytes = 256 * 1024,
    }) catch return null;
    alloc.free(result.stderr);
    return result.stdout;
}

fn findMetricValue(raw: []const u8, key: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, key)) {
            const val = std.mem.trimStart(u8, line[key.len..], " ");
            const trimmed = std.mem.trimEnd(u8, val, " \r\t");
            if (trimmed.len > 0) return trimmed;
        }
    }
    return "n/a";
}

fn writeGapSummaryJson(alloc: std.mem.Allocator, out_path: []const u8) void {
    std.debug.print("\n== GAP SUMMARY ==\n", .{});

    if (std.fs.path.dirname(out_path)) |dir| {
        compat.fs.cwd().makePath(dir) catch {};
    }

    var f = compat.fs.cwd().createFile(out_path, .{ .truncate = true }) catch |err| {
        std.debug.print("GAPS: summary.json skipped (create: {s})\n", .{@errorName(err)});
        return;
    };
    defer f.close();
    const w = f.deprecatedWriter();

    const now: u64 = @intCast(compat.timestamp());

    // Git version
    const ver_raw = shellCapture(alloc, "cd ~/src/tsunagi-follower && git describe --tags --always 2>/dev/null");
    defer if (ver_raw) |v| alloc.free(v);
    const version: []const u8 = if (ver_raw) |v| blk: {
        const t = std.mem.trimEnd(u8, std.mem.trimStart(u8, v, " \t"), "\n\r \t");
        break :blk if (t.len > 0) t else "unknown";
    } else "unknown";

    // Fetch metrics from running node
    const metrics_raw = shellCapture(alloc, "curl -s --max-time 5 http://127.0.0.1:9080/metrics");
    defer if (metrics_raw) |m| alloc.free(m);
    const raw: []const u8 = metrics_raw orelse "";

    const m_truth = findMetricValue(raw, "tsunagi_lmdb_truth_ratio ");
    const m_mi_ema = findMetricValue(raw, "tsunagi_ledger_missing_inputs_ema ");
    const m_vc_ratio = findMetricValue(raw, "tsunagi_ledger_value_check_ratio ");
    const m_gap_keys = findMetricValue(raw, "tsunagi_gap_missing_keys ");
    const m_gap_repeat = findMetricValue(raw, "tsunagi_gap_repeat_ratio ");
    const m_hot_count = findMetricValue(raw, "tsunagi_gap_hot_top_count ");
    const m_hot_age = findMetricValue(raw, "tsunagi_gap_hot_top_age_seconds ");
    const m_bf_blocks = findMetricValue(raw, "tsunagi_backfill_blocks_total ");
    const m_bf_runs = findMetricValue(raw, "tsunagi_backfill_runs_total ");
    const m_bf_cursor = findMetricValue(raw, "tsunagi_backfill_cursor_offset ");
    const m_bf_seg = findMetricValue(raw, "tsunagi_backfill_segment_done_ratio ");
    // Gap trend (5m)
    const m_delta5 = findMetricValue(raw, "tsunagi_gap_keys_delta_5m ");
    const m_new5 = findMetricValue(raw, "tsunagi_gap_new_keys_5m ");
    const m_res5 = findMetricValue(raw, "tsunagi_gap_resolved_5m ");
    const m_evd5 = findMetricValue(raw, "tsunagi_gap_evictions_delta_5m ");
    const m_me5 = findMetricValue(raw, "tsunagi_gap_missing_events_5m ");
    const m_winr = findMetricValue(raw, "tsunagi_gap_win_rate ");
    const m_wunix = findMetricValue(raw, "tsunagi_gap_window_unix ");
    const m_wage = findMetricValue(raw, "tsunagi_gap_window_age_seconds ");

    // Write JSON
    w.print("{{\n", .{}) catch return;
    w.print("  \"unix\": {d},\n", .{now}) catch return;
    w.print("  \"version\": \"{s}\",\n", .{version}) catch return;
    w.print("  \"metrics\": {{\n", .{}) catch return;
    w.print("    \"lmdb_truth_ratio\": \"{s}\",\n", .{m_truth}) catch return;
    w.print("    \"ledger_missing_inputs_ema\": \"{s}\",\n", .{m_mi_ema}) catch return;
    w.print("    \"ledger_value_check_ratio\": \"{s}\",\n", .{m_vc_ratio}) catch return;
    w.print("    \"gap_missing_keys\": \"{s}\",\n", .{m_gap_keys}) catch return;
    w.print("    \"gap_repeat_ratio\": \"{s}\",\n", .{m_gap_repeat}) catch return;
    w.print("    \"gap_hot_top_count\": \"{s}\",\n", .{m_hot_count}) catch return;
    w.print("    \"gap_hot_top_age_seconds\": \"{s}\",\n", .{m_hot_age}) catch return;
    w.print("    \"backfill_blocks_total\": \"{s}\",\n", .{m_bf_blocks}) catch return;
    w.print("    \"backfill_runs_total\": \"{s}\",\n", .{m_bf_runs}) catch return;
    w.print("    \"backfill_cursor_offset\": \"{s}\",\n", .{m_bf_cursor}) catch return;
    w.print("    \"backfill_segment_done_ratio\": \"{s}\",\n", .{m_bf_seg}) catch return;
    w.print("    \"gap_keys_delta_5m\": \"{s}\",\n", .{m_delta5}) catch return;
    w.print("    \"gap_new_keys_5m\": \"{s}\",\n", .{m_new5}) catch return;
    w.print("    \"gap_resolved_5m\": \"{s}\",\n", .{m_res5}) catch return;
    w.print("    \"gap_evictions_delta_5m\": \"{s}\",\n", .{m_evd5}) catch return;
    w.print("    \"gap_missing_events_5m\": \"{s}\",\n", .{m_me5}) catch return;
    w.print("    \"gap_win_rate\": \"{s}\",\n", .{m_winr}) catch return;
    w.print("    \"gap_window_unix\": \"{s}\",\n", .{m_wunix}) catch return;
    w.print("    \"gap_window_age_seconds\": \"{s}\"\n", .{m_wage}) catch return;
    w.print("  }},\n", .{}) catch return;
    w.print("  \"note\": \"n/a means metric missing or metrics endpoint unavailable\"\n", .{}) catch return;
    w.print("}}\n", .{}) catch return;

    std.debug.print("GAPS: summary.json written\n", .{});
}

fn copyToCanonical(alloc: std.mem.Allocator, src_path: []const u8, canonical_dir: []const u8, filename: []const u8) void {
    const tmp_path = std.fmt.allocPrint(alloc, "{s}/{s}.tmp", .{ canonical_dir, filename }) catch return;
    defer alloc.free(tmp_path);
    const final_path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ canonical_dir, filename }) catch return;
    defer alloc.free(final_path);

    // Read source
    var src = compat.fs.cwd().openFile(src_path, .{}) catch return;
    defer src.close();
    var dst = compat.fs.cwd().createFile(tmp_path, .{ .truncate = true }) catch |e| {
        std.debug.print("GAPS: latest {s} update skipped (create: {s})\n", .{ filename, @errorName(e) });
        return;
    };
    defer dst.close();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = src.read(&buf) catch |e| {
            std.debug.print("GAPS: latest {s} update skipped (read: {s})\n", .{ filename, @errorName(e) });
            return;
        };
        if (n == 0) break;
        dst.writeAll(buf[0..n]) catch |e| {
            std.debug.print("GAPS: latest {s} update skipped (write: {s})\n", .{ filename, @errorName(e) });
            return;
        };
    }
    // Atomic rename
    compat.fs.cwd().rename(tmp_path, final_path) catch |e| {
        std.debug.print("GAPS: latest {s} update skipped (rename: {s})\n", .{ filename, @errorName(e) });
        return;
    };
}

fn updateCanonicalLatest(alloc: std.mem.Allocator, bundle_dir: []const u8) void {
    const home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch return;
    defer alloc.free(home);
    if (home.len == 0) return;

    const canonical_dir = std.fmt.allocPrint(alloc, "{s}/tsf/gaps", .{home}) catch return;
    defer alloc.free(canonical_dir);
    compat.fs.cwd().makePath(canonical_dir) catch |e| {
        std.debug.print("GAPS: latest update skipped (mkdir: {s})\n", .{@errorName(e)});
        return;
    };

    // Copy summary.json (required)
    const sum_src = std.fmt.allocPrint(alloc, "{s}/summary.json", .{bundle_dir}) catch return;
    defer alloc.free(sum_src);
    copyToCanonical(alloc, sum_src, canonical_dir, "summary.json");

    // Copy top_missing.json (optional)
    const top_src = std.fmt.allocPrint(alloc, "{s}/top_missing.json", .{bundle_dir}) catch return;
    defer alloc.free(top_src);
    copyToCanonical(alloc, top_src, canonical_dir, "top_missing.json");

    // Copy missing_inputs.keys (optional)
    const keys_src = std.fmt.allocPrint(alloc, "{s}/missing_inputs.keys", .{bundle_dir}) catch return;
    defer alloc.free(keys_src);
    copyToCanonical(alloc, keys_src, canonical_dir, "missing_inputs.keys");

    std.debug.print("GAPS: latest updated in {s}\n", .{canonical_dir});
}

fn exportGapBundle(alloc: std.mem.Allocator, out_path: []const u8) void {
    const home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch {
        std.debug.print("GAPS: export skipped (TSUNAGI_HOME not set)\n", .{});
        return;
    };
    defer alloc.free(home);

    const gap_dir = std.fmt.allocPrint(alloc, "{s}/gaps", .{home}) catch return;
    defer alloc.free(gap_dir);

    const out_dir = std.fs.path.dirname(out_path) orelse ".";
    const bundle_dir = std.fmt.allocPrint(alloc, "{s}/gaps", .{out_dir}) catch return;
    defer alloc.free(bundle_dir);

    compat.fs.cwd().makePath(bundle_dir) catch |e| {
        std.debug.print("GAPS: export skipped (mkdir: {s})\n", .{@errorName(e)});
        return;
    };

    // Copy files
    const src_keys = std.fmt.allocPrint(alloc, "{s}/missing_inputs.keys", .{gap_dir}) catch return;
    defer alloc.free(src_keys);
    const dst_keys = std.fmt.allocPrint(alloc, "{s}/missing_inputs.keys", .{bundle_dir}) catch return;
    defer alloc.free(dst_keys);
    copyFileIfExists(alloc, src_keys, dst_keys);

    const src_top = std.fmt.allocPrint(alloc, "{s}/top_missing.json", .{gap_dir}) catch return;
    defer alloc.free(src_top);
    const dst_top = std.fmt.allocPrint(alloc, "{s}/top_missing.json", .{bundle_dir}) catch return;
    defer alloc.free(dst_top);
    copyFileIfExists(alloc, src_top, dst_top);

    const src_fs = std.fmt.allocPrint(alloc, "{s}/missing_inputs.first_seen.json", .{gap_dir}) catch return;
    defer alloc.free(src_fs);
    const dst_fs = std.fmt.allocPrint(alloc, "{s}/first_seen.json", .{bundle_dir}) catch return;
    defer alloc.free(dst_fs);
    copyFileIfExists(alloc, src_fs, dst_fs);

    const src_log = std.fmt.allocPrint(alloc, "{s}/missing_inputs.log", .{gap_dir}) catch return;
    defer alloc.free(src_log);
    const dst_log = std.fmt.allocPrint(alloc, "{s}/missing_inputs.log", .{bundle_dir}) catch return;
    defer alloc.free(dst_log);
    tailCopyFile(alloc, src_log, dst_log, 200);

    // Write summary.json with live metrics snapshot
    const summary_path = std.fmt.allocPrint(alloc, "{s}/summary.json", .{bundle_dir}) catch return;
    defer alloc.free(summary_path);
    writeGapSummaryJson(alloc, summary_path);

    // Update canonical "latest" in TSUNAGI_HOME/tsf/gaps/
    updateCanonicalLatest(alloc, bundle_dir);

    std.debug.print("GAPS: exported to {s}\n", .{bundle_dir});
}

const TsfStats = struct {
    records: usize,
    digest: [32]u8,
    file_size: u64,
    anchor: tsf.Header,
};

fn readTsfStats(path: []const u8) !TsfStats {
    var f = try compat.fs.cwd().openFile(path, .{});
    defer f.close();

    const end_pos = try f.getEndPos();
    if (end_pos < @sizeOf(tsf.Header) + @sizeOf(tsf.Footer)) return error.InvalidSnapshot;

    // Read header for anchor metadata
    const anchor = try tsf.readHeader(f.deprecatedReader());

    // Read digest from footer
    try f.seekTo(end_pos - @sizeOf(tsf.Footer));
    const r = f.deprecatedReader();
    var digest: [32]u8 = undefined;
    try r.readNoEof(&digest);

    // Count records by scanning payload
    const hdr_size: u64 = @sizeOf(tsf.Header);
    const payload_end: u64 = end_pos - @sizeOf(tsf.Footer);
    try f.seekTo(hdr_size);

    var pos: u64 = hdr_size;
    var records: usize = 0;

    while (pos + 8 <= payload_end) {
        const key_len: u64 = @intCast(tsf.readU32le(r) catch break);
        pos += 4;
        if (pos + key_len > payload_end) break;
        pos += key_len;
        try f.seekTo(pos);

        const val_len: u64 = @intCast(tsf.readU32le(r) catch break);
        pos += 4;
        if (pos + val_len > payload_end) break;
        pos += val_len;
        try f.seekTo(pos);

        records += 1;
    }

    return TsfStats{
        .records = records,
        .digest = digest,
        .file_size = end_pos,
        .anchor = anchor,
    };
}

fn gzipFile(alloc: std.mem.Allocator, in_path: []const u8) !u64 {
    // Read input file
    const data = blk: {
        var inf = try compat.fs.cwd().openFile(in_path, .{});
        defer inf.close();
        break :blk try inf.readToEndAlloc(alloc, 2 * 1024 * 1024 * 1024);
    };
    defer alloc.free(data);

    const gz_path = try std.fmt.allocPrint(alloc, "{s}.gz", .{in_path});
    defer alloc.free(gz_path);

    var out_f = try compat.fs.cwd().createFile(gz_path, .{ .truncate = true });
    defer out_f.close();

    // Zig 0.15.2: use deprecatedWriter for gzip output
    
    const w = out_f.deprecatedWriter();

    // Gzip header (RFC 1952)
    try w.writeAll(&[_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03 });

    // DEFLATE store blocks (RFC 1951 sec 3.2.4). The flate Compress and
    // BlockWriter in zig 0.15.2 stdlib are WIP (missing bit_writer field,
    // @panic in drain) so we emit non-compressed store blocks directly.
    // Each block: 1-byte flags + 2-byte LEN + 2-byte NLEN + payload.
    const max_block: usize = 65535;
    var off: usize = 0;
    while (true) {
        const rem = data.len - off;
        const clen: u16 = @intCast(@min(rem, max_block));
        const final = (off + clen >= data.len);
        var hdr: [5]u8 = undefined;
        hdr[0] = if (final) 0x01 else 0x00;
        std.mem.writeInt(u16, hdr[1..3], clen, .little);
        std.mem.writeInt(u16, hdr[3..5], ~clen, .little);
        try w.writeAll(&hdr);
        if (clen > 0) try w.writeAll(data[off..][0..clen]);
        off += clen;
        if (final) break;
    }

    // Gzip footer: CRC-32 + ISIZE (RFC 1952)
    var footer: [8]u8 = undefined;
    std.mem.writeInt(u32, footer[0..4], std.hash.Crc32.hash(data), .little);
    std.mem.writeInt(u32, footer[4..8], @as(u32, @truncate(data.len)), .little);
    try w.writeAll(&footer);

    return try out_f.getEndPos();
}

pub fn run(
    alloc: std.mem.Allocator,
    lmdb_dir: []const u8,
    out_path: []const u8,
    test_dir: []const u8,
    do_gzip: bool,
    strict: bool,
    signing_key_opt: ?[]const u8,
) !void {
    // Ensure output directory exists
    if (std.fs.path.dirname(out_path)) |dir| {
        compat.fs.cwd().makePath(dir) catch {};
    }

    // Step 1 — Export
    std.debug.print("\n== TSF EXPORT ==\n", .{});
    try snapshot_cmd.exportSnapshot(alloc, out_path, lmdb_dir, signing_key_opt);
    const stats = try readTsfStats(out_path);
    std.debug.print("records={d}\ndigest={x}\n", .{ stats.records, &stats.digest });
    std.debug.print("anchor:\n", .{});
    snapshot_cmd.printAnchor(stats.anchor);

    // Step 2 — Import into test dir
    std.debug.print("\n== TSF IMPORT TEST ==\n", .{});
    compat.fs.cwd().deleteTree(test_dir) catch {};
    try compat.fs.cwd().makePath(test_dir);
    try snapshot_cmd.importSnapshot(alloc, out_path, test_dir, null, strict, null, null, true);
    std.debug.print("digest verified={x}\n", .{&stats.digest});

    // Step 3 — Bootstrap test
    std.debug.print("\n== BOOTSTRAP TEST ==\n", .{});
    compat.fs.cwd().deleteTree(test_dir) catch {};
    try bootstrap_cmd.run(alloc, out_path, test_dir);
    std.debug.print("BOOTSTRAP TEST OK\n", .{});

    // Step 4 — Optional gzip
    var gzip_size: u64 = 0;
    if (do_gzip) {
        std.debug.print("\n== TSF GZIP ==\n", .{});
        gzip_size = try gzipFile(alloc, out_path);
        std.debug.print("TSF GZIP size={d}\n", .{gzip_size});
    }

    // Step 5 — Gap bundle (non-fatal)
    std.debug.print("\n== GAP BUNDLE ==\n", .{});
    exportGapBundle(alloc, out_path);

    // Step 6 — Final report
    std.debug.print(
        \\
        \\== TSF ARTIFACT COMPLETE ==
        \\export_records={d}
        \\final_digest={s}
        \\file_size={d}
        \\
    , .{ stats.records, &stats.digest, stats.file_size });
    std.debug.print("anchor:\n", .{});
    snapshot_cmd.printAnchor(stats.anchor);
    if (do_gzip) {
        std.debug.print("gzip_size={d}\n", .{gzip_size});
    }
}
