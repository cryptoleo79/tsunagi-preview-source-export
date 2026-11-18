TSUNAGI Backup Documentation
=============================

Script: scripts/backup-tsunagi-site.sh

=== WHAT IS BACKED UP ===

1. Website files
   Source:  /var/www/tsunagi
   Contains: all HTML pages, assets, docs, status.json
   Backed up as: www-tsunagi/

2. Runtime home (mainnet)
   Source:  /home/tsunagi/tsunagi-home
   Contains: cursor.json, journal.ndjson, propagation artifacts
   Backed up as: tsunagi-home/
   Skipped if directory does not exist.

3. Runtime home (preview)
   Source:  /home/tsunagi/tsunagi-home-preview
   Contains: cursor.json, journal.ndjson, propagation artifacts
   Backed up as: tsunagi-home-preview/
   Skipped if directory does not exist.

4. Source repository
   Source:  /home/tsunagi/src/tsunagi-follower/tsunagi-node
   Contains: Zig source, scripts, web pages, docs
   Backed up as: tsunagi-node/
   Excludes: zig-out/, .zig-cache/ (build artifacts)
   Skipped if directory does not exist.

=== BACKUP OUTPUT ===

Backups are stored in: /home/tsunagi/backups/

Each backup produces a single compressed archive:
  /home/tsunagi/backups/tsunagi-YYYYMMDD-HHMMSS.tar.gz

The temporary uncompressed directory is removed after
successful compression.

=== HOW TO RUN MANUALLY ===

  ./scripts/backup-tsunagi-site.sh

Or from any directory:

  /home/tsunagi/src/tsunagi-follower/tsunagi-node/scripts/backup-tsunagi-site.sh

The script prints progress messages and a summary with
archive path and size.

=== AUTOMATION WITH CRON ===

Daily backup at 03:00:

  0 3 * * * /home/tsunagi/src/tsunagi-follower/tsunagi-node/scripts/backup-tsunagi-site.sh >> /home/tsunagi/backups/backup.log 2>&1

Weekly backup (Sunday 04:00):

  0 4 * * 0 /home/tsunagi/src/tsunagi-follower/tsunagi-node/scripts/backup-tsunagi-site.sh >> /home/tsunagi/backups/backup.log 2>&1

=== OFF-SERVER BACKUP ===

IMPORTANT: Local backups protect against accidental deletion but
NOT against server failure, disk corruption, or host compromise.
Always copy backups off-server.

Manual copy with scp:

  scp /home/tsunagi/backups/tsunagi-20260312-030000.tar.gz \
    user@remote:/path/to/backups/

Automated sync with rsync:

  rsync -avz /home/tsunagi/backups/ user@remote:/path/to/backups/

Combined cron (backup + sync):

  0 3 * * * /path/to/scripts/backup-tsunagi-site.sh >> /home/tsunagi/backups/backup.log 2>&1 && rsync -avz /home/tsunagi/backups/ user@remote:/backups/tsunagi/

=== RETENTION ===

The script does not delete old backups. To manage disk usage,
periodically remove old archives:

  # Keep only the 7 most recent backups
  ls -t /home/tsunagi/backups/tsunagi-*.tar.gz | tail -n +8 | xargs rm -f

=== DEPENDENCIES ===

Required: bash, cp, tar, du, date
Optional: rsync (used for source repo backup to exclude build dirs;
          falls back to cp if rsync is unavailable — edit script)

=== LMDB DATABASES ===

Note: LMDB databases (data.mdb, lock.mdb) in the runtime home
directories can be large (tens of GB). The backup script copies
them as-is. For large LMDB stores, consider excluding them from
routine backups and managing LMDB snapshots separately.

To exclude LMDB from backups, add --exclude='*.mdb' to the
rsync command in the script, or remove the runtime home
sections entirely if only website backup is needed.
