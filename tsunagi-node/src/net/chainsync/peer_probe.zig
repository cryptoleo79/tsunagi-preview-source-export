// Phase 8 peer probe — header-only ChainSync observer.
//
// A second TCP connection to a secondary relay that runs ONLY ChainSync.
// On every RollForward, it extracts the Cardano header CBOR bytes,
// computes blake2b-256 over them, parses slot + block_no, and atomically
// updates `producer_ctx.rx_block_last / rx_slot_last / rx_hash_last` via
// `producer.updateRxFromPeer` (see producer.zig).
//
// Intentionally NOT a full follower:
//   - no ledger apply, no UTxO writes, no journal, no mempool, no LMDB
//   - no blockfetch, no tx-submission, no keepalive
//   - does NOT share follower.Context with the primary
//
// If the remote closes or any protocol error occurs, the probe logs and
// reconnects with exponential backoff capped at 60s.

const std = @import("std");
const compat = @import("compat");
const shutdown = @import("../../ops/shutdown.zig");

const cbor = @import("../cbor/term.zig");
const chainsync_codec = @import("chainsync_codec.zig");
const handshake_codec = @import("../handshake/handshake_codec.zig");
const mux_bearer = @import("../muxwire/mux_bearer.zig");
const bt_boundary = @import("../transport/byte_transport.zig");
const tcp_bt = @import("../transport/tcp_byte_transport.zig");
const header_raw = @import("../ledger/header_raw.zig");
const producer = @import("../../producer/producer.zig");
const multi_probe = @import("../../producer/multi_probe.zig");

const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

const handshake_proto: u16 = 0;
const chainsync_proto: u16 = 2;
const keepalive_proto: u16 = 8;

// Preview network magic (mainnet overrides via env if ever needed).
const preview_magic: u64 = 2;

const ProbeContext = struct {
    alloc: std.mem.Allocator,
    host: []u8,
    port: u16,
    network_magic: u64,
    producer_ctx: *producer.ProducerContext,
    probe_id: u32,
    peer_id_buf: [16]u8 = [_]u8{0} ** 16,
    peer_id_len: u8 = 0,
    // RequestNext → RollForward round-trip sampling for latency_ms.
    req_sent_ns: i128 = 0,
};

/// Spawn the probe as a detached background thread.
///
/// host/port are duped onto `alloc` and kept alive for the life of the
/// thread (which is the life of the process — the context is leaked
/// intentionally, matching propagation_server.spawnBackground).
pub fn spawnBackground(
    alloc: std.mem.Allocator,
    host: []const u8,
    port: u16,
    network_magic: u64,
    producer_ctx: *producer.ProducerContext,
    probe_id: u32,
) bool {
    const host_copy = alloc.dupe(u8, host) catch {
        std.debug.print("PEER_PROBE_SPAWN: dupe host failed\n", .{});
        return false;
    };
    const cfg = alloc.create(ProbeContext) catch {
        alloc.free(host_copy);
        std.debug.print("PEER_PROBE_SPAWN: alloc ctx failed\n", .{});
        return false;
    };
    cfg.* = .{
        .alloc = alloc,
        .host = host_copy,
        .port = port,
        .network_magic = network_magic,
        .producer_ctx = producer_ctx,
        .probe_id = probe_id,
    };
    const pid_len = std.fmt.bufPrint(cfg.peer_id_buf[0..], "probe-{d}", .{probe_id}) catch {
        alloc.free(host_copy);
        alloc.destroy(cfg);
        std.debug.print("PEER_PROBE_SPAWN: peer_id fmt failed\n", .{});
        return false;
    };
    cfg.peer_id_len = @intCast(pid_len.len);

    // Register in multi-probe state table immediately so /status shows the
    // peer even before first connect completes.
    var addr_buf: [128]u8 = undefined;
    const addr_str = std.fmt.bufPrint(&addr_buf, "{s}:{d}", .{ host, port }) catch host;
    multi_probe.registerPeer(probe_id, addr_str);

    const thread = std.Thread.spawn(.{}, probeThread, .{cfg}) catch {
        alloc.free(host_copy);
        alloc.destroy(cfg);
        std.debug.print("PEER_PROBE_SPAWN: thread spawn failed\n", .{});
        return false;
    };
    thread.detach();
    std.debug.print("PEER_PROBE_SPAWNED: id={d} host={s} port={d}\n", .{ probe_id, host, port });
    return true;
}

