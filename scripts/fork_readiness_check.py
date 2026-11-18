#!/usr/bin/env python3
"""Tsunagi fork-readiness checklist runner.

Produces a timestamped evidence bundle (results.json, summary.md, command_log.txt)
under TSUNAGI_HOME/regress/fork_readiness/<timestamp>/.

Python 3 stdlib only — no external dependencies.
"""

import argparse
import datetime
import json
import os
import subprocess
import sys
import textwrap
import urllib.error
import urllib.request


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def utc_now():
    return datetime.datetime.now(datetime.timezone.utc)


def ts_dir_name(dt):
    return dt.strftime("%Y%m%dT%H%M%SZ")


def run_cmd(args, env=None, timeout=300):
    """Run a command, return (exit_code, stdout+stderr)."""
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
        return proc.returncode, proc.stdout.decode("utf-8", errors="replace")
    except FileNotFoundError:
        return 127, f"command not found: {args[0]}"
    except subprocess.TimeoutExpired:
        return 124, f"timeout after {timeout}s"


def fetch_url(url, timeout=15):
    """Fetch a URL, return (ok, body_str)."""
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return True, resp.read().decode("utf-8", errors="replace")
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return False, str(exc)


# ---------------------------------------------------------------------------
# Checklist steps
# ---------------------------------------------------------------------------

