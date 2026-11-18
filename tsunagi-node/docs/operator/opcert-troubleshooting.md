# Operator Runbook — Opcert Self-Verify Troubleshooting

Use this when the forge log shows:

```
FORGE_SELF_VERIFY_FAIL: gate=opcert reason=ed25519_verify_failed ...
```

The forge self-verify reconstructs the operational certificate's signed message and verifies it
against the cold key **before** broadcasting any block:

```
sigma_msg = kes_root(32) ‖ seq_no(8, big-endian) ‖ kes_period(8, big-endian)
ed25519_verify(pk = cold_vk, msg = sigma_msg, sig = opcert_sigma) must succeed
```

It fails iff **any** of `kes_root`, `seq_no`, `kes_period`, `cold_vk`, `opcert_sigma` disagrees with
what the cold key signed in `node.cert`. ed25519 is deterministic — there is no flaky path. Work the
checklist top to bottom; do not stop at the first mismatch, because the fault can be **compound** (see
`docs/incidents/2026-06-opcert-self-verify-root-cause.md`).

---

## Deterministic checklist

### STEP 1 — Verify `TSUNAGI_HOME`

Confirm the home the **running** node actually uses (from the launcher, not by assumption):

```bash
grep -n "TSUNAGI_HOME" /home/cardano/start-relay-forge.sh        # the active launcher
pgrep -af tsunagi-node                                            # confirm the live PID/binary
```

> Pitfall: multiple homes exist (`…-colo`, `…-preview`). Resetting state in the wrong home does
> nothing. Everything below operates on `$H = $TSUNAGI_HOME`.

### STEP 2 — Verify `opcert_state.json`

```bash
H=<the TSUNAGI_HOME from STEP 1>
cat "$H/opcert_state.json"
grep "OPCERT_STATE" "$H"/logs/*.log ~/tsunagi-logs/forge.log 2>/dev/null | tail -1
# boot log shows the authoritative loaded value:
#   OPCERT_STATE: current=<seq> source=file last_persisted=<seq>
```

The `seq_no` in this file is what self-verify uses. It must equal the **counter** in `node.cert`
(STEP 5). If it drifted (e.g. `15`, `24`), reset it:

```bash
cp -a "$H/opcert_state.json" "$H/opcert_state.json.bak.$(date +%s)"
printf '{"seq_no":<CERT_COUNTER>,"last_slot":0}' > "$H/opcert_state.json"   # usually 0
```

> **Precedence trap:** `opcert_state.json` (file) WINS over `TSUNAGI_OPCERT_SEQ` (env). Setting the env
> var alone has no effect. Reset the **file**, then restart (seq is read once at boot).

### STEP 3 — Verify `TSUNAGI_OPCERT_SEQ`

```bash
grep -n "TSUNAGI_OPCERT_SEQ" /home/cardano/start-relay-forge.sh /home/cardano/tsunagi-auto.sh
```

Should equal the cert counter. Note this is only used when `opcert_state.json` is absent/unparyable
(file wins otherwise).

### STEP 4 — Verify `TSUNAGI_OPCERT_SIGMA_HEX`

```bash
grep -n "TSUNAGI_OPCERT_SIGMA_HEX" /home/cardano/start-relay-forge.sh /home/cardano/tsunagi-auto.sh
grep "TSUNAGI_OPCERT_SIGMA_HEX" ~/tsunagi-logs/forge.log | tail -1   # what the runtime echoed at boot
grep "FORGE_SELF_VERIFY_FAIL" ~/tsunagi-logs/forge.log* | grep -o "sigma_first8=[0-9a-f]*" | tail -1
```

- Must be **exactly 128 hex chars (64 bytes)**.
- `sigma_first8` from a failure line must equal the first 16 hex of the cert sigma (STEP 5).
- **This env var has no file source — the launcher is the only authoritative input.** A hand-edited
  launcher is the most likely corruption point. Never slice the sigma out of the cborHex by hand; use
  STEP 5.

### STEP 5 — Decode `node.cert`

