TSUNAGI Operator JSON Generator
=================================

Script: scripts/generate-operator-json.sh

Purpose:
  Generates an operator-facing operator.json telemetry file from
  TSUNAGI runtime state files. The operator page
  (web/operator/index.html) fetches this file every 10 seconds
  to display live operational telemetry.

  This is a companion to generate-status-json.sh. The status
  endpoint serves the public status dashboard; the operator
  endpoint serves structured data organized for node operators.

=== DATA SOURCES ===

The script reads three files from the TSUNAGI home directory:

1. cursor.json
   Path: $TSUNAGI_HOME/cursor.json
   Written by: the node on every chain tip update
   Fields used:
     - slot              → sync.slot
     - block_no          → sync.block
     - tip_hash_hex      → sync.tip_hash
     - roll_forward_count  → pipeline.blocks_processed
     - roll_backward_count → pipeline.rollbacks
     - updated_unix      → used to derive sync.tip_age_seconds

2. journal.ndjson
   Path: $TSUNAGI_HOME/journal.ndjson
   Written by: the node on every roll-forward/backward event
   Fields used (from last roll_forward event):
     - tx_count          → pipeline.tx_last_block
     - utxo_count        → ledger.utxo_estimate
     - utxo_consumed     → pipeline.utxo_consumed
     - utxo_produced     → pipeline.utxo_produced
     - utxo_delta        → pipeline.utxo_delta

3. coverage.json
   Path: $TSUNAGI_HOME/propagation_artifact/coverage.json
   Written by: the propagation artifact builder
   Fields used:
     - usable_contiguous_depth → storage.coverage_total
     - break_count             → storage.coverage_found

=== DERIVED FIELDS ===

- sync.tip_age_seconds:  now - updated_unix from cursor.json
- sync.status:           derived from tip age using KAGAMI thresholds
                         (>600s = critical, >120s = warn, else healthy)
- runtime.generated_at:  ISO 8601 timestamp at generation time
- runtime.uptime_seconds: now - TSUNAGI_BOOT_UNIX (if set)
- ledger.primary_mode:   from TSUNAGI_LEDGER_MODE env (default: lmdb_truth)
- ledger.shadow_enabled: from TSUNAGI_SHADOW_ENABLE env (default: true)

=== FIELDS SET TO NULL ===

These fields require runtime instrumentation and are not
persisted to files:

- storage.fallback_used  (per-block flag, not persisted)

=== OUTPUT STRUCTURE ===

{
  "node": "tsunagi-preview",
  "network": "preview",

  "sync": {
    "slot": number,
    "block": number,
    "tip_hash": string,
    "tip_age_seconds": number,
    "status": "healthy|warn|critical"
  },

  "ledger": {
    "primary_mode": string,
    "shadow_enabled": boolean,
    "utxo_estimate": number
  },

  "pipeline": {
    "blocks_processed": number,
    "rollbacks": number,
    "tx_last_block": number,
    "utxo_consumed": number,
    "utxo_produced": number,
    "utxo_delta": number
  },

  "storage": {
    "coverage_total": number,
    "coverage_found": number,
    "fallback_used": boolean
  },

  "runtime": {
    "uptime_seconds": number,
    "generated_at": ISO8601
  }
}

=== USAGE ===

1. Manual run:

   export TSUNAGI_HOME=~/tsunagi-home-preview
   ./scripts/generate-operator-json.sh operator.json

2. Copy output to web root:

   sudo cp operator.json /var/www/tsunagi/operator.json

3. Combined one-liner:

   TSUNAGI_HOME=~/tsunagi-home-preview \
     ./scripts/generate-operator-json.sh /var/www/tsunagi/operator.json

=== ENVIRONMENT VARIABLES ===

  TSUNAGI_HOME           Node state directory
                         Default: ~/tsunagi-home-preview

  TSUNAGI_NETWORK        Network name for the "network" field
                         Default: preview

  TSUNAGI_LEDGER_MODE    Primary ledger mode
                         Default: lmdb_truth

  TSUNAGI_SHADOW_ENABLE  Shadow verification flag (true/false)
                         Default: true

  TSUNAGI_BOOT_UNIX      Unix timestamp when the node was started
                         Default: 0 (uptime_seconds will be null)

