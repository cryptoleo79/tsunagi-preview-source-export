const std = @import("std");
const compat = @import("compat");
const Sha256 = std.crypto.hash.sha2.Sha256;
const tsf = @import("../store/tsf.zig");

// ── Snapshot Proof — signed snapshot envelope + mutation suite (v4.1.0) ──
//
// Signs a TSF snapshot, verifies it, runs 7 adversarial mutations
// (all must be rejected), produces a self-contained evidence directory.
// Zero secrets by design.
//
// Tooling only. Offline. No runtime changes. No forging/broadcast/injection.
//
// Exit codes: 0=PASS, 2=FAIL, 3=missing args/files, 4=sign/IO error.

const CaptureResult = struct {
    exit_code: u8,
    len: usize,
};

const MutationResult = struct {
    name: []const u8,
    expected: u8,
    actual: u8,
    result: []const u8, // "PASS", "FAIL", or "SKIP"
};

// ── pub fn run ──────────────────────────────────────────────────────

pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    // ── Parse args ──
    var file_path: ?[]const u8 = null;
    var keydir: ?[]const u8 = null;
    var out_base: []const u8 = "/tmp";
    var strict = false;
    var net: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--file")) {
            file_path = args_it.next() orelse {
                std.debug.print("ERROR: --file requires a path\n", .{});
                return 3;
            };
        } else if (std.mem.eql(u8, arg, "--keydir")) {
            keydir = args_it.next() orelse {
                std.debug.print("ERROR: --keydir requires a path\n", .{});
                return 3;
            };
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_base = args_it.next() orelse {
                std.debug.print("ERROR: --out requires a path\n", .{});
                return 3;
            };
        } else if (std.mem.eql(u8, arg, "--strict")) {
            strict = true;
        } else if (std.mem.eql(u8, arg, "--net")) {
            net = args_it.next() orelse {
                std.debug.print("ERROR: --net requires a value\n", .{});
                return 3;
            };
        } else {
            std.debug.print("ERROR: unknown flag: {s}\n", .{arg});
            return 3;
        }
    }

    const tsf_path = file_path orelse {
        std.debug.print("ERROR: --file required\n", .{});
        return 3;
    };

    const key_dir = keydir orelse {
        std.debug.print("ERROR: --keydir required\n", .{});
        return 3;
    };

    // ── Validate TSF exists ──
    const snap_stat = compat.fs.cwd().statFile(tsf_path) catch {
        std.debug.print("ERROR: cannot stat TSF file: {s}\n", .{tsf_path});
        return 3;
    };
    const snap_size = snap_stat.size;

    // ── Read TSF header ──
    var snap_file = compat.fs.cwd().openFile(tsf_path, .{}) catch {
        std.debug.print("ERROR: cannot open TSF: {s}\n", .{tsf_path});
        return 3;
    };
    var reader = snap_file.deprecatedReader();
    const header = tsf.readHeader(&reader) catch {
        snap_file.close();
        std.debug.print("ERROR: cannot read TSF header from {s}\n", .{tsf_path});
        return 4;
    };
    snap_file.close();

    if (!std.mem.eql(u8, header.magic[0..4], "TSF2")) {
        std.debug.print("ERROR: invalid TSF magic (expected TSF2)\n", .{});
        return 4;
    }

    const slot = header.slot;
    const block_no = header.block_no;

    // ── Resolve self_exe ──
    var self_buf: [4096]u8 = undefined;
    const self_exe = compat.selfExePath(&self_buf) catch {
        std.debug.print("ERROR: cannot resolve self exe path\n", .{});
        return 4;
    };

    // ── Timestamp + evidence dir ──
    const unix_now: u64 = @intCast(@max(@as(i64, 0), compat.timestamp()));

    var dir_name_buf: [256]u8 = undefined;
    const dir_name = if (net) |n|
        std.fmt.bufPrint(&dir_name_buf, "tsunagi_snapshot_proof_{s}_{d}", .{ n, unix_now }) catch {
            std.debug.print("ERROR: dir name too long\n", .{});
            return 4;
        }
    else
        std.fmt.bufPrint(&dir_name_buf, "tsunagi_snapshot_proof_{d}", .{unix_now}) catch {
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
    {
        var buf: [512]u8 = undefined;
        const checks_dir = std.fmt.bufPrint(&buf, "{s}/checks", .{evidence_dir}) catch return 4;
        compat.fs.cwd().makePath(checks_dir) catch {};
    }
    {
        var buf: [512]u8 = undefined;
        const inputs_dir = std.fmt.bufPrint(&buf, "{s}/inputs", .{evidence_dir}) catch return 4;
        compat.fs.cwd().makePath(inputs_dir) catch {};
    }

    // ── Step 1: Version detection ──
    const version_str = detectVersion(alloc, self_exe, evidence_dir);
    defer if (version_str) |vs| alloc.free(vs);

    // ── Step 2: Snapshot info ──
    const snap_sha256 = sha256File(tsf_path) orelse {
        std.debug.print("ERROR: cannot hash TSF file\n", .{});
        return 4;
    };
    const snap_hex = std.fmt.bytesToHex(snap_sha256, .lower);

    const snap_basename = if (std.mem.lastIndexOfScalar(u8, tsf_path, '/')) |idx|
        tsf_path[idx + 1 ..]
    else
        tsf_path;

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
            tsf_path, snap_basename, @as([]const u8, &snap_hex), snap_size, slot, block_no,
        }) catch return 4;
    }

    // ── Step 3: Key handling ──
    // Check keydir for existing key
    const key_path = std.fmt.allocPrint(alloc, "{s}/snapshot_ed25519.key", .{key_dir}) catch return 4;
    defer alloc.free(key_path);
    const pub_path = std.fmt.allocPrint(alloc, "{s}/snapshot_ed25519.pub", .{key_dir}) catch return 4;
    defer alloc.free(pub_path);

    // Check if key exists; if not, run keygen + copy
    const key_exists = if (compat.fs.cwd().statFile(key_path)) |_| true else |_| false;
    if (!key_exists) {
        std.debug.print("snapshot-proof: key not found at {s}, running keygen\n", .{key_path});

        // Run snapshot-keygen (writes to default ~/.local/tsunagi/keys/)
        const keygen_exit = spawnAndWaitExit(alloc, &[_][]const u8{ self_exe, "snapshot-keygen" });
        if (keygen_exit != 0) {
            std.debug.print("ERROR: snapshot-keygen failed (exit={d})\n", .{keygen_exit});
            return 4;
        }

        // Determine default key location
        const home_env = compat.getEnvVarOwned(alloc, "HOME") catch {
            std.debug.print("ERROR: HOME not set\n", .{});
            return 4;
        };
        defer alloc.free(home_env);

        const default_key = std.fmt.allocPrint(alloc, "{s}/.local/tsunagi/keys/snapshot_ed25519.key", .{home_env}) catch return 4;
        defer alloc.free(default_key);
        const default_pub = std.fmt.allocPrint(alloc, "{s}/.local/tsunagi/keys/snapshot_ed25519.pub", .{home_env}) catch return 4;
        defer alloc.free(default_pub);

        // If keydir differs from default, copy keys there
        const default_dir = std.fmt.allocPrint(alloc, "{s}/.local/tsunagi/keys", .{home_env}) catch return 4;
        defer alloc.free(default_dir);

        if (!std.mem.eql(u8, key_dir, default_dir)) {
            compat.fs.cwd().makePath(key_dir) catch {};
            if (!copyFile(alloc, default_key, key_path)) {
                std.debug.print("ERROR: cannot copy key to {s}\n", .{key_path});
                return 4;
            }
            if (!copyFile(alloc, default_pub, pub_path)) {
                std.debug.print("ERROR: cannot copy pub to {s}\n", .{pub_path});
                return 4;
            }
        }
    }

    // Read pubkey and write to inputs/pubkey_hex.txt
    const pubkey_hex = blk: {
        var pf = compat.fs.cwd().openFile(pub_path, .{}) catch {
            std.debug.print("ERROR: cannot read pubkey: {s}\n", .{pub_path});
            return 4;
        };
        defer pf.close();
        var pk_buf: [256]u8 = undefined;
        const pk_n = pf.read(&pk_buf) catch {
            std.debug.print("ERROR: cannot read pubkey\n", .{});
            return 4;
        };
        break :blk alloc.dupe(u8, std.mem.trimEnd(u8, pk_buf[0..pk_n], "\n\r \t")) catch return 4;
    };
    defer alloc.free(pubkey_hex);

    {
        var pk_path_buf: [512]u8 = undefined;
        const pk_out = std.fmt.bufPrint(&pk_path_buf, "{s}/inputs/pubkey_hex.txt", .{evidence_dir}) catch return 4;
        _ = writeFileContent(pk_out, pubkey_hex);
    }

    // ── Step 4: Verify original (may FAIL if unsigned) ──
    std.debug.print("snapshot-proof: verifying original (may fail if unsigned)\n", .{});
    var verify_orig_buf: [4096]u8 = undefined;
    const verify_orig = runCaptureStderrWithExit(alloc, &[_][]const u8{
        self_exe, "snapshot-verify", "--file", tsf_path, "--pubkey-file", pub_path,
    }, &verify_orig_buf);
    const verify_orig_exit: u8 = if (verify_orig) |r| r.exit_code else 255;
    const verify_orig_result: []const u8 = if (verify_orig_exit == 0) "PASS" else "FAIL";
    {
        var vo_path_buf: [512]u8 = undefined;
        const vo_path = std.fmt.bufPrint(&vo_path_buf, "{s}/checks/verify_original.txt", .{evidence_dir}) catch return 4;
        var vo_content_buf: [128]u8 = undefined;
        const vo_content = std.fmt.bufPrint(&vo_content_buf, "exit_code={d}\nresult={s}\n", .{ verify_orig_exit, verify_orig_result }) catch return 4;
        _ = writeFileContent(vo_path, vo_content);
    }

    // ── Step 5: Sign ──
    std.debug.print("snapshot-proof: signing TSF\n", .{});
    const sign_exit = spawnAndWaitExit(alloc, &[_][]const u8{
        self_exe, "snapshot-sign", "--file", tsf_path, "--key", key_path,
    });
    if (sign_exit != 0) {
        std.debug.print("ERROR: snapshot-sign failed (exit={d})\n", .{sign_exit});
        return 4;
    }

    // ── Step 6: Verify signed (MUST PASS) ──
    std.debug.print("snapshot-proof: verifying signed TSF\n", .{});
    var verify_signed_buf: [4096]u8 = undefined;
    const verify_signed = runCaptureStderrWithExit(alloc, &[_][]const u8{
        self_exe, "snapshot-verify", "--file", tsf_path, "--pubkey-file", pub_path,
    }, &verify_signed_buf);
    const verify_signed_exit: u8 = if (verify_signed) |r| r.exit_code else 255;
    {
        var vs_path_buf: [512]u8 = undefined;
        const vs_path = std.fmt.bufPrint(&vs_path_buf, "{s}/checks/verify_signed.txt", .{evidence_dir}) catch return 4;
        if (verify_signed) |r| {
            _ = writeFileContent(vs_path, verify_signed_buf[0..r.len]);
        } else {
            _ = writeFileContent(vs_path, "ERROR: failed to spawn verify\n");
        }
    }
    if (verify_signed_exit != 0) {
        std.debug.print("FAIL: verify after signing failed (exit={d})\n", .{verify_signed_exit});
        // Still write manifest + SHA256SUMS for debugging
        writeSnapshotProofManifest(alloc, evidence_dir, unix_now, version_str, strict, net, tsf_path, snap_basename, @as([]const u8, &snap_hex), snap_size, slot, block_no, pubkey_hex, verify_orig_result, "FAIL", "SKIP", 0, 0, 0);
        writeSha256Sums(alloc, evidence_dir);
        const stdout = compat.fs.stdoutWriter();
        stdout.print("{s}\n", .{evidence_dir}) catch {};
        return 2;
    }

    // ── Step 7: Mutation suite (7 tests) ──
    std.debug.print("snapshot-proof: running mutation suite\n", .{});

    var mutations: [7]MutationResult = undefined;
    var pass_count: u32 = 0;
    var fail_count: u32 = 0;
    var skip_count: u32 = 0;

    // Get TSF dir for sig_swap (find another .tsf.sig)
    const tsf_dir = if (std.mem.lastIndexOfScalar(u8, tsf_path, '/')) |idx|
        tsf_path[0..idx]
    else
        ".";

    // 1. tail_flip: XOR byte at filesize-1024
    mutations[0] = runMutation(alloc, self_exe, pub_path, tsf_path, snap_size, "tail_flip", 2);
    // 2. head_flip: XOR byte at offset 16
    mutations[1] = runMutation(alloc, self_exe, pub_path, tsf_path, snap_size, "head_flip", 2);
    // 3. truncate: copy minus last byte
    mutations[2] = runMutation(alloc, self_exe, pub_path, tsf_path, snap_size, "truncate", 2);
    // 4. append: copy + null byte at end
    mutations[3] = runMutation(alloc, self_exe, pub_path, tsf_path, snap_size, "append", 2);
    // 5. random_sig: copy TSF + 89 random bytes as .sig
    mutations[4] = runMutation(alloc, self_exe, pub_path, tsf_path, snap_size, "random_sig", 2);
    // 6. missing_sig: copy TSF, no .sig
    mutations[5] = runMutation(alloc, self_exe, pub_path, tsf_path, snap_size, "missing_sig", 1);
    // 7. sig_swap: copy TSF + another .tsf.sig from same dir
    const swap_sig = findSwapSig(alloc, tsf_dir, snap_basename);
    defer if (swap_sig) |s| alloc.free(s);
    if (swap_sig != null) {
        mutations[6] = runMutationSigSwap(alloc, self_exe, pub_path, tsf_path, swap_sig.?);
    } else {
        mutations[6] = .{ .name = "sig_swap", .expected = 2, .actual = 0, .result = "SKIP" };
    }

    for (&mutations) |*m| {
        if (std.mem.eql(u8, m.result, "PASS")) {
            pass_count += 1;
        } else if (std.mem.eql(u8, m.result, "FAIL")) {
            fail_count += 1;
        } else {
            skip_count += 1;
        }
    }

    // ── Step 8: Write mutation report ──
    {
        var mr_path_buf: [512]u8 = undefined;
        const mr_path = std.fmt.bufPrint(&mr_path_buf, "{s}/checks/mutation_report.json", .{evidence_dir}) catch return 4;
        var mr_f = compat.fs.cwd().createFile(mr_path, .{ .truncate = true }) catch {
            std.debug.print("ERROR: cannot write mutation_report.json\n", .{});
            return 4;
        };
        defer mr_f.close();
        const w = mr_f.deprecatedWriter();

        w.print("{{\"mutations\":[", .{}) catch return 4;
        for (&mutations, 0..) |*m, i| {
            if (i > 0) w.writeAll(",") catch {};
            w.print("{{\"name\":\"{s}\",\"expected\":{d},\"actual\":{d},\"result\":\"{s}\"}}", .{
                m.name, m.expected, m.actual, m.result,
            }) catch return 4;
        }
        const overall_mutation: []const u8 = if (fail_count == 0) "PASS" else "FAIL";
        w.print("],\"pass_count\":{d},\"fail_count\":{d},\"skip_count\":{d},\"overall\":\"{s}\"}}\n", .{
            pass_count, fail_count, skip_count, overall_mutation,
        }) catch return 4;
    }

    // ── Step 9: Zero-secrets scan (5MB limit, pubkey_hex.txt exception) ──
    if (!scanForSecrets(alloc, evidence_dir)) {
        std.debug.print("FAIL: zero-secrets scan failed (forbidden files in evidence dir)\n", .{});
        return 2;
    }

    // ── Step 10: Manifest ──
    const mutation_overall: []const u8 = if (fail_count == 0) "PASS" else "FAIL";
    writeSnapshotProofManifest(alloc, evidence_dir, unix_now, version_str, strict, net, tsf_path, snap_basename, @as([]const u8, &snap_hex), snap_size, slot, block_no, pubkey_hex, verify_orig_result, "PASS", mutation_overall, pass_count, fail_count, skip_count);

    // ── Step 11: SHA256SUMS (LAST) ──
    writeSha256Sums(alloc, evidence_dir);

    // ── Step 12: Summary ──
    const overall_pass = (verify_signed_exit == 0) and (fail_count == 0);
    std.debug.print("\n=== Snapshot Proof ===\n", .{});
    std.debug.print("overall: {s}\n", .{if (overall_pass) "PASS" else "FAIL"});
    std.debug.print("verify_original: {s}\n", .{verify_orig_result});
    std.debug.print("verify_signed: PASS\n", .{});
    std.debug.print("mutation_suite: {s} (pass={d} fail={d} skip={d})\n", .{ mutation_overall, pass_count, fail_count, skip_count });

    const stdout = compat.fs.stdoutWriter();
    stdout.print("{s}\n", .{evidence_dir}) catch {};

    if (overall_pass) return 0;
    return 2;
}

