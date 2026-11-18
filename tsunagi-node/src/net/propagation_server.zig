const std = @import("std");
const compat = @import("compat");
const cbor = @import("cbor/term.zig");
const mux_bearer = @import("muxwire/mux_bearer.zig");
const mux_header = @import("muxwire/mux_header.zig");
const handshake_codec = @import("handshake/handshake_codec.zig");
const chainsync_server = @import("../protocols/chainsync_server.zig");
const blockfetch_server = @import("../protocols/blockfetch_server.zig");
const keepalive = @import("miniproto/keepalive.zig");
const fragment_coverage = @import("../archive/fragment_coverage.zig");
const node_state = @import("../node_state.zig");
const adaptive = @import("../producer/adaptive.zig");
const decision = @import("../producer/decision.zig");
const propagation_opt = @import("../producer/propagation_opt.zig");
const feedback = @import("../producer/feedback.zig");
const announce = @import("../producer/announce.zig");
const forge_stats = @import("../producer/forge_stats.zig");
const connection_registry = @import("connection_registry.zig");
const forge_notify = @import("forge_notify.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

/// PR-BCAST: TSUNAGI_MODE is the single authority for whether forged blocks
/// are emitted on the wire. Returns false (preview_safe — no broadcast) by
/// default; only `live` enables transmission.
fn isLiveMode() bool {
    const m = compat.getenv("TSUNAGI_MODE") orelse "preview_safe";
    return std.mem.eql(u8, m, "live");
}

// ── Propagation Server — preview relay-boundary harness (v4.5.7) ────
//
// Minimal N2N server: listens for a single operator-controlled relay,
// negotiates handshake, serves ChainSync headers and BlockFetch blocks
// from a sealed artifact directory.
//
// Safety gates: preview-only, allowlist, guardian arm token, no-inject.
// Exit codes: 0=success, 1=gate refused, 2=serve error, 3=missing files, 4=parse error.

const build_version = "v4.5.30-raw-copy-cleanup";

// Orphan-watchdog signal: bumped whenever a serve loop exits with
// served_header=true && served_block=false (the local cardano-node
// took our header but never followed up with BlockFetch — a strong
// signal our forge is on a fork the network rejected).
// Read by producer.checkOrphanWatchdog.
pub var g_serve_header_only_disconnects: std.atomic.Value(u64) =
    std.atomic.Value(u64).init(0);

const preview_magic: u64 = 2;
const handshake_proto: u16 = 0;
const keepalive_proto: u16 = 8;

// NodeToNode protocol version compatibility window.
// V14 is the canonical-stable baseline (proven in production 2026-05-14
// against cardano-node 11.0.1 via Propose offer {14,15} → Accept v14 →
// Cold→Warm→Hot promotion observed). V15 is layered on top: we now pick
// the HIGHEST version in [lowest_supported, highest_supported] that the
// peer offers with matching preview_magic. The 4-element VersionData
// shape [magic, diffusionMode_bool, peerSharing_u8, query_bool] is
// identical for both versions per the observed wire (cardano-node 11.0.1
// emits 4-element VersionData for v14 AND v15) — so encodeAccept stays
// version-agnostic. If a future peer offers only v14 we still accept;
// if it offers only v15 we accept too. Symmetric dual-stack.
const ntn_lowest_supported: u64 = 14;
const ntn_highest_supported: u64 = 15;

const HandshakeResult = enum { ok, probe, fail };

// ── Config ──────────────────────────────────────────────────────────

pub const Config = struct {
    net: []const u8,
    listen_port: u16,
    artifact_dir: []const u8,
    allowlist: []const u8,
    arm_token_path: ?[]const u8,
    receipts_dir: ?[]const u8,
};

/// Spawn propagation server as a detached background thread.
/// Returns true if successfully spawned.
pub fn spawnBackground(alloc: std.mem.Allocator, state_dir: []const u8, net_name: []const u8) bool {
    // Build config from env/state_dir
    const art_dir = std.fs.path.join(alloc, &[_][]const u8{ state_dir, "propagation_artifact" }) catch return false;
    const chain_tip = std.fs.path.join(alloc, &[_][]const u8{ state_dir, "chain_tip" }) catch return false;

    // Env override of legacy hardcoded port/allowlist (audit s5-t8 HIGH-1).
    // Defaults preserve prior loopback-only behavior.
    const allowlist: []const u8 = compat.getEnvVarOwned(alloc, "TSUNAGI_PROPAGATION_ALLOWLIST") catch "127.0.0.1";
    const port: u16 = blk: {
        const env_port = compat.getEnvVarOwned(alloc, "TSUNAGI_PROPAGATION_PORT") catch break :blk 3033;
        defer alloc.free(env_port);
        break :blk std.fmt.parseInt(u16, env_port, 10) catch 3033;
    };

    // Store config for thread (static lifetime — leaked intentionally, server runs forever)
    const cfg = alloc.create(ThreadConfig) catch return false;
    cfg.* = .{
        .art_dir = art_dir,
        .chain_tip_dir = chain_tip,
        .net = net_name,
        .port = port,
        .allowlist = allowlist,
    };

    const thread = std.Thread.spawn(.{}, propagationThread, .{ alloc, cfg }) catch {
        std.debug.print("PROPAGATION_AUTOSTART: thread spawn failed\n", .{});
        return false;
    };
    thread.detach();
    std.debug.print("PROPAGATION_AUTOSTART: spawned on port {d} artifact_dir={s}\n", .{ cfg.port, cfg.art_dir });
    return true;
}

const ThreadConfig = struct {
    art_dir: []const u8,
    chain_tip_dir: []const u8,
    net: []const u8,
    port: u16,
    allowlist: []const u8,
};

fn propagationThread(alloc: std.mem.Allocator, cfg: *const ThreadConfig) void {
    const exit = runDirect(alloc, cfg.net, cfg.port, cfg.art_dir, cfg.allowlist, cfg.chain_tip_dir);
    std.debug.print("PROPAGATION_AUTOSTART: exited code={d}\n", .{exit});
}

/// Direct entry point — takes explicit config, no CLI parsing.
pub fn runDirect(
    alloc: std.mem.Allocator,
    net_val: []const u8,
    listen_port: u16,
    art_dir: []const u8,
    allow_str: []const u8,
    chain_tip_dir_opt: ?[]const u8,
) u8 {
    std.debug.print("propagation: build={s}\n", .{build_version});
    if (chain_tip_dir_opt) |ctd| {
        std.debug.print("propagation: chain_tip_dir={s} (canonical fragment bridge enabled)\n", .{ctd});
    }

    if (!std.mem.eql(u8, net_val, "preview")) {
        std.debug.print("REFUSE: propagation harness is preview-only (got --net {s})\n", .{net_val});
        return 1;
    }

    return runServer(alloc, art_dir, allow_str, listen_port, chain_tip_dir_opt, null);
}

// ── pub fn run ──────────────────────────────────────────────────────

pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var net: ?[]const u8 = null;
    var listen_port: u16 = 3033;
    var artifact_dir: ?[]const u8 = null;
    var allowlist_str: ?[]const u8 = null;
    var arm_token_path: ?[]const u8 = null;
    var receipts_dir: ?[]const u8 = null;
    var chain_tip_dir: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--net")) {
            net = args_it.next() orelse {
                std.debug.print("ERROR: --net requires a value\n", .{});
                return 4;
            };
        } else if (std.mem.eql(u8, arg, "--port")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --port requires a number\n", .{});
                return 4;
            };
            listen_port = std.fmt.parseInt(u16, val, 10) catch {
                std.debug.print("ERROR: invalid --port: {s}\n", .{val});
                return 4;
            };
        } else if (std.mem.eql(u8, arg, "--artifact-dir")) {
            artifact_dir = args_it.next() orelse {
                std.debug.print("ERROR: --artifact-dir requires a path\n", .{});
                return 4;
            };
        } else if (std.mem.eql(u8, arg, "--allowlist")) {
            allowlist_str = args_it.next() orelse {
                std.debug.print("ERROR: --allowlist requires a value\n", .{});
                return 4;
            };
        } else if (std.mem.eql(u8, arg, "--arm-token")) {
            arm_token_path = args_it.next() orelse {
                std.debug.print("ERROR: --arm-token requires a path\n", .{});
                return 4;
            };
        } else if (std.mem.eql(u8, arg, "--receipts-dir")) {
            receipts_dir = args_it.next() orelse {
                std.debug.print("ERROR: --receipts-dir requires a path\n", .{});
                return 4;
            };
        } else if (std.mem.eql(u8, arg, "--chain-tip-dir")) {
            chain_tip_dir = args_it.next() orelse {
                std.debug.print("ERROR: --chain-tip-dir requires a path\n", .{});
                return 4;
            };
        } else {
            std.debug.print("ERROR: unknown flag: {s}\n", .{arg});
            return 4;
        }
    }

    // ── Build identity ──────────────────────────────────────────────
    std.debug.print("propagation: build={s}\n", .{build_version});
    if (chain_tip_dir) |ctd| {
        std.debug.print("propagation: chain_tip_dir={s} (canonical fragment bridge enabled)\n", .{ctd});
    }

    // ── Safety gates ────────────────────────────────────────────────

    // Gate 1: preview-only
    const net_val = net orelse {
        std.debug.print("ERROR: --net is required\n", .{});
        return 4;
    };
    if (!std.mem.eql(u8, net_val, "preview")) {
        std.debug.print("REFUSE: propagation harness is preview-only (got --net {s})\n", .{net_val});
        return 1;
    }

    // Gate 2: TSUNAGI_TXSUB_BROADCAST must NOT be set
    if (compat.hasEnvVar(alloc, "TSUNAGI_TXSUB_BROADCAST")) {
        std.debug.print("REFUSE: TSUNAGI_TXSUB_BROADCAST is set (mutually exclusive with propagation)\n", .{});
        return 1;
    }

    // Gate 3: artifact-dir required and sealed
    const art_dir = artifact_dir orelse {
        std.debug.print("ERROR: --artifact-dir is required\n", .{});
        return 4;
    };

    // Gate 4: allowlist required
    const allow_str = allowlist_str orelse {
        std.debug.print("ERROR: --allowlist is required (comma-separated IPs)\n", .{});
        return 4;
    };

    // Gate 5: arm-token validity (optional but checked if provided)
    if (arm_token_path) |tp| {
        if (!checkArmToken(tp)) {
            std.debug.print("REFUSE: guardian arm token invalid or expired\n", .{});
            return 1;
        }
    }

    return runServer(alloc, art_dir, allow_str, listen_port, chain_tip_dir, receipts_dir);
}

