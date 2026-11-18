const std = @import("std");
const compat = @import("compat");
const block_candidate_verify_cmd = @import("block_candidate_verify_cmd.zig");
const block_candidate_regress_cmd = @import("block_candidate_regress_cmd.zig");
const i18n = @import("i18n.zig");
const lmdb_utxo = @import("../store/lmdb_utxo.zig");
const header_store_mod = @import("../store/header_store.zig");
const lmdb_c = lmdb_utxo.c;
const chainsync_server = @import("../protocols/chainsync_server.zig");
const fragment_coverage = @import("../archive/fragment_coverage.zig");
const tate = @import("../guardian/tate.zig");
const kura_stabilizer = @import("../guardian/kura_stabilizer.zig");

// ── Constants ────────────────────────────────────────────────────────
const DEFAULT_PORT: u16 = 9081;
const PREVIEW_TESTNET_MAGIC: []const u8 = "2";

// ── Main dispatch ────────────────────────────────────────────────────

pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    const subcmd = args_it.next() orelse {
        printUsage();
        return 1;
    };

    if (std.mem.eql(u8, subcmd, "tx-build")) return runTxBuild(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "tx-submit")) return runTxSubmit(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "tx-status")) return runTxStatus(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "kes-status")) return runKesStatus(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "proof-latest")) return runProofLatest(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "doctor")) return runDoctor(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "forge-status")) return runForgeStatus(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "seal-latest")) return runSealLatest(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "seal-tip")) return runSealTip(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "airgap-opcert")) return runAirgapOpcert(args_it);
    if (std.mem.eql(u8, subcmd, "version")) return runVersion(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "deploy-check")) return runDeployCheck(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "forge-arm")) return runForgeArm(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "yamori")) return runYamori(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "tate")) return runTate(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "kura")) return runKura(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "bcast-arm")) return runBcastArm(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "bcast-status")) return runBcastStatus(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "bcast-push")) return runBcastPush(alloc, args_it);

    std.debug.print("ERROR: unknown guardian subcommand: {s}\n", .{subcmd});
    printUsage();
    return 1;
}

fn printUsage() void {
    std.debug.print(
        \\Omotenashi Guardian — operator CLI
        \\
        \\Usage:
        \\  tsunagi-node guardian <subcommand> [options]
        \\
        \\Subcommands:
        \\  tx-build       Build a transaction via cardano-cli (preview-only)
        \\  tx-submit      Submit a signed transaction to the local node
        \\  tx-status      Query mempool for transaction status
        \\  kes-status     Display KES key period and validity info
        \\  proof-latest   Package latest block candidate proof bundle
        \\  doctor         Run diagnostic checks against the running node
        \\  forge-status   Pre-forging readiness dashboard (preview-first)
        \\  seal-latest    Verify + regress + seal latest block candidate for propagation
        \\  seal-tip       Export real chain tip header from follower for propagation (header-only)
        \\  airgap-opcert  Print opcert rotation ceremony instructions
        \\  version        Show running binary version (read-only)
        \\  deploy-check   Verify deploy readiness (read-only)
        \\  forge-arm      Arm forge gate (pre-flight + writes token, requires --i-know-what-im-doing)
        \\  yamori         YAMORI Shield (event memory + safe-mode)
        \\  tate           TATE Shield (fragment defense + propagation safety)
        \\  kura           KURA retention + safe pruning (disk hygiene)
        \\  bcast-arm      Arm broadcast gate (pre-flight + token, requires --i-know-what-im-doing)
        \\  bcast-status   Show broadcast gate status (read-only)
        \\  bcast-push     Validate forge artifacts + print relay transfer command
        \\
        \\Global options (for subcommands that query the node):
        \\  --port <N>     Node HTTP port (default: 9081; also infers net: 9080=mainnet 9081=preview 9082=sancho)
        \\  --home <path>  Tsunagi home directory (default: $TSUNAGI_HOME, or ~/tsunagi-home-<net>)
        \\  --net <name>   Network name (mainnet|preview|sancho) — used to resolve home if --home not given
        \\
        \\Example — seal + propagate (preview):
        \\  tsunagi-node guardian seal-latest --net preview
        \\  tsunagi-node propagate-serve --net preview --artifact-dir <printed path> --allowlist <ip> --port 3033
        \\
    , .{});
}

// ── tx-build ─────────────────────────────────────────────────────────

fn runTxBuild(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var out_path: ?[]const u8 = null;
    var from_addr: ?[]const u8 = null;
    var to_addr: ?[]const u8 = null;
    var ada_amount: ?[]const u8 = null;
    var cli_path: ?[]const u8 = null;
    var socket_path: ?[]const u8 = null;
    var force_mainnet = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--out")) {
            out_path = args_it.next() orelse {
                std.debug.print("ERROR: --out requires a path\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--from")) {
            from_addr = args_it.next() orelse {
                std.debug.print("ERROR: --from requires an address\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--to")) {
            to_addr = args_it.next() orelse {
                std.debug.print("ERROR: --to requires an address\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--ada")) {
            ada_amount = args_it.next() orelse {
                std.debug.print("ERROR: --ada requires an amount\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--cardano-cli")) {
            cli_path = args_it.next() orelse {
                std.debug.print("ERROR: --cardano-cli requires a path\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--socket-path")) {
            socket_path = args_it.next() orelse {
                std.debug.print("ERROR: --socket-path requires a path\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--i-know-what-im-doing")) {
            force_mainnet = true;
        } else {
            std.debug.print("ERROR: unknown tx-build flag: {s}\n", .{arg});
            return 1;
        }
    }

    const out = out_path orelse {
        std.debug.print("ERROR: --out <path> is required\n", .{});
        return 1;
    };
    const from = from_addr orelse {
        std.debug.print("ERROR: --from <addr> is required\n", .{});
        return 1;
    };
    const to = to_addr orelse {
        std.debug.print("ERROR: --to <addr> is required\n", .{});
        return 1;
    };
    const ada = ada_amount orelse {
        std.debug.print("ERROR: --ada <amount> is required\n", .{});
        return 1;
    };

    // Resolve cardano-cli
    const cli = cli_path orelse blk: {
        const env_cli = compat.getEnvVarOwned(alloc, "CARDANO_CLI") catch null;
        if (env_cli) |c| break :blk @as(?[]const u8, c);
        break :blk @as(?[]const u8, "cardano-cli");
    } orelse "cardano-cli";

    // Resolve socket path (required — no silent defaults)
    const sock = socket_path orelse blk: {
        const env_sock = compat.getEnvVarOwned(alloc, "CARDANO_NODE_SOCKET_PATH") catch null;
        if (env_sock) |s| break :blk @as(?[]const u8, s);
        break :blk @as(?[]const u8, null);
    };
    if (sock == null) {
        std.debug.print("ERROR: --socket-path or CARDANO_NODE_SOCKET_PATH required\n", .{});
        return 1;
    }

    // Enforce preview (--testnet-magic 2) unless --i-know-what-im-doing
    if (!force_mainnet) {
        std.debug.print("tx-build: using --testnet-magic {s} (preview)\n", .{PREVIEW_TESTNET_MAGIC});
    } else {
        std.debug.print("tx-build: WARNING — --i-know-what-im-doing enabled, mainnet guard disabled\n", .{});
    }

    // Compute lovelace from ADA string (multiply by 1_000_000)
    // For simplicity, pass ada value + "000000" as lovelace string for cardano-cli
    var lovelace_buf: [64]u8 = undefined;
    const lovelace = std.fmt.bufPrint(&lovelace_buf, "{s}000000", .{ada}) catch {
        std.debug.print("ERROR: ada amount too long\n", .{});
        return 1;
    };

    // Build cardano-cli args
    const tx_out_val = std.fmt.allocPrint(alloc, "{s}+{s}", .{ to, lovelace }) catch {
        std.debug.print("ERROR: alloc failed\n", .{});
        return 1;
    };
    defer alloc.free(tx_out_val);

    var argv = std.array_list.Managed([]const u8).init(alloc);
    defer argv.deinit();
    argv.appendSlice(&[_][]const u8{
        cli,
        "transaction",
        "build-raw",
        "--tx-in",
        from,
        "--tx-out",
        tx_out_val,
        "--fee",
        "0",
        "--testnet-magic",
        PREVIEW_TESTNET_MAGIC,
        "--out-file",
        out,
    }) catch {
        std.debug.print("ERROR: alloc failed\n", .{});
        return 1;
    };

    // Set CARDANO_NODE_SOCKET_PATH env for cardano-cli
    var env_map = compat.EnvMap.init(alloc);
    defer env_map.deinit();
    // Inherit existing env
    var sys_env = compat.getEnvMap(alloc) catch {
        std.debug.print("ERROR: cannot read environment\n", .{});
        return 1;
    };
    defer sys_env.deinit();
    var env_it = sys_env.iterator();
    while (env_it.next()) |entry| {
        env_map.put(entry.key_ptr.*, entry.value_ptr.*) catch {};
    }
    env_map.put("CARDANO_NODE_SOCKET_PATH", sock.?) catch {
        std.debug.print("ERROR: cannot set socket env\n", .{});
        return 1;
    };

    var child = compat.Child.init(argv.items, alloc);
    child.env_map = &env_map;
    const term = child.spawnAndWait() catch |err| {
        std.debug.print("ERROR: cardano-cli failed to execute: {}\n", .{err});
        return 1;
    };

    switch (term) {
        .exited => |code| {
            if (code == 0) {
                // Check output file size
                var f = compat.fs.cwd().openFile(out, .{}) catch {
                    std.debug.print("tx-build: cardano-cli exited 0 but output file not found: {s}\n", .{out});
                    return 1;
                };
                defer f.close();
                const stat = f.stat() catch {
                    std.debug.print("tx-build: cannot stat output file\n", .{});
                    return 1;
                };
                std.debug.print("tx-build OK: {s} ({d} bytes)\n", .{ out, stat.size });
                return 0;
            } else {
                std.debug.print("ERROR: cardano-cli exited with code {d}\n", .{code});
                return 1;
            }
        },
        else => {
            std.debug.print("ERROR: cardano-cli terminated abnormally\n", .{});
            return 1;
        },
    }
}

// ── tx-submit ────────────────────────────────────────────────────────

fn runTxSubmit(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var file_path: ?[]const u8 = null;
    var port: u16 = DEFAULT_PORT;
    var debug = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--file")) {
            file_path = args_it.next() orelse {
                std.debug.print("ERROR: --file requires a path\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--port")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --port requires a number\n", .{});
                return 1;
            };
            port = std.fmt.parseInt(u16, val, 10) catch {
                std.debug.print("ERROR: invalid port: {s}\n", .{val});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--debug")) {
            debug = true;
        } else {
            std.debug.print("ERROR: unknown tx-submit flag: {s}\n", .{arg});
            return 1;
        }
    }

    const fpath = file_path orelse {
        std.debug.print("ERROR: --file <path> is required\n", .{});
        return 1;
    };

    // Read file
    const file_data = readFileAlloc(alloc, fpath) orelse {
        std.debug.print("ERROR: cannot read file: {s}\n", .{fpath});
        return 1;
    };
    defer alloc.free(file_data);

    // Detect TextEnvelope JSON and extract CBOR
    var tx_bytes: []const u8 = undefined;
    var tx_bytes_owned = false;
    if (file_data.len > 0 and file_data[0] == '{') {
        // Try TextEnvelope extraction
        if (extractCborHex(file_data)) |hex_str| {
            const decoded = hexDecode(alloc, hex_str) orelse {
                std.debug.print("ERROR: invalid hex in cborHex field\n", .{});
                return 1;
            };
            tx_bytes = decoded;
            tx_bytes_owned = true;
        } else {
            std.debug.print("ERROR: file looks like JSON but no cborHex field found\n", .{});
            return 1;
        }
    } else {
        tx_bytes = file_data;
    }
    defer if (tx_bytes_owned) alloc.free(@constCast(tx_bytes));

    // Compute tx hash for display: blake2b256(tx_body)
    // tx_body = first CBOR element of the transaction array
    var txid_hex: [64]u8 = undefined;
    var has_txid = false;
    if (tx_bytes.len > 1) {
        // Try to extract tx_body and compute txid
        const block_hash = @import("../net/ledger/block_hash.zig");
        if (block_hash.computeCanonicalTxid(tx_bytes)) |txid| {
            txid_hex = std.fmt.bytesToHex(txid, .lower);
            has_txid = true;
        }
    }

    // POST to node
    const resp = httpPost(alloc, port, "/tx/submit", tx_bytes, "application/octet-stream") orelse {
        std.debug.print("ERROR: cannot connect to node at 127.0.0.1:{d}\n", .{port});
        return 1;
    };
    defer alloc.free(resp.body);

    // Bounded output
    if (has_txid) {
        std.debug.print("txid: {s}\n", .{&txid_hex});
    }
    std.debug.print("status: {d}\n", .{resp.status});
    std.debug.print("size: {d} bytes\n", .{tx_bytes.len});

    // Parse response body for result info
    if (resp.body.len > 0) {
        // Try to extract meaningful fields
        if (std.mem.indexOf(u8, resp.body, "accepted")) |_| {
            std.debug.print("result: accepted\n", .{});
        } else if (std.mem.indexOf(u8, resp.body, "rejected")) |_| {
            std.debug.print("result: rejected\n", .{});
        } else if (std.mem.indexOf(u8, resp.body, "duplicate")) |_| {
            std.debug.print("result: duplicate\n", .{});
        } else {
            std.debug.print("result: {s}\n", .{resp.body[0..@min(resp.body.len, 120)]});
        }
    }

    if (debug) {
        std.debug.print("\n--- full response ---\n{s}\n", .{resp.body});
    }

    if (resp.status >= 200 and resp.status < 300) return 0;
    return 1;
}

// ── tx-status ────────────────────────────────────────────────────────

fn runTxStatus(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var txid: ?[]const u8 = null;
    var port: u16 = DEFAULT_PORT;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--txid")) {
            txid = args_it.next() orelse {
                std.debug.print("ERROR: --txid requires a 64-char hex string\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--port")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --port requires a number\n", .{});
                return 1;
            };
            port = std.fmt.parseInt(u16, val, 10) catch {
                std.debug.print("ERROR: invalid port: {s}\n", .{val});
                return 1;
            };
        } else {
            std.debug.print("ERROR: unknown tx-status flag: {s}\n", .{arg});
            return 1;
        }
    }

    const resp = httpGet(alloc, port, "/mempool") orelse {
        std.debug.print("ERROR: cannot connect to node at 127.0.0.1:{d}\n", .{port});
        return 1;
    };
    defer alloc.free(resp.body);

    if (resp.status < 200 or resp.status >= 300) {
        std.debug.print("ERROR: /mempool returned HTTP {d}\n", .{resp.status});
        return 1;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch {
        std.debug.print("ERROR: cannot parse mempool response\n", .{});
        return 1;
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    const items = if (root.get("items")) |v| jsonInt(v) else null;
    const bytes = if (root.get("bytes")) |v| jsonInt(v) else null;

    std.debug.print("mempool: {d} items, {d} bytes\n", .{
        items orelse 0,
        bytes orelse 0,
    });

    // Print top entries
    if (root.get("top")) |top_val| {
        if (top_val == .array) {
            for (top_val.array.items, 0..) |entry, i| {
                if (entry == .string) {
                    std.debug.print("  [{d}] {s}\n", .{ i, entry.string });
                }
            }
        }
    }

    // Check for specific txid
    if (txid) |expected| {
        var found = false;
        if (root.get("top")) |top_val| {
            if (top_val == .array) {
                for (top_val.array.items) |entry| {
                    if (entry == .string) {
                        if (std.mem.indexOf(u8, expected, entry.string) != null or
                            std.mem.indexOf(u8, entry.string, expected[0..@min(expected.len, entry.string.len)]) != null)
                        {
                            found = true;
                            break;
                        }
                    }
                }
            }
        }
        if (found) {
            std.debug.print("txid {s}: found in mempool\n", .{expected});
        } else {
            std.debug.print("txid {s}: not found in mempool\n", .{expected});
        }
    }

    return 0;
}

// ── kes-status ───────────────────────────────────────────────────────

fn runKesStatus(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var port: u16 = DEFAULT_PORT;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --port requires a number\n", .{});
                return 1;
            };
            port = std.fmt.parseInt(u16, val, 10) catch {
                std.debug.print("ERROR: invalid port: {s}\n", .{val});
                return 1;
            };
        } else {
            std.debug.print("ERROR: unknown kes-status flag: {s}\n", .{arg});
            return 1;
        }
    }

    const resp = httpGet(alloc, port, "/state") orelse {
        std.debug.print("ERROR: cannot connect to node at 127.0.0.1:{d}\n", .{port});
        return 1;
    };
    defer alloc.free(resp.body);

    if (resp.status < 200 or resp.status >= 300) {
        std.debug.print("ERROR: /state returned HTTP {d}\n", .{resp.status});
        return 1;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch {
        std.debug.print("ERROR: cannot parse /state response\n", .{});
        return 1;
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    std.debug.print("=== KES Status ===\n", .{});

    // producer_kes_period
    if (root.get("producer_kes_period")) |kp_val| {
        if (kp_val == .object) {
            const kp = kp_val.object;
            const cur = if (kp.get("current_period")) |v| jsonInt(v) else null;
            const start = if (kp.get("start_period")) |v| jsonInt(v) else null;
            const max = if (kp.get("max_periods")) |v| jsonInt(v) else null;
            const valid = if (kp.get("period_valid_last")) |v| jsonInt(v) else null;
            const rc = if (kp.get("period_reason_code_last")) |v| jsonInt(v) else null;
            const start_slot = if (kp.get("period_start_slot")) |v| jsonInt(v) else null;
            const end_slot = if (kp.get("period_end_slot")) |v| jsonInt(v) else null;
            const rollovers = if (kp.get("rollovers_total")) |v| jsonInt(v) else null;
            const oor = if (kp.get("out_of_range_total")) |v| jsonInt(v) else null;
            const refused = if (kp.get("sign_refused_total")) |v| jsonInt(v) else null;

            std.debug.print("  current_period:    {d}\n", .{cur orelse 0});
            std.debug.print("  start_period:      {d}\n", .{start orelse 0});
            std.debug.print("  max_periods:       {d}\n", .{max orelse 0});
            if (cur != null and start != null and max != null) {
                const remaining = (start.? + max.?) -| (cur.? + 1);
                std.debug.print("  remaining_periods: {d}\n", .{remaining});
            }
            std.debug.print("  period_valid:      {s}\n", .{if (valid != null and valid.? == 1) "YES" else "NO"});
            std.debug.print("  reason_code:       {d}\n", .{rc orelse 0});
            std.debug.print("  period_start_slot: {d}\n", .{start_slot orelse 0});
            std.debug.print("  period_end_slot:   {d}\n", .{end_slot orelse 0});
            std.debug.print("  rollovers_total:   {d}\n", .{rollovers orelse 0});
            std.debug.print("  out_of_range:      {d}\n", .{oor orelse 0});
            std.debug.print("  sign_refused:      {d}\n", .{refused orelse 0});
        }
    } else {
        std.debug.print("  producer_kes_period: not available\n", .{});
    }

    // producer_kes
    if (root.get("producer_kes")) |kes_val| {
        if (kes_val == .object) {
            const kes = kes_val.object;
            const enabled = if (kes.get("enabled")) |v| jsonInt(v) else null;
            const signed = if (kes.get("signed_total")) |v| jsonInt(v) else null;
            const sig_present = if (kes.get("sig_present_last")) |v| jsonInt(v) else null;

            std.debug.print("\n  kes_enabled:       {s}\n", .{if (enabled != null and enabled.? == 1) "YES" else "NO"});
            std.debug.print("  signed_total:      {d}\n", .{signed orelse 0});
            std.debug.print("  sig_present_last:  {d}\n", .{sig_present orelse 0});
        }
    }

    return 0;
}

// ── proof-latest ─────────────────────────────────────────────────────

fn runProofLatest(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var home_path: ?[]const u8 = null;
    var verify = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--home")) {
            home_path = args_it.next() orelse {
                std.debug.print("ERROR: --home requires a path\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--verify")) {
            verify = true;
        } else {
            std.debug.print("ERROR: unknown proof-latest flag: {s}\n", .{arg});
            return 1;
        }
    }

    // Resolve home
    const home = home_path orelse blk: {
        const env_home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
        if (env_home) |h| break :blk @as(?[]const u8, h);
        break :blk @as(?[]const u8, null);
    };
    if (home == null) {
        std.debug.print("ERROR: --home or TSUNAGI_HOME required\n", .{});
        return 1;
    }

    // Locate the proof bundle script.
    // Try: (1) relative to executable: exe_dir/../../../../scripts/
    //      (2) relative to TSUNAGI_HOME: home/../src/tsunagi-follower/scripts/
    //      (3) fallback: $HOME/src/tsunagi-follower/scripts/
    const script_name = "make_block_candidate_proof_bundle.py";
    const script_path = findScript(alloc, script_name) orelse {
        std.debug.print("ERROR: cannot locate {s}\n", .{script_name});
        std.debug.print("  hint: ensure ~/src/tsunagi-follower/scripts/{s} exists\n", .{script_name});
        return 1;
    };
    defer alloc.free(script_path);

    const script_args = [_][]const u8{
        "python3",
        script_path,
        "--home",
        home.?,
    };

    var child = compat.Child.init(&script_args, alloc);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    const term = child.spawnAndWait() catch |err| {
        std.debug.print("ERROR: cannot run proof bundle script: {}\n", .{err});
        return 1;
    };

    const script_exit: u8 = switch (term) {
        .exited => |code| code,
        else => {
            std.debug.print("ERROR: proof bundle script terminated abnormally\n", .{});
            return 1;
        },
    };

    if (script_exit != 0) {
        std.debug.print("proof-latest: script exited with code {d}\n", .{script_exit});
        return script_exit;
    }

    // If --verify, find the latest block dir and run verify
    if (verify) {
        const blocks_dir_path = std.fmt.allocPrint(alloc, "{s}/producer_dryrun/blocks", .{home.?}) catch {
            std.debug.print("ERROR: alloc failed\n", .{});
            return 1;
        };
        defer alloc.free(blocks_dir_path);

        const latest_dir = findLatestBlockDir(alloc, blocks_dir_path) orelse {
            std.debug.print("proof-latest: no block candidate directories found for verification\n", .{});
            return 0;
        };
        defer alloc.free(latest_dir);

        std.debug.print("\n--- Verification ---\n", .{});
        var fake_args = FakeArgs{
            .items = &[_][]const u8{ "--dir", latest_dir },
        };
        const verify_exit = block_candidate_verify_cmd.run(alloc, &fake_args);
        if (verify_exit != 0) return verify_exit;
    }

    return 0;
}

// ── forge-status ─────────────────────────────────────────────────────

fn runForgeStatus(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var port: u16 = DEFAULT_PORT;
    var home_path: ?[]const u8 = null;
    var force = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --port requires a number\n", .{});
                return 1;
            };
            port = std.fmt.parseInt(u16, val, 10) catch {
                std.debug.print("ERROR: invalid port: {s}\n", .{val});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--home")) {
            home_path = args_it.next() orelse {
                std.debug.print("ERROR: --home requires a path\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--i-know-what-im-doing")) {
            force = true;
        } else {
            std.debug.print("ERROR: unknown forge-status flag: {s}\n", .{arg});
            return 1;
        }
    }

    // 1) Get /status for network info
    const status_resp = httpGet(alloc, port, "/status") orelse {
        std.debug.print("ERROR: cannot connect to node at 127.0.0.1:{d}\n", .{port});
        return 1;
    };
    defer alloc.free(status_resp.body);

    var net_str: []const u8 = "(unknown)";
    var status_slot: i64 = 0;
    var status_block: i64 = 0;
    var is_preview = false;

    if (status_resp.status >= 200 and status_resp.status < 300) {
        const sp = std.json.parseFromSlice(std.json.Value, alloc, status_resp.body, .{}) catch null;
        if (sp) |parsed| {
            defer parsed.deinit();
            const sroot = parsed.value.object;
            if (sroot.get("net")) |v| {
                if (v == .string) {
                    net_str = v.string;
                    is_preview = std.mem.eql(u8, v.string, "preview");
                }
            }
            if (sroot.get("slot")) |v| status_slot = jsonInt(v) orelse 0;
            if (sroot.get("block")) |v| status_block = jsonInt(v) orelse 0;

            // Preview-first refusal
            if (!is_preview and !force) {
                std.debug.print("REFUSED: forge-status is preview-first; pass --i-know-what-im-doing to view on non-preview\n", .{});
                return 1;
            }
        }
    }

    // 2) Get /state for detailed fields
    const state_resp = httpGet(alloc, port, "/state") orelse {
        std.debug.print("ERROR: cannot fetch /state\n", .{});
        return 1;
    };
    defer alloc.free(state_resp.body);

    var state_parsed_opt: ?std.json.Parsed(std.json.Value) = null;
    defer if (state_parsed_opt) |*p| p.deinit();

    if (state_resp.status >= 200 and state_resp.status < 300) {
        state_parsed_opt = std.json.parseFromSlice(std.json.Value, alloc, state_resp.body, .{}) catch null;
    }

    std.debug.print("=== Forge Status ===\n", .{});

    // Network
    std.debug.print("\n[Network]\n", .{});
    std.debug.print("  net:            {s}\n", .{net_str});
    std.debug.print("  slot:           {d}\n", .{status_slot});
    std.debug.print("  block:          {d}\n", .{status_block});

    if (state_parsed_opt) |state_parsed| {
        const root = state_parsed.value.object;

        // Header stable
        if (root.get("header")) |hdr| {
            if (hdr == .object) {
                const stable = if (hdr.object.get("stable")) |v| jsonInt(v) else null;
                std.debug.print("  header_stable:  {d}\n", .{stable orelse 0});
            }
        }

        // TXSUB
        std.debug.print("\n[TX Submission]\n", .{});
        if (root.get("txsub")) |txsub| {
            if (txsub == .object) {
                const enabled = if (txsub.object.get("enabled")) |v| jsonInt(v) else null;
                std.debug.print("  enabled:        {s}\n", .{if (enabled != null and enabled.? == 1) "YES" else "NO"});
            }
        }
        // Check env for broadcast flag
        {
            const bcast = compat.getEnvVarOwned(alloc, "TSUNAGI_TXSUB_BROADCAST") catch null;
            if (bcast) |val| {
                defer alloc.free(val);
                if (std.mem.eql(u8, val, "1")) {
                    std.debug.print("  broadcast:      WARNING — TSUNAGI_TXSUB_BROADCAST=1 is set!\n", .{});
                } else {
                    std.debug.print("  broadcast:      OFF\n", .{});
                }
            } else {
                std.debug.print("  broadcast:      OFF (env not set)\n", .{});
            }
        }

        // DRYRUN
        std.debug.print("\n[Dryrun]\n", .{});
        {
            const dr_enabled = getNestedInt(root, "producer_dryrun", "enabled");
            std.debug.print("  enabled:        {s}\n", .{if (dr_enabled != null and dr_enabled.? == 1) "YES" else "NO"});
            const dr_leaders = getNestedInt(root, "producer_dryrun", "leader_slots_total");
            std.debug.print("  leader_slots:   {d}\n", .{dr_leaders orelse 0});
            const dr_cand = getNestedInt(root, "producer_dryrun", "candidates_built_total");
            std.debug.print("  candidates:     {d}\n", .{dr_cand orelse 0});
        }

        // Stake fraction
        std.debug.print("\n[Stake]\n", .{});
        {
            const sf_env = compat.getEnvVarOwned(alloc, "TSUNAGI_STAKE_FRACTION_X1E9") catch null;
            if (sf_env) |val| {
                defer alloc.free(val);
                const sf_int = std.fmt.parseInt(u64, val, 10) catch 0;
                std.debug.print("  stake_fraction: {s} (x1e9)\n", .{val});
                if (sf_int > 300_000_000) {
                    std.debug.print("  WARNING: stake boost active (> 300M x1e9, proof mode)\n", .{});
                }
            } else {
                // Try from /state
                const sf = getNestedInt(root, "producer_leader", "stake_fraction_x1e9");
                if (sf) |v| {
                    std.debug.print("  stake_fraction: {d} (x1e9, from /state)\n", .{v});
                    if (v > 300_000_000) {
                        std.debug.print("  WARNING: stake boost active (> 300M x1e9, proof mode)\n", .{});
                    }
                } else {
                    std.debug.print("  stake_fraction: (unknown)\n", .{});
                }
            }
        }

        // KES status
        std.debug.print("\n[KES]\n", .{});
        if (root.get("producer_kes_period")) |kp_val| {
            if (kp_val == .object) {
                const kp = kp_val.object;
                const cur = if (kp.get("current_period")) |v| jsonInt(v) else null;
                const start = if (kp.get("start_period")) |v| jsonInt(v) else null;
                const max = if (kp.get("max_periods")) |v| jsonInt(v) else null;
                const valid = if (kp.get("period_valid_last")) |v| jsonInt(v) else null;

                std.debug.print("  current_period: {d}\n", .{cur orelse 0});
                std.debug.print("  start_period:   {d}\n", .{start orelse 0});
                std.debug.print("  max_periods:    {d}\n", .{max orelse 0});

                if (cur != null and start != null and max != null) {
                    const remaining: i64 = (start.? + max.?) - (cur.? + 1);
                    std.debug.print("  remaining:      {d}\n", .{remaining});
                    std.debug.print("  validity:       {s}\n", .{if (valid != null and valid.? == 1) "YES" else "NO"});

                    // Classification
                    if (max.? > 0 and remaining >= 0) {
                        const rem_u: u64 = @intCast(remaining);
                        const max_u: u64 = @intCast(max.?);
                        const pct: u64 = (rem_u * 100) / max_u;
                        if (pct <= 5) {
                            std.debug.print("  status:         CRITICAL (remaining <= 5%% of max)\n", .{});
                        } else if (pct <= 10) {
                            std.debug.print("  status:         WARNING (remaining <= 10%% of max)\n", .{});
                        } else {
                            std.debug.print("  status:         OK\n", .{});
                        }
                    }
                } else {
                    std.debug.print("  remaining:      (unknown)\n", .{});
                    std.debug.print("  validity:       (unknown)\n", .{});
                }
            }
        } else {
            std.debug.print("  (no KES period data available)\n", .{});
        }
    } else {
        std.debug.print("\n(cannot parse /state — remaining fields unavailable)\n", .{});
    }

    // Latest proof dir
    std.debug.print("\n[Latest Proof]\n", .{});
    {
        const home = home_path orelse blk: {
            const env_home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
            break :blk env_home;
        };
        if (home) |h| {
            const blocks_path = std.fmt.allocPrint(alloc, "{s}/producer_dryrun/blocks", .{h}) catch null;
            if (blocks_path) |bp| {
                defer alloc.free(bp);
                if (findLatestBlockDir(alloc, bp)) |latest| {
                    defer alloc.free(latest);
                    std.debug.print("  dir:            {s}\n", .{latest});
                    // Read included_tx_count.txt if present
                    const tc_path = std.fmt.allocPrint(alloc, "{s}/included_tx_count.txt", .{latest}) catch null;
                    if (tc_path) |tcp| {
                        defer alloc.free(tcp);
                        if (readFileAlloc(alloc, tcp)) |tc_data| {
                            defer alloc.free(tc_data);
                            const trimmed = std.mem.trimEnd(u8, tc_data, "\n\r ");
                            std.debug.print("  tx_count:       {s}\n", .{trimmed});
                        } else {
                            std.debug.print("  tx_count:       (not available)\n", .{});
                        }
                    }
                } else {
                    std.debug.print("  (no block candidate directories)\n", .{});
                }
            }
            if (home_path == null) alloc.free(h);
        } else {
            std.debug.print("  (unknown — --home or TSUNAGI_HOME not set)\n", .{});
        }
    }

    return 0;
}

// ── seal-latest ──────────────────────────────────────────────────────

// ── seal-tip: Export real chain tip header for propagation ──────────
//
// Copies $TSUNAGI_HOME/chain_tip/ (written by follower on each RollForward)
// to $TSUNAGI_HOME/propagation_artifact/ for use by propagate-serve.
// Header-only mode — no block.cbor (BlockFetch will be skipped by relay).
// The header has correct blockNo because it's a real chain header.

