const std = @import("std");
const compat = @import("compat");

const cbor = @import("../cbor/term.zig");
const follower = @import("follower.zig");
const journal = @import("../ledger/journal.zig");
const tps = @import("../ledger/tps.zig");
const utxo_mod = @import("../ledger/utxo.zig");
const utxo_store = @import("../ledger/utxo_store.zig");
const tx_decode = @import("../ledger/tx_decode.zig");
const i18n = @import("../../cli/i18n.zig");
const pretty = @import("../../cli/pretty.zig");
const header_raw = @import("../ledger/header_raw.zig");
const cursor_store = @import("../ledger/cursor.zig");
const delta_history = @import("../ledger/delta_history.zig");
const chain_index = @import("../ledger/chain_index.zig");
const tx_decoder = @import("../ledger/tx_decoder.zig");
const tx_summary_history = @import("../ledger/tx_summary_history.zig");
const block_decode_store = @import("../ledger/block_decode_store.zig");
const mempool_summary_history = @import("../mempool/mempool_summary_history.zig");
const confirmation_tracker = @import("../mempool/confirmation_tracker.zig");
const block_hash = @import("../ledger/block_hash.zig");
const propagation_tracker = @import("../mempool/propagation_tracker.zig");
const slot_observatory = @import("../consensus/slot_observatory.zig");
const shadow_producer = @import("../consensus/shadow_producer.zig");
const producer_dryrun = @import("../consensus/producer_dryrun.zig");
const candidate_validator = @import("../consensus/candidate_validator.zig");
const peer_observatory = @import("../network/peer_observatory.zig");
const kes_sign = @import("../../producer/crypto/kes_sign.zig");
const http_metrics = @import("../metrics/http_metrics.zig");
const producer = @import("../../producer/producer.zig");
const txsubmission = @import("../miniproto/txsubmission.zig");
const counting_allocator = @import("../../ops/counting_allocator.zig");
const peer_probe = @import("peer_probe.zig");
const multi_probe = @import("../../producer/multi_probe.zig");
const stake_distribution = @import("../ledger/stake_distribution.zig");
const leader_schedule = @import("../../producer/leader_schedule.zig");
const wall_tick = @import("../../producer/wall_tick.zig");
const protocol_manager = @import("../../producer/protocol_manager.zig");
const pool_stats = @import("../../producer/pool_stats.zig");

var g_debug: bool = false;
// Process-wide spawn-once guard for runWithOptions worker threads
// (forge-readiness 2026-05-23). True after the first runWithOptions call
// spawns its leader_schedule / wall_tick / protocol_manager / peer_probe /
// acceptance_tracker / stake_distribution worker set. Subsequent re-entries
// (peer-rotation loop in main.zig) skip the spawn block — the original
// workers continue against the heap-pinned ctx.
var g_workers_spawned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn vprint(comptime fmt: []const u8, args: anytype) void {
    if (g_debug) std.debug.print(fmt, args);
}

fn ensureStateDir(dir_path: []const u8) !void {
    try compat.fs.cwd().makePath(dir_path);
}

fn countSnapshotLines(path: []const u8) usize {
    var file = compat.fs.openFileAbsolute(path, .{}) catch return 0;
    defer file.close();
    const r = file.reader();
    var buf: [4096]u8 = undefined;
    var n: usize = 0;
    while (true) {
        const line = r.readUntilDelimiterOrEof(&buf, '\n') catch break;
        if (line == null) break;
        const trimmed = std.mem.trim(u8, line.?, " \r\t");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "UTXO_COUNT")) continue;
        n += 1;
    }
    return n;
}

const HeaderCandidate = struct {
    index: usize,
    bytes: []u8,
};

fn freeHeaderCandidates(alloc: std.mem.Allocator, candidates: []HeaderCandidate) void {
    for (candidates) |candidate| {
        alloc.free(candidate.bytes);
    }
    alloc.free(candidates);
}

fn freeHeaderValues(alloc: std.mem.Allocator, values: *[15]?[]u8) void {
    for (values) |maybe_bytes| {
        if (maybe_bytes) |bytes| alloc.free(bytes);
    }
    values.* = [_]?[]u8{null} ** 15;
}

fn printHeader32List(label: []const u8, candidates: []HeaderCandidate) void {
    std.debug.print("{s} [", .{label});
    for (candidates, 0..) |candidate, i| {
        if (i > 0) std.debug.print(",", .{});
        std.debug.print("{d}", .{candidate.index});
    }
    std.debug.print("]\n", .{});
}

fn printContinuityVerdict(
    prev: header_raw.HeaderBodyRawSnapshot,
    curr: header_raw.HeaderBodyRawSnapshot,
    structure_ok: bool,
) void {
    const slot_delta: i64 = @as(i64, @intCast(curr.f0_u64)) - @as(i64, @intCast(prev.f0_u64));
    const block_delta: i64 = @as(i64, @intCast(curr.f1_u64)) - @as(i64, @intCast(prev.f1_u64));
    const protocol_stable = prev.f7_u64 == curr.f7_u64 and
        prev.f13_u64 == curr.f13_u64 and
        prev.f14_u64 == curr.f14_u64;
    const leader_changed = !std.mem.eql(u8, prev.f3_bytes32[0..], curr.f3_bytes32[0..]) or
        !std.mem.eql(u8, prev.f4_bytes32[0..], curr.f4_bytes32[0..]);

    std.debug.print("continuity slot delta={d}\n", .{slot_delta});
    std.debug.print("continuity block number delta={d}\n", .{block_delta});
    std.debug.print("continuity protocol stable={s}\n", .{if (protocol_stable) "true" else "false"});
    std.debug.print("continuity leader changed={s}\n", .{if (leader_changed) "true" else "false"});

    const ok = structure_ok and slot_delta >= 0 and block_delta >= 0 and protocol_stable;
    if (ok) {
        std.debug.print("continuity verdict: OK (light follower)\n", .{});
    } else {
        std.debug.print("continuity verdict: WARN (rollback or protocol change)\n", .{});
    }
}

fn captureFirstRollForward(
    alloc: std.mem.Allocator,
    tip: cbor.Term,
    header_cbor_bytes: []const u8,
    prev_hash: ?[32]u8,
) void {
    _ = alloc;
    const tip_hash = getTipHash(tip);
    if (tip_hash) |hash| {
        if (hash.len == 32) {
            std.debug.print("tip_hash_full={x}\n", .{hash});
        }
    }

    std.debug.print("header_cbor_len={d}\n", .{header_cbor_bytes.len});
    std.debug.print(
        "header_cbor_hex={x}\n",
        .{header_cbor_bytes},
    );

    const header_hash = follower.headerHashBlake2b256(header_cbor_bytes);
    std.debug.print("header_hash={x}\n", .{&header_hash});
    if (prev_hash) |hash| {
        std.debug.print("prev_hash={x}\n", .{&hash});
    } else {
        std.debug.print("prev_hash=(null)\n", .{});
    }
}

fn writeCaptureFile(tip: cbor.Term, header_cbor_bytes: []const u8) !void {
    var file = try compat.fs.createFileAbsolute("/tmp/tsunagi_capture.txt", .{ .truncate = true });
    defer file.close();

    const tip_hash = getTipHash(tip);
    if (tip_hash) |hash| {
        if (hash.len == 32) {
            try file.writer().print(
                "tip_hash_full={x}\n",
                .{hash},
            );
        } else {
            try file.writer().print("tip_hash_full=(invalid)\n", .{});
        }
    } else {
        try file.writer().print("tip_hash_full=(null)\n", .{});
    }

    try file.writer().print(
        "header_cbor_hex={x}\n",
        .{header_cbor_bytes},
    );
    try file.writer().print("header_cbor_len={d}\n", .{header_cbor_bytes.len});
}

fn collectHeaderCandidates(alloc: std.mem.Allocator, block: cbor.Term) ![]HeaderCandidate {
    var list = std.array_list.Managed(HeaderCandidate).init(alloc);
    errdefer {
        for (list.items) |candidate| {
            alloc.free(candidate.bytes);
        }
        list.deinit();
    }

    if (block != .array) return list.toOwnedSlice();
    const items = block.array;
    if (items.len < 2) return list.toOwnedSlice();

    const block_bytes = blk: {
        if (items[1] == .bytes) break :blk items[1].bytes;
        if (items[1] == .tag and items[1].tag.tag == 24 and items[1].tag.value.* == .bytes) {
            break :blk items[1].tag.value.*.bytes;
        }
        return list.toOwnedSlice();
    };

    const inner_bytes = header_raw.getTag24InnerBytes(block_bytes) orelse block_bytes;
    var fbs = compat.fixedBufferStream(inner_bytes);
    const top = cbor.decode(alloc, fbs.reader()) catch return list.toOwnedSlice();
    defer cbor.free(top, alloc);

    if (top != .array) return list.toOwnedSlice();
    const top_items = top.array;
    if (top_items.len == 0 or top_items[0] != .array) return list.toOwnedSlice();

    for (top_items[0].array, 0..) |item, i| {
        if (item == .bytes and item.bytes.len == 32) {
            const copy = try alloc.dupe(u8, item.bytes);
            try list.append(.{ .index = i, .bytes = copy });
        }
    }

    return list.toOwnedSlice();
}

fn printPoint(term: cbor.Term) void {
    if (term == .array) {
        const items = term.array;
        if (items.len == 0) {
            std.debug.print("point: origin\n", .{});
            return;
        }
        if (items.len >= 2 and items[0] == .u64 and items[1] == .bytes) {
            const slot = items[0].u64;
            const hash = items[1].bytes;
            const end = if (hash.len < 8) hash.len else 8;
            std.debug.print(
                "point: slot={d} hash={x}\n",
                .{ slot, hash[0..end] },
            );
            return;
        }
    }
    std.debug.print("point: (opaque)\n", .{});
}

fn printIndent(level: usize) void {
    var i: usize = 0;
    while (i < level) : (i += 1) {
        std.debug.print("  ", .{});
    }
}

fn printTerm(term: cbor.Term, level: usize) void {
    switch (term) {
        .u64 => |v| {
            printIndent(level);
            std.debug.print("u64 {d}\n", .{v});
        },
        .i64 => |v| {
            printIndent(level);
            std.debug.print("i64 {d}\n", .{v});
        },
        .bool => |v| {
            printIndent(level);
            std.debug.print("bool {s}\n", .{if (v) "true" else "false"});
        },
        .null => {
            printIndent(level);
            std.debug.print("null\n", .{});
        },
        .text => |v| {
            printIndent(level);
            std.debug.print("text \"{s}\"\n", .{v});
        },
        .bytes => |v| {
            const end = if (v.len < 8) v.len else 8;
            printIndent(level);
            std.debug.print(
                "bytes {x} len={d}\n",
                .{ v[0..end], v.len },
            );
        },
        .array => |items| {
            printIndent(level);
            std.debug.print("array len={d}\n", .{items.len});
            for (items) |item| {
                printTerm(item, level + 1);
            }
        },
        .map_u64 => |entries| {
            printIndent(level);
            std.debug.print("map_u64 len={d}\n", .{entries.len});
            for (entries) |entry| {
                printIndent(level + 1);
                std.debug.print("key {d}\n", .{entry.key});
                printTerm(entry.value, level + 2);
            }
        },
        .tag => |t| {
            printIndent(level);
            std.debug.print("tag {d}\n", .{t.tag});
            printTerm(t.value.*, level + 1);
        },
    }
}

fn printBlockShallow(term: cbor.Term) void {
    std.debug.print("block term:\n", .{});
    switch (term) {
        .array => |items| {
            std.debug.print("array len={d}\n", .{items.len});
            const max_items = if (items.len < 2) items.len else 2;
            var i: usize = 0;
            while (i < max_items) : (i += 1) {
                const item = items[i];
                switch (item) {
                    .u64 => |v| std.debug.print("  [{d}] u64 {d}\n", .{ i, v }),
                    .bytes => |b| std.debug.print("  [{d}] bytes len={d}\n", .{ i, b.len }),
                    .array => std.debug.print("  [{d}] array\n", .{i}),
                    .map_u64 => std.debug.print("  [{d}] map_u64\n", .{i}),
                    .i64 => std.debug.print("  [{d}] i64\n", .{i}),
                    .bool => std.debug.print("  [{d}] bool\n", .{i}),
                    .text => std.debug.print("  [{d}] text\n", .{i}),
                    .null => std.debug.print("  [{d}] null\n", .{i}),
                    .tag => |t| std.debug.print("  [{d}] tag {d}\n", .{ i, t.tag }),
                }
            }
        },
        .map_u64 => |entries| {
            std.debug.print("map len={d}\n", .{entries.len});
        },
        .u64 => std.debug.print("block: u64\n", .{}),
        .i64 => std.debug.print("block: i64\n", .{}),
        .bool => std.debug.print("block: bool\n", .{}),
        .text => std.debug.print("block: text\n", .{}),
        .bytes => std.debug.print("block: bytes\n", .{}),
        .null => std.debug.print("block: null\n", .{}),
        .tag => |t| std.debug.print("block: tag {d}\n", .{t.tag}),
    }
}