/// Core server loop — shared by CLI run() and thread-spawned runDirect().
fn runServer(
    alloc: std.mem.Allocator,
    art_dir: []const u8,
    allow_str: []const u8,
    listen_port: u16,
    chain_tip_dir: ?[]const u8,
    receipts_dir: ?[]const u8,
) u8 {
    // ── Parse allowlist (no artifact dependency) ────────────────────

    var allowed_ips = std.array_list.Managed([]const u8).init(alloc);
    defer allowed_ips.deinit();
    {
        var it = std.mem.splitScalar(u8, allow_str, ',');
        while (it.next()) |ip| {
            const trimmed = std.mem.trim(u8, ip, " ");
            if (trimmed.len > 0) {
                allowed_ips.append(trimmed) catch {};
            }
        }
    }
    if (allowed_ips.items.len == 0) {
        std.debug.print("ERROR: allowlist is empty\n", .{});
        return 4;
    }

    // ── TCP Listener (bind FIRST, before waiting for artifact) ──────
    // Cold-start fix: bind the port immediately so port 3033 is LISTEN
    // even before the producer has written an artifact. Connections that
    // arrive before the artifact is ready queue in the kernel SYN backlog
    // and are accepted once we reach the loop below.

    const addr = compat.IpAddress.parseIp4("0.0.0.0", listen_port) catch {
        std.debug.print("ERROR: cannot parse listen address\n", .{});
        return 2;
    };
    var server = blk: {
        var a = addr;
        break :blk a.listen(compat.defaultIo(), .{ .reuse_address = true }) catch {
            std.debug.print("ERROR: cannot bind to port {d}\n", .{listen_port});
            return 2;
        };
    };
    defer server.deinit(compat.defaultIo());

    std.debug.print("PROP_LISTEN: port={d}\n", .{listen_port});
    std.debug.print("propagation: listening on 0.0.0.0:{d} (preview-only, persistent)\n", .{listen_port});

    // ── Initial artifact load (non-blocking) ─────────────────────────
    // CRITICAL: the accept loop must NOT depend on artifact readiness.
    // Previously we blocked here polling until an artifact existed, but a
    // bound socket completes the TCP 3-way handshake in the kernel before
    // userspace ever calls accept(). Inbound clients (cardano-node) would
    // therefore send Propose successfully, then time out waiting for our
    // AcceptVersion because we were still sleeping in the artifact-wait
    // loop. Result: TrHandshakeClientError ExceededTimeLimit ServerHasAgency
    // SingConfirm — observed for weeks on every cardano-node dial. The
    // handshake is artifact-independent; the SERVE phase is what needs an
    // artifact. So we attempt a non-blocking load, leave current_snap null
    // if not ready, and gate only the serve step on artifact presence.

    var current_snap: ?ArtifactSnapshot = null;
    var generation: u64 = 0;
    if (loadArtifactSnapshotEx(alloc, art_dir, 0, chain_tip_dir)) |snap| {
        current_snap = snap;
        std.debug.print("PROP_ARTIFACT_READY: slot={d} block={d} hash={x}\n", .{
            snap.sealed.slot,
            snap.sealed.block_no,
            snap.sealed.header_hash[0..8],
        });
    } else {
        std.debug.print("PROP_NO_ARTIFACT_YET: dir={s} (accept loop will run; serve gated until artifact lands)\n", .{art_dir});
    }

    // Mempool for TxSubmission2 (serving + ingestion)
    const mempool_mod = @import("ledger/mempool.zig");
    const txsub_mod = @import("miniproto/txsubmission.zig");
    var prop_mempool = mempool_mod.Mempool.init(alloc, mempool_mod.DEFAULT_MAX_ITEMS, mempool_mod.DEFAULT_MAX_BYTES);
    defer prop_mempool.deinit();
    txsub_mod.g_mempool = &prop_mempool;

    // ── Persistent accept loop ──────────────────────────────────────
    // Each iteration: reload check → accept → post-accept reload check → handshake → serve → receipt → close → loop back.
    // Two reload checks: pre-accept (catches changes between connections) and post-accept
    // (catches changes that happened while blocked in accept). Never mid-connection.
    // Fresh per-connection state; listener is reused; artifact reloaded when changed.

    var connection_count: u32 = 0;
    while (true) {
        // ── Reload check (BEFORE accept) ────────────────────────────
        // Two cases:
        //   (a) we already have an artifact and may need to refresh it
        //   (b) we never loaded one — retry the initial load each iteration
        if (current_snap) |*cur_ptr| {
            if (artifactChanged(alloc, art_dir, cur_ptr)) {
                generation += 1;
                if (loadArtifactSnapshotEx(alloc, art_dir, generation, chain_tip_dir)) |new_snap| {
                    freeArtifactSnapshot(alloc, cur_ptr);
                    current_snap = new_snap;
                    const s = &current_snap.?;
                    std.debug.print("ARTIFACT_RELOAD gen={d} slot={d} block_no={d} hash={x} fragment_depth={d}\n", .{
                        s.generation, s.sealed.slot, s.sealed.block_no,
                        s.sealed.header_hash[0..8], s.fragment.len,
                    });
                } else {
                    std.debug.print("ARTIFACT_RELOAD_FAILED gen={d} keeping last-known-good slot={d} block_no={d} hash={x}\n", .{
                        generation, cur_ptr.sealed.slot, cur_ptr.sealed.block_no,
                        cur_ptr.sealed.header_hash[0..8],
                    });
                }
            }
        } else {
            // Still cold — try once per iteration without blocking.
            if (loadArtifactSnapshotEx(alloc, art_dir, 0, chain_tip_dir)) |snap| {
                current_snap = snap;
                std.debug.print("PROP_ARTIFACT_READY: slot={d} block={d} hash={x}\n", .{
                    snap.sealed.slot, snap.sealed.block_no, snap.sealed.header_hash[0..8],
                });
            }
        }

        // ── Ready log (before blocking on accept) ───────────────────
        if (current_snap) |snap| {
            std.debug.print("ARTIFACT_READY gen={d} slot={d} block_no={d} hash={x} fragment_depth={d}\n", .{
                snap.generation, snap.sealed.slot, snap.sealed.block_no,
                snap.sealed.header_hash[0..8], snap.fragment.len,
            });
        } else {
            std.debug.print("ARTIFACT_NOT_READY: accept loop will run, post-handshake serve will close until first forge lands\n", .{});
        }

        // Per-connection probe retry state (fresh each connection attempt)
        const max_probe_retries: u32 = 10;
        var probe_count: u32 = 0;

        var conn: compat.NetStream = undefined;
        var peer_ip_buf: [64]u8 = undefined;
        var peer_ip: []const u8 = undefined;
        var handshake_ok = false;
        var registry_id: u64 = 0;

        while (probe_count < max_probe_retries) {
            std.debug.print("propagation: waiting for relay connection...\n", .{});
            conn = server.accept(compat.defaultIo()) catch {
                std.debug.print("ERROR: accept failed\n", .{});
                continue;
            };

            // 0.16 net.Server.accept returns only a Stream (no peer address);
            // recover the peer sockaddr from the connected fd via getpeername
            // so the allowlist check + logging preserve the prior semantics.
            var peer_sa: std.posix.sockaddr = undefined;
            var peer_sa_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
            std.posix.getpeername(conn.socket.handle, &peer_sa, &peer_sa_len) catch {
                peer_sa = std.mem.zeroes(std.posix.sockaddr);
            };
            peer_ip = formatIp4(peer_sa, &peer_ip_buf);
            std.debug.print("propagation: connection accepted from {s}\n", .{peer_ip});

            if (!isAllowed(peer_ip, allowed_ips.items)) {
                std.debug.print("REFUSE: peer {s} not in allowlist\n", .{peer_ip});
                conn.close(compat.defaultIo());
                probe_count += 1;
                continue;
            }

            // Connection registry: register on TCP accept (state=cold);
            // markHandshakeDone moves it to warm. unregister on close.
            registry_id = connection_registry.register(.incoming, peer_ip);

            // Attempt handshake — probe detection happens inside
            var bt = streamToBt(conn);
            const hs_result = doServerHandshake(alloc, &bt);

            if (hs_result == .probe) {
                std.debug.print("propagation: probe from {s} (TCP connect + EOF, ignoring)\n", .{peer_ip});
                connection_registry.unregister(registry_id);
                registry_id = 0;
                conn.close(compat.defaultIo());
                probe_count += 1;
                continue;
            }
            if (hs_result == .fail) {
                std.debug.print("propagation: handshake failed from {s}\n", .{peer_ip});
                connection_registry.unregister(registry_id);
                registry_id = 0;
                conn.close(compat.defaultIo());
                probe_count += 1;
                continue;
            }

            // .ok — real handshake succeeded
            std.debug.print("propagation: handshake accepted from {s}\n", .{peer_ip});
            connection_registry.markHandshakeDone(registry_id);
            handshake_ok = true;
            break;
        }

        if (!handshake_ok) {
            std.debug.print("propagation: exceeded {d} probe retries, waiting for next connection...\n", .{max_probe_retries});
            continue;
        }

        connection_count += 1;

        // ── Artifact gate (post-handshake) ──────────────────────────
        // Handshake completed; if no sealed artifact has ever been written
        // we cannot serve a chain. Close cleanly. cardano-node sees a
        // successful handshake (no SingConfirm timeout), then a clean
        // close — it will re-promote periodically. The very moment the
        // first forge writes an artifact, the next reconnect serves it.
        // Try one more non-blocking load before giving up on this round.
        if (current_snap == null) {
            if (loadArtifactSnapshotEx(alloc, art_dir, 0, chain_tip_dir)) |snap| {
                current_snap = snap;
                std.debug.print("PROP_ARTIFACT_READY: slot={d} block={d} hash={x}\n", .{
                    snap.sealed.slot, snap.sealed.block_no, snap.sealed.header_hash[0..8],
                });
            }
        }
        if (current_snap == null) {
            std.debug.print("PROPAGATION_HANDSHAKE_ONLY: peer={s} conn=#{d} reason=no_artifact_yet (handshake OK, closing cleanly — cardano-node will reconnect)\n", .{ peer_ip, connection_count });
            connection_registry.unregister(registry_id);
            conn.close(compat.defaultIo());
            continue;
        }

        // ── Reload check (AFTER accept, BEFORE serve) ───────────────
        // Catches artifacts that changed while blocked in accept().
        if (current_snap) |*cur_ptr| {
            if (artifactChanged(alloc, art_dir, cur_ptr)) {
                generation += 1;
                if (loadArtifactSnapshotEx(alloc, art_dir, generation, chain_tip_dir)) |new_snap| {
                    freeArtifactSnapshot(alloc, cur_ptr);
                    current_snap = new_snap;
                    const s = &current_snap.?;
                    std.debug.print("ARTIFACT_RELOAD_POST_ACCEPT gen={d} slot={d} block_no={d} hash={x} fragment_depth={d}\n", .{
                        s.generation, s.sealed.slot, s.sealed.block_no,
                        s.sealed.header_hash[0..8], s.fragment.len,
                    });
                } else {
                    std.debug.print("ARTIFACT_RELOAD_POST_ACCEPT_FAILED gen={d} keeping last-known-good slot={d} block_no={d} hash={x}\n", .{
                        generation, cur_ptr.sealed.slot, cur_ptr.sealed.block_no,
                        cur_ptr.sealed.header_hash[0..8],
                    });
                }
            }
        }

        // current_snap is guaranteed non-null past the gate above.
        const snap: *ArtifactSnapshot = &current_snap.?;

        std.debug.print("propagation: connection #{d} serve start peer={s} gen={d}\n", .{ connection_count, peer_ip, snap.generation });

        // ── Initialize acceptance trace ─────────────────────────────
        var trace = AcceptanceTrace{};
        trace.connection_id = connection_count;
        trace.accepted_unix = compat.timestamp();
        trace.handshake_ok = true;
        trace.artifact_gen = snap.generation;
        trace.sealed_slot = snap.sealed.slot;
        trace.sealed_block_no = snap.sealed.block_no;
        trace.sealed_hash_prefix = std.mem.readInt(u64, snap.sealed.header_hash[0..8], .big);
        trace.fragment_depth = @intCast(snap.fragment.len);

        std.debug.print("ACCEPTANCE_CONN_TRUTH: connection_id={d} peer={s} accepted_unix={d} artifact_gen={d} sealed_slot={d} sealed_block_no={d} fragment_depth={d}\n", .{
            trace.connection_id, peer_ip, trace.accepted_unix,
            trace.artifact_gen, trace.sealed_slot, trace.sealed_block_no, trace.fragment_depth,
        });

        // ── Record follower tip before serving ──────────────────────
        var tip_before_buf: [128]u8 = undefined;
        const tip_before = readFollowerTip(alloc, &tip_before_buf);

        // ── Serve via mux (fresh per-connection state) ──────────────
        var served_header = false;
        var served_block = false;

        var bt = streamToBt(conn);
        const serve_result = serveMuxLoop(alloc, &bt, &snap.sealed, snap.fragment, &served_header, &served_block, art_dir, &trace, registry_id);

        std.debug.print("propagation: serveMuxLoop returned result={d}\n", .{serve_result});

        // ── Record follower tip after serving ───────────────────────
        var tip_after_buf: [128]u8 = undefined;
        const tip_after = readFollowerTip(alloc, &tip_after_buf);

        const no_inject_ok = std.mem.eql(u8, tip_before, tip_after);
        if (!no_inject_ok) {
            std.debug.print("propagation: NOTE tip changed during serve (follower is live-syncing, expected)\n", .{});
        }

        // ── Finalize trace ─────────────────────────────────────────
        trace.served_header = served_header;
        trace.served_block = served_block;

        // Orphan watchdog signal: header-served but block-not-served exits
        // mean cardano-node walked our chain to the fork point then dropped.
        if (served_header and !served_block) {
            const sho_new = g_serve_header_only_disconnects.fetchAdd(1, .release) + 1;
            std.debug.print("SERVE_DECISION: kind=header_only_disconnect served_header=true served_block=false sealed_slot={d} sealed_block_no={d} count={d}\n", .{
                snap.sealed.slot, snap.sealed.block_no, sho_new,
            });
        } else if (served_block) {
            std.debug.print("SERVE_DECISION: kind=full_serve served_header={} served_block=true sealed_slot={d} sealed_block_no={d}\n", .{
                served_header, snap.sealed.slot, snap.sealed.block_no,
            });
        } else {
            std.debug.print("SERVE_DECISION: kind=no_serve served_header=false served_block=false sealed_slot={d} sealed_block_no={d}\n", .{
                snap.sealed.slot, snap.sealed.block_no,
            });
        }

        // Phase 6 event: relay fetched our block (= network accepted signal)
        if (served_block) {
            std.debug.print("EVENT_BLOCK_ACCEPTED: slot={d} block_no={d} peer={s} blockfetch_rx={d}\n", .{
                snap.sealed.slot, snap.sealed.block_no, peer_ip, trace.blockfetch_rx_total,
            });
            // Phase 8.1: record acceptance for /status endpoint
            node_state.updateAccept(snap.sealed.slot, compat.timestamp());
            // Phase 9.4: propagation telemetry — record pull + compute latency.
            propagation_opt.onPull(snap.sealed.slot, snap.sealed.block_no);
            // Phase 9.8: acceptance feedback — mark matching forge as accepted.
            feedback.onAccept(snap.sealed.slot);
            // forge_stats: relay pulled our block — mark slot as adopted.
            forge_stats.onAdopted(snap.sealed.slot);
            // Phase 9.6: announce serve — relay pulled our block.
            announce.onServe(snap.sealed.slot, peer_ip);
            // Phase 8.7/9: adaptive + decision hooks
            adaptive.onBlockAccepted();
            decision.onSuccess();
        }

        std.debug.print("ACCEPTANCE_RESULT_TRUTH: connection_id={d} peer={s} handshake_ok={} relay_ahead={} tsunagi_ahead={} equal_tip={} chosen_slot={d} msg_request_next_rx_total={d} rollback_tx_total={d} rollforward_fragment_tx_total={d} rollforward_sealed_tx_total={d} blockfetch_rx_total={d} served_header={} served_block={} fresh_path_complete={} loop_exit_reason={s} msg_count={d}\n", .{
            trace.connection_id, peer_ip, trace.handshake_ok,
            trace.relay_ahead, trace.tsunagi_ahead, trace.equal_tip,
            trace.chosen_slot, trace.msg_request_next_rx_total,
            trace.rollback_tx_total, trace.rollforward_fragment_tx_total,
            trace.rollforward_sealed_tx_total, trace.blockfetch_rx_total,
            trace.served_header, trace.served_block, trace.fresh_path_complete,
            trace.exitReasonStr(), trace.msg_count,
        });

        // ── Write receipt (per-connection) ──────────────────────────
        const receipt_base = receipts_dir orelse art_dir;
        writeReceipt(alloc, receipt_base, peer_ip, &snap.sealed, served_header, served_block, tip_before, tip_after, no_inject_ok);
        writeAcceptanceReceipt(receipt_base, peer_ip, &trace);

        // ── Summary (per-connection) ────────────────────────────────
        std.debug.print("\n=== Propagation Serve (connection #{d}) ===\n", .{connection_count});
        std.debug.print("peer: {s}\n", .{peer_ip});
        std.debug.print("served_header: {}\n", .{served_header});
        std.debug.print("served_block: {}\n", .{served_block});
        std.debug.print("no_inject_ok: {}\n", .{no_inject_ok});

        // Close connection socket, loop back for next
        conn.close(compat.defaultIo());
        connection_registry.unregister(registry_id);
        registry_id = 0;
        std.debug.print("propagation: connection #{d} closed, returning to accept loop\n", .{connection_count});
    }
}

// ── Sealed artifact loading ─────────────────────────────────────────

const SealedArtifact = struct {
    slot: u64,
    block_no: u64,
    header_hash: [32]u8,
    header_cbor: []const u8,
    block_cbor: ?[]const u8, // null when sourced from chain_tip (header-only)
};

// ── Artifact Snapshot ───────────────────────────────────────────────
// Bundles all loaded artifact state for atomic reload at connection boundaries.

const ArtifactSnapshot = struct {
    sealed: SealedArtifact,
    fragment: []chainsync_server.FragmentEntry,
    generation: u64, // monotonic counter, incremented on each reload
    prev_hash: [32]u8, // from parseHeaderFields, for FindIntersect
    has_prev_hash: bool,
};

// ── AcceptanceTrace ────────────────────────────────────────────────
// Per-connection observability trace — captures the full acceptance state machine
// from TCP accept through loop exit. Fixed-size, no allocator needed.

pub const AcceptanceTrace = struct {
    connection_id: u32 = 0,
    accepted_unix: i64 = 0,
    handshake_ok: bool = false,
    artifact_gen: u64 = 0,
    sealed_slot: u64 = 0,
    sealed_block_no: u64 = 0,
    sealed_hash_prefix: u64 = 0,
    fragment_depth: u32 = 0,
    intersect_result_found: bool = false,
    intersect_method: [24]u8 = [_]u8{0} ** 24,
    intersect_method_len: u8 = 0,
    chosen_index: u32 = 0,
    chosen_slot: u64 = 0,
    relay_newest_slot: u64 = 0,
    relay_ahead: bool = false,
    tsunagi_ahead: bool = false,
    equal_tip: bool = false,
    need_rollback_initial: bool = false,
    msg_request_next_rx_total: u32 = 0,
    rollback_tx_total: u32 = 0,
    rollforward_fragment_tx_total: u32 = 0,
    rollforward_sealed_tx_total: u32 = 0,
    awaitreply_tx_total: u32 = 0,
    blockfetch_rx_total: u32 = 0,
    blockfetch_batches_tx_total: u32 = 0,
    blockfetch_last_start_slot: u64 = 0,
    blockfetch_last_end_slot: u64 = 0,
    served_header: bool = false,
    served_block: bool = false,
    fresh_path_complete: bool = false,
    loop_exit_reason: [24]u8 = [_]u8{0} ** 24,
    loop_exit_reason_len: u8 = 0,
    msg_count: u32 = 0,

    fn setMethod(self: *AcceptanceTrace, method: []const u8) void {
        const n = @min(method.len, self.intersect_method.len);
        @memcpy(self.intersect_method[0..n], method[0..n]);
        self.intersect_method_len = @intCast(n);
    }

    fn setExitReason(self: *AcceptanceTrace, reason: []const u8) void {
        const n = @min(reason.len, self.loop_exit_reason.len);
        @memcpy(self.loop_exit_reason[0..n], reason[0..n]);
        self.loop_exit_reason_len = @intCast(n);
    }

    fn methodStr(self: *const AcceptanceTrace) []const u8 {
        return self.intersect_method[0..self.intersect_method_len];
    }

    fn exitReasonStr(self: *const AcceptanceTrace) []const u8 {
        return self.loop_exit_reason[0..self.loop_exit_reason_len];
    }
};

/// Load a complete artifact snapshot: sealed + HEADER_FIX + fragment + validation.
/// Returns null on failure (caller should keep last-known-good).
fn loadArtifactSnapshot(alloc: std.mem.Allocator, art_dir: []const u8, generation: u64) ?ArtifactSnapshot {
    return loadArtifactSnapshotEx(alloc, art_dir, generation, null);
}

// Cold-start spam suppression: pre-forge, loadArtifactSnapshotEx is
// called once per accept-loop iteration (every ~10s when cardano-node
// reconnects). Printing the failure each time produced 130+ lines/min
// of expected steady-state. Rate-limit gen=0 failures to once per N
// attempts. gen > 0 failures (we had an artifact, then lost it) keep
// printing immediately — that case IS concerning.
var g_artifact_cold_fail_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
const ARTIFACT_COLD_FAIL_LOG_EVERY: u64 = 60; // ~10min at 1 try / 10s

