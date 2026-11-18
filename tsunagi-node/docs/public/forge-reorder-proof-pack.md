# TSUNAGI — Forge Pipeline + Mixed-Score Reorder Proof Pack

Canonical milestone language for the accepted-tx forge pipeline and
mixed-score candidate reorder proof on the Cardano preview network.

All copy below is validated against observed runtime evidence.
Use these blocks for README, website, architecture docs, social media,
and whitepaper references.

---

## What TSUNAGI Has Proven

On the Cardano preview network with a real relay connected:

- **Accepted-tx forge-path execution.** Real transactions submitted via
  HTTP, admitted through 13-check mempool validation, exported as forge
  candidates, and embedded in KES-signed block candidate bodies.

- **Full forge evidence pipeline.** FORGE_GATE, FORGE_RANK,
  FORGE_RANK_ORDER, FORGE_EXTERNAL, BELIEF_STATE, TRUST_SIGNAL,
  TRUST_AGGREGATE, and TRUST_AGGREGATE_SUMMARY all emitted with
  non-zero counts under real transaction load.

- **Deterministic opt-in candidate reordering.** Policy-gated reorder
  mode (off / observe / enforce_safe / reorder) proven on preview.
  Reorder mode applies deterministic score-based ordering with explicit
  tie-breaking (higher score first, lower original index on ties).

- **Mixed-score changed=1 reorder proof.** Two accepted non-Plutus
  transactions of different sizes produced different scores under
  size-aware ranking. The smaller transaction (88 bytes, score 492) was
  promoted above the larger transaction (116 bytes, score 489).
  `FORGE_REORDER: enabled=1 checked=2 changed=1` confirmed visible
  candidate reordering.

- **Multi-source trust observability.** Trust signals from forge
  execution and mempool validation, belief-state encoding, and
  normalized 12-entry aggregate evidence view — all emitting during
  candidate construction.

- **Observe-only trust score and decision metrics.** Simple additive
  trust score (positive - negative) and BAeY-compatible posterior
  (Beta prior), even-odds EV, Kelly fraction, and log-likelihood ratio
  — all derived from live evidence during each forge cycle. Proven with
  `TRUST_SCORE: positive=2 negative=0 neutral=10 score=2` and
  `DECISION_METRICS: alpha=3 beta=1 posterior_x1e6=750000
  ev_x1e6=500000 kelly_x1e6=500000 llr_x1e6=1098612` under real
  accepted-tx load.

- **Observe-only decision advisory.** Deterministic stance, confidence
  band, and allocation band derived from decision metrics during each
  forge cycle. Proven with `DECISION_ADVISORY: stance=positive
  confidence=medium allocation=moderate action=observe_only` under
  real accepted-tx load. Advisory is stateless, transparent, and does
  not influence runtime behavior.

- **Observe-only shadow policy preview.** Deterministic recommendation
  (favor, hold, caution, avoid) and strength (none, light, moderate,
  strong) derived from the decision advisory during each forge cycle.
  Proven with `POLICY_PREVIEW: recommendation=favor strength=moderate
  action=shadow_only` under real accepted-tx load. Policy preview is
  shadow-only and does not influence runtime behavior.

- **Shadow policy impact simulation.** Deterministic domain-touch
  simulation derived from the policy preview during each forge cycle.
  Proven with `POLICY_IMPACT: kind=ordering_bias touch_ordering=true
  touch_enforcement=false touch_mempool=false action=shadow_only`
  under real accepted-tx load. Identifies which runtime domain the
  preview policy would touch without actually touching it.

- **Policy-coupled ordering experiment.** Preview-only,
  operator-enabled ordering activation from shadow policy output.
  Proven with `POLICY_APPLY: domain=ordering
  experiment=ordering_bias_preview active=1 reason=ordering_bias
  strength=moderate mode=preview_only` while `FORGE_POLICY=observe`,
  causing `FORGE_REORDER: enabled=1 checked=2 changed=1`. This is
  the first point where TSUNAGI's decision pipeline activated runtime
  behavior through policy coupling rather than direct operator mode
  selection. Preview-only, ordering-only, no mempool or enforcement
  mutation.

- **/decision operator surface.** Full decision stack visible through
  one HTTP endpoint (`/decision`). Returns trust score, BAeY metrics,
  advisory, policy preview, policy impact, and policy apply status as
  structured JSON. Proven field-for-field match against live forge-cycle
  evidence. Operators can audit the entire decision pipeline in one
  request without parsing logs.

- **Stable runtime.** No crash, no relay disconnection, no unexpected
  behavior during any proof window. Safe revert to observe mode
  confirmed after every validation run.

---

## What TSUNAGI Does Not Yet Claim

- **Not full-node complete.** Epoch transitions, full stake/reward
  ledger, and full protocol-parameter chain derivation are not yet
  implemented.

- **Not consensus-equivalent parity.** TSUNAGI does not yet produce
  blocks accepted by the Cardano network consensus.

- **Not a full Bayesian engine.** Decision metrics use a Beta(1,1)
  uniform prior and simple additive counts. No weight learning, no
  history windowing, no adaptive updates.

- **Not adaptive policy.** Decision metrics are observe-only. They do
  not influence forge selection, ordering, enforcement, or mempool
  behavior.

- **Not general Plutus execution.** The evaluator uses structured rules
  and known-case boundary matching. Full Plutus/UPLC VM execution is
  not implemented.

- **Not production-ready block production.** Candidates are constructed
  but not broadcast. This is preview-only controlled validation.

