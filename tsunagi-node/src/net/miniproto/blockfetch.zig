const std = @import("std");
const compat = @import("compat");
const Mux = @import("../mux.zig").Mux;
const byte_transport = @import("../transport/byte_transport.zig");
const mux_bearer = @import("../muxwire/mux_bearer.zig");
const cbor = @import("../cbor/term.zig");
const tx_decode = @import("../ledger/tx_decode.zig");
const tx_decoder = @import("../ledger/tx_decoder.zig");
const capture = @import("../../replay/capture.zig");
const http_metrics = @import("../metrics/http_metrics.zig");
const block_verify = @import("../ledger/block_hash.zig");

/// Callback invoked when a block is successfully fetched and deltas computed
pub const OnBlockFetched = *const fn (
    alloc: std.mem.Allocator,
    ctx: *anyopaque,
    slot: u64,
    block_no: u64,
    deltas: tx_decode.TxDeltas,
    tx_summaries: tx_decoder.BlockTxResult,
) void;

// Module state for callback
var g_on_block_fetched: ?OnBlockFetched = null;
var g_ctx: ?*anyopaque = null;
var g_current_slot: u64 = 0;
var g_current_block_no: u64 = 0;
// Announced header hash from ChainSync RollForward. Used to verify the block
// fetched via BlockFetch is actually the block we requested (defends against
// a peer serving a valid-but-different block than promised).
var g_expected_block_hash: [32]u8 = [_]u8{0} ** 32;

// Performance telemetry
pub var g_metrics: ?*http_metrics.Metrics = null;

// Body hash verification: set to true when a mismatch is detected.
// Caller should check after handleResponse and trigger reconnect.
pub var g_body_hash_mismatch: bool = false;

// Verbose logging gate: set once from TSUNAGI_BLOCKFETCH_VERBOSE=1
var g_verbose: bool = false;
var g_verbose_init: bool = false;

fn isVerbose() bool {
    if (g_verbose_init) return g_verbose;
    g_verbose_init = true;
    const v = compat.getEnvVarOwned(std.heap.page_allocator, "TSUNAGI_BLOCKFETCH_VERBOSE") catch {
        g_verbose = false;
        return false;
    };
    defer std.heap.page_allocator.free(v);
    g_verbose = std.mem.eql(u8, v, "1");
    return g_verbose;
}

fn nsToMs(ns: i128) u64 {
    if (ns <= 0) return 0;
    return @truncate(@as(u128, @bitCast(ns)) / 1_000_000);
}

fn nsToUs(ns: i128) u64 {
    if (ns <= 0) return 0;
    return @truncate(@as(u128, @bitCast(ns)) / 1_000);
}

// Reassembly state for large messages split across mux segments
const ReasmState = struct {
    buf: std.array_list.Managed(u8),
    expected: ?usize = null, // expected total message size once computed
};
var g_reasm: ?ReasmState = null;
var g_reassembly_alloc: ?std.mem.Allocator = null;

const MAX_MESSAGE_SIZE = 2 * 1024 * 1024; // 2MB safety limit

pub const BlockFetchState = enum {
    idle,
    range_requested,
};

pub const BlockFetch = struct {
    mux: *Mux,
    state: BlockFetchState = .idle,

    pub fn attach(m: *Mux) BlockFetch {
        return .{ .mux = m };
    }

    pub fn requestRange(self: *BlockFetch) !void {
        if (self.state != .idle) return error.InvalidState;
        try self.mux.send(.{ .blockfetch = .request_range });
        self.state = .range_requested;
    }
};