fn printBlockHash(alloc: std.mem.Allocator, term: cbor.Term, tip_hash: ?[]const u8) void {
    if (term == .array) {
        const items = term.array;
        if (items.len >= 2 and items[0] == .u64) {
            const era_id = items[0].u64;
            const bytes = blk: {
                if (items[1] == .bytes) break :blk items[1].bytes;
                if (items[1] == .tag and items[1].tag.tag == 24 and items[1].tag.value.* == .bytes) {
                    const tag_bytes = items[1].tag.value.*.bytes;
                    var tag_digest: [32]u8 = undefined;
                    std.crypto.hash.blake2.Blake2b256.hash(tag_bytes, &tag_digest, .{});
                    std.debug.print(
                        "block_tag24_hash={x} bytes={d}\n",
                        .{ &tag_digest, tag_bytes.len },
                    );
                    var tag_full_list = std.array_list.Managed(u8).init(alloc);
                    defer tag_full_list.deinit();
                    cbor.encode(items[1], compat.listWriter(&tag_full_list)) catch return;
                    var tag_full_digest: [32]u8 = undefined;
                    std.crypto.hash.blake2.Blake2b256.hash(tag_full_list.items, &tag_full_digest, .{});
                    std.debug.print(
                        "block_tag24_full_hash={x} bytes={d}\n",
                        .{ &tag_full_digest, tag_full_list.items.len },
                    );
                    if (tip_hash) |hash| {
                        if (hash.len == 32 and std.mem.eql(u8, tag_digest[0..], hash)) {
                            std.debug.print("match: tip_hash == block_tag24_hash\n", .{});
                        }
                        const tip_prefix = hash[0..8];
                        const tag_prefix = tag_digest[0..8];
                        std.debug.print(
                            "tip_hash_prefix={x}\n",
                            .{tip_prefix},
                        );
                        std.debug.print(
                            "tag24_hash_prefix={x} eq={s}\n",
                            .{
                                tag_prefix,
                                if (std.mem.eql(u8, tag_digest[0..], hash)) "true" else "false",
                            },
                        );
                        std.debug.print(
                            "eq_tip_vs_tag24_full={s}\n",
                            .{if (std.mem.eql(u8, tag_full_digest[0..], hash)) "true" else "false"},
                        );
                    }
                    break :blk tag_bytes;
                }
                return;
            };
            var digest: [32]u8 = undefined;
            std.crypto.hash.blake2.Blake2b256.hash(bytes, &digest, .{});
            std.debug.print(
                "block: era={d} bytes={d} blake2b256={x}\n",
                .{ era_id, bytes.len, &digest },
            );

            const prefix_len = if (bytes.len < 16) bytes.len else 16;
            std.debug.print(
                "block: era={d} bytes={d} prefix={x}\n",
                .{ era_id, bytes.len, bytes[0..prefix_len] },
            );
            if (bytes.len > 0) {
                const major: u8 = bytes[0] >> 5;
                const kind = switch (major) {
                    0 => "uint",
                    1 => "negint",
                    2 => "bytes",
                    3 => "text",
                    4 => "array",
                    5 => "map",
                    6 => "tag",
                    else => "simple",
                };
                std.debug.print("cbor top: {s}\n", .{kind});
            }
            if (!printTag24Inner(alloc, bytes)) {
                std.debug.print("block inner: (not tag24)\n", .{});
                printInnerBytes(alloc, bytes, tip_hash);
            }
        }
    }
}

fn printTag24Inner(alloc: std.mem.Allocator, bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    if ((bytes[0] >> 5) != 6) return false;

    var index: usize = 1;
    const ai: u8 = bytes[0] & 0x1f;
    var tag: u32 = 0;
    switch (ai) {
        0...23 => tag = ai,
        24 => {
            if (index + 1 > bytes.len) return false;
            tag = bytes[index];
            index += 1;
        },
        25 => {
            if (index + 2 > bytes.len) return false;
            tag = (@as(u32, bytes[index]) << 8) | bytes[index + 1];
            index += 2;
        },
        26 => {
            if (index + 4 > bytes.len) return false;
            tag = (@as(u32, bytes[index]) << 24) |
                (@as(u32, bytes[index + 1]) << 16) |
                (@as(u32, bytes[index + 2]) << 8) |
                bytes[index + 3];
            index += 4;
        },
        else => return false,
    }
    if (tag != 24) return false;
    if (index >= bytes.len) return false;

    const item_head = bytes[index];
    if ((item_head >> 5) != 2) return false;
    index += 1;

    const item_ai: u8 = item_head & 0x1f;
    var len: usize = 0;
    switch (item_ai) {
        0...23 => len = item_ai,
        24 => {
            if (index + 1 > bytes.len) return false;
            len = bytes[index];
            index += 1;
        },
        25 => {
            if (index + 2 > bytes.len) return false;
            len = (@as(usize, bytes[index]) << 8) | bytes[index + 1];
            index += 2;
        },
        26 => {
            if (index + 4 > bytes.len) return false;
            len = (@as(usize, bytes[index]) << 24) |
                (@as(usize, bytes[index + 1]) << 16) |
                (@as(usize, bytes[index + 2]) << 8) |
                bytes[index + 3];
            index += 4;
        },
        else => return false,
    }
    if (index + len > bytes.len) return false;
    const inner = bytes[index .. index + len];
    printInnerBytes(alloc, inner, null);
    return true;
}

fn printInnerBytes(alloc: std.mem.Allocator, inner: []const u8, tip_hash: ?[]const u8) void {
    const prefix_len = if (inner.len < 16) inner.len else 16;
    std.debug.print(
        "block inner: bytes={d} prefix={x}\n",
        .{ inner.len, inner[0..prefix_len] },
    );
    if (inner.len == 0) {
        std.debug.print("block inner cbor top: (empty)\n", .{});
        return;
    }

    const inner_major: u8 = inner[0] >> 5;
    const inner_kind = switch (inner_major) {
        0 => "uint",
        1 => "negint",
        2 => "bytes",
        3 => "text",
        4 => "array",
        5 => "map",
        6 => "tag",
        else => "simple",
    };
    std.debug.print("block inner cbor top: {s}\n", .{inner_kind});

    if (inner_major != 4) return;
    var inner_index: usize = 1;
    const inner_ai: u8 = inner[0] & 0x1f;
    var array_len: usize = 0;
    switch (inner_ai) {
        0...23 => array_len = inner_ai,
        24 => {
            if (inner_index + 1 > inner.len) return;
            array_len = inner[inner_index];
            inner_index += 1;
        },
        25 => {
            if (inner_index + 2 > inner.len) return;
            array_len = (@as(usize, inner[inner_index]) << 8) | inner[inner_index + 1];
            inner_index += 2;
        },
        26 => {
            if (inner_index + 4 > inner.len) return;
            array_len = (@as(usize, inner[inner_index]) << 24) |
                (@as(usize, inner[inner_index + 1]) << 16) |
                (@as(usize, inner[inner_index + 2]) << 8) |
                inner[inner_index + 3];
            inner_index += 4;
        },
        else => return,
    }
    if (array_len != 2) return;

    var fbs = compat.fixedBufferStream(inner[inner_index..]);
    const t0 = cbor.decode(alloc, fbs.reader()) catch {
        std.debug.print("block inner inspect: failed\n", .{});
        return;
    };
    defer cbor.free(t0, alloc);
    const t1 = cbor.decode(alloc, fbs.reader()) catch {
        std.debug.print("block inner inspect: failed\n", .{});
        return;
    };
    defer cbor.free(t1, alloc);

    printTermShallow(0, t0);
    if (header_raw.decodeHeaderBodyRaw(t0)) |header_body| {
        header_raw.printHeaderBodyRaw(header_body);
    } else {
        std.debug.print("HeaderBodyRaw parse failed\n", .{});
    }
    printHeaderShallow(alloc, t0, tip_hash);
    printTermShallow(1, t1);
    if (t1 == .bytes) {
        const inner1 = t1.bytes;
        if (inner1.len > 0) {
            const major: u8 = inner1[0] >> 5;
            const kind = switch (major) {
                0 => "uint",
                1 => "negint",
                2 => "bytes",
                3 => "text",
                4 => "array",
                5 => "map",
                6 => "tag",
                else => "simple",
            };
            std.debug.print("inner1 cbor top: {s}\n", .{kind});
        } else {
            std.debug.print("inner1 cbor top: (empty)\n", .{});
        }
        std.debug.print("inner1 scan:\n", .{});
        scanCborShallow(inner1);
    }
}

fn printTermShallow(index: usize, term: cbor.Term) void {
    switch (term) {
        .u64 => |v| std.debug.print("block inner[{d}]: u64 {d}\n", .{ index, v }),
        .i64 => |v| std.debug.print("block inner[{d}]: i64 {d}\n", .{ index, v }),
        .bool => |v| std.debug.print("block inner[{d}]: bool {s}\n", .{ index, if (v) "true" else "false" }),
        .null => std.debug.print("block inner[{d}]: null\n", .{index}),
        .text => |v| std.debug.print("block inner[{d}]: text len={d}\n", .{ index, v.len }),
        .bytes => |b| {
            const end = if (b.len < 8) b.len else 8;
            std.debug.print(
                "block inner[{d}]: bytes len={d} prefix={x}\n",
                .{ index, b.len, b[0..end] },
            );
        },
        .array => |items| std.debug.print("block inner[{d}]: array len={d}\n", .{ index, items.len }),
        .map_u64 => |entries| std.debug.print("block inner[{d}]: map len={d}\n", .{ index, entries.len }),
        .tag => |t| std.debug.print("block inner[{d}]: tag {d}\n", .{ index, t.tag }),
    }
}

fn printInner1Term(term: cbor.Term) void {
    switch (term) {
        .u64 => |v| std.debug.print("inner1 term: u64 {d}\n", .{v}),
        .i64 => |v| std.debug.print("inner1 term: i64 {d}\n", .{v}),
        .bool => |v| std.debug.print("inner1 term: bool {s}\n", .{if (v) "true" else "false"}),
        .null => std.debug.print("inner1 term: null\n", .{}),
        .text => |v| std.debug.print("inner1 term: text len={d}\n", .{v.len}),
        .bytes => |b| {
            const end = if (b.len < 8) b.len else 8;
            std.debug.print(
                "inner1 term: bytes len={d} prefix={x}\n",
                .{ b.len, b[0..end] },
            );
        },
        .array => |items| {
            std.debug.print("inner1 term: array len={d}\n", .{items.len});
            const max_items = if (items.len < 3) items.len else 3;
            var i: usize = 0;
            while (i < max_items) : (i += 1) {
                const item = items[i];
                switch (item) {
                    .u64 => |v| std.debug.print("inner1[{d}]: u64 {d}\n", .{ i, v }),
                    .i64 => |v| std.debug.print("inner1[{d}]: i64 {d}\n", .{ i, v }),
                    .bool => |v| std.debug.print("inner1[{d}]: bool {s}\n", .{ i, if (v) "true" else "false" }),
                    .null => std.debug.print("inner1[{d}]: null\n", .{i}),
                    .text => |v| std.debug.print("inner1[{d}]: text len={d}\n", .{ i, v.len }),
                    .bytes => |b| {
                        const end = if (b.len < 8) b.len else 8;
                        std.debug.print(
                            "inner1[{d}]: bytes len={d} prefix={x}\n",
                            .{ i, b.len, b[0..end] },
                        );
                    },
                    .array => |arr| std.debug.print("inner1[{d}]: array len={d}\n", .{ i, arr.len }),
                    .map_u64 => |map| std.debug.print("inner1[{d}]: map len={d}\n", .{ i, map.len }),
                    .tag => |t| std.debug.print("inner1[{d}]: tag {d}\n", .{ i, t.tag }),
                }
            }
        },
        .map_u64 => |entries| {
            std.debug.print("inner1 term: map len={d}\n", .{entries.len});
            const max_entries = if (entries.len < 3) entries.len else 3;
            var i: usize = 0;
            while (i < max_entries) : (i += 1) {
                const entry = entries[i];
                const value = entry.value;
                switch (value) {
                    .u64 => |v| std.debug.print("inner1[{d}]: key={d} u64 {d}\n", .{ i, entry.key, v }),
                    .i64 => |v| std.debug.print("inner1[{d}]: key={d} i64 {d}\n", .{ i, entry.key, v }),
                    .bool => |v| std.debug.print("inner1[{d}]: key={d} bool {s}\n", .{ i, entry.key, if (v) "true" else "false" }),
                    .null => std.debug.print("inner1[{d}]: key={d} null\n", .{ i, entry.key }),
                    .text => |v| std.debug.print("inner1[{d}]: key={d} text len={d}\n", .{ i, entry.key, v.len }),
                    .bytes => |b| {
                        const end = if (b.len < 8) b.len else 8;
                        std.debug.print(
                            "inner1[{d}]: key={d} bytes len={d} prefix={x}\n",
                            .{ i, entry.key, b.len, b[0..end] },
                        );
                    },
                    .array => |arr| std.debug.print("inner1[{d}]: key={d} array len={d}\n", .{ i, entry.key, arr.len }),
                    .map_u64 => |map| std.debug.print("inner1[{d}]: key={d} map len={d}\n", .{ i, entry.key, map.len }),
                    .tag => |t| std.debug.print("inner1[{d}]: key={d} tag {d}\n", .{ i, entry.key, t.tag }),
                }
            }
        },
        .tag => |t| std.debug.print("inner1 term: tag {d}\n", .{t.tag}),
    }
}

fn majorName(major: u8) []const u8 {
    return switch (major) {
        0 => "uint",
        1 => "negint",
        2 => "bytes",
        3 => "text",
        4 => "array",
        5 => "map",
        6 => "tag",
        else => "simple",
    };
}

fn readAiValue(bytes: []const u8, index: *usize) ?usize {
    if (index.* >= bytes.len) return null;
    const head = bytes[index.*];
    const ai: u8 = head & 0x1f;
    index.* += 1;
    switch (ai) {
        0...23 => return ai,
        24 => {
            if (index.* + 1 > bytes.len) return null;
            const v = bytes[index.*];
            index.* += 1;
            return v;
        },
        25 => {
            if (index.* + 2 > bytes.len) return null;
            const v = (@as(usize, bytes[index.*]) << 8) | bytes[index.* + 1];
            index.* += 2;
            return v;
        },
        26 => {
            if (index.* + 4 > bytes.len) return null;
            const v = (@as(usize, bytes[index.*]) << 24) |
                (@as(usize, bytes[index.* + 1]) << 16) |
                (@as(usize, bytes[index.* + 2]) << 8) |
                bytes[index.* + 3];
            index.* += 4;
            return v;
        },
        31 => return null,
        else => return null,
    }
}

