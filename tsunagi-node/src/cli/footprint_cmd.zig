const std = @import("std");
const compat = @import("compat");

// ── Shell helpers (same pattern as console_cmd.zig) ────────────────

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

fn trimShell(raw: []const u8) []const u8 {
    return std.mem.trimEnd(u8, std.mem.trimStart(u8, raw, " \t"), " \t\r\n");
}

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

fn parseProcField(data: []const u8, key: []const u8) []const u8 {
    const pos = std.mem.indexOf(u8, data, key) orelse return "n/a";
    var i = pos + key.len;
    while (i < data.len and (data[i] == ' ' or data[i] == '\t')) : (i += 1) {}
    if (i >= data.len) return "n/a";
    var end = i;
    while (end < data.len and data[end] != '\n' and data[end] != ' ' and data[end] != '\t') : (end += 1) {}
    if (end == i) return "n/a";
    return data[i..end];
}

// ── Main entry ─────────────────────────────────────────────────────

pub fn run(alloc: std.mem.Allocator) void {
    var stderr_file = compat.fs.File.stderr();
    const w = stderr_file.writer();

    // Version
    const ver_raw = runShellCapture(alloc, "cd ~/src/tsunagi-follower && git describe --tags --always 2>/dev/null");
    defer if (ver_raw) |v| alloc.free(v);
    const version: []const u8 = if (ver_raw) |v| blk: {
        const t = trimShell(v);
        break :blk if (t.len > 0) t else "unknown";
    } else "unknown";

    // Service status
    const svc_raw = runShellCapture(alloc, "systemctl --user is-active tsunagi-mainnet.service 2>/dev/null");
    defer if (svc_raw) |v| alloc.free(v);
    const svc_state: []const u8 = if (svc_raw) |v| blk: {
        const t = trimShell(v);
        break :blk if (t.len > 0) t else "unknown";
    } else "unknown";

    // PID
    const pid_raw = runShellCapture(alloc, "pgrep -n tsunagi-node 2>/dev/null");
    defer if (pid_raw) |v| alloc.free(v);
    const pid_str: []const u8 = if (pid_raw) |v| blk: {
        const t = trimShell(v);
        break :blk if (t.len > 0) t else "n/a";
    } else "n/a";

    // /proc/<pid>/status → RSS, VmSize, Threads
    var rss_str: []const u8 = "n/a";
    var vmsize_str: []const u8 = "n/a";
    var threads_str: []const u8 = "n/a";
    var rss_mb_buf: [32]u8 = undefined;
    var vm_mb_buf: [32]u8 = undefined;

    const proc_raw = if (!std.mem.eql(u8, pid_str, "n/a")) blk: {
        const cmd = std.fmt.allocPrint(alloc, "cat /proc/{s}/status 2>/dev/null", .{pid_str}) catch break :blk @as(?[]u8, null);
        defer alloc.free(cmd);
        break :blk runShellCapture(alloc, cmd);
    } else null;
    defer if (proc_raw) |v| alloc.free(v);

    if (proc_raw) |data| {
        const rss_kb_str = parseProcField(data, "VmRSS:");
        const rss_kb = std.fmt.parseUnsigned(u64, rss_kb_str, 10) catch 0;
        if (rss_kb > 0) {
            rss_str = std.fmt.bufPrint(&rss_mb_buf, "{d} MB ({d} kB)", .{ rss_kb / 1024, rss_kb }) catch "n/a";
        }

        const vm_kb_str = parseProcField(data, "VmSize:");
        const vm_kb = std.fmt.parseUnsigned(u64, vm_kb_str, 10) catch 0;
        if (vm_kb > 0) {
            vmsize_str = std.fmt.bufPrint(&vm_mb_buf, "{d} MB ({d} kB)", .{ vm_kb / 1024, vm_kb }) catch "n/a";
        }

        threads_str = parseProcField(data, "Threads:");
    }

    // FD count: ls /proc/<pid>/fd | wc -l
    var fd_str: []const u8 = "n/a";
    var fd_buf: [32]u8 = undefined;
    const fd_raw = if (!std.mem.eql(u8, pid_str, "n/a")) blk: {
        const cmd = std.fmt.allocPrint(alloc, "ls /proc/{s}/fd 2>/dev/null | wc -l", .{pid_str}) catch break :blk @as(?[]u8, null);
        defer alloc.free(cmd);
        break :blk runShellCapture(alloc, cmd);
    } else null;
    defer if (fd_raw) |v| alloc.free(v);

    if (fd_raw) |v| {
        const t = trimShell(v);
        if (t.len > 0) {
            fd_str = std.fmt.bufPrint(&fd_buf, "{s}", .{t}) catch "n/a";
        }
    }

    // Metrics from running node
    const metrics_raw = runShellCapture(alloc, "curl -s http://127.0.0.1:9080/metrics 2>/dev/null");
    defer if (metrics_raw) |v| alloc.free(v);
    const raw: []const u8 = metrics_raw orelse "";
    const has_metrics = raw.len > 0;

    // Metric values
    const v_slot = findMetricValue(raw, "tsunagi_slot ") orelse "n/a";
    const v_block = findMetricValue(raw, "tsunagi_block ") orelse "n/a";
    const v_utxo = findMetricValue(raw, "tsunagi_utxo_count ") orelse "n/a";
    const v_ratio = findMetricValue(raw, "tsunagi_lmdb_truth_ratio ") orelse "n/a";
    const v_missing_ema = findMetricValue(raw, "tsunagi_ledger_missing_inputs_ema ") orelse "n/a";
    const v_cov_ratio = findMetricValue(raw, "tsunagi_ledger_value_check_ratio ") orelse "n/a";
    const v_auto_strict_raw = findMetricValue(raw, "tsunagi_ledger_auto_strict_enabled ") orelse "0";
    const auto_strict_label: []const u8 = if (std.mem.eql(u8, v_auto_strict_raw, "1")) "ON" else "OFF";

    // LMDB
    const v_map_bytes = findMetricValue(raw, "tsunagi_lmdb_map_size_bytes ") orelse "n/a";
    const v_map_gb = findMetricValue(raw, "tsunagi_lmdb_map_gb_effective ") orelse "n/a";
    const v_map_ok = findMetricValue(raw, "tsunagi_lmdb_map_gb_raw_parse_ok ") orelse "n/a";

    // Backfill
    const v_bf_runs = findMetricValue(raw, "tsunagi_backfill_runs_total ") orelse "0";
    const v_bf_blocks = findMetricValue(raw, "tsunagi_backfill_blocks_total ") orelse "0";
    const v_bf_errors = findMetricValue(raw, "tsunagi_backfill_errors_total ") orelse "0";

    // Capture
    const v_cap_seg_count = findMetricValue(raw, "tsunagi_capture_segments_count ") orelse "0";
    const v_cap_main_raw = findMetricValue(raw, "tsunagi_capture_mainnet_bin_bytes ") orelse "0";
    const cap_main_bytes = std.fmt.parseUnsigned(u64, v_cap_main_raw, 10) catch 0;
    var cap_buf: [32]u8 = undefined;
    const cap_mb_str: []const u8 = std.fmt.bufPrint(&cap_buf, "{d}MB", .{cap_main_bytes / (1024 * 1024)}) catch "n/a";
    const v_cap_rot_mb = findMetricValue(raw, "tsunagi_capture_rotate_mb ") orelse "n/a";

    // Gaps
    const v_gap_keys = findMetricValue(raw, "tsunagi_gap_missing_keys ") orelse "0";
    const v_gap_cap = findMetricValue(raw, "tsunagi_gap_keys_cap ") orelse "5000";
    const v_gap_repeat = findMetricValue(raw, "tsunagi_gap_repeat_ratio ") orelse "0";
    const v_gap_ls_items = findMetricValue(raw, "tsunagi_gap_last_seen_items ") orelse "0";
    const v_gap_oldest = findMetricValue(raw, "tsunagi_gap_oldest_last_seen_age_seconds ") orelse "0";

    // Authority
    const v_auth_conf = findMetricValue(raw, "tsunagi_authority_confidence ") orelse "n/a";
    const v_auth_fin = findMetricValue(raw, "tsunagi_authority_finality_score ") orelse "n/a";

    // Consensus
    const v_health = findMetricValue(raw, "tsunagi_consensus_health_score ") orelse "n/a";
    const v_tip_fresh = findMetricValue(raw, "tsunagi_consensus_tip_fresh_seconds ") orelse "n/a";

    // BAEY policy tick
    const pt_raw = runShellCapture(alloc, "grep policy_tick \"${TSUNAGI_HOME:-~/tsunagi-home-mainnet}/baey/events.log\" 2>/dev/null | tail -n 1");
    defer if (pt_raw) |pr| alloc.free(pr);
    const pt_line: []const u8 = if (pt_raw) |pr| trimShell(pr) else "";
    const pt_score = if (pt_line.len > 10) extractJsonStr(pt_line, "\"score\"") else "n/a";
    const pt_action = if (pt_line.len > 10) extractJsonStr(pt_line, "\"action\"") else "n/a";

    // Truth/convergence
    const truth_f = std.fmt.parseFloat(f64, v_ratio) catch 0.0;
    const miss_u = std.fmt.parseUnsigned(u64, v_missing_ema, 10) catch 999;
    const convergence_label: []const u8 = if (truth_f >= 0.99 and std.mem.eql(u8, v_auto_strict_raw, "1") and miss_u == 0)
        "READY"
    else if (truth_f > 0.0 or (std.fmt.parseUnsigned(u64, v_bf_runs, 10) catch 0) > 0)
        "CONVERGING"
    else
        "INCOMPLETE";

    // ── Render ──────────────────────────────────────────────────────

    w.print(
        \\
        \\  ╔══════════════════════════════════════╗
        \\  ║  TSUNAGI FOOTPRINT                   ║
        \\  ╚══════════════════════════════════════╝
        \\
        \\  Version:     {s}
        \\  Service:     {s}
        \\  PID:         {s}
        \\
        \\  ── Process ─────────────────────────────
        \\  RSS:         {s}
        \\  VmSize:      {s}
        \\  Threads:     {s}
        \\  FDs:         {s}
        \\
        \\  ── LMDB ───────────────────────────────
        \\  Map size:    {s} GB (bytes={s} parsed_ok={s})
        \\
    , .{
        version,
        svc_state,
        pid_str,
        rss_str,
        vmsize_str,
        threads_str,
        fd_str,
        v_map_gb, v_map_bytes, v_map_ok,
    }) catch {};

    if (has_metrics) {
        w.print(
            \\  ── Chain ──────────────────────────────
            \\  Slot:        {s}
            \\  Block:       {s}
            \\  UTxO:        {s}
            \\  Health:      {s}  tip_fresh={s}s
            \\  Authority:   conf={s} finality={s}
            \\
            \\  ── Convergence ────────────────────────
            \\  Truth:       {s}  auto_strict={s}
            \\  Ledger:      coverage={s} missing_ema={s}
            \\  Backfill:    runs={s} blocks={s} errors={s}
            \\  Capture:     mainnet={s} seg={s} rotate={s}MB
            \\  Status:      [ {s} ]
            \\
            \\  ── Gaps ───────────────────────────────
            \\  Keys:        {s}/{s}
            \\  Repeat:      {s}
            \\  Last seen:   {s}  oldest={s}s
            \\
            \\  ── BAEY ───────────────────────────────
            \\  Score:       {s}
            \\  Action:      {s}
            \\
        , .{
            v_slot,
            v_block,
            v_utxo,
            v_health,          v_tip_fresh,
            v_auth_conf,       v_auth_fin,
            v_ratio,           auto_strict_label,
            v_cov_ratio,       v_missing_ema,
            v_bf_runs,         v_bf_blocks, v_bf_errors,
            cap_mb_str,        v_cap_seg_count, v_cap_rot_mb,
            convergence_label,
            v_gap_keys,        v_gap_cap,
            v_gap_repeat,
            v_gap_ls_items,    v_gap_oldest,
            pt_score,
            pt_action,
        }) catch {};
        // Metrics health
        const v_up = findMetricValue(raw, "tsunagi_metrics_up ") orelse "n/a";
        const v_start_ok = findMetricValue(raw, "tsunagi_metrics_start_success_total ") orelse "n/a";
        w.print(
            \\  ── Metrics Health ─────────────────────
            \\  Up:          {s}  start_ok={s}
            \\
        , .{ v_up, v_start_ok }) catch {};

        // Producer eligibility test
        const v_et_en = findMetricValue(raw, "tsunagi_producer_elig_test_enabled ") orelse "0";
        const v_et_slot = findMetricValue(raw, "tsunagi_producer_elig_test_slot_in_epoch ") orelse "0";
        const v_sie = findMetricValue(raw, "tsunagi_producer_slot_in_epoch_last ") orelse "0";
        const v_elig = findMetricValue(raw, "tsunagi_producer_leader_eligible_last ") orelse "0";
        const v_prob = findMetricValue(raw, "tsunagi_producer_leader_probability_x1e6 ") orelse "0";
        const v_rc = findMetricValue(raw, "tsunagi_producer_leader_reason_code_last ") orelse "0";
        const v_epoch = findMetricValue(raw, "tsunagi_producer_epoch_last ") orelse "0";

        w.print(
            \\  ── Producer ───────────────────────────
            \\  Epoch:       {s}  sie={s}  eligible={s}
            \\  Prob:        {s}  reason={s}
        , .{ v_epoch, v_sie, v_elig, v_prob, v_rc }) catch {};

        if (std.mem.eql(u8, v_et_en, "1")) {
            const sie_u = std.fmt.parseUnsigned(u64, v_sie, 10) catch 0;
            const target_u = std.fmt.parseUnsigned(u64, v_et_slot, 10) catch 0;
            const eta_slots: u64 = if (target_u > sie_u) target_u - sie_u else (432000 - sie_u) + target_u;
            const eta_h = eta_slots / 3600;
            const eta_m = (eta_slots % 3600) / 60;
            w.print(
                \\
                \\  EligTest:    ON  target={s}  ETA ~{d}h{d:0>2}m ({d} slots)
            , .{ v_et_slot, eta_h, eta_m, eta_slots }) catch {};
        } else {
            w.print(
                \\
                \\  EligTest:    OFF
            , .{}) catch {};
        }

        // BAEY leader guard
        const pt_lg = if (pt_line.len > 10) extractJsonStr(pt_line, "\"leader_guard\"") else "n/a";
        const pt_lg_reason = if (pt_line.len > 10) extractJsonStr(pt_line, "\"lg_reason\"") else "n/a";
        const pt_computed = if (pt_line.len > 10) extractJsonStr(pt_line, "\"computed_action\"") else "n/a";
        const pt_final = if (pt_line.len > 10) extractJsonStr(pt_line, "\"final_action\"") else "n/a";
        w.print(
            \\
            \\
            \\  ── BAEY Guardian ──────────────────────
            \\  Score:       {s}  action={s}
            \\  Guard:       lg={s} lg_reason={s}
            \\  Actions:     computed={s} final={s}
            \\
        , .{ pt_score, pt_action, pt_lg, pt_lg_reason, pt_computed, pt_final }) catch {};

        // One-liner
        w.print(
            \\  ── One-Liner ──────────────────────────
            \\  FOOTPRINT: ver={s} rss={s} lmdb_gb={s} slot={s} truth={s} gaps={s} baey={s} producer={s}/{s}
            \\
        , .{
            version, rss_str, v_map_gb, v_slot, v_ratio,
            v_gap_keys, pt_score, v_elig, v_rc,
        }) catch {};
    } else {
        w.print(
            \\  ── Metrics ────────────────────────────
            \\  (not available — is the node running with TSUNAGI_METRICS=1?)
            \\
        , .{}) catch {};
    }
}
