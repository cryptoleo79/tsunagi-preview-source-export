#!/usr/bin/env python3
"""
gen_consensus_vectors.py — Generate consensus-align JSONL vectors (v3.9.0).

Header + tx-body generator + passthrough wrapper for existing oracle JSONL.
v3.9.0: alignment mode for mainnet (decodes header CBOR, no blocks/ required).
Python3 stdlib-only. Never includes secrets (.skey, private keys).

Modes:
  --mode header       Generate kind="header" vectors from block candidate artifacts
  --mode tx           Generate kind="tx" vectors from block artifacts with included_tx_hashes.json
  --mode alignment    Generate kind="header" vectors from regress/alignment/header_hash.jsonl
  --mode passthrough  Add kind/net fields to existing oracle JSONL (praos/vrf)
  --mode praos|vrf    Refuses: oracle values required externally

Usage:
  python3 gen_consensus_vectors.py --mode header --artifacts-dir <path> --out <file.jsonl> [--net preview]
  python3 gen_consensus_vectors.py --mode alignment --alignment-file <path> --out <file.jsonl> --net mainnet [--limit 360]
  python3 gen_consensus_vectors.py --mode tx --blocks-dir <path> --out <file.jsonl> [--net preview]
  python3 gen_consensus_vectors.py --mode passthrough --input <file.jsonl> --add-kind praos --out <file.jsonl> [--net preview]
"""

import argparse
import json
import os
import sys

SLOTS_PER_KES_PERIOD = 129600


# ── Minimal CBOR decoder (stdlib-only, definite-length only) ─────────

def cbor_decode(data, off=0):
    """Decode one CBOR data item. Returns (value, next_offset)."""
    if off >= len(data):
        raise ValueError(f"cbor_decode: offset {off} beyond data length {len(data)}")
    b = data[off]
    major = b >> 5
    info = b & 0x1f
    off += 1

    if info < 24:
        arg = info
    elif info == 24:
        arg = data[off]; off += 1
    elif info == 25:
        arg = int.from_bytes(data[off:off+2], 'big'); off += 2
    elif info == 26:
        arg = int.from_bytes(data[off:off+4], 'big'); off += 4
    elif info == 27:
        arg = int.from_bytes(data[off:off+8], 'big'); off += 8
    else:
        raise ValueError(f"cbor_decode: unsupported additional info {info}")

    if major == 0:  # unsigned int
        return arg, off
    elif major == 1:  # negative int
        return -1 - arg, off
    elif major == 2:  # byte string
        return data[off:off+arg], off + arg
    elif major == 3:  # text string
        return data[off:off+arg].decode('utf-8'), off + arg
    elif major == 4:  # array
        items = []
        for _ in range(arg):
            item, off = cbor_decode(data, off)
            items.append(item)
        return items, off
    elif major == 5:  # map
        m = {}
        for _ in range(arg):
            k, off = cbor_decode(data, off)
            v, off = cbor_decode(data, off)
            m[k] = v
        return m, off
    elif major == 6:  # tag — discard tag number, return inner value
        val, off = cbor_decode(data, off)
        return val, off
    else:
        raise ValueError(f"cbor_decode: unsupported major type {major}")


def cbor_item_end(data, off):
    """Return the byte offset just past one CBOR item starting at off."""
    _, end = cbor_decode(data, off)
    return end


# ── Alignment mode (v3.9.0) ─────────────────────────────────────────

