const std = @import("std");
const compat = @import("compat");
const slot_clock = @import("slot_clock.zig");
const genesis = @import("genesis.zig");
const vrf = @import("vrf.zig");
const kes = @import("kes.zig");
const header_candidate = @import("header_candidate.zig");
const keys = @import("keys.zig");
const leader_model = @import("leader_model.zig");
const zig_ed25519 = @import("crypto/zig_ed25519.zig");
const kes_placeholder = @import("crypto/kes_placeholder_ed25519.zig");
const kes_keyfile = @import("kes_keyfile.zig");
const body_candidate = @import("body_candidate.zig");
const slot_scheduler = @import("slot_scheduler.zig");
const kes_sign = @import("crypto/kes_sign.zig");
const kes_verify = @import("crypto/kes_verify.zig");
const nonce_evo = @import("nonce_evolution.zig");
const node_state = @import("../node_state.zig");
const leader_schedule = @import("leader_schedule.zig");
const exec_quality = @import("exec_quality.zig");
const adaptive = @import("adaptive.zig");
const peer_score = @import("peer_score.zig");
const decision = @import("decision.zig");
const signals = @import("signals.zig");
const prearm = @import("prearm.zig");
const multi_probe = @import("multi_probe.zig");
const forge_notify = @import("../net/forge_notify.zig");
const forge_delay = @import("forge_delay.zig");
const skip_advisory = @import("skip_advisory.zig");
const propagation_opt = @import("propagation_opt.zig");
const alerts = @import("alerts.zig");
const kes_alerts = @import("kes_alerts.zig");
const feedback = @import("feedback.zig");
const announce = @import("announce.zig");
const autotune = @import("autotune.zig");
const presence = @import("presence.zig");
const slot_filter_mod = @import("slot_filter.zig");
const execution_score = @import("execution.zig");
const kes_evolve = @import("crypto/kes_evolve.zig");
const praos_e34 = @import("crypto/praos_threshold_e34.zig");
const cbor_header_body = @import("cbor_header_body.zig");
const cbor_block_header_body = @import("cbor_block_header_body.zig");
const cbor_block_body = @import("cbor_block_body.zig");
const cbor_block_full = @import("cbor_block_full.zig");
const mempool_mod = @import("../net/ledger/mempool.zig");
const stake_snapshot = @import("../net/ledger/stake_snapshot.zig");
const sign_log = @import("sign_log.zig");
const forge_stats = @import("forge_stats.zig");
const utxo_mod = @import("../net/ledger/utxo.zig");
const tx_decode = @import("../net/ledger/tx_decode.zig");
const block_hash = @import("../net/ledger/block_hash.zig");
const forge_gate = @import("../net/ledger/forge_gate.zig");
const eval_external = @import("../net/ledger/eval_external.zig");
const trust_signal = @import("../net/ledger/trust_signal.zig");
const belief_state = @import("../net/ledger/belief_state.zig");
const trust_aggregate = @import("../net/ledger/trust_aggregate.zig");
const trust_score = @import("../net/ledger/trust_score.zig");
const decision_metrics = @import("../net/ledger/decision_metrics.zig");
const decision_advisory = @import("../net/ledger/decision_advisory.zig");
const policy_preview = @import("../net/ledger/policy_preview.zig");
const policy_impact = @import("../net/ledger/policy_impact.zig");
const policy_apply = @import("../net/ledger/policy_apply.zig");
const decision_state = @import("../net/ledger/decision_state.zig");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

// Epoch geometry (mainnet Shelley)
pub const SLOTS_PER_EPOCH_MAINNET: u64 = 432000;
pub const SHELLEY_START_SLOT_MAINNET: u64 = 4_492_800;
pub const SHELLEY_START_EPOCH_MAINNET: u64 = 208;
pub const SLOTS_PER_KES_PERIOD: u64 = 129600; // 1.5 days (432000 / 3)
pub const STATE_SCHEMA_VERSION: u64 = 1;
pub const PACK_SCHEMA_VERSION: u64 = 1;

pub const ProducerState = enum(u8) {
    Disabled = 0,
    Tracking = 1,
    Candidate = 2,
    Leader = 3,
};

pub const KesKeyKind = enum { unknown, placeholder_seed, cardano_kes };

/// Forge gate policy for execution-aware candidate filtering.
pub const ForgeGatePolicy = enum { off, observe, enforce_safe, reorder };

/// Single recent-tip entry for the peer-probe intersect history.
pub const RxTipEntry = struct {
    slot: u64 = 0,
    block_no: u64 = 0,
    hash: [32]u8 = [_]u8{0} ** 32,
    valid: bool = false,
};

pub const ProducerContext = struct {
    state: ProducerState,
    last_slot_checked: u64,
    last_leader_slot: u64,
    leader_checks_total: u64,
    // Slot clock + drift
    clock: slot_clock.SlotClock,
    last_observed_slot: u64,
    drift_last_slots: i64,
    drift_abs_max: u64,
    drift_events_total: u64,
    // Genesis
    genesis_unix: i64,
    slot_length_s: i64,
    genesis_parse_ok: bool,
    genesis_path_ok: bool,
    genesis_last_error_code: u64,
    genesis_network_magic: u64,
    // Epoch geometry (network-aware)
    slots_per_epoch: u64,
    shelley_start_slot: u64,
    shelley_start_epoch: u64,
    // Leader check skeleton
    epoch_last: u64,
    slot_in_epoch_last: u64,
    leader_eligible_last: bool,
    leader_probability_x1e6: u64,
    leader_checks_epoch_total: u64,
    // Epoch nonce — endogenous (chain-derived via nonce_evolution)
    nonce_state: nonce_evo.NonceState = .{},
    nonce_initialized: bool = false,
    nonce_last_fetch_epoch: u64 = 0, // epoch for which we last fetched/verified nonce
    nonce_last_fetch_unix: i64 = 0, // unix seconds of last NONCE_AUTO_UPDATE fetch attempt (cooldown gate)
    // Phase 6: event edge-trigger state (prevents duplicate EVENT_* emissions)
    event_leader_detected_slot: u64 = 0,
    event_leader_missed_slot: u64 = 0,
    // VRF interface
    vrf_cfg: vrf.VrfConfig,
    vrf_attempt_total: u64,
    vrf_checked_total: u64,
    vrf_checked_last: bool,
    vrf_probability_x1e6_last: u64,
    vrf_proof_present_last: bool,
    vrf_output_present_last: bool,
    vrf_reason_code_last: u8,
    // VRF real crypto (v0.8.95)
    vrf_init_ok: bool,
    vrf_verify_ok_last: bool,
    vrf_output_prefix_last: u64,
    // VRF tick-mode hardening (v0.9.3)
    vrf_tick_mode: u8, // 0=off, 1=eligible, 2=always
    last_vrf_checked_slot: u64,
    vrf_skipped_total: u64,
    // VRF proof artifact pipeline (v0.9.8)
    vrf_proof_bytes_last: [80]u8,
    vrf_output_bytes_last: [64]u8,
    vrf_proof_len_last: u64,
    vrf_output_len_last: u64,
    vrf_proof_prefix_last: u64,
    vrf_artifact_dirty: bool,
    // Key management
    key_cfg: keys.KeyCfg,
    key_validate_total: u64,
    key_err_code_last: u32,
    pool_ok_last: u8,
    kes_ok_last: u8,
    vrf_ok_last: u8,
    perms_ok_last: u8,
    readable_ok_last: u8,
    // Leader probability model
    stake_cfg: leader_model.StakeCfg,
    // Ledger-derived sigma (Phase 4) — overrides stake_cfg when available
    ledger_sigma_x1e9: u64 = 0,
    ledger_sigma_valid: bool = false,
    /// Source kind mirrored from stake_distribution.SigmaSource:
    /// 0=env, 1=bootstrap, 2=ledger. Updated by follower on every block.
    ledger_sigma_source_kind: u8 = 0,
    leader_reason_code_last: u32,
    expected_leaders_per_epoch: u64,
    // Eligibility test harness
    elig_test_enabled: bool,
    elig_test_slot_in_epoch: u64,
    elig_test_window_s: u64,
    elig_test_target_end: u64, // min(target + window_s, slots_per_epoch)
    elig_test_override_enabled: bool,
    elig_test_override_target: u64,
    elig_test_force_next_pending: bool,
    elig_test_force_next_offset: u64,
    // KES interface
    kes_cfg: kes.KesConfig,
    kes_attempt_total: u64,
    kes_signed_total: u64,
    kes_sig_present_last: u64,
    kes_reason_code_last: u64,
    // Header candidate pipeline (set by follower before tick)
    tip_block_last: u64,
    tip_slot_last: u64,
    tip_hash_last: [32]u8,
    // Latest received block — updated IMMEDIATELY on ChainSync receipt,
    // before apply. This is the absolute freshest known block.
    // Writes are serialized by `rx_mutex` (Phase 8: primary follower + peer probe).
    rx_block_last: u64 = 0,
    rx_slot_last: u64 = 0,
    rx_hash_last: [32]u8 = [_]u8{0} ** 32,
    // Parent hash of the rx_validated header. Required for the Stage-2
    // 1-step rule (rx may only become parent if its prev_hash equals the
    // applied tip's hash). Plumbed in by the primary follower; peer_probe
    // does not have prev_hash and writes rx_prev_known_last=false.
    rx_prev_hash_last: [32]u8 = [_]u8{0} ** 32,
    rx_prev_known_last: bool = false,
    rx_mutex: compat.Mutex = .{},
    /// Mutex protecting consistent reads of (tip_slot_last, tip_block_last,
    /// tip_hash_last). Without this, the b1/b2 fence in selectFreshestParent
    /// failed to detect mid-write torn snapshots: writer order
    /// "slot, hash, block_last" had a window where slot+hash were NEW and
    /// block was still OLD; readers saw block_no one behind hash, causing
    /// hashes_equal=false refusals on legitimate forge slots. Symmetric to
    /// rx_mutex. Writers (follower.zig RollForward + RollBackward, producer's
    /// own promote path) must hold this while updating tip_*_last. Readers
    /// (selectFreshestParent) acquire briefly to copy a snapshot.
    tip_mutex: compat.Mutex = .{},
    // Tip history ring buffer — written on every updateRxFromPeer success.
    // Used by peer-probe to send multiple intersect candidates, so IntersectNotFound
    // on the latest tip can fall back to older tips instead of replaying from genesis.
    rx_tip_history: [32]RxTipEntry = [_]RxTipEntry{.{}} ** 32,
    rx_tip_history_head: u32 = 0, // next write index (mod 32)
    rx_tip_history_count: u32 = 0, // total valid entries (saturates at 32)
    state_digest: [32]u8,
    // Canonical fragment tail (set by follower after fragment append)
    frag_tail_slot: u64 = 0,
    frag_tail_block_no: u64 = 0,
    frag_tail_hash: [32]u8 = [_]u8{0} ** 32,
    frag_tail_valid: bool = false,
    // Header candidate results
    candidate_built_total: u64,
    candidate_signed_total: u64,
    candidate_last_slot: u64,
    candidate_body_hash_prefix_last: u64,
    candidate_sig_present_last: u8,
    // Header candidate v2 (v0.9.1)
    candidate_hdr_bytes_len: u64,
    candidate_hdr_hash_w0: u64,
    candidate_hdr_hash_w1: u64,
    candidate_hdr_hash_w2: u64, // v1.2.0 — full 32-byte hash
    candidate_hdr_hash_w3: u64,
    // Pure Zig Ed25519 signing (v0.9.4)
    zig_sig_attempt_total: u64,
    zig_sig_ok_total: u64,
    zig_sig_present_last: u8,
    zig_sig_prefix_last: u64,
    zig_sig_reason_last: u8,
    // KES candidate signing pipeline (v0.9.5)
    kes_sign_enabled: bool,
    kes_sign_seed: ?[32]u8,
    kes_sign_attempt_total: u64,
    kes_sign_ok_total: u64,
    kes_sign_present_last: u64,
    kes_sign_prefix_last: u64,
    kes_sign_reason_last: u64,
    kes_sign_label_last: u64, // 1 = placeholder_ed25519
    // Candidate signing proof (v0.9.7)
    candidate_sig_prefix_last: u64,
    candidate_sign_reason_code_last: u64, // 0=ok 1=disabled 2=not_eligible 3=missing_seed 5=sign_fail 6=io_fail
    candidate_last_hdr_bytes: [198]u8,
    candidate_last_sig_bytes: [64]u8,
    candidate_sign_dirty: bool,
    // Block body builder (v0.9.9)
    body_cbor_len_last: u64,
    body_hash_w0: u64,
    body_hash_w1: u64,
    body_hash_w2: u64,
    body_hash_w3: u64,
    body_cbor_bytes_last: [body_candidate.BODY_V1_MAX_LEN]u8,
    body_artifact_dirty: bool,
    // Producer proof pack (v1.0.0)
    pack_dirty: bool,
    pack_total: u64,
    pack_last_unix: i64,
    // Praos leader check (v1.0.1)
    praos_u_x1e12_last: u64,
    praos_thresh_x1e12_last: u64,
    praos_leader_last: u64,
    praos_reason_code_last: u64,
    praos_checks_total: u64,
    praos_catchup_processed_total: u64 = 0, // slots evaluated by catchup scan
    praos_catchup_leaders_total: u64 = 0, // leaders found by catchup scan
    praos_catchup_truncated_total: u64 = 0, // catchup scans that hit MAX_CATCHUP_SLOTS
    praos_enabled: bool, // TSUNAGI_PRAOS_ENABLE=1 gate (v1.0.8)
    praos_last_checked_slot: u64, // v1.0.9
    // Praos decision surface (v1.1.3)
    praos_u_lt_t: u64,
    praos_delta_x1e12: u64,
    // Producer state digest (v1.2.0)
    producer_state_digest: [32]u8,
    // Slot scheduler (v1.1.0)
    schedule_epoch_last: u64,
    schedule_window_start_slot: u64,
    schedule_window_size: u64,
    schedule_leaders_in_window: u64,
    schedule_next_leader_offset: u64,
    schedule_u0_x1e12: u64,
    schedule_t_x1e12: u64,
    schedule_reason_code_last: u8,
    schedule_compute_total: u64,
    schedule_compute_us_total: u64,
    schedule_last_slot: u64,
    schedule_last_update_us: u64,
    // KES period gate (v1.0.2)
    kes_current_period_last: u64,
    kes_start_period: u64,
    kes_max_periods: u64,
    kes_period_valid_last: u64,
    kes_period_reason_code_last: u64,
    // KES lifecycle hardening (v1.1.2)
    kes_period_start_slot: u64,
    kes_period_end_slot: u64,
    kes_rollovers_total: u64,
    kes_last_rollover_slot: u64,
    kes_out_of_range_total: u64,
    kes_sign_refused_total: u64,
    kes_period_seen: bool,
    // Execution timing guards (hardening)
    vrf_compute_us_total: u64,
    vrf_compute_us_last: u64,
    tick_us_total: u64,
    tick_us_last: u64,
    tick_us_max: u64,
    // Producer dry-run (v1.8.0)
    dryrun_enabled: bool,
    dryrun_home_dir: ?[]const u8,
    dryrun_net_name: ?[]const u8,
    dryrun_slots_checked: u64,
    dryrun_leader_slots: u64,
    dryrun_candidates_built: u64,
    dryrun_candidates_verified: u64,
    dryrun_last_leader_slot: u64,
    dryrun_last_candidate_unix: u64,
    dryrun_last_verify_ok: u64,
    // Real KES signing (v1.8.7)
    kes_key_kind: KesKeyKind,
    kes_key_state: [kes_sign.SK_FULL_SIZE_6]u8, // 612 bytes
    kes_key_state_len: usize,
    kes_key_evolved_offset: u32, // 0xFFFFFFFF = not yet evolved
    candidate_last_kes_sig: [kes_sign.SUM6_KES_SIG_LEN]u8,
    dryrun_candidates_signed: u64,
    dryrun_last_sign_verify_ok: u64,
    // v2.0.0-alpha: Full Cardano block candidate (dryrun-only)
    dryrun_block_enabled: bool,
    dryrun_issuer_vk: [32]u8,
    dryrun_opcert_seq_no: u64,
    dryrun_opcert_sigma: [64]u8,
    /// Last opcert counter value persisted to disk. Used for the OPCERT_CHECK
    /// safety gate — forge refuses to sign if dryrun_opcert_seq_no &lt;=
    /// opcert_last_persisted (indicates stale in-memory state vs disk).
    opcert_last_persisted: u64 = 0,
    dryrun_pv_major: u64,
    dryrun_pv_minor: u64,
    dryrun_block_candidates_built: u64,
    dryrun_blocks_dir: ?[]const u8,
    dryrun_mempool: ?*mempool_mod.Mempool = null,
    utxo_set: ?*utxo_mod.UTxO = null, // Phase 5.5: UTxO reference for tx validation
    dryrun_block_max_tx: u32 = 50,
    dryrun_block_max_bytes: usize = 2 * 1024 * 1024,
    // v3.0.0: Forge gate (controlled preview, NO broadcast, NO chain injection)
    forge_enabled: bool = false,
    forge_preview_only: bool = false,
    forge_no_broadcast: bool = false,
    forge_require_guardian: bool = false,
    forge_all_flags_set: bool = false,
    forge_gate_policy: ForgeGatePolicy = .observe,
    policy_experiment_ordering: bool = false, // Phase 52: preview-only policy-coupled ordering
    policy_experiment_enforcement: bool = false, // Phase 54: preview-only policy-coupled enforcement
    force_forge: bool = false, // TEST ONLY: bypass praos + gate
    forge_sim_dir: ?[]const u8 = null,
    forge_last_forged_slot: u64 = 0,
    forge_last_forge_unix: i64 = 0,
    /// Phase 8.9: forge timing optimizer. Base delay in ms; 0 = disabled.
    /// Adaptive formula applies on top when >0.
    forge_delay_base_ms: u32 = 0,
    forge_delay_logged_slot: u64 = 0, // dedupe FORGE_DELAY log per slot
    forge_candidates_built: u64 = 0,
    forge_candidates_verified: u64 = 0,
    forge_last_slot: u64 = 0,
    forge_last_unix: u64 = 0,
    forge_refused_total: u64 = 0,
    forge_last_refuse_reason: u8 = 0, // 0=ok 5=kes_invalid 6=duplicate_slot 7=rate_limit
    // v3.8.3-fix9: Deferred forge — schedule for slot time, not delivery time.
    // When VRF detects a leader slot, store the slot and proof but do NOT forge yet.
    // On subsequent ticks, when wall-clock reaches the deferred slot, forge with the
    // CURRENT tip as parent (not the stale parent from detection time).
    deferred_forge_slot: u64 = 0,
    deferred_forge_proof: [80]u8 = [_]u8{0} ** 80,
    deferred_forge_output: [64]u8 = [_]u8{0} ** 64,
    deferred_forge_u_x1e12: u64 = 0,
    deferred_forge_thresh_x1e12: u64 = 0,
    deferred_forge_pending: bool = false,
    deferred_forge_executing: bool = false, // true during FORGE_AT_SLOT → skip scheduling, go to forge
    deferred_forge_awaiting_parent: bool = false, // true when slot reached but waiting for fresh block delivery
    // Guardian safe-mode: when active, skip forge and tx operations
    safe_mode_active: bool = false,
    safe_mode_last_check_unix: i64 = 0,
    // v3.8.0: Broadcast gate (announce-only, no chain injection)
    bcast_enabled: bool = false,
    bcast_preview_only: bool = false,
    bcast_no_inject: bool = false,
    bcast_require_guardian: bool = false,
    bcast_all_flags_set: bool = false,
    // ── Post-forge orphan watchdog ──
    // After every successful FORGE_PROMOTE_ATOMIC we snapshot the pre-forge
    // tip + opcert counter and arm the watchdog. checkOrphanWatchdog runs
    // at the top of each executeTick. If a probe reports a network block at
    // our forged height with a different hash, or NtN serves repeatedly exit
    // header-only, we rollback to pre-forge state and disarm. Window: 10 slots.
    forge_orphan_watchdog_armed: bool = false,
    // Phase 3 hardening: 3-state machine layered over the legacy `armed` boolean.
    //   DISARMED → no in-flight forge being watched
    //   ARMED → forge in-flight, no contradiction yet
    //   SUSPECT_DIV → at least one probe reported a divergent hash; we are
    //                 waiting SUSPECT_SETTLE_SLOTS, then asking Koios (via
    //                 acceptance_tracker) for authoritative confirmation
    //                 before destructive rollback.
    forge_orphan_state: u8 = 0, // 0=DISARMED, 1=ARMED, 2=SUSPECT_DIV
    forge_orphan_suspect_slot: u64 = 0,
    forge_orphan_armed_slot: u64 = 0,
    forge_orphan_armed_block_no: u64 = 0,
    forge_orphan_armed_hash: [32]u8 = [_]u8{0} ** 32,
    forge_orphan_armed_unix: i64 = 0,
    forge_orphan_baseline_serve_disconnects: u64 = 0,
    forge_orphan_baseline_intersect_not_found: u64 = 0,
    preforge_snapshot_valid: bool = false,
    preforge_tip_slot: u64 = 0,
    preforge_tip_block_no: u64 = 0,
    preforge_tip_hash: [32]u8 = [_]u8{0} ** 32,
    preforge_frag_tail_slot: u64 = 0,
    preforge_frag_tail_block_no: u64 = 0,
    preforge_frag_tail_hash: [32]u8 = [_]u8{0} ** 32,
    preforge_frag_tail_valid: bool = false,
    preforge_opcert_seq_no: u64 = 0,
};

/// Thread-safe update of rx_block_last / rx_slot_last / rx_hash_last.
///
/// Writes all three fields together under rx_mutex iff the incoming
/// block_no is strictly higher than the current rx_block_last. Used by
/// the primary follower (follower.zig) and the Phase 8 peer probe
/// (src/net/chainsync/peer_probe.zig) to converge on the freshest
/// known parent without tearing the 32-byte hash.
pub fn updateRxFromPeer(
    ctx: *ProducerContext,
    peer_id: []const u8,
    slot: u64,
    block_no: u64,
    hash: [32]u8,
    prev_hash: ?[32]u8,
) void {
    // Phase 8.6: record into exec_quality for gap/latency tracking.
    exec_quality.recordPeerUpdate(peer_id, slot, block_no);
    // Phase 8.8: peer scoring — freshness_win if we lead the previous tip.
    {
        // Snapshot previous tip (read-only); mutex isn't strictly needed for
        // the comparison, we'll take it below anyway.
        const prev_block = @atomicLoad(u64, &ctx.rx_block_last, .acquire);
        const is_fresh = block_no > prev_block;
        peer_score.recordUpdate(peer_id, block_no, is_fresh);
    }
    ctx.rx_mutex.lock();
    defer ctx.rx_mutex.unlock();
    const prev_block = ctx.rx_block_last;
    if (block_no <= prev_block) {
        // SAME-BLOCK PREV_HASH UPGRADE PATH
        // Probe peers (peer_probe.zig) call this with prev_hash=null because
        // their lightweight ChainSync doesn't parse the full header. If a
        // probe writes block N first, then primary delivers the SAME block
        // N with a valid prev_hash, the original `return` here silently
        // discarded primary's good prev_hash — leaving rx_prev_known=false
        // and forcing selectFreshestParent's Stage-2 1-step rule to fall
        // back to applied_tip on every leader fire (root cause of the
        // recurring rx_prev_unknown refusal class in production logs).
        //
        // Upgrade ONLY: same block_no, currently-missing prev_hash, an
        // incoming write WITH prev_hash. Same hash sanity guard prevents
        // accepting prev_hash from a competing branch. No block_no/slot/
        // hash mutation — those stay fixed until a strictly-newer block
        // arrives — so the writer-order torn-read fence is unaffected.
        if (block_no == prev_block and !ctx.rx_prev_known_last) {
            if (prev_hash) |ph| {
                if (std.mem.eql(u8, &hash, &ctx.rx_hash_last)) {
                    ctx.rx_prev_hash_last = ph;
                    ctx.rx_prev_known_last = true;
                    std.debug.print("RX_PREV_UPGRADE: peer={s} slot={d} block={d} prev_first8={x} hash_first8={x}\n", .{
                        peer_id, slot, block_no, ph[0..8], hash[0..8],
                    });
                }
            }
        }
        // Log stale headers from non-primary peers at a low rate (every 32nd)
        // so we see the probe is alive without spamming when primary is ahead.
        if (!std.mem.eql(u8, peer_id, "primary") and (block_no & 0x1f) == 0) {
            std.debug.print("PARENT_SOURCE_STALE: peer={s} slot={d} block={d} primary_block={d} gap={d}\n", .{
                peer_id, slot, block_no, prev_block, prev_block - block_no,
            });
        }
        return;
    }
    // RX_WRITE: fresh-only — pointer-identity diag + monotonic advance signal.
    // (Previously fired on every header including stales; ~30 MB/day at probe
    // rates. Now bounded by the actual fresh-block rate, ~1/s on preview.)
    std.debug.print("RX_WRITE: ctx_ptr=0x{x} peer={s} slot={d} block={d} prev_block={d}\n", .{
        @intFromPtr(ctx), peer_id, slot, block_no, prev_block,
    });
    // Writer-order invariant: rx_block_last MUST be written LAST.
    // Lock-free b1/b2 fences in the forge path read rx_block_last twice
    // around rx_slot_last/rx_hash_last/rx_prev_hash_last; only writes that
    // store block_no last allow the fence to detect torn reads. Do not
    // reorder.
    //
    // Resolved against main: main had `ctx.rx_block_last = block_no;` at
    // this position (top of the write block), which is the original
    // pre-PR-α order that caused torn reads at the read side. We keep the
    // bottom-only write (see line below the prev_hash assignments) and
    // discard the top write — preserving the torn-read fence guarantee.
    ctx.rx_slot_last = slot;
    ctx.rx_hash_last = hash;
    if (prev_hash) |ph| {
        ctx.rx_prev_hash_last = ph;
        ctx.rx_prev_known_last = true;
    } else {
        ctx.rx_prev_hash_last = [_]u8{0} ** 32;
        ctx.rx_prev_known_last = false;
    }
    ctx.rx_block_last = block_no;
    // Push into history ring buffer for multi-point intersect.
    const idx = ctx.rx_tip_history_head % 32;
    ctx.rx_tip_history[idx] = .{ .slot = slot, .block_no = block_no, .hash = hash, .valid = true };
    ctx.rx_tip_history_head +%= 1;
    if (ctx.rx_tip_history_count < 32) ctx.rx_tip_history_count += 1;
    std.debug.print("PARENT_SOURCE_UPDATE: peer={s} new_slot={d} new_block={d} prev_block={d}\n", .{
        peer_id, slot, block_no, prev_block,
    });
    // Wire live tip into /status/full surface. Forward-only inside
    // updateLiveTip — a stale peer value cannot regress the applied tip.
    // tip_hash + utxo_size remain owned by the applied path
    // (follower.onBlockFetched → node_state.updateTip).
    node_state.updateLiveTip(slot, block_no);
    // keep /status/full tip_hash in sync with the live PARENT_SOURCE_UPDATE source
    node_state.updateLiveTipHash(hash);
}

/// Snapshot recent tip history for peer-probe FindIntersect.
/// Returns up to `max` entries newest-first. Caller provides the output buffer.
/// Acquires rx_mutex for the duration.
pub fn snapshotRxTipHistory(
    ctx: *ProducerContext,
    out: []RxTipEntry,
) u32 {
    ctx.rx_mutex.lock();
    defer ctx.rx_mutex.unlock();
    const count = @min(ctx.rx_tip_history_count, @as(u32, @intCast(out.len)));
    if (count == 0) return 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // Newest-first: walk backward from (head - 1 - i)
        const src_idx = (ctx.rx_tip_history_head + 32 - 1 - i) % 32;
        out[i] = ctx.rx_tip_history[src_idx];
    }
    return count;
}

/// Maximum allowed gap (slots) between forge_slot and parent_slot. Forging
/// is refused above this threshold without burning opcert/KES.
/// Configurable via `TSUNAGI_STALE_PARENT_MAX_SLOTS`. Default 600.
/// Praos has no parent-slot-gap rule; cap exists only to refuse forging on a
/// catastrophically stale tip. 600 covers the geometric tail of normal
/// sparse-slot windows; canonical-lag gate handles the genuinely stale case.
pub fn staleParentMaxSlots() u64 {
    if (compat.getenv("TSUNAGI_STALE_PARENT_MAX_SLOTS")) |s| {
        const v = std.fmt.parseInt(u64, s, 10) catch return 600;
        if (v > 0) return v;
    }
    return 600;
}

/// Audit s2-t6 HIGH-1: prefer live protocol params (Koios/NtC watcher) over the
/// boot-time hardcoded `dryrun_pv_major/minor`. Eliminates the source-patch +
/// rebuild dance on each hardfork. Falls back to ctx fields if params not loaded.
pub fn currentProtocolVersion(ctx: *const ProducerContext) struct { major: u64, minor: u64 } {
    if (mempool_mod.g_protocol_params) |pp| {
        if (pp.protocol_major > 0) {
            return .{ .major = @as(u64, pp.protocol_major), .minor = @as(u64, pp.protocol_minor) };
        }
    }
    return .{ .major = ctx.dryrun_pv_major, .minor = ctx.dryrun_pv_minor };
}

// ── Authoritative active-stake sigma resolver (Variant B, 2026-06-07) ──
// SINGLE source of truth for election, leader scheduling, and the forge gate.
// READ-ONLY: never writes ctx.ledger_sigma_x1e9 and never mutates
// stake_distribution / stake_source state. Resolution order:
//   1) fresh stake_source poller snapshot (Koios on-chain active-stake share)
//   2) ctx.ledger_sigma_x1e9 (bootstrap/cert) — fallback if poller absent/stale
//   3) ctx.stake_cfg.stake_fraction_x1e9 (env) — last resort
// Source (1) is the SAME on-chain active-stake sigma cardano-node feeds into its
// own Praos VRF threshold, so consuming it aligns TSUNAGI's elected set with the
// node's and CANNOT over-elect relative to chain reality. No VRF/threshold/nonce
// math is touched here — only which sigma VALUE is selected.
pub const SigmaSource = enum {
    stake_source,
    ledger,
    env_cfg,
    pub fn name(self: SigmaSource) []const u8 {
        return switch (self) {
            .stake_source => "stake_source",
            .ledger => "ledger",
            .env_cfg => "env_cfg",
        };
    }
};

pub const ResolvedSigma = struct {
    sigma_x1e9: u64,
    source: SigmaSource,
    fallback_reason: []const u8, // "" when the primary (fresh poller) was used
};

/// Max age (seconds) for the stake_source poller snapshot to count as fresh.
/// The poller refreshes every 60s; 600s tolerates transient Koios hiccups.
pub const SIGMA_FRESH_MAX_S: i64 = 600;

pub fn resolveAuthoritativeSigma(ctx: *const ProducerContext) ResolvedSigma {
    const stake_source = @import("stake_source.zig");
    if (stake_source.g_active_snapshot) |snap| {
        const age = stake_source.snapshotAge();
        if (snap.sigma_x1e9 > 0 and age >= 0 and age < SIGMA_FRESH_MAX_S) {
            return .{ .sigma_x1e9 = snap.sigma_x1e9, .source = .stake_source, .fallback_reason = "" };
        }
        // poller present but stale or zero — fall back, recording why.
        if (ctx.ledger_sigma_valid and ctx.ledger_sigma_x1e9 > 0)
            return .{ .sigma_x1e9 = ctx.ledger_sigma_x1e9, .source = .ledger, .fallback_reason = "poller_stale" };
        return .{ .sigma_x1e9 = ctx.stake_cfg.stake_fraction_x1e9, .source = .env_cfg, .fallback_reason = "poller_stale_no_ledger" };
    }
    if (ctx.ledger_sigma_valid and ctx.ledger_sigma_x1e9 > 0)
        return .{ .sigma_x1e9 = ctx.ledger_sigma_x1e9, .source = .ledger, .fallback_reason = "poller_no_snapshot" };
    return .{ .sigma_x1e9 = ctx.stake_cfg.stake_fraction_x1e9, .source = .env_cfg, .fallback_reason = "no_poller_no_ledger" };
}

pub const ParentSource = enum {
    applied_tip,
    rx_validated,
    applied_tip_fallback,
    /// FCC: applied_tip was confirmed orphan via Koios canonical history,
    /// rx_prev_hash was confirmed canonical via exact byte equality.
    /// rx is promoted as parent. Activates ONLY after Stage-2 hash mismatch
    /// AND all seven consultation gates pass. Safe-by-default — never used
    /// under uncertainty.
    rx_canonical_validated,
};

/// FCC consultation result. Used by both `selectFreshestParent` (production)
/// and the FCC test matrix (unit tests). Pure function — no ctx, no
/// mutexes, no I/O.
pub const FccDecision = union(enum) {
    /// Promote rx canonical parent. Caller writes choice fields from these.
    override: struct {
        parent_slot: u64,
        parent_block: u64,
        parent_hash: [32]u8,
    },
    /// Consultation refused — fall through to existing applied_tip_fallback.
    /// Reason is for diagnostic logs only.
    refuse: enum {
        feature_disabled,
        stale_acceptance_tracker,
        not_one_step,
        rx_prev_unknown,
        block_not_in_history,
        canonical_slot_distance_exceeded,
        case_a_applied_tip_canonical,
        case_c_both_disagree,
        impossible_both_canonical,
    },
};

/// Pure-function FCC consultation. All inputs are values; no global state
/// except a `historyFreshness` and `canonical_hash_for_block` callable.
/// Used directly from selectFreshestParent in production; the test matrix
/// calls it with mock canonical-history lookups.
pub fn fccConsultPure(
    tip_b1: u64,
    tip_hash: [32]u8,
    rx_b1: u64,
    rx_slot: u64,
    rx_prev: [32]u8,
    rx_prev_known: bool,
    feature_enabled: bool,
    history_age_s: i64,
    canonical_lookup_hash: ?[32]u8,
    canonical_lookup_slot: ?u64,
    stale_parent_max_slots: u64,
) FccDecision {
    if (!feature_enabled) return .{ .refuse = .feature_disabled };
    // FRESHNESS THRESHOLD — first-principles analysis (not reactive tuning):
    //
    // The freshness gate protects against the canonical claim being
    // re-orphaned between witness-snapshot and forge time. The risk is
    // bounded by k-stability: rollbacks of depth > k do not occur. For
    // FCC's use case (witness covers applied_tip.block_no, typically
    // 1-5 blocks behind forge tip), the relevant rollback depths are
    // small and resolve within seconds-to-tens-of-seconds.
    //
    // With TIER 1 local header_store walk active (introduced in f40b71e),
    // the witness reflects cardano-node's k-stable consensus view,
    // refreshed every 60s in microseconds. Witness age < 60s in steady
    // state. 90s gives 30s slack for poll jitter — appropriate for both
    // TIER 1 (local walk authority) and TIER 2 (Koios, external lag).
    //
    // The 2026-05-15 incident (8241s stale acceptance_tracker at slot
    // 112191691) was a TRANSPORT failure, not a freshness-threshold
    // problem. The fix is reliable witness transport (TIER 1 local
    // walk), NOT a wider safety window.
    //
    // HISTORICAL NOTE — narrative clarification preserved in code:
    // f40b71e's commit body documents an intermediate iteration that
    // briefly widened this threshold from 90s to 300s as a reactive
    // response to the same incident. That widening was reverted within
    // the same commit after first-principles analysis showed (a) TIER 1
    // makes witness age << 60s in steady state, so widening is
    // unnecessary, and (b) widening a safety gate to compensate for a
    // transport reliability problem is the wrong architectural
    // direction. Doctrine reinforced by this episode and made permanent
    // here: no reactive patches without first-principles justification.
    if (history_age_s > 90) return .{ .refuse = .stale_acceptance_tracker };
    if (rx_b1 != tip_b1 + 1) return .{ .refuse = .not_one_step };
    if (!rx_prev_known) return .{ .refuse = .rx_prev_unknown };

    const canonical_hash = canonical_lookup_hash orelse return .{ .refuse = .block_not_in_history };
    const canonical_slot = canonical_lookup_slot orelse return .{ .refuse = .block_not_in_history };

    const canonical_slot_close = rx_slot >= canonical_slot and (rx_slot - canonical_slot) <= stale_parent_max_slots;
    if (!canonical_slot_close) return .{ .refuse = .canonical_slot_distance_exceeded };

    const applied_tip_canonical = std.mem.eql(u8, tip_hash[0..], canonical_hash[0..]);
    const rx_prev_canonical = std.mem.eql(u8, rx_prev[0..], canonical_hash[0..]);

    if (applied_tip_canonical and !rx_prev_canonical) return .{ .refuse = .case_a_applied_tip_canonical };
    if (!applied_tip_canonical and !rx_prev_canonical) return .{ .refuse = .case_c_both_disagree };
    if (applied_tip_canonical and rx_prev_canonical) return .{ .refuse = .impossible_both_canonical };

    // Case B: applied_tip orphan, rx_prev canonical → promote canonical parent.
    // The promoted parent is the CANONICAL block N (block=tip_b1, hash=canonical_hash);
    // its slot is canonical_slot. Using rx_slot here would be cross-domain (block N+1's
    // slot paired with block N's identity), understating parent_gap and weakening the
    // stale-parent gate. parent_slot is never serialized into the forged header, so this
    // does not alter forge bytes — it only makes the staleness gate measure the real gap.
    return .{ .override = .{
        .parent_slot = canonical_slot,
        .parent_block = tip_b1,
        .parent_hash = canonical_hash,
    } };
}

pub fn parentSourceName(s: ParentSource) []const u8 {
    return switch (s) {
        .applied_tip => "applied_tip",
        .rx_validated => "rx_validated",
        .applied_tip_fallback => "applied_tip_fallback",
        .rx_canonical_validated => "rx_canonical_validated",
    };
}

pub const ParentChoice = struct {
    slot: u64,
    block_no: u64,
    hash: [32]u8,
    source: ParentSource,
    fallback_reason: []const u8 = "none",
    rx_observed_slot: u64 = 0,
    rx_observed_block: u64 = 0,
    /// Diagnostic copies of the hash bytes we compared on the 1-step rule.
    /// Populated unconditionally so refuse logs can render them. Not used
    /// for any selection decision.
    tip_hash_at_select: [32]u8 = [_]u8{0} ** 32,
    rx_prev_hash_at_select: [32]u8 = [_]u8{0} ** 32,
    rx_prev_known: bool = false,
    torn_read: bool = false,
};

