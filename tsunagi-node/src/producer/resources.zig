// Self-resource reporting for /status/full.
//
// Exposes CPU%, RSS bytes, and disk% for the node's own process and the
// TSUNAGI_HOME mount, so operators see the node's own footprint inline
// without needing to run `top` / `df` in parallel.
//
// Sources (Linux only — best-effort everywhere else):
//   - CPU%   : /proc/self/stat fields 14 (utime) + 15 (stime), delta over
//              wall-time elapsed since the previous sample.
//   - RSS    : /proc/self/status VmRSS line (mirrors http_metrics.readRssKb).
//   - Disk%  : C statvfs() on TSUNAGI_HOME (mirrors guardian_cmd disk check).
//
// Design constraints:
//   - Fixed-size buffers; no allocator. Memory-locked policy.
//   - Any I/O failure → return zero/default values, never crash.
//   - sampleResources() is safe to call from any thread; mutex guards the
//     last-sample cache used to compute the CPU delta.

const std = @import("std");
const compat = @import("compat");

pub const Snapshot = struct {
    cpu_pct: f32 = 0.0, // 0..100
    mem_rss_bytes: u64 = 0,
    disk_pct: f32 = 0.0, // 0..100
    sample_unix: i64 = 0,
};

const State = struct {
    mu: compat.Mutex = .{},
    last_utime_ticks: u64 = 0,
    last_stime_ticks: u64 = 0,
    last_sample_unix: i64 = 0,
    last_snapshot: Snapshot = .{},
    primed: bool = false,
};

var g_state: State = .{};

// Linux default for _SC_CLK_TCK on x86_64. Kept as a constant so the
// module stays free of libc calls at runtime.
const CLK_TCK_HZ: f64 = 100.0;

/// Read VmRSS from /proc/self/status (KB → bytes). Returns 0 on any failure.
fn readRssBytes() u64 {
    var f = compat.fs.cwd().openFile("/proc/self/status", .{}) catch return 0;
    defer f.close();
    var buf: [4096]u8 = undefined;
    const n = f.read(&buf) catch return 0;
    if (n == 0) return 0;
    const data = buf[0..n];
    const key = "VmRSS:";
    const pos = std.mem.indexOf(u8, data, key) orelse return 0;
    var i = pos + key.len;
    while (i < data.len and (data[i] == ' ' or data[i] == '\t')) : (i += 1) {}
    if (i >= data.len) return 0;
    var end = i;
    while (end < data.len and data[end] >= '0' and data[end] <= '9') : (end += 1) {}
    if (end == i) return 0;
    const kb = std.fmt.parseUnsigned(u64, data[i..end], 10) catch return 0;
    return kb * 1024;
}

const CpuTicks = struct { utime: u64, stime: u64 };

/// Parse utime (field 14) + stime (field 15) from /proc/self/stat.
/// The comm field (#2) is parenthesized and may itself contain spaces or
/// parens, so we anchor on the LAST `)` and tokenize from there.
fn readCpuTicks() ?CpuTicks {
    var f = compat.fs.cwd().openFile("/proc/self/stat", .{}) catch return null;
    defer f.close();
    var buf: [4096]u8 = undefined;
    const n = f.read(&buf) catch return null;
    if (n == 0) return null;
    return parseCpuTicks(buf[0..n]);
}

/// Pure parser, exposed via test-private extraction so the parsing logic
/// can be exercised without touching /proc.
fn parseCpuTicks(data: []const u8) ?CpuTicks {
    const last_paren = std.mem.lastIndexOfScalar(u8, data, ')') orelse return null;
    // Fields after the closing paren are space-separated and start at
    // field #3 (state). utime is field #14, stime is field #15 — i.e.
    // tokens 11 and 12 after the closing paren (1-indexed: state=1,
    // ppid=2, pgrp=3, session=4, tty_nr=5, tpgid=6, flags=7, minflt=8,
    // cminflt=9, majflt=10, cmajflt=11, utime=12, stime=13).
    var i: usize = last_paren + 1;
    var field_idx: usize = 0;
    var utime: u64 = 0;
    var stime: u64 = 0;
    while (i < data.len) {
        // Skip whitespace.
        while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == '\n')) : (i += 1) {}
        if (i >= data.len) break;
        const start = i;
        while (i < data.len and data[i] != ' ' and data[i] != '\t' and data[i] != '\n') : (i += 1) {}
        const tok = data[start..i];
        field_idx += 1;
        if (field_idx == 12) {
            utime = std.fmt.parseUnsigned(u64, tok, 10) catch return null;
        } else if (field_idx == 13) {
            stime = std.fmt.parseUnsigned(u64, tok, 10) catch return null;
            return .{ .utime = utime, .stime = stime };
        }
    }
    return null;
}

/// statvfs() on `path`, return used%. 0.0 on any failure.
fn readDiskPercent(path: []const u8) f32 {
    const c = @cImport(@cInclude("sys/statvfs.h"));
    var path_buf: [512]u8 = undefined;
    const z = std.fmt.bufPrint(&path_buf, "{s}\x00", .{path}) catch return 0.0;
    if (z.len <= 1) return 0.0;
    const path_ptr: [*:0]const u8 = @ptrCast(z.ptr);
    var stat: c.struct_statvfs = undefined;
    const rc = c.statvfs(path_ptr, &stat);
    if (rc != 0) return 0.0;
    if (stat.f_blocks == 0) return 0.0;
    const total: f64 = @floatFromInt(stat.f_blocks);
    const free_blocks: f64 = @floatFromInt(stat.f_bfree);
    const used: f64 = total - free_blocks;
    if (used <= 0.0) return 0.0;
    const pct: f64 = used * 100.0 / total;
    return @floatCast(pct);
}

