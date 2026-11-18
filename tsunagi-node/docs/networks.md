# Multi-Network Profiles

**Version:** 1.5.10
**Last verified:** 2026-02-25

> This file is the canonical reference for network profiles. Values match
> `src/net/network_profile.zig` and are verified at startup via the `PROFILE:` log line.

---

## Supported Networks

| Network | Magic | Default Relay | Port | Default TSUNAGI_HOME |
|---------|-------|---------------|------|---------------------|
| mainnet | 764824073 | (relay list) | 3001 | ~/tsunagi-home-mainnet |
| preprod | 1 | preprod-node.world.dev.cardano.org | 30000 | ~/tsunagi-home-preprod |
| preview | 2 | preview-node.world.dev.cardano.org | 30002 | ~/tsunagi-home-preview |
| sancho | 4 | sanchonet-node.play.dev.cardano.org | 3001 | ~/tsunagi-home-sancho |

Network magic values are confirmed from official Cardano shelley-genesis.json files.

---

## Usage

`--net` is required. There is no default network.

```bash
tsunagi-node run --net mainnet
tsunagi-node run --net preprod
tsunagi-node run --net preview
tsunagi-node run --net sancho
```

Alternatively, set the `TSUNAGI_NET` environment variable:

```bash
export TSUNAGI_NET=preview
tsunagi-node run
```

The `--net` flag takes priority over `TSUNAGI_NET`.

---

## State Isolation

Each network uses a separate TSUNAGI_HOME directory by default. All state is stored within TSUNAGI_HOME:

| Component | Path |
|-----------|------|
| LMDB | `$TSUNAGI_HOME/lmdb/` |
| Captures | `$TSUNAGI_HOME/captures/` |
| BAeY events | `$TSUNAGI_HOME/baey/events.log` |
| BAeY state | `$TSUNAGI_HOME/baey/*.json` |
| Regress baselines | `$TSUNAGI_HOME/regress/` |
| Alignment vectors | `$TSUNAGI_HOME/regress/alignment/` |
| Cursor | `$TSUNAGI_HOME/cursor.json` |
| Journal | `$TSUNAGI_HOME/journal.ndjson` |
| UTxO snapshot | `$TSUNAGI_HOME/utxo.snapshot` |
| Genesis | `$TSUNAGI_HOME/genesis/<net>/` |

**Do not reuse LMDB directories across networks.** Cross-network state contamination will cause incorrect behavior.

---

## TSUNAGI_HOME Resolution

1. If `TSUNAGI_HOME` environment variable is set, use it (any network).
2. Otherwise, default to `$HOME/tsunagi-home-<net>` based on `--net`.

Override example:

```bash
TSUNAGI_HOME=/data/cardano-preview tsunagi-node run --net preview
```

---

## Genesis Directory Layout

Place genesis files in the network-specific subdirectory:

```
$TSUNAGI_HOME/
  genesis/
    mainnet/
      shelley-genesis.json
    preprod/
      shelley-genesis.json
    preview/
      shelley-genesis.json
    sancho/
      shelley-genesis.json
```

The path `$TSUNAGI_HOME/genesis/<net>/shelley-genesis.json` is the only auto-discovery path. There is no fallback to other networks. Set `TSUNAGI_GENESIS_PATH` to override.

---

## Running Multiple Networks Simultaneously

All networks can run concurrently on the same machine. Each service uses its own
TSUNAGI_HOME and a dedicated metrics port, so there is no state or port conflict.

### Metrics Port Assignments

| Network | Metrics Port | Service Unit |
|---------|-------------|-------------|
| mainnet | 9080 | `tsunagi-mainnet.service` |
| preview | 9081 | `tsunagi-preview.service` |
| sancho | 9082 | `tsunagi-sancho.service` |
| preprod | 9083 | `tsunagi-preprod.service` |

Ports are set via `TSUNAGI_METRICS_PORT` in each service unit. Override with
`TSUNAGI_METRICS_ADDR` if you need to bind to a different interface (default: 127.0.0.1).

### Quick Install

Use the install helper to copy all units at once:

```bash
./scripts/install_systemd_units.sh --enable \
  tsunagi-preview.service tsunagi-sancho.service
```

Or install manually:

```bash
cp docs/systemd/tsunagi-mainnet.service ~/.config/systemd/user/
cp docs/systemd/tsunagi-preview.service ~/.config/systemd/user/
cp docs/systemd/tsunagi-sancho.service  ~/.config/systemd/user/
systemctl --user daemon-reload

systemctl --user enable --now tsunagi-mainnet.service
systemctl --user enable --now tsunagi-preview.service
systemctl --user enable --now tsunagi-sancho.service
```

### Verify

```bash
# Check all services
systemctl --user status tsunagi-mainnet.service --no-pager
systemctl --user status tsunagi-preview.service --no-pager
systemctl --user status tsunagi-sancho.service  --no-pager

# Check metrics endpoints
curl -s http://127.0.0.1:9080/state | head -c 80
curl -s http://127.0.0.1:9081/state | head -c 80
curl -s http://127.0.0.1:9082/state | head -c 80
```

---

## Peer Override

For any network, you can override the default relay with `--peer`:

```bash
tsunagi-node run --net preview --peer 127.0.0.1:3002
```

Mainnet uses a built-in relay list with latency-based selection. Other networks use the default relay shown in the profile table above.
