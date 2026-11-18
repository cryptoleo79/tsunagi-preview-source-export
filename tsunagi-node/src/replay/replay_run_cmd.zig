const std = @import("std");
const compat = @import("compat");
const cbor = @import("../net/cbor/term.zig");
const tx_decode = @import("../net/ledger/tx_decode.zig");
const utxo_mod = @import("../net/ledger/utxo.zig");
const lmdb_utxo = @import("../store/lmdb_utxo.zig");
const header_store_mod = @import("../store/header_store.zig");
const block_hash = @import("../net/ledger/block_hash.zig");

const RECORD_MAX_LEN: u32 = 16 * 1024 * 1024; // 16MB
const PROGRESS_INTERVAL: usize = 500;

/// Per-block skip/apply reason counters.
const Coverage = struct {
    applied_ok: u64 = 0,
    skipped_missing_inputs: u64 = 0,
    skipped_bodyhash_missing: u64 = 0,
    skipped_bodyhash_mismatch: u64 = 0,
    skipped_header_integrity_fail: u64 = 0,
    skipped_ledger_violation: u64 = 0,
    skipped_decode_error: u64 = 0,
    skipped_other: u64 = 0,
    errors_total: u64 = 0,

    fn skippedTotal(self: Coverage) u64 {
        return self.skipped_missing_inputs +
            self.skipped_bodyhash_missing +
            self.skipped_bodyhash_mismatch +
            self.skipped_header_integrity_fail +
            self.skipped_ledger_violation +
            self.skipped_decode_error +
            self.skipped_other;
    }

    fn topSkipReason(self: Coverage) struct { name: []const u8, count: u64 } {
        const counts = [_]u64{
            self.skipped_missing_inputs,
            self.skipped_bodyhash_missing,
            self.skipped_bodyhash_mismatch,
            self.skipped_header_integrity_fail,
            self.skipped_ledger_violation,
            self.skipped_decode_error,
            self.skipped_other,
        };
        const names = [_][]const u8{
            "missing_inputs",
            "bodyhash_missing",
            "bodyhash_mismatch",
            "header_integrity",
            "ledger_violation",
            "decode_error",
            "other",
        };
        var best_idx: usize = 0;
        var best_count: u64 = 0;
        for (counts, 0..) |c, i| {
            if (c > best_count) {
                best_count = c;
                best_idx = i;
            }
        }
        if (best_count == 0) return .{ .name = "none", .count = 0 };
        return .{ .name = names[best_idx], .count = best_count };
    }

    fn printSummary(self: Coverage, blocks: u64) void {
        const skip_total = self.skippedTotal();
        const pct: f64 = if (blocks > 0)
            @as(f64, @floatFromInt(self.applied_ok)) / @as(f64, @floatFromInt(blocks)) * 100.0
        else
            0.0;
        const top = self.topSkipReason();

        std.debug.print("\nREPLAY COVERAGE:\n", .{});
        std.debug.print("  applied_ok={d}\n", .{self.applied_ok});
        std.debug.print("  skipped_total={d}\n", .{skip_total});
        std.debug.print("  - missing_inputs={d}\n", .{self.skipped_missing_inputs});
        std.debug.print("  - bodyhash_missing={d}\n", .{self.skipped_bodyhash_missing});
        std.debug.print("  - bodyhash_mismatch={d}\n", .{self.skipped_bodyhash_mismatch});
        std.debug.print("  - header_integrity={d}\n", .{self.skipped_header_integrity_fail});
        std.debug.print("  - ledger_violation={d}\n", .{self.skipped_ledger_violation});
        std.debug.print("  - decode_error={d}\n", .{self.skipped_decode_error});
        std.debug.print("  - other={d}\n", .{self.skipped_other});
        std.debug.print("  errors_total={d}\n", .{self.errors_total});
        std.debug.print("  coverage={d}/{d} ({d:.2}%)\n", .{ self.applied_ok, blocks, pct });
        std.debug.print("  top_skip_reason={s} ({d})\n", .{ top.name, top.count });
    }
};

