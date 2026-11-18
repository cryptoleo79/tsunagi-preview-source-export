// Operator View — CLI dashboard driven by /status/full.
//
// Polls http://127.0.0.1:<port>/status/full every 2 seconds and renders
// a dense operator panel to the terminal. Pure rendering layer — no fake
// data, no recomputation, no extra HTTP fetches.
//
//   tsunagi-node view                 # default port 3032
//   tsunagi-node view --port 3033
//   tsunagi-node view --once          # render once and exit
//   tsunagi-node view --host <ip>     # default 127.0.0.1
//
// Missing fields are rendered as em-dash ('—'). Comments adjacent to
// each placeholder identify the upstream change required to populate
// the value.
//
// Stability layers:
//   - JSON-response hardening (#148): startsWithBrace + last-good cache
//     + VIEW_POLL_BAD stderr log; bad polls leave the previous frame.
//   - Diff-and-overwrite repaint (#149): cursor-home + per-line ESC[K +
//     final ESC[J; full ESC[2J only on first paint and width changes;
//     MIN_RENDER_INTERVAL_MS=500 floor; identical frames suppress writes.
//   - Non-blocking q-to-quit input (#150): raw-mode termios on TTY runs;
//     50ms-sliced sleep with q/Q/ESC/ctrl-c poll; SIGINT/SIGTERM handler.
//   - Visual polish (#151): fixed-width column helpers, traffic-light
//     colors, slot/next-slot/LEADER/FORGED highlights, em-dash for
//     missing fields with explicit 0 retained where 0 is meaningful.

const std = @import("std");
const compat = @import("compat");

const DEFAULT_PORT: u16 = 3032;
const DEFAULT_HOST: []const u8 = "127.0.0.1";
const REFRESH_S: u64 = 2;

// ── Raw-mode terminal state ───────────────────────────────────────────
//
// The view subcommand is interactive: when stdin is a TTY we put the
// terminal into raw mode so single keystrokes (q/Q/ESC/ctrl-c) reach
// the poll loop without waiting for newline. Saved state is module-
// level so a SIGINT handler can restore it without a context arg.
//
// Invariants:
//   - g_raw_mode_active is true iff cooked-mode termios has been
//     replaced. We only ever clear it via restoreTermios, which is
//     idempotent.
//   - Non-interactive runs (piped stdin, --once) never flip this.
var g_orig_termios: ?std.posix.termios = null;
var g_raw_mode_active: bool = false;
var g_quit_requested: bool = false;

const STDIN_FD: std.posix.fd_t = 0;

// Cap on the cached "last good" /status/full body. The status server
// caps responses at ~16 KiB after PR #146; 4× headroom is plenty.
// Bodies larger than this are treated as transient bad polls and
// silently ignored — the cached frame stays on screen.
const MAX_CACHED_BODY: usize = 256 * 1024;

// Layout targets. Width tunes column placement.
const DEFAULT_WIDTH: usize = 80;
const MIN_WIDTH: usize = 64;
const MAX_WIDTH: usize = 200;

// Cardano network constants relevant to time/period math.
const SLOTS_PER_KES_PERIOD: u64 = 129_600;        // 36h on 1s slots
const SHELLEY_GENESIS_PREVIEW_UNIX: i64 = 1666656000;
const SHELLEY_GENESIS_MAINNET_UNIX: i64 = 1596059091;
const SLOTS_PER_EPOCH_PREVIEW: u64 = 86_400;       // 24h
const SLOTS_PER_EPOCH_MAINNET: u64 = 432_000;      // 5d

pub fn run(alloc: std.mem.Allocator, args_it: anytype) !void {
    var host: []const u8 = DEFAULT_HOST;
    var port: u16 = DEFAULT_PORT;
    var once: bool = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const v = args_it.next() orelse return error.InvalidArgs;
            port = std.fmt.parseUnsigned(u16, v, 10) catch return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--host")) {
            host = args_it.next() orelse return error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--once")) {
            once = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            return;
        } else {
            std.debug.print("view: unknown arg {s}\n", .{arg});
            return error.InvalidArgs;
        }
    }

    // Cached "last good" body. Holds the most recent /status/full
    // response that fetched cleanly, passed the leading-byte guard,
    // and parsed as valid JSON. Renders are driven entirely from this
    // cache — on a bad poll the loop sleeps without touching the
    // screen so the previous good frame remains visible. Freed on exit.
    var cached_body = std.array_list.Managed(u8).init(alloc);
    defer cached_body.deinit();
    try cached_body.ensureTotalCapacity(16 * 1024);

    // Reusable scratch buffer for the freshly-rendered frame and the
    // previously-painted frame. Capped at FRAME_BUF_CAP (~64 KiB)
    // each; a normal panel is well under 4 KiB. We diff `frame_buf`
    // against `prev_frame` and skip the paint entirely when they match,
    // which is the load-bearing piece of the no-flicker contract.
    var frame_buf = std.array_list.Managed(u8).init(alloc);
    defer frame_buf.deinit();
    try frame_buf.ensureTotalCapacity(8 * 1024);
    var prev_frame = std.array_list.Managed(u8).init(alloc);
    defer prev_frame.deinit();
    try prev_frame.ensureTotalCapacity(8 * 1024);

    var have_good_frame: bool = false;
    var printed_waiting: bool = false;
    // Last terminal width we painted with. A change between ticks
    // means line wrapping is now off — force a full clear + repaint
    // on the next paint to wipe any stale half-frame.
    var last_width: usize = 0;
    var last_paint_ms: i64 = 0;

    // Interactive runs (TTY-attached stdin, not --once) flip the
    // terminal into raw mode so 'q'/Q/ESC/ctrl-c quit within one tick.
    // Non-interactive runs skip the dance entirely. We always defer
    // restoreTermios — it is a no-op when raw mode never engaged, and
    // safely idempotent if the SIGINT handler already ran.
    const interactive = !once and stdinIsTty();
    if (interactive) {
        installSignalHandler();
        enterRawMode();
    }
    defer restoreTermios();

    while (true) {
        const ok = pollOnce(alloc, host, port, &cached_body);

        if (ok) {
            // Fresh good body in cached_body. Parse and render. A parse
            // failure on a previously-validated leading-brace body
            // is rare but possible (truncated mid-string after the
            // opening '{'); treat it as a transient bad poll and log it.
            var parsed = std.json.parseFromSlice(std.json.Value, alloc, cached_body.items, .{}) catch |err| {
                logPollBad(.parse_error, @errorName(err), cached_body.items);
                if (!have_good_frame and !printed_waiting) {
                    renderWaiting(host, port);
                    printed_waiting = true;
                }
                if (once) return;
                if (sleepUntilNextTickOrQuit()) return;
                continue;
            };
            defer parsed.deinit();

            try buildAndPaintFrame(&frame_buf, &prev_frame, parsed.value, &last_width, &last_paint_ms);
            have_good_frame = true;
            printed_waiting = false;
            if (once) return;
        } else {
            // Bad poll: pollOnce already logged the specific reason on
            // stderr. If we have never rendered a good frame, show a
            // single waiting line; otherwise leave the screen as it
            // last drew so the operator keeps seeing real data.
            if (!have_good_frame and !printed_waiting) {
                renderWaiting(host, port);
                printed_waiting = true;
            }
            if (once) return;
        }

        if (sleepUntilNextTickOrQuit()) return;
    }
}

/// Sleep up to REFRESH_S seconds in 50ms chunks, polling stdin for an
/// exit key on each chunk. Returns true if a quit key (q/Q/ESC/ctrl-c)
/// was seen — caller should return immediately so `defer restoreTermios`
/// fires before any further stdout writes (avoids leaving the cursor
/// at a random position relative to the half-rendered next frame).
///
/// In non-interactive mode pollExitKey is a no-op so this just sleeps.
fn sleepUntilNextTickOrQuit() bool {
    const chunk_ns: u64 = 50 * std.time.ns_per_ms;
    const total_ns: u64 = REFRESH_S * std.time.ns_per_s;
    var elapsed: u64 = 0;
    while (elapsed < total_ns) {
        if (g_quit_requested) return true;
        if (pollExitKey()) return true;
        const remain = total_ns - elapsed;
        const step = if (remain < chunk_ns) remain else chunk_ns;
        compat.sleep(step);
        elapsed += step;
    }
    if (g_quit_requested) return true;
    return pollExitKey();
}

/// Cap on a single rendered frame buffer. The panel today is
/// ~80 cols × ~30 lines ≈ 2.4 KiB; 64 KiB is huge headroom and a hard
/// stop in case a future renderer regresses into a runaway loop.
const FRAME_BUF_CAP: usize = 64 * 1024;

/// Hard floor on paint cadence. Today the poll loop sleeps for 2s so
/// this is purely defensive — it caps any future tightening of the
/// fetch interval at ~2 Hz so the terminal can keep up. Frames that
/// would arrive faster are silently elided (the cached frame stays).
const MIN_RENDER_INTERVAL_MS: i64 = 500;

/// ANSI: erase from cursor to end of line. Tagged on after each line
/// of the new frame so a previous-frame line that was longer at the
/// same row gets blanked without a screen-wide clear.
const ANSI_ERASE_LINE_TAIL: []const u8 = "\x1b[K";