```bash
python3 scripts/extract-opcert-sigma.py /home/cardano/tsunagi-keys-tsng/node.cert
```

This prints the authoritative `cold_vk`, `kes_root`, `counter`, `period`, and `sigma`, plus a
ready-to-paste `TSUNAGI_OPCERT_SIGMA_HEX=<sigma>` line. The sigma is the 64 bytes between the `5840`
and the trailing `5820` CBOR markers.

### STEP 6 — Compare

Build a single table and require **every** row to match:

| field    | from `node.cert` (STEP 5) | from runtime / env                                  | must match |
|----------|---------------------------|-----------------------------------------------------|-----------|
| cold vk  | counter file / cert       | `TSUNAGI_COLD_VK_HEX`, log `cold_vk_first8`          | ✅ |
| kes root | cert `kes_vkey`           | log `kes_root_first8`                                | ✅ |
| period   | cert `kes_period`         | `TSUNAGI_KES_START_PERIOD`, log `period`            | ✅ |
| seq      | cert `counter`            | `opcert_state.json` seq_no, log `OPCERT_STATE`      | ✅ |
| sigma    | cert `sigma`              | `TSUNAGI_OPCERT_SIGMA_HEX`, log `sigma_first8`      | ✅ |

Any ❌ → fix that source. **Do not stop at the first ❌** — fix all, because compound corruption is
real (June 2026: both seq and sigma were wrong simultaneously).

### STEP 7 — Verify self-verify inputs match cert inputs

Offline proof before the next elected slot (no KES/opcert burn):

```bash
python3 scripts/extract-opcert-sigma.py --verify /home/cardano/tsunagi-keys-tsng/node.cert
```

This reconstructs `sigma_msg = kes_root ‖ counter ‖ period` and runs the same ed25519 verification the
node does. Expect `SELF-VERIFY PARITY: PASS`. Then restart and confirm at the next elected slot:

```
FORGE_SELF_VERIFY: gate=opcert pass=YES seq=<counter> period=<period>
```

---

## Authoritative sources for `TSUNAGI_OPCERT_SIGMA_HEX` (and the other opcert inputs)

Reference for STEP 6. "Authoritative" = where the correct value originates; "launcher" = where it is
injected into the runtime environment (and therefore where corruption is most likely).

**Authoritative (origin of truth):**
- `node.cert` (`NodeOperationalCertificate`, e.g. `tsunagi-keys-tsng/node.cert`) — contains
  `kes_vkey`, `counter`, `kes_period`, `sigma`, `cold_vkey`. Decoded by
  `scripts/extract-opcert-sigma.py`.
- `cold.counter` (`NodeOperationalCertificateIssueCounter`) — "next certificate issue number"; the
  current cert's counter is this minus one.

**Runtime loader (where the node reads them):** `src/producer/producer.zig`
- seq: `opcert_state.json` (file) → else `TSUNAGI_OPCERT_SEQ` (env). **File wins.**
- sigma: `TSUNAGI_OPCERT_SIGMA_HEX` (env only — **no file source**).
- cold vk: `TSUNAGI_COLD_VK_HEX`. period: `TSUNAGI_KES_START_PERIOD`. kes root: extracted from the KES
  key (`kes.skey`).

**Launcher sources (where the env is set — corruption surface):**
- `start-relay-forge.sh` — `export TSUNAGI_OPCERT_SIGMA_HEX=…` (and `TSUNAGI_OPCERT_SEQ`,
  `TSUNAGI_COLD_VK_HEX`, `TSUNAGI_KES_START_PERIOD`).
- `tsunagi-auto.sh` — same variables (multi-line invocation form).
- `{TSUNAGI_HOME}/forge.env` (and its many `.bak` variants) — historically held the **correct** sigma
  (`5e3c8839…`).

**In-repo documentation references:** `docs/operator.md`, `docs/block-candidate.md`,
`docs/FIRST_BLOCK_GO_READINESS.md`.

> Golden rule: regenerate launcher sigma values **only** via `scripts/extract-opcert-sigma.py`. Manual
> slicing of the cborHex caused the June 2026 corruption.
