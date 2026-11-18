// Ouroboros Node-to-Client LocalStateQuery (proto 7) — minimal client.
//
// Purpose: query a LOCAL cardano-node's ledger state via Unix socket so
// TSUNAGI can validate opcert counters, fetch protocol params, and
// observe chain tip without the ~5-minute Koios lag.
//
// Safety: every operation returns a typed error. Callers MUST be prepared
// to fall back to Koios on any failure — NtC is a best-effort supplement,
// not a hard dependency.
//
// Enablement: gated at the caller site via TSUNAGI_NTC_ENABLE=1 +
// TSUNAGI_NTC_SOCKET=/path/to/node.socket.
//
// Wire format references (as of 2026-04):
//   - NtC versions: IntersectMBO/ouroboros-network node-to-client
//   - LSQ CDDL: IntersectMBO/ouroboros-consensus (query.cddl)
//   - Mux segment format: already implemented in src/net/muxwire/mux_bearer.zig

const std = @import("std");
const compat = @import("compat");
const cbor = @import("../cbor/term.zig");
const handshake_codec = @import("../handshake/handshake_codec.zig");
const mux_bearer = @import("../muxwire/mux_bearer.zig");
const byte_transport = @import("../transport/byte_transport.zig");
const unix_bt = @import("unix_byte_transport.zig");

pub const HANDSHAKE_PROTO: u16 = 0;
pub const LSQ_PROTO: u16 = 7;

/// NtC version numbers on the wire are `0x8000 + N` where N is the logical
/// NtC version. v16 introduced `query: bool` in version_data and the
/// "acquire-tip" tag shape used by Conway-era queries.
pub const NTC_VER_16: u64 = 32784;
pub const NTC_VER_17: u64 = 32785;
pub const NTC_VER_18: u64 = 32786;

/// Conway era integer (Byron=0, Shelley=1, Allegra=2, Mary=3, Alonzo=4,
/// Babbage=5, Conway=6). Used in LedgerQuery::BlockQuery era-wrapper.
pub const CONWAY_ERA: u64 = 6;

/// LedgerQuery::BlockQuery tag for GetCurrentPParams.
pub const BQ_GET_CURRENT_PPARAMS: u64 = 3;

/// LedgerQuery::BlockQuery tag for GetStakePoolParams.
///
/// Ouroboros LSQ exposes this query for retrieving Conway-era pool registration
/// fields (pledge, fixed cost, margin, owners, reward account) keyed by pool
/// keyhash. The exact integer constant on the wire varies between consensus
/// versions; the scaffolding below ENCODES our best-known shape (tag value
/// `17` from `ouroboros-consensus-cardano::ShelleyLedgerQueries`) but the
/// decoder is deliberately strict and falls through to `NotImplemented` if
/// the response shape does not match. Callers MUST treat NtC pool params as
/// best-effort and fall back to Koios on any failure.
pub const BQ_GET_STAKE_POOL_PARAMS: u64 = 17;

pub const LsqError = error{
    SocketUnavailable,
    HandshakeFailed,
    HandshakeRefused,
    VersionUnsupported,
    AcquireFailed,
    QueryFailed,
    DecodeFailed,
    Timeout,
    ProtocolMismatch,
    NotImplemented,
};

/// Minimal protocol parameters we care about. Extracted from
/// GetProtocolParameters result. Any field that fails to parse is left at
/// its zero value and the caller decides whether to accept a partial result.
pub const ProtoParams = struct {
    max_block_body_size: u64 = 0,
    max_tx_size: u64 = 0,
    min_fee_a: u64 = 0,
    min_fee_b: u64 = 0,
    protocol_major: u16 = 0,
    protocol_minor: u16 = 0,
    coins_per_utxo_byte: u64 = 0,
};

/// Conway-era stake pool registration fields surfaced for operator UX. We
/// only decode the scalar fields the dashboard needs (pledge / fixed cost /
/// margin). Owners, reward account, relay list, metadata are intentionally
/// out of scope here and remain the responsibility of higher-level Koios /
/// db-sync queries when needed.
pub const PoolParams = struct {
    pool_id: [28]u8 = std.mem.zeroes([28]u8),
    pledge: u64 = 0,
    cost_per_block: u64 = 0,
    /// Margin expressed as fixed-point parts-per-billion (0..1_000_000_000).
    margin_x1e9: u64 = 0,
    /// Reserved for the on-wire reward-account header byte. Zero until decoded.
    reward_account_kind: u8 = 0,
};

