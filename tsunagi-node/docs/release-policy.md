# TSUNAGI — Release & Tagging Policy

## Versioning (v0.x phase)

TSUNAGI uses:

`v0.<minor>.<patch>`

Examples:
- `v0.1.0` → first structured milestone
- `v0.1.1` → small fix
- `v0.2.0` → new feature group

---

## Meaning

**MAJOR (0)**:
- still experimental
- no backward compatibility guarantees

**MINOR**:
- new features
- new modules
- milestone (e.g. "first accepted block")

**PATCH**:
- bug fixes
- small improvements
- no behavioral change

---

## Release Types

### Milestone Release
- new capability
- multi-commit feature
- example: NtC integration

### Stability Release
- fixes only
- no new behavior

---

## Tag Rules

Tags must:

- be annotated
- match CHANGELOG
- reference a clean commit

Example:

```
git tag -a v0.1.0 -m "v0.1.0: first accepted block guardrails"
```

---

## DO NOT

- rewrite tags
- force push tags
- create tags without changelog
- skip version numbers

---

## Goal

Every version should answer:

"What changed?"
"Why does it matter?"
