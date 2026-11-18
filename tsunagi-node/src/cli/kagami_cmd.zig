const std = @import("std");
const compat = @import("compat");
const build_info = @import("../build_info.zig");
const cursor_mod = @import("../net/ledger/cursor.zig");
const lmdb_utxo = @import("../store/lmdb_utxo.zig");
const utxo_extract = @import("../ledger/utxo_extract.zig");
const snapshot_mod = @import("../kagami/snapshot.zig");

// ── KAGAMI 鏡 — Observability & Diagnostics ──────────────────────────
//
// Operator-facing diagnostic report. Read-only access to all data
// sources: cursor.json, LMDB UTxO store, propagation artifact,
// coverage.json. Never modifies state.

pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    const subcmd = args_it.next() orelse {
        printUsage();
        return 1;
    };

    if (std.mem.eql(u8, subcmd, "report")) {
        return runReport(alloc, args_it);
    }
    if (std.mem.eql(u8, subcmd, "stream")) {
        return runStream(alloc, args_it);
    }
    if (std.mem.eql(u8, subcmd, "json")) {
        return runJson(alloc, args_it);
    }

    std.debug.print("ERROR: unknown kagami subcommand: {s}\n", .{subcmd});
    printUsage();
    return 1;
}

fn printUsage() void {
    std.debug.print(
        \\Usage: tsunagi-node kagami <subcommand> [options]
        \\
        \\Subcommands:
        \\  report    Show node health and state report
        \\  stream    Live telemetry stream (repeating snapshot)
        \\  json      Machine-readable JSON snapshot
        \\
        \\Options:
        \\  --home <path>   TSUNAGI home directory
        \\  --net <network> Network name (mainnet, preview, preprod, sancho)
        \\  --lmdb <dir>    LMDB UTxO directory (or set TSUNAGI_LMDB)
        \\
    , .{});
}

fn runReport(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var home_path: ?[]const u8 = null;
    var net_name: ?[]const u8 = null;
    var lmdb_path: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--home")) {
            home_path = args_it.next() orelse {
                std.debug.print("ERROR: --home requires a path\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--net")) {
            net_name = args_it.next() orelse {
                std.debug.print("ERROR: --net requires a network name\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--lmdb")) {
            lmdb_path = args_it.next() orelse {
                std.debug.print("ERROR: --lmdb requires a path\n", .{});
                return 1;
            };
        } else {
            std.debug.print("ERROR: unknown flag: {s}\n", .{arg});
            return 1;
        }
    }

    // Resolve home
    var resolved_net: []const u8 = net_name orelse "(unknown)";
    const home = resolveHome(alloc, home_path, net_name, &resolved_net) orelse {
        std.debug.print("ERROR: cannot resolve home directory. Use --home or --net or set TSUNAGI_HOME.\n", .{});
        return 1;
    };

    // Resolve LMDB path: --lmdb flag > TSUNAGI_LMDB env
    const lmdb_dir: ?[]const u8 = lmdb_path orelse
        (compat.getEnvVarOwned(alloc, "TSUNAGI_LMDB") catch null);

    const out = compat.fs.stdoutWriter();
    printReport(alloc, out, home, resolved_net, lmdb_dir) catch |err| {
        std.debug.print("ERROR: report failed: {s}\n", .{@errorName(err)});
        return 2;
    };
    return 0;
}

