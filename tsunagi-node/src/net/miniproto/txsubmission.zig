const std = @import("std");
const compat = @import("compat");
const cbor = @import("../cbor/term.zig");
const mux_bearer = @import("../muxwire/mux_bearer.zig");
const byte_transport = @import("../transport/byte_transport.zig");
const http_metrics = @import("../metrics/http_metrics.zig");
const mempool_mod = @import("../ledger/mempool.zig");

/// NtN TxSubmission2 mini-protocol (protocol ID 4)
///
/// Cardano NtN TxSubmission2 message IDs:
///   0 = MsgRequestTxIds (non-blocking)  (server → client)
///   1 = MsgRequestTxIds (blocking)      (server → client)
///   2 = MsgReplyTxIds                   (client → server)
///   3 = MsgRequestTxs                   (server → client)
///   4 = MsgReplyTxs                     (client → server)
///   5 = MsgDone                         (client → server)
///   6 = MsgInit                         (client → server)

const TXSUB_PROTO: u16 = 4;
const MAX_INV_ITEMS: usize = 128;
const MAX_REPLY_TXS: usize = 16;
const MAX_REPLY_BYTES: usize = 256 * 1024;

pub var g_metrics: ?*http_metrics.Metrics = null;
pub var g_mempool: ?*mempool_mod.Mempool = null;
var g_last_error_log_unix: i64 = 0;

// ── State machine ───────────────────────────────────────────────────

pub const TxSubState = enum(u8) {
    Idle = 0,
    Active = 1,
    Done = 2,

    pub fn label(self: TxSubState) []const u8 {
        return switch (self) {
            .Idle => "IDLE",
            .Active => "ACTIVE",
            .Done => "DONE",
        };
    }

    pub fn code(self: TxSubState) u64 {
        return @intFromEnum(self);
    }
};

var g_state: TxSubState = .Idle;

// Session state (respond-only: peer must speak first)
var g_session_active: bool = false;
var g_session_first_unix: i64 = 0;
var g_last_msg_unix: i64 = 0;
var g_counted_session: bool = false;

// Passive observability (cumulative — survive reset)
var g_rx_msgs_total: u64 = 0;
var g_rx_bytes_total: u64 = 0;

// Msg-ID census (cumulative — survive reset)
var g_msg_id_counts: [16]u64 = [_]u64{0} ** 16;
var g_msg_id_unknown_total: u64 = 0;

// State machine + shape counters (cumulative — survive reset)
var g_known_total: u64 = 0;
var g_ignored_total: u64 = 0;
var g_invalid_shape_total: u64 = 0;
var g_state_idle_total: u64 = 1; // start in Idle
var g_state_active_total: u64 = 0;
var g_state_done_total: u64 = 0;

// Passive observability (per-session — cleared on reset)
var g_session_rx_msgs: u64 = 0;
var g_session_rx_bytes: u64 = 0;
var g_session_first_msg_id: u64 = std.math.maxInt(u64);
var g_session_first_msg_unix: i64 = 0;
var g_last_log_unix: i64 = 0;

// Outbound broadcast state
var g_last_broadcast_unix: i64 = 0;
var g_last_seen_change_seq: u64 = 0;

// ── Shape validation ────────────────────────────────────────────────

/// Validate the CBOR shape of a known TxSubmission2 message.
/// Returns true if the shape is acceptable. Does NOT crash on invalid shape.
fn validateShape(msg_id: u64, arr: []cbor.Term) bool {
    return switch (msg_id) {
        0, 1 => arr.len >= 1, // MsgRequestTxIds: [id, ...] (tolerate any trailing)
        2 => arr.len >= 1, // MsgReplyTxIds: [id, ...]
        3 => arr.len >= 2 and arr[1] == .array, // MsgRequestTxs: [3, array]
        4 => arr.len >= 2 and arr[1] == .array, // MsgReplyTxs: [4, array]
        5 => true, // MsgDone: [5] (tolerate trailing)
        6 => true, // MsgInit: [6] or [6, ...] (tolerate)
        else => false,
    };
}

fn isKnownMsgId(msg_id: u64) bool {
    return msg_id <= 6;
}