fn runSealTip(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var home_path: ?[]const u8 = null;
    var net_name: ?[]const u8 = null;
    var port_num: ?u16 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--home")) {
            home_path = args_it.next() orelse {
                std.debug.print("ERROR: --home requires a path\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--net")) {
            net_name = args_it.next() orelse {
                std.debug.print("ERROR: --net requires a value\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--port")) {
            const pval = args_it.next() orelse {
                std.debug.print("ERROR: --port requires a number\n", .{});
                return 1;
            };
            port_num = std.fmt.parseInt(u16, pval, 10) catch {
                std.debug.print("ERROR: invalid --port: {s}\n", .{pval});
                return 1;
            };
        } else {
            std.debug.print("ERROR: unknown seal-tip flag: {s}\n", .{arg});
            return 1;
        }
    }

    // Resolve home (same fail-closed logic as seal-latest)
    var resolved_net: []const u8 = "(unknown)";
    const home = resolveSealHome(alloc, home_path, net_name, port_num, &resolved_net) orelse {
        std.debug.print("ERROR: cannot determine home directory.\n", .{});
        std.debug.print("  Pass --home <path>, or --net <name>, or set $TSUNAGI_HOME.\n", .{});
        return 1;
    };

    // Verify chain_tip directory exists (follower must have written it)
    const src_dir = std.fmt.allocPrint(alloc, "{s}/chain_tip", .{home}) catch return 1;
    defer alloc.free(src_dir);
    {
        compat.fs.cwd().access(src_dir, .{}) catch {
            std.debug.print("ERROR: chain_tip directory not found: {s}\n", .{src_dir});
            std.debug.print("  Ensure the follower is running with TSUNAGI_HOME set and has synced at least one header.\n", .{});
            return 1;
        };
    }

    // Verify header.cbor exists
    const hdr_path = std.fmt.allocPrint(alloc, "{s}/header.cbor", .{src_dir}) catch return 1;
    defer alloc.free(hdr_path);
    {
        compat.fs.cwd().access(hdr_path, .{}) catch {
            std.debug.print("ERROR: {s}/header.cbor not found\n", .{src_dir});
            return 1;
        };
    }

    // Read meta.json for display
    const meta_path = std.fmt.allocPrint(alloc, "{s}/meta.json", .{src_dir}) catch return 1;
    defer alloc.free(meta_path);
    const meta_bytes = readFileAlloc(alloc, meta_path) orelse {
        std.debug.print("ERROR: {s}/meta.json not found\n", .{src_dir});
        return 1;
    };
    defer alloc.free(meta_bytes);
    std.debug.print("seal-tip: chain_tip meta.json: {s}\n", .{meta_bytes});

    // Copy chain_tip files to propagation_artifact
    const dest_dir = std.fmt.allocPrint(alloc, "{s}/propagation_artifact", .{home}) catch return 1;
    defer alloc.free(dest_dir);

    compat.fs.cwd().makePath(dest_dir) catch |err| {
        std.debug.print("ERROR: cannot create {s}: {}\n", .{ dest_dir, err });
        return 1;
    };

    const tip_files = [_][]const u8{
        "header.cbor",
        "header_hash.hex",
        "meta.json",
        "block.cbor",
        "prev_header.cbor",
        "prev_header_hash.hex",
    };
    var copied: u32 = 0;
    var has_block = false;
    for (&tip_files) |name| {
        const sp = std.fmt.allocPrint(alloc, "{s}/{s}", .{ src_dir, name }) catch continue;
        defer alloc.free(sp);
        const dp = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dest_dir, name }) catch continue;
        defer alloc.free(dp);
        const data = readFileAlloc(alloc, sp) orelse continue;
        defer alloc.free(data);
        var f = compat.fs.cwd().createFile(dp, .{ .truncate = true }) catch continue;
        defer f.close();
        f.writeAll(data) catch continue;
        copied += 1;
        if (std.mem.eql(u8, name, "block.cbor")) has_block = true;

        // Also write under block_header* names so propagation_server reads fresh data
        const alias: ?[]const u8 = if (std.mem.eql(u8, name, "header.cbor"))
            "block_header.cbor"
        else if (std.mem.eql(u8, name, "header_hash.hex"))
            "block_header_hash.hex"
        else
            null;
        if (alias) |aname| {
            const ap = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dest_dir, aname }) catch continue;
            defer alloc.free(ap);
            var af = compat.fs.cwd().createFile(ap, .{ .truncate = true }) catch continue;
            defer af.close();
            af.writeAll(data) catch continue;
        }
    }

    // Copy fragment/ directory (rolling chain fragment for intersection matching)
    var frag_copied: u32 = 0;
    {
        const frag_src = std.fmt.allocPrint(alloc, "{s}/fragment", .{src_dir}) catch "";
        defer if (frag_src.len > 0) alloc.free(frag_src);
        const frag_dest = std.fmt.allocPrint(alloc, "{s}/fragment", .{dest_dir}) catch "";
        defer if (frag_dest.len > 0) alloc.free(frag_dest);

        if (frag_src.len > 0 and frag_dest.len > 0) {
            // Clear stale entries from destination before copying.
            // Without this, old entries from previous seal-tip runs persist
            // and cause ancestry BREAKs when mixed with new chain data.
            {
                var stale_cleared: u32 = 0;
                if (compat.fs.cwd().openDir(frag_dest, .{ .iterate = true })) |dd_val| {
                    var dd = dd_val;
                    // Collect then delete (can't delete during iteration)
                    var stale_names: [8192]u8 = undefined;
                    var stale_offsets: [512]u16 = undefined;
                    var stale_lens: [512]u8 = undefined;
                    var sn_count: u16 = 0;
                    var sn_pos: u16 = 0;
                    {
                        var sit = dd.iterate();
                        while (sit.next() catch null) |se| {
                            if (se.kind != .file) continue;
                            if (sn_count < stale_offsets.len and sn_pos + se.name.len <= stale_names.len) {
                                @memcpy(stale_names[sn_pos .. sn_pos + se.name.len], se.name);
                                stale_offsets[sn_count] = sn_pos;
                                stale_lens[sn_count] = @intCast(se.name.len);
                                sn_pos += @intCast(se.name.len);
                                sn_count += 1;
                            }
                        }
                    }
                    dd.close();
                    var sd: u16 = 0;
                    while (sd < sn_count) : (sd += 1) {
                        const soff = stale_offsets[sd];
                        const slen = stale_lens[sd];
                        const sname = stale_names[soff .. soff + slen];
                        const sdp = std.fmt.allocPrint(alloc, "{s}/{s}", .{ frag_dest, sname }) catch continue;
                        defer alloc.free(sdp);
                        compat.fs.cwd().deleteFile(sdp) catch {};
                        stale_cleared += 1;
                    }
                } else |_| {}
                if (stale_cleared > 0) {
                    std.debug.print("seal-tip: cleared {d} stale fragment entries from destination\n", .{stale_cleared});
                }
            }
            compat.fs.cwd().makePath(frag_dest) catch {};

            // Phase 1: Collect live fragment source entries
            var live_seqs: [2560]u32 = undefined;
            var live_count: u32 = 0;
            {
                if (compat.fs.cwd().openDir(frag_src, .{ .iterate = true })) |d_val| {
                    var d = d_val;
                    defer d.close();
                    var sit = d.iterate();
                    while (sit.next() catch null) |entry| {
                        if (entry.kind != .file) continue;
                        if (!std.mem.endsWith(u8, entry.name, ".header.cbor")) continue;
                        if (entry.name.len < 20) continue;
                        const seq = std.fmt.parseUnsigned(u32, entry.name[0..8], 10) catch continue;
                        if (live_count < live_seqs.len) {
                            live_seqs[live_count] = seq;
                            live_count += 1;
                        }
                    }
                } else |_| {}
            }
            if (live_count > 1) {
                std.mem.sort(u32, live_seqs[0..live_count], {}, std.sort.asc(u32));
            }

            // Read oldest entry's hash for LMDB lookup
            var oldest_hash: [32]u8 = undefined;
            var has_oldest_hash = false;
            if (live_count > 0) {
                var hash_path_buf: [512]u8 = undefined;
                const hash_path = std.fmt.bufPrint(&hash_path_buf, "{s}/{d:0>8}.hash.hex", .{ frag_src, live_seqs[0] }) catch "";
                if (hash_path.len > 0) {
                    if (readFileAlloc(alloc, hash_path)) |hash_hex_raw| {
                        defer alloc.free(hash_hex_raw);
                        const trimmed = std.mem.trim(u8, hash_hex_raw, " \t\r\n");
                        if (trimmed.len >= 64) {
                            var valid = true;
                            for (0..32) |bi| {
                                oldest_hash[bi] = std.fmt.parseInt(u8, trimmed[bi * 2 .. bi * 2 + 2], 16) catch {
                                    valid = false;
                                    break;
                                };
                            }
                            has_oldest_hash = valid;
                        }
                    }
                }
            }

            // Phase 2+3: Ancestor seeding or raw copy
            const AncestorEntry = struct {
                hash: [32]u8,
                slot: u64,
                block_no: u64,
            };
            var ancestor_buf: [2160]AncestorEntry = undefined;
            var ancestor_count: u32 = 0;
            var did_ancestor_seeding = false;

            ancestor_seeding: {
                if (!has_oldest_hash or live_count == 0) break :ancestor_seeding;

                const lmdb_path_raw = compat.getEnvVarOwned(alloc, "TSUNAGI_LMDB") catch {
                    std.debug.print("seal-tip: TSUNAGI_LMDB not set, skipping ancestor seeding\n", .{});
                    break :ancestor_seeding;
                };
                defer alloc.free(lmdb_path_raw);
                const lmdb_path_trimmed = std.mem.trim(u8, lmdb_path_raw, " \t\r\n");
                if (lmdb_path_trimmed.len == 0) {
                    std.debug.print("seal-tip: TSUNAGI_LMDB not set, skipping ancestor seeding\n", .{});
                    break :ancestor_seeding;
                }
                const lmdb_path_z = alloc.dupeZ(u8, lmdb_path_trimmed) catch break :ancestor_seeding;
                defer alloc.free(lmdb_path_z);

                // Open LMDB read-only (safe alongside running follower)
                var lmdb_env: ?*lmdb_c.MDB_env = null;
                if (lmdb_c.mdb_env_create(&lmdb_env) != 0) {
                    std.debug.print("seal-tip: LMDB env create failed, skipping ancestor seeding\n", .{});
                    break :ancestor_seeding;
                }
                defer lmdb_c.mdb_env_close(lmdb_env);
                _ = lmdb_c.mdb_env_set_maxdbs(lmdb_env, 4);
                _ = lmdb_c.mdb_env_set_mapsize(lmdb_env, @as(usize, 256) * 1024 * 1024 * 1024);
                if (lmdb_c.mdb_env_open(lmdb_env, lmdb_path_z.ptr, lmdb_c.MDB_RDONLY | lmdb_c.MDB_NORDAHEAD, 0o644) != 0) {
                    std.debug.print("seal-tip: LMDB open failed at {s}, skipping ancestor seeding\n", .{lmdb_path_trimmed});
                    break :ancestor_seeding;
                }

                var hs = header_store_mod.HeaderStore.openReadOnly(lmdb_env) catch {
                    std.debug.print("seal-tip: HeaderStore open failed, skipping ancestor seeding\n", .{});
                    break :ancestor_seeding;
                };
                if (!hs.has_cbor_db) {
                    std.debug.print("seal-tip: header_cbor db not found (pre-v4.5.28 LMDB), skipping ancestor seeding\n", .{});
                    break :ancestor_seeding;
                }

                var rtxn = hs.beginRead() orelse {
                    std.debug.print("seal-tip: LMDB read txn failed, skipping ancestor seeding\n", .{});
                    break :ancestor_seeding;
                };
                defer hs.abort(&rtxn);

                // Look up oldest_hash to get prev_hash as walk start
                var walk_hash: [32]u8 = undefined;
                if (hs.getHeader(&rtxn, oldest_hash)) |rec| {
                    walk_hash = rec.prev_hash;
                } else {
                    std.debug.print("seal-tip: oldest fragment hash not in header store, skipping ancestor seeding\n", .{});
                    break :ancestor_seeding;
                }

                // Walk backwards, collecting ancestors that have CBOR
                const max_ancestors: u32 = if (live_count >= 2160) 0 else 2160 - live_count;
                var walked: u32 = 0;
                const zero_hash = std.mem.zeroes([32]u8);
                while (ancestor_count < max_ancestors) {
                    if (std.mem.eql(u8, &walk_hash, &zero_hash)) break;
                    const wrec = hs.getHeader(&rtxn, walk_hash) orelse break;
                    if (hs.getHeaderCbor(&rtxn, walk_hash) == null) break;
                    ancestor_buf[ancestor_count] = .{
                        .hash = walk_hash,
                        .slot = wrec.slot,
                        .block_no = wrec.block_no,
                    };
                    ancestor_count += 1;
                    walked += 1;
                    walk_hash = wrec.prev_hash;
                }

                std.debug.print("seal-tip: ancestor seeding: walked={d} ancestor_count={d}\n", .{ walked, ancestor_count });

                if (ancestor_count == 0) {
                    std.debug.print("seal-tip: 0 CBOR-covered ancestors found, raw copy (no renumbering)\n", .{});
                    break :ancestor_seeding;
                }

                // Write ancestors to destination (deepest ancestor at seq 0)
                // ancestor_buf[0] = nearest to oldest_hash, [ancestor_count-1] = deepest
                var oldest_anc_slot: u64 = 0;
                var newest_anc_slot: u64 = 0;
                for (0..ancestor_count) |i| {
                    const anc_idx = ancestor_count - 1 - @as(u32, @intCast(i));
                    const anc = ancestor_buf[anc_idx];
                    const seq: u32 = @intCast(i);
                    if (i == 0) oldest_anc_slot = anc.slot;
                    newest_anc_slot = anc.slot;

                    // .header.cbor
                    if (hs.getHeaderCbor(&rtxn, anc.hash)) |cbor| {
                        const fp = std.fmt.allocPrint(alloc, "{s}/{d:0>8}.header.cbor", .{ frag_dest, seq }) catch continue;
                        defer alloc.free(fp);
                        var f = compat.fs.cwd().createFile(fp, .{ .truncate = true }) catch continue;
                        defer f.close();
                        f.writeAll(cbor) catch continue;
                    }

                    // .hash.hex
                    {
                        const hex = std.fmt.bytesToHex(anc.hash, .lower);
                        const fp = std.fmt.allocPrint(alloc, "{s}/{d:0>8}.hash.hex", .{ frag_dest, seq }) catch continue;
                        defer alloc.free(fp);
                        var f = compat.fs.cwd().createFile(fp, .{ .truncate = true }) catch continue;
                        defer f.close();
                        f.writeAll(&hex) catch continue;
                    }

                    // .meta.json
                    {
                        const meta = std.fmt.allocPrint(alloc, "{{\"slot\":{d},\"block_no\":{d}}}", .{ anc.slot, anc.block_no }) catch continue;
                        defer alloc.free(meta);
                        const fp = std.fmt.allocPrint(alloc, "{s}/{d:0>8}.meta.json", .{ frag_dest, seq }) catch continue;
                        defer alloc.free(fp);
                        var f = compat.fs.cwd().createFile(fp, .{ .truncate = true }) catch continue;
                        defer f.close();
                        f.writeAll(meta) catch continue;
                    }

                    frag_copied += 1;
                }

                // Copy live entries with renumbered seq
                const frag_suffixes = [_][]const u8{ ".header.cbor", ".hash.hex", ".meta.json", ".body.cbor" };
                for (0..live_count) |i| {
                    const src_seq = live_seqs[i];
                    const dest_seq: u32 = ancestor_count + @as(u32, @intCast(i));
                    for (&frag_suffixes) |suffix| {
                        const sp = std.fmt.allocPrint(alloc, "{s}/{d:0>8}{s}", .{ frag_src, src_seq, suffix }) catch continue;
                        defer alloc.free(sp);
                        const dp = std.fmt.allocPrint(alloc, "{s}/{d:0>8}{s}", .{ frag_dest, dest_seq, suffix }) catch continue;
                        defer alloc.free(dp);
                        const data = readFileAlloc(alloc, sp) orelse continue;
                        defer alloc.free(data);
                        var ff = compat.fs.cwd().createFile(dp, .{ .truncate = true }) catch continue;
                        defer ff.close();
                        ff.writeAll(data) catch continue;
                    }
                    frag_copied += 1;
                }

                std.debug.print("seal-tip: fragment entries: ancestors={d} live={d} total={d}\n", .{ ancestor_count, live_count, ancestor_count + live_count });
                std.debug.print("seal-tip: ancestor slot range: oldest={d} newest={d}\n", .{ oldest_anc_slot, newest_anc_slot });
                did_ancestor_seeding = true;
            }

            // Raw copy fallback (exact v4.5.28 behavior when no ancestors)
            if (!did_ancestor_seeding) {
                // v4.5.30: Wipe destination fragment completely before raw copy.
                // The bounded stale clearing above (512 entries / 8192 bytes) is
                // insufficient when the live fragment has thousands of files.
                // Without this, stale low-seq entries from older generations
                // survive and cause ancestry BREAKs in propagation_server.
                compat.fs.cwd().deleteTree(frag_dest) catch {};
                compat.fs.cwd().makePath(frag_dest) catch {};

                if (compat.fs.cwd().openDir(frag_src, .{ .iterate = true })) |d_val| {
                    var d = d_val;
                    defer d.close();
                    var it = d.iterate();
                    while (it.next() catch null) |entry| {
                        if (entry.kind != .file) continue;
                        const fsp = std.fmt.allocPrint(alloc, "{s}/{s}", .{ frag_src, entry.name }) catch continue;
                        defer alloc.free(fsp);
                        const fdp = std.fmt.allocPrint(alloc, "{s}/{s}", .{ frag_dest, entry.name }) catch continue;
                        defer alloc.free(fdp);
                        const data = readFileAlloc(alloc, fsp) orelse continue;
                        defer alloc.free(data);
                        var ff = compat.fs.cwd().createFile(fdp, .{ .truncate = true }) catch continue;
                        defer ff.close();
                        ff.writeAll(data) catch continue;
                        frag_copied += 1;
                    }
                } else |_| {
                    std.debug.print("seal-tip: fragment/ directory not found (ok, optional)\n", .{});
                }
            }
        }
    }

    // ── Forge promotion: prefer forged sealed head when it extends fragment tail ──
    var forge_promoted = false;
    forge_promote: {
        // 1. Find fragment tail hash from dest fragment (highest seq .hash.hex)
        const frag_dest_path = std.fmt.allocPrint(alloc, "{s}/fragment", .{dest_dir}) catch break :forge_promote;
        defer alloc.free(frag_dest_path);

        var tail_seq: u32 = 0;
        var has_tail = false;
        {
            var fd = compat.fs.cwd().openDir(frag_dest_path, .{ .iterate = true }) catch break :forge_promote;
            defer fd.close();
            var fit = fd.iterate();
            while (fit.next() catch null) |fe| {
                if (fe.kind != .file) continue;
                if (!std.mem.endsWith(u8, fe.name, ".hash.hex")) continue;
                if (fe.name.len < 17) continue; // NNNNNNNN.hash.hex = 17
                const seq = std.fmt.parseUnsigned(u32, fe.name[0..8], 10) catch continue;
                if (!has_tail or seq > tail_seq) {
                    tail_seq = seq;
                    has_tail = true;
                }
            }
        }
        if (!has_tail) {
            std.debug.print("seal-tip: forge_promote: no fragment tail found, skipping\n", .{});
            break :forge_promote;
        }

        // Read fragment tail hash
        var tail_hash: [32]u8 = undefined;
        {
            var thp_buf: [512]u8 = undefined;
            const thp = std.fmt.bufPrint(&thp_buf, "{s}/{d:0>8}.hash.hex", .{ frag_dest_path, tail_seq }) catch break :forge_promote;
            const tail_hex_raw = readFileAlloc(alloc, thp) orelse {
                std.debug.print("seal-tip: forge_promote: cannot read fragment tail hash file\n", .{});
                break :forge_promote;
            };
            defer alloc.free(tail_hex_raw);
            const trimmed = std.mem.trim(u8, tail_hex_raw, " \t\r\n");
            if (trimmed.len < 64) break :forge_promote;
            var valid = true;
            for (0..32) |bi| {
                tail_hash[bi] = std.fmt.parseInt(u8, trimmed[bi * 2 .. bi * 2 + 2], 16) catch {
                    valid = false;
                    break;
                };
            }
            if (!valid) break :forge_promote;
        }

        // Read fragment tail slot from meta
        var tail_slot: u64 = 0;
        {
            var tmp_buf: [512]u8 = undefined;
            const tmp = std.fmt.bufPrint(&tmp_buf, "{s}/{d:0>8}.meta.json", .{ frag_dest_path, tail_seq }) catch break :forge_promote;
            const meta_raw = readFileAlloc(alloc, tmp) orelse break :forge_promote;
            defer alloc.free(meta_raw);
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, meta_raw, .{}) catch break :forge_promote;
            defer parsed.deinit();
            if (parsed.value == .object) {
                if (parsed.value.object.get("slot")) |v| {
                    if (jsonInt(v)) |s| tail_slot = @intCast(s);
                }
            }
        }
        std.debug.print("seal-tip: forge_promote: fragment tail seq={d} slot={d} hash={x}\n", .{
            tail_seq, tail_slot, tail_hash[0..8],
        });

        // 2. Check forged_head_pending/ snapshot first (survives chain_tip advancement)
        const snap_path = std.fmt.allocPrint(alloc, "{s}/forged_head_pending", .{home}) catch break :forge_promote;
        defer alloc.free(snap_path);

        // Try snapshot promotion
        snap_promote: {
            // Read parent.json from snapshot
            const parent_json_path = std.fmt.allocPrint(alloc, "{s}/parent.json", .{snap_path}) catch break :snap_promote;
            defer alloc.free(parent_json_path);
            const parent_json = readFileAlloc(alloc, parent_json_path) orelse break :snap_promote;
            defer alloc.free(parent_json);

            // Parse parent_hash and forge_slot from parent.json
            const pj = std.json.parseFromSlice(std.json.Value, alloc, parent_json, .{}) catch break :snap_promote;
            defer pj.deinit();
            if (pj.value != .object) break :snap_promote;
            const snap_forge_slot: u64 = if (pj.value.object.get("forge_slot")) |v| @intCast(jsonInt(v) orelse break :snap_promote) else break :snap_promote;
            const snap_parent_hash_str = if (pj.value.object.get("parent_hash")) |v| (if (v == .string) v.string else break :snap_promote) else break :snap_promote;
            if (snap_parent_hash_str.len < 64) break :snap_promote;

            // Parse parent_hash hex to bytes
            var snap_parent_hash: [32]u8 = undefined;
            for (0..32) |bi| {
                snap_parent_hash[bi] = std.fmt.parseInt(u8, snap_parent_hash_str[bi * 2 .. bi * 2 + 2], 16) catch break :snap_promote;
            }

            std.debug.print("seal-tip: forge_promote: snapshot forge_slot={d} parent_hash={x}\n", .{
                snap_forge_slot, snap_parent_hash[0..8],
            });

            // Validate: forge extends fragment tail
            if (snap_forge_slot <= tail_slot) {
                std.debug.print("seal-tip: forge_promote: SKIP snapshot forge_slot={d} <= tail slot={d}\n", .{ snap_forge_slot, tail_slot });
                break :snap_promote;
            }
            if (!std.mem.eql(u8, &snap_parent_hash, &tail_hash)) {
                std.debug.print("seal-tip: forge_promote: SKIP snapshot parent_hash mismatch\n", .{});
                break :snap_promote;
            }

            // Promote from snapshot
            const snap_files = [_]struct { src: []const u8, dst: []const u8 }{
                .{ .src = "block_header.cbor", .dst = "block_header.cbor" },
                .{ .src = "block_header.cbor", .dst = "header.cbor" },
                .{ .src = "block_header_hash.hex", .dst = "block_header_hash.hex" },
                .{ .src = "block_header_hash.hex", .dst = "header_hash.hex" },
                .{ .src = "block.cbor", .dst = "block.cbor" },
                .{ .src = "meta.json", .dst = "meta.json" },
            };
            var snap_copied: u32 = 0;
            for (&snap_files) |ff| {
                const fsp = std.fmt.allocPrint(alloc, "{s}/{s}", .{ snap_path, ff.src }) catch continue;
                defer alloc.free(fsp);
                const fdp = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dest_dir, ff.dst }) catch continue;
                defer alloc.free(fdp);
                const data = readFileAlloc(alloc, fsp) orelse continue;
                defer alloc.free(data);
                var file = compat.fs.cwd().createFile(fdp, .{ .truncate = true }) catch continue;
                defer file.close();
                file.writeAll(data) catch continue;
                snap_copied += 1;
            }
            if (snap_copied > 0) {
                forge_promoted = true;
                has_block = true;
                std.debug.print("seal-tip: FORGE PROMOTED slot={d} files={d} (from forged_head_pending snapshot)\n", .{
                    snap_forge_slot, snap_copied,
                });
                break :forge_promote; // done — skip fallback scan
            }
        }

        // 3. Fallback: scan producer_dryrun/blocks/ for latest forge candidate
        const blocks_path = std.fmt.allocPrint(alloc, "{s}/producer_dryrun/blocks", .{home}) catch break :forge_promote;
        defer alloc.free(blocks_path);
        const forge_dir = findLatestBlockDir(alloc, blocks_path) orelse {
            std.debug.print("seal-tip: forge_promote: no forge block candidates found\n", .{});
            break :forge_promote;
        };
        defer alloc.free(forge_dir);

        // Read forge block_header.cbor and parse prev_hash
        const forge_hdr_path = std.fmt.allocPrint(alloc, "{s}/block_header.cbor", .{forge_dir}) catch break :forge_promote;
        defer alloc.free(forge_hdr_path);
        const forge_hdr_data = readFileAlloc(alloc, forge_hdr_path) orelse {
            std.debug.print("seal-tip: forge_promote: no block_header.cbor in {s}\n", .{forge_dir});
            break :forge_promote;
        };
        defer alloc.free(forge_hdr_data);

        const forge_fields = chainsync_server.ChainSyncServer.parseHeaderFields(alloc, forge_hdr_data) orelse {
            std.debug.print("seal-tip: forge_promote: cannot parse forge header CBOR\n", .{});
            break :forge_promote;
        };
        const forge_prev_hash = forge_fields.prev_hash orelse {
            std.debug.print("seal-tip: forge_promote: forge header has no prev_hash\n", .{});
            break :forge_promote;
        };
        std.debug.print("seal-tip: forge_promote: forge slot={d} block_no={d} prev_hash={x}\n", .{
            forge_fields.slot, forge_fields.block_no, forge_prev_hash[0..8],
        });

        if (forge_fields.slot <= tail_slot) {
            std.debug.print("seal-tip: forge_promote: SKIP forge slot={d} <= tail slot={d}\n", .{ forge_fields.slot, tail_slot });
            break :forge_promote;
        }
        if (!std.mem.eql(u8, &forge_prev_hash, &tail_hash)) {
            std.debug.print("seal-tip: forge_promote: SKIP prev_hash mismatch (forge does not extend fragment tail)\n", .{});
            break :forge_promote;
        }

        // Promote from producer_dryrun/blocks/
        const forge_files = [_]struct { src: []const u8, dst: []const u8 }{
            .{ .src = "block_header.cbor", .dst = "block_header.cbor" },
            .{ .src = "block_header.cbor", .dst = "header.cbor" },
            .{ .src = "block_header_hash.hex", .dst = "block_header_hash.hex" },
            .{ .src = "block_header_hash.hex", .dst = "header_hash.hex" },
            .{ .src = "block.cbor", .dst = "block.cbor" },
            .{ .src = "meta.json", .dst = "meta.json" },
            .{ .src = "verify.json", .dst = "verify.json" },
            .{ .src = "signature.bin", .dst = "signature.bin" },
        };
        var forge_copied: u32 = 0;
        for (&forge_files) |ff| {
            const fsp = std.fmt.allocPrint(alloc, "{s}/{s}", .{ forge_dir, ff.src }) catch continue;
            defer alloc.free(fsp);
            const fdp = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dest_dir, ff.dst }) catch continue;
            defer alloc.free(fdp);
            const data = readFileAlloc(alloc, fsp) orelse continue;
            defer alloc.free(data);
            var file = compat.fs.cwd().createFile(fdp, .{ .truncate = true }) catch continue;
            defer file.close();
            file.writeAll(data) catch continue;
            forge_copied += 1;
        }
        if (forge_copied > 0) {
            forge_promoted = true;
            has_block = true;
            std.debug.print("seal-tip: FORGE PROMOTED slot={d} block_no={d} files={d} (extends fragment tail)\n", .{
                forge_fields.slot, forge_fields.block_no, forge_copied,
            });
        }
    }
    if (!forge_promoted) {
        std.debug.print("seal-tip: sealed head = chain_tip (no valid forge extends fragment tail)\n", .{});
    }

    // ── Fragment coverage diagnostics ────────────────────────────
    if (buildFragmentCoverageReport(alloc, dest_dir)) |report| {
        // Write coverage.json to artifact directory (diagnostic metadata only)
        const json = std.fmt.allocPrint(alloc, "{{\"intersectable_oldest_slot\":{d},\"intersectable_newest_slot\":{d},\"usable_contiguous_depth\":{d},\"numeric_file_count\":{d},\"break_count\":{d},\"first_break_slot\":{d},\"total_entries\":{d}}}\n", .{
            report.intersectable_oldest_slot,
            report.intersectable_newest_slot,
            report.usable_contiguous_depth,
            report.numeric_file_count,
            report.break_count,
            report.first_break_slot,
            report.total_entries,
        }) catch null;
        if (json) |j| {
            defer alloc.free(j);
            const cov_path = std.fmt.allocPrint(alloc, "{s}/coverage.json", .{dest_dir}) catch null;
            if (cov_path) |cp| {
                defer alloc.free(cp);
                const f = compat.fs.cwd().createFile(cp, .{ .truncate = true }) catch null;
                if (f) |file| {
                    var file_mut = file;
                    defer file_mut.close();
                    file_mut.writeAll(j) catch {};
                }
            }
        }
        std.debug.print("seal-tip: coverage intersectable=[{d}..{d}] usable_depth={d} numeric_files={d} breaks={d} first_break_slot={d}\n", .{
            report.intersectable_oldest_slot,
            report.intersectable_newest_slot,
            report.usable_contiguous_depth,
            report.numeric_file_count,
            report.break_count,
            report.first_break_slot,
        });
    }

    const mode_str = if (has_block) "header+block" else "header-only (block.cbor absent — BlockFetch will be skipped)";
    std.debug.print("\nseal-tip: copied {d}/{d} files + {d} fragment entries\n", .{ copied, tip_files.len, frag_copied });
    std.debug.print("  resolved_net  = {s}\n", .{resolved_net});
    std.debug.print("  resolved_home = {s}\n", .{home});
    std.debug.print("  artifact_dir  = {s}\n", .{dest_dir});
    std.debug.print("  block         = {s}\n", .{if (has_block) "present" else "absent"});
    std.debug.print("  mode          = {s}\n", .{mode_str});
    std.debug.print("\nReady to propagate:\n", .{});
    std.debug.print("  tsunagi-node propagate-serve --net {s} --artifact-dir {s} --allowlist <relay_ip> --port 3033\n\n", .{
        resolved_net, dest_dir,
    });
    return 0;
}

