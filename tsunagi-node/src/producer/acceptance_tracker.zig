// ============================================================================
// ARCHITECTURAL INVARIANT — DO NOT VIOLATE
//
// Koios is NOT consensus.
// Koios is an EXTERNAL CANONICAL WITNESS used ONLY for tie-breaking during
// explicit local divergence between applied_tip and rx_layer.
//
// The FCC (Forge-Time Canonicality Convergence) path:
//   - Activates ONLY during explicit Stage-2 hash mismatch
//   - Requires EXACT 32-byte canonical hash equality
//   - Refuses on ANY uncertainty
//   - NEVER overrides ancestry gates
//   - NEVER bypasses freshness
//   - NEVER weakens KES/opcert/sigma validation
//   - NEVER performs probabilistic weighting
//
// If Koios is stale, unreachable, or ambiguous, the system falls back to
// existing conservative refusal behavior. Loss of Koios must NEVER cause
// unsafe forging — only conservative refusal.
// ============================================================================
//
// Acceptance tracker — classifies forged blocks against the canonical chain
// observed via Koios.
//
// Pipeline:
//   1. Producer calls registerForge(slot, block_no, hash) immediately after
//      FORGE_PROMOTE_ATOMIC.
//   2. A background poller (spawnPoller) refreshes the canonical view every
//      ~30s by curl'ing Koios:
//          GET /api/v1/pool_blocks?_pool_bech32=<our_pool>
//          GET /api/v1/tip
//   3. A reconciler thread runs every 5s, walks live forge records, and
//      transitions states. Terminal states are `canonical` (WIN) and
//      `orphaned` (LOSS). Records that exceed a 600s budget without a
//      canonical match transition to `unknown`.
//
// Every state transition emits a single line to stdout:
//   ACCEPTANCE_VERDICT: forge_slot=S forge_block=N forge_hash=H
//     prev_state=X new_state=Y confidence=W elapsed_s=T
//
// Standalone module — nothing else in the tree imports it yet. Wiring is
// done by the producer (see suggested integration point at bottom of file).

const std = @import("std");
const compat = @import("compat");
const shutdown = @import("../ops/shutdown.zig");

// ─── Types ─────────────────────────────────────────────────────────────

pub const ForgeState = enum {
    forged,        // just registered
    pending,       // waiting for first Koios refresh
    arrived,       // observed somewhere in pool_blocks at our block_no
    local_valid,   // our hash present in pool_blocks but not yet >=2 confirmations
    canonical,     // TERMINAL — WIN: hash on canonical chain with confirmations
    orphaned,      // TERMINAL — LOSS: different hash at same block_no with confirmations
    fork_local,    // our hash visible but a competing hash also visible at same block_no
    unknown,       // TERMINAL — gave up after timeout
};

pub const ForgeRecord = struct {
    forge_slot: u64,
    forge_block_no: u64,
    forge_hash: [32]u8,
    forged_unix: i64,
    state: ForgeState,
    state_changed_unix: i64,
    confidence_weight: u32,
    last_koios_check_unix: i64,
};

pub const CanonicalBlock = struct {
    block_hash: [32]u8,
    block_no: u64,
    abs_slot: u64,
    epoch_no: u64,
    last_seen_unix: i64,
};

// ─── FCC: Canonical history ring ─────────────────────────────────────
// Short-window canonical hash record for forge-time tie-breaking.
// Populated by a low-cadence Koios /blocks?order=block_height.desc&limit=64
// fetch. NEVER consulted outside selectFreshestParent's Stage-2 mismatch
// path. NEVER consensus. Witness only.

pub const CanonicalEntry = struct {
    block_no: u64,
    slot: u64,
    hash: [32]u8,
    fetched_unix: i64,
};

// ─── Globals ──────────────────────────────────────────────────────────

pub var g_forge_records: std.array_list.Managed(ForgeRecord) = undefined;
pub var g_records_mu: compat.Mutex = .{};

pub var g_canonical_pool_blocks: std.array_list.Managed(CanonicalBlock) = undefined;
pub var g_canonical_mu: compat.Mutex = .{};

pub var g_canonical_tip_block_no: u64 = 0;
pub var g_canonical_tip_unix: i64 = 0;
pub var g_canonical_tip_abs_slot: u64 = 0;
/// Source of the most recent canonical tip update. "koios" | "cardano_cli" | "none".
pub var g_canonical_tip_source_buf: [16]u8 = [_]u8{0} ** 16;
pub var g_canonical_tip_source_len: usize = 4;

// ─── FCC globals ─────────────────────────────────────────────────────
const CANONICAL_HISTORY_DEPTH: usize = 64;
var g_canonical_history: [CANONICAL_HISTORY_DEPTH]CanonicalEntry = [_]CanonicalEntry{.{
    .block_no = 0,
    .slot = 0,
    .hash = [_]u8{0} ** 32,
    .fetched_unix = 0,
}} ** CANONICAL_HISTORY_DEPTH;
var g_canonical_history_count: usize = 0;
var g_canonical_history_last_refresh_unix: i64 = 0;
var g_canonical_history_mutex: compat.Mutex = .{};

// ─── FCC diagnostic instrumentation (pure observability, no semantics) ─
// These fields expose ring rebuild metadata at consult time so an operator
// can correlate refresh events with consultation events and disambiguate:
//   (1) ring snapshot vs consult snapshot divergence
//   (2) walk truncation (header_store gap) vs full walk
//   (3) ring coverage window vs applied_tip.block_no at consult time
//   (4) ring contents around the target block_no (forensic context)
// Updated atomically with the ring under g_canonical_history_mutex.
var g_canonical_history_generation: u64 = 0;
var g_canonical_history_head_anchor: [32]u8 = [_]u8{0} ** 32;
var g_canonical_history_walk_len: usize = 0;

pub const FccDiagWindow = struct {
    /// Up to 5 entries from the ring centered around target_block_no, in
    /// ring-order (not sorted). block_no=0 marks unused slots in the
    /// returned array. count is the actual number of populated entries.
    entries: [5]CanonicalEntry,
    count: usize,
};

