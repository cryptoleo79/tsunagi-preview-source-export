#!/bin/bash
# TSUNAGI Slot Supervisor v2 — BAeY-guided operatorless launch controller
#
# State machine: IDLE → EPOCH_PREP → SLOT_PREP → LEADER_ARMED →
#   FORGE_PENDING_PARENT → FORGE_EXECUTING → PROPAGATION_PENDING →
#   ACCEPTANCE_OBSERVE → SUCCESS / RETRY_READY / ESCALATE_OPERATOR
#
# BAeY evidence engine: deterministic fault classification from
# forge/propagation/acceptance signals. Produces ranked blockers
# with confidence levels and bounded next-action recommendations.
#
# Persisted state: $GUARDIAN_DIR/supervisor_state.json
# Attempt records: $GUARDIAN_DIR/attempts/
# Evidence: $EVIDENCE_BASE/<timestamp>_slot_<N>/
# Escalation: $GUARDIAN_DIR/ESCALATION.json

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────
TSUNAGI_HOME="${TSUNAGI_HOME:-${HOME}/tsunagi-home-preview}"
METRICS_URL="${TSUNAGI_METRICS_URL:-http://127.0.0.1:9081/metrics}"
GUARDIAN_DIR="$TSUNAGI_HOME/guardian"
ATTEMPTS_DIR="$GUARDIAN_DIR/attempts"
EVIDENCE_BASE="${HOME}/tsunagi-evidence"
STATE_FILE="$GUARDIAN_DIR/supervisor_state.json"
LEADER_SCAN="${LEADER_SCAN:-/tmp/leader_scan}"
NONCE_SCRIPT="${NONCE_SCRIPT:-/tmp/update-epoch-nonce.sh}"
VRF_SKEY="${VRF_SKEY:-${HOME}/tsunagi-keys/preview-bp/vrf.skey}"
EPOCH_STAKE_CONF="${HOME}/.config/systemd/user/tsunagi-preview.service.d/98-epoch-stake.conf"
SLOTS_PER_EPOCH=86400
SLOT_PREP_HORIZON=600
EPOCH_PREP_HORIZON=7200
MAX_CONSECUTIVE_FAILURES=5
DRY_RUN="${DRY_RUN:-0}"
LOCKFILE="/tmp/tsunagi-slot-supervisor.lock"

exec 9>"$LOCKFILE"
if ! flock -n 9; then exit 0; fi

mkdir -p "$GUARDIAN_DIR" "$ATTEMPTS_DIR"

# ── Helpers ─────────────────────────────────────────────────────────
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] SUPERVISOR: $*"; }

metric() {
    local val=""
    for _try in 1 2 3; do
        val=$(curl -sf "$METRICS_URL" 2>/dev/null | grep "^$1 " | awk '{print $2}' | head -1 || true)
        [ -n "$val" ] && break
        sleep 1
    done
    echo "$val"
}

current_slot() { metric "tsunagi_producer_observed_slot"; }

configured_nonce() {
    grep 'EPOCH_NONCE_HEX' "$EPOCH_STAKE_CONF" 2>/dev/null | cut -d= -f3
}

configured_stake() {
    grep 'STAKE_FRACTION' "$EPOCH_STAKE_CONF" 2>/dev/null | cut -d= -f3
}

read_state() {
    [ -f "$STATE_FILE" ] && python3 -c "import sys,json; d=json.load(open('$STATE_FILE')); print(d.get('$1',''))" 2>/dev/null || true
}