fn printReport(alloc: std.mem.Allocator, writer: anytype, home: []const u8, net: []const u8, lmdb_dir: ?[]const u8) !void {
    const now = compat.timestamp();

    // ── Header ──
    try writer.print("TSUNAGI KAGAMI — Node Health Report\n", .{});
    try writer.print("====================================\n", .{});
    try writer.print("version     : {s} ({s}) {s} {s} zig={s}\n", .{
        build_info.info.git_tag,
        build_info.info.git_commit,
        build_info.info.build_mode,
        build_info.info.target_triple,
        build_info.info.zig_version,
    });
    try writer.print("network     : {s}\n", .{net});
    try writer.print("home        : {s}\n", .{home});
    try writer.print("\n", .{});

    // ── Chain Tip ──
    try writer.print("Chain Tip\n", .{});
    const cursor_path = std.fmt.allocPrint(alloc, "{s}/cursor.json", .{home}) catch null;
    defer if (cursor_path) |p| alloc.free(p);

    if (cursor_path) |cp| {
        if (cursor_mod.loadOrInit(alloc, cp)) |cur| {
            try writer.print("  slot          : {d}\n", .{cur.slot});
            try writer.print("  block_no      : {d}\n", .{cur.block_no});
            try writer.print("  tip_hash      : {s}...\n", .{cur.tip_hash_hex[0..16]});
            if (cur.updated_unix > 0) {
                const age = now - cur.updated_unix;
                try writer.print("  last_update   : {d}s ago\n", .{age});
            } else {
                try writer.print("  last_update   : (never)\n", .{});
            }
            try writer.print("  roll_forward  : {d}\n", .{cur.roll_forward_count});
            try writer.print("  roll_backward : {d}\n", .{cur.roll_backward_count});
        } else |_| {
            try writer.print("  (not available — cursor.json read error)\n", .{});
        }
    } else {
        try writer.print("  (not available)\n", .{});
    }
    try writer.print("\n", .{});

    // ── UTxO State ──
    try writer.print("UTxO State\n", .{});
    if (lmdb_dir) |dir| {
        const dir_z = alloc.dupeZ(u8, dir) catch null;
        defer if (dir_z) |z| alloc.free(z);
        if (dir_z) |z| {
            if (lmdb_utxo.LmdbUtxo.open(z)) |store_val| {
                var store = store_val;
                defer store.close();
                const count = utxo_extract.countUtxos(&store);
                try writer.print("  count         : {d}\n", .{count});
                if (utxo_extract.utxoDigest(&store)) |digest| {
                    try writer.print("  digest        : {x}...\n", .{
                        digest[0..8],
                    });
                } else {
                    try writer.print("  digest        : (unavailable)\n", .{});
                }
            } else |_| {
                try writer.print("  (not available — LMDB open failed)\n", .{});
            }
        } else {
            try writer.print("  (not available — allocation failed)\n", .{});
        }
    } else {
        try writer.print("  (not available — set TSUNAGI_LMDB or use --lmdb)\n", .{});
    }
    try writer.print("\n", .{});

    // ── Propagation ──
    try writer.print("Propagation\n", .{});
    const art_dir = std.fmt.allocPrint(alloc, "{s}/propagation_artifact", .{home}) catch null;
    defer if (art_dir) |p| alloc.free(p);

    if (art_dir) |ad| {
        const art_exists = blk: {
            compat.fs.cwd().access(ad, .{}) catch break :blk false;
            break :blk true;
        };
        if (!art_exists) {
            try writer.print("  artifact_dir  : absent\n", .{});
        } else {
            try writer.print("  artifact_dir  : present\n", .{});

            // Fragment coverage from coverage.json
            const cov_path = std.fmt.allocPrint(alloc, "{s}/coverage.json", .{ad}) catch null;
            defer if (cov_path) |p| alloc.free(p);
            if (cov_path) |cp| {
                printCoverageFromJson(alloc, writer, cp) catch {};
            }

            // Artifact age from meta.json
            const meta_path = std.fmt.allocPrint(alloc, "{s}/meta.json", .{ad}) catch null;
            defer if (meta_path) |p| alloc.free(p);
            if (meta_path) |mp| {
                printArtifactAge(alloc, writer, mp, now) catch {};
            }
        }
    } else {
        try writer.print("  (not available)\n", .{});
    }
}

fn printCoverageFromJson(alloc: std.mem.Allocator, writer: anytype, path: []const u8) !void {
    const data = compat.fs.cwd().readFileAlloc(path, alloc, 4096) catch {
        try writer.print("  coverage      : (coverage.json not found)\n", .{});
        return;
    };
    defer alloc.free(data);

    // Simple JSON field extraction (no full parser needed)
    const depth = parseJsonU64(data, "usable_contiguous_depth");
    const oldest = parseJsonU64(data, "intersectable_oldest_slot");
    const newest = parseJsonU64(data, "intersectable_newest_slot");
    const breaks = parseJsonU64(data, "break_count");
    const files = parseJsonU64(data, "numeric_file_count");

    if (oldest != null and newest != null) {
        try writer.print("  intersectable : [{d}..{d}]\n", .{ oldest.?, newest.? });
    }
    if (depth) |d| {
        try writer.print("  usable_depth  : {d}\n", .{d});
    }
    if (files) |f| {
        try writer.print("  numeric_files : {d}\n", .{f});
    }
    if (breaks) |b| {
        try writer.print("  breaks        : {d}\n", .{b});
    }
}