fn scanItem(bytes: []const u8, index: *usize, label: []const u8) bool {
    if (index.* >= bytes.len) return false;
    const head = bytes[index.*];
    const major: u8 = head >> 5;
    const ai: u8 = head & 0x1f;
    if (ai == 31) {
        std.debug.print("{s}: {s} indefinite (not supported)\n", .{ label, majorName(major) });
        return false;
    }
    const start = index.*;
    const len_or_val = readAiValue(bytes, index) orelse return false;

    switch (major) {
        0 => std.debug.print("{s}: uint {d}\n", .{ label, len_or_val }),
        1 => std.debug.print("{s}: negint {d}\n", .{ label, len_or_val }),
        2, 3 => {
            const kind = if (major == 2) "bytes" else "text";
            if (index.* + len_or_val > bytes.len) return false;
            const end = if (len_or_val < 8) len_or_val else 8;
            std.debug.print(
                "{s}: {s} len={d} prefix={x}\n",
                .{ label, kind, len_or_val, bytes[index.* .. index.* + end] },
            );
            index.* += len_or_val;
        },
        4 => std.debug.print("{s}: array len={d}\n", .{ label, len_or_val }),
        5 => std.debug.print("{s}: map pairs={d}\n", .{ label, len_or_val }),
        6 => std.debug.print("{s}: tag {d}\n", .{ label, len_or_val }),
        else => std.debug.print("{s}: simple ai={d}\n", .{ label, ai }),
    }

    _ = start;
    return true;
}

fn scanCborShallow(bytes: []const u8) void {
    var index: usize = 0;
    if (bytes.len == 0) {
        std.debug.print("inner1 scan: empty\n", .{});
        return;
    }

    if (index >= bytes.len) return;
    const head = bytes[index];
    const major: u8 = head >> 5;
    const ai: u8 = head & 0x1f;
    if (ai == 31) {
        std.debug.print("inner1 scan: {s} indefinite (not supported)\n", .{majorName(major)});
        return;
    }
    const len_or_val = readAiValue(bytes, &index) orelse {
        std.debug.print("inner1 scan: failed\n", .{});
        return;
    };

    if (major == 6) {
        std.debug.print("inner1 scan: tag {d}\n", .{len_or_val});
        if (index >= bytes.len) return;
        const sub_head = bytes[index];
        const sub_major: u8 = sub_head >> 5;
        const sub_ai: u8 = sub_head & 0x1f;
        if (sub_ai == 31) {
            std.debug.print("inner1 scan: {s} indefinite (not supported)\n", .{majorName(sub_major)});
            return;
        }
        const sub_len = readAiValue(bytes, &index) orelse return;
        std.debug.print("inner1 scan: {s}\n", .{majorName(sub_major)});
        if (sub_major == 2 or sub_major == 3) {
            if (index + sub_len > bytes.len) return;
            index += sub_len;
        }
        if (sub_major != 4 and sub_major != 5) return;
        const pairs = sub_len;
        if (sub_major == 4) {
            const max_items = if (pairs < 3) pairs else 3;
            var i: usize = 0;
            while (i < max_items) : (i += 1) {
                if (!scanItem(bytes, &index, "inner1 scan item")) return;
            }
            return;
        }
        const max_pairs = if (pairs < 3) pairs else 3;
        var i: usize = 0;
        while (i < max_pairs) : (i += 1) {
            if (!scanItem(bytes, &index, "inner1 scan key")) return;
            if (!scanItem(bytes, &index, "inner1 scan val")) return;
        }
        return;
    }

    std.debug.print("inner1 scan: {s}\n", .{majorName(major)});
    if (major == 4) {
        const max_items = if (len_or_val < 3) len_or_val else 3;
        var i: usize = 0;
        while (i < max_items) : (i += 1) {
            if (!scanItem(bytes, &index, "inner1 scan item")) return;
        }
        return;
    }
    if (major == 5) {
        const max_pairs = if (len_or_val < 3) len_or_val else 3;
        var i: usize = 0;
        while (i < max_pairs) : (i += 1) {
            if (!scanItem(bytes, &index, "inner1 scan key")) return;
            if (!scanItem(bytes, &index, "inner1 scan val")) return;
        }
        return;
    }
}

fn printHeaderItem(index: usize, term: cbor.Term) void {
    switch (term) {
        .u64 => |v| std.debug.print("header[{d}]: u64 {d}\n", .{ index, v }),
        .i64 => |v| std.debug.print("header[{d}]: i64 {d}\n", .{ index, v }),
        .bool => |v| std.debug.print("header[{d}]: bool {s}\n", .{ index, if (v) "true" else "false" }),
        .null => std.debug.print("header[{d}]: null\n", .{index}),
        .text => |v| std.debug.print("header[{d}]: text len={d}\n", .{ index, v.len }),
        .bytes => |b| {
            if (index == 8 and b.len == 32) {
                std.debug.print("prev_hash: {x}\n", .{b});
                return;
            }
            const end = if (b.len < 8) b.len else 8;
            std.debug.print(
                "header[{d}]: bytes len={d} prefix={x}\n",
                .{ index, b.len, b[0..end] },
            );
        },
        .array => |items| std.debug.print("header[{d}]: array len={d}\n", .{ index, items.len }),
        .map_u64 => |entries| std.debug.print("header[{d}]: map len={d}\n", .{ index, entries.len }),
        .tag => |t| std.debug.print("header[{d}]: tag {d}\n", .{ index, t.tag }),
    }
}

fn printHeaderItemNested(parent: usize, index: usize, term: cbor.Term) void {
    switch (term) {
        .u64 => |v| std.debug.print("header[{d}][{d}]: u64 {d}\n", .{ parent, index, v }),
        .i64 => |v| std.debug.print("header[{d}][{d}]: i64 {d}\n", .{ parent, index, v }),
        .bool => |v| std.debug.print("header[{d}][{d}]: bool {s}\n", .{ parent, index, if (v) "true" else "false" }),
        .null => std.debug.print("header[{d}][{d}]: null\n", .{ parent, index }),
        .text => |v| std.debug.print("header[{d}][{d}]: text len={d}\n", .{ parent, index, v.len }),
        .bytes => |b| {
            const end = if (b.len < 8) b.len else 8;
            std.debug.print(
                "header[{d}][{d}]: bytes len={d} prefix={x}\n",
                .{ parent, index, b.len, b[0..end] },
            );
        },
        .array => |items| std.debug.print("header[{d}][{d}]: array len={d}\n", .{ parent, index, items.len }),
        .map_u64 => |entries| std.debug.print("header[{d}][{d}]: map len={d}\n", .{ parent, index, entries.len }),
        .tag => |t| std.debug.print("header[{d}][{d}]: tag {d}\n", .{ parent, index, t.tag }),
    }
}

fn printHeaderShallow(alloc: std.mem.Allocator, term: cbor.Term, tip_hash: ?[]const u8) void {
    if (term != .array) return;
    const items = term.array;
    if (items.len != 15) return;
    // HeaderBody index hints (suspected):
    //  0: slot
    //  1: block_no
    //  2: prev_hash (Maybe)
    //  3: issuer_vkey
    //  4: vrf_vkey
    //  5: vrf_result
    //  6: kes_info
    //  7: era
    //  8: constant_nonce / reserved
    //  9: metadata_hash
    // 10: body_size?
    // 11: body_hash?
    // 12: opcert / protocol?
    // 13: proto_version?
    // 14: extra / reserved
    var i: usize = 0;
    while (i < items.len and i < 15) : (i += 1) {
        printHeaderItem(i, items[i]);
    }

    var list = std.array_list.Managed(u8).init(alloc);
    defer list.deinit();
    cbor.encode(term, compat.listWriter(&list)) catch return;
    const bytes = list.items;
    var digest: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(bytes, &digest, .{});
    std.debug.print(
        "block_inner_hash={x} bytes={d}\n",
        .{ &digest, bytes.len },
    );
    if (tip_hash) |hash| {
        if (hash.len == 32 and std.mem.eql(u8, digest[0..], hash)) {
            std.debug.print("match: tip_hash == block_inner_hash\n", .{});
        }
        const tip_prefix = hash[0..8];
        const inner_prefix = digest[0..8];
        std.debug.print(
            "tip_hash_prefix={x}\n",
            .{tip_prefix},
        );
        std.debug.print(
            "inner_hash_prefix={x} eq={s}\n",
            .{
                inner_prefix,
                if (std.mem.eql(u8, digest[0..], hash)) "true" else "false",
            },
        );
    }

    var header32_indices: [15]usize = undefined;
    var header32_count: usize = 0;
    i = 0;
    while (i < items.len and i < 15) : (i += 1) {
        if (items[i] == .bytes and items[i].bytes.len == 32) {
            header32_indices[header32_count] = i;
            header32_count += 1;
            if (tip_hash) |hash| {
                if (hash.len == 32 and std.mem.eql(u8, items[i].bytes, hash)) {
                    std.debug.print("match: tip_hash == header[{d}]\n", .{i});
                }
            }
        }
    }
    if (header32_count > 0) {
        std.debug.print("header32 fields: [", .{});
        i = 0;
        while (i < header32_count) : (i += 1) {
            if (i > 0) std.debug.print(",", .{});
            std.debug.print("{d}", .{header32_indices[i]});
        }
        std.debug.print("]\n", .{});
    }

    if (items.len >= 6 and items[5] == .array) {
        const header5 = items[5].array;
        if (header5.len == 2) {
            printHeaderItemNested(5, 0, header5[0]);
            printHeaderItemNested(5, 1, header5[1]);
            if (header5[0] == .u64 and header5[1] == .bytes) {
                const slot = header5[0].u64;
                const hash = header5[1].bytes;
                const end = if (hash.len < 8) hash.len else 8;
                std.debug.print(
                    "header point candidate: slot={d} hash={x}\n",
                    .{ slot, hash[0..end] },
                );
            }
        }
    }

    if (items.len >= 7 and items[6] == .array) {
        const header6 = items[6].array;
        if (header6.len == 2) {
            printHeaderItemNested(6, 0, header6[0]);
            printHeaderItemNested(6, 1, header6[1]);
            if (header6[0] == .u64 and header6[1] == .bytes and header6[1].bytes.len == 32) {
                const slot = header6[0].u64;
                const hash = header6[1].bytes;
                const end = if (hash.len < 8) hash.len else 8;
                std.debug.print(
                    "header[6] point candidate: slot={d} hash={x}\n",
                    .{ slot, hash[0..end] },
                );
            } else if ((header6[0] == .array and header6[0].array.len == 2 and header6[1] == .u64) or
                (header6[0] == .u64 and header6[1] == .array and header6[1].array.len == 2))
            {
                std.debug.print("header[6] looks nested\n", .{});
            }
        }
    }

    i = 6;
    while (i < items.len and i < 15) : (i += 1) {
        if (items[i] == .array) {
            const entry = items[i].array;
            if (entry.len == 2 and entry[0] == .u64 and entry[1] == .bytes) {
                const slot = entry[0].u64;
                const hash = entry[1].bytes;
                if (hash.len == 32) {
                    const end = if (hash.len < 8) hash.len else 8;
                    std.debug.print(
                        "header point candidate at [{d}]: slot={d} hash={x}\n",
                        .{ i, slot, hash[0..end] },
                    );
                }
            }
        }
    }
}

fn getTipHash(term: cbor.Term) ?[]const u8 {
    if (term != .array) return null;
    const items = term.array;
    const inner = blk: {
        if (items.len == 1 and items[0] == .array) break :blk items[0].array;
        break :blk items;
    };
    if (inner.len != 2) return null;
    if (inner[0] != .array or inner[1] != .u64) return null;
    const point = inner[0].array;
    if (point.len != 2) return null;
    if (point[0] != .u64 or point[1] != .bytes) return null;
    if (point[1].bytes.len != 32) return null;
    return point[1].bytes;
}

const TipSlotBlock = struct {
    slot: u64,
    block_no: u64,
};

fn getTipSlotBlock(term: cbor.Term) ?TipSlotBlock {
    if (term != .array) return null;
    const items = term.array;
    const inner = blk: {
        if (items.len == 1 and items[0] == .array) break :blk items[0].array;
        break :blk items;
    };
    if (inner.len == 2 and inner[0] == .array and inner[1] == .u64) {
        const point = inner[0].array;
        if (point.len == 2 and point[0] == .u64 and point[1] == .bytes) {
            return .{ .slot = point[0].u64, .block_no = inner[1].u64 };
        }
    }
    if (inner.len >= 3 and inner[0] == .u64 and inner[2] == .u64) {
        return .{ .slot = inner[0].u64, .block_no = inner[2].u64 };
    }
    return null;
}

fn printTipArray(items: []const cbor.Term) void {
    if (items.len == 2 and items[0] == .array and items[1] == .u64) {
        const inner = items[0].array;
        if (inner.len == 2 and inner[0] == .u64 and inner[1] == .bytes) {
            const slot = inner[0].u64;
            const hash = inner[1].bytes;
            const block_no = items[1].u64;
            const end = if (hash.len < 8) hash.len else 8;
            std.debug.print(
                "tip(from msg): slot={d} blockNo={d} hash={x}\n",
                .{ slot, block_no, hash[0..end] },
            );
            return;
        }
    }
    if (items.len >= 1 and items[0] == .u64) {
        if (items.len >= 3 and items[2] == .u64) {
            std.debug.print(
                "tip(from msg): slot={d} blockNo={d}\n",
                .{ items[0].u64, items[2].u64 },
            );
            return;
        }
        std.debug.print("tip(from msg): slot={d}\n", .{items[0].u64});
        return;
    }
    std.debug.print("tip(from msg): (opaque)\n", .{});
    std.debug.print("tip term:\n", .{});
    printTerm(.{ .array = @constCast(items) }, 1);
}