/// Extract a 32-byte hash from a CBOR Term (raw bytes or Tag-wrapped bytes).
fn extractHash32(term: cbor.Term) ?[32]u8 {
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

/// Skip one complete CBOR data item in raw bytes, returning the number of bytes consumed.
fn skipCborItem(data: []const u8) ?usize {
    if (data.len == 0) return null;
    const initial_byte = data[0];
    const major = initial_byte >> 5;
    const addl = initial_byte & 0x1f;

    var hdr_size: usize = 1;
    var arg: u64 = 0;

    if (addl < 24) {
        arg = addl;
    } else if (addl == 24) {
        if (data.len < 2) return null;
        arg = data[1];
        hdr_size = 2;
    } else if (addl == 25) {
        if (data.len < 3) return null;
        arg = std.mem.readInt(u16, data[1..3], .big);
        hdr_size = 3;
    } else if (addl == 26) {
        if (data.len < 5) return null;
        arg = std.mem.readInt(u32, data[1..5], .big);
        hdr_size = 5;
    } else if (addl == 27) {
        if (data.len < 9) return null;
        arg = std.mem.readInt(u64, data[1..9], .big);
        hdr_size = 9;
    } else {
        return null;
    }

    switch (major) {
        0, 1 => {
            return hdr_size;
        },
        2, 3 => {
            const total = hdr_size + arg;
            if (total > data.len) return null;
            return @intCast(total);
        },
        4 => {
            var pos: usize = hdr_size;
            var i: u64 = 0;
            while (i < arg) : (i += 1) {
                const item_size = skipCborItem(data[pos..]) orelse return null;
                pos += item_size;
            }
            return pos;
        },
        5 => {
            var pos: usize = hdr_size;
            var i: u64 = 0;
            while (i < arg * 2) : (i += 1) {
                const item_size = skipCborItem(data[pos..]) orelse return null;
                pos += item_size;
            }
            return pos;
        },
        6 => {
            const item_size = skipCborItem(data[hdr_size..]) orelse return null;
            return hdr_size + item_size;
        },
        7 => {
            return hdr_size;
        },
        else => return null,
    }
}

/// Extract the raw CBOR bytes of the header from a block payload.
fn extractHeaderBytes(payload: []const u8) ?[]const u8 {
    if (payload.len < 3) return null;

    const outer_byte = payload[0];
    if ((outer_byte >> 5) != 4) return null;
    var pos: usize = 1;
    const outer_addl = outer_byte & 0x1f;
    if (outer_addl == 24) {
        pos = 2;
    } else if (outer_addl < 24) {
        pos = 1;
    } else {
        return null;
    }

    const era_size = skipCborItem(payload[pos..]) orelse return null;
    pos += era_size;

    if (pos >= payload.len) return null;
    const bc_byte = payload[pos];
    if ((bc_byte >> 5) != 4) return null;
    const bc_addl = bc_byte & 0x1f;
    if (bc_addl < 24) {
        pos += 1;
    } else if (bc_addl == 24) {
        pos += 2;
    } else {
        return null;
    }

    const header_start = pos;
    const header_size = skipCborItem(payload[pos..]) orelse return null;
    return payload[header_start .. header_start + header_size];
}

const HeaderInfo = struct {
    block_no: u64,
    slot: u64,
    prev_hash: [32]u8,
    header_hash: [32]u8,
};

fn extractHeaderFromBlock(alloc: std.mem.Allocator, block_term: cbor.Term, payload: []const u8) ?HeaderInfo {
    if (block_term != .array or block_term.array.len < 2) return null;
    const block_content = block_term.array[1];
    if (block_content != .array or block_content.array.len == 0) return null;

    const header_term = block_content.array[0];

    var body: []cbor.Term = undefined;
    var from_tag24 = false;

    if (header_term == .tag and header_term.tag.tag == 24) {
        const inner = header_term.tag.value.*;
        if (inner != .bytes or inner.bytes.len <= 10) return null;

        var fbs = compat.fixedBufferStream(inner.bytes);
        const hdr = cbor.decode(alloc, fbs.reader()) catch return null;

        if (hdr != .array or hdr.array.len == 0) return null;
        if (hdr.array[0] != .array) return null;
        body = hdr.array[0].array;
        from_tag24 = true;
    } else if (header_term == .array and header_term.array.len >= 2) {
        if (header_term.array[0] != .array) return null;
        body = header_term.array[0].array;
    } else {
        return null;
    }

    if (body.len < 3) return null;

    const block_no = if (body[0] == .u64) body[0].u64 else return null;
    const slot = if (body[1] == .u64) body[1].u64 else return null;
    const prev_hash = extractHash32(body[2]) orelse return null;

    var header_hash: [32]u8 = undefined;

    if (from_tag24) {
        const inner_bytes = header_term.tag.value.*.bytes;
        std.crypto.hash.blake2.Blake2b256.hash(inner_bytes, &header_hash, .{});
    } else {
        const raw_header = extractHeaderBytes(payload) orelse {
            return .{
                .block_no = block_no,
                .slot = slot,
                .prev_hash = prev_hash,
                .header_hash = std.mem.zeroes([32]u8),
            };
        };
        std.crypto.hash.blake2.Blake2b256.hash(raw_header, &header_hash, .{});
    }

    return .{
        .block_no = block_no,
        .slot = slot,
        .prev_hash = prev_hash,
        .header_hash = header_hash,
    };
}

const BodyHashResult = enum { ok, missing, mismatch };

fn verifyBodyHash(block_content: cbor.Term, payload: []const u8) BodyHashResult {
    if (block_content != .array or block_content.array.len < 2) return .missing;
    const header_term = block_content.array[0];
    const committed = block_hash.extractBodyHashFromHeader(header_term) orelse return .missing;
    const parts = block_hash.extractBodyParts(payload) orelse return .missing;
    const computed = block_hash.computeBodyHash(parts);
    if (!std.mem.eql(u8, &computed, &committed)) return .mismatch;
    return .ok;
}

fn computeStateDigest(
    blocks: u64,
    applied: u64,
    skipped: u64,
    header_height: u64,
    last_slot: u64,
    last_block_no: u64,
    last_tip_hash: [32]u8,
) [32]u8 {
    const prefix = "TSUNAGI_REPLAY_V1";
    var hasher = std.crypto.hash.blake2.Blake2b256.init(.{});
    hasher.update(prefix);

    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, blocks, .little);
    hasher.update(&buf);
    std.mem.writeInt(u64, &buf, applied, .little);
    hasher.update(&buf);
    std.mem.writeInt(u64, &buf, skipped, .little);
    hasher.update(&buf);
    std.mem.writeInt(u64, &buf, header_height, .little);
    hasher.update(&buf);
    std.mem.writeInt(u64, &buf, last_slot, .little);
    hasher.update(&buf);
    std.mem.writeInt(u64, &buf, last_block_no, .little);
    hasher.update(&buf);
    hasher.update(&last_tip_hash);

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

// ── Per-block timing record ──────────────────────────────────────────

const BlockTiming = struct {
    elapsed_us: u64,
    applied: bool,
    skip_reason: []const u8,
};

// ── Single run result ────────────────────────────────────────────────

const RunResult = struct {
    digest: [32]u8,
    utxo_state_digest: [32]u8,
    cov: Coverage,
    blocks: u64,
    header_height: u64,
    last_slot: u64,
    last_block_no: u64,
    // Perf summary (only meaningful if perf=true)
    perf_count: u64,
    perf_min_us: u64,
    perf_max_us: u64,
    perf_avg_us: u64,
    perf_p50_us: u64,
    perf_p95_us: u64,
    // Per-block timings (only populated if perf=true and blocks <= 5000)
    block_timings: ?[]BlockTiming,
    exit_code: u8,
};

// ── Single replay run (extracted from original run()) ────────────────

fn runSingleReplay(
    alloc: std.mem.Allocator,
    file_path: []const u8,
    lmdb_dir: []const u8,
    max_blocks: usize,
    from_offset: u64,
    strict: bool,
    debug: bool,
    quiet: bool,
    perf: bool,
) RunResult {
    var result = RunResult{
        .digest = std.mem.zeroes([32]u8),
        .utxo_state_digest = std.mem.zeroes([32]u8),
        .cov = Coverage{},
        .blocks = 0,
        .header_height = 0,
        .last_slot = 0,
        .last_block_no = 0,
        .perf_count = 0,
        .perf_min_us = 0,
        .perf_max_us = 0,
        .perf_avg_us = 0,
        .perf_p50_us = 0,
        .perf_p95_us = 0,
        .block_timings = null,
        .exit_code = 0,
    };

    // Open capture file
    var f = compat.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.debug.print("replay-run: cannot open file {s}: {s}\n", .{ file_path, @errorName(err) });
        result.exit_code = 1;
        return result;
    };
    defer f.close();

    // Create LMDB dir
    compat.fs.cwd().makePath(lmdb_dir) catch |err| {
        std.debug.print("replay-run: cannot create LMDB dir {s}: {s}\n", .{ lmdb_dir, @errorName(err) });
        result.exit_code = 1;
        return result;
    };

    // Open LMDB UTxO store
    const lmdb_dir_z = alloc.dupeZ(u8, lmdb_dir) catch {
        std.debug.print("replay-run: alloc failed\n", .{});
        result.exit_code = 1;
        return result;
    };
    defer alloc.free(lmdb_dir_z);

    var store = lmdb_utxo.LmdbUtxo.open(lmdb_dir_z) catch |err| {
        std.debug.print("replay-run: LMDB open failed: {s}\n", .{@errorName(err)});
        result.exit_code = 1;
        return result;
    };
    defer store.close();

    var hs = header_store_mod.HeaderStore.open(store.env) catch |err| {
        std.debug.print("replay-run: header store open failed: {s}\n", .{@errorName(err)});
        result.exit_code = 1;
        return result;
    };

    var header_height: u64 = 0;
    var header_head: ?[32]u8 = null;
    {
        if (hs.beginRead()) |rtxn0| {
            var rtxn = rtxn0;
            defer hs.abort(&rtxn);
            header_head = hs.getHead(&rtxn);
            header_height = hs.getHeight(&rtxn);
        }
    }

    if (from_offset > 0) {
        f.seekTo(from_offset) catch |err| {
            std.debug.print("replay-run: seek to offset {d} failed: {s}\n", .{ from_offset, @errorName(err) });
            result.exit_code = 1;
            return result;
        };
    }

    if (!quiet) {
        std.debug.print("replay-run: file={s} lmdb={s} max_blocks={d} from_offset={d} strict={}\n", .{
            file_path, lmdb_dir, max_blocks, from_offset, strict,
        });
    }

    var reader = f.reader();

    var blocks: u64 = 0;
    var cov = Coverage{};
    var last_slot: u64 = 0;
    var last_block_no: u64 = 0;
    var last_tip_hash: [32]u8 = std.mem.zeroes([32]u8);

    // Per-block timing collection
    const collect_timings = perf and (max_blocks > 0 and max_blocks <= 5000);
    var timings_list = std.array_list.Managed(BlockTiming).init(alloc);
    defer if (!collect_timings) timings_list.deinit();
    // Perf aggregates
    var perf_sum_us: u64 = 0;
    var perf_min_us: u64 = std.math.maxInt(u64);
    var perf_max_us: u64 = 0;
    var perf_count: u64 = 0;

    while (true) {
        if (max_blocks > 0 and blocks >= max_blocks) break;

        const block_start = if (perf) compat.nanoTimestamp() else 0;

        var len_buf: [4]u8 = undefined;
        const n = f.readAll(&len_buf) catch break;
        if (n == 0) break;
        if (n != 4) {
            if (debug) std.debug.print("replay-run: truncated record header at block {d}\n", .{blocks});
            cov.errors_total += 1;
            break;
        }

        const len = std.mem.readInt(u32, &len_buf, .little);
        if (len == 0) continue;

        if (len > RECORD_MAX_LEN) {
            if (debug) std.debug.print("replay-run: record too large ({d} bytes) at block {d}\n", .{ len, blocks });
            cov.errors_total += 1;
            if (strict) {
                result.exit_code = 2;
                break;
            }
            break;
        }

        const payload = alloc.alloc(u8, len) catch {
            std.debug.print("replay-run: alloc failed for {d} byte record\n", .{len});
            result.exit_code = 1;
            break;
        };
        defer alloc.free(payload);

        reader.readNoEof(payload) catch {
            if (debug) std.debug.print("replay-run: truncated payload at block {d}\n", .{blocks});
            cov.errors_total += 1;
            break;
        };

        blocks += 1;

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var fbs = compat.fixedBufferStream(payload);
        const block_term = cbor.decode(arena_alloc, fbs.reader()) catch {
            if (debug) std.debug.print("replay-run: CBOR decode failed at block {d}\n", .{blocks});
            cov.skipped_decode_error += 1;
            if (strict) {
                result.exit_code = 2;
                break;
            }
            if (perf) recordBlockTiming(&timings_list, block_start, false, "decode_error", collect_timings, &perf_sum_us, &perf_min_us, &perf_max_us, &perf_count);
            continue;
        };

        if (block_term != .array or block_term.array.len < 2) {
            if (debug) std.debug.print("replay-run: invalid block shape at block {d}\n", .{blocks});
            cov.skipped_decode_error += 1;
            if (strict) {
                result.exit_code = 2;
                break;
            }
            if (perf) recordBlockTiming(&timings_list, block_start, false, "decode_error", collect_timings, &perf_sum_us, &perf_min_us, &perf_max_us, &perf_count);
            continue;
        }

        const hdr_info = extractHeaderFromBlock(arena_alloc, block_term, payload);
        if (hdr_info) |info| {
            last_slot = info.slot;
            last_block_no = info.block_no;
            last_tip_hash = info.header_hash;

            const zero_hash = std.mem.zeroes([32]u8);
            const hash_valid = !std.mem.eql(u8, info.header_hash[0..], zero_hash[0..]);

            if (hash_valid) {
                var linkage_ok = true;
                if (header_head) |head| {
                    if (!std.mem.eql(u8, info.prev_hash[0..], head[0..])) {
                        linkage_ok = false;
                    }
                }

                if (!linkage_ok and strict) {
                    if (debug) std.debug.print("replay-run: header chain linkage error at block {d} slot={d}\n", .{ blocks, info.slot });
                }

                const new_height = header_height + 1;
                if (hs.beginWrite()) |wtxn0| {
                    var wtxn = wtxn0;
                    hs.putHeader(&wtxn, info.header_hash, info.slot, info.block_no, new_height, info.prev_hash);
                    hs.setHead(&wtxn, info.header_hash);
                    hs.setHeight(&wtxn, new_height);
                    if (hs.commit(&wtxn)) {
                        header_head = info.header_hash;
                        header_height = new_height;
                    }
                }
            }
        }

        const block_content = block_term.array[1];
        const bh_result = verifyBodyHash(block_content, payload);
        switch (bh_result) {
            .ok => {},
            .missing => {
                if (debug) std.debug.print("replay-run: body hash missing at block {d}\n", .{blocks});
                cov.skipped_bodyhash_missing += 1;
                if (strict) {
                    result.exit_code = 2;
                    break;
                }
                if (perf) recordBlockTiming(&timings_list, block_start, false, "bodyhash_missing", collect_timings, &perf_sum_us, &perf_min_us, &perf_max_us, &perf_count);
                continue;
            },
            .mismatch => {
                if (debug) std.debug.print("replay-run: body hash mismatch at block {d}\n", .{blocks});
                cov.skipped_bodyhash_mismatch += 1;
                if (strict) {
                    result.exit_code = 2;
                    break;
                }
                if (perf) recordBlockTiming(&timings_list, block_start, false, "bodyhash_mismatch", collect_timings, &perf_sum_us, &perf_min_us, &perf_max_us, &perf_count);
                continue;
            },
        }

        const scan = tx_decode.extractTxListFromTermPublic(arena_alloc, block_content);

        if (scan == null or scan.?.tx_list.len == 0) {
            cov.applied_ok += 1;
            if (perf) recordBlockTiming(&timings_list, block_start, true, "", collect_timings, &perf_sum_us, &perf_min_us, &perf_max_us, &perf_count);

            if (!quiet and debug and blocks % PROGRESS_INTERVAL == 0) {
                std.debug.print("replay: blocks={d} applied={d} skipped={d}\n", .{ blocks, cov.applied_ok, cov.skippedTotal() });
            }
            continue;
        }

        const tx_list = scan.?.tx_list;
        const deltas = tx_decode.extractTxDeltas(alloc, tx_list, null, false) catch {
            if (debug) std.debug.print("replay-run: delta extraction failed at block {d}\n", .{blocks});
            cov.skipped_decode_error += 1;
            if (strict) {
                result.exit_code = 2;
                break;
            }
            if (perf) recordBlockTiming(&timings_list, block_start, false, "decode_error", collect_timings, &perf_sum_us, &perf_min_us, &perf_max_us, &perf_count);
            continue;
        };
        defer tx_decode.freeTxDeltas(alloc, deltas);

        var block_skipped = false;

        if (deltas.consumed.len > 0) {
            if (store.beginRead()) |rtxn0| {
                var rtxn = rtxn0;
                defer store.abort(&rtxn);

                for (deltas.consumed) |con| {
                    const existing = store.getTxn(&rtxn, con.tx_hash, con.index);
                    if (existing == null) {
                        if (strict) {
                            std.debug.print("replay-run: STRICT missing consumed input at block {d} slot={d}\n", .{ blocks, last_slot });
                            result.exit_code = 2;
                            // Return early — strict mode failure
                            result.cov = cov;
                            result.blocks = blocks;
                            result.header_height = header_height;
                            result.last_slot = last_slot;
                            result.last_block_no = last_block_no;
                            result.digest = computeStateDigest(blocks, cov.applied_ok, cov.skippedTotal(), header_height, last_slot, last_block_no, last_tip_hash);
                            result.utxo_state_digest = store.computeStateDigest() orelse std.mem.zeroes([32]u8);
                            return result;
                        }
                        block_skipped = true;
                        break;
                    }
                }
            }
        }

        if (block_skipped) {
            cov.skipped_missing_inputs += 1;
            if (perf) recordBlockTiming(&timings_list, block_start, false, "missing_inputs", collect_timings, &perf_sum_us, &perf_min_us, &perf_max_us, &perf_count);
        } else {
            const txn0 = store.beginWrite() orelse {
                cov.errors_total += 1;
                if (strict) {
                    result.exit_code = 2;
                    break;
                }
                if (perf) recordBlockTiming(&timings_list, block_start, false, "write_error", collect_timings, &perf_sum_us, &perf_min_us, &perf_max_us, &perf_count);
                continue;
            };
            var txn = txn0;

            for (deltas.consumed) |con| {
                store.delTxn(&txn, con.tx_hash, con.index);
            }
            for (deltas.produced) |p| {
                store.putTxn(alloc, &txn, p.input.tx_hash, p.input.index, p.output);
            }

            if (store.commit(&txn)) {
                cov.applied_ok += 1;
                if (perf) recordBlockTiming(&timings_list, block_start, true, "", collect_timings, &perf_sum_us, &perf_min_us, &perf_max_us, &perf_count);
            } else {
                cov.errors_total += 1;
                if (perf) recordBlockTiming(&timings_list, block_start, false, "commit_error", collect_timings, &perf_sum_us, &perf_min_us, &perf_max_us, &perf_count);
                if (strict) {
                    result.exit_code = 2;
                    break;
                }
            }
        }

        if (!quiet and debug and blocks % PROGRESS_INTERVAL == 0) {
            std.debug.print("replay: blocks={d} applied={d} skipped={d}\n", .{ blocks, cov.applied_ok, cov.skippedTotal() });
        }
    }

    const digest = computeStateDigest(blocks, cov.applied_ok, cov.skippedTotal(), header_height, last_slot, last_block_no, last_tip_hash);

    // Compute canonical UTxO state digest from LMDB
    const utxo_digest = store.computeStateDigest() orelse std.mem.zeroes([32]u8);

    // Compute perf summary
    if (perf and perf_count > 0) {
        result.perf_count = perf_count;
        result.perf_min_us = perf_min_us;
        result.perf_max_us = perf_max_us;
        result.perf_avg_us = perf_sum_us / perf_count;

        // p50/p95: sort a copy of timing values
        if (collect_timings and timings_list.items.len > 0) {
            const times = alloc.alloc(u64, timings_list.items.len) catch {
                result.perf_p50_us = 0;
                result.perf_p95_us = 0;
                result.cov = cov;
                result.blocks = blocks;
                result.header_height = header_height;
                result.last_slot = last_slot;
                result.last_block_no = last_block_no;
                result.digest = digest;
                result.utxo_state_digest = utxo_digest;
                result.block_timings = timings_list.toOwnedSlice() catch null;
                return result;
            };
            defer alloc.free(times);
            for (timings_list.items, 0..) |t, i| {
                times[i] = t.elapsed_us;
            }
            std.mem.sort(u64, times, {}, std.sort.asc(u64));
            result.perf_p50_us = times[times.len / 2];
            const p95_idx = (times.len * 95) / 100;
            result.perf_p95_us = times[@min(p95_idx, times.len - 1)];
        }
    }

    result.cov = cov;
    result.blocks = blocks;
    result.header_height = header_height;
    result.last_slot = last_slot;
    result.last_block_no = last_block_no;
    result.digest = digest;
    result.utxo_state_digest = utxo_digest;
    if (collect_timings) {
        result.block_timings = timings_list.toOwnedSlice() catch null;
    }
    return result;
}