write_state() {
    local state="$1" reason="${2:-}" slot="${3:-0}" failures="${4:-0}" blocker="${5:-none}"
    cat > "$STATE_FILE" << EOF
{
  "state": "$state",
  "reason": "$reason",
  "target_slot": $slot,
  "consecutive_failures": $failures,
  "primary_blocker": "$blocker",
  "updated_unix": $(date +%s),
  "updated_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

escalate() {
    local reason="$1"
    log "ESCALATE: $reason"
    cat > "$GUARDIAN_DIR/ESCALATION.json" << EOF
{"reason":"$reason","unix":$(date +%s),"utc":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
    write_state "ESCALATE_OPERATOR" "$reason" 0 0 "$reason"
}

# ── Epoch Prep ──────────────────────────────────────────────────────
check_epoch_nonce() {
    local slot dist
    slot=$(current_slot) || return 1
    local ep=$(( slot / SLOTS_PER_EPOCH ))
    local boundary=$(( (ep + 1) * SLOTS_PER_EPOCH ))
    dist=$(( boundary - slot ))

    [ "$dist" -gt "$EPOCH_PREP_HORIZON" ] && return 0

    local nonce
    nonce=$(configured_nonce)
    if [ -z "$nonce" ]; then
        log "EPOCH_PREP: WARNING — no nonce configured, boundary in ${dist}s"
        return 1
    fi
    log "EPOCH_PREP: epoch=$ep next=$((ep+1)) boundary_in=${dist}s nonce=${nonce:0:16}..."
}

# ── Leader Scan ─────────────────────────────────────────────────────
scan_leader_slots() {
    local slot nonce stake
    slot=$(current_slot) || return 0
    nonce=$(configured_nonce) || return 0
    stake=$(configured_stake) || return 0
    local ep=$(( slot / SLOTS_PER_EPOCH ))
    local end=$(( (ep + 1) * SLOTS_PER_EPOCH ))

    [ ! -x "$LEADER_SCAN" ] && return 0

    local output next
    output=$("$LEADER_SCAN" "$VRF_SKEY" "$nonce" "$slot" "$end" "$stake" 50000 2>/dev/null || true)
    next=$(echo "$output" | head -1 | awk '{print $2}' | cut -d= -f2)

    [ -n "$next" ] && [ "$next" -gt 0 ] 2>/dev/null && echo "$next"
}

scan_all_remaining_slots() {
    local slot nonce stake
    slot=$(current_slot) || return 0
    nonce=$(configured_nonce) || return 0
    stake=$(configured_stake) || return 0
    local ep=$(( slot / SLOTS_PER_EPOCH ))
    local end=$(( (ep + 1) * SLOTS_PER_EPOCH ))

    [ ! -x "$LEADER_SCAN" ] && return 0

    "$LEADER_SCAN" "$VRF_SKEY" "$nonce" "$slot" "$end" "$stake" 50000 2>/dev/null | awk '{print $2}' | cut -d= -f2 || true
}

# ── Readiness Checks ───────────────────────────────────────────────
check_readiness() {
    local target_slot="$1"
    local checks_passed=0 checks_total=0 fail_list=""

    # 1. Preview service
    checks_total=$((checks_total + 1))
    if systemctl --user is-active tsunagi-preview.service >/dev/null 2>&1; then
        checks_passed=$((checks_passed + 1))
    else
        fail_list="${fail_list}service_down,"
    fi

    # 2. Propagate-serve
    checks_total=$((checks_total + 1))
    if ss -ltnp 2>/dev/null | grep -q ':3033'; then
        checks_passed=$((checks_passed + 1))
    else
        fail_list="${fail_list}propagate_down,"
    fi

    # 3. Epoch match
    checks_total=$((checks_total + 1))
    local ep=$(metric "tsunagi_producer_epoch_last")
    local want_ep=$(( target_slot / SLOTS_PER_EPOCH ))
    if [ "${ep:-0}" = "$want_ep" ]; then
        checks_passed=$((checks_passed + 1))
    else
        fail_list="${fail_list}epoch_mismatch,"
    fi

    # 4. VRF verify
    checks_total=$((checks_total + 1))
    if [ "$(metric tsunagi_producer_vrf_verify_ok_last)" = "1" ]; then
        checks_passed=$((checks_passed + 1))
    else
        fail_list="${fail_list}vrf_not_ok,"
    fi

    # 5. Nonce present
    checks_total=$((checks_total + 1))
    if [ -n "$(configured_nonce)" ]; then
        checks_passed=$((checks_passed + 1))
    else
        fail_list="${fail_list}nonce_missing,"
    fi

    # 6. Tip freshness (drift < 30 slots)
    checks_total=$((checks_total + 1))
    local obs=$(metric "tsunagi_producer_observed_slot")
    local est=$(metric "tsunagi_producer_estimated_slot")
    local drift=$(( ${est:-0} - ${obs:-0} ))
    if [ "$drift" -lt 30 ] && [ "$drift" -gt -30 ]; then
        checks_passed=$((checks_passed + 1))
    else
        fail_list="${fail_list}tip_drift_${drift},"
    fi

    log "READINESS: ${checks_passed}/${checks_total} passed slot=$target_slot${fail_list:+ fails=$fail_list}"

    [ "$checks_passed" -eq "$checks_total" ]
}

# ── Forge Arm ───────────────────────────────────────────────────────
arm_forge() {
    local target_slot="$1"
    [ "$DRY_RUN" = "1" ] && { log "DRY_RUN: would arm slot $target_slot"; return 0; }
    cat > "$GUARDIAN_DIR/forge_arm.json" << EOF
{"armed_at_unix":$(date +%s),"net":"preview","home":"$TSUNAGI_HOME","target_slot":$target_slot,"nonce":"$(head -c 16 /dev/urandom | xxd -p)","safety":["broadcast_off","kes_valid","doctor_pass","preview_only"]}
EOF
    log "ARMED: slot=$target_slot"
}

# ── BAeY Evidence Engine ───────────────────────────────────────────
# Deterministic fault classification from forge/propagation signals.
# Produces a ranked blocker diagnosis with confidence and next action.

baey_classify() {
    local target_slot="$1"
    local ts=$(date -u +%Y%m%d_%H%M%S)
    local edir="$EVIDENCE_BASE/${ts}_slot_${target_slot}"
    mkdir -p "$edir"

    # ── Collect raw evidence ──
    local journal_slice=""
    journal_slice=$(journalctl --user -u tsunagi-preview.service --since "10 min ago" --no-pager -o cat 2>/dev/null || true)

    local plog=""
    plog=$(ls -t ~/tsunagi-logs/propagate-serve-*.log 2>/dev/null | head -1 || true)
    local prop_slice=""
    [ -n "$plog" ] && prop_slice=$(strings "$plog" 2>/dev/null | tail -200 || true)

    # Save raw evidence
    echo "$journal_slice" | grep -E 'SCHEDULED_LEADER|FORGE_AT|FORGE:|FORGE_PROMOTE|DEFERRED_PARENT|ACCEPTANCE|SEALED_WIRE|FORGE_PROTOCOL' > "$edir/forge_journal.txt" 2>/dev/null || true
    echo "$prop_slice" | grep -E 'ACCEPTANCE_RESULT|SEALED_WIRE|serve_recent_sealed|blockfetch|slot_gap' > "$edir/propagation.txt" 2>/dev/null || true

    # Copy forge meta if exists
    local fdir
    fdir=$(ls -td "$TSUNAGI_HOME/producer_forge_sim/"*"_${target_slot}" 2>/dev/null | head -1 || true)
    [ -n "$fdir" ] && [ -d "$fdir" ] && cp "$fdir/meta.json" "$edir/forge_meta.json" 2>/dev/null || true

    # ── Extract signals ──
    local sig_leader_detected=0 sig_forge_fired=0 sig_promote_ok=0
    local sig_coherent=0 sig_sealed_served=0 sig_blockfetch=0
    local sig_parent_refreshed=0 sig_parent_gap=999
    local sig_slot_gap=999 sig_recency_ok=0
    local sig_protocol_ok=0 sig_equal_tip=0

    # Leader detection
    echo "$journal_slice" | grep -q "SCHEDULED_LEADER.*slot=${target_slot}" && sig_leader_detected=1

    # Forge fired
    echo "$journal_slice" | grep -q "FORGE_PROMOTE_ATOMIC.*slot=${target_slot}" && { sig_forge_fired=1; sig_promote_ok=1; }

    # Coherence
    echo "$journal_slice" | grep -q "artifact_coherent=true" && sig_coherent=1

    # Parent truth
    local parent_line
    parent_line=$(echo "$journal_slice" | grep "DEFERRED_PARENT_TRUTH.*deferred_slot=${target_slot}" | head -1)
    if [ -n "$parent_line" ]; then
        echo "$parent_line" | grep -q "parent_refresh_applied=true" && sig_parent_refreshed=1
        local cached_block refreshed_block
        cached_block=$(echo "$parent_line" | sed 's/.*cached_parent_block=\([0-9]*\).*/\1/')
        refreshed_block=$(echo "$parent_line" | sed 's/.*refreshed_parent_block=\([0-9]*\).*/\1/')
        [ -n "$cached_block" ] && [ -n "$refreshed_block" ] && sig_parent_gap=$((refreshed_block - cached_block))
    fi

    # Canonical chain block_no at forge slot
    local canonical_block_at_slot forged_block_no block_no_gap=999
    canonical_block_at_slot=$(echo "$journal_slice" | grep "ROLL FWD slot=${target_slot} " | head -1 | sed 's/.*block=\([0-9]*\).*/\1/')
    forged_block_no=$(echo "$journal_slice" | grep "FORGE:.*slot=${target_slot}" | head -1 | sed 's/.*block_no=\([0-9]*\).*/\1/')
    if [ -n "$canonical_block_at_slot" ] && [ -n "$forged_block_no" ]; then
        block_no_gap=$((canonical_block_at_slot - forged_block_no))
    fi

    # Protocol version
    echo "$journal_slice" | grep -q "FORGE_PROTOCOL_VERSION_TRUTH.*minor=0" && sig_protocol_ok=1

    # Propagation signals
    local latest_acceptance
    latest_acceptance=$(echo "$prop_slice" | grep "ACCEPTANCE_RESULT_TRUTH" | tail -1)
    if [ -n "$latest_acceptance" ]; then
        echo "$latest_acceptance" | grep -q "rollforward_sealed_tx_total=[1-9]" && sig_sealed_served=1
        echo "$latest_acceptance" | grep -q "blockfetch_rx_total=[1-9]" && sig_blockfetch=1
        echo "$latest_acceptance" | grep -q "equal_tip=true" && sig_equal_tip=1
    fi

    local gap_line
    gap_line=$(echo "$prop_slice" | grep "serve_recent_sealed" | tail -1)
    if [ -n "$gap_line" ]; then
        sig_slot_gap=$(echo "$gap_line" | sed 's/.*slot_gap=\([0-9]*\).*/\1/')
        echo "$gap_line" | grep -q "serve_recent_sealed=true" && sig_recency_ok=1
    fi

    # ── BAeY: Weighted fault classification ──
    local primary_blocker="unknown" secondary_blocker="none"
    local confidence=0 retry_safe="true" next_action="continue_to_next_slot"

    if [ "$sig_blockfetch" = "1" ]; then
        primary_blocker="none_success"
        confidence=100
        next_action="celebrate"
    elif [ "$sig_leader_detected" = "0" ]; then
        primary_blocker="no_leader_detected"
        confidence=95
        next_action="verify_vrf_nonce_stake"
    elif [ "$sig_forge_fired" = "0" ]; then
        primary_blocker="leader_detected_no_forge"
        confidence=90
        next_action="check_forge_arm_and_flags"
    elif [ "$sig_coherent" = "0" ]; then
        primary_blocker="artifact_incoherent"
        confidence=85
        next_action="check_fragment_state"
    elif [ "$sig_sealed_served" = "0" ] && [ "${sig_slot_gap:-999}" -gt 600 ]; then
        primary_blocker="propagation_window_miss"
        confidence=80
        secondary_blocker="slot_gap_${sig_slot_gap}_exceeds_window"
        next_action="check_live_push_timing"
    elif [ "$sig_sealed_served" = "0" ]; then
        primary_blocker="sealed_not_served"
        confidence=75
        next_action="check_propagation_path"
    elif [ "$sig_blockfetch" = "0" ] && [ "$block_no_gap" -gt 0 ]; then
        primary_blocker="stale_parent_block_no_gap_${block_no_gap}"
        confidence=90
        secondary_blocker="relay_chain_selection_reject"
        next_action="improve_parent_freshness"
    elif [ "$sig_blockfetch" = "0" ]; then
        primary_blocker="sealed_served_no_blockfetch"
        confidence=70
        secondary_blocker="relay_validation_unknown"
        next_action="investigate_relay_side"
    fi

    # ── Write attempt record ──
    local attempt_file="$ATTEMPTS_DIR/attempt_${target_slot}.json"
    cat > "$attempt_file" << EOF
{
  "slot": $target_slot,
  "unix": $(date +%s),
  "utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "signals": {
    "leader_detected": $sig_leader_detected,
    "forge_fired": $sig_forge_fired,
    "promote_ok": $sig_promote_ok,
    "coherent": $sig_coherent,
    "parent_refreshed": $sig_parent_refreshed,
    "parent_gap": $sig_parent_gap,
    "block_no_gap": $block_no_gap,
    "protocol_ok": $sig_protocol_ok,
    "sealed_served": $sig_sealed_served,
    "slot_gap": ${sig_slot_gap:-999},
    "recency_ok": $sig_recency_ok,
    "equal_tip": $sig_equal_tip,
    "blockfetch": $sig_blockfetch
  },
  "baey": {
    "primary_blocker": "$primary_blocker",
    "secondary_blocker": "$secondary_blocker",
    "confidence": $confidence,
    "retry_safe": $retry_safe,
    "next_action": "$next_action"
  },
  "evidence_dir": "$edir",
  "binary": "$(readlink ~/.local/tsunagi/current 2>/dev/null || echo unknown)"
}
EOF

    # State snapshot
    cp "$attempt_file" "$edir/baey_diagnosis.json" 2>/dev/null || true

    log "BAEY: slot=$target_slot blocker=$primary_blocker confidence=$confidence block_no_gap=$block_no_gap slot_gap=${sig_slot_gap:-?} action=$next_action"

    # Return primary blocker for caller
    echo "$primary_blocker"
}

# ── Main ────────────────────────────────────────────────────────────
main() {
    local slot
    slot=$(current_slot)
    if [ -z "$slot" ]; then
        log "ERROR: cannot read metrics"
        exit 1
    fi

    local state consec_failures target_slot last_blocker
    state=$(read_state "state")
    consec_failures=$(read_state "consecutive_failures")
    consec_failures=${consec_failures:-0}
    target_slot=$(read_state "target_slot")
    target_slot=${target_slot:-0}
    last_blocker=$(read_state "primary_blocker")

    # Escalation check
    if [ -f "$GUARDIAN_DIR/ESCALATION.json" ]; then
        log "ESCALATION active — operator must clear $GUARDIAN_DIR/ESCALATION.json"
        exit 0
    fi

    # ── Epoch prep ──
    check_epoch_nonce || true

    # ── Check if previous target passed → classify ──
    if [ "$target_slot" -gt 0 ] && [ "$slot" -gt "$((target_slot + 120))" ]; then
        local blocker
        blocker=$(baey_classify "$target_slot")

        if [ "$blocker" = "none_success" ]; then
            write_state "SUCCESS" "blockfetch_received" "$target_slot" 0 "none"
            log "SUCCESS: slot=$target_slot"
            exit 0
        fi

        consec_failures=$((consec_failures + 1))

        # Check escalation threshold
        if [ "$consec_failures" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
            escalate "consecutive_failures=$consec_failures blocker=$blocker"
            exit 0
        fi

        # Same blocker repeating?
        if [ "$blocker" = "$last_blocker" ] && [ "$consec_failures" -ge 3 ]; then
            escalate "repeated_blocker=$blocker count=$consec_failures"
            exit 0
        fi

        write_state "RETRY_READY" "retry" 0 "$consec_failures" "$blocker"
        log "RETRY_READY: failures=$consec_failures blocker=$blocker"
    fi

    # ── Scan for next slot ──
    local next_slot
    next_slot=$(scan_leader_slots)

    if [ -z "$next_slot" ]; then
        [ "$state" != "idle" ] && write_state "IDLE" "no_slots" 0 "$consec_failures" "${last_blocker:-none}"
        exit 0
    fi

    local dist=$(( next_slot - slot ))

    # ── Slot prep ──
    if [ "$dist" -le "$SLOT_PREP_HORIZON" ]; then
        log "SLOT_PREP: slot=$next_slot dist=${dist}s epoch=$(( next_slot / SLOTS_PER_EPOCH ))"

        if ! check_readiness "$next_slot"; then
            write_state "SLOT_PREP" "readiness_failed" "$next_slot" "$consec_failures" "readiness_check_failed"
            exit 0
        fi

        # Auto-arm
        if [ ! -f "$GUARDIAN_DIR/forge_arm.json" ]; then
            arm_forge "$next_slot"
        fi

        write_state "LEADER_ARMED" "ready" "$next_slot" "$consec_failures" "none"
        log "LEADER_ARMED: slot=$next_slot dist=${dist}s"

        # Log all remaining slots for visibility
        local remaining
        remaining=$(scan_all_remaining_slots)
        local count
        count=$(echo "$remaining" | grep -c '[0-9]' || true)
        log "QUEUE: ${count} leader slots remaining in epoch"
        exit 0
    fi

    # ── Idle ──
    if [ "$state" != "IDLE" ] || [ "$target_slot" != "$next_slot" ]; then
        write_state "IDLE" "waiting" "$next_slot" "$consec_failures" "${last_blocker:-none}"
        log "IDLE: next=$next_slot dist=${dist}s (~$((dist/3600))h$((dist%3600/60))m) failures=$consec_failures"
    fi
}

main "$@"
