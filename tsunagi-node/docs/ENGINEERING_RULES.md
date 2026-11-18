# TSUNAGI Engineering Rules

These rules govern all development on the TSUNAGI codebase.

---

## Git Discipline

- **Forward-only history.** No amend of published commits. No rebase of
  published commits. No force push. No tag rewriting.
- **Commit style:** `fix(scope): summary`, `feat(scope): summary`,
  `docs(scope): summary`, `chore(scope): summary`, `test(scope): summary`.
- **Manual approval** for all releases and deployments.
- **Tag milestones** with annotated tags. Tags are permanent.

## Protocol Correctness

- **Correctness before optimization.** A correct slow implementation is
  better than a fast incorrect one.
- **Deterministic behavior preferred.** Avoid heuristics where a
  deterministic approach exists.
- **No injection.** TSUNAGI must never feed served blocks into its own
  follower chain state. The NO_INJECT invariant is always enforced.
- **Spec compliance.** Ouroboros mini-protocol messages must follow the
  specification. RollBackward after IntersectFound. Contiguous header
  sequences. Exact CBOR bytes from disk.

## Safety

- **Fail-closed.** If a safety gate cannot be evaluated, the operation
  does not proceed. No fallback, no override.
- **Preview-only** for propagation until explicitly unlocked for other
  networks.
- **Bounded diagnostics.** No unbounded logging or memory growth.
  Diagnostic probes are capped and removed after use.
- **Operator transparency.** All significant decisions are logged.
  Receipts are written for served headers and blocks.

## Code Changes

- **Minimal blast radius.** Only change what is necessary for the
  current task. No unrelated cleanup, formatting sweeps, or
  beautification.
- **No speculative features.** Do not add code for hypothetical future
  requirements.
- **Preserve existing behavior** in fallback paths. When adding a new
  code path, the old path must produce identical results under the
  same conditions.
- **Test coverage** for bug fixes. Every bug fix should include a
  regression test covering the failure scenario.

## Releases

- **Build and test** before every release: `zig build -Doptimize=ReleaseSafe`
  and `zig build test`.
- **Install** to both binary paths after build.
- **Verify runtime** after deployment (check logs for expected behavior).
- **Tag, push, and create GitHub release** with evidence-based release notes.
