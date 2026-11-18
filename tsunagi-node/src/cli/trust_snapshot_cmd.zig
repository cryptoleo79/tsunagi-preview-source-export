const std = @import("std");
const compat = @import("compat");
const Ed25519 = std.crypto.sign.Ed25519;
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

// ── trust-snapshot: generate a signed verifiable node state snapshot ──
// ── trust-verify:  verify a trust snapshot against a public key     ──

pub fn runSnapshot(alloc: std.mem.Allocator, args_it: anytype) !void {
    var out_path: ?[]const u8 = null;
    var key_path: ?[]const u8 = null;
    var port: u16 = 9081;
    var append_history: bool = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--out")) {
            out_path = args_it.next();
        } else if (std.mem.eql(u8, arg, "--key")) {
            key_path = args_it.next();
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (args_it.next()) |p| port = std.fmt.parseInt(u16, p, 10) catch 9081;
        } else if (std.mem.eql(u8, arg, "--append-history")) {
            append_history = true;
        }
    }

    // Fetch /state
    const state_json = fetchState(alloc, port) orelse {
        std.debug.print("trust-snapshot: cannot reach /state on port {d}\n", .{port});
        return error.FetchFailed;
    };
    defer alloc.free(state_json);

    // Extract fields
    const unix: u64 = @intCast(@max(0, compat.timestamp()));
    const tip_slot = jU64(state_json, "\"slot\"") orelse 0;
    const tip_block = jU64(state_json, "\"block\"") orelse 0;
    const health_score = jU64(state_json, "\"health_score\"") orelse 100;
    const health_band = jStr(state_json, "\"health_band\"") orelse "GREEN";
    const rt_state = jStr(state_json, "\"rt_state\"") orelse "HEALTHY";
    const health_primary = jStr(state_json, "\"health_primary\"") orelse "nominal";
    const gate_ready = jU64(state_json, "\"gate_ready\"") orelse 0;

    // Insight: find current block inside insight section
    const ins_blocks = jU64(state_json, "\"blocks_in_window\"") orelse
        (if (std.mem.indexOf(u8, state_json, "\"insight\"")) |_| jU64(state_json, "\"blocks\"") else null) orelse 0;

    // Build insight from /state insight.current
    var ins_txs: u64 = 0;
    var ins_fees: u64 = 0;
    var ins_ada: u64 = 0;
    if (std.mem.indexOf(u8, state_json, "\"current\"")) |cur_pos| {
        const sub = state_json[cur_pos..];
        ins_txs = jU64(sub, "\"txs\"") orelse 0;
        ins_fees = jU64(sub, "\"fees\"") orelse 0;
        ins_ada = jU64(sub, "\"ada_moved\"") orelse 0;
    }

    // Convergence
    var truth_ratio_str: []const u8 = "0.000000";
    if (std.mem.indexOf(u8, state_json, "\"convergence\"")) |conv_pos| {
        const sub = state_json[conv_pos..];
        truth_ratio_str = jStr(sub, "\"truth_ratio\"") orelse "0.000000";
    }

    // Build canonical body (deterministic key order, no whitespace)
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = compat.listWriter(&buf);

    try w.print(
        \\{{"version":1,"unix":{d},"chain_family":"cardano","network":"preview","tip":{{"slot":{d},"block":{d}}},"health":{{"score":{d},"band":"{s}","state":"{s}","primary":"{s}"}},"insight":{{"blocks":{d},"txs":{d},"fees_lovelace":{d},"ada_moved_lovelace":{d}}},"convergence":{{"truth_ratio":"{s}","gate_ready":{d}}}}}
    , .{
        unix, tip_slot, tip_block,
        health_score, health_band, rt_state, health_primary,
        ins_blocks, ins_txs, ins_fees, ins_ada,
        truth_ratio_str, gate_ready,
    });

    const canonical = buf.items;

    // Compute digest
    var digest: [32]u8 = undefined;
    Blake2b256.hash(canonical, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);

    // Sign
    const seed = readKey32(alloc, key_path) catch |err| {
        std.debug.print("trust-snapshot: cannot read signing key: {s}\n", .{@errorName(err)});
        // Output unsigned snapshot
        try outputSnapshot(alloc, canonical, &digest_hex, null, null, out_path);
        return;
    };

    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const sig = try kp.sign(&digest, null);
    const sig_hex = std.fmt.bytesToHex(sig.toBytes(), .lower);
    const pub_hex = std.fmt.bytesToHex(kp.public_key.toBytes(), .lower);

    try outputSnapshot(alloc, canonical, &digest_hex, &sig_hex, &pub_hex, out_path);

    std.debug.print("trust-snapshot: slot={d} block={d} health={d} digest={x}\n", .{
        tip_slot, tip_block, health_score, digest[0..8],
    });

    // Append to history if requested
    if (append_history) {
        appendHistory(alloc, canonical, &digest_hex, &sig_hex, &pub_hex) catch |err| {
            std.debug.print("trust-snapshot: history append failed: {s}\n", .{@errorName(err)});
        };
    }
}

fn outputSnapshot(alloc: std.mem.Allocator, canonical: []const u8, digest_hex: []const u8, sig_hex: ?[]const u8, pub_hex: ?[]const u8, out_path: ?[]const u8) !void {
    // Build final JSON: canonical body minus closing }, then append digest/sig/pubkey
    // canonical ends with }. Strip it, append new fields, close.
    var out = std.array_list.Managed(u8).init(alloc);
    defer out.deinit();
    const ow = compat.listWriter(&out);

    // Strip trailing }
    if (canonical.len > 0 and canonical[canonical.len - 1] == '}') {
        try ow.writeAll(canonical[0 .. canonical.len - 1]);
    } else {
        try ow.writeAll(canonical);
    }

    try ow.print(",\"digest\":\"{s}\"", .{digest_hex});
    if (sig_hex) |s| try ow.print(",\"signature\":\"{s}\"", .{s});
    if (pub_hex) |p| try ow.print(",\"pubkey\":\"{s}\"", .{p});
    try ow.writeByte('}');
    try ow.writeByte('\n');

    if (out_path) |path| {
        var f = try compat.fs.cwd().createFile(path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(out.items);
        std.debug.print("trust-snapshot: written to {s}\n", .{path});
    } else {
        const stdout = compat.fs.stdoutWriter();
        try stdout.writeAll(out.items);
    }
}

// ── trust-verify ──

pub fn runVerify(alloc: std.mem.Allocator, args_it: anytype) !void {
    var file_path: ?[]const u8 = null;
    var pubkey_hex: ?[]const u8 = null;
    var pubkey_file: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--file")) {
            file_path = args_it.next();
        } else if (std.mem.eql(u8, arg, "--pubkey")) {
            pubkey_hex = args_it.next();
        } else if (std.mem.eql(u8, arg, "--pubkey-file")) {
            pubkey_file = args_it.next();
        }
    }

    const fp = file_path orelse {
        std.debug.print("trust-verify: --file required\n", .{});
        return error.InvalidArgs;
    };

    const raw = blk: {
        var f = compat.fs.cwd().openFile(fp, .{}) catch |err| {
            std.debug.print("trust-verify: cannot open {s}: {s}\n", .{ fp, @errorName(err) });
            return err;
        };
        defer f.close();
        break :blk try f.readToEndAlloc(alloc, 1024 * 1024);
    };
    defer alloc.free(raw);

    // Extract digest, signature, pubkey from the JSON
    const file_digest_hex = jStr(raw, "\"digest\"") orelse {
        std.debug.print("trust-verify: no digest field in snapshot\n", .{});
        return error.MissingDigest;
    };
    const file_sig_hex = jStr(raw, "\"signature\"") orelse {
        std.debug.print("trust-verify: no signature field in snapshot\n", .{});
        return error.MissingSignature;
    };

    // Reconstruct canonical body: everything before ,"digest"
    const digest_pos = std.mem.indexOf(u8, raw, ",\"digest\"") orelse {
        std.debug.print("trust-verify: cannot find digest boundary\n", .{});
        return error.MalformedSnapshot;
    };
    var canonical = std.array_list.Managed(u8).init(alloc);
    defer canonical.deinit();
    try canonical.appendSlice(raw[0..digest_pos]);
    try canonical.append('}');

    // Verify digest
    var computed_digest: [32]u8 = undefined;
    Blake2b256.hash(canonical.items, &computed_digest, .{});
    const computed_hex = std.fmt.bytesToHex(computed_digest, .lower);

    if (!std.mem.eql(u8, &computed_hex, file_digest_hex)) {
        std.debug.print("trust-verify: DIGEST MISMATCH\n  expected: {s}\n  computed: {s}\n", .{ file_digest_hex, &computed_hex });
        std.process.exit(1);
    }

    // Parse signature
    var sig_bytes: [64]u8 = undefined;
    _ = std.fmt.hexToBytes(&sig_bytes, file_sig_hex) catch {
        std.debug.print("trust-verify: invalid signature hex\n", .{});
        return error.InvalidSignature;
    };

    // Get pubkey
    var pk_bytes: [32]u8 = undefined;
    if (pubkey_hex) |hex| {
        _ = std.fmt.hexToBytes(&pk_bytes, hex) catch return error.InvalidPubkey;
    } else if (pubkey_file) |pf| {
        pk_bytes = readKey32(alloc, pf) catch return error.InvalidPubkey;
    } else if (jStr(raw, "\"pubkey\"")) |embedded_hex| {
        _ = std.fmt.hexToBytes(&pk_bytes, embedded_hex) catch return error.InvalidPubkey;
    } else {
        // Try default key
        pk_bytes = readKey32(alloc, null) catch {
            std.debug.print("trust-verify: no pubkey provided and no default key found\n", .{});
            return error.NoPubkey;
        };
    }

    const pk = Ed25519.PublicKey.fromBytes(pk_bytes) catch {
        std.debug.print("trust-verify: invalid public key\n", .{});
        return error.InvalidPubkey;
    };
    const sig = Ed25519.Signature.fromBytes(sig_bytes);

    sig.verify(&computed_digest, pk) catch {
        std.debug.print("trust-verify: SIGNATURE INVALID\n", .{});
        std.process.exit(1);
    };

    std.debug.print("trust-verify: VALID\n", .{});
    std.debug.print("  digest:  {s}\n", .{file_digest_hex});
    const slot = jU64(raw, "\"slot\"") orelse 0;
    const block = jU64(raw, "\"block\"") orelse 0;
    const health = jU64(raw, "\"score\"") orelse 0;
    std.debug.print("  slot:    {d}\n  block:   {d}\n  health:  {d}\n", .{ slot, block, health });
}