def gen_alignment_vectors(alignment_file, out_path, net, limit):
    """Generate kind='header' vectors from regress/alignment/header_hash.jsonl.

    Decodes Cardano header CBOR to extract all fields needed by consensus-align.
    Hard-fails on any extraction error (strict: no silent skips).
    """
    if not os.path.isfile(alignment_file):
        print(f"ERROR: alignment file not found: {alignment_file}", file=sys.stderr)
        sys.exit(1)

    vectors = []
    line_no = 0

    with open(alignment_file) as f:
        for raw_line in f:
            line_no += 1
            line = raw_line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError as e:
                print(f"ERROR: JSON parse error at line {line_no}: {e}", file=sys.stderr)
                sys.exit(1)

            if obj.get("kind") != "header_hash":
                continue

            # Parse note field: "slot=N block=N era=N net=N"
            note = obj.get("note", "")
            note_kv = {}
            for part in note.split():
                if "=" in part:
                    k, v = part.split("=", 1)
                    note_kv[k] = v

            vec_net = note_kv.get("net", "")
            if vec_net != net:
                continue

            header_bytes_hex = obj.get("header_bytes_hex", "")
            expected_hash_hex = obj.get("expected_header_hash_hex", "")

            if not header_bytes_hex or not expected_hash_hex:
                print(f"ERROR: line {line_no}: missing header_bytes_hex or expected_header_hash_hex",
                      file=sys.stderr)
                sys.exit(1)

            header_bytes = bytes.fromhex(header_bytes_hex)

            # CBOR decode: outer = [header_body_array, kes_sig_bytes]
            try:
                outer, _ = cbor_decode(header_bytes, 0)
            except Exception as e:
                print(f"ERROR: line {line_no}: CBOR decode failed: {e}", file=sys.stderr)
                sys.exit(1)

            if not isinstance(outer, list) or len(outer) < 2:
                print(f"ERROR: line {line_no}: header is not [header_body, sig]", file=sys.stderr)
                sys.exit(1)

            header_body = outer[0]
            kes_sig = outer[1]

            if not isinstance(header_body, list) or len(header_body) < 8:
                print(f"ERROR: line {line_no}: header_body has {len(header_body)} items (need >=8)",
                      file=sys.stderr)
                sys.exit(1)

            if not isinstance(kes_sig, (bytes, bytearray)) or len(kes_sig) != 448:
                print(f"ERROR: line {line_no}: kes_sig is {type(kes_sig).__name__} len={len(kes_sig) if isinstance(kes_sig, (bytes, bytearray)) else '?'} (need bytes/448)",
                      file=sys.stderr)
                sys.exit(1)

            # Extract fields from header_body
            block_no = header_body[0]
            slot = header_body[1]
            # body_hash at index 7 (Babbage/Conway 10-item) or 8 (older 15-item)
            if len(header_body) == 10:
                body_hash_idx = 7
                opcert_idx = 8
            elif len(header_body) == 15:
                body_hash_idx = 8
                opcert_idx = 9
            else:
                # Best guess for unknown era
                body_hash_idx = 7
                opcert_idx = 8

            body_hash = header_body[body_hash_idx]
            if not isinstance(body_hash, (bytes, bytearray)) or len(body_hash) != 32:
                print(f"ERROR: line {line_no}: body_hash at index {body_hash_idx} is not 32 bytes",
                      file=sys.stderr)
                sys.exit(1)

            opcert = header_body[opcert_idx]
            if not isinstance(opcert, list) or len(opcert) < 3:
                print(f"ERROR: line {line_no}: opcert at index {opcert_idx} is not [hot_vkey, counter, kes_period, ...]",
                      file=sys.stderr)
                sys.exit(1)

            kes_pk = opcert[0]
            cert_kes_period = opcert[2]  # [hot_vkey, counter, kes_period, cold_sig]

            if not isinstance(kes_pk, (bytes, bytearray)) or len(kes_pk) != 32:
                print(f"ERROR: line {line_no}: kes_pk is not 32 bytes", file=sys.stderr)
                sys.exit(1)
            if not isinstance(cert_kes_period, int):
                print(f"ERROR: line {line_no}: cert_kes_period is not int", file=sys.stderr)
                sys.exit(1)

            current_kes_period = slot // SLOTS_PER_KES_PERIOD
            kes_period_offset = current_kes_period - cert_kes_period

            # Extract header_body_cbor raw bytes span
            # The outer array is 0x82 (2-item array), so header_body starts at offset 1
            # and ends where the sig bytes begin
            outer_hdr_end = 1  # 0x82 = 1 byte for 2-item array header
            body_cbor_start = outer_hdr_end
            body_cbor_end = cbor_item_end(header_bytes, body_cbor_start)
            header_body_cbor = header_bytes[body_cbor_start:body_cbor_end]

            vector = {
                "kind": "header",
                "net": net,
                "slot": int(slot),
                "block_no": int(block_no),
                "header_bytes_hex": header_bytes_hex,
                "header_hash_hex": expected_hash_hex,
                "body_hash_hex": body_hash.hex(),
                "kes_pk_hex": kes_pk.hex(),
                "kes_period_offset": int(kes_period_offset),
                "kes_sig_hex": kes_sig.hex(),
                "header_body_cbor_hex": header_body_cbor.hex(),
            }

            vectors.append((int(slot), vector))

    if not vectors:
        print(f"ERROR: no matching alignment vectors for net={net}", file=sys.stderr)
        sys.exit(1)

    # Sort by slot ascending, apply limit (take latest N)
    vectors.sort(key=lambda x: x[0])
    if limit and len(vectors) > limit:
        vectors = vectors[-limit:]

    with open(out_path, "w") as out:
        for _, vec in vectors:
            out.write(json.dumps(vec, separators=(",", ":")) + "\n")

    print(f"Generated {len(vectors)} alignment header vectors -> {out_path}", file=sys.stderr)


