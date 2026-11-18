const std = @import("std");
const compat = @import("compat");
const snapshot_cmd = @import("snapshot_cmd.zig");
const tsf = @import("tsf.zig");

fn readAnchor(path: []const u8) !tsf.Header {
    var f = try compat.fs.cwd().openFile(path, .{});
    defer f.close();
    return try tsf.readHeader(f.deprecatedReader());
}

pub fn run(alloc: std.mem.Allocator, tsf_path: []const u8, lmdb_dir_opt: ?[]const u8) !void {
    std.debug.print(
        \\
        \\TSUNAGI Bootstrap
        \\=================
        \\Importing TSF snapshot into LMDB...
        \\  file: {s}
        \\
    , .{tsf_path});

    // Read and display anchor before import
    if (readAnchor(tsf_path)) |hdr| {
        if (std.mem.eql(u8, hdr.magic[0..], tsf.MAGIC) and hdr.version == tsf.VERSION) {
            std.debug.print("  anchor:\n", .{});
            snapshot_cmd.printAnchor(hdr);
        } else {
            std.debug.print("  warning: snapshot is not TSF2 format\n", .{});
        }
    } else |_| {}

    try snapshot_cmd.importSnapshot(alloc, tsf_path, lmdb_dir_opt, null, true, null, null, true);

    std.debug.print(
        \\
        \\Bootstrap complete!
        \\
        \\Next steps:
        \\  1. Start the node:
        \\       ./zig-out/bin/tsunagi-node run --net mainnet
        \\  2. Monitor LMDB truth ratio:
        \\       curl -s http://127.0.0.1:9080/metrics | grep tsunagi_lmdb
        \\  3. Re-export snapshot after accumulation:
        \\       ./zig-out/bin/tsunagi-node snapshot-export --out utxo-latest.tsf
        \\
    , .{});
}
