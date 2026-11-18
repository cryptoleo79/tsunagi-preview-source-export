const std = @import("std");
const compat = @import("compat");
const cbor = @import("../net/cbor/term.zig");
const mux_bearer = @import("../net/muxwire/mux_bearer.zig");
const mux_header = @import("../net/muxwire/mux_header.zig");
const bt_mod = @import("../net/transport/byte_transport.zig");
const fragment_coverage = @import("../archive/fragment_coverage.zig");

// ── ChainSync Server (v4.5.13) ──────────────────────────────────────
//
// Fragment-aware ChainSync server: serves a contiguous chain fragment
// of recent headers. FindIntersect matches relay points against ALL
// fragment hashes; RequestNext serves successive headers from the
// intersect point through to the tip.
//
// Protocol numbers follow Cardano N2N: ChainSync = 2.
//
// CBOR message tags (Cardano miniprotocol):
//   MsgRequestNext       = [0]
//   MsgAwaitReply        = [1]
//   MsgRollForward       = [2, serialised_header, tip]
//   MsgRollBackward      = [3, point, tip]
//   MsgFindIntersect     = [4, [points...]]
//   MsgIntersectFound    = [5, point, tip]
//   MsgIntersectNotFound = [6, tip]
//   MsgDone              = [7]
//
// tip  = [ point, blockNo ]       (2-element)
// point = [ slot, headerHash ]    (2-element)
//
// HardFork SerialisedHeader = [eraIndex, tag(24, bytes(raw_header))]
// Conway era on preview: eraIndex = 6 (CardanoEras is 0-indexed:
//   Byron=0, Shelley=1, Allegra=2, Mary=3, Alonzo=4, Babbage=5, Conway=6).
// Full MsgRollForward: [2, [era, tag(24, hdr_bytes)], [[slot, hash], blockNo]]

pub const chainsync_proto: u16 = 2;

// Orphan-watchdog signal: bumped whenever handleFindIntersect returns
// IntersectNotFound. Read by producer.checkOrphanWatchdog.
pub var g_intersect_not_found_total: std.atomic.Value(u64) =
    std.atomic.Value(u64).init(0);

pub const SealedHeader = struct {
    slot: u64,
    block_no: u64,
    hash: [32]u8,
    header_cbor: []const u8,
    era_index: u64 = 6, // Conway = 6 (Babbage = 5; CardanoEras 0-indexed)
};

/// One entry in the rolling chain fragment. Ordered oldest→newest.
/// Each entry's prev_hash must equal the preceding entry's hash (contiguous ancestry).
pub const FragmentEntry = struct {
    slot: u64,
    block_no: u64,
    hash: [32]u8,
    prev_hash: [32]u8,
    header_cbor: []const u8,
    body_cbor: ?[]const u8 = null, // block body for BlockFetch serving
    era_index: u64 = 6, // Conway = 6 (Babbage = 5; CardanoEras 0-indexed)
};

/// Bounded slot+hash backstop entry. Used to cover relay intersect points
/// that fall outside the live in-memory fragment (e.g. coherence drop or
/// cold start). Fixed-capacity ring; no allocator.
pub const HistoryEntry = struct {
    slot: u64,
    hash: [32]u8,
};

/// Capacity of the in-memory header history backstop. Sized to hold roughly
/// one Cardano k-window (~2160 headers) worth of recent ancestry without
/// allocator pressure.
pub const HISTORY_CAPACITY: usize = 2400;

