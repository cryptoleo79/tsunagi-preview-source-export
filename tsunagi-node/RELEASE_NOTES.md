# Release Notes

## Preview Propagation Milestone (2026-03-26)

The block propagation pipeline is operational on the Cardano preview
network.

### What works

- ChainSync serves fragment and sealed headers to connected relays
- Pipelined MsgRequestNext consumed from batched mux segments
- LIVE_PUSH delivers forged headers on live AwaitReply connections
- VRF proof, KES signature, and OPCERT verify locally
- Forge slot matches VRF-proven slot

### In validation

- End-to-end relay block acceptance
- BlockFetch completion (bf_tx > 0, served_block = true)

### Fixes applied

| Issue | Root cause | Fix |
|---|---|---|
| Relay rejects RollForward | Era index 6 instead of 7 | era_index → 7 |
| Pipelined messages dropped | Single CBOR decode per segment | Loop over payload |
| VRF proof invalid | Header slot ≠ VRF slot | forge_slot = current_slot |
| OPCERT sigma invalid | kes_period mismatch | Re-issued at kes_period=800 |
| OPCERT sigma invalid | Wrong kes.vkey | Re-issued with correct key |
| Header rejected | protocol_version [10,0] | Set to [10,2] |
| VRF invalid | Stale epoch nonce | Updated to current epoch |
| Threshold mismatch | sigma 20% vs 0.087% | Corrected stake fraction |
