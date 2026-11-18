const std = @import("std");
const compat = @import("compat");
const readiness = @import("../net/consensus/producer_readiness.zig");
const sodium_vrf = @import("../producer/crypto/sodium_vrf.zig");
const kes_sign = @import("../producer/crypto/kes_sign.zig");
const kes_verify = @import("../producer/crypto/kes_verify.zig");
const kes_keyfile = @import("../producer/kes_keyfile.zig");
const cbor_block_body = @import("../producer/cbor_block_body.zig");

/// Producer readiness harness — local-only, no broadcast, no network IO.
///
/// Evaluates whether a pool operator's node would be ready to produce a block
/// at a given slot. Loads VRF and KES keys from disk, computes VRF proof,
/// evaluates Praos leadership, checks KES validity, runs sign+verify,
/// assembles a local candidate, and outputs a deterministic JSON report.
///
/// Usage:
///   tsunagi-node producer-ready --slot <N> [options]
///
/// Options:
///   --vrf-skey <path>           VRF signing key file (cardano-cli JSON envelope)
///   --kes-skey <path>           KES signing key file (cardano-cli JSON envelope)
///   --pool-id <64 hex>          Pool ID (cold verification key hash)
///   --stake-x1e9 <N>            Stake fraction * 1e9 (e.g. 1000000 = 0.1%)
///   --asc-x1e6 <N>              Active slot coefficient * 1e6 (default: 50000 = 0.05)
///   --epoch <N>                 Epoch number (default: 0)
///   --net-magic <N>             Network magic (default: 2 = preview)
///   --tip-block <N>             Tip block number for candidate (default: 0)
///   --tip-hash <64 hex>         Tip block hash for candidate (default: zeros)
///   --kes-period <N>            Current KES period (default: 0)
///   --opcert-start-period <N>   OpCert start KES period (default: 0)
///   --max-kes-evolutions <N>    Max KES evolutions (default: 62)
///   --out <path>                Write JSON report to file
///   --bundle-dir <path>        Write artifact bundle when READY (5 files)
///
/// Exit codes: 0=READY, 1=NOT_LEADER, 2=NOT_READY, 3=usage error, 4=IO error.
///
/// SAFETY: No broadcast. No network IO. No mempool mutation. Local evaluation only.

pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    // ── Parse arguments ──────────────────────────────────────────────
    var slot: ?u64 = null;
    var epoch: u64 = 0;
    var asc_x1e6: u64 = 50_000;
    var net_magic: u32 = 2;
    var tip_block: u64 = 0;
    var stake_x1e9: u64 = 0;
    var kes_period: u32 = 0;
    var opcert_start: u32 = 0;
    var max_kes_evo: u32 = 62;
    var slots_per_epoch: u64 = 86400;

    var vrf_skey_path: ?[]const u8 = null;
    var kes_skey_path: ?[]const u8 = null;
    var pool_id_hex: ?[]const u8 = null;
    var tip_hash_hex: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var bundle_dir: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (eql(arg, "--slot")) {
            slot = parseNextU64(args_it) orelse return usageErr("--slot requires a number");
        } else if (eql(arg, "--epoch")) {
            epoch = parseNextU64(args_it) orelse return usageErr("--epoch requires a number");
        } else if (eql(arg, "--asc-x1e6")) {
            asc_x1e6 = parseNextU64(args_it) orelse return usageErr("--asc-x1e6 requires a number");
        } else if (eql(arg, "--net-magic")) {
            net_magic = @intCast(parseNextU64(args_it) orelse return usageErr("--net-magic requires a number"));
        } else if (eql(arg, "--tip-block")) {
            tip_block = parseNextU64(args_it) orelse return usageErr("--tip-block requires a number");
        } else if (eql(arg, "--stake-x1e9")) {
            stake_x1e9 = parseNextU64(args_it) orelse return usageErr("--stake-x1e9 requires a number");
        } else if (eql(arg, "--kes-period")) {
            kes_period = @intCast(parseNextU64(args_it) orelse return usageErr("--kes-period requires a number"));
        } else if (eql(arg, "--opcert-start-period")) {
            opcert_start = @intCast(parseNextU64(args_it) orelse return usageErr("--opcert-start-period requires a number"));
        } else if (eql(arg, "--max-kes-evolutions")) {
            max_kes_evo = @intCast(parseNextU64(args_it) orelse return usageErr("--max-kes-evolutions requires a number"));
        } else if (eql(arg, "--slots-per-epoch")) {
            slots_per_epoch = parseNextU64(args_it) orelse return usageErr("--slots-per-epoch requires a number");
        } else if (eql(arg, "--vrf-skey")) {
            vrf_skey_path = args_it.next() orelse return usageErr("--vrf-skey requires a path");
        } else if (eql(arg, "--kes-skey")) {
            kes_skey_path = args_it.next() orelse return usageErr("--kes-skey requires a path");
        } else if (eql(arg, "--pool-id")) {
            pool_id_hex = args_it.next() orelse return usageErr("--pool-id requires 64 hex chars");
        } else if (eql(arg, "--tip-hash")) {
            tip_hash_hex = args_it.next() orelse return usageErr("--tip-hash requires 64 hex chars");
        } else if (eql(arg, "--out")) {
            out_path = args_it.next() orelse return usageErr("--out requires a path");
        } else if (eql(arg, "--bundle-dir")) {
            bundle_dir = args_it.next() orelse return usageErr("--bundle-dir requires a path");
        }
    }

    const target_slot = slot orelse {
        std.debug.print("ERROR: --slot <N> is required\n", .{});
        return 3;
    };

    // ── Derived values ───────────────────────────────────────────────
    const slot_in_epoch: u64 = if (slots_per_epoch > 0) target_slot % slots_per_epoch else target_slot;

    var tip_hash: [32]u8 = [_]u8{0} ** 32;
    if (tip_hash_hex) |hex| {
        if (hex.len != 64) {
            std.debug.print("ERROR: --tip-hash must be 64 hex chars\n", .{});
            return 3;
        }
        _ = std.fmt.hexToBytes(&tip_hash, hex) catch {
            std.debug.print("ERROR: --tip-hash invalid hex\n", .{});
            return 3;
        };
    }

    var pool_id: [32]u8 = [_]u8{0} ** 32;
    var has_pool_id = false;
    if (pool_id_hex) |hex| {
        if (hex.len != 64) {
            std.debug.print("ERROR: --pool-id must be 64 hex chars\n", .{});
            return 3;
        }
        _ = std.fmt.hexToBytes(&pool_id, hex) catch {
            std.debug.print("ERROR: --pool-id invalid hex\n", .{});
            return 3;
        };
        has_pool_id = true;
    }

    const has_stake = stake_x1e9 > 0;

    // ── Load VRF key ─────────────────────────────────────────────────
    var has_vrf = false;
    var vrf_output: [64]u8 = [_]u8{0} ** 64;
    var vrf_pk: [32]u8 = [_]u8{0} ** 32;

    if (vrf_skey_path) |vpath| {
        const content = readFileAlloc(alloc, vpath) orelse {
            std.debug.print("ERROR: cannot read VRF key: {s}\n", .{vpath});
            return 4;
        };
        defer alloc.free(content);

        if (parseVrfSeed(content)) |seed| {
            if (sodium_vrf.sodiumInit()) {
                if (sodium_vrf.keypairFromSeed(&seed)) |kp| {
                    vrf_pk = kp.pk;
                    // VRF input: epoch(u64 BE) || slot(u64 BE) = 16 bytes
                    var msg: [16]u8 = undefined;
                    std.mem.writeInt(u64, msg[0..8], epoch, .big);
                    std.mem.writeInt(u64, msg[8..16], target_slot, .big);

                    if (sodium_vrf.prove(&kp.sk, &msg)) |result| {
                        vrf_output = result.output;
                        has_vrf = true;
                    } else {
                        std.debug.print("WARN: VRF prove failed for slot {d}\n", .{target_slot});
                    }
                } else {
                    std.debug.print("WARN: VRF keypair derivation failed\n", .{});
                }
            } else {
                std.debug.print("WARN: libsodium init failed\n", .{});
            }
        } else {
            std.debug.print("WARN: cannot parse VRF seed from {s}\n", .{vpath});
        }
    }

    // ── Load KES key ─────────────────────────────────────────────────
    var has_kes = false;
    var kes_key_state_buf: [kes_sign.SK_FULL_SIZE_6 + 256]u8 = undefined;
    var kes_key_state: ?[]const u8 = null;
    var kes_pk: [32]u8 = [_]u8{0} ** 32;

    if (kes_skey_path) |kpath| {
        const content = readFileAlloc(alloc, kpath) orelse {
            std.debug.print("ERROR: cannot read KES key: {s}\n", .{kpath});
            return 4;
        };
        defer alloc.free(content);

        if (kes_keyfile.isJsonKeyFile(content)) {
            if (kes_keyfile.readKeyJson(content)) |kf| {
                const decoded_len = kes_keyfile.decodeCborHex(kf.cbor_hex, &kes_key_state_buf) orelse 0;
                const kind = kes_keyfile.classifyKesKey(kf.type_str, decoded_len);

                switch (kind) {
                    .cardano_kes => {
                        if (decoded_len == kes_sign.SK_SIZE_6 or decoded_len == kes_sign.SK_FULL_SIZE_6) {
                            kes_key_state = kes_key_state_buf[0..decoded_len];
                            if (kes_sign.extractRootPk(kes_key_state_buf[0..decoded_len])) |pk| {
                                kes_pk = pk;
                                has_kes = true;
                            } else |_| {
                                std.debug.print("WARN: cannot extract KES root PK\n", .{});
                            }
                        } else {
                            std.debug.print("WARN: KES key state unexpected size: {d} (expected {d} or {d})\n", .{
                                decoded_len, kes_sign.SK_SIZE_6, kes_sign.SK_FULL_SIZE_6,
                            });
                        }
                    },
                    .placeholder_seed => {
                        std.debug.print("WARN: KES key is placeholder seed (32 bytes), sign+verify will be skipped\n", .{});
                    },
                    .unknown => {
                        std.debug.print("WARN: KES key type unknown: {s}, decoded {d} bytes\n", .{ kf.type_str, decoded_len });
                    },
                }
            } else {
                std.debug.print("WARN: cannot parse KES key JSON from {s}\n", .{kpath});
            }
        } else {
            std.debug.print("WARN: KES key file is not a cardano-cli JSON envelope: {s}\n", .{kpath});
        }
    }

    // ── Evaluate ─────────────────────────────────────────────────────
    const state_digest = [_]u8{0} ** 32; // placeholder for local evaluation

    const report = readiness.evaluate(
        target_slot,
        epoch,
        slot_in_epoch,
        vrf_output,
        stake_x1e9,
        asc_x1e6,
        has_vrf,
        kes_period,
        opcert_start,
        max_kes_evo,
        kes_key_state,
        kes_pk,
        net_magic,
        tip_block,
        tip_hash,
        state_digest,
        pool_id,
    );

    // ── Cardano wire body stats ──────────────────────────────────────
    const empty_body = cbor_block_body.buildEmptyBody();
    const body_size_bytes = empty_body.body_size; // 4 for empty block

    // ── Format hashes ────────────────────────────────────────────────
    const header_hash_hex = std.fmt.bytesToHex(report.candidate.header_hash, .lower);
    const body_hash_hex = std.fmt.bytesToHex(report.candidate.body_hash, .lower);

    // ── Format JSON report ───────────────────────────────────────────
    var buf: [4096]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{
        \\  "slot": {d},
        \\  "epoch": {d},
        \\  "slot_in_epoch": {d},
        \\  "state": "{s}",
        \\  "leadership": {{
        \\    "status": "{s}",
        \\    "is_leader": {s},
        \\    "u_x1e12": {d},
        \\    "thresh_x1e12": {d},
        \\    "reason": {d}
        \\  }},
        \\  "kes": {{
        \\    "status": "{s}",
        \\    "current_period": {d},
        \\    "start_period": {d},
        \\    "remaining_periods": {d},
        \\    "max_periods": {d},
        \\    "expired": {s}
        \\  }},
        \\  "sign_verify": {{
        \\    "status": "{s}",
        \\    "sign_ok": {s},
        \\    "verify_ok": {s},
        \\    "verify_detail": "{s}"
        \\  }},
        \\  "candidate": {{
        \\    "status": "{s}",
        \\    "header_hash": "{s}",
        \\    "body_hash": "{s}",
        \\    "header_bytes": {d},
        \\    "body_bytes": {d}
        \\  }},
        \\  "availability": {{
        \\    "has_vrf": {s},
        \\    "has_kes": {s},
        \\    "has_pool_id": {s},
        \\    "has_stake": {s}
        \\  }},
        \\  "tx_count": 0,
        \\  "body_size_bytes": {d}
        \\}}
    , .{
        report.slot,
        report.epoch,
        report.slot_in_epoch,
        report.state.label(),
        // leadership
        report.leadership.status.label(),
        if (report.leadership.is_leader) "true" else "false",
        report.leadership.u_x1e12,
        report.leadership.thresh_x1e12,
        report.leadership.reason,
        // kes
        report.kes.status.label(),
        report.kes.current_period,
        report.kes.start_period,
        report.kes.remaining_periods,
        report.kes.max_periods,
        if (report.kes.expired) "true" else "false",
        // sign_verify
        report.sign_verify.status.label(),
        if (report.sign_verify.sign_ok) "true" else "false",
        if (report.sign_verify.verify_ok) "true" else "false",
        kes_verify.resultStr(report.sign_verify.verify_detail),
        // candidate
        report.candidate.status.label(),
        @as([]const u8, &header_hash_hex),
        @as([]const u8, &body_hash_hex),
        report.candidate.header_bytes_len,
        report.candidate.body_bytes_len,
        // availability
        if (has_vrf) "true" else "false",
        if (has_kes) "true" else "false",
        if (has_pool_id) "true" else "false",
        if (has_stake) "true" else "false",
        // body
        body_size_bytes,
    }) catch {
        std.debug.print("ERROR: report buffer overflow\n", .{});
        return 4;
    };

    // ── Output ───────────────────────────────────────────────────────
    std.debug.print("{s}\n", .{json});

    if (out_path) |opath| {
        var f = compat.fs.cwd().createFile(opath, .{}) catch {
            std.debug.print("ERROR: cannot create {s}\n", .{opath});
            return 4;
        };
        defer f.close();
        f.writeAll(json) catch {
            std.debug.print("ERROR: cannot write {s}\n", .{opath});
            return 4;
        };
        std.debug.print("report: {s}\n", .{opath});
    }

    // ── Bundle artifacts ──────────────────────────────────────────────
    if (bundle_dir) |bdir| {
        if (report.state == .ready) {
            if (kes_key_state) |ks| {
                if (readiness.buildArtifactBundle(
                    target_slot, epoch, slot_in_epoch,
                    vrf_output, ks, kes_pk,
                    opcert_start, net_magic, tip_block,
                    tip_hash, state_digest, pool_id,
                )) |bundle| {
                    compat.fs.cwd().makePath(bdir) catch {
                        std.debug.print("ERROR: cannot create bundle dir: {s}\n", .{bdir});
                        return 4;
                    };
                    if (writeBundleFiles(bdir, json, &bundle)) {
                        std.debug.print("bundle: {s} (5 files)\n", .{bdir});
                    } else {
                        std.debug.print("ERROR: bundle write failed\n", .{});
                        return 4;
                    }
                } else {
                    std.debug.print("WARN: artifact bundle build failed (KES sign error)\n", .{});
                }
            }
        }
    }

    // ── Exit code ────────────────────────────────────────────────────
    return switch (report.state) {
        .ready => 0,
        .not_leader => 1,
        .not_ready => 2,
    };
}

