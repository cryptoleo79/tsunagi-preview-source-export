#!/usr/bin/env python3
"""
extract-opcert-sigma.py — decode a Cardano NodeOperationalCertificate (node.cert)
into operator-readable opcert fields, and (optionally) reproduce the node's forge
self-verify ed25519 check.

The forge self-verify (src/producer/producer.zig) computes:

    sigma_msg = kes_root(32) || seq_no(8, big-endian) || kes_period(8, big-endian)
    ed25519_verify(pk = cold_vk, msg = sigma_msg, sig = opcert_sigma)

This script extracts kes_root, counter (seq), kes_period, cold_vk and sigma from
node.cert so the operator can set TSUNAGI_OPCERT_SIGMA_HEX deterministically instead
of hand-slicing the cborHex (which caused the June 2026 corruption incident — see
docs/incidents/2026-06-opcert-self-verify-root-cause.md).

Usage:
    python3 scripts/extract-opcert-sigma.py path/to/node.cert
    python3 scripts/extract-opcert-sigma.py --verify path/to/node.cert
    python3 scripts/extract-opcert-sigma.py --env path/to/node.cert    # print env-ready lines only

No external dependencies (pure-python ed25519, RFC 8032).
"""
import argparse
import binascii
import json
import struct
import sys


def load_cborhex(path):
    """Read a TextEnvelope node.cert and return its cborHex (str)."""
    with open(path, "r") as f:
        obj = json.load(f)
    if "cborHex" not in obj:
        raise ValueError(f"{path}: not a TextEnvelope (no cborHex field)")
    return obj["cborHex"].strip()


def decode_opcert(cborhex):
    """
    Decode the operational certificate CBOR:
        [ [ kes_vkey(bstr32), counter(uint), kes_period(uint), sigma(bstr64) ], cold_vkey(bstr32) ]
    Returns a dict of hex strings / ints.
    """
    b = binascii.unhexlify(cborhex)
    i = 0

    def rd(n):
        nonlocal i
        v = b[i:i + n]
        i += n
        return v

    if b[i] != 0x82:
        raise ValueError("expected outer CBOR array(2)")
    i += 1
    if b[i] != 0x84:
        raise ValueError("expected inner CBOR array(4)")
    i += 1

    if b[i] != 0x58 or b[i + 1] != 0x20:
        raise ValueError("expected 0x5820 (bstr32) for kes_vkey")
    i += 2
    kes = rd(32)

    counter, i = _uint(b, i)
    period, i = _uint(b, i)

    if b[i] != 0x58 or b[i + 1] != 0x40:
        raise ValueError("expected 0x5840 (bstr64) for sigma")
    i += 2
    sigma = b[i:i + 64]
    i += 64

    if b[i] != 0x58 or b[i + 1] != 0x20:
        raise ValueError("expected 0x5820 (bstr32) for cold_vkey")
    i += 2
    cold = b[i:i + 32]
    i += 32

    return {
        "kes_root": kes.hex(),
        "counter": counter,
        "period": period,
        "sigma": sigma.hex(),
        "cold_vk": cold.hex(),
    }


def _uint(b, i):
    """Decode a CBOR unsigned integer at offset i. Returns (value, new_i)."""
    t = b[i]
    if t < 0x18:
        return t, i + 1
    if t == 0x18:
        return b[i + 1], i + 2
    if t == 0x19:
        return int.from_bytes(b[i + 1:i + 3], "big"), i + 3
    if t == 0x1a:
        return int.from_bytes(b[i + 1:i + 5], "big"), i + 5
    if t == 0x1b:
        return int.from_bytes(b[i + 1:i + 9], "big"), i + 9
    raise ValueError(f"unexpected CBOR uint header byte 0x{t:02x}")


# ---------------------------------------------------------------------------
# pure-python ed25519 verify (RFC 8032), no dependencies
# ---------------------------------------------------------------------------
import hashlib

