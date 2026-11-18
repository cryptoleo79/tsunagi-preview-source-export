#!/usr/bin/env python3
"""
gen_praos_expected_vectors.py — Generate math-only diagnostic vectors for
the praos-exact-align harness.

These vectors are DIAGNOSTIC ONLY. They do NOT claim cardano-node equivalence.
expected_threshold_x1e12 is ALWAYS null in this output.

The field expected_threshold_x1e12_math contains the continuous-formula result
for diagnostic comparison, but it is NEVER used as the PASS/FAIL oracle by
praos-exact-align (which only gates on non-null expected_threshold_x1e12).

Computation:
  T = -expm1(sigma * log1p(-f))
  f = asc_x1e6 / 1e6
  sigma = stake_fraction_x1e9 / 1e9
  expected_threshold_x1e12_math = round(T * 1e12)

Rounding: round-half-away-from-zero (Python round() uses banker's rounding /
round-half-to-even; we use int(T * 1e12 + 0.5) for consistent
round-half-away-from-zero behavior on non-negative values).

Python 3.6+ stdlib only. No forging. No broadcast.

Exit codes:
  0  success
  3  IO/parse error
"""

import argparse
import json
import math
import sys


DEFAULT_ASC_LIST = "50000"
DEFAULT_STAKE_LIST = (
    "1000,10000,100000,1000000,10000000,"
    "100000000,500000000,900000000,1000000000"
)


def compute_threshold_x1e12(stake_fraction_x1e9, asc_x1e6):
    """Compute exact Praos threshold using numerically stable formula.

    T = -expm1(sigma * log1p(-f))

    Returns integer x1e12, rounded half-away-from-zero.
    """
    if stake_fraction_x1e9 == 0 or asc_x1e6 == 0:
        return 0

    f = asc_x1e6 / 1_000_000.0
    sigma = stake_fraction_x1e9 / 1_000_000_000.0

    if f >= 1.0:
        return 1_000_000_000_000

    # T = -expm1(sigma * log1p(-f))
    t = -math.expm1(sigma * math.log1p(-f))

    if t <= 0.0:
        return 0
    if t >= 1.0:
        return 1_000_000_000_000

    # Round half-away-from-zero for non-negative values
    return int(t * 1_000_000_000_000.0 + 0.5)


def main():
    parser = argparse.ArgumentParser(
        description="Generate math-only diagnostic vectors for praos-exact-align")
    parser.add_argument("--out", required=True,
                        help="Output JSONL file path")
    parser.add_argument("--asc-list", default=DEFAULT_ASC_LIST,
                        help="Comma-separated ASC values (x1e6)")
    parser.add_argument("--stake-list", default=DEFAULT_STAKE_LIST,
                        help="Comma-separated stake fraction values (x1e9)")
    parser.add_argument("--mode", default="preview",
                        choices=["preview", "mainnet", "sancho"],
                        help="Network mode (metadata only)")
    args = parser.parse_args()

    try:
        asc_values = [int(x.strip()) for x in args.asc_list.split(",")]
    except ValueError as e:
        print(f"ERROR: invalid --asc-list: {e}", file=sys.stderr)
        return 3

    try:
        stake_values = [int(x.strip()) for x in args.stake_list.split(",")]
    except ValueError as e:
        print(f"ERROR: invalid --stake-list: {e}", file=sys.stderr)
        return 3

    vectors = []
    for asc in asc_values:
        for stake in stake_values:
            math_val = compute_threshold_x1e12(stake, asc)
            vec = {
                "mode": args.mode,
                "stake_fraction_x1e9": stake,
                "asc_x1e6": asc,
                "expected_threshold_x1e12": None,
                "expected_threshold_x1e12_math": math_val,
                "math_method": "T=-expm1(s*log1p(-f))",
                "math_rounding": "round(T*1e12, half-away-from-zero)",
            }
            vectors.append(vec)

    try:
        with open(args.out, "w") as f:
            for vec in vectors:
                f.write(json.dumps(vec, separators=(",", ":")) + "\n")
    except IOError as e:
        print(f"ERROR: cannot write {args.out}: {e}", file=sys.stderr)
        return 3

    print(f"Wrote {len(vectors)} diagnostic vectors to {args.out}")
    print(f"  mode: {args.mode}")
    print(f"  asc_values: {asc_values}")
    print(f"  stake_values: {stake_values}")
    print(f"  expected_threshold_x1e12: always null (DIAGNOSTIC ONLY)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
