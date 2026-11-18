const std = @import("std");
const compat = @import("compat");
const i18n = @import("i18n.zig");
const release_install = @import("release_install.zig");
const footprint_cmd = @import("footprint_cmd.zig");

// ── Bilingual labels ─────────────────────────────────────────────────

fn p(lang: i18n.Lang, en: []const u8, ja: []const u8) []const u8 {
    return if (lang == .ja) ja else en;
}

// ── Capture rotation ETA state (persists across menu runs) ──────────

var eta_last_capture_bytes: u64 = 0;
var eta_last_capture_unix: u64 = 0;
var eta_rate_bps: f64 = 0.0;

// ── Shell helpers ────────────────────────────────────────────────────

fn runShell(alloc: std.mem.Allocator, cmd: []const u8) void {
    var child = compat.Child.init(
        &[_][]const u8{ "/bin/sh", "-c", cmd },
        alloc,
    );
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    _ = child.spawnAndWait() catch |err| {
        std.debug.print("  command failed: {}\n", .{err});
    };
}

fn runShellCapture(alloc: std.mem.Allocator, cmd: []const u8) ?[]u8 {
    var child = compat.Child.init(
        &[_][]const u8{ "/bin/sh", "-c", cmd },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch return null;

    const stdout = child.stdout orelse return null;
    const output = stdout.readToEndAlloc(alloc, 256 * 1024) catch null;
    _ = child.wait() catch {};
    return output;
}

// ── Confirm prompt ───────────────────────────────────────────────────

fn confirm(lang: i18n.Lang) bool {
    // Persistent stdin reader: a per-call reader over-reads the typed line into a
    // throwaway buffer and loses every byte past the first of each kernel read
    // (including the '\n'), so the menu would stall. The shared persistent reader
    // retains over-read surplus across calls.
    const stdin = compat.fs.persistentStdin();
    std.debug.print("  {s} ", .{p(lang, "Are you sure? (y/N):", "実行しますか？(y/N):")});
    var buf: [16]u8 = undefined;
    const line = stdin.readUntilDelimiterOrEof(&buf, '\n') catch return false;
    const input = line orelse return false;
    const trimmed = std.mem.trimEnd(u8, input, "\r");
    return trimmed.len == 1 and (trimmed[0] == 'y' or trimmed[0] == 'Y');
}

// ── Read a line from stdin ───────────────────────────────────────────

fn readLine(buf: []u8) ?[]const u8 {
    // Shared persistent reader (see confirm()): preserves over-read surplus so
    // consecutive menu reads do not lose bytes across calls.
    const stdin = compat.fs.persistentStdin();
    const line = stdin.readUntilDelimiterOrEof(buf, '\n') catch return null;
    const input = line orelse return null;
    return std.mem.trimEnd(u8, std.mem.trimStart(u8, input, " \t"), " \t\r");
}

// ── Metrics line-value parser ────────────────────────────────────────

fn findMetricValue(raw: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, key)) {
            return line[key.len..];
        }
    }
    return null;
}

fn findIndexedMetricValue(raw: []const u8, prefix: []const u8, idx: usize) ?[]const u8 {
    // Match: prefix{index="<idx>"} <value>
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const idx_start = std.mem.indexOf(u8, line, "index=\"") orelse continue;
        const num_start = idx_start + 7;
        const num_end = std.mem.indexOfPos(u8, line, num_start, "\"") orelse continue;
        const line_idx = std.fmt.parseUnsigned(usize, line[num_start..num_end], 10) catch continue;
        if (line_idx != idx) continue;
        const brace = std.mem.indexOfPos(u8, line, num_end, "} ") orelse continue;
        return line[brace + 2 ..];
    }
    return null;
}

// ── Capture rotation ETA helpers ────────────────────────────────────

fn updateCaptureRate(capture_bytes: u64) void {
    const now: u64 = @intCast(@max(0, compat.timestamp()));
    if (eta_last_capture_bytes > 0 and eta_last_capture_unix > 0 and capture_bytes > eta_last_capture_bytes) {
        const dt = if (now > eta_last_capture_unix) now - eta_last_capture_unix else 0;
        if (dt >= 1) {
            const dt_f: f64 = @floatFromInt(dt);
            const delta: f64 = @floatFromInt(capture_bytes - eta_last_capture_bytes);
            const inst_rate = delta / dt_f;
            if (eta_rate_bps == 0.0) {
                eta_rate_bps = inst_rate;
            } else {
                eta_rate_bps = 0.8 * eta_rate_bps + 0.2 * inst_rate;
            }
        }
    }
    if (capture_bytes > 0) {
        eta_last_capture_bytes = capture_bytes;
        eta_last_capture_unix = now;
    }
}

fn formatEta(buf: []u8, capture_bytes: u64, rotate_bytes: u64, seg_count: u64) []const u8 {
    if (seg_count > 0) return "rotated";
    if (rotate_bytes == 0 or capture_bytes == 0) return "n/a";
    if (capture_bytes >= rotate_bytes) return "<1m";
    if (eta_rate_bps > 0.0) {
        const remaining: f64 = @floatFromInt(rotate_bytes - capture_bytes);
        const eta_f = remaining / eta_rate_bps;
        if (eta_f > 999.0 * 3600.0) return ">999h";
        const eta_secs: u64 = @intFromFloat(eta_f);
        if (eta_secs < 60) {
            return std.fmt.bufPrint(buf, "{d}s", .{eta_secs}) catch "n/a";
        } else if (eta_secs < 3600) {
            return std.fmt.bufPrint(buf, "{d}m", .{eta_secs / 60}) catch "n/a";
        } else {
            const hours = eta_secs / 3600;
            const mins = (eta_secs % 3600) / 60;
            return std.fmt.bufPrint(buf, "{d}h{d}m", .{ hours, mins }) catch "n/a";
        }
    }
    return "n/a";
}

// ── Gap summary.json reader ─────────────────────────────────────────

fn extractJsonStr(raw: []const u8, key: []const u8) []const u8 {
    const key_pos = std.mem.indexOf(u8, raw, key) orelse return "n/a";
    var i = key_pos + key.len;
    while (i < raw.len and (raw[i] == ':' or raw[i] == ' ')) : (i += 1) {}
    if (i >= raw.len or raw[i] != '"') return "n/a";
    i += 1;
    const val_start = i;
    const val_end = std.mem.indexOfPos(u8, raw, val_start, "\"") orelse return "n/a";
    return raw[val_start..val_end];
}

fn extractJsonU64(raw: []const u8, key: []const u8) u64 {
    const key_pos = std.mem.indexOf(u8, raw, key) orelse return 0;
    var i = key_pos + key.len;
    while (i < raw.len and (raw[i] == ':' or raw[i] == ' ')) : (i += 1) {}
    if (i >= raw.len) return 0;
    const num_start = i;
    while (i < raw.len and raw[i] >= '0' and raw[i] <= '9') : (i += 1) {}
    return std.fmt.parseUnsigned(u64, raw[num_start..i], 10) catch 0;
}

const GapSummary = struct {
    raw: []u8,
    version: []const u8,
    unix: u64,
    lmdb_truth_ratio: []const u8,
    ledger_missing_inputs_ema: []const u8,
    ledger_value_check_ratio: []const u8,
    gap_missing_keys: []const u8,
    gap_repeat_ratio: []const u8,
    gap_hot_top_count: []const u8,
    gap_hot_top_age_seconds: []const u8,
    backfill_blocks_total: []const u8,
    backfill_runs_total: []const u8,
    backfill_cursor_offset: []const u8,
    backfill_segment_done_ratio: []const u8,
};

fn readLatestGapSummary(alloc: std.mem.Allocator) ?GapSummary {
    // Try primary: TSUNAGI_HOME/tsf/gaps/summary.json
    const raw = blk: {
        const data = runShellCapture(alloc, "cat \"${TSUNAGI_HOME:-~/tsunagi-home-mainnet}/tsf/gaps/summary.json\" 2>/dev/null");
        if (data) |d| {
            if (d.len > 0 and d.len < 65536) break :blk d;
            alloc.free(d);
        }
        // Fallback: TSUNAGI_HOME/gaps/summary.json
        const fb = runShellCapture(alloc, "cat \"${TSUNAGI_HOME:-~/tsunagi-home-mainnet}/gaps/summary.json\" 2>/dev/null");
        if (fb) |d| {
            if (d.len > 0 and d.len < 65536) break :blk d;
            alloc.free(d);
        }
        return null;
    };

    return GapSummary{
        .raw = raw,
        .version = extractJsonStr(raw, "\"version\""),
        .unix = extractJsonU64(raw, "\"unix\""),
        .lmdb_truth_ratio = extractJsonStr(raw, "\"lmdb_truth_ratio\""),
        .ledger_missing_inputs_ema = extractJsonStr(raw, "\"ledger_missing_inputs_ema\""),
        .ledger_value_check_ratio = extractJsonStr(raw, "\"ledger_value_check_ratio\""),
        .gap_missing_keys = extractJsonStr(raw, "\"gap_missing_keys\""),
        .gap_repeat_ratio = extractJsonStr(raw, "\"gap_repeat_ratio\""),
        .gap_hot_top_count = extractJsonStr(raw, "\"gap_hot_top_count\""),
        .gap_hot_top_age_seconds = extractJsonStr(raw, "\"gap_hot_top_age_seconds\""),
        .backfill_blocks_total = extractJsonStr(raw, "\"backfill_blocks_total\""),
        .backfill_runs_total = extractJsonStr(raw, "\"backfill_runs_total\""),
        .backfill_cursor_offset = extractJsonStr(raw, "\"backfill_cursor_offset\""),
        .backfill_segment_done_ratio = extractJsonStr(raw, "\"backfill_segment_done_ratio\""),
    };
}

// ── Status banner ───────────────────────────────────────────────────

fn trimShell(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, std.mem.trimStart(u8, s, " \t"), "\n\r \t");
}

