//! NET-RUNTIME AUDIT (net/mux + framing) — fragmented-stream reassembly for the
//! length-prefix framing path (net/mux.zig `Mux.recv`), 0.16.
//!
//! Companion to serve_loop_fragmented_read_tests.zig (which pins the Cardano mux
//! `mux_bearer.recvSegment` two-phase header+payload read). This file pins the
//! OTHER reassembly path in the subsystem: `Mux.recv`, which pulls at-most-256
//! bytes per `readAtMost`, accumulates them in a PERSISTENT `recv_buf`
//! (std.array_list), and decodes `[u32 len][payload]` frames from it via
//! framing.decode. Correctness hinges on (a) the underlying transport's
//! readAtMost preserving bytes across calls and (b) Mux.recv never losing the
//! surplus it buffered beyond a single decoded frame.
//!
//! AUDIT FINDING: no defect. All net/mux+framing socket reads use persistent
//! readers — tcp/unix StreamProtoReader (compat, connection-owned buffer),
//! propagation_server StreamBtImpl raw posix.read (kernel-buffered, never
//! over-reads), and http_metrics a single per-connection NetStream.Reader. No
//! fresh per-call NetStream.Reader.init appears in any hot read loop.
//!
//! These tests feed a length-prefixed message in 1-byte and odd split chunks
//! through the REAL Mux.recv and assert the full message reassembles with no
//! loss and the accumulator drains cleanly. A regression to a non-persistent
//! reader (dropping bytes buffered beyond one read) would surface as a frame
//! that never completes or decodes to garbage.
//!
//! Author: cryptoleo79.

const std = @import("std");

const ByteTransport = @import("net/transport/byte_transport.zig").ByteTransport;
const ByteTransportVTable = @import("net/transport/byte_transport.zig").ByteTransportVTable;
const Mux = @import("net/mux.zig").Mux;
const framing = @import("net/framing/length_prefix.zig");
const Message = @import("net/protocol/message.zig").Message;

/// Models a kernel socket receive buffer: bytes fed in accumulate; readAtMost
/// hands back at most `chunk` per call (never more than requested) and retains
/// the surplus for the next call — exactly read(2) semantics.
const FragmentingTransport = struct {
    data: []const u8,
    pos: usize = 0,
    chunk: usize,

    fn writeAll(_: *anyopaque, _: []const u8) anyerror!void {}

    fn readAtMost(ctx: *anyopaque, out: []u8) anyerror!usize {
        const self: *FragmentingTransport = @ptrCast(@alignCast(ctx));
        const available = self.data.len - self.pos;
        if (available == 0) return 0; // drained -> EOF
        const n = @min(@min(out.len, self.chunk), available);
        @memcpy(out[0..n], self.data[self.pos .. self.pos + n]);
        self.pos += n;
        return n;
    }

    fn deinit(_: *anyopaque) void {}

    const vtable = ByteTransportVTable{
        .writeAll = writeAll,
        .readAtMost = readAtMost,
        .deinit = deinit,
    };

    fn transport(self: *FragmentingTransport) ByteTransport {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

/// Drive Mux.recv until it produces a message or the stream is exhausted.
/// Returns the decoded message (or null if the frame never completed).
fn drainOneMessage(mux: *Mux, max_calls: usize) !?Message {
    var calls: usize = 0;
    while (calls < max_calls) : (calls += 1) {
        if (try mux.recv()) |m| return m;
    }
    return null;
}

test "Mux.recv reassembles a length-prefixed frame delivered 1 byte at a time" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Payload must be a codec-decodable tag (message_codec only knows the test
    // tag set); reassembly correctness is independent of payload content.
    const payload = "find_intersect";
    const frame = try framing.encode(alloc, payload); // [u32 len][payload]
    defer alloc.free(frame);

    var ft = FragmentingTransport{ .data = frame, .chunk = 1 };
    const bt = ft.transport();
    var mux = Mux.init(alloc, bt);
    defer mux.deinit();

    // Each recv() consumes at most 1 byte (chunk=1) and returns null until the
    // full 4-byte length prefix + payload have accumulated. Bound generously.
    const msg = try drainOneMessage(&mux, frame.len + 8);
    try std.testing.expect(msg != null);
    try std.testing.expectEqual(Message{ .chainsync = .find_intersect }, msg.?);
    // Single clean frame -> accumulator fully drained, no surplus retained.
    try std.testing.expectEqual(@as(usize, 0), mux.recv_buf.items.len);
    try std.testing.expectEqual(frame.len, ft.pos);
}

test "Mux.recv reassembles frames across odd split-chunk sizes straddling the length prefix" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const payload = "request_range";
    const frame = try framing.encode(alloc, payload);
    defer alloc.free(frame);

    // Chunks that land mid-prefix (1..3) and straddle the 4-byte header/payload
    // boundary (5,7) — a non-persistent reader would lose bytes at these splits.
    const chunks = [_]usize{ 1, 2, 3, 5, 7, 256 };
    for (chunks) |c| {
        var ft = FragmentingTransport{ .data = frame, .chunk = c };
        const bt = ft.transport();
        var mux = Mux.init(alloc, bt);
        defer mux.deinit();

        const msg = try drainOneMessage(&mux, frame.len + 8);
        try std.testing.expect(msg != null);
        try std.testing.expectEqual(Message{ .blockfetch = .request_range }, msg.?);
        try std.testing.expectEqual(@as(usize, 0), mux.recv_buf.items.len);
    }
}

test "Mux.recv reads two back-to-back frames from one 1-byte-fragmented stream without bleed" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Two length-prefixed frames concatenated; with chunk=1 the boundary is
    // invisible to the reader. Decoding frame #1 must leave frame #2 intact in
    // recv_buf and not over-consume into it.
    const f1 = try framing.encode(alloc, "find_intersect");
    defer alloc.free(f1);
    const f2 = try framing.encode(alloc, "request_next");
    defer alloc.free(f2);

    const combo = try alloc.alloc(u8, f1.len + f2.len);
    defer alloc.free(combo);
    @memcpy(combo[0..f1.len], f1);
    @memcpy(combo[f1.len..], f2);

    var ft = FragmentingTransport{ .data = combo, .chunk = 1 };
    const bt = ft.transport();
    var mux = Mux.init(alloc, bt);
    defer mux.deinit();

    const m1 = try drainOneMessage(&mux, combo.len + 8);
    try std.testing.expect(m1 != null);
    try std.testing.expectEqual(Message{ .chainsync = .find_intersect }, m1.?);

    const m2 = try drainOneMessage(&mux, combo.len + 8);
    try std.testing.expect(m2 != null);
    try std.testing.expectEqual(Message{ .chainsync = .request_next }, m2.?);

    // Both frames consumed; nothing left over, whole stream drained.
    try std.testing.expectEqual(@as(usize, 0), mux.recv_buf.items.len);
    try std.testing.expectEqual(combo.len, ft.pos);
}
