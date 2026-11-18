const std = @import("std");
const compat = @import("compat");
const utxo = @import("utxo.zig");

// Upper bound for a persisted UTxO file read in one shot. UTxO lines are ~80
// bytes; 512 MiB covers millions of entries (preview's set is far smaller).
const MAX_UTXO_FILE_BYTES: usize = 512 * 1024 * 1024;

pub fn save(path: []const u8, state: *utxo.UTxO) !void {
    var file = try compat.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    // Buffer the whole serialization in memory, then issue ONE writeAll.
    //
    // RESIDUAL-CAVEAT FIX (Zig 0.16 compat shim): compat.fs.File's per-call
    // writer().print() spins up a fresh Io.Writer + flush() (a write syscall)
    // on EVERY call. Printing one line per UTxO entry therefore performed
    // O(entries) positional pwrite+fsync-less-flush syscalls — pathological for
    // a large UTxO set. A single buffered writeAll is byte-for-byte identical on
    // disk (same format strings, same iteration order) but one syscall.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var out = std.array_list.Managed(u8).init(aa);

    const lw = compat.listWriter(&out);
    try lw.print("UTXO_COUNT {d}\n", .{state.map.count()});

    var it = state.map.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        try lw.print(
            "{x}:{d} {d}\n",
            .{
                &k.tx_hash,
                k.index,
                v.lovelace,
            },
        );
    }
    try file.writeAll(out.items);
}

pub fn load(alloc: std.mem.Allocator, path: []const u8) !utxo.UTxO {
    var state = utxo.UTxO.init(alloc);

    var file = compat.fs.cwd().openFile(path, .{}) catch return state;
    defer file.close();

    // RESIDUAL-CAVEAT FIX (Zig 0.16 compat shim): the previous
    // readUntilDelimiterOrEof loop read ONE byte at a time, and each byte went
    // through compat.fs.File.read -> a fresh 4096-byte Io.Reader + seekTo +
    // pread. That was O(bytes) reader-setups and overlapping preads. Read the
    // whole file ONCE (compat.readToEndAlloc is a single streaming drain), then
    // split lines in memory. Parsing is unchanged, so loaded state is identical.
    const contents = file.readToEndAlloc(alloc, MAX_UTXO_FILE_BYTES) catch return state;
    defer alloc.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "UTXO_COUNT")) continue;

        var it = std.mem.splitSequence(u8, line, " ");
        const left = it.next() orelse continue;
        const value_str = it.next() orelse continue;
        const value = std.fmt.parseInt(u64, value_str, 10) catch continue;

        var it2 = std.mem.splitSequence(u8, left, ":");
        const hash_hex = it2.next() orelse continue;
        const index_str = it2.next() orelse continue;
        const index = std.fmt.parseInt(u32, index_str, 10) catch continue;

        if (hash_hex.len != 64) continue;
        var hash: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&hash, hash_hex) catch continue;

        state.map.put(
            .{ .tx_hash = hash, .index = index },
            .{ .address = "", .lovelace = value },
        ) catch continue;
    }

    return state;
}

test "utxo_store: buffered save + single-read load roundtrip (compat residual fix)" {
    const a = std.testing.allocator;
    const path = "/tmp/tsunagi_utxo_store_roundtrip.txt";
    defer compat.fs.cwd().deleteFile(path) catch {};

    var src = utxo.UTxO.init(a);
    defer src.deinit();

    // A few deterministic entries (count > 1 exercises the per-entry print loop
    // that previously issued one flush() syscall per line).
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        var h: [32]u8 = undefined;
        for (&h, 0..) |*b, j| b.* = @intCast((j + i) & 0xff);
        try src.map.put(
            .{ .tx_hash = h, .index = i },
            .{ .address = "", .lovelace = 1_000_000 + @as(u64, i) },
        );
    }

    try save(path, &src);

    var loaded = try load(a, path);
    defer loaded.deinit();

    try std.testing.expectEqual(src.map.count(), loaded.map.count());

    var it = src.map.iterator();
    while (it.next()) |entry| {
        const got = loaded.map.get(entry.key_ptr.*) orelse return error.MissingKey;
        try std.testing.expectEqual(entry.value_ptr.*.lovelace, got.lovelace);
    }
}

test "utxo_store: load of missing file returns empty state (no crash)" {
    const a = std.testing.allocator;
    var st = try load(a, "/tmp/tsunagi_utxo_store_definitely_absent_xyz.txt");
    defer st.deinit();
    try std.testing.expectEqual(@as(usize, 0), st.map.count());
}