fn printTip(term: cbor.Term) void {
    if (term == .array) {
        const items = term.array;
        if (items.len == 1 and items[0] == .array) {
            printTipArray(items[0].array);
            return;
        }
        printTipArray(items);
        return;
    }
    std.debug.print("tip(from msg): (opaque)\n", .{});
    std.debug.print("tip term:\n", .{});
    printTerm(term, 1);
}

const FollowerCtx = struct {
    base: follower.Context,
    alloc: std.mem.Allocator,
    tps_meter: ?tps.TpsMeter = null,
    utxo: utxo_mod.UTxO,
    undo_stack: std.array_list.Managed(utxo_mod.Undo),
    debug: bool,
    lang: i18n.Lang,
    pretty: bool,
    preview_utxo: bool,
    cursor_path: []const u8,
    journal_path: []const u8,
    utxo_path: []const u8,
    last_status_unix: i64 = 0,
    stopping: bool = false,
    metrics: ?*const anyopaque = null,
    prev_candidates: ?[]HeaderCandidate = null,
    prev_header_values: [15]?[]u8 = [_]?[]u8{null} ** 15,
    prev_changed: [15]bool = [_]bool{false} ** 15,
    captured_first_rollforward: bool = false,
    prev_header_hash_opt: ?[32]u8 = null,
    prev_header_cbor_len: ?usize = null,
    prev_header_body_raw: ?header_raw.HeaderBodyRawSnapshot = null,
    printed_continuity_verdict: bool = false,
    last_dup_tip_hex: ?[8]u8 = null,
    last_saved_tip_hex: ?[8]u8 = null,
    delta_hist: delta_history.DeltaHistory = delta_history.DeltaHistory.init(),
    tx_summary_hist: tx_summary_history.TxSummaryHistory = tx_summary_history.TxSummaryHistory.init(),
    tx_decode_path: []const u8 = "",
    block_store: block_decode_store.BlockDecodeStore = block_decode_store.BlockDecodeStore.init(),
    mempool_summary: mempool_summary_history.MempoolSummaryStore = mempool_summary_history.MempoolSummaryStore.init(),
    mempool_journal_path: []const u8 = "",
    confirmation: confirmation_tracker.ConfirmationTracker = confirmation_tracker.ConfirmationTracker.init(),
    confirmation_journal_path: []const u8 = "",
    propagation: propagation_tracker.PropagationTracker = propagation_tracker.PropagationTracker.init(),
    propagation_journal_path: []const u8 = "",
    slot_obs: slot_observatory.SlotObservatory = slot_observatory.SlotObservatory.init(),
    slot_journal_path: []const u8 = "",
    peer_obs: peer_observatory.PeerObservatory = peer_observatory.PeerObservatory.init(),
    peer_obs_journal_path: []const u8 = "",
    shadow_cfg: shadow_producer.ShadowConfig = .{},
    shadow_hist: shadow_producer.ShadowHistory = shadow_producer.ShadowHistory.init(),
    dryrun_cfg: producer_dryrun.DryRunConfig = .{},
    dryrun_hist: producer_dryrun.DryRunHistory = producer_dryrun.DryRunHistory.init(),
    fragment_dir: []const u8 = "",
    fragment_seq: u32 = 0,
    fragment_capacity: u32 = 64,
    chain_idx: chain_index.ChainIndex = chain_index.ChainIndex.init(),
};

fn ctxFromAny(ctx_any: *anyopaque) *FollowerCtx {
    const base_ctx = @as(*follower.Context, @ptrCast(@alignCast(ctx_any)));
    return @fieldParentPtr("base", base_ctx);
}

fn onPeerConnect(ctx_any: *anyopaque, host: []const u8, port: u16) void {
    const ctx = ctxFromAny(ctx_any);
    // Wire header store for query layer (one-time, after follower opens it during init)
    if (http_metrics.g_header_store == null) {
        if (ctx.base.header_store) |*hs| {
            http_metrics.g_header_store = hs;
            std.debug.print("QUERY LAYER: g_header_store wired on peer connect\n", .{});
        }
    }
    var label_buf: [96]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "{s}:{d}", .{ host, port }) catch return;
    const ev = peer_observatory.makeEvent(label, .peer_connect, null, null, null, compat.timestamp());
    ctx.peer_obs.append(ev);
    if (ctx.peer_obs_journal_path.len > 0) {
        journal.appendPeerEvent(ctx.peer_obs_journal_path, ev, null) catch |err| {
            std.log.warn("peer connect journal write: {}", .{err});
        };
    }
}

fn onPeerDisconnect(ctx_any: *anyopaque, host: []const u8, port: u16, reason: []const u8) void {
    const ctx = ctxFromAny(ctx_any);
    var label_buf: [96]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "{s}:{d}", .{ host, port }) catch return;
    const ev = peer_observatory.makeEvent(label, .peer_disconnect, null, null, null, compat.timestamp());
    ctx.peer_obs.append(ev);
    if (ctx.peer_obs_journal_path.len > 0) {
        journal.appendPeerEvent(ctx.peer_obs_journal_path, ev, reason) catch |err| {
            std.log.warn("peer disconnect journal write: {}", .{err});
        };
    }
}

