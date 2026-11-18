#!/usr/bin/env python3
"""Extract header-body CBOR vectors from Tsunagi capture .bin files.

Usage:
    python3 scripts/extract_header_body_bytes.py --capture <path.bin> --out <vectors.jsonl> [--max N]

Output: JSONL with one JSON object per block:
    {
        "slot": <u64>,
        "block_no": <u64>,
        "era": "<string>",
        "prev_hash_hex": "<hex|NULL>",
        "body_hash_hex": "<32-byte hex>",
        "header_body_cbor_hex": "<hex>",
        "kes_sig_hex": "<hex>",
        "kes_pk_hex": "<hex>",
        "kes_period_offset": <u64>
    }

Era labels: byron=0, shelley=1, allegra=2, mary=3, alonzo=4, babbage=5, conway=6, conway2=7
Hard-stop: exits non-zero if era changes mid-capture.
Python 3.6+ stdlib only.
"""

import struct
import sys
import json
import argparse

ERA_LABELS = {
    0: "byron", 1: "shelley", 2: "allegra", 3: "mary",
    4: "alonzo", 5: "babbage", 6: "conway", 7: "conway2",
}

SLOTS_PER_KES_PERIOD = 129600


def read_u32_le(f):
    b = f.read(4)
    if len(b) < 4:
        return None
    return struct.unpack('<I', b)[0]


def cbor_read_hdr(data, pos):
    """Read CBOR initial byte, return (major, addl, value, new_pos)."""
    if pos >= len(data):
        return None
    initial = data[pos]
    major = (initial >> 5) & 0x7
    addl = initial & 0x1f
    pos += 1
    if addl < 24:
        return (major, addl, addl, pos)
    elif addl == 24:
        return (major, addl, data[pos], pos + 1)
    elif addl == 25:
        v = struct.unpack('>H', data[pos:pos+2])[0]
        return (major, addl, v, pos + 2)
    elif addl == 26:
        v = struct.unpack('>I', data[pos:pos+4])[0]
        return (major, addl, v, pos + 4)
    elif addl == 27:
        v = struct.unpack('>Q', data[pos:pos+8])[0]
        return (major, addl, v, pos + 8)
    elif addl == 31:
        return (major, addl, -1, pos)
    return None


def cbor_skip(data, pos):
    """Skip one complete CBOR element, return new position."""
    if pos >= len(data):
        return pos
    r = cbor_read_hdr(data, pos)
    if r is None:
        return pos + 1
    major, addl, val, new_pos = r
    if major in (0, 1, 7):
        return new_pos
    elif major in (2, 3):
        if addl == 31:
            p = new_pos
            while p < len(data) and data[p] != 0xff:
                p = cbor_skip(data, p)
            return p + 1
        return new_pos + val
    elif major == 4:
        if addl == 31:
            p = new_pos
            while p < len(data) and data[p] != 0xff:
                p = cbor_skip(data, p)
            return p + 1
        p = new_pos
        for _ in range(val):
            p = cbor_skip(data, p)
        return p
    elif major == 5:
        if addl == 31:
            p = new_pos
            while p < len(data) and data[p] != 0xff:
                p = cbor_skip(data, p)
                p = cbor_skip(data, p)
            return p + 1
        p = new_pos
        for _ in range(val):
            p = cbor_skip(data, p)
            p = cbor_skip(data, p)
        return p
    elif major == 6:
        return cbor_skip(data, new_pos)
    return new_pos


def cbor_read_uint(data, pos):
    """Read a CBOR unsigned integer, return (value, new_pos)."""
    r = cbor_read_hdr(data, pos)
    if r is None or r[0] != 0:
        return None, pos
    return r[2], r[3]


def cbor_read_bytes(data, pos):
    """Read a CBOR byte string, return (bytes, new_pos)."""
    r = cbor_read_hdr(data, pos)
    if r is None or r[0] != 2:
        return None, pos
    length = r[2]
    start = r[3]
    return data[start:start+length], start + length


