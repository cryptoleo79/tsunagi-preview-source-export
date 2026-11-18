# Incident — Compound Opcert Self-Verify Failure (June 2026)

**Status:** Resolved
**Severity:** Blocker (no block could be forged on the live preview relay)
**Pool:** `preview-tsunagi-pool` (cold vk `190950f3…d167`)
**Deployed binary at time of incident:** `tsunagi-node` 0.15.2, sha256 `932dc5008169ffc9f449bb6ec4a0474be839b94c96bf0b912e617d5539018dd9`
**Network:** preview (1-second slots)

---

## 1. Summary

After the stale-parent acceptance fix was deployed, every elected slot still failed to forge. The
dominant failure was:

```
FORGE_SELF_VERIFY_FAIL: gate=opcert reason=ed25519_verify_failed
  cold_vk_first8=190950f3eb090590 kes_root_first8=b1da2f0e79593d06 seq=15 period=846
```

The investigation proved this was **not** a single fault. It was a **compound corruption** of the
operational-certificate material that the forge self-verify check depends on:

1. **Opcert counter drift** — `opcert_state.json` had drifted to `seq_no=15` (the per-forge
   `OPCERT_INCREMENT` had walked it up over months of local forges).
2. **Corrupted launcher sigma** — `start-relay-forge.sh` / `tsunagi-auto.sh` exported a
   `TSUNAGI_OPCERT_SIGMA_HEX` value that was **not the opcert signature** but a mis-sliced region of
   the `node.cert` CBOR.

Either fault alone is sufficient to fail self-verify. Both were present. Resetting `seq` to 0 was
necessary but **not sufficient** — the run continued to fail at `seq=0` because the loaded sigma was
the corrupt slice. Only after correcting the launcher sigma did all five self-verify inputs match the
certificate.

---

## 2. What the self-verify check actually verifies

`src/producer/producer.zig` (FORGE_SELF_VERIFY gate) reconstructs the canonical Cardano operational
certificate signed message and verifies it against the cold key, before any block is broadcast:

```
sigma_msg (48 bytes) = kes_root(32) ‖ seq_no(8, big-endian) ‖ kes_period(8, big-endian)
ed25519_verify(pk = cold_vk, msg = sigma_msg, sig = opcert_sigma)  must succeed
```

Inputs and their sources:

| input            | runtime field            | source                                                            |
|------------------|--------------------------|-------------------------------------------------------------------|
| `kes_root`       | `forge_kes_root`         | `kes_sign.extractRootPk(kes_key_state)` — KES **root** (invariant across periods) |
| `seq_no`         | `ctx.dryrun_opcert_seq_no` | `{TSUNAGI_HOME}/opcert_state.json` (file wins) → else `TSUNAGI_OPCERT_SEQ` |
| `kes_period`     | `ctx.kes_start_period`   | `TSUNAGI_KES_START_PERIOD`                                         |
| `cold_vk` (pk)   | `ctx.dryrun_issuer_vk`   | `TSUNAGI_COLD_VK_HEX`                                              |
| `opcert_sigma`   | `ctx.dryrun_opcert_sigma`| `TSUNAGI_OPCERT_SIGMA_HEX` (env-only — **no file source**)         |

ed25519 verification is deterministic. The signature in `node.cert` is produced once by the cold key
over `(kes_vkey ‖ counter ‖ kes_period)`. It is valid for **exactly one** `(kes_vkey, counter,
kes_period)` tuple. If any reconstructed input differs from what the cold key signed, verification
fails — every slot, with no randomness.

---

## 3. Timeline

| time (2026-06)   | event |
|------------------|-------|
| (prior)          | Stale-parent acceptance fix deployed (binary `932dc500`, base `9182326` + applied-tip fix). |
| post-deploy      | Every elected slot fails. Majority: `FORGE_SELF_VERIFY_FAIL gate=opcert seq=15`. Minority: `FORGE_REFUSE_STALE_PARENT`. |
| diagnosis 1      | Decoded the live `node.cert`: counter=0, but runtime `seq=15` → seq drift identified. |
| action 1         | Identified active `TSUNAGI_HOME=/home/cardano/tsunagi-home-colo` (not `…-preview`). Reset `colo/opcert_state.json` `{"seq_no":15,…}` → `{"seq_no":0,"last_slot":0}`. Restarted. |
| verify 1         | Boot shows `OPCERT_STATE: current=0 source=file last_persisted=0`. |
| **falsification**| Next elected slot **114278360** STILL fails at `seq=0`: `… seq=0 period=846 sigma_first8=28a969405cf5a6e2`. seq drift alone did not explain the failure. |
| diagnosis 2      | Pulled the runtime `sigma_first8`: `28a96940…`. Decoded `node.cert` sigma: `5e3c8839…`. They differ. The launcher sigma is corrupt. |
| evidence         | `start-relay-forge.sh` / `tsunagi-auto.sh` export `TSUNAGI_OPCERT_SIGMA_HEX=28a96940…d167` — a **tail-slice of the cborHex**, not the signature. Offline ed25519: correct sigma verifies @seq=0 (PASS), corrupt sigma fails (FAIL). |
| action 2         | Corrected launcher `TSUNAGI_OPCERT_SIGMA_HEX` → `5e3c8839…2c05` (the `node.cert` sigma). Restarted. |
| verify 2         | Boot shows correct sigma loaded + `OPCERT_STATE current=0`. All five self-verify inputs now match the cert. |