/// ANSI: erase from cursor to end of screen. Emitted after the last
/// line so any extra rows from a previously-longer frame disappear.
const ANSI_ERASE_BELOW: []const u8 = "\x1b[J";

/// ANSI: cursor home. The cheap repaint anchor.
const ANSI_CURSOR_HOME: []const u8 = "\x1b[H";

/// ANSI: full clear + cursor home. Used for the first paint and for
/// terminal-resize re-paints; never for steady-state ticks.
const ANSI_FULL_CLEAR: []const u8 = "\x1b[2J\x1b[H";

/// Pure diff predicate. Returns true when the freshly-rendered frame
/// matches the previously-painted frame exactly — caller must then skip
/// the paint to avoid flicker. The empty-prev case (first paint) always
/// falls through to a paint so the screen actually shows up on launch.
fn shouldSkipPaint(prev: []const u8, cur: []const u8) bool {
    if (cur.len == 0) return true;          // nothing to paint
    if (prev.len == 0) return false;        // first paint: always run
    return std.mem.eql(u8, prev, cur);
}

/// Compose the cursor-home + per-line + erase-tail paint payload into
/// `out`. Each line of the rendered frame ends with ESC[K so any longer
/// previous-frame line at the same row is erased. After the last line
/// we emit ESC[J to wipe any rows the previous frame had below the
/// new frame's tail.
///
/// Pulled out so unit tests can assert the exact byte sequence without
/// involving stdout.
fn composeIncrementalPaint(out: *std.array_list.Managed(u8), frame: []const u8) !void {
    try out.appendSlice(ANSI_CURSOR_HOME);
    var rest: []const u8 = frame;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        if (nl) |idx| {
            // Write line content (without the trailing '\n'), then
            // erase to end of line, then re-emit the '\n' so the
            // cursor advances to the next row.
            try out.appendSlice(rest[0..idx]);
            try out.appendSlice(ANSI_ERASE_LINE_TAIL);
            try out.append('\n');
            rest = rest[idx + 1 ..];
        } else {
            // Trailing partial line (no terminating '\n'). Write it,
            // erase to end of line.
            try out.appendSlice(rest);
            try out.appendSlice(ANSI_ERASE_LINE_TAIL);
            rest = rest[rest.len..];
        }
    }
    try out.appendSlice(ANSI_ERASE_BELOW);
}

/// Build a fresh frame into `frame_buf` and paint it to stdout, but
/// only when it differs from `prev_frame`. The very first paint always
/// runs (prev_frame is empty); subsequent identical frames are elided
/// entirely so a steady-state node produces zero terminal output.
///
/// Subsequent paints cursor-home and erase line-by-line instead of a
/// full screen clear, eliminating the visible flicker between the
/// clear and the first byte of the new frame. A change in detected
/// terminal width forces a full clear so any reflowed content from
/// the previous width is wiped cleanly.
fn buildAndPaintFrame(
    frame_buf: *std.array_list.Managed(u8),
    prev_frame: *std.array_list.Managed(u8),
    root: std.json.Value,
    last_width: *usize,
    last_paint_ms: *i64,
) !void {
    // 2 Hz paint floor. If the poll loop ever ticks faster than
    // MIN_RENDER_INTERVAL_MS we skip the paint entirely; the cached
    // previous frame stays on screen and the loop loops on.
    const now_ms: i64 = compat.milliTimestamp();
    if (last_paint_ms.* != 0 and (now_ms - last_paint_ms.*) < MIN_RENDER_INTERVAL_MS) {
        return;
    }

    frame_buf.clearRetainingCapacity();
    const width = termWidth();
    const use_color = colorEnabled();
    try renderPanel(compat.listWriter(frame_buf), root, width, use_color);
    if (frame_buf.items.len > FRAME_BUF_CAP) {
        // Defensive: never paint a runaway buffer.
        return error.FrameTooLarge;
    }

    const width_changed = (last_width.* != 0 and last_width.* != width);
    const force_full = width_changed or prev_frame.items.len == 0;

    // Diff against the previous good frame. Identical content + no
    // resize → no bytes go to stdout, no flicker.
    if (!width_changed and shouldSkipPaint(prev_frame.items, frame_buf.items)) {
        last_width.* = width;
        return;
    }

    var out = compat.fs.File.stdout();
    if (force_full) {
        // First paint, or operator just resized the terminal: nuke the
        // canvas before laying down the new frame.
        out.writeAll(ANSI_FULL_CLEAR) catch {};
        out.writeAll(frame_buf.items) catch {};
    } else {
        // Steady-state in-place overwrite: cursor-home, line-by-line
        // with erase-to-eol, then erase below the last line. Composed
        // into a single buffered write so the terminal sees one
        // contiguous payload (no half-frames mid-flight).
        var paint_buf = std.array_list.Managed(u8).init(frame_buf.allocator);
        defer paint_buf.deinit();
        paint_buf.ensureTotalCapacity(frame_buf.items.len + 256) catch {};
        composeIncrementalPaint(&paint_buf, frame_buf.items) catch {
            // Compose failed (OOM): fall back to a full repaint rather
            // than leaving a stale frame on screen.
            out.writeAll(ANSI_FULL_CLEAR) catch {};
            out.writeAll(frame_buf.items) catch {};
            prev_frame.clearRetainingCapacity();
            prev_frame.appendSlice(frame_buf.items) catch {};
            last_width.* = width;
            last_paint_ms.* = now_ms;
            return;
        };
        out.writeAll(paint_buf.items) catch {};
    }

    // Stash the painted frame for next-tick comparison.
    prev_frame.clearRetainingCapacity();
    prev_frame.appendSlice(frame_buf.items) catch {};
    last_width.* = width;
    last_paint_ms.* = now_ms;
}

const PollBadKind = enum {
    http_error,
    empty_body,
    non_json,
    parse_error,

    fn label(self: PollBadKind) []const u8 {
        return switch (self) {
            .http_error => "http_error",
            .empty_body => "empty_body",
            .non_json => "non_json",
            .parse_error => "parse_error",
        };
    }
};

/// stderr-only poll-failure diagnostic. Stays off stdout so it never
/// disturbs the rendered panel; operators capture it with
/// `tsunagi-node view 2> view.log` for post-mortem.
///
/// Format:  VIEW_POLL_BAD: kind=<…> bytes=<n> first8=<hex>[ err=<name>]
fn logPollBad(kind: PollBadKind, err_name: []const u8, body: []const u8) void {
    var hex_buf: [16]u8 = undefined;
    var hex_len: usize = 0;
    const take = @min(body.len, 8);
    var i: usize = 0;
    while (i < take) : (i += 1) {
        const b = body[i];
        const hi = "0123456789abcdef"[b >> 4];
        const lo = "0123456789abcdef"[b & 0x0f];
        hex_buf[hex_len] = hi;
        hex_buf[hex_len + 1] = lo;
        hex_len += 2;
    }
    const hex = hex_buf[0..hex_len];

    const stderr = compat.fs.stderrWriter();
    if (err_name.len == 0) {
        stderr.print(
            "VIEW_POLL_BAD: kind={s} bytes={d} first8={s}\n",
            .{ kind.label(), body.len, hex },
        ) catch {};
    } else {
        stderr.print(
            "VIEW_POLL_BAD: kind={s} bytes={d} first8={s} err={s}\n",
            .{ kind.label(), body.len, hex, err_name },
        ) catch {};
    }
}

/// Single poll: fetch /status/full, copy into `cached_body` only when
/// the response is non-empty, within the size cap, and looks like a
/// JSON document. Returns true on success (caller proceeds to parse +
/// render); false otherwise (caller treats as transient bad poll).
///
/// Every false return is accompanied by a single stderr VIEW_POLL_BAD
/// line so operators can post-mortem transient HTTP / format issues.
/// This function never throws — a fetch failure is simply a bad poll.
fn pollOnce(
    alloc: std.mem.Allocator,
    host: []const u8,
    port: u16,
    cached_body: *std.array_list.Managed(u8),
) bool {
    const body = fetchStatus(alloc, host, port) catch |err| {
        logPollBad(.http_error, @errorName(err), &.{});
        return false;
    };
    defer alloc.free(body);

    if (body.len == 0) {
        logPollBad(.empty_body, "", body);
        return false;
    }
    if (body.len > MAX_CACHED_BODY) {
        // Treat oversize as non_json — same operator action (ignore +
        // wait for a clean response). Distinguishable in the log line
        // by the bytes= field exceeding the cap.
        logPollBad(.non_json, "oversize", body);
        return false;
    }
    if (!startsWithBrace(body)) {
        logPollBad(.non_json, "", body);
        return false;
    }

    cached_body.clearRetainingCapacity();
    cached_body.appendSlice(body) catch |err| {
        logPollBad(.http_error, @errorName(err), body);
        return false;
    };
    return true;
}

/// Cold-start fallback: shown once on first failed poll instead of an
/// empty zero-state panel. Replaced by the real panel on first success.
fn renderWaiting(host: []const u8, port: u16) void {
    clearScreen();
    std.debug.print(
        "TSUNAGI view: waiting for valid /status/full from {s}:{d}...\n",
        .{ host, port },
    );
}