pub const ChainSyncServer = struct {
    sealed: SealedHeader,
    served_header: bool = false, // true once any header has been served
    served_sealed: bool = false, // true once the sealed tip header has been served
    resolved: bool = false, // true after header CBOR fields have been parsed
    intersect_slot: u64 = 0, // chosen intersect slot (for RollForward logging)
    prev_hash: [32]u8 = [_]u8{0} ** 32, // prevHash from sealed header CBOR
    has_prev_hash: bool = false, // whether prev_hash was successfully parsed

    // RollBackward state: Cardano spec requires MsgRollBackward(intersection, tip)
    // as the first response to MsgRequestNext after MsgIntersectFound.
    need_rollback: bool = false,
    intersect_hash: [32]u8 = [_]u8{0} ** 32, // hash of the intersection point

    // Fragment state: contiguous chain of headers (oldest→newest)
    fragment: []const FragmentEntry = &[_]FragmentEntry{},
    fragment_serve_idx: usize = 0, // next fragment entry to serve via RollForward
    fragment_intersect_idx: ?usize = null, // index of intersected entry in fragment
    relay_newest_slot: u64 = 0, // newest slot from relay FindIntersect points
    sealed_recency_window: u64 = 600, // max slot gap for serving sealed block when relay is ahead

    // Last-sent tracking for disconnect diagnostics
    last_sent_kind: []const u8 = "none",
    last_sent_frag_idx: usize = 0,
    last_sent_slot: u64 = 0,
    last_sent_block_no: u64 = 0,
    last_sent_hash: [32]u8 = [_]u8{0} ** 32,

    // ── Header history backstop ─────────────────────────────────────
    // Bounded ring of (slot, hash) pairs used as a tertiary intersect
    // source when neither fragment nor prev_hash + sealed.hash satisfy
    // the relay's points. Populated by callers via pushHistory();
    // safe to leave empty (path is purely additive).
    history: [HISTORY_CAPACITY]HistoryEntry = std.mem.zeroes([HISTORY_CAPACITY]HistoryEntry),
    history_len: usize = 0,
    history_head: usize = 0, // next write index (ring head)

    pub fn init(sealed: SealedHeader) ChainSyncServer {
        return .{ .sealed = sealed };
    }

    pub fn initWithFragment(sealed: SealedHeader, fragment: []const FragmentEntry) ChainSyncServer {
        return .{ .sealed = sealed, .fragment = fragment };
    }

    /// Append a (slot, hash) to the bounded history ring. Older entries
    /// are overwritten in FIFO order once the ring is full. No allocator.
    pub fn pushHistory(self: *ChainSyncServer, slot: u64, hash: [32]u8) void {
        self.history[self.history_head] = .{ .slot = slot, .hash = hash };
        self.history_head = (self.history_head + 1) % HISTORY_CAPACITY;
        if (self.history_len < HISTORY_CAPACITY) self.history_len += 1;
    }

    /// Linear scan of the history ring for a hash. Bounded by HISTORY_CAPACITY.
    /// Returns the matched (slot, hash) entry, or null if absent.
    pub fn lookupHistoryHash(self: *const ChainSyncServer, hash: [32]u8) ?HistoryEntry {
        const n = self.history_len;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const e = self.history[i];
            if (std.mem.eql(u8, &e.hash, &hash)) return e;
        }
        return null;
    }

    /// Probe the bounded history ring for any of the relay's points.
    /// Returns IntersectFound on a match (and sets RollBackward state)
    /// or null if no relay point hash exists in history. Pure additive:
    /// no-op when history_len == 0.
    fn tryHistoryIntersect(
        self: *ChainSyncServer,
        alloc: std.mem.Allocator,
        points_term: cbor.Term,
    ) ?[]u8 {
        if (self.history_len == 0) return null;
        if (points_term != .array) return null;

        for (points_term.array, 0..) |pt, i| {
            if (pt != .array or pt.array.len != 2) continue;
            if (pt.array[1] != .bytes) continue;
            if (pt.array[1].bytes.len != 32) continue;
            const pt_slot = if (pt.array[0] == .u64) pt.array[0].u64 else 0;
            const pt_hash_slice = pt.array[1].bytes[0..32];
            var pt_hash: [32]u8 = undefined;
            @memcpy(&pt_hash, pt_hash_slice);

            if (self.lookupHistoryHash(pt_hash)) |entry| {
                std.debug.print("INTERSECT_CHECK: relay_pt_idx={d} relay_slot={d} relay_hash_first8={x} local_match=true matched_via=header_store\n", .{
                    i, pt_slot, pt_hash[0..8],
                });
                self.intersect_slot = entry.slot;
                @memcpy(&self.intersect_hash, &entry.hash);
                self.need_rollback = true;
                std.debug.print("chainsync: FindIntersect method=header_store result=found chosen_slot={d} sealed_slot={d} history_len={d}\n", .{
                    entry.slot, self.sealed.slot, self.history_len,
                });
                return self.encodeIntersectFound(alloc, pt);
            }
        }
        return null;
    }

    /// Handle an incoming ChainSync message payload. Returns response bytes or null (done/error).
    pub fn handleMessage(self: *ChainSyncServer, alloc: std.mem.Allocator, payload: []const u8) ?[]u8 {
        // On first message, resolve sealed.slot and sealed.block_no from
        // the actual header CBOR.  meta.json stores the upstream server's
        // TIP values which can be ahead of the header we captured.
        if (!self.resolved) {
            self.resolved = true;
            self.resolveHeaderFields(alloc);
        }

        var fbs = compat.fixedBufferStream(payload);
        const term = cbor.decode(alloc, fbs.reader()) catch return null;
        defer cbor.free(term, alloc);

        if (term != .array or term.array.len < 1) return null;
        if (term.array[0] != .u64) return null;

        const tag = term.array[0].u64;
        return switch (tag) {
            4 => blk: {
                const n_points = if (term.array.len >= 2 and term.array[1] == .array) term.array[1].array.len else 0;
                std.debug.print("chainsync: rx MsgFindIntersect points={d}\n", .{n_points});
                break :blk self.handleFindIntersect(alloc, term);
            },
            0 => blk: {
                std.debug.print("chainsync: rx MsgRequestNext\n", .{});
                break :blk self.handleRequestNext(alloc);
            },
            7 => blk: {
                std.debug.print("chainsync: rx MsgDone\n", .{});
                break :blk null;
            },
            else => blk: {
                std.debug.print("chainsync: rx unknown tag={d} payload_len={d}\n", .{ tag, payload.len });
                break :blk null;
            },
        };
    }

    fn handleFindIntersect(self: *ChainSyncServer, alloc: std.mem.Allocator, term: cbor.Term) ?[]u8 {
        // MsgFindIntersect = [4, [points...]]
        // Relay sends points newest-first.
        //
        // Fragment mode (fragment.len > 0):
        //   Search relay points against ALL fragment hashes.
        //   Choose the newest relay point whose hash matches ANY fragment entry.
        //   Set fragment_serve_idx to the successor of the matched entry.
        //
        // Legacy strict mode (has_prev_hash == true, no fragment):
        //   ONLY match on prevHash. If no relay point matches → IntersectNotFound.
        //
        // Legacy fallback mode (has_prev_hash == false, no fragment):
        //   Slot-based selection (header unparseable/malformed).
        if (term.array.len >= 2) {
            const points_term = term.array[1];
            if (points_term == .array and points_term.array.len > 0) {
                var best_idx: ?usize = null;
                var best_slot: u64 = 0;
                var match_method: []const u8 = "none";

                // INTERSECT_OFFER — dump up to 5 newest fragment entries we can match against.
                if (self.fragment.len > 0) {
                    const offer_count: usize = @min(5, self.fragment.len);
                    const offer_start: usize = self.fragment.len - offer_count;
                    var oi: usize = 0;
                    while (oi < offer_count) : (oi += 1) {
                        const e = self.fragment[offer_start + oi];
                        std.debug.print("INTERSECT_OFFER: idx={d} slot={d} hash_first8={x}\n", .{
                            offer_start + oi, e.slot, e.hash[0..8],
                        });
                    }
                }

                if (self.fragment.len > 0) {
                    // Fragment-aware matching: search relay points against all fragment hashes
                    // Choose the newest relay point (first match, since points are newest-first)
                    // whose hash matches any fragment entry.

                    // ── Stale tip detection ──
                    // Relay points are newest-first. point[0].slot approximates the relay's chain tip.
                    // If the relay is already ahead of our sealed tip, we have nothing to offer.
                    var relay_newest_slot: u64 = 0;
                    if (points_term.array.len > 0 and points_term.array[0] == .array and
                        points_term.array[0].array.len >= 1 and points_term.array[0].array[0] == .u64)
                    {
                        relay_newest_slot = points_term.array[0].array[0].u64;
                    }
                    self.relay_newest_slot = relay_newest_slot;
                    const slot_gap: i128 = @as(i128, self.sealed.slot) - @as(i128, relay_newest_slot);
                    const relay_ahead = relay_newest_slot > self.sealed.slot;
                    const tsunagi_ahead = self.sealed.slot > relay_newest_slot;
                    const equal_tip = self.sealed.slot == relay_newest_slot;
                    std.debug.print("chainsync: CHAIN_POSITION relay_newest_slot={d} sealed_slot={d} sealed_block_no={d} gap={d} relay_ahead={}\n", .{
                        relay_newest_slot, self.sealed.slot, self.sealed.block_no, slot_gap, relay_ahead,
                    });
                    std.debug.print("candidate: relay_newest_slot={d} sealed_slot={d} sealed_block_no={d} gap_slots={d} relay_ahead={} tsunagi_ahead={} equal_tip={} strictly_ahead={}\n", .{
                        relay_newest_slot, self.sealed.slot, self.sealed.block_no, slot_gap, relay_ahead, tsunagi_ahead, equal_tip, tsunagi_ahead,
                    });

                    if (relay_ahead) {
                        std.debug.print("chainsync: STALE_TIP relay_newest_slot={d} sealed_slot={d} (relay ahead, proceeding with fragment hash match)\n", .{
                            relay_newest_slot, self.sealed.slot,
                        });
                        // Do NOT return IntersectNotFound here. The relay sends points
                        // newest-first; point[0] is often ahead of our sealed tip, but
                        // later points in the set may match our fragment. Let the hash
                        // match loop below decide. If no hash matches, IntersectNotFound
                        // is returned naturally.
                    }

                    // ── Match loop ──
                    var best_frag_idx: ?usize = null;
                    for (points_term.array, 0..) |pt, i| {
                        if (pt != .array or pt.array.len != 2) continue;
                        if (pt.array[1] != .bytes) {
                            std.debug.print("chainsync: point idx={d} hash parse failed (not bytes)\n", .{i});
                            continue;
                        }
                        if (pt.array[1].bytes.len != 32) {
                            std.debug.print("chainsync: point idx={d} hash parse failed (len={d})\n", .{
                                i, pt.array[1].bytes.len,
                            });
                            continue;
                        }
                        const pt_hash = pt.array[1].bytes[0..32];
                        const pt_slot_log = if (pt.array[0] == .u64) pt.array[0].u64 else 0;

                        // Search fragment entries for a hash match
                        var matched_frag: ?usize = null;
                        for (self.fragment, 0..) |frag, fi| {
                            if (std.mem.eql(u8, pt_hash, &frag.hash)) {
                                matched_frag = fi;
                                break;
                            }
                        }
                        const local_match = matched_frag != null;
                        const matched_via: []const u8 = if (matched_frag != null) "fragment" else "none";
                        std.debug.print("INTERSECT_CHECK: relay_pt_idx={d} relay_slot={d} relay_hash_first8={x} local_match={} matched_via={s}\n", .{
                            i, pt_slot_log, pt_hash[0..8], local_match, matched_via,
                        });
                        if (matched_frag) |fi| {
                            best_idx = i;
                            best_slot = pt_slot_log;
                            best_frag_idx = fi;
                            match_method = "fragment_hash";
                            std.debug.print("chainsync: FindIntersect fragment_hash match pt_idx={d} frag_idx={d} slot={d} frag_slot={d}\n", .{
                                i, fi, pt_slot_log, self.fragment[fi].slot,
                            });
                            break; // newest match wins
                        }
                    }

                    if (best_frag_idx) |fi| {
                        // Serve from the successor of the matched fragment entry
                        self.fragment_intersect_idx = fi;
                        self.fragment_serve_idx = fi + 1;
                        self.served_header = false;
                        std.debug.print("INTERSECT_RESULT: result=found method=fragment_hash chosen_slot={d} frag_idx={d}\n", .{
                            best_slot, fi,
                        });
                    } else {
                        // No exact fragment hash match — try header_store backstop
                        // before declaring IntersectNotFound.
                        if (self.tryHistoryIntersect(alloc, points_term)) |reply| {
                            return reply;
                        }
                        {
                            // Neither hash nor slot matched — IntersectNotFound
                            // ── Diagnostic: slot range comparison ──
                            if (points_term.array.len > 0 and self.fragment.len > 0) {
                                var pt_min_slot: u64 = std.math.maxInt(u64);
                                var pt_max_slot: u64 = 0;
                                for (points_term.array) |pt| {
                                    if (pt == .array and pt.array.len >= 1 and pt.array[0] == .u64) {
                                        if (pt.array[0].u64 < pt_min_slot) pt_min_slot = pt.array[0].u64;
                                        if (pt.array[0].u64 > pt_max_slot) pt_max_slot = pt.array[0].u64;
                                    }
                                }
                                std.debug.print("chainsync: diag relay_slot_range=[{d}..{d}] fragment_slot_range=[{d}..{d}]\n", .{
                                    pt_min_slot, pt_max_slot,
                                    self.fragment[0].slot, self.fragment[self.fragment.len - 1].slot,
                                });
                            }

                            std.debug.print("chainsync: FindIntersect method=fragment_slot result=not_found points={d} fragment_len={d} sealed_slot={d} history_len={d}\n", .{
                                points_term.array.len,
                                self.fragment.len,
                                self.sealed.slot,
                                self.history_len,
                            });
                            _ = g_intersect_not_found_total.fetchAdd(1, .release);
                            std.debug.print("INTERSECT_RESULT: result=not_found points={d} fragment_len={d} sealed_slot={d}\n", .{
                                points_term.array.len, self.fragment.len, self.sealed.slot,
                            });
                            return self.encodeTipMsg(alloc, 6);
                        }
                    }
                } else if (self.has_prev_hash) {
                    // Strict prevHash-only matching (no fragment available)
                    // Also check sealed.hash — if relay already knows our block, match on that
                    for (points_term.array, 0..) |pt, i| {
                        if (pt != .array or pt.array.len != 2) continue;
                        if (pt.array[1] != .bytes) continue;
                        if (pt.array[1].bytes.len != 32) continue;
                        const pt_slot = if (pt.array[0] == .u64) pt.array[0].u64 else 0;
                        const pt_hash = pt.array[1].bytes[0..32];
                        // Log each relay point for diagnostics
                        std.debug.print("chainsync: FindIntersect relay_point[{d}] slot={d} hash={x}\n", .{
                            i, pt_slot, pt_hash[0..8],
                        });
                        const matched_prev = std.mem.eql(u8, pt_hash, &self.prev_hash);
                        const matched_sealed = std.mem.eql(u8, pt_hash, &self.sealed.hash);
                        const local_match = matched_prev or matched_sealed;
                        const matched_via: []const u8 = if (matched_prev) "prev_hash" else if (matched_sealed) "sealed" else "none";
                        std.debug.print("INTERSECT_CHECK: relay_pt_idx={d} relay_slot={d} relay_hash_first8={x} local_match={} matched_via={s}\n", .{
                            i, pt_slot, pt_hash[0..8], local_match, matched_via,
                        });
                        if (matched_prev) {
                            best_idx = i;
                            best_slot = pt_slot;
                            match_method = "prevHash_strict";
                            std.debug.print("chainsync: FindIntersect prevHash_strict match at index={d} slot={d}\n", .{ i, pt_slot });
                            break;
                        }
                        // Also match on sealed hash (relay already has our block)
                        if (matched_sealed) {
                            best_idx = i;
                            best_slot = pt_slot;
                            match_method = "sealed_hash";
                            std.debug.print("chainsync: FindIntersect sealed_hash match at index={d} slot={d}\n", .{ i, pt_slot });
                            break;
                        }
                    }

                    // If prevHash not in relay points, try header_store backstop
                    // before declaring IntersectNotFound.
                    if (best_idx == null) {
                        if (self.tryHistoryIntersect(alloc, points_term)) |reply| {
                            return reply;
                        }
                        std.debug.print("chainsync: FindIntersect method=prevHash_strict result=not_found points={d} sealed_slot={d} prevHash={x} history_len={d}\n", .{
                            points_term.array.len,
                            self.sealed.slot,
                            self.prev_hash[0..8],
                            self.history_len,
                        });
                        return self.encodeTipMsg(alloc, 6);
                    }
                } else {
                    // Slot-based fallback (prevHash unavailable/unparseable, no fragment).
                    // Try header_store backstop first — a hash hit is preferred over
                    // a blind slot match.
                    if (self.tryHistoryIntersect(alloc, points_term)) |reply| {
                        return reply;
                    }
                    // Emit a per-point trace so the operator sees each candidate.
                    for (points_term.array, 0..) |pt, i| {
                        if (pt != .array or pt.array.len != 2) continue;
                        if (pt.array[0] != .u64 or pt.array[1] != .bytes) continue;
                        if (pt.array[1].bytes.len != 32) continue;
                        const slot = pt.array[0].u64;
                        const pt_hash = pt.array[1].bytes[0..32];
                        std.debug.print("INTERSECT_CHECK: relay_pt_idx={d} relay_slot={d} relay_hash_first8={x} local_match=false matched_via=none\n", .{
                            i, slot, pt_hash[0..8],
                        });
                    }
                    // Pass 1: find highest slot < sealed.slot (strictly earlier)
                    for (points_term.array, 0..) |pt, i| {
                        if (pt != .array or pt.array.len != 2) continue;
                        if (pt.array[0] != .u64 or pt.array[1] != .bytes) continue;
                        const slot = pt.array[0].u64;
                        if (slot < self.sealed.slot and (best_idx == null or slot > best_slot)) {
                            best_idx = i;
                            best_slot = slot;
                            match_method = "slot_fallback";
                        }
                    }

                    // Pass 2: if no strictly-earlier point, accept slot == sealed.slot
                    if (best_idx == null) {
                        for (points_term.array, 0..) |pt, i| {
                            if (pt != .array or pt.array.len != 2) continue;
                            if (pt.array[0] != .u64 or pt.array[1] != .bytes) continue;
                            const slot = pt.array[0].u64;
                            if (slot == self.sealed.slot) {
                                best_idx = i;
                                best_slot = slot;
                                match_method = "slot_fallback";
                                break;
                            }
                        }
                    }
                }

                if (best_idx) |idx| {
                    self.intersect_slot = best_slot;
                    // Capture intersection point hash for RollBackward
                    if (points_term.array[idx] == .array and
                        points_term.array[idx].array.len >= 2 and
                        points_term.array[idx].array[1] == .bytes and
                        points_term.array[idx].array[1].bytes.len == 32)
                    {
                        @memcpy(&self.intersect_hash, points_term.array[idx].array[1].bytes[0..32]);
                    }
                    self.need_rollback = true;
                    // Log chosen point hash prefix for verification
                    const pt_hash = if (points_term.array[idx] == .array and
                        points_term.array[idx].array.len >= 2 and
                        points_term.array[idx].array[1] == .bytes and
                        points_term.array[idx].array[1].bytes.len >= 8)
                        points_term.array[idx].array[1].bytes[0..8]
                    else
                        &[_]u8{0} ** 8;
                    std.debug.print("chainsync: FindIntersect points={d} chosen_slot={d} chosen_index={d} sealed_slot={d} method={s} result=found pt_hash={s} has_prev_hash={} fragment_len={d} need_rollback=true\n", .{
                        points_term.array.len, best_slot, idx, self.sealed.slot, match_method, pt_hash, self.has_prev_hash, self.fragment.len,
                    });
                    return self.encodeIntersectFound(alloc, points_term.array[idx]);
                }

                // Slot-based fallback exhausted (has_prev_hash was false)
                std.debug.print("chainsync: FindIntersect method=slot_fallback result=not_found points={d} sealed_slot={d}\n", .{
                    points_term.array.len,
                    self.sealed.slot,
                });
                return self.encodeTipMsg(alloc, 6);
            }
        }
        // Fallback: no valid points array — send IntersectNotFound
        std.debug.print("chainsync: FindIntersect no valid points array, sending IntersectNotFound\n", .{});
        return self.encodeTipMsg(alloc, 6);
    }

    fn handleRequestNext(self: *ChainSyncServer, alloc: std.mem.Allocator) ?[]u8 {
        const slot_gap: u64 = if (self.relay_newest_slot > self.sealed.slot)
            self.relay_newest_slot - self.sealed.slot
        else
            0;
        const action: []const u8 = if (self.need_rollback)
            "rollback"
        else if (self.fragment.len > 0 and self.fragment_serve_idx < self.fragment.len)
            "rollforward_fragment"
        else if (!self.served_sealed)
            "rollforward_sealed"
        else
            "awaitreply_done";
        std.debug.print("REQUEST_NEXT_DECISION: action={s} intersect_slot={d} fragment_serve_idx={d} fragment_len={d} served_header={} served_sealed={} need_rollback={} relay_newest={d} sealed_slot={d} slot_gap={d}\n", .{
            action, self.intersect_slot, self.fragment_serve_idx, self.fragment.len,
            self.served_header, self.served_sealed, self.need_rollback,
            self.relay_newest_slot, self.sealed.slot,
            slot_gap,
        });

        // Cardano ChainSync spec: after MsgIntersectFound, the first MsgRequestNext
        // must return MsgRollBackward(intersection_point, tip) to confirm the
        // agreed intersection. Only subsequent MsgRequestNext calls return MsgRollForward.
        if (self.need_rollback) {
            self.need_rollback = false;
            self.last_sent_kind = "rollback";
            self.last_sent_slot = self.intersect_slot;
            self.last_sent_hash = self.intersect_hash;
            std.debug.print("chainsync: tx MsgRollBackward slot={d} hash={x} (post-intersect, spec-required)\n", .{
                self.intersect_slot,
                self.intersect_hash[0..8],
            });
            return self.encodeRollBackward(alloc);
        }

        // Serve remaining fragment entries after intersect via RollForward.
        // The relay needs to see chain progression before the sealed tip.
        if (self.fragment.len > 0 and self.fragment_serve_idx < self.fragment.len) {
            const entry = &self.fragment[self.fragment_serve_idx];

            // Decode the actual header bytes: slot, block_no, prev_hash, hash
            var decoded_slot: u64 = 0;
            var decoded_block_no: u64 = 0;
            var decoded_prev_hash: [32]u8 = [_]u8{0} ** 32;
            var has_decoded_prev: bool = false;
            var decoded_hash: [32]u8 = [_]u8{0} ** 32;
            if (parseHeaderFields(alloc, entry.header_cbor)) |fields| {
                decoded_slot = fields.slot;
                decoded_block_no = fields.block_no;
                if (fields.prev_hash) |ph| {
                    decoded_prev_hash = ph;
                    has_decoded_prev = true;
                }
            }
            std.crypto.hash.blake2.Blake2b256.hash(entry.header_cbor, &decoded_hash, .{});

            // Determine what the predecessor hash should be
            const is_first_after_rollback = (self.fragment_serve_idx > 0 and
                self.fragment_serve_idx == (self.fragment_intersect_idx orelse 0) + 1);
            const prev_entry_hash: [32]u8 = if (self.fragment_serve_idx > 0)
                self.fragment[self.fragment_serve_idx - 1].hash
            else
                [_]u8{0} ** 32;
            const prev_matches_intersect = std.mem.eql(u8, &decoded_prev_hash, &self.intersect_hash);
            const prev_matches_predecessor = std.mem.eql(u8, &decoded_prev_hash, &prev_entry_hash);

            std.debug.print("FRAGMENT_PARENT_TRUTH: intersect_slot={d} intersect_hash={x} first_frag_idx={d} first_frag_slot={d} first_frag_block_no={d} first_frag_hash={x} first_frag_prevHash={x} prev_matches_intersect={} prev_matches_predecessor={} is_first_after_rollback={} has_decoded_prev={}\n", .{
                self.intersect_slot,
                self.intersect_hash[0..8],
                self.fragment_serve_idx,
                entry.slot, entry.block_no,
                entry.hash[0..8],
                decoded_prev_hash[0..8],
                prev_matches_intersect,
                prev_matches_predecessor,
                is_first_after_rollback,
                has_decoded_prev,
            });

            // Pre-forge correctness guard: refuse to emit RollForward whose
            // ancestry does not chain to the relay's chosen intersect (or to
            // the previously-served fragment entry). Serving a header whose
            // prev_hash breaks the chain would cause the relay to reject and
            // disconnect. Pause via MsgAwaitReply — tag 1 — to let the next
            // tick re-evaluate state. (MsgIntersectNotFound is not valid
            // out of FindIntersect state, so AwaitReply is the safe stall.)
            if (has_decoded_prev) {
                const ancestry_ok = if (is_first_after_rollback)
                    prev_matches_intersect
                else
                    prev_matches_predecessor;
                if (!ancestry_ok) {
                    std.debug.print("FRAGMENT_ANCESTRY_REFUSE: idx={d} slot={d} block_no={d} reason={s} action=await_reply\n", .{
                        self.fragment_serve_idx,
                        entry.slot,
                        entry.block_no,
                        if (is_first_after_rollback) "prev_does_not_match_intersect" else "prev_does_not_match_predecessor",
                    });
                    return encodeSimpleMsg(alloc, 1);
                }
            }

            self.last_sent_kind = "fragment";
            self.last_sent_frag_idx = self.fragment_serve_idx;
            self.last_sent_slot = entry.slot;
            self.last_sent_block_no = entry.block_no;
            self.last_sent_hash = entry.hash;

            const remaining_blocks = if (self.sealed.block_no > entry.block_no) self.sealed.block_no - entry.block_no else 0;
            const remaining_slots = if (self.sealed.slot > entry.slot) self.sealed.slot - entry.slot else 0;
            std.debug.print("LAST_ACCEPTED_PROGRESS_TRUTH: kind=fragment idx={d} slot={d} block_no={d} remaining_blocks={d} remaining_slots={d} frag_remaining={d}\n", .{
                self.fragment_serve_idx, entry.slot, entry.block_no,
                remaining_blocks, remaining_slots,
                self.fragment.len - self.fragment_serve_idx - 1,
            });

            self.fragment_serve_idx += 1;
            self.served_header = true;
            return self.encodeRollForwardEntry(alloc, entry);
        }

        // Serve sealed tip header (after fragment is exhausted, or in single-header mode)
        if (!self.served_sealed) {
            // If fragment was served, always serve sealed header next — it extends the fragment.
            // Only apply the slot guard when there's no fragment (single-header mode).
            if (self.fragment.len == 0 and self.intersect_slot >= self.sealed.slot) {
                std.debug.print("chainsync: tx MsgAwaitReply (no fragment, intersect_slot={d} >= sealed_slot={d}, cannot advance)\n", .{
                    self.intersect_slot, self.sealed.slot,
                });
                return encodeSimpleMsg(alloc, 1);
            }
            // Sealed-staleness guard: if our forged artifact is more than
            // STALE_GATE_SLOTS behind the relay's claimed tip, refuse to
            // advertise it. Pushing a stale block triggers UnexpectedBlockNo
            // on the relay (HeaderEnvelopeError). Pause via MsgAwaitReply
            // until the next forge writes a fresh artifact.
            const STALE_GATE_SLOTS: u64 = 600; // ~10 min on preview (1s slots)
            if (self.relay_newest_slot > self.sealed.slot and
                (self.relay_newest_slot - self.sealed.slot) > STALE_GATE_SLOTS)
            {
                std.debug.print("SEALED_STALE_REFUSE: sealed_slot={d} relay_newest={d} gap={d} action=await_reply\n", .{
                    self.sealed.slot,
                    self.relay_newest_slot,
                    self.relay_newest_slot - self.sealed.slot,
                });
                return encodeSimpleMsg(alloc, 1);
            }
            if (self.relay_newest_slot > self.sealed.slot) {
                std.debug.print("SEALED_SERVE_DECISION: sealed_slot={d} relay_newest={d} gap={d} action=serve_anyway (within stale gate)\n", .{
                    self.sealed.slot, self.relay_newest_slot,
                    self.relay_newest_slot - self.sealed.slot,
                });
            }
            self.served_sealed = true;
            self.served_header = true;
            self.last_sent_kind = "sealed";
            self.last_sent_slot = self.sealed.slot;
            self.last_sent_block_no = self.sealed.block_no;
            self.last_sent_hash = self.sealed.hash;
            std.debug.print("SEALED_WIRE_TRUTH: slot={d} block_no={d} intersect_slot={d} hash={x} prevHash={x} era={d} hdr_len={d} relay_newest={d}\n", .{
                self.sealed.slot,
                self.sealed.block_no,
                self.intersect_slot,
                self.sealed.hash[0..8],
                if (self.has_prev_hash) self.prev_hash[0..8] else &[_]u8{0} ** 8,
                self.sealed.era_index,
                self.sealed.header_cbor.len,
                self.relay_newest_slot,
            });
            return self.encodeRollForward(alloc);
        }
        // All headers served — send AwaitReply [1]
        std.debug.print("chainsync: tx MsgAwaitReply (all headers served)\n", .{});
        const result = encodeSimpleMsg(alloc, 1);
        if (result == null) {
            std.debug.print("chainsync: ERROR encodeSimpleMsg returned null for AwaitReply\n", .{});
        }
        return result;
    }

    fn encodeIntersectFound(self: *ChainSyncServer, alloc: std.mem.Allocator, point: cbor.Term) ?[]u8 {
        // MsgIntersectFound = [5, point, tip]
        // point is the relay's point (borrowed from incoming term)
        // tip = [[our_slot, our_hash], blockNo]
        var list = std.array_list.Managed(u8).init(alloc);
        const w = compat.listWriter(&list);

        // Build tip
        const tip = self.buildTip(alloc) orelse return null;
        defer freeTip(alloc, tip);

        // [5, point, tip]
        var items: [3]cbor.Term = undefined;
        items[0] = .{ .u64 = 5 };
        items[1] = point;
        items[2] = tip;

        const arr_term = cbor.Term{ .array = &items };
        cbor.encode(arr_term, w) catch {
            list.deinit();
            return null;
        };

        const result = list.toOwnedSlice() catch null;
        if (result) |wire| {
            std.debug.print("chainsync: tx MsgIntersectFound wire_first8={s} wire_len={d}\n", .{
                hexFirst8(wire), wire.len,
            });
        }
        return result;
    }

    /// Encode MsgRollBackward = [3, point, tip]
    /// point = [intersect_slot, intersect_hash]
    /// Sent as the first response to MsgRequestNext after MsgIntersectFound (spec-required).
    fn encodeRollBackward(self: *ChainSyncServer, alloc: std.mem.Allocator) ?[]u8 {
        var list = std.array_list.Managed(u8).init(alloc);
        const w = compat.listWriter(&list);

        // Build tip
        const tip = self.buildTip(alloc) orelse return null;
        defer freeTip(alloc, tip);

        // Build point = [intersect_slot, intersect_hash]
        var pt_items: [2]cbor.Term = undefined;
        pt_items[0] = .{ .u64 = self.intersect_slot };
        pt_items[1] = .{ .bytes = &self.intersect_hash };

        // [3, point, tip]
        var items: [3]cbor.Term = undefined;
        items[0] = .{ .u64 = 3 };
        items[1] = .{ .array = &pt_items };
        items[2] = tip;

        const arr_term = cbor.Term{ .array = &items };
        cbor.encode(arr_term, w) catch {
            list.deinit();
            return null;
        };

        return list.toOwnedSlice() catch null;
    }

    pub fn encodeRollForward(self: *ChainSyncServer, alloc: std.mem.Allocator) ?[]u8 {
        // MsgRollForward = [2, serialised_header, tip]
        // serialised_header = [eraIndex, tag(24, bytes(raw_header))]  (HardFork combinator)
        // tip = [[slot, hash], blockNo]
        var list = std.array_list.Managed(u8).init(alloc);
        const w = compat.listWriter(&list);

        // Build tip
        const tip = self.buildTip(alloc) orelse return null;
        defer freeTip(alloc, tip);

        // Build tag(24, bytes(header_cbor))
        const tag_inner = alloc.create(cbor.Term) catch return null;
        tag_inner.* = .{ .bytes = self.sealed.header_cbor };
        defer alloc.destroy(tag_inner);

        // Build serialised_header = [eraIndex, tag(24, bytes(raw_header))]
        var sh_items: [2]cbor.Term = undefined;
        sh_items[0] = .{ .u64 = self.sealed.era_index };
        sh_items[1] = .{ .tag = .{ .tag = 24, .value = tag_inner } };

        // [2, serialised_header, tip]
        var items: [3]cbor.Term = undefined;
        items[0] = .{ .u64 = 2 };
        items[1] = .{ .array = &sh_items };
        items[2] = tip;

        const arr_term = cbor.Term{ .array = &items };
        cbor.encode(arr_term, w) catch {
            list.deinit();
            return null;
        };

        const result = list.toOwnedSlice() catch null;
        if (result) |wire| {
            std.debug.print("chainsync: tx MsgRollForward slot={d} intersect_slot={d} wire_first8={s} wire_len={d} era={d} hdr_len={d}\n", .{
                self.sealed.slot, self.intersect_slot, hexFirst8(wire), wire.len, self.sealed.era_index, self.sealed.header_cbor.len,
            });
        }
        return result;
    }

    /// Encode MsgRollForward for a fragment entry (same wire format as encodeRollForward but with fragment data).
    fn encodeRollForwardEntry(self: *ChainSyncServer, alloc: std.mem.Allocator, entry: *const FragmentEntry) ?[]u8 {
        var list = std.array_list.Managed(u8).init(alloc);
        const w = compat.listWriter(&list);

        // Build tip: always use sealed tip for session consistency.
        // Tip must not regress between IntersectFound and RollForward.
        const tip = self.buildTip(alloc) orelse return null;
        defer freeTip(alloc, tip);

        // Build tag(24, bytes(header_cbor))
        const tag_inner = alloc.create(cbor.Term) catch return null;
        tag_inner.* = .{ .bytes = entry.header_cbor };
        defer alloc.destroy(tag_inner);

        // serialised_header = [eraIndex, tag(24, bytes(raw_header))]
        var sh_items: [2]cbor.Term = undefined;
        sh_items[0] = .{ .u64 = entry.era_index };
        sh_items[1] = .{ .tag = .{ .tag = 24, .value = tag_inner } };

        // [2, serialised_header, tip]
        var items: [3]cbor.Term = undefined;
        items[0] = .{ .u64 = 2 };
        items[1] = .{ .array = &sh_items };
        items[2] = tip;

        const arr_term = cbor.Term{ .array = &items };
        cbor.encode(arr_term, w) catch {
            list.deinit();
            return null;
        };

        const result = list.toOwnedSlice() catch null;
        if (result) |wire| {
            std.debug.print("chainsync: tx MsgRollForward(frag) slot={d} block_no={d} wire_len={d} era={d} hdr_len={d} tip_slot={d} tip_block_no={d} tip_source=sealed\n", .{
                entry.slot, entry.block_no, wire.len, entry.era_index, entry.header_cbor.len,
                self.sealed.slot, self.sealed.block_no,
            });
        }
        return result;
    }

    fn encodeTipMsg(self: *ChainSyncServer, alloc: std.mem.Allocator, msg_tag: u64) ?[]u8 {
        // [msg_tag, tip]
        var list = std.array_list.Managed(u8).init(alloc);
        const w = compat.listWriter(&list);

        const tip = self.buildTip(alloc) orelse return null;
        defer freeTip(alloc, tip);

        var items: [2]cbor.Term = undefined;
        items[0] = .{ .u64 = msg_tag };
        items[1] = tip;

        const arr_term = cbor.Term{ .array = &items };
        cbor.encode(arr_term, w) catch {
            list.deinit();
            return null;
        };

        const result = list.toOwnedSlice() catch null;
        if (result) |wire| {
            std.debug.print("chainsync: tx msg_tag={d} wire_first8={s} wire_len={d}\n", .{
                msg_tag, hexFirst8(wire), wire.len,
            });
        }
        return result;
    }

    // ── Shared tip encoding ─────────────────────────────────────────

    /// Build a tip Term: [[slot, hash], blockNo]
    /// Caller must call freeTip() after encoding.
    fn buildTip(self: *ChainSyncServer, alloc: std.mem.Allocator) ?cbor.Term {
        var point_items = alloc.alloc(cbor.Term, 2) catch return null;
        point_items[0] = .{ .u64 = self.sealed.slot };
        point_items[1] = .{ .bytes = &self.sealed.hash };

        var tip_items = alloc.alloc(cbor.Term, 2) catch {
            alloc.free(point_items);
            return null;
        };
        tip_items[0] = .{ .array = point_items };
        tip_items[1] = .{ .u64 = self.sealed.block_no };

        std.debug.print("chainsync: tip slot={d} block_no={d} hash={x}\n", .{
            self.sealed.slot, self.sealed.block_no, self.sealed.hash[0..8],
        });
        return cbor.Term{ .array = tip_items };
    }

    fn freeTip(alloc: std.mem.Allocator, tip: cbor.Term) void {
        if (tip == .array and tip.array.len == 2 and tip.array[0] == .array) {
            alloc.free(tip.array[0].array);
        }
        if (tip == .array) alloc.free(tip.array);
    }

    /// Encode tip to standalone byte buffer (for manual message construction).
    fn encodeTipBytes(self: *ChainSyncServer, alloc: std.mem.Allocator) ?[]u8 {
        const tip = self.buildTip(alloc) orelse return null;
        defer freeTip(alloc, tip);

        var buf = std.array_list.Managed(u8).init(alloc);
        cbor.encode(tip, compat.listWriter(&buf)) catch {
            buf.deinit();
            return null;
        };
        return buf.toOwnedSlice() catch null;
    }

    fn encodeSimpleMsg(alloc: std.mem.Allocator, msg_tag: u64) ?[]u8 {
        var list = std.array_list.Managed(u8).init(alloc);
        const w = compat.listWriter(&list);

        var items: [1]cbor.Term = undefined;
        items[0] = .{ .u64 = msg_tag };
        const arr_term = cbor.Term{ .array = &items };
        cbor.encode(arr_term, w) catch {
            list.deinit();
            return null;
        };
        const result = list.toOwnedSlice() catch null;
        if (result) |wire| {
            std.debug.print("chainsync: tx simple msg_tag={d} wire={s} wire_len={d}\n", .{
                msg_tag, hexFirst8(wire), wire.len,
            });
        }
        return result;
    }

    // ── Header CBOR field resolution ────────────────────────────────
    //
    // meta.json stores the upstream server's TIP slot/block_no (from the
    // ChainSync RollForward tip field), which can be 1+ blocks ahead of
    // the header we actually captured.  This causes UnexpectedBlockNo
    // when the relay validates the served header against its own chain.
    //
    // Fix: parse the authoritative slot and block_no directly from the
    // header CBOR and override sealed values if they differ.
    //
    // Cardano header CBOR: [header_body, kes_signature]
    // header_body: [block_number, slot, prev_hash, ...]

    fn resolveHeaderFields(self: *ChainSyncServer, alloc: std.mem.Allocator) void {
        const fields = parseHeaderFields(alloc, self.sealed.header_cbor) orelse {
            std.debug.print("chainsync: WARN could not parse header CBOR fields\n", .{});
            return;
        };

        if (fields.block_no != self.sealed.block_no or fields.slot != self.sealed.slot) {
            std.debug.print("chainsync: HEADER_FIX meta slot={d} block_no={d} -> header slot={d} block_no={d}\n", .{
                self.sealed.slot, self.sealed.block_no, fields.slot, fields.block_no,
            });
            self.sealed.slot = fields.slot;
            self.sealed.block_no = fields.block_no;
        } else {
            std.debug.print("chainsync: header fields match meta slot={d} block_no={d}\n", .{
                self.sealed.slot, self.sealed.block_no,
            });
        }

        // Extract prevHash for intersection matching
        if (fields.prev_hash) |ph| {
            self.prev_hash = ph;
            self.has_prev_hash = true;
            std.debug.print("chainsync: prevHash={x}\n", .{
                ph[0..8],
            });
        } else {
            std.debug.print("chainsync: WARN prevHash not found in header CBOR\n", .{});
        }
    }

    /// Parse block_no, slot, and prevHash from raw header CBOR.
    /// Header format: [header_body, kes_signature]
    /// header_body[0] = block_number (u64)
    /// header_body[1] = slot (u64)
    /// header_body[2] = prev_hash (bytes32, possibly tag-wrapped)
    pub fn parseHeaderFields(alloc: std.mem.Allocator, header_cbor: []const u8) ?struct { block_no: u64, slot: u64, prev_hash: ?[32]u8 } {
        if (header_cbor.len == 0) return null;
        var fbs = compat.fixedBufferStream(header_cbor);
        const term = cbor.decode(alloc, fbs.reader()) catch return null;
        defer cbor.free(term, alloc);

        if (term != .array or term.array.len < 2) return null;

        // Detect format: wrapped header [header_body, kes_sig] vs bare header body [block_no, slot, ...]
        // Wrapped: array.len == 2, array[0] is array (the body), array[1] is bytes (the sig)
        // Bare body: array.len >= 10, array[0] is u64 (block_number)
        const body = if (term.array[0] == .array)
            term.array[0] // wrapped: [header_body, kes_sig]
        else
            term; // bare header body
        if (body != .array or body.array.len < 2) return null;
        if (body.array[0] != .u64 or body.array[1] != .u64) return null;

        // Extract prevHash at index 2 (raw bytes or tag-wrapped bytes)
        var prev_hash: ?[32]u8 = null;
        if (body.array.len >= 3) {
            prev_hash = extract32ByteHash(body.array[2]);
        }

        return .{ .block_no = body.array[0].u64, .slot = body.array[1].u64, .prev_hash = prev_hash };
    }

    /// Extract a 32-byte hash from a CBOR Term (raw .bytes or tag-wrapped .bytes).
    fn extract32ByteHash(term: cbor.Term) ?[32]u8 {
        if (term == .bytes and term.bytes.len == 32) {
            var out: [32]u8 = undefined;
            @memcpy(&out, term.bytes[0..32]);
            return out;
        }
        if (term == .tag) {
            const inner = term.tag.value.*;
            if (inner == .bytes and inner.bytes.len == 32) {
                var out: [32]u8 = undefined;
                @memcpy(&out, inner.bytes[0..32]);
                return out;
            }
        }
        return null;
    }

    // ── Hex helper (bounded, static buffer) ─────────────────────────

    fn hexFirst8(data: []const u8) []const u8 {
        if (data.len == 0) return "()";
        const S = struct {
            var buf: [16]u8 = undefined;
        };
        const hex = "0123456789abcdef";
        var pos: usize = 0;
        for (data[0..@min(data.len, 8)]) |b| {
            if (pos + 1 >= S.buf.len) break;
            S.buf[pos] = hex[b >> 4];
            S.buf[pos + 1] = hex[b & 0x0f];
            pos += 2;
        }
        return S.buf[0..pos];
    }
};

