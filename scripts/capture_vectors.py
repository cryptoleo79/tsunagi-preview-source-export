#!/usr/bin/env python3
"""Capture alignment vectors from Tsunagi block capture files.

Reads binary capture files (u32-LE length + CBOR payload) and produces
JSONL vector files for praos-align, vrf-align, and header-align harnesses.

Requires: Python 3.6+ (stdlib only, no external packages).
"""

import argparse
import hashlib
import json
import os
import struct
import sys

# ---------------------------------------------------------------------------
# Minimal CBOR navigator (enough to slice Cardano block structures)
# ---------------------------------------------------------------------------

def cbor_info(data, pos):
    """Parse CBOR initial byte. Returns (major, value, pos_after_header)."""
    if pos >= len(data):
        return None
    b = data[pos]
    major = b >> 5
    info = b & 0x1f
    pos += 1
    if info < 24:
        return (major, info, pos)
    elif info == 24:
        return (major, data[pos], pos + 1)
    elif info == 25:
        return (major, int.from_bytes(data[pos:pos+2], 'big'), pos + 2)
    elif info == 26:
        return (major, int.from_bytes(data[pos:pos+4], 'big'), pos + 4)
    elif info == 27:
        return (major, int.from_bytes(data[pos:pos+8], 'big'), pos + 8)
    elif info == 31:
        return (major, -1, pos)  # indefinite length
    return None


def cbor_skip(data, pos):
    """Skip one CBOR element. Returns position after it, or None on error."""
    info = cbor_info(data, pos)
    if info is None:
        return None
    major, val, pos2 = info
    if major in (0, 1):  # uint / negint
        return pos2
    elif major in (2, 3):  # bytes / text
        if val < 0:  # indefinite
            while pos2 < len(data) and data[pos2] != 0xff:
                pos2 = cbor_skip(data, pos2)
                if pos2 is None:
                    return None
            return pos2 + 1 if pos2 < len(data) else None
        return pos2 + val if pos2 + val <= len(data) else None
    elif major == 4:  # array
        if val < 0:
            while pos2 < len(data) and data[pos2] != 0xff:
                pos2 = cbor_skip(data, pos2)
                if pos2 is None:
                    return None
            return pos2 + 1 if pos2 < len(data) else None
        for _ in range(val):
            pos2 = cbor_skip(data, pos2)
            if pos2 is None:
                return None
        return pos2
    elif major == 5:  # map
        count = val if val >= 0 else 0
        if val < 0:
            while pos2 < len(data) and data[pos2] != 0xff:
                pos2 = cbor_skip(data, pos2)
                if pos2 is None:
                    return None
                pos2 = cbor_skip(data, pos2)
                if pos2 is None:
                    return None
            return pos2 + 1 if pos2 < len(data) else None
        for _ in range(count):
            pos2 = cbor_skip(data, pos2)
            if pos2 is None:
                return None
            pos2 = cbor_skip(data, pos2)
            if pos2 is None:
                return None
        return pos2
    elif major == 6:  # tag
        return cbor_skip(data, pos2)
    elif major == 7:  # simple / float
        return pos2
    return None


def cbor_read_uint(data, pos):
    """Read a CBOR unsigned integer. Returns (value, next_pos) or None."""
    info = cbor_info(data, pos)
    if info is None or info[0] != 0:
        return None
    return (info[1], info[2])


def cbor_read_bytes(data, pos):
    """Read CBOR byte string. Returns (bytes, next_pos) or None."""
    info = cbor_info(data, pos)
    if info is None or info[0] != 2:
        return None
    major, length, pos2 = info
    if length < 0 or pos2 + length > len(data):
        return None
    return (data[pos2:pos2+length], pos2 + length)


def cbor_array_start(data, pos):
    """Read CBOR array header. Returns (count, pos_after_header) or None."""
    info = cbor_info(data, pos)
    if info is None or info[0] != 4:
        return None
    return (info[1], info[2])

# ---------------------------------------------------------------------------
# Block parsing
# ---------------------------------------------------------------------------

def blake2b_256(data):
    """Compute blake2b-256 hash, return hex string."""
    h = hashlib.blake2b(data, digest_size=32)
    return h.hexdigest()


