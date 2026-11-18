#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# backup-tsunagi-site.sh
# Creates a timestamped backup of TSUNAGI website and runtime data.
#
# Usage:
#   ./scripts/backup-tsunagi-site.sh
#
# Backup target: /home/tsunagi/backups/tsunagi-YYYYMMDD-HHMMSS.tar.gz
# ─────────────────────────────────────────────────────────────
set -euo pipefail

BACKUP_ROOT="/home/tsunagi/backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$BACKUP_ROOT/tsunagi-$TIMESTAMP"
ARCHIVE="$BACKUP_ROOT/tsunagi-$TIMESTAMP.tar.gz"

echo "TSUNAGI Backup — $TIMESTAMP"
echo "============================="
echo ""

# ── Create backup directory ───────────────────────────────────
mkdir -p "$BACKUP_DIR"
echo "Backup directory: $BACKUP_DIR"
echo ""

# ── 1. Website files ─────────────────────────────────────────
WEBROOT="/var/www/tsunagi"
if [ -d "$WEBROOT" ]; then
  echo "Backing up website:  $WEBROOT"
  cp -a "$WEBROOT" "$BACKUP_DIR/www-tsunagi"
  echo "  Done."
else
  echo "Skipping website:    $WEBROOT (not found)"
fi

# ── 2. Runtime home (mainnet) ────────────────────────────────
MAINNET_HOME="/home/tsunagi/tsunagi-home"
if [ -d "$MAINNET_HOME" ]; then
  echo "Backing up mainnet:  $MAINNET_HOME"
  cp -a "$MAINNET_HOME" "$BACKUP_DIR/tsunagi-home"
  echo "  Done."
else
  echo "Skipping mainnet:    $MAINNET_HOME (not found)"
fi

# ── 3. Runtime home (preview) ────────────────────────────────
PREVIEW_HOME="/home/tsunagi/tsunagi-home-preview"
if [ -d "$PREVIEW_HOME" ]; then
  echo "Backing up preview:  $PREVIEW_HOME"
  cp -a "$PREVIEW_HOME" "$BACKUP_DIR/tsunagi-home-preview"
  echo "  Done."
else
  echo "Skipping preview:    $PREVIEW_HOME (not found)"
fi

# ── 4. Source repository ─────────────────────────────────────
SOURCE_DIR="/home/tsunagi/src/tsunagi-follower/tsunagi-node"
if [ -d "$SOURCE_DIR" ]; then
  echo "Backing up source:   $SOURCE_DIR"
  # Exclude build artifacts and .zig-cache to save space
  rsync -a \
    --exclude='zig-out' \
    --exclude='.zig-cache' \
    --exclude='zig-cache' \
    "$SOURCE_DIR/" "$BACKUP_DIR/tsunagi-node/"
  echo "  Done."
else
  echo "Skipping source:     $SOURCE_DIR (not found)"
fi

echo ""

# ── Compress ──────────────────────────────────────────────────
echo "Compressing: $ARCHIVE"
tar -czf "$ARCHIVE" -C "$BACKUP_ROOT" "tsunagi-$TIMESTAMP"
echo "  Done."

# ── Remove uncompressed directory ─────────────────────────────
rm -rf "$BACKUP_DIR"
echo "Removed temporary directory."

# ── Summary ───────────────────────────────────────────────────
SIZE=$(du -sh "$ARCHIVE" | cut -f1)
echo ""
echo "Backup complete."
echo "  Archive: $ARCHIVE"
echo "  Size:    $SIZE"
echo ""
echo "IMPORTANT: Copy this archive off-server for safe storage."
echo "  scp $ARCHIVE user@remote:/path/to/backups/"