fn printArtifactAge(alloc: std.mem.Allocator, writer: anytype, path: []const u8, now: i64) !void {
    const data = compat.fs.cwd().readFileAlloc(path, alloc, 4096) catch {
        try writer.print("  artifact_age  : (meta.json not found)\n", .{});
        return;
    };
    defer alloc.free(data);

    const unix_val = parseJsonU64(data, "unix") orelse {
        try writer.print("  artifact_age  : (no unix field)\n", .{});
        return;
    };

    const unix_i64: i64 = @intCast(unix_val);
    const age = now - unix_i64;
    if (age < 0) {
        try writer.print("  artifact_age  : (clock skew)\n", .{});
    } else if (age < 60) {
        try writer.print("  artifact_age  : {d}s\n", .{age});
    } else if (age < 3600) {
        try writer.print("  artifact_age  : {d}m {d}s\n", .{ @divFloor(age, 60), @mod(age, 60) });
    } else {
        try writer.print("  artifact_age  : {d}h {d}m\n", .{ @divFloor(age, 3600), @divFloor(@mod(age, 3600), 60) });
    }
}

/// Extract a u64 value for a given JSON key from a flat JSON object.
/// Simple substring search — works for single-level {"key":value,...} format.
fn parseJsonU64(data: []const u8, key: []const u8) ?u64 {
    // Search for "key": pattern
    var pos: usize = 0;
    while (pos + key.len + 3 < data.len) {
        if (data[pos] == '"') {
            const key_start = pos + 1;
            if (key_start + key.len < data.len and
                std.mem.eql(u8, data[key_start .. key_start + key.len], key) and
                data[key_start + key.len] == '"')
            {
                // Found "key" — skip to colon and parse number
                var i = key_start + key.len + 1;
                while (i < data.len and (data[i] == ' ' or data[i] == ':' or data[i] == '\t')) i += 1;
                const num_start = i;
                while (i < data.len and data[i] >= '0' and data[i] <= '9') i += 1;
                if (i > num_start) {
                    return std.fmt.parseUnsigned(u64, data[num_start..i], 10) catch null;
                }
                return null;
            }
        }
        pos += 1;
    }
    return null;
}

// ── Home resolution (simplified from guardian_cmd.zig pattern) ──

fn resolveHome(alloc: std.mem.Allocator, home_path: ?[]const u8, net_name: ?[]const u8, resolved_net: *[]const u8) ?[]const u8 {
    // 1) Explicit --home
    if (home_path) |hp| {
        if (net_name == null) {
            resolved_net.* = inferNetFromPath(hp);
        }
        return hp;
    }

    // 2) --net -> ~/tsunagi-home-<net> (explicit network intent beats env)
    if (net_name) |net| {
        if (homeFromNet(alloc, net)) |path| return path;
    }

    // 3) TSUNAGI_HOME env (ambient fallback)
    if (compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null) |env_home| {
        if (net_name == null) {
            resolved_net.* = inferNetFromPath(env_home);
        }
        return env_home;
    }

    return null;
}

fn inferNetFromPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, "-preview")) return "preview";
    if (std.mem.endsWith(u8, path, "-mainnet")) return "mainnet";
    if (std.mem.endsWith(u8, path, "-preprod")) return "preprod";
    if (std.mem.endsWith(u8, path, "-sancho")) return "sancho";
    if (std.mem.endsWith(u8, path, "tsunagi-home")) return "mainnet";
    return "(unknown)";
}

fn homeFromNet(alloc: std.mem.Allocator, net: []const u8) ?[]const u8 {
    const user_home = compat.getEnvVarOwned(alloc, "HOME") catch return null;
    defer alloc.free(user_home);
    const path = std.fmt.allocPrint(alloc, "{s}/tsunagi-home-{s}", .{ user_home, net }) catch return null;
    compat.fs.cwd().access(path, .{}) catch {
        alloc.free(path);
        return null;
    };
    return path;
}

// ── kagami json ─────────────────────────────────────────────────────

fn runJson(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var home_path: ?[]const u8 = null;
    var net_name: ?[]const u8 = null;
    var lmdb_path: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--home")) {
            home_path = args_it.next() orelse {
                std.debug.print("ERROR: --home requires a path\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--net")) {
            net_name = args_it.next() orelse {
                std.debug.print("ERROR: --net requires a network name\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--lmdb")) {
            lmdb_path = args_it.next() orelse {
                std.debug.print("ERROR: --lmdb requires a path\n", .{});
                return 1;
            };
        } else {
            std.debug.print("ERROR: unknown flag: {s}\n", .{arg});
            return 1;
        }
    }

    // Resolve home
    var resolved_net: []const u8 = net_name orelse "(unknown)";
    const home = resolveHome(alloc, home_path, net_name, &resolved_net) orelse {
        std.debug.print("ERROR: cannot resolve home directory. Use --home or --net or set TSUNAGI_HOME.\n", .{});
        return 1;
    };

    // Resolve LMDB path: --lmdb flag > TSUNAGI_LMDB env
    const lmdb_dir: ?[]const u8 = lmdb_path orelse
        (compat.getEnvVarOwned(alloc, "TSUNAGI_LMDB") catch null);

    const snap = snapshot_mod.collect(alloc, .{
        .home = home,
        .lmdb_path = lmdb_dir,
        .now = compat.timestamp(),
    }) catch {
        std.debug.print("ERROR: snapshot collection failed\n", .{});
        return 2;
    };

    const out = compat.fs.stdoutWriter();
    writeJson(out, snap, resolved_net, home) catch |err| {
        std.debug.print("ERROR: JSON write failed: {s}\n", .{@errorName(err)});
        return 2;
    };
    return 0;
}