/// Stage-1 + Stage-2 freshest-parent selection. Probe is NEVER consulted
/// — strictly advisory elsewhere. Caller is responsible for Stage-3
/// (slot-gap staleness via staleParentMaxSlots()) and for any
/// parent-vs-forge-slot ordering check.
///
/// Stage-1: candidate = max(applied_tip, rx_validated) by block_no.
/// Stage-2 (1-step rule): rx_validated is accepted as parent only when:
///   - rx_prev_known_last is true, AND
///   - rx.block_no == applied_tip.block_no + 1, AND
///   - rx.prev_hash == applied_tip.hash
/// On any failure or torn snapshot, fall back to applied_tip with
/// fallback_reason populated. Never widens parent identity beyond the
/// validated-locally set.
pub fn selectFreshestParent(ctx: *ProducerContext) ParentChoice {
    // Take both mutexes briefly to snapshot consistent tip and rx state.
    // The previous b1/b2 fence was insufficient: it only detects writer
    // updates that COMPLETE between the two reads, not mid-write windows
    // where slot+hash are NEW but block_no is still OLD. Production
    // forensics on 2026-05-14 found applied_tip with tip_block=4278426 but
    // tip_hash equal to block 4278427's hash — a torn snapshot from
    // exactly such a window. Caused a 1-step rule failure on a legitimate
    // leader slot. Mutex-protected reads eliminate this race.
    var tip_b1: u64 = 0;
    var tip_slot: u64 = 0;
    var tip_hash: [32]u8 = [_]u8{0} ** 32;
    {
        ctx.tip_mutex.lock();
        defer ctx.tip_mutex.unlock();
        tip_b1 = ctx.tip_block_last;
        tip_slot = ctx.tip_slot_last;
        tip_hash = ctx.tip_hash_last;
    }
    const tip_torn = false; // mutex guarantees consistency; field kept for log compat

    var rx_b1: u64 = 0;
    var rx_slot: u64 = 0;
    var rx_hash: [32]u8 = [_]u8{0} ** 32;
    var rx_prev: [32]u8 = [_]u8{0} ** 32;
    var rx_prev_known: bool = false;
    {
        ctx.rx_mutex.lock();
        defer ctx.rx_mutex.unlock();
        rx_b1 = ctx.rx_block_last;
        rx_slot = ctx.rx_slot_last;
        rx_hash = ctx.rx_hash_last;
        rx_prev = ctx.rx_prev_hash_last;
        rx_prev_known = ctx.rx_prev_known_last;
    }
    const rx_torn = false; // mutex guarantees consistency; field kept for log compat

    var choice = ParentChoice{
        .slot = tip_slot,
        .block_no = tip_b1,
        .hash = tip_hash,
        .source = .applied_tip,
        .rx_observed_slot = rx_slot,
        .rx_observed_block = rx_b1,
        .tip_hash_at_select = tip_hash,
        .rx_prev_hash_at_select = rx_prev,
        .rx_prev_known = rx_prev_known,
        .torn_read = tip_torn or rx_torn,
    };

    if (tip_torn or rx_torn) {
        choice.source = .applied_tip_fallback;
        choice.fallback_reason = "torn_snapshot";
        return choice;
    }
    if (rx_b1 <= tip_b1) {
        return choice;
    }
    if (!rx_prev_known) {
        choice.source = .applied_tip_fallback;
        choice.fallback_reason = "rx_prev_unknown";
        return choice;
    }
    if (rx_b1 != tip_b1 + 1) {
        choice.source = .applied_tip_fallback;
        choice.fallback_reason = "rx_not_one_step";
        return choice;
    }
    if (!std.mem.eql(u8, rx_prev[0..], tip_hash[0..])) {
        // ─── FCC: Forge-Time Canonicality Convergence consultation ──────
        // Stage-2 1-step hashes disagree. Before defaulting to applied_tip
        // fallback (which is the safe-but-stale choice), consult the
        // external canonical witness (Koios history ring) to determine
        // whether applied_tip is orphan and rx_prev is canonical. Promote
        // rx as parent ONLY under EXACT 32-byte canonical hash equality
        // AND all seven gates pass. Safe-by-default — refuses on ANY
        // uncertainty. NEVER consensus. Witness only.
        const acceptance_tracker = @import("acceptance_tracker.zig");

        // Resolve feature flag + freshness + canonical lookup, then call the
        // pure consultation function. Production logs the decision; the
        // pure function returns a structured FccDecision so tests can
        // assert on it without depending on log scraping.
        const feature_enabled_p = blk_p: {
            if (compat.getenv("TSUNAGI_FORGE_CANONICAL_CONSULT")) |s| {
                if (s.len > 0 and s[0] == '0') break :blk_p false;
            }
            break :blk_p true;
        };
        const age_p = acceptance_tracker.historyFreshness();
        const canonical_hash_p = acceptance_tracker.getCanonicalHashForBlock(tip_b1);
        const canonical_slot_p = acceptance_tracker.getCanonicalSlotForBlock(tip_b1);

        // ─── Diagnostic capture ──────────────────────────────────────────
        // Pure observability. Captures the ring state AT consult time so
        // operator can disambiguate refresh-vs-consult divergence, walk
        // truncation, ring-coverage-vs-applied_tip mismatches, and
        // lineage assumptions. Single mutex acquisition under
        // canonical_history_mutex; consistent with canonical_hash_p +
        // canonical_slot_p (those were under the same mutex, microseconds
        // apart). Window includes up to 5 entries around tip_b1 for
        // forensic context (or first 5 entries if tip_b1 not found).
        const diag = acceptance_tracker.getDiagnosticSnapshot(tip_b1);
        std.debug.print(
            "FCC_DIAG_CONSULT: consult_for_block_no={d} ring_gen={d} ring_count={d} ring_walk_len={d} ring_newest_block={d} ring_oldest_block={d} ring_freshness_s={d} ring_head_anchor_first8={s} target_hit={} target_hash_first8={s} target_slot={d} applied_tip_slot={d} applied_tip_block={d} applied_tip_hash_first8={s} rx_slot={d} rx_block={d} rx_prev_first8={s} rx_prev_known={}\n",
            .{
                tip_b1,
                diag.generation, diag.ring_count, diag.walk_len,
                diag.newest_block, diag.oldest_block, diag.freshness_s,
                std.fmt.bytesToHex(diag.head_anchor[0..8], .lower),
                diag.target_hit,
                std.fmt.bytesToHex(diag.target_hash[0..8], .lower),
                diag.target_slot,
                tip_slot, tip_b1,
                std.fmt.bytesToHex(tip_hash[0..8], .lower),
                rx_slot, rx_b1,
                std.fmt.bytesToHex(rx_prev[0..8], .lower),
                rx_prev_known,
            },
        );
        // Window entries (forensic context around target_block_no, or
        // first 5 entries of ring if target not found). One log line per
        // entry; kept compact.
        var wi: usize = 0;
        while (wi < diag.window.count) : (wi += 1) {
            const e = diag.window.entries[wi];
            std.debug.print(
                "FCC_DIAG_WINDOW: idx={d} block_no={d} slot={d} hash_first8={s} match={}\n",
                .{
                    wi, e.block_no, e.slot,
                    std.fmt.bytesToHex(e.hash[0..8], .lower),
                    e.block_no == tip_b1,
                },
            );
        }

        const fcc_decision = fccConsultPure(
            tip_b1, tip_hash,
            rx_b1, rx_slot, rx_prev, rx_prev_known,
            feature_enabled_p, age_p,
            canonical_hash_p, canonical_slot_p,
            staleParentMaxSlots(),
        );

        switch (fcc_decision) {
            .override => |o| {
                _ = @import("../net/metrics/http_metrics.zig").g_forge_canonical_override_total.fetchAdd(1, .acq_rel);
                std.debug.print("FORGE_CANONICAL_OVERRIDE: applied_tip block={d} hash={s} was orphan; rx_prev canonical; promoting canonical parent block_no={d} hash={s} freshness_witness_slot={d}\n", .{
                    tip_b1,
                    std.fmt.bytesToHex(tip_hash[0..8], .lower),
                    o.parent_block,
                    std.fmt.bytesToHex(o.parent_hash[0..8], .lower),
                    o.parent_slot,
                });
                choice.slot = o.parent_slot;
                choice.block_no = o.parent_block;
                choice.hash = o.parent_hash;
                choice.source = .rx_canonical_validated;
                choice.fallback_reason = "applied_tip_orphan_canonical_override";
                return choice;
            },
            .refuse => |r| {
                // Emit reason-specific log lines (preserve original observability).
                switch (r) {
                    .feature_disabled => {},
                    .stale_acceptance_tracker => std.debug.print("FORGE_CANONICAL_REFUSE: reason=acceptance_tracker_stale age_s={d}\n", .{age_p}),
                    .not_one_step, .rx_prev_unknown => {}, // already enforced upstream; silent
                    .block_not_in_history => std.debug.print("FORGE_CANONICAL_REFUSE: reason=block_not_in_history block_no={d}\n", .{tip_b1}),
                    .canonical_slot_distance_exceeded => {
                        const cs = canonical_slot_p orelse 0;
                        std.debug.print("FORGE_CANONICAL_REFUSE: reason=canonical_slot_distance_exceeded canonical_slot={d} rx_slot={d} max={d}\n", .{ cs, rx_slot, staleParentMaxSlots() });
                    },
                    .case_a_applied_tip_canonical => {
                        const ch = canonical_hash_p orelse [_]u8{0} ** 32;
                        std.debug.print("FORGE_CANONICALITY_CHECK: block_no={d} applied_tip_hash={s} rx_prev_hash={s} canonical_hash={s} applied_tip_canonical=true rx_prev_canonical=false freshness_s={d}\n", .{
                            tip_b1,
                            std.fmt.bytesToHex(tip_hash[0..8], .lower),
                            std.fmt.bytesToHex(rx_prev[0..8], .lower),
                            std.fmt.bytesToHex(ch[0..8], .lower),
                            age_p,
                        });
                    },
                    .case_c_both_disagree => std.debug.print("FORGE_CANONICAL_REFUSE: reason=both_disagree_with_canonical block_no={d}\n", .{tip_b1}),
                    .impossible_both_canonical => {},
                }
                // Fall through to existing conservative refusal.
            },
        }
        choice.source = .applied_tip_fallback;
        choice.fallback_reason = "rx_hash_mismatch";
        return choice;
    }

    choice.slot = rx_slot;
    choice.block_no = rx_b1;
    choice.hash = rx_hash;
    choice.source = .rx_validated;
    choice.fallback_reason = "none";
    return choice;
}

pub fn init(ctx: *ProducerContext, alloc: std.mem.Allocator) void {
    initWithNet(ctx, alloc, false, null, "mainnet");
}

pub fn initWithNet(ctx: *ProducerContext, alloc: std.mem.Allocator, is_mainnet: bool, expected_magic: ?u32, genesis_dir_name: []const u8) void {
    ctx.state = .Tracking;
    ctx.last_slot_checked = 0;
    ctx.last_leader_slot = 0;
    ctx.leader_checks_total = 0;
    ctx.last_observed_slot = 0;
    ctx.drift_last_slots = 0;
    ctx.drift_abs_max = 0;
    ctx.drift_events_total = 0;
    ctx.epoch_last = 0;
    ctx.slot_in_epoch_last = 0;
    ctx.leader_eligible_last = false;
    ctx.leader_probability_x1e6 = 0;
    ctx.leader_checks_epoch_total = 0;
    // Epoch geometry: set early so elig_test init can use ctx.slots_per_epoch
    if (is_mainnet) {
        ctx.slots_per_epoch = SLOTS_PER_EPOCH_MAINNET;
        ctx.shelley_start_slot = SHELLEY_START_SLOT_MAINNET;
        ctx.shelley_start_epoch = SHELLEY_START_EPOCH_MAINNET;
    } else {
        ctx.slots_per_epoch = 86_400;
        ctx.shelley_start_slot = 0;
        ctx.shelley_start_epoch = 0;
    }
    ctx.vrf_attempt_total = 0;
    ctx.vrf_checked_total = 0;
    ctx.vrf_checked_last = false;
    ctx.vrf_probability_x1e6_last = 0;
    ctx.vrf_proof_present_last = false;
    ctx.vrf_output_present_last = false;
    ctx.vrf_reason_code_last = 0;
    ctx.vrf_cfg = vrf.loadConfig(alloc);
    ctx.vrf_init_ok = ctx.vrf_cfg.init_ok;

    // ── Epoch nonce bootstrap (endogenous — no external dependency) ──
    // Priority: 1) nonce_state.json (chain-derived), 2) genesis seed bootstrap
    {
        // Deprecate TSUNAGI_EPOCH_NONCE_HEX — log warning if present, do not use
        if (compat.getEnvVarOwned(alloc, "TSUNAGI_EPOCH_NONCE_HEX")) |h| {
            defer alloc.free(h);
            std.debug.print("PRAOS_NONCE_DEPRECATED: TSUNAGI_EPOCH_NONCE_HEX is set but ignored — nonce is now endogenous\n", .{});
        } else |_| {}

        // Source 1: Chain-derived nonce from nonce_state.json (persisted evolution)
        const home_env = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
        defer if (home_env) |hh| alloc.free(hh);

        var loaded_from_state = false;
        if (home_env) |home| {
            var nonce_path_buf: [512]u8 = undefined;
            const nonce_path = std.fmt.bufPrint(&nonce_path_buf, "{s}/nonce_state.json", .{home}) catch "";
            if (nonce_path.len > 0 and nonce_evo.loadState(&ctx.nonce_state, nonce_path)) {
                if (ctx.nonce_state.epoch_nonce_valid) {
                    ctx.nonce_initialized = true;
                    loaded_from_state = true;
                    std.debug.print("PRAOS_NONCE_BOOTSTRAP: nonce={x} source=chain_state epoch={d}\n", .{
                        &ctx.nonce_state.epoch_nonce, ctx.nonce_state.nonce_epoch,
                    });
                }
            }
        }

        // Source 2: Auto-fetch from Koios API (no babysitting)
        if (!loaded_from_state) {
            const net_name = if (ctx.slots_per_epoch == 86_400) "preview" else "mainnet";
            // Estimate current epoch from wall clock
            const genesis_unix_preview: i64 = 1654041600; // Preview genesis
            const genesis_unix_mainnet: i64 = 1596059091; // Mainnet Shelley genesis
            const genesis_unix = if (ctx.slots_per_epoch == 86_400) genesis_unix_preview else genesis_unix_mainnet;
            const now_unix = compat.timestamp();
            const elapsed: u64 = @intCast(@max(0, now_unix - genesis_unix));
            const est_slot = elapsed; // 1 slot = 1 second on preview
            const est_epoch = ctx.shelley_start_epoch + (est_slot / ctx.slots_per_epoch);

            if (nonce_evo.fetchEpochNonce(&ctx.nonce_state, est_epoch, net_name)) {
                ctx.nonce_initialized = true;
                loaded_from_state = true; // Prevent further fallback
                std.debug.print("PRAOS_NONCE_BOOTSTRAP: nonce={x} source=koios epoch={d}\n", .{
                    &ctx.nonce_state.epoch_nonce, est_epoch,
                });
                // Persist so next restart doesn't need fetch
                if (home_env) |home| {
                    var sp_buf: [512]u8 = undefined;
                    const sp = std.fmt.bufPrint(&sp_buf, "{s}/nonce_state.json", .{home}) catch "";
                    if (sp.len > 0) nonce_evo.saveState(&ctx.nonce_state, sp);
                }
            } else {
                std.debug.print("PRAOS_NONCE_BOOTSTRAP: koios_fetch_failed epoch={d} — leader detection disabled until nonce available\n", .{est_epoch});
                // Leave nonce_initialized=false — VRF will get null nonce, reason_code=11
            }
        }
    }
    ctx.vrf_verify_ok_last = false;
    ctx.vrf_output_prefix_last = 0;
    ctx.last_vrf_checked_slot = 0;
    ctx.vrf_skipped_total = 0;
    ctx.vrf_proof_bytes_last = [_]u8{0} ** 80;
    ctx.vrf_output_bytes_last = [_]u8{0} ** 64;
    ctx.vrf_proof_len_last = 0;
    ctx.vrf_output_len_last = 0;
    ctx.vrf_proof_prefix_last = 0;
    ctx.vrf_artifact_dirty = false;

    // VRF tick mode: off(0) / eligible(1) / always(2)
    const env_tick_mode = compat.getEnvVarOwned(alloc, "TSUNAGI_VRF_TICK_MODE") catch null;
    ctx.vrf_tick_mode = if (env_tick_mode) |v| blk: {
        defer alloc.free(v);
        if (std.mem.eql(u8, v, "eligible")) break :blk 1;
        if (std.mem.eql(u8, v, "always")) break :blk 2;
        if (std.mem.eql(u8, v, "off")) break :blk 0;
        std.debug.print("VRF TICK MODE: invalid '{s}' (defaulting to off)\n", .{v});
        break :blk 0;
    } else 0;
    std.debug.print("VRF TICK MODE: {s}\n", .{switch (ctx.vrf_tick_mode) {
        0 => "off",
        1 => "eligible",
        2 => "always",
        else => "unknown",
    }});

    // Key management
    ctx.key_cfg = keys.loadConfig(alloc);
    const kv = keys.validate(ctx.key_cfg);
    ctx.key_validate_total = 1;
    ctx.key_err_code_last = kv.err_code;
    ctx.pool_ok_last = if (kv.pool_ok) 1 else 0;
    ctx.kes_ok_last = if (kv.kes_ok) 1 else 0;
    ctx.vrf_ok_last = if (kv.vrf_ok) 1 else 0;
    ctx.perms_ok_last = if (kv.perms_ok) 1 else 0;
    ctx.readable_ok_last = if (kv.readable_ok) 1 else 0;

    // KES interface
    ctx.kes_cfg = kes.loadConfig(alloc);
    ctx.kes_attempt_total = 0;
    ctx.kes_signed_total = 0;
    ctx.kes_sig_present_last = 0;
    ctx.kes_reason_code_last = @as(u64, ctx.kes_cfg.reason_code_last);

    // Header candidate pipeline
    ctx.tip_block_last = 0;
    ctx.tip_slot_last = 0;
    ctx.tip_hash_last = [_]u8{0} ** 32;
    ctx.state_digest = [_]u8{0} ** 32;
    ctx.candidate_built_total = 0;
    ctx.candidate_signed_total = 0;
    ctx.candidate_last_slot = 0;
    ctx.candidate_body_hash_prefix_last = 0;
    ctx.candidate_sig_present_last = 0;
    ctx.candidate_hdr_bytes_len = 0;
    ctx.candidate_hdr_hash_w0 = 0;
    ctx.candidate_hdr_hash_w1 = 0;
    ctx.candidate_hdr_hash_w2 = 0;
    ctx.candidate_hdr_hash_w3 = 0;
    ctx.producer_state_digest = [_]u8{0} ** 32;
    ctx.zig_sig_attempt_total = 0;
    ctx.zig_sig_ok_total = 0;
    ctx.zig_sig_present_last = 0;
    ctx.zig_sig_prefix_last = 0;
    ctx.zig_sig_reason_last = 0;

    // KES candidate signing (v0.9.5)
    ctx.kes_sign_attempt_total = 0;
    ctx.kes_sign_ok_total = 0;
    ctx.kes_sign_present_last = 0;
    ctx.kes_sign_prefix_last = 0;
    ctx.kes_sign_reason_last = 1; // disabled by default
    ctx.kes_sign_label_last = 0;
    ctx.candidate_sig_prefix_last = 0;
    ctx.candidate_sign_reason_code_last = 1; // disabled by default
    ctx.candidate_last_hdr_bytes = [_]u8{0} ** 198;
    ctx.candidate_last_sig_bytes = [_]u8{0} ** 64;
    ctx.candidate_sign_dirty = false;
    ctx.body_cbor_len_last = 0;
    ctx.body_hash_w0 = 0;
    ctx.body_hash_w1 = 0;
    ctx.body_hash_w2 = 0;
    ctx.body_hash_w3 = 0;
    ctx.body_cbor_bytes_last = [_]u8{0} ** body_candidate.BODY_V1_MAX_LEN;
    ctx.body_artifact_dirty = false;
    ctx.pack_dirty = false;
    ctx.pack_total = 0;
    ctx.pack_last_unix = 0;
    ctx.praos_u_x1e12_last = 0;
    ctx.praos_thresh_x1e12_last = 0;
    ctx.praos_leader_last = 0;
    ctx.praos_reason_code_last = 1; // vrf_disabled
    ctx.praos_checks_total = 0;
    ctx.praos_last_checked_slot = 0;
    ctx.praos_u_lt_t = 0;
    ctx.praos_delta_x1e12 = 0;
    // Praos enable gate (v1.0.8)
    ctx.praos_enabled = if (compat.getenv("TSUNAGI_PRAOS_ENABLE")) |val|
        std.mem.eql(u8, val, "1")
    else
        false;
    if (ctx.praos_enabled) {
        std.debug.print("PRODUCER: Praos-based eligibility ENABLED (TSUNAGI_PRAOS_ENABLE=1)\n", .{});
    }
    // Slot scheduler (v1.1.0)
    ctx.schedule_epoch_last = 0;
    ctx.schedule_window_start_slot = 0;
    ctx.schedule_window_size = 0;
    ctx.schedule_leaders_in_window = 0;
    ctx.schedule_next_leader_offset = 999999;
    ctx.schedule_u0_x1e12 = 0;
    ctx.schedule_t_x1e12 = 0;
    ctx.schedule_reason_code_last = 0;
    ctx.schedule_compute_total = 0;
    ctx.schedule_compute_us_total = 0;
    ctx.schedule_last_slot = 0;
    ctx.schedule_last_update_us = 0;
    // KES period gate (v1.0.2)
    ctx.kes_current_period_last = 0;
    ctx.kes_period_valid_last = 0;
    ctx.kes_period_reason_code_last = 1; // signing disabled
    // KES lifecycle hardening (v1.1.2)
    ctx.kes_period_start_slot = 0;
    ctx.kes_period_end_slot = 0;
    ctx.kes_rollovers_total = 0;
    ctx.kes_last_rollover_slot = 0;
    ctx.kes_out_of_range_total = 0;
    ctx.kes_sign_refused_total = 0;
    ctx.kes_period_seen = false;
    // Execution timing guards (hardening)
    ctx.vrf_compute_us_total = 0;
    ctx.vrf_compute_us_last = 0;
    ctx.tick_us_total = 0;
    ctx.tick_us_last = 0;
    ctx.tick_us_max = 0;
    // dryrun_enabled is a misnamed legacy field that gates "build full block
    // candidate" — kept TRUE in both modes when forge keys are present.
    // Set after ctx.forge_enabled is initialized below; init zero-valued for now.
    ctx.dryrun_enabled = false;
    ctx.dryrun_home_dir = null;
    ctx.dryrun_net_name = null;
    ctx.dryrun_slots_checked = 0;
    ctx.dryrun_leader_slots = 0;
    ctx.dryrun_candidates_built = 0;
    ctx.dryrun_candidates_verified = 0;
    ctx.dryrun_last_leader_slot = 0;
    ctx.dryrun_last_candidate_unix = 0;
    ctx.dryrun_last_verify_ok = 0;
    // Real KES signing (v1.8.7)
    ctx.kes_key_kind = .unknown;
    ctx.kes_key_state = std.mem.zeroes([kes_sign.SK_FULL_SIZE_6]u8);
    ctx.kes_key_state_len = 0;
    ctx.kes_key_evolved_offset = 0xFFFFFFFF;
    ctx.candidate_last_kes_sig = std.mem.zeroes([kes_sign.SUM6_KES_SIG_LEN]u8);
    ctx.dryrun_candidates_signed = 0;
    ctx.dryrun_last_sign_verify_ok = 0;
    // v2.0.0-alpha: Full Cardano block candidate (dryrun-only)
    ctx.dryrun_block_enabled = false;
    ctx.dryrun_issuer_vk = std.mem.zeroes([32]u8);
    ctx.dryrun_opcert_seq_no = 0;
    ctx.dryrun_opcert_sigma = std.mem.zeroes([64]u8);
    ctx.dryrun_pv_major = 11;
    ctx.dryrun_pv_minor = 0;
    ctx.dryrun_block_candidates_built = 0;
    ctx.dryrun_blocks_dir = null;
    ctx.dryrun_mempool = null;
    // v2.1.0-a: tx inclusion caps from env
    ctx.dryrun_block_max_tx = blk: {
        const v = compat.getEnvVarOwned(alloc, "TSUNAGI_DRYRUN_BLOCK_MAX_TX") catch break :blk 50;
        defer alloc.free(v);
        break :blk std.fmt.parseUnsigned(u32, v, 10) catch 50;
    };
    ctx.dryrun_block_max_bytes = blk: {
        const v = compat.getEnvVarOwned(alloc, "TSUNAGI_DRYRUN_BLOCK_MAX_BYTES") catch break :blk 2 * 1024 * 1024;
        defer alloc.free(v);
        break :blk std.fmt.parseUnsigned(usize, v, 10) catch 2 * 1024 * 1024;
    };
    // v3.0.0: Forge gate (controlled preview, NO broadcast, NO chain injection)
    // Phase 9.2: adaptive forge delay — reads TSUNAGI_FORGE_DELAY_* env vars.
    forge_delay.initFromEnv();
    ctx.forge_delay_base_ms = forge_delay.config().base_ms;
    // Phase 9.3: skip advisory — TSUNAGI_SKIP_ADVISORY / TSUNAGI_SKIP_ENFORCE.
    skip_advisory.initFromEnv();
    // Phase 9.4: propagation observability + flags.
    propagation_opt.initFromEnv();
    // Phase 9.5: slot alerts + webhook.
    alerts.initFromEnv();
    // Phase 9.9: auto-tuner (shadow — observe-only recommendations).
    autotune.initFromEnv();
    // Task 8: mark/set/go stake snapshot (default OFF; TSUNAGI_SNAPSHOT_ENABLE=1 to activate).
    stake_snapshot.initFromEnv();
    // Slashing protection — load last-signed-slot from disk so we never re-sign for
    // a slot we've already signed for (Lighthouse pattern). Always-on, no env flag.
    sign_log.loadFromDisk();
    // Phase 10.2: peer bias — TSUNAGI_PEER_BIAS=1.
    multi_probe.initBiasFromEnv();
    // Phase 10.3: slot quality filter — advisory ON by default, enforce OFF.
    slot_filter_mod.initFromEnv();
    // Single source of truth: TSUNAGI_MODE = preview_safe (default) | live.
    // All forge/broadcast behavior derives from is_live; legacy env flags are
    // no longer read.
    const mode_str = compat.getenv("TSUNAGI_MODE") orelse "preview_safe";
    const is_live = std.mem.eql(u8, mode_str, "live");
    ctx.forge_enabled = if (compat.getenv("TSUNAGI_FORGE_ENABLE")) |val| std.mem.eql(u8, val, "1") else false;
    ctx.forge_require_guardian = if (compat.getenv("TSUNAGI_FORGE_REQUIRE_GUARDIAN_CONFIRM")) |val| std.mem.eql(u8, val, "1") else false;
    // Mode-derived flags — preserve legacy field names so downstream consumers
    // keep compiling. Their semantics are now: "preview safety guards active".
    ctx.forge_preview_only = !is_live;
    ctx.forge_no_broadcast = !is_live;
    // Forge execution gate — opens whenever keys + guardian are present, in
    // BOTH preview_safe and live. The two modes differ only in broadcast.
    ctx.forge_all_flags_set = ctx.forge_enabled and ctx.forge_require_guardian;
    // dryrun_enabled retains its real meaning: "build full block candidates".
    ctx.dryrun_enabled = ctx.forge_enabled;
    // Forge gate policy: live enforces, preview_safe observes. Reorder/off are
    // no longer reachable from env; they were experiment knobs and stay off.
    ctx.forge_gate_policy = if (is_live) ForgeGatePolicy.enforce_safe else ForgeGatePolicy.observe;
    // Phase 52: Preview-only policy-coupled ordering experiment
    if (compat.getenv("TSUNAGI_POLICY_EXPERIMENT")) |val| {
        ctx.policy_experiment_ordering = std.mem.eql(u8, val, "ordering_bias_preview");
        ctx.policy_experiment_enforcement = std.mem.eql(u8, val, "enforcement_bias_preview");
    }
    // TSUNAGI_PRODUCER_FORCE_FORGE=1: bypass praos + arm token, treat as leader always (TEST ONLY)
    ctx.force_forge = if (compat.getenv("TSUNAGI_PRODUCER_FORCE_FORGE")) |val| std.mem.eql(u8, val, "1") else false;
    if (ctx.force_forge) {
        std.debug.print("FORCE_FORGE: enabled (TEST MODE — bypasses praos and arm token)\n", .{});
        // Force forge implies the gate is open — preview/no-broadcast flags
        // are now mode-derived and not part of the gate composition.
        if (!ctx.forge_all_flags_set) {
            ctx.forge_enabled = true;
            ctx.forge_require_guardian = true;
            ctx.forge_all_flags_set = true;
            ctx.dryrun_enabled = true;
            std.debug.print("FORCE_FORGE: auto-set forge gate flags\n", .{});
        }
    }
    ctx.forge_sim_dir = null;
    ctx.forge_candidates_built = 0;
    ctx.forge_candidates_verified = 0;
    ctx.forge_last_slot = 0;
    ctx.forge_last_unix = 0;
    ctx.forge_refused_total = 0;
    ctx.forge_last_refuse_reason = 0;
    if (ctx.forge_all_flags_set) {
        if (compat.getenv("TSUNAGI_HOME")) |home| {
            ctx.forge_sim_dir = std.fs.path.join(alloc, &[_][]const u8{ home, "producer_forge_sim" }) catch null;
            if (ctx.forge_sim_dir) |dir| compat.fs.cwd().makePath(dir) catch {};
        }
        std.debug.print("FORGE GATE: active mode={s} (forge_enabled + guardian present)\n", .{mode_str});
    } else if (ctx.forge_enabled) {
        std.debug.print("FORGE GATE: WARNING — TSUNAGI_FORGE_REQUIRE_GUARDIAN_CONFIRM=1 missing\n", .{});
    }

    // v3.8.0: Broadcast gate env vars
    ctx.bcast_enabled = if (compat.getenv("TSUNAGI_BCAST_ENABLE")) |val| std.mem.eql(u8, val, "1") else false;
    ctx.bcast_preview_only = if (compat.getenv("TSUNAGI_BCAST_PREVIEW_ONLY")) |val| std.mem.eql(u8, val, "1") else false;
    ctx.bcast_no_inject = if (compat.getenv("TSUNAGI_BCAST_NO_INJECT")) |val| std.mem.eql(u8, val, "1") else false;
    ctx.bcast_require_guardian = if (compat.getenv("TSUNAGI_BCAST_REQUIRE_GUARDIAN_CONFIRM")) |val| std.mem.eql(u8, val, "1") else false;
    ctx.bcast_all_flags_set = ctx.bcast_enabled and ctx.bcast_preview_only and ctx.bcast_no_inject and ctx.bcast_require_guardian;
    if (ctx.bcast_all_flags_set) {
        std.debug.print("BCAST GATE: all 4 flags set — controlled broadcast mode active\n", .{});
    } else if (ctx.bcast_enabled) {
        std.debug.print("BCAST GATE: WARNING — incomplete flag set (preview_only={} no_inject={} require_guardian={})\n", .{
            ctx.bcast_preview_only, ctx.bcast_no_inject, ctx.bcast_require_guardian,
        });
    }

    {
        const env_start = compat.getEnvVarOwned(alloc, "TSUNAGI_KES_START_PERIOD") catch null;
        ctx.kes_start_period = if (env_start) |v| blk: {
            defer alloc.free(v);
            break :blk std.fmt.parseUnsigned(u64, v, 10) catch 0;
        } else 0;
        const env_max = compat.getEnvVarOwned(alloc, "TSUNAGI_KES_MAX_PERIODS") catch null;
        ctx.kes_max_periods = if (env_max) |v| blk: {
            defer alloc.free(v);
            break :blk std.fmt.parseUnsigned(u64, v, 10) catch 62;
        } else 62;
        std.debug.print("KES PERIOD: start={d} max={d} slots_per_period={d}\n", .{ ctx.kes_start_period, ctx.kes_max_periods, SLOTS_PER_KES_PERIOD });
    }
    ctx.kes_sign_seed = null;
    const env_kes_sign = compat.getEnvVarOwned(alloc, "TSUNAGI_KES_SIGN") catch null;
    const kes_sign_flag = if (env_kes_sign) |v| blk: {
        defer alloc.free(v);
        break :blk !std.mem.eql(u8, v, "0");
    } else false;
    ctx.kes_sign_enabled = kes_sign_flag and ctx.key_cfg.enabled;
    if (ctx.kes_sign_enabled) {
        // Load seed from KES skey path
        if (ctx.key_cfg.kes_skey_path) |path| {
            const file_content = blk: {
                var f = compat.fs.cwd().openFile(path, .{ .mode = .read_only }) catch {
                    std.debug.print("KES SIGN: cannot open {s} (reason=3)\n", .{path});
                    ctx.kes_sign_reason_last = 3;
                    break :blk null;
                };
                defer f.close();
                break :blk f.readToEndAlloc(alloc, 65536) catch null;
            };
            if (file_content) |content| {
                defer alloc.free(content);
                if (kes_keyfile.isJsonKeyFile(content)) {
                    // Cardano-cli JSON key envelope detected
                    if (kes_keyfile.readKeyJson(content)) |kf| {
                        var decoded_buf: [4096]u8 = undefined;
                        const decoded_len = kes_keyfile.decodeCborHex(kf.cbor_hex, &decoded_buf);
                        const dlen = decoded_len orelse 0;
                        const kind = kes_keyfile.classifyKesKey(kf.type_str, dlen);
                        switch (kind) {
                            .placeholder_seed => {
                                // 32-byte seed inside JSON envelope
                                if (decoded_len) |dl| {
                                    if (dl == 32) {
                                        var seed: [32]u8 = undefined;
                                        @memcpy(&seed, decoded_buf[0..32]);
                                        ctx.kes_sign_seed = seed;
                                        ctx.kes_key_kind = .placeholder_seed;
                                        std.debug.print("KES KEY: placeholder seed in JSON envelope (32 bytes)\n", .{});
                                        std.debug.print("KES SIGN: enabled (placeholder ed25519) — TEST ONLY, no forging\n", .{});
                                    }
                                }
                            },
                            .cardano_kes => {
                                // v1.8.7: store real KES key state for Sum6Kes signing
                                if (decoded_len) |dl| {
                                    if (dl == kes_sign.SK_SIZE_6 or dl == kes_sign.SK_FULL_SIZE_6) {
                                        @memcpy(ctx.kes_key_state[0..dl], decoded_buf[0..dl]);
                                        // Normalize to 612-byte form (append period=0 if 608)
                                        if (dl == kes_sign.SK_SIZE_6) {
                                            std.mem.writeInt(u32, ctx.kes_key_state[kes_sign.SK_SIZE_6..][0..4], 0, .big);
                                        }
                                        ctx.kes_key_state_len = kes_sign.SK_FULL_SIZE_6;
                                        ctx.kes_key_kind = .cardano_kes;
                                        // Also extract first 32 bytes as seed for placeholder fallback
                                        var s: [32]u8 = undefined;
                                        @memcpy(&s, decoded_buf[0..32]);
                                        ctx.kes_sign_seed = s;
                                        std.debug.print("KES KEY: cardano_kes JSON type={s} decoded_len={d}\n", .{ kf.type_str, dl });
                                        std.debug.print("KES SIGN: enabled (real Sum6Kes) — dryrun only, no forging\n", .{});
                                    } else {
                                        std.debug.print("KES KEY: cardano_kes unexpected size={d} (expected {d} or {d})\n", .{ dl, kes_sign.SK_SIZE_6, kes_sign.SK_FULL_SIZE_6 });
                                        ctx.kes_sign_reason_last = 4;
                                    }
                                }
                            },
                            .unknown => {
                                std.debug.print("KES KEY: unknown JSON key type={s} decoded_len={d}\n", .{ kf.type_str, dlen });
                                ctx.kes_sign_reason_last = 4;
                            },
                        }
                    } else {
                        std.debug.print("KES KEY: malformed JSON key envelope in {s} (reason=4)\n", .{path});
                        ctx.kes_sign_reason_last = 4;
                    }
                } else if (kes_placeholder.parseSeed(content)) |seed| {
                    ctx.kes_sign_seed = seed;
                    ctx.kes_key_kind = .placeholder_seed;
                    std.debug.print("KES KEY: placeholder seed (32 bytes)\n", .{});
                    std.debug.print("KES SIGN: enabled (placeholder ed25519) — TEST ONLY, no forging\n", .{});
                } else {
                    std.debug.print("KES KEY: unknown format in {s} len={d} (reason=4)\n", .{ path, content.len });
                    ctx.kes_sign_reason_last = 4;
                }
            } else {
                std.debug.print("KES SIGN: cannot read {s} (reason=3)\n", .{path});
                ctx.kes_sign_reason_last = 3;
            }
        } else {
            std.debug.print("KES SIGN: no KES skey path configured (reason=3)\n", .{});
            ctx.kes_sign_reason_last = 3;
        }
        if (ctx.kes_sign_seed == null) {
            ctx.kes_sign_enabled = false;
        }
    } else {
        std.debug.print("KES SIGN: disabled\n", .{});
    }

    // v2.0.0-alpha: Full Cardano block candidate env vars (dryrun-only)
    if (ctx.dryrun_enabled) {
        var block_cfg_ok = true;
        // TSUNAGI_COLD_VK_HEX (required, 64 hex chars = 32 bytes)
        const env_cold_vk = compat.getEnvVarOwned(alloc, "TSUNAGI_COLD_VK_HEX") catch null;
        if (env_cold_vk) |hex| {
            defer alloc.free(hex);
            if (hex.len == 64) {
                _ = std.fmt.hexToBytes(&ctx.dryrun_issuer_vk, hex) catch {
                    block_cfg_ok = false;
                };
            } else block_cfg_ok = false;
        } else block_cfg_ok = false;
        // TSUNAGI_OPCERT_SEQ: preferred source is {TSUNAGI_HOME}/opcert_state.json,
        // falls back to env var. TODO: refuse to forge if persisted counter is
        // behind on-chain opcert counter (Koios/local-state query not yet wired).
        var opcert_loaded_from_file = false;
        var opcert_source: []const u8 = "env";
        if (compat.getenv("TSUNAGI_HOME")) |oc_home| {
            var oc_pb: [512]u8 = undefined;
            const oc_path = std.fmt.bufPrint(&oc_pb, "{s}/opcert_state.json", .{oc_home}) catch "";
            if (oc_path.len > 0) {
                if (compat.fs.cwd().readFileAlloc(oc_path, alloc, 1024)) |buf| {
                    defer alloc.free(buf);
                    if (std.mem.indexOf(u8, buf, "\"seq_no\"")) |k| {
                        var i = k + 8;
                        while (i < buf.len and (buf[i] == ' ' or buf[i] == ':' or buf[i] == '\t')) : (i += 1) {}
                        var j = i;
                        while (j < buf.len and buf[j] >= '0' and buf[j] <= '9') : (j += 1) {}
                        if (j > i) {
                            if (std.fmt.parseUnsigned(u64, buf[i..j], 10)) |n| {
                                ctx.dryrun_opcert_seq_no = n;
                                opcert_source = "file";
                                opcert_loaded_from_file = true;
                            } else |_| {}
                        }
                    }
                } else |_| {}
            }
        }
        const env_opcert_seq = compat.getEnvVarOwned(alloc, "TSUNAGI_OPCERT_SEQ") catch null;
        if (!opcert_loaded_from_file) {
            if (env_opcert_seq) |v| {
                defer alloc.free(v);
                ctx.dryrun_opcert_seq_no = std.fmt.parseUnsigned(u64, v, 10) catch blk: {
                    block_cfg_ok = false;
                    break :blk 0;
                };
            } else block_cfg_ok = false;
        } else if (env_opcert_seq) |v| alloc.free(v);
        ctx.opcert_last_persisted = ctx.dryrun_opcert_seq_no;
        std.debug.print("OPCERT_STATE: current={d} source={s} last_persisted={d}\n", .{ ctx.dryrun_opcert_seq_no, opcert_source, ctx.opcert_last_persisted });
        // TSUNAGI_OPCERT_SIGMA_HEX (required, 128 hex chars = 64 bytes)
        const env_opcert_sigma = compat.getEnvVarOwned(alloc, "TSUNAGI_OPCERT_SIGMA_HEX") catch null;
        if (env_opcert_sigma) |hex| {
            defer alloc.free(hex);
            if (hex.len == 128) {
                _ = std.fmt.hexToBytes(&ctx.dryrun_opcert_sigma, hex) catch {
                    block_cfg_ok = false;
                };
            } else block_cfg_ok = false;
        } else block_cfg_ok = false;
        // TSUNAGI_PROTOCOL_MAJOR (optional, default 11)
        const env_pv_major = compat.getEnvVarOwned(alloc, "TSUNAGI_PROTOCOL_MAJOR") catch null;
        if (env_pv_major) |v| {
            defer alloc.free(v);
            ctx.dryrun_pv_major = std.fmt.parseUnsigned(u64, v, 10) catch 11;
        }
        // TSUNAGI_PROTOCOL_MINOR (optional, default 0)
        const env_pv_minor = compat.getEnvVarOwned(alloc, "TSUNAGI_PROTOCOL_MINOR") catch null;
        const pv_minor_source: []const u8 = if (env_pv_minor != null) "env" else "default";
        if (env_pv_minor) |v| {
            defer alloc.free(v);
            ctx.dryrun_pv_minor = std.fmt.parseUnsigned(u64, v, 10) catch 0;
        }
        std.debug.print("FORGE_PROTOCOL_VERSION_TRUTH: major={d} minor={d} source={s}\n", .{
            ctx.dryrun_pv_major, ctx.dryrun_pv_minor, pv_minor_source,
        });
        ctx.dryrun_block_enabled = block_cfg_ok;
        if (block_cfg_ok) {
            std.debug.print("BLOCK CANDIDATE: enabled (dryrun-only, block era tag 7, 10-element header body)\n", .{});
        } else {
            std.debug.print("BLOCK CANDIDATE: disabled (missing TSUNAGI_COLD_VK_HEX / TSUNAGI_OPCERT_SEQ / TSUNAGI_OPCERT_SIGMA_HEX)\n", .{});
        }
    }

    // Leader probability model (env var is fallback — ledger-derived sigma takes priority)
    ctx.stake_cfg = leader_model.loadStakeCfg(alloc);
    if (ctx.stake_cfg.stake_fraction_x1e9 > 0) {
        std.debug.print("STAKE_FALLBACK: TSUNAGI_STAKE_FRACTION_X1E9={d} (used until ledger sigma available)\n", .{ctx.stake_cfg.stake_fraction_x1e9});
    }
    ctx.leader_reason_code_last = 0;
    ctx.expected_leaders_per_epoch = 0;

    // Eligibility test harness
    // Primary env: TSUNAGI_PRODUCER_ELIG_TEST, alias: TSUNAGI_ELIG_TEST_OVERRIDE_ENABLED
    const env_elig = compat.getEnvVarOwned(alloc, "TSUNAGI_PRODUCER_ELIG_TEST") catch
        (compat.getEnvVarOwned(alloc, "TSUNAGI_ELIG_TEST_OVERRIDE_ENABLED") catch null);
    ctx.elig_test_enabled = if (env_elig) |v| blk: {
        defer alloc.free(v);
        break :blk std.mem.eql(u8, v, "1");
    } else false;
    ctx.elig_test_slot_in_epoch = if (ctx.elig_test_enabled and ctx.key_cfg.pool_id_hex != null)
        computeEligSlot(ctx.key_cfg.pool_id_hex.?, ctx.slots_per_epoch)
    else
        0;
    // Target override (TEST ONLY): allows forcing a near-term eligibility window
    // Primary: TSUNAGI_PRODUCER_ELIG_TEST_TARGET_OVERRIDE, alias: TSUNAGI_ELIG_TEST_OVERRIDE_TARGET
    ctx.elig_test_override_enabled = false;
    ctx.elig_test_override_target = 0;
    var elig_test_force_next: bool = false;
    var elig_test_force_next_offset: u64 = 0;
    if (ctx.elig_test_enabled) {
        const env_override = compat.getEnvVarOwned(alloc, "TSUNAGI_PRODUCER_ELIG_TEST_TARGET_OVERRIDE") catch
            (compat.getEnvVarOwned(alloc, "TSUNAGI_ELIG_TEST_OVERRIDE_TARGET") catch null);
        if (env_override) |raw| {
            defer alloc.free(raw);
            if (std.fmt.parseUnsigned(u64, raw, 10)) |parsed| {
                const clamped = @min(parsed, ctx.slots_per_epoch - 1);
                ctx.elig_test_override_enabled = true;
                ctx.elig_test_override_target = clamped;
                ctx.elig_test_slot_in_epoch = clamped;
            } else |_| {
                std.debug.print("PRODUCER ELIG TEST: invalid override '{s}' (ignored)\n", .{raw});
            }
        }
        // Force-next mode: TSUNAGI_PRODUCER_ELIG_TEST_FORCE_NEXT=1 or =<offset>
        // Resolves target to current slot_in_epoch + offset at first tick.
        // Deferred: actual resolution happens in tick() when current_slot is known.
        if (!ctx.elig_test_override_enabled) {
            const env_force = compat.getEnvVarOwned(alloc, "TSUNAGI_PRODUCER_ELIG_TEST_FORCE_NEXT") catch null;
            if (env_force) |raw| {
                defer alloc.free(raw);
                const parsed = std.fmt.parseUnsigned(u64, raw, 10) catch 10;
                elig_test_force_next = true;
                elig_test_force_next_offset = std.math.clamp(parsed, 1, 120);
                ctx.elig_test_override_enabled = true;
                // Target will be resolved at first tick — set placeholder
                ctx.elig_test_override_target = 0;
                ctx.elig_test_slot_in_epoch = 0;
            }
        }
    }
    // Persist force_next state for deferred resolution in tick()
    ctx.elig_test_force_next_pending = elig_test_force_next;
    ctx.elig_test_force_next_offset = elig_test_force_next_offset;
    // Window size: default 10s when elig_test enabled, clamp [1..600]
    ctx.elig_test_window_s = if (ctx.elig_test_enabled) blk: {
        const env_win = compat.getEnvVarOwned(alloc, "TSUNAGI_PRODUCER_ELIG_TEST_WINDOW_S") catch
            (compat.getEnvVarOwned(alloc, "TSUNAGI_PRODUCER_ELIG_WINDOW_S") catch null);
        const raw_val: u64 = if (env_win) |v| inner: {
            defer alloc.free(v);
            break :inner std.fmt.parseUnsigned(u64, v, 10) catch 10;
        } else 10;
        break :blk std.math.clamp(raw_val, 1, 600);
    } else 0;
    // Compute target end (clamp to epoch boundary) — skipped if force_next pending
    ctx.elig_test_target_end = if (ctx.elig_test_enabled and !elig_test_force_next and (ctx.elig_test_slot_in_epoch > 0 or ctx.elig_test_override_enabled))
        @min(ctx.elig_test_slot_in_epoch + ctx.elig_test_window_s, ctx.slots_per_epoch)
    else
        0;
    // Startup summary
    if (ctx.elig_test_enabled) {
        if (elig_test_force_next) {
            std.debug.print("PRODUCER ELIG TEST EFFECTIVE: enabled=1 mode=force_next offset=+{d} window={d}s (resolves at first tick, TEST ONLY)\n", .{ elig_test_force_next_offset, ctx.elig_test_window_s });
        } else if (ctx.elig_test_override_enabled) {
            std.debug.print("PRODUCER ELIG TEST EFFECTIVE: enabled=1 mode=override target={d} window={d}s end={d} (TEST ONLY)\n", .{ ctx.elig_test_slot_in_epoch, ctx.elig_test_window_s, ctx.elig_test_target_end });
        } else {
            std.debug.print("PRODUCER ELIG TEST EFFECTIVE: enabled=1 mode=pool_hash target={d} window={d}s end={d} (TEST ONLY, no forging)\n", .{ ctx.elig_test_slot_in_epoch, ctx.elig_test_window_s, ctx.elig_test_target_end });
        }
    } else {
        std.debug.print("PRODUCER ELIG TEST EFFECTIVE: enabled=0\n", .{});
    }

    // Load genesis config (env path or strict per-network auto-discovery)
    const em64: ?u64 = if (expected_magic) |m| @as(u64, m) else null;
    const gen = if (genesis.resolveGenesisPath(alloc, genesis_dir_name)) |resolved_path| blk: {
        defer alloc.free(resolved_path);
        break :blk if (em64) |em|
            genesis.loadGenesisForNet(alloc, resolved_path, em)
        else
            genesis.loadGenesis(alloc, resolved_path);
    } else blk: {
        std.debug.print("GENESIS: path=n/a ok=0 start_unix=0 slot_len=1s magic=n/a err=1 (set TSUNAGI_GENESIS_PATH or place file in $TSUNAGI_HOME/genesis/{s}/)\n", .{genesis_dir_name});
        break :blk genesis.GenesisConfig{
            .genesis_unix = 0,
            .slot_length_s = 1,
            .network_magic = 0,
            .parsed_ok = false,
            .path_ok = false,
            .last_error_code = genesis.ERR_PATH_MISSING,
        };
    };

    ctx.genesis_unix = gen.genesis_unix;
    ctx.slot_length_s = gen.slot_length_s;
    ctx.genesis_parse_ok = gen.parsed_ok;
    ctx.genesis_path_ok = gen.path_ok;
    ctx.genesis_last_error_code = gen.last_error_code;
    ctx.genesis_network_magic = gen.network_magic;

    // ── Genesis fail-loud gate (forge-readiness 2026-05-23) ────────────
    //
    // If the operator requested forge mode (TSUNAGI_FORGE_ENABLE=1) but
    // genesis didn't parse, EVERY downstream slot/epoch derivation will
    // be wall-clock-from-unix-zero garbage (this is what produces the
    // structurally-impossible epoch requests that drove the NONCE
    // auto-update infinite loop). Refuse to start rather than run a
    // broken clock with live forge enabled.
    //
    // Observe-only mode (no forge env) is still tolerated — the bad
    // clock is harmless when the node never tries to sign a block —
    // but a clear warning is printed so the operator can fix the env.
    if (!gen.parsed_ok) {
        const forge_requested = blk_fr: {
            const v = compat.getEnvVarOwned(alloc, "TSUNAGI_FORGE_ENABLE") catch break :blk_fr false;
            defer alloc.free(v);
            break :blk_fr std.mem.eql(u8, v, "1");
        };
        if (forge_requested) {
            std.debug.print(
                "GENESIS: FATAL — parsed_ok=false (err={d}) but TSUNAGI_FORGE_ENABLE=1. " ++
                    "Forge requires a valid genesis clock. Set TSUNAGI_GENESIS_PATH or place " ++
                    "shelley-genesis.json at $TSUNAGI_HOME/genesis/{s}/. Refusing to start.\n",
                .{ gen.last_error_code, genesis_dir_name },
            );
            std.process.exit(96);
        }
        std.debug.print(
            "GENESIS: WARNING — parsed_ok=false (err={d}); running in observe-only mode " ++
                "with neutralized clock. Set TSUNAGI_GENESIS_PATH or $TSUNAGI_HOME/genesis/{s}/" ++
                "shelley-genesis.json to enable forge.\n",
            .{ gen.last_error_code, genesis_dir_name },
        );
    }

    // Wire protocol parameters to mempool admission
    if (gen.parsed_ok and gen.min_fee_a > 0) {
        mempool_mod.g_protocol_params = .{
            .min_fee_a = gen.min_fee_a,
            .min_fee_b = gen.min_fee_b,
            .min_utxo_value = gen.min_utxo_value,
            .max_tx_size = gen.max_tx_size,
            .source = 0, // genesis
            .reload_unix = compat.timestamp(),
        };
        std.debug.print("PROTOCOL_PARAMS: wired from genesis min_fee_a={d} min_fee_b={d} min_utxo={d} max_tx={d}\n", .{
            gen.min_fee_a, gen.min_fee_b, gen.min_utxo_value, gen.max_tx_size,
        });
    }

    // Try loading operator-provided protocol-params.json (overrides genesis)
    var pp_source_str: []const u8 = "fallback";
    var pp_path_str: []const u8 = "none";
    {
        const genesis_mod = @import("genesis.zig");
        const home_env = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
        if (home_env) |home| {
            defer alloc.free(home);
            if (genesis_mod.loadProtocolParamsFile(alloc, home)) |pp| {
                mempool_mod.g_protocol_params = pp;
                pp_source_str = "file";
                pp_path_str = "$TSUNAGI_HOME/protocol-params.json";
                std.debug.print("PROTOCOL_PARAMS: overridden from file\n", .{});
            } else if (mempool_mod.g_protocol_params != null) {
                pp_source_str = "genesis";
                pp_path_str = "genesis";
            }
        } else if (mempool_mod.g_protocol_params != null) {
            pp_source_str = "genesis";
            pp_path_str = "genesis";
        }
    }
    // Startup source declaration + sanity validation (grep-friendly, one line each)
    if (mempool_mod.g_protocol_params) |pp_now| {
        std.debug.print("PROTOCOL_SOURCE: source={s} path={s} fee_a={d} fee_b={d} max_tx={d}\n", .{
            pp_source_str, pp_path_str, pp_now.min_fee_a, pp_now.min_fee_b, pp_now.max_tx_size,
        });
        if (pp_now.min_fee_a == 0 or pp_now.min_fee_b == 0 or pp_now.max_tx_size == 0) {
            std.debug.print("PROTOCOL_INVALID: one or more params are zero — protocol params file missing or malformed\n", .{});
        }
    } else {
        std.debug.print("PROTOCOL_SOURCE: source=fallback path=none fee_a=0 fee_b=0 max_tx=0\n", .{});
        std.debug.print("PROTOCOL_INVALID: one or more params are zero — protocol params file missing or malformed\n", .{});
    }
    if (is_mainnet) {
        slot_clock.initWithEra(&ctx.clock, gen.genesis_unix, gen.slot_length_s, slot_clock.MAINNET_BYRON_SLOT_LENGTH_S, slot_clock.MAINNET_SHELLEY_START_SLOT);
    } else {
        slot_clock.init(&ctx.clock, gen.genesis_unix, gen.slot_length_s);
    }

    // Prime forge_stats epoch so /status/full.forge_stats.epoch isn't 0
    // for the first ~5-10s window between init and the first tick().
    // Uses the same formula as tick(): shelley_start_epoch + (shelley_slot / slots_per_epoch).
    // sigma=0 is correct here — onEpochBoundary is idempotent and the next real
    // tick will overwrite with the live snapshot/ledger sigma.
    {
        const now_unix_init = compat.timestamp();
        const est_slot_init = slot_clock.estimateSlot(&ctx.clock, now_unix_init);
        if (est_slot_init >= ctx.shelley_start_slot and ctx.slots_per_epoch > 0) {
            const shelley_slot_init = est_slot_init - ctx.shelley_start_slot;
            const epoch_init = ctx.shelley_start_epoch + (shelley_slot_init / ctx.slots_per_epoch);
            forge_stats.onEpochBoundary(epoch_init, 0, ctx.slots_per_epoch, ctx.stake_cfg.asc_x1e6);
        }
    }
}