// ── Mutation runners ────────────────────────────────────────────────

fn runMutation(
    alloc: std.mem.Allocator,
    self_exe: []const u8,
    pub_path: []const u8,
    tsf_path: []const u8,
    file_size: u64,
    comptime name: []const u8,
    expected_exit: u8,
) MutationResult {
    std.debug.print("  mutation: {s}\n", .{name});

    // Create temp dir
    const tmp_dir = std.fmt.allocPrint(alloc, "/tmp/.tsunagi_mut_{s}_{d}", .{
        name, @as(u64, @intCast(@max(@as(i64, 0), compat.timestamp()))),
    }) catch return .{ .name = name, .expected = expected_exit, .actual = 255, .result = "FAIL" };
    defer {
        compat.fs.cwd().deleteTree(tmp_dir) catch {};
        alloc.free(tmp_dir);
    }
    compat.fs.cwd().makePath(tmp_dir) catch return .{ .name = name, .expected = expected_exit, .actual = 255, .result = "FAIL" };

    const mut_tsf = std.fmt.allocPrint(alloc, "{s}/mutated.tsf", .{tmp_dir}) catch return .{ .name = name, .expected = expected_exit, .actual = 255, .result = "FAIL" };
    defer alloc.free(mut_tsf);
    const mut_sig = std.fmt.allocPrint(alloc, "{s}/mutated.tsf.sig", .{tmp_dir}) catch return .{ .name = name, .expected = expected_exit, .actual = 255, .result = "FAIL" };
    defer alloc.free(mut_sig);

    // Original .sig path
    const orig_sig = std.fmt.allocPrint(alloc, "{s}.sig", .{tsf_path}) catch return .{ .name = name, .expected = expected_exit, .actual = 255, .result = "FAIL" };
    defer alloc.free(orig_sig);

    if (std.mem.eql(u8, name, "tail_flip")) {
        // XOR byte at filesize-1024
        const offset = if (file_size > 1024) file_size - 1024 else 0;
        if (!copyFileWithMutation(alloc, tsf_path, mut_tsf, offset, 0xFF)) {
            return .{ .name = name, .expected = expected_exit, .actual = 255, .result = "FAIL" };
        }
        if (!copyFile(alloc, orig_sig, mut_sig)) {
            return .{ .name = name, .expected = expected_exit, .actual = 255, .result = "FAIL" };
        }
    } else if (std.mem.eql(u8, name, "head_flip")) {
        // XOR byte at offset 16
        if (!copyFileWithMutation(alloc, tsf_path, mut_tsf, 16, 0xFF)) {
            return .{ .name = name, .expected = expected_exit, .actual = 255, .result = "FAIL" };
        }
        if (!copyFile(alloc, orig_sig, mut_sig)) {
            return .{ .name = name, .expected = expected_exit, .actual = 255, .result = "FAIL" };
        }
    } else if (std.mem.eql(u8, name, "truncate")) {
        // Copy minus last byte
        if (!copyFileTruncated(alloc, tsf_path, mut_tsf)) {
            return .{ .name = name, .expected = expected_exit, .actual = 255, .result = "FAIL" };
        }
        if (!copyFile(alloc, orig_sig, mut_sig)) {
            return .{ .name = name, .expected = expected_exit, .actual = 255, .result = "FAIL" };
        }
    } else if (std.mem.eql(u8, name, "append")) {
        // Copy + null byte at end
        if (!copyFileAppended(alloc, tsf_path, mut_tsf, 0x00)) {
            return .{ .name = name, .expected = expected_exit, .actual = 255, .result = "FAIL" };
        }
        if (!copyFile(alloc, orig_sig, mut_sig)) {
            return .{ .name = name, .expected = expected_exit, .actual = 255, .result = "FAIL" };
        }
    } else if (std.mem.eql(u8, name, "random_sig")) {
        // Copy TSF + 89 random bytes as .sig
        if (!copyFile(alloc, tsf_path, mut_tsf)) {
            return .{ .name = name, .expected = expected_exit, .actual = 255, .result = "FAIL" };
        }
        // Write 89 random-ish bytes as .sig
        var sf = compat.fs.cwd().createFile(mut_sig, .{ .truncate = true }) catch {
            return .{ .name = name, .expected = expected_exit, .actual = 255, .result = "FAIL" };
        };
        defer sf.close();
        var rand_bytes: [89]u8 = undefined;
        // Use timestamp-based pseudorandom fill
        const seed: u64 = @intCast(@max(@as(i64, 0), compat.timestamp()));
        for (&rand_bytes, 0..) |*b, i| {
            b.* = @truncate(seed +% @as(u64, i) *% 251 +% 37);
        }
        sf.writeAll(&rand_bytes) catch {};
    } else if (std.mem.eql(u8, name, "missing_sig")) {
        // Copy TSF, no .sig
        if (!copyFile(alloc, tsf_path, mut_tsf)) {
            return .{ .name = name, .expected = expected_exit, .actual = 255, .result = "FAIL" };
        }
        // Deliberately no .sig file
    }

    // Run verify on mutated file
    const actual_exit = spawnAndWaitExit(alloc, &[_][]const u8{
        self_exe, "snapshot-verify", "--file", mut_tsf, "--pubkey-file", pub_path,
    });

    const result_str: []const u8 = if (actual_exit == expected_exit) "PASS" else "FAIL";
    if (!std.mem.eql(u8, result_str, "PASS")) {
        std.debug.print("  FAIL: {s} expected exit={d} got exit={d}\n", .{ name, expected_exit, actual_exit });
    }
    return .{ .name = name, .expected = expected_exit, .actual = actual_exit, .result = result_str };
}