=== AUTOMATION ===

Option A — Cron (every 10 seconds via wrapper):

  Create a wrapper script that runs 6 times per minute:

    #!/bin/bash
    for i in $(seq 0 5); do
      TSUNAGI_HOME=~/tsunagi-home-preview \
        /path/to/scripts/generate-operator-json.sh \
        /var/www/tsunagi/operator.json
      sleep 10
    done

  Add to crontab:

    * * * * * /path/to/operator-loop.sh >/dev/null 2>&1

Option B — systemd timer (every 10 seconds):

  /etc/systemd/system/tsunagi-operator.service:

    [Unit]
    Description=Generate TSUNAGI operator.json

    [Service]
    Type=oneshot
    Environment=TSUNAGI_HOME=/home/tsunagi/tsunagi-home-preview
    ExecStart=/path/to/scripts/generate-operator-json.sh /var/www/tsunagi/operator.json

  /etc/systemd/system/tsunagi-operator.timer:

    [Unit]
    Description=Refresh TSUNAGI operator.json every 10s

    [Timer]
    OnBootSec=10s
    OnUnitActiveSec=10s
    AccuracySec=1s

    [Install]
    WantedBy=timers.target

  Enable:

    sudo systemctl daemon-reload
    sudo systemctl enable --now tsunagi-operator.timer

=== INTEGRATION WITH MONITORING ===

The operator.json endpoint is designed for integration with
external monitoring systems:

1. Web dashboard:
   web/operator/index.html fetches /operator.json every 10s
   and renders a live telemetry panel.

2. Alerting:
   Monitor sync.status for "warn" or "critical" values.
   Alert on sync.tip_age_seconds exceeding thresholds.

3. Metrics collection:
   Parse operator.json fields into Prometheus, Grafana,
   or custom dashboards. All numeric fields are suitable
   for time-series collection.

4. Health checks:
   Use sync.status as a simple health probe endpoint.
   "healthy" = OK, "warn" = degraded, "critical" = down.

=== ADDITIONAL JSON GENERATORS ===

1. generate-blocks-json.sh [output-path]
   Generates blocks.json with the most recent 50 blocks from
   journal.ndjson, enriched with decode metadata from
   tx_decode.ndjson. Each entry includes slot, block number,
   block hash, tx count, UTxO consumed/produced/delta,
   truncated flag, and ISO 8601 timestamp. Output is newest-first.

   Data sources:
     journal.ndjson   — block-level delta data
     tx_decode.ndjson — truncated flag per block

   Output structure:
   {
     "network": "preview",
     "generated_at": "2026-...",
     "recent": [
       {
         "slot": 106736812,
         "block": 4103443,
         "block_hash": "abc123...",
         "tx_count": 3,
         "utxo_consumed": 5,
         "utxo_produced": 8,
         "utxo_delta": 3,
         "truncated": false,
         "timestamp": "2026-01-15T12:34:56Z"
       }
     ]
   }

2. generate-block-detail-json.sh <block_no> [output-path]
   Generates a single block detail JSON file for a specific
   block number. Searches journal.ndjson for the matching
   roll_forward entry and enriches with per-tx decode
   summaries from tx_decode.ndjson.

   Data sources:
     journal.ndjson   — block-level delta data
     tx_decode.ndjson — per-tx decode summaries

   Output structure:
   {
     "network": "preview",
     "block": 4103443,
     "slot": 106736812,
     "block_hash": "abc123...",
     "tip_hash": "def456...",
     "tx_count": 3,
     "utxo_consumed": 5,
     "utxo_produced": 8,
     "utxo_delta": 3,
     "utxo_set_size": 45000,
     "truncated": false,
     "transactions": [
       { "index": 0, "inputs": 2, "outputs": 3,
         "fee": 170000, "metadata": false },
       { "index": 1, "inputs": 1, "outputs": 2,
         "fee": 185000, "metadata": true }
     ],
     "timestamp": "2026-01-15T12:34:56Z",
     "source": "journal.ndjson + tx_decode.ndjson"
   }