fn recordBlockTiming(
    list: *std.array_list.Managed(BlockTiming),
    block_start: i128,
    applied: bool,
    skip_reason: []const u8,
    collect: bool,
    sum_us: *u64,
    min_us: *u64,
    max_us: *u64,
    count: *u64,
) void {
    const end = compat.nanoTimestamp();
    const elapsed_ns: u64 = @intCast(@max(end - block_start, 0));
    const elapsed_us = elapsed_ns / 1000;
    sum_us.* += elapsed_us;
    if (elapsed_us < min_us.*) min_us.* = elapsed_us;
    if (elapsed_us > max_us.*) max_us.* = elapsed_us;
    count.* += 1;
    if (collect) {
        list.append(.{ .elapsed_us = elapsed_us, .applied = applied, .skip_reason = skip_reason }) catch {};
    }
}

// ── Delete directory recursively ─────────────────────────────────────

fn deleteDir(path: []const u8) void {
    compat.fs.cwd().deleteTree(path) catch {};
}

// ── Get version via git describe ─────────────────────────────────────

fn getVersionBuf(buf: []u8) []const u8 {
    const alloc = std.heap.page_allocator;
    var child = compat.Child.init(
        &[_][]const u8{ "/bin/sh", "-c", "cd ~/src/tsunagi-follower && git describe --tags --always 2>/dev/null" },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch return "unknown";
    const stdout = child.stdout orelse return "unknown";
    const n = stdout.read(buf) catch return "unknown";
    _ = child.wait() catch {};
    if (n == 0) return "unknown";
    var end = n;
    while (end > 0 and (buf[end - 1] == '\n' or buf[end - 1] == '\r')) end -= 1;
    if (end > 0) return buf[0..end];
    return "unknown";
}

// ── Baseline / Regression ────────────────────────────────────────────

const BaselineData = struct {
    avg_us: u64,
    p95_us: u64,
    applied_ok: u64,
    determinism_digest: [64]u8,
    digest_len: usize,
    state_digest_hex: [64]u8,
    state_digest_len: usize,
};

const RegressionResult = enum {
    PASS,
    WARN,
    FAIL,

    pub fn label(self: RegressionResult) []const u8 {
        return switch (self) {
            .PASS => "PASS",
            .WARN => "WARN",
            .FAIL => "FAIL",
        };
    }
};

const RegressionInfo = struct {
    baseline_file: []const u8,
    threshold_pct: u64,
    avg_delta_pct_x10: i64,
    p95_delta_pct_x10: i64,
    determinism_match: bool,
    state_digest_match: bool,
    applied_match: bool,
    result: RegressionResult,
};

fn extractJsonU64(data: []const u8, key: []const u8) ?u64 {
    var pos: usize = 0;
    while (pos + key.len + 3 < data.len) : (pos += 1) {
        if (data[pos] != '"') continue;
        if (pos + 1 + key.len >= data.len) continue;
        if (!std.mem.eql(u8, data[pos + 1 .. pos + 1 + key.len], key)) continue;
        if (data[pos + 1 + key.len] != '"') continue;

        var p = pos + 2 + key.len;
        while (p < data.len and data[p] != ':') : (p += 1) {}
        if (p >= data.len) return null;
        p += 1;
        while (p < data.len and (data[p] == ' ' or data[p] == '\n' or data[p] == '\r' or data[p] == '\t')) : (p += 1) {}
        if (p >= data.len) return null;
        var end = p;
        while (end < data.len and data[end] >= '0' and data[end] <= '9') : (end += 1) {}
        if (end == p) return null;
        return std.fmt.parseUnsigned(u64, data[p..end], 10) catch null;
    }
    return null;
}

fn extractJsonStr(data: []const u8, key: []const u8, buf: []u8) usize {
    var pos: usize = 0;
    while (pos + key.len + 3 < data.len) : (pos += 1) {
        if (data[pos] != '"') continue;
        if (pos + 1 + key.len >= data.len) continue;
        if (!std.mem.eql(u8, data[pos + 1 .. pos + 1 + key.len], key)) continue;
        if (data[pos + 1 + key.len] != '"') continue;

        var p = pos + 2 + key.len;
        while (p < data.len and data[p] != ':') : (p += 1) {}
        if (p >= data.len) return 0;
        p += 1;
        while (p < data.len and (data[p] == ' ' or data[p] == '\n' or data[p] == '\r' or data[p] == '\t')) : (p += 1) {}
        if (p >= data.len or data[p] != '"') return 0;
        p += 1;
        var end = p;
        while (end < data.len and data[end] != '"') : (end += 1) {}
        if (end >= data.len) return 0;
        const len = end - p;
        if (len > buf.len) return 0;
        @memcpy(buf[0..len], data[p..end]);
        return len;
    }
    return 0;
}

fn loadBaseline(alloc: std.mem.Allocator, path: []const u8) ?BaselineData {
    var f = compat.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("REGRESSION: cannot open baseline {s}: {s}\n", .{ path, @errorName(err) });
        return null;
    };
    defer f.close();

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const reader = f.reader();
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = reader.read(&tmp) catch break;
        if (n == 0) break;
        buf.appendSlice(tmp[0..n]) catch break;
        if (buf.items.len > 2 * 1024 * 1024) break;
    }
    if (buf.items.len == 0) {
        std.debug.print("REGRESSION: empty baseline file\n", .{});
        return null;
    }
    const content = buf.items;

    var result = BaselineData{
        .avg_us = 0,
        .p95_us = 0,
        .applied_ok = 0,
        .determinism_digest = std.mem.zeroes([64]u8),
        .digest_len = 0,
        .state_digest_hex = std.mem.zeroes([64]u8),
        .state_digest_len = 0,
    };

    result.avg_us = extractJsonU64(content, "avg_us") orelse 0;
    result.p95_us = extractJsonU64(content, "p95_us") orelse 0;
    result.applied_ok = extractJsonU64(content, "applied_ok") orelse 0;
    result.digest_len = extractJsonStr(content, "determinism_digest", &result.determinism_digest);
    result.state_digest_len = extractJsonStr(content, "state_digest_hex", &result.state_digest_hex);

    return result;
}

