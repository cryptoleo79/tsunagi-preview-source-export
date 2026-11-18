# Auto Vector Capture

Automatically extracts alignment vectors from new block capture segments
and refreshes the alignment suite nightly.

## How It Works

1. The tsunagi node writes block captures to `$TSUNAGI_HOME/captures/`.
   When a file exceeds the rotation threshold (default 256 MB), it is
   renamed to `<net>.<unix_timestamp>.bin` and a new active file begins.

2. `auto_capture_vectors.py` processes only **completed (rotated) segments**
   — never the active file being written to by the node.

3. A cursor file (`$TSUNAGI_HOME/regress/alignment/.auto_capture_cursor`)
   records the last processed segment filename. On each run, only segments
   with names sorting after the cursor are processed.

4. Vectors are appended to the existing JSONL files. Deduplication is
   enforced by header hash — no duplicate vectors are written.

5. After extraction, the alignment suite (`run_alignment_suite.py`) runs
   automatically to validate the new vectors.

## Cursor Mechanism

The cursor stores a single filename (e.g. `mainnet.1771836535.bin`).
Capture segments use `<net>.<unix_timestamp>.bin` naming, so lexicographic
ordering matches chronological ordering.

**Reset the cursor** to reprocess all segments:
```bash
rm $TSUNAGI_HOME/regress/alignment/.auto_capture_cursor
```

**Set cursor to a specific segment** to skip earlier files:
```bash
echo "mainnet.1771836535.bin" > $TSUNAGI_HOME/regress/alignment/.auto_capture_cursor
```

## Usage

```bash
# Manual run
python3 scripts/auto_capture_vectors.py \
  --home ~/tsunagi-home-preview \
  --net preview \
  --max-new 50

# Cap vector growth (extract fewer per run)
python3 scripts/auto_capture_vectors.py \
  --home ~/tsunagi-home-mainnet \
  --net mainnet \
  --max-new 10
```

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--home` | (required) | TSUNAGI_HOME directory |
| `--net` | (required) | Network name (mainnet, preprod, preview, sancho) |
| `--max-new` | 50 | Max new vectors to extract per run |

## Capping Vector Growth

The `--max-new` flag limits how many vectors are added per run. Combined
with the retention cleanup timer (v1.5.5), this keeps disk usage bounded.

To cap total vector count, periodically trim the JSONL files:
```bash
tail -n 500 $TSUNAGI_HOME/regress/alignment/header_hash.jsonl > /tmp/h.jsonl
mv /tmp/h.jsonl $TSUNAGI_HOME/regress/alignment/header_hash.jsonl
```

## Systemd Timer Setup

Install nightly timers for each network:

```bash
# Install units
cp docs/systemd/tsunagi-auto-capture-preview.service ~/.config/systemd/user/
cp docs/systemd/tsunagi-auto-capture-preview.timer   ~/.config/systemd/user/
cp docs/systemd/tsunagi-auto-capture-sancho.service   ~/.config/systemd/user/
cp docs/systemd/tsunagi-auto-capture-sancho.timer     ~/.config/systemd/user/

# Enable
systemctl --user daemon-reload
systemctl --user enable --now tsunagi-auto-capture-preview.timer
systemctl --user enable --now tsunagi-auto-capture-sancho.timer

# Verify
systemctl --user list-timers | grep auto-capture
```

## Pipeline

```
captures/*.bin  -->  auto_capture_vectors.py  -->  header_hash.jsonl
                                                   vrf_u.jsonl
                                              -->  run_alignment_suite.py
                                              -->  alignment results/
                                              -->  fork_readiness_check.py (next run)
```
