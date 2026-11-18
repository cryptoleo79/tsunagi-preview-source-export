TSUNAGI Status JSON Generator
==============================

Script: scripts/generate-status-json.sh

Purpose:
  Generates a website-consumable status.json file from TSUNAGI
  runtime state files. The status page (web/status/index.html)
  fetches this file every 10 seconds to display live telemetry.

=== DATA SOURCES ===

The script reads three files from the TSUNAGI home directory:

1. cursor.json
   Path: $TSUNAGI_HOME/cursor.json
   Written by: the node on every chain tip update
   Fields used:
     - slot              (chain tip slot number)
     - block_no          (chain tip block number)
     - tip_hash_hex      (64 hex chars, truncated to 16 for display)
     - roll_forward_count
     - roll_backward_count
     - updated_unix      (unix timestamp of last update)

2. journal.ndjson
   Path: $TSUNAGI_HOME/journal.ndjson
   Written by: the node on every roll-forward/backward event
   Fields used (from last roll_forward event):
     - tx_count          (transactions in the latest block)
     - utxo_count        (UTxO set size after block application)

3. coverage.json
   Path: $TSUNAGI_HOME/propagation_artifact/coverage.json
   Written by: the propagation artifact builder
   Fields used:
     - usable_contiguous_depth  (mapped to coverage_total)

=== DERIVED FIELDS ===

- tip_age_seconds:  now - updated_unix from cursor.json
- status:           derived from tip age using KAGAMI thresholds
                    (>600s = critical, >120s = warn, else healthy)
- updated_at:       ISO 8601 conversion of updated_unix
- network:          from TSUNAGI_NETWORK env (default: preview)
- primary_mode:     from TSUNAGI_LEDGER_MODE env (default: lmdb_truth)
- shadow_enabled:   from TSUNAGI_SHADOW_ENABLE env (default: true)

=== FIELDS SET TO NULL ===

These fields require runtime instrumentation and are not
persisted to files:

- tps               (use `tsunagi-node kagami stream` for real-time)
- utxo_consumed     (per-block delta, not persisted)
- utxo_produced     (per-block delta, not persisted)
- utxo_delta        (per-block delta, not persisted)
- coverage_found    (LMDB preflight result, not persisted)
- fallback_used     (per-block flag, not persisted)

=== USAGE ===

1. Manual run:

   export TSUNAGI_HOME=~/tsunagi-home-preview
   ./scripts/generate-status-json.sh status.json

2. Copy output to web root:

   sudo cp status.json /var/www/tsunagi/status.json

3. Combined one-liner:

   TSUNAGI_HOME=~/tsunagi-home-preview \
     ./scripts/generate-status-json.sh /var/www/tsunagi/status.json

=== ENVIRONMENT VARIABLES ===

  TSUNAGI_HOME           Node state directory
                         Default: ~/tsunagi-home-preview

  TSUNAGI_NETWORK        Network name for the "network" field
                         Default: preview

  TSUNAGI_LEDGER_MODE    Primary ledger mode
                         Default: lmdb_truth

  TSUNAGI_SHADOW_ENABLE  Shadow verification flag (true/false)
                         Default: true

=== AUTOMATION ===

Option A — Cron (every 10 seconds via wrapper):

  Create a wrapper script that runs 6 times per minute:

    #!/bin/bash
    for i in $(seq 0 5); do
      TSUNAGI_HOME=~/tsunagi-home-preview \
        /path/to/scripts/generate-status-json.sh \
        /var/www/tsunagi/status.json
      sleep 10
    done

  Add to crontab:

    * * * * * /path/to/status-loop.sh >/dev/null 2>&1

Option B — systemd timer (every 10 seconds):

  /etc/systemd/system/tsunagi-status.service:

    [Unit]
    Description=Generate TSUNAGI status.json

    [Service]
    Type=oneshot
    Environment=TSUNAGI_HOME=/home/tsunagi/tsunagi-home-preview
    ExecStart=/path/to/scripts/generate-status-json.sh /var/www/tsunagi/status.json

  /etc/systemd/system/tsunagi-status.timer:

    [Unit]
    Description=Refresh TSUNAGI status.json every 10s

    [Timer]
    OnBootSec=10s
    OnUnitActiveSec=10s
    AccuracySec=1s

    [Install]
    WantedBy=timers.target

  Enable:

    sudo systemctl daemon-reload
    sudo systemctl enable --now tsunagi-status.timer

=== DEPENDENCIES ===

Required: bash, sed, grep, date
Optional: jq (used automatically if present for more robust parsing)

The script checks for jq at startup and falls back to sed-based
extraction if jq is not available. Both paths produce identical output.

=== OUTPUT FORMAT ===

See web/status/README-deploy.txt for the expected JSON shape.