fn runSealLatest(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var home_path: ?[]const u8 = null;
    var net_name: ?[]const u8 = null;
    var port_num: ?u16 = null;
    var make_bundle = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--home")) {
            home_path = args_it.next() orelse {
                std.debug.print("ERROR: --home requires a path\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--net")) {
            net_name = args_it.next() orelse {
                std.debug.print("ERROR: --net requires a value\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--port")) {
            const pval = args_it.next() orelse {
                std.debug.print("ERROR: --port requires a number\n", .{});
                return 1;
            };
            port_num = std.fmt.parseInt(u16, pval, 10) catch {
                std.debug.print("ERROR: invalid --port: {s}\n", .{pval});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--make-bundle")) {
            make_bundle = true;
        } else {
            std.debug.print("ERROR: unknown seal-latest flag: {s}\n", .{arg});
            return 1;
        }
    }

    // Resolve home — fail-closed, no guessing.
    // Order: 1) --home  2) $TSUNAGI_HOME  3) --net -> ~/tsunagi-home-<net>
    //        4) --port -> infer net -> ~/tsunagi-home-<net>  5) ERROR
    var resolved_net: []const u8 = "(unknown)";
    const home = resolveSealHome(alloc, home_path, net_name, port_num, &resolved_net) orelse {
        std.debug.print("ERROR: cannot determine home directory (refusing to guess).\n", .{});
        std.debug.print("  Pass --home <path>, or --net <name>, or set $TSUNAGI_HOME.\n", .{});
        return 1;
    };
    // Verify resolved home exists
    {
        compat.fs.cwd().access(home, .{}) catch {
            std.debug.print("ERROR: resolved home path does not exist: {s}\n", .{home});
            return 1;
        };
    }
    std.debug.print("seal-latest: resolved_net={s} resolved_home={s}\n", .{ resolved_net, home });

    // Find newest blocks dir
    const blocks_dir_path = std.fmt.allocPrint(alloc, "{s}/producer_dryrun/blocks", .{home}) catch {
        std.debug.print("ERROR: alloc failed\n", .{});
        return 1;
    };
    defer alloc.free(blocks_dir_path);

    const latest_dir = findLatestBlockDir(alloc, blocks_dir_path) orelse {
        std.debug.print("ERROR: no block candidate directories in {s}\n", .{blocks_dir_path});
        return 1;
    };
    defer alloc.free(latest_dir);

    std.debug.print("=== Seal Latest ===\n", .{});
    std.debug.print("  dir: {s}\n", .{latest_dir});

    // Read slot from meta.json if possible
    {
        const meta_path = std.fmt.allocPrint(alloc, "{s}/meta.json", .{latest_dir}) catch null;
        if (meta_path) |mp| {
            defer alloc.free(mp);
            if (readFileAlloc(alloc, mp)) |meta_data| {
                defer alloc.free(meta_data);
                const meta_parsed = std.json.parseFromSlice(std.json.Value, alloc, meta_data, .{}) catch null;
                if (meta_parsed) |parsed| {
                    defer parsed.deinit();
                    if (parsed.value == .object) {
                        if (parsed.value.object.get("slot")) |v| {
                            if (jsonInt(v)) |slot| {
                                std.debug.print("  slot: {d}\n", .{slot});
                            }
                        }
                    }
                }
            } else {
                std.debug.print("  slot: (unknown)\n", .{});
            }
        }
    }

    // Read tx count
    {
        const tc_path = std.fmt.allocPrint(alloc, "{s}/included_tx_count.txt", .{latest_dir}) catch null;
        if (tc_path) |tcp| {
            defer alloc.free(tcp);
            if (readFileAlloc(alloc, tcp)) |tc_data| {
                defer alloc.free(tc_data);
                const trimmed = std.mem.trimEnd(u8, tc_data, "\n\r ");
                std.debug.print("  tx_count: {s}\n", .{trimmed});
            } else {
                std.debug.print("  tx_count: 0 (no metadata)\n", .{});
            }
        }
    }

    // 1) Run block-candidate-verify in-process
    std.debug.print("\n--- Verify ---\n", .{});
    var verify_args = FakeArgs{
        .items = &[_][]const u8{ "--dir", latest_dir },
    };
    const verify_rc = block_candidate_verify_cmd.run(alloc, &verify_args);
    const verify_ok = verify_rc == 0;

    // 2) Run block-candidate-regress if vectors exist
    std.debug.print("\n--- Regress ---\n", .{});
    var regress_rc: u8 = 0;
    var regress_ran = false;
    const vectors_paths = [_][]const u8{
        "/tmp/block_candidate_vectors_1.jsonl",
        "/tmp/block_candidate_vectors.jsonl",
    };
    for (&vectors_paths) |vp| {
        compat.fs.cwd().access(vp, .{}) catch continue;
        std.debug.print("vectors: {s}\n", .{vp});
        var regress_args = FakeArgs{
            .items = &[_][]const u8{ "--vectors", vp },
        };
        regress_rc = block_candidate_regress_cmd.run(alloc, &regress_args);
        regress_ran = true;
        break;
    }
    if (regress_ran) {
        std.debug.print("regress: {s}\n", .{if (regress_rc == 0) "PASS" else "FAIL"});
    } else {
        std.debug.print("regress vectors: (missing) SKIP\n", .{});
    }

    // 3) Optionally make bundle
    var bundle_path_buf: [512]u8 = undefined;
    var bundle_path_len: usize = 0;
    var bundle_sha: ?[64]u8 = null;
    if (make_bundle) {
        std.debug.print("\n--- Bundle ---\n", .{});
        const script_name = "make_block_candidate_proof_bundle.py";
        const script_path = findScript(alloc, script_name) orelse {
            std.debug.print("ERROR: cannot locate {s}\n", .{script_name});
            return 1;
        };
        defer alloc.free(script_path);

        const script_args = [_][]const u8{
            "python3", script_path, "--home", home,
        };

        var child = compat.Child.init(&script_args, alloc);
        child.stderr_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        const term = child.spawnAndWait() catch |err| {
            std.debug.print("ERROR: cannot run bundle script: {}\n", .{err});
            return 1;
        };
        const bundle_exit: u8 = switch (term) {
            .exited => |code| code,
            else => 1,
        };
        if (bundle_exit != 0) {
            std.debug.print("bundle: FAIL (exit {d})\n", .{bundle_exit});
        } else {
            // Find latest zip and compute sha256
            const bundles_dir = std.fmt.allocPrint(alloc, "{s}/producer_dryrun/blocks_proof_bundles", .{home}) catch null;
            if (bundles_dir) |bd| {
                defer alloc.free(bd);
                if (findLatestBundleZip(alloc, bd)) |zip_path| {
                    defer alloc.free(zip_path);
                    if (zip_path.len <= bundle_path_buf.len) {
                        @memcpy(bundle_path_buf[0..zip_path.len], zip_path);
                        bundle_path_len = zip_path.len;
                    }
                    if (readFileAlloc(alloc, zip_path)) |zip_data| {
                        defer alloc.free(zip_data);
                        var hash: [32]u8 = undefined;
                        std.crypto.hash.sha2.Sha256.hash(zip_data, &hash, .{});
                        bundle_sha = std.fmt.bytesToHex(hash, .lower);
                    }
                }
            }
        }
    }

    // Summary
    std.debug.print("\n=== Seal Summary ===\n", .{});
    std.debug.print("  dir:     {s}\n", .{latest_dir});
    std.debug.print("  verify:  {s}\n", .{if (verify_ok) "PASS" else "FAIL"});
    if (regress_ran) {
        std.debug.print("  regress: {s}\n", .{if (regress_rc == 0) "PASS" else "FAIL"});
    } else {
        std.debug.print("  regress: SKIP\n", .{});
    }
    if (make_bundle) {
        if (bundle_path_len > 0) {
            std.debug.print("  bundle:  {s}\n", .{bundle_path_buf[0..bundle_path_len]});
            if (bundle_sha) |sha| {
                std.debug.print("  sha256:  {s}\n", .{&sha});
            }
        } else {
            std.debug.print("  bundle:  (not created)\n", .{});
        }
    }

    if (!verify_ok) return 2;
    if (regress_ran and regress_rc != 0) return 2;

    // Copy sealed artifacts to propagation_artifact/ for propagate-serve
    const prop_dir = std.fmt.allocPrint(alloc, "{s}/propagation_artifact", .{home}) catch return 0;
    defer alloc.free(prop_dir);
    copyArtifactDir(alloc, latest_dir, prop_dir);

    std.debug.print("\nseal-latest: resolved_net={s} resolved_home={s} artifact_dir={s}\n", .{ resolved_net, home, prop_dir });
    std.debug.print("seal-latest: use with:\n", .{});
    std.debug.print("  tsunagi-node propagate-serve --net {s} --artifact-dir {s} --allowlist <ip> --port 3033\n", .{ resolved_net, prop_dir });
    return 0;
}

// ── airgap-opcert ────────────────────────────────────────────────────

fn runAirgapOpcert(args_it: anytype) u8 {
    var lang: i18n.Lang = .en;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--lang")) {
            lang = i18n.parseLang(args_it.next());
        } else {
            std.debug.print("ERROR: unknown airgap-opcert flag: {s}\n", .{arg});
            return 1;
        }
    }

    switch (lang) {
        .en => printOpcertEn(),
        .ja => printOpcertJa(),
    }
    return 0;
}

fn printOpcertEn() void {
    std.debug.print(
        \\=== OpCert Rotation Ceremony (Air-Gapped) ===
        \\
        \\--- BP Node (Online) ---
        \\1. Stop the node:
        \\     sudo systemctl stop tsunagi-preview
        \\2. Locate current files:
        \\     - node.cert (operational certificate)
        \\     - cold.vkey (cold verification key)
        \\     - kes.skey (current KES signing key)
        \\3. Copy cold.vkey and current node.cert to a USB drive.
        \\4. Note the current KES period:
        \\     cardano-cli query kes-period-info --testnet-magic 2
        \\
        \\--- Air-Gapped Machine ---
        \\5. Generate a new KES key pair:
        \\     cardano-cli node key-gen-KES \
        \\       --verification-key-file kes.NEW.vkey \
        \\       --signing-key-file kes.NEW.skey
        \\6. Issue a new operational certificate:
        \\     cardano-cli node issue-op-cert \
        \\       --kes-verification-key-file kes.NEW.vkey \
        \\       --cold-signing-key-file cold.skey \
        \\       --operational-certificate-issue-counter-file cold.counter \
        \\       --kes-period <CURRENT_KES_PERIOD> \
        \\       --out-file node.cert.NEW
        \\7. Verify the new cert (if kes-period-info available).
        \\8. Copy node.cert.NEW and kes.NEW.skey to USB drive.
        \\
        \\--- BP Node (Online) ---
        \\9.  Back up old files: node.cert.bak, kes.skey.bak
        \\10. Install new files:
        \\      cp kes.NEW.skey kes.skey
        \\      cp node.cert.NEW node.cert
        \\11. Restart the node:
        \\      sudo systemctl start tsunagi-preview
        \\12. Verify KES status:
        \\      tsunagi-node guardian kes-status --port 9081
        \\13. Confirm no KES errors in journal:
        \\      journalctl --user -u tsunagi-preview -n 30 --no-pager
        \\
        \\--- Safety ---
        \\- NEVER copy cold.skey to the BP node.
        \\- NEVER leave USB drives mounted after transfer.
        \\- Shred temporary files on the air-gapped machine.
        \\
    , .{});
}

fn printOpcertJa() void {
    std.debug.print(
        \\=== OpCert ローテーション手順（エアギャップ） ===
        \\
        \\--- BP ノード（オンライン） ---
        \\1. ノードを停止:
        \\     sudo systemctl stop tsunagi-preview
        \\2. 現在のファイルを確認:
        \\     - node.cert（運用証明書）
        \\     - cold.vkey（コールド検証鍵）
        \\     - kes.skey（現在のKES署名鍵）
        \\3. cold.vkey と node.cert を USB にコピー。
        \\4. 現在の KES ピリオドを確認:
        \\     cardano-cli query kes-period-info --testnet-magic 2
        \\
        \\--- エアギャップマシン ---
        \\5. 新しい KES 鍵ペアを生成:
        \\     cardano-cli node key-gen-KES \
        \\       --verification-key-file kes.NEW.vkey \
        \\       --signing-key-file kes.NEW.skey
        \\6. 新しい運用証明書を発行:
        \\     cardano-cli node issue-op-cert \
        \\       --kes-verification-key-file kes.NEW.vkey \
        \\       --cold-signing-key-file cold.skey \
        \\       --operational-certificate-issue-counter-file cold.counter \
        \\       --kes-period <現在のKESピリオド> \
        \\       --out-file node.cert.NEW
        \\7. 新しい証明書を検証。
        \\8. node.cert.NEW と kes.NEW.skey を USB にコピー。
        \\
        \\--- BP ノード（オンライン） ---
        \\9.  旧ファイルをバックアップ: node.cert.bak, kes.skey.bak
        \\10. 新ファイルをインストール:
        \\      cp kes.NEW.skey kes.skey
        \\      cp node.cert.NEW node.cert
        \\11. ノードを再起動:
        \\      sudo systemctl start tsunagi-preview
        \\12. KES ステータスを確認:
        \\      tsunagi-node guardian kes-status --port 9081
        \\13. ジャーナルで KES エラーがないことを確認:
        \\      journalctl --user -u tsunagi-preview -n 30 --no-pager
        \\
        \\--- 安全対策 ---
        \\- cold.skey を BP ノードに絶対コピーしない。
        \\- 転送後は USB を必ず取り外す。
        \\- エアギャップマシンの一時ファイルは完全消去する。
        \\
    , .{});
}

// ── version (read-only) ──────────────────────────────────────────────

fn runVersion(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var service: []const u8 = "tsunagi-preview.service";

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--service")) {
            service = args_it.next() orelse {
                std.debug.print("ERROR: --service requires a unit name\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--port")) {
            // Accept for CLI consistency; not used by version
            _ = args_it.next();
        } else {
            std.debug.print("ERROR: unknown version flag: {s}\n", .{arg});
            return 1;
        }
    }

    // Check service is active
    if (!isServiceActive(alloc, service)) {
        std.debug.print("REFUSED: service not active: {s}\n", .{service});
        return 1;
    }

    // Get ExecStart from systemctl show
    var exec_path_buf: [1024]u8 = undefined;
    const exec_path_len = runCapture(alloc, &[_][]const u8{ "systemctl", "--user", "show", service, "--property=ExecStart", "--no-pager" }, &exec_path_buf) orelse {
        std.debug.print("ERROR: cannot query ExecStart for {s}\n", .{service});
        return 1;
    };

    const exec_output = exec_path_buf[0..exec_path_len];

    // Parse binary path from ExecStart output
    // Format: ExecStart={ path=/home/.../tsunagi-node ; argv[]=... }
    const bin_path = parseExecStartPath(exec_output) orelse {
        std.debug.print("ERROR: cannot parse ExecStart from {s}\n", .{service});
        std.debug.print("  raw: {s}\n", .{exec_output[0..@min(exec_output.len, 200)]});
        return 1;
    };

    std.debug.print("=== Guardian Version ===\n", .{});
    std.debug.print("  service:  {s}\n", .{service});
    std.debug.print("  binary:   {s}\n", .{bin_path});

    // Run --version on that binary (output goes to stderr via std.debug.print)
    {
        var ver_buf: [256]u8 = undefined;
        const ver_len = runCaptureStderr(alloc, &[_][]const u8{ bin_path, "--version" }, &ver_buf) orelse {
            std.debug.print("  version:  (cannot execute)\n", .{});
            return 1;
        };
        const ver_trimmed = std.mem.trimEnd(u8, ver_buf[0..ver_len], "\n\r ");
        // Show first line only (bounded)
        const first_line = if (std.mem.indexOf(u8, ver_trimmed, "\n")) |nl| ver_trimmed[0..nl] else ver_trimmed;
        if (first_line.len > 0) {
            std.debug.print("  version:  {s}\n", .{first_line});
        } else {
            std.debug.print("  version:  (no output — binary may predate --version)\n", .{});
        }
    }

    return 0;
}

/// Parse the binary path from systemctl show ExecStart output.
/// Input: "ExecStart={ path=/home/.../tsunagi-node ; argv[]=/home/... ; ... }\n"
/// Returns: "/home/.../tsunagi-node"
fn parseExecStartPath(output: []const u8) ?[]const u8 {
    // Look for "path=" after "ExecStart="
    const path_key = "path=";
    const path_pos = std.mem.indexOf(u8, output, path_key) orelse return null;
    const start = path_pos + path_key.len;
    if (start >= output.len) return null;
    // Path ends at space or semicolon
    var end = start;
    while (end < output.len and output[end] != ' ' and output[end] != ';' and output[end] != '\n') : (end += 1) {}
    if (end == start) return null;
    return output[start..end];
}

// ── deploy-check (read-only) ────────────────────────────────────────

fn runDeployCheck(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var port: u16 = DEFAULT_PORT;
    var service: []const u8 = "tsunagi-preview.service";

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --port requires a number\n", .{});
                return 1;
            };
            port = std.fmt.parseInt(u16, val, 10) catch {
                std.debug.print("ERROR: invalid port: {s}\n", .{val});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--service")) {
            service = args_it.next() orelse {
                std.debug.print("ERROR: --service requires a unit name\n", .{});
                return 1;
            };
        } else {
            std.debug.print("ERROR: unknown deploy-check flag: {s}\n", .{arg});
            return 1;
        }
    }

    // Check service is active
    if (!isServiceActive(alloc, service)) {
        std.debug.print("REFUSED: service not active: {s}\n", .{service});
        return 1;
    }

    std.debug.print("=== Deploy Check ({s}) ===\n", .{service});
    var pass: u32 = 0;
    var fail: u32 = 0;
    const total: u32 = 5;

    // 1) /status reachable
    {
        const resp = httpGet(alloc, port, "/status");
        if (resp != null) {
            alloc.free(resp.?.body);
            if (resp.?.status == 200) {
                pass += 1;
                std.debug.print("  PASS  /status reachable\n", .{});
            } else {
                fail += 1;
                std.debug.print("  FAIL  /status reachable (HTTP {d})\n", .{resp.?.status});
            }
        } else {
            fail += 1;
            std.debug.print("  FAIL  /status reachable (connection refused)\n", .{});
        }
    }

    // 2) /state parse OK
    var state_ok = false;
    var state_json: ?std.json.Parsed(std.json.Value) = null;
    defer if (state_json != null) state_json.?.deinit();
    {
        const resp = httpGet(alloc, port, "/state");
        if (resp != null) {
            defer alloc.free(resp.?.body);
            if (resp.?.status >= 200 and resp.?.status < 300) {
                state_json = std.json.parseFromSlice(std.json.Value, alloc, resp.?.body, .{}) catch null;
            }
        }
        if (state_json != null) {
            state_ok = true;
            pass += 1;
            std.debug.print("  PASS  /state parse OK\n", .{});
        } else {
            fail += 1;
            std.debug.print("  FAIL  /state parse OK\n", .{});
        }
    }

    // 3) Doctor 10/10 (inline quick check)
    if (state_ok) {
        const root = state_json.?.value.object;
        var doc_pass: u32 = 0;
        // tip > 0
        if (root.get("tip")) |tip| {
            if (tip == .object) {
                if (tip.object.get("slot")) |v| {
                    if (jsonInt(v)) |s| {
                        if (s > 0) doc_pass += 1;
                    }
                }
            }
        }
        // kes_ok, vrf_ok, period_valid, dryrun, clock_ok
        if (getNestedInt(root, "producer_keys", "kes_ok")) |v| { if (v == 1) doc_pass += 1; }
        if (getNestedInt(root, "producer_keys", "vrf_ok")) |v| { if (v == 1) doc_pass += 1; }
        if (getNestedInt(root, "producer_kes_period", "period_valid_last")) |v| { if (v == 1) doc_pass += 1; }
        if (getNestedInt(root, "producer_dryrun", "enabled")) |v| { if (v == 1) doc_pass += 1; }
        if (getNestedInt(root, "producer_clock", "clock_ok")) |v| { if (v == 1) doc_pass += 1; }
        // mempool
        {
            const resp = httpGet(alloc, port, "/mempool");
            if (resp != null) {
                alloc.free(resp.?.body);
                if (resp.?.status == 200) doc_pass += 1;
            }
        }
        // health
        {
            const resp = httpGet(alloc, port, "/health");
            if (resp != null) {
                alloc.free(resp.?.body);
                if (resp.?.status == 200) doc_pass += 1;
            }
        }
        if (doc_pass >= 8) {
            pass += 1;
            std.debug.print("  PASS  Doctor core ({d}/8)\n", .{doc_pass});
        } else {
            fail += 1;
            std.debug.print("  FAIL  Doctor core ({d}/8)\n", .{doc_pass});
        }
    } else {
        fail += 1;
        std.debug.print("  FAIL  Doctor core (no /state)\n", .{});
    }

    // 4) Broadcast OFF
    {
        const bcast = compat.getEnvVarOwned(alloc, "TSUNAGI_TXSUB_BROADCAST") catch null;
        if (bcast) |val| {
            defer alloc.free(val);
            if (std.mem.eql(u8, val, "1")) {
                fail += 1;
                std.debug.print("  FAIL  Broadcast OFF (TSUNAGI_TXSUB_BROADCAST=1)\n", .{});
            } else {
                pass += 1;
                std.debug.print("  PASS  Broadcast OFF\n", .{});
            }
        } else {
            pass += 1;
            std.debug.print("  PASS  Broadcast OFF (env not set)\n", .{});
        }
    }

    // 5) Forge OFF
    {
        const forge = compat.getEnvVarOwned(alloc, "TSUNAGI_FORGE_ENABLE") catch null;
        if (forge) |val| {
            defer alloc.free(val);
            if (std.mem.eql(u8, val, "1")) {
                fail += 1;
                std.debug.print("  FAIL  Forge OFF (TSUNAGI_FORGE_ENABLE=1)\n", .{});
            } else {
                pass += 1;
                std.debug.print("  PASS  Forge OFF\n", .{});
            }
        } else {
            pass += 1;
            std.debug.print("  PASS  Forge OFF (env not set)\n", .{});
        }
    }

    std.debug.print("\n{d}/{d} deploy checks passed\n", .{ pass, total });
    if (fail > 0) return 1;
    return 0;
}

// ── doctor ───────────────────────────────────────────────────────────

fn runDoctor(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var port: u16 = DEFAULT_PORT;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --port requires a number\n", .{});
                return 1;
            };
            port = std.fmt.parseInt(u16, val, 10) catch {
                std.debug.print("ERROR: invalid port: {s}\n", .{val});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--init-baseline") or std.mem.eql(u8, arg, "--init") or std.mem.eql(u8, arg, "--update-baseline")) {
            std.debug.print("REFUSED: baseline update is out of scope\n", .{});
            return 1;
        } else {
            std.debug.print("ERROR: unknown doctor flag: {s}\n", .{arg});
            return 1;
        }
    }

    std.debug.print("=== Guardian Doctor ===\n", .{});
    var pass: u32 = 0;
    var fail: u32 = 0;
    var warn: u32 = 0;
    const total: u32 = 10; // 8 original + 2 new warnings

    // Check 1: Node reachable (with retry for transient TCP drops)
    {
        const resp = httpGetRetry(alloc, port, "/health");
        if (resp != null) {
            alloc.free(resp.?.body);
            if (resp.?.status == 200) {
                pass += 1;
                std.debug.print("  PASS  Node reachable (HTTP 200)\n", .{});
            } else {
                fail += 1;
                std.debug.print("  FAIL  Node reachable (HTTP {d})\n", .{resp.?.status});
            }
        } else {
            fail += 1;
            std.debug.print("  FAIL  Node reachable (connection refused)\n", .{});
        }
    }

    // Get /state once for checks 2-7
    var state_json: ?std.json.Parsed(std.json.Value) = null;
    defer if (state_json != null) state_json.?.deinit();
    {
        const resp = httpGet(alloc, port, "/state");
        if (resp != null) {
            defer alloc.free(resp.?.body);
            if (resp.?.status >= 200 and resp.?.status < 300) {
                state_json = std.json.parseFromSlice(std.json.Value, alloc, resp.?.body, .{}) catch null;
            }
        }
    }

    if (state_json == null) {
        // All state-dependent checks fail
        fail += 6;
        std.debug.print("  FAIL  Tip advancing (cannot parse /state)\n", .{});
        std.debug.print("  FAIL  KES keys loaded (cannot parse /state)\n", .{});
        std.debug.print("  FAIL  VRF keys loaded (cannot parse /state)\n", .{});
        std.debug.print("  FAIL  KES period valid (cannot parse /state)\n", .{});
        std.debug.print("  FAIL  Dryrun enabled (cannot parse /state)\n", .{});
        std.debug.print("  FAIL  Clock OK (cannot parse /state)\n", .{});
    } else {
        const root = state_json.?.value.object;

        // Check 2: Tip advancing
        {
            var tip_slot: ?i64 = null;
            if (root.get("tip")) |tip| {
                if (tip == .object) {
                    if (tip.object.get("slot")) |v| {
                        tip_slot = jsonInt(v);
                    }
                }
            }
            if (tip_slot != null and tip_slot.? > 0) {
                pass += 1;
                std.debug.print("  PASS  Tip advancing (slot={d})\n", .{tip_slot.?});
            } else {
                fail += 1;
                std.debug.print("  FAIL  Tip advancing (slot={d})\n", .{tip_slot orelse 0});
            }
        }

        // Check 3: KES keys loaded
        {
            const ok = getNestedInt(root, "producer_keys", "kes_ok");
            if (ok != null and ok.? == 1) {
                pass += 1;
                std.debug.print("  PASS  KES keys loaded\n", .{});
            } else {
                fail += 1;
                std.debug.print("  FAIL  KES keys loaded\n", .{});
            }
        }

        // Check 4: VRF keys loaded
        {
            const ok = getNestedInt(root, "producer_keys", "vrf_ok");
            if (ok != null and ok.? == 1) {
                pass += 1;
                std.debug.print("  PASS  VRF keys loaded\n", .{});
            } else {
                fail += 1;
                std.debug.print("  FAIL  VRF keys loaded\n", .{});
            }
        }

        // Check 5: KES period valid
        {
            const ok = getNestedInt(root, "producer_kes_period", "period_valid_last");
            if (ok != null and ok.? == 1) {
                pass += 1;
                std.debug.print("  PASS  KES period valid\n", .{});
            } else {
                fail += 1;
                std.debug.print("  FAIL  KES period valid\n", .{});
            }
        }

        // Check 6: Dryrun enabled
        {
            const ok = getNestedInt(root, "producer_dryrun", "enabled");
            if (ok != null and ok.? == 1) {
                pass += 1;
                std.debug.print("  PASS  Dryrun enabled\n", .{});
            } else {
                fail += 1;
                std.debug.print("  FAIL  Dryrun enabled\n", .{});
            }
        }

        // Check 7: Clock OK
        {
            const ok = getNestedInt(root, "producer_clock", "clock_ok");
            if (ok != null and ok.? == 1) {
                pass += 1;
                std.debug.print("  PASS  Clock OK\n", .{});
            } else {
                fail += 1;
                std.debug.print("  FAIL  Clock OK\n", .{});
            }
        }
    }

    // Check 8: Mempool accessible
    {
        const resp = httpGet(alloc, port, "/mempool");
        if (resp != null) {
            alloc.free(resp.?.body);
            if (resp.?.status == 200) {
                pass += 1;
                std.debug.print("  PASS  Mempool accessible\n", .{});
            } else {
                fail += 1;
                std.debug.print("  FAIL  Mempool accessible (HTTP {d})\n", .{resp.?.status});
            }
        } else {
            fail += 1;
            std.debug.print("  FAIL  Mempool accessible (connection refused)\n", .{});
        }
    }

    // Check 9: Broadcast flag (WARNING if TSUNAGI_TXSUB_BROADCAST=1)
    {
        const bcast = compat.getEnvVarOwned(alloc, "TSUNAGI_TXSUB_BROADCAST") catch null;
        if (bcast) |val| {
            defer alloc.free(val);
            if (std.mem.eql(u8, val, "1")) {
                warn += 1;
                std.debug.print("  WARN  Broadcast flag (TSUNAGI_TXSUB_BROADCAST=1 is set!)\n", .{});
            } else {
                pass += 1;
                std.debug.print("  PASS  Broadcast flag (OFF)\n", .{});
            }
        } else {
            pass += 1;
            std.debug.print("  PASS  Broadcast flag (env not set)\n", .{});
        }
    }

    // Check 10: Stake boost (WARNING if TSUNAGI_STAKE_FRACTION_X1E9 > 300M)
    {
        const sf_env = compat.getEnvVarOwned(alloc, "TSUNAGI_STAKE_FRACTION_X1E9") catch null;
        if (sf_env) |val| {
            defer alloc.free(val);
            const sf_int = std.fmt.parseInt(u64, val, 10) catch 0;
            if (sf_int > 300_000_000) {
                warn += 1;
                std.debug.print("  WARN  Stake boost active ({s} x1e9 > 300M, proof mode)\n", .{val});
            } else {
                pass += 1;
                std.debug.print("  PASS  Stake fraction ({s} x1e9)\n", .{val});
            }
        } else {
            // Not set — check /state if available
            if (state_json) |sj| {
                const sf = getNestedInt(sj.value.object, "producer_leader", "stake_fraction_x1e9");
                if (sf) |v| {
                    if (v > 300_000_000) {
                        warn += 1;
                        std.debug.print("  WARN  Stake boost active ({d} x1e9 > 300M, proof mode)\n", .{v});
                    } else {
                        pass += 1;
                        std.debug.print("  PASS  Stake fraction ({d} x1e9)\n", .{v});
                    }
                } else {
                    pass += 1;
                    std.debug.print("  PASS  Stake fraction (not configured)\n", .{});
                }
            } else {
                pass += 1;
                std.debug.print("  PASS  Stake fraction (not configured)\n", .{});
            }
        }
    }

    std.debug.print("\n{d}/{d} checks passed", .{ pass, total });
    if (warn > 0) std.debug.print(", {d} warnings", .{warn});
    std.debug.print("\n", .{});
    if (fail > 0) return 1;
    return 0;
}

// ── yamori (YAMORI Shield) ───────────────────────────────────────────

fn runYamori(alloc: std.mem.Allocator, args_it: anytype) u8 {
    const subcmd = args_it.next() orelse {
        yamoriPrintUsage();
        return 1;
    };

    if (std.mem.eql(u8, subcmd, "status")) return runYamoriStatus(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "record")) return runYamoriRecord(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "analyze")) return runYamoriAnalyze(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "safe-mode")) return runYamoriSafeMode(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "check")) return runYamoriCheck(alloc, args_it);

    std.debug.print("ERROR: unknown yamori subcommand: {s}\n", .{subcmd});
    yamoriPrintUsage();
    return 1;
}

fn yamoriPrintUsage() void {
    std.debug.print(
        \\YAMORI Shield — operator event memory + safe-mode controller
        \\
        \\Usage:
        \\  tsunagi-node guardian yamori <subcommand> [options]
        \\
        \\Subcommands:
        \\  status         Bounded node health summary (read-only)
        \\  check          Node health checks with OK/WARN/CRIT verdicts
        \\  record         Append a structured event to the YAMORI event log
        \\  analyze        Analyze recent events and suggest actions (read-only)
        \\  safe-mode      Apply or revert systemd safe-mode drop-in
        \\
        \\Options:
        \\  --port <N>     Node HTTP port (default: 9081)
        \\  --home <P>     TSUNAGI_HOME override
        \\
    , .{});
}

// ── yamori check ────────────────────────────────────────────────────

// Thresholds (hardcoded for MVP)
const CHECK_TIP_OK: i64 = 120; // seconds
const CHECK_TIP_WARN: i64 = 600;
const CHECK_ART_OK: i64 = 300;
const CHECK_ART_WARN: i64 = 1800;
const CHECK_DEPTH_OK: u64 = 100;
const CHECK_DEPTH_WARN: u64 = 10;

const CheckVerdict = enum { ok, warn, crit, skip };

