#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_DIR="$ROOT_DIR/tsunagi-node"

mkdir -p "$HOME/.config/systemd/user" "$HOME/bin"

# 1) env helper
cat > "$HOME/tsunagi-env.sh" <<EOF
set -euo pipefail
cd "$NODE_DIR" || exit 1

mkdir -p .cache/zig .cache/tmp
export TMPDIR="\$PWD/.cache/tmp"
export ZIG_GLOBAL_CACHE_DIR="\$PWD/.cache/zig"
export ZIG_LOCAL_CACHE_DIR="\$PWD/.cache/zig"
export ZIG_TMPDIR="\$PWD/.cache/tmp"

# Default runtime state (override per command)
export TSUNAGI_HOME="\${TSUNAGI_HOME:-$HOME/.tsunagi-mainnet}"
mkdir -p "\$TSUNAGI_HOME" 2>/dev/null || true
EOF
chmod +x "$HOME/tsunagi-env.sh"

# 2) convenience command
cat > "$HOME/bin/tsunagi" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$HOME/tsunagi-env.sh"

MODE="${1:-menu}"
shift || true

case "$MODE" in
  menu)  exec "$PWD/../scripts/tsunagi.sh" "$@" ;;
  doc|doctor) exec "$PWD/../scripts/doctor.sh" "${1:-en}" ;;
  run)
    NET="${1:-mainnet}"; shift || true
    LANG="${1:-en}"; shift || true
    DEBUG="${1:-debug}"; shift || true
    LOG="${1:-/tmp/tsunagi_run.log}"; shift || true
    rm -f "$LOG" 2>/dev/null || true
    if [[ "$DEBUG" == "debug" ]]; then
      timeout 0 stdbuf -oL -eL zig build run --cache-dir "$ZIG_LOCAL_CACHE_DIR" --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
        -- run --net "$NET" --lang "$LANG" --debug >"$LOG" 2>&1
    else
      timeout 0 stdbuf -oL -eL zig build run --cache-dir "$ZIG_LOCAL_CACHE_DIR" --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
        -- run --net "$NET" --lang "$LANG" >"$LOG" 2>&1
    fi
    ;;
  *)
    echo "usage: tsunagi [menu|doctor|run]" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$HOME/bin/tsunagi"

# 3) systemd user service
cat > "$HOME/.config/systemd/user/tsunagi.service" <<EOF
[Unit]
Description=Tsunagi Node (Zig-only Cardano follower)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$NODE_DIR
Environment=TSUNAGI_HOME=%h/.tsunagi-mainnet
ExecStart=/bin/bash -lc 'source %h/tsunagi-env.sh && exec stdbuf -oL -eL zig build run --cache-dir "\$ZIG_LOCAL_CACHE_DIR" --global-cache-dir "\$ZIG_GLOBAL_CACHE_DIR" -- run --net mainnet --lang en --debug'
Restart=always
RestartSec=2
# keep logs in journal; you can also tee to file by customizing ExecStart
LimitNOFILE=1048576

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload

echo "✅ Installed:"
echo " - $HOME/tsunagi-env.sh"
echo " - $HOME/bin/tsunagi (make sure ~/bin is on PATH)"
echo " - systemd user unit: ~/.config/systemd/user/tsunagi.service"
echo
echo "Next:"
echo "  systemctl --user enable --now tsunagi"
echo "  journalctl --user -u tsunagi -f"
