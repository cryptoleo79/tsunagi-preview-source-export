// Correlation exporter — joins CORRELATION + CORRELATION_RESULT log lines
// into JSONL outcome records.
//
// Usage:
//   tsunagi-node correlation-export [--input <file>] [--output <file>]
//
// Input default: $TSUNAGI_LOG_DIR/forge.log or stdin.
// Output default: stdout.
//
// Behavior:
//   - Read-only on the input file (never seeks; tolerant to incomplete tails).
//   - Memory-bounded: matches by slot using a fixed-size ring of pending
//     CORRELATION events; if a slot's CORRELATION_RESULT never arrives the
//     event is dropped from the ring after PENDING_CAPACITY new events.
//   - Output one JSON object per resolved slot:
//       {"slot":N,"llr":X,"ev":Y,"kelly":Z,"posterior":P,"accepted":0|1}
//   - Emits a final summary line "{"total":N,"accepted":N,"missed":N}" to stderr.
//
// Constraints:
//   - No new dependencies.
//   - No forge path changes.
//   - Safe to run while the node is forging.

const std = @import("std");
const compat = @import("compat");

const PENDING_CAPACITY: usize = 256;

const PendingEntry = struct {
    slot: u64 = 0,
    llr: i64 = 0,
    ev: i64 = 0,
    kelly: i64 = 0,
    posterior: u64 = 0,
    used: bool = false,
};

const Ring = struct {
    entries: [PENDING_CAPACITY]PendingEntry = [_]PendingEntry{.{}} ** PENDING_CAPACITY,
    head: usize = 0,

    fn record(self: *Ring, e: PendingEntry) void {
        // Skip dup if the slot is already present and unresolved.
        for (&self.entries) |*existing| {
            if (existing.used and existing.slot == e.slot) {
                existing.* = e; // overwrite (latest decision snapshot wins)
                existing.used = true;
                return;
            }
        }
        self.entries[self.head] = e;
        self.entries[self.head].used = true;
        self.head = (self.head + 1) % PENDING_CAPACITY;
    }

    fn take(self: *Ring, slot: u64) ?PendingEntry {
        for (&self.entries) |*e| {
            if (e.used and e.slot == slot) {
                const out = e.*;
                e.used = false;
                return out;
            }
        }
        return null;
    }
};

/// Parse a "key=N" pair where N is i64. Returns null if the key is absent.
fn parseI64Field(line: []const u8, key: []const u8) ?i64 {
    const idx = std.mem.indexOf(u8, line, key) orelse return null;
    var i = idx + key.len;
    if (i >= line.len) return null;
    var negative = false;
    if (line[i] == '-') {
        negative = true;
        i += 1;
    }
    var j = i;
    while (j < line.len and line[j] >= '0' and line[j] <= '9') : (j += 1) {}
    if (j == i) return null;
    const v = std.fmt.parseInt(i64, line[i..j], 10) catch return null;
    return if (negative) -v else v;
}

fn parseU64Field(line: []const u8, key: []const u8) ?u64 {
    const v = parseI64Field(line, key) orelse return null;
    if (v < 0) return null;
    return @intCast(v);
}

const Stats = struct {
    total: u64 = 0,
    accepted: u64 = 0,
    missed: u64 = 0,
};

fn processLine(
    line: []const u8,
    ring: *Ring,
    out_writer: anytype,
    stats: *Stats,
) !void {
    // CORRELATION (decision snapshot at forge time)
    if (std.mem.indexOf(u8, line, "CORRELATION:") != null and
        std.mem.indexOf(u8, line, "CORRELATION_RESULT:") == null)
    {
        const slot = parseU64Field(line, "slot=") orelse return;
        const llr = parseI64Field(line, " llr=") orelse 0;
        const ev = parseI64Field(line, " ev=") orelse 0;
        const kelly = parseI64Field(line, " kelly=") orelse 0;
        const posterior = parseU64Field(line, " posterior=") orelse 0;
        ring.record(.{
            .slot = slot,
            .llr = llr,
            .ev = ev,
            .kelly = kelly,
            .posterior = posterior,
            .used = true,
        });
        return;
    }
    // CORRELATION_RESULT (outcome resolution)
    if (std.mem.indexOf(u8, line, "CORRELATION_RESULT:") != null) {
        const slot = parseU64Field(line, "slot=") orelse return;
        const accepted = parseU64Field(line, " accepted=") orelse return;
        const e = ring.take(slot) orelse {
            // Result without a matching decision snapshot — emit with zeros.
            try out_writer.print(
                "{{\"slot\":{d},\"llr\":0,\"ev\":0,\"kelly\":0,\"posterior\":0,\"accepted\":{d}}}\n",
                .{ slot, accepted },
            );
            stats.total += 1;
            if (accepted == 1) stats.accepted += 1 else stats.missed += 1;
            return;
        };
        try out_writer.print(
            "{{\"slot\":{d},\"llr\":{d},\"ev\":{d},\"kelly\":{d},\"posterior\":{d},\"accepted\":{d}}}\n",
            .{ e.slot, e.llr, e.ev, e.kelly, e.posterior, accepted },
        );
        stats.total += 1;
        if (accepted == 1) stats.accepted += 1 else stats.missed += 1;
    }
}