fn computeDeltaPctX10(baseline_val: u64, current_val: u64) i64 {
    if (baseline_val == 0) return 0;
    const diff: i64 = @as(i64, @intCast(current_val)) - @as(i64, @intCast(baseline_val));
    return @divTrunc(diff * 1000, @as(i64, @intCast(baseline_val)));
}

fn computeRegression(
    baseline: BaselineData,
    current_avg_us: u64,
    current_p95_us: u64,
    current_applied_ok: u64,
    current_digest_hex: [64]u8,
    current_state_digest_hex: [64]u8,
    baseline_file: []const u8,
    threshold_pct: u64,
) RegressionInfo {
    const avg_delta = computeDeltaPctX10(baseline.avg_us, current_avg_us);
    const p95_delta = computeDeltaPctX10(baseline.p95_us, current_p95_us);

    const det_match = baseline.digest_len == 64 and
        std.mem.eql(u8, &baseline.determinism_digest, &current_digest_hex);

    const sd_match = baseline.state_digest_len == 0 or
        (baseline.state_digest_len == 64 and std.mem.eql(u8, &baseline.state_digest_hex, &current_state_digest_hex));

    const applied_match = baseline.applied_ok == current_applied_ok;

    var result_val = RegressionResult.PASS;
    if (!det_match and baseline.digest_len > 0) result_val = .FAIL;
    if (!sd_match) result_val = .FAIL;
    if (!applied_match) result_val = .FAIL;

    const threshold_x10: i64 = @intCast(threshold_pct * 10);
    if (result_val != .FAIL) {
        if (avg_delta > threshold_x10 or p95_delta > threshold_x10) {
            result_val = .WARN;
        }
    }

    return .{
        .baseline_file = baseline_file,
        .threshold_pct = threshold_pct,
        .avg_delta_pct_x10 = avg_delta,
        .p95_delta_pct_x10 = p95_delta,
        .determinism_match = det_match,
        .state_digest_match = sd_match,
        .applied_match = applied_match,
        .result = result_val,
    };
}

