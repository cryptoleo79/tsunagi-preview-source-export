#!/usr/bin/env python3
"""Auto-capture alignment vectors from new block capture files.

Incrementally extracts header-hash and VRF vectors from Tsunagi capture
segments, appends to JSONL vector files, and triggers the alignment suite.

Cursor-based: tracks the last processed capture filename so only new
segments are processed on each run.  Deduplicates by header hash.

Python 3 stdlib only — no external dependencies.
"""

import argparse
import hashlib
import json
import os
import struct
import subprocess
import sys


# ---------------------------------------------------------------------------
# Minimal CBOR navigator (same as capture_vectors.py)
# ---------------------------------------------------------------------------

def cbor_info(data, pos):
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
        return (major, -1, pos)
    return None


def cbor_skip(data, pos):
    info = cbor_info(data, pos)
    if info is None:
        return None
    major, val, pos2 = info
    if major in (0, 1):
        return pos2
    elif major in (2, 3):
        if val < 0:
            while pos2 < len(data) and data[pos2] != 0xff:
                pos2 = cbor_skip(data, pos2)
                if pos2 is None:
                    return None
            return pos2 + 1 if pos2 < len(data) else None
        return pos2 + val if pos2 + val <= len(data) else None
    elif major == 4:
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
    elif major == 5:
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
    elif major == 6:
        return cbor_skip(data, pos2)
    elif major == 7:
        return pos2
    return None


def cbor_read_uint(data, pos):
    info = cbor_info(data, pos)
    if info is None or info[0] != 0:
        return None
    return (info[1], info[2])


def cbor_read_bytes(data, pos):
    info = cbor_info(data, pos)
    if info is None or info[0] != 2:
        return None
    major, length, pos2 = info
    if length < 0 or pos2 + length > len(data):
        return None
    return (data[pos2:pos2+length], pos2 + length)


def cbor_array_start(data, pos):
    info = cbor_info(data, pos)
    if info is None or info[0] != 4:
        return None
    return (info[1], info[2])


# ---------------------------------------------------------------------------
# Block parsing
# ---------------------------------------------------------------------------

def blake2b_256(data):
    return hashlib.blake2b(data, digest_size=32).hexdigest()


def parse_block(payload):
    outer = cbor_array_start(payload, 0)
    if outer is None or outer[0] < 2:
        return None
    pos = outer[1]

    era_info = cbor_read_uint(payload, pos)
    if era_info is None:
        return None
    era, pos = era_info

    inner = cbor_array_start(payload, pos)
    if inner is None or inner[0] < 4:
        return None
    _, pos = inner

    header_start = pos
    header_end = cbor_skip(payload, pos)
    if header_end is None:
        return None
    header_cbor = payload[header_start:header_end]
    header_hash = blake2b_256(header_cbor)

    hdr_arr = cbor_array_start(payload, header_start)
    if hdr_arr is None or hdr_arr[0] < 2:
        return None

    hdr_body_start = hdr_arr[1]
    body_arr = cbor_array_start(payload, hdr_body_start)
    if body_arr is None:
        return None
    body_count, body_pos = body_arr

    result = {
        'era': era,
        'header_cbor': header_cbor,
        'header_hash': header_hash,
    }

    if body_count >= 10:
        field_pos = body_pos

        bn = cbor_read_uint(payload, field_pos)
        if bn:
            result['block_number'] = bn[0]
            field_pos = bn[1]
        else:
            field_pos = cbor_skip(payload, field_pos)

        sl = cbor_read_uint(payload, field_pos)
        if sl:
            result['slot'] = sl[0]
            field_pos = sl[1]
        else:
            field_pos = cbor_skip(payload, field_pos)

        field_pos = cbor_skip(payload, field_pos)  # prev_hash
        field_pos = cbor_skip(payload, field_pos)  # issuer_vkey
        field_pos = cbor_skip(payload, field_pos)  # vrf_vkey

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
    count = 0
    with open(capture_path, 'rb') as f:
        while count < max_blocks:
            hdr = f.read(4)
            if len(hdr) < 4:
                break
            length = struct.unpack('<I', hdr)[0]
            if length == 0 or length > 16 * 1024 * 1024:
                break
            payload = f.read(length)
            if len(payload) < length:
                break
            block = parse_block(payload)
            if block:
                count += 1
                yield block