def extract_block(payload):
    """Extract header-body vector from a raw block payload.
    Returns dict or None on parse error."""
    if len(payload) < 4:
        return None

    # Outer: [era, block_content]
    r = cbor_read_hdr(payload, 0)
    if r is None or r[0] != 4 or r[2] < 2:
        return None
    pos = r[3]

    # Era
    era_val, pos = cbor_read_uint(payload, pos)
    if era_val is None:
        return None
    era_label = ERA_LABELS.get(era_val, f"unknown_{era_val}")

    # Block content: should be array(5) for post-Alonzo
    r = cbor_read_hdr(payload, pos)
    if r is None or r[0] != 4:
        return None
    n_content = r[2]
    pos = r[3]

    # Header = [header_body, kes_sig]
    header_start = pos
    r = cbor_read_hdr(payload, pos)
    if r is None or r[0] != 4 or r[2] != 2:
        return None
    pos = r[3]

    # Header body (10-element array for Babbage/Conway/era7)
    hdr_body_start = pos
    r = cbor_read_hdr(payload, pos)
    if r is None or r[0] != 4:
        return None
    n_fields = r[2]
    pos = r[3]

    if n_fields == 10:
        # [0] block_number
        block_no, pos = cbor_read_uint(payload, pos)
        if block_no is None:
            return None

        # [1] slot
        slot, pos = cbor_read_uint(payload, pos)
        if slot is None:
            return None

        # [2] prev_hash: bytes(32) or null
        if payload[pos] == 0xf6:
            prev_hash_hex = "NULL"
            pos += 1
        else:
            prev_hash, pos = cbor_read_bytes(payload, pos)
            if prev_hash is None or len(prev_hash) != 32:
                return None
            prev_hash_hex = prev_hash.hex()

        # [3] issuer_vk: bytes(32)
        pos = cbor_skip(payload, pos)

        # [4] vrf_vkey: bytes(32)
        pos = cbor_skip(payload, pos)

        # [5] vrf_result: array(2) = [output, proof]
        pos = cbor_skip(payload, pos)

        # [6] block_body_size: uint
        pos = cbor_skip(payload, pos)

        # [7] block_body_hash: bytes(32)
        body_hash, pos = cbor_read_bytes(payload, pos)
        if body_hash is None or len(body_hash) != 32:
            return None

        # [8] operational_cert: array(4)
        opcert_start = pos
        r = cbor_read_hdr(payload, pos)
        if r is None or r[0] != 4 or r[2] != 4:
            return None
        pos = r[3]

        # opcert[0] = hot_vk (kes_pk)
        kes_pk, pos = cbor_read_bytes(payload, pos)
        if kes_pk is None or len(kes_pk) != 32:
            return None

        # opcert[1] = seq_no
        pos = cbor_skip(payload, pos)

        # opcert[2] = kes_period
        kes_period, pos = cbor_read_uint(payload, pos)
        if kes_period is None:
            return None

        # opcert[3] = sigma
        pos = cbor_skip(payload, pos)

        # [9] protocol_version: array(2)
        pos = cbor_skip(payload, pos)

        hdr_body_end = pos
        hdr_body_cbor = payload[hdr_body_start:hdr_body_end]

        # KES signature
        kes_sig, kes_end = cbor_read_bytes(payload, pos)
        if kes_sig is None:
            return None

        # KES period offset
        current_kes_period = slot // SLOTS_PER_KES_PERIOD
        kes_period_offset = current_kes_period - kes_period

        return {
            "slot": slot,
            "block_no": block_no,
            "era": era_label,
            "prev_hash_hex": prev_hash_hex,
            "body_hash_hex": body_hash.hex(),
            "header_body_cbor_hex": hdr_body_cbor.hex(),
            "kes_sig_hex": kes_sig.hex(),
            "kes_pk_hex": kes_pk.hex(),
            "kes_period_offset": kes_period_offset,
        }

    elif n_fields == 15:
        # Shelley/Alonzo format - skip fields to get what we need
        # [0] block_number
        block_no, pos = cbor_read_uint(payload, pos)
        if block_no is None:
            return None

        # [1] slot
        slot, pos = cbor_read_uint(payload, pos)
        if slot is None:
            return None

        # [2] prev_hash (or null)
        if payload[pos] == 0xf6:
            prev_hash_hex = "NULL"
            pos += 1
        else:
            prev_hash, pos = cbor_read_bytes(payload, pos)
            if prev_hash is None or len(prev_hash) != 32:
                return None
            prev_hash_hex = prev_hash.hex()

        # [3..7] skip to [8] body_hash
        for _ in range(5):
            pos = cbor_skip(payload, pos)

        # [8] body_hash
        body_hash, pos = cbor_read_bytes(payload, pos)
        if body_hash is None or len(body_hash) != 32:
            return None

        # skip remaining fields to find kes_pk and kes_period
        # For 15-field: need to identify opcert location
        # Skip [9]..[14]
        for _ in range(6):
            pos = cbor_skip(payload, pos)

        hdr_body_end = pos
        hdr_body_cbor = payload[hdr_body_start:hdr_body_end]

        # KES signature
        kes_sig, _ = cbor_read_bytes(payload, pos)
        if kes_sig is None:
            return None

        return {
            "slot": slot,
            "block_no": block_no,
            "era": era_label,
            "prev_hash_hex": prev_hash_hex,
            "body_hash_hex": body_hash.hex(),
            "header_body_cbor_hex": hdr_body_cbor.hex(),
            "kes_sig_hex": kes_sig.hex(),
            "kes_pk_hex": "",
            "kes_period_offset": 0,
        }

    else:
        return None


def main():
    parser = argparse.ArgumentParser(description="Extract header-body CBOR vectors from Tsunagi capture files")
    parser.add_argument("--capture", required=True, help="Path to capture .bin file")
    parser.add_argument("--out", required=True, help="Output JSONL path")
    parser.add_argument("--max", type=int, default=0, help="Max blocks to extract (0=all)")
    args = parser.parse_args()

    first_era = None
    count = 0
    errors = 0

    with open(args.capture, 'rb') as f, open(args.out, 'w') as out:
        while True:
            length = read_u32_le(f)
            if length is None:
                break
            if length == 0:
                continue

            payload = f.read(length)
            if len(payload) < length:
                break

            vec = extract_block(payload)
            if vec is None:
                errors += 1
                print(f"WARNING: cannot parse block at index {count + errors}", file=sys.stderr)
                continue

            # Era hard-stop
            if first_era is None:
                first_era = vec["era"]
            elif vec["era"] != first_era:
                print(f"ERROR: era changed mid-capture; re-run extraction on a single-era range", file=sys.stderr)
                print(f"  first era: {first_era}, changed to: {vec['era']} at block {count}", file=sys.stderr)
                sys.exit(1)

            out.write(json.dumps(vec, separators=(',', ':')) + '\n')
            count += 1

            if args.max > 0 and count >= args.max:
                break

    print(f"Extracted {count} vectors (era={first_era}, errors={errors}) -> {args.out}", file=sys.stderr)
    if count == 0:
        print("ERROR: no vectors extracted", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
