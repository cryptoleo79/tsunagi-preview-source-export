#!/usr/bin/env python3
"""Tsunagi retention cleanup — prune old evidence bundles, captures, and alignment results.

Targets (all under TSUNAGI_HOME):
  - regress/fork_readiness/<timestamp>/   — by age (default 30 days)
  - captures/*.bin                        — by count, oldest-first (default keep 200)
  - regress/alignment/results/<timestamp>/— by count, oldest-first (default keep 50)

Safety: never deletes lmdb/, genesis/, keys/, *.skey, *.vkey, or opcert files.

Python 3 stdlib only — no external dependencies.
"""

import argparse
import datetime
import os
import shutil
import sys


# ---------------------------------------------------------------------------
# Safety
# ---------------------------------------------------------------------------

# Directories that must NEVER be deleted, even if they appear under a target.
PROTECTED_DIRS = {"lmdb", "genesis", "keys"}

# File extensions / names that must NEVER be deleted.
PROTECTED_NAMES = {"opcert"}
PROTECTED_EXTS = {".skey", ".vkey"}


def is_protected(path):
    """Return True if *path* (file or dir) must not be deleted."""
    name = os.path.basename(path)
    if name in PROTECTED_DIRS or name in PROTECTED_NAMES:
        return True
    _, ext = os.path.splitext(name)
    if ext in PROTECTED_EXTS:
        return True
    return False


# ---------------------------------------------------------------------------
# Pruning helpers
# ---------------------------------------------------------------------------

def parse_ts_dir(name):
    """Parse a YYYYMMDDTHHMMSSZ directory name into a datetime (UTC).

    Returns None if the name doesn't match the expected format.
    """
    try:
        return datetime.datetime.strptime(name, "%Y%m%dT%H%M%SZ").replace(
            tzinfo=datetime.timezone.utc
        )
    except ValueError:
        return None


def prune_fork_readiness(home, keep_days, dry_run):
    """Delete fork readiness bundles older than *keep_days* days."""
    base = os.path.join(home, "regress", "fork_readiness")
    if not os.path.isdir(base):
        print(f"  SKIP: {base} does not exist")
        return 0

    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=keep_days)
    removed = 0

    for entry in sorted(os.listdir(base)):
        path = os.path.join(base, entry)
        if not os.path.isdir(path):
            continue
        if is_protected(path):
            continue

        ts = parse_ts_dir(entry)
        if ts is None:
            # Not a timestamp dir — skip.
            continue
        if ts < cutoff:
            if dry_run:
                print(f"  DRY-RUN: would remove {path}")
            else:
                shutil.rmtree(path)
                print(f"  REMOVED: {path}")
            removed += 1

    return removed


def prune_captures(home, keep_count, dry_run):
    """Keep only the newest *keep_count* capture files (by mtime)."""
    base = os.path.join(home, "captures")
    if not os.path.isdir(base):
        print(f"  SKIP: {base} does not exist")
        return 0

    # Collect .bin files with mtime.
    files = []
    for entry in os.listdir(base):
        path = os.path.join(base, entry)
        if not os.path.isfile(path):
            continue
        if is_protected(path):
            continue
        if not entry.endswith(".bin"):
            continue
        files.append((os.path.getmtime(path), path))

    # Sort by mtime descending (newest first).
    files.sort(key=lambda x: x[0], reverse=True)

    removed = 0
    for _, path in files[keep_count:]:
        if dry_run:
            print(f"  DRY-RUN: would remove {path}")
        else:
            os.remove(path)
            print(f"  REMOVED: {path}")
        removed += 1

    return removed


def prune_alignment_results(home, keep_count, dry_run):
    """Keep only the newest *keep_count* alignment result directories (by name sort)."""
    base = os.path.join(home, "regress", "alignment", "results")
    if not os.path.isdir(base):
        print(f"  SKIP: {base} does not exist")
        return 0

    dirs = []
    for entry in sorted(os.listdir(base)):
        path = os.path.join(base, entry)
        if not os.path.isdir(path):
            continue
        if is_protected(path):
            continue
        dirs.append(entry)

    # Sorted ascending — newest timestamps sort last. Remove the oldest.
    to_remove = dirs[:-keep_count] if len(dirs) > keep_count else []
    removed = 0
    for entry in to_remove:
        path = os.path.join(base, entry)
        if dry_run:
            print(f"  DRY-RUN: would remove {path}")
        else:
            shutil.rmtree(path)
            print(f"  REMOVED: {path}")
        removed += 1

    return removed


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Prune old tsunagi evidence bundles, captures, and alignment results."
    )
    parser.add_argument(
        "--home",
        default=os.environ.get("TSUNAGI_HOME", os.path.expanduser("~/.tsunagi")),
        help="TSUNAGI_HOME directory (default: $TSUNAGI_HOME or ~/.tsunagi)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would be deleted without actually deleting.",
    )
    parser.add_argument(
        "--keep-days-fork",
        type=int,
        default=30,
        help="Keep fork readiness bundles newer than N days (default: 30).",
    )
    parser.add_argument(
        "--keep-captures",
        type=int,
        default=200,
        help="Keep the newest N capture files (default: 200).",
    )
    parser.add_argument(
        "--keep-align-results",
        type=int,
        default=50,
        help="Keep the newest N alignment result dirs (default: 50).",
    )
    args = parser.parse_args()

    home = os.path.abspath(args.home)
    if not os.path.isdir(home):
        print(f"ERROR: TSUNAGI_HOME does not exist: {home}", file=sys.stderr)
        sys.exit(1)

    mode = "DRY-RUN" if args.dry_run else "LIVE"
    print(f"=== Tsunagi Retention Cleanup ({mode}) ===")
    print(f"TSUNAGI_HOME: {home}")
    print()

    total = 0

    print(f"[1/3] Fork readiness bundles (keep >{args.keep_days_fork} days)")
    n = prune_fork_readiness(home, args.keep_days_fork, args.dry_run)
    total += n
    print(f"  -> {n} bundle(s) {'would be ' if args.dry_run else ''}removed")
    print()

    print(f"[2/3] Captures (keep newest {args.keep_captures})")
    n = prune_captures(home, args.keep_captures, args.dry_run)
    total += n
    print(f"  -> {n} file(s) {'would be ' if args.dry_run else ''}removed")
    print()

    print(f"[3/3] Alignment results (keep newest {args.keep_align_results})")
    n = prune_alignment_results(home, args.keep_align_results, args.dry_run)
    total += n
    print(f"  -> {n} dir(s) {'would be ' if args.dry_run else ''}removed")
    print()

    print(f"=== Total: {total} item(s) {'would be ' if args.dry_run else ''}removed ===")


if __name__ == "__main__":
    main()