fn printRegressionReport(baseline: BaselineData, current_avg_us: u64, current_p95_us: u64, reg: RegressionInfo) void {
    std.debug.print("\nREPLAY REGRESSION:\n", .{});

    const abs_avg: u64 = if (reg.avg_delta_pct_x10 < 0) @intCast(-reg.avg_delta_pct_x10) else @intCast(reg.avg_delta_pct_x10);
    const avg_sign: []const u8 = if (reg.avg_delta_pct_x10 >= 0) "+" else "-";
    const avg_verdict: []const u8 = if (reg.avg_delta_pct_x10 > @as(i64, @intCast(reg.threshold_pct * 10))) "WARN" else "OK";
    std.debug.print("  avg_us: {d} -> {d} ({s}{d}.{d}%) {s}\n", .{
        baseline.avg_us, current_avg_us, avg_sign, abs_avg / 10, abs_avg % 10, avg_verdict,
    });

    const abs_p95: u64 = if (reg.p95_delta_pct_x10 < 0) @intCast(-reg.p95_delta_pct_x10) else @intCast(reg.p95_delta_pct_x10);
    const p95_sign: []const u8 = if (reg.p95_delta_pct_x10 >= 0) "+" else "-";
    const p95_verdict: []const u8 = if (reg.p95_delta_pct_x10 > @as(i64, @intCast(reg.threshold_pct * 10))) "WARN" else "OK";
    std.debug.print("  p95_us: {d} -> {d} ({s}{d}.{d}%) {s}\n", .{
        baseline.p95_us, current_p95_us, p95_sign, abs_p95 / 10, abs_p95 % 10, p95_verdict,
    });

    const det_label: []const u8 = if (reg.determinism_match) "OK" else "FAIL";
    std.debug.print("  determinism: {s}\n", .{det_label});

    const sd_label: []const u8 = if (reg.state_digest_match) "OK" else "FAIL";
    std.debug.print("  state_digest: {s}\n", .{sd_label});

    std.debug.print("  RESULT: {s}\n", .{reg.result.label()});
}

fn printTrendSummary(baseline: BaselineData, current_avg_us: u64, current_p95_us: u64, current_applied_ok: u64) void {
    const avg_delta = computeDeltaPctX10(baseline.avg_us, current_avg_us);
    const p95_delta = computeDeltaPctX10(baseline.p95_us, current_p95_us);
    const cov_diff: i64 = @as(i64, @intCast(current_applied_ok)) - @as(i64, @intCast(baseline.applied_ok));

    const abs_avg: u64 = if (avg_delta < 0) @intCast(-avg_delta) else @intCast(avg_delta);
    const avg_sign: []const u8 = if (avg_delta >= 0) "+" else "-";
    const abs_p95: u64 = if (p95_delta < 0) @intCast(-p95_delta) else @intCast(p95_delta);
    const p95_sign: []const u8 = if (p95_delta >= 0) "+" else "-";
    const abs_cov: u64 = if (cov_diff < 0) @intCast(-cov_diff) else @intCast(cov_diff);
    const cov_sign: []const u8 = if (cov_diff >= 0) "+" else "-";

    std.debug.print("\nTREND:\n", .{});
    std.debug.print("  avg_us: {s}{d}.{d}%\n", .{ avg_sign, abs_avg / 10, abs_avg % 10 });
    std.debug.print("  p95_us: {s}{d}.{d}%\n", .{ p95_sign, abs_p95 / 10, abs_p95 % 10 });
    std.debug.print("  coverage: {s}{d}\n", .{ cov_sign, abs_cov });
}

// ── Main entry point ─────────────────────────────────────────────────

