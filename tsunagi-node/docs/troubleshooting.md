# TSUNAGI Troubleshooting

Operator-facing failure modes. Each entry: Symptom → Meaning → Confirm → Fix.

All log lines are emitted via `std.debug.print` to stderr. Tail with:

```
journalctl --user -u tsunagi-node -f      # systemd
tail -F ${TSUNAGI_HOME}/logs/tsunagi.log  # file
```

Set `LOGS=${TSUNAGI_HOME}/logs/tsunagi.log` (or your own path) for the grep
commands below.

---

## 1. Lock conflict — another process holds TSUNAGI_HOME

**Symptom**

```
ANOTHER_INSTANCE_HOLDS_LOCK: path=<TSUNAGI_HOME>/lock — refusing to start
```

**What it means**

A previous `tsunagi-node` is still running (or crashed without releasing the
flock). The startup guard refuses to share state.

Source: `src/ops/autonomy.zig:67`.

**Confirm**

```
pgrep -af tsunagi-node
ls -l ${TSUNAGI_HOME}/lock
fuser ${TSUNAGI_HOME}/lock
```

**Fix**

Stop the other process, or run with a separate home:

```
pkill -TERM tsunagi-node
# or
TSUNAGI_HOME=/tmp/tsunagi-alt tsunagi-node ...
```

If no process holds it but the lock is stale, remove `${TSUNAGI_HOME}/lock`
manually after confirming with `fuser` that nothing has it open.

---

## 2. TSUNAGI_HOME unresolved

**Symptom**

```
ERROR: cannot resolve TSUNAGI_HOME (set TSUNAGI_HOME or HOME)
```

**What it means**

Neither `TSUNAGI_HOME` nor `HOME` is set in the environment. The node refuses
to write state to an arbitrary directory.

Source: `src/main.zig:405`.

**Confirm**

```
env | grep -E '^(TSUNAGI_HOME|HOME)='
```

**Fix**

```
export TSUNAGI_HOME=/var/lib/tsunagi
# or just
export HOME=/home/tsunagi
```

For systemd, set `Environment=TSUNAGI_HOME=...` in the unit.

---

## 3. Invalid TSUNAGI_MODE

**Symptom**

```
FATAL: TSUNAGI_MODE='<value>' — supported values: preview_safe | live
```

**What it means**

The mode selector accepts only two literals. Anything else (including empty,
`production`, `prod`, `mainnet`) aborts startup.

**Confirm**

```
grep -E "^TSUNAGI_MODE=" ${TSUNAGI_HOME}/forge.env
env | grep ^TSUNAGI_MODE=
```

**Fix**

Edit `${TSUNAGI_HOME}/forge.env`:

```
TSUNAGI_MODE=live           # or preview_safe
```

No quotes, no trailing whitespace.

---

## 4. Forge enabled but guardian confirm missing

**Symptom**

```
FATAL: TSUNAGI_FORGE_ENABLE=1 but missing required companion flags.
```

**What it means**

`TSUNAGI_FORGE_ENABLE=1` requires the full companion set, including
`TSUNAGI_FORGE_REQUIRE_GUARDIAN_CONFIRM=1`. Forge gate refuses to half-arm.

Source: `src/main.zig:439`; flag check `src/producer/producer.zig:758-759`.

**Confirm**

```
grep -E '^TSUNAGI_FORGE_(ENABLE|PREVIEW_ONLY|NO_BROADCAST|REQUIRE_GUARDIAN_CONFIRM)=' \
  ${TSUNAGI_HOME}/forge.env
```

All four must equal `1`.

**Fix** — append to `${TSUNAGI_HOME}/forge.env`:

```
TSUNAGI_FORGE_ENABLE=1
TSUNAGI_FORGE_PREVIEW_ONLY=1
TSUNAGI_FORGE_NO_BROADCAST=1
TSUNAGI_FORGE_REQUIRE_GUARDIAN_CONFIRM=1
```

---

## 5. Forge enabled on non-preview network

**Symptom**

```
FATAL: TSUNAGI_FORGE_ENABLE=1 is only allowed on --net preview
```

Source: `src/main.zig:444`.

**What it means**

Forge is hard-locked to preview. Any other `--net` argument aborts when forge
is armed.

**Confirm**

```
ps -ef | grep tsunagi-node | grep -- --net
```

**Fix** — launch with `--net preview`, or disable forge:

```
tsunagi-node --net preview ...
# or
unset TSUNAGI_FORGE_ENABLE   # and remove from forge.env
```

---

## 6. TSUNAGI_TXSUB_BROADCAST conflicts with forge

**Symptom**

```
FATAL: TSUNAGI_FORGE_ENABLE=1 but TSUNAGI_TXSUB_BROADCAST is set. REFUSE.
```

Source: `src/main.zig:451` (and `:477` for the parallel BCAST refuse at
`src/main.zig:464,469,473,477`).

**What it means**

A forging node must not also act as a tx-broadcast egress. The combination is
explicitly refused to prevent unintended replay.

**Confirm**