fn printBanner(alloc: std.mem.Allocator, lang: i18n.Lang) void {
    const w = compat.fs.stderrWriter();

    // ── Collect data (track original allocations for cleanup) ────

    const version_raw = runShellCapture(alloc, "cd ~/src/tsunagi-follower && git describe --tags --always 2>/dev/null");
    defer if (version_raw) |v| alloc.free(v);
    const version = if (version_raw) |v| blk: {
        const t = trimShell(v);
        break :blk if (t.len > 0) t else "unknown";
    } else "unknown";

    const svc_raw = runShellCapture(alloc, "systemctl --user is-active tsunagi-mainnet.service 2>/dev/null");
    defer if (svc_raw) |v| alloc.free(v);
    const svc_state = if (svc_raw) |v| blk: {
        const t = trimShell(v);
        break :blk if (t.len > 0) t else "unknown";
    } else "unknown";

    const rss_raw = runShellCapture(alloc, "ps -o rss= -p $(pgrep -n tsunagi-node 2>/dev/null) 2>/dev/null");
    defer if (rss_raw) |v| alloc.free(v);
    const rss_kb: u64 = if (rss_raw) |v| std.fmt.parseUnsigned(u64, trimShell(v), 10) catch 0 else 0;

    const metrics_raw = runShellCapture(alloc, "curl -s http://127.0.0.1:9080/metrics 2>/dev/null");
    defer if (metrics_raw) |v| alloc.free(v);
    const raw: []const u8 = metrics_raw orelse "";

    const v_slot = findMetricValue(raw, "tsunagi_slot ") orelse "n/a";
    const v_block = findMetricValue(raw, "tsunagi_block ") orelse "n/a";
    const v_utxo = findMetricValue(raw, "tsunagi_utxo_count ") orelse "n/a";
    const v_ratio = findMetricValue(raw, "tsunagi_lmdb_truth_ratio ") orelse "n/a";
    const v_decode_us = findMetricValue(raw, "tsunagi_perf_blockfetch_decode_us ") orelse "0";
    const v_tx_us = findMetricValue(raw, "tsunagi_perf_tx_extract_us ") orelse "0";
    const v_lmdb_us = findMetricValue(raw, "tsunagi_perf_lmdb_write_us ") orelse "0";
    const v_total_us = findMetricValue(raw, "tsunagi_perf_block_total_us ") orelse "0";
    const v_recon_us = findMetricValue(raw, "tsunagi_perf_reconnect_us ") orelse "0";
    const v_header_height = findMetricValue(raw, "tsunagi_header_height ") orelse "n/a";
    const v_cov_ratio = findMetricValue(raw, "tsunagi_ledger_value_check_ratio ") orelse "n/a";
    const v_missing_ema = findMetricValue(raw, "tsunagi_ledger_missing_inputs_ema ") orelse "n/a";
    const v_auto_strict_raw = findMetricValue(raw, "tsunagi_ledger_auto_strict_enabled ") orelse "0";
    const auto_strict_on = std.mem.eql(u8, v_auto_strict_raw, "1");

    // Body hash verification
    const v_bhash_ok = findMetricValue(raw, "tsunagi_block_body_hash_verified_total ") orelse "0";
    const v_bhash_last_ok_raw = findMetricValue(raw, "tsunagi_block_body_hash_last_ok_unix ") orelse "0";
    const bhash_last_ok_unix = std.fmt.parseUnsigned(u64, v_bhash_last_ok_raw, 10) catch 0;
    const now_unix: u64 = @intCast(@max(0, compat.timestamp()));
    var bhash_ago_buf: [32]u8 = undefined;
    const bhash_ago_str: []const u8 = if (bhash_last_ok_unix > 0 and now_unix >= bhash_last_ok_unix)
        std.fmt.bufPrint(&bhash_ago_buf, "{d}s", .{now_unix - bhash_last_ok_unix}) catch "n/a"
    else
        "n/a";

    const mode_raw = runShellCapture(alloc, "echo ${TSUNAGI_MODE:-accumulation}");
    defer if (mode_raw) |v| alloc.free(v);
    const mode = if (mode_raw) |v| blk: {
        const t = trimShell(v);
        break :blk if (t.len > 0) t else "accumulation";
    } else "accumulation";

    // Bayes top peer
    var best_idx: usize = 0;
    var best_sample: []const u8 = "n/a";
    var best_alpha: []const u8 = "n/a";
    var best_beta: []const u8 = "n/a";
    {
        var top_val: f64 = -1.0;
        for (0..5) |i| {
            if (findIndexedMetricValue(raw, "tsunagi_peer_score_sample{", i)) |sv| {
                const fv = std.fmt.parseFloat(f64, sv) catch continue;
                if (fv > top_val) {
                    top_val = fv;
                    best_idx = i;
                    best_sample = sv;
                }
            }
        }
        if (top_val >= 0.0) {
            best_alpha = findIndexedMetricValue(raw, "tsunagi_peer_alpha{", best_idx) orelse "n/a";
            best_beta = findIndexedMetricValue(raw, "tsunagi_peer_beta{", best_idx) orelse "n/a";
        }
    }

    // Capture size
    const cap_raw = runShellCapture(alloc, "stat -c%s \"${TSUNAGI_HOME:-$HOME/tsunagi-home-mainnet}\"/captures/*.bin 2>/dev/null | awk '{s+=$1}END{print s}'");
    defer if (cap_raw) |v| alloc.free(v);
    var cap_buf: [32]u8 = undefined;
    const capture_str: []const u8 = if (cap_raw) |v| blk: {
        const bytes = std.fmt.parseUnsigned(u64, trimShell(v), 10) catch break :blk "n/a";
        const mb = bytes / (1024 * 1024);
        break :blk std.fmt.bufPrint(&cap_buf, "{d}MB", .{mb}) catch "n/a";
    } else "n/a";

    // TSF latest
    const tsf_raw = runShellCapture(alloc, "ls -t \"${TSUNAGI_HOME:-$HOME/tsunagi-home-mainnet}\"/tsf/*.tsf.gz 2>/dev/null | head -1");
    defer if (tsf_raw) |v| alloc.free(v);
    const tsf_str: []const u8 = if (tsf_raw) |v| blk: {
        const t = trimShell(v);
        if (t.len == 0) break :blk "n/a";
        if (std.mem.lastIndexOfScalar(u8, t, '/')) |slash| break :blk t[slash + 1 ..];
        break :blk t;
    } else "n/a";

    // RSS display
    var rss_buf: [32]u8 = undefined;
    const rss_display: []const u8 = if (rss_kb > 0)
        std.fmt.bufPrint(&rss_buf, "{d}MB", .{rss_kb / 1024}) catch "n/a"
    else
        "n/a";

    // ── Render ──────────────────────────────────────────────────────

    w.print(
        \\
        \\  ╔══════════════════════════════════════╗
        \\  ║  {s: <37}║
        \\  ╚══════════════════════════════════════╝
        \\  {s: <20}{s}
        \\  {s: <20}{s}
        \\  {s: <20}LMDB {s} (truth_ratio={s})
        \\  {s: <20}{s}   {s: <8}{s}
        \\  {s: <20}{s}
        \\  Bayes Top: idx={d} sample={s} alpha={s} beta={s}
        \\  Perf: decode={s}us tx={s}us lmdb={s}us total={s}us reconnect={s}us
        \\
    , .{
        p(lang, "TSUNAGI STATUS", "TSUNAGI ステータス"),
        p(lang, "Version:", "バージョン:"),       version,
        p(lang, "Network:", "ネットワーク:"),       p(lang, "mainnet", "メインネット"),
        p(lang, "Mode:", "モード:"),             mode,       v_ratio,
        p(lang, "Slot:", "スロット:"),            v_slot,     p(lang, "Block:", "ブロック:"), v_block,
        p(lang, "UTxO(est):", "UTxO（推定）:"),    v_utxo,
        best_idx, best_sample, best_alpha, best_beta,
        v_decode_us, v_tx_us, v_lmdb_us, v_total_us, v_recon_us,
    }) catch {};
    // Mempool line from /mempool endpoint
    const mp_raw = runShellCapture(alloc, "curl -s http://127.0.0.1:9080/mempool 2>/dev/null");
    defer if (mp_raw) |v| alloc.free(v);
    var mp_items_buf: [32]u8 = undefined;
    var mp_bytes_buf: [32]u8 = undefined;
    var mp_items_str: []const u8 = "n/a";
    var mp_bytes_str: []const u8 = "";
    if (mp_raw) |mp_json| {
        // Parse {"items":N,"bytes":B,...}
        if (std.mem.indexOf(u8, mp_json, "\"items\":")) |items_start| {
            const num_start = items_start + 8;
            if (std.mem.indexOfAnyPos(u8, mp_json, num_start, ",}")) |num_end| {
                mp_items_str = std.fmt.bufPrint(&mp_items_buf, "{s}", .{mp_json[num_start..num_end]}) catch "n/a";
            }
        }
        if (std.mem.indexOf(u8, mp_json, "\"bytes\":")) |bytes_start| {
            const num_start = bytes_start + 8;
            if (std.mem.indexOfAnyPos(u8, mp_json, num_start, ",}")) |num_end| {
                mp_bytes_str = std.fmt.bufPrint(&mp_bytes_buf, " bytes={s}", .{mp_json[num_start..num_end]}) catch "";
            }
        }
    }

    w.print(
        \\  {s: <20}{s}
        \\  {s: <20}ok_total={s} last_ok={s}
        \\  {s} coverage={s} missing_ema={s} auto_strict={s}
        \\  {s: <20}items={s}{s}
        \\  {s: <20}{s}  TSF: {s}
        \\  {s: <20}{s}  RSS: {s}
        \\
    , .{
        p(lang, "Header height:", "ヘッダ高さ:"),    v_header_height,
        p(lang, "  BodyHash:", "  ボディハッシュ:"),  v_bhash_ok, bhash_ago_str,
        p(lang, "  Ledger:", "  台帳:"),           v_cov_ratio, v_missing_ema, if (auto_strict_on) "ON" else "OFF",
        p(lang, "Mempool:", "メンプール:"),          mp_items_str, mp_bytes_str,
        p(lang, "Capture:", "キャプチャ:"),         capture_str, tsf_str,
        p(lang, "Service:", "サービス:"),           svc_state,   rss_display,
    }) catch {};

    // ── Convergence ─────────────────────────────────────────────────
    const v_bf_runs = findMetricValue(raw, "tsunagi_backfill_runs_total ") orelse "0";
    const v_bf_blocks = findMetricValue(raw, "tsunagi_backfill_blocks_total ") orelse "0";
    const v_bf_last_unix_raw = findMetricValue(raw, "tsunagi_backfill_last_unix ") orelse "0";
    const v_bf_last_blocks = findMetricValue(raw, "tsunagi_backfill_last_blocks ") orelse "0";
    const v_bf_errors = findMetricValue(raw, "tsunagi_backfill_errors_total ") orelse "0";

    const bf_last_unix = std.fmt.parseUnsigned(u64, v_bf_last_unix_raw, 10) catch 0;
    var bf_ago_buf: [32]u8 = undefined;
    const bf_ago_str: []const u8 = if (bf_last_unix > 0 and now_unix >= bf_last_unix)
        std.fmt.bufPrint(&bf_ago_buf, "{d}s ago", .{now_unix - bf_last_unix}) catch "n/a"
    else
        "n/a";

    const v_bf_file_count = findMetricValue(raw, "tsunagi_backfill_file_count_last ") orelse "0";
    const v_bf_file_index = findMetricValue(raw, "tsunagi_backfill_file_index_last ") orelse "0";
    const v_bf_seg_done = findMetricValue(raw, "tsunagi_backfill_segment_done_ratio ") orelse "0";

    // Format seg display: "seg=I+1/N done=XX.X%"
    const bf_fc = std.fmt.parseUnsigned(u64, v_bf_file_count, 10) catch 0;
    const bf_fi = std.fmt.parseUnsigned(u64, v_bf_file_index, 10) catch 0;
    const bf_done_f = std.fmt.parseFloat(f64, v_bf_seg_done) catch 0.0;
    var seg_buf: [48]u8 = undefined;
    const seg_str: []const u8 = if (bf_fc > 0)
        std.fmt.bufPrint(&seg_buf, "seg={d}/{d} done={d:.1}%", .{ bf_fi + 1, bf_fc, bf_done_f * 100.0 }) catch "n/a"
    else
        "seg=n/a";

    // EOF idle
    const v_bf_eof_idle = findMetricValue(raw, "tsunagi_backfill_eof_idle_total ") orelse "0";
    var eof_idle_suffix_buf: [32]u8 = undefined;
    const eof_idle_str: []const u8 = blk: {
        const ei = std.fmt.parseUnsigned(u64, v_bf_eof_idle, 10) catch 0;
        if (ei > 0) {
            break :blk std.fmt.bufPrint(&eof_idle_suffix_buf, " eof_idle={d}", .{ei}) catch "";
        }
        break :blk "";
    };

    // Segment cleanup
    const v_bf_seg_deleted = findMetricValue(raw, "tsunagi_backfill_segments_deleted_total ") orelse "0";
    var seg_del_suffix_buf: [32]u8 = undefined;
    const seg_del_str: []const u8 = blk: {
        const sd = std.fmt.parseUnsigned(u64, v_bf_seg_deleted, 10) catch 0;
        if (sd > 0) {
            break :blk std.fmt.bufPrint(&seg_del_suffix_buf, " deleted={d}", .{sd}) catch "";
        }
        break :blk "";
    };

    // Capture observability
    const v_cap_main_raw = findMetricValue(raw, "tsunagi_capture_mainnet_bin_bytes ") orelse "0";
    const v_cap_seg_count = findMetricValue(raw, "tsunagi_capture_segments_count ") orelse "0";
    const v_cap_seg_bytes_raw = findMetricValue(raw, "tsunagi_capture_segments_bytes_total ") orelse "0";
    const v_cap_rot_mb = findMetricValue(raw, "tsunagi_capture_rotate_mb ") orelse "n/a";
    const v_cap_rot_bytes_raw = findMetricValue(raw, "tsunagi_capture_rotate_bytes ") orelse "0";
    const cap_main_bytes = std.fmt.parseUnsigned(u64, v_cap_main_raw, 10) catch 0;
    const cap_seg_bytes = std.fmt.parseUnsigned(u64, v_cap_seg_bytes_raw, 10) catch 0;
    const cap_rot_bytes_direct = std.fmt.parseUnsigned(u64, v_cap_rot_bytes_raw, 10) catch 0;
    const cap_rot_bytes = if (cap_rot_bytes_direct > 0) cap_rot_bytes_direct else blk: {
        const rot_mb = std.fmt.parseUnsigned(u64, v_cap_rot_mb, 10) catch 0;
        break :blk rot_mb * 1024 * 1024;
    };
    const cap_seg_count_u = std.fmt.parseUnsigned(u64, v_cap_seg_count, 10) catch 0;
    var cap_main_buf: [32]u8 = undefined;
    var cap_seg_buf: [32]u8 = undefined;
    const cap_main_mb: []const u8 = std.fmt.bufPrint(&cap_main_buf, "{d}MB", .{cap_main_bytes / (1024 * 1024)}) catch "n/a";
    const cap_seg_mb: []const u8 = std.fmt.bufPrint(&cap_seg_buf, "{d}MB", .{cap_seg_bytes / (1024 * 1024)}) catch "n/a";
    const cap_pre_rotation = cap_seg_count_u == 0 and cap_rot_bytes > 0 and cap_main_bytes < cap_rot_bytes;

    // Capture rotation ETA
    updateCaptureRate(cap_main_bytes);
    var eta_buf: [16]u8 = undefined;
    const eta_str = formatEta(&eta_buf, cap_main_bytes, cap_rot_bytes, cap_seg_count_u);

    // Truth line values
    const v_truth_total = findMetricValue(raw, "tsunagi_lmdb_truth_blocks_total ") orelse "0";
    const v_fallback_total = findMetricValue(raw, "tsunagi_lmdb_fallback_blocks_total ") orelse "0";

    const v_density_bl = findMetricValue(raw, "tsunagi_chain_density_baseline ") orelse "n/a";
    const v_density_rmin = findMetricValue(raw, "tsunagi_chain_density_recommended_min ") orelse "n/a";
    const v_density_avg3 = findMetricValue(raw, "tsunagi_chain_density_smoothed_last ") orelse "n/a";
    const v_density_streak = findMetricValue(raw, "tsunagi_chain_density_violation_streak_last ") orelse "0";

    const truth_f = std.fmt.parseFloat(f64, v_ratio) catch 0.0;
    const miss_u = std.fmt.parseUnsigned(u64, v_missing_ema, 10) catch 999;
    const convergence_label: []const u8 = if (truth_f >= 0.99 and auto_strict_on and miss_u == 0)
        p(lang, "READY", "完了")
    else if (truth_f > 0.0 or (std.fmt.parseUnsigned(u64, v_bf_runs, 10) catch 0) > 0)
        p(lang, "CONVERGING", "収束中")
    else
        p(lang, "INCOMPLETE", "未完了");

    // Convergence gate values
    const v_cg_ready = findMetricValue(raw, "tsunagi_convergence_ready ") orelse "0";
    const v_cg_stable = findMetricValue(raw, "tsunagi_convergence_ready_stable_seconds ") orelse "0";
    const v_cg_truth = findMetricValue(raw, "tsunagi_convergence_truth_ratio_last ") orelse "0";
    const v_cg_vc = findMetricValue(raw, "tsunagi_convergence_value_check_ratio_last ") orelse "0";
    const v_cg_ema = findMetricValue(raw, "tsunagi_convergence_missing_ema_last ") orelse "0";
    const cg_ready_label: []const u8 = if (std.mem.eql(u8, v_cg_ready, "1"))
        p(lang, "YES", "有効")
    else
        p(lang, "NO", "無効");

    w.print(
        \\  ── {s} ──────────────────────────────
        \\  {s: <20}seg={s} mainnet={s} rotated={s} rotate={s}MB eta={s}
        \\  {s: <20}runs={s} blocks={s} errors={s} {s}{s}{s}
        \\  {s: <20}{s} (+{s} blks)
        \\  {s: <20}ratio={s} truth={s} fallback={s}
        \\  {s: <20}missing_ema={s} value_check={s} auto_strict={s}
        \\
    , .{
        p(lang, "Convergence", "収束状況"),
        p(lang, "Capture:", "キャプチャ:"),      v_cap_seg_count, cap_main_mb, cap_seg_mb, v_cap_rot_mb, eta_str,
        p(lang, "Backfill:", "バックフィル:"),    v_bf_runs, v_bf_blocks, v_bf_errors, seg_str, eof_idle_str, seg_del_str,
        p(lang, "  Last run:", "  前回実行:"),    bf_ago_str, v_bf_last_blocks,
        p(lang, "Truth:", "真実:"),              v_ratio, v_truth_total, v_fallback_total,
        p(lang, "Ledger:", "台帳:"),             v_missing_ema, v_cov_ratio, if (auto_strict_on) "ON" else "OFF",
    }) catch {};
    if (cap_pre_rotation) {
        w.print("  {s}\n", .{
            p(lang, "Hint: seg=0 and mainnet < rotate threshold; backfill sees only 1 file until rotation triggers.", "ヒント: seg=0 かつ mainnetが閾値未満; backfillはローテーションまで1ファイルのみ検出します。"),
        }) catch {};
    }
    // Backfill recommendation
    const v_rec_code = findMetricValue(raw, "tsunagi_backfill_recommend_profile_code ") orelse "1";
    const v_rec_blocks = findMetricValue(raw, "tsunagi_backfill_recommend_blocks ") orelse "500";
    const v_rec_seconds = findMetricValue(raw, "tsunagi_backfill_recommend_seconds ") orelse "20";
    const v_rec_pressure = findMetricValue(raw, "tsunagi_backfill_recommend_pressure ") orelse "1";
    const rec_code_u = std.fmt.parseUnsigned(u64, v_rec_code, 10) catch 1;
    const rec_label: []const u8 = switch (rec_code_u) {
        0 => p(lang, "cautious", "慎重"),
        2 => p(lang, "aggressive", "積極"),
        else => p(lang, "normal", "通常"),
    };
    w.print(
        \\  {s: <20}rec={s} ({s}/{s}) pressure={s}
        \\
    , .{
        p(lang, "  Recommend:", "  推奨:"), rec_label, v_rec_blocks, v_rec_seconds, v_rec_pressure,
    }) catch {};
    // Integrity line values
    const v_hdr_stable_raw = findMetricValue(raw, "tsunagi_header_head_stable ") orelse "0";
    const hdr_stable_label: []const u8 = if (std.mem.eql(u8, v_hdr_stable_raw, "1")) "ON" else "OFF";
    const v_val_violation = findMetricValue(raw, "tsunagi_ledger_value_violation_total ") orelse "0";

    w.print(
        \\  {s: <20}avg3={s} base={s} rec_min={s} streak={s}
        \\  {s: <20}ready={s} stable={s}s truth={s} value={s} ema={s}
        \\  {s: <20}bodyhash_ok={s} header_stable={s} value_violation={s}
        \\  {s: <20}[ {s} ]
        \\
    , .{
        p(lang, "Density:", "密度:"),            v_density_avg3, v_density_bl, v_density_rmin, v_density_streak,
        p(lang, "Gate:", "ゲート:"),             cg_ready_label, v_cg_stable, v_cg_truth, v_cg_vc, v_cg_ema,
        p(lang, "Integrity:", "整合性:"),         v_bhash_ok, hdr_stable_label, v_val_violation,
        p(lang, "Status:", "状態:"),             convergence_label,
    }) catch {};

    // Operator hint
    {
        const hint_gap_keys_raw = findMetricValue(raw, "tsunagi_gap_missing_keys ") orelse "0";
        const hint_gap_cap_raw = findMetricValue(raw, "tsunagi_gap_keys_cap ") orelse "5000";
        const hint_gap_keys = std.fmt.parseUnsigned(u64, hint_gap_keys_raw, 10) catch 0;
        const hint_gap_cap = std.fmt.parseUnsigned(u64, hint_gap_cap_raw, 10) catch 5000;
        const hint_vc_f = std.fmt.parseFloat(f64, v_cg_vc) catch 0.0;

        const hint: []const u8 = if (cap_pre_rotation)
            "waiting for rotation \xe2\x80\x94 capture must reach rotate threshold to create segments for backfill."
        else if (hint_gap_keys >= hint_gap_cap and hint_gap_cap > 0)
            "gaps are capped \xe2\x80\x94 keep backfill + capture running to reduce missing keys."
        else if (truth_f < 0.10)
            "LMDB still converging \xe2\x80\x94 keep backfill running; truth ratio will rise as gaps resolve."
        else if (truth_f >= 0.80 and miss_u <= 1 and hint_vc_f >= 0.80)
            "convergence looks ready \xe2\x80\x94 watch Gate stable seconds; TSF artifact recommended."
        else
            "normal convergence \xe2\x80\x94 monitor truth_ratio and missing_ema.";

        w.print("  {s: <20}{s}\n", .{ "Hint2:", hint }) catch {};
    }

    // Consensus clock sanity
    const v_clock_drift = findMetricValue(raw, "tsunagi_consensus_wall_drift_last ") orelse "n/a";
    const v_clock_jump = findMetricValue(raw, "tsunagi_consensus_slot_jump_last ") orelse "n/a";
    const v_clock_viol = findMetricValue(raw, "tsunagi_consensus_clock_violation_total ") orelse "0";
    w.print(
        \\  {s: <20}drift_last={s}s slot_jump={s} violations={s}
        \\
    , .{
        p(lang, "Clock:", "クロック:"), v_clock_drift, v_clock_jump, v_clock_viol,
    }) catch {};

    // Consensus skeleton
    {
        const v_health = findMetricValue(raw, "tsunagi_consensus_health_score ") orelse "100";
        const v_stall = findMetricValue(raw, "tsunagi_peer_stall_active ") orelse "0";
        const v_reason = findMetricValue(raw, "tsunagi_consensus_stall_reason_code ") orelse "0";
        const v_age = findMetricValue(raw, "tsunagi_consensus_stall_age_seconds ") orelse "0";
        const v_bf_age = findMetricValue(raw, "tsunagi_consensus_blockfetch_age_seconds ") orelse "0";
        const v_ka_age = findMetricValue(raw, "tsunagi_consensus_keepalive_age_seconds ") orelse "0";
        w.print(
            \\  {s: <20}health={s} stall={s} reason={s} age={s}s bf_age={s}s ka_age={s}s
            \\
        , .{
            p(lang, "Consensus:", "コンセンサス:"), v_health, v_stall, v_reason, v_age, v_bf_age, v_ka_age,
        }) catch {};
    }

    // Authority confidence
    {
        const v_auth_conf = findMetricValue(raw, "tsunagi_authority_confidence ") orelse "1.000000";
        const v_auth_fin = findMetricValue(raw, "tsunagi_authority_finality_score ") orelse "0.000000";
        const v_auth_stable = findMetricValue(raw, "tsunagi_authority_stable_seconds ") orelse "0";
        const v_auth_reorg5m = findMetricValue(raw, "tsunagi_authority_reorg_events_5m ") orelse "0";
        const v_auth_dmax = findMetricValue(raw, "tsunagi_authority_reorg_depth_max_5m ") orelse "0";
        const v_auth_fdelta = findMetricValue(raw, "tsunagi_authority_fork_delta_5m ") orelse "0";
        const v_auth_gate_raw = findMetricValue(raw, "tsunagi_authority_gate_active ") orelse "0";
        const v_auth_gate: []const u8 = if (std.mem.eql(u8, v_auth_gate_raw, "1")) "ON" else "OFF";
        const v_auth_reason = findMetricValue(raw, "tsunagi_authority_reason_code_last ") orelse "0";
        w.print(
            \\  {s: <20}conf={s} fin={s} stable={s}s reorg5m={s} depth_max={s} fork_d5m={s} gate={s} reason={s}
            \\
        , .{
            p(lang, "Authority:", "オーソリティ:"), v_auth_conf, v_auth_fin, v_auth_stable, v_auth_reorg5m, v_auth_dmax, v_auth_fdelta, v_auth_gate, v_auth_reason,
        }) catch {};
    }

    // Block producer skeleton
    {
        const v_ps_raw = findMetricValue(raw, "tsunagi_producer_state ") orelse "1";
        const ps_u = std.fmt.parseUnsigned(u64, v_ps_raw, 10) catch 1;
        const ps_label: []const u8 = switch (ps_u) {
            0 => "DISABLED",
            2 => "CANDIDATE",
            3 => "LEADER",
            else => "TRACKING",
        };
        const v_ps_slot = findMetricValue(raw, "tsunagi_producer_last_slot_checked ") orelse "0";
        const v_ps_leader = findMetricValue(raw, "tsunagi_producer_last_leader_slot ") orelse "0";
        const v_ps_checks = findMetricValue(raw, "tsunagi_producer_leader_checks_total ") orelse "0";
        w.print(
            \\  {s: <20}state={s} last_check={s} leader_slot={s} checks={s}
            \\
        , .{
            p(lang, "Producer:", "プロデューサー:"), ps_label, v_ps_slot, v_ps_leader, v_ps_checks,
        }) catch {};
    }

    // Producer slot clock
    {
        const v_pc_obs = findMetricValue(raw, "tsunagi_producer_observed_slot ") orelse "0";
        const v_pc_est = findMetricValue(raw, "tsunagi_producer_estimated_slot ") orelse "0";
        const v_pc_drift = findMetricValue(raw, "tsunagi_producer_drift_last_slots ") orelse "0";
        const v_pc_abs = findMetricValue(raw, "tsunagi_producer_drift_abs_last ") orelse "0";
        const v_pc_max = findMetricValue(raw, "tsunagi_producer_drift_abs_max ") orelse "0";
        const v_pc_ev = findMetricValue(raw, "tsunagi_producer_drift_events_total ") orelse "0";
        const v_pc_ok = findMetricValue(raw, "tsunagi_producer_clock_ok ") orelse "0";
        // Format drift with sign prefix
        var drift_buf: [24]u8 = undefined;
        const drift_display: []const u8 = blk: {
            const drift_i = std.fmt.parseInt(i64, v_pc_drift, 10) catch 0;
            if (drift_i >= 0) {
                break :blk std.fmt.bufPrint(&drift_buf, "+{d}", .{drift_i}) catch v_pc_drift;
            }
            break :blk v_pc_drift; // already has '-'
        };
        w.print(
            \\  {s: <20}obs={s} est={s} drift={s} abs={s} max={s} events={s} ok={s}
            \\
        , .{
            p(lang, "ProducerClock:", "プロデューサー時計:"), v_pc_obs, v_pc_est, drift_display, v_pc_abs, v_pc_max, v_pc_ev, v_pc_ok,
        }) catch {};
    }

    // Genesis loader
    {
        const v_gen_unix = findMetricValue(raw, "tsunagi_producer_genesis_unix ") orelse "0";
        const v_gen_slot = findMetricValue(raw, "tsunagi_producer_slot_length_s ") orelse "0";
        const v_gen_ok = findMetricValue(raw, "tsunagi_producer_genesis_parse_ok ") orelse "0";
        const v_gen_err = findMetricValue(raw, "tsunagi_producer_genesis_last_error_code ") orelse "0";
        const is_ok = std.mem.eql(u8, v_gen_ok, "1");
        if (is_ok) {
            // Format unix as YYYY-MM-DD
            var date_buf: [11]u8 = undefined;
            const date_str: []const u8 = blk: {
                const unix_val = std.fmt.parseUnsigned(u64, v_gen_unix, 10) catch 0;
                if (unix_val == 0) break :blk "n/a";
                const days = unix_val / 86400;
                var y: u64 = 1970;
                var rem = days;
                while (true) {
                    const yd: u64 = if ((y % 4 == 0 and y % 100 != 0) or y % 400 == 0) 366 else 365;
                    if (rem < yd) break;
                    rem -= yd;
                    y += 1;
                }
                const leap = (y % 4 == 0 and y % 100 != 0) or y % 400 == 0;
                const mdays = [_]u64{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
                var mo: u64 = 0;
                while (mo < 12 and rem >= mdays[mo]) {
                    rem -= mdays[mo];
                    mo += 1;
                }
                break :blk std.fmt.bufPrint(&date_buf, "{d}-{d:0>2}-{d:0>2}", .{ y, mo + 1, rem + 1 }) catch "n/a";
            };
            w.print(
                \\  {s: <20}ok=1 start={s} slot_len={s}s
                \\
            , .{
                p(lang, "Genesis:", "ジェネシス:"), date_str, v_gen_slot,
            }) catch {};
        } else {
            w.print(
                \\  {s: <20}ok=0 err={s} (set TSUNAGI_GENESIS_PATH)
                \\
            , .{
                p(lang, "Genesis:", "ジェネシス:"), v_gen_err,
            }) catch {};
        }
    }

    // Producer keys
    {
        const v_pk_en = findMetricValue(raw, "tsunagi_producer_keys_enabled ") orelse "0";
        const v_pk_pool = findMetricValue(raw, "tsunagi_producer_pool_ok ") orelse "0";
        const v_pk_kes = findMetricValue(raw, "tsunagi_producer_kes_ok ") orelse "0";
        const v_pk_vrf = findMetricValue(raw, "tsunagi_producer_vrf_ok ") orelse "0";
        const v_pk_perms = findMetricValue(raw, "tsunagi_producer_keys_perms_ok ") orelse "0";
        const v_pk_read = findMetricValue(raw, "tsunagi_producer_keys_readable_ok ") orelse "0";
        const v_pk_err = findMetricValue(raw, "tsunagi_producer_keys_err_code_last ") orelse "0";
        const en_label: []const u8 = if (std.mem.eql(u8, v_pk_en, "1")) "ON" else "OFF";
        w.print(
            \\  {s: <20}enabled={s} pool={s} kes={s} vrf={s} perms={s} read={s} err={s}
            \\
        , .{
            p(lang, "ProducerKeys:", "プロデューサー鍵:"), en_label, v_pk_pool, v_pk_kes, v_pk_vrf, v_pk_perms, v_pk_read, v_pk_err,
        }) catch {};
    }

    // Leader check skeleton
    {
        const v_lc_epoch = findMetricValue(raw, "tsunagi_producer_epoch_last ") orelse "0";
        const v_lc_sie = findMetricValue(raw, "tsunagi_producer_slot_in_epoch_last ") orelse "0";
        const v_lc_prob = findMetricValue(raw, "tsunagi_producer_leader_probability_x1e6 ") orelse "0";
        const v_lc_rc = findMetricValue(raw, "tsunagi_producer_leader_reason_code_last ") orelse "0";
        const v_lc_exp = findMetricValue(raw, "tsunagi_producer_expected_leaders_per_epoch ") orelse "0";
        const v_lc_elig = findMetricValue(raw, "tsunagi_producer_leader_eligible_last ") orelse "0";
        const v_et_en = findMetricValue(raw, "tsunagi_producer_elig_test_enabled ") orelse "0";
        const v_et_slot = findMetricValue(raw, "tsunagi_producer_elig_test_slot_in_epoch ") orelse "0";
        const v_et_win = findMetricValue(raw, "tsunagi_producer_elig_test_window_s ") orelse "0";
        const v_et_end = findMetricValue(raw, "tsunagi_producer_elig_test_target_end_slot_in_epoch ") orelse "0";
        const v_et_ov_en = findMetricValue(raw, "tsunagi_producer_elig_test_override_enabled ") orelse "0";
        const v_et_ov_tgt = findMetricValue(raw, "tsunagi_producer_elig_test_override_target ") orelse "0";
        // Praos leader check (v1.0.1)
        const v_pr_u = findMetricValue(raw, "tsunagi_producer_praos_u_x1e12 ") orelse "0";
        const v_pr_t = findMetricValue(raw, "tsunagi_producer_praos_thresh_x1e12 ") orelse "0";
        const v_pr_leader = findMetricValue(raw, "tsunagi_producer_praos_leader_last ") orelse "0";
        const v_pr_rc = findMetricValue(raw, "tsunagi_producer_praos_reason_code_last ") orelse "0";
        const v_pr_checks = findMetricValue(raw, "tsunagi_producer_praos_checks_total ") orelse "0";
        // Format u and T as 0.NNNNNN (divide x1e12 display as x1e6)
        var u_buf: [16]u8 = undefined;
        const u_display: []const u8 = blk_u: {
            const uv = std.fmt.parseUnsigned(u64, v_pr_u, 10) catch 0;
            const uv6 = uv / 1_000_000; // x1e12 -> x1e6 for display
            break :blk_u std.fmt.bufPrint(&u_buf, "{d}.{d:0>6}", .{ uv6 / 1_000_000, uv6 % 1_000_000 }) catch v_pr_u;
        };
        var t_buf: [16]u8 = undefined;
        const t_display: []const u8 = blk_t: {
            const tv = std.fmt.parseUnsigned(u64, v_pr_t, 10) catch 0;
            const tv6 = tv / 1_000_000; // x1e12 -> x1e6 for display
            break :blk_t std.fmt.bufPrint(&t_buf, "{d}.{d:0>6}", .{ tv6 / 1_000_000, tv6 % 1_000_000 }) catch v_pr_t;
        };
        // Format prob as 0.NNNNNN
        var prob_buf: [16]u8 = undefined;
        const prob_display: []const u8 = blk: {
            const pv = std.fmt.parseUnsigned(u64, v_lc_prob, 10) catch 0;
            break :blk std.fmt.bufPrint(&prob_buf, "{d}.{d:0>6}", .{ pv / 1_000_000, pv % 1_000_000 }) catch v_lc_prob;
        };
        // Format slot as current/target..end when elig_test is ON
        if (std.mem.eql(u8, v_et_en, "1")) {
            // Compute ETA from slot values (same formula as /state producer_eta)
            const slots_per_epoch: u64 = 432000;
            const sie_val = std.fmt.parseUnsigned(u64, v_lc_sie, 10) catch 0;
            const target_val = std.fmt.parseUnsigned(u64, v_et_slot, 10) catch 0;
            var eta_remaining: u64 = 0;
            if (target_val != 0) {
                if (sie_val <= target_val) {
                    eta_remaining = target_val - sie_val;
                } else {
                    eta_remaining = (slots_per_epoch - sie_val) + target_val;
                }
            }
            var pl_eta_buf: [16]u8 = undefined;
            const eta_display: []const u8 = if (target_val == 0)
                ""
            else
                std.fmt.bufPrint(&pl_eta_buf, " ETA={d}h{d:0>2}m", .{ eta_remaining / 3600, (eta_remaining % 3600) / 60 }) catch "";
            // Override display
            var ov_buf: [24]u8 = undefined;
            const ov_display: []const u8 = if (std.mem.eql(u8, v_et_ov_en, "1"))
                std.fmt.bufPrint(&ov_buf, " override=ON tgt={s}", .{v_et_ov_tgt}) catch " override=ON"
            else
                " override=OFF";
            w.print(
                \\  {s: <20}epoch={s} window={s}s sie={s}/{s}..{s} elig={s} prob={s} exp={s} reason={s}{s}{s}
                \\
            , .{
                p(lang, "ProducerLeader:", "プロデューサーリーダー:"), v_lc_epoch, v_et_win, v_lc_sie, v_et_slot, v_et_end, v_lc_elig, prob_display, v_lc_exp, v_lc_rc, eta_display, ov_display,
            }) catch {};
        } else {
            w.print(
                \\  {s: <20}epoch={s} sie={s} eligible={s} prob={s} exp={s} reason={s}
                \\
            , .{
                p(lang, "ProducerLeader:", "プロデューサーリーダー:"), v_lc_epoch, v_lc_sie, v_lc_elig, prob_display, v_lc_exp, v_lc_rc,
            }) catch {};
        }
        // Praos line (always shown, v1.0.9 extended)
        const v_pr_en = findMetricValue(raw, "tsunagi_producer_praos_enabled ") orelse "0";
        const v_pr_lcs = findMetricValue(raw, "tsunagi_producer_praos_last_checked_slot ") orelse "0";
        const v_pr_ult = findMetricValue(raw, "tsunagi_praos_u_lt_t ") orelse "0";
        const v_pr_delta = findMetricValue(raw, "tsunagi_praos_delta_x1e12 ") orelse "0";
        const pr_en_label: []const u8 = if (std.mem.eql(u8, v_pr_en, "1")) "ON" else "OFF";
        const pr_elig_label: []const u8 = if (std.mem.eql(u8, v_pr_ult, "1")) "true" else "false";
        // Delta display (x1e12 -> 0.NNNNNN)
        var d_buf: [16]u8 = undefined;
        const delta_display: []const u8 = blk_d: {
            const dv = std.fmt.parseUnsigned(u64, v_pr_delta, 10) catch 0;
            const dv6 = dv / 1_000_000;
            break :blk_d std.fmt.bufPrint(&d_buf, "{d}.{d:0>6}", .{ dv6 / 1_000_000, dv6 % 1_000_000 }) catch v_pr_delta;
        };
        // Reason code label
        const pr_rc_val = std.fmt.parseUnsigned(u64, v_pr_rc, 10) catch 99;
        const pr_rc_label: []const u8 = switch (pr_rc_val) {
            0 => "ok_leader",
            1 => "vrf_disabled",
            2 => "vrf_not_ready",
            3 => "keys_not_ready",
            4 => "clock_bad",
            5 => "stake_zero",
            6 => "not_leader",
            else => "unknown",
        };
        w.print(
            \\  {s: <20}enabled={s} slot={s} praos={s} u={s} T={s} eligible={s} delta={s} reason={s}({s}) checks={s}
            \\
        , .{
            p(lang, "PraosCheck:", "プラオスチェック:"), pr_en_label, v_pr_lcs, v_pr_leader, u_display, t_display, pr_elig_label, delta_display, pr_rc_label, v_pr_rc, v_pr_checks,
        }) catch {};
    }

    // VRF interface
    {
        const v_vrf_en = findMetricValue(raw, "tsunagi_producer_vrf_enabled ") orelse "0";
        const v_vrf_ok = findMetricValue(raw, "tsunagi_producer_vrf_parse_ok ") orelse "0";
        const v_vrf_att = findMetricValue(raw, "tsunagi_producer_vrf_attempt_total ") orelse "0";
        const v_vrf_chk = findMetricValue(raw, "tsunagi_producer_vrf_checked_total ") orelse "0";
        const v_vrf_rc = findMetricValue(raw, "tsunagi_producer_vrf_reason_code_last ") orelse "0";
        const v_vrf_proof = findMetricValue(raw, "tsunagi_producer_vrf_proof_present ") orelse "0";
        const v_vrf_output = findMetricValue(raw, "tsunagi_producer_vrf_output_present ") orelse "0";
        const v_vrf_prefix = findMetricValue(raw, "tsunagi_producer_vrf_output_prefix_last ") orelse "0";
        const v_vrf_tm = findMetricValue(raw, "tsunagi_producer_vrf_tick_mode_code ") orelse "0";
        const v_vrf_lcs = findMetricValue(raw, "tsunagi_producer_vrf_last_checked_slot ") orelse "0";
        const v_vrf_ppfx = findMetricValue(raw, "tsunagi_producer_vrf_proof_prefix_last ") orelse "0";
        const en_label: []const u8 = if (std.mem.eql(u8, v_vrf_en, "1")) "ON" else "OFF";
        const mode_label: []const u8 = if (std.mem.eql(u8, v_vrf_tm, "2")) "ALWAYS" else if (std.mem.eql(u8, v_vrf_tm, "1")) "ELIG" else "OFF";
        w.print(
            \\  {s: <20}enabled={s} ok={s} attempt={s} checked={s} last_slot={s} mode={s} proof={s} out={s} pfx=0x{s} opfx=0x{s} reason={s}
            \\
        , .{
            p(lang, "VRF:", "VRF:"), en_label, v_vrf_ok, v_vrf_att, v_vrf_chk, v_vrf_lcs, mode_label, v_vrf_proof, v_vrf_output, v_vrf_ppfx, v_vrf_prefix, v_vrf_rc,
        }) catch {};
    }

    // KES interface
    {
        const v_kes_en = findMetricValue(raw, "tsunagi_producer_kes_enabled ") orelse "0";
        const v_kes_ok = findMetricValue(raw, "tsunagi_producer_kes_parse_ok ") orelse "0";
        const v_kes_att = findMetricValue(raw, "tsunagi_producer_kes_attempt_total ") orelse "0";
        const v_kes_sig = findMetricValue(raw, "tsunagi_producer_kes_signed_total ") orelse "0";
        const v_kes_sp = findMetricValue(raw, "tsunagi_producer_kes_sig_present_last ") orelse "0";
        const v_kes_rc = findMetricValue(raw, "tsunagi_producer_kes_reason_code_last ") orelse "0";
        const kes_en_label: []const u8 = if (std.mem.eql(u8, v_kes_en, "1")) "ON" else "OFF";
        w.print(
            \\  {s: <20}enabled={s} ok={s} attempts={s} signed={s} sig={s} reason={s}
            \\
        , .{
            p(lang, "KES:", "KES:"), kes_en_label, v_kes_ok, v_kes_att, v_kes_sig, v_kes_sp, v_kes_rc,
        }) catch {};
    }

    // Header candidate pipeline
    {
        const v_cand_built = findMetricValue(raw, "tsunagi_producer_candidate_built_total ") orelse "0";
        const v_cand_signed = findMetricValue(raw, "tsunagi_producer_candidate_signed_total ") orelse "0";
        const v_cand_slot = findMetricValue(raw, "tsunagi_producer_candidate_last_slot ") orelse "0";
        const v_cand_sig = findMetricValue(raw, "tsunagi_producer_candidate_sig_present_last ") orelse "0";
        const v_cand_pfx = findMetricValue(raw, "tsunagi_producer_candidate_sig_prefix_last ") orelse "0";
        const v_cand_rc = findMetricValue(raw, "tsunagi_producer_candidate_sign_reason_code_last ") orelse "0";
        const v_cand_hdr_len = findMetricValue(raw, "tsunagi_producer_candidate_hdr_bytes_len ") orelse "0";
        const v_body_len = findMetricValue(raw, "tsunagi_producer_body_cbor_len ") orelse "0";
        const v_body_w0 = findMetricValue(raw, "tsunagi_producer_body_hash_w0 ") orelse "0";
        w.print(
            \\  {s: <20}built={s} signed={s} sig={s} prefix=0x{s} reason={s} hdr_len={s} body_len={s} body=0x{s} last_slot={s}
            \\
        , .{
            p(lang, "Candidate:", "候補:"), v_cand_built, v_cand_signed, v_cand_sig, v_cand_pfx, v_cand_rc, v_cand_hdr_len, v_body_len, v_body_w0, v_cand_slot,
        }) catch {};
    }

    // Pure Zig Ed25519 signing
    {
        const v_zs_att = findMetricValue(raw, "tsunagi_producer_zig_sig_attempt_total ") orelse "0";
        const v_zs_ok = findMetricValue(raw, "tsunagi_producer_zig_sig_ok_total ") orelse "0";
        const v_zs_pres = findMetricValue(raw, "tsunagi_producer_zig_sig_present_last ") orelse "0";
        const v_zs_pfx = findMetricValue(raw, "tsunagi_producer_zig_sig_prefix_last ") orelse "0";
        const v_zs_rc = findMetricValue(raw, "tsunagi_producer_zig_sig_reason_last ") orelse "0";
        w.print(
            \\  {s: <20}attempts={s} ok={s} sig={s} prefix=0x{s} reason={s}
            \\
        , .{
            p(lang, "ZigSig:", "Zig署名:"), v_zs_att, v_zs_ok, v_zs_pres, v_zs_pfx, v_zs_rc,
        }) catch {};
    }

    // KES sign pipeline
    {
        const v_ks_att = findMetricValue(raw, "tsunagi_producer_kes_sign_attempt_total ") orelse "0";
        const v_ks_ok = findMetricValue(raw, "tsunagi_producer_kes_sign_ok_total ") orelse "0";
        const v_ks_pres = findMetricValue(raw, "tsunagi_producer_kes_sign_present_last ") orelse "0";
        const v_ks_pfx = findMetricValue(raw, "tsunagi_producer_kes_sign_prefix_last ") orelse "0";
        const v_ks_rc = findMetricValue(raw, "tsunagi_producer_kes_sign_reason_last ") orelse "0";
        const v_ks_label = findMetricValue(raw, "tsunagi_producer_kes_sign_label_last ") orelse "0";
        const ks_en_label: []const u8 = if (!std.mem.eql(u8, v_ks_att, "0")) "ON" else "OFF";
        const ks_label_str: []const u8 = if (std.mem.eql(u8, v_ks_label, "1")) "ED25519" else "n/a";
        w.print(
            \\  {s: <20}enabled={s} attempts={s} ok={s} sig={s} prefix=0x{s} reason={s} label={s}
            \\
        , .{
            p(lang, "KESign:", "KES署名:"), ks_en_label, v_ks_att, v_ks_ok, v_ks_pres, v_ks_pfx, v_ks_rc, ks_label_str,
        }) catch {};
    }

    // KES period gate (v1.0.2, enhanced v1.1.2)
    {
        const v_kp_cur = findMetricValue(raw, "tsunagi_producer_kes_current_period ") orelse "0";
        const v_kp_start = findMetricValue(raw, "tsunagi_producer_kes_start_period ") orelse "0";
        const v_kp_max = findMetricValue(raw, "tsunagi_producer_kes_max_periods ") orelse "62";
        const v_kp_valid = findMetricValue(raw, "tsunagi_producer_kes_period_valid_last ") orelse "0";
        const v_kp_rc = findMetricValue(raw, "tsunagi_producer_kes_period_reason_code_last ") orelse "0";
        const v_kp_rollovers = findMetricValue(raw, "tsunagi_kes_rollovers_total ") orelse "0";
        const v_kp_refused = findMetricValue(raw, "tsunagi_kes_sign_refused_total ") orelse "0";
        w.print(
            \\  {s: <20}period={s} start={s} max={s} valid={s} reason={s} rollovers={s} refused={s}
            \\
        , .{
            p(lang, "KESPeriod:", "KES期間:"), v_kp_cur, v_kp_start, v_kp_max, v_kp_valid, v_kp_rc, v_kp_rollovers, v_kp_refused,
        }) catch {};
    }

    // Producer proof pack (v2)
    {
        const v_pk_total = findMetricValue(raw, "tsunagi_producer_pack_total ") orelse "0";
        const v_pk_unix = findMetricValue(raw, "tsunagi_producer_pack_last_unix ") orelse "0";
        const pk_unix_val = std.fmt.parseUnsigned(u64, v_pk_unix, 10) catch 0;
        var pk_ago_buf: [16]u8 = undefined;
        const pk_ago_str: []const u8 = if (pk_unix_val > 0 and now_unix >= pk_unix_val) blk: {
            const age = now_unix - pk_unix_val;
            if (age >= 3600) break :blk std.fmt.bufPrint(&pk_ago_buf, "{d}h", .{age / 3600}) catch "n/a"
            else if (age >= 60) break :blk std.fmt.bufPrint(&pk_ago_buf, "{d}m", .{age / 60}) catch "n/a"
            else break :blk std.fmt.bufPrint(&pk_ago_buf, "{d}s", .{age}) catch "n/a";
        } else "n/a";
        w.print(
            \\  {s: <20}total={s} last={s} ago
            \\
        , .{
            p(lang, "ProducerPack:", "パック:"), v_pk_total, pk_ago_str,
        }) catch {};
    }

    // Slot scheduler (v1.1.0)
    {
        const v_sc_epoch = findMetricValue(raw, "tsunagi_producer_schedule_epoch_last ") orelse "0";
        const v_sc_leaders = findMetricValue(raw, "tsunagi_producer_schedule_leaders_in_window ") orelse "0";
        const v_sc_next = findMetricValue(raw, "tsunagi_producer_schedule_next_leader_offset ") orelse "0";
        const v_sc_u0 = findMetricValue(raw, "tsunagi_producer_schedule_u0_x1e12 ") orelse "0";
        const v_sc_t0 = findMetricValue(raw, "tsunagi_producer_schedule_t_x1e12 ") orelse "0";
        const v_sc_rc = findMetricValue(raw, "tsunagi_producer_schedule_reason_code_last ") orelse "0";
        const v_sc_update_us = findMetricValue(raw, "tsunagi_producer_schedule_last_update_us ") orelse "0";

        // Format u0 and T as 0.NNNNNN (6 decimal digits)
        const su0_val = std.fmt.parseUnsigned(u64, v_sc_u0, 10) catch 0;
        const st0_val = std.fmt.parseUnsigned(u64, v_sc_t0, 10) catch 0;
        var su0_buf: [16]u8 = undefined;
        var st0_buf: [16]u8 = undefined;
        const su0_str = std.fmt.bufPrint(&su0_buf, "{d}.{d:0>6}", .{ su0_val / 1_000_000_000_000, (su0_val % 1_000_000_000_000) / 1_000_000 }) catch "n/a";
        const st0_str = std.fmt.bufPrint(&st0_buf, "{d}.{d:0>6}", .{ st0_val / 1_000_000_000_000, (st0_val % 1_000_000_000_000) / 1_000_000 }) catch "n/a";

        // Format next offset
        const next_val = std.fmt.parseUnsigned(u64, v_sc_next, 10) catch 999999;
        var next_buf: [16]u8 = undefined;
        const next_str: []const u8 = if (next_val >= 999999) "n/a" else std.fmt.bufPrint(&next_buf, "+{d}", .{next_val}) catch "n/a";

        // Age (from last_update_us — microseconds)
        const sc_update_us_val = std.fmt.parseUnsigned(u64, v_sc_update_us, 10) catch 0;
        const sc_update_unix = sc_update_us_val / 1_000_000;
        var sc_ago_buf: [16]u8 = undefined;
        const sc_ago_str: []const u8 = if (sc_update_unix > 0 and now_unix >= sc_update_unix) blk: {
            const age = now_unix - sc_update_unix;
            if (age >= 3600) break :blk std.fmt.bufPrint(&sc_ago_buf, "{d}h", .{age / 3600}) catch "n/a"
            else if (age >= 60) break :blk std.fmt.bufPrint(&sc_ago_buf, "{d}m", .{age / 60}) catch "n/a"
            else break :blk std.fmt.bufPrint(&sc_ago_buf, "{d}s", .{age}) catch "n/a";
        } else "n/a";

        w.print(
            \\  {s: <20}epoch={s} leaders={s}/128 next={s} u0={s} T={s} reason={s} age={s}
            \\
        , .{
            p(lang, "ProducerSched:", "スケジュール:"), v_sc_epoch, v_sc_leaders, next_str, su0_str, st0_str, v_sc_rc, sc_ago_str,
        }) catch {};
    }

    // Producer Timing (hardening)
    {
        const v_vrf_us = findMetricValue(raw, "tsunagi_producer_vrf_compute_us_total ") orelse "0";
        const v_sched_us = findMetricValue(raw, "tsunagi_producer_schedule_compute_us_total ") orelse "0";
        const v_tick_us = findMetricValue(raw, "tsunagi_producer_tick_us_total ") orelse "0";
        const v_tick_max = findMetricValue(raw, "tsunagi_producer_tick_us_max ") orelse "0";
        w.print(
            \\  {s: <20}vrf_us={s} sched_us={s} tick_us={s} tick_max={s}
            \\
        , .{
            p(lang, "ProducerTiming:", "タイミング:"), v_vrf_us, v_sched_us, v_tick_us, v_tick_max,
        }) catch {};
    }

    // Header validation
    {
        const v_hv_total = findMetricValue(raw, "tsunagi_header_validate_total ") orelse "0";
        const v_hv_fail = findMetricValue(raw, "tsunagi_header_validate_fail_total ") orelse "0";
        const v_hv_ratio = findMetricValue(raw, "tsunagi_header_validate_fail_ratio ") orelse "0";
        const v_hv_hash = findMetricValue(raw, "tsunagi_header_hash_mismatch_total ") orelse "0";
        const v_hv_prev = findMetricValue(raw, "tsunagi_header_prevhash_mismatch_total ") orelse "0";
        const strict_label: []const u8 = if (compat.hasEnvVar(std.heap.page_allocator, "TSUNAGI_HEADER_STRICT")) "ON" else "OFF";
        w.print(
            \\  {s: <20}total={s} fail={s} ratio={s} hash_mis={s} prev_mis={s} strict={s}
            \\
        , .{
            p(lang, "HeaderValidate:", "ヘッダ検証:"), v_hv_total, v_hv_fail, v_hv_ratio, v_hv_hash, v_hv_prev, strict_label,
        }) catch {};
    }

    // Ledger anomaly bands
    const v_anom_fee = findMetricValue(raw, "tsunagi_ledger_fee_est_lovelace_last ") orelse "n/a";
    const v_anom_dust = findMetricValue(raw, "tsunagi_ledger_dust_ratio_last ") orelse "n/a";
    const v_anom_maxout = findMetricValue(raw, "tsunagi_ledger_max_out_lovelace_last ") orelse "n/a";
    const v_anom_total = findMetricValue(raw, "tsunagi_ledger_anomaly_total ") orelse "0";
    w.print(
        \\  {s: <20}fee={s} dust={s} max_out={s} anomalies={s}
        \\
    , .{
        p(lang, "Ledger Anom:", "台帳異常:"), v_anom_fee, v_anom_dust, v_anom_maxout, v_anom_total,
    }) catch {};

    // TxSubmission session
    {
        const v_ts_state_raw = findMetricValue(raw, "tsunagi_txsub_state_code ") orelse "0";
        const ts_state_label: []const u8 = if (std.mem.eql(u8, v_ts_state_raw, "2")) "DONE" else if (std.mem.eql(u8, v_ts_state_raw, "1")) "ACTIVE" else "IDLE";
        const v_ts_first_id = findMetricValue(raw, "tsunagi_txsub_session_first_msg_id_last ") orelse "0";
        const ts_first_id_label: []const u8 = if (std.mem.eql(u8, v_ts_first_id, "0")) "n/a" else v_ts_first_id;
        const v_ts_age = findMetricValue(raw, "tsunagi_txsub_session_age_seconds_last ") orelse "n/a";
        const v_ts_rx_msgs = findMetricValue(raw, "tsunagi_txsub_session_rx_msgs_last ") orelse "0";
        const v_ts_rx_bytes_raw = findMetricValue(raw, "tsunagi_txsub_session_rx_bytes_last ") orelse "0";
        // Convert bytes to KB
        var ts_kb_buf: [16]u8 = undefined;
        const ts_rx_kb: []const u8 = blk: {
            const bytes_u = std.fmt.parseUnsigned(u64, v_ts_rx_bytes_raw, 10) catch 0;
            const kb = bytes_u / 1024;
            break :blk std.fmt.bufPrint(&ts_kb_buf, "{d}", .{kb}) catch "0";
        };
        // State machine + shape
        const v_ts_ignored = findMetricValue(raw, "tsunagi_txsub_ignored_total ") orelse "0";
        const v_ts_bad_shape = findMetricValue(raw, "tsunagi_txsub_invalid_shape_total ") orelse "0";
        // Census ids
        const v_c0 = findMetricValue(raw, "tsunagi_txsub_msg_id_0_total ") orelse "0";
        const v_c1 = findMetricValue(raw, "tsunagi_txsub_msg_id_1_total ") orelse "0";
        const v_c3 = findMetricValue(raw, "tsunagi_txsub_msg_id_3_total ") orelse "0";
        const v_c5 = findMetricValue(raw, "tsunagi_txsub_msg_id_5_total ") orelse "0";
        const v_c6 = findMetricValue(raw, "tsunagi_txsub_msg_id_6_total ") orelse "0";
        const v_cu = findMetricValue(raw, "tsunagi_txsub_msg_id_unknown_total ") orelse "0";
        w.print(
            \\  {s: <20}state={s} first_id={s} age={s}s rx={s}/{s}KB ids(0/1/3/5/6/unk)={s}/{s}/{s}/{s}/{s}/{s} ignored={s} bad_shape={s}
            \\
        , .{
            p(lang, "TxSub:", "TxSub:"), ts_state_label, ts_first_id_label, v_ts_age, v_ts_rx_msgs, ts_rx_kb,
            v_c0, v_c1, v_c3, v_c5, v_c6, v_cu, v_ts_ignored, v_ts_bad_shape,
        }) catch {};
    }

    // TxSub broadcast bridge
    {
        const v_bc_attempt = findMetricValue(raw, "tsunagi_txsub_broadcast_attempt_total ") orelse "0";
        const v_bc_sent = findMetricValue(raw, "tsunagi_txsub_broadcast_sent_total ") orelse "0";
        const v_bc_blocked = findMetricValue(raw, "tsunagi_txsub_broadcast_blocked_total ") orelse "0";
        const bc_enabled: []const u8 = if (compat.hasEnvVar(std.heap.page_allocator, "TSUNAGI_TXSUB_BROADCAST")) "ON" else "OFF";
        w.print(
            \\  {s: <20}enabled={s} attempt={s} sent={s} blocked={s}
            \\
        , .{
            p(lang, "TxBroadcast:", "TxBroadcast:"), bc_enabled, v_bc_attempt, v_bc_sent, v_bc_blocked,
        }) catch {};
    }

    // BAEY audit log + policy tick
    {
        const v_by_total = findMetricValue(raw, "tsunagi_baey_events_total ") orelse "0";
        const pt_raw = runShellCapture(alloc, "grep policy_tick \"${TSUNAGI_HOME:-~/tsunagi-home-mainnet}/baey/events.log\" 2>/dev/null | tail -n 1");
        defer if (pt_raw) |pr| alloc.free(pr);
        const pt_line: []const u8 = if (pt_raw) |pr| trimShell(pr) else "";
        if (pt_line.len > 10) {
            const pt_score = extractJsonStr(pt_line, "\"score\"");
            const pt_action = extractJsonStr(pt_line, "\"action\"");
            const pt_unix = extractJsonU64(pt_line, "\"unix\"");
            const pt_age = if (pt_unix > 0 and now_unix >= pt_unix) now_unix - pt_unix else 0;
            var pt_age_buf: [16]u8 = undefined;
            const pt_age_str = std.fmt.bufPrint(&pt_age_buf, "{d}s", .{pt_age}) catch "n/a";
            const pt_auth_conf = extractJsonStr(pt_line, "\"auth_conf\"");
            const pt_auth_fin = extractJsonStr(pt_line, "\"auth_fin\"");
            const pt_auth_reorg = extractJsonStr(pt_line, "\"auth_reorg5m\"");
            const pt_auth_forks = extractJsonStr(pt_line, "\"auth_forks\"");
            w.print(
                \\  {s: <20}events={s} score={s} action={s} age={s} auth_conf={s} auth_fin={s} reorg5m={s} forks={s}
                \\
            , .{
                p(lang, "BAEY:", "BAEY:"), v_by_total, pt_score, pt_action, pt_age_str, pt_auth_conf, pt_auth_fin, pt_auth_reorg, pt_auth_forks,
            }) catch {};
            // Leader guard v2 sub-line
            const pt_lg_raw = extractJsonStr(pt_line, "\"leader_guard\"");
            const pt_lg_label: []const u8 = if (std.mem.eql(u8, pt_lg_raw, "1")) "ON" else "OFF";
            const pt_prob = extractJsonStr(pt_line, "\"producer_prob_x1e6\"");
            const pt_exp = extractJsonStr(pt_line, "\"producer_expected_epoch\"");
            const pt_lg_reason = extractJsonStr(pt_line, "\"lg_reason\"");
            const pt_prod_reason = extractJsonStr(pt_line, "\"producer_reason_code\"");
            const pt_stake = extractJsonStr(pt_line, "\"producer_stake_x1e9\"");
            var prob_fmt_buf: [16]u8 = undefined;
            const prob_fmt: []const u8 = blk: {
                const pv = std.fmt.parseUnsigned(u64, pt_prob, 10) catch 0;
                break :blk std.fmt.bufPrint(&prob_fmt_buf, "{d}.{d:0>6}", .{ pv / 1_000_000, pv % 1_000_000 }) catch "n/a";
            };
            w.print(
                \\  {s: <20}leader_guard={s} lg_reason={s} prob={s} exp_epoch={s} stake={s} prod_reason={s}
                \\
            , .{
                @as([]const u8, ""), pt_lg_label, pt_lg_reason, prob_fmt, pt_exp, pt_stake, pt_prod_reason,
            }) catch {};
        } else {
            w.print(
                \\  {s: <20}events={s} policy n/a
                \\
            , .{
                p(lang, "BAEY:", "BAEY:"), v_by_total,
            }) catch {};
            w.print(
                \\  {s: <20}leader_guard=n/a lg_reason=n/a prob=n/a exp_epoch=n/a stake=n/a prod_reason=n/a
                \\
            , .{@as([]const u8, "")}) catch {};
        }

        // Adaptive weights line
        const v_ws = findMetricValue(raw, "tsunagi_baey_weight_stall ") orelse "n/a";
        const v_wd = findMetricValue(raw, "tsunagi_baey_weight_density ") orelse "n/a";
        const v_wh = findMetricValue(raw, "tsunagi_baey_weight_header ") orelse "n/a";
        const v_wk = findMetricValue(raw, "tsunagi_baey_weight_keepalive ") orelse "n/a";
        const v_wg = findMetricValue(raw, "tsunagi_baey_weight_gap ") orelse "n/a";
        const v_wa = findMetricValue(raw, "tsunagi_baey_weight_authority ") orelse "n/a";
        const v_wf = findMetricValue(raw, "tsunagi_baey_weight_finality ") orelse "n/a";
        w.print(
            \\  {s: <20}stall={s} density={s} header={s} keepalive={s} gap={s} authority={s} finality={s}
            \\
        , .{
            p(lang, "Weights:", "重み:"), v_ws, v_wd, v_wh, v_wk, v_wg, v_wa, v_wf,
        }) catch {};
    }

    // Gap hunter v4
    const v_gap_keys = findMetricValue(raw, "tsunagi_gap_missing_keys ") orelse "0";
    const v_gap_cap = findMetricValue(raw, "tsunagi_gap_keys_cap ") orelse "5000";
    const v_gap_repeat = findMetricValue(raw, "tsunagi_gap_repeat_ratio ") orelse "0";
    const v_gap_delta_raw = findMetricValue(raw, "tsunagi_gap_keys_delta_5m ") orelse "n/a";
    const v_gap_ev5 = findMetricValue(raw, "tsunagi_gap_evictions_delta_5m ") orelse "n/a";
    const v_gap_hot5 = findMetricValue(raw, "tsunagi_gap_hot_changes_5m ") orelse "n/a";
    const v_gap_oldest = findMetricValue(raw, "tsunagi_gap_oldest_last_seen_age_seconds ") orelse "0";
    const v_gap_capped = findMetricValue(raw, "tsunagi_gap_capped ") orelse "0";
    const v_gap_ls_items = findMetricValue(raw, "tsunagi_gap_last_seen_items ") orelse "0";
    // Format delta with + prefix for non-negative
    var gap_delta_buf: [16]u8 = undefined;
    const gap_delta_str: []const u8 = blk: {
        if (std.mem.eql(u8, v_gap_delta_raw, "n/a")) break :blk "n/a";
        if (v_gap_delta_raw.len > 0 and v_gap_delta_raw[0] == '-') break :blk v_gap_delta_raw;
        break :blk std.fmt.bufPrint(&gap_delta_buf, "+{s}", .{v_gap_delta_raw}) catch v_gap_delta_raw;
    };
    w.print(
        \\  {s: <20}keys={s}/{s} d5m={s} ev5m={s} hot5m={s} oldest={s}s capped={s} repeat={s} ls={s}
        \\
    , .{
        p(lang, "Gaps:", "ギャップ:"), v_gap_keys, v_gap_cap, gap_delta_str, v_gap_ev5, v_gap_hot5, v_gap_oldest, v_gap_capped, v_gap_repeat, v_gap_ls_items,
    }) catch {};

    // BackfillGap steering
    const v_bgk = findMetricValue(raw, "tsunagi_backfill_gap_keys_loaded_last ") orelse "n/a";
    const v_bgs = findMetricValue(raw, "tsunagi_backfill_gap_consumed_seen_last ") orelse "n/a";
    const v_bgz = findMetricValue(raw, "tsunagi_backfill_gap_consumed_resolved_last ") orelse "n/a";
    const v_bgp = findMetricValue(raw, "tsunagi_backfill_produced_total_last ") orelse "n/a";
    const v_bgh = findMetricValue(raw, "tsunagi_backfill_gap_hit_last ") orelse "n/a";
    const v_bgr = findMetricValue(raw, "tsunagi_backfill_gap_hit_ratio ") orelse "n/a";
    w.print(
        \\  {s: <20}keys_loaded={s} seen={s} resolved={s} produced={s} hits={s} ratio={s}
        \\
    , .{
        p(lang, "BackfillGap:", "BFギャップ:"), v_bgk, v_bgs, v_bgz, v_bgp, v_bgh, v_bgr,
    }) catch {};

    // BackfillAutotune
    const v_at_en = findMetricValue(raw, "tsunagi_backfill_autotune_enabled ") orelse "0";
    if (std.mem.eql(u8, v_at_en, "1")) {
        const v_at_prof = findMetricValue(raw, "tsunagi_backfill_autotune_profile_current ") orelse "0";
        const v_at_reason = findMetricValue(raw, "tsunagi_backfill_autotune_reason_code_last ") orelse "0";
        const v_at_sw = findMetricValue(raw, "tsunagi_backfill_autotune_switch_total ") orelse "0";
        const prof_u = std.fmt.parseUnsigned(u64, v_at_prof, 10) catch 0;
        const prof_label: []const u8 = switch (prof_u) {
            0 => "cautious",
            1 => "normal",
            2 => "aggressive",
            else => "unknown",
        };
        const reason_u = std.fmt.parseUnsigned(u64, v_at_reason, 10) catch 0;
        const reason_label: []const u8 = switch (reason_u) {
            0 => "none",
            1 => "gap_pressure",
            2 => "missing_ema",
            3 => "low_truth",
            4 => "perf_safety",
            5 => "winning",
            6 => "mixed",
            7 => "losing",
            else => "unknown",
        };
        w.print(
            \\  {s: <20}ON profile={s} reason={s} switched={s}
            \\
        , .{
            p(lang, "BFAutotune:", "BF自動調整:"), prof_label, reason_label, v_at_sw,
        }) catch {};
    } else {
        w.print(
            \\  {s: <20}OFF
            \\
        , .{
            p(lang, "BFAutotune:", "BF自動調整:"),
        }) catch {};
    }

    // State digest (full 32-byte / 64-char hex)
    {
        const v_sd_hi = findMetricValue(raw, "tsunagi_state_digest_hi ") orelse "0";
        const v_sd_lo = findMetricValue(raw, "tsunagi_state_digest_lo ") orelse "0";
        const v_sd_w2 = findMetricValue(raw, "tsunagi_state_digest_w2 ") orelse "0";
        const v_sd_w3 = findMetricValue(raw, "tsunagi_state_digest_w3 ") orelse "0";
        const v_sd_unix = findMetricValue(raw, "tsunagi_state_digest_unix ") orelse "0";
        // Build first 8 hex chars from w0 (hi)
        var sd_hex_buf: [16]u8 = undefined;
        const sd_hex: []const u8 = blk: {
            const hi_val = std.fmt.parseUnsigned(u64, v_sd_hi, 10) catch 0;
            if (hi_val == 0) {
                const lo_val = std.fmt.parseUnsigned(u64, v_sd_lo, 10) catch 0;
                const w2_val = std.fmt.parseUnsigned(u64, v_sd_w2, 10) catch 0;
                const w3_val = std.fmt.parseUnsigned(u64, v_sd_w3, 10) catch 0;
                if (lo_val == 0 and w2_val == 0 and w3_val == 0) break :blk "n/a";
            }
            var hi_bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &hi_bytes, std.fmt.parseUnsigned(u64, v_sd_hi, 10) catch 0, .big);
            const hex_chars = "0123456789abcdef";
            for (0..4) |bi| {
                sd_hex_buf[bi * 2] = hex_chars[hi_bytes[bi] >> 4];
                sd_hex_buf[bi * 2 + 1] = hex_chars[hi_bytes[bi] & 0xf];
            }
            break :blk sd_hex_buf[0..8];
        };
        // Compute age
        var sd_age_buf: [16]u8 = undefined;
        const sd_age_str: []const u8 = blk: {
            const sd_unix_val = std.fmt.parseUnsigned(u64, v_sd_unix, 10) catch 0;
            if (sd_unix_val == 0) break :blk "n/a";
            const age = if (now_unix > sd_unix_val) now_unix - sd_unix_val else 0;
            break :blk std.fmt.bufPrint(&sd_age_buf, "{d}s", .{age}) catch "n/a";
        };
        w.print(
            \\  {s: <20}hex={s}... age={s}
            \\
        , .{
            p(lang, "StateDigest:", "状態ダイジェスト:"), sd_hex, sd_age_str,
        }) catch {};
    }

    // Memory proof
    {
        const v_rss = findMetricValue(raw, "tsunagi_rss_kb ") orelse "0";
        const v_lmdb_map = findMetricValue(raw, "tsunagi_lmdb_map_size_bytes ") orelse "0";
        const v_ac = findMetricValue(raw, "tsunagi_alloc_current_bytes ") orelse "0";
        const v_ap = findMetricValue(raw, "tsunagi_alloc_peak_bytes ") orelse "0";
        const v_an = findMetricValue(raw, "tsunagi_alloc_net_bytes ") orelse "0";
        const v_alu = findMetricValue(raw, "tsunagi_alloc_peak_last_unix ") orelse "0";
        // Format as MB
        var rss_mb_buf: [16]u8 = undefined;
        const rss_mb = blk: {
            const kb = std.fmt.parseUnsigned(u64, v_rss, 10) catch 0;
            break :blk std.fmt.bufPrint(&rss_mb_buf, "{d}", .{kb / 1024}) catch "0";
        };
        var lmdb_gb_buf: [16]u8 = undefined;
        const lmdb_gb = blk: {
            const b = std.fmt.parseUnsigned(u64, v_lmdb_map, 10) catch 0;
            break :blk std.fmt.bufPrint(&lmdb_gb_buf, "{d}", .{b / (1024 * 1024 * 1024)}) catch "0";
        };
        var ac_mb_buf: [16]u8 = undefined;
        const ac_mb = blk: {
            const b = std.fmt.parseUnsigned(u64, v_ac, 10) catch 0;
            break :blk std.fmt.bufPrint(&ac_mb_buf, "{d}", .{b / (1024 * 1024)}) catch "0";
        };
        var ap_mb_buf: [16]u8 = undefined;
        const ap_mb = blk: {
            const b = std.fmt.parseUnsigned(u64, v_ap, 10) catch 0;
            break :blk std.fmt.bufPrint(&ap_mb_buf, "{d}", .{b / (1024 * 1024)}) catch "0";
        };
        var an_mb_buf: [16]u8 = undefined;
        const an_mb = blk: {
            const b = std.fmt.parseUnsigned(u64, v_an, 10) catch 0;
            break :blk std.fmt.bufPrint(&an_mb_buf, "{d}", .{b / (1024 * 1024)}) catch "0";
        };
        var peak_age_buf: [16]u8 = undefined;
        const peak_age = blk: {
            const lu = std.fmt.parseUnsigned(u64, v_alu, 10) catch 0;
            if (lu == 0) break :blk "n/a";
            const age = if (now_unix > lu) now_unix - lu else 0;
            break :blk std.fmt.bufPrint(&peak_age_buf, "{d}s", .{age}) catch "n/a";
        };
        w.print(
            \\  {s: <20}rss={s}MB lmdb_map={s}GB alloc_cur={s}MB alloc_peak={s}MB net={s}MB peak_changed={s}
            \\
        , .{
            p(lang, "MemoryProof:", "メモリ証明:"), rss_mb, lmdb_gb, ac_mb, ap_mb, an_mb, peak_age,
        }) catch {};
    }

    // Memory attribution
    {
        const v_gaps = findMetricValue(raw, "tsunagi_mem_gaps_total_bytes_est ") orelse "0";
        const v_mp = findMetricValue(raw, "tsunagi_mem_mempool_bytes_est ") orelse "0";
        const v_cap = findMetricValue(raw, "tsunagi_mem_capture_bytes_est ") orelse "0";
        const v_lmap = findMetricValue(raw, "tsunagi_mem_lmdb_map_bytes ") orelse "0";

        var gaps_buf: [16]u8 = undefined;
        const gaps_str = blk: {
            const b = std.fmt.parseUnsigned(u64, v_gaps, 10) catch 0;
            if (b == 0) break :blk "n/a";
            const mb10 = b / 104858; // b * 10 / 1048576, avoid overflow
            if (mb10 >= 10) {
                break :blk std.fmt.bufPrint(&gaps_buf, "{d}.{d}M", .{ mb10 / 10, mb10 % 10 }) catch "n/a";
            }
            // Show as KB
            break :blk std.fmt.bufPrint(&gaps_buf, "{d}K", .{ b / 1024 }) catch "n/a";
        };
        var mp_buf: [16]u8 = undefined;
        const mp_str = blk: {
            const b = std.fmt.parseUnsigned(u64, v_mp, 10) catch 0;
            if (b == 0) break :blk "n/a";
            break :blk std.fmt.bufPrint(&mp_buf, "{d}K", .{ b / 1024 }) catch "n/a";
        };
        var ma_cap_buf: [16]u8 = undefined;
        const cap_str = blk: {
            const b = std.fmt.parseUnsigned(u64, v_cap, 10) catch 0;
            if (b == 0) break :blk "n/a";
            const mb10 = b / 104858;
            if (mb10 >= 10) {
                break :blk std.fmt.bufPrint(&ma_cap_buf, "{d}.{d}M", .{ mb10 / 10, mb10 % 10 }) catch "n/a";
            }
            break :blk std.fmt.bufPrint(&ma_cap_buf, "{d}K", .{ b / 1024 }) catch "n/a";
        };
        var lmap_buf: [16]u8 = undefined;
        const lmap_str = blk: {
            const b = std.fmt.parseUnsigned(u64, v_lmap, 10) catch 0;
            if (b == 0) break :blk "n/a";
            const gb10 = b / 107374183; // b * 10 / 1073741824
            break :blk std.fmt.bufPrint(&lmap_buf, "{d}.{d}G", .{ gb10 / 10, gb10 % 10 }) catch "n/a";
        };
        w.print(
            \\  {s: <20}gaps={s} mempool={s} capture={s} lmdb_map={s}
            \\
        , .{
            p(lang, "MemoryAttribution:", "メモリ帰属:"), gaps_str, mp_str, cap_str, lmap_str,
        }) catch {};
    }

    // FastSync controller
    {
        const v_en = findMetricValue(raw, "tsunagi_fastsync_enabled ") orelse "0";
        const v_sc = findMetricValue(raw, "tsunagi_fastsync_state_code ") orelse "0";
        const v_lu = findMetricValue(raw, "tsunagi_fastsync_last_unix ") orelse "0";
        const v_la = findMetricValue(raw, "tsunagi_fastsync_last_action_code ") orelse "0";
        const state_code = std.fmt.parseUnsigned(u64, v_sc, 10) catch 0;
        const state_name: []const u8 = switch (state_code) {
            0 => "OFF",
            1 => "WARMUP",
            2 => "PUSHING",
            3 => "READY",
            else => "?",
        };
        var fs_age_buf: [16]u8 = undefined;
        const fs_age = blk: {
            const lu = std.fmt.parseUnsigned(u64, v_lu, 10) catch 0;
            if (lu == 0) break :blk "n/a";
            const age = if (now_unix > lu) now_unix - lu else 0;
            break :blk std.fmt.bufPrint(&fs_age_buf, "{d}s", .{age}) catch "n/a";
        };
        w.print(
            \\  {s: <20}{s} last={s} action={s}
            \\
        , .{
            p(lang, "FastSync:", "FastSync:"), state_name, fs_age, v_la,
        }) catch {};
        _ = v_en;

        // FastSync ETA line
        const v_eta = findMetricValue(raw, "tsunagi_fastsync_eta_minutes ") orelse "0";
        const v_erc = findMetricValue(raw, "tsunagi_fastsync_eta_reason_code ") orelse "0";
        const v_td = findMetricValue(raw, "tsunagi_convergence_truth_delta_5m ") orelse "0.000000";
        const v_vd = findMetricValue(raw, "tsunagi_convergence_value_delta_5m ") orelse "0.000000";
        const v_ed = findMetricValue(raw, "tsunagi_convergence_missing_ema_delta_5m ") orelse "0.000";
        const eta_val = std.fmt.parseUnsigned(u64, v_eta, 10) catch 0;
        const erc_val = std.fmt.parseUnsigned(u64, v_erc, 10) catch 0;
        var fs_eta_buf: [16]u8 = undefined;
        const fs_eta_str: []const u8 = if (erc_val == 0) "0m" else if (eta_val == 0) "n/a" else
            std.fmt.bufPrint(&fs_eta_buf, "{d}m", .{eta_val}) catch "n/a";
        w.print(
            \\  {s: <20}eta={s} truth_d5m={s} value_d5m={s} ema_d5m={s}
            \\
        , .{
            p(lang, "FastSyncETA:", "FastSync予測:"), fs_eta_str, v_td, v_vd, v_ed,
        }) catch {};
    }

    // Gap Summary (from summary.json)
    const gap_sum = readLatestGapSummary(alloc);
    defer if (gap_sum) |gs| alloc.free(gs.raw);

    if (gap_sum) |gs| {
        const gs_age = if (now_unix > gs.unix) now_unix - gs.unix else 0;
        var gs_age_buf: [32]u8 = undefined;
        const gs_age_str = std.fmt.bufPrint(&gs_age_buf, "{d}", .{gs_age}) catch "n/a";

        w.print(
            \\  {s}
            \\    version={s} age={s}s
            \\    truth={s} missing_ema={s} value={s}
            \\    gaps={s} repeat={s} hot_age={s}s
            \\    backfill runs={s} blocks={s} done={s}
            \\
        , .{
            p(lang, "Summary.json:", "Summary.json:"),
            gs.version, gs_age_str,
            gs.lmdb_truth_ratio, gs.ledger_missing_inputs_ema, gs.ledger_value_check_ratio,
            gs.gap_missing_keys, gs.gap_repeat_ratio, gs.gap_hot_top_age_seconds,
            gs.backfill_runs_total, gs.backfill_blocks_total, gs.backfill_segment_done_ratio,
        }) catch {};
    } else {
        w.print("  {s}\n", .{
            p(lang, "Summary.json: n/a", "Summary.json: n/a"),
        }) catch {};
    }
}

