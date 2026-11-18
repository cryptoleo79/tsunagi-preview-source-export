const std = @import("std");
const compat = @import("compat");

// Global atomic counters — read from any thread (metrics server, console)
pub var g_current_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var g_peak_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var g_baseline_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var g_peak_increase_events: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var g_peak_last_unix: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var g_start_unix: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub const CountingAllocator = struct {
    inner: std.mem.Allocator,

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = std.mem.Allocator.noRemap,
        .free = freeFn,
    };

    pub fn init(inner: std.mem.Allocator) CountingAllocator {
        return .{ .inner = inner };
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn allocFn(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.inner.rawAlloc(len, ptr_align, ret_addr);
        if (result != null) {
            trackAlloc(len);
        }
        return result;
    }

    fn resizeFn(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.inner.rawResize(buf, buf_align, new_len, ret_addr);
        if (ok) {
            if (new_len > buf.len) {
                trackAlloc(new_len - buf.len);
            } else if (buf.len > new_len) {
                trackFree(buf.len - new_len);
            }
        }
        return ok;
    }

    fn freeFn(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        trackFree(buf.len);
        self.inner.rawFree(buf, buf_align, ret_addr);
    }
};

fn trackAlloc(len: usize) void {
    const prev = g_current_bytes.fetchAdd(len, .acq_rel);
    const new_current = prev +| len;
    // Update peak via CAS loop
    var peak = g_peak_bytes.load(.acquire);
    while (new_current > peak) {
        const result = g_peak_bytes.cmpxchgWeak(peak, new_current, .acq_rel, .acquire);
        if (result) |old| {
            peak = old;
        } else {
            // Peak was updated — check if past warmup
            const start = g_start_unix.load(.acquire);
            const now: u64 = @intCast(@max(@as(i64, 0), compat.timestamp()));
            if (start > 0 and now -| start >= 60) {
                _ = g_peak_increase_events.fetchAdd(1, .acq_rel);
            }
            g_peak_last_unix.store(now, .release);
            break;
        }
    }
}

fn trackFree(len: usize) void {
    _ = g_current_bytes.fetchSub(len, .acq_rel);
}

pub fn captureBaseline() void {
    const current = g_current_bytes.load(.acquire);
    g_baseline_bytes.store(current, .release);
    const now: u64 = @intCast(@max(@as(i64, 0), compat.timestamp()));
    g_start_unix.store(now, .release);
    g_peak_last_unix.store(now, .release);
}
