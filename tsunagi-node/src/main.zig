const std = @import("std");
const build_options = @import("build_options");
const compat = @import("compat");

/// 0.16 removed std.process.argsWithAllocator. ArgsIter wraps the
/// compat.argsAlloc slice with the old .next()/.deinit() surface so all
/// existing call sites (including &args_it passed to subcommands) are
/// unchanged. Strings + slice are owned by the backing allocator.
const ArgsIter = struct {
    args: []const [:0]const u8,
    idx: usize = 0,
    alloc: std.mem.Allocator,

    fn init(a: std.mem.Allocator) !ArgsIter {
        return .{ .args = try compat.argsAlloc(a), .alloc = a };
    }
    pub fn next(self: *ArgsIter) ?[:0]const u8 {
        if (self.idx >= self.args.len) return null;
        const a = self.args[self.idx];
        self.idx += 1;
        return a;
    }
    fn deinit(self: *ArgsIter) void {
        self.alloc.free(self.args);
    }
};

const PeerManager = @import("net/peer_manager.zig").PeerManager;
const Mux = @import("net/mux.zig").Mux;
const Message = @import("net/protocol/message.zig").Message;
const ChainSync = @import("net/miniproto/chainsync.zig").ChainSync;
const BlockFetch = @import("net/miniproto/blockfetch.zig").BlockFetch;
const follower = @import("net/chainsync/follower.zig");
const http_metrics = @import("net/metrics/http_metrics.zig");

const memory_bt = @import("net/transport/memory_byte_transport.zig");
const tcp_smoke = @import("net/transport/tcp_smoke.zig");
const tcp_framed_mod = @import("net/transport/tcp_framed.zig");
const handshake_smoke = @import("net/handshake/handshake_smoke.zig");
const handshake_mux_smoke = @import("net/handshake/handshake_mux_smoke.zig");
const chainsync_mux_smoke = @import("net/chainsync/chainsync_mux_smoke.zig");
const i18n = @import("cli/i18n.zig");
const pretty = @import("cli/pretty.zig");
const guardian_cmd = @import("cli/guardian_cmd.zig");
const view_cmd = @import("cli/view.zig");
const correlation_export_cmd = @import("cli/correlation_export.zig");
const kagami_cmd = @import("cli/kagami_cmd.zig");
const forge_sim_cmd = @import("cli/forge_sim_cmd.zig");
const ledger_harness_cmd = @import("cli/ledger_harness_cmd.zig");
const replay = @import("replay/replay.zig");
const replay_run_cmd = @import("replay/replay_run_cmd.zig");
const lmdb_seed = @import("store/lmdb_seed.zig");
const lmdb_backfill = @import("store/lmdb_backfill.zig");
const lmdb_backfill_dir = @import("store/lmdb_backfill_dir.zig");
const lmdb_backfill_autopilot = @import("store/lmdb_backfill_autopilot.zig");
const snapshot_cmd = @import("store/snapshot_cmd.zig");
const snapshot_sign = @import("store/snapshot_sign.zig");
const trust_snapshot_cmd = @import("cli/trust_snapshot_cmd.zig");
const bootstrap_cmd = @import("store/bootstrap_cmd.zig");
const lmdb_digest_cmd = @import("store/lmdb_digest_cmd.zig");
const tsf_artifact_cmd = @import("store/tsf_artifact_cmd.zig");
const capture_retention_cmd = @import("store/capture_retention_cmd.zig");
const capture = @import("replay/capture.zig");
const autoswitch_cmd = @import("store/autoswitch_cmd.zig");
const setup_cmd = @import("cli/setup_cmd.zig");
const console_cmd = @import("cli/console_cmd.zig");
const baey_loop_cmd = @import("cli/baey_loop_cmd.zig");
const footprint_cmd = @import("cli/footprint_cmd.zig");
const vrf_selftest_cmd = @import("cli/vrf_selftest_cmd.zig");
const bodyhash_selftest_cmd = @import("cli/bodyhash_selftest_cmd.zig");
const pack_verify_cmd = @import("cli/pack_verify_cmd.zig");
const pack_now_cmd = @import("cli/pack_now_cmd.zig");
const praos_selftest_cmd = @import("cli/praos_selftest_cmd.zig");
const replay_baseline_cmd = @import("cli/replay_baseline_cmd.zig");
const replay_regress_cmd = @import("cli/replay_regress_cmd.zig");
const schedule_regress_cmd = @import("cli/schedule_regress_cmd.zig");
const kes_selftest_cmd = @import("cli/kes_selftest_cmd.zig");
const praos_regress_cmd = @import("cli/praos_regress_cmd.zig");
const producer_regress_cmd = @import("cli/producer_regress_cmd.zig");
const doppelganger = @import("producer/doppelganger.zig");
const baey_regress_cmd = @import("cli/baey_regress_cmd.zig");
const praos_align_cmd = @import("cli/praos_align_cmd.zig");
const praos_exact_align_cmd = @import("cli/praos_exact_align_cmd.zig");
const praos_threshold_regress_cmd = @import("cli/praos_threshold_regress_cmd.zig");
const header_body_align_cmd = @import("cli/header_body_align_cmd.zig");
const block_candidate_verify_cmd = @import("cli/block_candidate_verify_cmd.zig");
const block_candidate_regress_cmd = @import("cli/block_candidate_regress_cmd.zig");
const readiness_sim_cmd = @import("cli/readiness_sim_cmd.zig");
const producer_ready_cmd = @import("cli/producer_ready_cmd.zig");
const producer_bridge_cmd = @import("cli/producer_bridge_cmd.zig");
const vrf_align_cmd = @import("cli/vrf_align_cmd.zig");
const header_align_cmd = @import("cli/header_align_cmd.zig");
const candidate_verify_cmd = @import("cli/candidate_verify_cmd.zig");
const candidate_validate_cmd = @import("cli/candidate_validate_cmd.zig");
const kes_inspect_cmd = @import("cli/kes_inspect_cmd.zig");
const kes_verify_cmd = @import("cli/kes_verify_cmd.zig");
const kes_align_cmd = @import("cli/kes_align_cmd.zig");
const consensus_align_cmd = @import("cli/consensus_align_cmd.zig");
const evidence_pack_cmd = @import("cli/evidence_pack_cmd.zig");
const build_info_cmd = @import("cli/build_info_cmd.zig");
const repro_report_cmd = @import("cli/repro_report_cmd.zig");
const build_info = @import("build_info.zig");
const cold_start_cmd = @import("cli/cold_start_cmd.zig");
const propagation_server = @import("net/propagation_server.zig");
const autonomy = @import("ops/autonomy.zig");
const peer_rotation = @import("net/peer_rotation.zig");
const snapshot_proof_cmd = @import("cli/snapshot_proof_cmd.zig");
const kes_sign_test_cmd = @import("cli/kes_sign_test_cmd.zig");
const kes_evolve_cmd = @import("cli/kes_evolve_cmd.zig");
const mempool_mod = @import("net/ledger/mempool.zig");
const txsubmission = @import("net/miniproto/txsubmission.zig");
const network_profile = @import("net/network_profile.zig");

fn printMsg(msg: Message) void {
    switch (msg) {
        .chainsync => |m| std.debug.print("[peer] chainsync: {s}\n", .{@tagName(m)}),
        .blockfetch => |m| std.debug.print("[peer] blockfetch: {s}\n", .{@tagName(m)}),
        .txsubmission => |m| std.debug.print("[peer] txsubmission: {s}\n", .{@tagName(m)}),
        .keepalive => |m| std.debug.print("[peer] keepalive: {s}\n", .{@tagName(m)}),
    }
}

