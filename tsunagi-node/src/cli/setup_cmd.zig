const std = @import("std");
const compat = @import("compat");
const i18n = @import("i18n.zig");
const release_install = @import("release_install.zig");

pub const Role = enum { relay, tools, bp };

// ── Embedded systemd unit templates (repo/dev mode) ─────────────────

const tmpl_mainnet_service =
    \\# Tsunagi mainnet relay — installed by `tsunagi-node setup`
    \\[Unit]
    \\Description=Tsunagi Node (mainnet)
    \\After=network-online.target
    \\Wants=network-online.target
    \\StartLimitIntervalSec=60
    \\StartLimitBurst=3
    \\
    \\[Service]
    \\Type=simple
    \\WorkingDirectory=%h/src/tsunagi-follower/tsunagi-node
    \\
    \\# === TSUNAGI ENVIRONMENT ===
    \\Environment=TSUNAGI_HOME=%h/tsunagi-home-mainnet
    \\Environment=TSUNAGI_CAPTURE=1
    \\Environment=TSUNAGI_LMDB=%h/tsunagi-home-mainnet/lmdb
    \\Environment=TSUNAGI_LMDB_TRUTH=0
    \\Environment=TSUNAGI_LMDB_AUTHORITY=0
    \\Environment=TSUNAGI_METRICS=1
    \\# Environment=TSUNAGI_MODE=lmdb_native  # Enable once LMDB convergence is reached
    \\
    \\# === RUN ===
    \\ExecStart=%h/src/tsunagi-follower/tsunagi-node/zig-out/bin/tsunagi-node run --net mainnet --lang en
    \\
    \\Restart=on-failure
    \\RestartSec=5
    \\
    \\# === RESOURCE LIMITS ===
    \\MemoryMax=10G
    \\CPUQuota=250%
    \\Nice=5
    \\LimitNOFILE=65535
    \\
    \\# === SECURITY HARDENING ===
    \\NoNewPrivileges=true
    \\PrivateTmp=true
    \\ProtectSystem=strict
    \\ProtectHome=true
    \\ReadWritePaths=%h/tsunagi-home-mainnet
    \\RestrictSUIDSGID=true
    \\LockPersonality=true
    \\MemoryDenyWriteExecute=true
    \\RestrictNamespaces=true
    \\SystemCallArchitectures=native
    \\
    \\# === LOGGING ===
    \\StandardOutput=journal
    \\StandardError=journal
    \\
    \\[Install]
    \\WantedBy=default.target
    \\
;

const tmpl_tsf_service =
    \\[Unit]
    \\Description=Tsunagi TSF Artifact Export (nightly)
    \\After=network-online.target
    \\Wants=network-online.target
    \\
    \\[Service]
    \\Type=oneshot
    \\WorkingDirectory=%h/src/tsunagi-follower/tsunagi-node
    \\
    \\Environment=TSUNAGI_HOME=%h/tsunagi-home-mainnet
    \\Environment=TSUNAGI_LMDB=%h/tsunagi-home-mainnet/lmdb
    \\
    \\# Output files
    \\Environment=TSF_DIR=%h/tsunagi-home-mainnet/tsf
    \\Environment=KEEP_LAST=7
    \\
    \\ExecStart=/usr/bin/env bash -lc '\
    \\  set -euo pipefail; \
    \\  mkdir -p "$TSF_DIR"; \
    \\  TSF_OUT="$TSF_DIR/mainnet-$(date +%%Y%%m%%d-%%H%%M%%S).tsf"; \
    \\  ./zig-out/bin/tsunagi-node tsf-artifact --lmdb "$TSUNAGI_LMDB" --out "$TSF_OUT" --test-dir /tmp/tsunagi-lmdb-test --gzip --strict; \
    \\  ls -1t "$TSF_DIR"/*.tsf 2>/dev/null | tail -n +$((KEEP_LAST+1)) | xargs -r rm -f; \
    \\  ls -1t "$TSF_DIR"/*.tsf.gz 2>/dev/null | tail -n +$((KEEP_LAST+1)) | xargs -r rm -f; \
    \\  echo "tsf-artifact: wrote $TSF_OUT" \
    \\'
    \\
;

const tmpl_autoswitch_service =
    \\[Unit]
    \\Description=Tsunagi AutoSwitch Apply (checks convergence marker)
    \\After=network-online.target
    \\Wants=network-online.target
    \\
    \\[Service]
    \\Type=oneshot
    \\WorkingDirectory=%h/src/tsunagi-follower/tsunagi-node
    \\Environment=TSUNAGI_HOME=%h/tsunagi-home-mainnet
    \\Environment=TSUNAGI_AUTOSWITCH=1
    \\ExecStart=%h/src/tsunagi-follower/tsunagi-node/zig-out/bin/tsunagi-node autoswitch-apply
    \\
