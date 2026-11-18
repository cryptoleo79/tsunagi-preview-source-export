#!/usr/bin/env python3
"""Bootstrap a new network TSUNAGI_HOME with regress baselines and alignment vectors.

Creates required directories, initializes regression baselines, captures alignment
vectors from block captures (if available), and runs the alignment suite.

Python 3 stdlib only — no external dependencies.
"""

import argparse
import os
import subprocess
import sys


def run_cmd(args, env=None, timeout=300):
    """Run a command, print output, return exit code."""
    merged_env = dict(os.environ)
    if env:
        merged_env.update(env)
    try:
        proc = subprocess.run(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=merged_env,
            timeout=timeout,
        )
        output = proc.stdout.decode("utf-8", errors="replace")
        if output.strip():
            for line in output.rstrip().splitlines():
                print(f"    {line}")
        return proc.returncode
    except FileNotFoundError:
        print(f"    ERROR: command not found: {args[0]}")
        return 127
    except subprocess.TimeoutExpired:
        print(f"    ERROR: timeout after {timeout}s")
        return 124


def main():
    parser = argparse.ArgumentParser(
        description="Bootstrap a new network TSUNAGI_HOME with baselines and vectors.",
    )
    parser.add_argument(
        "--home", required=True,
        help="TSUNAGI_HOME directory to bootstrap",
    )
    parser.add_argument(
        "--net", required=True,
        choices=["mainnet", "preprod", "preview", "sancho"],
        help="Network name",
    )
    parser.add_argument(
        "--bin", default=None,
        help="Path to tsunagi-node binary (auto-detected if omitted)",
    )
    parser.add_argument(
        "--count", type=int, default=120,
        help="Number of alignment vectors to capture (default: 120)",
    )
    args = parser.parse_args()

    home = os.path.abspath(args.home)
    scripts_dir = os.path.dirname(os.path.abspath(__file__))

    # Resolve binary
    bin_path = args.bin
    if bin_path:
        bin_path = os.path.abspath(bin_path)
    else:
        candidates = [
            os.path.expanduser("~/.local/tsunagi/current/bin/tsunagi-node"),
            os.path.join(scripts_dir, "..", "tsunagi-node", "zig-out", "bin", "tsunagi-node"),
            os.path.join(scripts_dir, "..", "zig-out", "bin", "tsunagi-node"),
        ]
        for c in candidates:
            c = os.path.abspath(c)
            if os.path.isfile(c) and os.access(c, os.X_OK):
                bin_path = c
                break
    if not bin_path or not os.path.isfile(bin_path):
        print(f"ERROR: tsunagi-node binary not found. Use --bin to specify.")
        sys.exit(1)

    print(f"[bootstrap] net={args.net} home={home}")
    print(f"  binary: {bin_path}")
    print()

    env = {"TSUNAGI_HOME": home}

    # --- A) Ensure dirs ---
    print("[A] Ensuring directories...")
    for d in [
        os.path.join(home, "regress"),
        os.path.join(home, "regress", "alignment"),
        os.path.join(home, "regress", "alignment", "results"),
    ]:
        os.makedirs(d, exist_ok=True)
        print(f"    {d}")
    print()

    # --- B) Initialize baselines ---
    print("[B] Initializing regression baselines...")
    baselines_created = False

    # schedule-regress and kes-selftest are global (no baseline needed)
    print("  schedule-regress (global, no baseline):")
    rc = run_cmd([bin_path, "schedule-regress"], env=env)
    print(f"    -> {'PASS' if rc == 0 else 'FAIL'}")
    print()

    print("  kes-selftest (global, no baseline):")
    rc = run_cmd([bin_path, "kes-selftest"], env=env)
    print(f"    -> {'PASS' if rc == 0 else 'FAIL'}")
    print()

    # praos-regress
    baseline_path = os.path.join(home, "regress", "praos_baseline.json")
    if os.path.isfile(baseline_path):
        print("  praos-regress: baseline already exists, skipping init")
    else:
        print("  praos-regress --init-baseline:")
        rc = run_cmd([bin_path, "praos-regress", "--init-baseline"], env=env)
        if rc == 0:
            baselines_created = True
            print(f"    -> CREATED")
        else:
            print(f"    -> FAILED (exit={rc})")
    print()

    # producer-regress
    baseline_path = os.path.join(home, "regress", "producer_baseline.json")
    if os.path.isfile(baseline_path):
        print("  producer-regress: baseline already exists, skipping init")
    else:
        print("  producer-regress --init-baseline:")
        rc = run_cmd([bin_path, "producer-regress", "--init-baseline"], env=env)
        if rc == 0:
            baselines_created = True
            print(f"    -> CREATED")
        else:
            print(f"    -> FAILED (exit={rc})")
    print()

    # baey-regress
    baseline_path = os.path.join(home, "regress", "baey_baseline.json")
    if os.path.isfile(baseline_path):
        print("  baey-regress: baseline already exists, skipping init")
    else:
        print("  baey-regress --seed 1 --init-baseline:")
        rc = run_cmd([bin_path, "baey-regress", "--seed", "1", "--init-baseline"], env=env)
        if rc == 0:
            baselines_created = True
            print(f"    -> CREATED")
        else:
            print(f"    -> FAILED (exit={rc})")
    print()

    # --- C) Capture vectors ---
    print("[C] Capturing alignment vectors...")
    capture_dir = os.path.join(home, "captures")
    vectors_dir = os.path.join(home, "regress", "alignment")
    capture_script = os.path.join(scripts_dir, "capture_vectors.py")

    header_path = os.path.join(vectors_dir, "header_hash.jsonl")
    vrf_path = os.path.join(vectors_dir, "vrf_u.jsonl")
    vectors_created = {"header": 0, "vrf": 0}

    if os.path.isfile(header_path) and os.path.isfile(vrf_path):
        # Count existing vectors
        with open(header_path) as f:
            vectors_created["header"] = sum(1 for _ in f)
        with open(vrf_path) as f:
            vectors_created["vrf"] = sum(1 for _ in f)
        print(f"  vectors already exist: header={vectors_created['header']} vrf={vectors_created['vrf']}")
        if vectors_created["header"] >= args.count and vectors_created["vrf"] >= args.count:
            print("  sufficient vectors, skipping capture")
        else:
            print("  insufficient vectors, re-capturing...")
            if os.path.isdir(capture_dir) and os.path.isfile(capture_script):
                rc = run_cmd(
                    [sys.executable, capture_script,
                     "--capture-dir", capture_dir,
                     "--out", vectors_dir,
                     "--count", str(args.count),
                     "--mode", args.net],
                    env=env,
                )
                if rc == 0:
                    with open(header_path) as f:
                        vectors_created["header"] = sum(1 for _ in f)
                    with open(vrf_path) as f:
                        vectors_created["vrf"] = sum(1 for _ in f)
                else:
                    print(f"    capture_vectors.py failed (exit={rc})")
            else:
                if not os.path.isdir(capture_dir):
                    print(f"  no captures directory: {capture_dir}")
                if not os.path.isfile(capture_script):
                    print(f"  capture script missing: {capture_script}")
                print("  vectors will need to be captured after node runs and captures blocks")
    elif os.path.isdir(capture_dir) and os.path.isfile(capture_script):
        cap_files = [f for f in os.listdir(capture_dir) if f.endswith(".bin")]
        if cap_files:
            rc = run_cmd(
                [sys.executable, capture_script,
                 "--capture-dir", capture_dir,
                 "--out", vectors_dir,
                 "--count", str(args.count),
                 "--mode", args.net],
                env=env,
            )
            if rc == 0:
                if os.path.isfile(header_path):
                    with open(header_path) as f:
                        vectors_created["header"] = sum(1 for _ in f)
                if os.path.isfile(vrf_path):
                    with open(vrf_path) as f:
                        vectors_created["vrf"] = sum(1 for _ in f)
            else:
                print(f"    capture_vectors.py failed (exit={rc})")
        else:
            print(f"  no .bin files in {capture_dir}")
            print("  vectors will need to be captured after node runs and captures blocks")
    else:
        if not os.path.isdir(capture_dir):
            print(f"  no captures directory: {capture_dir}")
        print("  vectors will need to be captured after node runs and captures blocks")
    print()

    # --- D) Run alignment suite ---
    print("[D] Running alignment suite...")
    suite_script = os.path.join(scripts_dir, "run_alignment_suite.py")
    suite_status = "SKIP"

    if vectors_created["header"] > 0 and vectors_created["vrf"] > 0:
        if os.path.isfile(suite_script):
            rc = run_cmd(
                [sys.executable, suite_script,
                 "--home", home,
                 "--bin", bin_path,
                 "--min-header", str(min(vectors_created["header"], args.count)),
                 "--min-vrf", str(min(vectors_created["vrf"], args.count))],
                env=env,
            )
            suite_status = "PASS" if rc == 0 else "FAIL"
        else:
            print(f"  suite script missing: {suite_script}")
            suite_status = "SKIP"
    else:
        print("  no vectors available, skipping alignment suite")
        suite_status = "SKIP"
    print()

    # --- E) Summary ---
    print("=" * 50)
    print(f"[bootstrap] Summary for {args.net}")
    print(f"  TSUNAGI_HOME:     {home}")
    print(f"  baselines_created: {'yes' if baselines_created else 'no (already existed or failed)'}")
    print(f"  vectors_created:   header={vectors_created['header']} vrf={vectors_created['vrf']}")
    print(f"  suite_status:      {suite_status}")
    print()

    # Check baselines exist
    all_baselines = True
    for name in ["praos_baseline.json", "producer_baseline.json", "baey_baseline.json"]:
        p = os.path.join(home, "regress", name)
        exists = os.path.isfile(p)
        if not exists:
            all_baselines = False
        print(f"  {name}: {'exists' if exists else 'MISSING'}")

    print()
    if all_baselines and vectors_created["header"] > 0 and suite_status == "PASS":
        print("[bootstrap] READY — fork_readiness_check.py should report PASS")
    elif all_baselines:
        print("[bootstrap] PARTIAL — baselines ready, vectors may need capture after node runs")
        print("  fork_readiness_check.py will report WARN until vectors are sufficient")
    else:
        print("[bootstrap] INCOMPLETE — check errors above")

    sys.exit(0)


if __name__ == "__main__":
    main()
