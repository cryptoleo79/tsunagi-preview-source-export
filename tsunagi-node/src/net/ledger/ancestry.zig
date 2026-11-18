const std = @import("std");
const compat = @import("compat");
const chain_index = @import("chain_index.zig");

/// Result entry from an ancestry walk. Same shape as ChainEntry.
pub const AncestryEntry = struct {
    slot: u64,
    block_no: u64,
    hash: [32]u8,
    prev_hash: [32]u8,
    source: Source,

    pub const Source = enum(u8) {
        chain_index = 0,
        fragment = 1,
        lmdb = 2,
    };
};

/// Opaque lookup function for LMDB tier. Caller provides a function that
/// takes a hash and returns (slot, block_no, prev_hash) or null.
/// This avoids a compile-time dependency on header_store.zig / LMDB.
pub const LmdbLookupResult = struct {
    slot: u64,
    block_no: u64,
    prev_hash: [32]u8,
};
pub const LmdbLookupFn = *const fn (ctx: *anyopaque, hash: [32]u8) ?LmdbLookupResult;

/// Walk backward from a starting hash through three tiers:
///   1. ChainIndex (in-memory, ~200 blocks)
///   2. Fragment directory (on-disk, ~2160 blocks, uses prev_hash.hex)
///   3. LMDB via caller-provided lookup function (persistent, unbounded)
///
/// Writes entries newest-first into `out`. Returns the number of entries written.
/// Stops when: buffer is full, a tier has no match, or the chain breaks.
///
/// Pure query — no mutation, no allocation beyond stack buffers.
/// Fragment dir and lmdb_lookup are optional (pass null to skip tiers).
pub fn walkBack(
    start_hash: [32]u8,
    chain_idx: *const chain_index.ChainIndex,
    frag_dir: ?[]const u8,
    lmdb_ctx: ?*anyopaque,
    lmdb_lookup: ?LmdbLookupFn,
    out: []AncestryEntry,
) u32 {
    if (out.len == 0) return 0;
    var written: u32 = 0;
    var current_hash = start_hash;

    // ── Tier 1: ChainIndex (in-memory) ──
    while (written < out.len) {
        const entry = chain_idx.lookupByHash(current_hash) orelse break;
        out[written] = .{
            .slot = entry.slot,
            .block_no = entry.block_no,
            .hash = entry.hash,
            .prev_hash = entry.prev_hash,
            .source = .chain_index,
        };
        written += 1;
        current_hash = entry.prev_hash;
    }

    // ── Tier 2: Fragment directory (on-disk) ──
    if (written < out.len) {
        if (frag_dir) |fd| {
            written += walkFragment(current_hash, fd, out[written..], &current_hash);
        }
    }

    // ── Tier 3: LMDB via callback ──
    if (written < out.len) {
        if (lmdb_ctx) |ctx| {
            if (lmdb_lookup) |lookup| {
                while (written < out.len) {
                    const rec = lookup(ctx, current_hash) orelse break;
                    out[written] = .{
                        .slot = rec.slot,
                        .block_no = rec.block_no,
                        .hash = current_hash,
                        .prev_hash = rec.prev_hash,
                        .source = .lmdb,
                    };
                    written += 1;
                    current_hash = rec.prev_hash;
                }
            }
        }
    }

    return written;
}