fn loadArtifactSnapshotEx(alloc: std.mem.Allocator, art_dir: []const u8, generation: u64, ct_dir: ?[]const u8) ?ArtifactSnapshot {
    // Two-phase artifact publication: refuse to load any generation until
    // producer has written the `.ready` sentinel — written LAST after both
    // sealed-block files AND fragment ancestry are fully on disk. Without
    // this guard, this function could observe a partially-published
    // artifact where the sealed block is visible but the fragment is still
    // empty/old, producing ARTIFACT_LOAD ... fragment_depth=0 followed by
    // a degraded RollForward. Observed live at slot 113310132 on
    // 2026-05-28 where cardano-node received the header and disconnected
    // before BlockFetch. Cold-start (no artifact yet) is handled by the
    // pre-existing ARTIFACT_NOT_READY_YET log below; the new branch only
    // adds rate-limited diagnostic logging when a sealed artifact exists
    // but the sentinel is absent (mid-write).
    {
        var ready_buf: [512]u8 = undefined;
        const ready_path = std.fmt.bufPrint(&ready_buf, "{s}/.ready", .{art_dir}) catch return null;
        compat.fs.cwd().access(ready_path, .{}) catch {
            if (generation != 0) {
                std.debug.print("ARTIFACT_LOAD_NOT_READY gen={d} reason=ready_sentinel_absent dir={s}\n", .{ generation, art_dir });
            }
            return null;
        };
    }
    var sealed = loadSealedArtifact(alloc, art_dir) orelse {
        if (generation == 0) {
            const n = g_artifact_cold_fail_counter.fetchAdd(1, .release);
            if (n == 0 or (n % ARTIFACT_COLD_FAIL_LOG_EVERY) == 0) {
                std.debug.print("ARTIFACT_NOT_READY_YET gen=0 attempts={d} dir={s} (pre-forge steady-state; rate-limited 1-in-{d})\n", .{ n + 1, art_dir, ARTIFACT_COLD_FAIL_LOG_EVERY });
            }
        } else {
            std.debug.print("ARTIFACT_LOAD_FAILED gen={d} reason=loadSealedArtifact_failed dir={s}\n", .{ generation, art_dir });
        }
        return null;
    };

    // HEADER_FIX: resolve authoritative slot/block_no from header CBOR
    var prev_hash: [32]u8 = [_]u8{0} ** 32;
    var has_prev_hash: bool = false;

    if (chainsync_server.ChainSyncServer.parseHeaderFields(alloc, sealed.header_cbor)) |fields| {
        if (fields.slot != sealed.slot or fields.block_no != sealed.block_no) {
            std.debug.print("propagation: HEADER_FIX meta slot={d} block_no={d} -> header slot={d} block_no={d}\n", .{
                sealed.slot, sealed.block_no, fields.slot, fields.block_no,
            });
            sealed.slot = fields.slot;
            sealed.block_no = fields.block_no;
        }
        if (fields.prev_hash) |ph| {
            prev_hash = ph;
            has_prev_hash = true;
            std.debug.print("propagation: header prevHash={x}\n", .{
                ph[0..8],
            });
        } else {
            std.debug.print("propagation: WARN header prevHash not found\n", .{});
        }
    }

    // Load fragment — prefer art_dir/fragment when present (frozen producer
    // snapshot), fall back to chain_tip_dir only as cold-start.
    //
    // Rationale: chain_tip/fragment is a live follower-owned structure that
    // saveChainTipHeader → fragmentWipe resets the moment a non-successor
    // header arrives (reason=block_no_gap fires when the producer's own
    // forged block becomes the new tip; see follower.zig:9215-9225).
    // Observed live at slot 113529807 / 2026-05-31: producer published
    // depth=2161 into art_dir/fragment, follower wiped chain_tip/fragment
    // one line later, propagation_server read chain_tip and served
    // fragment_depth=0. The orphan-dir disk dump showed 10803 files
    // intact in propagation_artifact/fragment — the snapshot was correct,
    // the reader consulted the wrong directory.
    //
    // Cold-start (no sealed copy yet) still uses ct_dir so pre-forge
    // chain-tip ancestry serving is unchanged.
    const art_frag_present = blk: {
        var probe_buf: [600]u8 = undefined;
        const probe = std.fmt.bufPrint(&probe_buf, "{s}/fragment", .{art_dir}) catch break :blk false;
        var d = compat.fs.cwd().openDir(probe, .{}) catch break :blk false;
        d.close();
        break :blk true;
    };
    const frag_source_dir = if (art_frag_present) art_dir else (ct_dir orelse art_dir);
    const fragment = loadFragment(alloc, frag_source_dir);
    const using_chain_tip_fragment = !art_frag_present and (ct_dir != null);

    if (using_chain_tip_fragment) {
        std.debug.print("propagation: fragment loaded from chain_tip_dir ({d} entries)\n", .{fragment.len});
    } else {
        std.debug.print("propagation: fragment loaded from art_dir ({d} entries)\n", .{fragment.len});
    }

    // Validate fragment tail == sealed prevHash (hard coherence guard)
    var artifact_coherent: bool = false;
    var coherence_reason: []const u8 = "unknown";
    if (fragment.len > 0) {
        const frag_oldest_slot = fragment[0].slot;
        const frag_newest_slot = fragment[fragment.len - 1].slot;
        const tail = &fragment[fragment.len - 1];
        std.debug.print("propagation: fragment loaded entries={d} oldest_slot={d} newest_slot={d}\n", .{
            fragment.len, frag_oldest_slot, frag_newest_slot,
        });
        if (using_chain_tip_fragment) {
            // Chain-tip bridge mode: fragment is from the live canonical chain,
            // not from the artifact. Coherence with sealed block is irrelevant —
            // the stale-tip guard in handleRequestNext will skip the sealed block
            // and go to AwaitReply, where LIVE_PUSH delivers the fresh forge.
            artifact_coherent = true;
            coherence_reason = "chain_tip_bridge";
            std.debug.print("propagation: chain_tip_bridge mode — fragment is canonical chain, coherence with sealed block skipped\n", .{});
        } else if (has_prev_hash) {
            const tail_matches = std.mem.eql(u8, &prev_hash, &tail.hash);
            const gap_slots: i128 = @as(i128, sealed.slot) - @as(i128, frag_newest_slot);
            std.debug.print("ARTIFACT_COHERENCE_TRUTH: sealed_slot={d} sealed_block_no={d} sealed_hash={x} sealed_prev_hash={x} fragment_oldest_slot={d} fragment_newest_slot={d} fragment_depth={d} tail_hash={x} tail_matches_sealed_parent={} sealed_fragment_gap_slots={d}\n", .{
                sealed.slot, sealed.block_no,
                sealed.header_hash[0..8],
                prev_hash[0..8],
                frag_oldest_slot, frag_newest_slot, fragment.len,
                tail.hash[0..8],
                tail_matches, gap_slots,
            });
            if (tail_matches) {
                artifact_coherent = true;
                coherence_reason = "tail_matches_sealed_parent";
                std.debug.print("propagation: fragment tail IS direct parent of sealed tip\n", .{});
            } else {
                coherence_reason = "tail_hash_mismatch";
                std.debug.print("propagation: REJECT sealed tip has NO verified parent in fragment (tail_hash mismatch) artifact_ready=false\n", .{});
            }
        } else {
            // No prevHash available — can't verify, allow with warning
            artifact_coherent = true;
            coherence_reason = "no_prev_hash_available";
            std.debug.print("propagation: WARN header prevHash not found, skipping fragment coherence check\n", .{});
        }
    } else {
        // No fragment — single-header mode, allow
        artifact_coherent = true;
        coherence_reason = "single_header_mode";
        std.debug.print("propagation: no fragment available (single-header mode)\n", .{});
    }
    std.debug.print("ARTIFACT_READY_TRUTH: artifact_ready={} reason={s} gen={d} sealed_slot={d}\n", .{
        artifact_coherent, coherence_reason, generation, sealed.slot,
    });

    // ── Fragment coverage diagnostics ────────────────────────────
    if (fragment.len > 0) {
        // Build FragmentSlotInfo from loaded entries
        const slot_infos = alloc.alloc(fragment_coverage.FragmentSlotInfo, fragment.len) catch null;
        if (slot_infos) |infos| {
            defer alloc.free(infos);
            for (fragment, 0..) |entry, idx| {
                infos[idx] = .{
                    .slot = entry.slot,
                    .hash = entry.hash,
                    .prev_hash = entry.prev_hash,
                };
            }

            // Count numeric files in {art_dir}/fragment/
            const numeric_file_count = countFragmentFiles(art_dir);

            const report = fragment_coverage.analyzeFragment(infos, numeric_file_count);
            std.debug.print("propagation: coverage intersectable=[{d}..{d}] usable_depth={d} numeric_files={d} breaks={d} first_break_slot={d}\n", .{
                report.intersectable_oldest_slot,
                report.intersectable_newest_slot,
                report.usable_contiguous_depth,
                report.numeric_file_count,
                report.break_count,
                report.first_break_slot,
            });
        }
    } else {
        std.debug.print("propagation: coverage skipped (no fragment)\n", .{});
    }

    // If fragment is incoherent with sealed tip, drop it (serve in single-header mode).
    // This prevents serving a fragment whose tail doesn't chain into the sealed block,
    // which would cause relay intersection at an old point followed by disconnect.
    var effective_fragment: []chainsync_server.FragmentEntry = @constCast(fragment);
    if (!artifact_coherent and fragment.len > 0) {
        std.debug.print("ARTIFACT_LOAD_DEGRADED: dropping incoherent fragment (depth={d}) for gen={d}, serving single-header mode\n", .{
            fragment.len, generation,
        });
        // Free the incoherent fragment
        for (fragment) |entry| {
            alloc.free(@constCast(entry.header_cbor));
            if (entry.body_cbor) |bc| alloc.free(@constCast(bc));
        }
        alloc.free(@constCast(fragment));
        effective_fragment = @constCast(&[_]chainsync_server.FragmentEntry{});
    }

    std.debug.print("ARTIFACT_LOAD gen={d} slot={d} block_no={d} hash={x} fragment_depth={d} coherent={}\n", .{
        generation,
        sealed.slot,
        sealed.block_no,
        sealed.header_hash[0..8],
        effective_fragment.len,
        artifact_coherent,
    });

    return .{
        .sealed = sealed,
        .fragment = effective_fragment,
        .generation = generation,
        .prev_hash = prev_hash,
        .has_prev_hash = has_prev_hash,
    };
}

/// Free all heap allocations owned by a snapshot.
fn freeArtifactSnapshot(alloc: std.mem.Allocator, snap: *ArtifactSnapshot) void {
    // Free fragment entry header + body CBORs
    for (snap.fragment) |entry| {
        alloc.free(@constCast(entry.header_cbor));
        if (entry.body_cbor) |bc| alloc.free(@constCast(bc));
    }
    // Free fragment slice itself (if non-empty, it's heap-allocated)
    if (snap.fragment.len > 0) {
        alloc.free(snap.fragment);
    }
    // Free sealed header/block CBORs
    alloc.free(@constCast(snap.sealed.header_cbor));
    if (snap.sealed.block_cbor) |bc| {
        alloc.free(@constCast(bc));
    }
    // Zero out
    snap.sealed.slot = 0;
    snap.sealed.block_no = 0;
    snap.sealed.header_hash = [_]u8{0} ** 32;
    snap.sealed.header_cbor = &[_]u8{};
    snap.sealed.block_cbor = null;
    snap.fragment = &[_]chainsync_server.FragmentEntry{};
    snap.generation = 0;
}

/// Cheap change detection: compare meta.json slot+block_no and block_header_hash.hex
/// against current snapshot. Returns false on read errors (conservative).
fn artifactChanged(alloc: std.mem.Allocator, art_dir: []const u8, current: *const ArtifactSnapshot) bool {
    // Read meta.json
    var meta_path_buf: [512]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&meta_path_buf, "{s}/meta.json", .{art_dir}) catch return false;
    const meta_bytes = readFileBounded(alloc, meta_path, 8192) orelse {
        std.debug.print("ARTIFACT_CHECK read_failed file=meta.json dir={s} (keeping last-known-good)\n", .{art_dir});
        return false;
    };
    defer alloc.free(meta_bytes);

    const disk_slot = parseMetaSlot(meta_bytes) orelse {
        std.debug.print("ARTIFACT_CHECK parse_failed field=slot dir={s} (keeping last-known-good)\n", .{art_dir});
        return false;
    };
    const disk_block_no = parseMetaBlockNo(meta_bytes) orelse 0;

    // Read block_header_hash.hex (must match loadSealedArtifact's file)
    var hash_path_buf: [512]u8 = undefined;
    const hash_path = std.fmt.bufPrint(&hash_path_buf, "{s}/block_header_hash.hex", .{art_dir}) catch return false;
    const hash_hex = readFileBounded(alloc, hash_path, 128) orelse {
        std.debug.print("ARTIFACT_CHECK read_failed file=block_header_hash.hex dir={s} (keeping last-known-good)\n", .{art_dir});
        return false;
    };
    defer alloc.free(hash_hex);

    var disk_hash: [32]u8 = [_]u8{0} ** 32;
    const trimmed = std.mem.trim(u8, hash_hex, " \t\r\n");
    if (trimmed.len != 64 or !parseHexToHash(trimmed, &disk_hash)) {
        std.debug.print("ARTIFACT_CHECK parse_failed file=block_header_hash.hex len={d} dir={s} (keeping last-known-good)\n", .{ trimmed.len, art_dir });
        return false;
    }

    const changed = (disk_slot != current.sealed.slot) or
        (disk_block_no != current.sealed.block_no) or
        (!std.mem.eql(u8, &disk_hash, &current.sealed.header_hash));

    std.debug.print("ARTIFACT_SOURCE_TRUTH: disk_slot={d} disk_block_no={d} disk_hash={x} current_slot={d} current_block_no={d} current_hash={x} source_kind=sealed_snapshot changed={}\n", .{
        disk_slot,
        disk_block_no,
        disk_hash[0..8],
        current.sealed.slot,
        current.sealed.block_no,
        current.sealed.header_hash[0..8],
        changed,
    });

    return changed;
}

fn loadSealedArtifact(alloc: std.mem.Allocator, dir: []const u8) ?SealedArtifact {
    // Verify directory exists and is accessible
    {
        var d = compat.fs.cwd().openDir(dir, .{}) catch return null;
        d.close();
    }

    // Read block_header.cbor (required) — real Cardano header: [header_body, kes_sig]
    var header_path_buf: [512]u8 = undefined;
    const header_path = std.fmt.bufPrint(&header_path_buf, "{s}/block_header.cbor", .{dir}) catch return null;
    const header_cbor = readFileBounded(alloc, header_path, 64 * 1024) orelse return null;

    // Read block.cbor (optional — null when sourced from chain_tip)
    var block_path_buf: [512]u8 = undefined;
    const block_path = std.fmt.bufPrint(&block_path_buf, "{s}/block.cbor", .{dir}) catch return null;
    const block_cbor = readFileBounded(alloc, block_path, 4 * 1024 * 1024);
    if (block_cbor == null) {
        std.debug.print("loadSealedArtifact: block.cbor not found (header-only mode)\n", .{});
    }

    // Read meta.json for slot, block_no, and hash
    var meta_path_buf: [512]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&meta_path_buf, "{s}/meta.json", .{dir}) catch return null;
    const meta_bytes = readFileBounded(alloc, meta_path, 8192) orelse {
        alloc.free(header_cbor);
        if (block_cbor) |bc| alloc.free(bc);
        return null;
    };
    defer alloc.free(meta_bytes);

    // Parse slot and hash from meta.json
    const slot = parseMetaSlot(meta_bytes) orelse {
        std.debug.print("loadSealedArtifact: parseMetaSlot failed\n", .{});
        alloc.free(header_cbor);
        if (block_cbor) |bc| alloc.free(bc);
        return null;
    };
    const block_no = parseMetaBlockNo(meta_bytes) orelse 0;

    var hash: [32]u8 = undefined;
    if (!parseMetaHash(meta_bytes, &hash)) {
        // Fallback: read block_header_hash.hex file (forge outputs hash as separate file)
        var hash_path_buf: [512]u8 = undefined;
        const hash_path = std.fmt.bufPrint(&hash_path_buf, "{s}/block_header_hash.hex", .{dir}) catch {
            alloc.free(header_cbor);
            if (block_cbor) |bc| alloc.free(bc);
            return null;
        };
        const hash_hex = readFileBounded(alloc, hash_path, 128) orelse {
            std.debug.print("loadSealedArtifact: no header_hash in meta.json and no block_header_hash.hex file\n", .{});
            alloc.free(header_cbor);
            if (block_cbor) |bc| alloc.free(bc);
            return null;
        };
        defer alloc.free(hash_hex);
        // Trim whitespace/newlines, expect exactly 64 hex chars
        const trimmed = std.mem.trim(u8, hash_hex, " \t\r\n");
        if (trimmed.len != 64 or !parseHexToHash(trimmed, &hash)) {
            std.debug.print("loadSealedArtifact: block_header_hash.hex invalid (len={d})\n", .{trimmed.len});
            alloc.free(header_cbor);
            if (block_cbor) |bc| alloc.free(bc);
            return null;
        }
        std.debug.print("loadSealedArtifact: header_hash from block_header_hash.hex\n", .{});
    }

    // Self-verify: stored hash MUST equal Blake2b256(header_cbor).
    // If forge writes a stale or mismatched hex file alongside fresh header.cbor,
    // we'd advertise a wrong hash via MsgRollForward and the relay would reject
    // with UnexpectedHeaderHash. Refuse to load on mismatch.
    var computed_hash: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(header_cbor, &computed_hash, .{});
    if (!std.mem.eql(u8, &computed_hash, &hash)) {
        std.debug.print("FORGE_HASH_MISMATCH: stored_hash={x} computed_hash={x} header_cbor_len={d}\n", .{
            hash[0..8],
            computed_hash[0..8],
            header_cbor.len,
        });
        // The artifact is unsafe to advertise. Refuse to load.
        // Caller treats null as "no artifact ready" — handler will respond
        // IntersectNotFound / NoBlocks gracefully (post-#155/#156).
        alloc.free(header_cbor);
        if (block_cbor) |bc| alloc.free(bc);
        return null;
    }
    std.debug.print("FORGE_HASH_VERIFIED: hash={x} header_cbor_len={d}\n", .{
        hash[0..8], header_cbor.len,
    });

    return .{
        .slot = slot,
        .block_no = block_no,
        .header_hash = hash,
        .header_cbor = header_cbor,
        .block_cbor = block_cbor,
    };
}

