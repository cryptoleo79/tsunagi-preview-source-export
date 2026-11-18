const std = @import("std");
const compat = @import("compat");

/// Slot-range interval set for tracking processed chain coverage.
/// Maintains a sorted, non-overlapping list of covered slot ranges.
/// Used to identify gaps in CBOR archive or block processing coverage.
pub const SlotRange = struct {
    start: u64,
    end: u64, // inclusive
};

pub const CoverageMap = struct {
    ranges: std.array_list.Managed(SlotRange),

    pub fn init(alloc: std.mem.Allocator) CoverageMap {
        return .{ .ranges = std.array_list.Managed(SlotRange).init(alloc) };
    }

    pub fn deinit(self: *CoverageMap) void {
        self.ranges.deinit();
    }

    /// Add a covered slot range [start, end] (inclusive).
    /// Merges with any overlapping or adjacent existing ranges.
    pub fn addRange(self: *CoverageMap, start: u64, end: u64) void {
        if (start > end) return;

        var merged = SlotRange{ .start = start, .end = end };

        // Remove all ranges that overlap or are adjacent to the new range.
        // A range [a,b] overlaps/adjoins [start,end] when a <= end+1 and b+1 >= start.
        var i: usize = 0;
        while (i < self.ranges.items.len) {
            const r = self.ranges.items[i];
            if (r.start <= merged.end +| 1 and r.end +| 1 >= merged.start) {
                merged.start = @min(merged.start, r.start);
                merged.end = @max(merged.end, r.end);
                _ = self.ranges.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        // Insert merged range in sorted position
        var pos: usize = 0;
        while (pos < self.ranges.items.len and self.ranges.items[pos].start < merged.start) {
            pos += 1;
        }
        self.ranges.insert(pos, merged) catch return;
    }

    /// Return uncovered slot ranges within [from, to] (inclusive).
    pub fn gaps(self: *const CoverageMap, alloc: std.mem.Allocator, from: u64, to: u64) []SlotRange {
        if (from > to) return &.{};

        var result = std.array_list.Managed(SlotRange).init(alloc);
        var cursor: u64 = from;

        for (self.ranges.items) |r| {
            if (r.end < from) continue;
            if (r.start > to) break;

            if (r.start > cursor) {
                result.append(.{ .start = cursor, .end = @min(r.start - 1, to) }) catch return result.toOwnedSlice() catch &.{};
            }
            cursor = if (r.end >= to) to + 1 else r.end + 1;
        }

        if (cursor <= to) {
            result.append(.{ .start = cursor, .end = to }) catch {};
        }

        return result.toOwnedSlice() catch &.{};
    }

    /// Fraction of [from, to] that is covered. Returns 0.0..1.0.
    pub fn coverageRatio(self: *const CoverageMap, from: u64, to: u64) f64 {
        if (from > to) return 0.0;
        const total: f64 = @floatFromInt(to - from + 1);
        var covered: u64 = 0;

        for (self.ranges.items) |r| {
            if (r.end < from) continue;
            if (r.start > to) break;
            const lo = @max(r.start, from);
            const hi = @min(r.end, to);
            covered += hi - lo + 1;
        }

        return @as(f64, @floatFromInt(covered)) / total;
    }

    /// Total number of covered slots across all ranges.
    pub fn coveredCount(self: *const CoverageMap) u64 {
        var total: u64 = 0;
        for (self.ranges.items) |r| {
            total += r.end - r.start + 1;
        }
        return total;
    }

    /// Save to JSON file.
    pub fn save(self: *const CoverageMap, path: []const u8) !void {
        var buf = std.array_list.Managed(u8).init(self.ranges.allocator);
        defer buf.deinit();

        try buf.appendSlice("[");
        for (self.ranges.items, 0..) |r, i| {
            if (i > 0) try buf.appendSlice(",");
            var num_buf: [40]u8 = undefined;
            try buf.appendSlice("[");
            const s = std.fmt.bufPrint(&num_buf, "{d}", .{r.start}) catch unreachable;
            try buf.appendSlice(s);
            try buf.appendSlice(",");
            const e = std.fmt.bufPrint(&num_buf, "{d}", .{r.end}) catch unreachable;
            try buf.appendSlice(e);
            try buf.appendSlice("]");
        }
        try buf.appendSlice("]\n");

        var f = try compat.fs.cwd().createFile(path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(buf.items);
    }

    /// Load from JSON file. Format: [[start,end],[start,end],...]
    pub fn load(alloc: std.mem.Allocator, path: []const u8) !CoverageMap {
        var map = CoverageMap.init(alloc);

        const data = compat.fs.cwd().readFileAlloc(path, alloc, 1024 * 1024) catch return map;
        defer alloc.free(data);

        // Simple parser for [[n,n],[n,n],...] format
        var i: usize = 0;
        while (i < data.len) {
            // Find start of a pair: look for '[' after the outer '['
            if (data[i] == '[' and i > 0) {
                i += 1;
                // Parse start number
                const start_begin = i;
                while (i < data.len and data[i] >= '0' and data[i] <= '9') i += 1;
                if (i == start_begin) { i += 1; continue; }
                const start = std.fmt.parseUnsigned(u64, data[start_begin..i], 10) catch { i += 1; continue; };

                // Skip comma
                while (i < data.len and data[i] != ',') i += 1;
                i += 1;

                // Parse end number
                const end_begin = i;
                while (i < data.len and data[i] >= '0' and data[i] <= '9') i += 1;
                if (i == end_begin) { i += 1; continue; }
                const end = std.fmt.parseUnsigned(u64, data[end_begin..i], 10) catch { i += 1; continue; };

                map.addRange(start, end);
            } else {
                i += 1;
            }
        }

        return map;
    }
};

// --- Tests ---

test "addRange merges overlapping intervals" {
    var map = CoverageMap.init(std.testing.allocator);
    defer map.deinit();

    map.addRange(10, 20);
    map.addRange(30, 40);
    try std.testing.expectEqual(@as(usize, 2), map.ranges.items.len);

    // Overlapping merge
    map.addRange(15, 35);
    try std.testing.expectEqual(@as(usize, 1), map.ranges.items.len);
    try std.testing.expectEqual(@as(u64, 10), map.ranges.items[0].start);
    try std.testing.expectEqual(@as(u64, 40), map.ranges.items[0].end);
}

test "addRange merges adjacent intervals" {
    var map = CoverageMap.init(std.testing.allocator);
    defer map.deinit();

    map.addRange(10, 20);
    map.addRange(21, 30);
    try std.testing.expectEqual(@as(usize, 1), map.ranges.items.len);
    try std.testing.expectEqual(@as(u64, 10), map.ranges.items[0].start);
    try std.testing.expectEqual(@as(u64, 30), map.ranges.items[0].end);
}

test "gaps returns correct uncovered ranges" {
    const alloc = std.testing.allocator;
    var map = CoverageMap.init(alloc);
    defer map.deinit();

    map.addRange(10, 20);
    map.addRange(30, 40);

    const g = map.gaps(alloc, 0, 50);
    defer alloc.free(g);

    try std.testing.expectEqual(@as(usize, 3), g.len);
    // Gap 1: [0, 9]
    try std.testing.expectEqual(@as(u64, 0), g[0].start);
    try std.testing.expectEqual(@as(u64, 9), g[0].end);
    // Gap 2: [21, 29]
    try std.testing.expectEqual(@as(u64, 21), g[1].start);
    try std.testing.expectEqual(@as(u64, 29), g[1].end);
    // Gap 3: [41, 50]
    try std.testing.expectEqual(@as(u64, 41), g[2].start);
    try std.testing.expectEqual(@as(u64, 50), g[2].end);
}

test "coverageRatio computes correctly" {
    var map = CoverageMap.init(std.testing.allocator);
    defer map.deinit();

    // Empty map
    try std.testing.expectEqual(@as(f64, 0.0), map.coverageRatio(0, 99));

    // Full coverage
    map.addRange(0, 99);
    try std.testing.expectEqual(@as(f64, 1.0), map.coverageRatio(0, 99));

    // 50% coverage
    var map2 = CoverageMap.init(std.testing.allocator);
    defer map2.deinit();
    map2.addRange(0, 49);
    const ratio = map2.coverageRatio(0, 99);
    try std.testing.expect(ratio > 0.49 and ratio < 0.51);
}

test "coveredCount returns total slots" {
    var map = CoverageMap.init(std.testing.allocator);
    defer map.deinit();

    map.addRange(10, 20); // 11 slots
    map.addRange(30, 39); // 10 slots
    try std.testing.expectEqual(@as(u64, 21), map.coveredCount());
}

test "save and load round-trip" {
    const alloc = std.testing.allocator;
    const tmp_path = "/tmp/tsunagi_test_coverage.json";

    var map = CoverageMap.init(alloc);
    defer map.deinit();
    map.addRange(100, 200);
    map.addRange(300, 400);

    try map.save(tmp_path);
    defer compat.fs.cwd().deleteFile(tmp_path) catch {};

    var loaded = try CoverageMap.load(alloc, tmp_path);
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 2), loaded.ranges.items.len);
    try std.testing.expectEqual(@as(u64, 100), loaded.ranges.items[0].start);
    try std.testing.expectEqual(@as(u64, 200), loaded.ranges.items[0].end);
    try std.testing.expectEqual(@as(u64, 300), loaded.ranges.items[1].start);
    try std.testing.expectEqual(@as(u64, 400), loaded.ranges.items[1].end);
}

test "load from nonexistent file returns empty map" {
    const alloc = std.testing.allocator;
    var map = try CoverageMap.load(alloc, "/tmp/tsunagi_test_nonexistent_coverage.json");
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 0), map.ranges.items.len);
}