pub fn run(
    alloc: std.mem.Allocator,
    file_path: []const u8,
    lmdb_dir: []const u8,
    max_blocks: usize,
    from_offset: u64,
    strict: bool,
    debug: bool,
    report_dir: ?[]const u8,
    report_prefix: ?[]const u8,
    repeat: usize,
    fresh: bool,
    perf: bool,
    quiet: bool,
    baseline_json: ?[]const u8,
    regress_threshold: u64,
    trend: bool,
) u8 {
    // Benchmark mode: when report_dir is provided
    const bench_dir = report_dir orelse {
        // Legacy single-run mode (no benchmark features)
        const r = runSingleReplay(alloc, file_path, lmdb_dir, max_blocks, from_offset, strict, debug, false, false);
        r.cov.printSummary(r.blocks);
        std.debug.print("\nREPLAY DONE blocks={d} applied={d} skipped={d} errors={d}\n", .{ r.blocks, r.cov.applied_ok, r.cov.skippedTotal(), r.cov.errors_total });
        std.debug.print("header_height={d} last_slot={d} last_block={d}\n", .{ r.header_height, r.last_slot, r.last_block_no });
        std.debug.print("state_digest={x}\n", .{&r.digest});

        // Write legacy reports
        const effective_dir: []const u8 = std.fs.path.dirname(file_path) orelse ".";
        const prefix = report_prefix orelse "replay";
        writeLegacyReports(alloc, effective_dir, prefix, file_path, lmdb_dir, max_blocks, from_offset, strict, &r);
        return r.exit_code;
    };

    const effective_repeat = if (repeat == 0) @as(usize, 1) else repeat;

    // Create report dir
    compat.fs.cwd().makePath(bench_dir) catch |err| {
        std.debug.print("replay-bench: cannot create report dir {s}: {s}\n", .{ bench_dir, @errorName(err) });
        return 1;
    };

    std.debug.print("REPLAY BENCH: runs={d} fresh={} perf={} max_blocks={d}\n", .{ effective_repeat, fresh, perf, max_blocks });

    // Allocate run results
    const results = alloc.alloc(RunResult, effective_repeat) catch {
        std.debug.print("replay-bench: alloc failed\n", .{});
        return 1;
    };
    defer alloc.free(results);

    // Run N replays
    for (0..effective_repeat) |i| {
        const run_num = i + 1;
        // Build per-run LMDB dir
        const run_lmdb = std.fmt.allocPrint(alloc, "{s}/run-{d:0>3}", .{ lmdb_dir, run_num }) catch {
            std.debug.print("replay-bench: alloc failed\n", .{});
            return 1;
        };
        defer alloc.free(run_lmdb);

        if (fresh) {
            deleteDir(run_lmdb);
        }

        std.debug.print("\n== RUN {d}/{d} lmdb={s} ==\n", .{ run_num, effective_repeat, run_lmdb });

        results[i] = runSingleReplay(alloc, file_path, run_lmdb, max_blocks, from_offset, strict, debug, quiet, perf);

        if (!quiet) {
            results[i].cov.printSummary(results[i].blocks);
        }

        std.debug.print("RUN {d}: digest={x} applied={d} skipped={d} errors={d}\n", .{
            run_num,
            &results[i].digest,
            results[i].cov.applied_ok,
            results[i].cov.skippedTotal(),
            results[i].cov.errors_total,
        });

        if (results[i].exit_code != 0 and strict) {
            std.debug.print("REPLAY BENCH: run {d} failed with exit_code={d}, aborting\n", .{ run_num, results[i].exit_code });
            return results[i].exit_code;
        }
    }

    // Determinism check
    var determinism_ok = true;
    const ref_digest = results[0].digest;
    const ref_utxo_digest = results[0].utxo_state_digest;
    const ref_errors = results[0].cov.errors_total;
    const ref_height = results[0].header_height;
    for (1..effective_repeat) |i| {
        if (!std.mem.eql(u8, &results[i].digest, &ref_digest)) determinism_ok = false;
        if (!std.mem.eql(u8, &results[i].utxo_state_digest, &ref_utxo_digest)) determinism_ok = false;
        if (results[i].cov.errors_total != ref_errors) determinism_ok = false;
        if (results[i].header_height != ref_height) determinism_ok = false;
    }

    const det_label: []const u8 = if (determinism_ok) "OK" else "FAIL";
    std.debug.print("\nREPLAY BENCH: determinism={s} digest={x} state_digest={x} runs={d}\n", .{
        det_label,
        &ref_digest,
        &ref_utxo_digest,
        effective_repeat,
    });

    // Aggregate perf across runs
    var agg_avg_us: u64 = 0;
    var agg_p95_us: u64 = 0;
    if (perf and effective_repeat > 0) {
        var sum_avg: u64 = 0;
        var sum_p95: u64 = 0;
        for (results[0..effective_repeat]) |r| {
            sum_avg += r.perf_avg_us;
            sum_p95 += r.perf_p95_us;
        }
        agg_avg_us = sum_avg / effective_repeat;
        agg_p95_us = sum_p95 / effective_repeat;
    }

    // Regression check
    var regression: ?RegressionInfo = null;
    if (baseline_json) |bpath| {
        if (loadBaseline(alloc, bpath)) |baseline| {
            const digest_hex = fmtDigest(&ref_digest);
            const state_digest_hex = fmtDigest(&ref_utxo_digest);
            regression = computeRegression(
                baseline,
                agg_avg_us,
                agg_p95_us,
                results[0].cov.applied_ok,
                digest_hex,
                state_digest_hex,
                bpath,
                regress_threshold,
            );
            printRegressionReport(baseline, agg_avg_us, agg_p95_us, regression.?);
            if (trend) {
                printTrendSummary(baseline, agg_avg_us, agg_p95_us, results[0].cov.applied_ok);
            }
        }
    }

    // Write benchmark reports
    writeBenchReportJson(alloc, bench_dir, file_path, max_blocks, from_offset, strict, results, effective_repeat, determinism_ok, perf, agg_avg_us, agg_p95_us, regression);
    writeBenchReportCsv(alloc, bench_dir, results, effective_repeat, perf);
    if (perf and max_blocks > 0 and max_blocks <= 5000) {
        writeBenchPerBlockCsv(alloc, bench_dir, results, effective_repeat);
    }

    std.debug.print("REPLAY BENCH: reports written to {s}\n", .{bench_dir});

    // Free block_timings
    for (results) |r| {
        if (r.block_timings) |bt| {
            alloc.free(bt);
        }
    }

    if (results[0].exit_code != 0 and strict) return results[0].exit_code;
    return 0;
}

// ── Hex format helper ────────────────────────────────────────────────

fn fmtDigest(digest: *const [32]u8) [64]u8 {
    const hex = "0123456789abcdef";
    var buf: [64]u8 = undefined;
    for (0..32) |i| {
        buf[i * 2] = hex[digest[i] >> 4];
        buf[i * 2 + 1] = hex[digest[i] & 0xf];
    }
    return buf;
}

// ── Benchmark report writers ─────────────────────────────────────────