fn usage() void {
    std.debug.print(
        \\TSUNAGI Node (Zig-only)
        \\
        \\Usage:
        \\  zig build run
        \\  zig build run -- --version
        \\  zig build run -- run --net mainnet|preprod|preview|sancho [--peer host:port] [--lang en|ja] [--debug]
        \\  zig build run -- doctor [--lang en|ja]
        \\  zig build run -- tcp-smoke <host> <port>
        \\  zig build run -- tcp-framed <host> <port>
        \\  zig build run -- handshake-smoke <host> <port>
        \\  zig build run -- handshake-mux-smoke <host> <port>
        \\  zig build run -- chainsync-mux-smoke <host> <port>
        \\  zig build run -- replay --file <path> [--lang en|ja] [--debug]
        \\  zig build run -- replay-run --file <path> --lmdb <dir> [--max-blocks N] [--from-offset BYTES] [--strict] [--debug] [--report-dir <dir>] [--report-prefix <name>] [--repeat N] [--fresh] [--perf] [--quiet] [--baseline-json <path>] [--regress-threshold N] [--trend]
        \\  zig build run -- lmdb-seed --snapshot <path> [--lmdb <dir>] [--limit N]
        \\  zig build run -- lmdb-backfill --file <capture.bin> [--lmdb <dir>] [--max N] [--strict]
        \\  zig build run -- lmdb-backfill-dir --dir <captures_dir> [--lmdb <dir>] [--max-per-file N] [--net <name>] [--strict]
        \\  zig build run -- lmdb-backfill-inc --dir <captures_dir> [--lmdb <dir>] [--max-blocks N] [--max-seconds S] [--cursor <path>] [--net <name>] [--strict]
        \\  zig build run -- snapshot-export --out <file> [--lmdb <dir>] [--signing-key <path>]
        \\  zig build run -- snapshot-import --file <file> [--lmdb <dir>] [--verify-digest <hex64>] [--strict] [--pubkey <hex>] [--pubkey-file <path>] [--allow-unsigned]
        \\  zig build run -- snapshot-keygen
        \\  zig build run -- snapshot-sign --file <path> [--key <path>]
        \\  zig build run -- snapshot-verify --file <path> [--sig <path>] [--pubkey <hex>] [--pubkey-file <path>]
        \\  zig build run -- trust-snapshot [--out <file>] [--key <path>] [--port <N>]
        \\  zig build run -- trust-verify --file <path> [--pubkey <hex>] [--pubkey-file <path>]
        \\  zig build run -- trust-reputation [--out <file>] [--key <path>]
        \\  zig build run -- trust-exchange [--key <path>]
        \\  zig build run -- trust-federate [--key <path>]
        \\  zig build run -- trust-graph [--key <path>]
        \\  zig build run -- trust-propagate [--key <path>]
        \\  zig build run -- bootstrap --file <snapshot.tsf> [--lmdb <dir>]
        \\  zig build run -- lmdb-digest [--lmdb <dir>]
        \\  zig build run -- tsf-artifact --lmdb <dir> --out <file> --test-dir <dir> [--gzip] [--strict] [--signing-key <path>]
        \\  zig build run -- capture-retention --dir <captures_dir> [--max-bytes N]
        \\  zig build run -- autoswitch-apply
        \\  zig build run -- setup --role relay|tools|bp [--install latest|vX.Y.Z] [--autoswitch] [--lang en|ja]
        \\  zig build run -- submit-tx --file <tx.cbor> | --hex <hex> [--offline]
        \\  zig build run -- mempool  (queries running node)
        \\  zig build run -- forge-sim --dir <dryrun_slot_dir> --out <report.json>
        \\  zig build run -- guardian <tx-build|tx-submit|tx-status|kes-status|proof-latest|doctor|forge-status|seal-latest|airgap-opcert|yamori|kura> [options]
        \\  zig build run -- ledger-harness <snapshot|digest|rewind|replay|verify> [options]
        \\  zig build run -- console [--lang en|ja]
        \\  zig build run -- baey-loop [--dry-run] [--apply]
        \\  zig build run -- vrf-selftest
        \\  zig build run -- bodyhash-selftest
        \\  zig build run -- pack-verify --dir <pack-directory>
        \\  zig build run -- pack-now
        \\  zig build run -- praos-selftest --stake-x1e9 <N> --asc-x1e6 <N> --vrf-output-hex <128 hex chars>
        \\  zig build run -- schedule-regress
        \\  zig build run -- kes-selftest [--slot <N>] [--start-period <N>] [--max-periods <N>]
        \\  zig build run -- kes-inspect --key <path>
        \\  zig build run -- kes-verify --pk <hex> --period <N> --msg <hex> --sig <hex> | --selftest
        \\  zig build run -- kes-align --vectors <path.jsonl>
        \\  zig build run -- praos-regress [--slots <N>] [--init-baseline]
        \\  zig build run -- producer-regress [--slots <N>] [--init-baseline]
        \\  zig build run -- baey-regress [--seed <N>] [--init-baseline]
        \\  zig build run -- praos-threshold-regress --vectors <path.jsonl>
        \\  zig build run -- header-body-align --vectors <path.jsonl>
        \\  zig build run -- candidate-validate --bundle-dir <path> [--out <path>]
        \\  zig build run -- block-candidate-verify --dir <dryrun_slot_dir> [--expect-tx-hash <64hex>]
        \\  zig build run -- block-candidate-regress --vectors <path.jsonl>
        \\  zig build run -- readiness-sim --vectors <file.jsonl> --out <report.json>
        \\  zig build run -- producer-ready --slot <N> [--vrf-skey <path>] [--kes-skey <path>] [--pool-id <hex>] [--stake-x1e9 <N>] [--out <path>]
        \\  zig build run -- producer-bridge [--state-dir <path>] [--net preview] [--slot <N>] [--bundle-dir <path>] [--out <path>]
        \\  zig build run -- praos-align [--vectors <path.jsonl>]
        \\  zig build run -- vrf-align [--vectors <path.jsonl>]
        \\  zig build run -- consensus-align --vectors <path.jsonl> --mode <praos|vrf|header|tx|all> [--verbose]
        \\  zig build run -- evidence-pack --home <path> --net <preview|mainnet> --out <dir> [--limit N] [--strict] [--port N] [--notarize-gpg] [--gpg-key <id>] [--gpg-homedir <path>] [--gpg-armor]
        \\  zig build run -- evidence-pack --cold-start --snapshot <path> --net <net> --out <dir> [--strict]
        \\  zig build run -- cold-start --snapshot <path> --out-lmdb <dir> [--verify-digest <hex64>] [--strict]
        \\  zig build run -- snapshot-proof --file <tsf> --keydir <dir> [--out <dir>] [--net <name>] [--strict]
        \\  zig build run -- build-info [--json]
        \\  zig build run -- repro-report [--json]
        \\  zig build run -- header-align --candidate-v2|--cardano-header-bytes [--vectors <path.jsonl>]
        \\  zig build run -- propagate-serve --net preview --artifact-dir <dir> --allowlist <ips> [--port N] [--arm-token <path>] [--receipts-dir <dir>]
        \\  zig build run -- footprint
        \\  zig build run -- replay-baseline --file <capture.bin> --out-dir <dir> [--max-blocks N] [--repeat N] [--force]
        \\  zig build run -- replay-regress --file <capture.bin> --out-dir <dir> [--baseline-json <path>] [--max-blocks N] [--repeat N] [--regress-threshold N] [--trend]
        \\
        \\Default: runs in-memory framed mux demo.
        \\
    , .{});
}

fn fileExists(path: []const u8) bool {
    var f = compat.fs.openFileAbsolute(path, .{}) catch return false;
    f.close();
    return true;
}

/// Resolve TSUNAGI_HOME: env var takes priority, then $HOME/<net_suffix>.
/// This is the single authoritative resolution point for TSUNAGI_HOME.
fn resolveHome(alloc: std.mem.Allocator, net_suffix: []const u8) ![]u8 {
    // 1. TSUNAGI_HOME env always takes priority
    const env_dir = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_dir) |dir| {
        if (dir.len > 0) return dir;
        alloc.free(dir);
    }

    // 2. Network-specific default: $HOME/<net_suffix>
    const home = compat.getEnvVarOwned(alloc, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (home) |dir| {
        defer alloc.free(dir);
        return try std.fs.path.join(alloc, &[_][]const u8{ dir, net_suffix });
    }
    return error.EnvironmentVariableNotFound;
}

fn getStateDir(alloc: std.mem.Allocator) ![]u8 {
    return resolveHome(alloc, ".tsunagi");
}

fn parseFlagValue(arg: []const u8, name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, arg, name)) return null;
    if (arg.len == name.len) return null;
    if (arg[name.len] != '=') return null;
    return arg[name.len + 1 ..];
}

// libc setenv — Zig 0.15.2 has no native equivalent.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// Auto-load ${TSUNAGI_HOME}/forge.env into process env BEFORE any env reads.
/// KEY=VALUE per line; # comments, blank lines, optional `export ` prefix and
/// matched surrounding quotes accepted. Uses setenv(overwrite=1) so file values
/// win over stale shell exports — node config is deterministic from the file.
fn loadForgeConfig(alloc: std.mem.Allocator, home: []const u8) void {
    var pbuf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/forge.env", .{home}) catch return;

    var f = compat.fs.cwd().openFile(path, .{}) catch {
        std.debug.print("CONFIG_NOT_FOUND: path={s}\n", .{path});
        return;
    };
    defer f.close();

    var rbuf: [16 * 1024]u8 = undefined;
    const n = f.readAll(&rbuf) catch {
        std.debug.print("CONFIG_READ_FAIL: path={s}\n", .{path});
        return;
    };
    const data = rbuf[0..n];

    var loaded: usize = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw_line| {
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        while (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) line = line[1..];
        if (line.len == 0) continue;
        if (line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) line = line[7..];
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        var val = line[eq + 1 ..];
        while (val.len > 0 and (val[val.len - 1] == ' ' or val[val.len - 1] == '\t')) val = val[0 .. val.len - 1];
        if (val.len >= 2 and (val[0] == '"' or val[0] == '\'') and val[val.len - 1] == val[0]) {
            val = val[1 .. val.len - 1];
        }
        if (key.len == 0) continue;

        const key_z = alloc.allocSentinel(u8, key.len, 0) catch continue;
        defer alloc.free(key_z);
        @memcpy(key_z[0..key.len], key);
        const val_z = alloc.allocSentinel(u8, val.len, 0) catch continue;
        defer alloc.free(val_z);
        @memcpy(val_z[0..val.len], val);

        // overwrite=1 — forge.env wins over shell exports for deterministic config.
        const rc = setenv(key_z.ptr, val_z.ptr, 1);
        if (rc == 0) loaded += 1;
    }
    std.debug.print("CONFIG_LOADED: path={s} keys={d}\n", .{ path, loaded });
}

