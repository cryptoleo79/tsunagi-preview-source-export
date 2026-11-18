#!/usr/bin/env bash
set -euo pipefail

LANG_CHOICE="${1:-en}" # en|ja
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_DIR="$ROOT_DIR/tsunagi-node"

say() {
  if [[ "$LANG_CHOICE" == "ja" ]]; then
    printf "%s\n" "$2"
  else
    printf "%s\n" "$1"
  fi
}

menu() {
  say "=== Tsunagi Menu ===" "=== Tsunagi メニュー ==="
  say "1) Doctor (health check)" "1) Doctor（ヘルスチェック）"
  say "2) Install/Update helpers (env + systemd)" "2) インストール/更新（env + systemd）"
  say "3) Run mainnet (debug, log to /tmp)" "3) Mainnet 実行（debug、/tmpへログ）"
  say "4) Run preview (debug, log to /tmp)" "4) Preview 実行（debug、/tmpへログ）"
  say "5) Start service (systemd --user)" "5) サービス開始（systemd --user）"
  say "6) Stop service" "6) サービス停止"
  say "7) Follow service logs" "7) サービスログ追跡"
  say "8) Tail last run log (/tmp/tsunagi_run.log)" "8) 最終実行ログ tail (/tmp/tsunagi_run.log)"
  say "0) Exit" "0) 終了"
  printf "> "
}

run_node() {
  local NET="$1"
  local LOG="/tmp/tsunagi_run.log"
  mkdir -p "$NODE_DIR/.cache/zig" "$NODE_DIR/.cache/tmp"
  export TMPDIR="$NODE_DIR/.cache/tmp"
  export ZIG_GLOBAL_CACHE_DIR="$NODE_DIR/.cache/zig"
  export ZIG_LOCAL_CACHE_DIR="$NODE_DIR/.cache/zig"
  export ZIG_TMPDIR="$NODE_DIR/.cache/tmp"
  export TSUNAGI_HOME="${TSUNAGI_HOME:-$HOME/.tsunagi-$NET}"
  mkdir -p "$TSUNAGI_HOME"
  rm -f "$LOG" 2>/dev/null || true

  say "Running $NET for 120s. Log: $LOG" "$NET を120秒実行します。ログ: $LOG"
  ( cd "$NODE_DIR"
    timeout 120s stdbuf -oL -eL zig build run \
      --cache-dir "$ZIG_LOCAL_CACHE_DIR" --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
      -- run --net "$NET" --lang "$LANG_CHOICE" --debug \
      > "$LOG" 2>&1 || true
  )
  say "Done. Tip: grep small slices from $LOG" "完了。ヒント: $LOG を grep で少量だけ表示すると安定します。"
}

while true; do
  menu
  read -r choice || exit 0
  case "$choice" in
    1) exec "$ROOT_DIR/scripts/doctor.sh" "$LANG_CHOICE" ;;
    2) exec "$ROOT_DIR/scripts/install.sh" ;;
    3) run_node "mainnet" ;;
    4) run_node "preview" ;;
    5) systemctl --user enable --now tsunagi; say "service started" "サービス開始";;
    6) systemctl --user disable --now tsunagi || systemctl --user stop tsunagi; say "service stopped" "サービス停止";;
    7) journalctl --user -u tsunagi -f ;;
    8) tail -n 120 /tmp/tsunagi_run.log 2>/dev/null || say "no /tmp/tsunagi_run.log yet" "まだ /tmp/tsunagi_run.log がありません";;
    0) exit 0 ;;
    *) say "invalid choice" "無効な選択";;
  esac
done
