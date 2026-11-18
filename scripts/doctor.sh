#!/usr/bin/env bash
set -euo pipefail

LANG_CHOICE="${1:-en}"   # en | ja
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_DIR="$ROOT_DIR/tsunagi-node"
ENV_FILE="$HOME/tsunagi-env.sh"

say() {
  if [[ "$LANG_CHOICE" == "ja" ]]; then
    printf "%s\n" "$2"
  else
    printf "%s\n" "$1"
  fi
}

ok()  { say "OK: $1" "OK: $1"; }
warn(){ say "WARN: $1" "注意: $1"; }
bad() { say "FAIL: $1" "失敗: $1"; }

say "== Tsunagi Doctor (EN) ==" "== Tsunagi Doctor (日本語) =="

# 1) repo sanity
[[ -d "$NODE_DIR" ]] && ok "repo path: $NODE_DIR" || { bad "missing $NODE_DIR"; exit 1; }
[[ -f "$NODE_DIR/build.zig" ]] && ok "build.zig exists" || warn "build.zig not found under tsunagi-node"

# 2) zig sanity
if command -v zig >/dev/null 2>&1; then
  ZV="$(zig version || true)"
  ok "zig found: $(command -v zig) (version $ZV)"
else
  bad "zig not found in PATH"
fi

# 3) env file
if [[ -f "$ENV_FILE" ]]; then
  ok "env file exists: $ENV_FILE"
else
  warn "env file missing: $ENV_FILE (run scripts/install.sh)"
fi

# 4) disk / memory
DF="$(df -h "$ROOT_DIR" | awk 'NR==2{print $4 " free on " $1 " (" $5 " used)"}')"
ok "disk: $DF"

# 5) TSUNAGI_HOME sanity (optional)
TSUNAGI_HOME="${TSUNAGI_HOME:-$HOME/.tsunagi-mainnet}"
mkdir -p "$TSUNAGI_HOME" || true
ok "TSUNAGI_HOME=$TSUNAGI_HOME"
[[ -f "$TSUNAGI_HOME/cursor.json" ]] && ok "cursor.json present" || warn "cursor.json missing (fresh sync or cleared)"
[[ -f "$TSUNAGI_HOME/utxo.snapshot" ]] && ok "utxo.snapshot present" || warn "utxo.snapshot missing (UTxO not yet persisted)"

# 6) network basic checks (best-effort)
# We keep it minimal to avoid dependencies.
say "== Network checks ==" "== ネットワーク確認 =="
MAINNET_HOST="mainnet-node.world.dev.cardano.org"
PREVIEW_HOST="preview-node.world.dev.cardano.org"
if command -v getent >/dev/null 2>&1; then
  getent hosts "$MAINNET_HOST" >/dev/null && ok "DNS ok: $MAINNET_HOST" || warn "DNS failed: $MAINNET_HOST"
  getent hosts "$PREVIEW_HOST" >/dev/null && ok "DNS ok: $PREVIEW_HOST" || warn "DNS failed: $PREVIEW_HOST"
else
  warn "getent not available; skipping DNS check"
fi

# 7) termius stability hint
say "== Termius safety ==" "== Termius 安定化 =="
say \
  "Tip: run with logs redirected to file, and grep small slices." \
  "ヒント: 出力はファイルにリダイレクトして、grepで少量だけ表示すると安定します。"

say "Doctor finished." "Doctor 完了。"