fn probeThread(cfg: *ProbeContext) void {
    // AWS-style full-jitter backoff: sleep ∈ [0, min(cap, base * 2^attempt)].
    var attempt: u32 = 0;
    const cap_s: u64 = 60;
    const base_s: u64 = 1;
    while (true) {
        if (shutdown.stopRequested()) return;
        runOneConnection(cfg) catch |err| {
            std.debug.print("PEER_PROBE_DISCONNECT: id={d} reason={s}\n", .{ cfg.probe_id, @errorName(err) });
        };
        multi_probe.markDisconnected(cfg.probe_id);
        const shift: u6 = @intCast(@min(attempt, 6));
        const max_wait: u64 = @min(cap_s, base_s * (@as(u64, 1) << shift));
        const seed: u64 = @truncate(@as(u128, @bitCast(compat.nanoTimestamp())));
        var prng = std.Random.DefaultPrng.init(seed);
        const sleep_s: u64 = prng.random().intRangeAtMost(u64, 0, max_wait);
        compat.sleep(sleep_s * std.time.ns_per_s);
        attempt +|= 1;
    }
}

fn runOneConnection(cfg: *ProbeContext) !void {
    std.debug.print("PEER_PROBE_CONNECT: id={d} host={s} port={d}\n", .{ cfg.probe_id, cfg.host, cfg.port });

    var bt = try tcp_bt.connect(cfg.alloc, cfg.host, cfg.port);
    defer bt.deinit();

    // 30s handshake timeout, then 20s steady-state.
    tcp_bt.setReadTimeout(&bt, 30_000) catch {};
    if (!try doHandshake(cfg.alloc, &bt, cfg.network_magic)) {
        std.debug.print("PEER_PROBE_DISCONNECT: id={d} reason=handshake_refused\n", .{cfg.probe_id});
        return;
    }
    multi_probe.markConnected(cfg.probe_id);

    // Wait for primary to have at least one tip before we intersect —
    // never fall back to origin (that replays from genesis).
    var wait_attempts: u32 = 0;
    while (true) {
        const sent = sendFindIntersect(cfg.alloc, &bt, cfg.producer_ctx) catch |err| {
            std.debug.print("PEER_PROBE_DISCONNECT: reason=intersect_send_{s}\n", .{@errorName(err)});
            return;
        };
        if (sent) break;
        wait_attempts += 1;
        if (wait_attempts == 1 or wait_attempts % 10 == 0) {
            std.debug.print("PEER_PROBE_INTERSECT_WAIT: no_primary_tip_yet attempts={d}\n", .{wait_attempts});
        }
        compat.sleep(2 * std.time.ns_per_s);
        if (wait_attempts > 150) {
            // ~5 min without primary progress — give up this connection, reconnect.
            std.debug.print("PEER_PROBE_DISCONNECT: reason=primary_not_progressing\n", .{});
            return;
        }
    }

    tcp_bt.setReadTimeout(&bt, 20_000) catch {};

    // Request/response loop — continuous ChainSync streaming.
    // Cardano state machine:
    //   Idle → RequestNext → CanAwait
    //   CanAwait → RollForward/RollBackward → Idle (client must RequestNext again)
    //   CanAwait → AwaitReply → MustReply
    //   MustReply → RollForward/RollBackward (pushed) → Idle (client must RequestNext)
    var heartbeat_last: i64 = compat.timestamp();
    var msg_count: u64 = 0;
    var rf_count: u64 = 0;
    var timeout_streak: u32 = 0;
    while (true) {
        const seg_opt = mux_bearer.recvSegmentWithTimeout(cfg.alloc, &bt) catch |err| switch (err) {
            error.TimedOut => {
                timeout_streak += 1;
                // Emit a heartbeat every ~60s so operator sees the probe is alive.
                const now = compat.timestamp();
                if (now - heartbeat_last >= 60) {
                    std.debug.print("PEER_PROBE_HEARTBEAT: msgs={d} rolls={d} timeout_streak={d} waiting_for_push\n", .{ msg_count, rf_count, timeout_streak });
                    heartbeat_last = now;
                }
                // 5-minute silence → peer is probably wedged, reconnect.
                if (timeout_streak >= 15) {
                    std.debug.print("PEER_PROBE_DISCONNECT: reason=silent_peer streak={d}\n", .{timeout_streak});
                    return;
                }
                continue;
            },
            else => return err,
        };
        timeout_streak = 0;
        const seg = seg_opt orelse {
            std.debug.print("PEER_PROBE_DISCONNECT: reason=peer_closed msgs={d} rolls={d}\n", .{ msg_count, rf_count });
            return;
        };
        defer cfg.alloc.free(seg.payload);
        msg_count += 1;

        // Handle keepalive pings inline — essential to keep relay from closing us.
        if (seg.hdr.proto == keepalive_proto) {
            handleKeepalive(cfg.alloc, &bt, seg.payload) catch |err| {
                std.debug.print("PEER_PROBE_KEEPALIVE_FAIL: err={s}\n", .{@errorName(err)});
            };
            continue;
        }

        if (seg.hdr.proto != chainsync_proto) {
            // Ignore other mux channels (txsubmission etc).
            continue;
        }

        var fbs = compat.fixedBufferStream(seg.payload);
        var msg = chainsync_codec.decodeResponse(cfg.alloc, fbs.reader()) catch |err| {
            std.debug.print("PEER_PROBE_DECODE_FAIL: err={s} payload_len={d}\n", .{ @errorName(err), seg.payload.len });
            // Don't die on a single bad message — try to stay in sync.
            continue;
        };
        defer chainsync_codec.free(cfg.alloc, &msg);

        switch (msg) {
            .intersect_found => {
                std.debug.print("PEER_PROBE_MSG: id={d} intersect_found\n", .{cfg.probe_id});
                try sendRequestNext(cfg, &bt);
            },
            .intersect_not_found => {
                // None of our history points matched the peer's chain. This is
                // rare — usually means peer is far behind, just rolled back, or
                // on a different fork. Disconnect and reconnect after backoff;
                // primary may have newer tips by then.
                std.debug.print("PEER_PROBE_DISCONNECT: id={d} reason=intersect_not_found (will retry with fresh history)\n", .{cfg.probe_id});
                return;
            },
            .await_reply => {
                // Server has no new headers right now. State is MustReply —
                // server WILL push a roll_forward/roll_backward when ready.
                // We just loop and keep reading. No action needed.
                std.debug.print("PEER_PROBE_MSG: id={d} await_reply (waiting for push)\n", .{cfg.probe_id});
            },
            .roll_forward => |rf| {
                rf_count += 1;
                handleRollForward(cfg, rf.block);
                // After receiving, state is Idle — must request next.
                try sendRequestNext(cfg, &bt);
            },
            .roll_backward => {
                std.debug.print("PEER_PROBE_MSG: id={d} roll_backward\n", .{cfg.probe_id});
                try sendRequestNext(cfg, &bt);
            },
            .find_intersect, .request_next => {
                // Client-originated verbs — should not appear on responder.
                std.debug.print("PEER_PROBE_UNEXPECTED: got client-verb on responder\n", .{});
            },
        }
    }
}