/// Handle an incoming TxSubmission mux segment.
/// Decodes top-level CBOR to identify the message, validates shape,
/// enforces state machine, responds to requests, and counts metrics.
/// Never crashes — decode failures are counted and the segment is dropped.
pub fn handleMessage(
    alloc: std.mem.Allocator,
    bt: *byte_transport.ByteTransport,
    payload: []const u8,
    debug: bool,
) void {
    if (g_metrics) |m| {
        _ = m.txsub_msgs_total.fetchAdd(1, .acq_rel);
    }

    // Passive observability: count all rx
    g_rx_msgs_total += 1;
    g_rx_bytes_total += payload.len;
    g_session_rx_msgs += 1;
    g_session_rx_bytes += payload.len;

    if (payload.len == 0) return;

    var fbs = compat.fixedBufferStream(payload);
    const term = cbor.decode(alloc, fbs.reader()) catch {
        if (g_metrics) |m| {
            _ = m.txsub_decode_errors_total.fetchAdd(1, .acq_rel);
        }
        rateLimitedLog("TXSUB: decode error len={d}\n", .{payload.len});
        return;
    };
    defer cbor.free(term, alloc);

    // Expect [msg_id, ...] array
    if (term != .array or term.array.len == 0) {
        if (g_metrics) |m| {
            _ = m.txsub_invalid_shape_total.fetchAdd(1, .acq_rel);
        }
        g_invalid_shape_total += 1;
        if (debug) std.debug.print("TXSUB: non-array message {s}\n", .{@tagName(term)});
        return;
    }

    const msg_id: u64 = if (term.array[0] == .u64) term.array[0].u64 else {
        if (g_metrics) |m| {
            _ = m.txsub_invalid_shape_total.fetchAdd(1, .acq_rel);
        }
        g_invalid_shape_total += 1;
        if (debug) std.debug.print("TXSUB: msg_id not u64\n", .{});
        g_msg_id_unknown_total += 1;
        return;
    };

    // Msg-ID census
    if (msg_id < 16) {
        g_msg_id_counts[@intCast(msg_id)] += 1;
    } else {
        g_msg_id_unknown_total += 1;
    }

    // Known vs unknown classification
    if (isKnownMsgId(msg_id)) {
        g_known_total += 1;
    }

    // Shape validation for known message IDs
    if (isKnownMsgId(msg_id) and !validateShape(msg_id, term.array)) {
        g_invalid_shape_total += 1;
        if (g_metrics) |m| {
            _ = m.txsub_invalid_shape_total.fetchAdd(1, .acq_rel);
        }
        rateLimitedLog("TXSUB: invalid shape msg_id={d} len={d}\n", .{ msg_id, term.array.len });
        // Do NOT crash, do NOT disconnect — observability only
        // Still allow state machine transition + processing to proceed for robustness
    }

    if (debug) {
        std.debug.print("TXSUB: msg_id={d} array_len={d} state={s}\n", .{ msg_id, term.array.len, g_state.label() });
    }

    // ── State machine transitions ──────────────────────────────────

    const now_ts = compat.timestamp();
    g_last_msg_unix = now_ts;

    // Idle → Active on any valid message
    if (g_state == .Idle and isKnownMsgId(msg_id)) {
        g_state = .Active;
        g_state_active_total += 1;
        g_session_active = true;
        g_session_first_unix = now_ts;
        std.debug.print("TXSUB: Idle→Active (rx msg_id={d})\n", .{msg_id});
    } else if (g_state == .Idle) {
        // Unknown msg while Idle — still transition to Active
        g_state = .Active;
        g_state_active_total += 1;
        g_session_active = true;
        g_session_first_unix = now_ts;
        std.debug.print("TXSUB: Idle→Active (rx unknown msg_id={d})\n", .{msg_id});
    }

    // Done state: only allow MsgDone, ignore everything else
    if (g_state == .Done and msg_id != 5) {
        g_ignored_total += 1;
        if (g_metrics) |m| {
            _ = m.txsub_ignored_total.fetchAdd(1, .acq_rel);
        }
        if (debug) std.debug.print("TXSUB: ignored msg_id={d} in Done state\n", .{msg_id});
        updateGauges(now_ts);
        return;
    }

    if (!g_counted_session) {
        g_counted_session = true;
        if (g_metrics) |m| {
            _ = m.txsub_sessions_total.fetchAdd(1, .acq_rel);
        }
    }
    // Track first message of session
    if (g_session_first_msg_unix == 0) {
        g_session_first_msg_unix = now_ts;
        g_session_first_msg_id = msg_id;
    }

    // Update gauges
    updateGauges(now_ts);

    // Rate-limited observability log (60s, only when session active)
    if (g_session_active and (now_ts - g_last_log_unix >= 60)) {
        g_last_log_unix = now_ts;
        std.debug.print("TXSUB CENSUS: state={s} id0={d} id1={d} id3={d} id4={d} id5={d} id6={d} unk={d} known={d} ignored={d} bad_shape={d} rx_msgs={d}\n", .{
            g_state.label(),
            g_msg_id_counts[0], g_msg_id_counts[1], g_msg_id_counts[3],
            g_msg_id_counts[4], g_msg_id_counts[5], g_msg_id_counts[6],
            g_msg_id_unknown_total, g_known_total, g_ignored_total, g_invalid_shape_total,
            g_session_rx_msgs,
        });
    }

    // ── Message dispatch ───────────────────────────────────────────

    switch (msg_id) {
        0, 1 => {
            // MsgRequestTxIds (0=non-blocking, 1=blocking) — respond with MsgReplyTxIds
            if (debug) std.debug.print("TXSUB: rx MsgRequestTxIds (blocking={d})\n", .{msg_id});
            sendInventory(alloc, bt, debug) catch |err| {
                if (debug) std.debug.print("TXSUB: inventory send error {}\n", .{err});
            };
        },
        3 => {
            // MsgRequestTxs [3, [txid, ...]] — respond with MsgReplyTxs [4, [tx_bytes, ...]]
            if (debug) std.debug.print("TXSUB: rx MsgRequestTxs\n", .{});
            sendReplyTxs(alloc, bt, term, debug) catch |err| {
                if (debug) std.debug.print("TXSUB: reply txs send error {}\n", .{err});
            };
        },
        6 => {
            // MsgInit — protocol initiation from peer
            if (debug) std.debug.print("TXSUB: rx MsgInit\n", .{});
            // As server: request txids from the client (ingestion pull)
            sendRequestTxIds(alloc, bt, 0, 16, debug) catch |err| {
                if (debug) std.debug.print("TXSUB: send MsgRequestTxIds error {}\n", .{err});
            };
        },
        2 => {
            // MsgReplyTxIds from client: parse inventory and request tx bodies
            handleReplyTxIds(alloc, bt, term, debug);
        },
        4 => {
            // MsgReplyTxs from client: parse tx bodies and admit to mempool
            handleReplyTxs(alloc, term, debug);
        },
        5 => {
            // MsgDone — peer terminated session → transition to Done
            std.debug.print("TXSUB: rx MsgDone (Active→Done)\n", .{});
            g_state = .Done;
            g_state_done_total += 1;
            g_session_active = false;
            if (g_metrics) |m| {
                _ = m.txsub_done_total.fetchAdd(1, .acq_rel);
                m.txsub_session_active.store(0, .release);
                m.txsub_state_code.store(TxSubState.Done.code(), .release);
            }
        },
        else => {
            if (debug) std.debug.print("TXSUB: unknown msg_id={d}\n", .{msg_id});
            if (g_metrics) |m| {
                _ = m.txsub_decode_errors_total.fetchAdd(1, .acq_rel);
            }
        },
    }
}