fn writeBenchReportJson(
    alloc: std.mem.Allocator,
    dir: []const u8,
    file_path: []const u8,
    max_blocks: usize,
    from_offset: u64,
    strict: bool,
    results: []const RunResult,
    num_runs: usize,
    determinism_ok: bool,
    perf: bool,
    agg_avg_us: u64,
    agg_p95_us: u64,
    regression: ?RegressionInfo,
) void {
    const path = std.fmt.allocPrint(alloc, "{s}/report.json", .{dir}) catch return;
    defer alloc.free(path);

    var f = compat.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer f.close();
    const w = f.writer();
    const now: u64 = @intCast(compat.timestamp());
    const strict_str: []const u8 = if (strict) "true" else "false";
    const det_str: []const u8 = if (determinism_ok) "true" else "false";

    var version_buf: [64]u8 = undefined;
    const version = getVersionBuf(&version_buf);

    w.print("{{\n", .{}) catch return;
    w.print("  \"version\": \"{s}\",\n", .{version}) catch return;
    w.print("  \"unix\": {d},\n", .{now}) catch return;
    w.print("  \"input\": {{\n", .{}) catch return;
    w.print("    \"file\": \"{s}\",\n", .{file_path}) catch return;
    w.print("    \"max_blocks\": {d},\n", .{max_blocks}) catch return;
    w.print("    \"from_offset\": {d},\n", .{from_offset}) catch return;
    w.print("    \"strict\": {s}\n", .{strict_str}) catch return;
    w.print("  }},\n", .{}) catch return;
    w.print("  \"avg_us\": {d},\n", .{agg_avg_us}) catch return;
    w.print("  \"p95_us\": {d},\n", .{agg_p95_us}) catch return;
    w.print("  \"applied_ok\": {d},\n", .{results[0].cov.applied_ok}) catch return;
    w.print("  \"runs\": [\n", .{}) catch return;

    for (0..num_runs) |i| {
        const digest_hex = fmtDigest(&results[i].digest);
        const top = results[i].cov.topSkipReason();

        if (i > 0) w.print(",\n", .{}) catch {};
        w.print("    {{\n", .{}) catch continue;
        w.print("      \"run\": {d},\n", .{i + 1}) catch continue;
        w.print("      \"digest\": \"{s}\",\n", .{digest_hex}) catch continue;
        w.print("      \"applied_ok\": {d},\n", .{results[i].cov.applied_ok}) catch continue;
        w.print("      \"skipped_total\": {d},\n", .{results[i].cov.skippedTotal()}) catch continue;
        w.print("      \"errors_total\": {d},\n", .{results[i].cov.errors_total}) catch continue;
        w.print("      \"top_skip_reason\": \"{s}\",\n", .{top.name}) catch continue;
        w.print("      \"header_height\": {d},\n", .{results[i].header_height}) catch continue;
        w.print("      \"last_slot\": {d},\n", .{results[i].last_slot}) catch continue;
        w.print("      \"last_block\": {d}", .{results[i].last_block_no}) catch continue;
        if (perf) {
            w.print(",\n", .{}) catch continue;
            w.print("      \"perf\": {{\n", .{}) catch continue;
            w.print("        \"count\": {d},\n", .{results[i].perf_count}) catch continue;
            w.print("        \"min_us\": {d},\n", .{results[i].perf_min_us}) catch continue;
            w.print("        \"max_us\": {d},\n", .{results[i].perf_max_us}) catch continue;
            w.print("        \"avg_us\": {d},\n", .{results[i].perf_avg_us}) catch continue;
            w.print("        \"p50_us\": {d},\n", .{results[i].perf_p50_us}) catch continue;
            w.print("        \"p95_us\": {d}\n", .{results[i].perf_p95_us}) catch continue;
            w.print("      }}\n", .{}) catch continue;
        } else {
            w.print("\n", .{}) catch continue;
        }
        w.print("    }}", .{}) catch {};
    }

    w.print("\n  ],\n", .{}) catch return;
    w.print("  \"determinism_ok\": {s},\n", .{det_str}) catch return;
    if (determinism_ok) {
        const d_hex = fmtDigest(&results[0].digest);
        w.print("  \"determinism_digest\": \"{s}\",\n", .{d_hex}) catch return;
    } else {
        w.print("  \"determinism_digest\": \"\",\n", .{}) catch return;
    }
    {
        const sd_hex = fmtDigest(&results[0].utxo_state_digest);
        w.print("  \"state_digest_hex\": \"{s}\",\n", .{sd_hex}) catch return;
    }
    if (regression) |reg| {
        w.print("  \"regression\": {{\n", .{}) catch return;
        w.print("    \"baseline_file\": \"{s}\",\n", .{reg.baseline_file}) catch return;
        w.print("    \"threshold_pct\": {d},\n", .{reg.threshold_pct}) catch return;
        const r_abs_avg: u64 = if (reg.avg_delta_pct_x10 < 0) @intCast(-reg.avg_delta_pct_x10) else @intCast(reg.avg_delta_pct_x10);
        const r_avg_sign: []const u8 = if (reg.avg_delta_pct_x10 >= 0) "" else "-";
        w.print("    \"avg_delta_pct\": {s}{d}.{d},\n", .{ r_avg_sign, r_abs_avg / 10, r_abs_avg % 10 }) catch return;
        const r_abs_p95: u64 = if (reg.p95_delta_pct_x10 < 0) @intCast(-reg.p95_delta_pct_x10) else @intCast(reg.p95_delta_pct_x10);
        const r_p95_sign: []const u8 = if (reg.p95_delta_pct_x10 >= 0) "" else "-";
        w.print("    \"p95_delta_pct\": {s}{d}.{d},\n", .{ r_p95_sign, r_abs_p95 / 10, r_abs_p95 % 10 }) catch return;
        const r_det_str: []const u8 = if (reg.determinism_match) "true" else "false";
        w.print("    \"determinism_match\": {s},\n", .{r_det_str}) catch return;
        const r_sd_str: []const u8 = if (reg.state_digest_match) "true" else "false";
        w.print("    \"state_digest_match\": {s},\n", .{r_sd_str}) catch return;
        w.print("    \"result\": \"{s}\"\n", .{reg.result.label()}) catch return;
        w.print("  }},\n", .{}) catch return;
    } else {
        w.print("  \"regression\": null,\n", .{}) catch return;
    }
    var notes_buf: [256]u8 = undefined;
    var notes_len: usize = 0;
    if (!perf) {
        const note = "perf disabled (no --perf flag)";
        @memcpy(notes_buf[notes_len .. notes_len + note.len], note);
        notes_len += note.len;
    }
    if (notes_len > 0) {
        w.print("  \"notes\": [\"{s}\"]\n", .{notes_buf[0..notes_len]}) catch return;
    } else {
        w.print("  \"notes\": []\n", .{}) catch return;
    }
    w.print("}}\n", .{}) catch return;
}

fn writeBenchReportCsv(
    alloc: std.mem.Allocator,
    dir: []const u8,
    results: []const RunResult,
    num_runs: usize,
    perf: bool,
) void {
    const path = std.fmt.allocPrint(alloc, "{s}/report.csv", .{dir}) catch return;
    defer alloc.free(path);

    var f = compat.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer f.close();
    const w = f.writer();

    w.print("run,digest,applied_ok,skipped_total,errors_total,header_height,last_slot,last_block,min_us,max_us,avg_us,p50_us,p95_us\n", .{}) catch return;

    for (0..num_runs) |i| {
        const digest_hex = fmtDigest(&results[i].digest);
        if (perf) {
            w.print("{d},{s},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d}\n", .{
                i + 1,         digest_hex,      results[i].cov.applied_ok,
                results[i].cov.skippedTotal(), results[i].cov.errors_total, results[i].header_height,
                results[i].last_slot,   results[i].last_block_no, results[i].perf_min_us,
                results[i].perf_max_us, results[i].perf_avg_us,   results[i].perf_p50_us,
                results[i].perf_p95_us,
            }) catch continue;
        } else {
            w.print("{d},{s},{d},{d},{d},{d},{d},{d},0,0,0,0,0\n", .{
                i + 1,         digest_hex,      results[i].cov.applied_ok,
                results[i].cov.skippedTotal(), results[i].cov.errors_total, results[i].header_height,
                results[i].last_slot,   results[i].last_block_no,
            }) catch continue;
        }
    }
}

