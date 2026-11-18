const std = @import("std");
const compat = @import("compat");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

pub const PackMeta = struct {
    unix: i64,
    slot: u64,
    epoch: u64,
    slot_in_epoch: u64,
    net_magic: u64,
    tip_block: u64,
    hdr_bytes_len: u64,
    hdr_hash_w0: u64,
    hdr_hash_w1: u64,
    body_cbor_len: u64,
    body_hash_w0: u64,
    body_hash_w1: u64,
    body_hash_w2: u64,
    body_hash_w3: u64,
    vrf_proof_len: u64,
    vrf_output_len: u64,
    vrf_proof_prefix: u64,
    vrf_output_prefix: u64,
    sig_len: u64,
    sig_prefix: u64,
    sign_reason: u64,
    pool_id_prefix_hex: [16]u8,
    // State snapshot (v2)
    state_genesis_magic: u64,
    state_genesis_start_unix: i64,
    state_genesis_slot_len_s: i64,
    state_leader_epoch: u64,
    state_leader_sie: u64,
    state_leader_prob_x1e6: u64,
    state_leader_expected: u64,
    state_praos_enabled: u64,
    state_praos_u_x1e12: u64,
    state_praos_thresh_x1e12: u64,
    state_praos_leader_last: u64,
    state_praos_reason_last: u64,
    // Praos decision surface (v1.1.3)
    state_praos_u_lt_t: u64,
    state_vrf_enabled: u64,
    state_vrf_reason_code: u64,
    state_vrf_proof_present: u64,
    state_vrf_output_present: u64,
    state_vrf_proof_len: u64,
    state_vrf_output_len: u64,
    state_vrf_output_prefix: u64,
    state_kes_sign_enabled: u64,
    state_kes_sign_reason: u64,
    state_kes_sign_ok_total: u64,
    state_kes_sign_present: u64,
    state_kes_sign_prefix: u64,
    state_candidate_hdr_len: u64,
    state_candidate_hdr_hash_prefix: u64,
    state_candidate_body_len: u64,
    state_candidate_sig_present: u64,
    // KES lifecycle (v1.1.2)
    state_kes_cur_period: u64,
    state_kes_valid: u64,
    state_kes_reason_code: u64,
    state_kes_start_period: u64,
    state_kes_max_periods: u64,
    // Producer state digest (v1.2.0)
    state_producer_digest_hex: [64]u8,
    // Slot scheduler (v1.1.0)
    state_schedule_window: u64,
    state_schedule_leaders_in_window: u64,
    state_schedule_next_leader_offset: u64,
    // Cryptographic closure (v3)
    vrf_pk_hex: [64]u8,
    kes_pk_hex: [64]u8,
    stake_fraction_x1e9: u64,
    asc_x1e6: u64,
    vrf_input_epoch: u64,
    vrf_input_slot: u64,
};

pub const PackResult = struct {
    ok: bool,
};

const hex_chars = "0123456789abcdef";

fn hexEncode8(buf: *[16]u8, val: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, val, .big);
    for (0..8) |i| {
        buf[i * 2] = hex_chars[bytes[i] >> 4];
        buf[i * 2 + 1] = hex_chars[bytes[i] & 0xf];
    }
}

fn hexEncode32(buf: *[64]u8, w0: u64, w1: u64, w2: u64, w3: u64) void {
    var bytes: [32]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], w0, .big);
    std.mem.writeInt(u64, bytes[8..16], w1, .big);
    std.mem.writeInt(u64, bytes[16..24], w2, .big);
    std.mem.writeInt(u64, bytes[24..32], w3, .big);
    for (0..32) |i| {
        buf[i * 2] = hex_chars[bytes[i] >> 4];
        buf[i * 2 + 1] = hex_chars[bytes[i] & 0xf];
    }
}

fn hashBytesHex(buf: *[64]u8, data: []const u8) void {
    var digest: [32]u8 = undefined;
    Blake2b256.hash(data, &digest, .{});
    for (0..32) |i| {
        buf[i * 2] = hex_chars[digest[i] >> 4];
        buf[i * 2 + 1] = hex_chars[digest[i] & 0xf];
    }
}

fn writeFileToDir(alloc: std.mem.Allocator, dir: []const u8, name: []const u8, data: []const u8) bool {
    const tmp_path = std.fmt.allocPrint(alloc, "{s}/{s}.tmp", .{ dir, name }) catch return false;
    defer alloc.free(tmp_path);
    const final_path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name }) catch return false;
    defer alloc.free(final_path);
    var file = compat.fs.cwd().createFile(tmp_path, .{}) catch return false;
    file.writeAll(data) catch {
        file.close();
        return false;
    };
    file.close();
    compat.fs.cwd().rename(tmp_path, final_path) catch return false;
    return true;
}