pub const FccDiagSnapshot = struct {
    generation: u64,
    refresh_unix: i64,
    freshness_s: i64,
    ring_count: usize,
    walk_len: usize,           // Entries actually traversed before break;
                               //   < ring_count would indicate the ring
                               //   contains stale entries from a prior walk.
    newest_block: u64,
    oldest_block: u64,
    head_anchor: [32]u8,       // Hash where last walk started (cardano-node
                               //   HEAD at walk time).
    target_hit: bool,          // True iff target_block_no found in ring.
    target_hash: [32]u8,       // Populated iff target_hit (else zeros).
    target_slot: u64,          // Populated iff target_hit (else 0).
    window: FccDiagWindow,     // Up to 5 entries around target_block_no.
};

/// Atomic forensic snapshot of the ring + lookup outcome for target_block_no.
/// Single mutex acquisition; no race between "lookup" and "diagnostic".
pub fn getDiagnosticSnapshot(target_block_no: u64) FccDiagSnapshot {
    g_canonical_history_mutex.lock();
    defer g_canonical_history_mutex.unlock();

    var snap = FccDiagSnapshot{
        .generation = g_canonical_history_generation,
        .refresh_unix = g_canonical_history_last_refresh_unix,
        .freshness_s = if (g_canonical_history_last_refresh_unix == 0)
            std.math.maxInt(i64)
        else
            compat.timestamp() - g_canonical_history_last_refresh_unix,
        .ring_count = g_canonical_history_count,
        .walk_len = g_canonical_history_walk_len,
        .newest_block = if (g_canonical_history_count > 0) g_canonical_history[0].block_no else 0,
        .oldest_block = if (g_canonical_history_count > 0) g_canonical_history[g_canonical_history_count - 1].block_no else 0,
        .head_anchor = g_canonical_history_head_anchor,
        .target_hit = false,
        .target_hash = [_]u8{0} ** 32,
        .target_slot = 0,
        .window = .{ .entries = [_]CanonicalEntry{.{
            .block_no = 0,
            .slot = 0,
            .hash = [_]u8{0} ** 32,
            .fetched_unix = 0,
        }} ** 5, .count = 0 },
    };

    // Linear scan for target + collect ring-order window of up to 5 entries
    // whose block_no is within ±2 of target_block_no for forensic context.
    var i: usize = 0;
    var found_idx: ?usize = null;
    while (i < g_canonical_history_count and i < CANONICAL_HISTORY_DEPTH) : (i += 1) {
        if (g_canonical_history[i].block_no == target_block_no and !snap.target_hit) {
            snap.target_hit = true;
            snap.target_hash = g_canonical_history[i].hash;
            snap.target_slot = g_canonical_history[i].slot;
            found_idx = i;
        }
    }

    // Populate window: entries near target_block_no in ring order.
    if (found_idx) |fi| {
        const start = if (fi >= 2) fi - 2 else 0;
        const end = @min(start + 5, g_canonical_history_count);
        var w: usize = 0;
        var j: usize = start;
        while (j < end and w < 5) : ({ j += 1; w += 1; }) {
            snap.window.entries[w] = g_canonical_history[j];
        }
        snap.window.count = w;
    } else {
        // Target not found — show first 5 entries instead so we see what
        // the ring DOES contain.
        var w: usize = 0;
        while (w < @min(@as(usize, 5), g_canonical_history_count)) : (w += 1) {
            snap.window.entries[w] = g_canonical_history[w];
        }
        snap.window.count = w;
    }

    return snap;
}

// Tunable for tests: when set non-null, getCanonicalHashForBlock /
// getCanonicalSlotForBlock / historyFreshness use these injected values
// instead of the live ring. Only the unit-test path touches this.
const TestOverride = struct {
    block_no: u64,
    slot: u64,
    hash: [32]u8,
    freshness_s: i64,
};
var g_test_override: ?TestOverride = null;

var g_initialized: bool = false;
var g_pool_bech32_buf: [128]u8 = undefined;
var g_pool_bech32_len: usize = 0;
var g_alloc: std.mem.Allocator = undefined;

// Tunables
// Separate cadences: tip is small and changes every ~20s of chain time; pool_blocks
// is large (1 MiB+ for established pools) and changes only on confirmation. Lower
// cadences keep us well under Koios free-tier limits even with shared-IP throttling.
const TIP_INTERVAL_S: i64 = 60;
const POOL_BLOCKS_INTERVAL_S: i64 = 180;
const POLL_INTERVAL_S: i64 = TIP_INTERVAL_S; // legacy alias for log message
const RECONCILE_INTERVAL_MS: u64 = 5_000;
const ACCEPTANCE_TIMEOUT_S: i64 = 600;
const CONFIRMATIONS_REQUIRED: u64 = 2;
const MAX_FORGE_RECORDS: usize = 4096;
const MAX_CANONICAL_BLOCKS: usize = 8192;
const KOIOS_BASE_DEFAULT = "https://preview.koios.rest";
const RESPONSE_BUF_SIZE: usize = 1 << 20; // 1 MiB

// FCC: canonical history polling cadence. Same as tip cadence so we
// piggyback on the existing rate-limit-aware backoff infrastructure.
const CANONICAL_HISTORY_INTERVAL_S: i64 = 60;
const CANONICAL_HISTORY_RESP_BUF_SIZE: usize = 64 * 1024; // ~1 KiB/entry × 64 ample

// Backoff: exponential with cap + jitter. 429 from Koios gets longer cap.
const BACKOFF_MIN_S: i64 = 30;
const BACKOFF_MAX_S: i64 = 600;
const BACKOFF_429_FLOOR_S: i64 = 60;

// ─── Initialization ───────────────────────────────────────────────────

fn ensureInit(alloc: std.mem.Allocator) void {
    if (g_initialized) return;
    g_alloc = alloc;
    g_forge_records = std.array_list.Managed(ForgeRecord).init(alloc);
    g_canonical_pool_blocks = std.array_list.Managed(CanonicalBlock).init(alloc);
    g_initialized = true;
}

fn koiosBase() []const u8 {
    if (compat.getenv("TSUNAGI_KOIOS_BASE")) |b| {
        if (b.len > 0) return b;
    }
    return KOIOS_BASE_DEFAULT;
}

