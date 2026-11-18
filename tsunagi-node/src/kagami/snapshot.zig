const std = @import("std");
const compat = @import("compat");
const lmdb_utxo = @import("../store/lmdb_utxo.zig");
const utxo_extract = @import("../ledger/utxo_extract.zig");

// ── KAGAMI 鏡 — Snapshot Cache ─────────────────────────────────────
//
// Read-only data gatherer that collects local node state into a single
// struct. Avoids duplicated parsing logic across stream iterations.
// Reusable by kagami report, yamori watch, tate watch, or future
// HTTP/status surface.
//
// No protocol imports. No file mutation. No global state.

// ── Thresholds (match TATE / YAMORI) ──

const TIP_AGE_WARN: i64 = 120;
const TIP_AGE_CRIT: i64 = 600;
const ART_AGE_WARN: i64 = 300;
const ART_AGE_CRIT: i64 = 1800;
const DEPTH_WARN: u64 = 100;
const DEPTH_CRIT: u64 = 10;
const GAP_WARN: i64 = 300;
const GAP_CRIT: i64 = 300;
const GAP_WARN_LOW: i64 = 61;

pub const Status = enum { healthy, warn, critical };

pub const Snapshot = struct {
    // Chain tip (from cursor.json)
    chain_tip_slot: ?u64,
    chain_tip_block_no: ?u64,
    tip_age_seconds: ?i64,
    roll_forward_count: ?u64,
    roll_backward_count: ?u64,

    // Propagation (from coverage.json + meta.json)
    artifact_present: bool,
    artifact_age_seconds: ?i64,
    intersectable_oldest_slot: ?u64,
    intersectable_newest_slot: ?u64,
    usable_depth: ?u64,
    break_count: ?u64,
    tip_artifact_gap_slots: ?i64,

    // UTxO (from LMDB, optional)
    utxo_count: ?u64,

    // Derived
    status: Status,
};

pub const CollectInput = struct {
    home: []const u8,
    lmdb_path: ?[]const u8,
    now: i64,
};

pub fn collect(alloc: std.mem.Allocator, input: CollectInput) !Snapshot {
    var snap = Snapshot{
        .chain_tip_slot = null,
        .chain_tip_block_no = null,
        .tip_age_seconds = null,
        .roll_forward_count = null,
        .roll_backward_count = null,
        .artifact_present = false,
        .artifact_age_seconds = null,
        .intersectable_oldest_slot = null,
        .intersectable_newest_slot = null,
        .usable_depth = null,
        .break_count = null,
        .tip_artifact_gap_slots = null,
        .utxo_count = null,
        .status = .healthy,
    };

    // ── cursor.json ──
    const cursor_path = try std.fmt.allocPrint(alloc, "{s}/cursor.json", .{input.home});
    defer alloc.free(cursor_path);

    if (readFileAlloc(alloc, cursor_path)) |data| {
        defer alloc.free(data);
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{ .allocate = .alloc_always }) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (p.value == .object) {
                snap.chain_tip_slot = jsonU64(p.value, "slot");
                snap.chain_tip_block_no = jsonU64(p.value, "block_no");
                snap.roll_forward_count = jsonU64(p.value, "roll_forward_count");
                snap.roll_backward_count = jsonU64(p.value, "roll_backward_count");
                if (p.value.object.get("updated_unix")) |v| {
                    if (v == .integer) {
                        const age = input.now - v.integer;
                        snap.tip_age_seconds = age;
                    }
                }
            }
        }
    }

    // ── propagation_artifact/ ──
    const art_dir = try std.fmt.allocPrint(alloc, "{s}/propagation_artifact", .{input.home});
    defer alloc.free(art_dir);

    snap.artifact_present = blk: {
        compat.fs.cwd().access(art_dir, .{}) catch break :blk false;
        break :blk true;
    };

    // ── meta.json ──
    if (snap.artifact_present) {
        const meta_path = try std.fmt.allocPrint(alloc, "{s}/meta.json", .{art_dir});
        defer alloc.free(meta_path);
        if (readFileAlloc(alloc, meta_path)) |data| {
            defer alloc.free(data);
            if (parseJsonU64(data, "unix")) |unix_val| {
                const unix_i64: i64 = @intCast(unix_val);
                snap.artifact_age_seconds = input.now - unix_i64;
            }
        }
    }

    // ── coverage.json ──
    if (snap.artifact_present) {
        const cov_path = try std.fmt.allocPrint(alloc, "{s}/coverage.json", .{art_dir});
        defer alloc.free(cov_path);
        if (readFileAlloc(alloc, cov_path)) |data| {
            defer alloc.free(data);
            snap.intersectable_oldest_slot = parseJsonU64(data, "intersectable_oldest_slot");
            snap.intersectable_newest_slot = parseJsonU64(data, "intersectable_newest_slot");
            snap.usable_depth = parseJsonU64(data, "usable_contiguous_depth");
            snap.break_count = parseJsonU64(data, "break_count");
        }
    }

    // ── tip_artifact_gap ──
    if (snap.chain_tip_slot != null and snap.intersectable_newest_slot != null) {
        const tip: i64 = @intCast(snap.chain_tip_slot.?);
        const newest: i64 = @intCast(snap.intersectable_newest_slot.?);
        snap.tip_artifact_gap_slots = tip - newest;
    }

    // ── LMDB UTxO count (optional) ──
    if (input.lmdb_path) |lmdb_dir| {
        const dir_z = try alloc.dupeZ(u8, lmdb_dir);
        defer alloc.free(dir_z);
        if (lmdb_utxo.LmdbUtxo.open(dir_z)) |store_val| {
            var store = store_val;
            defer store.close();
            snap.utxo_count = utxo_extract.countUtxos(&store);
        } else |_| {}
    }

    // ── Derive status ──
    snap.status = deriveStatus(&snap);

    return snap;
}