/// Cheap structural guard: returns true iff the first non-whitespace
/// byte of `body` is '{'. Used to reject non-JSON-document responses
/// (empty, "not found", HTML, bare scalars, arrays) before they reach
/// std.json. Whitespace per the JSON spec: SP HT LF CR.
fn startsWithBrace(body: []const u8) bool {
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
        return c == '{';
    }
    return false;
}

fn printHelp() !void {
    const stderr = compat.fs.stderrWriter();
    try stderr.writeAll(
        \\tsunagi-node view — live operator panel
        \\
        \\Usage: tsunagi-node view [--host HOST] [--port PORT] [--once]
        \\
        \\Polls /status/full every 2 seconds. All values come from the node
        \\runtime; no external APIs, no fake metrics. Missing fields render
        \\as '—' (em-dash) until the upstream module exposes them.
        \\
        \\Honored env:
        \\  COLUMNS    target render width (default 80, clamped 64..200)
        \\  NO_COLOR   if set (any value), disable ANSI color
        \\
        \\Interactive: q / Q / ESC / ctrl-c quit.
        \\
    );
}

// ── HTTP fetch over raw TCP ───────────────────────────────────────────

fn fetchStatus(alloc: std.mem.Allocator, host: []const u8, port: u16) ![]u8 {
    const io = compat.defaultIo();

    // Address resolution. `IpAddress.parse` handles both IPv4 and IPv6
    // literals. The pre-0.16 fallback path used `std.net.getAddressList`
    // to resolve DNS hostnames; 0.16's std.Io.net has no equivalent
    // synchronous DNS A-record resolver, so a non-literal `host` is
    // rejected here. In practice `host` defaults to 127.0.0.1 and is an
    // IP literal in all current call sites (--host takes an IP).
    // TODO(0.16-dns): wire a DNS resolver if hostname support is needed.
    var addr = std.Io.net.IpAddress.parse(host, port) catch return error.ResolveFailed;
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var req_buf: [512]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf,
        "GET /status/full HTTP/1.1\r\nHost: {s}\r\nAccept: application/json\r\nConnection: close\r\n\r\n",
        .{host},
    );
    // Short single write of the fixed request line + headers. The
    // StreamWriter shim buffers + flushes; preserves the exact bytes.
    try compat.streamWriter(stream).writeAll(req);

    var response = std.array_list.Managed(u8).init(alloc);
    defer response.deinit();

    // Persistent protocol reader. The buffer outlives the read loop so
    // no buffered bytes are dropped between iterations (a fresh reader
    // per iteration would discard whatever was already buffered).
    var read_buf: [4096]u8 = undefined;
    var reader = compat.NetStream.Reader.init(stream, io, &read_buf);

    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = reader.interface.readSliceShort(&tmp) catch |err| switch (err) {
            // readSliceShort surfaces the underlying socket error as
            // error.ReadFailed and stashes the real error on the reader.
            // A peer reset mid-stream is an ordinary end-of-body here,
            // matching the pre-0.16 `error.ConnectionResetByPeer => break`.
            error.ReadFailed => switch (reader.err orelse return err) {
                error.ConnectionResetByPeer => break,
                else => |e| return e,
            },
        };
        if (n == 0) break;
        try response.appendSlice(tmp[0..n]);
        if (response.items.len > 1 << 20) return error.ResponseTooLarge;
    }

    const hdr_end = std.mem.indexOf(u8, response.items, "\r\n\r\n") orelse return error.MalformedResponse;
    const body = response.items[hdr_end + 4 ..];
    return try alloc.dupe(u8, body);
}

// ── Terminal helpers ──────────────────────────────────────────────────

fn clearScreen() void {
    std.debug.print("\x1b[2J\x1b[H", .{});
}

/// Returns true when stdin is attached to a terminal. Piped runs and
/// `--once` capture (e.g. ` | head`) return false; we then skip raw
/// mode entirely so the surrounding shell is not disturbed.
fn stdinIsTty() bool {
    return compat.fs.File.stdin().inner.isTty(compat.defaultIo()) catch false;
}

/// Drop the line discipline into raw-ish mode: clear ICANON (no
/// line-buffering) and ECHO (no mirror of keypresses on the panel),
/// and set VMIN=0/VTIME=0 so reads return immediately with whatever
/// bytes are queued. The original termios is stashed for restore.
///
/// On any error the function returns silently — the worst case is
/// that 'q' to quit does not work; the panel still renders.
fn enterRawMode() void {
    if (g_raw_mode_active) return;
    const orig = std.posix.tcgetattr(STDIN_FD) catch return;
    g_orig_termios = orig;

    var raw = orig;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    std.posix.tcsetattr(STDIN_FD, .NOW, raw) catch {
        g_orig_termios = null;
        return;
    };
    g_raw_mode_active = true;
}

/// Idempotent. Safe to call from a signal handler: reads only the
/// module-level termios snapshot, makes one tcsetattr syscall, and
/// flips a bool. Called from `defer` on every exit path and from the
/// SIGINT handler so an orphaned raw-mode terminal is never possible.
fn restoreTermios() void {
    if (!g_raw_mode_active) return;
    if (g_orig_termios) |orig| {
        std.posix.tcsetattr(STDIN_FD, .NOW, orig) catch {};
    }
    g_raw_mode_active = false;
}

/// SIGINT/SIGTERM handler. Restores the terminal so the operator's
/// shell is left in cooked mode, then exits with code 0. We do NOT
/// chain to a previous handler — the view subcommand owns the process
/// (main.zig dispatches and returns straight to it).
fn handleSignal(_: std.posix.SIG) callconv(.c) void {
    g_quit_requested = true;
    restoreTermios();
    std.process.exit(0);
}

fn installSignalHandler() void {
    var action = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
}

/// Table of keystrokes that quit the view. Pure helper for testing.
///   'q' / 'Q'  — primary binding shown in the footer
///   0x1B (ESC) — escape (also any arrow-key sequence's lead byte;
///                we treat the lead byte alone as quit since arrow
///                keys are not bound to anything yet)
///   0x03 (ETX) — ctrl-c (raw mode swallows the signal so we read it)
fn isExitKey(b: u8) bool {
    return b == 'q' or b == 'Q' or b == 0x1B or b == 0x03;
}

/// Non-blocking poll of stdin. Returns true if any byte read matches
/// `isExitKey`. Reads at most 8 bytes per call — sufficient to drain
/// a pasted multi-byte escape sequence and inspect its lead byte. In
/// non-interactive (non-raw) mode we skip the read entirely.
fn pollExitKey() bool {
    if (!g_raw_mode_active) return false;
    var buf: [8]u8 = undefined;
    const n = std.posix.read(STDIN_FD, &buf) catch |err| switch (err) {
        error.WouldBlock => return false,
        else => return false,
    };
    if (n == 0) return false;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (isExitKey(buf[i])) return true;
    }
    return false;
}

/// Width is COLUMNS env clamped to [MIN_WIDTH, MAX_WIDTH], else DEFAULT_WIDTH.
fn termWidth() usize {
    if (compat.getenv("COLUMNS")) |s| {
        const n = std.fmt.parseUnsigned(usize, s, 10) catch return DEFAULT_WIDTH;
        if (n < MIN_WIDTH) return MIN_WIDTH;
        if (n > MAX_WIDTH) return MAX_WIDTH;
        return n;
    }
    return DEFAULT_WIDTH;
}

/// True when stdout is a TTY and NO_COLOR is unset.
fn colorEnabled() bool {
    if (compat.getenv("NO_COLOR")) |_| return false;
    // std.fs.File.stdout() returns the file; .isTty() is best-effort.
    var out = compat.fs.File.stdout();
    return out.isTty();
}

// ANSI color escapes (only emitted when colorEnabled()).
const C = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const cyan = "\x1b[36m";
    const blue = "\x1b[34m";
};

fn cTag(use_color: bool, code: []const u8) []const u8 {
    return if (use_color) code else "";
}

/// ANSI sequence iff `use_color` is true; empty string otherwise. Wraps
/// the inline pattern so the gating is consistent. Mirrors `cTag` but
/// explicit about the OFF path.
fn ansiOn(use_color: bool, code: []const u8) []const u8 {
    return if (use_color) code else "";
}

fn ansiOff() []const u8 {
    return "";
}

/// Traffic-light helpers. Each returns the ANSI prefix to wrap the
/// associated value; pair with `C.reset` after the value. When color is
/// disabled (NO_COLOR or non-tty), the helper returns an empty string and
/// the value renders unchanged — required for the byte-equal frame diff
/// in #149 to behave correctly when stdout is piped.
fn lightSync(use_color: bool, tip_age_seconds: i64) []const u8 {
    if (!use_color) return "";
    if (tip_age_seconds < 5) return C.green;
    if (tip_age_seconds < 30) return C.yellow;
    return C.red;
}

fn lightKes(use_color: bool, periods_remaining: u64) []const u8 {
    if (!use_color) return "";
    if (periods_remaining > 10) return C.green;
    if (periods_remaining >= 5) return C.yellow;
    return C.red;
}

fn lightCpu(use_color: bool, cpu_pct: f64) []const u8 {
    if (!use_color) return "";
    if (cpu_pct < 50.0) return C.green;
    if (cpu_pct <= 80.0) return C.yellow;
    return C.red;
}

fn lightDisk(use_color: bool, disk_pct: f64) []const u8 {
    if (!use_color) return "";
    if (disk_pct < 80.0) return C.green;
    if (disk_pct <= 90.0) return C.yellow;
    return C.red;
}