fn writeJson(writer: anytype, snap: snapshot_mod.Snapshot, net: []const u8, home: []const u8) !void {
    try writer.print("{{\n", .{});

    // Top-level
    try writer.print("  \"version\": \"{s}\",\n", .{build_info.info.git_tag});
    try writer.print("  \"network\": \"{s}\",\n", .{net});
    try writer.print("  \"home\": \"{s}\",\n", .{home});

    // chain_tip
    try writer.print("\n  \"chain_tip\": {{\n", .{});
    try writeJsonOptU64(writer, "slot", snap.chain_tip_slot, true);
    try writeJsonOptU64(writer, "block_no", snap.chain_tip_block_no, true);
    try writeJsonOptI64(writer, "tip_age_seconds", snap.tip_age_seconds, true);
    try writeJsonOptU64(writer, "roll_forward", snap.roll_forward_count, true);
    try writeJsonOptU64(writer, "roll_backward", snap.roll_backward_count, false);
    try writer.print("  }},\n", .{});

    // propagation
    try writer.print("\n  \"propagation\": {{\n", .{});
    try writer.print("    \"artifact_present\": {s},\n", .{if (snap.artifact_present) "true" else "false"});
    try writeJsonOptI64(writer, "artifact_age_seconds", snap.artifact_age_seconds, true);
    // fragment_range as array or null
    if (snap.intersectable_oldest_slot != null and snap.intersectable_newest_slot != null) {
        try writer.print("    \"fragment_range\": [{d},{d}],\n", .{
            snap.intersectable_oldest_slot.?,
            snap.intersectable_newest_slot.?,
        });
    } else {
        try writer.print("    \"fragment_range\": null,\n", .{});
    }
    try writeJsonOptU64(writer, "usable_depth", snap.usable_depth, true);
    try writeJsonOptU64(writer, "break_count", snap.break_count, true);
    try writeJsonOptI64(writer, "tip_artifact_gap_slots", snap.tip_artifact_gap_slots, false);
    try writer.print("  }},\n", .{});

    // utxo
    try writer.print("\n  \"utxo\": {{\n", .{});
    try writeJsonOptU64(writer, "count", snap.utxo_count, false);
    try writer.print("  }},\n", .{});

    // status
    const status_str: []const u8 = switch (snap.status) {
        .healthy => "HEALTHY",
        .warn => "WARN",
        .critical => "CRITICAL",
    };
    try writer.print("\n  \"status\": \"{s}\"\n", .{status_str});

    try writer.print("}}\n", .{});
}

fn writeJsonOptU64(writer: anytype, key: []const u8, val: ?u64, trailing_comma: bool) !void {
    const comma: []const u8 = if (trailing_comma) "," else "";
    if (val) |v| {
        try writer.print("    \"{s}\": {d}{s}\n", .{ key, v, comma });
    } else {
        try writer.print("    \"{s}\": null{s}\n", .{ key, comma });
    }
}

fn writeJsonOptI64(writer: anytype, key: []const u8, val: ?i64, trailing_comma: bool) !void {
    const comma: []const u8 = if (trailing_comma) "," else "";
    if (val) |v| {
        try writer.print("    \"{s}\": {d}{s}\n", .{ key, v, comma });
    } else {
        try writer.print("    \"{s}\": null{s}\n", .{ key, comma });
    }
}

// ── kagami stream ───────────────────────────────────────────────────