fn onRollForward(
    ctx_any: *anyopaque,
    tip_slot: u64,
    tip_block: u64,
    tip_hash32: [32]u8,
    header_hash32: [32]u8,
    tx_count: u64,
    inputs_consumed: u32,
    outputs_produced: u32,
    tx_summaries: tx_decoder.BlockTxResult,
    tx_bodies_cbor: ?[]const u8,
) !void {
    const ctx = ctxFromAny(ctx_any);
    if (ctx.stopping) return;
    const alloc = ctx.alloc;

    // Wire header store pointer for query layer (one-time, after follower opens it)
    if (http_metrics.g_header_store == null) {
        if (ctx.base.header_store) |*hs| {
            http_metrics.g_header_store = hs;
        }
    }

    const tip = ctx.base.current_tip orelse return;
    const block = ctx.base.current_block orelse return;

    // Phase B'''' D-3: parse delivered (slot, block_no) early. If unparseable,
    // refuse to advance the cursor — do not fall back to peer-tip values.
    // This preserves operator-visible continuity surfaces in the delivered
    // domain (D-1) and prevents the cross-domain footgun from re-entering
    // via the cursor write path.
    var delivered_slot: u64 = 0;
    var delivered_block: u64 = 0;
    var have_delivered_fields = false;
    if (follower.extractHeaderCborInfo(alloc, block)) |hi_for_fields| {
        defer alloc.free(hi_for_fields.cbor_bytes);
        defer if (hi_for_fields.full_header_cbor) |fhc| alloc.free(fhc);
        // parseHeaderSlotAndBlockNo expects the FULL header
        // [header_body, body_signature] — it indexes top[0] to reach the
        // header_body, then header_body[0]/[1] for block_no/slot.
        // extractHeaderCborInfo.cbor_bytes is the BARE header_body (one
        // CBOR array layer too shallow): feeding it makes top[0] resolve
        // to block_no (a u64), the parser's `body != .array` guard
        // rejects it, and every RollForward is refused with
        // "delivered header unparseable". full_header_cbor is the full
        // header — the buffer the parser's contract actually requires.
        // Fall back to cbor_bytes only if the full-header encode was
        // unavailable (preserves prior behavior in that edge case).
        const header_for_parse = hi_for_fields.full_header_cbor orelse hi_for_fields.cbor_bytes;
        if (follower.parseHeaderSlotAndBlockNo(header_for_parse)) |f| {
            delivered_slot = f.slot;
            delivered_block = f.block_no;
            have_delivered_fields = true;
        }
    }
    if (!have_delivered_fields) {
        if (ctx.metrics) |metrics_any| {
            const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
            _ = m.tsunagi_header_parse_refused_total.fetchAdd(1, .acq_rel);
        }
        std.debug.print("ROLL FWD: refusing cursor advance — delivered header unparseable\n", .{});
        return;
    }

    // Phase B'''' F1 closure: /status and /chain/tip must agree. The
    // delivered values are the operator-visible continuity values
    // throughout post-fix TSUNAGI.
    if (ctx.metrics) |metrics_any| {
        const metrics = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
        metrics.slot.store(delivered_slot, .release);
        metrics.block_no.store(delivered_block, .release);
        // Peer-tip gauges for peer-lag visibility (D-2).
        metrics.peer_tip_slot.store(tip_slot, .release);
        metrics.peer_tip_block_no.store(tip_block, .release);
        const est = ctx.base.utxo_count_est;
        metrics.utxo.store(if (est > 0) @intCast(est) else 0, .release);
        _ = metrics.roll_fwd.fetchAdd(1, .acq_rel);
    }

    const tip_hash = getTipHash(tip);
    // new_slot/new_block_no were previously sourced from peer-tip; post-fix
    // they are sourced from the parsed delivered header to keep the cursor
    // representation coherent (D-1).
    const new_slot: ?u64 = delivered_slot;
    const new_block_no: ?u64 = delivered_block;
    // tip_hash_hex sources from delivered header hash (HIGH-4a co-shift).
    var new_tip_hash_hex: [64]u8 = ctx.base.cursor.tip_hash_hex;
    _ = try std.fmt.bufPrint(&new_tip_hash_hex, "{x}", .{&header_hash32});
    const has_tip_hash = true;
    const tip_prefix8: ?[8]u8 = blk: {
        var prefix: [8]u8 = [_]u8{'?'} ** 8;
        _ = std.fmt.bufPrint(&prefix, "{x}", .{header_hash32[0..4]}) catch {};
        break :blk prefix;
    };
    // tip_hash (peer's far-tip hash) is consumed below by printBlockHash.
    if (new_slot != null and new_block_no != null and has_tip_hash) {
        const slot = new_slot.?;
        const block_no = new_block_no.?;
        // Phase B'''' C1 closure: stale-suppression operands MUST be in the
        // peer-tip domain (matching incoming tip_slot/tip_block) — comparing
        // to delivered-domain cursor would compare across domains and
        // effectively stop firing post-fix.
        if (tip_slot < ctx.base.peer_tip_slot_last or tip_block < ctx.base.peer_tip_block_no_last) {
            if (ctx.debug) {
                std.debug.print(
                    "ROLL FWD (stale) peer_slot={d} peer_block={d} delivered_slot={d} delivered_block={d} (no save)\n",
                    .{ tip_slot, tip_block, slot, block_no },
                );
            }
            return;
        }
        if (std.mem.eql(u8, new_tip_hash_hex[0..], ctx.base.cursor.tip_hash_hex[0..])) {
            if (tip_prefix8) |prefix| {
                const should_log = if (ctx.last_dup_tip_hex) |last_dup|
                    !std.mem.eql(u8, last_dup[0..], prefix[0..])
                else
                    true;
                if (should_log and ctx.debug) {
                    std.debug.print(
                        "ROLL FWD (duplicate) slot={d} block={d} tip={s} (no save)\n",
                        .{ slot, block_no, prefix[0..] },
                    );
                    ctx.last_dup_tip_hex = prefix;
                }
            }
            return;
        }
    }
    var header_hash_hex: [64]u8 = [_]u8{'0'} ** 64;
    _ = try std.fmt.bufPrint(
        &header_hash_hex,
        "{x}",
        .{&header_hash32},
    );
    ctx.base.cursor.header_hash_hex = header_hash_hex;
    if (new_slot) |slot| ctx.base.cursor.slot = slot;
    if (new_block_no) |block_no| ctx.base.cursor.block_no = block_no;
    if (has_tip_hash) {
        ctx.base.cursor.tip_hash_hex = new_tip_hash_hex;
    }
    // C1 (cont): advance peer_tip_*_last after non-stale, non-duplicate
    // RollForward so the next call's stale-suppression compares against
    // the latest accepted peer tip.
    ctx.base.peer_tip_slot_last = tip_slot;
    ctx.base.peer_tip_block_no_last = tip_block;
    if (ctx.debug and !ctx.stopping) {
        printBlockShallow(block);
        printBlockHash(alloc, block, tip_hash);
    }
    if (follower.extractHeaderCborInfo(alloc, block)) |header_info| {
        defer alloc.free(header_info.cbor_bytes);
        defer if (header_info.full_header_cbor) |fhc| alloc.free(fhc);
        if (!ctx.captured_first_rollforward) {
            ctx.captured_first_rollforward = true;
            if (ctx.debug) {
                captureFirstRollForward(
                    alloc,
                    tip,
                    header_info.cbor_bytes,
                    header_info.prev_hash,
                );
                try writeCaptureFile(
                    tip,
                    header_info.cbor_bytes,
                );
            }
        }
        if (ctx.prev_header_hash_opt) |prev_hash| {
            if (header_info.prev_hash) |next_prev_hash| {
                const matches = std.mem.eql(u8, prev_hash[0..], next_prev_hash[0..]);
                vprint(
                    "header_hash == next.prev_hash ({s})\n",
                    .{if (matches) "true" else "false"},
                );
            }
        }
        const curr_body_opt = header_raw.extractHeaderBodyRawSnapshot(
            alloc,
            block,
        );
        if (curr_body_opt) |curr_body| {
            if (ctx.prev_header_body_raw) |prev_body| {
                if (ctx.base.roll_forward_count == 2 and !ctx.printed_continuity_verdict) {
                    if (ctx.debug) {
                        header_raw.printHeaderBodyRawStability(prev_body, curr_body, true);
                        printContinuityVerdict(prev_body, curr_body, true);
                    }
                    ctx.printed_continuity_verdict = true;
                }
            }
            ctx.prev_header_body_raw = curr_body;
            if (ctx.prev_header_hash_opt) |prev_hash| {
                var match_any = false;
                const matches_f3 = std.mem.eql(
                    u8,
                    prev_hash[0..],
                    curr_body.f3_bytes32[0..],
                );
                vprint(
                    "prev_header_hash == curr.f3_bytes32 -> {s}\n",
                    .{if (matches_f3) "true" else "false"},
                );
                if (matches_f3) {
                    vprint("MATCH FIELD: f3\n", .{});
                    match_any = true;
                }

                const matches_f4 = std.mem.eql(
                    u8,
                    prev_hash[0..],
                    curr_body.f4_bytes32[0..],
                );
                vprint(
                    "prev_header_hash == curr.f4_bytes32 -> {s}\n",
                    .{if (matches_f4) "true" else "false"},
                );
                if (matches_f4) {
                    vprint("MATCH FIELD: f4\n", .{});
                    match_any = true;
                }

                const matches_f8 = std.mem.eql(
                    u8,
                    prev_hash[0..],
                    curr_body.f8_bytes32[0..],
                );
                vprint(
                    "prev_header_hash == curr.f8_bytes32 -> {s}\n",
                    .{if (matches_f8) "true" else "false"},
                );
                if (matches_f8) {
                    vprint("MATCH FIELD: f8\n", .{});
                    match_any = true;
                }

                const matches_f9 = std.mem.eql(
                    u8,
                    prev_hash[0..],
                    curr_body.f9_bytes32[0..],
                );
                vprint(
                    "prev_header_hash == curr.f9_bytes32 -> {s}\n",
                    .{if (matches_f9) "true" else "false"},
                );
                if (matches_f9) {
                    vprint("MATCH FIELD: f9\n", .{});
                    match_any = true;
                }

                if (curr_body.f2 == .bytes32) {
                    const matches_f2 = std.mem.eql(
                        u8,
                        prev_hash[0..],
                        curr_body.f2.bytes32[0..],
                    );
                    vprint(
                        "prev_header_hash == curr.f2 -> {s}\n",
                        .{if (matches_f2) "true" else "false"},
                    );
                    if (matches_f2) {
                        vprint("MATCH FIELD: f2\n", .{});
                        match_any = true;
                    }
                }

                vprint(
                    "curr_prev_hash matches prev_header_hash={s}\n",
                    .{if (match_any) "true" else "false"},
                );
            }
        } else if (ctx.prev_header_body_raw != null and ctx.debug) {
            std.debug.print("consensus continuity: BROKEN\n", .{});
        }
        ctx.prev_header_hash_opt = header_hash32;
        ctx.prev_header_cbor_len = header_info.cbor_bytes.len;

        // Chain index: append block metadata for historical lookup
        ctx.chain_idx.append(.{
            .slot = tip_slot,
            .block_no = tip_block,
            .hash = header_hash32,
            .prev_hash = header_info.prev_hash orelse [_]u8{0} ** 32,
        });
        if (ctx.chain_idx.count() <= 3 or ctx.chain_idx.count() % 100 == 0) {
            std.debug.print("CHAIN_INDEX: append slot={d} block={d} count={d} ptr={*}\n", .{
                tip_slot, tip_block, ctx.chain_idx.count(), &ctx.chain_idx,
            });
        }

        // Rolling chain fragment: write recent headers for propagation ancestry.
        // Uses monotonically increasing sequence numbers so filename sort order
        // always equals chronological order. Deletes stale entries beyond capacity.
        // Writes full header CBOR [header_body, kes_sig] (not just header body)
        // so that propagation ChainSync can serve wire-compatible headers.
        if (ctx.fragment_dir.len > 0 and header_info.full_header_cbor != null) {
            const full_hdr = header_info.full_header_cbor.?;
            const seq = ctx.fragment_seq;
            ctx.fragment_seq +%= 1;
            var seq_buf: [8]u8 = undefined;
            const seq_str = std.fmt.bufPrint(&seq_buf, "{d:0>8}", .{seq}) catch "";
            if (seq_str.len > 0) {
                // Write full header CBOR [header_body, kes_sig]
                var hdr_path_buf: [512]u8 = undefined;
                const hdr_path = std.fmt.bufPrint(&hdr_path_buf, "{s}/{s}.header.cbor", .{ ctx.fragment_dir, seq_str }) catch null;
                if (hdr_path) |hp| {
                    var hf = compat.fs.createFileAbsolute(hp, .{}) catch null;
                    if (hf) |*f| {
                        defer f.close();
                        _ = f.write(full_hdr) catch {};
                    }
                }
                // Write hash hex (blake2b256 of full header = Cardano block hash)
                var hash_path_buf: [512]u8 = undefined;
                const hash_path = std.fmt.bufPrint(&hash_path_buf, "{s}/{s}.hash.hex", .{ ctx.fragment_dir, seq_str }) catch null;
                if (hash_path) |hp| {
                    var full_hdr_hash: [32]u8 = undefined;
                    std.crypto.hash.blake2.Blake2b256.hash(full_hdr, &full_hdr_hash, .{});
                    const hash_hex = std.fmt.bytesToHex(full_hdr_hash, .lower);
                    var hf = compat.fs.createFileAbsolute(hp, .{}) catch null;
                    if (hf) |*f| {
                        defer f.close();
                        _ = f.write(&hash_hex) catch {};
                        _ = f.write("\n") catch {};
                    }
                }
                // Delete stale entry beyond capacity
                if (seq >= ctx.fragment_capacity) {
                    const stale_seq = seq - ctx.fragment_capacity;
                    var stale_buf: [8]u8 = undefined;
                    const stale_str = std.fmt.bufPrint(&stale_buf, "{d:0>8}", .{stale_seq}) catch "";
                    if (stale_str.len > 0) {
                        var stale_hdr_buf: [512]u8 = undefined;
                        var stale_hash_buf: [512]u8 = undefined;
                        if (std.fmt.bufPrint(&stale_hdr_buf, "{s}/{s}.header.cbor", .{ ctx.fragment_dir, stale_str })) |sp| {
                            compat.fs.deleteFileAbsolute(sp) catch {};
                        } else |_| {}
                        if (std.fmt.bufPrint(&stale_hash_buf, "{s}/{s}.hash.hex", .{ ctx.fragment_dir, stale_str })) |sp| {
                            compat.fs.deleteFileAbsolute(sp) catch {};
                        } else |_| {}
                    }
                }
            }
        }
    }
    const curr_candidates = try collectHeaderCandidates(
        alloc,
        block,
    );
    if (ctx.prev_header_hash_opt) |prev_hash| {
        for (curr_candidates) |curr_item| {
            if (std.mem.eql(u8, curr_item.bytes, prev_hash[0..])) {
                vprint(
                    "consensus prev-hash field: header[{d}] matches prev_header_hash\n",
                    .{curr_item.index},
                );
            }
        }
    }
    var curr_changed: [15]bool = [_]bool{false} ** 15;
    var curr_present: [15]bool = [_]bool{false} ** 15;
    for (curr_candidates) |curr_item| {
        if (curr_item.index < 15) {
            curr_present[curr_item.index] = true;
            if (ctx.prev_header_values[curr_item.index]) |prev_bytes| {
                curr_changed[curr_item.index] =
                    !std.mem.eql(u8, prev_bytes, curr_item.bytes);
            } else {
                curr_changed[curr_item.index] = true;
            }
        }
    }
    for (curr_candidates) |curr_item| {
        if (curr_item.index < 15) {
            if (ctx.prev_header_values[curr_item.index]) |prev_bytes| {
                alloc.free(prev_bytes);
            }
            ctx.prev_header_values[curr_item.index] = try alloc.dupe(
                u8,
                curr_item.bytes,
            );
        }
    }
    var idx: usize = 0;
    while (idx < ctx.prev_header_values.len) : (idx += 1) {
        if (!curr_present[idx]) {
            if (ctx.prev_header_values[idx]) |prev_bytes| {
                alloc.free(prev_bytes);
            }
            ctx.prev_header_values[idx] = null;
        }
    }
    if (ctx.debug) printHeader32List("curr header32:", curr_candidates);
    if (ctx.prev_candidates) |prev| {
        if (ctx.debug) printHeader32List("prev header32:", prev);
        for (prev) |prev_item| {
            for (curr_candidates) |curr_item| {
                if (!ctx.prev_changed[prev_item.index] or
                    !curr_changed[curr_item.index])
                {
                    continue;
                }
                if (std.mem.eql(u8, prev_item.bytes, curr_item.bytes)) {
                    vprint(
                        "link candidate: prev.header[{d}] -> curr.header[{d}]\n",
                        .{ prev_item.index, curr_item.index },
                    );
                }
                if (std.mem.eql(u8, prev_item.bytes, curr_item.bytes)) {
                    vprint(
                        "match32: prev.header[{d}] == curr.header[{d}]\n",
                        .{ prev_item.index, curr_item.index },
                    );
                    vprint(
                        "prev.header[{d}] == curr.header[{d}] (possible prev-hash link)\n",
                        .{ prev_item.index, curr_item.index },
                    );
                    vprint(
                        "matching indices: prev={d} curr={d}\n",
                        .{ prev_item.index, curr_item.index },
                    );
                }
            }
        }
        freeHeaderCandidates(alloc, prev);
    }
    ctx.prev_candidates = curr_candidates;
    ctx.prev_changed = curr_changed;
    if (ctx.debug) printTip(tip);
    if (ctx.debug and !ctx.stopping) {
        var header_prefix: [8]u8 = [_]u8{'?'} ** 8;
        _ = try std.fmt.bufPrint(
            &header_prefix,
            "{x}",
            .{header_hash32[0..4]},
        );
        std.debug.print("header_hash_prefix={s}\n", .{header_prefix[0..]});
    }
    ctx.base.cursor.roll_forward_count += 1;
    ctx.base.cursor.updated_unix = compat.timestamp();
    try cursor_store.save(ctx.base.cursor, ctx.cursor_path);
    if (!ctx.stopping) {
        std.debug.print("CURSOR saved {s}\n", .{ctx.cursor_path});
    }
    try journal.appendRollForward(
        ctx.journal_path,
        compat.timestamp(),
        ctx.base.cursor.slot,
        ctx.base.cursor.block_no,
        ctx.base.cursor.tip_hash_hex[0..],
        header_hash_hex[0..],
        tx_count,
        ctx.utxo.count(),
        inputs_consumed,
        outputs_produced,
    );
    ctx.delta_hist.append(.{
        .slot = ctx.base.cursor.slot,
        .block_no = ctx.base.cursor.block_no,
        .block_hash_hex = header_hash_hex,
        .tx_count = @intCast(tx_count),
        .utxo_consumed = inputs_consumed,
        .utxo_produced = outputs_produced,
        .utxo_delta = @as(i32, @intCast(outputs_produced)) - @as(i32, @intCast(inputs_consumed)),
        .timestamp_unix = compat.timestamp(),
    });
    ctx.tx_summary_hist.append(.{
        .slot = ctx.base.cursor.slot,
        .block_no = ctx.base.cursor.block_no,
        .block_hash_hex = header_hash_hex,
        .tx_count = @intCast(tx_count),
        .txs = tx_summaries.summaries,
        .txs_len = tx_summaries.count,
        .truncated = tx_summaries.truncated,
        .timestamp_unix = compat.timestamp(),
    });
    ctx.block_store.append(.{
        .slot = ctx.base.cursor.slot,
        .block_no = ctx.base.cursor.block_no,
        .block_hash_hex = header_hash_hex,
        .tx_count = @intCast(tx_count),
        .utxo_consumed = inputs_consumed,
        .utxo_produced = outputs_produced,
        .utxo_delta = @as(i32, @intCast(outputs_produced)) - @as(i32, @intCast(inputs_consumed)),
        .txs = tx_summaries.summaries,
        .txs_len = tx_summaries.count,
        .truncated = tx_summaries.truncated,
        .timestamp_unix = compat.timestamp(),
    });
    // Slot observatory: record observed block
    const obs_ts = compat.timestamp();
    ctx.slot_obs.appendObservedBlock(tip_slot, tip_block, obs_ts);
    if (ctx.slot_journal_path.len > 0) {
        journal.appendSlotObservation(
            ctx.slot_journal_path, ctx.slot_obs.latest().?,
        ) catch |err| {
            std.log.warn("slot observation journal write: {}", .{err});
        };
    }
    // Shadow producer: local-only candidate evaluation on slot progression
    if (ctx.shadow_cfg.enabled) {
        const pc = &ctx.base.producer_ctx;

        // Decode pool_id from hex (same pattern as producer.zig:1001)
        var pool_id_bytes: [32]u8 = [_]u8{0} ** 32;
        if (pc.key_cfg.pool_id_hex) |pid| {
            _ = std.fmt.hexToBytes(&pool_id_bytes, pid) catch {};
        }

        // Extract KES root PK if key state is loaded
        var kes_pk: [32]u8 = [_]u8{0} ** 32;
        const kes_state: ?[]const u8 = if (pc.kes_key_state_len > 0)
            pc.kes_key_state[0..pc.kes_key_state_len]
        else
            null;
        if (kes_state) |ks| {
            kes_pk = kes_sign.extractRootPk(ks) catch [_]u8{0} ** 32;
        }

        const shadow_inputs = shadow_producer.ShadowInputs{
            .slot = tip_slot,
            .epoch = pc.epoch_last,
            .slot_in_epoch = pc.slot_in_epoch_last,
            .tip_block_no = tip_block,
            .tip_hash32 = tip_hash32,
            .has_vrf = pc.vrf_cfg.enabled and pc.vrf_init_ok,
            .has_kes = pc.kes_key_state_len > 0,
            .has_pool_id = pc.key_cfg.pool_id_hex != null,
            .has_stake = pc.stake_cfg.stake_fraction_x1e9 > 0,
            .stake_fraction_x1e9 = pc.stake_cfg.stake_fraction_x1e9,
            .asc_x1e6 = pc.stake_cfg.asc_x1e6,
            .current_kes_period = @intCast(pc.kes_current_period_last),
            .opcert_start_period = @intCast(pc.kes_start_period),
            .max_kes_evolutions = @intCast(pc.kes_max_periods),
            .net_magic = @intCast(ctx.base.network_magic),
            .vrf_output = pc.vrf_output_bytes_last,
            .kes_key_state = kes_state,
            .kes_pk = kes_pk,
            .pool_id = pool_id_bytes,
            .timestamp_unix = obs_ts,
        };

        const shadow_event = shadow_producer.evaluate(shadow_inputs);
        ctx.shadow_hist.append(shadow_event);

        // Write shadow-last.json (overwrite, bounded single file)
        if (ctx.shadow_cfg.report_dir) |dir| {
            var path_buf: [512]u8 = undefined;
            const report_path = std.fmt.bufPrint(&path_buf, "{s}/shadow-last.json", .{dir}) catch null;
            if (report_path) |rp| {
                var json_buf: [1024]u8 = undefined;
                const json_line = shadow_producer.formatEventJson(shadow_event, &json_buf) catch null;
                if (json_line) |jl| {
                    var file = compat.fs.createFileAbsolute(rp, .{}) catch null;
                    if (file) |*f| {
                        defer f.close();
                        _ = f.write(jl) catch {};
                        _ = f.write("\n") catch {};
                    }
                }
            }
        }

        // Write artifact bundle only on local_candidate_ready
        if (shadow_event.state == .local_candidate_ready) {
            if (ctx.shadow_cfg.artifact_dir) |adir| {
                const readiness_mod = @import("../consensus/producer_readiness.zig");
                const bundle = readiness_mod.buildArtifactBundle(
                    tip_slot,
                    pc.epoch_last,
                    pc.slot_in_epoch_last,
                    pc.vrf_output_bytes_last,
                    kes_state.?,
                    kes_pk,
                    @intCast(pc.kes_start_period),
                    @intCast(ctx.base.network_magic),
                    tip_block,
                    tip_hash32,
                    pc.state_digest,
                    pool_id_bytes,
                );
                if (bundle) |b| {
                    // Write candidate header CBOR
                    var hdr_path_buf: [512]u8 = undefined;
                    const hdr_path = std.fmt.bufPrint(&hdr_path_buf, "{s}/shadow-candidate-header.cbor", .{adir}) catch null;
                    if (hdr_path) |hp| {
                        var hf = compat.fs.createFileAbsolute(hp, .{}) catch null;
                        if (hf) |*f| {
                            defer f.close();
                            _ = f.write(b.header_cbor[0..b.header_cbor_len]) catch {};
                        }
                    }
                    // Write full block CBOR
                    var blk_path_buf: [512]u8 = undefined;
                    const blk_path = std.fmt.bufPrint(&blk_path_buf, "{s}/shadow-candidate-block.cbor", .{adir}) catch null;
                    if (blk_path) |bp| {
                        var bf = compat.fs.createFileAbsolute(bp, .{}) catch null;
                        if (bf) |*f| {
                            defer f.close();
                            _ = f.write(b.block_cbor[0..b.block_cbor_len]) catch {};
                        }
                    }
                    // Write hashes JSON
                    var hash_path_buf: [512]u8 = undefined;
                    const hash_path = std.fmt.bufPrint(&hash_path_buf, "{s}/shadow-candidate-hashes.json", .{adir}) catch null;
                    if (hash_path) |hashp| {
                        var hfile = compat.fs.createFileAbsolute(hashp, .{}) catch null;
                        if (hfile) |*f| {
                            defer f.close();
                            var hj_buf: [512]u8 = undefined;
                            var bh_hex: [64]u8 = undefined;
                            _ = std.fmt.bufPrint(&bh_hex, "{x}", .{&b.block_hash}) catch {};
                            var body_hex: [64]u8 = undefined;
                            _ = std.fmt.bufPrint(&body_hex, "{x}", .{&b.body_hash}) catch {};
                            const hj = std.fmt.bufPrint(&hj_buf,
                                \\{{"block_hash":"{x}","body_hash":"{x}","slot":{d},"block_no":{d}}}
                            , .{ bh_hex[0..], body_hex[0..], tip_slot, tip_block }) catch null;
                            if (hj) |line| {
                                _ = f.write(line) catch {};
                                _ = f.write("\n") catch {};
                            }
                        }
                    }
                }
            }
        }
        // Producer dry-run: derive telemetry event from shadow evaluation
        if (ctx.dryrun_cfg.enabled) {
            var dr_validation_state: ?candidate_validator.ValidationState = null;
            var dr_candidate_valid: bool = false;

            // Validate candidate bundle when one was built
            if (shadow_event.state == .local_candidate_ready) {
                const readiness_mod = @import("../consensus/producer_readiness.zig");
                const dr_bundle = readiness_mod.buildArtifactBundle(
                    tip_slot, pc.epoch_last, pc.slot_in_epoch_last,
                    pc.vrf_output_bytes_last, kes_state.?,
                    kes_pk, @intCast(pc.kes_start_period),
                    @intCast(ctx.base.network_magic), tip_block,
                    tip_hash32, pc.state_digest, pool_id_bytes,
                );
                if (dr_bundle) |b| {
                    const report = candidate_validator.validate(
                        b.header_cbor[0..b.header_cbor_len],
                        b.block_cbor[0..b.block_cbor_len],
                        b.block_hash,
                        b.body_hash,
                    );
                    dr_validation_state = report.state;
                    dr_candidate_valid = (report.state == .valid);
                }
            }

            const dryrun_event = producer_dryrun.fromShadowAndValidation(
                shadow_event, dr_validation_state, dr_candidate_valid,
            );
            ctx.dryrun_hist.append(dryrun_event);

            // Write producer-dryrun-last.json (overwrite, bounded single file)
            if (ctx.dryrun_cfg.report_dir) |dir| {
                var dr_path_buf: [512]u8 = undefined;
                const dr_path = std.fmt.bufPrint(&dr_path_buf, "{s}/producer-dryrun-last.json", .{dir}) catch null;
                if (dr_path) |rp| {
                    var dr_json_buf: [1024]u8 = undefined;
                    const dr_json = producer_dryrun.formatEventJson(dryrun_event, &dr_json_buf) catch null;
                    if (dr_json) |jl| {
                        var dr_file = compat.fs.createFileAbsolute(rp, .{}) catch null;
                        if (dr_file) |*f| {
                            defer f.close();
                            _ = f.write(jl) catch {};
                            _ = f.write("\n") catch {};
                        }
                    }
                }
            }
        }
    }
    // Peer observatory: record block received
    {
        const ev = peer_observatory.makeEvent("chainsync", .block_received, tip_slot, tip_block, null, obs_ts);
        ctx.peer_obs.append(ev);
        if (ctx.peer_obs_journal_path.len > 0) {
            journal.appendPeerEvent(ctx.peer_obs_journal_path, ev, null) catch |err| {
                std.log.warn("peer event journal write: {}", .{err});
            };
        }
    }
    if (ctx.tx_decode_path.len > 0) {
        journal.appendTxDecode(
            ctx.tx_decode_path,
            ctx.base.cursor.slot,
            ctx.base.cursor.block_no,
            header_hash_hex[0..],
            tx_summaries,
        ) catch |err| {
            std.debug.print("WARN: tx_decode journal write failed: {}\n", .{err});
        };
    }
    // Confirmation correlation: scan block for pending txids
    if (tx_bodies_cbor) |tb| {
        const confirm_ts = compat.timestamp();
        var pi: u32 = 0;
        while (pi < ctx.confirmation.pendingCount()) {
            const pending = ctx.confirmation.pending[pi];
            if (block_hash.findTxidInBodies(tb, &pending.txid_hex)) {
                // Propagation: mark block observed + confirmed
                _ = ctx.propagation.markBlockObserved(pending.txid_hex, tip_block, tip_slot, confirm_ts);
                _ = ctx.propagation.markConfirmed(pending.txid_hex, confirm_ts, confirm_ts - pending.received_unix);
                if (ctx.confirmation.markConfirmed(
                    pending.txid_hex,
                    tip_block,
                    tip_slot,
                    confirm_ts,
                )) |c| {
                    if (ctx.confirmation_journal_path.len > 0) {
                        journal.appendConfirmation(
                            ctx.confirmation_journal_path, c,
                        ) catch |err| {
                            std.log.warn("confirmation journal write: {}", .{err});
                        };
                    }
                    // Propagation journal: write full lifecycle snapshot
                    if (ctx.propagation_journal_path.len > 0) {
                        if (ctx.propagation.lookupByTxid(pending.txid_hex)) |p| {
                            journal.appendPropagation(
                                ctx.propagation_journal_path, p.*,
                            ) catch |err| {
                                std.log.warn("propagation journal write: {}", .{err});
                            };
                        }
                    }
                }
                // markConfirmed shifts pending array; re-check same index
                continue;
            }
            pi += 1;
        }
    }
    if (ctx.debug and !ctx.stopping) {
        std.debug.print("JOURNAL append fwd\n", .{});
    }
    const now = compat.timestamp();
    if (ctx.tps_meter == null) {
        ctx.tps_meter = tps.TpsMeter.init(now);
    }
    ctx.tps_meter.?.addBlock(tx_count, now, ctx.debug);
    if (ctx.debug and !ctx.stopping) {
        std.debug.print("TX_COUNT={d}\n", .{tx_count});
    }
    if (ctx.preview_utxo) {
        if (ctx.debug and !ctx.stopping) {
            std.debug.print(
                "UTXO count={d} undo_depth={d}\n",
                .{ ctx.utxo.count(), ctx.undo_stack.items.len },
            );
        }
        utxo_store.save(ctx.utxo_path, &ctx.utxo) catch {};
    }
    var tip_prefix: [8]u8 = [_]u8{'?'} ** 8;
    if (tip_prefix8) |prefix| {
        tip_prefix = prefix;
    }
    ctx.last_saved_tip_hex = tip_prefix;
    ctx.last_dup_tip_hex = null;
    if (!ctx.stopping) {
        std.debug.print(
            "ROLL FWD delivered slot={d} block={d} tip={s} fwd={d} back={d} txs={d} utxo={d}\n",
            .{
                ctx.base.cursor.slot,
                ctx.base.cursor.block_no,
                tip_prefix[0..],
                ctx.base.cursor.roll_forward_count,
                ctx.base.cursor.roll_backward_count,
                tx_count,
                ctx.utxo.count(),
            },
        );
        // Phase B'''' Row 16: companion ROLL FWD PEER log when peer-tip
        // is ahead of delivered (delta_blocks >= 1) — peer-lag visibility
        // without polluting the delivered ROLL FWD log line.
        if (tip_block > ctx.base.cursor.block_no) {
            const delta_blocks: u64 = tip_block - ctx.base.cursor.block_no;
            var peer_prefix: [8]u8 = [_]u8{'?'} ** 8;
            _ = std.fmt.bufPrint(&peer_prefix, "{x}", .{tip_hash32[0..4]}) catch {};
            std.debug.print(
                "ROLL FWD PEER: peer_slot={d} peer_block={d} peer_tip={s} (delta_blocks={d})\n",
                .{ tip_slot, tip_block, peer_prefix[0..], delta_blocks },
            );
        }
    }
}