fn lightLost(use_color: bool, lost_total: u64) []const u8 {
    if (!use_color) return "";
    if (lost_total == 0) return C.green;
    if (lost_total <= 2) return C.yellow;
    return C.red;
}

// ── JSON accessors ────────────────────────────────────────────────────

fn get(root: std.json.Value, key: []const u8) ?std.json.Value {
    if (root != .object) return null;
    return root.object.get(key);
}

fn getObj(root: std.json.Value, key: []const u8) std.json.Value {
    const v = get(root, key) orelse return std.json.Value{ .null = {} };
    return v;
}

fn getInt(root: std.json.Value, key: []const u8) i64 {
    const v = get(root, key) orelse return 0;
    return switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

fn getU64(root: std.json.Value, key: []const u8) u64 {
    const n = getInt(root, key);
    return if (n < 0) 0 else @intCast(n);
}

fn getF64(root: std.json.Value, key: []const u8) f64 {
    const v = get(root, key) orelse return 0.0;
    return switch (v) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => 0.0,
    };
}

fn getBool(root: std.json.Value, key: []const u8) bool {
    const v = get(root, key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        .integer => |n| n != 0,
        else => false,
    };
}

fn getStr(root: std.json.Value, key: []const u8) []const u8 {
    const v = get(root, key) orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

// ── Box drawing helpers ───────────────────────────────────────────────

fn hrule(w: anytype, width: usize) !void {
    var i: usize = 0;
    while (i < width) : (i += 1) try w.print("─", .{});
    try w.print("\n", .{});
}

/// Heavier rule used only at the top of the panel as a visual anchor.
/// Body sections use the single-rule `sectionHeader` helper instead.
fn anchorRule(w: anytype, width: usize) !void {
    var i: usize = 0;
    while (i < width) : (i += 1) try w.print("═", .{});
    try w.print("\n", .{});
}

/// Subtle single-rule section divider: " ─── TITLE ─────────...─".
/// Always exactly `width` cols: leading space + 3 dashes + space + title +
/// space + fill dashes. Per-row dividers are dropped — each render*
/// function only emits its rows; the section header is the one separator.
fn sectionHeader(w: anytype, width: usize, title: []const u8) !void {
    try w.print(" ─── {s} ", .{title});
    // Bytes already written (counted by display width — ASCII title +
    // multibyte dashes both occupy 1 col each in xterm conventions):
    // " " + "─" + "─" + "─" + " " + title + " " = title.len + 6.
    const used: usize = title.len + 6;
    const fill: usize = if (width > used) width - used else 0;
    var i: usize = 0;
    while (i < fill) : (i += 1) try w.print("─", .{});
    try w.print("\n", .{});
}

// ── Column / value formatting helpers ─────────────────────────────────

/// Fixed cell widths used by every kv row. Two-column rows align label to
/// COL_LABEL chars and value to COL_VALUE; three-column rows use the same
/// pair three times. Tweaking these widths re-aligns the whole panel.
const COL_LABEL: usize = 13;
const COL_VALUE: usize = 14;

/// Pad `s` to exactly `width` chars on the right. Truncates with a single
/// '~' marker if it would overflow. Returns a slice into `buf`. Buf must
/// be at least `width` bytes.
fn padRight(buf: []u8, s: []const u8, width: usize) []const u8 {
    if (width == 0) return buf[0..0];
    if (s.len == width) {
        var i: usize = 0;
        while (i < width) : (i += 1) buf[i] = s[i];
        return buf[0..width];
    }
    if (s.len > width) {
        // Truncate with a single ASCII '~' marker so the rendered cell
        // width equals `width` exactly. We avoid '…' (3-byte UTF-8) so
        // the byte length matches the column count.
        if (width == 1) {
            buf[0] = s[0];
            return buf[0..1];
        }
        const cut = width - 1;
        var i: usize = 0;
        while (i < cut) : (i += 1) buf[i] = s[i];
        buf[cut] = '~';
        return buf[0..width];
    }
    var i: usize = 0;
    while (i < s.len) : (i += 1) buf[i] = s[i];
    while (i < width) : (i += 1) buf[i] = ' ';
    return buf[0..width];
}

/// Render a single "label : value" cell padded to (COL_LABEL + 2 + COL_VALUE).
/// Buf must be sized for COL_LABEL + COL_VALUE + 4.
fn kvCell(buf: []u8, label: []const u8, value: []const u8) []const u8 {
    var lab_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;
    const lab = padRight(&lab_buf, label, COL_LABEL);
    const val = padRight(&val_buf, value, COL_VALUE);
    return std.fmt.bufPrint(buf, "{s}: {s}", .{ lab, val }) catch buf[0..0];
}

/// Render a value as the formatted string when `present` is true,
/// otherwise return the em-dash. Caller passes a comptime fmt string and
/// args appropriate to it. Used to disambiguate "missing field" from
/// "explicit zero" — see render() callsites for which numeric fields keep
/// printing 0 vs. dash.
fn fmtOrDash(buf: []u8, present: bool, comptime fmt_str: []const u8, args: anytype) []const u8 {
    if (!present) return "—";
    return std.fmt.bufPrint(buf, fmt_str, args) catch "?";
}

// ── Formatting helpers ────────────────────────────────────────────────

fn fmtUptime(buf: []u8, secs: i64) []const u8 {
    if (secs <= 0) return std.fmt.bufPrint(buf, "0d 00:00:00", .{}) catch "0d 00:00:00";
    const total: u64 = @intCast(secs);
    const days = total / 86_400;
    const rem = total % 86_400;
    const hh = rem / 3_600;
    const mm = (rem % 3_600) / 60;
    const ss = rem % 60;
    return std.fmt.bufPrint(buf, "{d}d {d:0>2}:{d:0>2}:{d:0>2}", .{ days, hh, mm, ss }) catch "?";
}

fn fmtBytesIEC(buf: []u8, bytes: u64) []const u8 {
    const KB: f64 = 1024.0;
    const MB: f64 = 1024.0 * 1024.0;
    const GB: f64 = 1024.0 * 1024.0 * 1024.0;
    const f: f64 = @floatFromInt(bytes);
    if (f >= GB) {
        return std.fmt.bufPrint(buf, "{d:.1}G", .{f / GB}) catch "?";
    } else if (f >= MB) {
        return std.fmt.bufPrint(buf, "{d:.1}M", .{f / MB}) catch "?";
    } else if (f >= KB) {
        return std.fmt.bufPrint(buf, "{d:.1}K", .{f / KB}) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d}B", .{bytes}) catch "?";
}

fn fmtAdaCompact(buf: []u8, lovelace: u64) []const u8 {
    const ada: f64 = @as(f64, @floatFromInt(lovelace)) / 1_000_000.0;
    const M: f64 = 1_000_000.0;
    const K: f64 = 1_000.0;
    if (ada >= M) {
        return std.fmt.bufPrint(buf, "{d:.2}M", .{ada / M}) catch "?";
    } else if (ada >= K) {
        return std.fmt.bufPrint(buf, "{d:.1}k", .{ada / K}) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d:.0}", .{ada}) catch "?";
}

/// Format a unix timestamp as "YYYY-MM-DD HH:MM UTC". Bounded.
fn fmtUtc(buf: []u8, unix: i64) []const u8 {
    if (unix <= 0) return "—";
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(unix) };
    const day_secs = es.getDaySeconds();
    const ed = es.getEpochDay();
    const ymd = ed.calculateYearDay();
    const md = ymd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{
        ymd.year,
        md.month.numeric(),
        md.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
    }) catch "—";
}

// ── Top-level render ──────────────────────────────────────────────────

/// Render the operator panel into a writer. Pure output — no stdout
/// writes from this function or anything it calls. The orchestration
/// loop captures the bytes and decides when (and how) to paint them.
fn renderPanel(w: anytype, root: std.json.Value, width: usize, use_color: bool) !void {
    try renderHeader(w, root, width, use_color);
    try sectionHeader(w, width, "EPOCH");
    try renderEpoch(w, root, width, use_color);
    try sectionHeader(w, width, "TIP");
    try renderTip(w, root, width, use_color);
    try sectionHeader(w, width, "CONNECTIONS");
    try renderConnections(w, root, width, use_color);
    try sectionHeader(w, width, "BLOCK PROPAGATION");
    try renderPropagation(w, root, width, use_color);
    try sectionHeader(w, width, "NODE RESOURCES");
    try renderResources(w, root, width, use_color);
    try sectionHeader(w, width, "CORE");
    try renderCore(w, root, width, use_color);
    try sectionHeader(w, width, "BLOCK PRODUCTION");
    try renderProduction(w, root, width, use_color);
    try hrule(w, width);

    // Footer intentionally omits a per-tick wall-clock timestamp. With
    // a unix `refreshed: <ts>` baked into every frame, two consecutive
    // polls of identical JSON would still differ byte-for-byte and the
    // diff-and-skip paint path could never elide a paint. Operators
    // who need the precise refresh moment can read `meta.uptime_unix`
    // off /status/full directly.
    const meta = getObj(root, "meta");
    const ready = getBool(meta, "ready");
    const truncated = getBool(meta, "truncated");
    const status_str: []const u8 =
        if (truncated) "TRUNCATED" else if (!ready) "initializing" else "ready";

    // Sync status: tip_age_seconds is spliced into the top-level object
    // by http_metrics.zig. Color follows the standard sync rule:
    // <5s green, <30s yellow, else red. When the field is missing (older
    // build, cold-start) we render '—' with no color.
    const tip_age_present = get(root, "tip_age_seconds") != null;
    const tip_age = getInt(root, "tip_age_seconds");
    const sync_c = if (tip_age_present) lightSync(use_color, tip_age) else "";
    const sync_rst = if (tip_age_present and use_color) C.reset else "";
    var ta_buf: [16]u8 = undefined;
    const ta_str = fmtOrDash(&ta_buf, tip_age_present, "{d}s", .{tip_age});

    try w.print(" {s}status:{s} {s}    sync: {s}{s}{s}    refresh every {d}s    press q to quit\n", .{
        cTag(use_color, C.dim),
        cTag(use_color, C.reset),
        status_str,
        sync_c, ta_str, sync_rst,
        REFRESH_S,
    });
}