// ── Helpers ──────────────────────────────────────────────────────────

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn usageErr(msg: []const u8) u8 {
    std.debug.print("ERROR: {s}\n", .{msg});
    return 3;
}

fn parseNextU64(args_it: anytype) ?u64 {
    const val_str = args_it.next() orelse return null;
    return std.fmt.parseUnsigned(u64, val_str, 10) catch null;
}

fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    var f = compat.fs.cwd().openFile(path, .{ .mode = .read_only }) catch return null;
    defer f.close();
    return f.readToEndAlloc(alloc, 16384) catch null;
}

/// Parse VRF seed from cardano-cli JSON key envelope.
/// Handles both 5820 (32-byte seed) and 5840 (64-byte expanded key, first 32 = seed).
fn parseVrfSeed(content: []const u8) ?[32]u8 {
    const kf = kes_keyfile.readKeyJson(content) orelse return null;
    var decoded: [256]u8 = undefined;
    const decoded_len = kes_keyfile.decodeCborHex(kf.cbor_hex, &decoded) orelse return null;

    if (decoded_len == 32) {
        // Direct seed
        var seed: [32]u8 = undefined;
        @memcpy(&seed, decoded[0..32]);
        return seed;
    } else if (decoded_len >= 64) {
        // Expanded VRF key: first 32 bytes are seed
        var seed: [32]u8 = undefined;
        @memcpy(&seed, decoded[0..32]);
        return seed;
    }

    return null;
}