// ── Menu actions ─────────────────────────────────────────────────────

fn actionStatus(alloc: std.mem.Allocator, lang: i18n.Lang) void {
    printBanner(alloc, lang);
    std.debug.print("\n--- {s} ---\n\n", .{p(lang, "Service Detail", "サービス詳細")});
    runShell(alloc, "systemctl --user status tsunagi-mainnet.service --no-pager 2>&1 || true");
    std.debug.print("\n", .{});
}

fn actionTailLogs(alloc: std.mem.Allocator, lang: i18n.Lang) void {
    std.debug.print("\n--- {s} ---\n\n", .{p(lang, "Recent Logs (80 lines)", "最近のログ（80行）")});
    runShell(alloc, "journalctl --user -u tsunagi-mainnet.service -n 80 --no-pager -o cat 2>&1 || true");
    std.debug.print("\n", .{});
}

fn actionRestart(alloc: std.mem.Allocator, lang: i18n.Lang) void {
    std.debug.print("\n  {s}\n", .{p(lang, "Restart tsunagi-mainnet.service?", "tsunagi-mainnet.service を再起動しますか？")});
    if (!confirm(lang)) {
        std.debug.print("  {s}\n\n", .{p(lang, "Cancelled.", "キャンセルしました。")});
        return;
    }
    runShell(alloc, "systemctl --user restart tsunagi-mainnet.service");
    std.debug.print("  {s}\n\n", .{p(lang, "Restart issued.", "再起動を実行しました。")});
}