;

// ── Installed-mode templates (use ~/.local/tsunagi/current) ─────────

const tmpl_mainnet_service_installed =
    \\# Tsunagi mainnet relay — installed from GitHub Release
    \\[Unit]
    \\Description=Tsunagi Node (mainnet)
    \\After=network-online.target
    \\Wants=network-online.target
    \\StartLimitIntervalSec=60
    \\StartLimitBurst=3
    \\
    \\[Service]
    \\Type=simple
    \\WorkingDirectory=%h/.local/tsunagi/current
    \\
    \\# === TSUNAGI ENVIRONMENT ===
    \\Environment=TSUNAGI_HOME=%h/tsunagi-home-mainnet
    \\Environment=TSUNAGI_CAPTURE=1
    \\Environment=TSUNAGI_LMDB=%h/tsunagi-home-mainnet/lmdb
    \\Environment=TSUNAGI_LMDB_TRUTH=0
    \\Environment=TSUNAGI_LMDB_AUTHORITY=0
    \\Environment=TSUNAGI_METRICS=1
    \\# Environment=TSUNAGI_MODE=lmdb_native  # Enable once LMDB convergence is reached
    \\
    \\# === RUN ===
    \\ExecStart=%h/.local/tsunagi/current/tsunagi-node run --net mainnet --lang en
    \\
    \\Restart=on-failure
    \\RestartSec=5
    \\
    \\# === RESOURCE LIMITS ===
    \\MemoryMax=10G
    \\CPUQuota=250%
    \\Nice=5
    \\LimitNOFILE=65535
    \\
    \\# === SECURITY HARDENING ===
    \\NoNewPrivileges=true
    \\PrivateTmp=true
    \\ProtectSystem=strict
    \\ProtectHome=true
    \\ReadWritePaths=%h/tsunagi-home-mainnet %h/.local/tsunagi
    \\RestrictSUIDSGID=true
    \\LockPersonality=true
    \\MemoryDenyWriteExecute=true
    \\RestrictNamespaces=true
    \\SystemCallArchitectures=native
    \\
    \\# === LOGGING ===
    \\StandardOutput=journal
    \\StandardError=journal
    \\
    \\[Install]
    \\WantedBy=default.target
    \\
;

const tmpl_tsf_service_installed =
    \\[Unit]
    \\Description=Tsunagi TSF Artifact Export (nightly)
    \\After=network-online.target
    \\Wants=network-online.target
    \\
    \\[Service]
    \\Type=oneshot
    \\WorkingDirectory=%h/.local/tsunagi/current
    \\
    \\Environment=TSUNAGI_HOME=%h/tsunagi-home-mainnet
    \\Environment=TSUNAGI_LMDB=%h/tsunagi-home-mainnet/lmdb
    \\
    \\# Output files
    \\Environment=TSF_DIR=%h/tsunagi-home-mainnet/tsf
    \\Environment=KEEP_LAST=7
    \\
    \\ExecStart=/usr/bin/env bash -lc '\
    \\  set -euo pipefail; \
    \\  mkdir -p "$TSF_DIR"; \
    \\  TSF_OUT="$TSF_DIR/mainnet-$(date +%%Y%%m%%d-%%H%%M%%S).tsf"; \
    \\  ./tsunagi-node tsf-artifact --lmdb "$TSUNAGI_LMDB" --out "$TSF_OUT" --test-dir /tmp/tsunagi-lmdb-test --gzip --strict; \
    \\  ls -1t "$TSF_DIR"/*.tsf 2>/dev/null | tail -n +$((KEEP_LAST+1)) | xargs -r rm -f; \
    \\  ls -1t "$TSF_DIR"/*.tsf.gz 2>/dev/null | tail -n +$((KEEP_LAST+1)) | xargs -r rm -f; \
    \\  echo "tsf-artifact: wrote $TSF_OUT" \
    \\'
    \\
;

const tmpl_autoswitch_service_installed =
    \\[Unit]
    \\Description=Tsunagi AutoSwitch Apply (checks convergence marker)
    \\After=network-online.target
    \\Wants=network-online.target
    \\
    \\[Service]
    \\Type=oneshot
    \\WorkingDirectory=%h/.local/tsunagi/current
    \\Environment=TSUNAGI_HOME=%h/tsunagi-home-mainnet
    \\Environment=TSUNAGI_AUTOSWITCH=1
    \\ExecStart=%h/.local/tsunagi/current/tsunagi-node autoswitch-apply
    \\
