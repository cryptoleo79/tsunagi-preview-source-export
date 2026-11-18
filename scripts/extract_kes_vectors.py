#!/usr/bin/env python3
"""Extract KES verification vectors from Tsunagi block capture files.

Reads binary capture files (u32-LE length + CBOR payload) and produces
JSONL vector files with KES public key, signature, slot, period, and
header body hash extracted from real Cardano block headers.

Requires: Python 3.6+ (stdlib only, no external packages).

Output: kes_vectors.jsonl suitable for later kes-align verification
once the exact "to-be-signed" message construction is implemented.
"""

import argparse
import hashlib
import json
import os
import struct
import sys

# ---------------------------------------------------------------------------
# Minimal CBOR navigator (same as capture_vectors.py)
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
# Block parsing — extended for KES vector extraction
# ---------------------------------------------------------------------------

SLOTS_PER_KES_PERIOD = 129600


def blake2b_256(data):
    """Compute blake2b-256 hash, return hex string."""
    h = hashlib.blake2b(data, digest_size=32)
    return h.hexdigest()


def parse_block_kes(payload):
    """Parse a Cardano block and extract KES-related fields.

    Returns dict with KES fields, or None on parse error.
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

    # Parse header: array(2) [header_body, kes_signature]
    hdr_arr = cbor_array_start(payload, header_start)
    if hdr_arr is None or hdr_arr[0] < 2:
        return None

    # Header body start/end (for raw bytes extraction)
    hdr_body_start = hdr_arr[1]
    hdr_body_end = cbor_skip(payload, hdr_body_start)
    if hdr_body_end is None:
        return None
    header_body_cbor = payload[hdr_body_start:hdr_body_end]
    header_body_hash = blake2b_256(header_body_cbor)

    # KES signature = second element of header array
    kes_sig_result = cbor_read_bytes(payload, hdr_body_end)
    if kes_sig_result is None:
        return None
    kes_sig_bytes, _ = kes_sig_result

    # Parse header body fields
    body_arr = cbor_array_start(payload, hdr_body_start)
    if body_arr is None:
        return None
    body_count, body_pos = body_arr

    result = {
        'era': era,
        'header_cbor_hex': header_cbor.hex(),
        'header_hash': header_hash,
        'header_body_cbor_hex': header_body_cbor.hex(),
        'header_body_hash': header_body_hash,
        'body_field_count': body_count,
        'kes_sig_hex': kes_sig_bytes.hex(),
        'kes_sig_len': len(kes_sig_bytes),
    }

    # Babbage/Conway: 10 items; Shelley/Allegra/Mary/Alonzo: 15 items
    if body_count >= 10:
        field_pos = body_pos

        # Field 0: block_number
        bn = cbor_read_uint(payload, field_pos)
        if bn:
            result['block_number'] = bn[0]
            field_pos = bn[1]
        else:
            field_pos = cbor_skip(payload, field_pos)
            if field_pos is None:
                return None

        # Field 1: slot
        sl = cbor_read_uint(payload, field_pos)
        if sl:
            result['slot'] = sl[0]
            result['kes_period'] = sl[0] // SLOTS_PER_KES_PERIOD
            field_pos = sl[1]
        else:
            field_pos = cbor_skip(payload, field_pos)
            if field_pos is None:
                return None

        # Field 2: prev_hash (bytes32 or null) — skip
        field_pos = cbor_skip(payload, field_pos)
        if field_pos is None:
            return None

        # Field 3: issuer_vkey (cold key, bytes32) — extract for reference
        issuer = cbor_read_bytes(payload, field_pos)
        if issuer and len(issuer[0]) == 32:
            result['issuer_vkey_hex'] = issuer[0].hex()
            field_pos = issuer[1]
        else:
            field_pos = cbor_skip(payload, field_pos)
            if field_pos is None:
                return None

        # Field 4: vrf_vkey (bytes32) — skip
        field_pos = cbor_skip(payload, field_pos)
        if field_pos is None:
            return None

        # Field 5: vrf_cert — skip
        field_pos = cbor_skip(payload, field_pos)
        if field_pos is None:
            return None

        # Field 6: body_size (uint) — skip
        field_pos = cbor_skip(payload, field_pos)
        if field_pos is None:
            return None

        # Field 7: body_hash (bytes32) — extract
        body_hash = cbor_read_bytes(payload, field_pos)
        if body_hash and len(body_hash[0]) == 32:
            result['block_body_hash_hex'] = body_hash[0].hex()
            field_pos = body_hash[1]
        else:
            field_pos = cbor_skip(payload, field_pos)
            if field_pos is None:
                return None

        # Field 8: op_cert = [hot_vkey(32), seq_no, kes_period, sigma(64)]
        opcert_arr = cbor_array_start(payload, field_pos)
        if opcert_arr and opcert_arr[0] >= 4:
            opcert_pos = opcert_arr[1]

            # op_cert[0]: hot_vkey = KES public key (32 bytes)
            hot_vkey = cbor_read_bytes(payload, opcert_pos)
            if hot_vkey and len(hot_vkey[0]) == 32:
                result['kes_pk_hex'] = hot_vkey[0].hex()
                opcert_pos = hot_vkey[1]
            else:
                opcert_pos = cbor_skip(payload, opcert_pos)
                if opcert_pos is None:
                    return result

            # op_cert[1]: sequence_number
            seq = cbor_read_uint(payload, opcert_pos)
            if seq:
                result['opcert_sequence'] = seq[0]
                opcert_pos = seq[1]
            else:
                opcert_pos = cbor_skip(payload, opcert_pos)
                if opcert_pos is None:
                    return result

            # op_cert[2]: kes_period (start period from opcert)
            kp = cbor_read_uint(payload, opcert_pos)
            if kp:
                result['opcert_kes_period'] = kp[0]
                opcert_pos = kp[1]
            else:
                opcert_pos = cbor_skip(payload, opcert_pos)
                if opcert_pos is None:
                    return result

            # op_cert[3]: sigma (cold key signature, 64 bytes)
            sigma = cbor_read_bytes(payload, opcert_pos)
            if sigma and len(sigma[0]) == 64:
                result['opcert_sigma_hex'] = sigma[0].hex()

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
            block = parse_block_kes(payload)
            if block:
                count += 1
                yield block


# ---------------------------------------------------------------------------
# Vector generation
# ---------------------------------------------------------------------------

def generate_kes_vectors(blocks, out_dir, net, count):
    """Generate KES JSONL vector file from parsed blocks."""
    os.makedirs(out_dir, exist_ok=True)
    kes_path = os.path.join(out_dir, 'kes_vectors.jsonl')

    seen = set()  # dedup by (kes_pk_hex, slot)
    written = 0
    skipped_no_pk = 0
    skipped_no_sig = 0
    skipped_dup = 0
    skipped_sig_len = 0

    with open(kes_path, 'w') as kf:
        for block in blocks:
            if written >= count:
                break

            kes_pk = block.get('kes_pk_hex', '')
            kes_sig = block.get('kes_sig_hex', '')
            slot = block.get('slot')

            if not kes_pk or len(kes_pk) != 64:
                skipped_no_pk += 1
                continue
            if not kes_sig:
                skipped_no_sig += 1
                continue
            if len(kes_sig) != 896:  # 448 bytes = 896 hex chars
                skipped_sig_len += 1
                continue

            dedup_key = (kes_pk, slot)
            if dedup_key in seen:
                skipped_dup += 1
                continue
            seen.add(dedup_key)

            kes_period = block.get('kes_period', 0)
            opcert_kes_period = block.get('opcert_kes_period', 0)

            vec = {
                'net': net,
                'slot': slot,
                'block_number': block.get('block_number'),
                'era': block.get('era'),
                'kes_period': kes_period,
                'opcert_kes_period': opcert_kes_period,
                'kes_period_offset': kes_period - opcert_kes_period,
                'kes_pk_hex': kes_pk,
                'kes_sig_hex': kes_sig,
                'header_body_hash_hex': block.get('header_body_hash', ''),
                'block_body_hash_hex': block.get('block_body_hash_hex', ''),
                'header_body_cbor_hex': block.get('header_body_cbor_hex', ''),
                'header_hash': block.get('header_hash', ''),
                'issuer_vkey_hex': block.get('issuer_vkey_hex', ''),
                'opcert_sequence': block.get('opcert_sequence'),
                'note': 'extracted from real block header',
            }
            kf.write(json.dumps(vec, separators=(',', ':')) + '\n')
            written += 1

    return written, skipped_no_pk, skipped_no_sig, skipped_dup, skipped_sig_len


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description='Extract KES verification vectors from Tsunagi captures.')
    parser.add_argument('--home', default=None,
        help='TSUNAGI_HOME directory (default: $TSUNAGI_HOME)')
    parser.add_argument('--net', default='preview',
        choices=['mainnet', 'preprod', 'preview', 'sancho'],
        help='Network name (default: preview)')
    parser.add_argument('--capture-dir', default=None,
        help='Capture directory (default: $TSUNAGI_HOME/captures)')
    parser.add_argument('--out', default=None,
        help='Output directory (default: $TSUNAGI_HOME/regress/kes)')
    parser.add_argument('--count', type=int, default=50,
        help='Max vectors to extract (default: 50)')
    args = parser.parse_args()

    # Resolve TSUNAGI_HOME
    home = args.home or os.environ.get('TSUNAGI_HOME')
    if home is None:
        print('ERROR: --home or TSUNAGI_HOME must be set')
        sys.exit(1)

    # Resolve capture directory
    capture_dir = args.capture_dir or os.path.join(home, 'captures')
    if not os.path.isdir(capture_dir):
        print(f'ERROR: capture directory not found: {capture_dir}')
        sys.exit(1)

    # Resolve output directory
    out_dir = args.out or os.path.join(home, 'regress', 'kes')

    # Find capture files for this network (sorted newest first)
    net = args.net
    cap_files = sorted(
        [os.path.join(capture_dir, f) for f in os.listdir(capture_dir)
         if f.endswith('.bin') and f.startswith(net)],
        reverse=True
    )
    if not cap_files:
        # Fallback: try all .bin files if net-specific not found
        cap_files = sorted(
            [os.path.join(capture_dir, f) for f in os.listdir(capture_dir)
             if f.endswith('.bin')],
            reverse=True
        )

    if not cap_files:
        print(f'ERROR: no .bin capture files in {capture_dir}')
        sys.exit(1)

    print(f'=== KES Vector Extraction ===')
    print(f'  home:        {home}')
    print(f'  net:         {net}')
    print(f'  capture_dir: {capture_dir}')
    print(f'  out:         {out_dir}')
    print(f'  count:       {args.count}')
    print(f'  files:       {len(cap_files)}')
    print()

    # Collect blocks from capture files
    def block_iter():
        remaining = args.count * 3  # read extra to account for skips
        for path in cap_files:
            fname = os.path.basename(path)
            print(f'  reading: {fname}')
            for block in read_capture_blocks(path, remaining):
                yield block
                remaining -= 1
                if remaining <= 0:
                    return

    written, skip_pk, skip_sig, skip_dup, skip_len = generate_kes_vectors(
        block_iter(), out_dir, net, args.count)

    print()
    print(f'=== Summary ===')
    print(f'  kes_vectors.jsonl:  {written} vectors')
    print(f'  skipped_no_pk:     {skip_pk}')
    print(f'  skipped_no_sig:    {skip_sig}')
    print(f'  skipped_dup:       {skip_dup}')
    print(f'  skipped_sig_len:   {skip_len} (expected 448 bytes / 896 hex)')
    print()

    if written == 0:
        print('WARN: no KES vectors generated')
        print('  Check that capture files contain Babbage/Conway era blocks')
        print('  with operational certificates.')
    else:
        kes_path = os.path.join(out_dir, 'kes_vectors.jsonl')
        print(f'  output: {kes_path}')

        # Quick validation of first vector
        with open(kes_path) as f:
            first = json.loads(f.readline())
            pk_len = len(first.get('kes_pk_hex', ''))
            sig_len = len(first.get('kes_sig_hex', ''))
            print(f'  first vector: slot={first.get("slot")} '
                  f'kes_period={first.get("kes_period")} '
                  f'pk_hex_len={pk_len} sig_hex_len={sig_len}')

    print()
    print('Done.')


if __name__ == '__main__':
    main()
