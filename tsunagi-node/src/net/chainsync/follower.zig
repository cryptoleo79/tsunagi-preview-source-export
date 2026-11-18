const std = @import("std");
const compat = @import("compat");
const shutdown = @import("../../ops/shutdown.zig");

const cbor = @import("../cbor/term.zig");
const chainsync_codec = @import("chainsync_codec.zig");
const applied_tip_select = @import("applied_tip_select.zig");
const handshake_codec = @import("../handshake/handshake_codec.zig");
const mux_bearer = @import("../muxwire/mux_bearer.zig");
const bt_boundary = @import("../transport/byte_transport.zig");
const tcp_bt = @import("../transport/tcp_byte_transport.zig");
const header_raw = @import("../ledger/header_raw.zig");
const cursor_store = @import("../ledger/cursor.zig");
const tps = @import("../ledger/tps.zig");
const tx_decode = @import("../ledger/tx_decode.zig");
const tx_decoder = @import("../ledger/tx_decoder.zig");
const journal = @import("../ledger/journal.zig");
pub const utxo_mod = @import("../ledger/utxo.zig");
const blockfetch = @import("../miniproto/blockfetch.zig");
const txsubmission = @import("../miniproto/txsubmission.zig");
const keepalive = @import("../miniproto/keepalive.zig");
const http_metrics = @import("../metrics/http_metrics.zig");
const lmdb_utxo = @import("../../store/lmdb_utxo.zig");
const header_store_mod = @import("../../store/header_store.zig");
const producer = @import("../../producer/producer.zig");
const nonce_evolution = @import("../../producer/nonce_evolution.zig");
const candidate_validator = @import("../consensus/candidate_validator.zig");
const slot_clock = @import("../../producer/slot_clock.zig");
const pack = @import("../../producer/pack.zig");
const counting_allocator = @import("../../ops/counting_allocator.zig");
const ledger_pipeline = @import("../../ledger/ledger_pipeline.zig");
const block_hash = @import("../ledger/block_hash.zig");
const stake_state = @import("../ledger/stake_state.zig");
const stake_distribution = @import("../ledger/stake_distribution.zig");
const stake_snapshot = @import("../ledger/stake_snapshot.zig");
const node_state = @import("../../node_state.zig");
const signals = @import("../../producer/signals.zig");
const connection_registry = @import("../connection_registry.zig");

const chainsync_proto: u16 = 2;
const txsubmission_proto: u16 = 4;
const keepalive_proto: u16 = 8;

// Module-level nonce evolution state (persists across reconnections)
var g_nonce_state: nonce_evolution.NonceState = .{};
var g_nonce_state_loaded: bool = false;
var g_nonce_state_last_save_unix: i64 = 0;

// Module-level stake distribution state (persists across reconnections)
var g_stake_state: stake_state.StakeState = .{};
var g_stake_state_loaded: bool = false;
var g_stake_state_last_save_unix: i64 = 0;

// Module-level stake distribution (sigma computation)
pub var g_stake_dist: stake_distribution.StakeDistribution = .{};
var g_stake_dist_loaded: bool = false;
var g_stake_dist_last_save_unix: i64 = 0;

/// Approximate current epoch number from wall clock — used by Phase 4.2
/// bootstrap to query Koios for the right epoch_info snapshot.
pub fn currentEpochApprox() u64 {
    const now_unix = compat.timestamp();
    // Preview genesis unix = 1666656000; 1 slot/s; epoch = 86400 slots.
    if (now_unix <= 1666656000) return 0;
    const elapsed: u64 = @intCast(now_unix - 1666656000);
    return elapsed / 86400;
}

const Relay = struct {
    host: []const u8,
    port: u16,
};

const mainnet_relays = [_]Relay{
    .{ .host = "3.135.125.51", .port = 3001 },
    .{ .host = "3.9.192.44", .port = 3001 },
    .{ .host = "35.177.184.223", .port = 3001 },
    .{ .host = "34.216.201.242", .port = 3001 },
    .{ .host = "13.41.234.173", .port = 3001 },
};

const MAX_UNDO_DEPTH: usize = 200;
const UNDO_CONFIRM_DEPTH: usize = 3;
const STABILITY_DEPTH: u64 = 2160; // Cardano k parameter — max safe rollback depth

// Ledger anomaly bands
const MAX_FEE_EST_LOVELACE: u64 = 50_000_000; // 50 ADA
const DUST_THRESHOLD_LOVELACE: u64 = 1_000_000; // 1 ADA
const DUST_MIN_OUTPUTS: u64 = 50;
const DUST_RATIO_X1E6: u64 = 800_000; // 0.80
const WHALE_OUT_LOVELACE: u64 = 10_000_000_000_000; // 10M ADA

// Gap hunter
const MAX_GAP_KEYS: usize = 5000;
const MAX_SAMPLE_PER_BLOCK: usize = 10;
const GAP_TOPK: usize = 10;
const GAP_WINDOW_SECONDS: i64 = 300;

pub const Context = struct {
    cursor: cursor_store.Cursor,
    current_tip: ?cbor.Term = null,
    current_block: ?cbor.Term = null,
    current_point: ?cbor.Term = null,
    roll_forward_count: u64 = 0,
    rolls_since_last_rollback: u64 = 0,
    debug_verbose: bool = false,
    utxo: ?*utxo_mod.UTxO = null,
    undo_stack: ?*std.array_list.Managed(utxo_mod.Undo) = null,
    preview_utxo: bool = false,
    // Shadow ledger pipeline (advisory, TSUNAGI_LEDGER_SHADOW=1)
    shadow_pipeline: ?*ledger_pipeline.Pipeline = null,
    shadow_stats: ShadowStats = .{},
    // Primary ledger pipeline (TSUNAGI_LEDGER_PRIMARY=1)
    primary_pipeline: ?*ledger_pipeline.Pipeline = null,
    network_magic: u64 = 2,
    peer_sharing: bool = true,
    metrics: ?*const anyopaque = null,
    lmdb: ?lmdb_utxo.LmdbUtxo = null,
    utxo_count_est: i64 = 0,
    last_fallback_blocks: u64 = 0,
    last_fallback_change_unix: i64 = 0,
    convergence_marked: bool = false,
    // Convergence gate
    last_conv_gate_eval_unix: i64 = 0,
    conv_ready_since_unix: i64 = 0,
    conv_ready_latched_unix: i64 = 0,
    last_cbor_toolarge_log_unix: i64 = 0,
    last_cbor_eof_log_unix: i64 = 0,
    last_cbor_other_log_unix: i64 = 0,
    // DELIVERED_HEADER_PARSE observability rate-limit timestamp (OBSERVABILITY-ONLY,
    // never consumed by any decision path).
    last_delivered_header_dump_unix: i64 = 0,
    header_store: ?header_store_mod.HeaderStore = null,
    header_head: ?[32]u8 = null,
    header_height: u64 = 0,
    header_chain_mismatch_streak: u32 = 0,
    header_head_stable: bool = false,
    header_stable_consecutive: u32 = 0,
    last_header_chain_error_log_unix: i64 = 0,
    last_header_slot: u64 = 0,
    last_header_block_no: u64 = 0,
    last_header_violation_log_unix: i64 = 0,
    last_ledger_violation_log_unix: i64 = 0,
    ledger_violation_pending: bool = false,
    strict_start_unix: i64 = 0,
    strict_active: bool = false,
    ledger_missing_inputs_last: u64 = 0,
    ledger_missing_inputs_ema: f64 = 0.0,
    auto_strict_enabled: bool = false,
    last_auto_strict_check_unix: i64 = 0,
    last_auto_strict_log_unix: i64 = 0,
    density_window_start_slot: u64 = 0,
    density_window_block_count: u64 = 0,
    density_last_x1e6: u64 = 0,
    density_prev1_x1e6: u64 = 0,
    density_prev2_x1e6: u64 = 0,
    density_violation_streak: u32 = 0,
    last_density_violation_log_unix: i64 = 0,
    last_density_max_log_unix: i64 = 0,
    density_max_violation_streak: u32 = 0,
    density_max_triggered: bool = false,
    density_baseline_ema_f64: f64 = 0.0,
    density_baseline_updates: u64 = 0,
    last_density_baseline_log_unix: i64 = 0,
    rollback_window_start_unix: i64 = 0,
    rollback_window_count: u64 = 0,
    rollback_window_depth_sum: u64 = 0,
    rollback_window_depth_max: u64 = 0,
    last_rollback_flap_log_unix: i64 = 0,
    // v1.5.9: Rollback stabilization window
    tx_decode_journal_path: ?[]const u8 = null, // set by caller for BlockFetch journal writes
    rollback_stabilize_until_unix: i64 = 0,
    last_rollback_stabilize_log_unix: i64 = 0,
    last_lmdb_truth_error_log_unix: i64 = 0,
    last_lmdb_preflight_log_unix: i64 = 0,
    // Header probe state
    last_probe_unix: i64 = 0,
    probe_inflight: bool = false,
    best_probe_slot: u64 = 0,
    best_probe_block: u64 = 0,
    best_probe_peer_idx: usize = 0,
    // Per-peer tip tracking (multi-peer observability)
    peer_tip_slots: [8]u64 = [_]u64{0} ** 8,
    peer_tip_blocks: [8]u64 = [_]u64{0} ** 8,
    peer_tip_last_seen: [8]i64 = [_]i64{0} ** 8,
    peer_tip_ok: [8]bool = [_]bool{false} ** 8,
    peer_tip_probes_total: u64 = 0,
    peer_tip_disagree_total: u64 = 0,
    peer_tip_max_divergence_slots: u64 = 0,
    peer_tip_stale_count: u32 = 0,
    last_peer_tip_log_unix: i64 = 0,
    // Soft fork-choice gate
    rollback_low_confidence_total: u64 = 0,
    probe_result_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    probe_result_slot: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    probe_result_block: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    probe_result_peer_idx: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    probe_result_integrity_ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_probe_integrity_log_unix: i64 = 0,
    // KeepAlive strict
    last_keepalive_strict_log_unix: i64 = 0,
    // KES heartbeat — wall-clock period bookkeeping when chain is stalled.
    // Throttled to ~once per 10s so it doesn't fire on every loop iteration.
    last_kes_heartbeat_unix: i64 = 0,
    // Stall detection
    last_roll_fwd_unix: i64 = 0,
    stall_active: bool = false,
    last_stall_log_unix: i64 = 0,
    last_stall_switch_unix: i64 = 0,
    // PRIMARY FOLLOWER OBSERVABILITY (fix/primary-follower-observability)
    // OBSERVABILITY-ONLY: not consumed by any decision path; used only for log emission rate-limiting.
    primary_recv_timeouts_since_last_log: u64 = 0,
    primary_last_recv_log_unix: i64 = 0,
    primary_rollforwards_processed: u64 = 0,
    primary_intersect_completed: bool = false,
    primary_last_mux_log_unix: i64 = 0,
    primary_last_tip_promo_log_unix: i64 = 0,
    primary_mux_segments_seen_since_last_log: u64 = 0,
    // Chain selection policy
    preferred_peer_idx: ?usize = null,
    last_chain_select_switch_unix: i64 = 0,
    last_chain_select_log_unix: i64 = 0,
    // Gap hunter
    missing_inputs_map: ?std.AutoHashMap([36]u8, u32) = null,
    gap_keys_loaded: bool = false,
    gap_dir: ?[]const u8 = null,
    last_gap_persist_unix: i64 = 0,
    last_gap_log_unix: i64 = 0,
    // Gap hunter v2 — hot gaps + age + repeat ratio
    missing_inputs_first_seen: ?std.AutoHashMap([36]u8, u64) = null,
    last_first_seen_persist_unix: i64 = 0,
    gap_window_start_unix: i64 = 0,
    gap_window_missing_events: u64 = 0,
    gap_window_new_keys: u64 = 0,
    // Gap hunter v3 — LRU eviction
    missing_inputs_last_seen: ?std.AutoHashMap([36]u8, u64) = null,
    last_last_seen_persist_unix: i64 = 0,
    gap_evictions_total: u64 = 0,
    // Gap hunter v4 — 5-minute delta window
    gap_window_evictions: u64 = 0,
    gap_window_keys_start: u64 = 0,
    gap_window_resolved_start: u64 = 0,
    gap_hot_key_last: [36]u8 = [_]u8{0} ** 36,
    gap_hot_changes_5min: u64 = 0,
    // Consensus clock sanity
    clock_last_wall_unix: i64 = 0,
    clock_last_slot_seen: u64 = 0,
    clock_last_violation_log_unix: i64 = 0,
    // Ledger anomaly bands
    last_anomaly_log_unix: i64 = 0,
    // Consensus skeleton — 5-minute delta window
    consensus_window_start_unix: i64 = 0,
    consensus_herr_base: u64 = 0,
    consensus_kto_base: u64 = 0,
    consensus_rb_base: u64 = 0,
    consensus_herr_delta_5m: u64 = 0,
    consensus_kto_delta_5m: u64 = 0,
    consensus_rb_delta_5m: u64 = 0,
    // Stall attribution
    last_stall_attrib_log_unix: i64 = 0,
    stall_was_active: bool = false,
    // 5m delta bases (extended)
    consensus_bf_batch_base: u64 = 0,
    consensus_ka_pong_base: u64 = 0,
    consensus_pc_base: u64 = 0,
    consensus_hsw_base: u64 = 0,
    // Header validation
    header_validate_total: u64 = 0,
    header_validate_fail_total: u64 = 0,
    header_hash_mismatch_total: u64 = 0,
    header_prevhash_mismatch_total: u64 = 0,
    last_header_validate_log_unix: i64 = 0,
    // VRF validation (observe mode)
    vrf_validate_total: u64 = 0,
    vrf_validate_ok: u64 = 0,
    vrf_validate_skip: u64 = 0,
    vrf_validate_fail: u64 = 0,
    last_vrf_validate_log_unix: i64 = 0,
    // BAEY audit log
    baey_dir: ?[]const u8 = null,
    baey_last_peer_switch_unix: i64 = 0,
    baey_last_stall_unix: i64 = 0,
    baey_last_density_unix: i64 = 0,
    baey_last_rollback_unix: i64 = 0,
    baey_last_keepalive_unix: i64 = 0,
    baey_last_convergence_unix: i64 = 0,
    // Peer-tip telemetry (D-2). Peer-observed (slot, block_no, hash) from
    // RollForward envelope, retained explicitly so /status, KAGAMI, and
    // Prometheus can report peer-lag visibility now that the operator-
    // visible continuity surfaces are delivered-domain (D-1).
    peer_tip_slot: u64 = 0,
    peer_tip_block_no: u64 = 0,
    peer_tip_hash: [32]u8 = [_]u8{0} ** 32,
    peer_tip_observed_unix: i64 = 0,
    // Stale-suppression high-water in peer-tip domain (chainsync_mux_smoke
    // uses these instead of cursor.slot/block_no to preserve the original
    // PT-domain semantic of "reject peer-tip regression" after cursor
    // shifted to DLV).
    peer_tip_slot_last: u64 = 0,
    peer_tip_block_no_last: u64 = 0,
    // Authority model — fields renamed to peer_observed_authority_* (D-5)
    // since they track peer-observed authoritative tip, not delivered.
    peer_observed_authority_slot: u64 = 0,
    peer_observed_authority_block: u64 = 0,
    peer_observed_authority_hash: [32]u8 = [_]u8{0} ** 32,
    authority_confidence_x1e6: u64 = 1_000_000,
    authority_finality_score_x1e6: u64 = 0,
    authority_reorg_depth_last: u64 = 0,
    authority_reorg_events_5m: u64 = 0,
    authority_fork_events_total: u64 = 0,
    authority_window_start_unix: i64 = 0,
    authority_reorg_base: u64 = 0,
    // v3 additions
    authority_reorg_depth_sum_5m: u64 = 0,
    authority_reorg_depth_max_5m: u64 = 0,
    authority_fork_base: u64 = 0,
    authority_last_instability_unix: i64 = 0,
    authority_last_log_unix: i64 = 0,
    // v4: stability gate + reason codes
    authority_stable_gate_unix: i64 = 0,
    authority_stable_gate_active: bool = false,
    authority_stable_gate_seconds: u32 = 60,
    authority_reason_code_last: u64 = 0,
    // Eligibility edge detection
    producer_elig_last: u8 = 0,
    last_producer_elig_log_unix: i64 = 0,
    // Producer proof bundle
    last_producer_proof_unix: i64 = 0,
    // State digest
    last_state_digest_unix: i64 = 0,
    state_digest_blocks_since: u64 = 0,
    // Memory attribution tick
    last_mem_attrib_unix: i64 = 0,
    last_mem_attrib_gap_keys: u64 = 0,
    // FastSync controller
    fastsync_enabled: bool = false,
    fastsync_state: u8 = 0, // 0=OFF,1=WARMUP,2=PUSHING,3=READY
    fastsync_last_eval_unix: i64 = 0,
    fastsync_last_backfill_action_unix: i64 = 0,
    fastsync_last_capture_action_unix: i64 = 0,
    fastsync_last_tsf_action_unix: i64 = 0,
    fastsync_last_clear_action_unix: i64 = 0,
    fastsync_home_dir: ?[]const u8 = null,
    // Convergence slope window
    conv_slope_window_start_unix: i64 = 0,
    conv_slope_truth_base_x1e6: u64 = 0,
    conv_slope_value_base_x1e6: u64 = 0,
    conv_slope_ema_base: u64 = 0,
    // Block producer skeleton
    producer_ctx: producer.ProducerContext = .{
        .state = .Tracking,
        .last_slot_checked = 0,
        .last_leader_slot = 0,
        .leader_checks_total = 0,
        .clock = .{ .genesis_unix = 0, .slot_length_s = 1, .byron_slot_length_s = 0, .shelley_start_slot = 0, .shelley_start_unix = 0, .last_est_slot = 0, .last_est_unix = 0 },
        .last_observed_slot = 0,
        .drift_last_slots = 0,
        .drift_abs_max = 0,
        .drift_events_total = 0,
        .genesis_unix = 0,
        .slot_length_s = 1,
        .genesis_parse_ok = false,
        .genesis_path_ok = false,
        .genesis_last_error_code = 1,
        .slots_per_epoch = 86_400, // default to preview; overridden by initWithNet
        .shelley_start_slot = 0,
        .shelley_start_epoch = 0,
        .epoch_last = 0,
        .slot_in_epoch_last = 0,
        .leader_eligible_last = false,
        .leader_probability_x1e6 = 0,
        .leader_checks_epoch_total = 0,
        .vrf_cfg = .{ .enabled = false, .parse_ok = true, .key_path = null, .reason_code_last = 1, .init_ok = false, .seed = null, .pk = null, .sk = null },
        .vrf_attempt_total = 0,
        .vrf_checked_total = 0,
        .vrf_checked_last = false,
        .vrf_probability_x1e6_last = 0,
        .vrf_proof_present_last = false,
        .vrf_output_present_last = false,
        .vrf_reason_code_last = 0,
        .vrf_init_ok = false,
        .vrf_verify_ok_last = false,
        .vrf_output_prefix_last = 0,
        .vrf_tick_mode = 0,
        .last_vrf_checked_slot = 0,
        .vrf_skipped_total = 0,
        .vrf_proof_bytes_last = [_]u8{0} ** 80,
        .vrf_output_bytes_last = [_]u8{0} ** 64,
        .vrf_proof_len_last = 0,
        .vrf_output_len_last = 0,
        .vrf_proof_prefix_last = 0,
        .vrf_artifact_dirty = false,
        .key_cfg = .{ .enabled = false, .parse_ok = true, .kes_skey_path = null, .vrf_skey_path = null, .pool_id_hex = null, .last_error_code = 1 },
        .key_validate_total = 0,
        .key_err_code_last = 1,
        .pool_ok_last = 0,
        .kes_ok_last = 0,
        .vrf_ok_last = 0,
        .perms_ok_last = 0,
        .readable_ok_last = 0,
        .stake_cfg = .{ .stake_fraction_x1e9 = 0, .asc_x1e6 = 50_000, .parse_ok = true, .error_code = 3 },
        .leader_reason_code_last = 1,
        .expected_leaders_per_epoch = 0,
        .elig_test_enabled = false,
        .elig_test_slot_in_epoch = 0,
        .elig_test_window_s = 0,
        .elig_test_target_end = 0,
        .elig_test_override_enabled = false,
        .elig_test_override_target = 0,
        .elig_test_force_next_pending = false,
        .elig_test_force_next_offset = 0,
        .kes_cfg = .{ .enabled = false, .parse_ok = true, .key_path = null, .reason_code_last = 1 },
        .kes_attempt_total = 0,
        .kes_signed_total = 0,
        .kes_sig_present_last = 0,
        .kes_reason_code_last = 1,
        .tip_block_last = 0,
        .tip_slot_last = 0,
        .tip_hash_last = [_]u8{0} ** 32,
        .state_digest = [_]u8{0} ** 32,
        .genesis_network_magic = 0,
        .candidate_built_total = 0,
        .candidate_signed_total = 0,
        .candidate_last_slot = 0,
        .candidate_body_hash_prefix_last = 0,
        .candidate_sig_present_last = 0,
        .candidate_hdr_bytes_len = 0,
        .candidate_hdr_hash_w0 = 0,
        .candidate_hdr_hash_w1 = 0,
        .candidate_hdr_hash_w2 = 0,
        .candidate_hdr_hash_w3 = 0,
        .producer_state_digest = [_]u8{0} ** 32,
        .zig_sig_attempt_total = 0,
        .zig_sig_ok_total = 0,
        .zig_sig_present_last = 0,
        .zig_sig_prefix_last = 0,
        .zig_sig_reason_last = 0,
        .kes_sign_enabled = false,
        .kes_sign_seed = null,
        .kes_sign_attempt_total = 0,
        .kes_sign_ok_total = 0,
        .kes_sign_present_last = 0,
        .kes_sign_prefix_last = 0,
        .kes_sign_reason_last = 1,
        .kes_sign_label_last = 0,
        .candidate_sig_prefix_last = 0,
        .candidate_sign_reason_code_last = 1,
        .candidate_last_hdr_bytes = [_]u8{0} ** 198,
        .candidate_last_sig_bytes = [_]u8{0} ** 64,
        .candidate_sign_dirty = false,
        .body_cbor_len_last = 0,
        .body_hash_w0 = 0,
        .body_hash_w1 = 0,
        .body_hash_w2 = 0,
        .body_hash_w3 = 0,
        .body_cbor_bytes_last = [_]u8{0} ** 128,
        .body_artifact_dirty = false,
        .pack_dirty = false,
        .pack_total = 0,
        .pack_last_unix = 0,
        .praos_u_x1e12_last = 0,
        .praos_thresh_x1e12_last = 0,
        .praos_leader_last = 0,
        .praos_reason_code_last = 1,
        .praos_checks_total = 0,
        .praos_enabled = false,
        .praos_last_checked_slot = 0,
        .praos_u_lt_t = 0,
        .praos_delta_x1e12 = 0,
        // Slot scheduler (v1.1.0)
        .schedule_epoch_last = 0,
        .schedule_window_start_slot = 0,
        .schedule_window_size = 0,
        .schedule_leaders_in_window = 0,
        .schedule_next_leader_offset = 999999,
        .schedule_u0_x1e12 = 0,
        .schedule_t_x1e12 = 0,
        .schedule_reason_code_last = 0,
        .schedule_compute_total = 0,
        .schedule_compute_us_total = 0,
        .schedule_last_slot = 0,
        .schedule_last_update_us = 0,
        .vrf_compute_us_total = 0,
        .vrf_compute_us_last = 0,
        .tick_us_total = 0,
        .tick_us_last = 0,
        .tick_us_max = 0,
        .kes_current_period_last = 0,
        .kes_start_period = 0,
        .kes_max_periods = 62,
        .kes_period_valid_last = 0,
        .kes_period_reason_code_last = 1,
        // KES lifecycle hardening (v1.1.2)
        .kes_period_start_slot = 0,
        .kes_period_end_slot = 0,
        .kes_rollovers_total = 0,
        .kes_last_rollover_slot = 0,
        .kes_out_of_range_total = 0,
        .kes_sign_refused_total = 0,
        .kes_period_seen = false,
        // Producer dry-run (v1.8.0)
        .dryrun_enabled = false,
        .dryrun_home_dir = null,
        .dryrun_net_name = null,
        .dryrun_slots_checked = 0,
        .dryrun_leader_slots = 0,
        .dryrun_candidates_built = 0,
        .dryrun_candidates_verified = 0,
        .dryrun_last_leader_slot = 0,
        .dryrun_last_candidate_unix = 0,
        .dryrun_last_verify_ok = 0,
        // Real KES signing (v1.8.7)
        .kes_key_kind = .unknown,
        .kes_key_state = std.mem.zeroes([612]u8),
        .kes_key_state_len = 0,
        .kes_key_evolved_offset = 0xFFFFFFFF,
        .candidate_last_kes_sig = std.mem.zeroes([448]u8),
        .dryrun_candidates_signed = 0,
        .dryrun_last_sign_verify_ok = 0,
        // v2.0.0-alpha: Full Cardano block candidate (dryrun-only)
        .dryrun_block_enabled = false,
        .dryrun_issuer_vk = std.mem.zeroes([32]u8),
        .dryrun_opcert_seq_no = 0,
        .dryrun_opcert_sigma = std.mem.zeroes([64]u8),
        .dryrun_pv_major = 11,
        .dryrun_pv_minor = 0,
        .dryrun_block_candidates_built = 0,
        .dryrun_blocks_dir = null,
        .dryrun_mempool = null,
    },
};

pub const Callbacks = struct {
    on_roll_forward: fn (
        ctx: *anyopaque,
        tip_slot: u64,
        tip_block: u64,
        tip_hash32: [32]u8,
        header_hash32: [32]u8,
        tx_count: u64,
        inputs_consumed: u32,
        outputs_produced: u32,
        tx_summaries: tx_decoder.BlockTxResult,
        tx_bodies_cbor: ?[]const u8,
    ) anyerror!void,
    on_roll_backward: fn (
        ctx: *anyopaque,
        tip_slot: u64,
        tip_block: u64,
        tip_hash32: [32]u8,
        // Phase B'''': delivered rollback point (the point we are
        // rolling BACK TO). tip_* describe peer's far tip; the point
        // describes the new delivered tip after the rollback.
        point_slot: u64,
        point_block: u64,
        point_hash: [32]u8,
    ) anyerror!void,
    on_status: fn (
        ctx: *anyopaque,
        slot: u64,
        block: u64,
        fwd: u64,
        back: u64,
        tip_prefix8: [8]u8,
    ) void,
    on_shutdown: fn (ctx: *anyopaque) void,
    /// Optional: peer connected (TCP + handshake succeeded).
    on_peer_connect: ?fn (ctx: *anyopaque, host: []const u8, port: u16) void = null,
    /// Optional: peer disconnected (reason e.g. "stream_error", "keepalive_timeout").
    on_peer_disconnect: ?fn (ctx: *anyopaque, host: []const u8, port: u16, reason: []const u8) void = null,
};

pub const HeaderCborInfo = struct {
    cbor_bytes: []u8,
    prev_hash: ?[32]u8,
    /// Full header CBOR: [header_body, kes_sig]. Used for fragment writing.
    /// Caller must free separately from cbor_bytes.
    full_header_cbor: ?[]u8 = null,
};

var g_should_stop: ?*bool = null;
var g_signal_received: bool = false;
var g_signal_logged: bool = false;

/// Read-only accessor for callers (e.g. an outer peer-rotation loop) that need
/// to distinguish "runWithOptions returned due to operator signal" from
/// "returned due to peer error". Pure export, no behavior change.
pub fn shutdownRequested() bool {
    return g_signal_received;
}

pub const SelectedPeer = struct {
    host: []u8,
    port: u16,
};

// 0.16 port: std.net was removed. std.net.Address -> a generic *std.posix.sockaddr
// + length pair; the socket/connect/poll path is plain std.posix (unchanged in 0.16).
fn connectWithTimeout(addr: *const std.posix.sockaddr, addr_len: std.posix.socklen_t, timeout_ms: u32) bool {
    const sock_flags = std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC;
    // 0.16 port: std.posix.{socket,connect,close,getsockoptError} were removed
    // (constants/types + std.posix.poll remain). Use compat libc-backed wrappers
    // that replicate the 0.15 errno->error mappings exactly.
    const sockfd = compat.socket(addr.family, sock_flags, std.posix.IPPROTO.TCP) catch return false;
    defer compat.closeSocket(sockfd);

    if (compat.connect(sockfd, addr, addr_len)) |_| {
        return true;
    } else |err| switch (err) {
        error.WouldBlock, error.ConnectionPending => {},
        else => return false,
    }

    var fds = [_]std.posix.pollfd{.{ .fd = sockfd, .events = std.posix.POLL.OUT, .revents = 0 }};
    const poll_rc = std.posix.poll(fds[0..], @intCast(timeout_ms)) catch return false;
    if (poll_rc == 0) return false;

    compat.getsockoptError(sockfd) catch return false;
    return true;
}

// `addr_bytes` are the 4 IPv4 octets in network byte order (== dotted-quad order),
// identical to the bytes the old std.net.Ip4Address.sa.addr exposed.
fn formatIpv4Host(alloc: std.mem.Allocator, addr_bytes: [4]u8) ![]u8 {
    var buf: [15]u8 = undefined;
    const ip = try std.fmt.bufPrint(&buf, "{}.{}.{}.{}", .{
        addr_bytes[0],
        addr_bytes[1],
        addr_bytes[2],
        addr_bytes[3],
    });
    return alloc.dupe(u8, ip);
}

pub fn selectReachableIpv4(
    alloc: std.mem.Allocator,
    hostname: []const u8,
    port: u16,
    timeout_ms: u32,
) !?SelectedPeer {
    // 0.16 has no std.net.getAddressList equivalent (std.Io.net only parses
    // literals + IPv6 scopes; no DNS). Preserve the original DNS-resolution
    // behavior via libc getaddrinfo directly (every TSUNAGI target links libc),
    // which is exactly what std.net.getAddressList used under the hood.
    const host_z = try alloc.dupeZ(u8, hostname);
    defer alloc.free(host_z);
    var port_buf: [6]u8 = undefined;
    const port_z = try std.fmt.bufPrintZ(&port_buf, "{d}", .{port});

    const hints: std.c.addrinfo = .{
        .flags = .{},
        .family = std.posix.AF.INET,
        .socktype = std.posix.SOCK.STREAM,
        .protocol = std.posix.IPPROTO.TCP,
        .addrlen = 0,
        .canonname = null,
        .addr = null,
        .next = null,
    };
    var res: ?*std.c.addrinfo = null;
    switch (std.c.getaddrinfo(host_z.ptr, port_z.ptr, &hints, &res)) {
        @as(std.c.EAI, @enumFromInt(0)) => {},
        else => return error.UnknownHostName,
    }
    defer if (res) |r| std.c.freeaddrinfo(r);

    var it: ?*std.c.addrinfo = res;
    while (it) |info| : (it = info.next) {
        const sa = info.addr orelse continue;
        if (sa.family != std.posix.AF.INET) continue;
        if (connectWithTimeout(sa, info.addrlen, timeout_ms)) {
            const sa_in: *const std.posix.sockaddr.in = @ptrCast(@alignCast(sa));
            const host = try formatIpv4Host(alloc, @bitCast(sa_in.addr));
            return .{ .host = host, .port = port };
        }
    }
    return null;
}

pub fn selectMainnetPeer(alloc: std.mem.Allocator, timeout_ms: u32) !?SelectedPeer {
    const candidates = [_][]const u8{
        "backbone.cardano.iog.io",
        "backbone.mainnet.cardanofoundation.org",
        "backbone.mainnet.emurgornd.com",
    };

    for (candidates) |hostname| {
        if (try selectReachableIpv4(alloc, hostname, 3001, timeout_ms)) |peer| {
            return peer;
        }
    }
    return null;
}

fn vprint(debug_verbose: bool, comptime fmt: []const u8, args: anytype) void {
    if (debug_verbose) std.debug.print(fmt, args);
}

fn termKindName(term: cbor.Term) []const u8 {
    return switch (term) {
        .u64 => "u64",
        .i64 => "i64",
        .bool => "bool",
        .null => "null",
        .bytes => "bytes",
        .text => "text",
        .array => "array",
        .map_u64 => "map",
        .tag => "tag",
    };
}

fn logBlockShape(block: cbor.Term, tip_hash32: [32]u8) void {
    var tip_prefix: [8]u8 = [_]u8{'?'} ** 8;
    _ = std.fmt.bufPrint(
        &tip_prefix,
        "{x}",
        .{tip_hash32[0..4]},
    ) catch {};

    switch (block) {
        .array => |items| {
            const count = items.len;
            const first = @min(@as(usize, 3), count);
            std.debug.print("mainnet block shape tip={s} array len={d} first=[", .{ tip_prefix[0..], count });
            var i: usize = 0;
            while (i < first) : (i += 1) {
                if (i > 0) std.debug.print(",", .{});
                std.debug.print("{x}", .{termKindName(items[i])});
            }
            std.debug.print("]\n", .{});
        },
        .map_u64 => |entries| {
            std.debug.print("mainnet block shape tip={s} map len={d}\n", .{ tip_prefix[0..], entries.len });
        },
        .bytes => |b| {
            std.debug.print("mainnet block shape tip={s} bytes len={d}\n", .{ tip_prefix[0..], b.len });
        },
        .tag => |t| {
            switch (t.value.*) {
                .bytes => |b| {
                    std.debug.print(
                        "mainnet block shape tip={s} tag={d} bytes len={d}\n",
                        .{ tip_prefix[0..], t.tag, b.len },
                    );
                },
                else => {
                    std.debug.print(
                        "mainnet block shape tip={s} tag={d} inner={s}\n",
                        .{ tip_prefix[0..], t.tag, termKindName(t.value.*) },
                    );
                },
            }
        },
        else => {
            std.debug.print("mainnet block shape tip={s} {s}\n", .{ tip_prefix[0..], termKindName(block) });
        },
    }
}

fn hexHasValue(hex: []const u8) bool {
    for (hex) |b| {
        if (b != '0') return true;
    }
    return false;
}

fn handleSignal(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    if (g_should_stop) |ptr| {
        ptr.* = true;
    }
    g_signal_received = true;
    // TSUNAGI-native shared stop flag — detached worker threads check this
    // each loop iteration so SIGTERM brings the whole runtime down promptly.
    shutdown.requestStop();
}

fn installSignalHandlers(should_stop: *bool) !void {
    g_should_stop = should_stop;
    var action = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
}

fn checkStop(should_stop: *bool) bool {
    // Forge-readiness 2026-05-23: do NOT clear g_signal_received here.
    // main.zig's peer-rotation loop reads `shutdownRequested()` after
    // runWithOptions returns; clearing the flag here on first read
    // caused main.zig to miss the signal and rotate to a new peer
    // instead of exiting cleanly. The shared `shutdown.g_stop` is the
    // non-consuming view used by worker loops; `g_signal_received` is
    // the latched operator-asked-to-quit indicator that must survive.
    if (g_signal_received and !g_signal_logged) {
        g_signal_logged = true;
        std.debug.print("Signal received, shutting down...\n", .{});
    }
    return should_stop.* or shutdown.stopRequested();
}

/// Wall-clock KES heartbeat from the follower idle loop.
///
/// producer.tick() is the only writer of kes_current_period_last and the
/// only caller of kes_alerts.onPeriodUpdate. tick() runs from
/// onBlockFetched, so when the chain stalls KES period reporting and
/// rotation alerts go stale. This helper computes a wall-clock slot
/// estimate and calls producer.heartbeatKesPeriod, which updates ONLY
/// the KES period and alerts state (no leader, no VRF, no forge logic).
///
/// Throttled to roughly once per 10 seconds via last_heartbeat_unix.
fn maybeHeartbeatKes(ctx: *Context) void {
    const now = compat.timestamp();
    if (now - ctx.last_kes_heartbeat_unix < 10) return;
    ctx.last_kes_heartbeat_unix = now;

    const slot_len: i64 = if (ctx.producer_ctx.slot_length_s > 0) ctx.producer_ctx.slot_length_s else 1;
    const elapsed: i64 = now - ctx.producer_ctx.genesis_unix;
    if (elapsed <= 0 or ctx.producer_ctx.genesis_unix == 0) return;
    const est_slot: u64 = @intCast(@divTrunc(elapsed, slot_len));
    producer.heartbeatKesPeriod(&ctx.producer_ctx, est_slot);
}

fn maybePrintStatus(
    last_status_unix: *i64,
    callbacks: Callbacks,
    ctx_any: *anyopaque,
    cursor: *const cursor_store.Cursor,
) void {
    const now = compat.timestamp();
    if (now - last_status_unix.* >= 10) {
        last_status_unix.* = now;
        var tip_prefix8: [8]u8 = undefined;
        std.mem.copyForwards(u8, tip_prefix8[0..], cursor.tip_hash_hex[0..8]);
        callbacks.on_status(
            ctx_any,
            cursor.slot,
            cursor.block_no,
            cursor.roll_forward_count,
            cursor.roll_backward_count,
            tip_prefix8,
        );
    }
}

fn buildV14VersionData(
    alloc: std.mem.Allocator,
    network_magic: u64,
    peer_sharing: bool,
) !cbor.Term {
    // diffusion_mode: false=InitiatorOnly, true=InitiatorAndResponder
    // When TxSubmission is enabled, use InitiatorAndResponder so the relay
    // opens a TxSubmission2 session toward us (enabling active broadcast).
    const txsub_enabled = compat.hasEnvVar(alloc, "TSUNAGI_TXSUB_ENABLE");
    var version_items = try alloc.alloc(cbor.Term, 4);
    version_items[0] = .{ .u64 = network_magic };
    version_items[1] = .{ .bool = txsub_enabled };
    version_items[2] = .{ .u64 = if (peer_sharing) 1 else 0 };
    version_items[3] = .{ .bool = false };
    return cbor.Term{ .array = version_items };
}

fn doHandshake(
    alloc: std.mem.Allocator,
    bt: *bt_boundary.ByteTransport,
    network_magic: u64,
    peer_sharing: bool,
) !bool {
    const trace = compat.hasEnvVar(alloc, "TSUNAGI_TRACE");

    if (trace) {
        std.debug.print("HANDSHAKE: network_magic={d} peer_sharing={}\n", .{ network_magic, peer_sharing });
    }

    const version_data = try buildV14VersionData(alloc, network_magic, peer_sharing);

    var entries = try alloc.alloc(cbor.MapEntry, 1);
    entries[0] = .{ .key = 14, .value = version_data };
    var propose = handshake_codec.HandshakeMsg{
        .propose = .{ .versions = .{ .map_u64 = entries } },
    };
    defer handshake_codec.free(alloc, &propose);

    var payload_list = std.array_list.Managed(u8).init(alloc);
    defer payload_list.deinit();
    try handshake_codec.encodeMsg(propose, compat.listWriter(&payload_list));
    const payload = try payload_list.toOwnedSlice();
    defer alloc.free(payload);

    if (trace) {
        const dump_len = @min(payload.len, 64);
        std.debug.print("HANDSHAKE: sending proto=0 dir=initiator len={d} first_bytes={x}\n", .{
            payload.len,
            payload[0..dump_len],
        });
    }

    mux_bearer.sendSegment(bt, .initiator, 0, payload) catch |err| {
        if (trace) {
            std.debug.print("HANDSHAKE: send error: {s}\n", .{@errorName(err)});
        }
        return err;
    };

    if (trace) {
        std.debug.print("HANDSHAKE: send ok, waiting for response (timeout=30s)\n", .{});
    }

    // Use 30s timeout for handshake (longer than main loop's 10s)
    tcp_bt.setReadTimeout(bt, 30_000) catch {};

    const seg = mux_bearer.recvSegmentWithTimeout(alloc, bt) catch |err| {
        if (trace) {
            std.debug.print("HANDSHAKE: recv error: {s}\n", .{@errorName(err)});
        }
        if (err == error.TimedOut) {
            if (trace) {
                std.debug.print("HANDSHAKE: timed out after 30s\n", .{});
            }
            return false;
        }
        return err;
    };

    if (seg == null) {
        if (trace) {
            std.debug.print("HANDSHAKE: recv returned null (peer closed)\n", .{});
        }
        return false;
    }
    defer alloc.free(seg.?.payload);

    if (trace) {
        const dump_len = @min(seg.?.payload.len, 64);
        std.debug.print("HANDSHAKE: recv ok hdr{{dir={s} proto={d} len={d}}} first_bytes={x}\n", .{
            @tagName(seg.?.hdr.dir),
            seg.?.hdr.proto,
            seg.?.hdr.len,
            seg.?.payload[0..dump_len],
        });
    }

    var fbs = compat.fixedBufferStream(seg.?.payload);
    var msg = handshake_codec.decodeMsg(alloc, fbs.reader()) catch |err| {
        if (trace) {
            std.debug.print("HANDSHAKE: decode error: {s} at position={d}\n", .{ @errorName(err), fbs.pos });
        }
        return false;
    };
    defer handshake_codec.free(alloc, &msg);

    const accepted = msg == .accept;
    if (trace) {
        std.debug.print("HANDSHAKE: decoded msg={s} accepted={}\n", .{ @tagName(msg), accepted });
    }

    return accepted;
}

const TipSlotBlock = struct {
    slot: u64,
    block_no: u64,
};

fn getTipHash(term: cbor.Term) ?[]const u8 {
    if (term != .array) return null;
    const items = term.array;
    const inner = blk: {
        if (items.len == 1 and items[0] == .array) break :blk items[0].array;
        break :blk items;
    };
    if (inner.len != 2) return null;
    if (inner[0] != .array or inner[1] != .u64) return null;
    const point = inner[0].array;
    if (point.len != 2) return null;
    if (point[0] != .u64 or point[1] != .bytes) return null;
    if (point[1].bytes.len != 32) return null;
    return point[1].bytes;
}

fn getTipSlotBlock(term: cbor.Term) ?TipSlotBlock {
    if (term != .array) return null;
    const items = term.array;
    const inner = blk: {
        if (items.len == 1 and items[0] == .array) break :blk items[0].array;
        break :blk items;
    };
    if (inner.len == 2 and inner[0] == .array and inner[1] == .u64) {
        const point = inner[0].array;
        if (point.len == 2 and point[0] == .u64 and point[1] == .bytes) {
            return .{ .slot = point[0].u64, .block_no = inner[1].u64 };
        }
    }
    if (inner.len >= 3 and inner[0] == .u64 and inner[2] == .u64) {
        return .{ .slot = inner[0].u64, .block_no = inner[2].u64 };
    }
    return null;
}

// PRIMARY FOLLOWER OBSERVABILITY (fix/primary-follower-observability)
// Print a 1-line summary of a CBOR term's shape — used when getTipSlotBlock
// returns null so the operator can see what cardano-node actually sent.
// OBSERVABILITY-ONLY: no decision path consumes this.
fn logTipShapeSummary(label: []const u8, term: cbor.Term) void {
    switch (term) {
        .array => |items| {
            std.debug.print(
                "PRIMARY_TIP_PARSE_NULL: label={s} shape=array len={d}",
                .{ label, items.len },
            );
            // Describe up to first 4 elements by their tag + size info
            const cap = if (items.len < 4) items.len else 4;
            var i: usize = 0;
            while (i < cap) : (i += 1) {
                switch (items[i]) {
                    .u64 => |v| std.debug.print(" [{d}]=u64:{d}", .{ i, v }),
                    .i64 => |v| std.debug.print(" [{d}]=i64:{d}", .{ i, v }),
                    .bytes => |b| std.debug.print(" [{d}]=bytes:{d}", .{ i, b.len }),
                    .text => |t| std.debug.print(" [{d}]=text:{d}", .{ i, t.len }),
                    .array => |a| std.debug.print(" [{d}]=array:{d}", .{ i, a.len }),
                    .map_u64 => |m| std.debug.print(" [{d}]=map:{d}", .{ i, m.len }),
                    .tag => |t| std.debug.print(" [{d}]=tag:{d}", .{ i, t.tag }),
                    .bool => std.debug.print(" [{d}]=bool", .{i}),
                    .null => std.debug.print(" [{d}]=null", .{i}),
                }
            }
            std.debug.print("\n", .{});
        },
        .u64 => |v| std.debug.print("PRIMARY_TIP_PARSE_NULL: label={s} shape=u64:{d}\n", .{ label, v }),
        .bytes => |b| std.debug.print("PRIMARY_TIP_PARSE_NULL: label={s} shape=bytes:{d}\n", .{ label, b.len }),
        .tag => |t| std.debug.print("PRIMARY_TIP_PARSE_NULL: label={s} shape=tag:{d}\n", .{ label, t.tag }),
        else => std.debug.print("PRIMARY_TIP_PARSE_NULL: label={s} shape=other\n", .{label}),
    }
}

pub fn headerHashBlake2b256(header_cbor_bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(header_cbor_bytes, &digest, .{});
    return digest;
}

// IntersectNotFound recovery — bounded canonical continuity negotiation.
// Operator-ratified design (2026-05-20): when relay returns IntersectNotFound,
// follower must NOT remain permanently wedged at tip_block_last=0. Instead,
// present a bounded multi-point FindIntersect built from authenticated local
// ancestry (cursor + header_store prev_hash walk at exponential depths) and
// let the relay select the deepest matching point.
//
// Strict doctrine:
//   - READ-ONLY consultation of cursor / header_store. NEVER mutate cursor.json.
//   - NO fork arbitration. NO shadow consensus. NO probabilistic recovery.
//   - NO invented hashes. Only points TSUNAGI has already received-and-stored
//     via authenticated chainsync (header_store records or current cursor).
//   - Relay decides which point is canonical; TSUNAGI only presents candidates.
//
// Depth ladder is deterministic and bounded:
//   {1, 4, 16, 64, 256, 1024, 4096} hops back from header_head.
const MAX_INTERSECT_POINTS: usize = 8;
const INTERSECT_DEPTH_LADDER = [_]u32{ 1, 4, 16, 64, 256, 1024, 4096 };

const RecoveryPoint = struct {
    slot: u64,
    hash: [32]u8,
    source: enum { cursor, header_store },
    depth: u32, // 0 for cursor; 1..4096 for header_store walks
};

// Collect up to MAX_INTERSECT_POINTS authenticated ancestry candidates.
// Order: [0] cursor (if valid), [1..] header_store walk at INTERSECT_DEPTH_LADDER.
// READ-ONLY — does not mutate any state.
fn collectIntersectPoints(ctx: *Context, out: *[MAX_INTERSECT_POINTS]RecoveryPoint) usize {
    var n: usize = 0;

    // (1) Current cursor point — newest, highest priority.
    if (ctx.cursor.slot > 0 and hexHasValue(ctx.cursor.tip_hash_hex[0..])) {
        var hash_bytes: [32]u8 = undefined;
        var cursor_ok = true;
        _ = std.fmt.hexToBytes(&hash_bytes, ctx.cursor.tip_hash_hex[0..]) catch {
            cursor_ok = false;
        };
        if (cursor_ok) {
            out[n] = .{
                .slot = ctx.cursor.slot,
                .hash = hash_bytes,
                .source = .cursor,
                .depth = 0,
            };
            n += 1;
        }
    }

    // (2) Walk header_store backward at the ratified exponential depth ladder.
    if (ctx.header_store) |*hs| {
        const head_opt = ctx.header_head;
        if (head_opt) |head| {
            if (hs.beginRead()) |rtxn_v| {
                var rtxn = rtxn_v;
                defer hs.abort(&rtxn);

                var current_hash: [32]u8 = head;
                var current_depth: u32 = 0;
                var ladder_idx: usize = 0;

                while (n < MAX_INTERSECT_POINTS and ladder_idx < INTERSECT_DEPTH_LADDER.len) {
                    const rec_opt = hs.getHeader(&rtxn, current_hash);
                    if (rec_opt == null) break;
                    const rec = rec_opt.?;

                    if (current_depth == INTERSECT_DEPTH_LADDER[ladder_idx]) {
                        out[n] = .{
                            .slot = rec.slot,
                            .hash = current_hash,
                            .source = .header_store,
                            .depth = current_depth,
                        };
                        n += 1;
                        ladder_idx += 1;
                    }

                    // End-of-chain detection (all-zero prev_hash → genesis).
                    var all_zero = true;
                    for (rec.prev_hash) |b| {
                        if (b != 0) {
                            all_zero = false;
                            break;
                        }
                    }
                    if (all_zero) break;

                    current_hash = rec.prev_hash;
                    current_depth += 1;
                }
            }
        }
    }

    return n;
}

// Source-tag → operator-visible label.
fn recoverySourceLabel(s: RecoveryPoint) []const u8 {
    return switch (s.source) {
        .cursor => "cursor",
        .header_store => "header_store",
    };
}

pub fn extractHeaderCborInfo(alloc: std.mem.Allocator, block: cbor.Term) ?HeaderCborInfo {
    if (block != .array) return null;
    const items = block.array;
    if (items.len < 2) return null;

    const block_bytes = blk: {
        if (items[1] == .bytes) break :blk items[1].bytes;
        if (items[1] == .tag and items[1].tag.tag == 24 and items[1].tag.value.* == .bytes) {
            break :blk items[1].tag.value.*.bytes;
        }
        return null;
    };

    const inner_bytes = header_raw.getTag24InnerBytes(block_bytes) orelse block_bytes;
    var fbs = compat.fixedBufferStream(inner_bytes);
    const top = cbor.decode(alloc, fbs.reader()) catch return null;
    defer cbor.free(top, alloc);

    if (top != .array) return null;
    const top_items = top.array;
    if (top_items.len == 0 or top_items[0] != .array) return null;
    // Shelley=15 items, Babbage/Conway=10 items; require at least 3 for prev_hash at index 2
    if (top_items[0].array.len < 3) return null;

    var list = std.array_list.Managed(u8).init(alloc);
    errdefer list.deinit();
    cbor.encode(top_items[0], compat.listWriter(&list)) catch {
        list.deinit();
        return null;
    };
    const cbor_bytes = list.toOwnedSlice() catch {
        list.deinit();
        return null;
    };

    // Encode full header [header_body, kes_sig] for fragment writing
    var full_hdr: ?[]u8 = null;
    {
        var full_list = std.array_list.Managed(u8).init(alloc);
        cbor.encode(top, compat.listWriter(&full_list)) catch {
            full_list.deinit();
        };
        if (full_list.items.len > 0) {
            full_hdr = full_list.toOwnedSlice() catch null;
        }
    }

    var prev_hash: ?[32]u8 = null;
    const header_items = top_items[0].array;
    // prev_hash is at index 2 in both Shelley (15-item) and Babbage/Conway (10-item) header bodies
    if (header_items.len >= 3 and header_items[2] == .bytes and header_items[2].bytes.len == 32) {
        var bytes32: [32]u8 = undefined;
        std.mem.copyForwards(u8, bytes32[0..], header_items[2].bytes);
        prev_hash = bytes32;
    }

    return HeaderCborInfo{
        .cbor_bytes = cbor_bytes,
        .full_header_cbor = full_hdr,
        .prev_hash = prev_hash,
    };
}

const HeaderHashError = error{
    InvalidBlock,
    InvalidHeader,
};

fn computeHeaderHash32(alloc: std.mem.Allocator, header_cbor_bytes: []const u8) ?[32]u8 {
    var fbs = compat.fixedBufferStream(header_cbor_bytes);
    const top = cbor.decode(alloc, fbs.reader()) catch return null;
    defer cbor.free(top, alloc);

    if (top != .array) return null;
    const top_items = top.array;
    if (top_items.len == 0) return null;
    if (top_items[0] != .array) return null;

    // Cardano header body is usually 15 items, but NOT guaranteed
    if (top_items[0].array.len < 10) {
        // too small to be a valid header body
        return null;
    }

    var digest: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(header_cbor_bytes, &digest, .{});
    return digest;
}

fn extractPrevHashFromRaw(alloc: std.mem.Allocator, header_cbor_bytes: []const u8) ?[32]u8 {
    var fbs = compat.fixedBufferStream(header_cbor_bytes);
    const top = cbor.decode(alloc, fbs.reader()) catch |e| {
        std.debug.print("PREV_HASH_EXTRACT_FAIL: cbor_decode_err err={s} bytes_len={d}\n", .{ @errorName(e), header_cbor_bytes.len });
        return null;
    };
    defer cbor.free(top, alloc);

    if (top != .array) {
        std.debug.print("PREV_HASH_EXTRACT_FAIL: top_not_array kind={s} bytes_len={d}\n", .{ termKindName(top), header_cbor_bytes.len });
        return null;
    }
    const top_items = top.array;
    if (top_items.len == 0) {
        std.debug.print("PREV_HASH_EXTRACT_FAIL: top_empty bytes_len={d}\n", .{header_cbor_bytes.len});
        return null;
    }
    if (top_items[0] != .array) {
        std.debug.print("PREV_HASH_EXTRACT_FAIL: top0_not_array kind={s} top_len={d} bytes_len={d}\n", .{ termKindName(top_items[0]), top_items.len, header_cbor_bytes.len });
        return null;
    }
    const header_body = top_items[0].array;
    if (header_body.len < 3) {
        std.debug.print("PREV_HASH_EXTRACT_FAIL: body_too_short len={d} bytes_len={d}\n", .{ header_body.len, header_cbor_bytes.len });
        return null;
    }

    // prev_hash is at index 2 in both Shelley (15-item) and Babbage/Conway (10-item) header bodies
    const result = extract32ByteHash(header_body[2]);
    if (result == null) {
        // Surface the actual CBOR shape at index 2 so we can fix the
        // extractor (or extract32ByteHash) precisely. Likely candidates:
        //   .null            — Genesis block (prev is nil), correct behavior to drop
        //   .bytes(N) N != 32 — Truncated/corrupt header
        //   .tag(T) ...      — Unexpected tag wrap
        //   other            — Encoding we haven't seen before
        var details_buf: [128]u8 = undefined;
        const details = termDetails(header_body[2], &details_buf);
        std.debug.print("PREV_HASH_EXTRACT_FAIL: index2_unrecognized kind={s} details={s} body_len={d} bytes_len={d}\n", .{
            termKindName(header_body[2]), details, header_body.len, header_cbor_bytes.len,
        });
    }
    return result;
}

fn termDetails(term: cbor.Term, buf: []u8) []const u8 {
    return switch (term) {
        .u64 => |v| std.fmt.bufPrint(buf, "u64({d})", .{v}) catch "u64",
        .i64 => |v| std.fmt.bufPrint(buf, "i64({d})", .{v}) catch "i64",
        .bool => |v| std.fmt.bufPrint(buf, "bool({})", .{v}) catch "bool",
        .null => "null",
        .bytes => |b| std.fmt.bufPrint(buf, "bytes(len={d})", .{b.len}) catch "bytes",
        .text => |t| std.fmt.bufPrint(buf, "text(len={d})", .{t.len}) catch "text",
        .array => |a| std.fmt.bufPrint(buf, "array(len={d})", .{a.len}) catch "array",
        .map_u64 => |m| std.fmt.bufPrint(buf, "map(len={d})", .{m.len}) catch "map",
        .tag => |t| std.fmt.bufPrint(buf, "tag({d}->{s})", .{ t.tag, @tagName(t.value.*) }) catch "tag",
    };
}

/// Extract a 32-byte hash from a CBOR Term that is either raw .bytes or tag-wrapped .bytes.
fn extract32ByteHash(term: cbor.Term) ?[32]u8 {
    if (term == .bytes and term.bytes.len == 32) {
        var out: [32]u8 = undefined;
        @memcpy(&out, term.bytes[0..32]);
        return out;
    }
    if (term == .tag) {
        const inner = term.tag.value.*;
        if (inner == .bytes and inner.bytes.len == 32) {
            var out: [32]u8 = undefined;
            @memcpy(&out, inner.bytes[0..32]);
            return out;
        }
    }
    return null;
}

fn readHead(bytes: []const u8, idx: *usize) ?struct { major: u8, ai: u8 } {
    if (idx.* >= bytes.len) return null;
    const b = bytes[idx.*];
    idx.* += 1;
    return .{ .major = b >> 5, .ai = b & 0x1f };
}

fn readLen(bytes: []const u8, idx: *usize, ai: u8) ?usize {
    switch (ai) {
        0...23 => return ai,
        24 => {
            if (idx.* + 1 > bytes.len) return null;
            const v = bytes[idx.*];
            idx.* += 1;
            return v;
        },
        25 => {
            if (idx.* + 2 > bytes.len) return null;
            const v = (@as(usize, bytes[idx.*]) << 8) | bytes[idx.* + 1];
            idx.* += 2;
            return v;
        },
        26 => {
            if (idx.* + 4 > bytes.len) return null;
            const v = (@as(usize, bytes[idx.*]) << 24) |
                (@as(usize, bytes[idx.* + 1]) << 16) |
                (@as(usize, bytes[idx.* + 2]) << 8) |
                bytes[idx.* + 3];
            idx.* += 4;
            return v;
        },
        27 => {
            if (idx.* + 8 > bytes.len) return null;
            var v: usize = 0;
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                v = (v << 8) | bytes[idx.* + i];
            }
            idx.* += 8;
            return v;
        },
        31 => return null,
        else => return null,
    }
}

fn peekMajor(bytes: []const u8, idx: usize) ?u8 {
    if (idx >= bytes.len) return null;
    return bytes[idx] >> 5;
}

fn skipItem(bytes: []const u8, idx: *usize) bool {
    const head = readHead(bytes, idx) orelse return false;
    const major = head.major;
    const ai = head.ai;

    switch (major) {
        0, 1 => {
            _ = readLen(bytes, idx, ai) orelse return false;
            return true;
        },
        2, 3 => {
            const len = readLen(bytes, idx, ai) orelse return false;
            if (idx.* + len > bytes.len) return false;
            idx.* += len;
            return true;
        },
        4 => {
            const len = readLen(bytes, idx, ai) orelse return false;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                if (!skipItem(bytes, idx)) return false;
            }
            return true;
        },
        5 => {
            const len = readLen(bytes, idx, ai) orelse return false;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                if (!skipItem(bytes, idx)) return false;
                if (!skipItem(bytes, idx)) return false;
            }
            return true;
        },
        6 => {
            _ = readLen(bytes, idx, ai) orelse return false;
            return skipItem(bytes, idx);
        },
        7 => return true,
        else => return false,
    }
}

fn scanTxBodiesCount(body_bytes: []const u8) u64 {
    var idx: usize = 0;
    while (idx < body_bytes.len) {
        const start = idx;
        const head = readHead(body_bytes, &idx) orelse return 0;
        if (head.major == 4) {
            const len = readLen(body_bytes, &idx, head.ai) orelse return 0;
            if (idx >= body_bytes.len) return 0;
            const first_major = peekMajor(body_bytes, idx) orelse return 0;
            if (first_major == 5) {
                return @as(u64, @intCast(len));
            }
            if (first_major == 6) {
                var tag_idx = idx;
                const tag_head = readHead(body_bytes, &tag_idx) orelse return 0;
                if (tag_head.major == 6) {
                    _ = readLen(body_bytes, &tag_idx, tag_head.ai) orelse return 0;
                    const next_major = peekMajor(body_bytes, tag_idx) orelse return 0;
                    if (next_major == 5) {
                        return @as(u64, @intCast(len));
                    }
                }
            }
        }
        idx = start;
        if (!skipItem(body_bytes, &idx)) return 0;
    }
    return 0;
}

fn extractTxCount(block_body_bytes: []const u8, alloc: std.mem.Allocator, debug: bool) u64 {
    const DEBUG_TX_DISCOVERY = true;

    var outer_fbs = compat.fixedBufferStream(block_body_bytes);
    const outer = cbor.decode(alloc, outer_fbs.reader()) catch {
        if (debug and DEBUG_TX_DISCOVERY) {
            std.debug.print("TX_DISCOVERY: outer_decode=fail\n", .{});
        }
        return 0;
    };
    defer cbor.free(outer, alloc);

    if (outer != .array) {
        if (debug and DEBUG_TX_DISCOVERY) {
            std.debug.print("TX_DISCOVERY: outer_not_array\n", .{});
        }
        return 0;
    }
    const outer_items = outer.array;
    if (outer_items.len < 2) {
        if (debug and DEBUG_TX_DISCOVERY) {
            std.debug.print("TX_DISCOVERY: outer_len_lt_2\n", .{});
        }
        return 0;
    }
    if (outer_items[1] != .bytes) {
        if (debug and DEBUG_TX_DISCOVERY) {
            std.debug.print("TX_DISCOVERY: outer_body_not_bytes kind=", .{});
            switch (outer_items[1]) {
                .u64 => std.debug.print("u64\n", .{}),
                .i64 => std.debug.print("i64\n", .{}),
                .bool => std.debug.print("bool\n", .{}),
                .null => std.debug.print("null\n", .{}),
                .bytes => std.debug.print("bytes\n", .{}),
                .text => std.debug.print("text\n", .{}),
                .array => |arr| std.debug.print("array({d})\n", .{arr.len}),
                .map_u64 => |m| std.debug.print("map({d})\n", .{m.len}),
                .tag => |t| std.debug.print("tag({d})\n", .{t.tag}),
            }
        }
        if (debug) {
            std.debug.print("BODY_BYTES missing\n", .{});
        }
        return 0;
    }

    const body_bytes = outer_items[1].bytes;
    if (debug) {
        std.debug.print("BODY_BYTES len={d}\n", .{body_bytes.len});
    }
    const count = scanTxBodiesCount(body_bytes);
    if (debug and DEBUG_TX_DISCOVERY) {
        std.debug.print(
            "TX_DISCOVERY: scan body_bytes=len{d} found={s} count={d}\n",
            .{ body_bytes.len, if (count > 0) "yes" else "no", count },
        );
    }
    return count;
}

fn cloneTerm(alloc: std.mem.Allocator, term: cbor.Term) !cbor.Term {
    return switch (term) {
        .u64 => |v| cbor.Term{ .u64 = v },
        .i64 => |v| cbor.Term{ .i64 = v },
        .bool => |v| cbor.Term{ .bool = v },
        .null => cbor.Term{ .null = {} },
        .bytes => |b| cbor.Term{ .bytes = try alloc.dupe(u8, b) },
        .text => |t| cbor.Term{ .text = try alloc.dupe(u8, t) },
        .array => |items| blk: {
            var out = try alloc.alloc(cbor.Term, items.len);
            // `out` is uninitialized; only free the prefix actually filled so the
            // errdefer never frees a garbage (uninitialized) union tag on OOM.
            var filled: usize = 0;
            errdefer {
                for (out[0..filled]) |item| cbor.free(item, alloc);
                alloc.free(out);
            }
            for (items, 0..) |item, i| {
                out[i] = try cloneTerm(alloc, item);
                filled = i + 1;
            }
            break :blk cbor.Term{ .array = out };
        },
        .map_u64 => |entries| blk: {
            var out = try alloc.alloc(cbor.MapEntry, entries.len);
            var filled: usize = 0;
            errdefer {
                for (out[0..filled]) |e| cbor.free(e.value, alloc);
                alloc.free(out);
            }
            for (entries, 0..) |e, i| {
                out[i] = .{ .key = e.key, .value = try cloneTerm(alloc, e.value) };
                filled = i + 1;
            }
            break :blk cbor.Term{ .map_u64 = out };
        },
        .tag => |t| blk: {
            const value = try alloc.create(cbor.Term);
            errdefer alloc.destroy(value);
            value.* = try cloneTerm(alloc, t.value.*);
            break :blk cbor.Term{ .tag = .{ .tag = t.tag, .value = value } };
        },
    };
}

fn storeTip(alloc: std.mem.Allocator, last_tip: *?cbor.Term, tip: cbor.Term) !void {
    if (last_tip.*) |existing| {
        cbor.free(existing, alloc);
    }
    last_tip.* = try cloneTerm(alloc, tip);
}

fn tipHash32(term: cbor.Term) ?[32]u8 {
    const bytes = getTipHash(term) orelse return null;
    var out: [32]u8 = undefined;
    std.mem.copyForwards(u8, out[0..], bytes);
    return out;
}

fn headerHash32(alloc: std.mem.Allocator, block: cbor.Term) ?[32]u8 {
    const header_info = extractHeaderCborInfo(alloc, block) orelse return null;
    defer alloc.free(header_info.cbor_bytes);
    return headerHashBlake2b256(header_info.cbor_bytes);
}

/// Callback invoked when BlockFetch returns a full block with tx deltas
// File-scoped LMDB pointer for mempool UTxO existence check callback
var g_lmdb_for_mempool: ?*lmdb_utxo.LmdbUtxo = null;
// Protocol params periodic reload + change detection
var g_params_last_reload_unix: i64 = 0;
var g_params_last_fee_a: u64 = 0;
var g_params_last_fee_b: u64 = 0;
var g_params_last_min_utxo: u64 = 0;
var g_params_last_max_tx: u64 = 0;
var g_params_last_cost_per_byte: u64 = 0;
// File-scoped slot for mempool validity interval enforcement
var g_last_observed_slot: u64 = 0;

fn currentSlotProvider() ?u64 {
    const s = g_last_observed_slot;
    return if (s > 0) s else null;
}

fn lmdbUtxoLookup(tx_hash: [32]u8, index: u32) ?u64 {
    const store = g_lmdb_for_mempool orelse return 0; // no LMDB → allow with 0
    var txn = store.beginRead() orelse return 0;
    defer store.abort(&txn);
    const raw = store.getTxn(&txn, tx_hash, index) orelse return null;
    const dec = store.decodeTxOutValue(std.heap.page_allocator, raw) orelse return null;
    defer std.heap.page_allocator.free(dec.address);
    return dec.lovelace;
}

fn onBlockFetched(
    alloc: std.mem.Allocator,
    ctx_any: *anyopaque,
    slot: u64,
    block_no: u64,
    deltas: tx_decode.TxDeltas,
    bf_summaries: tx_decoder.BlockTxResult,
) void {
    const ctx = @as(*Context, @ptrCast(@alignCast(ctx_any)));
    if (slot > g_last_observed_slot) g_last_observed_slot = slot;

    std.debug.print("BLOCKFETCH: applying deltas slot={d} block={d} consumed={d} produced={d} bf_tx_count={d}\n", .{
        slot,
        block_no,
        deltas.consumed.len,
        deltas.produced.len,
        bf_summaries.count,
    });

    // Phase 8.1: update node_state for /status endpoint
    {
        const utxo_sz: u64 = if (ctx.utxo_count_est > 0) @intCast(ctx.utxo_count_est) else 0;
        node_state.updateTip(slot, block_no, [_]u8{0} ** 32, utxo_sz);
    }

    // ── Resolve consumed inputs for stake distribution BEFORE UTxO apply ──
    const MAX_CONSUMED_STAKES = 64;
    var consumed_stakes: [MAX_CONSUMED_STAKES]stake_distribution.ConsumedStake = undefined;
    var consumed_stake_count: u32 = 0;
    if (ctx.utxo) |utxo_set| {
        for (deltas.consumed) |input| {
            if (consumed_stake_count >= MAX_CONSUMED_STAKES) break;
            if (utxo_set.map.get(input)) |txout| {
                if (txout.address.len >= 57) {
                    const addr_type = txout.address[0] >> 4;
                    if (addr_type <= 3) {
                        var cs = &consumed_stakes[consumed_stake_count];
                        @memcpy(&cs.stake_credential, txout.address[29..57]);
                        cs.lovelace = txout.lovelace;
                        consumed_stake_count += 1;
                    }
                }
            }
        }
    }

    if (ctx.primary_pipeline) |pp| {
        primaryApplyDeltas(ctx, pp, deltas, slot, block_no);
    } else {
        applyPreviewUtxo(ctx, alloc, deltas, slot, block_no);
    }
    shadowApplyDeltas(ctx, deltas, slot, block_no);

    // Periodic protocol params file reload (every 60s) with change detection
    {
        const now_pp = compat.timestamp();
        if (now_pp - g_params_last_reload_unix >= 60) {
            g_params_last_reload_unix = now_pp;
            const home_env = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
            const mempool_mod2 = @import("../ledger/mempool.zig");
            const genesis_mod = @import("../../producer/genesis.zig");
            if (home_env) |home| {
                defer alloc.free(home);
                if (genesis_mod.loadProtocolParamsFile(alloc, home)) |pp| {
                    // Increment reload counter
                    if (ctx.metrics) |ma| {
                        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                        _ = m.protocol_params_reload_total.fetchAdd(1, .monotonic);
                    }

                    // Change detection: compare each field against last-known values
                    var changed = false;
                    const fields = .{
                        .{ "min_fee_a", pp.min_fee_a, &g_params_last_fee_a },
                        .{ "min_fee_b", pp.min_fee_b, &g_params_last_fee_b },
                        .{ "min_utxo_value", pp.min_utxo_value, &g_params_last_min_utxo },
                        .{ "max_tx_size", pp.max_tx_size, &g_params_last_max_tx },
                        .{ "utxo_cost_per_byte", pp.utxo_cost_per_byte, &g_params_last_cost_per_byte },
                    };
                    inline for (fields) |f| {
                        const old_val = f[2].*;
                        const new_val = f[1];
                        if (old_val != 0 and old_val != new_val) {
                            changed = true;
                            std.debug.print("PROTOCOL_PARAMS_CHANGED: field={s} old={d} new={d} source=file reload_unix={d}\n", .{
                                f[0], old_val, new_val, now_pp,
                            });
                            if (ctx.metrics) |ma| {
                                const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                                _ = m.protocol_params_change_total.fetchAdd(1, .monotonic);
                            }
                        }
                        f[2].* = new_val;
                    }

                    // Truth log on every reload
                    std.debug.print("PROTOCOL_PARAMS_TRUTH: fee_a={d} fee_b={d} min_utxo={d} max_tx={d} utxo_cost_per_byte={d} source=file reload_unix={d} changed={s}\n", .{
                        pp.min_fee_a, pp.min_fee_b, pp.min_utxo_value, pp.max_tx_size,
                        pp.utxo_cost_per_byte, now_pp, if (changed) "true" else "false",
                    });

                    mempool_mod2.g_protocol_params = pp;
                } else {
                    // File missing or unparseable — fallback log
                    std.debug.print("PROTOCOL_PARAMS_FALLBACK: reason=file_missing_or_parse_error source=genesis reload_unix={d}\n", .{now_pp});
                    if (ctx.metrics) |ma| {
                        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                        _ = m.protocol_params_fallback_total.fetchAdd(1, .monotonic);
                    }

                    // Truth log with current genesis values
                    if (mempool_mod2.g_protocol_params) |cur| {
                        std.debug.print("PROTOCOL_PARAMS_TRUTH: fee_a={d} fee_b={d} min_utxo={d} max_tx={d} utxo_cost_per_byte={d} source=genesis reload_unix={d} changed=false\n", .{
                            cur.min_fee_a, cur.min_fee_b, cur.min_utxo_value, cur.max_tx_size,
                            cur.utxo_cost_per_byte, now_pp,
                        });
                    }
                }
            }
        }
    }

    // Evict confirmed txs from mempool
    if (txsubmission.g_mempool) |mp| {
        if (deltas.consumed.len > 0) {
            const evicted = mp.evictConfirmed(deltas.consumed);
            if (evicted > 0) {
                std.debug.print("MEMPOOL_EVICT_CONFIRMED: evicted={d} consumed={d} slot={d}\n", .{
                    evicted, deltas.consumed.len, slot,
                });
            }
        }
        // TTL sweep: drop entries older than TSUNAGI_MEMPOOL_TTL_S (default 3600s)
        _ = mp.sweepExpired(compat.timestamp());
        // Phase 8.1: reflect mempool state in /status
        node_state.updateMempool(@intCast(mp.count()), @intCast(mp.totalBytes()));
    }

    tx_decode.freeTxDeltas(alloc, deltas);

    // Update fee/withdrawal counters from BlockFetch-sourced summaries
    tx_decode.updateBlockSummaryCounters(bf_summaries);

    // Write supplementary journal entry with BlockFetch-sourced tx summaries
    if (bf_summaries.count > 0) {
        if (ctx.tx_decode_journal_path) |jpath| {
            // Compute block hash hex for journal entry
            var hash_hex: [64]u8 = undefined;
            const hex_chars = "0123456789abcdef";
            if (ctx.header_head) |hh| {
                for (hh, 0..) |b, i| {
                    hash_hex[i * 2] = hex_chars[b >> 4];
                    hash_hex[i * 2 + 1] = hex_chars[b & 0xf];
                }
            } else {
                @memset(&hash_hex, '0');
            }
            journal.appendTxDecode(jpath, slot, block_no, &hash_hex, bf_summaries) catch {};
        }
    }

    // ── Stake state: accumulate certificate counts ──
    {
        const now_ss = compat.timestamp();

        // Load state on first block if not yet loaded
        if (!g_stake_state_loaded) {
            const pa_ss = std.heap.page_allocator;
            if (compat.getEnvVarOwned(pa_ss, "TSUNAGI_HOME")) |home| {
                defer pa_ss.free(home);
                var ss_path_buf: [512]u8 = undefined;
                const ss_path = std.fmt.bufPrint(&ss_path_buf, "{s}/stake_state.json", .{home}) catch "";
                if (ss_path.len > 0) _ = stake_state.loadState(&g_stake_state, ss_path);
            } else |_| {}
            g_stake_state_loaded = true;
        }

        // Process block certificates
        if (bf_summaries.block_cert_summary.total > 0) {
            stake_state.processBlock(&g_stake_state, slot, now_ss, bf_summaries.block_cert_summary);

            // Update metrics atomics
            if (ctx.metrics) |ma| {
                const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                m.stake_net_registered.store(g_stake_state.netRegistered(), .release);
                m.stake_net_pools.store(g_stake_state.netPools(), .release);
                m.stake_delegations_total.store(g_stake_state.active_delegations, .release);
                m.stake_total_certs.store(g_stake_state.total_certs, .release);
            }
        }

        // Periodic save + truth log (every 60s)
        if (now_ss - g_stake_state_last_save_unix >= 60) {
            g_stake_state_last_save_unix = now_ss;

            std.debug.print("STAKE_STATE_TRUTH: net_registered={d} net_pools={d} delegations={d} total_certs={d} blocks_with_certs={d}\n", .{
                g_stake_state.netRegistered(),
                g_stake_state.netPools(),
                g_stake_state.active_delegations,
                g_stake_state.total_certs,
                g_stake_state.blocks_with_certs,
            });

            const pa_sv = std.heap.page_allocator;
            if (compat.getEnvVarOwned(pa_sv, "TSUNAGI_HOME")) |home| {
                defer pa_sv.free(home);
                var sv_buf: [512]u8 = undefined;
                const sv = std.fmt.bufPrint(&sv_buf, "{s}/stake_state.json", .{home}) catch "";
                if (sv.len > 0) stake_state.saveState(&g_stake_state, sv);
            } else |_| {}
        }
    }

    // ── Stake distribution: track delegations and output stakes ──
    {
        const now_sd = compat.timestamp();

        // Initialize pool ID on first block
        if (!g_stake_dist_loaded) {
            // Load persisted state
            const pa_sd = std.heap.page_allocator;
            if (compat.getEnvVarOwned(pa_sd, "TSUNAGI_HOME")) |home| {
                defer pa_sd.free(home);
                var sd_path_buf: [512]u8 = undefined;
                const sd_path = std.fmt.bufPrint(&sd_path_buf, "{s}/stake_dist.json", .{home}) catch "";
                if (sd_path.len > 0) _ = g_stake_dist.loadState(sd_path);
            } else |_| {}
            // Set our pool ID from producer context
            if (ctx.producer_ctx.key_cfg.pool_id_hex) |pid| {
                g_stake_dist.setPoolId(pid);
            }
            g_stake_dist_loaded = true;
        }

        // Process certificates: registration (type 0), deregistration (type 1),
        // delegation (type 2). Reg count is a simple counter; dereg scrubs our
        // delegator array; delegation is full hash+pool_id match.
        const cert_sum = bf_summaries.block_cert_summary;
        var r: u16 = 0;
        while (r < cert_sum.stake_registration) : (r += 1) {
            g_stake_dist.processStakeRegistration();
        }
        // Deregistration: we only track the credential if it comes through a
        // delegation entry (which carries the 28-byte hash). Cert-type-1 alone
        // currently doesn't expose the hash through block_cert_summary, so
        // just tally the count for observability.
        if (cert_sum.stake_deregistration > 0) {
            g_stake_dist.stake_deregistrations += cert_sum.stake_deregistration;
            g_stake_dist.live_tracking_ready = true;
        }
        if (cert_sum.delegation_count > 0) {
            for (cert_sum.delegations[0..cert_sum.delegation_count]) |deleg| {
                if (deleg.valid) {
                    g_stake_dist.processDelegation(deleg.credential_hash, deleg.pool_id);
                }
            }
        }

        // Process consumed inputs (subtract spent UTxOs)
        for (consumed_stakes[0..consumed_stake_count]) |cs| {
            var addr: [57]u8 = undefined;
            addr[0] = 0x01;
            @memset(addr[1..29], 0);
            @memcpy(addr[29..57], &cs.stake_credential);
            g_stake_dist.processInput(&addr, cs.lovelace);
        }

        // Process produced outputs (add new UTxOs)
        for (bf_summaries.output_stakes[0..bf_summaries.output_stake_count]) |entry| {
            if (entry.valid) {
                var addr: [57]u8 = undefined;
                addr[0] = 0x01;
                @memset(addr[1..29], 0);
                @memcpy(addr[29..57], &entry.stake_credential);
                g_stake_dist.processOutput(&addr, entry.lovelace);
            }
        }

        // Recompute sigma and feed to producer
        g_stake_dist.recomputeSigma(slot);
        // Phase 4.2: promote env|bootstrap → ledger once live tracking has
        // accumulated enough observations (100 stake-touching events).
        stake_distribution.maybePromoteToLedger(&g_stake_dist, 100);
        // Task 8: drive mark/set/go snapshot promotion. Cheap, mutex-bounded;
        // safe even when TSUNAGI_SNAPSHOT_ENABLE is unset (the producer simply
        // ignores the snapshot in that case).
        if (ctx.producer_ctx.slots_per_epoch > 0) {
            const shelley_slot = if (slot >= ctx.producer_ctx.shelley_start_slot) slot - ctx.producer_ctx.shelley_start_slot else 0;
            const epoch = ctx.producer_ctx.shelley_start_epoch + (shelley_slot / ctx.producer_ctx.slots_per_epoch);
            const slot_in_epoch = shelley_slot % ctx.producer_ctx.slots_per_epoch;
            stake_snapshot.onSlotProgress(&g_stake_dist, &stake_snapshot.g_snapshots, epoch, slot_in_epoch);
        }
        if (g_stake_dist.sigma_x1e9 > 0) {
            ctx.producer_ctx.ledger_sigma_x1e9 = g_stake_dist.sigma_x1e9;
            ctx.producer_ctx.ledger_sigma_valid = true;
            // Mirror the source enum into producer_ctx for PRAOS_STATE log.
            ctx.producer_ctx.ledger_sigma_source_kind = @intFromEnum(g_stake_dist.source);
        }
        // Throttled live-update log: every 60s when live tracking is ready.
        if (g_stake_dist.live_tracking_ready and (now_sd - g_stake_dist_last_save_unix >= 60)) {
            std.debug.print("STAKE_LIVE_UPDATE: pool={d} total={d} sigma_x1e9={d} registrations={d} deregistrations={d} delegations={d}\n", .{
                g_stake_dist.our_pool_lovelace, g_stake_dist.total_staked_lovelace, g_stake_dist.sigma_x1e9,
                g_stake_dist.stake_registrations, g_stake_dist.stake_deregistrations, g_stake_dist.delegations_processed,
            });
        }

        // Periodic save (every 60s)
        if (now_sd - g_stake_dist_last_save_unix >= 60) {
            g_stake_dist_last_save_unix = now_sd;
            const pa_sd2 = std.heap.page_allocator;
            if (compat.getEnvVarOwned(pa_sd2, "TSUNAGI_HOME")) |home| {
                defer pa_sd2.free(home);
                var sd_buf: [512]u8 = undefined;
                const sd_path = std.fmt.bufPrint(&sd_buf, "{s}/stake_dist.json", .{home}) catch "";
                if (sd_path.len > 0) g_stake_dist.saveState(sd_path);
            } else |_| {}
        }
    }
}

fn storeLmdbWriteMs(ctx: *Context, elapsed_ns: i128) void {
    if (ctx.metrics) |metrics_any| {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
        const ns: u128 = if (elapsed_ns <= 0) 0 else @bitCast(elapsed_ns);
        m.perf_lmdb_write_ms.store(@truncate(ns / 1_000_000), .release);
        m.perf_lmdb_write_us.store(@truncate(ns / 1_000), .release);
    }
}

/// Fallback: in-memory apply + shadow-write to LMDB (used when applyDeltaLmdb fails in non-truth mode)
fn applyPreviewUtxoFallback(ctx: *Context, alloc: std.mem.Allocator, store: *lmdb_utxo.LmdbUtxo, deltas: tx_decode.TxDeltas) void {
    const utxo = ctx.utxo orelse return;
    const undo_stack = ctx.undo_stack orelse return;

    // In-memory apply (skip when LMDB is set to avoid unbounded memory growth)
    const skip_mem = lmdbSkipMemory();
    if (!skip_mem) {
        var undo = utxo.applyDelta(deltas.consumed, deltas.produced) catch |err| {
            std.debug.print("UTXO fallback applyDelta failed: {s}\n", .{@errorName(err)});
            var empty_undo = utxo_mod.Undo.init(alloc);
            undo_stack.append(empty_undo) catch {
                empty_undo.deinit();
            };
            return;
        };
        undo_stack.append(undo) catch |err| {
            std.debug.print("UTXO fallback undo append failed: {s}\n", .{@errorName(err)});
            undo.deinit();
            return;
        };
        if (undo_stack.items.len > MAX_UNDO_DEPTH) {
            var evicted = undo_stack.orderedRemove(0);
            evicted.deinitFreeAddresses();
        }
    }

    // Shadow-write to LMDB (so it accumulates new UTxOs)
    if (store.beginWrite()) |txn0| {
        const lmdb_t0 = compat.nanoTimestamp();
        var t = txn0;
        for (deltas.consumed) |con| {
            store.delTxn(&t, con.tx_hash, con.index);
        }
        for (deltas.produced) |p| {
            store.putTxn(alloc, &t, p.input.tx_hash, p.input.index, p.output);
        }
        if (!store.commit(&t)) {
            std.debug.print("LMDB: fallback commit failed\n", .{});
        }
        storeLmdbWriteMs(ctx, compat.nanoTimestamp() - lmdb_t0);
    }

    // Increment fallback counter
    if (ctx.metrics) |metrics_any| {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
        _ = m.lmdb_fallback_blocks.fetchAdd(1, .acq_rel);
    }

    ctx.utxo_count_est += @as(i64, @intCast(deltas.produced.len));
    ctx.utxo_count_est -= @as(i64, @intCast(deltas.consumed.len));
    if (ctx.utxo_count_est < 0) ctx.utxo_count_est = 0;
    std.debug.print("UTXO live applied (fallback): -{d} +{d}\n", .{ deltas.consumed.len, deltas.produced.len });
    std.debug.print("UTXO est={d} undo_depth={d}\n", .{ ctx.utxo_count_est, undo_stack.items.len });
    maybePrintLmdbRatio(ctx);
}

fn applyPreviewUtxo(ctx: *Context, alloc: std.mem.Allocator, deltas: tx_decode.TxDeltas, tip_slot: u64, tip_block: u64) void {
    const utxo = ctx.utxo orelse return;
    const undo_stack = ctx.undo_stack orelse return;
    if (deltas.consumed.len == 0 and deltas.produced.len == 0) return;

    // Ledger invariant validation
    if (!validateDeltasInvariant(ctx, alloc, deltas, tip_slot, tip_block)) {
        // Strict mode: skip apply, signal violation for reconnect
        ctx.ledger_violation_pending = true;
        return;
    }

    // Phase F5: LMDB-native mode — LMDB is mandatory, no fallback
    if (lmdbNativeEnabled()) {
        if (ctx.lmdb) |*store| {
            const lmdb_t0 = compat.nanoTimestamp();
            const txn0 = store.beginWrite() orelse {
                std.debug.print("LMDB NATIVE: beginWrite failed\n", .{});
                std.process.exit(1);
            };
            var txn = txn0;

            var undo = utxo.applyDeltaLmdb(store, alloc, txn, deltas.consumed, deltas.produced) catch |err| {
                std.debug.print("LMDB NATIVE apply failed: {s}\n", .{@errorName(err)});
                store.abort(&txn);
                std.process.exit(1);
            };

            const ok = store.commit(&txn);
            if (!ok) {
                std.debug.print("LMDB NATIVE: commit failed\n", .{});
                undo.deinit();
                std.process.exit(1);
            }
            storeLmdbWriteMs(ctx, compat.nanoTimestamp() - lmdb_t0);

            // push undo + cap (same logic as truth path)
            undo_stack.append(undo) catch {
                std.debug.print("LMDB NATIVE: undo append failed\n", .{});
                undo.deinit();
                std.process.exit(1);
            };
            if (undo_stack.items.len > MAX_UNDO_DEPTH) {
                var evicted = undo_stack.orderedRemove(0);
                evicted.deinitFreeAddresses();
            }

            // Increment truth counter for metrics
            if (ctx.metrics) |metrics_any| {
                const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
                _ = m.lmdb_truth_blocks.fetchAdd(1, .acq_rel);
            }

            ctx.utxo_count_est += @as(i64, @intCast(deltas.produced.len));
            ctx.utxo_count_est -= @as(i64, @intCast(deltas.consumed.len));
            if (ctx.utxo_count_est < 0) ctx.utxo_count_est = 0;
            std.debug.print("UTXO live applied (lmdb-native): -{d} +{d}\n", .{ deltas.consumed.len, deltas.produced.len });
            std.debug.print("UTXO est={d} undo_depth={d}\n", .{ ctx.utxo_count_est, undo_stack.items.len });
            maybePrintLmdbRatio(ctx);
            return;
        } else {
            std.debug.print("LMDB NATIVE: missing TSUNAGI_LMDB store\n", .{});
            std.process.exit(1);
        }
    }

    // Phase 4B: LMDB-truth path — LMDB is the authoritative state store
    if (ctx.lmdb) |*store| {
        // v5.0: preflight coverage check — skip write txn if inputs are missing
        if (deltas.consumed.len > 0) {
            if (store.beginRead()) |rtxn0| {
                var rtxn = rtxn0;
                defer store.abort(&rtxn);
                var pf_found: usize = 0;
                var pf_first_missing: ?[32]u8 = null;
                for (deltas.consumed) |input| {
                    if (store.getTxn(&rtxn, input.tx_hash, input.index) != null) {
                        pf_found += 1;
                    } else if (pf_first_missing == null) {
                        pf_first_missing = input.tx_hash;
                    }
                }
                const pf_missing = deltas.consumed.len - pf_found;
                if (pf_missing > 0) {
                    // v5.2: preflight coverage profile counter
                    if (ctx.metrics) |ma| {
                        const pm = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                        if (pf_found > 0) {
                            _ = pm.preflight_partial_coverage_blocks.fetchAdd(1, .acq_rel);
                        } else {
                            _ = pm.preflight_zero_coverage_blocks.fetchAdd(1, .acq_rel);
                        }
                    }
                    // Rate-limited diagnostic log (30s)
                    const now_pf = compat.timestamp();
                    if (now_pf - ctx.last_lmdb_preflight_log_unix >= 30) {
                        ctx.last_lmdb_preflight_log_unix = now_pf;
                        if (pf_first_missing) |fh| {
                            std.debug.print("LMDB PREFLIGHT: coverage={d}/{d} missing={d} first_missing={x}\n", .{
                                pf_found, deltas.consumed.len, pf_missing,
                                &fh,
                            });
                        }
                    }
                    // Skip beginWrite — go straight to fallback
                    applyPreviewUtxoFallback(ctx, alloc, store, deltas);
                    return;
                }
                // v5.2: full coverage — all consumed inputs found in LMDB
                if (ctx.metrics) |ma| {
                    const pm = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                    _ = pm.preflight_full_coverage_blocks.fetchAdd(1, .acq_rel);
                }
            }
        }

        if (store.beginWrite()) |txn0| {
            const lmdb_t0 = compat.nanoTimestamp();
            var txn = txn0;

            // Apply delta through LMDB (reads existing values for undo, writes mutations)
            var undo = utxo.applyDeltaLmdb(store, alloc, txn, deltas.consumed, deltas.produced) catch |err| {
                // v1.5.9: rate-limited log (30s) + metric counter
                if (ctx.metrics) |ma| {
                    const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                    _ = m.lmdb_truth_apply_fail_total.fetchAdd(1, .acq_rel);
                }
                const now_lmdb = compat.timestamp();
                if (now_lmdb - ctx.last_lmdb_truth_error_log_unix >= 30) {
                    ctx.last_lmdb_truth_error_log_unix = now_lmdb;
                    std.debug.print("LMDB TRUTH apply failed: {s}\n", .{@errorName(err)});
                }
                store.abort(&txn);
                if (lmdbTruthEnabled()) std.process.exit(1);
                applyPreviewUtxoFallback(ctx, alloc, store, deltas);
                return;
            };

            // Commit LMDB transaction
            if (!store.commit(&txn)) {
                std.debug.print("LMDB TRUTH commit failed\n", .{});
                undo.deinit();
                if (lmdbTruthEnabled()) std.process.exit(1);
                return;
            }
            storeLmdbWriteMs(ctx, compat.nanoTimestamp() - lmdb_t0);

            // Push undo + cap (same semantics as memory path)
            undo_stack.append(undo) catch {
                undo.deinit();
                if (lmdbTruthEnabled()) std.process.exit(1);
                return;
            };
            if (undo_stack.items.len > MAX_UNDO_DEPTH) {
                var evicted = undo_stack.orderedRemove(0);
                evicted.deinitFreeAddresses();
            }

            // VERIFY (non-fatal): sample first 2 consumed + first 2 produced
            if (store.beginRead()) |rtxn0| {
                var rt = rtxn0;
                defer store.abort(&rt);

                var vi: usize = 0;
                while (vi < deltas.consumed.len and vi < 2) : (vi += 1) {
                    const con = deltas.consumed[vi];
                    if (store.getTxn(&rt, con.tx_hash, con.index) != null) {
                        std.debug.print("LMDB VERIFY FAIL: consumed still present\n", .{});
                        if (lmdbTruthEnabled()) {
                            std.debug.print("LMDB TRUTH: exiting due to verify failure\n", .{});
                            std.process.exit(1);
                        }
                    }
                }

                var vj: usize = 0;
                while (vj < deltas.produced.len and vj < 2) : (vj += 1) {
                    const p = deltas.produced[vj];
                    const raw = store.getTxn(&rt, p.input.tx_hash, p.input.index) orelse {
                        std.debug.print("LMDB VERIFY FAIL: produced missing\n", .{});
                        if (lmdbTruthEnabled()) {
                            std.debug.print("LMDB TRUTH: exiting due to verify failure\n", .{});
                            std.process.exit(1);
                        }
                        continue;
                    };
                    const dec = store.decodeTxOutValue(alloc, raw) orelse {
                        std.debug.print("LMDB VERIFY FAIL: produced decode\n", .{});
                        if (lmdbTruthEnabled()) {
                            std.debug.print("LMDB TRUTH: exiting due to verify failure\n", .{});
                            std.process.exit(1);
                        }
                        continue;
                    };
                    defer alloc.free(dec.address);
                    if (dec.lovelace != p.output.lovelace) {
                        std.debug.print("LMDB VERIFY FAIL: lovelace mismatch\n", .{});
                        if (lmdbTruthEnabled()) {
                            std.debug.print("LMDB TRUTH: exiting due to verify failure\n", .{});
                            std.process.exit(1);
                        }
                    }
                }
            }

            // Increment truth counter
            if (ctx.metrics) |metrics_any| {
                const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
                _ = m.lmdb_truth_blocks.fetchAdd(1, .acq_rel);
            }

            ctx.utxo_count_est += @as(i64, @intCast(deltas.produced.len));
            ctx.utxo_count_est -= @as(i64, @intCast(deltas.consumed.len));
            if (ctx.utxo_count_est < 0) ctx.utxo_count_est = 0;
            std.debug.print("UTXO live applied: -{d} +{d}\n", .{ deltas.consumed.len, deltas.produced.len });
            std.debug.print("UTXO est={d} undo_depth={d}\n", .{ ctx.utxo_count_est, undo_stack.items.len });
            maybePrintLmdbRatio(ctx);
            return;
        } else {
            std.debug.print("LMDB TRUTH beginWrite failed\n", .{});
            if (lmdbTruthEnabled()) std.process.exit(1);
            return;
        }
    }

    // Fallback: in-memory applyDelta (no LMDB)
    var undo = utxo.applyDelta(deltas.consumed, deltas.produced) catch |err| {
        std.debug.print("UTXO applyDelta failed: {s}\n", .{@errorName(err)});
        var empty_undo = utxo_mod.Undo.init(alloc);
        undo_stack.append(empty_undo) catch {
            empty_undo.deinit();
        };
        return;
    };
    undo_stack.append(undo) catch |err| {
        std.debug.print("UTXO undo append failed: {s}\n", .{@errorName(err)});
        undo.deinit();
        return;
    };
    if (undo_stack.items.len > MAX_UNDO_DEPTH) {
        var evicted = undo_stack.orderedRemove(0);
        evicted.deinitFreeAddresses();
    }
    ctx.utxo_count_est += @as(i64, @intCast(deltas.produced.len));
    ctx.utxo_count_est -= @as(i64, @intCast(deltas.consumed.len));
    if (ctx.utxo_count_est < 0) ctx.utxo_count_est = 0;
    std.debug.print("UTXO live applied: -{d} +{d}\n", .{ deltas.consumed.len, deltas.produced.len });
    std.debug.print("UTXO est={d} undo_depth={d}\n", .{ ctx.utxo_count_est, undo_stack.items.len });
}

fn lmdbSkipMemory() bool {
    return compat.hasEnvVar(std.heap.page_allocator, "TSUNAGI_LMDB");
}

fn lmdbTruthEnabled() bool {
    const v = compat.getEnvVarOwned(std.heap.page_allocator, "TSUNAGI_LMDB_TRUTH") catch return false;
    defer std.heap.page_allocator.free(v);
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

fn lmdbNativeEnabled() bool {
    const v = compat.getEnvVarOwned(std.heap.page_allocator, "TSUNAGI_MODE") catch return false;
    defer std.heap.page_allocator.free(v);
    return std.mem.eql(u8, v, "lmdb_native");
}

fn ledgerStrictEnabled() bool {
    const v = compat.getEnvVarOwned(std.heap.page_allocator, "TSUNAGI_LEDGER_STRICT") catch return false;
    defer std.heap.page_allocator.free(v);
    return std.mem.eql(u8, v, "1");
}

fn ledgerShadowEnabled() bool {
    const v = compat.getEnvVarOwned(std.heap.page_allocator, "TSUNAGI_LEDGER_SHADOW") catch return false;
    defer std.heap.page_allocator.free(v);
    return std.mem.eql(u8, v, "1");
}

fn ledgerPrimaryEnabled() bool {
    const v = compat.getEnvVarOwned(std.heap.page_allocator, "TSUNAGI_LEDGER_PRIMARY") catch return false;
    defer std.heap.page_allocator.free(v);
    return std.mem.eql(u8, v, "1");
}

fn ledgerPrimaryMode() ledger_pipeline.ApplyMode {
    const v = compat.getEnvVarOwned(std.heap.page_allocator, "TSUNAGI_LEDGER_PRIMARY_MODE") catch return .memory_only;
    defer std.heap.page_allocator.free(v);
    if (std.mem.eql(u8, v, "lmdb_truth")) return .lmdb_truth;
    if (std.mem.eql(u8, v, "lmdb_native")) return .lmdb_native;
    return .memory_only;
}

// ── Shadow ledger types and helpers ─────────────────────────────────

const ShadowStats = struct {
    blocks_applied: u64 = 0,
    mismatches: u64 = 0,
    apply_errors: u64 = 0,
    rollback_errors: u64 = 0,
    last_block_slot: u64 = 0,
    last_block_number: u64 = 0,
};

fn shadowApplyDeltas(ctx: *Context, deltas: tx_decode.TxDeltas, tip_slot: u64, tip_block: u64) void {
    const shadow = ctx.shadow_pipeline orelse return;
    // Mirror follower's early-return for empty deltas
    if (deltas.consumed.len == 0 and deltas.produced.len == 0) return;
    // Skip if follower skipped due to ledger violation
    if (ctx.ledger_violation_pending) return;

    _ = shadow.applyDeltas(deltas.consumed, deltas.produced) catch |err| {
        ctx.shadow_stats.apply_errors += 1;
        ctx.shadow_stats.mismatches += 1;
        std.debug.print("SHADOW LEDGER: apply error: {s} slot={d} block={d}\n", .{
            @errorName(err), tip_slot, tip_block,
        });
        return;
    };
    ctx.shadow_stats.blocks_applied += 1;
    ctx.shadow_stats.last_block_slot = tip_slot;
    ctx.shadow_stats.last_block_number = tip_block;

    // Compare undo depth with primary source of truth
    const primary_undo_depth: usize = if (ctx.primary_pipeline) |pp|
        pp.undoDepth()
    else if (ctx.undo_stack) |us|
        us.items.len
    else
        0;
    const shadow_undo_depth = shadow.undoDepth();
    if (shadow_undo_depth != primary_undo_depth) {
        ctx.shadow_stats.mismatches += 1;
        const primary_utxo: usize = if (ctx.primary_pipeline) |pp|
            pp.count()
        else if (ctx.utxo) |u|
            u.count()
        else
            0;
        std.debug.print(
            "SHADOW LEDGER MISMATCH:\n  block_no={d}\n  slot={d}\n  primary_utxo={d}\n  shadow_utxo={d}\n  primary_undo_depth={d}\n  shadow_undo_depth={d}\n",
            .{
                tip_block,
                tip_slot,
                primary_utxo,
                shadow.count(),
                primary_undo_depth,
                shadow_undo_depth,
            },
        );
    }

    // Periodic progress every 500 blocks
    if (ctx.shadow_stats.blocks_applied % 500 == 0) {
        std.debug.print("SHADOW LEDGER: progress blocks={d} mismatches={d}\n", .{
            ctx.shadow_stats.blocks_applied, ctx.shadow_stats.mismatches,
        });
    }
}

fn shadowRollback(ctx: *Context) void {
    const shadow = ctx.shadow_pipeline orelse return;
    shadow.rollback() catch {
        ctx.shadow_stats.rollback_errors += 1;
        ctx.shadow_stats.mismatches += 1;
        std.debug.print("SHADOW LEDGER: rollback failed (empty undo)\n", .{});
    };
}

fn shadowConfirmOldest(ctx: *Context) void {
    const shadow = ctx.shadow_pipeline orelse return;
    shadow.confirmOldest(@intCast(ctx.rolls_since_last_rollback), UNDO_CONFIRM_DEPTH);
}

fn shadowShutdownSummary(ctx: *Context, alloc: std.mem.Allocator) void {
    _ = alloc;
    const shadow = ctx.shadow_pipeline orelse return;
    // Idempotent: clear the handle so a re-entry is a no-op.
    ctx.shadow_pipeline = null;
    const s = ctx.shadow_stats;
    std.debug.print("SHADOW LEDGER: shutdown blocks={d} mismatches={d} apply_errors={d} rollback_errors={d} utxo={d} undo={d}\n", .{
        s.blocks_applied,
        s.mismatches,
        s.apply_errors,
        s.rollback_errors,
        shadow.count(),
        shadow.undoDepth(),
    });
    // Teardown discipline: this runs only at process exit. The shadow
    // pipeline's UTxO map and undo stack are intentionally NOT deep-freed.
    // Walking the structure to free every allocation microseconds before
    // the OS reclaims the entire address space is wasted work, and it was
    // the detonation surface for any latent ownership aliasing. Production
    // Cardano nodes (cardano-node under GC, Amaru under RAII) likewise do
    // not deep-free in-memory ledger state at shutdown — they persist the
    // on-disk store and let the runtime/OS reclaim memory. The allocation
    // is left to the OS.
}

// ── Primary ledger helpers ──────────────────────────────────────────

fn primaryApplyDeltas(ctx: *Context, pp: *ledger_pipeline.Pipeline, deltas: tx_decode.TxDeltas, tip_slot: u64, tip_block: u64) void {
    if (deltas.consumed.len == 0 and deltas.produced.len == 0) return;

    const result = pp.applyDeltas(deltas.consumed, deltas.produced) catch |err| {
        std.debug.print("PRIMARY LEDGER: apply error: {s} slot={d} block={d}\n", .{
            @errorName(err), tip_slot, tip_block,
        });
        // In lmdb_native mode, LMDB errors are fatal (matches inline behavior)
        if (pp.mode == .lmdb_native) {
            std.debug.print("PRIMARY LEDGER: fatal LMDB error in lmdb_native mode, exiting\n", .{});
            std.process.exit(1);
        }
        return;
    };

    // Track LMDB truth/fallback metrics for convergence tracking
    if (pp.mode == .lmdb_truth or pp.mode == .lmdb_native) {
        if (ctx.metrics) |metrics_any| {
            const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
            if (result.used_fallback) {
                _ = m.lmdb_fallback_blocks.fetchAdd(1, .acq_rel);
            } else {
                _ = m.lmdb_truth_blocks.fetchAdd(1, .acq_rel);
            }
        }
        if (result.used_fallback) {
            std.debug.print("PRIMARY LEDGER: used_fallback=true slot={d} block={d}\n", .{
                tip_slot, tip_block,
            });
        }
        if (result.coverage_total > 0) {
            std.debug.print("PRIMARY LEDGER: preflight coverage found={d} total={d} fallback={d}\n", .{
                result.coverage_found, result.coverage_total, @as(u1, if (result.used_fallback) 1 else 0),
            });
        }
    }

    ctx.utxo_count_est += @as(i64, @intCast(deltas.produced.len));
    ctx.utxo_count_est -= @as(i64, @intCast(deltas.consumed.len));
    if (ctx.utxo_count_est < 0) ctx.utxo_count_est = 0;

    std.debug.print("UTXO live applied (primary): -{d} +{d}\n", .{
        deltas.consumed.len, deltas.produced.len,
    });
    std.debug.print("UTXO est={d} undo_depth={d}\n", .{
        ctx.utxo_count_est, pp.undoDepth(),
    });
}

fn primaryRollback(pp: *ledger_pipeline.Pipeline) void {
    pp.rollback() catch {
        std.debug.print("PRIMARY LEDGER: rollback skipped (undo empty)\n", .{});
        return;
    };
    std.debug.print("PRIMARY LEDGER: rollback applied; utxo={d} undo_depth={d}\n", .{
        pp.count(), pp.undoDepth(),
    });
}

fn primaryShutdownSummary(ctx: *Context, alloc: std.mem.Allocator) void {
    _ = alloc;
    const pp = ctx.primary_pipeline orelse return;
    // Idempotent: clear the handle so a re-entry is a no-op.
    ctx.primary_pipeline = null;
    const mode_name: []const u8 = switch (pp.mode) {
        .memory_only => "memory_only",
        .lmdb_truth => "lmdb_truth",
        .lmdb_native => "lmdb_native",
    };
    std.debug.print("PRIMARY LEDGER: shutdown mode={s} utxo={d} undo={d}\n", .{
        mode_name, pp.count(), pp.undoDepth(),
    });
    // Teardown discipline: this runs only at process exit. The primary
    // pipeline's UTxO map and undo stack are intentionally NOT deep-freed.
    // Walking the structure to free every allocation microseconds before
    // the OS reclaims the entire address space is wasted work, and it was
    // the detonation surface for any latent ownership aliasing. Production
    // Cardano nodes (cardano-node under GC, Amaru under RAII) likewise do
    // not deep-free in-memory ledger state at shutdown — they persist the
    // on-disk store (here: LMDB, already durable) and let the runtime/OS
    // reclaim memory. The allocation is left to the OS.
}

fn strictStillActive(ctx: *Context) bool {
    if (!ctx.strict_active) return false;
    const now = compat.timestamp();
    if (now - ctx.strict_start_unix >= 600) {
        ctx.strict_active = false;
        std.debug.print("STRICT MODE: auto-disabled after 600s (convergence window)\n", .{});
        return false;
    }
    return true;
}

// ── Chain density guard ─────────────────────────────────────────────
const DENSITY_WINDOW_SLOTS: u64 = 100;
const MIN_DENSITY_X1E6: u64 = 10_000; // 0.010 blocks/slot minimum
const MAX_DENSITY_X1E6: u64 = 300_000; // 0.300 blocks/slot maximum (warn-only by default)

fn densityMaxStrictEnabled() bool {
    return compat.hasEnvVar(std.heap.page_allocator, "TSUNAGI_DENSITY_MAX_STRICT");
}

fn clockStrictEnabled() bool {
    return compat.hasEnvVar(std.heap.page_allocator, "TSUNAGI_CLOCK_STRICT");
}

fn ledgerAnomalyStrictEnabled() bool {
    return compat.hasEnvVar(std.heap.page_allocator, "TSUNAGI_LEDGER_ANOMALY_STRICT");
}

fn vrfEnforceEnabled() bool {
    return compat.hasEnvVar(std.heap.page_allocator, "TSUNAGI_VRF_ENFORCE");
}

fn headerStrictEnabled() bool {
    return compat.hasEnvVar(std.heap.page_allocator, "TSUNAGI_HEADER_STRICT");
}

/// Validate header hash + prev-hash linkage on roll-forward.
/// Returns true if OK, false if validation failure.
fn validateHeaderOnRollForward(
    ctx: *Context,
    alloc: std.mem.Allocator,
    inner_bytes: []const u8,
    computed_hash: [32]u8,
    tip_slot: u64,
    tip_block: u64,
) bool {
    const now = compat.timestamp();
    ctx.header_validate_total += 1;
    if (ctx.metrics) |ma| {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
        _ = m.header_validate_total.fetchAdd(1, .acq_rel);
    }

    // Hash validation: computeHeaderHash32 returns null (zeroes) if header shape is invalid
    const is_zero = std.mem.eql(u8, computed_hash[0..], &std.mem.zeroes([32]u8));
    if (is_zero) {
        ctx.header_hash_mismatch_total += 1;
        ctx.header_validate_fail_total += 1;
        if (ctx.metrics) |ma| {
            const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
            _ = m.header_hash_mismatch_total.fetchAdd(1, .acq_rel);
            _ = m.header_validate_fail_total.fetchAdd(1, .acq_rel);
        }
        if (now - ctx.last_header_validate_log_unix >= 60) {
            ctx.last_header_validate_log_unix = now;
            std.debug.print(
                "HEADER VALIDATE FAIL: hash mismatch (null hash) slot={d} block={d} len={d}\n",
                .{ tip_slot, tip_block, inner_bytes.len },
            );
        }
        updateHeaderValidateRatio(ctx);
        return false;
    }

    // Prev-hash linkage
    const prev_hash_opt = extractPrevHashFromRaw(alloc, inner_bytes);
    if (prev_hash_opt == null) {
        // Cannot extract prev_hash — do NOT fail validation (era/shape safety)
        if (ctx.metrics) |ma| {
            const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
            _ = m.header_prevhash_missing.fetchAdd(1, .acq_rel);
        }
        updateHeaderValidateRatio(ctx);
        return true;
    }

    if (ctx.header_head) |head| {
        if (ctx.header_head_stable) {
            const prev_hash = prev_hash_opt.?;
            if (!std.mem.eql(u8, prev_hash[0..], head[0..])) {
                ctx.header_prevhash_mismatch_total += 1;
                ctx.header_validate_fail_total += 1;
                if (ctx.metrics) |ma| {
                    const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                    _ = m.header_prevhash_mismatch_total.fetchAdd(1, .acq_rel);
                    _ = m.header_validate_fail_total.fetchAdd(1, .acq_rel);
                }
                if (now - ctx.last_header_validate_log_unix >= 60) {
                    ctx.last_header_validate_log_unix = now;
                    std.debug.print(
                        "HEADER VALIDATE FAIL: prev mismatch slot={d} block={d} prev={x} head={x}\n",
                        .{
                            tip_slot,
                            tip_block,
                            prev_hash[0..4],
                            head[0..4],
                        },
                    );
                }
                updateHeaderValidateRatio(ctx);
                return false;
            }
        }
    }

    // ── VRF proof validation ──
    // Verify the VRF proof in the received header against the epoch nonce.
    // Mode: observe (default) or enforce (TSUNAGI_VRF_ENFORCE=1).
    // Observe: log + counter only. Enforce: reject invalid headers.
    {
        ctx.vrf_validate_total += 1;
        const pa_vrf = std.heap.page_allocator;
        var epoch_nonce: ?[32]u8 = null;
        if (compat.getEnvVarOwned(pa_vrf, "TSUNAGI_EPOCH_NONCE_HEX")) |hex| {
            defer pa_vrf.free(hex);
            if (hex.len == 64) {
                var nonce: [32]u8 = undefined;
                if (std.fmt.hexToBytes(&nonce, hex)) |_| {
                    epoch_nonce = nonce;
                } else |_| {}
            }
        } else |_| {}

        const nonce_ptr: ?*const [32]u8 = if (epoch_nonce) |*n| n else null;
        const vrf_result = candidate_validator.validateVrf(alloc, inner_bytes, nonce_ptr);
        const enforce = vrfEnforceEnabled();
        switch (vrf_result.status) {
            .ok => {
                ctx.vrf_validate_ok += 1;
            },
            .skipped_no_nonce, .skipped_parse_fail => {
                ctx.vrf_validate_skip += 1;
            },
            .invalid_proof => {
                ctx.vrf_validate_fail += 1;
                if (now - ctx.last_vrf_validate_log_unix >= 10) {
                    ctx.last_vrf_validate_log_unix = now;
                    std.debug.print("VRF_VALIDATE_TRUTH: status=invalid_proof slot={d} block={d} enforce={} ok={d} fail={d} skip={d} total={d}\n", .{
                        tip_slot, tip_block, enforce, ctx.vrf_validate_ok, ctx.vrf_validate_fail, ctx.vrf_validate_skip, ctx.vrf_validate_total,
                    });
                }
                if (enforce) {
                    ctx.header_validate_fail_total += 1;
                    if (ctx.metrics) |ma| {
                        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                        _ = m.header_validate_fail_total.fetchAdd(1, .acq_rel);
                    }
                    updateHeaderValidateRatio(ctx);
                    return false;
                }
            },
        }
    }

    updateHeaderValidateRatio(ctx);
    return true;
}

fn updateHeaderValidateRatio(ctx: *Context) void {
    if (ctx.header_validate_total == 0) return;
    const ratio = (ctx.header_validate_fail_total * 1_000_000) / ctx.header_validate_total;
    if (ctx.metrics) |ma| {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
        m.header_validate_fail_ratio_x1e6.store(ratio, .release);
    }
}

/// Check consensus clock sanity on roll-forward. Returns true if strict
/// mode is enabled and a violation warrants disconnect.
fn checkClockSanity(ctx: *Context, slot: u64, now: i64) bool {
    const strict = clockStrictEnabled();
    var violation = false;

    if (ctx.clock_last_wall_unix != 0 and ctx.clock_last_slot_seen != 0) {
        const wall_delta: u64 = if (now > ctx.clock_last_wall_unix) @intCast(now - ctx.clock_last_wall_unix) else 0;
        const slot_delta: u64 = if (slot > ctx.clock_last_slot_seen) slot - ctx.clock_last_slot_seen else 0;

        // Compute drift = abs(slot_delta - wall_delta)
        const drift: u64 = if (slot_delta >= wall_delta) slot_delta - wall_delta else wall_delta - slot_delta;

        // Rule 1: Slot regression
        if (slot < ctx.clock_last_slot_seen) {
            violation = true;
        }

        // Rule 2: Excessive forward jump (slot_delta > wall_delta + 120)
        if (slot_delta > wall_delta + 120) {
            violation = true;
        }

        if (violation) {
            if (ctx.metrics) |ma| {
                const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                _ = m.consensus_clock_violation_total.fetchAdd(1, .acq_rel);
                m.consensus_slot_jump_last.store(slot_delta, .release);
                m.consensus_wall_drift_last.store(drift, .release);
            }
            // Rate-limited log (once per 60s)
            if (now - ctx.clock_last_violation_log_unix >= 60) {
                ctx.clock_last_violation_log_unix = now;
                const strict_u: u64 = if (strict) 1 else 0;
                std.debug.print("CLOCK VIOLATION: slot_delta={d} wall_delta={d} drift={d} strict={d}\n", .{ slot_delta, wall_delta, drift, strict_u });
            }
        } else {
            // Update drift gauge even when no violation (operational observability)
            if (ctx.metrics) |ma| {
                const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                m.consensus_wall_drift_last.store(drift, .release);
            }
        }
    }

    // Update state
    ctx.clock_last_wall_unix = now;
    ctx.clock_last_slot_seen = slot;

    return violation and strict;
}

/// Update consensus skeleton: 5-minute delta window + health score.
/// Called on every roll-forward. Observability only — no behavior change.
// ── Authority confidence model ──────────────────────────────────────

const AUTHORITY_WINDOW_SECONDS: i64 = 300;
const AUTHORITY_FINALITY_RAMP_SECONDS: i64 = 7200; // 2 hours to full finality

fn updateAuthorityModel(ctx: *Context, peer_slot: u64, peer_block_no: u64, peer_hash: [32]u8, is_rollback: bool, reorg_depth: u64) void {
    const now = compat.timestamp();

    // Initialize window + instability baseline
    if (ctx.authority_window_start_unix == 0) {
        ctx.authority_window_start_unix = now;
        ctx.authority_last_instability_unix = now;
    }

    // Stability gate: expire after gate_seconds
    const gate_active = ctx.authority_stable_gate_active and
        (now - ctx.authority_stable_gate_unix) < @as(i64, @intCast(ctx.authority_stable_gate_seconds));
    if (!gate_active and ctx.authority_stable_gate_active) {
        ctx.authority_stable_gate_active = false;
    }

    // Window rollover (reset 5m counters)
    if (now - ctx.authority_window_start_unix >= AUTHORITY_WINDOW_SECONDS) {
        ctx.authority_reorg_base = ctx.authority_reorg_events_5m;
        ctx.authority_fork_base = ctx.authority_fork_events_total;
        ctx.authority_reorg_depth_sum_5m = 0;
        ctx.authority_reorg_depth_max_5m = 0;
        ctx.authority_window_start_unix = now;
    }

    // Track rollback (always count, but only penalize outside gate)
    if (is_rollback) {
        ctx.authority_reorg_depth_last = reorg_depth;
        ctx.authority_reorg_events_5m += 1;
        ctx.authority_reorg_depth_sum_5m += reorg_depth;
        if (reorg_depth > ctx.authority_reorg_depth_max_5m)
            ctx.authority_reorg_depth_max_5m = reorg_depth;
        if (!gate_active) ctx.authority_last_instability_unix = now;
    }

    // Fork detection (same or earlier slot without rollback)
    if (peer_slot <= ctx.peer_observed_authority_slot and !is_rollback) {
        ctx.authority_fork_events_total += 1;
        if (!gate_active) ctx.authority_last_instability_unix = now;
    }

    // Update canonical tip if advancing
    if (peer_slot > ctx.peer_observed_authority_slot) {
        ctx.peer_observed_authority_slot = peer_slot;
        ctx.peer_observed_authority_block = peer_block_no;
        ctx.peer_observed_authority_hash = peer_hash;
    }

    // Compute 5m deltas
    const reorg_events_delta = ctx.authority_reorg_events_5m -| ctx.authority_reorg_base;
    const fork_delta_5m = ctx.authority_fork_events_total -| ctx.authority_fork_base;

    // Confidence: start=1.0, subtract penalties (suppressed during gate)
    var conf_x1e6: i64 = 1_000_000;
    if (!gate_active) {
        conf_x1e6 -= @as(i64, @intCast(@min(reorg_events_delta, 10))) * 60_000; // max 600k
        conf_x1e6 -= @as(i64, @intCast(@min(ctx.authority_reorg_depth_max_5m, 15))) * 20_000; // max 300k
        conf_x1e6 -= @as(i64, @intCast(@min(fork_delta_5m, 20))) * 10_000; // max 200k
        if (conf_x1e6 < 0) conf_x1e6 = 0;
    }
    ctx.authority_confidence_x1e6 = @intCast(conf_x1e6);

    // Finality: ramp linearly over 2 hours since last instability
    const stable_seconds = now - ctx.authority_last_instability_unix;
    const finality_x1e6: u64 = if (stable_seconds <= 0)
        0
    else
        @min(1_000_000, @as(u64, @intCast(stable_seconds)) * 1_000_000 / @as(u64, @intCast(AUTHORITY_FINALITY_RAMP_SECONDS)));
    ctx.authority_finality_score_x1e6 = finality_x1e6;

    // Stable seconds for metrics
    const stable_u64: u64 = if (stable_seconds >= 0) @intCast(stable_seconds) else 0;

    // Depth avg (x1e6 for float precision)
    const depth_avg_x1e6: u64 = if (reorg_events_delta > 0)
        (ctx.authority_reorg_depth_sum_5m * 1_000_000) / reorg_events_delta
    else
        0;

    // Reason code: determine dominant penalty term
    const reason_code: u64 = blk: {
        if (gate_active) break :blk 5; // gate_active
        if (stable_u64 < 60) break :blk 4; // low_stable_seconds
        const reorg_events_term: u64 = @as(u64, @min(reorg_events_delta, 10)) * 60_000;
        const reorg_depth_term: u64 = @as(u64, @min(ctx.authority_reorg_depth_max_5m, 15)) * 20_000;
        const fork_term: u64 = @as(u64, @min(fork_delta_5m, 20)) * 10_000;
        if (reorg_events_term == 0 and reorg_depth_term == 0 and fork_term == 0) break :blk 0; // ok
        if (reorg_events_term >= reorg_depth_term and reorg_events_term >= fork_term) break :blk 1; // reorg_events_5m
        if (reorg_depth_term >= reorg_events_term and reorg_depth_term >= fork_term) break :blk 2; // reorg_depth_max_5m
        break :blk 3; // fork_delta_5m
    };
    ctx.authority_reason_code_last = reason_code;

    const gate_u64: u64 = if (gate_active) 1 else 0;
    const window_unix: u64 = if (ctx.authority_window_start_unix > 0) @intCast(ctx.authority_window_start_unix) else 0;

    // Export to metrics
    if (ctx.metrics) |ma| {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
        m.authority_confidence_x1e6.store(ctx.authority_confidence_x1e6, .release);
        m.authority_finality_score_x1e6.store(ctx.authority_finality_score_x1e6, .release);
        m.authority_reorg_depth_last.store(ctx.authority_reorg_depth_last, .release);
        m.authority_reorg_events_5m.store(reorg_events_delta, .release);
        m.authority_fork_events_total.store(ctx.authority_fork_events_total, .release);
        m.authority_reorg_depth_max_5m.store(ctx.authority_reorg_depth_max_5m, .release);
        m.authority_reorg_depth_avg_x1e6.store(depth_avg_x1e6, .release);
        m.authority_fork_delta_5m.store(fork_delta_5m, .release);
        m.authority_stable_seconds.store(stable_u64, .release);
        m.authority_gate_active.store(gate_u64, .release);
        m.authority_reason_code_last.store(reason_code, .release);
        m.authority_reorg_events_delta_5m.store(reorg_events_delta, .release);
        m.authority_window_unix.store(window_unix, .release);
        m.consensus_last_authority_update_unix.store(@intCast(now), .release);
    }

    // Rate-limited log (60s)
    if (now - ctx.authority_last_log_unix >= 60) {
        ctx.authority_last_log_unix = now;
        std.debug.print("AUTHORITY: conf={d}.{d:0>6} fin={d}.{d:0>6} stable={d}s reorg5m={d} depth_max={d} fork_d5m={d} gate={d} reason={d}\n", .{
            ctx.authority_confidence_x1e6 / 1_000_000, ctx.authority_confidence_x1e6 % 1_000_000,
            finality_x1e6 / 1_000_000, finality_x1e6 % 1_000_000,
            stable_u64, reorg_events_delta, ctx.authority_reorg_depth_max_5m,
            fork_delta_5m, gate_u64, reason_code,
        });
    }
}

fn updateConsensusSkeleton(ctx: *Context, now: i64) void {
    const ma = ctx.metrics orelse return;
    const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));

    // 5-minute delta window
    if (ctx.consensus_window_start_unix == 0) {
        ctx.consensus_window_start_unix = now;
        ctx.consensus_herr_base = m.header_chain_errors.load(.acquire);
        ctx.consensus_kto_base = m.keepalive_timeouts_total.load(.acquire);
        ctx.consensus_rb_base = m.roll_back.load(.acquire);
        ctx.consensus_bf_batch_base = m.blockfetch_batch_done_total.load(.acquire);
        ctx.consensus_ka_pong_base = m.keepalive_pongs_total.load(.acquire);
        ctx.consensus_pc_base = m.peer_closed.load(.acquire);
        ctx.consensus_hsw_base = m.header_store_writes.load(.acquire);
    } else if (now - ctx.consensus_window_start_unix >= 300) {
        // Window rollover — compute deltas
        const herr_now = m.header_chain_errors.load(.acquire);
        const kto_now = m.keepalive_timeouts_total.load(.acquire);
        const rb_now = m.roll_back.load(.acquire);
        const bf_now = m.blockfetch_batch_done_total.load(.acquire);
        const ka_now = m.keepalive_pongs_total.load(.acquire);
        const pc_now = m.peer_closed.load(.acquire);
        const hsw_now = m.header_store_writes.load(.acquire);
        ctx.consensus_herr_delta_5m = herr_now -| ctx.consensus_herr_base;
        ctx.consensus_kto_delta_5m = kto_now -| ctx.consensus_kto_base;
        ctx.consensus_rb_delta_5m = rb_now -| ctx.consensus_rb_base;
        const bf_delta = bf_now -| ctx.consensus_bf_batch_base;
        const ka_delta = ka_now -| ctx.consensus_ka_pong_base;
        const pc_delta = pc_now -| ctx.consensus_pc_base;
        const hsw_delta = hsw_now -| ctx.consensus_hsw_base;
        // Reset window
        ctx.consensus_window_start_unix = now;
        ctx.consensus_herr_base = herr_now;
        ctx.consensus_kto_base = kto_now;
        ctx.consensus_rb_base = rb_now;
        ctx.consensus_bf_batch_base = bf_now;
        ctx.consensus_ka_pong_base = ka_now;
        ctx.consensus_pc_base = pc_now;
        ctx.consensus_hsw_base = hsw_now;
        // Store deltas
        m.consensus_header_err_delta_5m.store(ctx.consensus_herr_delta_5m, .release);
        m.consensus_keepalive_to_delta_5m.store(ctx.consensus_kto_delta_5m, .release);
        m.consensus_rollback_delta_5m.store(ctx.consensus_rb_delta_5m, .release);
        m.consensus_blockfetch_batches_delta_5m.store(bf_delta, .release);
        m.consensus_keepalive_pongs_delta_5m.store(ka_delta, .release);
        m.consensus_peer_closed_delta_5m.store(pc_delta, .release);
        m.consensus_header_store_writes_delta_5m.store(hsw_delta, .release);
        m.consensus_window_unix.store(@intCast(now), .release);
    }

    // Chain quality = density smoothed
    const quality = m.chain_density_smoothed_last_x1e6.load(.acquire);
    m.consensus_chain_quality_x1e6.store(quality, .release);

    // Health score: start 100, subtract for problems, clamp 0..100
    var score: i64 = 100;
    // Stall: -30
    if (m.peer_stall_active.load(.acquire) == 1) score -= 30;
    // Header errors in last 5m: -5 each (cap 40)
    score -= @as(i64, @intCast(@min(ctx.consensus_herr_delta_5m * 5, 40)));
    // Rollbacks in last 5m: -5 each (cap 30)
    score -= @as(i64, @intCast(@min(ctx.consensus_rb_delta_5m * 5, 30)));
    // Keepalive timeouts in last 5m: -3 each (cap 20)
    score -= @as(i64, @intCast(@min(ctx.consensus_kto_delta_5m * 3, 20)));
    if (score < 0) score = 0;
    m.consensus_health_score.store(@intCast(score), .release);
}

/// Check chain density in a moving window. Returns true if a violation
/// was detected (caller should penalize peer and reconnect).
fn maybeCheckDensity(ctx: *Context, slot: u64) bool {
    ctx.density_max_triggered = false;
    if (slot == 0) return false;

    // Initialize window on first forward
    if (ctx.density_window_start_slot == 0) {
        ctx.density_window_start_slot = slot;
        ctx.density_window_block_count = 0;
        return false;
    }

    if (slot < ctx.density_window_start_slot) return false;

    ctx.density_window_block_count += 1;
    const slot_delta = slot - ctx.density_window_start_slot;

    if (slot_delta < DENSITY_WINDOW_SLOTS) return false;

    // Window closed — compute density
    const density_x1e6 = (ctx.density_window_block_count * 1_000_000) / slot_delta;
    const window_start = ctx.density_window_start_slot;

    // Shift rolling history
    ctx.density_prev2_x1e6 = ctx.density_prev1_x1e6;
    ctx.density_prev1_x1e6 = ctx.density_last_x1e6;
    ctx.density_last_x1e6 = density_x1e6;

    // Compute rolling average of non-zero entries (last 3 windows)
    var sum: u64 = 0;
    var count: u64 = 0;
    if (ctx.density_last_x1e6 > 0) {
        sum += ctx.density_last_x1e6;
        count += 1;
    }
    if (ctx.density_prev1_x1e6 > 0) {
        sum += ctx.density_prev1_x1e6;
        count += 1;
    }
    if (ctx.density_prev2_x1e6 > 0) {
        sum += ctx.density_prev2_x1e6;
        count += 1;
    }
    const density_smoothed_x1e6: u64 = if (count > 0) sum / count else density_x1e6;

    // Update metrics regardless of violation
    if (ctx.metrics) |metrics_any| {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
        m.chain_density_last_x1e6.store(density_x1e6, .release);
        m.chain_density_window_blocks_last.store(ctx.density_window_block_count, .release);
        m.chain_density_window_slots_last.store(slot_delta, .release);
        m.chain_density_smoothed_last_x1e6.store(density_smoothed_x1e6, .release);
        m.chain_density_violation_streak_last.store(ctx.density_violation_streak, .release);

        // Update density baseline EMA (alpha=0.05)
        const d_f64: f64 = @floatFromInt(density_x1e6);
        if (ctx.density_baseline_updates == 0) {
            ctx.density_baseline_ema_f64 = d_f64;
        } else {
            ctx.density_baseline_ema_f64 = 0.95 * ctx.density_baseline_ema_f64 + 0.05 * d_f64;
        }
        ctx.density_baseline_updates += 1;
        const baseline_x1e6: u64 = @intFromFloat(ctx.density_baseline_ema_f64);

        // Recommended thresholds (metrics-only, not enforced)
        const rec_min_x1e6: u64 = @max(MIN_DENSITY_X1E6, (baseline_x1e6 * 20) / 100);
        const rec_max_x1e6: u64 = @min(500_000, baseline_x1e6 * 5);

        m.chain_density_baseline_x1e6.store(baseline_x1e6, .release);
        m.chain_density_recommended_min_x1e6.store(rec_min_x1e6, .release);
        m.chain_density_recommended_max_x1e6.store(rec_max_x1e6, .release);
        _ = m.chain_density_baseline_updates_total.fetchAdd(1, .acq_rel);
        const now_bl = compat.timestamp();
        m.chain_density_baseline_last_unix.store(@as(u64, @intCast(@max(0, now_bl))), .release);

        // Rate-limited baseline log (60s)
        if (now_bl - ctx.last_density_baseline_log_unix >= 60) {
            ctx.last_density_baseline_log_unix = now_bl;
            std.debug.print(
                "DENSITY BASELINE: last={d}.{d:0>6} avg3={d}.{d:0>6} baseline={d}.{d:0>6} rec_min={d}.{d:0>6} rec_max={d}.{d:0>6}\n",
                .{
                    density_x1e6 / 1_000_000,          density_x1e6 % 1_000_000,
                    density_smoothed_x1e6 / 1_000_000,  density_smoothed_x1e6 % 1_000_000,
                    baseline_x1e6 / 1_000_000,          baseline_x1e6 % 1_000_000,
                    rec_min_x1e6 / 1_000_000,           rec_min_x1e6 % 1_000_000,
                    rec_max_x1e6 / 1_000_000,           rec_max_x1e6 % 1_000_000,
                },
            );
        }
    }

    // Reset window for next cycle
    const blocks = ctx.density_window_block_count;
    ctx.density_window_start_slot = slot;
    ctx.density_window_block_count = 0;

    // Violation decision uses smoothed avg3
    if (density_smoothed_x1e6 < MIN_DENSITY_X1E6) {
        ctx.density_violation_streak += 1;
        if (ctx.metrics) |metrics_any| {
            const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
            _ = m.chain_density_violation_total.fetchAdd(1, .acq_rel);
            m.chain_density_violation_streak_last.store(ctx.density_violation_streak, .release);
        }
        const now = compat.timestamp();
        if (now - ctx.last_density_violation_log_unix >= 60) {
            ctx.last_density_violation_log_unix = now;
            const penalty_x100: u64 = switch (ctx.density_violation_streak) {
                1 => 20,
                2 => 40,
                else => 80,
            };
            std.debug.print(
                "DENSITY VIOLATION: slot_range=[{d}-{d}] window_blocks={d} window_slots={d} last={d}.{d:0>6} avg3={d}.{d:0>6} threshold={d}.{d:0>6} streak={d} penalty=0.{d:0>2}\n",
                .{
                    window_start,                       slot,
                    blocks,                             slot_delta,
                    density_x1e6 / 1_000_000,           density_x1e6 % 1_000_000,
                    density_smoothed_x1e6 / 1_000_000,  density_smoothed_x1e6 % 1_000_000,
                    MIN_DENSITY_X1E6 / 1_000_000,       MIN_DENSITY_X1E6 % 1_000_000,
                    ctx.density_violation_streak,        penalty_x100,
                },
            );
        }
        return true;
    }

    ctx.density_violation_streak = 0;
    if (ctx.metrics) |metrics_any| {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
        m.chain_density_violation_streak_last.store(0, .release);
    }

    // Max-density check (disjoint from min — density too high)
    if (density_smoothed_x1e6 > MAX_DENSITY_X1E6) {
        ctx.density_max_triggered = true;
        ctx.density_max_violation_streak += 1;
        if (ctx.metrics) |metrics_any| {
            const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
            _ = m.chain_density_max_violation_total.fetchAdd(1, .acq_rel);
            m.chain_density_max_last_x1e6.store(density_smoothed_x1e6, .release);
        }
        const now_max = compat.timestamp();
        if (now_max - ctx.last_density_max_log_unix >= 60) {
            ctx.last_density_max_log_unix = now_max;
            const strict = densityMaxStrictEnabled();
            std.debug.print(
                "MAX DENSITY WARN: slot_range=[{d}-{d}] blocks={d} slots={d} avg3={d}.{d:0>6} max={d}.{d:0>6} strict={d}\n",
                .{
                    window_start,                       slot,
                    blocks,                             slot_delta,
                    density_smoothed_x1e6 / 1_000_000,  density_smoothed_x1e6 % 1_000_000,
                    MAX_DENSITY_X1E6 / 1_000_000,       MAX_DENSITY_X1E6 % 1_000_000,
                    @as(u64, if (strict) 1 else 0),
                },
            );
        }
    } else {
        ctx.density_max_violation_streak = 0;
        if (ctx.metrics) |metrics_any| {
            const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
            m.chain_density_max_last_x1e6.store(density_smoothed_x1e6, .release);
        }
    }

    return false;
}

// ── Rollback flap guard ─────────────────────────────────────────────
const ROLLBACK_WINDOW_SECS: i64 = 600; // 10 minutes
const ROLLBACK_FLAP_MAX_COUNT: u64 = 5; // >5 rollbacks per window triggers
const ROLLBACK_STABILIZE_S: i64 = 60; // v1.5.9: suppress header errors for 60s post-rollback

/// Update rollback flap window. Returns true if a flap violation was detected.
fn maybeUpdateRollbackFlap(ctx: *Context, depth: u64) bool {
    const now = compat.timestamp();

    // Initialize or expire window
    if (ctx.rollback_window_start_unix == 0) {
        ctx.rollback_window_start_unix = now;
        ctx.rollback_window_count = 0;
        ctx.rollback_window_depth_sum = 0;
        ctx.rollback_window_depth_max = 0;
    } else if (now - ctx.rollback_window_start_unix > ROLLBACK_WINDOW_SECS) {
        ctx.rollback_window_start_unix = now;
        ctx.rollback_window_count = 0;
        ctx.rollback_window_depth_sum = 0;
        ctx.rollback_window_depth_max = 0;
    }

    ctx.rollback_window_count += 1;
    ctx.rollback_window_depth_sum += depth;
    ctx.rollback_window_depth_max = @max(ctx.rollback_window_depth_max, depth);

    // Update metrics gauges
    if (ctx.metrics) |metrics_any| {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
        m.rollback_window_count_last.store(ctx.rollback_window_count, .release);
        m.rollback_window_max_depth_last.store(ctx.rollback_window_depth_max, .release);
        const avg_x1000 = if (ctx.rollback_window_count > 0)
            (ctx.rollback_window_depth_sum * 1000) / ctx.rollback_window_count
        else
            0;
        m.rollback_window_avg_depth_x1000.store(avg_x1000, .release);
    }

    if (ctx.rollback_window_count > ROLLBACK_FLAP_MAX_COUNT) {
        if (ctx.metrics) |metrics_any| {
            const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
            _ = m.rollback_flap_violation_total.fetchAdd(1, .acq_rel);
        }
        if (now - ctx.last_rollback_flap_log_unix >= 60) {
            ctx.last_rollback_flap_log_unix = now;
            const avg = if (ctx.rollback_window_count > 0)
                ctx.rollback_window_depth_sum / ctx.rollback_window_count
            else
                0;
            std.debug.print(
                "ROLLBACK FLAP: count={d}/10m avg_depth={d} max_depth={d} → reconnect\n",
                .{ ctx.rollback_window_count, avg, ctx.rollback_window_depth_max },
            );
        }
        // BAEY audit
        if (now - ctx.baey_last_rollback_unix >= 60) {
            ctx.baey_last_rollback_unix = now;
            baeyLog(ctx, "rollback_flap", "excessive_rollbacks", "reconnect", ctx.cursor.slot, ctx.cursor.block_no);
        }
        return true;
    }
    return false;
}

// ── Chain selection policy ────────────────────────────────────────────
const CHAIN_SELECT_SCORE_MARGIN: i64 = 200;
const CHAIN_SELECT_COOLDOWN_S: i64 = 300; // 5 minutes between score-based switches

fn computePeerScore(
    slot: u64,
    height: u64,
    density_x1e6: u64,
    rollback_count: u64,
    rollback_max_depth: u64,
    bayes_sample_x1e6: u64,
) i64 {
    const slot_term: i64 = @intCast(slot / 10);
    const clamped_height: u64 = @min(height, std.math.maxInt(u64) / 5);
    const height_term: i64 = @intCast(clamped_height * 5);
    const density_term: i64 = @intCast(density_x1e6 / 1000);
    const rb_count_raw: u64 = @min(rollback_count, 100);
    const rb_count: u64 = if (rb_count_raw <= 1) 0 else rb_count_raw; // v1.5.9: single rollback is normal
    const rollback_penalty: i64 = @intCast(rb_count * 200);
    const rb_depth: u64 = @min(rollback_max_depth, 1000);
    const depth_penalty: i64 = @intCast(rb_depth * 10);
    const tiebreak: i64 = @intCast(bayes_sample_x1e6 / 10000);
    return slot_term + height_term + density_term - rollback_penalty - depth_penalty + tiebreak;
}

fn classifyChainSelectReason(
    probe_slot: u64,
    current_slot: u64,
    probe_block: u64,
    current_block: u64,
    current_height: u64,
    stall_active: bool,
    rollback_count: u64,
    density_violation_streak: u32,
) u64 {
    if (probe_slot > current_slot + 200) return 1; // probe_better_slot
    const block_delta = if (probe_block > current_block) probe_block - current_block else 0;
    const proxy_height_delta = block_delta;
    _ = current_height;
    if (proxy_height_delta > 20) return 2; // probe_better_height
    if (stall_active) return 3; // stall_recovery
    if (rollback_count >= 3) return 4; // rollback_risk
    if (density_violation_streak > 0) return 5; // density_risk
    return 6; // bayes_tiebreak
}

// ── Header probe (multi-peer tip comparison) ────────────────────────
const PROBE_INTERVAL_S: i64 = 120; // probe every 2 minutes
const PROBE_TIMEOUT_MS: u32 = 8_000; // 8s total timeout per probe
const PROBE_SWITCH_SLOT_DELTA: u64 = 200; // switch if probe slot is 200+ ahead
const PROBE_SWITCH_BLOCK_DELTA: u64 = 20; // switch if probe block is 20+ ahead

const ProbeArgs = struct {
    alloc: std.mem.Allocator,
    host: []const u8,
    port: u16,
    network_magic: u64,
    peer_sharing: bool,
    peer_idx: usize,
    metrics: ?*http_metrics.Metrics,
    ctx: *Context,
};

fn runHeaderProbe(args: ProbeArgs) void {
    const a = args.alloc;

    // Connect with short timeout
    var bt = tcp_bt.connect(a, args.host, args.port) catch {
        if (args.metrics) |m| _ = m.header_probe_fail_total.fetchAdd(1, .acq_rel);
        args.ctx.probe_inflight = false;
        return;
    };
    defer bt.deinit();

    tcp_bt.setReadTimeout(&bt, PROBE_TIMEOUT_MS) catch {};

    // Handshake
    const accepted = doHandshake(a, &bt, args.network_magic, args.peer_sharing) catch {
        if (args.metrics) |m| _ = m.header_probe_fail_total.fetchAdd(1, .acq_rel);
        args.ctx.probe_inflight = false;
        return;
    };
    if (!accepted) {
        if (args.metrics) |m| _ = m.header_probe_fail_total.fetchAdd(1, .acq_rel);
        args.ctx.probe_inflight = false;
        return;
    }

    // FindIntersect at origin — the points list must CONTAIN the origin point [[]],
    // NOT be empty ([]). See chainsync_codec.encodeFindIntersectOrigin.
    {
        var list = std.array_list.Managed(u8).init(a);
        defer list.deinit();
        chainsync_codec.encodeFindIntersectOrigin(compat.listWriter(&list)) catch {
            if (args.metrics) |m| _ = m.header_probe_fail_total.fetchAdd(1, .acq_rel);
            args.ctx.probe_inflight = false;
            return;
        };
        const msg_bytes = list.toOwnedSlice() catch {
            if (args.metrics) |m| _ = m.header_probe_fail_total.fetchAdd(1, .acq_rel);
            args.ctx.probe_inflight = false;
            return;
        };
        defer a.free(msg_bytes);
        mux_bearer.sendSegment(&bt, .responder, chainsync_proto, msg_bytes) catch {
            if (args.metrics) |m| _ = m.header_probe_fail_total.fetchAdd(1, .acq_rel);
            args.ctx.probe_inflight = false;
            return;
        };
    }

    // Phase 1: Read first chainsync response to get tip
    var got_tip = false;
    var probe_slot: u64 = 0;
    var probe_block: u64 = 0;
    var first_tip_hash: ?[32]u8 = null;

    for (0..5) |_| {
        const seg = mux_bearer.recvSegmentWithTimeout(a, &bt) catch break;
        if (seg == null) break;
        defer a.free(seg.?.payload);

        if (seg.?.hdr.proto != chainsync_proto) continue;

        var fbs = compat.fixedBufferStream(seg.?.payload);
        const resp = chainsync_codec.decodeResponse(a, fbs.reader()) catch break;
        defer chainsync_codec.free(a, @constCast(&resp));

        const tip_term: ?cbor.Term = switch (resp) {
            .intersect_found => |iv| iv.tip,
            .intersect_not_found => |iv| iv.tip,
            .roll_forward => |iv| iv.tip,
            else => null,
        };
        if (tip_term) |tip| {
            if (getTipSlotBlock(tip)) |tsb| {
                probe_slot = tsb.slot;
                probe_block = tsb.block_no;
                got_tip = true;
            }
            first_tip_hash = tipHash32(tip);
        }
        break;
    }

    if (!got_tip) {
        if (args.metrics) |m| _ = m.header_probe_fail_total.fetchAdd(1, .acq_rel);
        args.ctx.probe_inflight = false;
        return;
    }

    // Phase 2: Integrity check — send RequestNext, read one more message,
    // verify the tip hash is consistent (peer speaks coherent headers).
    var integrity_ok = false;
    integrity_blk: {
        const recorded_hash = first_tip_hash orelse break :integrity_blk;

        // Send RequestNext
        var req_list = std.array_list.Managed(u8).init(a);
        defer req_list.deinit();
        chainsync_codec.encodeRequestNext(compat.listWriter(&req_list)) catch break :integrity_blk;
        const req_bytes = req_list.toOwnedSlice() catch break :integrity_blk;
        defer a.free(req_bytes);
        mux_bearer.sendSegment(&bt, .responder, chainsync_proto, req_bytes) catch break :integrity_blk;

        // Read up to 5 segments looking for a second chainsync response
        for (0..5) |_| {
            const seg2 = mux_bearer.recvSegmentWithTimeout(a, &bt) catch break :integrity_blk;
            if (seg2 == null) break :integrity_blk;
            defer a.free(seg2.?.payload);

            if (seg2.?.hdr.proto != chainsync_proto) continue;

            var fbs2 = compat.fixedBufferStream(seg2.?.payload);
            const resp2 = chainsync_codec.decodeResponse(a, fbs2.reader()) catch break :integrity_blk;
            defer chainsync_codec.free(a, @constCast(&resp2));

            // Extract tip from the second message
            const tip2_term: ?cbor.Term = switch (resp2) {
                .roll_forward => |iv| iv.tip,
                .roll_backward => |iv| iv.tip,
                .await_reply => {
                    // AwaitReply means we're at tip — peer is coherent, tip hasn't changed
                    integrity_ok = true;
                    break :integrity_blk;
                },
                else => null,
            };

            if (tip2_term) |tip2| {
                const second_hash = tipHash32(tip2) orelse break :integrity_blk;
                // Tip hash must match (peer's reported tip should be consistent
                // across consecutive messages within the same session)
                if (std.mem.eql(u8, recorded_hash[0..], second_hash[0..])) {
                    integrity_ok = true;
                }
            }
            break :integrity_blk;
        }
    }

    // Count success but separate integrity status
    if (args.metrics) |m| _ = m.header_probe_success_total.fetchAdd(1, .acq_rel);

    if (integrity_ok) {
        if (args.metrics) |m| {
            _ = m.header_probe_integrity_ok_total.fetchAdd(1, .acq_rel);
            m.header_probe_best_slot.store(probe_slot, .release);
            m.header_probe_best_block.store(probe_block, .release);
            m.header_probe_best_peer_index.store(args.peer_idx, .release);
        }
        args.ctx.probe_result_slot.store(probe_slot, .release);
        args.ctx.probe_result_block.store(probe_block, .release);
        args.ctx.probe_result_peer_idx.store(args.peer_idx, .release);
        args.ctx.probe_result_integrity_ok.store(true, .release);
        args.ctx.probe_result_ready.store(true, .release);
    } else {
        if (args.metrics) |m| _ = m.header_probe_integrity_fail_total.fetchAdd(1, .acq_rel);
        // Mark result as not integrity-ok so main thread won't use it
        args.ctx.probe_result_integrity_ok.store(false, .release);
        args.ctx.probe_result_slot.store(probe_slot, .release);
        args.ctx.probe_result_block.store(probe_block, .release);
        args.ctx.probe_result_peer_idx.store(args.peer_idx, .release);
        args.ctx.probe_result_ready.store(true, .release);
    }

    args.ctx.probe_inflight = false;
}

fn maybeStartHeaderProbe(
    ctx: *Context,
    score: *PeerScore,
    current_relay_idx: usize,
) void {
    if (ctx.probe_inflight) return;

    const now = compat.timestamp();
    if (now - ctx.last_probe_unix < PROBE_INTERVAL_S) return;
    ctx.last_probe_unix = now;

    // Pick an alternate relay (not current)
    var probe_idx = pickRelay(score, null);
    if (probe_idx == current_relay_idx) {
        // Try next index
        probe_idx = (current_relay_idx + 1) % RELAY_COUNT;
    }

    const relay = mainnet_relays[probe_idx];
    const m: ?*http_metrics.Metrics = if (ctx.metrics) |ma|
        @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))))
    else
        null;

    ctx.probe_inflight = true;
    const args = ProbeArgs{
        .alloc = std.heap.page_allocator,
        .host = relay.host,
        .port = relay.port,
        .network_magic = ctx.network_magic,
        .peer_sharing = ctx.peer_sharing,
        .peer_idx = probe_idx,
        .metrics = m,
        .ctx = ctx,
    };

    const thread = std.Thread.spawn(.{}, runHeaderProbe, .{args}) catch {
        ctx.probe_inflight = false;
        return;
    };
    thread.detach();
}

fn maybeApplyProbeSwitch(
    ctx: *Context,
    score: *PeerScore,
    current_relay_idx: *usize,
    peer_was_closed: *bool,
) void {
    if (!ctx.probe_result_ready.load(.acquire)) return;
    ctx.probe_result_ready.store(false, .release);

    // v1.5.9: suppress switch during rollback stabilization window
    {
        const now_sw = compat.timestamp();
        if (now_sw < ctx.rollback_stabilize_until_unix) {
            if (now_sw - ctx.last_rollback_stabilize_log_unix >= 60) {
                ctx.last_rollback_stabilize_log_unix = now_sw;
                std.debug.print("CHAIN SELECT: suppressed switch (rollback stabilize, remaining={d}s)\n", .{
                    ctx.rollback_stabilize_until_unix - now_sw,
                });
            }
            return;
        }
    }

    const probe_slot = ctx.probe_result_slot.load(.acquire);
    const probe_block = ctx.probe_result_block.load(.acquire);
    const probe_idx = ctx.probe_result_peer_idx.load(.acquire);
    const integrity_ok = ctx.probe_result_integrity_ok.load(.acquire);

    const now = compat.timestamp();
    const can_log = (now - ctx.last_probe_integrity_log_unix >= 60);

    // ── Per-peer tip tracking ──
    if (probe_idx < ctx.peer_tip_slots.len) {
        ctx.peer_tip_slots[probe_idx] = probe_slot;
        ctx.peer_tip_blocks[probe_idx] = probe_block;
        ctx.peer_tip_last_seen[probe_idx] = now;
        ctx.peer_tip_ok[probe_idx] = integrity_ok;
        ctx.peer_tip_probes_total += 1;

        // Compute divergence across known peers
        var max_slot: u64 = 0;
        var min_slot: u64 = std.math.maxInt(u64);
        var known_count: u32 = 0;
        var stale_count: u32 = 0;
        for (ctx.peer_tip_slots, ctx.peer_tip_last_seen) |s, ls| {
            if (ls == 0) continue; // never probed
            known_count += 1;
            if (s > max_slot) max_slot = s;
            if (s < min_slot) min_slot = s;
            if (now - ls > 600) stale_count += 1; // >10 min = stale
        }
        // Include current active peer's tip
        if (ctx.last_header_slot > 0) {
            known_count += 1;
            if (ctx.last_header_slot > max_slot) max_slot = ctx.last_header_slot;
            if (ctx.last_header_slot < min_slot) min_slot = ctx.last_header_slot;
        }

        const divergence = if (max_slot > min_slot) max_slot - min_slot else 0;
        ctx.peer_tip_max_divergence_slots = divergence;
        ctx.peer_tip_stale_count = stale_count;

        if (divergence > 60 and known_count >= 2) {
            ctx.peer_tip_disagree_total += 1;
        }

        // Periodic truth log (every 120s)
        if (now - ctx.last_peer_tip_log_unix >= 120) {
            ctx.last_peer_tip_log_unix = now;
            std.debug.print("PEER_TIP_TRUTH: probes_total={d} known_peers={d} max_slot={d} min_slot={d} divergence={d} stale={d} disagree_total={d}\n", .{
                ctx.peer_tip_probes_total, known_count, max_slot, min_slot, divergence, stale_count, ctx.peer_tip_disagree_total,
            });
        }
    }

    // Integrity gate: do not trust probes that failed integrity check
    if (!integrity_ok) {
        _ = penalizePeerRateLimited(score, probe_idx, 0.5, .authority_fail, now, ctx.metrics);
        if (can_log) {
            ctx.last_probe_integrity_log_unix = now;
            std.debug.print(
                "PROBE INTEGRITY FAIL: idx={d} slot={d} block={d} reason=tip_hash_mismatch\n",
                .{ probe_idx, probe_slot, probe_block },
            );
        }
        return;
    }

    if (can_log) {
        ctx.last_probe_integrity_log_unix = now;
        std.debug.print(
            "PROBE INTEGRITY OK: idx={d} slot={d} block={d}\n",
            .{ probe_idx, probe_slot, probe_block },
        );
    }

    // ── Chain Selection Policy v1: score-based switching ──
    const our_slot = ctx.cursor.slot;
    const our_block = ctx.cursor.block_no;

    // Compute density avg3 for scoring
    var d_sum: u64 = 0;
    var d_cnt: u64 = 0;
    if (ctx.density_last_x1e6 > 0) { d_sum += ctx.density_last_x1e6; d_cnt += 1; }
    if (ctx.density_prev1_x1e6 > 0) { d_sum += ctx.density_prev1_x1e6; d_cnt += 1; }
    if (ctx.density_prev2_x1e6 > 0) { d_sum += ctx.density_prev2_x1e6; d_cnt += 1; }
    const density_avg3 = if (d_cnt > 0) d_sum / d_cnt else 0;

    // Bayes samples (x1e6 scale)
    const cur_bayes_x1e6: u64 = @intFromFloat(@max(0.0, score.sample[current_relay_idx.*]) * 1_000_000);
    const probe_bayes_x1e6: u64 = if (probe_idx < RELAY_COUNT)
        @intFromFloat(@max(0.0, score.sample[probe_idx]) * 1_000_000)
    else
        500_000;

    // Proxy probe height: current_height + (probe_block - current_block), clamped
    const block_delta_proxy = if (probe_block > our_block) probe_block - our_block else 0;
    const probe_height_proxy = ctx.header_height + block_delta_proxy;

    const current_score = computePeerScore(
        our_slot,
        ctx.header_height,
        density_avg3,
        ctx.rollback_window_count,
        ctx.rollback_window_depth_max,
        cur_bayes_x1e6,
    );
    const best_score = computePeerScore(
        probe_slot,
        probe_height_proxy,
        density_avg3, // same density context for both
        0, // probe peer has no rollback history from our perspective
        0,
        probe_bayes_x1e6,
    );

    // Update score gauges always (even if no switch)
    if (ctx.metrics) |ma| {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
        m.chain_select_score_current_last.store(@intCast(@max(0, current_score)), .release);
        m.chain_select_score_best_last.store(@intCast(@max(0, best_score)), .release);
    }

    // Check margin + cooldown
    if (best_score < current_score + CHAIN_SELECT_SCORE_MARGIN) return;
    if (now - ctx.last_chain_select_switch_unix < CHAIN_SELECT_COOLDOWN_S) return;

    // Determine dominant reason
    const reason = classifyChainSelectReason(
        probe_slot,
        our_slot,
        probe_block,
        our_block,
        ctx.header_height,
        ctx.stall_active,
        ctx.rollback_window_count,
        ctx.density_violation_streak,
    );

    // Execute switch
    _ = penalizePeerRateLimited(score, current_relay_idx.*, 0.2, .other, now, ctx.metrics);
    rewardPeer(score, probe_idx, 0.1);
    ctx.preferred_peer_idx = probe_idx;
    peer_was_closed.* = true;
    ctx.last_chain_select_switch_unix = now;

    if (ctx.metrics) |ma| {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
        _ = m.chain_select_switch_total.fetchAdd(1, .acq_rel);
        _ = m.header_probe_switch_total.fetchAdd(1, .acq_rel);
        m.chain_select_last_reason_code.store(reason, .release);
        _ = m.baey_switches_total.fetchAdd(1, .acq_rel);
        m.baey_last_switch_reason_code.store(reason, .release);
        m.baey_last_switch_unix.store(@intCast(now), .release);
    }

    // BAEY audit
    if (now - ctx.baey_last_peer_switch_unix >= 60) {
        ctx.baey_last_peer_switch_unix = now;
        baeyLog(ctx, "peer_switch", "probe_better", "reconnect", our_slot, our_block);
    }

    // Rate-limited log
    if (now - ctx.last_chain_select_log_unix >= 60) {
        ctx.last_chain_select_log_unix = now;
        const slot_delta = if (probe_slot > our_slot) probe_slot - our_slot else 0;
        const block_delta = if (probe_block > our_block) probe_block - our_block else 0;
        std.debug.print(
            "CHAIN SELECT: switch cur_idx={d}(score={d}) -> best_idx={d}(score={d}) reason={d} slot_delta={d} block_delta={d} density_avg3={d} rollback_count={d}\n",
            .{ current_relay_idx.*, current_score, probe_idx, best_score, reason, slot_delta, block_delta, density_avg3, ctx.rollback_window_count },
        );
    }
}

// ── Stall detection + probe-based recovery ──────────────────────────
const STALL_SECS: i64 = 45;
const STALL_SWITCH_MIN_COOLDOWN: i64 = 300; // 5 minutes

fn maybeCheckStallAndSwitch(
    ctx: *Context,
    score: *PeerScore,
    current_relay_idx: *usize,
    peer_was_closed: *bool,
) void {
    const now = compat.timestamp();

    // Initialize on first tick
    if (ctx.last_roll_fwd_unix == 0) {
        ctx.last_roll_fwd_unix = now;
        return;
    }

    const elapsed = now - ctx.last_roll_fwd_unix;
    const stalled = elapsed >= STALL_SECS;

    // Compute stall attribution ages (always, for metrics)
    const stall_age: u64 = if (elapsed > 0) @intCast(elapsed) else 0;
    var bf_age: u64 = 0;
    var ka_age: u64 = 0;
    var reason_code: u64 = 0;

    if (ctx.metrics) |ma| {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
        m.peer_last_roll_fwd_unix.store(@intCast(ctx.last_roll_fwd_unix), .release);
        m.peer_stall_active.store(if (stalled) 1 else 0, .release);

        // Compute ages from timestamps
        const bf_unix = m.consensus_last_blockfetch_batch_unix.load(.acquire);
        const ka_unix = m.consensus_last_keepalive_pong_unix.load(.acquire);
        const now_u: u64 = @intCast(now);
        bf_age = if (bf_unix > 0 and now_u > bf_unix) now_u - bf_unix else 0;
        ka_age = if (ka_unix > 0 and now_u > ka_unix) now_u - ka_unix else 0;

        // Stall reason (deterministic priority)
        if (stalled) {
            const hsw_unix = m.consensus_last_header_store_write_unix.load(.acquire);
            const hsw_age = if (hsw_unix > 0 and now_u > hsw_unix) now_u - hsw_unix else 0;
            const auth_conf = m.authority_confidence_x1e6.load(.acquire);
            const gate = m.authority_gate_active.load(.acquire);

            reason_code = if (ka_age >= 90)
                1 // keepalive_dead
            else if (bf_age >= 30)
                2 // blockfetch_starved
            else if (hsw_age >= 60)
                3 // header_store_stalled
            else if (gate == 0 and auth_conf < 800_000)
                4 // authority_instable
            else
                9; // unknown
        }

        m.consensus_stall_reason_code.store(reason_code, .release);
        m.consensus_stall_age_seconds.store(stall_age, .release);
        m.consensus_blockfetch_age_seconds.store(bf_age, .release);
        m.consensus_keepalive_age_seconds.store(ka_age, .release);
    }

    if (!stalled) return;

    // Rate-limited stall attribution log (60s)
    if (now - ctx.last_stall_attrib_log_unix >= 60) {
        ctx.last_stall_attrib_log_unix = now;
        var auth_conf_val: u64 = 1_000_000;
        if (ctx.metrics) |ma| {
            const m2 = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
            auth_conf_val = m2.authority_confidence_x1e6.load(.acquire);
        }
        std.debug.print("STALL ATTRIB: active=1 age={d}s reason={d} blockfetch_age={d}s keepalive_age={d}s authority_conf={d}.{d:0>6}\n", .{
            stall_age, reason_code, bf_age, ka_age,
            auth_conf_val / 1_000_000, auth_conf_val % 1_000_000,
        });
    }

    // Transition false→true: count stall event
    if (!ctx.stall_active) {
        ctx.stall_active = true;
        if (ctx.metrics) |ma| {
            const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
            _ = m.peer_stall_detect_total.fetchAdd(1, .acq_rel);
            _ = m.consensus_stall_total.fetchAdd(1, .acq_rel);
        }
    }

    // Check if we have a recent integrity-ok probe with a better tip
    if (!ctx.probe_result_integrity_ok.load(.acquire)) return;

    const best_slot = ctx.probe_result_slot.load(.acquire);
    const best_block = ctx.probe_result_block.load(.acquire);
    const best_idx = ctx.probe_result_peer_idx.load(.acquire);

    const probe_ahead = best_slot > ctx.cursor.slot or best_block > ctx.cursor.block_no;
    if (!probe_ahead) return;

    // Cooldown: don't switch more than once per 5 min due to stall
    if (now - ctx.last_stall_switch_unix < STALL_SWITCH_MIN_COOLDOWN) return;
    // Also respect chain select cooldown
    if (now - ctx.last_chain_select_switch_unix < CHAIN_SELECT_COOLDOWN_S) return;

    const slot_delta = if (best_slot > ctx.cursor.slot) best_slot - ctx.cursor.slot else 0;
    std.debug.print(
        "STALL SWITCH: current idx={d} -> best idx={d} (probe slot delta={d})\n",
        .{ current_relay_idx.*, best_idx, slot_delta },
    );

    _ = penalizePeerRateLimited(score, current_relay_idx.*, 0.2, .other, now, ctx.metrics);
    rewardPeer(score, best_idx, 0.1);
    ctx.preferred_peer_idx = best_idx;
    peer_was_closed.* = true;
    ctx.last_stall_switch_unix = now;
    ctx.last_chain_select_switch_unix = now;
    ctx.stall_active = false;

    if (ctx.metrics) |ma| {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
        _ = m.probe_switch_due_to_stall_total.fetchAdd(1, .acq_rel);
        _ = m.chain_select_switch_total.fetchAdd(1, .acq_rel);
        m.chain_select_last_reason_code.store(3, .release); // stall_recovery
        _ = m.baey_switches_total.fetchAdd(1, .acq_rel);
        m.baey_last_switch_reason_code.store(3, .release);
        m.baey_last_switch_unix.store(@intCast(now), .release);
    }

    // BAEY audit
    if (now - ctx.baey_last_stall_unix >= 60) {
        ctx.baey_last_stall_unix = now;
        baeyLog(ctx, "stall_recovery", "no_forward_progress", "reconnect", ctx.cursor.slot, ctx.cursor.block_no);
    }
}

fn maybeUpdateAutoStrict(ctx: *Context) void {
    const now = compat.timestamp();
    if (now - ctx.last_auto_strict_check_unix < 30) return;
    ctx.last_auto_strict_check_unix = now;

    const ma = ctx.metrics orelse return;
    const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));

    const ratio_x1e6 = m.ledger_value_check_ratio_x1e6.load(.acquire);
    const missing_ema = m.ledger_missing_inputs_ema.load(.acquire);
    const ratio_f: f64 = @as(f64, @floatFromInt(ratio_x1e6)) / 1_000_000.0;

    const can_log = (now - ctx.last_auto_strict_log_unix >= 60);

    if (!ctx.auto_strict_enabled) {
        // Enable when ratio >= 0.80 AND missing_ema <= 1
        if (ratio_f >= 0.80 and missing_ema <= 1) {
            ctx.auto_strict_enabled = true;
            _ = m.ledger_auto_strict_toggle_total.fetchAdd(1, .acq_rel);
            m.ledger_auto_strict_enabled.store(1, .release);
            if (can_log) {
                ctx.last_auto_strict_log_unix = now;
                std.debug.print("AUTO-STRICT: enabled (ratio={d:.4} missing_ema={d})\n", .{ ratio_f, missing_ema });
            }
        }
    } else {
        // Disable when ratio <= 0.50 OR missing_ema >= 3
        if (ratio_f <= 0.50 or missing_ema >= 3) {
            ctx.auto_strict_enabled = false;
            _ = m.ledger_auto_strict_toggle_total.fetchAdd(1, .acq_rel);
            m.ledger_auto_strict_enabled.store(0, .release);
            if (can_log) {
                ctx.last_auto_strict_log_unix = now;
                std.debug.print("AUTO-STRICT: disabled (ratio={d:.4} missing_ema={d})\n", .{ ratio_f, missing_ema });
            }
        }
    }
}

/// Validate ledger invariants on deltas before applying them.
/// Returns true if validation passed (or non-strict mode with warnings only).
/// Returns false if strict mode and a hard violation occurred (caller should skip apply).
fn validateDeltasInvariant(
    ctx: *Context,
    alloc: std.mem.Allocator,
    deltas: tx_decode.TxDeltas,
    tip_slot: u64,
    tip_block: u64,
) bool {
    const strict = strictStillActive(ctx) or ctx.auto_strict_enabled;
    const now_lv = compat.timestamp();
    const can_log = (now_lv - ctx.last_ledger_violation_log_unix >= 60);

    // 1) Duplicate consumed inputs within this block
    if (deltas.consumed.len > 1) {
        // Use a hash map keyed on (tx_hash ++ index_le) = 36 bytes
        var seen = std.AutoHashMap([36]u8, void).init(alloc);
        defer seen.deinit();

        var dup_found = false;
        for (deltas.consumed) |con| {
            var key: [36]u8 = undefined;
            @memcpy(key[0..32], con.tx_hash[0..32]);
            std.mem.writeInt(u32, key[32..36], con.index, .little);

            if (seen.contains(key)) {
                dup_found = true;
                break;
            }
            seen.put(key, {}) catch {};
        }

        if (dup_found) {
            if (ctx.metrics) |ma| {
                const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                _ = m.ledger_dup_input_total.fetchAdd(1, .acq_rel);
                _ = m.ledger_violation_total.fetchAdd(1, .acq_rel);
            }
            if (can_log) {
                ctx.last_ledger_violation_log_unix = now_lv;
                std.debug.print("LEDGER VIOLATION: duplicate consumed input (block_no={d} slot={d})\n", .{ tip_block, tip_slot });
            }
            if (strict) return false;
        }
    }

    // 2) Missing consumed inputs in LMDB (only when LMDB is available)
    if (ctx.lmdb) |*store| {
        if (store.beginRead()) |rtxn0| {
            var rtxn = rtxn0;
            defer store.abort(&rtxn);

            var missing_count: u64 = 0;
            var gap_sampled: u64 = 0;
            for (deltas.consumed) |con| {
                if (store.getTxn(&rtxn, con.tx_hash, con.index) == null) {
                    missing_count += 1;
                    // Gap hunter: sample missing keys into tracking map
                    if (gap_sampled < MAX_SAMPLE_PER_BLOCK) {
                        if (gapTrackKey(ctx, con.tx_hash, con.index)) {
                            gap_sampled += 1;
                        }
                    }
                }
            }

            if (missing_count > 0) {
                if (ctx.metrics) |ma| {
                    const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                    _ = m.ledger_missing_input_total.fetchAdd(missing_count, .acq_rel);
                    _ = m.ledger_violation_total.fetchAdd(1, .acq_rel);
                }
                if (can_log) {
                    ctx.last_ledger_violation_log_unix = now_lv;
                    std.debug.print("LEDGER VIOLATION: missing inputs in LMDB count={d} (block_no={d} slot={d})\n", .{ missing_count, tip_block, tip_slot });
                }
                if (strict) return false;
            }

            // Update missing input trend (always, even when count=0)
            ctx.ledger_missing_inputs_last = missing_count;
            const alpha: f64 = 0.1;
            ctx.ledger_missing_inputs_ema =
                (alpha * @as(f64, @floatFromInt(missing_count))) +
                ((1.0 - alpha) * ctx.ledger_missing_inputs_ema);
            if (ctx.metrics) |ma| {
                const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                m.ledger_missing_inputs_last.store(missing_count, .monotonic);
                const ema_u64 = @as(u64, @intFromFloat(
                    if (ctx.ledger_missing_inputs_ema < 0.0) 0.0 else ctx.ledger_missing_inputs_ema,
                ));
                m.ledger_missing_inputs_ema.store(ema_u64, .monotonic);
            }

            // Gap hunter: update metrics, window counters, persist
            if (missing_count > 0) {
                if (ctx.metrics) |ma| {
                    const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                    _ = m.gap_missing_events_total.fetchAdd(1, .acq_rel);
                    if (ctx.missing_inputs_map) |map| {
                        m.gap_missing_keys.store(@intCast(map.count()), .release);
                    }
                    if (ctx.missing_inputs_last_seen) |ls| {
                        m.gap_last_seen_items.store(@intCast(ls.count()), .release);
                    }
                }
                // Window counters for repeat ratio + v4 trend
                const now_gap = compat.timestamp();
                if (ctx.gap_window_start_unix == 0) {
                    ctx.gap_window_start_unix = now_gap;
                    ctx.gap_window_keys_start = if (ctx.missing_inputs_map) |mm| mm.count() else 0;
                    if (ctx.metrics) |ma| {
                        const m2 = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                        ctx.gap_window_resolved_start = m2.gap_resolved_total.load(.acquire);
                    }
                }
                if (now_gap - ctx.gap_window_start_unix >= GAP_WINDOW_SECONDS) {
                    // v4: compute and publish 5-minute deltas before reset
                    const keys_end: u64 = if (ctx.missing_inputs_map) |mm| mm.count() else 0;
                    const delta_keys: i64 = @as(i64, @intCast(keys_end)) - @as(i64, @intCast(ctx.gap_window_keys_start));
                    const capped_now: u64 = if (ctx.missing_inputs_map) |mm| (if (mm.count() >= MAX_GAP_KEYS) @as(u64, 1) else @as(u64, 0)) else 0;
                    if (ctx.metrics) |ma| {
                        const m2 = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                        const resolved_now = m2.gap_resolved_total.load(.acquire);
                        const delta_resolved = if (resolved_now >= ctx.gap_window_resolved_start) resolved_now - ctx.gap_window_resolved_start else 0;
                        const GAP_DELTA_OFFSET: u64 = 10_000_000;
                        m2.gap_keys_delta_5m.store(@intCast(@as(i64, @intCast(GAP_DELTA_OFFSET)) + delta_keys), .release);
                        m2.gap_new_keys_5m.store(ctx.gap_window_new_keys, .release);
                        m2.gap_resolved_5m.store(delta_resolved, .release);
                        m2.gap_evictions_5m.store(ctx.gap_window_evictions, .release);
                        m2.gap_missing_events_5m.store(ctx.gap_window_missing_events, .release);
                        m2.gap_hot_changes_5m.store(ctx.gap_hot_changes_5min, .release);
                        m2.gap_window_unix.store(@intCast(@max(now_gap, 0)), .release);
                        // Win rate: resolved / max(1, new_keys) * 1e6
                        const win_denom = @max(ctx.gap_window_new_keys, 1);
                        m2.gap_win_rate_x1e6.store((delta_resolved * 1_000_000) / win_denom, .release);
                        // Update start snapshots
                        ctx.gap_window_keys_start = keys_end;
                        ctx.gap_window_resolved_start = resolved_now;
                    }
                    // Log once per window
                    const repeat_pct = if (ctx.gap_window_missing_events > 0)
                        ((ctx.gap_window_missing_events - @min(ctx.gap_window_new_keys, ctx.gap_window_missing_events)) * 100) / ctx.gap_window_missing_events
                    else
                        @as(u64, 0);
                    std.debug.print("GAPS 5MIN: keys={d} delta={d} evict_delta={d} hot_changes={d} repeat={d}% capped={d}\n", .{
                        keys_end, delta_keys, ctx.gap_window_evictions, ctx.gap_hot_changes_5min, repeat_pct, capped_now,
                    });
                    // Reset window
                    ctx.gap_window_start_unix = now_gap;
                    ctx.gap_window_missing_events = 0;
                    ctx.gap_window_new_keys = 0;
                    ctx.gap_window_evictions = 0;
                    ctx.gap_hot_changes_5min = 0;
                }
                ctx.gap_window_missing_events += missing_count;
                ctx.gap_window_new_keys += gap_sampled;
                // Compute repeat_ratio = 1 - (new_keys / max(1, missing_events))
                const denom = @max(ctx.gap_window_missing_events, 1);
                const ratio_x1e6: u64 = if (ctx.gap_window_new_keys >= denom)
                    0
                else
                    ((denom - ctx.gap_window_new_keys) * 1_000_000) / denom;
                if (ctx.metrics) |ma| {
                    const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                    m.gap_repeat_ratio_x1e6.store(ratio_x1e6, .release);
                    m.gap_new_keys_window.store(ctx.gap_window_new_keys, .release);
                    m.gap_missing_events_window.store(ctx.gap_window_missing_events, .release);
                    // v3 eviction metrics
                    m.gap_evictions_total.store(ctx.gap_evictions_total, .release);
                    m.gap_keys_cap.store(MAX_GAP_KEYS, .release);
                    const capped_val: u64 = if (ctx.missing_inputs_map) |mm| (if (mm.count() >= MAX_GAP_KEYS) @as(u64, 1) else @as(u64, 0)) else 0;
                    m.gap_capped.store(capped_val, .release);
                    // v4: window age
                    const age_secs: u64 = if (now_gap > ctx.gap_window_start_unix) @intCast(now_gap - ctx.gap_window_start_unix) else 0;
                    m.gap_window_age_seconds.store(age_secs, .release);
                    // Compute oldest last_seen age
                    if (ctx.missing_inputs_last_seen) |ls| {
                        if (ls.count() > 0) {
                            var oldest_ts: u64 = std.math.maxInt(u64);
                            var ls_iter = ls.iterator();
                            while (ls_iter.next()) |entry| {
                                if (entry.value_ptr.* < oldest_ts) oldest_ts = entry.value_ptr.*;
                            }
                            const now_v3: u64 = @intCast(compat.timestamp());
                            const age_oldest = if (now_v3 >= oldest_ts) now_v3 - oldest_ts else 0;
                            m.gap_oldest_last_seen_age_seconds.store(age_oldest, .release);
                        } else {
                            m.gap_oldest_last_seen_age_seconds.store(0, .release);
                        }
                    }
                }
            }
            if (ctx.missing_inputs_map != null) {
                const now_gap = compat.timestamp();
                if (now_gap - ctx.last_gap_persist_unix >= 60) {
                    ctx.last_gap_persist_unix = now_gap;
                    persistGapKeys(ctx);
                    computeAndPersistTopK(ctx);
                }
                if (now_gap - ctx.last_first_seen_persist_unix >= 300) {
                    ctx.last_first_seen_persist_unix = now_gap;
                    persistFirstSeen(ctx);
                }
                if (now_gap - ctx.last_last_seen_persist_unix >= 300) {
                    ctx.last_last_seen_persist_unix = now_gap;
                    persistLastSeen(ctx);
                    const ls_count: u64 = if (ctx.missing_inputs_last_seen) |ls| ls.count() else 0;
                    std.debug.print("GAPS: last_seen persisted keys={d}\n", .{ls_count});
                    if (ctx.metrics) |ma| {
                        const m3 = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                        m3.gap_last_seen_persist_unix.store(@intCast(@max(now_gap, 0)), .release);
                        m3.gap_last_seen_items.store(ls_count, .release);
                    }
                }
                if (gap_sampled > 0 and now_gap - ctx.last_gap_log_unix >= 10) {
                    ctx.last_gap_log_unix = now_gap;
                    const keys_count: u64 = if (ctx.missing_inputs_map) |m| @intCast(m.count()) else 0;
                    appendGapLog(ctx, tip_slot, tip_block, missing_count, gap_sampled, keys_count);
                }
            }
        }
    }

    // 3) Overflow check on delta counts (u64 arithmetic)
    {
        const consumed_len: u64 = @intCast(deltas.consumed.len);
        const produced_len: u64 = @intCast(deltas.produced.len);
        const total = std.math.add(u64, consumed_len, produced_len) catch {
            if (ctx.metrics) |ma| {
                const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                _ = m.ledger_overflow_total.fetchAdd(1, .acq_rel);
                _ = m.ledger_violation_total.fetchAdd(1, .acq_rel);
            }
            if (can_log) {
                ctx.last_ledger_violation_log_unix = now_lv;
                std.debug.print("LEDGER VIOLATION: overflow in delta counts (block_no={d} slot={d})\n", .{ tip_block, tip_slot });
            }
            if (strict) return false;
            return true;
        };
        _ = total;
    }

    // 4) Value conservation: sum_in >= sum_out (only when all inputs resolvable)
    if (ctx.lmdb) |*store| {
        if (deltas.consumed.len > 0) {
            if (store.beginRead()) |rtxn0| {
                var rtxn = rtxn0;
                defer store.abort(&rtxn);

                var sum_in: u128 = 0;
                var all_resolved = true;
                var decode_fail = false;

                for (deltas.consumed) |con| {
                    const raw = store.getTxn(&rtxn, con.tx_hash, con.index) orelse {
                        all_resolved = false;
                        break;
                    };
                    // Lovelace is first 8 bytes (u64 LE) of encoded TxOut
                    if (raw.len < 8) {
                        decode_fail = true;
                        all_resolved = false;
                        break;
                    }
                    const lovelace = std.mem.readInt(u64, raw[0..8], .little);
                    sum_in += @as(u128, lovelace);
                }

                if (!all_resolved) {
                    // Missing or malformed inputs — skip value check
                    if (ctx.metrics) |ma| {
                        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                        _ = m.ledger_value_checks_skipped_total.fetchAdd(1, .acq_rel);
                        if (decode_fail) {
                            _ = m.ledger_input_decode_fail_total.fetchAdd(1, .acq_rel);
                        }
                    }
                } else {
                    // All resolved — execute value check, count as checked
                    if (ctx.metrics) |ma| {
                        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                        _ = m.ledger_value_checks_total.fetchAdd(1, .acq_rel);
                    }

                    var sum_out: u128 = 0;
                    for (deltas.produced) |p| {
                        sum_out += @as(u128, p.output.lovelace);
                    }

                    // Update gauges (saturate u128 → u64)
                    const sat_in: u64 = if (sum_in > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(sum_in);
                    const sat_out: u64 = if (sum_out > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(sum_out);
                    const fee_est: u128 = if (sum_in >= sum_out) sum_in - sum_out else 0;
                    const sat_fee: u64 = if (fee_est > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(fee_est);

                    // Anomaly band analysis (produced outputs)
                    var dust_count: u64 = 0;
                    var max_out_lovelace: u64 = 0;
                    const produced_count: u64 = @intCast(deltas.produced.len);
                    for (deltas.produced) |pd| {
                        if (pd.output.lovelace <= DUST_THRESHOLD_LOVELACE) dust_count += 1;
                        if (pd.output.lovelace > max_out_lovelace) max_out_lovelace = pd.output.lovelace;
                    }
                    const dust_denom = if (produced_count > 0) produced_count else 1;
                    const dust_ratio_x1e6: u64 = (dust_count * 1_000_000) / dust_denom;

                    if (ctx.metrics) |ma| {
                        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                        m.ledger_sum_in_lovelace_last.store(sat_in, .release);
                        m.ledger_sum_out_lovelace_last.store(sat_out, .release);
                        m.ledger_fee_est_lovelace_last.store(sat_fee, .release);
                        m.ledger_dust_ratio_last_x1e6.store(dust_ratio_x1e6, .release);
                        m.ledger_dust_count_last.store(dust_count, .release);
                        m.ledger_max_out_lovelace_last.store(max_out_lovelace, .release);
                    }

                    // Anomaly checks (warn-only default, strict opt-in)
                    {
                        const anomaly_strict = ledgerAnomalyStrictEnabled();
                        const anomaly_can_log = (now_lv - ctx.last_anomaly_log_unix >= 60);
                        var any_anomaly = false;

                        // 1) Fee upper bound
                        if (sat_fee > MAX_FEE_EST_LOVELACE) {
                            any_anomaly = true;
                            if (ctx.metrics) |ma| {
                                const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                                _ = m.ledger_anomaly_fee_total.fetchAdd(1, .acq_rel);
                            }
                        }

                        // 2) Dust storm
                        if (produced_count >= DUST_MIN_OUTPUTS and dust_ratio_x1e6 >= DUST_RATIO_X1E6) {
                            any_anomaly = true;
                            if (ctx.metrics) |ma| {
                                const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                                _ = m.ledger_anomaly_dust_total.fetchAdd(1, .acq_rel);
                            }
                        }

                        // 3) Whale output
                        if (max_out_lovelace >= WHALE_OUT_LOVELACE) {
                            any_anomaly = true;
                            if (ctx.metrics) |ma| {
                                const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                                _ = m.ledger_anomaly_whale_total.fetchAdd(1, .acq_rel);
                            }
                        }

                        if (any_anomaly) {
                            if (ctx.metrics) |ma| {
                                const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                                _ = m.ledger_anomaly_total.fetchAdd(1, .acq_rel);
                            }
                            if (anomaly_can_log) {
                                ctx.last_anomaly_log_unix = now_lv;
                                const strict_u: u64 = if (anomaly_strict) 1 else 0;
                                const dr_int = dust_ratio_x1e6 / 1_000_000;
                                const dr_frac = dust_ratio_x1e6 % 1_000_000;
                                std.debug.print("LEDGER ANOMALY: fee={d} dust={d}/{d} ratio={d}.{d:0>6} max_out={d} strict={d} block={d} slot={d}\n", .{ sat_fee, dust_count, produced_count, dr_int, dr_frac, max_out_lovelace, strict_u, tip_block, tip_slot });
                            }
                            if (anomaly_strict) {
                                if (ctx.metrics) |ma| {
                                    const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                                    _ = m.ledger_anomaly_strict_disconnect_total.fetchAdd(1, .acq_rel);
                                }
                                return false;
                            }
                        }
                    }

                    if (sum_out > sum_in) {
                        if (ctx.metrics) |ma| {
                            const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                            _ = m.ledger_value_violation_total.fetchAdd(1, .acq_rel);
                            _ = m.ledger_violation_total.fetchAdd(1, .acq_rel);
                        }
                        if (can_log) {
                            ctx.last_ledger_violation_log_unix = now_lv;
                            std.debug.print("LEDGER VIOLATION: value conservation failed sum_in={d} sum_out={d} (block_no={d} slot={d})\n", .{ sat_in, sat_out, tip_block, tip_slot });
                        }
                        if (strict) return false;
                    }
                }

                // Update coverage ratio gauge after each increment
                if (ctx.metrics) |ma| {
                    const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                    const ck = m.ledger_value_checks_total.load(.acquire);
                    const sk = m.ledger_value_checks_skipped_total.load(.acquire);
                    const tot = ck + sk;
                    const rx1e6: u64 = if (tot == 0) 0 else (ck * 1_000_000) / tot;
                    m.ledger_value_check_ratio_x1e6.store(rx1e6, .release);
                }
            }
        }
    }

    return true;
}

// ── BAEY audit log ──────────────────────────────────────────────────

fn getBaeyDir(ctx: *Context) ?[]const u8 {
    if (ctx.baey_dir) |d| return d;
    const home = compat.getEnvVarOwned(std.heap.page_allocator, "TSUNAGI_HOME") catch return null;
    const dir = std.fmt.allocPrint(std.heap.page_allocator, "{s}/baey", .{home}) catch {
        std.heap.page_allocator.free(home);
        return null;
    };
    std.heap.page_allocator.free(home);
    compat.fs.cwd().makePath(dir) catch {};
    ctx.baey_dir = dir;
    return dir;
}

fn maybeConsumeBaeySwitchMarker(
    ctx: *Context,
    score: *PeerScore,
    current_relay_idx: *usize,
    peer_was_closed: *bool,
) void {
    const dir = getBaeyDir(ctx) orelse return;
    const alloc = std.heap.page_allocator;
    const path = std.fmt.allocPrint(alloc, "{s}/switch_peer.json", .{dir}) catch return;
    defer alloc.free(path);

    // Try to read the marker file
    var f = compat.fs.cwd().openFile(path, .{}) catch return;
    const data = f.deprecatedReader().readAllAlloc(alloc, 4096) catch {
        f.close();
        return;
    };
    f.close();
    defer alloc.free(data);

    // Delete the marker immediately (consume once)
    compat.fs.cwd().deleteFile(path) catch {};

    // Pick a different peer via normal scoring
    const old_idx = current_relay_idx.*;
    const new_idx = pickRelay(score, ctx.metrics);
    if (new_idx != old_idx) {
        current_relay_idx.* = new_idx;
        ctx.preferred_peer_idx = new_idx;
        peer_was_closed.* = true;
        baeyLog(ctx, "baey_switch_peer", "switch_peer_marker", "reconnect", ctx.cursor.slot, ctx.cursor.block_no);
        std.debug.print("BAEY: switch_peer marker consumed, switching {d} -> {d}\n", .{ old_idx, new_idx });
    } else {
        baeyLog(ctx, "baey_switch_peer", "switch_peer_marker", "no_better_peer", ctx.cursor.slot, ctx.cursor.block_no);
        std.debug.print("BAEY: switch_peer marker consumed, no better peer found\n", .{});
    }
}

fn baeyLog(
    ctx: *Context,
    kind: []const u8,
    reason: []const u8,
    action: []const u8,
    slot: u64,
    block: u64,
) void {
    const dir = getBaeyDir(ctx) orelse return;
    const now = compat.timestamp();

    const log_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/events.log", .{dir}) catch return;
    defer std.heap.page_allocator.free(log_path);

    var file = compat.fs.cwd().openFile(log_path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => compat.fs.cwd().createFile(log_path, .{}) catch return,
        else => return,
    };
    defer file.close();
    file.seekFromEnd(0) catch return;

    // Gather snapshot metrics
    var truth_buf: [24]u8 = undefined;
    var ema_buf: [24]u8 = undefined;
    var density_buf: [24]u8 = undefined;
    const truth_str: []const u8 = if (ctx.metrics) |ma| blk: {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
        const ltb = m.lmdb_truth_blocks.load(.acquire);
        const lfb = m.lmdb_fallback_blocks.load(.acquire);
        const denom = ltb + lfb;
        const r = if (denom > 0) (ltb * 1_000_000) / denom else 0;
        break :blk std.fmt.bufPrint(&truth_buf, "{d}.{d:0>6}", .{ r / 1_000_000, r % 1_000_000 }) catch "0";
    } else "0";
    const ema_str: []const u8 = if (ctx.metrics) |ma| blk: {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
        const v = m.ledger_missing_inputs_ema.load(.acquire);
        break :blk std.fmt.bufPrint(&ema_buf, "{d}", .{v}) catch "0";
    } else "0";
    const density_str: []const u8 = if (ctx.metrics) |ma| blk: {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
        const v = m.chain_density_smoothed_last_x1e6.load(.acquire);
        break :blk std.fmt.bufPrint(&density_buf, "{d}.{d:0>6}", .{ v / 1_000_000, v % 1_000_000 }) catch "0";
    } else "0";

    file.deprecatedWriter().print(
        \\{{"unix":{d},"kind":"{x}","reason":"{x}","action":"{x}","slot":{d},"block":{d},"metrics":{{"truth_ratio":"{x}","missing_ema":"{x}","density":"{x}"}}}}
        \\
    , .{ now, kind, reason, action, slot, block, truth_str, ema_str, density_str }) catch return;

    // Update metrics
    if (ctx.metrics) |ma| {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
        _ = m.baey_events_total.fetchAdd(1, .acq_rel);
        m.baey_last_event_unix.store(@intCast(now), .release);
    }
}

fn baeyLogEligEvent(ctx: *Context, slot: u64, block: u64) void {
    const dir = getBaeyDir(ctx) orelse return;
    const now = compat.timestamp();

    const log_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/events.log", .{dir}) catch return;
    defer std.heap.page_allocator.free(log_path);

    var file = compat.fs.cwd().openFile(log_path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => compat.fs.cwd().createFile(log_path, .{}) catch return,
        else => return,
    };
    defer file.close();
    file.seekFromEnd(0) catch return;

    // Pool id prefix (first 16 hex chars)
    const pool_prefix: []const u8 = if (ctx.producer_ctx.key_cfg.pool_id_hex) |pid|
        pid[0..@min(pid.len, 16)]
    else
        "n/a";

    file.deprecatedWriter().print(
        \\{{"unix":{d},"kind":"producer_elig_test_eligible","slot":{d},"block":{d},"epoch_last":{d},"slot_in_epoch":{d},"target_slot_in_epoch":{d},"window_s":{d},"prob_x1e6":{d},"stake_fraction_x1e9":{d},"pool_id_prefix":"{x}"}}
        \\
    , .{
        now,
        slot,
        block,
        ctx.producer_ctx.epoch_last,
        ctx.producer_ctx.slot_in_epoch_last,
        ctx.producer_ctx.elig_test_slot_in_epoch,
        ctx.producer_ctx.elig_test_window_s,
        ctx.producer_ctx.leader_probability_x1e6,
        ctx.producer_ctx.stake_cfg.stake_fraction_x1e9,
        pool_prefix,
    }) catch return;

    // Update BAEY metrics
    if (ctx.metrics) |ma| {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
        _ = m.baey_events_total.fetchAdd(1, .acq_rel);
        m.baey_last_event_unix.store(@intCast(now), .release);
    }
}

fn baeyLogProducerProof(ctx: *Context, slot: u64, block: u64) void {
    const dir = getBaeyDir(ctx) orelse return;
    const now = compat.timestamp();

    const log_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/events.log", .{dir}) catch return;
    defer std.heap.page_allocator.free(log_path);

    var file = compat.fs.cwd().openFile(log_path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => compat.fs.cwd().createFile(log_path, .{}) catch return,
        else => return,
    };
    defer file.close();
    file.seekFromEnd(0) catch return;

    const pc = &ctx.producer_ctx;
    const w = file.deprecatedWriter();

    // Pool id prefix (first 16 hex chars)
    const pool_prefix: []const u8 = if (pc.key_cfg.pool_id_hex) |pid|
        pid[0..@min(pid.len, 16)]
    else
        "n/a";

    // State digest hex from producer_ctx.state_digest[32]
    const hex_chars = "0123456789abcdef";
    var sd_hex: [64]u8 = undefined;
    for (0..32) |bi| {
        sd_hex[bi * 2] = hex_chars[pc.state_digest[bi] >> 4];
        sd_hex[bi * 2 + 1] = hex_chars[pc.state_digest[bi] & 0xf];
    }

    // Candidate hdr_hash_prefix_hex (16 chars from w0)
    var hdr_hex: [16]u8 = undefined;
    var hdr_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &hdr_bytes, pc.candidate_hdr_hash_w0, .big);
    for (0..8) |hi| {
        hdr_hex[hi * 2] = hex_chars[hdr_bytes[hi] >> 4];
        hdr_hex[hi * 2 + 1] = hex_chars[hdr_bytes[hi] & 0xf];
    }

    // KES sign label
    const kes_sign_label: []const u8 = if (pc.kes_sign_label_last == 1) "KES_PLACEHOLDER_ED25519" else "n/a";

    // Write the proof bundle as a single JSON line
    w.print(
        \\{{"unix":{d},"kind":"producer_proof","slot":{d},"block":{d},"epoch_last":{d},"slot_in_epoch_last":{d}
    , .{ now, slot, block, pc.epoch_last, pc.slot_in_epoch_last }) catch return;

    // Eligibility test context
    w.print(
        \\,"elig_test":{{"enabled":{d},"window_s":{d},"target":{d},"target_end":{d},"override_enabled":{d},"override_target":{d}}}
    , .{
        @as(u64, if (pc.elig_test_enabled) 1 else 0),
        pc.elig_test_window_s,
        pc.elig_test_slot_in_epoch,
        pc.elig_test_target_end,
        @as(u64, if (pc.elig_test_override_enabled) 1 else 0),
        pc.elig_test_override_target,
    }) catch return;

    // Candidate v2
    w.print(
        \\,"candidate":{{"hdr_bytes_len":{d},"hdr_hash_w0":{d},"hdr_hash_w1":{d},"hdr_hash_prefix_hex":"{x}","body_hash_prefix":{d},"sig_present_last":{d},"signed_total":{d}}}
    , .{
        pc.candidate_hdr_bytes_len,
        pc.candidate_hdr_hash_w0,
        pc.candidate_hdr_hash_w1,
        &hdr_hex,
        pc.candidate_body_hash_prefix_last,
        @as(u64, pc.candidate_sig_present_last),
        pc.candidate_signed_total,
    }) catch return;

    // State digest
    w.print(
        \\,"state_digest_hex":"{x}"
    , .{&sd_hex}) catch return;

    // Producer keys status
    w.print(
        \\,"producer_keys":{{"enabled":{d},"parse_ok":{d},"validate_total":{d},"err_code":{d},"pool_ok":{d},"kes_ok":{d},"vrf_ok":{d},"perms_ok":{d},"readable_ok":{d},"pool_id_prefix":"{x}"}}
    , .{
        @as(u64, if (pc.key_cfg.enabled) 1 else 0),
        @as(u64, if (pc.key_cfg.parse_ok) 1 else 0),
        pc.key_validate_total,
        @as(u64, pc.key_err_code_last),
        @as(u64, pc.pool_ok_last),
        @as(u64, pc.kes_ok_last),
        @as(u64, pc.vrf_ok_last),
        @as(u64, pc.perms_ok_last),
        @as(u64, pc.readable_ok_last),
        pool_prefix,
    }) catch return;

    // VRF status
    w.print(
        \\,"vrf":{{"enabled":{d},"parse_ok":{d},"attempt_total":{d},"checked_total":{d},"checked_last":{d},"probability_x1e6":{d},"proof_present":{d},"output_present":{d},"reason_code":{d},"output_prefix_last":{d},"tick_mode":{d},"last_checked_slot":{d},"skipped_total":{d}}}
    , .{
        @as(u64, if (pc.vrf_cfg.enabled) 1 else 0),
        @as(u64, if (pc.vrf_cfg.parse_ok) 1 else 0),
        pc.vrf_attempt_total,
        pc.vrf_checked_total,
        @as(u64, if (pc.vrf_checked_last) 1 else 0),
        pc.vrf_probability_x1e6_last,
        @as(u64, if (pc.vrf_proof_present_last) 1 else 0),
        @as(u64, if (pc.vrf_output_present_last) 1 else 0),
        @as(u64, pc.vrf_reason_code_last),
        pc.vrf_output_prefix_last,
        @as(u64, pc.vrf_tick_mode),
        pc.last_vrf_checked_slot,
        pc.vrf_skipped_total,
    }) catch return;

    // KES sign status
    w.print(
        \\,"kes_sign":{{"enabled":{d},"attempt_total":{d},"ok_total":{d},"sig_present_last":{d},"sig_prefix_last":{d},"reason_code_last":{d},"label":"{x}"}}
    , .{
        @as(u64, if (pc.kes_sign_enabled) 1 else 0),
        pc.kes_sign_attempt_total,
        pc.kes_sign_ok_total,
        pc.kes_sign_present_last,
        pc.kes_sign_prefix_last,
        pc.kes_sign_reason_last,
        kes_sign_label,
    }) catch return;

    // Close the JSON object
    w.print(
        \\}}
        \\
    , .{}) catch return;

    // Update metrics
    ctx.last_producer_proof_unix = now;
    if (ctx.metrics) |ma| {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
        _ = m.baey_events_total.fetchAdd(1, .acq_rel);
        m.baey_last_event_unix.store(@intCast(now), .release);
        m.last_producer_proof_unix.store(@as(u64, @intCast(now)), .release);
    }
}

fn persistCandidateArtifacts(ctx: *Context) void {
    const pc = &ctx.producer_ctx;
    if (!pc.candidate_sign_dirty) return;
    pc.candidate_sign_dirty = false;

    const home = compat.getEnvVarOwned(std.heap.page_allocator, "TSUNAGI_HOME") catch return;
    defer std.heap.page_allocator.free(home);

    const dir_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/producer", .{home}) catch return;
    defer std.heap.page_allocator.free(dir_path);

    // Ensure directory exists
    compat.fs.cwd().makePath(dir_path) catch {};

    // Helper: atomic write (write .tmp, rename to final)
    const writeAtomic = struct {
        fn f(dir: []const u8, name: []const u8, data: []const u8) bool {
            const tmp_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}.tmp", .{ dir, name }) catch return false;
            defer std.heap.page_allocator.free(tmp_path);
            const final_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ dir, name }) catch return false;
            defer std.heap.page_allocator.free(final_path);

            // Write tmp
            var file = compat.fs.cwd().createFile(tmp_path, .{}) catch return false;
            file.writeAll(data) catch {
                file.close();
                return false;
            };
            file.close();

            // Rename tmp → final
            compat.fs.cwd().rename(tmp_path, final_path) catch return false;
            return true;
        }
    }.f;

    // Write candidate_hdr_166.bin
    if (!writeAtomic(dir_path, "candidate_hdr_166.bin", &pc.candidate_last_hdr_bytes)) {
        std.debug.print("PRODUCER SIGN: failed to write candidate_hdr_166.bin (reason=6)\n", .{});
        pc.candidate_sign_reason_code_last = 6; // io_fail
        return;
    }

    // Write candidate_sig_64.bin
    if (!writeAtomic(dir_path, "candidate_sig_64.bin", &pc.candidate_last_sig_bytes)) {
        std.debug.print("PRODUCER SIGN: failed to write candidate_sig_64.bin (reason=6)\n", .{});
        pc.candidate_sign_reason_code_last = 6; // io_fail
        return;
    }

    // Build candidate_meta.json
    const hex_chars = "0123456789abcdef";
    var hdr_hex: [16]u8 = undefined;
    var hdr_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &hdr_bytes, pc.candidate_hdr_hash_w0, .big);
    for (0..8) |hi| {
        hdr_hex[hi * 2] = hex_chars[hdr_bytes[hi] >> 4];
        hdr_hex[hi * 2 + 1] = hex_chars[hdr_bytes[hi] & 0xf];
    }
    var sig_hex: [16]u8 = undefined;
    var sig_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &sig_bytes, pc.candidate_sig_prefix_last, .big);
    for (0..8) |si| {
        sig_hex[si * 2] = hex_chars[sig_bytes[si] >> 4];
        sig_hex[si * 2 + 1] = hex_chars[sig_bytes[si] & 0xf];
    }
    var sd_hex: [16]u8 = undefined;
    for (0..8) |bi| {
        sd_hex[bi * 2] = hex_chars[pc.state_digest[bi] >> 4];
        sd_hex[bi * 2 + 1] = hex_chars[pc.state_digest[bi] & 0xf];
    }

    const now = compat.timestamp();
    var meta_buf: [512]u8 = undefined;
    const meta_json = std.fmt.bufPrint(&meta_buf,
        \\{{"unix":{d},"slot":{d},"epoch":{d},"slot_in_epoch":{d},"hdr_hash_prefix_hex":"{x}","sig_prefix_hex":"{x}","state_digest_prefix_hex":"{x}"}}
    , .{
        now,
        pc.candidate_last_slot,
        pc.epoch_last,
        pc.slot_in_epoch_last,
        &hdr_hex,
        &sig_hex,
        &sd_hex,
    }) catch return;

    if (!writeAtomic(dir_path, "candidate_meta.json", meta_json)) {
        std.debug.print("PRODUCER SIGN: failed to write candidate_meta.json (reason=6)\n", .{});
        pc.candidate_sign_reason_code_last = 6; // io_fail
        return;
    }

    std.debug.print("PRODUCER SIGN: wrote candidate_hdr_166.bin + candidate_sig_64.bin slot={d} epoch={d} sie={d}\n", .{
        pc.candidate_last_slot,
        pc.epoch_last,
        pc.slot_in_epoch_last,
    });
}

fn persistVrfArtifacts(ctx: *Context) void {
    const pc = &ctx.producer_ctx;
    if (!pc.vrf_artifact_dirty) return;
    pc.vrf_artifact_dirty = false;

    if (pc.vrf_proof_len_last == 0 or pc.vrf_output_len_last == 0) return;

    const home = compat.getEnvVarOwned(std.heap.page_allocator, "TSUNAGI_HOME") catch return;
    defer std.heap.page_allocator.free(home);

    const dir_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/producer", .{home}) catch return;
    defer std.heap.page_allocator.free(dir_path);

    compat.fs.cwd().makePath(dir_path) catch {};

    const writeAtomic = struct {
        fn f(dir: []const u8, name: []const u8, data: []const u8) bool {
            const tmp_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}.tmp", .{ dir, name }) catch return false;
            defer std.heap.page_allocator.free(tmp_path);
            const final_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ dir, name }) catch return false;
            defer std.heap.page_allocator.free(final_path);
            var file = compat.fs.cwd().createFile(tmp_path, .{}) catch return false;
            file.writeAll(data) catch {
                file.close();
                return false;
            };
            file.close();
            compat.fs.cwd().rename(tmp_path, final_path) catch return false;
            return true;
        }
    }.f;

    const proof_len: usize = @intCast(pc.vrf_proof_len_last);
    const output_len: usize = @intCast(pc.vrf_output_len_last);

    if (!writeAtomic(dir_path, "vrf_proof.bin", pc.vrf_proof_bytes_last[0..proof_len])) {
        std.debug.print("PRODUCER VRF: failed to write vrf_proof.bin\n", .{});
        return;
    }
    if (!writeAtomic(dir_path, "vrf_output.bin", pc.vrf_output_bytes_last[0..output_len])) {
        std.debug.print("PRODUCER VRF: failed to write vrf_output.bin\n", .{});
        return;
    }

    // Write VRF public key (v3 cryptographic closure)
    if (pc.vrf_cfg.pk) |pk| {
        _ = writeAtomic(dir_path, "vrf_pk.bin", &pk);
    }

    // Write KES Ed25519 public key (v3 cryptographic closure)
    if (pc.kes_sign_seed) |seed| {
        const kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch null;
        if (kp) |k| {
            const pub_bytes = k.public_key.toBytes();
            _ = writeAtomic(dir_path, "kes_pk.bin", &pub_bytes);
        }
    }

    // Build vrf_meta.json
    const hex_chars = "0123456789abcdef";
    var proof_hex: [16]u8 = undefined;
    var proof_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &proof_bytes, pc.vrf_proof_prefix_last, .big);
    for (0..8) |pi| {
        proof_hex[pi * 2] = hex_chars[proof_bytes[pi] >> 4];
        proof_hex[pi * 2 + 1] = hex_chars[proof_bytes[pi] & 0xf];
    }
    var output_hex: [16]u8 = undefined;
    var output_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &output_bytes, pc.vrf_output_prefix_last, .big);
    for (0..8) |oi| {
        output_hex[oi * 2] = hex_chars[output_bytes[oi] >> 4];
        output_hex[oi * 2 + 1] = hex_chars[output_bytes[oi] & 0xf];
    }

    const now = compat.timestamp();
    var meta_buf: [512]u8 = undefined;
    const meta_json = std.fmt.bufPrint(&meta_buf,
        \\{{"unix":{d},"slot":{d},"epoch":{d},"slot_in_epoch":{d},"mode":{d},"prob_x1e6":{d},"reason_code":{d},"proof_prefix_hex":"{x}","output_prefix_hex":"{x}"}}
    , .{
        now,
        pc.last_vrf_checked_slot,
        pc.epoch_last,
        pc.slot_in_epoch_last,
        @as(u64, pc.vrf_tick_mode),
        pc.vrf_probability_x1e6_last,
        @as(u64, pc.vrf_reason_code_last),
        &proof_hex,
        &output_hex,
    }) catch return;

    if (!writeAtomic(dir_path, "vrf_meta.json", meta_json)) {
        std.debug.print("PRODUCER VRF: failed to write vrf_meta.json\n", .{});
        return;
    }

    std.debug.print("PRODUCER VRF: wrote vrf_proof.bin + vrf_output.bin slot={d} epoch={d} sie={d}\n", .{
        pc.last_vrf_checked_slot,
        pc.epoch_last,
        pc.slot_in_epoch_last,
    });
}

fn persistCandidateBodyArtifacts(ctx: *Context) void {
    const pc = &ctx.producer_ctx;
    if (!pc.body_artifact_dirty) return;
    pc.body_artifact_dirty = false;

    if (pc.body_cbor_len_last == 0) return;

    const home = compat.getEnvVarOwned(std.heap.page_allocator, "TSUNAGI_HOME") catch return;
    defer std.heap.page_allocator.free(home);

    const dir_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/producer", .{home}) catch return;
    defer std.heap.page_allocator.free(dir_path);

    compat.fs.cwd().makePath(dir_path) catch {};

    const writeAtomic = struct {
        fn f(dir: []const u8, name: []const u8, data: []const u8) bool {
            const tmp_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}.tmp", .{ dir, name }) catch return false;
            defer std.heap.page_allocator.free(tmp_path);
            const final_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ dir, name }) catch return false;
            defer std.heap.page_allocator.free(final_path);
            var file = compat.fs.cwd().createFile(tmp_path, .{}) catch return false;
            file.writeAll(data) catch {
                file.close();
                return false;
            };
            file.close();
            compat.fs.cwd().rename(tmp_path, final_path) catch return false;
            return true;
        }
    }.f;

    const cbor_len: usize = @intCast(pc.body_cbor_len_last);

    if (!writeAtomic(dir_path, "candidate_body.cbor", pc.body_cbor_bytes_last[0..cbor_len])) {
        std.debug.print("PRODUCER BODY: failed to write candidate_body.cbor\n", .{});
        return;
    }

    // Build body_meta.json
    const hex_chars = "0123456789abcdef";
    var hash_hex: [64]u8 = undefined;
    var hash_bytes: [32]u8 = undefined;
    std.mem.writeInt(u64, hash_bytes[0..8], pc.body_hash_w0, .big);
    std.mem.writeInt(u64, hash_bytes[8..16], pc.body_hash_w1, .big);
    std.mem.writeInt(u64, hash_bytes[16..24], pc.body_hash_w2, .big);
    std.mem.writeInt(u64, hash_bytes[24..32], pc.body_hash_w3, .big);
    for (0..32) |bi| {
        hash_hex[bi * 2] = hex_chars[hash_bytes[bi] >> 4];
        hash_hex[bi * 2 + 1] = hex_chars[hash_bytes[bi] & 0xf];
    }

    const now = compat.timestamp();
    var meta_buf: [512]u8 = undefined;
    const meta_json = std.fmt.bufPrint(&meta_buf,
        \\{{"unix":{d},"slot":{d},"epoch":{d},"slot_in_epoch":{d},"cbor_len":{d},"body_hash_hex":"{x}"}}
    , .{
        now,
        pc.candidate_last_slot,
        pc.epoch_last,
        pc.slot_in_epoch_last,
        pc.body_cbor_len_last,
        &hash_hex,
    }) catch return;

    if (!writeAtomic(dir_path, "body_meta.json", meta_json)) {
        std.debug.print("PRODUCER BODY: failed to write body_meta.json\n", .{});
        return;
    }

    std.debug.print("PRODUCER BODY: wrote candidate_body.cbor ({d} bytes) slot={d} epoch={d} sie={d}\n", .{
        pc.body_cbor_len_last,
        pc.candidate_last_slot,
        pc.epoch_last,
        pc.slot_in_epoch_last,
    });
}

fn maybeWriteProducerPack(ctx: *Context) void {
    const pc = &ctx.producer_ctx;
    if (!pc.pack_dirty) return;
    pc.pack_dirty = false;

    // Rate limit: 60s
    const now = compat.timestamp();
    if (pc.pack_last_unix > 0 and now - pc.pack_last_unix < 60) return;

    // Need header + body to be present
    if (pc.candidate_hdr_bytes_len == 0 or pc.body_cbor_len_last == 0) return;

    const home = compat.getEnvVarOwned(std.heap.page_allocator, "TSUNAGI_HOME") catch return;
    defer std.heap.page_allocator.free(home);

    // Build pool_id prefix hex (first 16 hex chars)
    var pool_prefix: [16]u8 = [_]u8{'0'} ** 16;
    if (pc.key_cfg.pool_id_hex) |pid| {
        const copy_len = @min(pid.len, 16);
        @memcpy(pool_prefix[0..copy_len], pid[0..copy_len]);
    }

    // Hex-encode VRF public key (v3)
    const hx = "0123456789abcdef";
    var vrf_pk_hex: [64]u8 = [_]u8{'0'} ** 64;
    var vrf_pk_bin: ?[32]u8 = null;
    if (pc.vrf_cfg.pk) |pk| {
        vrf_pk_bin = pk;
        for (0..32) |i| {
            vrf_pk_hex[i * 2] = hx[pk[i] >> 4];
            vrf_pk_hex[i * 2 + 1] = hx[pk[i] & 0xf];
        }
    }

    // Derive KES Ed25519 public key from seed (v3)
    var kes_pk_hex: [64]u8 = [_]u8{'0'} ** 64;
    var kes_pk_bin: ?[32]u8 = null;
    if (pc.kes_sign_seed) |seed| {
        const kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch null;
        if (kp) |k| {
            const pub_bytes = k.public_key.toBytes();
            kes_pk_bin = pub_bytes;
            for (0..32) |i| {
                kes_pk_hex[i * 2] = hx[pub_bytes[i] >> 4];
                kes_pk_hex[i * 2 + 1] = hx[pub_bytes[i] & 0xf];
            }
        }
    }

    const meta = pack.PackMeta{
        .unix = now,
        .slot = pc.candidate_last_slot,
        .epoch = pc.epoch_last,
        .slot_in_epoch = pc.slot_in_epoch_last,
        .net_magic = pc.genesis_network_magic,
        .tip_block = pc.tip_block_last,
        .hdr_bytes_len = pc.candidate_hdr_bytes_len,
        .hdr_hash_w0 = pc.candidate_hdr_hash_w0,
        .hdr_hash_w1 = pc.candidate_hdr_hash_w1,
        .body_cbor_len = pc.body_cbor_len_last,
        .body_hash_w0 = pc.body_hash_w0,
        .body_hash_w1 = pc.body_hash_w1,
        .body_hash_w2 = pc.body_hash_w2,
        .body_hash_w3 = pc.body_hash_w3,
        .vrf_proof_len = pc.vrf_proof_len_last,
        .vrf_output_len = pc.vrf_output_len_last,
        .vrf_proof_prefix = pc.vrf_proof_prefix_last,
        .vrf_output_prefix = pc.vrf_output_prefix_last,
        .sig_len = if (pc.candidate_sig_present_last == 1) @as(u64, 64) else @as(u64, 0),
        .sig_prefix = pc.candidate_sig_prefix_last,
        .sign_reason = pc.candidate_sign_reason_code_last,
        .pool_id_prefix_hex = pool_prefix,
        // State snapshot (v2)
        .state_genesis_magic = pc.genesis_network_magic,
        .state_genesis_start_unix = pc.genesis_unix,
        .state_genesis_slot_len_s = pc.slot_length_s,
        .state_leader_epoch = pc.epoch_last,
        .state_leader_sie = pc.slot_in_epoch_last,
        .state_leader_prob_x1e6 = pc.leader_probability_x1e6,
        .state_leader_expected = pc.expected_leaders_per_epoch,
        .state_praos_enabled = if (pc.praos_enabled) @as(u64, 1) else 0,
        .state_praos_u_x1e12 = pc.praos_u_x1e12_last,
        .state_praos_thresh_x1e12 = pc.praos_thresh_x1e12_last,
        .state_praos_leader_last = pc.praos_leader_last,
        .state_praos_reason_last = pc.praos_reason_code_last,
        .state_praos_u_lt_t = pc.praos_u_lt_t,
        .state_vrf_enabled = if (pc.vrf_cfg.enabled) @as(u64, 1) else 0,
        .state_vrf_reason_code = pc.vrf_reason_code_last,
        .state_vrf_proof_present = if (pc.vrf_proof_present_last) @as(u64, 1) else 0,
        .state_vrf_output_present = if (pc.vrf_output_present_last) @as(u64, 1) else 0,
        .state_vrf_proof_len = pc.vrf_proof_len_last,
        .state_vrf_output_len = pc.vrf_output_len_last,
        .state_vrf_output_prefix = pc.vrf_output_prefix_last,
        .state_kes_sign_enabled = if (pc.kes_sign_enabled) @as(u64, 1) else 0,
        .state_kes_sign_reason = pc.kes_sign_reason_last,
        .state_kes_sign_ok_total = pc.kes_sign_ok_total,
        .state_kes_sign_present = pc.kes_sign_present_last,
        .state_kes_sign_prefix = pc.kes_sign_prefix_last,
        .state_candidate_hdr_len = pc.candidate_hdr_bytes_len,
        .state_candidate_hdr_hash_prefix = pc.candidate_hdr_hash_w0,
        .state_candidate_body_len = pc.body_cbor_len_last,
        .state_candidate_sig_present = pc.candidate_sig_present_last,
        // KES lifecycle (v1.1.2)
        .state_kes_cur_period = pc.kes_current_period_last,
        .state_kes_valid = pc.kes_period_valid_last,
        .state_kes_reason_code = pc.kes_period_reason_code_last,
        .state_kes_start_period = pc.kes_start_period,
        .state_kes_max_periods = pc.kes_max_periods,
        // Slot scheduler (v1.1.0)
        .state_schedule_window = pc.schedule_window_size,
        .state_schedule_leaders_in_window = pc.schedule_leaders_in_window,
        .state_schedule_next_leader_offset = pc.schedule_next_leader_offset,
        // Producer state digest (v1.2.0)
        .state_producer_digest_hex = blk_digest: {
            const hex_chars = "0123456789abcdef";
            var dhex: [64]u8 = undefined;
            for (0..32) |di| {
                dhex[di * 2] = hex_chars[pc.producer_state_digest[di] >> 4];
                dhex[di * 2 + 1] = hex_chars[pc.producer_state_digest[di] & 0xf];
            }
            break :blk_digest dhex;
        },
        // Cryptographic closure (v3)
        .vrf_pk_hex = vrf_pk_hex,
        .kes_pk_hex = kes_pk_hex,
        .stake_fraction_x1e9 = pc.stake_cfg.stake_fraction_x1e9,
        .asc_x1e6 = pc.stake_cfg.asc_x1e6,
        .vrf_input_epoch = pc.epoch_last,
        .vrf_input_slot = pc.candidate_last_slot,
    };

    const body_cbor_len: usize = @intCast(pc.body_cbor_len_last);
    const vrf_proof: ?[]const u8 = if (pc.vrf_proof_len_last > 0) blk: {
        const len: usize = @intCast(pc.vrf_proof_len_last);
        break :blk pc.vrf_proof_bytes_last[0..len];
    } else null;
    const vrf_output: ?[]const u8 = if (pc.vrf_output_len_last > 0) blk: {
        const len: usize = @intCast(pc.vrf_output_len_last);
        break :blk pc.vrf_output_bytes_last[0..len];
    } else null;
    const sig_bytes: ?[]const u8 = if (pc.candidate_sig_present_last == 1) &pc.candidate_last_sig_bytes else null;

    const result = pack.buildPack(
        std.heap.page_allocator,
        home,
        meta,
        &pc.candidate_last_hdr_bytes,
        pc.body_cbor_bytes_last[0..body_cbor_len],
        vrf_proof,
        vrf_output,
        sig_bytes,
        vrf_pk_bin,
        kes_pk_bin,
    );

    if (result.ok) {
        pc.pack_total += 1;
        pc.pack_last_unix = now;
        std.debug.print("PRODUCER PACK: wrote pack slot={d} epoch={d} sie={d} total={d}\n", .{
            pc.candidate_last_slot, pc.epoch_last, pc.slot_in_epoch_last, pc.pack_total,
        });
    } else {
        std.debug.print("PRODUCER PACK: failed to write pack\n", .{});
    }
}

// ── Gap Hunter helpers ───────────────────────────────────────────────

fn getGapDir(ctx: *Context) ?[]const u8 {
    if (ctx.gap_dir) |d| return d;
    const home = compat.getEnvVarOwned(std.heap.page_allocator, "TSUNAGI_HOME") catch return null;
    const dir = std.fmt.allocPrint(std.heap.page_allocator, "{s}/gaps", .{home}) catch {
        std.heap.page_allocator.free(home);
        return null;
    };
    std.heap.page_allocator.free(home);
    compat.fs.cwd().makePath(dir) catch {};
    ctx.gap_dir = dir;
    return dir;
}

fn gapTrackKey(ctx: *Context, tx_hash: [32]u8, index: u32) bool {
    // Lazy init
    if (ctx.missing_inputs_map == null) {
        ctx.missing_inputs_map = std.AutoHashMap([36]u8, u32).init(std.heap.page_allocator);
        ctx.missing_inputs_first_seen = std.AutoHashMap([36]u8, u64).init(std.heap.page_allocator);
        ctx.missing_inputs_last_seen = std.AutoHashMap([36]u8, u64).init(std.heap.page_allocator);
        if (!ctx.gap_keys_loaded) {
            ctx.gap_keys_loaded = true;
            loadGapKeys(ctx);
            loadFirstSeen(ctx);
            loadLastSeen(ctx);
            // Backfill last_seen for loaded keys that don't have entries yet
            backfillLastSeen(ctx);
        }
    }
    var map = &ctx.missing_inputs_map.?;
    const now_u: u64 = @intCast(compat.timestamp());

    var key: [36]u8 = undefined;
    @memcpy(key[0..32], tx_hash[0..32]);
    std.mem.writeInt(u32, key[32..36], index, .little);

    const gop = map.getOrPut(key) catch return false;
    if (gop.found_existing) {
        gop.value_ptr.* +%= 1;
        // Update last-seen on every hit
        if (ctx.missing_inputs_last_seen) |*ls| {
            ls.put(key, now_u) catch {};
        }
        return false;
    }
    // New key — check cap and evict if needed
    if (map.count() > MAX_GAP_KEYS) {
        // We just inserted and exceeded cap; evict oldest last_seen entry
        if (ctx.missing_inputs_last_seen) |*ls| {
            var oldest_key: ?[36]u8 = null;
            var oldest_ts: u64 = std.math.maxInt(u64);
            var ls_iter = ls.iterator();
            while (ls_iter.next()) |entry| {
                if (entry.value_ptr.* < oldest_ts) {
                    oldest_ts = entry.value_ptr.*;
                    oldest_key = entry.key_ptr.*;
                }
            }
            if (oldest_key) |evict_key| {
                // Don't evict the key we just inserted
                if (!std.mem.eql(u8, &evict_key, &key)) {
                    _ = map.remove(evict_key);
                    _ = ls.remove(evict_key);
                    if (ctx.missing_inputs_first_seen) |*fs| {
                        _ = fs.remove(evict_key);
                    }
                    ctx.gap_evictions_total += 1;
                    ctx.gap_window_evictions += 1;
                }
            }
        }
    }
    gop.value_ptr.* = 1;
    // Record first-seen + last-seen timestamp
    if (ctx.missing_inputs_first_seen) |*fs| {
        fs.put(key, now_u) catch {};
    }
    if (ctx.missing_inputs_last_seen) |*ls| {
        ls.put(key, now_u) catch {};
    }
    return true;
}

fn loadGapKeys(ctx: *Context) void {
    const dir = getGapDir(ctx) orelse return;
    const path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/missing_inputs.keys", .{dir}) catch return;
    defer std.heap.page_allocator.free(path);

    var f = compat.fs.cwd().openFile(path, .{}) catch return;
    defer f.close();
    const data = f.deprecatedReader().readAllAlloc(std.heap.page_allocator, 512 * 1024) catch return;
    defer std.heap.page_allocator.free(data);

    var map = &ctx.missing_inputs_map.?;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len < 72) continue;
        if (map.count() >= MAX_GAP_KEYS) break;
        var key: [36]u8 = undefined;
        var valid = true;
        for (0..36) |i| {
            key[i] = std.fmt.parseInt(u8, line[i * 2 .. i * 2 + 2], 16) catch {
                valid = false;
                break;
            };
        }
        if (!valid) continue;
        map.put(key, 0) catch continue;
    }
    std.debug.print("GAP HUNTER: loaded {d} keys from file\n", .{map.count()});
}

fn persistGapKeys(ctx: *Context) void {
    const dir = getGapDir(ctx) orelse return;
    const map = ctx.missing_inputs_map orelse return;

    const path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/missing_inputs.keys", .{dir}) catch return;
    defer std.heap.page_allocator.free(path);
    const tmp = std.fmt.allocPrint(std.heap.page_allocator, "{s}/missing_inputs.keys.tmp", .{dir}) catch return;
    defer std.heap.page_allocator.free(tmp);

    var f = compat.fs.cwd().createFile(tmp, .{}) catch return;
    const hex = "0123456789abcdef";
    var iter = map.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        var line: [73]u8 = undefined;
        for (0..36) |i| {
            line[i * 2] = hex[key[i] >> 4];
            line[i * 2 + 1] = hex[key[i] & 0xf];
        }
        line[72] = '\n';
        _ = f.write(&line) catch {};
    }
    f.close();
    compat.fs.cwd().rename(tmp, path) catch {};
}

fn appendGapLog(ctx: *Context, slot: u64, block_no: u64, missing: u64, sampled: u64, keys_count: u64) void {
    const dir = getGapDir(ctx) orelse return;
    const path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/missing_inputs.log", .{dir}) catch return;
    defer std.heap.page_allocator.free(path);

    var f = compat.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
    defer f.close();
    const end = f.getEndPos() catch 0;
    f.seekTo(end) catch {};

    const now: u64 = @intCast(compat.timestamp());
    f.deprecatedWriter().print("{d} block={d} slot={d} missing={d} sampled={d} keys={d}\n", .{
        now, block_no, slot, missing, sampled, keys_count,
    }) catch {};
}

// ── Gap Hunter v2: TopK + age + first_seen ──────────────────────────

const TopKEntry = struct { key: [36]u8, count: u32, age: u64, age_last: u64 };

fn computeAndPersistTopK(ctx: *Context) void {
    const map = ctx.missing_inputs_map orelse return;
    const dir = getGapDir(ctx) orelse return;
    const now_u: u64 = @intCast(compat.timestamp());

    // Compute TopK by iterating the map and keeping the K highest counts
    var top: [GAP_TOPK]TopKEntry = undefined;
    var top_len: usize = 0;

    var iter = map.iterator();
    while (iter.next()) |entry| {
        const c = entry.value_ptr.*;
        const k = entry.key_ptr.*;
        const first = if (ctx.missing_inputs_first_seen) |fs| (fs.get(k) orelse now_u) else now_u;
        const age = if (now_u >= first) now_u - first else 0;
        const last = if (ctx.missing_inputs_last_seen) |ls| (ls.get(k) orelse now_u) else now_u;
        const a_last = if (now_u >= last) now_u - last else 0;

        if (top_len < GAP_TOPK) {
            top[top_len] = .{ .key = k, .count = c, .age = age, .age_last = a_last };
            top_len += 1;
        } else {
            // Find the minimum in top array
            var min_idx: usize = 0;
            for (1..top_len) |i| {
                if (top[i].count < top[min_idx].count) min_idx = i;
            }
            if (c > top[min_idx].count) {
                top[min_idx] = .{ .key = k, .count = c, .age = age, .age_last = a_last };
            }
        }
    }

    // Sort descending by count (simple insertion sort, K=10)
    if (top_len > 1) {
        for (1..top_len) |i| {
            const tmp = top[i];
            var j: usize = i;
            while (j > 0 and top[j - 1].count < tmp.count) {
                top[j] = top[j - 1];
                j -= 1;
            }
            top[j] = tmp;
        }
    }

    // Update hot-top metrics + hot key change tracking
    if (top_len > 0) {
        if (!std.mem.eql(u8, &ctx.gap_hot_key_last, &top[0].key)) {
            ctx.gap_hot_changes_5min += 1;
            ctx.gap_hot_key_last = top[0].key;
        }
    }
    if (ctx.metrics) |ma| {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
        if (top_len > 0) {
            m.gap_hot_top_count.store(top[0].count, .release);
            m.gap_hot_top_age_seconds.store(top[0].age, .release);
        } else {
            m.gap_hot_top_count.store(0, .release);
            m.gap_hot_top_age_seconds.store(0, .release);
        }
    }

    // Write top_missing.json
    const path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/top_missing.json", .{dir}) catch return;
    defer std.heap.page_allocator.free(path);
    const tmp = std.fmt.allocPrint(std.heap.page_allocator, "{s}/top_missing.json.tmp", .{dir}) catch return;
    defer std.heap.page_allocator.free(tmp);

    var f = compat.fs.cwd().createFile(tmp, .{}) catch return;
    const w = f.deprecatedWriter();
    const hex = "0123456789abcdef";

    w.print("{{\"updated_unix\":{d},\"total_keys\":{d},\"top\":[", .{
        now_u, @as(u64, @intCast(map.count())),
    }) catch {};

    for (0..top_len) |i| {
        if (i > 0) _ = w.write(",") catch {};
        _ = w.write("{\"k\":\"") catch {};
        var hbuf: [72]u8 = undefined;
        for (0..36) |b| {
            hbuf[b * 2] = hex[top[i].key[b] >> 4];
            hbuf[b * 2 + 1] = hex[top[i].key[b] & 0xf];
        }
        _ = w.write(&hbuf) catch {};
        w.print("\",\"c\":{d},\"age\":{d},\"age_last\":{d}}}", .{ top[i].count, top[i].age, top[i].age_last }) catch {};
    }
    _ = w.write("]}\n") catch {};
    f.close();
    compat.fs.cwd().rename(tmp, path) catch {};
}

fn loadFirstSeen(ctx: *Context) void {
    const dir = getGapDir(ctx) orelse return;
    const path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/missing_inputs.first_seen.json", .{dir}) catch return;
    defer std.heap.page_allocator.free(path);

    var f = compat.fs.cwd().openFile(path, .{}) catch return;
    defer f.close();
    const data = f.deprecatedReader().readAllAlloc(std.heap.page_allocator, 1024 * 1024) catch return;
    defer std.heap.page_allocator.free(data);

    var fs_map = &(ctx.missing_inputs_first_seen orelse return);
    // Parse items: look for ["<72hex>",<unix>] pairs
    // Simple scan: find "items":[  then parse each ["...",N]
    const items_start = std.mem.indexOf(u8, data, "\"items\":[") orelse return;
    var pos = items_start + "\"items\":[".len;
    while (pos < data.len and fs_map.count() < MAX_GAP_KEYS) {
        // Find next ["
        const bracket = std.mem.indexOfPos(u8, data, pos, "[\"") orelse break;
        const hex_start = bracket + 2;
        if (hex_start + 72 > data.len) break;
        // Parse 72 hex chars
        var key: [36]u8 = undefined;
        var valid = true;
        for (0..36) |i| {
            key[i] = std.fmt.parseInt(u8, data[hex_start + i * 2 .. hex_start + i * 2 + 2], 16) catch {
                valid = false;
                break;
            };
        }
        if (!valid) {
            pos = hex_start + 72;
            continue;
        }
        // Find ,<number>]
        const comma = std.mem.indexOfPos(u8, data, hex_start + 72, ",") orelse {
            pos = hex_start + 72;
            continue;
        };
        const close = std.mem.indexOfPos(u8, data, comma + 1, "]") orelse {
            pos = comma + 1;
            continue;
        };
        const num_str = std.mem.trim(u8, data[comma + 1 .. close], " ");
        const unix_val = std.fmt.parseUnsigned(u64, num_str, 10) catch {
            pos = close + 1;
            continue;
        };
        fs_map.put(key, unix_val) catch {};
        pos = close + 1;
    }
    std.debug.print("GAP HUNTER: loaded {d} first_seen entries (path={s}, bytes={d})\n", .{ fs_map.count(), path, data.len });
}

fn persistFirstSeen(ctx: *Context) void {
    const dir = getGapDir(ctx) orelse return;
    const fs_map = ctx.missing_inputs_first_seen orelse return;
    if (fs_map.count() == 0) return;

    const path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/missing_inputs.first_seen.json", .{dir}) catch return;
    defer std.heap.page_allocator.free(path);
    const tmp = std.fmt.allocPrint(std.heap.page_allocator, "{s}/missing_inputs.first_seen.json.tmp", .{dir}) catch return;
    defer std.heap.page_allocator.free(tmp);

    var f = compat.fs.cwd().createFile(tmp, .{}) catch return;
    const w = f.deprecatedWriter();
    const hex = "0123456789abcdef";
    const now_u: u64 = @intCast(compat.timestamp());

    w.print("{{\"updated_unix\":{d},\"items\":[", .{now_u}) catch {};

    var iter = fs_map.iterator();
    var first = true;
    while (iter.next()) |entry| {
        // Only persist entries that still exist in the main map
        if (ctx.missing_inputs_map) |main_map| {
            if (!main_map.contains(entry.key_ptr.*)) continue;
        }
        if (!first) _ = w.write(",") catch {};
        first = false;
        _ = w.write("[\"") catch {};
        var hbuf: [72]u8 = undefined;
        for (0..36) |b| {
            hbuf[b * 2] = hex[entry.key_ptr.*[b] >> 4];
            hbuf[b * 2 + 1] = hex[entry.key_ptr.*[b] & 0xf];
        }
        _ = w.write(&hbuf) catch {};
        w.print("\",{d}]", .{entry.value_ptr.*}) catch {};
    }
    _ = w.write("]}\n") catch {};
    f.close();
    compat.fs.cwd().rename(tmp, path) catch {};
}

fn loadLastSeen(ctx: *Context) void {
    const dir = getGapDir(ctx) orelse return;
    const path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/missing_inputs.last_seen.json", .{dir}) catch return;
    defer std.heap.page_allocator.free(path);

    var f = compat.fs.cwd().openFile(path, .{}) catch return;
    defer f.close();
    const data = f.deprecatedReader().readAllAlloc(std.heap.page_allocator, 1024 * 1024) catch return;
    defer std.heap.page_allocator.free(data);

    const file_bytes: u64 = @intCast(data.len);

    var ls_map = &(ctx.missing_inputs_last_seen orelse return);
    const items_start = std.mem.indexOf(u8, data, "\"items\":[") orelse {
        std.debug.print("GAP HUNTER: loaded 0 last_seen entries (path={s}, bytes={d}, no items key)\n", .{ path, file_bytes });
        if (ctx.metrics) |ma| {
            const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
            m.gap_last_seen_file_bytes.store(file_bytes, .release);
        }
        return;
    };
    var pos = items_start + "\"items\":[".len;
    var parse_errors: u64 = 0;
    while (pos < data.len and ls_map.count() < MAX_GAP_KEYS) {
        const bracket = std.mem.indexOfPos(u8, data, pos, "[\"") orelse break;
        const hex_start = bracket + 2;
        if (hex_start + 72 > data.len) break;
        var key: [36]u8 = undefined;
        var valid = true;
        for (0..36) |i| {
            key[i] = std.fmt.parseInt(u8, data[hex_start + i * 2 .. hex_start + i * 2 + 2], 16) catch {
                valid = false;
                break;
            };
        }
        if (!valid) {
            parse_errors += 1;
            pos = hex_start + 72;
            continue;
        }
        const comma = std.mem.indexOfPos(u8, data, hex_start + 72, ",") orelse {
            parse_errors += 1;
            pos = hex_start + 72;
            continue;
        };
        const close = std.mem.indexOfPos(u8, data, comma + 1, "]") orelse {
            parse_errors += 1;
            pos = comma + 1;
            continue;
        };
        const num_str = std.mem.trim(u8, data[comma + 1 .. close], " ");
        const unix_val = std.fmt.parseUnsigned(u64, num_str, 10) catch {
            parse_errors += 1;
            pos = close + 1;
            continue;
        };
        ls_map.put(key, unix_val) catch {};
        pos = close + 1;
    }
    std.debug.print("GAP HUNTER: loaded {d} last_seen entries (path={s}, bytes={d}, parse_errors={d})\n", .{ ls_map.count(), path, file_bytes, parse_errors });
    if (ctx.metrics) |ma| {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
        m.gap_last_seen_loaded.store(@intCast(ls_map.count()), .release);
        m.gap_last_seen_file_bytes.store(file_bytes, .release);
        m.gap_last_seen_parse_errors_total.store(parse_errors, .release);
    }
}

fn backfillLastSeen(ctx: *Context) void {
    const main_map = ctx.missing_inputs_map orelse return;
    var ls = &(ctx.missing_inputs_last_seen orelse return);
    const now_u: u64 = @intCast(compat.timestamp());
    var backfilled: u64 = 0;
    var iter = main_map.iterator();
    while (iter.next()) |entry| {
        if (!ls.contains(entry.key_ptr.*)) {
            // Use first_seen timestamp if available, otherwise now
            const ts = if (ctx.missing_inputs_first_seen) |fs| (fs.get(entry.key_ptr.*) orelse now_u) else now_u;
            ls.put(entry.key_ptr.*, ts) catch {};
            backfilled += 1;
        }
    }
    std.debug.print("GAP HUNTER: backfilled {d} last_seen entries from loaded keys (total={d})\n", .{ backfilled, ls.count() });
    if (ctx.metrics) |ma| {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
        m.gap_last_seen_items.store(@intCast(ls.count()), .release);
    }
}

fn persistLastSeen(ctx: *Context) void {
    const dir = getGapDir(ctx) orelse return;
    const ls_map = ctx.missing_inputs_last_seen orelse return;
    if (ls_map.count() == 0) return;

    const path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/missing_inputs.last_seen.json", .{dir}) catch return;
    defer std.heap.page_allocator.free(path);
    const tmp = std.fmt.allocPrint(std.heap.page_allocator, "{s}/missing_inputs.last_seen.json.tmp", .{dir}) catch return;
    defer std.heap.page_allocator.free(tmp);

    var f = compat.fs.cwd().createFile(tmp, .{}) catch return;
    const w = f.deprecatedWriter();
    const hex = "0123456789abcdef";
    const now_u: u64 = @intCast(compat.timestamp());

    w.print("{{\"updated_unix\":{d},\"items\":[", .{now_u}) catch {};

    var ls_iter = ls_map.iterator();
    var first = true;
    while (ls_iter.next()) |entry| {
        // Only persist entries that still exist in the main map
        if (ctx.missing_inputs_map) |main_map| {
            if (!main_map.contains(entry.key_ptr.*)) continue;
        }
        if (!first) _ = w.write(",") catch {};
        first = false;
        _ = w.write("[\"") catch {};
        var hbuf: [72]u8 = undefined;
        for (0..36) |b| {
            hbuf[b * 2] = hex[entry.key_ptr.*[b] >> 4];
            hbuf[b * 2 + 1] = hex[entry.key_ptr.*[b] & 0xf];
        }
        _ = w.write(&hbuf) catch {};
        w.print("\",{d}]", .{entry.value_ptr.*}) catch {};
    }
    _ = w.write("]}\n") catch {};
    const file_bytes: u64 = f.getPos() catch 0;
    f.close();
    compat.fs.cwd().rename(tmp, path) catch {};
    std.debug.print("GAPS: last_seen file bytes={d}\n", .{file_bytes});
    if (ctx.metrics) |ma| {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
        m.gap_last_seen_file_bytes.store(file_bytes, .release);
    }
}

fn lmdbAuthorityEnabled() bool {
    const v = compat.getEnvVarOwned(std.heap.page_allocator, "TSUNAGI_LMDB_AUTHORITY") catch return false;
    defer std.heap.page_allocator.free(v);
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

fn lmdbAuthorityFail(msg: []const u8) void {
    std.debug.print("LMDB AUTHORITY VIOLATION: {s}\n", .{msg});
    std.debug.print("LMDB AUTHORITY: exiting (systemd restart)\n", .{});
    std.process.exit(1);
}

var g_last_ratio_print_unix: i64 = 0;
var g_prev_truth: u64 = 0;
var g_prev_fallback: u64 = 0;

fn maybePrintLmdbRatio(ctx: *Context) void {
    const metrics_any = ctx.metrics orelse return;
    const now = compat.timestamp();
    if (now - g_last_ratio_print_unix < 60) return;
    g_last_ratio_print_unix = now;

    const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
    const t = m.lmdb_truth_blocks.load(.acquire);
    const f = m.lmdb_fallback_blocks.load(.acquire);
    const denom = t + f;
    const ratio: f64 = if (denom == 0) 0.0 else @as(f64, @floatFromInt(t)) / @as(f64, @floatFromInt(denom));

    // Rolling window: truth/fallback delta since last print
    const dt = t - g_prev_truth;
    const df = f - g_prev_fallback;
    const window_denom = dt + df;
    const window_ratio: f64 = if (window_denom == 0) 0.0 else @as(f64, @floatFromInt(dt)) / @as(f64, @floatFromInt(window_denom));
    g_prev_truth = t;
    g_prev_fallback = f;

    std.debug.print(
        "LMDB PATH RATIO: truth={d} fallback={d} ratio={d:.4} window_truth={d} window_fallback={d} window_ratio={d:.4}\n",
        .{ t, f, ratio, dt, df, window_ratio },
    );
}

pub fn checkConvergence(ctx: *Context, alloc: std.mem.Allocator) void {
    const metrics_any = ctx.metrics orelse return;
    const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
    const truth = m.lmdb_truth_blocks.load(.acquire);
    const fallback = m.lmdb_fallback_blocks.load(.acquire);
    const denom = truth + fallback;
    if (denom == 0) return;

    const now = compat.timestamp();

    // Initialize fallback tracking on first call
    if (ctx.last_fallback_change_unix == 0) {
        ctx.last_fallback_blocks = fallback;
        ctx.last_fallback_change_unix = now;
        return;
    }

    // Track fallback stability
    if (fallback != ctx.last_fallback_blocks) {
        ctx.last_fallback_blocks = fallback;
        ctx.last_fallback_change_unix = now;
    }

    // ── Convergence gate evaluation (every 10s) ──
    if (now - ctx.last_conv_gate_eval_unix >= 10) {
        ctx.last_conv_gate_eval_unix = now;

        const truth_ratio_x1e6: u64 = if (denom > 0) (truth * 1_000_000) / denom else 0;
        const value_check_ratio_x1e6 = m.ledger_value_check_ratio_x1e6.load(.acquire);
        const missing_ema = m.ledger_missing_inputs_ema.load(.acquire);

        const ready_now = (truth_ratio_x1e6 >= 800_000) and (value_check_ratio_x1e6 >= 800_000) and (missing_ema <= 1);

        if (ready_now) {
            if (ctx.conv_ready_since_unix == 0) ctx.conv_ready_since_unix = now;
        } else {
            ctx.conv_ready_since_unix = 0;
        }

        const stable_s: u64 = if (ctx.conv_ready_since_unix > 0) @intCast(now - ctx.conv_ready_since_unix) else 0;

        // Latch: write marker file on first stable-ready
        if (stable_s >= 600 and ctx.conv_ready_latched_unix == 0) {
            ctx.conv_ready_latched_unix = now;
            // Write truth_ready.json marker (atomic)
            const state_dir = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
            if (state_dir) |sd| {
                defer alloc.free(sd);
                const marker_path = std.fs.path.join(alloc, &[_][]const u8{ sd, "truth_ready.json" }) catch null;
                if (marker_path) |mp| {
                    defer alloc.free(mp);
                    const tmp_path = std.fmt.allocPrint(alloc, "{s}.tmp", .{mp}) catch null;
                    if (tmp_path) |tp| {
                        defer alloc.free(tp);
                        if (compat.fs.cwd().createFile(tp, .{})) |tf_const| {
                            var tf = tf_const;
                            const truth_ratio_f: f64 = @as(f64, @floatFromInt(truth_ratio_x1e6)) / 1_000_000.0;
                            const vc_ratio_f: f64 = @as(f64, @floatFromInt(value_check_ratio_x1e6)) / 1_000_000.0;
                            tf.deprecatedWriter().print(
                                "{{\"truth_ready\":true,\"unix\":{d},\"truth_ratio\":{d:.6},\"value_check_ratio\":{d:.6},\"missing_ema\":{d},\"slot\":{d},\"block_no\":{d},\"header_height\":{d}}}\n",
                                .{ now, truth_ratio_f, vc_ratio_f, missing_ema, ctx.cursor.slot, ctx.cursor.block_no, ctx.header_height },
                            ) catch {};
                            tf.close();
                            compat.fs.cwd().rename(tp, mp) catch {};
                            std.debug.print("CONVERGENCE GATE: truth_ready.json written (stable for {d}s)\n", .{stable_s});
                        } else |_| {}
                    }
                }
            }
            // BAEY audit (fires once at latch)
            baeyLog(ctx, "convergence_latched", "stable_600s", "latch", ctx.cursor.slot, ctx.cursor.block_no);
        }

        // Update convergence gate metrics
        m.convergence_gate_ready.store(if (ctx.conv_ready_latched_unix > 0) @as(u64, 1) else 0, .release);
        m.convergence_gate_ready_unix.store(if (ctx.conv_ready_latched_unix > 0) @intCast(ctx.conv_ready_latched_unix) else 0, .release);
        m.convergence_gate_stable_seconds.store(stable_s, .release);
        m.convergence_gate_truth_ratio_x1e6.store(truth_ratio_x1e6, .release);
        m.convergence_gate_value_check_ratio_x1e6.store(value_check_ratio_x1e6, .release);
        m.convergence_gate_missing_ema.store(missing_ema, .release);
    }

    // ── Legacy native_ready marker (existing behavior) ──
    if (ctx.convergence_marked) return;

    const ratio: f64 = @as(f64, @floatFromInt(truth)) / @as(f64, @floatFromInt(denom));
    const stable_secs = now - ctx.last_fallback_change_unix;

    if (ratio >= 0.999 and stable_secs >= 600) {
        const state_dir = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch return;
        defer alloc.free(state_dir);

        const marker_path = std.fs.path.join(alloc, &[_][]const u8{ state_dir, "native_ready.json" }) catch return;
        defer alloc.free(marker_path);

        var f = compat.fs.cwd().createFile(marker_path, .{ .truncate = true }) catch return;
        defer f.close();

        f.deprecatedWriter().print(
            \\{{
            \\  "native_ready": true,
            \\  "when_unix": {d},
            \\  "truth_ratio": {d:.6},
            \\  "truth_blocks": {d},
            \\  "fallback_blocks": {d}
            \\}}
            \\
        , .{ now, ratio, truth, fallback }) catch return;

        std.debug.print("LMDB CONVERGED: native mode ready (see {s})\n", .{marker_path});
        ctx.convergence_marked = true;
    }
}

fn lmdbApplyUndoRollback(ctx: *Context, alloc: std.mem.Allocator, undo: *utxo_mod.Undo) void {
    var store = &(ctx.lmdb orelse return);

    if (store.beginWrite()) |txn0| {
        var txn = txn0;

        // Apply rollback operations in reverse order (same as utxo.rollbackDelta)
        var i: usize = undo.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = undo.entries.items[i];
            switch (e) {
                // Inserted during forward => remove from LMDB on rollback
                .inserted => |input| {
                    store.delTxn(&txn, input.tx_hash, input.index);
                },
                // Removed during forward => restore into LMDB on rollback
                .removed => |r| {
                    store.putTxn(alloc, &txn, r.input.tx_hash, r.input.index, r.output);
                },
            }
        }

        const ok = store.commit(&txn);
        if (!ok) std.debug.print("LMDB: rollback commit failed (non-fatal)\n", .{});
    } else {
        std.debug.print("LMDB: rollback beginWrite failed (non-fatal)\n", .{});
    }
}

/// Evict oldest undo entries that are deeply confirmed (beyond reorg risk).
/// Called on roll_forward; after UNDO_CONFIRM_DEPTH consecutive forwards
/// without rollback, the oldest undo is permanently committed.
fn confirmDeepUndos(ctx: *Context) void {
    const undo_stack = ctx.undo_stack orelse return;
    if (ctx.rolls_since_last_rollback >= UNDO_CONFIRM_DEPTH and undo_stack.items.len > 0) {
        var evicted = undo_stack.orderedRemove(0);
        evicted.deinitFreeAddresses();
        std.debug.print("UNDO: confirmed oldest entry; undo_depth={d}\n", .{undo_stack.items.len});
    }
}

// --- Replay support (offline block processing) ---

pub const ReplayResult = struct {
    tx_count: u64,
};

pub const ReplayCtx = struct {
    utxo: utxo_mod.UTxO,
    undo_stack: std.array_list.Managed(utxo_mod.Undo),
    debug: bool,
    state_digest: [32]u8,
    last_block_no: u64,
    last_slot: u64,
    utxo_keys: std.AutoHashMap(utxo_mod.TxIn, void),

    pub fn init(alloc: std.mem.Allocator, debug: bool) !ReplayCtx {
        return .{
            .utxo = utxo_mod.UTxO.init(alloc),
            .undo_stack = std.array_list.Managed(utxo_mod.Undo).init(alloc),
            .debug = debug,
            .state_digest = [_]u8{0} ** 32,
            .last_block_no = 0,
            .last_slot = 0,
            .utxo_keys = std.AutoHashMap(utxo_mod.TxIn, void).init(alloc),
        };
    }

    pub fn deinit(self: *ReplayCtx) void {
        for (self.undo_stack.items) |*u| {
            u.deinit();
        }
        self.undo_stack.deinit();
        self.utxo.deinit();
        self.utxo_keys.deinit();
    }
};

fn applyPreviewUtxoReplay(ctx: *ReplayCtx, alloc: std.mem.Allocator, deltas: tx_decode.TxDeltas) void {
    if (deltas.consumed.len == 0 and deltas.produced.len == 0) return;

    var undo = ctx.utxo.applyDelta(deltas.consumed, deltas.produced) catch |err| {
        std.debug.print("REPLAY UTXO applyDelta failed: {s}\n", .{@errorName(err)});
        var empty_undo = utxo_mod.Undo.init(alloc);
        ctx.undo_stack.append(empty_undo) catch {
            empty_undo.deinit();
        };
        return;
    };
    ctx.undo_stack.append(undo) catch |err| {
        std.debug.print("REPLAY UTXO undo append failed: {s}\n", .{@errorName(err)});
        undo.deinit();
        return;
    };
    if (ctx.undo_stack.items.len > MAX_UNDO_DEPTH) {
        var evicted = ctx.undo_stack.orderedRemove(0);
        evicted.deinitFreeAddresses();
    }
}

fn replayUpdateDigest(
    ctx: *ReplayCtx,
    tx_count: u64,
    consumed_len: u64,
    produced_len: u64,
) void {
    var h = std.crypto.hash.blake2.Blake2b256.init(.{});
    h.update(&ctx.state_digest);

    var buf: [8]u8 = undefined;

    std.mem.writeInt(u64, &buf, tx_count, .little);
    h.update(&buf);

    std.mem.writeInt(u64, &buf, consumed_len, .little);
    h.update(&buf);

    std.mem.writeInt(u64, &buf, produced_len, .little);
    h.update(&buf);

    std.mem.writeInt(u64, &buf, @intCast(ctx.utxo.count()), .little);
    h.update(&buf);

    std.mem.writeInt(u64, &buf, @intCast(ctx.undo_stack.items.len), .little);
    h.update(&buf);

    h.final(&ctx.state_digest);
}

pub fn replayDigestHex(ctx: *ReplayCtx, out: *[64]u8) []const u8 {
    _ = std.fmt.bufPrint(out, "{x}", .{&ctx.state_digest}) catch return out[0..0];
    return out[0..64];
}

fn keyHashTxIn(x: utxo_mod.TxIn) u64 {
    var h = std.crypto.hash.blake2.Blake2b256.init(.{});
    h.update(x.tx_hash[0..]);
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, @intCast(x.index), .little);
    h.update(&buf);
    var out: [32]u8 = undefined;
    h.final(&out);
    return std.mem.readInt(u64, out[0..8], .little);
}

fn keyHashProduced(p: utxo_mod.Produced) u64 {
    return keyHashTxIn(p.input);
}

fn replayCheckTxDeltasStructural(alloc: std.mem.Allocator, deltas: tx_decode.TxDeltas) !void {
    var consumed_set = std.AutoHashMap(u64, void).init(alloc);
    defer consumed_set.deinit();

    for (deltas.consumed) |c| {
        const k = keyHashTxIn(c);
        const gop = try consumed_set.getOrPut(k);
        if (gop.found_existing) {
            std.debug.print("LEDGER VIOLATION: duplicate consumed input in block\n", .{});
            return error.LedgerViolation;
        }
    }

    var produced_set = std.AutoHashMap(u64, void).init(alloc);
    defer produced_set.deinit();

    for (deltas.produced) |p| {
        const k = keyHashProduced(p);
        const gop = try produced_set.getOrPut(k);
        if (gop.found_existing) {
            std.debug.print("LEDGER VIOLATION: duplicate produced output in block\n", .{});
            return error.LedgerViolation;
        }
    }
}

fn replayApplyKeySetStrict(ctx: *ReplayCtx, deltas: tx_decode.TxDeltas) !void {
    for (deltas.consumed) |c| {
        if (!ctx.utxo_keys.contains(c)) {
            std.debug.print("LEDGER VIOLATION: consumed input missing from key-set\n", .{});
            return error.LedgerViolation;
        }
    }
    for (deltas.produced) |p| {
        const k = p.input;
        if (ctx.utxo_keys.contains(k)) {
            std.debug.print("LEDGER VIOLATION: produced output already exists in key-set\n", .{});
            return error.LedgerViolation;
        }
    }

    for (deltas.consumed) |c| {
        _ = ctx.utxo_keys.remove(c);
    }
    for (deltas.produced) |p| {
        try ctx.utxo_keys.put(p.input, {});
    }
}

fn replayCheckInvariants(
    ctx: *ReplayCtx,
    slot: u64,
    block_no: u64,
) !void {
    // Monotonic block number
    if (ctx.last_block_no != 0 and block_no <= ctx.last_block_no) {
        std.debug.print(
            "LEDGER VIOLATION: block_no not increasing (prev={d}, curr={d})\n",
            .{ ctx.last_block_no, block_no },
        );
        return error.LedgerViolation;
    }

    // Monotonic slot
    if (ctx.last_slot != 0 and slot <= ctx.last_slot) {
        std.debug.print(
            "LEDGER VIOLATION: slot not increasing (prev={d}, curr={d})\n",
            .{ ctx.last_slot, slot },
        );
        return error.LedgerViolation;
    }

    ctx.last_block_no = block_no;
    ctx.last_slot = slot;
}

pub fn replayProcessBlock(
    alloc: std.mem.Allocator,
    ctx: *ReplayCtx,
    slot: u64,
    block_no: u64,
    payload: []const u8,
) !ReplayResult {
    var fbs = compat.fixedBufferStream(payload);
    const term = cbor.decode(alloc, fbs.reader()) catch |err| {
        if (ctx.debug) std.debug.print("REPLAY: CBOR decode error {}\n", .{err});
        return .{ .tx_count = 0 };
    };
    defer cbor.free(term, alloc);

    // Block structure: [era, block_content]
    const block_content = if (term == .array and term.array.len >= 2) term.array[1] else term;

    const scan = tx_decode.extractTxListFromTermPublic(alloc, block_content) orelse {
        return .{ .tx_count = 0 };
    };
    const tx_list = scan.tx_list;
    if (tx_list.len == 0) return .{ .tx_count = 0 };

    const deltas = tx_decode.extractTxDeltas(alloc, tx_list, null, ctx.debug) catch {
        return .{ .tx_count = 0 };
    };
    defer tx_decode.freeTxDeltas(alloc, deltas);

    try replayCheckInvariants(
        ctx,
        slot,
        block_no,
    );

    try replayCheckTxDeltasStructural(alloc, deltas);

    try replayApplyKeySetStrict(ctx, deltas);

    applyPreviewUtxoReplay(ctx, alloc, deltas);

    replayUpdateDigest(
        ctx,
        deltas.tx_count,
        @intCast(deltas.consumed.len),
        @intCast(deltas.produced.len),
    );

    return .{ .tx_count = deltas.tx_count };
}

// --- Bayesian peer scoring (Thompson sampling) ---

const RELAY_COUNT = mainnet_relays.len;
comptime {
    if (RELAY_COUNT != http_metrics.PEER_SLOTS) @compileError("RELAY_COUNT must match http_metrics.PEER_SLOTS");
}
const SCORE_CAP: f64 = 50.0;

// v1.2.2 — BAeY guardrail constants
const PEER_PENALTY_COOLDOWN_S: i64 = 30; // seconds peer is in cooldown after hard fault
const PENALTY_RATE_WINDOW_S: i64 = 10; // max one penalty per type per peer per window

const PenaltyType = enum(u3) {
    connect_fail = 0,
    handshake_fail = 1,
    keepalive_timeout = 2,
    stream_error = 3,
    cbor_error = 4,
    density_violation = 5,
    authority_fail = 6,
    other = 7,
};
const PENALTY_TYPE_COUNT = 8;

const PeerScore = struct {
    alpha: [RELAY_COUNT]f64,
    beta_val: [RELAY_COUNT]f64,
    sample: [RELAY_COUNT]f64,
    selected: [RELAY_COUNT]u64,
    rng: std.Random.DefaultPrng,
    last_log_unix: i64,
    last_alpha_reward_unix: i64,
    last_perf_nudge_unix: i64,
    // v1.2.2 — per-peer cooldown and rate limiter
    peer_cooldown_until: [RELAY_COUNT]i64,
    last_penalty_unix: [RELAY_COUNT][PENALTY_TYPE_COUNT]i64,
};

/// AWS-style full-jitter backoff sleep. Sleeps for a random duration in
/// [0, min(cap_s, base_s * 2^attempt)] seconds, checking stop flag each second.
/// Returns true if stop was signaled during the wait.
fn jitterBackoffSleep(attempt: u32, cap_s: u64, base_s: u64, should_stop: *bool) bool {
    const shift: u6 = @intCast(@min(attempt, 6));
    const max_wait: u64 = @min(cap_s, base_s * (@as(u64, 1) << shift));
    const seed: u64 = @truncate(@as(u128, @bitCast(compat.nanoTimestamp())));
    var prng = std.Random.DefaultPrng.init(seed);
    const sleep_s: u64 = prng.random().intRangeAtMost(u64, 0, max_wait);
    var remaining: u64 = sleep_s;
    while (remaining > 0) : (remaining -= 1) {
        if (checkStop(should_stop)) return true;
        compat.sleep(1 * std.time.ns_per_s);
    }
    return false;
}

fn initPeerScore() PeerScore {
    const seed = @as(u64, @truncate(@as(u128, @bitCast(compat.nanoTimestamp()))));
    var score: PeerScore = undefined;
    for (0..RELAY_COUNT) |i| {
        score.alpha[i] = 1.0;
        score.beta_val[i] = 1.0;
        score.sample[i] = 0.0;
        score.selected[i] = 0;
        score.peer_cooldown_until[i] = 0;
        for (0..PENALTY_TYPE_COUNT) |t| {
            score.last_penalty_unix[i][t] = 0;
        }
    }
    score.rng = std.Random.DefaultPrng.init(seed);
    score.last_log_unix = 0;
    score.last_alpha_reward_unix = 0;
    score.last_perf_nudge_unix = 0;
    return score;
}

fn penalizePeer(score: *PeerScore, idx: usize, amount: f64) void {
    score.beta_val[idx] = @min(score.beta_val[idx] + amount, SCORE_CAP);
}

fn rewardPeer(score: *PeerScore, idx: usize, amount: f64) void {
    score.alpha[idx] = @min(score.alpha[idx] + amount, SCORE_CAP);
}

/// v1.2.2 — Rate-limited penalty wrapper. Returns true if penalty was applied, false if rate-limited.
/// Hard-fault types also set per-peer cooldown.
fn penalizePeerRateLimited(score: *PeerScore, idx: usize, amount: f64, ptype: PenaltyType, now: i64, metrics_any: ?*const anyopaque) bool {
    const ti = @intFromEnum(ptype);
    if (now - score.last_penalty_unix[idx][ti] < PENALTY_RATE_WINDOW_S) {
        // Rate-limited: increment counter
        if (metrics_any) |ma| {
            const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
            _ = m.baey_penalty_rate_limited_total.fetchAdd(1, .acq_rel);
        }
        return false;
    }
    score.last_penalty_unix[idx][ti] = now;
    penalizePeer(score, idx, amount);
    // Hard faults set cooldown
    switch (ptype) {
        .connect_fail, .handshake_fail, .keepalive_timeout => {
            score.peer_cooldown_until[idx] = now + PEER_PENALTY_COOLDOWN_S;
        },
        else => {},
    }
    return true;
}

fn sampleNormal(rng: *std.Random.DefaultPrng) f64 {
    // Box-Muller transform
    const rand_a = rng.random().float(f64);
    const rand_b = rng.random().float(f64);
    const r = @sqrt(-2.0 * @log(if (rand_a < 1e-300) 1e-300 else rand_a));
    return r * @cos(2.0 * std.math.pi * rand_b);
}

fn sampleGamma(rng: *std.Random.DefaultPrng, shape: f64) f64 {
    if (shape < 0.01) return 0.001; // degenerate guard

    if (shape < 1.0) {
        // Boost: Gamma(a) = Gamma(a+1) * U^(1/a)
        const g = sampleGamma(rng, shape + 1.0);
        const u = rng.random().float(f64);
        const clamped = if (u < 1e-300) 1e-300 else u;
        return g * std.math.pow(f64, clamped, 1.0 / shape);
    }

    // Marsaglia-Tsang for shape >= 1
    const d = shape - 1.0 / 3.0;
    const c = 1.0 / @sqrt(9.0 * d);

    while (true) {
        var x: f64 = undefined;
        var v: f64 = undefined;
        while (true) {
            x = sampleNormal(rng);
            v = 1.0 + c * x;
            if (v > 0.0) break;
        }
        v = v * v * v;
        const u = rng.random().float(f64);
        const clamped_u = if (u < 1e-300) 1e-300 else u;
        if (@log(clamped_u) < 0.5 * x * x + d - d * v + d * @log(v)) {
            return d * v;
        }
    }
}

fn sampleBeta(rng: *std.Random.DefaultPrng, a: f64, b: f64) f64 {
    const x = sampleGamma(rng, a);
    const y = sampleGamma(rng, b);
    const sum = x + y;
    if (sum < 1e-300) return 0.5;
    return x / sum;
}

fn pickRelay(score: *PeerScore, metrics_any: ?*const anyopaque) usize {
    const now = compat.timestamp();

    // Sample all peers
    var best_idx: usize = 0;
    var best_sample: f64 = -1.0;
    var best_noncooldown_idx: usize = 0;
    var best_noncooldown_sample: f64 = -1.0;
    var all_in_cooldown: bool = true;

    for (0..RELAY_COUNT) |i| {
        const s = sampleBeta(&score.rng, score.alpha[i], score.beta_val[i]);
        score.sample[i] = s;

        // Track overall best (for fallback if all in cooldown)
        if (s > best_sample) {
            best_sample = s;
            best_idx = i;
        }

        // Track best among non-cooldown peers
        if (score.peer_cooldown_until[i] <= now) {
            all_in_cooldown = false;
            if (s > best_noncooldown_sample) {
                best_noncooldown_sample = s;
                best_noncooldown_idx = i;
            }
        }
    }

    // v1.2.2: skip peers in cooldown unless all are in cooldown
    const selected_idx = if (all_in_cooldown) best_idx else best_noncooldown_idx;

    score.selected[selected_idx] += 1;

    // Update metrics atomics
    if (metrics_any) |ma| {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
        for (0..RELAY_COUNT) |i| {
            m.peer_alpha[i].store(@intFromFloat(score.alpha[i] * 1000.0), .release);
            m.peer_beta[i].store(@intFromFloat(score.beta_val[i] * 1000.0), .release);
            m.peer_sample[i].store(@intFromFloat(score.sample[i] * 1000.0), .release);
            m.peer_selected[i].store(score.selected[i], .release);
        }
        m.baey_selected_peer_index.store(selected_idx, .release);
        m.baey_cooldown_active.store(if (all_in_cooldown) 1 else 0, .release);
    }

    // Rate-limited log (once per 60s)
    if (now - score.last_log_unix >= 60) {
        score.last_log_unix = now;
        const relay = mainnet_relays[selected_idx];
        std.debug.print("BAYES: selected idx={d} peer={s}:{d} alpha={d:.2} beta={d:.2} sample={d:.3} cooldown_all={d}\n", .{
            selected_idx,
            relay.host,
            relay.port,
            score.alpha[selected_idx],
            score.beta_val[selected_idx],
            if (all_in_cooldown) best_sample else best_noncooldown_sample,
            @as(u8, if (all_in_cooldown) 1 else 0),
        });
    }

    return selected_idx;
}

// ── FastSync controller tick ────────────────────────────────────────

const FASTSYNC_COOLDOWN_S: i64 = 600; // 10 minutes

fn fastsyncTick(ctx: *Context, now: i64) void {
    const home_dir = ctx.fastsync_home_dir orelse return;
    const m_ptr = ctx.metrics orelse return;
    const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(m_ptr))));

    // Read inputs from atomics
    const truth_blocks = m.lmdb_truth_blocks.load(.acquire);
    const fallback_blocks = m.lmdb_fallback_blocks.load(.acquire);
    const total_blocks = truth_blocks +| fallback_blocks;
    const truth_ratio_x1e6: u64 = if (total_blocks > 0) (truth_blocks * 1_000_000) / total_blocks else 0;
    const value_check_x1e6 = m.ledger_value_check_ratio_x1e6.load(.acquire);
    const missing_ema = m.ledger_missing_inputs_ema.load(.acquire);
    const gap_capped = m.gap_capped.load(.acquire);
    const cap_main = m.capture_mainnet_bin_bytes.load(.acquire);
    const cap_rot = m.capture_rotate_bytes.load(.acquire);
    const cap_seg = m.capture_segments_count.load(.acquire);

    // State evaluation
    const ready = (truth_ratio_x1e6 >= 800_000) and (value_check_x1e6 >= 800_000) and (missing_ema <= 1) and (gap_capped == 0);
    const warmup = (cap_seg == 0) and (cap_rot > 0) and (cap_main < cap_rot);

    const prev_state = ctx.fastsync_state;
    const new_state: u8 = if (ready) 3 else if (warmup) 1 else 2; // READY / WARMUP / PUSHING

    ctx.fastsync_state = new_state;
    const now_u: u64 = if (now >= 0) @intCast(now) else 0;
    m.fastsync_state_code.store(new_state, .release);
    m.fastsync_last_unix.store(now_u, .release);

    if (new_state != prev_state) {
        const state_names = [4][]const u8{ "OFF", "WARMUP", "PUSHING", "READY" };
        const sn = if (new_state < 4) state_names[new_state] else "?";
        std.debug.print("FASTSYNC: state {d}->{d} ({s}) truth={d}.{d:0>2}% vcheck={d}.{d:0>2}% ema={d} capped={d}\n", .{
            prev_state, new_state, sn,
            truth_ratio_x1e6 / 10000, (truth_ratio_x1e6 % 10000) / 100,
            value_check_x1e6 / 10000, (value_check_x1e6 % 10000) / 100,
            missing_ema, gap_capped,
        });
    }

    // Actions (only in PUSHING state)
    if (new_state == 2) {
        // 1) Backfill override
        if (now - ctx.fastsync_last_backfill_action_unix >= FASTSYNC_COOLDOWN_S) {
            ctx.fastsync_last_backfill_action_unix = now;
            const expires = now_u +| 600; // 10 minutes
            fastsyncWriteBackfillOverride(home_dir, expires);
            _ = m.fastsync_actions_total.fetchAdd(1, .acq_rel);
            m.fastsync_last_action_code.store(1, .release);
        }

        // 2) Capture rotate override (set to 16MB for faster rotation)
        if (now - ctx.fastsync_last_capture_action_unix >= FASTSYNC_COOLDOWN_S) {
            ctx.fastsync_last_capture_action_unix = now;
            fastsyncWriteCaptureRotateOverride(home_dir, 16);
            _ = m.fastsync_actions_total.fetchAdd(1, .acq_rel);
            m.fastsync_last_action_code.store(2, .release);
        }

        // 3) TSF artifact request (every 30 minutes = 1800s)
        if (now - ctx.fastsync_last_tsf_action_unix >= 1800) {
            ctx.fastsync_last_tsf_action_unix = now;
            fastsyncWriteTsfRequest(home_dir, now_u);
            _ = m.fastsync_actions_total.fetchAdd(1, .acq_rel);
            m.fastsync_last_action_code.store(3, .release);
        }
    }

    // Clear overrides when transitioning to READY
    if (new_state == 3 and prev_state != 3) {
        if (now - ctx.fastsync_last_clear_action_unix >= FASTSYNC_COOLDOWN_S) {
            ctx.fastsync_last_clear_action_unix = now;
            fastsyncClearOverrides(home_dir);
            _ = m.fastsync_actions_total.fetchAdd(1, .acq_rel);
            m.fastsync_last_action_code.store(4, .release);
        }
    }

    // Convergence slope window (300s = 5 minutes)
    const SLOPE_OFFSET: u64 = 10_000_000;
    if (ctx.conv_slope_window_start_unix == 0) {
        // Initialize baselines
        ctx.conv_slope_window_start_unix = now;
        ctx.conv_slope_truth_base_x1e6 = truth_ratio_x1e6;
        ctx.conv_slope_value_base_x1e6 = value_check_x1e6;
        ctx.conv_slope_ema_base = missing_ema;
    } else if (now - ctx.conv_slope_window_start_unix >= 300) {
        // Window rollover — compute deltas
        const truth_delta_i: i64 = @as(i64, @intCast(truth_ratio_x1e6)) - @as(i64, @intCast(ctx.conv_slope_truth_base_x1e6));
        const value_delta_i: i64 = @as(i64, @intCast(value_check_x1e6)) - @as(i64, @intCast(ctx.conv_slope_value_base_x1e6));
        const ema_delta_i: i64 = @as(i64, @intCast(missing_ema)) - @as(i64, @intCast(ctx.conv_slope_ema_base));
        // Store offset-encoded (SLOPE_OFFSET + delta)
        const truth_enc: u64 = @intCast(@as(i64, @intCast(SLOPE_OFFSET)) + truth_delta_i);
        const value_enc: u64 = @intCast(@as(i64, @intCast(SLOPE_OFFSET)) + value_delta_i);
        const ema_enc: u64 = @intCast(@as(i64, @intCast(SLOPE_OFFSET)) + ema_delta_i * 1000); // x1e3 encoding
        m.convergence_truth_delta_5m_x1e6.store(truth_enc, .release);
        m.convergence_value_delta_5m_x1e6.store(value_enc, .release);
        m.convergence_missing_ema_delta_5m_x1e3.store(ema_enc, .release);
        m.convergence_slope_window_unix.store(now_u, .release);
        // Reset baselines
        ctx.conv_slope_window_start_unix = now;
        ctx.conv_slope_truth_base_x1e6 = truth_ratio_x1e6;
        ctx.conv_slope_value_base_x1e6 = value_check_x1e6;
        ctx.conv_slope_ema_base = missing_ema;
    }

    // ETA computation (only in PUSHING or READY)
    if (new_state == 3) {
        // READY
        m.fastsync_eta_minutes.store(0, .release);
        m.fastsync_eta_reason_code.store(0, .release);
    } else if (new_state == 2) {
        // PUSHING — compute ETA from slopes
        const td_raw = m.convergence_truth_delta_5m_x1e6.load(.acquire);
        const vd_raw = m.convergence_value_delta_5m_x1e6.load(.acquire);
        const ed_raw = m.convergence_missing_ema_delta_5m_x1e3.load(.acquire);
        const td_i: i64 = @as(i64, @intCast(td_raw)) - @as(i64, @intCast(SLOPE_OFFSET));
        const vd_i: i64 = @as(i64, @intCast(vd_raw)) - @as(i64, @intCast(SLOPE_OFFSET));
        const ed_i: i64 = @as(i64, @intCast(ed_raw)) - @as(i64, @intCast(SLOPE_OFFSET));

        if (ctx.conv_slope_window_start_unix == now) {
            // No slope data yet (first window)
            m.fastsync_eta_minutes.store(0, .release);
            m.fastsync_eta_reason_code.store(1, .release);
        } else if (td_i <= 0 or vd_i <= 0) {
            // Slopes not positive (not converging)
            m.fastsync_eta_minutes.store(0, .release);
            m.fastsync_eta_reason_code.store(2, .release);
        } else if (ed_i >= 0 and missing_ema > 1) {
            // EMA not dropping
            m.fastsync_eta_minutes.store(0, .release);
            m.fastsync_eta_reason_code.store(2, .release);
        } else {
            // Compute three ETAs (in 5-minute units, then convert to minutes)
            const truth_gap: f64 = if (truth_ratio_x1e6 < 800_000)
                @as(f64, @floatFromInt(800_000 - truth_ratio_x1e6))
            else
                0.0;
            const value_gap: f64 = if (value_check_x1e6 < 800_000)
                @as(f64, @floatFromInt(800_000 - value_check_x1e6))
            else
                0.0;
            const td_f: f64 = @max(1.0, @as(f64, @floatFromInt(td_i)));
            const vd_f: f64 = @max(1.0, @as(f64, @floatFromInt(vd_i)));
            const eta_truth = (truth_gap / td_f) * 5.0;
            const eta_value = (value_gap / vd_f) * 5.0;
            var eta_ema: f64 = 0.0;
            if (missing_ema > 1 and ed_i < 0) {
                const ema_gap: f64 = @as(f64, @floatFromInt(missing_ema - 1)) * 1000.0; // scale to x1e3
                const ed_abs: f64 = @as(f64, @floatFromInt(-ed_i));
                eta_ema = (ema_gap / @max(1.0, ed_abs)) * 5.0;
            }
            const eta_max = @max(eta_truth, @max(eta_value, eta_ema));
            const eta_ceil: u64 = if (eta_max <= 0.0) 0 else @intFromFloat(@ceil(eta_max));
            const eta_clamped: u64 = if (eta_ceil == 0) 0 else @min(9999, @max(1, eta_ceil));
            m.fastsync_eta_minutes.store(eta_clamped, .release);
            m.fastsync_eta_reason_code.store(3, .release);
        }
    } else {
        // OFF or WARMUP — no ETA
        m.fastsync_eta_minutes.store(0, .release);
        m.fastsync_eta_reason_code.store(1, .release);
    }
}

fn fastsyncWriteBackfillOverride(home_dir: []const u8, expires: u64) void {
    const alloc = std.heap.page_allocator;
    const dir_path = std.fs.path.join(alloc, &[_][]const u8{ home_dir, "baey" }) catch return;
    defer alloc.free(dir_path);
    compat.fs.cwd().makePath(dir_path) catch return;
    const tmp_path = std.fs.path.join(alloc, &[_][]const u8{ dir_path, "backfill_override.json.tmp" }) catch return;
    defer alloc.free(tmp_path);
    const final_path = std.fs.path.join(alloc, &[_][]const u8{ dir_path, "backfill_override.json" }) catch return;
    defer alloc.free(final_path);

    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"expires_unix\":{d},\"source\":\"fastsync\"}}", .{expires}) catch return;

    var f = compat.fs.cwd().createFile(tmp_path, .{}) catch return;
    f.writeAll(json) catch {
        f.close();
        return;
    };
    f.close();
    compat.fs.cwd().rename(tmp_path, final_path) catch return;
    std.debug.print("FASTSYNC: wrote backfill_override expires_unix={d}\n", .{expires});
}

fn fastsyncWriteCaptureRotateOverride(home_dir: []const u8, mb: u64) void {
    const alloc = std.heap.page_allocator;
    const tmp_path = std.fs.path.join(alloc, &[_][]const u8{ home_dir, "capture.rotate_mb.tmp" }) catch return;
    defer alloc.free(tmp_path);
    const final_path = std.fs.path.join(alloc, &[_][]const u8{ home_dir, "capture.rotate_mb" }) catch return;
    defer alloc.free(final_path);

    var buf: [16]u8 = undefined;
    const val = std.fmt.bufPrint(&buf, "{d}\n", .{mb}) catch return;

    var f = compat.fs.cwd().createFile(tmp_path, .{}) catch return;
    f.writeAll(val) catch {
        f.close();
        return;
    };
    f.close();
    compat.fs.cwd().rename(tmp_path, final_path) catch return;
    std.debug.print("FASTSYNC: wrote capture.rotate_mb={d}\n", .{mb});
}

fn fastsyncWriteTsfRequest(home_dir: []const u8, unix: u64) void {
    const alloc = std.heap.page_allocator;
    const tsf_dir = std.fs.path.join(alloc, &[_][]const u8{ home_dir, "tsf" }) catch return;
    defer alloc.free(tsf_dir);
    compat.fs.cwd().makePath(tsf_dir) catch return;
    const tmp_path = std.fs.path.join(alloc, &[_][]const u8{ tsf_dir, "fastsync.request.tmp" }) catch return;
    defer alloc.free(tmp_path);
    const final_path = std.fs.path.join(alloc, &[_][]const u8{ tsf_dir, "fastsync.request" }) catch return;
    defer alloc.free(final_path);

    var buf: [64]u8 = undefined;
    const val = std.fmt.bufPrint(&buf, "{{\"unix\":{d}}}\n", .{unix}) catch return;

    var f = compat.fs.cwd().createFile(tmp_path, .{}) catch return;
    f.writeAll(val) catch {
        f.close();
        return;
    };
    f.close();
    compat.fs.cwd().rename(tmp_path, final_path) catch return;
    std.debug.print("FASTSYNC: wrote tsf/fastsync.request unix={d}\n", .{unix});
}

fn fastsyncClearOverrides(home_dir: []const u8) void {
    const alloc = std.heap.page_allocator;
    // Remove capture.rotate_mb
    const cap_path = std.fs.path.join(alloc, &[_][]const u8{ home_dir, "capture.rotate_mb" }) catch return;
    defer alloc.free(cap_path);
    compat.fs.cwd().deleteFile(cap_path) catch {};
    // Remove backfill_override.json
    const bf_path = std.fs.path.join(alloc, &[_][]const u8{ home_dir, "baey", "backfill_override.json" }) catch return;
    defer alloc.free(bf_path);
    compat.fs.cwd().deleteFile(bf_path) catch {};
    // Remove tsf/fastsync.request
    const tsf_path = std.fs.path.join(alloc, &[_][]const u8{ home_dir, "tsf", "fastsync.request" }) catch return;
    defer alloc.free(tsf_path);
    compat.fs.cwd().deleteFile(tsf_path) catch {};
    std.debug.print("FASTSYNC: cleared overrides\n", .{});
}

pub fn run(
    alloc: std.mem.Allocator,
    host: []const u8,
    port: u16,
    callbacks: Callbacks,
    ctx_any: *anyopaque,
) !void {
    const ctx = @as(*Context, @ptrCast(@alignCast(ctx_any)));
    const use_relay_list = ctx.network_magic == 764824073; // mainnet magic

    // PRIMARY LIFECYCLE OBSERVABILITY (fix/primary-follower-lifecycle-observability)
    // Unconditional logs at every stage between task entry and recv-loop entry.
    // OBSERVABILITY-ONLY — no semantic changes.
    std.debug.print(
        "PRIMARY_TASK_ENTER: host={s} port={d} network_magic={d} use_relay_list={s}\n",
        .{ host, port, ctx.network_magic, if (use_relay_list) "true" else "false" },
    );
    // Defer an unconditional task-exit log so we see if the task ever returns.
    defer std.debug.print("PRIMARY_TASK_EXIT: function pub fn run() returning\n", .{});
    // Final function-scope defer marker. Registered immediately after
    // PRIMARY_TASK_EXIT, so in LIFO it fires immediately BEFORE TASK_EXIT.
    // Seeing this means every other run() defer unwound without aborting.
    defer std.debug.print("DEFER_GROUP_RUN_DEFERS_DONE\n", .{});

    // Open LMDB shadow store if TSUNAGI_LMDB is set
    if (compat.getEnvVarOwned(alloc, "TSUNAGI_LMDB") catch null) |path| {
        defer alloc.free(path);
        const path_z = alloc.dupeZ(u8, path) catch null;
        defer if (path_z) |pz| alloc.free(pz);
        if (path_z) |pz| {
            ctx.lmdb = lmdb_utxo.LmdbUtxo.open(pz) catch |err| blk: {
                std.debug.print("LMDB: open failed: {s}\n", .{@errorName(err)});
                break :blk null;
            };
            if (ctx.lmdb != null) {
                std.debug.print("LMDB: shadow store opened at {s}\n", .{path});
                // Wire UTxO existence check into mempool for input validation
                g_lmdb_for_mempool = if (ctx.lmdb) |*l| l else null;
                const mempool_mod = @import("../ledger/mempool.zig");
                mempool_mod.g_utxo_lookup_fn = &lmdbUtxoLookup;
                mempool_mod.g_current_slot_fn = &currentSlotProvider;
            }
        }
    }

    // Open header chain store if LMDB is available
    if (ctx.lmdb) |lmdb| {
        ctx.header_store = header_store_mod.HeaderStore.open(lmdb.env) catch |err| blk: {
            std.debug.print("HEADER STORE: open failed: {s}\n", .{@errorName(err)});
            break :blk null;
        };
        if (ctx.header_store) |*hs| {
            // Phase B'''': synchronous slot_index rebuild before chain-sync
            // subscription. Idempotent via SLOT_INDEX_SCHEMA sentinel — fast
            // path returns immediately on already-migrated envs. The post-fix
            // binary writes delivered-domain slot_index keys; pre-existing
            // peer-tip-domain entries are walked, re-keyed by parsed
            // delivered slot from header_cbor, and the sentinel is set.
            const parseShim = struct {
                fn call(cbor_bytes: []const u8) ?header_store_mod.HeaderStore.ParsedHeaderFields {
                    const f = parseHeaderSlotAndBlockNo(cbor_bytes) orelse return null;
                    return .{ .slot = f.slot, .block_no = f.block_no };
                }
            };
            hs.rebuildSlotIndexIfNeeded(&parseShim.call) catch |err| {
                std.debug.print("SLOT_INDEX_REBUILD: failed err={s}\n", .{@errorName(err)});
            };
            if (hs.beginRead()) |rtxn0| {
                var rtxn = rtxn0;
                defer hs.abort(&rtxn);
                if (hs.getHead(&rtxn)) |head| {
                    ctx.header_head = head;
                    // Initialize last_header_slot/block_no from HEAD record
                    if (hs.getHeader(&rtxn, head)) |rec| {
                        ctx.last_header_slot = rec.slot;
                        ctx.last_header_block_no = rec.block_no;
                    }
                }
                ctx.header_height = hs.getHeight(&rtxn);
            }
            std.debug.print("HEADER STORE: opened height={d} last_slot={d} last_block={d}\n", .{ ctx.header_height, ctx.last_header_slot, ctx.last_header_block_no });
            if (ctx.metrics) |metrics_any| {
                const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
                m.header_height.store(ctx.header_height, .release);
            }
        }
    }

    // Initialize strict ledger mode if env is set
    if (ledgerStrictEnabled()) {
        ctx.strict_active = true;
        ctx.strict_start_unix = compat.timestamp();
        std.debug.print("STRICT MODE: enabled (auto-expire 600s)\n", .{});
    }

    // Initialize shadow ledger pipeline if TSUNAGI_LEDGER_SHADOW=1
    if (ledgerShadowEnabled()) {
        const shadow = alloc.create(ledger_pipeline.Pipeline) catch null;
        if (shadow) |s| {
            s.* = ledger_pipeline.Pipeline.init(alloc, .memory_only, null);
            ctx.shadow_pipeline = s;
            std.debug.print("SHADOW LEDGER: enabled (memory_only, advisory)\n", .{});
        }
    }
    // DEFER GROUP: SHADOW_LEDGER — bracketed for crash localization.
    // LIFO registration: END registered first (fires last), BEGIN last
    // (fires first). At unwind we therefore see, in order:
    //   DEFER_GROUP_SHADOW_LEDGER_BEGIN
    //   <shadowShutdownSummary runs>
    //   DEFER_GROUP_SHADOW_LEDGER_END
    // If BEGIN prints but END does not, the abort is inside
    // shadowShutdownSummary.
    defer std.debug.print("DEFER_GROUP_SHADOW_LEDGER_END\n", .{});
    defer shadowShutdownSummary(ctx, alloc);
    defer std.debug.print("DEFER_GROUP_SHADOW_LEDGER_BEGIN\n", .{});

    // Initialize primary ledger pipeline if TSUNAGI_LEDGER_PRIMARY=1
    if (ledgerPrimaryEnabled()) {
        const mode = ledgerPrimaryMode();
        const mode_name: []const u8 = switch (mode) {
            .memory_only => "memory_only",
            .lmdb_truth => "lmdb_truth",
            .lmdb_native => "lmdb_native",
        };

        // LMDB modes require ctx.lmdb — refuse to silently downgrade
        const needs_lmdb = (mode == .lmdb_truth or mode == .lmdb_native);
        if (needs_lmdb and ctx.lmdb == null) {
            std.debug.print("PRIMARY LEDGER: configuration error — mode={s} requires TSUNAGI_LMDB but ctx.lmdb is null; primary pipeline NOT enabled\n", .{mode_name});
        } else {
            const store_ptr: ?*lmdb_utxo.LmdbUtxo = if (needs_lmdb)
                if (ctx.lmdb) |*s| s else null
            else
                null;
            const pp = alloc.create(ledger_pipeline.Pipeline) catch null;
            if (pp) |p| {
                p.* = ledger_pipeline.Pipeline.init(alloc, mode, store_ptr);
                ctx.primary_pipeline = p;
                std.debug.print("PRIMARY LEDGER: enabled ({s})\n", .{mode_name});
            }
        }
    }
    // DEFER GROUP: PRIMARY_LEDGER — bracketed for crash localization.
    // Registered last among the function-scope ledger defers, so in LIFO
    // it is the FIRST to fire at run() exit. At unwind we see, in order:
    //   DEFER_GROUP_PRIMARY_LEDGER_BEGIN
    //   <primaryShutdownSummary runs>
    //   DEFER_GROUP_PRIMARY_LEDGER_END
    // If BEGIN prints but END does not, the abort is inside
    // primaryShutdownSummary.
    defer std.debug.print("DEFER_GROUP_PRIMARY_LEDGER_END\n", .{});
    defer primaryShutdownSummary(ctx, alloc);
    defer std.debug.print("DEFER_GROUP_PRIMARY_LEDGER_BEGIN\n", .{});

    var should_stop = false;
    try installSignalHandlers(&should_stop);

    // Expose metrics pointer to mini-protocol modules
    if (ctx.metrics) |metrics_any| {
        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
        blockfetch.g_metrics = m;
        txsubmission.g_metrics = m;
        keepalive.g_metrics = m;
    }

    var peer_was_closed = false;
    var score = initPeerScore();
    var current_relay_idx: usize = if (ctx.preferred_peer_idx) |ppi| blk: {
        ctx.preferred_peer_idx = null;
        break :blk ppi;
    } else pickRelay(&score, ctx.metrics);
    var connect_attempt: u64 = 0;
    var backoff_seconds: u64 = 2;
    const max_backoff_seconds: u64 = 60;
    var backoff_reset_pending = false;
    // Full-jitter backoff attempt counter (AWS pattern). Resets on successful sync.
    var backoff_attempt: u32 = 0;
    var last_blockfetch_trigger_block: u64 = 0; // Track last block that triggered BlockFetch (survives reconnects)

    // Capture allocator baseline before main loop
    counting_allocator.captureBaseline();

    // FastSync controller init
    {
        const fs_env = compat.getEnvVarOwned(alloc, "TSUNAGI_FASTSYNC") catch null;
        if (fs_env) |v| {
            defer alloc.free(v);
            if (v.len > 0 and !std.mem.eql(u8, v, "0")) {
                ctx.fastsync_enabled = true;
                // Resolve TSUNAGI_HOME for marker files
                const home_dir = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch null;
                if (home_dir) |hd| {
                    ctx.fastsync_home_dir = hd; // leak-owned, lives for process lifetime
                }
                if (ctx.metrics) |ma| {
                    const fsm = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                    fsm.fastsync_enabled.store(1, .release);
                    fsm.fastsync_state_code.store(1, .release); // start in WARMUP
                }
                ctx.fastsync_state = 1;
                std.debug.print("FASTSYNC: enabled (TSUNAGI_HOME={s})\n", .{ctx.fastsync_home_dir orelse "unset"});
            }
        }
    }

    // PRIMARY LIFECYCLE OBSERVABILITY: about to enter reconnect loop
    std.debug.print(
        "PRIMARY_RECONNECT_LOOP_START: connect_attempt_initial={d} backoff_seconds={d}\n",
        .{ connect_attempt, backoff_seconds },
    );

    reconnect: while (true) {
        // PRIMARY LIFECYCLE OBSERVABILITY: every reconnect-loop iteration
        std.debug.print(
            "PRIMARY_RECONNECT_LOOP_ITER: attempt={d} backoff_seconds={d} backoff_attempt={d}\n",
            .{ connect_attempt + 1, backoff_seconds, backoff_attempt },
        );
        peer_was_closed = false;
        keepalive.reset();
        txsubmission.reset();
        ctx.density_window_start_slot = 0;
        ctx.density_window_block_count = 0;
        ctx.rollback_window_start_unix = 0;
        ctx.rollback_window_count = 0;
        ctx.rollback_window_depth_sum = 0;
        ctx.rollback_window_depth_max = 0;
        // Authority stability gate: suppress false instability after reconnect
        ctx.authority_stable_gate_unix = compat.timestamp();
        ctx.authority_stable_gate_active = true;
        ctx.probe_result_ready.store(false, .release);
        ctx.last_roll_fwd_unix = 0;
        ctx.stall_active = false;
        // Apply preferred peer if chain selection set one
        if (ctx.preferred_peer_idx) |ppi| {
            current_relay_idx = ppi;
            ctx.preferred_peer_idx = null;
        }
        connect_attempt += 1;
        if (ctx.undo_stack) |us| {
            std.debug.print("UNDO: depth at reconnect = {d}\n", .{us.items.len});
        }

        const actual_host: []const u8 = blk: {
            if (use_relay_list) {
                break :blk mainnet_relays[current_relay_idx].host;
            }
            break :blk host;
        };
        const actual_port: u16 = blk: {
            if (use_relay_list) {
                break :blk mainnet_relays[current_relay_idx].port;
            }
            break :blk port;
        };

        std.debug.print("NET: connect begin peer={s}:{d} attempt={d} backoff={d}s\n", .{
            actual_host,
            actual_port,
            connect_attempt,
            backoff_seconds,
        });

        // PRIMARY LIFECYCLE OBSERVABILITY: about to TCP-connect
        std.debug.print(
            "PRIMARY_TCP_CONNECT_BEGIN: host={s} port={d}\n",
            .{ actual_host, actual_port },
        );

        const connect_t0 = compat.nanoTimestamp();
        var bt = tcp_bt.connect(alloc, actual_host, actual_port) catch |err| {
            std.debug.print("NET: connect failed: {s}\n", .{@errorName(err)});
            // PRIMARY LIFECYCLE: explicit failure log with reason
            std.debug.print(
                "PRIMARY_TCP_CONNECT_FAIL: host={s} port={d} err={s} → reconnect\n",
                .{ actual_host, actual_port, @errorName(err) },
            );
            _ = penalizePeerRateLimited(&score, current_relay_idx, 1.0, .connect_fail, compat.timestamp(), ctx.metrics);
            if (jitterBackoffSleep(backoff_attempt, max_backoff_seconds, 1, &should_stop)) {
                std.debug.print("PRIMARY_RECONNECT_LOOP_EXIT: reason=tcp_connect_fail_then_stop\n", .{});
                break :reconnect;
            }
            backoff_attempt +|= 1;
            backoff_seconds = @min(backoff_seconds * 2, max_backoff_seconds);
            current_relay_idx = pickRelay(&score, ctx.metrics);
            continue;
        };
        defer bt.deinit();

        std.debug.print("NET: connect ok\n", .{});
        // PRIMARY LIFECYCLE: TCP connect succeeded
        std.debug.print(
            "PRIMARY_TCP_CONNECT_OK: host={s} port={d}\n",
            .{ actual_host, actual_port },
        );

        // Connection registry: register the outgoing connection. Format
        // "host:port" so duplex matching against incoming entries works
        // when the same remote peer connects back.
        var reg_addr_buf: [128]u8 = undefined;
        const reg_addr = std.fmt.bufPrint(&reg_addr_buf, "{s}:{d}", .{ actual_host, actual_port }) catch reg_addr_buf[0..0];
        var registry_id: u64 = connection_registry.register(.outgoing, reg_addr);
        // Tear-down on every loop exit. Even if peer_was_closed isn't set
        // (e.g. shutdown_requested), we still want to drop the registry slot.
        defer if (registry_id != 0) {
            connection_registry.unregister(registry_id);
            registry_id = 0;
        };

        // Set bounded read timeout for handshake phase (30s).
        // Without this, doHandshake can hang indefinitely if the
        // remote accepts TCP but never sends a handshake response.
        tcp_bt.setReadTimeout(&bt, 30_000) catch {};

        // Record reconnect duration
        {
            const connect_elapsed = compat.nanoTimestamp() - connect_t0;
            const ns: u128 = if (connect_elapsed <= 0) 0 else @bitCast(connect_elapsed);
            if (ctx.metrics) |metrics_any| {
                const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
                m.perf_reconnect_ms.store(@truncate(ns / 1_000_000), .release);
                m.perf_reconnect_us.store(@truncate(ns / 1_000), .release);
            }
        }

        var tps_meter = tps.TpsMeter.init(compat.timestamp());
        var last_body_debug_prefix: ?[8]u8 = null;
        var force_debug_rollforwards: u8 = 2;
        var blockfetch_once: bool = false;

        var last_tip: ?cbor.Term = null;
        defer if (last_tip) |tip| {
            cbor.free(tip, alloc);
        };

        // PRIMARY LIFECYCLE OBSERVABILITY: about to handshake
        std.debug.print(
            "PRIMARY_HANDSHAKE_BEGIN: host={s} port={d} network_magic={d}\n",
            .{ actual_host, actual_port, ctx.network_magic },
        );

        const accepted = doHandshake(alloc, &bt, ctx.network_magic, ctx.peer_sharing) catch |err| {
            std.debug.print("NET: handshake error: {s}\n", .{@errorName(err)});
            // PRIMARY LIFECYCLE: handshake threw an error
            std.debug.print(
                "PRIMARY_HANDSHAKE_FAIL: host={s} port={d} err={s} → reconnect\n",
                .{ actual_host, actual_port, @errorName(err) },
            );
            _ = penalizePeerRateLimited(&score, current_relay_idx, 1.0, .handshake_fail, compat.timestamp(), ctx.metrics);
            if (jitterBackoffSleep(backoff_attempt, max_backoff_seconds, 1, &should_stop)) {
                std.debug.print("PRIMARY_RECONNECT_LOOP_EXIT: reason=handshake_err_then_stop\n", .{});
                break :reconnect;
            }
            backoff_attempt +|= 1;
            backoff_seconds = @min(backoff_seconds * 2, max_backoff_seconds);
            current_relay_idx = pickRelay(&score, ctx.metrics);
            continue; // reconnect loop
        };

        if (!accepted) {
            std.debug.print("NET: handshake not accepted (no response)\n", .{});
            // PRIMARY LIFECYCLE: handshake returned but not accepted
            std.debug.print(
                "PRIMARY_HANDSHAKE_REFUSED: host={s} port={d} → reconnect\n",
                .{ actual_host, actual_port },
            );
            _ = penalizePeerRateLimited(&score, current_relay_idx, 1.0, .handshake_fail, compat.timestamp(), ctx.metrics);
            if (jitterBackoffSleep(backoff_attempt, max_backoff_seconds, 1, &should_stop)) {
                std.debug.print("PRIMARY_RECONNECT_LOOP_EXIT: reason=handshake_refused_then_stop\n", .{});
                break :reconnect;
            }
            backoff_attempt +|= 1;
            backoff_seconds = @min(backoff_seconds * 2, max_backoff_seconds);
            current_relay_idx = pickRelay(&score, ctx.metrics);
            continue; // reconnect loop
        }

        // PRIMARY LIFECYCLE: handshake accepted, beyond connect/handshake stage
        std.debug.print(
            "PRIMARY_HANDSHAKE_OK: host={s} port={d}\n",
            .{ actual_host, actual_port },
        );

        if (callbacks.on_peer_connect) |cb| cb(ctx_any, actual_host, actual_port);
        connection_registry.markHandshakeDone(registry_id);

        // Restore normal timeout after handshake
        const timeout_ms: u32 = 10_000;
        tcp_bt.setReadTimeout(&bt, timeout_ms) catch {};

        // INTERSECT_NOT_FOUND RECOVERY (2026-05-20, operator-ratified):
        // Build a multi-point FindIntersect from authenticated local ancestry
        // (cursor + header_store walk at the depth ladder). Send all candidates
        // in ONE FindIntersect; relay selects the deepest matching point. If
        // none match, the .intersect_not_found handler performs an in-connection
        // origin fallback (one shot). READ-ONLY; cursor.json is NEVER mutated here.
        var recovery_buf: [MAX_INTERSECT_POINTS]RecoveryPoint = undefined;
        const recovery_n = collectIntersectPoints(ctx, &recovery_buf);

        std.debug.print(
            "PRIMARY_INTERSECT_RECOVERY_BEGIN: candidate_count={d}\n",
            .{recovery_n},
        );

        const used_cursor_point = recovery_n > 0 and recovery_buf[0].source == .cursor;
        var intersect_recovery_attempted = false; // tracks if origin fallback has been sent this connection

        // OWNERSHIP DISCIPLINE — RECOVERY POINT BUFFERS (reconnect-loop-body scope):
        //   hash_dupes[i]   — heap, OWNED here; allocated by alloc.dupe; freed by the
        //                     defer below. Each entry is freed AT MOST ONCE because the
        //                     defer iterates [0..hash_dupes_count) and the post-free
        //                     zeroing turns any accidental re-fire into a visible empty
        //                     slice (not a double-free).
        //   pair_storage[]  — stack, NOT owned (no free needed); slices into it are
        //                     consumed synchronously by encodeFindIntersect.
        //   points_storage[]— stack, NOT owned.
        //   cbor.Term.bytes — borrows hash_dupes[i] (not owner); MUST not outlive
        //                     hash_dupes[i]; encoder consumes synchronously below.
        var hash_dupes: [MAX_INTERSECT_POINTS][]u8 = undefined;
        var hash_dupes_count: usize = 0;
        defer {
            var di: usize = 0;
            while (di < hash_dupes_count) : (di += 1) {
                const buf = hash_dupes[di];
                // Defensive: zero the slot BEFORE free so any concurrent path that
                // also sees the slot can't double-free. (Zig defers are not
                // concurrent, but document the invariant clearly.)
                hash_dupes[di] = &[_]u8{};
                std.debug.print(
                    "PRIMARY_INTERSECT_RECOVERY_BUF_FREE: idx={d} bytes={d}\n",
                    .{ di, buf.len },
                );
                alloc.free(buf);
            }
            hash_dupes_count = 0;
        }

        var pair_storage: [MAX_INTERSECT_POINTS * 2]cbor.Term = undefined;
        var points_storage: [MAX_INTERSECT_POINTS]cbor.Term = undefined;

        {
            var rp_idx: usize = 0;
            while (rp_idx < recovery_n) : (rp_idx += 1) {
                const dup = alloc.dupe(u8, recovery_buf[rp_idx].hash[0..]) catch |err| {
                    std.debug.print(
                        "PRIMARY_INTERSECT_RECOVERY_ALLOC_FAIL: idx={d} err={s} → propagating\n",
                        .{ rp_idx, @errorName(err) },
                    );
                    return err;
                };
                hash_dupes[rp_idx] = dup;
                hash_dupes_count += 1;
                std.debug.print(
                    "PRIMARY_INTERSECT_RECOVERY_BUF_ALLOC: idx={d} bytes={d}\n",
                    .{ rp_idx, dup.len },
                );
                pair_storage[rp_idx * 2 + 0] = .{ .u64 = recovery_buf[rp_idx].slot };
                pair_storage[rp_idx * 2 + 1] = .{ .bytes = dup };
                points_storage[rp_idx] = .{ .array = pair_storage[rp_idx * 2 .. rp_idx * 2 + 2] };

                std.debug.print(
                    "PRIMARY_INTERSECT_RECOVERY_ATTEMPT: idx={d} source={s} slot={d} hash={x} depth={d}\n",
                    .{
                        rp_idx,
                        recoverySourceLabel(recovery_buf[rp_idx]),
                        recovery_buf[rp_idx].slot,
                        recovery_buf[rp_idx].hash[0..8],
                        recovery_buf[rp_idx].depth,
                    },
                );
            }
        }

        const points = cbor.Term{ .array = points_storage[0..recovery_n] };

        if (used_cursor_point) {
            std.debug.print(
                "FindIntersect using cursor point: slot={d} hash={x}\n",
                .{ recovery_buf[0].slot, recovery_buf[0].hash[0..4] },
            );
        } else {
            std.debug.print("FindIntersect using origin (no cursor point)\n", .{});
        }

        // PRIMARY LIFECYCLE: about to allocate + encode + send FindIntersect
        std.debug.print(
            "PRIMARY_FINDINTERSECT_BEGIN: used_cursor_point={s} candidate_count={d}\n",
            .{ if (used_cursor_point) "true" else "false", recovery_n },
        );
        var list = std.array_list.Managed(u8).init(alloc);
        defer list.deinit();
        // No candidate points (fresh start / no cursor) → request ORIGIN with a points list
        // that CONTAINS the origin point ([[]]), not an empty points list ([]). An empty
        // list encodes [4,[]] (3 bytes) which peers reject with IntersectNotFound, so a
        // genuinely empty follower could never intersect at origin.
        const enc_res = if (recovery_n == 0)
            chainsync_codec.encodeFindIntersectOrigin(compat.listWriter(&list))
        else
            chainsync_codec.encodeFindIntersect(compat.listWriter(&list), points);
        enc_res catch |err| {
            std.debug.print(
                "PRIMARY_FINDINTERSECT_ENCODE_FAIL: err={s} → propagating\n",
                .{@errorName(err)},
            );
            return err;
        };
        const msg_bytes = list.toOwnedSlice() catch |err| {
            std.debug.print(
                "PRIMARY_FINDINTERSECT_BYTES_FAIL: err={s} → propagating\n",
                .{@errorName(err)},
            );
            return err;
        };
        defer alloc.free(msg_bytes);
        // PRIMARY LIFECYCLE: encoded successfully
        std.debug.print(
            "PRIMARY_FINDINTERSECT_ENCODED: bytes={d}\n",
            .{msg_bytes.len},
        );

        mux_bearer.sendSegment(&bt, .responder, chainsync_proto, msg_bytes) catch |err| {
            std.debug.print(
                "PRIMARY_FINDINTERSECT_SEND_FAIL: err={s} → propagating\n",
                .{@errorName(err)},
            );
            return err;
        };
        vprint(ctx.debug_verbose, "chainsync: sent FindIntersect ({d} bytes)\n", .{msg_bytes.len});
        // PRIMARY LIFECYCLE: FindIntersect successfully sent
        std.debug.print(
            "PRIMARY_FINDINTERSECT_SENT: bytes={d} proto=chainsync\n",
            .{msg_bytes.len},
        );

        var last_status_unix: i64 = compat.timestamp();
        var shutdown_requested = false;
        const trace_enabled = ctx.debug_verbose or (compat.hasEnvVar(alloc, "TSUNAGI_TRACE"));
        var last_trace_tip: ?[32]u8 = null;

        // PRIMARY LIFECYCLE OBSERVABILITY: about to enter recv loop. THIS IS THE
        // STAGE WE EXPECTED TO REACH. If this log appears but PRIMARY_RECV_HEARTBEAT
        // (from the prior observability commit) does NOT, the loop is entered but
        // recvSegmentWithTimeout never returns TimedOut OR data — likely state-machine
        // wedge. If this log DOES NOT appear, the task exited before recv loop.
        std.debug.print(
            "PRIMARY_RECVLOOP_ENTERED: host={s} port={d} cursor_slot={d} cursor_block={d} trace_enabled={s}\n",
            .{ actual_host, actual_port, ctx.cursor.slot, ctx.cursor.block_no, if (trace_enabled) "true" else "false" },
        );

        outer: while (true) {
            if (checkStop(&should_stop)) {
                shutdown_requested = true;
                break :outer;
            }
            maybePrintStatus(&last_status_unix, callbacks, ctx_any, &ctx.cursor);
            maybeHeartbeatKes(ctx);
            maybeUpdateAutoStrict(ctx);
            keepalive.maybeSendPing(alloc, &bt);
            if (keepalive.takeReconnectSignal(alloc)) {
                const now_ka = compat.timestamp();
                if (now_ka - ctx.last_keepalive_strict_log_unix >= 60) {
                    ctx.last_keepalive_strict_log_unix = now_ka;
                    std.debug.print("KEEPALIVE STRICT: 2 timeouts → reconnect\n", .{});
                }
                if (ctx.metrics) |ma| {
                    const m_ka = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                    _ = m_ka.keepalive_reconnect_total.fetchAdd(1, .acq_rel);
                }
                // BAEY audit
                if (now_ka - ctx.baey_last_keepalive_unix >= 60) {
                    ctx.baey_last_keepalive_unix = now_ka;
                    baeyLog(ctx, "keepalive_strict", "2_consecutive_timeouts", "reconnect", ctx.cursor.slot, ctx.cursor.block_no);
                }
                _ = penalizePeerRateLimited(&score, current_relay_idx, 0.2, .keepalive_timeout, now_ka, ctx.metrics);
                peer_was_closed = true;
                if (callbacks.on_peer_disconnect) |cb| cb(ctx_any, actual_host, actual_port, "keepalive_timeout");
                keepalive.reset();
                break :outer;
            }
            txsubmission.maybeBroadcastInventory(alloc, &bt);
            if (use_relay_list) {
                maybeStartHeaderProbe(ctx, &score, current_relay_idx);
                maybeApplyProbeSwitch(ctx, &score, &current_relay_idx, &peer_was_closed);
                if (peer_was_closed) break :outer;
                maybeCheckStallAndSwitch(ctx, &score, &current_relay_idx, &peer_was_closed);
                if (peer_was_closed) break :outer;
                maybeConsumeBaeySwitchMarker(ctx, &score, &current_relay_idx, &peer_was_closed);
                if (peer_was_closed) break :outer;
            }
            tcp_bt.setReadTimeout(&bt, timeout_ms) catch {};

            const seg = mux_bearer.recvSegmentWithTimeout(alloc, &bt) catch |err| switch (err) {
                error.TimedOut => {
                    // PRIMARY OBSERVABILITY: rate-limited recv-timeout heartbeat (1-in-30s).
                    // Replaces silent `continue` so operator can see the recv loop is alive
                    // but starving for data. No decision change — pure visibility.
                    ctx.primary_recv_timeouts_since_last_log += 1;
                    if (ctx.metrics) |ma_to| {
                        const m_to = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma_to))));
                        _ = m_to.primary_recv_timeouts_total.fetchAdd(1, .acq_rel);
                    }
                    const now_to = compat.timestamp();
                    if (now_to - ctx.primary_last_recv_log_unix >= 30) {
                        ctx.primary_last_recv_log_unix = now_to;
                        std.debug.print(
                            "PRIMARY_RECV_HEARTBEAT: timeouts={d} cursor_slot={d} cursor_block={d} tip_block_last={d} rolls_processed={d} mux_segs_seen={d} intersect={s}\n",
                            .{
                                ctx.primary_recv_timeouts_since_last_log,
                                ctx.cursor.slot,
                                ctx.cursor.block_no,
                                ctx.producer_ctx.tip_block_last,
                                ctx.primary_rollforwards_processed,
                                ctx.primary_mux_segments_seen_since_last_log,
                                if (ctx.primary_intersect_completed) "found" else "awaiting",
                            },
                        );
                        ctx.primary_recv_timeouts_since_last_log = 0;
                        ctx.primary_mux_segments_seen_since_last_log = 0;
                    }
                    continue;
                },
                else => return err,
            };
            if (seg == null) {
                vprint(true, "peer closed\n", .{});
                peer_was_closed = true;
                if (callbacks.on_peer_disconnect) |cb| cb(ctx_any, actual_host, actual_port, "stream_error");
                if (ctx.metrics) |metrics_any| {
                    const metrics = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
                    _ = metrics.peer_closed.fetchAdd(1, .acq_rel);
                }
                _ = penalizePeerRateLimited(&score, current_relay_idx, 0.2, .stream_error, compat.timestamp(), ctx.metrics);
                break :outer;
            }
            defer alloc.free(seg.?.payload);

            const hdr = seg.?.hdr;
            vprint(
                ctx.debug_verbose,
                "mux: rx hdr dir={s} proto={d} len={d}\n",
                .{ @tagName(hdr.dir), hdr.proto, hdr.len },
            );
            // PRIMARY OBSERVABILITY: rate-limited mux segment header summary (1-in-30s,
            // independent of debug_verbose). Shows what proto channels cardano-node
            // is actually pushing on. No decision change.
            ctx.primary_mux_segments_seen_since_last_log += 1;
            {
                const now_mx = compat.timestamp();
                if (now_mx - ctx.primary_last_mux_log_unix >= 30) {
                    ctx.primary_last_mux_log_unix = now_mx;
                    std.debug.print(
                        "PRIMARY_MUX_SEG: dir={s} proto={d} len={d} (sample; segs_seen_window={d})\n",
                        .{ @tagName(hdr.dir), hdr.proto, hdr.len, ctx.primary_mux_segments_seen_since_last_log },
                    );
                }
            }

            // Connection registry: classify the inbound segment by proto
            // so the connection's state derives correctly (hot vs warm).
            // Keepalive-only traffic must NOT promote the peer to hot.
            switch (hdr.proto) {
                chainsync_proto => connection_registry.recordActivity(registry_id, connection_registry.PROTO_CHAINSYNC),
                txsubmission_proto => connection_registry.recordActivity(registry_id, connection_registry.PROTO_TXSUBMISSION),
                keepalive_proto => connection_registry.recordActivity(registry_id, connection_registry.PROTO_KEEPALIVE),
                3 => connection_registry.recordActivity(registry_id, connection_registry.PROTO_BLOCKFETCH),
                else => {},
            }

            if (hdr.proto == chainsync_proto) {
                var fbs = compat.fixedBufferStream(seg.?.payload);
                var msg = try chainsync_codec.decodeResponse(alloc, fbs.reader());
                defer chainsync_codec.free(alloc, &msg);
                // PRIMARY OBSERVABILITY: log decoded chainsync tag unconditionally
                // (one line per chainsync_proto segment). No decision change.
                std.debug.print(
                    "PRIMARY_CHAINSYNC_DECODE: tag={s} payload_len={d}\n",
                    .{ @tagName(msg), seg.?.payload.len },
                );

                switch (msg) {
                    .intersect_found => {
                        vprint(ctx.debug_verbose, "chainsync: intersect found\n", .{});
                        // PRIMARY OBSERVABILITY: explicit intersect_found log + counter.
                        ctx.primary_intersect_completed = true;
                        if (ctx.metrics) |ma_if| {
                            const m_if = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma_if))));
                            _ = m_if.primary_intersect_found_total.fetchAdd(1, .acq_rel);
                        }
                        if (getTipSlotBlock(msg.intersect_found.tip)) |tsb_if| {
                            std.debug.print(
                                "PRIMARY_INTERSECT_FOUND: tip_slot={d} tip_block={d}\n",
                                .{ tsb_if.slot, tsb_if.block_no },
                            );
                            // Recovery-context log: if this IntersectFound followed an
                            // origin fallback, the relay matched origin; otherwise it
                            // matched one of our authenticated multi-point candidates.
                            std.debug.print(
                                "PRIMARY_INTERSECT_RECOVERY_FOUND: matched_via={s} tip_slot={d} tip_block={d}\n",
                                .{
                                    if (intersect_recovery_attempted) "origin_fallback" else "multi_point_ladder",
                                    tsb_if.slot,
                                    tsb_if.block_no,
                                },
                            );
                            // OBSERVABILITY: extract the matched point from IntersectFound and
                            // identify which candidate it corresponded to (cursor / header_store
                            // at depth=D / origin). READ-ONLY; never mutates anything.
                            {
                                const matched = msg.intersect_found.point;
                                if (matched == .array and matched.array.len == 0) {
                                    std.debug.print(
                                        "PRIMARY_RECOVERY_MATCH_SOURCE: origin\n" ++
                                            "PRIMARY_RECOVERY_MATCH_SLOT: 0\n" ++
                                            "PRIMARY_RECOVERY_MATCH_BLOCK: 0\n" ++
                                            "PRIMARY_RECOVERY_MATCH_HASH: (origin)\n",
                                        .{},
                                    );
                                } else if (matched == .array and matched.array.len == 2 and
                                    matched.array[0] == .u64 and matched.array[1] == .bytes)
                                {
                                    const m_slot: u64 = matched.array[0].u64;
                                    const m_hash: []const u8 = matched.array[1].bytes;
                                    var m_source: []const u8 = "unknown";
                                    var m_depth: u32 = 0;
                                    var m_block: u64 = 0;
                                    var rc_i: usize = 0;
                                    while (rc_i < recovery_n) : (rc_i += 1) {
                                        if (recovery_buf[rc_i].slot == m_slot and
                                            m_hash.len == 32 and
                                            std.mem.eql(u8, m_hash, recovery_buf[rc_i].hash[0..]))
                                        {
                                            m_source = recoverySourceLabel(recovery_buf[rc_i]);
                                            m_depth = recovery_buf[rc_i].depth;
                                            break;
                                        }
                                    }
                                    // Look up block_no in header_store if header_store match.
                                    if (std.mem.eql(u8, m_source, "header_store")) {
                                        if (ctx.header_store) |*hs_lk| {
                                            if (hs_lk.beginRead()) |rtxn_v| {
                                                var rtxn = rtxn_v;
                                                defer hs_lk.abort(&rtxn);
                                                var h32: [32]u8 = undefined;
                                                @memcpy(&h32, m_hash[0..32]);
                                                if (hs_lk.getHeader(&rtxn, h32)) |rec| {
                                                    m_block = rec.block_no;
                                                }
                                            }
                                        }
                                    } else if (std.mem.eql(u8, m_source, "cursor")) {
                                        m_block = ctx.cursor.block_no;
                                    }
                                    std.debug.print(
                                        "PRIMARY_RECOVERY_MATCH_SOURCE: {s} depth={d}\n" ++
                                            "PRIMARY_RECOVERY_MATCH_SLOT: {d}\n" ++
                                            "PRIMARY_RECOVERY_MATCH_BLOCK: {d}\n" ++
                                            "PRIMARY_RECOVERY_MATCH_HASH: {x}\n",
                                        .{ m_source, m_depth, m_slot, m_block, m_hash[0..@min(m_hash.len, 16)] },
                                    );
                                } else {
                                    std.debug.print(
                                        "PRIMARY_RECOVERY_MATCH_SOURCE: unrecognized_point_shape\n",
                                        .{},
                                    );
                                    logTipShapeSummary("RECOVERY_MATCH.point", msg.intersect_found.point);
                                }
                            }
                        } else {
                            std.debug.print(
                                "PRIMARY_INTERSECT_FOUND: tip_parse=NULL (tip shape unexpected — see PRIMARY_TIP_PARSE_NULL)\n",
                                .{},
                            );
                            if (ctx.metrics) |ma_pn| {
                                const m_pn = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma_pn))));
                                _ = m_pn.primary_tip_parse_null_total.fetchAdd(1, .acq_rel);
                            }
                            logTipShapeSummary("INTERSECT_FOUND.tip", msg.intersect_found.tip);
                        }
                        try storeTip(alloc, &last_tip, msg.intersect_found.tip);
                        backoff_reset_pending = true;

                        var req_list = std.array_list.Managed(u8).init(alloc);
                        defer req_list.deinit();
                        try chainsync_codec.encodeRequestNext(compat.listWriter(&req_list));
                        const req_bytes = try req_list.toOwnedSlice();
                        defer alloc.free(req_bytes);

                        var steps: u64 = 0;
                        while (true) : (steps += 1) {
                            if (checkStop(&should_stop)) {
                                shutdown_requested = true;
                                break :outer;
                            }
                            maybePrintStatus(&last_status_unix, callbacks, ctx_any, &ctx.cursor);
                            try mux_bearer.sendSegment(&bt, .responder, chainsync_proto, req_bytes);

                            var awaiting_reply = true;
                            while (awaiting_reply) {
                                if (checkStop(&should_stop)) {
                                    shutdown_requested = true;
                                    break :outer;
                                }
                                maybePrintStatus(&last_status_unix, callbacks, ctx_any, &ctx.cursor);
                                maybeHeartbeatKes(ctx);
                                keepalive.maybeSendPing(alloc, &bt);
                                if (keepalive.takeReconnectSignal(alloc)) {
                                    const now_ka = compat.timestamp();
                                    if (now_ka - ctx.last_keepalive_strict_log_unix >= 60) {
                                        ctx.last_keepalive_strict_log_unix = now_ka;
                                        std.debug.print("KEEPALIVE STRICT: 2 timeouts → reconnect\n", .{});
                                    }
                                    if (ctx.metrics) |ma| {
                                        const m_ka = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                                        _ = m_ka.keepalive_reconnect_total.fetchAdd(1, .acq_rel);
                                    }
                                    // BAEY audit
                                    if (now_ka - ctx.baey_last_keepalive_unix >= 60) {
                                        ctx.baey_last_keepalive_unix = now_ka;
                                        baeyLog(ctx, "keepalive_strict", "2_consecutive_timeouts", "reconnect", ctx.cursor.slot, ctx.cursor.block_no);
                                    }
                                    _ = penalizePeerRateLimited(&score, current_relay_idx, 0.2, .keepalive_timeout, now_ka, ctx.metrics);
                                    peer_was_closed = true;
                                    keepalive.reset();
                                    break :outer;
                                }
                                txsubmission.maybeBroadcastInventory(alloc, &bt);
                                if (use_relay_list) {
                                    maybeStartHeaderProbe(ctx, &score, current_relay_idx);
                                    maybeApplyProbeSwitch(ctx, &score, &current_relay_idx, &peer_was_closed);
                                    if (peer_was_closed) break :outer;
                                    maybeCheckStallAndSwitch(ctx, &score, &current_relay_idx, &peer_was_closed);
                                    if (peer_was_closed) break :outer;
                                    maybeConsumeBaeySwitchMarker(ctx, &score, &current_relay_idx, &peer_was_closed);
                                    if (peer_was_closed) break :outer;
                                }
                                tcp_bt.setReadTimeout(&bt, timeout_ms) catch {};

                                const next_seg = mux_bearer.recvSegmentWithTimeout(alloc, &bt) catch |err| switch (err) {
                                    error.TimedOut => continue,
                                    else => return err,
                                };
                                if (next_seg == null) {
                                    vprint(true, "peer closed\n", .{});
                                    peer_was_closed = true;
                                    if (ctx.metrics) |metrics_any| {
                                        const metrics = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
                                        _ = metrics.peer_closed.fetchAdd(1, .acq_rel);
                                    }
                                    _ = penalizePeerRateLimited(&score, current_relay_idx, 0.2, .stream_error, compat.timestamp(), ctx.metrics);
                                    break :outer;
                                }
                                defer alloc.free(next_seg.?.payload);

                                const next_hdr = next_seg.?.hdr;
                                vprint(
                                    ctx.debug_verbose,
                                    "mux: rx hdr dir={s} proto={d} len={d}\n",
                                    .{ @tagName(next_hdr.dir), next_hdr.proto, next_hdr.len },
                                );

                                if (next_hdr.proto == chainsync_proto) {
                                    // Per-message arena: all transient CBOR decode trees are
                                    // bulk-freed when the arena is destroyed at block exit,
                                    // preventing malloc fragmentation during catch-up sync.
                                    var cs_arena = std.heap.ArenaAllocator.init(alloc);
                                    defer cs_arena.deinit();
                                    const a = cs_arena.allocator();

                                    var next_fbs = compat.fixedBufferStream(next_seg.?.payload);
                                    const next_msg = try chainsync_codec.decodeResponse(a, next_fbs.reader());
                                    // No defer free — arena.deinit() bulk-frees all decode trees

                                    switch (next_msg) {
                                        .await_reply => {
                                            vprint(ctx.debug_verbose, "chainsync[{d}]: await reply\n", .{steps});
                                            awaiting_reply = true;
                                        },
                                        .roll_forward => {
                                            vprint(ctx.debug_verbose, "chainsync[{d}]: roll forward\n", .{steps});
                                            try storeTip(alloc, &last_tip, next_msg.roll_forward.tip);

                                            if (backoff_reset_pending) {
                                                backoff_reset_pending = false;
                                                backoff_seconds = 2;
                                                backoff_attempt = 0;
                                                if (ctx.debug_verbose) {
                                                    std.debug.print("NET: backoff reset (successful sync)\n", .{});
                                                }
                                            }

                                            const tip_info = getTipSlotBlock(next_msg.roll_forward.tip);
                                            const tip_slot: u64 = if (tip_info) |info| info.slot else 0;
                                            const tip_block: u64 = if (tip_info) |info| info.block_no else 0;

                                            var tip_hash32_value: [32]u8 = std.mem.zeroes([32]u8);
                                            var has_tip_hash = false;
                                            if (tipHash32(next_msg.roll_forward.tip)) |hash| {
                                                tip_hash32_value = hash;
                                                has_tip_hash = true;
                                            }

                                            var full_block_bytes: []const u8 = &[_]u8{};
                                            var inner_bytes_owned: ?[]u8 = null;
                                            const inner_bytes = blk: {
                                                const block = next_msg.roll_forward.block;
                                                if (block != .array) break :blk &[_]u8{};
                                                const items = block.array;
                                                if (items.len < 2) break :blk &[_]u8{};

                                                const block_bytes = blk_bytes: {
                                                    if (items[1] == .bytes) break :blk_bytes items[1].bytes;
                                                    if (items[1] == .tag and
                                                        items[1].tag.tag == 24 and
                                                        items[1].tag.value.* == .bytes)
                                                    {
                                                        break :blk_bytes items[1].tag.value.*.bytes;
                                                    }
                                                    // Mainnet: items[1] is array, encode to bytes
                                                    if (items[1] == .array or items[1] == .map_u64) {
                                                        var buf = std.array_list.Managed(u8).init(a);
                                                        defer buf.deinit();
                                                        cbor.encode(items[1], compat.listWriter(&buf)) catch break :blk &[_]u8{};
                                                        const dup = a.dupe(u8, buf.items) catch break :blk &[_]u8{};
                                                        inner_bytes_owned = dup;
                                                        break :blk_bytes dup;
                                                    }
                                                    break :blk &[_]u8{};
                                                };

                                                full_block_bytes = block_bytes;
                                                break :blk header_raw.getTag24InnerBytes(block_bytes) orelse block_bytes;
                                            };
                                            const header_hash32_value =
                                                computeHeaderHash32(a, inner_bytes) orelse std.mem.zeroes([32]u8);

                                            // Header validation: hash + prev linkage (observability-first)
                                            if (!validateHeaderOnRollForward(ctx, a, inner_bytes, header_hash32_value, tip_slot, tip_block)) {
                                                if (headerStrictEnabled()) {
                                                    peer_was_closed = true;
                                                }
                                            }

                                            // Parent tuple for producer: use delivered block identity.
                                            const delivered_fields = parseHeaderSlotAndBlockNo(inner_bytes);
                                            const parent_slot_for_tick = if (delivered_fields) |f| f.slot else tip_slot;
                                            const parent_block_for_tick = if (delivered_fields) |f| f.block_no else tip_block;
                                            const parent_hash_for_tick: [32]u8 = header_hash32_value;

                                            // Extract prev_hash up-front so it can be plumbed into
                                            // updateRxFromPeer for the Stage-2 1-step parent rule
                                            // (selectFreshestParent). Also reused by the ancestry-gated
                                            // delta path below.
                                            const delivered_prev_hash = extractPrevHashFromRaw(a, inner_bytes);

                                            // Update rx_*_last IMMEDIATELY — this is the freshest
                                            // known block, before any apply or disk write.
                                            // Serialized via producer.updateRxFromPeer so the
                                            // Phase 8 peer probe can write these fields without
                                            // tearing the 32-byte hash.
                                            producer.updateRxFromPeer(
                                                &ctx.producer_ctx,
                                                "primary",
                                                parent_slot_for_tick,
                                                parent_block_for_tick,
                                                parent_hash_for_tick,
                                                delivered_prev_hash,
                                            );

                                            // Header chain authority: validate linkage + store
                                            if (ctx.header_store) |*hs| header_blk: {
                                                const prev_hash_opt = extractPrevHashFromRaw(a, inner_bytes);
                                                const prev_hash = prev_hash_opt orelse std.mem.zeroes([32]u8);
                                                const prev_missing = prev_hash_opt == null;

                                                if (prev_missing) {
                                                    // Extraction not confident — skip validation, store with zeroes
                                                    if (ctx.metrics) |ma| {
                                                        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                                                        _ = m.header_prevhash_missing.fetchAdd(1, .acq_rel);
                                                    }
                                                    ctx.header_chain_mismatch_streak = 0;
                                                } else if (ctx.header_head) |head| {
                                                    if (!std.mem.eql(u8, prev_hash[0..], head[0..])) {
                                                        const now_hc = compat.timestamp();
                                                        if (now_hc < ctx.rollback_stabilize_until_unix) {
                                                            // v1.5.9: Stabilization window — suppress mismatch
                                                            ctx.header_chain_mismatch_streak = 0;
                                                            ctx.header_stable_consecutive = 0;
                                                            if (ctx.metrics) |ma| {
                                                                const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                                                                _ = m.rollback_stabilize_suppressed_total.fetchAdd(1, .acq_rel);
                                                            }
                                                            if (now_hc - ctx.last_rollback_stabilize_log_unix >= 60) {
                                                                ctx.last_rollback_stabilize_log_unix = now_hc;
                                                                std.debug.print(
                                                                    "HEADER STABILIZE: suppressed mismatch slot={d} block={d} remaining={d}s\n",
                                                                    .{ tip_slot, tip_block, ctx.rollback_stabilize_until_unix - now_hc },
                                                                );
                                                            }
                                                            // Fall through to head update (do NOT break :header_blk)
                                                        } else {
                                                            // Clear stabilization gauge on expiry
                                                            if (ctx.rollback_stabilize_until_unix > 0) {
                                                                ctx.rollback_stabilize_until_unix = 0;
                                                                if (ctx.metrics) |ma| {
                                                                    const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                                                                    m.rollback_stabilize_active.store(0, .release);
                                                                }
                                                            }
                                                            // Normal mismatch path (existing logic unchanged)
                                                            ctx.header_chain_mismatch_streak += 1;
                                                            ctx.header_stable_consecutive = 0;
                                                            if (ctx.header_head_stable) {
                                                                if (ctx.metrics) |ma| {
                                                                    const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                                                                    _ = m.header_chain_errors.fetchAdd(1, .acq_rel);
                                                                }
                                                            }
                                                            if (now_hc - ctx.last_header_chain_error_log_unix >= 60) {
                                                                ctx.last_header_chain_error_log_unix = now_hc;
                                                                std.debug.print("HEADER CHAIN ERROR: prev!=head slot={d} block={d} prev={x} head={x} streak={d}\n", .{
                                                                    tip_slot,
                                                                    tip_block,
                                                                    prev_hash[0..4],
                                                                    head[0..4],
                                                                    ctx.header_chain_mismatch_streak,
                                                                });
                                                            }
                                                            if (ctx.header_chain_mismatch_streak >= 3) {
                                                                std.debug.print("HEADER CHAIN: 3-strike reset, clearing head\n", .{});
                                                                ctx.header_head = null;
                                                                ctx.header_head_stable = false;
                                                                ctx.header_stable_consecutive = 0;
                                                                peer_was_closed = true;
                                                                ctx.header_chain_mismatch_streak = 0;
                                                                if (ctx.metrics) |ma2| {
                                                                    const m2 = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma2))));
                                                                    _ = m2.header_mismatch_reconnects.fetchAdd(1, .acq_rel);
                                                                }
                                                            }
                                                            break :header_blk;
                                                        }
                                                    } else {
                                                        ctx.header_chain_mismatch_streak = 0;
                                                        ctx.header_stable_consecutive += 1;
                                                        if (ctx.header_stable_consecutive >= 2 and !ctx.header_head_stable) {
                                                            ctx.header_head_stable = true;
                                                            if (ctx.metrics) |ma3| {
                                                                const m3 = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma3))));
                                                                m3.header_head_stable.store(1, .release);
                                                            }
                                                        }
                                                        // Clear stabilization gauge on expiry (match path)
                                                        if (ctx.rollback_stabilize_until_unix > 0 and compat.timestamp() >= ctx.rollback_stabilize_until_unix) {
                                                            ctx.rollback_stabilize_until_unix = 0;
                                                            if (ctx.metrics) |ma4| {
                                                                const m4 = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma4))));
                                                                m4.rollback_stabilize_active.store(0, .release);
                                                            }
                                                        }
                                                    }
                                                } else {
                                                    // No head yet (bootstrap) — accept without validation
                                                    ctx.header_chain_mismatch_streak = 0;
                                                    ctx.header_stable_consecutive = 0;
                                                }

                                                // Monotonicity invariants (slot + block_no must not decrease on forward)
                                                {
                                                    var violation = false;
                                                    const now_inv = compat.timestamp();
                                                    const can_log = (now_inv - ctx.last_header_violation_log_unix >= 60);

                                                    if (ctx.last_header_slot != 0 and tip_slot < ctx.last_header_slot) {
                                                        if (ctx.metrics) |ma| {
                                                            const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                                                            _ = m.header_slot_violation.fetchAdd(1, .acq_rel);
                                                        }
                                                        if (can_log) {
                                                            ctx.last_header_violation_log_unix = now_inv;
                                                            std.debug.print("HEADER SLOT VIOLATION: last={d} got={d} block={d}\n", .{ ctx.last_header_slot, tip_slot, tip_block });
                                                        }
                                                        violation = true;
                                                    }

                                                    if (ctx.last_header_block_no != 0 and tip_block < ctx.last_header_block_no) {
                                                        if (ctx.metrics) |ma| {
                                                            const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                                                            _ = m.header_block_violation.fetchAdd(1, .acq_rel);
                                                        }
                                                        if (can_log) {
                                                            ctx.last_header_violation_log_unix = now_inv;
                                                            std.debug.print("HEADER BLOCK VIOLATION: last={d} got={d} slot={d}\n", .{ ctx.last_header_block_no, tip_block, tip_slot });
                                                        }
                                                        violation = true;
                                                    }

                                                    if (violation) {
                                                        peer_was_closed = true;
                                                        break :header_blk;
                                                    }
                                                }

                                                // Phase B'''' D-3: parse-or-refuse. If the delivered
                                                // header cannot be parsed for slot/block_no, refuse to
                                                // store rather than fall back to peer-tip values (which
                                                // would re-introduce the cross-domain footgun).
                                                if (delivered_fields == null) {
                                                    if (ctx.metrics) |ma| {
                                                        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                                                        _ = m.tsunagi_header_parse_refused_total.fetchAdd(1, .acq_rel);
                                                    }
                                                    std.debug.print("HEADER PARSE REFUSED: delivered header unparseable (slot/block_no) — skipping store\n", .{});
                                                    // OBSERVABILITY: rate-limited structural dump of the unparseable
                                                    // header so we can localize the era/shape mismatch. 1-in-30s by
                                                    // default; first occurrence after binary start ALWAYS fires.
                                                    // Read-only; never mutates parser logic.
                                                    {
                                                        const now_dh = compat.timestamp();
                                                        if (ctx.last_delivered_header_dump_unix == 0 or
                                                            (now_dh - ctx.last_delivered_header_dump_unix) >= 30)
                                                        {
                                                            ctx.last_delivered_header_dump_unix = now_dh;
                                                            dumpHeaderShapeAndClassify("rollforward_inner", inner_bytes);
                                                        }
                                                    }
                                                    break :header_blk;
                                                }

                                                // Store header (linkage OK, bootstrap, or prev_hash missing)
                                                const new_height = ctx.header_height + 1;
                                                if (hs.beginWrite()) |wtxn0| {
                                                    var wtxn = wtxn0;
                                                    hs.putHeader(&wtxn, header_hash32_value, parent_slot_for_tick, parent_block_for_tick, new_height, prev_hash);
                                                    hs.putHeaderCbor(&wtxn, header_hash32_value, inner_bytes);
                                                    hs.putSlotIndex(&wtxn, parent_slot_for_tick, header_hash32_value);
                                                    hs.setHead(&wtxn, header_hash32_value);
                                                    hs.setHeight(&wtxn, new_height);
                                                    if (hs.commit(&wtxn)) {
                                                        ctx.header_head = header_hash32_value;
                                                        ctx.header_height = new_height;
                                                        ctx.last_header_slot = parent_slot_for_tick;
                                                        ctx.last_header_block_no = parent_block_for_tick;
                                                        if (ctx.metrics) |ma| {
                                                            const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                                                            _ = m.header_store_writes.fetchAdd(1, .acq_rel);
                                                            m.consensus_last_header_store_write_unix.store(@intCast(compat.timestamp()), .release);
                                                            m.header_height.store(new_height, .release);
                                                        }
                                                        // Save chain tip header for propagation harness
                                                        var appended_tail: ?FragmentTail = null;
                                                        saveChainTipHeader(inner_bytes, header_hash32_value, tip_slot, tip_block, full_block_bytes, &appended_tail);
                                                        // Update canonical fragment tail on producer context
                                                        if (appended_tail) |tail| {
                                                            ctx.producer_ctx.frag_tail_slot = tail.slot;
                                                            ctx.producer_ctx.frag_tail_block_no = tail.block_no;
                                                            ctx.producer_ctx.frag_tail_hash = tail.hash;
                                                            ctx.producer_ctx.frag_tail_valid = true;
                                                        }

                                                        // ── Nonce evolution: chain-derived path DISABLED ──
                                                        //
                                                        // Rationale (2026-05-16 incident — restored
                                                        // "TSUNAGI observes consensus; does not
                                                        // reconstruct it" doctrine firewall):
                                                        //
                                                        // The chain-derived path (processBlockVrf +
                                                        // finalizeAccumulator in nonce_evolution.zig)
                                                        // diverges from Cardano's authoritative
                                                        // praosStateEpochNonce along four independent
                                                        // algorithmic axes:
                                                        //   A. wrong randomness-stabilisation cutoff
                                                        //      (epoch_length * 4/5 = 80%; Conway spec is
                                                        //      epoch_length - 4·k/f ≈ 60% for Preview)
                                                        //   B. missing outer blake2b256 in per-block
                                                        //      vrfNonceValue (single hash; spec is
                                                        //      blake2b256(blake2b256("N" ‖ vrf_output)))
                                                        //   C. XOR accumulator vs Cardano's
                                                        //      blake2b256(a ‖ b) concat-then-hash ⭒
                                                        //   D. wrong TICKF epoch-boundary formula
                                                        //      (TSUNAGI: blake2b256(prev_epoch_nonce ‖
                                                        //      candidate); spec: blake2b256(candidate ‖
                                                        //      lastEpochBlockNonce))
                                                        //
                                                        // Combined with producer.zig:2017 outer-gate
                                                        // strict-> and finalizeAccumulator's bypass of
                                                        // updateStateMonotonic, this latched a wrong
                                                        // nonce at every epoch boundary (verified for
                                                        // at least epochs 1293–1299) that authoritative
                                                        // paths (Tier 1 cardano-cli, Tier 2 Koios) could
                                                        // never override within the same epoch. Result:
                                                        // 4-month canonical-block drought; all forge
                                                        // attempts produced blocks rejected by network
                                                        // validators as VRF-invalid for their declared
                                                        // slot under the correct nonce.
                                                        //
                                                        // Authoritative epoch nonce is now sourced
                                                        // exclusively via producer.zig:2017 →
                                                        // fetchEpochNonce → Tier 1 cardano-cli (if
                                                        // TSUNAGI_CARDANO_NODE_SOCKET set) or Tier 2
                                                        // Koios. All writes route through
                                                        // updateStateMonotonic. nonce_evolution.zig
                                                        // accumulator code is retained for future
                                                        // sovereign-node-phase reuse once corrected
                                                        // against the four spec bugs above, but is NOT
                                                        // invoked from runtime.
                                                        //
                                                        // To re-enable for sovereign-node research,
                                                        // first correct A/B/C/D, then route writes
                                                        // through updateStateMonotonic with a source
                                                        // priority that demotes chain-derived below
                                                        // cardano-cli and Koios. See
                                                        // session_resume_2026_05_16_nonce_root_cause_solved.md.
                                                        _ = &g_nonce_state; // silence unused warning
                                                    }
                                                }
                                            }

                                            if (trace_enabled and has_tip_hash) {
                                                if (last_trace_tip == null or
                                                    !std.mem.eql(u8, last_trace_tip.?[0..], tip_hash32_value[0..]))
                                                {
                                                    logBlockShape(next_msg.roll_forward.block, tip_hash32_value);
                                                    last_trace_tip = tip_hash32_value;
                                                }
                                            }
                                            var debug_body = false;
                                            var tip_prefix: [8]u8 = [_]u8{'?'} ** 8;
                                            _ = try std.fmt.bufPrint(
                                                &tip_prefix,
                                                "{x}",
                                                .{tip_hash32_value[0..4]},
                                            );
                                            if (last_body_debug_prefix) |last| {
                                                if (!std.mem.eql(u8, last[0..], tip_prefix[0..])) {
                                                    debug_body = true;
                                                }
                                            } else {
                                                debug_body = true;
                                            }
                                            if (debug_body and ctx.debug_verbose) {
                                                last_body_debug_prefix = tip_prefix;
                                            } else if (!ctx.debug_verbose) {
                                                debug_body = false;
                                            }
                                            const force_debug = force_debug_rollforwards > 0;
                                            _ = force_debug;
                                            // const effective_debug = debug_body or force_debug;
                                            var block_body_bytes_opt: ?[]const u8 = null;
                                            var block_body_bytes_owned: ?[]u8 = null;
                                            var body_top: ?cbor.Term = null;
                                            var body_fbs = compat.fixedBufferStream(inner_bytes);
                                            if (cbor.decode(a, body_fbs.reader())) |decoded| {
                                                body_top = decoded;
                                                if (ctx.debug_verbose) {
                                                    std.debug.print("BODY_TOP: kind={s}", .{@tagName(body_top.?)});
                                                    if (body_top.? == .array) {
                                                        std.debug.print(" len={d}", .{body_top.?.array.len});
                                                        if (body_top.?.array.len > 0) std.debug.print(" [0]={s}", .{@tagName(body_top.?.array[0])});
                                                        if (body_top.?.array.len > 1) std.debug.print(" [1]={s}", .{@tagName(body_top.?.array[1])});
                                                    }
                                                    std.debug.print("\n", .{});
                                                }
                                                if (body_top.? == .array and body_top.?.array.len >= 2) {
                                                    const body_term = body_top.?.array[1];
                                                    block_body_bytes_opt = switch (body_term) {
                                                        .bytes => |b| b,
                                                        .tag => |t| blk: {
                                                            if (t.tag == 24 and t.value.* == .bytes) {
                                                                break :blk t.value.*.bytes;
                                                            }
                                                            break :blk null;
                                                        },
                                                        // Mainnet case: body_term is already structured (array/map_u64)
                                                        .array, .map_u64 => blk: {
                                                            var buf = std.array_list.Managed(u8).init(a);
                                                            defer buf.deinit();
                                                            try cbor.encode(body_term, compat.listWriter(&buf));
                                                            const dup = try a.dupe(u8, buf.items);
                                                            block_body_bytes_owned = dup;
                                                            break :blk dup;
                                                        },
                                                        else => null,
                                                    };
                                                }
                                            } else |_| {
                                                if (ctx.debug_verbose) {
                                                    std.debug.print("TX_BODY decode failed (inner_bytes)\n", .{});
                                                }
                                            }
                                            // No defer free — arena.deinit() handles body_top, block_body_bytes_owned, inner_bytes_owned

                                            var tx_count: u64 = 0;
                                            var deltas = tx_decode.TxDeltas{
                                                .consumed = &[_]utxo_mod.TxIn{},
                                                .produced = &[_]utxo_mod.Produced{},
                                                .tx_count = 0,
                                            };
                                            var tx_summary_result = tx_decoder.BlockTxResult{
                                                .summaries = undefined,
                                                .count = 0,
                                                .truncated = false,
                                            };
                                            if (block_body_bytes_opt) |block_body_bytes| {
                                                var tx_list: ?[]cbor.Term = null;
                                                var tx_list_kind: []const u8 = "unknown";
                                                var body_term: ?cbor.Term = null;
                                                const MAX_BLOCK_BODY_BYTES: usize = 8 * 1024 * 1024; // 8 MB
                                                if (block_body_bytes.len > MAX_BLOCK_BODY_BYTES) {
                                                    // Size cap: skip decode, increment metrics, rate-limit log
                                                    if (ctx.metrics) |metrics_any| {
                                                        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
                                                        _ = m.cbor_toolarge.fetchAdd(1, .acq_rel);
                                                    }
                                                    _ = penalizePeerRateLimited(&score, current_relay_idx, 0.02, .cbor_error, compat.timestamp(), ctx.metrics);
                                                    const now_tl = compat.timestamp();
                                                    if (now_tl - ctx.last_cbor_toolarge_log_unix >= 60) {
                                                        ctx.last_cbor_toolarge_log_unix = now_tl;
                                                        std.debug.print("CBOR guard: body bytes too large len={d}, skipping decode\n", .{block_body_bytes.len});
                                                    }
                                                    body_term = null;
                                                } else {
                                                    body_term = cbor.decodeOrRaw(a, block_body_bytes) catch |err| blk: {
                                                        // Decode failed: increment metrics, penalize peer, rate-limit log
                                                        _ = penalizePeerRateLimited(&score, current_relay_idx, 0.02, .cbor_error, compat.timestamp(), ctx.metrics);
                                                        const now_cf = compat.timestamp();
                                                        if (ctx.metrics) |metrics_any| {
                                                            const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
                                                            if (err == error.CborTooLarge) {
                                                                _ = m.cbor_toolarge.fetchAdd(1, .acq_rel);
                                                            } else if (err == error.EndOfStream) {
                                                                _ = m.cbor_eof.fetchAdd(1, .acq_rel);
                                                            } else {
                                                                _ = m.cbor_other.fetchAdd(1, .acq_rel);
                                                            }
                                                        }
                                                        if (err == error.CborTooLarge) {
                                                            if (now_cf - ctx.last_cbor_toolarge_log_unix >= 60) {
                                                                ctx.last_cbor_toolarge_log_unix = now_cf;
                                                                std.debug.print("CBOR guard: decodeOrRaw failed: CborTooLarge\n", .{});
                                                            }
                                                        } else if (err == error.EndOfStream) {
                                                            if (now_cf - ctx.last_cbor_eof_log_unix >= 60) {
                                                                ctx.last_cbor_eof_log_unix = now_cf;
                                                                std.debug.print("CBOR guard: decodeOrRaw failed: EndOfStream\n", .{});
                                                            }
                                                        } else {
                                                            if (now_cf - ctx.last_cbor_other_log_unix >= 60) {
                                                                ctx.last_cbor_other_log_unix = now_cf;
                                                                std.debug.print("CBOR guard: decodeOrRaw failed: {s}\n", .{@errorName(err)});
                                                            }
                                                        }
                                                        break :blk null;
                                                    };
                                                }
                                                if (body_term) |body_term_value| {
                                                    // A) Shape probe for debugging structure
                                                    if (ctx.debug_verbose) {
                                                        std.debug.print("SHAPE: body_term={s}", .{@tagName(body_term_value)});
                                                        if (body_term_value == .array) {
                                                            std.debug.print(" len={d}\n", .{body_term_value.array.len});
                                                            const max_elem = @min(body_term_value.array.len, 5);
                                                            var i: usize = 0;
                                                            while (i < max_elem) : (i += 1) {
                                                                const elem = body_term_value.array[i];
                                                                std.debug.print("  [{d}]={s}", .{ i, @tagName(elem) });
                                                                if (elem == .array) {
                                                                    std.debug.print(" len={d}", .{elem.array.len});
                                                                    if (elem.array.len > 0) {
                                                                        std.debug.print(" [0]={s}", .{@tagName(elem.array[0])});
                                                                        // Deep probe for element [2] (likely TX bodies)
                                                                        if (i == 2 and elem.array.len > 0) {
                                                                            const first_item = elem.array[0];
                                                                            if (first_item == .array and first_item.array.len > 0) {
                                                                                std.debug.print(" [2][0][0]={s}", .{@tagName(first_item.array[0])});
                                                                            } else if (first_item == .tag) {
                                                                                std.debug.print(" [2][0]=tag({d},inner={s})", .{ first_item.tag.tag, @tagName(first_item.tag.value.*) });
                                                                            } else if (first_item == .bytes) {
                                                                                std.debug.print(" [2][0]=bytes(len={d})", .{first_item.bytes.len});
                                                                            }
                                                                        }
                                                                    }
                                                                } else if (elem == .bytes) {
                                                                    std.debug.print(" len={d}", .{elem.bytes.len});
                                                                    if (elem.bytes.len > 0) {
                                                                        std.debug.print(" first=0x{x:0>2}", .{elem.bytes[0]});
                                                                    }
                                                                } else if (elem == .tag) {
                                                                    std.debug.print(" tag={d}", .{elem.tag.tag});
                                                                    const inner = elem.tag.value.*;
                                                                    std.debug.print(" inner={s}", .{@tagName(inner)});
                                                                    if (inner == .bytes and inner.bytes.len > 0) {
                                                                        std.debug.print(" len={d} first=0x{x:0>2}", .{ inner.bytes.len, inner.bytes[0] });
                                                                    }
                                                                }
                                                                std.debug.print("\n", .{});
                                                            }
                                                        } else {
                                                            std.debug.print("\n", .{});
                                                        }
                                                    }

                                                    // B) Smart TX list extraction using tx_decode helper
                                                    if (body_term_value == .array) {
                                                        // TX_PAYLOAD_PROBE: Inspect payload structure
                                                        const items = body_term_value.array;
                                                        if (items.len >= 2 and items[0] == .u64 and ctx.debug_verbose) {
                                                            const max_show = @min(items.len, 5);
                                                            var kind_buf: [5][]const u8 = undefined;
                                                            var idx: usize = 0;
                                                            while (idx < max_show) : (idx += 1) {
                                                                kind_buf[idx] = @tagName(items[idx]);
                                                            }
                                                            const k0 = if (max_show > 0) kind_buf[0] else "";
                                                            const k1 = if (max_show > 1) kind_buf[1] else "";
                                                            const k2 = if (max_show > 2) kind_buf[2] else "";
                                                            const k3 = if (max_show > 3) kind_buf[3] else "";
                                                            const k4 = if (max_show > 4) kind_buf[4] else "";
                                                            std.debug.print("TX_PAYLOAD_PROBE len={d} kinds=[{s},{s},{s},{s},{s}]\n", .{ items.len, k0, k1, k2, k3, k4 });
                                                            // TX_PAYLOAD_CAND: inspect candidates 2..4 without walking arrays
                                                            {
                                                                var cand_i: usize = 2;
                                                                while (cand_i <= 4) : (cand_i += 1) {
                                                                    if (items.len <= cand_i) break;
                                                                    const cand = items[cand_i];
                                                                    const cand_len: usize = if (cand == .array) cand.array.len else 0;
                                                                    if (cand == .array and cand.array.len > 0) {
                                                                        const first_tx = cand.array[0];
                                                                        if (first_tx == .array) {
                                                                            const txa = first_tx.array;
                                                                            var tx0_k0: []const u8 = "none";
                                                                            var tx0_k1: []const u8 = "none";
                                                                            var tx0_k2: []const u8 = "none";
                                                                            var tx0_k1_buf: [64]u8 = undefined;
                                                                            var tx0_k2_buf: [64]u8 = undefined;

                                                                            if (txa.len > 0) tx0_k0 = @tagName(txa[0]);
                                                                            if (txa.len > 1) {
                                                                                if (txa[1] == .bytes) {
                                                                                    const s = std.fmt.bufPrint(&tx0_k1_buf, "bytes({d})", .{txa[1].bytes.len}) catch "bytes(?)";
                                                                                    tx0_k1 = s;
                                                                                } else if (txa[1] == .tag and txa[1].tag.value.* == .bytes) {
                                                                                    const s = std.fmt.bufPrint(&tx0_k1_buf, "tag{d}->bytes({d})", .{ txa[1].tag.tag, txa[1].tag.value.*.bytes.len }) catch "tag->bytes(?)";
                                                                                    tx0_k1 = s;
                                                                                } else {
                                                                                    tx0_k1 = @tagName(txa[1]);
                                                                                }
                                                                            }
                                                                            if (txa.len > 2) {
                                                                                if (txa[2] == .bytes) {
                                                                                    const s = std.fmt.bufPrint(&tx0_k2_buf, "bytes({d})", .{txa[2].bytes.len}) catch "bytes(?)";
                                                                                    tx0_k2 = s;
                                                                                } else if (txa[2] == .tag and txa[2].tag.value.* == .bytes) {
                                                                                    const s = std.fmt.bufPrint(&tx0_k2_buf, "tag{d}->bytes({d})", .{ txa[2].tag.tag, txa[2].tag.value.*.bytes.len }) catch "tag->bytes(?)";
                                                                                    tx0_k2 = s;
                                                                                } else {
                                                                                    tx0_k2 = @tagName(txa[2]);
                                                                                }
                                                                            }

                                                                            std.debug.print(
                                                                                "TX_PAYLOAD_TX0: i={d} cand_len={d} tx_len={d} k0={s} k1={s} k2={s}\n",
                                                                                .{ cand_i, cand.array.len, txa.len, tx0_k0, tx0_k1, tx0_k2 },
                                                                            );
                                                                        }
                                                                    }
                                                                    std.debug.print(
                                                                        "TX_PAYLOAD_CAND: i={d} kind={s} len={d}",
                                                                        .{ cand_i, @tagName(cand), cand_len },
                                                                    );
                                                                    if (cand == .array and cand_len > 0) {
                                                                        const first = cand.array[0];
                                                                        std.debug.print(" first_kind={s}", .{@tagName(first)});
                                                                        if (first == .array) {
                                                                            const first_len = first.array.len;
                                                                            std.debug.print(" first.array_len={d}", .{first_len});
                                                                            if (first_len > 0) {
                                                                                std.debug.print(" first0_kind={s}", .{@tagName(first.array[0])});
                                                                            }
                                                                        } else if (first == .tag) {
                                                                            std.debug.print(
                                                                                " first.tag={d} inner_kind={s}",
                                                                                .{ first.tag.tag, @tagName(first.tag.value.*) },
                                                                            );
                                                                        } else if (first == .bytes) {
                                                                            const b0: u8 = if (first.bytes.len > 0) first.bytes[0] else 0;
                                                                            std.debug.print(" first.bytes_len={d} b0=0x{x:0>2}", .{ first.bytes.len, b0 });
                                                                        }
                                                                    }
                                                                    std.debug.print("\n", .{});

                                                                    // TX_PAYLOAD_SEC: Inspect sections within this candidate
                                                                    if (cand == .array) {
                                                                        const max_j = @min(3, cand_len - 1);
                                                                        var sec_j: usize = 0;
                                                                        while (sec_j <= max_j) : (sec_j += 1) {
                                                                            const sec = cand.array[sec_j];
                                                                            std.debug.print("TX_PAYLOAD_SEC: i={d} j={d} kind={s}", .{ cand_i, sec_j, @tagName(sec) });

                                                                            if (sec == .array) {
                                                                                const sec_len = sec.array.len;
                                                                                std.debug.print(" len={d}", .{sec_len});
                                                                                if (sec_len > 0) {
                                                                                    const sec_first = sec.array[0];
                                                                                    std.debug.print(" [0]={s}", .{@tagName(sec_first)});
                                                                                    if (sec_first == .array and sec_first.array.len > 0) {
                                                                                        std.debug.print(" [0][0]={s}", .{@tagName(sec_first.array[0])});
                                                                                    }
                                                                                }
                                                                            } else if (sec == .bytes) {
                                                                                const sec_len = sec.bytes.len;
                                                                                const b0: u8 = if (sec_len > 0) sec.bytes[0] else 0;
                                                                                std.debug.print(" bytes_len={d} b0=0x{x:0>2}", .{ sec_len, b0 });
                                                                            } else if (sec == .tag) {
                                                                                std.debug.print(" tag={d} inner={s}", .{ sec.tag.tag, @tagName(sec.tag.value.*) });
                                                                                if (sec.tag.value.* == .bytes) {
                                                                                    const inner_len = sec.tag.value.*.bytes.len;
                                                                                    const b0: u8 = if (inner_len > 0) sec.tag.value.*.bytes[0] else 0;
                                                                                    std.debug.print(" inner_bytes_len={d} b0=0x{x:0>2}", .{ inner_len, b0 });
                                                                                }
                                                                            }

                                                                            std.debug.print("\n", .{});

                                                                            // TX_CONWAY_MAP: Detailed probe for map_u64 in items[4] sections
                                                                            if (cand_i == 4 and sec == .map_u64) {
                                                                                const map_entries = sec.map_u64;
                                                                                std.debug.print("TX_CONWAY_MAP: i={d} j={d} map_len={d}\n", .{ cand_i, sec_j, map_entries.len });
                                                                                const max_keys = @min(6, map_entries.len);
                                                                                var key_idx: usize = 0;
                                                                                while (key_idx < max_keys) : (key_idx += 1) {
                                                                                    const entry = map_entries[key_idx];
                                                                                    const val = entry.value;
                                                                                    std.debug.print("TX_CONWAY_MAP:   key={d} val_kind={s}", .{ entry.key, @tagName(val) });
                                                                                    if (val == .bytes) {
                                                                                        const b0: u8 = if (val.bytes.len > 0) val.bytes[0] else 0;
                                                                                        std.debug.print(" bytes_len={d} first=0x{x:0>2}", .{ val.bytes.len, b0 });
                                                                                    } else if (val == .tag and val.tag.tag == 24 and val.tag.value.* == .bytes) {
                                                                                        const tag24_inner_bytes = val.tag.value.*.bytes;
                                                                                        const b0: u8 = if (tag24_inner_bytes.len > 0) tag24_inner_bytes[0] else 0;
                                                                                        std.debug.print(" tag24_bytes_len={d} first=0x{x:0>2}", .{ tag24_inner_bytes.len, b0 });
                                                                                    } else if (val == .map_u64) {
                                                                                        std.debug.print(" map_len={d}", .{val.map_u64.len});
                                                                                    } else if (val == .array) {
                                                                                        std.debug.print(" array_len={d}", .{val.array.len});
                                                                                    }
                                                                                    std.debug.print("\n", .{});
                                                                                }
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                        // Conway payload: items = [u64, bytes, array, array, array]
                                                        // items[4] likely contains tx bodies (possibly in a map_u64)
                                                        if (tx_list == null and body_term_value == .array) {
                                                            const conway_items = body_term_value.array;
                                                            if (conway_items.len == 5 and conway_items[0] == .u64 and conway_items[1] == .bytes and conway_items[4] == .array) {
                                                                // Delegate to tx_decode helper which handles items[4] map extraction
                                                                if (tx_decode.extractTxListFromTermPublic(a, body_term_value)) |scan| {
                                                                    tx_list = scan.tx_list;
                                                                    tx_list_kind = "conway.items[4]";
                                                                    if (ctx.debug_verbose and tx_list.?.len > 0) {
                                                                        std.debug.print(
                                                                            "TX_CONWAY: tx_list_len={d} first_kind={s}\n",
                                                                            .{ tx_list.?.len, @tagName(tx_list.?[0]) },
                                                                        );
                                                                    }
                                                                }
                                                            }
                                                        }

                                                        // Existing generic extractor fallback
                                                        if (tx_list == null) {
                                                            if (tx_decode.extractTxListFromTermPublic(a, body_term_value)) |scan| {
                                                                tx_list = scan.tx_list;
                                                                // NOTE: scan.owner is the same as body_term_value in this call path (don't free twice)
                                                                tx_list_kind = "term-scan";
                                                            }
                                                        }
                                                    }
                                                }
                                                // No defer free for body_term — arena.deinit() handles it

                                                // Bayesian alpha reward: once per 60s window of successful decodes
                                                {
                                                    const now_ar = compat.timestamp();
                                                    if (now_ar - score.last_alpha_reward_unix >= 60) {
                                                        score.last_alpha_reward_unix = now_ar;
                                                        rewardPeer(&score, current_relay_idx, 0.02);
                                                    }

                                                    // Bayes v2: performance nudge (once per 60s)
                                                    if (now_ar - score.last_perf_nudge_unix >= 60) {
                                                        if (ctx.metrics) |metrics_any| {
                                                            const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(metrics_any))));
                                                            const reconnect_us = m.perf_reconnect_us.load(.acquire);
                                                            const block_total_us = m.perf_block_total_us.load(.acquire);
                                                            const ri = current_relay_idx % RELAY_COUNT;

                                                            if (reconnect_us > 0 and reconnect_us <= 30_000 and block_total_us > 0 and block_total_us <= 5_000) {
                                                                rewardPeer(&score, ri, 0.005);
                                                                _ = m.peer_perf_reward[ri].fetchAdd(1, .acq_rel);
                                                                score.last_perf_nudge_unix = now_ar;
                                                            } else if (reconnect_us >= 200_000) {
                                                                _ = penalizePeerRateLimited(&score, ri, 0.01, .other, now_ar, ctx.metrics);
                                                                _ = m.peer_perf_penalty[ri].fetchAdd(1, .acq_rel);
                                                                score.last_perf_nudge_unix = now_ar;
                                                            }
                                                        }
                                                    }
                                                }

                                                if (tx_list) |tx_list_items| {
                                                    tx_count = @intCast(tx_list_items.len);
                                                    tx_summary_result = tx_decoder.extractTxSummaries(alloc, tx_list_items);
                                                    tx_decode.updateBlockSummaryCounters(tx_summary_result);
                                                    if (tx_list_items.len > 0) {
                                                        const first = tx_list_items[0];
                                                        tx_list_kind = if (first == .bytes)
                                                            "bytes"
                                                        else if (first == .tag and
                                                            first.tag.tag == 24 and
                                                            first.tag.value.* == .bytes)
                                                            "tag24"
                                                        else if (first == .map_u64)
                                                            "map"
                                                        else
                                                            "unknown";
                                                    }
                                                    if (ctx.debug_verbose) {
                                                        std.debug.print(
                                                            "tx_list_kind={s} tx_count={d}\n",
                                                            .{ tx_list_kind, tx_count },
                                                        );
                                                        if (tx_list_items.len > 0) {
                                                            const first_tx = tx_list_items[0];
                                                            std.debug.print("TX_ITEM[0]: kind={s}", .{@tagName(first_tx)});
                                                            if (first_tx == .tag) {
                                                                std.debug.print(" tag={d} inner={s}", .{ first_tx.tag.tag, @tagName(first_tx.tag.value.*) });
                                                            } else if (first_tx == .bytes) {
                                                                std.debug.print(" bytes_len={d}", .{first_tx.bytes.len});
                                                            } else if (first_tx == .array) {
                                                                std.debug.print(" array_len={d}", .{first_tx.array.len});
                                                                if (first_tx.array.len > 0) {
                                                                    std.debug.print(" [0]={s}", .{@tagName(first_tx.array[0])});
                                                                }
                                                            }
                                                            std.debug.print("\n", .{});
                                                        }
                                                    }
                                                    if (tx_list_items.len > 0) {
                                                        // Extract canonical txids from original full block bytes
                                                        var txid_buf: [block_hash.MAX_TX_HASHES][32]u8 = undefined;
                                                        const bp_result = block_hash.extractBodyParts(full_block_bytes);
                                                        const txid_count = if (bp_result) |parts|
                                                            block_hash.extractTxBodyHashes(parts.tx_bodies, &txid_buf)
                                                        else
                                                            @as(usize, 0);
                                                        const c_txids: ?[]const [32]u8 = if (txid_count > 0) txid_buf[0..txid_count] else null;
                                                        deltas = tx_decode.extractTxDeltas(alloc, tx_list_items, c_txids, debug_body) catch deltas;
                                                        if (ctx.debug_verbose and tx_count > 0 and
                                                            deltas.consumed.len == 0 and deltas.produced.len == 0)
                                                        {
                                                            std.debug.print("tx_count>0 but deltas empty\n", .{});

                                                            // === BLOCKFETCH TRIGGER: hash-only list detected ===
                                                            if (!blockfetch_once and tx_list_items.len > 0) {
                                                                // Check if first item is hash-only (not map_u64)
                                                                const first_item = tx_list_items[0];
                                                                const is_hash_array = first_item == .array and first_item.array.len >= 2 and first_item.array[0] == .u64;
                                                                const is_hash_bytes = first_item == .bytes and first_item.bytes.len == 32;

                                                                if (is_hash_array or is_hash_bytes) {
                                                                    blockfetch_once = true;

                                                                    // Extract tx hashes from hash-only list
                                                                    var hashes = std.array_list.Managed([32]u8).init(alloc);
                                                                    defer hashes.deinit();

                                                                    for (tx_list_items) |it| {
                                                                        // Hash-only entries: array [u64, bytes32, bytes32] or just bytes32
                                                                        if (it == .array and it.array.len >= 2) {
                                                                            const maybe = it.array[1];
                                                                            if (maybe == .bytes and maybe.bytes.len == 32) {
                                                                                var h: [32]u8 = undefined;
                                                                                @memcpy(&h, maybe.bytes[0..32]);
                                                                                hashes.append(h) catch {};
                                                                            }
                                                                        } else if (it == .bytes and it.bytes.len == 32) {
                                                                            var h: [32]u8 = undefined;
                                                                            @memcpy(&h, it.bytes[0..32]);
                                                                            hashes.append(h) catch {};
                                                                        }
                                                                        if (hashes.items.len >= 12) break; // cap at 12
                                                                    }

                                                                    std.debug.print("BLOCKFETCH: trigger block={d} slot={d} tx_hashes={d}\n", .{ tip_block, tip_slot, hashes.items.len });

                                                                    // Request full block via BlockFetch using block point (NOT tx hashes!)
                                                                    // Point = [slot, block_header_hash] from ChainSync RollForward
                                                                    blockfetch.requestBlock(
                                                                        alloc,
                                                                        &bt,
                                                                        tip_slot,
                                                                        tip_hash32_value,
                                                                        tip_block,
                                                                        ctx_any,
                                                                        onBlockFetched,
                                                                    ) catch |err| {
                                                                        std.debug.print("BLOCKFETCH: error {}\n", .{err});
                                                                    };
                                                                }
                                                            }
                                                        }
                                                        defer tx_decode.freeTxDeltas(alloc, deltas);

                                                        // Ancestry gate: skip delta apply if block doesn't chain to our tip.
                                                        // This prevents applying deltas from orphaned or reorged blocks.
                                                        const ancestry_ok = blk_anc: {
                                                            if (delivered_prev_hash == null) break :blk_anc true; // can't verify → allow
                                                            if (ctx.header_head == null) break :blk_anc true; // no tip yet → allow
                                                            break :blk_anc std.mem.eql(u8, &delivered_prev_hash.?, &ctx.header_head.?);
                                                        };
                                                        if (!ancestry_ok) {
                                                            std.debug.print("DELTA_SKIP_ANCESTRY_BREAK: slot={d} block={d} prev_hash={x} expected_head={x}\n", .{
                                                                tip_slot, tip_block,
                                                                delivered_prev_hash.?[0..8],
                                                                ctx.header_head.?[0..8],
                                                            });
                                                            tx_decode.incrAncestrySkip();
                                                        } else {
                                                            if (ctx.primary_pipeline) |pp| {
                                                                primaryApplyDeltas(ctx, pp, deltas, tip_slot, tip_block);
                                                            } else {
                                                                applyPreviewUtxo(ctx, alloc, deltas, tip_slot, tip_block);
                                                            }
                                                            shadowApplyDeltas(ctx, deltas, tip_slot, tip_block);

                                                            // Evict confirmed txs from mempool
                                                            if (txsubmission.g_mempool) |mp| {
                                                                if (deltas.consumed.len > 0) {
                                                                    const evicted = mp.evictConfirmed(deltas.consumed);
                                                                    if (evicted > 0) {
                                                                        std.debug.print("MEMPOOL_EVICT_CONFIRMED: evicted={d} consumed={d} slot={d}\n", .{
                                                                            evicted, deltas.consumed.len, tip_slot,
                                                                        });
                                                                    }
                                                                }
                                                                // TTL sweep: drop entries older than TSUNAGI_MEMPOOL_TTL_S (default 3600s)
                                                                _ = mp.sweepExpired(compat.timestamp());
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                            // Check ledger violation flag (set by validateDeltasInvariant in strict mode)
                                            if (ctx.ledger_violation_pending) {
                                                ctx.ledger_violation_pending = false;
                                                peer_was_closed = true;
                                                if (ctx.metrics) |ma| {
                                                    const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                                                    _ = m.ledger_strict_disconnect_total.fetchAdd(1, .acq_rel);
                                                }
                                                std.debug.print("STRICT MODE: ledger violation → disconnect\n", .{});
                                            }

                                            if (force_debug_rollforwards > 0) force_debug_rollforwards -= 1;

                                            if (ctx.debug_verbose) {
                                                var header_prefix: [8]u8 = [_]u8{'?'} ** 8;
                                                _ = try std.fmt.bufPrint(
                                                    &header_prefix,
                                                    "{x}",
                                                    .{header_hash32_value[0..4]},
                                                );
                                                std.debug.print(
                                                    "engine header_hash_prefix={s}\n",
                                                    .{header_prefix[0..]},
                                                );
                                            }

                                            const now = compat.timestamp();
                                            tps_meter.addBlock(tx_count, now, ctx.debug_verbose);
                                            ctx.roll_forward_count += 1;
                                            ctx.rolls_since_last_rollback += 1;

                                            // Consensus tip freshness (inter-block gap, before reset)
                                            if (ctx.last_roll_fwd_unix > 0) {
                                                if (ctx.metrics) |ma_fresh| {
                                                    const m_fresh = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma_fresh))));
                                                    m_fresh.consensus_tip_fresh_seconds.store(@intCast(@max(0, now - ctx.last_roll_fwd_unix)), .release);
                                                }
                                            }

                                            // Stall recovery: mark forward progress
                                            ctx.last_roll_fwd_unix = now;
                                            ctx.stall_active = false;
                                            if (ctx.metrics) |ma_stall| {
                                                const m_stall = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma_stall))));
                                                m_stall.peer_last_roll_fwd_unix.store(@intCast(now), .release);
                                                m_stall.peer_stall_active.store(0, .release);
                                            }

                                            // Consensus clock sanity (warn-only by default, strict opt-in)
                                            if (checkClockSanity(ctx, tip_slot, now)) {
                                                peer_was_closed = true;
                                            }

                                            // Authority confidence model (observability-only)
                                            updateAuthorityModel(ctx, tip_slot, tip_block, header_hash32_value, false, 0);

                                            // Block producer skeleton tick.
                                            // tip_mutex serializes the triple-write so readers in
                                            // selectFreshestParent observe a consistent (slot, hash,
                                            // block_no) snapshot. Forensics 2026-05-14 found a torn
                                            // mid-write read: slot+hash advanced to block N+1, block_no
                                            // still at N — caused a 1-step rule mismatch and refused
                                            // a legitimate forge. The prior b1/b2 fence at the reader
                                            // could not detect that window because tip_block_last had
                                            // not yet changed between b1 and b2.
                                            // PRIMARY OBSERVABILITY (fix/primary-follower-observability)
                                            // Capture pre-write values + log every promotion attempt.
                                            // Rate-limited to 1-in-30s for steady-state; immediate when value transitions 0→nonzero.
                                            const prior_tip_block = ctx.producer_ctx.tip_block_last;
                                            const applied_tip_triple = applied_tip_select.appliedTipTripleForRollForward(
                                                tip_slot,
                                                tip_block,
                                                parent_slot_for_tick,
                                                parent_block_for_tick,
                                                parent_hash_for_tick,
                                            );
                                            ctx.producer_ctx.tip_mutex.lock();
                                            ctx.producer_ctx.tip_slot_last = applied_tip_triple.slot;
                                            ctx.producer_ctx.tip_hash_last = applied_tip_triple.hash;
                                            ctx.producer_ctx.tip_block_last = applied_tip_triple.block_no;
                                            ctx.producer_ctx.tip_mutex.unlock();
                                            // PRIMARY OBSERVABILITY: tip_block_last write log + promotion counter
                                            ctx.primary_rollforwards_processed += 1;
                                            if (ctx.metrics) |ma_rf| {
                                                const m_rf = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma_rf))));
                                                _ = m_rf.primary_rollforwards_processed_total.fetchAdd(1, .acq_rel);
                                                if (prior_tip_block == 0 and tip_block != 0) {
                                                    _ = m_rf.primary_tip_promotions_total.fetchAdd(1, .acq_rel);
                                                }
                                            }
                                            {
                                                const now_tp = compat.timestamp();
                                                const transitioned_from_zero = (prior_tip_block == 0 and tip_block != 0);
                                                const tip_parse_null = (tip_info == null);
                                                if (transitioned_from_zero or tip_parse_null or
                                                    now_tp - ctx.primary_last_tip_promo_log_unix >= 30)
                                                {
                                                    ctx.primary_last_tip_promo_log_unix = now_tp;
                                                    std.debug.print(
                                                        "PRIMARY_TIP_WRITE: source=primary_rf prior_block={d} new_block={d} new_slot={d} tip_parse_null={s} rolls_processed={d}\n",
                                                        .{
                                                            prior_tip_block,
                                                            tip_block,
                                                            tip_slot,
                                                            if (tip_parse_null) "true" else "false",
                                                            ctx.primary_rollforwards_processed,
                                                        },
                                                    );
                                                    if (tip_parse_null) {
                                                        if (ctx.metrics) |ma_pn2| {
                                                            const m_pn2 = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma_pn2))));
                                                            _ = m_pn2.primary_tip_parse_null_total.fetchAdd(1, .acq_rel);
                                                        }
                                                        logTipShapeSummary("RF.tip", next_msg.roll_forward.tip);
                                                    }
                                                }
                                            }

                                            // Phase B'''' D-2: record peer-tip telemetry. Operator-visible
                                            // delivered values flow through metrics.slot/block_no via
                                            // chainsync_mux_smoke.onRollForward; peer-tip values land here.
                                            ctx.peer_tip_slot = tip_slot;
                                            ctx.peer_tip_block_no = tip_block;
                                            ctx.peer_tip_hash = tip_hash32_value;
                                            ctx.peer_tip_observed_unix = now;
                                            if (ctx.metrics) |ma_pt| {
                                                const m_pt = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma_pt))));
                                                m_pt.peer_tip_slot.store(tip_slot, .release);
                                                m_pt.peer_tip_block_no.store(tip_block, .release);
                                            }
                                            if (ctx.metrics) |ma_sd| {
                                                const m_sd = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma_sd))));
                                                std.mem.writeInt(u64, ctx.producer_ctx.state_digest[0..8], m_sd.state_digest_hi.load(.acquire), .big);
                                                std.mem.writeInt(u64, ctx.producer_ctx.state_digest[8..16], m_sd.state_digest_lo.load(.acquire), .big);
                                                std.mem.writeInt(u64, ctx.producer_ctx.state_digest[16..24], m_sd.state_digest_w2.load(.acquire), .big);
                                                std.mem.writeInt(u64, ctx.producer_ctx.state_digest[24..32], m_sd.state_digest_w3.load(.acquire), .big);
                                            }

                                            // Tick at successor slot and also at estimated wall-clock slot.
                                            // The VRF leader check is per-slot; if the chain has gaps
                                            // between blocks, the leader slot may be several slots ahead
                                            // of delivered_block.slot + 1. Ticking at the estimated
                                            // current slot ensures we evaluate our actual leader window.
                                            producer.tick(&ctx.producer_ctx, parent_slot_for_tick + 1, now, parent_slot_for_tick, parent_block_for_tick, parent_hash_for_tick);
                                            {
                                                const est_slot = slot_clock.estimateSlot(&ctx.producer_ctx.clock, now);
                                                if (est_slot > parent_slot_for_tick + 1) {
                                                    producer.tick(&ctx.producer_ctx, est_slot, now, parent_slot_for_tick, parent_block_for_tick, parent_hash_for_tick);
                                                }
                                                // Also tick at scheduled leader slot if one exists nearby
                                                if (ctx.producer_ctx.schedule_leaders_in_window > 0 and ctx.producer_ctx.schedule_next_leader_offset < 999999) {
                                                    const leader_slot = ctx.producer_ctx.schedule_window_start_slot + ctx.producer_ctx.schedule_next_leader_offset;
                                                    if (leader_slot > parent_slot_for_tick and leader_slot <= est_slot + 128) {
                                                        producer.tick(&ctx.producer_ctx, leader_slot, now, parent_slot_for_tick, parent_block_for_tick, parent_hash_for_tick);
                                                    }
                                                }
                                            }
                                            if (ctx.metrics) |ma_prod| {
                                                const m_prod = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma_prod))));
                                                m_prod.producer_state.store(@intFromEnum(ctx.producer_ctx.state), .release);
                                                m_prod.producer_last_slot_checked.store(ctx.producer_ctx.last_slot_checked, .release);
                                                m_prod.producer_last_leader_slot.store(ctx.producer_ctx.last_leader_slot, .release);
                                                m_prod.producer_leader_checks_total.store(ctx.producer_ctx.leader_checks_total, .release);
                                                m_prod.producer_observed_slot.store(ctx.producer_ctx.last_observed_slot, .release);
                                                m_prod.producer_estimated_slot.store(ctx.producer_ctx.clock.last_est_slot, .release);
                                                // Offset-encode signed drift: store = drift + 10_000_000
                                                const drift_store: u64 = @intCast(@as(i64, @max(0, @min(20_000_000, ctx.producer_ctx.drift_last_slots + 10_000_000))));
                                                m_prod.producer_drift_last_slots.store(drift_store, .release);
                                                const drift_abs: u64 = if (ctx.producer_ctx.drift_last_slots < 0) @intCast(-ctx.producer_ctx.drift_last_slots) else @intCast(ctx.producer_ctx.drift_last_slots);
                                                m_prod.producer_drift_abs_last.store(drift_abs, .release);
                                                m_prod.producer_drift_abs_max.store(ctx.producer_ctx.drift_abs_max, .release);
                                                m_prod.producer_drift_events_total.store(ctx.producer_ctx.drift_events_total, .release);
                                                m_prod.producer_clock_ok.store(if (ctx.producer_ctx.genesis_parse_ok and ctx.producer_ctx.slot_length_s >= 1) @as(u64, 1) else @as(u64, 0), .release);
                                                // Genesis gauges
                                                const gen_unix_store: u64 = if (ctx.producer_ctx.genesis_unix >= 0) @intCast(ctx.producer_ctx.genesis_unix) else 0;
                                                m_prod.producer_genesis_unix.store(gen_unix_store, .release);
                                                m_prod.producer_slot_length_s.store(@intCast(ctx.producer_ctx.slot_length_s), .release);
                                                m_prod.producer_genesis_parse_ok.store(if (ctx.producer_ctx.genesis_parse_ok) @as(u64, 1) else @as(u64, 0), .release);
                                                m_prod.producer_genesis_path_ok.store(if (ctx.producer_ctx.genesis_path_ok) @as(u64, 1) else @as(u64, 0), .release);
                                                m_prod.producer_genesis_last_error_code.store(ctx.producer_ctx.genesis_last_error_code, .release);
                                                // Leader check skeleton
                                                m_prod.producer_epoch_last.store(ctx.producer_ctx.epoch_last, .release);
                                                m_prod.producer_slot_in_epoch_last.store(ctx.producer_ctx.slot_in_epoch_last, .release);
                                                m_prod.producer_leader_eligible_last.store(if (ctx.producer_ctx.leader_eligible_last) @as(u64, 1) else @as(u64, 0), .release);
                                                m_prod.producer_leader_probability_x1e6.store(ctx.producer_ctx.leader_probability_x1e6, .release);
                                                m_prod.producer_leader_checks_epoch_total.store(ctx.producer_ctx.leader_checks_epoch_total, .release);
                                                // VRF interface
                                                m_prod.producer_vrf_enabled.store(if (ctx.producer_ctx.vrf_cfg.enabled) @as(u64, 1) else @as(u64, 0), .release);
                                                m_prod.producer_vrf_parse_ok.store(if (ctx.producer_ctx.vrf_cfg.parse_ok) @as(u64, 1) else @as(u64, 0), .release);
                                                m_prod.producer_vrf_attempt_total.store(ctx.producer_ctx.vrf_attempt_total, .release);
                                                m_prod.producer_vrf_checked_total.store(ctx.producer_ctx.vrf_checked_total, .release);
                                                m_prod.producer_vrf_reason_code_last.store(@as(u64, ctx.producer_ctx.vrf_reason_code_last), .release);
                                                m_prod.producer_vrf_checked_last.store(if (ctx.producer_ctx.vrf_checked_last) @as(u64, 1) else @as(u64, 0), .release);
                                                m_prod.producer_vrf_probability_x1e6.store(ctx.producer_ctx.vrf_probability_x1e6_last, .release);
                                                m_prod.producer_vrf_proof_present.store(if (ctx.producer_ctx.vrf_proof_present_last) @as(u64, 1) else @as(u64, 0), .release);
                                                m_prod.producer_vrf_output_present.store(if (ctx.producer_ctx.vrf_output_present_last) @as(u64, 1) else @as(u64, 0), .release);
                                                m_prod.producer_vrf_init_ok.store(if (ctx.producer_ctx.vrf_init_ok) @as(u64, 1) else @as(u64, 0), .release);
                                                m_prod.producer_vrf_verify_ok_last.store(if (ctx.producer_ctx.vrf_verify_ok_last) @as(u64, 1) else @as(u64, 0), .release);
                                                m_prod.producer_vrf_output_prefix_last.store(ctx.producer_ctx.vrf_output_prefix_last, .release);
                                                m_prod.producer_vrf_tick_mode_code.store(@as(u64, ctx.producer_ctx.vrf_tick_mode), .release);
                                                m_prod.producer_vrf_last_checked_slot.store(ctx.producer_ctx.last_vrf_checked_slot, .release);
                                                m_prod.producer_vrf_skipped_total.store(ctx.producer_ctx.vrf_skipped_total, .release);
                                                // VRF proof artifact pipeline (v0.9.8)
                                                m_prod.producer_vrf_proof_len_last.store(ctx.producer_ctx.vrf_proof_len_last, .release);
                                                m_prod.producer_vrf_output_len_last.store(ctx.producer_ctx.vrf_output_len_last, .release);
                                                m_prod.producer_vrf_proof_prefix_last.store(ctx.producer_ctx.vrf_proof_prefix_last, .release);
                                                // output_prefix_last already synced above
                                                // KES interface
                                                m_prod.producer_kes_enabled.store(if (ctx.producer_ctx.kes_cfg.enabled) @as(u64, 1) else @as(u64, 0), .release);
                                                m_prod.producer_kes_parse_ok.store(if (ctx.producer_ctx.kes_cfg.parse_ok) @as(u64, 1) else @as(u64, 0), .release);
                                                m_prod.producer_kes_attempt_total.store(ctx.producer_ctx.kes_attempt_total, .release);
                                                m_prod.producer_kes_signed_total.store(ctx.producer_ctx.kes_signed_total, .release);
                                                m_prod.producer_kes_sig_present_last.store(ctx.producer_ctx.kes_sig_present_last, .release);
                                                m_prod.producer_kes_reason_code_last.store(ctx.producer_ctx.kes_reason_code_last, .release);
                                                // Header candidate pipeline
                                                m_prod.producer_candidate_built_total.store(ctx.producer_ctx.candidate_built_total, .release);
                                                m_prod.producer_candidate_signed_total.store(ctx.producer_ctx.candidate_signed_total, .release);
                                                m_prod.producer_candidate_last_slot.store(ctx.producer_ctx.candidate_last_slot, .release);
                                                m_prod.producer_candidate_body_hash_prefix.store(ctx.producer_ctx.candidate_body_hash_prefix_last, .release);
                                                m_prod.producer_candidate_sig_present_last.store(@as(u64, ctx.producer_ctx.candidate_sig_present_last), .release);
                                                m_prod.producer_candidate_hdr_bytes_len.store(ctx.producer_ctx.candidate_hdr_bytes_len, .release);
                                                m_prod.producer_candidate_hdr_hash_w0.store(ctx.producer_ctx.candidate_hdr_hash_w0, .release);
                                                m_prod.producer_candidate_hdr_hash_w1.store(ctx.producer_ctx.candidate_hdr_hash_w1, .release);
                                                // Block body builder (v0.9.9)
                                                m_prod.producer_body_cbor_len.store(ctx.producer_ctx.body_cbor_len_last, .release);
                                                m_prod.producer_body_hash_w0.store(ctx.producer_ctx.body_hash_w0, .release);
                                                m_prod.producer_body_hash_w1.store(ctx.producer_ctx.body_hash_w1, .release);
                                                m_prod.producer_body_hash_w2.store(ctx.producer_ctx.body_hash_w2, .release);
                                                m_prod.producer_body_hash_w3.store(ctx.producer_ctx.body_hash_w3, .release);
                                                // Producer proof pack (v1.0.0)
                                                m_prod.producer_pack_total.store(ctx.producer_ctx.pack_total, .release);
                                                m_prod.producer_pack_last_unix.store(if (ctx.producer_ctx.pack_last_unix > 0) @as(u64, @intCast(ctx.producer_ctx.pack_last_unix)) else 0, .release);
                                                // Praos leader check (v1.0.1)
                                                m_prod.producer_praos_u_x1e12.store(ctx.producer_ctx.praos_u_x1e12_last, .release);
                                                m_prod.producer_praos_thresh_x1e12.store(ctx.producer_ctx.praos_thresh_x1e12_last, .release);
                                                m_prod.producer_praos_leader_last.store(ctx.producer_ctx.praos_leader_last, .release);
                                                m_prod.producer_praos_reason_code_last.store(ctx.producer_ctx.praos_reason_code_last, .release);
                                                m_prod.producer_praos_checks_total.store(ctx.producer_ctx.praos_checks_total, .release);
                                                m_prod.producer_praos_enabled.store(if (ctx.producer_ctx.praos_enabled) @as(u64, 1) else 0, .release);
                                                m_prod.producer_praos_last_checked_slot.store(ctx.producer_ctx.praos_last_checked_slot, .release);
                                                // Praos decision surface (v1.1.3)
                                                m_prod.producer_praos_u_lt_t.store(ctx.producer_ctx.praos_u_lt_t, .release);
                                                m_prod.producer_praos_delta_x1e12.store(ctx.producer_ctx.praos_delta_x1e12, .release);
                                                // Producer state digest (v1.2.0)
                                                m_prod.producer_state_digest_w0.store(std.mem.readInt(u64, ctx.producer_ctx.producer_state_digest[0..8], .big), .release);
                                                m_prod.producer_state_digest_w1.store(std.mem.readInt(u64, ctx.producer_ctx.producer_state_digest[8..16], .big), .release);
                                                m_prod.producer_state_digest_w2.store(std.mem.readInt(u64, ctx.producer_ctx.producer_state_digest[16..24], .big), .release);
                                                m_prod.producer_state_digest_w3.store(std.mem.readInt(u64, ctx.producer_ctx.producer_state_digest[24..32], .big), .release);
                                                // Header hash w2/w3 (v1.2.0)
                                                m_prod.producer_candidate_hdr_hash_w2.store(ctx.producer_ctx.candidate_hdr_hash_w2, .release);
                                                m_prod.producer_candidate_hdr_hash_w3.store(ctx.producer_ctx.candidate_hdr_hash_w3, .release);
                                                // Slot scheduler (v1.1.0)
                                                m_prod.producer_schedule_epoch_last.store(ctx.producer_ctx.schedule_epoch_last, .release);
                                                m_prod.producer_schedule_window_start_slot.store(ctx.producer_ctx.schedule_window_start_slot, .release);
                                                m_prod.producer_schedule_window_size.store(ctx.producer_ctx.schedule_window_size, .release);
                                                m_prod.producer_schedule_leaders_in_window.store(ctx.producer_ctx.schedule_leaders_in_window, .release);
                                                m_prod.producer_schedule_next_leader_offset.store(ctx.producer_ctx.schedule_next_leader_offset, .release);
                                                m_prod.producer_schedule_u0_x1e12.store(ctx.producer_ctx.schedule_u0_x1e12, .release);
                                                m_prod.producer_schedule_t_x1e12.store(ctx.producer_ctx.schedule_t_x1e12, .release);
                                                m_prod.producer_schedule_reason_code_last.store(@as(u64, ctx.producer_ctx.schedule_reason_code_last), .release);
                                                m_prod.producer_schedule_compute_total.store(ctx.producer_ctx.schedule_compute_total, .release);
                                                m_prod.producer_schedule_compute_us_total.store(ctx.producer_ctx.schedule_compute_us_total, .release);
                                                m_prod.producer_schedule_last_slot.store(ctx.producer_ctx.schedule_last_slot, .release);
                                                m_prod.producer_schedule_last_update_us.store(ctx.producer_ctx.schedule_last_update_us, .release);
                                                // Execution timing guards (hardening)
                                                m_prod.producer_vrf_compute_us_total.store(ctx.producer_ctx.vrf_compute_us_total, .release);
                                                m_prod.producer_vrf_compute_us_last.store(ctx.producer_ctx.vrf_compute_us_last, .release);
                                                m_prod.producer_tick_us_total.store(ctx.producer_ctx.tick_us_total, .release);
                                                m_prod.producer_tick_us_last.store(ctx.producer_ctx.tick_us_last, .release);
                                                m_prod.producer_tick_us_max.store(ctx.producer_ctx.tick_us_max, .release);
                                                // KES period gate (v1.0.2)
                                                m_prod.producer_kes_current_period.store(ctx.producer_ctx.kes_current_period_last, .release);
                                                m_prod.producer_kes_period_valid_last.store(ctx.producer_ctx.kes_period_valid_last, .release);
                                                m_prod.producer_kes_period_reason_code_last.store(ctx.producer_ctx.kes_period_reason_code_last, .release);
                                                m_prod.producer_kes_start_period.store(ctx.producer_ctx.kes_start_period, .release);
                                                m_prod.producer_kes_max_periods.store(ctx.producer_ctx.kes_max_periods, .release);
                                                // KES lifecycle hardening (v1.1.2)
                                                m_prod.producer_kes_period_start_slot.store(ctx.producer_ctx.kes_period_start_slot, .release);
                                                m_prod.producer_kes_period_end_slot.store(ctx.producer_ctx.kes_period_end_slot, .release);
                                                m_prod.producer_kes_rollovers_total.store(ctx.producer_ctx.kes_rollovers_total, .release);
                                                m_prod.producer_kes_last_rollover_slot.store(ctx.producer_ctx.kes_last_rollover_slot, .release);
                                                m_prod.producer_kes_out_of_range_total.store(ctx.producer_ctx.kes_out_of_range_total, .release);
                                                m_prod.producer_kes_sign_refused_total.store(ctx.producer_ctx.kes_sign_refused_total, .release);
                                                // Pure Zig Ed25519 signing
                                                m_prod.producer_zig_sig_attempt_total.store(ctx.producer_ctx.zig_sig_attempt_total, .release);
                                                m_prod.producer_zig_sig_ok_total.store(ctx.producer_ctx.zig_sig_ok_total, .release);
                                                m_prod.producer_zig_sig_present_last.store(@as(u64, ctx.producer_ctx.zig_sig_present_last), .release);
                                                m_prod.producer_zig_sig_prefix_last.store(ctx.producer_ctx.zig_sig_prefix_last, .release);
                                                m_prod.producer_zig_sig_reason_last.store(@as(u64, ctx.producer_ctx.zig_sig_reason_last), .release);
                                                // KES candidate signing
                                                m_prod.producer_kes_sign_attempt_total.store(ctx.producer_ctx.kes_sign_attempt_total, .release);
                                                m_prod.producer_kes_sign_ok_total.store(ctx.producer_ctx.kes_sign_ok_total, .release);
                                                m_prod.producer_kes_sign_present_last.store(ctx.producer_ctx.kes_sign_present_last, .release);
                                                m_prod.producer_kes_sign_prefix_last.store(ctx.producer_ctx.kes_sign_prefix_last, .release);
                                                m_prod.producer_kes_sign_reason_last.store(ctx.producer_ctx.kes_sign_reason_last, .release);
                                                m_prod.producer_kes_sign_label_last.store(ctx.producer_ctx.kes_sign_label_last, .release);
                                                // Candidate signing proof (v0.9.7)
                                                m_prod.producer_candidate_sig_prefix_last.store(ctx.producer_ctx.candidate_sig_prefix_last, .release);
                                                m_prod.producer_candidate_sign_reason_code_last.store(ctx.producer_ctx.candidate_sign_reason_code_last, .release);
                                                // Key management
                                                m_prod.producer_keys_enabled.store(if (ctx.producer_ctx.key_cfg.enabled) @as(u64, 1) else @as(u64, 0), .release);
                                                m_prod.producer_keys_parse_ok.store(if (ctx.producer_ctx.key_cfg.parse_ok) @as(u64, 1) else @as(u64, 0), .release);
                                                m_prod.producer_keys_validate_total.store(ctx.producer_ctx.key_validate_total, .release);
                                                m_prod.producer_keys_err_code_last.store(@as(u64, ctx.producer_ctx.key_err_code_last), .release);
                                                m_prod.producer_pool_ok.store(@as(u64, ctx.producer_ctx.pool_ok_last), .release);
                                                m_prod.producer_kes_ok.store(@as(u64, ctx.producer_ctx.kes_ok_last), .release);
                                                m_prod.producer_vrf_key_ok.store(@as(u64, ctx.producer_ctx.vrf_ok_last), .release);
                                                m_prod.producer_keys_perms_ok.store(@as(u64, ctx.producer_ctx.perms_ok_last), .release);
                                                m_prod.producer_keys_readable_ok.store(@as(u64, ctx.producer_ctx.readable_ok_last), .release);
                                                // Leader probability model
                                                m_prod.producer_stake_fraction_x1e9.store(ctx.producer_ctx.stake_cfg.stake_fraction_x1e9, .release);
                                                m_prod.producer_active_slot_coeff_x1e6.store(ctx.producer_ctx.stake_cfg.asc_x1e6, .release);
                                                m_prod.producer_expected_leaders_per_epoch.store(ctx.producer_ctx.expected_leaders_per_epoch, .release);
                                                m_prod.producer_leader_reason_code_last.store(@as(u64, ctx.producer_ctx.leader_reason_code_last), .release);
                                                // Eligibility test harness
                                                m_prod.producer_elig_test_enabled.store(@as(u64, if (ctx.producer_ctx.elig_test_enabled) 1 else 0), .release);
                                                m_prod.producer_elig_test_slot_in_epoch.store(ctx.producer_ctx.elig_test_slot_in_epoch, .release);
                                                m_prod.producer_elig_test_window_s.store(ctx.producer_ctx.elig_test_window_s, .release);
                                                m_prod.producer_elig_test_target_end_slot_in_epoch.store(ctx.producer_ctx.elig_test_target_end, .release);
                                                m_prod.producer_elig_test_window_active.store(if (ctx.producer_ctx.leader_eligible_last) @as(u64, 1) else @as(u64, 0), .release);
                                                m_prod.producer_elig_test_override_enabled.store(@as(u64, if (ctx.producer_ctx.elig_test_override_enabled) 1 else 0), .release);
                                                m_prod.producer_elig_test_override_target.store(ctx.producer_ctx.elig_test_override_target, .release);
                                                // Producer dry-run (v1.8.0)
                                                m_prod.producer_dryrun_enabled.store(if (ctx.producer_ctx.dryrun_enabled) @as(u64, 1) else 0, .release);
                                                m_prod.producer_dryrun_slots_checked_total.store(ctx.producer_ctx.dryrun_slots_checked, .release);
                                                m_prod.producer_dryrun_leader_slots_total.store(ctx.producer_ctx.dryrun_leader_slots, .release);
                                                m_prod.producer_dryrun_candidates_built_total.store(ctx.producer_ctx.dryrun_candidates_built, .release);
                                                m_prod.producer_dryrun_candidates_verified_total.store(ctx.producer_ctx.dryrun_candidates_verified, .release);
                                                m_prod.producer_dryrun_last_leader_slot.store(ctx.producer_ctx.dryrun_last_leader_slot, .release);
                                                m_prod.producer_dryrun_last_candidate_unix.store(ctx.producer_ctx.dryrun_last_candidate_unix, .release);
                                                m_prod.producer_dryrun_last_verify_ok.store(ctx.producer_ctx.dryrun_last_verify_ok, .release);
                                                // Real KES signing metrics (v1.8.7)
                                                m_prod.producer_dryrun_candidates_signed_total.store(ctx.producer_ctx.dryrun_candidates_signed, .release);
                                                m_prod.producer_dryrun_last_sign_verify_ok.store(ctx.producer_ctx.dryrun_last_sign_verify_ok, .release);
                                            }

                                            // Persist candidate signing artifacts (v0.9.7)
                                            persistCandidateArtifacts(ctx);
                                            persistVrfArtifacts(ctx);
                                            persistCandidateBodyArtifacts(ctx);
                                            maybeWriteProducerPack(ctx);

                                            // Eligibility edge detection: log when eligible flips 0→1
                                            {
                                                const eligible_now: u8 = if (ctx.producer_ctx.leader_eligible_last) 1 else 0;
                                                if (eligible_now == 1 and ctx.producer_elig_last == 0) {
                                                    const now_elig = compat.timestamp();
                                                    if (now_elig - ctx.last_producer_elig_log_unix >= 60) {
                                                        ctx.last_producer_elig_log_unix = now_elig;
                                                        std.debug.print("PRODUCER ELIG TEST: eligible window hit slot={d} epoch={d} sie={d} target={d} end={d} window={d}s override={d}\n", .{
                                                            tip_slot,
                                                            ctx.producer_ctx.epoch_last,
                                                            ctx.producer_ctx.slot_in_epoch_last,
                                                            ctx.producer_ctx.elig_test_slot_in_epoch,
                                                            ctx.producer_ctx.elig_test_target_end,
                                                            ctx.producer_ctx.elig_test_window_s,
                                                            @as(u64, if (ctx.producer_ctx.elig_test_override_enabled) 1 else 0),
                                                        });
                                                        baeyLogEligEvent(ctx, tip_slot, tip_block);
                                                        baeyLogProducerProof(ctx, tip_slot, tip_block);
                                                    }
                                                }
                                                ctx.producer_elig_last = eligible_now;
                                            }

                                            // State digest computation (every 100 blocks OR 60 seconds)
                                            {
                                                ctx.state_digest_blocks_since += 1;
                                                const now_sd = compat.timestamp();
                                                const blocks_trigger = ctx.state_digest_blocks_since >= 100;
                                                const time_trigger = (now_sd - ctx.last_state_digest_unix >= 60) and ctx.state_digest_blocks_since >= 1;
                                                if (blocks_trigger or time_trigger) {
                                                    if (ctx.lmdb) |*lmdb_sd| {
                                                        if (lmdb_sd.computeStateDigest()) |digest| {
                                                            ctx.state_digest_blocks_since = 0;
                                                            ctx.last_state_digest_unix = now_sd;
                                                            if (ctx.metrics) |ma_sd| {
                                                                const m_sd = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma_sd))));
                                                                m_sd.state_digest_hi.store(std.mem.readInt(u64, digest[0..8], .big), .release);
                                                                m_sd.state_digest_lo.store(std.mem.readInt(u64, digest[8..16], .big), .release);
                                                                m_sd.state_digest_w2.store(std.mem.readInt(u64, digest[16..24], .big), .release);
                                                                m_sd.state_digest_w3.store(std.mem.readInt(u64, digest[24..32], .big), .release);
                                                                const sd_unix: u64 = if (now_sd >= 0) @intCast(now_sd) else 0;
                                                                m_sd.state_digest_unix.store(sd_unix, .release);
                                                            }
                                                        }
                                                    }
                                                }
                                            }

                                            // Memory attribution tick (every 30s or gap delta >=100)
                                            {
                                                const now_ma = compat.timestamp();
                                                const gap_keys_now: u64 = if (ctx.missing_inputs_map) |mm| mm.count() else 0;
                                                const gap_delta = if (gap_keys_now >= ctx.last_mem_attrib_gap_keys)
                                                    gap_keys_now - ctx.last_mem_attrib_gap_keys
                                                else
                                                    ctx.last_mem_attrib_gap_keys - gap_keys_now;
                                                const time_trigger_ma = (now_ma - ctx.last_mem_attrib_unix >= 30);
                                                const delta_trigger_ma = (gap_delta >= 100);
                                                if (time_trigger_ma or delta_trigger_ma) {
                                                    ctx.last_mem_attrib_unix = now_ma;
                                                    ctx.last_mem_attrib_gap_keys = gap_keys_now;
                                                    if (ctx.metrics) |ma_ptr| {
                                                        const ma_m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma_ptr))));
                                                        // Gap attribution: entry_overhead=64, key=36, value varies
                                                        const fs_count: u64 = if (ctx.missing_inputs_first_seen) |fs| fs.count() else 0;
                                                        const ls_count: u64 = if (ctx.missing_inputs_last_seen) |ls| ls.count() else 0;
                                                        const keys_est = @as(u64, @truncate(@min(@as(u128, gap_keys_now) * (64 + 36 + 4), std.math.maxInt(u64))));
                                                        const fs_est = @as(u64, @truncate(@min(@as(u128, fs_count) * (64 + 36 + 8), std.math.maxInt(u64))));
                                                        const ls_est = @as(u64, @truncate(@min(@as(u128, ls_count) * (64 + 36 + 8), std.math.maxInt(u64))));
                                                        const gaps_total = keys_est +| fs_est +| ls_est;
                                                        ma_m.mem_gaps_keys_count.store(gap_keys_now, .release);
                                                        ma_m.mem_gaps_first_seen_count.store(fs_count, .release);
                                                        ma_m.mem_gaps_last_seen_count.store(ls_count, .release);
                                                        ma_m.mem_gaps_keys_bytes_est.store(keys_est, .release);
                                                        ma_m.mem_gaps_first_seen_bytes_est.store(fs_est, .release);
                                                        ma_m.mem_gaps_last_seen_bytes_est.store(ls_est, .release);
                                                        ma_m.mem_gaps_total_bytes_est.store(gaps_total, .release);
                                                        // Mempool attribution
                                                        const mp_items = ma_m.mempool_items.load(.acquire);
                                                        const mp_bytes = ma_m.mempool_bytes.load(.acquire);
                                                        ma_m.mem_mempool_items.store(mp_items, .release);
                                                        ma_m.mem_mempool_bytes_est.store(mp_bytes, .release);
                                                        // Capture attribution (disk-backed)
                                                        const cap_main = ma_m.capture_mainnet_bin_bytes.load(.acquire);
                                                        const cap_seg = ma_m.capture_segments_bytes_total.load(.acquire);
                                                        ma_m.mem_capture_bytes_est.store(cap_main +| cap_seg, .release);
                                                        // LMDB attribution (virtual map)
                                                        ma_m.mem_lmdb_map_bytes.store(ma_m.lmdb_map_size_bytes.load(.acquire), .release);
                                                    }
                                                }
                                            }

                                            // FastSync controller tick (every 30s)
                                            if (ctx.fastsync_enabled) {
                                                const now_fs = compat.timestamp();
                                                if (now_fs - ctx.fastsync_last_eval_unix >= 30) {
                                                    ctx.fastsync_last_eval_unix = now_fs;
                                                    fastsyncTick(ctx, now_fs);
                                                }
                                            }

                                            // Chain density guard (avg3 smoothed, escalating penalty)
                                            if (maybeCheckDensity(ctx, tip_slot)) {
                                                // MIN violation: escalating penalty + reconnect
                                                const density_penalty: f64 = switch (ctx.density_violation_streak) {
                                                    1 => 0.2,
                                                    2 => 0.4,
                                                    else => 0.8,
                                                };
                                                _ = penalizePeerRateLimited(&score, current_relay_idx, density_penalty, .density_violation, compat.timestamp(), ctx.metrics);
                                                peer_was_closed = true;
                                                // BAEY audit
                                                {
                                                    const now_d = compat.timestamp();
                                                    if (now_d - ctx.baey_last_density_unix >= 60) {
                                                        ctx.baey_last_density_unix = now_d;
                                                        baeyLog(ctx, "density_violation", "low_density", "reconnect", tip_slot, tip_block);
                                                    }
                                                }
                                            } else if (ctx.density_max_triggered) {
                                                // MAX violation: mild penalty, reconnect only if strict
                                                _ = penalizePeerRateLimited(&score, current_relay_idx, 0.2, .density_violation, compat.timestamp(), ctx.metrics);
                                                if (densityMaxStrictEnabled()) {
                                                    if (ctx.metrics) |ma| {
                                                        const mm = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                                                        _ = mm.chain_density_max_strict_disconnect_total.fetchAdd(1, .acq_rel);
                                                    }
                                                    peer_was_closed = true;
                                                }
                                            }

                                            // Consensus skeleton: health score + 5m deltas
                                            updateConsensusSkeleton(ctx, now);

                                            // Full BlockFetch on every roll-forward for tx decode + UTxO deltas
                                            // (ChainSync headers carry TX_COUNT=0; full block needed)
                                            if (has_tip_hash) {
                                                if (tip_block != last_blockfetch_trigger_block) {
                                                    last_blockfetch_trigger_block = tip_block;
                                                    if (ctx.debug_verbose) {
                                                        std.debug.print(
                                                            "BLOCKFETCH: full request slot={d} block={d} tip={s}\n",
                                                            .{ tip_slot, tip_block, tip_prefix[0..] },
                                                        );
                                                    }
                                                    blockfetch.requestBlock(
                                                        alloc,
                                                        &bt,
                                                        tip_slot,
                                                        tip_hash32_value,
                                                        tip_block,
                                                        ctx_any,
                                                        onBlockFetched,
                                                    ) catch |err| {
                                                        std.debug.print("BLOCKFETCH: full request error {}\n", .{err});
                                                    };
                                                }
                                            }

                                            // Evict deeply-confirmed undo entries so baseline advances
                                            if (ctx.primary_pipeline) |pp| {
                                                const before = pp.undoDepth();
                                                pp.confirmOldest(@intCast(ctx.rolls_since_last_rollback), UNDO_CONFIRM_DEPTH);
                                                if (pp.undoDepth() < before) {
                                                    std.debug.print("UNDO: confirmed oldest entry; undo_depth={d}\n", .{pp.undoDepth()});
                                                }
                                            } else {
                                                confirmDeepUndos(ctx);
                                            }
                                            shadowConfirmOldest(ctx);

                                            ctx.current_tip = next_msg.roll_forward.tip;
                                            ctx.current_block = next_msg.roll_forward.block;
                                            const body_parts = block_hash.extractBodyParts(full_block_bytes);
                                            const tx_bodies = if (body_parts) |bp| bp.tx_bodies else null;
                                            try callbacks.on_roll_forward(
                                                ctx_any,
                                                tip_slot,
                                                tip_block,
                                                tip_hash32_value,
                                                header_hash32_value,
                                                tx_count,
                                                @intCast(deltas.consumed.len),
                                                @intCast(deltas.produced.len),
                                                tx_summary_result,
                                                tx_bodies,
                                            );
                                            ctx.current_tip = null;
                                            ctx.current_block = null;
                                            awaiting_reply = false;
                                        },
                                        .roll_backward => {
                                            vprint(ctx.debug_verbose, "chainsync[{d}]: roll backward\n", .{steps});
                                            try storeTip(alloc, &last_tip, next_msg.roll_backward.tip);
                                            ctx.rolls_since_last_rollback = 0;

                                            // Apply UTxO rollback if we have state + undo history.
                                            //
                                            // ChainSync rollbacks can happen for forks; we must revert the last applied delta(s)
                                            // to keep our in-memory UTxO consistent with the chain tip.
                                            //
                                            // We currently treat each roll-forward application as pushing one Undo entry.
                                            // On a rollback message, pop one Undo and rollbackDelta().
                                            if (ctx.primary_pipeline) |pp| {
                                                primaryRollback(pp);
                                                shadowRollback(ctx);
                                            } else if (ctx.utxo) |utxo| {
                                                if (ctx.undo_stack) |undo_stack| {
                                                    if (undo_stack.items.len > 0) {
                                                        var undo = undo_stack.pop().?;
                                                        utxo.rollbackDelta(&undo);
                                                        lmdbApplyUndoRollback(ctx, alloc, &undo);
                                                        undo.deinitFreeAddresses();
                                                        std.debug.print(
                                                            "UTXO rollback applied; count={d} undo_depth={d}\n",
                                                            .{ utxo.count(), undo_stack.items.len },
                                                        );
                                                        shadowRollback(ctx);
                                                    } else {
                                                        std.debug.print("UTXO rollback skipped (undo empty); count={d}\n", .{utxo.count()});
                                                    }
                                                } else if (ctx.debug_verbose) {
                                                    std.debug.print("UTXO rollback: no undo_stack\n", .{});
                                                }
                                            } else if (ctx.debug_verbose) {
                                                std.debug.print("UTXO rollback: no utxo\n", .{});
                                            }

                                            // RollBackward applied_tip update: use the rollback POINT
                                            // (LCA we rewound to), NOT the peer's far-tip claim.
                                            // Per Ouroboros ChainSync MsgRollBackward(point, tip):
                                            //   point = where we should rewind TO (this IS our new
                                            //           applied state after the rollback)
                                            //   tip   = peer's current network tip (informational; far
                                            //           ahead of point; we have NOT validated it)
                                            // Prior bug: used .tip — applied_tip claimed peer's far
                                            // tip after every rollback, hash didn't match next
                                            // RollForward's prev_hash, caused refusals.
                                            //
                                            // Keep tip_info / tip_slot / tip_block / tip_hash32_value
                                            // for logging compat (ROLLBACK_TRUTH still wants peer-tip
                                            // info), but DO NOT use them for applied_tip update below.
                                            const tip_info = getTipSlotBlock(next_msg.roll_backward.tip);
                                            const tip_slot: u64 = if (tip_info) |info| info.slot else 0;
                                            const tip_block: u64 = if (tip_info) |info| info.block_no else 0;

                                            var tip_hash32_value: [32]u8 = std.mem.zeroes([32]u8);
                                            if (tipHash32(next_msg.roll_backward.tip)) |hash| {
                                                tip_hash32_value = hash;
                                            }

                                            // ── Stability depth gate (k=2160) ──
                                            // Reject rollbacks deeper than the Cardano stability parameter.
                                            // A rollback this deep indicates either an adversarial peer or
                                            // a catastrophic chain reorganization beyond consensus safety.
                                            {
                                                const current_block = ctx.last_header_block_no;
                                                const rb_depth_est = if (current_block > tip_block) current_block - tip_block else 0;
                                                const within_stability = rb_depth_est <= STABILITY_DEPTH;
                                                std.debug.print("ROLLBACK_TRUTH: depth={d} target_slot={d} target_block={d} current_block={d} within_stability={} stability_depth={d}\n", .{
                                                    rb_depth_est, tip_slot, tip_block, current_block, within_stability, STABILITY_DEPTH,
                                                });
                                                if (!within_stability) {
                                                    std.debug.print("ROLLBACK_DEPTH_EXCEEDED: requested_depth={d} stability_depth={d} action=skip_rollback\n", .{
                                                        rb_depth_est, STABILITY_DEPTH,
                                                    });
                                                    if (ctx.metrics) |ma| {
                                                        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                                                        _ = m.header_rollback_total.fetchAdd(1, .acq_rel);
                                                    }
                                                    // Skip this rollback — do not apply state mutation
                                                    // The peer will likely disconnect or send new data
                                                    awaiting_reply = false;
                                                    continue;
                                                }
                                            }

                                            // ── Soft fork-choice gate (observe mode) ──
                                            // For deep rollbacks (>10 blocks), check peer agreement.
                                            {
                                                const current_block = ctx.last_header_block_no;
                                                const rb_depth = if (current_block > tip_block) current_block - tip_block else 0;
                                                if (rb_depth > 10) {
                                                    var peers_known: u32 = 0;
                                                    var peers_agreeing: u32 = 0;
                                                    const now_rc = compat.timestamp();
                                                    for (ctx.peer_tip_slots, ctx.peer_tip_last_seen) |ps, ls| {
                                                        if (ls == 0 or now_rc - ls > 600) continue;
                                                        peers_known += 1;
                                                        if (ps >= tip_slot) peers_agreeing += 1;
                                                    }
                                                    const confidence: []const u8 = if (peers_agreeing >= 2 or peers_known < 2) "high" else if (peers_agreeing == 1) "medium" else "low";
                                                    std.debug.print("ROLLBACK_PEER_CHECK: depth={d} target_slot={d} peers_agreeing={d} peers_known={d} confidence={s}\n", .{
                                                        rb_depth, tip_slot, peers_agreeing, peers_known, confidence,
                                                    });
                                                    if (peers_agreeing == 0 and peers_known >= 2) {
                                                        ctx.rollback_low_confidence_total += 1;
                                                        std.debug.print("ROLLBACK_CONFIDENCE_LOW: depth={d} target_slot={d} peers_agreeing=0 low_confidence_total={d} action=warn\n", .{
                                                            rb_depth, tip_slot, ctx.rollback_low_confidence_total,
                                                        });
                                                    }
                                                }
                                            }

                                            // Header chain: rewind HEAD on rollback + track depth
                                            if (ctx.header_store) |*hs| {
                                                const old_height = ctx.header_height;
                                                const zero_hash = std.mem.zeroes([32]u8);
                                                if (!std.mem.eql(u8, tip_hash32_value[0..], zero_hash[0..])) {
                                                    // Lookup the rollback target in header DB
                                                    if (hs.beginRead()) |rtxn0| {
                                                        var rtxn = rtxn0;
                                                        defer hs.abort(&rtxn);
                                                        if (hs.getHeader(&rtxn, tip_hash32_value)) |rec| {
                                                            // Found: rewind to stored height
                                                            if (hs.beginWrite()) |wtxn0| {
                                                                var wtxn = wtxn0;
                                                                // Walk from old HEAD to rollback target, deleting slot index entries
                                                                if (ctx.header_head) |old_head| {
                                                                    var walk_hash = old_head;
                                                                    var walk_steps: u32 = 0;
                                                                    while (walk_steps < 200) : (walk_steps += 1) {
                                                                        if (std.mem.eql(u8, &walk_hash, &tip_hash32_value)) break;
                                                                        if (hs.getHeader(&rtxn, walk_hash)) |wrec| {
                                                                            hs.deleteSlotIndex(&wtxn, wrec.slot);
                                                                            walk_hash = wrec.prev_hash;
                                                                        } else break;
                                                                    }
                                                                }
                                                                hs.setHead(&wtxn, tip_hash32_value);
                                                                hs.setHeight(&wtxn, rec.height);
                                                                if (hs.commit(&wtxn)) {
                                                                    ctx.header_head = tip_hash32_value;
                                                                    ctx.header_height = rec.height;
                                                                    ctx.last_header_slot = rec.slot;
                                                                    ctx.last_header_block_no = rec.block_no;
                                                                    if (ctx.metrics) |ma| {
                                                                        const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                                                                        m.header_height.store(rec.height, .release);
                                                                    }
                                                                }
                                                            }
                                                        } else {
                                                            std.debug.print("HEADER STORE: rollback target not in DB, resetting\n", .{});
                                                            ctx.header_head = null;
                                                            ctx.header_height = 0;
                                                            ctx.last_header_slot = 0;
                                                            ctx.last_header_block_no = 0;
                                                            ctx.header_head_stable = false;
                                                            ctx.header_stable_consecutive = 0;
                                                            if (ctx.metrics) |ma| {
                                                                const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                                                                m.header_height.store(0, .release);
                                                            }
                                                        }
                                                    }
                                                }

                                                // Rollback metrics
                                                const rb_depth = if (old_height >= ctx.header_height) old_height - ctx.header_height else 0;
                                                if (ctx.metrics) |ma| {
                                                    const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                                                    _ = m.header_rollback_total.fetchAdd(1, .acq_rel);
                                                    m.header_rollback_depth_last.store(rb_depth, .release);
                                                }

                                                // Authority model: record reorg
                                                updateAuthorityModel(ctx, tip_slot, tip_block, tip_hash32_value, true, rb_depth);

                                                // Rollback flap guard
                                                if (maybeUpdateRollbackFlap(ctx, rb_depth)) {
                                                    _ = penalizePeerRateLimited(&score, current_relay_idx, 0.5, .other, compat.timestamp(), ctx.metrics);
                                                    peer_was_closed = true;
                                                }
                                            }

                                            // v1.5.9: set rollback stabilization window
                                            {
                                                const now_stab = compat.timestamp();
                                                ctx.rollback_stabilize_until_unix = now_stab + ROLLBACK_STABILIZE_S;
                                                if (ctx.metrics) |ma| {
                                                    const m = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                                                    m.rollback_stabilize_active.store(1, .release);
                                                }
                                            }

                                            ctx.current_tip = next_msg.roll_backward.tip;
                                            ctx.current_block = null;
                                            ctx.current_point = next_msg.roll_backward.point;

                                            // Extract point (slot, hash) from rollback target.
                                            // Format per Ouroboros: point = (slot, hash) 2-tuple,
                                            // OR () for origin/genesis rollback.
                                            var point_slot: u64 = 0;
                                            var point_hash: [32]u8 = std.mem.zeroes([32]u8);
                                            var point_block: u64 = 0;
                                            {
                                                const pt = next_msg.roll_backward.point;
                                                if (pt == .array and pt.array.len == 2) {
                                                    if (pt.array[0] == .u64) point_slot = pt.array[0].u64;
                                                    // hash may be raw bytes(32) or tag-wrapped bytes(32)
                                                    const hash_term = pt.array[1];
                                                    if (hash_term == .bytes and hash_term.bytes.len == 32) {
                                                        @memcpy(&point_hash, hash_term.bytes[0..32]);
                                                    } else if (hash_term == .tag) {
                                                        const inner = hash_term.tag.value.*;
                                                        if (inner == .bytes and inner.bytes.len == 32) {
                                                            @memcpy(&point_hash, inner.bytes[0..32]);
                                                        }
                                                    }
                                                }
                                                // Look up block_no in header_store by point hash.
                                                // If not present (deep rollback, fresh start, origin),
                                                // leave point_block=0 — applied_tip's block_no field
                                                // will be 0 until next RollForward updates it.
                                                if (ctx.header_store) |*hs| {
                                                    if (hs.beginRead()) |rtxn0| {
                                                        var rtxn = rtxn0;
                                                        defer hs.abort(&rtxn);
                                                        if (hs.getHeader(&rtxn, point_hash)) |rec| {
                                                            point_block = rec.block_no;
                                                        }
                                                    }
                                                }
                                            }
                                            std.debug.print("ROLLBACK_POINT: slot={d} block={d} hash_first8={x} peer_tip_slot={d} peer_tip_block={d}\n", .{
                                                point_slot, point_block, point_hash[0..8],
                                                tip_slot, tip_block,
                                            });

                                            // Audit s4-t1 HIGH-1 (refined): update applied_tip to the
                                            // rollback POINT, not peer's far tip. Serialized via
                                            // tip_mutex for atomic snapshot. The .tip value is kept
                                            // for logging only (ROLLBACK_TRUTH already uses it).
                                            ctx.producer_ctx.tip_mutex.lock();
                                            ctx.producer_ctx.tip_slot_last = point_slot;
                                            ctx.producer_ctx.tip_hash_last = point_hash;
                                            ctx.producer_ctx.tip_block_last = point_block;
                                            ctx.producer_ctx.tip_mutex.unlock();

                                            // Phase 8.65: record fork event for signal layer
                                            signals.recordForkEvent();
                                            try callbacks.on_roll_backward(
                                                ctx_any,
                                                tip_slot,
                                                tip_block,
                                                tip_hash32_value,
                                                point_slot,
                                                point_block,
                                                point_hash,
                                            );
                                            ctx.current_tip = null;
                                            ctx.current_point = null;
                                            awaiting_reply = false;
                                        },
                                        else => {
                                            vprint(ctx.debug_verbose, "chainsync[{d}]: no response\n", .{steps});
                                            awaiting_reply = false;
                                        },
                                    }
                                } else if (next_hdr.proto == 3) {
                                    // BlockFetch protocol response
                                    vprint(ctx.debug_verbose, "mux: rx proto=3 len={d}\n", .{next_hdr.len});
                                    blockfetch.handleResponse(alloc, next_seg.?.payload) catch |err| {
                                        std.debug.print("BLOCKFETCH: handle error {}\n", .{err});
                                    };
                                    if (blockfetch.g_body_hash_mismatch) {
                                        blockfetch.g_body_hash_mismatch = false;
                                        std.debug.print("BODY HASH: mismatch detected, triggering reconnect\n", .{});
                                        _ = penalizePeerRateLimited(&score, current_relay_idx, 0.5, .authority_fail, compat.timestamp(), ctx.metrics);
                                        peer_was_closed = true;
                                    }
                                    continue;
                                } else if (next_hdr.proto == txsubmission_proto) {
                                    // TxSubmission protocol message (no-op responder)
                                    vprint(ctx.debug_verbose, "mux: rx proto=4 (txsub) len={d}\n", .{next_hdr.len});
                                    txsubmission.handleMessage(alloc, &bt, next_seg.?.payload, ctx.debug_verbose);
                                    continue;
                                } else if (next_hdr.proto == keepalive_proto) {
                                    vprint(ctx.debug_verbose, "mux: rx proto=8 (keepalive) len={d}\n", .{next_hdr.len});
                                    keepalive.handleMessage(alloc, &bt, next_seg.?.payload, ctx.debug_verbose);
                                    if (ctx.metrics) |ma| {
                                        const m_ka2 = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                                        m_ka2.consensus_last_keepalive_pong_unix.store(@intCast(compat.timestamp()), .release);
                                    }
                                    continue;
                                } else {
                                    vprint(ctx.debug_verbose, "mux: rx unexpected proto={d}\n", .{next_hdr.proto});
                                    continue;
                                }
                            }
                        }
                    },
                    .intersect_not_found => {
                        vprint(ctx.debug_verbose, "chainsync: intersect not found\n", .{});
                        // PRIMARY OBSERVABILITY: explicit IntersectNotFound counter + log.
                        if (ctx.metrics) |ma_inf| {
                            const m_inf = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma_inf))));
                            _ = m_inf.primary_intersect_not_found_total.fetchAdd(1, .acq_rel);
                        }
                        if (getTipSlotBlock(msg.intersect_not_found.tip)) |tsb_inf| {
                            std.debug.print(
                                "PRIMARY_INTERSECT_NOT_FOUND: relay_tip_slot={d} relay_tip_block={d} (cursor not on canonical chain — recovery engaged)\n",
                                .{ tsb_inf.slot, tsb_inf.block_no },
                            );
                        } else {
                            std.debug.print(
                                "PRIMARY_INTERSECT_NOT_FOUND: tip_parse=NULL (cursor not on canonical chain)\n",
                                .{},
                            );
                            logTipShapeSummary("INTERSECT_NOT_FOUND.tip", msg.intersect_not_found.tip);
                            if (ctx.metrics) |ma_pn3| {
                                const m_pn3 = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma_pn3))));
                                _ = m_pn3.primary_tip_parse_null_total.fetchAdd(1, .acq_rel);
                            }
                        }

                        // INTERSECT_NOT_FOUND RECOVERY — bounded continuity negotiation.
                        // First IntersectNotFound on a fresh connection: the multi-point
                        // FindIntersect (built from cursor + header_store ladder) was rejected;
                        // attempt in-connection origin fallback (one shot, major continuity
                        // event — fully observable).
                        // If origin is ALSO rejected: log _ABORT, disconnect, reconnect.
                        // No retry storm, no infinite descent, no cursor mutation.
                        if (intersect_recovery_attempted) {
                            std.debug.print(
                                "PRIMARY_INTERSECT_RECOVERY_ABORT: reason=origin_also_rejected disconnect=true\n",
                                .{},
                            );
                            peer_was_closed = true;
                            break :outer;
                        }
                        intersect_recovery_attempted = true;

                        std.debug.print(
                            "PRIMARY_INTERSECT_RECOVERY_ORIGIN: reason=all_candidates_rejected (in-connection origin fallback)\n",
                            .{},
                        );
                        if (ctx.metrics) |ma_or| {
                            const m_or = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma_or))));
                            _ = m_or.primary_intersect_recovery_origin_total.fetchAdd(1, .acq_rel);
                        }

                        // OWNERSHIP DISCIPLINE — ORIGIN FALLBACK BUFFERS (switch-arm scope):
                        //   origin_list    — OWNS its backing buffer until toOwnedSlice
                        //                    moves ownership to origin_bytes; deinit
                        //                    afterward is a no-op on the empty list.
                        //   origin_bytes   — heap, OWNED here; freed by single defer
                        //                    below. Fires exactly once on arm exit.
                        // The origin request must send a points list CONTAINING the origin
                        // point ([[]]), not an empty points list ([]). See
                        // chainsync_codec.encodeFindIntersectOrigin.
                        var origin_list = std.array_list.Managed(u8).init(alloc);
                        defer origin_list.deinit();
                        chainsync_codec.encodeFindIntersectOrigin(compat.listWriter(&origin_list)) catch |err| {
                            std.debug.print(
                                "PRIMARY_INTERSECT_RECOVERY_ORIGIN_ENCODE_FAIL: err={s} → reconnecting\n",
                                .{@errorName(err)},
                            );
                            peer_was_closed = true;
                            break :outer;
                        };
                        const origin_bytes = origin_list.toOwnedSlice() catch |err| {
                            std.debug.print(
                                "PRIMARY_INTERSECT_RECOVERY_ORIGIN_BYTES_FAIL: err={s} → reconnecting\n",
                                .{@errorName(err)},
                            );
                            peer_was_closed = true;
                            break :outer;
                        };
                        std.debug.print(
                            "PRIMARY_INTERSECT_RECOVERY_ORIGIN_BUF_ALLOC: bytes={d}\n",
                            .{origin_bytes.len},
                        );
                        defer {
                            std.debug.print(
                                "PRIMARY_INTERSECT_RECOVERY_ORIGIN_BUF_FREE: bytes={d}\n",
                                .{origin_bytes.len},
                            );
                            alloc.free(origin_bytes);
                        }
                        mux_bearer.sendSegment(&bt, .responder, chainsync_proto, origin_bytes) catch |err| {
                            std.debug.print(
                                "PRIMARY_INTERSECT_RECOVERY_ORIGIN_SEND_FAIL: err={s} → reconnecting\n",
                                .{@errorName(err)},
                            );
                            peer_was_closed = true;
                            break :outer;
                        };
                        std.debug.print(
                            "PRIMARY_INTERSECT_RECOVERY_ORIGIN_SENT: bytes={d} proto=chainsync\n",
                            .{origin_bytes.len},
                        );
                        continue :outer;
                    },
                    else => {
                        vprint(ctx.debug_verbose, "chainsync: no response\n", .{});
                        // PRIMARY OBSERVABILITY: unexpected chainsync message tag log.
                        std.debug.print(
                            "PRIMARY_CHAINSYNC_UNEXPECTED: tag={s} (will reconnect)\n",
                            .{@tagName(msg)},
                        );
                        continue :outer;
                    },
                }
                continue;
            } else if (hdr.proto == 3) {
                // BlockFetch protocol response
                vprint(ctx.debug_verbose, "mux: rx proto=3 len={d}\n", .{hdr.len});
                blockfetch.handleResponse(alloc, seg.?.payload) catch |err| {
                    std.debug.print("BLOCKFETCH: handle error {}\n", .{err});
                };
                if (blockfetch.g_body_hash_mismatch) {
                    blockfetch.g_body_hash_mismatch = false;
                    std.debug.print("BODY HASH: mismatch detected, triggering reconnect\n", .{});
                    _ = penalizePeerRateLimited(&score, current_relay_idx, 0.5, .authority_fail, compat.timestamp(), ctx.metrics);
                    peer_was_closed = true;
                }
                continue;
            } else if (hdr.proto == txsubmission_proto) {
                // TxSubmission protocol message (no-op responder)
                vprint(ctx.debug_verbose, "mux: rx proto=4 (txsub) len={d}\n", .{hdr.len});
                txsubmission.handleMessage(alloc, &bt, seg.?.payload, ctx.debug_verbose);
                continue;
            } else if (hdr.proto == keepalive_proto) {
                vprint(ctx.debug_verbose, "mux: rx proto=8 (keepalive) len={d}\n", .{hdr.len});
                keepalive.handleMessage(alloc, &bt, seg.?.payload, ctx.debug_verbose);
                if (ctx.metrics) |ma| {
                    const m_ka3 = @as(*http_metrics.Metrics, @ptrCast(@alignCast(@constCast(ma))));
                    m_ka3.consensus_last_keepalive_pong_unix.store(@intCast(compat.timestamp()), .release);
                }
                continue;
            } else {
                vprint(ctx.debug_verbose, "mux: rx unexpected proto={d}\n", .{hdr.proto});
                continue;
            }
        }

        if (shutdown_requested) {
            callbacks.on_shutdown(ctx_any);
            return;
        }
        if (!peer_was_closed) return;

        // Full-jitter backoff with Bayesian relay selection
        if (jitterBackoffSleep(backoff_attempt, max_backoff_seconds, 1, &should_stop)) return;
        backoff_attempt +|= 1;
        backoff_seconds = @min(backoff_seconds * 2, max_backoff_seconds);
        _ = penalizePeerRateLimited(&score, current_relay_idx, 0.2, .other, compat.timestamp(), ctx.metrics);
        current_relay_idx = pickRelay(&score, ctx.metrics);
    }
}

// ── Chain tip header capture for propagation ────────────────────────
//
// Saves the latest validated header CBOR bytes to $TSUNAGI_HOME/chain_tip/
// for use by `guardian seal-tip` → `propagate-serve`.
// Rate-limited to at most once per 10 seconds to avoid IO thrash during sync.
//
// IMPORTANT (v4.5.11): slot/block_no for meta.json are parsed from the
// actual header CBOR, NOT from the upstream RollForward tip.  The tip
// can be 1+ blocks ahead of the header being captured.

var g_last_chain_tip_save_unix: i64 = 0;

pub const FragmentTail = struct {
    slot: u64,
    block_no: u64,
    hash: [32]u8,
};

pub fn saveChainTipHeader(
    inner_bytes: []const u8,
    hash: [32]u8,
    tip_slot: u64,
    tip_block_no: u64,
    block_body: []const u8,
    out_frag_tail: *?FragmentTail,
) void {
    if (inner_bytes.len == 0) return;

    const now = compat.timestamp();

    // Parse authoritative slot/block_no from the actual header CBOR.
    // tip_slot/tip_block_no come from upstream RollForward tip and may
    // describe a LATER block — they are peer-tip-domain, not delivered.
    const hdr_fields = parseHeaderSlotAndBlockNo(inner_bytes);
    const delivered_slot = if (hdr_fields) |f| f.slot else tip_slot;
    const delivered_block_no = if (hdr_fields) |f| f.block_no else tip_block_no;
    // Aliases retained for downstream fragment-tail / journal logic that
    // already treats these as the delivered (header-parsed) values.
    const hdr_slot = delivered_slot;
    const hdr_block_no = delivered_block_no;

    // Phase B'''': CHAIN_TIP_HEADER renamed tip_mismatch -> peer_divergence
    // with explicit delta fields. Predicate unchanged (unconditional
    // emission of the comparison preserved per "every fix adds gates,
    // never weakens" doctrine — MAJOR-1 closure from Phase C).
    if (hdr_fields != null and (delivered_slot != tip_slot or delivered_block_no != tip_block_no)) {
        const b_delta: u64 = if (tip_block_no >= delivered_block_no) tip_block_no - delivered_block_no else 0;
        const s_delta: u64 = if (tip_slot >= delivered_slot) tip_slot - delivered_slot else 0;
        std.debug.print("CHAIN_TIP_HEADER: peer_divergence delta_blocks={d} delta_slots={d} peer_block={d} peer_slot={d} delivered_block={d} delivered_slot={d}\n", .{
            b_delta, s_delta, tip_block_no, tip_slot, delivered_block_no, delivered_slot,
        });
    }

    const pa = std.heap.page_allocator;
    const home = compat.getEnvVarOwned(pa, "TSUNAGI_HOME") catch return;
    defer pa.free(home);

    const dir_path = std.fmt.allocPrint(pa, "{s}/chain_tip", .{home}) catch return;
    defer pa.free(dir_path);

    compat.fs.cwd().makePath(dir_path) catch return;

    // ── Step 1: Read CURRENT tip from disk (before overwriting) ────
    // This data is needed for fragment chain verification.

    // Parse NEW header's prevHash
    const new_prev_hash = parseHeaderPrevHash(inner_bytes);

    // Read CURRENT tip hash
    var cur_hash_path_buf: [512]u8 = undefined;
    const cur_hash_path = std.fmt.bufPrint(&cur_hash_path_buf, "{s}/header_hash.hex", .{dir_path}) catch "";
    var cur_hash: ?[32]u8 = null;
    if (cur_hash_path.len > 0) {
        if (tipReadFile(cur_hash_path)) |hex_data| {
            defer pa.free(hex_data);
            const trimmed = std.mem.trim(u8, hex_data, " \t\r\n");
            if (trimmed.len == 64) {
                var h: [32]u8 = undefined;
                if (tipParseHex64(trimmed, &h)) cur_hash = h;
            }
        }
    }

    // Read CURRENT tip header CBOR
    var cur_hdr_path_buf: [512]u8 = undefined;
    const cur_hdr_path = std.fmt.bufPrint(&cur_hdr_path_buf, "{s}/header.cbor", .{dir_path}) catch "";
    var cur_cbor: ?[]u8 = null;
    if (cur_hdr_path.len > 0) cur_cbor = tipReadFile(cur_hdr_path);
    defer if (cur_cbor) |cc| pa.free(cc);

    // Read CURRENT tip block body CBOR (for fragment append)
    var cur_body_path_buf: [512]u8 = undefined;
    const cur_body_path = std.fmt.bufPrint(&cur_body_path_buf, "{s}/block.cbor", .{dir_path}) catch "";
    var cur_block_body: ?[]u8 = null;
    if (cur_body_path.len > 0) cur_block_body = tipReadFile(cur_body_path);
    defer if (cur_block_body) |cb| pa.free(cb);

    var cur_slot: ?u64 = null;
    var cur_block_no: ?u64 = null;
    var cur_prev_hash: ?[32]u8 = null;
    if (cur_cbor) |cc| {
        if (parseHeaderSlotAndBlockNo(cc)) |f| {
            cur_slot = f.slot;
            cur_block_no = f.block_no;
        }
        cur_prev_hash = parseHeaderPrevHash(cc);
    }

    // ── Step 2: ALWAYS write header.cbor + header_hash.hex ──────────
    // This must happen on EVERY call so the on-disk tip is always current.
    // Otherwise, the 10s rate limit creates gaps that break fragment chaining.

    // header.cbor
    if (!tipWriteAtomic(dir_path, "header.cbor", inner_bytes)) return;

    // header_hash.hex
    const hex_chars = "0123456789abcdef";
    var hash_hex: [64]u8 = undefined;
    for (hash, 0..) |b, i| {
        hash_hex[i * 2] = hex_chars[b >> 4];
        hash_hex[i * 2 + 1] = hex_chars[b & 0xf];
    }
    _ = tipWriteAtomic(dir_path, "header_hash.hex", &hash_hex);

    // block.cbor — write full block body (must stay in sync with header.cbor)
    if (block_body.len > 0) {
        _ = tipWriteAtomic(dir_path, "block.cbor", block_body);
    }

    // ── Step 3: Chain-verified rolling fragment store (ALWAYS) ──────
    // Fragment append MUST run on every call to capture every block.
    // Rate-limiting fragment appends causes contiguity gaps because
    // header.cbor advances every call but the fragment falls behind.
    //
    // The fragment must be a contiguous ancestor chain of the sealed tip.
    // A new header H_new may extend the fragment only if:
    //   1. H_new.prevHash == current_tip.hash  (direct successor)
    //   2. H_new.block_no == current_tip.block_no + 1
    //   3. H_new.slot > current_tip.slot
    // If any condition fails → reset fragment and re-anchor.
    //
    // We append the CURRENT tip (read above, now displaced) into the fragment,
    // after verifying it chains to the fragment tail.
    {
        var frag_dir_buf: [512]u8 = undefined;
        const frag_dir = std.fmt.bufPrint(&frag_dir_buf, "{s}/fragment", .{dir_path}) catch "";
        if (frag_dir.len > 0) {
            compat.fs.cwd().makePath(frag_dir) catch {};

            // Successor check: is the NEW header a direct successor of CURRENT tip?
            var is_successor = false;
            var reset_reason: ?[]const u8 = null;

            if (new_prev_hash != null and cur_hash != null and
                cur_slot != null and cur_block_no != null)
            {
                if (!std.mem.eql(u8, &new_prev_hash.?, &cur_hash.?)) {
                    reset_reason = "prev_hash_mismatch";
                } else if (hdr_block_no != cur_block_no.? + 1) {
                    reset_reason = "block_no_gap";
                } else if (hdr_slot <= cur_slot.?) {
                    reset_reason = "slot_non_monotonic";
                } else {
                    is_successor = true;
                }
            } else if (cur_hash == null) {
                reset_reason = "no_current_tip";
            } else {
                reset_reason = "parse_failure";
            }

            if (is_successor) {
                // Current tip is the verified parent of the new header.
                // Check if current tip chains to fragment tail.
                const tail_hash = fragmentTailHash(frag_dir);
                var append_ok = false;

                if (tail_hash == null) {
                    // Empty fragment → anchor current tip as entry 0
                    append_ok = true;
                } else if (cur_prev_hash != null and std.mem.eql(u8, &cur_prev_hash.?, &tail_hash.?)) {
                    // Current tip's prevHash matches fragment tail → contiguous
                    append_ok = true;
                } else {
                    // Current tip doesn't chain to fragment tail → reset + anchor
                    std.debug.print("FRAGMENT: reset reason=tail_chain_break tail_hash={x} cur_prevHash={x}\n", .{
                        if (tail_hash) |th| th[0..8] else &[_]u8{0} ** 8,
                        if (cur_prev_hash) |cp| cp[0..8] else &[_]u8{0} ** 8,
                    });
                    fragmentWipe(frag_dir);
                    append_ok = true;
                }

                if (append_ok) {
                    fragmentAppendEntry(frag_dir, dir_path, cur_cbor.?, cur_hash.?, cur_slot.?, cur_block_no.?, cur_block_body, cur_prev_hash);
                    fragmentPrune(frag_dir, 2160);
                    const depth = fragmentCount(frag_dir);
                    const oldest_frag_slot = fragmentOldestSlot(frag_dir);
                    std.debug.print("FRAGMENT: append slot={d} block_no={d} depth={d} oldest_slot={d} newest_slot={d}\n", .{
                        cur_slot.?, cur_block_no.?, depth, oldest_frag_slot, cur_slot.?,
                    });
                    // Export canonical fragment tail for forge parent anchoring
                    out_frag_tail.* = .{ .slot = cur_slot.?, .block_no = cur_block_no.?, .hash = cur_hash.? };
                }
            } else {
                // Not a direct successor — check for rollback re-anchor before wiping
                var rollback_anchored = false;
                if (new_prev_hash != null and
                    reset_reason != null and std.mem.eql(u8, reset_reason.?, "prev_hash_mismatch"))
                {
                    rollback_anchored = fragmentRollbackToHash(frag_dir, new_prev_hash.?);
                    if (rollback_anchored) {
                        const depth = fragmentCount(frag_dir);
                        const oldest_frag_slot = fragmentOldestSlot(frag_dir);
                        std.debug.print("FRAGMENT: rollback re-anchor new_prevHash={x} depth={d} oldest_slot={d}\n", .{
                            new_prev_hash.?[0..8],
                            depth,
                            oldest_frag_slot,
                        });
                    }
                }
                if (!rollback_anchored) {
                    std.debug.print("FRAGMENT: reset reason={s} new_slot={d} new_block_no={d} new_prevHash={x} cur_hash={x}\n", .{
                        reset_reason orelse "unknown",
                        hdr_slot,
                        hdr_block_no,
                        if (new_prev_hash) |np| np[0..8] else &[_]u8{0} ** 8,
                        if (cur_hash) |ch| ch[0..8] else &[_]u8{0} ** 8,
                    });
                    if (cur_slot != null and cur_block_no != null) {
                        std.debug.print("FRAGMENT: cur_slot={d} cur_block_no={d}\n", .{ cur_slot.?, cur_block_no.? });
                    }
                    fragmentWipe(frag_dir);
                }
            }

            // prev_header: only set if verified successor
            if (is_successor and cur_cbor != null and cur_hash != null) {
                _ = tipWriteAtomic(dir_path, "prev_header.cbor", cur_cbor.?);
                const hex_chars2 = "0123456789abcdef";
                var prev_hash_hex_buf: [64]u8 = undefined;
                for (cur_hash.?, 0..) |b, i| {
                    prev_hash_hex_buf[i * 2] = hex_chars2[b >> 4];
                    prev_hash_hex_buf[i * 2 + 1] = hex_chars2[b & 0xf];
                }
                _ = tipWriteAtomic(dir_path, "prev_header_hash.hex", &prev_hash_hex_buf);
            } else {
                std.debug.print("FRAGMENT: no verified parent for prev_header\n", .{});
            }
        }
    }

    // ── Step 4: meta.json + verbose log (rate-limited to avoid IO thrash) ──
    if (now - g_last_chain_tip_save_unix < 10) return;
    g_last_chain_tip_save_unix = now;

    var meta_buf: [256]u8 = undefined;
    const meta_json = std.fmt.bufPrint(&meta_buf,
        \\{{"slot":{d},"block_no":{d},"unix":{d}}}
    , .{ hdr_slot, hdr_block_no, now }) catch return;
    _ = tipWriteAtomic(dir_path, "meta.json", meta_json);

    std.debug.print("CHAIN_TIP_HEADER: saved slot={d} block_no={d} hash={x} hdr_len={d}\n", .{
        hdr_slot,
        hdr_block_no,
        hash[0..8],
        inner_bytes.len,
    });
}

/// Parse slot and block_no from raw header CBOR.
/// Header format: [header_body, kes_signature]
/// header_body[0] = block_number, header_body[1] = slot
// DELIVERED_HEADER_PARSE observability — dumps the CBOR structural signature of a
// header that parseHeaderSlotAndBlockNo refuses, plus a coarse era classification
// based on the structure. READ-ONLY; never mutates anything. Called only from the
// refusal log site, never from any decision path.
//
// Emits, in order:
//   DELIVERED_HEADER_PARSE_BEGIN: len=N first4=BYTES
//   DELIVERED_HEADER_PARSE_SHAPE: top_kind=... top_len=... body_kind=... body_len=...
//                                  body0_kind=... body0_val=... body1_kind=... body1_val=...
//   DELIVERED_HEADER_PARSE_REJECT: stage=...
//   DELIVERED_HEADER_PARSE_ERA: guess=... reason=...
//   DELIVERED_HEADER_PARSE_REASON: ...
fn dumpHeaderShapeAndClassify(label: []const u8, header_cbor: []const u8) void {
    // Header byte preamble (first 4 raw bytes give CBOR major + initial structure).
    var preamble: [4]u8 = .{ 0, 0, 0, 0 };
    {
        var i: usize = 0;
        while (i < 4 and i < header_cbor.len) : (i += 1) preamble[i] = header_cbor[i];
    }
    std.debug.print(
        "DELIVERED_HEADER_PARSE_BEGIN: label={s} len={d} first4={x:0>2}{x:0>2}{x:0>2}{x:0>2}\n",
        .{ label, header_cbor.len, preamble[0], preamble[1], preamble[2], preamble[3] },
    );

    if (header_cbor.len == 0) {
        std.debug.print(
            "DELIVERED_HEADER_PARSE_REJECT: stage=empty_bytes\n" ++
                "DELIVERED_HEADER_PARSE_ERA: guess=unknown reason=no_bytes\n" ++
                "DELIVERED_HEADER_PARSE_REASON: header_cbor.len==0\n",
            .{},
        );
        return;
    }

    const pa = std.heap.page_allocator;
    var fbs = compat.fixedBufferStream(header_cbor);
    const top_or_err = cbor.decode(pa, fbs.reader());
    if (top_or_err) |top_v| {
        const top = top_v;
        defer cbor.free(top, pa);

        // Top-level shape
        const top_kind: []const u8 = switch (top) {
            .array => "array",
            .u64 => "u64",
            .i64 => "i64",
            .bytes => "bytes",
            .text => "text",
            .map_u64 => "map_u64",
            .tag => "tag",
            .bool => "bool",
            .null => "null",
        };
        const top_len: usize = if (top == .array) top.array.len else 0;

        if (top != .array or top.array.len < 1) {
            std.debug.print(
                "DELIVERED_HEADER_PARSE_SHAPE: top_kind={s} top_len={d}\n" ++
                    "DELIVERED_HEADER_PARSE_REJECT: stage=top_not_array_or_empty\n" ++
                    "DELIVERED_HEADER_PARSE_ERA: guess=unknown reason=top_shape_unexpected\n" ++
                    "DELIVERED_HEADER_PARSE_REASON: parser expected top:array(len>=1) got top_kind={s} top_len={d}\n",
                .{ top_kind, top_len, top_kind, top_len },
            );
            return;
        }

        const body = top.array[0];
        const body_kind: []const u8 = switch (body) {
            .array => "array",
            .u64 => "u64",
            .i64 => "i64",
            .bytes => "bytes",
            .text => "text",
            .map_u64 => "map_u64",
            .tag => "tag",
            .bool => "bool",
            .null => "null",
        };
        const body_len: usize = if (body == .array) body.array.len else 0;

        if (body != .array or body.array.len < 2) {
            std.debug.print(
                "DELIVERED_HEADER_PARSE_SHAPE: top_kind=array top_len={d} body_kind={s} body_len={d}\n" ++
                    "DELIVERED_HEADER_PARSE_REJECT: stage=body_not_array_or_short\n" ++
                    "DELIVERED_HEADER_PARSE_ERA: guess=byron_or_pre_shelley reason=body_not_2plus_array\n" ++
                    "DELIVERED_HEADER_PARSE_REASON: parser expected body:array(len>=2) got body_kind={s} body_len={d}\n",
                .{ top_len, body_kind, body_len, body_kind, body_len },
            );
            return;
        }

        const b0 = body.array[0];
        const b1 = body.array[1];
        const b0_kind: []const u8 = switch (b0) {
            .array => "array",
            .u64 => "u64",
            .i64 => "i64",
            .bytes => "bytes",
            .text => "text",
            .map_u64 => "map_u64",
            .tag => "tag",
            .bool => "bool",
            .null => "null",
        };
        const b1_kind: []const u8 = switch (b1) {
            .array => "array",
            .u64 => "u64",
            .i64 => "i64",
            .bytes => "bytes",
            .text => "text",
            .map_u64 => "map_u64",
            .tag => "tag",
            .bool => "bool",
            .null => "null",
        };
        const b0_val: u64 = if (b0 == .u64) b0.u64 else 0;
        const b1_val: u64 = if (b1 == .u64) b1.u64 else 0;

        std.debug.print(
            "DELIVERED_HEADER_PARSE_SHAPE: top_kind=array top_len={d} body_kind=array body_len={d} body0_kind={s} body0_val={d} body1_kind={s} body1_val={d}\n",
            .{ top_len, body_len, b0_kind, b0_val, b1_kind, b1_val },
        );

        if (b0 != .u64 or b1 != .u64) {
            // Shelley-onward expects body[0]=block_no:u64, body[1]=slot:u64.
            // If body[0] is .array, this looks like Byron boundary/main header
            // shape (body starts with epoch struct, not a block_no integer).
            const era_guess: []const u8 = if (b0 == .array)
                "byron_boundary_or_main"
            else if (b0 == .tag)
                "byron_tagged_or_pre_shelley"
            else
                "unknown_pre_shelley";
            std.debug.print(
                "DELIVERED_HEADER_PARSE_REJECT: stage=body_fields_not_u64u64\n" ++
                    "DELIVERED_HEADER_PARSE_ERA: guess={s} reason=body0_or_body1_not_u64\n" ++
                    "DELIVERED_HEADER_PARSE_REASON: parser expected body[0]:u64 body[1]:u64 got body0_kind={s} body1_kind={s}\n",
                .{ era_guess, b0_kind, b1_kind },
            );
            return;
        }

        // body[0] = block_no, body[1] = slot — but if parser still rejected at top, this branch is unreachable.
        // Reaching here means dumpHeaderShape was called speculatively; just emit a neutral observation.
        std.debug.print(
            "DELIVERED_HEADER_PARSE_REJECT: stage=none (shape parses as expected)\n" ++
                "DELIVERED_HEADER_PARSE_ERA: guess=shelley_or_later reason=body_shape_matches_modern\n" ++
                "DELIVERED_HEADER_PARSE_REASON: shape OK at parser level (block_no={d} slot={d}) — refusal may be downstream\n",
            .{ b0_val, b1_val },
        );
    } else |decode_err| {
        std.debug.print(
            "DELIVERED_HEADER_PARSE_REJECT: stage=cbor_decode_failed\n" ++
                "DELIVERED_HEADER_PARSE_ERA: guess=unknown reason=cbor_decode_error\n" ++
                "DELIVERED_HEADER_PARSE_REASON: cbor.decode err={s}\n",
            .{@errorName(decode_err)},
        );
    }
}

pub fn parseHeaderSlotAndBlockNo(header_cbor: []const u8) ?struct { slot: u64, block_no: u64 } {
    if (header_cbor.len == 0) return null;
    const pa = std.heap.page_allocator;
    var fbs = compat.fixedBufferStream(header_cbor);
    const top = cbor.decode(pa, fbs.reader()) catch return null;
    defer cbor.free(top, pa);

    if (top != .array or top.array.len < 1) return null;
    const body = top.array[0];
    if (body != .array or body.array.len < 2) return null;
    if (body.array[0] != .u64 or body.array[1] != .u64) return null;

    return .{ .block_no = body.array[0].u64, .slot = body.array[1].u64 };
}

fn tipWriteAtomic(dir: []const u8, name: []const u8, data: []const u8) bool {
    const pa = std.heap.page_allocator;
    const tmp_path = std.fmt.allocPrint(pa, "{s}/{s}.tmp", .{ dir, name }) catch return false;
    defer pa.free(tmp_path);
    const final_path = std.fmt.allocPrint(pa, "{s}/{s}", .{ dir, name }) catch return false;
    defer pa.free(final_path);

    var file = compat.fs.cwd().createFile(tmp_path, .{}) catch return false;
    file.writeAll(data) catch {
        file.close();
        return false;
    };
    file.close();
    compat.fs.cwd().rename(tmp_path, final_path) catch return false;
    return true;
}

/// Read a file's contents using page_allocator. Caller must free the returned slice.
fn tipReadFile(path: []const u8) ?[]u8 {
    const pa = std.heap.page_allocator;
    var f = compat.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    return f.readToEndAlloc(pa, 64 * 1024) catch null;
}

/// Parse prevHash from raw header CBOR.
/// Header format: [header_body, kes_signature]
/// header_body[2] = prev_hash (bytes32, possibly tag-wrapped)
fn parseHeaderPrevHash(header_cbor: []const u8) ?[32]u8 {
    if (header_cbor.len == 0) return null;
    const pa = std.heap.page_allocator;
    var fbs = compat.fixedBufferStream(header_cbor);
    const top = cbor.decode(pa, fbs.reader()) catch return null;
    defer cbor.free(top, pa);

    if (top != .array or top.array.len < 1) return null;
    const body = top.array[0];
    if (body != .array or body.array.len < 3) return null;

    // prevHash at index 2: raw bytes or tag-wrapped
    const term = body.array[2];
    if (term == .bytes and term.bytes.len == 32) {
        var out: [32]u8 = undefined;
        @memcpy(&out, term.bytes[0..32]);
        return out;
    }
    if (term == .tag) {
        const inner = term.tag.value.*;
        if (inner == .bytes and inner.bytes.len == 32) {
            var out: [32]u8 = undefined;
            @memcpy(&out, inner.bytes[0..32]);
            return out;
        }
    }
    return null;
}

/// Parse 64 hex chars into a 32-byte hash.
fn tipParseHex64(hex: []const u8, out: *[32]u8) bool {
    if (hex.len != 64) return false;
    var byte_idx: usize = 0;
    var char_idx: usize = 0;
    while (char_idx + 1 < 64) : ({
        char_idx += 2;
        byte_idx += 1;
    }) {
        const hi = tipHexVal(hex[char_idx]) orelse return false;
        const lo = tipHexVal(hex[char_idx + 1]) orelse return false;
        out[byte_idx] = (@as(u8, hi) << 4) | @as(u8, lo);
    }
    return true;
}

fn tipHexVal(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    return null;
}

/// Get the hash of the newest (highest-seq) fragment entry.
fn fragmentTailHash(frag_dir: []const u8) ?[32]u8 {
    const pa = std.heap.page_allocator;
    var max_seq: u32 = 0;
    var found = false;
    {
        var dir = compat.fs.cwd().openDir(frag_dir, .{ .iterate = true }) catch return null;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (entry.name.len >= 20 and std.mem.endsWith(u8, entry.name, ".header.cbor")) {
                const seq = std.fmt.parseInt(u32, entry.name[0..8], 10) catch continue;
                if (!found or seq > max_seq) {
                    max_seq = seq;
                    found = true;
                }
            }
        }
    }
    if (!found) return null;

    var seq_buf: [8]u8 = undefined;
    const seq_str = std.fmt.bufPrint(&seq_buf, "{d:0>8}", .{max_seq}) catch return null;
    var path_buf: [512]u8 = undefined;
    const hash_path = std.fmt.bufPrint(&path_buf, "{s}/{s}.hash.hex", .{ frag_dir, seq_str }) catch return null;
    const hex_data = tipReadFile(hash_path) orelse return null;
    defer pa.free(hex_data);
    const trimmed = std.mem.trim(u8, hex_data, " \t\r\n");
    var h: [32]u8 = undefined;
    if (trimmed.len == 64 and tipParseHex64(trimmed, &h)) return h;
    return null;
}

/// Scan fragment entries for one whose hash matches target_hash.
/// If found, delete all entries with sequence number > the match (rollback truncation).
/// If the match is already the tail (highest seq), no files are deleted.
/// Returns true if the anchor was found, false otherwise.
fn fragmentRollbackToHash(frag_dir: []const u8, target_hash: [32]u8) bool {
    const pa = std.heap.page_allocator;

    // Phase 1: collect all sequence numbers and find the matching hash
    var seqs: [2560]u32 = undefined;
    var count: u32 = 0;
    var match_seq: ?u32 = null;
    var max_seq: u32 = 0;
    var found_any = false;
    {
        var dir = compat.fs.cwd().openDir(frag_dir, .{ .iterate = true }) catch return false;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (entry.name.len >= 17 and std.mem.endsWith(u8, entry.name, ".hash.hex")) {
                const seq = std.fmt.parseInt(u32, entry.name[0..8], 10) catch continue;
                if (count < seqs.len) {
                    seqs[count] = seq;
                    count += 1;
                }
                if (!found_any or seq > max_seq) {
                    max_seq = seq;
                    found_any = true;
                }
                // Read and compare hash
                var path_buf: [512]u8 = undefined;
                const hash_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ frag_dir, entry.name }) catch continue;
                const hex_data = tipReadFile(hash_path) orelse continue;
                defer pa.free(hex_data);
                const trimmed = std.mem.trim(u8, hex_data, " \t\r\n");
                var h: [32]u8 = undefined;
                if (trimmed.len == 64 and tipParseHex64(trimmed, &h)) {
                    if (std.mem.eql(u8, &h, &target_hash)) {
                        match_seq = seq;
                    }
                }
            }
        }
    }

    const anchor = match_seq orelse return false;

    // Read tail hash for diagnostic
    var tail_hash_prefix: [16]u8 = undefined;
    if (found_any) {
        var tseq_buf: [8]u8 = undefined;
        const tseq_str = std.fmt.bufPrint(&tseq_buf, "{d:0>8}", .{max_seq}) catch "00000000";
        var tpath_buf: [512]u8 = undefined;
        const tail_path = std.fmt.bufPrint(&tpath_buf, "{s}/{s}.hash.hex", .{ frag_dir, tseq_str }) catch "";
        if (tail_path.len > 0) {
            if (tipReadFile(tail_path)) |tail_hex| {
                defer pa.free(tail_hex);
                const tail_trimmed = std.mem.trim(u8, tail_hex, " \t\r\n");
                if (tail_trimmed.len >= 16) {
                    @memcpy(&tail_hash_prefix, tail_trimmed[0..16]);
                } else {
                    @memcpy(&tail_hash_prefix, "0000000000000000");
                }
            } else {
                @memcpy(&tail_hash_prefix, "0000000000000000");
            }
        } else {
            @memcpy(&tail_hash_prefix, "0000000000000000");
        }
    } else {
        @memcpy(&tail_hash_prefix, "0000000000000000");
    }

    // Diagnostic: matched hash and tail hash
    std.debug.print("FRAGMENT: rollback_anchor_check anchor_hash={x} tail_hash={s} anchor_seq={d:0>8} tail_seq={d:0>8}\n", .{
        target_hash[0..8],
        tail_hash_prefix,
        anchor,
        max_seq,
    });

    // If anchor IS the tail, nothing to delete
    if (anchor == max_seq) {
        std.debug.print("FRAGMENT: rollback_truncate anchor_seq={d:0>8} deleted=0 retained={d}\n", .{
            anchor, count,
        });
        return true;
    }

    // Phase 2: delete all entries with seq > anchor
    var deleted: u32 = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (seqs[i] > anchor) {
            var seq_buf: [8]u8 = undefined;
            const seq_str = std.fmt.bufPrint(&seq_buf, "{d:0>8}", .{seqs[i]}) catch continue;
            const suffixes = [_][]const u8{ ".header.cbor", ".hash.hex", ".prev_hash.hex", ".meta.json", ".body.cbor" };
            for (&suffixes) |suffix| {
                var fname_buf: [64]u8 = undefined;
                const fname = std.fmt.bufPrint(&fname_buf, "{s}{s}", .{ seq_str, suffix }) catch continue;
                var path_buf2: [512]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buf2, "{s}/{s}", .{ frag_dir, fname }) catch continue;
                compat.fs.cwd().deleteFile(path) catch {};
            }
            deleted += 1;
        }
    }

    std.debug.print("FRAGMENT: rollback_truncate anchor_seq={d:0>8} deleted={d} retained={d}\n", .{
        anchor, deleted, count - deleted,
    });
    return true;
}

/// Wipe all fragment entries from the directory.
/// Loops in batches to handle directories with more files than buffer capacity.
fn fragmentWipe(frag_dir: []const u8) void {
    var total_wiped: u32 = 0;
    var pass: u32 = 0;
    while (pass < 32) : (pass += 1) { // safety limit: 32 passes * 512 files = 16384 max
        var dir = compat.fs.cwd().openDir(frag_dir, .{ .iterate = true }) catch return;

        // Collect batch of filenames (can't delete while iterating)
        var names: [8192]u8 = undefined;
        var name_offsets: [512]u16 = undefined;
        var name_lens: [512]u8 = undefined;
        var n_count: u16 = 0;
        var n_pos: u16 = 0;
        {
            var it = dir.iterate();
            while (it.next() catch null) |entry| {
                if (entry.kind != .file) continue;
                if (entry.name.len >= 15 and
                    (std.mem.endsWith(u8, entry.name, ".header.cbor") or
                    std.mem.endsWith(u8, entry.name, ".hash.hex") or
                    std.mem.endsWith(u8, entry.name, ".prev_hash.hex") or
                    std.mem.endsWith(u8, entry.name, ".meta.json") or
                    std.mem.endsWith(u8, entry.name, ".body.cbor")))
                {
                    if (n_count < name_offsets.len and n_pos + entry.name.len <= names.len) {
                        @memcpy(names[n_pos .. n_pos + entry.name.len], entry.name);
                        name_offsets[n_count] = n_pos;
                        name_lens[n_count] = @intCast(entry.name.len);
                        n_pos += @intCast(entry.name.len);
                        n_count += 1;
                    }
                }
            }
        }
        dir.close();

        if (n_count == 0) break; // directory clean

        var d: u16 = 0;
        while (d < n_count) : (d += 1) {
            const off = name_offsets[d];
            const len = name_lens[d];
            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{
                frag_dir, names[off .. off + len],
            }) catch continue;
            compat.fs.cwd().deleteFile(path) catch {};
        }
        total_wiped += n_count;
    }
    std.debug.print("FRAGMENT: wiped {d} files\n", .{total_wiped});
}

/// Append the current tip as a new fragment entry.
fn fragmentAppendEntry(frag_dir: []const u8, dir_path: []const u8, cur_cbor: []const u8, cur_hash: [32]u8, cur_slot: u64, cur_block_no: u64, body_cbor: ?[]const u8, prev_hash: ?[32]u8) void {
    _ = dir_path;
    const next_seq = fragmentNextSeq(frag_dir);
    var seq_buf: [8]u8 = undefined;
    const seq_str = std.fmt.bufPrint(&seq_buf, "{d:0>8}", .{next_seq}) catch return;

    const hex_chars = "0123456789abcdef";

    // Write header CBOR
    var fname_buf: [64]u8 = undefined;
    const hdr_name = std.fmt.bufPrint(&fname_buf, "{s}.header.cbor", .{seq_str}) catch return;
    _ = tipWriteAtomic(frag_dir, hdr_name, cur_cbor);

    // Write hash hex
    var hash_hex: [64]u8 = undefined;
    for (cur_hash, 0..) |b, i| {
        hash_hex[i * 2] = hex_chars[b >> 4];
        hash_hex[i * 2 + 1] = hex_chars[b & 0xf];
    }
    var hname_buf: [64]u8 = undefined;
    const hash_name = std.fmt.bufPrint(&hname_buf, "{s}.hash.hex", .{seq_str}) catch return;
    _ = tipWriteAtomic(frag_dir, hash_name, &hash_hex);

    // Write prev_hash hex (for O(1) ancestry verification without CBOR decode)
    if (prev_hash) |ph| {
        var ph_hex: [64]u8 = undefined;
        for (ph, 0..) |b, i| {
            ph_hex[i * 2] = hex_chars[b >> 4];
            ph_hex[i * 2 + 1] = hex_chars[b & 0xf];
        }
        var phname_buf: [64]u8 = undefined;
        const ph_name = std.fmt.bufPrint(&phname_buf, "{s}.prev_hash.hex", .{seq_str}) catch return;
        _ = tipWriteAtomic(frag_dir, ph_name, &ph_hex);
    }

    // Write meta
    var meta_buf: [256]u8 = undefined;
    const now = compat.timestamp();
    const meta_json = std.fmt.bufPrint(&meta_buf,
        \\{{"slot":{d},"block_no":{d},"unix":{d}}}
    , .{ cur_slot, cur_block_no, now }) catch return;
    var mname_buf: [64]u8 = undefined;
    const meta_name = std.fmt.bufPrint(&mname_buf, "{s}.meta.json", .{seq_str}) catch return;
    _ = tipWriteAtomic(frag_dir, meta_name, meta_json);

    // Write block body CBOR (if available)
    if (body_cbor) |body| {
        var bname_buf: [64]u8 = undefined;
        const body_name = std.fmt.bufPrint(&bname_buf, "{s}.body.cbor", .{seq_str}) catch return;
        _ = tipWriteAtomic(frag_dir, body_name, body);
    }
}

/// Count fragment entries.
fn fragmentCount(frag_dir: []const u8) u32 {
    var count: u32 = 0;
    var dir = compat.fs.cwd().openDir(frag_dir, .{ .iterate = true }) catch return 0;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name.len >= 20 and std.mem.endsWith(u8, entry.name, ".header.cbor")) {
            count += 1;
        }
    }
    return count;
}

/// Get the slot of the oldest fragment entry by reading the lowest-numbered .meta.json.
fn fragmentOldestSlot(frag_dir: []const u8) u64 {
    var min_seq: u32 = std.math.maxInt(u32);
    var found_any = false;
    {
        var dir = compat.fs.cwd().openDir(frag_dir, .{ .iterate = true }) catch return 0;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (entry.name.len >= 20 and std.mem.endsWith(u8, entry.name, ".header.cbor")) {
                const seq = std.fmt.parseInt(u32, entry.name[0..8], 10) catch continue;
                if (!found_any or seq < min_seq) {
                    min_seq = seq;
                    found_any = true;
                }
            }
        }
    }
    if (!found_any) return 0;
    // Read the meta.json for this sequence to extract slot
    var seq_buf: [8]u8 = undefined;
    const seq_str = std.fmt.bufPrint(&seq_buf, "{d:0>8}", .{min_seq}) catch return 0;
    var path_buf: [512]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&path_buf, "{s}/{s}.meta.json", .{ frag_dir, seq_str }) catch return 0;
    const meta_data = tipReadFile(meta_path) orelse return 0;
    defer std.heap.page_allocator.free(meta_data);
    // Simple extraction: find "slot": then number
    const key = std.mem.indexOf(u8, meta_data, "\"slot\"") orelse return 0;
    const colon = std.mem.indexOfPos(u8, meta_data, key + 5, ":") orelse return 0;
    var start = colon + 1;
    while (start < meta_data.len and meta_data[start] == ' ') start += 1;
    var end = start;
    while (end < meta_data.len and meta_data[end] >= '0' and meta_data[end] <= '9') end += 1;
    if (end == start) return 0;
    return std.fmt.parseInt(u64, meta_data[start..end], 10) catch 0;
}

/// Find the next sequence number for a fragment directory by scanning existing .header.cbor files.
fn fragmentNextSeq(frag_dir: []const u8) u32 {
    var max_seq: u32 = 0;
    var found_any = false;
    var dir = compat.fs.cwd().openDir(frag_dir, .{ .iterate = true }) catch return 0;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name.len >= 20 and std.mem.endsWith(u8, entry.name, ".header.cbor")) {
            const seq_str = entry.name[0..8];
            const seq = std.fmt.parseInt(u32, seq_str, 10) catch continue;
            if (!found_any or seq > max_seq) {
                max_seq = seq;
                found_any = true;
            }
        }
    }
    return if (found_any) max_seq + 1 else 0;
}

/// Prune fragment directory to keep at most `max_entries` entries (by sequence number).
/// Deletes the oldest entries (lowest sequence numbers) first.
fn fragmentPrune(frag_dir: []const u8, max_entries: u32) void {
    // Collect all sequence numbers
    var seqs: [2560]u32 = undefined;
    var count: u32 = 0;
    {
        var dir = compat.fs.cwd().openDir(frag_dir, .{ .iterate = true }) catch return;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (entry.name.len >= 20 and std.mem.endsWith(u8, entry.name, ".header.cbor")) {
                const seq = std.fmt.parseInt(u32, entry.name[0..8], 10) catch continue;
                if (count < seqs.len) {
                    seqs[count] = seq;
                    count += 1;
                }
            }
        }
    }

    if (count <= max_entries) return;

    // Sort ascending
    std.mem.sort(u32, seqs[0..count], {}, std.sort.asc(u32));

    // Delete oldest entries
    const to_delete = count - max_entries;
    var i: u32 = 0;
    while (i < to_delete) : (i += 1) {
        var seq_buf: [8]u8 = undefined;
        const seq_str = std.fmt.bufPrint(&seq_buf, "{d:0>8}", .{seqs[i]}) catch continue;
        const suffixes = [_][]const u8{ ".header.cbor", ".hash.hex", ".prev_hash.hex", ".meta.json", ".body.cbor" };
        for (&suffixes) |suffix| {
            var fname_buf: [64]u8 = undefined;
            const fname = std.fmt.bufPrint(&fname_buf, "{s}{s}", .{ seq_str, suffix }) catch continue;
            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ frag_dir, fname }) catch continue;
            compat.fs.cwd().deleteFile(path) catch {};
        }
        std.debug.print("FRAGMENT: pruned seq={s}\n", .{seq_str});
    }
}

test "fragmentRollbackToHash truncates entries after matched anchor" {
    // Create a temp fragment directory with 10 entries (seq 0..9)
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const hex_chars = "0123456789abcdef";
    var hashes: [10][32]u8 = undefined;

    for (0..10) |i| {
        const seq: u32 = @intCast(i);
        var seq_buf: [8]u8 = undefined;
        const seq_str = std.fmt.bufPrint(&seq_buf, "{d:0>8}", .{seq}) catch unreachable;

        // Generate a unique hash for each entry
        var h: [32]u8 = std.mem.zeroes([32]u8);
        h[0] = @intCast(i);
        h[1] = @intCast(i + 100);
        hashes[i] = h;

        // Write .hash.hex
        var hash_hex: [64]u8 = undefined;
        for (h, 0..) |b, j| {
            hash_hex[j * 2] = hex_chars[b >> 4];
            hash_hex[j * 2 + 1] = hex_chars[b & 0xf];
        }
        var hname_buf: [64]u8 = undefined;
        const hash_name = std.fmt.bufPrint(&hname_buf, "{s}.hash.hex", .{seq_str}) catch unreachable;
        const hf = tmp_dir.dir.createFile(hash_name, .{}) catch unreachable;
        hf.writeAll(&hash_hex) catch unreachable;
        hf.close();

        // Write .header.cbor (dummy)
        var fname_buf: [64]u8 = undefined;
        const hdr_name = std.fmt.bufPrint(&fname_buf, "{s}.header.cbor", .{seq_str}) catch unreachable;
        const cf = tmp_dir.dir.createFile(hdr_name, .{}) catch unreachable;
        cf.writeAll("dummy") catch unreachable;
        cf.close();

        // Write .meta.json (dummy)
        var mname_buf: [64]u8 = undefined;
        const meta_name = std.fmt.bufPrint(&mname_buf, "{s}.meta.json", .{seq_str}) catch unreachable;
        const mf = tmp_dir.dir.createFile(meta_name, .{}) catch unreachable;
        mf.writeAll("{}") catch unreachable;
        mf.close();
    }

    // Get the real path for fragmentRollbackToHash (it uses cwd-relative paths)
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const frag_dir = tmp_dir.dir.realpath(".", &real_path_buf) catch unreachable;

    // Test 1: rollback to entry 7 — should delete entries 8 and 9
    const result = fragmentRollbackToHash(frag_dir, hashes[7]);
    try std.testing.expect(result);
    try std.testing.expectEqual(@as(u32, 8), fragmentCount(frag_dir));

    // Verify entries 0-7 still exist
    for (0..8) |i| {
        var seq_buf2: [8]u8 = undefined;
        const seq_s = std.fmt.bufPrint(&seq_buf2, "{d:0>8}", .{@as(u32, @intCast(i))}) catch unreachable;
        var vname_buf: [64]u8 = undefined;
        const vname = std.fmt.bufPrint(&vname_buf, "{s}.header.cbor", .{seq_s}) catch unreachable;
        tmp_dir.dir.access(vname, .{}) catch {
            return error.ExpectedEntryMissing;
        };
    }

    // Verify entries 8 and 9 are gone
    for (8..10) |i| {
        var seq_buf3: [8]u8 = undefined;
        const seq_s2 = std.fmt.bufPrint(&seq_buf3, "{d:0>8}", .{@as(u32, @intCast(i))}) catch unreachable;
        var gname_buf: [64]u8 = undefined;
        const gname = std.fmt.bufPrint(&gname_buf, "{s}.header.cbor", .{seq_s2}) catch unreachable;
        tmp_dir.dir.access(gname, .{}) catch continue; // expected: file not found
        return error.ExpectedEntryStillExists;
    }

    // Test 2: rollback to entry 7 again (now the tail) — should return true, delete=0
    const result2 = fragmentRollbackToHash(frag_dir, hashes[7]);
    try std.testing.expect(result2);
    try std.testing.expectEqual(@as(u32, 8), fragmentCount(frag_dir));

    // Test 3: rollback to a hash that doesn't exist — should return false
    var fake_hash: [32]u8 = std.mem.zeroes([32]u8);
    fake_hash[0] = 0xFF;
    fake_hash[1] = 0xFF;
    const result3 = fragmentRollbackToHash(frag_dir, fake_hash);
    try std.testing.expect(!result3);
    try std.testing.expectEqual(@as(u32, 8), fragmentCount(frag_dir)); // unchanged
}

// ── VRF output extraction for nonce evolution ──────────────────────

/// Extract the 64-byte VRF output from a raw block header CBOR.
/// Header = [header_body, kes_sig]; header_body[5] = [vrf_output(64), vrf_proof(80)]
fn extractVrfOutput(header_cbor: []const u8) ?[64]u8 {
    if (header_cbor.len == 0) return null;
    const pa = std.heap.page_allocator;
    var fbs = compat.fixedBufferStream(header_cbor);
    const top = cbor.decode(pa, fbs.reader()) catch return null;
    defer cbor.free(top, pa);

    if (top != .array or top.array.len < 2) return null;
    const body = if (top.array[0] == .array) top.array[0] else return null;
    if (body.array.len < 6) return null;

    // body[5] = [vrf_output, vrf_proof]
    const vrf_result = if (body.array[5] == .array and body.array[5].array.len >= 1)
        body.array[5].array
    else
        return null;

    if (vrf_result[0] != .bytes or vrf_result[0].bytes.len != 64) return null;

    var output: [64]u8 = undefined;
    @memcpy(&output, vrf_result[0].bytes[0..64]);
    return output;
}

