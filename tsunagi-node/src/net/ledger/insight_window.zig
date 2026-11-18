const std = @import("std");

pub const WindowBucket = struct {
    window_start_unix: i64 = 0,
    blocks_in_window: u64 = 0,
    total_tx_count: u64 = 0,
    fees_lovelace: u64 = 0,
    ada_moved_lovelace: u64 = 0,
    script_tx_count: u64 = 0,
    cert_tx_count: u64 = 0,
    collateral_tx_count: u64 = 0,
    withdrawal_count: u32 = 0,
};

pub const InsightRing = struct {
    buckets: [12]WindowBucket = [_]WindowBucket{.{}} ** 12,
    idx: usize = 0,
    initialized: bool = false,

    pub fn init() InsightRing {
        return .{};
    }

    fn alignWindowStart(ts: i64) i64 {
        return ts - @mod(ts, 300);
    }

    fn ensureWindow(self: *InsightRing, ts: i64) void {
        const start = alignWindowStart(ts);

        if (!self.initialized) {
            self.initialized = true;
            self.idx = 0;
            self.buckets[self.idx] = .{ .window_start_unix = start };
            return;
        }

        const cur_start = self.buckets[self.idx].window_start_unix;
        if (start == cur_start) return;

        if (start < cur_start) return;

        var next_start = cur_start + 300;
        while (next_start <= start) : (next_start += 300) {
            self.idx = (self.idx + 1) % self.buckets.len;
            self.buckets[self.idx] = .{ .window_start_unix = next_start };
        }
    }

    pub fn record(
        self: *InsightRing,
        ts: i64,
        total_tx_count: u64,
        fees_lovelace: u64,
        ada_moved_lovelace: u64,
        script_tx_count: u64,
        cert_tx_count: u64,
        collateral_tx_count: u64,
        withdrawal_count: u32,
    ) void {
        self.ensureWindow(ts);

        var b = &self.buckets[self.idx];
        b.blocks_in_window += 1;
        b.total_tx_count += total_tx_count;
        b.fees_lovelace += fees_lovelace;
        b.ada_moved_lovelace += ada_moved_lovelace;
        b.script_tx_count += script_tx_count;
        b.cert_tx_count += cert_tx_count;
        b.collateral_tx_count += collateral_tx_count;
        b.withdrawal_count += withdrawal_count;
    }

    pub fn getCurrent(self: *const InsightRing) WindowBucket {
        if (!self.initialized) return .{};
        return self.buckets[self.idx];
    }

    pub fn latestCompleted(self: *const InsightRing) ?WindowBucket {
        if (!self.initialized) return null;
        const prev = if (self.idx == 0) self.buckets.len - 1 else self.idx - 1;
        if (self.buckets[prev].window_start_unix == 0) return null;
        return self.buckets[prev];
    }
};
