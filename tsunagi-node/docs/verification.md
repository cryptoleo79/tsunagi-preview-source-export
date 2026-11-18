# Verification

## Purpose

TSUNAGI provides standalone verifiers that check cryptographic
correctness against real artifact files without starting the full
node.

## Tools

### verify_forged

KES signature check against the artifact header.

Build:

```
cd src/producer/crypto
zig build-exe verify_forged.zig -fno-llvm -fno-lld
```

Run:

```
./verify_forged
```

Reads block_header.cbor from the propagation artifact. Extracts the
embedded header body and KES signature. Verifies using hot_vk from
the opcert field and the computed KES period offset.

Output: `KES_VERIFY: OK` or the specific failure (bad_sig_len,
period_out_of_range, pk_mismatch, ed25519_fail).

### verify_vrf

VRF proof check against the artifact header.

Build:

```
cd src/producer/crypto
zig build-exe verify_vrf.zig -lsodium -lc -fno-llvm -fno-lld
```

Run:

```
./verify_vrf
```

Reads block_header.cbor from the propagation artifact. Extracts slot,
vrf_vkey, vrf_output, and vrf_proof. Computes
blake2b256("L" || epoch_nonce || BE64(slot)) and calls
crypto_vrf_ietfdraft03_verify.

**Important:** verify_vrf currently uses a hardcoded epoch nonce. Update
it when the epoch changes before running.

Output: `VRF_VERIFY: OK` with output_match, or `VRF_VERIFY: FAIL`.

## When to use

| Question | Tool |
|---|---|
| Is KES valid for the artifact header? | verify_forged |
| Is VRF valid for the artifact header? | verify_vrf |
| Relay rejects — which field? | verify_vrf first, then verify_forged |

## Interpreting results

| Result | Meaning | Next step |
|---|---|---|
| KES_VERIFY: OK | Signature valid | Issue is not KES |
| KES_VERIFY: ed25519_fail | Sig doesn't match body | Check if body modified after signing |
| KES_VERIFY: pk_mismatch | Tree structure inconsistent | Check KES key state or evolution |
| KES_VERIFY: period_out_of_range | Offset ≥ 64 | Adjust KES_START_PERIOD |
| VRF_VERIFY: OK | Proof valid for slot + nonce | Issue is not VRF |
| VRF_VERIFY: FAIL | Proof doesn't verify | Check nonce freshness, check slot |
| VRF output_match=false | Proof valid but output differs | Header output corrupted |

## Known limitations

- verify_vrf currently uses a hardcoded epoch nonce. Must be updated
  each epoch or parameterized in a future version.
- The forge-sim command reads standalone files (header_body.cbor,
  signature.bin) from the dryrun path, not the forge path. These may
  diverge from the embedded header in block_header.cbor. Use
  verify_forged for authoritative KES checks.
