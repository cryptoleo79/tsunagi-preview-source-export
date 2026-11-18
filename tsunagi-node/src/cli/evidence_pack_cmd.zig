const std = @import("std");
const compat = @import("compat");
const Sha256 = std.crypto.hash.sha2.Sha256;
const tsf = @import("../store/tsf.zig");
const build_info = @import("../build_info.zig");
const snapshot_sign = @import("../store/snapshot_sign.zig");

// ── Evidence Pack — offline legitimacy bundle (v3.7.0) ──────────────
//
// Produces a deterministic, shareable directory containing verification
// results from existing harnesses: consensus-align, readiness-sim,
// forge-sim, ledger-harness, guardian deploy-check.
//
// Offline-by-default. Deterministic. Fail-fast on required checks.
// No forging, no broadcast, no chain injection.
//
// Exit codes: 0=PASS, 2=FAIL, 3=missing files, 4=parse errors.

const Config = struct {
    home: []const u8,
    net: []const u8,
    out_base: []const u8,
    limit: u32,
    strict: bool,
    port: ?u16,
    consensus_vectors: ?[]const u8,
    readiness_vectors: ?[]const u8,
    header_only: bool = false,
};

const CaptureResult = struct {
    exit_code: u8,
    len: usize,
};

// ── pub fn run ──────────────────────────────────────────────────────

pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var home_path: ?[]const u8 = null;
    var net: ?[]const u8 = null;
    var out_base: []const u8 = "/tmp";
    var limit: u32 = 50;
    var strict = false;
    var port: ?u16 = null;
    var consensus_vectors: ?[]const u8 = null;
    var readiness_vectors: ?[]const u8 = null;
    var cold_start = false;
    var snapshot: ?[]const u8 = null;
    var snapshot_proof = false;
    var file_arg: ?[]const u8 = null;
    var keydir_arg: ?[]const u8 = null;
    var notarize_gpg = false;
    var gpg_key_id: ?[]const u8 = null;
    var gpg_homedir: ?[]const u8 = null;
    var gpg_armor = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--home")) {
            home_path = args_it.next() orelse {
                std.debug.print("ERROR: --home requires a path\n", .{});
                return 4;
            };
        } else if (std.mem.eql(u8, arg, "--net")) {
            net = args_it.next() orelse {
                std.debug.print("ERROR: --net requires a value\n", .{});
                return 4;
            };
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_base = args_it.next() orelse {
                std.debug.print("ERROR: --out requires a path\n", .{});
                return 4;
            };
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --limit requires a number\n", .{});
                return 4;
            };
            limit = std.fmt.parseInt(u32, val, 10) catch {
                std.debug.print("ERROR: invalid --limit: {s}\n", .{val});
                return 4;
            };
        } else if (std.mem.eql(u8, arg, "--strict")) {
            strict = true;
        } else if (std.mem.eql(u8, arg, "--port")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --port requires a number\n", .{});
                return 4;
            };
            port = std.fmt.parseInt(u16, val, 10) catch {
                std.debug.print("ERROR: invalid --port: {s}\n", .{val});
                return 4;
            };
        } else if (std.mem.eql(u8, arg, "--consensus-vectors")) {
            consensus_vectors = args_it.next() orelse {
                std.debug.print("ERROR: --consensus-vectors requires a path\n", .{});
                return 4;
            };
        } else if (std.mem.eql(u8, arg, "--readiness-vectors")) {
            readiness_vectors = args_it.next() orelse {
                std.debug.print("ERROR: --readiness-vectors requires a path\n", .{});
                return 4;
            };
        } else if (std.mem.eql(u8, arg, "--cold-start")) {
            cold_start = true;
        } else if (std.mem.eql(u8, arg, "--snapshot-proof")) {
            snapshot_proof = true;
        } else if (std.mem.eql(u8, arg, "--file")) {
            file_arg = args_it.next() orelse {
                std.debug.print("ERROR: --file requires a path\n", .{});
                return 4;
            };
        } else if (std.mem.eql(u8, arg, "--keydir")) {
            keydir_arg = args_it.next() orelse {
                std.debug.print("ERROR: --keydir requires a path\n", .{});
                return 4;
            };
        } else if (std.mem.eql(u8, arg, "--snapshot")) {
            snapshot = args_it.next() orelse {
                std.debug.print("ERROR: --snapshot requires a path\n", .{});
                return 4;
            };
        } else if (std.mem.eql(u8, arg, "--notarize-gpg")) {
            notarize_gpg = true;
        } else if (std.mem.eql(u8, arg, "--gpg-key")) {
            gpg_key_id = args_it.next() orelse {
                std.debug.print("ERROR: --gpg-key requires a value\n", .{});
                return 4;
            };
        } else if (std.mem.eql(u8, arg, "--gpg-homedir")) {
            gpg_homedir = args_it.next() orelse {
                std.debug.print("ERROR: --gpg-homedir requires a path\n", .{});
                return 4;
            };
        } else if (std.mem.eql(u8, arg, "--gpg-armor")) {
            gpg_armor = true;
        } else {
            std.debug.print("ERROR: unknown flag: {s}\n", .{arg});
            return 4;
        }
    }

    // Snapshot-proof early dispatch (bypasses --home requirement)
    if (snapshot_proof) {
        const file = file_arg orelse {
            std.debug.print("ERROR: --snapshot-proof requires --file\n", .{});
            return 3;
        };
        const kd = keydir_arg orelse {
            std.debug.print("ERROR: --snapshot-proof requires --keydir\n", .{});
            return 3;
        };
        const net_val = net orelse {
            std.debug.print("ERROR: --net is required for --snapshot-proof\n", .{});
            return 4;
        };
        return runSnapshotProofMode(alloc, net_val, out_base, strict, file, kd);
    }

    // Cold-start early dispatch (bypasses --home requirement)
    if (cold_start) {
        const snap = snapshot orelse {
            std.debug.print("ERROR: --cold-start requires --snapshot\n", .{});
            return 3;
        };
        const net_val = net orelse {
            std.debug.print("ERROR: --net is required for --cold-start\n", .{});
            return 4;
        };
        return runColdStartEnvelope(alloc, net_val, out_base, strict, snap);
    }

    // Resolve home
    var home_owned = false;
    const home = if (home_path) |hp| hp else blk: {
        const env_home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
        if (env_home) |h| {
            home_owned = true;
            break :blk h;
        }
        break :blk @as(?[]const u8, null);
    };
    if (home == null) {
        std.debug.print("ERROR: --home or TSUNAGI_HOME required\n", .{});
        return 4;
    }
    defer if (home_owned) alloc.free(home.?);

    // Validate net
    const net_str = net orelse {
        std.debug.print("ERROR: --net is required (preview|preprod|mainnet|sancho)\n", .{});
        return 4;
    };
    if (!std.mem.eql(u8, net_str, "preview") and
        !std.mem.eql(u8, net_str, "preprod") and
        !std.mem.eql(u8, net_str, "mainnet") and
        !std.mem.eql(u8, net_str, "sancho"))
    {
        std.debug.print("ERROR: --net must be preview|preprod|mainnet|sancho\n", .{});
        return 4;
    }

    // Self-exe path
    var self_exe_buf: [4096]u8 = undefined;
    const self_exe = compat.selfExePath(&self_exe_buf) catch {
        std.debug.print("ERROR: cannot determine self executable path\n", .{});
        return 3;
    };

    // Create evidence directory
    const unix_now: u64 = @intCast(@max(@as(i64, 0), compat.timestamp()));
    var dir_name_buf: [256]u8 = undefined;
    const dir_name = std.fmt.bufPrint(&dir_name_buf, "tsunagi_evidence_{s}_{d}", .{ net_str, unix_now }) catch {
        std.debug.print("ERROR: dir name too long\n", .{});
        return 4;
    };

    const evidence_dir = std.fmt.allocPrint(alloc, "{s}/{s}", .{ out_base, dir_name }) catch {
        std.debug.print("ERROR: alloc failed\n", .{});
        return 4;
    };
    defer alloc.free(evidence_dir);

    compat.fs.cwd().makePath(evidence_dir) catch {
        std.debug.print("ERROR: cannot create {s}\n", .{evidence_dir});
        return 3;
    };

    var checks_buf: [512]u8 = undefined;
    const checks_dir = std.fmt.bufPrint(&checks_buf, "{s}/checks", .{evidence_dir}) catch return 4;
    compat.fs.cwd().makePath(checks_dir) catch {};

    var inputs_buf: [512]u8 = undefined;
    const inputs_dir = std.fmt.bufPrint(&inputs_buf, "{s}/inputs", .{evidence_dir}) catch return 4;
    compat.fs.cwd().makePath(inputs_dir) catch {};

    var cfg = Config{
        .home = home.?,
        .net = net_str,
        .out_base = out_base,
        .limit = limit,
        .strict = strict,
        .port = port,
        .consensus_vectors = consensus_vectors,
        .readiness_vectors = readiness_vectors,
    };

    // ── Orchestration ───────────────────────────────────────────────

    // 1) Version
    const version_str = detectVersion(alloc, self_exe, evidence_dir);
    defer if (version_str) |vs| alloc.free(vs);

    // 2) Guardian deploy-check (optional)
    var guardian_result: []const u8 = "SKIP";
    if (cfg.port) |p| {
        const grc = runGuardianDeployCheck(alloc, self_exe, p, evidence_dir);
        if (grc == 0) {
            guardian_result = "PASS";
        } else {
            guardian_result = "FAIL";
            if (cfg.strict) {
                std.debug.print("FAIL: guardian deploy-check\n", .{});
            }
        }
    }

    // 3) Consensus vectors
    const cons_gen = generateConsensusVectors(alloc, &cfg, evidence_dir) orelse {
        if (cfg.strict) {
            std.debug.print("ERROR: cannot generate consensus vectors\n", .{});
            return 3;
        }
        std.debug.print("WARN: consensus vectors unavailable, skipping\n", .{});
        return writeFailAndExit(alloc, evidence_dir, &cfg, unix_now, version_str, guardian_result);
    };
    defer alloc.free(cons_gen.path);
    if (cons_gen.used_alignment) cfg.header_only = true;

    // 4) Consensus-align (required)
    const consensus_exit = runConsensusAlign(alloc, self_exe, cons_gen.path, evidence_dir);
    const consensus_result: []const u8 = if (consensus_exit == 0) "PASS" else "FAIL";
    if (consensus_exit != 0) {
        std.debug.print("FAIL: consensus-align (exit {d})\n", .{consensus_exit});
    }

    // 5) Readiness vectors
    const read_gen = generateReadinessVectors(alloc, &cfg, evidence_dir) orelse {
        if (cfg.strict) {
            std.debug.print("ERROR: cannot generate readiness vectors\n", .{});
            return 3;
        }
        std.debug.print("WARN: readiness vectors unavailable\n", .{});
        return writeFailAndExit(alloc, evidence_dir, &cfg, unix_now, version_str, guardian_result);
    };
    defer alloc.free(read_gen.path);
    if (read_gen.used_alignment) cfg.header_only = true;

    // 6) Readiness-sim dual run (required)
    var rolling_digest: [64]u8 = .{0} ** 64;
    var has_digest = false;
    const readiness_exit = runReadinessSimDual(alloc, self_exe, read_gen.path, evidence_dir, &rolling_digest, &has_digest, cfg.header_only);
    const readiness_result: []const u8 = if (readiness_exit == 0) "PASS" else "FAIL";
    if (readiness_exit != 0) {
        std.debug.print("FAIL: readiness-sim (exit {d})\n", .{readiness_exit});
    }

    // 7) Forge-sim (optional)
    var forge_result: []const u8 = "SKIP";
    {
        const forge_exit = runForgeSim(alloc, self_exe, cfg.home, evidence_dir);
        if (forge_exit) |fe| {
            forge_result = if (fe == 0) "PASS" else "FAIL";
        }
    }

    // 8) Ledger digest
    var ledger_result: []const u8 = "SKIP";
    {
        var lmdb_buf: [512]u8 = undefined;
        const lmdb_path = std.fmt.bufPrint(&lmdb_buf, "{s}/lmdb", .{cfg.home}) catch "";
        if (lmdb_path.len > 0) {
            const lmdb_exists = blk: {
                var d = compat.fs.cwd().openDir(lmdb_path, .{}) catch break :blk false;
                d.close();
                break :blk true;
            };

            if (lmdb_exists) {
                const ledger_exit = runLedgerDigest(alloc, self_exe, cfg.home, evidence_dir);
                ledger_result = if (ledger_exit == 0) "PASS" else "FAIL";
            } else if (cfg.strict) {
                ledger_result = "FAIL";
                std.debug.print("FAIL: lmdb/ not found (--strict)\n", .{});
            }
        }
    }

    // 9) Zero-secrets scan
    if (!scanForSecrets(alloc, evidence_dir, 5 * 1024 * 1024)) {
        std.debug.print("FAIL: zero-secrets scan failed (forbidden files in evidence dir)\n", .{});
        return 2;
    }

    // 10) Determine overall
    const required_pass = (consensus_exit == 0) and (readiness_exit == 0);
    const ledger_ok = std.mem.eql(u8, ledger_result, "PASS") or std.mem.eql(u8, ledger_result, "SKIP");
    const overall_pass = required_pass and ledger_ok;

    // 11) Manifest
    writeManifest(alloc, evidence_dir, &cfg, unix_now, version_str, consensus_result, readiness_result, forge_result, ledger_result, guardian_result, &rolling_digest, has_digest);

    // 11b) Build identity (v4.2.0 Layer A)
    emitBuildInfo(evidence_dir);

    // 12) SHA256SUMS
    writeSha256Sums(alloc, evidence_dir);

    // 12b) GPG notarization (optional)
    if (notarize_gpg) {
        const notarize_exit = notarizeGpgSign(alloc, evidence_dir, gpg_armor, gpg_key_id, gpg_homedir);
        if (notarize_exit != 0) return notarize_exit;
    }

    // 13) Summary
    std.debug.print("\n=== Evidence Pack ===\n", .{});
    std.debug.print("overall: {s}\n", .{if (overall_pass) "PASS" else "FAIL"});
    if (has_digest) {
        std.debug.print("rolling_digest: {s}\n", .{rolling_digest[0..16]});
    }
    std.debug.print("consensus_align: {s}\n", .{consensus_result});
    std.debug.print("readiness_sim: {s}\n", .{readiness_result});
    std.debug.print("forge_sim: {s}\n", .{forge_result});
    std.debug.print("ledger_digest: {s}\n", .{ledger_result});
    std.debug.print("guardian_deploy_check: {s}\n", .{guardian_result});
    // Last line: evidence dir path (runbook extracts this) — stdout for script capture
    const stdout = compat.fs.stdoutWriter();
    stdout.print("{s}\n", .{evidence_dir}) catch {};

    if (overall_pass) return 0;
    return 2;
}

fn writeFailAndExit(alloc: std.mem.Allocator, evidence_dir: []const u8, cfg: *const Config, unix_now: u64, version_str: ?[]const u8, guardian_result: []const u8) u8 {
    writeManifest(alloc, evidence_dir, cfg, unix_now, version_str, "FAIL", "FAIL", "SKIP", "SKIP", guardian_result, &(.{0} ** 64), false);
    emitBuildInfo(evidence_dir);
    writeSha256Sums(alloc, evidence_dir);
    std.debug.print("\n=== Evidence Pack ===\n", .{});
    std.debug.print("overall: FAIL\n", .{});
    const stdout = compat.fs.stdoutWriter();
    stdout.print("{s}\n", .{evidence_dir}) catch {};
    return 2;
}