/// Fetch full block via BlockFetch protocol using block point (slot + block_header_hash)
/// This fetches the COMPLETE block with full tx bodies, not the compact hash-only version
pub fn requestBlock(
    alloc: std.mem.Allocator,
    bt: *byte_transport.ByteTransport,
    block_slot: u64,
    block_hash: [32]u8,
    block_no: u64,
    ctx: *anyopaque,
    on_block_fetched: OnBlockFetched,
) !void {
    if (isVerbose()) {
        std.debug.print("BLOCKFETCH: request block slot={d} hash={x}\n", .{
            block_slot,
            block_hash[0..4],
        });
    }

    // Store callback and context for response handler
    g_on_block_fetched = on_block_fetched;
    g_ctx = ctx;
    g_current_slot = block_slot;
    g_current_block_no = block_no;
    g_expected_block_hash = block_hash;

    // Initialize reassembly state if needed
    if (g_reasm == null) {
        g_reassembly_alloc = alloc;
        g_reasm = ReasmState{ .buf = std.array_list.Managed(u8).init(alloc) };
    }

    // Build CBOR RequestRange: [0, point_from, point_to]
    // point = [slot, hash_bytes] - must build TWO separate point arrays!
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();

    // Build point_from
    var from_items = try alloc.alloc(cbor.Term, 2);
    from_items[0] = cbor.Term{ .u64 = block_slot };
    from_items[1] = cbor.Term{ .bytes = try alloc.dupe(u8, block_hash[0..]) };
    const point_from = cbor.Term{ .array = from_items };

    // Build point_to (separate array, same values for single-block fetch)
    var to_items = try alloc.alloc(cbor.Term, 2);
    to_items[0] = cbor.Term{ .u64 = block_slot };
    to_items[1] = cbor.Term{ .bytes = try alloc.dupe(u8, block_hash[0..]) };
    const point_to = cbor.Term{ .array = to_items };

    // Build RequestRange: [0, from, to]
    var request_items = try alloc.alloc(cbor.Term, 3);
    request_items[0] = cbor.Term{ .u64 = 0 }; // RequestRange message ID
    request_items[1] = point_from;
    request_items[2] = point_to;
    const request_term = cbor.Term{ .array = request_items };

    // Encode to CBOR
    try cbor.encode(request_term, compat.listWriter(&buf));
    const request_payload = try buf.toOwnedSlice();
    defer alloc.free(request_payload);

    // Decode-verify: ensure we're sending correct structure
    var verify_fbs = compat.fixedBufferStream(request_payload);
    const verified = cbor.decode(alloc, verify_fbs.reader()) catch |err| {
        std.debug.print("BLOCKFETCH: encode-verify FAILED {}\n", .{err});
        cbor.free(request_term, alloc);
        return err;
    };
    defer cbor.free(verified, alloc);

    // Verify term shape and log decoded values
    if (verified == .array and verified.array.len == 3 and
        verified.array[0] == .u64 and verified.array[0].u64 == 0 and
        verified.array[1] == .array and verified.array[1].array.len == 2 and
        verified.array[2] == .array and verified.array[2].array.len == 2)
    {
        if (isVerbose()) {
            const from_point = verified.array[1].array;
            const to_point = verified.array[2].array;
            const from_slot = if (from_point[0] == .u64) from_point[0].u64 else 0;
            const from_hash = if (from_point[1] == .bytes) from_point[1].bytes else &[_]u8{};
            const to_slot = if (to_point[0] == .u64) to_point[0].u64 else 0;
            const to_hash = if (to_point[1] == .bytes) to_point[1].bytes else &[_]u8{};

            std.debug.print("BLOCKFETCH: verify RequestRange=[0,[{d},{x}],[{d},{x}]]\n", .{
                from_slot,
                from_hash[0..@min(4, from_hash.len)],
                to_slot,
                to_hash[0..@min(4, to_hash.len)],
            });
        }
    } else {
        std.debug.print("BLOCKFETCH: verify FAILED wrong shape\n", .{});
    }

    // Free the request term after encoding
    cbor.free(request_term, alloc);

    // Log CBOR hex for debugging (verbose only)
    if (isVerbose()) {
        const hex_len = @min(80, request_payload.len);
        std.debug.print("BLOCKFETCH: CBOR hex={x}\n", .{request_payload[0..hex_len]});
    }

    // Send RequestRange (use .responder direction like ChainSync)
    try mux_bearer.sendSegment(bt, .responder, 3, request_payload);
    if (isVerbose()) {
        std.debug.print("BLOCKFETCH: sent RequestRange proto=3 len={d} dir=responder\n", .{request_payload.len});
        std.debug.print("BLOCKFETCH: request sent, responses handled in main loop\n", .{});
    }
}

