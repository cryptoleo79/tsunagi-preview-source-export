#!/usr/bin/env bash
set -euo pipefail

# gen_praos_expected_vectors_from_cardano_node.sh
#
# Produce TRUE oracle vectors where expected_threshold_x1e12 is filled
# (non-null) by cardano-node reference code (vendored 34-digit fixed-point
# arithmetic from Cardano.Ledger.NonIntegral).
#
# These vectors are the ONLY valid oracle for PASS/FAIL in praos-exact-align.
# Math-only vectors (from gen_praos_expected_vectors.py) are DIAGNOSTIC ONLY.
#
# FAIL-CLOSED: This script NEVER emits expected_threshold_x1e12 unless
# the Haskell oracle executable actually ran. No fallback to float math.
# If ghc/cabal are missing or the build fails, the script exits non-zero
# and produces NO output file.
#
# Exit codes:
#   0  success (oracle vectors produced, all expected non-null)
#   3  missing prerequisites (ghc, cabal, or oracle project)
#   4  oracle build/run failure or invalid output

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORACLE_DIR="${SCRIPT_DIR}/haskell/praos-threshold-oracle"

OUT="/tmp/praos_oracle.jsonl"
MODE="preview"
ASC_LIST="50000"
STAKE_LIST="1000,10000,100000,1000000,10000000,100000000,500000000,900000000,1000000000"

usage() {
    cat <<'EOF'
Usage:
  gen_praos_expected_vectors_from_cardano_node.sh \
    [--out <path.jsonl>] \
    [--mode preview|mainnet|sancho] \
    [--asc-list <comma-separated x1e6>] \
    [--stake-list <comma-separated x1e9>]

Produces TRUE oracle vectors with expected_threshold_x1e12 filled (non-null)
using the cardano-node reference arithmetic (34-digit fixed-point, continued
fractions for ln, Taylor series for exp).

Default output: /tmp/praos_oracle.jsonl

PREREQUISITES:
  - GHC (>= 8.10) and cabal-install (>= 3.0)
  - The Haskell oracle project at scripts/haskell/praos-threshold-oracle/

ARITHMETIC SOURCE:
  Vendored from https://github.com/IntersectMBO/cardano-ledger
    libs/non-integral/src/Cardano/Ledger/NonIntegral.hs
  FixedPoint type (E34, 34 decimal digits) from:
    libs/cardano-ledger-core/src/Cardano/Ledger/BaseTypes.hs
  activeSlotLog storage: floor(10^34 * ln'(1-f)) (mkActiveSlotCoeff)
  Final rounding: floor(T * 10^12)

VALIDATION:
  After generation, all lines are checked for non-null expected_threshold_x1e12.
  If any null values are found, the script exits 4.

USAGE WITH TSUNAGI:
  # Generate on BP server:
  scripts/gen_praos_expected_vectors_from_cardano_node.sh --out /tmp/praos_oracle.jsonl
  # Transfer to Tsunagi server:
  scp /tmp/praos_oracle.jsonl tsunagi-server:/tmp/
  # Run on Tsunagi server:
  tsunagi-node praos-exact-align --vectors /tmp/praos_oracle.jsonl

EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        --asc-list) ASC_LIST="$2"; shift 2 ;;
        --stake-list) STAKE_LIST="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; usage; exit 3 ;;
    esac
done

# ── Check prerequisites ──────────────────────────────────────────────

check_prerequisites() {
    local missing=0

    if ! command -v ghc &>/dev/null; then
        echo "  MISSING: ghc (Glasgow Haskell Compiler)" >&2
        missing=1
    else
        echo "  ghc: $(ghc --version 2>/dev/null | head -1)"
    fi

    if ! command -v cabal &>/dev/null; then
        echo "  MISSING: cabal-install" >&2
        missing=1
    else
        echo "  cabal: $(cabal --version 2>/dev/null | head -1)"
    fi

    if [[ -f "${ORACLE_DIR}/praos-threshold-oracle.cabal" ]]; then
        echo "  oracle project: found at ${ORACLE_DIR}"
    else
        echo "  oracle project: NOT FOUND at ${ORACLE_DIR}" >&2
        echo "" >&2
        echo "The Haskell oracle project is missing." >&2
        echo "Expected: ${ORACLE_DIR}/praos-threshold-oracle.cabal" >&2
        missing=1
    fi

    return $missing
}

echo "=== Praos Threshold Oracle Vector Generator ==="
echo ""
echo "Checking prerequisites..."

if ! check_prerequisites; then
    echo "" >&2
    echo "═══════════════════════════════════════════════════════════════" >&2
    echo "  PREREQUISITES NOT MET" >&2
    echo "" >&2
    echo "  To produce TRUE oracle vectors, you need:" >&2
    echo "    1. GHC >= 8.10 and cabal-install >= 3.0" >&2
    echo "    2. The Haskell oracle project at:" >&2
    echo "       ${ORACLE_DIR}/" >&2
    echo "" >&2
    echo "  No fallback to float math. Install prerequisites and retry." >&2
    echo "═══════════════════════════════════════════════════════════════" >&2
    exit 3
fi

# ── Build and run oracle ─────────────────────────────────────────────

# Remove any stale output to prevent previous results masking a failure
rm -f "${OUT}"

echo ""
echo "Building and running oracle..."
echo "  mode: ${MODE}"
echo "  asc_list: ${ASC_LIST}"
echo "  stake_list: ${STAKE_LIST}"
echo "  out: ${OUT}"
echo ""

cd "${ORACLE_DIR}"

if ! cabal run praos-threshold-oracle -- \
    --mode "${MODE}" \
    --asc-list "${ASC_LIST}" \
    --stake-list "${STAKE_LIST}" \
    --out "${OUT}" 2>&1; then
    echo "ERROR: oracle build or run failed" >&2
    exit 4
fi

# ── Validate output ──────────────────────────────────────────────────

if [[ ! -f "${OUT}" ]]; then
    echo "ERROR: output file not created: ${OUT}" >&2
    exit 4
fi

LINES=$(wc -l < "${OUT}")
if [[ "${LINES}" -eq 0 ]]; then
    echo "ERROR: output file is empty: ${OUT}" >&2
    exit 4
fi

# Check for null expected_threshold_x1e12 (must NOT appear in oracle output)
if grep -q '"expected_threshold_x1e12":null' "${OUT}" 2>/dev/null; then
    NULL_COUNT=$(grep -c '"expected_threshold_x1e12":null' "${OUT}" 2>/dev/null || true)
    echo "ERROR: output contains ${NULL_COUNT} null expected_threshold_x1e12 values" >&2
    echo "  Oracle vectors must have non-null expected_threshold_x1e12." >&2
    exit 4
fi

# ── Success ──────────────────────────────────────────────────────────

echo ""
echo "=== Oracle generation complete ==="
echo "  vectors: ${LINES}"
echo "  output:  ${OUT}"
echo "  expected_threshold_x1e12: all non-null (TRUE ORACLE)"
echo ""
echo "Run against praos-exact-align:"
echo "  tsunagi-node praos-exact-align --vectors ${OUT}"