fn updateGauges(now_ts: i64) void {
    const session_age: u64 = if (g_session_active and g_session_first_msg_unix > 0 and now_ts > g_session_first_msg_unix)
        @intCast(now_ts - g_session_first_msg_unix)
    else
        0;
    const first_id_export: u64 = if (g_session_first_msg_id == std.math.maxInt(u64)) 0 else g_session_first_msg_id;
    if (g_metrics) |m| {
        m.txsub_session_active.store(if (g_session_active) 1 else 0, .release);
        m.txsub_session_first_unix.store(@intCast(g_session_first_unix), .release);
        m.txsub_last_msg_unix.store(@intCast(now_ts), .release);
        m.txsub_rx_msgs_total.store(g_rx_msgs_total, .release);
        m.txsub_rx_bytes_total.store(g_rx_bytes_total, .release);
        m.txsub_session_rx_msgs_last.store(g_session_rx_msgs, .release);
        m.txsub_session_rx_bytes_last.store(g_session_rx_bytes, .release);
        m.txsub_session_first_msg_id_last.store(first_id_export, .release);
        m.txsub_session_age_seconds_last.store(session_age, .release);
        // State machine gauges
        m.txsub_state_code.store(g_state.code(), .release);
        m.txsub_known_total.store(g_known_total, .release);
        m.txsub_ignored_total.store(g_ignored_total, .release);
        m.txsub_invalid_shape_total.store(g_invalid_shape_total, .release);
        // Census
        m.txsub_msg_id_0_total.store(g_msg_id_counts[0], .release);
        m.txsub_msg_id_1_total.store(g_msg_id_counts[1], .release);
        m.txsub_msg_id_3_total.store(g_msg_id_counts[3], .release);
        m.txsub_msg_id_4_total.store(g_msg_id_counts[4], .release);
        m.txsub_msg_id_5_total.store(g_msg_id_counts[5], .release);
        m.txsub_msg_id_6_total.store(g_msg_id_counts[6], .release);
        m.txsub_msg_id_unknown_total.store(g_msg_id_unknown_total, .release);
    }
}