```
env | grep -E '^TSUNAGI_(FORGE_ENABLE|TXSUB_BROADCAST|BCAST_ENABLE)='
grep -E '^(TSUNAGI_TXSUB_BROADCAST|TSUNAGI_BCAST_ENABLE)=' ${TSUNAGI_HOME}/forge.env
```

**Fix** — pick one role. Remove `TSUNAGI_TXSUB_BROADCAST` from both shell and
`forge.env`, then restart.

---

## 7. forge.env not found

**Symptom**

```
CONFIG_NOT_FOUND: path=<TSUNAGI_HOME>/forge.env
```

Source: `src/main.zig:238`.

**What it means**

The config loader (`loadForgeConfig`) could not open the file. Without it, no
forge env vars are set.

**Confirm**

```
ls -l ${TSUNAGI_HOME}/forge.env
```

**Fix**

```
mkdir -p ${TSUNAGI_HOME}
cp docs/forge.env.example ${TSUNAGI_HOME}/forge.env
chmod 600 ${TSUNAGI_HOME}/forge.env
```

Edit values to match this node.

---

## 8. MODE shows `preview_safe` but operator expected `live`

**Symptom**

Logs print `MODE: preview_safe` after `CONFIG_LOADED`, even though the
operator "set live in the shell". Most common operator confusion.

**What it means**

`forge.env` is loaded with `setenv(overwrite=1)` (`src/main.zig:227,275-276`),
so the **file value wins over any shell export**. If `forge.env` lacks the
line, the previously-shell-set value is *also* lost on subsequent reloads.

**Confirm**

```
grep -E 'CONFIG_LOADED|MODE:' $LOGS | tail -10
grep -E '^TSUNAGI_MODE=' ${TSUNAGI_HOME}/forge.env
```

`CONFIG_LOADED: path=... keys=N` shows how many lines were ingested
(`src/main.zig:279`). If `keys` looks too low, the file is short.

**Fix**

Put the desired mode **in the file** — not the shell:

```
# ${TSUNAGI_HOME}/forge.env
TSUNAGI_MODE=live
```

Restart and verify the next `MODE:` log line.

---

## 9. No `leader_eligible=true` ever — operator panics too early

**Symptom**

Hours pass; no log line shows `leader_eligible=true`. Operator suspects forge
is broken.

**What it means**

Leader rate is a function of stake. With σ=0.000744 and active-slot
coefficient f=0.05, expected leader slots ≈ 1 every `1/(σ·f) ≈ 26 800` slots
≈ 7.5 hours. Variance is high; gaps of 24 h are normal.

The lottery decision log line is `FORGE_DECISION_TRUTH`
(`src/producer/producer.zig:1786`).

**Confirm the lottery is running**

```
grep FORGE_DECISION_TRUTH $LOGS | head -5
grep FORGE_DECISION_TRUTH $LOGS | tail -5
```

Each line shows `u_x1e12=... thresh_x1e12=...`. Both should be non-zero and
`u_x1e12` should vary slot-to-slot (it is the VRF output mapped to [0,1]).
If `thresh_x1e12=0`, σ is zero — fix stake configuration. If `u_x1e12=0` on
every line, VRF output is broken.

**Fix**

If thresholds and u look sane, **wait**. Compute expected gap:

```
python3 -c "s=0.000744; f=0.05; print('expected slots between leaders:', 1/(s*f))"
```

---

## 10. No `PROPAGATION_SEND` in live mode

**Symptom**

`MODE: live` is logged, but you never see `PROPAGATION_SEND`. Or you see
`PROPAGATION_SUPPRESSED` while mode is `live`.

**What it means**

The mode flag did not reach `propagation_server`. In `live` mode it must send;
suppression is only valid in `preview_safe`.

**Confirm**

```
grep -E 'MODE:|PROPAGATION_SEND|PROPAGATION_SUPPRESSED' $LOGS | tail -20
```

**Fix**

If you see `PROPAGATION_SUPPRESSED` while `MODE:` reads `live`, that is a
propagation_server bug — file an issue and attach the matched grep output.
As a workaround, restart and verify mode propagation on the next forge.

---

## 11. PROPAGATION_AUTOSTART exits with code=3 on cold start

**Symptom**

```
PROPAGATION_AUTOSTART: spawned on port 30000 artifact_dir=...
PROPAGATION_AUTOSTART: exited code=3
```

Source: `src/net/propagation_server.zig:70,84`.

**What it means**

Propagation server crashed because there is no sealed artifact yet. This is
expected on first boot — there is nothing to serve. The thread self-heals on
the first successful forge (sealed block.cbor + fragment appear).

**Confirm**

```
grep PROPAGATION_AUTOSTART $LOGS | tail -10
ls -l ${TSUNAGI_HOME}/chain_tip/
ls -l ${TSUNAGI_HOME}/chain_tip/fragment/
```

**Fix**

Non-blocking. Wait for the first forge. If you still see `code=3` after a
sealed forge, attach the artifact dir listing to an issue.

---

## 12. TSUNAGI_LMDB unset or set to "0"/"1"

**Symptom**

Node opens (or creates) a directory literally named `0` or `1` under cwd, or
LMDB queries return empty. `kagami` prints
`(not available — set TSUNAGI_LMDB or use --lmdb)`
(`src/cli/kagami_cmd.zig:166`).