// ── History ──

const HISTORY_MAX_LINES: usize = 288; // 24h at 5-min intervals

fn appendHistory(alloc: std.mem.Allocator, canonical: []const u8, digest_hex: []const u8, sig_hex: []const u8, pub_hex: []const u8) !void {
    const home = try compat.getEnvVarOwned(alloc, "TSUNAGI_HOME");
    defer alloc.free(home);
    const dir = try std.fmt.allocPrint(alloc, "{s}/trust", .{home});
    defer alloc.free(dir);
    compat.fs.cwd().makeDir(dir) catch |err| if (err != error.PathAlreadyExists) return err;

    const path = try std.fmt.allocPrint(alloc, "{s}/history.ndjson", .{dir});
    defer alloc.free(path);

    // Build the single-line JSON (same as outputSnapshot but no trailing newline yet)
    var line = std.array_list.Managed(u8).init(alloc);
    defer line.deinit();
    const lw = compat.listWriter(&line);
    if (canonical.len > 0 and canonical[canonical.len - 1] == '}') {
        try lw.writeAll(canonical[0 .. canonical.len - 1]);
    } else {
        try lw.writeAll(canonical);
    }
    try lw.print(",\"digest\":\"{s}\",\"signature\":\"{s}\",\"pubkey\":\"{s}\"}}\n", .{ digest_hex, sig_hex, pub_hex });

    // Append
    {
        var f = compat.fs.cwd().openFile(path, .{ .mode = .write_only }) catch |err| {
            if (err == error.FileNotFound) {
                var nf = try compat.fs.cwd().createFile(path, .{});
                try nf.writeAll(line.items);
                nf.close();
                std.debug.print("trust-snapshot: history created ({s})\n", .{path});
                return;
            }
            return err;
        };
        defer f.close();
        try f.seekFromEnd(0);
        try f.writeAll(line.items);
    }

    // Prune if needed
    pruneHistory(alloc, path) catch {};
    std.debug.print("trust-snapshot: appended to history\n", .{});
}

fn pruneHistory(alloc: std.mem.Allocator, path: []const u8) !void {
    var f = try compat.fs.cwd().openFile(path, .{});
    defer f.close();
    const data = try f.readToEndAlloc(alloc, 4 * 1024 * 1024); // max 4MB
    defer alloc.free(data);

    // Count lines
    var line_count: usize = 0;
    for (data) |c| {
        if (c == '\n') line_count += 1;
    }

    if (line_count <= HISTORY_MAX_LINES) return;

    // Keep only the last HISTORY_MAX_LINES lines
    const skip = line_count - HISTORY_MAX_LINES;
    var skipped: usize = 0;
    var pos: usize = 0;
    while (skipped < skip and pos < data.len) {
        if (data[pos] == '\n') skipped += 1;
        pos += 1;
    }

    // Write truncated content
    const tmp = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp);
    {
        var wf = try compat.fs.cwd().createFile(tmp, .{ .truncate = true });
        defer wf.close();
        try wf.writeAll(data[pos..]);
    }
    try compat.fs.cwd().rename(tmp, path);
    std.debug.print("trust-snapshot: pruned history to {d} lines\n", .{HISTORY_MAX_LINES});
}

// ── Reputation ──

pub fn runReputation(alloc: std.mem.Allocator, args_it: anytype) !void {
    var out_path: ?[]const u8 = null;
    var key_path: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--out")) {
            out_path = args_it.next();
        } else if (std.mem.eql(u8, arg, "--key")) {
            key_path = args_it.next();
        }
    }

    // Read history
    const home = try compat.getEnvVarOwned(alloc, "TSUNAGI_HOME");
    defer alloc.free(home);
    const history_path = try std.fmt.allocPrint(alloc, "{s}/trust/history.ndjson", .{home});
    defer alloc.free(history_path);

    var hf = compat.fs.cwd().openFile(history_path, .{}) catch |err| {
        std.debug.print("trust-reputation: cannot open history: {s}\n", .{@errorName(err)});
        return err;
    };
    defer hf.close();
    const data = try hf.readToEndAlloc(alloc, 4 * 1024 * 1024);
    defer alloc.free(data);

    // Parse lines
    var total: u64 = 0;
    var health_sum: u64 = 0;
    var healthy_count: u64 = 0;
    var degraded_events: u64 = 0;
    var was_healthy: bool = true;
    var first_unix: u64 = 0;
    var last_unix: u64 = 0;

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len < 10) continue; // skip empty lines
        const h = jU64(line, "\"score\"") orelse continue;
        const u = jU64(line, "\"unix\"") orelse continue;
        const state = jStr(line, "\"state\"") orelse "HEALTHY";

        health_sum += h;
        total += 1;
        if (first_unix == 0) first_unix = u;
        last_unix = u;

        const is_healthy = std.mem.eql(u8, state, "HEALTHY");
        if (is_healthy) {
            healthy_count += 1;
        }
        if (was_healthy and !is_healthy) {
            degraded_events += 1;
        }
        was_healthy = is_healthy;
    }

    if (total == 0) {
        std.debug.print("trust-reputation: no valid snapshots in history\n", .{});
        return error.EmptyHistory;
    }

    // Compute factors
    const health_avg: u64 = health_sum / total;
    const time_span = if (last_unix > first_unix) last_unix - first_unix else 300;
    const expected = time_span / 300 + 1;
    const uptime_x1000: u64 = @min(1000, (total * 1000) / expected);
    const stability_x1000: u64 = (healthy_count * 1000) / total;
    // Recovery factor: 1.0 if no degradation, else scale by ratio of healthy to total
    const recovery_x1000: u64 = if (degraded_events == 0) 1000 else @min(1000, (healthy_count * 1000) / total);

    // Weighted reputation: 40% health + 25% uptime + 20% stability + 15% recovery
    const rep_score: u64 = (health_avg * 40 + (uptime_x1000 / 10) * 25 + (stability_x1000 / 10) * 20 + (recovery_x1000 / 10) * 15) / 100;
    const rep_clamped: u64 = @min(100, rep_score);

    const window_hours: u64 = time_span / 3600;

    // Build canonical JSON
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = compat.listWriter(&buf);
    try w.print(
        \\{{"version":1,"unix":{d},"chain_family":"cardano","network":"preview","reputation_score":{d},"window_hours":{d},"snapshots_expected":{d},"snapshots_present":{d},"health_average":{d},"uptime_ratio_x1000":{d},"stability_ratio_x1000":{d},"degraded_events":{d},"recovery_factor_x1000":{d}}}
    , .{
        @as(u64, @intCast(@max(0, compat.timestamp()))),
        rep_clamped, window_hours, expected, total,
        health_avg, uptime_x1000, stability_x1000,
        degraded_events, recovery_x1000,
    });

    const canonical = buf.items;

    // Digest + sign
    var digest: [32]u8 = undefined;
    Blake2b256.hash(canonical, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);

    const seed = readKey32(alloc, key_path) catch |err| {
        std.debug.print("trust-reputation: signing key unavailable: {s}\n", .{@errorName(err)});
        try outputSnapshot(alloc, canonical, &digest_hex, null, null, out_path);
        return;
    };

    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const sig = try kp.sign(&digest, null);
    const sig_hex = std.fmt.bytesToHex(sig.toBytes(), .lower);
    const pub_hex = std.fmt.bytesToHex(kp.public_key.toBytes(), .lower);

    try outputSnapshot(alloc, canonical, &digest_hex, &sig_hex, &pub_hex, out_path);

    // Also write to $TSUNAGI_HOME/trust/reputation.json for /state pickup
    {
        const rep_path = std.fmt.allocPrint(alloc, "{s}/trust/reputation.json", .{home}) catch return;
        defer alloc.free(rep_path);
        const tmp_path = std.fmt.allocPrint(alloc, "{s}/trust/reputation.json.tmp", .{home}) catch return;
        defer alloc.free(tmp_path);

        var rf = compat.fs.cwd().createFile(tmp_path, .{ .truncate = true }) catch return;
        outputSnapshot(alloc, canonical, &digest_hex, &sig_hex, &pub_hex, null) catch {};
        // Actually write to file directly
        rf.close();
        // Re-do via outputSnapshot to file
        outputSnapshot(alloc, canonical, &digest_hex, &sig_hex, &pub_hex, rep_path) catch return;
        // rep_path already written by outputSnapshot
    }

    std.debug.print("trust-reputation: score={d} health_avg={d} uptime={d}/1000 stability={d}/1000 snapshots={d}/{d}\n", .{
        rep_clamped, health_avg, uptime_x1000, stability_x1000, total, expected,
    });
}

// ── Cross-Node Trust Exchange ──