// ── Tests: sealed recency window ────────────────────────────────────

test "sealed served when relay slightly ahead (within stale gate)" {
    const alloc = std.testing.allocator;
    var server = ChainSyncServer.init(.{
        .slot = 1000,
        .block_no = 100,
        .hash = [_]u8{0xAA} ** 32,
        .header_cbor = &[_]u8{ 0x82, 0x8a, 0x00, 0x00 },
    });
    server.relay_newest_slot = 1500; // gap=500, within STALE_GATE_SLOTS=600 → still serve
    server.need_rollback = false;

    const response = server.handleRequestNext(alloc);
    try std.testing.expect(response != null);
    if (response) |r| alloc.free(r);
    try std.testing.expect(server.served_sealed);
}

test "sealed staleness gate refuses serve when relay too far ahead" {
    const alloc = std.testing.allocator;
    var server = ChainSyncServer.init(.{
        .slot = 1000,
        .block_no = 100,
        .hash = [_]u8{0xAA} ** 32,
        .header_cbor = &[_]u8{ 0x82, 0x8a, 0x00, 0x00 },
    });
    server.relay_newest_slot = 9000; // gap=8000, exceeds STALE_GATE_SLOTS=600 → refuse
    server.need_rollback = false;

    const response = server.handleRequestNext(alloc);
    try std.testing.expect(response != null);
    if (response) |r| {
        // MsgAwaitReply is a 2-byte CBOR array [1]
        try std.testing.expectEqual(@as(usize, 2), r.len);
        try std.testing.expectEqual(@as(u8, 0x81), r[0]);
        try std.testing.expectEqual(@as(u8, 0x01), r[1]);
        alloc.free(r);
    }
    try std.testing.expect(!server.served_sealed);
}

