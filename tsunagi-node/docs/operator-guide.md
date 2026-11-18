# TSUNAGI Operator Guide

Audience: Cardano stake-pool operator who has run `cardano-node` before, has VRF / KES / Opcert key files in hand, and wants to bring a TSUNAGI node online on the **preview** testnet.

This guide is copy-paste-ready. Substitute paths only where annotated.

---

## 1. Prerequisites

TSUNAGI is an independent Zig implementation. It does **not** wrap `cardano-node`. The build host must provide:

| Requirement      | Notes                                                                 |
|------------------|-----------------------------------------------------------------------|
| Zig 0.15.2       | Exact version. Download: <https://ziglang.org/download/>              |
| liblmdb-dev      | `apt install liblmdb-dev` (Debian/Ubuntu)                             |
| libsodium-dev    | `apt install libsodium-dev`                                           |
| gcc              | C linker for libc / libsodium / liblmdb                               |
| GNU make         | Some helper scripts in `scripts/` invoke `make`                       |
| Linux x86_64     | Tested on Ubuntu 22.04 / 24.04                                        |

Windows and macOS are **not supported** in the current cycle.

Pin Zig to a known location, e.g. `/home/cardano/opt/zig-x86_64-linux-0.15.2/zig`. Do **not** rely on `apt`'s `zig` package; it is too old.

---

## 2. Build

```
git clone <repo-url> tsunagi-node
cd tsunagi-node
/home/cardano/opt/zig-x86_64-linux-0.15.2/zig build -Doptimize=ReleaseSafe
./zig-out/bin/tsunagi-node --version
```

`--version` prints the embedded git revision, the Zig version used to build, the target triple, and the optimize mode. Confirm `commit=` matches `git rev-parse HEAD`.

To produce a portable artifact for deploy:

```
gzip -c ./zig-out/bin/tsunagi-node > ~/tsunagi-node.gz
md5sum ~/tsunagi-node.gz
```

---

## 3. State directory layout

The operator picks a single `TSUNAGI_HOME`. Everything the node owns lives under it. Suggested location:

```
mkdir -p ~/tsunagi-home-preview
```

After first run, the layout is:

```
${TSUNAGI_HOME}/
  lock                  # exclusive flock; one node per home
  clean                 # marker written on graceful shutdown
  forge.env             # operator-managed config (see §4)
  opcert_state.json     # opcert counter + KES period state, atomic
  logs/
    node.log            # rotated tee log (5 MB x 5)
  chain_tip/
    fragment/           # sealed block fragments (NOT chain_fragment/)
  propagation_artifact/ # outbound BlockFetch artifacts
```

The operator only ever edits `forge.env`. Everything else is owned by the node.

---

## 4. Configure forge.env

```
cp docs/forge.env.example ${TSUNAGI_HOME}/forge.env
$EDITOR ${TSUNAGI_HOME}/forge.env
```

Each key:

| Key                                       | Meaning                                                                                             |
|-------------------------------------------|-----------------------------------------------------------------------------------------------------|
| `TSUNAGI_MODE`                            | `preview_safe` (forge locally, no broadcast) or `live` (broadcast to peers)                         |
| `TSUNAGI_FORGE_ENABLE=1`                  | Opens the forge path. Without this, the node only follows.                                          |
| `TSUNAGI_FORGE_REQUIRE_GUARDIAN_CONFIRM=1`| Required safety rail. Refuses to forge unless guardian confirmation is present. Do not disable.     |
| `TSUNAGI_VRF_SKEY=/path/to/vrf.skey`      | Cardano VRF signing key (cborHex unwrapped at load).                                                |
| `TSUNAGI_KES_SKEY=/path/to/kes.skey`      | KES signing key. Period is tracked in `opcert_state.json`.                                          |
| `TSUNAGI_OPCERT=/path/to/opcert.json`     | Operational certificate. Counter is verified before every forge.                                    |
| `TSUNAGI_LMDB=/path/to/lmdb`              | Path to the LMDB env. Must be a directory path. Do not pass `0` or `1` — those are not flags here.  |
| `TSUNAGI_STAKE_FRACTION_X1E9` (optional)  | Override sigma until ledger sigma is fully wired. Integer, scaled by 1e9.                           |

Permissions: `chmod 600 forge.env`. KES / VRF / Opcert files should likewise be `0600`.

---

## 5. Launch (canonical incantation)

Use exactly this sequence. Each step matters.

```
pkill -9 -f "tsunagi-node run" 2>/dev/null; sleep 2
for v in $(env | awk -F= '/^TSUNAGI_/{print $1}' | grep -v '^TSUNAGI_HOME$'); do unset "$v"; done
export TSUNAGI_HOME=/home/cardano/tsunagi-home-preview
nohup ./zig-out/bin/tsunagi-node run --net preview --peer 3.74.40.92:30002 \
  > ~/tsunagi-logs/forge-N.log 2>&1 &
```

Why each line:

