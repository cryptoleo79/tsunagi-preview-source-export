#!/usr/bin/env python3
"""
make_candidate_proof_bundle.py — Package latest real_kes candidate into a
shareable evidence bundle (ZIP).

Strict safety:
- NO secrets: rejects *.skey, *.vkey, node.cert, opcert*, vrf_*, genesis*, keys/
- NO symlinks: rejects any symlink in candidate directory
- Fail-closed: rejects unexpected/unsafe files
- Deterministic: sorted zip entries, sorted SHA256SUMS

Exit codes:
  0  success
  2  no suitable real_kes candidate found
  3  missing/invalid files, failed validation, or unsafe file/symlink
  4  malformed JSON

Python 3.6+ stdlib only. No forging. No broadcast. Preview-only.
"""

import argparse
import hashlib
import json
import os
import sys
import time
import zipfile

# ── Safety: files that must NEVER be included ──────────────────────────
SECRET_PATTERNS = (
    ".skey", ".vkey", "node.cert", "opcert",
    "vrf_proof", "vrf_output", "vrf_",
    "genesis", "keys/",
)

# ── Files allowed in the bundle ────────────────────────────────────────
REQUIRED_FILES = [
    "meta.json",
    "verify.json",
    "header_body.cbor",
    "signature.bin",
    "header_hash.hex",
    "body_hash.hex",
]

OPTIONAL_FILES = [
    "header.cbor",
]

ALLOWED_FILES = set(REQUIRED_FILES + OPTIONAL_FILES)

# ── Generated files (added by script) ─────────────────────────────────
GENERATED_FILES = ["summary.md", "SHA256SUMS"]


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def is_secret_filename(name):
    lower = name.lower()
    for pat in SECRET_PATTERNS:
        if pat in lower:
            return True
    return False


def reject_symlinks(candidate_dir):
    """Reject any symlinks in the candidate directory."""
    for entry in os.listdir(candidate_dir):
        full = os.path.join(candidate_dir, entry)
        if os.path.islink(full):
            print(f"ERROR: symlink detected: {entry}", file=sys.stderr)
            sys.exit(3)


def find_latest_real_kes_candidate(candidates_dir):
    """Find the most recent candidate dir where sig_kind==real_kes and sig_ok==true."""
    if not os.path.isdir(candidates_dir):
        return None

    dirs = []
    for entry in os.listdir(candidates_dir):
        full = os.path.join(candidates_dir, entry)
        if not os.path.isdir(full):
            continue
        if os.path.islink(full):
            continue
        meta_path = os.path.join(full, "meta.json")
        verify_path = os.path.join(full, "verify.json")
        if not os.path.isfile(meta_path) or not os.path.isfile(verify_path):
            continue
        try:
            with open(meta_path) as f:
                meta = json.load(f)
            with open(verify_path) as f:
                verify = json.load(f)
        except (json.JSONDecodeError, ValueError):
            continue
        if meta.get("sig_kind") != "real_kes":
            continue
        if verify.get("sig_verify_ok") is not True and verify.get("sig_ok") is not True:
            continue
        # Extract unix timestamp from dir name (format: <unix>_<slot>)
        parts = entry.split("_")
        try:
            ts = int(parts[0])
        except (ValueError, IndexError):
            ts = 0
        dirs.append((ts, entry, full))

    if not dirs:
        return None
    dirs.sort(key=lambda x: x[0], reverse=True)
    return dirs[0][2]


