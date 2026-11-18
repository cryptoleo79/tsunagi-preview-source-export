# Praos Exact Threshold Equivalence Harness (v1.9.0, v1.9.1, v1.9.2)

## Purpose

Verification-only harness that compares Tsunagi's Praos threshold computation
against an exact reference formula and (when available) precomputed vectors
from cardano-node.

**NO runtime changes.** The harness does not modify the node's Praos math,
scheduler, or any runtime logic. NO forging. NO broadcast. NO chain injection.

## 3-Way Comparison

For each input vector, the harness computes three values:

| Label | Source | Role |
|-------|--------|------|
| `tsunagi_threshold_x1e12` | Existing `computeThreshX1e12()` (unchanged) | System under test |
| `exact_reference_threshold_x1e12` | Continuous formula in harness | Diagnostic reference |
| `expected_threshold_x1e12` | Precomputed from cardano-node (JSONL) | **Oracle** |

## Oracle Rule (CRITICAL)

PASS/FAIL is determined **ONLY** by comparing:

```
tsunagi_threshold_x1e12  vs  expected_threshold_x1e12
```

The `exact_reference_threshold_x1e12` is **DIAGNOSTIC ONLY**. It is never
used as the oracle for PASS/FAIL determination.

If `expected_threshold_x1e12` is `null`:
- Status = `SKIP_EXPECTED_NULL`
- Not counted as failure
- No equivalence claim is made

## Numerical Method (Exact Reference)

The continuous Praos leader threshold formula is:

```
T = 1 - (1 - f)^sigma
```

where:
- `f = asc_x1e6 / 1,000,000` (active slot coefficient)
- `sigma = stake_fraction_x1e9 / 1,000,000,000` (relative stake)

### Numerically Stable Form

To avoid catastrophic cancellation for small `f` and `sigma`:

```
T = -expm1( sigma * log1p(-f) )
```

where `log1p(x) = ln(1+x)` and `expm1(x) = e^x - 1` are standard
numerically stable functions.

### Edge Cases

| Condition | Result |
|-----------|--------|
| `f == 0` | `T = 0` |
| `sigma == 0` | `T = 0` |
| `f == 1` and `sigma > 0` | `T = 1` |

### Integer Conversion

```
exact_x1e12 = round(T * 1,000,000,000,000)
```

### Rounding Method

**Round half-away-from-zero** (Zig `@round` semantics). This means:
- 0.5 rounds to 1
- 1.5 rounds to 2
- -0.5 rounds to -1

Consistently applied to the exact reference computation.

### Float Precision

- **f64** is used for the exact reference computation.
- `f128` is not available for `log1p`/`expm1` in Zig 0.13.0.
- f64 provides ~15 significant decimal digits, which is sufficient for
  diagnostic comparison at the x1e12 scale.
- Since the exact reference is diagnostic only (never the oracle), f64
  precision is acceptable.

## How to Run

### Self-test (no external vectors)

```bash
tsunagi-node praos-exact-align
```

Self-test uses Tsunagi's own output as expected (internal consistency check).
This is NOT an equivalence proof against cardano-node.

### With external vectors

```bash
tsunagi-node praos-exact-align --vectors vectors.jsonl
```

### JSONL Schema

One JSON object per line:

```json
{"stake_fraction_x1e9":500000000,"asc_x1e6":50000,"expected_threshold_x1e12":25320565519}
{"stake_fraction_x1e9":100000000,"asc_x1e6":50000,"expected_threshold_x1e12":null}
```

Fields:
- `stake_fraction_x1e9` (u64, required): relative stake * 1e9
- `asc_x1e6` (u64, required): active slot coefficient * 1e6
- `expected_threshold_x1e12` (u64 or null, required): expected threshold * 1e12

## Output Format

Per vector:

```
idx=0 stake_x1e9=500000000 asc_x1e6=50000 tsu_x1e12=25000000000 exact_x1e12=25320565519 expected_x1e12=25320565519 status=FAIL abs_delta_expected=320565519 rel_delta_expected_ppm=12659 abs_delta_exact=320565519 rel_delta_exact_ppm=12659
```

Summary:

```
vectors=N mismatches=M skipped=K
max_abs_delta_expected=...
max_rel_delta_expected_ppm=...
max_abs_delta_exact=...
max_rel_delta_exact_ppm=...
EXIT=X
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | No mismatches among vectors with non-null expected |
| 2 | At least one mismatch found |
| 3 | Parse error, file error, or IO error |

## Generating Expected Vectors

Two vector generation paths exist, with distinct roles:

| Path | Script | `expected_threshold_x1e12` | Role |
|------|--------|---------------------------|------|
| Math-only | `scripts/gen_praos_expected_vectors.py` | Always `null` | Diagnostic — no PASS/FAIL claim |
| Oracle | `scripts/gen_praos_expected_vectors_from_cardano_node.sh` | Non-null (from cardano-node) | **TRUE oracle** — determines PASS/FAIL |

### Path A — Math-only diagnostic vectors

```bash
python3 scripts/gen_praos_expected_vectors.py --out vectors_diag.jsonl
```

Options:
- `--mode preview|mainnet|sancho` (metadata only, default: preview)
- `--asc-list <comma-separated x1e6>` (default: 50000)
- `--stake-list <comma-separated x1e9>` (default: 1000,...,1000000000)

Output schema (one JSON object per line):

```json
{"mode":"preview","stake_fraction_x1e9":500000000,"asc_x1e6":50000,"expected_threshold_x1e12":null,"expected_threshold_x1e12_math":25320565519,"math_method":"T=-expm1(s*log1p(-f))","math_rounding":"round(T*1e12, half-away-from-zero)"}
```

Key points:
- `expected_threshold_x1e12` is **always null** — praos-exact-align will
  report `SKIP_EXPECTED_NULL` for every vector (no PASS/FAIL claim).
- `expected_threshold_x1e12_math` is the continuous-formula result for
  diagnostic comparison (never used as the oracle).
- Python 3.6+ stdlib only.

### Path B — Oracle vectors from cardano-node

```bash
scripts/gen_praos_expected_vectors_from_cardano_node.sh \
  --out vectors_oracle.jsonl \
  --mode preview \
  --asc-list 50000 \
  --stake-list 1000,10000,100000,1000000,10000000,100000000,500000000,900000000,1000000000