/// Send MsgReplyTxIds [2, [[txid_bytes, tx_size], ...]] with mempool inventory.
fn sendInventory(alloc: std.mem.Allocator, bt: *byte_transport.ByteTransport, debug: bool) !void {
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();

    const inv = encodeInventoryResponse(alloc, &buf) catch |err| {
        if (debug) std.debug.print("TXSUB: encode inventory error {}\n", .{err});
        return err;
    };
    _ = inv;

    try mux_bearer.sendSegment(bt, .responder, TXSUB_PROTO, buf.items);
}

/// Encode a MsgReplyTxIds response into the provided buffer.
/// Returns the number of txids included.
pub fn encodeInventoryResponse(alloc: std.mem.Allocator, buf: *std.array_list.Managed(u8)) !usize {
    const mp = g_mempool;
    const items_slice = if (mp) |m| m.items.items else &[_]mempool_mod.Item{};
    const count = @min(items_slice.len, MAX_INV_ITEMS);

    // Build CBOR: [2, [[txid_bytes, size], ...]]
    // Allocate inner pair arrays and outer list
    var pairs = try alloc.alloc(cbor.Term, count);
    defer alloc.free(pairs);

    var pair_storage = try alloc.alloc([2]cbor.Term, count);
    defer alloc.free(pair_storage);

    for (0..count) |i| {
        const item = &items_slice[i];
        pair_storage[i][0] = cbor.Term{ .bytes = &item.hash };
        pair_storage[i][1] = cbor.Term{ .u64 = item.tx_bytes.len };
        pairs[i] = cbor.Term{ .array = &pair_storage[i] };
    }

    var outer: [2]cbor.Term = undefined;
    outer[0] = cbor.Term{ .u64 = 2 }; // MsgReplyTxIds
    outer[1] = cbor.Term{ .array = pairs };
    const term = cbor.Term{ .array = &outer };

    try cbor.encode(term, compat.listWriter(buf));

    // Update metrics
    if (g_metrics) |m| {
        _ = m.txsub_inventory_sent_total.fetchAdd(1, .acq_rel);
        m.txsub_inventory_items_last.store(@intCast(count), .release);
    }

    return count;
}

/// Parse requested txids from MsgRequestTxs and send MsgReplyTxs with matching tx bodies.
fn sendReplyTxs(alloc: std.mem.Allocator, bt: *byte_transport.ByteTransport, msg_term: cbor.Term, debug: bool) !void {
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();

    const result = encodeReplyTxs(alloc, &buf, msg_term) catch |err| {
        if (debug) std.debug.print("TXSUB: encode reply txs error {}\n", .{err});
        return err;
    };

    if (debug) std.debug.print("TXSUB: replying with {d} txs ({d} bytes)\n", .{ result.served, result.bytes });

    try mux_bearer.sendSegment(bt, .responder, TXSUB_PROTO, buf.items);
}

// ── Ingestion (server-initiated pull) ─────────────────────────────

// Pending txids from most recent MsgReplyTxIds (for MsgRequestTxs)
var g_pending_txids: [128][32]u8 = undefined;
var g_pending_count: usize = 0;

// Ingestion counters
var g_ingest_request_ids: u64 = 0;
var g_ingest_reply_ids: u64 = 0;
var g_ingest_request_txs: u64 = 0;
var g_ingest_reply_txs: u64 = 0;
var g_ingest_accept: u64 = 0;
var g_ingest_reject: u64 = 0;

/// Send MsgRequestTxIds [0, ack, req] or [1, ack, req] as server.
fn sendRequestTxIds(alloc: std.mem.Allocator, bt: *byte_transport.ByteTransport, ack: u64, req: u64, debug: bool) !void {
    var items = try alloc.alloc(cbor.Term, 3);
    defer alloc.free(items);
    items[0] = .{ .u64 = 0 }; // non-blocking
    items[1] = .{ .u64 = ack };
    items[2] = .{ .u64 = req };
    const term = cbor.Term{ .array = items };

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    try cbor.encode(term, compat.listWriter(&buf));

    try mux_bearer.sendSegment(bt, .responder, TXSUB_PROTO, buf.items);
    g_ingest_request_ids += 1;
    if (debug) std.debug.print("TXSUB_INGEST: sent MsgRequestTxIds ack={d} req={d}\n", .{ ack, req });
}