3. generate-block-detail-dir.sh [output-dir]
   Batch generates static per-block detail JSON files for the
   most recent 50 blocks. Each file is named <block_no>.json.
   Calls generate-block-detail-json.sh for each block.

   Usage:
     ./scripts/generate-block-detail-dir.sh block-detail/
   Result:
     block-detail/4103443.json
     block-detail/4103442.json
     ...

4. generate-delta-json.sh [output-path]
   Generates delta.json with the most recent 50 UTxO deltas.
   Used by the explorer page delta graph canvas.

5. generate-decode-json.sh [output-path]
   Generates decode.json from tx_decode.ndjson with per-block,
   per-transaction decode summaries. Data is produced by the
   runtime pipeline (tx_decoder.zig → journal.appendTxDecode).
   Each block entry includes individual transaction summaries
   with inputs, outputs, fee, and metadata flag.

   Data source: $TSUNAGI_HOME/tx_decode.ndjson
   Written by: the node on every roll-forward event

   NDJSON line format:
   {"type":"tx_decode","slot":N,"block_no":N,"block_hash":"...",
    "tx_count":N,"truncated":false,"txs":[
      {"idx":0,"in":2,"out":3,"fee":170000,"meta":false}, ...
    ]}

   Output structure:
   {
     "network": "preview",
     "generated_at": "2026-...",
     "blocks": [
       {
         "slot": 106736812,
         "block": 4103443,
         "block_hash": "abc123...",
         "tx_count": 3,
         "truncated": false,
         "transactions": [
           { "index": 0, "inputs": 2, "outputs": 3,
             "fee": 170000, "metadata": false },
           { "index": 1, "inputs": 1, "outputs": 2,
             "fee": 185000, "metadata": true }
         ]
       }
     ]
   }

6. prune-decode.sh [max-lines]
   Retention tool for tx_decode.ndjson. Keeps the most recent
   N lines and discards the rest. Uses safe temp-file-then-mv
   pattern to prevent corruption during pruning.

   Default retention: 5000 lines (~5000 blocks of decode data)

   Usage:
     TSUNAGI_HOME=~/tsunagi-home-preview \
       ./scripts/prune-decode.sh 5000

   Automation (cron, daily):
     0 3 * * * TSUNAGI_HOME=~/tsunagi-home-preview \
       /path/to/scripts/prune-decode.sh 5000 >/dev/null 2>&1

7. generate-mempool-json.sh [output-path]
   Generates mempool.json from mempool.ndjson with the most recent
   50 decoded mempool transaction summaries, newest-first.

   Data source: $TSUNAGI_HOME/mempool.ndjson
   Written by: the node on every accepted tx submission
   (http_metrics.zig → mempool_decoder.decodeMempoolTx →
    journal.appendMempoolTx)

   NDJSON line format:
   {"type":"mempool_tx","txid":"abc...","in":2,"out":3,
    "fee":170000,"meta":false,"size":432,"ts":1710000000}

   Output structure:
   {
     "network": "preview",
     "generated_at": "2026-...",
     "tx_count": 42,
     "recent": [
       {
         "txid": "abc123...",
         "inputs": 2,
         "outputs": 3,
         "fee": 170000,
         "metadata": false,
         "size": 432,
         "timestamp": "2026-03-14T12:00:00Z"
       }
     ]
   }

   Usage:
     TSUNAGI_HOME=~/tsunagi-home-preview \
       ./scripts/generate-mempool-json.sh /var/www/tsunagi/mempool.json