// ── Process helpers ─────────────────────────────────────────────────

fn runCaptureStderrWithExit(alloc: std.mem.Allocator, argv: []const []const u8, buf: []u8) ?CaptureResult {
    var child = compat.Child.init(argv, alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    child.spawn() catch return null;
    var total: usize = 0;
    if (child.stderr) |se| {
        while (total < buf.len) {
            const n = se.read(buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
    }
    const term = child.wait() catch return null;
    const exit_code: u8 = switch (term) {
        .exited => |code| code,
        else => 255,
    };
    return .{ .exit_code = exit_code, .len = total };
}

fn spawnAndWaitExit(alloc: std.mem.Allocator, argv: []const []const u8) u8 {
    var child = compat.Child.init(argv, alloc);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    const term = child.spawnAndWait() catch return 255;
    return switch (term) {
        .exited => |code| code,
        else => 255,
    };
}

fn spawnWithEnvAndWait(alloc: std.mem.Allocator, argv: []const []const u8, env_key: []const u8, env_val: []const u8) u8 {
    var child = compat.Child.init(argv, alloc);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;

    // Build env map with the extra variable
    var env_map = compat.EnvMap.init(alloc);
    defer env_map.deinit();
    // Copy current env
    if (compat.getEnvMap(alloc)) |sysenv_val| {
        var sysenv = sysenv_val;
        defer sysenv.deinit();
        var it = sysenv.iterator();
        while (it.next()) |entry| {
            env_map.put(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
    } else |_| {}
    env_map.put(env_key, env_val) catch {};
    child.env_map = &env_map;

    const term = child.spawnAndWait() catch return 255;
    return switch (term) {
        .exited => |code| code,
        else => 255,
    };
}

fn writeFileContent(path: []const u8, content: []const u8) bool {
    var f = compat.fs.cwd().createFile(path, .{ .truncate = true }) catch return false;
    defer f.close();
    f.writeAll(content) catch return false;
    return true;
}

fn copyFile(alloc: std.mem.Allocator, src: []const u8, dst: []const u8) bool {
    _ = alloc;
    var inf = compat.fs.cwd().openFile(src, .{}) catch return false;
    defer inf.close();
    var outf = compat.fs.cwd().createFile(dst, .{ .truncate = true }) catch return false;
    defer outf.close();
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = inf.read(&buf) catch return false;
        if (n == 0) break;
        outf.writeAll(buf[0..n]) catch return false;
    }
    return true;
}

// ── Version detection ───────────────────────────────────────────────

fn detectVersion(alloc: std.mem.Allocator, self_exe: []const u8, evidence_dir: []const u8) ?[]const u8 {
    var buf: [512]u8 = undefined;
    const result = runCaptureStderrWithExit(alloc, &[_][]const u8{self_exe, "--version"}, &buf) orelse return null;
    const version_line = std.mem.trimEnd(u8, buf[0..result.len], "\n\r \t");

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/version.txt", .{evidence_dir}) catch return null;

    var content_buf: [1024]u8 = undefined;
    const content = std.fmt.bufPrint(&content_buf, "{s}\nevidence-pack v4.0.0\n", .{version_line}) catch return null;
    _ = writeFileContent(path, content);

    return alloc.dupe(u8, version_line) catch null;
}

// ── Vector generation ───────────────────────────────────────────────

const GenVectorsResult = struct {
    path: []const u8,
    used_alignment: bool,
};

fn generateConsensusVectors(alloc: std.mem.Allocator, cfg: *const Config, evidence_dir: []const u8) ?GenVectorsResult {
    var out_path_buf: [512]u8 = undefined;
    const out_path_slice = std.fmt.bufPrint(&out_path_buf, "{s}/inputs/consensus_vectors.jsonl", .{evidence_dir}) catch return null;
    const out_path = alloc.dupe(u8, out_path_slice) catch return null;

    // If user provided vectors, copy them
    if (cfg.consensus_vectors) |user_path| {
        if (copyFile(alloc, user_path, out_path)) return .{ .path = out_path, .used_alignment = false };
        alloc.free(out_path);
        return null;
    }

    // Find script
    const script = findScript(alloc, "tsunagi-node/scripts/gen_consensus_vectors.py") orelse {
        std.debug.print("WARN: gen_consensus_vectors.py not found\n", .{});
        alloc.free(out_path);
        return null;
    };
    defer alloc.free(script);

    // Build blocks dir path
    var blocks_buf: [512]u8 = undefined;
    const blocks_dir = std.fmt.bufPrint(&blocks_buf, "{s}/producer_dryrun/blocks", .{cfg.home}) catch {
        alloc.free(out_path);
        return null;
    };

    // Check if blocks dir exists
    const blocks_exists = blk: {
        var d = compat.fs.cwd().openDir(blocks_dir, .{}) catch break :blk false;
        d.close();
        break :blk true;
    };

    var limit_buf: [16]u8 = undefined;
    const limit_str = std.fmt.bufPrint(&limit_buf, "{d}", .{cfg.limit}) catch {
        alloc.free(out_path);
        return null;
    };

    if (blocks_exists) {
        const exit = spawnAndWaitExit(alloc, &[_][]const u8{
            "python3", script, "--mode", "header",
            "--artifacts-dir", blocks_dir,
            "--out", out_path,
            "--net", cfg.net,
            "--limit", limit_str,
        });

        if (exit != 0) {
            std.debug.print("WARN: gen_consensus_vectors.py exited {d}\n", .{exit});
            alloc.free(out_path);
            return null;
        }
        return .{ .path = out_path, .used_alignment = false };
    }

    // Alignment fallback: try regress/alignment/header_hash.jsonl
    var align_buf: [512]u8 = undefined;
    const align_path = std.fmt.bufPrint(&align_buf, "{s}/regress/alignment/header_hash.jsonl", .{cfg.home}) catch {
        alloc.free(out_path);
        return null;
    };
    const align_exists = if (compat.fs.cwd().statFile(align_path)) |_| true else |_| false;
    if (!align_exists) {
        std.debug.print("WARN: no blocks/ and no alignment file\n", .{});
        alloc.free(out_path);
        return null;
    }

    std.debug.print("INFO: using alignment fallback ({s})\n", .{align_path});
    const exit = spawnAndWaitExit(alloc, &[_][]const u8{
        "python3", script, "--mode", "alignment",
        "--alignment-file", align_path,
        "--out", out_path,
        "--net", cfg.net,
        "--limit", limit_str,
    });

    if (exit != 0) {
        std.debug.print("WARN: gen_consensus_vectors.py alignment exited {d}\n", .{exit});
        alloc.free(out_path);
        return null;
    }
    return .{ .path = out_path, .used_alignment = true };
}

fn generateReadinessVectors(alloc: std.mem.Allocator, cfg: *const Config, evidence_dir: []const u8) ?GenVectorsResult {
    var out_path_buf: [512]u8 = undefined;
    const out_path_slice = std.fmt.bufPrint(&out_path_buf, "{s}/inputs/readiness_vectors.jsonl", .{evidence_dir}) catch return null;
    const out_path = alloc.dupe(u8, out_path_slice) catch return null;

    // If user provided vectors, copy them
    if (cfg.readiness_vectors) |user_path| {
        if (copyFile(alloc, user_path, out_path)) return .{ .path = out_path, .used_alignment = false };
        alloc.free(out_path);
        return null;
    }

    // Find script
    const script = findScript(alloc, "scripts/gen_readiness_sim_vectors.py") orelse {
        std.debug.print("WARN: gen_readiness_sim_vectors.py not found\n", .{});
        alloc.free(out_path);
        return null;
    };
    defer alloc.free(script);

    // Build blocks dir path
    var blocks_buf: [512]u8 = undefined;
    const blocks_dir = std.fmt.bufPrint(&blocks_buf, "{s}/producer_dryrun/blocks", .{cfg.home}) catch {
        alloc.free(out_path);
        return null;
    };

    var limit_buf: [16]u8 = undefined;
    const limit_str = std.fmt.bufPrint(&limit_buf, "{d}", .{cfg.limit}) catch {
        alloc.free(out_path);
        return null;
    };

    // Check if blocks dir exists
    const blocks_exists = blk: {
        var d = compat.fs.cwd().openDir(blocks_dir, .{}) catch break :blk false;
        d.close();
        break :blk true;
    };

    if (blocks_exists) {
        const exit = spawnAndWaitExit(alloc, &[_][]const u8{
            "python3", script,
            "--net", cfg.net,
            "--mode", "blocks",
            "--blocks-dir", blocks_dir,
            "--out", out_path,
            "--limit", limit_str,
        });

        if (exit != 0) {
            std.debug.print("WARN: gen_readiness_sim_vectors.py exited {d}\n", .{exit});
            alloc.free(out_path);
            return null;
        }
        return .{ .path = out_path, .used_alignment = false };
    }

    // Alignment fallback
    var align_buf: [512]u8 = undefined;
    const align_path = std.fmt.bufPrint(&align_buf, "{s}/regress/alignment/header_hash.jsonl", .{cfg.home}) catch {
        alloc.free(out_path);
        return null;
    };
    const align_exists = if (compat.fs.cwd().statFile(align_path)) |_| true else |_| false;
    if (!align_exists) {
        std.debug.print("WARN: no blocks/ and no alignment file for readiness\n", .{});
        alloc.free(out_path);
        return null;
    }

    const exit = spawnAndWaitExit(alloc, &[_][]const u8{
        "python3", script,
        "--net", cfg.net,
        "--mode", "alignment",
        "--alignment-file", align_path,
        "--out", out_path,
        "--limit", limit_str,
    });

    if (exit != 0) {
        std.debug.print("WARN: gen_readiness_sim_vectors.py alignment exited {d}\n", .{exit});
        alloc.free(out_path);
        return null;
    }
    return .{ .path = out_path, .used_alignment = true };
}

fn findScript(alloc: std.mem.Allocator, rel_path: []const u8) ?[]const u8 {
    // Try known base directories
    const bases = [_][]const u8{
        "/home/tsunagi/src/tsunagi-follower",
    };
    for (bases) |base| {
        const full = std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, rel_path }) catch continue;
        if (compat.fs.cwd().statFile(full)) |_| {
            return full;
        } else |_| {
            alloc.free(full);
        }
    }
    // Try HOME env
    const home_env = compat.getEnvVarOwned(alloc, "HOME") catch null;
    if (home_env) |he| {
        defer alloc.free(he);
        const full = std.fmt.allocPrint(alloc, "{s}/src/tsunagi-follower/{s}", .{ he, rel_path }) catch return null;
        if (compat.fs.cwd().statFile(full)) |_| {
            return full;
        } else |_| {
            alloc.free(full);
        }
    }
    return null;
}

// ── Consensus-align check ───────────────────────────────────────────

fn runConsensusAlign(alloc: std.mem.Allocator, self_exe: []const u8, vectors_path: []const u8, evidence_dir: []const u8) u8 {
    var buf: [16384]u8 = undefined;
    const result = runCaptureStderrWithExit(alloc, &[_][]const u8{
        self_exe, "consensus-align", "--vectors", vectors_path, "--mode", "all",
    }, &buf) orelse return 3;

    // Write captured output
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/checks/consensus_align_summary.txt", .{evidence_dir}) catch return 4;
    _ = writeFileContent(path, buf[0..result.len]);

    return result.exit_code;
}

// ── Readiness-sim dual run ──────────────────────────────────────────

fn runReadinessSimDual(alloc: std.mem.Allocator, self_exe: []const u8, vectors_path: []const u8, evidence_dir: []const u8, out_digest: *[64]u8, has_digest: *bool, header_only: bool) u8 {
    // Run 1
    var r1_buf: [512]u8 = undefined;
    const r1_path = std.fmt.bufPrint(&r1_buf, "{s}/checks/readiness_sim_report_1.json", .{evidence_dir}) catch return 4;
    const exit1 = if (header_only)
        spawnAndWaitExit(alloc, &[_][]const u8{
            self_exe, "readiness-sim", "--vectors", vectors_path, "--out", r1_path, "--header-only",
        })
    else
        spawnAndWaitExit(alloc, &[_][]const u8{
            self_exe, "readiness-sim", "--vectors", vectors_path, "--out", r1_path,
        });

    // Run 2
    var r2_buf: [512]u8 = undefined;
    const r2_path = std.fmt.bufPrint(&r2_buf, "{s}/checks/readiness_sim_report_2.json", .{evidence_dir}) catch return 4;
    const exit2 = if (header_only)
        spawnAndWaitExit(alloc, &[_][]const u8{
            self_exe, "readiness-sim", "--vectors", vectors_path, "--out", r2_path, "--header-only",
        })
    else
        spawnAndWaitExit(alloc, &[_][]const u8{
            self_exe, "readiness-sim", "--vectors", vectors_path, "--out", r2_path,
        });

    if (exit1 != 0) return exit1;
    if (exit2 != 0) return exit2;

    // Extract digests from both reports
    var d1: [64]u8 = undefined;
    var d2: [64]u8 = undefined;
    const got1 = extractDigestFromReport(alloc, r1_path, &d1);
    const got2 = extractDigestFromReport(alloc, r2_path, &d2);

    if (got1 and got2) {
        if (!std.mem.eql(u8, &d1, &d2)) {
            std.debug.print("FAIL: readiness-sim digest mismatch between runs\n", .{});
            std.debug.print("  run1: {s}\n", .{&d1});
            std.debug.print("  run2: {s}\n", .{&d2});
            return 2;
        }
        @memcpy(out_digest, &d1);
        has_digest.* = true;
    } else if (got1) {
        @memcpy(out_digest, &d1);
        has_digest.* = true;
    }

    return 0;
}

fn extractDigestFromReport(alloc: std.mem.Allocator, report_path: []const u8, out: *[64]u8) bool {
    _ = alloc;
    var f = compat.fs.cwd().openFile(report_path, .{}) catch return false;
    defer f.close();
    var buf: [4096]u8 = undefined;
    const n = f.read(&buf) catch return false;
    const content = buf[0..n];

    // Search for "rolling_digest_hex":"<64hex>"
    const needle = "\"rolling_digest_hex\":\"";
    const idx = std.mem.indexOf(u8, content, needle) orelse return false;
    const start = idx + needle.len;
    if (start + 64 > content.len) return false;
    @memcpy(out, content[start..][0..64]);
    return true;
}

// ── Forge-sim (optional) ────────────────────────────────────────────

fn runForgeSim(alloc: std.mem.Allocator, self_exe: []const u8, home: []const u8, evidence_dir: []const u8) ?u8 {
    // Find newest dir in producer_dryrun/blocks/
    var blocks_path_buf: [512]u8 = undefined;
    const blocks_path = std.fmt.bufPrint(&blocks_path_buf, "{s}/producer_dryrun/blocks", .{home}) catch return null;

    const latest = findLatestDir(alloc, blocks_path) orelse return null;
    defer alloc.free(latest);

    var report_buf: [512]u8 = undefined;
    const report_path = std.fmt.bufPrint(&report_buf, "{s}/checks/forge_sim_report.json", .{evidence_dir}) catch return null;

    return spawnAndWaitExit(alloc, &[_][]const u8{
        self_exe, "forge-sim", "--dir", latest, "--out", report_path,
    });
}

fn findLatestDir(alloc: std.mem.Allocator, dir_path: []const u8) ?[]const u8 {
    var dir = compat.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return null;
    defer dir.close();
    var it = dir.iterate();
    var latest: ?[]u8 = null;
    while (it.next() catch null) |e| {
        if (e.kind != .directory) continue;
        if (latest == null) {
            latest = alloc.dupe(u8, e.name) catch continue;
        } else {
            if (std.mem.lessThan(u8, latest.?, e.name)) {
                alloc.free(latest.?);
                latest = alloc.dupe(u8, e.name) catch continue;
            }
        }
    }
    if (latest) |l| {
        const full = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, l }) catch {
            alloc.free(l);
            return null;
        };
        alloc.free(l);
        return full;
    }
    return null;
}