fn runMutationSigSwap(
    alloc: std.mem.Allocator,
    self_exe: []const u8,
    pub_path: []const u8,
    tsf_path: []const u8,
    swap_sig_path: []const u8,
) MutationResult {
    std.debug.print("  mutation: sig_swap\n", .{});

    const tmp_dir = std.fmt.allocPrint(alloc, "/tmp/.tsunagi_mut_sig_swap_{d}", .{
        @as(u64, @intCast(@max(@as(i64, 0), compat.timestamp()))),
    }) catch return .{ .name = "sig_swap", .expected = 2, .actual = 255, .result = "FAIL" };
    defer {
        compat.fs.cwd().deleteTree(tmp_dir) catch {};
        alloc.free(tmp_dir);
    }
    compat.fs.cwd().makePath(tmp_dir) catch return .{ .name = "sig_swap", .expected = 2, .actual = 255, .result = "FAIL" };

    const mut_tsf = std.fmt.allocPrint(alloc, "{s}/mutated.tsf", .{tmp_dir}) catch return .{ .name = "sig_swap", .expected = 2, .actual = 255, .result = "FAIL" };
    defer alloc.free(mut_tsf);
    const mut_sig = std.fmt.allocPrint(alloc, "{s}/mutated.tsf.sig", .{tmp_dir}) catch return .{ .name = "sig_swap", .expected = 2, .actual = 255, .result = "FAIL" };
    defer alloc.free(mut_sig);

    // Copy TSF and swap sig
    if (!copyFile(alloc, tsf_path, mut_tsf)) {
        return .{ .name = "sig_swap", .expected = 2, .actual = 255, .result = "FAIL" };
    }
    if (!copyFile(alloc, swap_sig_path, mut_sig)) {
        return .{ .name = "sig_swap", .expected = 2, .actual = 255, .result = "FAIL" };
    }

    const actual_exit = spawnAndWaitExit(alloc, &[_][]const u8{
        self_exe, "snapshot-verify", "--file", mut_tsf, "--pubkey-file", pub_path,
    });

    const result_str: []const u8 = if (actual_exit == 2) "PASS" else "FAIL";
    if (!std.mem.eql(u8, result_str, "PASS")) {
        std.debug.print("  FAIL: sig_swap expected exit=2 got exit={d}\n", .{actual_exit});
    }
    return .{ .name = "sig_swap", .expected = 2, .actual = actual_exit, .result = result_str };
}