const PEER_STALE_SECONDS: u64 = 600; // exclude peers older than 10 min

pub fn runExchange(alloc: std.mem.Allocator, args_it: anytype) !void {
    var key_path: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--key")) {
            key_path = args_it.next();
        }
    }

    const home = try compat.getEnvVarOwned(alloc, "TSUNAGI_HOME");
    defer alloc.free(home);
    const trust_dir = try std.fmt.allocPrint(alloc, "{s}/trust", .{home});
    defer alloc.free(trust_dir);
    compat.fs.cwd().makeDir(trust_dir) catch |err| if (err != error.PathAlreadyExists) return err;

    const peer_rep_dir = try std.fmt.allocPrint(alloc, "{s}/peer_reputations", .{trust_dir});
    defer alloc.free(peer_rep_dir);
    compat.fs.cwd().makeDir(peer_rep_dir) catch |err| if (err != error.PathAlreadyExists) return err;

    // Read peers.json
    const peers_path = try std.fmt.allocPrint(alloc, "{s}/peers.json", .{trust_dir});
    defer alloc.free(peers_path);
    const peers_raw = blk: {
        var f = compat.fs.cwd().openFile(peers_path, .{}) catch |err| {
            std.debug.print("trust-exchange: cannot open {s}: {s}\n", .{ peers_path, @errorName(err) });
            return err;
        };
        defer f.close();
        break :blk try f.readToEndAlloc(alloc, 256 * 1024);
    };
    defer alloc.free(peers_raw);

    // Parse peers: find each "endpoint" and "pubkey" pair.
    // Simple: scan for "endpoint":"..." and "pubkey":"..." blocks.
    const now_unix: u64 = @intCast(@max(0, compat.timestamp()));
    var peers_verified: u32 = 0;
    var peers_total: u32 = 0;
    var rep_sum: u64 = 0;
    var health_sum: u64 = 0;
    var valid_count: u32 = 0;

    // Collect peer results for trust_network.json
    var peer_results = std.array_list.Managed(u8).init(alloc);
    defer peer_results.deinit();

    // Iterate peers by finding "endpoint" occurrences
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, peers_raw, search_pos, "\"endpoint\"")) |ep_pos| {
        search_pos = ep_pos + 10;
        peers_total += 1;

        const endpoint = jStr(peers_raw[ep_pos..], "\"endpoint\"") orelse continue;
        const pubkey_hex = jStr(peers_raw[ep_pos..], "\"pubkey\"") orelse continue;
        const name = jStr(peers_raw[ep_pos..], "\"name\"") orelse "unknown";

        std.debug.print("trust-exchange: fetching peer '{s}' from {s}\n", .{ name, endpoint });

        // Fetch peer reputation via HTTP
        const rep_data = fetchHttpUrl(alloc, endpoint) orelse {
            std.debug.print("trust-exchange: fetch failed for '{s}'\n", .{name});
            if (peers_total > 1 or peer_results.items.len > 0) try compat.listWriter(&peer_results).writeByte(',');
            try compat.listWriter(&peer_results).print(
                \\{{"name":"{s}","pubkey":"{s}","verified":false,"reason":"fetch_failed"}}
            , .{ name, pubkey_hex[0..@min(16, pubkey_hex.len)] });
            continue;
        };
        defer alloc.free(rep_data);

        // Verify signature against known pubkey
        const file_digest_hex = jStr(rep_data, "\"digest\"") orelse {
            std.debug.print("trust-exchange: no digest in peer '{s}' response\n", .{name});
            continue;
        };
        const file_sig_hex = jStr(rep_data, "\"signature\"") orelse {
            std.debug.print("trust-exchange: no signature in peer '{s}' response\n", .{name});
            continue;
        };

        // Reconstruct canonical body
        const digest_boundary = std.mem.indexOf(u8, rep_data, ",\"digest\"") orelse continue;
        var canonical_buf = std.array_list.Managed(u8).init(alloc);
        defer canonical_buf.deinit();
        try canonical_buf.appendSlice(rep_data[0..digest_boundary]);
        try canonical_buf.append('}');

        var computed_digest: [32]u8 = undefined;
        Blake2b256.hash(canonical_buf.items, &computed_digest, .{});
        const computed_hex = std.fmt.bytesToHex(computed_digest, .lower);

        if (!std.mem.eql(u8, &computed_hex, file_digest_hex)) {
            std.debug.print("trust-exchange: DIGEST MISMATCH for peer '{s}'\n", .{name});
            continue;
        }

        // Verify Ed25519 signature with the KNOWN pubkey (not embedded)
        var pk_bytes: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&pk_bytes, pubkey_hex) catch continue;
        var sig_bytes: [64]u8 = undefined;
        _ = std.fmt.hexToBytes(&sig_bytes, file_sig_hex) catch continue;

        const pk = Ed25519.PublicKey.fromBytes(pk_bytes) catch continue;
        const sig = Ed25519.Signature.fromBytes(sig_bytes);
        sig.verify(&computed_digest, pk) catch {
            std.debug.print("trust-exchange: SIGNATURE INVALID for peer '{s}'\n", .{name});
            continue;
        };

        // Extract reputation fields
        const peer_rep_score = jU64(rep_data, "\"reputation_score\"") orelse 0;
        const peer_health_avg = jU64(rep_data, "\"health_average\"") orelse 0;
        const peer_unix = jU64(rep_data, "\"unix\"") orelse 0;
        const age_seconds = if (now_unix > peer_unix) now_unix - peer_unix else 0;

        peers_verified += 1;

        // Write to peer_reputations/<prefix>.json
        const prefix = pubkey_hex[0..@min(16, pubkey_hex.len)];
        const pr_path = std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ peer_rep_dir, prefix }) catch continue;
        defer alloc.free(pr_path);
        {
            var pf = compat.fs.cwd().createFile(pr_path, .{ .truncate = true }) catch continue;
            defer pf.close();
            pf.writeAll(rep_data) catch {};
        }

        // Include in network score only if fresh enough
        const is_fresh = age_seconds <= PEER_STALE_SECONDS;
        if (is_fresh) {
            rep_sum += peer_rep_score;
            health_sum += peer_health_avg;
            valid_count += 1;
        }

        std.debug.print("trust-exchange: VERIFIED peer '{s}' score={d} age={d}s fresh={}\n", .{
            name, peer_rep_score, age_seconds, is_fresh,
        });

        // Add to peer results array
        if (peer_results.items.len > 0) try compat.listWriter(&peer_results).writeByte(',');
        try compat.listWriter(&peer_results).print(
            \\{{"name":"{s}","pubkey":"{s}","reputation_score":{d},"health_average":{d},"verified":true,"fetched_unix":{d},"age_seconds":{d},"fresh":{}}}
        , .{ name, pubkey_hex, peer_rep_score, peer_health_avg, now_unix, age_seconds, is_fresh });
    }

    // Read own reputation
    const own_rep_path = try std.fmt.allocPrint(alloc, "{s}/reputation.json", .{trust_dir});
    defer alloc.free(own_rep_path);
    var own_score: u64 = 0;
    var own_health: u64 = 0;
    var own_pubkey: []const u8 = "unknown";
    {
        const own_f = compat.fs.cwd().openFile(own_rep_path, .{}) catch null;
        if (own_f) |of_const| {
            var of = of_const;
            defer of.close();
            const own_data = of.readToEndAlloc(alloc, 64 * 1024) catch null;
            if (own_data) |od| {
                own_score = jU64(od, "\"reputation_score\"") orelse 0;
                own_health = jU64(od, "\"health_average\"") orelse 0;
                own_pubkey = jStr(od, "\"pubkey\"") orelse "unknown";
                // Don't free od — own_pubkey points into it
            }
        }
    }

    // Compute network score
    const network_score: u64 = if (valid_count == 0)
        own_score
    else blk_ns: {
        const peer_avg = rep_sum / valid_count;
        break :blk_ns (own_score * 60 + peer_avg * 40) / 100;
    };

    // Build canonical trust_network JSON
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = compat.listWriter(&buf);
    try w.print(
        \\{{"version":1,"unix":{d},"chain_family":"cardano","network":"preview","self":{{"pubkey":"{s}","reputation_score":{d},"health_average":{d}}},"peers":[{s}],"network_score":{d},"peers_verified":{d},"peers_total":{d},"peers_fresh":{d}}}
    , .{
        now_unix, own_pubkey, own_score, own_health,
        peer_results.items, network_score,
        peers_verified, peers_total, valid_count,
    });

    const canonical = buf.items;

    // Digest + sign
    var digest: [32]u8 = undefined;
    Blake2b256.hash(canonical, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);

    const seed = readKey32(alloc, key_path) catch {
        try outputSnapshot(alloc, canonical, &digest_hex, null, null, null);
        return;
    };
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const sig_val = try kp.sign(&digest, null);
    const sig_hex = std.fmt.bytesToHex(sig_val.toBytes(), .lower);
    const pub_hex = std.fmt.bytesToHex(kp.public_key.toBytes(), .lower);

    // Write trust_network.json
    const net_path = try std.fmt.allocPrint(alloc, "{s}/trust_network.json", .{trust_dir});
    defer alloc.free(net_path);
    try outputSnapshot(alloc, canonical, &digest_hex, &sig_hex, &pub_hex, net_path);

    std.debug.print("trust-exchange: network_score={d} self={d} verified={d}/{d} fresh={d}\n", .{
        network_score, own_score, peers_verified, peers_total, valid_count,
    });
}

