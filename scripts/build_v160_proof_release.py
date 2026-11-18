#!/usr/bin/env python3
"""Build the v1.6.0 multi-network fork readiness proof release.

Runs make_fork_proof_bundle for mainnet, preview, and sancho, then
aggregates the results into a release-proof-v1.6.0/ directory with
a generated README.md. Creates tsunagi-fork-proof-v1.6.0.zip.

Requires: Python 3.6+ (stdlib only).
"""

import datetime
import json
import os
import platform
import subprocess
import sys
import zipfile

RELEASE_VERSION = "v1.6.0"
RELEASE_DIR = f"release-proof-{RELEASE_VERSION}"
ZIP_NAME = f"tsunagi-fork-proof-{RELEASE_VERSION}.zip"

NETWORKS = [
    {"net": "mainnet", "home_env": "~/tsunagi-home-mainnet"},
    {"net": "preview", "home_env": "~/tsunagi-home-preview"},
    {"net": "sancho",  "home_env": "~/tsunagi-home-sancho"},
]

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
BUNDLE_SCRIPT = os.path.join(SCRIPTS_DIR, "make_fork_proof_bundle.py")


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


def load_results_json(proof_dir, net):
    """Load results.json from a proof directory."""
    path = os.path.join(proof_dir, net, "results.json")
    if not os.path.isfile(path):
        return None
    with open(path) as f:
        return json.load(f)


def generate_readme(proof_dir, results_map):
    """Generate the release README.md."""
    now_utc = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M UTC")
    git_tag = get_git_tag()

    lines = []
    lines.append(f"# Tsunagi {RELEASE_VERSION} — Multi-Network Fork-Ready Proof")
    lines.append("")
    lines.append(f"**Version:** {git_tag}")
    lines.append(f"**Date:** {now_utc}")
    lines.append(f"**Host:** {platform.node()}")
    lines.append("")
    lines.append("---")
    lines.append("")

    # Fork readiness summary
    lines.append("## Fork Readiness Summary")
    lines.append("")
    lines.append("| Network | Status | Tip Slot | Header Vectors | VRF Vectors | Timestamp |")
    lines.append("|---------|--------|----------|---------------|-------------|-----------|")

    for entry in NETWORKS:
        net = entry["net"]
        r = results_map.get(net)
        if not r:
            lines.append(f"| {net} | NO DATA | - | - | - | - |")
            continue
        status = r.get("overall", r.get("overall_status", "UNKNOWN"))
        tip = r.get("runtime_probe", {}).get("tip_slot", "-")
        hdr_count = r.get("alignment", {}).get("header", {}).get("count", 0)
        vrf_count = r.get("alignment", {}).get("vrf", {}).get("count", 0)
        ts = r.get("timestamp_utc", "-")
        if isinstance(ts, str) and len(ts) > 19:
            ts = ts[:19] + "Z"
        lines.append(f"| {net} | {status} | {tip} | {hdr_count} | {vrf_count} | {ts} |")

    lines.append("")

    # Alignment summary
    lines.append("## Alignment Summary")
    lines.append("")
    lines.append("Each network has been tested with independent header hash and VRF alignment vectors")
    lines.append("extracted from live chain captures. Vectors are validated against the Zig-native")
    lines.append("cryptographic harnesses (`header-align`, `vrf-align`).")
    lines.append("")

    for entry in NETWORKS:
        net = entry["net"]
        r = results_map.get(net)
        if not r:
            continue
        al = r.get("alignment", {})
        hdr = al.get("header", {})
        vrf = al.get("vrf", {})
        lines.append(f"**{net}:** header={hdr.get('count', 0)} vectors ({hdr.get('status', '?')}), "
                      f"vrf={vrf.get('count', 0)} vectors ({vrf.get('status', '?')})")

    lines.append("")

    # Offline regressions
    lines.append("## Offline Regression Summary")
    lines.append("")
    lines.append("| Test | mainnet | preview | sancho |")
    lines.append("|------|---------|---------|--------|")

    test_names = ["schedule-regress", "kes-selftest", "praos-regress",
                  "producer-regress", "baey-regress"]
    for test in test_names:
        row = [test]
        for entry in NETWORKS:
            net = entry["net"]
            r = results_map.get(net)
            if r:
                st = r.get("offline", {}).get(test, {}).get("status", "-")
            else:
                st = "-"
            row.append(st)
        lines.append(f"| {row[0]} | {row[1]} | {row[2]} | {row[3]} |")

    lines.append("")

    # How to reproduce
    lines.append("## How to Reproduce")
    lines.append("")
    lines.append("```bash")
    lines.append("# Fork readiness check (per network)")
    lines.append("python3 scripts/fork_readiness_check.py \\")
    lines.append("  --home ~/tsunagi-home-mainnet --net mainnet \\")
    lines.append("  --bin ~/.local/tsunagi/current/bin/tsunagi-node \\")
    lines.append("  --state-url http://127.0.0.1:9080/state \\")
    lines.append("  --metrics-url http://127.0.0.1:9080/metrics")
    lines.append("")
    lines.append("python3 scripts/fork_readiness_check.py \\")
    lines.append("  --home ~/tsunagi-home-preview --net preview \\")
    lines.append("  --bin ~/.local/tsunagi/current/bin/tsunagi-node \\")
    lines.append("  --state-url http://127.0.0.1:9081/state \\")
    lines.append("  --metrics-url http://127.0.0.1:9081/metrics")
    lines.append("")
    lines.append("python3 scripts/fork_readiness_check.py \\")
    lines.append("  --home ~/tsunagi-home-sancho --net sancho \\")
    lines.append("  --bin ~/.local/tsunagi/current/bin/tsunagi-node \\")
    lines.append("  --state-url http://127.0.0.1:9082/state \\")
    lines.append("  --metrics-url http://127.0.0.1:9082/metrics")
    lines.append("")
    lines.append("# Alignment suite (per network)")
    lines.append("python3 scripts/run_alignment_suite.py \\")
    lines.append("  --home ~/tsunagi-home-mainnet")
    lines.append("")
    lines.append("python3 scripts/run_alignment_suite.py \\")
    lines.append("  --home ~/tsunagi-home-preview")
    lines.append("")
    lines.append("python3 scripts/run_alignment_suite.py \\")
    lines.append("  --home ~/tsunagi-home-sancho")
    lines.append("```")
    lines.append("")

    # What this is not
    lines.append("## What This Is Not")
    lines.append("")
    lines.append("No consensus modifications. Harness-only verification.")
    lines.append("")
    lines.append("This proof bundle demonstrates that Tsunagi correctly follows the chain")
    lines.append("and validates headers and VRF proofs against live network data. It does not")
    lines.append("include block forging, transaction broadcast, or mempool injection.")
    lines.append("")

    return "\n".join(lines) + "\n"