fn doHandshake(alloc: std.mem.Allocator, bt: *bt_boundary.ByteTransport, network_magic: u64) !bool {
    // NodeToNode v14 version data: [network_magic, diffusion_mode=false,
    // peer_sharing=0, query=false]. Probe never wants TxSubmission flow
    // opened against it, so diffusion_mode stays false (InitiatorOnly).
    var version_items = try alloc.alloc(cbor.Term, 4);
    defer alloc.free(version_items);
    version_items[0] = .{ .u64 = network_magic };
    version_items[1] = .{ .bool = false };
    version_items[2] = .{ .u64 = 0 };
    version_items[3] = .{ .bool = false };
    const version_data = cbor.Term{ .array = version_items };

    var entries = try alloc.alloc(cbor.MapEntry, 1);
    defer alloc.free(entries);
    entries[0] = .{ .key = 14, .value = version_data };
    const propose = handshake_codec.HandshakeMsg{
        .propose = .{ .versions = .{ .map_u64 = entries } },
    };

    var payload_list = std.array_list.Managed(u8).init(alloc);
    defer payload_list.deinit();
    try handshake_codec.encodeMsg(propose, compat.listWriter(&payload_list));

    try mux_bearer.sendSegment(bt, .initiator, handshake_proto, payload_list.items);

    const seg_opt = try mux_bearer.recvSegmentWithTimeout(alloc, bt);
    const seg = seg_opt orelse return false;
    defer alloc.free(seg.payload);

    var fbs = compat.fixedBufferStream(seg.payload);
    var msg = handshake_codec.decodeMsg(alloc, fbs.reader()) catch return false;
    defer handshake_codec.free(alloc, &msg);

    return msg == .accept;
}