/// Walk backward through fragment directory using hash.hex / prev_hash.hex files.
/// Returns number of entries written. Updates current_hash to the last prev_hash found.
fn walkFragment(
    start_hash: [32]u8,
    frag_dir: []const u8,
    out: []AncestryEntry,
    current_hash_out: *[32]u8,
) u32 {
    // Build an index of fragment entries: collect (seq, hash, prev_hash, slot, block_no).
    // Fragment has at most ~2200 entries. We read hash.hex and prev_hash.hex for each.
    const MAX_FRAG = 2200;
    var frag_hashes: [MAX_FRAG][32]u8 = undefined;
    var frag_prev: [MAX_FRAG][32]u8 = undefined;
    var frag_slots: [MAX_FRAG]u64 = undefined;
    var frag_blocks: [MAX_FRAG]u64 = undefined;
    var frag_count: u32 = 0;

    // Scan fragment directory
    var dir = compat.fs.cwd().openDir(frag_dir, .{ .iterate = true }) catch return 0;
    defer dir.close();

    // Collect sequence numbers from .hash.hex files
    var seqs: [MAX_FRAG]u32 = undefined;
    var seq_count: u32 = 0;
    {
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (entry.name.len >= 17 and std.mem.endsWith(u8, entry.name, ".hash.hex")) {
                const seq = std.fmt.parseInt(u32, entry.name[0..8], 10) catch continue;
                if (seq_count < MAX_FRAG) {
                    seqs[seq_count] = seq;
                    seq_count += 1;
                }
            }
        }
    }

    if (seq_count == 0) return 0;

    // Sort descending (newest first) for faster lookup
    std.mem.sort(u32, seqs[0..seq_count], {}, std.sort.desc(u32));

    // Read hash + prev_hash + meta for each entry
    const hex_chars = "0123456789abcdef";
    _ = hex_chars;
    for (seqs[0..seq_count]) |seq| {
        var seq_buf: [8]u8 = undefined;
        const seq_str = std.fmt.bufPrint(&seq_buf, "{d:0>8}", .{seq}) catch continue;

        // Read hash.hex
        var hpath_buf: [512]u8 = undefined;
        const hpath = std.fmt.bufPrint(&hpath_buf, "{s}/{s}.hash.hex", .{ frag_dir, seq_str }) catch continue;
        var hash: [32]u8 = undefined;
        if (!readHexFile(hpath, &hash)) continue;

        // Read prev_hash.hex
        var ppath_buf: [512]u8 = undefined;
        const ppath = std.fmt.bufPrint(&ppath_buf, "{s}/{s}.prev_hash.hex", .{ frag_dir, seq_str }) catch continue;
        var prev: [32]u8 = undefined;
        if (!readHexFile(ppath, &prev)) continue;

        // Read meta.json for slot + block_no
        var mpath_buf: [512]u8 = undefined;
        const mpath = std.fmt.bufPrint(&mpath_buf, "{s}/{s}.meta.json", .{ frag_dir, seq_str }) catch continue;
        const meta = readMeta(mpath) orelse continue;

        if (frag_count < MAX_FRAG) {
            frag_hashes[frag_count] = hash;
            frag_prev[frag_count] = prev;
            frag_slots[frag_count] = meta.slot;
            frag_blocks[frag_count] = meta.block_no;
            frag_count += 1;
        }
    }

    // Walk backward through loaded fragment entries
    var current = start_hash;
    var written: u32 = 0;
    while (written < out.len) {
        // Find entry with matching hash
        var found = false;
        for (0..frag_count) |i| {
            if (std.mem.eql(u8, &frag_hashes[i], &current)) {
                out[written] = .{
                    .slot = frag_slots[i],
                    .block_no = frag_blocks[i],
                    .hash = frag_hashes[i],
                    .prev_hash = frag_prev[i],
                    .source = .fragment,
                };
                written += 1;
                current = frag_prev[i];
                found = true;
                break;
            }
        }
        if (!found) break;
    }

    current_hash_out.* = current;
    return written;
}

// ── Helpers ──

fn readHexFile(path: []const u8, out: *[32]u8) bool {
    var f = compat.fs.cwd().openFile(path, .{}) catch return false;
    defer f.close();
    var buf: [128]u8 = undefined;
    const n = f.readAll(&buf) catch return false;
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (trimmed.len != 64) return false;
    for (0..32) |i| {
        out[i] = (hexVal(trimmed[i * 2]) orelse return false) << 4 |
            (hexVal(trimmed[i * 2 + 1]) orelse return false);
    }
    return true;
}

fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

const Meta = struct { slot: u64, block_no: u64 };

fn readMeta(path: []const u8) ?Meta {
    var f = compat.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    var buf: [256]u8 = undefined;
    const n = f.readAll(&buf) catch return null;
    const data = buf[0..n];
    const slot = extractJsonU64(data, "\"slot\":") orelse return null;
    const block_no = extractJsonU64(data, "\"block_no\":") orelse return null;
    return .{ .slot = slot, .block_no = block_no };
}

fn extractJsonU64(data: []const u8, key: []const u8) ?u64 {
    const idx = std.mem.indexOf(u8, data, key) orelse return null;
    const start = idx + key.len;
    var end = start;
    while (end < data.len and data[end] >= '0' and data[end] <= '9') : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(u64, data[start..end], 10) catch null;
}

// ── Tests ──

test "walkBack returns 0 on empty chain" {
    var idx = chain_index.ChainIndex.init();
    var buf: [10]AncestryEntry = undefined;
    const n = walkBack([_]u8{0} ** 32, &idx, null, null, null, &buf);
    try std.testing.expectEqual(@as(u32, 0), n);
}

test "walkBack traverses ChainIndex" {
    var idx = chain_index.ChainIndex.init();

    // Build a 3-block chain: A ← B ← C
    var hash_a: [32]u8 = [_]u8{0} ** 32;
    hash_a[0] = 0xAA;
    var hash_b: [32]u8 = [_]u8{0} ** 32;
    hash_b[0] = 0xBB;
    var hash_c: [32]u8 = [_]u8{0} ** 32;
    hash_c[0] = 0xCC;
    const zero: [32]u8 = [_]u8{0} ** 32;

    idx.append(.{ .slot = 100, .block_no = 1, .hash = hash_a, .prev_hash = zero });
    idx.append(.{ .slot = 200, .block_no = 2, .hash = hash_b, .prev_hash = hash_a });
    idx.append(.{ .slot = 300, .block_no = 3, .hash = hash_c, .prev_hash = hash_b });

    var buf: [10]AncestryEntry = undefined;
    const n = walkBack(hash_c, &idx, null, null, null, &buf);
    try std.testing.expectEqual(@as(u32, 3), n);
    try std.testing.expectEqual(@as(u64, 300), buf[0].slot);
    try std.testing.expectEqual(@as(u64, 200), buf[1].slot);
    try std.testing.expectEqual(@as(u64, 100), buf[2].slot);
    try std.testing.expectEqual(AncestryEntry.Source.chain_index, buf[0].source);
}