/// A single NtC session over a Unix socket. Not thread-safe; one session per
/// caller. Short-lived: open → acquire → query → release → close.
pub const Session = struct {
    alloc: std.mem.Allocator,
    bt: byte_transport.ByteTransport,
    network_magic: u64,
    negotiated_version: u64,
    acquired: bool,

    pub fn deinit(self: *Session) void {
        // Best-effort send of MsgRelease (if acquired) + MsgDone.
        if (self.acquired) self.sendRelease() catch {};
        self.sendDone() catch {};
        self.bt.deinit();
    }

    fn sendLsqPayload(self: *Session, payload: []const u8) !void {
        try mux_bearer.sendSegment(&self.bt, .initiator, LSQ_PROTO, payload);
    }

    fn recvLsqMessage(self: *Session) !cbor.Term {
        const seg_opt = try mux_bearer.recvSegmentWithTimeout(self.alloc, &self.bt);
        const seg = seg_opt orelse return error.Timeout;
        // Caller owns the payload buffer; decode into a Term then free raw bytes.
        var fbs = compat.fixedBufferStream(seg.payload);
        const term = try cbor.decode(self.alloc, fbs.reader());
        self.alloc.free(seg.payload);
        return term;
    }

    fn sendRelease(self: *Session) !void {
        // MsgRelease = [5]
        const bytes = [_]u8{ 0x81, 0x05 };
        try self.sendLsqPayload(&bytes);
        self.acquired = false;
    }

    fn sendDone(self: *Session) !void {
        // MsgDone = [7]
        const bytes = [_]u8{ 0x81, 0x07 };
        try self.sendLsqPayload(&bytes);
    }

    /// Send MsgAcquireVolatileTip = [8]. Wait for MsgAcquired [1] or
    /// MsgFailure [2, reason].
    fn acquireTip(self: *Session) LsqError!void {
        const bytes = [_]u8{ 0x81, 0x08 };
        self.sendLsqPayload(&bytes) catch return LsqError.AcquireFailed;
        const term = self.recvLsqMessage() catch return LsqError.AcquireFailed;
        defer cbor.free(term, self.alloc);
        if (term != .array or term.array.len == 0) return LsqError.DecodeFailed;
        if (term.array[0] != .u64) return LsqError.DecodeFailed;
        const tag = term.array[0].u64;
        if (tag == 1) {
            self.acquired = true;
            return;
        }
        return LsqError.AcquireFailed;
    }

    /// Query GetProtocolParameters for Conway era. Wire:
    ///   MsgQuery = [3, [0, [0, [6, [3]]]]]
    ///     = 82 03 82 00 82 00 82 06 81 03
    /// Response: MsgResult = [4, <pparams_map>].
    pub fn queryProtocolParams(self: *Session) LsqError!ProtoParams {
        if (!self.acquired) {
            try self.acquireTip();
        }
        // Exact byte sequence from LSQ spec for Conway GetCurrentPParams.
        const query_bytes = [_]u8{ 0x82, 0x03, 0x82, 0x00, 0x82, 0x00, 0x82, 0x06, 0x81, 0x03 };
        self.sendLsqPayload(&query_bytes) catch return LsqError.QueryFailed;
        const term = self.recvLsqMessage() catch return LsqError.QueryFailed;
        defer cbor.free(term, self.alloc);

        if (term != .array or term.array.len < 2) return LsqError.DecodeFailed;
        if (term.array[0] != .u64 or term.array[0].u64 != 4) return LsqError.DecodeFailed;
        const result = term.array[1];
        return decodeProtocolParams(result);
    }

    /// Query GetStakePoolParams for a single pool (28-byte keyhash). Wire shape
    /// (Conway era, best-known):
    ///   MsgQuery = [3, [0, [0, [6, [BQ_GET_STAKE_POOL_PARAMS, [<pool_id_bytes>]]]]]]
    /// The set of pool ids is encoded as a CBOR array of byte strings; our
    /// caller only ever needs one entry.
    ///
    /// Response: MsgResult = [4, <map { pool_id => pool_params_struct }>].
    /// We deliberately keep the decoder narrow — anything we cannot make
    /// sense of returns `NotImplemented` so the caller falls back to Koios.
    pub fn queryStakePoolParams(self: *Session, pool_id: [28]u8) LsqError!PoolParams {
        if (!self.acquired) {
            try self.acquireTip();
        }
        const payload = encodePoolParamsQuery(self.alloc, pool_id) catch return LsqError.QueryFailed;
        defer self.alloc.free(payload);
        self.sendLsqPayload(payload) catch return LsqError.QueryFailed;
        const term = self.recvLsqMessage() catch return LsqError.QueryFailed;
        defer cbor.free(term, self.alloc);

        if (term != .array or term.array.len < 2) return LsqError.DecodeFailed;
        if (term.array[0] != .u64 or term.array[0].u64 != 4) return LsqError.DecodeFailed;
        return decodePoolParamsResponse(term.array[1], pool_id) catch |err| {
            std.debug.print("LSQ_POOL_PARAMS_UNSUPPORTED: response shape mismatch err={s}\n", .{@errorName(err)});
            return LsqError.NotImplemented;
        };
    }
};

