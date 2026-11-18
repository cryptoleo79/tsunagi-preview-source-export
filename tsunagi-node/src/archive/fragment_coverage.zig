const std = @import("std");

/// Lightweight slot+hash info for fragment ancestry analysis.
/// Defined locally to avoid importing chainsync_server.zig (which
/// would pull transitive dependencies into archive test discovery).
/// Callers convert FragmentEntry → FragmentSlotInfo before calling
/// analyzeFragment().
pub const FragmentSlotInfo = struct {
    slot: u64,
    hash: [32]u8,
    prev_hash: [32]u8,
};

/// Result of analyzing a loaded fragment for coverage metrics.
pub const CoverageReport = struct {
    /// Oldest slot in the contiguous ancestry-verified tail.
    intersectable_oldest_slot: u64,
    /// Newest slot in the fragment (tip).
    intersectable_newest_slot: u64,
    /// Number of entries in the contiguous ancestry-verified tail.
    usable_contiguous_depth: usize,
    /// Total number of numeric slot-range files on disk (caller-provided).
    numeric_file_count: usize,
    /// Number of ancestry breaks detected in the full fragment.
    break_count: usize,
    /// Slot of the first ancestry break (0 if none).
    first_break_slot: u64,
    /// Total number of entries in the fragment before trimming.
    total_entries: usize,
};

/// Analyze a loaded fragment (oldest→newest order) for coverage metrics.
///
/// Performs its own backward ancestry walk: starting from the newest entry,
/// walks backward verifying entries[i].prev_hash == entries[i-1].hash.
/// The contiguous tail is the longest suffix with unbroken ancestry.
///
/// `numeric_file_count` is passed through from the caller (number of
/// slot-range archive files on disk). This function does not perform I/O.
pub fn analyzeFragment(
    entries: []const FragmentSlotInfo,
    numeric_file_count: usize,
) CoverageReport {
    if (entries.len == 0) {
        return .{
            .intersectable_oldest_slot = 0,
            .intersectable_newest_slot = 0,
            .usable_contiguous_depth = 0,
            .numeric_file_count = numeric_file_count,
            .break_count = 0,
            .first_break_slot = 0,
            .total_entries = 0,
        };
    }

    // Walk backward from newest, counting breaks and finding contiguous tail.
    var break_count: usize = 0;
    var first_break_slot: u64 = 0;
    // contiguous_start_index: index of the oldest entry in the contiguous tail
    var contiguous_start_index: usize = entries.len - 1;

    var contiguous_tail_found = false;

    var i: usize = entries.len - 1;
    while (i > 0) : (i -= 1) {
        if (!std.mem.eql(u8, &entries[i].prev_hash, &entries[i - 1].hash)) {
            // Ancestry break between entries[i-1] and entries[i].
            break_count += 1;
            if (!contiguous_tail_found) {
                // First break from tip defines contiguous tail start.
                contiguous_start_index = i;
                first_break_slot = entries[i].slot;
                contiguous_tail_found = true;
            }
        }
    }

    // If no breaks were found, the entire fragment is contiguous.
    if (!contiguous_tail_found) {
        contiguous_start_index = 0;
    }

    const usable_depth = entries.len - contiguous_start_index;

    return .{
        .intersectable_oldest_slot = entries[contiguous_start_index].slot,
        .intersectable_newest_slot = entries[entries.len - 1].slot,
        .usable_contiguous_depth = usable_depth,
        .numeric_file_count = numeric_file_count,
        .break_count = break_count,
        .first_break_slot = first_break_slot,
        .total_entries = entries.len,
    };
}

// --- Tests ---

test "analyzeFragment fully contiguous" {
    // 5 entries, all ancestry-linked: A←B←C←D←E
    const entries = makeContiguous(5);
    const report = analyzeFragment(&entries, 10);

    try std.testing.expectEqual(@as(usize, 5), report.total_entries);
    try std.testing.expectEqual(@as(usize, 5), report.usable_contiguous_depth);
    try std.testing.expectEqual(@as(usize, 0), report.break_count);
    try std.testing.expectEqual(@as(u64, 0), report.first_break_slot);
    try std.testing.expectEqual(@as(u64, 100), report.intersectable_oldest_slot);
    try std.testing.expectEqual(@as(u64, 500), report.intersectable_newest_slot);
    try std.testing.expectEqual(@as(usize, 10), report.numeric_file_count);
}