// ─── Public API ───────────────────────────────────────────────────────

/// Spawn the Koios poller and the reconciler. Returns true on success.
pub fn spawnPoller(alloc: std.mem.Allocator, pool_bech32: []const u8) bool {
    ensureInit(alloc);
    if (pool_bech32.len == 0 or pool_bech32.len > g_pool_bech32_buf.len) {
        std.debug.print("ACCEPTANCE_SPAWN: bad pool_bech32 len={d}\n", .{pool_bech32.len});
        return false;
    }
    @memcpy(g_pool_bech32_buf[0..pool_bech32.len], pool_bech32);
    g_pool_bech32_len = pool_bech32.len;

    const t1 = std.Thread.spawn(.{}, pollerLoop, .{}) catch {
        std.debug.print("ACCEPTANCE_SPAWN: poller thread spawn failed\n", .{});
        return false;
    };
    t1.detach();

    const t2 = std.Thread.spawn(.{}, reconcilerLoop, .{}) catch {
        std.debug.print("ACCEPTANCE_SPAWN: reconciler thread spawn failed\n", .{});
        return false;
    };
    t2.detach();

    std.debug.print("ACCEPTANCE_SPAWN: ready pool={s} poll_s={d} reconcile_ms={d} timeout_s={d}\n", .{
        pool_bech32, POLL_INTERVAL_S, RECONCILE_INTERVAL_MS, ACCEPTANCE_TIMEOUT_S,
    });
    return true;
}

/// Producer calls this immediately after FORGE_PROMOTE_ATOMIC.
pub fn registerForge(slot: u64, block_no: u64, hash: [32]u8) void {
    if (!g_initialized) {
        // Allocator-free safety: caller spawned poller? If not, refuse.
        std.debug.print("ACCEPTANCE_REGISTER: not initialized — drop slot={d}\n", .{slot});
        return;
    }
    const now = compat.timestamp();
    const rec = ForgeRecord{
        .forge_slot = slot,
        .forge_block_no = block_no,
        .forge_hash = hash,
        .forged_unix = now,
        .state = .forged,
        .state_changed_unix = now,
        .confidence_weight = 0,
        .last_koios_check_unix = 0,
    };

    g_records_mu.lock();
    defer g_records_mu.unlock();

    // Dedup: ignore if same (slot, hash) already present.
    for (g_forge_records.items) |r| {
        if (r.forge_slot == slot and std.mem.eql(u8, &r.forge_hash, &hash)) {
            return;
        }
    }
    if (g_forge_records.items.len >= MAX_FORGE_RECORDS) {
        // Drop oldest non-terminal record to bound memory.
        var i: usize = 0;
        while (i < g_forge_records.items.len) : (i += 1) {
            const s = g_forge_records.items[i].state;
            if (s == .canonical or s == .orphaned or s == .unknown) {
                _ = g_forge_records.orderedRemove(i);
                break;
            }
        }
    }
    g_forge_records.append(rec) catch {
        std.debug.print("ACCEPTANCE_REGISTER: append failed slot={d}\n", .{slot});
        return;
    };
    std.debug.print("ACCEPTANCE_REGISTER: slot={d} block_no={d} hash={s}\n", .{
        slot, block_no, std.fmt.bytesToHex(hash[0..8], .lower),
    });
}

/// Phase 3: orphan watchdog Koios-confirmation gate.
/// Returns whether Koios's pool_blocks list contains the given hash.
///   .found     — hash is present in canonical pool_blocks (we won)
///   .not_found — pool_blocks data is fresh AND hash is absent (we lost)
///   .unknown   — Koios data is missing or stale; caller should defer
pub const KoiosHashStatus = enum { found, not_found, unknown };

pub fn koiosKnowsHash(hash: [32]u8) KoiosHashStatus {
    g_canonical_mu.lock();
    defer g_canonical_mu.unlock();

    // If we never received any Koios data, we cannot answer.
    if (g_canonical_tip_unix == 0) return .unknown;

    // If the most recent Koios poll is stale (>120s), we cannot answer authoritatively.
    const age = compat.timestamp() - g_canonical_tip_unix;
    if (age > 120) return .unknown;

    for (g_canonical_pool_blocks.items) |b| {
        if (std.mem.eql(u8, &b.block_hash, &hash)) return .found;
    }
    return .not_found;
}

/// Read-only snapshot of a record's current state (looked up by slot).
pub fn classifyForge(forge_slot: u64) ForgeState {
    g_records_mu.lock();
    defer g_records_mu.unlock();
    for (g_forge_records.items) |r| {
        if (r.forge_slot == forge_slot) return r.state;
    }
    return .unknown;
}

// ─── FCC accessors ───────────────────────────────────────────────────
// Forge-time canonicality consultation. Read-only. Witness only — NEVER
// consensus. Returns null on miss; caller MUST treat null as "no signal,
// fall back to existing refusal behavior".

pub fn getCanonicalHashForBlock(block_no: u64) ?[32]u8 {
    if (g_test_override) |ov| {
        if (ov.block_no == block_no) return ov.hash;
        return null;
    }
    g_canonical_history_mutex.lock();
    defer g_canonical_history_mutex.unlock();
    var i: usize = 0;
    while (i < g_canonical_history_count and i < CANONICAL_HISTORY_DEPTH) : (i += 1) {
        if (g_canonical_history[i].block_no == block_no) {
            return g_canonical_history[i].hash;
        }
    }
    return null;
}

pub fn getCanonicalSlotForBlock(block_no: u64) ?u64 {
    if (g_test_override) |ov| {
        if (ov.block_no == block_no) return ov.slot;
        return null;
    }
    g_canonical_history_mutex.lock();
    defer g_canonical_history_mutex.unlock();
    var i: usize = 0;
    while (i < g_canonical_history_count and i < CANONICAL_HISTORY_DEPTH) : (i += 1) {
        if (g_canonical_history[i].block_no == block_no) {
            return g_canonical_history[i].slot;
        }
    }
    return null;
}