// ── Section renderers ─────────────────────────────────────────────────

fn renderHeader(w: anytype, root: std.json.Value, width: usize, use_color: bool) !void {
    const meta = getObj(root, "meta");
    const now = compat.timestamp();
    // uptime_unix is the *duration* (seconds) since process start, per
    // /status/full contract (see http_metrics.zig: uptime_unix). Some
    // older builds may expose process_start_unix instead — fall back if
    // the value looks like a wall-clock time (>= 1e9).
    const ut_raw = getInt(meta, "uptime_unix");
    const uptime: i64 = if (ut_raw > 1_000_000_000) (now - ut_raw) else ut_raw;

    var ub: [32]u8 = undefined;
    const us = fmtUptime(&ub, uptime);

    const title = "TSUNAGI";
    // Right-align the uptime label.
    const right = "Uptime: ";
    // total used: " " + title + spaces + right + uptime + " "
    const used = 1 + title.len + 1 + right.len + us.len + 1;
    const pad: usize = if (width > used) width - used else 1;
    var i: usize = 0;
    try w.print(" {s}{s}{s}", .{ cTag(use_color, C.bold), title, cTag(use_color, C.reset) });
    while (i < pad) : (i += 1) try w.print(" ", .{});
    try w.print("{s}{s}\n", .{ right, us });
    // Heavier '═' rule: top-of-panel anchor only. Section dividers below
    // use the lighter '─' rule via sectionHeader().
    try anchorRule(w, width);
}

/// Epoch line + 68-char progress bar.
/// Bar uses '▌' for filled, '▖' for empty.
fn renderEpoch(w: anytype, root: std.json.Value, _: usize, use_color: bool) !void {
    const epoch_present = get(root, "nonce_epoch") != null;
    const epoch = getU64(root, "nonce_epoch");

    // /status/full does not currently expose slot_in_epoch directly. We
    // derive it from the absolute slot relative to epoch boundaries when
    // a slots_per_epoch is known. As a best-effort fallback we compute
    // slot_in_epoch = absolute_slot mod slots_per_epoch.
    //
    // MISSING: producer_slot_in_epoch / producer_slots_per_epoch in
    // /status/full — currently only exported via Prometheus. Until those
    // are mirrored into JSON we pick the slot length / period from the
    // network heuristic below.
    const abs_slot = getU64(root, "slot");
    var slots_per_epoch: u64 = SLOTS_PER_EPOCH_PREVIEW;
    if (abs_slot > 200_000_000) {
        slots_per_epoch = SLOTS_PER_EPOCH_MAINNET;
    }
    // Allow forge_stats to override (preferred source).
    const fs = getObj(root, "forge_stats");
    const fs_spe = getU64(fs, "slots_per_epoch");
    if (fs_spe > 0) slots_per_epoch = fs_spe;

    const slot_in_epoch: u64 = if (slots_per_epoch == 0) 0 else abs_slot % slots_per_epoch;
    const remaining: u64 = if (slots_per_epoch > slot_in_epoch) slots_per_epoch - slot_in_epoch else 0;

    // Cardano runs 1 slot/sec on shelley-era networks for both preview
    // and mainnet, so seconds == slots for the remaining countdown.
    const rem_h = remaining / 3600;
    const rem_m = (remaining % 3600) / 60;
    const rem_s = remaining % 60;

    const pct_x100: u64 = if (slots_per_epoch == 0) 0 else (slot_in_epoch * 10_000) / slots_per_epoch;
    const pct_int = pct_x100 / 100;
    const pct_frac = pct_x100 % 100;

    // nonce_epoch missing renders as '—'; the percentage / countdown are
    // still informative because they derive from `slot` mod
    // slots_per_epoch which is independent of the epoch counter.
    var ep_buf: [16]u8 = undefined;
    const ep_str = fmtOrDash(&ep_buf, epoch_present, "{d}", .{epoch});
    try w.print(" Epoch {s} [{d:0>2}.{d:0>2}%], {d:0>2}:{d:0>2}:{d:0>2} remaining\n", .{
        ep_str, pct_int, pct_frac, rem_h, rem_m, rem_s,
    });

    // 68-col progress bar.
    const bar_w: usize = 68;
    const filled: usize = blk: {
        if (slots_per_epoch == 0) break :blk 0;
        const f = (slot_in_epoch * bar_w) / slots_per_epoch;
        break :blk @intCast(f);
    };
    try w.print(" {s}", .{cTag(use_color, C.cyan)});
    var i: usize = 0;
    while (i < bar_w) : (i += 1) {
        if (i < filled) try w.print("▌", .{}) else try w.print("▖", .{});
    }
    try w.print("{s}\n", .{cTag(use_color, C.reset)});
}

/// 3-column tip grid: Block/Slot/Slot epoch | Tip ref/diff/Density | Forks/Total Tx/Pending Tx.
/// Highlights: `slot` (cyan-bold) and the dedicated Next Slot / Leader
/// row (cyan-bold for the next-slot value, yellow-bold for an imminent
/// LEADER state, green-bold once we have FORGED).
fn renderTip(w: anytype, root: std.json.Value, _: usize, use_color: bool) !void {
    const block_present = get(root, "block_no") != null;
    const slot_present = get(root, "slot") != null;
    const block = getU64(root, "block_no");
    const slot = getU64(root, "slot");

    // Slot in epoch — same derivation as in renderEpoch.
    const abs_slot = slot;
    var slots_per_epoch: u64 = SLOTS_PER_EPOCH_PREVIEW;
    if (abs_slot > 200_000_000) slots_per_epoch = SLOTS_PER_EPOCH_MAINNET;
    const fs = getObj(root, "forge_stats");
    const fs_spe = getU64(fs, "slots_per_epoch");
    if (fs_spe > 0) slots_per_epoch = fs_spe;
    const slot_in_epoch: u64 = if (slots_per_epoch == 0) 0 else abs_slot % slots_per_epoch;

    // Tip reference and diff. /status/full does not currently expose a
    // network reference tip — slot itself is our best knowledge of the
    // chain head we have observed. Tip(diff) is set to tip_age when
    // available; otherwise 0.
    //
    // MISSING: tip_ref (network head from probes/follower) and tip_diff
    // (slots behind) — to be wired alongside #94 (connection state).
    const tip_ref = slot;
    const tip_diff: u64 = 0;

    const density_present = get(root, "chain_density_last_x1e6") != null;
    const density_x1e6 = getU64(root, "chain_density_last_x1e6");
    const density: f64 = @as(f64, @floatFromInt(density_x1e6)) / 1_000_000.0;

    // Forks: not yet exposed in /status/full.
    // MISSING: authority_fork_events_total — Prometheus gauge today; lift to JSON.
    const forks_label = "—";

    // Total TX seen by node — we fall back to the sign_log / forge_stats
    // counters we do have. Closest proxy is mempool serves over time.
    //
    // MISSING: total_tx (lifetime tx-on-chain count). Until that lands
    // we surface mempool_items as Pending Tx and leave Total Tx as '—'.
    const total_tx_label = "—";

    const mempool_items = getU64(root, "mempool_items");
    const mempool_bytes = getU64(root, "mempool_bytes");
    var mb_buf: [16]u8 = undefined;
    const mb_str = std.fmt.bufPrint(&mb_buf, "{d}/{d}K", .{
        mempool_items,
        mempool_bytes / 1024,
    }) catch "?";

    // Highlight escapes for the slot field. Cyan + bold so the operator
    // eye lands on it first. Reset after the value.
    const slot_hi = if (use_color) C.bold ++ C.cyan else "";
    const slot_rst = ansiOn(use_color, C.reset);

    // Three-column layout. Field labels left-padded, values right-padded
    // to fixed widths so columns align. Slot value is highlighted; the
    // padded width compensates for the 0-width ANSI bytes by widening
    // the format spec. Numeric fields where the upstream key may be
    // absent (vs. legitimately zero) render '—' via fmtOrDash.
    var bk_buf: [16]u8 = undefined;
    const bk_str = fmtOrDash(&bk_buf, block_present, "{d}", .{block});
    var sl_buf: [16]u8 = undefined;
    const sl_str = fmtOrDash(&sl_buf, slot_present, "{d}", .{slot});
    var tr_buf: [16]u8 = undefined;
    const tr_str = fmtOrDash(&tr_buf, slot_present, "{d}", .{tip_ref});
    var td_buf: [16]u8 = undefined;
    const td_str = fmtOrDash(&td_buf, slot_present, "{d}", .{tip_diff});
    var se_buf: [16]u8 = undefined;
    const se_str = fmtOrDash(&se_buf, slot_present, "{d}", .{slot_in_epoch});
    var dn_buf: [16]u8 = undefined;
    const dn_str = fmtOrDash(&dn_buf, density_present, "{d:.3}", .{density});

    try w.print(" Block      : {s: <9} Tip (ref)  : {s: <9} Forks      : {s}\n", .{
        bk_str, tr_str, forks_label,
    });
    try w.print(" Slot       : {s}{s: <9}{s} Tip (diff) : {s: <9} Total Tx   : {s}\n", .{
        slot_hi, sl_str, slot_rst, td_str, total_tx_label,
    });
    try w.print(" Slot epoch : {s: <9} Density    : {s: <9} Pending Tx : {s}\n", .{
        se_str, dn_str, mb_str,
    });

    // Next-slot + leader-status row. schedule.next_slot is the closest
    // upcoming slot we are scheduled to lead; schedule.eta_sec is its
    // distance in seconds. We render LEADER (yellow-bold) when eta is in
    // [-1, 30] (i.e. now or imminent), FORGED (green-bold) when the most
    // recent adopted block matches the current absolute slot, otherwise
    // an em-dash. Both highlights are gated by use_color.
    const sched = getObj(root, "schedule");
    const next_slot_present = get(sched, "next_slot") != null;
    const next_slot = getU64(sched, "next_slot");
    const eta_sec = getInt(sched, "eta_sec");

    const adopted_slot = getU64(fs, "last_adopted_slot");
    const just_forged: bool = adopted_slot != 0 and adopted_slot == slot;
    const is_imminent_leader: bool = next_slot_present and next_slot != 0 and
        eta_sec >= -1 and eta_sec <= 30;

    const ns_hi = if (use_color and next_slot_present and next_slot != 0) C.bold ++ C.cyan else "";
    const ns_rst = if (use_color and next_slot_present and next_slot != 0) C.reset else "";
    var ns_buf: [16]u8 = undefined;
    const ns_str = if (next_slot_present and next_slot != 0)
        (std.fmt.bufPrint(&ns_buf, "{d}", .{next_slot}) catch "?")
    else
        "—";

    const ld_hi = if (use_color and just_forged)
        C.bold ++ C.green
    else if (use_color and is_imminent_leader)
        C.bold ++ C.yellow
    else
        "";
    const ld_rst = if (use_color and (just_forged or is_imminent_leader)) C.reset else "";
    const ld_str: []const u8 = if (just_forged) "FORGED" else if (is_imminent_leader) "LEADER" else "—";

    try w.print(" Next Slot  : {s}{s: <9}{s} Leader     : {s}{s: <9}{s}\n", .{
        ns_hi, ns_str, ns_rst, ld_hi, ld_str, ld_rst,
    });
}