fn actionMetrics(alloc: std.mem.Allocator, lang: i18n.Lang) void {
    std.debug.print("\n--- {s} ---\n\n", .{p(lang, "Metrics Snapshot", "メトリクススナップショット")});

    const raw = runShellCapture(alloc, "curl -s http://127.0.0.1:9080/metrics 2>/dev/null") orelse {
        std.debug.print("  {s}\n\n", .{p(lang, "Could not reach metrics endpoint.", "メトリクスエンドポイントに接続できません。")});
        return;
    };
    defer alloc.free(raw);

    if (raw.len == 0) {
        std.debug.print("  {s}\n\n", .{p(lang, "Empty response (is the node running with TSUNAGI_METRICS=1?).", "空のレスポンス（TSUNAGI_METRICS=1 でノードが動作中ですか？）")});
        return;
    }

    // Parse key metrics
    const keys = [_][]const u8{
        "tsunagi_slot ",
        "tsunagi_block ",
        "tsunagi_utxo_count ",
        "tsunagi_lmdb_truth_ratio ",
        "tsunagi_cbor_toolarge_total ",
        "tsunagi_cbor_endofstream_total ",
        "tsunagi_cbor_other_total ",
        "tsunagi_ledger_value_check_ratio ",
        "tsunagi_ledger_missing_inputs_ema ",
        "tsunagi_ledger_auto_strict_enabled ",
    };
    const labels_en = [_][]const u8{
        "Slot",
        "Block",
        "UTxO count",
        "LMDB truth ratio",
        "CBOR too-large",
        "CBOR end-of-stream",
        "CBOR other errors",
        "Ledger coverage ratio",
        "Ledger missing inputs EMA",
        "Ledger auto-strict",
    };
    const labels_ja = [_][]const u8{
        "スロット",
        "ブロック",
        "UTxO 数",
        "LMDB truth 比率",
        "CBOR サイズ超過",
        "CBOR ストリーム終端",
        "CBOR その他エラー",
        "台帳カバレッジ比率",
        "台帳欠損入力EMA",
        "台帳自動Strict",
    };

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        for (keys, 0..) |key, ki| {
            if (std.mem.startsWith(u8, line, key)) {
                const val = line[key.len..];
                const label = if (lang == .ja) labels_ja[ki] else labels_en[ki];
                std.debug.print("  {s}: {s}\n", .{ label, val });
                break;
            }
        }
    }

    // Find top Bayesian peer
    var best_idx: usize = 0;
    var best_val: f64 = 0.0;
    var found_peer = false;

    var lines2 = std.mem.splitScalar(u8, raw, '\n');
    while (lines2.next()) |line| {
        if (!std.mem.startsWith(u8, line, "tsunagi_peer_score_sample{")) continue;
        // tsunagi_peer_score_sample{index="N"} V.VVV
        const idx_start = std.mem.indexOf(u8, line, "index=\"") orelse continue;
        const idx_num_start = idx_start + 7;
        const idx_end = std.mem.indexOfPos(u8, line, idx_num_start, "\"") orelse continue;
        const close_brace = std.mem.indexOfPos(u8, line, idx_end, "} ") orelse continue;
        const val_str = line[close_brace + 2 ..];
        const idx_num = std.fmt.parseUnsigned(usize, line[idx_num_start..idx_end], 10) catch continue;
        const val = std.fmt.parseFloat(f64, val_str) catch continue;
        if (!found_peer or val > best_val) {
            best_val = val;
            best_idx = idx_num;
            found_peer = true;
        }
    }

    if (found_peer) {
        std.debug.print("  {s}: index={d} (score={d:.3})\n", .{
            p(lang, "Top Bayes peer", "Bayes 最良ピア"),
            best_idx,
            best_val,
        });
    }

    // Gaps
    std.debug.print("\n  -- {s} --\n", .{p(lang, "Gaps", "ギャップ")});
    const gap_snap_keys = [_][]const u8{
        "tsunagi_gap_missing_keys ",
        "tsunagi_gap_hot_top_count ",
        "tsunagi_gap_hot_top_age_seconds ",
        "tsunagi_gap_repeat_ratio ",
        "tsunagi_gap_new_keys_window ",
        "tsunagi_gap_missing_events_window ",
        "tsunagi_gap_last_seen_items ",
        "tsunagi_gap_last_seen_loaded ",
        "tsunagi_gap_last_seen_file_bytes ",
        "tsunagi_gap_last_seen_parse_errors_total ",
    };
    const gap_snap_en = [_][]const u8{
        "missing_keys",
        "hot_top_count",
        "hot_top_age_s",
        "repeat_ratio",
        "new_keys_window",
        "missing_events_window",
        "last_seen_items",
        "last_seen_loaded",
        "last_seen_file_bytes",
        "last_seen_parse_errors",
    };
    const gap_snap_ja = [_][]const u8{
        "欠損キー数",
        "ホットトップ回数",
        "ホットトップ経過秒",
        "リピート率",
        "ウィンドウ新規キー",
        "ウィンドウ欠損イベント",
        "last_seen現在数",
        "last_seen読込数",
        "last_seenバイト数",
        "last_seenパースエラー",
    };
    for (gap_snap_keys, 0..) |key, ki| {
        if (findMetricValue(raw, key)) |val| {
            const label = if (lang == .ja) gap_snap_ja[ki] else gap_snap_en[ki];
            std.debug.print("  {s}: {s}\n", .{ label, val });
        }
    }

    // Gap Trend (5m)
    std.debug.print("\n  -- {s} --\n", .{p(lang, "Gap Trend (5m)", "ギャップ推移 (5分)")});
    {
        const gt_keys = [_][]const u8{
            "tsunagi_gap_keys_delta_5m ",
            "tsunagi_gap_new_keys_5m ",
            "tsunagi_gap_resolved_5m ",
            "tsunagi_gap_evictions_delta_5m ",
            "tsunagi_gap_missing_events_5m ",
            "tsunagi_gap_hot_changes_5m ",
            "tsunagi_gap_win_rate ",
            "tsunagi_gap_window_unix ",
            "tsunagi_gap_last_seen_persist_unix ",
        };
        const gt_en = [_][]const u8{
            "keys_delta_5m",
            "new_keys_5m",
            "resolved_5m",
            "evictions_delta_5m",
            "missing_events_5m",
            "hot_changes_5m",
            "win_rate",
            "window_unix",
            "last_seen_persist_unix",
        };
        const gt_ja = [_][]const u8{
            "キー増減(5分)",
            "新規キー(5分)",
            "解決数(5分)",
            "追放増減(5分)",
            "欠損イベント(5分)",
            "ホット変動(5分)",
            "勝率",
            "ウィンドウ開始Unix",
            "最終永続化Unix",
        };
        for (gt_keys, 0..) |key, ki| {
            if (findMetricValue(raw, key)) |val| {
                const label = if (lang == .ja) gt_ja[ki] else gt_en[ki];
                std.debug.print("  {s}: {s}\n", .{ label, val });
            }
        }
    }

    // Consensus Clock
    std.debug.print("\n  -- {s} --\n", .{p(lang, "Clock Sanity", "クロック健全性")});
    {
        const ck_keys = [_][]const u8{
            "tsunagi_consensus_clock_violation_total ",
            "tsunagi_consensus_slot_jump_last ",
            "tsunagi_consensus_wall_drift_last ",
        };
        const ck_en = [_][]const u8{
            "violation_total",
            "slot_jump_last",
            "wall_drift_last",
        };
        const ck_ja = [_][]const u8{
            "違反合計",
            "スロットジャンプ(最新)",
            "壁時計ドリフト(最新)",
        };
        for (ck_keys, 0..) |key, ki| {
            if (findMetricValue(raw, key)) |val| {
                const label = if (lang == .ja) ck_ja[ki] else ck_en[ki];
                std.debug.print("  {s}: {s}\n", .{ label, val });
            }
        }
    }

    // Consensus Skeleton
    std.debug.print("\n  -- {s} --\n", .{p(lang, "Consensus Skeleton", "コンセンサススケルトン")});
    {
        const cs_keys = [_][]const u8{
            "tsunagi_consensus_health_score ",
            "tsunagi_consensus_tip_fresh_seconds ",
            "tsunagi_consensus_chain_quality ",
            "tsunagi_consensus_header_err_delta_5m ",
            "tsunagi_consensus_keepalive_to_delta_5m ",
            "tsunagi_consensus_rollback_delta_5m ",
            "tsunagi_consensus_stall_reason_code ",
            "tsunagi_consensus_stall_age_seconds ",
            "tsunagi_consensus_blockfetch_age_seconds ",
            "tsunagi_consensus_keepalive_age_seconds ",
            "tsunagi_consensus_window_unix ",
            "tsunagi_consensus_blockfetch_batches_delta_5m ",
            "tsunagi_consensus_keepalive_pongs_delta_5m ",
            "tsunagi_consensus_peer_closed_delta_5m ",
            "tsunagi_consensus_header_store_writes_delta_5m ",
        };
        const cs_en = [_][]const u8{
            "health_score",
            "tip_fresh_seconds",
            "chain_quality",
            "header_err_delta_5m",
            "keepalive_to_delta_5m",
            "rollback_delta_5m",
            "stall_reason_code",
            "stall_age_seconds",
            "blockfetch_age_seconds",
            "keepalive_age_seconds",
            "window_unix",
            "blockfetch_batches_delta_5m",
            "keepalive_pongs_delta_5m",
            "peer_closed_delta_5m",
            "header_store_writes_delta_5m",
        };
        const cs_ja = [_][]const u8{
            "健全スコア",
            "ティップ鮮度(秒)",
            "チェーン品質",
            "ヘッダエラー(5分)",
            "キープアライブTO(5分)",
            "ロールバック(5分)",
            "ストール理由コード",
            "ストール経過秒数",
            "ブロックフェッチ経過秒数",
            "キープアライブ経過秒数",
            "ウィンドウUnix",
            "BFバッチデルタ(5分)",
            "KAポングデルタ(5分)",
            "ピア切断デルタ(5分)",
            "HSW書込デルタ(5分)",
        };
        for (cs_keys, 0..) |key, ki| {
            if (findMetricValue(raw, key)) |val| {
                const label = if (lang == .ja) cs_ja[ki] else cs_en[ki];
                std.debug.print("  {s}: {s}\n", .{ label, val });
            }
        }
    }

    // Authority Confidence
    std.debug.print("\n  -- {s} --\n", .{p(lang, "Authority Confidence", "オーソリティ信頼度")});
    {
        const auth_keys = [_][]const u8{
            "tsunagi_authority_confidence ",
            "tsunagi_authority_finality_score ",
            "tsunagi_authority_reorg_depth_last ",
            "tsunagi_authority_reorg_events_5m ",
            "tsunagi_authority_fork_events_total ",
            "tsunagi_authority_reorg_depth_max_5m ",
            "tsunagi_authority_reorg_depth_avg_5m ",
            "tsunagi_authority_fork_delta_5m ",
            "tsunagi_authority_stable_seconds ",
            "tsunagi_authority_gate_active ",
            "tsunagi_authority_reason_code_last ",
            "tsunagi_authority_reorg_events_delta_5m ",
            "tsunagi_authority_window_unix ",
        };
        const auth_en = [_][]const u8{
            "confidence",
            "finality_score",
            "reorg_depth_last",
            "reorg_events_5m",
            "fork_events_total",
            "reorg_depth_max_5m",
            "reorg_depth_avg_5m",
            "fork_delta_5m",
            "stable_seconds",
            "gate_active",
            "reason_code_last",
            "reorg_events_delta_5m",
            "window_unix",
        };
        const auth_ja = [_][]const u8{
            "信頼度",
            "ファイナリティ",
            "リオーグ深度",
            "リオーグイベント(5分)",
            "フォークイベント合計",
            "リオーグ最大深度(5分)",
            "リオーグ平均深度(5分)",
            "フォークデルタ(5分)",
            "安定秒数",
            "ゲート有効",
            "理由コード",
            "リオーグデルタ(5分)",
            "ウィンドウUnix",
        };
        for (auth_keys, 0..) |key, ki| {
            if (findMetricValue(raw, key)) |val| {
                const label = if (lang == .ja) auth_ja[ki] else auth_en[ki];
                std.debug.print("  {s}: {s}\n", .{ label, val });
            }
        }
    }

    // Header Validation
    std.debug.print("\n  -- {s} --\n", .{p(lang, "Header Validation", "ヘッダ検証")});
    {
        const hv_keys = [_][]const u8{
            "tsunagi_header_validate_total ",
            "tsunagi_header_validate_fail_total ",
            "tsunagi_header_validate_fail_ratio ",
            "tsunagi_header_hash_mismatch_total ",
            "tsunagi_header_prevhash_mismatch_total ",
        };
        const hv_en = [_][]const u8{
            "validate_total",
            "validate_fail_total",
            "validate_fail_ratio",
            "hash_mismatch_total",
            "prevhash_mismatch_total",
        };
        const hv_ja = [_][]const u8{
            "検証合計",
            "検証失敗合計",
            "検証失敗率",
            "ハッシュ不一致",
            "前ハッシュ不一致",
        };
        for (hv_keys, 0..) |key, ki| {
            if (findMetricValue(raw, key)) |val| {
                const label = if (lang == .ja) hv_ja[ki] else hv_en[ki];
                std.debug.print("  {s}: {s}\n", .{ label, val });
            }
        }
    }

    // Anomaly Bands
    std.debug.print("\n  -- {s} --\n", .{p(lang, "Anomaly Bands", "異常バンド")});
    {
        const ab_keys = [_][]const u8{
            "tsunagi_ledger_anomaly_total ",
            "tsunagi_ledger_anomaly_fee_total ",
            "tsunagi_ledger_anomaly_dust_total ",
            "tsunagi_ledger_anomaly_whale_total ",
            "tsunagi_ledger_anomaly_strict_disconnect_total ",
            "tsunagi_ledger_dust_ratio_last ",
            "tsunagi_ledger_dust_count_last ",
            "tsunagi_ledger_max_out_lovelace_last ",
        };
        const ab_en = [_][]const u8{
            "anomaly_total",
            "fee_anomalies",
            "dust_anomalies",
            "whale_anomalies",
            "strict_disconnects",
            "dust_ratio_last",
            "dust_count_last",
            "max_out_lovelace_last",
        };
        const ab_ja = [_][]const u8{
            "異常合計",
            "手数料異常",
            "ダスト異常",
            "ホエール異常",
            "Strict切断",
            "ダスト率(最新)",
            "ダスト数(最新)",
            "最大出力(最新)",
        };
        for (ab_keys, 0..) |key, ki| {
            if (findMetricValue(raw, key)) |val| {
                const label = if (lang == .ja) ab_ja[ki] else ab_en[ki];
                std.debug.print("  {s}: {s}\n", .{ label, val });
            }
        }
    }

    // TxSubmission
    std.debug.print("\n  -- {s} --\n", .{p(lang, "TxSubmission", "TxSubmission")});
    {
        const ts_keys = [_][]const u8{
            "tsunagi_txsub_sessions_total ",
            "tsunagi_txsub_session_active ",
            "tsunagi_txsub_last_msg_unix ",
            "tsunagi_txsub_done_total ",
            "tsunagi_txsub_msgs_total ",
            "tsunagi_txsub_decode_errors_total ",
            "tsunagi_txsub_inventory_sent_total ",
            "tsunagi_txsub_txs_served_total ",
            "tsunagi_txsub_bytes_served_total ",
            "tsunagi_txsub_rx_msgs_total ",
            "tsunagi_txsub_rx_bytes_total ",
            "tsunagi_txsub_session_rx_msgs_last ",
            "tsunagi_txsub_session_rx_bytes_last ",
            "tsunagi_txsub_session_first_msg_id_last ",
            "tsunagi_txsub_session_age_seconds_last ",
            "tsunagi_txsub_msg_id_0_total ",
            "tsunagi_txsub_msg_id_1_total ",
            "tsunagi_txsub_msg_id_3_total ",
            "tsunagi_txsub_msg_id_4_total ",
            "tsunagi_txsub_msg_id_5_total ",
            "tsunagi_txsub_msg_id_6_total ",
            "tsunagi_txsub_msg_id_unknown_total ",
            "tsunagi_txsub_broadcast_attempt_total ",
            "tsunagi_txsub_broadcast_sent_total ",
            "tsunagi_txsub_broadcast_blocked_total ",
            "tsunagi_txsub_known_total ",
            "tsunagi_txsub_ignored_total ",
            "tsunagi_txsub_invalid_shape_total ",
            "tsunagi_txsub_state_code ",
        };
        const ts_en = [_][]const u8{
            "sessions_total",
            "session_active",
            "last_msg_unix",
            "done_total",
            "msgs_total",
            "decode_errors_total",
            "inventory_sent_total",
            "txs_served_total",
            "bytes_served_total",
            "rx_msgs_total",
            "rx_bytes_total",
            "session_rx_msgs",
            "session_rx_bytes",
            "session_first_msg_id",
            "session_age_seconds",
            "msg_id_0 (ReqTxIds NB)",
            "msg_id_1 (ReqTxIds BLK)",
            "msg_id_3 (ReqTxs)",
            "msg_id_4 (ReplyTxs)",
            "msg_id_5 (Done)",
            "msg_id_6 (Init)",
            "msg_id_unknown",
            "broadcast_attempt_total",
            "broadcast_sent_total",
            "broadcast_blocked_total",
            "known_total",
            "ignored_total",
            "invalid_shape_total",
            "state_code",
        };
        const ts_ja = [_][]const u8{
            "セッション合計",
            "セッション有効",
            "最終メッセージUnix",
            "Done合計",
            "メッセージ合計",
            "デコードエラー合計",
            "在庫送信合計",
            "Tx提供合計",
            "バイト提供合計",
            "受信メッセージ合計",
            "受信バイト合計",
            "セッション受信メッセージ",
            "セッション受信バイト",
            "セッション初回MsgID",
            "セッション経過秒",
            "msg_id_0 (ReqTxIds NB)",
            "msg_id_1 (ReqTxIds BLK)",
            "msg_id_3 (ReqTxs)",
            "msg_id_4 (ReplyTxs)",
            "msg_id_5 (Done)",
            "msg_id_6 (Init)",
            "msg_id_不明",
            "ブロードキャスト試行",
            "ブロードキャスト送信",
            "ブロードキャストブロック",
            "既知合計",
            "無視合計",
            "不正形状合計",
            "状態コード",
        };
        for (ts_keys, 0..) |key, ki| {
            if (findMetricValue(raw, key)) |val| {
                const label = if (lang == .ja) ts_ja[ki] else ts_en[ki];
                std.debug.print("  {s}: {s}\n", .{ label, val });
            }
        }
    }

    // Convergence / Backfill
    std.debug.print("\n  -- {s} --\n", .{p(lang, "Convergence", "収束状況")});
    const conv_keys = [_][]const u8{
        "tsunagi_backfill_runs_total ",
        "tsunagi_backfill_blocks_total ",
        "tsunagi_backfill_errors_total ",
        "tsunagi_backfill_busy_total ",
        "tsunagi_backfill_last_unix ",
        "tsunagi_backfill_last_blocks ",
        "tsunagi_backfill_cursor_offset ",
        "tsunagi_convergence_ready ",
        "tsunagi_backfill_recommend_profile_code ",
        "tsunagi_backfill_recommend_blocks ",
        "tsunagi_backfill_recommend_seconds ",
        "tsunagi_backfill_recommend_pressure ",
    };
    const conv_labels_en = [_][]const u8{
        "Backfill runs",
        "Backfill blocks",
        "Backfill errors",
        "Backfill busy (skipped)",
        "Backfill last run (unix)",
        "Backfill last blocks",
        "Backfill cursor offset",
        "Convergence ready",
        "Recommend profile",
        "Recommend blocks",
        "Recommend seconds",
        "Recommend pressure",
    };
    const conv_labels_ja = [_][]const u8{
        "バックフィル実行回数",
        "バックフィルブロック数",
        "バックフィルエラー数",
        "バックフィル競合(スキップ)",
        "バックフィル最終実行(unix)",
        "バックフィル最終ブロック数",
        "バックフィルカーソル位置",
        "収束準備完了",
        "推奨プロファイル",
        "推奨ブロック",
        "推奨秒",
        "推奨圧力",
    };

    for (conv_keys, 0..) |key, ki| {
        if (findMetricValue(raw, key)) |val| {
            const label = if (lang == .ja) conv_labels_ja[ki] else conv_labels_en[ki];
            std.debug.print("  {s}: {s}\n", .{ label, val });
        }
    }

    // Capture ETA
    {
        const m_cap_bytes_raw = findMetricValue(raw, "tsunagi_capture_mainnet_bin_bytes ") orelse "0";
        const m_cap_rot_bytes_raw = findMetricValue(raw, "tsunagi_capture_rotate_bytes ") orelse "0";
        const m_cap_rot_mb_raw = findMetricValue(raw, "tsunagi_capture_rotate_mb ") orelse "0";
        const m_cap_seg_raw = findMetricValue(raw, "tsunagi_capture_segments_count ") orelse "0";
        const m_cap_b = std.fmt.parseUnsigned(u64, m_cap_bytes_raw, 10) catch 0;
        const m_rot_direct = std.fmt.parseUnsigned(u64, m_cap_rot_bytes_raw, 10) catch 0;
        const m_cap_rot = if (m_rot_direct > 0) m_rot_direct else blk: {
            const mb = std.fmt.parseUnsigned(u64, m_cap_rot_mb_raw, 10) catch 0;
            break :blk mb * 1024 * 1024;
        };
        const m_cap_seg = std.fmt.parseUnsigned(u64, m_cap_seg_raw, 10) catch 0;
        updateCaptureRate(m_cap_b);
        var m_eta_buf: [16]u8 = undefined;
        const m_eta = formatEta(&m_eta_buf, m_cap_b, m_cap_rot, m_cap_seg);
        const m_rate_u: u64 = @intFromFloat(eta_rate_bps);
        std.debug.print("  {s}: {d}\n", .{ p(lang, "capture_rotate_bytes", "キャプチャ回転バイト"), m_cap_rot });
        std.debug.print("  {s}: {d}\n", .{ p(lang, "capture_bytes", "キャプチャバイト"), m_cap_b });
        std.debug.print("  {s}: {d}\n", .{ p(lang, "capture_rate_bps", "キャプチャ速度B/s"), m_rate_u });
        std.debug.print("  {s}: {s}\n", .{ p(lang, "capture_eta", "キャプチャETA"), m_eta });
    }

    // Backfill Gap Steering
    std.debug.print("\n  -- {s} --\n", .{p(lang, "Backfill Gap Steering", "BFギャップステアリング")});
    const bgs_keys = [_][]const u8{
        "tsunagi_backfill_gap_keys_loaded_last ",
        "tsunagi_backfill_produced_total_last ",
        "tsunagi_backfill_gap_hit_last ",
        "tsunagi_backfill_gap_hit_ratio ",
        "tsunagi_backfill_gap_hit_total ",
        "tsunagi_backfill_gap_consumed_seen_last ",
        "tsunagi_backfill_gap_consumed_resolved_last ",
        "tsunagi_backfill_gap_consumed_seen_total ",
        "tsunagi_backfill_gap_consumed_resolved_total ",
    };
    const bgs_en = [_][]const u8{
        "gap_keys_loaded_last",
        "produced_total_last",
        "gap_hit_last",
        "gap_hit_ratio",
        "gap_hit_total",
        "consumed_seen_last",
        "consumed_resolved_last",
        "consumed_seen_total",
        "consumed_resolved_total",
    };
    const bgs_ja = [_][]const u8{
        "ギャップキー読込数",
        "生成出力数",
        "ヒット数(前回)",
        "ヒット率",
        "ヒット累計",
        "消費検出数(前回)",
        "消費解決数(前回)",
        "消費検出累計",
        "消費解決累計",
    };
    for (bgs_keys, 0..) |key, ki| {
        if (findMetricValue(raw, key)) |val| {
            const label = if (lang == .ja) bgs_ja[ki] else bgs_en[ki];
            std.debug.print("  {s}: {s}\n", .{ label, val });
        }
    }

    // Backfill Autotune
    std.debug.print("\n  -- {s} --\n", .{p(lang, "Backfill Autotune", "BF自動調整")});
    const bat_keys = [_][]const u8{
        "tsunagi_backfill_autotune_enabled ",
        "tsunagi_backfill_autotune_profile_current ",
        "tsunagi_backfill_autotune_last_change_unix ",
        "tsunagi_backfill_autotune_switch_total ",
        "tsunagi_backfill_autotune_reason_code_last ",
    };
    const bat_en = [_][]const u8{
        "enabled",
        "profile_current",
        "last_change_unix",
        "switch_total",
        "reason_code_last",
    };
    const bat_ja = [_][]const u8{
        "有効",
        "現在プロファイル",
        "最終変更Unix",
        "切替累計",
        "理由コード(前回)",
    };
    for (bat_keys, 0..) |key, ki| {
        if (findMetricValue(raw, key)) |val| {
            const label = if (lang == .ja) bat_ja[ki] else bat_en[ki];
            std.debug.print("  {s}: {s}\n", .{ label, val });
        }
    }

    // BAEY audit log + policy tick
    std.debug.print("\n  -- {s} --\n", .{p(lang, "BAEY Audit Log + Policy Tick", "BAEY 監査ログ + ポリシーティック")});
    {
        const by_keys = [_][]const u8{
            "tsunagi_baey_events_total ",
            "tsunagi_baey_last_event_unix ",
            "tsunagi_baey_weight_stall ",
            "tsunagi_baey_weight_density ",
            "tsunagi_baey_weight_header ",
            "tsunagi_baey_weight_keepalive ",
            "tsunagi_baey_weight_gap ",
            "tsunagi_baey_weight_authority ",
            "tsunagi_baey_weight_finality ",
        };
        const by_en = [_][]const u8{
            "events_total",
            "last_event_unix",
            "weight_stall",
            "weight_density",
            "weight_header",
            "weight_keepalive",
            "weight_gap",
            "weight_authority",
            "weight_finality",
        };
        const by_ja = [_][]const u8{
            "イベント合計",
            "最終イベントUnix",
            "重み_ストール",
            "重み_密度",
            "重み_ヘッダー",
            "重み_キープアライブ",
            "重み_ギャップ",
            "重み_オーソリティ",
            "重み_ファイナリティ",
        };
        for (by_keys, 0..) |key, ki| {
            if (findMetricValue(raw, key)) |val| {
                const label = if (lang == .ja) by_ja[ki] else by_en[ki];
                std.debug.print("  {s}: {s}\n", .{ label, val });
            }
        }

        // Last policy tick from events.log
        const mpt_raw = runShellCapture(alloc, "grep policy_tick \"${TSUNAGI_HOME:-~/tsunagi-home-mainnet}/baey/events.log\" 2>/dev/null | tail -n 1");
        defer if (mpt_raw) |pr| alloc.free(pr);
        const mpt_line: []const u8 = if (mpt_raw) |pr| trimShell(pr) else "";
        if (mpt_line.len > 10) {
            const mpt_now: u64 = @intCast(@max(0, compat.timestamp()));
            const mpt_unix = extractJsonU64(mpt_line, "\"unix\"");
            const mpt_age = if (mpt_unix > 0 and mpt_now >= mpt_unix) mpt_now - mpt_unix else 0;
            std.debug.print("  {s}: {s}\n", .{ p(lang, "policy_score", "ポリシースコア"), extractJsonStr(mpt_line, "\"score\"") });
            std.debug.print("  {s}: {s}\n", .{ p(lang, "policy_action", "ポリシーアクション"), extractJsonStr(mpt_line, "\"action\"") });
            std.debug.print("  {s}: {d}s\n", .{ p(lang, "policy_age", "ポリシー経過"), mpt_age });
            std.debug.print("  {s}: {s}\n", .{ p(lang, "policy_stall", "ストール"), extractJsonStr(mpt_line, "\"stall\"") });
            std.debug.print("  {s}: {s}\n", .{ p(lang, "policy_density", "密度"), extractJsonStr(mpt_line, "\"density\"") });
            std.debug.print("  {s}: {s}\n", .{ p(lang, "policy_win_rate", "勝率"), extractJsonStr(mpt_line, "\"win_rate\"") });
            std.debug.print("  {s}: {s}\n", .{ p(lang, "leader_guard", "リーダーガード"), extractJsonStr(mpt_line, "\"leader_guard\"") });
            std.debug.print("  {s}: {s}\n", .{ p(lang, "lg_reason", "LG理由コード"), extractJsonStr(mpt_line, "\"lg_reason\"") });
            std.debug.print("  {s}: {s}\n", .{ p(lang, "producer_reason_code", "プロデューサー理由"), extractJsonStr(mpt_line, "\"producer_reason_code\"") });
            std.debug.print("  {s}: {s}\n", .{ p(lang, "producer_stake_x1e9", "ステーク(x1e9)"), extractJsonStr(mpt_line, "\"producer_stake_x1e9\"") });
            std.debug.print("  {s}: {s}\n", .{ p(lang, "producer_expected_epoch", "期待リーダー/エポック"), extractJsonStr(mpt_line, "\"producer_expected_epoch\"") });
        } else {
            std.debug.print("  {s}: n/a\n", .{p(lang, "policy_tick", "ポリシーティック")});
        }
    }

    // Producer Skeleton
    std.debug.print("\n  -- {s} --\n", .{p(lang, "Producer Skeleton", "プロデューサースケルトン")});
    {
        const ps_keys = [_][]const u8{
            "tsunagi_producer_state ",
            "tsunagi_producer_last_slot_checked ",
            "tsunagi_producer_last_leader_slot ",
            "tsunagi_producer_leader_checks_total ",
            "tsunagi_producer_observed_slot ",
            "tsunagi_producer_estimated_slot ",
            "tsunagi_producer_drift_last_slots ",
            "tsunagi_producer_drift_abs_last ",
            "tsunagi_producer_drift_abs_max ",
            "tsunagi_producer_drift_events_total ",
            "tsunagi_producer_clock_ok ",
            "tsunagi_producer_genesis_unix ",
            "tsunagi_producer_slot_length_s ",
            "tsunagi_producer_genesis_parse_ok ",
            "tsunagi_producer_genesis_path_ok ",
            "tsunagi_producer_genesis_last_error_code ",
            "tsunagi_producer_epoch_last ",
            "tsunagi_producer_slot_in_epoch_last ",
            "tsunagi_producer_leader_eligible_last ",
            "tsunagi_producer_leader_probability_x1e6 ",
            "tsunagi_producer_leader_checks_epoch_total ",
            "tsunagi_producer_vrf_enabled ",
            "tsunagi_producer_vrf_parse_ok ",
            "tsunagi_producer_vrf_checked_total ",
            "tsunagi_producer_vrf_reason_code_last ",
            "tsunagi_producer_vrf_init_ok ",
            "tsunagi_producer_vrf_verify_ok_last ",
            "tsunagi_producer_vrf_output_prefix_last ",
            "tsunagi_producer_keys_enabled ",
            "tsunagi_producer_keys_parse_ok ",
            "tsunagi_producer_keys_validate_total ",
            "tsunagi_producer_keys_err_code_last ",
            "tsunagi_producer_kes_ok ",
            "tsunagi_producer_vrf_ok ",
            "tsunagi_producer_keys_perms_ok ",
            "tsunagi_producer_keys_readable_ok ",
            "tsunagi_producer_stake_fraction_x1e9 ",
            "tsunagi_producer_active_slot_coeff_x1e6 ",
            "tsunagi_producer_expected_leaders_per_epoch ",
            "tsunagi_producer_leader_reason_code_last ",
            "tsunagi_producer_elig_test_enabled ",
            "tsunagi_producer_elig_test_slot_in_epoch ",
        };
        const ps_en = [_][]const u8{
            "state",
            "last_slot_checked",
            "last_leader_slot",
            "leader_checks_total",
            "observed_slot",
            "estimated_slot",
            "drift_last_slots",
            "drift_abs_max",
            "drift_events_total",
            "genesis_unix",
            "slot_length_s",
            "genesis_parse_ok",
            "genesis_path_ok",
            "genesis_last_error_code",
            "epoch_last",
            "slot_in_epoch_last",
            "leader_eligible_last",
            "leader_probability_x1e6",
            "leader_checks_epoch_total",
            "vrf_enabled",
            "vrf_parse_ok",
            "vrf_checked_total",
            "vrf_reason_code_last",
            "vrf_init_ok",
            "vrf_verify_ok_last",
            "vrf_output_prefix_last",
            "keys_enabled",
            "keys_parse_ok",
            "keys_validate_total",
            "keys_err_code_last",
            "kes_ok",
            "vrf_key_ok",
            "keys_perms_ok",
            "keys_readable_ok",
            "stake_fraction_x1e9",
            "active_slot_coeff_x1e6",
            "expected_leaders_per_epoch",
            "leader_reason_code_last",
            "elig_test_enabled",
            "elig_test_slot_in_epoch",
        };
        const ps_ja = [_][]const u8{
            "状態",
            "最終チェックスロット",
            "最終リーダースロット",
            "リーダーチェック合計",
            "観測スロット",
            "推定スロット",
            "ドリフト(最新)",
            "ドリフト最大",
            "ドリフトイベント合計",
            "ジェネシスUNIX",
            "スロット長(秒)",
            "ジェネシス解析OK",
            "ジェネシスパスOK",
            "ジェネシスエラーコード",
            "エポック(最新)",
            "エポック内スロット",
            "リーダー資格",
            "リーダー確率(x1e6)",
            "リーダーチェック(エポック)",
            "VRF有効",
            "VRF解析OK",
            "VRFチェック合計",
            "VRF理由コード",
            "VRF初期化OK",
            "VRF検証OK",
            "VRF出力プレフィックス",
            "鍵管理有効",
            "鍵解析OK",
            "鍵検証合計",
            "鍵エラーコード",
            "KES OK",
            "VRF鍵OK",
            "パーミッションOK",
            "読取OK",
            "ステーク比率(x1e9)",
            "アクティブスロット係数(x1e6)",
            "期待リーダー/エポック",
            "リーダー理由コード",
            "適格テスト有効",
            "適格テストスロット",
        };
        for (ps_keys, 0..) |key, ki| {
            if (findMetricValue(raw, key)) |val| {
                const label = if (lang == .ja) ps_ja[ki] else ps_en[ki];
                std.debug.print("  {s}: {s}\n", .{ label, val });
            }
        }
    }

    // Gap Summary (from summary.json)
    std.debug.print("\n  -- {s} --\n", .{p(lang, "Gap Summary (summary.json)", "ギャップサマリー (summary.json)")});
    const gs = readLatestGapSummary(alloc);
    defer if (gs) |g| alloc.free(g.raw);

    if (gs) |g| {
        const gs_now: u64 = @intCast(@max(0, compat.timestamp()));
        const gs_age = if (gs_now > g.unix) gs_now - g.unix else 0;
        std.debug.print("  {s}: {s}\n", .{ p(lang, "version", "バージョン"), g.version });
        std.debug.print("  {s}: {d}s\n", .{ p(lang, "age", "経過"), gs_age });
        std.debug.print("  {s}: {s}\n", .{ p(lang, "truth_ratio", "真実比率"), g.lmdb_truth_ratio });
        std.debug.print("  {s}: {s}\n", .{ p(lang, "missing_inputs_ema", "欠損入力EMA"), g.ledger_missing_inputs_ema });
        std.debug.print("  {s}: {s}\n", .{ p(lang, "value_check_ratio", "値検査比率"), g.ledger_value_check_ratio });
        std.debug.print("  {s}: {s}\n", .{ p(lang, "gap_missing_keys", "ギャップキー数"), g.gap_missing_keys });
        std.debug.print("  {s}: {s}\n", .{ p(lang, "repeat_ratio", "リピート率"), g.gap_repeat_ratio });
        std.debug.print("  {s}: {s}\n", .{ p(lang, "hot_top_age_seconds", "ホットトップ経過秒"), g.gap_hot_top_age_seconds });
        std.debug.print("  {s}: {s}\n", .{ p(lang, "backfill_runs", "バックフィル実行数"), g.backfill_runs_total });
        std.debug.print("  {s}: {s}\n", .{ p(lang, "backfill_blocks", "バックフィルブロック数"), g.backfill_blocks_total });
        std.debug.print("  {s}: {s}\n", .{ p(lang, "cursor_offset", "カーソル位置"), g.backfill_cursor_offset });
        std.debug.print("  {s}: {s}\n", .{ p(lang, "segment_done_ratio", "セグメント完了率"), g.backfill_segment_done_ratio });
    } else {
        std.debug.print("  {s}\n", .{p(lang, "summary.json: n/a", "summary.json: n/a")});
    }

    // Memory / Footprint
    std.debug.print("\n  -- {s} --\n", .{p(lang, "Memory / Footprint", "メモリ / フットプリント")});
    {
        const mem_keys = [_][]const u8{
            "tsunagi_rss_kb ",
            "tsunagi_lmdb_map_size_bytes ",
        };
        const mem_en = [_][]const u8{
            "rss_kb",
            "lmdb_map_size_bytes",
        };
        const mem_ja = [_][]const u8{
            "RSS (KB)",
            "LMDB マップサイズ (バイト)",
        };
        for (mem_keys, 0..) |key, ki| {
            if (findMetricValue(raw, key)) |val| {
                const label = if (lang == .ja) mem_ja[ki] else mem_en[ki];
                std.debug.print("  {s}: {s}\n", .{ label, val });
            }
        }
    }

    // Memory Attribution
    std.debug.print("\n  -- {s} --\n", .{p(lang, "Memory Attribution", "メモリ帰属")});
    {
        const ma_keys = [_][]const u8{
            "tsunagi_alloc_current_bytes ",
            "tsunagi_alloc_peak_bytes ",
            "tsunagi_mem_gaps_total_bytes_est ",
            "tsunagi_mem_gaps_keys_count ",
            "tsunagi_mem_gaps_first_seen_count ",
            "tsunagi_mem_gaps_last_seen_count ",
            "tsunagi_mem_mempool_bytes_est ",
            "tsunagi_mem_capture_bytes_est ",
            "tsunagi_mem_lmdb_map_bytes ",
        };
        const ma_en = [_][]const u8{
            "alloc_current_bytes",
            "alloc_peak_bytes",
            "gaps_total_bytes_est",
            "gaps_keys_count",
            "gaps_first_seen_count",
            "gaps_last_seen_count",
            "mempool_bytes_est",
            "capture_bytes_est",
            "lmdb_map_bytes",
        };
        const ma_ja = [_][]const u8{
            "アロケータ現在バイト",
            "アロケータピークバイト",
            "ギャップ推定バイト合計",
            "ギャップキー数",
            "ギャップ初検出数",
            "ギャップ最終検出数",
            "メモリプール推定バイト",
            "キャプチャ推定バイト",
            "LMDBマップバイト",
        };
        for (ma_keys, 0..) |key, ki| {
            if (findMetricValue(raw, key)) |val| {
                const label = if (lang == .ja) ma_ja[ki] else ma_en[ki];
                std.debug.print("  {s}: {s}\n", .{ label, val });
            }
        }
    }

    std.debug.print("\n", .{});
}