/// Send FindIntersect with multiple candidate points drawn from the primary's
/// tip history. Sends up to 8 points (latest first). Never falls back to
/// origin — if history is empty, we defer and retry after primary advances.
/// Returns false if no points are available yet.
fn sendFindIntersect(
    alloc: std.mem.Allocator,
    bt: *bt_boundary.ByteTransport,
    pctx: *producer.ProducerContext,
) !bool {
    // Snapshot up to 8 most-recent tips from primary history.
    var history: [8]producer.RxTipEntry = [_]producer.RxTipEntry{.{}} ** 8;
    const n = producer.snapshotRxTipHistory(pctx, &history);
    if (n == 0) return false;

    // Build stratified point list: newest + spaced-out older entries.
    // With up to 32 history entries (one per new block primary sees),
    // indexes [0, 1, 4, 16] give us tip, tip-1, tip-4, tip-16 roughly.
    const strata: [4]u32 = .{ 0, 1, 4, 16 };
    var selected: [4]producer.RxTipEntry = undefined;
    var sel_n: u32 = 0;
    for (strata) |idx| {
        if (idx < n) {
            selected[sel_n] = history[idx];
            sel_n += 1;
        }
    }
    if (sel_n == 0) return false;

    // Allocate hash copies (CBOR slices) and point pairs.
    var hash_copies = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (hash_copies.items) |h| alloc.free(h);
        hash_copies.deinit();
    }
    var point_pairs = std.array_list.Managed([]cbor.Term).init(alloc);
    defer {
        for (point_pairs.items) |p| alloc.free(p);
        point_pairs.deinit();
    }

    const points_items = try alloc.alloc(cbor.Term, sel_n);
    defer alloc.free(points_items);

    var i: u32 = 0;
    while (i < sel_n) : (i += 1) {
        const h = try alloc.dupe(u8, selected[i].hash[0..]);
        try hash_copies.append(h);
        const pair = try alloc.alloc(cbor.Term, 2);
        try point_pairs.append(pair);
        pair[0] = .{ .u64 = selected[i].slot };
        pair[1] = .{ .bytes = h };
        points_items[i] = .{ .array = pair };
    }

    const points = cbor.Term{ .array = points_items };

    var list = std.array_list.Managed(u8).init(alloc);
    defer list.deinit();
    try chainsync_codec.encodeFindIntersect(compat.listWriter(&list), points);
    try mux_bearer.sendSegment(bt, .responder, chainsync_proto, list.items);

    std.debug.print("PEER_PROBE_INTERSECT: points={d} newest_slot={d} newest_hash={x} oldest_slot={d}\n", .{
        sel_n, selected[0].slot, selected[0].hash[0..4], selected[sel_n - 1].slot,
    });
    return true;
}

fn sendRequestNext(cfg: *ProbeContext, bt: *bt_boundary.ByteTransport) !void {
    var list = std.array_list.Managed(u8).init(cfg.alloc);
    defer list.deinit();
    try chainsync_codec.encodeRequestNext(compat.listWriter(&list));
    try mux_bearer.sendSegment(bt, .responder, chainsync_proto, list.items);
    cfg.req_sent_ns = compat.nanoTimestamp();
}