/// Compute expected total CBOR message size by parsing prefix
/// Returns null if not enough bytes to determine size
fn computeExpectedSize(bytes: []const u8) ?usize {
    if (bytes.len < 2) return null;

    var pos: usize = 0;

    // Parse top-level array [msg_id, ...]
    const arr_initial = bytes[pos];
    pos += 1;
    const arr_major = arr_initial >> 5;
    const arr_addl = arr_initial & 0x1f;

    if (arr_major != 4) return null; // must be array

    // Get array length (definite only)
    const arr_len: usize = if (arr_addl < 24)
        arr_addl
    else if (arr_addl == 24 and pos < bytes.len) blk: {
        pos += 1;
        break :blk bytes[pos - 1];
    } else return null;

    if (arr_len == 0) return null;

    // Parse msg_id (should be u64)
    if (pos >= bytes.len) return null;
    const msg_initial = bytes[pos];
    pos += 1;
    const msg_major = msg_initial >> 5;
    const msg_addl = msg_initial & 0x1f;

    if (msg_major != 0) return null; // msg_id must be unsigned
    const msg_id: u64 = if (msg_addl < 24) msg_addl else return null;

    // For Block message (id=4), need to parse tag+bytes or direct bytes
    if (msg_id == 4 and arr_len >= 2) {
        if (pos >= bytes.len) return null;
        const block_initial = bytes[pos];
        const block_major = block_initial >> 5;

        // Handle tag wrapper (tag 24 = 0xd8 0x18)
        if (block_major == 6) {
            pos += 1; // skip tag initial
            if (pos >= bytes.len) return null;
            const tag_num = bytes[pos];
            pos += 1;
            if (tag_num != 24) return null; // only handle tag 24

            // Now parse the wrapped bytes
            if (pos >= bytes.len) return null;
            const bytes_initial = bytes[pos];
            const bytes_major = bytes_initial >> 5;
            if (bytes_major != 2) return null; // must be bytes
            return parseBytesLength(bytes, pos);
        }
        // Direct bytes (no tag)
        else if (block_major == 2) {
            return parseBytesLength(bytes, pos);
        }
    }

    // For other messages: NoBlocks [3], BatchDone [5], or simple 1-element arrays
    // If arr_len == 1 and we have the msg_id, the message is complete
    if (arr_len == 1 and msg_addl < 24) {
        // Message is just [msg_id], size is 2 bytes total
        return pos; // pos is already at end after reading msg_id
    }

    // For StartBatch [2, ...] or other complex messages, need more sophisticated parsing
    // For now, use heuristic: if we have >64 bytes it's likely complete
    if (bytes.len >= 64) return bytes.len;

    return null;
}

/// Parse CBOR bytes length starting at pos, return total message size
fn parseBytesLength(bytes: []const u8, pos: usize) ?usize {
    if (pos >= bytes.len) return null;
    const initial = bytes[pos];
    const addl = initial & 0x1f;

    var hdr_len: usize = 1; // initial byte
    const payload_len: usize = if (addl < 24) addl else if (addl == 24 and pos + 1 < bytes.len) blk: {
        hdr_len += 1;
        break :blk bytes[pos + 1];
    } else if (addl == 25 and pos + 2 < bytes.len) blk: {
        hdr_len += 2;
        const b1 = @as(u16, bytes[pos + 1]);
        const b2 = @as(u16, bytes[pos + 2]);
        break :blk (b1 << 8) | b2;
    } else if (addl == 26 and pos + 4 < bytes.len) blk: {
        hdr_len += 4;
        const b1 = @as(u32, bytes[pos + 1]);
        const b2 = @as(u32, bytes[pos + 2]);
        const b3 = @as(u32, bytes[pos + 3]);
        const b4 = @as(u32, bytes[pos + 4]);
        break :blk (b1 << 24) | (b2 << 16) | (b3 << 8) | b4;
    } else return null;

    // Total = everything up to and including the bytes
    return pos + hdr_len + payload_len;
}

