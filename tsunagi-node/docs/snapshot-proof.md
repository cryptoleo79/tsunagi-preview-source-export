# snapshot-proof -- Signed Snapshot Envelope + Mutation Suite (v4.1.0)

## Purpose

Signs a TSF snapshot, verifies it, runs 7 adversarial mutations (all must be
rejected), and produces a self-contained evidence directory. Proves that
Ed25519 snapshot signing and verification works correctly and rejects all
tampered inputs.

Zero secrets by design. Tooling only. Offline. No runtime changes. No
forging/broadcast/injection.

## Usage

```bash
tsunagi-node snapshot-proof \
    --file <path/to/snapshot.tsf> \
    --keydir <dir> \
    [--out <dir>] \
    [--net <name>] \
    [--strict]
```

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--file <path>` | (required) | TSF snapshot file |
| `--keydir <dir>` | (required) | Directory containing `snapshot_ed25519.{key,pub}` |
| `--out <dir>` | `/tmp` | Base output directory |
| `--net <name>` | (none) | Network name, included in evidence dir name |
| `--strict` | off | Included in manifest metadata |

### Quick Start

```bash
cd ~/src/tsunagi-follower/tsunagi-node
zig build -Doptimize=ReleaseSafe

BIN=./zig-out/bin/tsunagi-node
TSF=~/tsunagi-home-mainnet/tsf/mainnet-20260303-074715.tsf
KEYDIR=~/.local/tsunagi/keys

$BIN snapshot-proof --file "$TSF" --keydir "$KEYDIR" --out /tmp --net mainnet --strict
```

## How It Works

1. Parse and validate arguments
2. Validate TSF file exists and read TSF header (slot, block_no)
3. Create evidence directory: `tsunagi_snapshot_proof[_<net>]_<unix>/`
4. Detect version, write `version.txt`
5. Compute SHA256 of TSF, write `inputs/snapshot_info.json`
6. Key handling:
   - Check `<keydir>/snapshot_ed25519.key` exists
   - If missing: run `snapshot-keygen` subprocess, copy keys to keydir if needed
   - Read public key, write `inputs/pubkey_hex.txt`
7. Verify original TSF (may FAIL if unsigned, result recorded)
8. Sign the TSF via `snapshot-sign` subprocess
9. Verify the signed TSF (MUST PASS)
10. Run 7-mutation adversarial suite (see below)
11. Write `checks/mutation_report.json`
12. Zero-secrets scan (5MB limit, `pubkey_hex.txt` exception)
13. Write `manifest.json`
14. Write `SHA256SUMS` (sorted, last)
15. Print summary to stderr, evidence dir path to stdout

## Mutation Suite

Seven adversarial tests. Each creates a mutated copy of the TSF and/or its
signature, then runs `snapshot-verify`. A mutation PASSES when verification
correctly rejects the tampered input.

| Mutation | What | Expected Exit |
|----------|------|---------------|
| `tail_flip` | XOR byte at filesize-1024 | 2 (INVALID) |
| `head_flip` | XOR byte at offset 16 | 2 (INVALID) |
| `truncate` | Copy minus last byte | 2 (INVALID) |
| `append` | Copy + null byte at end | 2 (INVALID) |
| `random_sig` | Copy TSF + 89 random bytes as .sig | 2 (INVALID) |
| `missing_sig` | Copy TSF, no .sig file | 1 (FileNotFound) |
| `sig_swap` | Copy TSF + another .tsf.sig from same dir | 2 (INVALID) or SKIP |

Exit 2 = INVALID signature (v4.0.1 convention). Exit 1 = missing .sig.
Both are correct rejections. Exit 0 = mutation unexpectedly verified = FAIL.

`sig_swap` is SKIPped if no other `.tsf.sig` exists in the same directory.

## Output Directory

```
tsunagi_snapshot_proof[_<net>]_<unix>/
  manifest.json
  SHA256SUMS
  version.txt
  checks/
    verify_original.txt
    verify_signed.txt
    mutation_report.json
  inputs/
    snapshot_info.json
    pubkey_hex.txt
```

## Manifest Schema

```json
{
  "version": "...",
  "unix": 1709337600,
  "strict": true,
  "mode": "snapshot_proof",
  "snapshot": {
    "path": "/path/to/snapshot.tsf",
    "basename": "snapshot.tsf",
    "sha256": "<64 hex chars>",
    "bytes": 123456789,
    "slot": 123456,
    "block_no": 12345
  },
  "pubkey_hex": "<64 hex chars>",
  "results": {
    "verify_original": "PASS|FAIL",
    "verify_signed": "PASS",
    "mutation_suite": "PASS"
  },
  "notes": [...]
}
```

## Mutation Report Schema

```json
{
  "mutations": [
    {"name": "tail_flip", "expected": 2, "actual": 2, "result": "PASS"},
    ...
  ],
  "pass_count": 7,
  "fail_count": 0,
  "skip_count": 0,
  "overall": "PASS"
}
```

## Zero-Secrets Scan

Before writing the manifest, the evidence directory is scanned:
- Reject `*.skey`, `*.vkey`, `*.cert` files
- Reject filenames containing "key" **except** `pubkey_hex.txt`
- Reject files larger than 5MB

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All checks PASS (verify_signed + mutation suite) |
| 2 | One or more checks FAIL |
| 3 | Missing required args or files |
| 4 | Sign failed, IO/parse error |

## Via evidence-pack

Snapshot proof can also be invoked through the evidence-pack command:

```bash
tsunagi-node evidence-pack \
    --snapshot-proof \
    --file <path/to/snapshot.tsf> \
    --keydir <dir> \
    --net <name> \
    [--out <dir>] \
    [--strict]
```

This delegates to `snapshot-proof` as a subprocess.

## Non-Goals

- No forging, no broadcast, no chain injection
- No changes to signing/verification logic (reuses existing CLI commands)
- No inline keygen (delegates to `snapshot-keygen` subprocess)
- No secrets in the evidence envelope (zero-secrets scan enforced)
- Not a backup tool -- contains only verification results and metadata

## v4.3.0 — Detached Pubkey Verification

### Verify with explicit pubkey file

```bash
tsunagi-node snapshot-verify \
    --file <snapshot.tsf> \
    --pubkey-file <snapshot_ed25519.pub>
```

When `--pubkey-file` is provided, the local keydir is not used.
The pubkey file must contain a 64-character hex-encoded Ed25519 public key.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Signature VALID |
| 2 | Signature INVALID |
| 1 | Missing sig file, missing pubkey file, or IO error |