/// Fetch a URL via plain HTTP (no TLS). Supports http://host:port/path.
/// HTTPS is not supported in this MVP — document as future extension.
fn fetchHttpUrl(alloc: std.mem.Allocator, url: []const u8) ?[]u8 {
    // Parse URL: must start with http://
    const prefix = "http://";
    if (!std.mem.startsWith(u8, url, prefix)) {
        std.debug.print("trust-exchange: only http:// URLs supported (got: {s})\n", .{url});
        return null;
    }
    const after_scheme = url[prefix.len..];

    // Split host:port from path
    const path_start = std.mem.indexOf(u8, after_scheme, "/") orelse after_scheme.len;
    const host_port = after_scheme[0..path_start];
    const path = if (path_start < after_scheme.len) after_scheme[path_start..] else "/";

    // Split host and port
    var host: []const u8 = host_port;
    var port: u16 = 80;
    if (std.mem.indexOf(u8, host_port, ":")) |colon| {
        host = host_port[0..colon];
        port = std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) catch 80;
    }

    // Resolve and connect
    var addr = std.Io.net.IpAddress.parseIp4(host, port) catch {
        std.debug.print("trust-exchange: cannot resolve {s}:{d}\n", .{ host, port });
        return null;
    };
    const stream = addr.connect(compat.defaultIo(), .{ .mode = .stream }) catch {
        std.debug.print("trust-exchange: cannot connect to {s}:{d}\n", .{ host, port });
        return null;
    };
    defer stream.close(compat.defaultIo());

    // Send HTTP request
    const sw = compat.streamWriter(stream);
    sw.print("GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ path, host_port }) catch return null;

    // Read response
    const sr = compat.streamReader(stream);
    const raw = sr.readAllAlloc(alloc, 512 * 1024) catch return null;

    // Extract body after \r\n\r\n
    if (std.mem.indexOf(u8, raw, "\r\n\r\n")) |hdr_end| {
        const body = raw[hdr_end + 4 ..];
        const copy = alloc.alloc(u8, body.len) catch {
            alloc.free(raw);
            return null;
        };
        @memcpy(copy, body);
        alloc.free(raw);
        return copy;
    }

    alloc.free(raw);
    return null;
}

// ── Federation Layer ──

const DIVERGENCE_MINOR: u64 = 10; // delta >= 10 from mean
const DIVERGENCE_MAJOR: u64 = 20; // delta >= 20 from mean
const MAX_FEDERATION_PEERS: usize = 32;

pub fn runFederate(alloc: std.mem.Allocator, args_it: anytype) !void {
    var key_path: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--key")) {
            key_path = args_it.next();
        }
    }

    const home = try compat.getEnvVarOwned(alloc, "TSUNAGI_HOME");
    defer alloc.free(home);
    const trust_dir = try std.fmt.allocPrint(alloc, "{s}/trust", .{home});
    defer alloc.free(trust_dir);
    const pn_dir = try std.fmt.allocPrint(alloc, "{s}/peer_networks", .{trust_dir});
    defer alloc.free(pn_dir);
    compat.fs.cwd().makeDir(pn_dir) catch |err| if (err != error.PathAlreadyExists) return err;

    // Read peers.json
    const peers_path = try std.fmt.allocPrint(alloc, "{s}/peers.json", .{trust_dir});
    defer alloc.free(peers_path);
    const peers_raw = blk: {
        var f = compat.fs.cwd().openFile(peers_path, .{}) catch |err| {
            std.debug.print("trust-federate: cannot open {s}: {s}\n", .{ peers_path, @errorName(err) });
            return err;
        };
        defer f.close();
        break :blk try f.readToEndAlloc(alloc, 256 * 1024);
    };
    defer alloc.free(peers_raw);

    // Read own reputation
    const own_rep_path = try std.fmt.allocPrint(alloc, "{s}/reputation.json", .{trust_dir});
    defer alloc.free(own_rep_path);
    var own_score: u64 = 0;
    var own_pubkey: []const u8 = "unknown";
    // Keep own_data alive for own_pubkey slice
    var own_data_buf: ?[]u8 = null;
    {
        const own_f = compat.fs.cwd().openFile(own_rep_path, .{}) catch null;
        if (own_f) |of_const| {
            var of = of_const;
            defer of.close();
            own_data_buf = of.readToEndAlloc(alloc, 64 * 1024) catch null;
            if (own_data_buf) |od| {
                own_score = jU64(od, "\"reputation_score\"") orelse 0;
                own_pubkey = jStr(od, "\"pubkey\"") orelse "unknown";
            }
        }
    }

    const now_unix: u64 = @intCast(@max(0, compat.timestamp()));

    // Collect peer trust_network views
    var scores: [MAX_FEDERATION_PEERS + 1]u64 = undefined;
    var score_count: usize = 0;
    scores[0] = own_score;
    score_count = 1;

    var peers_total: u32 = 0;
    var peers_verified: u32 = 0;
    var peers_fresh: u32 = 0;
    var rep_sum: u64 = 0;

    var peer_views = std.array_list.Managed(u8).init(alloc);
    defer peer_views.deinit();

    // Iterate peers
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, peers_raw, search_pos, "\"endpoint\"")) |ep_pos| {
        search_pos = ep_pos + 10;
        peers_total += 1;
        if (peers_total > MAX_FEDERATION_PEERS) break;

        const endpoint_base = jStr(peers_raw[ep_pos..], "\"endpoint\"") orelse continue;
        const pubkey_hex = jStr(peers_raw[ep_pos..], "\"pubkey\"") orelse continue;
        const name = jStr(peers_raw[ep_pos..], "\"name\"") orelse "";
        const id = pubkey_hex[0..@min(16, pubkey_hex.len)];

        // Derive trust_network URL: replace last path component with trust_network.json
        // e.g. http://host/data/reputation.json → http://host/data/trust_network.json
        var tn_url_buf: [512]u8 = undefined;
        const tn_url = blk_url: {
            if (std.mem.lastIndexOf(u8, endpoint_base, "/")) |last_slash| {
                const base = endpoint_base[0 .. last_slash + 1];
                break :blk_url std.fmt.bufPrint(&tn_url_buf, "{s}trust_network.json", .{base}) catch continue;
            }
            break :blk_url std.fmt.bufPrint(&tn_url_buf, "{s}/trust_network.json", .{endpoint_base}) catch continue;
        };

        std.debug.print("trust-federate: fetching peer id={s} from {s}\n", .{ id, tn_url });

        const tn_data = fetchHttpUrl(alloc, tn_url) orelse {
            std.debug.print("trust-federate: fetch failed for id={s}\n", .{id});
            appendPeerView(&peer_views, id, name, pubkey_hex, 0, 0, 0, 0, false, "fetch_failed", "NONE") catch {};
            continue;
        };
        defer alloc.free(tn_data);

        // Verify
        const file_digest_hex = jStr(tn_data, "\"digest\"") orelse continue;
        const file_sig_hex = jStr(tn_data, "\"signature\"") orelse continue;
        const digest_boundary = std.mem.indexOf(u8, tn_data, ",\"digest\"") orelse continue;

        var canonical_buf = std.array_list.Managed(u8).init(alloc);
        defer canonical_buf.deinit();
        try canonical_buf.appendSlice(tn_data[0..digest_boundary]);
        try canonical_buf.append('}');

        var computed_digest: [32]u8 = undefined;
        Blake2b256.hash(canonical_buf.items, &computed_digest, .{});
        const computed_hex = std.fmt.bytesToHex(computed_digest, .lower);

        if (!std.mem.eql(u8, &computed_hex, file_digest_hex)) {
            std.debug.print("trust-federate: DIGEST MISMATCH for id={s}\n", .{id});
            appendPeerView(&peer_views, id, name, pubkey_hex, 0, 0, 0, 0, false, "digest_mismatch", "NONE") catch {};
            continue;
        }

        var pk_bytes: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&pk_bytes, pubkey_hex) catch continue;
        var sig_bytes: [64]u8 = undefined;
        _ = std.fmt.hexToBytes(&sig_bytes, file_sig_hex) catch continue;

        const pk = Ed25519.PublicKey.fromBytes(pk_bytes) catch continue;
        const sig = Ed25519.Signature.fromBytes(sig_bytes);
        sig.verify(&computed_digest, pk) catch {
            std.debug.print("trust-federate: SIGNATURE INVALID for id={s}\n", .{id});
            appendPeerView(&peer_views, id, name, pubkey_hex, 0, 0, 0, 0, false, "sig_invalid", "NONE") catch {};
            continue;
        };

        peers_verified += 1;

        // Extract fields from peer's trust_network
        const peer_net_score = jU64(tn_data, "\"network_score\"") orelse 0;
        const peer_self_rep = blk_sr: {
            if (std.mem.indexOf(u8, tn_data, "\"self\"")) |sp| {
                break :blk_sr jU64(tn_data[sp..], "\"reputation_score\"") orelse 0;
            }
            break :blk_sr @as(u64, 0);
        };
        const peer_fresh_count = jU64(tn_data, "\"peers_fresh\"") orelse 0;
        const peer_unix = jU64(tn_data, "\"unix\"") orelse 0;
        const age = if (now_unix > peer_unix) now_unix - peer_unix else 0;
        const is_fresh = age <= PEER_STALE_SECONDS;

        // Store
        const pr_path = std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ pn_dir, id }) catch continue;
        defer alloc.free(pr_path);
        {
            var pf = compat.fs.cwd().createFile(pr_path, .{ .truncate = true }) catch continue;
            defer pf.close();
            pf.writeAll(tn_data) catch {};
        }

        if (is_fresh) {
            peers_fresh += 1;
            const contribution = (peer_self_rep * 60 + peer_net_score * 40) / 100;
            rep_sum += contribution;
            if (score_count < MAX_FEDERATION_PEERS + 1) {
                scores[score_count] = peer_self_rep;
                score_count += 1;
            }
        }

        // Divergence computed after all peers collected — placeholder for now
        appendPeerView(&peer_views, id, name, pubkey_hex, peer_self_rep, peer_net_score, @intCast(peer_fresh_count), age, is_fresh, "ok", "PENDING") catch {};

        std.debug.print("trust-federate: VERIFIED id={s} self_rep={d} net_score={d} age={d}s fresh={}\n", .{
            id, peer_self_rep, peer_net_score, age, is_fresh,
        });
    }

    // Compute federation score
    const federation_score: u64 = if (peers_fresh == 0)
        own_score
    else blk_fs: {
        const peer_avg = rep_sum / peers_fresh;
        break :blk_fs (own_score * 50 + peer_avg * 50) / 100;
    };

    // Agreement: integer stddev * 10 subtracted from 1000, clamped [0, 1000]
    // Using integer math: variance = sum((x - mean)^2) / n
    const agreement_x1000: u64 = blk_ag: {
        if (score_count < 2) break :blk_ag 1000;
        var sum: u64 = 0;
        for (scores[0..score_count]) |s| sum += s;
        const mean = sum / score_count;
        var var_sum: u64 = 0;
        for (scores[0..score_count]) |s| {
            const diff: i64 = @as(i64, @intCast(s)) - @as(i64, @intCast(mean));
            const d2: u64 = @intCast(diff * diff);
            // Cap per-element contribution to prevent overflow from extreme outliers
            var_sum += @min(d2, 10000);
        }
        const variance = var_sum / score_count;
        // Integer sqrt approximation (Newton's method, 5 iterations)
        var stddev: u64 = if (variance > 0) variance else 0;
        if (stddev > 0) {
            var x: u64 = variance;
            var i: u32 = 0;
            while (i < 5) : (i += 1) {
                if (x == 0) break;
                x = (x + variance / x) / 2;
            }
            stddev = x;
        }
        const penalty = @min(1000, stddev * 10);
        break :blk_ag 1000 -| penalty;
    };

    // Recompute divergence for each peer and rebuild peer_views with correct levels
    // The mean is scores[0..score_count] average
    var mean_score: u64 = 0;
    if (score_count > 0) {
        var s: u64 = 0;
        for (scores[0..score_count]) |sc| s += sc;
        mean_score = s / score_count;
    }

    // Rebuild peer_views with divergence levels
    var final_views = std.array_list.Managed(u8).init(alloc);
    defer final_views.deinit();
    var divergent_count: u32 = 0;

    // Re-parse the PENDING peer views and update divergence
    // Split peer_views by },{ boundaries
    {
        const raw_views = peer_views.items;
        var vit = std.mem.splitSequence(u8, raw_views, "},{");
        var first = true;
        while (vit.next()) |chunk| {
            // Reconstruct the full JSON object
            var obj = std.array_list.Managed(u8).init(alloc);
            defer obj.deinit();
            if (!first) try obj.append('{');
            try obj.appendSlice(chunk);
            if (vit.peek() != null) try obj.append('}');
            first = false;

            // Extract self_reputation from this view
            const peer_rep = jU64(obj.items, "\"self_reputation\"") orelse continue;
            const diff_abs: u64 = if (peer_rep > mean_score) peer_rep - mean_score else mean_score - peer_rep;
            const diff_signed: i64 = @as(i64, @intCast(peer_rep)) - @as(i64, @intCast(mean_score));
            const level: []const u8 = if (diff_abs >= DIVERGENCE_MAJOR)
                "MAJOR"
            else if (diff_abs >= DIVERGENCE_MINOR)
                "MINOR"
            else
                "NONE";

            if (diff_abs >= DIVERGENCE_MINOR) divergent_count += 1;

            // Replace "PENDING" with actual level and add delta
            if (std.mem.indexOf(u8, obj.items, "\"PENDING\"")) |pend_pos| {
                if (final_views.items.len > 0) try compat.listWriter(&final_views).writeByte(',');
                try final_views.appendSlice(obj.items[0..pend_pos]);
                try compat.listWriter(&final_views).print("\"{s}\",\"divergence_delta\":{d}", .{ level, diff_signed });
                // Find the rest after "PENDING"
                const after = pend_pos + 9; // len("\"PENDING\"")
                if (after < obj.items.len) {
                    try final_views.appendSlice(obj.items[after..]);
                }
            } else {
                if (final_views.items.len > 0) try compat.listWriter(&final_views).writeByte(',');
                try final_views.appendSlice(obj.items);
            }
        }
    }

    // Build canonical federation JSON
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = compat.listWriter(&buf);
    try w.print(
        \\{{"version":1,"unix":{d},"chain_family":"cardano","network":"preview","federation_score":{d},"agreement_ratio_x1000":{d},"self_reputation":{d},"self_pubkey":"{s}","peers_in_federation":{d},"peers_verified":{d},"peers_fresh":{d},"peers_divergent":{d},"mean_reputation":{d},"peer_views":[{s}]}}
    , .{
        now_unix, federation_score, agreement_x1000,
        own_score, own_pubkey,
        peers_total, peers_verified, peers_fresh, divergent_count,
        mean_score, final_views.items,
    });

    const canonical = buf.items;

    // Digest + sign
    var digest: [32]u8 = undefined;
    Blake2b256.hash(canonical, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);

    const seed = readKey32(alloc, key_path) catch {
        try outputSnapshot(alloc, canonical, &digest_hex, null, null, null);
        return;
    };
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const sig_val = try kp.sign(&digest, null);
    const sig_hex = std.fmt.bytesToHex(sig_val.toBytes(), .lower);
    const pub_hex = std.fmt.bytesToHex(kp.public_key.toBytes(), .lower);

    const fed_path = try std.fmt.allocPrint(alloc, "{s}/federation.json", .{trust_dir});
    defer alloc.free(fed_path);
    try outputSnapshot(alloc, canonical, &digest_hex, &sig_hex, &pub_hex, fed_path);

    std.debug.print("trust-federate: score={d} agreement={d}/1000 verified={d}/{d} fresh={d} divergent={d} mean={d}\n", .{
        federation_score, agreement_x1000, peers_verified, peers_total, peers_fresh, divergent_count, mean_score,
    });

    // Free own_data_buf if allocated
    if (own_data_buf) |od| alloc.free(od);
}