def validate_candidate(candidate_dir):
    """Validate candidate directory contents. Returns (meta, verify) or exits."""
    reject_symlinks(candidate_dir)

    # Check for secret files
    for entry in os.listdir(candidate_dir):
        if is_secret_filename(entry):
            print(f"ERROR: unsafe file in candidate dir: {entry}", file=sys.stderr)
            sys.exit(3)

    # Check required files exist
    for name in REQUIRED_FILES:
        path = os.path.join(candidate_dir, name)
        if not os.path.isfile(path):
            print(f"ERROR: missing required file: {name}", file=sys.stderr)
            sys.exit(3)

    # Parse and validate meta.json
    meta_path = os.path.join(candidate_dir, "meta.json")
    try:
        with open(meta_path) as f:
            meta = json.load(f)
    except (json.JSONDecodeError, ValueError) as e:
        print(f"ERROR: malformed meta.json: {e}", file=sys.stderr)
        sys.exit(4)

    required_meta_keys = ["net", "slot", "kes_period_offset", "sig_kind", "pool_id_hex"]
    for key in required_meta_keys:
        if key not in meta:
            print(f"ERROR: meta.json missing required key: {key}", file=sys.stderr)
            sys.exit(4)

    if meta["sig_kind"] != "real_kes":
        print(f"ERROR: meta.json sig_kind is '{meta['sig_kind']}', expected 'real_kes'",
              file=sys.stderr)
        sys.exit(3)

    # Parse and validate verify.json
    verify_path = os.path.join(candidate_dir, "verify.json")
    try:
        with open(verify_path) as f:
            verify = json.load(f)
    except (json.JSONDecodeError, ValueError) as e:
        print(f"ERROR: malformed verify.json: {e}", file=sys.stderr)
        sys.exit(4)

    sig_ok = verify.get("sig_verify_ok") or verify.get("sig_ok")
    if sig_ok is not True:
        print("ERROR: verify.json does not indicate PASS (sig_ok != true)", file=sys.stderr)
        sys.exit(3)

    # Validate signature.bin size == 448
    sig_path = os.path.join(candidate_dir, "signature.bin")
    sig_size = os.path.getsize(sig_path)
    if sig_size != 448:
        print(f"ERROR: signature.bin size is {sig_size}, expected 448", file=sys.stderr)
        sys.exit(3)

    # Validate header_body.cbor non-empty
    hdr_path = os.path.join(candidate_dir, "header_body.cbor")
    hdr_size = os.path.getsize(hdr_path)
    if hdr_size == 0:
        print("ERROR: header_body.cbor is empty", file=sys.stderr)
        sys.exit(3)

    return meta, verify