fn runStream(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var home_path: ?[]const u8 = null;
    var net_name: ?[]const u8 = null;
    var lmdb_path: ?[]const u8 = null;
    var interval_secs: u64 = 1;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--home")) {
            home_path = args_it.next() orelse {
                std.debug.print("ERROR: --home requires a path\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--net")) {
            net_name = args_it.next() orelse {
                std.debug.print("ERROR: --net requires a network name\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--lmdb")) {
            lmdb_path = args_it.next() orelse {
                std.debug.print("ERROR: --lmdb requires a path\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--interval")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --interval requires a number\n", .{});
                return 1;
            };
            interval_secs = std.fmt.parseUnsigned(u64, val, 10) catch {
                std.debug.print("ERROR: invalid --interval: {s}\n", .{val});
                return 1;
            };
            if (interval_secs == 0) interval_secs = 1;
        } else {
            std.debug.print("ERROR: unknown flag: {s}\n", .{arg});
            return 1;
        }
    }

    // Resolve home
    var resolved_net: []const u8 = net_name orelse "(unknown)";
    const home = resolveHome(alloc, home_path, net_name, &resolved_net) orelse {
        std.debug.print("ERROR: cannot resolve home directory. Use --home or --net or set TSUNAGI_HOME.\n", .{});
        return 1;
    };

    // Resolve LMDB path: --lmdb flag > TSUNAGI_LMDB env
    const lmdb_dir: ?[]const u8 = lmdb_path orelse
        (compat.getEnvVarOwned(alloc, "TSUNAGI_LMDB") catch null);

    const out = compat.fs.stdoutWriter();

    // Print header once
    out.print("TSUNAGI KAGAMI STREAM\n", .{}) catch {};
    out.print("=====================\n", .{}) catch {};
    out.print("network     : {s}\n", .{resolved_net}) catch {};
    out.print("home        : {s}\n", .{home}) catch {};
    out.print("interval    : {d}s\n", .{interval_secs}) catch {};

    // Stream loop
    while (true) {
        out.print("\n", .{}) catch {};

        const snap = snapshot_mod.collect(alloc, .{
            .home = home,
            .lmdb_path = lmdb_dir,
            .now = compat.timestamp(),
        }) catch {
            out.print("(snapshot collection failed)\n", .{}) catch {};
            compat.sleep(interval_secs * std.time.ns_per_s);
            continue;
        };

        // Chain tip
        if (snap.chain_tip_slot) |slot| {
            out.print("slot            : {d}\n", .{slot}) catch {};
        } else {
            out.print("slot            : (unavailable)\n", .{}) catch {};
        }
        if (snap.chain_tip_block_no) |bn| {
            out.print("block_no        : {d}\n", .{bn}) catch {};
        } else {
            out.print("block_no        : (unavailable)\n", .{}) catch {};
        }
        if (snap.tip_age_seconds) |age| {
            out.print("tip_age         : {d}s\n", .{age}) catch {};
        } else {
            out.print("tip_age         : (unavailable)\n", .{}) catch {};
        }
        if (snap.roll_forward_count) |rf| {
            out.print("roll_forward    : {d}\n", .{rf}) catch {};
        }
        if (snap.roll_backward_count) |rb| {
            out.print("roll_backward   : {d}\n", .{rb}) catch {};
        }

        // Propagation
        if (snap.artifact_age_seconds) |age| {
            out.print("artifact_age    : {d}s\n", .{age}) catch {};
        } else if (snap.artifact_present) {
            out.print("artifact_age    : (unavailable)\n", .{}) catch {};
        } else {
            out.print("artifact_age    : (no artifact)\n", .{}) catch {};
        }
        if (snap.intersectable_oldest_slot != null and snap.intersectable_newest_slot != null) {
            out.print("fragment_range  : [{d}..{d}]\n", .{
                snap.intersectable_oldest_slot.?,
                snap.intersectable_newest_slot.?,
            }) catch {};
        }
        if (snap.usable_depth) |depth| {
            out.print("usable_depth    : {d}\n", .{depth}) catch {};
        }
        if (snap.break_count) |bc| {
            out.print("break_count     : {d}\n", .{bc}) catch {};
        }
        if (snap.tip_artifact_gap_slots) |gap| {
            out.print("tip_gap_slots   : {d}\n", .{gap}) catch {};
        }

        // UTxO
        if (snap.utxo_count) |count| {
            out.print("utxo_count      : {d}\n", .{count}) catch {};
        }

        // Status
        const status_str: []const u8 = switch (snap.status) {
            .healthy => "HEALTHY",
            .warn => "WARN",
            .critical => "CRITICAL",
        };
        out.print("status          : {s}\n", .{status_str}) catch {};

        out.print("\n--- refresh ---\n", .{}) catch {};

        compat.sleep(interval_secs * std.time.ns_per_s);
    }
}

fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    var file = compat.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    return file.readToEndAlloc(alloc, 1024 * 1024) catch null;
}