fn writeBenchPerBlockCsv(
    alloc: std.mem.Allocator,
    dir: []const u8,
    results: []const RunResult,
    num_runs: usize,
) void {
    const path = std.fmt.allocPrint(alloc, "{s}/per_block.csv", .{dir}) catch return;
    defer alloc.free(path);

    var f = compat.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer f.close();
    const w = f.writer();

    w.print("run,block_index,elapsed_us,applied_ok,skipped_reason\n", .{}) catch return;

    for (0..num_runs) |i| {
        const bt = results[i].block_timings orelse continue;
        for (bt, 0..) |t, bi| {
            const applied_str: []const u8 = if (t.applied) "1" else "0";
            w.print("{d},{d},{d},{s},{s}\n", .{
                i + 1, bi + 1, t.elapsed_us, applied_str, t.skip_reason,
            }) catch continue;
        }
    }
}

// ── Legacy report writers (backward-compatible with v0.8.20) ─────────

fn writeLegacyReports(
    alloc: std.mem.Allocator,
    dir: []const u8,
    prefix: []const u8,
    file_path: []const u8,
    lmdb_dir: []const u8,
    max_blocks: usize,
    from_offset: u64,
    strict: bool,
    r: *const RunResult,
) void {
    const json_path = std.fmt.allocPrint(alloc, "{s}/{s}.report.json", .{ dir, prefix }) catch return;
    defer alloc.free(json_path);
    const csv_path = std.fmt.allocPrint(alloc, "{s}/{s}.report.csv", .{ dir, prefix }) catch return;
    defer alloc.free(csv_path);

    const blocks_denom: u64 = if (r.blocks > 0) r.blocks else 1;
    const coverage_ratio_int = r.cov.applied_ok * 1_000_000 / blocks_denom;
    const cov_whole = coverage_ratio_int / 1_000_000;
    const cov_frac = coverage_ratio_int % 1_000_000;

    writeJsonReport(alloc, json_path, file_path, lmdb_dir, max_blocks, from_offset, strict, r.blocks, &r.cov, cov_whole, cov_frac, &r.digest, r.header_height, r.last_slot, r.last_block_no);
    writeCsvReport(alloc, csv_path, file_path, lmdb_dir, max_blocks, from_offset, strict, r.blocks, &r.cov, cov_whole, cov_frac, &r.digest, r.header_height, r.last_slot, r.last_block_no);

    std.debug.print("REPLAY REPORT: json={s} csv={s}\n", .{ json_path, csv_path });
}

fn writeJsonReport(
    alloc: std.mem.Allocator,
    path: []const u8,
    file_path: []const u8,
    lmdb_dir: []const u8,
    max_blocks: usize,
    from_offset: u64,
    strict: bool,
    blocks: u64,
    cov: *const Coverage,
    cov_whole: u64,
    cov_frac: u64,
    digest: *const [32]u8,
    header_height: u64,
    last_slot: u64,
    last_block_no: u64,
) void {
    var f = compat.fs.cwd().createFile(path, .{ .truncate = true }) catch |err| {
        std.debug.print("REPLAY REPORT: failed to write {s} ({s})\n", .{ path, @errorName(err) });
        return;
    };
    defer f.close();
    const w = f.writer();
    const now: u64 = @intCast(compat.timestamp());
    const top = cov.topSkipReason();
    const strict_str: []const u8 = if (strict) "true" else "false";

    const digest_hex = std.fmt.allocPrint(alloc, "{x}", .{digest}) catch return;
    defer alloc.free(digest_hex);

    w.print("{{\n", .{}) catch return;
    w.print("  \"unix\": {d},\n", .{now}) catch return;
    w.print("  \"file\": \"{s}\",\n", .{file_path}) catch return;
    w.print("  \"lmdb\": \"{s}\",\n", .{lmdb_dir}) catch return;
    w.print("  \"max_blocks\": {d},\n", .{max_blocks}) catch return;
    w.print("  \"from_offset\": {d},\n", .{from_offset}) catch return;
    w.print("  \"strict\": {s},\n", .{strict_str}) catch return;
    w.print("  \"blocks_total\": {d},\n", .{blocks}) catch return;
    w.print("  \"applied_ok\": {d},\n", .{cov.applied_ok}) catch return;
    w.print("  \"skipped_total\": {d},\n", .{cov.skippedTotal()}) catch return;
    w.print("  \"errors_total\": {d},\n", .{cov.errors_total}) catch return;
    w.print("  \"coverage_ratio\": {d}.{d:0>6},\n", .{ cov_whole, cov_frac }) catch return;
    w.print("  \"top_skip_reason\": \"{s}\",\n", .{top.name}) catch return;
    w.print("  \"skips\": {{\n", .{}) catch return;
    w.print("    \"missing_inputs\": {d},\n", .{cov.skipped_missing_inputs}) catch return;
    w.print("    \"bodyhash_missing\": {d},\n", .{cov.skipped_bodyhash_missing}) catch return;
    w.print("    \"bodyhash_mismatch\": {d},\n", .{cov.skipped_bodyhash_mismatch}) catch return;
    w.print("    \"header_integrity\": {d},\n", .{cov.skipped_header_integrity_fail}) catch return;
    w.print("    \"ledger_violation\": {d},\n", .{cov.skipped_ledger_violation}) catch return;
    w.print("    \"decode_error\": {d},\n", .{cov.skipped_decode_error}) catch return;
    w.print("    \"other\": {d}\n", .{cov.skipped_other}) catch return;
    w.print("  }},\n", .{}) catch return;
    w.print("  \"header_height\": {d},\n", .{header_height}) catch return;
    w.print("  \"last_slot\": {d},\n", .{last_slot}) catch return;
    w.print("  \"last_block\": {d},\n", .{last_block_no}) catch return;
    w.print("  \"state_digest\": \"{s}\"\n", .{digest_hex}) catch return;
    w.print("}}\n", .{}) catch return;
}

fn writeCsvReport(
    alloc: std.mem.Allocator,
    path: []const u8,
    file_path: []const u8,
    lmdb_dir: []const u8,
    max_blocks: usize,
    from_offset: u64,
    strict: bool,
    blocks: u64,
    cov: *const Coverage,
    cov_whole: u64,
    cov_frac: u64,
    digest: *const [32]u8,
    header_height: u64,
    last_slot: u64,
    last_block_no: u64,
) void {
    var f = compat.fs.cwd().createFile(path, .{ .truncate = true }) catch |err| {
        std.debug.print("REPLAY REPORT: failed to write {s} ({s})\n", .{ path, @errorName(err) });
        return;
    };
    defer f.close();
    const w = f.writer();
    const now: u64 = @intCast(compat.timestamp());
    const top = cov.topSkipReason();
    const strict_str: []const u8 = if (strict) "true" else "false";

    const digest_hex = std.fmt.allocPrint(alloc, "{x}", .{digest}) catch return;
    defer alloc.free(digest_hex);

    w.print("unix,file,lmdb,max_blocks,from_offset,strict,blocks_total,applied_ok,skipped_total,errors_total,coverage_ratio,top_skip_reason,missing_inputs,bodyhash_missing,bodyhash_mismatch,header_integrity,ledger_violation,decode_error,other,header_height,last_slot,last_block,state_digest\n", .{}) catch return;

    w.print("{d},\"{s}\",\"{s}\",{d},{d},{s},{d},{d},{d},{d},{d}.{d:0>6},{s},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{s}\n", .{
        now,
        file_path,
        lmdb_dir,
        max_blocks,
        from_offset,
        strict_str,
        blocks,
        cov.applied_ok,
        cov.skippedTotal(),
        cov.errors_total,
        cov_whole,
        cov_frac,
        top.name,
        cov.skipped_missing_inputs,
        cov.skipped_bodyhash_missing,
        cov.skipped_bodyhash_mismatch,
        cov.skipped_header_integrity_fail,
        cov.skipped_ledger_violation,
        cov.skipped_decode_error,
        cov.skipped_other,
        header_height,
        last_slot,
        last_block_no,
        digest_hex,
    }) catch return;
}