def generate_summary(meta, file_sizes, sig_hash, hdr_body_hash):
    """Generate summary.md content."""
    lines = [
        "# Tsunagi Real-KES Dryrun Candidate Proof Bundle",
        "",
        "**Dryrun-only proof. NO forging. NO broadcast. Preview-only.**",
        "",
        "## Candidate",
        "",
        f"- **net**: {meta.get('net', 'unknown')}",
        f"- **slot**: {meta.get('slot', 'unknown')}",
        f"- **unix**: {meta.get('unix', 'unknown')}",
        f"- **block_no**: {meta.get('block_no', 'unknown')}",
        f"- **kes_period**: {meta.get('kes_period', 'unknown')}",
        f"- **kes_period_offset**: {meta.get('kes_period_offset', 'unknown')}",
        f"- **pool_id_hex**: {meta.get('pool_id_hex', 'unknown')}",
        f"- **kes_pk_hex**: {meta.get('kes_pk_hex', 'unknown')}",
        f"- **sig_kind**: {meta.get('sig_kind', 'unknown')}",
        f"- **candidate_version**: {meta.get('candidate_version', 'unknown')}",
        "",
        "## Included Files",
        "",
    ]
    for name in sorted(file_sizes.keys()):
        lines.append(f"- `{name}` ({file_sizes[name]} bytes)")
    lines.extend([
        "",
        "## Direct Hashes",
        "",
        f"- sha256(signature.bin) = `{sig_hash}`",
        f"- sha256(header_body.cbor) = `{hdr_body_hash}`",
        "",
        "## How to Verify",
        "",
        "Extract the zip and check the internal checksums:",
        "",
        "```bash",
        "unzip <bundle>.zip -d proof/",
        "cd proof/",
        "sha256sum -c SHA256SUMS",
        "```",
        "",
        "Optional: verify with tsunagi-node candidate-verify:",
        "",
        "```bash",
        "tsunagi-node candidate-verify --dir proof/",
        "```",
        "",
        "## Safety",
        "",
        "- This bundle contains ONLY public-safe evidence files.",
        "- NO private keys, NO signing keys, NO VRF keys, NO certificates.",
        "- NO blocks were forged or broadcast. This is dryrun-only.",
        "- Preview network only.",
        "",
    ])
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="Package latest real_kes candidate into proof bundle")
    parser.add_argument("--home", required=True,
                        help="TSUNAGI_HOME directory")
    parser.add_argument("--net", default="preview",
                        help="Network name (default: preview)")
    parser.add_argument("--out", default=None,
                        help="Output directory (default: <home>/producer_dryrun/proof_bundles/)")
    parser.add_argument("--latest", action="store_true", default=True,
                        help="Select latest real_kes candidate (default)")
    args = parser.parse_args()

    home = os.path.abspath(args.home)
    if not os.path.isdir(home):
        print(f"ERROR: TSUNAGI_HOME not found: {home}", file=sys.stderr)
        sys.exit(3)

    candidates_dir = os.path.join(home, "producer_dryrun", "candidates")
    candidate_dir = find_latest_real_kes_candidate(candidates_dir)
    if candidate_dir is None:
        print("No suitable real_kes candidate found.", file=sys.stderr)
        print(f"  Searched: {candidates_dir}", file=sys.stderr)
        sys.exit(2)

    candidate_name = os.path.basename(candidate_dir)
    print(f"Selected candidate: {candidate_name}")
    print(f"  Path: {candidate_dir}")

    # Validate
    meta, verify = validate_candidate(candidate_dir)
    print(f"  sig_kind: {meta.get('sig_kind')}")
    print(f"  slot: {meta.get('slot')}")
    print(f"  kes_period_offset: {meta.get('kes_period_offset')}")

    # Collect files to include
    include_files = []
    file_sizes = {}
    for name in REQUIRED_FILES:
        path = os.path.join(candidate_dir, name)
        include_files.append((name, path))
        file_sizes[name] = os.path.getsize(path)
    for name in OPTIONAL_FILES:
        path = os.path.join(candidate_dir, name)
        if os.path.isfile(path) and not os.path.islink(path):
            include_files.append((name, path))
            file_sizes[name] = os.path.getsize(path)

    # Safety: reject any file not in allowed set
    for name, path in include_files:
        if name not in ALLOWED_FILES:
            print(f"ERROR: unexpected file for inclusion: {name}", file=sys.stderr)
            sys.exit(3)
        if is_secret_filename(name):
            print(f"ERROR: unsafe file for inclusion: {name}", file=sys.stderr)
            sys.exit(3)

    # Compute direct hashes
    sig_hash = sha256_file(os.path.join(candidate_dir, "signature.bin"))
    hdr_body_hash = sha256_file(os.path.join(candidate_dir, "header_body.cbor"))

    # Generate summary.md
    summary_content = generate_summary(meta, file_sizes, sig_hash, hdr_body_hash)

    # Output directory
    out_dir = args.out
    if out_dir is None:
        out_dir = os.path.join(home, "producer_dryrun", "proof_bundles")
    os.makedirs(out_dir, exist_ok=True)

    slot = meta.get("slot", 0)
    ts = int(time.time())
    zip_name = f"{ts}_{slot}_real_kes.zip"
    zip_path = os.path.join(out_dir, zip_name)

    # Build SHA256SUMS content (deterministic order)
    sha_lines = []
    all_entries = {}
    for name, path in include_files:
        with open(path, "rb") as f:
            data = f.read()
        all_entries[name] = data
    # Add generated files
    all_entries["summary.md"] = summary_content.encode("utf-8")
    file_sizes["summary.md"] = len(all_entries["summary.md"])

    # Compute SHA256SUMS for all files (sorted)
    sorted_names = sorted(all_entries.keys())
    for name in sorted_names:
        h = sha256_bytes(all_entries[name])
        sha_lines.append(f"{h}  {name}")
    sha256sums_content = "\n".join(sha_lines) + "\n"
    all_entries["SHA256SUMS"] = sha256sums_content.encode("utf-8")
    file_sizes["SHA256SUMS"] = len(all_entries["SHA256SUMS"])

    # Re-sort with SHA256SUMS included
    sorted_names = sorted(all_entries.keys())

    # Write ZIP (deterministic order)
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for name in sorted_names:
            info = zipfile.ZipInfo(name)
            info.date_time = (2025, 1, 1, 0, 0, 0)  # fixed timestamp for reproducibility
            info.compress_type = zipfile.ZIP_DEFLATED
            zf.writestr(info, all_entries[name])

    print(f"\nBundle written: {zip_path}")
    print(f"  Size: {os.path.getsize(zip_path)} bytes")
    print(f"  Files: {len(sorted_names)}")

    # Write external SHA256SUMS (hash of the zip itself)
    zip_hash = sha256_file(zip_path)
    ext_sha_path = os.path.join(out_dir, "SHA256SUMS")
    with open(ext_sha_path, "w") as f:
        f.write(f"{zip_hash}  {zip_name}\n")
    print(f"  External SHA256SUMS: {ext_sha_path}")
    print(f"  ZIP sha256: {zip_hash}")

    print("\nDone.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