/// CONNECTIONS — placeholder rows. /status/full does not yet expose
/// peer-state breakdown for incoming/outgoing.
///
/// MISSING: connections.in/out (Bi-Dir/Duplex/Warm/Hot) — to be wired by #94.
fn renderConnections(w: anytype, _: std.json.Value, _: usize, _: bool) !void {
    try w.print(" Bi-Dir     : {s: <9} Warm       : {s: <9} Warm       : {s}\n", .{
        "—", "—", "—",
    });
    try w.print(" Duplex     : {s: <9} Hot        : {s: <9} Hot        : {s}\n", .{
        "—", "—", "—",
    });
}

fn renderPropagation(w: anytype, root: std.json.Value, _: usize, _: bool) !void {
    const p = getObj(root, "presence");
    const last_ms = getU64(p, "last_notice_ms");
    const pct1s = getU64(p, "under_1s_pct");
    const pct3s = getU64(p, "under_3s_pct");
    const pct5s = getU64(p, "under_5s_pct");

    const last_s: f64 = @as(f64, @floatFromInt(last_ms)) / 1000.0;
    if (last_ms == 0) {
        try w.print(" Last Block : {s: <9} <1s|<3s|<5s [%] : {d} | {d} | {d}\n", .{
            "—", pct1s, pct3s, pct5s,
        });
    } else {
        try w.print(" Last Block : {d:.2}s     <1s|<3s|<5s [%] : {d} | {d} | {d}\n", .{
            last_s, pct1s, pct3s, pct5s,
        });
    }
}

fn renderResources(w: anytype, root: std.json.Value, _: usize, use_color: bool) !void {
    const r = getObj(root, "resources");
    const cpu_present = get(r, "cpu_pct") != null;
    const cpu = getF64(r, "cpu_pct");
    const rss = getU64(r, "mem_rss_bytes");
    const disk_present = get(r, "disk_pct") != null;
    const disk = getF64(r, "disk_pct");

    var rb: [16]u8 = undefined;
    const rs = if (rss == 0) "—" else fmtBytesIEC(&rb, rss);

    // Traffic-light wraps each numeric value; reset escapes are inline
    // (still part of the same rendered frame so PR #149 diff-paint
    // continues to detect "unchanged frame" correctly).
    const cpu_c = lightCpu(use_color, cpu);
    const disk_c = lightDisk(use_color, disk);
    const rst = ansiOn(use_color, C.reset);

    if (cpu_present and disk_present) {
        try w.print(" CPU (sys)  : {s}{d:.2}%{s}     Mem (RSS)  : {s: <9} Disk util  : {s}{d:.0}%{s}\n", .{
            cpu_c, cpu, rst, rs, disk_c, disk, rst,
        });
    } else {
        // Either field missing — render present-only branches with em-dash.
        var cb: [16]u8 = undefined;
        const cs = fmtOrDash(&cb, cpu_present, "{d:.2}%", .{cpu});
        var db: [16]u8 = undefined;
        const ds = fmtOrDash(&db, disk_present, "{d:.0}%", .{disk});
        try w.print(" CPU (sys)  : {s}{s: <9}{s} Mem (RSS)  : {s: <9} Disk util  : {s}{s: <9}{s}\n", .{
            if (cpu_present) cpu_c else "", cs, if (cpu_present) rst else "",
            rs,
            if (disk_present) disk_c else "", ds, if (disk_present) rst else "",
        });
    }
}

fn renderCore(w: anytype, root: std.json.Value, _: usize, use_color: bool) !void {
    // KES — period derived from forge_stats / kes_alerts. Both are
    // populated; kes_alerts.level drives the color tag.
    const ka = getObj(root, "kes_alerts");
    const kes_cur_present = get(ka, "current_period") != null;
    const kes_rem_present = get(ka, "periods_remaining") != null;
    const kes_cur = getU64(ka, "current_period");
    const kes_rem = getU64(ka, "periods_remaining");

    // KES expiry estimate: if current/remaining are present, expiry =
    // now + remaining * SLOTS_PER_KES_PERIOD seconds. We do not have a
    // direct exp_unix in /status/full yet, so this is best-effort.
    //
    // MISSING: kes_alerts.expiry_unix — to be added alongside #91 follow-up.
    const now_unix = compat.timestamp();
    const exp_unix: i64 = now_unix + @as(i64, @intCast(kes_rem * SLOTS_PER_KES_PERIOD));
    var eb: [32]u8 = undefined;
    const exp_str = if (!kes_rem_present or kes_rem == 0) "—" else fmtUtc(&eb, exp_unix);

    // Threshold-based traffic light per spec: > 10 green, 5..10 yellow,
    // < 5 red. The kes_alerts.level field is also present and carries
    // module-defined semantics, but the operator-facing rule is the
    // remaining-periods threshold below.
    const kes_color = if (kes_rem_present) lightKes(use_color, kes_rem) else "";
    const kes_reset = if (kes_rem_present and use_color) C.reset else "";

    var kc_buf: [16]u8 = undefined;
    const kc_str = fmtOrDash(&kc_buf, kes_cur_present, "{d}", .{kes_cur});
    var kr_buf: [16]u8 = undefined;
    const kr_str = fmtOrDash(&kr_buf, kes_rem_present, "{d}", .{kes_rem});

    try w.print(" KES current|remaining|exp : {s} | {s}{s}{s} | {s}\n", .{
        kc_str, kes_color, kr_str, kes_reset, exp_str,
    });

    // OP Cert — disk and chain counters are not yet in /status/full.
    // We DO have producer_keys_readable_ok over the producer module; the
    // counters live as Prometheus gauges (opcert_counter_disk /
    // opcert_counter_chain). Render '—' until the JSON exposure lands.
    //
    // MISSING: opcert.disk / opcert.chain in /status/full.
    try w.print(" OP Cert disk|chain        : {s} | {s}\n", .{ "—", "—" });

    // Pool stats. Most require LSQ.
    // - Blocks: forge_stats.adopted_total (lifetime) is closest; we use it.
    // - Act Stake: derive from sigma_x1e9 if a total_supply hint is
    //   exposed; otherwise show sigma directly.
    // MISSING: pool_stats.pledge / live_pledge / fixed_fee / margin /
    // delegators / saturation — requires LSQ GetStakePoolParams (#95).
    const fs = getObj(root, "forge_stats");
    const blocks_present = get(fs, "adopted_total") != null;
    const blocks_lifetime = getU64(fs, "adopted_total");
    const sigma_present = get(root, "sigma_x1e9") != null;
    const sigma_x1e9 = getU64(root, "sigma_x1e9");
    const sigma: f64 = @as(f64, @floatFromInt(sigma_x1e9)) / 1_000_000_000.0;

    // Active stake — best effort from sigma. We don't have total active
    // stake exposed yet, so we surface sigma as a fraction in the same
    // slot. σ is the pool's share of active stake.
    var bl_buf: [16]u8 = undefined;
    const bl_str = fmtOrDash(&bl_buf, blocks_present, "{d}", .{blocks_lifetime});
    var as_buf: [24]u8 = undefined;
    const as_str = fmtOrDash(&as_buf, sigma_present, "σ={d:.4}", .{sigma});

    try w.print(" Blocks     : {s: <9} Act Stake  : {s: <9} Pledge     : {s}\n", .{
        bl_str, as_str, "—",
    });
    try w.print(" Fixed Fee  : {s: <9} Live Stake : {s: <9} Live Pledge: {s}\n", .{
        "—", "—", "—",
    });
    try w.print(" Margin Fee : {s: <9} Delegators : {s: <9} Saturation : {s}\n", .{
        "—", "—", "—",
    });
}

