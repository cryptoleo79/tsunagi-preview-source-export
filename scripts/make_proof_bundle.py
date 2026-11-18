#!/usr/bin/env python3
"""Package alignment proof evidence into a distributable zip bundle.

Reads the latest alignment suite results and bundles them with metadata
into a single zip file for attachment to release notes.

Requires: Python 3.6+ (stdlib only).
"""

import argparse
import datetime
import json
import os
import platform
import subprocess
import sys
import zipfile

BUNDLE_VERSION = "v1.4.0"


def find_latest_results(home):
    """Find the most recent results directory."""
    results_base = os.path.join(home, "regress", "alignment", "results")
    if not os.path.isdir(results_base):
        return None
    dirs = sorted([
        d for d in os.listdir(results_base)
        if os.path.isdir(os.path.join(results_base, d))
    ])
    if not dirs:
        return None
    return os.path.join(results_base, dirs[-1])


def get_git_tag():
    """Get current git tag, or 'unknown'."""
    try:
        result = subprocess.run(
            ["git", "describe", "--tags", "--always"],
            capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            return result.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return "unknown"


def main():
    parser = argparse.ArgumentParser(
        description="Package alignment proof bundle.")
    parser.add_argument("--home", default=None,
        help="TSUNAGI_HOME path (default: $TSUNAGI_HOME)")
    parser.add_argument("--output", default=None,
        help="Output zip path (default: tsunagi-alignment-proof-v1.4.0.zip)")
    args = parser.parse_args()

    home = args.home or os.environ.get("TSUNAGI_HOME")
    if not home or not os.path.isdir(home):
        print(f"ERROR: TSUNAGI_HOME not found: {home}")
        sys.exit(1)

    results_dir = find_latest_results(home)
    if not results_dir:
        print("ERROR: no alignment results found")
        print(f"  Expected at: {home}/regress/alignment/results/")
        print("  Run: python3 scripts/run_alignment_suite.py --home $TSUNAGI_HOME")
        sys.exit(1)

    print(f"=== Make Proof Bundle ===")
    print(f"  home:    {home}")
    print(f"  results: {results_dir}")
    print()

    # Read results.json for metadata
    results_path = os.path.join(results_dir, "results.json")
    if not os.path.isfile(results_path):
        print(f"ERROR: results.json not found in {results_dir}")
        sys.exit(1)

    with open(results_path) as f:
        results = json.load(f)

    # Build metadata
    header_run = results.get("runs", {}).get("header_align", {})
    vrf_run = results.get("runs", {}).get("vrf_align", {})
    praos_run = results.get("runs", {}).get("praos_align", {})

    metadata = {
        "tsunagi_version": get_git_tag(),
        "bundle_version": BUNDLE_VERSION,
        "timestamp_utc": datetime.datetime.utcnow().strftime(
            "%Y-%m-%dT%H:%M:%SZ"),
        "results_timestamp": results.get("timestamp_utc", "unknown"),
        "header_vectors": header_run.get("vectors", 0),
        "header_status": header_run.get("status", "UNKNOWN"),
        "vrf_vectors": vrf_run.get("vectors", 0),
        "vrf_status": vrf_run.get("status", "UNKNOWN"),
        "praos_vectors": praos_run.get("vectors", 0),
        "praos_status": praos_run.get("status", "UNKNOWN"),
        "binary_path": results.get("tsunagi_bin", "unknown"),
        "host": platform.node(),
    }

    # Bundle files
    bundle_files = {
        "results.json": results_path,
        "summary.md": os.path.join(results_dir, "summary.md"),
        "command_log.txt": os.path.join(results_dir, "command_log.txt"),
    }

    # Verify all files exist
    for name, path in bundle_files.items():
        if not os.path.isfile(path):
            print(f"ERROR: missing {name} at {path}")
            sys.exit(1)

    # Create zip
    output = args.output or f"tsunagi-alignment-proof-{BUNDLE_VERSION}.zip"
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as zf:
        # Add metadata
        zf.writestr("metadata.json",
                     json.dumps(metadata, indent=2) + "\n")
        print(f"  + metadata.json")

        # Add result files
        for name, path in bundle_files.items():
            zf.write(path, name)
            print(f"  + {name}")

    size = os.path.getsize(output)
    print()
    print(f"  output: {output} ({size:,} bytes)")
    print()

    # Summary
    print(f"  header: {metadata['header_status']} "
          f"({metadata['header_vectors']} vectors)")
    print(f"  vrf:    {metadata['vrf_status']} "
          f"({metadata['vrf_vectors']} vectors)")
    print(f"  praos:  {metadata['praos_status']} "
          f"({metadata['praos_vectors']} vectors)")
    print()
    print("=== Proof Bundle: DONE ===")


if __name__ == "__main__":
    main()