/// Decode and handle a BlockFetch response message
/// Called from main message loop when proto=3 message arrives
/// Handles mux segment reassembly for large messages (>12KB)
pub fn handleResponse(alloc: std.mem.Allocator, payload: []const u8) !void {
    var reasm = &(g_reasm orelse return error.NotInitialized);
    const prev_len = reasm.buf.items.len;

    // Append segment to reassembly buffer
    try reasm.buf.appendSlice(payload);

    if (prev_len > 0 and isVerbose()) {
        std.debug.print("BLOCKFETCH: segment append len={d} total={d}\n", .{ payload.len, reasm.buf.items.len });
    }

    // Safety check: enforce max message size
    if (reasm.buf.items.len > MAX_MESSAGE_SIZE) {
        std.debug.print("BLOCKFETCH: message too large {d}, clearing\n", .{reasm.buf.items.len});
        reasm.buf.clearRetainingCapacity();
        reasm.expected = null;
        return error.MessageTooLarge;
    }

    // Process complete messages from buffer
    while (reasm.buf.items.len > 0) {
        // Compute expected size if not yet known
        if (reasm.expected == null) {
            reasm.expected = computeExpectedSize(reasm.buf.items);
            if (reasm.expected) |exp| {
                if (isVerbose()) std.debug.print("BLOCKFETCH: computed expected size={d} have={d}\n", .{ exp, reasm.buf.items.len });
            }
        }

        // Check if we have complete message
        const expected = reasm.expected orelse {
            // Can't determine size yet, need more data
            if (prev_len == 0 and isVerbose()) {
                std.debug.print("BLOCKFETCH: need more data to determine size (have {d} bytes)\n", .{reasm.buf.items.len});
            }
            return;
        };

        if (reasm.buf.items.len < expected) {
            // Incomplete message, wait for more segments
            return;
        }

        // We have enough bytes, decode exactly expected bytes
        var fbs = compat.fixedBufferStream(reasm.buf.items[0..expected]);
        const resp = cbor.decode(alloc, fbs.reader()) catch |err| {
            std.debug.print("BLOCKFETCH: decode error {} at expected={d}\n", .{ err, expected });
            // Clear and reset on decode error
            reasm.buf.clearRetainingCapacity();
            reasm.expected = null;
            return err;
        };
        defer cbor.free(resp, alloc);

        if (prev_len == 0 and expected > 1024 and isVerbose()) {
            std.debug.print("BLOCKFETCH: full message decoded len={d}\n", .{expected});
        }

        // Handle the decoded message
        try handleDecodedMessage(alloc, resp);

        // Remove consumed bytes from buffer, keep remainder
        if (expected < reasm.buf.items.len) {
            const remaining = reasm.buf.items.len - expected;
            std.mem.copyForwards(u8, reasm.buf.items[0..remaining], reasm.buf.items[expected..]);
            reasm.buf.shrinkRetainingCapacity(remaining);
            reasm.expected = null; // reset for next message
        } else {
            // All bytes consumed
            reasm.buf.clearRetainingCapacity();
            reasm.expected = null;
            break;
        }
    }
}

fn getStateDir(alloc: std.mem.Allocator) ![]u8 {
    const env_dir = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
    if (env_dir) |dir| return dir;
    const home = try compat.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(home);
    return try std.fs.path.join(alloc, &[_][]const u8{ home, ".tsunagi" });
}