fn deriveStatus(snap: *const Snapshot) Status {
    // CRITICAL checks
    if (snap.tip_age_seconds == null) return .critical; // cursor missing
    if (snap.tip_age_seconds) |age| {
        if (age > TIP_AGE_CRIT) return .critical;
    }
    if (!snap.artifact_present) return .critical;
    if (snap.artifact_age_seconds) |age| {
        if (age > ART_AGE_CRIT) return .critical;
    }
    if (snap.usable_depth) |depth| {
        if (depth < DEPTH_CRIT) return .critical;
    }
    if (snap.break_count) |bc| {
        if (bc > 0) return .critical;
    }
    if (snap.tip_artifact_gap_slots) |gap| {
        if (gap > GAP_CRIT) return .critical;
    }

    // WARN checks
    if (snap.tip_age_seconds) |age| {
        if (age > TIP_AGE_WARN) return .warn;
    }
    if (snap.artifact_age_seconds) |age| {
        if (age > ART_AGE_WARN) return .warn;
    }
    if (snap.usable_depth) |depth| {
        if (depth < DEPTH_WARN) return .warn;
    }
    if (snap.tip_artifact_gap_slots) |gap| {
        if (gap >= GAP_WARN_LOW) return .warn;
    }
    // Coverage metadata missing while artifact exists
    if (snap.artifact_present and snap.usable_depth == null) return .warn;

    return .healthy;
}

// ── Helpers ────────────────────────────────────────────────────────

fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    var file = compat.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    return file.readToEndAlloc(alloc, 1024 * 1024) catch null;
}

fn jsonU64(obj: std.json.Value, key: []const u8) ?u64 {
    if (obj.object.get(key)) |v| {
        if (v == .integer and v.integer >= 0) {
            return @intCast(v.integer);
        }
    }
    return null;
}