fn runYamoriCheck(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var home_path: ?[]const u8 = null;
    var net_name: ?[]const u8 = null;
    var lmdb_path: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--home")) {
            home_path = args_it.next() orelse {
                std.debug.print("ERROR: --home requires a path\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--net")) {
            net_name = args_it.next() orelse {
                std.debug.print("ERROR: --net requires a network name\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--lmdb")) {
            lmdb_path = args_it.next() orelse {
                std.debug.print("ERROR: --lmdb requires a path\n", .{});
                return 1;
            };
        } else {
            std.debug.print("ERROR: unknown flag: {s}\n", .{arg});
            return 1;
        }
    }

    // Resolve home (same precedence as KAGAMI: --home > --net > TSUNAGI_HOME)
    var resolved_net: []const u8 = net_name orelse "(unknown)";
    const home = yamoriCheckResolveHome(alloc, home_path, net_name, &resolved_net) orelse {
        std.debug.print("ERROR: cannot resolve home. Use --home or --net or set TSUNAGI_HOME.\n", .{});
        return 1;
    };

    const lmdb_dir: ?[]const u8 = lmdb_path orelse
        (compat.getEnvVarOwned(alloc, "TSUNAGI_LMDB") catch null);

    var out_file = compat.fs.File.stdout();
    const out = out_file.writer();

    // Header
    out.print("YAMORI CHECK — Node Health\n", .{}) catch {};
    out.print("==========================\n", .{}) catch {};
    out.print("network     : {s}\n", .{resolved_net}) catch {};
    out.print("home        : {s}\n", .{home}) catch {};
    if (lmdb_dir) |ld| {
        out.print("lmdb        : {s}\n", .{ld}) catch {};
    } else {
        out.print("lmdb        : (not configured)\n", .{}) catch {};
    }
    out.print("\n", .{}) catch {};

    var pass: u32 = 0;
    var warn_count: u32 = 0;
    var crit_count: u32 = 0;
    var skip_count: u32 = 0;
    var worst: CheckVerdict = .ok;

    const now = compat.timestamp();

    // ── Check 1: follower_alive ──
    const cursor_path = std.fmt.allocPrint(alloc, "{s}/cursor.json", .{home}) catch null;
    defer if (cursor_path) |p| alloc.free(p);

    var cursor_unix: i64 = 0;
    var cursor_ok = false;

    if (cursor_path) |cp| {
        const cursor_data = readFileAlloc(alloc, cp);
        if (cursor_data) |data| {
            defer alloc.free(data);
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{ .allocate = .alloc_always }) catch null;
            if (parsed) |p| {
                defer p.deinit();
                if (p.value == .object) {
                    if (p.value.object.get("updated_unix")) |v| {
                        if (v == .integer) {
                            cursor_unix = v.integer;
                            cursor_ok = true;
                        }
                    }
                }
            }
        }
    }

    if (cursor_ok) {
        yamoriCheckPrint(out, .ok, "follower_alive", "cursor.json present and readable");
        yamoriTally(.ok, &pass, &warn_count, &crit_count, &skip_count, &worst);
    } else {
        yamoriCheckPrint(out, .crit, "follower_alive", "cursor.json missing or unparseable");
        yamoriTally(.crit, &pass, &warn_count, &crit_count, &skip_count, &worst);
    }

    // ── Check 2: follower_tip_age ──
    if (cursor_ok) {
        if (cursor_unix == 0) {
            yamoriCheckPrint(out, .crit, "follower_tip_age", "updated_unix=0 (never updated)");
            yamoriTally(.crit, &pass, &warn_count, &crit_count, &skip_count, &worst);
        } else {
            const age = now - cursor_unix;
            var age_buf: [80]u8 = undefined;
            const age_msg = std.fmt.bufPrint(&age_buf, "{d}s (threshold: <{d}s OK, <{d}s WARN)", .{ age, CHECK_TIP_OK, CHECK_TIP_WARN }) catch "?";
            if (age < CHECK_TIP_OK) {
                yamoriCheckPrint(out, .ok, "follower_tip_age", age_msg);
                yamoriTally(.ok, &pass, &warn_count, &crit_count, &skip_count, &worst);
            } else if (age < CHECK_TIP_WARN) {
                yamoriCheckPrint(out, .warn, "follower_tip_age", age_msg);
                yamoriTally(.warn, &pass, &warn_count, &crit_count, &skip_count, &worst);
            } else {
                yamoriCheckPrint(out, .crit, "follower_tip_age", age_msg);
                yamoriTally(.crit, &pass, &warn_count, &crit_count, &skip_count, &worst);
            }
        }
    } else {
        yamoriCheckPrint(out, .skip, "follower_tip_age", "cursor not available");
        yamoriTally(.skip, &pass, &warn_count, &crit_count, &skip_count, &worst);
    }

    // ── Check 3: artifact_present ──
    const art_dir = std.fmt.allocPrint(alloc, "{s}/propagation_artifact", .{home}) catch null;
    defer if (art_dir) |p| alloc.free(p);

    const art_exists = if (art_dir) |ad| blk: {
        compat.fs.cwd().access(ad, .{}) catch break :blk false;
        break :blk true;
    } else false;

    if (art_exists) {
        yamoriCheckPrint(out, .ok, "artifact_present", "propagation_artifact/ exists");
        yamoriTally(.ok, &pass, &warn_count, &crit_count, &skip_count, &worst);
    } else {
        yamoriCheckPrint(out, .crit, "artifact_present", "propagation_artifact/ missing");
        yamoriTally(.crit, &pass, &warn_count, &crit_count, &skip_count, &worst);
    }

    // ── Check 4: artifact_age ──
    if (art_exists) {
        const meta_path = std.fmt.allocPrint(alloc, "{s}/meta.json", .{art_dir.?}) catch null;
        defer if (meta_path) |p| alloc.free(p);

        var art_age_verdict: CheckVerdict = .crit;
        var art_age_msg_buf: [80]u8 = undefined;
        var art_age_msg: []const u8 = "meta.json missing or unparseable";

        if (meta_path) |mp| {
            const meta_data = readFileAlloc(alloc, mp);
            if (meta_data) |data| {
                defer alloc.free(data);
                if (yamoriParseJsonU64(data, "unix")) |unix_val| {
                    const unix_i64: i64 = @intCast(unix_val);
                    const age = now - unix_i64;
                    art_age_msg = std.fmt.bufPrint(&art_age_msg_buf, "{d}s (threshold: <{d}s OK, <{d}s WARN)", .{ age, CHECK_ART_OK, CHECK_ART_WARN }) catch "?";
                    if (age < CHECK_ART_OK) {
                        art_age_verdict = .ok;
                    } else if (age < CHECK_ART_WARN) {
                        art_age_verdict = .warn;
                    } else {
                        art_age_verdict = .crit;
                    }
                }
            }
        }

        yamoriCheckPrint(out, art_age_verdict, "artifact_age", art_age_msg);
        yamoriTally(art_age_verdict, &pass, &warn_count, &crit_count, &skip_count, &worst);
    } else {
        yamoriCheckPrint(out, .skip, "artifact_age", "artifact not present");
        yamoriTally(.skip, &pass, &warn_count, &crit_count, &skip_count, &worst);
    }

    // ── Load coverage.json (shared by checks 5 and 6) ──
    var cov_depth: ?u64 = null;
    var cov_breaks: ?u64 = null;
    var cov_available = false;

    if (art_exists) {
        const cov_path = std.fmt.allocPrint(alloc, "{s}/coverage.json", .{art_dir.?}) catch null;
        defer if (cov_path) |p| alloc.free(p);
        if (cov_path) |cp| {
            const cov_data = readFileAlloc(alloc, cp);
            if (cov_data) |data| {
                defer alloc.free(data);
                cov_depth = yamoriParseJsonU64(data, "usable_contiguous_depth");
                cov_breaks = yamoriParseJsonU64(data, "break_count");
                cov_available = true;
            }
        }
    }

    // ── Check 5: usable_depth ──
    if (art_exists) {
        if (cov_available) {
            if (cov_depth) |depth| {
                var depth_buf: [80]u8 = undefined;
                const depth_msg = std.fmt.bufPrint(&depth_buf, "{d} (threshold: >={d} OK, >={d} WARN)", .{ depth, CHECK_DEPTH_OK, CHECK_DEPTH_WARN }) catch "?";
                if (depth >= CHECK_DEPTH_OK) {
                    yamoriCheckPrint(out, .ok, "usable_depth", depth_msg);
                    yamoriTally(.ok, &pass, &warn_count, &crit_count, &skip_count, &worst);
                } else if (depth >= CHECK_DEPTH_WARN) {
                    yamoriCheckPrint(out, .warn, "usable_depth", depth_msg);
                    yamoriTally(.warn, &pass, &warn_count, &crit_count, &skip_count, &worst);
                } else {
                    yamoriCheckPrint(out, .crit, "usable_depth", depth_msg);
                    yamoriTally(.crit, &pass, &warn_count, &crit_count, &skip_count, &worst);
                }
            } else {
                yamoriCheckPrint(out, .warn, "usable_depth", "coverage.json missing depth field");
                yamoriTally(.warn, &pass, &warn_count, &crit_count, &skip_count, &worst);
            }
        } else {
            yamoriCheckPrint(out, .warn, "usable_depth", "coverage.json not found");
            yamoriTally(.warn, &pass, &warn_count, &crit_count, &skip_count, &worst);
        }
    } else {
        yamoriCheckPrint(out, .skip, "usable_depth", "artifact not present");
        yamoriTally(.skip, &pass, &warn_count, &crit_count, &skip_count, &worst);
    }

    // ── Check 6: break_count ──
    if (art_exists) {
        if (cov_available) {
            if (cov_breaks) |breaks| {
                var breaks_buf: [40]u8 = undefined;
                const breaks_msg = std.fmt.bufPrint(&breaks_buf, "{d}", .{breaks}) catch "?";
                if (breaks == 0) {
                    yamoriCheckPrint(out, .ok, "break_count", breaks_msg);
                    yamoriTally(.ok, &pass, &warn_count, &crit_count, &skip_count, &worst);
                } else {
                    yamoriCheckPrint(out, .crit, "break_count", breaks_msg);
                    yamoriTally(.crit, &pass, &warn_count, &crit_count, &skip_count, &worst);
                }
            } else {
                yamoriCheckPrint(out, .warn, "break_count", "coverage.json missing break_count field");
                yamoriTally(.warn, &pass, &warn_count, &crit_count, &skip_count, &worst);
            }
        } else {
            yamoriCheckPrint(out, .warn, "break_count", "coverage.json not found");
            yamoriTally(.warn, &pass, &warn_count, &crit_count, &skip_count, &worst);
        }
    } else {
        yamoriCheckPrint(out, .skip, "break_count", "artifact not present");
        yamoriTally(.skip, &pass, &warn_count, &crit_count, &skip_count, &worst);
    }

    // ── Check 7: lmdb_available ──
    if (lmdb_dir) |dir| {
        const dir_z = alloc.dupeZ(u8, dir) catch null;
        defer if (dir_z) |z| alloc.free(z);
        if (dir_z) |z| {
            if (lmdb_utxo.LmdbUtxo.open(z)) |store_val| {
                var store = store_val;
                store.close();
                yamoriCheckPrint(out, .ok, "lmdb_available", "LMDB opened successfully");
                yamoriTally(.ok, &pass, &warn_count, &crit_count, &skip_count, &worst);
            } else |_| {
                yamoriCheckPrint(out, .crit, "lmdb_available", "LMDB open failed");
                yamoriTally(.crit, &pass, &warn_count, &crit_count, &skip_count, &worst);
            }
        } else {
            yamoriCheckPrint(out, .crit, "lmdb_available", "allocation failed");
            yamoriTally(.crit, &pass, &warn_count, &crit_count, &skip_count, &worst);
        }
    } else {
        yamoriCheckPrint(out, .skip, "lmdb_available", "not configured");
        yamoriTally(.skip, &pass, &warn_count, &crit_count, &skip_count, &worst);
    }

    // ── Summary ──
    const evaluated = pass + warn_count + crit_count;
    out.print("\n", .{}) catch {};
    out.print("{d}/{d} checks passed", .{ pass, evaluated }) catch {};
    if (warn_count > 0) out.print(", {d} warnings", .{warn_count}) catch {};
    if (crit_count > 0) out.print(", {d} critical", .{crit_count}) catch {};
    if (skip_count > 0) out.print(", {d} skipped", .{skip_count}) catch {};
    out.print("\n\n", .{}) catch {};

    const overall_str: []const u8 = switch (worst) {
        .crit => "CRITICAL",
        .warn => "WARN",
        .ok => "OK",
        .skip => "OK",
    };
    out.print("OVERALL: {s}\n", .{overall_str}) catch {};

    if (worst == .crit) return 1;
    return 0;
}

fn yamoriCheckPrint(writer: anytype, verdict: CheckVerdict, name: []const u8, detail: []const u8) void {
    const tag: []const u8 = switch (verdict) {
        .ok => "[  OK  ]",
        .warn => "[ WARN ]",
        .crit => "[ CRIT ]",
        .skip => "[ SKIP ]",
    };
    writer.print("{s} {s: <20} {s}\n", .{ tag, name, detail }) catch {};
}

fn yamoriTally(verdict: CheckVerdict, pass: *u32, warn_count: *u32, crit_count: *u32, skip_count: *u32, worst: *CheckVerdict) void {
    switch (verdict) {
        .ok => pass.* += 1,
        .warn => {
            warn_count.* += 1;
            if (worst.* == .ok or worst.* == .skip) worst.* = .warn;
        },
        .crit => {
            crit_count.* += 1;
            worst.* = .crit;
        },
        .skip => skip_count.* += 1,
    }
}

fn yamoriParseJsonU64(data: []const u8, key: []const u8) ?u64 {
    var pos: usize = 0;
    while (pos + key.len + 3 < data.len) {
        if (data[pos] == '"') {
            const key_start = pos + 1;
            if (key_start + key.len < data.len and
                std.mem.eql(u8, data[key_start .. key_start + key.len], key) and
                data[key_start + key.len] == '"')
            {
                var i = key_start + key.len + 1;
                while (i < data.len and (data[i] == ' ' or data[i] == ':' or data[i] == '\t')) i += 1;
                const num_start = i;
                while (i < data.len and data[i] >= '0' and data[i] <= '9') i += 1;
                if (i > num_start) {
                    return std.fmt.parseUnsigned(u64, data[num_start..i], 10) catch null;
                }
                return null;
            }
        }
        pos += 1;
    }
    return null;
}

fn yamoriCheckResolveHome(alloc: std.mem.Allocator, home_path: ?[]const u8, net_name: ?[]const u8, resolved_net: *[]const u8) ?[]const u8 {
    if (home_path) |hp| {
        if (net_name == null) {
            resolved_net.* = inferNetFromPath(hp);
        }
        return hp;
    }
    if (net_name) |net| {
        if (homeFromNet(alloc, net)) |path| return path;
    }
    if (compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null) |env_home| {
        if (net_name == null) {
            resolved_net.* = inferNetFromPath(env_home);
        }
        return env_home;
    }
    return null;
}

// ── TATE 盾 — Fragment Defense ──────────────────────────────────────

fn runTate(alloc: std.mem.Allocator, args_it: anytype) u8 {
    const subcmd = args_it.next() orelse {
        tatePrintUsage();
        return 1;
    };

    if (std.mem.eql(u8, subcmd, "check")) return runTateCheck(alloc, args_it);

    std.debug.print("ERROR: unknown tate subcommand: {s}\n", .{subcmd});
    tatePrintUsage();
    return 1;
}

fn tatePrintUsage() void {
    std.debug.print(
        \\TATE Shield — fragment defense & propagation safety
        \\
        \\Usage:
        \\  tsunagi-node guardian tate <subcommand> [options]
        \\
        \\Subcommands:
        \\  check          Fragment defense assessment with verdicts and recommendations
        \\
        \\Options:
        \\  --home <path>  TSUNAGI home directory
        \\  --net <name>   Network name (mainnet, preview, preprod, sancho)
        \\
    , .{});
}

fn runTateCheck(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var home_path: ?[]const u8 = null;
    var net_name: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--home")) {
            home_path = args_it.next() orelse {
                std.debug.print("ERROR: --home requires a path\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--net")) {
            net_name = args_it.next() orelse {
                std.debug.print("ERROR: --net requires a network name\n", .{});
                return 1;
            };
        } else {
            std.debug.print("ERROR: unknown flag: {s}\n", .{arg});
            return 1;
        }
    }

    // Resolve home (same precedence: --home > --net > TSUNAGI_HOME)
    var resolved_net: []const u8 = net_name orelse "(unknown)";
    const home = yamoriCheckResolveHome(alloc, home_path, net_name, &resolved_net) orelse {
        std.debug.print("ERROR: cannot resolve home. Use --home or --net or set TSUNAGI_HOME.\n", .{});
        return 1;
    };

    var out_file = compat.fs.File.stdout();
    const out = out_file.writer();
    const now = compat.timestamp();

    // ── Gather data ──

    // cursor.json
    var cursor_present = false;
    var cursor_slot: ?u64 = null;
    var cursor_updated_unix: ?i64 = null;

    const cursor_path = std.fmt.allocPrint(alloc, "{s}/cursor.json", .{home}) catch null;
    defer if (cursor_path) |p| alloc.free(p);

    if (cursor_path) |cp| {
        if (readFileAlloc(alloc, cp)) |data| {
            defer alloc.free(data);
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{ .allocate = .alloc_always }) catch null;
            if (parsed) |p| {
                defer p.deinit();
                if (p.value == .object) {
                    cursor_present = true;
                    if (p.value.object.get("slot")) |v| {
                        if (v == .integer) cursor_slot = @intCast(v.integer);
                    }
                    if (p.value.object.get("updated_unix")) |v| {
                        if (v == .integer) cursor_updated_unix = v.integer;
                    }
                }
            }
        }
    }

    // propagation_artifact/
    const art_dir = std.fmt.allocPrint(alloc, "{s}/propagation_artifact", .{home}) catch null;
    defer if (art_dir) |p| alloc.free(p);

    const artifact_exists = if (art_dir) |ad| blk: {
        compat.fs.cwd().access(ad, .{}) catch break :blk false;
        break :blk true;
    } else false;

    // meta.json
    var artifact_unix: ?i64 = null;
    if (artifact_exists) {
        if (art_dir) |ad| {
            const meta_path = std.fmt.allocPrint(alloc, "{s}/meta.json", .{ad}) catch null;
            defer if (meta_path) |p| alloc.free(p);
            if (meta_path) |mp| {
                if (readFileAlloc(alloc, mp)) |data| {
                    defer alloc.free(data);
                    if (yamoriParseJsonU64(data, "unix")) |v| {
                        artifact_unix = @intCast(v);
                    }
                }
            }
        }
    }

    // coverage.json
    var coverage_present = false;
    var usable_depth: ?u64 = null;
    var break_count: ?u64 = null;
    var newest_slot: ?u64 = null;
    var oldest_slot: ?u64 = null;

    if (artifact_exists) {
        if (art_dir) |ad| {
            const cov_path = std.fmt.allocPrint(alloc, "{s}/coverage.json", .{ad}) catch null;
            defer if (cov_path) |p| alloc.free(p);
            if (cov_path) |cp| {
                if (readFileAlloc(alloc, cp)) |data| {
                    defer alloc.free(data);
                    coverage_present = true;
                    usable_depth = yamoriParseJsonU64(data, "usable_contiguous_depth");
                    break_count = yamoriParseJsonU64(data, "break_count");
                    newest_slot = yamoriParseJsonU64(data, "intersectable_newest_slot");
                    oldest_slot = yamoriParseJsonU64(data, "intersectable_oldest_slot");
                }
            }
        }
    }

    // ── Evaluate ──
    const input = tate.Input{
        .cursor_present = cursor_present,
        .cursor_slot = cursor_slot,
        .cursor_updated_unix = cursor_updated_unix,
        .artifact_exists = artifact_exists,
        .artifact_unix = artifact_unix,
        .coverage_present = coverage_present,
        .usable_depth = usable_depth,
        .break_count = break_count,
        .newest_slot = newest_slot,
        .oldest_slot = oldest_slot,
        .now = now,
    };

    const report = tate.evaluate(input);

    // ── Print header ──
    out.print("TATE CHECK — Fragment Defense\n", .{}) catch {};
    out.print("=============================\n", .{}) catch {};
    out.print("network     : {s}\n", .{resolved_net}) catch {};
    out.print("home        : {s}\n", .{home}) catch {};
    if (oldest_slot != null and newest_slot != null) {
        out.print("fragment_range : [{d}..{d}]\n", .{ oldest_slot.?, newest_slot.? }) catch {};
    }
    out.print("\n", .{}) catch {};

    // ── Print signals ──
    // Signal 1: artifact_present
    tateCheckPrint(out, report.artifact_present, "artifact_present", switch (report.artifact_present) {
        .ok => "propagation_artifact/ exists",
        .crit => "propagation_artifact/ missing",
        else => "—",
    });

    // Signal 2: artifact_age
    if (report.artifact_age == .skip) {
        tateCheckPrint(out, .skip, "artifact_age", "artifact absent");
    } else if (report.artifact_age_secs) |age| {
        var buf_age: [80]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf_age, "{d}s (threshold: <{d}s)", .{ age, tate.ARTIFACT_AGE_OK }) catch "?";
        tateCheckPrint(out, report.artifact_age, "artifact_age", msg);
    } else {
        tateCheckPrint(out, report.artifact_age, "artifact_age", "meta.json missing");
    }

    // Signal 3: usable_depth
    if (report.usable_depth == .skip) {
        tateCheckPrint(out, .skip, "usable_depth", "artifact absent");
    } else if (report.depth_value) |depth| {
        var buf_depth: [80]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf_depth, "{d} (threshold: >={d})", .{ depth, tate.DEPTH_OK }) catch "?";
        tateCheckPrint(out, report.usable_depth, "usable_depth", msg);
    } else {
        tateCheckPrint(out, report.usable_depth, "usable_depth", "coverage.json missing");
    }

    // Signal 4: break_count
    if (report.break_count == .skip) {
        tateCheckPrint(out, .skip, "break_count", "artifact absent");
    } else if (report.break_value) |bc| {
        var buf_breaks: [40]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf_breaks, "{d}", .{bc}) catch "?";
        tateCheckPrint(out, report.break_count, "break_count", msg);
    } else {
        tateCheckPrint(out, report.break_count, "break_count", "coverage.json missing");
    }

    // Signal 5: follower_tip_age
    if (report.tip_age_secs) |age| {
        var buf_tip: [80]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf_tip, "{d}s (threshold: <{d}s)", .{ age, tate.TIP_AGE_OK }) catch "?";
        tateCheckPrint(out, report.follower_tip_age, "follower_tip_age", msg);
    } else if (!cursor_present) {
        tateCheckPrint(out, report.follower_tip_age, "follower_tip_age", "cursor.json missing");
    } else {
        tateCheckPrint(out, report.follower_tip_age, "follower_tip_age", "no update timestamp");
    }

    // Signal 6: tip_artifact_gap
    if (report.tip_artifact_gap == .skip) {
        tateCheckPrint(out, .skip, "tip_artifact_gap", "artifact absent");
    } else if (report.gap_slots) |gap| {
        var buf_gap: [80]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf_gap, "{d} slots (threshold: <={d})", .{ gap, tate.GAP_OK }) catch "?";
        tateCheckPrint(out, report.tip_artifact_gap, "tip_artifact_gap", msg);
    } else {
        tateCheckPrint(out, report.tip_artifact_gap, "tip_artifact_gap", "cannot compute");
    }

    // Signal 7: coverage_metadata
    tateCheckPrint(out, report.coverage_metadata, "coverage_metadata", switch (report.coverage_metadata) {
        .ok => "coverage.json present",
        .warn => "coverage.json missing",
        .skip => "artifact absent",
        else => "—",
    });

    // ── Print recommendations ──
    if (report.rec_count > 0) {
        out.print("\nRecommendations:\n", .{}) catch {};
        for (report.recs[0..report.rec_count]) |rec| {
            out.print("  - {s}\n", .{rec}) catch {};
        }
    }

    // ── Overall ──
    const overall_str: []const u8 = switch (report.overall) {
        .crit => "CRITICAL",
        .warn => "WARN",
        .ok => "OK",
        .skip => "OK",
    };
    out.print("\nOVERALL: {s}\n", .{overall_str}) catch {};

    // Exit: 0 for OK or WARN, 1 for CRITICAL
    if (report.overall == .crit) return 1;
    return 0;
}

fn tateCheckPrint(writer: anytype, verdict: tate.Verdict, name: []const u8, detail: []const u8) void {
    const tag: []const u8 = switch (verdict) {
        .ok => "[  OK  ]",
        .warn => "[ WARN ]",
        .crit => "[ CRIT ]",
        .skip => "[ SKIP ]",
    };
    writer.print("{s} {s: <20} {s}\n", .{ tag, name, detail }) catch {};
}

// ── yamori status ───────────────────────────────────────────────────

fn runYamoriStatus(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var port: u16 = DEFAULT_PORT;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --port requires a number\n", .{});
                return 1;
            };
            port = std.fmt.parseInt(u16, val, 10) catch {
                std.debug.print("ERROR: invalid port: {s}\n", .{val});
                return 1;
            };
        } else {
            std.debug.print("ERROR: unknown yamori status flag: {s}\n", .{arg});
            return 1;
        }
    }

    // 1) /status
    const status_resp = httpGet(alloc, port, "/status") orelse {
        std.debug.print("ERROR: cannot connect to node at 127.0.0.1:{d}\n", .{port});
        return 1;
    };
    defer alloc.free(status_resp.body);

    var net_str: []const u8 = "(unknown)";
    var status_slot: i64 = 0;

    if (status_resp.status >= 200 and status_resp.status < 300) {
        const sp = std.json.parseFromSlice(std.json.Value, alloc, status_resp.body, .{}) catch null;
        if (sp) |parsed| {
            defer parsed.deinit();
            const sroot = parsed.value.object;
            if (sroot.get("net")) |v| {
                if (v == .string) net_str = v.string;
            }
            if (sroot.get("slot")) |v| status_slot = jsonInt(v) orelse 0;
        }
    }

    // 2) /state
    var state_parsed_opt: ?std.json.Parsed(std.json.Value) = null;
    defer if (state_parsed_opt) |*p| p.deinit();
    {
        const resp = httpGet(alloc, port, "/state");
        if (resp) |r| {
            defer alloc.free(r.body);
            if (r.status >= 200 and r.status < 300) {
                state_parsed_opt = std.json.parseFromSlice(std.json.Value, alloc, r.body, .{}) catch null;
            }
        }
    }

    std.debug.print("=== YAMORI Status ===\n", .{});
    std.debug.print("  net:              {s}\n", .{net_str});
    std.debug.print("  slot:             {d}\n", .{status_slot});

    if (state_parsed_opt) |sj| {
        const root = sj.value.object;

        // header_stable
        if (root.get("header")) |hdr| {
            if (hdr == .object) {
                const stable = if (hdr.object.get("stable")) |v| jsonInt(v) else null;
                std.debug.print("  header_stable:    {d}\n", .{stable orelse 0});
            }
        }

        // txsub enabled
        if (root.get("txsub")) |txsub| {
            if (txsub == .object) {
                const enabled = if (txsub.object.get("enabled")) |v| jsonInt(v) else null;
                std.debug.print("  txsub_enabled:    {s}\n", .{
                    if (enabled != null and enabled.? == 1) "YES" else "NO",
                });
            }
        }

        // KES period valid
        {
            const valid = getNestedInt(root, "producer_kes_period", "period_valid_last");
            std.debug.print("  kes_period_valid: {s}\n", .{
                if (valid != null and valid.? == 1) "YES" else "NO",
            });
        }
    } else {
        std.debug.print("  (cannot parse /state)\n", .{});
    }

    // broadcast warning (env check)
    {
        const bcast = compat.getEnvVarOwned(alloc, "TSUNAGI_TXSUB_BROADCAST") catch null;
        if (bcast) |val| {
            defer alloc.free(val);
            if (std.mem.eql(u8, val, "1")) {
                std.debug.print("  broadcast:        WARNING — TSUNAGI_TXSUB_BROADCAST=1\n", .{});
            } else {
                std.debug.print("  broadcast:        OFF\n", .{});
            }
        } else {
            std.debug.print("  broadcast:        OFF\n", .{});
        }
    }

    // mempool
    {
        const mresp = httpGet(alloc, port, "/mempool");
        if (mresp) |mr| {
            defer alloc.free(mr.body);
            if (mr.status >= 200 and mr.status < 300) {
                const mp = std.json.parseFromSlice(std.json.Value, alloc, mr.body, .{}) catch null;
                if (mp) |parsed| {
                    defer parsed.deinit();
                    const mroot = parsed.value.object;
                    const items = if (mroot.get("items")) |v| jsonInt(v) else null;
                    const bytes = if (mroot.get("bytes")) |v| jsonInt(v) else null;
                    std.debug.print("  mempool:          {d} items, {d} bytes\n", .{
                        items orelse 0, bytes orelse 0,
                    });
                }
            }
        } else {
            std.debug.print("  mempool:          (unreachable)\n", .{});
        }
    }

    return 0;
}

// ── yamori record ───────────────────────────────────────────────────