test "analyzeFragment with one break" {
    // 5 entries, break between index 1 and 2:
    // A←B | C←D←E  (contiguous tail = C,D,E = depth 3)
    var entries = makeContiguous(5);
    // Break: entry[2].prev_hash != entry[1].hash
    entries[2].prev_hash = [_]u8{0xFF} ** 32;

    const report = analyzeFragment(&entries, 5);

    try std.testing.expectEqual(@as(usize, 5), report.total_entries);
    try std.testing.expectEqual(@as(usize, 3), report.usable_contiguous_depth);
    try std.testing.expectEqual(@as(usize, 1), report.break_count);
    try std.testing.expectEqual(@as(u64, 300), report.first_break_slot); // slot of entries[2]
    try std.testing.expectEqual(@as(u64, 300), report.intersectable_oldest_slot);
    try std.testing.expectEqual(@as(u64, 500), report.intersectable_newest_slot);
}

test "analyzeFragment with multiple breaks" {
    // 5 entries, breaks between 0-1 and 2-3:
    // A | B←C | D←E  (contiguous tail = D,E = depth 2)
    var entries = makeContiguous(5);
    entries[1].prev_hash = [_]u8{0xFE} ** 32; // break between 0 and 1
    entries[3].prev_hash = [_]u8{0xFD} ** 32; // break between 2 and 3

    const report = analyzeFragment(&entries, 3);

    try std.testing.expectEqual(@as(usize, 5), report.total_entries);
    try std.testing.expectEqual(@as(usize, 2), report.usable_contiguous_depth);
    try std.testing.expectEqual(@as(usize, 2), report.break_count);
    // first_break_slot is the first break encountered in backward walk = entries[3]
    try std.testing.expectEqual(@as(u64, 400), report.first_break_slot);
    try std.testing.expectEqual(@as(u64, 400), report.intersectable_oldest_slot);
    try std.testing.expectEqual(@as(u64, 500), report.intersectable_newest_slot);
}

test "analyzeFragment empty fragment" {
    const entries = [_]FragmentSlotInfo{};
    const report = analyzeFragment(&entries, 7);

    try std.testing.expectEqual(@as(usize, 0), report.total_entries);
    try std.testing.expectEqual(@as(usize, 0), report.usable_contiguous_depth);
    try std.testing.expectEqual(@as(usize, 0), report.break_count);
    try std.testing.expectEqual(@as(u64, 0), report.first_break_slot);
    try std.testing.expectEqual(@as(usize, 7), report.numeric_file_count);
}

test "analyzeFragment single entry" {
    const h = hashFromByte(0x01);
    const entries = [_]FragmentSlotInfo{
        .{ .slot = 42, .hash = h, .prev_hash = hashFromByte(0x00) },
    };
    const report = analyzeFragment(&entries, 0);

    try std.testing.expectEqual(@as(usize, 1), report.total_entries);
    try std.testing.expectEqual(@as(usize, 1), report.usable_contiguous_depth);
    try std.testing.expectEqual(@as(usize, 0), report.break_count);
    try std.testing.expectEqual(@as(u64, 42), report.intersectable_oldest_slot);
    try std.testing.expectEqual(@as(u64, 42), report.intersectable_newest_slot);
}

test "analyzeFragment numeric_file_count passthrough" {
    const entries = makeContiguous(2);
    const r1 = analyzeFragment(&entries, 0);
    const r2 = analyzeFragment(&entries, 999);
    try std.testing.expectEqual(@as(usize, 0), r1.numeric_file_count);
    try std.testing.expectEqual(@as(usize, 999), r2.numeric_file_count);
}

// --- Test helpers ---

fn hashFromByte(b: u8) [32]u8 {
    return [_]u8{b} ** 32;
}

/// Build a contiguous fragment of `n` entries with slots 100, 200, ..., n*100.
/// Entry[i].prev_hash == entry[i-1].hash for all i>0.
fn makeContiguous(comptime n: usize) [n]FragmentSlotInfo {
    var entries: [n]FragmentSlotInfo = undefined;
    for (0..n) |idx| {
        entries[idx] = .{
            .slot = @as(u64, idx + 1) * 100,
            .hash = hashFromByte(@intCast(idx + 1)),
            .prev_hash = hashFromByte(@intCast(idx)), // links to previous
        };
    }
    return entries;
}
