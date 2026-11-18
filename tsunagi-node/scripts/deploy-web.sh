#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# deploy-web.sh
# Deploys TSUNAGI static site to /var/www/tsunagi/.
# Runtime-generated JSON lives in /var/www/tsunagi-data/ (untouched).
#
# Usage:
#   cd tsunagi-node && ./scripts/deploy-web.sh
# ─────────────────────────────────────────────────────────────
set -euo pipefail

REPO_WEB_DIR="$(pwd)/web"
STATIC_TARGET="/var/www/tsunagi"
DATA_TARGET="/var/www/tsunagi-data"

# ── Preflight ──
if [ ! -d "$REPO_WEB_DIR" ]; then
  echo "ERROR: web directory not found in repo"
  exit 1
fi
if [ ! -f "$REPO_WEB_DIR/index.html" ]; then
  echo "ERROR: index.html not found in web/"
  exit 1
fi
if [ ! -f "$REPO_WEB_DIR/assets/tsunagi-logo-primary.jpeg" ]; then
  echo "WARNING: logo asset missing from web/assets/"
fi

echo "Deploying TSUNAGI static site..."

# ── Static site (--delete is safe here — no runtime files) ──
sudo mkdir -p "$STATIC_TARGET"
sudo rsync -av --delete "$REPO_WEB_DIR"/ "$STATIC_TARGET"/
sudo find "$STATIC_TARGET" -type f -name "*.html" -exec chmod 644 {} \;

# ── Ensure data directory exists (never deleted) ──
sudo mkdir -p "$DATA_TARGET" "$DATA_TARGET/block-detail"
sudo chown tsunagi:tsunagi "$DATA_TARGET" "$DATA_TARGET/block-detail"

# ── Reload nginx ──
sudo systemctl reload nginx

# ── Postdeploy checks ──
echo ""
echo "=== Postdeploy Checks ==="
curl -sf --max-time 3 -o /dev/null "http://127.0.0.1/index.html" && echo "  PASS: index.html reachable" || echo "  FAIL: index.html"
curl -sf --max-time 3 -o /dev/null "http://127.0.0.1/assets/tsunagi-logo-primary.jpeg" && echo "  PASS: logo asset reachable" || echo "  FAIL: logo asset"
curl -sf --max-time 3 -o /dev/null "http://127.0.0.1/data/status.json" && echo "  PASS: /data/status.json reachable" || echo "  WARN: /data/status.json (may need cron cycle)"
echo ""
echo "Deployment complete."