fn actionTsfArtifact(alloc: std.mem.Allocator, lang: i18n.Lang) void {
    std.debug.print("\n  {s}\n", .{p(lang, "Starting TSF artifact export...", "TSF アーティファクトエクスポートを開始...")});
    runShell(alloc, "systemctl --user start tsf-artifact.service");
    std.debug.print("  {s}\n\n", .{p(lang, "Done. Check logs: journalctl --user -u tsf-artifact.service --since '1 min ago'", "完了。ログ確認: journalctl --user -u tsf-artifact.service --since '1 min ago'")});
}

fn actionBackfill(alloc: std.mem.Allocator, lang: i18n.Lang) void {
    std.debug.print("\n  {s}\n", .{p(lang, "Backfilling LMDB from capture directory...", "キャプチャディレクトリから LMDB をバックフィル中...")});

    // Resolve capture dir: $TSUNAGI_HOME/captures or ~/tsunagi-home-mainnet/captures
    const home_dir = runShellCapture(alloc, "echo \"${TSUNAGI_HOME:-$HOME/tsunagi-home-mainnet}\"") orelse {
        std.debug.print("  {s}\n\n", .{p(lang, "Cannot resolve TSUNAGI_HOME.", "TSUNAGI_HOME を解決できません。")});
        return;
    };
    defer alloc.free(home_dir);
    const trimmed_home = std.mem.trimEnd(u8, home_dir, "\n\r ");
    if (trimmed_home.len == 0) {
        std.debug.print("  {s}\n\n", .{p(lang, "Empty TSUNAGI_HOME.", "TSUNAGI_HOME が空です。")});
        return;
    }

    const capture_dir = std.fmt.allocPrint(alloc, "{s}/captures", .{trimmed_home}) catch {
        std.debug.print("  alloc failed\n", .{});
        return;
    };
    defer alloc.free(capture_dir);

    const cmd = std.fmt.allocPrint(
        alloc,
        "tsunagi-node lmdb-backfill-dir --dir {s} --lmdb {s}/lmdb --strict 2>&1",
        .{ capture_dir, trimmed_home },
    ) catch return;
    defer alloc.free(cmd);

    runShell(alloc, cmd);
    std.debug.print("\n", .{});
}