test "sealed always served: relay not ahead serves normally" {
    const alloc = std.testing.allocator;
    var server = ChainSyncServer.init(.{
        .slot = 1000,
        .block_no = 100,
        .hash = [_]u8{0xAA} ** 32,
        .header_cbor = &[_]u8{ 0x82, 0x8a, 0x00, 0x00 },
    });
    server.relay_newest_slot = 900; // behind sealed
    server.need_rollback = false;

    const response = server.handleRequestNext(alloc);
    try std.testing.expect(response != null);
    if (response) |r| alloc.free(r);
    try std.testing.expect(server.served_sealed);
}

// ── Tests: header history backstop ──────────────────────────────────

test "history ring: pushHistory and lookupHistoryHash" {
    var server = ChainSyncServer.init(.{
        .slot = 1000,
        .block_no = 100,
        .hash = [_]u8{0xAA} ** 32,
        .header_cbor = &[_]u8{},
    });
    try std.testing.expectEqual(@as(usize, 0), server.history_len);

    const h1: [32]u8 = [_]u8{0x11} ** 32;
    const h2: [32]u8 = [_]u8{0x22} ** 32;
    server.pushHistory(100, h1);
    server.pushHistory(200, h2);

    try std.testing.expectEqual(@as(usize, 2), server.history_len);
    const got1 = server.lookupHistoryHash(h1) orelse return error.MissingHash;
    try std.testing.expectEqual(@as(u64, 100), got1.slot);
    const got2 = server.lookupHistoryHash(h2) orelse return error.MissingHash;
    try std.testing.expectEqual(@as(u64, 200), got2.slot);

    const absent: [32]u8 = [_]u8{0xFF} ** 32;
    try std.testing.expect(server.lookupHistoryHash(absent) == null);
}