/// Sample the live resource view and update the cached snapshot.
/// `tsunagi_home` is used for disk%; when null the disk metric stays 0.
pub fn sampleResources(tsunagi_home: ?[]const u8) Snapshot {
    const now_unix: i64 = compat.timestamp();
    const ticks_now_opt = readCpuTicks();
    const rss_bytes = readRssBytes();
    const disk_pct: f32 = if (tsunagi_home) |home| readDiskPercent(home) else 0.0;

    g_state.mu.lock();
    defer g_state.mu.unlock();

    var cpu_pct: f32 = 0.0;
    if (ticks_now_opt) |t| {
        if (g_state.primed and now_unix > g_state.last_sample_unix) {
            const wall_secs: f64 = @floatFromInt(now_unix - g_state.last_sample_unix);
            const prev_total = g_state.last_utime_ticks + g_state.last_stime_ticks;
            const now_total = t.utime + t.stime;
            const delta_ticks: u64 = if (now_total >= prev_total) now_total - prev_total else 0;
            const dt_f: f64 = @floatFromInt(delta_ticks);
            const pct_f: f64 = (dt_f / (wall_secs * CLK_TCK_HZ)) * 100.0;
            const clamped: f64 = if (pct_f < 0.0) 0.0 else if (pct_f > 100.0) 100.0 else pct_f;
            cpu_pct = @floatCast(clamped);
        }
        g_state.last_utime_ticks = t.utime;
        g_state.last_stime_ticks = t.stime;
        g_state.last_sample_unix = now_unix;
        g_state.primed = true;
    }

    const snap: Snapshot = .{
        .cpu_pct = cpu_pct,
        .mem_rss_bytes = rss_bytes,
        .disk_pct = disk_pct,
        .sample_unix = now_unix,
    };
    g_state.last_snapshot = snap;
    return snap;
}

/// Render the cached snapshot as compact JSON. Caller-owned buf.
/// Returns 0 if the buffer is too small (caller treats as empty section).
pub fn renderJson(buf: []u8) usize {
    g_state.mu.lock();
    const snap = g_state.last_snapshot;
    g_state.mu.unlock();

    var w = compat.fixedBufferStream(buf);
    w.writer().print(
        "{{\"cpu_pct\":{d:.2},\"mem_rss_bytes\":{d},\"disk_pct\":{d:.2},\"sample_unix\":{d}}}",
        .{ snap.cpu_pct, snap.mem_rss_bytes, snap.disk_pct, snap.sample_unix },
    ) catch return 0;
    return w.pos;
}

// ── Tests ──────────────────────────────────────────────────────────

test "parseCpuTicks parses simple stat line" {
    // Fields: pid (comm) state ppid pgrp session tty_nr tpgid flags
    //         minflt cminflt majflt cmajflt utime stime ...
    const sample =
        "1234 (tsunagi-node) S 1 1234 1234 0 -1 4194304 " ++
        "100 200 0 0 4242 1337 0 0 20 0 1 0 100 0 0 0\n";
    const t = parseCpuTicks(sample) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u64, 4242), t.utime);
    try std.testing.expectEqual(@as(u64, 1337), t.stime);
}

test "parseCpuTicks tolerates parens inside comm" {
    // comm with embedded `) (` to confirm we anchor on the LAST `)`.
    const sample =
        "9999 (weird) name) R 1 9999 9999 0 -1 0 " ++
        "0 0 0 0 999 111 0 0 20 0 1 0 0 0 0\n";
    const t = parseCpuTicks(sample) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u64, 999), t.utime);
    try std.testing.expectEqual(@as(u64, 111), t.stime);
}

test "parseCpuTicks returns null on truncated input" {
    const sample = "1 (x) R 1 1 1 0 -1 0 0 0 0 0\n"; // no utime/stime
    try std.testing.expect(parseCpuTicks(sample) == null);
}

test "renderJson emits expected keys" {
    g_state = .{};
    g_state.last_snapshot = .{
        .cpu_pct = 1.25,
        .mem_rss_bytes = 3_741_319_168,
        .disk_pct = 8.0,
        .sample_unix = 1_745_000_000,
    };
    var buf: [256]u8 = undefined;
    const n = renderJson(&buf);
    const out = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, out, "\"cpu_pct\":1.25") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"mem_rss_bytes\":3741319168") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"disk_pct\":8.00") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"sample_unix\":1745000000") != null);
}

test "sampleResources is safe with null home" {
    g_state = .{};
    const s1 = sampleResources(null);
    // First sample primes the state — cpu_pct should be 0.0.
    try std.testing.expectEqual(@as(f32, 0.0), s1.cpu_pct);
    try std.testing.expect(s1.sample_unix > 0);
    // disk_pct must be 0 when no home is provided.
    try std.testing.expectEqual(@as(f32, 0.0), s1.disk_pct);
}