fn actionInstall(alloc: std.mem.Allocator, lang: i18n.Lang) void {
    std.debug.print("\n  {s}\n", .{p(lang, "Install latest release?", "最新リリースをインストールしますか？")});
    if (!confirm(lang)) {
        std.debug.print("  {s}\n\n", .{p(lang, "Cancelled.", "キャンセルしました。")});
        return;
    }

    const lang_flag: []const u8 = if (lang == .ja) "ja" else "en";
    const cmd = std.fmt.allocPrint(
        alloc,
        "tsunagi-node setup --role relay --install latest --lang {s} 2>&1",
        .{lang_flag},
    ) catch return;
    defer alloc.free(cmd);

    runShell(alloc, cmd);
    std.debug.print("\n", .{});
}

fn actionToggleTimer(alloc: std.mem.Allocator, lang: i18n.Lang, timer_name: []const u8, label_en: []const u8, label_ja: []const u8) void {
    // Check current state
    const check_cmd = std.fmt.allocPrint(
        alloc,
        "systemctl --user is-enabled {s} 2>/dev/null || echo disabled",
        .{timer_name},
    ) catch return;
    defer alloc.free(check_cmd);

    const state_raw = runShellCapture(alloc, check_cmd) orelse {
        std.debug.print("  {s}\n\n", .{p(lang, "Cannot check timer state.", "タイマーの状態を確認できません。")});
        return;
    };
    defer alloc.free(state_raw);
    const state = std.mem.trimEnd(u8, state_raw, "\n\r ");

    const currently_enabled = std.mem.eql(u8, state, "enabled");
    const label = p(lang, label_en, label_ja);

    if (currently_enabled) {
        std.debug.print("\n  {s}: {s} -> {s}\n", .{ label, p(lang, "enabled", "有効"), p(lang, "disabling", "無効化中") });
        const cmd = std.fmt.allocPrint(alloc, "systemctl --user disable --now {s}", .{timer_name}) catch return;
        defer alloc.free(cmd);
        runShell(alloc, cmd);
    } else {
        std.debug.print("\n  {s}: {s} -> {s}\n", .{ label, p(lang, "disabled", "無効"), p(lang, "enabling", "有効化中") });
        const cmd = std.fmt.allocPrint(alloc, "systemctl --user enable --now {s}", .{timer_name}) catch return;
        defer alloc.free(cmd);
        runShell(alloc, cmd);
    }
    std.debug.print("  {s}\n\n", .{p(lang, "Done.", "完了。")});
}