8. generate-confirmation-json.sh [output-path]
   Generates confirmation.json from confirmation.ndjson and
   mempool.ndjson with recent confirmed and pending transactions.

   Data sources:
     confirmation.ndjson — per-tx confirmation events
       Written by: the node on block decode when a pending txid
       is found in the block (chainsync_mux_smoke.zig →
        confirmation_tracker.markConfirmed → journal.appendConfirmation)
     mempool.ndjson — per-tx mempool submission events
       Used to derive pending list (excluding confirmed txids)

   NDJSON line format (confirmation.ndjson):
   {"type":"confirmed_tx","txid":"abc...","received":N,
    "confirmed":N,"seconds":N,"block":N,"slot":N,"fee":N}

   Output structure:
   {
     "network": "preview",
     "generated_at": "2026-...",
     "pending_count": 3,
     "confirmed_count": 12,
     "recent_confirmed": [
       {
         "txid": "abc123...",
         "block": 4107001,
         "slot": 106900000,
         "confirmation_seconds": 30,
         "fee": 170000,
         "timestamp": "2026-03-14T13:59:50Z"
       }
     ],
     "recent_pending": [
       {
         "txid": "def456...",
         "age_seconds": 18,
         "fee": 180000,
         "inputs": 1,
         "outputs": 2
       }
     ]
   }

   Usage:
     TSUNAGI_HOME=~/tsunagi-home-preview \
       ./scripts/generate-confirmation-json.sh /var/www/tsunagi/confirmation.json

9. generate-slot-observatory-json.sh [output-path]
   Generates slot-observatory.json from slot_observatory.ndjson with
   recent slot-level observations (block arrivals and inter-block gaps).

   Data source: $TSUNAGI_HOME/slot_observatory.ndjson
   Written by: the node on every roll-forward event
   (chainsync_mux_smoke.zig → slot_observatory.appendObservedBlock
    → journal.appendSlotObservation)

   Only observed_block entries are emitted by the current runtime.
   The local_candidate kind is deferred — the enum exists for
   forward compatibility but is not populated.

   NDJSON line format:
   {"type":"slot_observation","slot":N,"block":N_or_null,
    "observed_unix":N,"kind":"observed_block",
    "gap_from_prev_block":N_or_null}

   gap_from_prev_block: number of empty slots between this block
   and the previous observed block (current_slot - last_block_slot - 1).
   0 means consecutive blocks. null for the first observed block.

   Output structure:
   {
     "network": "preview",
     "generated_at": "2026-...",
     "observation_count": 1234,
     "latest_slot": 106900000,
     "latest_block": 4107001,
     "latest_gap": 2,
     "avg_gap": 1.5,
     "recent_observations": [
       {
         "slot": 106900000,
         "block": 4107001,
         "kind": "observed_block",
         "gap_from_prev_block": 2,
         "observed_at": "2026-03-14T14:00:00Z"
       }
     ]
   }

   Usage:
     TSUNAGI_HOME=~/tsunagi-home-preview \
       ./scripts/generate-slot-observatory-json.sh /var/www/tsunagi/slot-observatory.json

10. generate-network-json.sh [output-path]
    Generates network.json from peer_observatory.ndjson with recent
    peer/network events (connect, disconnect, block received).

    Data source: $TSUNAGI_HOME/peer_observatory.ndjson
    Written by: the node on peer connect/disconnect (follower.zig
    callbacks → chainsync_mux_smoke.zig handlers) and on every
    roll-forward event (block_received with neutral "chainsync" label)

    NDJSON line format:
    {"type":"peer_event","peer":"3.135.125.51:3001","event":"peer_connect",
     "slot":null,"block":null,"latency_ms":null,"reason":null,"ts":N}
    {"type":"peer_event","peer":"3.135.125.51:3001","event":"peer_disconnect",
     "slot":null,"block":null,"latency_ms":null,"reason":"stream_error","ts":N}
    {"type":"peer_event","peer":"chainsync","event":"block_received",
     "slot":N,"block":N,"latency_ms":null,"reason":null,"ts":N}

    Output structure:
    {
      "network": "preview",
      "generated_at": "2026-...",
      "event_count": 42,
      "connect_count": 5,
      "disconnect_count": 3,
      "block_event_count": 34,
      "recent_events": [
        {
          "peer": "3.135.125.51:3001",
          "event": "peer_connect",
          "slot": null,
          "block": null,
          "latency_ms": null,
          "reason": null,
          "timestamp": "2026-03-14T18:00:00Z"
        }
      ]
    }

    Deferred items (not emitted by current runtime):
    - tx_seen: TxSubmission protocol is pull-based; TSUNAGI does
      not observe txs arriving from peers
    - latency_ms: blockfetch.zig has no request-to-completion
      timing; always null in current output
    - Disconnect reasons beyond stream_error and keepalive_timeout:
      density_violation, authority_fail, cbor_error are real
      disconnect paths but not yet wired to the peer observatory

    Usage:
      TSUNAGI_HOME=~/tsunagi-home-preview \
        ./scripts/generate-network-json.sh /var/www/tsunagi/network.json

