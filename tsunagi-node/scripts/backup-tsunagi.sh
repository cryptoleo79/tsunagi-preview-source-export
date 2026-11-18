#!/usr/bin/env bash
set -euo pipefail

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_ROOT="$HOME/backups"
DEST="$BACKUP_ROOT/tsunagi-backup-$STAMP"

mkdir -p "$BACKUP_ROOT"
mkdir -p "$DEST"

echo "Creating backup staging dir: $DEST"

# Runtime homes
[ -d "$HOME/tsunagi-home" ] && cp -a "$HOME/tsunagi-home" "$DEST/"
[ -d "$HOME/tsunagi-home-preview" ] && cp -a "$HOME/tsunagi-home-preview" "$DEST/"
[ -d "$HOME/tsunagi-home-mainnet" ] && cp -a "$HOME/tsunagi-home-mainnet" "$DEST/"
[ -d "$HOME/tsunagi-home-sancho" ] && cp -a "$HOME/tsunagi-home-sancho" "$DEST/"

# Repo
[ -d "$HOME/src/tsunagi-follower/tsunagi-node" ] && mkdir -p "$DEST/src/tsunagi-follower" && cp -a "$HOME/src/tsunagi-follower/tsunagi-node" "$DEST/src/tsunagi-follower/"

# Website
[ -d "/var/www/tsunagi" ] && mkdir -p "$DEST/var/www" && cp -a "/var/www/tsunagi" "$DEST/var/www/"

# Optional docs / local operator files
[ -f "$HOME/tsunagi-preview-producer.env" ] && cp -a "$HOME/tsunagi-preview-producer.env" "$DEST/"
[ -f "$HOME/forge-arm-safe.sh" ] && cp -a "$HOME/forge-arm-safe.sh" "$DEST/"

tar -czf "${DEST}.tar.gz" -C "$BACKUP_ROOT" \
  --exclude='*.skey' \
  --exclude='*.cert' \
  --exclude='tsunagi-keys' \
  "tsunagi-backup-${STAMP}"

rm -rf "$DEST"

echo "Backup complete: ${DEST}.tar.gz"

find "$BACKUP_ROOT" -type f -name 'tsunagi-backup-*.tar.gz' -mtime +7 -delete
echo "Retention: removed archives older than 7 days"
