#!/usr/bin/env python3
"""
gen_block_candidate_regress_vectors.py — Extract a JSONL regression vector
from a single block candidate artifact directory.

Reads:
  - meta.json (kes_pk_hex, kes_period_offset)
  - header_body.cbor (raw bytes → hex)
  - signature.bin (448 bytes → hex)
  - header_hash.hex
  - body_hash.hex

Emits one JSONL line:
  {"slot":<u64>,"header_hash_hex":"<64hex>","body_hash_hex":"<64hex>",
   "kes_pk_hex":"<hex>","kes_period_offset":<u64>,"sig_hex":"<hex>",
   "header_body_cbor_hex":"<hex>"}

Python 3.6+ stdlib only.
"""

import argparse
import json
import os
import sys


def main():
    parser = argparse.ArgumentParser(
        description="Extract block candidate regress vector from artifact directory")
    parser.add_argument("--dir", required=True,
                        help="Block candidate directory (e.g., blocks/<unix>_<slot>)")
    parser.add_argument("--out", required=True,
                        help="Output JSONL file (appends if exists)")
    args = parser.parse_args()

    d = args.dir
    if not os.path.isdir(d):
        print(f"ERROR: directory not found: {d}", file=sys.stderr)
        sys.exit(3)

    # Read meta.json
    meta_path = os.path.join(d, "meta.json")
    try:
        with open(meta_path) as f:
            meta = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, ValueError) as e:
        print(f"ERROR: cannot read meta.json: {e}", file=sys.stderr)
        sys.exit(3)

    slot = meta.get("slot")
    if slot is None:
        print("ERROR: meta.json missing 'slot'", file=sys.stderr)
        sys.exit(3)

    kes_pk_hex = meta.get("kes_pk_hex")
    if kes_pk_hex is None:
        print("ERROR: meta.json missing 'kes_pk_hex'", file=sys.stderr)
        sys.exit(3)

    kes_period_offset = meta.get("kes_period_offset")
    if kes_period_offset is None:
        print("ERROR: meta.json missing 'kes_period_offset'", file=sys.stderr)
        sys.exit(3)

    # Read header_body.cbor
    hdr_body_path = os.path.join(d, "header_body.cbor")
    try:
        with open(hdr_body_path, "rb") as f:
            header_body_bytes = f.read()
    except FileNotFoundError:
        print(f"ERROR: header_body.cbor not found in {d}", file=sys.stderr)
        sys.exit(3)
    if len(header_body_bytes) == 0:
        print("ERROR: header_body.cbor is empty", file=sys.stderr)
        sys.exit(3)

    # Read signature.bin
    sig_path = os.path.join(d, "signature.bin")
    try:
        with open(sig_path, "rb") as f:
            sig_bytes = f.read()
    except FileNotFoundError:
        print(f"ERROR: signature.bin not found in {d}", file=sys.stderr)
        sys.exit(3)
    if len(sig_bytes) != 448:
        print(f"ERROR: signature.bin size is {len(sig_bytes)}, expected 448", file=sys.stderr)
        sys.exit(3)

    # Read header_hash.hex
    hdr_hash_path = os.path.join(d, "header_hash.hex")
    try:
        with open(hdr_hash_path) as f:
            header_hash_hex = f.read().strip()
    except FileNotFoundError:
        print(f"ERROR: header_hash.hex not found in {d}", file=sys.stderr)
        sys.exit(3)

    # Read body_hash.hex
    body_hash_path = os.path.join(d, "body_hash.hex")
    try:
        with open(body_hash_path) as f:
            body_hash_hex = f.read().strip()
    except FileNotFoundError:
        print(f"ERROR: body_hash.hex not found in {d}", file=sys.stderr)
        sys.exit(3)

    vector = {
        "slot": int(slot),
        "header_hash_hex": header_hash_hex,
        "body_hash_hex": body_hash_hex,
        "kes_pk_hex": kes_pk_hex,
        "kes_period_offset": int(kes_period_offset),
        "sig_hex": sig_bytes.hex(),
        "header_body_cbor_hex": header_body_bytes.hex(),
    }

    line = json.dumps(vector, separators=(",", ":"))

    with open(args.out, "a") as f:
        f.write(line + "\n")

    print(f"Vector written: slot={slot} kes_period_offset={kes_period_offset}")
    print(f"  header_body_cbor: {len(header_body_bytes)} bytes")
    print(f"  signature: {len(sig_bytes)} bytes")
    print(f"  Output: {args.out}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