11. generate-health-json.sh

   Generates health.json -- composite health score derived from
   existing JSON endpoints. No direct journal or runtime access.

   Data sources (pre-generated JSON files):
   - operator.json   → pipeline.blocks_processed, pipeline.rollbacks
   - network.json    → connect_count, disconnect_count
   - slot-observatory.json → avg_gap (converted to avg_gap_x10)
   - confirmation.json → pending_count, recent_confirmed[].confirmation_seconds

   Scoring model (mirrors src/net/health/health_engine.zig):

   Component scores (0-100):
   - peer_score:    disconnect_count / max(connect_count,1) ratio
                    100 if no disconnects, degrades linearly, 30 at 100%+ rate
                    neutral 80 if no connect/disconnect data
   - slot_score:    avg_gap_x10 (avg_gap * 10, integer)
                    100 if gap <= 3.0s, linear to 70 at 10s, to 40 at 30s
                    neutral 80 if no slot data
   - block_score:   rollback rate per 10k blocks
                    100 if no rollbacks, degrades linearly, 40 at rate >= 100
                    neutral 80 if no blocks processed
   - confirmation_score: avg confirmation seconds from recent_confirmed
                    100 if <= 30s, linear to 60 at 120s, to 30 at 300s
                    neutral 80 if no confirmation data
   - mempool_score: pending_count from confirmation.json
                    100 at 0 pending, 95 at <=10, degrades to 40 at 200+

   Overall score:
     (peer * 25 + slot * 20 + block * 25 + confirm * 15 + mempool * 15) / 100

   State:
     >= 90 excellent, >= 75 healthy, >= 60 degraded, < 60 critical

   Output structure:
   {
     "network": "preview",
     "generated_at": "2026-...",
     "score": 92,
     "state": "excellent",
     "peer_score": 95,
     "slot_score": 88,
     "block_score": 100,
     "confirmation_score": 90,
     "mempool_score": 96
   }

   Limitations:
   - Health score is observability-derived, not consensus-derived
   - Sparse data early after startup yields neutral/default scoring
   - No latency timing for block fetch yet
   - No peer tx propagation visibility
   - Score is heuristic operator guidance, not protocol truth
   - Shell scoring uses integer arithmetic only, matching Zig reference
   - avg_gap float-to-integer conversion uses awk truncation

   Environment:
     TSUNAGI_WEB     -- web root (default: /var/www/tsunagi)
     TSUNAGI_NETWORK -- network name (default: preview)

   Usage:
     TSUNAGI_WEB=/var/www/tsunagi \
       ./scripts/generate-health-json.sh /var/www/tsunagi/health.json

