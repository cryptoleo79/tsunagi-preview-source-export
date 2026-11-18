#!/usr/bin/env python3
"""Package fork readiness proof evidence for a single network.

Locates the latest fork_readiness run under TSUNAGI_HOME/regress/fork_readiness/<net>/
and copies the evidence files into a local proof/<net>/ directory.

Requires: Python 3.6+ (stdlib only).
"""

import argparse
import datetime
import os
import shutil
import sys

EVIDENCE_FILES = [
    "results.json",
    "summary.md",
    "command_log.txt",
    "state.json",
    "metrics.txt",
]


def find_latest_fork_readiness(home):
    """Find the most recent fork_readiness results directory."""
    base = os.path.join(home, "regress", "fork_readiness")
    if not os.path.isdir(base):
        return None
    dirs = sorted([
        d for d in os.listdir(base)
        if os.path.isdir(os.path.join(base, d))
    ])
    if not dirs:
        return None
    return os.path.join(base, dirs[-1]), dirs[-1]


def main():
    parser = argparse.ArgumentParser(
        description="Package fork readiness proof for a single network.")
    parser.add_argument("--home", required=True,
        help="TSUNAGI_HOME path for the network")
    parser.add_argument("--net", required=True,
        help="Network name (mainnet, preview, sancho)")
    parser.add_argument("--output-dir", default="proof",
        help="Output base directory (default: proof)")
    args = parser.parse_args()

    home = args.home
    net = args.net
    output_base = args.output_dir

    if not os.path.isdir(home):
        print(f"ERROR: TSUNAGI_HOME not found: {home}")
        sys.exit(1)

    result = find_latest_fork_readiness(home)
    if not result:
        print(f"ERROR: no fork_readiness results found for {net}")
        print(f"  Expected at: {home}/regress/fork_readiness/")
        print(f"  Run: python3 scripts/fork_readiness_check.py --home {home} --net {net}")
        sys.exit(1)

    results_dir, timestamp = result

    print(f"=== Fork Proof Bundle: {net} ===")
    print(f"  home:      {home}")
    print(f"  results:   {results_dir}")
    print(f"  timestamp: {timestamp}")

    # Create output directory
    out_dir = os.path.join(output_base, net)
    os.makedirs(out_dir, exist_ok=True)

    # Copy evidence files
    copied = 0
    for fname in EVIDENCE_FILES:
        src = os.path.join(results_dir, fname)
        if os.path.isfile(src):
            shutil.copy2(src, os.path.join(out_dir, fname))
            print(f"  + {fname}")
            copied += 1
        else:
            print(f"  - {fname} (not found, skipped)")

    # Write LATEST.txt
    now_utc = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    latest_path = os.path.join(out_dir, "LATEST.txt")
    with open(latest_path, "w") as f:
        f.write(f"network: {net}\n")
        f.write(f"results_timestamp: {timestamp}\n")
        f.write(f"bundle_created: {now_utc}\n")
    print(f"  + LATEST.txt")
    copied += 1

    print()
    print(f"  files: {copied}")
    print(f"  output: {out_dir}/")
    print(f"=== Done: {net} ===")
    print()


if __name__ == "__main__":
    main()
