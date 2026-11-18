# Retention Policy

Tsunagi accumulates artifacts over time. The retention cleanup script prunes old
data to prevent unbounded disk growth while keeping enough history for debugging.

## Targets

| Artifact | Location | Default retention |
|----------|----------|-------------------|
| Fork readiness bundles | `$TSUNAGI_HOME/regress/fork_readiness/<ts>/` | 30 days |
| Block captures | `$TSUNAGI_HOME/captures/*.bin` | Newest 200 files |
| Alignment results | `$TSUNAGI_HOME/regress/alignment/results/<ts>/` | Newest 50 dirs |

## Safety

The script **never** deletes:
- `lmdb/`, `genesis/`, `keys/` directories
- `*.skey`, `*.vkey`, `opcert` files

## Usage

```bash
# Dry-run (print what would be deleted)
python3 scripts/retention_cleanup.py --home ~/tsunagi-home-mainnet --dry-run

# Live run with defaults
python3 scripts/retention_cleanup.py --home ~/tsunagi-home-mainnet

# Custom thresholds
python3 scripts/retention_cleanup.py \
  --home ~/tsunagi-home-mainnet \
  --keep-days-fork 60 \
  --keep-captures 500 \
  --keep-align-results 100
```

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--home` | `$TSUNAGI_HOME` or `~/.tsunagi` | TSUNAGI_HOME directory |
| `--dry-run` | off | Print actions without deleting |
| `--keep-days-fork` | 30 | Keep fork readiness bundles newer than N days |
| `--keep-captures` | 200 | Keep the newest N capture `.bin` files |
| `--keep-align-results` | 50 | Keep the newest N alignment result directories |

## Systemd Timer (optional)

Install the weekly timer to run cleanup automatically for all networks:

```bash
# Install units
cp docs/systemd/tsunagi-retention-cleanup.service ~/.config/systemd/user/
cp docs/systemd/tsunagi-retention-cleanup.timer   ~/.config/systemd/user/

# Enable and start
systemctl --user daemon-reload
systemctl --user enable --now tsunagi-retention-cleanup.timer

# Verify
systemctl --user list-timers | grep retention
```

To run manually:

```bash
systemctl --user start tsunagi-retention-cleanup.service
journalctl --user -u tsunagi-retention-cleanup.service --no-pager -n 50
```