pub fn tick(ctx: *ProducerContext, current_slot: u64, now_unix: i64, parent_slot: u64, parent_block_no: u64, parent_hash: [32]u8) void {
    // ── Deferred forge execution: fire when wall-clock reaches the leader slot ──
    if (ctx.deferred_forge_pending and current_slot >= ctx.deferred_forge_slot) {
        // ── Wall-clock barrier ──────────────────────────────────────────
        // current_slot is whatever the upstream caller passed. follower.zig:8152
        // schedule-leader-tick admits `leader_slot <= est_slot + 128`, so the
        // value can be a FUTURE slot at this point. Without this gate, tick()
        // would forge at wall-clock T < slot_start_unix and the propagation
        // server would publish a header that cardano-node rejects as
        // InFutureHeaderExceedsClockSkew (observed: ageUponArrival -42s..-2s
        // for slot 113631767 on 2026-06-01).
        //
        // Inner check is gated on genesis_parse_ok because estimateSlot
        // returns 0 when the clock is uninitialized (slot_clock.zig:37),
        // which would otherwise dead-lock the forge. Every path that sets
        // deferred_forge_pending=true already requires genesis_parse_ok=true
        // (producer.zig:2311 PRAOS catchup and producer.zig:2377 main leader
        // path), so the gate is structurally unreachable when genesis_parse_ok
        // is false — but guard explicitly for defense in depth.
        if (ctx.genesis_parse_ok) {
            const wall_clock_slot = slot_clock.estimateSlot(&ctx.clock, now_unix);
            if (wall_clock_slot < ctx.deferred_forge_slot) {
                if (ctx.forge_delay_logged_slot != ctx.deferred_forge_slot) {
                    ctx.forge_delay_logged_slot = ctx.deferred_forge_slot;
                    std.debug.print("FORGE_WAIT_SLOT_UTC: deferred_slot={d} wall_clock_slot={d} wait_slots={d} now_unix={d}\n", .{
                        ctx.deferred_forge_slot, wall_clock_slot, ctx.deferred_forge_slot - wall_clock_slot, now_unix,
                    });
                }
                return;
            }
        }
        // Phase 9.2: adaptive non-blocking forge-delay gate. Returns early
        // from tick() until enough ms have elapsed since slot start.
        if (ctx.forge_delay_base_ms > 0) {
            const slot_start_ms: i128 = (@as(i128, @intCast(ctx.deferred_forge_slot)) + 1666656000) * 1000;
            const now_ms: i128 = @divFloor(compat.nanoTimestamp(), 1_000_000);
            const elapsed_ms: i64 = @intCast(now_ms - slot_start_ms);

            const dec = forge_delay.compute(mempool_mod.g_fork_state.fork_pending);

            if (elapsed_ms >= 0 and @as(u32, @intCast(elapsed_ms)) < dec.delay_ms) {
                if (ctx.forge_delay_logged_slot != ctx.deferred_forge_slot) {
                    ctx.forge_delay_logged_slot = ctx.deferred_forge_slot;
                    forge_delay.record(ctx.deferred_forge_slot, dec);
                    std.debug.print("FORGE_DELAY_ADAPT: slot={d} base={d} final={d} gap={d} latency={d} adv={d} conf={d} reason={s}\n", .{
                        ctx.deferred_forge_slot, dec.base_ms, dec.delay_ms,
                        dec.gap, dec.latency_ms, dec.advantage, dec.confidence_x1000, dec.reason,
                    });
                    if (dec.presence_adjustment_ms != 0) {
                        std.debug.print("FORGE_DELAY_PRESENCE: slot={d} base={d} presence_ms={d} p90_ms={d} adjustment={d} final={d}\n", .{
                            ctx.deferred_forge_slot, dec.base_ms,
                            dec.presence_p50_ms, dec.presence_p90_ms,
                            dec.presence_adjustment_ms, dec.delay_ms,
                        });
                    }
                }
                return; // wait for next tick
            }
            // Record the final applied delay once the gate releases too.
            if (ctx.forge_delay_logged_slot != ctx.deferred_forge_slot) {
                ctx.forge_delay_logged_slot = ctx.deferred_forge_slot;
                forge_delay.record(ctx.deferred_forge_slot, dec);
                if (dec.presence_adjustment_ms != 0) {
                    std.debug.print("FORGE_DELAY_PRESENCE: slot={d} base={d} presence_ms={d} p90_ms={d} adjustment={d} final={d}\n", .{
                        ctx.deferred_forge_slot, dec.base_ms,
                        dec.presence_p50_ms, dec.presence_p90_ms,
                        dec.presence_adjustment_ms, dec.delay_ms,
                    });
                }
            }
        }

        // Phase 9.3: skip advisory — observe-only by default. If
        // TSUNAGI_SKIP_ENFORCE=1 AND verdict=skip, abort this forge.
        {
            const advice = skip_advisory.advise(ctx.deferred_forge_slot);
            if (advice.enforce and advice.verdict == .skip) {
                std.debug.print("FORGE_SKIP_ENFORCED: slot={d} reason=low_ev ev_x1000={d} rating={s}\n", .{
                    ctx.deferred_forge_slot, advice.ev_x1000, advice.rating.str(),
                });
                ctx.deferred_forge_pending = false;
                ctx.deferred_forge_executing = false;
                return;
            }
        }

        // Phase 10.3: slot quality filter — advisory ON by default, enforce
        // OFF. Only aborts when TSUNAGI_SLOT_FILTER_ENFORCE=1 AND verdict=skip.
        {
            const sf = slot_filter_mod.advise(ctx.deferred_forge_slot);
            if (sf.enforce and sf.verdict == .skip) {
                slot_filter_mod.markEnforced();
                std.debug.print("FORGE_SKIP_FILTER: slot={d} reason=low_quality score={d}\n", .{
                    ctx.deferred_forge_slot, sf.score,
                });
                ctx.deferred_forge_pending = false;
                ctx.deferred_forge_executing = false;
                return;
            }
        }

        // Phase 10.4: compute + log the unified execution score for this
        // forge decision (observational only).
        _ = execution_score.record(ctx.deferred_forge_slot);

        // ── FINAL PARENT SELECTION: fresh, canonical, stable ──
        //
        // Three-layer parent selection with correctness guards:
        // 1. Collect freshest from all sources
        // 2. Burst stability read (ensure batch is settled)
        // 3. Final consistency check before building

        // ── Stage-1/2 parent selection via shared helper ──
        // Site A and Site B both route through selectFreshestParent. Only
        // applied_tip and rx_validated (with 1-step rule) are eligible for
        // parent identity. Probe is never read here.
        const choice = selectFreshestParent(ctx);
        const fresh_parent_slot = choice.slot;
        const fresh_parent_block_no = choice.block_no;
        const fresh_parent_hash = choice.hash;
        const parent_source_name = parentSourceName(choice.source);
        // Tick-time params (parent_slot/parent_block_no/parent_hash) are not
        // used in the deferred path — selectFreshestParent reads tip_*_last
        // and rx_*_last directly.

        const parent_gap = if (ctx.deferred_forge_slot > fresh_parent_slot)
            ctx.deferred_forge_slot - fresh_parent_slot
        else
            0;
        const stale_threshold_a: u64 = staleParentMaxSlots();

        // Phase 6.1: parent freshness log (always emit one line at finalize)
        std.debug.print("PARENT_SELECTED slot={d} block={d} parent_source={s} parent_gap_slots={d} fallback_reason={s}\n", .{
            fresh_parent_slot, fresh_parent_block_no, parent_source_name, parent_gap, choice.fallback_reason,
        });
        // Phase 8.6: latency from last probe update → parent selection
        exec_quality.recordParentSelected();
        // Phase 8.7: feed current exec metrics into adaptive rolling averages.
        {
            const snap = exec_quality.currentScore();
            if (snap.latency_ms > 0) adaptive.recordLatency(snap.latency_ms);
            adaptive.recordParentGap(snap.parent_gap);
        }
        if (parent_gap > stale_threshold_a) {
            std.debug.print("PARENT_STALE local={d} forge={d} parent_gap_slots={d} threshold={d} parent_source={s}\n", .{
                fresh_parent_slot, ctx.deferred_forge_slot, parent_gap, stale_threshold_a, parent_source_name,
            });
        }

        // ── Safety guard: parent must be BEFORE the deferred slot ──
        if (fresh_parent_slot >= ctx.deferred_forge_slot) {
            std.debug.print("FORGE_EXPIRE: deferred_slot={d} parent_slot={d} parent_block={d} parent_source={s} (chain advanced past forge slot)\n", .{
                ctx.deferred_forge_slot, fresh_parent_slot, fresh_parent_block_no, parent_source_name,
            });
            ctx.deferred_forge_pending = false;
            ctx.deferred_forge_slot = 0;
            ctx.deferred_forge_awaiting_parent = false;
            return;
        }

        // ── Stage-3: stale-parent refusal (no opcert / no KES burn) ──
        if (parent_gap > stale_threshold_a) {
            std.debug.print("FORGE_REFUSE_STALE_PARENT: forge_slot={d} parent_slot={d} parent_block={d} parent_source={s} parent_gap_slots={d} threshold={d} fallback_reason={s} rx_slot={d} rx_block={d} tip_slot={d} tip_block={d} rx_prev_first8={x} tip_hash_first8={x} rx_prev_known={} hashes_equal={}\n", .{
                ctx.deferred_forge_slot, fresh_parent_slot, fresh_parent_block_no,
                parent_source_name, parent_gap, stale_threshold_a, choice.fallback_reason,
                choice.rx_observed_slot, choice.rx_observed_block,
                ctx.tip_slot_last, ctx.tip_block_last,
                choice.rx_prev_hash_at_select[0..8], choice.tip_hash_at_select[0..8],
                choice.rx_prev_known,
                std.mem.eql(u8, choice.rx_prev_hash_at_select[0..], choice.tip_hash_at_select[0..]),
            });
            ctx.deferred_forge_pending = false;
            ctx.deferred_forge_slot = 0;
            ctx.deferred_forge_awaiting_parent = false;
            return;
        }

        // ── Detailed truth log ──
        const est_slot_at_forge = slot_clock.estimateSlot(&ctx.clock, now_unix);
        const wall_gap = if (est_slot_at_forge > fresh_parent_slot) est_slot_at_forge - fresh_parent_slot else 0;
        std.debug.print("FORGE_PARENT_TRUTH: forge_slot={d} est_slot={d} parent_slot={d} parent_block={d} parent_hash={x} parent_source={s} parent_gap_slots={d} wall_gap={d} rx_slot={d} rx_block={d} tip_slot={d} tip_block={d} fallback_reason={s}\n", .{
            ctx.deferred_forge_slot, est_slot_at_forge,
            fresh_parent_slot, fresh_parent_block_no,
            fresh_parent_hash[0..8], parent_source_name, parent_gap, wall_gap,
            ctx.rx_slot_last, ctx.rx_block_last,
            ctx.tip_slot_last, ctx.tip_block_last,
            choice.fallback_reason,
        });

        // Update context with freshest parent — under tip_mutex for atomic snapshot
        ctx.tip_mutex.lock();
        ctx.tip_slot_last = fresh_parent_slot;
        ctx.tip_block_last = fresh_parent_block_no;
        ctx.tip_hash_last = fresh_parent_hash;
        ctx.tip_mutex.unlock();
        ctx.deferred_forge_awaiting_parent = false;

        // Wall-clock has reached the leader slot. Forge NOW with freshest parent.
        std.debug.print("FORGE_AT_SLOT: deferred_slot={d} current_slot={d} parent_slot={d} parent_block_no={d} parent_hash={x} parent_source={s} parent_gap_slots={d}\n", .{
            ctx.deferred_forge_slot, current_slot,
            fresh_parent_slot, fresh_parent_block_no, fresh_parent_hash[0..8],
            parent_source_name, parent_gap,
        });
        // Phase 8.9: final parent line for operator — labels the picked source.
        std.debug.print("FORGE_PARENT_FINAL: slot={d} parent_block={d} parent_source={s} parent_gap_slots={d} fallback_reason={s}\n", .{
            ctx.deferred_forge_slot, fresh_parent_block_no, parent_source_name, parent_gap, choice.fallback_reason,
        });
        // Swap in the stored VRF proof/output so the forge path uses the correct values
        ctx.vrf_proof_bytes_last = ctx.deferred_forge_proof;
        ctx.vrf_output_bytes_last = ctx.deferred_forge_output;
        ctx.praos_u_x1e12_last = ctx.deferred_forge_u_x1e12;
        ctx.praos_thresh_x1e12_last = ctx.deferred_forge_thresh_x1e12;
        // Mark as leader so the forge gate fires
        ctx.leader_eligible_last = true;
        ctx.praos_leader_last = 1;
        // Clear deferred state BEFORE executing (prevent re-entry)
        ctx.deferred_forge_pending = false;
        const deferred_slot = ctx.deferred_forge_slot;
        ctx.deferred_forge_slot = 0;
        // Reset slot guard so executeTick doesn't skip (deferred_slot was already checked normally)
        if (ctx.last_slot_checked >= deferred_slot) {
            ctx.last_slot_checked = deferred_slot - 1;
        }
        // Parent already selected above via deterministic freshest-tip.
        // Use ctx.tip_*_last which was updated with the freshest values.
        const forge_parent_slot = ctx.tip_slot_last;
        const forge_parent_block_no = ctx.tip_block_last;
        // ── Conditional parent-freshness drain ──────────────────────
        // Only wait when the chosen parent is older than 2 slots; in the
        // common case (parent already fresh) this adds zero delay.
        // Bounded by MAX_DRAIN_MS; exits early as soon as a fresher
        // RollForward arrives.
        const PARENT_FRESH_THRESHOLD: u64 = 2;
        const MAX_DRAIN_MS: u64 = 1500;
        const POLL_MS: u64 = 50;
        const parent_age_drain: u64 = if (deferred_slot > forge_parent_slot)
            deferred_slot - forge_parent_slot
        else
            0;
        if (!ctx.force_forge and parent_age_drain > PARENT_FRESH_THRESHOLD) {
            const start_block = forge_parent_block_no;
            var waited_ms: u64 = 0;
            var updated_in_drain: bool = false;
            while (waited_ms < MAX_DRAIN_MS) {
                compat.sleep(POLL_MS * std.time.ns_per_ms);
                waited_ms += POLL_MS;
                const rx_block_now = ctx.rx_block_last;
                const rx_slot_now = ctx.rx_slot_last;
                if (rx_block_now > start_block and rx_slot_now < deferred_slot) {
                    ctx.tip_mutex.lock();
                    ctx.tip_slot_last = rx_slot_now;
                    ctx.tip_block_last = rx_block_now;
                    ctx.tip_hash_last = ctx.rx_hash_last;
                    ctx.tip_mutex.unlock();
                    updated_in_drain = true;
                    break;
                }
            }
            std.debug.print("PARENT_DRAIN: slot={d} age={d} waited_ms={d} updated_parent={}\n", .{
                deferred_slot, parent_age_drain, waited_ms, updated_in_drain,
            });
        }
        const exec_parent_slot = ctx.tip_slot_last;
        const exec_parent_block_no = ctx.tip_block_last;
        const exec_parent_hash = ctx.tip_hash_last;
        // Set executing flag so forge gate skips scheduling and goes straight to forge
        ctx.deferred_forge_executing = true;
        // Execute tick at the deferred slot with fresh parent
        executeTick(ctx, deferred_slot, now_unix, exec_parent_slot, exec_parent_block_no, exec_parent_hash);
        ctx.deferred_forge_executing = false;
        // Re-scan VRF for any leader slots that were skipped while deferred was pending.
        // The pending guard at line ~2101 blocks scheduling additional slots, so any
        // leader slot between deferred_slot+1 and current_slot was missed. Force a
        // fresh check by resetting last_slot_checked to just after the fired slot.
        if (current_slot > deferred_slot + 1) {
            const rescan_from = deferred_slot + 1;
            std.debug.print("DEFERRED_RESCAN: deferred_slot={d} current_slot={d} rescan_from={d} (checking for skipped leader slots)\n", .{
                deferred_slot, current_slot, rescan_from,
            });
            ctx.last_slot_checked = rescan_from - 1;
            ctx.last_vrf_checked_slot = rescan_from - 1;
        }
        return;
    }
    // Expire stale deferred forge (>300 slots past target = chain moved on)
    if (ctx.deferred_forge_pending and current_slot > ctx.deferred_forge_slot + 300) {
        std.debug.print("FORGE_DEFERRED_EXPIRED: slot={d} current={d} (chain advanced too far)\n", .{
            ctx.deferred_forge_slot, current_slot,
        });
        ctx.deferred_forge_pending = false;
        ctx.deferred_forge_awaiting_parent = false;
        ctx.deferred_forge_slot = 0;
    }

    executeTick(ctx, current_slot, now_unix, parent_slot, parent_block_no, parent_hash);
}