fn readFileBounded(alloc: std.mem.Allocator, path: []const u8, max_size: usize) ?[]u8 {
    var f = compat.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    return f.readToEndAlloc(alloc, max_size) catch null;
}

/// Count .header.cbor files in {art_dir}/fragment/ (numeric file count for coverage).
fn countFragmentFiles(art_dir: []const u8) usize {
    var frag_dir_buf: [512]u8 = undefined;
    const frag_dir = std.fmt.bufPrint(&frag_dir_buf, "{s}/fragment", .{art_dir}) catch return 0;
    var dir = compat.fs.cwd().openDir(frag_dir, .{ .iterate = true }) catch return 0;
    defer dir.close();
    var count: usize = 0;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".header.cbor")) count += 1;
    }
    return count;
}

/// Load fragment entries from artifact_dir/fragment/ directory.
/// Returns a sorted (oldest→newest) slice of FragmentEntry.
/// Verifies contiguous ancestry: each entry's prev_hash == predecessor's hash.
/// Returns empty slice if no fragment directory or no valid entries.
fn loadFragment(alloc: std.mem.Allocator, art_dir: []const u8) []chainsync_server.FragmentEntry {
    var frag_dir_buf: [512]u8 = undefined;
    const frag_dir = std.fmt.bufPrint(&frag_dir_buf, "{s}/fragment", .{art_dir}) catch return &[_]chainsync_server.FragmentEntry{};

    var dir = compat.fs.cwd().openDir(frag_dir, .{ .iterate = true }) catch {
        std.debug.print("propagation: fragment/ directory not found (single-header mode)\n", .{});
        return &[_]chainsync_server.FragmentEntry{};
    };
    defer dir.close();

    // Collect sequence numbers
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

    if (seq_count == 0) {
        std.debug.print("propagation: fragment/ directory empty\n", .{});
        return &[_]chainsync_server.FragmentEntry{};
    }

    // Sort ascending (oldest first)
    std.mem.sort(u32, seqs[0..seq_count], {}, std.sort.asc(u32));

    // Load each entry
    var entries = alloc.alloc(chainsync_server.FragmentEntry, seq_count) catch return &[_]chainsync_server.FragmentEntry{};
    var loaded: usize = 0;

    for (seqs[0..seq_count]) |seq| {
        var seq_buf: [8]u8 = undefined;
        const seq_str = std.fmt.bufPrint(&seq_buf, "{d:0>8}", .{seq}) catch continue;

        // Read header CBOR
        var hdr_path_buf: [512]u8 = undefined;
        const hdr_path = std.fmt.bufPrint(&hdr_path_buf, "{s}/{s}.header.cbor", .{ frag_dir, seq_str }) catch continue;
        const header_cbor = readFileBounded(alloc, hdr_path, 64 * 1024) orelse continue;

        // Read hash hex
        var hash_path_buf: [512]u8 = undefined;
        const hash_path = std.fmt.bufPrint(&hash_path_buf, "{s}/{s}.hash.hex", .{ frag_dir, seq_str }) catch continue;
        const hash_hex = readFileBounded(alloc, hash_path, 128) orelse {
            alloc.free(header_cbor);
            continue;
        };
        defer alloc.free(hash_hex);

        const trimmed_hash = std.mem.trim(u8, hash_hex, " \t\r\n");
        var entry_hash: [32]u8 = undefined;
        if (trimmed_hash.len != 64 or !parseHexToHash(trimmed_hash, &entry_hash)) {
            alloc.free(header_cbor);
            continue;
        }

        // Parse header fields for slot, block_no, prev_hash
        const fields = chainsync_server.ChainSyncServer.parseHeaderFields(alloc, header_cbor) orelse {
            alloc.free(header_cbor);
            continue;
        };

        // Read block body CBOR (optional — may not exist for older fragments)
        var body_path_buf: [512]u8 = undefined;
        const body_cbor: ?[]const u8 = if (std.fmt.bufPrint(&body_path_buf, "{s}/{s}.body.cbor", .{ frag_dir, seq_str })) |bp|
            readFileBounded(alloc, bp, 4 * 1024 * 1024)
        else |_|
            null;

        entries[loaded] = .{
            .slot = fields.slot,
            .block_no = fields.block_no,
            .hash = entry_hash,
            .prev_hash = fields.prev_hash orelse [_]u8{0} ** 32,
            .header_cbor = header_cbor,
            .body_cbor = body_cbor,
        };
        if (loaded == 0) {
            std.debug.print("ERA_DIAG: FragmentEntry[0] era_index={d} slot={d}\n", .{ entries[0].era_index, fields.slot });
        }
        loaded += 1;
    }

    if (loaded == 0) {
        alloc.free(entries);
        std.debug.print("propagation: fragment/ no valid entries loaded\n", .{});
        return &[_]chainsync_server.FragmentEntry{};
    }

    const result = entries[0..loaded];

    // Verify contiguous ancestry: each entry's prev_hash == predecessor's hash.
    // Walk backwards from the newest entry to find the longest contiguous tail
    // anchored at the newest entry (closest to sealed tip).
    var tail_start: usize = loaded; // will be set to start of contiguous tail
    {
        // Find the longest suffix where each entry chains to its predecessor
        var contig_from: usize = loaded - 1; // start at newest
        while (contig_from > 0) : (contig_from -= 1) {
            if (!std.mem.eql(u8, &result[contig_from].prev_hash, &result[contig_from - 1].hash)) {
                std.debug.print("propagation: fragment ancestry BREAK at idx={d} slot={d} block_no={d} prevHash={x} pred_hash={x}\n", .{
                    contig_from,
                    result[contig_from].slot,
                    result[contig_from].block_no,
                    result[contig_from].prev_hash[0..8],
                    result[contig_from - 1].hash[0..8],
                });
                break;
            }
        }
        tail_start = contig_from;
    }

    const tail_len = loaded - tail_start;

    if (tail_start > 0) {
        // Free orphaned header + body CBORs from discarded head entries BEFORE shift
        std.debug.print("propagation: fragment using contiguous tail from idx={d} len={d} (discarded {d} stale head entries)\n", .{
            tail_start, tail_len, tail_start,
        });
        {
            var m: usize = 0;
            while (m < tail_start) : (m += 1) {
                alloc.free(@constCast(result[m].header_cbor));
                if (result[m].body_cbor) |bc| alloc.free(@constCast(bc));
            }
        }
        // Shift contiguous tail to beginning
        var k: usize = 0;
        while (k < tail_len) : (k += 1) {
            result[k] = result[tail_start + k];
        }
    }

    std.debug.print("propagation: fragment loaded {d} contiguous entries, oldest_slot={d} newest_slot={d}\n", .{
        tail_len,
        result[0].slot,
        result[tail_len - 1].slot,
    });

    return result[0..tail_len];
}

fn parseMetaSlot(meta: []const u8) ?u64 {
    // Simple JSON extraction: find "slot" then : then number
    const key_start = std.mem.indexOf(u8, meta, "\"slot\"") orelse return null;
    // Find the colon after "slot"
    var pos = key_start + 6; // skip "slot"
    while (pos < meta.len and (meta[pos] == ' ' or meta[pos] == ':' or meta[pos] == '\t')) pos += 1;
    const num_start = pos;
    var end = num_start;
    while (end < meta.len and meta[end] >= '0' and meta[end] <= '9') end += 1;
    if (end == num_start) return null;
    return std.fmt.parseInt(u64, meta[num_start..end], 10) catch null;
}

fn parseMetaBlockNo(meta: []const u8) ?u64 {
    const key_start = std.mem.indexOf(u8, meta, "\"block_no\"") orelse return null;
    var pos = key_start + 10; // skip "block_no"
    while (pos < meta.len and (meta[pos] == ' ' or meta[pos] == ':' or meta[pos] == '\t')) pos += 1;
    const num_start = pos;
    var end = num_start;
    while (end < meta.len and meta[end] >= '0' and meta[end] <= '9') end += 1;
    if (end == num_start) return null;
    return std.fmt.parseInt(u64, meta[num_start..end], 10) catch null;
}

fn parseMetaHash(meta: []const u8, out: *[32]u8) bool {
    // Simple JSON extraction: find "header_hash" then : then "<64hex>"
    const key_start = std.mem.indexOf(u8, meta, "\"header_hash\"") orelse return false;
    var pos = key_start + 13; // skip "header_hash"
    // Skip :, whitespace, opening quote
    while (pos < meta.len and (meta[pos] == ' ' or meta[pos] == ':' or meta[pos] == '\t')) pos += 1;
    if (pos >= meta.len or meta[pos] != '"') return false;
    pos += 1; // skip opening quote
    const start = pos;
    if (start + 64 > meta.len) return false;
    const hex = meta[start .. start + 64];
    var byte_idx: usize = 0;
    var char_idx: usize = 0;
    while (char_idx + 1 < 64) : ({
        char_idx += 2;
        byte_idx += 1;
    }) {
        const hi = hexVal(hex[char_idx]) orelse return false;
        const lo = hexVal(hex[char_idx + 1]) orelse return false;
        out[byte_idx] = (@as(u8, hi) << 4) | @as(u8, lo);
    }
    return true;
}

fn parseHexToHash(hex: []const u8, out: *[32]u8) bool {
    if (hex.len != 64) return false;
    var byte_idx: usize = 0;
    var char_idx: usize = 0;
    while (char_idx + 1 < 64) : ({
        char_idx += 2;
        byte_idx += 1;
    }) {
        const hi = hexVal(hex[char_idx]) orelse return false;
        const lo = hexVal(hex[char_idx + 1]) orelse return false;
        out[byte_idx] = (@as(u8, hi) << 4) | @as(u8, lo);
    }
    return true;
}

fn hexVal(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    return null;
}

// ── Arm token check ─────────────────────────────────────────────────

fn checkArmToken(path: []const u8) bool {
    var f = compat.fs.cwd().openFile(path, .{}) catch return false;
    defer f.close();
    var buf: [256]u8 = undefined;
    const n = f.read(&buf) catch return false;
    if (n == 0) return false;

    // Token format: unix_expiry on first line
    const content = buf[0..n];
    var end: usize = 0;
    while (end < content.len and content[end] != '\n' and content[end] != '\r') end += 1;
    const expiry_str = std.mem.trim(u8, content[0..end], " \t");
    const expiry = std.fmt.parseInt(i64, expiry_str, 10) catch return false;

    const now = compat.timestamp();
    return now < expiry;
}

// ── Follower tip reading (NO_INJECT check) ──────────────────────────

fn readFollowerTip(alloc: std.mem.Allocator, buf: *[128]u8) []const u8 {
    _ = alloc;
    // Read from cursor.json if TSUNAGI_HOME is set (best-effort)
    const home = compat.getEnvVarOwned(std.heap.c_allocator, "TSUNAGI_HOME") catch return "unknown";
    defer std.heap.c_allocator.free(home);

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/cursor.json", .{home}) catch return "unknown";
    var f = compat.fs.cwd().openFile(path, .{}) catch return "no_cursor";
    defer f.close();

    // Read first 128 bytes to get tip hash from cursor
    const n = f.read(buf) catch return "read_err";
    if (n == 0) return "empty";

    // Compute SHA256 of cursor file content as a stable tip identifier
    var digest: [32]u8 = undefined;
    Sha256.hash(buf[0..n], &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(buf[0..64], &hex);
    return buf[0..64];
}

// ── Allowlist ───────────────────────────────────────────────────────

fn isAllowed(peer_ip: []const u8, allowlist: []const []const u8) bool {
    for (allowlist) |allowed| {
        if (std.mem.eql(u8, peer_ip, allowed)) return true;
    }
    return false;
}

fn formatIp4(addr: std.posix.sockaddr, buf: *[64]u8) []const u8 {
    const bytes = switch (addr.family) {
        std.posix.AF.INET => blk: {
            const sa: *const std.posix.sockaddr.in = @ptrCast(@alignCast(&addr));
            break :blk @as(*const [4]u8, @ptrCast(&sa.addr));
        },
        else => return "unknown",
    };
    const s = std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
        bytes[0], bytes[1], bytes[2], bytes[3],
    }) catch return "unknown";
    return s;
}

// ── Mux dispatch loop (post-handshake) ──────────────────────────────

