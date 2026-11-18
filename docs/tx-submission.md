# Transaction Submission Relay

**Version:** 1.7.0

---

## Purpose

Tsunagi supports safe, opt-in transaction submission relay over the NtN
TxSubmission2 mini-protocol. This enables use cases such as:

- Hydra head open/close transactions
- Edge device or IoT transaction submission
- Lightweight transaction relay without running a full Cardano node

Transactions are accepted via HTTP, admitted to a local mempool, and relayed
to the connected peer via NtN inventory broadcast. The peer then requests and
receives the transaction bodies through the standard Cardano protocol.

---

## How to Enable

Two environment variables control the feature:

| Variable | Purpose | Default |
|----------|---------|---------|
| `TSUNAGI_TXSUB_ENABLE=1` | Enable HTTP `/tx/submit` endpoint (local mempool admission) | OFF |
| `TSUNAGI_TXSUB_BROADCAST=1` | Enable NtN relay to connected peer | OFF |

**Both must be set** for end-to-end relay. Setting `TSUNAGI_TXSUB_ENABLE=1` alone
enables local mempool admission without broadcasting to the network.

Add to your systemd unit `[Service]` section:

```ini
Environment=TSUNAGI_TXSUB_ENABLE=1
Environment=TSUNAGI_TXSUB_BROADCAST=1
```

Then restart:

```bash
systemctl --user daemon-reload
systemctl --user restart tsunagi-mainnet.service
```

---

## How to Submit

### Binary CBOR

```bash
curl -X POST \
  -H "Content-Type: application/octet-stream" \
  --data-binary @tx.cbor \
  http://127.0.0.1:9080/tx/submit
```

### Hex-encoded

```bash
curl -X POST \
  -d "84a400..." \
  http://127.0.0.1:9080/tx/submit
```

If `Content-Type` does not contain `octet-stream`, the body is treated as
hex-encoded text.

---

## Response Codes

| Code | Result | Meaning |
|------|--------|---------|
| 200 | `{"status":"submitted","result":"accepted","hash":"...","size":N}` | Tx accepted into mempool |
| 200 | `{"status":"submitted","result":"duplicate"}` | Tx already in mempool |
| 400 | `{"status":"rejected","result":"cbor_invalid"}` | Invalid CBOR structure |
| 403 | `{"status":"rejected","result":"disabled"}` | TSUNAGI_TXSUB_ENABLE not set |
| 413 | `{"status":"rejected","result":"too_large"}` | Tx exceeds 64 KB limit |
| 429 | `{"status":"rejected","result":"rate_limited"}` | Exceeded 10 tx/min limit |
| 503 | `{"status":"rejected","result":"safe_mode"}` | BAEY safe mode active |
| 503 | `{"status":"rejected","result":"mempool_unavailable"}` | Mempool not initialized |

---

## HTTP Semantics

The HTTP response reflects **local mempool admission**. Network-level propagation
is asynchronous — the NtN TxSubmission2 protocol is inventory-based, not
request-response. There is no synchronous "accepted/rejected" from the remote peer.

To observe network propagation, monitor these Prometheus metrics:

- `tsunagi_txsub_broadcast_sent_total` — inventory broadcasts sent to peer
- `tsunagi_txsub_txs_served_total` — transaction bodies served to peer

---

## Security

- **Localhost only.** The metrics server binds to 127.0.0.1 by default. No remote
  access is possible unless the operator explicitly overrides `TSUNAGI_METRICS_ADDR`.
- **Disabled by default.** Without `TSUNAGI_TXSUB_ENABLE=1`, all submissions return 403.
- **Rate limited.** 10 transactions per minute per node process.
- **Size limited.** 64 KB maximum transaction size.
- **BAEY safe mode.** Submissions are blocked when the BAEY guardian activates safe mode.

---

## Audit Log

When tx submission is enabled, all submission events are logged to:

```
$TSUNAGI_HOME/txsub/events.log
```

Format: JSONL (one JSON object per line):

```json
{"unix":1234567890,"net":"mainnet","tx_hash":"abcd...","size_bytes":1234,"result":"accepted","reject_reason":""}
```

The log file is created automatically if missing. The `txsub/` directory is
created at startup when the feature is enabled.

---

## Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `tsunagi_txsub_relay_requests_total` | counter | HTTP /tx/submit requests received |
| `tsunagi_txsub_relay_accepted_total` | counter | Txs accepted into mempool |
| `tsunagi_txsub_relay_rejected_total` | counter | Txs rejected by local validation |
| `tsunagi_txsub_relay_disabled_total` | counter | Requests rejected (relay disabled) |
| `tsunagi_txsub_relay_rate_limited_total` | counter | Requests rejected by rate limit |
| `tsunagi_txsub_relay_too_large_total` | counter | Requests rejected (tx too large) |
| `tsunagi_txsub_relay_last_result_unix` | gauge | Unix timestamp of last result |

The `/state` endpoint also includes a `txsub` section:

```json
{
  "txsub": {
    "enabled": 0,
    "rate_limit_per_min": 10,
    "max_tx_bytes": 65536,
    "requests_total": 0,
    "accepted_total": 0,
    "rejected_total": 0,
    "last_result_unix": 0
  }
}
```

---

## What This Is Not

- No block forging or block production.
- No mempool construction (Tsunagi does not build blocks from the mempool).
- No transaction broadcast to multiple peers (relay is to the single connected peer).
- No implicit signing of any kind.