fn executeTick(ctx: *ProducerContext, current_slot: u64, now_unix: i64, parent_slot: u64, parent_block_no: u64, parent_hash: [32]u8) void {
    if (current_slot <= ctx.last_slot_checked) return;
    // Capture catchup window before advancing the slot guard. Praos requires
    // VRF eval at every slot; if the producer was woken late (block-arrival
    // driven, ~20-50s gaps), intermediate slots would be skipped without
    // this scan. End is exclusive — current_slot is evaluated by the main
    // tick body below.
    const catchup_start = ctx.last_slot_checked + 1;
    const tick_t0 = compat.nanoTimestamp();
    defer {
        const tick_t1 = compat.nanoTimestamp();
        const tick_elapsed_us: u64 = @intCast(@max(0, @divFloor(tick_t1 - tick_t0, 1000)));
        ctx.tick_us_total += tick_elapsed_us;
        ctx.tick_us_last = tick_elapsed_us;
        if (tick_elapsed_us > ctx.tick_us_max) ctx.tick_us_max = tick_elapsed_us;
    }
    ctx.last_slot_checked = current_slot;
    ctx.leader_checks_total += 1;
    ctx.last_observed_slot = current_slot;
    if (ctx.dryrun_enabled) ctx.dryrun_slots_checked += 1;

    // Orphan watchdog — runs every slot, no-op when not armed.
    checkOrphanWatchdog(ctx, current_slot);

    // Slot clock drift (observed - estimated; positive = chain ahead of clock)
    const est = slot_clock.estimateSlot(&ctx.clock, now_unix);
    const est_i: i64 = @intCast(est);
    const obs_i: i64 = @intCast(current_slot);
    const drift = obs_i - est_i;
    ctx.drift_last_slots = drift;
    const abs: u64 = if (drift < 0) @intCast(-drift) else @intCast(drift);
    if (abs > ctx.drift_abs_max) ctx.drift_abs_max = abs;
    if (abs >= 120) ctx.drift_events_total += 1;

    // Epoch math (network-aware: uses ctx.slots_per_epoch / shelley_start_*)
    if (current_slot < ctx.shelley_start_slot) {
        // Pre-Shelley (Byron): no leader schedule
        ctx.epoch_last = 0;
        ctx.slot_in_epoch_last = current_slot;
        ctx.leader_reason_code_last = 6; // pre_shelley_unsupported
        ctx.leader_eligible_last = false;
        ctx.leader_probability_x1e6 = 0;
        ctx.expected_leaders_per_epoch = 0;
        ctx.state = .Tracking;
        return;
    }
    const shelley_slot = current_slot - ctx.shelley_start_slot;
    const epoch = ctx.shelley_start_epoch + (shelley_slot / ctx.slots_per_epoch);
    const slot_in_epoch = shelley_slot % ctx.slots_per_epoch;
    ctx.epoch_last = epoch;
    ctx.slot_in_epoch_last = slot_in_epoch;
    ctx.leader_checks_epoch_total += 1;

    // ── Epoch boundary nonce auto-update ──
    // If the epoch changed and our nonce doesn't match, fetch from Koios.
    // This handles: fresh start, missed evolution, epoch boundary crossing.
    // The guard `nonce_last_fetch_epoch` is set ONLY after a successful fetch
    // so that failures (Koios down, breaker open, slot_in_epoch < 120) leave
    // it cleared for next-tick retry. Previously the guard was latched
    // unconditionally on entry, deadlocking the gate when the very first
    // tick of a new epoch landed before slot_in_epoch > 120.
    // Forward-only auto-update: only fetch when local epoch is STRICTLY
    // GREATER than state's nonce_epoch. With `!=`, a brief slot-math glitch
    // around epoch boundary (local says N while state already holds N+1
    // from a fresh cli fetch) would re-fetch for the older epoch and
    // regress state. The monotonic writer in nonce_evolution catches this
    // as a last-line defense; this caller-side gate prevents the useless
    // fetch attempt and the spurious NONCE_REGRESSION_REFUSED log noise.
    // Catch-up + clock-validity guards (forge-readiness 2026-05-23):
    //
    // (a) `ctx.genesis_parse_ok` — when genesis didn't parse, `epoch` is
    //     wall-clock-derived from a unix-epoch-zero baseline (huge number)
    //     while cardano-cli will permanently return the real current epoch.
    //     They can never reconcile; firing NONCE_AUTO_UPDATE in that state
    //     is the infinite cardano-cli fork loop. Refuse.
    // (b) `now_unix - nonce_last_fetch_unix >= NONCE_FETCH_COOLDOWN_S` —
    //     cooldown between attempts even when the math says retry.
    //
    // Note: a prior MAX_EPOCH_LOOKAHEAD=2 bound here was REMOVED on
    // 2026-05-26 (commit fix/nonce-progression-lock). The bound was
    // designed for catch-up replay where slot-math derived an epoch
    // far ahead of the live chain, but `ctx.genesis_parse_ok` already
    // gates exactly that scenario (genesis_unix=0 fallback) and the
    // cooldown gate already rate-limits cardano-cli forks. The
    // lookahead actively prevented recovery from a stale on-disk
    // nonce_state.json — observed on relay at epoch 1309 with state
    // pinned at nonce_epoch=1303 from a prior run, blocking every
    // forge at FORGE_GATE_NONCE despite a healthy chain tip. With
    // the lookahead gone, the monotonic writer (which uses cli_epoch
    // from `cardano-cli query tip` as authoritative) accepts any
    // forward jump in one fetch, ending the latch.
    const NONCE_FETCH_COOLDOWN_S: i64 = 10;
    const now_unix_for_nonce = compat.timestamp();
    const cooldown_ok = now_unix_for_nonce - ctx.nonce_last_fetch_unix >= NONCE_FETCH_COOLDOWN_S;
    if (epoch > ctx.nonce_state.nonce_epoch
        and epoch != ctx.nonce_last_fetch_epoch
        and ctx.genesis_parse_ok
        and cooldown_ok) {
        const net_name: []const u8 = if (ctx.slots_per_epoch == 86_400) "preview" else "mainnet";
        // Wait a few slots into the epoch for Koios to index (slot_in_epoch > 120 = ~2 min)
        if (slot_in_epoch > 120 or !ctx.nonce_initialized) {
            std.debug.print("NONCE_AUTO_UPDATE: epoch_advanced current={d} nonce_epoch={d} fetching...\n", .{
                epoch, ctx.nonce_state.nonce_epoch,
            });
            // Stamp cooldown BEFORE fetch — covers success, fail, and the
            // structurally-impossible-request path so cardano-cli can't be
            // forked more than once per NONCE_FETCH_COOLDOWN_S window.
            ctx.nonce_last_fetch_unix = now_unix_for_nonce;
            if (nonce_evo.fetchEpochNonce(&ctx.nonce_state, epoch, net_name)) {
                ctx.nonce_initialized = true;
                // CORRECTNESS: latch the gate to the ACTUAL post-fetch state,
                // NOT the requested local epoch. Previously we set
                //   ctx.nonce_last_fetch_epoch = epoch;
                // which locked out retries even when fetchEpochNonce returned
                // success but state.nonce_epoch did not advance — e.g. when
                // a stale persisted nonce_state.json was loaded, or a Koios
                // response returned the prior epoch's data. Result: PRAOS_STATE
                // reported nonce_epoch=N-1 indefinitely while the gate was
                // latched at N, blocking every retry until the next epoch
                // boundary. Observed at epoch 1297→1298 on 2026-05-15. By
                // latching to state.nonce_epoch, the outer gate
                // (epoch > state.nonce_epoch) remains the single source of
                // truth: if state didn't advance, the gate condition stays
                // TRUE and the next tick retries.
                ctx.nonce_last_fetch_epoch = ctx.nonce_state.nonce_epoch;
                // Persist
                if (compat.getenv("TSUNAGI_HOME")) |home| {
                    var np_buf: [512]u8 = undefined;
                    const np = std.fmt.bufPrint(&np_buf, "{s}/nonce_state.json", .{home}) catch "";
                    if (np.len > 0) nonce_evo.saveState(&ctx.nonce_state, np);
                }
                std.debug.print("NONCE_EPOCH_ROLL: requested_epoch={d} achieved_epoch={d} achieved_nonce={x}\n", .{
                    epoch, ctx.nonce_state.nonce_epoch, ctx.nonce_state.epoch_nonce[0..8],
                });
                if (ctx.nonce_state.nonce_epoch < epoch) {
                    std.debug.print("NONCE_AUTO_UPDATE: fetch_did_not_advance requested={d} achieved={d} — will retry next tick\n", .{
                        epoch, ctx.nonce_state.nonce_epoch,
                    });
                }
            } else {
                std.debug.print("NONCE_AUTO_UPDATE: fetch_failed epoch={d} — will retry next tick\n", .{epoch});
                // gate intentionally NOT set so next tick retries
            }
        }
        // If slot_in_epoch <= 120 AND nonce_initialized, we leave the gate
        // unset and try again on the next tick when slot_in_epoch is larger.
    }

    // Force-next deferred resolution: set target to current slot_in_epoch + offset
    if (ctx.elig_test_force_next_pending) {
        const target = @min(slot_in_epoch + ctx.elig_test_force_next_offset, ctx.slots_per_epoch - 1);
        ctx.elig_test_override_target = target;
        ctx.elig_test_slot_in_epoch = target;
        ctx.elig_test_target_end = @min(target + ctx.elig_test_window_s, ctx.slots_per_epoch);
        ctx.elig_test_force_next_pending = false;
        std.debug.print("PRODUCER ELIG TEST RESOLVED: force_next target={d} end={d} current_slot_in_epoch={d} (TEST ONLY)\n", .{ target, ctx.elig_test_target_end, slot_in_epoch });
    }

    // Stale-target warning (once, on first tick with elig_test active)
    if (ctx.elig_test_enabled and ctx.elig_test_target_end > 0 and ctx.leader_checks_epoch_total == 1) {
        if (slot_in_epoch >= ctx.elig_test_target_end) {
            std.debug.print("PRODUCER ELIG TEST WARNING: target window [{d},{d}) already passed current_slot_in_epoch={d}\n", .{ ctx.elig_test_slot_in_epoch, ctx.elig_test_target_end, slot_in_epoch });
        }
    }

    // Effective stake fraction: prefer go-snapshot (Cardano mark/set/go) when
    // TSUNAGI_SNAPSHOT_ENABLE=1 and a valid go exists; otherwise fall back to
    // ledger-live sigma, then env. When the snapshot flag is off, behavior is
    // identical to pre-Task-8.
    // Variant B: single authoritative active-stake sigma (read-only resolver).
    // Feeds election, PRAOS_STATE, EVENT_LEADER_DETECTED — same value the forge
    // gate and leader_schedule now use. (Replaces the old inert stake_snapshot
    // path + raw ledger_sigma read.)
    const sigma_res = resolveAuthoritativeSigma(ctx);
    const effective_sigma = sigma_res.sigma_x1e9;

    // forge_stats: notify epoch geometry. Idempotent — only resets per-epoch
    // counters on epoch change. Observational only.
    forge_stats.onEpochBoundary(epoch, effective_sigma, ctx.slots_per_epoch, ctx.stake_cfg.asc_x1e6);

    // Leader probability from stake model
    if (!ctx.key_cfg.enabled) {
        ctx.leader_probability_x1e6 = 0;
        ctx.leader_eligible_last = false;
        ctx.leader_reason_code_last = 1; // disabled
        ctx.expected_leaders_per_epoch = 0;
    } else if (ctx.key_err_code_last != 0 and ctx.key_err_code_last != keys.ERR_OK) {
        ctx.leader_probability_x1e6 = 0;
        ctx.leader_eligible_last = false;
        ctx.leader_reason_code_last = 2; // missing_keys
        ctx.expected_leaders_per_epoch = 0;
    } else if (ctx.stake_cfg.error_code == leader_model.ERR_STAKE_MISSING and !ctx.ledger_sigma_valid) {
        ctx.leader_probability_x1e6 = 0;
        ctx.leader_eligible_last = false;
        ctx.leader_reason_code_last = 3; // stake_missing
        ctx.expected_leaders_per_epoch = 0;
    } else if (!ctx.stake_cfg.parse_ok and !ctx.ledger_sigma_valid) {
        ctx.leader_probability_x1e6 = 0;
        ctx.leader_eligible_last = false;
        ctx.leader_reason_code_last = 4; // stake_bad
        ctx.expected_leaders_per_epoch = 0;
    } else if (!ctx.genesis_parse_ok) {
        ctx.leader_probability_x1e6 = 0;
        ctx.leader_eligible_last = false;
        ctx.leader_reason_code_last = 5; // clock_bad
        ctx.expected_leaders_per_epoch = 0;
    } else {
        // Compute probability
        const prob = leader_model.computeProbX1e6(effective_sigma, ctx.stake_cfg.asc_x1e6);
        ctx.leader_probability_x1e6 = prob;
        ctx.expected_leaders_per_epoch = leader_model.computeExpectedEpoch(effective_sigma, ctx.stake_cfg.asc_x1e6, ctx.slots_per_epoch);
        ctx.leader_reason_code_last = 0; // ok
        // Eligibility test harness: deterministic leader window
        if (ctx.elig_test_enabled and prob > 0 and (ctx.elig_test_slot_in_epoch > 0 or ctx.elig_test_override_enabled)) {
            const was_elig = ctx.leader_eligible_last;
            const elig = (slot_in_epoch >= ctx.elig_test_slot_in_epoch and slot_in_epoch < ctx.elig_test_target_end);
            ctx.leader_eligible_last = elig;
            if (elig and !was_elig) {
                std.debug.print("PRODUCER ELIG TEST: entering forced eligibility window slot_in_epoch={d} target=[{d},{d})\n", .{ slot_in_epoch, ctx.elig_test_slot_in_epoch, ctx.elig_test_target_end });
            }
        } else {
            ctx.leader_eligible_last = false; // no real VRF
        }
    }

    // VRF interface (real VRF compute v0.8.95, tick-mode gated v0.9.3)
    var vrf_should_run = switch (ctx.vrf_tick_mode) {
        0 => false, // off
        1 => ctx.leader_eligible_last or (ctx.elig_test_enabled and ctx.slot_in_epoch_last >= ctx.elig_test_slot_in_epoch and ctx.slot_in_epoch_last < ctx.elig_test_target_end), // eligible
        2 => true, // always
        else => false,
    };
    // v1.0.8: praos needs VRF output every slot to compute u
    if (ctx.praos_enabled) vrf_should_run = true;
    if (vrf_should_run and current_slot != ctx.last_vrf_checked_slot) {
        const vrf_t0 = compat.nanoTimestamp();
        const nonce_ptr: ?*const [32]u8 = if (ctx.nonce_initialized) &ctx.nonce_state.epoch_nonce else null;
        const vrf_res = vrf.checkLeader(&ctx.vrf_cfg, current_slot, nonce_ptr, ctx.leader_probability_x1e6, ctx.genesis_parse_ok);
        const vrf_t1 = compat.nanoTimestamp();
        const vrf_elapsed_us: u64 = @intCast(@max(0, @divFloor(vrf_t1 - vrf_t0, 1000)));
        ctx.vrf_compute_us_total += vrf_elapsed_us;
        ctx.vrf_compute_us_last = vrf_elapsed_us;
        if (vrf_res.attempted) ctx.vrf_attempt_total += 1;
        if (vrf_res.checked) ctx.vrf_checked_total += 1;
        ctx.vrf_checked_last = vrf_res.checked;
        ctx.vrf_probability_x1e6_last = vrf_res.probability_x1e6;
        ctx.vrf_proof_present_last = vrf_res.proof_present;
        ctx.vrf_output_present_last = vrf_res.output_present;
        ctx.vrf_reason_code_last = vrf_res.reason_code;
        ctx.vrf_verify_ok_last = vrf_res.verify_ok;
        ctx.vrf_output_prefix_last = vrf_res.output_prefix;
        ctx.last_vrf_checked_slot = current_slot;
        // v0.9.8: store raw proof/output for persistence
        if (vrf_res.proof_present and vrf_res.output_present) {
            @memcpy(&ctx.vrf_proof_bytes_last, &vrf_res.proof_bytes);
            @memcpy(&ctx.vrf_output_bytes_last, &vrf_res.output_bytes);
            ctx.vrf_proof_len_last = vrf_res.proof_len;
            ctx.vrf_output_len_last = vrf_res.output_len;
            ctx.vrf_proof_prefix_last = vrf_res.proof_prefix;
            ctx.vrf_artifact_dirty = true;
        }
    } else if (!vrf_should_run and ctx.vrf_cfg.enabled) {
        ctx.vrf_skipped_total += 1;
    }

    // Praos leader check v2 (v1.0.8) — VRF threshold math with full gating
    {
        const clock_ok = ctx.genesis_parse_ok;
        const praos = computePraosLeaderDecision(
            effective_sigma,
            ctx.stake_cfg.asc_x1e6,
            ctx.vrf_output_bytes_last,
            ctx.vrf_cfg.enabled, // vrf_enabled
            ctx.vrf_init_ok,
            ctx.vrf_output_present_last,
            ctx.vrf_output_len_last,
            ctx.vrf_verify_ok_last,
            ctx.key_cfg.enabled, // keys_ready
            clock_ok,
        );
        ctx.praos_u_x1e12_last = praos.u_x1e12;
        ctx.praos_thresh_x1e12_last = praos.thresh_x1e12;
        // Phase 6 event: edge-trigger on leader detection (once per slot)
        if (praos.leader == 1 and current_slot != ctx.event_leader_detected_slot) {
            ctx.event_leader_detected_slot = current_slot;
            std.debug.print("EVENT_LEADER_DETECTED: slot={d} epoch={d} u_x1e12={d} thresh_x1e12={d}\n", .{
                current_slot, ctx.epoch_last, praos.u_x1e12, praos.thresh_x1e12,
            });
            adaptive.onLeaderDetected();
        }
        ctx.praos_leader_last = praos.leader;
        ctx.praos_reason_code_last = praos.reason;
        ctx.praos_checks_total += 1;
        ctx.praos_last_checked_slot = current_slot;
        ctx.praos_u_lt_t = if (praos.u_x1e12 < praos.thresh_x1e12) @as(u64, 1) else 0;
        ctx.praos_delta_x1e12 = if (praos.thresh_x1e12 > praos.u_x1e12) praos.thresh_x1e12 - praos.u_x1e12 else 0;

        // Priority: force_forge > elig_test > praos > nothing
        if (ctx.force_forge) {
            ctx.leader_eligible_last = true;
        } else if (ctx.elig_test_enabled) {
            // leader_eligible_last already set by elig_test window above
        } else if (ctx.praos_enabled) {
            ctx.leader_eligible_last = (praos.leader == 1);
        } else {
            ctx.leader_eligible_last = false;
        }
        // forge_stats: record this slot as a leader-win when eligible.
        // Observational only — does not gate or alter the forge path.
        if (ctx.leader_eligible_last) {
            forge_stats.onLeader(current_slot);
        }
    }

    // ── Praos catchup scan ──────────────────────────────────────────
    // Walk every slot in the gap [catchup_start, current_slot) and run
    // VRF + praos. If any slot wins, schedule a deferred forge for it
    // (the existing pipeline fires at slot time). Bounded by
    // MAX_CATCHUP_SLOTS so a long pause cannot burst-replay.
    if (current_slot > catchup_start and ctx.praos_enabled and
        ctx.vrf_cfg.enabled and ctx.key_cfg.enabled and ctx.genesis_parse_ok and
        !ctx.deferred_forge_pending)
    {
        const MAX_CATCHUP_SLOTS: u64 = 200;
        const gap = current_slot - catchup_start;
        const nonce_ptr_cu: ?*const [32]u8 = if (ctx.nonce_initialized) &ctx.nonce_state.epoch_nonce else null;
        var processed: u64 = 0;
        var s = catchup_start;
        while (s < current_slot and processed < MAX_CATCHUP_SLOTS) : (s += 1) {
            processed += 1;
            // Stale-slot guard: if the leader slot would be more than 5 slots
            // in the past by the time we'd forge, the deferred-fire path runs
            // immediately for slot G but with the CURRENT (much fresher) parent.
            // The forged block claims slot G with a parent whose block_no is
            // ahead of any plausible chain extending from G — cardano-node
            // rejects, opcert counter burned. Skip these slots; the lottery
            // already passed for them.
            if (s + 5 < current_slot) {
                std.debug.print("PRAOS_CATCHUP_SKIP_STALE: slot={d} current={d} gap={d}\n", .{
                    s, current_slot, current_slot - s,
                });
                continue;
            }
            const vrf_res = vrf.checkLeader(&ctx.vrf_cfg, s, nonce_ptr_cu, ctx.leader_probability_x1e6, ctx.genesis_parse_ok);
            if (!vrf_res.proof_present or !vrf_res.output_present) continue;
            const praos_cu = computePraosLeaderDecision(
                effective_sigma,
                ctx.stake_cfg.asc_x1e6,
                vrf_res.output_bytes,
                ctx.vrf_cfg.enabled,
                ctx.vrf_init_ok,
                vrf_res.output_present,
                vrf_res.output_len,
                vrf_res.verify_ok,
                ctx.key_cfg.enabled,
                ctx.genesis_parse_ok,
            );
            if (praos_cu.leader == 1) {
                std.debug.print("PRAOS_CATCHUP_LEADER: slot={d} u_x1e12={d} thresh_x1e12={d} processed={d} gap={d}\n", .{
                    s, praos_cu.u_x1e12, praos_cu.thresh_x1e12, processed, gap,
                });
                ctx.deferred_forge_slot = s;
                @memcpy(&ctx.deferred_forge_proof, &vrf_res.proof_bytes);
                @memcpy(&ctx.deferred_forge_output, &vrf_res.output_bytes);
                ctx.deferred_forge_u_x1e12 = praos_cu.u_x1e12;
                ctx.deferred_forge_thresh_x1e12 = praos_cu.thresh_x1e12;
                ctx.deferred_forge_pending = true;
                ctx.praos_catchup_leaders_total += 1;
                break;
            }
        }
        ctx.praos_catchup_processed_total +%= processed;
        if (gap > MAX_CATCHUP_SLOTS) {
            ctx.praos_catchup_truncated_total +%= 1;
            std.debug.print("PRAOS_CATCHUP_TRUNCATED: gap={d} cap={d} skipped={d} truncated_total={d} (long pause/disconnect — slots beyond cap not evaluated)\n", .{
                gap, MAX_CATCHUP_SLOTS, gap - MAX_CATCHUP_SLOTS, ctx.praos_catchup_truncated_total,
            });
        }
        if (processed > 0 and (gap > 4 or processed >= MAX_CATCHUP_SLOTS)) {
            std.debug.print("PRAOS_CATCHUP: gap={d} processed={d} cap={d}\n", .{
                gap, processed, MAX_CATCHUP_SLOTS,
            });
        }
    }

    // Slot scheduler (v1.1.0) — blake2b deterministic, no VRF prove
    if (ctx.praos_enabled and ctx.vrf_cfg.enabled and ctx.key_cfg.enabled and ctx.genesis_parse_ok) {
        if (current_slot != ctx.schedule_window_start_slot) {
            const t_start = compat.nanoTimestamp();
            const nonce_ptr_sched: ?*const [32]u8 = if (ctx.nonce_initialized) &ctx.nonce_state.epoch_nonce else null;
            const sched = slot_scheduler.computeScheduleReal(
                ctx.epoch_last,
                current_slot,
                effective_sigma,
                ctx.stake_cfg.asc_x1e6,
                ctx.genesis_parse_ok,
                &ctx.vrf_cfg,
                nonce_ptr_sched,
            );
            const t_end = compat.nanoTimestamp();
            const elapsed_us: u64 = @intCast(@max(0, @divFloor(t_end - t_start, 1000)));
            ctx.schedule_epoch_last = sched.epoch;
            ctx.schedule_window_start_slot = sched.start_slot;
            ctx.schedule_window_size = sched.window;
            ctx.schedule_leaders_in_window = sched.leaders_in_window;
            ctx.schedule_next_leader_offset = sched.next_leader_offset;
            ctx.schedule_u0_x1e12 = sched.u_x1e12_first;
            ctx.schedule_t_x1e12 = sched.thresh_x1e12_first;
            ctx.schedule_reason_code_last = 0;
            ctx.schedule_compute_total += 1;
            ctx.schedule_compute_us_total += elapsed_us;
            ctx.schedule_last_slot = current_slot;
            ctx.schedule_last_update_us = @intCast(@max(0, @divFloor(t_end, 1000)));
        }
    } else {
        ctx.schedule_reason_code_last = if (!ctx.vrf_cfg.enabled or !ctx.vrf_output_present_last) 1
            else if (effective_sigma == 0) 2
            else if (!ctx.genesis_parse_ok) 3
            else 1;
    }

    // KES period gate (v1.0.2, enhanced v1.1.2)
    applyKesPeriod(ctx, current_slot);

    // KES interface (stub signing, no real crypto)
    const kes_res = kes.signStub(&ctx.kes_cfg, "producer_tick");
    if (kes_res.attempted) ctx.kes_attempt_total += 1;
    ctx.kes_sig_present_last = if (kes_res.sig_present) @as(u64, 1) else @as(u64, 0);
    ctx.kes_reason_code_last = @as(u64, kes_res.reason_code);

    // Diagnostic: log decision truth for every tick
    if (ctx.praos_checks_total > 0 and ctx.praos_checks_total % 30 == 1) {
        std.debug.print("FORGE_DECISION_TRUTH: slot={d} epoch={d} slot_in_epoch={d} leader_eligible={} praos_leader={d} reason_code={d} dryrun_enabled={} u_x1e12={d} thresh_x1e12={d} sched_leaders={d} sched_next_offset={d}\n", .{
            current_slot, ctx.epoch_last, ctx.slot_in_epoch_last,
            ctx.leader_eligible_last, ctx.praos_leader_last, ctx.praos_reason_code_last,
            ctx.dryrun_enabled, ctx.praos_u_x1e12_last, ctx.praos_thresh_x1e12_last,
            ctx.schedule_leaders_in_window, ctx.schedule_next_leader_offset,
        });
        const sigma_source_label: []const u8 = if (ctx.ledger_sigma_valid and ctx.ledger_sigma_x1e9 > 0)
            (switch (ctx.ledger_sigma_source_kind) {
                2 => "ledger",
                1 => "bootstrap",
                else => "env",
            })
        else
            "env";
        std.debug.print("PRAOS_STATE: slot={d} epoch_nonce={x} nonce_epoch={d} sigma={d} sigma_source={s}(kind={d}) leader={} catchup_total={d} catchup_leaders={d} vrf_skipped={d}\n", .{
            current_slot, &ctx.nonce_state.epoch_nonce, ctx.nonce_state.nonce_epoch,
            effective_sigma,
            sigma_source_label,
            ctx.ledger_sigma_source_kind,
            ctx.praos_leader_last == 1,
            ctx.praos_catchup_processed_total,
            ctx.praos_catchup_leaders_total,
            ctx.vrf_skipped_total,
        });
        // Variant B telemetry: which sigma the authoritative resolver selected.
        std.debug.print("SIGMA_AUTHORITATIVE: sigma_authoritative={d} sigma_source={s} sigma_fallback_reason={s}\n", .{
            sigma_res.sigma_x1e9,
            sigma_res.source.name(),
            if (sigma_res.fallback_reason.len == 0) "none" else sigma_res.fallback_reason,
        });
        // Phase 8.1: update node_state for /status endpoint
        node_state.updateConsensus(ctx.nonce_state.nonce_epoch, effective_sigma, ctx.praos_leader_last == 1);
        // Phase 8.5: emit EVENT_LEADER_IMMINENT at T-120s to any cached leader.
        leader_schedule.checkImminent(current_slot);
        // Phase 8.7: adaptive tick (detects rejection-by-timeout, throttled log).
        adaptive.onTick(current_slot);
        // Phase 8.8: throttled peer-score log.
        peer_score.maybeLog();
        // Phase 9: throttled decision-metrics log.
        decision.maybeLog();
        // Phase 8.65: throttled signal layer log.
        signals.maybeLog();
        // Phase 9.5: continuous visibility — PREARM_STATE heartbeat.
        prearm.maybeLogState();
        // Phase 9.1: multi-probe health sweep — mark stale peers disconnected.
        multi_probe.tickHealth();
        // Phase 8.95: pre-arm stage transitions (observability-only, reads rx_* under no lock — OK for read-only).
        {
            const rx_block_snap = ctx.rx_block_last;
            const rx_slot_snap = ctx.rx_slot_last;
            const eq_for_probe = exec_quality.currentScore();
            const probe_wins = eq_for_probe.probe_advantage >= 50;
            prearm.onTick(current_slot, rx_block_snap, rx_slot_snap, probe_wins);

            // Phase 9.1: Log best-tip attribution when pre-arm is active.
            // This is observational — the actual rx_* fields already reflect
            // the freshest tip from any peer (primary or probe) via
            // updateRxFromPeer's monotonic merge.
            if (prearm.g_state.armed and prearm.g_state.stage != .idle) {
                var bt: multi_probe.BestTip = .{};
                if (multi_probe.g_bias_enabled) {
                    const notice_ms_global: u32 = blk: {
                        presence.g_state.mu.lock();
                        defer presence.g_state.mu.unlock();
                        break :blk presence.g_state.avg_notice_ms;
                    };
                    bt = multi_probe.getBestBiasedTip(notice_ms_global);
                    if (bt.valid) {
                        std.debug.print("PEER_SELECTED: slot={d} peer={d} score={d:.4}\n", .{
                            prearm.g_state.target_slot, bt.peer_id, bt.score,
                        });
                    } else {
                        bt = multi_probe.getBestTip(); // fallback: unbiased
                    }
                } else {
                    bt = multi_probe.getBestTip();
                }
                if (bt.valid) {
                    std.debug.print("PREARM_BEST_TIP: slot={d} block={d} peer_id={d} latency={d}\n", .{
                        bt.slot, bt.block, bt.peer_id, bt.latency_ms,
                    });
                }
            }
        }
    }

    // Header candidate v2 pipeline (NO forging, NO broadcast)
    // Guard: candidate slot must be strictly after parent slot
    if (current_slot <= parent_slot and !ctx.deferred_forge_executing) return;
    if (ctx.leader_eligible_last) {
        // Decode pool_id_hex to bytes (28 or 32 bytes, right-pad to 32)
        var pool_id_bytes: [32]u8 = [_]u8{0} ** 32;
        if (ctx.key_cfg.pool_id_hex) |pid| {
            _ = std.fmt.hexToBytes(&pool_id_bytes, pid) catch {};
        }

        // VRF output prefix as 8 bytes
        var vrf_prefix_bytes: [8]u8 = [_]u8{0} ** 8;
        if (ctx.vrf_output_present_last) {
            std.mem.writeInt(u64, &vrf_prefix_bytes, ctx.vrf_output_prefix_last, .big);
        }

        // Block body builder v1 (v0.9.9) — canonical CBOR empty body + real body hash
        const body = body_candidate.buildEmptyBodyV1(
            @as(u32, @intCast(ctx.genesis_network_magic)),
            current_slot,
            parent_block_no,
            parent_hash,
        );
        ctx.body_cbor_len_last = body.cbor_len;
        ctx.body_hash_w0 = std.mem.readInt(u64, body.body_hash[0..8], .big);
        ctx.body_hash_w1 = std.mem.readInt(u64, body.body_hash[8..16], .big);
        ctx.body_hash_w2 = std.mem.readInt(u64, body.body_hash[16..24], .big);
        ctx.body_hash_w3 = std.mem.readInt(u64, body.body_hash[24..32], .big);
        @memcpy(&ctx.body_cbor_bytes_last, &body.cbor_bytes);
        ctx.body_artifact_dirty = true;

        const cand = header_candidate.buildCandidateV2(
            @as(u32, @intCast(ctx.genesis_network_magic)),
            ctx.epoch_last,
            current_slot,
            ctx.slot_in_epoch_last,
            parent_block_no,
            parent_hash,
            ctx.state_digest,
            vrf_prefix_bytes,
            pool_id_bytes,
            body.body_hash,
        );

        ctx.candidate_built_total += 1;
        ctx.candidate_last_slot = current_slot;
        ctx.candidate_body_hash_prefix_last = std.mem.readInt(u64, body.body_hash[0..8], .big);
        ctx.candidate_hdr_bytes_len = cand.bytes_len;
        ctx.candidate_hdr_hash_w0 = std.mem.readInt(u64, cand.header_hash[0..8], .big);
        ctx.candidate_hdr_hash_w1 = std.mem.readInt(u64, cand.header_hash[8..16], .big);
        ctx.candidate_hdr_hash_w2 = std.mem.readInt(u64, cand.header_hash[16..24], .big);
        ctx.candidate_hdr_hash_w3 = std.mem.readInt(u64, cand.header_hash[24..32], .big);

        // Pure Zig Ed25519 detached signing (v0.9.4, observability only)
        {
            const msg32: [32]u8 = cand.header_hash;
            const seed32: [32]u8 = pool_id_bytes;
            ctx.zig_sig_attempt_total += 1;
            const sig_res = zig_ed25519.signHash32(msg32, seed32);
            ctx.zig_sig_present_last = if (sig_res.sig_present) 1 else 0;
            ctx.zig_sig_reason_last = sig_res.reason_code;
            if (sig_res.ok) {
                ctx.zig_sig_ok_total += 1;
                ctx.zig_sig_prefix_last = std.mem.readInt(u64, sig_res.sig[0..8], .big);
            }
        }

        // KES candidate signing pipeline (v0.9.5+v0.9.7+v1.8.7, observability only — NO forging)
        // v1.0.2: gate signing on KES period validity
        // v1.8.7: real Sum6Kes signing for cardano_kes keys
        if (ctx.kes_sign_enabled and ctx.kes_period_valid_last == 1) {
            if (ctx.kes_key_kind == .cardano_kes and ctx.kes_key_state_len > 0) {
                // v1.8.7+v1.8.8: Real Sum6Kes signing with key evolution
                ctx.kes_sign_attempt_total += 1;

                // Compute KES period offset
                const kes_period_offset: u32 = @intCast(ctx.kes_current_period_last - ctx.kes_start_period);

                // v1.8.8: Evolve key state to target period if needed
                if (ctx.kes_key_evolved_offset != kes_period_offset) {
                    const current_key_period = std.mem.readInt(u32, ctx.kes_key_state[kes_sign.SK_SIZE_6..][0..4], .big);
                    if (current_key_period > kes_period_offset) {
                        std.debug.print("FATAL: KES key period ({d}) > target offset ({d}), cannot devolve\n", .{ current_key_period, kes_period_offset });
                        std.process.exit(97);
                    }
                    if (current_key_period < kes_period_offset) {
                        kes_evolve.evolveToOffset(&ctx.kes_key_state, ctx.kes_key_state_len, current_key_period, kes_period_offset) catch {
                            std.debug.print("FATAL: KES key evolution failed ({d} -> {d})\n", .{ current_key_period, kes_period_offset });
                            std.process.exit(97);
                        };
                        std.debug.print("KES EVOLVE: {d} -> {d} OK\n", .{ current_key_period, kes_period_offset });
                    }
                    ctx.kes_key_evolved_offset = kes_period_offset;
                }

                // Build CBOR header body (the signed message)
                const hdr_body = cbor_header_body.buildHeaderBodyCbor(
                    parent_block_no + 1,
                    current_slot,
                    parent_hash,
                    body.body_hash,
                );

                // Sign
                var kes_sig: [kes_sign.SUM6_KES_SIG_LEN]u8 = undefined;
                var key_period: u32 = 0;
                kes_sign.signSum6Kes(
                    ctx.kes_key_state[0..ctx.kes_key_state_len],
                    hdr_body.bytes[0..hdr_body.len],
                    &kes_sig,
                    &key_period,
                ) catch {
                    std.debug.print("FATAL: Sum6Kes signing failed\n", .{});
                    std.process.exit(97);
                };

                // Validate period matches
                if (key_period != kes_period_offset) {
                    std.debug.print("FATAL: KES key period ({d}) != expected offset ({d})\n", .{ key_period, kes_period_offset });
                    std.process.exit(97);
                }

                // Immediate self-verify
                const root_pk = kes_sign.extractRootPk(ctx.kes_key_state[0..ctx.kes_key_state_len]) catch {
                    std.debug.print("FATAL: cannot extract KES root PK\n", .{});
                    std.process.exit(97);
                };
                const vr = kes_verify.verifySum6Kes(root_pk, kes_period_offset, hdr_body.bytes[0..hdr_body.len], &kes_sig);
                if (vr != .ok) {
                    std.debug.print("FATAL: KES sig failed self-verify: {s}\n", .{kes_verify.resultStr(vr)});
                    std.process.exit(97);
                }

                @memcpy(&ctx.candidate_last_kes_sig, &kes_sig);
                ctx.kes_sign_ok_total += 1;
                ctx.kes_sign_present_last = 1;
                ctx.kes_sign_prefix_last = std.mem.readInt(u64, kes_sig[0..8], .big);
                ctx.kes_sign_label_last = 2; // real_kes
                ctx.candidate_signed_total += 1;
                ctx.candidate_sig_present_last = 1;
                ctx.candidate_sig_prefix_last = std.mem.readInt(u64, kes_sig[0..8], .big);
                ctx.candidate_sign_reason_code_last = 0; // ok
                @memcpy(&ctx.candidate_last_hdr_bytes, &cand.bytes);
                ctx.candidate_sign_dirty = true;
            } else if (ctx.kes_sign_seed) |seed| {
                // Existing placeholder Ed25519 path (unchanged)
                ctx.kes_sign_attempt_total += 1;
                const ks_res = kes_placeholder.signCandidateBytes(seed, &cand.bytes);
                ctx.kes_sign_present_last = if (ks_res.ok) 1 else 0;
                ctx.kes_sign_reason_last = @as(u64, ks_res.reason);
                if (ks_res.ok) {
                    ctx.kes_sign_ok_total += 1;
                    ctx.kes_sign_prefix_last = ks_res.prefix_u64;
                    ctx.kes_sign_label_last = 1; // placeholder_ed25519
                    // v0.9.7: candidate signing proof
                    ctx.candidate_signed_total += 1;
                    ctx.candidate_sig_present_last = 1;
                    ctx.candidate_sig_prefix_last = ks_res.prefix_u64;
                    ctx.candidate_sign_reason_code_last = 0; // ok
                    @memcpy(&ctx.candidate_last_hdr_bytes, &cand.bytes);
                    @memcpy(&ctx.candidate_last_sig_bytes, &ks_res.sig);
                    ctx.candidate_sign_dirty = true;
                } else {
                    ctx.candidate_sig_present_last = 0;
                    ctx.candidate_sign_reason_code_last = 5; // sign_fail
                    ctx.kes_sign_refused_total += 1;
                }
            } else {
                ctx.candidate_sig_present_last = 0;
                ctx.candidate_sign_reason_code_last = 3; // missing_seed
                ctx.kes_sign_refused_total += 1;
            }
        } else if (ctx.kes_sign_enabled and ctx.kes_period_valid_last != 1) {
            ctx.kes_sign_present_last = 0;
            ctx.kes_sign_reason_last = 7; // kes_period_invalid
            ctx.candidate_sig_present_last = 0;
            ctx.candidate_sign_reason_code_last = 7; // kes_period_invalid
            ctx.kes_out_of_range_total += 1;
            ctx.kes_sign_refused_total += 1;
        } else {
            ctx.kes_sign_present_last = 0;
            ctx.kes_sign_reason_last = 1; // disabled
            ctx.candidate_sig_present_last = 0;
            ctx.candidate_sign_reason_code_last = 1; // disabled
        }

        std.debug.print("PRODUCER CANDIDATE V2: slot={d} epoch={d} hdr_len={d} hdr=0x{x:0>16}{x:0>16} body_len={d} body=0x{x:0>16}{x:0>16}\n", .{
            current_slot, ctx.epoch_last, cand.bytes_len, ctx.candidate_hdr_hash_w0, ctx.candidate_hdr_hash_w1, ctx.body_cbor_len_last, ctx.body_hash_w0, ctx.body_hash_w1,
        });
        ctx.pack_dirty = true;

        // v1.8.0: Dryrun artifact write + local verify
        if (ctx.dryrun_enabled) {
            ctx.dryrun_leader_slots += 1;
            ctx.dryrun_last_leader_slot = current_slot;
            const artifact_unix: u64 = if (now_unix > 0) @intCast(now_unix) else 0;

            if (ctx.dryrun_home_dir) |base_dir| {
                var dir_buf: [512]u8 = undefined;
                const dir_name = std.fmt.bufPrint(&dir_buf, "{s}/{d}_{d}", .{ base_dir, artifact_unix, current_slot }) catch "";

                if (dir_name.len > 0) {
                    compat.fs.cwd().makePath(dir_name) catch {};

                    // Write header.cbor (raw 198 bytes)
                    _ = dryrunWriteFile(dir_name, "header.cbor", &cand.bytes);

                    // Write header_hash.hex (64 hex chars)
                    const hdr_hash_hex = std.fmt.bytesToHex(cand.header_hash, .lower);
                    _ = dryrunWriteFile(dir_name, "header_hash.hex", &hdr_hash_hex);

                    // Write body_hash.hex (64 hex chars)
                    const body_hash_hex = std.fmt.bytesToHex(body.body_hash, .lower);
                    _ = dryrunWriteFile(dir_name, "body_hash.hex", &body_hash_hex);

                    // v1.8.7: Write header_body.cbor + signature.bin based on key kind
                    const is_real_kes = (ctx.kes_key_kind == .cardano_kes and ctx.candidate_sign_dirty);
                    if (is_real_kes) {
                        // Write header_body.cbor (CBOR header body — the signed message)
                        const hdr_body = cbor_header_body.buildHeaderBodyCbor(
                            parent_block_no + 1, current_slot, parent_hash, body.body_hash,
                        );
                        _ = dryrunWriteFile(dir_name, "header_body.cbor", hdr_body.bytes[0..hdr_body.len]);
                        // Write signature.bin (448 bytes, real Sum6Kes)
                        _ = dryrunWriteFile(dir_name, "signature.bin", &ctx.candidate_last_kes_sig);
                    } else {
                        // Write signature.bin (64 bytes, placeholder Ed25519 or empty)
                        _ = dryrunWriteFile(dir_name, "signature.bin", &ctx.candidate_last_sig_bytes);
                    }

                    // Local verification
                    var verify_hash_match = false;
                    var verify_sig_ok = false;
                    {
                        var recomp_hash: [32]u8 = undefined;
                        Blake2b256.hash(&cand.bytes, &recomp_hash, .{});
                        verify_hash_match = std.mem.eql(u8, &recomp_hash, &cand.header_hash);
                    }
                    if (is_real_kes) {
                        // Already verified in signing pipeline (FATAL if fail)
                        verify_sig_ok = true;
                        ctx.dryrun_candidates_signed += 1;
                        ctx.dryrun_last_sign_verify_ok = 1;
                    } else if (ctx.kes_sign_enabled and ctx.candidate_sign_dirty) {
                        if (ctx.kes_sign_seed) |seed| {
                            const kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch null;
                            if (kp) |keypair| {
                                const sig = std.crypto.sign.Ed25519.Signature.fromBytes(ctx.candidate_last_sig_bytes);
                                sig.verify(&cand.bytes, keypair.public_key) catch {
                                    verify_sig_ok = false;
                                };
                                verify_sig_ok = true;
                            }
                        }
                    }

                    const sig_kind_str: []const u8 = if (is_real_kes)
                        "real_kes"
                    else if (ctx.kes_sign_enabled and ctx.candidate_sign_dirty)
                        "placeholder_ed25519"
                    else
                        "none";
                    const pool_id_hex_str: []const u8 = if (ctx.key_cfg.pool_id_hex) |pid| pid else "";

                    ctx.dryrun_candidates_built += 1;
                    ctx.dryrun_candidates_verified += 1;
                    ctx.dryrun_last_candidate_unix = artifact_unix;
                    ctx.dryrun_last_verify_ok = if (verify_hash_match and (verify_sig_ok or !ctx.kes_sign_enabled)) @as(u64, 1) else 0;

                    // v1.8.7: compute kes_pk_hex and kes_period_offset for meta.json
                    var kes_pk_hex_buf: [64]u8 = [_]u8{'0'} ** 64;
                    var kes_period_offset_val: i64 = -1;
                    if (is_real_kes) {
                        const pk = kes_sign.extractRootPk(ctx.kes_key_state[0..ctx.kes_key_state_len]) catch [_]u8{0} ** 32;
                        kes_pk_hex_buf = std.fmt.bytesToHex(pk, .lower);
                        kes_period_offset_val = @intCast(ctx.kes_current_period_last - ctx.kes_start_period);
                    }

                    // Write meta.json (v1.8.7: kes_pk_hex and kes_period_offset filled for real_kes)
                    {
                        var meta_buf: [2048]u8 = undefined;
                        const meta_json = std.fmt.bufPrint(&meta_buf,
                            \\{{"unix":{d},"net":"{s}","slot":{d},"block_no":{d},"leader":true,"u_x1e12":{d},"t_x1e12":{d},"kes_period":{d},"kes_valid":{d},"sig_kind":"{s}","candidate_version":"TSUNAGI_HDR_CANDIDATE_V2","pool_id_hex":"{s}","kes_pk_hex":"{s}","kes_period_offset":{d},"signed_msg_mode":"direct"}}
                        , .{
                            artifact_unix,
                            if (ctx.dryrun_net_name) |n| n else "unknown",
                            current_slot,
                            parent_block_no + 1,
                            ctx.praos_u_x1e12_last,
                            ctx.praos_thresh_x1e12_last,
                            ctx.kes_current_period_last,
                            ctx.kes_period_valid_last,
                            sig_kind_str,
                            pool_id_hex_str,
                            @as([]const u8, &kes_pk_hex_buf),
                            kes_period_offset_val,
                        }) catch "";
                        if (meta_json.len > 0) _ = dryrunWriteFile(dir_name, "meta.json", meta_json);
                    }

                    // Write verify.json
                    {
                        var vfy_buf: [256]u8 = undefined;
                        const vfy_json = std.fmt.bufPrint(&vfy_buf,
                            \\{{"hash_match":{s},"sig_verify_ok":{s},"sig_kind":"{s}"}}
                        , .{
                            if (verify_hash_match) "true" else "false",
                            if (verify_sig_ok) "true" else "false",
                            sig_kind_str,
                        }) catch "";
                        if (vfy_json.len > 0) _ = dryrunWriteFile(dir_name, "verify.json", vfy_json);
                    }

                    std.debug.print("PRODUCER DRYRUN: artifacts written slot={d} hash_ok={} sig_ok={} sig_kind={s} dir={s}\n", .{ current_slot, verify_hash_match, verify_sig_ok, sig_kind_str, dir_name });

                    // v2.0.0-alpha: Full Cardano block candidate (block era tag 7, 10-element header body)
                    if (ctx.dryrun_block_enabled and is_real_kes and ctx.vrf_cfg.pk != null and ctx.vrf_output_present_last) {
                        const vrf_pk = ctx.vrf_cfg.pk.?;

                        // 1. Build body — embed txs if available (v2.1.2), otherwise empty
                        const empty_body = cbor_block_body.buildEmptyBody();

                        // v2.1.0-a: Export mempool txs for inclusion.
                        // Pass live protocol max_block_body_size so the mempool
                        // selector caps body size proactively (no wasted slot
                        // on a post-hoc size_exceeded reject). 90112 fallback
                        // matches Babbage/Conway default until params load.
                        const protocol_body_cap_pre: u64 = if (mempool_mod.g_protocol_params) |pp|
                            (if (pp.max_block_body_size > 0) pp.max_block_body_size else 90112)
                        else
                            90112;
                        var included_exports: ?[]mempool_mod.DryrunExportItem = null;
                        defer if (included_exports) |e| std.heap.page_allocator.free(e);
                        if (ctx.dryrun_mempool) |mp| {
                            included_exports = mp.exportForDryrunBlock(std.heap.page_allocator, ctx.dryrun_block_max_tx, ctx.dryrun_block_max_bytes, protocol_body_cap_pre);
                        }

                        // Phase 30: Forge-path execution gate with policy control.
                        // Policy: off (skip gate entirely), observe (log only), enforce_safe (skip invalid txs).
                        // Uncertain cases (unsupported, evaluator_unavailable) always pass through.

                        // Max candidate tx count — matches current dry-run candidate ceiling.
                        const FORGE_GATE_MAX_TX = 50;
                        var fg_skip: [FORGE_GATE_MAX_TX]bool = .{false} ** FORGE_GATE_MAX_TX;
                        // Phase 43: Hoisted for use in reorder-aware decompose loop.
                        const RankEntry = struct { idx: u32, score: u32 };
                        var rk_entries: [FORGE_GATE_MAX_TX]RankEntry = undefined;
                        var rk_count: u32 = 0;
                        var reorder_active = ctx.forge_gate_policy == .reorder;
                        // Phase 46: Hoisted for aggregate use across blocks.
                        var last_forge_sig = trust_signal.ForgeSignalSnapshot{};

                        if (ctx.forge_gate_policy != .off) {
                            if (included_exports) |exports| {
                                const is_enforce = ctx.forge_gate_policy == .enforce_safe or ctx.forge_gate_policy == .reorder
                                    or (ctx.policy_experiment_enforcement and ctx.forge_preview_only);
                                var fg_not_applicable: u32 = 0;
                                var fg_passed: u32 = 0;
                                var fg_failed: u32 = 0;
                                var fg_unsupported: u32 = 0;
                                var fg_evaluator_unavailable: u32 = 0;
                                var fg_skipped: u32 = 0;
                                var fg_script_failed: u32 = 0;
                                var fg_missing_context: u32 = 0;
                                var fg_invalid_redeemer: u32 = 0;
                                // Phase 31: Ranking counters (observation only, no reordering)
                                var rk_passed_cost_low: u32 = 0;
                                var rk_passed_cost_medium: u32 = 0;
                                var rk_passed_cost_high: u32 = 0;
                                var rk_no_cost: u32 = 0;
                                for (exports, 0..) |exp, idx| {
                                    // Single evaluation: rank wraps gate
                                    const rank = forge_gate.rankTxForForgePath(exp.tx_bytes);
                                    const detail = rank.gate;
                                    // Collect rank entries for dry-run ordering
                                    if (rk_count < FORGE_GATE_MAX_TX) {
                                        rk_entries[rk_count] = .{ .idx = @intCast(idx), .score = rank.score };
                                        rk_count += 1;
                                    }
                                    // Ranking buckets
                                    switch (rank.cost_class) {
                                        .low => rk_passed_cost_low += 1,
                                        .medium => rk_passed_cost_medium += 1,
                                        .high => rk_passed_cost_high += 1,
                                        .none => rk_no_cost += 1,
                                    }
                                    // Gate counters
                                    switch (detail.result) {
                                        .not_applicable => fg_not_applicable += 1,
                                        .passed => fg_passed += 1,
                                        .failed => {
                                            fg_failed += 1;
                                            switch (detail.error_code) {
                                                .script_failed => fg_script_failed += 1,
                                                .missing_context => fg_missing_context += 1,
                                                .invalid_redeemer => fg_invalid_redeemer += 1,
                                                else => {},
                                            }
                                            if (is_enforce and idx < FORGE_GATE_MAX_TX) {
                                                switch (detail.error_code) {
                                                    .script_failed, .missing_context, .invalid_redeemer => {
                                                        fg_skip[idx] = true;
                                                        fg_skipped += 1;
                                                    },
                                                    else => {},
                                                }
                                            }
                                        },
                                        .unsupported => fg_unsupported += 1,
                                        .evaluator_unavailable => fg_evaluator_unavailable += 1,
                                    }
                                }
                                const policy_name = switch (ctx.forge_gate_policy) {
                                    .observe => "observe",
                                    .enforce_safe => "enforce_safe",
                                    .reorder => "reorder",
                                    .off => "off",
                                };
                                std.debug.print("FORGE_GATE: policy={s} checked={d} not_applicable={d} passed={d} failed={d} unsupported={d} evaluator_unavailable={d} script_failed={d} missing_context={d} invalid_redeemer={d} skipped={d}\n", .{
                                    policy_name, exports.len, fg_not_applicable, fg_passed, fg_failed, fg_unsupported, fg_evaluator_unavailable, fg_script_failed, fg_missing_context, fg_invalid_redeemer, fg_skipped,
                                });
                                std.debug.print("FORGE_RANK: checked={d} passed_cost_low={d} passed_cost_medium={d} passed_cost_high={d} no_cost={d}\n", .{
                                    exports.len, rk_passed_cost_low, rk_passed_cost_medium, rk_passed_cost_high, rk_no_cost,
                                });

                                // Phase 32: Dry-run ordering simulation (no actual reordering)
                                // Sort by score descending; break ties by lower original index first.
                                std.mem.sort(RankEntry, rk_entries[0..rk_count], {}, struct {
                                    fn order(_: void, a: RankEntry, b: RankEntry) bool {
                                        if (a.score != b.score) return a.score > b.score;
                                        return a.idx < b.idx;
                                    }
                                }.order);
                                const top_n = @min(rk_count, 5);
                                if (top_n > 0) {
                                    std.debug.print("FORGE_RANK_ORDER (dry-run):", .{});
                                    for (rk_entries[0..top_n]) |e| {
                                        std.debug.print(" idx={d} score={d}", .{ e.idx, e.score });
                                    }
                                    std.debug.print("\n", .{});
                                }

                                // Phase 42: External evaluation observe-only (summary only).
                                // Invokes known-case external boundary check per tx.
                                // No enforcement, no reordering, no per-tx logging.
                                var ext_supported_pass: u32 = 0;
                                var ext_supported_fail: u32 = 0;
                                var ext_backend_unavailable: u32 = 0;
                                var ext_case_not_supported: u32 = 0;
                                var ext_invalid_response: u32 = 0;
                                for (exports) |exp| {
                                    const eb = eval_external.evaluateKnownCaseExternal(exp.tx_bytes);
                                    switch (eb.result) {
                                        .supported_pass => ext_supported_pass += 1,
                                        .supported_fail => ext_supported_fail += 1,
                                        .backend_unavailable => ext_backend_unavailable += 1,
                                        .case_not_supported => ext_case_not_supported += 1,
                                        .invalid_response => ext_invalid_response += 1,
                                    }
                                }
                                std.debug.print("FORGE_EXTERNAL: checked={d} supported_pass={d} supported_fail={d} backend_unavailable={d} case_not_supported={d} invalid_response={d}\n", .{
                                    exports.len, ext_supported_pass, ext_supported_fail, ext_backend_unavailable, ext_case_not_supported, ext_invalid_response,
                                });

                                // Phase 44: Trust signal — encode observed outcomes as evidence.
                                // Observe-only. No scoring, no BAeY, no EV/Kelly/LLR yet.
                                last_forge_sig = trust_signal.buildForgeSignal(
                                    @intCast(exports.len),
                                    ext_supported_pass,
                                    ext_supported_fail,
                                    ext_backend_unavailable,
                                    ext_case_not_supported,
                                    ext_invalid_response,
                                );
                                last_forge_sig.emitSummary(compat.fs.stderrWriter());

                                // Phase 45: Belief state — structure evidence for future BAeY.
                                // Observe-only. No posterior math, no scoring, no adaptive behavior.
                                const belief = belief_state.buildBeliefFromSignal(&last_forge_sig);
                                belief.emitSummary(compat.fs.stderrWriter());
                            }

                            // Phase 45: Mempool validation trust signal (second source).
                            // Reads existing mempool counters. No mutation. Observe-only.
                            var mp_sig = trust_signal.MempoolSignalSnapshot{};
                            if (ctx.dryrun_mempool) |mp| {
                                mp_sig = trust_signal.buildMempoolSignal(mp);
                                mp_sig.emitSummary(compat.fs.stderrWriter());
                            }

                            // Phase 46: Aggregate evidence across sources.
                            // Consumes the forge signal (if available) and mempool signal.
                            // No scoring, no weighting, no decision authority.
                            const agg = trust_aggregate.buildAggregate(&last_forge_sig, &mp_sig);
                            agg.emitEntries(compat.fs.stderrWriter());

                            // Phase 47: Simple pre-Bayesian trust score.
                            // Observe-only. No adaptive behavior, no BAeY/EV/Kelly/LLR.
                            const ts = trust_score.buildScore(&agg);
                            ts.emitSummary(compat.fs.stderrWriter());

                            // Phase 48: BAeY / EV / Kelly / LLR decision metrics.
                            // Observe-only. No adaptive behavior, no policy mutation.
                            const dm = decision_metrics.buildMetrics(&ts);
                            dm.emitSummary(compat.fs.stderrWriter());

                            // Phase 49: Observe-only decision advisory.
                            // Answers "what would the node conclude?" — not "what will it do?"
                            const adv = decision_advisory.buildAdvisory(&dm);
                            adv.emitSummary(compat.fs.stderrWriter());

                            // Phase 50: Shadow policy preview.
                            // Answers "what policy would the node prefer?" — not "what will it do?"
                            const pp = policy_preview.buildPreview(&adv);
                            pp.emitSummary(compat.fs.stderrWriter());

                            // Phase 51: Shadow policy impact simulation.
                            // "If this policy were active, what domain would it touch?"
                            const pi = policy_impact.buildImpact(&pp);
                            pi.emitSummary(compat.fs.stderrWriter());

                            // Phase 52: Preview-only policy-coupled ordering experiment.
                            // Uses pure helper with real preview guard (forge_preview_only).
                            const apply_result = policy_apply.shouldActivateOrdering(
                                ctx.policy_experiment_ordering,
                                ctx.forge_preview_only,
                                &pi,
                            );
                            if (apply_result.active) reorder_active = true;
                            policy_apply.emitApplySummary(&apply_result, compat.fs.stderrWriter());

                            // Phase 54: Preview-only policy-coupled enforcement experiment.
                            // Phase 54: Enforcement experiment evaluation.
                            // Activation is at `is_enforce` declaration (flag + preview guard).
                            // This evaluates whether current evidence supports it.
                            const enforce_apply_result = policy_apply.shouldActivateEnforcement(
                                ctx.policy_experiment_enforcement,
                                ctx.forge_preview_only,
                                &pi,
                            );
                            policy_apply.emitEnforcementApplySummary(&enforce_apply_result, compat.fs.stderrWriter());

                            // Phase 53: Write decision stack state for operator surfaces.
                            decision_state.g_decision_state = .{
                                .trust_positive = ts.positive,
                                .trust_negative = ts.negative,
                                .trust_neutral = ts.neutral,
                                .trust_score = ts.score,
                                .alpha = dm.alpha,
                                .beta = dm.beta_,
                                .posterior_x1e6 = dm.posterior_mean_x1e6,
                                .ev_x1e6 = dm.ev_x1e6,
                                .kelly_x1e6 = dm.kelly_x1e6,
                                .llr_x1e6 = dm.llr_x1e6,
                                .stance = @intFromEnum(adv.stance),
                                .confidence = @intFromEnum(adv.confidence),
                                .allocation = @intFromEnum(adv.allocation),
                                .recommendation = @intFromEnum(pp.recommendation),
                                .strength = @intFromEnum(pp.strength),
                                .impact_kind = @intFromEnum(pi.impact_kind),
                                .touch_ordering = pi.touch_ordering,
                                .touch_enforcement = pi.touch_enforcement,
                                .touch_mempool = pi.touch_mempool,
                                .apply_active = apply_result.active,
                                .enforce_apply_active = enforce_apply_result.active,
                                .experiment_ordering_enabled = ctx.policy_experiment_ordering,
                                .experiment_enforcement_enabled = ctx.policy_experiment_enforcement,
                                .preview_guard_passed = ctx.forge_preview_only,
                                .cycle_unix = compat.timestamp(),
                            };
                        }

                        // v2.1.2: Decompose txs and build body with tx embedding
                        var dyn_body: ?cbor_block_body.DynBodyResult = null;
                        defer if (dyn_body) |db| {
                            std.heap.page_allocator.free(db.tx_bodies_cbor);
                            std.heap.page_allocator.free(db.witnesses_cbor);
                            std.heap.page_allocator.free(db.aux_data_cbor);
                        };
                        if (included_exports) |exports| {
                            if (exports.len > 0) {
                                var body_slices = std.array_list.Managed([]const u8).init(std.heap.page_allocator);
                                defer body_slices.deinit();
                                var wit_slices = std.array_list.Managed([]const u8).init(std.heap.page_allocator);
                                defer wit_slices.deinit();
                                // Per-tx auxiliary_data (Conway tx element [3]); null for
                                // metadata-free txs. Kept in lockstep with body_slices.
                                var aux_slices = std.array_list.Managed(?[]const u8).init(std.heap.page_allocator);
                                defer aux_slices.deinit();

                                // Phase 43: When reorder is active, iterate by ranked order.
                                // Otherwise, iterate by original export order (default).
                                const use_count = if (reorder_active and rk_count > 0) rk_count else @as(u32, @intCast(exports.len));
                                var reorder_changed: bool = false;
                                const first_before: u32 = 0;
                                var first_after: u32 = 0;
                                if (reorder_active and rk_count > 0) {
                                    first_after = rk_entries[0].idx;
                                    if (first_after != first_before) reorder_changed = true;
                                }
                                var iter_i: u32 = 0;
                                while (iter_i < use_count) : (iter_i += 1) {
                                    const idx: usize = if (reorder_active and rk_count > 0)
                                        rk_entries[iter_i].idx
                                    else
                                        iter_i;
                                    if (idx < FORGE_GATE_MAX_TX and fg_skip[idx]) continue;
                                    const exp = exports[idx];
                                    const parts = block_hash.decomposeTx(exp.tx_bytes) orelse continue;
                                    body_slices.append(parts.tx_body) catch continue;
                                    wit_slices.append(parts.witnesses) catch {
                                        _ = body_slices.pop();
                                        continue;
                                    };
                                    aux_slices.append(parts.aux_data) catch {
                                        _ = body_slices.pop();
                                        _ = wit_slices.pop();
                                        continue;
                                    };
                                }
                                if (reorder_active) {
                                    std.debug.print("FORGE_REORDER: enabled=1 checked={d} changed={d}\n", .{
                                        use_count, @as(u32, if (reorder_changed) 1 else 0),
                                    });
                                }

                                if (body_slices.items.len > 0) {
                                    dyn_body = cbor_block_body.buildBodyWithTxSlices(
                                        std.heap.page_allocator,
                                        body_slices.items,
                                        wit_slices.items,
                                        aux_slices.items,
                                    );
                                    if (dyn_body != null) {
                                        std.debug.print("DRYRUN: {d} txs embedded in block body\n", .{body_slices.items.len});
                                    }
                                }
                            }
                        }

                        const use_body_hash: [32]u8 = if (dyn_body) |db| db.body_hash else empty_body.body_hash;
                        const use_body_size: u64 = if (dyn_body) |db| db.body_size else empty_body.body_size;

                        // 2. Extract KES root pk for opcert hot_vk
                        const kes_root_pk = kes_sign.extractRootPk(ctx.kes_key_state[0..ctx.kes_key_state_len]) catch {
                            std.debug.print("FATAL: BLOCK CANDIDATE cannot extract KES root PK\n", .{});
                            std.process.exit(97);
                        };

                        // 3. Build real 10-element header body CBOR
                        const real_hdr_body = cbor_block_header_body.buildHeaderBodyCborV2(
                            parent_block_no + 1,
                            current_slot,
                            parent_hash,
                            ctx.dryrun_issuer_vk,
                            vrf_pk,
                            ctx.vrf_output_bytes_last,
                            ctx.vrf_proof_bytes_last,
                            use_body_size,
                            use_body_hash,
                            .{
                                .hot_vk = kes_root_pk,
                                .seq_no = ctx.dryrun_opcert_seq_no,
                                .kes_period = ctx.kes_start_period,
                                .sigma = ctx.dryrun_opcert_sigma,
                            },
                            blk_pv: {
                                const pv = currentProtocolVersion(ctx);
                                break :blk_pv .{ .major = pv.major, .minor = pv.minor };
                            },
                        );

                        // 4. KES sign the real header body (key_state is const, safe to sign twice)
                        var block_kes_sig: [kes_sign.SUM6_KES_SIG_LEN]u8 = undefined;
                        var block_key_period: u32 = 0;
                        kes_sign.signSum6Kes(
                            ctx.kes_key_state[0..ctx.kes_key_state_len],
                            real_hdr_body.bytes[0..real_hdr_body.len],
                            &block_kes_sig,
                            &block_key_period,
                        ) catch {
                            std.debug.print("FATAL: BLOCK CANDIDATE Sum6Kes signing failed\n", .{});
                            std.process.exit(97);
                        };

                        // 5. Immediate self-verify of KES signature
                        const block_vr = kes_verify.verifySum6Kes(kes_root_pk, @intCast(ctx.kes_current_period_last - ctx.kes_start_period), real_hdr_body.bytes[0..real_hdr_body.len], &block_kes_sig);
                        if (block_vr != .ok) {
                            std.debug.print("FATAL: BLOCK CANDIDATE KES sig failed self-verify: {s}\n", .{kes_verify.resultStr(block_vr)});
                            std.process.exit(97);
                        }

                        // 6. Assemble header CBOR: [header_body, kes_sig]
                        var hdr_buf: [2048]u8 = undefined;
                        const hdr_result = cbor_block_full.assembleHeader(&hdr_buf, real_hdr_body.bytes[0..real_hdr_body.len], block_kes_sig);

                        // 7. Self-verify: recompute header hash
                        var recomp_hdr_hash: [32]u8 = undefined;
                        Blake2b256.hash(hdr_buf[0..hdr_result.len], &recomp_hdr_hash, .{});
                        if (!std.mem.eql(u8, &recomp_hdr_hash, &hdr_result.header_hash)) {
                            std.debug.print("FATAL: BLOCK CANDIDATE header hash mismatch\n", .{});
                            std.process.exit(97);
                        }

                        // 8. Assemble full block CBOR: [era, [header, tx_bodies, witnesses, aux_data, invalid_txs]]
                        const use_tx_bodies: []const u8 = if (dyn_body) |db| db.tx_bodies_cbor else empty_body.tx_bodies_cbor;
                        const use_witnesses: []const u8 = if (dyn_body) |db| db.witnesses_cbor else empty_body.witnesses_cbor;
                        const use_aux_data: []const u8 = if (dyn_body) |db| db.aux_data_cbor else empty_body.aux_data_cbor;
                        const fb_needed = 16 + hdr_result.len + use_tx_bodies.len + use_witnesses.len + use_aux_data.len + empty_body.invalid_txs_cbor.len;
                        var fb_stack: [4096]u8 = undefined;
                        var fb_heap: ?[]u8 = null;
                        defer if (fb_heap) |h| std.heap.page_allocator.free(h);
                        if (fb_needed > 4096) {
                            fb_heap = std.heap.page_allocator.alloc(u8, fb_needed) catch {
                                std.debug.print("FATAL: BLOCK CANDIDATE cannot alloc {d}-byte full block buffer\n", .{fb_needed});
                                std.process.exit(97);
                            };
                        }
                        const full_block_buf: []u8 = if (fb_heap) |h| h else &fb_stack;
                        const full_block_len = cbor_block_full.assembleFullBlock(
                            full_block_buf,
                            cbor_block_full.CONWAY_BLOCK_ERA_TAG, // 7 — see constant doc (Byron double-tag); NOT 6
                            hdr_buf[0..hdr_result.len],
                            use_tx_bodies,
                            use_witnesses,
                            use_aux_data,
                            empty_body.invalid_txs_cbor,
                        );

                        // 9. Write block candidate artifacts to blocks/ dir
                        if (ctx.dryrun_blocks_dir) |blocks_base| {
                            var blocks_dir_buf: [512]u8 = undefined;
                            const blocks_dir_name = std.fmt.bufPrint(&blocks_dir_buf, "{s}/{d}_{d}", .{ blocks_base, artifact_unix, current_slot }) catch "";
                            if (blocks_dir_name.len > 0) {
                                compat.fs.cwd().makePath(blocks_dir_name) catch {};
                                // Block-specific artifacts
                                _ = dryrunWriteFile(blocks_dir_name, "block.cbor", full_block_buf[0..full_block_len]);
                                _ = dryrunWriteFile(blocks_dir_name, "block_header.cbor", hdr_buf[0..hdr_result.len]);
                                const blk_hdr_hash_hex = std.fmt.bytesToHex(hdr_result.header_hash, .lower);
                                _ = dryrunWriteFile(blocks_dir_name, "block_header_hash.hex", &blk_hdr_hash_hex);
                                const blk_body_hash_hex = std.fmt.bytesToHex(use_body_hash, .lower);
                                _ = dryrunWriteFile(blocks_dir_name, "block_body_hash.hex", &blk_body_hash_hex);
                                // Shared artifacts (self-contained for proof bundle)
                                _ = dryrunWriteFile(blocks_dir_name, "header.cbor", &cand.bytes);
                                const blk_cand_hdr_hex = std.fmt.bytesToHex(cand.header_hash, .lower);
                                _ = dryrunWriteFile(blocks_dir_name, "header_hash.hex", &blk_cand_hdr_hex);
                                const blk_cand_body_hex = std.fmt.bytesToHex(body.body_hash, .lower);
                                _ = dryrunWriteFile(blocks_dir_name, "body_hash.hex", &blk_cand_body_hex);
                                _ = dryrunWriteFile(blocks_dir_name, "header_body.cbor", real_hdr_body.bytes[0..real_hdr_body.len]);
                                _ = dryrunWriteFile(blocks_dir_name, "signature.bin", &block_kes_sig);
                                // meta.json
                                {
                                    var blk_meta_buf: [2048]u8 = undefined;
                                    const blk_meta = std.fmt.bufPrint(&blk_meta_buf,
                                        \\{{"unix":{d},"net":"{s}","slot":{d},"block_no":{d},"leader":true,"u_x1e12":{d},"t_x1e12":{d},"kes_period":{d},"kes_valid":{d},"sig_kind":"real_kes","candidate_version":"TSUNAGI_HDR_CANDIDATE_V2","pool_id_hex":"{s}","kes_pk_hex":"{s}","kes_period_offset":{d},"signed_msg_mode":"direct"}}
                                    , .{
                                        artifact_unix,
                                        if (ctx.dryrun_net_name) |n| n else "unknown",
                                        current_slot,
                                        parent_block_no + 1,
                                        ctx.praos_u_x1e12_last,
                                        ctx.praos_thresh_x1e12_last,
                                        ctx.kes_current_period_last,
                                        ctx.kes_period_valid_last,
                                        pool_id_hex_str,
                                        @as([]const u8, &kes_pk_hex_buf),
                                        kes_period_offset_val,
                                    }) catch "";
                                    if (blk_meta.len > 0) _ = dryrunWriteFile(blocks_dir_name, "meta.json", blk_meta);
                                }
                                // verify.json
                                {
                                    var blk_vfy_buf: [256]u8 = undefined;
                                    const blk_vfy = std.fmt.bufPrint(&blk_vfy_buf,
                                        \\{{"hash_match":true,"sig_verify_ok":true,"sig_kind":"real_kes"}}
                                    , .{}) catch "";
                                    if (blk_vfy.len > 0) _ = dryrunWriteFile(blocks_dir_name, "verify.json", blk_vfy);
                                }

                                // v2.1.0-a: Write tx inclusion metadata artifacts
                                var inc_tx_count: usize = 0;
                                var inc_tx_total_bytes: usize = 0;
                                if (included_exports) |exports| {
                                    if (exports.len > 0) {
                                        inc_tx_count = exports.len;
                                        // included_tx_hashes.json
                                        {
                                            var json_buf = std.array_list.Managed(u8).init(std.heap.page_allocator);
                                            defer json_buf.deinit();
                                            json_buf.append('[') catch {};
                                            for (exports, 0..) |exp, idx| {
                                                if (idx > 0) json_buf.append(',') catch {};
                                                json_buf.append('"') catch {};
                                                const hex = std.fmt.bytesToHex(exp.txid, .lower);
                                                json_buf.appendSlice(&hex) catch {};
                                                json_buf.append('"') catch {};
                                                inc_tx_total_bytes += exp.tx_bytes.len;
                                            }
                                            json_buf.append(']') catch {};
                                            if (json_buf.items.len > 2) _ = dryrunWriteFile(blocks_dir_name, "included_tx_hashes.json", json_buf.items);
                                        }
                                        // included_tx_count.txt
                                        {
                                            var cnt_buf: [32]u8 = undefined;
                                            const cnt_str = std.fmt.bufPrint(&cnt_buf, "{d}", .{inc_tx_count}) catch "";
                                            if (cnt_str.len > 0) _ = dryrunWriteFile(blocks_dir_name, "included_tx_count.txt", cnt_str);
                                        }
                                        // included_tx_total_bytes.txt
                                        {
                                            var bytes_buf: [32]u8 = undefined;
                                            const bytes_str = std.fmt.bufPrint(&bytes_buf, "{d}", .{inc_tx_total_bytes}) catch "";
                                            if (bytes_str.len > 0) _ = dryrunWriteFile(blocks_dir_name, "included_tx_total_bytes.txt", bytes_str);
                                        }
                                        if (dyn_body != null) {
                                            std.debug.print("DRYRUN: tx metadata written ({d} txs, {d} bytes), txs embedded in body\n", .{ inc_tx_count, inc_tx_total_bytes });
                                        } else {
                                            std.debug.print("DRYRUN: tx metadata written ({d} txs, {d} bytes), tx embedding failed\n", .{ inc_tx_count, inc_tx_total_bytes });
                                        }
                                    }
                                }

                                ctx.dryrun_block_candidates_built += 1;
                                std.debug.print("BLOCK CANDIDATE: built slot={d} block_no={d} hdr_len={d} block_len={d} tx_meta={d} dir={s}\n", .{
                                    current_slot,
                                    parent_block_no + 1,
                                    hdr_result.len,
                                    full_block_len,
                                    inc_tx_count,
                                    blocks_dir_name,
                                });
                            }
                        }

                        // Guardian safe-mode check (rate-limited to once per 30s)
                        if (now_unix - ctx.safe_mode_last_check_unix >= 30) {
                            ctx.safe_mode_last_check_unix = now_unix;
                            ctx.safe_mode_active = checkSafeModeFile();
                        }

                        // v3.0.0: Forge gate — SEPARATE from dryrun, ADDITIVE only
                        if (ctx.safe_mode_active) {
                            if (ctx.forge_all_flags_set) {
                                std.debug.print("FORGE_SKIP_SAFE_MODE: safe_mode_active=true slot={d}\n", .{current_slot});
                            }
                        } else if (ctx.forge_all_flags_set and ctx.forge_sim_dir != null) {
                            const forge_gate_ok = ctx.force_forge or forgeInternalGate(ctx, current_slot, now_unix);
                            if (forge_gate_ok) {
                                forge_attempt: {
                                if (!ctx.frag_tail_valid) {
                                    std.debug.print("FORGE SKIP: fragment tail not yet populated\n", .{});
                                    ctx.forge_refused_total += 1;
                                    forge_stats.onForgeAttempt(current_slot, false);
                                } else if (ctx.deferred_forge_executing) {
                                    // Deferred forge execution: go directly to forge with fresh parent.
                                    // Skip scheduling — we already have the stored VRF proof.
                                } else if (!ctx.deferred_forge_pending and current_slot > parent_slot) {
                                    // Check: are we already AT the leader slot? If so, forge
                                    // immediately — deferring would lose the window because the
                                    // next tick will have a parent past the forge slot.
                                    //
                                    // ── Wall-clock barrier for inline forge ────────────────────
                                    // current_slot can be a FUTURE slot when follower.zig:8152
                                    // calls producer.tick with leader_slot (up to est_slot+128).
                                    // Without this gate, FORGE_IMMEDIATE would publish a header
                                    // with slot=leader_slot at wall-clock T < slot_start_unix
                                    // and cardano-node would reject InFutureHeaderExceedsClockSkew
                                    // (observed: slot=113631767, ageUponArrival=-42..-2s).
                                    //
                                    // When wall-clock is not yet at current_slot, force the else
                                    // branch (SCHEDULED_LEADER) which defers; the deferred-fire
                                    // path's own wall-clock barrier (producer.zig:1723) then
                                    // holds until wall-clock arrives at slot_start_unix.
                                    //
                                    // genesis_parse_ok guard mirrors the deferred-fire barrier:
                                    // if clock isn't initialized, estimateSlot returns 0 which
                                    // would otherwise force every leader through the deferred
                                    // schedule path; the existing downstream gates handle the
                                    // degenerate case.
                                    const inline_wall_clock_ready = !ctx.genesis_parse_ok or
                                        slot_clock.estimateSlot(&ctx.clock, now_unix) >= current_slot;
                                    if (current_slot == ctx.praos_last_checked_slot and parent_slot < current_slot and inline_wall_clock_ready) {
                                        // Stage-1/2 selection via shared helper. Probe never read.
                                        const imm_choice = selectFreshestParent(ctx);
                                        const imm_parent_slot = imm_choice.slot;
                                        const imm_parent_block = imm_choice.block_no;
                                        const imm_source = parentSourceName(imm_choice.source);
                                        const imm_gap = if (current_slot > imm_parent_slot) current_slot - imm_parent_slot else 0;
                                        std.debug.print("FORGE_IMMEDIATE: slot={d} parent_slot={d} parent_block={d} parent_source={s} parent_gap_slots={d} fallback_reason={s} u_x1e12={d} thresh={d}\n", .{
                                            current_slot, imm_parent_slot, imm_parent_block,
                                            imm_source, imm_gap, imm_choice.fallback_reason,
                                            ctx.praos_u_x1e12_last, ctx.praos_thresh_x1e12_last,
                                        });
                                        // Stage-3: stale-parent refusal (no opcert / no KES burn).
                                        // Applied immediately after selectFreshestParent, before any
                                        // forge execution. break :forge_attempt cleanly aborts this
                                        // forge attempt only; executeTick housekeeping continues.
                                        const imm_stale_threshold: u64 = staleParentMaxSlots();
                                        if (imm_gap > imm_stale_threshold) {
                                            std.debug.print("FORGE_REFUSE_STALE_PARENT: forge_slot={d} parent_slot={d} parent_block={d} parent_source={s} parent_gap_slots={d} threshold={d} fallback_reason={s} rx_slot={d} rx_block={d} tip_slot={d} tip_block={d} rx_prev_first8={x} tip_hash_first8={x} rx_prev_known={} hashes_equal={}\n", .{
                                                current_slot, imm_parent_slot, imm_parent_block,
                                                imm_source, imm_gap, imm_stale_threshold, imm_choice.fallback_reason,
                                                imm_choice.rx_observed_slot, imm_choice.rx_observed_block,
                                                ctx.tip_slot_last, ctx.tip_block_last,
                                                imm_choice.rx_prev_hash_at_select[0..8], imm_choice.tip_hash_at_select[0..8],
                                                imm_choice.rx_prev_known,
                                                std.mem.eql(u8, imm_choice.rx_prev_hash_at_select[0..], imm_choice.tip_hash_at_select[0..]),
                                            });
                                            break :forge_attempt;
                                        }
                                        // Do NOT mutate ctx.tip_*_last here. tip_*_last must reflect
                                        // ONLY the applied ChainSync tip; writing the selected parent
                                        // (especially rx_validated) would pollute canonical state and
                                        // risk reintroducing structural inconsistency. forge_promote_inner
                                        // re-runs selectFreshestParent on its own and works from local
                                        // fp_* variables.
                                    } else {
                                        // Defer: store VRF proof and target slot, forge later at slot time.
                                        ctx.deferred_forge_slot = current_slot;
                                        ctx.deferred_forge_proof = ctx.vrf_proof_bytes_last;
                                        ctx.deferred_forge_output = ctx.vrf_output_bytes_last;
                                        ctx.deferred_forge_u_x1e12 = ctx.praos_u_x1e12_last;
                                        ctx.deferred_forge_thresh_x1e12 = ctx.praos_thresh_x1e12_last;
                                        ctx.deferred_forge_pending = true;
                                        std.debug.print("SCHEDULED_LEADER: slot={d} parent_slot={d} parent_block_no={d} u_x1e12={d} thresh={d} (deferred to slot time)\n", .{
                                            current_slot, parent_slot, parent_block_no,
                                            ctx.praos_u_x1e12_last, ctx.praos_thresh_x1e12_last,
                                        });
                                        // Do NOT consume arm token yet — will be consumed when forge fires
                                        return;
                                    }
                                }
                                // Fall through to forge execution (both deferred and legacy paths)
                                forge_promote_inner: {
                                    // ╔══════════════════════════════════════════════════════════════╗
                                    // ║  TRUTH-ALIGNMENT GATES (Phase 1 + 4 remediation)              ║
                                    // ║  Run BEFORE any irreversible action (opcert/KES/CBOR/disk).   ║
                                    // ║  Order: nonce currency → σ drift → canonical lag → parent     ║
                                    // ║  Refusal increments forge_refused_total + onForgeAttempt(false)║
                                    // ║  No opcert burn. No KES sign. No artifact write.              ║
                                    // ╚══════════════════════════════════════════════════════════════╝

                                    // ── FORGE_GATE_HARDFORK — refuse if proto/era exceed binary's supported max ──
                                    // Phase 4.5: auto-detect Dijkstra (v12) or any unknown future hardfork.
                                    // Current binary supports Conway era_index=6 + proto_major <= 11.
                                    // On HF detection: log + refuse + write HARDFORK_LOCK marker.
                                    {
                                        const SUPPORTED_PROTO_MAJOR_MAX: u64 = 11;
                                        const SUPPORTED_ERA_INDEX_MAX: u8 = 6; // Conway
                                        const live_pv_major: u64 = blk: {
                                            if (mempool_mod.g_protocol_params) |pp| {
                                                if (pp.protocol_major > 0) break :blk @as(u64, pp.protocol_major);
                                            }
                                            break :blk ctx.dryrun_pv_major;
                                        };
                                        const live_era: u8 = 6; // Conway era index used by our forge path
                                        if (live_pv_major > SUPPORTED_PROTO_MAJOR_MAX or live_era > SUPPORTED_ERA_INDEX_MAX) {
                                            std.debug.print("FORGE_REFUSE: gate=hardfork reason=unsupported_version proto_major={d} era={d} binary_max_proto={d} binary_max_era={d}\n", .{
                                                live_pv_major, live_era, SUPPORTED_PROTO_MAJOR_MAX, SUPPORTED_ERA_INDEX_MAX,
                                            });
                                            if (compat.getenv("TSUNAGI_HOME")) |home| {
                                                var pb: [512]u8 = undefined;
                                                const lock_path = std.fmt.bufPrint(&pb, "{s}/HARDFORK_LOCK", .{home}) catch "";
                                                if (lock_path.len > 0) {
                                                    if (compat.fs.cwd().createFile(lock_path, .{ .truncate = true })) |f| {
                                                        var ff = f;
                                                        var lock_body_buf: [256]u8 = undefined;
                                                        const lock_body = std.fmt.bufPrint(&lock_body_buf, "proto_major={d} era={d} detected_unix={d}\n", .{
                                                            live_pv_major, live_era, compat.timestamp(),
                                                        }) catch "";
                                                        if (lock_body.len > 0) _ = ff.writeAll(lock_body) catch {};
                                                        ff.close();
                                                    } else |_| {}
                                                }
                                            }
                                            ctx.forge_refused_total += 1;
                                            forge_stats.onForgeAttempt(current_slot, false);
                                            break :forge_promote_inner;
                                        }
                                        std.debug.print("FORGE_GATE_HARDFORK: pass=YES proto_major={d} era={d}\n", .{
                                            live_pv_major, live_era,
                                        });
                                    }

                                    // ── FORGE_GATE_NONCE — refuse if nonce_epoch != current_epoch ──
                                    {
                                        if (!ctx.nonce_initialized) {
                                            std.debug.print("FORGE_REFUSE: gate=nonce reason=not_initialized\n", .{});
                                            ctx.forge_refused_total += 1;
                                            forge_stats.onForgeAttempt(current_slot, false);
                                            break :forge_promote_inner;
                                        }
                                        if (ctx.nonce_state.nonce_epoch != ctx.epoch_last) {
                                            std.debug.print("FORGE_REFUSE: gate=nonce reason=epoch_mismatch nonce_epoch={d} current_epoch={d}\n", .{
                                                ctx.nonce_state.nonce_epoch, ctx.epoch_last,
                                            });
                                            ctx.forge_refused_total += 1;
                                            forge_stats.onForgeAttempt(current_slot, false);
                                            break :forge_promote_inner;
                                        }
                                        std.debug.print("FORGE_GATE_NONCE: pass=YES nonce_epoch={d} current_epoch={d}\n", .{
                                            ctx.nonce_state.nonce_epoch, ctx.epoch_last,
                                        });
                                    }

                                    // ── FORGE_GATE_SIGMA — refuse if runtime σ drifts >N% from chain σ ──
                                    {
                                        const stake_source = @import("stake_source.zig");
                                        const gate_epoch: u64 = ctx.epoch_last;
                                        const chain_snap_opt = stake_source.forgeStakeSnapshot(gate_epoch) catch |err| blk: {
                                            // Snapshot unavailable — soft pass with warning UNLESS strict mode.
                                            // Strict mode: TSUNAGI_SIGMA_STRICT=1 → refuse.
                                            const strict = compat.getenv("TSUNAGI_SIGMA_STRICT") orelse "0";
                                            if (std.mem.eql(u8, strict, "1")) {
                                                std.debug.print("FORGE_REFUSE: gate=sigma reason=no_chain_snapshot err={s} (strict mode)\n", .{@errorName(err)});
                                                ctx.forge_refused_total += 1;
                                                forge_stats.onForgeAttempt(current_slot, false);
                                                break :forge_promote_inner;
                                            }
                                            std.debug.print("FORGE_GATE_SIGMA: pass=SOFT reason=no_chain_snapshot err={s}\n", .{@errorName(err)});
                                            break :blk null;
                                        };
                                        if (chain_snap_opt) |chain_snap| {
                                            // Variant B: forge gate env side reads the SAME authoritative
                                            // resolver as election (read-only). With the fresh poller this
                                            // equals the chain side -> drift 0; the max() below remains a
                                            // belt-and-suspenders floor if the resolver fell back to ledger.
                                            const raw_env_sigma_x1e9: u64 = resolveAuthoritativeSigma(ctx).sigma_x1e9;
                                            // gate-prefer-fresh-env (sigma-drift-2026-06-06): under-claiming (env below
                                            // chain) is the consensus-SAFE direction — a lower σ only lowers the Praos
                                            // VRF threshold, so the node can win FEWER slots, never an ineligible one.
                                            // Lift a stale-low env σ up to the fresh chain-poller value so a stale
                                            // ledger σ cannot trip the guard, while leaving the OVER-claim case
                                            // (env > chain) fully intact so it still refuses. Drift/refuse logic below
                                            // is unchanged; it simply operates on the clamped env_sigma_x1e9.
                                            const env_sigma_x1e9: u64 = if (raw_env_sigma_x1e9 > chain_snap.sigma_x1e9)
                                                raw_env_sigma_x1e9
                                            else
                                                chain_snap.sigma_x1e9;
                                            const drift_pct: i64 = if (chain_snap.sigma_x1e9 > 0)
                                                @divTrunc((@as(i64, @intCast(env_sigma_x1e9)) - @as(i64, @intCast(chain_snap.sigma_x1e9))) * 100, @as(i64, @intCast(chain_snap.sigma_x1e9)))
                                            else
                                                0;
                                            const max_drift_pct: i64 = blk: {
                                                if (compat.getenv("TSUNAGI_SIGMA_DRIFT_MAX_PCT")) |s| {
                                                    if (std.fmt.parseInt(i64, s, 10)) |v| break :blk v else |_| {}
                                                }
                                                break :blk 5;
                                            };
                                            std.debug.print("FORGE_GATE_SIGMA: epoch={d} env_sigma_x1e9={d} raw_env_sigma_x1e9={d} chain_sigma_x1e9={d} drift_pct={d} max_drift_pct={d}\n", .{
                                                gate_epoch, env_sigma_x1e9, raw_env_sigma_x1e9, chain_snap.sigma_x1e9, drift_pct, max_drift_pct,
                                            });
                                            const abs_drift: i64 = if (drift_pct < 0) -drift_pct else drift_pct;
                                            if (abs_drift > max_drift_pct) {
                                                std.debug.print("FORGE_REFUSE: gate=sigma reason=drift_exceeded epoch={d} env={d} chain={d} drift_pct={d}\n", .{
                                                    gate_epoch, env_sigma_x1e9, chain_snap.sigma_x1e9, drift_pct,
                                                });
                                                ctx.forge_refused_total += 1;
                                                forge_stats.onForgeAttempt(current_slot, false);
                                                break :forge_promote_inner;
                                            }
                                        }
                                    }

                                    // ── FORGE_GATE_CANONICAL_LAG — refuse if local tip is N+ blocks behind canonical ──
                                    // Phase 4: prevents forging on catastrophically stale upstream chain state.
                                    // Reads canonical tip from acceptance_tracker (Koios-fed). Default threshold 600 slots.
                                    // Override via TSUNAGI_CANONICAL_LAG_MAX_SLOTS env. Strict via TSUNAGI_CANONICAL_LAG_STRICT=1.
                                    {
                                        const acceptance_tracker = @import("acceptance_tracker.zig");
                                        const canon_tip_block = acceptance_tracker.g_canonical_tip_block_no;
                                        const canon_tip_age_s: i64 = if (acceptance_tracker.g_canonical_tip_unix > 0)
                                            compat.timestamp() - acceptance_tracker.g_canonical_tip_unix
                                        else
                                            999_999;
                                        const max_lag_slots: u64 = blk: {
                                            if (compat.getenv("TSUNAGI_CANONICAL_LAG_MAX_SLOTS")) |s| {
                                                if (std.fmt.parseInt(u64, s, 10)) |v| break :blk v else |_| {}
                                            }
                                            break :blk 600;
                                        };
                                        if (canon_tip_block > 0 and canon_tip_age_s < 300) {
                                            const local_block = ctx.tip_block_last;
                                            const lag_blocks: i64 = @as(i64, @intCast(canon_tip_block)) - @as(i64, @intCast(local_block));
                                            std.debug.print("FORGE_GATE_CANONICAL_LAG: local_block={d} canonical_block={d} lag_blocks={d} canon_age_s={d} max_lag_slots={d}\n", .{
                                                local_block, canon_tip_block, lag_blocks, canon_tip_age_s, max_lag_slots,
                                            });
                                            // Each block ≈ 20 slots avg on preview, so lag in blocks * 20 ≈ slots
                                            if (lag_blocks > @as(i64, @intCast(max_lag_slots / 20))) {
                                                std.debug.print("FORGE_REFUSE: gate=canonical_lag reason=upstream_stale local={d} canonical={d} lag={d}\n", .{
                                                    local_block, canon_tip_block, lag_blocks,
                                                });
                                                ctx.forge_refused_total += 1;
                                                forge_stats.onForgeAttempt(current_slot, false);
                                                break :forge_promote_inner;
                                            }
                                        } else {
                                            const strict = compat.getenv("TSUNAGI_CANONICAL_LAG_STRICT") orelse "0";
                                            if (std.mem.eql(u8, strict, "1") and canon_tip_block == 0) {
                                                std.debug.print("FORGE_REFUSE: gate=canonical_lag reason=no_canonical_data (strict mode)\n", .{});
                                                ctx.forge_refused_total += 1;
                                                forge_stats.onForgeAttempt(current_slot, false);
                                                break :forge_promote_inner;
                                            }
                                            std.debug.print("FORGE_GATE_CANONICAL_LAG: pass=SOFT canon_block={d} canon_age_s={d}\n", .{
                                                canon_tip_block, canon_tip_age_s,
                                            });
                                        }
                                    }

                                    // ── PARENT SELECTION: applied_tip OR rx_validated (1-step) ──
                                    // Parent identity is restricted to the validated-locally set.
                                    // selectFreshestParent enforces Stage-1 (max block over applied_tip
                                    // vs rx_validated) and Stage-2 (1-step rule: rx.block_no ==
                                    // tip.block_no+1 AND rx.prev_hash == tip.hash AND rx_prev_known).
                                    // Probe peers are NEVER read for parent identity — strictly
                                    // advisory below. Stage-3 (slot-gap staleness) is enforced
                                    // inline using staleParentMaxSlots(); on stale we refuse forge
                                    // before any opcert/KES side effect.
                                    const forge_slot = current_slot;
                                    const choice = selectFreshestParent(ctx);
                                    // Torn snapshot is NOT a refusal: the helper already falls
                                    // back to applied_tip values with fallback_reason="torn_snapshot".
                                    // Stage-3 stale-parent check below still runs unconditionally.
                                    if (choice.block_no == 0) {
                                        std.debug.print("FORGE_PARENT_REFUSE: reason=tip_empty forge_slot={d}\n", .{forge_slot});
                                        break :forge_promote_inner;
                                    }
                                    if (choice.slot >= forge_slot) {
                                        std.debug.print("FORGE_PARENT_REFUSE: reason=tip_at_or_after_forge_slot tip_slot={d} forge_slot={d} parent_source={s}\n", .{
                                            choice.slot, forge_slot, parentSourceName(choice.source),
                                        });
                                        break :forge_promote_inner;
                                    }

                                    const parent_gap_slots: u64 = forge_slot - choice.slot;
                                    const stale_threshold: u64 = staleParentMaxSlots();
                                    if (parent_gap_slots > stale_threshold) {
                                        std.debug.print("FORGE_REFUSE_STALE_PARENT: forge_slot={d} parent_slot={d} parent_block={d} parent_source={s} parent_gap_slots={d} threshold={d} fallback_reason={s} rx_slot={d} rx_block={d} tip_slot={d} tip_block={d} rx_prev_first8={x} tip_hash_first8={x} rx_prev_known={} hashes_equal={}\n", .{
                                            forge_slot, choice.slot, choice.block_no,
                                            parentSourceName(choice.source), parent_gap_slots, stale_threshold,
                                            choice.fallback_reason,
                                            choice.rx_observed_slot, choice.rx_observed_block,
                                            ctx.tip_slot_last, ctx.tip_block_last,
                                            choice.rx_prev_hash_at_select[0..8], choice.tip_hash_at_select[0..8],
                                            choice.rx_prev_known,
                                            std.mem.eql(u8, choice.rx_prev_hash_at_select[0..], choice.tip_hash_at_select[0..]),
                                        });
                                        break :forge_promote_inner;
                                    }

                                    const fp_slot = choice.slot;
                                    const fp_block_no = choice.block_no;
                                    const fp_hash = choice.hash;
                                    const computed_child_block_no = fp_block_no + 1;

                                    // Probe is strictly advisory — read max(block_no) for diagnostic
                                    // logging only. Never used as parent identity.
                                    const probe_max_block: u64 = blk: {
                                        multi_probe.g_mu.lock();
                                        defer multi_probe.g_mu.unlock();
                                        var maxb: u64 = 0;
                                        var pi: u32 = 0;
                                        while (pi < multi_probe.MAX_PROBES) : (pi += 1) {
                                            if (multi_probe.g_probe_peers[pi].used and multi_probe.g_probe_peers[pi].last_block > maxb) {
                                                maxb = multi_probe.g_probe_peers[pi].last_block;
                                            }
                                        }
                                        break :blk maxb;
                                    };
                                    std.debug.print("FORGE_PARENT_FINAL: parent_slot={d} parent_block_no={d} parent_hash={x} computed_block_no={d} forge_slot={d} parent_source={s} parent_gap_slots={d} fallback_reason={s} rx_observed=(s={d},b={d}) probe_max_block={d} rx_prev_first8={x} tip_hash_first8={x} rx_prev_known={} hashes_equal={}\n", .{
                                        fp_slot, fp_block_no, fp_hash[0..8], computed_child_block_no, forge_slot,
                                        parentSourceName(choice.source), parent_gap_slots, choice.fallback_reason,
                                        choice.rx_observed_slot, choice.rx_observed_block,
                                        probe_max_block,
                                        choice.rx_prev_hash_at_select[0..8], choice.tip_hash_at_select[0..8],
                                        choice.rx_prev_known,
                                        std.mem.eql(u8, choice.rx_prev_hash_at_select[0..], choice.tip_hash_at_select[0..]),
                                    });
                                    std.debug.print("FORGE ANCHOR: tick_parent slot={d} block_no={d} hash={x} frag_tail slot={d} block_no={d} -> forge slot={d}\n", .{
                                        fp_slot, fp_block_no, fp_hash[0..8],
                                        ctx.frag_tail_slot, ctx.frag_tail_block_no, forge_slot,
                                    });

                                    // Try mempool tx inclusion for non-empty blocks
                                    const forge_body_std = cbor_block_body.buildEmptyBody();
                                    var forge_dyn_body: ?cbor_block_body.DynBodyResult = null;
                                    var forge_tx_count: usize = 0;
                                    defer if (forge_dyn_body) |db| {
                                        std.heap.page_allocator.free(db.tx_bodies_cbor);
                                        std.heap.page_allocator.free(db.witnesses_cbor);
                                        std.heap.page_allocator.free(db.aux_data_cbor);
                                    };
                                    if (ctx.dryrun_mempool) |mp| {
                                        // Same protocol-body cap as the candidate-build path above.
                                        const protocol_body_cap_forge: u64 = if (mempool_mod.g_protocol_params) |pp|
                                            (if (pp.max_block_body_size > 0) pp.max_block_body_size else 90112)
                                        else
                                            90112;
                                        if (mp.exportForDryrunBlock(std.heap.page_allocator, ctx.dryrun_block_max_tx, ctx.dryrun_block_max_bytes, protocol_body_cap_forge)) |exports| {
                                            defer std.heap.page_allocator.free(exports);
                                            if (exports.len > 0) {
                                                var f_body_slices = std.array_list.Managed([]const u8).init(std.heap.page_allocator);
                                                defer f_body_slices.deinit();
                                                var f_wit_slices = std.array_list.Managed([]const u8).init(std.heap.page_allocator);
                                                defer f_wit_slices.deinit();
                                                // Per-tx auxiliary_data (Conway tx element [3]); null for
                                                // metadata-free txs. Indexed in lockstep with f_body_slices
                                                // so buildBodyWithTxSlices can emit auxiliary_data_set keyed
                                                // by block tx index. Slices point into exp.tx_bytes (owned by
                                                // `exports`, freed after the body is built).
                                                var f_aux_slices = std.array_list.Managed(?[]const u8).init(std.heap.page_allocator);
                                                defer f_aux_slices.deinit();
                                                // Track consumed inputs within this block to detect double-spends
                                                const MAX_BLOCK_INPUTS = 256;
                                                var block_consumed: [MAX_BLOCK_INPUTS]utxo_mod.TxIn = undefined;
                                                var block_consumed_count: usize = 0;
                                                var tx_skip_count: usize = 0;

                                                for (exports) |exp| {
                                                    // Phase 5.5: Validate tx before inclusion
                                                    const check = validateTxForInclusion(
                                                        exp.tx_bytes,
                                                        ctx.utxo_set,
                                                        block_consumed[0..block_consumed_count],
                                                    );
                                                    if (check.reason) |reason| {
                                                        std.debug.print("TX_SKIP: reason={s} txid={x}\n", .{ reason, exp.txid[0..8] });
                                                        tx_skip_count += 1;
                                                        // Persistent failures (parse, missing UTxO, balance,
                                                        // self-duplicate-input) will fail the same way next slot.
                                                        // Evict from mempool so we don't rescan a doomed tx forever.
                                                        // Transient failures (double_spend within this candidate
                                                        // block) keep the tx — the conflicting tx may be gone
                                                        // next slot.
                                                        if (check.persistent) {
                                                            if (ctx.dryrun_mempool) |mp_evict| {
                                                                // Mempool keys items by blake2b-256(full tx CBOR),
                                                                // not by the canonical txid (hash of tx body).
                                                                // Recompute the mempool key from the same bytes
                                                                // that addTx hashed.
                                                                var mp_hash: [32]u8 = undefined;
                                                                std.crypto.hash.blake2.Blake2b256.hash(exp.tx_bytes, &mp_hash, .{});
                                                                if (mp_evict.removeTx(mp_hash)) {
                                                                    std.debug.print("TX_EVICT: reason={s} txid={x}\n", .{ reason, exp.txid[0..8] });
                                                                }
                                                            }
                                                        }
                                                        continue;
                                                    }

                                                    const parts = block_hash.decomposeTx(exp.tx_bytes) orelse continue;
                                                    // Hardfork layer: per-tx size check using live protocol params
                                                    if (mempool_mod.g_protocol_params) |pp_check| {
                                                        if (pp_check.max_tx_size > 0 and exp.tx_bytes.len > pp_check.max_tx_size) {
                                                            std.debug.print("FORGE_BLOCK_REJECT_PRECHECK: reason=tx_too_large txid={x} size={d} max={d}\n", .{
                                                                exp.txid[0..8], exp.tx_bytes.len, pp_check.max_tx_size,
                                                            });
                                                            continue;
                                                        }
                                                    }
                                                    f_body_slices.append(parts.tx_body) catch continue;
                                                    f_wit_slices.append(parts.witnesses) catch {
                                                        _ = f_body_slices.pop();
                                                        continue;
                                                    };
                                                    f_aux_slices.append(parts.aux_data) catch {
                                                        _ = f_body_slices.pop();
                                                        _ = f_wit_slices.pop();
                                                        continue;
                                                    };

                                                    // Record consumed inputs for double-spend check
                                                    if (tx_decode.extractTxInputsFromBytes(std.heap.page_allocator, exp.tx_bytes)) |inputs| {
                                                        defer std.heap.page_allocator.free(inputs);
                                                        for (inputs) |inp| {
                                                            if (block_consumed_count < MAX_BLOCK_INPUTS) {
                                                                block_consumed[block_consumed_count] = inp;
                                                                block_consumed_count += 1;
                                                            }
                                                        }
                                                    }
                                                }
                                                if (tx_skip_count > 0) {
                                                    std.debug.print("TX_VALIDATION: skipped={d} accepted={d}\n", .{ tx_skip_count, f_body_slices.items.len });
                                                }
                                                if (f_body_slices.items.len > 0) {
                                                    forge_dyn_body = cbor_block_body.buildBodyWithTxSlices(
                                                        std.heap.page_allocator,
                                                        f_body_slices.items,
                                                        f_wit_slices.items,
                                                        f_aux_slices.items,
                                                    );
                                                    if (forge_dyn_body != null) {
                                                        forge_tx_count = f_body_slices.items.len;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    const forge_use_body_hash: [32]u8 = if (forge_dyn_body) |db| db.body_hash else forge_body_std.body_hash;
                                    const forge_use_body_size: u64 = if (forge_dyn_body) |db| db.body_size else forge_body_std.body_size;
                                    std.debug.print("MEMPOOL_STATE: pool_size={d} exported={d}\n", .{
                                        if (ctx.dryrun_mempool) |mp| mp.count() else 0,
                                        forge_tx_count,
                                    });

                                    // Rebuild real header body with canonical parent
                                    var vrf_pk_forge: [32]u8 = [_]u8{0} ** 32;
                                    if (ctx.vrf_cfg.pk) |pk| vrf_pk_forge = pk;
                                    const forge_kes_root = kes_sign.extractRootPk(ctx.kes_key_state[0..ctx.kes_key_state_len]) catch [_]u8{0} ** 32;
                                    const forge_hdr_body = cbor_block_header_body.buildHeaderBodyCborV2(
                                        fp_block_no + 1,
                                        forge_slot,
                                        fp_hash,
                                        ctx.dryrun_issuer_vk,
                                        vrf_pk_forge,
                                        ctx.vrf_output_bytes_last,
                                        ctx.vrf_proof_bytes_last,
                                        forge_use_body_size,
                                        forge_use_body_hash,
                                        .{
                                            .hot_vk = forge_kes_root,
                                            .seq_no = ctx.dryrun_opcert_seq_no,
                                            .kes_period = ctx.kes_start_period,
                                            .sigma = ctx.dryrun_opcert_sigma,
                                        },
                                        blk_pv: {
                                            const pv = currentProtocolVersion(ctx);
                                            break :blk_pv .{ .major = pv.major, .minor = pv.minor };
                                        },
                                    );

                                    // Block body size guard (pre-KES): reject oversized bodies
                                    // before spending crypto. Prefer live protocol params from
                                    // Koios/file; fall back to Babbage/Conway default 90112.
                                    const max_block_body_size: u64 = if (mempool_mod.g_protocol_params) |pp|
                                        (if (pp.max_block_body_size > 0) pp.max_block_body_size else 90112)
                                    else
                                        90112;
                                    if (forge_use_body_size > max_block_body_size) {
                                        std.debug.print("BLOCK_SIZE_CHECK: slot={d} size={d} max={d} ok=0\n", .{ forge_slot, forge_use_body_size, max_block_body_size });
                                        std.debug.print("BLOCK_REJECT_LOCAL: reason=size_exceeded slot={d} size={d} max={d}\n", .{ forge_slot, forge_use_body_size, max_block_body_size });
                                        ctx.forge_refused_total += 1;
                                        forge_stats.onForgeAttempt(forge_slot, false);
                                        break :forge_promote_inner;
                                    }
                                    std.debug.print("BLOCK_SIZE_CHECK: slot={d} size={d} max={d} ok=1\n", .{ forge_slot, forge_use_body_size, max_block_body_size });
                                    std.debug.print("BLOCK_VALIDATION_OK: slot={d} size={d} max={d}\n", .{ forge_slot, forge_use_body_size, max_block_body_size });

                                    // Opcert counter safety — refuse forge if in-memory counter would
                                    // regress vs disk-persisted value. Prevents silent relay reject on
                                    // stale opcert after a cold-start / rollback.
                                    if (ctx.dryrun_opcert_seq_no < ctx.opcert_last_persisted) {
                                        std.debug.print("OPCERT_CHECK: slot={d} local={d} last={d} ok=0\n", .{
                                            forge_slot, ctx.dryrun_opcert_seq_no, ctx.opcert_last_persisted,
                                        });
                                        ctx.forge_refused_total += 1;
                                        forge_stats.onForgeAttempt(forge_slot, false);
                                        break :forge_promote_inner;
                                    }
                                    std.debug.print("OPCERT_CHECK: slot={d} local={d} last={d} ok=1\n", .{
                                        forge_slot, ctx.dryrun_opcert_seq_no, ctx.opcert_last_persisted,
                                    });

                                    // Slashing protection — refuse to sign if we ever signed at this
                                    // slot (or higher) before. Hard invariant: prevents double-sign
                                    // after a crash + restart cycle. Always-on safety gate.
                                    if (!sign_log.check(forge_slot)) {
                                        ctx.forge_refused_total += 1;
                                        forge_stats.onForgeAttempt(forge_slot, false);
                                        break :forge_promote_inner;
                                    }

                                    // Re-sign with KES
                                    var forge_kes_sig: [kes_sign.SUM6_KES_SIG_LEN]u8 = undefined;
                                    var forge_key_period: u32 = 0;
                                    kes_sign.signSum6Kes(
                                        ctx.kes_key_state[0..ctx.kes_key_state_len],
                                        forge_hdr_body.bytes[0..forge_hdr_body.len],
                                        &forge_kes_sig,
                                        &forge_key_period,
                                    ) catch {
                                        std.debug.print("FORGE: KES re-sign failed\n", .{});
                                        ctx.forge_refused_total += 1;
                                        forge_stats.onForgeAttempt(forge_slot, false);
                                        break :forge_promote_inner;
                                    };

                                    // Persist last-signed-slot BEFORE block emission. Failures are
                                    // logged but do not abort — in-memory gate already advanced.
                                    sign_log.record(forge_slot);
                                    // forge_stats: KES sign succeeded — record successful attempt.
                                    forge_stats.onForgeAttempt(forge_slot, true);

                                    // Assemble header
                                    var forge_hdr_buf: [2048]u8 = undefined;
                                    const forge_hdr_result = cbor_block_full.assembleHeader(&forge_hdr_buf, forge_hdr_body.bytes[0..forge_hdr_body.len], forge_kes_sig);

                                    // Assemble full block — use dynamic body if txs included, else empty
                                    const forge_tb_cbor = if (forge_dyn_body) |db| db.tx_bodies_cbor else forge_body_std.tx_bodies_cbor;
                                    const forge_wt_cbor = if (forge_dyn_body) |db| db.witnesses_cbor else forge_body_std.witnesses_cbor;
                                    const forge_ad_cbor = if (forge_dyn_body) |db| db.aux_data_cbor else forge_body_std.aux_data_cbor;
                                    const forge_it_cbor = forge_body_std.invalid_txs_cbor;

                                    // Phase 7: forge header self-consistency guard.
                                    // Verify header's body_hash/body_size match the actual body we will emit.
                                    {
                                        const recomp_body_hash = cbor_block_body.computeBodyHash(forge_tb_cbor, forge_wt_cbor, forge_ad_cbor, forge_it_cbor);
                                        const actual_body_size: u64 = @intCast(forge_tb_cbor.len + forge_wt_cbor.len + forge_ad_cbor.len + forge_it_cbor.len);
                                        if (!std.mem.eql(u8, &recomp_body_hash, &forge_use_body_hash)) {
                                            std.debug.print("FORGE_HEADER_INCONSISTENT: reason=body_hash_mismatch slot={d}\n", .{forge_slot});
                                            ctx.forge_refused_total += 1;
                                            forge_stats.onForgeAttempt(forge_slot, false);
                                            break :forge_promote_inner;
                                        }
                                        if (actual_body_size != forge_use_body_size) {
                                            std.debug.print("FORGE_HEADER_INCONSISTENT: reason=body_size_mismatch slot={d} hdr={d} actual={d}\n", .{ forge_slot, forge_use_body_size, actual_body_size });
                                            ctx.forge_refused_total += 1;
                                            forge_stats.onForgeAttempt(forge_slot, false);
                                            break :forge_promote_inner;
                                        }
                                        var recomp_hdr_hash2: [32]u8 = undefined;
                                        std.crypto.hash.blake2.Blake2b256.hash(forge_hdr_buf[0..forge_hdr_result.len], &recomp_hdr_hash2, .{});
                                        if (!std.mem.eql(u8, &recomp_hdr_hash2, &forge_hdr_result.header_hash)) {
                                            std.debug.print("FORGE_HEADER_INCONSISTENT: reason=header_hash_unstable slot={d}\n", .{forge_slot});
                                            ctx.forge_refused_total += 1;
                                            forge_stats.onForgeAttempt(forge_slot, false);
                                            break :forge_promote_inner;
                                        }
                                        std.debug.print("FORGE_HEADER_OK: slot={d} hdr={s} body={s}\n", .{ forge_slot, std.fmt.bytesToHex(forge_hdr_result.header_hash[0..8], .lower), std.fmt.bytesToHex(forge_use_body_hash[0..8], .lower) });
                                    }

                                    // ── FORGE_SELF_VERIFY: opcert sigma cryptographic self-check ──
                                    // Verify the constructed opcert's sigma signature against our own
                                    // cold_vkey BEFORE writing the block artifact + broadcasting. If
                                    // sigma was misconstructed (operator data error pasting the wrong
                                    // bytes into TSUNAGI_OPCERT_SIGMA_HEX), refuse the forge — no
                                    // opcert/KES burn, no peer-side rejection round-trip, immediate
                                    // diagnostic log.
                                    //
                                    // This is the catch-this-class-of-bug-forever gate. The opcert
                                    // sigma must satisfy:
                                    //   ed25519_verify(
                                    //     pk  = cold_vkey,
                                    //     msg = hot_kes_vkey(32) || seq_no_be(8) || kes_period_be(8),
                                    //     sig = opcert.sigma
                                    //   ) → success
                                    //
                                    // If it doesn't, every block we broadcast will be rejected by
                                    // peers at the opcert verify step (cardano-node's first
                                    // cryptographic check on incoming blocks). Catch here, refuse,
                                    // log, save operator 13+ hours of failed-silent-rejection wait.
                                    {
                                        const Ed25519 = std.crypto.sign.Ed25519;
                                        var sigma_msg: [48]u8 = undefined;
                                        @memcpy(sigma_msg[0..32], &forge_kes_root);
                                        std.mem.writeInt(u64, sigma_msg[32..40], ctx.dryrun_opcert_seq_no, .big);
                                        std.mem.writeInt(u64, sigma_msg[40..48], ctx.kes_start_period, .big);

                                        const cold_pk_parsed = Ed25519.PublicKey.fromBytes(ctx.dryrun_issuer_vk) catch {
                                            std.debug.print("FORGE_SELF_VERIFY_FAIL: gate=opcert reason=cold_vk_parse_failed slot={d}\n", .{forge_slot});
                                            ctx.forge_refused_total += 1;
                                            forge_stats.onForgeAttempt(forge_slot, false);
                                            break :forge_promote_inner;
                                        };
                                        const sigma_sig = Ed25519.Signature.fromBytes(ctx.dryrun_opcert_sigma);
                                        sigma_sig.verify(&sigma_msg, cold_pk_parsed) catch {
                                            std.debug.print("FORGE_SELF_VERIFY_FAIL: gate=opcert reason=ed25519_verify_failed slot={d} cold_vk_first8={x} kes_root_first8={x} seq={d} period={d} sigma_first8={x}\n", .{
                                                forge_slot,
                                                ctx.dryrun_issuer_vk[0..8],
                                                forge_kes_root[0..8],
                                                ctx.dryrun_opcert_seq_no,
                                                ctx.kes_start_period,
                                                ctx.dryrun_opcert_sigma[0..8],
                                            });
                                            ctx.forge_refused_total += 1;
                                            forge_stats.onForgeAttempt(forge_slot, false);
                                            break :forge_promote_inner;
                                        };
                                        std.debug.print("FORGE_SELF_VERIFY: gate=opcert pass=YES slot={d} cold_vk_first8={x} kes_root_first8={x} seq={d} period={d}\n", .{
                                            forge_slot,
                                            ctx.dryrun_issuer_vk[0..8],
                                            forge_kes_root[0..8],
                                            ctx.dryrun_opcert_seq_no,
                                            ctx.kes_start_period,
                                        });
                                    }

                                    // Buffer: 4KB for empty, heap for non-empty
                                    var forge_fb_buf: [4096]u8 = undefined;
                                    var forge_fb_heap: ?[]u8 = null;
                                    defer if (forge_fb_heap) |h| std.heap.page_allocator.free(h);
                                    const forge_fb_slice: []u8 = if (forge_dyn_body != null) blk: {
                                        const needed = forge_use_body_size + 2048 + 16;
                                        forge_fb_heap = std.heap.page_allocator.alloc(u8, @intCast(needed)) catch break :blk &forge_fb_buf;
                                        break :blk forge_fb_heap.?;
                                    } else &forge_fb_buf;

                                    const forge_full_len = cbor_block_full.assembleFullBlock(
                                        forge_fb_slice,
                                        cbor_block_full.CONWAY_BLOCK_ERA_TAG, // 7 — see constant doc (Byron double-tag); NOT 6
                                        forge_hdr_buf[0..forge_hdr_result.len],
                                        forge_tb_cbor,
                                        forge_wt_cbor,
                                        forge_ad_cbor,
                                        forge_it_cbor,
                                    );

                                    // ── FORGE_BLOCK_ENVELOPE self-verify (catch-this-class-forever gate) ──
                                    // The assembled block MUST be the canonical Conway BlockFetch envelope:
                                    //   [ era_tag=7 , [header, ...] ]  →  bytes begin 0x82 0x07 0x85
                                    // If the era tag is ever wrong again (e.g. 6 → routes to the relay's
                                    // Babbage decoder → rejected in the BlockFetch client before ChainDB,
                                    // no ChainDB trace, silent orphan), REFUSE the forge here rather than
                                    // broadcast a block the network will discard.
                                    if (forge_full_len < 3 or
                                        forge_fb_slice[0] != 0x82 or
                                        forge_fb_slice[1] != cbor_block_full.CONWAY_BLOCK_ERA_TAG or
                                        forge_fb_slice[2] != 0x85)
                                    {
                                        std.debug.print("FORGE_BLOCK_ENVELOPE_FAIL: slot={d} expected=82{x:0>2}85 got={x:0>2}{x:0>2}{x:0>2} len={d}\n", .{
                                            forge_slot,
                                            cbor_block_full.CONWAY_BLOCK_ERA_TAG,
                                            forge_fb_slice[0],
                                            if (forge_full_len > 1) forge_fb_slice[1] else 0,
                                            if (forge_full_len > 2) forge_fb_slice[2] else 0,
                                            forge_full_len,
                                        });
                                        ctx.forge_refused_total += 1;
                                        forge_stats.onForgeAttempt(forge_slot, false);
                                        break :forge_promote_inner;
                                    }
                                    // Operator evidence: print the ACTUAL assembled prefix bytes (no hardcoded
                                    // string) immediately before promotion, so the log is unambiguous proof
                                    // that what we are about to promote/serve begins 82 07 85 (Conway block).
                                    const fbp_hex = std.fmt.bytesToHex(forge_fb_slice[0..3], .lower);
                                    std.debug.print("FORGE_BLOCK_ENVELOPE_OK: slot={d} era_tag={d} prefix={s} block_len={d}\n", .{
                                        forge_slot,
                                        cbor_block_full.CONWAY_BLOCK_ERA_TAG,
                                        fbp_hex, // actual first 3 bytes of block.cbor → expect "820785"
                                        forge_full_len,
                                    });

                                    const forge_base = ctx.forge_sim_dir.?;
                                var forge_dir_buf: [512]u8 = undefined;
                                const forge_dir = std.fmt.bufPrint(&forge_dir_buf, "{s}/{d}_{d}", .{ forge_base, artifact_unix, forge_slot }) catch "";
                                if (forge_dir.len > 0) {
                                    compat.fs.cwd().makePath(forge_dir) catch {};

                                    const f_hdr_hash_hex = std.fmt.bytesToHex(forge_hdr_result.header_hash, .lower);
                                    const f_body_hash_hex = std.fmt.bytesToHex(forge_use_body_hash, .lower);
                                    const f_cand_hdr_hex = std.fmt.bytesToHex(cand.header_hash, .lower);
                                    const f_cand_body_hex = std.fmt.bytesToHex(body.body_hash, .lower);

                                    // Write artifacts
                                    _ = dryrunWriteFile(forge_dir, "block.cbor", forge_fb_slice[0..forge_full_len]);
                                    _ = dryrunWriteFile(forge_dir, "block_header.cbor", forge_hdr_buf[0..forge_hdr_result.len]);
                                    _ = dryrunWriteFile(forge_dir, "block_header_hash.hex", &f_hdr_hash_hex);
                                    _ = dryrunWriteFile(forge_dir, "block_body_hash.hex", &f_body_hash_hex);
                                    _ = dryrunWriteFile(forge_dir, "header.cbor", &cand.bytes);
                                    _ = dryrunWriteFile(forge_dir, "header_hash.hex", &f_cand_hdr_hex);
                                    _ = dryrunWriteFile(forge_dir, "body_hash.hex", &f_cand_body_hex);
                                    _ = dryrunWriteFile(forge_dir, "header_body.cbor", real_hdr_body.bytes[0..real_hdr_body.len]);
                                    _ = dryrunWriteFile(forge_dir, "signature.bin", &forge_kes_sig);

                                    // meta.json (own buffer)
                                    {
                                        var f_meta_buf: [2048]u8 = undefined;
                                        const f_meta = std.fmt.bufPrint(&f_meta_buf,
                                            \\{{"mode":"forge","unix":{d},"net":"{s}","slot":{d},"block_no":{d},"leader":true,"u_x1e12":{d},"t_x1e12":{d},"kes_period":{d},"kes_valid":{d},"sig_kind":"real_kes","pool_id_hex":"{s}","kes_pk_hex":"{s}","kes_period_offset":{d},"signed_msg_mode":"direct"}}
                                        , .{
                                            artifact_unix,
                                            if (ctx.dryrun_net_name) |n| n else "unknown",
                                            forge_slot,
                                            fp_block_no + 1,
                                            ctx.praos_u_x1e12_last,
                                            ctx.praos_thresh_x1e12_last,
                                            ctx.kes_current_period_last,
                                            ctx.kes_period_valid_last,
                                            pool_id_hex_str,
                                            @as([]const u8, &kes_pk_hex_buf),
                                            kes_period_offset_val,
                                        }) catch "";
                                        if (f_meta.len > 0) _ = dryrunWriteFile(forge_dir, "meta.json", f_meta);
                                    }

                                    // verify.json (own buffer)
                                    {
                                        var f_vfy_buf: [256]u8 = undefined;
                                        const f_vfy = std.fmt.bufPrint(&f_vfy_buf,
                                            \\{{"hash_match":true,"sig_verify_ok":true,"sig_kind":"real_kes","mode":"forge"}}
                                        , .{}) catch "";
                                        if (f_vfy.len > 0) _ = dryrunWriteFile(forge_dir, "verify.json", f_vfy);
                                    }

                                    // tx metadata artifacts (if txs were included)
                                    if (included_exports) |exports| {
                                        if (exports.len > 0) {
                                            // included_tx_hashes.json
                                            {
                                                var json_buf = std.array_list.Managed(u8).init(std.heap.page_allocator);
                                                defer json_buf.deinit();
                                                json_buf.append('[') catch {};
                                                for (exports, 0..) |exp, idx| {
                                                    if (idx > 0) json_buf.append(',') catch {};
                                                    json_buf.append('"') catch {};
                                                    const hex = std.fmt.bytesToHex(exp.txid, .lower);
                                                    json_buf.appendSlice(&hex) catch {};
                                                    json_buf.append('"') catch {};
                                                }
                                                json_buf.append(']') catch {};
                                                if (json_buf.items.len > 2) _ = dryrunWriteFile(forge_dir, "included_tx_hashes.json", json_buf.items);
                                            }
                                            // included_tx_count.txt
                                            {
                                                var f_cnt_buf: [32]u8 = undefined;
                                                const f_cnt = std.fmt.bufPrint(&f_cnt_buf, "{d}", .{exports.len}) catch "";
                                                if (f_cnt.len > 0) _ = dryrunWriteFile(forge_dir, "included_tx_count.txt", f_cnt);
                                            }
                                        }
                                    }

                                    // forge_receipt.json
                                    {
                                        var rcpt_buf: [512]u8 = undefined;
                                        const rcpt = std.fmt.bufPrint(&rcpt_buf,
                                            \\{{"mode":"forge","consumed_token":true,"unix":{d},"slot":{d},"block_no":{d}}}
                                        , .{ artifact_unix, forge_slot, fp_block_no + 1 }) catch "";
                                        if (rcpt.len > 0) _ = dryrunWriteFile(forge_dir, "forge_receipt.json", rcpt);
                                    }

                                    // v3.8.0: broadcast_receipt.json (initial, announced=false)
                                    if (ctx.bcast_all_flags_set) {
                                        const tip_hash_hex = std.fmt.bytesToHex(fp_hash, .lower);
                                        var brcpt_buf: [768]u8 = undefined;
                                        const brcpt = std.fmt.bufPrint(&brcpt_buf,
                                            \\{{"mode":"broadcast","announced":false,"unix":{d},"slot":{d},"block_no":{d},"peers":0,"error":null,"no_inject":true,"tip_before":{{"slot":{d},"hash":"{s}"}},"tip_after":{{"slot":{d},"hash":"{s}"}}}}
                                        , .{
                                            artifact_unix,
                                            forge_slot,
                                            fp_block_no + 1,
                                            ctx.last_observed_slot,
                                            @as([]const u8, &tip_hash_hex),
                                            ctx.last_observed_slot,
                                            @as([]const u8, &tip_hash_hex),
                                        }) catch "";
                                        if (brcpt.len > 0) _ = dryrunWriteFile(forge_dir, "broadcast_receipt.json", brcpt);
                                    }

                                    ctx.forge_candidates_built += 1;
                                    ctx.forge_candidates_verified += 1;
                                    ctx.forge_last_slot = forge_slot;
                                    ctx.forge_last_unix = artifact_unix;
                                    std.debug.print("FORGE: block built slot={d} block_no={d} hdr_len={d} block_len={d} dir={s}\n", .{
                                        forge_slot, fp_block_no + 1, forge_hdr_result.len, forge_full_len, forge_dir,
                                    });
                                    std.debug.print("BLOCK_BUILD: slot={d} tx_count={d} body_size={d}\n", .{
                                        forge_slot, forge_tx_count, forge_use_body_size,
                                    });
                                    // Observation-only fallback warning: fires per forge when params are
                                    // missing or genesis-derived (source=0) rather than operator-supplied file.
                                    if (mempool_mod.g_protocol_params) |pp_obs| {
                                        if (pp_obs.source == 0) {
                                            std.debug.print("PROTOCOL_WARNING: fallback_active slot={d} — block construction may use outdated params\n", .{forge_slot});
                                        }
                                    } else {
                                        std.debug.print("PROTOCOL_WARNING: fallback_active slot={d} — block construction may use outdated params\n", .{forge_slot});
                                    }
                                    std.debug.print("EVENT_BLOCK_BUILD: slot={d} block_no={d} tx_count={d} body_size={d} block_len={d}\n", .{
                                        forge_slot, fp_block_no + 1, forge_tx_count, forge_use_body_size, forge_full_len,
                                    });
                                    // (Opcert bump moved to the single atomic block at the bottom of this
                                    //  forge path. Previously bumped here AND there, causing every forge
                                    //  to advance the counter by 2 and skip values cardano-node expects.)
                                    // Phase 9.4: record forge checkpoint for propagation latency.
                                    propagation_opt.onForge(forge_slot, fp_block_no + 1);
                                    // Phase 9.8: feedback snapshot — records gap + delay used at forge time.
                                    {
                                        const fb_eq = exec_quality.currentScore();
                                        const fb_delay = forge_delay.g_state.last_delay_ms;
                                        feedback.onForge(forge_slot, fp_block_no + 1, fb_eq.parent_gap, fb_delay);
                                    }
                                    // Phase 9.6: mark announce-readiness right at EVENT_BLOCK_BUILD.
                                    {
                                        const hdr_sz_usize: usize = if (forge_full_len >= forge_use_body_size) forge_full_len - forge_use_body_size else 0;
                                        const hdr_sz: u32 = @intCast(@min(hdr_sz_usize, std.math.maxInt(u32)));
                                        const body_sz: u32 = @intCast(@min(forge_use_body_size, std.math.maxInt(u32)));
                                        const total_sz: u32 = @intCast(@min(forge_full_len, std.math.maxInt(u32)));
                                        announce.onForge(forge_slot, fp_block_no + 1, hdr_sz, body_sz, total_sz);
                                    }
                                    // Phase 9.1: attribute parent source from multi-probe best-tip (observational).
                                    {
                                        const bt = multi_probe.getBestTip();
                                        if (bt.valid and bt.block == fp_block_no) {
                                            std.debug.print("FORGE_PARENT_SELECTED: source=multi_probe peer_id={d} block={d} slot={d} latency_ms={d}\n", .{
                                                bt.peer_id, bt.block, bt.slot, bt.latency_ms,
                                            });
                                        } else {
                                            std.debug.print("FORGE_PARENT_SELECTED: source=primary block={d}\n", .{fp_block_no});
                                        }
                                    }
                                    // Phase 8.1: record forge outcome for /status endpoint
                                    node_state.updateForge(forge_slot, compat.timestamp());
                                    // Phase 8.7: track build count for adaptive engine
                                    adaptive.onBlockBuilt(forge_slot);
                                    // Phase 8.95: hand off from pre-arm state
                                    prearm.onExecute(forge_slot, fp_block_no + 1);

                                    // Opcert counter: PINNED — do NOT increment per forge.
                                    //
                                    // ROOT CAUSE (FORGE_SELF_VERIFY_FAIL gate=opcert ed25519_verify_failed):
                                    // The operational certificate's sigma is a SINGLE cold-key signature over
                                    // (kes_vkey ‖ counter ‖ kes_period). It is valid for exactly ONE counter
                                    // value — the one baked into node.cert (here: 0). A Cardano opcert
                                    // legitimately signs EVERY block in its KES window with that SAME counter;
                                    // the counter only changes when the operator issues a NEW cert (KES
                                    // rotation), which re-signs the sigma with the cold key. The runtime has
                                    // no cold key, so it CANNOT re-sign — bumping the counter here desyncs the
                                    // reconstructed sigma_msg from the static sigma and makes FORGE_SELF_VERIFY
                                    // (and every peer's opcert check) fail forever. The old per-forge bump
                                    // walked opcert_state.json 0→15 across months of local forges, which is
                                    // exactly why seq=15 mismatched the sigma-over-0. Pin the counter to the
                                    // operator-issued value; persist the (unchanged) value so the on-disk
                                    // opcert_state.json self-heals toward the cert instead of drifting.
                                    //
                                    // preforge snapshot retained for the orphan watchdog rollback contract.
                                    ctx.preforge_opcert_seq_no = ctx.dryrun_opcert_seq_no;
                                    {
                                        const oc_old = ctx.dryrun_opcert_seq_no;
                                        const oc_new = oc_old; // PINNED (was: oc_old + 1) — see comment above
                                        ctx.dryrun_opcert_seq_no = oc_new;
                                        ctx.opcert_last_persisted = oc_new;
                                        if (compat.getenv("TSUNAGI_HOME")) |oc_home2| {
                                            var oc_pb2: [512]u8 = undefined;
                                            const oc_path2 = std.fmt.bufPrint(&oc_pb2, "{s}/opcert_state.json", .{oc_home2}) catch "";
                                            var oc_tmp_pb: [512]u8 = undefined;
                                            const oc_tmp = std.fmt.bufPrint(&oc_tmp_pb, "{s}/opcert_state.json.tmp", .{oc_home2}) catch "";
                                            var oc_body_buf: [128]u8 = undefined;
                                            const oc_body = std.fmt.bufPrint(&oc_body_buf,
                                                \\{{"seq_no":{d},"last_slot":{d}}}
                                            , .{ oc_new, forge_slot }) catch "";
                                            if (oc_path2.len > 0 and oc_tmp.len > 0 and oc_body.len > 0) {
                                                if (compat.fs.cwd().createFile(oc_tmp, .{ .truncate = true })) |f| {
                                                    var ff = f;
                                                    _ = ff.writeAll(oc_body) catch {};
                                                    ff.close();
                                                    compat.fs.cwd().rename(oc_tmp, oc_path2) catch {};
                                                } else |_| {}
                                            }
                                        }
                                        std.debug.print("OPCERT_PIN: slot={d} seq={d} (counter pinned to issued opcert; no per-forge bump)\n", .{ forge_slot, oc_new });
                                    }

                                    // Snapshot forged head for deterministic seal-tip promotion.
                                    // Writes to $TSUNAGI_HOME/forged_head_pending/ so seal-tip
                                    // can find it even after canonical chain_tip advances past.
                                    if (compat.getenv("TSUNAGI_HOME")) |snap_home| {
                                        var snap_dir_buf: [512]u8 = undefined;
                                        const snap_dir = std.fmt.bufPrint(&snap_dir_buf, "{s}/forged_head_pending", .{snap_home}) catch "";
                                        if (snap_dir.len > 0) {
                                            compat.fs.cwd().makePath(snap_dir) catch {};
                                            // Write parent identity so seal-tip can verify extension
                                            var parent_meta_buf: [256]u8 = undefined;
                                            const snap_parent = std.fmt.bufPrint(&parent_meta_buf,
                                                \\{{"parent_slot":{d},"parent_block_no":{d},"parent_hash":"{s}","forge_slot":{d},"forge_block_no":{d}}}
                                            , .{
                                                fp_slot, fp_block_no,
                                                &fp_hash,
                                                forge_slot, fp_block_no + 1,
                                            }) catch "";
                                            if (snap_parent.len > 0) _ = dryrunWriteFile(snap_dir, "parent.json", snap_parent);
                                            // Copy forge artifacts
                                            _ = dryrunWriteFile(snap_dir, "block_header.cbor", forge_hdr_buf[0..forge_hdr_result.len]);
                                            const snap_hdr_hash_hex = std.fmt.bytesToHex(forge_hdr_result.header_hash, .lower);
                                            _ = dryrunWriteFile(snap_dir, "block_header_hash.hex", &snap_hdr_hash_hex);
                                            _ = dryrunWriteFile(snap_dir, "block.cbor", forge_fb_slice[0..forge_full_len]);
                                            // Write meta.json (same as forge dir)
                                            var snap_meta_buf: [2048]u8 = undefined;
                                            const snap_meta = std.fmt.bufPrint(&snap_meta_buf,
                                                \\{{"slot":{d},"block_no":{d},"unix":{d}}}
                                            , .{ forge_slot, fp_block_no + 1, artifact_unix }) catch "";
                                            if (snap_meta.len > 0) _ = dryrunWriteFile(snap_dir, "meta.json", snap_meta);
                                            std.debug.print("FORGE SNAPSHOT: written to {s}\n", .{snap_dir});

                                            // ── ATOMIC FORGE PROMOTE ──
                                            // Write forged block directly to propagation_artifact/
                                            // so LIVE_PUSH can detect the change immediately.
                                            // This eliminates the race between forge and seal-tip timer.
                                            var art_dir_buf: [512]u8 = undefined;
                                            const art_dir = std.fmt.bufPrint(&art_dir_buf, "{s}/propagation_artifact", .{snap_home}) catch "";
                                            if (art_dir.len > 0) {
                                                // Verify artifact dir exists (created by seal-tip on first run)
                                                if (compat.fs.cwd().openDir(art_dir, .{})) |d| {
                                                    var dd = d;
                                                    dd.close();
                                                    // Write the 4 files that propagation_server reads.
                                                    // block.cbor write is GATING: if it fails we cannot
                                                    // serve the body, so we must not emit FORGE_PROMOTE_ATOMIC
                                                    // (which announces serveability).
                                                    //
                                                    // Two-phase artifact publication: clear stale `.ready` sentinel
                                                    // FIRST so propagation_server stalls on this generation until
                                                    // BOTH the sealed-block files AND the fragment ancestry are
                                                    // fully written. Without this fence, propagation_server's
                                                    // artifactChanged() poll can fire between the meta.json write
                                                    // and the fragment copy, serving a bundle with
                                                    // fragment_depth=0 — observed live at slot 113310132 on
                                                    // 2026-05-28 where cardano-node received the header but
                                                    // disconnected before BlockFetch.
                                                    {
                                                        var ready_clear_buf: [512]u8 = undefined;
                                                        const ready_clear_path = std.fmt.bufPrint(&ready_clear_buf, "{s}/.ready", .{art_dir}) catch "";
                                                        if (ready_clear_path.len > 0) compat.fs.cwd().deleteFile(ready_clear_path) catch {};
                                                    }
                                                    _ = dryrunWriteFile(art_dir, "block_header.cbor", forge_hdr_buf[0..forge_hdr_result.len]);
                                                    const block_cbor_ok = dryrunWriteFile(art_dir, "block.cbor", forge_fb_slice[0..forge_full_len]);
                                                    if (!block_cbor_ok) {
                                                        std.debug.print("FORGE_PROMOTE_BLOCK_CBOR_FAIL: slot={d}\n", .{forge_slot});
                                                    } else {
                                                    const art_hdr_hash_hex = std.fmt.bytesToHex(forge_hdr_result.header_hash, .lower);
                                                    _ = dryrunWriteFile(art_dir, "block_header_hash.hex", &art_hdr_hash_hex);
                                                    // meta.json (must match what propagation_server parses)
                                                    var art_meta_buf: [256]u8 = undefined;
                                                    const art_meta = std.fmt.bufPrint(&art_meta_buf,
                                                        \\{{"slot":{d},"block_no":{d},"unix":{d}}}
                                                    , .{ forge_slot, fp_block_no + 1, artifact_unix }) catch "";
                                                    if (art_meta.len > 0) _ = dryrunWriteFile(art_dir, "meta.json", art_meta);
                                                    // Also write prev_header artifacts for fragment continuity
                                                    const art_prev_hash_hex = std.fmt.bytesToHex(fp_hash, .lower);
                                                    _ = dryrunWriteFile(art_dir, "prev_header_hash.hex", &art_prev_hash_hex);
                                                    // signature.bin + verify.json for completeness
                                                    _ = dryrunWriteFile(art_dir, "signature.bin", &forge_kes_sig);
                                                    var art_vfy_buf: [128]u8 = undefined;
                                                    const art_vfy = std.fmt.bufPrint(&art_vfy_buf,
                                                        \\{{"hash_match":true,"sig_verify_ok":true,"sig_kind":"real_kes"}}
                                                    , .{}) catch "";
                                                    if (art_vfy.len > 0) _ = dryrunWriteFile(art_dir, "verify.json", art_vfy);
                                                    std.debug.print("FORGE_PROMOTE_ATOMIC: slot={d} block_no={d} hash={x} dir={s}\n", .{
                                                        forge_slot, fp_block_no + 1,
                                                        forge_hdr_result.header_hash[0..8],
                                                        art_dir,
                                                    });
                                                    // Phase 2: register forge with acceptance tracker for canonical-truth lifecycle
                                                    {
                                                        const acceptance_tracker = @import("acceptance_tracker.zig");
                                                        acceptance_tracker.registerForge(forge_slot, fp_block_no + 1, forge_hdr_result.header_hash);
                                                    }
                                                    // Write holdoff marker: "unix slot" — used by seal-tip (holdoff) and
                                                    // propagation_server (own_forge detection).
                                                    var holdoff_buf: [64]u8 = undefined;
                                                    const holdoff_str = std.fmt.bufPrint(&holdoff_buf, "{d} {d}", .{ artifact_unix, forge_slot }) catch "";
                                                    if (holdoff_str.len > 0) _ = dryrunWriteFile(art_dir, "forge_promoted_at.txt", holdoff_str);

                                                    // ── FRAGMENT COHERENCE ──
                                                    // Copy chain_tip/fragment/ → propagation_artifact/fragment/
                                                    // so the promoted sealed block has a coherent ancestor chain.
                                                    {
                                                        var src_frag_buf: [512]u8 = undefined;
                                                        const src_frag = std.fmt.bufPrint(&src_frag_buf, "{s}/chain_tip/fragment", .{snap_home}) catch "";
                                                        var dst_frag_buf: [512]u8 = undefined;
                                                        const dst_frag = std.fmt.bufPrint(&dst_frag_buf, "{s}/fragment", .{art_dir}) catch "";
                                                        if (src_frag.len > 0 and dst_frag.len > 0) {
                                                            const copied = copyFragmentDir(src_frag, dst_frag);

                                                            // ── FORGE PARENT APPEND ──
                                                            // The fragment tail is always 1 block behind the forge parent
                                                            // because saveChainTipHeader appends the OLD tip to fragment
                                                            // then writes the NEW block to header.cbor. The forge parent
                                                            // (= the new block) is in chain_tip/header.cbor but not yet
                                                            // in the fragment. Append it now so tail_hash == fp_hash.
                                                            var pre_tail = readFragmentTailHash(dst_frag);
                                                            const pre_match = pre_tail.valid and std.mem.eql(u8, &pre_tail.hash, &fp_hash);
                                                            if (!pre_match) {
                                                                // Read forge parent header from chain_tip/header.cbor
                                                                var tip_hdr_buf: [512]u8 = undefined;
                                                                const tip_hdr_path = std.fmt.bufPrint(&tip_hdr_buf, "{s}/chain_tip/header.cbor", .{snap_home}) catch "";
                                                                if (tip_hdr_path.len > 0) {
                                                                    if (readFileBounded(tip_hdr_path, 64 * 1024)) |tip_hdr| {
                                                                        defer std.heap.page_allocator.free(tip_hdr);
                                                                        // Append as next fragment entry
                                                                        const next_seq = fragmentNextSeq(dst_frag);
                                                                        appendFragmentEntry(dst_frag, next_seq, fp_slot, fp_block_no, fp_hash, tip_hdr);
                                                                        std.debug.print("FORGE_PARENT_APPEND: seq={d} slot={d} block_no={d} hash={x} hdr_len={d}\n", .{
                                                                            next_seq, fp_slot, fp_block_no, fp_hash[0..8], tip_hdr.len,
                                                                        });
                                                                    }
                                                                }
                                                            }

                                                            // Post-append verification
                                                            const tail_result = readFragmentTailHash(dst_frag);
                                                            const tail_matches = tail_result.valid and std.mem.eql(u8, &tail_result.hash, &fp_hash);
                                                            const frag_depth = countFragmentEntries(dst_frag);
                                                            const newest_slot = readFragmentNewestSlot(dst_frag);
                                                            const oldest_slot = readFragmentOldestSlot(dst_frag);
                                                            const gap: i128 = @as(i128, forge_slot) - @as(i128, newest_slot);
                                                            std.debug.print("FORGE_PROMOTE_FRAGMENT: src={s} dst={s} copied={d} sealed_slot={d} sealed_block_no={d} sealed_hash={x} sealed_prev_hash={x} fragment_oldest_slot={d} fragment_newest_slot={d} fragment_depth={d} tail_hash={x} tail_matches_sealed_parent={} sealed_fragment_gap_slots={d} artifact_coherent={} degraded_mode={}\n", .{
                                                                src_frag, dst_frag, copied,
                                                                forge_slot, fp_block_no + 1,
                                                                forge_hdr_result.header_hash[0..8],
                                                                fp_hash[0..8],
                                                                oldest_slot, newest_slot, frag_depth,
                                                                if (tail_result.valid) tail_result.hash[0..8] else &[_]u8{0} ** 8,
                                                                tail_matches, gap,
                                                                tail_matches, !tail_matches,
                                                            });
                                                        }
                                                    }
                                                    // Two-phase artifact publication: write `.ready` sentinel
                                                    // atomically (tmp + rename) NOW that both sealed-block files
                                                    // AND fragment ancestry are fully on disk. propagation_server
                                                    // refuses to load any artifact generation without this
                                                    // sentinel present. Pairs with the deleteFile at the start of
                                                    // FORGE_PROMOTE_ATOMIC.
                                                    {
                                                        var ready_tmp_buf: [512]u8 = undefined;
                                                        var ready_path_buf: [512]u8 = undefined;
                                                        const ready_tmp = std.fmt.bufPrint(&ready_tmp_buf, "{s}/.ready.tmp", .{art_dir}) catch "";
                                                        const ready_path = std.fmt.bufPrint(&ready_path_buf, "{s}/.ready", .{art_dir}) catch "";
                                                        if (ready_tmp.len > 0 and ready_path.len > 0) {
                                                            if (compat.fs.cwd().createFile(ready_tmp, .{ .truncate = true })) |f| {
                                                                var ff = f;
                                                                defer ff.close();
                                                                _ = ff.writeAll("1\n") catch {};
                                                            } else |_| {}
                                                            compat.fs.cwd().rename(ready_tmp, ready_path) catch {};
                                                        }
                                                    }
                                                    // notify AFTER fragment ancestry is coherent; earlier wakeup let propagation_server serve a header without a matching body chain
                                                    forge_notify.notify();
                                                    std.debug.print("NOTIFY_WAKE: slot={d}\n", .{forge_slot});
                                                    } // end of `else` for block_cbor_ok gate
                                                } else |_| {
                                                    std.debug.print("FORGE_PROMOTE_ATOMIC: SKIP artifact dir not found: {s}\n", .{art_dir});
                                                }
                                            }
                                        }
                                    }
                                    }

                                    // ── OWN-CHAIN INSERTION ──
                                    // Inject the forged block into TSUNAGI's own chain_tip state
                                    // so the propagation server serves it as the natural tip,
                                    // not as a separate late artifact.
                                    {
                                        // Snapshot pre-forge in-memory tip/frag_tail for orphan rollback.
                                        // (preforge_opcert_seq_no captured separately, BEFORE the opcert bump
                                        //  earlier in this forge path.)
                                        ctx.preforge_tip_slot = ctx.tip_slot_last;
                                        ctx.preforge_tip_block_no = ctx.tip_block_last;
                                        ctx.preforge_tip_hash = ctx.tip_hash_last;
                                        ctx.preforge_frag_tail_slot = ctx.frag_tail_slot;
                                        ctx.preforge_frag_tail_block_no = ctx.frag_tail_block_no;
                                        ctx.preforge_frag_tail_hash = ctx.frag_tail_hash;
                                        ctx.preforge_frag_tail_valid = ctx.frag_tail_valid;
                                        ctx.preforge_snapshot_valid = true;

                                        const follower = @import("../net/chainsync/follower.zig");
                                        var frag_tail: ?follower.FragmentTail = null;
                                        follower.saveChainTipHeader(
                                            forge_hdr_buf[0..forge_hdr_result.len],
                                            forge_hdr_result.header_hash,
                                            forge_slot,
                                            fp_block_no + 1,
                                            forge_fb_slice[0..forge_full_len],
                                            &frag_tail,
                                        );
                                        if (frag_tail) |tail| {
                                            ctx.frag_tail_slot = tail.slot;
                                            ctx.frag_tail_block_no = tail.block_no;
                                            ctx.frag_tail_hash = tail.hash;
                                            ctx.frag_tail_valid = true;
                                        }
                                        // Audit s4-t6 HIGH-1: do NOT optimistically write our own forged
                                        // block to tip_*_last. If first wasn't accepted, building on it
                                        // self-orphans. Wait for peer-confirmed RollForward to update tip.
                                        // Watchdog state (forge_orphan_armed_*) tracks our forge separately.
                                        std.debug.print("FORGE_OWN_CHAIN_INSERT: slot={d} block_no={d} hash={x} frag_tail_updated={} injection_target=chain_tip\n", .{
                                            forge_slot, fp_block_no + 1,
                                            forge_hdr_result.header_hash[0..8],
                                            frag_tail != null,
                                        });

                                        // Arm orphan watchdog.
                                        ctx.forge_orphan_watchdog_armed = true; ctx.forge_orphan_state = 1;
                                        ctx.forge_orphan_armed_slot = forge_slot;
                                        ctx.forge_orphan_armed_block_no = fp_block_no + 1;
                                        ctx.forge_orphan_armed_hash = forge_hdr_result.header_hash;
                                        ctx.forge_orphan_armed_unix = now_unix;
                                        const propagation_server_w = @import("../net/propagation_server.zig");
                                        const chainsync_server_w = @import("../protocols/chainsync_server.zig");
                                        ctx.forge_orphan_baseline_serve_disconnects =
                                            propagation_server_w.g_serve_header_only_disconnects.load(.acquire);
                                        ctx.forge_orphan_baseline_intersect_not_found =
                                            chainsync_server_w.g_intersect_not_found_total.load(.acquire);
                                        std.debug.print("FORGE_ORPHAN_WATCHDOG_ARMED: slot={d} block_no={d} hash={x} timeout_slots=10 baseline_serve_disc={d} baseline_int_nf={d}\n", .{
                                            forge_slot, fp_block_no + 1,
                                            forge_hdr_result.header_hash[0..8],
                                            ctx.forge_orphan_baseline_serve_disconnects,
                                            ctx.forge_orphan_baseline_intersect_not_found,
                                        });
                                    }

                                    // Record forge for slot uniqueness guard
                                    ctx.forge_last_forged_slot = current_slot;
                                    ctx.forge_last_forge_unix = now_unix;
                                }
                                } // forge_attempt
                            } else {
                                ctx.forge_refused_total += 1;
                                forge_stats.onForgeAttempt(current_slot, false);
                                // forge_last_refuse_reason already set by forgeInternalGate
                            }
                        }
                    }
                }
            }
        }
    }

    // v1.2.0 — Per-tick deterministic state digest (12 fields, 144 bytes)
    {
        var digest_hasher = Blake2b256.init(.{});
        var dbuf: [8]u8 = undefined;

        // 1. last_checked_slot (8 LE)
        std.mem.writeInt(u64, &dbuf, ctx.praos_last_checked_slot, .little);
        digest_hasher.update(&dbuf);
        // 2. u_x1e12 (8 LE)
        std.mem.writeInt(u64, &dbuf, ctx.praos_u_x1e12_last, .little);
        digest_hasher.update(&dbuf);
        // 3. threshold_x1e12 (8 LE)
        std.mem.writeInt(u64, &dbuf, ctx.praos_thresh_x1e12_last, .little);
        digest_hasher.update(&dbuf);
        // 4. u_lt_t (8 LE)
        std.mem.writeInt(u64, &dbuf, ctx.praos_u_lt_t, .little);
        digest_hasher.update(&dbuf);
        // 5. delta_x1e12 (8 LE)
        std.mem.writeInt(u64, &dbuf, ctx.praos_delta_x1e12, .little);
        digest_hasher.update(&dbuf);
        // 6. kes_period (8 LE)
        std.mem.writeInt(u64, &dbuf, ctx.kes_current_period_last, .little);
        digest_hasher.update(&dbuf);
        // 7. kes_valid (8 LE)
        std.mem.writeInt(u64, &dbuf, ctx.kes_period_valid_last, .little);
        digest_hasher.update(&dbuf);
        // 8. leader_last (8 LE)
        std.mem.writeInt(u64, &dbuf, ctx.praos_leader_last, .little);
        digest_hasher.update(&dbuf);
        // 9. header_hash (32 bytes: 4x8 LE)
        std.mem.writeInt(u64, &dbuf, ctx.candidate_hdr_hash_w0, .little);
        digest_hasher.update(&dbuf);
        std.mem.writeInt(u64, &dbuf, ctx.candidate_hdr_hash_w1, .little);
        digest_hasher.update(&dbuf);
        std.mem.writeInt(u64, &dbuf, ctx.candidate_hdr_hash_w2, .little);
        digest_hasher.update(&dbuf);
        std.mem.writeInt(u64, &dbuf, ctx.candidate_hdr_hash_w3, .little);
        digest_hasher.update(&dbuf);
        // 10. state_digest (32 bytes raw)
        digest_hasher.update(&ctx.producer_state_digest);
        // 11. pack_schema_version (8 LE)
        std.mem.writeInt(u64, &dbuf, PACK_SCHEMA_VERSION, .little);
        digest_hasher.update(&dbuf);
        // 12. state_schema_version (8 LE)
        std.mem.writeInt(u64, &dbuf, STATE_SCHEMA_VERSION, .little);
        digest_hasher.update(&dbuf);

        digest_hasher.final(&ctx.producer_state_digest);
    }

    ctx.state = .Tracking;
}

/// Read the freshest parent from cursor.json (written on every block delivery).
/// Post-forge orphan watchdog. Runs at the top of each executeTick.
///
/// Triggers a rollback if any of:
///   A) any probe peer reports last_block_no >= armed_block_no with a
///      hash different from our forged hash (network built on a fork
///      that does not include our block).
///   B) global serve_header_only_disconnects has incremented by >= 2
///      since arm (cardano-node walked our chain to the fork point and
///      dropped twice in a row without fetching the block).
///   C) global intersect_not_found_total has incremented by >= 1 since
///      arm (cardano-node's offered points don't match our fragment).
///
/// If the 10-slot window elapses with no contradiction signal, the
/// watchdog disarms cleanly and assumes the forge was accepted.
fn checkOrphanWatchdog(ctx: *ProducerContext, current_slot: u64) void {
    if (!ctx.forge_orphan_watchdog_armed) return;

    // Timeout — assume accepted.
    if (current_slot >= ctx.forge_orphan_armed_slot + 60) {
        std.debug.print("FORGE_ORPHAN_WATCHDOG_DISARM: slot={d} armed_slot={d} reason=timeout_assumed_accepted\n", .{
            current_slot, ctx.forge_orphan_armed_slot,
        });
        ctx.forge_orphan_watchdog_armed = false; ctx.forge_orphan_state = 0;
        ctx.preforge_snapshot_valid = false;
        return;
    }

    // Trigger A — probe at-or-past our height with a different hash.
    // PHASE 3 HARDENING: single-probe divergence transitions to SUSPECT_DIV,
    // does NOT immediately rollback. After SUSPECT_SETTLE_SLOTS (default 30),
    // consult acceptance_tracker (Koios-fed canonical view) for authoritative
    // confirmation. Single-probe rollbacks were causing false positives.
    const SUSPECT_SETTLE_SLOTS: u64 = blk: {
        if (compat.getenv("TSUNAGI_SUSPECT_SETTLE_SLOTS")) |s| {
            if (std.fmt.parseInt(u64, s, 10)) |v| break :blk v else |_| {}
        }
        break :blk 30;
    };

    if (ctx.forge_orphan_state == 1) { // ARMED
        var divergence_seen = false;
        {
            multi_probe.g_mu.lock();
            defer multi_probe.g_mu.unlock();
            var pi: u32 = 0;
            while (pi < multi_probe.MAX_PROBES) : (pi += 1) {
                const p = multi_probe.g_probe_peers[pi];
                if (!p.used) continue;
                if (p.last_block < ctx.forge_orphan_armed_block_no) continue;
                const all_zero = blk: {
                    var i: usize = 0;
                    while (i < 32) : (i += 1) if (p.last_hash[i] != 0) break :blk false;
                    break :blk true;
                };
                if (all_zero) continue;
                if (!std.mem.eql(u8, &p.last_hash, &ctx.forge_orphan_armed_hash)) {
                    std.debug.print("ROLLBACK_SUSPECT: probe_id={d} probe_block={d} probe_hash={x} armed_block={d} armed_hash={x} settle_slots={d}\n", .{
                        p.id, p.last_block, p.last_hash[0..8],
                        ctx.forge_orphan_armed_block_no, ctx.forge_orphan_armed_hash[0..8],
                        SUSPECT_SETTLE_SLOTS,
                    });
                    divergence_seen = true;
                    break;
                }
            }
        }
        if (divergence_seen) {
            ctx.forge_orphan_state = 2; // SUSPECT_DIV
            ctx.forge_orphan_suspect_slot = current_slot;
            return;
        }
    }

    // SUSPECT_DIV: settle, then ask acceptance_tracker (Koios) for the truth.
    if (ctx.forge_orphan_state == 2) {
        // Wait the settle window before consulting Koios.
        if (current_slot - ctx.forge_orphan_suspect_slot < SUSPECT_SETTLE_SLOTS) {
            std.debug.print("KOIOS_CONFIRMATION_PENDING: armed_slot={d} suspect_slot={d} settle_remaining={d}\n", .{
                ctx.forge_orphan_armed_slot, ctx.forge_orphan_suspect_slot,
                SUSPECT_SETTLE_SLOTS - (current_slot - ctx.forge_orphan_suspect_slot),
            });
            return;
        }

        // Consult acceptance_tracker — does our hash appear in canonical view?
        const acceptance_tracker = @import("acceptance_tracker.zig");
        const koios_status = acceptance_tracker.koiosKnowsHash(ctx.forge_orphan_armed_hash);
        switch (koios_status) {
            .found => {
                std.debug.print("FALSE_POSITIVE_ROLLBACK_PREVENTED: armed_slot={d} armed_block_no={d} armed_hash={x} koios=found\n", .{
                    ctx.forge_orphan_armed_slot, ctx.forge_orphan_armed_block_no,
                    ctx.forge_orphan_armed_hash[0..8],
                });
                std.debug.print("CANONICAL_CONFIRMED: forge_block={d} forge_hash={x}\n", .{
                    ctx.forge_orphan_armed_block_no, ctx.forge_orphan_armed_hash[0..8],
                });
                ctx.forge_orphan_watchdog_armed = false; ctx.forge_orphan_state = 0;
                ctx.forge_orphan_state = 0;
                ctx.preforge_snapshot_valid = false;
                return;
            },
            .not_found => {
                std.debug.print("ROLLBACK_CONFIRMED: reason=koios_confirmed_loss armed_hash={x}\n", .{
                    ctx.forge_orphan_armed_hash[0..8],
                });
                rollbackOrphan(ctx, "probe_divergence");
                return;
            },
            .unknown => {
                // Koios unreachable or no data; defer up to hard ceiling.
                const SUSPECT_HARD_CEILING_SLOTS: u64 = 120;
                if (current_slot >= ctx.forge_orphan_armed_slot + SUSPECT_HARD_CEILING_SLOTS) {
                    std.debug.print("ROLLBACK_CONFIRMED: reason=suspect_hard_ceiling armed_slot={d} current_slot={d}\n", .{
                        ctx.forge_orphan_armed_slot, current_slot,
                    });
                    rollbackOrphan(ctx, "probe_divergence");
                    return;
                }
                return;
            },
        }
    }

    // Trigger B — header-only disconnects since arm.
    {
        const propagation_server = @import("../net/propagation_server.zig");
        const sho_now = propagation_server.g_serve_header_only_disconnects.load(.acquire);
        const sho_delta = sho_now -% ctx.forge_orphan_baseline_serve_disconnects;
        if (sho_delta >= 2) {
            std.debug.print("ROLLBACK_TRIGGER: reason=serve_fail count={d} baseline={d}\n", .{
                sho_delta, ctx.forge_orphan_baseline_serve_disconnects,
            });
            rollbackOrphan(ctx, "serve_fail");
            return;
        }
    }

    // Trigger C — IntersectNotFound since arm.
    {
        const chainsync_server = @import("../protocols/chainsync_server.zig");
        const inf_now = chainsync_server.g_intersect_not_found_total.load(.acquire);
        const inf_delta = inf_now -% ctx.forge_orphan_baseline_intersect_not_found;
        if (inf_delta >= 1) {
            std.debug.print("ROLLBACK_TRIGGER: reason=intersect_fail count={d} baseline={d}\n", .{
                inf_delta, ctx.forge_orphan_baseline_intersect_not_found,
            });
            rollbackOrphan(ctx, "intersect_fail");
            return;
        }
    }
}

/// Roll producer state back to the pre-forge snapshot. In-memory tip and
/// frag_tail are restored; opcert counter is decremented and re-persisted.
///
/// On a HIGH-CONFIDENCE trigger (probe_divergence — an actual on-chain block
/// at our forged height with a different hash), the propagation_artifact dir
/// is also renamed aside so the propagation server stops re-serving the
/// orphan to cardano-node. Lower-confidence triggers (serve_fail,
/// intersect_fail) leave the artifact alone — they could fire on a winning
/// forge in adverse network conditions, and renaming a winning artifact
/// would prevent acceptance.
fn rollbackOrphan(ctx: *ProducerContext, reason: []const u8) void {
    if (!ctx.preforge_snapshot_valid) {
        std.debug.print("FORGE_ORPHAN_ROLLBACK_SKIP: reason={s} cause=no_snapshot\n", .{reason});
        ctx.forge_orphan_watchdog_armed = false; ctx.forge_orphan_state = 0;
        return;
    }
    const armed_slot = ctx.forge_orphan_armed_slot;
    const armed_block = ctx.forge_orphan_armed_block_no;
    const armed_hash = ctx.forge_orphan_armed_hash;

    ctx.tip_mutex.lock();
    ctx.tip_slot_last = ctx.preforge_tip_slot;
    ctx.tip_block_last = ctx.preforge_tip_block_no;
    ctx.tip_hash_last = ctx.preforge_tip_hash;
    ctx.tip_mutex.unlock();
    ctx.frag_tail_slot = ctx.preforge_frag_tail_slot;
    ctx.frag_tail_block_no = ctx.preforge_frag_tail_block_no;
    ctx.frag_tail_hash = ctx.preforge_frag_tail_hash;
    ctx.frag_tail_valid = ctx.preforge_frag_tail_valid;

    ctx.deferred_forge_pending = false;
    ctx.deferred_forge_executing = false;
    ctx.deferred_forge_awaiting_parent = false;

    const oc_pre = ctx.preforge_opcert_seq_no;
    ctx.dryrun_opcert_seq_no = oc_pre;
    ctx.opcert_last_persisted = oc_pre;
    persistOpcertCounter(oc_pre) catch |err| {
        std.debug.print("OPCERT_ROLLBACK_FAIL: err={s} target={d}\n", .{ @errorName(err), oc_pre });
    };

    // High-confidence rollback: rename artifact dir aside so propagation
    // server stops serving the orphan. Recoverable: original kept as
    // propagation_artifact.orphan.<unix>.
    if (std.mem.eql(u8, reason, "probe_divergence")) {
        if (compat.getenv("TSUNAGI_HOME")) |home| {
            const now_unix = compat.timestamp();
            var src_buf: [512]u8 = undefined;
            const src = std.fmt.bufPrint(&src_buf, "{s}/propagation_artifact", .{home}) catch "";
            var dst_buf: [600]u8 = undefined;
            const dst = std.fmt.bufPrint(&dst_buf, "{s}/propagation_artifact.orphan.{d}", .{ home, now_unix }) catch "";
            if (src.len > 0 and dst.len > 0) {
                if (compat.fs.cwd().rename(src, dst)) |_| {
                    compat.fs.cwd().makePath(src) catch {};
                    std.debug.print("FORGE_ORPHAN_ARTIFACT_QUARANTINED: src={s} dst={s} reason={s}\n", .{
                        src, dst, reason,
                    });
                } else |err| {
                    std.debug.print("FORGE_ORPHAN_ARTIFACT_QUARANTINE_FAIL: err={s} src={s}\n", .{
                        @errorName(err), src,
                    });
                }
            }
        }
    }

    ctx.forge_orphan_watchdog_armed = false; ctx.forge_orphan_state = 0;
    ctx.preforge_snapshot_valid = false;

    std.debug.print("FORGE_ORPHAN_ROLLBACK: reason={s} armed_slot={d} armed_block_no={d} armed_hash={x} restored_tip_slot={d} restored_tip_block={d} restored_opcert={d}\n", .{
        reason, armed_slot, armed_block, armed_hash[0..8],
        ctx.tip_slot_last, ctx.tip_block_last, oc_pre,
    });
}

/// Persist the opcert sequence counter to {TSUNAGI_HOME}/opcert_state.json.
/// Atomically writes via temp-file + rename. Best-effort: failure logs but
/// does not abort the forge (the in-memory counter has already advanced).
fn persistOpcertCounter(counter: u64) !void {
    const home = compat.getenv("TSUNAGI_HOME") orelse return error.NoTsunagiHome;
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/opcert_state.json", .{home});
    var tmp_buf: [520]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});

    var body_buf: [128]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "{{\"seq_no\":{d}}}\n", .{counter});

    {
        var f = try compat.fs.cwd().createFile(tmp_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(body);
    }
    try compat.fs.cwd().rename(tmp_path, path);
}

/// Returns null if the file is missing, unreadable, or unparseable.
const CursorParent = struct { slot: u64, block_no: u64, hash: [32]u8 };
fn readCursorParent(path: []const u8) ?CursorParent {
    var file = compat.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    var buf: [1024]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    if (n == 0) return null;
    const data = buf[0..n];

    // Parse "slot": N
    const slot = parseJsonU64(data, "\"slot\"") orelse return null;
    // Parse "block_no": N
    const block_no = parseJsonU64(data, "\"block_no\"") orelse return null;
    // Parse "header_hash_hex": "..."
    const hash_hex = parseJsonString(data, "\"header_hash_hex\"") orelse return null;
    if (hash_hex.len != 64) return null;
    var hash: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&hash, hash_hex) catch return null;
    return CursorParent{ .slot = slot, .block_no = block_no, .hash = hash };
}

fn parseJsonU64(data: []const u8, key: []const u8) ?u64 {
    const idx = std.mem.indexOf(u8, data, key) orelse return null;
    var pos = idx + key.len;
    // Skip whitespace and colon
    while (pos < data.len and (data[pos] == ' ' or data[pos] == ':' or data[pos] == '\t' or data[pos] == '\n')) : (pos += 1) {}
    var end = pos;
    while (end < data.len and data[end] >= '0' and data[end] <= '9') : (end += 1) {}
    if (end == pos) return null;
    return std.fmt.parseUnsigned(u64, data[pos..end], 10) catch null;
}

fn parseJsonString(data: []const u8, key: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, data, key) orelse return null;
    var pos = idx + key.len;
    // Skip to opening quote
    while (pos < data.len and data[pos] != '"') : (pos += 1) {}
    if (pos >= data.len) return null;
    pos += 1; // skip opening quote
    var end = pos;
    while (end < data.len and data[end] != '"') : (end += 1) {}
    if (end >= data.len) return null;
    return data[pos..end];
}

/// Map first 8 bytes of VRF output to uniform scalar u in [0, 1) scaled by 1e12.
pub fn vrfOutputToU_x1e12(output_bytes: [64]u8) u64 {
    // Praos leader value: blake2b256("L" || vrf_output)
    // Ref: Ouroboros.Consensus.Protocol.Praos.VRF hashVRF SVRFLeader
    var leader_input: [1 + 64]u8 = undefined;
    leader_input[0] = 'L';
    @memcpy(leader_input[1..65], &output_bytes);
    var leader_value: [32]u8 = undefined;
    Blake2b256.hash(&leader_input, &leader_value, .{});
    const r = std.mem.readInt(u64, leader_value[0..8], .big);
    const u_128: u128 = (@as(u128, r) * 1_000_000_000_000) / @as(u128, std.math.maxInt(u64));
    return @intCast(@max(1, u_128));
}

/// Compute Praos threshold T_x1e12 = floor((1 - (1-f)^sigma) * 1e12).
/// Uses E34 fixed-point arithmetic matching cardano-node exactly (v1.9.4).
pub fn computeThreshX1e12(stake_fraction_x1e9: u64, asc_x1e6: u64) u64 {
    return praos_e34.computeThresholdX1e12(stake_fraction_x1e9, asc_x1e6);
}

/// Praos leader check v2: VRF threshold math with full gating (observability only).
/// Returns (u_x1e12, thresh_x1e12, leader 0/1, reason_code).
/// Reason codes: 0=ok_leader, 1=vrf_disabled, 2=vrf_not_ready,
///               3=keys_not_ready, 4=clock_bad, 5=stake_zero, 6=not_leader
pub fn computePraosLeaderDecision(
    stake_fraction_x1e9: u64,
    asc_x1e6: u64,
    vrf_output_bytes: [64]u8,
    vrf_enabled: bool,
    vrf_init_ok: bool,
    vrf_output_present: bool,
    vrf_output_len: u64,
    vrf_verify_ok: bool,
    keys_ready: bool,
    clock_ok: bool,
) struct { u_x1e12: u64, thresh_x1e12: u64, leader: u64, reason: u64 } {
    // Gate: VRF must be enabled
    if (!vrf_enabled) return .{ .u_x1e12 = 0, .thresh_x1e12 = 0, .leader = 0, .reason = 1 };
    // Gate: VRF must be ready (init ok, output present, 64 bytes, verified)
    if (!vrf_init_ok or !vrf_output_present or vrf_output_len != 64 or !vrf_verify_ok)
        return .{ .u_x1e12 = 0, .thresh_x1e12 = 0, .leader = 0, .reason = 2 };
    // Gate: keys must be ready
    if (!keys_ready) return .{ .u_x1e12 = 0, .thresh_x1e12 = 0, .leader = 0, .reason = 3 };
    // Gate: clock must be ok
    if (!clock_ok) return .{ .u_x1e12 = 0, .thresh_x1e12 = 0, .leader = 0, .reason = 4 };
    // Gate: stake must be nonzero
    if (stake_fraction_x1e9 == 0) return .{ .u_x1e12 = 0, .thresh_x1e12 = 0, .leader = 0, .reason = 5 };

    // u_x1e12 from VRF output
    const u_x1e12 = vrfOutputToU_x1e12(vrf_output_bytes);

    // T_x1e12 = (f_x1e12 * σ_x1e12) / 1e12  (linear small-σ approximation)
    const thresh_x1e12 = computeThreshX1e12(stake_fraction_x1e9, asc_x1e6);

    if (thresh_x1e12 == 0) return .{ .u_x1e12 = u_x1e12, .thresh_x1e12 = 0, .leader = 0, .reason = 5 };

    // Leader if u < T (strict less-than, spec-aligned)
    if (u_x1e12 < thresh_x1e12) {
        return .{ .u_x1e12 = u_x1e12, .thresh_x1e12 = thresh_x1e12, .leader = 1, .reason = 0 };
    }
    return .{ .u_x1e12 = u_x1e12, .thresh_x1e12 = thresh_x1e12, .leader = 0, .reason = 6 };
}

/// Derive deterministic eligible slot from pool_id_hex using blake2b256.
/// Returns (blake2b256(pool_id_bytes)[0..8] as u64 big-endian) % slots_per_epoch.
/// Returns 0 if pool_id_hex is invalid.
fn computeEligSlot(pool_id_hex: []const u8, slots_per_epoch: u64) u64 {
    // Decode hex to bytes
    var pool_bytes: [32]u8 = undefined;
    const decoded_len = pool_id_hex.len / 2;
    if (decoded_len == 0 or decoded_len > 32) return 0;
    const decoded = std.fmt.hexToBytes(&pool_bytes, pool_id_hex) catch return 0;
    var digest: [32]u8 = undefined;
    Blake2b256.hash(decoded, &digest, .{});
    const slot_raw = std.mem.readInt(u64, digest[0..8], .big);
    return slot_raw % slots_per_epoch;
}

// v1.8.0: Dryrun artifact IO helper
/// Atomically replace the fragment directory: stage into a sibling dir, then rename.
/// propagate-serve never observes a half-written fragment/ because the rename is atomic.
/// Returns number of files copied, or 0 on failure (old fragment left intact).
fn copyFragmentDir(src_dir: []const u8, dst_dir: []const u8) u32 {
    // Stage path: dst_dir + ".staging" (e.g. propagation_artifact/fragment.staging)
    var stage_buf: [600]u8 = undefined;
    const stage_dir = std.fmt.bufPrint(&stage_buf, "{s}.staging", .{dst_dir}) catch return 0;

    // Old path: dst_dir + ".old" for the swap-out
    var old_buf: [600]u8 = undefined;
    const old_dir = std.fmt.bufPrint(&old_buf, "{s}.old", .{dst_dir}) catch return 0;

    // Clean up any leftover staging/old dirs from previous crashes
    compat.fs.cwd().deleteTree(stage_dir) catch {};
    compat.fs.cwd().deleteTree(old_dir) catch {};

    // Create staging directory
    compat.fs.cwd().makePath(stage_dir) catch return 0;

    // Copy all files from src to staging
    var src = compat.fs.cwd().openDir(src_dir, .{ .iterate = true }) catch return 0;
    defer src.close();
    var copied: u32 = 0;
    var it = src.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        var f = src.openFile(entry.name, .{}) catch continue;
        defer f.close();
        const data = f.readToEndAlloc(std.heap.page_allocator, 4 * 1024 * 1024) catch continue;
        defer std.heap.page_allocator.free(data);
        var staged_path_buf: [700]u8 = undefined;
        const staged_path = std.fmt.bufPrint(&staged_path_buf, "{s}/{s}", .{ stage_dir, entry.name }) catch continue;
        var out = compat.fs.cwd().createFile(staged_path, .{ .truncate = true }) catch continue;
        defer out.close();
        out.writeAll(data) catch continue;
        copied += 1;
    }

    if (copied == 0) {
        compat.fs.cwd().deleteTree(stage_dir) catch {};
        return 0;
    }

    // Atomic swap: rename current fragment → .old, rename staging → fragment
    // If current fragment doesn't exist, just rename staging into place.
    const has_current = if (compat.fs.cwd().openDir(dst_dir, .{})) |d| blk: {
        var dd = d;
        dd.close();
        break :blk true;
    } else |_| false;

    if (has_current) {
        compat.fs.cwd().rename(dst_dir, old_dir) catch {
            // Can't move old out of the way — abort, leave old fragment intact
            compat.fs.cwd().deleteTree(stage_dir) catch {};
            return 0;
        };
    }
    compat.fs.cwd().rename(stage_dir, dst_dir) catch {
        // Rename staging failed — restore old if we moved it
        if (has_current) {
            compat.fs.cwd().rename(old_dir, dst_dir) catch {};
        }
        compat.fs.cwd().deleteTree(stage_dir) catch {};
        return 0;
    };
    // Clean up old directory
    compat.fs.cwd().deleteTree(old_dir) catch {};

    return copied;
}