/// Extract a u64 value for a given JSON key from a flat JSON object.
/// Simple substring search — works for single-level {"key":value,...} format.
fn parseJsonU64(data: []const u8, key: []const u8) ?u64 {
    var pos: usize = 0;
    while (pos + key.len + 3 < data.len) {
        if (data[pos] == '"') {
            const key_start = pos + 1;
            if (key_start + key.len < data.len and
                std.mem.eql(u8, data[key_start .. key_start + key.len], key) and
                data[key_start + key.len] == '"')
            {
                var i = key_start + key.len + 1;
                while (i < data.len and (data[i] == ' ' or data[i] == ':' or data[i] == '\t')) i += 1;
                const num_start = i;
                while (i < data.len and data[i] >= '0' and data[i] <= '9') i += 1;
                if (i > num_start) {
                    return std.fmt.parseUnsigned(u64, data[num_start..i], 10) catch null;
                }
                return null;
            }
        }
        pos += 1;
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────

test "deriveStatus healthy" {
    const snap = Snapshot{
        .chain_tip_slot = 1000,
        .chain_tip_block_no = 100,
        .tip_age_seconds = 5,
        .roll_forward_count = 100,
        .roll_backward_count = 2,
        .artifact_present = true,
        .artifact_age_seconds = 30,
        .intersectable_oldest_slot = 800,
        .intersectable_newest_slot = 990,
        .usable_depth = 2160,
        .break_count = 0,
        .tip_artifact_gap_slots = 10,
        .utxo_count = 50000,
        .status = .healthy,
    };
    try std.testing.expectEqual(Status.healthy, deriveStatus(&snap));
}

test "deriveStatus critical — cursor missing" {
    const snap = Snapshot{
        .chain_tip_slot = null,
        .chain_tip_block_no = null,
        .tip_age_seconds = null,
        .roll_forward_count = null,
        .roll_backward_count = null,
        .artifact_present = true,
        .artifact_age_seconds = 30,
        .intersectable_oldest_slot = null,
        .intersectable_newest_slot = null,
        .usable_depth = 2160,
        .break_count = 0,
        .tip_artifact_gap_slots = null,
        .utxo_count = null,
        .status = .healthy,
    };
    try std.testing.expectEqual(Status.critical, deriveStatus(&snap));
}

test "deriveStatus critical — artifact absent" {
    const snap = Snapshot{
        .chain_tip_slot = 1000,
        .chain_tip_block_no = 100,
        .tip_age_seconds = 5,
        .roll_forward_count = 100,
        .roll_backward_count = 2,
        .artifact_present = false,
        .artifact_age_seconds = null,
        .intersectable_oldest_slot = null,
        .intersectable_newest_slot = null,
        .usable_depth = null,
        .break_count = null,
        .tip_artifact_gap_slots = null,
        .utxo_count = null,
        .status = .healthy,
    };
    try std.testing.expectEqual(Status.critical, deriveStatus(&snap));
}

test "deriveStatus critical — stale artifact" {
    const snap = Snapshot{
        .chain_tip_slot = 1000,
        .chain_tip_block_no = 100,
        .tip_age_seconds = 5,
        .roll_forward_count = 100,
        .roll_backward_count = 2,
        .artifact_present = true,
        .artifact_age_seconds = 2000,
        .intersectable_oldest_slot = 800,
        .intersectable_newest_slot = 990,
        .usable_depth = 2160,
        .break_count = 0,
        .tip_artifact_gap_slots = 10,
        .utxo_count = null,
        .status = .healthy,
    };
    try std.testing.expectEqual(Status.critical, deriveStatus(&snap));
}

test "deriveStatus critical — breaks" {
    const snap = Snapshot{
        .chain_tip_slot = 1000,
        .chain_tip_block_no = 100,
        .tip_age_seconds = 5,
        .roll_forward_count = 100,
        .roll_backward_count = 2,
        .artifact_present = true,
        .artifact_age_seconds = 30,
        .intersectable_oldest_slot = 800,
        .intersectable_newest_slot = 990,
        .usable_depth = 2160,
        .break_count = 1,
        .tip_artifact_gap_slots = 10,
        .utxo_count = null,
        .status = .healthy,
    };
    try std.testing.expectEqual(Status.critical, deriveStatus(&snap));
}

test "deriveStatus warn — tip aging" {
    const snap = Snapshot{
        .chain_tip_slot = 1000,
        .chain_tip_block_no = 100,
        .tip_age_seconds = 200,
        .roll_forward_count = 100,
        .roll_backward_count = 2,
        .artifact_present = true,
        .artifact_age_seconds = 30,
        .intersectable_oldest_slot = 800,
        .intersectable_newest_slot = 990,
        .usable_depth = 2160,
        .break_count = 0,
        .tip_artifact_gap_slots = 10,
        .utxo_count = null,
        .status = .healthy,
    };
    try std.testing.expectEqual(Status.warn, deriveStatus(&snap));
}

test "deriveStatus warn — coverage missing" {
    const snap = Snapshot{
        .chain_tip_slot = 1000,
        .chain_tip_block_no = 100,
        .tip_age_seconds = 5,
        .roll_forward_count = 100,
        .roll_backward_count = 2,
        .artifact_present = true,
        .artifact_age_seconds = 30,
        .intersectable_oldest_slot = null,
        .intersectable_newest_slot = null,
        .usable_depth = null,
        .break_count = null,
        .tip_artifact_gap_slots = null,
        .utxo_count = null,
        .status = .healthy,
    };
    try std.testing.expectEqual(Status.warn, deriveStatus(&snap));
}

test "deriveStatus warn — moderate gap" {
    const snap = Snapshot{
        .chain_tip_slot = 1000,
        .chain_tip_block_no = 100,
        .tip_age_seconds = 5,
        .roll_forward_count = 100,
        .roll_backward_count = 2,
        .artifact_present = true,
        .artifact_age_seconds = 30,
        .intersectable_oldest_slot = 800,
        .intersectable_newest_slot = 900,
        .usable_depth = 2160,
        .break_count = 0,
        .tip_artifact_gap_slots = 100,
        .utxo_count = null,
        .status = .healthy,
    };
    try std.testing.expectEqual(Status.warn, deriveStatus(&snap));
}

test "parseJsonU64 extracts values" {
    const data = "{\"slot\":12345,\"block_no\":678}";
    try std.testing.expectEqual(@as(?u64, 12345), parseJsonU64(data, "slot"));
    try std.testing.expectEqual(@as(?u64, 678), parseJsonU64(data, "block_no"));
    try std.testing.expectEqual(@as(?u64, null), parseJsonU64(data, "missing"));
}