test "HEADER_STORE_BACKSTOP_MATCHES: relay point present in history hits backstop" {
    const alloc = std.testing.allocator;
    var server = ChainSyncServer.init(.{
        .slot = 1000,
        .block_no = 100,
        .hash = [_]u8{0xAA} ** 32,
        .header_cbor = &[_]u8{ 0x82, 0x8a, 0x00, 0x00 },
    });
    // Force the prevHash-strict branch (no fragment, has_prev_hash=true)
    // and seed history with a hash neither prev nor sealed knows about.
    server.has_prev_hash = true;
    server.prev_hash = [_]u8{0xBB} ** 32;

    const X: [32]u8 = [_]u8{0x77} ** 32;
    const S: u64 = 4242;
    server.pushHistory(S, X);

    // Build relay points: [Origin (slot=0, zero-hash), [S, X]]
    var origin_pt = [2]cbor.Term{
        .{ .u64 = 0 },
        .{ .bytes = &[_]u8{0} ** 32 },
    };
    var match_pt = [2]cbor.Term{
        .{ .u64 = S },
        .{ .bytes = &X },
    };
    var pts = [2]cbor.Term{
        .{ .array = &origin_pt },
        .{ .array = &match_pt },
    };
    var msg_items = [2]cbor.Term{
        .{ .u64 = 4 }, // MsgFindIntersect tag
        .{ .array = &pts },
    };
    const term = cbor.Term{ .array = &msg_items };

    const reply = server.handleFindIntersect(alloc, term);
    try std.testing.expect(reply != null);
    if (reply) |r| alloc.free(r);

    // Backstop must record the matched intersect point.
    try std.testing.expectEqual(S, server.intersect_slot);
    try std.testing.expectEqualSlices(u8, &X, &server.intersect_hash);
    try std.testing.expect(server.need_rollback);
}