fn runYamoriRecord(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var port: u16 = DEFAULT_PORT;
    var home_path: ?[]const u8 = null;
    var level: ?[]const u8 = null;
    var subsys: ?[]const u8 = null;
    var code: ?[]const u8 = null;
    var msg_arg: ?[]const u8 = null;
    var note_arg: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --port requires a number\n", .{});
                return 1;
            };
            port = std.fmt.parseInt(u16, val, 10) catch {
                std.debug.print("ERROR: invalid port: {s}\n", .{val});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--home")) {
            home_path = args_it.next() orelse {
                std.debug.print("ERROR: --home requires a path\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--level")) {
            level = args_it.next() orelse {
                std.debug.print("ERROR: --level requires a value\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--subsys")) {
            subsys = args_it.next() orelse {
                std.debug.print("ERROR: --subsys requires a value\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--code")) {
            code = args_it.next() orelse {
                std.debug.print("ERROR: --code requires a value\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--msg")) {
            msg_arg = args_it.next() orelse {
                std.debug.print("ERROR: --msg requires a value\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--note")) {
            note_arg = args_it.next() orelse {
                std.debug.print("ERROR: --note requires a value\n", .{});
                return 1;
            };
        } else {
            std.debug.print("ERROR: unknown yamori record flag: {s}\n", .{arg});
            return 1;
        }
    }

    // Validate required fields
    const lvl = level orelse {
        std.debug.print("ERROR: --level is required (INFO|WARN|CRIT)\n", .{});
        return 1;
    };
    const sys = subsys orelse {
        std.debug.print("ERROR: --subsys is required\n", .{});
        return 1;
    };
    const cd = code orelse {
        std.debug.print("ERROR: --code is required\n", .{});
        return 1;
    };

    // Validate level
    if (!std.mem.eql(u8, lvl, "INFO") and
        !std.mem.eql(u8, lvl, "WARN") and
        !std.mem.eql(u8, lvl, "CRIT"))
    {
        std.debug.print("ERROR: --level must be INFO, WARN, or CRIT\n", .{});
        return 1;
    }

    // Validate subsys
    const valid_subsys = [_][]const u8{ "TXSUB", "KES", "VRF", "PRAOS", "LEDGER", "DEPLOY", "FORGE", "HEALTH" };
    var subsys_ok = false;
    for (valid_subsys) |vs| {
        if (std.mem.eql(u8, sys, vs)) {
            subsys_ok = true;
            break;
        }
    }
    if (!subsys_ok) {
        std.debug.print("ERROR: --subsys must be one of: TXSUB, KES, VRF, PRAOS, LEDGER, DEPLOY, FORGE, HEALTH\n", .{});
        return 1;
    }

    // msg construction: --msg > --note > ""
    const raw_msg: []const u8 = msg_arg orelse (note_arg orelse "");

    // Sanitize msg: replace \r \n \t with space, cap at 160, reject " and \
    var clean_msg: [160]u8 = undefined;
    var clean_len: usize = 0;
    for (raw_msg) |c| {
        if (clean_len >= 160) break;
        if (c == '"' or c == '\\') {
            std.debug.print("ERROR: --msg must not contain '\"' or '\\' characters\n", .{});
            return 1;
        }
        if (c == '\r' or c == '\n' or c == '\t') {
            clean_msg[clean_len] = ' ';
        } else {
            clean_msg[clean_len] = c;
        }
        clean_len += 1;
    }
    const sanitized_msg = clean_msg[0..clean_len];

    // Get net from /status (fallback "unknown")
    var net_buf: [32]u8 = undefined;
    var net_str: []const u8 = "unknown";
    {
        const status_resp = httpGet(alloc, port, "/status");
        if (status_resp) |resp| {
            defer alloc.free(resp.body);
            if (resp.status >= 200 and resp.status < 300) {
                const sp = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch null;
                if (sp) |parsed| {
                    defer parsed.deinit();
                    if (parsed.value == .object) {
                        if (parsed.value.object.get("net")) |v| {
                            if (v == .string and v.string.len <= net_buf.len) {
                                @memcpy(net_buf[0..v.string.len], v.string);
                                net_str = net_buf[0..v.string.len];
                            }
                        }
                    }
                }
            }
        }
    }

    // Resolve home
    var home_owned = false;
    const home = if (home_path) |hp| hp else blk: {
        const env_home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
        if (env_home) |h| {
            home_owned = true;
            break :blk h;
        }
        break :blk @as(?[]const u8, null);
    };
    if (home == null) {
        std.debug.print("ERROR: --home or TSUNAGI_HOME required\n", .{});
        return 1;
    }
    defer if (home_owned) alloc.free(home.?);

    // Ensure guardian dir
    var gdir_buf: [512]u8 = undefined;
    const gdir = std.fmt.bufPrint(&gdir_buf, "{s}/guardian", .{home.?}) catch {
        std.debug.print("ERROR: path too long\n", .{});
        return 1;
    };
    compat.fs.cwd().makePath(gdir) catch {};

    // Build event file path
    var evpath_buf: [512]u8 = undefined;
    const events_path = std.fmt.bufPrint(&evpath_buf, "{s}/guardian/yamori_events.jsonl", .{home.?}) catch {
        std.debug.print("ERROR: path too long\n", .{});
        return 1;
    };

    // Build JSONL line
    const now_unix: i64 = compat.timestamp();
    var line_buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf,
        \\{{"unix":{d},"net":"{s}","level":"{s}","subsys":"{s}","code":"{s}","msg":"{s}"}}
    , .{ now_unix, net_str, lvl, sys, cd, sanitized_msg }) catch {
        std.debug.print("ERROR: event line buffer overflow\n", .{});
        return 1;
    };

    // Append to JSONL file
    var file = compat.fs.cwd().createFile(events_path, .{ .truncate = false }) catch {
        std.debug.print("ERROR: cannot open {s}\n", .{events_path});
        return 1;
    };
    defer file.close();

    const end_pos = file.getEndPos() catch {
        std.debug.print("ERROR: cannot stat {s}\n", .{events_path});
        return 1;
    };
    file.seekTo(end_pos) catch {
        std.debug.print("ERROR: cannot seek {s}\n", .{events_path});
        return 1;
    };

    file.writeAll(line) catch {
        std.debug.print("ERROR: write failed\n", .{});
        return 1;
    };
    file.writeAll("\n") catch {
        std.debug.print("ERROR: write newline failed\n", .{});
        return 1;
    };

    std.debug.print("recorded: {s}\n", .{line});
    return 0;
}

// ── yamori analyze ──────────────────────────────────────────────────

fn runYamoriAnalyze(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var home_path: ?[]const u8 = null;
    var last_n: u32 = 50;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--home")) {
            home_path = args_it.next() orelse {
                std.debug.print("ERROR: --home requires a path\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--last")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --last requires a number\n", .{});
                return 1;
            };
            last_n = std.fmt.parseInt(u32, val, 10) catch {
                std.debug.print("ERROR: invalid --last value: {s}\n", .{val});
                return 1;
            };
            if (last_n == 0 or last_n > 10000) {
                std.debug.print("ERROR: --last must be 1..10000\n", .{});
                return 1;
            }
        } else {
            std.debug.print("ERROR: unknown yamori analyze flag: {s}\n", .{arg});
            return 1;
        }
    }

    // Resolve home
    var home_owned = false;
    const home = if (home_path) |hp| hp else blk: {
        const env_home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
        if (env_home) |h| {
            home_owned = true;
            break :blk h;
        }
        break :blk @as(?[]const u8, null);
    };
    if (home == null) {
        std.debug.print("ERROR: --home or TSUNAGI_HOME required\n", .{});
        return 1;
    }
    defer if (home_owned) alloc.free(home.?);

    // Build events file path
    var evpath_buf: [512]u8 = undefined;
    const events_path = std.fmt.bufPrint(&evpath_buf, "{s}/guardian/yamori_events.jsonl", .{home.?}) catch {
        std.debug.print("ERROR: path too long\n", .{});
        return 1;
    };

    // Open events file
    var file = compat.fs.cwd().openFile(events_path, .{}) catch {
        std.debug.print("No events recorded.\n", .{});
        return 0;
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        std.debug.print("ERROR: cannot stat event file\n", .{});
        return 1;
    };
    if (file_size == 0) {
        std.debug.print("No events recorded.\n", .{});
        return 0;
    }

    // Tail-read: read up to 64KB from end
    const max_tail: u64 = 65536;
    const read_start: u64 = if (file_size > max_tail) file_size - max_tail else 0;
    const read_len: usize = @intCast(file_size - read_start);

    const tail_buf = alloc.alloc(u8, read_len) catch {
        std.debug.print("ERROR: cannot allocate tail buffer\n", .{});
        return 1;
    };
    defer alloc.free(tail_buf);

    file.seekTo(read_start) catch {
        std.debug.print("ERROR: cannot seek\n", .{});
        return 1;
    };
    const bytes_read = file.readAll(tail_buf) catch {
        std.debug.print("ERROR: cannot read\n", .{});
        return 1;
    };
    const data = tail_buf[0..bytes_read];

    // Find start of last N lines by scanning backward
    var newline_count: u32 = 0;
    var scan_pos: usize = data.len;
    if (scan_pos > 0 and data[scan_pos - 1] == '\n') scan_pos -= 1;
    while (scan_pos > 0) {
        scan_pos -= 1;
        if (data[scan_pos] == '\n') {
            newline_count += 1;
            if (newline_count >= last_n) {
                scan_pos += 1; // start after this newline
                break;
            }
        }
    }

    // If mid-file read, skip first partial line
    var lines_start: usize = scan_pos;
    if (read_start > 0 and scan_pos == 0) {
        if (std.mem.indexOfScalar(u8, data, '\n')) |nl| {
            lines_start = nl + 1;
        }
    }

    const lines_data = data[lines_start..];

    // Parse lines: track (subsys,code) frequency and last 5 CRITs
    const FreqEntry = struct { subsys: [32]u8, subsys_len: usize, code: [64]u8, code_len: usize, count: u32 };
    var freq: [256]FreqEntry = undefined;
    var freq_len: usize = 0;

    var crit_lines: [5][]const u8 = [_][]const u8{""} ** 5;
    var crit_count: usize = 0;
    var total_events: u32 = 0;

    // Codes seen for playbook suggestions
    var seen_codes: [256][64]u8 = undefined;
    var seen_code_lens: [256]usize = undefined;
    var seen_code_count: usize = 0;

    var line_iter = std.mem.splitScalar(u8, lines_data, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        total_events += 1;

        // Extract subsys and code using substring search (avoid full JSON parse per line)
        const ev_subsys = extractJsonStr(line, "\"subsys\":\"") orelse continue;
        const ev_code = extractJsonStr(line, "\"code\":\"") orelse continue;
        const ev_level = extractJsonStr(line, "\"level\":\"") orelse "";

        // Track frequency
        var found_idx: ?usize = null;
        for (freq[0..freq_len], 0..) |f, i| {
            if (std.mem.eql(u8, f.subsys[0..f.subsys_len], ev_subsys) and
                std.mem.eql(u8, f.code[0..f.code_len], ev_code))
            {
                found_idx = i;
                break;
            }
        }
        if (found_idx) |idx| {
            freq[idx].count += 1;
        } else if (freq_len < 256) {
            var entry: FreqEntry = .{ .subsys = undefined, .subsys_len = @min(ev_subsys.len, 32), .code = undefined, .code_len = @min(ev_code.len, 64), .count = 1 };
            @memcpy(entry.subsys[0..entry.subsys_len], ev_subsys[0..entry.subsys_len]);
            @memcpy(entry.code[0..entry.code_len], ev_code[0..entry.code_len]);
            freq[freq_len] = entry;
            freq_len += 1;
        }

        // Track codes for playbook
        if (seen_code_count < 256 and ev_code.len <= 64) {
            var code_seen = false;
            for (seen_codes[0..seen_code_count], seen_code_lens[0..seen_code_count]) |sc, sl| {
                if (std.mem.eql(u8, sc[0..sl], ev_code)) {
                    code_seen = true;
                    break;
                }
            }
            if (!code_seen) {
                @memcpy(seen_codes[seen_code_count][0..ev_code.len], ev_code);
                seen_code_lens[seen_code_count] = ev_code.len;
                seen_code_count += 1;
            }
        }

        // Track last 5 CRITs
        if (std.mem.eql(u8, ev_level, "CRIT")) {
            if (crit_count < 5) {
                crit_lines[crit_count] = line;
                crit_count += 1;
            } else {
                crit_lines[0] = crit_lines[1];
                crit_lines[1] = crit_lines[2];
                crit_lines[2] = crit_lines[3];
                crit_lines[3] = crit_lines[4];
                crit_lines[4] = line;
            }
        }
    }

    // Print analysis
    std.debug.print("=== YAMORI Analyze ({d} events) ===\n", .{total_events});

    // Top 5 recurring (subsys,code)
    std.debug.print("\n[Top recurring events]\n", .{});
    {
        var printed: u32 = 0;
        var used: [256]bool = [_]bool{false} ** 256;
        while (printed < 5 and printed < freq_len) {
            var best_idx: usize = 0;
            var best_count: u32 = 0;
            for (0..freq_len) |i| {
                if (!used[i] and freq[i].count > best_count) {
                    best_idx = i;
                    best_count = freq[i].count;
                }
            }
            if (best_count == 0) break;
            used[best_idx] = true;
            std.debug.print("  {d}x  {s}/{s}\n", .{
                best_count,
                freq[best_idx].subsys[0..freq[best_idx].subsys_len],
                freq[best_idx].code[0..freq[best_idx].code_len],
            });
            printed += 1;
        }
        if (freq_len == 0) std.debug.print("  (none)\n", .{});
    }

    // Last 5 CRITs
    std.debug.print("\n[Last critical events]\n", .{});
    if (crit_count == 0) {
        std.debug.print("  (none)\n", .{});
    } else {
        for (crit_lines[0..crit_count]) |cline| {
            const display = cline[0..@min(cline.len, 200)];
            std.debug.print("  {s}\n", .{display});
        }
    }

    // Suggested actions from playbook
    std.debug.print("\n[Suggested actions]\n", .{});
    var suggestions_printed: u32 = 0;
    for (0..seen_code_count) |i| {
        if (suggestions_printed >= 3) break;
        const c = seen_codes[i][0..seen_code_lens[i]];
        const suggestion = yamoriPlaybook(c);
        if (suggestion.len > 0 and !std.mem.eql(u8, suggestion, "See docs/yamori.md for taxonomy.")) {
            std.debug.print("  -> {s}: {s}\n", .{ c, suggestion });
            suggestions_printed += 1;
        }
    }
    if (suggestions_printed == 0) {
        std.debug.print("  (no playbook matches)\n", .{});
    }

    return 0;
}

/// Extract a JSON string value by searching for a needle like "\"key\":\"".
/// Returns the value between the needle and the next unescaped quote.
fn extractJsonStr(json: []const u8, needle: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const val_start = start + needle.len;
    const end = std.mem.indexOfPos(u8, json, val_start, "\"") orelse return null;
    if (end == val_start) return null;
    return json[val_start..end];
}

/// YAMORI playbook: code -> suggested operator action.
fn yamoriPlaybook(code: []const u8) []const u8 {
    const entries = [_]struct { c: []const u8, a: []const u8 }{
        .{ .c = "TXSUB_BROADCAST_ON", .a = "Disable TSUNAGI_TXSUB_BROADCAST; safe-mode apply can enforce this." },
        .{ .c = "DEPLOY_TEXT_FILE_BUSY", .a = "Deploy into versioned dir; never overwrite in-use binaries; use ExecStart override." },
        .{ .c = "FORGE_ARM_TOKEN_EXPIRED", .a = "Re-run guardian forge-arm; token TTL is 10 minutes." },
        .{ .c = "HEALTH_ENDPOINT_FAIL", .a = "Check service active; run guardian doctor; verify port." },
        .{ .c = "KES_PERIOD_INVALID", .a = "Check opcert counter and KES period alignment." },
        .{ .c = "KES_INVALID_PERIOD", .a = "Check opcert counter and KES period alignment." },
        .{ .c = "FORGE_MISS", .a = "Missed leader slot. Check KES validity and clock sync." },
        .{ .c = "LEDGER_VIOLATION_SPIKE", .a = "Check for malformed transactions; review BAeY peer scores." },
        .{ .c = "TXSUB_REJECT_INVALID", .a = "Verify tx CBOR structure; check cardano-cli version." },
    };
    for (entries) |e| {
        if (std.mem.eql(u8, code, e.c)) return e.a;
    }
    return "See docs/yamori.md for taxonomy.";
}

// ── yamori safe-mode ────────────────────────────────────────────────

fn runYamoriSafeMode(alloc: std.mem.Allocator, args_it: anytype) u8 {
    const action = args_it.next() orelse {
        std.debug.print(
            \\Usage: tsunagi-node guardian yamori safe-mode <apply|revert> [options]
            \\
            \\Options:
            \\  --service <unit>          Systemd user service (default: tsunagi-preview.service)
            \\  --home <path>             TSUNAGI_HOME override
            \\  --i-know-what-im-doing    Required for non-preview services
            \\
        , .{});
        return 1;
    };

    if (std.mem.eql(u8, action, "apply")) return runYamoriSafeModeApply(alloc, args_it);
    if (std.mem.eql(u8, action, "revert")) return runYamoriSafeModeRevert(alloc, args_it);

    std.debug.print("ERROR: unknown safe-mode action: {s} (expected apply or revert)\n", .{action});
    return 1;
}

fn runYamoriSafeModeApply(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var service: []const u8 = "tsunagi-preview.service";
    var confirmed = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--service")) {
            service = args_it.next() orelse {
                std.debug.print("ERROR: --service requires a unit name\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--home")) {
            _ = args_it.next() orelse {
                std.debug.print("ERROR: --home requires a path\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--i-know-what-im-doing")) {
            confirmed = true;
        } else {
            std.debug.print("ERROR: unknown safe-mode apply flag: {s}\n", .{arg});
            return 1;
        }
    }

    // Safety gate
    if (!std.mem.eql(u8, service, "tsunagi-preview.service") and !confirmed) {
        std.debug.print("REFUSED: safe-mode apply on non-preview service requires --i-know-what-im-doing\n", .{});
        return 1;
    }

    // Build drop-in path: ~/.config/systemd/user/<service>.d/99-yamori-safe.conf
    const user_home = compat.getEnvVarOwned(alloc, "HOME") catch {
        std.debug.print("ERROR: HOME not set\n", .{});
        return 1;
    };
    defer alloc.free(user_home);

    var dropin_dir_buf: [512]u8 = undefined;
    const dropin_dir = std.fmt.bufPrint(&dropin_dir_buf, "{s}/.config/systemd/user/{s}.d", .{ user_home, service }) catch {
        std.debug.print("ERROR: path too long\n", .{});
        return 1;
    };

    compat.fs.cwd().makePath(dropin_dir) catch {
        std.debug.print("ERROR: cannot create drop-in directory: {s}\n", .{dropin_dir});
        return 1;
    };

    var dropin_path_buf: [512]u8 = undefined;
    const dropin_path = std.fmt.bufPrint(&dropin_path_buf, "{s}/99-yamori-safe.conf", .{dropin_dir}) catch {
        std.debug.print("ERROR: path too long\n", .{});
        return 1;
    };

    // Write drop-in content
    const dropin_content =
        \\[Service]
        \\UnsetEnvironment=TSUNAGI_TXSUB_BROADCAST
        \\UnsetEnvironment=TSUNAGI_FORGE_ENABLE
        \\UnsetEnvironment=TSUNAGI_FORGE_PREVIEW_ONLY
        \\UnsetEnvironment=TSUNAGI_FORGE_NO_BROADCAST
        \\UnsetEnvironment=TSUNAGI_FORGE_REQUIRE_GUARDIAN_CONFIRM
        \\
    ;

    var out_file = compat.fs.cwd().createFile(dropin_path, .{ .truncate = true }) catch {
        std.debug.print("ERROR: cannot write {s}\n", .{dropin_path});
        return 1;
    };
    defer out_file.close();
    out_file.writeAll(dropin_content) catch {
        std.debug.print("ERROR: write failed\n", .{});
        return 1;
    };

    // daemon-reload
    {
        const args_reload = [_][]const u8{ "systemctl", "--user", "daemon-reload" };
        var child = compat.Child.init(&args_reload, alloc);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        const term = child.spawnAndWait() catch {
            std.debug.print("ERROR: cannot run systemctl --user daemon-reload\n", .{});
            return 1;
        };
        switch (term) {
            .exited => |ec| if (ec != 0) {
                std.debug.print("ERROR: daemon-reload failed (exit {d})\n", .{ec});
                return 1;
            },
            else => {
                std.debug.print("ERROR: daemon-reload abnormal exit\n", .{});
                return 1;
            },
        }
    }

    // restart service
    {
        const args_restart = [_][]const u8{ "systemctl", "--user", "restart", service };
        var child = compat.Child.init(&args_restart, alloc);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        const term = child.spawnAndWait() catch {
            std.debug.print("ERROR: cannot restart {s}\n", .{service});
            return 1;
        };
        switch (term) {
            .exited => |ec| if (ec != 0) {
                std.debug.print("ERROR: restart failed for {s} (exit {d})\n", .{ service, ec });
                return 1;
            },
            else => {
                std.debug.print("ERROR: restart abnormal exit for {s}\n", .{service});
                return 1;
            },
        }
    }

    std.debug.print("APPLIED safe-mode drop-in: {s}\n", .{dropin_path});
    std.debug.print("  UnsetEnvironment=TSUNAGI_TXSUB_BROADCAST\n", .{});
    std.debug.print("  UnsetEnvironment=TSUNAGI_FORGE_ENABLE\n", .{});
    std.debug.print("  UnsetEnvironment=TSUNAGI_FORGE_PREVIEW_ONLY\n", .{});
    std.debug.print("  UnsetEnvironment=TSUNAGI_FORGE_NO_BROADCAST\n", .{});
    std.debug.print("  UnsetEnvironment=TSUNAGI_FORGE_REQUIRE_GUARDIAN_CONFIRM\n", .{});
    return 0;
}

fn runYamoriSafeModeRevert(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var service: []const u8 = "tsunagi-preview.service";
    var confirmed = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--service")) {
            service = args_it.next() orelse {
                std.debug.print("ERROR: --service requires a unit name\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--home")) {
            _ = args_it.next() orelse {
                std.debug.print("ERROR: --home requires a path\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--i-know-what-im-doing")) {
            confirmed = true;
        } else {
            std.debug.print("ERROR: unknown safe-mode revert flag: {s}\n", .{arg});
            return 1;
        }
    }

    // Safety gate
    if (!std.mem.eql(u8, service, "tsunagi-preview.service") and !confirmed) {
        std.debug.print("REFUSED: safe-mode revert on non-preview service requires --i-know-what-im-doing\n", .{});
        return 1;
    }

    // Build drop-in path
    const user_home = compat.getEnvVarOwned(alloc, "HOME") catch {
        std.debug.print("ERROR: HOME not set\n", .{});
        return 1;
    };
    defer alloc.free(user_home);

    var dropin_path_buf: [512]u8 = undefined;
    const dropin_path = std.fmt.bufPrint(&dropin_path_buf, "{s}/.config/systemd/user/{s}.d/99-yamori-safe.conf", .{ user_home, service }) catch {
        std.debug.print("ERROR: path too long\n", .{});
        return 1;
    };

    // Delete drop-in
    compat.fs.cwd().deleteFile(dropin_path) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("safe-mode drop-in not present (already reverted?): {s}\n", .{dropin_path});
            return 0;
        }
        std.debug.print("ERROR: cannot remove {s}\n", .{dropin_path});
        return 1;
    };

    // daemon-reload
    {
        const args_reload = [_][]const u8{ "systemctl", "--user", "daemon-reload" };
        var child = compat.Child.init(&args_reload, alloc);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        const term = child.spawnAndWait() catch {
            std.debug.print("ERROR: cannot run systemctl --user daemon-reload\n", .{});
            return 1;
        };
        switch (term) {
            .exited => |ec| if (ec != 0) {
                std.debug.print("ERROR: daemon-reload failed (exit {d})\n", .{ec});
                return 1;
            },
            else => {
                std.debug.print("ERROR: daemon-reload abnormal exit\n", .{});
                return 1;
            },
        }
    }

    // restart service
    {
        const args_restart = [_][]const u8{ "systemctl", "--user", "restart", service };
        var child = compat.Child.init(&args_restart, alloc);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        const term = child.spawnAndWait() catch {
            std.debug.print("ERROR: cannot restart {s}\n", .{service});
            return 1;
        };
        switch (term) {
            .exited => |ec| if (ec != 0) {
                std.debug.print("ERROR: restart failed for {s} (exit {d})\n", .{ service, ec });
                return 1;
            },
            else => {
                std.debug.print("ERROR: restart abnormal exit for {s}\n", .{service});
                return 1;
            },
        }
    }

    std.debug.print("REVERTED safe-mode drop-in: {s}\n", .{dropin_path});
    return 0;
}

// ── Shared helpers ───────────────────────────────────────────────────

const HttpResponse = struct {
    status: u16,
    body: []u8,
};

fn httpGet(alloc: std.mem.Allocator, port: u16, path: []const u8) ?HttpResponse {
    var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return null;
    const stream = addr.connect(compat.defaultIo(), .{ .mode = .stream }) catch return null;
    defer stream.close(compat.defaultIo());

    const w = compat.streamWriter(stream);
    w.print("GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{ path, port }) catch return null;

    return readHttpResponse(alloc, stream);
}

/// httpGet with up to 3 attempts and 300ms back-off between retries.
/// Retries on null (connection failure) or status 0 (malformed response).
fn httpGetRetry(alloc: std.mem.Allocator, port: u16, path: []const u8) ?HttpResponse {
    var attempt: u8 = 0;
    while (attempt < 6) : (attempt += 1) {
        if (attempt > 0) compat.sleep(500 * std.time.ns_per_ms);
        const resp = httpGet(alloc, port, path) orelse continue;
        if (resp.status == 0) {
            alloc.free(resp.body);
            continue;
        }
        return resp;
    }
    return null;
}

fn httpPost(alloc: std.mem.Allocator, port: u16, path: []const u8, body: []const u8, content_type: []const u8) ?HttpResponse {
    var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return null;
    const stream = addr.connect(compat.defaultIo(), .{ .mode = .stream }) catch return null;
    defer stream.close(compat.defaultIo());

    const w = compat.streamWriter(stream);
    w.print("POST {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ path, port, content_type, body.len }) catch return null;
    w.writeAll(body) catch return null;

    return readHttpResponse(alloc, stream);
}

fn readHttpResponse(alloc: std.mem.Allocator, stream: compat.NetStream) ?HttpResponse {
    var resp_buf: [65536]u8 = undefined;
    var total_read: usize = 0;
    var rbuf: [4096]u8 = undefined;
    var sr = compat.NetStream.Reader.init(stream, compat.defaultIo(), &rbuf);
    while (total_read < resp_buf.len) {
        const n = sr.interface.readSliceShort(resp_buf[total_read..]) catch break;
        if (n == 0) break;
        total_read += n;
    }
    if (total_read == 0) return null;
    const resp = resp_buf[0..total_read];

    // Parse status code from first line: "HTTP/1.1 200 OK\r\n"
    var status: u16 = 0;
    if (resp.len > 12 and std.mem.startsWith(u8, resp, "HTTP/")) {
        // Find space after version
        if (std.mem.indexOfScalar(u8, resp[0..@min(resp.len, 20)], ' ')) |sp| {
            if (sp + 3 < resp.len) {
                status = std.fmt.parseInt(u16, resp[sp + 1 .. sp + 4], 10) catch 0;
            }
        }
    }

    // Find body after \r\n\r\n
    if (std.mem.indexOf(u8, resp, "\r\n\r\n")) |hdr_end| {
        const body_slice = resp[hdr_end + 4 ..];
        const body_copy = alloc.dupe(u8, body_slice) catch return null;
        return .{ .status = status, .body = body_copy };
    }

    // No body separator found — return empty body
    const empty = alloc.alloc(u8, 0) catch return null;
    return .{ .status = status, .body = empty };
}

fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    var file = compat.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    return file.readToEndAlloc(alloc, 1024 * 1024) catch null;
}

/// Build a CoverageReport from the fragment in {art_dir}/fragment/.
/// Returns null if directory is missing, empty, or cannot be parsed.
fn buildFragmentCoverageReport(alloc: std.mem.Allocator, art_dir: []const u8) ?fragment_coverage.CoverageReport {
    var frag_dir_buf: [512]u8 = undefined;
    const frag_dir = std.fmt.bufPrint(&frag_dir_buf, "{s}/fragment", .{art_dir}) catch return null;

    var dir = compat.fs.cwd().openDir(frag_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    // Collect sequence numbers from .header.cbor files
    var seqs: [2560]u32 = undefined;
    var seq_count: u32 = 0;
    {
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (entry.name.len >= 20 and std.mem.endsWith(u8, entry.name, ".header.cbor")) {
                const seq = std.fmt.parseInt(u32, entry.name[0..8], 10) catch continue;
                if (seq_count < seqs.len) {
                    seqs[seq_count] = seq;
                    seq_count += 1;
                }
            }
        }
    }
    if (seq_count == 0) return null;

    std.mem.sort(u32, seqs[0..seq_count], {}, std.sort.asc(u32));

    const infos = alloc.alloc(fragment_coverage.FragmentSlotInfo, seq_count) catch return null;
    defer alloc.free(infos);
    var loaded: usize = 0;

    for (seqs[0..seq_count]) |seq| {
        var seq_buf: [8]u8 = undefined;
        const seq_str = std.fmt.bufPrint(&seq_buf, "{d:0>8}", .{seq}) catch continue;

        // Read hash.hex
        var hash_path_buf: [512]u8 = undefined;
        const hash_path = std.fmt.bufPrint(&hash_path_buf, "{s}/{s}.hash.hex", .{ frag_dir, seq_str }) catch continue;
        const hash_data = readFileAlloc(alloc, hash_path) orelse continue;
        defer alloc.free(hash_data);
        const trimmed = std.mem.trim(u8, hash_data, " \t\r\n");
        var entry_hash: [32]u8 = undefined;
        if (trimmed.len != 64 or !sealTipParseHex(trimmed, &entry_hash)) continue;

        // Read header CBOR for slot and prev_hash
        var hdr_path_buf: [512]u8 = undefined;
        const hdr_path = std.fmt.bufPrint(&hdr_path_buf, "{s}/{s}.header.cbor", .{ frag_dir, seq_str }) catch continue;
        const header_cbor = readFileAlloc(alloc, hdr_path) orelse continue;
        defer alloc.free(header_cbor);
        const fields = chainsync_server.ChainSyncServer.parseHeaderFields(alloc, header_cbor) orelse continue;

        infos[loaded] = .{
            .slot = fields.slot,
            .hash = entry_hash,
            .prev_hash = fields.prev_hash orelse [_]u8{0} ** 32,
        };
        loaded += 1;
    }

    if (loaded == 0) return null;

    return fragment_coverage.analyzeFragment(infos[0..loaded], seq_count);
}

fn sealTipParseHex(hex: []const u8, out: *[32]u8) bool {
    if (hex.len != 64) return false;
    var byte_idx: usize = 0;
    var char_idx: usize = 0;
    while (char_idx + 1 < 64) : ({
        char_idx += 2;
        byte_idx += 1;
    }) {
        const hi = sealTipHexVal(hex[char_idx]) orelse return false;
        const lo = sealTipHexVal(hex[char_idx + 1]) orelse return false;
        out[byte_idx] = (@as(u8, hi) << 4) | @as(u8, lo);
    }
    return true;
}

fn sealTipHexVal(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    return null;
}

/// Extract cborHex value from TextEnvelope JSON string.
/// Finds "cborHex" key and extracts the hex string value.
fn extractCborHex(data: []const u8) ?[]const u8 {
    // Find "cborHex" (with quotes)
    const key = "\"cborHex\"";
    const key_pos = std.mem.indexOf(u8, data, key) orelse return null;
    var pos = key_pos + key.len;

    // Skip whitespace and colon
    while (pos < data.len and (data[pos] == ' ' or data[pos] == ':' or data[pos] == '\t' or data[pos] == '\n' or data[pos] == '\r')) {
        pos += 1;
    }

    // Expect opening quote
    if (pos >= data.len or data[pos] != '"') return null;
    pos += 1;

    // Find closing quote
    const start = pos;
    while (pos < data.len and data[pos] != '"') {
        pos += 1;
    }
    if (pos >= data.len) return null;

    return data[start..pos];
}

/// Decode hex string to bytes.
fn hexDecode(alloc: std.mem.Allocator, hex: []const u8) ?[]u8 {
    if (hex.len % 2 != 0) return null;
    const out = alloc.alloc(u8, hex.len / 2) catch return null;
    for (0..out.len) |i| {
        const hi: u8 = @intCast(hexVal(hex[i * 2]) orelse {
            alloc.free(out);
            return null;
        });
        const lo: u8 = @intCast(hexVal(hex[i * 2 + 1]) orelse {
            alloc.free(out);
            return null;
        });
        out[i] = (hi << 4) | lo;
    }
    return out;
}

fn hexVal(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    return null;
}

/// Extract integer value from std.json.Value
fn jsonInt(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

/// Get a nested integer: root.get(obj_key).object.get(field_key) as integer
fn getNestedInt(root: std.json.ObjectMap, obj_key: []const u8, field_key: []const u8) ?i64 {
    const obj_val = root.get(obj_key) orelse return null;
    if (obj_val != .object) return null;
    const field_val = obj_val.object.get(field_key) orelse return null;
    return jsonInt(field_val);
}

/// Fetch and parse /state with retry logic (3 attempts, 300ms between).
/// Uses .alloc_always so the parsed tree owns all strings and does not
/// reference the (freed) HTTP response body.
fn fetchStateParsed(alloc: std.mem.Allocator, port: u16) ?std.json.Parsed(std.json.Value) {
    var attempt: u8 = 0;
    var last_body_len: usize = 0;
    var last_body_preview: [80]u8 = undefined;
    var last_preview_len: usize = 0;
    while (attempt < 3) : (attempt += 1) {
        if (attempt > 0) compat.sleep(300 * std.time.ns_per_ms);
        const resp = httpGet(alloc, port, "/state") orelse continue;
        defer alloc.free(resp.body);
        if (resp.status < 200 or resp.status >= 300) continue;
        last_body_len = resp.body.len;
        const preview_n = @min(resp.body.len, last_body_preview.len);
        @memcpy(last_body_preview[0..preview_n], resp.body[0..preview_n]);
        last_preview_len = preview_n;
        return std.json.parseFromSlice(
            std.json.Value,
            alloc,
            resp.body,
            .{ .allocate = .alloc_always },
        ) catch continue;
    }
    // All retries exhausted — print bounded diagnostic and return null.
    // Sanitize preview: replace control chars with '.'.
    for (last_body_preview[0..last_preview_len]) |*c| {
        if (c.* < 0x20) c.* = '.';
    }
    std.debug.print("  FAIL  /state parse (len={d}, preview={s})\n", .{
        last_body_len,
        last_body_preview[0..last_preview_len],
    });
    std.debug.print("\nABORT: cannot parse /state after 3 attempts\n", .{});
    return null;
}

/// Extract integer value from raw JSON by key prefix (e.g. "\"slot\":")
fn forgeExtractJsonInt(data: []const u8, key: []const u8) ?i64 {
    const pos = std.mem.indexOf(u8, data, key) orelse return null;
    const start = pos + key.len;
    if (start >= data.len) return null;
    var end = start;
    while (end < data.len and ((data[end] >= '0' and data[end] <= '9') or data[end] == '-')) : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(i64, data[start..end], 10) catch null;
}

/// Extract string value from raw JSON by key prefix (e.g. "\"net\":\"")
fn forgeExtractJsonStr(data: []const u8, key: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, data, key) orelse return null;
    const start = pos + key.len;
    if (start >= data.len) return null;
    const end = std.mem.indexOfPos(u8, data, start, "\"") orelse return null;
    return data[start..end];
}

/// FakeArgs to pass synthetic arguments to block_candidate_verify_cmd.run()
const FakeArgs = struct {
    items: []const []const u8,
    idx: usize = 0,

    pub fn next(self: *FakeArgs) ?[]const u8 {
        if (self.idx >= self.items.len) return null;
        defer self.idx += 1;
        return self.items[self.idx];
    }
};

/// Locate a script in the repo's scripts/ directory.
/// Search order: (1) $HOME/src/tsunagi-follower/scripts/<name>
fn findScript(alloc: std.mem.Allocator, name: []const u8) ?[]u8 {
    const home = compat.getEnvVarOwned(alloc, "HOME") catch return null;
    defer alloc.free(home);
    const path = std.fmt.allocPrint(alloc, "{s}/src/tsunagi-follower/scripts/{s}", .{ home, name }) catch return null;
    // Verify it exists
    compat.fs.cwd().access(path, .{}) catch {
        alloc.free(path);
        return null;
    };
    return path;
}

/// Find the latest .zip file in a directory by name (lexicographic sort = latest timestamp)
fn findLatestBundleZip(alloc: std.mem.Allocator, dir_path: []const u8) ?[]u8 {
    var dir = compat.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return null;
    defer dir.close();

    var latest_name: ?[]u8 = null;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zip")) continue;
        if (latest_name == null) {
            latest_name = alloc.dupe(u8, entry.name) catch continue;
        } else {
            if (std.mem.order(u8, entry.name, latest_name.?) == .gt) {
                alloc.free(latest_name.?);
                latest_name = alloc.dupe(u8, entry.name) catch continue;
            }
        }
    }

    if (latest_name) |name| {
        const full = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, name }) catch {
            alloc.free(name);
            return null;
        };
        alloc.free(name);
        return full;
    }
    return null;
}