;

// Timer templates are path-independent — shared by both modes
const tmpl_tsf_timer =
    \\[Unit]
    \\Description=Run Tsunagi TSF Artifact Export nightly at 03:00
    \\
    \\[Timer]
    \\OnCalendar=*-*-* 03:00:00
    \\Persistent=true
    \\Unit=tsf-artifact.service
    \\
    \\[Install]
    \\WantedBy=timers.target
    \\
;

const tmpl_autoswitch_timer =
    \\[Unit]
    \\Description=Run Tsunagi autoswitch apply every 5 minutes
    \\
    \\[Timer]
    \\OnCalendar=*:0/5
    \\Persistent=true
    \\Unit=autoswitch-apply.service
    \\
    \\[Install]
    \\WantedBy=timers.target
    \\
;

// ── Helpers ──────────────────────────────────────────────────────────

fn p(lang: i18n.Lang, en: []const u8, ja: []const u8) []const u8 {
    return if (lang == .ja) ja else en;
}

/// Install a single systemd unit file. Returns true if written, false if skipped.
fn installUnit(alloc: std.mem.Allocator, unit_dir: []const u8, name: []const u8, content: []const u8, lang: i18n.Lang) !bool {
    const dest = try std.fs.path.join(alloc, &[_][]const u8{ unit_dir, name });
    defer alloc.free(dest);

    // Never overwrite existing files
    if (compat.fs.cwd().openFile(dest, .{})) |fc| {
        var f = fc;
        f.close();
        std.debug.print("  {s}: {s}\n", .{
            p(lang, "exists (skipped)", "既存（スキップ）"),
            name,
        });
        return false;
    } else |_| {}

    var f = try compat.fs.cwd().createFile(dest, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);

    std.debug.print("  {s}: {s}\n", .{
        p(lang, "installed", "インストール完了"),
        name,
    });
    return true;
}

fn runSystemctl(alloc: std.mem.Allocator, args: []const []const u8) void {
    _ = alloc; // 0.16's std.process.spawn does not take an allocator
    _ = compat.childSpawnWait(args) catch |err| {
        std.debug.print("  warning: systemctl failed: {}\n", .{err});
    };
}

// ── Main entry ───────────────────────────────────────────────────────

