const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zig 0.16 migration: shared compat shim, importable everywhere as
    // `@import("compat")`. link_libc so its libc-backed env access resolves.
    const compat_mod = b.createModule(.{
        .root_source_file = b.path("src/compat.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Build options for version stamping (reproducible: no timestamp by default)
    const version = b.option([]const u8, "version", "Version tag (e.g. v2.4.0)") orelse "dev";
    const commit = b.option([]const u8, "commit", "Git commit hash") orelse "unknown";
    const optimize_str: []const u8 = switch (optimize) {
        .Debug => "Debug",
        .ReleaseSafe => "ReleaseSafe",
        .ReleaseFast => "ReleaseFast",
        .ReleaseSmall => "ReleaseSmall",
    };

    // v4.2.0: extended build identity options (Layer A reproducibility)
    const git_tag = b.option([]const u8, "tsunagi_git_tag", "Git tag (e.g. v4.2.0)") orelse "untagged";
    const source_dirty = b.option(bool, "tsunagi_source_dirty", "true if worktree has uncommitted changes") orelse false;
    const build_epoch = b.option(u64, "tsunagi_build_epoch", "Controlled build timestamp (unix seconds, 0=absent)") orelse 0;

    // Derive target triple from resolved target
    const target_triple = blk: {
        const t = target.result;
        break :blk b.fmt("{s}-{s}-{s}", .{
            @tagName(t.cpu.arch),
            @tagName(t.os.tag),
            if (t.abi != .none) @tagName(t.abi) else "none",
        });
    };

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "commit", commit);
    options.addOption([]const u8, "optimize", optimize_str);
    options.addOption([]const u8, "git_tag", git_tag);
    options.addOption(bool, "source_dirty", source_dirty);
    options.addOption(u64, "build_epoch", build_epoch);
    options.addOption([]const u8, "target_triple", target_triple);
    options.addOption([]const u8, "zig_version", b.fmt("{any}", .{@import("builtin").zig_version}));

    const exe = b.addExecutable(.{
        .name = "tsunagi-node",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    exe.root_module.link_libc = true; // zig 0.16: linkLibC() moved to module field
    exe.root_module.linkSystemLibrary("lmdb", .{});
    exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
    exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
    exe.root_module.linkSystemLibrary("sodium", .{});
    b.installArtifact(exe);

    // Standalone external evaluator binary (protocol v1, no libc/LMDB/sodium)
    const eval_exe = b.addExecutable(.{
        .name = "plutus-evaluator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/plutus-evaluator.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(eval_exe);

    // Praos bit-equivalence harness — standalone diagnostic binary.
    // Reads CLI inputs (slot, epoch_nonce, sigma, asc, vrf_skey), computes
    // TSUNAGI's exact Praos leader path stage-by-stage, prints every byte.
    // Read-only relative to runtime: no live state mutation, no broadcast,
    // no file writes. Imports the same sodium_vrf and praos_threshold_e34
    // modules as the runtime via named-module imports (Zig 0.15.2 module
    // path restriction prevents `..` traversal from src/tools/).
    const sodium_vrf_mod = b.createModule(.{
        .root_source_file = b.path("src/producer/crypto/sodium_vrf.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sodium_vrf_mod.linkSystemLibrary("sodium", .{});
    sodium_vrf_mod.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
    sodium_vrf_mod.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });

    const praos_e34_mod = b.createModule(.{
        .root_source_file = b.path("src/producer/crypto/praos_threshold_e34.zig"),
        .target = target,
        .optimize = optimize,
    });

    const praos_verify_root = b.createModule(.{
        .root_source_file = b.path("src/tools/praos_verify.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    praos_verify_root.addImport("sodium_vrf", sodium_vrf_mod);
    praos_verify_root.addImport("praos_e34", praos_e34_mod);
    praos_verify_root.linkSystemLibrary("sodium", .{});
    praos_verify_root.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
    praos_verify_root.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });

    const praos_verify = b.addExecutable(.{
        .name = "praos-verify",
        .root_module = praos_verify_root,
    });
    const praos_verify_install = b.addInstallArtifact(praos_verify, .{});
    b.getInstallStep().dependOn(&praos_verify_install.step);
    const praos_verify_step = b.step("praos-verify", "Build the Praos bit-equivalence harness");
    praos_verify_step.dependOn(&praos_verify_install.step);

    // Phase B'''': standalone slot_index reset utility (rollback recovery).
    // Operationally separable from the runtime — the operator stops the
    // post-fix binary, runs this against the LMDB env to clear sentinel
    // and empty slot_index, then restarts the pre-fix binary which boots
    // without the sentinel and treats slot_index as un-migrated.
    const slot_index_reset_root = b.createModule(.{
        .root_source_file = b.path("src/tools/slot_index_reset.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    slot_index_reset_root.linkSystemLibrary("lmdb", .{});
    slot_index_reset_root.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
    slot_index_reset_root.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
    const slot_index_reset = b.addExecutable(.{
        .name = "tsunagi-slot-index-reset",
        .root_module = slot_index_reset_root,
    });
    const slot_index_reset_install = b.addInstallArtifact(slot_index_reset, .{});
    b.getInstallStep().dependOn(&slot_index_reset_install.step);
    const slot_index_reset_step = b.step("slot-index-reset", "Build standalone slot_index reset utility");
    slot_index_reset_step.dependOn(&slot_index_reset_install.step);

    // `zig build run -- [args...]`
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run TSUNAGI Node");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` runs all test roots.
    const test_step = b.step("test", "Run TSUNAGI Node tests");

    const protocol_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protocol_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(protocol_tests).step);

    const byte_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/byte_transport_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(byte_tests).step);

    // NET-RUNTIME AUDIT regression: fragmented socket-read reassembly through
    // the real mux_bearer.recvSegment serve-loop read path (blockfetch_server +
    // propagation_server). Proves length-prefixed messages reassemble with no
    // loss when delivered in 1-byte / split chunks (kernel read(2) semantics).
    const serve_loop_fragmented_read_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/serve_loop_fragmented_read_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(serve_loop_fragmented_read_tests).step);

    // Concurrency proof for the compat shim's global Io routing: many real OS
    // threads hammering compat fs/time/Mutex concurrently through
    // std.Io.Threaded.global_single_threaded.io(). Links libc (compat env path).
    const compat_concurrency_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compat_concurrency_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    compat_concurrency_tests.root_module.link_libc = true;
    test_step.dependOn(&b.addRunArtifact(compat_concurrency_tests).step);

    const framing_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/framing_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(framing_tests).step);

    const mux_framing_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mux_framing_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(mux_framing_tests).step);

    // NET-RUNTIME AUDIT: fragmented-stream reassembly for the length-prefix
    // framing path (net/mux.zig Mux.recv) — companion to
    // serve_loop_fragmented_read_tests (the mux_bearer.recvSegment path).
    const mux_fragment_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mux_fragment_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(mux_fragment_tests).step);

    const handshake_codec_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/handshake_codec_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(handshake_codec_tests).step);

    const muxwire_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/muxwire_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(muxwire_tests).step);

    const chainsync_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/chainsync_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(chainsync_tests).step);

    // Acceptance-frontier reproduction (slot 114191515, epoch 1321): the
    // cross-domain applied-tip write that forces FORGE_REFUSE_STALE_PARENT.
    const acceptance_frontier_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/acceptance_frontier_parent_select_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(acceptance_frontier_tests).step);

    // NET-RUNTIME: fragmented-stream reassembly over the ntc/transport read
    // path (persistent StreamProtoReader). Proves no byte loss when a
    // length-prefixed mux segment arrives 1 byte at a time / in split chunks.
    const ntc_fragmented_read_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ntc_fragmented_read_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ntc_fragmented_read_tests.root_module.link_libc = true;
    test_step.dependOn(&b.addRunArtifact(ntc_fragmented_read_tests).step);

    const txsubmission_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/txsubmission_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(txsubmission_tests).step);

    // block_hash_tests: Zig 0.15.2 module path restriction — block_hash.zig imports
    // ../cbor/ which is outside its module path. Tests are covered by ledger_tests.zig.

    const ancestry_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/net/ledger/ancestry.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(ancestry_tests).step);

    const tx_decoder_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tx_decoder_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(tx_decoder_tests).step);

    const mempool_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mempool_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(mempool_tests).step);

    const consensus_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/consensus_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    consensus_tests.root_module.linkSystemLibrary("sodium", .{});
    consensus_tests.root_module.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
    consensus_tests.root_module.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
    test_step.dependOn(&b.addRunArtifact(consensus_tests).step);

    const producer_kes_heartbeat_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/producer_kes_heartbeat_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    producer_kes_heartbeat_tests.root_module.linkSystemLibrary("sodium", .{});
    producer_kes_heartbeat_tests.root_module.linkSystemLibrary("lmdb", .{});
    producer_kes_heartbeat_tests.root_module.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
    producer_kes_heartbeat_tests.root_module.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
    test_step.dependOn(&b.addRunArtifact(producer_kes_heartbeat_tests).step);

    const nonce_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/producer/nonce_evolution.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(nonce_tests).step);

    const resources_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/producer/resources.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(resources_tests).step);

    const lsq_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lsq_pool_params_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(lsq_tests).step);

    const status_fallback_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/net/metrics/status_fallback.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(status_fallback_tests).step);

    const pool_stats_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pool_stats_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    pool_stats_tests.root_module.linkSystemLibrary("lmdb", .{});
    pool_stats_tests.root_module.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
    pool_stats_tests.root_module.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
    test_step.dependOn(&b.addRunArtifact(pool_stats_tests).step);

    // stake_state tests: covered by ledger_tests.zig (module path restriction)

    const network_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/network_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(network_tests).step);

    const connection_registry_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/net/connection_registry.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(connection_registry_tests).step);

    const propagation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/propagation_server_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(propagation_tests).step);

    const bf_repro_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/propagation_server_bf_repro_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(bf_repro_tests).step);

    const archive_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/archive_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(archive_tests).step);

    const guardian_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/guardian_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(guardian_tests).step);

    const utxo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/utxo_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(utxo_tests).step);

    const kagami_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kagami_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    kagami_tests.root_module.linkSystemLibrary("lmdb", .{});
    kagami_tests.root_module.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
    kagami_tests.root_module.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
    test_step.dependOn(&b.addRunArtifact(kagami_tests).step);

    const health_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/health_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(health_tests).step);

    const ledger_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ledger_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    ledger_tests.root_module.linkSystemLibrary("lmdb", .{});
    ledger_tests.root_module.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
    ledger_tests.root_module.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
    test_step.dependOn(&b.addRunArtifact(ledger_tests).step);

    // CLI view tests: cover the unified renderer + input + stability
    // helpers (#148 / #149 / #150 / #151) — isExitKey, padRight,
    // fmtOrDash, light* helpers, shouldSkipPaint, composeIncrementalPaint,
    // and the minimal-status renderPanel that exercises every em-dash
    // path. Pure CLI module: no libsodium / lmdb / libc linkage needed.
    const view_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/view.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(view_tests).step);

    // Remediation integration tests: stake_source σ snapshot, σ-drift gate,
    // nonce-currency gate, orphan watchdog state machine, and acceptance
    // tracker. Self-contained — only stake_source is a real-module import;
    // the remaining modules are mocked at file level (still developing).
    const remediation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_remediation_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(remediation_tests).step);

    // Net-runtime fragmentation guard for the metrics HTTP server read path:
    // drives the exact handleConn persistent-reader sequence (takeByte line
    // reads + readSliceShort body) over a REAL loopback TCP socket whose
    // payload is delivered 1-byte and split-chunked, asserting no loss /
    // truncation. Links libc (compat global Io socket path).
    const metrics_frag_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/http_metrics_fragmentation_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(metrics_frag_tests).step);

    // Zig 0.16 migration: make `compat` importable from every target.
    for ([_]*std.Build.Step.Compile{
        exe,                          eval_exe,
        praos_verify,                 slot_index_reset,
        protocol_tests,               byte_tests,
        framing_tests,                mux_framing_tests,
        handshake_codec_tests,        muxwire_tests,
        chainsync_tests,              txsubmission_tests,
        acceptance_frontier_tests,
        ntc_fragmented_read_tests,
        ancestry_tests,               tx_decoder_tests,
        mempool_tests,                consensus_tests,
        producer_kes_heartbeat_tests, nonce_tests,
        resources_tests,              lsq_tests,
        status_fallback_tests,        pool_stats_tests,
        network_tests,                connection_registry_tests,
        propagation_tests,            bf_repro_tests,
        archive_tests,                guardian_tests,
        utxo_tests,                   kagami_tests,
        health_tests,                 ledger_tests,
        view_tests,                   remediation_tests,
        serve_loop_fragmented_read_tests,
        mux_fragment_tests,
        metrics_frag_tests,
    }) |c| {
        c.root_module.addImport("compat", compat_mod);
    }
}
