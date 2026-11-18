pub const SlotClock = struct {
    genesis_unix: i64,
    slot_length_s: i64,
    // Byron era correction (mainnet only; 0 for testnets)
    byron_slot_length_s: i64,
    shelley_start_slot: u64,
    shelley_start_unix: i64,
    // State
    last_est_slot: u64,
    last_est_unix: i64,
};

// Mainnet constants: Byron had 20s slots, Shelley hard fork at slot 4,492,800
pub const MAINNET_BYRON_SLOT_LENGTH_S: i64 = 20;
pub const MAINNET_SHELLEY_START_SLOT: u64 = 4_492_800;

pub fn init(sc: *SlotClock, genesis_unix: i64, slot_length_s: i64) void {
    initWithEra(sc, genesis_unix, slot_length_s, 0, 0);
}

pub fn initWithEra(sc: *SlotClock, genesis_unix: i64, slot_length_s: i64, byron_slot_length_s: i64, shelley_start_slot: u64) void {
    sc.genesis_unix = genesis_unix;
    sc.slot_length_s = slot_length_s;
    sc.byron_slot_length_s = byron_slot_length_s;
    sc.shelley_start_slot = shelley_start_slot;
    sc.shelley_start_unix = if (byron_slot_length_s > 0 and shelley_start_slot > 0)
        genesis_unix + @as(i64, @intCast(shelley_start_slot)) * byron_slot_length_s
    else
        genesis_unix;
    sc.last_est_slot = 0;
    sc.last_est_unix = 0;
}

/// Returns estimated slot >= 0 (clamped).
/// For mainnet: accounts for Byron era (20s slots) before Shelley hard fork.
pub fn estimateSlot(sc: *SlotClock, now_unix: i64) u64 {
    if (now_unix <= sc.genesis_unix or sc.slot_length_s <= 0) return 0;

    // Era-aware estimation (mainnet: Byron 20s → Shelley 1s at slot 4,492,800)
    if (sc.byron_slot_length_s > 0 and sc.shelley_start_slot > 0) {
        if (now_unix < sc.shelley_start_unix) {
            // Still in Byron era (shouldn't happen in practice)
            const delta = now_unix - sc.genesis_unix;
            const s = @divTrunc(delta, sc.byron_slot_length_s);
            if (s <= 0) return 0;
            sc.last_est_slot = @intCast(s);
        } else {
            // Shelley era: shelley_start_slot + elapsed_since_shelley / slot_length_s
            const shelley_elapsed = now_unix - sc.shelley_start_unix;
            const shelley_slots = @divTrunc(shelley_elapsed, sc.slot_length_s);
            sc.last_est_slot = sc.shelley_start_slot + (if (shelley_slots > 0) @as(u64, @intCast(shelley_slots)) else 0);
        }
    } else {
        // Simple mode (testnets or no Byron correction)
        const delta = now_unix - sc.genesis_unix;
        const s = @divTrunc(delta, sc.slot_length_s);
        if (s <= 0) return 0;
        sc.last_est_slot = @intCast(s);
    }

    sc.last_est_unix = now_unix;
    return sc.last_est_slot;
}