pub fn run(alloc: std.mem.Allocator, role: Role, autoswitch: bool, install_arg: ?[]const u8, lang: i18n.Lang) !void {
    // --- BP stub ---
    if (role == .bp) {
        std.debug.print("\n{s}\n\n", .{p(
            lang,
            "BP (block producer) mode is not implemented yet.\nReserved for future full-node forging capability.",
            "BP（ブロック生成）モードは未対応です。\n将来のフルノード鍛造機能のために予約されています。",
        )});
        std.debug.print("{s}\n\n", .{p(
            lang,
            "Tip: use --role relay to set up a relay node instead.",
            "ヒント: --role relay でリレーノードをセットアップできます。",
        )});
        return;
    }

    // --- Install from release (if requested) ---
    var installed: ?release_install.InstallResult = null;
    if (install_arg) |ia| {
        installed = try release_install.install(alloc, ia, lang);
    }
    const use_installed = installed != null;

    // --- Resolve paths ---
    const home = compat.getEnvVarOwned(alloc, "HOME") catch {
        std.debug.print("error: HOME not set\n", .{});
        return error.EnvironmentVariableNotFound;
    };
    defer alloc.free(home);

    const unit_dir = try std.fs.path.join(alloc, &[_][]const u8{ home, ".config", "systemd", "user" });
    defer alloc.free(unit_dir);

    // --- Banner ---
    std.debug.print(
        \\
        \\  +======================================+
        \\  |       TSUNAGI  SETUP  v0.7.42        |
        \\  +======================================+
        \\
    , .{});

    const role_label = switch (role) {
        .relay => p(lang, "relay", "リレー"),
        .tools => p(lang, "tools", "ツール"),
        .bp => unreachable,
    };
    std.debug.print("  {s}: {s}\n", .{ p(lang, "Role", "ロール"), role_label });
    if (installed) |inst| {
        std.debug.print("  {s}: {s} ({s})\n", .{ p(lang, "Release", "リリース"), inst.tag, inst.arch });
    }
    std.debug.print("\n", .{});

    // --- Ensure unit directory ---
    std.debug.print("{s}\n", .{p(lang, "Creating systemd user directory...", "systemd ユーザーディレクトリを作成中...")});
    try compat.fs.cwd().makePath(unit_dir);
    std.debug.print("  {s}\n\n", .{unit_dir});

    // --- Select templates based on install mode ---
    const svc_mainnet = if (use_installed) tmpl_mainnet_service_installed else tmpl_mainnet_service;
    const svc_tsf = if (use_installed) tmpl_tsf_service_installed else tmpl_tsf_service;
    const svc_autoswitch = if (use_installed) tmpl_autoswitch_service_installed else tmpl_autoswitch_service;

    // --- Install units ---
    std.debug.print("{s}\n", .{p(lang, "Installing unit files...", "ユニットファイルをインストール中...")});

    if (role == .relay) {
        _ = try installUnit(alloc, unit_dir, "tsunagi-mainnet.service", svc_mainnet, lang);
    }

    _ = try installUnit(alloc, unit_dir, "tsf-artifact.service", svc_tsf, lang);
    _ = try installUnit(alloc, unit_dir, "tsf-artifact.timer", tmpl_tsf_timer, lang);

    if (autoswitch) {
        _ = try installUnit(alloc, unit_dir, "autoswitch-apply.service", svc_autoswitch, lang);
        _ = try installUnit(alloc, unit_dir, "autoswitch-apply.timer", tmpl_autoswitch_timer, lang);
    }

    std.debug.print("\n", .{});

    // --- systemctl commands ---
    std.debug.print("{s}\n", .{p(lang, "Reloading systemd...", "systemd をリロード中...")});
    runSystemctl(alloc, &[_][]const u8{ "systemctl", "--user", "daemon-reload" });

    if (role == .relay) {
        std.debug.print("{s}\n", .{p(lang, "Enabling and starting node service...", "ノードサービスを有効化・起動中...")});
        runSystemctl(alloc, &[_][]const u8{ "systemctl", "--user", "enable", "--now", "tsunagi-mainnet.service" });
    }

    std.debug.print("{s}\n", .{p(lang, "Enabling TSF artifact timer...", "TSF アーティファクトタイマーを有効化中...")});
    runSystemctl(alloc, &[_][]const u8{ "systemctl", "--user", "enable", "--now", "tsf-artifact.timer" });

    if (autoswitch) {
        std.debug.print("{s}\n", .{p(lang, "Enabling autoswitch timer...", "自動切替タイマーを有効化中...")});
        runSystemctl(alloc, &[_][]const u8{ "systemctl", "--user", "enable", "--now", "autoswitch-apply.timer" });
    }

    if (role == .relay) {
        std.debug.print("{s}\n", .{p(lang, "Restarting node...", "ノードを再起動中...")});
        runSystemctl(alloc, &[_][]const u8{ "systemctl", "--user", "restart", "tsunagi-mainnet.service" });
    }

    // --- Summary ---
    std.debug.print("\n  -----------------------------------------\n", .{});

    if (installed) |inst| {
        std.debug.print(
            \\
            \\  {s}: {s}
            \\  {s}: {s}
            \\  Binary: {s}/tsunagi-node
            \\
        , .{
            p(lang, "Installed tag", "インストール済みタグ"),
            inst.tag,
            p(lang, "Architecture", "アーキテクチャ"),
            inst.arch,
            inst.install_dir,
        });
    }

    if (role == .relay) {
        std.debug.print(
            \\
            \\  {s}
            \\
            \\  {s}
            \\    systemctl --user status tsunagi-mainnet.service
            \\
            \\  {s}
            \\    journalctl --user -u tsunagi-mainnet.service -f
            \\
            \\  {s}
            \\    http://127.0.0.1:9080/metrics
            \\
        , .{
            p(lang, "Setup complete!", "セットアップ完了！"),
            p(lang, "Check status:", "状態の確認:"),
            p(lang, "View logs:", "ログの確認:"),
            p(lang, "Metrics:", "メトリクス:"),
        });
    } else {
        // tools
        std.debug.print(
            \\
            \\  {s}
            \\
            \\  {s}
            \\    systemctl --user list-timers --all | grep -E 'tsf-artifact|autoswitch'
            \\
            \\  {s}
            \\    systemctl --user start tsf-artifact.service
            \\    journalctl --user -u tsf-artifact.service --since "1 min ago"
            \\
        , .{
            p(lang, "Tools setup complete!", "ツールセットアップ完了！"),
            p(lang, "Check timers:", "タイマーの確認:"),
            p(lang, "Manual TSF export:", "手動 TSF エクスポート:"),
        });
    }

    if (autoswitch) {
        std.debug.print(
            \\
            \\  {s}
            \\    systemctl --user list-timers --all | grep autoswitch
            \\
        , .{p(lang, "Autoswitch timer:", "自動切替タイマー:")});
    }

    std.debug.print("  -----------------------------------------\n\n", .{});
}