fn appendPeerView(
    list: *std.array_list.Managed(u8),
    id: []const u8,
    name: []const u8,
    pubkey: []const u8,
    self_rep: u64,
    net_score: u64,
    their_fresh: u64,
    age: u64,
    is_fresh: bool,
    status: []const u8,
    divergence: []const u8,
) !void {
    if (list.items.len > 0) try compat.listWriter(list).writeByte(',');
    try compat.listWriter(list).print(
        \\{{"id":"{s}","name":"{s}","pubkey":"{s}","self_reputation":{d},"network_score":{d},"their_peers_fresh":{d},"age_seconds":{d},"fresh":{},"status":"{s}","divergence_level":"{s}"}}
    , .{ id, name, pubkey, self_rep, net_score, their_fresh, age, is_fresh, status, divergence });
}

// ── Trust Graph ──

const MAX_GRAPH_NODES: usize = 64;

const GraphNode = struct {
    id: [16]u8 = undefined,
    id_len: u8 = 0,
    reputation: u64 = 0,
    depth: u8 = 0, // 0=self, 1=direct peer, 2=transitive
    trust_weight_x1000: u64 = 1000,
    verified: bool = false,
    fresh: bool = false,
};

const GraphEdge = struct {
    from_idx: u8 = 0,
    to_idx: u8 = 0,
    weight: u64 = 0,
    fresh: bool = false,
};