/// Returns seconds since the most recent successful canonical-history
/// refresh. Returns a large sentinel (i64.max) if no refresh has ever
/// succeeded, so callers reading "freshness > 90s" trip safe-refuse.
pub fn historyFreshness() i64 {
    if (g_test_override) |ov| return ov.freshness_s;
    g_canonical_history_mutex.lock();
    defer g_canonical_history_mutex.unlock();
    if (g_canonical_history_last_refresh_unix == 0) return std.math.maxInt(i64);
    return compat.timestamp() - g_canonical_history_last_refresh_unix;
}

// Test-only injection. Production code never sets this.
pub fn _setTestOverride(block_no: u64, slot: u64, hash: [32]u8, freshness_s: i64) void {
    g_test_override = .{ .block_no = block_no, .slot = slot, .hash = hash, .freshness_s = freshness_s };
}
pub fn _clearTestOverride() void {
    g_test_override = null;
}

/// Dump a JSON-ish status line list to writer.
pub fn dumpStatus(writer: anytype) void {
    g_records_mu.lock();
    defer g_records_mu.unlock();
    g_canonical_mu.lock();
    defer g_canonical_mu.unlock();

    writer.print("{{\"canonical_tip_block_no\":{d},\"canonical_tip_abs_slot\":{d},\"canonical_tip_unix\":{d},\"pool_blocks\":{d},\"forge_records\":[", .{
        g_canonical_tip_block_no,
        g_canonical_tip_abs_slot,
        g_canonical_tip_unix,
        g_canonical_pool_blocks.items.len,
    }) catch return;

    for (g_forge_records.items, 0..) |r, i| {
        const sep: []const u8 = if (i == 0) "" else ",";
        writer.print(
            "{s}{{\"slot\":{d},\"block_no\":{d},\"hash\":\"{s}\",\"state\":\"{s}\",\"confidence\":{d},\"elapsed_s\":{d}}}",
            .{
                sep,
                r.forge_slot,
                r.forge_block_no,
                std.fmt.bytesToHex(r.forge_hash[0..8], .lower),
                @tagName(r.state),
                r.confidence_weight,
                compat.timestamp() - r.forged_unix,
            },
        ) catch return;
    }
    writer.print("]}}\n", .{}) catch return;
}

// ─── Poller (Koios) ───────────────────────────────────────────────────

fn pollerLoop() void {
    // Stagger initial fetch so we don't race spawn-time logs.
    compat.sleep(2 * std.time.ns_per_s);

    // Tip and pool_blocks have separate backoff state because they serve
    // different roles. Tip feeds FORGE_GATE_CANONICAL_LAG (gate-critical;
    // failure could block forge). pool_blocks feeds ACCEPTANCE_VERDICT
    // classification (post-forge confirmation; degraded operation is OK).
    // Sharing a counter conflates pool 429 noise with tip outages.
    var last_tip_attempt_ts: i64 = 0;
    var last_pool_attempt_ts: i64 = 0;
    // Stagger FCC history first poll 30s after tip poll to avoid
    // concurrent Koios request collisions on shared-IP rate-limiting.
    // Initialized to current time MINUS (interval - stagger_offset) so
    // first attempt fires at stagger_offset seconds, not immediately.
    const fcc_history_stagger_offset_s: i64 = 30;
    var last_history_attempt_ts: i64 = compat.timestamp() - (CANONICAL_HISTORY_INTERVAL_S - fcc_history_stagger_offset_s);
    var backoff_tip_s: i64 = 0;
    var backoff_pool_s: i64 = 0;
    var backoff_history_s: i64 = 0;
    var consec_fail_tip: u32 = 0;
    var consec_fail_pool: u32 = 0;
    var consec_fail_history: u32 = 0;
    var prng = std.Random.DefaultPrng.init(@intCast(compat.timestamp()));
    const rnd = prng.random();

    while (true) {
        if (shutdown.stopRequested()) return;
        const now = compat.timestamp();

        // ─── TIP path (gate-critical) ─────────────────────────────────
        if (now - last_tip_attempt_ts >= TIP_INTERVAL_S + backoff_tip_s) {
            last_tip_attempt_ts = now;
            if (fetchTipWithFallback()) {
                if (consec_fail_tip > 0) {
                    std.debug.print("ACCEPTANCE_BACKOFF: kind=tip recovered after fail={d}\n", .{consec_fail_tip});
                    consec_fail_tip = 0;
                    backoff_tip_s = 0;
                }
            } else |e| {
                consec_fail_tip += 1;
                const is_429 = (e == error.RateLimited);
                const floor: i64 = if (is_429) BACKOFF_429_FLOOR_S else BACKOFF_MIN_S;
                const doubled: i64 = if (backoff_tip_s == 0) floor else backoff_tip_s * 2;
                backoff_tip_s = @min(BACKOFF_MAX_S, @max(floor, doubled));
                std.debug.print("ACCEPTANCE_POLL_ERR: kind=tip {s} consec_fail={d} next_backoff_s={d}\n", .{
                    @errorName(e), consec_fail_tip, backoff_tip_s,
                });
            }
        }

        // ─── FCC HISTORY path (forge-time canonicality consultation) ──
        // Witness-only role. Failure does NOT block forge; it only degrades
        // FCC's ability to tie-break — selectFreshestParent falls back to
        // existing conservative refusal when history is stale (>90s old).
        if (now - last_history_attempt_ts >= CANONICAL_HISTORY_INTERVAL_S + backoff_history_s) {
            last_history_attempt_ts = now;
            // TIER 1: local header_store chain-walk. No network, always
            // authoritative from cardano-node's view, microsecond latency.
            // Try first on every poll; Koios is only used if local fails.
            const local_ok = blk: {
                fetchCanonicalHistoryLocal() catch |e| {
                    // Don't spam — local failure is expected during cold
                    // start before header_store is wired. Log once per N.
                    if (consec_fail_history % 30 == 0) {
                        std.debug.print("FCC_HISTORY_LOCAL_FAIL: {s} (will try TIER 2 Koios)\n", .{@errorName(e)});
                    }
                    break :blk false;
                };
                break :blk true;
            };
            if (local_ok) {
                if (consec_fail_history > 0) {
                    std.debug.print("FCC_HISTORY_RECOVERED: source=local_header_store after fail={d}\n", .{consec_fail_history});
                    consec_fail_history = 0;
                    backoff_history_s = 0;
                }
            } else if (fetchCanonicalHistory()) {
                // TIER 2 success — Koios.
                if (consec_fail_history > 0) {
                    std.debug.print("FCC_HISTORY_RECOVERED: source=koios after fail={d}\n", .{consec_fail_history});
                    consec_fail_history = 0;
                    backoff_history_s = 0;
                }
            } else |e| {
                consec_fail_history += 1;
                const is_429 = (e == error.RateLimited);
                const floor: i64 = if (is_429) BACKOFF_429_FLOOR_S else BACKOFF_MIN_S;
                const doubled: i64 = if (backoff_history_s == 0) floor else backoff_history_s * 2;
                backoff_history_s = @min(BACKOFF_MAX_S, @max(floor, doubled));
                std.debug.print("FCC_HISTORY_ERR: tier1=local_unavailable tier2_koios={s} consec_fail={d} next_backoff_s={d}\n", .{
                    @errorName(e), consec_fail_history, backoff_history_s,
                });
            }
        }

        // ─── POOL_BLOCKS path (verdict-relevant, not gate-critical) ───
        if (now - last_pool_attempt_ts >= POOL_BLOCKS_INTERVAL_S + backoff_pool_s) {
            last_pool_attempt_ts = now;
            if (fetchPoolBlocks()) {
                if (consec_fail_pool > 0) {
                    std.debug.print("ACCEPTANCE_POOL_RECOVERED: after fail={d}\n", .{consec_fail_pool});
                    consec_fail_pool = 0;
                    backoff_pool_s = 0;
                }
            } else |e| {
                consec_fail_pool += 1;
                const is_429 = (e == error.RateLimited);
                const floor: i64 = if (is_429) BACKOFF_429_FLOOR_S else BACKOFF_MIN_S;
                const doubled: i64 = if (backoff_pool_s == 0) floor else backoff_pool_s * 2;
                backoff_pool_s = @min(BACKOFF_MAX_S, @max(floor, doubled));
                // Quieter log class — pool_blocks degradation does not block
                // forge. Logged at lower visibility so operator focus stays
                // on tip health.
                std.debug.print("ACCEPTANCE_POOL_DEGRADED: {s} consec_fail={d} next_backoff_s={d}\n", .{
                    @errorName(e), consec_fail_pool, backoff_pool_s,
                });
            }
        }

        const jitter: i64 = rnd.intRangeAtMost(i64, -3, 3);
        const sleep_s: u64 = @intCast(@max(@as(i64, 1), 10 + jitter));
        compat.sleep(sleep_s * std.time.ns_per_s);
    }
}