// ── Upgrade / Rollback actions ───────────────────────────────────────

fn actionUpgrade(alloc: std.mem.Allocator, lang: i18n.Lang) void {
    std.debug.print("\n  {s}\n", .{p(lang, "Upgrade to latest release?", "最新リリースにアップグレードしますか？")});
    if (!confirm(lang)) {
        std.debug.print("  {s}\n\n", .{p(lang, "Cancelled.", "キャンセルしました。")});
        return;
    }

    std.debug.print("\n", .{});
    const result = release_install.install(alloc, "latest", lang) catch {
        std.debug.print("  {s}\n\n", .{p(lang, "Upgrade failed.", "アップグレードに失敗しました。")});
        return;
    };

    std.debug.print("  {s}: {s}\n", .{ p(lang, "Upgraded to", "アップグレード完了"), result.tag });

    // Restart service
    std.debug.print("  {s}\n", .{p(lang, "Restarting node...", "ノードを再起動中...")});
    runShell(alloc, "systemctl --user restart tsunagi-mainnet.service");
    std.debug.print("  {s}\n\n", .{p(lang, "Done.", "完了。")});
}

fn actionListVersions(alloc: std.mem.Allocator, lang: i18n.Lang) void {
    std.debug.print("\n--- {s} ---\n\n", .{p(lang, "Installed Versions", "インストール済みバージョン")});

    // Current tag
    if (release_install.getCurrentTag(alloc)) |cur| {
        defer alloc.free(cur);
        std.debug.print("  {s}: {s}\n\n", .{ p(lang, "Current", "現在"), cur });
    } else {
        std.debug.print("  {s}: {s}\n\n", .{ p(lang, "Current", "現在"), p(lang, "(unknown)", "（不明）") });
    }

    const tags = release_install.listInstalledTags(alloc) catch {
        std.debug.print("  {s}\n\n", .{p(lang, "Could not list versions.", "バージョン一覧を取得できません。")});
        return;
    };
    defer {
        for (tags) |t| alloc.free(t);
        alloc.free(tags);
    }

    if (tags.len == 0) {
        std.debug.print("  {s}\n\n", .{p(lang, "No installed versions found in ~/.local/tsunagi/", "~/.local/tsunagi/ にバージョンが見つかりません")});
        return;
    }

    for (tags, 1..) |tag, idx| {
        std.debug.print("  {d}) {s}\n", .{ idx, tag });
    }
    std.debug.print("\n", .{});
}