---

## 4. Failed slots (evidence)

`seq=15` failures (corrupt seq AND corrupt sigma):

```
slot=114222547  seq=15 period=846 sigma_first8=28a969405cf5a6e2
slot=114223290  seq=15 period=846 sigma_first8=28a969405cf5a6e2
slot=114228671  seq=15 period=846 sigma_first8=28a969405cf5a6e2
slot=114234564  seq=15 period=846 sigma_first8=28a969405cf5a6e2
slot=114258127  seq=15 period=846 sigma_first8=28a969405cf5a6e2
slot=114258252  seq=15 period=846 sigma_first8=28a969405cf5a6e2
```

`seq=0` failure (seq corrected, sigma still corrupt — the decisive falsification):

```
slot=114278360  seq=0  period=846 sigma_first8=28a969405cf5a6e2
```

Slots that instead hit the (separate, intermittent) parent gate: `114224377`, `114230905`,
`114259833` — `FORGE_REFUSE_STALE_PARENT` with `hashes_equal=false`. These are documented as a
distinct, non-systematic freshness refusal in the acceptance-frontier status doc; they are not part of
the opcert fault.

---

## 5. Decoded `node.cert` evidence (the ground truth)

`node.cert` cborHex (`NodeOperationalCertificate`):

```
82845820 b1da2f0e79593d0671f0e574083f944a4b502482ec4a4361bac2f23757dc66d3   <- 5820 kes_vkey(32)
00                                                                          <- counter = 0
19034e                                                                      <- kes_period = 846 (0x034e)
5840 5e3c88392cb5e2d18b3042073ef5927b001541d7d446f93d7ddeb4fcbc76ac2299
     9728a969405cf5a6e2dae3acc354c2fa9d97959ef134802a735f229b4c2c05         <- 5840 sigma(64)
5820 190950f3eb0905909066d0c5525671bfc3017e165e704683e4ca26b7bbf2d167       <- 5820 cold_vkey(32)
```

Decoded fields:

| field    | value |
|----------|-------|
| kes_root | `b1da2f0e79593d0671f0e574083f944a4b502482ec4a4361bac2f23757dc66d3` |
| counter  | `0` |
| period   | `846` |
| cold_vk  | `190950f3eb0905909066d0c5525671bfc3017e165e704683e4ca26b7bbf2d167` |
| **sigma**| `5e3c88392cb5e2d18b3042073ef5927b001541d7d446f93d7ddeb4fcbc76ac22599728a969405cf5a6e2dae3acc354c2fa9d97959ef134802a735f229b4c2c05` |

Every failure-log constant matched the cert except the counter (`0` in cert vs `15`/`0` at runtime)
and the sigma. The cert is the authoritative source for all five inputs.

---

## 6. Seq-drift evidence

- `/home/cardano/tsunagi-home-colo/opcert_state.json` = `{"seq_no":15,"last_slot":110584908}` (the
  active `TSUNAGI_HOME`).
- `/home/cardano/tsunagi-home-preview/opcert_state.json.drifted-to-24.bak` = `{"seq_no":24}` — prior
  drift on the preview home.
- Mechanism: `producer.zig` `OPCERT_INCREMENT` bumped `dryrun_opcert_seq_no` and persisted
  `opcert_state.json` after every successful local forge. None were ever network-adopted, but each
  bumped the counter. The self-verify gate was added later; it then failed for any `seq ≥ 1` and
  aborted **before** the increment, freezing the counter at the last persisted value.
- **Precedence trap:** `opcert_state.json` (file) wins over `TSUNAGI_OPCERT_SEQ` (env) at boot
  (`producer.zig` opcert load). The launcher set `OPCERT_SEQ=0`, but the on-disk file (15) silently
  overrode it. Resetting the env var alone does nothing; the **file** must be reset.

---

## 7. Corrupted sigma evidence

Runtime (from `start-relay-forge.sh` / `tsunagi-auto.sh`):

```
TSUNAGI_OPCERT_SIGMA_HEX=28a969405cf5a6e2dae3acc354c2fa9d97959ef134802a735f229b4c2c055820190950f3eb0905909066d0c5525671bfc3017e165e704683e4ca26b7bbf2d167
```