def gen_header_vectors(artifacts_dir, out_path, net, limit):
    """Generate kind='header' vectors from block candidate artifact directories."""
    if not os.path.isdir(artifacts_dir):
        print(f"ERROR: artifacts dir not found: {artifacts_dir}", file=sys.stderr)
        sys.exit(1)

    # Each subdirectory is a slot dir containing block artifacts
    slot_dirs = sorted(
        [d for d in os.listdir(artifacts_dir)
         if os.path.isdir(os.path.join(artifacts_dir, d))],
    )

    if not slot_dirs:
        print(f"ERROR: no artifact subdirectories found in {artifacts_dir}", file=sys.stderr)
        sys.exit(1)

    vectors = []
    for slot_dir_name in slot_dirs:
        slot_dir = os.path.join(artifacts_dir, slot_dir_name)

        # Required files
        required = [
            "block_header.cbor", "block_header_hash.hex",
            "block_body_hash.hex", "meta.json", "signature.bin",
            "header_body.cbor",
        ]
        missing = [f for f in required if not os.path.isfile(os.path.join(slot_dir, f))]
        if missing:
            print(f"SKIP: {slot_dir_name} missing {missing}", file=sys.stderr)
            continue

        # Read artifacts
        header_bytes = read_binary(os.path.join(slot_dir, "block_header.cbor"))
        header_hash = read_text(os.path.join(slot_dir, "block_header_hash.hex")).strip()
        body_hash = read_text(os.path.join(slot_dir, "block_body_hash.hex")).strip()
        meta = json.loads(read_text(os.path.join(slot_dir, "meta.json")))
        sig_bytes = read_binary(os.path.join(slot_dir, "signature.bin"))
        hdr_body_bytes = read_binary(os.path.join(slot_dir, "header_body.cbor"))

        slot = meta.get("slot")
        block_no = meta.get("block_no")
        kes_pk_hex = meta.get("kes_pk_hex", "")
        kes_period_offset = meta.get("kes_period_offset")

        if slot is None or kes_pk_hex == "" or kes_period_offset is None:
            print(f"SKIP: {slot_dir_name} incomplete meta.json", file=sys.stderr)
            continue

        if len(sig_bytes) != 448:
            print(f"SKIP: {slot_dir_name} signature.bin is {len(sig_bytes)} bytes (expected 448)", file=sys.stderr)
            continue

        if len(kes_pk_hex) != 64:
            print(f"SKIP: {slot_dir_name} kes_pk_hex is {len(kes_pk_hex)} chars (expected 64)", file=sys.stderr)
            continue

        vector = {
            "kind": "header",
            "net": net,
            "slot": int(slot),
            "block_no": int(block_no) if block_no is not None else 0,
            "header_bytes_hex": header_bytes.hex(),
            "header_hash_hex": header_hash,
            "body_hash_hex": body_hash,
            "kes_pk_hex": kes_pk_hex,
            "kes_period_offset": int(kes_period_offset),
            "kes_sig_hex": sig_bytes.hex(),
            "header_body_cbor_hex": hdr_body_bytes.hex(),
        }

        vectors.append((int(slot), vector))

    # Sort by slot ascending, apply limit
    vectors.sort(key=lambda x: x[0])
    if limit and len(vectors) > limit:
        vectors = vectors[-limit:]

    with open(out_path, "w") as out:
        for _, vec in vectors:
            out.write(json.dumps(vec, separators=(",", ":")) + "\n")

    print(f"Generated {len(vectors)} header vectors -> {out_path}", file=sys.stderr)