// ── Ledger digest ───────────────────────────────────────────────────

fn runLedgerDigest(alloc: std.mem.Allocator, self_exe: []const u8, home: []const u8, evidence_dir: []const u8) u8 {
    // Run ledger-harness snapshot --home <home>
    const exit = spawnWithEnvAndWait(alloc, &[_][]const u8{
        self_exe, "ledger-harness", "snapshot", "--home", home,
    }, "TSUNAGI_HOME", home);

    if (exit != 0) return exit;

    // Find latest snapshot file in <home>/ledger_snapshots/
    var snap_dir_buf: [512]u8 = undefined;
    const snap_dir_path = std.fmt.bufPrint(&snap_dir_buf, "{s}/ledger_snapshots", .{home}) catch return 4;

    const latest_snap = findLatestFile(alloc, snap_dir_path, ".snapshot.json") orelse return 4;
    defer alloc.free(latest_snap);

    // Copy it to checks/ledger_digest.json
    var dst_buf: [512]u8 = undefined;
    const dst = std.fmt.bufPrint(&dst_buf, "{s}/checks/ledger_digest.json", .{evidence_dir}) catch return 4;

    if (!copyFile(alloc, latest_snap, dst)) return 4;
    return 0;
}

fn findLatestFile(alloc: std.mem.Allocator, dir_path: []const u8, suffix: []const u8) ?[]const u8 {
    var dir = compat.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return null;
    defer dir.close();
    var it = dir.iterate();
    var latest: ?[]u8 = null;
    while (it.next() catch null) |e| {
        if (e.kind != .file) continue;
        if (!std.mem.endsWith(u8, e.name, suffix)) continue;
        if (latest == null) {
            latest = alloc.dupe(u8, e.name) catch continue;
        } else {
            if (std.mem.lessThan(u8, latest.?, e.name)) {
                alloc.free(latest.?);
                latest = alloc.dupe(u8, e.name) catch continue;
            }
        }
    }
    if (latest) |l| {
        const full = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, l }) catch {
            alloc.free(l);
            return null;
        };
        alloc.free(l);
        return full;
    }
    return null;
}