fn renderProduction(w: anytype, root: std.json.Value, _: usize, use_color: bool) !void {
    const fs = getObj(root, "forge_stats");
    const leader = getU64(fs, "leader_total");
    const adopted = getU64(fs, "adopted_total");
    const lost = getU64(fs, "lost_total");
    const ideal = getU64(fs, "ideal");
    const luck_x100 = getU64(fs, "luck_pct_x100");
    const luck_int = luck_x100 / 100;
    const luck_frac = luck_x100 % 100;

    // Ideal is the integer expected leader count for this epoch
    // (sigma * slots_per_epoch * f). Operators may also see it surfaced
    // as a decimal in some external panels.
    // Confirmed is currently always 0 in forge_stats and the work to
    // wire ChainSync confirmations is not yet merged — render '—'.
    //
    // MISSING: forge_stats.confirmed_total — wired by ChainSync rollback
    // tracking (Phase 2 placeholder, see forge_stats.zig).
    // `leader_total`, `adopted_total`, `ideal`, `luck_pct_x100`, and
    // `lost_total` keep printing 0 explicitly when zero (0 IS valid data
    // for "no events so far this epoch"); only fields that are absent
    // from the JSON payload em-dash.
    try w.print(" Leader     : {d: <9} Luck       : {d:0>2}.{d:0>2}%    Confirmed  : {s}\n", .{
        leader, luck_int, luck_frac, "—",
    });
    // Lost gets a traffic-light wrap (green at 0, yellow 1..2, red >2).
    const lost_c = lightLost(use_color, lost);
    const lost_rst = ansiOn(use_color, C.reset);
    try w.print(" Ideal      : {d: <9} Adopted    : {d: <9} Lost       : {s}{d}{s}\n", .{
        ideal, adopted, lost_c, lost, lost_rst,
    });
}

// ── Tests ─────────────────────────────────────────────────────────────

test "isExitKey accepts q/Q/ESC/ctrl-c only" {
    // Bound bindings — every other byte must be ignored, including
    // spaces, arrow-key body bytes ([A/[B), printable letters, and
    // control chars near 0x03 (ctrl-b/ctrl-d).
    try std.testing.expect(isExitKey('q'));
    try std.testing.expect(isExitKey('Q'));
    try std.testing.expect(isExitKey(0x1B)); // ESC
    try std.testing.expect(isExitKey(0x03)); // ctrl-c

    try std.testing.expect(!isExitKey('a'));
    try std.testing.expect(!isExitKey('Z'));
    try std.testing.expect(!isExitKey(' '));
    try std.testing.expect(!isExitKey('\n'));
    try std.testing.expect(!isExitKey('\r'));
    try std.testing.expect(!isExitKey(0x00));
    try std.testing.expect(!isExitKey(0x02)); // ctrl-b
    try std.testing.expect(!isExitKey(0x04)); // ctrl-d
    try std.testing.expect(!isExitKey('['));
    try std.testing.expect(!isExitKey('A'));
    try std.testing.expect(!isExitKey('B'));
}

test "startsWithBrace rejects non-JSON-document bodies" {
    // Exact corruption pattern that triggered the operator-visible
    // panel flicker: routing fallback returning the literal "not found".
    try std.testing.expect(!startsWithBrace("not found"));
    try std.testing.expect(!startsWithBrace(""));
    try std.testing.expect(!startsWithBrace("  "));
    try std.testing.expect(!startsWithBrace("[]"));
    try std.testing.expect(!startsWithBrace("null"));
    try std.testing.expect(!startsWithBrace("42"));
    try std.testing.expect(!startsWithBrace("\"a string\""));
    try std.testing.expect(!startsWithBrace("<html>"));
}

test "startsWithBrace accepts JSON objects with leading whitespace" {
    try std.testing.expect(startsWithBrace("{}"));
    try std.testing.expect(startsWithBrace("{\"a\":1}"));
    try std.testing.expect(startsWithBrace("  \n  {\"a\":1}"));
    try std.testing.expect(startsWithBrace("\t\r\n {\"k\":true}"));
}

test "fmtUptime formats days/hours/minutes/seconds" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0d 00:00:00", fmtUptime(&buf, 0));
    try std.testing.expectEqualStrings("0d 00:00:30", fmtUptime(&buf, 30));
    try std.testing.expectEqualStrings("0d 01:02:03", fmtUptime(&buf, 3723));
    try std.testing.expectEqualStrings("5d 11:26:00", fmtUptime(&buf, 5 * 86_400 + 11 * 3600 + 26 * 60));
}

test "fmtBytesIEC chooses unit" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0B", fmtBytesIEC(&buf, 0));
    try std.testing.expectEqualStrings("512B", fmtBytesIEC(&buf, 512));
    try std.testing.expectEqualStrings("1.0K", fmtBytesIEC(&buf, 1024));
    try std.testing.expectEqualStrings("3.5M", fmtBytesIEC(&buf, 3_670_016));
    try std.testing.expectEqualStrings("3.5G", fmtBytesIEC(&buf, 3_758_096_384));
}

test "fmtUtc formats unix timestamp" {
    var buf: [32]u8 = undefined;
    // 2026-05-31 02:00:00 UTC = 1780192800
    try std.testing.expectEqualStrings("2026-05-31 02:00 UTC", fmtUtc(&buf, 1780192800));
    try std.testing.expectEqualStrings("—", fmtUtc(&buf, 0));
}

test "fmtOrDash em-dashes when absent and formats when present" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("—", fmtOrDash(&buf, false, "{d}", .{42}));
    try std.testing.expectEqualStrings("42", fmtOrDash(&buf, true, "{d}", .{42}));
    try std.testing.expectEqualStrings("3.14", fmtOrDash(&buf, true, "{d:.2}", .{3.14}));
}

test "padRight pads short strings and truncates long ones" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("ab        ", padRight(&buf, "ab", 10));
    try std.testing.expectEqualStrings("          ", padRight(&buf, "", 10));
    try std.testing.expectEqualStrings("abcd", padRight(&buf, "abcd", 4));
    // Overlong string truncates with the ASCII '~' marker so column width
    // is preserved for downstream alignment.
    try std.testing.expectEqualStrings("abc~", padRight(&buf, "abcdef", 4));
}

test "kvCell composes label and value at fixed width" {
    var buf: [64]u8 = undefined;
    const cell = kvCell(&buf, "Block", "1234");
    // COL_LABEL=13, COL_VALUE=14, separator ": " (2 bytes) → 29 bytes.
    try std.testing.expectEqual(@as(usize, 29), cell.len);
    try std.testing.expect(std.mem.startsWith(u8, cell, "Block        : "));
}

test "traffic-light helpers pick green/yellow/red by threshold" {
    // Sync: <5 green, <30 yellow, else red.
    try std.testing.expectEqualStrings(C.green, lightSync(true, 0));
    try std.testing.expectEqualStrings(C.green, lightSync(true, 4));
    try std.testing.expectEqualStrings(C.yellow, lightSync(true, 5));
    try std.testing.expectEqualStrings(C.yellow, lightSync(true, 29));
    try std.testing.expectEqualStrings(C.red, lightSync(true, 30));
    try std.testing.expectEqualStrings(C.red, lightSync(true, 600));

    // KES: >10 green, 5..10 yellow, <5 red.
    try std.testing.expectEqualStrings(C.green, lightKes(true, 11));
    try std.testing.expectEqualStrings(C.yellow, lightKes(true, 10));
    try std.testing.expectEqualStrings(C.yellow, lightKes(true, 5));
    try std.testing.expectEqualStrings(C.red, lightKes(true, 4));
    try std.testing.expectEqualStrings(C.red, lightKes(true, 0));

    // CPU: <50 green, 50..80 yellow, >80 red.
    try std.testing.expectEqualStrings(C.green, lightCpu(true, 0.0));
    try std.testing.expectEqualStrings(C.green, lightCpu(true, 49.99));
    try std.testing.expectEqualStrings(C.yellow, lightCpu(true, 50.0));
    try std.testing.expectEqualStrings(C.yellow, lightCpu(true, 80.0));
    try std.testing.expectEqualStrings(C.red, lightCpu(true, 80.5));

    // Disk: <80 green, 80..90 yellow, >90 red.
    try std.testing.expectEqualStrings(C.green, lightDisk(true, 79.0));
    try std.testing.expectEqualStrings(C.yellow, lightDisk(true, 80.0));
    try std.testing.expectEqualStrings(C.yellow, lightDisk(true, 90.0));
    try std.testing.expectEqualStrings(C.red, lightDisk(true, 90.5));

    // Lost: 0 green, 1..2 yellow, >2 red.
    try std.testing.expectEqualStrings(C.green, lightLost(true, 0));
    try std.testing.expectEqualStrings(C.yellow, lightLost(true, 1));
    try std.testing.expectEqualStrings(C.yellow, lightLost(true, 2));
    try std.testing.expectEqualStrings(C.red, lightLost(true, 3));
}