/// Handle a decoded BlockFetch response message
fn handleDecodedMessage(alloc: std.mem.Allocator, resp: cbor.Term) !void {
    if (resp != .array or resp.array.len == 0) {
        std.debug.print("BLOCKFETCH: invalid response {s}\n", .{@tagName(resp)});
        return error.InvalidResponse;
    }

    const msg_id = if (resp.array[0] == .u64) resp.array[0].u64 else 999;

    // Debug: log response structure (verbose only)
    if (msg_id == 4 and isVerbose()) {
        std.debug.print("BLOCKFETCH: Block response len={d} items: ", .{resp.array.len});
        var i: usize = 0;
        while (i < @min(resp.array.len, 4)) : (i += 1) {
            std.debug.print("[{d}]={s} ", .{ i, @tagName(resp.array[i]) });
        }
        std.debug.print("\n", .{});
    }

    switch (msg_id) {
        2 => {
            // StartBatch
            if (isVerbose()) std.debug.print("BLOCKFETCH: StartBatch\n", .{});
        },
        3 => {
            // NoBlocks
            std.debug.print("BLOCKFETCH: NoBlocks\n", .{});
        },
        4 => {
            // Block - contains full block with tx bodies, wrapped in tag
            if (resp.array.len >= 2) {
                // Block can be [4, bytes] or [4, tag(bytes)]
                const block_data = resp.array[1];
                const block_bytes = if (block_data == .bytes)
                    block_data.bytes
                else if (block_data == .tag and block_data.tag.value.* == .bytes)
                    block_data.tag.value.*.bytes
                else
                    null;

                if (block_bytes) |bytes| {
                    if (isVerbose()) {
                        const prefix = bytes[0..@min(8, bytes.len)];
                        std.debug.print("BLOCKFETCH: Block len={d} prefix={x}\n", .{
                            bytes.len,
                            prefix,
                        });
                    }

                    // Save block bytes for propagation harness (chain_tip/block.cbor)
                    saveChainTipBlock(bytes);

                    // Capture raw block bytes if enabled
                    if (capture.enabled()) {
                        const state_dir = getStateDir(alloc) catch null;
                        if (state_dir) |sd| {
                            defer alloc.free(sd);
                            capture.appendRecord(alloc, sd, bytes) catch |err| {
                                std.debug.print("CAPTURE: appendRecord error {s}\n", .{@errorName(err)});
                            };
                        }
                    }

                    // Performance: start block total timer
                    const block_t0 = compat.nanoTimestamp();

                    // Per-block arena: all CBOR term tree allocations are bulk-freed
                    // when the arena is destroyed, preventing allocator fragmentation.
                    // Only TxDeltas (passed to callback) use the long-lived 'alloc'.
                    var arena = std.heap.ArenaAllocator.init(alloc);
                    defer arena.deinit();
                    const a = arena.allocator();

                    // Decode full block bytes into CBOR Term (arena-allocated)
                    const decode_t0 = compat.nanoTimestamp();
                    var block_fbs = compat.fixedBufferStream(bytes);
                    const term = cbor.decode(a, block_fbs.reader()) catch |err| {
                        const pos = block_fbs.pos;
                        std.debug.print("BLOCKFETCH: decode error {} at pos={d}/{d}\n", .{ err, pos, bytes.len });

                        // Dump block bytes to file for offline analysis
                        if (compat.fs.cwd().createFile("/tmp/blockfetch_block.bin", .{ .truncate = true })) |file_const| {
                            var file = file_const;
                            defer file.close();
                            file.writeAll(bytes) catch {};
                            std.debug.print("BLOCKFETCH: dumped {d} bytes to /tmp/blockfetch_block.bin\n", .{bytes.len});
                        } else |_| {}

                        // Dump failure position
                        if (compat.fs.cwd().createFile("/tmp/blockfetch_failpos.txt", .{ .truncate = true })) |file_const| {
                            var file = file_const;
                            defer file.close();
                            var buf: [100]u8 = undefined;
                            const msg = std.fmt.bufPrint(&buf, "pos={d} len={d} error={s}\n", .{ pos, bytes.len, @errorName(err) }) catch "error\n";
                            file.writeAll(msg) catch {};
                        } else |_| {}

                        if (isVerbose() and pos > 0 and pos < bytes.len) {
                            const fail_byte = bytes[pos];
                            const major = fail_byte >> 5;
                            const addl = fail_byte & 0x1f;
                            std.debug.print("BLOCKFETCH: fail byte=0x{x:0>2} major={d} addl={d}\n", .{ fail_byte, major, addl });

                            // Show wider context for analysis
                            const context_start = if (pos >= 16) pos - 16 else 0;
                            const context_end = @min(pos + 32, bytes.len);
                            std.debug.print("BLOCKFETCH: context [{d}..{d}]:\n", .{ context_start, context_end });

                            // Print in lines of 16 bytes
                            var i = context_start;
                            while (i < context_end) {
                                const line_end = @min(i + 16, context_end);
                                const marker = if (i <= pos and pos < line_end) " <--" else "";
                                std.debug.print("  {d:4}: {x}{s}\n", .{
                                    i,
                                    bytes[i..line_end],
                                    marker,
                                });
                                i = line_end;
                            }
                        }
                        return;
                    };
                    // No need for defer cbor.free(term, a) — arena.deinit() bulk-frees all
                    const decode_elapsed = compat.nanoTimestamp() - decode_t0;
                    if (g_metrics) |m| {
                        m.perf_blockfetch_decode_ms.store(nsToMs(decode_elapsed), .release);
                        m.perf_blockfetch_decode_us.store(nsToUs(decode_elapsed), .release);
                    }

                    // Log decoded term structure (verbose only)
                    if (term == .array and term.array.len >= 2) {
                        if (isVerbose()) {
                            std.debug.print("BLOCKFETCH: decoded array len={d} [0]={s} [1]={s}\n", .{
                                term.array.len,
                                @tagName(term.array[0]),
                                @tagName(term.array[1]),
                            });
                        }
                    } else {
                        if (isVerbose()) std.debug.print("BLOCKFETCH: decoded {s}\n", .{@tagName(term)});
                        return;
                    }

                    // BlockFetch block structure: [era, block_content]
                    // block_content is [header, body, witnesses, metadata, invalid_txs]
                    // We need to pass block_content (not full term) to extractTxListFromTermPublic
                    const block_content = if (term.array.len >= 2) term.array[1] else term;

                    // Header hash verification: ensure the peer served the block we
                    // actually requested (blake2b256(header_cbor) == announced hash).
                    // Hard gate: on mismatch we skip decode/apply and flag for reconnect.
                    const zero_hash = std.mem.eql(u8, &g_expected_block_hash, &[_]u8{0} ** 32);
                    if (!zero_hash) {
                        if (block_verify.extractHeaderRegion(bytes)) |hdr_region| {
                            const computed_header_hash = block_verify.blake2b256(hdr_region);
                            if (!std.mem.eql(u8, &computed_header_hash, &g_expected_block_hash)) {
                                std.debug.print("BLOCK_VALIDATION_FAIL reason=header_hash_mismatch slot={d} block={d} expected={x} computed={x}\n", .{
                                    g_current_slot,
                                    g_current_block_no,
                                    g_expected_block_hash[0..8],
                                    computed_header_hash[0..8],
                                });
                                g_body_hash_mismatch = true; // reuse reconnect/reject channel
                                return;
                            }
                        } else {
                            std.debug.print("BLOCK_VALIDATION_FAIL reason=header_region_parse slot={d} block={d}\n", .{
                                g_current_slot,
                                g_current_block_no,
                            });
                            g_body_hash_mismatch = true;
                            return;
                        }
                    }

                    // Body hash verification: compare header commitment against computed hash
                    // Cardano uses a merkle-style "hash of hashes":
                    //   blake2b256(blake2b256(tx_bodies) || blake2b256(witnesses) || blake2b256(aux_data) || blake2b256(invalid_txs))
                    if (block_content == .array and block_content.array.len >= 2) body_verify: {
                        const header_term = block_content.array[0];

                        const committed_hash = block_verify.extractBodyHashFromHeader(header_term) orelse {
                            if (g_metrics) |m| {
                                _ = m.block_body_hash_missing_total.fetchAdd(1, .acq_rel);
                            }
                            break :body_verify;
                        };

                        const body_parts = block_verify.extractBodyParts(bytes) orelse {
                            if (g_metrics) |m| {
                                _ = m.block_body_hash_missing_total.fetchAdd(1, .acq_rel);
                            }
                            break :body_verify;
                        };

                        const computed_hash = block_verify.computeBodyHash(body_parts);

                        if (!std.mem.eql(u8, &computed_hash, &committed_hash)) {
                            if (g_metrics) |m| {
                                _ = m.block_body_hash_mismatch_total.fetchAdd(1, .acq_rel);
                                _ = m.block_body_hash_reject_total.fetchAdd(1, .acq_rel);
                                const now: u64 = @intCast(@max(0, compat.timestamp()));
                                m.block_body_hash_last_fail_unix.store(now, .release);
                            }
                            std.debug.print("BLOCK_VALIDATION_FAIL reason=body_hash_mismatch slot={d} block={d} committed={x} computed={x}\n", .{
                                g_current_slot,
                                g_current_block_no,
                                committed_hash[0..8],
                                computed_hash[0..8],
                            });
                            g_body_hash_mismatch = true;
                            return; // hard gate: no tx_decode, no deltas, no LMDB write
                        }

                        // Verification succeeded
                        if (g_metrics) |m| {
                            _ = m.block_body_hash_verified_total.fetchAdd(1, .acq_rel);
                            const now: u64 = @intCast(@max(0, compat.timestamp()));
                            m.block_body_hash_last_ok_unix.store(now, .release);
                        }
                    }

                    // Extract tx list from the block content
                    // tx_list is a slice into arena-owned term tree (no allocation)
                    const tx_t0 = compat.nanoTimestamp();
                    if (tx_decode.extractTxListFromTermPublic(a, block_content)) |scan| {
                        // NOTE: scan.owner is term (same), so don't free scan separately
                        const tx_list = scan.tx_list;

                        // Canonical txids from original block bytes (no alloc, stack only)
                        var txid_buf: [block_verify.MAX_TX_HASHES][32]u8 = undefined;
                        const txid_count = if (block_verify.extractBodyParts(bytes)) |parts|
                            block_verify.extractTxBodyHashes(parts.tx_bodies, &txid_buf)
                        else
                            @as(usize, 0);
                        const c_txids: ?[]const [32]u8 = if (txid_count > 0) txid_buf[0..txid_count] else null;

                        // Compute TxDeltas from full tx bodies
                        // LIFETIME: deltas are alloc-owned (not arena) so they survive
                        // arena.deinit() and can be passed to onBlockFetched callback.
                        // tx_list (arena-owned views into term) is only read here.
                        const deltas = tx_decode.extractTxDeltas(alloc, tx_list, c_txids, true) catch |err| {
                            std.debug.print("BLOCKFETCH: extractTxDeltas error {}\n", .{err});
                            return;
                        };
                        const tx_elapsed = compat.nanoTimestamp() - tx_t0;
                        if (g_metrics) |m| {
                            m.perf_tx_extract_ms.store(nsToMs(tx_elapsed), .release);
                            m.perf_tx_extract_us.store(nsToUs(tx_elapsed), .release);
                        }

                        if (deltas.consumed.len == 0 and deltas.produced.len == 0) {
                            if (isVerbose()) std.debug.print("BLOCKFETCH: deltas empty tx_count={d}\n", .{tx_list.len});
                            tx_decode.freeTxDeltas(alloc, deltas);
                        } else {
                            if (isVerbose()) {
                                std.debug.print("BLOCKFETCH: deltas tx_count={d} consumed={d} produced={d}\n", .{
                                    tx_list.len,
                                    deltas.consumed.len,
                                    deltas.produced.len,
                                });
                            }

                            // Extract tx summaries with raw CBOR for withdrawal lovelace
                            const raw_tb: ?[]const u8 = if (block_verify.extractBodyParts(bytes)) |p| p.tx_bodies else null;
                            const bf_summaries = tx_decoder.extractTxSummariesWithRaw(alloc, tx_list, raw_tb);

                            // Invoke callback to apply deltas in follower
                            if (g_on_block_fetched) |callback| {
                                if (g_ctx) |ctx| {
                                    callback(alloc, ctx, g_current_slot, g_current_block_no, deltas, bf_summaries);
                                }
                            }

                            // Callback frees deltas
                        }
                        // Block total time (decode + tx extract + callback/LMDB)
                        const block_elapsed = compat.nanoTimestamp() - block_t0;
                        if (g_metrics) |m| {
                            m.perf_block_total_ms.store(nsToMs(block_elapsed), .release);
                            m.perf_block_total_us.store(nsToUs(block_elapsed), .release);
                        }
                    } else {
                        if (isVerbose()) {
                            std.debug.print("BLOCKFETCH: no tx list in block\n", .{});

                            // Diagnostic: log term structure
                            if (term == .array and term.array.len >= 2 and term.array[1] == .array) {
                                const body = term.array[1].array;
                                std.debug.print("BLOCKFETCH: body array len={d}", .{body.len});
                                if (body.len > 0) {
                                    const max = @min(3, body.len);
                                    var i: usize = 0;
                                    while (i < max) : (i += 1) {
                                        std.debug.print(" [{d}]={s}", .{ i, @tagName(body[i]) });
                                    }
                                }
                                std.debug.print("\n", .{});
                            }
                        }
                    }
                } else {
                    if (isVerbose()) std.debug.print("BLOCKFETCH: Block wrong type {s}\n", .{@tagName(block_data)});
                }
            } else {
                if (isVerbose()) std.debug.print("BLOCKFETCH: Block resp.len={d}\n", .{resp.array.len});
            }
        },
        5 => {
            // BatchDone
            if (isVerbose()) std.debug.print("BLOCKFETCH: BatchDone\n", .{});
            if (g_metrics) |m| {
                _ = m.blockfetch_batch_done_total.fetchAdd(1, .acq_rel);
                m.consensus_last_blockfetch_batch_unix.store(@intCast(compat.timestamp()), .release);
            }
        },
        else => {
            std.debug.print("BLOCKFETCH: unknown msg_id={d}\n", .{msg_id});
        },
    }
}