/// Handle MsgReplyTxIds [2, [[hash, size], ...]]: parse txids and request bodies.
fn handleReplyTxIds(alloc: std.mem.Allocator, bt: *byte_transport.ByteTransport, term: cbor.Term, debug: bool) void {
    g_ingest_reply_ids += 1;

    if (term != .array or term.array.len < 2 or term.array[1] != .array) {
        if (debug) std.debug.print("TXSUB_INGEST: MsgReplyTxIds bad shape\n", .{});
        return;
    }

    const pairs = term.array[1].array;
    if (pairs.len == 0) {
        if (debug) std.debug.print("TXSUB_INGEST: MsgReplyTxIds empty inventory\n", .{});
        return;
    }

    // Extract txids
    g_pending_count = 0;
    for (pairs) |pair| {
        if (g_pending_count >= 128) break;
        if (pair != .array or pair.array.len < 1) continue;
        const hash_term = pair.array[0];
        if (hash_term != .bytes or hash_term.bytes.len != 32) continue;
        @memcpy(&g_pending_txids[g_pending_count], hash_term.bytes[0..32]);
        g_pending_count += 1;
    }

    if (debug) std.debug.print("TXSUB_INGEST: MsgReplyTxIds parsed {d} txids\n", .{g_pending_count});

    if (g_pending_count == 0) return;

    // Send MsgRequestTxs [3, [txid, ...]]
    var txid_terms = alloc.alloc(cbor.Term, g_pending_count) catch return;
    defer alloc.free(txid_terms);
    for (0..g_pending_count) |i| {
        txid_terms[i] = cbor.Term{ .bytes = &g_pending_txids[i] };
    }

    var msg_items = alloc.alloc(cbor.Term, 2) catch return;
    defer alloc.free(msg_items);
    msg_items[0] = .{ .u64 = 3 }; // MsgRequestTxs
    msg_items[1] = cbor.Term{ .array = txid_terms };
    const msg_term = cbor.Term{ .array = msg_items };

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    cbor.encode(msg_term, compat.listWriter(&buf)) catch return;

    mux_bearer.sendSegment(bt, .responder, TXSUB_PROTO, buf.items) catch return;
    g_ingest_request_txs += 1;
    if (debug) std.debug.print("TXSUB_INGEST: sent MsgRequestTxs for {d} txids\n", .{g_pending_count});
}

/// Handle MsgReplyTxs [4, [tx_bytes, ...]]: admit tx bodies to mempool.
fn handleReplyTxs(alloc: std.mem.Allocator, term: cbor.Term, debug: bool) void {
    g_ingest_reply_txs += 1;

    if (term != .array or term.array.len < 2 or term.array[1] != .array) {
        if (debug) std.debug.print("TXSUB_INGEST: MsgReplyTxs bad shape\n", .{});
        return;
    }

    const tx_list = term.array[1].array;
    if (debug) std.debug.print("TXSUB_INGEST: MsgReplyTxs received {d} tx bodies\n", .{tx_list.len});

    const mp = g_mempool orelse {
        if (debug) std.debug.print("TXSUB_INGEST: no mempool, cannot admit\n", .{});
        return;
    };

    for (tx_list) |tx_term| {
        if (tx_term != .bytes or tx_term.bytes.len == 0) continue;
        const r = mp.addTx(tx_term.bytes);
        switch (r) {
            .accepted => {
                g_ingest_accept += 1;
                if (debug) std.debug.print("TXSUB_INGEST: tx accepted ({d} bytes)\n", .{tx_term.bytes.len});
            },
            else => {
                g_ingest_reject += 1;
                if (debug) std.debug.print("TXSUB_INGEST: tx rejected reason={s} ({d} bytes)\n", .{ @tagName(r), tx_term.bytes.len });
            },
        }
    }

    // Request more txids after processing
    _ = alloc;
}

const ReplyTxsResult = struct {
    requested: usize,
    served: usize,
    bytes: usize,
};

/// Extract a 32-byte txid from a CBOR term. Tolerant of:
///   - bytes(32) directly
///   - array where first element is bytes(32) (e.g. [hash, size] pairs)
fn extractTxid(t: cbor.Term) ?[32]u8 {
    if (t == .bytes and t.bytes.len == 32) {
        return t.bytes[0..32].*;
    }
    if (t == .array and t.array.len >= 1) {
        if (t.array[0] == .bytes and t.array[0].bytes.len == 32) {
            return t.array[0].bytes[0..32].*;
        }
    }
    return null;
}

