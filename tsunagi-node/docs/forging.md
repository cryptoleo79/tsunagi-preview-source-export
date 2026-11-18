# Forging

## Purpose

The forge pipeline produces new Cardano blocks when the node wins a
Praos VRF leader check. It constructs a Conway-era block with a valid
header and writes it to disk for promotion and propagation.

## Components

| Component | File |
|---|---|
| Producer tick | src/producer/producer.zig |
| Header body builder | src/producer/cbor_block_header_body.zig |
| Block assembler | src/producer/cbor_block_full.zig |
| KES signing | src/producer/crypto/kes_sign.zig |
| VRF evaluation | src/producer/vrf.zig, crypto/sodium_vrf.zig |

## Inputs

- VRF signing key (TSUNAGI_VRF_SKEY_PATH)
- KES signing key (TSUNAGI_KES_SKEY_PATH)
- Epoch nonce (TSUNAGI_EPOCH_NONCE_HEX)
- Fragment tail (in-memory: slot, block_no, hash)
- Stake parameters (TSUNAGI_STAKE_FRACTION_X1E9)

## Outputs

Artifacts in producer_forge_sim/\<unix\>_\<slot\>/:
- block_header.cbor — full header: [body, kes_sig]
- block.cbor — full block: [era=7, [header, bodies...]]
- header_body.cbor — standalone body bytes (dryrun source)
- signature.bin — 448-byte KES signature (dryrun source)
- meta.json — slot, block_no, kes_period_offset
- verify.json — self-test results

Snapshot in forged_head_pending/ for seal-tip promotion.

## Flow

1. VRF evaluated for current_slot with epoch_nonce
2. Praos threshold check: u_x1e12 < thresh_x1e12
3. If leader: build 10-element header body (Conway)
4. KES sign header body (Sum6Kes, period = current - start)
5. Assemble header: array(2) [body, sig]
6. Assemble block: array(2) [era=7, array(5) [header, ...]]
7. Write artifacts and verify.json

## Critical invariant

The header slot must equal current_slot — the slot for which the VRF
proof was computed. This invariant is enforced because the VRF proof is
computed for current_slot. Any mismatch results in relay-side rejection.

## Failure modes

| Failure | Cause | Diagnostic |
|---|---|---|
| FORGE SKIP: tail mismatch | Chain tip moved | Normal during catch-up |
| FATAL: KES evolution failed | Offset exceeds 64 | Adjust KES_START_PERIOD or opcert |
| verify.json sig_verify_ok=false | Signing or assembly bug | Check header_body vs signature |
| VRF_VERIFY: FAIL (local) | Slot or nonce mismatch | Run verify_vrf, check nonce |

## Testing

```
cd src/producer/crypto
./verify_vrf      # VRF proof
./verify_forged   # KES signature
```