/// Read a bounded file from an absolute path. Returns owned slice or null.
fn readFileBounded(path: []const u8, max_size: usize) ?[]u8 {
    var f = compat.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    return f.readToEndAlloc(std.heap.page_allocator, max_size) catch null;
}

/// Find the next sequence number for a fragment directory (max existing + 1).
fn fragmentNextSeq(frag_dir: []const u8) u32 {
    var dir = compat.fs.cwd().openDir(frag_dir, .{ .iterate = true }) catch return 0;
    defer dir.close();
    var max_seq: u32 = 0;
    var found = false;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name.len >= 20 and std.mem.endsWith(u8, entry.name, ".header.cbor")) {
            const s = std.fmt.parseInt(u32, entry.name[0..8], 10) catch continue;
            if (!found or s > max_seq) { max_seq = s; found = true; }
        }
    }
    return if (found) max_seq + 1 else 0;
}

/// Append a single fragment entry (header.cbor + hash.hex + meta.json) to a fragment directory.
fn appendFragmentEntry(frag_dir: []const u8, seq: u32, slot: u64, block_no: u64, hash: [32]u8, header_cbor: []const u8) void {
    var seq_buf: [8]u8 = undefined;
    const seq_str = std.fmt.bufPrint(&seq_buf, "{d:0>8}", .{seq}) catch return;

    // header.cbor
    var hdr_buf: [600]u8 = undefined;
    const hdr_path = std.fmt.bufPrint(&hdr_buf, "{s}/{s}.header.cbor", .{ frag_dir, seq_str }) catch return;
    {
        var f = compat.fs.cwd().createFile(hdr_path, .{ .truncate = true }) catch return;
        defer f.close();
        f.writeAll(header_cbor) catch return;
    }

    // hash.hex
    const hash_hex = std.fmt.bytesToHex(hash, .lower);
    var hash_path_buf: [600]u8 = undefined;
    const hash_path = std.fmt.bufPrint(&hash_path_buf, "{s}/{s}.hash.hex", .{ frag_dir, seq_str }) catch return;
    {
        var f = compat.fs.cwd().createFile(hash_path, .{ .truncate = true }) catch return;
        defer f.close();
        f.writeAll(&hash_hex) catch return;
    }

    // meta.json
    var meta_content_buf: [128]u8 = undefined;
    const meta_content = std.fmt.bufPrint(&meta_content_buf, "{{\"slot\":{d},\"block_no\":{d}}}", .{ slot, block_no }) catch return;
    var meta_path_buf: [600]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&meta_path_buf, "{s}/{s}.meta.json", .{ frag_dir, seq_str }) catch return;
    {
        var f = compat.fs.cwd().createFile(meta_path, .{ .truncate = true }) catch return;
        defer f.close();
        f.writeAll(meta_content) catch return;
    }
}