12. generate-producer-dryrun-json.sh [output-path]
    Generates producer-dryrun.json from the runtime dry-run engine's
    bounded overwrite file.

    Data source: $TSUNAGI_HOME/producer-dryrun-last.json
    Written by: the node on every shadow-evaluated slot when
    TSUNAGI_PRODUCER_DRYRUN_ENABLE=1 and
    TSUNAGI_PRODUCER_DRYRUN_REPORT_DIR is set.

    The source file is a single JSON line, overwritten per slot.
    No append-only growth. No binary invocation by the generator.

    Honesty note: summary fields (candidate_ready, candidate_invalid,
    candidate_failed, not_leader, not_configured) are derived from
    the single last event only. They are 0 or 1, not historical
    counts. The generator does not fabricate history.

    If the source file is missing or empty, the generator emits
    an "enabled": false stub with all fields set to null.

    Output structure:
    {
      "network": "preview",
      "generated_at": "2026-...",
      "enabled": true,
      "last": {
        "slot": 106903999,
        "epoch": 1237,
        "slot_in_epoch": 32199,
        "block_no": 4108901,
        "state": "NOT_LEADER",
        "leadership": false,
        "candidate_built": false,
        "candidate_valid": false,
        "validation_state": null,
        "header_hash": "0000...",
        "body_hash": "0000...",
        "timestamp_unix": 1710002001
      },
      "summary": {
        "seen_last": true,
        "candidate_ready": 0,
        "candidate_invalid": 0,
        "candidate_failed": 0,
        "not_leader": 1,
        "not_configured": 0
      }
    }

    Consumers:
    - Operator (web/operator/index.html): detail panel with state
      pill, slot, epoch, leadership, candidate valid, hashes, age
    - Explorer (web/explorer/index.html): compact bar with state
      pill, slot, valid/invalid, truncated header hash

    Environment:
      TSUNAGI_HOME    -- node state directory (default: ~/tsunagi-home-preview)
      TSUNAGI_NETWORK -- network name (default: preview)

    Usage:
      TSUNAGI_HOME=~/tsunagi-home-preview \
        ./scripts/generate-producer-dryrun-json.sh /var/www/tsunagi/producer-dryrun.json

=== WEB PAGE DATA FLOW ===

  Homepage (index.html):
    Fetches /status.json → telemetry strip (slot, block, age,
    status, delta)

  Explorer (explorer/index.html):
    Fetches /status.json  → hero panel, ledger cards, decode timeline
    Fetches /delta.json   → UTxO delta bar chart
    Fetches /blocks.json  → latest block detail card, recent blocks table
    Fetches /decode.json  → latest transaction activity card
    Fetches /mempool.json → live transaction flow panel (5 recent txs)
    Fetches /confirmation.json → recent confirmations panel (5 recent)
    Fetches /slot-observatory.json → recent slot rhythm panel (6 recent)
    Fetches /network.json → network activity panel (6 recent events)
    Fetches /health.json  → chain health bar (score, state, components)
    Fetches /producer-dryrun.json → dry-run bar (state, slot, valid)

  Operator (operator/index.html):
    Fetches /operator.json → node header, sync summary card, blocks card
    Fetches /network.json  → network summary card, recent network table
    Fetches /slot-observatory.json → slot rhythm summary card, slot table
    Fetches /mempool.json  → mempool summary card
    Fetches /confirmation.json → confirmations summary card, confirm table
    Fetches /blocks.json   → recent blocks table
    Fetches /health.json   → node health panel (score, state, components)
    Fetches /producer-dryrun.json → dry-run detail panel (state, slot, valid)

  Decode (decode/index.html):
    Fetches /status.json → decoder overview, pipeline, detail cards
    Fetches /blocks.json → recent blocks table + inspect drilldown
    Fetches /block-detail/<block_no>.json → per-tx drilldown on inspect
    Fetches /decode.json → per-tx decode cards (real runtime data)

  Labs (labs/):
    cbor-playground.html → standalone CBOR hex decoder (JS-only)
    mempool.html → fetches /mempool.json every 10s, displays
      decoded tx summaries (txid, inputs, outputs, fee, metadata,
      size, age) in a live-updating table
    confirmation.html → fetches /confirmation.json every 10s,
      displays pending and confirmed txs with confirmation time
    slots.html → fetches /slot-observatory.json every 10s,
      displays slot-level observations with inter-block gaps
    network.html → fetches /network.json every 10s,
      displays peer connect/disconnect and block arrival events

=== DEPENDENCIES ===

Required: bash, sed, grep, date
Optional: jq (used automatically if present for more robust parsing)

The script checks for jq at startup and falls back to sed-based
extraction if jq is not available. Both paths produce identical output.