pub fn run(alloc: std.mem.Allocator, args_it: anytype) !void {
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--input")) {
            input_path = args_it.next() orelse return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--output")) {
            output_path = args_it.next() orelse return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            return;
        }
    }

    // Open input. When reading a regular file we use its (positional) reader;
    // when reading stdin we MUST use the persistent stdin reader, because the
    // per-call streaming File reader over-reads each line into a throwaway
    // buffer and loses every byte past the first kernel read (dropping nearly
    // all piped input).
    var input_file: compat.fs.File = if (input_path) |p|
        try compat.fs.cwd().openFile(p, .{})
    else
        compat.fs.File.stdin();
    defer if (input_path != null) input_file.close();

    // Open output
    var output_file: compat.fs.File = if (output_path) |p|
        try compat.fs.cwd().createFile(p, .{ .truncate = true })
    else
        compat.fs.File.stdout();
    defer if (output_path != null) output_file.close();

    const out_writer = output_file.deprecatedWriter();

    var ring = Ring{};
    var stats = Stats{};
    var line_buf: [4096]u8 = undefined;

    if (input_path == null) {
        // stdin: persistent reader (over-read-safe across lines).
        const stdin = compat.fs.persistentStdin();
        while (true) {
            const line = stdin.readUntilDelimiterOrEof(&line_buf, '\n') catch |err| switch (err) {
                error.StreamTooLong => continue, // skip overlong lines
                else => break,
            };
            if (line == null) break;
            try processLine(line.?, &ring, out_writer, &stats);
        }
    } else {
        const reader = input_file.deprecatedReader();
        while (true) {
            const line = reader.readUntilDelimiterOrEof(&line_buf, '\n') catch |err| switch (err) {
                error.StreamTooLong => continue, // skip overlong lines
                else => break,
            };
            if (line == null) break;
            try processLine(line.?, &ring, out_writer, &stats);
        }
    }

    const stderr = compat.fs.stderrWriter();
    try stderr.print("{{\"total\":{d},\"accepted\":{d},\"missed\":{d}}}\n", .{
        stats.total, stats.accepted, stats.missed,
    });
    _ = alloc;
}

fn printHelp() !void {
    const stderr = compat.fs.stderrWriter();
    try stderr.writeAll(
        \\tsunagi-node correlation-export — join CORRELATION + CORRELATION_RESULT into JSONL
        \\
        \\Usage: tsunagi-node correlation-export [--input PATH] [--output PATH]
        \\
        \\Reads stdin (or --input file) for CORRELATION / CORRELATION_RESULT log
        \\lines. Pairs them by slot and writes one JSON record per resolved slot.
        \\Output goes to stdout (or --output file). Final summary on stderr.
        \\
        \\Output format (JSONL):
        \\  {"slot":N,"llr":X,"ev":Y,"kelly":Z,"posterior":P,"accepted":0|1}
        \\
    );
}

// ── Tests ──

test "parseI64Field handles positive and negative" {
    try std.testing.expectEqual(@as(?i64, 42), parseI64Field("foo=42 bar", "foo="));
    try std.testing.expectEqual(@as(?i64, -7), parseI64Field("ev=-7 ", "ev="));
    try std.testing.expectEqual(@as(?i64, null), parseI64Field("foo bar", "x="));
}

test "Ring records and takes a single slot" {
    var ring = Ring{};
    ring.record(.{ .slot = 100, .llr = 42, .used = true });
    const e = ring.take(100);
    try std.testing.expect(e != null);
    try std.testing.expectEqual(@as(i64, 42), e.?.llr);
    try std.testing.expectEqual(@as(?PendingEntry, null), ring.take(100)); // already taken
}

test "processLine matches CORRELATION + CORRELATION_RESULT" {
    var ring = Ring{};
    var stats = Stats{};
    var buf: [512]u8 = undefined;
    var fbs = compat.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try processLine(
        "2026-04-25T01:00:00 CORRELATION: slot=110 llr=500 ev=300 kelly=200 posterior=750",
        &ring,
        writer,
        &stats,
    );
    try std.testing.expectEqual(@as(u64, 0), stats.total); // not yet resolved

    try processLine(
        "2026-04-25T01:01:00 CORRELATION_RESULT: slot=110 llr=500 ev=300 kelly=200 posterior=750 accepted=1",
        &ring,
        writer,
        &stats,
    );
    try std.testing.expectEqual(@as(u64, 1), stats.total);
    try std.testing.expectEqual(@as(u64, 1), stats.accepted);
    const out = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"slot\":110") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"accepted\":1") != null);
}

test "processLine handles result without prior CORRELATION" {
    var ring = Ring{};
    var stats = Stats{};
    var buf: [512]u8 = undefined;
    var fbs = compat.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try processLine(
        "CORRELATION_RESULT: slot=200 accepted=0",
        &ring,
        writer,
        &stats,
    );
    try std.testing.expectEqual(@as(u64, 1), stats.total);
    try std.testing.expectEqual(@as(u64, 1), stats.missed);
    const out = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"llr\":0") != null);
}