- **Not execution-cost-based reorder.** The mixed-score proof uses
  size-aware differentiation for accepted non-Plutus transactions, not
  Plutus execution-cost scoring.

---

## README-Safe Summary

```
Proven on preview with real relay connected:
- Accepted-tx forge-path execution with real KES-signed block candidates
- Full forge evidence pipeline (gate, rank, external boundary, belief state, aggregate)
- Deterministic opt-in candidate reordering under accepted-tx load
- Mixed-score reorder with visible changed=1 evidence (size-aware differentiation)
- Multi-source trust-signal and aggregate observability during candidate construction
- Stable runtime under controlled validation with no relay disruption
```

---

## Website-Safe Summary

TSUNAGI constructs real KES-signed block candidates with embedded
transactions on the Cardano preview network. The full forge evidence
pipeline — gate evaluation, deterministic ranking, external boundary
checking, trust-signal emission, and candidate reordering — has been
validated under accepted-transaction load with a real relay connected.
Mixed-score candidate reordering has been proven with visible changed=1
evidence using size-aware differentiation for accepted non-Plutus
transactions. Block candidates are not yet broadcast to the network.
Full Plutus execution and consensus-equivalent parity are not yet
implemented.

---

## Architecture-Safe Summary

TSUNAGI implements an execution-aware forge pipeline with four policy
modes (off, observe, enforce_safe, reorder). The pipeline evaluates
each candidate transaction through a forge gate, computes a
deterministic score, applies optional enforcement for clearly invalid
transactions, and performs opt-in candidate reordering based on score.

Ranking uses execution-cost signals for Plutus-shaped transactions
(currently rule-based, not VM-backed) and size-aware differentiation
for non-Plutus transactions. The external evaluator boundary supports
a versioned protocol (v1), known-case fingerprint matching via
blake2b256, and a standalone compiled evaluator binary.

Trust signals from forge execution and mempool validation are
aggregated into a normalized 12-entry evidence view during each
candidate construction cycle.

---

## Operator-Safe Summary

TSUNAGI's forge pipeline runs on the Cardano preview network with
policy-controlled behavior:

| Policy | Gate | Enforce | Reorder |
|--------|------|---------|---------|
| off | disabled | no | no |
| observe | evaluate + log | no | no |
| enforce_safe | evaluate + log | skip clearly invalid | no |
| reorder | evaluate + log | skip clearly invalid | yes |

Set via `TSUNAGI_FORGE_POLICY=observe|enforce_safe|reorder|off`.

Runtime telemetry lines:
- `FORGE_GATE:` — per-cycle gate evaluation summary
- `FORGE_RANK:` — cost-class distribution
- `FORGE_RANK_ORDER:` — dry-run ordering by score
- `FORGE_REORDER:` — reorder activation and changed status
- `FORGE_EXTERNAL:` — external evaluator boundary summary
- `TRUST_SIGNAL:` — per-source evidence (forge_external, mempool)
- `TRUST_AGGREGATE:` — normalized cross-source evidence entries
- `BELIEF_STATE:` — belief-ready evidence encoding

---

## X Post (Single)

TSUNAGI — mixed-score candidate reorder on preview.

Real accepted txs. Real KES-signed candidates. Deterministic ranking.
changed=1 proven.

Full forge evidence pipeline: gate, rank, external boundary, trust
signals, aggregate.

Not full-node. Not Plutus. Not consensus parity.
Honest, deterministic, node-first.

tsunagi.tech

---

## X Thread

**1/5**
TSUNAGI milestone: mixed-score candidate reorder proven on Cardano
preview with a real relay connected.

Two accepted txs of different sizes scored differently under
deterministic size-aware ranking. The smaller tx was promoted.
FORGE_REORDER: enabled=1 changed=1.

**2/5**
The full forge evidence pipeline fires on every candidate cycle:
- FORGE_GATE evaluates each tx
- FORGE_RANK scores + classifies
- FORGE_RANK_ORDER shows dry-run ordering
- FORGE_EXTERNAL checks the evaluator boundary
- TRUST_SIGNAL + TRUST_AGGREGATE track evidence

**3/5**
Policy modes give operators explicit control:
- observe: evaluate + log only
- enforce_safe: skip clearly invalid txs
- reorder: deterministic score-based ordering

Default is observe. No hidden behavior changes.

**4/5**
What this is NOT:
- Not full Plutus execution (rule-based evaluator)
- Not consensus parity (candidates not broadcast)
- Not production-ready BP (preview-only controlled validation)
- Not general execution-cost reorder (size-aware for non-Plutus)

**5/5**
TSUNAGI is a Zig-native Cardano node that follows the chain, validates
transactions, constructs signed block candidates, and computes
verifiable trust signals from its own observed runtime state.

Forward-only. Deterministic. Operator-first.

tsunagi.tech

---

## Whitepaper-Safe Paragraph

TSUNAGI's forge pipeline has been validated on the Cardano preview
network under accepted-transaction load with a real relay connected.
The pipeline evaluates each candidate transaction through a
deterministic execution gate, computes a bounded score, and applies
optional policy-gated candidate reordering. Mixed-score reordering has
been proven with visible evidence: two accepted non-Plutus transactions
of different sizes were reordered based on size-aware ranking, with the
smaller transaction promoted to first position in the candidate body.
Trust signals from forge execution outcomes and mempool validation are
aggregated into a normalized evidence view during each candidate
construction cycle. Block candidates are KES-signed but not yet
broadcast to the network. Full Plutus execution, consensus-equivalent
parity, and production-ready block production remain future milestones.