**What it means**

`TSUNAGI_LMDB` is treated as a path, not a boolean. Setting it to `0` or `1`
makes the node treat those characters as a directory name.

**Confirm**

```
env | grep ^TSUNAGI_LMDB=
ls -ld "$TSUNAGI_LMDB" 2>/dev/null
```

**Fix**

```
export TSUNAGI_LMDB=${TSUNAGI_HOME}/lmdb
mkdir -p ${TSUNAGI_LMDB}
```

Add the line to `forge.env` if you want it persistent across restarts.

---

## 13. Fragment not growing — `fragment_len=0`

**Symptom**

`/status/full` shows `fragment_len=0` for many minutes. ChainSync is not
appending headers.

**What it means**

The follower writes `PARENT_SOURCE_UPDATE` on every accepted header
(see `src/node_state.zig:50,64,153,180` documenting the writer contract). If
that log line is absent, the upstream peer connection is broken or the
handshake never completed.

**Confirm**

```
grep PARENT_SOURCE_UPDATE $LOGS | tail -5
grep -E 'HANDSHAKE|peer.*closed|stream_error' $LOGS | tail -20
ls -1 ${TSUNAGI_HOME}/chain_tip/fragment/ | wc -l
```

`HANDSHAKE: recv returned null (peer closed)` (`src/net/chainsync/follower.zig:844`)
indicates upstream dropped before version negotiation.

**Fix**

Verify reachability of the configured peer:

```
nc -zv <peer-host> <peer-port>
```

If unreachable, change `--peer`. If reachable but handshake fails, check
`network_magic` for the network you intended (preview = 2).

---

## 14. IPv6-only DNS for upstream peer

**Symptom**

Connect to `preview-node.world.dev.cardano.org` times out. No
`HANDSHAKE: network_magic=...` line appears.

**What it means**

On some hosts the public preview relay resolves to AAAA only; the node's
`connectWithTimeout` (`src/net/chainsync/follower.zig:553`) and IPv4 selector
`selectReachableIpv4` (`:612`) both filter to IPv4. Result: no candidate
address.

**Confirm**

```
getent ahosts preview-node.world.dev.cardano.org
dig +short A preview-node.world.dev.cardano.org
dig +short AAAA preview-node.world.dev.cardano.org
```

If only AAAA returns, you have the issue.

**Fix**

Use an IPv4 literal:

```
tsunagi-node --net preview --peer 3.74.40.92:30002 ...
```

Pin in your launch script; rotate if the public IP changes.

---

## 15. Genesis file missing

**Symptom**

Node aborts during slot/epoch arithmetic, or VRF threshold is zero, or epoch
boundaries are computed against wrong parameters.

**What it means**

Shelley genesis JSON (`shelley-genesis.json`) is required to read
`activeSlotsCoeff`, `epochLength`, `slotLength`, `securityParam`, etc.

**Confirm**

```
ls -l ${TSUNAGI_HOME}/genesis/preview/shelley-genesis.json
```

**Fix**

```
mkdir -p ${TSUNAGI_HOME}/genesis/preview
curl -fsSL \
  https://book.world.dev.cardano.org/environments/preview/shelley-genesis.json \
  -o ${TSUNAGI_HOME}/genesis/preview/shelley-genesis.json
```

Repeat for `byron-genesis.json`, `alonzo-genesis.json`, `conway-genesis.json`
under the same directory if your build expects them.

---

## 16. Stale shell exports overriding forge.env (historical)

**Symptom**

`forge.env` contains `TSUNAGI_STAKE_FRACTION_X1E9=744200` but logs show the
old `636000` threshold being used.

**What it means**

Pre-PR-LOADER, `loadForgeConfig` used `setenv(overwrite=0)`, so an existing
shell export shadowed the file. Fixed by `setenv(overwrite=1)` at
`src/main.zig:275-276` — file values now win.

**Confirm before launch**

```
env | grep ^TSUNAGI_
```

The only `TSUNAGI_*` var that should be present in the shell is
`TSUNAGI_HOME`. Everything else must come from `forge.env`.

**Fix**

```
unset $(env | awk -F= '/^TSUNAGI_/ && $1 != "TSUNAGI_HOME" {print $1}')
exec tsunagi-node --net preview ...
```

If you see this on a current binary, capture both `env | grep ^TSUNAGI_` and
`grep CONFIG_LOADED $LOGS` — file an issue with both.

---

## Quick diagnostic one-liner

When in doubt, run:

```
grep -E 'CONFIG_LOADED|CONFIG_NOT_FOUND|FATAL|ERROR|ANOTHER_INSTANCE_HOLDS_LOCK|MODE:|HANDSHAKE|PARENT_SOURCE_UPDATE|FORGE_DECISION_TRUTH|PROPAGATION_AUTOSTART|PROPAGATION_SEND|PROPAGATION_SUPPRESSED' \
  $LOGS | tail -40
```

The first `FATAL`/`ERROR`/`CONFIG_NOT_FOUND` line is almost always the root
cause; everything after it is fallout.