/// Parse env var as boolean for safety-critical flags. Returns:
///   null  if unset
///   true  if value is one of "1", "true", "yes", "on" (case-insensitive)
///   false otherwise (including "0", "false", "no", "off", "", typos)
///
/// Use this instead of std.process.hasEnvVar for forge/broadcast/guardian
/// gates: the operator must be able to explicitly disable a feature via
/// VAR=0 in forge.env. Presence-only tests treat VAR=0 as "set therefore
/// enabled", which is a footgun under the forge.env-authoritative model
/// (forge.env loads with overwrite=1 → cannot be unset from outside the file).
fn envFlag(key: []const u8) ?bool {
    const v = compat.getenv(key) orelse return null;
    if (v.len == 0) return false;
    if (v.len > 16) return true;
    var buf: [16]u8 = undefined;
    for (v, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const lower = buf[0..v.len];
    if (std.mem.eql(u8, lower, "1")) return true;
    if (std.mem.eql(u8, lower, "true")) return true;
    if (std.mem.eql(u8, lower, "yes")) return true;
    if (std.mem.eql(u8, lower, "on")) return true;
    return false;
}

/// When TSUNAGI_FORGE_ENABLE is truthy but companion guard flags are unset,
/// auto-set them to "1" so the forge guard is trivially satisfiable.
fn ensureForgeCompanions(alloc: std.mem.Allocator) void {
    if (envFlag("TSUNAGI_FORGE_ENABLE") != true) return;

    const inner = struct {
        fn ensure(a: std.mem.Allocator, key: []const u8) void {
            if (compat.getenv(key) != null) return;
            const key_z = a.allocSentinel(u8, key.len, 0) catch return;
            defer a.free(key_z);
            @memcpy(key_z[0..key.len], key);
            const val_z = a.allocSentinel(u8, 1, 0) catch return;
            defer a.free(val_z);
            val_z[0] = '1';
            if (setenv(key_z.ptr, val_z.ptr, 0) == 0) {
                std.debug.print("FORGE_AUTO_COMPANION: {s}=1\n", .{key});
            }
        }
    };
    inner.ensure(alloc, "TSUNAGI_FORGE_PREVIEW_ONLY");
    inner.ensure(alloc, "TSUNAGI_FORGE_REQUIRE_GUARDIAN_CONFIRM");
}

pub fn main() !void {
    // Use libc allocator: glibc malloc returns freed pages to the OS via
    // madvise(MADV_DONTNEED), preventing the monotonic RSS growth that Zig's
    // GeneralPurposeAllocator causes under CBOR decode/free churn.
    const alloc = std.heap.c_allocator;

    const pm = PeerManager.init();
    _ = pm;

    var args_it = try ArgsIter.init(alloc);
    defer args_it.deinit();

    _ = args_it.next(); // argv[0]

    if (args_it.next()) |cmd| {
        if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v") or std.mem.eql(u8, cmd, "version")) {
            var stderr_file = compat.fs.File.stderr();
            const stderr = stderr_file.writer();
            build_info.printVersionLine(stderr) catch {};
            return;
        }
        if (std.mem.eql(u8, cmd, "view")) {
            try view_cmd.run(alloc, &args_it);
            return;
        }
        if (std.mem.eql(u8, cmd, "correlation-export")) {
            try correlation_export_cmd.run(alloc, &args_it);
            return;
        }
        if (std.mem.eql(u8, cmd, "run")) {
            // Phase: first-accepted-block sprint — doppelganger guard (observation-only).
            doppelganger.check(alloc);

            var lang: i18n.Lang = .en;
            var debug = false;
            var net_str: ?[]const u8 = null;
            var peer_override: ?[]const u8 = null;

            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--debug")) {
                    debug = true;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--peer")) {
                    peer_override = args_it.next() orelse {
                        std.debug.print("missing value for --peer\n", .{});
                        return error.InvalidArgs;
                    };
                    continue;
                }
                if (parseFlagValue(arg, "--peer")) |val| {
                    peer_override = val;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--lang")) {
                    lang = i18n.parseLang(args_it.next());
                    continue;
                }
                if (parseFlagValue(arg, "--lang")) |val| {
                    lang = i18n.parseLang(val);
                    continue;
                }
                if (std.mem.eql(u8, arg, "--net")) {
                    net_str = args_it.next() orelse {
                        std.debug.print("missing value for --net\n", .{});
                        return error.InvalidArgs;
                    };
                    continue;
                }
                if (parseFlagValue(arg, "--net")) |val| {
                    net_str = val;
                    continue;
                }
                std.debug.print("unknown flag: {s}\n", .{arg});
                return error.InvalidArgs;
            }

            // Resolve network: --net flag > TSUNAGI_NET env > error
            const effective_net_str = net_str orelse blk: {
                const env_net = compat.getEnvVarOwned(alloc, "TSUNAGI_NET") catch null;
                if (env_net) |n| {
                    if (n.len > 0) break :blk @as([]const u8, n);
                    alloc.free(n);
                }
                std.debug.print("ERROR: --net is required (mainnet, preprod, preview, sancho)\n", .{});
                std.debug.print("  or set TSUNAGI_NET environment variable\n", .{});
                return error.InvalidArgs;
            };

            const net_enum = network_profile.parseNet(effective_net_str) orelse {
                std.debug.print("unknown --net value: {s}\n", .{effective_net_str});
                std.debug.print("  supported: mainnet, preprod, preview, sancho\n", .{});
                return error.InvalidArgs;
            };
            const profile = network_profile.getProfile(net_enum);

            // Resolve TSUNAGI_HOME and load ${TSUNAGI_HOME}/forge.env BEFORE any
            // TSUNAGI_* env read. setenv(overwrite=1) in loadForgeConfig makes
            // the file authoritative over inherited shell exports. NOTHING above
            // this point may call getenv on a TSUNAGI_* var, otherwise the file
            // value will not be visible.
            const state_dir = resolveHome(alloc, profile.home_suffix) catch {
                std.debug.print("ERROR: cannot resolve TSUNAGI_HOME (set TSUNAGI_HOME or HOME)\n", .{});
                return error.InvalidArgs;
            };
            loadForgeConfig(alloc, state_dir);
            ensureForgeCompanions(alloc);

            // Live-forging defaults (preview only). setenv overwrite=0 means
            // forge.env / shell exports always win; we only fill unset values.
            // Mainnet/preprod/sancho stay observe-only; their FORGE_ENABLE
            // FATAL gate (below) would refuse a default of 1 on those nets.
            if (std.mem.eql(u8, effective_net_str, "preview")) {
                _ = setenv("TSUNAGI_FORGE_ENABLE", "1", 0);
                _ = setenv("TSUNAGI_FORGE_NO_BROADCAST", "0", 0);
                _ = setenv("TSUNAGI_FORGE_POLICY", "forge", 0);
                _ = setenv("TSUNAGI_MODE", "live", 0);
                _ = setenv("TSUNAGI_STALE_PARENT_MAX_SLOTS", "120", 0);
                _ = setenv("TSUNAGI_FORGE_REQUIRE_GUARDIAN_CONFIRM", "1", 0);
            }

            std.debug.print("TSUNAGI_ENV_POST_CONFIG: TSUNAGI_FORGE_ENABLE={s} TSUNAGI_VRF_ENABLE={s} TSUNAGI_KES_ENABLE={s}\n", .{
                compat.getenv("TSUNAGI_FORGE_ENABLE") orelse "<unset>",
                compat.getenv("TSUNAGI_VRF_ENABLE") orelse "<unset>",
                compat.getenv("TSUNAGI_KES_ENABLE") orelse "<unset>",
            });
            // EFFECTIVE_CONFIG prints parsed booleans, not raw env strings, so
            // VAR=0 in forge.env shows as the disabled state operators expect.
            const forge_enable_bool = envFlag("TSUNAGI_FORGE_ENABLE") orelse false;
            const no_broadcast_bool = envFlag("TSUNAGI_FORGE_NO_BROADCAST") orelse false;
            std.debug.print("EFFECTIVE_CONFIG: forge_enable={d} broadcast={d} policy={s} mode={s} stale_parent_max={s} peer={s}\n", .{
                @intFromBool(forge_enable_bool),
                @intFromBool(!no_broadcast_bool),
                compat.getenv("TSUNAGI_FORGE_POLICY") orelse "observe",
                compat.getenv("TSUNAGI_MODE") orelse "preview_safe",
                compat.getenv("TSUNAGI_STALE_PARENT_MAX_SLOTS") orelse "40",
                peer_override orelse (compat.getenv("TSUNAGI_PEER") orelse "<unset>"),
            });

            // Runtime mode — single source of truth for forge/broadcast behavior.
            //   TSUNAGI_MODE = preview_safe (default) | live
            //     preview_safe — forge locally, do not broadcast to peers.
            //     live         — forge and broadcast.
            // Read AFTER forge.env so the file value takes effect.
            const mode_str: []const u8 = compat.getenv("TSUNAGI_MODE") orelse "preview_safe";
            const is_live = std.mem.eql(u8, mode_str, "live");
            if (!is_live and !std.mem.eql(u8, mode_str, "preview_safe")) {
                std.debug.print("FATAL: TSUNAGI_MODE='{s}' — supported values: preview_safe | live\n", .{mode_str});
                std.process.exit(99);
            }

            std.debug.print("MODE: {s} ({s})\n", .{
                mode_str,
                if (is_live) "broadcast enabled" else "no broadcast",
            });

            // Block production gate — opens forge path when keys are configured.
            // Surviving safety rails (deliberate): preview-only network, guardian-
            // confirm flag, TSUNAGI_TXSUB_BROADCAST refused (separate channel).
            //
            // Value-based parsing via envFlag: TSUNAGI_FORGE_ENABLE=0 in forge.env
            // disables forge (presence-only test treated =0 as "set therefore on",
            // making it impossible to opt out via forge.env once preview live-
            // defaults filled the key).
            const forge_enable = envFlag("TSUNAGI_FORGE_ENABLE") orelse false;
            if (forge_enable) {
                if (!std.mem.eql(u8, effective_net_str, "preview")) {
                    std.debug.print("FATAL: TSUNAGI_FORGE_ENABLE=1 is only allowed on --net preview\n", .{});
                    std.process.exit(99);
                }
                if (envFlag("TSUNAGI_FORGE_REQUIRE_GUARDIAN_CONFIRM") != true) {
                    std.debug.print("FATAL: TSUNAGI_FORGE_ENABLE=1 requires TSUNAGI_FORGE_REQUIRE_GUARDIAN_CONFIRM=1\n", .{});
                    std.process.exit(99);
                }
                if (envFlag("TSUNAGI_TXSUB_BROADCAST") == true) {
                    std.debug.print("FATAL: TSUNAGI_FORGE_ENABLE=1 but TSUNAGI_TXSUB_BROADCAST is set. REFUSE.\n", .{});
                    std.process.exit(99);
                }
                std.debug.print("FORGE: enabled (mode={s})\n", .{mode_str});
            } else {
                std.debug.print("FORGE: disabled (observe-only) — TSUNAGI_FORGE_ENABLE={s}\n", .{
                    compat.getenv("TSUNAGI_FORGE_ENABLE") orelse "<unset>",
                });
            }

            // PR-A: operator-grade autonomy primitives. Order matters:
            //   1. acquireLock — refuse if a sibling tsunagi-node holds the home.
            //   2. installLogTee — capture every subsequent debug.print to disk.
            //   3. markActive — clear stale clean marker; markClean fires via defer.
            try autonomy.acquireLock(state_dir);
            autonomy.installLogTee(state_dir) catch |e| {
                std.debug.print("LOG_TEE_INSTALL_FAILED: {s} — continuing without file log\n", .{@errorName(e)});
            };
            autonomy.markActive(state_dir);
            defer autonomy.markClean(state_dir);

            var host: []const u8 = undefined;
            var port: u16 = undefined;
            var used_peer_override = false;
            var host_owned = false;

            if (peer_override) |peer| {
                const colon = std.mem.indexOfScalar(u8, peer, ':') orelse {
                    std.debug.print("invalid --peer value (expected host:port)\n", .{});
                    return error.InvalidArgs;
                };
                host = peer[0..colon];
                const port_str = peer[colon + 1 ..];
                port = std.fmt.parseUnsigned(u16, port_str, 10) catch {
                    std.debug.print("invalid --peer port\n", .{});
                    return error.InvalidArgs;
                };
                used_peer_override = true;
            } else {
                if (profile.is_mainnet) {
                    const timeout_ms: u32 = 3_000;
                    const peer = try follower.selectMainnetPeer(alloc, timeout_ms) orelse {
                        std.debug.print(
                            "mainnet peer selection failed; pass --peer host:port\n",
                            .{},
                        );
                        return error.InvalidArgs;
                    };
                    host = peer.host;
                    port = peer.port;
                    host_owned = true;
                } else {
                    host = profile.default_relay_host;
                    port = profile.default_relay_port;
                }
            }

            pretty.printHeader(lang);
            defer if (host_owned) alloc.free(host);
            std.debug.print("TSUNAGI_HOME: {s}\n", .{state_dir});
            // v1.5.10: canonical profile log for drift detection
            if (profile.is_mainnet) {
                std.debug.print("PROFILE: net={s} magic={d} relay=(relay list):{d} home={s} genesis_dir={s}\n", .{
                    profile.name, profile.network_magic, profile.default_relay_port, state_dir, profile.genesis_dir_name,
                });
            } else {
                std.debug.print("PROFILE: net={s} magic={d} relay={s}:{d} home={s} genesis_dir={s}\n", .{
                    profile.name, profile.network_magic, profile.default_relay_host, profile.default_relay_port, state_dir, profile.genesis_dir_name,
                });
            }
            if (used_peer_override) {
                if (lang == .ja) {
                    std.debug.print("接続先指定: {s}:{d}\n", .{ host, port });
                } else {
                    std.debug.print("Peer override: {s}:{d}\n", .{ host, port });
                }
            } else {
                if (lang == .ja) {
                    std.debug.print("ネットワーク: {s} 接続先={s}:{d}\n", .{ profile.name, host, port });
                } else {
                    std.debug.print("Network: {s} peer={s}:{d}\n", .{ profile.name, host, port });
                }
            }
            std.debug.print("{s}\n", .{i18n.msg(lang, "running")});
            std.debug.print("{s}\n", .{i18n.msg(lang, "ctrlc_hint")});

            var metrics = http_metrics.Metrics.initDefault();
            const metrics_enabled = debug or compat.hasEnvVar(alloc, "TSUNAGI_METRICS");

            var mp = mempool_mod.Mempool.init(alloc, mempool_mod.DEFAULT_MAX_ITEMS, mempool_mod.DEFAULT_MAX_BYTES);
            defer mp.deinit();
            txsubmission.g_mempool = &mp;

            // Resolve backfill stats bridge path for metrics export
            const bf_stats_path: ?[]const u8 = std.fs.path.join(alloc, &[_][]const u8{ state_dir, "backfill.stats.json" }) catch null;
            const bf_captures_dir: ?[]const u8 = std.fs.path.join(alloc, &[_][]const u8{ state_dir, "captures" }) catch null;

            // Resolve metrics bind address and port from env vars
            const metrics_bind_addr: [4]u8 = blk: {
                const addr_str = compat.getEnvVarOwned(alloc, "TSUNAGI_METRICS_ADDR") catch break :blk [4]u8{ 127, 0, 0, 1 };
                defer alloc.free(addr_str);
                if (addr_str.len == 0) break :blk [4]u8{ 127, 0, 0, 1 };
                // Validate by parsing then extract bytes
                const parsed = std.Io.net.IpAddress.parseIp4(addr_str, 0) catch {
                    std.debug.print("ERROR: invalid TSUNAGI_METRICS_ADDR: {s}\n", .{addr_str});
                    return error.InvalidArgs;
                };
                break :blk parsed.ip4.bytes;
            };
            const metrics_bind_port: u16 = blk: {
                const port_str = compat.getEnvVarOwned(alloc, "TSUNAGI_METRICS_PORT") catch break :blk 9080;
                defer alloc.free(port_str);
                if (port_str.len == 0) break :blk 9080;
                break :blk std.fmt.parseInt(u16, port_str, 10) catch {
                    std.debug.print("ERROR: invalid TSUNAGI_METRICS_PORT: {s}\n", .{port_str});
                    return error.InvalidArgs;
                };
            };

            // v1.7.0: tx submission relay (opt-in)
            const txsub_enabled = compat.hasEnvVar(alloc, "TSUNAGI_TXSUB_ENABLE");
            if (txsub_enabled) {
                std.debug.print("TXSUB RELAY: enabled (TSUNAGI_TXSUB_ENABLE=1)\n", .{});
                const txsub_dir = std.fs.path.join(alloc, &[_][]const u8{ state_dir, "txsub" }) catch null;
                if (txsub_dir) |dir| compat.fs.cwd().makePath(dir) catch {};
            } else {
                std.debug.print("TXSUB RELAY: disabled (set TSUNAGI_TXSUB_ENABLE=1 to enable)\n", .{});
            }

            // preview_safe artifact directories — populated when forge runs but
            // broadcast is suppressed, so an operator can inspect candidate blocks.
            if (forge_enable and !is_live) {
                const dryrun_dir = std.fs.path.join(alloc, &[_][]const u8{ state_dir, "producer_dryrun", "candidates" }) catch null;
                if (dryrun_dir) |dir| compat.fs.cwd().makePath(dir) catch {};
                const dryrun_blocks_dir = std.fs.path.join(alloc, &[_][]const u8{ state_dir, "producer_dryrun", "blocks" }) catch null;
                if (dryrun_blocks_dir) |dir| compat.fs.cwd().makePath(dir) catch {};
            }
            // forge_sim + guardian directories
            if (forge_enable) {
                const forge_sim_dir = std.fs.path.join(alloc, &[_][]const u8{ state_dir, "producer_forge_sim" }) catch null;
                if (forge_sim_dir) |dir| compat.fs.cwd().makePath(dir) catch {};
                const forge_guardian_dir = std.fs.path.join(alloc, &[_][]const u8{ state_dir, "guardian" }) catch null;
                if (forge_guardian_dir) |dir| compat.fs.cwd().makePath(dir) catch {};
            }

            var metrics_server: ?http_metrics.Server = null;
            if (metrics_enabled) {
                metrics_server = http_metrics.Server{ .alloc = alloc, .metrics = &metrics, .mempool = &mp, .backfill_stats_path = bf_stats_path, .captures_dir_path = bf_captures_dir, .bind_addr = metrics_bind_addr, .bind_port = metrics_bind_port, .profile_net = profile.name, .profile_magic = @as(u64, profile.network_magic), .profile_relay_host = host, .profile_relay_port = port, .profile_genesis_dir = profile.genesis_dir_name, .txsub_enabled = txsub_enabled, .txsub_home_path = state_dir };
                metrics_server.?.start() catch {};
                // Surface preview_safe (no-broadcast) state via the existing metric.
                if (forge_enable and !is_live) {
                    metrics.producer_dryrun_enabled.store(1, .release);
                }
            } else {
                std.debug.print("METRICS: disabled (TSUNAGI_METRICS!=1)\n", .{});
            }
            defer if (metrics_server) |*ms| ms.shutdown();

            // Set network-aware capture filename prefix (e.g. "preview.bin" instead of "mainnet.bin")
            capture.setNetPrefix(profile.name);
            if (capture.enabled()) {
                std.debug.print("CAPTURE: file={s}/captures/{s}.bin rotate_mb={d}\n", .{ state_dir, profile.name, capture.rotateBytes() / (1024 * 1024) });
            }

            // Auto-start propagation server when forge is enabled
            if (forge_enable) {
                if (propagation_server.spawnBackground(alloc, state_dir, profile.genesis_dir_name)) {
                    std.debug.print("PROPAGATION: auto-started (forge mode)\n", .{});
                } else {
                    std.debug.print("PROPAGATION: auto-start failed — blocks won't reach relay\n", .{});
                }
            }

            // PR-D: peer rotation loop. Single peer (host:port resolved above)
            // is the first attempt; on disconnect / connect failure we rotate
            // through the resolved peer list (TSUNAGI_PEER_PRIMARY env →
            // --peer flag → ${TSUNAGI_HOME}/peers.json → preview fallback →
            // profile.default_relay). Exits cleanly when the follower's
            // signal handler observes SIGINT/SIGTERM (shutdownRequested).
            // Reconstruct "host:port" for the primary override since
            // peer_rotation.buildPeerList expects the full string form.
            var primary_buf: [144]u8 = undefined;
            const primary_str: ?[]const u8 = if (used_peer_override)
                (std.fmt.bufPrint(&primary_buf, "{s}:{d}", .{ host, port }) catch null)
            else
                null;
            const peers = peer_rotation.buildPeerList(
                state_dir,
                profile.name,
                profile.default_relay_host,
                profile.default_relay_port,
                primary_str,
            );
            if (peers.count == 0) {
                std.debug.print("FATAL: no upstream peer available (peers.json + fallback list both empty)\n", .{});
                return error.NoPeer;
            }

            // Find the starting index = the host:port we already resolved.
            var idx: usize = 0;
            {
                var i: usize = 0;
                while (i < peers.count) : (i += 1) {
                    const e = &peers.entries[i];
                    if (e.port == port and std.mem.eql(u8, e.host(), host)) {
                        idx = i;
                        break;
                    }
                }
            }

            var fail_streak: u32 = 0;
            while (true) {
                const e = &peers.entries[idx];
                std.debug.print("PEER_CONNECT_ATTEMPT: host={s} port={d} idx={d}/{d} fail_streak={d}\n", .{
                    e.host(), e.port, idx, peers.count, fail_streak,
                });
                const t0_ms: i64 = compat.milliTimestamp();
                chainsync_mux_smoke.runWithOptions(
                    alloc,
                    e.host(),
                    e.port,
                    lang,
                    debug,
                    true,
                    profile.is_mainnet,
                    @as(u64, profile.network_magic),
                    state_dir,
                    profile.genesis_dir_name,
                    &metrics,
                ) catch |err| {
                    const dt_s: i64 = @divTrunc(compat.milliTimestamp() - t0_ms, 1000);
                    std.debug.print("PEER_CONNECT_FAIL: host={s} port={d} err={s} held_s={d}\n", .{
                        e.host(), e.port, @errorName(err), dt_s,
                    });
                };

                // Did the operator request shutdown? Follower's signal
                // handler sets g_signal_received which we read via the
                // shutdownRequested accessor.
                if (follower.shutdownRequested()) {
                    std.debug.print("PEER_LOOP_EXIT: reason=shutdown_requested\n", .{});
                    break;
                }

                // Returned without a signal — treat as disconnect; rotate.
                const dt_s: i64 = @divTrunc(compat.milliTimestamp() - t0_ms, 1000);
                std.debug.print("PEER_DISCONNECTED: host={s} port={d} held_s={d}\n", .{ e.host(), e.port, dt_s });
                // A held connection >= 30s is treated as "this peer worked once" — reset backoff.
                if (dt_s >= 30) fail_streak = 0 else fail_streak +%= 1;
                idx = peer_rotation.rotateIdx(idx, peers.count);
                std.debug.print("PEER_ROTATE: next_host={s} next_port={d} idx={d}/{d}\n", .{
                    peers.entries[idx].host(), peers.entries[idx].port, idx, peers.count,
                });
                const sleep_ms = peer_rotation.backoffMs(fail_streak);
                std.debug.print("PEER_BACKOFF_SLEEP_MS: {d}\n", .{sleep_ms});
                compat.sleep(sleep_ms * std.time.ns_per_ms);
                if (follower.shutdownRequested()) {
                    std.debug.print("PEER_LOOP_EXIT: reason=shutdown_during_backoff\n", .{});
                    break;
                }
            }
            return;
        } else if (std.mem.eql(u8, cmd, "doctor")) {
            var lang: i18n.Lang = .en;
            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--lang")) {
                    lang = i18n.parseLang(args_it.next());
                    continue;
                }
                if (parseFlagValue(arg, "--lang")) |val| {
                    lang = i18n.parseLang(val);
                    continue;
                }
                std.debug.print("unknown flag: {s}\n", .{arg});
                return error.InvalidArgs;
            }

            const ok = i18n.msg(lang, "doctor_ok");
            const fail = i18n.msg(lang, "doctor_fail");

            const state_dir = try getStateDir(alloc);
            defer alloc.free(state_dir);
            compat.fs.cwd().makePath(state_dir) catch {};
            const cursor_path = try std.fs.path.join(alloc, &[_][]const u8{ state_dir, "cursor.json" });
            defer alloc.free(cursor_path);
            const journal_path = try std.fs.path.join(alloc, &[_][]const u8{ state_dir, "journal.ndjson" });
            defer alloc.free(journal_path);
            const utxo_path = try std.fs.path.join(alloc, &[_][]const u8{ state_dir, "utxo.snapshot" });
            defer alloc.free(utxo_path);

            std.debug.print("state_dir: {s}\n", .{state_dir});
            const cursor_exists = fileExists(cursor_path);
            const journal_exists = fileExists(journal_path);
            const utxo_exists = fileExists(utxo_path);

            std.debug.print("cursor.json: {s}\n", .{if (cursor_exists) ok else fail});
            std.debug.print("journal.ndjson: {s}\n", .{if (journal_exists) ok else fail});
            std.debug.print("utxo.snapshot: {s}\n", .{if (utxo_exists) ok else fail});
            return;
        } else if (std.mem.eql(u8, cmd, "tcp-smoke")) {
            const host = args_it.next() orelse {
                usage();
                return error.InvalidArgs;
            };
            const port_s = args_it.next() orelse {
                usage();
                return error.InvalidArgs;
            };
            const port_u = std.fmt.parseUnsigned(u16, port_s, 10) catch {
                usage();
                return error.InvalidArgs;
            };
            try tcp_smoke.run(alloc, host, port_u);
            return;
        } else if (std.mem.eql(u8, cmd, "tcp-framed")) {
            const host = args_it.next() orelse {
                usage();
                return error.InvalidArgs;
            };
            const port_s = args_it.next() orelse {
                usage();
                return error.InvalidArgs;
            };
            const port_u = std.fmt.parseUnsigned(u16, port_s, 10) catch {
                usage();
                return error.InvalidArgs;
            };
            try tcp_framed_mod.run(alloc, host, port_u);
            return;
        } else if (std.mem.eql(u8, cmd, "handshake-smoke")) {
            const host = args_it.next() orelse {
                usage();
                return error.InvalidArgs;
            };
            const port_s = args_it.next() orelse {
                usage();
                return error.InvalidArgs;
            };
            const port_u = std.fmt.parseUnsigned(u16, port_s, 10) catch {
                usage();
                return error.InvalidArgs;
            };
            try handshake_smoke.run(alloc, host, port_u);
            return;
        } else if (std.mem.eql(u8, cmd, "handshake-mux-smoke")) {
            const host = args_it.next() orelse {
                usage();
                return error.InvalidArgs;
            };
            const port_s = args_it.next() orelse {
                usage();
                return error.InvalidArgs;
            };
            const port_u = std.fmt.parseUnsigned(u16, port_s, 10) catch {
                usage();
                return error.InvalidArgs;
            };
            try handshake_mux_smoke.run(alloc, host, port_u);
            return;
        } else if (std.mem.eql(u8, cmd, "chainsync-mux-smoke")) {
            const host = args_it.next() orelse {
                usage();
                return error.InvalidArgs;
            };
            const port_s = args_it.next() orelse {
                usage();
                return error.InvalidArgs;
            };
            const port_u = std.fmt.parseUnsigned(u16, port_s, 10) catch {
                usage();
                return error.InvalidArgs;
            };
            try chainsync_mux_smoke.run(alloc, host, port_u);
            return;
        } else if (std.mem.eql(u8, cmd, "replay")) {
            var lang: i18n.Lang = .en;
            var debug = false;
            var file_path: ?[]const u8 = null;

            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--debug")) {
                    debug = true;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--file")) {
                    file_path = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--file")) |val| {
                    file_path = val;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--lang")) {
                    lang = i18n.parseLang(args_it.next());
                    continue;
                }
                if (parseFlagValue(arg, "--lang")) |val| {
                    lang = i18n.parseLang(val);
                    continue;
                }
                return error.InvalidArgs;
            }

            const p = file_path orelse return error.InvalidArgs;
            try replay.run(alloc, p, lang, debug);
            return;
        } else if (std.mem.eql(u8, cmd, "replay-run")) {
            var rr_file: ?[]const u8 = null;
            var rr_lmdb: ?[]const u8 = null;
            var rr_max_blocks: usize = 0;
            var rr_from_offset: u64 = 0;
            var rr_strict = false;
            var rr_debug = false;
            var rr_report_dir: ?[]const u8 = null;
            var rr_report_prefix: ?[]const u8 = null;
            var rr_repeat: usize = 3;
            var rr_fresh = false;
            var rr_perf = false;
            var rr_quiet = false;
            var rr_baseline_json: ?[]const u8 = null;
            var rr_regress_threshold: u64 = 15;
            var rr_trend = false;

            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--strict")) {
                    rr_strict = true;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--debug")) {
                    rr_debug = true;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--fresh")) {
                    rr_fresh = true;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--perf")) {
                    rr_perf = true;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--quiet")) {
                    rr_quiet = true;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--file")) {
                    rr_file = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--file")) |val| {
                    rr_file = val;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--lmdb")) {
                    rr_lmdb = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--lmdb")) |val| {
                    rr_lmdb = val;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--max-blocks")) {
                    const v = args_it.next() orelse return error.InvalidArgs;
                    rr_max_blocks = std.fmt.parseUnsigned(usize, v, 10) catch return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--max-blocks")) |val| {
                    rr_max_blocks = std.fmt.parseUnsigned(usize, val, 10) catch return error.InvalidArgs;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--from-offset")) {
                    const v = args_it.next() orelse return error.InvalidArgs;
                    rr_from_offset = std.fmt.parseUnsigned(u64, v, 10) catch return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--from-offset")) |val| {
                    rr_from_offset = std.fmt.parseUnsigned(u64, val, 10) catch return error.InvalidArgs;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--report-dir")) {
                    rr_report_dir = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--report-dir")) |val| {
                    rr_report_dir = val;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--report-prefix")) {
                    rr_report_prefix = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--report-prefix")) |val| {
                    rr_report_prefix = val;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--repeat")) {
                    const v = args_it.next() orelse return error.InvalidArgs;
                    rr_repeat = std.fmt.parseUnsigned(usize, v, 10) catch return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--repeat")) |val| {
                    rr_repeat = std.fmt.parseUnsigned(usize, val, 10) catch return error.InvalidArgs;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--trend")) {
                    rr_trend = true;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--baseline-json")) {
                    rr_baseline_json = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--baseline-json")) |val| {
                    rr_baseline_json = val;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--regress-threshold")) {
                    const v = args_it.next() orelse return error.InvalidArgs;
                    rr_regress_threshold = std.fmt.parseUnsigned(u64, v, 10) catch return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--regress-threshold")) |val| {
                    rr_regress_threshold = std.fmt.parseUnsigned(u64, val, 10) catch return error.InvalidArgs;
                    continue;
                }
                std.debug.print("unknown arg: {s}\n", .{arg});
                return error.InvalidArgs;
            }

            const rr_f = rr_file orelse {
                std.debug.print("missing --file\n", .{});
                return error.InvalidArgs;
            };
            const rr_l = rr_lmdb orelse {
                std.debug.print("missing --lmdb\n", .{});
                return error.InvalidArgs;
            };

            const exit_code = replay_run_cmd.run(alloc, rr_f, rr_l, rr_max_blocks, rr_from_offset, rr_strict, rr_debug, rr_report_dir, rr_report_prefix, rr_repeat, rr_fresh, rr_perf, rr_quiet, rr_baseline_json, rr_regress_threshold, rr_trend);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "lmdb-seed")) {
            var snapshot_path: ?[]const u8 = null;
            var lmdb_dir: ?[]const u8 = null;
            var limit: ?usize = null;

            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--snapshot")) {
                    snapshot_path = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--snapshot")) |val| {
                    snapshot_path = val;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--lmdb")) {
                    lmdb_dir = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--lmdb")) |val2| {
                    lmdb_dir = val2;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--limit")) {
                    const s = args_it.next() orelse return error.InvalidArgs;
                    limit = std.fmt.parseInt(usize, s, 10) catch return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--limit")) |val3| {
                    limit = std.fmt.parseInt(usize, val3, 10) catch return error.InvalidArgs;
                    continue;
                }
                std.debug.print("unknown arg: {s}\n", .{arg});
                return error.InvalidArgs;
            }

            const snap = snapshot_path orelse {
                std.debug.print("missing --snapshot\n", .{});
                return error.InvalidArgs;
            };

            try lmdb_seed.run(alloc, snap, lmdb_dir, limit);
            return;
        } else if (std.mem.eql(u8, cmd, "lmdb-backfill")) {
            var file_path: ?[]const u8 = null;
            var lmdb_dir2: ?[]const u8 = null;
            var max_blocks: ?usize = null;
            var strict = false;

            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--strict")) {
                    strict = true;
                    continue;
                }

                if (std.mem.eql(u8, arg, "--file")) {
                    file_path = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--file")) |v| {
                    file_path = v;
                    continue;
                }

                if (std.mem.eql(u8, arg, "--lmdb")) {
                    lmdb_dir2 = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--lmdb")) |v2| {
                    lmdb_dir2 = v2;
                    continue;
                }

                if (std.mem.eql(u8, arg, "--max")) {
                    const s = args_it.next() orelse return error.InvalidArgs;
                    max_blocks = std.fmt.parseInt(usize, s, 10) catch return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--max")) |v3| {
                    max_blocks = std.fmt.parseInt(usize, v3, 10) catch return error.InvalidArgs;
                    continue;
                }

                std.debug.print("unknown arg: {s}\n", .{arg});
                return error.InvalidArgs;
            }

            const p = file_path orelse {
                std.debug.print("missing --file\n", .{});
                return error.InvalidArgs;
            };

            try lmdb_backfill.run(alloc, p, lmdb_dir2, max_blocks, strict);
            return;
        } else if (std.mem.eql(u8, cmd, "lmdb-backfill-dir")) {
            var dir_path: ?[]const u8 = null;
            var lmdb_dir3: ?[]const u8 = null;
            var max_per_file: ?usize = null;
            var strict2 = false;
            var bf_dir_net: ?[]const u8 = null;

            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--strict")) {
                    strict2 = true;
                    continue;
                }

                if (std.mem.eql(u8, arg, "--dir")) {
                    dir_path = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--dir")) |v| {
                    dir_path = v;
                    continue;
                }

                if (std.mem.eql(u8, arg, "--lmdb")) {
                    lmdb_dir3 = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--lmdb")) |v2| {
                    lmdb_dir3 = v2;
                    continue;
                }

                if (std.mem.eql(u8, arg, "--max-per-file")) {
                    const s = args_it.next() orelse return error.InvalidArgs;
                    max_per_file = std.fmt.parseInt(usize, s, 10) catch return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--max-per-file")) |v3| {
                    max_per_file = std.fmt.parseInt(usize, v3, 10) catch return error.InvalidArgs;
                    continue;
                }

                if (std.mem.eql(u8, arg, "--net")) {
                    bf_dir_net = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--net")) |v4| {
                    bf_dir_net = v4;
                    continue;
                }

                std.debug.print("unknown arg: {s}\n", .{arg});
                return error.InvalidArgs;
            }

            const d = dir_path orelse {
                std.debug.print("missing --dir\n", .{});
                return error.InvalidArgs;
            };

            try lmdb_backfill_dir.run(alloc, d, lmdb_dir3, max_per_file, strict2, bf_dir_net);
            return;
        } else if (std.mem.eql(u8, cmd, "lmdb-backfill-inc")) {
            var bf_dir: ?[]const u8 = null;
            var bf_lmdb: ?[]const u8 = null;
            var bf_max_blocks: ?usize = null;
            var bf_max_seconds: ?i64 = null;
            var bf_cursor: ?[]const u8 = null;
            var bf_strict = false;
            var bf_adaptive = false;
            var bf_metrics_url: []const u8 = "http://127.0.0.1:9080/metrics";
            var bf_reset_cursor = false;
            var bf_inc_net: ?[]const u8 = null;

            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--strict")) {
                    bf_strict = true;
                    continue;
                }

                if (std.mem.eql(u8, arg, "--dir")) {
                    bf_dir = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--dir")) |v| {
                    bf_dir = v;
                    continue;
                }

                if (std.mem.eql(u8, arg, "--lmdb")) {
                    bf_lmdb = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--lmdb")) |v| {
                    bf_lmdb = v;
                    continue;
                }

                if (std.mem.eql(u8, arg, "--max-blocks")) {
                    const s = args_it.next() orelse return error.InvalidArgs;
                    bf_max_blocks = std.fmt.parseInt(usize, s, 10) catch return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--max-blocks")) |v| {
                    bf_max_blocks = std.fmt.parseInt(usize, v, 10) catch return error.InvalidArgs;
                    continue;
                }

                if (std.mem.eql(u8, arg, "--max-seconds")) {
                    const s = args_it.next() orelse return error.InvalidArgs;
                    bf_max_seconds = std.fmt.parseInt(i64, s, 10) catch return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--max-seconds")) |v| {
                    bf_max_seconds = std.fmt.parseInt(i64, v, 10) catch return error.InvalidArgs;
                    continue;
                }

                if (std.mem.eql(u8, arg, "--cursor")) {
                    bf_cursor = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--cursor")) |v| {
                    bf_cursor = v;
                    continue;
                }

                if (std.mem.eql(u8, arg, "--adaptive")) {
                    bf_adaptive = true;
                    continue;
                }

                if (std.mem.eql(u8, arg, "--reset-cursor")) {
                    bf_reset_cursor = true;
                    continue;
                }

                if (std.mem.eql(u8, arg, "--metrics-url")) {
                    bf_metrics_url = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--metrics-url")) |v| {
                    bf_metrics_url = v;
                    continue;
                }

                if (std.mem.eql(u8, arg, "--net")) {
                    bf_inc_net = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--net")) |v| {
                    bf_inc_net = v;
                    continue;
                }

                std.debug.print("unknown arg: {s}\n", .{arg});
                return error.InvalidArgs;
            }

            const bf_d = bf_dir orelse {
                std.debug.print("missing --dir\n", .{});
                return error.InvalidArgs;
            };

            try lmdb_backfill_autopilot.run(alloc, bf_d, bf_lmdb, bf_max_blocks, bf_max_seconds, bf_cursor, bf_strict, bf_adaptive, bf_metrics_url, bf_reset_cursor, bf_inc_net);
            return;
        } else if (std.mem.eql(u8, cmd, "capture-retention")) {
            var cr_dir: ?[]const u8 = null;
            var cr_max: u64 = 10 * 1024 * 1024 * 1024;

            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--dir")) {
                    cr_dir = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--dir")) |v| {
                    cr_dir = v;
                    continue;
                }

                if (std.mem.eql(u8, arg, "--max-bytes")) {
                    const s = args_it.next() orelse return error.InvalidArgs;
                    cr_max = std.fmt.parseInt(u64, s, 10) catch return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--max-bytes")) |v2| {
                    cr_max = std.fmt.parseInt(u64, v2, 10) catch return error.InvalidArgs;
                    continue;
                }

                std.debug.print("unknown arg: {s}\n", .{arg});
                return error.InvalidArgs;
            }

            const cr_d = cr_dir orelse {
                std.debug.print("missing --dir\n", .{});
                return error.InvalidArgs;
            };

            try capture_retention_cmd.run(alloc, cr_d, cr_max);
            return;
        } else if (std.mem.eql(u8, cmd, "autoswitch-apply")) {
            try autoswitch_cmd.run(alloc);
            return;
        } else if (std.mem.eql(u8, cmd, "snapshot-export")) {
            var out_path: ?[]const u8 = null;
            var snap_lmdb: ?[]const u8 = null;
            var signing_key: ?[]const u8 = null;

            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--out")) {
                    out_path = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--out")) |v| {
                    out_path = v;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--lmdb")) {
                    snap_lmdb = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--lmdb")) |v2| {
                    snap_lmdb = v2;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--signing-key")) {
                    signing_key = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--signing-key")) |v3| {
                    signing_key = v3;
                    continue;
                }
                std.debug.print("unknown arg: {s}\n", .{arg});
                return error.InvalidArgs;
            }

            const op = out_path orelse {
                std.debug.print("missing --out\n", .{});
                return error.InvalidArgs;
            };

            try snapshot_cmd.exportSnapshot(alloc, op, snap_lmdb, signing_key);
            return;
        } else if (std.mem.eql(u8, cmd, "snapshot-import")) {
            var imp_file: ?[]const u8 = null;
            var imp_lmdb: ?[]const u8 = null;
            var verify_digest: ?[]const u8 = null;
            var imp_strict = false;
            var imp_pubkey: ?[]const u8 = null;
            var imp_pubkey_file: ?[]const u8 = null;
            var imp_allow_unsigned = false;

            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--strict")) {
                    imp_strict = true;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--allow-unsigned")) {
                    imp_allow_unsigned = true;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--file")) {
                    imp_file = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--file")) |v| {
                    imp_file = v;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--lmdb")) {
                    imp_lmdb = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--lmdb")) |v2| {
                    imp_lmdb = v2;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--verify-digest")) {
                    verify_digest = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--verify-digest")) |v3| {
                    verify_digest = v3;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--pubkey")) {
                    imp_pubkey = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--pubkey")) |v4| {
                    imp_pubkey = v4;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--pubkey-file")) {
                    imp_pubkey_file = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--pubkey-file")) |v5| {
                    imp_pubkey_file = v5;
                    continue;
                }
                std.debug.print("unknown arg: {s}\n", .{arg});
                return error.InvalidArgs;
            }

            const ip = imp_file orelse {
                std.debug.print("missing --file\n", .{});
                return error.InvalidArgs;
            };

            try snapshot_cmd.importSnapshot(alloc, ip, imp_lmdb, verify_digest, imp_strict, imp_pubkey, imp_pubkey_file, imp_allow_unsigned);
            return;
        } else if (std.mem.eql(u8, cmd, "snapshot-keygen")) {
            try snapshot_sign.keygen(alloc);
            return;
        } else if (std.mem.eql(u8, cmd, "snapshot-sign")) {
            var sign_file: ?[]const u8 = null;
            var sign_key: ?[]const u8 = null;

            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--file")) {
                    sign_file = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--file")) |v| {
                    sign_file = v;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--key")) {
                    sign_key = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--key")) |v2| {
                    sign_key = v2;
                    continue;
                }
                std.debug.print("unknown arg: {s}\n", .{arg});
                return error.InvalidArgs;
            }

            const sf = sign_file orelse {
                std.debug.print("missing --file\n", .{});
                return error.InvalidArgs;
            };

            try snapshot_sign.signFile(alloc, sf, sign_key);
            return;
        } else if (std.mem.eql(u8, cmd, "snapshot-verify")) {
            var verify_file: ?[]const u8 = null;
            var verify_sig: ?[]const u8 = null;
            var verify_pubkey: ?[]const u8 = null;
            var verify_pubkey_file: ?[]const u8 = null;

            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--file")) {
                    verify_file = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--file")) |v| {
                    verify_file = v;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--sig")) {
                    verify_sig = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--sig")) |v2| {
                    verify_sig = v2;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--pubkey")) {
                    verify_pubkey = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--pubkey")) |v3| {
                    verify_pubkey = v3;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--pubkey-file")) {
                    verify_pubkey_file = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--pubkey-file")) |v4| {
                    verify_pubkey_file = v4;
                    continue;
                }
                std.debug.print("unknown arg: {s}\n", .{arg});
                return error.InvalidArgs;
            }

            const vf = verify_file orelse {
                std.debug.print("missing --file\n", .{});
                return error.InvalidArgs;
            };

            const sig_valid = try snapshot_sign.verifyFile(alloc, vf, verify_sig, verify_pubkey, verify_pubkey_file);
            if (!sig_valid) std.process.exit(2);
            return;
        } else if (std.mem.eql(u8, cmd, "trust-snapshot")) {
            try trust_snapshot_cmd.runSnapshot(alloc, &args_it);
            return;
        } else if (std.mem.eql(u8, cmd, "trust-verify")) {
            try trust_snapshot_cmd.runVerify(alloc, &args_it);
            return;
        } else if (std.mem.eql(u8, cmd, "trust-reputation")) {
            try trust_snapshot_cmd.runReputation(alloc, &args_it);
            return;
        } else if (std.mem.eql(u8, cmd, "trust-exchange")) {
            try trust_snapshot_cmd.runExchange(alloc, &args_it);
            return;
        } else if (std.mem.eql(u8, cmd, "trust-federate")) {
            try trust_snapshot_cmd.runFederate(alloc, &args_it);
            return;
        } else if (std.mem.eql(u8, cmd, "trust-graph")) {
            try trust_snapshot_cmd.runGraph(alloc, &args_it);
            return;
        } else if (std.mem.eql(u8, cmd, "trust-propagate")) {
            try trust_snapshot_cmd.runPropagate(alloc, &args_it);
            return;
        } else if (std.mem.eql(u8, cmd, "bootstrap")) {
            var boot_file: ?[]const u8 = null;
            var boot_lmdb: ?[]const u8 = null;

            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--file")) {
                    boot_file = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--file")) |v| {
                    boot_file = v;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--lmdb")) {
                    boot_lmdb = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--lmdb")) |v2| {
                    boot_lmdb = v2;
                    continue;
                }
                std.debug.print("unknown arg: {s}\n", .{arg});
                return error.InvalidArgs;
            }

            const bf = boot_file orelse {
                std.debug.print("missing --file\n", .{});
                return error.InvalidArgs;
            };

            try bootstrap_cmd.run(alloc, bf, boot_lmdb);
            return;
        } else if (std.mem.eql(u8, cmd, "lmdb-digest")) {
            var digest_lmdb: ?[]const u8 = null;

            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--lmdb")) {
                    digest_lmdb = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--lmdb")) |v| {
                    digest_lmdb = v;
                    continue;
                }
                std.debug.print("unknown arg: {s}\n", .{arg});
                return error.InvalidArgs;
            }

            const exit_code = lmdb_digest_cmd.run(alloc, digest_lmdb);
            if (exit_code != 0) std.process.exit(exit_code);
            return;
        } else if (std.mem.eql(u8, cmd, "tsf-artifact")) {
            var art_lmdb: ?[]const u8 = null;
            var art_out: ?[]const u8 = null;
            var art_test: ?[]const u8 = null;
            var art_gzip = false;
            var art_strict = false;
            var art_signing_key: ?[]const u8 = null;

            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--gzip")) {
                    art_gzip = true;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--strict")) {
                    art_strict = true;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--lmdb")) {
                    art_lmdb = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--lmdb")) |v| {
                    art_lmdb = v;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--out")) {
                    art_out = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--out")) |v2| {
                    art_out = v2;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--test-dir")) {
                    art_test = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--test-dir")) |v3| {
                    art_test = v3;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--signing-key")) {
                    art_signing_key = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--signing-key")) |v4| {
                    art_signing_key = v4;
                    continue;
                }
                std.debug.print("unknown arg: {s}\n", .{arg});
                return error.InvalidArgs;
            }

            const a_lmdb = art_lmdb orelse {
                std.debug.print("missing --lmdb\n", .{});
                return error.InvalidArgs;
            };
            const a_out = art_out orelse {
                std.debug.print("missing --out\n", .{});
                return error.InvalidArgs;
            };
            const a_test = art_test orelse {
                std.debug.print("missing --test-dir\n", .{});
                return error.InvalidArgs;
            };

            try tsf_artifact_cmd.run(alloc, a_lmdb, a_out, a_test, art_gzip, art_strict, art_signing_key);
            return;
        } else if (std.mem.eql(u8, cmd, "setup")) {
            var setup_role: ?setup_cmd.Role = null;
            var setup_autoswitch = false;
            var setup_install: ?[]const u8 = null;
            var setup_lang: i18n.Lang = .en;

            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--autoswitch")) {
                    setup_autoswitch = true;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--install")) {
                    setup_install = args_it.next() orelse {
                        std.debug.print("missing value for --install (latest or vX.Y.Z)\n", .{});
                        return error.InvalidArgs;
                    };
                    continue;
                }
                if (std.mem.eql(u8, arg, "--role")) {
                    const rv = args_it.next() orelse {
                        std.debug.print("missing value for --role\n", .{});
                        return error.InvalidArgs;
                    };
                    if (std.mem.eql(u8, rv, "relay")) {
                        setup_role = .relay;
                    } else if (std.mem.eql(u8, rv, "tools")) {
                        setup_role = .tools;
                    } else if (std.mem.eql(u8, rv, "bp")) {
                        setup_role = .bp;
                    } else {
                        std.debug.print("unknown role: {s} (use relay, tools, or bp)\n", .{rv});
                        return error.InvalidArgs;
                    }
                    continue;
                }
                if (std.mem.eql(u8, arg, "--lang")) {
                    setup_lang = i18n.parseLang(args_it.next());
                    continue;
                }
                std.debug.print("unknown arg: {s}\n", .{arg});
                return error.InvalidArgs;
            }

            const sr = setup_role orelse {
                std.debug.print("missing --role (relay, tools, or bp)\n", .{});
                return error.InvalidArgs;
            };

            try setup_cmd.run(alloc, sr, setup_autoswitch, setup_install, setup_lang);
            return;
        } else if (std.mem.eql(u8, cmd, "guardian")) {
            const exit_code = guardian_cmd.run(alloc, &args_it);
            if (exit_code != 0) std.process.exit(exit_code);
            return;
        } else if (std.mem.eql(u8, cmd, "kagami")) {
            const exit_code = kagami_cmd.run(alloc, &args_it);
            if (exit_code != 0) std.process.exit(exit_code);
            return;
        } else if (std.mem.eql(u8, cmd, "forge-sim")) {
            const exit_code = forge_sim_cmd.run(alloc, &args_it);
            if (exit_code != 0) std.process.exit(exit_code);
            return;
        } else if (std.mem.eql(u8, cmd, "ledger-harness")) {
            const exit_code = ledger_harness_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "submit-tx")) {
            var tx_file: ?[]const u8 = null;
            var tx_hex: ?[]const u8 = null;
            var offline = false;

            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--offline")) {
                    offline = true;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--file")) {
                    tx_file = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--file")) |v| {
                    tx_file = v;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--hex")) {
                    tx_hex = args_it.next() orelse return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--hex")) |v| {
                    tx_hex = v;
                    continue;
                }
                std.debug.print("unknown arg: {s}\n", .{arg});
                return error.InvalidArgs;
            }

            // Read tx bytes from file or hex
            var tx_bytes: []u8 = undefined;
            var tx_bytes_owned = false;
            var is_hex_input = false;

            if (tx_file) |path| {
                var file = compat.fs.cwd().openFile(path, .{}) catch |err| {
                    std.debug.print("cannot open file: {s} ({s})\n", .{ path, @errorName(err) });
                    return error.InvalidArgs;
                };
                defer file.close();
                tx_bytes = file.deprecatedReader().readAllAlloc(alloc, mempool_mod.MAX_TX_SIZE + 1) catch |err| {
                    std.debug.print("cannot read file: {s} ({s})\n", .{ path, @errorName(err) });
                    return error.InvalidArgs;
                };
                tx_bytes_owned = true;
            } else if (tx_hex) |hex| {
                // For online mode, we send hex directly; for offline, decode it
                if (offline) {
                    tx_bytes = mempool_mod.decodeHex(alloc, hex) orelse {
                        std.debug.print("invalid hex input\n", .{});
                        return error.InvalidArgs;
                    };
                    tx_bytes_owned = true;
                } else {
                    // Keep as hex string for POST body
                    tx_bytes = @constCast(hex);
                    is_hex_input = true;
                }
            } else {
                std.debug.print("missing --file or --hex\n", .{});
                return error.InvalidArgs;
            }
            defer if (tx_bytes_owned) alloc.free(tx_bytes);

            if (offline) {
                // Local validation only
                var mp = mempool_mod.Mempool.init(alloc, mempool_mod.DEFAULT_MAX_ITEMS, mempool_mod.DEFAULT_MAX_BYTES);
                defer mp.deinit();

                const result = mp.addTx(tx_bytes);
                switch (result) {
                    .accepted => {
                        const item = mp.items.items[0];
                        const hex_out = mempool_mod.Mempool.fmtHash(&item.hash);
                        std.debug.print("TX accepted (offline): hash={s} size={d} bytes\n", .{ hex_out, tx_bytes.len });
                    },
                    .rejected_too_large => std.debug.print("TX rejected: too large ({d} bytes, max {d})\n", .{ tx_bytes.len, mempool_mod.MAX_TX_SIZE }),
                    .rejected_cbor_invalid => std.debug.print("TX rejected: invalid CBOR (not a top-level array)\n", .{}),
                    .rejected_duplicate => std.debug.print("TX rejected: duplicate\n", .{}),
                    .rejected_input_conflict => std.debug.print("TX rejected: input conflict with existing mempool tx\n", .{}),
                    .rejected_missing_input => std.debug.print("TX rejected: input UTxO not found in ledger\n", .{}),
                    .rejected_balance_insufficient => std.debug.print("TX rejected: insufficient input balance\n", .{}),
                    .rejected_ttl_expired => std.debug.print("TX rejected: expired validity interval\n", .{}),
                    .rejected_validity_start_future => std.debug.print("TX rejected: validity start is in the future\n", .{}),
                    .rejected_fee_insufficient => std.debug.print("TX rejected: fee below minimum required by protocol\n", .{}),
                    .rejected_min_utxo => std.debug.print("TX rejected: output below minimum UTxO value\n", .{}),
                    .rejected_timelock => std.debug.print("TX rejected: native timelock bounds violated\n", .{}),
                    .rejected_witness_invalid => std.debug.print("TX rejected: vkey witness signature verification failed\n", .{}),
                    .rejected_witness_coverage => std.debug.print("TX rejected: key-controlled input missing matching vkey witness\n", .{}),
                    .rejected_plutus_unsupported => std.debug.print("TX rejected: requires Plutus execution (not supported)\n", .{}),
                    .rejected_plutus_eval_failed => std.debug.print("TX rejected: Plutus evaluation failed\n", .{}),
                    .accepted_plutus_evaluated => {
                        const item = mp.items.items[0];
                        const hex_out = mempool_mod.Mempool.fmtHash(&item.hash);
                        std.debug.print("TX accepted (Plutus evaluated): hash={s} size={d} bytes\n", .{ hex_out, tx_bytes.len });
                    },
                }
                return;
            }

            // Online mode: POST to running node
            const submit_port: u16 = 9080;
            var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", submit_port) catch {
                std.debug.print("cannot parse submit address\n", .{});
                return error.InvalidArgs;
            };
            const stream = addr.connect(compat.defaultIo(), .{ .mode = .stream }) catch {
                std.debug.print("cannot connect to node at 127.0.0.1:{d} — is the node running?\n", .{submit_port});
                return error.InvalidArgs;
            };
            defer stream.close(compat.defaultIo());

            // Build POST body: if file input, encode as hex for text/plain
            var body: []const u8 = undefined;
            var body_owned = false;
            var content_type: []const u8 = undefined;
            if (is_hex_input) {
                body = tx_bytes;
                content_type = "text/plain";
            } else {
                // Binary file — send as hex
                const hex_buf = alloc.alloc(u8, tx_bytes.len * 2) catch {
                    std.debug.print("alloc failed\n", .{});
                    return error.InvalidArgs;
                };
                const hex_chars = "0123456789abcdef";
                for (tx_bytes, 0..) |byte, i| {
                    hex_buf[i * 2] = hex_chars[byte >> 4];
                    hex_buf[i * 2 + 1] = hex_chars[byte & 0x0f];
                }
                body = hex_buf;
                body_owned = true;
                content_type = "text/plain";
            }
            defer if (body_owned) alloc.free(@constCast(body));

            // Send HTTP request
            const sw = compat.streamWriter(stream);
            sw.print("POST /tx/submit HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ submit_port, content_type, body.len }) catch {
                std.debug.print("failed to send request\n", .{});
                return error.InvalidArgs;
            };
            sw.writeAll(body) catch {
                std.debug.print("failed to send body\n", .{});
                return error.InvalidArgs;
            };

            // Read response
            var resp_buf: [4096]u8 = undefined;
            var rdr_buf: [4096]u8 = undefined;
            var sr = compat.NetStream.Reader.init(stream, compat.defaultIo(), &rdr_buf);
            var total_read: usize = 0;
            while (total_read < resp_buf.len) {
                const n = sr.interface.readSliceShort(resp_buf[total_read..]) catch break;
                if (n == 0) break;
                total_read += n;
            }
            const resp = resp_buf[0..total_read];

            // Find body after \r\n\r\n
            if (std.mem.indexOf(u8, resp, "\r\n\r\n")) |hdr_end| {
                const resp_body = resp[hdr_end + 4 ..];
                std.debug.print("{s}\n", .{resp_body});
            } else {
                std.debug.print("unexpected response from node\n", .{});
            }
            return;
        } else if (std.mem.eql(u8, cmd, "mempool")) {
            const mp_port: u16 = 9080;
            var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", mp_port) catch {
                std.debug.print("cannot parse address\n", .{});
                return error.InvalidArgs;
            };
            const stream = addr.connect(compat.defaultIo(), .{ .mode = .stream }) catch {
                std.debug.print("cannot connect to node at 127.0.0.1:{d} — is the node running?\n", .{mp_port});
                return error.InvalidArgs;
            };
            defer stream.close(compat.defaultIo());

            const sw = compat.streamWriter(stream);
            sw.print("GET /mempool HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{mp_port}) catch {
                std.debug.print("failed to send request\n", .{});
                return error.InvalidArgs;
            };

            var resp_buf: [4096]u8 = undefined;
            var rdr_buf: [4096]u8 = undefined;
            var sr = compat.NetStream.Reader.init(stream, compat.defaultIo(), &rdr_buf);
            var total_read: usize = 0;
            while (total_read < resp_buf.len) {
                const n = sr.interface.readSliceShort(resp_buf[total_read..]) catch break;
                if (n == 0) break;
                total_read += n;
            }
            const resp = resp_buf[0..total_read];

            if (std.mem.indexOf(u8, resp, "\r\n\r\n")) |hdr_end| {
                const resp_body = resp[hdr_end + 4 ..];
                std.debug.print("{s}\n", .{resp_body});
            } else {
                std.debug.print("unexpected response from node\n", .{});
            }
            return;
        } else if (std.mem.eql(u8, cmd, "console")) {
            var console_lang: i18n.Lang = .en;
            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--lang")) {
                    console_lang = i18n.parseLang(args_it.next());
                    continue;
                }
                if (parseFlagValue(arg, "--lang")) |val| {
                    console_lang = i18n.parseLang(val);
                    continue;
                }
                std.debug.print("unknown flag: {s}\n", .{arg});
                return error.InvalidArgs;
            }
            console_cmd.run(alloc, console_lang);
            return;
        } else if (std.mem.eql(u8, cmd, "baey-loop")) {
            var bl_apply = false;
            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--dry-run")) {
                    // dry-run is the default when --apply is not set
                    continue;
                }
                if (std.mem.eql(u8, arg, "--apply")) {
                    bl_apply = true;
                    continue;
                }
                std.debug.print("unknown flag: {s}\n", .{arg});
                return error.InvalidArgs;
            }
            baey_loop_cmd.run(alloc, bl_apply);
            return;
        } else if (std.mem.eql(u8, cmd, "replay-baseline")) {
            var rb_file: ?[]const u8 = null;
            var rb_out_dir: ?[]const u8 = null;
            var rb_max_blocks: usize = 200;
            var rb_repeat: usize = 3;
            var rb_force = false;

            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--force")) { rb_force = true; continue; }
                if (std.mem.eql(u8, arg, "--file")) { rb_file = args_it.next() orelse return error.InvalidArgs; continue; }
                if (parseFlagValue(arg, "--file")) |val| { rb_file = val; continue; }
                if (std.mem.eql(u8, arg, "--out-dir")) { rb_out_dir = args_it.next() orelse return error.InvalidArgs; continue; }
                if (parseFlagValue(arg, "--out-dir")) |val| { rb_out_dir = val; continue; }
                if (std.mem.eql(u8, arg, "--max-blocks")) {
                    const v = args_it.next() orelse return error.InvalidArgs;
                    rb_max_blocks = std.fmt.parseUnsigned(usize, v, 10) catch return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--max-blocks")) |val| {
                    rb_max_blocks = std.fmt.parseUnsigned(usize, val, 10) catch return error.InvalidArgs;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--repeat")) {
                    const v = args_it.next() orelse return error.InvalidArgs;
                    rb_repeat = std.fmt.parseUnsigned(usize, v, 10) catch return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--repeat")) |val| {
                    rb_repeat = std.fmt.parseUnsigned(usize, val, 10) catch return error.InvalidArgs;
                    continue;
                }
                std.debug.print("unknown arg: {s}\n", .{arg});
                return error.InvalidArgs;
            }

            const rb_f = rb_file orelse { std.debug.print("missing --file\n", .{}); return error.InvalidArgs; };
            const rb_d = rb_out_dir orelse { std.debug.print("missing --out-dir\n", .{}); return error.InvalidArgs; };
            const exit_code = replay_baseline_cmd.run(alloc, rb_f, rb_d, rb_max_blocks, rb_repeat, rb_force);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "replay-regress")) {
            var rg_file: ?[]const u8 = null;
            var rg_out_dir: ?[]const u8 = null;
            var rg_baseline_json: ?[]const u8 = null;
            var rg_max_blocks: usize = 200;
            var rg_repeat: usize = 3;
            var rg_regress_threshold: u64 = 15;
            var rg_trend = true;

            while (args_it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--trend")) { rg_trend = true; continue; }
                if (std.mem.eql(u8, arg, "--file")) { rg_file = args_it.next() orelse return error.InvalidArgs; continue; }
                if (parseFlagValue(arg, "--file")) |val| { rg_file = val; continue; }
                if (std.mem.eql(u8, arg, "--out-dir")) { rg_out_dir = args_it.next() orelse return error.InvalidArgs; continue; }
                if (parseFlagValue(arg, "--out-dir")) |val| { rg_out_dir = val; continue; }
                if (std.mem.eql(u8, arg, "--baseline-json")) { rg_baseline_json = args_it.next() orelse return error.InvalidArgs; continue; }
                if (parseFlagValue(arg, "--baseline-json")) |val| { rg_baseline_json = val; continue; }
                if (std.mem.eql(u8, arg, "--max-blocks")) {
                    const v = args_it.next() orelse return error.InvalidArgs;
                    rg_max_blocks = std.fmt.parseUnsigned(usize, v, 10) catch return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--max-blocks")) |val| {
                    rg_max_blocks = std.fmt.parseUnsigned(usize, val, 10) catch return error.InvalidArgs;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--repeat")) {
                    const v = args_it.next() orelse return error.InvalidArgs;
                    rg_repeat = std.fmt.parseUnsigned(usize, v, 10) catch return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--repeat")) |val| {
                    rg_repeat = std.fmt.parseUnsigned(usize, val, 10) catch return error.InvalidArgs;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--regress-threshold")) {
                    const v = args_it.next() orelse return error.InvalidArgs;
                    rg_regress_threshold = std.fmt.parseUnsigned(u64, v, 10) catch return error.InvalidArgs;
                    continue;
                }
                if (parseFlagValue(arg, "--regress-threshold")) |val| {
                    rg_regress_threshold = std.fmt.parseUnsigned(u64, val, 10) catch return error.InvalidArgs;
                    continue;
                }
                std.debug.print("unknown arg: {s}\n", .{arg});
                return error.InvalidArgs;
            }

            const rg_f = rg_file orelse { std.debug.print("missing --file\n", .{}); return error.InvalidArgs; };
            const rg_d = rg_out_dir orelse { std.debug.print("missing --out-dir\n", .{}); return error.InvalidArgs; };
            const rg_b = rg_baseline_json orelse blk: {
                break :blk std.fmt.allocPrint(alloc, "{s}/baseline/report.json", .{rg_d}) catch {
                    std.debug.print("missing --baseline-json\n", .{});
                    return error.InvalidArgs;
                };
            };
            const exit_code = replay_regress_cmd.run(alloc, rg_f, rg_d, rg_b, rg_max_blocks, rg_repeat, rg_regress_threshold, rg_trend);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "vrf-selftest")) {
            const exit_code = vrf_selftest_cmd.run(alloc);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "bodyhash-selftest")) {
            const exit_code = bodyhash_selftest_cmd.run(alloc);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "pack-verify")) {
            const exit_code = pack_verify_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "pack-now")) {
            const exit_code = pack_now_cmd.run(alloc);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "praos-selftest")) {
            const exit_code = praos_selftest_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "schedule-regress")) {
            const exit_code = schedule_regress_cmd.run(alloc);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "kes-selftest")) {
            const exit_code = kes_selftest_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "praos-regress")) {
            const exit_code = praos_regress_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "producer-regress")) {
            const exit_code = producer_regress_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "baey-regress")) {
            const exit_code = baey_regress_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "praos-align")) {
            const exit_code = praos_align_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "praos-exact-align")) {
            const exit_code = praos_exact_align_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "vrf-align")) {
            const exit_code = vrf_align_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "header-align")) {
            const exit_code = header_align_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "candidate-verify")) {
            const exit_code = candidate_verify_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "candidate-validate")) {
            const exit_code = candidate_validate_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "kes-inspect")) {
            const exit_code = kes_inspect_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "kes-verify")) {
            const exit_code = kes_verify_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "kes-align")) {
            const exit_code = kes_align_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "kes-sign-test")) {
            const exit_code = kes_sign_test_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "kes-evolve")) {
            const exit_code = kes_evolve_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "praos-threshold-regress")) {
            const exit_code = praos_threshold_regress_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "header-body-align")) {
            const exit_code = header_body_align_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "block-candidate-verify")) {
            const exit_code = block_candidate_verify_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "block-candidate-regress")) {
            const exit_code = block_candidate_regress_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "readiness-sim")) {
            const exit_code = readiness_sim_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "producer-ready")) {
            const exit_code = producer_ready_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "producer-bridge")) {
            const exit_code = producer_bridge_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "consensus-align")) {
            const exit_code = consensus_align_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "build-info")) {
            const exit_code = build_info_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "repro-report")) {
            const exit_code = repro_report_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "evidence-pack")) {
            const exit_code = evidence_pack_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "cold-start")) {
            const exit_code = cold_start_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "snapshot-proof")) {
            const exit_code = snapshot_proof_cmd.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "propagate-serve")) {
            const exit_code = propagation_server.run(alloc, &args_it);
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, cmd, "footprint")) {
            footprint_cmd.run(alloc);
            return;
        } else {
            usage();
            return error.InvalidArgs;
        }
    }

    // Default: in-memory framed mux demo
    const bt = memory_bt.init(alloc, 256);
    var mux = Mux.init(alloc, bt);
    defer mux.deinit();

    var cs = ChainSync.attach(&mux);
    var bf = BlockFetch.attach(&mux);

    try cs.findIntersect();
    try cs.requestNext();
    try bf.requestRange();

    std.debug.print("TSUNAGI Node framed mux start (D.3.3)\n", .{});
    while (try mux.recv()) |msg| {
        printMsg(msg);
    }
    std.debug.print("TSUNAGI Node framed mux done (D.3.3)\n", .{});
}