// ── Guardian deploy-check ───────────────────────────────────────────

fn runGuardianDeployCheck(alloc: std.mem.Allocator, self_exe: []const u8, port_val: u16, evidence_dir: []const u8) u8 {
    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port_val}) catch return 4;

    var buf: [8192]u8 = undefined;
    const result = runCaptureStderrWithExit(alloc, &[_][]const u8{
        self_exe, "guardian", "deploy-check", "--port", port_str,
    }, &buf) orelse return 3;

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/checks/guardian_deploy_check.txt", .{evidence_dir}) catch return 4;
    _ = writeFileContent(path, buf[0..result.len]);

    return result.exit_code;
}

// ── Zero-secrets scan ───────────────────────────────────────────────

fn scanForSecrets(alloc: std.mem.Allocator, evidence_dir: []const u8, max_file_size: u64) bool {
    // Collect all files and check for forbidden patterns
    var files = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (files.items) |s| alloc.free(s);
        files.deinit();
    }
    collectFilesRecursive(alloc, evidence_dir, evidence_dir, &files);

    for (files.items) |rel_path| {
        // Check extension: *.skey, *.vkey, *.cert
        if (std.mem.endsWith(u8, rel_path, ".skey") or
            std.mem.endsWith(u8, rel_path, ".vkey") or
            std.mem.endsWith(u8, rel_path, ".cert"))
        {
            std.debug.print("SECRETS: forbidden file extension: {s}\n", .{rel_path});
            return false;
        }

        // Check if filename contains "key"
        // Extract basename (last component after /)
        const basename = if (std.mem.lastIndexOfScalar(u8, rel_path, '/')) |idx|
            rel_path[idx + 1 ..]
        else
            rel_path;
        if (std.mem.indexOf(u8, basename, "key") != null) {
            std.debug.print("SECRETS: filename contains 'key': {s}\n", .{rel_path});
            return false;
        }

        // Check file size > 5MB
        const full = std.fmt.allocPrint(alloc, "{s}/{s}", .{ evidence_dir, rel_path }) catch continue;
        defer alloc.free(full);
        const stat = compat.fs.cwd().statFile(full) catch continue;
        if (stat.size > max_file_size) {
            std.debug.print("SECRETS: file too large: {s} ({d} bytes, limit {d})\n", .{ rel_path, stat.size, max_file_size });
            return false;
        }
    }
    return true;
}

// ── Manifest JSON ───────────────────────────────────────────────────

fn writeManifest(alloc: std.mem.Allocator, evidence_dir: []const u8, cfg: *const Config, unix_now: u64, version_str: ?[]const u8, consensus_result: []const u8, readiness_result: []const u8, forge_result: []const u8, ledger_result: []const u8, guardian_result: []const u8, rolling_digest: *const [64]u8, has_digest: bool) void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/manifest.json", .{evidence_dir}) catch return;

    var f = compat.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer f.close();
    const w = f.deprecatedWriter();

    const ver = version_str orelse "unknown";
    const digest_str: []const u8 = if (has_digest) rolling_digest else "0000000000000000000000000000000000000000000000000000000000000000";

    w.print("{{", .{}) catch return;
    w.print("\"version\":\"{s}\",", .{ver}) catch return;
    w.print("\"net\":\"{s}\",", .{cfg.net}) catch return;
    w.print("\"home\":\"{s}\",", .{cfg.home}) catch return;
    w.print("\"unix\":{d},", .{unix_now}) catch return;
    w.print("\"limit\":{d},", .{cfg.limit}) catch return;
    w.print("\"strict\":{s},", .{if (cfg.strict) "true" else "false"}) catch return;
    w.print("\"inputs\":{{", .{}) catch return;
    w.print("\"consensus_vectors\":\"inputs/consensus_vectors.jsonl\",", .{}) catch return;
    w.print("\"readiness_vectors\":\"inputs/readiness_vectors.jsonl\"", .{}) catch return;
    w.print("}},", .{}) catch return;
    w.print("\"results\":{{", .{}) catch return;
    w.print("\"guardian_deploy_check\":\"{s}\",", .{guardian_result}) catch return;
    w.print("\"consensus_align\":\"{s}\",", .{consensus_result}) catch return;
    w.print("\"readiness_sim\":\"{s}\",", .{readiness_result}) catch return;
    w.print("\"forge_sim\":\"{s}\",", .{forge_result}) catch return;
    w.print("\"ledger_digest\":\"{s}\"", .{ledger_result}) catch return;
    w.print("}},", .{}) catch return;
    w.print("\"rolling_digest_hex\":\"{s}\",", .{digest_str}) catch return;

    // Notes
    w.print("\"notes\":[", .{}) catch return;
    var notes_count: u32 = 0;
    if (std.mem.eql(u8, guardian_result, "SKIP")) {
        if (notes_count > 0) w.writeAll(",") catch {};
        w.print("\"guardian deploy-check skipped (no --port)\"", .{}) catch return;
        notes_count += 1;
    }
    if (std.mem.eql(u8, forge_result, "SKIP")) {
        if (notes_count > 0) w.writeAll(",") catch {};
        w.print("\"forge-sim skipped (no block dirs)\"", .{}) catch return;
        notes_count += 1;
    }
    if (std.mem.eql(u8, ledger_result, "SKIP")) {
        if (notes_count > 0) w.writeAll(",") catch {};
        w.print("\"ledger digest skipped (no lmdb)\"", .{}) catch return;
        notes_count += 1;
    }
    _ = alloc;
    w.print("]", .{}) catch return;
    w.print("}}\n", .{}) catch return;
}