/// Encode MsgReplyTxs [4, [tx_bytes, ...]] into buf.
/// Parses requested txids from msg_term ([3, [txid, ...]]), looks up each in mempool,
/// and includes matching tx bodies up to MAX_REPLY_TXS / MAX_REPLY_BYTES.
pub fn encodeReplyTxs(alloc: std.mem.Allocator, buf: *std.array_list.Managed(u8), msg_term: cbor.Term) !ReplyTxsResult {
    var result = ReplyTxsResult{ .requested = 0, .served = 0, .bytes = 0 };

    // Parse requested txids from [3, <txid_list>]
    const txid_list: []cbor.Term = if (msg_term == .array and msg_term.array.len >= 2 and msg_term.array[1] == .array)
        msg_term.array[1].array
    else
        &[_]cbor.Term{};

    result.requested = txid_list.len;

    // Update requested metric
    if (g_metrics) |m| {
        _ = m.txsub_txs_requested_total.fetchAdd(@intCast(result.requested), .acq_rel);
    }

    const mp = g_mempool;

    // Collect matching tx bodies (bounded)
    var tx_terms = std.array_list.Managed(cbor.Term).init(alloc);
    defer tx_terms.deinit();

    for (txid_list) |tid| {
        if (tx_terms.items.len >= MAX_REPLY_TXS) break;

        const hash = extractTxid(tid) orelse continue;

        if (mp) |m| {
            if (m.getTx(hash)) |tx_bytes| {
                if (result.bytes + tx_bytes.len > MAX_REPLY_BYTES) break;
                tx_terms.append(cbor.Term{ .bytes = tx_bytes }) catch break;
                result.served += 1;
                result.bytes += tx_bytes.len;
            }
        }
    }

    // Encode [4, [tx_bytes, ...]]
    var outer: [2]cbor.Term = undefined;
    outer[0] = cbor.Term{ .u64 = 4 }; // MsgReplyTxs
    outer[1] = cbor.Term{ .array = tx_terms.items };
    const term = cbor.Term{ .array = &outer };

    try cbor.encode(term, compat.listWriter(buf));

    // Update metrics
    if (g_metrics) |m| {
        _ = m.txsub_txs_served_total.fetchAdd(@intCast(result.served), .acq_rel);
        _ = m.txsub_bytes_served_total.fetchAdd(@intCast(result.bytes), .acq_rel);
    }

    return result;
}

fn rateLimitedLog(comptime fmt: []const u8, args: anytype) void {
    const now = compat.timestamp();
    if (now - g_last_error_log_unix < 60) return;
    g_last_error_log_unix = now;
    std.debug.print(fmt, args);
}

/// Reset session and broadcast state on reconnect.
/// Clears per-session counters; preserves cumulative totals.
/// State machine resets to Idle.
pub fn reset() void {
    g_state = .Idle;
    g_state_idle_total += 1;
    g_session_active = false;
    g_session_first_unix = 0;
    g_last_msg_unix = 0;
    g_counted_session = false;
    g_session_rx_msgs = 0;
    g_session_rx_bytes = 0;
    g_session_first_msg_id = std.math.maxInt(u64);
    g_session_first_msg_unix = 0;
    g_last_log_unix = 0;
    g_last_broadcast_unix = 0;
    g_last_seen_change_seq = 0;
    if (g_metrics) |m| {
        m.txsub_session_active.store(0, .release);
        m.txsub_session_age_seconds_last.store(0, .release);
        m.txsub_state_code.store(TxSubState.Idle.code(), .release);
    }
}

fn txsubBroadcastEnabled() bool {
    // v5.4.0: broadcast requires TSUNAGI_TXSUB_ENABLE only.
    // Previously also required TSUNAGI_TXSUB_BROADCAST (AND gate).
    // The separate broadcast gate is no longer needed — if TxSubmission is
    // enabled, the node should actively announce txs to the relay.
    const has_enable = compat.hasEnvVar(std.heap.page_allocator, "TSUNAGI_TXSUB_ENABLE");
    if (!has_enable) return false;
    // BAEY safe mode gate: block broadcast when safe_mode.json is active
    if (http_metrics.isSafeModeActive(std.heap.page_allocator)) return false;
    return true;
}