_p = 2 ** 255 - 19
_d = (-121665 * pow(121666, _p - 2, _p)) % _p
_I = pow(2, (_p - 1) // 4, _p)


def _xrecover(y):
    xx = (y * y - 1) * pow(_d * y * y + 1, _p - 2, _p) % _p
    x = pow(xx, (_p + 3) // 8, _p)
    if (x * x - xx) % _p:
        x = x * _I % _p
    if x % 2:
        x = _p - x
    return x


_By = 4 * pow(5, _p - 2, _p) % _p
_B = (_xrecover(_By) % _p, _By % _p)


def _edwards(P, Q):
    x1, y1 = P
    x2, y2 = Q
    x3 = (x1 * y2 + x2 * y1) * pow(1 + _d * x1 * x2 * y1 * y2, _p - 2, _p) % _p
    y3 = (y1 * y2 + x1 * x2) * pow(1 - _d * x1 * x2 * y1 * y2, _p - 2, _p) % _p
    return (x3, y3)


def _scalarmult(P, e):
    if e == 0:
        return (0, 1)
    Q = _scalarmult(P, e // 2)
    Q = _edwards(Q, Q)
    if e & 1:
        Q = _edwards(Q, P)
    return Q


def _decodepoint(s):
    y = int.from_bytes(s, "little") & ((1 << 255) - 1)
    x = _xrecover(y)
    if x & 1 != (s[31] >> 7) & 1:
        x = _p - x
    return (x, y)


def ed25519_verify(sig, msg, pk):
    R = _decodepoint(sig[:32])
    A = _decodepoint(pk)
    S = int.from_bytes(sig[32:], "little")
    h = int.from_bytes(hashlib.sha512(sig[:32] + pk + msg).digest(), "little")
    return _scalarmult(_B, S) == _edwards(R, _scalarmult(A, h))


def self_verify(fields):
    """Reproduce the node's forge self-verify. Returns bool."""
    kes = binascii.unhexlify(fields["kes_root"])
    cold = binascii.unhexlify(fields["cold_vk"])
    sigma = binascii.unhexlify(fields["sigma"])
    msg = kes + struct.pack(">Q", fields["counter"]) + struct.pack(">Q", fields["period"])
    return ed25519_verify(sigma, msg, cold)


def main():
    ap = argparse.ArgumentParser(description="Decode a Cardano node.cert opcert.")
    ap.add_argument("node_cert", help="path to node.cert (TextEnvelope)")
    ap.add_argument("--verify", action="store_true",
                    help="also reproduce the forge self-verify ed25519 check")
    ap.add_argument("--env", action="store_true",
                    help="print only the env-ready export lines")
    args = ap.parse_args()

    try:
        cborhex = load_cborhex(args.node_cert)
        f = decode_opcert(cborhex)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    if args.env:
        print(f"TSUNAGI_COLD_VK_HEX={f['cold_vk']}")
        print(f"TSUNAGI_OPCERT_SEQ={f['counter']}")
        print(f"TSUNAGI_KES_START_PERIOD={f['period']}")
        print(f"TSUNAGI_OPCERT_SIGMA_HEX={f['sigma']}")
        return 0

    print(f"node.cert: {args.node_cert}")
    print(f"  cold_vk  : {f['cold_vk']}  (first8 {f['cold_vk'][:16]})")
    print(f"  kes_root : {f['kes_root']}  (first8 {f['kes_root'][:16]})")
    print(f"  counter  : {f['counter']}   <- TSUNAGI_OPCERT_SEQ / opcert_state.json seq_no must equal this")
    print(f"  period   : {f['period']}    <- TSUNAGI_KES_START_PERIOD must equal this")
    print(f"  sigma    : {f['sigma']}")
    print(f"             (len {len(f['sigma'])} hex = {len(f['sigma'])//2} bytes; first8 {f['sigma'][:16]})")
    print()
    print("Env-ready (paste into the launcher; do NOT hand-slice the cborHex):")
    print(f"  TSUNAGI_OPCERT_SIGMA_HEX={f['sigma']}")

    if args.verify:
        ok = self_verify(f)
        print()
        msg = f"kes_root || u64be({f['counter']}) || u64be({f['period']})"
        print(f"SELF-VERIFY PARITY ({msg} vs cold_vk): {'PASS' if ok else 'FAIL'}")
        if not ok:
            print("  -> the certificate itself does not self-verify; re-issue the opcert.")
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