fn serveMuxLoop(
    alloc: std.mem.Allocator,
    bt: *StreamBt,
    sealed: *const SealedArtifact,
    fragment: []const chainsync_server.FragmentEntry,
    served_header: *bool,
    served_block: *bool,
    art_dir: []const u8,
    trace: *AcceptanceTrace,
    registry_id: u64,
) u8 {
    // Initialize protocol servers
    if (sealed.block_no == 0) {
        std.debug.print("propagation: WARNING: block_no=0 in sealed artifact — relay will likely reject tip\n", .{});
    }
    var cs_server = chainsync_server.ChainSyncServer.initWithFragment(.{
        .slot = sealed.slot,
        .block_no = sealed.block_no,
        .hash = sealed.header_hash,
        .header_cbor = sealed.header_cbor,
    }, fragment);
    // Configurable sealed recency window (default 600 slots)
    if (compat.getenv("TSUNAGI_PROPAGATE_SEALED_RECENCY_WINDOW_SLOTS")) |val| {
        cs_server.sealed_recency_window = std.fmt.parseUnsigned(u64, val, 10) catch 600;
    }
    // Seed the bounded header history backstop from every fragment entry plus
    // the sealed tip. This widens FindIntersect coverage when the live fragment
    // is later dropped (coherence) or never accumulates (cold start). Bounded
    // by HISTORY_CAPACITY; older entries roll out FIFO.
    for (fragment) |fe| {
        cs_server.pushHistory(fe.slot, fe.hash);
    }
    cs_server.pushHistory(sealed.slot, sealed.header_hash);
    std.debug.print("CHAINSYNC_HISTORY_SEEDED: history_len={d} fragment_len={d} sealed_slot={d}\n", .{
        cs_server.history_len, fragment.len, sealed.slot,
    });
    std.debug.print("ERA_DIAG: sealed.era_index={d} fragment[0].era_index={d} fragment_len={d}\n", .{
        cs_server.sealed.era_index,
        if (fragment.len > 0) fragment[0].era_index else 99,
        fragment.len,
    });

    // Build fetchable blocks: fragment bodies + sealed tip
    var fetchable_count: usize = 0;
    for (fragment) |entry| {
        if (entry.body_cbor != null) fetchable_count += 1;
    }
    const has_sealed_block = sealed.block_cbor != null;
    if (has_sealed_block) fetchable_count += 1;

    var bf_server: ?blockfetch_server.BlockFetchServer = null;
    var fetchable_buf: []blockfetch_server.SealedBlock = &[_]blockfetch_server.SealedBlock{};
    if (fetchable_count > 0) {
        fetchable_buf = alloc.alloc(blockfetch_server.SealedBlock, fetchable_count) catch &[_]blockfetch_server.SealedBlock{};
        if (fetchable_buf.len == fetchable_count) {
            var fi: usize = 0;
            for (fragment) |entry| {
                if (entry.body_cbor) |bc| {
                    fetchable_buf[fi] = .{ .slot = entry.slot, .hash = entry.hash, .block_cbor = bc };
                    fi += 1;
                }
            }
            if (sealed.block_cbor) |bc| {
                fetchable_buf[fi] = .{ .slot = sealed.slot, .hash = sealed.header_hash, .block_cbor = bc };
                fi += 1;
            }
            bf_server = blockfetch_server.BlockFetchServer.init(fetchable_buf);

            var frag_body_count: usize = 0;
            for (fragment) |entry| {
                if (entry.body_cbor != null) frag_body_count += 1;
            }
            std.debug.print("propagation: fetchable blocks: {d} fragment + {d} sealed = {d} total\n", .{
                frag_body_count, @as(usize, if (has_sealed_block) 1 else 0), fetchable_count,
            });
        }
    }
    defer if (fetchable_buf.len > 0) alloc.free(fetchable_buf);

    const header_only = sealed.block_cbor == null;

    // Set shorter timeout for mux loop
    setStreamTimeout(bt, 1_000);

    std.debug.print("propagation: serveMuxLoop enter header_only={}\n", .{header_only});
    // Mux dispatch loop
    var timeout_count: u32 = 0;
    var max_timeouts: u32 = 120; // ~120s of idle before giving up (1s timeouts)
    var msg_count: u32 = 0;
    var chainsync_tx_count: u32 = 0; // RollForward + AwaitReply sent
    var chainsync_rx_count: u32 = 0; // MsgRequestNext + MsgFindIntersect received
    var blockfetch_rx_count: u32 = 0;
    var blockfetch_tx_count: u32 = 0;
    var done_received: bool = false;
    var last_proto_seen: u16 = 0;
    var fresh_path_complete: bool = false;
    // Forge-notify wake: snapshot the global forge sequence on entry; if it
    // advances during a recv timeout, force an immediate artifact reload.
    var notify_seq_snapshot: u64 = forge_notify.loadSeq();
    var fresh_timeout_short: bool = false;

    while (timeout_count < max_timeouts) {
        const seg = mux_bearer.recvSegmentWithTimeout(alloc, bt) catch |err| {
            if (err == error.TimedOut) {
                timeout_count += 1;

                // Ouroboros ChainSync: after AwaitReply, the server has agency
                // to send MsgRollForward when it gets new data. Check if the
                // artifact has been updated (new forge promoted) and proactively
                // send the new sealed tip on this existing connection.
                if (fresh_path_complete and !served_block.*) {
                    // First entry into LIVE_PUSH wait: shorten socket timeout
                    // from 1000ms to 100ms so artifact polls are sub-second.
                    if (!fresh_timeout_short) {
                        setStreamTimeout(bt, 100);
                        fresh_timeout_short = true;
                        // Preserve ~120s idle budget at the new 100ms granularity.
                        max_timeouts = 1200;
                        timeout_count = 0;
                    }
                    // Forge-notify hint: if the producer signaled a new forge,
                    // log it once and let the artifactChanged check below run
                    // (it always runs on every timeout cycle).
                    const cur_seq = forge_notify.loadSeq();
                    if (cur_seq != notify_seq_snapshot) {
                        std.debug.print("NOTIFY_WAKE: prop_seq={d}\n", .{cur_seq});
                        notify_seq_snapshot = cur_seq;
                    }
                    // Log every 10th poll to prove the wakeup loop is alive
                    if (timeout_count % 10 == 1) {
                        std.debug.print("LIVE_PUSH_POLL: timeout_count={d} fresh_path_complete={} served_block={} art_dir={s}\n", .{
                            timeout_count, fresh_path_complete, served_block.*, art_dir,
                        });
                    }
                    var reload_snap = ArtifactSnapshot{
                        .sealed = sealed.*,
                        .fragment = &[_]chainsync_server.FragmentEntry{},
                        .generation = 0,
                        .prev_hash = [_]u8{0} ** 32,
                        .has_prev_hash = false,
                    };
                    const changed = artifactChanged(alloc, art_dir, &reload_snap);
                    if (changed) {
                        std.debug.print("LIVE_PUSH_SCAN: artifact changed, loading new snapshot from {s}\n", .{art_dir});
                        if (loadArtifactSnapshot(alloc, art_dir, 0)) |new_snap| {
                            defer freeArtifactSnapshot(alloc, @constCast(&new_snap));
                            // Build and send MsgRollForward with updated sealed tip
                            var live_cs = chainsync_server.ChainSyncServer.init(.{
                                .slot = new_snap.sealed.slot,
                                .block_no = new_snap.sealed.block_no,
                                .hash = new_snap.sealed.header_hash,
                                .header_cbor = new_snap.sealed.header_cbor,
                            });
                            const rf = live_cs.encodeRollForward(alloc) orelse {
                                continue;
                            };
                            defer alloc.free(rf);
                            // PR-BCAST: gate the actual transmit on TSUNAGI_MODE=live.
                            if (!isLiveMode()) {
                                std.debug.print("PROPAGATION_SUPPRESSED: site=RF_PUSH slot={d} block={d} reason=preview_safe\n", .{
                                    new_snap.sealed.slot, new_snap.sealed.block_no,
                                });
                                continue;
                            }
                            std.debug.print("PROPAGATION_SEND: site=RF_PUSH slot={d} block={d} bytes={d}\n", .{
                                new_snap.sealed.slot, new_snap.sealed.block_no, rf.len,
                            });
                            mux_bearer.sendSegment(bt, .initiator, chainsync_server.chainsync_proto, rf) catch {
                                break;
                            };
                            chainsync_tx_count += 1;
                            served_header.* = true;
                            fresh_path_complete = false; // reset — new AwaitReply cycle
                            fresh_timeout_short = false; // reset alongside fresh_path_complete
                            timeout_count = 0;
                            std.debug.print("LIVE_PUSH_SEND: slot={d} block_no={d} hash={x} hdr_len={d} has_block={}\n", .{
                                new_snap.sealed.slot, new_snap.sealed.block_no,
                                new_snap.sealed.header_hash[0..8],
                                new_snap.sealed.header_cbor.len,
                                new_snap.sealed.block_cbor != null,
                            });

                            // Update BlockFetch server with new block if available
                            if (new_snap.sealed.block_cbor) |bc| {
                                if (alloc.alloc(blockfetch_server.SealedBlock, 1)) |nf| {
                                    if (alloc.dupe(u8, bc)) |bc_dupe| {
                                        nf[0] = .{ .slot = new_snap.sealed.slot, .hash = new_snap.sealed.header_hash, .block_cbor = bc_dupe };
                                        if (fetchable_buf.len > 0) alloc.free(fetchable_buf);
                                        fetchable_buf = nf;
                                        bf_server = blockfetch_server.BlockFetchServer.init(fetchable_buf);
                                    } else |_| {
                                        alloc.free(nf);
                                    }
                                } else |_| {}
                            }
                        }
                    } else {
                        // Artifact not changed — still waiting
                        if (timeout_count % 30 == 1) {
                            std.debug.print("LIVE_PUSH_WAIT: artifact unchanged, timeout_count={d}\n", .{timeout_count});
                        }
                    }
                } else {
                    // Not in fresh_path_complete or already served block
                    if (timeout_count % 30 == 1) {
                        std.debug.print("LIVE_PUSH_SKIP: fresh_path_complete={} served_block={} timeout_count={d}\n", .{
                            fresh_path_complete, served_block.*, timeout_count,
                        });
                    }
                }

                continue;
            }
            trace.setExitReason("recv_error");
            std.debug.print("propagation: serveMuxLoop recv error={s} msg_count={d}\n", .{ @errorName(err), msg_count });
            break;
        };

        if (seg == null) {
            trace.setExitReason("peer_disconnect");
            std.debug.print("LOOP_EXIT_TRUTH: reason=peer_disconnect msg_count={d} cs_rx={d} cs_tx={d} bf_rx={d} served_header={} served_sealed={} fresh_path_complete={} done_received={} last_proto_seen={d} last_sent_kind={s} last_sent_slot={d} last_sent_block_no={d} last_sent_frag_idx={d}\n", .{
                msg_count, chainsync_rx_count, chainsync_tx_count, blockfetch_rx_count,
                served_header.*, cs_server.served_sealed, fresh_path_complete, done_received, last_proto_seen,
                cs_server.last_sent_kind, cs_server.last_sent_slot, cs_server.last_sent_block_no, cs_server.last_sent_frag_idx,
            });
            std.debug.print("BF_EARLY_EXIT: reason=peer_disconnect conn={d}\n", .{trace.connection_id});
            break;
        }
        defer alloc.free(seg.?.payload);

        timeout_count = 0; // reset on activity
        msg_count += 1;

        const proto = seg.?.hdr.proto;
        const payload = seg.?.payload;
        last_proto_seen = proto;

        // Bounded instrumentation: log every inbound segment with first 8 bytes hex
        std.debug.print("mux: rx proto={d} dir={d} len={d} first8={s} msg#{d}\n", .{
            proto, @intFromEnum(seg.?.hdr.dir), payload.len, fmtFirst8(payload), msg_count,
        });

        if (proto == chainsync_server.chainsync_proto) {
            connection_registry.recordActivity(registry_id, connection_registry.PROTO_CHAINSYNC);
            std.debug.print("dispatch: proto={d} -> chainsync\n", .{proto});

            // Pipelining: relay may batch multiple CBOR messages into one mux segment.
            // Process all messages in the payload by advancing a cursor.
            var cs_cursor: usize = 0;
            var cs_send_err = false;
            while (cs_cursor < payload.len) {
                const sub_payload = payload[cs_cursor..];
                chainsync_rx_count += 1;
                const response = cs_server.handleMessage(alloc, sub_payload) orelse {
                    done_received = true;
                    std.debug.print("propagation: chainsync handleMessage returned null (MsgDone or decode error) msg#{d} cursor={d}\n", .{ msg_count, cs_cursor });
                    break;
                };
                defer alloc.free(response);

                // Advance cursor past the consumed CBOR item
                var fbs_measure = compat.fixedBufferStream(sub_payload);
                const measure_term = cbor.decode(alloc, fbs_measure.reader()) catch break;
                cbor.free(measure_term, alloc);
                cs_cursor += fbs_measure.pos;

                if (response.len >= 3 and response[0] == 0x83 and response[1] == 0x02) {
                    if (response[2] == 0x82) {
                        std.debug.print("chainsync: tx RollForward wire OK (HardFork wrapper present) first16={s}\n", .{fmtFirst16(response)});
                    } else {
                        std.debug.print("chainsync: ERROR: RollForward missing HardFork era wrapper! byte[2]=0x{x:0>2} expected 0x82 first16={s}\n", .{
                            response[2], fmtFirst16(response),
                        });
                    }
                }

                std.debug.print("chainsync: tx {s} len={d} first8={s}\n", .{
                    csaMsgName(response), response.len, fmtFirst8(response),
                });
                // PR-BCAST: only RollForward (0x83 0x02) carries our sealed
                // block. Suppress that one in preview_safe; RollBackward and
                // Intersect responses must always go through or the protocol
                // session breaks.
                const is_rollforward = response.len >= 2 and response[0] == 0x83 and response[1] == 0x02;
                if (is_rollforward and !isLiveMode()) {
                    std.debug.print("PROPAGATION_SUPPRESSED: site=RF_RESP slot={d} block={d} reason=preview_safe\n", .{
                        sealed.slot, sealed.block_no,
                    });
                    continue;
                }
                if (is_rollforward) {
                    std.debug.print("PROPAGATION_SEND: site=RF_RESP slot={d} block={d} bytes={d}\n", .{
                        sealed.slot, sealed.block_no, response.len,
                    });
                }
                mux_bearer.sendSegment(bt, .initiator, chainsync_server.chainsync_proto, response) catch |err| {
                    std.debug.print("propagation: chainsync sendSegment error={s} msg#{d}\n", .{ @errorName(err), msg_count });
                    cs_send_err = true;
                    break;
                };
                chainsync_tx_count += 1;
                if (cs_server.served_header) served_header.* = true;

                // ── Trace: classify response and update counters ────
                if (response.len >= 2 and response[0] == 0x83 and response[1] == 0x05) {
                    // IntersectFound — populate intersect trace fields
                    trace.intersect_result_found = true;
                    trace.relay_newest_slot = cs_server.relay_newest_slot;
                    trace.relay_ahead = (cs_server.relay_newest_slot > sealed.slot);
                    trace.tsunagi_ahead = (sealed.slot > cs_server.relay_newest_slot);
                    trace.equal_tip = (sealed.slot == cs_server.relay_newest_slot);
                    trace.need_rollback_initial = cs_server.need_rollback;
                    trace.chosen_slot = cs_server.intersect_slot;
                    trace.setMethod(cs_server.last_sent_kind);
                    std.debug.print("ACCEPTANCE_INTERSECT_TRUTH: connection_id={d} intersect_result_found=true chosen_slot={d} relay_newest_slot={d} method={s}\n", .{
                        trace.connection_id, trace.chosen_slot, trace.relay_newest_slot, trace.methodStr(),
                    });
                    std.debug.print("ACCEPTANCE_POSITION_TRUTH: connection_id={d} relay_ahead={} tsunagi_ahead={} equal_tip={} need_rollback_initial={}\n", .{
                        trace.connection_id, trace.relay_ahead, trace.tsunagi_ahead, trace.equal_tip, trace.need_rollback_initial,
                    });
                } else if (response.len >= 2 and response[0] == 0x83 and response[1] == 0x03) {
                    // RollBackward
                    trace.rollback_tx_total += 1;
                    trace.msg_request_next_rx_total += 1;
                } else if (response.len >= 2 and response[0] == 0x83 and response[1] == 0x02) {
                    // RollForward — distinguish fragment vs sealed via last_sent_kind
                    trace.msg_request_next_rx_total += 1;
                    if (std.mem.eql(u8, cs_server.last_sent_kind, "fragment")) {
                        trace.rollforward_fragment_tx_total += 1;
                    } else {
                        trace.rollforward_sealed_tx_total += 1;
                    }
                }

                // Detect AwaitReply → marks end of fresh serve path
                if (response.len >= 2 and response[1] == 0x01) {
                    trace.awaitreply_tx_total += 1;
                    trace.msg_request_next_rx_total += 1;
                    trace.fresh_path_complete = true;
                    fresh_path_complete = true;
                    break; // AwaitReply = server has agency, stop processing pipelined requests
                }
            }
            if (cs_send_err) break;
            if (payload.len > 2 and cs_cursor > 2) {
                std.debug.print("PIPELINE_TRUTH: payload_len={d} cursor={d} messages_processed={d}\n", .{
                    payload.len, cs_cursor, chainsync_tx_count,
                });
            }

            if (fresh_path_complete) {
                std.debug.print("AWAIT_REGISTER: sealed_slot={d} relay_newest={d} art_dir={s} timeout_count={d} msg_count={d}\n", .{
                    sealed.slot, cs_server.relay_newest_slot, art_dir, timeout_count, msg_count,
                });
            }

        } else if (proto == blockfetch_server.blockfetch_proto) {
            connection_registry.recordActivity(registry_id, connection_registry.PROTO_BLOCKFETCH);
            blockfetch_rx_count += 1;
            trace.blockfetch_rx_total += 1;
            std.debug.print("blockfetch: rx raw len={d} first8={s}\n", .{ payload.len, fmtFirst8(payload) });
            std.debug.print("dispatch: proto={d} -> blockfetch\n", .{proto});
            // BF_REQUEST entry — fires on EVERY blockfetch payload decode entry
            // (slot=0/end_slot=0 are placeholders until the inner CBOR decode
            // populates them; a second BF_REQUEST below carries the real slots).
            std.debug.print("BF_REQUEST: start_slot=0 end_slot=0 conn={d}\n", .{trace.connection_id});

            // Per-invocation observation flags (no behavior change — logging only).
            // bf_request_seen distinguishes MsgRequestRange (which must produce a
            // serve) from MsgClientDone (which must not). bf_from_slot / bf_to_slot
            // are hoisted from the inner decode block so subsequent BF_REQUEST and
            // BF_LOOKUP lines share a consistent slot pair.
            var bf_request_seen: bool = false;
            var bf_served_header: bool = false;
            var bf_served_block: bool = false;
            var bf_from_slot: u64 = 0;
            var bf_to_slot: u64 = 0;

            if (bf_server == null) {
                std.debug.print("blockfetch: no block.cbor (header-only mode), ignoring\n", .{});
                std.debug.print("BF_SERVE_ABORT: reason=state_not_ready slot=0 conn={d}\n", .{trace.connection_id});
                std.debug.print("BF_EARLY_EXIT: reason=no_artifact conn={d}\n", .{trace.connection_id});
                // Send MsgNoBlocks so the peer disconnects gracefully rather than
                // timing out at 60s. bf_server is null when sealed.block_cbor is
                // null (header-only mode); we cannot serve a body but the protocol
                // requires *some* reply to MsgRequestRange.
                if (blockfetch_server.encodeNoBlocksStandalone(alloc)) |nb_responses| {
                    for (nb_responses) |resp| {
                        std.debug.print("BF_SERVE_NOBLOCKS: slot=0 block_no=0 conn={d} bytes={d}\n", .{
                            trace.connection_id, resp.len,
                        });
                        mux_bearer.sendSegment(bt, .initiator, blockfetch_server.blockfetch_proto, resp) catch |err| {
                            std.debug.print("propagation: blockfetch sendSegment (NoBlocks) error={s}\n", .{@errorName(err)});
                            std.debug.print("BF_EARLY_EXIT: reason=send_error conn={d}\n", .{trace.connection_id});
                            break;
                        };
                        alloc.free(resp);
                    }
                    alloc.free(@constCast(nb_responses));
                }
                continue;
            }
            // Decode tag to distinguish MsgRequestRange vs ClientDone before handleMessage
            {
                var diag_fbs = compat.fixedBufferStream(payload);
                const diag_term = cbor.decode(alloc, diag_fbs.reader()) catch |err| {
                    std.debug.print("blockfetch: decode failed len={d} first8={s} err={s}\n", .{
                        payload.len, fmtFirst8(payload), @errorName(err),
                    });
                    std.debug.print("BF_SERVE_ABORT: reason=invalid_range slot=0 conn={d}\n", .{trace.connection_id});
                    std.debug.print("BF_EARLY_EXIT: reason=cbor_decode_failed conn={d}\n", .{trace.connection_id});
                    // Send MsgNoBlocks so the peer disconnects gracefully rather
                    // than waiting on the 60s timeout. Mirrors the bf_server==null
                    // pattern introduced in #140.
                    if (blockfetch_server.encodeNoBlocksStandalone(alloc)) |nb_responses| {
                        for (nb_responses) |resp| {
                            std.debug.print("BF_SERVE_NOBLOCKS: slot=0 block_no=0 conn={d} bytes={d}\n", .{
                                trace.connection_id, resp.len,
                            });
                            mux_bearer.sendSegment(bt, .initiator, blockfetch_server.blockfetch_proto, resp) catch |send_err| {
                                std.debug.print("propagation: blockfetch sendSegment (NoBlocks) error={s}\n", .{@errorName(send_err)});
                                std.debug.print("BF_EARLY_EXIT: reason=send_error conn={d}\n", .{trace.connection_id});
                                break;
                            };
                            alloc.free(resp);
                        }
                        alloc.free(@constCast(nb_responses));
                    } else {
                        std.debug.print("propagation: encodeNoBlocksStandalone failed\n", .{});
                    }
                    continue;
                };
                defer cbor.free(diag_term, alloc);
                if (diag_term == .array and diag_term.array.len >= 1 and diag_term.array[0] == .u64) {
                    const bf_tag = diag_term.array[0].u64;
                    if (bf_tag == 0) {
                        // Tag-driven classification: MsgRequestRange is identified by
                        // wire tag 0 alone, NEVER by extracted slot values. An Origin
                        // or zero-slot probe carries tag 0 with empty point arrays;
                        // setting bf_request_seen here — before any slot decode —
                        // ensures the handleMessage-null branch routes to the
                        // responses_alloc_failed sub-branch (which sends MsgNoBlocks)
                        // rather than the client_done sub-branch.
                        bf_request_seen = true;
                        // MsgRequestRange — extract slots for logging
                        if (diag_term.array.len >= 2 and diag_term.array[1] == .array and diag_term.array[1].array.len >= 1 and diag_term.array[1].array[0] == .u64) {
                            bf_from_slot = diag_term.array[1].array[0].u64;
                        }
                        if (diag_term.array.len >= 3 and diag_term.array[2] == .array and diag_term.array[2].array.len >= 1 and diag_term.array[2].array[0] == .u64) {
                            bf_to_slot = diag_term.array[2].array[0].u64;
                        }
                        trace.blockfetch_last_start_slot = bf_from_slot;
                        trace.blockfetch_last_end_slot = bf_to_slot;
                        std.debug.print("blockfetch: decoded MsgRequestRange start_slot={d} end_slot={d}\n", .{ bf_from_slot, bf_to_slot });
                        std.debug.print("BF_RX: slot={d} end_slot={d} conn={d}\n", .{ bf_from_slot, bf_to_slot, trace.connection_id });
                        // BF_REQUEST — emit immediately after MsgRequestRange decode,
                        // BEFORE any further gating. block_start/end are 0 placeholders
                        // because the wire format only carries (slot, hash) points.
                        std.debug.print("BF_REQUEST: slot_start={d} slot_end={d} block_start=0 block_end=0 conn={d}\n", .{
                            bf_from_slot, bf_to_slot, trace.connection_id,
                        });
                    } else if (bf_tag == 1) {
                        std.debug.print("blockfetch: decoded ClientDone\n", .{});
                    } else {
                        std.debug.print("blockfetch: decoded unknown tag={d}\n", .{bf_tag});
                    }
                } else {
                    std.debug.print("blockfetch: decode failed len={d} first8={s}\n", .{ payload.len, fmtFirst8(payload) });
                }
            }
            // BF_ARTIFACT_STATE — visibility into what the serve decision sees
            // right before handleMessage. fetchable_count reflects fetchable_buf
            // (post LIVE_PUSH updates if any).
            {
                const sh = sealed.header_hash;
                std.debug.print("BF_ARTIFACT_STATE: sealed_slot={d} sealed_block_no={d} sealed_hash_short={x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2} fetchable_count={d} request_start_slot={d} request_end_slot={d}\n", .{
                    sealed.slot, sealed.block_no,
                    sh[0], sh[1], sh[2], sh[3], sh[4], sh[5], sh[6], sh[7],
                    fetchable_buf.len, bf_from_slot, bf_to_slot,
                });
            }
            const responses = bf_server.?.handleMessage(alloc, payload) orelse {
                std.debug.print("blockfetch: handleMessage returned null (ClientDone or decode error)\n", .{});
                if (bf_request_seen) {
                    // Only an abort if a real range request was decoded — ClientDone is legit.
                    std.debug.print("BF_SERVE_ABORT: reason=artifact_not_found slot={d} conn={d}\n", .{
                        bf_from_slot, trace.connection_id,
                    });
                    std.debug.print("BF_EARLY_EXIT: reason=responses_alloc_failed conn={d}\n", .{trace.connection_id});
                    std.debug.print("BF_INVARIANT_VIOLATION: rx incremented but no serve, conn={d}\n", .{trace.connection_id});
                    // Send MsgNoBlocks so the peer disconnects gracefully rather
                    // than waiting on the 60s timeout. Mirrors the bf_server==null
                    // pattern introduced in #140. Only fires on the
                    // responses_alloc_failed / artifact_not_found sub-branch — the
                    // client_done sub-branch below is a clean disconnect that
                    // does not require a NoBlocks reply.
                    if (blockfetch_server.encodeNoBlocksStandalone(alloc)) |nb_responses| {
                        for (nb_responses) |resp| {
                            std.debug.print("BF_SERVE_NOBLOCKS: slot={d} block_no=0 conn={d} bytes={d}\n", .{
                                bf_from_slot, trace.connection_id, resp.len,
                            });
                            mux_bearer.sendSegment(bt, .initiator, blockfetch_server.blockfetch_proto, resp) catch |send_err| {
                                std.debug.print("propagation: blockfetch sendSegment (NoBlocks) error={s}\n", .{@errorName(send_err)});
                                std.debug.print("BF_EARLY_EXIT: reason=send_error conn={d}\n", .{trace.connection_id});
                                break;
                            };
                            alloc.free(resp);
                        }
                        alloc.free(@constCast(nb_responses));
                    } else {
                        std.debug.print("propagation: encodeNoBlocksStandalone failed\n", .{});
                    }
                } else {
                    std.debug.print("BF_EARLY_EXIT: reason=client_done conn={d}\n", .{trace.connection_id});
                }
                continue;
            };
            // BF_LOOKUP — classify the lookup result by response shape:
            //   1 response  -> NoBlocks (point not found in fetchable set)
            //   3 responses -> StartBatch + Block + BatchDone (hit)
            // Only emitted when we actually observed a MsgRequestRange.
            if (bf_request_seen) {
                if (responses.len >= 3) {
                    // Best-effort hash hint from the served sealed tip (BlockFetch
                    // doesn't echo which block was selected; sealed tip is the
                    // common case for relay-pull e2e).
                    const hh: [8]u8 = @bitCast(std.mem.nativeTo(u64, trace.sealed_hash_prefix, .big));
                    std.debug.print("BF_LOOKUP_OK: slot={d} block={d} hash={x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{
                        bf_from_slot, trace.sealed_block_no,
                        hh[0], hh[1], hh[2], hh[3], hh[4], hh[5], hh[6], hh[7],
                    });
                } else {
                    // Inferred reason without changing blockfetch_server.zig: if
                    // the requested slot exceeds sealed.slot it's range_above_sealed;
                    // otherwise the (slot, hash) tuple did not match any fetchable.
                    const reason: []const u8 = if (bf_from_slot > trace.sealed_slot)
                        "range_above_sealed"
                    else
                        "tail_hash_mismatch";
                    std.debug.print("BF_LOOKUP_FAIL: slot={d} block={d} reason={s}\n", .{
                        bf_from_slot, trace.sealed_block_no, reason,
                    });
                }
            }
            // PR-BCAST: in preview_safe, suppress the 3-message Block batch
            // (StartBatch+Block+BatchDone). NoBlocks (1-message miss) still
            // ships so the protocol session stays consistent.
            if (responses.len >= 3 and !isLiveMode()) {
                std.debug.print("PROPAGATION_SUPPRESSED: site=BF_BLOCK slot={d} block={d} reason=preview_safe\n", .{
                    bf_from_slot, trace.sealed_block_no,
                });
                for (responses) |resp| alloc.free(resp);
                alloc.free(@constCast(responses));
                trace.blockfetch_batches_tx_total += 1;
                continue;
            }
            // Send all response messages (StartBatch + Block + BatchDone)
            const bf_names = [_][]const u8{ "StartBatch", "Block", "BatchDone" };
            var bf_send_failed: bool = false;
            for (responses, 0..) |resp, i| {
                const name = if (i < bf_names.len) bf_names[i] else "?";
                std.debug.print("blockfetch: tx {s} len={d} first8={s}\n", .{
                    name, resp.len, fmtFirst8(resp),
                });
                std.debug.print("mux: tx proto={d} dir=1 len={d} first8={s}\n", .{
                    blockfetch_server.blockfetch_proto, resp.len, fmtFirst8(resp),
                });
                // Per-message BF_SERVE_<KIND> emitted IMMEDIATELY before sendSegment.
                // For a serve-hit the response sequence is StartBatch (i=0, kind=HEADER),
                // Block (i=1, kind=BLOCK), BatchDone (i=2, kind=BATCH_DONE); a NoBlocks
                // miss has only the single NoBlocks message (kind=NOBLOCKS).
                if (responses.len >= 3) {
                    if (i == 0) {
                        std.debug.print("BF_SERVE_HEADER: slot={d} block_no={d} conn={d} bytes={d}\n", .{
                            bf_from_slot, trace.sealed_block_no, trace.connection_id, resp.len,
                        });
                        bf_served_header = true;
                    } else if (i == 1) {
                        std.debug.print("BF_SERVE_BLOCK: slot={d} block_no={d} conn={d} bytes={d}\n", .{
                            bf_from_slot, trace.sealed_block_no, trace.connection_id, resp.len,
                        });
                        std.debug.print("PROPAGATION_SEND: site=BF_BLOCK slot={d} block={d} bytes={d}\n", .{
                            bf_from_slot, trace.sealed_block_no, resp.len,
                        });
                        bf_served_block = true;
                    } else if (i == 2) {
                        std.debug.print("BF_SERVE_BATCH_DONE: slot={d} block_no={d} conn={d} bytes={d}\n", .{
                            bf_from_slot, trace.sealed_block_no, trace.connection_id, resp.len,
                        });
                    }
                } else {
                    // 1-response path: MsgNoBlocks fallback (point not found).
                    std.debug.print("BF_SERVE_NOBLOCKS: slot={d} block_no={d} conn={d} bytes={d}\n", .{
                        bf_from_slot, trace.sealed_block_no, trace.connection_id, resp.len,
                    });
                }
                mux_bearer.sendSegment(bt, .initiator, blockfetch_server.blockfetch_proto, resp) catch |err| {
                    std.debug.print("propagation: blockfetch sendSegment error={s}\n", .{@errorName(err)});
                    std.debug.print("BF_EARLY_EXIT: reason=send_error conn={d}\n", .{trace.connection_id});
                    bf_send_failed = true;
                    break;
                };
                alloc.free(resp);
                blockfetch_tx_count += 1;
            }
            alloc.free(@constCast(responses));
            trace.blockfetch_batches_tx_total += 1;
            if (bf_send_failed and bf_request_seen) {
                std.debug.print("BF_SERVE_ABORT: reason=timing_race slot={d} conn={d}\n", .{
                    bf_from_slot, trace.connection_id,
                });
            }
            if (bf_server.?.served_block) {
                served_block.* = true;
                std.debug.print("BF_TX: slot={d} block={d} conn={d}\n", .{
                    trace.sealed_slot, trace.sealed_block_no, trace.connection_id,
                });
            }
            // BlockFetch invariant: if we observed a MsgRequestRange but did not
            // reach BOTH the BF_SERVE_HEADER and BF_SERVE_BLOCK sites, the serve
            // path short-circuited. NoBlocks (1-response path) counts as a
            // violation here because the operator's failure mode is "rx
            // incremented but no header AND block were sent".
            if (bf_request_seen and !(bf_served_header and bf_served_block)) {
                std.debug.print("BF_INVARIANT_VIOLATION: rx incremented but no serve, conn={d}\n", .{trace.connection_id});
            }

        } else if (proto == 4) {
            connection_registry.recordActivity(registry_id, connection_registry.PROTO_TXSUBMISSION);
            // TxSubmission2: propagate-serve is inert on this protocol.
            // The shared txsubmission handler sends MsgRequestTxIds with .responder
            // mux direction (bit 15 = 0), correct when TSUNAGI is TCP initiator
            // (follower mode). But propagate-serve is the TCP listener — outbound
            // messages need .initiator (bit 15 = 1). Sending with the wrong
            // direction bit causes the relay's TxSubmission codec to fail with
            // DeserialiseFailure at SingInit ("unexpected key (0, 3)"), triggering
            // immediate HotToCooling demotion and killing ChainSync/BlockFetch.
            //
            // Fix: consume TxSubmission messages silently. The relay's MsgInit is
            // acknowledged by not crashing the mux bearer. The TxSubmission
            // miniprotocol stalls independently without closing the TCP connection
            // — Cardano N2N miniprotocols are multiplexed and a stalled protocol
            // does not terminate the bearer.
            std.debug.print("dispatch: proto=4 -> txsubmission (inert, consuming silently)\n", .{});

        } else if (proto == keepalive_proto) {
            connection_registry.recordActivity(registry_id, connection_registry.PROTO_KEEPALIVE);
            std.debug.print("dispatch: proto={d} -> keepalive\n", .{proto});
            keepalive.serverHandleMessage(alloc, bt, payload);

        } else if (proto == handshake_proto) {
            // Ignore late handshake messages
            continue;
        } else {
            std.debug.print("propagation: unknown proto {d}, ignoring\n", .{proto});
        }

        // If we've served both header and block, we're done
        if (served_header.* and served_block.*) {
            trace.setExitReason("served_both");
            std.debug.print("propagation: serveMuxLoop exit reason=served_both msg_count={d}\n", .{msg_count});
            break;
        }
        // Header-only mode: after serving header, continue listening for
        // keepalives and further messages but don't block indefinitely
        if (header_only and served_header.*) {
            std.debug.print("propagation: header-only served, continuing mux loop for further messages\n", .{});
        }
    }

    const exit_reason: []const u8 = if (timeout_count >= max_timeouts) "idle_timeout" else "loop_exit";
    // Finalize trace exit state (served_both already set above if applicable)
    if (trace.loop_exit_reason_len == 0) {
        trace.setExitReason(exit_reason);
    }
    trace.msg_count = msg_count;
    trace.served_header = served_header.*;
    trace.served_block = served_block.*;
    trace.fresh_path_complete = fresh_path_complete;
    std.debug.print("propagation: serveMuxLoop exit reason={s} msg_count={d} timeout_count={d} served_header={} served_block={} cs_rx={d} cs_tx={d} bf_rx={d} bf_tx={d} done_received={} last_proto_seen={d} fresh_path_complete={}\n", .{
        exit_reason, msg_count, timeout_count, served_header.*, served_block.*, chainsync_rx_count, chainsync_tx_count, blockfetch_rx_count, blockfetch_tx_count, done_received, last_proto_seen, fresh_path_complete,
    });

    return 0;
}