/// Try Koios first; on RateLimited or any other error, fall back to local
/// cardano-cli (authoritative for our peer-graph). If neither path succeeds,
/// returns the Koios error so the caller can backoff.
fn fetchTipWithFallback() !void {
    fetchTip() catch |e| {
        // Try cardano-cli fallback if configured.
        if (compat.getenv("TSUNAGI_CARDANO_NODE_SOCKET")) |_| {
            fetchTipViaCardanoCli() catch |e2| {
                std.debug.print("ACCEPTANCE_FALLBACK_ERR: kind=cardano_cli {s} (koios_err={s})\n", .{
                    @errorName(e2), @errorName(e),
                });
                return e;
            };
            return;
        }
        return e;
    };
}

/// Fallback canonical-tip fetcher via local cardano-node socket. Uses
/// cardano-cli query tip --testnet-magic <N> --socket-path <S>. Authoritative
/// for our peer-graph's view of canonical; independent of Koios uptime.
fn fetchTipViaCardanoCli() !void {
    const socket = compat.getenv("TSUNAGI_CARDANO_NODE_SOCKET") orelse return error.NoSocket;
    const cli = compat.getenv("TSUNAGI_CARDANO_CLI") orelse "cardano-cli";
    const magic = compat.getenv("TSUNAGI_TESTNET_MAGIC") orelse "2";

    const argv = [_][]const u8{ cli, "query", "tip", "--testnet-magic", magic, "--socket-path", socket };

    var resp_buf: [4096]u8 = undefined;
    // 0.16 removed std.process.Child.init + manual Pipe/Ignore/spawn/readAll/wait.
    // compat.runCaptureStdout preserves that exact flow: spawns with stdout=Pipe,
    // stderr=Ignore, reads stdout into resp_buf, waits, and returns the stdout
    // slice (or null on spawn/read failure, non-zero exit, or empty stdout).
    const body = compat.runCaptureStdout(g_alloc, &argv, &resp_buf) orelse return error.CardanoCliNonZero;
    const block_no = parseUintField(body, "\"block\":") orelse return error.NoBlockNo;
    const abs_slot = parseUintField(body, "\"slot\":") orelse 0;

    g_canonical_mu.lock();
    defer g_canonical_mu.unlock();
    g_canonical_tip_block_no = block_no;
    g_canonical_tip_abs_slot = abs_slot;
    g_canonical_tip_unix = compat.timestamp();
    const src = "cardano_cli";
    @memcpy(g_canonical_tip_source_buf[0..src.len], src);
    g_canonical_tip_source_len = src.len;
    std.debug.print("ACCEPTANCE_POLL: source=cardano_cli canonical_tip_block_no={d} abs_slot={d}\n", .{
        block_no, abs_slot,
    });
}

fn fetchTip() !void {
    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}/api/v1/tip", .{koiosBase()});

    var resp_buf: [4096]u8 = undefined;
    const r = try curlGet(url, &resp_buf);
    if (r.http_code == 429) return error.RateLimited;
    if (r.http_code != 200) return error.HttpError;
    if (r.len == 0) return error.EmptyResponse;
    const body = resp_buf[0..r.len];

    // Response is a JSON array: [{"hash":"...","epoch_no":N,"abs_slot":S,"block_no":B,...}]
    const block_no = parseUintField(body, "\"block_no\":") orelse return error.NoBlockNo;
    const abs_slot = parseUintField(body, "\"abs_slot\":") orelse 0;

    g_canonical_mu.lock();
    defer g_canonical_mu.unlock();
    g_canonical_tip_block_no = block_no;
    g_canonical_tip_abs_slot = abs_slot;
    g_canonical_tip_unix = compat.timestamp();
    const src = "koios";
    @memcpy(g_canonical_tip_source_buf[0..src.len], src);
    g_canonical_tip_source_len = src.len;
}