/// Read the tail (highest-sequence) fragment entry's hash from a fragment directory.
const TailHashResult = struct { hash: [32]u8, valid: bool };
fn readFragmentTailHash(frag_dir: []const u8) TailHashResult {
    var dir = compat.fs.cwd().openDir(frag_dir, .{ .iterate = true }) catch return .{ .hash = [_]u8{0} ** 32, .valid = false };
    defer dir.close();
    var max_seq: u32 = 0;
    var found = false;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name.len >= 17 and std.mem.endsWith(u8, entry.name, ".hash.hex")) {
            const s = std.fmt.parseInt(u32, entry.name[0..8], 10) catch continue;
            if (!found or s > max_seq) {
                max_seq = s;
                found = true;
            }
        }
    }
    if (!found) return .{ .hash = [_]u8{0} ** 32, .valid = false };
    var path_buf: [600]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{d:0>8}.hash.hex", .{ frag_dir, max_seq }) catch return .{ .hash = [_]u8{0} ** 32, .valid = false };
    var f = compat.fs.cwd().openFile(path, .{}) catch return .{ .hash = [_]u8{0} ** 32, .valid = false };
    defer f.close();
    var hex_buf: [128]u8 = undefined;
    const n = f.readAll(&hex_buf) catch return .{ .hash = [_]u8{0} ** 32, .valid = false };
    const trimmed = std.mem.trim(u8, hex_buf[0..n], " \t\r\n");
    if (trimmed.len != 64) return .{ .hash = [_]u8{0} ** 32, .valid = false };
    var hash: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&hash, trimmed) catch return .{ .hash = [_]u8{0} ** 32, .valid = false };
    return .{ .hash = hash, .valid = true };
}