fn onRollBackward(
    ctx_any: *anyopaque,
    tip_slot: u64,
    tip_block: u64,
    tip_hash32: [32]u8,
    point_slot: u64,
    point_block: u64,
    point_hash: [32]u8,
) !void {
    _ = tip_hash32;
    _ = point_hash;

    const ctx = ctxFromAny(ctx_any);
    if (ctx.stopping) return;
    const tip = ctx.base.current_tip orelse return;

    // Update metrics
    if (ctx.metrics) |metrics_any| {
        const metrics = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
        _ = metrics.roll_back.fetchAdd(1, .acq_rel);
    }

    if (ctx.debug and !ctx.stopping) {
        if (ctx.base.current_point) |point| {
            printPoint(point);
        }
        printTip(tip);
    }
    ctx.base.cursor.roll_backward_count += 1;
    ctx.base.cursor.updated_unix = compat.timestamp();
    // Chain index: pop most recent entry on rollback
    _ = ctx.chain_idx.pop();
    try cursor_store.save(ctx.base.cursor, ctx.cursor_path);
    if (!ctx.stopping) {
        std.debug.print("CURSOR saved {s}\n", .{ctx.cursor_path});
    }
    try journal.appendRollBackward(
        ctx.journal_path,
        compat.timestamp(),
        ctx.base.cursor.slot,
        ctx.base.cursor.block_no,
        ctx.base.cursor.tip_hash_hex[0..],
    );
    if (ctx.debug and !ctx.stopping) {
        std.debug.print("JOURNAL append back\n", .{});
    }
    // Rollback already applied by follower.zig before this callback;
    // only log post-rollback state here.
    if (ctx.debug and !ctx.stopping) {
        std.debug.print(
            "UTXO rollback count={d} undo_depth={d}\n",
            .{ ctx.utxo.count(), ctx.undo_stack.items.len },
        );
    }
    const tip_hash = getTipHash(tip);
    // Phase B'''': cursor advances to the DELIVERED rollback point
    // (the new effective delivered tip), not peer's far tip. Preserves
    // D-1 domain coherence on rollback. tip_slot/tip_block remain
    // available for peer-tip telemetry below.
    _ = tip_slot;
    _ = tip_block;
    if (getTipSlotBlock(tip)) |_| {}
    ctx.base.cursor.slot = point_slot;
    ctx.base.cursor.block_no = point_block;
    var tip_prefix: [8]u8 = [_]u8{'?'} ** 8;
    if (tip_hash) |hash| {
        if (hash.len >= 4) {
            _ = try std.fmt.bufPrint(
                &tip_prefix,
                "{x}",
                .{hash[0..4]},
            );
        }
    }
    if (!ctx.stopping) {
        std.debug.print(
            "ROLL BACK slot={d} block={d} tip={s} fwd={d} back={d}\n",
            .{
                ctx.base.cursor.slot,
                ctx.base.cursor.block_no,
                tip_prefix[0..],
                ctx.base.cursor.roll_forward_count,
                ctx.base.cursor.roll_backward_count,
            },
        );
    }
}