def gen_tx_vectors(blocks_dir, out_path, net, limit):
    """Generate kind='tx' vectors from block artifact directories with included_tx_hashes.json."""
    if not os.path.isdir(blocks_dir):
        print(f"ERROR: blocks dir not found: {blocks_dir}", file=sys.stderr)
        sys.exit(1)

    slot_dirs = sorted(
        [d for d in os.listdir(blocks_dir)
         if os.path.isdir(os.path.join(blocks_dir, d))],
    )

    if not slot_dirs:
        print(f"ERROR: no subdirectories found in {blocks_dir}", file=sys.stderr)
        sys.exit(1)

    vectors = []
    skipped = 0
    for slot_dir_name in slot_dirs:
        slot_dir = os.path.join(blocks_dir, slot_dir_name)
        tx_hashes_path = os.path.join(slot_dir, "included_tx_hashes.json")

        if not os.path.isfile(tx_hashes_path):
            skipped += 1
            continue

        if not os.path.isfile(os.path.join(slot_dir, "block.cbor")):
            print(f"SKIP: {slot_dir_name} has tx_hashes but no block.cbor", file=sys.stderr)
            skipped += 1
            continue

        try:
            tx_hashes = json.loads(read_text(tx_hashes_path))
        except (json.JSONDecodeError, OSError) as e:
            print(f"SKIP: {slot_dir_name} cannot read included_tx_hashes.json: {e}", file=sys.stderr)
            skipped += 1
            continue

        if not isinstance(tx_hashes, list):
            print(f"SKIP: {slot_dir_name} included_tx_hashes.json is not an array", file=sys.stderr)
            skipped += 1
            continue

        slot = None
        meta_path = os.path.join(slot_dir, "meta.json")
        if os.path.isfile(meta_path):
            try:
                meta = json.loads(read_text(meta_path))
                slot = meta.get("slot")
            except (json.JSONDecodeError, OSError):
                pass
        if slot is None:
            parts = slot_dir_name.split("_")
            if len(parts) >= 2:
                try:
                    slot = int(parts[-1])
                except ValueError:
                    pass
        if slot is None:
            print(f"SKIP: {slot_dir_name} cannot determine slot", file=sys.stderr)
            skipped += 1
            continue

        tx_count_path = os.path.join(slot_dir, "included_tx_count.txt")
        tx_bytes_path = os.path.join(slot_dir, "included_tx_total_bytes.txt")

        tx_count = len(tx_hashes)
        if os.path.isfile(tx_count_path):
            try:
                tx_count = int(read_text(tx_count_path).strip())
            except (ValueError, OSError):
                pass

        tx_total_bytes = 0
        if os.path.isfile(tx_bytes_path):
            try:
                tx_total_bytes = int(read_text(tx_bytes_path).strip())
            except (ValueError, OSError):
                pass

        vector = {
            "kind": "tx",
            "net": net,
            "slot": int(slot),
            "block_dir": os.path.abspath(slot_dir),
            "included_tx_hashes": tx_hashes,
            "tx_count": tx_count,
            "tx_total_bytes": tx_total_bytes,
            "block_cbor_hex": None,
        }

        vectors.append((int(slot), vector))

    # Sort by slot ascending, apply limit
    vectors.sort(key=lambda x: x[0])
    if limit and len(vectors) > limit:
        vectors = vectors[-limit:]

    with open(out_path, "w") as out:
        for _, vec in vectors:
            out.write(json.dumps(vec, separators=(",", ":")) + "\n")

    print(f"Generated {len(vectors)} tx vectors (skipped {skipped}) -> {out_path}", file=sys.stderr)