/// Broadcast inventory to peer if mempool has changed (rate-limited to 10s).
/// Only sends when a TxSubmission session is active (peer has sent at least one
/// TxSubmission message), to avoid protocol violations that cause disconnects.
/// Requires TSUNAGI_TXSUB_BROADCAST=1 env var (default OFF).
pub fn maybeBroadcastInventory(alloc: std.mem.Allocator, bt: *byte_transport.ByteTransport) void {
    // Env gate: default OFF for safety
    if (!txsubBroadcastEnabled()) {
        return;
    }

    if (g_metrics) |m| {
        _ = m.txsub_broadcast_attempt_total.fetchAdd(1, .acq_rel);
    }

    if (!g_session_active or g_state != .Active) {
        if (g_metrics) |m| _ = m.txsub_broadcast_blocked_total.fetchAdd(1, .acq_rel);
        return;
    }
    const mp = g_mempool orelse return;
    const now = compat.timestamp();
    if (g_session_first_unix == 0 or (now - g_session_first_unix) < 3) {
        if (g_metrics) |m| _ = m.txsub_broadcast_blocked_total.fetchAdd(1, .acq_rel);
        return;
    }
    if (now - g_last_broadcast_unix < 2) {
        if (g_metrics) |m| _ = m.txsub_broadcast_blocked_total.fetchAdd(1, .acq_rel);
        return;
    }

    const seq = mp.changeSeq();
    if (seq == g_last_seen_change_seq) {
        return;
    }

    // Mempool changed — encode and send inventory
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();

    const count = encodeInventoryResponse(alloc, &buf) catch return;

    mux_bearer.sendSegment(bt, .responder, TXSUB_PROTO, buf.items) catch return;

    g_last_broadcast_unix = now;
    g_last_seen_change_seq = seq;

    if (g_metrics) |m| {
        _ = m.txsub_broadcast_sent_total.fetchAdd(1, .acq_rel);
        _ = m.txsub_inventory_broadcast_total.fetchAdd(1, .acq_rel);
        m.txsub_inventory_broadcast_items_last.store(@intCast(count), .release);
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

test "encodeInventoryResponse empty" {
    const alloc = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();

    // No mempool set → empty inventory
    g_mempool = null;
    const count = try encodeInventoryResponse(alloc, &buf);
    try std.testing.expectEqual(@as(usize, 0), count);
    try std.testing.expect(buf.items.len > 0); // Should still encode [2, []]

    // Decode and verify
    var fbs = compat.fixedBufferStream(buf.items);
    const decoded = try cbor.decode(alloc, fbs.reader());
    defer cbor.free(decoded, alloc);
    try std.testing.expect(decoded == .array);
    try std.testing.expectEqual(@as(usize, 2), decoded.array.len);
    try std.testing.expectEqual(@as(u64, 2), decoded.array[0].u64);
    try std.testing.expect(decoded.array[1] == .array);
    try std.testing.expectEqual(@as(usize, 0), decoded.array[1].array.len);
}

test "encodeInventoryResponse with items" {
    const alloc = std.testing.allocator;

    // Create a mempool with 2 items
    var mp = mempool_mod.Mempool.init(alloc, 16, 1024 * 1024);
    defer mp.deinit();

    // Valid Cardano tx-shaped CBOR: [{0: []}, {}] and [{0: [1]}, {}]
    const tx1 = [_]u8{ 0x82, 0xa1, 0x00, 0x80, 0xa0 };
    const tx2 = [_]u8{ 0x82, 0xa1, 0x00, 0x81, 0x01, 0xa0 };
    try std.testing.expectEqual(mempool_mod.AddResult.accepted, mp.addTx(&tx1));
    try std.testing.expectEqual(mempool_mod.AddResult.accepted, mp.addTx(&tx2));

    g_mempool = &mp;
    defer g_mempool = null;

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();

    const count = try encodeInventoryResponse(alloc, &buf);
    try std.testing.expectEqual(@as(usize, 2), count);

    // Decode and verify structure: [2, [[hash, size], [hash, size]]]
    var fbs = compat.fixedBufferStream(buf.items);
    const decoded = try cbor.decode(alloc, fbs.reader());
    defer cbor.free(decoded, alloc);
    try std.testing.expect(decoded == .array);
    try std.testing.expectEqual(@as(usize, 2), decoded.array.len);
    try std.testing.expectEqual(@as(u64, 2), decoded.array[0].u64);
    try std.testing.expect(decoded.array[1] == .array);
    try std.testing.expectEqual(@as(usize, 2), decoded.array[1].array.len);

    // Each pair: [bytes(32), u64]
    const pair0 = decoded.array[1].array[0];
    try std.testing.expect(pair0 == .array);
    try std.testing.expectEqual(@as(usize, 2), pair0.array.len);
    try std.testing.expect(pair0.array[0] == .bytes);
    try std.testing.expectEqual(@as(usize, 32), pair0.array[0].bytes.len);
    try std.testing.expect(pair0.array[1] == .u64);
    try std.testing.expectEqual(@as(u64, 5), pair0.array[1].u64); // tx1 is 5 bytes
}

test "encodeReplyTxs with one match" {
    const alloc = std.testing.allocator;

    var mp = mempool_mod.Mempool.init(alloc, 16, 1024 * 1024);
    defer mp.deinit();

    const tx1 = [_]u8{ 0x82, 0xa1, 0x00, 0x80, 0xa0 }; // [{0: []}, {}]
    try std.testing.expectEqual(mempool_mod.AddResult.accepted, mp.addTx(&tx1));
    const hash1 = mp.items.items[0].hash;

    g_mempool = &mp;
    defer g_mempool = null;

    // Build a fake MsgRequestTxs: [3, [hash1, unknown_hash]]
    var unknown_hash: [32]u8 = undefined;
    @memset(&unknown_hash, 0xff);

    var txid_list: [2]cbor.Term = undefined;
    txid_list[0] = cbor.Term{ .bytes = &hash1 };
    txid_list[1] = cbor.Term{ .bytes = &unknown_hash };
    var msg_arr: [2]cbor.Term = undefined;
    msg_arr[0] = cbor.Term{ .u64 = 3 };
    msg_arr[1] = cbor.Term{ .array = &txid_list };
    const msg_term = cbor.Term{ .array = &msg_arr };

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();

    const result = try encodeReplyTxs(alloc, &buf, msg_term);
    try std.testing.expectEqual(@as(usize, 2), result.requested);
    try std.testing.expectEqual(@as(usize, 1), result.served);
    try std.testing.expectEqual(@as(usize, 5), result.bytes);

    // Decode: [4, [bytes(5)]]
    var fbs = compat.fixedBufferStream(buf.items);
    const decoded = try cbor.decode(alloc, fbs.reader());
    defer cbor.free(decoded, alloc);
    try std.testing.expect(decoded == .array);
    try std.testing.expectEqual(@as(u64, 4), decoded.array[0].u64);
    try std.testing.expect(decoded.array[1] == .array);
    try std.testing.expectEqual(@as(usize, 1), decoded.array[1].array.len);
    try std.testing.expect(decoded.array[1].array[0] == .bytes);
    try std.testing.expectEqual(@as(usize, 5), decoded.array[1].array[0].bytes.len);
}

test "encodeReplyTxs bound enforcement" {
    const alloc = std.testing.allocator;

    var mp = mempool_mod.Mempool.init(alloc, 64, 4 * 1024 * 1024);
    defer mp.deinit();

    // Add 20 small valid tx-shaped CBOR: [{0: [i]}, {}]
    var hashes: [20][32]u8 = undefined;
    for (0..20) |i| {
        var tx_buf: [6]u8 = undefined;
        tx_buf[0] = 0x82; // 2-elem array
        tx_buf[1] = 0xa1; // 1-elem map
        tx_buf[2] = 0x00; // key 0
        tx_buf[3] = 0x81; // 1-elem array
        tx_buf[4] = @intCast(i); // unique value
        tx_buf[5] = 0xa0; // empty map (witness set)
        try std.testing.expectEqual(mempool_mod.AddResult.accepted, mp.addTx(&tx_buf));
        hashes[i] = mp.items.items[i].hash;
    }

    g_mempool = &mp;
    defer g_mempool = null;

    // Request all 20
    var txid_terms: [20]cbor.Term = undefined;
    for (0..20) |i| {
        txid_terms[i] = cbor.Term{ .bytes = &hashes[i] };
    }
    var msg_arr: [2]cbor.Term = undefined;
    msg_arr[0] = cbor.Term{ .u64 = 3 };
    msg_arr[1] = cbor.Term{ .array = &txid_terms };
    const msg_term = cbor.Term{ .array = &msg_arr };

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();

    const result = try encodeReplyTxs(alloc, &buf, msg_term);
    try std.testing.expectEqual(@as(usize, 20), result.requested);
    // MAX_REPLY_TXS = 16, so served should be capped at 16
    try std.testing.expectEqual(@as(usize, 16), result.served);
}

test "encodeReplyTxs empty mempool" {
    const alloc = std.testing.allocator;

    g_mempool = null;

    // Request with some hash
    var hash: [32]u8 = undefined;
    @memset(&hash, 0xaa);
    var txid_list: [1]cbor.Term = undefined;
    txid_list[0] = cbor.Term{ .bytes = &hash };
    var msg_arr: [2]cbor.Term = undefined;
    msg_arr[0] = cbor.Term{ .u64 = 3 };
    msg_arr[1] = cbor.Term{ .array = &txid_list };
    const msg_term = cbor.Term{ .array = &msg_arr };

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();

    const result = try encodeReplyTxs(alloc, &buf, msg_term);
    try std.testing.expectEqual(@as(usize, 1), result.requested);
    try std.testing.expectEqual(@as(usize, 0), result.served);
    try std.testing.expectEqual(@as(usize, 0), result.bytes);
}