def parse_block(payload):
    """Parse a Cardano block from CBOR payload.

    Returns dict with extracted fields, or None on parse error.
    """
    # Outer: array(2) [era, block_body]
    outer = cbor_array_start(payload, 0)
    if outer is None or outer[0] < 2:
        return None
    pos = outer[1]

    # Era
    era_info = cbor_read_uint(payload, pos)
    if era_info is None:
        return None
    era, pos = era_info

    # Inner: array(4 or 5) [header, tx_bodies, witnesses, aux_data, ...]
    inner = cbor_array_start(payload, pos)
    if inner is None or inner[0] < 4:
        return None
    inner_count, pos = inner

    # Header CBOR bytes (element 0 of inner array)
    header_start = pos
    header_end = cbor_skip(payload, pos)
    if header_end is None:
        return None
    header_cbor = payload[header_start:header_end]
    header_hash = blake2b_256(header_cbor)

    # Parse header: array(2) [header_body, signature]
    hdr_arr = cbor_array_start(payload, header_start)
    if hdr_arr is None or hdr_arr[0] < 2:
        return None

    # Header body: array(10) for Babbage/Conway, array(15) for Shelley
    hdr_body_start = hdr_arr[1]
    hdr_body_end = cbor_skip(payload, hdr_body_start)
    if hdr_body_end is None:
        return None

    body_arr = cbor_array_start(payload, hdr_body_start)
    if body_arr is None:
        return None
    body_count, body_pos = body_arr

    result = {
        'era': era,
        'header_cbor': header_cbor,
        'header_hash': header_hash,
        'body_field_count': body_count,
    }

    # Extract fields from header body
    # For 10-item (Babbage/Conway): [block_num, slot, prev_hash, issuer_vkey,
    #   vrf_vkey, vrf_cert, body_size, body_hash, op_cert, proto_version]
    if body_count >= 10:
        field_pos = body_pos

        # Field 0: block_number
        bn = cbor_read_uint(payload, field_pos)
        if bn:
            result['block_number'] = bn[0]
            field_pos = bn[1]
        else:
            field_pos = cbor_skip(payload, field_pos)

        # Field 1: slot
        sl = cbor_read_uint(payload, field_pos)
        if sl:
            result['slot'] = sl[0]
            field_pos = sl[1]
        else:
            field_pos = cbor_skip(payload, field_pos)

        # Field 2: prev_hash (bytes32 or null)
        field_pos = cbor_skip(payload, field_pos)

        # Field 3: issuer_vkey (bytes)
        field_pos = cbor_skip(payload, field_pos)

        # Field 4: vrf_vkey (bytes)
        field_pos = cbor_skip(payload, field_pos)

        # Field 5: vrf_cert = [output, proof]
        vrf_arr = cbor_array_start(payload, field_pos)
        if vrf_arr and vrf_arr[0] >= 2:
            vrf_pos = vrf_arr[1]
            vrf_out = cbor_read_bytes(payload, vrf_pos)
            if vrf_out:
                result['vrf_output'] = vrf_out[0]
                vrf_pos = vrf_out[1]
                vrf_prf = cbor_read_bytes(payload, vrf_pos)
                if vrf_prf:
                    result['vrf_proof'] = vrf_prf[0]

    return result


def read_capture_blocks(capture_path, max_blocks):
    """Read blocks from a Tsunagi capture file. Yields parsed block dicts."""
    count = 0
    with open(capture_path, 'rb') as f:
        while count < max_blocks:
            hdr = f.read(4)
            if len(hdr) < 4:
                break
            length = struct.unpack('<I', hdr)[0]
            if length == 0 or length > 16 * 1024 * 1024:  # sanity: max 16MB
                break
            payload = f.read(length)
            if len(payload) < length:
                break
            block = parse_block(payload)
            if block:
                count += 1
                yield block

# ---------------------------------------------------------------------------
# VRF u mapping (same integer formula as Tsunagi's vrfOutputToU_x1e12)
# ---------------------------------------------------------------------------

def vrf_output_to_u_x1e12(output_bytes):
    """Map first 8 bytes of VRF output to u in [1, 1e12].

    Exact integer math matching Tsunagi's vrfOutputToU_x1e12.
    """
    r = int.from_bytes(output_bytes[0:8], 'big')
    u = (r * 10**12) // (2**64 - 1)
    return max(1, u)

# ---------------------------------------------------------------------------
# Vector generation
# ---------------------------------------------------------------------------

