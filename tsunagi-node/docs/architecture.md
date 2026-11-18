# TSUNAGI Architecture

## 1. Overview

TSUNAGI is a Zig 0.15.2 implementation of the Cardano Ouroboros Praos protocol.
It runs as a single OS process. Internally it spawns a small set of background
threads (propagation server, log tee, optional metrics HTTP server) and runs
the ChainSync follower on the main thread. There is no separate consensus
daemon, no embedded VM, and no foreign runtime — KES/VRF/CBOR/LMDB are all
in-process Zig.

This document describes the runtime as of the mode-collapse PR set
(#171 / #172 / #173): a single `TSUNAGI_MODE = preview_safe | live`
selector replaces the legacy dryrun / preview-only / no-broadcast /
forge-policy / bcast-enable env tangle.

## 2. Startup sequence

The `run` subcommand in `src/main.zig` performs these steps in order. Line
ranges refer to `src/main.zig` after PR #171.

1. **argv parse**. Recognised flags on the `run` subcommand: `--net
   <mainnet|preprod|preview|sancho>`, `--peer host:port` (override default
   relay), `--debug`, `--lang en|ja`. Any unknown flag is fatal.

2. **Network resolution**. `--net` flag wins over `TSUNAGI_NET` env;
   absence is fatal. The matched `network_profile` carries the home
   suffix used in the next step.

3. **Resolve `TSUNAGI_HOME`** (`resolveHome`). Priority: `TSUNAGI_HOME`
   env → `$HOME/<network_profile.home_suffix>` (e.g. `~/.tsunagi-preview`).

4. **Load `${TSUNAGI_HOME}/forge.env`** (`loadForgeConfig`). `KEY=VALUE`
   per line; `#` comments, blank lines, optional `export ` prefix and
   matched surrounding quotes are accepted. Each line is applied via
   libc `setenv(name, value, overwrite=1)`, so the file deterministically
   wins over stale shell exports. A `CONFIG_LOADED: path=… keys=N` line
   is printed on success.

5. **Parse `TSUNAGI_MODE`** — reads AFTER forge.env so the file value is
   visible. Default `preview_safe`. Unknown values are fatal:
   `FATAL: TSUNAGI_MODE='<v>' — supported values: preview_safe | live`.
   Prints `MODE: preview_safe (no broadcast)` or `MODE: live (broadcast enabled)`.

6. **Forge gate validation**. When `TSUNAGI_FORGE_ENABLE=1`:
   - `--net` must be `preview` (FATAL otherwise).
   - `TSUNAGI_FORGE_REQUIRE_GUARDIAN_CONFIRM=1` must be set (FATAL otherwise).
   - `TSUNAGI_TXSUB_BROADCAST` must NOT be set (mutually exclusive — FATAL).
   On success, prints `FORGE: enabled (mode=<preview_safe|live>)`.

7. **Acquire instance lock** (`autonomy.acquireLock`).
   `flock(${TSUNAGI_HOME}/lock, LOCK_EX|LOCK_NB)` (`ops/autonomy.zig`).
   A second `tsunagi-node` against the same home prints
   `ANOTHER_INSTANCE_HOLDS_LOCK` and exits.

8. **Install log tee** (`autonomy.installLogTee`). Replaces stdout/stderr
   fds with a pipe; a worker thread mirrors every write to the original
   terminal AND to `${TSUNAGI_HOME}/logs/node.log`. Rotates at 5 MiB,
   keeps 5 backups.

9. **Clean-marker handling**. `markActive` deletes `${TSUNAGI_HOME}/clean`;
   `defer markClean` re-creates it on graceful return. Absence on next
   boot is the unclean-shutdown signal for downstream recovery scans.

10. **Metrics server (optional)**. When `--debug` is passed or
    `TSUNAGI_METRICS=1` is set, an HTTP metrics server starts. Bind from
    `TSUNAGI_METRICS_ADDR` (default `127.0.0.1`), port from
    `TSUNAGI_METRICS_PORT` (default `9080`).

11. **Propagation server (optional)**. When forge is enabled,
    `propagation_server.spawnBackground` starts the relay-facing server
    as a detached thread. Allowlist `127.0.0.1`. Serves from
    `${TSUNAGI_HOME}/propagation_artifact/`.

12. **Enter ChainSync follower**. Control hands to
    `chainsync_mux_smoke.runWithOptions`, which establishes the upstream
    TCP connection, performs N2N handshake, drives ChainSync, persists
    headers/blocks to the fragment store and LMDB, and (when forge is
    enabled) feeds the producer pipeline.

## 3. Runtime pipeline

```
   upstream peer --[ChainSync N2N]--> follower --[fragment]--> ${HOME}/chain_tip/fragment/
                                              \
                                               --[LMDB]--> header_store / utxo

   producer --[VRF lottery]--> [leader slot] --[KES Sum6 sign]--> sealed artifact
   sealed artifact --[propagation_server]--> [TSUNAGI_MODE gate]--> relay BlockFetch
```

### a. ChainSync follower
`src/net/chainsync/follower.zig` is the main thread loop. It opens a single
TCP connection to the upstream peer chosen at startup (relay default, or
`--peer` override, or `selectMainnetPeer` for mainnet). Over the muxed N2N
bearer it runs FindIntersect, then a continuous RequestNext loop, validating
header CBOR and chaining hashes before appending. Block bodies are fetched
over BlockFetch on the same bearer. SIGINT/SIGTERM handlers installed by
the follower set the stop flag and let the main loop unwind cleanly through
`defer markClean(state_dir)` in main.

### b. Fragment store
Append-only sequence under `${TSUNAGI_HOME}/chain_tip/fragment/`. Each
accepted block produces five sibling files keyed by an 8-digit zero-padded
sequence: `{seq:08d}.header`, `.body`, `.hash`, `.prev_hash`, `.meta`.
This is the canonical ancestor chain consumed by both the producer
(parent selection) and the propagation server's chain-tip bridge.

### c. LMDB stores
`src/store/` contains the LMDB modules:

- `header_store.zig` — point-in-time header index used for FindIntersect
  responses on the propagation side and for parent lookup.
- `lmdb_utxo.zig` — UTxO snapshot, fed by replay/backfill and live ChainSync.
- `lmdb_seed.zig`, `lmdb_backfill.zig`, `lmdb_backfill_dir.zig`,
  `lmdb_backfill_autopilot.zig` — bulk import paths from capture
  files and signed `.tsf` snapshots.
- `snapshot_cmd.zig`, `snapshot_sign.zig`, `bootstrap_cmd.zig`,
  `lmdb_digest_cmd.zig`, `tsf_artifact_cmd.zig`,
  `capture_retention_cmd.zig`, `autoswitch_cmd.zig`, `tsf.zig` —
  out-of-band tooling.

The path is `${TSUNAGI_LMDB}` — must be a real directory (values `"0"`,
`"1"`, or empty are rejected).

### d. Producer
`src/producer/producer.zig` runs the consensus-side loop driven from
within the follower's tick. Its forge context is initialised from
`TSUNAGI_MODE` (the same env value main reads):

```
const is_live = (TSUNAGI_MODE == "live");
ctx.forge_all_flags_set = ctx.forge_enabled and ctx.forge_require_guardian;
ctx.forge_gate_policy   = is_live ? .enforce_safe : .observe;
```

`forge_all_flags_set` opens the forge execution gate in BOTH modes when
the operator has set `TSUNAGI_FORGE_ENABLE=1` and
`TSUNAGI_FORGE_REQUIRE_GUARDIAN_CONFIRM=1`. The two modes differ only at
the propagation boundary; on the consensus side they are identical.

When the gate opens, the producer engages the VRF lottery, opcert checks,
KES Sum6 signing, mempool selection, and the sealed-artifact write path.
The atomic seal-and-promote step prints
`FORGE_PROMOTE_ATOMIC: slot=… block_no=… hash=… dir=…` and writes the
signed CBOR into `${TSUNAGI_HOME}/propagation_artifact/`.

### e. Forge / KES seal
KES Sum6 signing and opcert assembly are in-process. The result is a
self-contained directory under `propagation_artifact/` containing the
header CBOR, block CBOR, and a meta JSON. The producer never opens a
network socket itself; the propagation server is the only outbound
boundary.

### f. Propagation server (the mode boundary)
`src/net/propagation_server.zig` is auto-spawned as a detached thread
when forge is enabled. It listens on the loopback allowlist and accepts
a single relay connection at a time. After handshake it runs
`serveMuxLoop`, which:

- answers ChainSync FindIntersect from the chain-tip fragment + sealed tip,
- pushes a RollForward containing the sealed header (LIVE_PUSH path),
- responds to BlockFetch RequestRange with the 3-message StartBatch /
  Block / BatchDone batch, or with NoBlocks on miss.

**TSUNAGI_MODE gate** (PR #173). At three send sites:

| Site | What it transmits |
|---|---|
| `RF_PUSH` | Proactive RollForward to relay's AwaitReply (we have a new tip). |
| `RF_RESP` | RollForward response to relay's MsgRequestNext. |
| `BF_BLOCK` | The 3-message Block batch in answer to BlockFetch RequestRange. |

The server consults `isLiveMode()` (single env read of `TSUNAGI_MODE`) at
each of these sites:

- `live` → emit `PROPAGATION_SEND: site=… slot=… block=… bytes=…`
  and call `mux_bearer.sendSegment`. Bytes leave the process.
- `preview_safe` → emit
  `PROPAGATION_SUPPRESSED: site=… slot=… block=… reason=preview_safe`
  and skip the byte write.

Handshake, RollBackward, IntersectFound, IntersectNotFound, and the
NoBlocks miss path are NEVER suppressed — those messages must always
flow or the protocol session breaks.

## 4. TSUNAGI_MODE — single source of truth

| Mode | Forge runs? | Sealed artifact written? | Bytes leave the node? |
|---|---|---|---|
| `preview_safe` (default) | Yes | Yes | No (`PROPAGATION_SUPPRESSED`) |
| `live` | Yes | Yes | Yes (`PROPAGATION_SEND`) |

Both modes complete the consensus pipeline identically up to the
propagation boundary. Operators can inspect the output of a `preview_safe`
forge under `${TSUNAGI_HOME}/propagation_artifact/` before flipping the
mode.

The mode is set in `${TSUNAGI_HOME}/forge.env` (recommended) or as a
shell export. The file value wins on conflict because `loadForgeConfig`
calls `setenv(name, value, overwrite=1)` before any TSUNAGI_* env read.

The legacy variables — `TSUNAGI_PRODUCER_DRYRUN`,
`TSUNAGI_FORGE_PREVIEW_ONLY`, `TSUNAGI_FORGE_NO_BROADCAST`,
`TSUNAGI_FORGE_POLICY`, `TSUNAGI_FORGE_GATE_ENFORCE`, the entire
`TSUNAGI_BCAST_*` family — are no longer read on the runtime control
path. Setting them has no effect.

## 5. State directories

All paths are rooted at `${TSUNAGI_HOME}` (resolved per §2.3).

| Path | Purpose |
|---|---|
| `${TSUNAGI_HOME}/lock` | `flock` single-instance guard. |
| `${TSUNAGI_HOME}/clean` | Shutdown marker; absence on boot ⇒ unclean shutdown. |
| `${TSUNAGI_HOME}/logs/node.log` | Tee'd stdout+stderr, rotated 5 MiB × 5. |
| `${TSUNAGI_HOME}/chain_tip/fragment/` | Append-only ancestor chain (`{seq:08d}.{header,body,hash,prev_hash,meta}`). |
| `${TSUNAGI_HOME}/propagation_artifact/` | Latest sealed block (header CBOR, block CBOR, meta). |
| `${TSUNAGI_HOME}/forge.env` | Canonical config file, loaded with `setenv(overwrite=1)`. |
| `${TSUNAGI_HOME}/opcert_state.json` | Persisted opcert counter (atomic write). |
| `${TSUNAGI_HOME}/captures/` | N2N wire captures (when capture enabled). |
| `${TSUNAGI_HOME}/guardian/` | Guardian arm tokens / receipts (forge-enabled runs). |
| `${TSUNAGI_HOME}/producer_dryrun/` | Candidate + block artifacts (created in `preview_safe` mode for inspection). |
| `${TSUNAGI_HOME}/txsub/` | Tx submission relay state (when `TSUNAGI_TXSUB_ENABLE=1`). |

## 6. Threading model

- **Main thread** — `chainsync_mux_smoke.runWithOptions` →
  `follower.zig` event loop. Owns the upstream TCP socket, drives
  ChainSync/BlockFetch, and ticks the producer.
- **Log tee thread** — `ops/autonomy.zig:loggerThread` reads from the
  internal pipe, writes to the original stderr fd and to
  `logs/node.log`, performs lazy rotation every ~64 KiB.
- **Propagation server thread** — `propagation_server.spawnBackground`
  detaches `propagationThread`. Listens on loopback. One relay
  connection at a time. Consults `isLiveMode()` per send site.
- **Metrics HTTP thread (optional)** — started by
  `http_metrics.Server.start()` when `--debug` or `TSUNAGI_METRICS=1`.
  Plain HTTP, default `127.0.0.1:9080`.
- **KES heartbeat / forge ticks** — driven from the producer code path
  on the main thread; no dedicated KES thread.

Shutdown is ordered through SIGINT/SIGTERM handlers installed by the
follower. They set the follower's stop flag, which drains ChainSync and
returns through `main()`. The `defer autonomy.markClean(state_dir)` then
writes `clean`; the kernel releases the flock on process exit.
Background threads (propagation, logger, metrics) are detached and torn
down with the process — there is no explicit join.

## 7. Out of scope (current implementation)

The following are explicitly NOT implemented today:

- **Mainnet forge.** Forge gate refuses any network other than `preview`;
  the propagation server refuses any net other than `preview` at the
  entry point.
- **Multi-peer follower.** Exactly one upstream peer is opened per run.
  Multi-peer scaffolding exists in design notes but is not wired into
  the runtime path.
- **NtC local state queries (server side).** TSUNAGI does not expose a
  Node-to-Client server. The producer's protocol-state queries (e.g.
  current epoch nonce) fall back to Koios over HTTPS via curl.
- **Wallet / delegation operations.** No address derivation, no
  staking-cert builder, no key management beyond the operator-supplied
  KES/VRF/opcert files.
- **Explorer / public API gateway.** The metrics HTTP server is a
  Prometheus-style scrape endpoint, not a block explorer or query API.
- **Mainnet peer discovery.** `selectMainnetPeer` is a bounded probe
  over a fixed list, not a topology federation client.
- **Hot-reload of `forge.env`.** The file is read once at startup; later
  edits require a process restart.
- **In-process supervisor / restart loop.** A separate
  `tsunagi-supervisor` binary is the planned operator pattern; the node
  itself exits cleanly on fatal and relies on external supervision.