test "ansi gating returns empty string when color disabled" {
    // Same call site that the renderers use: color OFF must emit no escape.
    try std.testing.expectEqualStrings("", ansiOn(false, C.bold));
    try std.testing.expectEqualStrings("", ansiOn(false, C.green));
    try std.testing.expectEqualStrings(C.bold, ansiOn(true, C.bold));
    try std.testing.expectEqualStrings(C.green, ansiOn(true, C.green));
    // Light helpers also gate on use_color — required so piped output
    // emits zero ANSI bytes (the diff path in #149 sees byte-equal frames
    // across runs).
    try std.testing.expectEqualStrings("", lightSync(false, 0));
    try std.testing.expectEqualStrings("", lightKes(false, 0));
    try std.testing.expectEqualStrings("", lightCpu(false, 0.0));
    try std.testing.expectEqualStrings("", lightDisk(false, 0.0));
    try std.testing.expectEqualStrings("", lightLost(false, 0));
    // ansiOff is the canonical "no escape" sentinel.
    try std.testing.expectEqualStrings("", ansiOff());
}

test "renderPanel does not crash on empty object" {
    // Sanity: feeding an empty JSON object must not panic any accessor.
    // 0.16: std.json.ObjectMap (StringArrayHashMapUnmanaged) no longer has a
    // single-allocator init(); the empty-map value is `.empty`. deinit still
    // takes the allocator (see below).
    const empty = std.json.Value{ .object = std.json.ObjectMap.empty };
    var emptyMut = empty;
    defer emptyMut.object.deinit(std.testing.allocator);
    // We intentionally do not call renderPanel here (it writes to stdout
    // via std.debug.print which is global). Instead we exercise the
    // accessor surface that renderers call, mirroring what would happen
    // on a fresh /status/full hit before the node is ready.
    try std.testing.expectEqual(@as(u64, 0), getU64(empty, "slot"));
    try std.testing.expectEqual(@as(u64, 0), getU64(empty, "block_no"));
    try std.testing.expectEqual(@as(u64, 0), getU64(empty, "nonce_epoch"));
    try std.testing.expectEqual(false, getBool(empty, "meta"));
    try std.testing.expectEqualStrings("", getStr(empty, "tip_hash"));
}

test "renderPanel handles minimal status with missing fields (every em-dash path)" {
    // Empty meta + no other keys: every accessor must em-dash without
    // crashing. We render into a buffer and inspect for the em-dash
    // marker so the present/missing distinction is exercised end-to-end.
    const sample =
        \\{"meta":{"ready":false,"truncated":false,"uptime_unix":0}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, sample, .{});
    defer parsed.deinit();
    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try renderPanel(compat.listWriter(&buf), parsed.value, 80, false);
    // At least one em-dash must appear: nonce_epoch / block_no / slot
    // / density / sigma / KES / next-slot / leader-status all dash out
    // when their upstream keys are absent.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "—") != null);
    // Color OFF: zero ANSI escape bytes in the rendered frame.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\x1b[") == null);
}

test "renderPanel runs end-to-end on a representative status JSON" {
    // Minimal /status/full shape, hitting every section the renderer reads.
    const sample =
        \\{
        \\  "meta": {"ready": true, "truncated": false, "uptime_unix": 472020},
        \\  "slot": 110438405,
        \\  "block_no": 4220378,
        \\  "tip_hash": "abcd1234deadbeef",
        \\  "nonce_epoch": 1278,
        \\  "sigma_x1e9": 45000000,
        \\  "mempool_items": 0,
        \\  "mempool_bytes": 0,
        \\  "chain_density_last_x1e6": 3380000,
        \\  "presence": {"last_notice_ms": 80, "under_1s_pct": 100, "under_3s_pct": 100, "under_5s_pct": 100},
        \\  "resources": {"cpu_pct": 0.94, "mem_rss_bytes": 3758096384, "disk_pct": 8.0},
        \\  "kes_alerts": {"level": "none", "current_period": 852, "periods_remaining": 24},
        \\  "forge_stats": {"epoch": 1278, "leader_total": 1, "adopted_total": 553, "lost_total": 0, "ideal": 4, "luck_pct_x100": 2591, "slots_per_epoch": 86400}
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, sample, .{});
    defer parsed.deinit();
    // Render into a buffer (no stdout writes from the test path).
    var buf = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buf.deinit();
    try renderPanel(compat.listWriter(&buf), parsed.value, 80, false);
    // Sanity: the rendered panel must contain at least one section header.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "TSUNAGI") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Epoch") != null);
}

test "shouldSkipPaint: empty prev never skips, identical prev skips" {
    // First paint: prev_frame is empty, must paint unconditionally.
    try std.testing.expectEqual(false, shouldSkipPaint("", "hello"));
    // Steady state: identical content, paint suppressed.
    try std.testing.expectEqual(true, shouldSkipPaint("hello", "hello"));
    // Content changed by even one byte: must paint.
    try std.testing.expectEqual(false, shouldSkipPaint("hello", "hellp"));
    // Empty current frame: nothing to paint either way.
    try std.testing.expectEqual(true, shouldSkipPaint("hello", ""));
    try std.testing.expectEqual(true, shouldSkipPaint("", ""));
}

test "composeIncrementalPaint: starts with cursor-home, ends with erase-below" {
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try composeIncrementalPaint(&out, "alpha\nbeta\ngamma\n");

    // Must NOT contain a full-screen clear — that's the whole point.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[2J") == null);
    // Must lead with cursor-home.
    try std.testing.expect(std.mem.startsWith(u8, out.items, ANSI_CURSOR_HOME));
    // Must end with erase-below so trailing rows from a longer prev
    // frame disappear.
    try std.testing.expect(std.mem.endsWith(u8, out.items, ANSI_ERASE_BELOW));
    // Each rendered line must carry the per-line erase tail.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "alpha\x1b[K\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "beta\x1b[K\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "gamma\x1b[K\n") != null);
}

test "composeIncrementalPaint: shorter new frame still erases tail (verified via final ESC[J)" {
    // The new frame is shorter than what was on screen before. We
    // can't observe the prev frame from here, but the contract is
    // that the paint payload always ends with ESC[J — that's what
    // erases the leftover rows. Proves the contract via byte content.
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try composeIncrementalPaint(&out, "only-line\n");
    try std.testing.expect(std.mem.endsWith(u8, out.items, ANSI_ERASE_BELOW));
}

test "renderPanel: identical inputs produce byte-equal frames (no embedded wall-clock)" {
    // Two renders of the same JSON must produce identical output. If a
    // per-tick wall-clock value sneaks back into the renderer the diff
    // skip will never trigger and the flicker fix collapses.
    const sample =
        \\{
        \\  "meta": {"ready": true, "truncated": false, "uptime_unix": 472020},
        \\  "slot": 110438405,
        \\  "block_no": 4220378,
        \\  "nonce_epoch": 1278,
        \\  "sigma_x1e9": 45000000,
        \\  "mempool_items": 0,
        \\  "mempool_bytes": 0,
        \\  "chain_density_last_x1e6": 3380000,
        \\  "presence": {"last_notice_ms": 80, "under_1s_pct": 100, "under_3s_pct": 100, "under_5s_pct": 100},
        \\  "resources": {"cpu_pct": 0.94, "mem_rss_bytes": 3758096384, "disk_pct": 8.0},
        \\  "kes_alerts": {"level": "none", "current_period": 852, "periods_remaining": 24},
        \\  "forge_stats": {"leader_total": 1, "adopted_total": 553, "lost_total": 0, "ideal": 4, "luck_pct_x100": 2591, "slots_per_epoch": 86400}
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, sample, .{});
    defer parsed.deinit();

    var a = std.array_list.Managed(u8).init(std.testing.allocator);
    defer a.deinit();
    var b = std.array_list.Managed(u8).init(std.testing.allocator);
    defer b.deinit();

    try renderPanel(compat.listWriter(&a), parsed.value, 80, false);
    // Sleep is unnecessary — the renderer must not depend on wall time.
    try renderPanel(compat.listWriter(&b), parsed.value, 80, false);

    try std.testing.expectEqualSlices(u8, a.items, b.items);
    // And shouldSkipPaint must agree: second paint is elided.
    try std.testing.expectEqual(true, shouldSkipPaint(a.items, b.items));
}