fn countFragmentEntries(frag_dir: []const u8) u32 {
    var dir = compat.fs.cwd().openDir(frag_dir, .{ .iterate = true }) catch return 0;
    defer dir.close();
    var count: u32 = 0;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name.len >= 20 and std.mem.endsWith(u8, entry.name, ".header.cbor")) count += 1;
    }
    return count;
}

fn readFragmentSlotFromMeta(frag_dir: []const u8, seq: u32) u64 {
    var path_buf: [600]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{d:0>8}.meta.json", .{ frag_dir, seq }) catch return 0;
    var f = compat.fs.cwd().openFile(path, .{}) catch return 0;
    defer f.close();
    var buf: [256]u8 = undefined;
    const n = f.readAll(&buf) catch return 0;
    const content = buf[0..n];
    // Simple parse: find "slot": and read the number
    const key = "\"slot\":";
    const idx = std.mem.indexOf(u8, content, key) orelse return 0;
    var pos = idx + key.len;
    while (pos < content.len and content[pos] == ' ') pos += 1;
    var end = pos;
    while (end < content.len and content[end] >= '0' and content[end] <= '9') end += 1;
    if (end == pos) return 0;
    return std.fmt.parseInt(u64, content[pos..end], 10) catch 0;
}

fn readFragmentNewestSlot(frag_dir: []const u8) u64 {
    var dir = compat.fs.cwd().openDir(frag_dir, .{ .iterate = true }) catch return 0;
    defer dir.close();
    var max_seq: u32 = 0;
    var found = false;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name.len >= 18 and std.mem.endsWith(u8, entry.name, ".meta.json")) {
            const s = std.fmt.parseInt(u32, entry.name[0..8], 10) catch continue;
            if (!found or s > max_seq) { max_seq = s; found = true; }
        }
    }
    if (!found) return 0;
    return readFragmentSlotFromMeta(frag_dir, max_seq);
}