// ── Process helpers ─────────────────────────────────────────────────

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

// ── File helpers ────────────────────────────────────────────────────

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

fn copyFileWithMutation(alloc: std.mem.Allocator, src: []const u8, dst: []const u8, offset: u64, mask: u8) bool {
    _ = alloc;
    var inf = compat.fs.cwd().openFile(src, .{}) catch return false;
    defer inf.close();
    var outf = compat.fs.cwd().createFile(dst, .{ .truncate = true }) catch return false;
    defer outf.close();
    var buf: [8192]u8 = undefined;
    var pos: u64 = 0;
    while (true) {
        const n = inf.read(&buf) catch return false;
        if (n == 0) break;
        // XOR byte at target offset if it falls within this chunk
        if (offset >= pos and offset < pos + n) {
            const local: usize = @intCast(offset - pos);
            buf[local] ^= mask;
        }
        outf.writeAll(buf[0..n]) catch return false;
        pos += n;
    }
    return true;
}

fn copyFileTruncated(alloc: std.mem.Allocator, src: []const u8, dst: []const u8) bool {
    _ = alloc;
    var inf = compat.fs.cwd().openFile(src, .{}) catch return false;
    defer inf.close();
    const stat = inf.stat() catch return false;
    if (stat.size == 0) return false;
    const target_size = stat.size - 1;
    var outf = compat.fs.cwd().createFile(dst, .{ .truncate = true }) catch return false;
    defer outf.close();
    var buf: [8192]u8 = undefined;
    var written: u64 = 0;
    while (written < target_size) {
        const remaining = target_size - written;
        const to_read: usize = @intCast(@min(remaining, buf.len));
        const n = inf.read(buf[0..to_read]) catch return false;
        if (n == 0) break;
        outf.writeAll(buf[0..n]) catch return false;
        written += n;
    }
    return true;
}

