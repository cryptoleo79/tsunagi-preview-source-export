# TSUNAGI ops/systemd

This directory contains example systemd user unit templates.

## Install TSF nightly artifact export

```bash
mkdir -p ~/.config/systemd/user
cp ops/systemd/tsf-artifact.service.example ~/.config/systemd/user/tsf-artifact.service
cp ops/systemd/tsf-artifact.timer.example ~/.config/systemd/user/tsf-artifact.timer

systemctl --user daemon-reload
systemctl --user enable --now tsf-artifact.timer
systemctl --user list-timers --all | grep tsf-artifact
```

### What it does

- Runs daily at 03:00 local time
- Exports a TSF snapshot from LMDB to `~/tsunagi-home-mainnet/tsf/mainnet-YYYYMMDD-HHMMSS.tsf`
- Compresses with gzip (`--gzip`)
- Validates with `--strict`
- Retains the last 7 artifacts (both `.tsf` and `.tsf.gz`), deletes older

### Manual run

```bash
systemctl --user start tsf-artifact.service
journalctl --user -u tsf-artifact.service --since "1 min ago"
```

### Check timer status

```bash
systemctl --user list-timers --all | grep tsf-artifact
```

## Install LMDB autoswitch (convergence detector)

When LMDB truth ratio reaches >= 0.999 and fallback has been stable for >= 10 minutes,
the node writes `TSUNAGI_HOME/native_ready.json`. The autoswitch timer checks for this
marker every 5 minutes and, if found, creates a systemd drop-in to enable `lmdb_native`
mode, then restarts the node.

```bash
cp ops/systemd/autoswitch-apply.service.example ~/.config/systemd/user/autoswitch-apply.service
cp ops/systemd/autoswitch-apply.timer.example ~/.config/systemd/user/autoswitch-apply.timer

systemctl --user daemon-reload
systemctl --user enable --now autoswitch-apply.timer
systemctl --user list-timers --all | grep autoswitch
```

### How it works

1. The node detects convergence and writes `~/tsunagi-home-mainnet/native_ready.json`
2. The timer runs `autoswitch-apply` every 5 minutes
3. If the marker exists AND `TSUNAGI_AUTOSWITCH=1` (set in the service), it:
   - Creates `~/.config/systemd/user/tsunagi-mainnet.service.d/99-native.conf`
   - Runs `systemctl --user daemon-reload && restart tsunagi-mainnet.service`
4. The drop-in sets `TSUNAGI_LMDB_TRUTH=1`, `TSUNAGI_LMDB_AUTHORITY=1`, `TSUNAGI_MODE=lmdb_native`

### Manual check

```bash
# Check if marker exists
cat ~/tsunagi-home-mainnet/native_ready.json 2>/dev/null || echo "not ready"

# Manual apply (requires TSUNAGI_AUTOSWITCH=1)
TSUNAGI_AUTOSWITCH=1 ./tsunagi-node/zig-out/bin/tsunagi-node autoswitch-apply
```

## Install BAEY Guardian loop (dry-run policy ticks)

Runs every 30 seconds. Fetches metrics from the running node, computes a
suspicion score, and logs a `policy_tick` event to `TSUNAGI_HOME/baey/events.log`.
Does NOT execute any action — observation only.

```bash
cp ops/systemd/baey-loop.service.example ~/.config/systemd/user/baey-loop.service
cp ops/systemd/baey-loop.timer.example   ~/.config/systemd/user/baey-loop.timer

systemctl --user daemon-reload
systemctl --user enable --now baey-loop.timer
systemctl --user list-timers --all | grep baey-loop
```

### Verify

```bash
journalctl --user -u baey-loop.service -n 30 --no-pager -o cat
tail -n 5 ~/tsunagi-home-mainnet/baey/events.log | grep policy_tick
```

## Main node service

See `tsunagi-mainnet.service.example` for the main node unit template.
