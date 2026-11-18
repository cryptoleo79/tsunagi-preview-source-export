#!/usr/bin/env bash
# fork_readiness_cron.sh — daily fork-readiness evidence for preview + sancho.
# Suitable for cron or systemd timer.
#
# Usage:
#   ./scripts/fork_readiness_cron.sh
#   TSUNAGI_BIN=/path/to/tsunagi-node ./scripts/fork_readiness_cron.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKER="${SCRIPT_DIR}/fork_readiness_check.py"
BIN="${TSUNAGI_BIN:-${HOME}/.local/tsunagi/current/bin/tsunagi-node}"

run_check() {
    local net="$1"
    local home="${HOME}/tsunagi-home-${net}"
    if [ ! -d "${home}" ]; then
        echo "[cron] skip ${net}: ${home} does not exist"
        return 0
    fi
    echo "[cron] running fork-readiness for ${net}..."
    python3 "${CHECKER}" \
        --home "${home}" \
        --net "${net}" \
        --bin "${BIN}" \
        --state-url "http://127.0.0.1:9080/state" \
        --metrics-url "http://127.0.0.1:9080/metrics" \
        || echo "[cron] ${net}: non-zero exit (check evidence bundle)"
}

run_check preview
run_check sancho

echo "[cron] done"
