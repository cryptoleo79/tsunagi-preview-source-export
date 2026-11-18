const std = @import("std");

var g_seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn notify() void {
    _ = g_seq.fetchAdd(1, .release);
}

pub fn loadSeq() u64 {
    return g_seq.load(.acquire);
}
