#!/usr/bin/env bash
set -u

TSUNAGI_HOME="${TSUNAGI_HOME:-$HOME/tsunagi-home-preview}"
BIN="${BIN:-$HOME/src/tsunagi-follower/tsunagi-node/zig-out/bin/tsunagi-node}"
ALLOWLIST="${ALLOWLIST:-152.53.152.172,127.0.0.1}"
LOG="${LOG:-/tmp/propagation-preview-fresh.log}"

journalctl --user -u tsunagi-preview.service -f --no-pager | \
grep --line-buffered -Ei 'FORGE: block built|FORGE SNAPSHOT: written|FORGE SKIP:' | \
while IFS= read -r line; do
  echo
  echo "============================================================"
  echo "EVENT: $line"
  echo "TIME : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "============================================================"

  case "$line" in
    *"FORGE SKIP:"*)
      echo "strict-forge-watch: forge skipped; waiting for next real forge"
      ;;
    *)
      seal_out="$(TSUNAGI_HOME="$TSUNAGI_HOME" "$BIN" guardian seal-tip --net preview 2>&1 || true)"
      printf '%s\n' "$seal_out"

      if printf '%s\n' "$seal_out" | grep -q 'FORGE PROMOTED'; then
        echo
        echo "strict-forge-watch: FORGE PROMOTED detected"
        echo "strict-forge-watch: artifact updated on disk; LIVE_PUSH will deliver to relay"
      else
        echo "strict-forge-watch: no promotion this time; waiting for next forge"
      fi
      ;;
  esac
done
