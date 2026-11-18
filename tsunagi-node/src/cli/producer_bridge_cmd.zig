const std = @import("std");
const compat = @import("compat");
const bridge = @import("../net/consensus/producer_bridge.zig");
const readiness = @import("../net/consensus/producer_readiness.zig");
const cursor_store = @import("../net/ledger/cursor.zig");
const genesis = @import("../producer/genesis.zig");
const leader_model = @import("../producer/leader_model.zig");
const sodium_vrf = @import("../producer/crypto/sodium_vrf.zig");
const kes_sign = @import("../producer/crypto/kes_sign.zig");
const kes_verify = @import("../producer/crypto/kes_verify.zig");
const kes_keyfile = @import("../producer/kes_keyfile.zig");

/// Producer integration bridge — uses real node state and config.
///
/// Reads runtime state from:
///   - cursor.json (live tip slot/block/hash, written by node)
///   - genesis config (TSUNAGI_HOME/genesis/<net>/shelley-genesis.json)
///   - ENV vars (same as node runtime: TSUNAGI_VRF_SKEY_PATH, etc.)
///
/// Evaluates producer readiness using the existing standalone module.
/// Outputs a local JSON report. Optionally writes artifact bundle.
///
/// SAFETY: No broadcast. No network IO. No peer send. No mempool mutation.
/// Reads cursor.json read-only. Does not modify node state.
///
/// Usage:
///   tsunagi-node producer-bridge [options]
///
/// Options:
///   --state-dir <path>        State directory (default: $TSUNAGI_HOME)
///   --net <name>              Network: mainnet|preprod|preview|sancho (default: preview)
///   --slot <N>                Override slot (default: from cursor.json)
///   --bundle-dir <path>       Write artifact bundle when READY
///   --out <path>              Write JSON report to file
///
/// Exit codes: 0=READY, 1=NOT_LEADER, 2=NOT_CONFIGURED, 3=usage, 4=IO, 5=ERROR

pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    // ── Parse arguments ──────────────────────────────────────────────
    var state_dir_arg: ?[]const u8 = null;
    var net_name: []const u8 = "preview";
    var slot_override: ?u64 = null;
    var bundle_dir: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (eql(arg, "--state-dir")) {
            state_dir_arg = args_it.next() orelse return usageErr("--state-dir requires a path");
        } else if (eql(arg, "--net")) {
            net_name = args_it.next() orelse return usageErr("--net requires mainnet|preprod|preview|sancho");
        } else if (eql(arg, "--slot")) {
            slot_override = parseNextU64(args_it) orelse return usageErr("--slot requires a number");
        } else if (eql(arg, "--bundle-dir")) {
            bundle_dir = args_it.next() orelse return usageErr("--bundle-dir requires a path");
        } else if (eql(arg, "--out")) {
            out_path = args_it.next() orelse return usageErr("--out requires a path");
        }
    }

    const is_mainnet = eql(net_name, "mainnet");

    // ── Resolve state directory ──────────────────────────────────────
    const state_dir = state_dir_arg orelse blk: {
        const env_home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
        if (env_home) |h| break :blk h;
        std.debug.print("ERROR: --state-dir required (or set TSUNAGI_HOME)\n", .{});
        return 4;
    };
    defer if (state_dir_arg == null) alloc.free(state_dir);

    // ── Read cursor.json ─────────────────────────────────────────────
    const cursor_path = std.fs.path.join(alloc, &[_][]const u8{ state_dir, "cursor.json" }) catch {
        std.debug.print("ERROR: path join failed\n", .{});
        return 4;
    };
    defer alloc.free(cursor_path);

    const cursor = cursor_store.loadOrInit(alloc, cursor_path) catch {
        std.debug.print("ERROR: cannot read cursor: {s}\n", .{cursor_path});
        return 4;
    };

    const tip_slot = slot_override orelse cursor.slot;
    const tip_block = cursor.block_no;

    // Convert cursor tip_hash_hex (64 ASCII hex chars) to [32]u8
    var tip_hash: [32]u8 = [_]u8{0} ** 32;
    _ = std.fmt.hexToBytes(&tip_hash, &cursor.tip_hash_hex) catch {};

    if (tip_slot == 0 and slot_override == null) {
        std.debug.print("WARN: cursor slot is 0 (node may not have synced yet)\n", .{});
    }

    // ── Load genesis ─────────────────────────────────────────────────
    const genesis_dir_name = genesisDir(net_name);
    var gen_cfg = genesis.GenesisConfig{
        .genesis_unix = 0,
        .slot_length_s = 1,
        .network_magic = 0,
        .parsed_ok = false,
        .path_ok = false,
        .last_error_code = genesis.ERR_PATH_MISSING,
    };

    if (genesis.resolveGenesisPath(alloc, genesis_dir_name)) |gpath| {
        defer alloc.free(gpath);
        gen_cfg = genesis.loadGenesis(alloc, gpath);
        if (gen_cfg.parsed_ok) {
            std.debug.print("genesis: ok start_unix={d} slot_len={d}s magic={d}\n", .{
                gen_cfg.genesis_unix, gen_cfg.slot_length_s, gen_cfg.network_magic,
            });
        } else {
            std.debug.print("WARN: genesis parse failed (error={d})\n", .{gen_cfg.last_error_code});
        }
    } else {
        std.debug.print("WARN: genesis not found for {s}\n", .{genesis_dir_name});
    }

    // ── Compute epoch / slot_in_epoch / KES period ───────────────────
    const epoch_info = bridge.computeEpochFromSlot(tip_slot, is_mainnet);
    const kes_period = bridge.computeKesPeriod(tip_slot);

    // ── Load stake config from ENV ───────────────────────────────────
    const stake_cfg = leader_model.loadStakeCfg(alloc);
    const has_stake = stake_cfg.stake_fraction_x1e9 > 0;

    // ── Load VRF key from ENV ────────────────────────────────────────
    var has_vrf = false;
    var vrf_output: [64]u8 = [_]u8{0} ** 64;

    const vrf_path_env = compat.getEnvVarOwned(alloc, "TSUNAGI_VRF_SKEY_PATH") catch null;
    if (vrf_path_env) |vpath| {
        defer alloc.free(vpath);
        if (readFileAlloc(alloc, vpath)) |content| {
            defer alloc.free(content);
            if (parseVrfSeed(content)) |seed| {
                if (sodium_vrf.sodiumInit()) {
                    if (sodium_vrf.keypairFromSeed(&seed)) |kp| {
                        // VRF input: epoch(u64 BE) || slot(u64 BE)
                        var msg: [16]u8 = undefined;
                        std.mem.writeInt(u64, msg[0..8], epoch_info.epoch, .big);
                        std.mem.writeInt(u64, msg[8..16], tip_slot, .big);
                        if (sodium_vrf.prove(&kp.sk, &msg)) |result| {
                            vrf_output = result.output;
                            has_vrf = true;
                        }
                    }
                }
            }
            if (!has_vrf) std.debug.print("WARN: VRF key load/prove failed: {s}\n", .{vpath});
        } else {
            std.debug.print("WARN: cannot read VRF key: {s}\n", .{vpath});
        }
    }

    // ── Load KES key from ENV ────────────────────────────────────────
    var has_kes = false;
    var kes_key_state_buf: [kes_sign.SK_FULL_SIZE_6 + 256]u8 = undefined;
    var kes_key_state: ?[]const u8 = null;
    var kes_pk: [32]u8 = [_]u8{0} ** 32;

    const kes_path_env = compat.getEnvVarOwned(alloc, "TSUNAGI_KES_SKEY_PATH") catch null;
    if (kes_path_env) |kpath| {
        defer alloc.free(kpath);
        if (readFileAlloc(alloc, kpath)) |content| {
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
                            }
                        },
                        .placeholder_seed => {
                            std.debug.print("WARN: KES key is placeholder seed\n", .{});
                        },
                        .unknown => {
                            std.debug.print("WARN: KES key type unknown\n", .{});
                        },
                    }
                }
            }
            if (!has_kes) std.debug.print("WARN: KES key load failed: {s}\n", .{kpath});
        } else {
            std.debug.print("WARN: cannot read KES key: {s}\n", .{kpath});
        }
    }

    // ── Load pool ID from ENV ────────────────────────────────────────
    var has_pool_id = false;
    var pool_id: [32]u8 = [_]u8{0} ** 32;

    const pool_id_env = compat.getEnvVarOwned(alloc, "TSUNAGI_POOL_ID_HEX") catch null;
    if (pool_id_env) |hex| {
        defer alloc.free(hex);
        if (hex.len == 64) {
            _ = std.fmt.hexToBytes(&pool_id, hex) catch {};
            has_pool_id = true;
        } else if (hex.len == 56) {
            // 56-char pool ID → pad to 32 bytes (28 bytes + 4 zeros)
            _ = std.fmt.hexToBytes(pool_id[0..28], hex) catch {};
            has_pool_id = true;
        }
    }

    // ── Load KES period params from ENV ──────────────────────────────
    var opcert_start: u32 = 0;
    var max_kes_evo: u32 = 62;

    const env_start = compat.getEnvVarOwned(alloc, "TSUNAGI_KES_START_PERIOD") catch null;
    if (env_start) |v| {
        defer alloc.free(v);
        opcert_start = @intCast(std.fmt.parseUnsigned(u64, v, 10) catch 0);
    }
    const env_max = compat.getEnvVarOwned(alloc, "TSUNAGI_KES_MAX_PERIODS") catch null;
    if (env_max) |v| {
        defer alloc.free(v);
        max_kes_evo = @intCast(std.fmt.parseUnsigned(u64, v, 10) catch 62);
    }

    // ── Build BridgeInputs ───────────────────────────────────────────
    const inputs = bridge.BridgeInputs{
        .slot = tip_slot,
        .epoch = epoch_info.epoch,
        .slot_in_epoch = epoch_info.slot_in_epoch,
        .tip_block_no = tip_block,
        .tip_hash32 = tip_hash,
        .has_vrf = has_vrf,
        .has_kes = has_kes,
        .has_pool_id = has_pool_id,
        .has_stake = has_stake,
        .stake_fraction_x1e9 = stake_cfg.stake_fraction_x1e9,
        .asc_x1e6 = stake_cfg.asc_x1e6,
        .current_kes_period = kes_period,
        .opcert_start_period = opcert_start,
        .max_kes_evolutions = max_kes_evo,
        .net_magic = @intCast(gen_cfg.network_magic),
    };

    // ── Evaluate ─────────────────────────────────────────────────────
    const result = bridge.evaluateFromInputs(
        inputs, vrf_output, kes_key_state, kes_pk, pool_id,
    );

    // ── Format JSON report ───────────────────────────────────────────
    const header_hash_hex = std.fmt.bytesToHex(result.header_hash, .lower);
    const body_hash_hex = std.fmt.bytesToHex(result.body_hash, .lower);
    const tip_hash_hex_str = std.fmt.bytesToHex(tip_hash, .lower);

    var buf: [4096]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{
        \\  "bridge_state": "{s}",
        \\  "slot": {d},
        \\  "epoch": {d},
        \\  "slot_in_epoch": {d},
        \\  "kes_period": {d},
        \\  "tip_block": {d},
        \\  "tip_hash": "{s}",
        \\  "leadership": {s},
        \\  "candidate_built": {s},
        \\  "header_hash": "{s}",
        \\  "body_hash": "{s}",
        \\  "tx_count": {d},
        \\  "header_size_bytes": {d},
        \\  "body_size_bytes": {d},
        \\  "source": {{
        \\    "cursor": "{s}",
        \\    "net": "{s}",
        \\    "genesis_ok": {s},
        \\    "has_vrf": {s},
        \\    "has_kes": {s},
        \\    "has_pool_id": {s},
        \\    "has_stake": {s},
        \\    "stake_x1e9": {d},
        \\    "asc_x1e6": {d}
        \\  }}
        \\}}
    , .{
        result.state.label(),
        result.slot,
        inputs.epoch,
        inputs.slot_in_epoch,
        kes_period,
        tip_block,
        @as([]const u8, &tip_hash_hex_str),
        if (result.leadership) "true" else "false",
        if (result.candidate_built) "true" else "false",
        @as([]const u8, &header_hash_hex),
        @as([]const u8, &body_hash_hex),
        result.tx_count,
        result.header_size_bytes,
        result.body_size_bytes,
        // source
        cursor_path,
        net_name,
        if (gen_cfg.parsed_ok) "true" else "false",
        if (has_vrf) "true" else "false",
        if (has_kes) "true" else "false",
        if (has_pool_id) "true" else "false",
        if (has_stake) "true" else "false",
        stake_cfg.stake_fraction_x1e9,
        stake_cfg.asc_x1e6,
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

    // ── Bundle artifacts (reuse existing readiness bundle path) ───────
    if (bundle_dir) |bdir| {
        if (result.state == .ready_local_candidate) {
            if (kes_key_state) |ks| {
                const state_digest = [_]u8{0} ** 32;
                if (readiness.buildArtifactBundle(
                    tip_slot, inputs.epoch, inputs.slot_in_epoch,
                    vrf_output, ks, kes_pk,
                    opcert_start, inputs.net_magic, tip_block,
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
                    std.debug.print("WARN: artifact bundle build failed\n", .{});
                }
            }
        }
    }

    // ── Exit code ────────────────────────────────────────────────────
    return switch (result.state) {
        .ready_local_candidate => 0,
        .not_leader => 1,
        .not_configured => 2,
        .idle => 2,
        .error_state => 5,
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

fn genesisDir(net_name: []const u8) []const u8 {
    if (eql(net_name, "mainnet")) return "mainnet";
    if (eql(net_name, "preprod")) return "preprod";
    if (eql(net_name, "sancho")) return "sancho";
    return "preview";
}

fn parseVrfSeed(content: []const u8) ?[32]u8 {
    const kf = kes_keyfile.readKeyJson(content) orelse return null;
    var decoded: [256]u8 = undefined;
    const decoded_len = kes_keyfile.decodeCborHex(kf.cbor_hex, &decoded) orelse return null;
    if (decoded_len == 32) {
        var seed: [32]u8 = undefined;
        @memcpy(&seed, decoded[0..32]);
        return seed;
    } else if (decoded_len >= 64) {
        var seed: [32]u8 = undefined;
        @memcpy(&seed, decoded[0..32]);
        return seed;
    }
    return null;
}

fn writeBundleFiles(bdir: []const u8, report_json: []const u8, bundle: *const readiness.ArtifactBundle) bool {
    writeFileInDir(bdir, "producer-report.json", report_json) catch return false;
    writeFileInDir(bdir, "candidate-header.cbor", bundle.header_cbor[0..bundle.header_cbor_len]) catch return false;
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
    writeFileInDir(bdir, "candidate-block.cbor", bundle.block_cbor[0..bundle.block_cbor_len]) catch return false;
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