// ── Chain tip block capture for propagation ─────────────────────────
// Saves the latest fetched block CBOR to $TSUNAGI_HOME/chain_tip/block.cbor.
// Rate-limited to once per 10s. Dedicated limiter (not shared with header capture).

pub var g_last_chain_tip_block_save_unix: u64 = 0;

fn saveChainTipBlock(block_bytes: []const u8) void {
    const slot = g_current_slot;
    const block_no = g_current_block_no;
    const now: u64 = @intCast(@max(compat.timestamp(), 0));

    std.debug.print("CHAIN_TIP_BLOCK: enter now={d} slot={d} block_no={d} len={d}\n", .{
        now, slot, block_no, block_bytes.len,
    });

    if (block_bytes.len == 0) return;

    if (g_last_chain_tip_block_save_unix > 0 and now - g_last_chain_tip_block_save_unix < 10) {
        std.debug.print("CHAIN_TIP_BLOCK: skip rate_limit now={d} last={d} slot={d} block_no={d}\n", .{
            now, g_last_chain_tip_block_save_unix, slot, block_no,
        });
        return;
    }

    const pa = std.heap.page_allocator;
    const home = compat.getEnvVarOwned(pa, "TSUNAGI_HOME") catch |err| {
        std.debug.print("CHAIN_TIP_BLOCK: ERROR TSUNAGI_HOME: {any}\n", .{err});
        return;
    };
    defer pa.free(home);

    const dir_path = std.fmt.allocPrint(pa, "{s}/chain_tip", .{home}) catch |err| {
        std.debug.print("CHAIN_TIP_BLOCK: ERROR allocPrint dir: {any}\n", .{err});
        return;
    };
    defer pa.free(dir_path);

    compat.fs.cwd().makePath(dir_path) catch |err| {
        std.debug.print("CHAIN_TIP_BLOCK: ERROR mkdir {s}: {any}\n", .{ dir_path, err });
        return;
    };

    const tmp_path = std.fmt.allocPrint(pa, "{s}/block.cbor.tmp", .{dir_path}) catch |err| {
        std.debug.print("CHAIN_TIP_BLOCK: ERROR allocPrint tmp: {any}\n", .{err});
        return;
    };
    defer pa.free(tmp_path);
    const final_path = std.fmt.allocPrint(pa, "{s}/block.cbor", .{dir_path}) catch |err| {
        std.debug.print("CHAIN_TIP_BLOCK: ERROR allocPrint final: {any}\n", .{err});
        return;
    };
    defer pa.free(final_path);

    var file = compat.fs.cwd().createFile(tmp_path, .{}) catch |err| {
        std.debug.print("CHAIN_TIP_BLOCK: ERROR open {s}: {any}\n", .{ tmp_path, err });
        return;
    };
    file.writeAll(block_bytes) catch |err| {
        file.close();
        std.debug.print("CHAIN_TIP_BLOCK: ERROR write {s}: {any}\n", .{ tmp_path, err });
        return;
    };
    file.sync() catch |err| {
        std.debug.print("CHAIN_TIP_BLOCK: WARN fsync file: {any}\n", .{err});
    };
    file.close();

    compat.fs.cwd().rename(tmp_path, final_path) catch |err| {
        std.debug.print("CHAIN_TIP_BLOCK: ERROR rename {s} -> {s}: {any}\n", .{ tmp_path, final_path, err });
        return;
    };

    g_last_chain_tip_block_save_unix = now;
    std.debug.print("CHAIN_TIP_BLOCK: saved ok path={s} slot={d} block_no={d} len={d}\n", .{
        final_path, slot, block_no, block_bytes.len,
    });
}