/// Respond to keepalive pings from the relay so it doesn't close our
/// connection on idle. Cardano NtN keepalive: msg_id 0 = ping(cookie),
/// msg_id 1 = pong(cookie), msg_id 2 = done.
fn handleKeepalive(alloc: std.mem.Allocator, bt: *bt_boundary.ByteTransport, payload: []const u8) !void {
    if (payload.len == 0) return;
    var fbs = compat.fixedBufferStream(payload);
    const term = try cbor.decode(alloc, fbs.reader());
    defer cbor.free(term, alloc);
    if (term != .array or term.array.len == 0) return;
    if (term.array[0] != .u64) return;
    const msg_id = term.array[0].u64;
    if (msg_id != 0) return; // only respond to PINGs

    var cookie: u16 = 0;
    if (term.array.len >= 2 and term.array[1] == .u64) {
        cookie = @truncate(term.array[1].u64);
    }

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    var items: [2]cbor.Term = undefined;
    items[0] = cbor.Term{ .u64 = 1 };
    items[1] = cbor.Term{ .u64 = cookie };
    try cbor.encode(cbor.Term{ .array = items[0..2] }, compat.listWriter(&buf));
    try mux_bearer.sendSegment(bt, .responder, keepalive_proto, buf.items);
}

fn handleRollForward(cfg: *ProbeContext, block_term: cbor.Term) void {
    // Cardano RollForward block shape is [era, tag24(block_bytes), ...].
    // The inner bytes decode to [header, [txs...], ...]; we need the raw
    // encoded header_body so our blake2b-256 matches the relay's ID.
    if (block_term != .array) return;
    const items = block_term.array;
    if (items.len < 2) return;

    const block_bytes: []const u8 = switch (items[1]) {
        .bytes => |b| b,
        .tag => |t| if (t.tag == 24 and t.value.* == .bytes) t.value.*.bytes else return,
        else => return,
    };

    const inner_bytes = header_raw.getTag24InnerBytes(block_bytes) orelse block_bytes;

    // Decode the outer [header_body, kes_sig] structure and re-encode
    // header_body[0] alone so we hash the same bytes the primary does
    // (see follower.computeHeaderHash32).
    var fbs = compat.fixedBufferStream(inner_bytes);
    const top = cbor.decode(cfg.alloc, fbs.reader()) catch return;
    defer cbor.free(top, cfg.alloc);
    if (top != .array or top.array.len == 0) return;
    if (top.array[0] != .array or top.array[0].array.len < 3) return;

    // Hash the full [header_body, kes_sig] envelope — that matches what
    // the primary uses via computeHeaderHash32(inner_bytes).
    var digest: [32]u8 = undefined;
    Blake2b256.hash(inner_bytes, &digest, .{});

    // Extract slot + block_no from header_body: index 0 = block_no,
    // index 1 = slot. Both Shelley (15-item) and Babbage/Conway
    // (10-item) header bodies share this prefix.
    const body = top.array[0].array;
    if (body[0] != .u64 or body[1] != .u64) return;
    const block_no = body[0].u64;
    const slot = body[1].u64;

    // Latency: time from last RequestNext sent to this RollForward received.
    // Pushed rolls (server-initiated) will show the full await interval, so
    // clamp to reasonable ceiling to avoid polluting the best-tip tiebreaker.
    var latency_ms: u32 = 0;
    if (cfg.req_sent_ns > 0) {
        const elapsed_ns = compat.nanoTimestamp() - cfg.req_sent_ns;
        if (elapsed_ns > 0) {
            const ms = @divFloor(elapsed_ns, std.time.ns_per_ms);
            latency_ms = if (ms > 10_000) 10_000 else @intCast(ms);
        }
        cfg.req_sent_ns = 0;
    }

    std.debug.print("PEER_PROBE_HEADER: id={d} slot={d} block={d} latency_ms={d} hash={x}\n", .{
        cfg.probe_id, slot, block_no, latency_ms, digest[0..8],
    });

    multi_probe.recordHeaderWithHash(cfg.probe_id, slot, block_no, latency_ms, digest);
    // Probe path does not parse prev_hash; pass null so selectFreshestParent
    // treats this rx update as ineligible for Stage-2 promotion (probe stays
    // strictly advisory for parent identity).
    producer.updateRxFromPeer(cfg.producer_ctx, cfg.peer_id_buf[0..cfg.peer_id_len], slot, block_no, digest, null);
}

// Silence "unused" warnings for constants referenced only in comments.
comptime {
    _ = preview_magic;
}
