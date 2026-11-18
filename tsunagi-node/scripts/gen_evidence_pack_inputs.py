#!/usr/bin/env python3
"""
gen_evidence_pack_inputs.py — Generate both consensus and readiness vectors
for evidence-pack in a single invocation.

Calls gen_consensus_vectors.py and gen_readiness_sim_vectors.py in sequence.
Python 3.6+ stdlib-only. No secrets.

Usage:
  python3 gen_evidence_pack_inputs.py \
    --net preview \
    --home /path/to/tsunagi_home \
    --out-dir /tmp/evidence_inputs \
    [--limit 50]
"""

import argparse
import os
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(
        description="Generate evidence-pack input vectors")
    parser.add_argument("--net", required=True,
                        help="Network: preview, preprod, mainnet, sancho")
    parser.add_argument("--home", required=True,
                        help="TSUNAGI_HOME path")
    parser.add_argument("--out-dir", required=True,
                        help="Output directory for vector files")
    parser.add_argument("--limit", type=int, default=50,
                        help="Max vectors to extract (default: 50)")
    args = parser.parse_args()

    blocks_dir = os.path.join(args.home, "producer_dryrun", "blocks")
    alignment_file = os.path.join(
        args.home, "regress", "alignment", "header_hash.jsonl")
    use_alignment = False

    if not os.path.isdir(blocks_dir):
        if os.path.isfile(alignment_file):
            print(f"blocks/ not found, using alignment fallback: {alignment_file}", file=sys.stderr)
            use_alignment = True
        else:
            print(f"ERROR: no blocks directory and no alignment file",
                  file=sys.stderr)
            print(f"  tried: {blocks_dir}", file=sys.stderr)
            print(f"  tried: {alignment_file}", file=sys.stderr)
            sys.exit(1)

    os.makedirs(args.out_dir, exist_ok=True)

    # Locate scripts relative to this file
    this_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(this_dir)  # tsunagi-node/
    repo_parent = os.path.dirname(repo_root)  # tsunagi-follower/

    consensus_script = os.path.join(this_dir, "gen_consensus_vectors.py")
    readiness_script = os.path.join(
        repo_parent, "scripts", "gen_readiness_sim_vectors.py")

    if not os.path.isfile(consensus_script):
        print(f"ERROR: not found: {consensus_script}", file=sys.stderr)
        sys.exit(1)
    if not os.path.isfile(readiness_script):
        print(f"ERROR: not found: {readiness_script}", file=sys.stderr)
        sys.exit(1)

    # Generate consensus vectors
    cons_out = os.path.join(args.out_dir, "consensus_vectors.jsonl")
    if use_alignment:
        print(f"Generating consensus vectors (alignment): {cons_out}", file=sys.stderr)
        rc = subprocess.call([
            sys.executable, consensus_script,
            "--mode", "alignment",
            "--alignment-file", alignment_file,
            "--out", cons_out,
            "--net", args.net,
            "--limit", str(args.limit),
        ])
    else:
        print(f"Generating consensus vectors (header): {cons_out}", file=sys.stderr)
        rc = subprocess.call([
            sys.executable, consensus_script,
            "--mode", "header",
            "--artifacts-dir", blocks_dir,
            "--out", cons_out,
            "--net", args.net,
            "--limit", str(args.limit),
        ])
    if rc != 0:
        print(f"ERROR: gen_consensus_vectors.py exited {rc}", file=sys.stderr)
        sys.exit(rc)

    # Generate readiness vectors
    read_out = os.path.join(args.out_dir, "readiness_vectors.jsonl")
    if use_alignment:
        print(f"Generating readiness vectors (alignment): {read_out}", file=sys.stderr)
        rc = subprocess.call([
            sys.executable, readiness_script,
            "--mode", "alignment",
            "--alignment-file", alignment_file,
            "--net", args.net,
            "--out", read_out,
            "--limit", str(args.limit),
        ])
    else:
        print(f"Generating readiness vectors (blocks): {read_out}", file=sys.stderr)
        rc = subprocess.call([
            sys.executable, readiness_script,
            "--net", args.net,
            "--mode", "blocks",
            "--blocks-dir", blocks_dir,
            "--out", read_out,
            "--limit", str(args.limit),
        ])
    if rc != 0:
        print(f"ERROR: gen_readiness_sim_vectors.py exited {rc}",
              file=sys.stderr)
        sys.exit(rc)

    # Summary
    cons_lines = sum(1 for _ in open(cons_out)) if os.path.isfile(cons_out) else 0
    read_lines = sum(1 for _ in open(read_out)) if os.path.isfile(read_out) else 0
    print(f"Done: consensus={cons_lines} readiness={read_lines} out={args.out_dir}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