// ── Pubkey embedding (v4.3.0) ───────────────────────────────────────

const PubkeyMeta = struct {
    sha256_hex: [64]u8,
    len_bytes: usize,
    format: []const u8,
    embedded: bool,
};

/// Copy the default snapshot pubkey into inputs/snapshot_pubkey.pub and compute metadata.
/// Returns metadata; embedded=false if pubkey not available (best-effort).
fn embedPubkey(alloc: std.mem.Allocator, evidence_dir: []const u8) PubkeyMeta {
    var meta = PubkeyMeta{
        .sha256_hex = .{'0'} ** 64,
        .len_bytes = 0,
        .format = "unknown",
        .embedded = false,
    };

    const pub_path = snapshot_sign.defaultPubPathAlloc(alloc) catch return meta;
    defer alloc.free(pub_path);

    // Read pubkey file
    var pub_f = compat.fs.cwd().openFile(pub_path, .{}) catch return meta;
    defer pub_f.close();
    const pub_data = pub_f.readToEndAlloc(alloc, 4096) catch return meta;
    defer alloc.free(pub_data);

    // Compute metadata
    meta.len_bytes = pub_data.len;

    // Pubkey file is hex-encoded (64 hex chars = 32 bytes raw key)
    const trimmed = std.mem.trim(u8, pub_data, " \t\r\n");
    if (trimmed.len == 64) {
        // Hex-encoded 32-byte Ed25519 pubkey
        meta.format = "ed25519_hex_64";
    }

    // SHA256 of file contents
    var digest: [32]u8 = undefined;
    Sha256.hash(pub_data, &digest, .{});
    meta.sha256_hex = std.fmt.bytesToHex(digest, .lower);

    // Write to envelope
    var dst_buf: [512]u8 = undefined;
    const dst_path = std.fmt.bufPrint(&dst_buf, "{s}/inputs/snapshot_pubkey.pub", .{evidence_dir}) catch return meta;
    var dst_f = compat.fs.cwd().createFile(dst_path, .{ .truncate = true }) catch return meta;
    defer dst_f.close();
    dst_f.writeAll(pub_data) catch return meta;
    meta.embedded = true;

    return meta;
}

// ── Build info (v4.2.0 Layer A) ─────────────────────────────────────

fn emitBuildInfo(evidence_dir: []const u8) void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/checks/build_info.json", .{evidence_dir}) catch return;
    if (!build_info.writeJsonFile(path)) {
        std.debug.print("WARN: could not write checks/build_info.json\n", .{});
    }
}

// ── GPG notarization (v4.4.0) ───────────────────────────────────────

fn notarizeGpgSign(alloc: std.mem.Allocator, evidence_dir: []const u8, armor: bool, key_id: ?[]const u8, homedir: ?[]const u8) u8 {
    const ext: []const u8 = if (armor) ".asc" else ".sig";

    // 1) Sign manifest.json (content is final)
    const manifest_rc = gpgDetachSign(alloc, evidence_dir, "manifest.json", ext, armor, key_id, homedir);
    if (manifest_rc != 0) return manifest_rc;

    // 2) Recompute SHA256SUMS to include manifest.json.asc/sig
    //    (SHA256SUMS.asc/sig excluded by collectFilesRecursive)
    writeSha256Sums(alloc, evidence_dir);

    // 3) Sign SHA256SUMS (content is now final; sig file excluded from SHA256SUMS)
    const sums_rc = gpgDetachSign(alloc, evidence_dir, "SHA256SUMS", ext, armor, key_id, homedir);
    if (sums_rc != 0) return sums_rc;

    return 0;
}

fn gpgDetachSign(alloc: std.mem.Allocator, evidence_dir: []const u8, filename: []const u8, ext: []const u8, armor: bool, key_id: ?[]const u8, homedir: ?[]const u8) u8 {
    // Build input path: <evidence_dir>/<filename>
    var in_buf: [512]u8 = undefined;
    const in_path = std.fmt.bufPrint(&in_buf, "{s}/{s}", .{ evidence_dir, filename }) catch return 2;

    // Build output path: <evidence_dir>/<filename><ext>
    var out_buf: [512]u8 = undefined;
    const out_path = std.fmt.bufPrint(&out_buf, "{s}/{s}{s}", .{ evidence_dir, filename, ext }) catch return 2;

    // Build argv dynamically
    var argv_list = std.array_list.Managed([]const u8).init(alloc);
    defer argv_list.deinit();

    argv_list.append("gpg") catch return 2;
    argv_list.append("--batch") catch return 2;
    argv_list.append("--yes") catch return 2;
    argv_list.append("--detach-sign") catch return 2;

    if (armor) {
        argv_list.append("--armor") catch return 2;
    }
    if (homedir) |hd| {
        argv_list.append("--homedir") catch return 2;
        argv_list.append(hd) catch return 2;
    }
    if (key_id) |kid| {
        argv_list.append("--local-user") catch return 2;
        argv_list.append(kid) catch return 2;
    }
    argv_list.append("--output") catch return 2;
    argv_list.append(out_path) catch return 2;
    argv_list.append(in_path) catch return 2;

    // Capture stderr for bounded error reporting
    var stderr_buf: [4096]u8 = undefined;
    const result = runCaptureStderrWithExit(alloc, argv_list.items, &stderr_buf) orelse {
        std.debug.print("notarize: gpg not found or failed to spawn\n", .{});
        return 2;
    };

    if (result.exit_code != 0) {
        std.debug.print("notarize: gpg failed (exit {d}) signing {s}\n", .{ result.exit_code, filename });
        // Print first 5 lines of stderr (bounded)
        const stderr_out = stderr_buf[0..result.len];
        var line_count: u32 = 0;
        var start: usize = 0;
        for (stderr_out, 0..) |c, i| {
            if (c == '\n') {
                if (line_count < 5) {
                    std.debug.print("  {s}\n", .{stderr_out[start..i]});
                }
                line_count += 1;
                start = i + 1;
                if (line_count >= 5) break;
            }
        }
        // Print last partial line if under 5 lines
        if (line_count < 5 and start < stderr_out.len) {
            std.debug.print("  {s}\n", .{stderr_out[start..]});
        }
        return 2;
    }

    return 0;
}

// ── SHA256SUMS ──────────────────────────────────────────────────────

fn writeSha256Sums(alloc: std.mem.Allocator, evidence_dir: []const u8) void {
    // Collect all files recursively (exclude SHA256SUMS itself)
    var files = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (files.items) |s| alloc.free(s);
        files.deinit();
    }

    collectFilesRecursive(alloc, evidence_dir, evidence_dir, &files);

    // Sort by relative path
    std.sort.insertion([]u8, files.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    // Write SHA256SUMS
    var sums_path_buf: [512]u8 = undefined;
    const sums_path = std.fmt.bufPrint(&sums_path_buf, "{s}/SHA256SUMS", .{evidence_dir}) catch return;

    var f = compat.fs.cwd().createFile(sums_path, .{ .truncate = true }) catch return;
    defer f.close();
    const w = f.deprecatedWriter();

    for (files.items) |rel_path| {
        const full = std.fmt.allocPrint(alloc, "{s}/{s}", .{ evidence_dir, rel_path }) catch continue;
        defer alloc.free(full);
        const hash = sha256File(full) orelse continue;
        const hex = std.fmt.bytesToHex(hash, .lower);
        w.print("{s}  {s}\n", .{ @as([]const u8, &hex), rel_path }) catch continue;
    }
}