/// Decode a Conway PParams CBOR map into our minimal struct. Key mapping
/// per Pallas queries_v16::ProtocolParam (via authoritative research):
///   0 minfee_a         12 protocol_version [major, minor]
///   1 minfee_b         14 coins_per_utxo_byte
///   2 max_block_body_size   3 max_tx_size
fn decodeProtocolParams(term: cbor.Term) LsqError!ProtoParams {
    if (term != .map_u64) return LsqError.DecodeFailed;
    var out: ProtoParams = .{};
    for (term.map_u64) |entry| {
        switch (entry.key) {
            0 => if (entry.value == .u64) { out.min_fee_a = entry.value.u64; },
            1 => if (entry.value == .u64) { out.min_fee_b = entry.value.u64; },
            2 => if (entry.value == .u64) { out.max_block_body_size = entry.value.u64; },
            3 => if (entry.value == .u64) { out.max_tx_size = entry.value.u64; },
            12 => if (entry.value == .array and entry.value.array.len >= 2) {
                if (entry.value.array[0] == .u64) out.protocol_major = @intCast(entry.value.array[0].u64);
                if (entry.value.array[1] == .u64) out.protocol_minor = @intCast(entry.value.array[1].u64);
            },
            14 => if (entry.value == .u64) { out.coins_per_utxo_byte = entry.value.u64; },
            else => {},
        }
    }
    if (out.max_block_body_size == 0 and out.protocol_major == 0) return LsqError.DecodeFailed;
    return out;
}

/// Encode `MsgQuery [3, [0, [0, [6, [BQ_GET_STAKE_POOL_PARAMS, [<pool_id>]]]]]]`
/// into a heap-allocated byte slice the caller must free. We hand-roll the
/// CBOR — the wire is deterministic and small (35-40 bytes) so an array list
/// with the encoder helpers is overkill.
fn encodePoolParamsQuery(alloc: std.mem.Allocator, pool_id: [28]u8) ![]u8 {
    // Outer wrappers + inner header. Worst-case layout (BQ tag <= 255):
    //   82 03                 [3, _]
    //   82 00                 [0, _]
    //   82 00                 [0, _]
    //   82 06                 [6, _]   Conway era
    //   82                    array(2) for [BQ_tag, [pool_id]]
    //   18 NN                 BQ tag (u8 immediate, 2 bytes when > 23)
    //   81                    array(1)
    //   58 1C <28 bytes>      bytes(28)
    // = 2+2+2+2+1+2+1+2+28 = 42 bytes.
    var buf = try alloc.alloc(u8, 48);
    errdefer alloc.free(buf);
    var i: usize = 0;
    buf[i] = 0x82; i += 1; buf[i] = 0x03; i += 1;
    buf[i] = 0x82; i += 1; buf[i] = 0x00; i += 1;
    buf[i] = 0x82; i += 1; buf[i] = 0x00; i += 1;
    buf[i] = 0x82; i += 1; buf[i] = 0x06; i += 1;
    buf[i] = 0x82; i += 1;
    // BQ_GET_STAKE_POOL_PARAMS — encoded as immediate u8 (24..255 range uses
    // major-0 + addl=24 + 1 length byte).
    if (BQ_GET_STAKE_POOL_PARAMS <= 23) {
        buf[i] = @intCast(BQ_GET_STAKE_POOL_PARAMS); i += 1;
    } else if (BQ_GET_STAKE_POOL_PARAMS <= 255) {
        buf[i] = 0x18; i += 1;
        buf[i] = @intCast(BQ_GET_STAKE_POOL_PARAMS); i += 1;
    } else {
        // Wider tag encodings unsupported here — would need a different
        // scaffolding shape. Caller will see QueryFailed.
        return error.InvalidQuery;
    }
    buf[i] = 0x81; i += 1;        // array(1)
    buf[i] = 0x58; i += 1;        // bytes(uint8 length)
    buf[i] = 0x1C; i += 1;        // 28
    @memcpy(buf[i .. i + 28], &pool_id);
    i += 28;
    // Shrink to actual length so callers can free the exact slice they got.
    if (alloc.resize(buf, i)) {
        return buf[0..i];
    }
    const tight = try alloc.alloc(u8, i);
    @memcpy(tight, buf[0..i]);
    alloc.free(buf);
    return tight;
}

