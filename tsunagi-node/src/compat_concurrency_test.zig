//! Empirical concurrency proof for the compat shim's global Io routing.
//!
//! TSUNAGI is multi-threaded (std.Thread.spawn across producer/propagation/
//! chainsync/pollers/metrics). Every compat.* fs/time/net/Mutex op routes
//! through std.Io.Threaded.global_single_threaded.io(). This test hammers
//! those ops from many REAL OS threads concurrently to demonstrate the global
//! instance is safe to call from multiple threads at once.
//!
//! The argument (see analysis): on Linux every fs/time vtable fn ignores the
//! Threaded `userdata` (`_ = t`) and issues a direct stateless syscall on a
//! per-call stack buffer; Mutex/futex operate only on the caller's own atomic.
//! `Thread.current` (the Io.Threaded threadlocal) is null on raw std.Thread
//! threads, so cancel bookkeeping is a no-op. This test exercises that path.
//!
//! Run: zig test src/compat_concurrency_test.zig
//! Author: cryptoleo79.
const std = @import("std");
const compat = @import("compat.zig");

const N_THREADS = 16;
const ITERS = 400;

var g_mutex: compat.Mutex = .{};
var g_counter: u64 = 0;

const Ctx = struct {
    id: usize,
    dir: []const u8,
    err: ?anyerror = null,
};

fn worker(ctx: *Ctx) void {
    run(ctx) catch |e| {
        ctx.err = e;
    };
}

fn run(ctx: *Ctx) !void {
    var alloc_buf: [1 << 16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&alloc_buf);
    const a = fba.allocator();

    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        // ── time ops (now -> clock_gettime, stateless) ──
        const t0 = compat.nanoTimestamp();
        const t1 = compat.milliTimestamp();
        const t2 = compat.timestamp();
        std.mem.doNotOptimizeAway(t0);
        std.mem.doNotOptimizeAway(t1);
        std.mem.doNotOptimizeAway(t2);

        // ── Mutex (shared global) protecting a shared counter ──
        g_mutex.lock();
        g_counter += 1;
        g_mutex.unlock();

        // ── filesystem: each thread writes+reads its OWN file ──
        var name_buf: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&name_buf, "{s}/t{d}_{d}.bin", .{ ctx.dir, ctx.id, i % 4 });

        var payload: [256]u8 = undefined;
        const written = try std.fmt.bufPrint(&payload, "thread={d} iter={d} stamp={d}", .{ ctx.id, i, t0 });

        {
            var f = try compat.fs.cwd().createFile(path, .{ .truncate = true });
            defer f.close();
            try f.writeAll(written);
            try f.sync();
        }
        {
            var f = try compat.fs.cwd().openFile(path, .{ .mode = .read_only });
            defer f.close();
            const got = try f.readToEndAlloc(a, 4096);
            defer a.free(got);
            if (!std.mem.eql(u8, got, written)) return error.FileContentMismatch;
        }
        fba.reset();
    }
}

test "compat global Io is concurrency-safe across many OS threads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Resolve an absolute path for the tmp dir so compat.fs.cwd() ops are unambiguous.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(compat.defaultIo(), &path_buf);
    const dir = path_buf[0..dir_len];

    var ctxs: [N_THREADS]Ctx = undefined;
    var threads: [N_THREADS]std.Thread = undefined;

    for (&ctxs, 0..) |*c, idx| c.* = .{ .id = idx, .dir = dir };
    for (&threads, 0..) |*th, idx| th.* = try std.Thread.spawn(.{}, worker, .{&ctxs[idx]});
    for (&threads) |th| th.join();

    for (&ctxs) |c| {
        if (c.err) |e| {
            std.debug.print("worker {d} failed: {s}\n", .{ c.id, @errorName(e) });
            return e;
        }
    }
    try std.testing.expectEqual(@as(u64, N_THREADS * ITERS), g_counter);
}
