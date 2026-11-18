const std = @import("std");
const compat = @import("compat");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;
const pack = @import("../producer/pack.zig");

fn findJsonNumValue(json: []const u8, key: []const u8) ?u64 {
    var search_buf: [128]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, json, search) orelse return null;
    var i = pos + search.len;
    while (i < json.len and json[i] == ' ') : (i += 1) {}
    if (i >= json.len) return null;
    // Skip negative sign (result is u64, caller handles sign)
    if (json[i] == '-') {
        i += 1;
    }
    var end = i;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
    if (end == i) return null;
    return std.fmt.parseUnsigned(u64, json[i..end], 10) catch null;
}

fn findJsonStringValue(json: []const u8, key: []const u8, comptime len: usize) ?[len]u8 {
    var search_buf: [128]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, json, search) orelse return null;
    const start = pos + search.len;
    if (start + len > json.len) return null;
    var result: [len]u8 = undefined;
    @memcpy(&result, json[start..][0..len]);
    return result;
}

fn readFile(alloc: std.mem.Allocator, path: []const u8) ?[]const u8 {
    var file = compat.fs.cwd().openFile(path, .{ .mode = .read_only }) catch return null;
    defer file.close();
    return file.readToEndAlloc(alloc, 65536) catch null;
}

fn fetchState(alloc: std.mem.Allocator) ?[]const u8 {
    const io = compat.defaultIo();
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", 9080) catch return null;
    const stream = compat.tcpConnectToAddress(addr) catch return null;
    defer stream.close(io);
    const sw = compat.streamWriter(stream);
    sw.print("GET /state HTTP/1.1\r\nHost: 127.0.0.1:9080\r\nConnection: close\r\n\r\n", .{}) catch return null;
    var resp_buf = alloc.alloc(u8, 65536) catch return null;
    // Persistent reader buffer for protocol reads (do NOT recreate per read).
    var read_buf: [4096]u8 = undefined;
    var stream_reader = std.Io.net.Stream.Reader.init(stream, io, &read_buf);
    // readSliceShort fills the destination fully or stops at end-of-stream,
    // matching the original "read until buffer full or peer closes" loop.
    const total_read: usize = stream_reader.interface.readSliceShort(resp_buf) catch 0;
    if (total_read == 0) {
        alloc.free(resp_buf);
        return null;
    }
    const resp = resp_buf[0..total_read];
    // Find body after \r\n\r\n
    if (std.mem.indexOf(u8, resp, "\r\n\r\n")) |hdr_end| {
        const body_start = hdr_end + 4;
        // Move body to front so we can return the slice
        const body_len = total_read - body_start;
        std.mem.copyForwards(u8, resp_buf[0..body_len], resp[body_start..total_read]);
        return resp_buf[0..body_len];
    }
    alloc.free(resp_buf);
    return null;
}