fn writeBundleFiles(bdir: []const u8, report_json: []const u8, bundle: *const readiness.ArtifactBundle) bool {
    // 1. producer-report.json
    writeFileInDir(bdir, "producer-report.json", report_json) catch return false;

    // 2. candidate-header.cbor
    writeFileInDir(bdir, "candidate-header.cbor", bundle.header_cbor[0..bundle.header_cbor_len]) catch return false;

    // 3. candidate-body.cbor (4 body parts concatenated)
    {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/candidate-body.cbor", .{bdir}) catch return false;
        var f = compat.fs.cwd().createFile(path, .{}) catch return false;
        defer f.close();
        f.writeAll(bundle.body_tx_bodies) catch return false;
        f.writeAll(bundle.body_witnesses) catch return false;
        f.writeAll(bundle.body_aux_data) catch return false;
        f.writeAll(bundle.body_invalid_txs) catch return false;
    }

    // 4. candidate-block.cbor
    writeFileInDir(bdir, "candidate-block.cbor", bundle.block_cbor[0..bundle.block_cbor_len]) catch return false;

    // 5. candidate-hashes.json
    const block_hash_hex = std.fmt.bytesToHex(bundle.block_hash, .lower);
    const body_hash_hex = std.fmt.bytesToHex(bundle.body_hash, .lower);
    const cand_hdr_hex = std.fmt.bytesToHex(bundle.candidate_header_hash, .lower);
    const cand_body_hex = std.fmt.bytesToHex(bundle.candidate_body_hash, .lower);

    var hbuf: [1024]u8 = undefined;
    const hashes = std.fmt.bufPrint(&hbuf,
        \\{{
        \\  "block_hash": "{s}",
        \\  "body_hash": "{s}",
        \\  "candidate_header_hash": "{s}",
        \\  "candidate_body_hash": "{s}"
        \\}}
    , .{
        @as([]const u8, &block_hash_hex),
        @as([]const u8, &body_hash_hex),
        @as([]const u8, &cand_hdr_hex),
        @as([]const u8, &cand_body_hex),
    }) catch return false;
    writeFileInDir(bdir, "candidate-hashes.json", hashes) catch return false;

    return true;
}

fn writeFileInDir(dir_path: []const u8, filename: []const u8, data: []const u8) !void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, filename }) catch return error.NoSpaceLeft;
    var f = try compat.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(data);
}