fn onStatus(
    ctx_any: *anyopaque,
    slot: u64,
    block: u64,
    fwd: u64,
    back: u64,
    tip_prefix8: [8]u8,
) void {
    const ctx = ctxFromAny(ctx_any);
    if (ctx.stopping) return;
    const now = compat.timestamp();
    if (now - ctx.last_status_unix < 3) return;
    ctx.last_status_unix = now;
    const utxo_est: u64 = if (ctx.base.utxo_count_est > 0) @intCast(ctx.base.utxo_count_est) else 0;
    // Sync metrics gauges on every status tick (same values as the Status line)
    if (ctx.metrics) |metrics_any| {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
        m.slot.store(slot, .release);
        m.block_no.store(block, .release);
        m.utxo.store(utxo_est, .release);
    }
    // Check LMDB convergence on every status tick
    follower.checkConvergence(&ctx.base, ctx.alloc);
    if (ctx.pretty) {
        pretty.printStatusLine(
            ctx.lang,
            slot,
            block,
            0.0,
            utxo_est,
            fwd,
            back,
            tip_prefix8[0..],
        );
        return;
    }
    std.debug.print(
        "STATUS slot={d} block={d} fwd={d} back={d} tip={s}\n",
        .{ slot, block, fwd, back, tip_prefix8[0..] },
    );
}

fn onShutdown(ctx_any: *anyopaque) void {
    const ctx = ctxFromAny(ctx_any);
    ctx.stopping = true;
    std.debug.print(
        "Final cursor: slot={d} block={d} fwd={d} back={d} tip={s}\n",
        .{
            ctx.base.cursor.slot,
            ctx.base.cursor.block_no,
            ctx.base.cursor.roll_forward_count,
            ctx.base.cursor.roll_backward_count,
            ctx.base.cursor.tip_hash_hex[0..8],
        },
    );
}