```

Prerequisites:
- GHC (>= 8.10) and cabal-install (>= 3.0)
- Haskell oracle project at `scripts/haskell/praos-threshold-oracle/`
  (or a pre-built `praos-threshold-oracle` binary)

If prerequisites are not met, the script prints setup instructions and
exits 3. Run with `--help` for manual oracle instructions.

Oracle output schema:

```json
{"mode":"preview","stake_fraction_x1e9":500000000,"asc_x1e6":50000,"expected_threshold_x1e12":25320565519,"expected_threshold_rounding":"floor","oracle":"cardano-node","oracle_version":"10.4.0","notes":"reference rounding behavior"}
```

Key field: `expected_threshold_rounding` documents the rounding method
used by cardano-node (floor, round-nearest, round-nearest-even, or unknown).
This is metadata — praos-exact-align compares integer values directly.

### Running vectors against the harness

```bash
# Diagnostic (all SKIP_EXPECTED_NULL — no equivalence claim):
tsunagi-node praos-exact-align --vectors vectors_diag.jsonl

# Oracle (determines real PASS/FAIL):
tsunagi-node praos-exact-align --vectors vectors_oracle.jsonl
```

### Oracle Rule (re-asserted)

PASS/FAIL is determined **ONLY** by comparing `tsunagi_threshold_x1e12`
against `expected_threshold_x1e12` from cardano-node vectors.

- Math-only vectors (`expected_threshold_x1e12 = null`) → `SKIP_EXPECTED_NULL`
- Oracle vectors (`expected_threshold_x1e12` non-null) → `PASS` or `FAIL`
- The exact reference is **diagnostic only** — never determines PASS/FAIL

## Oracle Implemented (v1.9.2)

The TRUE oracle is now implemented as a standalone Haskell program at
`scripts/haskell/praos-threshold-oracle/`. It computes the Praos threshold
using the exact same arithmetic as cardano-node:

- **FixedPoint**: `Data.Fixed.Fixed E34` — 34 decimal digits of precision
  (from `Cardano.Ledger.BaseTypes`)
- **ln**: Generalized continued fraction with `eps = 1e-24` convergence
  (from `Cardano.Ledger.NonIntegral.ln'`)
- **exp**: Taylor series with argument reduction
  (from `Cardano.Ledger.NonIntegral.exp'`)
- **activeSlotLog**: `floor(10^34 * ln'(1-f))` then reload as FixedPoint
  (replicates `mkActiveSlotCoeff` from `Cardano.Ledger.BaseTypes`)
- **Rounding**: `floor(T * 10^12)` for the x1e12 conversion

### Two-machine verification flow

**On BP server** (has GHC + cabal):

```bash
# Generate oracle vectors:
scripts/gen_praos_expected_vectors_from_cardano_node.sh \
  --out /tmp/praos_oracle.jsonl

# Transfer to Tsunagi server:
scp /tmp/praos_oracle.jsonl tsunagi-server:/tmp/
```

**On Tsunagi server**:

```bash
# Run equivalence check:
tsunagi-node praos-exact-align --vectors /tmp/praos_oracle.jsonl
```

### Fail-closed behavior

The oracle generator script **exits non-zero** if:
- GHC or cabal are not installed (exit 3)
- The Haskell oracle project is missing (exit 3)
- The oracle build or execution fails (exit 4)
- The output contains any null `expected_threshold_x1e12` (exit 4)

No fallback to floating-point math. The script never emits
`expected_threshold_x1e12` unless the Haskell oracle actually ran.

### Oracle source attribution

The arithmetic is vendored from:
- **Repo**: https://github.com/IntersectMBO/cardano-ledger
- **Module**: `libs/non-integral/src/Cardano/Ledger/NonIntegral.hs`
- **License**: Apache-2.0
- Only the module name was changed (`Cardano.Ledger.NonIntegral` → `NonIntegral`)

## Tsunagi Threshold Function

Since v1.9.4, `computeThreshX1e12` in `producer.zig` delegates to
`praos_threshold_e34.zig` which ports the E34 fixed-point arithmetic
(34-digit `Fixed E34`, continued-fraction ln, Taylor exp) from
`NonIntegral.hs` to Zig, matching cardano-node's threshold exactly
including the `activeSlotLog` floor-reload step and floor rounding.

## Reminders

- This is a verification-only harness. No runtime Praos math is modified.
- No scheduler changes. No forging. No broadcast. No chain injection.
- The exact reference is diagnostic — never determines PASS/FAIL.
- Only precomputed cardano-node vectors determine equivalence.

### v1.9.5 Threshold Drift Guard

praos-threshold-regress enforces that runtime computeThreshX1e12
matches cardano-node oracle vectors exactly.

This command:
- Uses expected_threshold_x1e12 as the ONLY oracle.
- Treats null expected as SKIP.
- Fails immediately on mismatch.
- Prevents silent math drift in future changes.

Reminder:
No runtime changes were introduced in v1.9.5.