// ─── FCC: canonical history fetch — LOCAL (header_store chain-walk) ──
// TIER 1 source: walks the local LMDB header_store backwards from
// cardano-node's current HEAD. Each step is an O(1) LMDB hash lookup
// keyed by prev_hash. Builds the same (block_no, slot, hash) ring as
// the Koios path but without ANY network dependency. Authoritative
// from cardano-node's perspective — header_store contains exactly the
// chain cardano-node has validated and applied.
//
// Eliminates Koios outbound as a single point of FCC blindness. After
// the 2026-05-15 slot 112191691 incident (acceptance_tracker stale 8241s
// due to host-side curl/Koios degradation), this becomes the primary
// canonical-history source. Koios remains as TIER 2 fallback.
//
// Returns error.NoHeaderStore if global pointer not yet wired.
// Returns error.NoHead if header_store has no HEAD yet (cold start).
// Returns success and populates ring if at least 1 step succeeds.
fn fetchCanonicalHistoryLocal() !void {
    const http_metrics = @import("../net/metrics/http_metrics.zig");
    const hs_ptr = http_metrics.g_header_store orelse return error.NoHeaderStore;

    var rtxn = hs_ptr.beginRead() orelse return error.HeaderStoreTxnFailed;
    defer hs_ptr.abort(&rtxn);

    const head_hash = hs_ptr.getHead(&rtxn) orelse return error.NoHead;

    const now = compat.timestamp();
    var current_hash = head_hash;
    var count: usize = 0;

    g_canonical_history_mutex.lock();
    defer g_canonical_history_mutex.unlock();

    while (count < CANONICAL_HISTORY_DEPTH) {
        const rec = hs_ptr.getHeader(&rtxn, current_hash) orelse break;
        g_canonical_history[count] = .{
            .block_no = rec.block_no,
            .slot = rec.slot,
            .hash = current_hash,
            .fetched_unix = now,
        };
        count += 1;
        // Genesis sentinel: prev_hash all zeros means we hit the chain
        // origin (genesis block has no predecessor). Stop walking.
        if (std.mem.allEqual(u8, &rec.prev_hash, 0)) break;
        current_hash = rec.prev_hash;
    }

    if (count == 0) return error.EmptyWalk;

    g_canonical_history_count = count;
    g_canonical_history_last_refresh_unix = now;
    // Diagnostic metadata — captured atomically with ring contents under
    // the same mutex. Lets operator correlate refresh events with consult
    // events and detect walk truncation (count < DEPTH ⇒ header_store gap
    // hit during traversal).
    g_canonical_history_generation += 1;
    g_canonical_history_head_anchor = head_hash;
    g_canonical_history_walk_len = count;

    std.debug.print("FCC_HISTORY_REFRESH: source=local_header_store gen={d} entries={d} walk_len={d} newest_block={d} oldest_block={d} head_anchor_first8={s}\n", .{
        g_canonical_history_generation,
        count,
        g_canonical_history_walk_len,
        g_canonical_history[0].block_no,
        g_canonical_history[count - 1].block_no,
        std.fmt.bytesToHex(head_hash[0..8], .lower),
    });
}

// ─── FCC: canonical history fetch — KOIOS (TIER 2 fallback) ──────────
// GET /api/v1/blocks?order=block_height.desc&limit=64
// Populates g_canonical_history ring; refreshes last-refresh timestamp.
fn fetchCanonicalHistory() !void {
    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}/api/v1/blocks?order=block_height.desc&limit=64", .{koiosBase()});

    const resp_buf = g_alloc.alloc(u8, CANONICAL_HISTORY_RESP_BUF_SIZE) catch return error.OutOfMemory;
    defer g_alloc.free(resp_buf);

    const r = try curlGet(url, resp_buf);
    if (r.http_code == 429) return error.RateLimited;
    if (r.http_code != 200) return error.HttpError;
    if (r.len == 0) return error.EmptyResponse;
    const body = resp_buf[0..r.len];

    // Response is JSON array of block entries. We need: block_height, hash, abs_slot.
    // Field naming on Koios v1 /blocks: "block_height", "abs_slot", "hash".
    const now = compat.timestamp();
    var idx: usize = 0;
    var count: usize = 0;

    g_canonical_history_mutex.lock();
    defer g_canonical_history_mutex.unlock();

    while (idx < body.len and count < CANONICAL_HISTORY_DEPTH) {
        const hash_key = "\"hash\":\"";
        const k = std.mem.indexOfPos(u8, body, idx, hash_key) orelse break;
        const start = k + hash_key.len;
        if (start + 64 > body.len) break;
        var hash: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&hash, body[start .. start + 64]) catch {
            idx = start + 1;
            continue;
        };

        // Find the object boundary and parse block_height + abs_slot from it.
        const obj_start = lastIndexOfByteBefore(body, '{', k) orelse 0;
        const obj_end = std.mem.indexOfScalarPos(u8, body, start + 64, '}') orelse body.len;
        const obj = body[obj_start..obj_end];

        const block_no = parseUintField(obj, "\"block_height\":") orelse {
            idx = obj_end + 1;
            continue;
        };
        const abs_slot = parseUintField(obj, "\"abs_slot\":") orelse 0;

        g_canonical_history[count] = .{
            .block_no = block_no,
            .slot = abs_slot,
            .hash = hash,
            .fetched_unix = now,
        };
        count += 1;
        idx = obj_end + 1;
    }

    g_canonical_history_count = count;
    g_canonical_history_last_refresh_unix = now;

    std.debug.print("FCC_HISTORY_REFRESH: entries={d} newest_block={d} oldest_block={d}\n", .{
        count,
        if (count > 0) g_canonical_history[0].block_no else 0,
        if (count > 0) g_canonical_history[count - 1].block_no else 0,
    });
}

