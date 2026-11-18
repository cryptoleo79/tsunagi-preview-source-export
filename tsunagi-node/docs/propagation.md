# Propagation

## Purpose

The propagation server delivers forged blocks to a connected Cardano
relay over the Ouroboros N2N protocol. It serves ChainSync headers
(fragment + sealed) and BlockFetch block bodies from a sealed artifact
directory.

## Components

| Component | File |
|---|---|
| Propagation server | src/net/propagation_server.zig |
| ChainSync server | src/protocols/chainsync_server.zig |
| BlockFetch server | src/protocols/blockfetch_server.zig |

## Inputs

Artifact directory containing:
- block_header.cbor — sealed tip header
- block.cbor — full block
- meta.json — slot, block_no, hash
- fragment/ — recent chain headers and bodies

## Outputs

- Mux segments to relay: ChainSync RollForward, BlockFetch responses
- Propagation receipt (JSON) after each connection

## Modes

**Fragment serving.** Serves recent real-chain headers from the fragment
directory. The relay uses these to find an intersection.

**Sealed serving.** After fragments are exhausted, serves the forged
sealed tip header.

**LIVE_PUSH.** When the connection is in AwaitReply and the artifact
changes on disk, sends a proactive MsgRollForward with the new header.

## Key behaviors

- Pipelined MsgRequestNext: all CBOR messages in a batched mux segment
  are consumed
- AwaitReply triggers LIVE_PUSH_POLL (1-second artifact checks)
- Artifact reload is atomic via meta.json change detection

## Failure modes

| Failure | Drawer | Diagnostic |
|---|---|---|
| Relay disconnects after RollFwd | Encoding/Crypto | Check era, verify_vrf, verify_forged |
| bf_rx=0 after LIVE_PUSH_SEND | Consensus | Check threshold, nonce, stake |
| bf_tx=0 after bf_rx>0 | Propagation | Check block.cbor availability |
| LIVE_PUSH never fires | Operator | Check seal-tip, forge-watch |
| Artifact never changes | Operator | Check forge pipeline, promote path |

## Testing

```
tsunagi-node propagate-serve \
  --net preview \
  --artifact-dir <path> \
  --allowlist 127.0.0.1 \
  --port 3033
```

Monitor:

```
grep -E 'LIVE_PUSH_SEND|bf_rx|bf_tx|served_block' <logfile>
```