// ── Server-side handshake ───────────────────────────────────────────

fn doServerHandshake(alloc: std.mem.Allocator, bt: *StreamBt) HandshakeResult {
    // Set 30s read timeout for handshake
    setStreamTimeout(bt, 30_000);

    // Diagnostic: verify socket fd and read-back timeout
    {
        const impl: *StreamBtImpl = @ptrCast(@alignCast(bt.ctx));
        const fd = impl.stream.socket.handle;
        // Read back SO_RCVTIMEO to confirm it was applied
        var tv: std.posix.timeval = undefined;
        var optlen: u32 = @sizeOf(std.posix.timeval);
        const gso_rc = std.posix.system.getsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, @ptrCast(&tv), &optlen);
        if (gso_rc == 0) {
            std.debug.print("handshake: fd={d} SO_RCVTIMEO={d}s\n", .{ fd, tv.sec });
        } else {
            std.debug.print("handshake: fd={d} (getsockopt failed)\n", .{fd});
        }
    }

    // Receive Propose from relay
    const seg = mux_bearer.recvSegment(alloc, bt) catch |err| {
        std.debug.print("handshake: recv error: {s}\n", .{@errorName(err)});
        return .fail;
    };
    if (seg == null) {
        // TCP connect + immediate EOF = probe (e.g. nc -vz), not a real handshake
        std.debug.print("handshake: [probe] TCP connect + EOF before mux segment\n", .{});
        return .probe;
    }
    defer alloc.free(seg.?.payload);

    // Hex dump: first 16 bytes of handshake payload for wire debugging
    var hex_buf: [64]u8 = undefined;
    const hex_n = @min(seg.?.payload.len, 32);
    for (seg.?.payload[0..hex_n], 0..) |b, idx| {
        const hex_chars = "0123456789abcdef";
        hex_buf[idx * 2] = hex_chars[b >> 4];
        hex_buf[idx * 2 + 1] = hex_chars[b & 0x0f];
    }
    std.debug.print("mux: rx proto={d} dir={d} len={d} hex={s}\n", .{
        seg.?.hdr.proto,
        @intFromEnum(seg.?.hdr.dir),
        seg.?.payload.len,
        hex_buf[0 .. hex_n * 2],
    });

    if (seg.?.hdr.proto != handshake_proto) {
        std.debug.print("handshake: [decode] expected proto=0, got proto={d}\n", .{seg.?.hdr.proto});
        return .fail;
    }

    // Guard: reject unreasonably large handshake payloads
    if (seg.?.payload.len > 16384) {
        std.debug.print("handshake: [decode] payload too large: {d}\n", .{seg.?.payload.len});
        return .fail;
    }

    std.debug.print("handshake: decoding {d}-byte Propose...\n", .{seg.?.payload.len});
    var fbs = compat.fixedBufferStream(seg.?.payload);
    var msg = handshake_codec.decodeMsg(alloc, fbs.reader()) catch |err| {
        std.debug.print("handshake: [decode] CBOR decode error: {s}\n", .{@errorName(err)});
        return .fail;
    };
    std.debug.print("handshake: Propose decoded OK\n", .{});
    defer handshake_codec.free(alloc, &msg);

    if (msg != .propose) {
        std.debug.print("handshake: [decode] expected Propose, got different msg type\n", .{});
        return .fail;
    }

    // Check that the peer proposes a version we support with preview magic
    const versions = msg.propose.versions;
    if (versions != .map_u64) {
        std.debug.print("handshake: [version] version map is not map_u64 (got {s})\n", .{@tagName(versions)});
        return .fail;
    }

    // ── Hybrid v14/v15 version selection ─────────────────────────────
    // Step 1: log every offered version with its full VersionData fields,
    // for runtime forensic truth. Step 2: pick the HIGHEST version in
    // [ntn_lowest_supported, ntn_highest_supported] that matches our
    // preview_magic. Step 3: emit explicit "selecting v{N}" log line so
    // operator can see which protocol generation we actually negotiated.
    //
    // Preference for the highest is intentional — V15 adds nothing we
    // can't already serve, and accepting v15 keeps us forward-compatible
    // when peers eventually drop v14. The v14 fallback is preserved: if
    // the peer offers only v14 we accept v14. The proven-stable v14
    // path is the floor, v15 is the ceiling.

    std.debug.print("handshake: peer offered {d} versions\n", .{versions.map_u64.len});
    for (versions.map_u64) |entry| {
        if (entry.value == .array and entry.value.array.len >= 4) {
            const vd = entry.value.array;
            const magic_str: []const u8 = if (vd[0] == .u64) "ok" else "missing";
            const diff_mode: []const u8 = if (vd[1] == .bool) (if (vd[1].bool) "InitiatorOnly" else "InitiatorAndResponder") else "?";
            const peer_share: u64 = if (vd[2] == .u64) vd[2].u64 else 99;
            const query_flag: []const u8 = if (vd[3] == .bool) (if (vd[3].bool) "true" else "false") else "?";
            std.debug.print("handshake: peer offers v{d} [magic={s} diffusionMode={s} peerSharing={d} query={s}]\n", .{
                entry.key, magic_str, diff_mode, peer_share, query_flag,
            });
        } else {
            std.debug.print("handshake: peer offers v{d} [version_data shape unexpected]\n", .{entry.key});
        }
    }

    // Step 2: pick highest compatible
    var accepted_version: ?u64 = null;
    for (versions.map_u64) |entry| {
        if (entry.key < ntn_lowest_supported or entry.key > ntn_highest_supported) continue;
        if (entry.value != .array or entry.value.array.len < 1) continue;
        if (entry.value.array[0] != .u64 or entry.value.array[0].u64 != preview_magic) continue;
        if (accepted_version == null or entry.key > accepted_version.?) {
            accepted_version = entry.key;
        }
    }

    if (accepted_version == null) {
        std.debug.print("handshake: [version] refused (no compatible preview version in {d} entries; supported range [{d},{d}])\n", .{
            versions.map_u64.len, ntn_lowest_supported, ntn_highest_supported,
        });
        const refuse_payload = encodeRefuse(alloc) orelse return .fail;
        defer alloc.free(refuse_payload);
        mux_bearer.sendSegment(bt, .initiator, handshake_proto, refuse_payload) catch {};
        return .fail;
    }

    // Step 3: explicit selection log
    std.debug.print("handshake: selecting v{d} (highest compatible in range [{d},{d}])\n", .{
        accepted_version.?, ntn_lowest_supported, ntn_highest_supported,
    });

    // Send Accept
    std.debug.print("handshake: accepting v{d}\n", .{accepted_version.?});
    const accept_payload = encodeAccept(alloc, accepted_version.?) orelse return .fail;
    defer alloc.free(accept_payload);
    std.debug.print("mux: tx proto=0 dir=1 len={d} first8={s}\n", .{ accept_payload.len, fmtFirst8(accept_payload) });
    mux_bearer.sendSegment(bt, .initiator, handshake_proto, accept_payload) catch return .fail;

    return .ok;
}