/// Decode a `MsgResult` body into our `PoolParams`. We accept either:
///   - a map { pool_id_bytes => pool_params_value }
///   - a single bare pool_params_value
/// Pool params value layout (Conway):
///   [operator_keyhash, vrf_keyhash, pledge, cost, margin_unit_interval, ...]
/// where margin is a CBOR-tagged rational (tag 30) `[numerator, denominator]`.
/// Anything that does not match returns `error.UnsupportedShape`, which the
/// caller maps to `LsqError.NotImplemented` so we cleanly fall back to Koios.
fn decodePoolParamsResponse(result: cbor.Term, want: [28]u8) !PoolParams {
    var out: PoolParams = .{ .pool_id = want };
    const params_term: cbor.Term = blk: {
        if (result == .map_u64) {
            // Pool params responses use bytes keys, not u64 — our cbor decoder
            // only models u64-keyed maps natively. Fall through.
            return error.UnsupportedShape;
        }
        if (result == .array) break :blk result;
        return error.UnsupportedShape;
    };
    if (params_term.array.len < 5) return error.UnsupportedShape;
    // Index 2 = pledge, 3 = cost. Index 4 = margin (tag 30 [num, den]).
    if (params_term.array[2] == .u64) out.pledge = params_term.array[2].u64;
    if (params_term.array[3] == .u64) out.cost_per_block = params_term.array[3].u64;
    if (params_term.array[4] == .tag) {
        const inner = params_term.array[4].tag.value.*;
        if (inner == .array and inner.array.len == 2 and
            inner.array[0] == .u64 and inner.array[1] == .u64 and
            inner.array[1].u64 != 0)
        {
            const num: u128 = inner.array[0].u64;
            const den: u128 = inner.array[1].u64;
            const scaled: u128 = (num * 1_000_000_000) / den;
            out.margin_x1e9 = @intCast(@min(scaled, 1_000_000_000));
        }
    }
    return out;
}

/// Open a session: dial the socket, negotiate NtC v16+. Returns `LsqError`
/// without leaking resources on failure.
pub fn openSession(alloc: std.mem.Allocator, socket_path: []const u8, network_magic: u64) LsqError!Session {
    var bt = unix_bt.connectUnix(alloc, socket_path) catch |err| {
        std.debug.print("NTC_CONNECT_FAIL: path={s} err={s}\n", .{ socket_path, @errorName(err) });
        return LsqError.SocketUnavailable;
    };
    errdefer bt.deinit();

    // 30-second handshake timeout.
    unix_bt.setReadTimeout(&bt, 30_000) catch {};

    const version = doHandshake(alloc, &bt, network_magic) catch |err| {
        std.debug.print("NTC_HANDSHAKE_FAIL: err={s}\n", .{@errorName(err)});
        return LsqError.HandshakeFailed;
    };

    std.debug.print("NTC_SESSION_OPEN: path={s} version={d} magic={d}\n", .{ socket_path, version, network_magic });

    return .{
        .alloc = alloc,
        .bt = bt,
        .network_magic = network_magic,
        .negotiated_version = version,
        .acquired = false,
    };
}

