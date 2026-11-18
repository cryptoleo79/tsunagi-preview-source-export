const std = @import("std");
const compat = @import("compat");
const cbor = @import("../net/cbor/term.zig");
const mux_bearer = @import("../net/muxwire/mux_bearer.zig");
const bt_mod = @import("../net/transport/byte_transport.zig");

// ── BlockFetch Server (v4.5.25) ────────────────────────────────────
//
// Multi-block BlockFetch server: serves fragment bodies + sealed tip.
// Responds to MsgRequestRange with StartBatch + Block + BatchDone.
//
// Protocol number: BlockFetch = 3.
//
// CBOR message tags (Cardano miniprotocol):
//   MsgRequestRange = [0, point_from, point_to]
//   MsgClientDone   = [1]
//   MsgStartBatch   = [2]
//   MsgNoBlocks     = [3]
//   MsgBlock        = [4, block_cbor_wrapped]
//   MsgBatchDone    = [5]

pub const blockfetch_proto: u16 = 3;

/// Encode a single MsgNoBlocks reply as a one-element response slice.
/// Usable from contexts where no BlockFetchServer instance exists yet
/// (e.g. early-exit paths in the propagation server when bf_server is null).
pub fn encodeNoBlocksStandalone(alloc: std.mem.Allocator) ?[]const []u8 {
    const msg = BlockFetchServer.encodeSimple(alloc, 3) orelse return null;
    var responses = alloc.alloc([]u8, 1) catch {
        alloc.free(msg);
        return null;
    };
    responses[0] = msg;
    return responses;
}

pub const SealedBlock = struct {
    slot: u64,
    hash: [32]u8,
    block_cbor: []const u8,
};