fn encodeAccept(alloc: std.mem.Allocator, version: u64) ?[]u8 {
    // Accept = [1, version, version_data]
    // version_data = [magic, initiatorOnlyDiffusionMode, peerSharing, query]
    var vd_items = alloc.alloc(cbor.Term, 4) catch return null;
    vd_items[0] = .{ .u64 = preview_magic };
    vd_items[1] = .{ .bool = false };
    vd_items[2] = .{ .u64 = 0 }; // no peer sharing
    vd_items[3] = .{ .bool = false };
    defer alloc.free(vd_items);

    const accept = handshake_codec.HandshakeMsg{
        .accept = .{
            .version = version,
            .version_data = .{ .array = vd_items },
        },
    };

    var list = std.array_list.Managed(u8).init(alloc);
    handshake_codec.encodeMsg(accept, compat.listWriter(&list)) catch {
        list.deinit();
        return null;
    };
    return list.toOwnedSlice() catch null;
}

fn encodeRefuse(alloc: std.mem.Allocator) ?[]u8 {
    var reason_items = alloc.alloc(cbor.Term, 2) catch return null;
    reason_items[0] = .{ .u64 = 0 }; // version mismatch
    reason_items[1] = .{ .text = "no compatible preview version" };
    defer alloc.free(reason_items);

    const refuse = handshake_codec.HandshakeMsg{
        .refuse = .{ .reason = .{ .array = reason_items } },
    };

    var list = std.array_list.Managed(u8).init(alloc);
    handshake_codec.encodeMsg(refuse, compat.listWriter(&list)) catch {
        list.deinit();
        return null;
    };
    return list.toOwnedSlice() catch null;
}

// ── Receipt writing ─────────────────────────────────────────────────

fn writeReceipt(
    alloc: std.mem.Allocator,
    base_dir: []const u8,
    peer_ip: []const u8,
    sealed: *const SealedArtifact,
    served_header: bool,
    served_block: bool,
    tip_before: []const u8,
    tip_after: []const u8,
    no_inject_ok: bool,
) void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/propagation_receipt.json", .{base_dir}) catch return;

    var f = compat.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer f.close();
    const w = f.deprecatedWriter();

    const hash_hex = std.fmt.bytesToHex(sealed.header_hash, .lower);

    w.print("{{", .{}) catch return;
    w.print("\"peer_ip\":\"{s}\",", .{peer_ip}) catch return;
    w.print("\"served_slot\":{d},", .{sealed.slot}) catch return;
    w.print("\"served_header_hash_hex\":\"{s}\",", .{@as([]const u8, &hash_hex)}) catch return;
    _ = alloc;
    w.print("\"artifact_dir\":\"sealed\",", .{}) catch return;
    w.print("\"served_header\":{s},", .{if (served_header) "true" else "false"}) catch return;
    w.print("\"served_block\":{s},", .{if (served_block) "true" else "false"}) catch return;
    w.print("\"tip_before\":\"{s}\",", .{tip_before}) catch return;
    w.print("\"tip_after\":\"{s}\",", .{tip_after}) catch return;
    w.print("\"no_inject_ok\":{s}", .{if (no_inject_ok) "true" else "false"}) catch return;
    w.print("}}\n", .{}) catch return;

    std.debug.print("propagation: receipt written to {s}\n", .{path});
}

fn writeAcceptanceReceipt(
    base_dir: []const u8,
    peer_ip: []const u8,
    trace: *const AcceptanceTrace,
) void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/acceptance_receipt.json", .{base_dir}) catch return;

    var f = compat.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer f.close();
    const w = f.deprecatedWriter();

    // Hash prefix as hex string
    var hex_buf: [16]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    const prefix_bytes: [8]u8 = @bitCast(std.mem.nativeTo(u64, trace.sealed_hash_prefix, .big));
    for (prefix_bytes, 0..) |b, idx| {
        hex_buf[idx * 2] = hex_chars[b >> 4];
        hex_buf[idx * 2 + 1] = hex_chars[b & 0x0f];
    }

    const b = struct {
        fn boolStr(v: bool) []const u8 {
            return if (v) "true" else "false";
        }
    }.boolStr;

    w.print("{{", .{}) catch return;
    w.print("\"connection_id\":{d},", .{trace.connection_id}) catch return;
    w.print("\"peer_ip\":\"{s}\",", .{peer_ip}) catch return;
    w.print("\"accepted_unix\":{d},", .{trace.accepted_unix}) catch return;
    w.print("\"handshake_ok\":{s},", .{b(trace.handshake_ok)}) catch return;
    w.print("\"artifact_gen\":{d},", .{trace.artifact_gen}) catch return;
    w.print("\"sealed_slot\":{d},", .{trace.sealed_slot}) catch return;
    w.print("\"sealed_block_no\":{d},", .{trace.sealed_block_no}) catch return;
    w.print("\"sealed_hash_prefix\":\"{s}\",", .{@as([]const u8, &hex_buf)}) catch return;
    w.print("\"fragment_depth\":{d},", .{trace.fragment_depth}) catch return;
    w.print("\"intersect_result_found\":{s},", .{b(trace.intersect_result_found)}) catch return;
    w.print("\"intersect_method\":\"{s}\",", .{trace.methodStr()}) catch return;
    w.print("\"chosen_index\":{d},", .{trace.chosen_index}) catch return;
    w.print("\"chosen_slot\":{d},", .{trace.chosen_slot}) catch return;
    w.print("\"relay_newest_slot\":{d},", .{trace.relay_newest_slot}) catch return;
    w.print("\"relay_ahead\":{s},", .{b(trace.relay_ahead)}) catch return;
    w.print("\"tsunagi_ahead\":{s},", .{b(trace.tsunagi_ahead)}) catch return;
    w.print("\"equal_tip\":{s},", .{b(trace.equal_tip)}) catch return;
    w.print("\"need_rollback_initial\":{s},", .{b(trace.need_rollback_initial)}) catch return;
    w.print("\"msg_request_next_rx_total\":{d},", .{trace.msg_request_next_rx_total}) catch return;
    w.print("\"rollback_tx_total\":{d},", .{trace.rollback_tx_total}) catch return;
    w.print("\"rollforward_fragment_tx_total\":{d},", .{trace.rollforward_fragment_tx_total}) catch return;
    w.print("\"rollforward_sealed_tx_total\":{d},", .{trace.rollforward_sealed_tx_total}) catch return;
    w.print("\"awaitreply_tx_total\":{d},", .{trace.awaitreply_tx_total}) catch return;
    w.print("\"blockfetch_rx_total\":{d},", .{trace.blockfetch_rx_total}) catch return;
    w.print("\"blockfetch_batches_tx_total\":{d},", .{trace.blockfetch_batches_tx_total}) catch return;
    w.print("\"blockfetch_last_start_slot\":{d},", .{trace.blockfetch_last_start_slot}) catch return;
    w.print("\"blockfetch_last_end_slot\":{d},", .{trace.blockfetch_last_end_slot}) catch return;
    w.print("\"served_header\":{s},", .{b(trace.served_header)}) catch return;
    w.print("\"served_block\":{s},", .{b(trace.served_block)}) catch return;
    w.print("\"fresh_path_complete\":{s},", .{b(trace.fresh_path_complete)}) catch return;
    w.print("\"loop_exit_reason\":\"{s}\",", .{trace.exitReasonStr()}) catch return;
    w.print("\"msg_count\":{d}", .{trace.msg_count}) catch return;
    w.print("}}\n", .{}) catch return;

    std.debug.print("propagation: acceptance receipt written to {s}\n", .{path});
}

// ── Hex dump helper ─────────────────────────────────────────────────

/// Extract ChainSync message name from encoded CBOR response.
/// Reads the second byte (first item of outer array) to determine the tag.
fn csaMsgName(data: []const u8) []const u8 {
    if (data.len < 2) return "?";
    const tag = data[1]; // first element of CBOR array (small uint)
    return switch (tag) {
        1 => "AwaitReply",
        2 => "RollForward",
        3 => "RollBackward",
        5 => "IntersectFound",
        6 => "IntersectNotFound",
        else => "?",
    };
}

fn fmtFirst8(data: []const u8) []const u8 {
    if (data.len == 0) return "()";
    const hex_chars = "0123456789abcdef";
    const S = struct {
        var buf: [16]u8 = undefined;
    };
    var pos: usize = 0;
    for (data[0..@min(data.len, 8)]) |b| {
        if (pos + 1 >= S.buf.len) break;
        S.buf[pos] = hex_chars[b >> 4];
        S.buf[pos + 1] = hex_chars[b & 0x0f];
        pos += 2;
    }
    return S.buf[0..pos];
}

fn fmtFirst16(data: []const u8) []const u8 {
    if (data.len == 0) return "()";
    const hex_chars = "0123456789abcdef";
    const S = struct {
        var buf: [32]u8 = undefined;
    };
    var pos: usize = 0;
    for (data[0..@min(data.len, 16)]) |b| {
        if (pos + 1 >= S.buf.len) break;
        S.buf[pos] = hex_chars[b >> 4];
        S.buf[pos + 1] = hex_chars[b & 0x0f];
        pos += 2;
    }
    return S.buf[0..pos];
}

// ── Stream → ByteTransport adapter ─────────────────────────────────

const StreamBt = @import("transport/byte_transport.zig").ByteTransport;

const StreamBtImpl = struct {
    stream: compat.NetStream,

    fn writeAll(ctx: *anyopaque, data: []const u8) anyerror!void {
        const self: *StreamBtImpl = @ptrCast(@alignCast(ctx));
        // 0.16 net.Stream has no direct writeAll; operate on the raw fd to
        // preserve exact byte semantics (and the SO_RCVTIMEO/WouldBlock
        // behavior used by readAtMost). writev-style short writes loop until
        // all bytes are flushed, matching the prior writeAll contract.
        var off: usize = 0;
        while (off < data.len) {
            const n = try compat.posixWrite(self.stream.socket.handle, data[off..]);
            if (n == 0) return error.ConnectionResetByPeer;
            off += n;
        }
    }

    fn readAtMost(ctx: *anyopaque, out: []u8) anyerror!usize {
        const self: *StreamBtImpl = @ptrCast(@alignCast(ctx));
        // Raw read on the fd preserves the SO_RCVTIMEO timeout path: EAGAIN
        // surfaces as error.WouldBlock, mapped to error.TimedOut as before.
        return std.posix.read(self.stream.socket.handle, out) catch |err| switch (err) {
            error.WouldBlock => return error.TimedOut,
            else => return err,
        };
    }

    fn deinit(_: *anyopaque) void {}

    const vtable = @import("transport/byte_transport.zig").ByteTransportVTable{
        .writeAll = writeAll,
        .readAtMost = readAtMost,
        .deinit = deinit,
    };
};