fn copyFileAppended(alloc: std.mem.Allocator, src: []const u8, dst: []const u8, byte: u8) bool {
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
    outf.writeAll(&[_]u8{byte}) catch return false;
    return true;
}

fn findSwapSig(alloc: std.mem.Allocator, tsf_dir: []const u8, exclude_basename: []const u8) ?[]const u8 {
    var dir = compat.fs.cwd().openDir(tsf_dir, .{ .iterate = true }) catch return null;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".tsf.sig")) continue;
        // Exclude the current TSF's sig
        const expected_sig_name = std.fmt.allocPrint(alloc, "{s}.sig", .{exclude_basename}) catch continue;
        defer alloc.free(expected_sig_name);
        if (std.mem.eql(u8, entry.name, expected_sig_name)) continue;
        // Found another sig
        const full = std.fmt.allocPrint(alloc, "{s}/{s}", .{ tsf_dir, entry.name }) catch continue;
        return full;
    }
    return null;
}

// ── Version detection ───────────────────────────────────────────────

fn detectVersion(alloc: std.mem.Allocator, self_exe: []const u8, evidence_dir: []const u8) ?[]const u8 {
    var buf: [512]u8 = undefined;
    const result = runCaptureStderrWithExit(alloc, &[_][]const u8{ self_exe, "--version" }, &buf) orelse return null;
    const version_line = std.mem.trimEnd(u8, buf[0..result.len], "\n\r \t");

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/version.txt", .{evidence_dir}) catch return null;

    var content_buf: [1024]u8 = undefined;
    const content = std.fmt.bufPrint(&content_buf, "{s}\nsnapshot-proof v4.1.0\n", .{version_line}) catch return null;
    _ = writeFileContent(path, content);

    return alloc.dupe(u8, version_line) catch null;
}

