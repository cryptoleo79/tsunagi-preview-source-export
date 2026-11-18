# TSUNAGI — Public Reveal Thread (Draft)

---

**Tweet 1 — Introduction**

Introducing TSUNAGI — an independent Cardano node written entirely in Zig.

Deterministic execution. Modular ledger pipeline. Runtime shadow verification. Zero garbage collection. Single static binary.

Built from the protocol specification, not from another implementation.

---

**Tweet 2 — Deterministic Architecture**

TSUNAGI's ledger pipeline is a deterministic state machine.

No global state. No environment coupling. Caller-provided allocators. Typed error returns.

Same inputs, same outputs — every time, on every machine.

Determinism isn't a goal. It's an invariant.

---

**Tweet 3 — Shadow Verification**

How do you verify a new ledger implementation safely?

Run two pipelines in parallel on every block. Compare after every application. Detect divergence within one block.

The shadow never touches the primary path. It only watches.

Zero mismatches across hundreds of blocks on preview.

---

**Tweet 4 — Observability Stack**

Four observability layers, each with a purpose:

KAGAMI (Mirror) — diagnostic snapshots
YAMORI (Guardian) — health evaluation
TATE (Shield) — fragment defense
KURA (Storehouse) — stabilization

Operators should understand their node from its own output.

---

**Tweet 5 — Whitepaper**

The full architecture, verification methodology, security model, and experimental validation are documented in the TSUNAGI whitepaper.

15 sections. 3 appendices. Grounded in measured results, not aspirations.

---

**Tweet 6 — Independent Implementation**

Cardano benefits from implementation diversity.

TSUNAGI is derived independently from the Ouroboros protocol specification. A second implementation confirms protocol assumptions, surfaces specification ambiguities, and strengthens network resilience.

Written in Zig. Built in Japan.

---

**Tweet 7 — Support**

TSUNAGI is developed independently. No Catalyst. No governance grants. No institutional funding.

If you want to support an independent Cardano node:

$tsunagi

Every contribution helps fund testing, research, and continued development.

---

⚠️ The TSUNAGI repository remains private while the architecture stabilizes.