fn actionRollback(alloc: std.mem.Allocator, lang: i18n.Lang) void {
    std.debug.print("\n--- {s} ---\n\n", .{p(lang, "Rollback", "ロールバック")});

    // Current tag
    const current: ?[]u8 = release_install.getCurrentTag(alloc);
    defer if (current) |c| alloc.free(c);

    if (current) |cur| {
        std.debug.print("  {s}: {s}\n\n", .{ p(lang, "Current", "現在"), cur });
    }

    const tags = release_install.listInstalledTags(alloc) catch {
        std.debug.print("  {s}\n\n", .{p(lang, "Could not list versions.", "バージョン一覧を取得できません。")});
        return;
    };
    defer {
        for (tags) |t| alloc.free(t);
        alloc.free(tags);
    }

    if (tags.len == 0) {
        std.debug.print("  {s}\n\n", .{p(lang, "No installed versions found.", "インストール済みバージョンが見つかりません。")});
        return;
    }

    for (tags, 1..) |tag, idx| {
        std.debug.print("  {d}) {s}\n", .{ idx, tag });
    }

    std.debug.print("\n  {s} ", .{p(lang, "Select version number:", "バージョン番号を選択:")});

    var sel_buf: [16]u8 = undefined;
    const sel_input = readLine(&sel_buf) orelse return;
    if (sel_input.len == 0) return;

    const sel_num = std.fmt.parseUnsigned(usize, sel_input, 10) catch {
        std.debug.print("  {s}\n\n", .{p(lang, "Invalid selection.", "無効な選択です。")});
        return;
    };

    if (sel_num < 1 or sel_num > tags.len) {
        std.debug.print("  {s}\n\n", .{p(lang, "Out of range.", "範囲外です。")});
        return;
    }

    const selected_tag = tags[sel_num - 1];

    // Check if same as current
    if (current) |cur| {
        if (std.mem.eql(u8, cur, selected_tag)) {
            std.debug.print("  {s}\n\n", .{p(lang, "Already on this version.", "既にこのバージョンです。")});
            return;
        }
    }

    std.debug.print("\n  {s} {s}\n", .{ p(lang, "Rollback to", "ロールバック先:"), selected_tag });
    if (!confirm(lang)) {
        std.debug.print("  {s}\n\n", .{p(lang, "Cancelled.", "キャンセルしました。")});
        return;
    }

    release_install.setCurrentTag(alloc, selected_tag) catch {
        std.debug.print("  {s}\n\n", .{p(lang, "Failed to switch version.", "バージョン切替に失敗しました。")});
        return;
    };

    std.debug.print("  {s}: {s}\n", .{ p(lang, "Switched to", "切替完了"), selected_tag });

    // Restart service
    std.debug.print("  {s}\n", .{p(lang, "Restarting node...", "ノードを再起動中...")});
    runShell(alloc, "systemctl --user restart tsunagi-mainnet.service");
    std.debug.print("  {s}\n\n", .{p(lang, "Done.", "完了。")});
}

fn actionBaeyEvents(alloc: std.mem.Allocator, lang: i18n.Lang) void {
    std.debug.print("\n--- {s} ---\n\n", .{p(lang, "BAEY Audit Events (last 50)", "BAEY 監査イベント（直近50件）")});
    const out = runShellCapture(alloc, "tail -n 50 \"${TSUNAGI_HOME:-~/tsunagi-home-mainnet}/baey/events.log\" 2>/dev/null");
    defer if (out) |o| alloc.free(o);
    if (out) |o| {
        const t = trimShell(o);
        if (t.len > 0) {
            std.debug.print("{s}\n\n", .{t});
        } else {
            std.debug.print("  {s}\n\n", .{p(lang, "(no events)", "（イベントなし）")});
        }
    } else {
        std.debug.print("  {s}\n\n", .{p(lang, "(file not found)", "（ファイルが見つかりません）")});
    }
}

fn actionLocalState(alloc: std.mem.Allocator, lang: i18n.Lang) void {
    std.debug.print("\n--- {s} ---\n\n", .{p(lang, "Local State (/state)", "ローカルステート (/state)")});
    const out = runShellCapture(alloc, "curl -s http://127.0.0.1:9080/state 2>/dev/null | python3 -m json.tool 2>/dev/null | head -n 60");
    defer if (out) |o| alloc.free(o);
    if (out) |o| {
        const t = trimShell(o);
        if (t.len > 0) {
            std.debug.print("{s}\n\n", .{t});
        } else {
            std.debug.print("  {s}\n\n", .{p(lang, "(no response)", "（応答なし）")});
        }
    } else {
        std.debug.print("  {s}\n\n", .{p(lang, "(fetch failed)", "（取得失敗）")});
    }
}

// ── Main loop ────────────────────────────────────────────────────────

pub fn run(alloc: std.mem.Allocator, lang: i18n.Lang) void {
    // Resolve version once at startup
    const ver_raw = runShellCapture(alloc, "cd ~/src/tsunagi-follower && git describe --tags --always 2>/dev/null");
    defer if (ver_raw) |v| alloc.free(v);
    const console_version: []const u8 = if (ver_raw) |v| blk: {
        const t = trimShell(v);
        break :blk if (t.len > 0) t else "unknown";
    } else "unknown";

    while (true) {
        // Print menu
        std.debug.print(
            \\
            \\  +======================================+
            \\  |        TSUNAGI  CONSOLE  {s: <13}|
            \\  +======================================+
            \\
        , .{console_version});

        const items = if (lang == .ja) [_][]const u8{
            "0. 終了",
            "1. ステータス",
            "2. ログ表示（直近80行）",
            "3. ノード再起動",
            "4. メトリクススナップショット",
            "5. TSF アーティファクト実行",
            "6. LMDB バックフィル（キャプチャから）",
            "7. 最新リリースをインストール",
            "8. AutoSwitch タイマー切替",
            "9. TSF タイマー切替",
            "j. 最新リリースにアップグレード",
            "k. インストール済みバージョン一覧",
            "l. ロールバック（以前のバージョンに戻す）",
            "m. ローカルステート表示 (/state)",
            "n. BAEY イベント（直近50件）",
            "p. フットプリントレポート",
        } else [_][]const u8{
            "0. Exit",
            "1. Status",
            "2. Tail Logs (last 80 lines)",
            "3. Restart Node",
            "4. Metrics Snapshot",
            "5. Run TSF Artifact Now",
            "6. Backfill LMDB from captures",
            "7. Install latest release",
            "8. Toggle AutoSwitch timer",
            "9. Toggle TSF timer",
            "j. Upgrade to latest release",
            "k. List installed versions",
            "l. Rollback to previous version",
            "m. Show Local State (/state)",
            "n. BAEY Events (last 50)",
            "p. Footprint Report",
        };

        for (items) |item| {
            std.debug.print("  {s}\n", .{item});
        }

        std.debug.print("\n  > ", .{});

        var buf: [16]u8 = undefined;
        const trimmed = readLine(&buf) orelse return;
        if (trimmed.len == 0) continue;

        // Match single character (digit or letter)
        if (trimmed.len == 1) {
            switch (trimmed[0]) {
                '0' => return,
                '1' => actionStatus(alloc, lang),
                '2' => actionTailLogs(alloc, lang),
                '3' => actionRestart(alloc, lang),
                '4' => actionMetrics(alloc, lang),
                '5' => actionTsfArtifact(alloc, lang),
                '6' => actionBackfill(alloc, lang),
                '7' => actionInstall(alloc, lang),
                '8' => actionToggleTimer(alloc, lang, "autoswitch-apply.timer", "AutoSwitch timer", "AutoSwitch タイマー"),
                '9' => actionToggleTimer(alloc, lang, "tsf-artifact.timer", "TSF timer", "TSF タイマー"),
                'j', 'J' => actionUpgrade(alloc, lang),
                'k', 'K' => actionListVersions(alloc, lang),
                'l', 'L' => actionRollback(alloc, lang),
                'm', 'M' => actionLocalState(alloc, lang),
                'n', 'N' => actionBaeyEvents(alloc, lang),
                'p', 'P' => footprint_cmd.run(alloc),
                else => std.debug.print("  {s}\n", .{p(lang, "Invalid choice.", "無効な選択です。")}),
            }
        } else {
            std.debug.print("  {s}\n", .{p(lang, "Invalid choice.", "無効な選択です。")});
        }
    }
}
