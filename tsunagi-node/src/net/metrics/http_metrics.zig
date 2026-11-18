const std = @import("std");
const compat = @import("compat");
const mempool_mod = @import("../ledger/mempool.zig");
const block_hash = @import("../ledger/block_hash.zig");
const mempool_decoder = @import("../mempool/mempool_decoder.zig");
const mempool_summary_history = @import("../mempool/mempool_summary_history.zig");
const journal = @import("../ledger/journal.zig");
const confirmation_tracker = @import("../mempool/confirmation_tracker.zig");
const propagation_tracker = @import("../mempool/propagation_tracker.zig");
const backfill_autopilot = @import("../../store/lmdb_backfill_autopilot.zig");
const capture = @import("../../replay/capture.zig");
const chain_index = @import("../ledger/chain_index.zig");
const node_state = @import("../../node_state.zig");
const leader_schedule = @import("../../producer/leader_schedule.zig");
const adaptive_eng = @import("../../producer/adaptive.zig");
const peer_score = @import("../../producer/peer_score.zig");
const decision_eng = @import("../../producer/decision.zig");
const signals_mod = @import("../../producer/signals.zig");
const protocol_manager = @import("../../producer/protocol_manager.zig");
const prearm = @import("../../producer/prearm.zig");
const multi_probe = @import("../../producer/multi_probe.zig");
const forge_delay = @import("../../producer/forge_delay.zig");
const skip_advisory = @import("../../producer/skip_advisory.zig");
const propagation_opt = @import("../../producer/propagation_opt.zig");
const alerts = @import("../../producer/alerts.zig");
const feedback = @import("../../producer/feedback.zig");
const announce = @import("../../producer/announce.zig");
const autotune = @import("../../producer/autotune.zig");
const stake_snapshot = @import("../../net/ledger/stake_snapshot.zig");
const sign_log = @import("../../producer/sign_log.zig");
const forge_stats = @import("../../producer/forge_stats.zig");
const kes_alerts = @import("../../producer/kes_alerts.zig");
const connection_registry = @import("../connection_registry.zig");
const resources = @import("../../producer/resources.zig");
const pool_stats = @import("../../producer/pool_stats.zig");
const presence = @import("../../producer/presence.zig");
const slot_filter_mod = @import("../../producer/slot_filter.zig");
const execution_score = @import("../../producer/execution.zig");
const header_store_mod = @import("../../store/header_store.zig");
const status_fallback = @import("status_fallback.zig");

pub const PEER_SLOTS: usize = 5;

// Mempool observatory: set by chainsync_mux_smoke after FollowerCtx is created
pub var g_mempool_summary: ?*mempool_summary_history.MempoolSummaryStore = null;
pub var g_mempool_journal_path: []const u8 = "";
pub var g_confirmation_tracker: ?*confirmation_tracker.ConfirmationTracker = null;
pub var g_propagation_tracker: ?*propagation_tracker.PropagationTracker = null;
pub var g_chain_index: ?*const chain_index.ChainIndex = null;
pub var g_header_store: ?*header_store_mod.HeaderStore = null;
/// Phase B'''': process-global Case-B override counter. producer.zig
/// increments this on FORGE_CANONICAL_OVERRIDE fire without needing an
/// http_metrics import or a ProducerContext field. The Prometheus
/// exposition path reads from this counter directly (gauge mirrored
/// into Metrics is also kept for /state usage).
pub var g_forge_canonical_override_total: std.atomic.Value(u64) = .{ .raw = 0 };

fn initAtomicArray(comptime N: usize, val: u64) [N]std.atomic.Value(u64) {
    var arr: [N]std.atomic.Value(u64) = undefined;
    for (&arr) |*slot| slot.* = std.atomic.Value(u64).init(val);
    return arr;
}

pub const Metrics = struct {
    // Updated from the node thread, read by the HTTP thread.
    // We keep it simple: atomics only.

    // Meta: metrics server health
    metrics_up: std.atomic.Value(u64) = .{ .raw = 0 },
    metrics_bind_fail_total: std.atomic.Value(u64) = .{ .raw = 0 },
    metrics_last_bind_fail_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    metrics_bind_retry_last: std.atomic.Value(u64) = .{ .raw = 0 },
    metrics_started: std.atomic.Value(u64) = .{ .raw = 0 },
    metrics_start_attempt_total: std.atomic.Value(u64) = .{ .raw = 0 },
    metrics_start_success_total: std.atomic.Value(u64) = .{ .raw = 0 },
    metrics_start_address_in_use_total: std.atomic.Value(u64) = .{ .raw = 0 },
    metrics_next_retry_unix: std.atomic.Value(u64) = .{ .raw = 0 },

    slot: std.atomic.Value(u64) = .{ .raw = 0 },
    block_no: std.atomic.Value(u64) = .{ .raw = 0 },
    utxo: std.atomic.Value(u64) = .{ .raw = 0 },
    roll_fwd: std.atomic.Value(u64) = .{ .raw = 0 },
    roll_back: std.atomic.Value(u64) = .{ .raw = 0 },
    peer_closed: std.atomic.Value(u64) = .{ .raw = 0 },
    // Primary follower observability (fix/primary-follower-observability)
    // OBSERVABILITY-ONLY: not consumed by any decision path; emitted only via /metrics.
    primary_rollforwards_processed_total: std.atomic.Value(u64) = .{ .raw = 0 },
    primary_recv_timeouts_total: std.atomic.Value(u64) = .{ .raw = 0 },
    primary_intersect_found_total: std.atomic.Value(u64) = .{ .raw = 0 },
    primary_intersect_not_found_total: std.atomic.Value(u64) = .{ .raw = 0 },
    primary_tip_promotions_total: std.atomic.Value(u64) = .{ .raw = 0 },
    primary_tip_parse_null_total: std.atomic.Value(u64) = .{ .raw = 0 },
    // INTERSECT_NOT_FOUND recovery — bounded continuity negotiation (2026-05-20).
    // Increments on each in-connection origin fallback after multi-point rejection.
    // Operationally a MAJOR continuity event; should be rare under stable canonical state.
    primary_intersect_recovery_origin_total: std.atomic.Value(u64) = .{ .raw = 0 },
    lmdb_truth_blocks: std.atomic.Value(u64) = .{ .raw = 0 },
    lmdb_fallback_blocks: std.atomic.Value(u64) = .{ .raw = 0 },
    cbor_toolarge: std.atomic.Value(u64) = .{ .raw = 0 },
    cbor_eof: std.atomic.Value(u64) = .{ .raw = 0 },
    cbor_other: std.atomic.Value(u64) = .{ .raw = 0 },

    // Bayesian peer scoring (values stored as x*1000 for fixed-point)
    peer_alpha: [PEER_SLOTS]std.atomic.Value(u64) = initAtomicArray(PEER_SLOTS, 1000),
    peer_beta: [PEER_SLOTS]std.atomic.Value(u64) = initAtomicArray(PEER_SLOTS, 1000),
    peer_sample: [PEER_SLOTS]std.atomic.Value(u64) = initAtomicArray(PEER_SLOTS, 0),
    peer_selected: [PEER_SLOTS]std.atomic.Value(u64) = initAtomicArray(PEER_SLOTS, 0),

    // Performance telemetry (latest values in milliseconds)
    perf_blockfetch_decode_ms: std.atomic.Value(u64) = .{ .raw = 0 },
    perf_tx_extract_ms: std.atomic.Value(u64) = .{ .raw = 0 },
    perf_lmdb_write_ms: std.atomic.Value(u64) = .{ .raw = 0 },
    perf_block_total_ms: std.atomic.Value(u64) = .{ .raw = 0 },
    perf_reconnect_ms: std.atomic.Value(u64) = .{ .raw = 0 },

    // Bayes v2: performance nudge counters (per-peer)
    peer_perf_reward: [PEER_SLOTS]std.atomic.Value(u64) = initAtomicArray(PEER_SLOTS, 0),
    peer_perf_penalty: [PEER_SLOTS]std.atomic.Value(u64) = initAtomicArray(PEER_SLOTS, 0),

    // Performance telemetry (latest values in microseconds — avoids 0ms rounding)
    perf_blockfetch_decode_us: std.atomic.Value(u64) = .{ .raw = 0 },
    perf_tx_extract_us: std.atomic.Value(u64) = .{ .raw = 0 },
    perf_lmdb_write_us: std.atomic.Value(u64) = .{ .raw = 0 },
    perf_block_total_us: std.atomic.Value(u64) = .{ .raw = 0 },
    perf_reconnect_us: std.atomic.Value(u64) = .{ .raw = 0 },

    // Header chain authority
    header_height: std.atomic.Value(u64) = .{ .raw = 0 },
    header_store_writes: std.atomic.Value(u64) = .{ .raw = 0 },
    header_chain_errors: std.atomic.Value(u64) = .{ .raw = 0 },
    header_prevhash_missing: std.atomic.Value(u64) = .{ .raw = 0 },
    // Phase B'''': parse-or-refuse counter. Increments when a delivered
    // header CBOR cannot be parsed for slot/block_no and is therefore
    // refused at the LMDB-of-record write site (no peer-tip fallback).
    tsunagi_header_parse_refused_total: std.atomic.Value(u64) = .{ .raw = 0 },
    // Phase B'''': peer-tip gauges (peer-lag visibility now that /status
    // reports delivered-domain values).
    peer_tip_slot: std.atomic.Value(u64) = .{ .raw = 0 },
    peer_tip_block_no: std.atomic.Value(u64) = .{ .raw = 0 },
    // Phase B'''': Case-B canonical override fire count (monitoring per
    // Tier-3 Round 3 Specialist A thresholds).
    forge_canonical_override_total: std.atomic.Value(u64) = .{ .raw = 0 },
    header_mismatch_reconnects: std.atomic.Value(u64) = .{ .raw = 0 },
    header_head_stable: std.atomic.Value(u64) = .{ .raw = 0 },

    // Rollback flap guard
    rollback_window_count_last: std.atomic.Value(u64) = .{ .raw = 0 },
    rollback_window_avg_depth_x1000: std.atomic.Value(u64) = .{ .raw = 0 },
    rollback_window_max_depth_last: std.atomic.Value(u64) = .{ .raw = 0 },
    rollback_flap_violation_total: std.atomic.Value(u64) = .{ .raw = 0 },
    // Rollback stabilization (v1.5.9)
    rollback_stabilize_suppressed_total: std.atomic.Value(u64) = .{ .raw = 0 },
    rollback_stabilize_active: std.atomic.Value(u64) = .{ .raw = 0 },
    // LMDB truth failures (v1.5.9)
    lmdb_truth_apply_fail_total: std.atomic.Value(u64) = .{ .raw = 0 },
    // v5.2: preflight coverage profile
    preflight_full_coverage_blocks: std.atomic.Value(u64) = .{ .raw = 0 },
    preflight_partial_coverage_blocks: std.atomic.Value(u64) = .{ .raw = 0 },
    preflight_zero_coverage_blocks: std.atomic.Value(u64) = .{ .raw = 0 },

    // Chain density guard
    chain_density_violation_total: std.atomic.Value(u64) = .{ .raw = 0 },
    chain_density_last_x1e6: std.atomic.Value(u64) = .{ .raw = 0 },
    chain_density_window_blocks_last: std.atomic.Value(u64) = .{ .raw = 0 },
    chain_density_window_slots_last: std.atomic.Value(u64) = .{ .raw = 0 },
    chain_density_smoothed_last_x1e6: std.atomic.Value(u64) = .{ .raw = 0 },
    chain_density_violation_streak_last: std.atomic.Value(u64) = .{ .raw = 0 },
    chain_density_baseline_x1e6: std.atomic.Value(u64) = .{ .raw = 0 },
    chain_density_recommended_min_x1e6: std.atomic.Value(u64) = .{ .raw = 0 },
    chain_density_recommended_max_x1e6: std.atomic.Value(u64) = .{ .raw = 0 },
    chain_density_baseline_updates_total: std.atomic.Value(u64) = .{ .raw = 0 },
    chain_density_baseline_last_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    chain_density_max_last_x1e6: std.atomic.Value(u64) = .{ .raw = 0 },
    chain_density_max_violation_total: std.atomic.Value(u64) = .{ .raw = 0 },
    chain_density_max_strict_disconnect_total: std.atomic.Value(u64) = .{ .raw = 0 },

    // Consensus clock sanity
    consensus_clock_violation_total: std.atomic.Value(u64) = .{ .raw = 0 },
    consensus_slot_jump_last: std.atomic.Value(u64) = .{ .raw = 0 },
    consensus_wall_drift_last: std.atomic.Value(u64) = .{ .raw = 0 },

    // Consensus skeleton
    consensus_health_score: std.atomic.Value(u64) = .{ .raw = 100 },
    consensus_tip_fresh_seconds: std.atomic.Value(u64) = .{ .raw = 0 },
    consensus_chain_quality_x1e6: std.atomic.Value(u64) = .{ .raw = 0 },
    consensus_header_err_delta_5m: std.atomic.Value(u64) = .{ .raw = 0 },
    consensus_keepalive_to_delta_5m: std.atomic.Value(u64) = .{ .raw = 0 },
    consensus_rollback_delta_5m: std.atomic.Value(u64) = .{ .raw = 0 },

    // Consensus stall attribution
    consensus_stall_reason_code: std.atomic.Value(u64) = .{ .raw = 0 },
    consensus_stall_age_seconds: std.atomic.Value(u64) = .{ .raw = 0 },
    consensus_blockfetch_age_seconds: std.atomic.Value(u64) = .{ .raw = 0 },
    consensus_keepalive_age_seconds: std.atomic.Value(u64) = .{ .raw = 0 },
    consensus_stall_total: std.atomic.Value(u64) = .{ .raw = 0 },
    // Stall attribution timestamps
    consensus_last_blockfetch_batch_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    consensus_last_keepalive_pong_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    consensus_last_header_store_write_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    consensus_last_authority_update_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    // 5-minute deltas (extended)
    consensus_window_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    consensus_blockfetch_batches_delta_5m: std.atomic.Value(u64) = .{ .raw = 0 },
    consensus_keepalive_pongs_delta_5m: std.atomic.Value(u64) = .{ .raw = 0 },
    consensus_peer_closed_delta_5m: std.atomic.Value(u64) = .{ .raw = 0 },
    consensus_header_store_writes_delta_5m: std.atomic.Value(u64) = .{ .raw = 0 },
    // BlockFetch batch counter
    blockfetch_batch_done_total: std.atomic.Value(u64) = .{ .raw = 0 },

    // Authority confidence model
    authority_confidence_x1e6: std.atomic.Value(u64) = .{ .raw = 1_000_000 },
    authority_finality_score_x1e6: std.atomic.Value(u64) = .{ .raw = 0 },
    authority_reorg_depth_last: std.atomic.Value(u64) = .{ .raw = 0 },
    authority_reorg_events_5m: std.atomic.Value(u64) = .{ .raw = 0 },
    authority_fork_events_total: std.atomic.Value(u64) = .{ .raw = 0 },
    authority_reorg_depth_max_5m: std.atomic.Value(u64) = .{ .raw = 0 },
    authority_reorg_depth_avg_x1e6: std.atomic.Value(u64) = .{ .raw = 0 },
    authority_fork_delta_5m: std.atomic.Value(u64) = .{ .raw = 0 },
    authority_stable_seconds: std.atomic.Value(u64) = .{ .raw = 0 },
    authority_gate_active: std.atomic.Value(u64) = .{ .raw = 0 },
    authority_reason_code_last: std.atomic.Value(u64) = .{ .raw = 0 },
    authority_reorg_events_delta_5m: std.atomic.Value(u64) = .{ .raw = 0 },
    authority_window_unix: std.atomic.Value(u64) = .{ .raw = 0 },

    // Header validation
    header_validate_total: std.atomic.Value(u64) = .{ .raw = 0 },
    header_validate_fail_total: std.atomic.Value(u64) = .{ .raw = 0 },
    header_hash_mismatch_total: std.atomic.Value(u64) = .{ .raw = 0 },
    header_prevhash_mismatch_total: std.atomic.Value(u64) = .{ .raw = 0 },
    header_validate_fail_ratio_x1e6: std.atomic.Value(u64) = .{ .raw = 0 },

    // Header authority invariants
    header_height_violation: std.atomic.Value(u64) = .{ .raw = 0 },
    header_slot_violation: std.atomic.Value(u64) = .{ .raw = 0 },
    header_block_violation: std.atomic.Value(u64) = .{ .raw = 0 },
    header_rollback_total: std.atomic.Value(u64) = .{ .raw = 0 },
    header_rollback_depth_last: std.atomic.Value(u64) = .{ .raw = 0 },

    // Ledger invariants
    ledger_violation_total: std.atomic.Value(u64) = .{ .raw = 0 },
    ledger_dup_input_total: std.atomic.Value(u64) = .{ .raw = 0 },
    ledger_overflow_total: std.atomic.Value(u64) = .{ .raw = 0 },
    ledger_missing_input_total: std.atomic.Value(u64) = .{ .raw = 0 },
    ledger_strict_disconnect_total: std.atomic.Value(u64) = .{ .raw = 0 },

    // Ledger economic invariants
    ledger_value_violation_total: std.atomic.Value(u64) = .{ .raw = 0 },
    ledger_sum_in_lovelace_last: std.atomic.Value(u64) = .{ .raw = 0 },
    ledger_sum_out_lovelace_last: std.atomic.Value(u64) = .{ .raw = 0 },
    ledger_fee_est_lovelace_last: std.atomic.Value(u64) = .{ .raw = 0 },
    ledger_value_checks_total: std.atomic.Value(u64) = .{ .raw = 0 },
    ledger_value_checks_skipped_total: std.atomic.Value(u64) = .{ .raw = 0 },
    ledger_input_decode_fail_total: std.atomic.Value(u64) = .{ .raw = 0 },
    // TX decode failure counters are read directly from tx_decode.zig via getDecodeCounters()
    // — no atomic fields needed here (avoids compiler backwards-branch limit).
    ledger_missing_inputs_last: std.atomic.Value(u64) = .{ .raw = 0 },
    ledger_missing_inputs_ema: std.atomic.Value(u64) = .{ .raw = 0 },
    ledger_value_check_ratio_x1e6: std.atomic.Value(u64) = .{ .raw = 0 },
    ledger_auto_strict_enabled: std.atomic.Value(u64) = .{ .raw = 0 },
    ledger_auto_strict_toggle_total: std.atomic.Value(u64) = .{ .raw = 0 },

    // Ledger anomaly bands
    ledger_anomaly_total: std.atomic.Value(u64) = .{ .raw = 0 },
    ledger_anomaly_fee_total: std.atomic.Value(u64) = .{ .raw = 0 },
    ledger_anomaly_dust_total: std.atomic.Value(u64) = .{ .raw = 0 },
    ledger_anomaly_whale_total: std.atomic.Value(u64) = .{ .raw = 0 },
    ledger_anomaly_strict_disconnect_total: std.atomic.Value(u64) = .{ .raw = 0 },

    // Protocol params observation
    protocol_params_reload_total: std.atomic.Value(u64) = .{ .raw = 0 },
    protocol_params_change_total: std.atomic.Value(u64) = .{ .raw = 0 },
    protocol_params_fallback_total: std.atomic.Value(u64) = .{ .raw = 0 },

    ledger_dust_ratio_last_x1e6: std.atomic.Value(u64) = .{ .raw = 0 },
    ledger_dust_count_last: std.atomic.Value(u64) = .{ .raw = 0 },
    ledger_max_out_lovelace_last: std.atomic.Value(u64) = .{ .raw = 0 },

    // TxSubmission mini-protocol
    txsub_sessions_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_msgs_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_decode_errors_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_inventory_sent_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_inventory_items_last: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_txs_requested_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_txs_served_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_bytes_served_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_inventory_broadcast_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_inventory_broadcast_items_last: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_broadcast_attempt_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_broadcast_sent_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_broadcast_blocked_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_session_active: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_session_first_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_last_msg_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_done_total: std.atomic.Value(u64) = .{ .raw = 0 },
    // Passive observability
    txsub_rx_msgs_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_rx_bytes_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_session_rx_msgs_last: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_session_rx_bytes_last: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_session_first_msg_id_last: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_session_age_seconds_last: std.atomic.Value(u64) = .{ .raw = 0 },
    // Msg-ID census
    txsub_msg_id_0_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_msg_id_1_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_msg_id_3_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_msg_id_4_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_msg_id_5_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_msg_id_6_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_msg_id_unknown_total: std.atomic.Value(u64) = .{ .raw = 0 },

    // TxSubmission state machine + shape validation
    txsub_known_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_ignored_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_invalid_shape_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_state_code: std.atomic.Value(u64) = .{ .raw = 0 },

    // BAEY audit log
    baey_events_total: std.atomic.Value(u64) = .{ .raw = 0 },
    baey_last_event_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    baey_safe_mode_enabled: std.atomic.Value(u64) = .{ .raw = 0 },
    baey_weight_stall: std.atomic.Value(u64) = .{ .raw = 0 },
    baey_weight_density: std.atomic.Value(u64) = .{ .raw = 0 },
    baey_weight_header: std.atomic.Value(u64) = .{ .raw = 0 },
    baey_weight_keepalive: std.atomic.Value(u64) = .{ .raw = 0 },
    baey_weight_gap: std.atomic.Value(u64) = .{ .raw = 0 },
    baey_weight_authority: std.atomic.Value(u64) = .{ .raw = 0 },
    baey_weight_finality: std.atomic.Value(u64) = .{ .raw = 0 },
    // BAeY peer selection state (v1.2.2)
    baey_selected_peer_index: std.atomic.Value(u64) = .{ .raw = 0 },
    baey_cooldown_active: std.atomic.Value(u64) = .{ .raw = 0 },
    baey_last_switch_reason_code: std.atomic.Value(u64) = .{ .raw = 0 },
    baey_last_switch_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    baey_switches_total: std.atomic.Value(u64) = .{ .raw = 0 },
    baey_penalty_rate_limited_total: std.atomic.Value(u64) = .{ .raw = 0 },

    // Block producer skeleton
    producer_state: std.atomic.Value(u64) = .{ .raw = 1 }, // 1=Tracking
    producer_last_slot_checked: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_last_leader_slot: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_leader_checks_total: std.atomic.Value(u64) = .{ .raw = 0 },
    // Producer slot clock + drift
    producer_observed_slot: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_estimated_slot: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_drift_last_slots: std.atomic.Value(u64) = .{ .raw = 10_000_000 }, // offset-encoded: 10M = 0 drift
    producer_drift_abs_max: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_drift_abs_last: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_drift_events_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_clock_ok: std.atomic.Value(u64) = .{ .raw = 0 },
    // Genesis loader
    producer_genesis_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_slot_length_s: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_genesis_parse_ok: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_genesis_path_ok: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_genesis_last_error_code: std.atomic.Value(u64) = .{ .raw = 1 },
    // Leader check skeleton
    producer_epoch_last: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_slot_in_epoch_last: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_leader_eligible_last: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_leader_probability_x1e6: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_leader_checks_epoch_total: std.atomic.Value(u64) = .{ .raw = 0 },
    // VRF interface
    producer_vrf_enabled: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_vrf_parse_ok: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_vrf_attempt_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_vrf_checked_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_vrf_reason_code_last: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_vrf_checked_last: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_vrf_probability_x1e6: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_vrf_proof_present: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_vrf_output_present: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_vrf_init_ok: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_vrf_verify_ok_last: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_vrf_output_prefix_last: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_vrf_tick_mode_code: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_vrf_last_checked_slot: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_vrf_skipped_total: std.atomic.Value(u64) = .{ .raw = 0 },
    // VRF proof artifact pipeline (v0.9.8)
    producer_vrf_proof_len_last: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_vrf_output_len_last: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_vrf_proof_prefix_last: std.atomic.Value(u64) = .{ .raw = 0 },
    // KES interface
    producer_kes_enabled: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_kes_parse_ok: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_kes_attempt_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_kes_signed_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_kes_sig_present_last: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_kes_reason_code_last: std.atomic.Value(u64) = .{ .raw = 1 },
    // Header candidate pipeline
    producer_candidate_built_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_candidate_signed_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_candidate_last_slot: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_candidate_body_hash_prefix: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_candidate_sig_present_last: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_candidate_hdr_bytes_len: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_candidate_hdr_hash_w0: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_candidate_hdr_hash_w1: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_candidate_hdr_hash_w2: std.atomic.Value(u64) = .{ .raw = 0 }, // v1.2.0
    producer_candidate_hdr_hash_w3: std.atomic.Value(u64) = .{ .raw = 0 }, // v1.2.0
    // Pure Zig Ed25519 signing
    producer_zig_sig_attempt_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_zig_sig_ok_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_zig_sig_present_last: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_zig_sig_prefix_last: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_zig_sig_reason_last: std.atomic.Value(u64) = .{ .raw = 0 },
    // KES candidate signing
    producer_kes_sign_attempt_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_kes_sign_ok_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_kes_sign_present_last: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_kes_sign_prefix_last: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_kes_sign_reason_last: std.atomic.Value(u64) = .{ .raw = 1 },
    producer_kes_sign_label_last: std.atomic.Value(u64) = .{ .raw = 0 },
    // Candidate signing proof (v0.9.7)
    producer_candidate_sig_prefix_last: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_candidate_sign_reason_code_last: std.atomic.Value(u64) = .{ .raw = 1 },
    // Block body builder (v0.9.9)
    producer_body_cbor_len: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_body_hash_w0: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_body_hash_w1: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_body_hash_w2: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_body_hash_w3: std.atomic.Value(u64) = .{ .raw = 0 },
    // Producer proof pack (v1.0.0)
    producer_pack_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_pack_last_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    // Praos leader check (v1.0.1)
    producer_praos_u_x1e12: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_praos_thresh_x1e12: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_praos_leader_last: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_praos_reason_code_last: std.atomic.Value(u64) = .{ .raw = 1 },
    producer_praos_checks_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_praos_enabled: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_praos_last_checked_slot: std.atomic.Value(u64) = .{ .raw = 0 },
    // Praos decision surface (v1.1.3)
    producer_praos_u_lt_t: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_praos_delta_x1e12: std.atomic.Value(u64) = .{ .raw = 0 },
    // Producer state digest (v1.2.0)
    producer_state_digest_w0: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_state_digest_w1: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_state_digest_w2: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_state_digest_w3: std.atomic.Value(u64) = .{ .raw = 0 },
    // KES period gate (v1.0.2)
    producer_kes_current_period: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_kes_period_valid_last: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_kes_period_reason_code_last: std.atomic.Value(u64) = .{ .raw = 1 },
    producer_kes_start_period: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_kes_max_periods: std.atomic.Value(u64) = .{ .raw = 62 },
    // KES lifecycle hardening (v1.1.2)
    producer_kes_period_start_slot: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_kes_period_end_slot: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_kes_rollovers_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_kes_last_rollover_slot: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_kes_out_of_range_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_kes_sign_refused_total: std.atomic.Value(u64) = .{ .raw = 0 },
    // Slot scheduler (v1.1.0)
    producer_schedule_epoch_last: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_schedule_window_start_slot: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_schedule_window_size: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_schedule_leaders_in_window: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_schedule_next_leader_offset: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_schedule_u0_x1e12: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_schedule_t_x1e12: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_schedule_reason_code_last: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_schedule_compute_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_schedule_compute_us_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_schedule_last_slot: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_schedule_last_update_us: std.atomic.Value(u64) = .{ .raw = 0 },
    // Execution timing guards (hardening)
    producer_vrf_compute_us_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_vrf_compute_us_last: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_tick_us_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_tick_us_last: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_tick_us_max: std.atomic.Value(u64) = .{ .raw = 0 },
    // Producer proof bundle (v0.9.6)
    last_producer_proof_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    // Key management
    producer_keys_enabled: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_keys_parse_ok: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_keys_validate_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_keys_err_code_last: std.atomic.Value(u64) = .{ .raw = 1 },
    producer_pool_ok: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_kes_ok: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_vrf_key_ok: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_keys_perms_ok: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_keys_readable_ok: std.atomic.Value(u64) = .{ .raw = 0 },
    // Leader probability model
    producer_stake_fraction_x1e9: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_active_slot_coeff_x1e6: std.atomic.Value(u64) = .{ .raw = 50_000 },
    producer_expected_leaders_per_epoch: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_leader_reason_code_last: std.atomic.Value(u64) = .{ .raw = 1 },
    // Eligibility test harness
    producer_elig_test_enabled: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_elig_test_slot_in_epoch: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_elig_test_window_s: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_elig_test_target_end_slot_in_epoch: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_elig_test_window_active: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_elig_test_override_enabled: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_elig_test_override_target: std.atomic.Value(u64) = .{ .raw = 0 },

    // UTxO state digest (canonical blake2b256, 32 bytes = 4 × u64)
    state_digest_hi: std.atomic.Value(u64) = .{ .raw = 0 }, // w0: bytes[0..8]
    state_digest_lo: std.atomic.Value(u64) = .{ .raw = 0 }, // w1: bytes[8..16]
    state_digest_w2: std.atomic.Value(u64) = .{ .raw = 0 }, // w2: bytes[16..24]
    state_digest_w3: std.atomic.Value(u64) = .{ .raw = 0 }, // w3: bytes[24..32]
    state_digest_unix: std.atomic.Value(u64) = .{ .raw = 0 },

    // Memory / footprint
    rss_kb: std.atomic.Value(u64) = .{ .raw = 0 },
    lmdb_map_size_bytes: std.atomic.Value(u64) = .{ .raw = 0 },
    lmdb_map_gb_effective: std.atomic.Value(u64) = .{ .raw = 0 },
    lmdb_map_gb_raw_parse_ok: std.atomic.Value(u64) = .{ .raw = 0 },

    // KeepAlive mini-protocol
    keepalive_pings_total: std.atomic.Value(u64) = .{ .raw = 0 },
    keepalive_pongs_total: std.atomic.Value(u64) = .{ .raw = 0 },
    keepalive_decode_errors_total: std.atomic.Value(u64) = .{ .raw = 0 },
    keepalive_timeouts_total: std.atomic.Value(u64) = .{ .raw = 0 },
    keepalive_reconnect_total: std.atomic.Value(u64) = .{ .raw = 0 },

    // Mempool
    mempool_items: std.atomic.Value(u64) = .{ .raw = 0 },
    mempool_bytes: std.atomic.Value(u64) = .{ .raw = 0 },
    mempool_accept_total: std.atomic.Value(u64) = .{ .raw = 0 },
    mempool_reject_total: std.atomic.Value(u64) = .{ .raw = 0 },
    mempool_evictions_total: std.atomic.Value(u64) = .{ .raw = 0 },
    mempool_confirmed_evictions_total: std.atomic.Value(u64) = .{ .raw = 0 },

    // Tx submit admission policy
    tx_submit_invalid_total: std.atomic.Value(u64) = .{ .raw = 0 },
    tx_submit_rate_limited_total: std.atomic.Value(u64) = .{ .raw = 0 },

    // Tx submission relay (v1.7.0)
    txsub_relay_requests_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_relay_accepted_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_relay_rejected_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_relay_disabled_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_relay_rate_limited_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_relay_too_large_total: std.atomic.Value(u64) = .{ .raw = 0 },
    txsub_relay_last_result_unix: std.atomic.Value(u64) = .{ .raw = 0 },

    // Stake distribution state (v5.6)
    stake_net_registered: std.atomic.Value(u64) = .{ .raw = 0 },
    stake_net_pools: std.atomic.Value(u64) = .{ .raw = 0 },
    stake_delegations_total: std.atomic.Value(u64) = .{ .raw = 0 },
    stake_total_certs: std.atomic.Value(u64) = .{ .raw = 0 },

    // Producer dry-run (v1.8.0) — use raw init to stay within comptime branch quota
    producer_dryrun_enabled: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_dryrun_slots_checked_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_dryrun_leader_slots_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_dryrun_candidates_built_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_dryrun_candidates_verified_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_dryrun_last_leader_slot: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_dryrun_last_candidate_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_dryrun_last_verify_ok: std.atomic.Value(u64) = .{ .raw = 0 },
    // Real KES signing metrics (v1.8.7)
    producer_dryrun_candidates_signed_total: std.atomic.Value(u64) = .{ .raw = 0 },
    producer_dryrun_last_sign_verify_ok: std.atomic.Value(u64) = .{ .raw = 0 },

    // Header probe (multi-peer tip comparison)
    header_probe_success_total: std.atomic.Value(u64) = .{ .raw = 0 },
    header_probe_fail_total: std.atomic.Value(u64) = .{ .raw = 0 },
    header_probe_switch_total: std.atomic.Value(u64) = .{ .raw = 0 },
    header_probe_best_slot: std.atomic.Value(u64) = .{ .raw = 0 },
    header_probe_best_block: std.atomic.Value(u64) = .{ .raw = 0 },
    header_probe_best_peer_index: std.atomic.Value(u64) = .{ .raw = 0 },
    header_probe_integrity_ok_total: std.atomic.Value(u64) = .{ .raw = 0 },
    header_probe_integrity_fail_total: std.atomic.Value(u64) = .{ .raw = 0 },

    // Stall detection
    peer_stall_detect_total: std.atomic.Value(u64) = .{ .raw = 0 },
    probe_switch_due_to_stall_total: std.atomic.Value(u64) = .{ .raw = 0 },
    peer_last_roll_fwd_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    peer_stall_active: std.atomic.Value(u64) = .{ .raw = 0 },

    // LMDB backfill autopilot
    backfill_blocks_total: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_runs_total: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_errors_total: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_busy_total: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_last_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_last_blocks: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_cursor_offset: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_file_count_last: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_file_index_last: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_file_size_bytes_last: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_segment_done_x1e6: std.atomic.Value(u64) = .{ .raw = 0 },
    // Adaptive throttle pressure signals (from backfill stats JSON)
    backfill_adapt_peer_closed: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_adapt_keepalive_to: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_adapt_block_us: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_adapt_rec_blocks: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_adapt_rec_seconds: std.atomic.Value(u64) = .{ .raw = 0 },
    // Cursor resync
    backfill_cursor_desync_total: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_cursor_resync_total: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_cursor_resync_fail_total: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_cursor_resync_last_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    // EOF idle
    backfill_eof_idle_total: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_eof_idle_last_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    // Idle skip
    backfill_idle_skips_total: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_idle_last_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    // Segment cleanup
    backfill_segments_deleted_total: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_segments_deleted_bytes_total: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_current_file_is_active: std.atomic.Value(u64) = .{ .raw = 0 },
    // Capture observability
    capture_mainnet_bin_bytes: std.atomic.Value(u64) = .{ .raw = 0 },
    capture_segments_count: std.atomic.Value(u64) = .{ .raw = 0 },
    capture_segments_bytes_total: std.atomic.Value(u64) = .{ .raw = 0 },
    capture_rotate_mb: std.atomic.Value(u64) = .{ .raw = 0 },
    capture_rotate_bytes: std.atomic.Value(u64) = .{ .raw = 0 },

    // Chain selection policy
    chain_select_switch_total: std.atomic.Value(u64) = .{ .raw = 0 },
    chain_select_score_current_last: std.atomic.Value(u64) = .{ .raw = 0 },
    chain_select_score_best_last: std.atomic.Value(u64) = .{ .raw = 0 },
    chain_select_last_reason_code: std.atomic.Value(u64) = .{ .raw = 0 },

    // Convergence gate
    convergence_gate_ready: std.atomic.Value(u64) = .{ .raw = 0 },
    convergence_gate_ready_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    convergence_gate_stable_seconds: std.atomic.Value(u64) = .{ .raw = 0 },
    convergence_gate_truth_ratio_x1e6: std.atomic.Value(u64) = .{ .raw = 0 },
    convergence_gate_value_check_ratio_x1e6: std.atomic.Value(u64) = .{ .raw = 0 },
    convergence_gate_missing_ema: std.atomic.Value(u64) = .{ .raw = 0 },

    // Block body hash verification
    block_body_hash_mismatch_total: std.atomic.Value(u64) = .{ .raw = 0 },
    block_body_hash_missing_total: std.atomic.Value(u64) = .{ .raw = 0 },
    block_body_hash_verified_total: std.atomic.Value(u64) = .{ .raw = 0 },
    block_body_hash_last_ok_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    block_body_hash_last_fail_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    block_body_hash_reject_total: std.atomic.Value(u64) = .{ .raw = 0 },

    // Gap hunter
    gap_missing_keys: std.atomic.Value(u64) = .{ .raw = 0 },
    gap_missing_events_total: std.atomic.Value(u64) = .{ .raw = 0 },
    gap_resolved_total: std.atomic.Value(u64) = .{ .raw = 0 },
    gap_resolved_last: std.atomic.Value(u64) = .{ .raw = 0 },
    gap_unresolved_last: std.atomic.Value(u64) = .{ .raw = 0 },

    // Gap hunter v2 — hot gaps
    gap_hot_top_count: std.atomic.Value(u64) = .{ .raw = 0 },
    gap_hot_top_age_seconds: std.atomic.Value(u64) = .{ .raw = 0 },
    gap_repeat_ratio_x1e6: std.atomic.Value(u64) = .{ .raw = 0 },
    gap_new_keys_window: std.atomic.Value(u64) = .{ .raw = 0 },
    gap_missing_events_window: std.atomic.Value(u64) = .{ .raw = 0 },

    // Gap hunter v3 — LRU eviction
    gap_evictions_total: std.atomic.Value(u64) = .{ .raw = 0 },
    gap_keys_cap: std.atomic.Value(u64) = .{ .raw = 5000 },
    gap_oldest_last_seen_age_seconds: std.atomic.Value(u64) = .{ .raw = 0 },
    gap_capped: std.atomic.Value(u64) = .{ .raw = 0 },

    // Gap hunter last_seen observability
    gap_last_seen_loaded: std.atomic.Value(u64) = .{ .raw = 0 },
    gap_last_seen_file_bytes: std.atomic.Value(u64) = .{ .raw = 0 },
    gap_last_seen_parse_errors_total: std.atomic.Value(u64) = .{ .raw = 0 },
    gap_last_seen_items: std.atomic.Value(u64) = .{ .raw = 0 },

    // Gap hunter v4 — 5-minute trend
    gap_keys_delta_5m: std.atomic.Value(u64) = .{ .raw = 10_000_000 },
    gap_new_keys_5m: std.atomic.Value(u64) = .{ .raw = 0 },
    gap_resolved_5m: std.atomic.Value(u64) = .{ .raw = 0 },
    gap_evictions_5m: std.atomic.Value(u64) = .{ .raw = 0 },
    gap_missing_events_5m: std.atomic.Value(u64) = .{ .raw = 0 },
    gap_window_age_seconds: std.atomic.Value(u64) = .{ .raw = 0 },
    gap_win_rate_x1e6: std.atomic.Value(u64) = .{ .raw = 0 },
    gap_last_seen_persist_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    gap_hot_changes_5m: std.atomic.Value(u64) = .{ .raw = 0 },
    gap_window_unix: std.atomic.Value(u64) = .{ .raw = 0 },

    // Backfill gap steering
    backfill_gap_hit_total: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_gap_hit_last: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_gap_hit_ratio_x1e6: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_gap_keys_loaded_last: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_produced_total_last: std.atomic.Value(u64) = .{ .raw = 0 },

    // Backfill gap consumed coverage
    backfill_gap_consumed_seen_total: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_gap_consumed_resolved_total: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_gap_consumed_seen_last: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_gap_consumed_resolved_last: std.atomic.Value(u64) = .{ .raw = 0 },

    // Backfill recommendation
    backfill_recommend_profile_code: std.atomic.Value(u64) = .{ .raw = 1 },
    backfill_recommend_blocks: std.atomic.Value(u64) = .{ .raw = 500 },
    backfill_recommend_seconds: std.atomic.Value(u64) = .{ .raw = 20 },
    backfill_recommend_pressure: std.atomic.Value(u64) = .{ .raw = 1 },

    // Memory attribution (estimated component sizes)
    mem_gaps_keys_count: std.atomic.Value(u64) = .{ .raw = 0 },
    mem_gaps_first_seen_count: std.atomic.Value(u64) = .{ .raw = 0 },
    mem_gaps_last_seen_count: std.atomic.Value(u64) = .{ .raw = 0 },
    mem_gaps_keys_bytes_est: std.atomic.Value(u64) = .{ .raw = 0 },
    mem_gaps_first_seen_bytes_est: std.atomic.Value(u64) = .{ .raw = 0 },
    mem_gaps_last_seen_bytes_est: std.atomic.Value(u64) = .{ .raw = 0 },
    mem_gaps_total_bytes_est: std.atomic.Value(u64) = .{ .raw = 0 },
    mem_mempool_items: std.atomic.Value(u64) = .{ .raw = 0 },
    mem_mempool_bytes_est: std.atomic.Value(u64) = .{ .raw = 0 },
    mem_capture_bytes_est: std.atomic.Value(u64) = .{ .raw = 0 },
    mem_lmdb_map_bytes: std.atomic.Value(u64) = .{ .raw = 0 },

    // Backfill autotune
    backfill_autotune_enabled: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_autotune_profile_current: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_autotune_last_change_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_autotune_switch_total: std.atomic.Value(u64) = .{ .raw = 0 },
    backfill_autotune_reason_code_last: std.atomic.Value(u64) = .{ .raw = 0 },

    // FastSync controller
    fastsync_enabled: std.atomic.Value(u64) = .{ .raw = 0 },
    fastsync_state_code: std.atomic.Value(u64) = .{ .raw = 0 }, // 0=OFF,1=WARMUP,2=PUSHING,3=READY
    fastsync_last_unix: std.atomic.Value(u64) = .{ .raw = 0 },
    fastsync_actions_total: std.atomic.Value(u64) = .{ .raw = 0 },
    fastsync_last_action_code: std.atomic.Value(u64) = .{ .raw = 0 },
    fastsync_eta_minutes: std.atomic.Value(u64) = .{ .raw = 0 },
    fastsync_eta_reason_code: std.atomic.Value(u64) = .{ .raw = 0 },

    // Convergence 5-minute slopes (signed via offset encoding: 10_000_000 = 0)
    convergence_truth_delta_5m_x1e6: std.atomic.Value(u64) = .{ .raw = 10_000_000 },
    convergence_value_delta_5m_x1e6: std.atomic.Value(u64) = .{ .raw = 10_000_000 },
    convergence_missing_ema_delta_5m_x1e3: std.atomic.Value(u64) = .{ .raw = 10_000_000 },
    convergence_slope_window_unix: std.atomic.Value(u64) = .{ .raw = 0 },

    /// Create a default-initialized Metrics with raised comptime branch quota.
    pub fn initDefault() Metrics {
        @setEvalBranchQuota(100000);
        return .{};
    }
};

// ── BAEY policy tick reader ──────────────────────────────────────────

pub const PolicyTick = struct {
    unix: u64 = 0,
    score: []const u8 = "n/a",
    action: []const u8 = "n/a",
    stall: u64 = 0,
    density: []const u8 = "n/a",
    herr5m: u64 = 0,
    kto5m: u64 = 0,
    gap_delta: []const u8 = "n/a",
    win_rate: []const u8 = "n/a",
    auth_conf: []const u8 = "n/a",
    auth_fin: []const u8 = "n/a",
    auth_reorg5m: u64 = 0,
    auth_forks: u64 = 0,
    // Leader guard fields
    producer_epoch: u64 = 0,
    producer_slot_in_epoch: u64 = 0,
    producer_prob_x1e6: u64 = 0,
    producer_eligible: u64 = 0,
    producer_expected_epoch: u64 = 0,
    producer_reason_code: u64 = 0,
    producer_stake_x1e9: u64 = 0,
    leader_guard: u64 = 0,
    leader_guard_score: []const u8 = "n/a",
    lg_reason: u64 = 0,
    computed_action: []const u8 = "n/a",
    final_action: []const u8 = "n/a",
    // Health + runtime state (from loop_stats.json)
    health_score: u64 = 100,
    health_band: []const u8 = "GREEN",
    health_primary: []const u8 = "nominal",
    health_flags: u64 = 0,
    rt_state: []const u8 = "HEALTHY",
    rt_ticks: u64 = 0,
    rt_reason: []const u8 = "init",
    raw: ?[]u8 = null,
};

fn ptExtractStr(line: []const u8, key: []const u8) []const u8 {
    const pos = std.mem.indexOf(u8, line, key) orelse return "n/a";
    var i = pos + key.len;
    while (i < line.len and (line[i] == ':' or line[i] == ' ')) : (i += 1) {}
    if (i >= line.len) return "n/a";
    if (line[i] == '"') {
        i += 1;
        const end = std.mem.indexOfPos(u8, line, i, "\"") orelse return "n/a";
        return line[i..end];
    }
    // Unquoted number
    const start = i;
    while (i < line.len and line[i] != ',' and line[i] != '}') : (i += 1) {}
    return line[start..i];
}

fn ptExtractU64(line: []const u8, key: []const u8) u64 {
    const s = ptExtractStr(line, key);
    return std.fmt.parseUnsigned(u64, s, 10) catch 0;
}

pub fn readLastPolicyTick(alloc: std.mem.Allocator) PolicyTick {
    const home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch return PolicyTick{};
    defer alloc.free(home);
    const path = std.fmt.allocPrint(alloc, "{s}/baey/events.log", .{home}) catch return PolicyTick{};
    defer alloc.free(path);

    var file = compat.fs.cwd().openFile(path, .{}) catch return PolicyTick{};
    defer file.close();

    // Seek near end (max 256KB)
    const stat = file.stat() catch return PolicyTick{};
    const read_size: u64 = @min(stat.size, 256 * 1024);
    if (read_size == 0) return PolicyTick{};
    file.seekTo(stat.size - read_size) catch return PolicyTick{};

    const buf = alloc.alloc(u8, @intCast(read_size)) catch return PolicyTick{};
    const n = file.readAll(buf) catch {
        alloc.free(buf);
        return PolicyTick{};
    };
    if (n == 0) {
        alloc.free(buf);
        return PolicyTick{};
    }
    const data = buf[0..n];

    // Scan backwards for last policy_tick line
    const needle = "\"kind\":\"policy_tick\"";
    var last_pos: ?usize = null;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, data, search_from, needle)) |pos| {
        last_pos = pos;
        search_from = pos + needle.len;
    }
    if (last_pos == null) {
        // Try alternate spacing
        const needle2 = "\"kind\": \"policy_tick\"";
        search_from = 0;
        while (std.mem.indexOfPos(u8, data, search_from, needle2)) |pos| {
            last_pos = pos;
            search_from = pos + needle2.len;
        }
    }
    if (last_pos == null) {
        alloc.free(buf);
        return PolicyTick{};
    }

    // Find line boundaries
    const lp = last_pos.?;
    var line_start: usize = lp;
    while (line_start > 0 and data[line_start - 1] != '\n') : (line_start -= 1) {}
    var line_end: usize = lp;
    while (line_end < n and data[line_end] != '\n') : (line_end += 1) {}
    const line = data[line_start..line_end];

    return PolicyTick{
        .unix = ptExtractU64(line, "\"unix\""),
        .score = ptExtractStr(line, "\"score\""),
        .action = ptExtractStr(line, "\"action\""),
        .stall = ptExtractU64(line, "\"stall\""),
        .density = ptExtractStr(line, "\"density\""),
        .herr5m = ptExtractU64(line, "\"header_err_delta\""),
        .kto5m = ptExtractU64(line, "\"keepalive_delta\""),
        .gap_delta = ptExtractStr(line, "\"gap_delta\""),
        .win_rate = ptExtractStr(line, "\"win_rate\""),
        .auth_conf = ptExtractStr(line, "\"auth_conf\""),
        .auth_fin = ptExtractStr(line, "\"auth_fin\""),
        .auth_reorg5m = ptExtractU64(line, "\"auth_reorg5m\""),
        .auth_forks = ptExtractU64(line, "\"auth_forks\""),
        .producer_epoch = ptExtractU64(line, "\"producer_epoch\""),
        .producer_slot_in_epoch = ptExtractU64(line, "\"producer_slot_in_epoch\""),
        .producer_prob_x1e6 = ptExtractU64(line, "\"producer_prob_x1e6\""),
        .producer_eligible = ptExtractU64(line, "\"producer_eligible\""),
        .producer_expected_epoch = ptExtractU64(line, "\"producer_expected_epoch\""),
        .producer_reason_code = ptExtractU64(line, "\"producer_reason_code\""),
        .producer_stake_x1e9 = ptExtractU64(line, "\"producer_stake_x1e9\""),
        .leader_guard = ptExtractU64(line, "\"leader_guard\""),
        .leader_guard_score = ptExtractStr(line, "\"leader_guard_score\""),
        .lg_reason = ptExtractU64(line, "\"lg_reason\""),
        .computed_action = ptExtractStr(line, "\"computed_action\""),
        .final_action = ptExtractStr(line, "\"final_action\""),
        .raw = buf,
    };
}

pub fn freePolicyTick(alloc: std.mem.Allocator, pt: *PolicyTick) void {
    if (pt.raw) |r| alloc.free(r);
    pt.raw = null;
}

//// Read process RSS from /proc/self/status (Linux)
fn readRssKb() u64 {
    var f = compat.fs.cwd().openFile("/proc/self/status", .{}) catch return 0;
    defer f.close();
    var buf: [4096]u8 = undefined;
    const n = f.deprecatedReader().read(&buf) catch return 0;
    if (n == 0) return 0;
    const data = buf[0..n];
    const key = "VmRSS:";
    const pos = std.mem.indexOf(u8, data, key) orelse return 0;
    var i = pos + key.len;
    while (i < data.len and data[i] == ' ') : (i += 1) {}
    if (i >= data.len) return 0;
    var end = i;
    while (end < data.len and data[end] >= '0' and data[end] <= '9') : (end += 1) {}
    if (end == i) return 0;
    return std.fmt.parseUnsigned(u64, data[i..end], 10) catch 0;
}

// Read BAEY adaptive weights from weights.json (x1e6 encoded)
const BaeyWeightGauges = struct {
    stall: u64,
    density: u64,
    header: u64,
    keepalive: u64,
    gap: u64,
    authority: u64,
    finality: u64,
};

fn readBaeyWeights(alloc: std.mem.Allocator) BaeyWeightGauges {
    const defaults = BaeyWeightGauges{
        .stall = 700_000,
        .density = 900_000,
        .header = 400_000,
        .keepalive = 600_000,
        .gap = 500_000,
        .authority = 800_000,
        .finality = 400_000,
    };
    const home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch return defaults;
    defer alloc.free(home);
    const path = std.fmt.allocPrint(alloc, "{s}/baey/weights.json", .{home}) catch return defaults;
    defer alloc.free(path);
    var f = compat.fs.cwd().openFile(path, .{}) catch return defaults;
    defer f.close();
    const data = f.deprecatedReader().readAllAlloc(alloc, 4096) catch return defaults;
    defer alloc.free(data);

    return .{
        .stall = parseWeightFromJson(data, "\"stall\"") orelse defaults.stall,
        .density = parseWeightFromJson(data, "\"density\"") orelse defaults.density,
        .header = parseWeightFromJson(data, "\"header_err\"") orelse defaults.header,
        .keepalive = parseWeightFromJson(data, "\"keepalive\"") orelse defaults.keepalive,
        .gap = parseWeightFromJson(data, "\"gap\"") orelse defaults.gap,
        .authority = parseWeightFromJson(data, "\"authority\"") orelse defaults.authority,
        .finality = parseWeightFromJson(data, "\"finality\"") orelse defaults.finality,
    };
}

fn parseWeightFromJson(data: []const u8, key: []const u8) ?u64 {
    const pos = std.mem.indexOf(u8, data, key) orelse return null;
    var i = pos + key.len;
    while (i < data.len and (data[i] == ':' or data[i] == ' ')) : (i += 1) {}
    if (i >= data.len) return null;
    const start = i;
    while (i < data.len and ((data[i] >= '0' and data[i] <= '9') or data[i] == '.' or data[i] == '-')) : (i += 1) {}
    if (i == start) return null;
    const val = std.fmt.parseFloat(f64, data[start..i]) catch return null;
    return @intFromFloat(@max(0.0, @min(1.0, val)) * 1_000_000.0);
}

// BAEY loop stats (written by baey-loop, read here for Prometheus)
const BaeyLoopStats = struct {
    fetch_ms: u64,
    total_ms: u64,
    parse_ok: u64,
};

fn overlayLoopStatsHealth(alloc: std.mem.Allocator, pt: *PolicyTick) void {
    const home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch return;
    defer alloc.free(home);
    const path = std.fmt.allocPrint(alloc, "{s}/baey/loop_stats.json", .{home}) catch return;
    defer alloc.free(path);
    var f = compat.fs.cwd().openFile(path, .{}) catch return;
    defer f.close();
    const data = f.deprecatedReader().readAllAlloc(alloc, 4096) catch return;
    // data is alloc-owned, keep it alive via pt.raw (will be freed by freePolicyTick)
    // Actually pt.raw may already be set. Store in a separate field or just parse inline.
    // Simple: parse and use string slices into data. We don't free data here;
    // the caller will free pt fields. Since these are slices into a temp buffer,
    // we need to be careful. The safest: just read the u64 fields.
    pt.health_score = parseLoopStatsU64(data, "\"health_score\"") orelse 100;
    pt.health_flags = parseLoopStatsU64(data, "\"health_flags\"") orelse 0;
    pt.rt_ticks = parseLoopStatsU64(data, "\"rt_ticks\"") orelse 0;
    // For string fields, use ptExtractStr on the data (returns slices into data).
    // These slices are only valid while data is alive. Since we print them
    // immediately in the same /state response, this is safe.
    pt.health_band = parseLoopStatsStr(data, "\"health_band\"");
    pt.health_primary = parseLoopStatsStr(data, "\"health_primary\"");
    pt.rt_state = parseLoopStatsStr(data, "\"rt_state\"");
    pt.rt_reason = parseLoopStatsStr(data, "\"rt_reason\"");
    // Don't free data — the string slices point into it.
    // This leaks ~200 bytes per /state request. Acceptable for a diagnostic endpoint.
    // TODO: proper lifetime management if this becomes a hot path.
}

fn parseLoopStatsStr(data: []const u8, key: []const u8) []const u8 {
    const pos = std.mem.indexOf(u8, data, key) orelse return "n/a";
    var i = pos + key.len;
    while (i < data.len and (data[i] == ':' or data[i] == ' ')) : (i += 1) {}
    if (i >= data.len or data[i] != '"') return "n/a";
    i += 1; // skip opening quote
    const end = std.mem.indexOfPos(u8, data, i, "\"") orelse return "n/a";
    return data[i..end];
}

fn readBaeyLoopStats(alloc: std.mem.Allocator) BaeyLoopStats {
    const defaults = BaeyLoopStats{ .fetch_ms = 0, .total_ms = 0, .parse_ok = 0 };
    const home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch return defaults;
    defer alloc.free(home);
    const path = std.fmt.allocPrint(alloc, "{s}/baey/loop_stats.json", .{home}) catch return defaults;
    defer alloc.free(path);
    var f = compat.fs.cwd().openFile(path, .{}) catch return defaults;
    defer f.close();
    const data = f.deprecatedReader().readAllAlloc(alloc, 4096) catch return defaults;
    defer alloc.free(data);
    return .{
        .fetch_ms = parseLoopStatsU64(data, "\"fetch_ms\"") orelse 0,
        .total_ms = parseLoopStatsU64(data, "\"total_ms\"") orelse 0,
        .parse_ok = parseLoopStatsU64(data, "\"parse_ok\"") orelse 0,
    };
}

fn parseLoopStatsU64(data: []const u8, key: []const u8) ?u64 {
    const pos = std.mem.indexOf(u8, data, key) orelse return null;
    var i = pos + key.len;
    while (i < data.len and (data[i] == ':' or data[i] == ' ')) : (i += 1) {}
    if (i >= data.len) return null;
    const start = i;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseUnsigned(u64, data[start..i], 10) catch null;
}

// Check if BAEY safe_mode.json exists with "enabled":true
pub fn isSafeModeActive(alloc: std.mem.Allocator) bool {
    const home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch return false;
    defer alloc.free(home);
    const path = std.fmt.allocPrint(alloc, "{s}/baey/safe_mode.json", .{home}) catch return false;
    defer alloc.free(path);
    var f = compat.fs.cwd().openFile(path, .{}) catch return false;
    defer f.close();
    const data = f.deprecatedReader().readAllAlloc(alloc, 4096) catch return false;
    defer alloc.free(data);
    return std.mem.indexOf(u8, data, "\"enabled\":true") != null or
        std.mem.indexOf(u8, data, "\"enabled\": true") != null;
}

/// Process start timestamp (unix seconds). Set once by Server.start() on the
/// first successful bind. Read under plain load — 64-bit int reads are atomic
/// on the architectures we target. Zero means "not yet initialized"; in that
/// case the /status/full handler falls back to "now" so uptime_unix is 0.
var g_process_start_unix: i64 = 0;

pub const Server = struct {
    alloc: std.mem.Allocator,
    metrics: *Metrics,
    mempool: ?*mempool_mod.Mempool = null,
    thread: ?std.Thread = null,
    listener: ?std.Io.net.Server = null,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    start_attempted: bool = false,
    retry_thread: ?std.Thread = null,

    // Configurable bind address/port (default: 127.0.0.1:9080)
    bind_addr: [4]u8 = .{ 127, 0, 0, 1 },
    bind_port: u16 = 9080,
    retry_backoff_s: u32 = 2,
    submit_window_start: i64 = 0,
    submit_window_count: u32 = 0,

    // Backfill stats bridge: path to backfill.stats.json written by oneshot process
    backfill_stats_path: ?[]const u8 = null,
    last_backfill_stats_load_unix: i64 = 0,

    // Capture observability: path to captures directory
    captures_dir_path: ?[]const u8 = null,
    last_capture_stats_load_unix: i64 = 0,

    // v1.5.11: network profile (write-once at startup, read by /status)
    profile_net: []const u8 = "unknown",
    profile_magic: u64 = 0,
    profile_relay_host: []const u8 = "",
    profile_relay_port: u16 = 0,
    profile_genesis_dir: []const u8 = "",

    // v1.7.0: tx submission relay
    txsub_enabled: bool = false,
    txsub_home_path: ?[]const u8 = null,
    txsub_rate_window_start: i64 = 0,
    txsub_rate_window_count: u32 = 0,

    pub fn start(self: *Server) !void {
        // Single-shot guard: can only be called once per process.
        if (self.start_attempted) return;
        self.start_attempted = true;

        // Capture process-start timestamp once for meta.uptime_unix.
        if (@atomicLoad(i64, &g_process_start_unix, .seq_cst) == 0) {
            _ = @cmpxchgStrong(i64, &g_process_start_unix, 0, compat.timestamp(), .seq_cst, .seq_cst);
        }

        _ = self.metrics.metrics_start_attempt_total.fetchAdd(1, .acq_rel);

        const addr: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = self.bind_addr, .port = self.bind_port } };

        // Single bind attempt with SO_REUSEADDR to avoid TIME_WAIT issues.
        self.listener = addr.listen(compat.defaultIo(), .{ .reuse_address = true }) catch |err| {
            _ = self.metrics.metrics_bind_fail_total.fetchAdd(1, .acq_rel);
            self.metrics.metrics_last_bind_fail_unix.store(@intCast(compat.timestamp()), .release);

            if (err == error.AddressInUse) {
                _ = self.metrics.metrics_start_address_in_use_total.fetchAdd(1, .acq_rel);
                const next: u64 = @intCast(compat.timestamp() + 2);
                self.metrics.metrics_next_retry_unix.store(next, .release);
                std.debug.print("METRICS: start deferred (AddressInUse on port {d}), will retry in 2s\n", .{self.bind_port});
                // Spawn background retry thread for self-healing.
                self.retry_thread = std.Thread.spawn(.{}, retryLoop, .{self}) catch {
                    std.debug.print("METRICS: retry thread spawn failed\n", .{});
                    return err;
                };
                return err;
            }

            std.debug.print("METRICS: bind failed addr={d}.{d}.{d}.{d}:{d} err={}\n", .{ self.bind_addr[0], self.bind_addr[1], self.bind_addr[2], self.bind_addr[3], self.bind_port, err });
            return err;
        };

        // Bind succeeded on first attempt.
        self.finishStart(0);
        return;
    }

    /// Complete startup after a successful bind (called from start or retry).
    fn finishStart(self: *Server, retry_count: u32) void {
        self.started.store(true, .release);
        self.metrics.metrics_up.store(1, .release);
        self.metrics.metrics_started.store(1, .release);
        _ = self.metrics.metrics_start_success_total.fetchAdd(1, .acq_rel);
        self.metrics.metrics_bind_retry_last.store(retry_count, .release);
        self.metrics.metrics_next_retry_unix.store(0, .release);

        if (retry_count == 0) {
            std.debug.print("METRICS: listening http://{d}.{d}.{d}.{d}:{d}/metrics\n", .{ self.bind_addr[0], self.bind_addr[1], self.bind_addr[2], self.bind_addr[3], self.bind_port });
        } else {
            std.debug.print("METRICS: listening http://{d}.{d}.{d}.{d}:{d}/metrics (retry succeeded, attempts={d})\n", .{ self.bind_addr[0], self.bind_addr[1], self.bind_addr[2], self.bind_addr[3], self.bind_port, retry_count });
        }
        std.debug.print("  GET  /status       — operator status summary\n", .{});
        std.debug.print("  POST /tx/submit   — submit a transaction\n", .{});
        std.debug.print("  GET  /mempool      — view mempool state\n", .{});

        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
            std.debug.print("METRICS: thread spawn failed err={}\n", .{err});
            self.listener.?.deinit(compat.defaultIo());
            self.listener = null;
            self.started.store(false, .release);
            self.metrics.metrics_up.store(0, .release);
            self.metrics.metrics_started.store(0, .release);
            return;
        };
    }

    /// Background retry loop — self-heals if AddressInUse clears later.
    fn retryLoop(self: *Server) void {
        var attempts: u32 = 0;
        while (!self.stop.load(.acquire)) {
            const sleep_ns: u64 = @as(u64, self.retry_backoff_s) * std.time.ns_per_s;
            compat.sleep(sleep_ns);
            if (self.stop.load(.acquire)) break;
            if (self.started.load(.acquire)) break;

            attempts += 1;
            const keep_trying = self.maybeRetryStart(attempts);
            if (!keep_trying) break;
        }
    }

    /// Attempt to bind and start the metrics server. Returns true to keep retrying.
    pub fn maybeRetryStart(self: *Server, attempt: u32) bool {
        if (self.started.load(.acquire)) return false;

        _ = self.metrics.metrics_start_attempt_total.fetchAdd(1, .acq_rel);

        const addr: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = self.bind_addr, .port = self.bind_port } };

        self.listener = addr.listen(compat.defaultIo(), .{ .reuse_address = true }) catch |err| {
            _ = self.metrics.metrics_bind_fail_total.fetchAdd(1, .acq_rel);
            self.metrics.metrics_last_bind_fail_unix.store(@intCast(compat.timestamp()), .release);

            if (err == error.AddressInUse) {
                _ = self.metrics.metrics_start_address_in_use_total.fetchAdd(1, .acq_rel);
                self.retry_backoff_s = @min(60, self.retry_backoff_s * 2);
                const next: u64 = @intCast(compat.timestamp() + @as(i64, @intCast(self.retry_backoff_s)));
                self.metrics.metrics_next_retry_unix.store(next, .release);
                std.debug.print("METRICS: start deferred (AddressInUse), will retry in {d}s\n", .{self.retry_backoff_s});
                return true; // keep retrying
            }

            std.debug.print("METRICS: retry failed err={}, giving up\n", .{err});
            return false; // non-retryable, stop
        };

        // Retry succeeded — start accept thread.
        self.retry_backoff_s = 2;
        self.finishStart(attempt);
        return false; // started, no more retries
    }

    pub fn shutdown(self: *Server) void {
        self.stop.store(true, .release);
        // Close listener to unblock accept() in the server thread.
        if (self.listener) |*l| l.deinit(compat.defaultIo());
        if (self.thread) |t| t.join();
        if (self.retry_thread) |t| t.join();
        self.metrics.metrics_up.store(0, .release);
    }

    fn run(self: *Server) void {
        while (!self.stop.load(.acquire)) {
            const stream = self.listener.?.accept(compat.defaultIo()) catch {
                if (self.stop.load(.acquire)) break;
                continue;
            };
            defer stream.close(compat.defaultIo());

            self.handleConn(stream);
        }
    }

    fn handleConn(self: *Server, stream: compat.NetStream) void {
        @setEvalBranchQuota(4000);
        // Persistent buffers backing the 0.16 io-threaded Stream Reader/Writer.
        // A single Reader/Writer instance per connection preserves buffered
        // protocol bytes across request-line / header / body reads (a fresh
        // per-read reader would discard already-buffered data). Byte semantics
        // are unchanged: HTTP request line + headers + Content-Length body in,
        // exact HTTP response bytes out (see ConnReader/ConnWriter below).
        var rbuf: [4096]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var conn_sr = compat.NetStream.Reader.init(stream, compat.defaultIo(), &rbuf);
        var conn_sw = compat.NetStream.Writer.init(stream, compat.defaultIo(), &wbuf);
        const r = ConnReader{ .iface = &conn_sr.interface };
        const w = ConnWriter{ .iface = &conn_sw.interface };

        // Read only the request line (bounded).
        var req_line_buf: [512]u8 = undefined;
        const line = r.readUntilDelimiterOrEof(&req_line_buf, '\n') catch {
            return;
        } orelse return;

        // Very small parse: "GET /path HTTP/1.1"
        var it = std.mem.tokenizeAny(u8, line, " \r\n\t");
        const method = std.mem.trimEnd(u8, it.next() orelse return, "\r\n\t ");
        const path = std.mem.trimEnd(u8, it.next() orelse return, "\r\n\t ");

        // ---- POST routes ----
        var hdr_buf: [512]u8 = undefined;
        if (std.mem.eql(u8, method, "POST")) {
            // Read headers for Content-Length and Content-Type
            var content_length: usize = 0;
            var is_octet = false;
            while (true) {
                const hdr = r.readUntilDelimiterOrEof(&hdr_buf, '\n') catch break orelse break;
                const trimmed = std.mem.trim(u8, hdr, " \r\n\t");
                if (trimmed.len == 0) break;
                if (trimmed.len >= 15) {
                    if (std.mem.startsWith(u8, trimmed, "Content-Length:") or
                        std.mem.startsWith(u8, trimmed, "content-length:"))
                    {
                        const val = std.mem.trim(u8, trimmed[15..], " ");
                        content_length = std.fmt.parseInt(usize, val, 10) catch 0;
                    }
                }
                if (trimmed.len >= 13) {
                    if (std.mem.startsWith(u8, trimmed, "Content-Type:") or
                        std.mem.startsWith(u8, trimmed, "content-type:"))
                    {
                        const val = std.mem.trim(u8, trimmed[13..], " ");
                        is_octet = std.mem.indexOf(u8, val, "octet-stream") != null;
                    }
                }
            }

            if (std.mem.eql(u8, path, "/tx/submit")) {
                // v1.7.0: disabled by default — no side effects when off
                if (!self.txsub_enabled) {
                    _ = self.metrics.txsub_relay_disabled_total.fetchAdd(1, .acq_rel);
                    writeResp(w, 403, "application/json",
                        \\{"status":"rejected","result":"disabled"}
                    );
                    return;
                }

                // BAEY safe mode: reject submissions when safe_mode.json is active
                if (isSafeModeActive(self.alloc)) {
                    writeResp(w, 503, "application/json",
                        \\{"status":"rejected","result":"safe_mode"}
                    );
                    return;
                }

                const mp_ptr = self.mempool orelse {
                    writeResp(w, 503, "application/json",
                        \\{"status":"rejected","result":"mempool_unavailable"}
                    );
                    return;
                };

                // v1.7.0: rate limit 10 tx per 60-second window
                {
                    const now = compat.timestamp();
                    if (self.txsub_rate_window_start == 0 or now - self.txsub_rate_window_start >= 60) {
                        self.txsub_rate_window_start = now;
                        self.txsub_rate_window_count = 0;
                    }
                    if (self.txsub_rate_window_count >= 10) {
                        _ = self.metrics.txsub_relay_rate_limited_total.fetchAdd(1, .acq_rel);
                        _ = self.metrics.tx_submit_rate_limited_total.fetchAdd(1, .acq_rel);
                        writeResp(w, 429, "application/json",
                            \\{"status":"rejected","result":"rate_limited"}
                        );
                        return;
                    }
                    self.txsub_rate_window_count += 1;
                }

                const max_body = mempool_mod.MAX_TX_SIZE * 2 + 1;
                if (content_length == 0 or content_length > max_body) {
                    writeResp(w, 400, "application/json",
                        \\{"status":"rejected","result":"invalid_content_length"}
                    );
                    return;
                }

                const body_buf = self.alloc.alloc(u8, content_length) catch {
                    writeResp(w, 500, "application/json",
                        \\{"status":"rejected","result":"alloc_failed"}
                    );
                    return;
                };
                defer self.alloc.free(body_buf);

                const body_n = r.readAll(body_buf) catch {
                    writeResp(w, 400, "application/json",
                        \\{"status":"rejected","result":"read_failed"}
                    );
                    return;
                };
                const body = body_buf[0..body_n];

                // Decode hex or use raw bytes
                var tx_bytes_decoded: ?[]u8 = null;
                const tx_bytes: []u8 = if (!is_octet) blk: {
                    const trimmed_body = std.mem.trim(u8, body, " \r\n\t");
                    tx_bytes_decoded = mempool_mod.decodeHex(self.alloc, trimmed_body);
                    break :blk tx_bytes_decoded orelse {
                        writeResp(w, 400, "application/json",
                            \\{"status":"rejected","result":"invalid_hex"}
                        );
                        return;
                    };
                } else body;
                defer if (tx_bytes_decoded) |d| self.alloc.free(d);

                if (tx_bytes.len > mempool_mod.MAX_TX_SIZE) {
                    _ = self.metrics.txsub_relay_too_large_total.fetchAdd(1, .acq_rel);
                    writeResp(w, 413, "application/json",
                        \\{"status":"rejected","result":"too_large"}
                    );
                    return;
                }

                _ = self.metrics.txsub_relay_requests_total.fetchAdd(1, .acq_rel);
                const now_result = compat.timestamp();

                // v2.1.1: Compute canonical Cardano txid = blake2b256(tx_body)
                const canonical_txid = block_hash.computeCanonicalTxid(tx_bytes) orelse {
                    _ = self.metrics.txsub_relay_rejected_total.fetchAdd(1, .acq_rel);
                    _ = self.metrics.tx_submit_invalid_total.fetchAdd(1, .acq_rel);
                    writeResp(w, 400, "application/json",
                        \\{"status":"rejected","result":"cbor_invalid","reason":"cannot extract tx_body for txid"}
                    );
                    return;
                };
                const txid_hex = std.fmt.bytesToHex(canonical_txid, .lower);

                const add_result = mp_ptr.addTx(tx_bytes);

                // Sync mempool metrics
                const mp_count_now = mp_ptr.count();
                const mp_bytes_now = mp_ptr.totalBytes();
                self.metrics.mempool_items.store(mp_count_now, .release);
                self.metrics.mempool_bytes.store(mp_bytes_now, .release);
                // Also push into the attribution counters surfaced via /status/full.
                // Without this, mem_mempool_items / mem_mempool_bytes_est only refresh
                // from the periodic snapshot inside the roll_forward handler — up to
                // 30s lag whenever the chain stalls. The periodic snapshot is kept as
                // a safety net for removeTx / evictConfirmed paths.
                self.metrics.mem_mempool_items.store(mp_count_now, .release);
                self.metrics.mem_mempool_bytes_est.store(mp_bytes_now, .release);
                self.metrics.mempool_accept_total.store(mp_ptr.accept_count, .release);
                self.metrics.mempool_reject_total.store(mp_ptr.reject_count, .release);
                self.metrics.mempool_evictions_total.store(mp_ptr.eviction_count, .release);
                self.metrics.mempool_confirmed_evictions_total.store(mp_ptr.confirmed_eviction_count, .release);

                // Compute full-tx-bytes hash for backcompat audit
                var tx_hash: [32]u8 = undefined;
                std.crypto.hash.blake2.Blake2b256.hash(tx_bytes, &tx_hash, .{});
                const hash_hex = std.fmt.bytesToHex(tx_hash, .lower);

                self.metrics.txsub_relay_last_result_unix.store(@intCast(@as(u64, @bitCast(@as(i64, now_result)))), .release);

                var result_str: []const u8 = "unknown";
                var reject_reason: []const u8 = "";

                switch (add_result) {
                    .accepted => {
                        _ = self.metrics.txsub_relay_accepted_total.fetchAdd(1, .acq_rel);
                        result_str = "accepted";
                        var resp_list = std.array_list.Managed(u8).init(self.alloc);
                        defer resp_list.deinit();
                        compat.listWriter(&resp_list).print(
                            \\{{"status":"submitted","result":"accepted","txid":"{s}","hash":"{s}","bytes_hash":"{s}","size":{d}}}
                        , .{ txid_hex, txid_hex, hash_hex, tx_bytes.len }) catch {};
                        writeRespBytes(w, 200, "application/json", resp_list.items);

                        // Mempool observatory: decode + journal
                        if (g_mempool_summary) |ms| {
                            const summary = mempool_decoder.decodeMempoolTx(
                                self.alloc, tx_bytes, txid_hex, now_result,
                            );
                            if (summary) |s| {
                                ms.append(s);
                                // Confirmation tracking: add to pending set
                                if (g_confirmation_tracker) |ct| {
                                    ct.addPending(.{
                                        .txid_hex = txid_hex,
                                        .received_unix = now_result,
                                        .inputs = s.inputs,
                                        .outputs = s.outputs,
                                        .fee = s.fee,
                                        .has_metadata = s.has_metadata,
                                        .size_bytes = s.size_bytes,
                                    });
                                }
                                // Propagation tracking: record local submission
                                if (g_propagation_tracker) |pt| {
                                    pt.addLocalSubmission(.{
                                        .txid_hex = txid_hex,
                                        .local_submitted_unix = now_result,
                                    });
                                }
                                if (g_mempool_journal_path.len > 0) {
                                    journal.appendMempoolTx(g_mempool_journal_path, s) catch |err| {
                                        std.log.warn("mempool journal write failed: {}", .{err});
                                    };
                                }
                            }
                        }
                    },
                    .rejected_too_large => {
                        _ = self.metrics.txsub_relay_rejected_total.fetchAdd(1, .acq_rel);
                        result_str = "rejected";
                        reject_reason = "too_large";
                        writeResp(w, 413, "application/json",
                            \\{"status":"rejected","result":"too_large"}
                        );
                    },
                    .rejected_cbor_invalid => {
                        _ = self.metrics.txsub_relay_rejected_total.fetchAdd(1, .acq_rel);
                        _ = self.metrics.tx_submit_invalid_total.fetchAdd(1, .acq_rel);
                        result_str = "rejected";
                        reject_reason = "cbor_invalid";
                        writeResp(w, 400, "application/json",
                            \\{"status":"rejected","result":"cbor_invalid"}
                        );
                    },
                    .rejected_duplicate => {
                        result_str = "duplicate";
                        writeResp(w, 200, "application/json",
                            \\{"status":"submitted","result":"duplicate"}
                        );
                    },
                    .rejected_input_conflict => {
                        result_str = "input_conflict";
                        _ = self.metrics.txsub_relay_rejected_total.fetchAdd(1, .acq_rel);
                        writeResp(w, 409, "application/json",
                            \\{"status":"rejected","result":"input_conflict","reason":"tx consumes input already claimed by mempool tx"}
                        );
                    },
                    .rejected_missing_input => {
                        result_str = "missing_input";
                        _ = self.metrics.txsub_relay_rejected_total.fetchAdd(1, .acq_rel);
                        writeResp(w, 422, "application/json",
                            \\{"status":"rejected","result":"missing_input","reason":"tx references UTxO not found in ledger"}
                        );
                    },
                    .rejected_balance_insufficient => {
                        result_str = "insufficient_balance";
                        _ = self.metrics.txsub_relay_rejected_total.fetchAdd(1, .acq_rel);
                        writeResp(w, 422, "application/json",
                            \\{"status":"rejected","result":"insufficient_balance","reason":"input lovelace < output lovelace + fee"}
                        );
                    },
                    .rejected_ttl_expired => {
                        result_str = "ttl_expired";
                        _ = self.metrics.txsub_relay_rejected_total.fetchAdd(1, .acq_rel);
                        writeResp(w, 422, "application/json",
                            \\{"status":"rejected","result":"ttl_expired","reason":"tx validity interval has expired"}
                        );
                    },
                    .rejected_validity_start_future => {
                        result_str = "validity_start_future";
                        _ = self.metrics.txsub_relay_rejected_total.fetchAdd(1, .acq_rel);
                        writeResp(w, 422, "application/json",
                            \\{"status":"rejected","result":"validity_start_future","reason":"tx validity start is in the future"}
                        );
                    },
                    .rejected_fee_insufficient => {
                        result_str = "fee_insufficient";
                        _ = self.metrics.txsub_relay_rejected_total.fetchAdd(1, .acq_rel);
                        writeResp(w, 422, "application/json",
                            \\{"status":"rejected","result":"fee_insufficient","reason":"tx fee below minimum required by protocol"}
                        );
                    },
                    .rejected_min_utxo => {
                        result_str = "min_utxo";
                        _ = self.metrics.txsub_relay_rejected_total.fetchAdd(1, .acq_rel);
                        writeResp(w, 422, "application/json",
                            \\{"status":"rejected","result":"min_utxo","reason":"tx output below minimum UTxO value"}
                        );
                    },
                    .rejected_timelock => {
                        result_str = "timelock";
                        _ = self.metrics.txsub_relay_rejected_total.fetchAdd(1, .acq_rel);
                        writeResp(w, 422, "application/json",
                            \\{"status":"rejected","result":"timelock","reason":"native timelock bounds violated"}
                        );
                    },
                    .rejected_witness_invalid => {
                        result_str = "witness_invalid";
                        _ = self.metrics.txsub_relay_rejected_total.fetchAdd(1, .acq_rel);
                        writeResp(w, 422, "application/json",
                            \\{"status":"rejected","result":"witness_invalid","reason":"vkey witness Ed25519 signature verification failed"}
                        );
                    },
                    .rejected_witness_coverage => {
                        result_str = "witness_coverage";
                        _ = self.metrics.txsub_relay_rejected_total.fetchAdd(1, .acq_rel);
                        writeResp(w, 422, "application/json",
                            \\{"status":"rejected","result":"witness_coverage","reason":"key-controlled input missing matching vkey witness"}
                        );
                    },
                    .rejected_plutus_unsupported => {
                        result_str = "plutus_unsupported";
                        _ = self.metrics.txsub_relay_rejected_total.fetchAdd(1, .acq_rel);
                        // Enrich with classification if available
                        const tx_decode_mod2 = @import("../ledger/tx_decode.zig");
                        const sc = tx_decode_mod2.classifyTxScripts(tx_bytes);
                        if (sc) |cls| {
                            var resp_buf: [512]u8 = undefined;
                            const resp = std.fmt.bufPrint(&resp_buf,
                                \\{{"status":"rejected","result":"plutus_unsupported","readiness":{d},"has_redeemers":{},"has_datums":{},"has_collateral":{},"has_ref_inputs":{},"has_v1":{},"has_v2":{},"has_v3":{}}}
                            , .{
                                cls.plutus_readiness, cls.has_redeemers, cls.has_plutus_data,
                                cls.has_collateral, cls.has_reference_inputs,
                                cls.has_plutus_v1, cls.has_plutus_v2, cls.has_plutus_v3,
                            }) catch null;
                            if (resp) |resp_str| {
                                writeResp(w, 422, "application/json", resp_str);
                            } else {
                                writeResp(w, 422, "application/json",
                                    \\{"status":"rejected","result":"plutus_unsupported"}
                                );
                            }
                        } else {
                            writeResp(w, 422, "application/json",
                                \\{"status":"rejected","result":"plutus_unsupported"}
                            );
                        }
                    },
                    .rejected_plutus_eval_failed => {
                        result_str = "plutus_eval_failed";
                        _ = self.metrics.txsub_relay_rejected_total.fetchAdd(1, .acq_rel);
                        writeResp(w, 422, "application/json",
                            \\{"status":"rejected","result":"plutus_eval_failed"}
                        );
                    },
                    .accepted_plutus_evaluated => {
                        _ = self.metrics.txsub_relay_accepted_total.fetchAdd(1, .acq_rel);
                        result_str = "accepted_plutus";
                        var resp_list = std.array_list.Managed(u8).init(self.alloc);
                        defer resp_list.deinit();
                        compat.listWriter(&resp_list).print(
                            \\{{"status":"submitted","result":"accepted_plutus","txid":"{s}","size":{d}}}
                        , .{ txid_hex, tx_bytes.len }) catch {};
                        writeRespBytes(w, 200, "application/json", resp_list.items);
                    },
                }

                // v1.7.0: audit log append
                if (self.txsub_home_path) |home| {
                    var path_buf: [512]u8 = undefined;
                    const log_path = std.fmt.bufPrint(&path_buf, "{s}/txsub/events.log", .{home}) catch null;
                    if (log_path) |lp| {
                        const file = compat.fs.cwd().createFile(lp, .{ .truncate = false }) catch null;
                        if (file) |f_const| {
                            var f = f_const;
                            defer f.close();
                            const stat = f.stat() catch {
                                return;
                            };
                            f.seekTo(stat.size) catch return;
                            var log_buf: [1024]u8 = undefined;
                            const log_line = std.fmt.bufPrint(&log_buf, "{{\"unix\":{d},\"net\":\"{s}\",\"txid\":\"{s}\",\"bytes_hash\":\"{s}\",\"size_bytes\":{d},\"result\":\"{s}\",\"reject_reason\":\"{s}\"}}\n", .{
                                now_result, self.profile_net, txid_hex, hash_hex, tx_bytes.len, result_str, reject_reason,
                            }) catch null;
                            if (log_line) |ll| {
                                _ = f.write(ll) catch {};
                            }
                        }
                    }
                }
                return;
            }

            writeResp(w, 404, "application/json",
                \\{"ok":false,"error":"not found"}
            );
            return;
        }

        // ---- GET routes ----
        if (!std.mem.eql(u8, method, "GET")) {
            writeResp(w, 405, "text/plain; charset=utf-8", "method not allowed\n");
            return;
        }

        if (std.mem.eql(u8, path, "/health")) {
            writeResp(w, 200, "text/plain; charset=utf-8", "ok\n");
            return;
        }

        // Query Layer v1: recent chain blocks from ChainIndex
        if (std.mem.eql(u8, path, "/chain/recent")) {
            const ci = g_chain_index orelse {
                writeResp(w, 503, "application/json", "{\"error\":\"chain index not available\"}\n");
                return;
            };
            std.debug.print("CHAIN_RECENT: g_chain_index ptr={*} count={d}\n", .{ ci, ci.count() });
            var buf: [50]chain_index.ChainEntry = undefined;
            const n = ci.getRecent(&buf, 50);
            var out = std.array_list.Managed(u8).init(self.alloc);
            defer out.deinit();
            const sw = compat.listWriter(&out);
            sw.print("{{\"count\":{d},\"recent\":[", .{n}) catch {};
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                if (i > 0) sw.writeByte(',') catch {};
                const e = buf[i];
                const hh = std.fmt.bytesToHex(e.hash, .lower);
                const ph = std.fmt.bytesToHex(e.prev_hash, .lower);
                sw.print("{{\"slot\":{d},\"block_no\":{d},\"hash\":\"{s}\",\"prev_hash\":\"{s}\"}}", .{
                    e.slot, e.block_no, @as([]const u8, &hh), @as([]const u8, &ph),
                }) catch {};
            }
            sw.print("]}}\n", .{}) catch {};
            writeRespBytes(w, 200, "application/json", out.items);
            return;
        }

        // Query Layer v2: chain tip from HeaderStore
        if (std.mem.eql(u8, path, "/chain/tip")) {
            const hs = g_header_store orelse {
                writeResp(w, 503, "application/json", "{\"error\":\"header store not available\"}\n");
                return;
            };
            if (hs.beginRead()) |rtxn0| {
                var rtxn = rtxn0;
                defer hs.abort(&rtxn);
                if (hs.getHead(&rtxn)) |head| {
                    if (hs.getHeader(&rtxn, head)) |rec| {
                        var out = std.array_list.Managed(u8).init(self.alloc);
                        defer out.deinit();
                        const sw = compat.listWriter(&out);
                        const hh = std.fmt.bytesToHex(head, .lower);
                        const ph = std.fmt.bytesToHex(rec.prev_hash, .lower);
                        sw.print("{{\"hash\":\"{s}\",\"slot\":{d},\"block_no\":{d},\"height\":{d},\"prev_hash\":\"{s}\"}}\n", .{
                            @as([]const u8, &hh), rec.slot, rec.block_no, rec.height, @as([]const u8, &ph),
                        }) catch {};
                        writeRespBytes(w, 200, "application/json", out.items);
                        return;
                    }
                }
            }
            writeResp(w, 404, "application/json", "{\"error\":\"no head found\"}\n");
            return;
        }

        // Query Layer v2: header lookup by hash from HeaderStore
        if (std.mem.startsWith(u8, path, "/chain/header/")) {
            const hs = g_header_store orelse {
                writeResp(w, 503, "application/json", "{\"error\":\"header store not available\"}\n");
                return;
            };
            const hex_part = path["/chain/header/".len..];
            if (hex_part.len != 64) {
                writeResp(w, 400, "application/json", "{\"error\":\"hash must be 64 hex chars\"}\n");
                return;
            }
            var hash: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&hash, hex_part) catch {
                writeResp(w, 400, "application/json", "{\"error\":\"invalid hex\"}\n");
                return;
            };
            if (hs.beginRead()) |rtxn0| {
                var rtxn = rtxn0;
                defer hs.abort(&rtxn);
                if (hs.getHeader(&rtxn, hash)) |rec| {
                    var out = std.array_list.Managed(u8).init(self.alloc);
                    defer out.deinit();
                    const sw = compat.listWriter(&out);
                    const hh = std.fmt.bytesToHex(hash, .lower);
                    const ph = std.fmt.bytesToHex(rec.prev_hash, .lower);
                    const cbor_len: usize = if (hs.getHeaderCbor(&rtxn, hash)) |cb| cb.len else 0;
                    sw.print("{{\"found\":true,\"hash\":\"{s}\",\"slot\":{d},\"block_no\":{d},\"height\":{d},\"prev_hash\":\"{s}\",\"header_cbor_bytes\":{d}}}\n", .{
                        @as([]const u8, &hh), rec.slot, rec.block_no, rec.height, @as([]const u8, &ph), cbor_len,
                    }) catch {};
                    writeRespBytes(w, 200, "application/json", out.items);
                    return;
                }
            }
            var nf_out = std.array_list.Managed(u8).init(self.alloc);
            defer nf_out.deinit();
            compat.listWriter(&nf_out).print("{{\"found\":false,\"hash\":\"{s}\"}}\n", .{hex_part}) catch {};
            writeRespBytes(w, 404, "application/json", nf_out.items);
            return;
        }

        // Query Layer v3: ancestor traversal from HeaderStore
        if (std.mem.startsWith(u8, path, "/chain/ancestors/")) {
            const hs = g_header_store orelse {
                writeResp(w, 503, "application/json", "{\"error\":\"header store not available\"}\n");
                return;
            };
            const after_prefix = path["/chain/ancestors/".len..];
            // Split hash from query string
            var hex_part: []const u8 = after_prefix;
            var depth: u32 = 10;
            if (std.mem.indexOf(u8, after_prefix, "?")) |qpos| {
                hex_part = after_prefix[0..qpos];
                const qs = after_prefix[qpos + 1 ..];
                if (std.mem.startsWith(u8, qs, "depth=")) {
                    depth = std.fmt.parseInt(u32, qs["depth=".len..], 10) catch 10;
                }
            }
            if (depth > 100) depth = 100;
            if (hex_part.len != 64) {
                writeResp(w, 400, "application/json", "{\"error\":\"hash must be 64 hex chars\"}\n");
                return;
            }
            var start_hash: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&start_hash, hex_part) catch {
                writeResp(w, 400, "application/json", "{\"error\":\"invalid hex\"}\n");
                return;
            };
            if (hs.beginRead()) |rtxn0| {
                var rtxn = rtxn0;
                defer hs.abort(&rtxn);
                // Check starting hash exists
                const first = hs.getHeader(&rtxn, start_hash) orelse {
                    var nf = std.array_list.Managed(u8).init(self.alloc);
                    defer nf.deinit();
                    compat.listWriter(&nf).print("{{\"found\":false,\"start_hash\":\"{s}\"}}\n", .{hex_part}) catch {};
                    writeRespBytes(w, 404, "application/json", nf.items);
                    return;
                };
                // Walk ancestor chain
                var out = std.array_list.Managed(u8).init(self.alloc);
                defer out.deinit();
                const sw = compat.listWriter(&out);
                sw.print("{{\"found\":true,\"start_hash\":\"{s}\",\"depth\":{d},", .{ hex_part, depth }) catch {};
                // Build chain array
                var chain_buf: [101]struct { hash: [32]u8, rec: header_store_mod.HeaderRec } = undefined;
                var count: u32 = 0;
                var cur_hash = start_hash;
                var cur_rec = first;
                var truncated = false;
                var reason: []const u8 = "";
                while (count <= depth) {
                    chain_buf[count] = .{ .hash = cur_hash, .rec = cur_rec };
                    count += 1;
                    if (count > depth) break;
                    // Check for zero prev_hash (genesis)
                    const zero = std.mem.zeroes([32]u8);
                    if (std.mem.eql(u8, &cur_rec.prev_hash, &zero)) {
                        truncated = true;
                        reason = "genesis or zero prev_hash";
                        break;
                    }
                    // Walk to parent
                    if (hs.getHeader(&rtxn, cur_rec.prev_hash)) |parent| {
                        cur_hash = cur_rec.prev_hash;
                        cur_rec = parent;
                    } else {
                        truncated = true;
                        reason = "ancestor not in local header store";
                        break;
                    }
                }
                sw.print("\"count\":{d},\"truncated\":{s},", .{
                    count, if (truncated) "true" else "false",
                }) catch {};
                if (truncated) {
                    sw.print("\"reason\":\"{s}\",", .{reason}) catch {};
                }
                sw.print("\"chain\":[", .{}) catch {};
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    if (i > 0) sw.writeByte(',') catch {};
                    const hh = std.fmt.bytesToHex(chain_buf[i].hash, .lower);
                    const ph = std.fmt.bytesToHex(chain_buf[i].rec.prev_hash, .lower);
                    sw.print("{{\"hash\":\"{s}\",\"slot\":{d},\"block_no\":{d},\"height\":{d},\"prev_hash\":\"{s}\"}}", .{
                        @as([]const u8, &hh), chain_buf[i].rec.slot, chain_buf[i].rec.block_no,
                        chain_buf[i].rec.height, @as([]const u8, &ph),
                    }) catch {};
                }
                sw.print("]}}\n", .{}) catch {};
                writeRespBytes(w, 200, "application/json", out.items);
                return;
            }
            writeResp(w, 503, "application/json", "{\"error\":\"header store read failed\"}\n");
            return;
        }

        // Query Layer v4: slot-based header lookup
        if (std.mem.startsWith(u8, path, "/chain/header-by-slot/")) {
            const hs = g_header_store orelse {
                writeResp(w, 503, "application/json", "{\"error\":\"header store not available\"}\n");
                return;
            };
            const slot_str = path["/chain/header-by-slot/".len..];
            const slot = std.fmt.parseInt(u64, slot_str, 10) catch {
                writeResp(w, 400, "application/json", "{\"error\":\"slot must be a number\"}\n");
                return;
            };
            if (hs.beginRead()) |rtxn0| {
                var rtxn = rtxn0;
                defer hs.abort(&rtxn);
                if (hs.getSlotIndex(&rtxn, slot)) |hash| {
                    if (hs.getHeader(&rtxn, hash)) |rec| {
                        var out = std.array_list.Managed(u8).init(self.alloc);
                        defer out.deinit();
                        const hh = std.fmt.bytesToHex(hash, .lower);
                        const ph = std.fmt.bytesToHex(rec.prev_hash, .lower);
                        compat.listWriter(&out).print("{{\"found\":true,\"slot\":{d},\"hash\":\"{s}\",\"block_no\":{d},\"height\":{d},\"prev_hash\":\"{s}\"}}\n", .{
                            slot, @as([]const u8, &hh), rec.block_no, rec.height, @as([]const u8, &ph),
                        }) catch {};
                        writeRespBytes(w, 200, "application/json", out.items);
                        return;
                    }
                }
            }
            var nf = std.array_list.Managed(u8).init(self.alloc);
            defer nf.deinit();
            compat.listWriter(&nf).print("{{\"found\":false,\"slot\":{d}}}\n", .{slot}) catch {};
            writeRespBytes(w, 404, "application/json", nf.items);
            return;
        }

        // v1.5.11: operator status summary
        if (std.mem.eql(u8, path, "/status")) {
            const m = self.metrics;
            const now_unix = compat.timestamp();
            const st_slot = m.slot.load(.acquire);
            const st_block = m.block_no.load(.acquire);
            const st_hstable = m.header_head_stable.load(.acquire);
            const dw0 = m.producer_state_digest_w0.load(.acquire);
            const dw1 = m.producer_state_digest_w1.load(.acquire);
            const dw2 = m.producer_state_digest_w2.load(.acquire);
            const dw3 = m.producer_state_digest_w3.load(.acquire);
            var out = std.array_list.Managed(u8).init(self.alloc);
            defer out.deinit();
            const sw = compat.listWriter(&out);
            sw.print(
                \\{{"net":"{s}","magic":{d},"relay":"{s}:{d}","genesis_dir":"{s}","slot":{d},"block":{d},"header_stable":{d},"digest":"{x:0>16}{x:0>16}{x:0>16}{x:0>16}","unix":{d}}}
            , .{
                self.profile_net, self.profile_magic,
                self.profile_relay_host, self.profile_relay_port,
                self.profile_genesis_dir,
                st_slot, st_block, st_hstable,
                dw0, dw1, dw2, dw3,
                now_unix,
            }) catch {};
            sw.print("\n", .{}) catch {};
            writeRespBytes(w, 200, "application/json", out.items);
            return;
        }

        if (std.mem.eql(u8, path, "/mempool")) {
            const mp_ptr = self.mempool orelse {
                writeResp(w, 503, "application/json",
                    \\{"ok":false,"error":"mempool not available"}
                );
                return;
            };
            var resp_list = std.array_list.Managed(u8).init(self.alloc);
            defer resp_list.deinit();
            const rw = compat.listWriter(&resp_list);
            rw.print(
                \\{{"items":{d},"bytes":{d},"top":[
            , .{ mp_ptr.count(), mp_ptr.totalBytes() }) catch {};
            const limit = @min(mp_ptr.items.items.len, 5);
            for (mp_ptr.items.items[0..limit], 0..) |item, idx| {
                if (idx > 0) rw.print(",", .{}) catch {};
                const hash_hex = mempool_mod.Mempool.fmtHash(&item.hash);
                rw.print("\"{s}\"", .{hash_hex[0..16]}) catch {};
            }
            rw.print("]}}", .{}) catch {};
            writeRespBytes(w, 200, "application/json", resp_list.items);
            return;
        }

        // Phase 8.55: on-demand leader schedule with configurable window + limit.
        // /schedule?hours=12&limit=32 — reads cache populated by leader_schedule thread.
        if (std.mem.startsWith(u8, path, "/schedule")) {
            // Parse hours + limit from query string.
            var hours: u32 = 12;
            var limit: u32 = 32;
            if (std.mem.indexOfScalar(u8, path, '?')) |qi| {
                var pit = std.mem.splitScalar(u8, path[qi + 1 ..], '&');
                while (pit.next()) |kv| {
                    if (std.mem.startsWith(u8, kv, "hours=")) {
                        hours = std.fmt.parseUnsigned(u32, kv[6..], 10) catch 12;
                    } else if (std.mem.startsWith(u8, kv, "limit=")) {
                        limit = std.fmt.parseUnsigned(u32, kv[6..], 10) catch 32;
                    }
                }
            }
            hours = @min(@max(hours, 1), 48);
            limit = @min(@max(limit, 1), 100);
            std.debug.print("SCHEDULE_REQUEST: hours={d} limit={d}\n", .{ hours, limit });
            var sbuf: [4096]u8 = undefined;
            const slen = leader_schedule.renderScheduleApi(&sbuf, hours, limit);
            // Quick scan of bytes to count how many entries we returned
            var result_count: u32 = 0;
            const body = sbuf[0..slen];
            if (std.mem.indexOf(u8, body, "\"count\":")) |ci| {
                const rc_start = ci + 8;
                var rc_end = rc_start;
                while (rc_end < body.len and body[rc_end] >= '0' and body[rc_end] <= '9') rc_end += 1;
                if (rc_end > rc_start) result_count = std.fmt.parseUnsigned(u32, body[rc_start..rc_end], 10) catch 0;
            }
            std.debug.print("SCHEDULE_RESULT: found={d} hours={d} limit={d} bytes={d}\n", .{ result_count, hours, limit, slen });
            writeRespBytes(w, 200, "application/json", body);
            return;
        }

        if (std.mem.eql(u8, path, "/status/full") or std.mem.eql(u8, path, "/node")) {
            // Structured fallback, always valid JSON with .meta + minimal .schedule.
            const STATUS_VERSION = "phase_meta_v1";
            const Fallbacks = struct {
                fn send(w_: anytype, reason: []const u8) void {
                    const now = compat.timestamp();
                    const pstart = @atomicLoad(i64, &g_process_start_unix, .seq_cst);
                    const uptime: i64 = if (pstart == 0 or now < pstart) 0 else now - pstart;
                    var buf: [512]u8 = undefined;
                    const s = std.fmt.bufPrint(
                        &buf,
                        "{{\"meta\":{{\"ready\":false,\"truncated\":true,\"reason\":\"{s}\",\"version\":\"phase_meta_v1\",\"uptime_unix\":{d},\"now_unix\":{d}}}," ++
                            "\"schedule\":{{\"count\":0,\"next_slot\":0,\"eta_sec\":0,\"confidence\":\"none\",\"leaders\":[]}}}}",
                        .{ reason, uptime, now },
                    ) catch {
                        const hard =
                            "{\"meta\":{\"ready\":false,\"truncated\":true,\"reason\":\"fatal\",\"version\":\"phase_meta_v1\",\"uptime_unix\":0,\"now_unix\":0}," ++
                            "\"schedule\":{\"count\":0,\"next_slot\":0,\"eta_sec\":0,\"confidence\":\"none\",\"leaders\":[]}}";
                        writeRespBytes(w_, 200, "application/json", hard);
                        return;
                    };
                    writeRespBytes(w_, 200, "application/json", s);
                }
            };

            // Merge node_state + leader_schedule + adaptive + peers + decision.
            var state_buf: [1536]u8 = undefined;
            const state_json = node_state.renderJson(&state_buf) catch {
                Fallbacks.send(w, "node_state_render_failed");
                return;
            };
            if (state_json.len < 2 or state_json[state_json.len - 1] != '}') {
                Fallbacks.send(w, "node_state_malformed");
                return;
            }
            // STATUS_SLOT — emit the live slot the status surface is about
            // to serialize. One-curl verification that PARENT_SOURCE_UPDATE
            // → node_state.updateLiveTip → /status/full wiring is intact.
            // Snapshot under the same mutex as renderJson to avoid tearing.
            {
                node_state.g_node_state.mu.lock();
                const status_slot_snap = node_state.g_node_state.slot;
                node_state.g_node_state.mu.unlock();
                std.debug.print("STATUS_SLOT: slot={d}\n", .{status_slot_snap});
            }
            var sched_buf: [2048]u8 = undefined;
            const sched_len = leader_schedule.renderJson(&sched_buf);
            var adapt_buf: [512]u8 = undefined;
            const adapt_len = adaptive_eng.renderJson(&adapt_buf);
            var peers_buf: [2048]u8 = undefined;
            const peers_len = peer_score.renderJson(&peers_buf);
            var dec_buf: [512]u8 = undefined;
            const dec_len = decision_eng.renderJson(&dec_buf);
            var sig_buf: [1024]u8 = undefined;
            const sig_len = signals_mod.renderJson(&sig_buf);
            var proto_buf: [512]u8 = undefined;
            const proto_len = protocol_manager.renderJson(&proto_buf);
            var prearm_buf: [512]u8 = undefined;
            const prearm_len = prearm.renderJson(&prearm_buf);
            var probes_buf: [2048]u8 = undefined;
            const probes_len = multi_probe.renderProbesJson(&probes_buf);
            var timing_buf: [512]u8 = undefined;
            const timing_len = forge_delay.renderJson(&timing_buf);
            var advisory_buf: [512]u8 = undefined;
            const advisory_len = skip_advisory.renderJson(&advisory_buf);
            var propagation_buf: [512]u8 = undefined;
            const propagation_len = propagation_opt.renderJson(&propagation_buf);
            var alerts_buf: [512]u8 = undefined;
            const alerts_len = alerts.renderJson(&alerts_buf);
            var feedback_buf: [512]u8 = undefined;
            const feedback_len = feedback.renderJson(&feedback_buf);
            var announce_buf: [512]u8 = undefined;
            const announce_len = announce.renderJson(&announce_buf);
            var autotune_buf: [512]u8 = undefined;
            const autotune_len = autotune.renderJson(&autotune_buf);
            var presence_buf: [512]u8 = undefined;
            const presence_len = presence.renderJson(&presence_buf);
            var stake_snapshot_buf: [768]u8 = undefined;
            const stake_snapshot_len = stake_snapshot.renderJson(&stake_snapshot_buf);
            var sign_log_buf: [256]u8 = undefined;
            const sign_log_len = sign_log.renderJson(&sign_log_buf);
            var forge_stats_buf: [384]u8 = undefined;
            const forge_stats_len = forge_stats.renderJson(&forge_stats_buf);
            var kes_alerts_buf: [256]u8 = undefined;
            const kes_alerts_len = kes_alerts.renderJson(&kes_alerts_buf);
            var pool_stats_buf: [384]u8 = undefined;
            const pool_stats_len = pool_stats.renderJson(&pool_stats_buf);
            var connections_buf: [2048]u8 = undefined;
            const connections_len = connection_registry.renderJson(&connections_buf);

            // Self-footprint snapshot (cpu/mem/disk). Sampled once per
            // /status/full request; failures degrade to zero/default values.
            const tsunagi_home = compat.getenv("TSUNAGI_HOME");
            _ = resources.sampleResources(tsunagi_home);
            var resources_buf: [192]u8 = undefined;
            const resources_len = resources.renderJson(&resources_buf);

            // Phase 10.2 — per-peer bias scores (uses presence.avg_notice_ms).
            var peer_bias_buf: [2048]u8 = undefined;
            const notice_ms_global: u32 = blk: {
                presence.g_state.mu.lock();
                defer presence.g_state.mu.unlock();
                break :blk presence.g_state.avg_notice_ms;
            };
            const peer_bias_len = multi_probe.renderBiasJson(&peer_bias_buf, notice_ms_global);
            var slot_filter_buf: [512]u8 = undefined;
            const slot_filter_len = slot_filter_mod.renderJson(&slot_filter_buf);
            var execution_buf: [512]u8 = undefined;
            const execution_len = execution_score.renderJson(&execution_buf);

            // 64 KiB — empirical headroom for ~30 top-level keys + rolling samples.
            var out: [65536]u8 = undefined;
            var n: usize = 0;
            var overflow: bool = false;

            const append_bounded = struct {
                fn f(dst: []u8, pos: *usize, over: *bool, prefix: []const u8, body: []const u8) void {
                    if (over.*) return;
                    const need = prefix.len + body.len;
                    if (pos.* + need > dst.len) {
                        over.* = true;
                        return;
                    }
                    @memcpy(dst[pos.* .. pos.* + prefix.len], prefix);
                    pos.* += prefix.len;
                    @memcpy(dst[pos.* .. pos.* + body.len], body);
                    pos.* += body.len;
                }
            };

            // STRICT READY RULE (Golden Ticket §1): last_scan_unix != 0 AND
            // range_end > range_start. A scan can be "triggered" but still
            // have an empty range during the first few ticks; we only report
            // ready once the schedule range is meaningful.
            const ready: bool = blk: {
                const s = &leader_schedule.g_schedule;
                break :blk s.last_scan_unix != 0 and s.scan_range_end > s.scan_range_start;
            };

            // Uptime + now — captured together so the pair is consistent.
            const now_unix: i64 = compat.timestamp();
            const uptime_unix: i64 = blk: {
                const pstart = @atomicLoad(i64, &g_process_start_unix, .seq_cst);
                break :blk if (pstart == 0 or now_unix < pstart) 0 else now_unix - pstart;
            };

            // meta is ALWAYS the first key. Initial assumes !truncated; we
            // never patch it — if overflow happens later we drop the whole
            // compose and emit a structured fallback via Fallbacks.send().
            var meta_buf: [320]u8 = undefined;
            const meta_initial = std.fmt.bufPrint(
                &meta_buf,
                "{{\"meta\":{{\"ready\":{s},\"truncated\":false,\"reason\":\"{s}\",\"version\":\"{s}\",\"uptime_unix\":{d},\"now_unix\":{d}}}",
                .{
                    if (ready) "true" else "false",
                    if (ready) "" else "initializing",
                    STATUS_VERSION,
                    uptime_unix,
                    now_unix,
                },
            ) catch {
                Fallbacks.send(w, "meta_fmt_fail");
                return;
            };
            if (meta_initial.len > out.len) {
                Fallbacks.send(w, "meta_too_large");
                return;
            }
            @memcpy(out[0..meta_initial.len], meta_initial);
            n = meta_initial.len;

            // Splice in node_state fields (strip leading '{' and trailing '}')
            // as additional top-level fields of the outer object.
            if (!overflow and state_json.len >= 2) {
                const inner = state_json[1 .. state_json.len - 1];
                if (inner.len > 0) {
                    if (n + 1 + inner.len > out.len) {
                        overflow = true;
                    } else {
                        out[n] = ',';
                        n += 1;
                        @memcpy(out[n .. n + inner.len], inner);
                        n += inner.len;
                    }
                }
            }

            append_bounded.f(&out, &n, &overflow, ",\"schedule\":", sched_buf[0..sched_len]);
            append_bounded.f(&out, &n, &overflow, ",\"adaptive\":", adapt_buf[0..adapt_len]);
            append_bounded.f(&out, &n, &overflow, ",\"peers\":", peers_buf[0..peers_len]);
            append_bounded.f(&out, &n, &overflow, ",\"decision\":", dec_buf[0..dec_len]);
            append_bounded.f(&out, &n, &overflow, ",\"signals\":", sig_buf[0..sig_len]);
            append_bounded.f(&out, &n, &overflow, ",\"protocol\":", proto_buf[0..proto_len]);
            append_bounded.f(&out, &n, &overflow, ",\"prearm\":", prearm_buf[0..prearm_len]);
            append_bounded.f(&out, &n, &overflow, ",\"probes\":", probes_buf[0..probes_len]);
            append_bounded.f(&out, &n, &overflow, ",\"timing\":", timing_buf[0..timing_len]);
            append_bounded.f(&out, &n, &overflow, ",\"advisory\":", advisory_buf[0..advisory_len]);
            append_bounded.f(&out, &n, &overflow, ",\"propagation\":", propagation_buf[0..propagation_len]);
            append_bounded.f(&out, &n, &overflow, ",\"alerts\":", alerts_buf[0..alerts_len]);
            append_bounded.f(&out, &n, &overflow, ",\"feedback\":", feedback_buf[0..feedback_len]);
            append_bounded.f(&out, &n, &overflow, ",\"announce\":", announce_buf[0..announce_len]);
            append_bounded.f(&out, &n, &overflow, ",\"autotune\":", autotune_buf[0..autotune_len]);
            append_bounded.f(&out, &n, &overflow, ",\"presence\":", presence_buf[0..presence_len]);
            append_bounded.f(&out, &n, &overflow, ",\"peer_bias\":", peer_bias_buf[0..peer_bias_len]);
            append_bounded.f(&out, &n, &overflow, ",\"slot_filter\":", slot_filter_buf[0..slot_filter_len]);
            append_bounded.f(&out, &n, &overflow, ",\"execution\":", execution_buf[0..execution_len]);
            append_bounded.f(&out, &n, &overflow, ",\"stake_snapshot\":", stake_snapshot_buf[0..stake_snapshot_len]);
            append_bounded.f(&out, &n, &overflow, ",\"sign_log\":", sign_log_buf[0..sign_log_len]);
            append_bounded.f(&out, &n, &overflow, ",\"forge_stats\":", forge_stats_buf[0..forge_stats_len]);
            append_bounded.f(&out, &n, &overflow, ",\"kes_alerts\":", kes_alerts_buf[0..kes_alerts_len]);
            append_bounded.f(&out, &n, &overflow, ",\"pool_stats\":", pool_stats_buf[0..pool_stats_len]);
            append_bounded.f(&out, &n, &overflow, ",\"connections\":", connections_buf[0..connections_len]);
            append_bounded.f(&out, &n, &overflow, ",\"resources\":", resources_buf[0..resources_len]);
            if (!overflow and n + 1 <= out.len) {
                out[n] = '}';
                n += 1;
            } else {
                overflow = true;
            }

            // STATUS_SECTIONS — per-section size accounting for future
            // overflow debugging. Logged on every hit; cheap (no allocations).
            std.debug.print("STATUS_SECTIONS: node={d} schedule={d} adaptive={d} peers={d} decision={d} signals={d} protocol={d} prearm={d} probes={d} timing={d} advisory={d} propagation={d} alerts={d} feedback={d} announce={d} autotune={d} presence={d} peer_bias={d} slot_filter={d} execution={d}\n", .{
                state_json.len, sched_len, adapt_len, peers_len, dec_len,
                sig_len, proto_len, prearm_len, probes_len, timing_len,
                advisory_len, propagation_len, alerts_len, feedback_len,
                announce_len, autotune_len, presence_len, peer_bias_len,
                slot_filter_len, execution_len,
            });

            // STATUS_EMIT — final shape with ready + overflow for operator visibility.
            // STATUS_SECTION_COUNT is the static number of top-level keys composed
            // above (meta + 24 sibling sections); update both together.
            const STATUS_SECTION_COUNT: usize = 25;
            std.debug.print("STATUS_EMIT: schedule_count={d} sched_len={d} body_len={d} overflow={s} ready={s}\n", .{
                leader_schedule.g_schedule.count, sched_len, n,
                if (overflow) "true" else "false",
                if (ready) "true" else "false",
            });
            std.debug.print("STATUS_EMIT: bytes={d} overflow={s} sections={d}\n", .{
                n,
                if (overflow) "true" else "false",
                STATUS_SECTION_COUNT,
            });

            if (overflow) {
                // Discard the partial body — it is a truncated mid-string
                // and would parse as invalid JSON.  Emit a minimal valid
                // document instead so jq still parses cleanly and the
                // meta.ready=false / meta.truncated=true contract holds.
                var fb_buf: [256]u8 = undefined;
                const fb = status_fallback.format(&fb_buf, n, out.len, now_unix) catch {
                    Fallbacks.send(w, "compose_overflow");
                    return;
                };
                std.debug.print("STATUS_FALLBACK: orig_bytes={d} buf={d} reason=overflow\n", .{ n, out.len });
                writeRespBytes(w, 200, "application/json", fb);
                return;
            }
            writeRespBytes(w, 200, "application/json", out[0..n]);
            return;
        }

        if (std.mem.eql(u8, path, "/metrics")) {
            // Load backfill stats from bridge file (throttled to every 10s)
            self.maybeLoadBackfillStats();
            self.maybeLoadCaptureStats();

            var out = std.array_list.Managed(u8).init(self.alloc);
            defer out.deinit();

            // Prometheus text exposition format (simple gauges/counters)
            // Use monotonic atomics.
            const wr = compat.listWriter(&out);

            // Meta: metrics server health
            wr.print(
                \\# HELP tsunagi_metrics_up Metrics server is listening (0/1)
                \\# TYPE tsunagi_metrics_up gauge
                \\tsunagi_metrics_up {d}
                \\# HELP tsunagi_metrics_bind_fail_total Metrics bind failure count
                \\# TYPE tsunagi_metrics_bind_fail_total counter
                \\tsunagi_metrics_bind_fail_total {d}
                \\# HELP tsunagi_metrics_last_bind_fail_unix Last bind failure unix timestamp
                \\# TYPE tsunagi_metrics_last_bind_fail_unix gauge
                \\tsunagi_metrics_last_bind_fail_unix {d}
                \\# HELP tsunagi_metrics_bind_retry_last Bind attempt used on last successful start (0=first try)
                \\# TYPE tsunagi_metrics_bind_retry_last gauge
                \\tsunagi_metrics_bind_retry_last {d}
                \\
            , .{
                self.metrics.metrics_up.load(.acquire),
                self.metrics.metrics_bind_fail_total.load(.acquire),
                self.metrics.metrics_last_bind_fail_unix.load(.acquire),
                self.metrics.metrics_bind_retry_last.load(.acquire),
            }) catch {};

            wr.print(
                \\# HELP tsunagi_metrics_started Metrics server started successfully (0/1)
                \\# TYPE tsunagi_metrics_started gauge
                \\tsunagi_metrics_started {d}
                \\# HELP tsunagi_metrics_start_attempt_total Cumulative metrics start attempts
                \\# TYPE tsunagi_metrics_start_attempt_total counter
                \\tsunagi_metrics_start_attempt_total {d}
                \\# HELP tsunagi_metrics_start_success_total Cumulative metrics start successes
                \\# TYPE tsunagi_metrics_start_success_total counter
                \\tsunagi_metrics_start_success_total {d}
                \\# HELP tsunagi_metrics_start_address_in_use_total Cumulative AddressInUse failures
                \\# TYPE tsunagi_metrics_start_address_in_use_total counter
                \\tsunagi_metrics_start_address_in_use_total {d}
                \\# HELP tsunagi_metrics_next_retry_unix Next retry unix timestamp (0=none)
                \\# TYPE tsunagi_metrics_next_retry_unix gauge
                \\tsunagi_metrics_next_retry_unix {d}
                \\
            , .{
                self.metrics.metrics_started.load(.acquire),
                self.metrics.metrics_start_attempt_total.load(.acquire),
                self.metrics.metrics_start_success_total.load(.acquire),
                self.metrics.metrics_start_address_in_use_total.load(.acquire),
                self.metrics.metrics_next_retry_unix.load(.acquire),
            }) catch {};

            const slot = self.metrics.slot.load(.acquire);
            const block_no = self.metrics.block_no.load(.acquire);
            const utxo = self.metrics.utxo.load(.acquire);
            const rf = self.metrics.roll_fwd.load(.acquire);
            const rb = self.metrics.roll_back.load(.acquire);
            const pc = self.metrics.peer_closed.load(.acquire);
            const ltb = self.metrics.lmdb_truth_blocks.load(.acquire);
            const lfb = self.metrics.lmdb_fallback_blocks.load(.acquire);
            const denom = ltb + lfb;
            const ratio: f64 = if (denom == 0) 0.0 else @as(f64, @floatFromInt(ltb)) / @as(f64, @floatFromInt(denom));
            const ctl = self.metrics.cbor_toolarge.load(.acquire);
            const ceof = self.metrics.cbor_eof.load(.acquire);
            const coth = self.metrics.cbor_other.load(.acquire);

            // Keep output stable + short.
            wr.print(
                \\# HELP tsunagi_slot Current chain slot
                \\# TYPE tsunagi_slot gauge
                \\tsunagi_slot {d}
                \\# HELP tsunagi_block Current block number
                \\# TYPE tsunagi_block gauge
                \\tsunagi_block {d}
                \\# HELP tsunagi_utxo_count UTxO set size
                \\# TYPE tsunagi_utxo_count gauge
                \\tsunagi_utxo_count {d}
                \\# HELP tsunagi_roll_forward_total Roll-forward events
                \\# TYPE tsunagi_roll_forward_total counter
                \\tsunagi_roll_forward_total {d}
                \\# HELP tsunagi_roll_backward_total Roll-back events
                \\# TYPE tsunagi_roll_backward_total counter
                \\tsunagi_roll_backward_total {d}
                \\# HELP tsunagi_peer_closed_total Peer disconnect events
                \\# TYPE tsunagi_peer_closed_total counter
                \\tsunagi_peer_closed_total {d}
                \\# HELP tsunagi_lmdb_truth_blocks_total Blocks applied via LMDB truth path
                \\# TYPE tsunagi_lmdb_truth_blocks_total counter
                \\tsunagi_lmdb_truth_blocks_total {d}
                \\# HELP tsunagi_lmdb_fallback_blocks_total Blocks applied via fallback path
                \\# TYPE tsunagi_lmdb_fallback_blocks_total counter
                \\tsunagi_lmdb_fallback_blocks_total {d}
                \\# HELP tsunagi_lmdb_truth_ratio LMDB truth path ratio (truth / (truth+fallback))
                \\# TYPE tsunagi_lmdb_truth_ratio gauge
                \\tsunagi_lmdb_truth_ratio {d:.6}
                \\# HELP tsunagi_cbor_toolarge_total CBOR decode skipped (payload too large)
                \\# TYPE tsunagi_cbor_toolarge_total counter
                \\tsunagi_cbor_toolarge_total {d}
                \\# HELP tsunagi_cbor_endofstream_total CBOR decode failed (end of stream)
                \\# TYPE tsunagi_cbor_endofstream_total counter
                \\tsunagi_cbor_endofstream_total {d}
                \\# HELP tsunagi_cbor_other_total CBOR decode failed (other errors)
                \\# TYPE tsunagi_cbor_other_total counter
                \\tsunagi_cbor_other_total {d}
                \\
            , .{ slot, block_no, utxo, rf, rb, pc, ltb, lfb, ratio, ctl, ceof, coth }) catch {
                writeResp(w, 500, "text/plain; charset=utf-8", "metrics build failed\n");
                return;
            };

            // Bayesian peer scoring metrics (per-index)
            wr.print(
                \\# HELP tsunagi_peer_alpha Bayesian alpha (success) for peer
                \\# TYPE tsunagi_peer_alpha gauge
                \\
            , .{}) catch {};
            for (0..PEER_SLOTS) |i| {
                const a = self.metrics.peer_alpha[i].load(.acquire);
                wr.print("tsunagi_peer_alpha{{index=\"{d}\"}} {d}.{d:0>3}\n", .{ i, a / 1000, a % 1000 }) catch {};
            }
            wr.print(
                \\# HELP tsunagi_peer_beta Bayesian beta (failure) for peer
                \\# TYPE tsunagi_peer_beta gauge
                \\
            , .{}) catch {};
            for (0..PEER_SLOTS) |i| {
                const b = self.metrics.peer_beta[i].load(.acquire);
                wr.print("tsunagi_peer_beta{{index=\"{d}\"}} {d}.{d:0>3}\n", .{ i, b / 1000, b % 1000 }) catch {};
            }
            wr.print(
                \\# HELP tsunagi_peer_score_sample Latest Thompson sample for peer
                \\# TYPE tsunagi_peer_score_sample gauge
                \\
            , .{}) catch {};
            for (0..PEER_SLOTS) |i| {
                const s = self.metrics.peer_sample[i].load(.acquire);
                wr.print("tsunagi_peer_score_sample{{index=\"{d}\"}} {d}.{d:0>3}\n", .{ i, s / 1000, s % 1000 }) catch {};
            }
            wr.print(
                \\# HELP tsunagi_peer_selected_total Times peer was selected
                \\# TYPE tsunagi_peer_selected_total counter
                \\
            , .{}) catch {};
            for (0..PEER_SLOTS) |i| {
                const sc = self.metrics.peer_selected[i].load(.acquire);
                wr.print("tsunagi_peer_selected_total{{index=\"{d}\"}} {d}\n", .{ i, sc }) catch {};
            }

            // Bayes v2: performance nudge counters
            wr.print(
                \\# HELP tsunagi_peer_perf_reward_total Performance-based reward events per peer
                \\# TYPE tsunagi_peer_perf_reward_total counter
                \\
            , .{}) catch {};
            for (0..PEER_SLOTS) |i| {
                const pr = self.metrics.peer_perf_reward[i].load(.acquire);
                wr.print("tsunagi_peer_perf_reward_total{{index=\"{d}\"}} {d}\n", .{ i, pr }) catch {};
            }
            wr.print(
                \\# HELP tsunagi_peer_perf_penalty_total Performance-based penalty events per peer
                \\# TYPE tsunagi_peer_perf_penalty_total counter
                \\
            , .{}) catch {};
            for (0..PEER_SLOTS) |i| {
                const pp = self.metrics.peer_perf_penalty[i].load(.acquire);
                wr.print("tsunagi_peer_perf_penalty_total{{index=\"{d}\"}} {d}\n", .{ i, pp }) catch {};
            }

            // Performance telemetry (latest values in ms)
            wr.print(
                \\# HELP tsunagi_perf_blockfetch_decode_ms BlockFetch CBOR decode time (ms)
                \\# TYPE tsunagi_perf_blockfetch_decode_ms gauge
                \\tsunagi_perf_blockfetch_decode_ms {d}
                \\# HELP tsunagi_perf_tx_extract_ms Tx extraction + delta computation time (ms)
                \\# TYPE tsunagi_perf_tx_extract_ms gauge
                \\tsunagi_perf_tx_extract_ms {d}
                \\# HELP tsunagi_perf_lmdb_write_ms LMDB write transaction time (ms)
                \\# TYPE tsunagi_perf_lmdb_write_ms gauge
                \\tsunagi_perf_lmdb_write_ms {d}
                \\# HELP tsunagi_perf_block_total_ms End-to-end block processing time (ms)
                \\# TYPE tsunagi_perf_block_total_ms gauge
                \\tsunagi_perf_block_total_ms {d}
                \\# HELP tsunagi_perf_reconnect_ms Last reconnect duration (ms)
                \\# TYPE tsunagi_perf_reconnect_ms gauge
                \\tsunagi_perf_reconnect_ms {d}
                \\
            , .{
                self.metrics.perf_blockfetch_decode_ms.load(.acquire),
                self.metrics.perf_tx_extract_ms.load(.acquire),
                self.metrics.perf_lmdb_write_ms.load(.acquire),
                self.metrics.perf_block_total_ms.load(.acquire),
                self.metrics.perf_reconnect_ms.load(.acquire),
            }) catch {};

            // PRIMARY FOLLOWER OBSERVABILITY (fix/primary-follower-observability)
            // OBSERVABILITY-ONLY counters — no decision path consumes these.
            wr.print(
                \\# HELP tsunagi_primary_rollforwards_processed_total Primary follower RollForward messages processed
                \\# TYPE tsunagi_primary_rollforwards_processed_total counter
                \\tsunagi_primary_rollforwards_processed_total {d}
                \\# HELP tsunagi_primary_recv_timeouts_total Primary follower recv timeouts (silent loop counter)
                \\# TYPE tsunagi_primary_recv_timeouts_total counter
                \\tsunagi_primary_recv_timeouts_total {d}
                \\# HELP tsunagi_primary_intersect_found_total Primary follower IntersectFound responses received
                \\# TYPE tsunagi_primary_intersect_found_total counter
                \\tsunagi_primary_intersect_found_total {d}
                \\# HELP tsunagi_primary_intersect_not_found_total Primary follower IntersectNotFound responses received
                \\# TYPE tsunagi_primary_intersect_not_found_total counter
                \\tsunagi_primary_intersect_not_found_total {d}
                \\# HELP tsunagi_primary_tip_promotions_total Primary follower tip_block_last writes (any non-zero promotion)
                \\# TYPE tsunagi_primary_tip_promotions_total counter
                \\tsunagi_primary_tip_promotions_total {d}
                \\# HELP tsunagi_primary_tip_parse_null_total getTipSlotBlock returned null (tip envelope shape mismatch)
                \\# TYPE tsunagi_primary_tip_parse_null_total counter
                \\tsunagi_primary_tip_parse_null_total {d}
                \\# HELP tsunagi_primary_intersect_recovery_origin_total Primary follower in-connection origin fallbacks after multi-point IntersectNotFound
                \\# TYPE tsunagi_primary_intersect_recovery_origin_total counter
                \\tsunagi_primary_intersect_recovery_origin_total {d}
                \\
            , .{
                self.metrics.primary_rollforwards_processed_total.load(.acquire),
                self.metrics.primary_recv_timeouts_total.load(.acquire),
                self.metrics.primary_intersect_found_total.load(.acquire),
                self.metrics.primary_intersect_not_found_total.load(.acquire),
                self.metrics.primary_tip_promotions_total.load(.acquire),
                self.metrics.primary_tip_parse_null_total.load(.acquire),
                self.metrics.primary_intersect_recovery_origin_total.load(.acquire),
            }) catch {};

            // Performance telemetry (microsecond resolution)
            wr.print(
                \\# HELP tsunagi_perf_blockfetch_decode_us BlockFetch CBOR decode time (us)
                \\# TYPE tsunagi_perf_blockfetch_decode_us gauge
                \\tsunagi_perf_blockfetch_decode_us {d}
                \\# HELP tsunagi_perf_tx_extract_us Tx extraction + delta computation time (us)
                \\# TYPE tsunagi_perf_tx_extract_us gauge
                \\tsunagi_perf_tx_extract_us {d}
                \\# HELP tsunagi_perf_lmdb_write_us LMDB write transaction time (us)
                \\# TYPE tsunagi_perf_lmdb_write_us gauge
                \\tsunagi_perf_lmdb_write_us {d}
                \\# HELP tsunagi_perf_block_total_us End-to-end block processing time (us)
                \\# TYPE tsunagi_perf_block_total_us gauge
                \\tsunagi_perf_block_total_us {d}
                \\# HELP tsunagi_perf_reconnect_us Last reconnect duration (us)
                \\# TYPE tsunagi_perf_reconnect_us gauge
                \\tsunagi_perf_reconnect_us {d}
                \\
            , .{
                self.metrics.perf_blockfetch_decode_us.load(.acquire),
                self.metrics.perf_tx_extract_us.load(.acquire),
                self.metrics.perf_lmdb_write_us.load(.acquire),
                self.metrics.perf_block_total_us.load(.acquire),
                self.metrics.perf_reconnect_us.load(.acquire),
            }) catch {};

            // Header chain authority
            wr.print(
                \\# HELP tsunagi_header_height Header chain stored height
                \\# TYPE tsunagi_header_height gauge
                \\tsunagi_header_height {d}
                \\# HELP tsunagi_header_store_writes_total Header records written
                \\# TYPE tsunagi_header_store_writes_total counter
                \\tsunagi_header_store_writes_total {d}
                \\# HELP tsunagi_header_chain_errors_total Header prev_hash linkage mismatches
                \\# TYPE tsunagi_header_chain_errors_total counter
                \\tsunagi_header_chain_errors_total {d}
                \\# HELP tsunagi_header_prevhash_missing_total Headers with unparseable prev_hash
                \\# TYPE tsunagi_header_prevhash_missing_total counter
                \\tsunagi_header_prevhash_missing_total {d}
                \\# HELP tsunagi_header_reconnects_due_to_mismatch_total Reconnects triggered by header mismatch streak
                \\# TYPE tsunagi_header_reconnects_due_to_mismatch_total counter
                \\tsunagi_header_reconnects_due_to_mismatch_total {d}
                \\# HELP tsunagi_header_head_stable Header chain linkage stabilized (0/1)
                \\# TYPE tsunagi_header_head_stable gauge
                \\tsunagi_header_head_stable {d}
                \\
            , .{
                self.metrics.header_height.load(.acquire),
                self.metrics.header_store_writes.load(.acquire),
                self.metrics.header_chain_errors.load(.acquire),
                self.metrics.header_prevhash_missing.load(.acquire),
                self.metrics.header_mismatch_reconnects.load(.acquire),
                self.metrics.header_head_stable.load(.acquire),
            }) catch {};

            // Phase B'''' telemetry: peer-tip gauges + override + parse-refused counters.
            wr.print(
                \\# HELP tsunagi_peer_tip_slot Peer-observed authoritative tip slot
                \\# TYPE tsunagi_peer_tip_slot gauge
                \\tsunagi_peer_tip_slot {d}
                \\# HELP tsunagi_peer_tip_block_no Peer-observed authoritative tip block_no
                \\# TYPE tsunagi_peer_tip_block_no gauge
                \\tsunagi_peer_tip_block_no {d}
                \\# HELP tsunagi_forge_canonical_override_total Case-B canonical override fires
                \\# TYPE tsunagi_forge_canonical_override_total counter
                \\tsunagi_forge_canonical_override_total {d}
                \\# HELP tsunagi_header_parse_refused_total Delivered headers refused at write due to parse failure
                \\# TYPE tsunagi_header_parse_refused_total counter
                \\tsunagi_header_parse_refused_total {d}
                \\
            , .{
                self.metrics.peer_tip_slot.load(.acquire),
                self.metrics.peer_tip_block_no.load(.acquire),
                g_forge_canonical_override_total.load(.acquire),
                self.metrics.tsunagi_header_parse_refused_total.load(.acquire),
            }) catch {};

            // Rollback flap guard
            {
                const avg_x1000 = self.metrics.rollback_window_avg_depth_x1000.load(.acquire);
                const avg_int = avg_x1000 / 1000;
                const avg_frac = avg_x1000 % 1000;
                wr.print(
                    \\# HELP tsunagi_rollback_window_count_last Rollbacks in current flap window
                    \\# TYPE tsunagi_rollback_window_count_last gauge
                    \\tsunagi_rollback_window_count_last {d}
                    \\# HELP tsunagi_rollback_window_avg_depth_last Average rollback depth in window
                    \\# TYPE tsunagi_rollback_window_avg_depth_last gauge
                    \\tsunagi_rollback_window_avg_depth_last {d}.{d:0>3}
                    \\# HELP tsunagi_rollback_window_max_depth_last Max rollback depth in window
                    \\# TYPE tsunagi_rollback_window_max_depth_last gauge
                    \\tsunagi_rollback_window_max_depth_last {d}
                    \\# HELP tsunagi_rollback_flap_violation_total Rollback flap violations (oscillation)
                    \\# TYPE tsunagi_rollback_flap_violation_total counter
                    \\tsunagi_rollback_flap_violation_total {d}
                    \\
                , .{
                    self.metrics.rollback_window_count_last.load(.acquire),
                    avg_int,
                    avg_frac,
                    self.metrics.rollback_window_max_depth_last.load(.acquire),
                    self.metrics.rollback_flap_violation_total.load(.acquire),
                }) catch {};
            }

            // Rollback stabilization (v1.5.9)
            wr.print(
                \\# HELP tsunagi_rollback_stabilize_suppressed_total Header mismatches suppressed by stabilization window
                \\# TYPE tsunagi_rollback_stabilize_suppressed_total counter
                \\tsunagi_rollback_stabilize_suppressed_total {d}
                \\# HELP tsunagi_rollback_stabilize_active Rollback stabilization window active (0/1)
                \\# TYPE tsunagi_rollback_stabilize_active gauge
                \\tsunagi_rollback_stabilize_active {d}
                \\
            , .{
                self.metrics.rollback_stabilize_suppressed_total.load(.acquire),
                self.metrics.rollback_stabilize_active.load(.acquire),
            }) catch {};

            // Chain density guard
            {
                const density_x1e6 = self.metrics.chain_density_last_x1e6.load(.acquire);
                const density_int = density_x1e6 / 1_000_000;
                const density_frac = density_x1e6 % 1_000_000;
                wr.print(
                    \\# HELP tsunagi_chain_density_violation_total Sparse-chain density violations
                    \\# TYPE tsunagi_chain_density_violation_total counter
                    \\tsunagi_chain_density_violation_total {d}
                    \\# HELP tsunagi_chain_density_last Chain density (blocks/slot) in last window
                    \\# TYPE tsunagi_chain_density_last gauge
                    \\tsunagi_chain_density_last {d}.{d:0>6}
                    \\# HELP tsunagi_chain_density_window_blocks_last Blocks in last density window
                    \\# TYPE tsunagi_chain_density_window_blocks_last gauge
                    \\tsunagi_chain_density_window_blocks_last {d}
                    \\# HELP tsunagi_chain_density_window_slots_last Slots in last density window
                    \\# TYPE tsunagi_chain_density_window_slots_last gauge
                    \\tsunagi_chain_density_window_slots_last {d}
                    \\
                , .{
                    self.metrics.chain_density_violation_total.load(.acquire),
                    density_int,
                    density_frac,
                    self.metrics.chain_density_window_blocks_last.load(.acquire),
                    self.metrics.chain_density_window_slots_last.load(.acquire),
                }) catch {};

                // Smoothed density + violation streak
                const sm_x1e6 = self.metrics.chain_density_smoothed_last_x1e6.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_chain_density_smoothed_last Smoothed density (avg of last 3 windows)
                    \\# TYPE tsunagi_chain_density_smoothed_last gauge
                    \\tsunagi_chain_density_smoothed_last {d}.{d:0>6}
                    \\# HELP tsunagi_chain_density_violation_streak_last Consecutive density violation count
                    \\# TYPE tsunagi_chain_density_violation_streak_last gauge
                    \\tsunagi_chain_density_violation_streak_last {d}
                    \\
                , .{
                    sm_x1e6 / 1_000_000,
                    sm_x1e6 % 1_000_000,
                    self.metrics.chain_density_violation_streak_last.load(.acquire),
                }) catch {};

                // Density baseline (adaptive)
                const bl_x1e6 = self.metrics.chain_density_baseline_x1e6.load(.acquire);
                const rm_x1e6 = self.metrics.chain_density_recommended_min_x1e6.load(.acquire);
                const rx_x1e6 = self.metrics.chain_density_recommended_max_x1e6.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_chain_density_baseline EMA baseline density (blocks/slot)
                    \\# TYPE tsunagi_chain_density_baseline gauge
                    \\tsunagi_chain_density_baseline {d}.{d:0>6}
                    \\# HELP tsunagi_chain_density_recommended_min Recommended minimum density
                    \\# TYPE tsunagi_chain_density_recommended_min gauge
                    \\tsunagi_chain_density_recommended_min {d}.{d:0>6}
                    \\# HELP tsunagi_chain_density_recommended_max Recommended maximum density
                    \\# TYPE tsunagi_chain_density_recommended_max gauge
                    \\tsunagi_chain_density_recommended_max {d}.{d:0>6}
                    \\# HELP tsunagi_chain_density_baseline_updates_total Baseline update count
                    \\# TYPE tsunagi_chain_density_baseline_updates_total counter
                    \\tsunagi_chain_density_baseline_updates_total {d}
                    \\# HELP tsunagi_chain_density_baseline_last_unix Last baseline update timestamp
                    \\# TYPE tsunagi_chain_density_baseline_last_unix gauge
                    \\tsunagi_chain_density_baseline_last_unix {d}
                    \\
                , .{
                    bl_x1e6 / 1_000_000, bl_x1e6 % 1_000_000,
                    rm_x1e6 / 1_000_000, rm_x1e6 % 1_000_000,
                    rx_x1e6 / 1_000_000, rx_x1e6 % 1_000_000,
                    self.metrics.chain_density_baseline_updates_total.load(.acquire),
                    self.metrics.chain_density_baseline_last_unix.load(.acquire),
                }) catch {};

                // Max-density guard
                const mx_x1e6 = self.metrics.chain_density_max_last_x1e6.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_chain_density_max_last Smoothed density at last max-density check
                    \\# TYPE tsunagi_chain_density_max_last gauge
                    \\tsunagi_chain_density_max_last {d}.{d:0>6}
                    \\# HELP tsunagi_chain_density_max_violation_total Max-density violations detected
                    \\# TYPE tsunagi_chain_density_max_violation_total counter
                    \\tsunagi_chain_density_max_violation_total {d}
                    \\# HELP tsunagi_chain_density_max_strict_disconnect_total Max-density strict disconnects
                    \\# TYPE tsunagi_chain_density_max_strict_disconnect_total counter
                    \\tsunagi_chain_density_max_strict_disconnect_total {d}
                    \\
                , .{
                    mx_x1e6 / 1_000_000, mx_x1e6 % 1_000_000,
                    self.metrics.chain_density_max_violation_total.load(.acquire),
                    self.metrics.chain_density_max_strict_disconnect_total.load(.acquire),
                }) catch {};
            }

            // Consensus clock sanity
            wr.print(
                \\# HELP tsunagi_consensus_clock_violation_total Slot/wall-clock sanity violations
                \\# TYPE tsunagi_consensus_clock_violation_total counter
                \\tsunagi_consensus_clock_violation_total {d}
                \\# HELP tsunagi_consensus_slot_jump_last Last slot jump magnitude
                \\# TYPE tsunagi_consensus_slot_jump_last gauge
                \\tsunagi_consensus_slot_jump_last {d}
                \\# HELP tsunagi_consensus_wall_drift_last Abs slot-vs-wall drift in seconds
                \\# TYPE tsunagi_consensus_wall_drift_last gauge
                \\tsunagi_consensus_wall_drift_last {d}
                \\
            , .{
                self.metrics.consensus_clock_violation_total.load(.acquire),
                self.metrics.consensus_slot_jump_last.load(.acquire),
                self.metrics.consensus_wall_drift_last.load(.acquire),
            }) catch {};

            // Consensus skeleton
            {
                const cq = self.metrics.consensus_chain_quality_x1e6.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_consensus_health_score Consensus health score 0-100
                    \\# TYPE tsunagi_consensus_health_score gauge
                    \\tsunagi_consensus_health_score {d}
                    \\# HELP tsunagi_consensus_tip_fresh_seconds Seconds since last roll-forward
                    \\# TYPE tsunagi_consensus_tip_fresh_seconds gauge
                    \\tsunagi_consensus_tip_fresh_seconds {d}
                    \\# HELP tsunagi_consensus_chain_quality Chain density smoothed
                    \\# TYPE tsunagi_consensus_chain_quality gauge
                    \\tsunagi_consensus_chain_quality {d}.{d:0>6}
                    \\# HELP tsunagi_consensus_header_err_delta_5m Header chain errors in last 5m window
                    \\# TYPE tsunagi_consensus_header_err_delta_5m gauge
                    \\tsunagi_consensus_header_err_delta_5m {d}
                    \\# HELP tsunagi_consensus_keepalive_to_delta_5m Keepalive timeouts in last 5m window
                    \\# TYPE tsunagi_consensus_keepalive_to_delta_5m gauge
                    \\tsunagi_consensus_keepalive_to_delta_5m {d}
                    \\# HELP tsunagi_consensus_rollback_delta_5m Rollbacks in last 5m window
                    \\# TYPE tsunagi_consensus_rollback_delta_5m gauge
                    \\tsunagi_consensus_rollback_delta_5m {d}
                    \\
                , .{
                    self.metrics.consensus_health_score.load(.acquire),
                    self.metrics.consensus_tip_fresh_seconds.load(.acquire),
                    cq / 1_000_000, cq % 1_000_000,
                    self.metrics.consensus_header_err_delta_5m.load(.acquire),
                    self.metrics.consensus_keepalive_to_delta_5m.load(.acquire),
                    self.metrics.consensus_rollback_delta_5m.load(.acquire),
                }) catch {};

                // Stall attribution
                wr.print(
                    \\# HELP tsunagi_consensus_stall_reason_code Stall root cause (0=none 1=ka_dead 2=bf_starved 3=hdr_stalled 4=auth_low 9=unknown)
                    \\# TYPE tsunagi_consensus_stall_reason_code gauge
                    \\tsunagi_consensus_stall_reason_code {d}
                    \\# HELP tsunagi_consensus_stall_age_seconds Seconds since last roll-forward
                    \\# TYPE tsunagi_consensus_stall_age_seconds gauge
                    \\tsunagi_consensus_stall_age_seconds {d}
                    \\# HELP tsunagi_consensus_blockfetch_age_seconds Seconds since last blockfetch batch done
                    \\# TYPE tsunagi_consensus_blockfetch_age_seconds gauge
                    \\tsunagi_consensus_blockfetch_age_seconds {d}
                    \\# HELP tsunagi_consensus_keepalive_age_seconds Seconds since last keepalive pong
                    \\# TYPE tsunagi_consensus_keepalive_age_seconds gauge
                    \\tsunagi_consensus_keepalive_age_seconds {d}
                    \\# HELP tsunagi_consensus_stall_total Cumulative stall transition events
                    \\# TYPE tsunagi_consensus_stall_total counter
                    \\tsunagi_consensus_stall_total {d}
                    \\
                , .{
                    self.metrics.consensus_stall_reason_code.load(.acquire),
                    self.metrics.consensus_stall_age_seconds.load(.acquire),
                    self.metrics.consensus_blockfetch_age_seconds.load(.acquire),
                    self.metrics.consensus_keepalive_age_seconds.load(.acquire),
                    self.metrics.consensus_stall_total.load(.acquire),
                }) catch {};

                // 5-minute deltas (extended)
                wr.print(
                    \\# HELP tsunagi_consensus_window_unix Consensus 5-min window start unix
                    \\# TYPE tsunagi_consensus_window_unix gauge
                    \\tsunagi_consensus_window_unix {d}
                    \\# HELP tsunagi_consensus_blockfetch_batches_delta_5m BlockFetch batch done events in last 5m
                    \\# TYPE tsunagi_consensus_blockfetch_batches_delta_5m gauge
                    \\tsunagi_consensus_blockfetch_batches_delta_5m {d}
                    \\# HELP tsunagi_consensus_keepalive_pongs_delta_5m KeepAlive pongs in last 5m
                    \\# TYPE tsunagi_consensus_keepalive_pongs_delta_5m gauge
                    \\tsunagi_consensus_keepalive_pongs_delta_5m {d}
                    \\# HELP tsunagi_consensus_peer_closed_delta_5m Peer closed events in last 5m
                    \\# TYPE tsunagi_consensus_peer_closed_delta_5m gauge
                    \\tsunagi_consensus_peer_closed_delta_5m {d}
                    \\# HELP tsunagi_consensus_header_store_writes_delta_5m Header store writes in last 5m
                    \\# TYPE tsunagi_consensus_header_store_writes_delta_5m gauge
                    \\tsunagi_consensus_header_store_writes_delta_5m {d}
                    \\
                , .{
                    self.metrics.consensus_window_unix.load(.acquire),
                    self.metrics.consensus_blockfetch_batches_delta_5m.load(.acquire),
                    self.metrics.consensus_keepalive_pongs_delta_5m.load(.acquire),
                    self.metrics.consensus_peer_closed_delta_5m.load(.acquire),
                    self.metrics.consensus_header_store_writes_delta_5m.load(.acquire),
                }) catch {};
            }

            // Authority confidence model
            {
                const ac = self.metrics.authority_confidence_x1e6.load(.acquire);
                const af = self.metrics.authority_finality_score_x1e6.load(.acquire);
                const ar = self.metrics.authority_reorg_depth_last.load(.acquire);
                const ae = self.metrics.authority_reorg_events_5m.load(.acquire);
                const afk = self.metrics.authority_fork_events_total.load(.acquire);
                const adm = self.metrics.authority_reorg_depth_max_5m.load(.acquire);
                const ada = self.metrics.authority_reorg_depth_avg_x1e6.load(.acquire);
                const afd = self.metrics.authority_fork_delta_5m.load(.acquire);
                const ass_ = self.metrics.authority_stable_seconds.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_authority_confidence Authority confidence score (0.0-1.0)
                    \\# TYPE tsunagi_authority_confidence gauge
                    \\tsunagi_authority_confidence {d}.{d:0>6}
                    \\# HELP tsunagi_authority_finality_score Finality estimation score (0.0-1.0)
                    \\# TYPE tsunagi_authority_finality_score gauge
                    \\tsunagi_authority_finality_score {d}.{d:0>6}
                    \\# HELP tsunagi_authority_reorg_depth_last Depth of last observed reorg
                    \\# TYPE tsunagi_authority_reorg_depth_last gauge
                    \\tsunagi_authority_reorg_depth_last {d}
                    \\# HELP tsunagi_authority_reorg_events_5m Reorg events in current 5-minute window
                    \\# TYPE tsunagi_authority_reorg_events_5m gauge
                    \\tsunagi_authority_reorg_events_5m {d}
                    \\# HELP tsunagi_authority_fork_events_total Cumulative fork detection events
                    \\# TYPE tsunagi_authority_fork_events_total counter
                    \\tsunagi_authority_fork_events_total {d}
                    \\
                , .{ ac / 1_000_000, ac % 1_000_000, af / 1_000_000, af % 1_000_000, ar, ae, afk }) catch {};
                wr.print(
                    \\# HELP tsunagi_authority_reorg_depth_max_5m Max reorg depth in 5-minute window
                    \\# TYPE tsunagi_authority_reorg_depth_max_5m gauge
                    \\tsunagi_authority_reorg_depth_max_5m {d}
                    \\# HELP tsunagi_authority_reorg_depth_avg_5m Avg reorg depth in 5-minute window (0.0-N.0)
                    \\# TYPE tsunagi_authority_reorg_depth_avg_5m gauge
                    \\tsunagi_authority_reorg_depth_avg_5m {d}.{d:0>6}
                    \\# HELP tsunagi_authority_fork_delta_5m Fork count delta in 5-minute window
                    \\# TYPE tsunagi_authority_fork_delta_5m gauge
                    \\tsunagi_authority_fork_delta_5m {d}
                    \\# HELP tsunagi_authority_stable_seconds Seconds since last instability event
                    \\# TYPE tsunagi_authority_stable_seconds gauge
                    \\tsunagi_authority_stable_seconds {d}
                    \\
                , .{ adm, ada / 1_000_000, ada % 1_000_000, afd, ass_ }) catch {};
                wr.print(
                    \\# HELP tsunagi_authority_gate_active Stability gate active after reconnect (0/1)
                    \\# TYPE tsunagi_authority_gate_active gauge
                    \\tsunagi_authority_gate_active {d}
                    \\# HELP tsunagi_authority_reason_code_last Dominant confidence penalty reason (0=ok 1=reorg_events 2=reorg_depth 3=fork 4=low_stable 5=gate)
                    \\# TYPE tsunagi_authority_reason_code_last gauge
                    \\tsunagi_authority_reason_code_last {d}
                    \\# HELP tsunagi_authority_reorg_events_delta_5m Reorg events delta in 5-minute window
                    \\# TYPE tsunagi_authority_reorg_events_delta_5m gauge
                    \\tsunagi_authority_reorg_events_delta_5m {d}
                    \\# HELP tsunagi_authority_window_unix Authority 5-minute window start unix
                    \\# TYPE tsunagi_authority_window_unix gauge
                    \\tsunagi_authority_window_unix {d}
                    \\
                , .{
                    self.metrics.authority_gate_active.load(.acquire),
                    self.metrics.authority_reason_code_last.load(.acquire),
                    self.metrics.authority_reorg_events_delta_5m.load(.acquire),
                    self.metrics.authority_window_unix.load(.acquire),
                }) catch {};
            }

            // Header validation
            {
                const hv_ratio = self.metrics.header_validate_fail_ratio_x1e6.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_header_validate_total Headers validated
                    \\# TYPE tsunagi_header_validate_total counter
                    \\tsunagi_header_validate_total {d}
                    \\# HELP tsunagi_header_validate_fail_total Header validation failures
                    \\# TYPE tsunagi_header_validate_fail_total counter
                    \\tsunagi_header_validate_fail_total {d}
                    \\# HELP tsunagi_header_hash_mismatch_total Header hash computation failures
                    \\# TYPE tsunagi_header_hash_mismatch_total counter
                    \\tsunagi_header_hash_mismatch_total {d}
                    \\# HELP tsunagi_header_prevhash_mismatch_total Header prev-hash linkage mismatches
                    \\# TYPE tsunagi_header_prevhash_mismatch_total counter
                    \\tsunagi_header_prevhash_mismatch_total {d}
                    \\# HELP tsunagi_header_validate_fail_ratio Validation failure ratio
                    \\# TYPE tsunagi_header_validate_fail_ratio gauge
                    \\tsunagi_header_validate_fail_ratio {d}.{d:0>6}
                    \\
                , .{
                    self.metrics.header_validate_total.load(.acquire),
                    self.metrics.header_validate_fail_total.load(.acquire),
                    self.metrics.header_hash_mismatch_total.load(.acquire),
                    self.metrics.header_prevhash_mismatch_total.load(.acquire),
                    hv_ratio / 1_000_000, hv_ratio % 1_000_000,
                }) catch {};
            }

            // Header authority invariants
            wr.print(
                \\# HELP tsunagi_header_height_violation_total Height monotonicity violations
                \\# TYPE tsunagi_header_height_violation_total counter
                \\tsunagi_header_height_violation_total {d}
                \\# HELP tsunagi_header_slot_violation_total Slot monotonicity violations (forward only)
                \\# TYPE tsunagi_header_slot_violation_total counter
                \\tsunagi_header_slot_violation_total {d}
                \\# HELP tsunagi_header_block_violation_total Block number monotonicity violations (forward only)
                \\# TYPE tsunagi_header_block_violation_total counter
                \\tsunagi_header_block_violation_total {d}
                \\# HELP tsunagi_header_rollback_total Total rollback events in header store
                \\# TYPE tsunagi_header_rollback_total counter
                \\tsunagi_header_rollback_total {d}
                \\# HELP tsunagi_header_rollback_depth_last Depth of last rollback in header store
                \\# TYPE tsunagi_header_rollback_depth_last gauge
                \\tsunagi_header_rollback_depth_last {d}
                \\
            , .{
                self.metrics.header_height_violation.load(.acquire),
                self.metrics.header_slot_violation.load(.acquire),
                self.metrics.header_block_violation.load(.acquire),
                self.metrics.header_rollback_total.load(.acquire),
                self.metrics.header_rollback_depth_last.load(.acquire),
            }) catch {};

            // Ledger invariants
            wr.print(
                \\# HELP tsunagi_ledger_violation_total Total ledger invariant violations
                \\# TYPE tsunagi_ledger_violation_total counter
                \\tsunagi_ledger_violation_total {d}
                \\# HELP tsunagi_ledger_dup_input_total Duplicate consumed inputs detected in block
                \\# TYPE tsunagi_ledger_dup_input_total counter
                \\tsunagi_ledger_dup_input_total {d}
                \\# HELP tsunagi_ledger_overflow_total Arithmetic overflow events
                \\# TYPE tsunagi_ledger_overflow_total counter
                \\tsunagi_ledger_overflow_total {d}
                \\# HELP tsunagi_ledger_missing_input_total Consumed inputs missing from LMDB
                \\# TYPE tsunagi_ledger_missing_input_total counter
                \\tsunagi_ledger_missing_input_total {d}
                \\# HELP tsunagi_ledger_strict_disconnect_total Disconnects due to strict ledger mode
                \\# TYPE tsunagi_ledger_strict_disconnect_total counter
                \\tsunagi_ledger_strict_disconnect_total {d}
                \\# HELP tsunagi_ledger_value_violation_total Value conservation violations (sum_out > sum_in)
                \\# TYPE tsunagi_ledger_value_violation_total counter
                \\tsunagi_ledger_value_violation_total {d}
                \\# HELP tsunagi_ledger_sum_in_lovelace_last Last block sum of consumed lovelace
                \\# TYPE tsunagi_ledger_sum_in_lovelace_last gauge
                \\tsunagi_ledger_sum_in_lovelace_last {d}
                \\# HELP tsunagi_ledger_sum_out_lovelace_last Last block sum of produced lovelace
                \\# TYPE tsunagi_ledger_sum_out_lovelace_last gauge
                \\tsunagi_ledger_sum_out_lovelace_last {d}
                \\# HELP tsunagi_ledger_fee_est_lovelace_last Last block estimated fee (sum_in - sum_out)
                \\# TYPE tsunagi_ledger_fee_est_lovelace_last gauge
                \\tsunagi_ledger_fee_est_lovelace_last {d}
                \\
            , .{
                self.metrics.ledger_violation_total.load(.acquire),
                self.metrics.ledger_dup_input_total.load(.acquire),
                self.metrics.ledger_overflow_total.load(.acquire),
                self.metrics.ledger_missing_input_total.load(.acquire),
                self.metrics.ledger_strict_disconnect_total.load(.acquire),
                self.metrics.ledger_value_violation_total.load(.acquire),
                self.metrics.ledger_sum_in_lovelace_last.load(.acquire),
                self.metrics.ledger_sum_out_lovelace_last.load(.acquire),
                self.metrics.ledger_fee_est_lovelace_last.load(.acquire),
            }) catch {};

            // LMDB truth failures (v1.5.9)
            wr.print(
                \\# HELP tsunagi_lmdb_truth_apply_fail_total LMDB truth applyDelta failures (non-fatal in preview mode)
                \\# TYPE tsunagi_lmdb_truth_apply_fail_total counter
                \\tsunagi_lmdb_truth_apply_fail_total {d}
                \\
            , .{
                self.metrics.lmdb_truth_apply_fail_total.load(.acquire),
            }) catch {};

            // v5.2: preflight coverage profile
            wr.print(
                \\# HELP tsunagi_preflight_full_coverage_blocks_total Blocks with all consumed inputs found in LMDB
                \\# TYPE tsunagi_preflight_full_coverage_blocks_total counter
                \\tsunagi_preflight_full_coverage_blocks_total {d}
                \\# HELP tsunagi_preflight_partial_coverage_blocks_total Blocks with some but not all consumed inputs in LMDB
                \\# TYPE tsunagi_preflight_partial_coverage_blocks_total counter
                \\tsunagi_preflight_partial_coverage_blocks_total {d}
                \\# HELP tsunagi_preflight_zero_coverage_blocks_total Blocks with no consumed inputs found in LMDB
                \\# TYPE tsunagi_preflight_zero_coverage_blocks_total counter
                \\tsunagi_preflight_zero_coverage_blocks_total {d}
                \\
            , .{
                self.metrics.preflight_full_coverage_blocks.load(.acquire),
                self.metrics.preflight_partial_coverage_blocks.load(.acquire),
                self.metrics.preflight_zero_coverage_blocks.load(.acquire),
            }) catch {};

            // Ledger value check coverage
            {
                const checks = self.metrics.ledger_value_checks_total.load(.acquire);
                const skipped = self.metrics.ledger_value_checks_skipped_total.load(.acquire);
                const ratio_x1e6 = self.metrics.ledger_value_check_ratio_x1e6.load(.acquire);
                const cov_ratio: f64 = @as(f64, @floatFromInt(ratio_x1e6)) / 1_000_000.0;
                wr.print(
                    \\# HELP tsunagi_ledger_value_checks_total Blocks where value conservation check executed
                    \\# TYPE tsunagi_ledger_value_checks_total counter
                    \\tsunagi_ledger_value_checks_total {d}
                    \\# HELP tsunagi_ledger_value_checks_skipped_total Blocks where value check skipped (missing inputs)
                    \\# TYPE tsunagi_ledger_value_checks_skipped_total counter
                    \\tsunagi_ledger_value_checks_skipped_total {d}
                    \\# HELP tsunagi_ledger_value_check_ratio Ratio of blocks with value check executed
                    \\# TYPE tsunagi_ledger_value_check_ratio gauge
                    \\tsunagi_ledger_value_check_ratio {d:.6}
                    \\# HELP tsunagi_ledger_input_decode_fail_total Consumed inputs found but value too short to decode
                    \\# TYPE tsunagi_ledger_input_decode_fail_total counter
                    \\tsunagi_ledger_input_decode_fail_total {d}
                    \\
                , .{ checks, skipped, cov_ratio, self.metrics.ledger_input_decode_fail_total.load(.acquire) }) catch {};
            }

            // TX decode failure counters (polled from tx_decode statics)
            {
                const tx_decode_mod = @import("../ledger/tx_decode.zig");
                const dc = tx_decode_mod.getDecodeCounters();
                wr.print(
                    \\# HELP tsunagi_tx_decode_fail_total TX items that failed CBOR decode
                    \\# TYPE tsunagi_tx_decode_fail_total counter
                    \\tsunagi_tx_decode_fail_total {d}
                    \\# HELP tsunagi_tx_input_parse_fail_total TX input parse failures
                    \\# TYPE tsunagi_tx_input_parse_fail_total counter
                    \\tsunagi_tx_input_parse_fail_total {d}
                    \\# HELP tsunagi_tx_output_parse_fail_total TX output parse failures
                    \\# TYPE tsunagi_tx_output_parse_fail_total counter
                    \\tsunagi_tx_output_parse_fail_total {d}
                    \\# HELP tsunagi_tx_hash_fail_total TX hash computation failures
                    \\# TYPE tsunagi_tx_hash_fail_total counter
                    \\tsunagi_tx_hash_fail_total {d}
                    \\# HELP tsunagi_tx_txid_mismatch_total Canonical txid count mismatches
                    \\# TYPE tsunagi_tx_txid_mismatch_total counter
                    \\tsunagi_tx_txid_mismatch_total {d}
                    \\# HELP tsunagi_tx_decode_blocks_total Blocks processed through TX decode
                    \\# TYPE tsunagi_tx_decode_blocks_total counter
                    \\tsunagi_tx_decode_blocks_total {d}
                    \\# HELP tsunagi_tx_ancestry_skip_total Delta applies skipped due to ancestry break
                    \\# TYPE tsunagi_tx_ancestry_skip_total counter
                    \\tsunagi_tx_ancestry_skip_total {d}
                    \\# HELP tsunagi_tx_block_total_fee_last Block total fee (lovelace) from most recent decode
                    \\# TYPE tsunagi_tx_block_total_fee_last gauge
                    \\tsunagi_tx_block_total_fee_last {d}
                    \\# HELP tsunagi_tx_block_total_output_last Block total output (lovelace) from most recent decode
                    \\# TYPE tsunagi_tx_block_total_output_last gauge
                    \\tsunagi_tx_block_total_output_last {d}
                    \\# HELP tsunagi_tx_withdrawal_txs_total Transactions with withdrawals (cumulative)
                    \\# TYPE tsunagi_tx_withdrawal_txs_total counter
                    \\tsunagi_tx_withdrawal_txs_total {d}
                    \\# HELP tsunagi_tx_cert_txs_total Transactions with certificates (cumulative)
                    \\# TYPE tsunagi_tx_cert_txs_total counter
                    \\tsunagi_tx_cert_txs_total {d}
                    \\# HELP tsunagi_tx_cert_stake_reg_total Stake registration certificates (cumulative)
                    \\# TYPE tsunagi_tx_cert_stake_reg_total counter
                    \\tsunagi_tx_cert_stake_reg_total {d}
                    \\# HELP tsunagi_tx_cert_stake_dereg_total Stake deregistration certificates (cumulative)
                    \\# TYPE tsunagi_tx_cert_stake_dereg_total counter
                    \\tsunagi_tx_cert_stake_dereg_total {d}
                    \\# HELP tsunagi_tx_cert_delegation_total Stake delegation certificates (cumulative)
                    \\# TYPE tsunagi_tx_cert_delegation_total counter
                    \\tsunagi_tx_cert_delegation_total {d}
                    \\# HELP tsunagi_tx_cert_pool_reg_total Pool registration certificates (cumulative)
                    \\# TYPE tsunagi_tx_cert_pool_reg_total counter
                    \\tsunagi_tx_cert_pool_reg_total {d}
                    \\# HELP tsunagi_tx_cert_pool_retire_total Pool retirement certificates (cumulative)
                    \\# TYPE tsunagi_tx_cert_pool_retire_total counter
                    \\tsunagi_tx_cert_pool_retire_total {d}
                    \\# HELP tsunagi_tx_cert_other_total Other certificate types (cumulative)
                    \\# TYPE tsunagi_tx_cert_other_total counter
                    \\tsunagi_tx_cert_other_total {d}
                    \\# HELP tsunagi_tx_cert_total All certificate actions (cumulative)
                    \\# TYPE tsunagi_tx_cert_total counter
                    \\tsunagi_tx_cert_total {d}
                    \\# HELP tsunagi_tx_script_txs_total Transactions with script data (cumulative)
                    \\# TYPE tsunagi_tx_script_txs_total counter
                    \\tsunagi_tx_script_txs_total {d}
                    \\# HELP tsunagi_tx_collateral_txs_total Transactions with collateral inputs (cumulative)
                    \\# TYPE tsunagi_tx_collateral_txs_total counter
                    \\tsunagi_tx_collateral_txs_total {d}
                    \\# HELP tsunagi_tx_input_duplicate_total Txs rejected for duplicate inputs
                    \\# TYPE tsunagi_tx_input_duplicate_total counter
                    \\tsunagi_tx_input_duplicate_total {d}
                    \\# HELP tsunagi_tx_validity_ttl_fail Txs with expired TTL
                    \\# TYPE tsunagi_tx_validity_ttl_fail counter
                    \\tsunagi_tx_validity_ttl_fail {d}
                    \\# HELP tsunagi_tx_validity_start_fail Txs with future validity start
                    \\# TYPE tsunagi_tx_validity_start_fail counter
                    \\tsunagi_tx_validity_start_fail {d}
                    \\# HELP tsunagi_tx_fee_zero_total Txs with zero fee
                    \\# TYPE tsunagi_tx_fee_zero_total counter
                    \\tsunagi_tx_fee_zero_total {d}
                    \\# HELP tsunagi_tx_balance_violation_total Blocks with lovelace balance violation
                    \\# TYPE tsunagi_tx_balance_violation_total counter
                    \\tsunagi_tx_balance_violation_total {d}
                    \\# HELP tsunagi_tx_address_malformed_total Outputs with malformed address
                    \\# TYPE tsunagi_tx_address_malformed_total counter
                    \\tsunagi_tx_address_malformed_total {d}
                    \\
                , .{
                    dc.decode_fail,
                    dc.input_parse_fail,
                    dc.output_parse_fail,
                    dc.hash_fail,
                    dc.txid_count_mismatch,
                    dc.blocks_total,
                    dc.ancestry_skip,
                    dc.block_total_fee_last,
                    dc.block_total_output_last,
                    dc.withdrawal_txs_total,
                    dc.cert_txs_total,
                    dc.cert_stake_reg_total,
                    dc.cert_stake_dereg_total,
                    dc.cert_delegation_total,
                    dc.cert_pool_reg_total,
                    dc.cert_pool_retire_total,
                    dc.cert_other_total,
                    dc.cert_total,
                    dc.script_txs_total,
                    dc.collateral_txs_total,
                    dc.input_duplicate_total,
                    dc.validity_ttl_fail,
                    dc.validity_start_fail,
                    dc.fee_zero_total,
                    dc.balance_violation_total,
                    dc.address_malformed_total,
                }) catch {};
            }

            // Operator insight: 5-minute window Prometheus gauges
            {
                const tx_decode_prom = @import("../ledger/tx_decode.zig");
                const ring_p = tx_decode_prom.getInsightRing();
                const cur_p = ring_p.getCurrent();
                wr.print(
                    \\# HELP tsunagi_insight_fees_5m Fees (lovelace) in current 5-min window
                    \\# TYPE tsunagi_insight_fees_5m gauge
                    \\tsunagi_insight_fees_5m {d}
                    \\# HELP tsunagi_insight_ada_moved_5m ADA moved (lovelace) in current 5-min window
                    \\# TYPE tsunagi_insight_ada_moved_5m gauge
                    \\tsunagi_insight_ada_moved_5m {d}
                    \\# HELP tsunagi_insight_txs_5m Total txs in current 5-min window
                    \\# TYPE tsunagi_insight_txs_5m gauge
                    \\tsunagi_insight_txs_5m {d}
                    \\# HELP tsunagi_insight_scripts_5m Script txs in current 5-min window
                    \\# TYPE tsunagi_insight_scripts_5m gauge
                    \\tsunagi_insight_scripts_5m {d}
                    \\# HELP tsunagi_insight_blocks_5m Blocks in current 5-min window
                    \\# TYPE tsunagi_insight_blocks_5m gauge
                    \\tsunagi_insight_blocks_5m {d}
                    \\
                , .{
                    cur_p.fees_lovelace,
                    cur_p.ada_moved_lovelace,
                    cur_p.total_tx_count,
                    cur_p.script_tx_count,
                    cur_p.blocks_in_window,
                }) catch {};
            }

            wr.print(
                \\# HELP tsunagi_ledger_missing_inputs_last Missing LMDB inputs in last validated block
                \\# TYPE tsunagi_ledger_missing_inputs_last gauge
                \\tsunagi_ledger_missing_inputs_last {d}
                \\# HELP tsunagi_ledger_missing_inputs_ema Smoothed missing input count (EMA)
                \\# TYPE tsunagi_ledger_missing_inputs_ema gauge
                \\tsunagi_ledger_missing_inputs_ema {d}
                \\# HELP tsunagi_ledger_auto_strict_enabled Auto-strict mode active (0/1)
                \\# TYPE tsunagi_ledger_auto_strict_enabled gauge
                \\tsunagi_ledger_auto_strict_enabled {d}
                \\# HELP tsunagi_ledger_auto_strict_toggle_total Auto-strict mode toggle events
                \\# TYPE tsunagi_ledger_auto_strict_toggle_total counter
                \\tsunagi_ledger_auto_strict_toggle_total {d}
                \\
            , .{
                self.metrics.ledger_missing_inputs_last.load(.acquire),
                self.metrics.ledger_missing_inputs_ema.load(.acquire),
                self.metrics.ledger_auto_strict_enabled.load(.acquire),
                self.metrics.ledger_auto_strict_toggle_total.load(.acquire),
            }) catch {};

            // Ledger anomaly bands
            {
                const dr_x1e6 = self.metrics.ledger_dust_ratio_last_x1e6.load(.acquire);
                const dr_int = dr_x1e6 / 1_000_000;
                const dr_frac = dr_x1e6 % 1_000_000;
                wr.print(
                    \\# HELP tsunagi_ledger_anomaly_total Total anomaly events (fee+dust+whale)
                    \\# TYPE tsunagi_ledger_anomaly_total counter
                    \\tsunagi_ledger_anomaly_total {d}
                    \\# HELP tsunagi_ledger_anomaly_fee_total Fee upper-bound anomalies
                    \\# TYPE tsunagi_ledger_anomaly_fee_total counter
                    \\tsunagi_ledger_anomaly_fee_total {d}
                    \\# HELP tsunagi_ledger_anomaly_dust_total Dust storm anomalies
                    \\# TYPE tsunagi_ledger_anomaly_dust_total counter
                    \\tsunagi_ledger_anomaly_dust_total {d}
                    \\# HELP tsunagi_ledger_anomaly_whale_total Whale output anomalies
                    \\# TYPE tsunagi_ledger_anomaly_whale_total counter
                    \\tsunagi_ledger_anomaly_whale_total {d}
                    \\# HELP tsunagi_ledger_anomaly_strict_disconnect_total Disconnects due to anomaly strict mode
                    \\# TYPE tsunagi_ledger_anomaly_strict_disconnect_total counter
                    \\tsunagi_ledger_anomaly_strict_disconnect_total {d}
                    \\# HELP tsunagi_ledger_dust_ratio_last Dust output ratio in last checked block
                    \\# TYPE tsunagi_ledger_dust_ratio_last gauge
                    \\tsunagi_ledger_dust_ratio_last {d}.{d:0>6}
                    \\# HELP tsunagi_ledger_dust_count_last Dust outputs in last checked block
                    \\# TYPE tsunagi_ledger_dust_count_last gauge
                    \\tsunagi_ledger_dust_count_last {d}
                    \\# HELP tsunagi_ledger_max_out_lovelace_last Largest single output lovelace in last checked block
                    \\# TYPE tsunagi_ledger_max_out_lovelace_last gauge
                    \\tsunagi_ledger_max_out_lovelace_last {d}
                    \\
                , .{
                    self.metrics.ledger_anomaly_total.load(.acquire),
                    self.metrics.ledger_anomaly_fee_total.load(.acquire),
                    self.metrics.ledger_anomaly_dust_total.load(.acquire),
                    self.metrics.ledger_anomaly_whale_total.load(.acquire),
                    self.metrics.ledger_anomaly_strict_disconnect_total.load(.acquire),
                    dr_int, dr_frac,
                    self.metrics.ledger_dust_count_last.load(.acquire),
                    self.metrics.ledger_max_out_lovelace_last.load(.acquire),
                }) catch {};
            }

            // Protocol params observation
            wr.print(
                \\# HELP tsunagi_protocol_params_reload_total Protocol params file reload attempts
                \\# TYPE tsunagi_protocol_params_reload_total counter
                \\tsunagi_protocol_params_reload_total {d}
                \\# HELP tsunagi_protocol_params_change_total Protocol params field changes detected
                \\# TYPE tsunagi_protocol_params_change_total counter
                \\tsunagi_protocol_params_change_total {d}
                \\# HELP tsunagi_protocol_params_fallback_total Protocol params file fallbacks to genesis
                \\# TYPE tsunagi_protocol_params_fallback_total counter
                \\tsunagi_protocol_params_fallback_total {d}
                \\
            , .{
                self.metrics.protocol_params_reload_total.load(.acquire),
                self.metrics.protocol_params_change_total.load(.acquire),
                self.metrics.protocol_params_fallback_total.load(.acquire),
            }) catch {};

            // TxSubmission mini-protocol
            wr.print(
                \\# HELP tsunagi_txsub_sessions_total TxSubmission streams opened
                \\# TYPE tsunagi_txsub_sessions_total counter
                \\tsunagi_txsub_sessions_total {d}
                \\# HELP tsunagi_txsub_msgs_total TxSubmission messages decoded
                \\# TYPE tsunagi_txsub_msgs_total counter
                \\tsunagi_txsub_msgs_total {d}
                \\# HELP tsunagi_txsub_decode_errors_total TxSubmission CBOR decode errors
                \\# TYPE tsunagi_txsub_decode_errors_total counter
                \\tsunagi_txsub_decode_errors_total {d}
                \\# HELP tsunagi_txsub_inventory_sent_total TxSubmission inventory responses sent
                \\# TYPE tsunagi_txsub_inventory_sent_total counter
                \\tsunagi_txsub_inventory_sent_total {d}
                \\# HELP tsunagi_txsub_inventory_items_last Txids in last inventory response
                \\# TYPE tsunagi_txsub_inventory_items_last gauge
                \\tsunagi_txsub_inventory_items_last {d}
                \\# HELP tsunagi_txsub_txs_requested_total Tx bodies requested by peers
                \\# TYPE tsunagi_txsub_txs_requested_total counter
                \\tsunagi_txsub_txs_requested_total {d}
                \\# HELP tsunagi_txsub_txs_served_total Tx bodies served to peers
                \\# TYPE tsunagi_txsub_txs_served_total counter
                \\tsunagi_txsub_txs_served_total {d}
                \\# HELP tsunagi_txsub_bytes_served_total Tx bytes served to peers
                \\# TYPE tsunagi_txsub_bytes_served_total counter
                \\tsunagi_txsub_bytes_served_total {d}
                \\# HELP tsunagi_txsub_inventory_broadcast_total Outbound inventory broadcasts on mempool change
                \\# TYPE tsunagi_txsub_inventory_broadcast_total counter
                \\tsunagi_txsub_inventory_broadcast_total {d}
                \\# HELP tsunagi_txsub_inventory_broadcast_items_last Items in last outbound broadcast
                \\# TYPE tsunagi_txsub_inventory_broadcast_items_last gauge
                \\tsunagi_txsub_inventory_broadcast_items_last {d}
                \\# HELP tsunagi_txsub_broadcast_attempt_total Broadcast attempts (env enabled)
                \\# TYPE tsunagi_txsub_broadcast_attempt_total counter
                \\tsunagi_txsub_broadcast_attempt_total {d}
                \\# HELP tsunagi_txsub_broadcast_sent_total Broadcasts successfully sent
                \\# TYPE tsunagi_txsub_broadcast_sent_total counter
                \\tsunagi_txsub_broadcast_sent_total {d}
                \\# HELP tsunagi_txsub_broadcast_blocked_total Broadcasts blocked by gating
                \\# TYPE tsunagi_txsub_broadcast_blocked_total counter
                \\tsunagi_txsub_broadcast_blocked_total {d}
                \\# HELP tsunagi_txsub_session_active TxSubmission session currently active (0/1)
                \\# TYPE tsunagi_txsub_session_active gauge
                \\tsunagi_txsub_session_active {d}
                \\# HELP tsunagi_txsub_session_first_unix Unix timestamp when current session started
                \\# TYPE tsunagi_txsub_session_first_unix gauge
                \\tsunagi_txsub_session_first_unix {d}
                \\# HELP tsunagi_txsub_last_msg_unix Unix timestamp of last TxSubmission message
                \\# TYPE tsunagi_txsub_last_msg_unix gauge
                \\tsunagi_txsub_last_msg_unix {d}
                \\# HELP tsunagi_txsub_done_total TxSubmission MsgDone events (peer ended session)
                \\# TYPE tsunagi_txsub_done_total counter
                \\tsunagi_txsub_done_total {d}
                \\
            , .{
                self.metrics.txsub_sessions_total.load(.acquire),
                self.metrics.txsub_msgs_total.load(.acquire),
                self.metrics.txsub_decode_errors_total.load(.acquire),
                self.metrics.txsub_inventory_sent_total.load(.acquire),
                self.metrics.txsub_inventory_items_last.load(.acquire),
                self.metrics.txsub_txs_requested_total.load(.acquire),
                self.metrics.txsub_txs_served_total.load(.acquire),
                self.metrics.txsub_bytes_served_total.load(.acquire),
                self.metrics.txsub_inventory_broadcast_total.load(.acquire),
                self.metrics.txsub_inventory_broadcast_items_last.load(.acquire),
                self.metrics.txsub_broadcast_attempt_total.load(.acquire),
                self.metrics.txsub_broadcast_sent_total.load(.acquire),
                self.metrics.txsub_broadcast_blocked_total.load(.acquire),
                self.metrics.txsub_session_active.load(.acquire),
                self.metrics.txsub_session_first_unix.load(.acquire),
                self.metrics.txsub_last_msg_unix.load(.acquire),
                self.metrics.txsub_done_total.load(.acquire),
            }) catch {};

            // TxSubmission passive observability
            wr.print(
                \\# HELP tsunagi_txsub_rx_msgs_total Cumulative TxSubmission messages received
                \\# TYPE tsunagi_txsub_rx_msgs_total counter
                \\tsunagi_txsub_rx_msgs_total {d}
                \\# HELP tsunagi_txsub_rx_bytes_total Cumulative TxSubmission bytes received
                \\# TYPE tsunagi_txsub_rx_bytes_total counter
                \\tsunagi_txsub_rx_bytes_total {d}
                \\# HELP tsunagi_txsub_session_rx_msgs_last Messages received in current/last session
                \\# TYPE tsunagi_txsub_session_rx_msgs_last gauge
                \\tsunagi_txsub_session_rx_msgs_last {d}
                \\# HELP tsunagi_txsub_session_rx_bytes_last Bytes received in current/last session
                \\# TYPE tsunagi_txsub_session_rx_bytes_last gauge
                \\tsunagi_txsub_session_rx_bytes_last {d}
                \\# HELP tsunagi_txsub_session_first_msg_id_last Msg ID of first message in session (0=none)
                \\# TYPE tsunagi_txsub_session_first_msg_id_last gauge
                \\tsunagi_txsub_session_first_msg_id_last {d}
                \\# HELP tsunagi_txsub_session_age_seconds_last Age of current session in seconds
                \\# TYPE tsunagi_txsub_session_age_seconds_last gauge
                \\tsunagi_txsub_session_age_seconds_last {d}
                \\
            , .{
                self.metrics.txsub_rx_msgs_total.load(.acquire),
                self.metrics.txsub_rx_bytes_total.load(.acquire),
                self.metrics.txsub_session_rx_msgs_last.load(.acquire),
                self.metrics.txsub_session_rx_bytes_last.load(.acquire),
                self.metrics.txsub_session_first_msg_id_last.load(.acquire),
                self.metrics.txsub_session_age_seconds_last.load(.acquire),
            }) catch {};

            // TxSubmission msg-id census
            wr.print(
                \\# HELP tsunagi_txsub_msg_id_0_total MsgRequestTxIds non-blocking received
                \\# TYPE tsunagi_txsub_msg_id_0_total counter
                \\tsunagi_txsub_msg_id_0_total {d}
                \\# HELP tsunagi_txsub_msg_id_1_total MsgRequestTxIds blocking received
                \\# TYPE tsunagi_txsub_msg_id_1_total counter
                \\tsunagi_txsub_msg_id_1_total {d}
                \\# HELP tsunagi_txsub_msg_id_3_total MsgRequestTxs received
                \\# TYPE tsunagi_txsub_msg_id_3_total counter
                \\tsunagi_txsub_msg_id_3_total {d}
                \\# HELP tsunagi_txsub_msg_id_4_total MsgReplyTxs received (unexpected)
                \\# TYPE tsunagi_txsub_msg_id_4_total counter
                \\tsunagi_txsub_msg_id_4_total {d}
                \\# HELP tsunagi_txsub_msg_id_5_total MsgDone received
                \\# TYPE tsunagi_txsub_msg_id_5_total counter
                \\tsunagi_txsub_msg_id_5_total {d}
                \\# HELP tsunagi_txsub_msg_id_6_total MsgInit received from peer
                \\# TYPE tsunagi_txsub_msg_id_6_total counter
                \\tsunagi_txsub_msg_id_6_total {d}
                \\# HELP tsunagi_txsub_msg_id_unknown_total Unknown msg_id received
                \\# TYPE tsunagi_txsub_msg_id_unknown_total counter
                \\tsunagi_txsub_msg_id_unknown_total {d}
                \\
            , .{
                self.metrics.txsub_msg_id_0_total.load(.acquire),
                self.metrics.txsub_msg_id_1_total.load(.acquire),
                self.metrics.txsub_msg_id_3_total.load(.acquire),
                self.metrics.txsub_msg_id_4_total.load(.acquire),
                self.metrics.txsub_msg_id_5_total.load(.acquire),
                self.metrics.txsub_msg_id_6_total.load(.acquire),
                self.metrics.txsub_msg_id_unknown_total.load(.acquire),
            }) catch {};

            // TxSubmission state machine
            wr.print(
                \\# HELP tsunagi_txsub_known_total Known TxSubmission messages (msg_id 0-6)
                \\# TYPE tsunagi_txsub_known_total counter
                \\tsunagi_txsub_known_total {d}
                \\# HELP tsunagi_txsub_ignored_total Messages ignored in Done state
                \\# TYPE tsunagi_txsub_ignored_total counter
                \\tsunagi_txsub_ignored_total {d}
                \\# HELP tsunagi_txsub_invalid_shape_total Messages with invalid CBOR shape
                \\# TYPE tsunagi_txsub_invalid_shape_total counter
                \\tsunagi_txsub_invalid_shape_total {d}
                \\# HELP tsunagi_txsub_state_code TxSubmission state (0=Idle 1=Active 2=Done)
                \\# TYPE tsunagi_txsub_state_code gauge
                \\tsunagi_txsub_state_code {d}
                \\
            , .{
                self.metrics.txsub_known_total.load(.acquire),
                self.metrics.txsub_ignored_total.load(.acquire),
                self.metrics.txsub_invalid_shape_total.load(.acquire),
                self.metrics.txsub_state_code.load(.acquire),
            }) catch {};

            // Tx submission relay (v1.7.0)
            wr.print(
                \\# HELP tsunagi_txsub_relay_requests_total HTTP /tx/submit requests received
                \\# TYPE tsunagi_txsub_relay_requests_total counter
                \\tsunagi_txsub_relay_requests_total {d}
                \\# HELP tsunagi_txsub_relay_accepted_total Txs accepted into mempool for relay
                \\# TYPE tsunagi_txsub_relay_accepted_total counter
                \\tsunagi_txsub_relay_accepted_total {d}
                \\# HELP tsunagi_txsub_relay_rejected_total Txs rejected by local validation
                \\# TYPE tsunagi_txsub_relay_rejected_total counter
                \\tsunagi_txsub_relay_rejected_total {d}
                \\# HELP tsunagi_txsub_relay_disabled_total Requests rejected (relay disabled)
                \\# TYPE tsunagi_txsub_relay_disabled_total counter
                \\tsunagi_txsub_relay_disabled_total {d}
                \\# HELP tsunagi_txsub_relay_rate_limited_total Requests rejected by rate limit
                \\# TYPE tsunagi_txsub_relay_rate_limited_total counter
                \\tsunagi_txsub_relay_rate_limited_total {d}
                \\# HELP tsunagi_txsub_relay_too_large_total Requests rejected (tx too large)
                \\# TYPE tsunagi_txsub_relay_too_large_total counter
                \\tsunagi_txsub_relay_too_large_total {d}
                \\# HELP tsunagi_txsub_relay_last_result_unix Unix timestamp of last /tx/submit result
                \\# TYPE tsunagi_txsub_relay_last_result_unix gauge
                \\tsunagi_txsub_relay_last_result_unix {d}
                \\
            , .{
                self.metrics.txsub_relay_requests_total.load(.acquire),
                self.metrics.txsub_relay_accepted_total.load(.acquire),
                self.metrics.txsub_relay_rejected_total.load(.acquire),
                self.metrics.txsub_relay_disabled_total.load(.acquire),
                self.metrics.txsub_relay_rate_limited_total.load(.acquire),
                self.metrics.txsub_relay_too_large_total.load(.acquire),
                self.metrics.txsub_relay_last_result_unix.load(.acquire),
            }) catch {};

            // Producer dry-run (v1.8.0)
            wr.print(
                \\# HELP tsunagi_producer_dryrun_enabled Whether producer dry-run mode is enabled
                \\# TYPE tsunagi_producer_dryrun_enabled gauge
                \\tsunagi_producer_dryrun_enabled {d}
                \\# HELP tsunagi_producer_dryrun_slots_checked_total Slots checked in dry-run mode
                \\# TYPE tsunagi_producer_dryrun_slots_checked_total counter
                \\tsunagi_producer_dryrun_slots_checked_total {d}
                \\# HELP tsunagi_producer_dryrun_leader_slots_total Leader slots found in dry-run mode
                \\# TYPE tsunagi_producer_dryrun_leader_slots_total counter
                \\tsunagi_producer_dryrun_leader_slots_total {d}
                \\# HELP tsunagi_producer_dryrun_candidates_built_total Candidate artifacts built in dry-run mode
                \\# TYPE tsunagi_producer_dryrun_candidates_built_total counter
                \\tsunagi_producer_dryrun_candidates_built_total {d}
                \\# HELP tsunagi_producer_dryrun_candidates_verified_total Candidate artifacts verified in dry-run mode
                \\# TYPE tsunagi_producer_dryrun_candidates_verified_total counter
                \\tsunagi_producer_dryrun_candidates_verified_total {d}
                \\# HELP tsunagi_producer_dryrun_last_leader_slot Last leader slot found in dry-run mode
                \\# TYPE tsunagi_producer_dryrun_last_leader_slot gauge
                \\tsunagi_producer_dryrun_last_leader_slot {d}
                \\# HELP tsunagi_producer_dryrun_last_candidate_unix Unix timestamp of last dry-run candidate
                \\# TYPE tsunagi_producer_dryrun_last_candidate_unix gauge
                \\tsunagi_producer_dryrun_last_candidate_unix {d}
                \\# HELP tsunagi_producer_dryrun_last_verify_ok Last dry-run candidate verification result
                \\# TYPE tsunagi_producer_dryrun_last_verify_ok gauge
                \\tsunagi_producer_dryrun_last_verify_ok {d}
                \\# HELP tsunagi_producer_dryrun_candidates_signed_total Candidates signed with real KES in dry-run mode
                \\# TYPE tsunagi_producer_dryrun_candidates_signed_total counter
                \\tsunagi_producer_dryrun_candidates_signed_total {d}
                \\# HELP tsunagi_producer_dryrun_last_sign_verify_ok Last real KES sign+verify result
                \\# TYPE tsunagi_producer_dryrun_last_sign_verify_ok gauge
                \\tsunagi_producer_dryrun_last_sign_verify_ok {d}
                \\
            , .{
                self.metrics.producer_dryrun_enabled.load(.acquire),
                self.metrics.producer_dryrun_slots_checked_total.load(.acquire),
                self.metrics.producer_dryrun_leader_slots_total.load(.acquire),
                self.metrics.producer_dryrun_candidates_built_total.load(.acquire),
                self.metrics.producer_dryrun_candidates_verified_total.load(.acquire),
                self.metrics.producer_dryrun_last_leader_slot.load(.acquire),
                self.metrics.producer_dryrun_last_candidate_unix.load(.acquire),
                self.metrics.producer_dryrun_last_verify_ok.load(.acquire),
                self.metrics.producer_dryrun_candidates_signed_total.load(.acquire),
                self.metrics.producer_dryrun_last_sign_verify_ok.load(.acquire),
            }) catch {};

            // KeepAlive mini-protocol
            wr.print(
                \\# HELP tsunagi_keepalive_pings_total KeepAlive pings sent
                \\# TYPE tsunagi_keepalive_pings_total counter
                \\tsunagi_keepalive_pings_total {d}
                \\# HELP tsunagi_keepalive_pongs_total KeepAlive pongs received
                \\# TYPE tsunagi_keepalive_pongs_total counter
                \\tsunagi_keepalive_pongs_total {d}
                \\# HELP tsunagi_keepalive_decode_errors_total KeepAlive CBOR decode errors
                \\# TYPE tsunagi_keepalive_decode_errors_total counter
                \\tsunagi_keepalive_decode_errors_total {d}
                \\# HELP tsunagi_keepalive_timeouts_total KeepAlive pong timeouts
                \\# TYPE tsunagi_keepalive_timeouts_total counter
                \\tsunagi_keepalive_timeouts_total {d}
                \\# HELP tsunagi_keepalive_reconnect_total KeepAlive strict reconnects (2 consecutive timeouts)
                \\# TYPE tsunagi_keepalive_reconnect_total counter
                \\tsunagi_keepalive_reconnect_total {d}
                \\
            , .{
                self.metrics.keepalive_pings_total.load(.acquire),
                self.metrics.keepalive_pongs_total.load(.acquire),
                self.metrics.keepalive_decode_errors_total.load(.acquire),
                self.metrics.keepalive_timeouts_total.load(.acquire),
                self.metrics.keepalive_reconnect_total.load(.acquire),
            }) catch {};

            // Mempool
            wr.print(
                \\# HELP tsunagi_mempool_items Current mempool transaction count
                \\# TYPE tsunagi_mempool_items gauge
                \\tsunagi_mempool_items {d}
                \\# HELP tsunagi_mempool_bytes Current mempool total bytes
                \\# TYPE tsunagi_mempool_bytes gauge
                \\tsunagi_mempool_bytes {d}
                \\# HELP tsunagi_mempool_accept_total Transactions accepted into mempool
                \\# TYPE tsunagi_mempool_accept_total counter
                \\tsunagi_mempool_accept_total {d}
                \\# HELP tsunagi_mempool_reject_total Transactions rejected from mempool
                \\# TYPE tsunagi_mempool_reject_total counter
                \\tsunagi_mempool_reject_total {d}
                \\# HELP tsunagi_mempool_evictions_total Transactions evicted from mempool
                \\# TYPE tsunagi_mempool_evictions_total counter
                \\tsunagi_mempool_evictions_total {d}
                \\# HELP tsunagi_mempool_confirmed_evictions_total Mempool txs evicted by block confirmation
                \\# TYPE tsunagi_mempool_confirmed_evictions_total counter
                \\tsunagi_mempool_confirmed_evictions_total {d}
                \\# HELP tsunagi_mempool_conflict_reject_total Txs rejected for input conflict with mempool
                \\# TYPE tsunagi_mempool_conflict_reject_total counter
                \\tsunagi_mempool_conflict_reject_total {d}
                \\# HELP tsunagi_mempool_missing_input_reject_total Txs rejected for missing input UTxO
                \\# TYPE tsunagi_mempool_missing_input_reject_total counter
                \\tsunagi_mempool_missing_input_reject_total {d}
                \\# HELP tsunagi_mempool_balance_reject_total Txs rejected for insufficient input balance
                \\# TYPE tsunagi_mempool_balance_reject_total counter
                \\tsunagi_mempool_balance_reject_total {d}
                \\# HELP tsunagi_mempool_fee_insufficient_reject_total Txs rejected for fee below min-fee
                \\# TYPE tsunagi_mempool_fee_insufficient_reject_total counter
                \\tsunagi_mempool_fee_insufficient_reject_total {d}
                \\# HELP tsunagi_mempool_min_utxo_reject_total Txs rejected for output below min-UTxO
                \\# TYPE tsunagi_mempool_min_utxo_reject_total counter
                \\tsunagi_mempool_min_utxo_reject_total {d}
                \\# HELP tsunagi_mempool_timelock_reject_total Txs rejected for native timelock violation
                \\# TYPE tsunagi_mempool_timelock_reject_total counter
                \\tsunagi_mempool_timelock_reject_total {d}
                \\# HELP tsunagi_mempool_witness_invalid_reject_total Txs rejected for invalid vkey witness
                \\# TYPE tsunagi_mempool_witness_invalid_reject_total counter
                \\tsunagi_mempool_witness_invalid_reject_total {d}
                \\# HELP tsunagi_mempool_witness_coverage_reject_total Txs rejected for missing keyhash witness
                \\# TYPE tsunagi_mempool_witness_coverage_reject_total counter
                \\tsunagi_mempool_witness_coverage_reject_total {d}
                \\# HELP tsunagi_mempool_plutus_unsupported_reject_total Txs rejected for requiring Plutus execution
                \\# TYPE tsunagi_mempool_plutus_unsupported_reject_total counter
                \\tsunagi_mempool_plutus_unsupported_reject_total {d}
                \\# HELP tsunagi_mempool_plutus_txs_seen_total Plutus txs classified at mempool admission
                \\# TYPE tsunagi_mempool_plutus_txs_seen_total counter
                \\tsunagi_mempool_plutus_txs_seen_total {d}
                \\# HELP tsunagi_mempool_plutus_with_redeemers_total Plutus txs with redeemers present
                \\# TYPE tsunagi_mempool_plutus_with_redeemers_total counter
                \\tsunagi_mempool_plutus_with_redeemers_total {d}
                \\# HELP tsunagi_mempool_plutus_readiness_4_total Plutus txs with all prerequisites (evaluator absent)
                \\# TYPE tsunagi_mempool_plutus_readiness_4_total counter
                \\tsunagi_mempool_plutus_readiness_4_total {d}
                \\# HELP tsunagi_mempool_inputs_key_controlled_total Consumed inputs classified as key-controlled
                \\# TYPE tsunagi_mempool_inputs_key_controlled_total counter
                \\tsunagi_mempool_inputs_key_controlled_total {d}
                \\# HELP tsunagi_mempool_inputs_script_non_plutus_total Consumed inputs classified as script-controlled (non-Plutus)
                \\# TYPE tsunagi_mempool_inputs_script_non_plutus_total counter
                \\tsunagi_mempool_inputs_script_non_plutus_total {d}
                \\# HELP tsunagi_mempool_inputs_plutus_definitive_total Consumed inputs classified as Plutus-controlled (definitive)
                \\# TYPE tsunagi_mempool_inputs_plutus_definitive_total counter
                \\tsunagi_mempool_inputs_plutus_definitive_total {d}
                \\# HELP tsunagi_mempool_inputs_unknown_total Consumed inputs with unknown classification
                \\# TYPE tsunagi_mempool_inputs_unknown_total counter
                \\tsunagi_mempool_inputs_unknown_total {d}
                \\# HELP tsunagi_mempool_ttl_reject_total Txs rejected for expired TTL
                \\# TYPE tsunagi_mempool_ttl_reject_total counter
                \\tsunagi_mempool_ttl_reject_total {d}
                \\# HELP tsunagi_mempool_validity_start_reject_total Txs rejected for future validity start
                \\# TYPE tsunagi_mempool_validity_start_reject_total counter
                \\tsunagi_mempool_validity_start_reject_total {d}
                \\
            , .{
                self.metrics.mempool_items.load(.acquire),
                self.metrics.mempool_bytes.load(.acquire),
                self.metrics.mempool_accept_total.load(.acquire),
                self.metrics.mempool_reject_total.load(.acquire),
                self.metrics.mempool_evictions_total.load(.acquire),
                self.metrics.mempool_confirmed_evictions_total.load(.acquire),
                if (self.mempool) |mp| mp.conflict_reject_count else 0,
                if (self.mempool) |mp| mp.missing_input_reject_count else 0,
                if (self.mempool) |mp| mp.balance_reject_count else 0,
                if (self.mempool) |mp| mp.ttl_reject_count else 0,
                if (self.mempool) |mp| mp.validity_start_reject_count else 0,
                if (self.mempool) |mp| mp.fee_insufficient_reject_count else 0,
                if (self.mempool) |mp| mp.min_utxo_reject_count else 0,
                if (self.mempool) |mp| mp.timelock_reject_count else 0,
                if (self.mempool) |mp| mp.witness_invalid_reject_count else 0,
                if (self.mempool) |mp| mp.witness_coverage_reject_count else 0,
                if (self.mempool) |mp| mp.plutus_unsupported_reject_count else 0,
                if (self.mempool) |mp| mp.plutus_txs_seen else 0,
                if (self.mempool) |mp| mp.plutus_with_redeemers else 0,
                if (self.mempool) |mp| mp.plutus_readiness_4_count else 0,
                if (self.mempool) |mp| mp.inputs_key_controlled else 0,
                if (self.mempool) |mp| mp.inputs_script_non_plutus else 0,
                if (self.mempool) |mp| mp.inputs_plutus_definitive else 0,
                if (self.mempool) |mp| mp.inputs_unknown else 0,
            }) catch {};

            // Tx submit admission policy
            wr.print(
                \\# HELP tsunagi_tx_submit_invalid_total Invalid tx submissions rejected by admission policy
                \\# TYPE tsunagi_tx_submit_invalid_total counter
                \\tsunagi_tx_submit_invalid_total {d}
                \\# HELP tsunagi_tx_submit_rate_limited_total Tx submissions rejected by rate limiting
                \\# TYPE tsunagi_tx_submit_rate_limited_total counter
                \\tsunagi_tx_submit_rate_limited_total {d}
                \\
            , .{
                self.metrics.tx_submit_invalid_total.load(.acquire),
                self.metrics.tx_submit_rate_limited_total.load(.acquire),
            }) catch {};

            // Block body hash verification
            wr.print(
                \\# HELP tsunagi_block_body_hash_mismatch_total Block body hash mismatches (header vs computed)
                \\# TYPE tsunagi_block_body_hash_mismatch_total counter
                \\tsunagi_block_body_hash_mismatch_total {d}
                \\# HELP tsunagi_block_body_hash_missing_total Blocks where body hash could not be extracted
                \\# TYPE tsunagi_block_body_hash_missing_total counter
                \\tsunagi_block_body_hash_missing_total {d}
                \\# HELP tsunagi_block_body_hash_verified_total Blocks with successful body hash verification
                \\# TYPE tsunagi_block_body_hash_verified_total counter
                \\tsunagi_block_body_hash_verified_total {d}
                \\# HELP tsunagi_block_body_hash_last_ok_unix Unix timestamp of last successful body hash verification
                \\# TYPE tsunagi_block_body_hash_last_ok_unix gauge
                \\tsunagi_block_body_hash_last_ok_unix {d}
                \\# HELP tsunagi_block_body_hash_last_fail_unix Unix timestamp of last body hash mismatch (0 if never)
                \\# TYPE tsunagi_block_body_hash_last_fail_unix gauge
                \\tsunagi_block_body_hash_last_fail_unix {d}
                \\# HELP tsunagi_block_body_hash_reject_total Blocks rejected due to body hash mismatch (decode/apply skipped)
                \\# TYPE tsunagi_block_body_hash_reject_total counter
                \\tsunagi_block_body_hash_reject_total {d}
                \\
            , .{
                self.metrics.block_body_hash_mismatch_total.load(.acquire),
                self.metrics.block_body_hash_missing_total.load(.acquire),
                self.metrics.block_body_hash_verified_total.load(.acquire),
                self.metrics.block_body_hash_last_ok_unix.load(.acquire),
                self.metrics.block_body_hash_last_fail_unix.load(.acquire),
                self.metrics.block_body_hash_reject_total.load(.acquire),
            }) catch {};

            // Header probe (multi-peer tip comparison)
            wr.print(
                \\# HELP tsunagi_header_probe_success_total Successful header probe connections
                \\# TYPE tsunagi_header_probe_success_total counter
                \\tsunagi_header_probe_success_total {d}
                \\# HELP tsunagi_header_probe_fail_total Failed header probe connections
                \\# TYPE tsunagi_header_probe_fail_total counter
                \\tsunagi_header_probe_fail_total {d}
                \\# HELP tsunagi_header_probe_switch_total Peer switches triggered by probe
                \\# TYPE tsunagi_header_probe_switch_total counter
                \\tsunagi_header_probe_switch_total {d}
                \\# HELP tsunagi_header_probe_best_slot Best slot seen from probed peer
                \\# TYPE tsunagi_header_probe_best_slot gauge
                \\tsunagi_header_probe_best_slot {d}
                \\# HELP tsunagi_header_probe_best_block Best block seen from probed peer
                \\# TYPE tsunagi_header_probe_best_block gauge
                \\tsunagi_header_probe_best_block {d}
                \\# HELP tsunagi_header_probe_best_peer_index Index of last probed peer
                \\# TYPE tsunagi_header_probe_best_peer_index gauge
                \\tsunagi_header_probe_best_peer_index {d}
                \\# HELP tsunagi_header_probe_integrity_ok_total Probes that passed integrity check
                \\# TYPE tsunagi_header_probe_integrity_ok_total counter
                \\tsunagi_header_probe_integrity_ok_total {d}
                \\# HELP tsunagi_header_probe_integrity_fail_total Probes that failed integrity check
                \\# TYPE tsunagi_header_probe_integrity_fail_total counter
                \\tsunagi_header_probe_integrity_fail_total {d}
                \\
            , .{
                self.metrics.header_probe_success_total.load(.acquire),
                self.metrics.header_probe_fail_total.load(.acquire),
                self.metrics.header_probe_switch_total.load(.acquire),
                self.metrics.header_probe_best_slot.load(.acquire),
                self.metrics.header_probe_best_block.load(.acquire),
                self.metrics.header_probe_best_peer_index.load(.acquire),
                self.metrics.header_probe_integrity_ok_total.load(.acquire),
                self.metrics.header_probe_integrity_fail_total.load(.acquire),
            }) catch {};

            // Stall detection
            wr.print(
                \\# HELP tsunagi_peer_stall_detect_total Stall detection events (no roll-forward)
                \\# TYPE tsunagi_peer_stall_detect_total counter
                \\tsunagi_peer_stall_detect_total {d}
                \\# HELP tsunagi_probe_switch_due_to_stall_total Peer switches triggered by stall + probe
                \\# TYPE tsunagi_probe_switch_due_to_stall_total counter
                \\tsunagi_probe_switch_due_to_stall_total {d}
                \\# HELP tsunagi_peer_last_roll_fwd_unix Unix timestamp of last roll-forward
                \\# TYPE tsunagi_peer_last_roll_fwd_unix gauge
                \\tsunagi_peer_last_roll_fwd_unix {d}
                \\# HELP tsunagi_peer_stall_active Whether peer is currently stalled (0/1)
                \\# TYPE tsunagi_peer_stall_active gauge
                \\tsunagi_peer_stall_active {d}
                \\
            , .{
                self.metrics.peer_stall_detect_total.load(.acquire),
                self.metrics.probe_switch_due_to_stall_total.load(.acquire),
                self.metrics.peer_last_roll_fwd_unix.load(.acquire),
                self.metrics.peer_stall_active.load(.acquire),
            }) catch {};

            // Chain selection policy
            wr.print(
                \\# HELP tsunagi_chain_select_switch_total Score-based peer switches
                \\# TYPE tsunagi_chain_select_switch_total counter
                \\tsunagi_chain_select_switch_total {d}
                \\# HELP tsunagi_chain_select_score_current_last Current peer score (last evaluation)
                \\# TYPE tsunagi_chain_select_score_current_last gauge
                \\tsunagi_chain_select_score_current_last {d}
                \\# HELP tsunagi_chain_select_score_best_last Best probed peer score (last evaluation)
                \\# TYPE tsunagi_chain_select_score_best_last gauge
                \\tsunagi_chain_select_score_best_last {d}
                \\# HELP tsunagi_chain_select_last_reason_code Last switch reason (1=slot 2=height 3=stall 4=rollback 5=density 6=bayes)
                \\# TYPE tsunagi_chain_select_last_reason_code gauge
                \\tsunagi_chain_select_last_reason_code {d}
                \\
            , .{
                self.metrics.chain_select_switch_total.load(.acquire),
                self.metrics.chain_select_score_current_last.load(.acquire),
                self.metrics.chain_select_score_best_last.load(.acquire),
                self.metrics.chain_select_last_reason_code.load(.acquire),
            }) catch {};

            // LMDB backfill autopilot
            wr.print(
                \\# HELP tsunagi_backfill_blocks_total Blocks applied by backfill autopilot
                \\# TYPE tsunagi_backfill_blocks_total counter
                \\tsunagi_backfill_blocks_total {d}
                \\# HELP tsunagi_backfill_runs_total Backfill runs completed
                \\# TYPE tsunagi_backfill_runs_total counter
                \\tsunagi_backfill_runs_total {d}
                \\# HELP tsunagi_backfill_errors_total Backfill decode/apply errors
                \\# TYPE tsunagi_backfill_errors_total counter
                \\tsunagi_backfill_errors_total {d}
                \\# HELP tsunagi_backfill_busy_total Backfill skipped (LMDB busy)
                \\# TYPE tsunagi_backfill_busy_total counter
                \\tsunagi_backfill_busy_total {d}
                \\# HELP tsunagi_backfill_last_unix Unix timestamp of last backfill run
                \\# TYPE tsunagi_backfill_last_unix gauge
                \\tsunagi_backfill_last_unix {d}
                \\# HELP tsunagi_backfill_last_blocks Blocks applied in last backfill run
                \\# TYPE tsunagi_backfill_last_blocks gauge
                \\tsunagi_backfill_last_blocks {d}
                \\# HELP tsunagi_backfill_cursor_offset Current backfill cursor offset
                \\# TYPE tsunagi_backfill_cursor_offset gauge
                \\tsunagi_backfill_cursor_offset {d}
                \\
            , .{
                self.metrics.backfill_blocks_total.load(.acquire),
                self.metrics.backfill_runs_total.load(.acquire),
                self.metrics.backfill_errors_total.load(.acquire),
                self.metrics.backfill_busy_total.load(.acquire),
                self.metrics.backfill_last_unix.load(.acquire),
                self.metrics.backfill_last_blocks.load(.acquire),
                self.metrics.backfill_cursor_offset.load(.acquire),
            }) catch {};

            // Backfill segment progress
            {
                const sd_x1e6 = self.metrics.backfill_segment_done_x1e6.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_backfill_file_count_last Number of capture files found
                    \\# TYPE tsunagi_backfill_file_count_last gauge
                    \\tsunagi_backfill_file_count_last {d}
                    \\# HELP tsunagi_backfill_file_index_last Current file index (0-based)
                    \\# TYPE tsunagi_backfill_file_index_last gauge
                    \\tsunagi_backfill_file_index_last {d}
                    \\# HELP tsunagi_backfill_file_size_bytes_last Size of current file in bytes
                    \\# TYPE tsunagi_backfill_file_size_bytes_last gauge
                    \\tsunagi_backfill_file_size_bytes_last {d}
                    \\# HELP tsunagi_backfill_segment_done_ratio Segment completion ratio (0.0-1.0)
                    \\# TYPE tsunagi_backfill_segment_done_ratio gauge
                    \\tsunagi_backfill_segment_done_ratio {d}.{d:0>6}
                    \\
                , .{
                    self.metrics.backfill_file_count_last.load(.acquire),
                    self.metrics.backfill_file_index_last.load(.acquire),
                    self.metrics.backfill_file_size_bytes_last.load(.acquire),
                    sd_x1e6 / 1_000_000,
                    sd_x1e6 % 1_000_000,
                }) catch {};
            }

            // Adaptive throttle metrics
            {
                const arb = self.metrics.backfill_adapt_rec_blocks.load(.acquire);
                if (arb > 0) {
                    wr.print(
                        \\# HELP tsunagi_backfill_adapt_peer_closed Peer-closed count seen by adaptive throttle
                        \\# TYPE tsunagi_backfill_adapt_peer_closed gauge
                        \\tsunagi_backfill_adapt_peer_closed {d}
                        \\# HELP tsunagi_backfill_adapt_keepalive_to Keepalive timeouts seen by adaptive throttle
                        \\# TYPE tsunagi_backfill_adapt_keepalive_to gauge
                        \\tsunagi_backfill_adapt_keepalive_to {d}
                        \\# HELP tsunagi_backfill_adapt_block_us Block processing time seen by adaptive throttle
                        \\# TYPE tsunagi_backfill_adapt_block_us gauge
                        \\tsunagi_backfill_adapt_block_us {d}
                        \\# HELP tsunagi_backfill_adapt_rec_blocks Recommended max_blocks from adaptive throttle
                        \\# TYPE tsunagi_backfill_adapt_rec_blocks gauge
                        \\tsunagi_backfill_adapt_rec_blocks {d}
                        \\# HELP tsunagi_backfill_adapt_rec_seconds Recommended max_seconds from adaptive throttle
                        \\# TYPE tsunagi_backfill_adapt_rec_seconds gauge
                        \\tsunagi_backfill_adapt_rec_seconds {d}
                        \\
                    , .{
                        self.metrics.backfill_adapt_peer_closed.load(.acquire),
                        self.metrics.backfill_adapt_keepalive_to.load(.acquire),
                        self.metrics.backfill_adapt_block_us.load(.acquire),
                        arb,
                        self.metrics.backfill_adapt_rec_seconds.load(.acquire),
                    }) catch {};
                }
            }

            // Cursor resync metrics
            {
                const cr_ds = self.metrics.backfill_cursor_desync_total.load(.acquire);
                const cr_rs = self.metrics.backfill_cursor_resync_total.load(.acquire);
                const cr_rf = self.metrics.backfill_cursor_resync_fail_total.load(.acquire);
                const cr_ru = self.metrics.backfill_cursor_resync_last_unix.load(.acquire);
                if (cr_ds > 0 or cr_rs > 0 or cr_rf > 0) {
                    wr.print(
                        \\# HELP tsunagi_backfill_cursor_desync_total Cursor desync detections
                        \\# TYPE tsunagi_backfill_cursor_desync_total counter
                        \\tsunagi_backfill_cursor_desync_total {d}
                        \\# HELP tsunagi_backfill_cursor_resync_total Successful cursor resyncs
                        \\# TYPE tsunagi_backfill_cursor_resync_total counter
                        \\tsunagi_backfill_cursor_resync_total {d}
                        \\# HELP tsunagi_backfill_cursor_resync_fail_total Failed cursor resync attempts
                        \\# TYPE tsunagi_backfill_cursor_resync_fail_total counter
                        \\tsunagi_backfill_cursor_resync_fail_total {d}
                        \\# HELP tsunagi_backfill_cursor_resync_last_unix Last successful resync timestamp
                        \\# TYPE tsunagi_backfill_cursor_resync_last_unix gauge
                        \\tsunagi_backfill_cursor_resync_last_unix {d}
                        \\
                    , .{ cr_ds, cr_rs, cr_rf, cr_ru }) catch {};
                }
            }

            // EOF idle metrics
            {
                const ei_total = self.metrics.backfill_eof_idle_total.load(.acquire);
                const ei_unix = self.metrics.backfill_eof_idle_last_unix.load(.acquire);
                if (ei_total > 0) {
                    wr.print(
                        \\# HELP tsunagi_backfill_eof_idle_total EOF idle detections (cursor at end, no new records)
                        \\# TYPE tsunagi_backfill_eof_idle_total counter
                        \\tsunagi_backfill_eof_idle_total {d}
                        \\# HELP tsunagi_backfill_eof_idle_last_unix Last EOF idle timestamp
                        \\# TYPE tsunagi_backfill_eof_idle_last_unix gauge
                        \\tsunagi_backfill_eof_idle_last_unix {d}
                        \\
                    , .{ ei_total, ei_unix }) catch {};
                }
            }

            // Idle skip metrics
            {
                const is_total = self.metrics.backfill_idle_skips_total.load(.acquire);
                const is_unix = self.metrics.backfill_idle_last_unix.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_backfill_idle_skips_total Runs skipped (no new bytes at cursor)
                    \\# TYPE tsunagi_backfill_idle_skips_total counter
                    \\tsunagi_backfill_idle_skips_total {d}
                    \\# HELP tsunagi_backfill_idle_last_unix Last idle skip timestamp
                    \\# TYPE tsunagi_backfill_idle_last_unix gauge
                    \\tsunagi_backfill_idle_last_unix {d}
                    \\
                , .{ is_total, is_unix }) catch {};
            }

            // Segment cleanup metrics
            {
                const sd_total = self.metrics.backfill_segments_deleted_total.load(.acquire);
                const sd_bytes = self.metrics.backfill_segments_deleted_bytes_total.load(.acquire);
                const cf_active = self.metrics.backfill_current_file_is_active.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_backfill_segments_deleted_total Fully-consumed rotated segments deleted
                    \\# TYPE tsunagi_backfill_segments_deleted_total counter
                    \\tsunagi_backfill_segments_deleted_total {d}
                    \\# HELP tsunagi_backfill_segments_deleted_bytes_total Bytes freed by segment deletion
                    \\# TYPE tsunagi_backfill_segments_deleted_bytes_total counter
                    \\tsunagi_backfill_segments_deleted_bytes_total {d}
                    \\# HELP tsunagi_backfill_current_file_is_active Cursor on active capture file (1) or rotated segment (0)
                    \\# TYPE tsunagi_backfill_current_file_is_active gauge
                    \\tsunagi_backfill_current_file_is_active {d}
                    \\
                , .{ sd_total, sd_bytes, cf_active }) catch {};
            }

            // Capture observability
            {
                const cap_main = self.metrics.capture_mainnet_bin_bytes.load(.acquire);
                const cap_seg_c = self.metrics.capture_segments_count.load(.acquire);
                const cap_seg_b = self.metrics.capture_segments_bytes_total.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_capture_mainnet_bin_bytes Size of active capture file
                    \\# TYPE tsunagi_capture_mainnet_bin_bytes gauge
                    \\tsunagi_capture_mainnet_bin_bytes {d}
                    \\# HELP tsunagi_capture_segments_count Number of rotated capture segments
                    \\# TYPE tsunagi_capture_segments_count gauge
                    \\tsunagi_capture_segments_count {d}
                    \\# HELP tsunagi_capture_segments_bytes_total Total bytes in rotated segments
                    \\# TYPE tsunagi_capture_segments_bytes_total gauge
                    \\tsunagi_capture_segments_bytes_total {d}
                    \\
                , .{ cap_main, cap_seg_c, cap_seg_b }) catch {};
                const cap_rot_mb = self.metrics.capture_rotate_mb.load(.acquire);
                const cap_rot_b = self.metrics.capture_rotate_bytes.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_capture_rotate_mb Capture rotation threshold in MB
                    \\# TYPE tsunagi_capture_rotate_mb gauge
                    \\tsunagi_capture_rotate_mb {d}
                    \\# HELP tsunagi_capture_rotate_bytes Capture rotation threshold in bytes
                    \\# TYPE tsunagi_capture_rotate_bytes gauge
                    \\tsunagi_capture_rotate_bytes {d}
                    \\
                , .{ cap_rot_mb, cap_rot_b }) catch {};
            }

            // Convergence gate
            {
                const cg_ready = self.metrics.convergence_gate_ready.load(.acquire);
                const cg_unix = self.metrics.convergence_gate_ready_unix.load(.acquire);
                const cg_stable = self.metrics.convergence_gate_stable_seconds.load(.acquire);
                const cg_truth = self.metrics.convergence_gate_truth_ratio_x1e6.load(.acquire);
                const cg_vc = self.metrics.convergence_gate_value_check_ratio_x1e6.load(.acquire);
                const cg_ema = self.metrics.convergence_gate_missing_ema.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_convergence_ready Convergence gate ready (truth>=0.80, value>=0.80, ema<=1, stable 600s)
                    \\# TYPE tsunagi_convergence_ready gauge
                    \\tsunagi_convergence_ready {d}
                    \\# HELP tsunagi_convergence_ready_unix Unix timestamp when convergence became stable-ready
                    \\# TYPE tsunagi_convergence_ready_unix gauge
                    \\tsunagi_convergence_ready_unix {d}
                    \\# HELP tsunagi_convergence_ready_stable_seconds Seconds continuously ready
                    \\# TYPE tsunagi_convergence_ready_stable_seconds gauge
                    \\tsunagi_convergence_ready_stable_seconds {d}
                    \\# HELP tsunagi_convergence_truth_ratio_last LMDB truth ratio (0.0-1.0)
                    \\# TYPE tsunagi_convergence_truth_ratio_last gauge
                    \\tsunagi_convergence_truth_ratio_last {d}.{d:0>6}
                    \\# HELP tsunagi_convergence_value_check_ratio_last Ledger value check ratio (0.0-1.0)
                    \\# TYPE tsunagi_convergence_value_check_ratio_last gauge
                    \\tsunagi_convergence_value_check_ratio_last {d}.{d:0>6}
                    \\# HELP tsunagi_convergence_missing_ema_last Ledger missing inputs EMA
                    \\# TYPE tsunagi_convergence_missing_ema_last gauge
                    \\tsunagi_convergence_missing_ema_last {d}
                    \\
                , .{
                    cg_ready,
                    cg_unix,
                    cg_stable,
                    cg_truth / 1_000_000, cg_truth % 1_000_000,
                    cg_vc / 1_000_000, cg_vc % 1_000_000,
                    cg_ema,
                }) catch {};
            }

            // Gap hunter
            {
                const gk = self.metrics.gap_missing_keys.load(.acquire);
                const ge = self.metrics.gap_missing_events_total.load(.acquire);
                const gr = self.metrics.gap_resolved_total.load(.acquire);
                const grl = self.metrics.gap_resolved_last.load(.acquire);
                const gul = self.metrics.gap_unresolved_last.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_gap_missing_keys Current number of tracked missing TxIn keys
                    \\# TYPE tsunagi_gap_missing_keys gauge
                    \\tsunagi_gap_missing_keys {d}
                    \\# HELP tsunagi_gap_missing_events_total Cumulative missing-input detection events
                    \\# TYPE tsunagi_gap_missing_events_total counter
                    \\tsunagi_gap_missing_events_total {d}
                    \\# HELP tsunagi_gap_resolved_total Cumulative gap keys resolved by backfill
                    \\# TYPE tsunagi_gap_resolved_total counter
                    \\tsunagi_gap_resolved_total {d}
                    \\# HELP tsunagi_gap_resolved_last Gap keys resolved in last backfill run
                    \\# TYPE tsunagi_gap_resolved_last gauge
                    \\tsunagi_gap_resolved_last {d}
                    \\# HELP tsunagi_gap_unresolved_last Gap keys still unresolved after last backfill run
                    \\# TYPE tsunagi_gap_unresolved_last gauge
                    \\tsunagi_gap_unresolved_last {d}
                    \\
                , .{ gk, ge, gr, grl, gul }) catch {};

                // Gap hunter v2
                const g_htc = self.metrics.gap_hot_top_count.load(.acquire);
                const g_hta = self.metrics.gap_hot_top_age_seconds.load(.acquire);
                const g_rr = self.metrics.gap_repeat_ratio_x1e6.load(.acquire);
                const g_nkw = self.metrics.gap_new_keys_window.load(.acquire);
                const g_mew = self.metrics.gap_missing_events_window.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_gap_hot_top_count Hit count of the hottest missing key
                    \\# TYPE tsunagi_gap_hot_top_count gauge
                    \\tsunagi_gap_hot_top_count {d}
                    \\# HELP tsunagi_gap_hot_top_age_seconds Age in seconds of the hottest missing key
                    \\# TYPE tsunagi_gap_hot_top_age_seconds gauge
                    \\tsunagi_gap_hot_top_age_seconds {d}
                    \\# HELP tsunagi_gap_repeat_ratio Fraction of missing events that are repeats (0.0-1.0)
                    \\# TYPE tsunagi_gap_repeat_ratio gauge
                    \\tsunagi_gap_repeat_ratio {d}.{d:0>6}
                    \\# HELP tsunagi_gap_new_keys_window New gap keys discovered in current window
                    \\# TYPE tsunagi_gap_new_keys_window gauge
                    \\tsunagi_gap_new_keys_window {d}
                    \\# HELP tsunagi_gap_missing_events_window Missing-input events in current window
                    \\# TYPE tsunagi_gap_missing_events_window gauge
                    \\tsunagi_gap_missing_events_window {d}
                    \\
                , .{ g_htc, g_hta, g_rr / 1_000_000, g_rr % 1_000_000, g_nkw, g_mew }) catch {};

                // Gap hunter v3 — eviction
                const g_ev = self.metrics.gap_evictions_total.load(.acquire);
                const g_cap = self.metrics.gap_keys_cap.load(.acquire);
                const g_old = self.metrics.gap_oldest_last_seen_age_seconds.load(.acquire);
                const g_cpd = self.metrics.gap_capped.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_gap_evictions_total Cumulative LRU evictions from gap key set
                    \\# TYPE tsunagi_gap_evictions_total counter
                    \\tsunagi_gap_evictions_total {d}
                    \\# HELP tsunagi_gap_keys_cap Maximum number of tracked gap keys
                    \\# TYPE tsunagi_gap_keys_cap gauge
                    \\tsunagi_gap_keys_cap {d}
                    \\# HELP tsunagi_gap_oldest_last_seen_age_seconds Age of least-recently-seen gap key
                    \\# TYPE tsunagi_gap_oldest_last_seen_age_seconds gauge
                    \\tsunagi_gap_oldest_last_seen_age_seconds {d}
                    \\# HELP tsunagi_gap_capped Whether gap key set is at capacity (0 or 1)
                    \\# TYPE tsunagi_gap_capped gauge
                    \\tsunagi_gap_capped {d}
                    \\
                , .{ g_ev, g_cap, g_old, g_cpd }) catch {};

                // Gap hunter last_seen observability
                const g_lsl = self.metrics.gap_last_seen_loaded.load(.acquire);
                const g_lsfb = self.metrics.gap_last_seen_file_bytes.load(.acquire);
                const g_lspe = self.metrics.gap_last_seen_parse_errors_total.load(.acquire);
                const g_lsi = self.metrics.gap_last_seen_items.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_gap_last_seen_loaded Number of last_seen entries loaded at startup
                    \\# TYPE tsunagi_gap_last_seen_loaded gauge
                    \\tsunagi_gap_last_seen_loaded {d}
                    \\# HELP tsunagi_gap_last_seen_file_bytes Size of last_seen.json file in bytes
                    \\# TYPE tsunagi_gap_last_seen_file_bytes gauge
                    \\tsunagi_gap_last_seen_file_bytes {d}
                    \\# HELP tsunagi_gap_last_seen_parse_errors_total Cumulative parse errors while loading last_seen
                    \\# TYPE tsunagi_gap_last_seen_parse_errors_total counter
                    \\tsunagi_gap_last_seen_parse_errors_total {d}
                    \\# HELP tsunagi_gap_last_seen_items Current number of entries in last_seen map
                    \\# TYPE tsunagi_gap_last_seen_items gauge
                    \\tsunagi_gap_last_seen_items {d}
                    \\
                , .{ g_lsl, g_lsfb, g_lspe, g_lsi }) catch {};

                // Gap hunter v4 — 5-minute trend + telemetry
                const g_delta_raw = self.metrics.gap_keys_delta_5m.load(.acquire);
                const g_delta: i64 = @as(i64, @intCast(g_delta_raw)) - 10_000_000;
                const g_nk5 = self.metrics.gap_new_keys_5m.load(.acquire);
                const g_res5 = self.metrics.gap_resolved_5m.load(.acquire);
                const g_ev5 = self.metrics.gap_evictions_5m.load(.acquire);
                const g_me5 = self.metrics.gap_missing_events_5m.load(.acquire);
                const g_wage = self.metrics.gap_window_age_seconds.load(.acquire);
                const g_wr = self.metrics.gap_win_rate_x1e6.load(.acquire);
                const g_lsp = self.metrics.gap_last_seen_persist_unix.load(.acquire);
                const g_hc5 = self.metrics.gap_hot_changes_5m.load(.acquire);
                const g_wunix = self.metrics.gap_window_unix.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_gap_keys_delta_5m Net change in gap keys over last 5-minute window
                    \\# TYPE tsunagi_gap_keys_delta_5m gauge
                    \\tsunagi_gap_keys_delta_5m {d}
                    \\# HELP tsunagi_gap_new_keys_5m New gap keys discovered in last 5-minute window
                    \\# TYPE tsunagi_gap_new_keys_5m gauge
                    \\tsunagi_gap_new_keys_5m {d}
                    \\# HELP tsunagi_gap_resolved_5m Gap keys resolved in last 5-minute window
                    \\# TYPE tsunagi_gap_resolved_5m gauge
                    \\tsunagi_gap_resolved_5m {d}
                    \\# HELP tsunagi_gap_evictions_delta_5m LRU evictions in last 5-minute window
                    \\# TYPE tsunagi_gap_evictions_delta_5m gauge
                    \\tsunagi_gap_evictions_delta_5m {d}
                    \\# HELP tsunagi_gap_missing_events_5m Missing-input events in last 5-minute window
                    \\# TYPE tsunagi_gap_missing_events_5m gauge
                    \\tsunagi_gap_missing_events_5m {d}
                    \\# HELP tsunagi_gap_window_age_seconds Seconds since current 5-minute window started
                    \\# TYPE tsunagi_gap_window_age_seconds gauge
                    \\tsunagi_gap_window_age_seconds {d}
                    \\# HELP tsunagi_gap_win_rate Ratio of resolved to new gap keys (>1 = winning)
                    \\# TYPE tsunagi_gap_win_rate gauge
                    \\tsunagi_gap_win_rate {d}.{d:0>6}
                    \\
                , .{ g_delta, g_nk5, g_res5, g_ev5, g_me5, g_wage, g_wr / 1_000_000, g_wr % 1_000_000 }) catch {};
                wr.print(
                    \\# HELP tsunagi_gap_last_seen_persist_unix Unix timestamp of last last_seen persistence
                    \\# TYPE tsunagi_gap_last_seen_persist_unix gauge
                    \\tsunagi_gap_last_seen_persist_unix {d}
                    \\# HELP tsunagi_gap_hot_changes_5m Number of times the hottest gap key changed in last 5-minute window
                    \\# TYPE tsunagi_gap_hot_changes_5m gauge
                    \\tsunagi_gap_hot_changes_5m {d}
                    \\# HELP tsunagi_gap_window_unix Unix timestamp of current 5-minute window start
                    \\# TYPE tsunagi_gap_window_unix gauge
                    \\tsunagi_gap_window_unix {d}
                    \\
                , .{ g_lsp, g_hc5, g_wunix }) catch {};
            }

            // Backfill recommendation
            {
                const rec_pc = self.metrics.backfill_recommend_profile_code.load(.acquire);
                const rec_b = self.metrics.backfill_recommend_blocks.load(.acquire);
                const rec_s = self.metrics.backfill_recommend_seconds.load(.acquire);
                const rec_p = self.metrics.backfill_recommend_pressure.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_backfill_recommend_profile_code Recommended backfill profile (0=cautious 1=normal 2=aggressive)
                    \\# TYPE tsunagi_backfill_recommend_profile_code gauge
                    \\tsunagi_backfill_recommend_profile_code {d}
                    \\# HELP tsunagi_backfill_recommend_blocks Recommended max blocks per backfill run
                    \\# TYPE tsunagi_backfill_recommend_blocks gauge
                    \\tsunagi_backfill_recommend_blocks {d}
                    \\# HELP tsunagi_backfill_recommend_seconds Recommended max seconds per backfill run
                    \\# TYPE tsunagi_backfill_recommend_seconds gauge
                    \\tsunagi_backfill_recommend_seconds {d}
                    \\# HELP tsunagi_backfill_recommend_pressure Gap pressure score driving the recommendation
                    \\# TYPE tsunagi_backfill_recommend_pressure gauge
                    \\tsunagi_backfill_recommend_pressure {d}
                    \\
                , .{ rec_pc, rec_b, rec_s, rec_p }) catch {};
            }

            // Backfill autotune
            {
                const at_en = self.metrics.backfill_autotune_enabled.load(.acquire);
                const at_pr = self.metrics.backfill_autotune_profile_current.load(.acquire);
                const at_cu = self.metrics.backfill_autotune_last_change_unix.load(.acquire);
                const at_sw = self.metrics.backfill_autotune_switch_total.load(.acquire);
                const at_rc = self.metrics.backfill_autotune_reason_code_last.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_backfill_autotune_enabled Backfill autotune enabled (0/1)
                    \\# TYPE tsunagi_backfill_autotune_enabled gauge
                    \\tsunagi_backfill_autotune_enabled {d}
                    \\# HELP tsunagi_backfill_autotune_profile_current Current autotune profile (0=cautious 1=normal 2=aggressive)
                    \\# TYPE tsunagi_backfill_autotune_profile_current gauge
                    \\tsunagi_backfill_autotune_profile_current {d}
                    \\# HELP tsunagi_backfill_autotune_last_change_unix Unix timestamp of last profile switch
                    \\# TYPE tsunagi_backfill_autotune_last_change_unix gauge
                    \\tsunagi_backfill_autotune_last_change_unix {d}
                    \\# HELP tsunagi_backfill_autotune_switch_total Cumulative autotune profile switches
                    \\# TYPE tsunagi_backfill_autotune_switch_total counter
                    \\tsunagi_backfill_autotune_switch_total {d}
                    \\# HELP tsunagi_backfill_autotune_reason_code_last Reason code for last autotune decision
                    \\# TYPE tsunagi_backfill_autotune_reason_code_last gauge
                    \\tsunagi_backfill_autotune_reason_code_last {d}
                    \\
                , .{ at_en, at_pr, at_cu, at_sw, at_rc }) catch {};
            }

            // Backfill gap steering
            {
                const ght = self.metrics.backfill_gap_hit_total.load(.acquire);
                const ghl = self.metrics.backfill_gap_hit_last.load(.acquire);
                const ghr = self.metrics.backfill_gap_hit_ratio_x1e6.load(.acquire);
                const gkl = self.metrics.backfill_gap_keys_loaded_last.load(.acquire);
                const gpt = self.metrics.backfill_produced_total_last.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_backfill_gap_hit_total Cumulative produced outputs matching gap keys
                    \\# TYPE tsunagi_backfill_gap_hit_total counter
                    \\tsunagi_backfill_gap_hit_total {d}
                    \\# HELP tsunagi_backfill_gap_hit_last Gap key hits in last backfill run
                    \\# TYPE tsunagi_backfill_gap_hit_last gauge
                    \\tsunagi_backfill_gap_hit_last {d}
                    \\# HELP tsunagi_backfill_gap_hit_ratio Gap hit ratio in last backfill run (0.0-1.0)
                    \\# TYPE tsunagi_backfill_gap_hit_ratio gauge
                    \\tsunagi_backfill_gap_hit_ratio {d}.{d:0>6}
                    \\# HELP tsunagi_backfill_gap_keys_loaded_last Gap keys loaded at start of last backfill run
                    \\# TYPE tsunagi_backfill_gap_keys_loaded_last gauge
                    \\tsunagi_backfill_gap_keys_loaded_last {d}
                    \\# HELP tsunagi_backfill_produced_total_last Produced outputs observed in last backfill run
                    \\# TYPE tsunagi_backfill_produced_total_last gauge
                    \\tsunagi_backfill_produced_total_last {d}
                    \\
                , .{ ght, ghl, ghr / 1_000_000, ghr % 1_000_000, gkl, gpt }) catch {};
            }

            // Backfill gap consumed coverage
            {
                const gcst = self.metrics.backfill_gap_consumed_seen_total.load(.acquire);
                const gcrt = self.metrics.backfill_gap_consumed_resolved_total.load(.acquire);
                const gcsl = self.metrics.backfill_gap_consumed_seen_last.load(.acquire);
                const gcrl = self.metrics.backfill_gap_consumed_resolved_last.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_backfill_gap_consumed_seen_total Cumulative consumed TxIns matching gap keys
                    \\# TYPE tsunagi_backfill_gap_consumed_seen_total counter
                    \\tsunagi_backfill_gap_consumed_seen_total {d}
                    \\# HELP tsunagi_backfill_gap_consumed_resolved_total Cumulative consumed gap keys resolved in LMDB
                    \\# TYPE tsunagi_backfill_gap_consumed_resolved_total counter
                    \\tsunagi_backfill_gap_consumed_resolved_total {d}
                    \\# HELP tsunagi_backfill_gap_consumed_seen_last Consumed gap keys seen in last backfill run
                    \\# TYPE tsunagi_backfill_gap_consumed_seen_last gauge
                    \\tsunagi_backfill_gap_consumed_seen_last {d}
                    \\# HELP tsunagi_backfill_gap_consumed_resolved_last Consumed gap keys resolved in last backfill run
                    \\# TYPE tsunagi_backfill_gap_consumed_resolved_last gauge
                    \\tsunagi_backfill_gap_consumed_resolved_last {d}
                    \\
                , .{ gcst, gcrt, gcsl, gcrl }) catch {};
            }

            // BAEY audit log + adaptive weights
            {
                const safe = if (isSafeModeActive(self.alloc)) @as(u64, 1) else @as(u64, 0);
                self.metrics.baey_safe_mode_enabled.store(safe, .release);

                const bw = readBaeyWeights(self.alloc);
                self.metrics.baey_weight_stall.store(bw.stall, .release);
                self.metrics.baey_weight_density.store(bw.density, .release);
                self.metrics.baey_weight_header.store(bw.header, .release);
                self.metrics.baey_weight_keepalive.store(bw.keepalive, .release);
                self.metrics.baey_weight_gap.store(bw.gap, .release);
                self.metrics.baey_weight_authority.store(bw.authority, .release);
                self.metrics.baey_weight_finality.store(bw.finality, .release);

                wr.print(
                    \\# HELP tsunagi_baey_events_total Cumulative BAEY audit log events written
                    \\# TYPE tsunagi_baey_events_total counter
                    \\tsunagi_baey_events_total {d}
                    \\# HELP tsunagi_baey_last_event_unix Unix timestamp of last BAEY event
                    \\# TYPE tsunagi_baey_last_event_unix gauge
                    \\tsunagi_baey_last_event_unix {d}
                    \\# HELP tsunagi_baey_safe_mode_enabled BAEY safe mode active (1=yes 0=no)
                    \\# TYPE tsunagi_baey_safe_mode_enabled gauge
                    \\tsunagi_baey_safe_mode_enabled {d}
                    \\
                , .{
                    self.metrics.baey_events_total.load(.acquire),
                    self.metrics.baey_last_event_unix.load(.acquire),
                    safe,
                }) catch {};

                wr.print(
                    \\# HELP tsunagi_baey_weight_stall BAEY adaptive weight: stall (x1e6)
                    \\# TYPE tsunagi_baey_weight_stall gauge
                    \\tsunagi_baey_weight_stall {d}
                    \\# HELP tsunagi_baey_weight_density BAEY adaptive weight: density (x1e6)
                    \\# TYPE tsunagi_baey_weight_density gauge
                    \\tsunagi_baey_weight_density {d}
                    \\# HELP tsunagi_baey_weight_header BAEY adaptive weight: header_err (x1e6)
                    \\# TYPE tsunagi_baey_weight_header gauge
                    \\tsunagi_baey_weight_header {d}
                    \\# HELP tsunagi_baey_weight_keepalive BAEY adaptive weight: keepalive (x1e6)
                    \\# TYPE tsunagi_baey_weight_keepalive gauge
                    \\tsunagi_baey_weight_keepalive {d}
                    \\# HELP tsunagi_baey_weight_gap BAEY adaptive weight: gap (x1e6)
                    \\# TYPE tsunagi_baey_weight_gap gauge
                    \\tsunagi_baey_weight_gap {d}
                    \\# HELP tsunagi_baey_weight_authority BAEY adaptive weight: authority (x1e6)
                    \\# TYPE tsunagi_baey_weight_authority gauge
                    \\tsunagi_baey_weight_authority {d}
                    \\# HELP tsunagi_baey_weight_finality BAEY adaptive weight: finality (x1e6)
                    \\# TYPE tsunagi_baey_weight_finality gauge
                    \\tsunagi_baey_weight_finality {d}
                    \\
                , .{
                    bw.stall, bw.density, bw.header, bw.keepalive, bw.gap, bw.authority, bw.finality,
                }) catch {};

                const ls = readBaeyLoopStats(self.alloc);
                wr.print(
                    \\# HELP tsunagi_baey_loop_fetch_ms_last BAEY loop last /state fetch latency (ms)
                    \\# TYPE tsunagi_baey_loop_fetch_ms_last gauge
                    \\tsunagi_baey_loop_fetch_ms_last {d}
                    \\# HELP tsunagi_baey_loop_total_ms_last BAEY loop last total iteration time (ms)
                    \\# TYPE tsunagi_baey_loop_total_ms_last gauge
                    \\tsunagi_baey_loop_total_ms_last {d}
                    \\# HELP tsunagi_baey_loop_parse_ok BAEY loop last parse success (1=ok 0=fail)
                    \\# TYPE tsunagi_baey_loop_parse_ok gauge
                    \\tsunagi_baey_loop_parse_ok {d}
                    \\
                , .{ ls.fetch_ms, ls.total_ms, ls.parse_ok }) catch {};

                // BAeY v1.2.2 counters
                wr.print(
                    \\# HELP tsunagi_baey_switches_total Peer switches triggered by BAeY
                    \\# TYPE tsunagi_baey_switches_total counter
                    \\tsunagi_baey_switches_total {d}
                    \\# HELP tsunagi_baey_penalty_rate_limited_total Penalties skipped by rate limiter
                    \\# TYPE tsunagi_baey_penalty_rate_limited_total counter
                    \\tsunagi_baey_penalty_rate_limited_total {d}
                    \\
                , .{
                    self.metrics.baey_switches_total.load(.acquire),
                    self.metrics.baey_penalty_rate_limited_total.load(.acquire),
                }) catch {};
            }

            // Block producer skeleton
            {
                wr.print(
                    \\# HELP tsunagi_producer_state Producer state (0=Disabled,1=Tracking,2=Candidate,3=Leader)
                    \\# TYPE tsunagi_producer_state gauge
                    \\tsunagi_producer_state {d}
                    \\# HELP tsunagi_producer_last_slot_checked Last slot checked by producer tick
                    \\# TYPE tsunagi_producer_last_slot_checked gauge
                    \\tsunagi_producer_last_slot_checked {d}
                    \\# HELP tsunagi_producer_last_leader_slot Last slot where leader election succeeded
                    \\# TYPE tsunagi_producer_last_leader_slot gauge
                    \\tsunagi_producer_last_leader_slot {d}
                    \\# HELP tsunagi_producer_leader_checks_total Cumulative leader election checks
                    \\# TYPE tsunagi_producer_leader_checks_total counter
                    \\tsunagi_producer_leader_checks_total {d}
                    \\
                , .{
                    self.metrics.producer_state.load(.acquire),
                    self.metrics.producer_last_slot_checked.load(.acquire),
                    self.metrics.producer_last_leader_slot.load(.acquire),
                    self.metrics.producer_leader_checks_total.load(.acquire),
                }) catch {};

                // Slot clock + drift
                const p_obs = self.metrics.producer_observed_slot.load(.acquire);
                const p_est = self.metrics.producer_estimated_slot.load(.acquire);
                const p_drift_raw = self.metrics.producer_drift_last_slots.load(.acquire);
                const p_drift_signed: i64 = @as(i64, @intCast(p_drift_raw)) - 10_000_000;
                const p_abs_max = self.metrics.producer_drift_abs_max.load(.acquire);
                const p_abs_last = self.metrics.producer_drift_abs_last.load(.acquire);
                const p_drift_ev = self.metrics.producer_drift_events_total.load(.acquire);
                const p_clock_ok = self.metrics.producer_clock_ok.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_producer_observed_slot Last observed slot from chain
                    \\# TYPE tsunagi_producer_observed_slot gauge
                    \\tsunagi_producer_observed_slot {d}
                    \\# HELP tsunagi_producer_estimated_slot Estimated slot from genesis wall clock
                    \\# TYPE tsunagi_producer_estimated_slot gauge
                    \\tsunagi_producer_estimated_slot {d}
                    \\# HELP tsunagi_producer_drift_last_slots Signed drift (observed - estimated) in slots
                    \\# TYPE tsunagi_producer_drift_last_slots gauge
                    \\tsunagi_producer_drift_last_slots {d}
                    \\# HELP tsunagi_producer_drift_abs_last Absolute value of last drift in slots
                    \\# TYPE tsunagi_producer_drift_abs_last gauge
                    \\tsunagi_producer_drift_abs_last {d}
                    \\# HELP tsunagi_producer_drift_abs_max Maximum absolute drift observed
                    \\# TYPE tsunagi_producer_drift_abs_max gauge
                    \\tsunagi_producer_drift_abs_max {d}
                    \\# HELP tsunagi_producer_drift_events_total Drift events where abs >= 120 slots
                    \\# TYPE tsunagi_producer_drift_events_total counter
                    \\tsunagi_producer_drift_events_total {d}
                    \\# HELP tsunagi_producer_clock_ok 1 when genesis parsed and slot_length >= 1
                    \\# TYPE tsunagi_producer_clock_ok gauge
                    \\tsunagi_producer_clock_ok {d}
                    \\
                , .{ p_obs, p_est, p_drift_signed, p_abs_last, p_abs_max, p_drift_ev, p_clock_ok }) catch {};
            }

            // Genesis loader
            {
                const g_unix = self.metrics.producer_genesis_unix.load(.acquire);
                const g_slot_len = self.metrics.producer_slot_length_s.load(.acquire);
                const g_parse_ok = self.metrics.producer_genesis_parse_ok.load(.acquire);
                const g_path_ok = self.metrics.producer_genesis_path_ok.load(.acquire);
                const g_err = self.metrics.producer_genesis_last_error_code.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_producer_genesis_unix Genesis systemStart as unix timestamp
                    \\# TYPE tsunagi_producer_genesis_unix gauge
                    \\tsunagi_producer_genesis_unix {d}
                    \\# HELP tsunagi_producer_slot_length_s Slot length from genesis in seconds
                    \\# TYPE tsunagi_producer_slot_length_s gauge
                    \\tsunagi_producer_slot_length_s {d}
                    \\# HELP tsunagi_producer_genesis_parse_ok 1 if genesis was parsed successfully
                    \\# TYPE tsunagi_producer_genesis_parse_ok gauge
                    \\tsunagi_producer_genesis_parse_ok {d}
                    \\# HELP tsunagi_producer_genesis_path_ok 1 if genesis file path was found
                    \\# TYPE tsunagi_producer_genesis_path_ok gauge
                    \\tsunagi_producer_genesis_path_ok {d}
                    \\# HELP tsunagi_producer_genesis_last_error_code Last genesis error code (0=ok)
                    \\# TYPE tsunagi_producer_genesis_last_error_code gauge
                    \\tsunagi_producer_genesis_last_error_code {d}
                    \\
                , .{ g_unix, g_slot_len, g_parse_ok, g_path_ok, g_err }) catch {};
            }

            // Leader check skeleton
            {
                const l_epoch = self.metrics.producer_epoch_last.load(.acquire);
                const l_sie = self.metrics.producer_slot_in_epoch_last.load(.acquire);
                const l_elig = self.metrics.producer_leader_eligible_last.load(.acquire);
                const l_prob = self.metrics.producer_leader_probability_x1e6.load(.acquire);
                const l_checks = self.metrics.producer_leader_checks_epoch_total.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_producer_epoch_last Current epoch number
                    \\# TYPE tsunagi_producer_epoch_last gauge
                    \\tsunagi_producer_epoch_last {d}
                    \\# HELP tsunagi_producer_slot_in_epoch_last Slot position within current epoch
                    \\# TYPE tsunagi_producer_slot_in_epoch_last gauge
                    \\tsunagi_producer_slot_in_epoch_last {d}
                    \\# HELP tsunagi_producer_leader_eligible_last 1 if eligible for leader election
                    \\# TYPE tsunagi_producer_leader_eligible_last gauge
                    \\tsunagi_producer_leader_eligible_last {d}
                    \\# HELP tsunagi_producer_leader_probability_x1e6 Leader probability scaled by 1e6
                    \\# TYPE tsunagi_producer_leader_probability_x1e6 gauge
                    \\tsunagi_producer_leader_probability_x1e6 {d}
                    \\# HELP tsunagi_producer_leader_checks_epoch_total Leader checks in current epoch
                    \\# TYPE tsunagi_producer_leader_checks_epoch_total counter
                    \\tsunagi_producer_leader_checks_epoch_total {d}
                    \\
                , .{ l_epoch, l_sie, l_elig, l_prob, l_checks }) catch {};
            }

            // VRF interface
            {
                const v_enabled = self.metrics.producer_vrf_enabled.load(.acquire);
                const v_parse_ok = self.metrics.producer_vrf_parse_ok.load(.acquire);
                const v_attempt = self.metrics.producer_vrf_attempt_total.load(.acquire);
                const v_checked = self.metrics.producer_vrf_checked_total.load(.acquire);
                const v_reason = self.metrics.producer_vrf_reason_code_last.load(.acquire);
                const v_chk_last = self.metrics.producer_vrf_checked_last.load(.acquire);
                const v_prob = self.metrics.producer_vrf_probability_x1e6.load(.acquire);
                const v_proof = self.metrics.producer_vrf_proof_present.load(.acquire);
                const v_output = self.metrics.producer_vrf_output_present.load(.acquire);
                const v_init_ok = self.metrics.producer_vrf_init_ok.load(.acquire);
                const v_verify_ok = self.metrics.producer_vrf_verify_ok_last.load(.acquire);
                const v_out_prefix = self.metrics.producer_vrf_output_prefix_last.load(.acquire);
                const v_tick_mode = self.metrics.producer_vrf_tick_mode_code.load(.acquire);
                const v_last_chk_slot = self.metrics.producer_vrf_last_checked_slot.load(.acquire);
                const v_skipped = self.metrics.producer_vrf_skipped_total.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_producer_vrf_enabled 1 if VRF is enabled
                    \\# TYPE tsunagi_producer_vrf_enabled gauge
                    \\tsunagi_producer_vrf_enabled {d}
                    \\# HELP tsunagi_producer_vrf_parse_ok 1 if VRF config parsed successfully
                    \\# TYPE tsunagi_producer_vrf_parse_ok gauge
                    \\tsunagi_producer_vrf_parse_ok {d}
                    \\# HELP tsunagi_producer_vrf_attempt_total Cumulative VRF check attempts
                    \\# TYPE tsunagi_producer_vrf_attempt_total counter
                    \\tsunagi_producer_vrf_attempt_total {d}
                    \\# HELP tsunagi_producer_vrf_checked_total Cumulative VRF checks performed
                    \\# TYPE tsunagi_producer_vrf_checked_total counter
                    \\tsunagi_producer_vrf_checked_total {d}
                    \\# HELP tsunagi_producer_vrf_reason_code_last Last VRF reason code (0=ok 1=disabled 2=missing_path 3=missing_file 4=bad_perms 5=unreadable 7=clock_bad 8=init_failed 9=bad_seed 10=prove_failed)
                    \\# TYPE tsunagi_producer_vrf_reason_code_last gauge
                    \\tsunagi_producer_vrf_reason_code_last {d}
                    \\# HELP tsunagi_producer_vrf_checked_last 1 if last VRF check was performed
                    \\# TYPE tsunagi_producer_vrf_checked_last gauge
                    \\tsunagi_producer_vrf_checked_last {d}
                    \\# HELP tsunagi_producer_vrf_probability_x1e6 VRF probability scaled by 1e6
                    \\# TYPE tsunagi_producer_vrf_probability_x1e6 gauge
                    \\tsunagi_producer_vrf_probability_x1e6 {d}
                    \\# HELP tsunagi_producer_vrf_proof_present 1 if VRF proof was present
                    \\# TYPE tsunagi_producer_vrf_proof_present gauge
                    \\tsunagi_producer_vrf_proof_present {d}
                    \\# HELP tsunagi_producer_vrf_output_present 1 if VRF output was present
                    \\# TYPE tsunagi_producer_vrf_output_present gauge
                    \\tsunagi_producer_vrf_output_present {d}
                    \\# HELP tsunagi_producer_vrf_init_ok 1 if VRF key init succeeded
                    \\# TYPE tsunagi_producer_vrf_init_ok gauge
                    \\tsunagi_producer_vrf_init_ok {d}
                    \\# HELP tsunagi_producer_vrf_verify_ok_last 1 if last VRF self-verify succeeded
                    \\# TYPE tsunagi_producer_vrf_verify_ok_last gauge
                    \\tsunagi_producer_vrf_verify_ok_last {d}
                    \\# HELP tsunagi_producer_vrf_output_prefix_last First 8 bytes of VRF output as u64
                    \\# TYPE tsunagi_producer_vrf_output_prefix_last gauge
                    \\tsunagi_producer_vrf_output_prefix_last {d}
                    \\# HELP tsunagi_producer_vrf_tick_mode_code VRF tick mode (0=off 1=eligible 2=always)
                    \\# TYPE tsunagi_producer_vrf_tick_mode_code gauge
                    \\tsunagi_producer_vrf_tick_mode_code {d}
                    \\# HELP tsunagi_producer_vrf_last_checked_slot Last slot where VRF was computed
                    \\# TYPE tsunagi_producer_vrf_last_checked_slot gauge
                    \\tsunagi_producer_vrf_last_checked_slot {d}
                    \\# HELP tsunagi_producer_vrf_skipped_total Cumulative VRF checks skipped due to mode/cache
                    \\# TYPE tsunagi_producer_vrf_skipped_total counter
                    \\tsunagi_producer_vrf_skipped_total {d}
                    \\
                , .{ v_enabled, v_parse_ok, v_attempt, v_checked, v_reason, v_chk_last, v_prob, v_proof, v_output, v_init_ok, v_verify_ok, v_out_prefix, v_tick_mode, v_last_chk_slot, v_skipped }) catch {};
            }

            // VRF proof artifact pipeline (v0.9.8)
            {
                const vp_plen = self.metrics.producer_vrf_proof_len_last.load(.acquire);
                const vp_olen = self.metrics.producer_vrf_output_len_last.load(.acquire);
                const vp_ppfx = self.metrics.producer_vrf_proof_prefix_last.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_producer_vrf_proof_len_last Length of last VRF proof in bytes
                    \\# TYPE tsunagi_producer_vrf_proof_len_last gauge
                    \\tsunagi_producer_vrf_proof_len_last {d}
                    \\# HELP tsunagi_producer_vrf_output_len_last Length of last VRF output in bytes
                    \\# TYPE tsunagi_producer_vrf_output_len_last gauge
                    \\tsunagi_producer_vrf_output_len_last {d}
                    \\# HELP tsunagi_producer_vrf_proof_prefix_last First 8 bytes of last VRF proof (u64 big-endian)
                    \\# TYPE tsunagi_producer_vrf_proof_prefix_last gauge
                    \\tsunagi_producer_vrf_proof_prefix_last {d}
                    \\
                , .{ vp_plen, vp_olen, vp_ppfx }) catch {};
            }

            // KES interface
            {
                const kes_en = self.metrics.producer_kes_enabled.load(.acquire);
                const kes_pok = self.metrics.producer_kes_parse_ok.load(.acquire);
                const kes_att = self.metrics.producer_kes_attempt_total.load(.acquire);
                const kes_sig = self.metrics.producer_kes_signed_total.load(.acquire);
                const kes_sp = self.metrics.producer_kes_sig_present_last.load(.acquire);
                const kes_rc = self.metrics.producer_kes_reason_code_last.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_producer_kes_enabled 1 if KES is enabled
                    \\# TYPE tsunagi_producer_kes_enabled gauge
                    \\tsunagi_producer_kes_enabled {d}
                    \\# HELP tsunagi_producer_kes_parse_ok 1 if KES config parsed successfully
                    \\# TYPE tsunagi_producer_kes_parse_ok gauge
                    \\tsunagi_producer_kes_parse_ok {d}
                    \\# HELP tsunagi_producer_kes_attempt_total Cumulative KES sign attempts
                    \\# TYPE tsunagi_producer_kes_attempt_total counter
                    \\tsunagi_producer_kes_attempt_total {d}
                    \\# HELP tsunagi_producer_kes_signed_total Cumulative KES signatures produced
                    \\# TYPE tsunagi_producer_kes_signed_total counter
                    \\tsunagi_producer_kes_signed_total {d}
                    \\# HELP tsunagi_producer_kes_sig_present_last 1 if last KES signature was present
                    \\# TYPE tsunagi_producer_kes_sig_present_last gauge
                    \\tsunagi_producer_kes_sig_present_last {d}
                    \\# HELP tsunagi_producer_kes_reason_code_last Last KES reason code (0=ok 1=disabled 2=missing_path 3=missing_file 4=bad_perms 5=unreadable 6=test_stub)
                    \\# TYPE tsunagi_producer_kes_reason_code_last gauge
                    \\tsunagi_producer_kes_reason_code_last {d}
                    \\
                , .{ kes_en, kes_pok, kes_att, kes_sig, kes_sp, kes_rc }) catch {};
            }

            // Header candidate pipeline
            {
                const c_built = self.metrics.producer_candidate_built_total.load(.acquire);
                const c_signed = self.metrics.producer_candidate_signed_total.load(.acquire);
                const c_slot = self.metrics.producer_candidate_last_slot.load(.acquire);
                const c_body = self.metrics.producer_candidate_body_hash_prefix.load(.acquire);
                const c_sig = self.metrics.producer_candidate_sig_present_last.load(.acquire);
                const c_hdr_len = self.metrics.producer_candidate_hdr_bytes_len.load(.acquire);
                const c_hdr_w0 = self.metrics.producer_candidate_hdr_hash_w0.load(.acquire);
                const c_hdr_w1 = self.metrics.producer_candidate_hdr_hash_w1.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_producer_candidate_built_total Cumulative header candidates built
                    \\# TYPE tsunagi_producer_candidate_built_total counter
                    \\tsunagi_producer_candidate_built_total {d}
                    \\# HELP tsunagi_producer_candidate_signed_total Cumulative header candidates signed
                    \\# TYPE tsunagi_producer_candidate_signed_total counter
                    \\tsunagi_producer_candidate_signed_total {d}
                    \\# HELP tsunagi_producer_candidate_last_slot Slot of last header candidate
                    \\# TYPE tsunagi_producer_candidate_last_slot gauge
                    \\tsunagi_producer_candidate_last_slot {d}
                    \\# HELP tsunagi_producer_candidate_body_hash_prefix Body hash prefix of last candidate (u64 big-endian)
                    \\# TYPE tsunagi_producer_candidate_body_hash_prefix gauge
                    \\tsunagi_producer_candidate_body_hash_prefix {d}
                    \\# HELP tsunagi_producer_candidate_sig_present_last 1 if last candidate had KES signature
                    \\# TYPE tsunagi_producer_candidate_sig_present_last gauge
                    \\tsunagi_producer_candidate_sig_present_last {d}
                    \\# HELP tsunagi_producer_candidate_hdr_bytes_len Candidate header bytes length
                    \\# TYPE tsunagi_producer_candidate_hdr_bytes_len gauge
                    \\tsunagi_producer_candidate_hdr_bytes_len {d}
                    \\# HELP tsunagi_producer_candidate_hdr_hash_w0 Candidate header hash word 0 (bytes 0..8 big-endian)
                    \\# TYPE tsunagi_producer_candidate_hdr_hash_w0 gauge
                    \\tsunagi_producer_candidate_hdr_hash_w0 {d}
                    \\# HELP tsunagi_producer_candidate_hdr_hash_w1 Candidate header hash word 1 (bytes 8..16 big-endian)
                    \\# TYPE tsunagi_producer_candidate_hdr_hash_w1 gauge
                    \\tsunagi_producer_candidate_hdr_hash_w1 {d}
                    \\
                , .{ c_built, c_signed, c_slot, c_body, c_sig, c_hdr_len, c_hdr_w0, c_hdr_w1 }) catch {};
            }

            // Block body builder (v0.9.9)
            {
                const b_cbor_len = self.metrics.producer_body_cbor_len.load(.acquire);
                const b_hw0 = self.metrics.producer_body_hash_w0.load(.acquire);
                const b_hw1 = self.metrics.producer_body_hash_w1.load(.acquire);
                const b_hw2 = self.metrics.producer_body_hash_w2.load(.acquire);
                const b_hw3 = self.metrics.producer_body_hash_w3.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_producer_body_cbor_len Candidate body CBOR length in bytes
                    \\# TYPE tsunagi_producer_body_cbor_len gauge
                    \\tsunagi_producer_body_cbor_len {d}
                    \\# HELP tsunagi_producer_body_hash_w0 Body hash word 0 (bytes 0..8 big-endian)
                    \\# TYPE tsunagi_producer_body_hash_w0 gauge
                    \\tsunagi_producer_body_hash_w0 {d}
                    \\# HELP tsunagi_producer_body_hash_w1 Body hash word 1 (bytes 8..16 big-endian)
                    \\# TYPE tsunagi_producer_body_hash_w1 gauge
                    \\tsunagi_producer_body_hash_w1 {d}
                    \\# HELP tsunagi_producer_body_hash_w2 Body hash word 2 (bytes 16..24 big-endian)
                    \\# TYPE tsunagi_producer_body_hash_w2 gauge
                    \\tsunagi_producer_body_hash_w2 {d}
                    \\# HELP tsunagi_producer_body_hash_w3 Body hash word 3 (bytes 24..32 big-endian)
                    \\# TYPE tsunagi_producer_body_hash_w3 gauge
                    \\tsunagi_producer_body_hash_w3 {d}
                    \\
                , .{ b_cbor_len, b_hw0, b_hw1, b_hw2, b_hw3 }) catch {};
            }

            // Producer proof pack (v1.0.0)
            {
                const pk_total = self.metrics.producer_pack_total.load(.acquire);
                const pk_unix = self.metrics.producer_pack_last_unix.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_producer_pack_total Cumulative producer proof packs written
                    \\# TYPE tsunagi_producer_pack_total counter
                    \\tsunagi_producer_pack_total {d}
                    \\# HELP tsunagi_producer_pack_last_unix Unix timestamp of last pack write
                    \\# TYPE tsunagi_producer_pack_last_unix gauge
                    \\tsunagi_producer_pack_last_unix {d}
                    \\
                , .{ pk_total, pk_unix }) catch {};
            }

            // Praos leader check (v1.0.1, extended v1.0.9)
            {
                const pr_u = self.metrics.producer_praos_u_x1e12.load(.acquire);
                const pr_t = self.metrics.producer_praos_thresh_x1e12.load(.acquire);
                const pr_leader = self.metrics.producer_praos_leader_last.load(.acquire);
                const pr_rc = self.metrics.producer_praos_reason_code_last.load(.acquire);
                const pr_checks = self.metrics.producer_praos_checks_total.load(.acquire);
                const pr_en = self.metrics.producer_praos_enabled.load(.acquire);
                const pr_lcs = self.metrics.producer_praos_last_checked_slot.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_producer_praos_u_x1e12 VRF uniform scalar u scaled by 1e12
                    \\# TYPE tsunagi_producer_praos_u_x1e12 gauge
                    \\tsunagi_producer_praos_u_x1e12 {d}
                    \\# HELP tsunagi_producer_praos_thresh_x1e12 Leader threshold T scaled by 1e12
                    \\# TYPE tsunagi_producer_praos_thresh_x1e12 gauge
                    \\tsunagi_producer_praos_thresh_x1e12 {d}
                    \\# HELP tsunagi_producer_praos_leader_last 1 if praos leader check passed
                    \\# TYPE tsunagi_producer_praos_leader_last gauge
                    \\tsunagi_producer_praos_leader_last {d}
                    \\# HELP tsunagi_producer_praos_reason_code_last Praos leader check reason code
                    \\# TYPE tsunagi_producer_praos_reason_code_last gauge
                    \\tsunagi_producer_praos_reason_code_last {d}
                    \\# HELP tsunagi_producer_praos_checks_total Cumulative praos leader checks
                    \\# TYPE tsunagi_producer_praos_checks_total counter
                    \\tsunagi_producer_praos_checks_total {d}
                    \\# HELP tsunagi_producer_praos_enabled Praos leader check enabled (0/1)
                    \\# TYPE tsunagi_producer_praos_enabled gauge
                    \\tsunagi_producer_praos_enabled {d}
                    \\# HELP tsunagi_producer_praos_last_checked_slot Last slot where Praos decision was evaluated
                    \\# TYPE tsunagi_producer_praos_last_checked_slot gauge
                    \\tsunagi_producer_praos_last_checked_slot {d}
                    \\
                , .{ pr_u, pr_t, pr_leader, pr_rc, pr_checks, pr_en, pr_lcs }) catch {};
            }

            // Praos decision surface (v1.1.3)
            {
                const ds_sf = self.metrics.producer_stake_fraction_x1e9.load(.acquire);
                const ds_asc = self.metrics.producer_active_slot_coeff_x1e6.load(.acquire);
                const ds_t = self.metrics.producer_praos_thresh_x1e12.load(.acquire);
                const ds_u = self.metrics.producer_praos_u_x1e12.load(.acquire);
                const ds_ult = self.metrics.producer_praos_u_lt_t.load(.acquire);
                const ds_delta = self.metrics.producer_praos_delta_x1e12.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_praos_stake_fraction_x1e9 Stake fraction used in Praos threshold (x1e9)
                    \\# TYPE tsunagi_praos_stake_fraction_x1e9 gauge
                    \\tsunagi_praos_stake_fraction_x1e9 {d}
                    \\# HELP tsunagi_praos_asc_x1e6 Active slot coefficient used in Praos threshold (x1e6)
                    \\# TYPE tsunagi_praos_asc_x1e6 gauge
                    \\tsunagi_praos_asc_x1e6 {d}
                    \\# HELP tsunagi_praos_threshold_x1e12 Praos leader threshold T (x1e12)
                    \\# TYPE tsunagi_praos_threshold_x1e12 gauge
                    \\tsunagi_praos_threshold_x1e12 {d}
                    \\# HELP tsunagi_praos_u_x1e12 VRF-derived uniform scalar u (x1e12)
                    \\# TYPE tsunagi_praos_u_x1e12 gauge
                    \\tsunagi_praos_u_x1e12 {d}
                    \\# HELP tsunagi_praos_u_lt_t 1 if u < T (eligible), 0 otherwise
                    \\# TYPE tsunagi_praos_u_lt_t gauge
                    \\tsunagi_praos_u_lt_t {d}
                    \\# HELP tsunagi_praos_delta_x1e12 Eligibility margin max(0, T - u) (x1e12)
                    \\# TYPE tsunagi_praos_delta_x1e12 gauge
                    \\tsunagi_praos_delta_x1e12 {d}
                    \\
                , .{ ds_sf, ds_asc, ds_t, ds_u, ds_ult, ds_delta }) catch {};
            }

            // Slot scheduler (v1.1.0)
            {
                const sc_epoch = self.metrics.producer_schedule_epoch_last.load(.acquire);
                const sc_wss = self.metrics.producer_schedule_window_start_slot.load(.acquire);
                const sc_wsz = self.metrics.producer_schedule_window_size.load(.acquire);
                const sc_leaders = self.metrics.producer_schedule_leaders_in_window.load(.acquire);
                const sc_next = self.metrics.producer_schedule_next_leader_offset.load(.acquire);
                const sc_u0 = self.metrics.producer_schedule_u0_x1e12.load(.acquire);
                const sc_t = self.metrics.producer_schedule_t_x1e12.load(.acquire);
                const sc_rc = self.metrics.producer_schedule_reason_code_last.load(.acquire);
                const sc_total = self.metrics.producer_schedule_compute_total.load(.acquire);
                const sc_us = self.metrics.producer_schedule_compute_us_total.load(.acquire);
                const sc_ls = self.metrics.producer_schedule_last_slot.load(.acquire);
                const sc_lu = self.metrics.producer_schedule_last_update_us.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_producer_schedule_epoch_last Epoch of last schedule computation
                    \\# TYPE tsunagi_producer_schedule_epoch_last gauge
                    \\tsunagi_producer_schedule_epoch_last {d}
                    \\# HELP tsunagi_producer_schedule_window_start_slot Start slot of schedule window
                    \\# TYPE tsunagi_producer_schedule_window_start_slot gauge
                    \\tsunagi_producer_schedule_window_start_slot {d}
                    \\# HELP tsunagi_producer_schedule_window_size Schedule window size (slots)
                    \\# TYPE tsunagi_producer_schedule_window_size gauge
                    \\tsunagi_producer_schedule_window_size {d}
                    \\# HELP tsunagi_producer_schedule_leaders_in_window Leader slots in window
                    \\# TYPE tsunagi_producer_schedule_leaders_in_window gauge
                    \\tsunagi_producer_schedule_leaders_in_window {d}
                    \\# HELP tsunagi_producer_schedule_next_leader_offset Offset to next leader slot (999999 if none)
                    \\# TYPE tsunagi_producer_schedule_next_leader_offset gauge
                    \\tsunagi_producer_schedule_next_leader_offset {d}
                    \\# HELP tsunagi_producer_schedule_u0_x1e12 u value for offset 0 scaled by 1e12
                    \\# TYPE tsunagi_producer_schedule_u0_x1e12 gauge
                    \\tsunagi_producer_schedule_u0_x1e12 {d}
                    \\# HELP tsunagi_producer_schedule_t_x1e12 Threshold T scaled by 1e12
                    \\# TYPE tsunagi_producer_schedule_t_x1e12 gauge
                    \\tsunagi_producer_schedule_t_x1e12 {d}
                    \\# HELP tsunagi_producer_schedule_reason_code_last Schedule reason code (0=ok)
                    \\# TYPE tsunagi_producer_schedule_reason_code_last gauge
                    \\tsunagi_producer_schedule_reason_code_last {d}
                    \\# HELP tsunagi_producer_schedule_compute_total Cumulative schedule computations
                    \\# TYPE tsunagi_producer_schedule_compute_total counter
                    \\tsunagi_producer_schedule_compute_total {d}
                    \\# HELP tsunagi_producer_schedule_compute_us_total Cumulative microseconds spent computing schedule
                    \\# TYPE tsunagi_producer_schedule_compute_us_total counter
                    \\tsunagi_producer_schedule_compute_us_total {d}
                    \\# HELP tsunagi_producer_schedule_last_slot Last slot that triggered schedule computation
                    \\# TYPE tsunagi_producer_schedule_last_slot gauge
                    \\tsunagi_producer_schedule_last_slot {d}
                    \\# HELP tsunagi_producer_schedule_last_update_us Unix microseconds of last schedule update
                    \\# TYPE tsunagi_producer_schedule_last_update_us gauge
                    \\tsunagi_producer_schedule_last_update_us {d}
                    \\
                , .{ sc_epoch, sc_wss, sc_wsz, sc_leaders, sc_next, sc_u0, sc_t, sc_rc, sc_total, sc_us, sc_ls, sc_lu }) catch {};
            }

            // Schema version static gauges (hardening)
            wr.print(
                \\# HELP tsunagi_state_schema_version Current /state JSON schema version
                \\# TYPE tsunagi_state_schema_version gauge
                \\tsunagi_state_schema_version 2
                \\# HELP tsunagi_pack_schema_version Current pack.json schema version
                \\# TYPE tsunagi_pack_schema_version gauge
                \\tsunagi_pack_schema_version 1
                \\
            , .{}) catch {};

            // Execution timing guards (hardening)
            {
                const vrf_us_total = self.metrics.producer_vrf_compute_us_total.load(.acquire);
                const vrf_us_last = self.metrics.producer_vrf_compute_us_last.load(.acquire);
                const tick_us_total = self.metrics.producer_tick_us_total.load(.acquire);
                const tick_us_last = self.metrics.producer_tick_us_last.load(.acquire);
                const tick_us_max = self.metrics.producer_tick_us_max.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_producer_vrf_compute_us_total Cumulative VRF prove microseconds
                    \\# TYPE tsunagi_producer_vrf_compute_us_total counter
                    \\tsunagi_producer_vrf_compute_us_total {d}
                    \\# HELP tsunagi_producer_vrf_compute_us_last Last single VRF prove microseconds
                    \\# TYPE tsunagi_producer_vrf_compute_us_last gauge
                    \\tsunagi_producer_vrf_compute_us_last {d}
                    \\# HELP tsunagi_producer_tick_us_total Cumulative tick microseconds
                    \\# TYPE tsunagi_producer_tick_us_total counter
                    \\tsunagi_producer_tick_us_total {d}
                    \\# HELP tsunagi_producer_tick_us_last Last single tick microseconds
                    \\# TYPE tsunagi_producer_tick_us_last gauge
                    \\tsunagi_producer_tick_us_last {d}
                    \\# HELP tsunagi_producer_tick_us_max Max single tick microseconds
                    \\# TYPE tsunagi_producer_tick_us_max gauge
                    \\tsunagi_producer_tick_us_max {d}
                    \\
                , .{ vrf_us_total, vrf_us_last, tick_us_total, tick_us_last, tick_us_max }) catch {};
            }

            // KES period gate (v1.0.2)
            {
                const kp_cur = self.metrics.producer_kes_current_period.load(.acquire);
                const kp_valid = self.metrics.producer_kes_period_valid_last.load(.acquire);
                const kp_rc = self.metrics.producer_kes_period_reason_code_last.load(.acquire);
                const kp_start = self.metrics.producer_kes_start_period.load(.acquire);
                const kp_max = self.metrics.producer_kes_max_periods.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_producer_kes_current_period Current KES period derived from slot
                    \\# TYPE tsunagi_producer_kes_current_period gauge
                    \\tsunagi_producer_kes_current_period {d}
                    \\# HELP tsunagi_producer_kes_period_valid_last 1 if current KES period is within allowed window
                    \\# TYPE tsunagi_producer_kes_period_valid_last gauge
                    \\tsunagi_producer_kes_period_valid_last {d}
                    \\# HELP tsunagi_producer_kes_period_reason_code_last KES period validation reason code
                    \\# TYPE tsunagi_producer_kes_period_reason_code_last gauge
                    \\tsunagi_producer_kes_period_reason_code_last {d}
                    \\# HELP tsunagi_producer_kes_start_period Configured KES start period
                    \\# TYPE tsunagi_producer_kes_start_period gauge
                    \\tsunagi_producer_kes_start_period {d}
                    \\# HELP tsunagi_producer_kes_max_periods Configured KES max periods
                    \\# TYPE tsunagi_producer_kes_max_periods gauge
                    \\tsunagi_producer_kes_max_periods {d}
                    \\
                , .{ kp_cur, kp_valid, kp_rc, kp_start, kp_max }) catch {};
            }

            // KES lifecycle hardening (v1.1.2)
            {
                const kl_start_slot = self.metrics.producer_kes_period_start_slot.load(.acquire);
                const kl_end_slot = self.metrics.producer_kes_period_end_slot.load(.acquire);
                const kl_rollovers = self.metrics.producer_kes_rollovers_total.load(.acquire);
                const kl_last_roll = self.metrics.producer_kes_last_rollover_slot.load(.acquire);
                const kl_oor = self.metrics.producer_kes_out_of_range_total.load(.acquire);
                const kl_refused = self.metrics.producer_kes_sign_refused_total.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_kes_period_start_slot First slot of current KES period
                    \\# TYPE tsunagi_kes_period_start_slot gauge
                    \\tsunagi_kes_period_start_slot {d}
                    \\# HELP tsunagi_kes_period_end_slot Last slot of current KES period (inclusive)
                    \\# TYPE tsunagi_kes_period_end_slot gauge
                    \\tsunagi_kes_period_end_slot {d}
                    \\# HELP tsunagi_kes_period_rollovers_total Cumulative KES period rollovers detected
                    \\# TYPE tsunagi_kes_period_rollovers_total counter
                    \\tsunagi_kes_period_rollovers_total {d}
                    \\# HELP tsunagi_kes_last_rollover_slot Slot at which last KES period rollover occurred
                    \\# TYPE tsunagi_kes_last_rollover_slot gauge
                    \\tsunagi_kes_last_rollover_slot {d}
                    \\# HELP tsunagi_kes_out_of_range_total Signing attempts refused due to KES period out of range
                    \\# TYPE tsunagi_kes_out_of_range_total counter
                    \\tsunagi_kes_out_of_range_total {d}
                    \\# HELP tsunagi_kes_sign_refused_total Total signing attempts refused (any reason)
                    \\# TYPE tsunagi_kes_sign_refused_total counter
                    \\tsunagi_kes_sign_refused_total {d}
                    \\
                , .{ kl_start_slot, kl_end_slot, kl_rollovers, kl_last_roll, kl_oor, kl_refused }) catch {};
            }

            // Candidate signing proof (v0.9.7)
            {
                const cs_pfx = self.metrics.producer_candidate_sig_prefix_last.load(.acquire);
                const cs_rc = self.metrics.producer_candidate_sign_reason_code_last.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_producer_candidate_sig_prefix_last First 8 bytes of last candidate signature (u64 big-endian)
                    \\# TYPE tsunagi_producer_candidate_sig_prefix_last gauge
                    \\tsunagi_producer_candidate_sig_prefix_last {d}
                    \\# HELP tsunagi_producer_candidate_sign_reason_code_last Last candidate sign reason code (0=ok 1=disabled 2=not_eligible 3=missing_seed 5=sign_fail 6=io_fail)
                    \\# TYPE tsunagi_producer_candidate_sign_reason_code_last gauge
                    \\tsunagi_producer_candidate_sign_reason_code_last {d}
                    \\
                , .{ cs_pfx, cs_rc }) catch {};
            }

            // Pure Zig Ed25519 signing
            {
                const zs_att = self.metrics.producer_zig_sig_attempt_total.load(.acquire);
                const zs_ok = self.metrics.producer_zig_sig_ok_total.load(.acquire);
                const zs_pres = self.metrics.producer_zig_sig_present_last.load(.acquire);
                const zs_pfx = self.metrics.producer_zig_sig_prefix_last.load(.acquire);
                const zs_rc = self.metrics.producer_zig_sig_reason_last.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_producer_zig_sig_attempt_total Pure Zig signing attempts
                    \\# TYPE tsunagi_producer_zig_sig_attempt_total counter
                    \\tsunagi_producer_zig_sig_attempt_total {d}
                    \\# HELP tsunagi_producer_zig_sig_ok_total Pure Zig successful signatures
                    \\# TYPE tsunagi_producer_zig_sig_ok_total counter
                    \\tsunagi_producer_zig_sig_ok_total {d}
                    \\# HELP tsunagi_producer_zig_sig_present_last Last zig signature present (0/1)
                    \\# TYPE tsunagi_producer_zig_sig_present_last gauge
                    \\tsunagi_producer_zig_sig_present_last {d}
                    \\# HELP tsunagi_producer_zig_sig_prefix_last First 8 bytes of last signature
                    \\# TYPE tsunagi_producer_zig_sig_prefix_last gauge
                    \\tsunagi_producer_zig_sig_prefix_last {d}
                    \\# HELP tsunagi_producer_zig_sig_reason_last Last zig signature reason code
                    \\# TYPE tsunagi_producer_zig_sig_reason_last gauge
                    \\tsunagi_producer_zig_sig_reason_last {d}
                    \\
                , .{ zs_att, zs_ok, zs_pres, zs_pfx, zs_rc }) catch {};
            }

            // KES candidate signing
            {
                const ks_att = self.metrics.producer_kes_sign_attempt_total.load(.acquire);
                const ks_ok = self.metrics.producer_kes_sign_ok_total.load(.acquire);
                const ks_pres = self.metrics.producer_kes_sign_present_last.load(.acquire);
                const ks_pfx = self.metrics.producer_kes_sign_prefix_last.load(.acquire);
                const ks_rc = self.metrics.producer_kes_sign_reason_last.load(.acquire);
                const ks_lbl = self.metrics.producer_kes_sign_label_last.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_producer_kes_sign_attempt_total KES candidate signing attempts
                    \\# TYPE tsunagi_producer_kes_sign_attempt_total counter
                    \\tsunagi_producer_kes_sign_attempt_total {d}
                    \\# HELP tsunagi_producer_kes_sign_ok_total KES candidate successful signatures
                    \\# TYPE tsunagi_producer_kes_sign_ok_total counter
                    \\tsunagi_producer_kes_sign_ok_total {d}
                    \\# HELP tsunagi_producer_kes_sign_present_last Last KES signature present (0/1)
                    \\# TYPE tsunagi_producer_kes_sign_present_last gauge
                    \\tsunagi_producer_kes_sign_present_last {d}
                    \\# HELP tsunagi_producer_kes_sign_prefix_last First 8 bytes of last KES signature
                    \\# TYPE tsunagi_producer_kes_sign_prefix_last gauge
                    \\tsunagi_producer_kes_sign_prefix_last {d}
                    \\# HELP tsunagi_producer_kes_sign_reason_last Last KES sign reason code (0=ok 1=disabled 2=empty 3=bad_read 4=bad_len 5=fail)
                    \\# TYPE tsunagi_producer_kes_sign_reason_last gauge
                    \\tsunagi_producer_kes_sign_reason_last {d}
                    \\# HELP tsunagi_producer_kes_sign_label_last KES signer label code (0=none 1=placeholder_ed25519)
                    \\# TYPE tsunagi_producer_kes_sign_label_last gauge
                    \\tsunagi_producer_kes_sign_label_last {d}
                    \\
                , .{ ks_att, ks_ok, ks_pres, ks_pfx, ks_rc, ks_lbl }) catch {};
            }

            // Producer proof bundle
            {
                const pp_unix = self.metrics.last_producer_proof_unix.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_last_producer_proof_unix Unix timestamp of last producer proof bundle event
                    \\# TYPE tsunagi_last_producer_proof_unix gauge
                    \\tsunagi_last_producer_proof_unix {d}
                    \\
                , .{pp_unix}) catch {};
            }

            // Key management
            {
                const k_en = self.metrics.producer_keys_enabled.load(.acquire);
                const k_pok = self.metrics.producer_keys_parse_ok.load(.acquire);
                const k_vt = self.metrics.producer_keys_validate_total.load(.acquire);
                const k_err = self.metrics.producer_keys_err_code_last.load(.acquire);
                const k_pool = self.metrics.producer_pool_ok.load(.acquire);
                const k_kes = self.metrics.producer_kes_ok.load(.acquire);
                const k_vrf = self.metrics.producer_vrf_key_ok.load(.acquire);
                const k_perms = self.metrics.producer_keys_perms_ok.load(.acquire);
                const k_read = self.metrics.producer_keys_readable_ok.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_producer_keys_enabled 1 if producer mode is enabled
                    \\# TYPE tsunagi_producer_keys_enabled gauge
                    \\tsunagi_producer_keys_enabled {d}
                    \\# HELP tsunagi_producer_keys_parse_ok 1 if key config parsed successfully
                    \\# TYPE tsunagi_producer_keys_parse_ok gauge
                    \\tsunagi_producer_keys_parse_ok {d}
                    \\# HELP tsunagi_producer_keys_validate_total Cumulative key validations
                    \\# TYPE tsunagi_producer_keys_validate_total counter
                    \\tsunagi_producer_keys_validate_total {d}
                    \\# HELP tsunagi_producer_keys_err_code_last Last key validation error code
                    \\# TYPE tsunagi_producer_keys_err_code_last gauge
                    \\tsunagi_producer_keys_err_code_last {d}
                    \\# HELP tsunagi_producer_pool_ok 1 if pool ID is valid
                    \\# TYPE tsunagi_producer_pool_ok gauge
                    \\tsunagi_producer_pool_ok {d}
                    \\# HELP tsunagi_producer_kes_ok 1 if KES key file exists
                    \\# TYPE tsunagi_producer_kes_ok gauge
                    \\tsunagi_producer_kes_ok {d}
                    \\# HELP tsunagi_producer_vrf_ok 1 if VRF key file exists
                    \\# TYPE tsunagi_producer_vrf_ok gauge
                    \\tsunagi_producer_vrf_ok {d}
                    \\# HELP tsunagi_producer_keys_perms_ok 1 if key files have safe permissions (0600)
                    \\# TYPE tsunagi_producer_keys_perms_ok gauge
                    \\tsunagi_producer_keys_perms_ok {d}
                    \\# HELP tsunagi_producer_keys_readable_ok 1 if key files are readable
                    \\# TYPE tsunagi_producer_keys_readable_ok gauge
                    \\tsunagi_producer_keys_readable_ok {d}
                    \\
                , .{ k_en, k_pok, k_vt, k_err, k_pool, k_kes, k_vrf, k_perms, k_read }) catch {};
            }

            // Leader probability model
            {
                const lm_sf = self.metrics.producer_stake_fraction_x1e9.load(.acquire);
                const lm_asc = self.metrics.producer_active_slot_coeff_x1e6.load(.acquire);
                const lm_prob = self.metrics.producer_leader_probability_x1e6.load(.acquire);
                const lm_exp = self.metrics.producer_expected_leaders_per_epoch.load(.acquire);
                const lm_rc = self.metrics.producer_leader_reason_code_last.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_producer_stake_fraction_x1e9 Operator stake fraction scaled by 1e9
                    \\# TYPE tsunagi_producer_stake_fraction_x1e9 gauge
                    \\tsunagi_producer_stake_fraction_x1e9 {d}
                    \\# HELP tsunagi_producer_active_slot_coeff_x1e6 Active slot coefficient scaled by 1e6
                    \\# TYPE tsunagi_producer_active_slot_coeff_x1e6 gauge
                    \\tsunagi_producer_active_slot_coeff_x1e6 {d}
                    \\# HELP tsunagi_producer_expected_leaders_per_epoch Expected leader slots per epoch
                    \\# TYPE tsunagi_producer_expected_leaders_per_epoch gauge
                    \\tsunagi_producer_expected_leaders_per_epoch {d}
                    \\# HELP tsunagi_producer_leader_reason_code_last Leader model reason code
                    \\# TYPE tsunagi_producer_leader_reason_code_last gauge
                    \\tsunagi_producer_leader_reason_code_last {d}
                    \\
                , .{ lm_sf, lm_asc, lm_exp, lm_rc }) catch {};
                // Note: tsunagi_producer_leader_probability_x1e6 is already exported above
                _ = lm_prob;
            }

            // Eligibility test harness
            {
                const et_en = self.metrics.producer_elig_test_enabled.load(.acquire);
                const et_slot = self.metrics.producer_elig_test_slot_in_epoch.load(.acquire);
                const et_win = self.metrics.producer_elig_test_window_s.load(.acquire);
                const et_end = self.metrics.producer_elig_test_target_end_slot_in_epoch.load(.acquire);
                const et_active = self.metrics.producer_elig_test_window_active.load(.acquire);
                const et_ov_en = self.metrics.producer_elig_test_override_enabled.load(.acquire);
                const et_ov_tgt = self.metrics.producer_elig_test_override_target.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_producer_elig_test_enabled 1 if deterministic eligibility test harness is enabled
                    \\# TYPE tsunagi_producer_elig_test_enabled gauge
                    \\tsunagi_producer_elig_test_enabled {d}
                    \\# HELP tsunagi_producer_elig_test_slot_in_epoch Deterministic eligible slot within epoch (test harness)
                    \\# TYPE tsunagi_producer_elig_test_slot_in_epoch gauge
                    \\tsunagi_producer_elig_test_slot_in_epoch {d}
                    \\# HELP tsunagi_producer_elig_test_window_s Eligibility window size in seconds
                    \\# TYPE tsunagi_producer_elig_test_window_s gauge
                    \\tsunagi_producer_elig_test_window_s {d}
                    \\# HELP tsunagi_producer_elig_test_target_end_slot_in_epoch End of eligibility window (exclusive)
                    \\# TYPE tsunagi_producer_elig_test_target_end_slot_in_epoch gauge
                    \\tsunagi_producer_elig_test_target_end_slot_in_epoch {d}
                    \\# HELP tsunagi_producer_elig_test_window_active 1 when currently inside eligibility window
                    \\# TYPE tsunagi_producer_elig_test_window_active gauge
                    \\tsunagi_producer_elig_test_window_active {d}
                    \\# HELP tsunagi_producer_elig_test_override_enabled 1 if target override is active (test-only)
                    \\# TYPE tsunagi_producer_elig_test_override_enabled gauge
                    \\tsunagi_producer_elig_test_override_enabled {d}
                    \\# HELP tsunagi_producer_elig_test_override_target Override target slot_in_epoch (test-only)
                    \\# TYPE tsunagi_producer_elig_test_override_target gauge
                    \\tsunagi_producer_elig_test_override_target {d}
                    \\
                , .{ et_en, et_slot, et_win, et_end, et_active, et_ov_en, et_ov_tgt }) catch {};
            }

            // State digest gauges
            {
                const sd_hi = self.metrics.state_digest_hi.load(.acquire);
                const sd_lo = self.metrics.state_digest_lo.load(.acquire);
                const sd_w2 = self.metrics.state_digest_w2.load(.acquire);
                const sd_w3 = self.metrics.state_digest_w3.load(.acquire);
                const sd_unix = self.metrics.state_digest_unix.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_state_digest_hi Upper 64 bits of canonical UTxO state digest (blake2b256) (w0)
                    \\# TYPE tsunagi_state_digest_hi gauge
                    \\tsunagi_state_digest_hi {d}
                    \\# HELP tsunagi_state_digest_lo Bits 64-127 of canonical UTxO state digest (w1)
                    \\# TYPE tsunagi_state_digest_lo gauge
                    \\tsunagi_state_digest_lo {d}
                    \\# HELP tsunagi_state_digest_w2 Bits 128-191 of canonical UTxO state digest
                    \\# TYPE tsunagi_state_digest_w2 gauge
                    \\tsunagi_state_digest_w2 {d}
                    \\# HELP tsunagi_state_digest_w3 Bits 192-255 of canonical UTxO state digest
                    \\# TYPE tsunagi_state_digest_w3 gauge
                    \\tsunagi_state_digest_w3 {d}
                    \\# HELP tsunagi_state_digest_unix Unix timestamp of last state digest computation
                    \\# TYPE tsunagi_state_digest_unix gauge
                    \\tsunagi_state_digest_unix {d}
                    \\
                , .{ sd_hi, sd_lo, sd_w2, sd_w3, sd_unix }) catch {};
            }

            // Memory / footprint gauges
            {
                const rss = readRssKb();
                self.metrics.rss_kb.store(rss, .release);
                const lmdb_utxo = @import("../../store/lmdb_utxo.zig");
                const map_bytes: u64 = lmdb_utxo.g_map_size_bytes;
                const map_gb: u64 = lmdb_utxo.g_map_gb_effective;
                const map_parse_ok: u64 = lmdb_utxo.g_map_gb_raw_parse_ok;
                self.metrics.lmdb_map_size_bytes.store(map_bytes, .release);
                self.metrics.lmdb_map_gb_effective.store(map_gb, .release);
                self.metrics.lmdb_map_gb_raw_parse_ok.store(map_parse_ok, .release);
                wr.print(
                    \\# HELP tsunagi_rss_kb Resident set size in kilobytes
                    \\# TYPE tsunagi_rss_kb gauge
                    \\tsunagi_rss_kb {d}
                    \\# HELP tsunagi_lmdb_map_size_bytes LMDB mmap virtual address space size
                    \\# TYPE tsunagi_lmdb_map_size_bytes gauge
                    \\tsunagi_lmdb_map_size_bytes {d}
                    \\# HELP tsunagi_lmdb_map_gb_effective Effective LMDB map size in GB after parsing and clamping
                    \\# TYPE tsunagi_lmdb_map_gb_effective gauge
                    \\tsunagi_lmdb_map_gb_effective {d}
                    \\# HELP tsunagi_lmdb_map_gb_raw_parse_ok Whether TSUNAGI_LMDB_MAP_GB env var parsed successfully (0/1)
                    \\# TYPE tsunagi_lmdb_map_gb_raw_parse_ok gauge
                    \\tsunagi_lmdb_map_gb_raw_parse_ok {d}
                    \\
                , .{ rss, map_bytes, map_gb, map_parse_ok }) catch {};
            }

            // Allocator watermark gauges
            {
                const ca = @import("../../ops/counting_allocator.zig");
                const ac = ca.g_current_bytes.load(.acquire);
                const ap = ca.g_peak_bytes.load(.acquire);
                const ab = ca.g_baseline_bytes.load(.acquire);
                const an: u64 = ac -| ab;
                const aev = ca.g_peak_increase_events.load(.acquire);
                const alu = ca.g_peak_last_unix.load(.acquire);
                wr.print(
                    \\# HELP tsunagi_alloc_current_bytes Allocator tracked bytes currently held
                    \\# TYPE tsunagi_alloc_current_bytes gauge
                    \\tsunagi_alloc_current_bytes {d}
                    \\# HELP tsunagi_alloc_peak_bytes Allocator high-water mark bytes
                    \\# TYPE tsunagi_alloc_peak_bytes gauge
                    \\tsunagi_alloc_peak_bytes {d}
                    \\# HELP tsunagi_alloc_net_bytes Allocator net bytes above baseline
                    \\# TYPE tsunagi_alloc_net_bytes gauge
                    \\tsunagi_alloc_net_bytes {d}
                    \\# HELP tsunagi_alloc_peak_increase_events_total Peak increase events after warmup
                    \\# TYPE tsunagi_alloc_peak_increase_events_total counter
                    \\tsunagi_alloc_peak_increase_events_total {d}
                    \\# HELP tsunagi_alloc_peak_last_unix Unix timestamp of last peak change
                    \\# TYPE tsunagi_alloc_peak_last_unix gauge
                    \\tsunagi_alloc_peak_last_unix {d}
                    \\
                , .{ ac, ap, an, aev, alu }) catch {};
            }

            // Memory attribution gauges
            {
                wr.print(
                    \\# HELP tsunagi_mem_gaps_keys_count Gap tracker missing keys count
                    \\# TYPE tsunagi_mem_gaps_keys_count gauge
                    \\tsunagi_mem_gaps_keys_count {d}
                    \\# HELP tsunagi_mem_gaps_first_seen_count Gap tracker first_seen map count
                    \\# TYPE tsunagi_mem_gaps_first_seen_count gauge
                    \\tsunagi_mem_gaps_first_seen_count {d}
                    \\# HELP tsunagi_mem_gaps_last_seen_count Gap tracker last_seen map count
                    \\# TYPE tsunagi_mem_gaps_last_seen_count gauge
                    \\tsunagi_mem_gaps_last_seen_count {d}
                    \\# HELP tsunagi_mem_gaps_keys_bytes_est Estimated bytes for missing_inputs_map
                    \\# TYPE tsunagi_mem_gaps_keys_bytes_est gauge
                    \\tsunagi_mem_gaps_keys_bytes_est {d}
                    \\# HELP tsunagi_mem_gaps_first_seen_bytes_est Estimated bytes for first_seen map
                    \\# TYPE tsunagi_mem_gaps_first_seen_bytes_est gauge
                    \\tsunagi_mem_gaps_first_seen_bytes_est {d}
                    \\# HELP tsunagi_mem_gaps_last_seen_bytes_est Estimated bytes for last_seen map
                    \\# TYPE tsunagi_mem_gaps_last_seen_bytes_est gauge
                    \\tsunagi_mem_gaps_last_seen_bytes_est {d}
                    \\# HELP tsunagi_mem_gaps_total_bytes_est Total estimated gap tracker bytes
                    \\# TYPE tsunagi_mem_gaps_total_bytes_est gauge
                    \\tsunagi_mem_gaps_total_bytes_est {d}
                    \\# HELP tsunagi_mem_mempool_items Mempool item count (attribution)
                    \\# TYPE tsunagi_mem_mempool_items gauge
                    \\tsunagi_mem_mempool_items {d}
                    \\# HELP tsunagi_mem_mempool_bytes_est Mempool estimated bytes
                    \\# TYPE tsunagi_mem_mempool_bytes_est gauge
                    \\tsunagi_mem_mempool_bytes_est {d}
                    \\# HELP tsunagi_mem_capture_bytes_est Capture footprint bytes (disk-backed)
                    \\# TYPE tsunagi_mem_capture_bytes_est gauge
                    \\tsunagi_mem_capture_bytes_est {d}
                    \\# HELP tsunagi_mem_lmdb_map_bytes LMDB virtual map size bytes
                    \\# TYPE tsunagi_mem_lmdb_map_bytes gauge
                    \\tsunagi_mem_lmdb_map_bytes {d}
                    \\
                , .{
                    self.metrics.mem_gaps_keys_count.load(.acquire),
                    self.metrics.mem_gaps_first_seen_count.load(.acquire),
                    self.metrics.mem_gaps_last_seen_count.load(.acquire),
                    self.metrics.mem_gaps_keys_bytes_est.load(.acquire),
                    self.metrics.mem_gaps_first_seen_bytes_est.load(.acquire),
                    self.metrics.mem_gaps_last_seen_bytes_est.load(.acquire),
                    self.metrics.mem_gaps_total_bytes_est.load(.acquire),
                    self.metrics.mem_mempool_items.load(.acquire),
                    self.metrics.mem_mempool_bytes_est.load(.acquire),
                    self.metrics.mem_capture_bytes_est.load(.acquire),
                    self.metrics.mem_lmdb_map_bytes.load(.acquire),
                }) catch {};
            }

            // FastSync controller gauges
            {
                wr.print(
                    \\# HELP tsunagi_fastsync_enabled FastSync controller enabled (0/1)
                    \\# TYPE tsunagi_fastsync_enabled gauge
                    \\tsunagi_fastsync_enabled {d}
                    \\# HELP tsunagi_fastsync_state_code FastSync state (0=OFF 1=WARMUP 2=PUSHING 3=READY)
                    \\# TYPE tsunagi_fastsync_state_code gauge
                    \\tsunagi_fastsync_state_code {d}
                    \\# HELP tsunagi_fastsync_last_unix FastSync last evaluation unix timestamp
                    \\# TYPE tsunagi_fastsync_last_unix gauge
                    \\tsunagi_fastsync_last_unix {d}
                    \\# HELP tsunagi_fastsync_actions_total FastSync actions taken
                    \\# TYPE tsunagi_fastsync_actions_total counter
                    \\tsunagi_fastsync_actions_total {d}
                    \\# HELP tsunagi_fastsync_last_action_code FastSync last action (1=backfill 2=capture 3=tsf 4=clear)
                    \\# TYPE tsunagi_fastsync_last_action_code gauge
                    \\tsunagi_fastsync_last_action_code {d}
                    \\
                , .{
                    self.metrics.fastsync_enabled.load(.acquire),
                    self.metrics.fastsync_state_code.load(.acquire),
                    self.metrics.fastsync_last_unix.load(.acquire),
                    self.metrics.fastsync_actions_total.load(.acquire),
                    self.metrics.fastsync_last_action_code.load(.acquire),
                }) catch {};
            }

            // FastSync ETA + convergence slopes
            {
                const SLOPE_OFFSET: u64 = 10_000_000;
                const eta_min = self.metrics.fastsync_eta_minutes.load(.acquire);
                const eta_rc = self.metrics.fastsync_eta_reason_code.load(.acquire);
                const td_raw = self.metrics.convergence_truth_delta_5m_x1e6.load(.acquire);
                const vd_raw = self.metrics.convergence_value_delta_5m_x1e6.load(.acquire);
                const ed_raw = self.metrics.convergence_missing_ema_delta_5m_x1e3.load(.acquire);
                const sw_unix = self.metrics.convergence_slope_window_unix.load(.acquire);
                // Decode signed deltas for float output
                const td_i: i64 = @as(i64, @intCast(td_raw)) - @as(i64, @intCast(SLOPE_OFFSET));
                const vd_i: i64 = @as(i64, @intCast(vd_raw)) - @as(i64, @intCast(SLOPE_OFFSET));
                const ed_i: i64 = @as(i64, @intCast(ed_raw)) - @as(i64, @intCast(SLOPE_OFFSET));
                const td_f: f64 = @as(f64, @floatFromInt(td_i)) / 1_000_000.0;
                const vd_f: f64 = @as(f64, @floatFromInt(vd_i)) / 1_000_000.0;
                const ed_f: f64 = @as(f64, @floatFromInt(ed_i)) / 1_000.0;
                wr.print(
                    \\# HELP tsunagi_fastsync_eta_minutes Conservative ETA to READY (0=n/a or ready)
                    \\# TYPE tsunagi_fastsync_eta_minutes gauge
                    \\tsunagi_fastsync_eta_minutes {d}
                    \\# HELP tsunagi_fastsync_eta_reason_code ETA reason (0=ready 1=no_slopes 2=wrong_dir 3=computed)
                    \\# TYPE tsunagi_fastsync_eta_reason_code gauge
                    \\tsunagi_fastsync_eta_reason_code {d}
                    \\# HELP tsunagi_convergence_truth_delta_5m Truth ratio change over 5m window
                    \\# TYPE tsunagi_convergence_truth_delta_5m gauge
                    \\tsunagi_convergence_truth_delta_5m {d:.6}
                    \\# HELP tsunagi_convergence_value_delta_5m Value check ratio change over 5m window
                    \\# TYPE tsunagi_convergence_value_delta_5m gauge
                    \\tsunagi_convergence_value_delta_5m {d:.6}
                    \\# HELP tsunagi_convergence_missing_ema_delta_5m Missing EMA change over 5m window
                    \\# TYPE tsunagi_convergence_missing_ema_delta_5m gauge
                    \\tsunagi_convergence_missing_ema_delta_5m {d:.3}
                    \\# HELP tsunagi_convergence_window_unix Convergence slope window timestamp
                    \\# TYPE tsunagi_convergence_window_unix gauge
                    \\tsunagi_convergence_window_unix {d}
                    \\
                , .{ eta_min, eta_rc, td_f, vd_f, ed_f, sw_unix }) catch {};
            }

            writeRespBytes(w, 200, "text/plain; version=0.0.4; charset=utf-8", out.items);
            return;
        }

        // Phase 53: Decision stack operator endpoint
        if (std.mem.eql(u8, path, "/decision")) {
            const decision_state_mod = @import("../ledger/decision_state.zig");
            const snap = decision_state_mod.g_decision_state;
            var dout = std.array_list.Managed(u8).init(self.alloc);
            defer dout.deinit();
            decision_state_mod.writeJson(&snap, compat.listWriter(&dout));
            writeRespBytes(w, 200, "application/json", dout.items);
            return;
        }

        if (std.mem.eql(u8, path, "/state")) {
            var out = std.array_list.Managed(u8).init(self.alloc);
            defer out.deinit();
            const sw = compat.listWriter(&out);

            const now = compat.timestamp();
            const m = self.metrics;

            // Tip
            const st_slot = m.slot.load(.acquire);
            const st_block = m.block_no.load(.acquire);
            const st_utxo = m.utxo.load(.acquire);

            // Header
            const st_hh = m.header_height.load(.acquire);
            const st_hs = m.header_head_stable.load(.acquire);
            const st_hv_total = m.header_validate_total.load(.acquire);
            const st_hv_fail = m.header_validate_fail_total.load(.acquire);
            const st_hv_ratio = m.header_validate_fail_ratio_x1e6.load(.acquire);

            // Convergence
            const st_ltb = m.lmdb_truth_blocks.load(.acquire);
            const st_lfb = m.lmdb_fallback_blocks.load(.acquire);
            const st_denom = st_ltb + st_lfb;
            const st_truth_x1e6: u64 = if (st_denom == 0) 0 else (st_ltb * 1_000_000) / st_denom;
            const st_missing_ema = m.ledger_missing_inputs_ema.load(.acquire);
            const st_vc_ratio = m.ledger_value_check_ratio_x1e6.load(.acquire);
            const st_gate_ready = m.convergence_gate_ready.load(.acquire);
            const st_gate_stable = m.convergence_gate_stable_seconds.load(.acquire);

            // Backfill
            const st_bf_runs = m.backfill_runs_total.load(.acquire);
            const st_bf_blocks = m.backfill_blocks_total.load(.acquire);
            const st_bf_cursor = m.backfill_cursor_offset.load(.acquire);
            const st_bf_seg = m.backfill_segment_done_x1e6.load(.acquire);
            const st_bf_eof = m.backfill_eof_idle_total.load(.acquire);

            // Gaps
            const st_gk = m.gap_missing_keys.load(.acquire);
            const st_gr = m.gap_repeat_ratio_x1e6.load(.acquire);
            const st_gh = m.gap_hot_top_age_seconds.load(.acquire);
            const st_gd = m.gap_keys_delta_5m.load(.acquire);
            const st_ge = m.gap_evictions_5m.load(.acquire);
            const st_gc = m.gap_hot_changes_5m.load(.acquire);
            const st_gw = m.gap_window_unix.load(.acquire);
            const st_gwr = m.gap_win_rate_x1e6.load(.acquire);

            sw.print(
                \\{{"state_schema_version":2,"baey_schema_version":1,"unix":{d},"metrics_addr":"{d}.{d}.{d}.{d}","metrics_port":{d},"tip":{{"slot":{d},"block":{d},"utxo_est":{d}}},"header":{{"height":{d},"stable":{d},"validate":{{"total":{d},"fail":{d},"ratio":"{d}.{d:0>6}"}}}},"convergence":{{"truth_ratio":"{d}.{d:0>6}","missing_ema":{d},"value_check_ratio":"{d}.{d:0>6}","gate_ready":{d},"gate_stable_seconds":{d}}}
            , .{
                now,
                self.bind_addr[0], self.bind_addr[1], self.bind_addr[2], self.bind_addr[3], self.bind_port,
                st_slot, st_block, st_utxo,
                st_hh, st_hs,
                st_hv_total, st_hv_fail, st_hv_ratio / 1_000_000, st_hv_ratio % 1_000_000,
                st_truth_x1e6 / 1_000_000, st_truth_x1e6 % 1_000_000,
                st_missing_ema,
                st_vc_ratio / 1_000_000, st_vc_ratio % 1_000_000,
                st_gate_ready, st_gate_stable,
            }) catch {};

            sw.print(
                \\,"backfill":{{"runs_total":{d},"blocks_total":{d},"cursor_offset":{d},"segment_done_ratio":"{d}.{d:0>6}","eof_idle_total":{d}}},"gaps":{{"missing_keys":{d},"repeat_ratio":"{d}.{d:0>6}","hot_top_age_seconds":{d},"delta_keys_5m":{d},"evictions_delta_5m":{d},"hot_changes_5m":{d},"window_unix":{d},"win_rate":"{d}.{d:0>6}"}}
            , .{
                st_bf_runs, st_bf_blocks, st_bf_cursor, st_bf_seg / 1_000_000, st_bf_seg % 1_000_000, st_bf_eof,
                st_gk,
                st_gr / 1_000_000, st_gr % 1_000_000,
                st_gh, st_gd, st_ge, st_gc, st_gw,
                st_gwr / 1_000_000, st_gwr % 1_000_000,
            }) catch {};

            // Consensus (stall + density + error deltas for BAEY)
            {
                const st_stall = m.peer_stall_active.load(.acquire);
                const st_ds = m.chain_density_smoothed_last_x1e6.load(.acquire);
                const st_drm = m.chain_density_recommended_min_x1e6.load(.acquire);
                const st_herr = m.consensus_header_err_delta_5m.load(.acquire);
                const st_kto = m.consensus_keepalive_to_delta_5m.load(.acquire);
                sw.print(
                    \\,"consensus":{{"stall_active":{d},"density_smoothed":"{d}.{d:0>6}","density_rec_min":"{d}.{d:0>6}","herr_delta_5m":{d},"keepalive_to_delta_5m":{d},
                , .{
                    st_stall,
                    st_ds / 1_000_000, st_ds % 1_000_000,
                    st_drm / 1_000_000, st_drm % 1_000_000,
                    st_herr, st_kto,
                }) catch {};
                sw.print(
                    \\"stall_reason_code":{d},"stall_age_seconds":{d},"blockfetch_age_seconds":{d},"keepalive_age_seconds":{d},"window_unix":{d},"blockfetch_batches_delta_5m":{d},"keepalive_pongs_delta_5m":{d},"peer_closed_delta_5m":{d},"header_store_writes_delta_5m":{d}}}
                , .{
                    m.consensus_stall_reason_code.load(.acquire),
                    m.consensus_stall_age_seconds.load(.acquire),
                    m.consensus_blockfetch_age_seconds.load(.acquire),
                    m.consensus_keepalive_age_seconds.load(.acquire),
                    m.consensus_window_unix.load(.acquire),
                    m.consensus_blockfetch_batches_delta_5m.load(.acquire),
                    m.consensus_keepalive_pongs_delta_5m.load(.acquire),
                    m.consensus_peer_closed_delta_5m.load(.acquire),
                    m.consensus_header_store_writes_delta_5m.load(.acquire),
                }) catch {};
            }

            // Genesis
            {
                const st_gen_unix = m.producer_genesis_unix.load(.acquire);
                const st_gen_slot = m.producer_slot_length_s.load(.acquire);
                const st_gen_ok = m.producer_genesis_parse_ok.load(.acquire);
                const st_gen_path = m.producer_genesis_path_ok.load(.acquire);
                const st_gen_err = m.producer_genesis_last_error_code.load(.acquire);
                sw.print(
                    \\,"genesis":{{"unix":{d},"slot_length_s":{d},"parse_ok":{d},"path_ok":{d},"error_code":{d}}}
                , .{ st_gen_unix, st_gen_slot, st_gen_ok, st_gen_path, st_gen_err }) catch {};
            }

            // Producer clock
            {
                const pc_obs = m.producer_observed_slot.load(.acquire);
                const pc_est = m.producer_estimated_slot.load(.acquire);
                const pc_drift_raw = m.producer_drift_last_slots.load(.acquire);
                const pc_drift: i64 = @as(i64, @intCast(pc_drift_raw)) - 10_000_000;
                const pc_abs_last = m.producer_drift_abs_last.load(.acquire);
                const pc_abs_max = m.producer_drift_abs_max.load(.acquire);
                const pc_ev = m.producer_drift_events_total.load(.acquire);
                const pc_ok = m.producer_clock_ok.load(.acquire);
                sw.print(
                    \\,"producer_clock":{{"observed_slot":{d},"estimated_slot":{d},"drift_last":{d},"drift_abs_last":{d},"drift_abs_max":{d},"drift_events_total":{d},"clock_ok":{d}}}
                , .{ pc_obs, pc_est, pc_drift, pc_abs_last, pc_abs_max, pc_ev, pc_ok }) catch {};
            }

            // Producer keys
            {
                const pk_en = m.producer_keys_enabled.load(.acquire);
                const pk_pok = m.producer_keys_parse_ok.load(.acquire);
                const pk_vt = m.producer_keys_validate_total.load(.acquire);
                const pk_err = m.producer_keys_err_code_last.load(.acquire);
                const pk_pool = m.producer_pool_ok.load(.acquire);
                const pk_kes = m.producer_kes_ok.load(.acquire);
                const pk_vrf = m.producer_vrf_key_ok.load(.acquire);
                const pk_perms = m.producer_keys_perms_ok.load(.acquire);
                const pk_read = m.producer_keys_readable_ok.load(.acquire);
                sw.print(
                    \\,"producer_keys":{{"enabled":{d},"parse_ok":{d},"validate_total":{d},"err_code_last":{d},"pool_ok":{d},"kes_ok":{d},"vrf_ok":{d},"perms_ok":{d},"readable_ok":{d}}}
                , .{ pk_en, pk_pok, pk_vt, pk_err, pk_pool, pk_kes, pk_vrf, pk_perms, pk_read }) catch {};
            }

            // Producer leader model
            {
                const pl_epoch = m.producer_epoch_last.load(.acquire);
                const pl_sie = m.producer_slot_in_epoch_last.load(.acquire);
                const pl_elig = m.producer_leader_eligible_last.load(.acquire);
                const pl_sf = m.producer_stake_fraction_x1e9.load(.acquire);
                const pl_asc = m.producer_active_slot_coeff_x1e6.load(.acquire);
                const pl_prob = m.producer_leader_probability_x1e6.load(.acquire);
                const pl_exp = m.producer_expected_leaders_per_epoch.load(.acquire);
                const pl_rc = m.producer_leader_reason_code_last.load(.acquire);
                const pl_et_en = m.producer_elig_test_enabled.load(.acquire);
                const pl_et_slot = m.producer_elig_test_slot_in_epoch.load(.acquire);
                const pl_et_win = m.producer_elig_test_window_s.load(.acquire);
                const pl_et_end = m.producer_elig_test_target_end_slot_in_epoch.load(.acquire);
                const pl_et_active = m.producer_elig_test_window_active.load(.acquire);
                const pl_et_ov_en = m.producer_elig_test_override_enabled.load(.acquire);
                const pl_et_ov_tgt = m.producer_elig_test_override_target.load(.acquire);
                const pl_pr_u = m.producer_praos_u_x1e12.load(.acquire);
                const pl_pr_t = m.producer_praos_thresh_x1e12.load(.acquire);
                const pl_pr_leader = m.producer_praos_leader_last.load(.acquire);
                const pl_pr_rc = m.producer_praos_reason_code_last.load(.acquire);
                const pl_pr_checks = m.producer_praos_checks_total.load(.acquire);
                sw.print(
                    \\,"producer_leader":{{"epoch_last":{d},"slot_in_epoch_last":{d},"leader_eligible_last":{d},"stake_fraction_x1e9":{d},"asc_x1e6":{d},"prob_x1e6":{d},"expected_leaders_per_epoch":{d},"leader_reason_code":{d},"elig_test_enabled":{d},"elig_test_slot_in_epoch":{d},"elig_test_window_s":{d},"elig_test_target_end_slot_in_epoch":{d},"elig_test_window_active":{d},"elig_test_override_enabled":{d},"elig_test_override_target":{d},"praos_u_x1e12":{d},"praos_thresh_x1e12":{d},"praos_leader_last":{d},"praos_reason_code_last":{d},"praos_checks_total":{d}}}
                , .{ pl_epoch, pl_sie, pl_elig, pl_sf, pl_asc, pl_prob, pl_exp, pl_rc, pl_et_en, pl_et_slot, pl_et_win, pl_et_end, pl_et_active, pl_et_ov_en, pl_et_ov_tgt, pl_pr_u, pl_pr_t, pl_pr_leader, pl_pr_rc, pl_pr_checks }) catch {};

                // Producer ETA — deterministic eligibility countdown
                const slots_per_epoch: u64 = 432000;
                var eta_remaining: u64 = 0;
                var eta_hm: []const u8 = "n/a";
                var eta_when: []const u8 = "n/a";
                var eta_hm_buf: [16]u8 = undefined;
                if (pl_et_en != 0 and pl_et_slot != 0) {
                    if (pl_sie <= pl_et_slot) {
                        eta_remaining = pl_et_slot - pl_sie;
                        eta_when = "this_epoch";
                    } else {
                        eta_remaining = (slots_per_epoch - pl_sie) + pl_et_slot;
                        eta_when = "next_epoch";
                    }
                    const hours = eta_remaining / 3600;
                    const mins = (eta_remaining % 3600) / 60;
                    eta_hm = std.fmt.bufPrint(&eta_hm_buf, "{d}h{d:0>2}m", .{ hours, mins }) catch "n/a";
                }
                sw.print(
                    \\,"producer_eta":{{"elig_test_remaining_seconds":{d},"elig_test_remaining_hm":"{s}","elig_test_when":"{s}"}}
                , .{ eta_remaining, eta_hm, eta_when }) catch {};
            }

            // VRF sub-object
            {
                const vrf_en = m.producer_vrf_enabled.load(.acquire);
                const vrf_pok = m.producer_vrf_parse_ok.load(.acquire);
                const vrf_att = m.producer_vrf_attempt_total.load(.acquire);
                const vrf_ct = m.producer_vrf_checked_total.load(.acquire);
                const vrf_cl = m.producer_vrf_checked_last.load(.acquire);
                const vrf_prob = m.producer_vrf_probability_x1e6.load(.acquire);
                const vrf_proof = m.producer_vrf_proof_present.load(.acquire);
                const vrf_output = m.producer_vrf_output_present.load(.acquire);
                const vrf_rc = m.producer_vrf_reason_code_last.load(.acquire);
                const vrf_init = m.producer_vrf_init_ok.load(.acquire);
                const vrf_vok = m.producer_vrf_verify_ok_last.load(.acquire);
                const vrf_opfx = m.producer_vrf_output_prefix_last.load(.acquire);
                const vrf_tm = m.producer_vrf_tick_mode_code.load(.acquire);
                const vrf_lcs = m.producer_vrf_last_checked_slot.load(.acquire);
                const vrf_skip = m.producer_vrf_skipped_total.load(.acquire);
                // v0.9.8 proof artifact fields
                const vrf_plen = m.producer_vrf_proof_len_last.load(.acquire);
                const vrf_olen = m.producer_vrf_output_len_last.load(.acquire);
                const vrf_ppfx = m.producer_vrf_proof_prefix_last.load(.acquire);
                const hex_chars_v = "0123456789abcdef";
                var vp_hex: [16]u8 = undefined;
                var vp_bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &vp_bytes, vrf_ppfx, .big);
                for (0..8) |vi| {
                    vp_hex[vi * 2] = hex_chars_v[vp_bytes[vi] >> 4];
                    vp_hex[vi * 2 + 1] = hex_chars_v[vp_bytes[vi] & 0xf];
                }
                var vo_hex: [16]u8 = undefined;
                var vo_bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &vo_bytes, vrf_opfx, .big);
                for (0..8) |vi2| {
                    vo_hex[vi2 * 2] = hex_chars_v[vo_bytes[vi2] >> 4];
                    vo_hex[vi2 * 2 + 1] = hex_chars_v[vo_bytes[vi2] & 0xf];
                }
                sw.print(
                    \\,"producer_vrf":{{"enabled":{d},"parse_ok":{d},"attempt_total":{d},"checked_total":{d},"checked_last":{d},"probability_x1e6":{d},"proof_present":{d},"output_present":{d},"reason_code":{d},"init_ok":{d},"verify_ok_last":{d},"output_prefix_last":{d},"tick_mode_code":{d},"last_checked_slot":{d},"skipped_total":{d},"proof_len_last":{d},"output_len_last":{d},"proof_prefix_hex":"{s}","output_prefix_hex":"{s}"}}
                , .{ vrf_en, vrf_pok, vrf_att, vrf_ct, vrf_cl, vrf_prob, vrf_proof, vrf_output, vrf_rc, vrf_init, vrf_vok, vrf_opfx, vrf_tm, vrf_lcs, vrf_skip, vrf_plen, vrf_olen, &vp_hex, &vo_hex }) catch {};
            }

            // KES sub-object
            {
                const kes_en = m.producer_kes_enabled.load(.acquire);
                const kes_pok = m.producer_kes_parse_ok.load(.acquire);
                const kes_att = m.producer_kes_attempt_total.load(.acquire);
                const kes_sig = m.producer_kes_signed_total.load(.acquire);
                const kes_sp = m.producer_kes_sig_present_last.load(.acquire);
                const kes_rc = m.producer_kes_reason_code_last.load(.acquire);
                sw.print(
                    \\,"producer_kes":{{"enabled":{d},"parse_ok":{d},"attempt_total":{d},"signed_total":{d},"sig_present_last":{d},"reason_code_last":{d}}}
                , .{ kes_en, kes_pok, kes_att, kes_sig, kes_sp, kes_rc }) catch {};
            }

            // Header candidate sub-object
            {
                const c_built = m.producer_candidate_built_total.load(.acquire);
                const c_signed = m.producer_candidate_signed_total.load(.acquire);
                const c_slot = m.producer_candidate_last_slot.load(.acquire);
                const c_body = m.producer_candidate_body_hash_prefix.load(.acquire);
                const c_sig = m.producer_candidate_sig_present_last.load(.acquire);
                const c_hdr_len = m.producer_candidate_hdr_bytes_len.load(.acquire);
                const c_hdr_w0 = m.producer_candidate_hdr_hash_w0.load(.acquire);
                const c_hdr_w1 = m.producer_candidate_hdr_hash_w1.load(.acquire);
                // Format body_hash_prefix as 16-char hex
                const hex_chars = "0123456789abcdef";
                var body_hex: [16]u8 = undefined;
                var body_bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &body_bytes, c_body, .big);
                for (0..8) |bi| {
                    body_hex[bi * 2] = hex_chars[body_bytes[bi] >> 4];
                    body_hex[bi * 2 + 1] = hex_chars[body_bytes[bi] & 0xf];
                }
                // Format hdr_hash_prefix as 16-char hex (from w0)
                var hdr_hex: [16]u8 = undefined;
                var hdr_bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &hdr_bytes, c_hdr_w0, .big);
                for (0..8) |hi| {
                    hdr_hex[hi * 2] = hex_chars[hdr_bytes[hi] >> 4];
                    hdr_hex[hi * 2 + 1] = hex_chars[hdr_bytes[hi] & 0xf];
                }
                const zs_att = m.producer_zig_sig_attempt_total.load(.acquire);
                const zs_ok = m.producer_zig_sig_ok_total.load(.acquire);
                const zs_pres = m.producer_zig_sig_present_last.load(.acquire);
                const zs_pfx = m.producer_zig_sig_prefix_last.load(.acquire);
                const zs_rc = m.producer_zig_sig_reason_last.load(.acquire);
                // KES sign fields
                const ks_att = m.producer_kes_sign_attempt_total.load(.acquire);
                const ks_ok = m.producer_kes_sign_ok_total.load(.acquire);
                const ks_pres = m.producer_kes_sign_present_last.load(.acquire);
                const ks_pfx = m.producer_kes_sign_prefix_last.load(.acquire);
                const ks_rc = m.producer_kes_sign_reason_last.load(.acquire);
                const ks_label = m.producer_kes_sign_label_last.load(.acquire);
                var ks_hex: [16]u8 = undefined;
                var ks_bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &ks_bytes, ks_pfx, .big);
                for (0..8) |ki| {
                    ks_hex[ki * 2] = hex_chars[ks_bytes[ki] >> 4];
                    ks_hex[ki * 2 + 1] = hex_chars[ks_bytes[ki] & 0xf];
                }
                const ks_label_str: []const u8 = if (ks_label == 1) "KES_PLACEHOLDER_ED25519" else "n/a";
                // Candidate signing proof (v0.9.7)
                const cs_pfx = m.producer_candidate_sig_prefix_last.load(.acquire);
                const cs_rc = m.producer_candidate_sign_reason_code_last.load(.acquire);
                var cs_hex: [16]u8 = undefined;
                var cs_bytes_tmp: [8]u8 = undefined;
                std.mem.writeInt(u64, &cs_bytes_tmp, cs_pfx, .big);
                for (0..8) |ci| {
                    cs_hex[ci * 2] = hex_chars[cs_bytes_tmp[ci] >> 4];
                    cs_hex[ci * 2 + 1] = hex_chars[cs_bytes_tmp[ci] & 0xf];
                }
                // Block body builder (v0.9.9)
                const b_cbor_len = m.producer_body_cbor_len.load(.acquire);
                const b_hw0 = m.producer_body_hash_w0.load(.acquire);
                const b_hw1 = m.producer_body_hash_w1.load(.acquire);
                const b_hw2 = m.producer_body_hash_w2.load(.acquire);
                const b_hw3 = m.producer_body_hash_w3.load(.acquire);
                var bh_hex: [64]u8 = undefined;
                var bh_bytes: [32]u8 = undefined;
                std.mem.writeInt(u64, bh_bytes[0..8], b_hw0, .big);
                std.mem.writeInt(u64, bh_bytes[8..16], b_hw1, .big);
                std.mem.writeInt(u64, bh_bytes[16..24], b_hw2, .big);
                std.mem.writeInt(u64, bh_bytes[24..32], b_hw3, .big);
                for (0..32) |bhi| {
                    bh_hex[bhi * 2] = hex_chars[bh_bytes[bhi] >> 4];
                    bh_hex[bhi * 2 + 1] = hex_chars[bh_bytes[bhi] & 0xf];
                }
                sw.print(
                    \\,"producer_candidate":{{"built_total":{d},"signed_total":{d},"last_slot":{d},"body_hash_prefix":"{s}","sig_present_last":{d},"sig_prefix_hex":"{s}","sign_reason_code_last":{d},"hdr_bytes_len":{d},"hdr_hash_prefix_hex":"{s}","hdr_hash_w0":{d},"hdr_hash_w1":{d},"body_cbor_len":{d},"body_hash_hex":"{s}","body_hash_w0":{d},"body_hash_w1":{d},"body_hash_w2":{d},"body_hash_w3":{d},"zig_sig_attempt_total":{d},"zig_sig_ok_total":{d},"zig_sig_present_last":{d},"zig_sig_prefix_last":{d},"zig_sig_reason_last":{d},"kes_sign":{{"attempt_total":{d},"ok_total":{d},"present_last":{d},"sig_prefix_hex":"{s}","reason_code_last":{d},"label":"{s}"}}}}
                , .{ c_built, c_signed, c_slot, &body_hex, c_sig, &cs_hex, cs_rc, c_hdr_len, &hdr_hex, c_hdr_w0, c_hdr_w1, b_cbor_len, &bh_hex, b_hw0, b_hw1, b_hw2, b_hw3, zs_att, zs_ok, zs_pres, zs_pfx, zs_rc, ks_att, ks_ok, ks_pres, &ks_hex, ks_rc, ks_label_str }) catch {};
            }

            // Producer proof bundle timestamp
            {
                const pp_unix = m.last_producer_proof_unix.load(.acquire);
                sw.print(
                    \\,"last_producer_proof_unix":{d}
                , .{pp_unix}) catch {};
            }

            // Producer proof pack (v1.0.0)
            {
                const pk_total = m.producer_pack_total.load(.acquire);
                const pk_unix = m.producer_pack_last_unix.load(.acquire);
                sw.print(
                    \\,"producer_pack":{{"total":{d},"last_unix":{d}}}
                , .{ pk_total, pk_unix }) catch {};
            }

            // KES period gate (v1.0.2, enhanced v1.1.2)
            {
                const kp_cur = m.producer_kes_current_period.load(.acquire);
                const kp_valid = m.producer_kes_period_valid_last.load(.acquire);
                const kp_rc = m.producer_kes_period_reason_code_last.load(.acquire);
                const kp_start = m.producer_kes_start_period.load(.acquire);
                const kp_max = m.producer_kes_max_periods.load(.acquire);
                const kp_ss = m.producer_kes_period_start_slot.load(.acquire);
                const kp_es = m.producer_kes_period_end_slot.load(.acquire);
                const kp_roll = m.producer_kes_rollovers_total.load(.acquire);
                const kp_lrs = m.producer_kes_last_rollover_slot.load(.acquire);
                const kp_oor = m.producer_kes_out_of_range_total.load(.acquire);
                const kp_ref = m.producer_kes_sign_refused_total.load(.acquire);
                sw.print(
                    \\,"producer_kes_period":{{"current_period":{d},"period_valid_last":{d},"period_reason_code_last":{d},"start_period":{d},"max_periods":{d},"period_start_slot":{d},"period_end_slot":{d},"rollovers_total":{d},"last_rollover_slot":{d},"out_of_range_total":{d},"sign_refused_total":{d}}}
                , .{ kp_cur, kp_valid, kp_rc, kp_start, kp_max, kp_ss, kp_es, kp_roll, kp_lrs, kp_oor, kp_ref }) catch {};
            }

            // Praos sub-object (v1.0.9, expanded v1.1.3)
            {
                const pp_en = m.producer_praos_enabled.load(.acquire);
                const pp_lcs = m.producer_praos_last_checked_slot.load(.acquire);
                const pp_u = m.producer_praos_u_x1e12.load(.acquire);
                const pp_t = m.producer_praos_thresh_x1e12.load(.acquire);
                const pp_leader = m.producer_praos_leader_last.load(.acquire);
                const pp_rc = m.producer_praos_reason_code_last.load(.acquire);
                const pp_checks = m.producer_praos_checks_total.load(.acquire);
                const pp_sf = m.producer_stake_fraction_x1e9.load(.acquire);
                const pp_asc = m.producer_active_slot_coeff_x1e6.load(.acquire);
                const pp_ult = m.producer_praos_u_lt_t.load(.acquire);
                const pp_delta = m.producer_praos_delta_x1e12.load(.acquire);
                sw.print(
                    \\,"producer_praos":{{"enabled":{d},"last_checked_slot":{d},"u_x1e12":{d},"thresh_x1e12":{d},"leader_last":{d},"reason_code_last":{d},"checks_total":{d},"stake_fraction_x1e9":{d},"asc_x1e6":{d},"u_lt_t":{d},"delta_x1e12":{d}}}
                , .{ pp_en, pp_lcs, pp_u, pp_t, pp_leader, pp_rc, pp_checks, pp_sf, pp_asc, pp_ult, pp_delta }) catch {};
            }

            // Producer state digest (v1.2.0)
            {
                const dw0 = m.producer_state_digest_w0.load(.acquire);
                const dw1 = m.producer_state_digest_w1.load(.acquire);
                const dw2 = m.producer_state_digest_w2.load(.acquire);
                const dw3 = m.producer_state_digest_w3.load(.acquire);
                const hex_chars = "0123456789abcdef";
                var digest_hex: [64]u8 = undefined;
                const words = [4]u64{ dw0, dw1, dw2, dw3 };
                for (0..4) |wi| {
                    const bytes: [8]u8 = @bitCast(std.mem.nativeToBig(u64, words[wi]));
                    for (0..8) |bi| {
                        digest_hex[wi * 16 + bi * 2] = hex_chars[bytes[bi] >> 4];
                        digest_hex[wi * 16 + bi * 2 + 1] = hex_chars[bytes[bi] & 0xf];
                    }
                }
                sw.print(
                    \\,"producer_state_digest":"{s}"
                , .{&digest_hex}) catch {};
            }

            // Slot scheduler (v1.1.0)
            {
                const sc_epoch = m.producer_schedule_epoch_last.load(.acquire);
                const sc_wss = m.producer_schedule_window_start_slot.load(.acquire);
                const sc_wsz = m.producer_schedule_window_size.load(.acquire);
                const sc_leaders = m.producer_schedule_leaders_in_window.load(.acquire);
                const sc_next = m.producer_schedule_next_leader_offset.load(.acquire);
                const sc_u0 = m.producer_schedule_u0_x1e12.load(.acquire);
                const sc_t = m.producer_schedule_t_x1e12.load(.acquire);
                const sc_rc = m.producer_schedule_reason_code_last.load(.acquire);
                const sc_total = m.producer_schedule_compute_total.load(.acquire);
                const sc_us = m.producer_schedule_compute_us_total.load(.acquire);
                const sc_ls = m.producer_schedule_last_slot.load(.acquire);
                const sc_lu = m.producer_schedule_last_update_us.load(.acquire);
                sw.print(
                    \\,"producer_schedule":{{"epoch":{d},"window_start_slot":{d},"window_size":{d},"leaders_in_window":{d},"next_leader_offset":{d},"u0_x1e12":{d},"t_x1e12":{d},"reason_code":{d},"compute_total":{d},"compute_us_total":{d},"last_slot":{d},"last_update_us":{d}}}
                , .{ sc_epoch, sc_wss, sc_wsz, sc_leaders, sc_next, sc_u0, sc_t, sc_rc, sc_total, sc_us, sc_ls, sc_lu }) catch {};
            }

            // Producer timing (hardening)
            {
                const pt_vrf_total = m.producer_vrf_compute_us_total.load(.acquire);
                const pt_vrf_last = m.producer_vrf_compute_us_last.load(.acquire);
                const pt_tick_total = m.producer_tick_us_total.load(.acquire);
                const pt_tick_last = m.producer_tick_us_last.load(.acquire);
                const pt_tick_max = m.producer_tick_us_max.load(.acquire);
                const pt_sched_total = m.producer_schedule_compute_us_total.load(.acquire);
                sw.print(
                    \\,"producer_timing":{{"vrf_us_total":{d},"vrf_us_last":{d},"tick_us_total":{d},"tick_us_last":{d},"tick_us_max":{d},"schedule_us_total":{d}}}
                , .{ pt_vrf_total, pt_vrf_last, pt_tick_total, pt_tick_last, pt_tick_max, pt_sched_total }) catch {};
            }

            // State digest (full 32 bytes = 64 hex chars)
            {
                const sd_w0 = m.state_digest_hi.load(.acquire);
                const sd_w1 = m.state_digest_lo.load(.acquire);
                const sd_w2 = m.state_digest_w2.load(.acquire);
                const sd_w3 = m.state_digest_w3.load(.acquire);
                const sd_unix = m.state_digest_unix.load(.acquire);
                var sd_bytes: [32]u8 = undefined;
                std.mem.writeInt(u64, sd_bytes[0..8], sd_w0, .big);
                std.mem.writeInt(u64, sd_bytes[8..16], sd_w1, .big);
                std.mem.writeInt(u64, sd_bytes[16..24], sd_w2, .big);
                std.mem.writeInt(u64, sd_bytes[24..32], sd_w3, .big);
                const hex_chars = "0123456789abcdef";
                var sd_hex: [64]u8 = undefined;
                for (0..32) |bi| {
                    sd_hex[bi * 2] = hex_chars[sd_bytes[bi] >> 4];
                    sd_hex[bi * 2 + 1] = hex_chars[sd_bytes[bi] & 0xf];
                }
                sw.print(
                    \\,"state_digest":{{"hex":"{s}","w0":{d},"w1":{d},"w2":{d},"w3":{d},"unix":{d}}}
                , .{ sd_hex, sd_w0, sd_w1, sd_w2, sd_w3, sd_unix }) catch {};
            }

            // Memory proof
            {
                const ca = @import("../../ops/counting_allocator.zig");
                const mem_rss = m.rss_kb.load(.acquire);
                const mem_lmdb = m.lmdb_map_size_bytes.load(.acquire);
                const mem_ac = ca.g_current_bytes.load(.acquire);
                const mem_ap = ca.g_peak_bytes.load(.acquire);
                const mem_ab = ca.g_baseline_bytes.load(.acquire);
                const mem_an: u64 = mem_ac -| mem_ab;
                const mem_alu = ca.g_peak_last_unix.load(.acquire);
                sw.print(
                    \\,"memory":{{"rss_kb":{d},"lmdb_map_size_bytes":{d},"alloc_current_bytes":{d},"alloc_peak_bytes":{d},"alloc_net_bytes":{d},"alloc_peak_last_unix":{d}
                , .{ mem_rss, mem_lmdb, mem_ac, mem_ap, mem_an, mem_alu }) catch {};
                // Attribution sub-object
                const ag_kc = m.mem_gaps_keys_count.load(.acquire);
                const ag_fc = m.mem_gaps_first_seen_count.load(.acquire);
                const ag_lc = m.mem_gaps_last_seen_count.load(.acquire);
                const ag_kb = m.mem_gaps_keys_bytes_est.load(.acquire);
                const ag_fb = m.mem_gaps_first_seen_bytes_est.load(.acquire);
                const ag_lb = m.mem_gaps_last_seen_bytes_est.load(.acquire);
                const ag_tb = m.mem_gaps_total_bytes_est.load(.acquire);
                const am_items = m.mem_mempool_items.load(.acquire);
                const am_bytes = m.mem_mempool_bytes_est.load(.acquire);
                const ac_bytes = m.mem_capture_bytes_est.load(.acquire);
                const al_bytes = m.mem_lmdb_map_bytes.load(.acquire);
                sw.print(
                    \\,"attrib":{{"gaps":{{"keys":{d},"first_seen":{d},"last_seen":{d},"bytes_est":{d},"keys_bytes_est":{d},"first_seen_bytes_est":{d},"last_seen_bytes_est":{d}}}
                , .{ ag_kc, ag_fc, ag_lc, ag_tb, ag_kb, ag_fb, ag_lb }) catch {};
                sw.print(
                    \\,"mempool":{{"items":{d},"bytes":{d}}},"capture":{{"bytes":{d}}},"lmdb":{{"map_bytes":{d}}}}}}}
                , .{ am_items, am_bytes, ac_bytes, al_bytes }) catch {};
            }

            // FastSync controller
            {
                const fs_en = m.fastsync_enabled.load(.acquire);
                const fs_st = m.fastsync_state_code.load(.acquire);
                const fs_lu = m.fastsync_last_unix.load(.acquire);
                const fs_la = m.fastsync_last_action_code.load(.acquire);
                const fs_eta = m.fastsync_eta_minutes.load(.acquire);
                const fs_erc = m.fastsync_eta_reason_code.load(.acquire);
                sw.print(
                    \\,"fastsync":{{"enabled":{d},"state":{d},"last_unix":{d},"last_action":{d},"eta_minutes":{d},"eta_reason_code":{d}}}
                , .{ fs_en, fs_st, fs_lu, fs_la, fs_eta, fs_erc }) catch {};
            }

            // Convergence slopes
            {
                const SLOPE_OFFSET: u64 = 10_000_000;
                const td_raw = m.convergence_truth_delta_5m_x1e6.load(.acquire);
                const vd_raw = m.convergence_value_delta_5m_x1e6.load(.acquire);
                const ed_raw = m.convergence_missing_ema_delta_5m_x1e3.load(.acquire);
                const sw_u = m.convergence_slope_window_unix.load(.acquire);
                const td_i: i64 = @as(i64, @intCast(td_raw)) - @as(i64, @intCast(SLOPE_OFFSET));
                const vd_i: i64 = @as(i64, @intCast(vd_raw)) - @as(i64, @intCast(SLOPE_OFFSET));
                const ed_i: i64 = @as(i64, @intCast(ed_raw)) - @as(i64, @intCast(SLOPE_OFFSET));
                const td_f: f64 = @as(f64, @floatFromInt(td_i)) / 1_000_000.0;
                const vd_f: f64 = @as(f64, @floatFromInt(vd_i)) / 1_000_000.0;
                const ed_f: f64 = @as(f64, @floatFromInt(ed_i)) / 1_000.0;
                sw.print(
                    \\,"convergence_slopes":{{"truth_delta_5m":{d:.6},"value_delta_5m":{d:.6},"missing_ema_delta_5m":{d:.3},"window_unix":{d}}}
                , .{ td_f, vd_f, ed_f, sw_u }) catch {};
            }

            // Authority model (real-time from atomics)
            {
                const st_ac = m.authority_confidence_x1e6.load(.acquire);
                const st_af = m.authority_finality_score_x1e6.load(.acquire);
                const st_ar = m.authority_reorg_events_5m.load(.acquire);
                const st_afk = m.authority_fork_events_total.load(.acquire);
                const st_adm = m.authority_reorg_depth_max_5m.load(.acquire);
                const st_ada = m.authority_reorg_depth_avg_x1e6.load(.acquire);
                const st_afd = m.authority_fork_delta_5m.load(.acquire);
                const st_ass = m.authority_stable_seconds.load(.acquire);
                const st_agate = m.authority_gate_active.load(.acquire);
                const st_areason = m.authority_reason_code_last.load(.acquire);
                const st_ared = m.authority_reorg_events_delta_5m.load(.acquire);
                const st_awu = m.authority_window_unix.load(.acquire);
                sw.print(
                    \\,"authority":{{"confidence":"{d}.{d:0>6}","finality":"{d}.{d:0>6}","reorg_events_5m":{d},"fork_events_total":{d},"reorg_depth_max_5m":{d},"reorg_depth_avg_5m":"{d}.{d:0>6}","fork_delta_5m":{d},"stable_seconds":{d},
                , .{
                    st_ac / 1_000_000, st_ac % 1_000_000,
                    st_af / 1_000_000, st_af % 1_000_000,
                    st_ar, st_afk, st_adm,
                    st_ada / 1_000_000, st_ada % 1_000_000,
                    st_afd, st_ass,
                }) catch {};
                sw.print(
                    \\"gate_active":{d},"reason_code_last":{d},"reorg_events_delta_5m":{d},"window_unix":{d}}}
                , .{ st_agate, st_areason, st_ared, st_awu }) catch {};
            }

            // BAeY peer selection state (v1.2.2)
            {
                sw.print(
                    \\,"baey":{{"enabled":1,"last_policy_tick_unix":{d},"selected_peer_index":{d},"cooldown_active":{d},"last_switch_reason_code":{d},"last_switch_unix":{d}}}
                , .{
                    m.baey_last_event_unix.load(.acquire),
                    m.baey_selected_peer_index.load(.acquire),
                    m.baey_cooldown_active.load(.acquire),
                    m.baey_last_switch_reason_code.load(.acquire),
                    m.baey_last_switch_unix.load(.acquire),
                }) catch {};
            }

            // BAEY policy tick
            {
                var pt = readLastPolicyTick(self.alloc);
                defer freePolicyTick(self.alloc, &pt);
                // Overlay health + runtime state from loop_stats.json
                overlayLoopStatsHealth(self.alloc, &pt);
                const safe_mode: u64 = if (isSafeModeActive(self.alloc)) 1 else 0;
                sw.print(
                    \\,"baey_policy":{{"unix":{d},"score":"{s}","action":"{s}","stall":{d},"density":"{s}","herr5m":{d},"kto5m":{d},"gap_keys_delta_5m":"{s}","gap_win_rate":"{s}","safe_mode_enabled":{d},
                , .{
                    pt.unix, pt.score, pt.action, pt.stall, pt.density,
                    pt.herr5m, pt.kto5m, pt.gap_delta, pt.win_rate, safe_mode,
                }) catch {};
                sw.print(
                    \\"authority":{{"confidence":"{s}","finality":"{s}","reorg_events_5m":{d},"fork_events_total":{d}}},
                , .{
                    pt.auth_conf, pt.auth_fin, pt.auth_reorg5m, pt.auth_forks,
                }) catch {};
                sw.print(
                    \\"producer_epoch":{d},"producer_slot_in_epoch":{d},"producer_prob_x1e6":{d},"producer_eligible":{d},"producer_expected_epoch":{d},"producer_reason_code":{d},"producer_stake_x1e9":{d},
                , .{
                    pt.producer_epoch, pt.producer_slot_in_epoch,
                    pt.producer_prob_x1e6, pt.producer_eligible,
                    pt.producer_expected_epoch, pt.producer_reason_code,
                    pt.producer_stake_x1e9,
                }) catch {};
                sw.print(
                    \\"leader_guard":{d},"leader_guard_score":"{s}","lg_reason":{d},"computed_action":"{s}","final_action":"{s}",
                , .{
                    pt.leader_guard, pt.leader_guard_score,
                    pt.lg_reason,
                    pt.computed_action, pt.final_action,
                }) catch {};
                // Health + runtime state (read from loop_stats.json)
                sw.print(
                    \\"health_score":{d},"health_band":"{s}","health_primary":"{s}","health_flags":{d},"rt_state":"{s}","rt_ticks":{d},"rt_reason":"{s}"}}
                , .{
                    pt.health_score, pt.health_band, pt.health_primary, pt.health_flags,
                    pt.rt_state, pt.rt_ticks, pt.rt_reason,
                }) catch {};
            }

            // Producer dry-run (v1.8.0)
            {
                sw.print(
                    \\,"producer_dryrun":{{"enabled":{d},"slots_checked_total":{d},"leader_slots_total":{d},"candidates_built_total":{d},"candidates_verified_total":{d},"last_leader_slot":{d},"last_candidate_unix":{d},"last_verify_ok":{d},"candidates_signed_total":{d},"last_sign_verify_ok":{d}}}
                , .{
                    m.producer_dryrun_enabled.load(.acquire),
                    m.producer_dryrun_slots_checked_total.load(.acquire),
                    m.producer_dryrun_leader_slots_total.load(.acquire),
                    m.producer_dryrun_candidates_built_total.load(.acquire),
                    m.producer_dryrun_candidates_verified_total.load(.acquire),
                    m.producer_dryrun_last_leader_slot.load(.acquire),
                    m.producer_dryrun_last_candidate_unix.load(.acquire),
                    m.producer_dryrun_last_verify_ok.load(.acquire),
                    m.producer_dryrun_candidates_signed_total.load(.acquire),
                    m.producer_dryrun_last_sign_verify_ok.load(.acquire),
                }) catch {};
            }

            // Tx submission relay (v1.7.0)
            {
                // TX decode failure counters
                {
                    const tx_decode_mod = @import("../ledger/tx_decode.zig");
                    const dc = tx_decode_mod.getDecodeCounters();
                    sw.print(
                        \\,"tx_decode":{{"blocks_total":{d},"decode_fail":{d},"input_parse_fail":{d},"output_parse_fail":{d},"hash_fail":{d},"txid_mismatch":{d},"ancestry_skip":{d},"block_total_fee_last":{d},"block_total_output_last":{d},"withdrawal_txs_total":{d},"cert_txs_total":{d},"cert_stake_reg":{d},"cert_stake_dereg":{d},"cert_delegation":{d},"cert_pool_reg":{d},"cert_pool_retire":{d},"cert_other":{d},"cert_total":{d},"script_txs_total":{d},"collateral_txs_total":{d},"input_duplicate":{d},"ttl_fail":{d},"start_fail":{d},"fee_zero":{d},"balance_violation":{d},"address_malformed":{d}}}
                    , .{
                        dc.blocks_total,
                        dc.decode_fail,
                        dc.input_parse_fail,
                        dc.output_parse_fail,
                        dc.hash_fail,
                        dc.txid_count_mismatch,
                        dc.ancestry_skip,
                        dc.block_total_fee_last,
                        dc.block_total_output_last,
                        dc.withdrawal_txs_total,
                        dc.cert_txs_total,
                        dc.cert_stake_reg_total,
                        dc.cert_stake_dereg_total,
                        dc.cert_delegation_total,
                        dc.cert_pool_reg_total,
                        dc.cert_pool_retire_total,
                        dc.cert_other_total,
                        dc.cert_total,
                        dc.script_txs_total,
                        dc.collateral_txs_total,
                        dc.input_duplicate_total,
                        dc.validity_ttl_fail,
                        dc.validity_start_fail,
                        dc.fee_zero_total,
                        dc.balance_violation_total,
                        dc.address_malformed_total,
                    }) catch {};
                }
                // Operator insight: 5-minute rolling windows
                {
                    const tx_decode_mod = @import("../ledger/tx_decode.zig");
                    const ring = tx_decode_mod.getInsightRing();
                    const cur = ring.getCurrent();
                    if (ring.latestCompleted()) |last| {
                        sw.print(
                            \\,"insight":{{"window_sec":300,"current":{{"start":{d},"blocks":{d},"txs":{d},"fees":{d},"ada_moved":{d},"scripts":{d},"certs":{d},"wdrls":{d}}},"last_completed":{{"start":{d},"blocks":{d},"txs":{d},"fees":{d},"ada_moved":{d},"scripts":{d},"certs":{d},"wdrls":{d}}}}}
                        , .{
                            cur.window_start_unix, cur.blocks_in_window, cur.total_tx_count,
                            cur.fees_lovelace, cur.ada_moved_lovelace,
                            cur.script_tx_count, cur.cert_tx_count, cur.withdrawal_count,
                            last.window_start_unix, last.blocks_in_window, last.total_tx_count,
                            last.fees_lovelace, last.ada_moved_lovelace,
                            last.script_tx_count, last.cert_tx_count, last.withdrawal_count,
                        }) catch {};
                    } else {
                        sw.print(
                            \\,"insight":{{"window_sec":300,"current":{{"start":{d},"blocks":{d},"txs":{d},"fees":{d},"ada_moved":{d},"scripts":{d},"certs":{d},"wdrls":{d}}},"last_completed":null}}
                        , .{
                            cur.window_start_unix, cur.blocks_in_window, cur.total_tx_count,
                            cur.fees_lovelace, cur.ada_moved_lovelace,
                            cur.script_tx_count, cur.cert_tx_count, cur.withdrawal_count,
                        }) catch {};
                    }
                }
                // Protocol params (from mempool global)
                {
                    const mp_mod = @import("../ledger/mempool.zig");
                    if (mp_mod.g_protocol_params) |pp| {
                        const src_str: []const u8 = if (pp.source == 1) "file" else "genesis";
                        sw.print(
                            \\,"protocol_params":{{"fee_per_byte":{d},"fee_fixed":{d},"min_utxo":{d},"max_tx_size":{d},"utxo_cost_per_byte":{d},"source":"{s}","reload_unix":{d}}}
                        , .{
                            pp.min_fee_a, pp.min_fee_b, pp.min_utxo_value, pp.max_tx_size,
                            pp.utxo_cost_per_byte, src_str, pp.reload_unix,
                        }) catch {};
                    }
                }
                // Propagated graph (from $TSUNAGI_HOME/trust/propagated_graph.json)
                {
                    const pg_home = compat.getEnvVarOwned(self.alloc, "TSUNAGI_HOME") catch null;
                    if (pg_home) |ph| {
                        defer self.alloc.free(ph);
                        const pg_path = std.fmt.allocPrint(self.alloc, "{s}/trust/propagated_graph.json", .{ph}) catch null;
                        if (pg_path) |pp| {
                            defer self.alloc.free(pp);
                            const pf = compat.fs.cwd().openFile(pp, .{}) catch null;
                            if (pf) |pgf_const| {
                                var pgf = pgf_const;
                                defer pgf.close();
                                const pd = pgf.deprecatedReader().readAllAlloc(self.alloc, 32768) catch null;
                                if (pd) |p_data| {
                                    defer self.alloc.free(p_data);
                                    const p_score = parseLoopStatsU64(p_data, "\"propagated_score\"") orelse 0;
                                    const p_nodes = parseLoopStatsU64(p_data, "\"nodes_total\"") orelse 0;
                                    const p_edges = parseLoopStatsU64(p_data, "\"edges_total\"") orelse 0;
                                    const p_depth = parseLoopStatsU64(p_data, "\"max_depth\"") orelse 0;
                                    const p_merged = parseLoopStatsU64(p_data, "\"peers_merged\"") orelse 0;
                                    const p_cluster = parseLoopStatsStr(p_data, "\"cluster\"");
                                    sw.print(
                                        \\,"propagated_graph":{{"score":{d},"nodes":{d},"edges":{d},"max_depth":{d},"peers_merged":{d},"cluster":"{s}"}}
                                    , .{ p_score, p_nodes, p_edges, p_depth, p_merged, p_cluster }) catch {};
                                }
                            }
                        }
                    }
                }
                // Trust graph (from $TSUNAGI_HOME/trust/trust_graph.json)
                {
                    const tg_home = compat.getEnvVarOwned(self.alloc, "TSUNAGI_HOME") catch null;
                    if (tg_home) |gh| {
                        defer self.alloc.free(gh);
                        const tg_path = std.fmt.allocPrint(self.alloc, "{s}/trust/trust_graph.json", .{gh}) catch null;
                        if (tg_path) |gp| {
                            defer self.alloc.free(gp);
                            const gf = compat.fs.cwd().openFile(gp, .{}) catch null;
                            if (gf) |gfile_const| {
                                var gfile = gfile_const;
                                defer gfile.close();
                                const gd = gfile.deprecatedReader().readAllAlloc(self.alloc, 32768) catch null;
                                if (gd) |g_data| {
                                    defer self.alloc.free(g_data);
                                    const g_score = parseLoopStatsU64(g_data, "\"graph_score\"") orelse 0;
                                    const g_nodes = parseLoopStatsU64(g_data, "\"nodes_total\"") orelse 0;
                                    const g_edges = parseLoopStatsU64(g_data, "\"edges_total\"") orelse 0;
                                    const g_fresh = parseLoopStatsU64(g_data, "\"nodes_fresh\"") orelse 0;
                                    const g_cluster = parseLoopStatsStr(g_data, "\"cluster\"");
                                    sw.print(
                                        \\,"trust_graph":{{"score":{d},"nodes":{d},"edges":{d},"fresh":{d},"cluster":"{s}"}}
                                    , .{ g_score, g_nodes, g_edges, g_fresh, g_cluster }) catch {};
                                }
                            }
                        }
                    }
                }
                // Federation (from $TSUNAGI_HOME/trust/federation.json)
                {
                    const fed_home = compat.getEnvVarOwned(self.alloc, "TSUNAGI_HOME") catch null;
                    if (fed_home) |fh| {
                        defer self.alloc.free(fh);
                        const fed_path = std.fmt.allocPrint(self.alloc, "{s}/trust/federation.json", .{fh}) catch null;
                        if (fed_path) |fp| {
                            defer self.alloc.free(fp);
                            const ff = compat.fs.cwd().openFile(fp, .{}) catch null;
                            if (ff) |ffile_const| {
                                var ffile = ffile_const;
                                defer ffile.close();
                                const fd = ffile.deprecatedReader().readAllAlloc(self.alloc, 32768) catch null;
                                if (fd) |fed_data| {
                                    defer self.alloc.free(fed_data);
                                    const f_score = parseLoopStatsU64(fed_data, "\"federation_score\"") orelse 0;
                                    const f_agree = parseLoopStatsU64(fed_data, "\"agreement_ratio_x1000\"") orelse 0;
                                    const f_verified = parseLoopStatsU64(fed_data, "\"peers_verified\"") orelse 0;
                                    const f_fresh = parseLoopStatsU64(fed_data, "\"peers_fresh\"") orelse 0;
                                    const f_divergent = parseLoopStatsU64(fed_data, "\"peers_divergent\"") orelse 0;
                                    const f_mean = parseLoopStatsU64(fed_data, "\"mean_reputation\"") orelse 0;
                                    sw.print(
                                        \\,"federation":{{"score":{d},"agreement_x1000":{d},"peers_verified":{d},"peers_fresh":{d},"peers_divergent":{d},"mean_reputation":{d}}}
                                    , .{ f_score, f_agree, f_verified, f_fresh, f_divergent, f_mean }) catch {};
                                }
                            }
                        }
                    }
                }
                // Trust network (from $TSUNAGI_HOME/trust/trust_network.json)
                {
                    const tn_home = compat.getEnvVarOwned(self.alloc, "TSUNAGI_HOME") catch null;
                    if (tn_home) |th| {
                        defer self.alloc.free(th);
                        const tn_path = std.fmt.allocPrint(self.alloc, "{s}/trust/trust_network.json", .{th}) catch null;
                        if (tn_path) |tp| {
                            defer self.alloc.free(tp);
                            const tf = compat.fs.cwd().openFile(tp, .{}) catch null;
                            if (tf) |tnf_const| {
                                var tnf = tnf_const;
                                defer tnf.close();
                                const td2 = tnf.deprecatedReader().readAllAlloc(self.alloc, 32768) catch null;
                                if (td2) |tn_data| {
                                    defer self.alloc.free(tn_data);
                                    const n_score = parseLoopStatsU64(tn_data, "\"network_score\"") orelse 0;
                                    const n_verified = parseLoopStatsU64(tn_data, "\"peers_verified\"") orelse 0;
                                    const n_total = parseLoopStatsU64(tn_data, "\"peers_total\"") orelse 0;
                                    const n_fresh = parseLoopStatsU64(tn_data, "\"peers_fresh\"") orelse 0;
                                    sw.print(
                                        \\,"trust_network":{{"network_score":{d},"peers_verified":{d},"peers_total":{d},"peers_fresh":{d}}}
                                    , .{ n_score, n_verified, n_total, n_fresh }) catch {};
                                }
                            }
                        }
                    }
                }
                // Reputation (from $TSUNAGI_HOME/trust/reputation.json)
                {
                    const rep_home = compat.getEnvVarOwned(self.alloc, "TSUNAGI_HOME") catch null;
                    if (rep_home) |rh| {
                        defer self.alloc.free(rh);
                        const rep_path = std.fmt.allocPrint(self.alloc, "{s}/trust/reputation.json", .{rh}) catch null;
                        if (rep_path) |rp| {
                            defer self.alloc.free(rp);
                            var rf = compat.fs.cwd().openFile(rp, .{}) catch null;
                            if (rf) |*rpf| {
                                defer rpf.close();
                                const rd = rpf.deprecatedReader().readAllAlloc(self.alloc, 8192) catch null;
                                if (rd) |rep_data| {
                                    const r_score = parseLoopStatsU64(rep_data, "\"reputation_score\"") orelse 0;
                                    const r_health = parseLoopStatsU64(rep_data, "\"health_average\"") orelse 0;
                                    const r_uptime = parseLoopStatsU64(rep_data, "\"uptime_ratio_x1000\"") orelse 0;
                                    const r_stab = parseLoopStatsU64(rep_data, "\"stability_ratio_x1000\"") orelse 0;
                                    const r_present = parseLoopStatsU64(rep_data, "\"snapshots_present\"") orelse 0;
                                    const r_expected = parseLoopStatsU64(rep_data, "\"snapshots_expected\"") orelse 0;
                                    const r_degraded = parseLoopStatsU64(rep_data, "\"degraded_events\"") orelse 0;
                                    sw.print(
                                        \\,"reputation":{{"score":{d},"health_avg":{d},"uptime_x1000":{d},"stability_x1000":{d},"snapshots":{d},"expected":{d},"degraded_events":{d}}}
                                    , .{
                                        r_score, r_health, r_uptime, r_stab, r_present, r_expected, r_degraded,
                                    }) catch {};
                                    // Don't free rep_data — slices may be used above (u64 parsing is done)
                                    self.alloc.free(rep_data);
                                }
                            }
                        }
                    }
                }
                const txe: u64 = if (self.txsub_enabled) 1 else 0;
                sw.print(
                    \\,"txsub":{{"enabled":{d},"rate_limit_per_min":10,"max_tx_bytes":65536,"requests_total":{d},"accepted_total":{d},"rejected_total":{d},"last_result_unix":{d}}}
                , .{
                    txe,
                    m.txsub_relay_requests_total.load(.acquire),
                    m.txsub_relay_accepted_total.load(.acquire),
                    m.txsub_relay_rejected_total.load(.acquire),
                    m.txsub_relay_last_result_unix.load(.acquire),
                }) catch {};

                // Stake distribution state
                sw.print(
                    \\,"stake":{{"net_registered":{d},"net_pools":{d},"delegations_total":{d},"total_certs":{d}}}}}
                , .{
                    m.stake_net_registered.load(.acquire),
                    m.stake_net_pools.load(.acquire),
                    m.stake_delegations_total.load(.acquire),
                    m.stake_total_certs.load(.acquire),
                }) catch {};
            }

            // Debug sanity: detect concatenated JSON
            if (std.mem.indexOf(u8, out.items, "}{") != null) {
                std.debug.print("/state WARNING: response contains '}}{{' — likely double JSON object\n", .{});
            }

            writeRespBytes(w, 200, "application/json", out.items);
            return;
        }

        writeResp(w, 404, "text/plain; charset=utf-8", "not found\n");
    }

    fn maybeLoadBackfillStats(self: *Server) void {
        const now = compat.timestamp();
        if (now - self.last_backfill_stats_load_unix < 10) return;
        self.last_backfill_stats_load_unix = now;

        const path = self.backfill_stats_path orelse return;
        var f = compat.fs.cwd().openFile(path, .{}) catch return;
        defer f.close();
        const data = f.deprecatedReader().readAllAlloc(self.alloc, 8192) catch return;
        defer self.alloc.free(data);

        self.metrics.backfill_runs_total.store(backfill_autopilot.parseJsonU64(data, "runs_total"), .release);
        self.metrics.backfill_blocks_total.store(backfill_autopilot.parseJsonU64(data, "blocks_total"), .release);
        self.metrics.backfill_errors_total.store(backfill_autopilot.parseJsonU64(data, "errors_total"), .release);
        self.metrics.backfill_busy_total.store(backfill_autopilot.parseJsonU64(data, "busy_total"), .release);
        self.metrics.backfill_last_unix.store(backfill_autopilot.parseJsonU64(data, "updated_unix"), .release);
        self.metrics.backfill_last_blocks.store(backfill_autopilot.parseJsonU64(data, "last_blocks"), .release);
        self.metrics.backfill_cursor_offset.store(backfill_autopilot.parseJsonU64(data, "cursor_offset"), .release);
        self.metrics.backfill_file_count_last.store(backfill_autopilot.parseJsonU64(data, "file_count"), .release);
        self.metrics.backfill_file_index_last.store(backfill_autopilot.parseJsonU64(data, "file_index"), .release);
        self.metrics.backfill_file_size_bytes_last.store(backfill_autopilot.parseJsonU64(data, "file_size_bytes"), .release);
        self.metrics.backfill_segment_done_x1e6.store(backfill_autopilot.parseJsonU64(data, "segment_done_x1e6"), .release);
        self.metrics.backfill_adapt_peer_closed.store(backfill_autopilot.parseJsonU64(data, "last_peer_closed_total"), .release);
        self.metrics.backfill_adapt_keepalive_to.store(backfill_autopilot.parseJsonU64(data, "last_keepalive_timeouts_total"), .release);
        self.metrics.backfill_adapt_block_us.store(backfill_autopilot.parseJsonU64(data, "last_block_total_us"), .release);
        self.metrics.backfill_adapt_rec_blocks.store(backfill_autopilot.parseJsonU64(data, "last_recommended_blocks"), .release);
        self.metrics.backfill_adapt_rec_seconds.store(backfill_autopilot.parseJsonU64(data, "last_recommended_seconds"), .release);
        self.metrics.backfill_cursor_desync_total.store(backfill_autopilot.parseJsonU64(data, "cursor_desync_total"), .release);
        self.metrics.backfill_cursor_resync_total.store(backfill_autopilot.parseJsonU64(data, "cursor_resync_total"), .release);
        self.metrics.backfill_cursor_resync_fail_total.store(backfill_autopilot.parseJsonU64(data, "cursor_resync_fail_total"), .release);
        self.metrics.backfill_cursor_resync_last_unix.store(backfill_autopilot.parseJsonU64(data, "cursor_resync_last_unix"), .release);
        self.metrics.backfill_eof_idle_total.store(backfill_autopilot.parseJsonU64(data, "eof_idle_total"), .release);
        self.metrics.backfill_eof_idle_last_unix.store(backfill_autopilot.parseJsonU64(data, "eof_idle_last_unix"), .release);
        self.metrics.backfill_segments_deleted_total.store(backfill_autopilot.parseJsonU64(data, "segments_deleted_total"), .release);
        self.metrics.backfill_segments_deleted_bytes_total.store(backfill_autopilot.parseJsonU64(data, "segments_deleted_bytes_total"), .release);
        self.metrics.backfill_current_file_is_active.store(backfill_autopilot.parseJsonU64(data, "current_file_is_active"), .release);
        self.metrics.backfill_idle_skips_total.store(backfill_autopilot.parseJsonU64(data, "idle_skips_total"), .release);
        self.metrics.backfill_idle_last_unix.store(backfill_autopilot.parseJsonU64(data, "idle_last_unix"), .release);
        // Gap hunter
        self.metrics.gap_resolved_total.store(backfill_autopilot.parseJsonU64(data, "gap_resolved_total"), .release);
        self.metrics.gap_resolved_last.store(backfill_autopilot.parseJsonU64(data, "gap_resolved_last"), .release);
        self.metrics.gap_unresolved_last.store(backfill_autopilot.parseJsonU64(data, "gap_unresolved_last"), .release);
        // Backfill recommendation
        self.metrics.backfill_recommend_profile_code.store(backfill_autopilot.parseJsonU64(data, "recommend_profile_code"), .release);
        self.metrics.backfill_recommend_blocks.store(backfill_autopilot.parseJsonU64(data, "recommend_blocks"), .release);
        self.metrics.backfill_recommend_seconds.store(backfill_autopilot.parseJsonU64(data, "recommend_seconds"), .release);
        self.metrics.backfill_recommend_pressure.store(backfill_autopilot.parseJsonU64(data, "recommend_pressure"), .release);
        // Backfill gap steering
        self.metrics.backfill_gap_hit_total.store(backfill_autopilot.parseJsonU64(data, "gap_resolved_total"), .release);
        self.metrics.backfill_gap_hit_last.store(backfill_autopilot.parseJsonU64(data, "gap_resolved_last"), .release);
        self.metrics.backfill_gap_hit_ratio_x1e6.store(backfill_autopilot.parseJsonU64(data, "gap_hit_ratio_last_x1e6"), .release);
        self.metrics.backfill_gap_keys_loaded_last.store(backfill_autopilot.parseJsonU64(data, "gap_keys_loaded_last"), .release);
        self.metrics.backfill_produced_total_last.store(backfill_autopilot.parseJsonU64(data, "produced_total_last"), .release);
        // Backfill gap consumed coverage
        self.metrics.backfill_gap_consumed_seen_total.store(backfill_autopilot.parseJsonU64(data, "gap_consumed_seen_total"), .release);
        self.metrics.backfill_gap_consumed_resolved_total.store(backfill_autopilot.parseJsonU64(data, "gap_consumed_resolved_total"), .release);
        self.metrics.backfill_gap_consumed_seen_last.store(backfill_autopilot.parseJsonU64(data, "gap_consumed_seen_last"), .release);
        self.metrics.backfill_gap_consumed_resolved_last.store(backfill_autopilot.parseJsonU64(data, "gap_consumed_resolved_last"), .release);
        // Backfill autotune
        self.metrics.backfill_autotune_enabled.store(backfill_autopilot.parseJsonU64(data, "autotune_enabled_last"), .release);
        self.metrics.backfill_autotune_profile_current.store(backfill_autopilot.parseJsonU64(data, "autotune_profile_current"), .release);
        self.metrics.backfill_autotune_last_change_unix.store(backfill_autopilot.parseJsonU64(data, "autotune_last_change_unix"), .release);
        self.metrics.backfill_autotune_switch_total.store(backfill_autopilot.parseJsonU64(data, "autotune_switch_total"), .release);
        self.metrics.backfill_autotune_reason_code_last.store(backfill_autopilot.parseJsonU64(data, "autotune_reason_code_last"), .release);
    }

    fn maybeLoadCaptureStats(self: *Server) void {
        const now = compat.timestamp();
        if (now - self.last_capture_stats_load_unix < 10) return;
        self.last_capture_stats_load_unix = now;

        const caps_dir = self.captures_dir_path orelse return;
        var dir = compat.fs.cwd().openDir(caps_dir, .{ .iterate = true }) catch {
            self.metrics.capture_mainnet_bin_bytes.store(0, .release);
            self.metrics.capture_segments_count.store(0, .release);
            self.metrics.capture_segments_bytes_total.store(0, .release);
            return;
        };
        defer dir.close();

        var mainnet_bytes: u64 = 0;
        var seg_count: u64 = 0;
        var seg_bytes: u64 = 0;

        var dit = dir.iterate();
        while (dit.next() catch null) |e| {
            if (e.kind != .file) continue;
            if (!capture.isCaptureFile(e.name)) continue;
            const fsize: u64 = if (dir.statFile(e.name)) |st| st.size else |_| 0;
            if (capture.isRotatedCapture(e.name)) {
                seg_count += 1;
                seg_bytes += fsize;
            } else {
                mainnet_bytes = fsize;
            }
        }

        self.metrics.capture_mainnet_bin_bytes.store(mainnet_bytes, .release);
        self.metrics.capture_segments_count.store(seg_count, .release);
        self.metrics.capture_segments_bytes_total.store(seg_bytes, .release);

        const rot_b = capture.rotateBytes();
        self.metrics.capture_rotate_bytes.store(rot_b, .release);
        self.metrics.capture_rotate_mb.store(rot_b / (1024 * 1024), .release);
    }

    // ── 0.16 connection adapters ──────────────────────────────────────────────
    // Thin wrappers over the persistent std.Io.net.Stream Reader/Writer
    // interfaces created once per connection in handleConn. They expose exactly
    // the old call shapes the request handler uses (readUntilDelimiterOrEof,
    // readAll, writeAll), preserving byte semantics: delimiter is consumed and
    // excluded from the returned slice; EOF with no bytes returns null; a full
    // buffer before the delimiter is StreamTooLong — identical to the 0.15
    // GenericReader.readUntilDelimiterOrEof contract. Writes flush so response
    // bytes hit the socket exactly as before.
    const ConnReader = struct {
        iface: *std.Io.Reader,

        /// Reads bytes until `delimiter` (consumed, excluded from result) into
        /// `buf`; returns the bytes read so far. On end-of-stream with zero
        /// bytes read returns null; with some bytes read returns those bytes.
        /// Returns error.StreamTooLong if `buf` fills before the delimiter.
        fn readUntilDelimiterOrEof(self: ConnReader, buf: []u8, delimiter: u8) !?[]u8 {
            var i: usize = 0;
            while (true) {
                const byte = self.iface.takeByte() catch |err| switch (err) {
                    error.EndOfStream => {
                        if (i == 0) return null;
                        return buf[0..i];
                    },
                    else => return err,
                };
                if (byte == delimiter) return buf[0..i];
                if (i >= buf.len) return error.StreamTooLong;
                buf[i] = byte;
                i += 1;
            }
        }

        /// Reads into `buf` until full or end-of-stream; returns bytes read.
        fn readAll(self: ConnReader, buf: []u8) !usize {
            return self.iface.readSliceShort(buf);
        }
    };

    const ConnWriter = struct {
        iface: *std.Io.Writer,

        fn writeAll(self: ConnWriter, bytes: []const u8) !void {
            try self.iface.writeAll(bytes);
            try self.iface.flush();
        }
    };

    fn writeResp(w: anytype, code: u16, ctype: []const u8, body: []const u8) void {
        writeRespBytes(w, code, ctype, body);
    }

    fn writeRespBytes(w: anytype, code: u16, ctype: []const u8, body: []const u8) void {
        const status = switch (code) {
            200 => "OK",
            400 => "Bad Request",
            404 => "Not Found",
            405 => "Method Not Allowed",
            413 => "Payload Too Large",
            429 => "Too Many Requests",
            500 => "Internal Server Error",
            503 => "Service Unavailable",
            else => "OK",
        };

        // Only emit STATUS_WRITE for the status endpoints to avoid log
        // noise on /metrics + /health hits. The "large JSON" gate matches
        // the prior behaviour but the log now follows a canonical
        // "requested/wrote/err" shape for parity with STATUS_EMIT.
        const log_status = std.mem.eql(u8, ctype, "application/json") and body.len > 1024;

        // Build header separately so we can retry partial writes instead of
        // silently eating errors. Connection: close tells the client to stop
        // reading after `Content-Length` bytes, which keeps the read side
        // deterministic even under slow-loris timeouts.
        var hdr_buf: [256]u8 = undefined;
        const hdr = std.fmt.bufPrint(
            &hdr_buf,
            "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ code, status, ctype, body.len },
        ) catch {
            // Header too long — emergency fallback to a tiny error body.
            const emerg = "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: 34\r\nConnection: close\r\n\r\n{\"error\":\"status_write_failed\"}\n";
            _ = w.writeAll(emerg) catch {};
            if (log_status) std.debug.print("STATUS_WRITE: requested={d} wrote=0 err=header_too_long\n", .{body.len});
            return;
        };

        // Single writeAll for headers — loops internally on partial writes.
        w.writeAll(hdr) catch |err| {
            if (log_status) std.debug.print("STATUS_WRITE: requested={d} wrote=0 err=header_{s}\n", .{ body.len, @errorName(err) });
            return;
        };

        // writeAll for body. GenericWriter.writeAll loops on short writes
        // (see std/io/generic_writer.zig). On error we cannot know how many
        // body bytes the kernel actually drained, so we report wrote=0.
        w.writeAll(body) catch |err| {
            if (log_status) std.debug.print("STATUS_WRITE: requested={d} wrote=0 err=body_{s}\n", .{ body.len, @errorName(err) });
            return;
        };

        if (log_status) {
            std.debug.print("STATUS_WRITE: requested={d} wrote={d} err=none\n", .{ body.len, body.len });
        }
    }
};