pub fn runGraph(alloc: std.mem.Allocator, args_it: anytype) !void {
    var key_path: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--key")) {
            key_path = args_it.next();
        }
    }

    const home = try compat.getEnvVarOwned(alloc, "TSUNAGI_HOME");
    defer alloc.free(home);
    const trust_dir = try std.fmt.allocPrint(alloc, "{s}/trust", .{home});
    defer alloc.free(trust_dir);

    var nodes: [MAX_GRAPH_NODES]GraphNode = undefined;
    var node_count: usize = 0;
    var edges: [MAX_GRAPH_NODES * 4]GraphEdge = undefined;
    var edge_count: usize = 0;

    const now_unix: u64 = @intCast(@max(0, compat.timestamp()));

    // Helper: find or insert node by id prefix
    const findOrInsert = struct {
        fn call(ns: *[MAX_GRAPH_NODES]GraphNode, nc: *usize, id_str: []const u8) ?usize {
            const id_l: u8 = @intCast(@min(16, id_str.len));
            // Search existing
            for (ns.*[0..nc.*], 0..) |*n, i| {
                if (n.id_len == id_l and std.mem.eql(u8, n.id[0..id_l], id_str[0..id_l])) return i;
            }
            // Insert — zero-initialize before setting fields
            if (nc.* >= MAX_GRAPH_NODES) return null;
            const idx = nc.*;
            ns.*[idx] = .{};
            @memcpy(ns.*[idx].id[0..id_l], id_str[0..id_l]);
            ns.*[idx].id_len = id_l;
            nc.* += 1;
            return idx;
        }
    }.call;

    // Read own trust_network.json
    const tn_path = try std.fmt.allocPrint(alloc, "{s}/trust_network.json", .{trust_dir});
    defer alloc.free(tn_path);
    const tn_data = blk: {
        var f = compat.fs.cwd().openFile(tn_path, .{}) catch |err| {
            std.debug.print("trust-graph: cannot open trust_network.json: {s}\n", .{@errorName(err)});
            return err;
        };
        defer f.close();
        break :blk try f.readToEndAlloc(alloc, 256 * 1024);
    };
    defer alloc.free(tn_data);

    // Self node
    var self_id: []const u8 = "unknown";
    var self_rep: u64 = 0;
    if (std.mem.indexOf(u8, tn_data, "\"self\"")) |sp| {
        const sub = tn_data[sp..];
        if (jStr(sub, "\"pubkey\"")) |pk| {
            self_id = pk[0..@min(16, pk.len)];
        }
        self_rep = jU64(sub, "\"reputation_score\"") orelse 0;
    }
    const self_idx = findOrInsert(&nodes, &node_count, self_id) orelse return error.GraphFull;
    nodes[self_idx].reputation = self_rep;
    nodes[self_idx].depth = 0;
    nodes[self_idx].trust_weight_x1000 = 1000;
    nodes[self_idx].verified = true;
    nodes[self_idx].fresh = true;

    // Direct peers from trust_network.json "peers" array
    {
        var spos: usize = 0;
        while (std.mem.indexOfPos(u8, tn_data, spos, "\"reputation_score\"")) |rp| {
            // Find the enclosing peer object's pubkey
            // Search backwards for "pubkey"
            const chunk_start = if (rp > 200) rp - 200 else 0;
            const chunk = tn_data[chunk_start..rp];
            const pk_str = jStr(chunk, "\"pubkey\"") orelse { spos = rp + 1; continue; };
            const peer_id = pk_str[0..@min(16, pk_str.len)];

            // Skip self
            if (std.mem.eql(u8, peer_id[0..@min(16, self_id.len)], self_id[0..@min(16, self_id.len)])) {
                spos = rp + 1;
                continue;
            }

            const peer_rep = jU64(tn_data[rp..], "\"reputation_score\"") orelse 0;
            const peer_fresh = if (std.mem.indexOf(u8, tn_data[rp..@min(rp + 100, tn_data.len)], "\"fresh\":true")) |_| true else false;

            const peer_idx = findOrInsert(&nodes, &node_count, peer_id) orelse { spos = rp + 1; continue; };
            nodes[peer_idx].reputation = peer_rep;
            nodes[peer_idx].depth = 1;
            nodes[peer_idx].trust_weight_x1000 = 1000;
            nodes[peer_idx].verified = true;
            nodes[peer_idx].fresh = peer_fresh;

            // Edge: self → peer
            if (edge_count < edges.len) {
                edges[edge_count] = .{ .from_idx = @intCast(self_idx), .to_idx = @intCast(peer_idx), .weight = peer_rep, .fresh = peer_fresh };
                edge_count += 1;
            }

            spos = rp + 1;
        }
    }

    // Transitive peers from peer_networks/<id>.json
    const pn_dir = try std.fmt.allocPrint(alloc, "{s}/peer_networks", .{trust_dir});
    defer alloc.free(pn_dir);
    {
        var dir = compat.fs.cwd().openDir(pn_dir, .{ .iterate = true }) catch {
            // No peer_networks directory — continue without transitive peers
            return buildGraphOutput(alloc, &nodes, node_count, &edges, edge_count, self_id, now_unix, trust_dir, key_path);
        };
        defer dir.close();

        // Collect filenames and sort for deterministic iteration order
        var name_buf: [MAX_GRAPH_NODES][64]u8 = undefined;
        var name_lens: [MAX_GRAPH_NODES]u8 = undefined;
        var file_count: usize = 0;
        {
            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
                if (file_count >= MAX_GRAPH_NODES) break;
                const len: u8 = @intCast(@min(64, entry.name.len));
                @memcpy(name_buf[file_count][0..len], entry.name[0..len]);
                name_lens[file_count] = len;
                file_count += 1;
            }
        }
        // Sort by filename (lexicographic)
        for (0..file_count) |i| {
            for (i + 1..file_count) |j| {
                const a = name_buf[i][0..name_lens[i]];
                const b = name_buf[j][0..name_lens[j]];
                if (std.mem.order(u8, a, b) == .gt) {
                    const tmp_name = name_buf[i];
                    const tmp_len = name_lens[i];
                    name_buf[i] = name_buf[j];
                    name_lens[i] = name_lens[j];
                    name_buf[j] = tmp_name;
                    name_lens[j] = tmp_len;
                }
            }
        }

        for (0..file_count) |fi| {
            const entry_name = name_buf[fi][0..name_lens[fi]];

            // The intermediary is identified by the filename prefix
            const intermediary_id = entry_name[0..@min(16, entry_name.len - 5)]; // strip .json
            const intermediary_idx = findOrInsert(&nodes, &node_count, intermediary_id);
            if (intermediary_idx == null) continue;
            const inter_rep = nodes[intermediary_idx.?].reputation;

            // Read the peer's trust_network
            const pn_path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ pn_dir, entry_name }) catch continue;
            defer alloc.free(pn_path);
            const pn_data = blk: {
                var pf = compat.fs.cwd().openFile(pn_path, .{}) catch continue;
                defer pf.close();
                break :blk pf.readToEndAlloc(alloc, 256 * 1024) catch continue;
            };
            defer alloc.free(pn_data);

            // Find peers listed in this trust_network
            var spos2: usize = 0;
            while (std.mem.indexOfPos(u8, pn_data, spos2, "\"reputation_score\"")) |rp2| {
                const chunk_start2 = if (rp2 > 200) rp2 - 200 else 0;
                const chunk2 = pn_data[chunk_start2..rp2];
                const pk2 = jStr(chunk2, "\"pubkey\"") orelse { spos2 = rp2 + 1; continue; };
                const tp_id = pk2[0..@min(16, pk2.len)];

                // Skip self and intermediary
                if (std.mem.eql(u8, tp_id[0..@min(16, self_id.len)], self_id[0..@min(16, self_id.len)])) {
                    spos2 = rp2 + 1;
                    continue;
                }
                if (std.mem.eql(u8, tp_id[0..@min(16, intermediary_id.len)], intermediary_id[0..@min(16, intermediary_id.len)])) {
                    spos2 = rp2 + 1;
                    continue;
                }

                const tp_rep = jU64(pn_data[rp2..], "\"reputation_score\"") orelse 0;
                const tp_fresh = if (std.mem.indexOf(u8, pn_data[rp2..@min(rp2 + 100, pn_data.len)], "\"fresh\":true")) |_| true else false;

                const tp_idx = findOrInsert(&nodes, &node_count, tp_id) orelse { spos2 = rp2 + 1; continue; };
                // Only set depth if not already closer
                if (nodes[tp_idx].depth == 0 and tp_idx != self_idx) {
                    nodes[tp_idx].depth = 2;
                }
                if (nodes[tp_idx].reputation == 0) nodes[tp_idx].reputation = tp_rep;
                nodes[tp_idx].fresh = tp_fresh;
                // Trust weight: 0.5 * intermediary_rep / 100
                nodes[tp_idx].trust_weight_x1000 = (500 * inter_rep) / 100;

                // Edge: intermediary → transitive peer
                if (edge_count < edges.len) {
                    edges[edge_count] = .{ .from_idx = @intCast(intermediary_idx.?), .to_idx = @intCast(tp_idx), .weight = tp_rep, .fresh = tp_fresh };
                    edge_count += 1;
                }

                spos2 = rp2 + 1;
            }
        }
    }

    try buildGraphOutput(alloc, &nodes, node_count, &edges, edge_count, self_id, now_unix, trust_dir, key_path);
}

