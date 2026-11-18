// Peer-rotation loop helper for the ChainSync follower (PR-D).
//
// Discovers a list of upstream peers from (in order):
//   1. TSUNAGI_PEER_PRIMARY env var (host:port)
//   2. --peer CLI flag (host:port) — passed in as primary_override
//   3. ${TSUNAGI_HOME}/peers.json — JSON array `["host:port", ...]` or
//      legacy `{"peers":[{"host":"x","port":N}, ...]}` (peer_config.zig).
//   4. Hardcoded preview fallback list — IOG-published preview relays.
//   5. profile.default_relay_host:port (always appended for non-preview nets).
//
// Provides a fixed-size bounded list, a rotate-on-failure helper, and the
// canonical exponential-backoff schedule (2s → 5s → 15s → 60s cap).
//
// No allocator ownership: peer entries are bounded byte buffers. The caller
// owns the list value and may pass it into chainsync_mux_smoke.runWithOptions
// per iteration.

const std = @import("std");
const compat = @import("compat");

pub const MAX_PEERS: usize = 8;

pub const PeerEntry = struct {
    host_buf: [128]u8 = undefined,
    host_len: u8 = 0,
    port: u16 = 3001,

    pub fn host(self: *const PeerEntry) []const u8 {
        return self.host_buf[0..self.host_len];
    }

    fn setHostPort(self: *PeerEntry, h: []const u8, p: u16) bool {
        if (h.len == 0 or h.len > self.host_buf.len) return false;
        @memcpy(self.host_buf[0..h.len], h);
        self.host_len = @intCast(h.len);
        self.port = p;
        return true;
    }
};

pub const PeerList = struct {
    entries: [MAX_PEERS]PeerEntry = undefined,
    count: usize = 0,

    fn append(self: *PeerList, h: []const u8, p: u16) void {
        if (self.count >= MAX_PEERS) return;
        // Dedupe — skip if already present.
        for (self.entries[0..self.count]) |*e| {
            if (e.port == p and std.mem.eql(u8, e.host(), h)) return;
        }
        var entry = PeerEntry{};
        if (entry.setHostPort(h, p)) {
            self.entries[self.count] = entry;
            self.count += 1;
        }
    }
};

/// Parse "host:port" → (host, port). Returns null on malformed input.
fn parseHostPort(s: []const u8) ?struct { host: []const u8, port: u16 } {
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return null;
    if (colon == 0 or colon + 1 >= s.len) return null;
    const host = s[0..colon];
    const port_str = s[colon + 1 ..];
    const port = std.fmt.parseUnsigned(u16, port_str, 10) catch return null;
    if (port == 0) return null;
    return .{ .host = host, .port = port };
}

/// Parse a flat JSON-array form: `["host:port", "host:port", ...]`.
/// Tolerant: ignores whitespace, accepts double-quoted strings.
fn parsePeersJsonArray(data: []const u8, list: *PeerList) bool {
    var i: usize = 0;
    while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == '\n' or data[i] == '\r')) i += 1;
    if (i >= data.len or data[i] != '[') return false;
    i += 1;
    while (i < data.len) {
        // Skip ws + commas
        while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == '\n' or data[i] == '\r' or data[i] == ',')) i += 1;
        if (i >= data.len) return false;
        if (data[i] == ']') return true;
        if (data[i] != '"') return false;
        i += 1;
        const start = i;
        while (i < data.len and data[i] != '"') i += 1;
        if (i >= data.len) return false;
        const entry = data[start..i];
        i += 1;
        if (parseHostPort(entry)) |hp| list.append(hp.host, hp.port);
    }
    return false;
}

/// Try ${home}/peers.json. Accepts the simple array shape first; if that
/// fails, attempts the legacy peer_config.zig nested shape via substring
/// scan to keep one-file pre-existing peers.json files working.
fn loadFromFile(home: []const u8, list: *PeerList) bool {
    var pbuf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/peers.json", .{home}) catch return false;
    var f = compat.fs.cwd().openFile(path, .{}) catch return false;
    defer f.close();
    var buf: [4096]u8 = undefined;
    const n = f.readAll(&buf) catch return false;
    if (n == 0) return false;
    const data = buf[0..n];

    // Try simple array form.
    var probe = list.*;
    if (parsePeersJsonArray(data, &probe)) {
        list.* = probe;
        std.debug.print("PEER_LIST_LOADED: source=peers_json_array path={s} count={d}\n", .{ path, list.count });
        return list.count > 0;
    }

    // Legacy nested form: {"peers":[{"host":"x","port":N}, ...]}.
    // Substring scan; keeps this module allocator-free.
    if (std.mem.indexOf(u8, data, "\"peers\"") != null) {
        var pos: usize = 0;
        while (pos < data.len) {
            const obj_start = std.mem.indexOfScalarPos(u8, data, pos, '{') orelse break;
            const obj_end = std.mem.indexOfScalarPos(u8, data, obj_start, '}') orelse break;
            const obj = data[obj_start .. obj_end + 1];
            pos = obj_end + 1;
            const h = extractStringField(obj, "host") orelse continue;
            const p_u64 = extractIntField(obj, "port") orelse 3001;
            if (p_u64 == 0 or p_u64 > 65535) continue;
            list.append(h, @intCast(p_u64));
        }
        if (list.count > 0) {
            std.debug.print("PEER_LIST_LOADED: source=peers_json_legacy path={s} count={d}\n", .{ path, list.count });
            return true;
        }
    }
    return false;
}