def generate_vectors(blocks, out_dir, mode, count):
    """Generate JSONL vector files from parsed blocks."""
    os.makedirs(out_dir, exist_ok=True)

    header_path = os.path.join(out_dir, 'header_hash.jsonl')
    vrf_path = os.path.join(out_dir, 'vrf_u.jsonl')
    praos_path = os.path.join(out_dir, 'praos_threshold.jsonl')

    header_count = 0
    vrf_count = 0

    with open(header_path, 'w') as hf, open(vrf_path, 'w') as vf:
        for block in blocks:
            if header_count >= count and vrf_count >= count:
                break

            slot = block.get('slot', '?')
            block_num = block.get('block_number', '?')
            era = block.get('era', '?')

            # Header hash vector
            if header_count < count:
                vec = {
                    'kind': 'header_hash',
                    'mode': 'cardano-header-bytes',
                    'header_bytes_hex': block['header_cbor'].hex(),
                    'expected_header_hash_hex': block['header_hash'],
                    'note': f'slot={slot} block={block_num} era={era} net={mode}',
                }
                hf.write(json.dumps(vec, separators=(',', ':')) + '\n')
                header_count += 1

            # VRF vector (if cert extracted)
            if vrf_count < count and 'vrf_output' in block:
                output = block['vrf_output']
                vec = {
                    'kind': 'vrf_u',
                    'vrf_output_hex': output.hex(),
                    'expected_u_x1e12': vrf_output_to_u_x1e12(output),
                    'note': f'slot={slot} block={block_num} era={era} net={mode}',
                }
                if 'vrf_proof' in block:
                    vec['vrf_proof_hex'] = block['vrf_proof'].hex()
                vf.write(json.dumps(vec, separators=(',', ':')) + '\n')
                vrf_count += 1

    # Praos threshold: document gap, write skeleton
    with open(praos_path, 'w') as pf:
        # Known mainnet ASC = 0.05 (50000 x1e6), but stake fractions need
        # ledger state queries. Write skeleton with null expected values.
        note = (f'net={mode} asc=0.05(mainnet_default) '
                'expected_threshold_x1e12=null(requires_cardano_node_reference)')
        for sigma_pct in [1, 5, 10, 25, 50, 100]:
            stake_x1e9 = sigma_pct * 10_000_000  # percentage * 1e7
            vec = {
                'kind': 'praos_threshold',
                'stake_fraction_x1e9': stake_x1e9,
                'asc_x1e6': 50000,
                'expected_threshold_x1e12': None,
                'note': f'sigma={sigma_pct}% {note}',
            }
            pf.write(json.dumps(vec, separators=(',', ':')) + '\n')

    return header_count, vrf_count

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description='Capture alignment vectors from Tsunagi block captures.')
    parser.add_argument('--node-socket', default=None,
        help='cardano-node socket path (optional; requires cardano-cli)')
    parser.add_argument('--capture-dir', default=None,
        help='Tsunagi captures directory (default: $TSUNAGI_HOME/captures/)')
    parser.add_argument('--out', required=True,
        help='Output directory for JSONL vector files')
    parser.add_argument('--count', type=int, default=50,
        help='Max vectors per file (default: 50)')
    parser.add_argument('--mode', default='mainnet',
        choices=['mainnet', 'preprod', 'preview', 'sancho'],
        help='Network mode for note fields (default: mainnet)')
    args = parser.parse_args()

    if args.node_socket:
        print('WARN: --node-socket specified but cardano-cli integration')
        print('      is not yet implemented. Use --capture-dir instead.')
        print('      (cardano-cli not found on this system)')

    # Resolve capture directory
    capture_dir = args.capture_dir
    if capture_dir is None:
        home = os.environ.get('TSUNAGI_HOME')
        if home:
            capture_dir = os.path.join(home, 'captures')
    if capture_dir is None or not os.path.isdir(capture_dir):
        print(f'ERROR: capture directory not found: {capture_dir}')
        print('  Set TSUNAGI_HOME or use --capture-dir')
        sys.exit(1)

    # Find capture files (sorted by name, newest first for freshest data)
    cap_files = sorted(
        [os.path.join(capture_dir, f) for f in os.listdir(capture_dir)
         if f.endswith('.bin')],
        reverse=True
    )
    if not cap_files:
        print(f'ERROR: no .bin files in {capture_dir}')
        sys.exit(1)

    print(f'=== Capture Vectors ===')
    print(f'  capture_dir: {capture_dir}')
    print(f'  files: {len(cap_files)}')
    print(f'  out: {args.out}')
    print(f'  count: {args.count}')
    print(f'  mode: {args.mode}')
    print()

    # Collect blocks from capture files
    def block_iter():
        for path in cap_files:
            fname = os.path.basename(path)
            print(f'  reading: {fname}')
            yield from read_capture_blocks(path, args.count)

    header_n, vrf_n = generate_vectors(
        block_iter(), args.out, args.mode, args.count)

    # Praos skeleton is always 6 lines
    praos_n = 6

    print()
    print(f'=== Summary ===')
    print(f'  header_hash.jsonl:      {header_n} vectors')
    print(f'  vrf_u.jsonl:            {vrf_n} vectors')
    print(f'  praos_threshold.jsonl:  {praos_n} vectors (skeleton, expected=null)')
    print()

    if header_n == 0:
        print('WARN: no header vectors generated (capture files empty?)')
    if vrf_n == 0:
        print('WARN: no VRF vectors generated (VRF certs not found in headers)')

    print('Done.')


if __name__ == '__main__':
    main()