/// Resolve home directory — fail-closed, no guessing.
/// Order: 1) explicit --home  2) $TSUNAGI_HOME  3) --net -> ~/tsunagi-home-<net>
///        4) --port -> infer net -> ~/tsunagi-home-<net>  5) null (caller errors)
fn resolveSealHome(
    alloc: std.mem.Allocator,
    home_path: ?[]const u8,
    net_name: ?[]const u8,
    port_num: ?u16,
    resolved_net: *[]const u8,
) ?[]const u8 {
    // 1) Explicit --home
    if (home_path) |hp| {
        // Try to infer net from path suffix for display
        if (net_name) |n| {
            resolved_net.* = n;
        } else if (std.mem.endsWith(u8, hp, "-preview")) {
            resolved_net.* = "preview";
        } else if (std.mem.endsWith(u8, hp, "-mainnet")) {
            resolved_net.* = "mainnet";
        } else if (std.mem.endsWith(u8, hp, "-sancho")) {
            resolved_net.* = "sancho";
        }
        return hp;
    }

    // 2) $TSUNAGI_HOME
    if (compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null) |env_home| {
        if (net_name) |n| {
            resolved_net.* = n;
        } else {
            resolved_net.* = inferNetFromPath(env_home);
        }
        return env_home;
    }

    // 3) --net -> ~/tsunagi-home-<net>
    if (net_name) |net| {
        resolved_net.* = net;
        return homeFromNet(alloc, net);
    }

    // 4) --port -> infer net -> ~/tsunagi-home-<net>
    if (port_num) |port| {
        const inferred: ?[]const u8 = switch (port) {
            9080 => "mainnet",
            9081 => "preview",
            9082 => "sancho",
            else => null,
        };
        if (inferred) |net| {
            resolved_net.* = net;
            return homeFromNet(alloc, net);
        }
    }

    // 5) No unambiguous signal — refuse
    return null;
}

fn inferNetFromPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, "-preview")) return "preview";
    if (std.mem.endsWith(u8, path, "-mainnet")) return "mainnet";
    if (std.mem.endsWith(u8, path, "-sancho")) return "sancho";
    // ~/tsunagi-home (no suffix) is mainnet by convention
    if (std.mem.endsWith(u8, path, "tsunagi-home")) return "mainnet";
    return "(unknown)";
}

fn homeFromNet(alloc: std.mem.Allocator, net: []const u8) ?[]const u8 {
    const user_home = compat.getEnvVarOwned(alloc, "HOME") catch return null;
    defer alloc.free(user_home);
    const path = std.fmt.allocPrint(alloc, "{s}/tsunagi-home-{s}", .{ user_home, net }) catch return null;
    compat.fs.cwd().access(path, .{}) catch {
        std.debug.print("ERROR: inferred home does not exist: {s}\n", .{path});
        alloc.free(path);
        return null;
    };
    return path;
}

/// Copy the required propagation files from source dir to dest dir.
/// Creates dest dir if needed. Overwrites existing files.
fn copyArtifactDir(alloc: std.mem.Allocator, src_dir: []const u8, dest_dir: []const u8) void {
    // Create dest dir (ok if exists)
    compat.fs.cwd().makePath(dest_dir) catch |err| {
        std.debug.print("seal-latest: cannot create {s}: {}\n", .{ dest_dir, err });
        return;
    };
    const files = [_][]const u8{
        "block_header.cbor",
        "header.cbor",
        "block.cbor",
        "meta.json",
        "header_hash.hex",
        "block_header_hash.hex",
        "header_body.cbor",
        "verify.json",
        "signature.bin",
    };
    var copied: u32 = 0;
    for (&files) |name| {
        const src_path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ src_dir, name }) catch continue;
        defer alloc.free(src_path);
        const dst_path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dest_dir, name }) catch continue;
        defer alloc.free(dst_path);
        const data = readFileAlloc(alloc, src_path) orelse continue;
        defer alloc.free(data);
        var f = compat.fs.cwd().createFile(dst_path, .{ .truncate = true }) catch continue;
        defer f.close();
        f.writeAll(data) catch continue;
        copied += 1;
    }
    std.debug.print("seal-latest: copied {d}/{d} files to {s}\n", .{ copied, files.len, dest_dir });
}

/// Find the latest block candidate directory by name (lexicographic sort = latest timestamp)
fn findLatestBlockDir(alloc: std.mem.Allocator, blocks_dir_path: []const u8) ?[]u8 {
    var dir = compat.fs.cwd().openDir(blocks_dir_path, .{ .iterate = true }) catch return null;
    defer dir.close();

    var latest_name: ?[]u8 = null;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (latest_name == null) {
            latest_name = alloc.dupe(u8, entry.name) catch continue;
        } else {
            if (std.mem.order(u8, entry.name, latest_name.?) == .gt) {
                alloc.free(latest_name.?);
                latest_name = alloc.dupe(u8, entry.name) catch continue;
            }
        }
    }

    if (latest_name) |name| {
        const full = std.fmt.allocPrint(alloc, "{s}/{s}", .{ blocks_dir_path, name }) catch {
            alloc.free(name);
            return null;
        };
        alloc.free(name);
        return full;
    }
    return null;
}

/// Check if a systemd user service is active.
fn isServiceActive(alloc: std.mem.Allocator, service: []const u8) bool {
    const args = [_][]const u8{ "systemctl", "--user", "is-active", service };
    var child = compat.Child.init(&args, alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = child.spawnAndWait() catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Run a command and capture its stdout into a buffer.
fn runCapture(alloc: std.mem.Allocator, argv: []const []const u8, buf: []u8) ?usize {
    var child = compat.Child.init(argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;
    var total: usize = 0;
    if (child.stdout) |stdout| {
        while (total < buf.len) {
            const n = stdout.read(buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
    }
    _ = child.wait() catch {};
    return total;
}

// ── forge-arm ───────────────────────────────────────────────────────

fn runForgeArm(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var port: u16 = DEFAULT_PORT;
    var home_path: ?[]const u8 = null;
    var confirmed = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --port requires a number\n", .{});
                return 1;
            };
            port = std.fmt.parseInt(u16, val, 10) catch {
                std.debug.print("ERROR: invalid port: {s}\n", .{val});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--home")) {
            home_path = args_it.next() orelse {
                std.debug.print("ERROR: --home requires a path\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--i-know-what-im-doing")) {
            confirmed = true;
        } else {
            std.debug.print("ERROR: unknown forge-arm flag: {s}\n", .{arg});
            return 1;
        }
    }

    if (!confirmed) {
        std.debug.print("ERROR: forge-arm requires --i-know-what-im-doing flag\n", .{});
        std.debug.print("Usage: tsunagi-node guardian forge-arm --port <N> --i-know-what-im-doing [--home <path>]\n", .{});
        return 1;
    }

    std.debug.print("=== Forge Arm — Pre-flight Checks ===\n", .{});
    var doc_pass: u32 = 0;
    var doc_fail: u32 = 0;

    // Check 1: Node reachable (with retry for transient TCP drops)
    {
        const resp = httpGetRetry(alloc, port, "/health");
        if (resp != null) {
            alloc.free(resp.?.body);
            if (resp.?.status == 200) {
                doc_pass += 1;
                std.debug.print("  PASS  Node reachable\n", .{});
            } else {
                doc_fail += 1;
                std.debug.print("  FAIL  Node reachable (HTTP {d})\n", .{resp.?.status});
            }
        } else {
            doc_fail += 1;
            std.debug.print("  FAIL  Node reachable (connection refused)\n", .{});
            std.debug.print("\nABORT: node not reachable\n", .{});
            return 1;
        }
    }

    // Get /state for checks 2-8 (with retry + alloc_always to avoid use-after-free)
    // If static readiness is present but dynamic fields are still zero (startup gap),
    // retry for up to ~15s to let the first producer tick populate them.
    var state_json: ?std.json.Parsed(std.json.Value) = null;
    defer if (state_json != null) state_json.?.deinit();
    {
        var ready_attempt: u8 = 0;
        while (ready_attempt < 6) : (ready_attempt += 1) {
            if (ready_attempt > 0) {
                if (state_json != null) state_json.?.deinit();
                state_json = null;
                compat.sleep(3 * std.time.ns_per_s);
                std.debug.print("  ...  waiting for dynamic producer readiness ({d}/6)\n", .{ready_attempt + 1});
            }
            state_json = fetchStateParsed(alloc, port);
            if (state_json == null) break;
            const r = state_json.?.value.object;
            // Check: static readiness present
            const keys_en = getNestedInt(r, "producer_keys", "enabled") orelse 0;
            const vrf_en = getNestedInt(r, "producer_vrf", "enabled") orelse 0;
            if (keys_en != 1 or vrf_en != 1) break; // not a startup gap — static not ready
            // Check: dynamic fields populated
            const kes_ok = getNestedInt(r, "producer_keys", "kes_ok") orelse 0;
            const vrf_ok = getNestedInt(r, "producer_keys", "vrf_ok") orelse 0;
            const period_valid = getNestedInt(r, "producer_kes_period", "period_valid_last") orelse 0;
            if (kes_ok == 1 and vrf_ok == 1 and period_valid == 1) break; // dynamic ready
            // Dynamic not yet populated — retry
        }
    }
    if (state_json == null) return 1;
    const root = state_json.?.value.object;

    // Check 2: Tip advancing
    {
        var tip_slot: ?i64 = null;
        if (root.get("tip")) |tip| {
            if (tip == .object) {
                if (tip.object.get("slot")) |v| {
                    tip_slot = jsonInt(v);
                }
            }
        }
        if (tip_slot != null and tip_slot.? > 0) {
            doc_pass += 1;
            std.debug.print("  PASS  Tip advancing (slot={d})\n", .{tip_slot.?});
        } else {
            doc_fail += 1;
            std.debug.print("  FAIL  Tip advancing\n", .{});
        }
    }

    // Check 3: KES keys loaded
    {
        const kes_ok = getNestedInt(root, "producer_keys", "kes_ok");
        if (kes_ok != null and kes_ok.? == 1) {
            doc_pass += 1;
            std.debug.print("  PASS  KES keys loaded\n", .{});
        } else {
            doc_fail += 1;
            std.debug.print("  FAIL  KES keys loaded\n", .{});
        }
    }

    // Check 4: VRF keys loaded
    {
        const vrf_ok = getNestedInt(root, "producer_keys", "vrf_ok");
        if (vrf_ok != null and vrf_ok.? == 1) {
            doc_pass += 1;
            std.debug.print("  PASS  VRF keys loaded\n", .{});
        } else {
            doc_fail += 1;
            std.debug.print("  FAIL  VRF keys loaded\n", .{});
        }
    }

    // Check 5: KES period valid
    {
        const kes_valid = getNestedInt(root, "producer_kes_period", "period_valid_last");
        if (kes_valid != null and kes_valid.? == 1) {
            doc_pass += 1;
            std.debug.print("  PASS  KES period valid\n", .{});
        } else {
            doc_fail += 1;
            std.debug.print("  FAIL  KES period valid\n", .{});
            std.debug.print("\nABORT: KES period invalid — cannot arm forge\n", .{});
            return 1;
        }
    }

    // Check 6: Dryrun enabled
    {
        const dryrun = getNestedInt(root, "producer_dryrun", "enabled");
        if (dryrun != null and dryrun.? == 1) {
            doc_pass += 1;
            std.debug.print("  PASS  Dryrun enabled\n", .{});
        } else {
            doc_fail += 1;
            std.debug.print("  FAIL  Dryrun enabled\n", .{});
        }
    }

    // Check 7: Clock OK (warn-only — clock sync may lag on preview)
    {
        const clock_ok = getNestedInt(root, "producer_clock", "clock_ok");
        if (clock_ok != null and clock_ok.? == 1) {
            doc_pass += 1;
            std.debug.print("  PASS  Clock OK\n", .{});
        } else {
            doc_pass += 1;
            std.debug.print("  WARN  Clock OK (not fatal for forge-arm)\n", .{});
        }
    }

    // Check 8: Mempool accessible
    {
        const resp = httpGetRetry(alloc, port, "/mempool");
        if (resp != null) {
            alloc.free(resp.?.body);
            if (resp.?.status >= 200 and resp.?.status < 300) {
                doc_pass += 1;
                std.debug.print("  PASS  Mempool accessible\n", .{});
            } else {
                doc_fail += 1;
                std.debug.print("  FAIL  Mempool accessible (HTTP {d})\n", .{resp.?.status});
            }
        } else {
            doc_fail += 1;
            std.debug.print("  FAIL  Mempool accessible\n", .{});
        }
    }

    // Check 9: Broadcast OFF
    {
        const bcast = compat.getEnvVarOwned(alloc, "TSUNAGI_TXSUB_BROADCAST") catch null;
        if (bcast) |val| {
            defer alloc.free(val);
            if (std.mem.eql(u8, val, "1")) {
                doc_fail += 1;
                std.debug.print("  FAIL  Broadcast OFF (TSUNAGI_TXSUB_BROADCAST=1)\n", .{});
                std.debug.print("\nABORT: broadcast is ON — cannot arm forge\n", .{});
                return 1;
            }
        }
        doc_pass += 1;
        std.debug.print("  PASS  Broadcast OFF\n", .{});
    }

    // Check 10: Network is preview (with retry for transient TCP/parse issues)
    {
        var is_preview = false;
        var status_attempt: u8 = 0;
        while (status_attempt < 3) : (status_attempt += 1) {
            if (status_attempt > 0) compat.sleep(300 * std.time.ns_per_ms);
            const resp = httpGet(alloc, port, "/status") orelse continue;
            defer alloc.free(resp.body);
            if (resp.status < 200 or resp.status >= 300) continue;
            const sp = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{ .allocate = .alloc_always }) catch continue;
            defer sp.deinit();
            if (sp.value == .object) {
                if (sp.value.object.get("net")) |v| {
                    if (v == .string) {
                        is_preview = std.mem.eql(u8, v.string, "preview");
                        break;
                    }
                }
            }
        }
        if (is_preview) {
            doc_pass += 1;
            std.debug.print("  PASS  Network is preview\n", .{});
        } else {
            doc_fail += 1;
            std.debug.print("  FAIL  Network is preview\n", .{});
            std.debug.print("\nABORT: not preview network — cannot arm forge\n", .{});
            return 1;
        }
    }

    if (doc_fail > 0) {
        std.debug.print("\n{d} pre-flight checks failed — aborting\n", .{doc_fail});
        return 1;
    }
    std.debug.print("\nAll pre-flight checks passed ({d}/{d})\n", .{ doc_pass, doc_pass });

    // Resolve home
    var home_owned = false;
    const home = if (home_path) |hp| hp else blk: {
        const env_home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
        if (env_home) |h| {
            home_owned = true;
            break :blk h;
        }
        break :blk @as(?[]const u8, null);
    };
    if (home == null) {
        std.debug.print("ERROR: --home or TSUNAGI_HOME required\n", .{});
        return 1;
    }
    defer if (home_owned) alloc.free(home.?);

    // Create guardian dir if needed
    {
        var gdir_buf: [512]u8 = undefined;
        const gdir = std.fmt.bufPrint(&gdir_buf, "{s}/guardian", .{home.?}) catch {
            std.debug.print("ERROR: path too long\n", .{});
            return 1;
        };
        compat.fs.cwd().makePath(gdir) catch {};
    }

    // Generate nonce (16 random bytes → 32 hex chars)
    var nonce_bytes: [16]u8 = undefined;
    compat.cryptoRandomBytes(&nonce_bytes);
    const nonce_hex = std.fmt.bytesToHex(nonce_bytes, .lower);

    // Current unix timestamp
    const now_unix: i64 = compat.timestamp();

    // Build token path
    var arm_path_buf: [512]u8 = undefined;
    const arm_path = std.fmt.bufPrint(&arm_path_buf, "{s}/guardian/forge_arm.json", .{home.?}) catch {
        std.debug.print("ERROR: path too long\n", .{});
        return 1;
    };

    // Write token JSON
    var token_buf: [512]u8 = undefined;
    const token_json = std.fmt.bufPrint(&token_buf,
        \\{{"armed_at_unix":{d},"net":"preview","home":"{s}","nonce":"{s}","safety":["broadcast_off","kes_valid","doctor_pass","preview_only"]}}
    , .{ now_unix, home.?, @as([]const u8, &nonce_hex) }) catch {
        std.debug.print("ERROR: token buffer overflow\n", .{});
        return 1;
    };

    var out_file = compat.fs.cwd().createFile(arm_path, .{ .truncate = true }) catch {
        std.debug.print("ERROR: cannot write {s}\n", .{arm_path});
        return 1;
    };
    defer out_file.close();
    out_file.writeAll(token_json) catch {
        std.debug.print("ERROR: write failed\n", .{});
        return 1;
    };

    std.debug.print("\nForge arming token written:\n", .{});
    std.debug.print("  path:  {s}\n", .{arm_path});
    std.debug.print("  nonce: {s}\n", .{@as([]const u8, &nonce_hex)});
    std.debug.print("  TTL:   10 minutes\n", .{});
    std.debug.print("\nThe producer will consume this token on the next leader slot.\n", .{});

    return 0;
}

/// Run a command and capture its stderr into a buffer.
fn runCaptureStderr(alloc: std.mem.Allocator, argv: []const []const u8, buf: []u8) ?usize {
    var child = compat.Child.init(argv, alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    child.spawn() catch return null;
    var total: usize = 0;
    if (child.stderr) |se| {
        while (total < buf.len) {
            const n = se.read(buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
    }
    _ = child.wait() catch {};
    return total;
}

// ── KURA (蔵) retention + safe pruning ──────────────────────────────

const KuraPolicy = struct {
    keep_captures: u64 = 4,
    keep_blocks: u64 = 50,
    keep_candidates: u64 = 50,
    keep_bundles: u64 = 30,
    keep_snapshots: u64 = 5,
    max_forge_dirs: u64 = 999999,
    rotate_yamori_mb: u64 = 1,
    prune_gaps: bool = false,
    i_know: bool = false,
    apply: bool = false,
};

const KuraTarget = struct {
    label: []const u8,
    rel_path: []const u8,
    is_dir_entries: bool,
};

const KURA_TARGETS = [_]KuraTarget{
    .{ .label = "captures", .rel_path = "captures", .is_dir_entries = false },
    .{ .label = "blocks", .rel_path = "producer_dryrun/blocks", .is_dir_entries = true },
    .{ .label = "candidates", .rel_path = "producer_dryrun/candidates", .is_dir_entries = true },
    .{ .label = "bundles", .rel_path = "producer_dryrun/blocks_proof_bundles", .is_dir_entries = false },
    .{ .label = "forge_sim", .rel_path = "producer_forge_sim", .is_dir_entries = true },
    .{ .label = "snapshots", .rel_path = "ledger_snapshots", .is_dir_entries = false },
    .{ .label = "gaps", .rel_path = "gaps", .is_dir_entries = false },
    .{ .label = "harness", .rel_path = "ledger_harness", .is_dir_entries = false },
    .{ .label = "fork_readiness", .rel_path = "regress/fork_readiness", .is_dir_entries = true },
};

const Candidate = struct {
    rel_path_buf: [512]u8 = undefined,
    rel_path_len: usize = 0,
    bytes: u64 = 0,
    is_dir: bool = false,

    fn relPath(self: *const Candidate) []const u8 {
        return self.rel_path_buf[0..self.rel_path_len];
    }
};

fn runKura(alloc: std.mem.Allocator, args_it: anytype) u8 {
    const subcmd = args_it.next() orelse {
        kuraPrintUsage();
        return 1;
    };

    if (std.mem.eql(u8, subcmd, "scan")) return runKuraScan(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "plan")) return runKuraPlan(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "apply")) return runKuraApply(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "revert")) return runKuraRevert(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "doctor")) return runKuraDoctor(alloc, args_it);
    if (std.mem.eql(u8, subcmd, "stabilize")) return runKuraStabilize(alloc, args_it);

    std.debug.print("ERROR: unknown kura subcommand: {s}\n", .{subcmd});
    kuraPrintUsage();
    return 1;
}

fn kuraPrintUsage() void {
    std.debug.print(
        \\KURA (蔵) — retention + safe pruning (disk hygiene)
        \\
        \\Usage:
        \\  tsunagi-node guardian kura <subcommand> [options]
        \\
        \\Subcommands:
        \\  scan           Show disk usage per target directory (read-only)
        \\  plan           Compute deletion candidates and write plan JSON
        \\  apply          Execute plan (requires --apply flag)
        \\  revert         Remove plan/apply metadata (data not recoverable)
        \\  doctor         Health checks on target directories (read-only)
        \\  stabilize      Evaluate artifact health and reseal if needed
        \\
        \\Options:
        \\  --home <P>              TSUNAGI_HOME override (required)
        \\  --keep-captures <N>     Captures to keep (default: 4)
        \\  --keep-blocks <N>       Dryrun block dirs to keep (default: 50)
        \\  --keep-candidates <N>   Candidate dirs to keep (default: 50)
        \\  --keep-bundles <N>      Proof bundle zips to keep (default: 30)
        \\  --keep-snapshots <N>    Ledger snapshots to keep (default: 5)
        \\  --max-forge-dirs <N>    Forge sim dirs to keep (default: unlimited)
        \\  --rotate-yamori-mb <N>  Yamori event log rotation threshold MB (default: 1)
        \\  --prune-gaps            Enable gap file pruning (off by default)
        \\  --i-know-what-im-doing  Required for --prune-gaps
        \\  --apply                 Required for apply subcommand to actually delete
        \\
    , .{});
}

// ── shared helpers ──────────────────────────────────────────────────

const KuraHome = struct {
    home: []const u8,
    owned: bool,
};

fn resolveKuraHome(alloc: std.mem.Allocator, args_it: anytype) ?KuraHome {
    var home_path: ?[]const u8 = null;
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--home")) {
            home_path = args_it.next();
        }
    }
    if (home_path) |hp| return .{ .home = hp, .owned = false };
    const env_home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
    if (env_home) |h| return .{ .home = h, .owned = true };
    std.debug.print("ERROR: --home or TSUNAGI_HOME required\n", .{});
    return null;
}

fn parseKuraArgs(args_it: anytype) struct { home_path: ?[]const u8, policy: KuraPolicy } {
    var home_path: ?[]const u8 = null;
    var policy = KuraPolicy{};

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--home")) {
            home_path = args_it.next();
        } else if (std.mem.eql(u8, arg, "--keep-captures")) {
            if (args_it.next()) |v| policy.keep_captures = std.fmt.parseInt(u64, v, 10) catch 4;
        } else if (std.mem.eql(u8, arg, "--keep-blocks")) {
            if (args_it.next()) |v| policy.keep_blocks = std.fmt.parseInt(u64, v, 10) catch 50;
        } else if (std.mem.eql(u8, arg, "--keep-candidates")) {
            if (args_it.next()) |v| policy.keep_candidates = std.fmt.parseInt(u64, v, 10) catch 50;
        } else if (std.mem.eql(u8, arg, "--keep-bundles")) {
            if (args_it.next()) |v| policy.keep_bundles = std.fmt.parseInt(u64, v, 10) catch 30;
        } else if (std.mem.eql(u8, arg, "--keep-snapshots")) {
            if (args_it.next()) |v| policy.keep_snapshots = std.fmt.parseInt(u64, v, 10) catch 5;
        } else if (std.mem.eql(u8, arg, "--max-forge-dirs")) {
            if (args_it.next()) |v| policy.max_forge_dirs = std.fmt.parseInt(u64, v, 10) catch 999999;
        } else if (std.mem.eql(u8, arg, "--rotate-yamori-mb")) {
            if (args_it.next()) |v| policy.rotate_yamori_mb = std.fmt.parseInt(u64, v, 10) catch 1;
        } else if (std.mem.eql(u8, arg, "--prune-gaps")) {
            policy.prune_gaps = true;
        } else if (std.mem.eql(u8, arg, "--i-know-what-im-doing")) {
            policy.i_know = true;
        } else if (std.mem.eql(u8, arg, "--apply")) {
            policy.apply = true;
        }
    }
    return .{ .home_path = home_path, .policy = policy };
}

fn resolveHome(alloc: std.mem.Allocator, home_path: ?[]const u8) ?KuraHome {
    if (home_path) |hp| return .{ .home = hp, .owned = false };
    const env_home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
    if (env_home) |h| return .{ .home = h, .owned = true };
    std.debug.print("ERROR: --home or TSUNAGI_HOME required\n", .{});
    return null;
}

fn isPathSafe(home: []const u8, candidate: []const u8) bool {
    // Refuse if candidate contains ".."
    var i: usize = 0;
    while (i + 1 < candidate.len) : (i += 1) {
        if (candidate[i] == '.' and candidate[i + 1] == '.') return false;
    }
    // Verify candidate path starts with home prefix
    if (!std.mem.startsWith(u8, candidate, home)) return false;
    return true;
}

fn formatBytes(bytes: u64, buf: []u8) []const u8 {
    if (bytes >= 1_048_576) {
        return std.fmt.bufPrint(buf, "{d}.{d}M", .{
            bytes / 1_048_576,
            (bytes % 1_048_576) * 10 / 1_048_576,
        }) catch "???";
    } else if (bytes >= 1024) {
        return std.fmt.bufPrint(buf, "{d}.{d}K", .{
            bytes / 1024,
            (bytes % 1024) * 10 / 1024,
        }) catch "???";
    } else {
        return std.fmt.bufPrint(buf, "{d}B", .{bytes}) catch "???";
    }
}

fn collectAndSortEntries(alloc: std.mem.Allocator, dir: *compat.fs.Dir, is_dir_entries: bool, symlink_count: *u64) std.array_list.Managed([]u8) {
    var names = std.array_list.Managed([]u8).init(alloc);
    var it = dir.iterate();
    while (it.next() catch null) |e| {
        if (e.kind == .sym_link) {
            symlink_count.* += 1;
            continue;
        }
        if (is_dir_entries and e.kind != .directory) continue;
        if (!is_dir_entries and e.kind != .file) continue;
        names.append(alloc.dupe(u8, e.name) catch continue) catch continue;
    }
    std.sort.insertion([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return names;
}

fn freeNameList(alloc: std.mem.Allocator, names: *std.array_list.Managed([]u8)) void {
    for (names.items) |s| alloc.free(s);
    names.deinit();
}

fn sumDirSize(dir: *compat.fs.Dir, name: []const u8, is_dir: bool) u64 {
    if (!is_dir) {
        const st = dir.statFile(name) catch return 0;
        return st.size;
    }
    // For directories, open and sum all files recursively (shallow = direct children)
    var subdir = dir.openDir(name, .{ .iterate = true }) catch return 0;
    defer subdir.close();
    var total: u64 = 0;
    var sub_it = subdir.iterate();
    while (sub_it.next() catch null) |e| {
        if (e.kind == .file) {
            const st = subdir.statFile(e.name) catch continue;
            total += st.size;
        }
    }
    return total;
}

// ── kura stabilize ──────────────────────────────────────────────────

fn runKuraStabilize(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var home_path: ?[]const u8 = null;
    var net_name: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--home")) {
            home_path = args_it.next() orelse {
                std.debug.print("ERROR: --home requires a path\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--net")) {
            net_name = args_it.next() orelse {
                std.debug.print("ERROR: --net requires a network name\n", .{});
                return 1;
            };
        } else {
            std.debug.print("ERROR: unknown flag: {s}\n", .{arg});
            return 1;
        }
    }

    // Resolve home (same precedence: --home > --net > TSUNAGI_HOME)
    var resolved_net: []const u8 = net_name orelse "(unknown)";
    const home = yamoriCheckResolveHome(alloc, home_path, net_name, &resolved_net) orelse {
        std.debug.print("ERROR: cannot resolve home. Use --home or --net or set TSUNAGI_HOME.\n", .{});
        return 1;
    };

    const now = compat.timestamp();

    // ── Read artifact metadata ──

    const art_dir = std.fmt.allocPrint(alloc, "{s}/propagation_artifact", .{home}) catch return 1;
    defer alloc.free(art_dir);

    const art_exists = blk: {
        compat.fs.cwd().access(art_dir, .{}) catch break :blk false;
        break :blk true;
    };

    if (!art_exists) {
        // No artifact at all — reseal needed
        std.debug.print("KURA STABILIZER\n", .{});
        std.debug.print("propagation artifact missing — forcing seal-tip\n", .{});
        return kuraRunSealTip(alloc, home, resolved_net);
    }

    // Read meta.json for artifact age
    var artifact_age: u64 = 0;
    {
        const meta_path = std.fmt.allocPrint(alloc, "{s}/meta.json", .{art_dir}) catch return 1;
        defer alloc.free(meta_path);
        if (readFileAlloc(alloc, meta_path)) |data| {
            defer alloc.free(data);
            if (yamoriParseJsonU64(data, "unix")) |unix_val| {
                const unix_i64: i64 = @intCast(unix_val);
                const age = now - unix_i64;
                artifact_age = if (age > 0) @intCast(age) else 0;
            }
        }
    }

    // Read cursor.json for tip slot
    var cursor_slot: u64 = 0;
    {
        const cursor_path = std.fmt.allocPrint(alloc, "{s}/cursor.json", .{home}) catch return 1;
        defer alloc.free(cursor_path);
        if (readFileAlloc(alloc, cursor_path)) |data| {
            defer alloc.free(data);
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{ .allocate = .alloc_always }) catch null;
            if (parsed) |p| {
                defer p.deinit();
                if (p.value == .object) {
                    if (p.value.object.get("slot")) |v| {
                        if (v == .integer and v.integer > 0) {
                            cursor_slot = @intCast(v.integer);
                        }
                    }
                }
            }
        }
    }

    // Read coverage.json
    var usable_depth: u64 = 0;
    var break_count: u64 = 0;
    var newest_slot: u64 = 0;
    {
        const cov_path = std.fmt.allocPrint(alloc, "{s}/coverage.json", .{art_dir}) catch return 1;
        defer alloc.free(cov_path);
        if (readFileAlloc(alloc, cov_path)) |data| {
            defer alloc.free(data);
            usable_depth = yamoriParseJsonU64(data, "usable_contiguous_depth") orelse 0;
            break_count = yamoriParseJsonU64(data, "break_count") orelse 0;
            newest_slot = yamoriParseJsonU64(data, "intersectable_newest_slot") orelse 0;
        }
    }

    // Compute gap
    const gap: u64 = if (cursor_slot > newest_slot) cursor_slot - newest_slot else 0;

    // ── Evaluate ──
    const action = kura_stabilizer.evaluate(.{
        .artifact_age_seconds = artifact_age,
        .tip_artifact_gap_slots = gap,
        .usable_depth = usable_depth,
        .break_count = break_count,
    });

    std.debug.print("KURA STABILIZER\n", .{});

    switch (action) {
        .none => {
            std.debug.print("artifact healthy — no action required\n", .{});
            return 0;
        },
        .reseal => {
            std.debug.print("artifact stale (age={d}s gap={d})\n", .{ artifact_age, gap });
            std.debug.print("resealing propagation artifact...\n", .{});
            return kuraRunSealTip(alloc, home, resolved_net);
        },
        .reseal_urgent => {
            std.debug.print("fragment ancestry break detected\n", .{});
            std.debug.print("forcing artifact reseal...\n", .{});
            return kuraRunSealTip(alloc, home, resolved_net);
        },
    }
}

/// Call runSealTip with pre-constructed arguments.
fn kuraRunSealTip(alloc: std.mem.Allocator, home: []const u8, net: []const u8) u8 {
    const args = [_][]const u8{ "--home", home, "--net", net };
    var it = StaticArgIterator{ .args = &args, .pos = 0 };
    return runSealTip(alloc, &it);
}

const StaticArgIterator = struct {
    args: []const []const u8,
    pos: usize,

    pub fn next(self: *StaticArgIterator) ?[]const u8 {
        if (self.pos >= self.args.len) return null;
        const val = self.args[self.pos];
        self.pos += 1;
        return val;
    }
};

// ── kura scan ───────────────────────────────────────────────────────

