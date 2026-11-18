#!/usr/bin/env python3
"""Derive KES signed message from extracted header vectors.

Reads kes_vectors.jsonl (from extract_kes_vectors.py) and produces a
derived JSONL file with msg_hex computed according to the specified mode.
The derived file is suitable for verification with:
  tsunagi-node kes-align --vectors <derived.jsonl>

Modes:
  direct    — msg = header_body_cbor bytes (raw CBOR)
  blake2b256 — msg = blake2b256(header_body_cbor) (32 bytes)

Requires: Python 3.6+ (stdlib only, no external packages).
"""

import argparse
import hashlib
import json
import os
import sys


def blake2b_256(data):
    """Compute blake2b-256 hash, return bytes."""
    h = hashlib.blake2b(data, digest_size=32)
    return h.digest()


def derive_msg(header_body_cbor_hex, mode):
    """Derive the signed message bytes from header body CBOR hex.

    Returns hex string of the derived message.
    """
    header_body_bytes = bytes.fromhex(header_body_cbor_hex)

    if mode == 'direct':
        return header_body_bytes.hex()
    elif mode == 'blake2b256':
        return blake2b_256(header_body_bytes).hex()
    else:
        raise ValueError(f'unknown mode: {mode}')


def main():
    parser = argparse.ArgumentParser(
        description='Derive KES signed message from extracted header vectors.')
    parser.add_argument('--vectors', required=True,
        help='Input kes_vectors.jsonl file')
    parser.add_argument('--mode', required=True,
        choices=['direct', 'blake2b256'],
        help='Message derivation mode')
    args = parser.parse_args()

    if not os.path.isfile(args.vectors):
        print(f'ERROR: file not found: {args.vectors}')
        sys.exit(1)

    # Output file: same directory, mode-suffixed name
    out_dir = os.path.dirname(args.vectors) or '.'
    out_path = os.path.join(out_dir, f'kes_vectors_derived.{args.mode}.jsonl')

    print(f'=== KES Message Derivation ===')
    print(f'  input:  {args.vectors}')
    print(f'  mode:   {args.mode}')
    print(f'  output: {out_path}')
    print()

    total = 0
    skipped = 0

    with open(args.vectors) as inf, open(out_path, 'w') as outf:
        for line in inf:
            line = line.strip()
            if not line:
                continue

            v = json.loads(line)

            header_body_hex = v.get('header_body_cbor_hex', '')
            if not header_body_hex:
                skipped += 1
                continue

            kes_pk = v.get('kes_pk_hex', '')
            kes_sig = v.get('kes_sig_hex', '')
            if len(kes_pk) != 64 or len(kes_sig) != 896:
                skipped += 1
                continue

            # Use kes_period_offset (relative to opcert start) for verification
            # This is the period parameter for verifySum6Kes (0..63)
            period_offset = v.get('kes_period_offset')
            if period_offset is None:
                # Fallback: compute from absolute periods
                kes_period = v.get('kes_period', 0)
                opcert_period = v.get('opcert_kes_period', 0)
                period_offset = kes_period - opcert_period

            if period_offset < 0 or period_offset >= 64:
                print(f'  WARN: skipping slot={v.get("slot")} '
                      f'period_offset={period_offset} (out of range)')
                skipped += 1
                continue

            msg_hex = derive_msg(header_body_hex, args.mode)

            derived = {
                'kes_pk_hex': kes_pk,
                'kes_period': period_offset,
                'msg_hex': msg_hex,
                'kes_sig_hex': kes_sig,
                'expected_result': 'OK',
                'mode': args.mode,
                'slot': v.get('slot'),
                'block_number': v.get('block_number'),
                'net': v.get('net', ''),
                'abs_kes_period': v.get('kes_period'),
                'opcert_kes_period': v.get('opcert_kes_period'),
            }
            outf.write(json.dumps(derived, separators=(',', ':')) + '\n')
            total += 1

    print(f'  derived: {total} vectors')
    print(f'  skipped: {skipped}')
    if total > 0:
        # Show first vector msg_hex length
        with open(out_path) as f:
            first = json.loads(f.readline())
            msg_len = len(first.get('msg_hex', '')) // 2
            print(f'  msg_hex bytes (first): {msg_len}')
            print(f'  kes_period (first): {first.get("kes_period")}')
    print()
    print(f'Next: run verification with:')
    print(f'  tsunagi-node kes-align --vectors {out_path}')
    print()
    print('Done.')


if __name__ == '__main__':
    main()
