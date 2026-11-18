# Release Procedure — Tsunagi Node

## Build

```bash
cd tsunagi-node
COMMIT="$(git rev-parse --short HEAD)"
zig build -Doptimize=ReleaseSafe -Dversion=vX.Y.Z -Dcommit="$COMMIT"
```

Verify version stamp:

```bash
./zig-out/bin/tsunagi-node --version
# tsunagi-node vX.Y.Z (abc1234) ReleaseSafe
```

Reproducibility: identical tag + commit + mode produce identical output.
No build timestamp is embedded by default.

## Install to Versioned Directory

Never overwrite a running binary ("Text file busy"). Always install
into a fresh versioned directory:

```bash
VERSION=vX.Y.Z
mkdir -p ~/.local/tsunagi/$VERSION/bin
cp ./zig-out/bin/tsunagi-node ~/.local/tsunagi/$VERSION/bin/tsunagi-node
sha256sum ~/.local/tsunagi/$VERSION/bin/tsunagi-node
```

## Update Preview Service

Point the preview systemd unit to the new binary. This is the only
place where ExecStart is changed — guardian commands are read-only.

```bash
# Edit the unit file
vi ~/.config/systemd/user/tsunagi-preview.service
# Change ExecStart and WorkingDirectory to point to $VERSION:
#   WorkingDirectory=%h/.local/tsunagi/vX.Y.Z
#   ExecStart=%h/.local/tsunagi/vX.Y.Z/bin/tsunagi-node run --net preview --lang en

# Or use sed (preview only):
sed -i "s|\.local/tsunagi/v[0-9.]*|.local/tsunagi/$VERSION|g" \
  ~/.config/systemd/user/tsunagi-preview.service

systemctl --user daemon-reload
systemctl --user restart tsunagi-preview.service
```

Rule: do NOT repoint the global `~/.local/tsunagi/current` symlink
during preview work. Mainnet and sancho services must remain pinned
to their current binary until explicitly upgraded.

## Verify

```bash
# Binary version
tsunagi-node guardian version --port 9081 --service tsunagi-preview.service

# Deploy readiness
tsunagi-node guardian deploy-check --port 9081 --service tsunagi-preview.service

# Doctor
tsunagi-node guardian doctor --port 9081

# Seal latest block candidate
tsunagi-node guardian seal-latest --home $TSUNAGI_HOME

# Forge simulation (if artifacts exist)
DIR="$(ls -1t $TSUNAGI_HOME/producer_dryrun/blocks | head -n 1)"
tsunagi-node forge-sim \
  --dir $TSUNAGI_HOME/producer_dryrun/blocks/$DIR \
  --out /tmp/forge_sim_report.json

# SHA256 of installed binary
sha256sum ~/.local/tsunagi/$VERSION/bin/tsunagi-node
```

## Rules

- No mainnet/sancho restarts for preview work.
- No baseline edits.
- No co-author lines in commits.
- No build artifacts committed to git.