fn runKuraScan(alloc: std.mem.Allocator, args_it: anytype) u8 {
    const resolved = resolveKuraHome(alloc, args_it) orelse return 1;
    defer if (resolved.owned) alloc.free(resolved.home);
    const home = resolved.home;

    std.debug.print("=== KURA Scan ===\n", .{});
    std.debug.print("{s: <20} {s: >8} {s: >10}\n", .{ "target", "count", "bytes" });

    var grand_total: u64 = 0;
    var grand_count: u64 = 0;

    for (KURA_TARGETS) |tgt| {
        var path_buf: [512]u8 = undefined;
        const target_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, tgt.rel_path }) catch continue;
        var dir = compat.fs.cwd().openDir(target_path, .{ .iterate = true }) catch {
            std.debug.print("{s: <20} {s: >8} {s: >10}\n", .{ tgt.label, "-", "-" });
            continue;
        };
        defer dir.close();

        var count: u64 = 0;
        var total_bytes: u64 = 0;
        var symlinks: u64 = 0;

        var names = collectAndSortEntries(alloc, &dir, tgt.is_dir_entries, &symlinks);
        defer freeNameList(alloc, &names);

        for (names.items) |name| {
            count += 1;
            total_bytes += sumDirSize(&dir, name, tgt.is_dir_entries);
        }

        if (symlinks > 0) {
            std.debug.print("  WARN: {d} symlink(s) skipped in {s}\n", .{ symlinks, tgt.label });
        }

        var sz_buf: [32]u8 = undefined;
        const sz_str = formatBytes(total_bytes, &sz_buf);
        std.debug.print("{s: <20} {d: >8} {s: >10}\n", .{ tgt.label, count, sz_str });
        grand_total += total_bytes;
        grand_count += count;
    }

    // yamori_events.jsonl
    {
        var ev_buf: [512]u8 = undefined;
        const ev_path = std.fmt.bufPrint(&ev_buf, "{s}/guardian/yamori_events.jsonl", .{home}) catch "";
        if (ev_path.len > 0) {
            const st = compat.fs.cwd().statFile(ev_path) catch null;
            if (st) |s| {
                var sz_buf: [32]u8 = undefined;
                const sz_str = formatBytes(s.size, &sz_buf);
                std.debug.print("{s: <20} {d: >8} {s: >10}\n", .{ "yamori_events", @as(u64, 1), sz_str });
                grand_total += s.size;
                grand_count += 1;
            } else {
                std.debug.print("{s: <20} {s: >8} {s: >10}\n", .{ "yamori_events", "-", "-" });
            }
        }
    }

    var gt_buf: [32]u8 = undefined;
    const gt_str = formatBytes(grand_total, &gt_buf);
    std.debug.print("{s: <20} {d: >8} {s: >10}\n", .{ "TOTAL", grand_count, gt_str });
    return 0;
}

// ── kura plan ───────────────────────────────────────────────────────

fn runKuraPlan(alloc: std.mem.Allocator, args_it: anytype) u8 {
    const parsed = parseKuraArgs(args_it);
    const resolved = resolveHome(alloc, parsed.home_path) orelse return 1;
    defer if (resolved.owned) alloc.free(resolved.home);
    const home = resolved.home;
    const policy = parsed.policy;

    var candidates = std.array_list.Managed(Candidate).init(alloc);
    defer candidates.deinit();

    var yamori_rotate = false;

    // 1) captures — keep last N by count OR last 2 days, whichever keeps more
    {
        var path_buf: [512]u8 = undefined;
        const target_path = std.fmt.bufPrint(&path_buf, "{s}/captures", .{home}) catch "";
        if (target_path.len > 0) {
            planCaptures(alloc, &candidates, target_path, "captures", policy.keep_captures);
        }
    }

    // 2) blocks — protect bundle-referenced + newest 2 + keep last N
    {
        var path_buf: [512]u8 = undefined;
        const blocks_path = std.fmt.bufPrint(&path_buf, "{s}/producer_dryrun/blocks", .{home}) catch "";
        var bundles_path_buf: [512]u8 = undefined;
        const bundles_path = std.fmt.bufPrint(&bundles_path_buf, "{s}/producer_dryrun/blocks_proof_bundles", .{home}) catch "";
        if (blocks_path.len > 0) {
            planBlocks(alloc, &candidates, blocks_path, "producer_dryrun/blocks", bundles_path, policy.keep_blocks);
        }
    }

    // 3) candidates — keep last N
    {
        var path_buf: [512]u8 = undefined;
        const target_path = std.fmt.bufPrint(&path_buf, "{s}/producer_dryrun/candidates", .{home}) catch "";
        if (target_path.len > 0) {
            planSimple(alloc, &candidates, target_path, "producer_dryrun/candidates", policy.keep_candidates, true);
        }
    }

    // 4) bundles — protect newest 2 + SHA256SUMS, keep last N
    {
        var path_buf: [512]u8 = undefined;
        const target_path = std.fmt.bufPrint(&path_buf, "{s}/producer_dryrun/blocks_proof_bundles", .{home}) catch "";
        if (target_path.len > 0) {
            planBundles(alloc, &candidates, target_path, "producer_dryrun/blocks_proof_bundles", policy.keep_bundles);
        }
    }

    // 5) forge_sim — keep all unless max_forge_dirs overridden
    if (policy.max_forge_dirs < 999999) {
        var path_buf: [512]u8 = undefined;
        const target_path = std.fmt.bufPrint(&path_buf, "{s}/producer_forge_sim", .{home}) catch "";
        if (target_path.len > 0) {
            planSimple(alloc, &candidates, target_path, "producer_forge_sim", policy.max_forge_dirs, true);
        }
    }

    // 6) snapshots — keep last N
    {
        var path_buf: [512]u8 = undefined;
        const target_path = std.fmt.bufPrint(&path_buf, "{s}/ledger_snapshots", .{home}) catch "";
        if (target_path.len > 0) {
            planSimple(alloc, &candidates, target_path, "ledger_snapshots", policy.keep_snapshots, false);
        }
    }

    // 7) gaps — only if --prune-gaps
    if (policy.prune_gaps and policy.i_know) {
        var path_buf: [512]u8 = undefined;
        const target_path = std.fmt.bufPrint(&path_buf, "{s}/gaps", .{home}) catch "";
        if (target_path.len > 0) {
            planPruneAll(alloc, &candidates, target_path, "gaps", false);
        }
    } else if (policy.prune_gaps and !policy.i_know) {
        std.debug.print("WARN: --prune-gaps requires --i-know-what-im-doing\n", .{});
    }

    // 8) fork_readiness — keep last N (reuse keep_blocks policy)
    {
        var path_buf: [512]u8 = undefined;
        const target_path = std.fmt.bufPrint(&path_buf, "{s}/regress/fork_readiness", .{home}) catch "";
        if (target_path.len > 0) {
            planSimple(alloc, &candidates, target_path, "regress/fork_readiness", policy.keep_blocks, true);
        }
    }

    // 9) yamori_events.jsonl — check rotation threshold
    {
        var ev_buf: [512]u8 = undefined;
        const ev_path = std.fmt.bufPrint(&ev_buf, "{s}/guardian/yamori_events.jsonl", .{home}) catch "";
        if (ev_path.len > 0) {
            const st = compat.fs.cwd().statFile(ev_path) catch null;
            if (st) |s| {
                const threshold = policy.rotate_yamori_mb * 1_048_576;
                if (s.size > threshold) {
                    yamori_rotate = true;
                }
            }
        }
    }

    // Compute total bytes
    var total_bytes: u64 = 0;
    for (candidates.items) |c| total_bytes += c.bytes;

    // Ensure guardian dir
    var gdir_buf: [512]u8 = undefined;
    const gdir = std.fmt.bufPrint(&gdir_buf, "{s}/guardian", .{home}) catch {
        std.debug.print("ERROR: path too long\n", .{});
        return 1;
    };
    compat.fs.cwd().makePath(gdir) catch {};

    // Write plan JSON
    var plan_path_buf: [512]u8 = undefined;
    const plan_path = std.fmt.bufPrint(&plan_path_buf, "{s}/guardian/kura_plan.json", .{home}) catch {
        std.debug.print("ERROR: path too long\n", .{});
        return 1;
    };

    var json = std.array_list.Managed(u8).init(alloc);
    defer json.deinit();

    const now_unix: i64 = compat.timestamp();
    compat.listWriter(&json).print("{{\"unix\":{d},\"home\":\"{s}\",\"policy\":{{", .{ now_unix, home }) catch {
        std.debug.print("ERROR: JSON build failed\n", .{});
        return 1;
    };
    compat.listWriter(&json).print("\"keep_captures\":{d},\"keep_blocks\":{d},\"keep_candidates\":{d},\"keep_bundles\":{d},\"keep_snapshots\":{d},\"max_forge_dirs\":{d},\"rotate_yamori_mb\":{d},\"prune_gaps\":{s}", .{
        policy.keep_captures,
        policy.keep_blocks,
        policy.keep_candidates,
        policy.keep_bundles,
        policy.keep_snapshots,
        policy.max_forge_dirs,
        policy.rotate_yamori_mb,
        if (policy.prune_gaps) "true" else "false",
    }) catch {};
    compat.listWriter(&json).print("}},\"candidates\":[", .{}) catch {};
    for (candidates.items, 0..) |c, i| {
        if (i > 0) compat.listWriter(&json).writeAll(",") catch {};
        compat.listWriter(&json).print("\"{s}\"", .{c.relPath()}) catch {};
    }
    compat.listWriter(&json).print("],\"candidate_count\":{d},\"bytes_to_free\":{d},\"yamori_rotate\":{s}}}", .{
        candidates.items.len,
        total_bytes,
        if (yamori_rotate) "true" else "false",
    }) catch {};

    var out_file = compat.fs.cwd().createFile(plan_path, .{ .truncate = true }) catch {
        std.debug.print("ERROR: cannot write {s}\n", .{plan_path});
        return 1;
    };
    defer out_file.close();
    out_file.writeAll(json.items) catch {
        std.debug.print("ERROR: write failed\n", .{});
        return 1;
    };

    var sz_buf: [32]u8 = undefined;
    const sz_str = formatBytes(total_bytes, &sz_buf);
    std.debug.print("Plan written: {s}\n", .{plan_path});
    std.debug.print("candidates: {d}\n", .{candidates.items.len});
    std.debug.print("bytes_to_free: {s}\n", .{sz_str});
    if (yamori_rotate) std.debug.print("yamori_events.jsonl: rotation pending\n", .{});
    return 0;
}

fn planCaptures(alloc: std.mem.Allocator, candidates: *std.array_list.Managed(Candidate), target_path: []const u8, rel_prefix: []const u8, keep_n: u64) void {
    var dir = compat.fs.cwd().openDir(target_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var symlinks: u64 = 0;
    var names = collectAndSortEntries(alloc, &dir, false, &symlinks);
    defer freeNameList(alloc, &names);

    if (names.items.len <= keep_n) return;

    // Determine 2-day cutoff for time-based retention
    const now_ns: i128 = compat.nanoTimestamp();
    const two_days_ns: i128 = 2 * 24 * 60 * 60 * 1_000_000_000;

    // Build keep set: union of {last N by count} and {files from last 2 days}
    // Names are sorted ascending (oldest first), so last N = tail
    const count_cutoff: usize = if (names.items.len > keep_n) names.items.len - @as(usize, @intCast(keep_n)) else 0;

    for (names.items, 0..) |name, idx| {
        // Always protect if in last N (count-based)
        if (idx >= count_cutoff) continue;

        // Check time-based retention
        const stat = dir.statFile(name) catch continue;
        const mtime_ns: i128 = stat.mtime.nanoseconds;
        const within_2_days = (now_ns - mtime_ns) < two_days_ns;
        if (within_2_days) continue;

        // This file is a deletion candidate
        var c = Candidate{ .bytes = stat.size, .is_dir = false };
        const rel = std.fmt.bufPrint(&c.rel_path_buf, "{s}/{s}", .{ rel_prefix, name }) catch continue;
        c.rel_path_len = rel.len;
        candidates.append(c) catch continue;
    }
}

fn planBlocks(alloc: std.mem.Allocator, candidates: *std.array_list.Managed(Candidate), blocks_path: []const u8, rel_prefix: []const u8, bundles_path: []const u8, keep_n: u64) void {
    var dir = compat.fs.cwd().openDir(blocks_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var symlinks: u64 = 0;
    var names = collectAndSortEntries(alloc, &dir, true, &symlinks);
    defer freeNameList(alloc, &names);

    if (names.items.len <= keep_n) return;

    // Collect bundle-referenced prefixes from blocks_proof_bundles/
    var bundle_prefixes = std.array_list.Managed([]u8).init(alloc);
    defer {
        for (bundle_prefixes.items) |s| alloc.free(s);
        bundle_prefixes.deinit();
    }
    {
        var bdir = compat.fs.cwd().openDir(bundles_path, .{ .iterate = true }) catch {
            // no bundles dir, skip prefix protection
            planBlocksInner(alloc, candidates, &dir, &names, rel_prefix, keep_n, &bundle_prefixes);
            return;
        };
        defer bdir.close();
        var bit = bdir.iterate();
        while (bit.next() catch null) |e| {
            if (e.kind != .file) continue;
            // zip filenames look like <unix>_<slot>_proof_bundle.zip
            // extract prefix up to second underscore as potential block dir name
            const n = e.name;
            if (std.mem.indexOf(u8, n, "_")) |first_us| {
                if (first_us + 1 < n.len) {
                    if (std.mem.indexOf(u8, n[first_us + 1 ..], "_")) |second_us| {
                        const prefix = n[0 .. first_us + 1 + second_us];
                        bundle_prefixes.append(alloc.dupe(u8, prefix) catch continue) catch continue;
                    }
                }
            }
        }
    }
    planBlocksInner(alloc, candidates, &dir, &names, rel_prefix, keep_n, &bundle_prefixes);
}

fn planBlocksInner(_: std.mem.Allocator, candidates: *std.array_list.Managed(Candidate), dir: *compat.fs.Dir, names: *std.array_list.Managed([]u8), rel_prefix: []const u8, keep_n: u64, bundle_prefixes: *std.array_list.Managed([]u8)) void {
    const count_cutoff: usize = if (names.items.len > keep_n) names.items.len - @as(usize, @intCast(keep_n)) else 0;
    // Always protect newest 2
    const protect_from: usize = if (names.items.len >= 2) names.items.len - 2 else 0;

    for (names.items, 0..) |name, idx| {
        // Protect if in last N
        if (idx >= count_cutoff) continue;
        // Protect newest 2
        if (idx >= protect_from) continue;
        // Protect bundle-referenced
        var is_referenced = false;
        for (bundle_prefixes.items) |prefix| {
            if (std.mem.startsWith(u8, name, prefix)) {
                is_referenced = true;
                break;
            }
        }
        if (is_referenced) continue;

        const sz = sumDirSize(dir, name, true);
        var c = Candidate{ .bytes = sz, .is_dir = true };
        const rel = std.fmt.bufPrint(&c.rel_path_buf, "{s}/{s}", .{ rel_prefix, name }) catch continue;
        c.rel_path_len = rel.len;
        candidates.append(c) catch continue;
    }
}

fn planSimple(alloc: std.mem.Allocator, candidates: *std.array_list.Managed(Candidate), target_path: []const u8, rel_prefix: []const u8, keep_n: u64, is_dir_entries: bool) void {
    var dir = compat.fs.cwd().openDir(target_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var symlinks: u64 = 0;
    var names = collectAndSortEntries(alloc, &dir, is_dir_entries, &symlinks);
    defer freeNameList(alloc, &names);

    if (names.items.len <= keep_n) return;

    const count_cutoff: usize = if (names.items.len > keep_n) names.items.len - @as(usize, @intCast(keep_n)) else 0;

    for (names.items, 0..) |name, idx| {
        if (idx >= count_cutoff) continue;
        const sz = sumDirSize(&dir, name, is_dir_entries);
        var c = Candidate{ .bytes = sz, .is_dir = is_dir_entries };
        const rel = std.fmt.bufPrint(&c.rel_path_buf, "{s}/{s}", .{ rel_prefix, name }) catch continue;
        c.rel_path_len = rel.len;
        candidates.append(c) catch continue;
    }
}

fn planBundles(alloc: std.mem.Allocator, candidates: *std.array_list.Managed(Candidate), target_path: []const u8, rel_prefix: []const u8, keep_n: u64) void {
    var dir = compat.fs.cwd().openDir(target_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var symlinks: u64 = 0;

    // Collect only .zip files
    var names = std.array_list.Managed([]u8).init(alloc);
    defer freeNameList(alloc, &names);
    {
        var it = dir.iterate();
        while (it.next() catch null) |e| {
            if (e.kind == .sym_link) {
                symlinks += 1;
                continue;
            }
            if (e.kind != .file) continue;
            // Skip SHA256SUMS — always protected
            if (std.mem.eql(u8, e.name, "SHA256SUMS")) continue;
            if (!std.mem.endsWith(u8, e.name, ".zip")) continue;
            names.append(alloc.dupe(u8, e.name) catch continue) catch continue;
        }
    }
    std.sort.insertion([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    if (names.items.len <= keep_n) return;

    const count_cutoff: usize = if (names.items.len > keep_n) names.items.len - @as(usize, @intCast(keep_n)) else 0;
    // Always protect newest 2
    const protect_from: usize = if (names.items.len >= 2) names.items.len - 2 else 0;

    for (names.items, 0..) |name, idx| {
        if (idx >= count_cutoff) continue;
        if (idx >= protect_from) continue;
        const st = dir.statFile(name) catch continue;
        var c = Candidate{ .bytes = st.size, .is_dir = false };
        const rel = std.fmt.bufPrint(&c.rel_path_buf, "{s}/{s}", .{ rel_prefix, name }) catch continue;
        c.rel_path_len = rel.len;
        candidates.append(c) catch continue;
    }
}

fn planPruneAll(alloc: std.mem.Allocator, candidates: *std.array_list.Managed(Candidate), target_path: []const u8, rel_prefix: []const u8, is_dir_entries: bool) void {
    var dir = compat.fs.cwd().openDir(target_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var symlinks: u64 = 0;
    var names = collectAndSortEntries(alloc, &dir, is_dir_entries, &symlinks);
    defer freeNameList(alloc, &names);

    for (names.items) |name| {
        const sz = sumDirSize(&dir, name, is_dir_entries);
        var c = Candidate{ .bytes = sz, .is_dir = is_dir_entries };
        const rel = std.fmt.bufPrint(&c.rel_path_buf, "{s}/{s}", .{ rel_prefix, name }) catch continue;
        c.rel_path_len = rel.len;
        candidates.append(c) catch continue;
    }
}

// ── kura apply ──────────────────────────────────────────────────────

fn runKuraApply(alloc: std.mem.Allocator, args_it: anytype) u8 {
    const parsed = parseKuraArgs(args_it);
    const resolved = resolveHome(alloc, parsed.home_path) orelse return 1;
    defer if (resolved.owned) alloc.free(resolved.home);
    const home = resolved.home;
    const policy = parsed.policy;

    if (!policy.apply) {
        std.debug.print("REFUSED: use --apply to confirm deletion\n", .{});
        std.debug.print("Run 'kura plan' first, review the plan, then 'kura apply --apply'\n", .{});
        return 1;
    }

    // Read plan JSON
    var plan_path_buf: [512]u8 = undefined;
    const plan_path = std.fmt.bufPrint(&plan_path_buf, "{s}/guardian/kura_plan.json", .{home}) catch {
        std.debug.print("ERROR: path too long\n", .{});
        return 1;
    };

    var plan_file = compat.fs.cwd().openFile(plan_path, .{}) catch {
        std.debug.print("ERROR: cannot open {s} — run 'kura plan' first\n", .{plan_path});
        return 1;
    };
    defer plan_file.close();

    // Read plan content (bounded: max 256KB)
    const plan_content = plan_file.reader().readAllAlloc(alloc, 256 * 1024) catch {
        std.debug.print("ERROR: cannot read plan file\n", .{});
        return 1;
    };
    defer alloc.free(plan_content);

    // Parse JSON
    const parsed_json = std.json.parseFromSlice(std.json.Value, alloc, plan_content, .{}) catch {
        std.debug.print("ERROR: invalid plan JSON\n", .{});
        return 1;
    };
    defer parsed_json.deinit();

    const root = parsed_json.value.object;

    // Verify home matches
    if (root.get("home")) |h| {
        if (h == .string) {
            if (!std.mem.eql(u8, h.string, home)) {
                std.debug.print("ERROR: plan home '{s}' does not match --home '{s}'\n", .{ h.string, home });
                return 1;
            }
        }
    }

    // Verify plan age < 15 minutes
    if (root.get("unix")) |u| {
        const plan_unix = jsonInt(u) orelse 0;
        const now_unix: i64 = compat.timestamp();
        const age = now_unix - plan_unix;
        if (age > 900) {
            std.debug.print("ERROR: plan is {d}s old (max 900s). Re-run 'kura plan'.\n", .{age});
            return 1;
        }
        if (age < 0) {
            std.debug.print("ERROR: plan timestamp is in the future\n", .{});
            return 1;
        }
    }

    // Extract candidates array
    const cands_val = root.get("candidates") orelse {
        std.debug.print("ERROR: plan JSON missing 'candidates' array\n", .{});
        return 1;
    };
    if (cands_val != .array) {
        std.debug.print("ERROR: 'candidates' is not an array\n", .{});
        return 1;
    }

    // Check yamori_rotate
    var yamori_rotate = false;
    if (root.get("yamori_rotate")) |yr| {
        if (yr == .bool) yamori_rotate = yr.bool;
    }

    var deleted: u64 = 0;
    var failed: u64 = 0;
    var bytes_freed: u64 = 0;

    // Track failures for report
    var failures = std.array_list.Managed(u8).init(alloc);
    defer failures.deinit();

    for (cands_val.array.items) |item| {
        if (item != .string) continue;
        const rel = item.string;

        // Safety: refuse ".."
        if (std.mem.indexOf(u8, rel, "..") != null) {
            std.debug.print("SKIP: unsafe path (contains ..): {s}\n", .{rel});
            failed += 1;
            appendFailure(&failures, rel, "contains ..");
            continue;
        }

        var full_path_buf: [1024]u8 = undefined;
        const full_path = std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ home, rel }) catch {
            failed += 1;
            continue;
        };

        // Safety: verify starts with home
        if (!isPathSafe(home, full_path)) {
            std.debug.print("SKIP: path outside home prefix: {s}\n", .{full_path});
            failed += 1;
            appendFailure(&failures, rel, "outside home prefix");
            continue;
        }

        // Attempt size estimation before delete
        const entry_bytes = estimateEntryBytes(full_path);

        // Try directory delete first, then file delete
        compat.fs.cwd().deleteTree(full_path) catch {
            compat.fs.cwd().deleteFile(full_path) catch {
                std.debug.print("FAIL: {s}\n", .{rel});
                failed += 1;
                appendFailure(&failures, rel, "delete failed");
                continue;
            };
        };
        deleted += 1;
        bytes_freed += entry_bytes;
    }

    // Handle yamori rotation
    if (yamori_rotate) {
        var ev_buf: [512]u8 = undefined;
        const ev_path = std.fmt.bufPrint(&ev_buf, "{s}/guardian/yamori_events.jsonl", .{home}) catch "";
        if (ev_path.len > 0) {
            const now_unix: i64 = compat.timestamp();
            var rot_buf: [512]u8 = undefined;
            const rot_path = std.fmt.bufPrint(&rot_buf, "{s}/guardian/yamori_events.{d}.jsonl", .{ home, now_unix }) catch "";
            if (rot_path.len > 0) {
                compat.fs.cwd().rename(ev_path, rot_path) catch {
                    std.debug.print("WARN: yamori rotation failed\n", .{});
                };
                // Create fresh empty file
                const fresh = compat.fs.cwd().createFile(ev_path, .{ .truncate = true }) catch null;
                if (fresh) |f| {
                    var f_mut = f;
                    f_mut.close();
                }
                std.debug.print("yamori_events.jsonl rotated\n", .{});
            }
        }
    }

    // Write apply report
    var apply_path_buf: [512]u8 = undefined;
    const apply_path = std.fmt.bufPrint(&apply_path_buf, "{s}/guardian/kura_apply.json", .{home}) catch "";
    if (apply_path.len > 0) {
        const now_unix2: i64 = compat.timestamp();
        var report = std.array_list.Managed(u8).init(alloc);
        defer report.deinit();
        compat.listWriter(&report).print("{{\"unix\":{d},\"deleted\":{d},\"bytes_freed\":{d},\"failures\":[{s}]}}", .{
            now_unix2, deleted, bytes_freed, failures.items,
        }) catch {};

        var rf = compat.fs.cwd().createFile(apply_path, .{ .truncate = true }) catch null;
        if (rf) |*f| {
            defer f.close();
            f.writeAll(report.items) catch {};
        }
    }

    var sz_buf: [32]u8 = undefined;
    const sz_str = formatBytes(bytes_freed, &sz_buf);
    std.debug.print("=== KURA Apply ===\n", .{});
    std.debug.print("deleted: {d}\n", .{deleted});
    std.debug.print("bytes_freed: {s}\n", .{sz_str});
    if (failed > 0) std.debug.print("failures: {d}\n", .{failed});
    if (failed > 0) return 1;
    return 0;
}

fn appendFailure(failures: *std.array_list.Managed(u8), path: []const u8, reason: []const u8) void {
    if (failures.items.len > 0) compat.listWriter(failures).writeAll(",") catch {};
    compat.listWriter(failures).print("{{\"path\":\"{s}\",\"reason\":\"{s}\"}}", .{ path, reason }) catch {};
}

fn estimateEntryBytes(full_path: []const u8) u64 {
    // Try stat as file first
    const st = compat.fs.cwd().statFile(full_path) catch {
        // Might be a directory — try opening and summing
        var dir = compat.fs.cwd().openDir(full_path, .{ .iterate = true }) catch return 0;
        defer dir.close();
        var total: u64 = 0;
        var it = dir.iterate();
        while (it.next() catch null) |e| {
            if (e.kind == .file) {
                const fst = dir.statFile(e.name) catch continue;
                total += fst.size;
            }
        }
        return total;
    };
    return st.size;
}

// ── kura revert ─────────────────────────────────────────────────────

fn runKuraRevert(alloc: std.mem.Allocator, args_it: anytype) u8 {
    const resolved = resolveKuraHome(alloc, args_it) orelse return 1;
    defer if (resolved.owned) alloc.free(resolved.home);
    const home = resolved.home;

    var plan_buf: [512]u8 = undefined;
    const plan_path = std.fmt.bufPrint(&plan_buf, "{s}/guardian/kura_plan.json", .{home}) catch {
        std.debug.print("ERROR: path too long\n", .{});
        return 1;
    };
    compat.fs.cwd().deleteFile(plan_path) catch {};

    var apply_buf: [512]u8 = undefined;
    const apply_path = std.fmt.bufPrint(&apply_buf, "{s}/guardian/kura_apply.json", .{home}) catch {
        std.debug.print("ERROR: path too long\n", .{});
        return 1;
    };
    compat.fs.cwd().deleteFile(apply_path) catch {};

    std.debug.print("KURA metadata removed.\n", .{});
    std.debug.print("NOTE: revert removes metadata only; deleted data is not recoverable.\n", .{});
    return 0;
}

// ── kura doctor ─────────────────────────────────────────────────────

fn runKuraDoctor(alloc: std.mem.Allocator, args_it: anytype) u8 {
    const resolved = resolveKuraHome(alloc, args_it) orelse return 1;
    defer if (resolved.owned) alloc.free(resolved.home);
    const home = resolved.home;

    std.debug.print("=== KURA Doctor ===\n", .{});
    var any_fail = false;

    // 1) Symlink check across all target dirs
    {
        var found_symlinks = false;
        for (KURA_TARGETS) |tgt| {
            var path_buf: [512]u8 = undefined;
            const target_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, tgt.rel_path }) catch continue;
            var dir = compat.fs.cwd().openDir(target_path, .{ .iterate = true }) catch continue;
            defer dir.close();
            var it = dir.iterate();
            while (it.next() catch null) |e| {
                if (e.kind == .sym_link) {
                    std.debug.print("[FAIL] Symlink found: {s}/{s}\n", .{ tgt.rel_path, e.name });
                    found_symlinks = true;
                    any_fail = true;
                }
            }
        }
        if (!found_symlinks) {
            std.debug.print("[PASS] No symlinks in target directories\n", .{});
        }
    }

    // 2) Blocks artifact check — each dir should have meta.json + verify.json
    {
        var path_buf: [512]u8 = undefined;
        const blocks_path = std.fmt.bufPrint(&path_buf, "{s}/producer_dryrun/blocks", .{home}) catch "";
        if (blocks_path.len > 0) {
            var bdir = compat.fs.cwd().openDir(blocks_path, .{ .iterate = true }) catch null;
            if (bdir) |*bd| {
                defer bd.close();
                var bit = bd.iterate();
                var checked: u64 = 0;
                var warnings: u64 = 0;
                while (bit.next() catch null) |e| {
                    if (e.kind != .directory) continue;
                    checked += 1;
                    var sdir = bd.openDir(e.name, .{}) catch continue;
                    defer sdir.close();
                    const has_meta = if (sdir.statFile("meta.json")) |_| true else |_| false;
                    const has_verify = if (sdir.statFile("verify.json")) |_| true else |_| false;
                    if (!has_meta) {
                        std.debug.print("[WARN] blocks/{s}: missing meta.json\n", .{e.name});
                        warnings += 1;
                    }
                    if (!has_verify) {
                        std.debug.print("[WARN] blocks/{s}: missing verify.json\n", .{e.name});
                        warnings += 1;
                    }
                }
                if (checked > 0 and warnings == 0) {
                    std.debug.print("[PASS] Block artifacts complete ({d} dirs checked)\n", .{checked});
                }
            }
        }
    }

    // 3) Bundles SHA256SUMS check
    {
        var path_buf: [512]u8 = undefined;
        const bundles_path = std.fmt.bufPrint(&path_buf, "{s}/producer_dryrun/blocks_proof_bundles/SHA256SUMS", .{home}) catch "";
        if (bundles_path.len > 0) {
            if (compat.fs.cwd().statFile(bundles_path)) |_| {
                std.debug.print("[PASS] SHA256SUMS present\n", .{});
            } else |_| {
                std.debug.print("[WARN] SHA256SUMS missing in blocks_proof_bundles/\n", .{});
            }
        }
    }

    // 4) Disk usage (best-effort via C statvfs)
    {
        const c = @cImport(@cInclude("sys/statvfs.h"));
        var path_buf: [512]u8 = undefined;
        const home_z = std.fmt.bufPrint(&path_buf, "{s}\x00", .{home}) catch "";
        if (home_z.len > 1) {
            const path_ptr: [*:0]const u8 = @ptrCast(home_z.ptr);
            var stat: c.struct_statvfs = undefined;
            const rc = c.statvfs(path_ptr, &stat);
            if (rc == 0 and stat.f_blocks > 0) {
                const used = stat.f_blocks - stat.f_bfree;
                const pct = used * 100 / stat.f_blocks;
                if (pct > 90) {
                    std.debug.print("[WARN] Disk usage: {d}%\n", .{pct});
                } else {
                    std.debug.print("[PASS] Disk usage: {d}%\n", .{pct});
                }
            }
        }
    }

    if (any_fail) return 1;
    return 0;
}

// ── bcast-arm (v3.8.0) ─────────────────────────────────────────────

fn runBcastArm(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var port: u16 = DEFAULT_PORT;
    var home_path: ?[]const u8 = null;
    var confirmed = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --port requires a number\n", .{});
                return 1;
            };
            port = std.fmt.parseInt(u16, val, 10) catch {
                std.debug.print("ERROR: invalid port: {s}\n", .{val});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--home")) {
            home_path = args_it.next() orelse {
                std.debug.print("ERROR: --home requires a path\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--i-know-what-im-doing")) {
            confirmed = true;
        } else {
            std.debug.print("ERROR: unknown bcast-arm flag: {s}\n", .{arg});
            return 1;
        }
    }

    if (!confirmed) {
        std.debug.print("ERROR: bcast-arm requires --i-know-what-im-doing flag\n", .{});
        std.debug.print("Usage: tsunagi-node guardian bcast-arm --port <N> --i-know-what-im-doing [--home <path>]\n", .{});
        return 1;
    }

    std.debug.print("=== Bcast Arm — Pre-flight Checks ===\n", .{});
    var doc_pass: u32 = 0;
    var doc_fail: u32 = 0;

    // Check 1: Node reachable (with retry for transient TCP drops)
    {
        const resp = httpGetRetry(alloc, port, "/health");
        if (resp != null) {
            alloc.free(resp.?.body);
            if (resp.?.status == 200) {
                doc_pass += 1;
                std.debug.print("  PASS  Node reachable\n", .{});
            } else {
                doc_fail += 1;
                std.debug.print("  FAIL  Node reachable (HTTP {d})\n", .{resp.?.status});
            }
        } else {
            doc_fail += 1;
            std.debug.print("  FAIL  Node reachable (connection refused)\n", .{});
            std.debug.print("\nABORT: node not reachable\n", .{});
            return 1;
        }
    }

    // Get /state for checks 2-7 (with retry + alloc_always to avoid use-after-free)
    var state_json: ?std.json.Parsed(std.json.Value) = null;
    defer if (state_json != null) state_json.?.deinit();
    state_json = fetchStateParsed(alloc, port);
    if (state_json == null) return 1;
    const root = state_json.?.value.object;

    // Check 2: Tip advancing
    {
        var tip_slot: ?i64 = null;
        if (root.get("tip")) |tip| {
            if (tip == .object) {
                if (tip.object.get("slot")) |v| {
                    tip_slot = jsonInt(v);
                }
            }
        }
        if (tip_slot != null and tip_slot.? > 0) {
            doc_pass += 1;
            std.debug.print("  PASS  Tip advancing (slot={d})\n", .{tip_slot.?});
        } else {
            doc_fail += 1;
            std.debug.print("  FAIL  Tip advancing\n", .{});
        }
    }

    // Check 3: KES keys loaded
    {
        const kes_ok = getNestedInt(root, "producer_keys", "kes_ok");
        if (kes_ok != null and kes_ok.? == 1) {
            doc_pass += 1;
            std.debug.print("  PASS  KES keys loaded\n", .{});
        } else {
            doc_fail += 1;
            std.debug.print("  FAIL  KES keys loaded\n", .{});
        }
    }

    // Check 4: VRF keys loaded
    {
        const vrf_ok = getNestedInt(root, "producer_keys", "vrf_ok");
        if (vrf_ok != null and vrf_ok.? == 1) {
            doc_pass += 1;
            std.debug.print("  PASS  VRF keys loaded\n", .{});
        } else {
            doc_fail += 1;
            std.debug.print("  FAIL  VRF keys loaded\n", .{});
        }
    }

    // Check 5: KES period valid
    {
        const kes_valid = getNestedInt(root, "producer_kes_period", "period_valid_last");
        if (kes_valid != null and kes_valid.? == 1) {
            doc_pass += 1;
            std.debug.print("  PASS  KES period valid\n", .{});
        } else {
            doc_fail += 1;
            std.debug.print("  FAIL  KES period valid\n", .{});
            std.debug.print("\nABORT: KES period invalid — cannot arm bcast\n", .{});
            return 1;
        }
    }

    // Check 6: Dryrun enabled
    {
        const dryrun = getNestedInt(root, "producer_dryrun", "enabled");
        if (dryrun != null and dryrun.? == 1) {
            doc_pass += 1;
            std.debug.print("  PASS  Dryrun enabled\n", .{});
        } else {
            doc_fail += 1;
            std.debug.print("  FAIL  Dryrun enabled\n", .{});
        }
    }

    // Check 7: Clock OK (warn-only — clock sync may lag on preview)
    {
        const clock_ok = getNestedInt(root, "producer_clock", "clock_ok");
        if (clock_ok != null and clock_ok.? == 1) {
            doc_pass += 1;
            std.debug.print("  PASS  Clock OK\n", .{});
        } else {
            doc_pass += 1;
            std.debug.print("  WARN  Clock OK (not fatal for bcast-arm)\n", .{});
        }
    }

    // Check 8: TXSUB broadcast OFF
    {
        const bcast = compat.getEnvVarOwned(alloc, "TSUNAGI_TXSUB_BROADCAST") catch null;
        if (bcast) |val| {
            defer alloc.free(val);
            if (std.mem.eql(u8, val, "1")) {
                doc_fail += 1;
                std.debug.print("  FAIL  Broadcast OFF (TSUNAGI_TXSUB_BROADCAST=1)\n", .{});
                std.debug.print("\nABORT: broadcast is ON — cannot arm bcast\n", .{});
                return 1;
            }
        }
        doc_pass += 1;
        std.debug.print("  PASS  TXSUB broadcast OFF\n", .{});
    }

    // Check 9: Network is preview (with retry for transient TCP/parse issues)
    {
        var is_preview = false;
        var status_attempt: u8 = 0;
        while (status_attempt < 3) : (status_attempt += 1) {
            if (status_attempt > 0) compat.sleep(300 * std.time.ns_per_ms);
            const resp = httpGet(alloc, port, "/status") orelse continue;
            defer alloc.free(resp.body);
            if (resp.status < 200 or resp.status >= 300) continue;
            const sp = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{ .allocate = .alloc_always }) catch continue;
            defer sp.deinit();
            if (sp.value == .object) {
                if (sp.value.object.get("net")) |v| {
                    if (v == .string) {
                        is_preview = std.mem.eql(u8, v.string, "preview");
                        break;
                    }
                }
            }
        }
        if (is_preview) {
            doc_pass += 1;
            std.debug.print("  PASS  Network is preview\n", .{});
        } else {
            doc_fail += 1;
            std.debug.print("  FAIL  Network is preview\n", .{});
            std.debug.print("\nABORT: not preview network — cannot arm bcast\n", .{});
            return 1;
        }
    }

    // Check 10: Forge gate active (check env OR node /state producer_dryrun)
    {
        var forge_ok = false;
        // First try local env
        const forge_env = compat.getEnvVarOwned(alloc, "TSUNAGI_FORGE_ENABLE") catch null;
        if (forge_env) |val| {
            defer alloc.free(val);
            if (std.mem.eql(u8, val, "1")) forge_ok = true;
        }
        // Fall back: if dryrun enabled on node and forge_sim dir exists, forge is active
        if (!forge_ok) {
            const dryrun = getNestedInt(root, "producer_dryrun", "enabled");
            if (dryrun != null and dryrun.? == 1) {
                const home_for_check = home_path orelse (compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null);
                if (home_for_check) |h| {
                    var fsim_buf: [512]u8 = undefined;
                    const fsim_path = std.fmt.bufPrint(&fsim_buf, "{s}/producer_forge_sim", .{h}) catch "";
                    if (fsim_path.len > 0) {
                        if (compat.fs.cwd().access(fsim_path, .{})) |_| {
                            forge_ok = true;
                        } else |_| {}
                    }
                }
            }
        }
        if (forge_ok) {
            doc_pass += 1;
            std.debug.print("  PASS  Forge gate active\n", .{});
        } else {
            doc_fail += 1;
            std.debug.print("  FAIL  Forge gate active\n", .{});
        }
    }

    // Check 11: Fork readiness evidence
    {
        const home_for_check = home_path orelse (compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null);
        if (home_for_check) |h| {
            var fr_path_buf: [512]u8 = undefined;
            const fr_path = std.fmt.bufPrint(&fr_path_buf, "{s}/regress/fork_readiness", .{h}) catch "";
            if (fr_path.len > 0) {
                if (compat.fs.cwd().openDir(fr_path, .{ .iterate = true })) |dir_val| {
                    var dir2 = dir_val;
                    defer dir2.close();
                    var it = dir2.iterate();
                    var count: u32 = 0;
                    while (it.next() catch null) |_| {
                        count += 1;
                        if (count > 0) break;
                    }
                    if (count > 0) {
                        doc_pass += 1;
                        std.debug.print("  PASS  Fork readiness evidence\n", .{});
                    } else {
                        doc_fail += 1;
                        std.debug.print("  FAIL  Fork readiness evidence (empty)\n", .{});
                    }
                } else |_| {
                    doc_fail += 1;
                    std.debug.print("  FAIL  Fork readiness evidence (dir not found)\n", .{});
                }
            } else {
                doc_fail += 1;
                std.debug.print("  FAIL  Fork readiness evidence (path error)\n", .{});
            }
        } else {
            doc_fail += 1;
            std.debug.print("  FAIL  Fork readiness evidence (no home path)\n", .{});
        }
    }

    // Check 12: No stale bcast token (warning, not hard fail)
    {
        const home_for_check = home_path orelse (compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null);
        if (home_for_check) |h| {
            var tk_path_buf: [512]u8 = undefined;
            const tk_path = std.fmt.bufPrint(&tk_path_buf, "{s}/guardian/bcast_arm.json", .{h}) catch "";
            if (tk_path.len > 0) {
                if (compat.fs.cwd().access(tk_path, .{})) |_| {
                    std.debug.print("  WARN  Stale bcast_arm.json exists (will be overwritten)\n", .{});
                } else |_| {
                    doc_pass += 1;
                    std.debug.print("  PASS  No stale bcast token\n", .{});
                }
            }
        }
    }

    if (doc_fail > 0) {
        std.debug.print("\n{d} pre-flight checks failed — aborting\n", .{doc_fail});
        return 1;
    }
    std.debug.print("\nAll pre-flight checks passed ({d}/{d})\n", .{ doc_pass, doc_pass });

    // Resolve home
    var home_owned = false;
    const home = if (home_path) |hp| hp else blk: {
        const env_home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
        if (env_home) |h| {
            home_owned = true;
            break :blk h;
        }
        break :blk @as(?[]const u8, null);
    };
    if (home == null) {
        std.debug.print("ERROR: --home or TSUNAGI_HOME required\n", .{});
        return 1;
    }
    defer if (home_owned) alloc.free(home.?);

    // Create guardian dir if needed
    {
        var gdir_buf: [512]u8 = undefined;
        const gdir = std.fmt.bufPrint(&gdir_buf, "{s}/guardian", .{home.?}) catch {
            std.debug.print("ERROR: path too long\n", .{});
            return 1;
        };
        compat.fs.cwd().makePath(gdir) catch {};
    }

    // Generate nonce (16 random bytes → 32 hex chars)
    var nonce_bytes: [16]u8 = undefined;
    compat.cryptoRandomBytes(&nonce_bytes);
    const nonce_hex = std.fmt.bytesToHex(nonce_bytes, .lower);

    // Current unix timestamp
    const now_unix: i64 = compat.timestamp();

    // Build token path
    var arm_path_buf: [512]u8 = undefined;
    const arm_path = std.fmt.bufPrint(&arm_path_buf, "{s}/guardian/bcast_arm.json", .{home.?}) catch {
        std.debug.print("ERROR: path too long\n", .{});
        return 1;
    };

    // Write token JSON
    var token_buf: [512]u8 = undefined;
    const token_json = std.fmt.bufPrint(&token_buf,
        \\{{"armed_at_unix":{d},"net":"preview","home":"{s}","nonce":"{s}","statements":["preview_only","no_inject","guardian_confirmed"]}}
    , .{ now_unix, home.?, @as([]const u8, &nonce_hex) }) catch {
        std.debug.print("ERROR: token buffer overflow\n", .{});
        return 1;
    };

    var out_file = compat.fs.cwd().createFile(arm_path, .{ .truncate = true }) catch {
        std.debug.print("ERROR: cannot write {s}\n", .{arm_path});
        return 1;
    };
    defer out_file.close();
    out_file.writeAll(token_json) catch {
        std.debug.print("ERROR: write failed\n", .{});
        return 1;
    };

    std.debug.print("\nBroadcast arming token written:\n", .{});
    std.debug.print("  path:  {s}\n", .{arm_path});
    std.debug.print("  nonce: {s}\n", .{@as([]const u8, &nonce_hex)});
    std.debug.print("  TTL:   10 minutes\n", .{});
    std.debug.print("\nUse 'guardian bcast-push' to validate artifacts and get transfer instructions.\n", .{});

    return 0;
}

// ── bcast-status (v3.8.0) ──────────────────────────────────────────

fn runBcastStatus(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var port: u16 = DEFAULT_PORT;
    var home_path: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --port requires a number\n", .{});
                return 1;
            };
            port = std.fmt.parseInt(u16, val, 10) catch {
                std.debug.print("ERROR: invalid port: {s}\n", .{val});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--home")) {
            home_path = args_it.next() orelse {
                std.debug.print("ERROR: --home requires a path\n", .{});
                return 1;
            };
        } else {
            std.debug.print("ERROR: unknown bcast-status flag: {s}\n", .{arg});
            return 1;
        }
    }

    // Resolve home
    var home_owned = false;
    const home = if (home_path) |hp| hp else blk: {
        const env_home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
        if (env_home) |h| {
            home_owned = true;
            break :blk h;
        }
        break :blk @as(?[]const u8, null);
    };
    defer if (home_owned) alloc.free(home.?);

    std.debug.print("=== Broadcast Gate Status ===\n\n", .{});

    // Broadcast env flags
    std.debug.print("Env flags:\n", .{});
    {
        const e1 = compat.getenv("TSUNAGI_BCAST_ENABLE");
        const e2 = compat.getenv("TSUNAGI_BCAST_PREVIEW_ONLY");
        const e3 = compat.getenv("TSUNAGI_BCAST_NO_INJECT");
        const e4 = compat.getenv("TSUNAGI_BCAST_REQUIRE_GUARDIAN_CONFIRM");
        std.debug.print("  TSUNAGI_BCAST_ENABLE:                    {s}\n", .{if (e1 != null) e1.? else "(unset)"});
        std.debug.print("  TSUNAGI_BCAST_PREVIEW_ONLY:              {s}\n", .{if (e2 != null) e2.? else "(unset)"});
        std.debug.print("  TSUNAGI_BCAST_NO_INJECT:                 {s}\n", .{if (e3 != null) e3.? else "(unset)"});
        std.debug.print("  TSUNAGI_BCAST_REQUIRE_GUARDIAN_CONFIRM:   {s}\n", .{if (e4 != null) e4.? else "(unset)"});
    }

    // bcast_arm.json
    std.debug.print("\nArming token:\n", .{});
    if (home) |h| {
        var arm_buf: [512]u8 = undefined;
        const arm_path = std.fmt.bufPrint(&arm_buf, "{s}/guardian/bcast_arm.json", .{h}) catch "";
        if (arm_path.len > 0) {
            if (readFileAlloc(alloc, arm_path)) |data| {
                defer alloc.free(data);
                const armed_at = forgeExtractJsonInt(data, "\"armed_at_unix\":");
                const now_unix: i64 = compat.timestamp();
                if (armed_at) |ts| {
                    const age = now_unix - ts;
                    const expired = age > 600;
                    std.debug.print("  bcast_arm.json: EXISTS (age={d}s, {s})\n", .{
                        age, if (expired) "EXPIRED" else "valid",
                    });
                } else {
                    std.debug.print("  bcast_arm.json: EXISTS (cannot parse age)\n", .{});
                }
            } else {
                std.debug.print("  bcast_arm.json: not found\n", .{});
            }
        }
    } else {
        std.debug.print("  (no home path — cannot check)\n", .{});
    }

    // Latest forge_sim artifact
    std.debug.print("\nLatest forge artifact:\n", .{});
    if (home) |h| {
        var sim_buf: [512]u8 = undefined;
        const sim_dir = std.fmt.bufPrint(&sim_buf, "{s}/producer_forge_sim", .{h}) catch "";
        if (sim_dir.len > 0) {
            if (compat.fs.cwd().openDir(sim_dir, .{ .iterate = true })) |dir_val| {
                var dir3 = dir_val;
                defer dir3.close();
                var it = dir3.iterate();
                var latest_name: [256]u8 = undefined;
                var latest_len: usize = 0;
                while (it.next() catch null) |entry| {
                    if (entry.kind == .directory) {
                        if (entry.name.len > latest_len) {
                            @memcpy(latest_name[0..entry.name.len], entry.name);
                            latest_len = entry.name.len;
                        } else if (entry.name.len == latest_len) {
                            if (std.mem.order(u8, entry.name, latest_name[0..latest_len]) == .gt) {
                                @memcpy(latest_name[0..entry.name.len], entry.name);
                                latest_len = entry.name.len;
                            }
                        }
                    }
                }
                if (latest_len > 0) {
                    std.debug.print("  latest: {s}/{s}\n", .{ sim_dir, latest_name[0..latest_len] });

                // Check broadcast_receipt.json in latest dir
                var rcpt_buf: [768]u8 = undefined;
                const rcpt_path = std.fmt.bufPrint(&rcpt_buf, "{s}/{s}/broadcast_receipt.json", .{ sim_dir, latest_name[0..latest_len] }) catch "";
                if (rcpt_path.len > 0) {
                    if (readFileAlloc(alloc, rcpt_path)) |rcpt_data| {
                        defer alloc.free(rcpt_data);
                        std.debug.print("  broadcast_receipt.json: EXISTS\n", .{});
                        // Check announced field
                        if (std.mem.indexOf(u8, rcpt_data, "\"announced\":true")) |_| {
                            std.debug.print("  announced: true\n", .{});
                        } else if (std.mem.indexOf(u8, rcpt_data, "\"announced\":false")) |_| {
                            std.debug.print("  announced: false\n", .{});
                        }
                    } else {
                        std.debug.print("  broadcast_receipt.json: not found\n", .{});
                    }
                }
                } else {
                    std.debug.print("  (no forge artifacts found)\n", .{});
                }
            } else |_| {
                std.debug.print("  (no producer_forge_sim directory)\n", .{});
            }
        }
    } else {
        std.debug.print("  (no home path — cannot check)\n", .{});
    }

    // Node tip (if port given)
    {
        const resp = httpGet(alloc, port, "/health");
        if (resp != null) {
            alloc.free(resp.?.body);
            std.debug.print("\nNode: reachable (port {d})\n", .{port});
        } else {
            std.debug.print("\nNode: not reachable (port {d})\n", .{port});
        }
    }

    return 0;
}

