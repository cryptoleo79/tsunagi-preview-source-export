#!/usr/bin/env python3
"""
gen_readiness_sim_vectors.py — Generate readiness-sim JSONL vectors (v3.9.0).

Scans producer_dryrun/blocks/<unix>_<slot>/ directories, extracts verification
data (header CBOR, block CBOR, hashes, KES signature), and outputs one JSONL
line per valid candidate.

v3.9.0: alignment mode for mainnet (decodes header CBOR, no blocks/ required).

Modes:
  --mode blocks      (default) Read from --blocks-dir (producer_dryrun/blocks/)
  --mode alignment   Read from --alignment-file (regress/alignment/header_hash.jsonl)

Filters (blocks mode): sig_kind == "real_kes", sig_verify_ok == true, net matches --net.

Python 3.6+ stdlib only.
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

def gen_alignment_readiness_vectors(alignment_file, out_path, net, limit):
    """Generate readiness-sim vectors from regress/alignment/header_hash.jsonl.

    Decodes Cardano header CBOR to extract all fields. Sets block_cbor_hex=null
    and header_only=true (requires readiness-sim --header-only).
    Hard-fails on any extraction error.
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
                print(f"ERROR: line {line_no}: kes_sig is not 448 bytes", file=sys.stderr)
                sys.exit(1)

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
                body_hash_idx = 7
                opcert_idx = 8

            body_hash = header_body[body_hash_idx]
            if not isinstance(body_hash, (bytes, bytearray)) or len(body_hash) != 32:
                print(f"ERROR: line {line_no}: body_hash not 32 bytes", file=sys.stderr)
                sys.exit(1)

            opcert = header_body[opcert_idx]
            if not isinstance(opcert, list) or len(opcert) < 3:
                print(f"ERROR: line {line_no}: opcert not [hot_vkey, counter, kes_period, ...]", file=sys.stderr)
                sys.exit(1)

            kes_pk = opcert[0]
            cert_kes_period = opcert[2]  # [hot_vkey, counter, kes_period, cold_sig]

            if not isinstance(kes_pk, (bytes, bytearray)) or len(kes_pk) != 32:
                print(f"ERROR: line {line_no}: kes_pk not 32 bytes", file=sys.stderr)
                sys.exit(1)

            current_kes_period = slot // SLOTS_PER_KES_PERIOD
            kes_period_offset = current_kes_period - cert_kes_period

            # header_body_cbor raw bytes: outer array is 0x82, body starts at offset 1
            body_cbor_start = 1
            body_cbor_end = cbor_item_end(header_bytes, body_cbor_start)
            header_body_cbor = header_bytes[body_cbor_start:body_cbor_end]

            vector = {
                "slot": int(slot),
                "block_no": int(block_no),
                "net": net,
                "block_header_cbor_hex": header_bytes_hex,
                "block_header_hash_hex": expected_hash_hex,
                "block_cbor_hex": None,
                "block_body_hash_hex": body_hash.hex(),
                "kes_pk_hex": kes_pk.hex(),
                "kes_period_offset": int(kes_period_offset),
                "sig_hex": kes_sig.hex(),
                "header_body_cbor_hex": header_body_cbor.hex(),
                "header_only": True,
            }

            vectors.append((int(slot), vector))

    if not vectors:
        print(f"ERROR: no matching alignment vectors for net={net}", file=sys.stderr)
        sys.exit(1)

    # Sort by slot ascending, apply limit (take latest N)
    vectors.sort(key=lambda x: x[0])
    if limit and len(vectors) > limit:
        vectors = vectors[-limit:]

    with open(out_path, "w") as out_f:
        for _, vec in vectors:
            out_f.write(json.dumps(vec, separators=(",", ":")) + "\n")

    print(f"Vectors written: {len(vectors)}  output: {out_path}", file=sys.stderr)
    return 0


# ── Blocks mode (existing) ──────────────────────────────────────────

def gen_blocks_readiness_vectors(blocks_dir, out_path, net, limit):
    """Generate readiness-sim vectors from producer_dryrun/blocks/ directories."""
    if not os.path.isdir(blocks_dir):
        print(f"ERROR: blocks directory not found: {blocks_dir}", file=sys.stderr)
        sys.exit(1)

    subdirs = sorted(
        d for d in os.listdir(blocks_dir)
        if os.path.isdir(os.path.join(blocks_dir, d))
    )

    # Collect with slot for sorting
    vectors = []
    skipped = 0

    for dirname in subdirs:
        dirpath = os.path.join(blocks_dir, dirname)

        try:
            vec = extract_vector(dirpath, net)
        except SkipDir as e:
            print(f"  skip: {dirname} ({e})", file=sys.stderr)
            skipped += 1
            continue
        except Exception as e:
            print(f"  error: {dirname} ({e})", file=sys.stderr)
            skipped += 1
            continue

        vectors.append((vec["slot"], vec))

    # Sort by slot ascending, apply limit (take latest N)
    vectors.sort(key=lambda x: x[0])
    if limit and len(vectors) > limit:
        vectors = vectors[-limit:]

    with open(out_path, "w") as out_f:
        for _, vec in vectors:
            out_f.write(json.dumps(vec, separators=(",", ":")) + "\n")

    written = len(vectors)
    if written == 0:
        print("ERROR: no valid vectors extracted", file=sys.stderr)
        sys.exit(1)

    print(f"Vectors written: {written}  skipped: {skipped}  output: {out_path}", file=sys.stderr)
    return 0