test "history ring overflow: oldest entry rolls out, newest survives" {
    var server = ChainSyncServer.init(.{
        .slot = 0,
        .block_no = 0,
        .hash = [_]u8{0} ** 32,
        .header_cbor = &[_]u8{},
    });
    // Fill past capacity by HISTORY_CAPACITY+10 entries. The first 10 should
    // have been overwritten; the last entries must still be findable.
    var i: usize = 0;
    while (i < HISTORY_CAPACITY + 10) : (i += 1) {
        var h: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u64, h[0..8], @as(u64, @intCast(i)), .little);
        server.pushHistory(@as(u64, @intCast(i)), h);
    }
    try std.testing.expectEqual(HISTORY_CAPACITY, server.history_len);

    // The very first entry (i=0) was overwritten.
    var first_hash: [32]u8 = [_]u8{0} ** 32;
    std.mem.writeInt(u64, first_hash[0..8], @as(u64, 0), .little);
    try std.testing.expect(server.lookupHistoryHash(first_hash) == null);

    // The most recently pushed entry must be present.
    var last_hash: [32]u8 = [_]u8{0} ** 32;
    std.mem.writeInt(u64, last_hash[0..8], @as(u64, HISTORY_CAPACITY + 9), .little);
    const found = server.lookupHistoryHash(last_hash) orelse return error.MissingHash;
    try std.testing.expectEqual(@as(u64, HISTORY_CAPACITY + 9), found.slot);
}