fn fetchPoolBlocks() !void {
    var url_buf: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buf,
        "{s}/api/v1/pool_blocks?_pool_bech32={s}",
        .{ koiosBase(), g_pool_bech32_buf[0..g_pool_bech32_len] },
    );

    // Response can be large for established pools — alloc a 1 MiB buffer.
    const resp_buf = g_alloc.alloc(u8, RESPONSE_BUF_SIZE) catch return error.OutOfMemory;
    defer g_alloc.free(resp_buf);

    const r = try curlGet(url, resp_buf);
    if (r.http_code == 429) return error.RateLimited;
    if (r.http_code != 200) return error.HttpError;
    if (r.len == 0) {
        // Empty body == empty pool_blocks list, which is fine.
        return;
    }
    const body = resp_buf[0..r.len];

    // Walk the array. Entries look like:
    //   {"epoch_no":N,"epoch_slot":..,"abs_slot":S,"block_height":B,"block_hash":"<64 hex>"}
    const now = compat.timestamp();
    var idx: usize = 0;
    var added: usize = 0;
    while (idx < body.len) {
        const hash_key = "\"block_hash\":\"";
        const k = std.mem.indexOfPos(u8, body, idx, hash_key) orelse break;
        const start = k + hash_key.len;
        if (start + 64 > body.len) break;
        var hash: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&hash, body[start .. start + 64]) catch {
            idx = start + 1;
            continue;
        };
        // Search backwards/forwards inside the surrounding object for fields.
        const obj_start = lastIndexOfByteBefore(body, '{', k) orelse 0;
        const obj_end = std.mem.indexOfScalarPos(u8, body, start + 64, '}') orelse body.len;
        const obj = body[obj_start..obj_end];

        const block_no = parseUintField(obj, "\"block_height\":") orelse 0;
        const abs_slot = parseUintField(obj, "\"abs_slot\":") orelse 0;
        const epoch_no = parseUintField(obj, "\"epoch_no\":") orelse 0;

        addOrTouchCanonical(.{
            .block_hash = hash,
            .block_no = block_no,
            .abs_slot = abs_slot,
            .epoch_no = epoch_no,
            .last_seen_unix = now,
        });
        added += 1;
        idx = obj_end + 1;
    }

    if (added > 0) {
        std.debug.print("ACCEPTANCE_POLL: pool_blocks_seen={d} canonical_tip_block_no={d}\n", .{
            added, g_canonical_tip_block_no,
        });
    }
}

fn addOrTouchCanonical(entry: CanonicalBlock) void {
    g_canonical_mu.lock();
    defer g_canonical_mu.unlock();
    for (g_canonical_pool_blocks.items) |*existing| {
        if (std.mem.eql(u8, &existing.block_hash, &entry.block_hash)) {
            existing.last_seen_unix = entry.last_seen_unix;
            if (existing.block_no == 0) existing.block_no = entry.block_no;
            if (existing.abs_slot == 0) existing.abs_slot = entry.abs_slot;
            return;
        }
    }
    if (g_canonical_pool_blocks.items.len >= MAX_CANONICAL_BLOCKS) {
        _ = g_canonical_pool_blocks.orderedRemove(0);
    }
    g_canonical_pool_blocks.append(entry) catch {};
}

// ─── Reconciler ───────────────────────────────────────────────────────

fn reconcilerLoop() void {
    while (true) {
        if (shutdown.stopRequested()) return;
        reconcileOnce();
        compat.sleep(RECONCILE_INTERVAL_MS * std.time.ns_per_ms);
    }
}

fn reconcileOnce() void {
    const now = compat.timestamp();

    g_records_mu.lock();
    defer g_records_mu.unlock();

    for (g_forge_records.items) |*r| {
        // Skip terminal states.
        switch (r.state) {
            .canonical, .orphaned, .unknown => continue,
            else => {},
        }
        const prev = r.state;
        const elapsed = now - r.forged_unix;

        // Bump from forged → pending after first poll cycle.
        if (r.state == .forged) {
            r.state = .pending;
        }

        // Inspect canonical view.
        var our_hash_seen: bool = false;
        var competing_hash_seen: bool = false;
        var our_block_no_confirmations: u64 = 0;
        var competing_block_no_confirmations: u64 = 0;

        {
            g_canonical_mu.lock();
            defer g_canonical_mu.unlock();
            for (g_canonical_pool_blocks.items) |c| {
                const same_block_no = (c.block_no == r.forge_block_no);
                const same_hash = std.mem.eql(u8, &c.block_hash, &r.forge_hash);
                if (same_hash) {
                    our_hash_seen = true;
                    if (g_canonical_tip_block_no >= c.block_no) {
                        our_block_no_confirmations = g_canonical_tip_block_no - c.block_no;
                    }
                } else if (same_block_no) {
                    competing_hash_seen = true;
                    if (g_canonical_tip_block_no >= c.block_no) {
                        const conf = g_canonical_tip_block_no - c.block_no;
                        if (conf > competing_block_no_confirmations) {
                            competing_block_no_confirmations = conf;
                        }
                    }
                }
            }
            r.last_koios_check_unix = g_canonical_tip_unix;
        }

        if (our_hash_seen and competing_hash_seen) {
            r.state = .fork_local;
            r.confidence_weight = @intCast(@min(our_block_no_confirmations, std.math.maxInt(u32)));
            // Fork resolves once one side gains 2+ confirmations.
            if (our_block_no_confirmations >= CONFIRMATIONS_REQUIRED) {
                r.state = .canonical;
            } else if (competing_block_no_confirmations >= CONFIRMATIONS_REQUIRED) {
                r.state = .orphaned;
            }
        } else if (our_hash_seen) {
            r.state = .arrived;
            r.confidence_weight = @intCast(@min(our_block_no_confirmations, std.math.maxInt(u32)));
            if (our_block_no_confirmations >= CONFIRMATIONS_REQUIRED) {
                r.state = .canonical;
            } else if (our_block_no_confirmations >= 1) {
                r.state = .local_valid;
            }
        } else if (competing_hash_seen and competing_block_no_confirmations >= CONFIRMATIONS_REQUIRED) {
            r.state = .orphaned;
            r.confidence_weight = @intCast(@min(competing_block_no_confirmations, std.math.maxInt(u32)));
        }

        // Timeout — give up and mark unknown.
        if (r.state != .canonical and r.state != .orphaned and elapsed > ACCEPTANCE_TIMEOUT_S) {
            r.state = .unknown;
        }

        if (r.state != prev) {
            r.state_changed_unix = now;
            std.debug.print(
                "ACCEPTANCE_VERDICT: forge_slot={d} forge_block={d} forge_hash={s} prev_state={s} new_state={s} confidence={d} elapsed_s={d}\n",
                .{
                    r.forge_slot,
                    r.forge_block_no,
                    std.fmt.bytesToHex(r.forge_hash[0..8], .lower),
                    @tagName(prev),
                    @tagName(r.state),
                    r.confidence_weight,
                    elapsed,
                },
            );
        }
    }
}