// ── bcast-push (v3.8.0) ────────────────────────────────────────────

const BCAST_ARM_TTL_S: i64 = 600; // 10 minutes

fn runBcastPush(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var port: ?u16 = null;
    var home_path: ?[]const u8 = null;
    var forge_dir: ?[]const u8 = null;
    var peer_str: ?[]const u8 = null;
    var confirmed = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --port requires a number\n", .{});
                return 1;
            };
            port = std.fmt.parseInt(u16, val, 10) catch {
                std.debug.print("ERROR: invalid port: {s}\n", .{val});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--home")) {
            home_path = args_it.next() orelse {
                std.debug.print("ERROR: --home requires a path\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--dir")) {
            forge_dir = args_it.next() orelse {
                std.debug.print("ERROR: --dir requires a path\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--peer")) {
            peer_str = args_it.next() orelse {
                std.debug.print("ERROR: --peer requires host:port\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--i-know-what-im-doing")) {
            confirmed = true;
        } else {
            std.debug.print("ERROR: unknown bcast-push flag: {s}\n", .{arg});
            return 1;
        }
    }

    // 1. --i-know-what-im-doing required
    if (!confirmed) {
        std.debug.print("ERROR: bcast-push requires --i-know-what-im-doing flag\n", .{});
        return 1;
    }

    // Required args
    if (forge_dir == null) {
        std.debug.print("ERROR: --dir <forge_dir> is required\n", .{});
        return 1;
    }
    if (peer_str == null) {
        std.debug.print("ERROR: --peer <host:port> is required\n", .{});
        return 1;
    }

    // 2. Preview-only check
    {
        const net_env = compat.getenv("TSUNAGI_NET");
        if (net_env) |n| {
            if (!std.mem.eql(u8, n, "preview")) {
                std.debug.print("ERROR: bcast-push is preview-only (TSUNAGI_NET={s})\n", .{n});
                return 1;
            }
        }
    }

    // 3. Refuse if TSUNAGI_TXSUB_BROADCAST set
    {
        const bcast_env = compat.getEnvVarOwned(alloc, "TSUNAGI_TXSUB_BROADCAST") catch null;
        if (bcast_env) |val| {
            defer alloc.free(val);
            if (std.mem.eql(u8, val, "1")) {
                std.debug.print("ERROR: TSUNAGI_TXSUB_BROADCAST is set — refuse bcast-push\n", .{});
                return 1;
            }
        }
    }

    // 4. Resolve home
    var home_owned = false;
    const home = if (home_path) |hp| hp else blk: {
        const env_home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
        if (env_home) |h| {
            home_owned = true;
            break :blk h;
        }
        break :blk @as(?[]const u8, null);
    };
    defer if (home_owned) alloc.free(home.?);

    // 5. Validate bcast_arm.json
    if (home == null) {
        std.debug.print("ERROR: --home or TSUNAGI_HOME required\n", .{});
        return 1;
    }

    var arm_path_buf: [512]u8 = undefined;
    const arm_path = std.fmt.bufPrint(&arm_path_buf, "{s}/guardian/bcast_arm.json", .{home.?}) catch {
        std.debug.print("ERROR: path too long\n", .{});
        return 1;
    };

    const arm_data = readFileAlloc(alloc, arm_path) orelse {
        std.debug.print("ERROR: bcast_arm.json not found at {s}\n", .{arm_path});
        std.debug.print("Run 'guardian bcast-arm' first.\n", .{});
        return 1;
    };
    defer alloc.free(arm_data);

    {
        const armed_at = forgeExtractJsonInt(arm_data, "\"armed_at_unix\":") orelse {
            std.debug.print("ERROR: bcast_arm.json missing armed_at_unix\n", .{});
            return 1;
        };
        const now_unix: i64 = compat.timestamp();
        if (now_unix - armed_at > BCAST_ARM_TTL_S) {
            std.debug.print("ERROR: bcast_arm.json expired (age={d}s, TTL={d}s)\n", .{ now_unix - armed_at, BCAST_ARM_TTL_S });
            return 1;
        }

        const net_str = forgeExtractJsonStr(arm_data, "\"net\":\"") orelse "unknown";
        if (!std.mem.eql(u8, net_str, "preview")) {
            std.debug.print("ERROR: bcast_arm.json net={s}, expected preview\n", .{net_str});
            return 1;
        }

        const home_str = forgeExtractJsonStr(arm_data, "\"home\":\"") orelse "";
        if (!std.mem.eql(u8, home_str, home.?)) {
            std.debug.print("ERROR: bcast_arm.json home mismatch\n", .{});
            return 1;
        }
    }

    // 6. Verify block.cbor exists
    var block_path_buf: [600]u8 = undefined;
    const block_path = std.fmt.bufPrint(&block_path_buf, "{s}/block.cbor", .{forge_dir.?}) catch {
        std.debug.print("ERROR: path too long\n", .{});
        return 1;
    };
    const block_stat = compat.fs.cwd().statFile(block_path) catch {
        std.debug.print("ERROR: block.cbor not found in {s}\n", .{forge_dir.?});
        return 1;
    };

    // 7. Verify broadcast_receipt.json exists
    var rcpt_path_buf: [600]u8 = undefined;
    const rcpt_path = std.fmt.bufPrint(&rcpt_path_buf, "{s}/broadcast_receipt.json", .{forge_dir.?}) catch {
        std.debug.print("ERROR: path too long\n", .{});
        return 1;
    };
    compat.fs.cwd().access(rcpt_path, .{}) catch {
        std.debug.print("ERROR: broadcast_receipt.json not found in {s}\n", .{forge_dir.?});
        return 1;
    };

    // 8. Verify block_header_hash.hex exists and is valid
    var hash_path_buf: [600]u8 = undefined;
    const hash_path = std.fmt.bufPrint(&hash_path_buf, "{s}/block_header_hash.hex", .{forge_dir.?}) catch {
        std.debug.print("ERROR: path too long\n", .{});
        return 1;
    };
    const hash_hex_data = readFileAlloc(alloc, hash_path) orelse {
        std.debug.print("ERROR: cannot read block_header_hash.hex\n", .{});
        return 1;
    };
    defer alloc.free(hash_hex_data);
    if (hash_hex_data.len < 64) {
        std.debug.print("ERROR: block_header_hash.hex too short ({d})\n", .{hash_hex_data.len});
        return 1;
    }

    // 9. Read meta.json for slot/block_no
    var meta_path_buf: [600]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&meta_path_buf, "{s}/meta.json", .{forge_dir.?}) catch {
        std.debug.print("ERROR: path too long\n", .{});
        return 1;
    };
    const meta_data = readFileAlloc(alloc, meta_path) orelse {
        std.debug.print("ERROR: cannot read meta.json\n", .{});
        return 1;
    };
    defer alloc.free(meta_data);

    const meta_slot = forgeExtractJsonInt(meta_data, "\"slot\":") orelse 0;
    const meta_block_no = forgeExtractJsonInt(meta_data, "\"block_no\":") orelse 0;

    // 10. Doctor check (if port given)
    if (port) |p| {
        const resp = httpGet(alloc, p, "/health");
        if (resp) |r| {
            alloc.free(r.body);
            if (r.status != 200) {
                std.debug.print("ERROR: node health check failed (HTTP {d})\n", .{r.status});
                return 1;
            }
        } else {
            std.debug.print("ERROR: node not reachable on port {d}\n", .{p});
            return 1;
        }
    }

    // === All validation passed ===
    std.debug.print("=== Broadcast Push ===\n", .{});
    std.debug.print("  artifacts validated:\n", .{});
    std.debug.print("    block.cbor:             {d} bytes\n", .{block_stat.size});
    std.debug.print("    block_header_hash.hex:  {s}\n", .{hash_hex_data[0..64]});
    std.debug.print("    meta.json:              slot={d} block_no={d}\n", .{meta_slot, meta_block_no});
    std.debug.print("    broadcast_receipt.json: present\n", .{});
    std.debug.print("    bcast_arm.json:         valid\n", .{});

    // Direct N2N block transport requires proper Ouroboros mini-protocol wiring
    // (ChainSync + peer promotion + BlockFetch). This is not yet implemented.
    // Write receipt and print operator file-transfer suggestion.

    const push_unix: i64 = compat.timestamp();
    {
        var rcpt_buf: [512]u8 = undefined;
        const rcpt = std.fmt.bufPrint(&rcpt_buf,
            \\{{"mode":"broadcast","announced":false,"unix":{d},"slot":{d},"block_no":{d},"peers":0,"error":"no_direct_transport","no_inject":true,"tip_before":null,"tip_after":null}}
        , .{ push_unix, meta_slot, meta_block_no }) catch {
            std.debug.print("ERROR: receipt buffer overflow\n", .{});
            return 1;
        };

        var rcpt_file = compat.fs.cwd().createFile(rcpt_path, .{ .truncate = true }) catch {
            std.debug.print("ERROR: cannot write broadcast_receipt.json\n", .{});
            return 1;
        };
        defer rcpt_file.close();
        rcpt_file.writeAll(rcpt) catch {};
        std.debug.print("  receipt: announced=false (no_direct_transport)\n", .{});
    }

    // Consume bcast_arm.json (one-time use)
    compat.fs.cwd().deleteFile(arm_path) catch {};

    // Print operator file-transfer suggestion
    std.debug.print("\n  Direct N2N block announce requires Ouroboros mini-protocol wiring\n", .{});
    std.debug.print("  (ChainSync warm/hot promotion + BlockFetch) — not yet available.\n", .{});
    std.debug.print("\n  To transfer forge artifacts to the relay manually:\n\n", .{});
    std.debug.print("    scp -r {s} relay:{s}\n\n", .{ forge_dir.?, forge_dir.? });
    std.debug.print("  Or with rsync:\n\n", .{});
    std.debug.print("    rsync -avz {s}/ {s}:{s}/\n\n", .{ forge_dir.?, peer_str.?, forge_dir.? });
    std.debug.print("  Peer: {s}\n", .{peer_str.?});
    std.debug.print("  Receipt: {s}\n", .{rcpt_path});

    return 1;
}

// v4.5.30 regression test: raw-copy fallback must not leave stale destination entries.
// Scenario: destination has stale entries at seq 0..4, source has entries at seq 3..7
// (sliding-window, nonzero start). After raw copy, destination must contain ONLY
// source entries (seq 3..7) — no stale seq 0..2 entries may survive.
test "seal-tip raw copy fallback wipes stale destination entries" {
    const alloc = std.testing.allocator;
    const frag_suffixes = [_][]const u8{ ".header.cbor", ".hash.hex", ".meta.json", ".body.cbor" };

    // Create temp dirs
    const tmp_base = "/tmp/tsunagi_test_sealtip_rawcopy";
    compat.fs.cwd().deleteTree(tmp_base) catch {};
    compat.fs.cwd().makePath(tmp_base) catch unreachable;
    defer compat.fs.cwd().deleteTree(tmp_base) catch {};

    const dest_dir = tmp_base ++ "/dest_fragment";
    const src_dir = tmp_base ++ "/src_fragment";
    compat.fs.cwd().makePath(dest_dir) catch unreachable;
    compat.fs.cwd().makePath(src_dir) catch unreachable;

    // Populate stale destination entries (seq 0..4, old generation)
    for (0..5) |seq| {
        for (&frag_suffixes) |suffix| {
            const path = std.fmt.allocPrint(alloc, "{s}/{d:0>8}{s}", .{ dest_dir, seq, suffix }) catch unreachable;
            defer alloc.free(path);
            var f = compat.fs.cwd().createFile(path, .{ .truncate = true }) catch unreachable;
            f.writeAll("stale") catch {};
            f.close();
        }
    }

    // Populate source entries (seq 3..7, sliding window)
    for (3..8) |seq| {
        for (&frag_suffixes) |suffix| {
            const path = std.fmt.allocPrint(alloc, "{s}/{d:0>8}{s}", .{ src_dir, seq, suffix }) catch unreachable;
            defer alloc.free(path);
            var f = compat.fs.cwd().createFile(path, .{ .truncate = true }) catch unreachable;
            f.writeAll("live") catch {};
            f.close();
        }
    }

    // Simulate v4.5.30 raw copy fallback: wipe + makePath + copy
    compat.fs.cwd().deleteTree(dest_dir) catch {};
    compat.fs.cwd().makePath(dest_dir) catch unreachable;
    {
        var d = compat.fs.cwd().openDir(src_dir, .{ .iterate = true }) catch unreachable;
        defer d.close();
        var it = d.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            const sp = std.fmt.allocPrint(alloc, "{s}/{s}", .{ src_dir, entry.name }) catch continue;
            defer alloc.free(sp);
            const dp = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dest_dir, entry.name }) catch continue;
            defer alloc.free(dp);
            const data = compat.fs.cwd().readFileAlloc(sp, alloc, 64 * 1024) catch continue;
            defer alloc.free(data);
            var ff = compat.fs.cwd().createFile(dp, .{ .truncate = true }) catch continue;
            defer ff.close();
            ff.writeAll(data) catch continue;
        }
    }

    // Verify: no stale entries (seq 0..2) survive
    for (0..3) |seq| {
        for (&frag_suffixes) |suffix| {
            const path = std.fmt.allocPrint(alloc, "{s}/{d:0>8}{s}", .{ dest_dir, seq, suffix }) catch unreachable;
            defer alloc.free(path);
            compat.fs.cwd().access(path, .{}) catch {
                continue; // expected: file not found
            };
            std.debug.print("FAIL: stale entry survived: {s}\n", .{path});
            return error.StaleEntrySurvived;
        }
    }

    // Verify: all source entries (seq 3..7) exist with correct content
    for (3..8) |seq| {
        for (&frag_suffixes) |suffix| {
            const path = std.fmt.allocPrint(alloc, "{s}/{d:0>8}{s}", .{ dest_dir, seq, suffix }) catch unreachable;
            defer alloc.free(path);
            const data = compat.fs.cwd().readFileAlloc(path, alloc, 64 * 1024) catch {
                std.debug.print("FAIL: source entry missing: {s}\n", .{path});
                return error.SourceEntryMissing;
            };
            defer alloc.free(data);
            try std.testing.expectEqualStrings("live", data);
        }
    }

    // Verify: exact file count (5 seqs × 4 suffixes = 20 files)
    var file_count: u32 = 0;
    {
        var d = compat.fs.cwd().openDir(dest_dir, .{ .iterate = true }) catch unreachable;
        defer d.close();
        var it = d.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind == .file) file_count += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 20), file_count);
}

fn bcastPushWriteFailReceipt(alloc: std.mem.Allocator, dir: []const u8, err_msg: []const u8) u8 {
    _ = alloc;
    var rcpt_path_buf: [600]u8 = undefined;
    const rcpt_path = std.fmt.bufPrint(&rcpt_path_buf, "{s}/broadcast_receipt.json", .{dir}) catch return 1;
    const push_unix: i64 = compat.timestamp();
    var rcpt_buf: [512]u8 = undefined;
    const rcpt = std.fmt.bufPrint(&rcpt_buf,
        \\{{"mode":"broadcast","announced":false,"unix":{d},"slot":0,"block_no":0,"peers":0,"error":"{s}","no_inject":true,"tip_before":null,"tip_after":null}}
    , .{ push_unix, err_msg }) catch return 1;
    var f = compat.fs.cwd().createFile(rcpt_path, .{ .truncate = true }) catch return 1;
    defer f.close();
    f.writeAll(rcpt) catch {};
    return 1;
}