This value is a **substring of the `node.cert` cborHex** — it begins at hex offset **152** (mid-sigma,
immediately after `…5997`) and runs to the **end** of the cborHex. It therefore concatenates:

```
[last 24 bytes of the real sigma] + [5820 CBOR byte-string tag] + [32-byte cold vkey]
```

The loader reads the first 64 bytes → `28a96940…`. That is **not** the opcert signature.

Offline ed25519 verification (against `cold_vk`, `msg = kes_root ‖ u64be(0) ‖ u64be(846)`):

```
VERIFY correct sigma (5e3c8839…) @ seq=0 => PASS
VERIFY corrupt sigma (28a96940…) @ seq=0 => FAIL   <- the live behavior
VERIFY correct sigma (5e3c8839…) @ seq=15 => FAIL  <- reproduces the seq-drift failure
```

The correct sigma was always present in `tsunagi-home-preview/forge.env` (`5e3c8839…`), which is why
historical slots `113163624`, `113310132` (the block broadcast 2026-05-28), `113336072` and others
logged `FORGE_SELF_VERIFY: pass=YES seq=0`. The **colo launcher** carried the corrupt slice.

---

## 8. Launcher corruption evidence (provenance)

The corrupt sigma had two in-repo-external sources, both on the relay:

- `/home/cardano/start-relay-forge.sh` — `export TSUNAGI_OPCERT_SIGMA_HEX=28a96940…d167`
- `/home/cardano/tsunagi-auto.sh` — `TSUNAGI_OPCERT_SIGMA_HEX=28a96940…d167 \`

The corruption is consistent with a manual byte-offset error when extracting the sigma out of the
`node.cert` cborHex by hand (selecting from the wrong start offset and running to the end of the
string, capturing the sigma tail + the trailing CBOR `5820` tag + the cold vkey).

---

## 9. Final resolution

1. **Seq:** reset `{TSUNAGI_HOME}/opcert_state.json` → `{"seq_no":0,"last_slot":0}`, restart (seq read
   once at boot).
2. **Sigma:** correct `TSUNAGI_OPCERT_SIGMA_HEX` in `start-relay-forge.sh` and `tsunagi-auto.sh` to the
   `node.cert` sigma `5e3c88392cb5e2d18b3042073ef5927b001541d7d446f93d7ddeb4fcbc76ac22599728a969405cf5a6e2dae3acc354c2fa9d97959ef134802a735f229b4c2c05`, restart.
3. **Durability (code):** the per-forge `OPCERT_INCREMENT` was the original drift cause. It is replaced
   by an **opcert counter pin** (`oc_new = oc_old`, logged as `OPCERT_PIN`) so the counter stays at the
   operator-issued cert value and never drifts again. Forged block bytes are unchanged (assembly reads
   the seq before the removed bump). Built on the deployed 0.15.2 lineage; mirrored on the Zig 0.16
   branch.

After (1) and (2), all five self-verify inputs match the certificate and verification succeeds
deterministically. (3) prevents the seq half of the fault from recurring.

---

## 10. Lessons learned

- **A passing-looking diagnosis can be incomplete.** The `FORGE_SELF_VERIFY_FAIL` line prints `seq`
  prominently, so the seq mismatch (15 vs 0) looked like the whole story. The corrupt sigma hid behind
  it until `sigma_first8` was pulled explicitly. Always compare **every** verify input against the
  certificate, not just the obvious one.
- **`opcert_state.json` (file) overrides `TSUNAGI_OPCERT_SEQ` (env).** Setting the env var is not
  enough; reset the file.
- **`TSUNAGI_OPCERT_SIGMA_HEX` has no file source — the launcher is authoritative.** A hand-edited
  launcher is a single point of corruption. Extract the sigma deterministically from `node.cert` (see
  `scripts/extract-opcert-sigma.py`), never by manual slicing.
- **`TSUNAGI_HOME` must be confirmed from the actual launcher**, not assumed. Here the live home was
  `…-colo`, while a stale `…-preview/opcert_state.json` had already (correctly but uselessly) been
  reset.
- **The runtime cannot re-sign the opcert.** The cold key signs the counter once; the node has no cold
  key, so it must never bump the counter on its own. The counter is pinned to the issued cert and only
  changes when the operator issues a new cert (KES rotation).
- **Self-verify earned its keep.** Refusing locally (no KES/opcert burn, no peer round-trip) turned a
  silent multi-hour orphan into an immediate, decodable diagnostic.

See also: `docs/operator/opcert-troubleshooting.md`, `docs/ACCEPTANCE_FRONTIER_STATUS.md`,
`scripts/extract-opcert-sigma.py`.