- `pkill ... ; sleep 2` — kills any prior instance and waits for the kernel to release its `flock`.
- The `for v in ...; unset` loop — strips every `TSUNAGI_*` shell export **except** `TSUNAGI_HOME`. This ensures `forge.env` is the single source of truth; stray shell exports otherwise silently win.
- `export TSUNAGI_HOME=...` — the only env var the node trusts from the shell.
- `nohup ... &` — survives shell exit; stdout/stderr captured to a versioned log.
- The `lock` file at `${TSUNAGI_HOME}/lock` is acquired with `flock(LOCK_EX | LOCK_NB)`. A second instance against the same home aborts immediately.

Increment `forge-N.log` per launch (`forge-1.log`, `forge-2.log`, …). Do not overwrite.

---

## 6. Lifecycle — what to expect in logs

Tail the log and watch these lines appear in this order. Exact strings:

```
LOCK_ACQUIRED: path=${TSUNAGI_HOME}/lock
LOG_TEE_INSTALLED: file=${TSUNAGI_HOME}/logs/node.log rotate_mb=5 keep=5
CONFIG_LOADED: path=${TSUNAGI_HOME}/forge.env keys=N
MODE: live (broadcast enabled)              # or: preview_safe (no broadcast)
FORGE: enabled (mode=live)                  # only if forge keys present + valid
PROFILE: net=preview magic=2 ...
```

Then the ChainSync follower attaches to the relay and fragments start growing:

```
PARENT_SOURCE_UPDATE: peer=primary new_slot=...
```

On a slot where this pool is leader-eligible:

```
FORGE_DECISION_TRUTH: ... leader_eligible=true
FORGE_PROMOTE_ATOMIC: ... seal=...
PROPAGATION_SEND: site=RF_PUSH slot=... block=...        # live mode only
BF_SERVE_BLOCK + PROPAGATION_SEND: site=BF_BLOCK ...
EVENT_BLOCK_ACCEPTED                                      # first accepted block
```

If `MODE: preview_safe` is shown, you will see `FORGE_PROMOTE_ATOMIC` but **no** `PROPAGATION_SEND` or `EVENT_BLOCK_ACCEPTED`. That is intentional — preview_safe forges to disk only.

---

## 7. Live operator panel

```
./zig-out/bin/tsunagi-node view
```

Connects to the running node's `/status/full` endpoint and renders a single-screen cockpit (mode, parent slot, follower lag, fragment count, forge eligibility window, propagation receipts, opcert period, alerts). Refreshes every 2 s. Press `q` to quit.

---

## 8. Graceful stop

```
kill -TERM <pid>
```

The follower drains its current ChainSync turn, returns from the read loop, defer chains run, the LMDB env is checkpointed, and a `clean` marker is written to `${TSUNAGI_HOME}/clean`. The `lock` is released.

`kill -9` works but **skips the `clean` marker**. On the next boot the node performs a recovery scan over `chain_tip/fragment/` and `propagation_artifact/`. This is correct but slow. Prefer `-TERM`.

---

## 9. Restart

Just run the §5 incantation again with the same `TSUNAGI_HOME`. The lock auto-releases on prior process exit. If a stale `lock` remains because the host crashed, the kernel discards the `flock` advisory record automatically — you do **not** need to delete the file by hand.

If `LOCK_ACQUIRED` does not appear within a second of launch, another `tsunagi-node` is still alive. Run `pgrep -af tsunagi-node` and resolve before retrying.

---

## 10. Updating to a new gz

Operator pattern, no in-place clobber:

```
# fetch
scp build-host:~/tsunagi-node.gz ~/

# stage
gunzip -c ~/tsunagi-node.gz > ~/tsunagi-node.new
chmod +x ~/tsunagi-node.new

# install (versioned dir + symlink flip is preferred; minimal shown here)
mv ~/tsunagi-node.new ~/bin/tsunagi-node

# restart
kill -TERM "$(pgrep -f 'tsunagi-node run')"
# ... wait for clean marker, then re-run §5
```

Never copy a binary over the running file. Move-then-restart only.

---

## 11. Sanity checks

After launch, three commands tell you the node is healthy:

```
# 1. Exactly one process
pgrep -af tsunagi-node

# 2. Lifecycle transitions visible
tail -f ${TSUNAGI_HOME}/logs/node.log \
  | grep -E '(MODE|CONFIG_LOADED|FORGE_DECISION_TRUTH|PROPAGATION_SEND)'

# 3. Fragment store is growing
ls ${TSUNAGI_HOME}/chain_tip/fragment/ | wc -l
```

The fragment count should increase monotonically as the follower advances. If it stalls for more than ~60 s while the relay is reachable, capture a log slice and investigate `PARENT_SOURCE_UPDATE` cadence before doing anything else.

---

## Quick reference

| Action          | Command                                                    |
|-----------------|------------------------------------------------------------|
| Build           | `zig build -Doptimize=ReleaseSafe`                         |
| Version         | `./zig-out/bin/tsunagi-node --version`                     |
| Launch          | See §5                                                     |
| Live panel      | `./zig-out/bin/tsunagi-node view`                          |
| Graceful stop   | `kill -TERM <pid>`                                         |
| Tail key events | `tail -f ${TSUNAGI_HOME}/logs/node.log \| grep -E ...`     |
| Fragment count  | `ls ${TSUNAGI_HOME}/chain_tip/fragment/ \| wc -l`          |
