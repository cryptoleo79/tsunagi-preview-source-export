// Slashing protection — last-signed-slot log.
//
// Pattern from Lighthouse / Prysm: persist the highest slot we've ever
// signed BEFORE issuing a new signature. On restart, refuse to sign any
// slot <= the persisted value. Prevents a crash + restart cycle from
// double-signing for the same slot, which on mainnet would be permanent
// reputation damage and (when slashing exists for Cardano in some future
// era) financial loss.
//
// Storage: ${TSUNAGI_HOME}/sign_log.json — single u64 last_signed_slot,
// plus the unix timestamp when we last advanced it. Atomic write via
// temp-file + rename.
//
// Safety contract:
//   - check(slot) returns true only when slot > last_persisted
//   - record(slot) is called BEFORE the KES sign + persists to disk
//   - record() failures are logged but DO NOT crash the node — the
//     refusal gate still works in-memory if disk is full / read-only
//   - When sign_log.json is missing (first start) check(slot) accepts
//     any slot > 0 — behavior identical to pre-Task slashing-protection
//   - No env flag — always-on safety. Refusal gate is a hard invariant.

const std = @import("std");
const compat = @import("compat");

pub const State = struct {
    mu: compat.Mutex = .{},
    last_signed_slot: u64 = 0,
    last_signed_unix: i64 = 0,
    loaded: bool = false,
    refused_total: u64 = 0,
    persisted_total: u64 = 0,
    persist_fail_total: u64 = 0,
};

pub var g_state: State = .{};

fn pathBuf(buf: []u8) ?[]const u8 {
    const home = compat.getenv("TSUNAGI_HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/sign_log.json", .{home}) catch null;
}

/// Load on startup. No-op if TSUNAGI_HOME unset or file missing.
pub fn loadFromDisk() void {
    var pb: [512]u8 = undefined;
    const path = pathBuf(&pb) orelse return;

    g_state.mu.lock();
    defer g_state.mu.unlock();

    if (g_state.loaded) return;

    var f = compat.fs.cwd().openFile(path, .{}) catch {
        g_state.loaded = true;
        std.debug.print("SIGN_LOG_LOAD: no prior log; starting fresh\n", .{});
        return;
    };
    defer f.close();

    var buf: [256]u8 = undefined;
    const n = f.readAll(&buf) catch {
        g_state.loaded = true;
        return;
    };
    const data = buf[0..n];

    if (std.mem.indexOf(u8, data, "\"slot\"")) |k| {
        var i = k + 6;
        while (i < data.len and (data[i] == ' ' or data[i] == ':' or data[i] == '\t')) : (i += 1) {}
        var j = i;
        while (j < data.len and data[j] >= '0' and data[j] <= '9') : (j += 1) {}
        if (j > i) {
            if (std.fmt.parseUnsigned(u64, data[i..j], 10)) |v| {
                g_state.last_signed_slot = v;
            } else |_| {}
        }
    }
    if (std.mem.indexOf(u8, data, "\"unix\"")) |k| {
        var i = k + 6;
        while (i < data.len and (data[i] == ' ' or data[i] == ':' or data[i] == '\t')) : (i += 1) {}
        var j = i;
        while (j < data.len and data[j] >= '0' and data[j] <= '9') : (j += 1) {}
        if (j > i) {
            if (std.fmt.parseInt(i64, data[i..j], 10)) |v| {
                g_state.last_signed_unix = v;
            } else |_| {}
        }
    }
    g_state.loaded = true;
    std.debug.print("SIGN_LOG_LOAD: last_signed_slot={d} last_signed_unix={d}\n", .{
        g_state.last_signed_slot, g_state.last_signed_unix,
    });
}

/// True iff `slot` is strictly greater than the persisted last-signed slot.
/// Returns false when refusal applies; caller MUST NOT proceed to sign.
pub fn check(slot: u64) bool {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    if (slot > g_state.last_signed_slot) return true;
    g_state.refused_total += 1;
    std.debug.print("SIGN_REFUSED: slot={d} last={d}\n", .{ slot, g_state.last_signed_slot });
    return false;
}

/// Persist the new highest-signed slot to disk via atomic temp + rename.
/// Updates the in-memory counter EVEN IF the disk write fails so the
/// refusal gate still works in-process.
pub fn record(slot: u64) void {
    g_state.mu.lock();
    g_state.last_signed_slot = slot;
    g_state.last_signed_unix = compat.timestamp();
    const slot_to_write = slot;
    const unix_to_write = g_state.last_signed_unix;
    g_state.mu.unlock();

    const ok = persistAtomic(slot_to_write, unix_to_write);
    g_state.mu.lock();
    defer g_state.mu.unlock();
    if (ok) {
        g_state.persisted_total += 1;
    } else {
        g_state.persist_fail_total += 1;
    }
}

fn persistAtomic(slot: u64, unix_ts: i64) bool {
    var pb: [512]u8 = undefined;
    const path = pathBuf(&pb) orelse return false;

    var tmp_buf: [520]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return false;

    var body_buf: [128]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{{\"slot\":{d},\"unix\":{d}}}\n", .{ slot, unix_ts }) catch return false;

    {
        var f = compat.fs.cwd().createFile(tmp_path, .{ .truncate = true }) catch |err| {
            std.debug.print("SIGN_LOG_PERSIST_FAIL: stage=create err={s}\n", .{@errorName(err)});
            return false;
        };
        defer f.close();
        f.writeAll(body) catch |err| {
            std.debug.print("SIGN_LOG_PERSIST_FAIL: stage=write err={s}\n", .{@errorName(err)});
            return false;
        };
    }
    compat.fs.cwd().rename(tmp_path, path) catch |err| {
        std.debug.print("SIGN_LOG_PERSIST_FAIL: stage=rename err={s}\n", .{@errorName(err)});
        return false;
    };
    return true;
}

pub fn renderJson(buf: []u8) usize {
    g_state.mu.lock();
    defer g_state.mu.unlock();
    var w = compat.fixedBufferStream(buf);
    w.writer().print(
        "{{\"last_signed_slot\":{d},\"last_signed_unix\":{d},\"loaded\":{s},\"refused_total\":{d},\"persisted_total\":{d},\"persist_fail_total\":{d}}}",
        .{
            g_state.last_signed_slot,
            g_state.last_signed_unix,
            if (g_state.loaded) "true" else "false",
            g_state.refused_total,
            g_state.persisted_total,
            g_state.persist_fail_total,
        },
    ) catch {};
    return w.pos;
}

// ── Tests ──

test "check accepts slot > last_signed" {
    g_state = .{};
    g_state.last_signed_slot = 100;
    g_state.loaded = true;
    try std.testing.expect(check(101));
    try std.testing.expectEqual(@as(u64, 0), g_state.refused_total);
}

test "check refuses slot <= last_signed and counts" {
    g_state = .{};
    g_state.last_signed_slot = 200;
    g_state.loaded = true;
    try std.testing.expect(!check(200));
    try std.testing.expect(!check(199));
    try std.testing.expectEqual(@as(u64, 2), g_state.refused_total);
}

test "check accepts any positive slot when state is fresh" {
    g_state = .{};
    g_state.loaded = true;
    try std.testing.expect(check(1));
    try std.testing.expect(check(1_000_000));
}

test "record updates in-memory counter even if persist fails" {
    g_state = .{};
    g_state.loaded = true;
    // No TSUNAGI_HOME → persist returns false. In-memory must still advance.
    record(500);
    try std.testing.expectEqual(@as(u64, 500), g_state.last_signed_slot);
    try std.testing.expect(g_state.persist_fail_total >= 1);
}
