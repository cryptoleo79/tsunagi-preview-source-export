# Slot Index Rollback Runbook — Phase B'''' (delivered-domain coherence)

This runbook covers the operator procedure for rolling a TSUNAGI node
back from a post-fix binary (delivered-domain `slot_index`) to a pre-fix
binary (peer-tip-domain `slot_index`). It also documents the same-window
deploy requirement, the `/status` semantic shift, and the
`legacy_no_cbor` acceptance clause.

This document assumes Phase B'''' Commits 1+2 have been deployed on a
single binary (`tsunagi-node` post-fix). The standalone utility
`tsunagi-slot-index-reset` ships in the same release.

## Same-window deploy requirement

Commits 1 and 2 land together in a single deploy window. They are not
independently deployable.

Reasoning:

- Commit 1 introduces the `SLOT_INDEX_SCHEMA` sentinel + boot-time
  `rebuildSlotIndexIfNeeded`. Without Commit 2, the rebuilt
  delivered-domain `slot_index` is correct but the operator-visible
  surfaces (`cursor.json`, `/status`, ROLL FWD log, CHAIN_TIP_HEADER)
  remain in peer-tip-domain — producing a hybrid where storage is
  delivered but observation is peer-tip. This is the worst of both
  worlds for operator trust.
- Commit 2 alone, without Commit 1, would shift the `putSlotIndex`
  writes to delivered-domain but leave pre-existing peer-tip-domain
  entries untouched, producing silent 404s on
  `/chain/header-by-slot/{slot}` for blocks indexed before the deploy.

Deploy Commit 1 + Commit 2 together. The deployed binary is internally
coherent and forward-compatible with the boot-time migration.

## `/status` semantic shift advisory

Pre-fix:

- `/status` `tip.slot` and `tip.block` reported peer-tip values (taken
  from the RollForward envelope; may describe a LATER block than the
  one TSUNAGI actually applied).

Post-fix:

- `/status` `tip.slot` and `tip.block` report delivered values (parsed
  from the header CBOR; describe the block TSUNAGI applied).
- New gauges `tsunagi_peer_tip_slot` and `tsunagi_peer_tip_block_no`
  preserve the pre-fix peer-tip values for peer-lag visibility.
- `/state` `state_schema_version` bumps from 1 to 2 to flag the shift.

Operators consuming `/status` programmatically should reconcile against
the new schema. The shift is typically 0-3 blocks (peer-tip may be
ahead of delivered by the duration of one RollForward burst).

## `legacy_no_cbor` acceptance clause

The boot-time `rebuildSlotIndexIfNeeded` walks the `headers` DBI and
re-derives the delivered slot for each entry by parsing `header_cbor`.
For `HeaderRec` entries written before commit `9de2732` (which
introduced the `header_cbor` archive), no `header_cbor` is present.

For those entries, the rebuild falls back to `rec.slot` (the slot
field stored at the time of write) and increments the
`legacy_no_cbor` counter. The aggregate log emitted at the end of the
rebuild reports:

```
SLOT_INDEX_REBUILD: total_indexed=N legacy_no_cbor=M corrupt_cbor=K
```

For envs that have been running TSUNAGI continuously since before
`9de2732`, `legacy_no_cbor` may be a large fraction of `total_indexed`.
This is accepted as the price of preserving the pre-cbor history; the
`rec.slot` fallback is correct for entries written when the pre-fix
binary already wrote peer-tip-domain `tip_slot` (the legacy slot field
was the same peer-tip value used as the slot_index key, so re-keying
to itself is a no-op on those entries).

For envs initialized post-`9de2732`, `legacy_no_cbor` should be 0 (or
trivially small for a brief boot transient). A `corrupt_cbor` count
greater than zero indicates a `header_cbor` entry that exists but
cannot be parsed for slot/block_no; treat any non-zero value as a
diagnostic signal worth investigating but not a deploy-blocker.

## Rollback procedure (post-fix -> pre-fix)

**FORBIDDEN: do NOT run `tsunagi-slot-index-reset` against an LMDB env
that is currently held open by a live post-fix tsunagi-node binary.**
The post-fix runtime caches its own DBI handles and writes through
them; an external `mdb_drop` would produce a torn read window and
likely corrupt the migration sentinel. Always stop the post-fix
binary first.

### Step 0 — Decision gate

Confirm rollback is warranted (operator-driven, not automatic). Tier-3
Round 3 Specialist D documented decision gates (G-A through G-D) — this
runbook covers the mechanical procedure once that decision has been
made.

### Step 1 — Stop the post-fix binary

```
sudo systemctl stop tsunagi-node
# OR
kill -TERM <pid>
```

Wait up to 30s for graceful shutdown. `SIGKILL` is acceptable if the
process does not exit within 30s; LMDB's write-ahead-log is crash-safe.
Confirm the process is gone:

```
pgrep -af tsunagi-node
```

Expected: no output.

### Step 2 — Run the reset utility against the stopped env

```
TSUNAGI_LMDB_DIR=/var/lib/tsunagi/lmdb \
TSUNAGI_LMDB_MAP_GB=256 \
  /opt/tsunagi/bin/tsunagi-slot-index-reset
```

(Alternatively, pass the path as `argv[1]`.)

Expected log:

```
RESET_SLOT_INDEX: ensure no live tsunagi-node holds this env; concurrent mutation is undefined behaviour.
RESET_SLOT_INDEX: target_dir='/var/lib/tsunagi/lmdb'
RESET_SLOT_INDEX: env opened
RESET_SLOT_INDEX: sentinel deleted
RESET_SLOT_INDEX: slot_index cleared (DBI retained)
RESET_SLOT_INDEX: commit OK — next binary boot will rebuild slot_index
```

If `sentinel deleted` is replaced by `sentinel not present`, the env
was already fresh (e.g. utility run twice or run against a never-migrated
env). Treat this as success.

### Step 3 — Swap binary back to pre-fix

```
sudo install /opt/tsunagi/bin/tsunagi-node-prefix /opt/tsunagi/bin/tsunagi-node
# OR your existing artifact-promotion mechanic
```

### Step 4 — Restart

```
sudo systemctl start tsunagi-node
```

Expected: pre-fix binary boots, treats `slot_index` as un-migrated (no
sentinel), writes peer-tip-domain entries on RollForward. Pre-fix binary
has no `rebuildSlotIndexIfNeeded` call, so the empty `slot_index` simply
fills lazily as new headers arrive.

### Step 5 — Verify

Within 5 minutes of restart:

- `tsunagi_header_height` advances (pre-fix is functional).
- `/chain/header-by-slot/{recent_slot}` returns 200 for slots indexed
  post-restart.
- For slots indexed pre-rollback under the post-fix binary, expect
  404 (the delivered-slot keys were dropped by Step 2; pre-fix writes
  peer-tip-slot keys). This is the cost of crossing the domain
  boundary; the operator runbook does not attempt to back-fill.

### Step 6 — If rollback fails

If Step 1 hung past 30s and `SIGKILL` was used: LMDB will recover from
its WAL on next start. No data loss.

If Step 2 returned an error: check the env path, map-size, and
permissions. Do NOT delete `data.mdb`, `lock.mdb`, `nonce_state.json`,
`KES`, or `chain_tip/`.

If Step 4 boots but the pre-fix binary refuses to write: confirm the
pre-fix binary at this path is the intended pre-fix version (the post-fix
binary will boot from the same path if the artifact wasn't swapped).

## Forward path (re-deploy post-fix)

If the operator decides to re-deploy the post-fix binary after a
rollback, the boot-time migration handles the transition automatically:

- `rebuildSlotIndexIfNeeded` sees no sentinel.
- Explicit `mdb_drop` empties any residual peer-tip-domain entries
  that the pre-fix binary wrote during its interim run.
- Walks `headers` DBI, re-derives delivered-domain slot keys.
- Writes sentinel.

No operator action is required between Step 4 and the re-deploy.

## Doctrine note

This procedure preserves the "safe refusal over unsafe liveness"
doctrine: during the rebuild window (typically seconds), the post-fix
binary may temporarily return 404 on slot lookups for blocks that
have not yet been re-keyed. This is correct conservative behaviour —
the consult cascade gates on `block_not_in_history` rather than
admitting a stale or wrong-domain answer. G14
(`parent_gap_slots <= 120`) is the dimensionally-independent
backstop and is unaffected by this migration.