pub fn run(alloc: std.mem.Allocator) u8 {
    std.debug.print("=== TSUNAGI Pack Now ===\n\n", .{});

    const home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch {
        std.debug.print("FAIL: TSUNAGI_HOME not set\n", .{});
        return 1;
    };
    defer alloc.free(home);

    const producer_dir = std.fmt.allocPrint(alloc, "{s}/producer", .{home}) catch return 1;
    defer alloc.free(producer_dir);

    // Read header bytes (legacy filename candidate_hdr_166.bin, content is 198 bytes)
    const hdr_path = std.fmt.allocPrint(alloc, "{s}/candidate_hdr_166.bin", .{producer_dir}) catch return 1;
    defer alloc.free(hdr_path);
    const hdr_data = readFile(alloc, hdr_path);
    if (hdr_data == null) {
        std.debug.print("FAIL: cannot read {s}\n", .{hdr_path});
        return 1;
    }
    defer alloc.free(hdr_data.?);
    const hdr = hdr_data.?;
    if (hdr.len < 198) {
        std.debug.print("FAIL: header too short ({d} bytes, expected 198)\n", .{hdr.len});
        return 1;
    }
    std.debug.print("  header:    {d} bytes\n", .{hdr.len});

    // Read body CBOR
    const body_path = std.fmt.allocPrint(alloc, "{s}/candidate_body.cbor", .{producer_dir}) catch return 1;
    defer alloc.free(body_path);
    const body_data = readFile(alloc, body_path);
    if (body_data == null) {
        std.debug.print("FAIL: cannot read {s}\n", .{body_path});
        return 1;
    }
    defer alloc.free(body_data.?);
    const body = body_data.?;
    std.debug.print("  body:      {d} bytes\n", .{body.len});

    // Read VRF proof (optional)
    const vrf_proof_path = std.fmt.allocPrint(alloc, "{s}/vrf_proof.bin", .{producer_dir}) catch return 1;
    defer alloc.free(vrf_proof_path);
    const vrf_proof_data = readFile(alloc, vrf_proof_path);
    defer if (vrf_proof_data) |d| alloc.free(d);
    if (vrf_proof_data) |d| {
        std.debug.print("  vrf_proof: {d} bytes\n", .{d.len});
    } else {
        std.debug.print("  vrf_proof: absent\n", .{});
    }

    // Read VRF output (optional)
    const vrf_output_path = std.fmt.allocPrint(alloc, "{s}/vrf_output.bin", .{producer_dir}) catch return 1;
    defer alloc.free(vrf_output_path);
    const vrf_output_data = readFile(alloc, vrf_output_path);
    defer if (vrf_output_data) |d| alloc.free(d);
    if (vrf_output_data) |d| {
        std.debug.print("  vrf_out:   {d} bytes\n", .{d.len});
    } else {
        std.debug.print("  vrf_out:   absent\n", .{});
    }

    // Read signature (optional)
    const sig_path = std.fmt.allocPrint(alloc, "{s}/candidate_sig_64.bin", .{producer_dir}) catch return 1;
    defer alloc.free(sig_path);
    const sig_data = readFile(alloc, sig_path);
    defer if (sig_data) |d| alloc.free(d);
    if (sig_data) |d| {
        std.debug.print("  sig:       {d} bytes\n", .{d.len});
    } else {
        std.debug.print("  sig:       absent\n", .{});
    }

    // Compute body hash
    var body_hash: [32]u8 = undefined;
    Blake2b256.hash(body, &body_hash, .{});
    const bh_w0 = std.mem.readInt(u64, body_hash[0..8], .big);
    const bh_w1 = std.mem.readInt(u64, body_hash[8..16], .big);
    const bh_w2 = std.mem.readInt(u64, body_hash[16..24], .big);
    const bh_w3 = std.mem.readInt(u64, body_hash[24..32], .big);

    // Compute header hash
    var hdr_hash: [32]u8 = undefined;
    Blake2b256.hash(hdr[0..198], &hdr_hash, .{});
    const hh_w0 = std.mem.readInt(u64, hdr_hash[0..8], .big);
    const hh_w1 = std.mem.readInt(u64, hdr_hash[8..16], .big);

    // Read metadata from body_meta.json
    const meta_path = std.fmt.allocPrint(alloc, "{s}/body_meta.json", .{producer_dir}) catch return 1;
    defer alloc.free(meta_path);
    const meta_data = readFile(alloc, meta_path);
    var meta_slot: u64 = 0;
    var meta_epoch: u64 = 0;
    var meta_sie: u64 = 0;
    if (meta_data) |md| {
        defer alloc.free(md);
        meta_slot = findJsonNumValue(md, "slot") orelse 0;
        meta_epoch = findJsonNumValue(md, "epoch") orelse 0;
        meta_sie = findJsonNumValue(md, "slot_in_epoch") orelse 0;
    }

    // Read VRF meta for input_epoch/input_slot (v3)
    const vrf_meta_path = std.fmt.allocPrint(alloc, "{s}/vrf_meta.json", .{producer_dir}) catch return 1;
    defer alloc.free(vrf_meta_path);
    const vrf_meta_data = readFile(alloc, vrf_meta_path);
    var vrf_input_epoch: u64 = 0;
    var vrf_input_slot: u64 = 0;
    if (vrf_meta_data) |vmd| {
        defer alloc.free(vmd);
        vrf_input_epoch = findJsonNumValue(vmd, "epoch") orelse 0;
        vrf_input_slot = findJsonNumValue(vmd, "slot") orelse 0;
    }

    // VRF prefixes
    var vrf_proof_prefix: u64 = 0;
    var vrf_output_prefix: u64 = 0;
    if (vrf_proof_data) |d| {
        if (d.len >= 8) vrf_proof_prefix = std.mem.readInt(u64, d[0..8], .big);
    }
    if (vrf_output_data) |d| {
        if (d.len >= 8) vrf_output_prefix = std.mem.readInt(u64, d[0..8], .big);
    }

    // Sig prefix
    var sig_prefix: u64 = 0;
    if (sig_data) |d| {
        if (d.len >= 8) sig_prefix = std.mem.readInt(u64, d[0..8], .big);
    }

    // Read VRF public key (optional, v3)
    const vrf_pk_path = std.fmt.allocPrint(alloc, "{s}/vrf_pk.bin", .{producer_dir}) catch return 1;
    defer alloc.free(vrf_pk_path);
    const vrf_pk_data = readFile(alloc, vrf_pk_path);
    defer if (vrf_pk_data) |d| alloc.free(d);
    var vrf_pk_bin: ?[32]u8 = null;
    if (vrf_pk_data) |d| {
        if (d.len == 32) {
            vrf_pk_bin = d[0..32].*;
            std.debug.print("  vrf_pk:    32 bytes\n", .{});
        }
    }
    if (vrf_pk_bin == null) std.debug.print("  vrf_pk:    absent\n", .{});

    // Read KES public key (optional, v3)
    const kes_pk_path = std.fmt.allocPrint(alloc, "{s}/kes_pk.bin", .{producer_dir}) catch return 1;
    defer alloc.free(kes_pk_path);
    const kes_pk_data = readFile(alloc, kes_pk_path);
    defer if (kes_pk_data) |d| alloc.free(d);
    var kes_pk_bin: ?[32]u8 = null;
    if (kes_pk_data) |d| {
        if (d.len == 32) {
            kes_pk_bin = d[0..32].*;
            std.debug.print("  kes_pk:    32 bytes\n", .{});
        }
    }
    if (kes_pk_bin == null) std.debug.print("  kes_pk:    absent\n", .{});

    // Hex-encode VRF and KES public keys for PackMeta
    const hx = "0123456789abcdef";
    var vrf_pk_hex: [64]u8 = [_]u8{'0'} ** 64;
    if (vrf_pk_bin) |pk| {
        for (0..32) |i| {
            vrf_pk_hex[i * 2] = hx[pk[i] >> 4];
            vrf_pk_hex[i * 2 + 1] = hx[pk[i] & 0xf];
        }
    }
    var kes_pk_hex: [64]u8 = [_]u8{'0'} ** 64;
    if (kes_pk_bin) |pk| {
        for (0..32) |i| {
            kes_pk_hex[i * 2] = hx[pk[i] >> 4];
            kes_pk_hex[i * 2 + 1] = hx[pk[i] & 0xf];
        }
    }

    // Extract net_magic from CBOR body (offset 17 for mainnet u32)
    var net_magic: u64 = 0;
    if (body.len > 22 and body[17] == 0x1a) {
        net_magic = std.mem.readInt(u32, body[18..22], .big);
    } else if (body.len > 17 and body[17] < 24) {
        net_magic = body[17];
    }

    const tip_block: u64 = 0;

    // Try to fetch /state for state snapshot enrichment
    var ss_genesis_magic: u64 = 0;
    const ss_genesis_start_unix: i64 = 0;
    const ss_genesis_slot_len_s: i64 = 0;
    var ss_leader_epoch: u64 = 0;
    var ss_leader_sie: u64 = 0;
    var ss_leader_prob: u64 = 0;
    var ss_leader_expected: u64 = 0;
    var ss_praos_enabled: u64 = 0;
    var ss_praos_u: u64 = 0;
    var ss_praos_t: u64 = 0;
    var ss_praos_leader: u64 = 0;
    var ss_praos_reason: u64 = 0;
    var ss_praos_u_lt_t: u64 = 0;
    var ss_stake_x1e9: u64 = 0;
    var ss_asc_x1e6: u64 = 0;
    const ss_vrf_enabled: u64 = 0;
    const ss_vrf_reason: u64 = 0;
    const ss_vrf_proof_present: u64 = 0;
    const ss_vrf_output_present: u64 = 0;
    const ss_vrf_proof_len: u64 = 0;
    const ss_vrf_output_len: u64 = 0;
    const ss_vrf_output_prefix: u64 = 0;
    const ss_kes_enabled: u64 = 0;
    const ss_kes_reason: u64 = 0;
    const ss_kes_ok_total: u64 = 0;
    const ss_kes_present: u64 = 0;
    const ss_kes_prefix: u64 = 0;
    const ss_cand_hdr_len: u64 = 0;
    const ss_cand_hdr_hash: u64 = 0;
    const ss_cand_body_len: u64 = 0;
    const ss_cand_sig: u64 = 0;
    var ss_sched_leaders: u64 = 0;
    var ss_sched_next: u64 = 0;
    // KES lifecycle (v1.1.2)
    var ss_kes_cur_period: u64 = 0;
    var ss_kes_valid: u64 = 0;
    var ss_kes_reason_code: u64 = 0;
    var ss_kes_start_period: u64 = 0;
    var ss_kes_max_periods: u64 = 62;
    // Producer state digest (v1.2.0)
    var ss_digest_hex: [64]u8 = [_]u8{'0'} ** 64;

    const state_json = fetchState(alloc);
    if (state_json) |sj| {
        const sj_alloc: []u8 = @constCast(sj.ptr)[0..65536];
        defer alloc.free(sj_alloc);
        std.debug.print("  /state:    fetched ({d} bytes)\n", .{sj.len});
        ss_genesis_magic = findJsonNumValue(sj, "network_magic") orelse 0;
        ss_leader_epoch = findJsonNumValue(sj, "epoch_last") orelse 0;
        ss_leader_sie = findJsonNumValue(sj, "slot_in_epoch_last") orelse 0;
        ss_leader_prob = findJsonNumValue(sj, "prob_x1e6") orelse 0;
        ss_leader_expected = findJsonNumValue(sj, "expected_leaders_per_epoch") orelse 0;
        ss_praos_enabled = findJsonNumValue(sj, "praos_enabled") orelse 0;
        // praos sub-object fields (unique keys in the JSON)
        ss_praos_u = findJsonNumValue(sj, "u_x1e12") orelse 0;
        ss_praos_t = findJsonNumValue(sj, "thresh_x1e12") orelse 0;
        ss_praos_leader = findJsonNumValue(sj, "leader_last") orelse 0;
        ss_praos_reason = findJsonNumValue(sj, "reason_code_last") orelse 0;
        ss_praos_u_lt_t = findJsonNumValue(sj, "u_lt_t") orelse 0;
        ss_stake_x1e9 = findJsonNumValue(sj, "stake_fraction_x1e9") orelse 0;
        ss_asc_x1e6 = findJsonNumValue(sj, "asc_x1e6") orelse 0;
        // Slot scheduler (v1.1.0)
        ss_sched_leaders = findJsonNumValue(sj, "leaders_in_window") orelse 0;
        ss_sched_next = findJsonNumValue(sj, "next_leader_offset") orelse 0;
        // KES lifecycle (v1.1.2)
        ss_kes_cur_period = findJsonNumValue(sj, "current_period") orelse 0;
        ss_kes_valid = findJsonNumValue(sj, "period_valid_last") orelse 0;
        ss_kes_reason_code = findJsonNumValue(sj, "period_reason_code_last") orelse 0;
        ss_kes_start_period = findJsonNumValue(sj, "start_period") orelse 0;
        ss_kes_max_periods = findJsonNumValue(sj, "max_periods") orelse 62;
        // Producer state digest (v1.2.0)
        if (findJsonStringValue(sj, "producer_state_digest", 64)) |d| {
            ss_digest_hex = d;
        }
    } else {
        std.debug.print("  /state:    unavailable (using defaults)\n", .{});
    }

    const now = compat.timestamp();
    const meta = pack.PackMeta{
        .unix = now,
        .slot = meta_slot,
        .epoch = meta_epoch,
        .slot_in_epoch = meta_sie,
        .net_magic = net_magic,
        .tip_block = tip_block,
        .hdr_bytes_len = @intCast(hdr.len),
        .hdr_hash_w0 = hh_w0,
        .hdr_hash_w1 = hh_w1,
        .body_cbor_len = @intCast(body.len),
        .body_hash_w0 = bh_w0,
        .body_hash_w1 = bh_w1,
        .body_hash_w2 = bh_w2,
        .body_hash_w3 = bh_w3,
        .vrf_proof_len = if (vrf_proof_data) |d| @intCast(d.len) else 0,
        .vrf_output_len = if (vrf_output_data) |d| @intCast(d.len) else 0,
        .vrf_proof_prefix = vrf_proof_prefix,
        .vrf_output_prefix = vrf_output_prefix,
        .sig_len = if (sig_data) |d| @intCast(d.len) else 0,
        .sig_prefix = sig_prefix,
        .sign_reason = 0,
        .pool_id_prefix_hex = [_]u8{'0'} ** 16,
        // State snapshot
        .state_genesis_magic = ss_genesis_magic,
        .state_genesis_start_unix = ss_genesis_start_unix,
        .state_genesis_slot_len_s = ss_genesis_slot_len_s,
        .state_leader_epoch = ss_leader_epoch,
        .state_leader_sie = ss_leader_sie,
        .state_leader_prob_x1e6 = ss_leader_prob,
        .state_leader_expected = ss_leader_expected,
        .state_praos_enabled = ss_praos_enabled,
        .state_praos_u_x1e12 = ss_praos_u,
        .state_praos_thresh_x1e12 = ss_praos_t,
        .state_praos_leader_last = ss_praos_leader,
        .state_praos_reason_last = ss_praos_reason,
        .state_praos_u_lt_t = ss_praos_u_lt_t,
        .state_vrf_enabled = ss_vrf_enabled,
        .state_vrf_reason_code = ss_vrf_reason,
        .state_vrf_proof_present = ss_vrf_proof_present,
        .state_vrf_output_present = ss_vrf_output_present,
        .state_vrf_proof_len = ss_vrf_proof_len,
        .state_vrf_output_len = ss_vrf_output_len,
        .state_vrf_output_prefix = ss_vrf_output_prefix,
        .state_kes_sign_enabled = ss_kes_enabled,
        .state_kes_sign_reason = ss_kes_reason,
        .state_kes_sign_ok_total = ss_kes_ok_total,
        .state_kes_sign_present = ss_kes_present,
        .state_kes_sign_prefix = ss_kes_prefix,
        .state_candidate_hdr_len = ss_cand_hdr_len,
        .state_candidate_hdr_hash_prefix = ss_cand_hdr_hash,
        .state_candidate_body_len = ss_cand_body_len,
        .state_candidate_sig_present = ss_cand_sig,
        // KES lifecycle (v1.1.2)
        .state_kes_cur_period = ss_kes_cur_period,
        .state_kes_valid = ss_kes_valid,
        .state_kes_reason_code = ss_kes_reason_code,
        .state_kes_start_period = ss_kes_start_period,
        .state_kes_max_periods = ss_kes_max_periods,
        // Slot scheduler (v1.1.0)
        .state_schedule_window = 128,
        .state_schedule_leaders_in_window = ss_sched_leaders,
        .state_schedule_next_leader_offset = ss_sched_next,
        // Producer state digest (v1.2.0)
        .state_producer_digest_hex = ss_digest_hex,
        // Cryptographic closure (v3)
        .vrf_pk_hex = vrf_pk_hex,
        .kes_pk_hex = kes_pk_hex,
        .stake_fraction_x1e9 = ss_stake_x1e9,
        .asc_x1e6 = ss_asc_x1e6,
        .vrf_input_epoch = vrf_input_epoch,
        .vrf_input_slot = vrf_input_slot,
    };

    std.debug.print("\n  Building pack (v3)...\n", .{});
    const result = pack.buildPack(alloc, home, meta, hdr, body, vrf_proof_data, vrf_output_data, sig_data, vrf_pk_bin, kes_pk_bin);

    if (result.ok) {
        std.debug.print("  Pack written to {s}/producer/pack/latest/\n", .{home});
        std.debug.print("\n=== Pack Now: OK ===\n", .{});
        return 0;
    } else {
        std.debug.print("\n=== Pack Now: FAIL ===\n", .{});
        return 1;
    }
}