// ── SHA256 file hash ────────────────────────────────────────────────

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

// ── SHA256SUMS ──────────────────────────────────────────────────────

fn writeSha256Sums(alloc: std.mem.Allocator, evidence_dir: []const u8) void {
    var files = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (files.items) |s| alloc.free(s);
        files.deinit();
    }

    collectFilesRecursive(alloc, evidence_dir, evidence_dir, &files);

    std.sort.insertion([]u8, files.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

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
            if (std.mem.eql(u8, current, base) and std.mem.eql(u8, entry.name, "SHA256SUMS")) continue;
            const full = std.fmt.allocPrint(alloc, "{s}/{s}", .{ current, entry.name }) catch continue;
            defer alloc.free(full);
            if (full.len > base.len + 1) {
                const rel = full[base.len + 1 ..];
                list.append(alloc.dupe(u8, rel) catch continue) catch continue;
            }
        }
    }
}

// ── Zero-secrets scan (with pubkey_hex.txt exception) ───────────────

fn scanForSecrets(alloc: std.mem.Allocator, evidence_dir: []const u8) bool {
    const max_file_size: u64 = 5 * 1024 * 1024;

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

        // Check if filename contains "key" — except pubkey_hex.txt
        const basename = if (std.mem.lastIndexOfScalar(u8, rel_path, '/')) |idx|
            rel_path[idx + 1 ..]
        else
            rel_path;

        if (std.mem.indexOf(u8, basename, "key") != null) {
            // Exception: pubkey_hex.txt is allowed
            if (!std.mem.eql(u8, basename, "pubkey_hex.txt")) {
                std.debug.print("SECRETS: filename contains 'key': {s}\n", .{rel_path});
                return false;
            }
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

fn writeSnapshotProofManifest(
    alloc: std.mem.Allocator,
    evidence_dir: []const u8,
    unix_now: u64,
    version_str: ?[]const u8,
    strict: bool,
    net_name: ?[]const u8,
    tsf_path: []const u8,
    snap_basename: []const u8,
    snap_hex: []const u8,
    snap_size: u64,
    slot: u64,
    block_no: u64,
    pubkey_hex: []const u8,
    verify_original: []const u8,
    verify_signed: []const u8,
    mutation_suite: []const u8,
    pass_count: u32,
    fail_count: u32,
    skip_count: u32,
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
    w.print("\"unix\":{d},", .{unix_now}) catch return;
    w.print("\"strict\":{s},", .{if (strict) "true" else "false"}) catch return;
    w.print("\"mode\":\"snapshot_proof\",", .{}) catch return;
    // Snapshot
    w.print("\"snapshot\":{{", .{}) catch return;
    w.print("\"path\":\"{s}\",", .{tsf_path}) catch return;
    w.print("\"basename\":\"{s}\",", .{snap_basename}) catch return;
    w.print("\"sha256\":\"{s}\",", .{snap_hex}) catch return;
    w.print("\"bytes\":{d},", .{snap_size}) catch return;
    w.print("\"slot\":{d},", .{slot}) catch return;
    w.print("\"block_no\":{d}", .{block_no}) catch return;
    w.print("}},", .{}) catch return;
    w.print("\"pubkey_hex\":\"{s}\",", .{pubkey_hex}) catch return;
    // Results
    w.print("\"results\":{{", .{}) catch return;
    w.print("\"verify_original\":\"{s}\",", .{verify_original}) catch return;
    w.print("\"verify_signed\":\"{s}\",", .{verify_signed}) catch return;
    w.print("\"mutation_suite\":\"{s}\"", .{mutation_suite}) catch return;
    w.print("}},", .{}) catch return;
    // Notes
    w.print("\"notes\":[", .{}) catch return;
    var notes_count: u32 = 0;
    if (std.mem.eql(u8, verify_original, "FAIL")) {
        if (notes_count > 0) w.writeAll(",") catch {};
        w.print("\"original TSF was unsigned or had different key\"", .{}) catch return;
        notes_count += 1;
    }
    if (net_name) |n| {
        if (notes_count > 0) w.writeAll(",") catch {};
        w.print("\"net: {s}\"", .{n}) catch return;
        notes_count += 1;
    }
    if (skip_count > 0) {
        if (notes_count > 0) w.writeAll(",") catch {};
        w.print("\"mutation skip_count: {d} (sig_swap requires another .tsf.sig in same dir)\"", .{skip_count}) catch return;
        notes_count += 1;
    }
    if (fail_count > 0) {
        if (notes_count > 0) w.writeAll(",") catch {};
        w.print("\"mutation fail_count: {d} (mutations that were not rejected)\"", .{fail_count}) catch return;
        notes_count += 1;
    }
    _ = pass_count;
    w.print("]", .{}) catch return;
    w.print("}}\n", .{}) catch return;
}