fn collectFilesRecursive(alloc: std.mem.Allocator, base: []const u8, current: []const u8, list: *std.array_list.Managed([]u8)) void {
    var dir = compat.fs.cwd().openDir(current, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind == .directory) {
            const sub = std.fmt.allocPrint(alloc, "{s}/{s}", .{ current, entry.name }) catch continue;
            defer alloc.free(sub);
            collectFilesRecursive(alloc, base, sub, list);
        } else if (entry.kind == .file) {
            // Skip SHA256SUMS itself and its signature files
            if (std.mem.eql(u8, current, base) and std.mem.eql(u8, entry.name, "SHA256SUMS")) continue;
            if (std.mem.eql(u8, current, base) and std.mem.eql(u8, entry.name, "SHA256SUMS.asc")) continue;
            if (std.mem.eql(u8, current, base) and std.mem.eql(u8, entry.name, "SHA256SUMS.sig")) continue;

            // Compute relative path
            const full = std.fmt.allocPrint(alloc, "{s}/{s}", .{ current, entry.name }) catch continue;
            defer alloc.free(full);

            // Strip base + "/" to get relative path
            if (full.len > base.len + 1) {
                const rel = full[base.len + 1 ..];
                list.append(alloc.dupe(u8, rel) catch continue) catch continue;
            }
        }
    }
}

// ── Snapshot-proof mode ──────────────────────────────────────────────

fn runSnapshotProofMode(alloc: std.mem.Allocator, net: []const u8, out_base: []const u8, strict: bool, file: []const u8, key_dir: []const u8) u8 {
    var self_exe_buf: [4096]u8 = undefined;
    const self_exe = compat.selfExePath(&self_exe_buf) catch {
        std.debug.print("ERROR: cannot resolve self exe\n", .{});
        return 4;
    };

    if (strict) {
        return spawnAndWaitExit(alloc, &[_][]const u8{
            self_exe, "snapshot-proof", "--file", file, "--keydir", key_dir, "--out", out_base, "--net", net, "--strict",
        });
    } else {
        return spawnAndWaitExit(alloc, &[_][]const u8{
            self_exe, "snapshot-proof", "--file", file, "--keydir", key_dir, "--out", out_base, "--net", net,
        });
    }
}

// ── Cold-start envelope ─────────────────────────────────────────────

fn runColdStartEnvelope(alloc: std.mem.Allocator, net_str: []const u8, out_base: []const u8, strict: bool, snapshot_path: []const u8) u8 {
    _ = strict;

    // Validate snapshot exists
    _ = compat.fs.cwd().statFile(snapshot_path) catch {
        std.debug.print("ERROR: cannot stat snapshot: {s}\n", .{snapshot_path});
        return 3;
    };

    // Self-exe
    var self_exe_buf: [4096]u8 = undefined;
    const self_exe = compat.selfExePath(&self_exe_buf) catch {
        std.debug.print("ERROR: cannot resolve self exe\n", .{});
        return 4;
    };

    // Timestamp
    const unix_now: u64 = @intCast(@max(@as(i64, 0), compat.timestamp()));

    // Create evidence directory
    var dir_name_buf: [256]u8 = undefined;
    const dir_name = std.fmt.bufPrint(&dir_name_buf, "tsunagi_evidence_coldstart_{s}_{d}", .{ net_str, unix_now }) catch {
        std.debug.print("ERROR: dir name too long\n", .{});
        return 4;
    };

    const evidence_dir = std.fmt.allocPrint(alloc, "{s}/{s}", .{ out_base, dir_name }) catch {
        std.debug.print("ERROR: alloc\n", .{});
        return 4;
    };
    defer alloc.free(evidence_dir);

    compat.fs.cwd().makePath(evidence_dir) catch {
        std.debug.print("ERROR: cannot create {s}\n", .{evidence_dir});
        return 3;
    };

    // Subdirs
    var checks_buf: [512]u8 = undefined;
    const checks_dir = std.fmt.bufPrint(&checks_buf, "{s}/checks", .{evidence_dir}) catch return 4;
    compat.fs.cwd().makePath(checks_dir) catch {};

    var inputs_buf: [512]u8 = undefined;
    const inputs_dir = std.fmt.bufPrint(&inputs_buf, "{s}/inputs", .{evidence_dir}) catch return 4;
    compat.fs.cwd().makePath(inputs_dir) catch {};

    // Version
    const version_str = detectVersion(alloc, self_exe, evidence_dir);
    defer if (version_str) |vs| alloc.free(vs);

    // Snapshot info: SHA256
    const snap_sha256 = sha256File(snapshot_path) orelse {
        std.debug.print("ERROR: cannot hash snapshot\n", .{});
        return 4;
    };
    const snap_hex = std.fmt.bytesToHex(snap_sha256, .lower);

    // Snapshot info: TSF header + file size
    const snap_stat = compat.fs.cwd().statFile(snapshot_path) catch {
        std.debug.print("ERROR: cannot stat snapshot\n", .{});
        return 4;
    };
    const snap_size = snap_stat.size;

    var snap_file = compat.fs.cwd().openFile(snapshot_path, .{}) catch {
        std.debug.print("ERROR: cannot open snapshot\n", .{});
        return 4;
    };
    var reader = snap_file.deprecatedReader();
    const header = tsf.readHeader(&reader) catch {
        snap_file.close();
        std.debug.print("ERROR: cannot read TSF header\n", .{});
        return 4;
    };
    snap_file.close();

    const slot = header.slot;
    const block_no = header.block_no;

    // Extract basename
    const snap_basename = if (std.mem.lastIndexOfScalar(u8, snapshot_path, '/')) |idx|
        snapshot_path[idx + 1 ..]
    else
        snapshot_path;

    // Write inputs/snapshot_info.json
    {
        var si_path_buf: [512]u8 = undefined;
        const si_path = std.fmt.bufPrint(&si_path_buf, "{s}/inputs/snapshot_info.json", .{evidence_dir}) catch return 4;
        var si_f = compat.fs.cwd().createFile(si_path, .{ .truncate = true }) catch {
            std.debug.print("ERROR: cannot write snapshot_info.json\n", .{});
            return 4;
        };
        defer si_f.close();
        const si_w = si_f.deprecatedWriter();
        si_w.print("{{\"path\":\"{s}\",\"basename\":\"{s}\",\"sha256\":\"{s}\",\"bytes\":{d},\"slot\":{d},\"block_no\":{d}}}\n", .{
            snapshot_path, snap_basename, @as([]const u8, &snap_hex), snap_size, slot, block_no,
        }) catch return 4;
    }

    // Temp LMDB paths (outside evidence dir, cleaned up after)
    const tmp1 = std.fmt.allocPrint(alloc, "{s}/.cs_lmdb_1_{d}", .{ out_base, unix_now }) catch return 4;
    defer alloc.free(tmp1);
    const tmp2 = std.fmt.allocPrint(alloc, "{s}/.cs_lmdb_2_{d}", .{ out_base, unix_now }) catch return 4;
    defer alloc.free(tmp2);

    // Report paths
    var r1_buf: [512]u8 = undefined;
    const r1_path = std.fmt.bufPrint(&r1_buf, "{s}/checks/cold_start_1.json", .{evidence_dir}) catch return 4;
    var r2_buf: [512]u8 = undefined;
    const r2_path = std.fmt.bufPrint(&r2_buf, "{s}/checks/cold_start_2.json", .{evidence_dir}) catch return 4;

    // Run cold-start #1
    std.debug.print("cold-start envelope: run 1\n", .{});
    const exit1 = spawnAndWaitExit(alloc, &[_][]const u8{
        self_exe, "cold-start", "--snapshot", snapshot_path, "--out-lmdb", tmp1, "--strict", "--out", r1_path,
    });
    const cs1_result: []const u8 = if (exit1 == 0) "PASS" else "FAIL";

    // Run cold-start #2
    std.debug.print("cold-start envelope: run 2\n", .{});
    const exit2 = spawnAndWaitExit(alloc, &[_][]const u8{
        self_exe, "cold-start", "--snapshot", snapshot_path, "--out-lmdb", tmp2, "--strict", "--out", r2_path,
    });
    const cs2_result: []const u8 = if (exit2 == 0) "PASS" else "FAIL";

    // Extract digests from reports
    var d1: [64]u8 = undefined;
    var d2: [64]u8 = undefined;
    const got1 = extractColdStartDigest(r1_path, &d1);
    const got2 = extractColdStartDigest(r2_path, &d2);

    var determinism_result: []const u8 = "FAIL";
    var ledger_digest_hex: []const u8 = "0000000000000000000000000000000000000000000000000000000000000000";

    if (got1 and got2 and std.mem.eql(u8, &d1, &d2)) {
        determinism_result = "PASS";
        ledger_digest_hex = &d1;
    } else if (got1) {
        ledger_digest_hex = &d1;
    }

    const ledger_result: []const u8 = if (exit1 == 0 and exit2 == 0) "PASS" else "FAIL";

    // Copy first report as ledger_digest.json
    {
        var ld_buf: [512]u8 = undefined;
        const ld_path = std.fmt.bufPrint(&ld_buf, "{s}/checks/ledger_digest.json", .{evidence_dir}) catch "";
        if (ld_path.len > 0) {
            _ = copyFile(alloc, r1_path, ld_path);
        }
    }

    const overall_pass = (exit1 == 0 and exit2 == 0 and std.mem.eql(u8, determinism_result, "PASS"));

    // Temp LMDB cleanup: PASS=delete, FAIL=preserve for debugging
    if (overall_pass) {
        compat.fs.cwd().deleteTree(tmp1) catch {};
        compat.fs.cwd().deleteTree(tmp2) catch {};
    }

    // Zero-secrets scan (only on PASS; FAIL envelope is for debugging)
    if (overall_pass) {
        if (!scanForSecrets(alloc, evidence_dir, 20 * 1024 * 1024)) {
            std.debug.print("FAIL: zero-secrets scan failed\n", .{});
            return 2;
        }
    }

    // Pubkey embedding (v4.3.0)
    const pubkey_meta = embedPubkey(alloc, evidence_dir);

    // Manifest
    writeColdStartManifest(alloc, evidence_dir, net_str, unix_now, version_str, snapshot_path, snap_basename, @as([]const u8, &snap_hex), snap_size, slot, block_no, cs1_result, cs2_result, determinism_result, ledger_result, ledger_digest_hex, overall_pass, tmp1, tmp2, &pubkey_meta);

    // Build identity (v4.2.0 Layer A)
    emitBuildInfo(evidence_dir);

    // SHA256SUMS
    writeSha256Sums(alloc, evidence_dir);

    // Summary
    std.debug.print("\n=== Cold-Start Evidence Pack ===\n", .{});
    std.debug.print("overall: {s}\n", .{if (overall_pass) "PASS" else "FAIL"});
    std.debug.print("cold_start_1: {s}\n", .{cs1_result});
    std.debug.print("cold_start_2: {s}\n", .{cs2_result});
    std.debug.print("determinism: {s}\n", .{determinism_result});
    std.debug.print("ledger_digest: {s}\n", .{ledger_result});
    std.debug.print("ledger_digest_hex: {s}\n", .{ledger_digest_hex});

    const stdout = compat.fs.stdoutWriter();
    stdout.print("{s}\n", .{evidence_dir}) catch {};

    if (overall_pass) return 0;
    return 2;
}