class SkipDir(Exception):
    pass


def extract_vector(dirpath, expected_net):
    """Extract a readiness-sim vector from a single block candidate directory."""

    meta_path = os.path.join(dirpath, "meta.json")
    with open(meta_path) as f:
        meta = json.load(f)

    sig_kind = meta.get("sig_kind", "")
    if sig_kind != "real_kes":
        raise SkipDir(f"sig_kind={sig_kind}")

    net = meta.get("net", "")
    if net != expected_net:
        raise SkipDir(f"net={net}")

    verify_path = os.path.join(dirpath, "verify.json")
    with open(verify_path) as f:
        verify = json.load(f)
    if not (verify.get("sig_verify_ok") is True or verify.get("sig_ok") is True):
        raise SkipDir("sig not verified")

    slot = meta.get("slot")
    if slot is None:
        raise SkipDir("missing slot")
    block_no = meta.get("block_no")
    if block_no is None:
        raise SkipDir("missing block_no")
    kes_pk_hex = meta.get("kes_pk_hex")
    if kes_pk_hex is None:
        raise SkipDir("missing kes_pk_hex")
    kes_period_offset = meta.get("kes_period_offset")
    if kes_period_offset is None:
        raise SkipDir("missing kes_period_offset")

    block_header_bytes = read_binary(dirpath, "block_header.cbor")
    block_bytes = read_binary(dirpath, "block.cbor")
    header_body_bytes = read_binary(dirpath, "header_body.cbor")
    sig_bytes = read_binary(dirpath, "signature.bin")

    if len(sig_bytes) != 448:
        raise SkipDir(f"signature.bin size={len(sig_bytes)}")

    block_header_hash_hex = read_hex(dirpath, "block_header_hash.hex")
    block_body_hash_hex = read_hex(dirpath, "block_body_hash.hex")

    return {
        "slot": int(slot),
        "block_no": int(block_no),
        "net": net,
        "block_header_cbor_hex": block_header_bytes.hex(),
        "block_header_hash_hex": block_header_hash_hex,
        "block_cbor_hex": block_bytes.hex(),
        "block_body_hash_hex": block_body_hash_hex,
        "kes_pk_hex": kes_pk_hex,
        "kes_period_offset": int(kes_period_offset),
        "sig_hex": sig_bytes.hex(),
        "header_body_cbor_hex": header_body_bytes.hex(),
    }


def read_binary(dirpath, filename):
    path = os.path.join(dirpath, filename)
    with open(path, "rb") as f:
        data = f.read()
    if len(data) == 0:
        raise SkipDir(f"{filename} is empty")
    return data


def read_hex(dirpath, filename):
    path = os.path.join(dirpath, filename)
    with open(path) as f:
        text = f.read().strip()
    if len(text) != 64:
        raise SkipDir(f"{filename} len={len(text)}")
    return text


def main():
    parser = argparse.ArgumentParser(
        description="Generate readiness-sim JSONL vectors (v3.9.0)")
    parser.add_argument("--net", required=True,
                        help="Network: preview, preprod, mainnet, sancho")
    parser.add_argument("--mode", default="blocks", choices=["blocks", "alignment"],
                        help="Generation mode (default: blocks)")
    parser.add_argument("--blocks-dir",
                        help="Path to producer_dryrun/blocks/ (for --mode blocks)")
    parser.add_argument("--alignment-file",
                        help="Path to header_hash.jsonl (for --mode alignment)")
    parser.add_argument("--out", required=True,
                        help="Output JSONL file (overwrites if exists)")
    parser.add_argument("--limit", type=int, default=50,
                        help="Max vectors to extract (default: 50)")
    args = parser.parse_args()

    if args.mode == "alignment":
        if not args.alignment_file:
            print("ERROR: --alignment-file required for --mode alignment", file=sys.stderr)
            sys.exit(1)
        return gen_alignment_readiness_vectors(
            args.alignment_file, args.out, args.net, args.limit)
    else:
        if not args.blocks_dir:
            print("ERROR: --blocks-dir required for --mode blocks", file=sys.stderr)
            sys.exit(1)
        return gen_blocks_readiness_vectors(
            args.blocks_dir, args.out, args.net, args.limit)


if __name__ == "__main__":
    sys.exit(main())