fn buildGraphOutput(
    alloc: std.mem.Allocator,
    nodes: *[MAX_GRAPH_NODES]GraphNode,
    node_count: usize,
    edges: *[MAX_GRAPH_NODES * 4]GraphEdge,
    edge_count: usize,
    self_id: []const u8,
    now_unix: u64,
    trust_dir: []const u8,
    key_path: ?[]const u8,
) !void {
    // Compute graph_score: weighted average of node.reputation * trust_weight
    var weighted_sum: u64 = 0;
    var weight_total: u64 = 0;
    var fresh_count: u32 = 0;
    var verified_count: u32 = 0;
    for (nodes.*[0..node_count]) |n| {
        weighted_sum += (n.reputation * n.trust_weight_x1000) / 1000;
        weight_total += 1;
        if (n.fresh) fresh_count += 1;
        if (n.verified) verified_count += 1;
    }
    const graph_score: u64 = if (weight_total > 0) weighted_sum / weight_total else 0;

    // Cluster classification
    var high: u32 = 0;
    var mid: u32 = 0;
    var low: u32 = 0;
    for (nodes.*[0..node_count]) |n| {
        if (n.reputation >= 80) high += 1
        else if (n.reputation >= 50) mid += 1
        else low += 1;
    }
    const cluster: []const u8 = if (low == 0 and mid == 0)
        "COHESIVE"
    else if (mid == 0 and low > 0 and high > 0)
        "SPLIT"
    else
        "FRAGMENTED";

    // Build JSON
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = compat.listWriter(&buf);

    try w.print(
        \\{{"version":1,"unix":{d},"chain_family":"cardano","network":"preview","graph_score":{d},"nodes_total":{d},"nodes_verified":{d},"nodes_fresh":{d},"edges_total":{d},"cluster":"{s}","self_id":"{s}","nodes":[
    , .{ now_unix, graph_score, node_count, verified_count, fresh_count, edge_count, cluster, self_id });

    for (nodes.*[0..node_count], 0..) |n, i| {
        if (i > 0) try w.writeByte(',');
        const band: []const u8 = if (n.reputation >= 80) "HIGH" else if (n.reputation >= 50) "MID" else "LOW";
        try w.print(
            \\{{"id":"{s}","reputation":{d},"depth":{d},"trust_weight_x1000":{d},"band":"{s}"}}
        , .{ n.id[0..n.id_len], n.reputation, n.depth, n.trust_weight_x1000, band });
    }

    try w.writeAll("],\"edges\":[");
    for (edges.*[0..edge_count], 0..) |e, i| {
        if (i > 0) try w.writeByte(',');
        const from_n = nodes.*[e.from_idx];
        const to_n = nodes.*[e.to_idx];
        try w.print(
            \\{{"from":"{s}","to":"{s}","weight":{d},"fresh":{}}}
        , .{ from_n.id[0..from_n.id_len], to_n.id[0..to_n.id_len], e.weight, e.fresh });
    }
    try w.writeAll("]}");

    const canonical = buf.items;

    // Digest + sign
    var digest: [32]u8 = undefined;
    Blake2b256.hash(canonical, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);

    const seed = readKey32(alloc, key_path) catch {
        try outputSnapshot(alloc, canonical, &digest_hex, null, null, null);
        return;
    };
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const sig_val = try kp.sign(&digest, null);
    const sig_hex = std.fmt.bytesToHex(sig_val.toBytes(), .lower);
    const pub_hex = std.fmt.bytesToHex(kp.public_key.toBytes(), .lower);

    const graph_path = try std.fmt.allocPrint(alloc, "{s}/trust_graph.json", .{trust_dir});
    defer alloc.free(graph_path);
    try outputSnapshot(alloc, canonical, &digest_hex, &sig_hex, &pub_hex, graph_path);

    std.debug.print("trust-graph: score={d} nodes={d} edges={d} cluster={s} fresh={d} verified={d}\n", .{
        graph_score, node_count, edge_count, cluster, fresh_count, verified_count,
    });
}

// ── Trust Graph Propagation ──

const MAX_PROPAGATED_NODES: usize = 128;
const MAX_PROPAGATED_EDGES: usize = 512;
const MAX_PROPAGATION_DEPTH: u8 = 3;

pub fn runPropagate(alloc: std.mem.Allocator, args_it: anytype) !void {
    var key_path: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--key")) {
            key_path = args_it.next();
        }
    }

    const home = try compat.getEnvVarOwned(alloc, "TSUNAGI_HOME");
    defer alloc.free(home);
    const trust_dir = try std.fmt.allocPrint(alloc, "{s}/trust", .{home});
    defer alloc.free(trust_dir);
    const pg_dir = try std.fmt.allocPrint(alloc, "{s}/peer_graphs", .{trust_dir});
    defer alloc.free(pg_dir);
    compat.fs.cwd().makeDir(pg_dir) catch |err| if (err != error.PathAlreadyExists) return err;

    const now_unix: u64 = @intCast(@max(0, compat.timestamp()));

    // Merged node/edge arrays
    var m_nodes: [MAX_PROPAGATED_NODES]GraphNode = undefined;
    var m_node_count: usize = 0;
    var m_edges: [MAX_PROPAGATED_EDGES]GraphEdge = undefined;
    var m_edge_count: usize = 0;

    const findOrInsertM = struct {
        fn call(ns: *[MAX_PROPAGATED_NODES]GraphNode, nc: *usize, id_str: []const u8) ?usize {
            const id_l: u8 = @intCast(@min(16, id_str.len));
            for (ns.*[0..nc.*], 0..) |*n, i| {
                if (n.id_len == id_l and std.mem.eql(u8, n.id[0..id_l], id_str[0..id_l])) return i;
            }
            if (nc.* >= MAX_PROPAGATED_NODES) return null;
            const idx = nc.*;
            ns.*[idx] = .{};
            @memcpy(ns.*[idx].id[0..id_l], id_str[0..id_l]);
            ns.*[idx].id_len = id_l;
            nc.* += 1;
            return idx;
        }
    }.call;

    // Phase 1: Load own trust_graph
    const own_graph_path = try std.fmt.allocPrint(alloc, "{s}/trust_graph.json", .{trust_dir});
    defer alloc.free(own_graph_path);
    {
        const own_data = blk: {
            var f = compat.fs.cwd().openFile(own_graph_path, .{}) catch {
                std.debug.print("trust-propagate: no local trust_graph.json\n", .{});
                return error.MissingLocalGraph;
            };
            defer f.close();
            break :blk try f.readToEndAlloc(alloc, 256 * 1024);
        };
        defer alloc.free(own_data);
        ingestGraphJson(own_data, &m_nodes, &m_node_count, &m_edges, &m_edge_count, 0, findOrInsertM);
    }

    // Phase 2: Read peers.json, fetch each peer's trust_graph, verify, merge
    const peers_path = try std.fmt.allocPrint(alloc, "{s}/peers.json", .{trust_dir});
    defer alloc.free(peers_path);
    const peers_raw = blk: {
        var f = compat.fs.cwd().openFile(peers_path, .{}) catch {
            std.debug.print("trust-propagate: no peers.json\n", .{});
            return error.MissingPeers;
        };
        defer f.close();
        break :blk try f.readToEndAlloc(alloc, 256 * 1024);
    };
    defer alloc.free(peers_raw);

    var peers_total: u32 = 0;
    var peers_fetched: u32 = 0;
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, peers_raw, search_pos, "\"endpoint\"")) |ep_pos| {
        search_pos = ep_pos + 10;
        peers_total += 1;

        const endpoint_base = jStr(peers_raw[ep_pos..], "\"endpoint\"") orelse continue;
        const pubkey_hex = jStr(peers_raw[ep_pos..], "\"pubkey\"") orelse continue;
        const id = pubkey_hex[0..@min(16, pubkey_hex.len)];

        // Derive graph URL
        var url_buf: [512]u8 = undefined;
        const graph_url = blk_url: {
            if (std.mem.lastIndexOf(u8, endpoint_base, "/")) |ls| {
                break :blk_url std.fmt.bufPrint(&url_buf, "{s}trust_graph.json", .{endpoint_base[0 .. ls + 1]}) catch continue;
            }
            break :blk_url std.fmt.bufPrint(&url_buf, "{s}/trust_graph.json", .{endpoint_base}) catch continue;
        };

        std.debug.print("trust-propagate: fetching peer id={s}\n", .{id});
        const pg_data = fetchHttpUrl(alloc, graph_url) orelse {
            std.debug.print("trust-propagate: fetch failed for id={s}\n", .{id});
            continue;
        };
        defer alloc.free(pg_data);

        // Verify signature
        const file_digest = jStr(pg_data, "\"digest\"") orelse continue;
        const file_sig = jStr(pg_data, "\"signature\"") orelse continue;
        const boundary = std.mem.indexOf(u8, pg_data, ",\"digest\"") orelse continue;

        var canon = std.array_list.Managed(u8).init(alloc);
        defer canon.deinit();
        try canon.appendSlice(pg_data[0..boundary]);
        try canon.append('}');

        var cd: [32]u8 = undefined;
        Blake2b256.hash(canon.items, &cd, .{});
        const ch = std.fmt.bytesToHex(cd, .lower);
        if (!std.mem.eql(u8, &ch, file_digest)) {
            std.debug.print("trust-propagate: DIGEST MISMATCH id={s}\n", .{id});
            continue;
        }

        var pk_b: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&pk_b, pubkey_hex) catch continue;
        var sig_b: [64]u8 = undefined;
        _ = std.fmt.hexToBytes(&sig_b, file_sig) catch continue;
        const pk = Ed25519.PublicKey.fromBytes(pk_b) catch continue;
        const sig = Ed25519.Signature.fromBytes(sig_b);
        sig.verify(&cd, pk) catch {
            std.debug.print("trust-propagate: SIG INVALID id={s}\n", .{id});
            continue;
        };

        // Store verified graph
        const store_path = std.fmt.allocPrint(alloc, "{s}/{s}.json", .{ pg_dir, id }) catch continue;
        defer alloc.free(store_path);
        {
            var sf = compat.fs.cwd().createFile(store_path, .{ .truncate = true }) catch continue;
            defer sf.close();
            sf.writeAll(pg_data) catch {};
        }

        // Check freshness
        const peer_unix = jU64(pg_data, "\"unix\"") orelse 0;
        const age = if (now_unix > peer_unix) now_unix - peer_unix else 0;
        if (age > PEER_STALE_SECONDS) {
            std.debug.print("trust-propagate: STALE id={s} age={d}s\n", .{ id, age });
            continue;
        }

        // Ingest peer's graph nodes/edges with depth offset +1
        ingestGraphJson(pg_data, &m_nodes, &m_node_count, &m_edges, &m_edge_count, 1, findOrInsertM);
        peers_fetched += 1;
        std.debug.print("trust-propagate: MERGED id={s} age={d}s\n", .{ id, age });
    }

    // Phase 3: Recompute weights for depth, score, cluster, output
    for (m_nodes[0..m_node_count]) |*n| {
        n.trust_weight_x1000 = switch (n.depth) {
            0 => 1000,
            1 => 1000,
            2 => 500,
            3 => 250,
            else => 100,
        };
    }

    // Get self_id
    var self_id: []const u8 = "unknown";
    if (m_node_count > 0) self_id = m_nodes[0].id[0..m_nodes[0].id_len];

    try buildPropagatedOutput(alloc, &m_nodes, m_node_count, &m_edges, m_edge_count, self_id, now_unix, peers_total, peers_fetched, trust_dir, key_path);
}