def main():
    print(f"=== Building {RELEASE_VERSION} Proof Release ===")
    print()

    # Step 1: Run make_fork_proof_bundle for each network
    proof_dir = os.path.join(RELEASE_DIR, "proof")

    for entry in NETWORKS:
        net = entry["net"]
        home = os.path.expanduser(entry["home_env"])

        if not os.path.isdir(home):
            print(f"WARN: {net} home not found: {home}, skipping")
            continue

        cmd = [
            sys.executable, BUNDLE_SCRIPT,
            "--home", home,
            "--net", net,
            "--output-dir", proof_dir,
        ]
        print(f"--- Bundling {net} ---")
        result = subprocess.run(cmd, timeout=30)
        if result.returncode != 0:
            print(f"ERROR: bundle failed for {net} (exit={result.returncode})")
            sys.exit(1)

    # Step 2: Load results for README generation
    results_map = {}
    for entry in NETWORKS:
        net = entry["net"]
        r = load_results_json(proof_dir, net)
        if r:
            results_map[net] = r

    # Step 3: Generate README.md
    readme_content = generate_readme(proof_dir, results_map)
    readme_path = os.path.join(RELEASE_DIR, "README.md")
    with open(readme_path, "w") as f:
        f.write(readme_content)
    print(f"Generated: {readme_path}")
    print()

    # Step 4: Create zip
    with zipfile.ZipFile(ZIP_NAME, "w", zipfile.ZIP_DEFLATED) as zf:
        for root, dirs, files in os.walk(RELEASE_DIR):
            for fname in sorted(files):
                full = os.path.join(root, fname)
                arcname = os.path.relpath(full, os.path.dirname(RELEASE_DIR))
                zf.write(full, arcname)
                print(f"  + {arcname}")

    size = os.path.getsize(ZIP_NAME)
    print()
    print(f"Output: {ZIP_NAME} ({size:,} bytes)")
    print()

    # Summary
    for entry in NETWORKS:
        net = entry["net"]
        r = results_map.get(net)
        if r:
            print(f"  {net}: {r.get('overall', r.get('overall_status', '?'))}")
        else:
            print(f"  {net}: NO DATA")

    print()
    print(f"=== {RELEASE_VERSION} Proof Release: DONE ===")


if __name__ == "__main__":
    main()