pub fn runWithOptions(
    alloc: std.mem.Allocator,
    host: []const u8,
    port: u16,
    lang: i18n.Lang,
    debug: bool,
    pretty_status: bool,
    is_mainnet: bool,
    network_magic: u64,
    state_dir: []const u8,
    genesis_dir_name: []const u8,
    metrics: ?*const anyopaque,
) !void {
    g_debug = debug;
    const peer_sharing = !is_mainnet;

    const trace = compat.hasEnvVar(alloc, "TSUNAGI_TRACE");
    if (trace or debug) {
        std.debug.print("INIT: is_mainnet={} network_magic={d} peer_sharing={}\n", .{
            is_mainnet,
            network_magic,
            peer_sharing,
        });
    }
    try ensureStateDir(state_dir);

    const cursor_path = try std.fs.path.join(alloc, &[_][]const u8{ state_dir, "cursor.json" });
    errdefer alloc.free(cursor_path);
    const journal_path = try std.fs.path.join(alloc, &[_][]const u8{ state_dir, "journal.ndjson" });
    errdefer alloc.free(journal_path);
    const tx_decode_path = try std.fs.path.join(alloc, &[_][]const u8{ state_dir, "tx_decode.ndjson" });
    errdefer alloc.free(tx_decode_path);
    const mempool_journal_path = try std.fs.path.join(alloc, &[_][]const u8{ state_dir, "mempool.ndjson" });
    errdefer alloc.free(mempool_journal_path);
    const confirmation_journal_path = try std.fs.path.join(alloc, &[_][]const u8{ state_dir, "confirmation.ndjson" });
    errdefer alloc.free(confirmation_journal_path);
    const propagation_journal_path = try std.fs.path.join(alloc, &[_][]const u8{ state_dir, "propagation.ndjson" });
    errdefer alloc.free(propagation_journal_path);
    const slot_journal_path = try std.fs.path.join(alloc, &[_][]const u8{ state_dir, "slot_observatory.ndjson" });
    errdefer alloc.free(slot_journal_path);
    const peer_obs_journal_path = try std.fs.path.join(alloc, &[_][]const u8{ state_dir, "peer_observatory.ndjson" });
    errdefer alloc.free(peer_obs_journal_path);
    const utxo_path = try std.fs.path.join(alloc, &[_][]const u8{ state_dir, "utxo.snapshot" });
    errdefer alloc.free(utxo_path);

    // Process-lifetime allocation, intentionally never freed.
    //
    // Detached worker threads — leader_schedule, wall_tick,
    // protocol_manager, peer_probe — are spawned below with
    // `&ctx.base.producer_ctx` and are NEVER joined. A stack-allocated
    // `ctx` died the instant `runWithOptions` returned, leaving those
    // worker pointers dangling into a dead stack frame for the whole
    // shutdown window — the `double free or corruption (fasttop)`
    // observed at process exit. Heap-allocating `ctx` and never freeing
    // it keeps every worker pointer valid until `std.process.exit`; the
    // OS reclaims the allocation at exit (matches cardano-node / Amaru
    // teardown discipline — no deep free of runtime state at shutdown).
    const ctx = try alloc.create(FollowerCtx);
    ctx.* = FollowerCtx{
        .base = .{
            .cursor = try cursor_store.loadOrInit(alloc, cursor_path),
            .current_tip = null,
            .current_block = null,
            .current_point = null,
            .roll_forward_count = 0,
            .debug_verbose = debug,
            .utxo = null,
            .undo_stack = null,
            .preview_utxo = false,
            .network_magic = network_magic,
            .peer_sharing = peer_sharing,
            .metrics = metrics,
        },
        .alloc = alloc,
        .tps_meter = null,
        .utxo = utxo_mod.UTxO.init(alloc),
        .undo_stack = std.array_list.Managed(utxo_mod.Undo).init(alloc),
        .debug = debug,
        .lang = lang,
        .pretty = pretty_status,
        .preview_utxo = true,
        .cursor_path = cursor_path,
        .journal_path = journal_path,
        .tx_decode_path = tx_decode_path,
        .utxo_path = utxo_path,
        .prev_candidates = null,
        .prev_header_values = [_]?[]u8{null} ** 15,
        .prev_changed = [_]bool{false} ** 15,
        .captured_first_rollforward = false,
        .prev_header_hash_opt = null,
        .prev_header_cbor_len = null,
        .prev_header_body_raw = null,
        .printed_continuity_verdict = false,
        .last_dup_tip_hex = null,
        .last_saved_tip_hex = null,
        .metrics = metrics,
    };
    ctx.base.tx_decode_journal_path = tx_decode_path;
    // Phase B'''' F3 closure: initialize peer_tip stale-suppression
    // high-water from the loaded cursor so the first post-restart
    // RollForward cannot bypass stale-suppression. Pre-fix this field
    // was implicitly the cursor itself (PT-domain); post-fix the cursor
    // is delivered-domain so we seed the explicit PT-domain field from
    // it (correct on first warm restart; subsequent RollForwards advance
    // it explicitly in onRollForward).
    ctx.base.peer_tip_slot_last = ctx.base.cursor.slot;
    ctx.base.peer_tip_block_no_last = ctx.base.cursor.block_no;
    ctx.mempool_journal_path = mempool_journal_path;
    http_metrics.g_mempool_summary = &ctx.mempool_summary;
    http_metrics.g_mempool_journal_path = mempool_journal_path;
    http_metrics.g_chain_index = &ctx.chain_idx;
    ctx.confirmation_journal_path = confirmation_journal_path;
    http_metrics.g_confirmation_tracker = &ctx.confirmation;
    ctx.propagation_journal_path = propagation_journal_path;
    http_metrics.g_propagation_tracker = &ctx.propagation;
    ctx.slot_journal_path = slot_journal_path;
    ctx.peer_obs_journal_path = peer_obs_journal_path;
    // Shadow producer: gate behind TSUNAGI_SHADOW_PRODUCER_ENABLE=1
    {
        const shadow_env = compat.getEnvVarOwned(alloc, "TSUNAGI_SHADOW_PRODUCER_ENABLE") catch null;
        const shadow_on = if (shadow_env) |v| blk: {
            defer alloc.free(v);
            break :blk std.mem.eql(u8, v, "1");
        } else false;
        if (shadow_on) {
            ctx.shadow_cfg.enabled = true;
            const report_env = compat.getEnvVarOwned(alloc, "TSUNAGI_SHADOW_REPORT_DIR") catch null;
            if (report_env) |dir| {
                if (dir.len > 0) {
                    compat.fs.cwd().makePath(dir) catch {};
                    ctx.shadow_cfg.report_dir = dir;
                } else {
                    alloc.free(dir);
                }
            }
            const artifact_env = compat.getEnvVarOwned(alloc, "TSUNAGI_SHADOW_ARTIFACT_DIR") catch null;
            if (artifact_env) |dir| {
                if (dir.len > 0) {
                    compat.fs.cwd().makePath(dir) catch {};
                    ctx.shadow_cfg.artifact_dir = dir;
                } else {
                    alloc.free(dir);
                }
            }
            std.debug.print("SHADOW PRODUCER: enabled=true report_dir={s} artifact_dir={s}\n", .{
                if (ctx.shadow_cfg.report_dir) |d| d else "(none)",
                if (ctx.shadow_cfg.artifact_dir) |d| d else "(none)",
            });
        }
    }
    // Producer dry-run: gate behind TSUNAGI_PRODUCER_DRYRUN_ENABLE=1
    {
        const dryrun_env = compat.getEnvVarOwned(alloc, "TSUNAGI_PRODUCER_DRYRUN_ENABLE") catch null;
        const dryrun_on = if (dryrun_env) |v| blk: {
            defer alloc.free(v);
            break :blk std.mem.eql(u8, v, "1");
        } else false;
        if (dryrun_on) {
            ctx.dryrun_cfg.enabled = true;
            // Dry-run requires shadow producer — auto-enable if not already
            if (!ctx.shadow_cfg.enabled) {
                ctx.shadow_cfg.enabled = true;
                std.debug.print("DRYRUN: auto-enabled shadow producer\n", .{});
            }
            const dr_report_env = compat.getEnvVarOwned(alloc, "TSUNAGI_PRODUCER_DRYRUN_REPORT_DIR") catch null;
            if (dr_report_env) |dir| {
                if (dir.len > 0) {
                    compat.fs.cwd().makePath(dir) catch {};
                    ctx.dryrun_cfg.report_dir = dir;
                } else {
                    alloc.free(dir);
                }
            }
            const dr_artifact_env = compat.getEnvVarOwned(alloc, "TSUNAGI_PRODUCER_DRYRUN_ARTIFACT_DIR") catch null;
            if (dr_artifact_env) |dir| {
                if (dir.len > 0) {
                    compat.fs.cwd().makePath(dir) catch {};
                    ctx.dryrun_cfg.artifact_dir = dir;
                } else {
                    alloc.free(dir);
                }
            }
            std.debug.print("PRODUCER DRYRUN: enabled=true report_dir={s} artifact_dir={s}\n", .{
                if (ctx.dryrun_cfg.report_dir) |d| d else "(none)",
                if (ctx.dryrun_cfg.artifact_dir) |d| d else "(none)",
            });
        }
    }
    ctx.base.utxo = &ctx.utxo;
    ctx.base.undo_stack = &ctx.undo_stack;
    ctx.base.preview_utxo = ctx.preview_utxo;
    producer.initWithNet(&ctx.base.producer_ctx, alloc, is_mainnet, if (is_mainnet) @as(?u32, @intCast(network_magic)) else null, genesis_dir_name);

    // Spawn-once guard (forge-readiness 2026-05-23): main.zig's peer-rotation
    // loop can re-enter runWithOptions on disconnect; without this guard each
    // re-entry would spawn another set of leader_schedule / wall_tick /
    // protocol_manager / peer_probe / acceptance_tracker / stake_distribution
    // worker threads, all pointing at &ctx.base.producer_ctx of the current
    // (heap-pinned) ctx. The first ctx wins and its workers carry forward.
    if (!g_workers_spawned.swap(true, .acq_rel)) {

    // Phase 9.1: multi-probe fanout. TSUNAGI_PEER_SECONDARY accepts a
    // comma-separated list of host:port entries; one detached probe
    // thread is spawned per entry (capped at multi_probe.MAX_PROBES).
    if (compat.getEnvVarOwned(alloc, "TSUNAGI_PEER_SECONDARY") catch null) |spec| {
        defer alloc.free(spec);
        var it = std.mem.tokenizeAny(u8, spec, ",;");
        var probe_id: u32 = 0;
        while (it.next()) |raw_entry| {
            const entry = std.mem.trim(u8, raw_entry, " \t\r\n");
            if (entry.len == 0) continue;
            if (probe_id >= multi_probe.MAX_PROBES) {
                std.debug.print("PEER_PROBE_SPAWN: MAX_PROBES={d} reached, ignoring {s}\n", .{ multi_probe.MAX_PROBES, entry });
                break;
            }
            const sep = std.mem.indexOfScalar(u8, entry, ':') orelse {
                std.debug.print("PEER_PROBE_SPAWN: invalid entry (need host:port) {s}\n", .{entry});
                continue;
            };
            const probe_host = entry[0..sep];
            const probe_port = std.fmt.parseUnsigned(u16, entry[sep + 1 ..], 10) catch 0;
            if (probe_host.len == 0 or probe_port == 0) {
                std.debug.print("PEER_PROBE_SPAWN: invalid entry {s}\n", .{entry});
                continue;
            }
            _ = peer_probe.spawnBackground(
                alloc,
                probe_host,
                probe_port,
                network_magic,
                &ctx.base.producer_ctx,
                probe_id,
            );
            probe_id += 1;
        }
    }

    // Phase 8.5: leader schedule engine — background VRF scanner.
    // Pure observability; never affects forge path.
    _ = leader_schedule.spawnBackground(alloc, &ctx.base.producer_ctx);

    // Wall-clock per-second producer tick driver. Ensures VRF leader
    // checks run for every slot, independent of upstream block-arrival
    // rate.
    _ = wall_tick.spawnBackground(alloc, &ctx.base.producer_ctx);

    // Hardfork Readiness Layer: protocol params auto-update from Koios.
    _ = protocol_manager.spawnBackground(alloc, genesis_dir_name, follower.currentEpochApprox);

    // Phase 1: chain σ source loader (Koios-fed, drives FORGE_GATE_SIGMA)
    {
        const stake_source = @import("../../producer/stake_source.zig");
        const pool_id = compat.getenv("TSUNAGI_POOL_BECH32") orelse
            "pool1nu2ptydyw7hhlp8kc6yr5dmkkujjn4yq59p5e5dm28xp6vfw5ts";
        _ = stake_source.spawnBackground(alloc, pool_id);
    }

    // Phase 2: acceptance tracker (Koios-fed canonical observer + classifier)
    {
        const acceptance_tracker = @import("../../producer/acceptance_tracker.zig");
        const pool_id = compat.getenv("TSUNAGI_POOL_BECH32") orelse
            "pool1nu2ptydyw7hhlp8kc6yr5dmkkujjn4yq59p5e5dm28xp6vfw5ts";
        _ = acceptance_tracker.spawnPoller(alloc, pool_id);
    }

    // Wire pool_stats to read live stake totals from follower.g_stake_dist
    // (the indirection keeps pool_stats unit-testable without follower deps).
    pool_stats.setLiveSource(struct {
        fn read() pool_stats.LiveStakeView {
            return .{
                .our_pool_lovelace = follower.g_stake_dist.our_pool_lovelace,
                .total_staked_lovelace = follower.g_stake_dist.total_staked_lovelace,
                .credential_count = follower.g_stake_dist.credential_count,
            };
        }
    }.read);

    // Phase 4.2: Koios stake bootstrap — populate ledger sigma on startup so
    // PRAOS uses real network stake from slot 0 rather than env fallback.
    // Gated by TSUNAGI_POOL_BECH32. Non-blocking, retry-on-failure.
    if (compat.getEnvVarOwned(alloc, "TSUNAGI_POOL_BECH32") catch null) |pool_bech32| {
        defer alloc.free(pool_bech32);
        if (pool_bech32.len > 0) {
            _ = stake_distribution.spawnBootstrap(
                alloc,
                &follower.g_stake_dist,
                &ctx.base.producer_ctx.ledger_sigma_x1e9,
                &ctx.base.producer_ctx.ledger_sigma_valid,
                &ctx.base.producer_ctx.ledger_sigma_source_kind,
                genesis_dir_name,
                pool_bech32,
                follower.currentEpochApprox,
            );
        }
    }

    } // end spawn-once guard



    // v1.8.0: wire dryrun artifact dir
    if (ctx.base.producer_ctx.dryrun_enabled) {
        ctx.base.producer_ctx.dryrun_home_dir = std.fs.path.join(alloc, &[_][]const u8{ state_dir, "producer_dryrun", "candidates" }) catch null;
        ctx.base.producer_ctx.dryrun_blocks_dir = std.fs.path.join(alloc, &[_][]const u8{ state_dir, "producer_dryrun", "blocks" }) catch null;
        ctx.base.producer_ctx.dryrun_net_name = genesis_dir_name;
        ctx.base.producer_ctx.dryrun_mempool = txsubmission.g_mempool;
        ctx.base.producer_ctx.utxo_set = ctx.base.utxo;
    }
    // Rolling chain fragment: write recent headers for propagation ancestry
    if (ctx.base.producer_ctx.forge_all_flags_set) {
        const frag_path = std.fs.path.join(alloc, &[_][]const u8{ state_dir, "chain_fragment" }) catch null;
        if (frag_path) |fp| {
            compat.fs.cwd().makePath(fp) catch {};
            ctx.fragment_dir = fp;
            // Resume sequence from highest existing file to avoid collisions after restart
            var dir = compat.fs.cwd().openDir(fp, .{ .iterate = true }) catch null;
            if (dir) |*d| {
                defer d.close();
                var it = d.iterate();
                var max_seq: u32 = 0;
                while (it.next() catch null) |entry| {
                    if (entry.kind != .file) continue;
                    if (entry.name.len >= 20 and std.mem.endsWith(u8, entry.name, ".header.cbor")) {
                        const s = std.fmt.parseInt(u32, entry.name[0..8], 10) catch continue;
                        if (s >= max_seq) max_seq = s + 1;
                    }
                }
                ctx.fragment_seq = max_seq;
            }
            std.debug.print("CHAIN FRAGMENT: writing to {s} (capacity={d}, resume_seq={d})\n", .{ fp, ctx.fragment_capacity, ctx.fragment_seq });
        }
    }

    // One-time export of producer readiness to metrics immediately after init.
    // Without this, /state shows zero-default producer fields until the first
    // RollForward, causing guardian forge-arm to abort on false zero-state.
    if (ctx.base.metrics) |ma_init| {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma_init))));
        const pc = &ctx.base.producer_ctx;
        m.producer_keys_enabled.store(if (pc.key_cfg.enabled) @as(u64, 1) else @as(u64, 0), .release);
        m.producer_keys_parse_ok.store(if (pc.key_cfg.parse_ok) @as(u64, 1) else @as(u64, 0), .release);
        m.producer_vrf_enabled.store(if (pc.vrf_cfg.enabled) @as(u64, 1) else @as(u64, 0), .release);
        m.producer_vrf_parse_ok.store(if (pc.vrf_cfg.parse_ok) @as(u64, 1) else @as(u64, 0), .release);
        m.producer_vrf_init_ok.store(if (pc.vrf_init_ok) @as(u64, 1) else @as(u64, 0), .release);
        m.producer_praos_enabled.store(if (pc.praos_enabled) @as(u64, 1) else @as(u64, 0), .release);
        m.producer_genesis_parse_ok.store(if (pc.genesis_parse_ok) @as(u64, 1) else @as(u64, 0), .release);
        m.producer_genesis_path_ok.store(if (pc.genesis_path_ok) @as(u64, 1) else @as(u64, 0), .release);
        m.producer_clock_ok.store(if (pc.genesis_parse_ok and pc.slot_length_s >= 1) @as(u64, 1) else @as(u64, 0), .release);
        const gen_unix: u64 = if (pc.genesis_unix >= 0) @intCast(pc.genesis_unix) else 0;
        m.producer_genesis_unix.store(gen_unix, .release);
        m.producer_slot_length_s.store(@intCast(pc.slot_length_s), .release);
        m.producer_dryrun_enabled.store(if (pc.dryrun_enabled) @as(u64, 1) else @as(u64, 0), .release);
        m.producer_kes_enabled.store(if (pc.kes_cfg.enabled) @as(u64, 1) else @as(u64, 0), .release);
        m.producer_kes_parse_ok.store(if (pc.kes_cfg.parse_ok) @as(u64, 1) else @as(u64, 0), .release);
        m.producer_kes_start_period.store(pc.kes_start_period, .release);
        m.producer_kes_max_periods.store(pc.kes_max_periods, .release);
        std.debug.print("PRODUCER METRICS: initial readiness exported to /state\n", .{});
    }

    defer {
        // `ctx` is a process-lifetime heap allocation (see its creation
        // above) referenced by detached, never-joined worker threads.
        // Deep-freeing ctx-owned memory here — undo_stack, utxo, header
        // values, path strings — would invalidate those live worker
        // references during the shutdown window and was the source of
        // the `double free or corruption (fasttop)` abort.
        //
        // Teardown discipline (matches cardano-node / Amaru): persist
        // state to disk, then let the OS reclaim memory at process
        // exit. No deep free of runtime state at shutdown.
        utxo_store.save(ctx.utxo_path, &ctx.utxo) catch {};
    }

    const lmdb_mode = compat.hasEnvVar(alloc, "TSUNAGI_LMDB");
    var utxo_file = compat.fs.openFileAbsolute(ctx.utxo_path, .{}) catch null;
    if (utxo_file) |*file| {
        file.close();
        if (lmdb_mode) {
            // LMDB mode: skip loading snapshot into memory (avoids OOM)
            const baseline = countSnapshotLines(ctx.utxo_path);
            std.debug.print("UTxO snapshot skipped (LMDB mode); baseline_count={d}\n", .{baseline});
        } else {
            ctx.utxo.deinit();
            ctx.utxo = try utxo_store.load(alloc, ctx.utxo_path);
            std.debug.print(
                "{s} (count={d})\n",
                .{ i18n.msg(lang, "snapshot_loaded"), ctx.utxo.count() },
            );
        }
    }
    if (!lmdb_mode) {
        try utxo_store.save(ctx.utxo_path, &ctx.utxo);
    }
    std.debug.print(
        "{s}: {s} (count={d})\n",
        .{ i18n.msg(lang, "snapshot_ready"), ctx.utxo_path, ctx.utxo.count() },
    );

    vprint(
        "cursor loaded: slot={d} block_no={d} fwd={d} back={d}\n",
        .{
            ctx.base.cursor.slot,
            ctx.base.cursor.block_no,
            ctx.base.cursor.roll_forward_count,
            ctx.base.cursor.roll_backward_count,
        },
    );

    // ── Startup ancestry continuity check ──
    // Walk backward from the tip's parent through the fragment directory.
    // The tip itself is in chain_tip/ but NOT in fragment/ (fragment has tip-1 and older).
    // ChainIndex is empty at startup; LMDB tier is optional (pass null).
    {
        const ancestry = @import("../ledger/ancestry.zig");
        // Read prev_header_hash.hex (the tip's parent hash) — this is the newest fragment entry.
        const prev_hash_path = std.fmt.allocPrint(alloc, "{s}/chain_tip/prev_header_hash.hex", .{state_dir}) catch null;
        defer if (prev_hash_path) |p| alloc.free(p);
        var start_hash: [32]u8 = [_]u8{0} ** 32;
        var have_start = false;
        if (prev_hash_path) |php| {
            var pf = compat.fs.cwd().openFile(php, .{}) catch null;
            if (pf) |*f| {
                defer f.close();
                var hex_buf: [128]u8 = undefined;
                const n = f.readAll(&hex_buf) catch 0;
                const trimmed = std.mem.trim(u8, hex_buf[0..n], " \t\r\n");
                if (trimmed.len == 64) {
                    have_start = true;
                    for (0..32) |i| {
                        start_hash[i] = (hexVal4(trimmed[i * 2]) orelse 0) << 4 | (hexVal4(trimmed[i * 2 + 1]) orelse 0);
                    }
                }
            }
        }
        if (have_start) {
            const frag_path = std.fmt.allocPrint(alloc, "{s}/chain_tip/fragment", .{state_dir}) catch null;
            defer if (frag_path) |p| alloc.free(p);
            const ANCESTRY_THRESHOLD: u32 = 10;
            var buf: [200]ancestry.AncestryEntry = undefined;
            // depth starts at 1 (the tip itself, whose parent is start_hash)
            const walk_depth = ancestry.walkBack(start_hash, &ctx.chain_idx, frag_path, null, null, &buf);
            const depth = walk_depth + 1; // +1 for the tip itself
            if (depth >= ANCESTRY_THRESHOLD) {
                const oldest = if (walk_depth > 0) buf[walk_depth - 1] else buf[0];
                std.debug.print("ANCESTRY_VERIFIED: depth={d} tip_slot={d} tip_block={d} oldest_slot={d} oldest_block={d}\n", .{
                    depth, ctx.base.cursor.slot, ctx.base.cursor.block_no,
                    oldest.slot, oldest.block_no,
                });
            } else if (walk_depth > 0) {
                std.debug.print("ANCESTRY_BREAK: depth={d} (below threshold {d}) tip_slot={d} tip_block={d} last_slot={d} last_block={d}\n", .{
                    depth, ANCESTRY_THRESHOLD,
                    ctx.base.cursor.slot, ctx.base.cursor.block_no,
                    buf[walk_depth - 1].slot, buf[walk_depth - 1].block_no,
                });
            } else {
                std.debug.print("ANCESTRY_BREAK: depth=0 tip_slot={d} tip_block={d} (tip parent not in fragment)\n", .{
                    ctx.base.cursor.slot, ctx.base.cursor.block_no,
                });
            }
        }
    }

    const callbacks = follower.Callbacks{
        .on_roll_forward = onRollForward,
        .on_roll_backward = onRollBackward,
        .on_status = onStatus,
        .on_shutdown = onShutdown,
        .on_peer_connect = onPeerConnect,
        .on_peer_disconnect = onPeerDisconnect,
    };

    var counting = counting_allocator.CountingAllocator.init(alloc);
    const counted_alloc = counting.allocator();
    try follower.run(counted_alloc, host, port, callbacks, &ctx.base);
}

pub fn run(alloc: std.mem.Allocator, host: []const u8, port: u16) !void {
    const is_mainnet = (port == 3001);
    const sd = blk: {
        const env_dir = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
        if (env_dir) |dir| {
            if (dir.len > 0) break :blk dir;
            alloc.free(dir);
        }
        const home = compat.getEnvVarOwned(alloc, "HOME") catch null;
        if (home) |dir| {
            defer alloc.free(dir);
            break :blk try std.fs.path.join(alloc, &[_][]const u8{ dir, ".tsunagi" });
        }
        return error.EnvironmentVariableNotFound;
    };
    defer alloc.free(sd);
    try runWithOptions(alloc, host, port, .en, true, false, is_mainnet,
        if (is_mainnet) @as(u64, 764_824_073) else 2,
        sd, if (is_mainnet) "mainnet" else "preview", null);
}

fn hexVal4(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}