// ─── Helpers ──────────────────────────────────────────────────────────

const CurlResult = struct { len: usize, http_code: u16 };

/// Drops -f so non-2xx responses don't make curl exit non-zero. Appends an
/// HTTP status marker via -w so the caller can distinguish 200 from 429
/// from 5xx and apply the right backoff. The marker is stripped from the
/// returned body length.
fn curlGet(url: []const u8, out_buf: []u8) !CurlResult {
    const start_ns = compat.nanoTimestamp();
    const status_marker = "\n___HTTP:%{http_code}";
    // -4: force IPv4. Many production hosts have degraded IPv6 routes to
    // CDN endpoints (preview.koios.rest in particular has been observed
    // hanging on IPv6 from shared hosting providers). Forcing IPv4
    // bypasses the broken AAAA path without touching DNS or system config.
    const argv = [_][]const u8{ "curl", "-s", "-4", "--max-time", "20", "-w", status_marker, url };
    // 0.16 removed std.process.Child.init + per-field pipe behavior; the compat
    // wrapper spawns the child with stdout/stderr pipes, collects both, and waits
    // — the same flow as the old spawn/readAll/wait sequence. stdout is copied
    // into out_buf and stderr (for forensic logging) into stderr_buf.
    var stderr_buf: [512]u8 = undefined;
    const cap = compat.runCapture(g_alloc, &argv, out_buf, &stderr_buf) orelse return error.WaitFailed;
    const n = cap.stdout.len;
    const stderr_n = cap.stderr.len;
    const elapsed_ms: i64 = @intCast(@divTrunc(compat.nanoTimestamp() - start_ns, 1_000_000));
    if (cap.exit_code != 0) {
        // curl exit codes:
        //  6=DNS resolve, 7=connect, 28=timeout, 35=TLS handshake,
        //  56=recv/send failure, 22=HTTP >=400 (only with -f), etc.
        // Capture exit code + first 256 bytes of stderr so operator can
        // distinguish timeout vs DNS vs TLS vs IPv6 issues at a glance.
        const stderr_slice = stderr_buf[0..@min(stderr_n, 256)];
        std.debug.print("CURL_FAIL: url={s} exit={d} elapsed_ms={d} stderr=\"{s}\"\n", .{
            url, cap.exit_code, elapsed_ms, stderr_slice,
        });
        return error.CurlNonZero;
    }

    // Parse trailing "\n___HTTP:NNN"; on parse failure, treat as unknown.
    const tag = "___HTTP:";
    const m = std.mem.lastIndexOf(u8, out_buf[0..n], tag) orelse return error.NoHttpCode;
    const code_start = m + tag.len;
    var code_end = code_start;
    while (code_end < n and out_buf[code_end] >= '0' and out_buf[code_end] <= '9') : (code_end += 1) {}
    if (code_end == code_start) return error.NoHttpCode;
    const code = std.fmt.parseInt(u16, out_buf[code_start..code_end], 10) catch return error.NoHttpCode;

    // Body ends at the marker's leading newline (or at marker start if no \n).
    var body_end = m;
    if (body_end > 0 and out_buf[body_end - 1] == '\n') body_end -= 1;
    return .{ .len = body_end, .http_code = code };
}

fn parseUintField(body: []const u8, key: []const u8) ?u64 {
    const k = std.mem.indexOf(u8, body, key) orelse return null;
    var i: usize = k + key.len;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t')) : (i += 1) {}
    var end: usize = i;
    while (end < body.len and body[end] >= '0' and body[end] <= '9') : (end += 1) {}
    if (end == i) return null;
    return std.fmt.parseInt(u64, body[i..end], 10) catch null;
}

fn lastIndexOfByteBefore(body: []const u8, byte: u8, before: usize) ?usize {
    var i: usize = if (before > body.len) body.len else before;
    while (i > 0) {
        i -= 1;
        if (body[i] == byte) return i;
    }
    return null;
}

// ─── Tests ────────────────────────────────────────────────────────────

test "parseUintField extracts numeric fields" {
    const body = "{\"epoch_no\":1285,\"abs_slot\":110944068,\"block_height\":3220088}";
    try std.testing.expectEqual(@as(u64, 1285), parseUintField(body, "\"epoch_no\":").?);
    try std.testing.expectEqual(@as(u64, 110944068), parseUintField(body, "\"abs_slot\":").?);
    try std.testing.expectEqual(@as(u64, 3220088), parseUintField(body, "\"block_height\":").?);
    try std.testing.expectEqual(@as(?u64, null), parseUintField(body, "\"missing\":"));
}

test "registerForge then classify reflects state" {
    ensureInit(std.testing.allocator);
    defer {
        g_forge_records.deinit();
        g_canonical_pool_blocks.deinit();
        g_initialized = false;
    }
    var hash: [32]u8 = undefined;
    @memset(&hash, 0xAB);
    registerForge(99_999, 12_345, hash);
    try std.testing.expectEqual(ForgeState.forged, classifyForge(99_999));
    try std.testing.expectEqual(ForgeState.unknown, classifyForge(1));
}
