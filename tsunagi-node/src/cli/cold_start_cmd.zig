const std = @import("std");
const compat = @import("compat");
const tsf = @import("../store/tsf.zig");

/// cold-start: import TSF snapshot into fresh LMDB, compute ledger digest.
///
/// Reuses existing CLI commands as subprocesses:
///   - snapshot-import (TSF → LMDB)
///   - ledger-harness digest (LMDB → Blake2b-256 digest via TSUNAGI_LMDB env)
///
/// Exit codes: 0=PASS, 2=digest mismatch, 3=strict/args, 4=IO/parse error.

pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    // ── Parse args ──
    var snapshot_path: ?[]const u8 = null;
    var out_lmdb: ?[]const u8 = null;
    var verify_digest: ?[]const u8 = null;
    var strict = false;
    var out_report: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--snapshot")) {
            snapshot_path = args_it.next() orelse {
                std.debug.print("ERROR: --snapshot requires a path\n", .{});
                return 3;
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--out-lmdb")) {
            out_lmdb = args_it.next() orelse {
                std.debug.print("ERROR: --out-lmdb requires a path\n", .{});
                return 3;
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--verify-digest")) {
            verify_digest = args_it.next() orelse {
                std.debug.print("ERROR: --verify-digest requires a hex string\n", .{});
                return 3;
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--out")) {
            out_report = args_it.next() orelse {
                std.debug.print("ERROR: --out requires a path\n", .{});
                return 3;
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--strict")) {
            strict = true;
            continue;
        }
        std.debug.print("ERROR: unknown flag: {s}\n", .{arg});
        return 3;
    }

    const snap = snapshot_path orelse {
        std.debug.print("ERROR: --snapshot required\n", .{});
        return 3;
    };
    const lmdb_dir = out_lmdb orelse {
        std.debug.print("ERROR: --out-lmdb required\n", .{});
        return 3;
    };

    // ── Validate snapshot file, read TSF header ──
    var snap_file = compat.fs.cwd().openFile(snap, .{}) catch {
        std.debug.print("ERROR: cannot open snapshot: {s}\n", .{snap});
        return 3;
    };
    const reader = snap_file.deprecatedReader();
    const header = tsf.readHeader(&reader) catch {
        snap_file.close();
        std.debug.print("ERROR: cannot read TSF header from {s}\n", .{snap});
        return 4;
    };
    snap_file.close();

    if (!std.mem.eql(u8, header.magic[0..4], "TSF2")) {
        std.debug.print("ERROR: invalid TSF magic (expected TSF2)\n", .{});
        return 4;
    }

    const slot = header.slot;
    const block_no = header.block_no;

    // ── Strict: out-lmdb must be empty or nonexistent ──
    if (strict) {
        if (compat.fs.cwd().openDir(lmdb_dir, .{ .iterate = true })) |*dir_handle| {
            var d = dir_handle.*;
            defer d.close();
            var it = d.iterate();
            if (it.next() catch null) |_| {
                std.debug.print("ERROR: --strict and out-lmdb is non-empty: {s}\n", .{lmdb_dir});
                return 3;
            }
        } else |_| {
            // Directory doesn't exist — OK, will be created by snapshot-import
        }
    }

    // ── Resolve self_exe ──
    var self_buf: [4096]u8 = undefined;
    const self_exe = compat.selfExePath(&self_buf) catch {
        std.debug.print("ERROR: cannot resolve self exe path\n", .{});
        return 4;
    };

    // ── Step 1: snapshot-import ──
    std.debug.print("cold-start: importing {s} -> {s}\n", .{ snap, lmdb_dir });

    const import_exit = spawnAndWaitExit(alloc, &[_][]const u8{
        self_exe, "snapshot-import", "--file", snap, "--lmdb", lmdb_dir, "--strict", "--allow-unsigned",
    });

    if (import_exit != 0) {
        std.debug.print("ERROR: snapshot-import failed (exit={d})\n", .{import_exit});
        return 4;
    }

    // ── Step 2: ledger-harness digest (via TSUNAGI_LMDB env) ──
    std.debug.print("cold-start: computing ledger digest from {s}\n", .{lmdb_dir});

    var digest_buf: [4096]u8 = undefined;
    const capture = spawnCaptureStderrWithEnv(alloc, &[_][]const u8{
        self_exe, "ledger-harness", "digest",
    }, "TSUNAGI_LMDB", lmdb_dir, &digest_buf) orelse {
        std.debug.print("ERROR: ledger-harness digest failed to spawn\n", .{});
        return 4;
    };

    if (capture.exit_code != 0) {
        std.debug.print("ERROR: ledger-harness digest failed (exit={d})\n", .{capture.exit_code});
        return 4;
    }

    // Parse stderr output for ledger_digest and utxo_entries
    const captured = digest_buf[0..capture.len];
    const digest_hex = parseField(captured, "ledger_digest: ") orelse {
        std.debug.print("ERROR: cannot parse ledger_digest from output\n", .{});
        return 4;
    };
    const utxo_str = parseField(captured, "utxo_entries: ") orelse {
        std.debug.print("ERROR: cannot parse utxo_entries from output\n", .{});
        return 4;
    };

    if (digest_hex.len != 64) {
        std.debug.print("ERROR: ledger_digest is {d} chars (expected 64)\n", .{digest_hex.len});
        return 4;
    }

    // ── Step 3: verify digest if requested ──
    if (verify_digest) |expected| {
        if (expected.len != 64) {
            std.debug.print("ERROR: --verify-digest must be 64 hex chars\n", .{});
            return 3;
        }
        if (!std.mem.eql(u8, digest_hex, expected)) {
            std.debug.print("FAIL: digest mismatch\n  expected: {s}\n  actual:   {s}\n", .{ expected, digest_hex });
            return 2;
        }
    }

    // ── Step 4: stdout (bounded) ──
    const stdout = compat.fs.stdoutWriter();
    stdout.print("out_lmdb={s}\n", .{lmdb_dir}) catch {};
    stdout.print("slot={d}\n", .{slot}) catch {};
    stdout.print("block_no={d}\n", .{block_no}) catch {};
    stdout.print("utxo_entries={s}\n", .{utxo_str}) catch {};
    stdout.print("ledger_digest_hex={s}\n", .{digest_hex}) catch {};
    stdout.print("EXIT=0\n", .{}) catch {};

    // ── Step 5: write JSON report if --out ──
    if (out_report) |report_path| {
        var f = compat.fs.cwd().createFile(report_path, .{ .truncate = true }) catch {
            std.debug.print("ERROR: cannot write report: {s}\n", .{report_path});
            return 4;
        };
        defer f.close();
        const w = f.deprecatedWriter();
        w.print("{{\"out_lmdb\":\"{s}\",\"slot\":{d},\"block_no\":{d},\"utxo_entries\":{s},\"ledger_digest_hex\":\"{s}\"}}\n", .{ lmdb_dir, slot, block_no, utxo_str, digest_hex }) catch {
            std.debug.print("ERROR: write report failed\n", .{});
            return 4;
        };
    }

    return 0;
}

// ── Helpers ──

fn parseField(text: []const u8, prefix: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < text.len) {
        // Find start of line
        const line_start = pos;
        // Find end of line
        var line_end = pos;
        while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}
        const line = text[line_start..line_end];
        pos = if (line_end < text.len) line_end + 1 else line_end;

        if (std.mem.startsWith(u8, line, prefix)) {
            return line[prefix.len..];
        }
    }
    return null;
}

const CaptureResult = struct {
    exit_code: u8,
    len: usize,
};

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

fn spawnCaptureStderrWithEnv(
    alloc: std.mem.Allocator,
    argv: []const []const u8,
    env_key: []const u8,
    env_val: []const u8,
    buf: []u8,
) ?CaptureResult {
    var child = compat.Child.init(argv, alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;

    // Build env map with the extra variable
    var env_map = compat.EnvMap.init(alloc);
    defer env_map.deinit();
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