/// Build a proof pack: writes files to timestamped dir + latest/.
pub fn buildPack(
    alloc: std.mem.Allocator,
    tsunagi_home: []const u8,
    meta: PackMeta,
    hdr_bytes: []const u8,
    body_cbor: []const u8,
    vrf_proof: ?[]const u8,
    vrf_output: ?[]const u8,
    sig_bytes: ?[]const u8,
    vrf_pk: ?[32]u8,
    kes_pk: ?[32]u8,
) PackResult {
    const ts_dir = std.fmt.allocPrint(alloc, "{s}/producer/pack/pack-{d}-slot-{d}-block-{d}", .{
        tsunagi_home, meta.unix, meta.slot, meta.tip_block,
    }) catch return .{ .ok = false };
    defer alloc.free(ts_dir);

    const latest_dir = std.fmt.allocPrint(alloc, "{s}/producer/pack/latest", .{tsunagi_home}) catch return .{ .ok = false };
    defer alloc.free(latest_dir);

    compat.fs.cwd().makePath(ts_dir) catch return .{ .ok = false };
    compat.fs.cwd().makePath(latest_dir) catch return .{ .ok = false };

    // Recompute full header hash from raw bytes for pack.json
    var full_hdr_hash: [32]u8 = [_]u8{0} ** 32;
    if (hdr_bytes.len >= 198) {
        Blake2b256.hash(hdr_bytes[0..198], &full_hdr_hash, .{});
    }
    var full_hdr_hex: [64]u8 = undefined;
    hexEncode32(&full_hdr_hex, std.mem.readInt(u64, full_hdr_hash[0..8], .big), std.mem.readInt(u64, full_hdr_hash[8..16], .big), std.mem.readInt(u64, full_hdr_hash[16..24], .big), std.mem.readInt(u64, full_hdr_hash[24..32], .big));

    // Build hex strings
    var bh_hex: [64]u8 = undefined;
    hexEncode32(&bh_hex, meta.body_hash_w0, meta.body_hash_w1, meta.body_hash_w2, meta.body_hash_w3);

    var vp_hex: [16]u8 = undefined;
    hexEncode8(&vp_hex, meta.vrf_proof_prefix);

    var vo_hex: [16]u8 = undefined;
    hexEncode8(&vo_hex, meta.vrf_output_prefix);

    var sp_hex: [16]u8 = undefined;
    hexEncode8(&sp_hex, meta.sig_prefix);

    // Build candidate_body_hash.bin (32 bytes from words)
    var body_hash_bin: [32]u8 = undefined;
    std.mem.writeInt(u64, body_hash_bin[0..8], meta.body_hash_w0, .big);
    std.mem.writeInt(u64, body_hash_bin[8..16], meta.body_hash_w1, .big);
    std.mem.writeInt(u64, body_hash_bin[16..24], meta.body_hash_w2, .big);
    std.mem.writeInt(u64, body_hash_bin[24..32], meta.body_hash_w3, .big);

    // Per-file blake2b256 hashes (v2)
    var hdr_file_hash: [64]u8 = undefined;
    hashBytesHex(&hdr_file_hash, hdr_bytes);
    var body_file_hash: [64]u8 = undefined;
    hashBytesHex(&body_file_hash, body_cbor);
    var body_hash_file_hash: [64]u8 = undefined;
    hashBytesHex(&body_hash_file_hash, &body_hash_bin);
    var vrf_proof_hash: [64]u8 = undefined;
    if (vrf_proof) |p| hashBytesHex(&vrf_proof_hash, p);
    var vrf_output_hash: [64]u8 = undefined;
    if (vrf_output) |o| hashBytesHex(&vrf_output_hash, o);
    var sig_file_hash: [64]u8 = undefined;
    if (sig_bytes) |s| hashBytesHex(&sig_file_hash, s);
    var vrf_pk_file_hash: [64]u8 = undefined;
    if (vrf_pk) |pk| hashBytesHex(&vrf_pk_file_hash, &pk);
    var kes_pk_file_hash: [64]u8 = undefined;
    if (kes_pk) |pk| hashBytesHex(&kes_pk_file_hash, &pk);

    // State snapshot hex prefixes
    var ss_vrf_out_hex: [16]u8 = undefined;
    hexEncode8(&ss_vrf_out_hex, meta.state_vrf_output_prefix);
    var ss_kes_sig_hex: [16]u8 = undefined;
    hexEncode8(&ss_kes_sig_hex, meta.state_kes_sign_prefix);
    var ss_hdr_hash_hex: [16]u8 = undefined;
    hexEncode8(&ss_hdr_hash_hex, meta.state_candidate_hdr_hash_prefix);

    // Format pack.json v3 using fixedBufferStream
    var json_buf: [12288]u8 = undefined;
    var fbs = compat.fixedBufferStream(&json_buf);
    const w = fbs.writer();

    // V1 fields (backward compatible)
    w.print(
        \\{{"version":3,"pack_schema_version":1,"hash_algorithm":"blake2b-256","unix":{d},"slot":{d},"epoch":{d},"slot_in_epoch":{d},"net_magic":{d},"network_magic":{d},"tip_block":{d},"hdr_bytes_len":{d},"hdr_hash_w0":{d},"hdr_hash_w1":{d},"hdr_hash_hex":"{s}","body_cbor_len":{d},"body_hash_w0":{d},"body_hash_w1":{d},"body_hash_w2":{d},"body_hash_w3":{d},"body_hash_hex":"{s}","vrf_proof_len":{d},"vrf_output_len":{d},"vrf_proof_prefix_hex":"{s}","vrf_output_prefix_hex":"{s}","sig_len":{d},"sig_prefix_hex":"{s}","sign_reason":{d},"pool_id_prefix_hex":"{s}"
    , .{
        meta.unix,          meta.slot,         meta.epoch,         meta.slot_in_epoch,
        meta.net_magic,     meta.net_magic,    meta.tip_block,
        meta.hdr_bytes_len, meta.hdr_hash_w0,  meta.hdr_hash_w1,  &full_hdr_hex,
        meta.body_cbor_len, meta.body_hash_w0, meta.body_hash_w1,  meta.body_hash_w2,
        meta.body_hash_w3,  &bh_hex,
        meta.vrf_proof_len, meta.vrf_output_len, &vp_hex,          &vo_hex,
        meta.sig_len,       &sp_hex,           meta.sign_reason,   &meta.pool_id_prefix_hex,
    }) catch return .{ .ok = false };

    // Files array (v2)
    w.print(
        \\,"files":[{{"name":"candidate_hdr_198.bin","size":{d},"blake2b256":"{s}"}},{{"name":"candidate_body.cbor","size":{d},"blake2b256":"{s}"}},{{"name":"candidate_body_hash.bin","size":32,"blake2b256":"{s}"}}
    , .{
        meta.hdr_bytes_len, &hdr_file_hash,
        meta.body_cbor_len, &body_file_hash,
        &body_hash_file_hash,
    }) catch return .{ .ok = false };
    if (vrf_proof) |p| {
        w.print(
            \\,{{"name":"vrf_proof.bin","size":{d},"blake2b256":"{s}"}}
        , .{ p.len, &vrf_proof_hash }) catch return .{ .ok = false };
    }
    if (vrf_output) |o| {
        w.print(
            \\,{{"name":"vrf_output.bin","size":{d},"blake2b256":"{s}"}}
        , .{ o.len, &vrf_output_hash }) catch return .{ .ok = false };
    }
    if (sig_bytes) |s| {
        w.print(
            \\,{{"name":"candidate_sig_64.bin","size":{d},"blake2b256":"{s}"}}
        , .{ s.len, &sig_file_hash }) catch return .{ .ok = false };
    }
    if (vrf_pk != null) {
        w.print(
            \\,{{"name":"vrf_pk.bin","size":32,"blake2b256":"{s}"}}
        , .{&vrf_pk_file_hash}) catch return .{ .ok = false };
    }
    if (kes_pk != null) {
        w.print(
            \\,{{"name":"kes_pk.bin","size":32,"blake2b256":"{s}"}}
        , .{&kes_pk_file_hash}) catch return .{ .ok = false };
    }
    w.writeAll("]") catch return .{ .ok = false };

    // State snapshot (v2, extended v1.1.2) — split into two prints (Zig 32-arg limit)
    w.print(
        \\,"state_snapshot":{{"genesis":{{"network_magic":{d},"system_start_unix":{d},"slot_length_s":{d}}},"producer_leader":{{"epoch_last":{d},"slot_in_epoch_last":{d},"prob_x1e6":{d},"expected_leaders_per_epoch":{d}}},"praos":{{"enabled":{d},"u_x1e12":{d},"thresh_x1e12":{d},"leader_last":{d},"reason_code_last":{d}}},"vrf":{{"enabled":{d},"reason_code":{d},"proof_present":{d},"output_present":{d},"proof_len_last":{d},"output_len_last":{d},"output_prefix_hex":"{s}"}},"kes_sign":{{"enabled":{d},"reason_code_last":{d},"ok_total":{d},"present_last":{d},"sig_prefix_hex":"{s}"}}
    , .{
        meta.state_genesis_magic, meta.state_genesis_start_unix, meta.state_genesis_slot_len_s,
        meta.state_leader_epoch, meta.state_leader_sie, meta.state_leader_prob_x1e6, meta.state_leader_expected,
        meta.state_praos_enabled, meta.state_praos_u_x1e12, meta.state_praos_thresh_x1e12, meta.state_praos_leader_last, meta.state_praos_reason_last,
        meta.state_vrf_enabled, meta.state_vrf_reason_code, meta.state_vrf_proof_present, meta.state_vrf_output_present, meta.state_vrf_proof_len, meta.state_vrf_output_len, &ss_vrf_out_hex,
        meta.state_kes_sign_enabled, meta.state_kes_sign_reason, meta.state_kes_sign_ok_total, meta.state_kes_sign_present, &ss_kes_sig_hex,
    }) catch return .{ .ok = false };
    w.print(
        \\,"kes_period":{{"cur_period":{d},"kes_valid":{d},"kes_reason_code":{d},"start_period":{d},"max_periods":{d}}},"candidate":{{"hdr_bytes_len":{d},"hdr_hash_prefix_hex":"{s}","body_cbor_len":{d},"body_hash_hex":"{s}","sig_present_last":{d}}},"producer_schedule":{{"window_size":{d},"leaders_in_window":{d},"next_leader_offset":{d}}},"producer_praos":{{"threshold_x1e12":{d},"u_x1e12":{d},"u_lt_t":{d}}},"producer_state_digest":"{s}","safety":{{"no_forging":true,"no_broadcast":true}}}}
    , .{
        meta.state_kes_cur_period, meta.state_kes_valid, meta.state_kes_reason_code, meta.state_kes_start_period, meta.state_kes_max_periods,
        meta.state_candidate_hdr_len, &ss_hdr_hash_hex, meta.state_candidate_body_len, &bh_hex, meta.state_candidate_sig_present,
        meta.state_schedule_window, meta.state_schedule_leaders_in_window, meta.state_schedule_next_leader_offset,
        meta.state_praos_thresh_x1e12, meta.state_praos_u_x1e12, meta.state_praos_u_lt_t, &meta.state_producer_digest_hex,
    }) catch return .{ .ok = false };

    // Praos snapshot (v3)
    w.print(
        \\,"praos_snapshot":{{"stake_fraction_x1e9":{d},"asc_x1e6":{d},"u_x1e12":{d},"thresh_x1e12":{d},"leader":{d},"reason_code":{d}}}
    , .{
        meta.stake_fraction_x1e9, meta.asc_x1e6,
        meta.state_praos_u_x1e12, meta.state_praos_thresh_x1e12,
        meta.state_praos_leader_last, meta.state_praos_reason_last,
    }) catch return .{ .ok = false };

    // VRF snapshot (v3)
    w.print(
        \\,"vrf_snapshot":{{"pk_hex":"{s}","proof_len":{d},"output_len":{d},"input_epoch":{d},"input_slot":{d}}}
    , .{
        &meta.vrf_pk_hex,
        meta.vrf_proof_len, meta.vrf_output_len,
        meta.vrf_input_epoch, meta.vrf_input_slot,
    }) catch return .{ .ok = false };

    // KES snapshot (v3)
    w.print(
        \\,"kes_snapshot":{{"pk_hex":"{s}","sig_len":{d},"label":1}}
    , .{
        &meta.kes_pk_hex, meta.sig_len,
    }) catch return .{ .ok = false };

    // Close root object
    w.writeAll("}") catch return .{ .ok = false };

    const json = fbs.getWritten();

    // Write to both timestamped and latest dirs
    const dirs = [_][]const u8{ ts_dir, latest_dir };
    for (dirs) |dir| {
        if (!writeFileToDir(alloc, dir, "candidate_hdr_198.bin", hdr_bytes)) return .{ .ok = false };
        if (!writeFileToDir(alloc, dir, "candidate_body.cbor", body_cbor)) return .{ .ok = false };
        if (!writeFileToDir(alloc, dir, "candidate_body_hash.bin", &body_hash_bin)) return .{ .ok = false };
        if (vrf_proof) |p| {
            _ = writeFileToDir(alloc, dir, "vrf_proof.bin", p);
        }
        if (vrf_output) |o| {
            _ = writeFileToDir(alloc, dir, "vrf_output.bin", o);
        }
        if (sig_bytes) |s| {
            _ = writeFileToDir(alloc, dir, "candidate_sig_64.bin", s);
        }
        if (vrf_pk) |pk| {
            _ = writeFileToDir(alloc, dir, "vrf_pk.bin", &pk);
        }
        if (kes_pk) |pk| {
            _ = writeFileToDir(alloc, dir, "kes_pk.bin", &pk);
        }
        if (!writeFileToDir(alloc, dir, "pack.json", json)) return .{ .ok = false };
    }

    return .{ .ok = true };
}
