# Integrity Monitor

**Version:** 1.6.1

---

## Purpose

The integrity monitor is a lightweight operator tool that polls the `/status`
endpoint on each running Tsunagi network and logs anomalies. It detects:

- **Slot stalls** — the tip slot has not advanced for more than 120 seconds.
- **Header stability drops** — `header_stable` transitions from 1 to 0,
  indicating the header chain anchor was reset (typically after a rollback
  or reconnect).
- **Digest changes** — the UTxO state digest changed between polls, which is
  normal chain progress and logged at INFO level for audit trail purposes.

This is read-only monitoring. The script does not modify runtime state, restart
services, or interact with the node beyond HTTP GET requests to localhost.

---

## How to Run

### Manual (foreground)

```bash
./scripts/tsunagi_integrity_monitor.sh
```

### Background (nohup)

```bash
nohup ./scripts/tsunagi_integrity_monitor.sh > /dev/null 2>&1 &
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TSUNAGI_INTEGRITY_DIR` | `~/tsunagi-integrity` | Directory for the log file |

The log is written to `$TSUNAGI_INTEGRITY_DIR/integrity.log`.

### Optional: systemd service

For production use, a systemd user service keeps the monitor running across
reboots:

```ini
[Unit]
Description=Tsunagi Integrity Monitor

[Service]
Type=simple
ExecStart=%h/src/tsunagi-follower/scripts/tsunagi_integrity_monitor.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
```

Save to `~/.config/systemd/user/tsunagi-integrity-monitor.service`, then:

```bash
systemctl --user daemon-reload
systemctl --user enable --now tsunagi-integrity-monitor.service
```

---

## Interpreting Warnings

### `INFO: digest changed (normal chain progress)`

The UTxO state digest changed since the last poll. This means new blocks were
applied. Expected during normal operation — appears every poll cycle while the
node is syncing or following the tip.

### `WARNING: slot stalled for Ns (slot=X)`

The tip slot has not changed for N seconds (threshold: 120s). Possible causes:

- The upstream peer is temporarily unreachable.
- The node is in a reconnect cycle after a rollback or peer switch.
- The network itself is experiencing low block production.

A brief stall (2-5 minutes) during a peer switch is normal. Sustained stalls
(>10 minutes) warrant investigation — check `journalctl --user -u tsunagi-<net>.service`.

### `WARNING: header_stable dropped to 0`

The header chain head was reset. This happens when:

- A rollback invalidated the current header chain anchor.
- A peer switch caused the node to re-anchor to a different chain tip.
- The 3-strike header mismatch threshold was hit, triggering a reconnect.

A transient drop (stable returns to 1 within 1-2 poll cycles) is normal after
rollbacks. Persistent instability (stable stays 0 for many cycles) may indicate
a problematic peer or network partition.

### `ERROR: no /status response`

The `/status` endpoint did not respond. The node service may be stopped, the
metrics server may not have started yet, or the port may be incorrect.

---

## Monitored Networks

| Network | Port | Endpoint |
|---------|------|----------|
| mainnet | 9080 | `http://127.0.0.1:9080/status` |
| preview | 9081 | `http://127.0.0.1:9081/status` |
| sancho  | 9082 | `http://127.0.0.1:9082/status` |

---

## What This Is Not

- Not a consensus validator.
- Not a block producer health check.
- Does not modify node configuration or restart services.
- Does not send alerts (pipe the log to your alerting system if needed).