fn ingestGraphJson(
    data: []const u8,
    nodes: *[MAX_PROPAGATED_NODES]GraphNode,
    node_count: *usize,
    edges: *[MAX_PROPAGATED_EDGES]GraphEdge,
    edge_count: *usize,
    depth_offset: u8,
    findOrInsert: fn (*[MAX_PROPAGATED_NODES]GraphNode, *usize, []const u8) ?usize,
) void {
    // Extract nodes from "nodes":[...] array
    var spos: usize = 0;
    while (std.mem.indexOfPos(u8, data, spos, "\"id\":\"")) |id_pos| {
        const id_start = id_pos + 6; // after "id":"
        const id_end = std.mem.indexOfPos(u8, data, id_start, "\"") orelse break;
        const node_id = data[id_start..id_end];
        spos = id_end + 1;

        // Find reputation and depth near this id
        const chunk_end = @min(id_end + 200, data.len);
        const chunk = data[id_end..chunk_end];
        const rep = jU64(chunk, "\"reputation\"") orelse continue;
        const orig_depth: u8 = @intCast(jU64(chunk, "\"depth\"") orelse 0);
        const new_depth = @min(orig_depth + depth_offset, MAX_PROPAGATION_DEPTH);

        const idx = findOrInsert(nodes, node_count, node_id) orelse continue;
        // Keep the closer (lower depth) version
        if (nodes.*[idx].reputation == 0 or new_depth < nodes.*[idx].depth) {
            nodes.*[idx].reputation = rep;
            nodes.*[idx].depth = new_depth;
        }
    }

    // Extract edges from "edges":[...] array
    var epos: usize = 0;
    while (std.mem.indexOfPos(u8, data, epos, "\"from\":\"")) |from_pos| {
        const from_start = from_pos + 8;
        const from_end = std.mem.indexOfPos(u8, data, from_start, "\"") orelse break;
        const from_id = data[from_start..from_end];
        epos = from_end + 1;

        const to_start_anchor = std.mem.indexOfPos(u8, data, epos, "\"to\":\"") orelse break;
        const to_start = to_start_anchor + 6;
        const to_end = std.mem.indexOfPos(u8, data, to_start, "\"") orelse break;
        const to_id = data[to_start..to_end];

        const weight = jU64(data[to_end..@min(to_end + 100, data.len)], "\"weight\"") orelse 0;

        const from_idx = findOrInsert(nodes, node_count, from_id) orelse continue;
        const to_idx = findOrInsert(nodes, node_count, to_id) orelse continue;

        // Check depth bounds
        if (nodes.*[from_idx].depth > MAX_PROPAGATION_DEPTH) continue;
        if (nodes.*[to_idx].depth > MAX_PROPAGATION_DEPTH) continue;

        // Deduplicate: keep higher weight for same from→to
        var found_existing = false;
        for (edges.*[0..edge_count.*]) |*e| {
            if (e.from_idx == @as(u8, @intCast(from_idx)) and e.to_idx == @as(u8, @intCast(to_idx))) {
                if (weight > e.weight) e.weight = weight;
                found_existing = true;
                break;
            }
        }
        if (!found_existing and edge_count.* < MAX_PROPAGATED_EDGES) {
            edges.*[edge_count.*] = .{
                .from_idx = @intCast(from_idx),
                .to_idx = @intCast(to_idx),
                .weight = weight,
                .fresh = true,
            };
            edge_count.* += 1;
        }
    }
}

fn buildPropagatedOutput(
    alloc: std.mem.Allocator,
    nodes: *[MAX_PROPAGATED_NODES]GraphNode,
    node_count: usize,
    edges: *[MAX_PROPAGATED_EDGES]GraphEdge,
    edge_count: usize,
    self_id: []const u8,
    now_unix: u64,
    peers_total: u32,
    peers_fetched: u32,
    trust_dir: []const u8,
    key_path: ?[]const u8,
) !void {
    // Score
    var weighted_sum: u64 = 0;
    var count: u64 = 0;
    var high: u32 = 0;
    var mid: u32 = 0;
    var low: u32 = 0;
    var max_depth: u8 = 0;
    for (nodes.*[0..node_count]) |n| {
        weighted_sum += (n.reputation * n.trust_weight_x1000) / 1000;
        count += 1;
        if (n.reputation >= 80) high += 1 else if (n.reputation >= 50) mid += 1 else low += 1;
        if (n.depth > max_depth) max_depth = n.depth;
    }
    const prop_score: u64 = if (count > 0) weighted_sum / count else 0;
    const cluster: []const u8 = if (low == 0 and mid == 0) "COHESIVE" else if (mid == 0 and low > 0 and high > 0) "SPLIT" else "FRAGMENTED";

    // Build JSON
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = compat.listWriter(&buf);

    try w.print(
        \\{{"version":1,"unix":{d},"chain_family":"cardano","network":"preview","propagated_score":{d},"nodes_total":{d},"edges_total":{d},"max_depth":{d},"cluster":"{s}","peers_queried":{d},"peers_merged":{d},"self_id":"{s}","nodes":[
    , .{ now_unix, prop_score, node_count, edge_count, max_depth, cluster, peers_total, peers_fetched, self_id });

    for (nodes.*[0..node_count], 0..) |n, i| {
        if (i > 0) try w.writeByte(',');
        const band: []const u8 = if (n.reputation >= 80) "HIGH" else if (n.reputation >= 50) "MID" else "LOW";
        try w.print(
            \\{{"id":"{s}","reputation":{d},"depth":{d},"weight_x1000":{d},"band":"{s}"}}
        , .{ n.id[0..n.id_len], n.reputation, n.depth, n.trust_weight_x1000, band });
    }

    try w.writeAll("],\"edges\":[");
    for (edges.*[0..edge_count], 0..) |e, i| {
        if (i > 0) try w.writeByte(',');
        const fn_node = nodes.*[e.from_idx];
        const tn_node = nodes.*[e.to_idx];
        try w.print(
            \\{{"from":"{s}","to":"{s}","weight":{d}}}
        , .{ fn_node.id[0..fn_node.id_len], tn_node.id[0..tn_node.id_len], e.weight });
    }
    try w.writeAll("]}");

    const canonical = buf.items;
    var digest: [32]u8 = undefined;
    Blake2b256.hash(canonical, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);

    const seed = readKey32(alloc, key_path) catch {
        try outputSnapshot(alloc, canonical, &digest_hex, null, null, null);
        return;
    };
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const sig_val = try kp.sign(&digest, null);
    const sig_hex = std.fmt.bytesToHex(sig_val.toBytes(), .lower);
    const pub_hex = std.fmt.bytesToHex(kp.public_key.toBytes(), .lower);

    const out_path = try std.fmt.allocPrint(alloc, "{s}/propagated_graph.json", .{trust_dir});
    defer alloc.free(out_path);
    try outputSnapshot(alloc, canonical, &digest_hex, &sig_hex, &pub_hex, out_path);

    std.debug.print("trust-propagate: score={d} nodes={d} edges={d} depth={d} cluster={s} merged={d}/{d}\n", .{
        prop_score, node_count, edge_count, max_depth, cluster, peers_fetched, peers_total,
    });
}

// ── Helpers ──

fn fetchState(alloc: std.mem.Allocator, port: u16) ?[]u8 {
    var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return null;
    const stream = addr.connect(compat.defaultIo(), .{ .mode = .stream }) catch return null;
    defer stream.close(compat.defaultIo());
    const w = compat.streamWriter(stream);
    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch return null;
    w.print("GET /state HTTP/1.1\r\nHost: 127.0.0.1:{s}\r\nConnection: close\r\n\r\n", .{port_str}) catch return null;
    const sr2 = compat.streamReader(stream);
    const raw = sr2.readAllAlloc(alloc, 512 * 1024) catch return null;
    if (std.mem.indexOf(u8, raw, "\r\n\r\n")) |hdr_end| {
        const body = raw[hdr_end + 4 ..];
        const copy = alloc.alloc(u8, body.len) catch { alloc.free(raw); return null; };
        @memcpy(copy, body);
        alloc.free(raw);
        return copy;
    }
    alloc.free(raw);
    return null;
}

fn readKey32(alloc: std.mem.Allocator, path_opt: ?[]const u8) ![32]u8 {
    const path = if (path_opt) |p| p else blk: {
        const home = try compat.getEnvVarOwned(alloc, "HOME");
        defer alloc.free(home);
        const dp = try std.fs.path.join(alloc, &[_][]const u8{ home, ".local", "tsunagi", "keys", "snapshot_ed25519.key" });
        break :blk dp;
    };
    var f = try compat.fs.cwd().openFile(path, .{});
    defer f.close();
    const raw = try f.readToEndAlloc(alloc, 4096);
    defer alloc.free(raw);
    const hex = std.mem.trim(u8, raw, " \t\r\n");
    if (hex.len != 64) return error.InvalidKeyLength;
    var out: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, hex);
    if (!std.mem.eql(u8, path, path_opt orelse "")) alloc.free(@constCast(path));
    return out;
}

fn jU64(data: []const u8, key: []const u8) ?u64 {
    const pos = std.mem.indexOf(u8, data, key) orelse return null;
    var i = pos + key.len;
    while (i < data.len and (data[i] == ':' or data[i] == ' ' or data[i] == '"')) : (i += 1) {}
    const start = i;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseUnsigned(u64, data[start..i], 10) catch null;
}

fn jStr(data: []const u8, key: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, data, key) orelse return null;
    var i = pos + key.len;
    while (i < data.len and (data[i] == ':' or data[i] == ' ')) : (i += 1) {}
    if (i >= data.len or data[i] != '"') return null;
    i += 1;
    const end = std.mem.indexOfPos(u8, data, i, "\"") orelse return null;
    return data[i..end];
}