fn extractColdStartDigest(report_path: []const u8, out: *[64]u8) bool {
    var f = compat.fs.cwd().openFile(report_path, .{}) catch return false;
    defer f.close();
    var buf: [4096]u8 = undefined;
    const n = f.read(&buf) catch return false;
    const content = buf[0..n];
    const needle = "\"ledger_digest_hex\":\"";
    const idx = std.mem.indexOf(u8, content, needle) orelse return false;
    const start = idx + needle.len;
    if (start + 64 > content.len) return false;
    @memcpy(out, content[start..][0..64]);
    return true;
}

fn writeColdStartManifest(
    alloc: std.mem.Allocator,
    evidence_dir: []const u8,
    net_str: []const u8,
    unix_now: u64,
    version_str: ?[]const u8,
    snapshot_path: []const u8,
    snap_basename: []const u8,
    snap_hex: []const u8,
    snap_size: u64,
    slot: u64,
    block_no: u64,
    cs1_result: []const u8,
    cs2_result: []const u8,
    determinism_result: []const u8,
    ledger_result: []const u8,
    ledger_digest_hex: []const u8,
    overall_pass: bool,
    tmp1: []const u8,
    tmp2: []const u8,
    pubkey_meta: *const PubkeyMeta,
) void {
    _ = alloc;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/manifest.json", .{evidence_dir}) catch return;

    var f = compat.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer f.close();
    const w = f.deprecatedWriter();

    const ver = version_str orelse "unknown";

    w.print("{{", .{}) catch return;
    w.print("\"version\":\"{s}\",", .{ver}) catch return;
    w.print("\"net\":\"{s}\",", .{net_str}) catch return;
    w.print("\"unix\":{d},", .{unix_now}) catch return;
    w.print("\"strict\":true,", .{}) catch return;
    w.print("\"mode\":\"cold_start\",", .{}) catch return;
    // Snapshot
    w.print("\"snapshot\":{{", .{}) catch return;
    w.print("\"path\":\"{s}\",", .{snapshot_path}) catch return;
    w.print("\"basename\":\"{s}\",", .{snap_basename}) catch return;
    w.print("\"sha256\":\"{s}\",", .{snap_hex}) catch return;
    w.print("\"bytes\":{d},", .{snap_size}) catch return;
    w.print("\"slot\":{d},", .{slot}) catch return;
    w.print("\"block_no\":{d}", .{block_no}) catch return;
    // v4.3.0: pubkey metadata (flat keys inside snapshot object)
    if (pubkey_meta.embedded) {
        w.print(",\"pubkey_sha256\":\"{s}\"", .{@as([]const u8, &pubkey_meta.sha256_hex)}) catch return;
        w.print(",\"pubkey_path_in_envelope\":\"inputs/snapshot_pubkey.pub\"", .{}) catch return;
        w.print(",\"pubkey_len_bytes\":{d}", .{pubkey_meta.len_bytes}) catch return;
        w.print(",\"pubkey_format\":\"{s}\"", .{pubkey_meta.format}) catch return;
    }
    w.print("}},", .{}) catch return;
    // Results
    w.print("\"results\":{{", .{}) catch return;
    w.print("\"cold_start_1\":\"{s}\",", .{cs1_result}) catch return;
    w.print("\"cold_start_2\":\"{s}\",", .{cs2_result}) catch return;
    w.print("\"determinism\":\"{s}\",", .{determinism_result}) catch return;
    w.print("\"ledger_digest\":\"{s}\"", .{ledger_result}) catch return;
    w.print("}},", .{}) catch return;
    w.print("\"ledger_digest_hex\":\"{s}\",", .{ledger_digest_hex}) catch return;
    // Notes
    w.print("\"notes\":[", .{}) catch return;
    var notes_count: u32 = 0;
    if (!overall_pass) {
        if (notes_count > 0) w.writeAll(",") catch {};
        w.print("\"preserved tmp_lmdb_1: {s}\"", .{tmp1}) catch return;
        notes_count += 1;
        w.writeAll(",") catch {};
        w.print("\"preserved tmp_lmdb_2: {s}\"", .{tmp2}) catch return;
        notes_count += 1;
    }
    w.print("]", .{}) catch return;
    w.print("}}\n", .{}) catch return;
}

fn sha256File(path: []const u8) ?[32]u8 {
    var f = compat.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    var h = Sha256.init(.{});
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = f.read(&buf) catch return null;
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return digest;
}
