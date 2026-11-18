# TSUNAGI Visual Identity

This document defines the official visual representation of the TSUNAGI project. It serves as a design reference for documentation, diagrams, website materials, and any external communication that represents the project visually.

---

## 1. Project Name

**TSUNAGI (繋ぎ)**

TSUNAGI means "connection" or "bridge" in Japanese. The name reflects the project's role as a bridge between the Cardano protocol specification and a deterministic, independently derived node implementation. It also represents the connection between protocol correctness and operational clarity — linking the formal properties of a blockchain consensus system to the practical requirements of the operators who maintain it.

The name is always written in uppercase when used as the project identifier: **TSUNAGI**. The Japanese characters 繋ぎ may accompany the name in formal documentation and branding materials.

---

## 2. Motto

**Let It Run. Let It Resolve.**

The motto expresses the operational philosophy of the project: resilient infrastructure that prioritizes deterministic execution and autonomous recovery over manual intervention.

"Let It Run" reflects confidence in deterministic design. A system built on explicit state transitions, typed error propagation, and no hidden control flow can be trusted to operate continuously without constant supervision. The system earns the right to run unattended through architectural discipline, not through operator hope.

"Let It Resolve" reflects the self-healing capability embedded in the architecture. When degradation occurs, the system detects it through structured health evaluation, contains it through layered defense, and resolves it through automated stabilization — before human intervention is required. The operator's role is oversight, not life support.

The motto appears in the README, the manifesto, and the whitepaper closing. It should be rendered in bold when used in documentation.

---

## 3. Subsystem Names

The TSUNAGI architecture uses Japanese-inspired names for its operational layers. The naming theme follows protective infrastructure concepts — tools of defense, observation, and guardianship — reflecting each subsystem's role in maintaining node health and operational integrity.

| Subsystem | Characters | Meaning | Role |
|-----------|-----------|---------|------|
| **KAGAMI** | 鏡 | Mirror | Diagnostic mirror reflecting node state through structured snapshots, JSON telemetry, and real-time health reports |
| **YAMORI** | 家守 | House Guardian | Guardian monitor performing threshold-based health evaluation, maintaining event memory, and engaging defensive postures |
| **TATE** | 盾 | Shield | Fragment defense layer verifying propagation artifact integrity and ancestry continuity |
| **KURA** | 蔵 | Storehouse | Stabilization layer managing artifact retention, detecting staleness, and performing automated maintenance |
| **TSURUGI** | 剣 | Sword | Protocol engine implementing the Ouroboros node-to-node protocols: ChainSync and BlockFetch |

Note on YAMORI: The spelling 家守 ("house guardian") is intentionally used instead of the biological spelling 守宮 ("gecko"). In TSUNAGI, the term represents a guardian subsystem responsible for node health and integrity rather than the literal animal name.

---

## 4. Visual Architecture Diagram

The primary architecture diagram is located at:

```
docs/public/images/tsunagi-architecture.jpg
```

This diagram illustrates the complete TSUNAGI node architecture as a vertical layered stack, showing:

- The observability subsystems (KAGAMI, YAMORI, TATE, KURA) at the top, representing the diagnostic and self-healing layers
- The TSURUGI protocol engine in the middle, representing the network-facing protocol implementation
- The deterministic ledger pipeline below, representing the state machine that processes block deltas
- The LMDB persistent storage at the base, representing durable UTxO state

The diagram is referenced in the whitepaper as Figure 1 and in the public overview documentation. It should be used as the canonical visual representation of the TSUNAGI architecture in all external materials.

---

## 5. Diagram Style Guidelines

All TSUNAGI architectural diagrams should follow a consistent visual style to maintain readability and project identity across documentation and presentations.

**Background.** Dark or black background. Diagrams are designed to be read in terminal environments and dark-mode documentation renderers. Light backgrounds may be used for print materials but dark is the default.

**Colors.** Minimal color palette. Architecture lines and box borders in silver or white. Text labels in white or light gray. Accent colors used sparingly to distinguish subsystem boundaries — never for decoration.

**Layout.** Layered vertical architecture with clear top-to-bottom flow. Each subsystem occupies a distinct horizontal band. Connections between layers are represented by vertical lines or arrows. No diagonal connections, no circular layouts, no overlapping elements.

**Terminal compatibility.** ASCII diagram versions should be maintained alongside graphical versions for inclusion in markdown documentation, terminal output, and plain-text contexts. ASCII diagrams use box-drawing characters (┌ ┐ └ ┘ │ ─ ┬ ┴ ├ ┤ ▼) and are indented consistently.

**Subsystem boundaries.** Each subsystem is enclosed in a distinct box with its Japanese name and English description. Boxes are uniformly sized within a diagram. Labels are centered within boxes.

**Consistency.** The same subsystem ordering (KAGAMI → YAMORI → TATE → KURA → TSURUGI → Ledger → LMDB) should be maintained across all diagrams unless a specific diagram intentionally highlights a different relationship.

---

## 6. Logo Philosophy

The TSUNAGI logo represents the concept of connection — the bridge between protocol and implementation, between specification and operation, between the formal and the practical.

The arc form in the logo symbolizes the bridge metaphor embedded in the project name. It suggests continuity, structural integrity, and the spanning of a gap. The arc connects two points that could not reach each other without the bridge between them, mirroring the project's role in connecting the Cardano protocol specification to an independent, deterministic implementation.

The logo is minimal by design. Infrastructure software is defined by what it does reliably, not by what it displays prominently. The visual identity reflects this: clean lines, no embellishment, and a form that communicates structural purpose rather than decorative intent.

The logo file is located at:

```
docs/assets/logo/tsunagi-logo-dark.png
```

---

## 7. Color Theme

The TSUNAGI visual identity uses a restrained color palette that reflects the project's emphasis on clarity, precision, and operational sobriety.

**Primary background:** Deep navy (#0a0e1a or similar). Used for diagram backgrounds, presentation slides, and dark-mode documentation contexts. The dark background reduces visual noise and places emphasis on structural content.

**Architecture lines:** Silver or white (#c0c0c0 to #ffffff). Used for box borders, connection lines, and structural elements in diagrams. High contrast against the dark background ensures readability in both screen and print contexts.

**Text:** White (#ffffff) for primary labels and headings. Light gray (#a0a0a0) for secondary annotations and descriptions. No colored text unless used to distinguish specific subsystem categories.

**Accent (reserved):** A single accent color may be introduced for highlighting active states, alerts, or emphasis in interactive contexts. This accent color has not been defined and should be chosen with restraint when the need arises. It should complement the navy-and-silver palette without introducing visual competition.

The color theme applies to diagrams, presentation materials, documentation headers, and any visual content that represents the TSUNAGI project. Code listings and terminal output retain their native formatting and are not styled to match the color theme.