class ChecklistRunner:
    def __init__(self, args):
        self.home = os.path.abspath(args.home)
        self.bin = os.path.abspath(args.bin)
        self.net = args.net
        self.state_url = args.state_url
        self.metrics_url = args.metrics_url
        self.min_header = args.min_header
        self.min_vrf = args.min_vrf
        self.now = utc_now()
        self.ts = ts_dir_name(self.now)
        self.out_dir = os.path.join(
            self.home, "regress", "fork_readiness", self.ts
        )
        self.cmd_log = []
        self.results = {
            "net": self.net,
            "tsunagi_home": self.home,
            "tsunagi_bin": self.bin,
            "timestamp_utc": self.now.isoformat(),
            "version": None,
            "offline": {},
            "alignment": {},
            "runtime_probe": {},
            "overall": "FAIL",
        }

    # -- A) Environment validation ------------------------------------------

    def validate_env(self):
        errors = []
        if not os.path.isdir(self.home):
            errors.append(f"TSUNAGI_HOME does not exist: {self.home}")
        if not os.path.isfile(self.bin):
            errors.append(f"tsunagi-node binary not found: {self.bin}")
        elif not os.access(self.bin, os.X_OK):
            errors.append(f"tsunagi-node binary not executable: {self.bin}")

        # Create output dirs
        os.makedirs(self.out_dir, exist_ok=True)

        # Detect version
        rc, out = run_cmd([self.bin, "--version"], timeout=10)
        if rc == 0 and out.strip():
            self.results["version"] = out.strip().splitlines()[0]
        else:
            # Try git tag from source dir
            src_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            rc2, out2 = run_cmd(["git", "-C", src_dir, "describe", "--tags", "--always"], timeout=10)
            if rc2 == 0 and out2.strip():
                self.results["version"] = out2.strip()

        return errors

    # -- B) Offline regressions ---------------------------------------------

    # Checks that need a baseline file in TSUNAGI_HOME/regress/
    BASELINE_CHECKS = {
        "praos-regress": "praos_baseline.json",
        "producer-regress": "producer_baseline.json",
        "baey-regress": "baey_baseline.json",
    }

    def run_offline_regressions(self):
        env = {"TSUNAGI_HOME": self.home}
        checks = [
            ("schedule-regress", [self.bin, "schedule-regress"]),
            ("kes-selftest", [self.bin, "kes-selftest"]),
            ("praos-regress", [self.bin, "praos-regress"]),
            ("producer-regress", [self.bin, "producer-regress"]),
            ("baey-regress", [self.bin, "baey-regress"]),
        ]
        all_pass = True
        for name, cmd in checks:
            # Check if baseline is required but missing
            baseline_file = self.BASELINE_CHECKS.get(name)
            if baseline_file:
                baseline_path = os.path.join(self.home, "regress", baseline_file)
                if not os.path.isfile(baseline_path):
                    self.results["offline"][name] = {
                        "status": "SKIP_NO_BASELINE",
                        "exit": -1,
                        "reason": f"baseline missing: {baseline_file}",
                    }
                    self._log_cmd(name, cmd, -1,
                                  f"SKIPPED: baseline not found at {baseline_path}\n"
                                  f"Run: bootstrap_network_home.py or "
                                  f"tsunagi-node {name} --init-baseline\n")
                    continue

            rc, out = run_cmd(cmd, env=env)
            status = "PASS" if rc == 0 else "FAIL"
            self.results["offline"][name] = {"status": status, "exit": rc}
            self._log_cmd(name, cmd, rc, out)
            if rc != 0:
                all_pass = False
        return all_pass

    # -- C) Alignment suite -------------------------------------------------

    def run_alignment(self):
        alignment_dir = os.path.join(self.home, "regress", "alignment")
        header_vectors = os.path.join(alignment_dir, "header_hash.jsonl")
        vrf_vectors = os.path.join(alignment_dir, "vrf_u.jsonl")
        env = {"TSUNAGI_HOME": self.home}

        # Header alignment
        self.results["alignment"]["header"] = self._run_alignment_check(
            "header-align",
            [self.bin, "header-align", "--cardano-header-bytes", "--vectors", header_vectors],
            header_vectors,
            self.min_header,
            env,
        )

        # VRF alignment
        self.results["alignment"]["vrf"] = self._run_alignment_check(
            "vrf-align",
            [self.bin, "vrf-align", "--vectors", vrf_vectors],
            vrf_vectors,
            self.min_vrf,
            env,
        )

    def _run_alignment_check(self, name, cmd, vectors_path, min_count, env):
        if not os.path.isfile(vectors_path):
            return {"status": "INSUFFICIENT_VECTORS", "count": 0, "reason": "vectors file missing"}

        count = 0
        with open(vectors_path, "r") as f:
            for _ in f:
                count += 1

        if count < min_count:
            return {
                "status": "INSUFFICIENT_VECTORS",
                "count": count,
                "reason": f"need >= {min_count}, have {count}",
            }

        rc, out = run_cmd(cmd, env=env)
        status = "PASS" if rc == 0 else "FAIL"
        self._log_cmd(name, cmd, rc, out)
        return {"status": status, "exit": rc, "count": count}

    # -- D) Runtime health probe --------------------------------------------

    def run_runtime_probe(self):
        probe = {"fetched": False, "key_checks": {}}

        if self.state_url:
            ok, body = fetch_url(self.state_url)
            if ok:
                probe["fetched"] = True
                # Save raw
                state_path = os.path.join(self.out_dir, "state.json")
                with open(state_path, "w") as f:
                    f.write(body)

                # Parse and check keys
                try:
                    data = json.loads(body)
                    required_keys = [
                        "state_schema_version",
                        "producer_state_digest",
                        "producer_praos",
                        "producer_kes_period",
                    ]
                    optional_keys = ["baey_schema_version"]

                    for k in required_keys:
                        probe["key_checks"][k] = "PRESENT" if k in data else "MISSING"
                    for k in optional_keys:
                        if k in data:
                            probe["key_checks"][k] = "PRESENT"

                    # Record reference values
                    if "tip" in data and "slot" in data["tip"]:
                        probe["tip_slot"] = data["tip"]["slot"]
                    if "producer_state_digest" in data:
                        probe["producer_state_digest"] = data["producer_state_digest"]

                except json.JSONDecodeError:
                    probe["key_checks"]["_parse"] = "FAIL"
            else:
                probe["state_error"] = body

        if self.metrics_url:
            ok, body = fetch_url(self.metrics_url)
            if ok:
                metrics_path = os.path.join(self.out_dir, "metrics.txt")
                with open(metrics_path, "w") as f:
                    f.write(body)

                # Check required prefixes
                required_prefixes = [
                    "tsunagi_state_schema_version",
                    "tsunagi_peer_alpha",
                    "tsunagi_producer_schedule_",
                    "tsunagi_praos_",
                    "tsunagi_kes_",
                ]
                lines = body.splitlines()
                prefix_counts = {}
                for prefix in required_prefixes:
                    count = sum(
                        1 for line in lines
                        if line.startswith(prefix) and not line.startswith("#")
                    )
                    prefix_counts[prefix] = count
                probe["metrics_prefix_counts"] = prefix_counts
            else:
                probe["metrics_error"] = body

        self.results["runtime_probe"] = probe

    # -- E) Evidence packaging ----------------------------------------------

    def compute_overall(self):
        # FAIL only if an executed regression truly fails (not skipped)
        has_skip = False
        for name, info in self.results["offline"].items():
            if info["status"] == "FAIL":
                self.results["overall"] = "FAIL"
                return
            if info["status"] == "SKIP_NO_BASELINE":
                has_skip = True

        # Check alignment
        alignment_pass = True
        alignment_insufficient = False
        for name, info in self.results["alignment"].items():
            if info["status"] == "FAIL":
                self.results["overall"] = "FAIL"
                return
            if info["status"] == "INSUFFICIENT_VECTORS":
                alignment_insufficient = True
            if info["status"] != "PASS":
                alignment_pass = False

        # WARN if baselines missing, alignment insufficient, or runtime probe missing
        if has_skip or alignment_insufficient or not alignment_pass:
            self.results["overall"] = "WARN"
            return

        probe = self.results["runtime_probe"]
        if self.state_url and not probe.get("fetched"):
            self.results["overall"] = "WARN"
            return

        # Check for MISSING required state keys
        for k, v in probe.get("key_checks", {}).items():
            if v == "MISSING":
                self.results["overall"] = "WARN"
                return

        self.results["overall"] = "PASS"

    def write_results(self):
        # results.json
        results_path = os.path.join(self.out_dir, "results.json")
        with open(results_path, "w") as f:
            json.dump(self.results, f, indent=2)
            f.write("\n")

        # command_log.txt
        log_path = os.path.join(self.out_dir, "command_log.txt")
        with open(log_path, "w") as f:
            f.write("".join(self.cmd_log))

        # summary.md
        summary_path = os.path.join(self.out_dir, "summary.md")
        with open(summary_path, "w") as f:
            f.write(self._build_summary())

    def _build_summary(self):
        r = self.results
        lines = []
        lines.append(f"# Fork Readiness Report: {r['net']}")
        lines.append("")
        lines.append(f"**Timestamp:** {r['timestamp_utc']}")
        lines.append(f"**TSUNAGI_HOME:** `{r['tsunagi_home']}`")
        if r.get("version"):
            lines.append(f"**Version:** {r['version']}")
        lines.append(f"**Overall:** **{r['overall']}**")
        lines.append("")

        # Offline regressions table
        lines.append("## Offline Regressions")
        lines.append("")
        lines.append("| Check | Status | Exit |")
        lines.append("|-------|--------|------|")
        for name, info in r["offline"].items():
            lines.append(f"| {name} | {info['status']} | {info['exit']} |")
        lines.append("")

        # Alignment table
        lines.append("## Alignment Suite")
        lines.append("")
        lines.append("| Check | Status | Vectors |")
        lines.append("|-------|--------|---------|")
        for name, info in r["alignment"].items():
            count = info.get("count", "n/a")
            status = info["status"]
            extra = ""
            if info.get("reason"):
                extra = f" ({info['reason']})"
            lines.append(f"| {name} | {status}{extra} | {count} |")
        lines.append("")

        # Runtime probe
        if r["runtime_probe"]:
            lines.append("## Runtime Health Probe")
            lines.append("")
            probe = r["runtime_probe"]
            lines.append(f"- State fetched: {probe.get('fetched', False)}")
            if probe.get("tip_slot"):
                lines.append(f"- Tip slot: {probe['tip_slot']}")
            if probe.get("producer_state_digest"):
                lines.append(f"- Producer state digest: `{probe['producer_state_digest']}`")
            if probe.get("key_checks"):
                lines.append("")
                lines.append("| Key | Status |")
                lines.append("|-----|--------|")
                for k, v in probe["key_checks"].items():
                    lines.append(f"| {k} | {v} |")
            if probe.get("metrics_prefix_counts"):
                lines.append("")
                lines.append("| Metrics Prefix | Count |")
                lines.append("|----------------|-------|")
                for prefix, count in probe["metrics_prefix_counts"].items():
                    lines.append(f"| `{prefix}` | {count} |")
            if probe.get("state_error"):
                lines.append(f"- State fetch error: {probe['state_error']}")
            if probe.get("metrics_error"):
                lines.append(f"- Metrics fetch error: {probe['metrics_error']}")
            lines.append("")

        # Warnings
        warnings = []
        for name, info in r["offline"].items():
            if info["status"] == "SKIP_NO_BASELINE":
                warnings.append(f"Regression '{name}': {info.get('reason', 'baseline missing')}")
        for name, info in r["alignment"].items():
            if info["status"] == "INSUFFICIENT_VECTORS":
                warnings.append(f"Alignment '{name}': {info.get('reason', 'insufficient vectors')}")
        if self.state_url and not r["runtime_probe"].get("fetched"):
            warnings.append("State URL provided but fetch failed")
        if self.metrics_url and r["runtime_probe"].get("metrics_error"):
            warnings.append(f"Metrics fetch failed: {r['runtime_probe']['metrics_error']}")

        if warnings:
            lines.append("## Warnings")
            lines.append("")
            for w in warnings:
                lines.append(f"- {w}")
            lines.append("")

        lines.append("---")
        lines.append(f"*Generated by fork_readiness_check.py at {r['timestamp_utc']}*")
        lines.append("")
        return "\n".join(lines)

    # -- Internal -----------------------------------------------------------

    def _log_cmd(self, name, cmd, rc, output):
        self.cmd_log.append(f"=== {name} ===\n")
        self.cmd_log.append(f"$ {' '.join(cmd)}\n")
        self.cmd_log.append(f"exit={rc}\n")
        self.cmd_log.append(output)
        if not output.endswith("\n"):
            self.cmd_log.append("\n")
        self.cmd_log.append("\n")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Tsunagi fork-readiness checklist runner",
    )
    parser.add_argument(
        "--home", required=True,
        help="TSUNAGI_HOME directory",
    )
    parser.add_argument(
        "--bin", default=os.path.expanduser("~/.local/tsunagi/current/bin/tsunagi-node"),
        help="Path to tsunagi-node binary (default: ~/.local/tsunagi/current/bin/tsunagi-node)",
    )
    parser.add_argument(
        "--net", required=True, choices=["mainnet", "preprod", "preview", "sancho"],
        help="Network name (for labeling)",
    )
    parser.add_argument(
        "--state-url",
        help="URL for /state probe (e.g. http://127.0.0.1:9080/state)",
    )
    parser.add_argument(
        "--metrics-url",
        help="URL for /metrics probe (e.g. http://127.0.0.1:9080/metrics)",
    )
    parser.add_argument(
        "--min-header", type=int, default=100,
        help="Minimum header alignment vectors required (default: 100)",
    )
    parser.add_argument(
        "--min-vrf", type=int, default=100,
        help="Minimum VRF alignment vectors required (default: 100)",
    )
    args = parser.parse_args()

    runner = ChecklistRunner(args)

    # A) Environment validation
    print(f"[fork-readiness] net={args.net} home={runner.home}")
    errors = runner.validate_env()
    if errors:
        for e in errors:
            print(f"  ERROR: {e}", file=sys.stderr)
        sys.exit(1)
    if runner.results.get("version"):
        print(f"  version: {runner.results['version']}")

    # B) Offline regressions
    print("[fork-readiness] running offline regressions...")
    offline_ok = runner.run_offline_regressions()
    for name, info in runner.results["offline"].items():
        print(f"  {name}: {info['status']}")

    # C) Alignment suite
    print("[fork-readiness] running alignment suite...")
    runner.run_alignment()
    for name, info in runner.results["alignment"].items():
        extra = f" ({info.get('reason', '')})" if info.get("reason") else ""
        print(f"  {name}: {info['status']}{extra}")

    # D) Runtime health probe
    if args.state_url or args.metrics_url:
        print("[fork-readiness] probing runtime health...")
        runner.run_runtime_probe()
        probe = runner.results["runtime_probe"]
        if probe.get("fetched"):
            print(f"  state: fetched (tip_slot={probe.get('tip_slot', '?')})")
        elif args.state_url:
            print(f"  state: fetch failed")
        if probe.get("metrics_prefix_counts"):
            total = sum(probe["metrics_prefix_counts"].values())
            print(f"  metrics: {total} matching lines")

    # E) Compute overall + write evidence
    runner.compute_overall()
    runner.write_results()

    overall = runner.results["overall"]
    print(f"[fork-readiness] overall: {overall}")
    print(f"[fork-readiness] evidence: {runner.out_dir}")

    if overall == "FAIL":
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