def passthrough(input_path, out_path, add_kind, net):
    """Add kind/net fields to existing oracle JSONL. Does NOT compute expected values."""
    if not os.path.isfile(input_path):
        print(f"ERROR: input file not found: {input_path}", file=sys.stderr)
        sys.exit(1)

    count = 0
    with open(input_path) as inp, open(out_path, "w") as out:
        for line in inp:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError as e:
                print(f"ERROR: JSON parse error at line {count + 1}: {e}", file=sys.stderr)
                sys.exit(1)

            obj["kind"] = add_kind
            obj["net"] = net

            out.write(json.dumps(obj, separators=(",", ":")) + "\n")
            count += 1

    print(f"Passthrough {count} vectors (kind={add_kind}) -> {out_path}", file=sys.stderr)


def read_binary(path):
    with open(path, "rb") as f:
        return f.read()


def read_text(path):
    with open(path, "r") as f:
        return f.read()


def main():
    parser = argparse.ArgumentParser(
        description="Generate consensus-align JSONL vectors (v3.9.0)"
    )
    parser.add_argument("--mode", required=True,
                        choices=["header", "tx", "alignment", "passthrough", "praos", "vrf"],
                        help="Generation mode")
    parser.add_argument("--artifacts-dir",
                        help="Path to block candidate artifact directories (for --mode header)")
    parser.add_argument("--blocks-dir",
                        help="Path to blocks directory (for --mode tx)")
    parser.add_argument("--alignment-file",
                        help="Path to header_hash.jsonl (for --mode alignment)")
    parser.add_argument("--input",
                        help="Input JSONL file (for --mode passthrough)")
    parser.add_argument("--add-kind",
                        help="Kind to add in passthrough mode (praos|vrf)")
    parser.add_argument("--out", required=True,
                        help="Output JSONL file path")
    parser.add_argument("--net", default="preview",
                        help="Network label (default: preview)")
    parser.add_argument("--limit", type=int, default=360,
                        help="Max vectors to output (default: 360)")

    args = parser.parse_args()

    if args.mode == "header":
        if not args.artifacts_dir:
            print("ERROR: --artifacts-dir required for --mode header", file=sys.stderr)
            sys.exit(1)
        gen_header_vectors(args.artifacts_dir, args.out, args.net, args.limit)

    elif args.mode == "alignment":
        if not args.alignment_file:
            print("ERROR: --alignment-file required for --mode alignment", file=sys.stderr)
            sys.exit(1)
        gen_alignment_vectors(args.alignment_file, args.out, args.net, args.limit)

    elif args.mode == "tx":
        if not args.blocks_dir:
            print("ERROR: --blocks-dir required for --mode tx", file=sys.stderr)
            sys.exit(1)
        gen_tx_vectors(args.blocks_dir, args.out, args.net, args.limit)

    elif args.mode == "passthrough":
        if not args.input:
            print("ERROR: --input required for --mode passthrough", file=sys.stderr)
            sys.exit(1)
        if not args.add_kind:
            print("ERROR: --add-kind required for --mode passthrough", file=sys.stderr)
            sys.exit(1)
        if args.add_kind not in ("praos", "vrf"):
            print("ERROR: --add-kind must be praos or vrf", file=sys.stderr)
            sys.exit(1)
        passthrough(args.input, args.out, args.add_kind, args.net)

    elif args.mode in ("praos", "vrf"):
        print(
            f"ERROR: Praos/VRF vectors must come from oracle harness; "
            f"v3.1.0 generator is header-only.\n"
            f"Use --mode passthrough --input <oracle.jsonl> --add-kind {args.mode} "
            f"to add kind/net fields to existing oracle JSONL.",
            file=sys.stderr,
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
