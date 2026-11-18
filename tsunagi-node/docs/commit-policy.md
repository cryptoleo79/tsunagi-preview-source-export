# TSUNAGI — Commit & PR Discipline

## Objective
Maintain a clean, professional, forward-only repository history with meaningful commits and proper PR flow.

---

## Core Principles

1. Forward-only history
- NEVER rewrite history
- NEVER amend commits
- NEVER rebase
- NEVER force push
- ALWAYS add new commits

2. Atomic commits
- Each commit = one logical change
- Small, reviewable, meaningful

---

## When to Commit

Commit when:
- A feature compiles and runs
- A bug is fixed
- A module is completed
- A milestone step is reached
- A safety fix is added
- A test is added or passes

Do NOT wait for large changes.

---

## Commit Message Format

`<scope>: <action>`

Examples:
- cbor: enforce recursion depth limit
- producer: add block size pre-sign guard
- decision: emit CORRELATION logs
- net: log BF_RX events
- opcert: enforce counter monotonicity

Avoid vague messages:
- update
- fix
- changes

---

## Branching Rules

For multi-step work:

`feature/<short-description>`

Examples:
- feature/first-accepted-block-guardrails
- feature/opcert-validation
- feature/blockfetch-proof

Work only inside that branch and commit incrementally.

---

## When to Create a PR

Create a PR when:
- A sprint completes
- Multiple commits form a milestone
- Core modules are touched
- Changes affect correctness or forge behavior

PR is REQUIRED for:
- acceptance path work
- network-related changes
- producer-level changes

---

## PR Title Format

`feat: <clear milestone>`

Examples:
- feat: first accepted block guardrails
- feat: opcert validation + block size safety
- feat: blockfetch observability + correlation logging

---

## PR Description Template

Summary:
<what this PR does>

Includes:
- list of changes

Key guarantees:
- forge path unchanged (if applicable)
- logic gated or observe-only

Safety:
- no blocking calls in forge path
- fallback behavior preserved

Success criteria:
- measurable outcomes

---

## Merge Rules

- Use normal merge (NOT squash)
- Preserve commit history
- Keep atomic commits visible

---

## What Not To Do

NEVER:
- dump large changes into one commit
- skip PR for major work
- mix unrelated changes
- rewrite history
- hide changes in "refactor"

---

## Sprint Rule

When "Sprint complete" is declared:
→ that work MUST be wrapped in a PR

---

## Goal

Produce a repository that:
- reads like an engineering narrative
- is easy to audit
- builds trust

---

## Final Rule

If someone reads the commit history,
they must understand exactly how TSUNAGI evolved.