/// NtC handshake: propose v16..v18 (wire: 32784..32786) with
/// version_data = [network_magic, query=false]. Returns the negotiated
/// wire version number on success.
fn doHandshake(alloc: std.mem.Allocator, bt: *byte_transport.ByteTransport, network_magic: u64) !u64 {
    var entries: [3]cbor.MapEntry = undefined;
    var version_datas: [3][2]cbor.Term = undefined;
    const versions = [_]u64{ NTC_VER_16, NTC_VER_17, NTC_VER_18 };
    for (versions, 0..) |v, i| {
        version_datas[i][0] = .{ .u64 = network_magic };
        version_datas[i][1] = .{ .bool = false }; // query=false → normal session
        entries[i] = .{ .key = v, .value = .{ .array = version_datas[i][0..] } };
    }
    const propose = handshake_codec.HandshakeMsg{
        .propose = .{ .versions = .{ .map_u64 = entries[0..] } },
    };

    var payload = std.array_list.Managed(u8).init(alloc);
    defer payload.deinit();
    try handshake_codec.encodeMsg(propose, compat.listWriter(&payload));

    try mux_bearer.sendSegment(bt, .initiator, HANDSHAKE_PROTO, payload.items);

    const seg_opt = try mux_bearer.recvSegmentWithTimeout(alloc, bt);
    const seg = seg_opt orelse return error.HandshakeFailed;
    defer alloc.free(seg.payload);

    var fbs = compat.fixedBufferStream(seg.payload);
    var msg = handshake_codec.decodeMsg(alloc, fbs.reader()) catch return error.HandshakeFailed;
    defer handshake_codec.free(alloc, &msg);

    switch (msg) {
        .accept => |ac| {
            if (ac.version < NTC_VER_16 or ac.version > NTC_VER_18) return error.VersionUnsupported;
            return ac.version;
        },
        .refuse => return error.HandshakeRefused,
        else => return error.HandshakeFailed,
    }
}

test "LsqError includes NotImplemented for fallback semantics" {
    const err: LsqError = LsqError.NotImplemented;
    try std.testing.expect(err == LsqError.NotImplemented);
}

test "encodePoolParamsQuery emits expected wrapper bytes" {
    const alloc = std.testing.allocator;
    var pool_id: [28]u8 = undefined;
    @memset(&pool_id, 0xAB);
    const bytes = try encodePoolParamsQuery(alloc, pool_id);
    defer alloc.free(bytes);
    // BQ tag 17 is <= 23 so it fits in a single immediate byte. That gives
    // 13 wrapper bytes + 28 pool_id bytes = 41 total.
    try std.testing.expectEqual(@as(usize, 41), bytes.len);
    try std.testing.expectEqual(@as(u8, 0x82), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x03), bytes[1]);
    try std.testing.expectEqual(@as(u8, 0x06), bytes[7]); // Conway era marker
    try std.testing.expectEqual(@as(u8, 0x82), bytes[8]); // array(2) [BQ_tag, args]
    try std.testing.expectEqual(@as(u8, 0x11), bytes[9]); // BQ tag 17 (single byte)
    try std.testing.expectEqual(@as(u8, 0x81), bytes[10]); // array(1)
    try std.testing.expectEqual(@as(u8, 0x58), bytes[11]); // bytes(uint8 length)
    try std.testing.expectEqual(@as(u8, 0x1C), bytes[12]); // 28
    try std.testing.expectEqual(@as(u8, 0xAB), bytes[13]);
}

test "decodePoolParamsResponse extracts pledge cost margin from synthetic array" {
    const alloc = std.testing.allocator;
    var pool_id: [28]u8 = undefined;
    @memset(&pool_id, 0x07);

    // Build synthetic [op_kh, vrf_kh, 5_000_000_000, 340_000_000, tag(30, [3, 100])]
    var op_kh = [_]u8{0} ** 28;
    var vrf_kh = [_]u8{0} ** 32;
    const margin_inner_terms = try alloc.alloc(cbor.Term, 2);
    margin_inner_terms[0] = .{ .u64 = 3 };
    margin_inner_terms[1] = .{ .u64 = 100 };
    const inner_term_ptr = try alloc.create(cbor.Term);
    inner_term_ptr.* = .{ .array = margin_inner_terms };
    defer alloc.destroy(inner_term_ptr);
    defer alloc.free(margin_inner_terms);

    var arr = [_]cbor.Term{
        .{ .bytes = &op_kh },
        .{ .bytes = &vrf_kh },
        .{ .u64 = 5_000_000_000 },
        .{ .u64 = 340_000_000 },
        .{ .tag = .{ .tag = 30, .value = inner_term_ptr } },
    };
    const result_term: cbor.Term = .{ .array = arr[0..] };
    const out = try decodePoolParamsResponse(result_term, pool_id);
    try std.testing.expectEqual(@as(u64, 5_000_000_000), out.pledge);
    try std.testing.expectEqual(@as(u64, 340_000_000), out.cost_per_block);
    // 3/100 = 30_000_000 in x1e9 fixed-point
    try std.testing.expectEqual(@as(u64, 30_000_000), out.margin_x1e9);
    try std.testing.expectEqualSlices(u8, &pool_id, &out.pool_id);
}
