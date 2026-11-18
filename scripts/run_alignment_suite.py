#!/usr/bin/env python3
"""Run alignment harnesses against captured vectors and produce evidence artifacts.

Outputs:
  results.json   — machine-readable results
  summary.md     — human-readable summary
  command_log.txt — full stdout/stderr from each harness

Requires: Python 3.6+ (stdlib only).
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys

VERSION = "v1.3.2"

# ---------------------------------------------------------------------------
# Environment validation
# ---------------------------------------------------------------------------

def resolve_home(args_home):
    """Resolve TSUNAGI_HOME from --home or environment."""
    if args_home:
        return args_home
    env = os.environ.get("TSUNAGI_HOME")
    if env:
        return env
    return None


def resolve_bin(args_bin):
    """Resolve tsunagi-node binary path."""
    if args_bin:
        if os.path.isfile(args_bin) and os.access(args_bin, os.X_OK):
            return args_bin
        return None
    # Default paths in priority order
    candidates = [
        os.path.expanduser("~/.local/tsunagi/current/bin/tsunagi-node"),
        "./zig-out/bin/tsunagi-node",
        "tsunagi-node/zig-out/bin/tsunagi-node",
    ]
    for c in candidates:
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return os.path.abspath(c)
    return None


def count_lines(path):
    """Count non-empty lines in a file."""
    if not os.path.isfile(path):
        return 0
    with open(path) as f:
        return sum(1 for line in f if line.strip())


def praos_has_null_expected(path):
    """Check if any line in praos vectors has expected_threshold_x1e12 = null."""
    if not os.path.isfile(path):
        return True
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if '"expected_threshold_x1e12":null' in line:
                return True
            if '"expected_threshold_x1e12": null' in line:
                return True
    return False

# ---------------------------------------------------------------------------
# Harness execution
# ---------------------------------------------------------------------------

SUMMARY_RE = re.compile(
    r'vectors=(\d+)\s+mismatches=(\d+)\s+max_abs_delta=(\d+)\s+EXIT=(\d+)')


def run_harness(bin_path, args, label):
    """Run a harness subprocess. Returns (exit_code, stdout, stderr, parsed)."""
    cmd = [bin_path] + args
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=120)
    except FileNotFoundError:
        return (127, "", f"ERROR: binary not found: {bin_path}", None)
    except subprocess.TimeoutExpired:
        return (124, "", "ERROR: harness timed out after 120s", None)

    # Harness output goes to stderr (Zig's std.debug.print)
    output = result.stderr or ""
    parsed = None
    m = SUMMARY_RE.search(output)
    if m:
        parsed = {
            "vectors": int(m.group(1)),
            "mismatches": int(m.group(2)),
            "max_abs_delta": int(m.group(3)),
            "exit_reported": int(m.group(4)),
        }
    return (result.returncode, result.stdout, output, parsed)

# ---------------------------------------------------------------------------
# Results generation
# ---------------------------------------------------------------------------

def build_results(home, bin_path, runs, inputs, timestamp):
    """Build the results.json structure."""
    return {
        "version": VERSION,
        "tsunagi_bin": bin_path,
        "tsunagi_home": home,
        "timestamp_utc": timestamp,
        "inputs": inputs,
        "runs": runs,
    }


def build_summary(results):
    """Build summary.md content."""
    lines = []
    lines.append("# Alignment Suite Results")
    lines.append("")
    lines.append(f"**Version:** {results['version']}")
    lines.append(f"**Timestamp:** {results['timestamp_utc']}")
    lines.append(f"**Binary:** `{results['tsunagi_bin']}`")
    lines.append(f"**TSUNAGI_HOME:** `{results['tsunagi_home']}`")
    lines.append("")
    lines.append("## Inputs")
    lines.append("")
    inp = results["inputs"]
    lines.append(f"| File | Vectors |")
    lines.append(f"|------|---------|")
    lines.append(f"| header_hash.jsonl | {inp['header_vectors']} |")
    lines.append(f"| vrf_u.jsonl | {inp['vrf_vectors']} |")
    lines.append(f"| praos_threshold.jsonl | {inp['praos_vectors']} |")
    lines.append("")
    lines.append("## Results")
    lines.append("")
    lines.append("| Harness | Status | Vectors | Mismatches | Exit |")
    lines.append("|---------|--------|---------|------------|------|")
    for name, run in results["runs"].items():
        status = run.get("status", "?")
        vectors = run.get("vectors", "-")
        mismatches = run.get("mismatches", "-")
        exit_code = run.get("exit", "-")
        lines.append(f"| {name} | {status} | {vectors} | {mismatches} | {exit_code} |")
    lines.append("")

    # Notes
    for name, run in results["runs"].items():
        if run.get("status") == "SKIPPED_EXPECTED_NULL":
            lines.append(
                f"**Note:** `{name}` skipped because "
                "`expected_threshold_x1e12` is null in vectors. "
                "Complete vectors with cardano-node reference values "
                "to enable this harness.")
            lines.append("")

    lines.append("## Commands")
    lines.append("")
    for name, run in results["runs"].items():
        cmd = run.get("command", "")
        lines.append(f"```bash")
        lines.append(f"# {name}")
        lines.append(cmd)
        lines.append(f"```")
        lines.append("")

    return "\n".join(lines)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Run alignment harnesses and produce evidence artifacts.")
    parser.add_argument("--home", default=None,
        help="TSUNAGI_HOME path (default: $TSUNAGI_HOME)")
    parser.add_argument("--bin", default=None,
        help="tsunagi-node binary path")
    parser.add_argument("--min-header", type=int, default=100,
        help="Minimum header vectors required (default: 100)")
    parser.add_argument("--min-vrf", type=int, default=100,
        help="Minimum VRF vectors required (default: 100)")
    parser.add_argument("--out", default=None,
        help="Output directory (default: $home/regress/alignment/results/<timestamp>)")
    args = parser.parse_args()

    timestamp = datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")

    # --- 1. Validate environment ---
    home = resolve_home(args.home)
    if not home or not os.path.isdir(home):
        print(f"ERROR: TSUNAGI_HOME not found: {home}")
        print("  Set TSUNAGI_HOME or use --home")
        sys.exit(4)

    bin_path = resolve_bin(args.bin)
    if not bin_path:
        print("ERROR: tsunagi-node binary not found")
        print("  Checked: ~/.local/tsunagi/current/bin/tsunagi-node")
        print("           ./zig-out/bin/tsunagi-node")
        print("  Use --bin to specify path")
        sys.exit(4)

    vectors_dir = os.path.join(home, "regress", "alignment")
    header_path = os.path.join(vectors_dir, "header_hash.jsonl")
    vrf_path = os.path.join(vectors_dir, "vrf_u.jsonl")
    praos_path = os.path.join(vectors_dir, "praos_threshold.jsonl")

    header_count = count_lines(header_path)
    vrf_count = count_lines(vrf_path)
    praos_count = count_lines(praos_path)

    print(f"=== Alignment Suite ({VERSION}) ===")
    print(f"  home:    {home}")
    print(f"  binary:  {bin_path}")
    print(f"  vectors: {vectors_dir}")
    print(f"  header:  {header_count} lines (min: {args.min_header})")
    print(f"  vrf:     {vrf_count} lines (min: {args.min_vrf})")
    print(f"  praos:   {praos_count} lines")
    print()

    if header_count < args.min_header:
        print(f"ERROR: header vectors ({header_count}) < minimum ({args.min_header})")
        print("  Run: python3 scripts/capture_vectors.py "
              f"--out {vectors_dir} --count {args.min_header}")
        sys.exit(3)

    if vrf_count < args.min_vrf:
        print(f"ERROR: VRF vectors ({vrf_count}) < minimum ({args.min_vrf})")
        print("  Run: python3 scripts/capture_vectors.py "
              f"--out {vectors_dir} --count {args.min_vrf}")
        sys.exit(3)

    # --- 2. Resolve output directory ---
    out_dir = args.out
    if not out_dir:
        out_dir = os.path.join(
            home, "regress", "alignment", "results", timestamp)
    os.makedirs(out_dir, exist_ok=True)

    inputs = {
        "header_vectors": header_count,
        "vrf_vectors": vrf_count,
        "praos_vectors": praos_count,
    }

    runs = {}
    command_log_parts = []
    any_fail = False

    # --- 3A. header-align ---
    print("  running: header-align ...")
    header_cmd = [
        "header-align", "--cardano-header-bytes",
        "--vectors", header_path,
    ]
    header_cmd_str = f"{bin_path} " + " ".join(header_cmd)
    exit_code, stdout, stderr, parsed = run_harness(bin_path, header_cmd, "header-align")

    command_log_parts.append(f"=== header-align ===\n$ {header_cmd_str}\n")
    command_log_parts.append(stderr)
    if stdout:
        command_log_parts.append(stdout)
    command_log_parts.append(f"\nexit: {exit_code}\n\n")

    if parsed and exit_code == 0:
        runs["header_align"] = {
            "status": "PASS",
            "exit": exit_code,
            "vectors": parsed["vectors"],
            "mismatches": parsed["mismatches"],
            "max_abs_delta": parsed["max_abs_delta"],
            "command": header_cmd_str,
        }
        print(f"    PASS  vectors={parsed['vectors']} mismatches={parsed['mismatches']}")
    else:
        any_fail = True
        runs["header_align"] = {
            "status": "FAIL",
            "exit": exit_code,
            "vectors": parsed["vectors"] if parsed else 0,
            "mismatches": parsed["mismatches"] if parsed else -1,
            "command": header_cmd_str,
        }
        print(f"    FAIL  exit={exit_code}")

    # --- 3B. vrf-align ---
    print("  running: vrf-align ...")
    vrf_cmd = ["vrf-align", "--vectors", vrf_path]
    vrf_cmd_str = f"{bin_path} " + " ".join(vrf_cmd)
    exit_code, stdout, stderr, parsed = run_harness(bin_path, vrf_cmd, "vrf-align")

    command_log_parts.append(f"=== vrf-align ===\n$ {vrf_cmd_str}\n")
    command_log_parts.append(stderr)
    if stdout:
        command_log_parts.append(stdout)
    command_log_parts.append(f"\nexit: {exit_code}\n\n")

    if parsed and exit_code == 0:
        runs["vrf_align"] = {
            "status": "PASS",
            "exit": exit_code,
            "vectors": parsed["vectors"],
            "mismatches": parsed["mismatches"],
            "max_abs_delta": parsed["max_abs_delta"],
            "command": vrf_cmd_str,
        }
        print(f"    PASS  vectors={parsed['vectors']} mismatches={parsed['mismatches']}")
    else:
        any_fail = True
        runs["vrf_align"] = {
            "status": "FAIL",
            "exit": exit_code,
            "vectors": parsed["vectors"] if parsed else 0,
            "mismatches": parsed["mismatches"] if parsed else -1,
            "command": vrf_cmd_str,
        }
        print(f"    FAIL  exit={exit_code}")

    # --- 3C. praos-align ---
    print("  running: praos-align ...")
    if praos_count == 0:
        runs["praos_align"] = {
            "status": "SKIPPED_NO_VECTORS",
            "exit": -1,
            "vectors": 0,
            "mismatches": 0,
            "command": "(skipped: no vectors)",
        }
        print("    SKIPPED (no vectors)")
        command_log_parts.append("=== praos-align ===\n(skipped: no vectors)\n\n")
    elif praos_has_null_expected(praos_path):
        runs["praos_align"] = {
            "status": "SKIPPED_EXPECTED_NULL",
            "exit": -1,
            "vectors": praos_count,
            "mismatches": 0,
            "command": "(skipped: expected_threshold_x1e12 is null)",
        }
        print(f"    SKIPPED_EXPECTED_NULL ({praos_count} vectors, expected=null)")
        command_log_parts.append(
            "=== praos-align ===\n"
            "(skipped: expected_threshold_x1e12 is null in vectors)\n\n")
    else:
        praos_cmd = ["praos-align", "--vectors", praos_path]
        praos_cmd_str = f"{bin_path} " + " ".join(praos_cmd)
        exit_code, stdout, stderr, parsed = run_harness(
            bin_path, praos_cmd, "praos-align")

        command_log_parts.append(f"=== praos-align ===\n$ {praos_cmd_str}\n")
        command_log_parts.append(stderr)
        if stdout:
            command_log_parts.append(stdout)
        command_log_parts.append(f"\nexit: {exit_code}\n\n")

        if parsed and exit_code == 0:
            runs["praos_align"] = {
                "status": "PASS",
                "exit": exit_code,
                "vectors": parsed["vectors"],
                "mismatches": parsed["mismatches"],
                "max_abs_delta": parsed["max_abs_delta"],
                "command": praos_cmd_str,
            }
            print(f"    PASS  vectors={parsed['vectors']} "
                  f"mismatches={parsed['mismatches']}")
        else:
            any_fail = True
            runs["praos_align"] = {
                "status": "FAIL",
                "exit": exit_code,
                "vectors": parsed["vectors"] if parsed else 0,
                "mismatches": parsed["mismatches"] if parsed else -1,
                "command": praos_cmd_str,
            }
            print(f"    FAIL  exit={exit_code}")

    # --- 4. Write results ---
    print()
    results = build_results(home, bin_path, runs, inputs, timestamp)

    results_path = os.path.join(out_dir, "results.json")
    with open(results_path, "w") as f:
        json.dump(results, f, indent=2)
        f.write("\n")
    print(f"  wrote: {results_path}")

    summary_path = os.path.join(out_dir, "summary.md")
    with open(summary_path, "w") as f:
        f.write(build_summary(results))
    print(f"  wrote: {summary_path}")

    log_path = os.path.join(out_dir, "command_log.txt")
    with open(log_path, "w") as f:
        f.write("".join(command_log_parts))
    print(f"  wrote: {log_path}")

    # --- 5. Final status ---
    print()
    if any_fail:
        print("=== Alignment Suite: FAIL ===")
        sys.exit(2)
    else:
        print("=== Alignment Suite: PASS ===")
        sys.exit(0)


if __name__ == "__main__":
    main()