def vrf_output_to_u_x1e12(output_bytes):
    r = int.from_bytes(output_bytes[0:8], 'big')
    u = (r * 10**12) // (2**64 - 1)
    return max(1, u)


# ---------------------------------------------------------------------------
# Cursor management
# ---------------------------------------------------------------------------

CURSOR_FILE = ".auto_capture_cursor"


def read_cursor(alignment_dir):
    """Read last processed capture filename from cursor file.

    Returns the filename string, or None if no cursor exists.
    """
    path = os.path.join(alignment_dir, CURSOR_FILE)
    if not os.path.isfile(path):
        return None
    with open(path) as f:
        return f.read().strip() or None


def write_cursor(alignment_dir, filename):
    """Write the last processed capture filename to cursor file."""
    path = os.path.join(alignment_dir, CURSOR_FILE)
    with open(path, 'w') as f:
        f.write(filename + '\n')


# ---------------------------------------------------------------------------
# Existing hash set (for dedup)
# ---------------------------------------------------------------------------

def load_existing_hashes(jsonl_path):
    """Load header hashes already present in the vector file."""
    hashes = set()
    if not os.path.isfile(jsonl_path):
        return hashes
    with open(jsonl_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                h = obj.get('expected_header_hash_hex') or obj.get('header_hash')
                if h:
                    hashes.add(h)
            except json.JSONDecodeError:
                pass
    return hashes


# ---------------------------------------------------------------------------
# Incremental extraction
# ---------------------------------------------------------------------------

def find_new_captures(capture_dir, cursor_filename):
    """Return sorted list of capture filenames newer than cursor.

    Files are sorted ascending by name (oldest first).
    The active capture file (no timestamp, e.g. 'mainnet.bin') is always
    processed last, and only if it's larger than before.
    """
    all_files = sorted(
        f for f in os.listdir(capture_dir)
        if f.endswith('.bin') and os.path.isfile(os.path.join(capture_dir, f))
    )
    if not all_files:
        return []

    # Split into rotated segments (with timestamp) and active file (no timestamp digit before .bin)
    rotated = []
    active = []
    for f in all_files:
        # Rotated files match pattern: <net>.<digits>.bin
        base = f[:-4]  # strip .bin
        parts = base.rsplit('.', 1)
        if len(parts) == 2 and parts[1].isdigit():
            rotated.append(f)
        else:
            active.append(f)

    # Filter rotated files newer than cursor
    if cursor_filename:
        rotated = [f for f in rotated if f > cursor_filename]

    # Active files always at the end (they get re-read each run since they grow)
    # But we skip active files — they're being written to by the node.
    # Only process completed (rotated) segments for safety.
    return rotated


def extract_from_captures(capture_dir, alignment_dir, net, new_files, max_new):
    """Extract vectors from new capture files and append to JSONL files."""
    header_path = os.path.join(alignment_dir, 'header_hash.jsonl')
    vrf_path = os.path.join(alignment_dir, 'vrf_u.jsonl')

    # Load existing hashes for dedup
    existing = load_existing_hashes(header_path)

    header_added = 0
    vrf_added = 0
    total_blocks = 0
    last_processed = None

    with open(header_path, 'a') as hf, open(vrf_path, 'a') as vf:
        for fname in new_files:
            if header_added >= max_new:
                break

            fpath = os.path.join(capture_dir, fname)
            print(f"  processing: {fname}")

            for block in read_capture_blocks(fpath, max_new * 2):
                total_blocks += 1
                if header_added >= max_new:
                    break

                hh = block['header_hash']
                if hh in existing:
                    continue
                existing.add(hh)

                slot = block.get('slot', '?')
                block_num = block.get('block_number', '?')
                era = block.get('era', '?')

                # Header hash vector
                vec = {
                    'kind': 'header_hash',
                    'mode': 'cardano-header-bytes',
                    'header_bytes_hex': block['header_cbor'].hex(),
                    'expected_header_hash_hex': hh,
                    'note': f'slot={slot} block={block_num} era={era} net={net}',
                }
                hf.write(json.dumps(vec, separators=(',', ':')) + '\n')
                header_added += 1

                # VRF vector
                if 'vrf_output' in block:
                    output = block['vrf_output']
                    vrf_vec = {
                        'kind': 'vrf_u',
                        'vrf_output_hex': output.hex(),
                        'expected_u_x1e12': vrf_output_to_u_x1e12(output),
                        'note': f'slot={slot} block={block_num} era={era} net={net}',
                    }
                    if 'vrf_proof' in block:
                        vrf_vec['vrf_proof_hex'] = block['vrf_proof'].hex()
                    vf.write(json.dumps(vrf_vec, separators=(',', ':')) + '\n')
                    vrf_added += 1

            last_processed = fname

    return header_added, vrf_added, total_blocks, last_processed


# ---------------------------------------------------------------------------
# Alignment suite trigger
# ---------------------------------------------------------------------------

def run_alignment_suite(home):
    """Run the alignment suite after vector extraction."""
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          'run_alignment_suite.py')
    if not os.path.isfile(script):
        print(f"  WARN: alignment suite not found: {script}")
        return False

    print(f"  running: python3 {script} --home {home}")
    try:
        proc = subprocess.run(
            [sys.executable, script, '--home', home],
            timeout=300,
        )
        return proc.returncode == 0
    except subprocess.TimeoutExpired:
        print("  WARN: alignment suite timed out (300s)")
        return False


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description='Auto-capture alignment vectors from new block captures.')
    parser.add_argument(
        '--home', required=True,
        help='TSUNAGI_HOME directory')
    parser.add_argument(
        '--net', required=True,
        choices=['mainnet', 'preprod', 'preview', 'sancho'],
        help='Network name (for vector note fields)')
    parser.add_argument(
        '--max-new', type=int, default=50,
        help='Max new vectors to extract per run (default: 50)')
    args = parser.parse_args()

    home = os.path.abspath(args.home)
    capture_dir = os.path.join(home, 'captures')
    alignment_dir = os.path.join(home, 'regress', 'alignment')

    if not os.path.isdir(home):
        print(f"ERROR: TSUNAGI_HOME does not exist: {home}", file=sys.stderr)
        sys.exit(1)

    if not os.path.isdir(capture_dir):
        print(f"No captures directory: {capture_dir}")
        print("Nothing to do.")
        sys.exit(0)

    os.makedirs(alignment_dir, exist_ok=True)

    # Read cursor
    cursor = read_cursor(alignment_dir)

    # Find new captures
    new_files = find_new_captures(capture_dir, cursor)
    if not new_files:
        print(f"No new capture segments since cursor: {cursor or '(none)'}")
        print("Nothing to do.")
        sys.exit(0)

    print(f"=== Auto Capture Vectors ({args.net}) ===")
    print(f"  home:       {home}")
    print(f"  captures:   {capture_dir}")
    print(f"  cursor:     {cursor or '(first run)'}")
    print(f"  new files:  {len(new_files)}")
    print(f"  max-new:    {args.max_new}")
    print()

    # Extract
    h_added, v_added, blocks, last = extract_from_captures(
        capture_dir, alignment_dir, args.net, new_files, args.max_new)

    # Update cursor to last fully processed file
    if last:
        write_cursor(alignment_dir, last)
        print(f"\n  cursor updated: {last}")

    # Count totals
    header_path = os.path.join(alignment_dir, 'header_hash.jsonl')
    vrf_path = os.path.join(alignment_dir, 'vrf_u.jsonl')
    h_total = sum(1 for _ in open(header_path)) if os.path.isfile(header_path) else 0
    v_total = sum(1 for _ in open(vrf_path)) if os.path.isfile(vrf_path) else 0

    print(f"\n=== Summary ===")
    print(f"  blocks scanned:     {blocks}")
    print(f"  header vectors:     +{h_added} (total: {h_total})")
    print(f"  vrf vectors:        +{v_added} (total: {v_total})")

    if h_added == 0 and v_added == 0:
        print("\n  No new vectors extracted (all duplicates or empty captures).")
        print("Done.")
        sys.exit(0)

    # Run alignment suite
    print(f"\n=== Alignment Suite ===")
    ok = run_alignment_suite(home)
    if ok:
        print("  alignment suite: PASS")
    else:
        print("  alignment suite: WARN (check output above)")

    print("\nDone.")


if __name__ == '__main__':
    main()