fn extractStringField(obj: []const u8, key: []const u8) ?[]const u8 {
    var kbuf: [64]u8 = undefined;
    const kw = std.fmt.bufPrint(&kbuf, "\"{s}\"", .{key}) catch return null;
    const kpos = std.mem.indexOf(u8, obj, kw) orelse return null;
    var i = kpos + kw.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == ':' or obj[i] == '\t')) i += 1;
    if (i >= obj.len or obj[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < obj.len and obj[i] != '"') i += 1;
    if (i >= obj.len) return null;
    return obj[start..i];
}

fn extractIntField(obj: []const u8, key: []const u8) ?u64 {
    var kbuf: [64]u8 = undefined;
    const kw = std.fmt.bufPrint(&kbuf, "\"{s}\"", .{key}) catch return null;
    const kpos = std.mem.indexOf(u8, obj, kw) orelse return null;
    var i = kpos + kw.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == ':' or obj[i] == '\t')) i += 1;
    const start = i;
    while (i < obj.len and obj[i] >= '0' and obj[i] <= '9') i += 1;
    if (i == start) return null;
    return std.fmt.parseUnsigned(u64, obj[start..i], 10) catch null;
}

/// Hardcoded preview fallback. IOG-published relays.
fn appendPreviewFallback(list: *PeerList) void {
    list.append("preview-node.play.dev.cardano.org", 3001);
    list.append("preview-node.world.dev.cardano.org", 30002);
}

/// Build the resolved peer list. Order is: env primary → CLI primary →
/// peers.json → preview fallback (when net=preview) → profile default.
/// Returns a list with `count >= 1` unless every source is empty AND no
/// profile default exists (caller treats empty as fatal).
pub fn buildPeerList(
    home: []const u8,
    net_name: []const u8,
    profile_default_host: []const u8,
    profile_default_port: u16,
    primary_override: ?[]const u8, // "host:port" from --peer flag, may be null
) PeerList {
    var list = PeerList{};

    // 1. TSUNAGI_PEER_PRIMARY env (highest priority).
    if (compat.getenv("TSUNAGI_PEER_PRIMARY")) |env_val| {
        if (parseHostPort(env_val)) |hp| {
            list.append(hp.host, hp.port);
            std.debug.print("PEER_PRIMARY_ENV: host={s} port={d}\n", .{ hp.host, hp.port });
        }
    }

    // 2. --peer CLI override.
    if (primary_override) |val| {
        if (parseHostPort(val)) |hp| {
            list.append(hp.host, hp.port);
        }
    }

    // 3. peers.json file.
    _ = loadFromFile(home, &list);

    // 4. Preview fallback (only when net=preview and not already covered).
    if (std.mem.eql(u8, net_name, "preview")) {
        appendPreviewFallback(&list);
    }

    // 5. profile.default_relay (always appended; deduped against primary).
    if (profile_default_host.len > 0) {
        list.append(profile_default_host, profile_default_port);
    }

    std.debug.print("PEER_LIST_RESOLVED: count={d}\n", .{list.count});
    var i: usize = 0;
    while (i < list.count) : (i += 1) {
        const e = &list.entries[i];
        std.debug.print("PEER_LIST[{d}]: host={s} port={d}\n", .{ i, e.host(), e.port });
    }
    return list;
}

/// Backoff schedule: 2s → 5s → 15s → 60s cap. `attempt` is 0-indexed
/// consecutive failure count.
pub fn backoffMs(attempt: u32) u64 {
    return switch (attempt) {
        0 => 2_000,
        1 => 5_000,
        2 => 15_000,
        else => 60_000,
    };
}

/// Round-robin index advance.
pub fn rotateIdx(idx: usize, count: usize) usize {
    if (count == 0) return 0;
    return (idx + 1) % count;
}