pub const BlockFetchServer = struct {
    blocks: []const SealedBlock,
    served_block: bool = false,

    pub fn init(blocks: []const SealedBlock) BlockFetchServer {
        return .{ .blocks = blocks };
    }

    /// Handle an incoming BlockFetch message payload.
    /// Returns a list of response payloads to send (may be multiple: StartBatch, Block, BatchDone).
    /// Returns null on MsgClientDone or error.
    pub fn handleMessage(self: *BlockFetchServer, alloc: std.mem.Allocator, payload: []const u8) ?[]const []u8 {
        var fbs = compat.fixedBufferStream(payload);
        const term = cbor.decode(alloc, fbs.reader()) catch {
            std.debug.print("BF_EARLY_EXIT: reason=cbor_decode_failed\n", .{});
            return null;
        };
        defer cbor.free(term, alloc);

        if (term != .array or term.array.len < 1) {
            std.debug.print("BF_EARLY_EXIT: reason=cbor_decode_failed\n", .{});
            return null;
        }
        if (term.array[0] != .u64) {
            std.debug.print("BF_EARLY_EXIT: reason=cbor_decode_failed\n", .{});
            return null;
        }

        const tag = term.array[0].u64;
        return switch (tag) {
            0 => self.handleRequestRange(alloc, term),
            1 => blk: {
                std.debug.print("BF_EARLY_EXIT: reason=client_done\n", .{});
                break :blk null;
            }, // MsgClientDone
            else => blk: {
                std.debug.print("BF_EARLY_EXIT: reason=handle_message_null\n", .{});
                break :blk null;
            },
        };
    }

    fn handleRequestRange(self: *BlockFetchServer, alloc: std.mem.Allocator, term: cbor.Term) ?[]const []u8 {
        // MsgRequestRange = [0, point_from, point_to]
        if (term.array.len < 3) {
            std.debug.print("blockfetch: RequestRange malformed (len={d})\n", .{term.array.len});
            std.debug.print("BF_EARLY_EXIT: reason=range_invalid\n", .{});
            return self.encodeNoBlocks(alloc);
        }

        const point_from = term.array[1];
        const point_to = term.array[2];

        // Log the request
        const from_slot = if (point_from == .array and point_from.array.len >= 1 and point_from.array[0] == .u64)
            point_from.array[0].u64
        else
            0;
        const to_slot = if (point_to == .array and point_to.array.len >= 1 and point_to.array[0] == .u64)
            point_to.array[0].u64
        else
            0;
        std.debug.print("blockfetch: RequestRange start_slot={d} end_slot={d} fetchable_count={d}\n", .{
            from_slot, to_slot, self.blocks.len,
        });

        if (self.blocks.len == 0) {
            std.debug.print("BF_EARLY_EXIT: reason=no_artifact\n", .{});
            return self.encodeNoBlocks(alloc);
        }

        const found = self.findBlock(point_from) orelse {
            std.debug.print("blockfetch: RequestRange point mismatch -> NoBlocks\n", .{});
            std.debug.print("BF_EARLY_EXIT: reason=slot_mismatch\n", .{});
            return self.encodeNoBlocks(alloc);
        };

        // Serve the block: StartBatch + Block + BatchDone
        std.debug.print("blockfetch: StartBatch\n", .{});
        const start_batch = encodeSimple(alloc, 2) orelse {
            std.debug.print("BF_EARLY_EXIT: reason=responses_alloc_failed\n", .{});
            return null;
        };
        const block_msg = encodeBlockCbor(alloc, found.block_cbor) orelse {
            alloc.free(start_batch);
            std.debug.print("BF_EARLY_EXIT: reason=responses_alloc_failed\n", .{});
            return null;
        };
        std.debug.print("blockfetch: sending Block len={d}\n", .{found.block_cbor.len});
        const batch_done = encodeSimple(alloc, 5) orelse {
            alloc.free(start_batch);
            alloc.free(block_msg);
            std.debug.print("BF_EARLY_EXIT: reason=responses_alloc_failed\n", .{});
            return null;
        };
        std.debug.print("blockfetch: BatchDone\n", .{});

        var responses = alloc.alloc([]u8, 3) catch {
            alloc.free(start_batch);
            alloc.free(block_msg);
            alloc.free(batch_done);
            std.debug.print("BF_EARLY_EXIT: reason=responses_alloc_failed\n", .{});
            return null;
        };
        responses[0] = start_batch;
        responses[1] = block_msg;
        responses[2] = batch_done;

        self.served_block = true;
        return responses;
    }

    fn findBlock(self: *BlockFetchServer, point: cbor.Term) ?SealedBlock {
        if (point != .array or point.array.len != 2) return null;
        if (point.array[0] != .u64) return null;
        const slot = point.array[0].u64;
        if (point.array[1] != .bytes) return null;
        if (point.array[1].bytes.len != 32) return null;
        for (self.blocks) |blk| {
            if (blk.slot == slot and std.mem.eql(u8, point.array[1].bytes, &blk.hash)) return blk;
        }
        // TEMPORARY DEBUG AID — slot-only fallback gated on
        // TSUNAGI_BF_FORCE_SLOT_MATCH. Used to prove the serve mechanism works
        // when the hash component is the only thing diverging (e.g. relay
        // requesting our point with a stale or projected hash). REVERT once the
        // root cause is identified. Risk: serves the wrong block on a fork —
        // accepted ONLY when operator explicitly opts in via the env flag.
        if (compat.getenv("TSUNAGI_BF_FORCE_SLOT_MATCH") != null) {
            for (self.blocks) |blk| {
                if (blk.slot == slot) {
                    std.debug.print("BF_FORCE_MATCH: slot={d} hash_match=false_but_slot_match\n", .{slot});
                    return blk;
                }
            }
        }
        return null;
    }

    fn encodeBlockCbor(alloc: std.mem.Allocator, block_cbor: []const u8) ?[]u8 {
        // MsgBlock = [4, block_cbor_wrapped]
        // block_cbor_wrapped = tag(24, bytes(block_cbor))
        var list = std.array_list.Managed(u8).init(alloc);
        const w = compat.listWriter(&list);

        const inner_tag = alloc.create(cbor.Term) catch return null;
        inner_tag.* = .{ .bytes = block_cbor };

        var items: [2]cbor.Term = undefined;
        items[0] = .{ .u64 = 4 };
        items[1] = .{ .tag = .{ .tag = 24, .value = inner_tag } };

        const arr_term = cbor.Term{ .array = &items };
        cbor.encode(arr_term, w) catch {
            alloc.destroy(inner_tag);
            list.deinit();
            return null;
        };
        alloc.destroy(inner_tag);
        return list.toOwnedSlice() catch null;
    }

    fn encodeNoBlocks(self: *BlockFetchServer, alloc: std.mem.Allocator) ?[]const []u8 {
        _ = self;
        return encodeNoBlocksStandalone(alloc);
    }

    fn encodeSimple(alloc: std.mem.Allocator, msg_tag: u64) ?[]u8 {
        var list = std.array_list.Managed(u8).init(alloc);
        const w = compat.listWriter(&list);

        var items: [1]cbor.Term = undefined;
        items[0] = .{ .u64 = msg_tag };
        const arr_term = cbor.Term{ .array = &items };
        cbor.encode(arr_term, w) catch {
            list.deinit();
            return null;
        };
        return list.toOwnedSlice() catch null;
    }
};