fn streamToBt(stream: compat.NetStream) StreamBt {
    // Use a static impl — single connection, lifetime managed externally
    const S = struct {
        var impl: StreamBtImpl = undefined;
    };
    S.impl = .{ .stream = stream };
    return .{
        .ctx = @ptrCast(&S.impl),
        .vtable = &StreamBtImpl.vtable,
    };
}

fn setStreamTimeout(bt: *StreamBt, timeout_ms: u32) void {
    const impl: *StreamBtImpl = @ptrCast(@alignCast(bt.ctx));
    var tv = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    std.posix.setsockopt(
        impl.stream.socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&tv),
    ) catch {};
}

// ── Snapshot lifecycle tests ────────────────────────────────────────

const test_dir = "/tmp/tsunagi-test-snapshot";

fn setupTestDir() void {
    // Remove and recreate clean test directory
    compat.fs.cwd().deleteTree(test_dir) catch {};
    compat.fs.cwd().makePath(test_dir) catch {};
}

fn writeTestFile(name: []const u8, content: []const u8) void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ test_dir, name }) catch return;
    var f = compat.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer f.close();
    f.writeAll(content) catch {};
}

test "artifactChanged detects slot change" {
    const alloc = std.testing.allocator;
    setupTestDir();
    defer compat.fs.cwd().deleteTree(test_dir) catch {};

    // Write initial meta.json + block_header_hash.hex
    writeTestFile("meta.json", "{\"slot\": 100, \"block_no\": 50}");
    writeTestFile("block_header_hash.hex", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n");

    // Create a snapshot with those values
    var snap = ArtifactSnapshot{
        .sealed = .{
            .slot = 100,
            .block_no = 50,
            .header_hash = undefined,
            .header_cbor = &[_]u8{},
            .block_cbor = null,
        },
        .fragment = &[_]chainsync_server.FragmentEntry{},
        .generation = 0,
        .prev_hash = [_]u8{0} ** 32,
        .has_prev_hash = false,
    };
    // Set header_hash to match the hex file
    _ = parseHexToHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", &snap.sealed.header_hash);

    // Same files → not changed
    try std.testing.expect(!artifactChanged(alloc, test_dir, &snap));

    // Change slot in meta.json
    writeTestFile("meta.json", "{\"slot\": 200, \"block_no\": 50}");
    try std.testing.expect(artifactChanged(alloc, test_dir, &snap));
}

test "artifactChanged returns false when unchanged" {
    const alloc = std.testing.allocator;
    setupTestDir();
    defer compat.fs.cwd().deleteTree(test_dir) catch {};

    writeTestFile("meta.json", "{\"slot\": 500, \"block_no\": 99}");
    writeTestFile("block_header_hash.hex", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n");

    var snap = ArtifactSnapshot{
        .sealed = .{
            .slot = 500,
            .block_no = 99,
            .header_hash = undefined,
            .header_cbor = &[_]u8{},
            .block_cbor = null,
        },
        .fragment = &[_]chainsync_server.FragmentEntry{},
        .generation = 0,
        .prev_hash = [_]u8{0} ** 32,
        .has_prev_hash = false,
    };
    _ = parseHexToHash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", &snap.sealed.header_hash);

    // Exact match → not changed
    try std.testing.expect(!artifactChanged(alloc, test_dir, &snap));

    // Call again → still not changed
    try std.testing.expect(!artifactChanged(alloc, test_dir, &snap));
}

test "loadArtifactSnapshot returns null on missing files" {
    const alloc = std.testing.allocator;
    setupTestDir();
    defer compat.fs.cwd().deleteTree(test_dir) catch {};

    // Empty directory → loadArtifactSnapshot should return null
    const result = loadArtifactSnapshot(alloc, test_dir, 0);
    try std.testing.expect(result == null);
}

// ── Artifact coherence tests ──────────────────────────────────────────

/// Build a minimal valid header CBOR: [[block_no, slot, prev_hash, ...padding], kes_sig]
/// parseHeaderFields expects array[0]=array(body), body[0]=block_no, body[1]=slot, body[2]=prev_hash
fn buildTestHeaderCbor(buf: []u8, block_no: u64, slot: u64, prev_hash: [32]u8) []u8 {
    var pos: usize = 0;
    // Outer array(2): [header_body, kes_sig]
    buf[pos] = 0x82;
    pos += 1;
    // header_body: array(3) [block_no, slot, prev_hash_bytes]
    buf[pos] = 0x83;
    pos += 1;
    // block_no (u64)
    pos += cborWriteU64(buf[pos..], block_no);
    // slot (u64)
    pos += cborWriteU64(buf[pos..], slot);
    // prev_hash (bytes32)
    buf[pos] = 0x58;
    pos += 1;
    buf[pos] = 32;
    pos += 1;
    @memcpy(buf[pos .. pos + 32], &prev_hash);
    pos += 32;
    // kes_sig: empty bytes
    buf[pos] = 0x40;
    pos += 1;
    return buf[0..pos];
}

fn cborWriteU64(buf: []u8, val: u64) usize {
    if (val < 24) {
        buf[0] = @intCast(val);
        return 1;
    } else if (val <= 0xFF) {
        buf[0] = 0x18;
        buf[1] = @intCast(val);
        return 2;
    } else if (val <= 0xFFFF) {
        buf[0] = 0x19;
        std.mem.writeInt(u16, buf[1..3], @intCast(val), .big);
        return 3;
    } else if (val <= 0xFFFFFFFF) {
        buf[0] = 0x1a;
        std.mem.writeInt(u32, buf[1..5], @intCast(val), .big);
        return 5;
    } else {
        buf[0] = 0x1b;
        std.mem.writeInt(u64, buf[1..9], val, .big);
        return 9;
    }
}

fn writeTestFragmentEntry(seq: u32, slot: u64, block_no: u64, hash: [32]u8, prev_hash: [32]u8) void {
    var seq_buf: [8]u8 = undefined;
    const seq_str = std.fmt.bufPrint(&seq_buf, "{d:0>8}", .{seq}) catch return;

    // header.cbor
    var hdr_buf: [128]u8 = undefined;
    const hdr = buildTestHeaderCbor(&hdr_buf, block_no, slot, prev_hash);
    var hdr_name_buf: [64]u8 = undefined;
    const hdr_name = std.fmt.bufPrint(&hdr_name_buf, "fragment/{s}.header.cbor", .{seq_str}) catch return;
    writeTestFile(hdr_name, hdr);

    // hash.hex
    const hash_hex = std.fmt.bytesToHex(hash, .lower);
    var hash_name_buf: [64]u8 = undefined;
    const hash_name = std.fmt.bufPrint(&hash_name_buf, "fragment/{s}.hash.hex", .{seq_str}) catch return;
    writeTestFile(hash_name, &hash_hex);

    // prev_hash.hex
    const prev_hex = std.fmt.bytesToHex(prev_hash, .lower);
    var prev_name_buf: [64]u8 = undefined;
    const prev_name = std.fmt.bufPrint(&prev_name_buf, "fragment/{s}.prev_hash.hex", .{seq_str}) catch return;
    writeTestFile(prev_name, &prev_hex);

    // meta.json
    var meta_buf: [128]u8 = undefined;
    const meta = std.fmt.bufPrint(&meta_buf, "{{\"slot\":{d},\"block_no\":{d}}}", .{ slot, block_no }) catch return;
    var meta_name_buf: [64]u8 = undefined;
    const meta_name = std.fmt.bufPrint(&meta_name_buf, "fragment/{s}.meta.json", .{seq_str}) catch return;
    writeTestFile(meta_name, meta);
}

fn makeTestHash(seed: u8) [32]u8 {
    var h: [32]u8 = undefined;
    @memset(&h, seed);
    return h;
}

test "artifact coherence: stale fragment + newer sealed = incoherent (dropped)" {
    const alloc = std.testing.allocator;
    setupTestDir();
    defer compat.fs.cwd().deleteTree(test_dir) catch {};

    // Fragment: entries with hashes AA, BB chaining
    const hash_aa = makeTestHash(0xAA);
    const hash_bb = makeTestHash(0xBB);
    const hash_cc = makeTestHash(0xCC); // sealed parent

    compat.fs.cwd().makePath(test_dir ++ "/fragment") catch {};
    // Entry 0: prev=AA, hash=BB
    writeTestFragmentEntry(0, 100, 10, hash_bb, hash_aa);

    // Sealed block: parent=CC (NOT BB), so fragment tail doesn't match
    var hdr_buf: [128]u8 = undefined;
    const hdr = buildTestHeaderCbor(&hdr_buf, 12, 300, hash_cc);
    writeTestFile("block_header.cbor", hdr);
    writeTestFile("meta.json", "{\"slot\":300,\"block_no\":12}");
    // Stored hash MUST equal Blake2b256(header_cbor) — self-verify gate.
    var sealed_real_hash: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(hdr, &sealed_real_hash, .{});
    const sealed_hex = std.fmt.bytesToHex(sealed_real_hash, .lower);
    writeTestFile("block_header_hash.hex", &sealed_hex);

    // Two-phase publication: producer writes the `.ready` sentinel LAST, after
    // both the sealed-block files and the fragment ancestry are fully on disk.
    // loadArtifactSnapshotEx refuses to load any artifact until it is present
    // (see the guard at the top of that fn). Emulate a fully-published artifact.
    writeTestFile(".ready", "");

    const result = loadArtifactSnapshot(alloc, test_dir, 0);
    try std.testing.expect(result != null);
    var snap = result.?;
    defer freeArtifactSnapshot(alloc, &snap);

    // Fragment should be dropped (incoherent) → single-header mode
    try std.testing.expect(snap.fragment.len == 0);
    try std.testing.expect(snap.sealed.slot == 300);
}

test "artifact coherence: matching fragment tail = coherent" {
    const alloc = std.testing.allocator;
    setupTestDir();
    defer compat.fs.cwd().deleteTree(test_dir) catch {};

    const hash_aa = makeTestHash(0xAA);
    const hash_bb = makeTestHash(0xBB);

    compat.fs.cwd().makePath(test_dir ++ "/fragment") catch {};
    // Entry 0: prev=AA, hash=BB (tail)
    writeTestFragmentEntry(0, 100, 10, hash_bb, hash_aa);

    // Sealed block: parent=BB (matches fragment tail)
    var hdr_buf: [128]u8 = undefined;
    const hdr = buildTestHeaderCbor(&hdr_buf, 11, 200, hash_bb);
    writeTestFile("block_header.cbor", hdr);
    writeTestFile("meta.json", "{\"slot\":200,\"block_no\":11}");
    // Stored hash MUST equal Blake2b256(header_cbor) — self-verify gate.
    var sealed_real_hash: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(hdr, &sealed_real_hash, .{});
    const sealed_hex = std.fmt.bytesToHex(sealed_real_hash, .lower);
    writeTestFile("block_header_hash.hex", &sealed_hex);

    // Two-phase publication sentinel (written LAST). See loadArtifactSnapshotEx.
    writeTestFile(".ready", "");

    const result = loadArtifactSnapshot(alloc, test_dir, 0);
    try std.testing.expect(result != null);
    var snap = result.?;
    defer freeArtifactSnapshot(alloc, &snap);

    // Fragment preserved (coherent)
    try std.testing.expect(snap.fragment.len == 1);
    try std.testing.expect(snap.sealed.slot == 200);
    try std.testing.expect(snap.sealed.block_no == 11);
}

test "artifact coherence: no fragment = single-header mode (coherent)" {
    const alloc = std.testing.allocator;
    setupTestDir();
    defer compat.fs.cwd().deleteTree(test_dir) catch {};

    const hash_cc = makeTestHash(0xCC);

    // Sealed only, no fragment/ directory
    var hdr_buf: [128]u8 = undefined;
    const hdr = buildTestHeaderCbor(&hdr_buf, 50, 5000, hash_cc);
    writeTestFile("block_header.cbor", hdr);
    writeTestFile("meta.json", "{\"slot\":5000,\"block_no\":50}");
    // Stored hash MUST equal Blake2b256(header_cbor) — self-verify gate.
    var sealed_real_hash: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(hdr, &sealed_real_hash, .{});
    const sealed_hex = std.fmt.bytesToHex(sealed_real_hash, .lower);
    writeTestFile("block_header_hash.hex", &sealed_hex);

    // Two-phase publication sentinel (written LAST). See loadArtifactSnapshotEx.
    writeTestFile(".ready", "");

    const result = loadArtifactSnapshot(alloc, test_dir, 0);
    try std.testing.expect(result != null);
    var snap = result.?;
    defer freeArtifactSnapshot(alloc, &snap);

    // No fragment → coherent in single-header mode
    try std.testing.expect(snap.fragment.len == 0);
    try std.testing.expect(snap.sealed.slot == 5000);
}

test "artifact coherence: multi-entry fragment + matching sealed" {
    const alloc = std.testing.allocator;
    setupTestDir();
    defer compat.fs.cwd().deleteTree(test_dir) catch {};

    const hash_a = makeTestHash(0x01);
    const hash_b = makeTestHash(0x02);
    const hash_c = makeTestHash(0x03);

    compat.fs.cwd().makePath(test_dir ++ "/fragment") catch {};
    // Entry 0: prev=A, hash=B
    writeTestFragmentEntry(0, 100, 10, hash_b, hash_a);
    // Entry 1: prev=B, hash=C (tail)
    writeTestFragmentEntry(1, 200, 11, hash_c, hash_b);

    // Sealed: parent=C (matches fragment tail)
    var hdr_buf: [128]u8 = undefined;
    const hdr = buildTestHeaderCbor(&hdr_buf, 12, 300, hash_c);
    writeTestFile("block_header.cbor", hdr);
    writeTestFile("meta.json", "{\"slot\":300,\"block_no\":12}");
    // Stored hash MUST equal Blake2b256(header_cbor) — self-verify gate.
    var sealed_real_hash: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(hdr, &sealed_real_hash, .{});
    const sealed_hex = std.fmt.bytesToHex(sealed_real_hash, .lower);
    writeTestFile("block_header_hash.hex", &sealed_hex);

    // Two-phase publication sentinel (written LAST). See loadArtifactSnapshotEx.
    writeTestFile(".ready", "");

    const result = loadArtifactSnapshot(alloc, test_dir, 0);
    try std.testing.expect(result != null);
    var snap = result.?;
    defer freeArtifactSnapshot(alloc, &snap);

    // Fragment coherent, 2 entries preserved
    try std.testing.expect(snap.fragment.len == 2);
    try std.testing.expect(snap.sealed.slot == 300);
}

test "loadSealedArtifact rejects when stored hash mismatches Blake2b256(header_cbor)" {
    const alloc = std.testing.allocator;
    setupTestDir();
    defer compat.fs.cwd().deleteTree(test_dir) catch {};

    // Write a real header CBOR.
    const parent_hash = makeTestHash(0x11);
    var hdr_buf: [128]u8 = undefined;
    const hdr = buildTestHeaderCbor(&hdr_buf, 7, 700, parent_hash);
    writeTestFile("block_header.cbor", hdr);
    writeTestFile("meta.json", "{\"slot\":700,\"block_no\":7}");

    // Deliberately write a hash that does NOT match Blake2b256(hdr).
    const wrong_hash = makeTestHash(0xEE);
    const wrong_hex = std.fmt.bytesToHex(wrong_hash, .lower);
    writeTestFile("block_header_hash.hex", &wrong_hex);

    // Sanity: confirm the fixture really is a mismatch.
    var actual_hash: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(hdr, &actual_hash, .{});
    try std.testing.expect(!std.mem.eql(u8, &actual_hash, &wrong_hash));

    // loadSealedArtifact must refuse to load the artifact.
    const result = loadSealedArtifact(alloc, test_dir);
    try std.testing.expect(result == null);
}

test "loadSealedArtifact accepts when stored hash matches Blake2b256(header_cbor)" {
    const alloc = std.testing.allocator;
    setupTestDir();
    defer compat.fs.cwd().deleteTree(test_dir) catch {};

    const parent_hash = makeTestHash(0x22);
    var hdr_buf: [128]u8 = undefined;
    const hdr = buildTestHeaderCbor(&hdr_buf, 8, 800, parent_hash);
    writeTestFile("block_header.cbor", hdr);
    writeTestFile("meta.json", "{\"slot\":800,\"block_no\":8}");

    // Write the correct hash.
    var real_hash: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(hdr, &real_hash, .{});
    const real_hex = std.fmt.bytesToHex(real_hash, .lower);
    writeTestFile("block_header_hash.hex", &real_hex);

    var sealed = loadSealedArtifact(alloc, test_dir) orelse return error.TestUnexpectedNull;
    defer alloc.free(sealed.header_cbor);
    defer if (sealed.block_cbor) |bc| alloc.free(bc);

    try std.testing.expect(sealed.slot == 800);
    try std.testing.expect(sealed.block_no == 8);
    try std.testing.expect(std.mem.eql(u8, &sealed.header_hash, &real_hash));
}