fn readFragmentOldestSlot(frag_dir: []const u8) u64 {
    var dir = compat.fs.cwd().openDir(frag_dir, .{ .iterate = true }) catch return 0;
    defer dir.close();
    var min_seq: u32 = std.math.maxInt(u32);
    var found = false;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name.len >= 18 and std.mem.endsWith(u8, entry.name, ".meta.json")) {
            const s = std.fmt.parseInt(u32, entry.name[0..8], 10) catch continue;
            if (!found or s < min_seq) { min_seq = s; found = true; }
        }
    }
    if (!found) return 0;
    return readFragmentSlotFromMeta(frag_dir, min_seq);
}

/// Result of forge-time tx validation. `reason == null` means the tx is valid.
/// `persistent == true` means the failure won't change next slot, so the tx
/// should be evicted from the mempool. `persistent == false` is a transient
/// failure (double-spend against another tx in the candidate block) — keep it.
const TxIncludeCheck = struct {
    reason: ?[]const u8,
    persistent: bool,
};

/// Phase 5.5: Validate a candidate tx before block inclusion.
/// Returns reason=null if valid, or a reason string if invalid.
/// `persistent` distinguishes failures that will repeat next slot (parse, missing
/// UTxO, balance, self-duplicate-input) from transient failures (double_spend
/// against another tx in this same candidate block).
fn validateTxForInclusion(
    tx_bytes: []const u8,
    utxo_set_opt: ?*utxo_mod.UTxO,
    block_consumed: []const utxo_mod.TxIn,
) TxIncludeCheck {
    // Extract inputs from tx
    const inputs = tx_decode.extractTxInputsFromBytes(std.heap.page_allocator, tx_bytes) orelse
        return .{ .reason = "parse_fail", .persistent = true };
    defer std.heap.page_allocator.free(inputs);

    if (inputs.len == 0) return .{ .reason = "no_inputs", .persistent = true };

    // Check for duplicate inputs within the tx
    for (inputs, 0..) |a, i| {
        for (inputs[i + 1 ..]) |b| {
            if (std.mem.eql(u8, &a.tx_hash, &b.tx_hash) and a.index == b.index) {
                return .{ .reason = "duplicate_input", .persistent = true };
            }
        }
    }

    // Check for double-spends against already-consumed inputs in this block.
    // Transient: the conflicting tx may not be there next slot, so do NOT evict.
    for (inputs) |inp| {
        for (block_consumed) |consumed| {
            if (std.mem.eql(u8, &inp.tx_hash, &consumed.tx_hash) and inp.index == consumed.index) {
                return .{ .reason = "double_spend", .persistent = false };
            }
        }
    }

    // Check that inputs exist in the UTxO set + sum input lovelace
    var input_sum: u128 = 0;
    if (utxo_set_opt) |utxo_set| {
        for (inputs) |inp| {
            if (utxo_set.map.get(inp)) |txout| {
                input_sum += txout.lovelace;
            } else {
                return .{ .reason = "invalid_utxo", .persistent = true };
            }
        }

        // Phase 5.6: Fee validation — inputs must cover outputs (no value creation)
        const output_sum = extractTxOutputSum(tx_bytes);
        if (output_sum > 0 and input_sum < output_sum) {
            return .{ .reason = "insufficient_input", .persistent = true };
        }
    }

    return .{ .reason = null, .persistent = false }; // valid
}

/// Phase 5.6: Extract total output lovelace from raw tx bytes.
/// Parses tx → body → outputs (key 1) → sums lovelace.
/// Returns 0 on any parse failure (caller treats as "cannot validate").
fn extractTxOutputSum(tx_bytes: []const u8) u128 {
    const alloc = std.heap.page_allocator;
    const cbor = @import("../net/cbor/term.zig");
    var fbs = compat.fixedBufferStream(tx_bytes);
    const term = cbor.decode(alloc, fbs.reader()) catch return 0;
    defer cbor.free(term, alloc);

    // tx = [body, witnesses, ...] where body is map
    const body: cbor.Term = if (term == .array and term.array.len >= 1) blk: {
        const b = term.array[0];
        if (b == .map_u64) break :blk b;
        // CBOR-in-CBOR: decode inner bytes
        if (b == .bytes and b.bytes.len > 50) {
            var inner_fbs = compat.fixedBufferStream(b.bytes);
            const inner = cbor.decode(alloc, inner_fbs.reader()) catch break :blk b;
            if (inner == .map_u64) return sumOutputsFromBody(inner);
            return 0;
        }
        break :blk b;
    } else return 0;

    return sumOutputsFromBody(body);
}

fn sumOutputsFromBody(body: @import("../net/cbor/term.zig").Term) u128 {
    const tx_decode_local = @import("../net/ledger/tx_decode.zig");
    const outputs_term = if (body == .map_u64)
        tx_decode_local.findMapKeyPublic(body.map_u64, 1) orelse return 0
    else
        return 0;

    const items = if (outputs_term == .array) outputs_term.array
    else if (outputs_term == .tag and outputs_term.tag.value.* == .array) outputs_term.tag.value.*.array
    else return 0;

    var total: u128 = 0;
    for (items) |out| {
        if (out == .array and out.array.len >= 2) {
            // Legacy: [addr, value]
            total += extractLovelace(out.array[1]);
        } else if (out == .map_u64) {
            // Post-Alonzo: {0: addr, 1: value}
            if (tx_decode_local.findMapKeyPublic(out.map_u64, 1)) |val| {
                total += extractLovelace(val);
            }
        }
    }
    return total;
}

fn extractLovelace(val: @import("../net/cbor/term.zig").Term) u64 {
    if (val == .u64) return val.u64;
    if (val == .array and val.array.len >= 1 and val.array[0] == .u64) return val.array[0].u64;
    return 0;
}

fn dryrunWriteFile(dir: []const u8, name: []const u8, data: []const u8) bool {
    var path_buf: [600]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch |err| {
        std.debug.print("DRYRUN_WRITE_FAIL: stage=bufPrint path={s}/{s} err={s}\n", .{ dir, name, @errorName(err) });
        return false;
    };
    // Atomic write: tmp + rename. Prevents the propagation server background
    // thread from observing a half-written artifact during a forge promote.
    // The rename is the visibility boundary — until it lands, the canonical
    // path either holds the previous artifact or does not exist.
    var tmp_buf: [620]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch |err| {
        std.debug.print("DRYRUN_WRITE_FAIL: stage=bufPrint_tmp path={s} err={s}\n", .{ path, @errorName(err) });
        return false;
    };
    {
        var f = compat.fs.cwd().createFile(tmp_path, .{ .truncate = true }) catch |err| {
            std.debug.print("DRYRUN_WRITE_FAIL: stage=create path={s} err={s}\n", .{ tmp_path, @errorName(err) });
            return false;
        };
        defer f.close();
        f.writeAll(data) catch |err| {
            std.debug.print("DRYRUN_WRITE_FAIL: stage=write path={s} err={s}\n", .{ tmp_path, @errorName(err) });
            return false;
        };
        f.sync() catch {}; // best-effort fsync; rename below provides atomicity
    }
    compat.fs.cwd().rename(tmp_path, path) catch |err| {
        std.debug.print("DRYRUN_WRITE_FAIL: stage=rename src={s} dst={s} err={s}\n", .{ tmp_path, path, @errorName(err) });
        return false;
    };
    return true;
}

/// Apply KES period bookkeeping for the given slot.
///
/// Updates kes_current_period_last, kes_period_*_slot, rollover counters,
/// kes_period_valid_last + kes_period_reason_code_last, and notifies
/// kes_alerts. Does NOT touch leader/VRF/forge state. Safe to call from
/// either the per-block tick path or a wall-clock heartbeat.
fn applyKesPeriod(ctx: *ProducerContext, current_slot: u64) void {
    const cur_period = current_slot / SLOTS_PER_KES_PERIOD;
    ctx.kes_period_start_slot = cur_period * SLOTS_PER_KES_PERIOD;
    ctx.kes_period_end_slot = ctx.kes_period_start_slot + SLOTS_PER_KES_PERIOD - 1;

    // Rollover detection (before overwriting kes_current_period_last)
    if (ctx.kes_period_seen and cur_period != ctx.kes_current_period_last) {
        ctx.kes_rollovers_total += 1;
        ctx.kes_last_rollover_slot = current_slot;
    }
    ctx.kes_current_period_last = cur_period;
    ctx.kes_period_seen = true;

    if (!ctx.kes_sign_enabled) {
        ctx.kes_period_valid_last = 0;
        ctx.kes_period_reason_code_last = 1; // signing disabled
    } else if (cur_period < ctx.kes_start_period) {
        ctx.kes_period_valid_last = 0;
        ctx.kes_period_reason_code_last = 2; // not started yet
    } else if (cur_period >= ctx.kes_start_period + ctx.kes_max_periods) {
        ctx.kes_period_valid_last = 0;
        ctx.kes_period_reason_code_last = 3; // expired
    } else {
        ctx.kes_period_valid_last = 1;
        ctx.kes_period_reason_code_last = 0; // ok
    }

    // KES rotation early-warning. periods_remaining saturates at 0 so
    // expired keys do not underflow. Module dedupes per (period, tier)
    // and skips entirely when signing is disabled.
    const kes_end_period = ctx.kes_start_period + ctx.kes_max_periods;
    const periods_remaining: u64 = if (cur_period >= kes_end_period) 0 else kes_end_period - cur_period;
    kes_alerts.onPeriodUpdate(cur_period, periods_remaining, ctx.kes_sign_enabled);
}

/// Wall-clock KES heartbeat. Updates only the KES period bookkeeping
/// (kes_current_period_last, kes_period_valid_last, kes_period_reason_code_last,
/// rollover counters, kes_alerts) for the supplied wall-clock slot estimate.
///
/// Does NOT invoke leader check, VRF, forge logic, or scheduling. Safe to call
/// from the follower idle loop on a wall-clock cadence so KES period reporting
/// and rotation alerts continue to advance during chain stalls when tick() is
/// not being driven by block arrivals.
pub fn heartbeatKesPeriod(ctx: *ProducerContext, current_slot_estimate: u64) void {
    applyKesPeriod(ctx, current_slot_estimate);
}

/// Internal forge gate — fully deterministic, no external files, no TTL.
/// Every call logs a decision. No silent failures.
fn forgeInternalGate(ctx: *ProducerContext, current_slot: u64, now_unix: i64) bool {
    // 1. KES validity
    if (ctx.kes_period_valid_last != 1) {
        ctx.forge_last_refuse_reason = 5;
        logForgeGate(current_slot, false, "kes_invalid", ctx);
        return false;
    }

    // 2. Slot uniqueness — never forge the same slot twice
    if (current_slot <= ctx.forge_last_forged_slot and ctx.forge_last_forged_slot > 0) {
        ctx.forge_last_refuse_reason = 6;
        logForgeGate(current_slot, false, "duplicate_slot", ctx);
        return false;
    }

    // 3. Rate limit (safety) — no forge within 1 second of last
    if (ctx.forge_last_forge_unix > 0 and now_unix - ctx.forge_last_forge_unix < 1) {
        ctx.forge_last_refuse_reason = 7;
        logForgeGate(current_slot, false, "rate_limit", ctx);
        return false;
    }

    // ALLOW
    ctx.forge_last_refuse_reason = 0;
    logForgeGate(current_slot, true, "allow", ctx);
    return true;
}

fn logForgeGate(slot: u64, allow: bool, reason: []const u8, ctx: *ProducerContext) void {
    std.debug.print("FORGE_GATE_DECISION: slot={d} decision={s} reason={s} kes_valid={d} leader={} last_forged={d}\n", .{
        slot,
        if (allow) "ALLOW" else "DENY",
        reason,
        ctx.kes_period_valid_last,
        ctx.leader_eligible_last,
        ctx.forge_last_forged_slot,
    });
    // Phase 6 event: leader-eligible slot denied by gate == missed leader
    if (!allow and ctx.leader_eligible_last and slot != ctx.event_leader_missed_slot) {
        ctx.event_leader_missed_slot = slot;
        std.debug.print("EVENT_LEADER_MISSED: slot={d} epoch={d} reason={s}\n", .{
            slot, ctx.epoch_last, reason,
        });
    }
}

/// Check if BAeY safe_mode.json exists and has enabled=true.
fn checkSafeModeFile() bool {
    const home = compat.getenv("TSUNAGI_HOME") orelse return false;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/baey/safe_mode.json", .{home}) catch return false;
    var f = compat.fs.cwd().openFile(path, .{}) catch return false;
    defer f.close();
    var buf: [256]u8 = undefined;
    const n = f.readAll(&buf) catch return false;
    return std.mem.indexOf(u8, buf[0..n], "\"enabled\":true") != null;
}

// ─── FCC Test Matrix ────────────────────────────────────────────────
// Pure-function tests against fccConsultPure. Each test corresponds to
// one row of the FCC design test matrix. Tests 1-9 are unit-testable.
// Test 10 (transport regression audit) is post-deploy structural verification.

const fcc_orphan_hash: [32]u8 = [_]u8{0xA9} ** 32;
const fcc_canonical_hash: [32]u8 = [_]u8{0x6F} ** 32;
const fcc_fork_hash: [32]u8 = [_]u8{0xDE} ** 32;
const FCC_STALE_MAX: u64 = 120;

test "FCC#1 Case B reproduction — applied_tip orphan, rx canonical => override" {
    const r = fccConsultPure(
        4280497, fcc_orphan_hash,
        4280498, 112102540, fcc_canonical_hash, true,
        true, 30,
        fcc_canonical_hash, 112102510,
        FCC_STALE_MAX,
    );
    try std.testing.expect(r == .override);
    // parent_slot is the CANONICAL parent's slot (block N = 112102510), not rx_slot
    // (block N+1 = 112102540). Single-domain identity (slot/block/hash all describe N).
    try std.testing.expectEqual(@as(u64, 112102510), r.override.parent_slot);
    try std.testing.expectEqual(@as(u64, 4280497), r.override.parent_block);
    try std.testing.expect(std.mem.eql(u8, &r.override.parent_hash, &fcc_canonical_hash));
}

test "FCC#2 Case A preservation — applied_tip canonical, rx fork => refuse" {
    const r = fccConsultPure(
        4280497, fcc_canonical_hash,
        4280498, 112102540, fcc_fork_hash, true,
        true, 30,
        fcc_canonical_hash, 112102510,
        FCC_STALE_MAX,
    );
    try std.testing.expect(r == .refuse);
    try std.testing.expect(r.refuse == .case_a_applied_tip_canonical);
}

test "FCC#3 Case C both disagree => hard refuse" {
    const r = fccConsultPure(
        4280497, fcc_orphan_hash,
        4280498, 112102540, fcc_fork_hash, true,
        true, 30,
        fcc_canonical_hash, 112102510,
        FCC_STALE_MAX,
    );
    try std.testing.expect(r == .refuse);
    try std.testing.expect(r.refuse == .case_c_both_disagree);
}

test "FCC#4 acceptance_tracker stale => hard refuse" {
    // Threshold is 90s (first-principles justified — see fccConsultPure
    // doc comment). Test uses 91s to exercise strict-refusal branch.
    const r = fccConsultPure(
        4280497, fcc_orphan_hash,
        4280498, 112102540, fcc_canonical_hash, true,
        true, 91,
        fcc_canonical_hash, 112102510,
        FCC_STALE_MAX,
    );
    try std.testing.expect(r == .refuse);
    try std.testing.expect(r.refuse == .stale_acceptance_tracker);
}

test "FCC#4b fresh-within-90 => allow consultation" {
    // 89s is within the freshness window. TIER 1 local walk completes
    // in microseconds so age << 60s in steady state; 30s slack absorbs
    // poll jitter.
    const r = fccConsultPure(
        4280497, fcc_orphan_hash,
        4280498, 112102540, fcc_canonical_hash, true,
        true, 89,
        fcc_canonical_hash, 112102510,
        FCC_STALE_MAX,
    );
    try std.testing.expect(r == .override);
}

test "FCC#5 missing block in history => hard refuse" {
    const r = fccConsultPure(
        4280497, fcc_orphan_hash,
        4280498, 112102540, fcc_canonical_hash, true,
        true, 30,
        null, null,
        FCC_STALE_MAX,
    );
    try std.testing.expect(r == .refuse);
    try std.testing.expect(r.refuse == .block_not_in_history);
}

test "FCC#6 rx_prev_known=false => refuse" {
    const r = fccConsultPure(
        4280497, fcc_orphan_hash,
        4280498, 112102540, fcc_canonical_hash, false,
        true, 30,
        fcc_canonical_hash, 112102510,
        FCC_STALE_MAX,
    );
    try std.testing.expect(r == .refuse);
    try std.testing.expect(r.refuse == .rx_prev_unknown);
}

test "FCC#7 rx_block jump (not one step) => refuse" {
    const r = fccConsultPure(
        4280497, fcc_orphan_hash,
        4280499, 112102540, fcc_canonical_hash, true,
        true, 30,
        fcc_canonical_hash, 112102510,
        FCC_STALE_MAX,
    );
    try std.testing.expect(r == .refuse);
    try std.testing.expect(r.refuse == .not_one_step);
}

test "FCC#8 canonical slot distance exceeded => refuse" {
    const r = fccConsultPure(
        4280497, fcc_orphan_hash,
        4280498, 112102700, fcc_canonical_hash, true,
        true, 30,
        fcc_canonical_hash, 112102510,
        FCC_STALE_MAX,
    );
    try std.testing.expect(r == .refuse);
    try std.testing.expect(r.refuse == .canonical_slot_distance_exceeded);
}

test "FCC#9 feature disabled => refuse silently" {
    const r = fccConsultPure(
        4280497, fcc_orphan_hash,
        4280498, 112102540, fcc_canonical_hash, true,
        false, 30,
        fcc_canonical_hash, 112102510,
        FCC_STALE_MAX,
    );
    try std.testing.expect(r == .refuse);
    try std.testing.expect(r.refuse == .feature_disabled);
}

test "FCC bound — canonical_slot == rx_slot is permitted" {
    const r = fccConsultPure(
        4280497, fcc_orphan_hash,
        4280498, 112102510, fcc_canonical_hash, true,
        true, 30,
        fcc_canonical_hash, 112102510,
        FCC_STALE_MAX,
    );
    try std.testing.expect(r == .override);
}

test "FCC bound — canonical_slot > rx_slot (inverted) => refuse" {
    const r = fccConsultPure(
        4280497, fcc_orphan_hash,
        4280498, 112102510, fcc_canonical_hash, true,
        true, 30,
        fcc_canonical_hash, 112102600,
        FCC_STALE_MAX,
    );
    try std.testing.expect(r == .refuse);
    try std.testing.expect(r.refuse == .canonical_slot_distance_exceeded);
}
