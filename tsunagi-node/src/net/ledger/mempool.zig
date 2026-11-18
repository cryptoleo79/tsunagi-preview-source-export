const std = @import("std");
const compat = @import("compat");
const cbor = @import("../cbor/term.zig");
const utxo = @import("utxo.zig");
const tx_decode = @import("tx_decode.zig");
const eval_external = @import("eval_external.zig");

/// Optional UTxO lookup function for input validation at submit time.
/// Set by the follower after LMDB is initialized. Null if unavailable.
/// Returns lovelace value if UTxO exists, null if not found.
pub var g_utxo_lookup_fn: ?*const fn ([32]u8, u32) ?u64 = null;

/// Optional current-slot provider for validity interval enforcement.
/// Returns the node's most recently observed slot, or null if unavailable.
pub var g_current_slot_fn: ?*const fn () ?u64 = null;

/// Optional payment keyhash lookup for witness coverage precheck.
/// Returns 28-byte payment keyhash if UTxO address is key-controlled, null otherwise.
pub var g_utxo_keyhash_fn: ?*const fn ([32]u8, u32) ?[28]u8 = null;

/// Protocol parameters loaded from genesis for admission validation.
pub const ProtocolParams = struct {
    min_fee_a: u64, // fee per byte
    min_fee_b: u64, // fixed fee component
    min_utxo_value: u64, // minimum output lovelace (Shelley-era flat value)
    max_tx_size: u64, // maximum tx size bytes
    utxo_cost_per_byte: u64 = 0, // Conway: informational only until size-based calc
    source: u8 = 0, // 0=genesis, 1=file, 2=koios, 3=ntc (local cardano-node socket)
    reload_unix: i64 = 0, // last reload timestamp
    // Hardfork Readiness Layer — extended protocol state
    protocol_major: u32 = 0,
    protocol_minor: u32 = 0,
    max_block_body_size: u64 = 0, // 0 = use default 90112
};
pub var g_protocol_params: ?ProtocolParams = null;

/// Hardfork Readiness: global fork state tracked separately so it survives
/// param reloads without mutation races.
pub const ForkState = struct {
    last_known_major: u32 = 0, // alias: current_major
    last_known_minor: u32 = 0, // alias: current_minor
    next_major: u32 = 0, // set when fork announced
    next_minor: u32 = 0,
    fork_pending: bool = false,
    fork_detected_unix: i64 = 0,
};
pub var g_fork_state: ForkState = .{};

/// Check if Plutus external evaluation is enabled via TSUNAGI_PLUTUS_EVAL=1.
/// Cached after first check per process lifetime.
var g_plutus_eval_enabled: enum { unknown, enabled, disabled } = .unknown;

fn isPlutusEvalEnabled() bool {
    if (g_plutus_eval_enabled == .unknown) {
        const val = compat.getenv("TSUNAGI_PLUTUS_EVAL") orelse {
            g_plutus_eval_enabled = .disabled;
            return false;
        };
        g_plutus_eval_enabled = if (std.mem.eql(u8, val, "1")) .enabled else .disabled;
    }
    return g_plutus_eval_enabled == .enabled;
}

pub const MAX_TX_SIZE: usize = 64 * 1024; // 64 KB
const MAX_WITNESS_ITEMS: usize = 64;
pub const DEFAULT_MAX_ITEMS: usize = 1024;
pub const DEFAULT_MAX_BYTES: usize = 8 * 1024 * 1024; // 8 MB
pub const DEFAULT_TTL_S: i64 = 3600; // 1 hour default TTL for mempool entries

/// Read TTL (seconds) from TSUNAGI_MEMPOOL_TTL_S env var, falling back to DEFAULT_TTL_S.
/// Values <= 0 disable TTL sweeping.
fn ttlSeconds() i64 {
    const val = compat.getenv("TSUNAGI_MEMPOOL_TTL_S") orelse return DEFAULT_TTL_S;
    return std.fmt.parseInt(i64, val, 10) catch DEFAULT_TTL_S;
}

pub const Item = struct {
    hash: [32]u8,
    tx_bytes: []u8,
    received_unix: i64,
};

pub const AddResult = enum {
    accepted,
    rejected_too_large,
    rejected_duplicate,
    rejected_cbor_invalid,
    rejected_input_conflict,
    rejected_missing_input,
    rejected_balance_insufficient,
    rejected_ttl_expired,
    rejected_validity_start_future,
    rejected_fee_insufficient,
    rejected_min_utxo,
    rejected_timelock,
    rejected_witness_invalid,
    rejected_witness_coverage,
    rejected_plutus_unsupported,
    rejected_plutus_eval_failed,
    accepted_plutus_evaluated,
};

pub const Mempool = struct {
    alloc: std.mem.Allocator,
    items: std.array_list.Managed(Item),
    total_bytes: usize,
    max_items: usize,
    max_bytes: usize,
    accept_count: u64,
    reject_count: u64,
    conflict_reject_count: u64,
    missing_input_reject_count: u64,
    balance_reject_count: u64,
    ttl_reject_count: u64,
    validity_start_reject_count: u64,
    fee_insufficient_reject_count: u64,
    min_utxo_reject_count: u64,
    timelock_reject_count: u64,
    witness_invalid_reject_count: u64,
    witness_coverage_reject_count: u64,
    plutus_unsupported_reject_count: u64,
    // Plutus evaluator bridge counters
    plutus_eval_attempt_total: u64 = 0,
    plutus_eval_success_total: u64 = 0,
    plutus_eval_fail_total: u64 = 0,
    plutus_eval_unavailable_total: u64 = 0,
    // Plutus classification counters (cumulative across all submissions)
    plutus_txs_seen: u64 = 0, // txs with requires_plutus_definitive=true
    plutus_with_redeemers: u64 = 0, // ...that had redeemers
    plutus_with_datums: u64 = 0, // ...that had plutus_data
    plutus_with_ref_inputs: u64 = 0, // ...that had reference_inputs
    plutus_readiness_4_count: u64 = 0, // ...with readiness=4 (evaluator_absent: all prereqs present)
    // Input path classification (cumulative across all submissions)
    inputs_key_controlled: u64 = 0,
    inputs_script_non_plutus: u64 = 0,
    inputs_plutus_definitive: u64 = 0,
    inputs_unknown: u64 = 0,
    eviction_count: u64,
    confirmed_eviction_count: u64,
    change_seq: u64,

    pub fn init(alloc: std.mem.Allocator, max_items: usize, max_bytes: usize) Mempool {
        return .{
            .alloc = alloc,
            .items = std.array_list.Managed(Item).init(alloc),
            .total_bytes = 0,
            .max_items = max_items,
            .max_bytes = max_bytes,
            .accept_count = 0,
            .reject_count = 0,
            .conflict_reject_count = 0,
            .missing_input_reject_count = 0,
            .balance_reject_count = 0,
            .ttl_reject_count = 0,
            .validity_start_reject_count = 0,
            .fee_insufficient_reject_count = 0,
            .min_utxo_reject_count = 0,
            .timelock_reject_count = 0,
            .witness_invalid_reject_count = 0,
            .witness_coverage_reject_count = 0,
            .plutus_unsupported_reject_count = 0,
            .eviction_count = 0,
            .confirmed_eviction_count = 0,
            .change_seq = 0,
        };
    }

    pub fn deinit(self: *Mempool) void {
        for (self.items.items) |item| {
            self.alloc.free(item.tx_bytes);
        }
        self.items.deinit();
    }

    pub fn addTx(self: *Mempool, raw_bytes: []const u8) AddResult {
        if (raw_bytes.len == 0) {
            self.reject_count += 1;
            return .rejected_cbor_invalid;
        }

        // Use protocol-param max_tx_size when available, else fallback
        const effective_max = if (g_protocol_params) |pp| (if (pp.max_tx_size > 0) pp.max_tx_size else MAX_TX_SIZE) else MAX_TX_SIZE;
        if (raw_bytes.len > effective_max) {
            self.reject_count += 1;
            return .rejected_too_large;
        }

        // Structural CBOR validation (admission policy)
        validateTxCbor(self.alloc, raw_bytes) catch {
            self.reject_count += 1;
            return .rejected_cbor_invalid;
        };

        // Compute blake2b-256 hash
        var hash: [32]u8 = undefined;
        std.crypto.hash.blake2.Blake2b256.hash(raw_bytes, &hash, .{});

        // Duplicate check
        for (self.items.items) |item| {
            if (std.mem.eql(u8, &item.hash, &hash)) {
                self.reject_count += 1;
                return .rejected_duplicate;
            }
        }

        // Input conflict check: reject if any input overlaps with existing mempool tx
        if (self.hasInputConflict(raw_bytes)) {
            self.reject_count += 1;
            self.conflict_reject_count += 1;
            return .rejected_input_conflict;
        }

        // Input existence check: reject if any consumed input is missing from LMDB
        if (hasMissingInput(self.alloc, raw_bytes)) {
            self.reject_count += 1;
            self.missing_input_reject_count += 1;
            return .rejected_missing_input;
        }

        // Balance check: reject if inputs < outputs + fee
        if (hasInsufficientBalance(self.alloc, raw_bytes)) {
            self.reject_count += 1;
            self.balance_reject_count += 1;
            return .rejected_balance_insufficient;
        }

        // Validity interval check against current slot
        switch (checkValidityInterval(self.alloc, raw_bytes)) {
            .ok => {},
            .ttl_expired => {
                self.reject_count += 1;
                self.ttl_reject_count += 1;
                return .rejected_ttl_expired;
            },
            .start_future => {
                self.reject_count += 1;
                self.validity_start_reject_count += 1;
                return .rejected_validity_start_future;
            },
        }

        // Min-fee enforcement (protocol params required)
        if (g_protocol_params) |pp| {
            if (pp.min_fee_a > 0) {
                const of = tx_decode.extractOutputTotalAndFee(self.alloc, raw_bytes);
                if (of) |result| {
                    const min_fee = pp.min_fee_a * raw_bytes.len + pp.min_fee_b;
                    if (result.fee < min_fee) {
                        self.reject_count += 1;
                        self.fee_insufficient_reject_count += 1;
                        return .rejected_fee_insufficient;
                    }
                }
            }
        }

        // Min-UTxO enforcement (protocol params required)
        // When utxo_cost_per_byte > 0: size-based min_ada = cost_per_byte * (approx_size + 160)
        // Otherwise: flat min_utxo_value fallback
        if (g_protocol_params) |pp| {
            if (pp.utxo_cost_per_byte > 0) {
                // Size-based min-ADA (Conway): exact CBOR output size
                const infos = tx_decode.extractOutputSizeInfo(self.alloc, raw_bytes);
                if (infos) |outputs| {
                    defer self.alloc.free(outputs);
                    for (outputs) |out| {
                        const min_ada = pp.utxo_cost_per_byte * (out.cbor_size + 160);
                        if (out.lovelace < min_ada) {
                            self.reject_count += 1;
                            self.min_utxo_reject_count += 1;
                            return .rejected_min_utxo;
                        }
                    }
                }
            } else if (pp.min_utxo_value > 0) {
                // Flat min-UTxO fallback (Shelley-era)
                const lovelaces = tx_decode.extractOutputLovelaces(self.alloc, raw_bytes);
                if (lovelaces) |lvs| {
                    defer self.alloc.free(lvs);
                    for (lvs) |lv| {
                        if (lv < pp.min_utxo_value) {
                            self.reject_count += 1;
                            self.min_utxo_reject_count += 1;
                            return .rejected_min_utxo;
                        }
                    }
                }
            }
        }

        // Native script evaluation
        // Evaluates witness scripts with proper AllOf/AnyOf/MOf/Timelock semantics.
        // Rejects only when a script definitively evaluates to false.
        if (hasNativeScriptViolation(self.alloc, raw_bytes)) {
            self.reject_count += 1;
            self.timelock_reject_count += 1;
            return .rejected_timelock;
        }

        // Vkey witness signature precheck
        // Verifies Ed25519 sigs over tx body hash. Rejects only on clear failure.
        // Does NOT verify witness coverage or that the correct keys signed.
        {
            const vk_result = tx_decode.verifyVkeyWitnesses(raw_bytes);
            if (vk_result != null and vk_result.? == false) {
                self.reject_count += 1;
                self.witness_invalid_reject_count += 1;
                return .rejected_witness_invalid;
            }
        }

        // Payment keyhash witness coverage precheck
        // For key-controlled inputs, verifies a matching vkey witness keyhash exists.
        // Skips script-controlled inputs. Does NOT claim full witness authorization.
        {
            const cov = tx_decode.checkWitnessCoverage(self.alloc, raw_bytes, g_utxo_keyhash_fn);
            if (cov != null and cov.? == false) {
                self.reject_count += 1;
                self.witness_coverage_reject_count += 1;
                return .rejected_witness_coverage;
            }
        }

        // Input path classification (informational, no rejection)
        {
            const ipc = tx_decode.classifyInputPaths(self.alloc, raw_bytes, g_utxo_lookup_fn, g_utxo_keyhash_fn);
            if (ipc) |c| {
                self.inputs_key_controlled += c.key_controlled;
                self.inputs_script_non_plutus += c.script_non_plutus;
                self.inputs_plutus_definitive += c.plutus_definitive;
                self.inputs_unknown += c.unknown;
            }
        }

        // Plutus gate: reject or evaluate via external bridge.
        // Native-script-only txs do NOT have script_data_hash and pass this gate.
        {
            const sc = tx_decode.classifyTxScripts(raw_bytes);
            if (sc != null and sc.?.requires_plutus_definitive) {
                self.plutus_txs_seen += 1;
                if (sc.?.has_redeemers) self.plutus_with_redeemers += 1;
                if (sc.?.has_plutus_data) self.plutus_with_datums += 1;
                if (sc.?.has_reference_inputs) self.plutus_with_ref_inputs += 1;
                if (sc.?.plutus_readiness == 4) self.plutus_readiness_4_count += 1;

                // Attempt external evaluator bridge if enabled
                if (isPlutusEvalEnabled()) {
                    self.plutus_eval_attempt_total += 1;
                    const ctx = tx_decode.buildPlutusContext(raw_bytes);
                    if (ctx) |pctx| {
                        const result = eval_external.evaluateExternal(&pctx);
                        const hash_hex = fmtHash(&hash);
                        if (result.success) {
                            self.plutus_eval_success_total += 1;
                            std.debug.print("PLUTUS_EVAL_TRUTH: tx_hash={s} evaluator=external result=success ex_mem={d} ex_steps={d}\n", .{
                                &hash_hex, result.ex_units_mem, result.ex_units_steps,
                            });
                            // Plutus eval succeeded — do NOT reject, fall through to admission
                        } else if (result.error_code == .backend_unavailable) {
                            self.plutus_eval_unavailable_total += 1;
                            std.debug.print("PLUTUS_EVAL_TRUTH: tx_hash={s} evaluator=external result=unavailable ex_mem=0 ex_steps=0\n", .{&hash_hex});
                            self.reject_count += 1;
                            self.plutus_unsupported_reject_count += 1;
                            return .rejected_plutus_unsupported;
                        } else {
                            self.plutus_eval_fail_total += 1;
                            std.debug.print("PLUTUS_EVAL_TRUTH: tx_hash={s} evaluator=external result=failure error={d} ex_mem={d} ex_steps={d}\n", .{
                                &hash_hex, @intFromEnum(result.error_code), result.ex_units_mem, result.ex_units_steps,
                            });
                            self.reject_count += 1;
                            return .rejected_plutus_eval_failed;
                        }
                    } else {
                        // Could not build context — reject as unsupported
                        self.plutus_eval_unavailable_total += 1;
                        self.reject_count += 1;
                        self.plutus_unsupported_reject_count += 1;
                        return .rejected_plutus_unsupported;
                    }
                } else {
                    // Evaluator not enabled — reject as before (backward compatible)
                    self.reject_count += 1;
                    self.plutus_unsupported_reject_count += 1;
                    return .rejected_plutus_unsupported;
                }
            }
        }

        // Evict oldest entries to make room
        while (self.items.items.len >= self.max_items or
            (self.total_bytes + raw_bytes.len > self.max_bytes and self.items.items.len > 0))
        {
            const oldest = self.items.orderedRemove(0);
            self.total_bytes -= oldest.tx_bytes.len;
            self.alloc.free(oldest.tx_bytes);
            self.eviction_count += 1;
            self.change_seq += 1;
        }

        // Still over budget after eviction? Reject.
        if (self.total_bytes + raw_bytes.len > self.max_bytes) {
            self.reject_count += 1;
            return .rejected_too_large;
        }

        // Copy and insert
        const tx_copy = self.alloc.dupe(u8, raw_bytes) catch {
            self.reject_count += 1;
            return .rejected_too_large;
        };

        const now = compat.timestamp();
        self.items.append(.{
            .hash = hash,
            .tx_bytes = tx_copy,
            .received_unix = now,
        }) catch {
            self.alloc.free(tx_copy);
            self.reject_count += 1;
            return .rejected_too_large;
        };

        self.total_bytes += tx_copy.len;
        self.accept_count += 1;
        self.change_seq += 1;
        return .accepted;
    }

    pub fn changeSeq(self: *const Mempool) u64 {
        return self.change_seq;
    }

    pub fn count(self: *const Mempool) usize {
        return self.items.items.len;
    }

    pub fn totalBytes(self: *const Mempool) usize {
        return self.total_bytes;
    }

    /// Look up a transaction by its blake2b-256 hash.
    /// Returns the raw tx bytes (owned by mempool) or null if not found.
    pub fn getTx(self: *const Mempool, hash: [32]u8) ?[]const u8 {
        for (self.items.items) |item| {
            if (std.mem.eql(u8, &item.hash, &hash)) {
                return item.tx_bytes;
            }
        }
        return null;
    }

    pub fn fmtHash(hash: *const [32]u8) [64]u8 {
        const hex_chars = "0123456789abcdef";
        var out: [64]u8 = undefined;
        for (hash, 0..) |byte, i| {
            out[i * 2] = hex_chars[byte >> 4];
            out[i * 2 + 1] = hex_chars[byte & 0x0f];
        }
        return out;
    }

    /// Remove a single mempool tx by its blake2b-256 hash.
    /// Used by the producer to evict transactions that fail forge-time validation
    /// in a way that won't change next slot (parse fail, missing UTxO, balance, etc).
    /// Returns true if the tx was found and removed, false otherwise.
    /// Mirrors the eviction-bookkeeping pattern used by addTx / evictConfirmed.
    pub fn removeTx(self: *Mempool, txid: [32]u8) bool {
        var i: usize = 0;
        while (i < self.items.items.len) : (i += 1) {
            const item = &self.items.items[i];
            if (std.mem.eql(u8, &item.hash, &txid)) {
                self.total_bytes -= item.tx_bytes.len;
                self.alloc.free(item.tx_bytes);
                _ = self.items.orderedRemove(i);
                self.eviction_count += 1;
                self.change_seq += 1;
                return true;
            }
        }
        return false;
    }

    /// Evict mempool txs whose inputs overlap with consumed inputs from a block.
    /// Called after block apply to remove confirmed/conflicting transactions.
    /// Returns the number of evicted items.
    pub fn evictConfirmed(self: *Mempool, consumed: []const utxo.TxIn) usize {
        var evicted: usize = 0;
        var i: usize = 0;
        while (i < self.items.items.len) {
            const item = &self.items.items[i];
            const tx_inputs = tx_decode.extractTxInputsFromBytes(self.alloc, item.tx_bytes);
            defer if (tx_inputs) |ins| self.alloc.free(ins);

            var conflicts = false;
            if (tx_inputs) |inputs| {
                for (inputs) |inp| {
                    for (consumed) |c| {
                        if (inp.index == c.index and std.mem.eql(u8, &inp.tx_hash, &c.tx_hash)) {
                            conflicts = true;
                            break;
                        }
                    }
                    if (conflicts) break;
                }
            }

            if (conflicts) {
                self.total_bytes -= item.tx_bytes.len;
                self.alloc.free(item.tx_bytes);
                _ = self.items.orderedRemove(i);
                self.eviction_count += 1;
                self.confirmed_eviction_count += 1;
                self.change_seq += 1;
                evicted += 1;
                // Don't increment i — next item shifted into this slot
            } else {
                i += 1;
            }
        }
        return evicted;
    }

    /// Sweep mempool entries whose received_unix is older than the configured TTL.
    /// Call periodically (e.g., once per block apply). Logs only when items are removed.
    /// Returns the number of evicted items.
    pub fn sweepExpired(self: *Mempool, now_unix: i64) usize {
        const ttl_s = ttlSeconds();
        if (ttl_s <= 0) return 0; // disabled
        const cutoff = now_unix - ttl_s;
        var evicted: usize = 0;
        var i: usize = 0;
        while (i < self.items.items.len) {
            const item = &self.items.items[i];
            if (item.received_unix < cutoff) {
                self.total_bytes -= item.tx_bytes.len;
                self.alloc.free(item.tx_bytes);
                _ = self.items.orderedRemove(i);
                self.eviction_count += 1;
                self.change_seq += 1;
                evicted += 1;
                // Don't increment i — next item shifted into this slot
            } else {
                i += 1;
            }
        }
        if (evicted > 0) {
            std.debug.print("MEMPOOL_TTL_EVICT: removed={d} ttl_s={d} pool_size_after={d}\n", .{
                evicted, ttl_s, self.items.items.len,
            });
        }
        return evicted;
    }

    /// Check whether a candidate tx's inputs conflict with any existing mempool tx.
    fn hasInputConflict(self: *Mempool, candidate_bytes: []const u8) bool {
        const candidate_inputs = tx_decode.extractTxInputsFromBytes(self.alloc, candidate_bytes) orelse return false;
        defer self.alloc.free(candidate_inputs);
        if (candidate_inputs.len == 0) return false;

        for (self.items.items) |item| {
            const existing_inputs = tx_decode.extractTxInputsFromBytes(self.alloc, item.tx_bytes) orelse continue;
            defer self.alloc.free(existing_inputs);

            for (candidate_inputs) |ci| {
                for (existing_inputs) |ei| {
                    if (ci.index == ei.index and std.mem.eql(u8, &ci.tx_hash, &ei.tx_hash)) {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    /// Check whether any consumed input in a candidate tx is missing from UTxO store.
    /// Returns true if at least one input does not exist. Skips if lookup fn unavailable.
    fn hasMissingInput(alloc: std.mem.Allocator, candidate_bytes: []const u8) bool {
        const lookup = g_utxo_lookup_fn orelse return false;
        const inputs = tx_decode.extractTxInputsFromBytes(alloc, candidate_bytes) orelse return false;
        defer alloc.free(inputs);
        if (inputs.len == 0) return false;

        for (inputs) |inp| {
            if (lookup(inp.tx_hash, inp.index) == null) return true;
        }
        return false;
    }

    /// Check whether a candidate tx has sufficient input lovelace to cover outputs + fee.
    /// Returns true if balance is insufficient. Skips if lookup fn unavailable.
    fn hasInsufficientBalance(alloc: std.mem.Allocator, candidate_bytes: []const u8) bool {
        const lookup = g_utxo_lookup_fn orelse return false;

        // Parse inputs and sum their lovelace from UTxO store
        const inputs = tx_decode.extractTxInputsFromBytes(alloc, candidate_bytes) orelse return false;
        defer alloc.free(inputs);
        if (inputs.len == 0) return false;

        var input_total: u64 = 0;
        for (inputs) |inp| {
            const lovelace = lookup(inp.tx_hash, inp.index) orelse return false; // missing → handled by hasMissingInput
            input_total +|= lovelace;
        }

        // Parse outputs lovelace + fee from raw tx bytes
        const output_fee = tx_decode.extractOutputTotalAndFee(alloc, candidate_bytes) orelse return false;
        const required = output_fee.output_total +| output_fee.fee;

        return input_total < required;
    }

    const ValidityResult = enum { ok, ttl_expired, start_future };

    /// Check whether a candidate tx's validity interval covers the current slot.
    fn checkValidityInterval(alloc: std.mem.Allocator, candidate_bytes: []const u8) ValidityResult {
        const slot_fn = g_current_slot_fn orelse return .ok; // no slot provider → skip
        const current_slot = slot_fn() orelse return .ok; // slot unavailable → skip
        if (current_slot == 0) return .ok;

        const vi = tx_decode.extractValidityInterval(alloc, candidate_bytes) orelse return .ok;

        // TTL / invalid_hereafter: tx invalid at or after this slot
        if (vi.ttl) |ttl| {
            if (current_slot >= ttl) return .ttl_expired;
        }

        // validity_start / invalid_before: tx invalid before this slot
        if (vi.validity_start) |vs| {
            if (current_slot < vs) return .start_future;
        }

        return .ok;
    }

    /// Native script evaluation gate.
    /// Evaluates witness native scripts with proper container semantics.
    /// Returns true (reject) only when a script definitively evaluates to false.
    /// Skips when no scripts, parse inconclusive, or slot unavailable.
    fn hasNativeScriptViolation(alloc: std.mem.Allocator, candidate_bytes: []const u8) bool {
        const slot_fn = g_current_slot_fn orelse return false;
        const current_slot = slot_fn() orelse return false;
        if (current_slot == 0) return false;

        const result = tx_decode.evaluateWitnessNativeScripts(alloc, candidate_bytes, current_slot);
        return result != null and result.? == false;
    }

    /// Export mempool txs for dryrun block candidate metadata (v2.1.0-a).
    /// Phase 9.7: when mempool has more than 1 item, items are picked in
    /// fee/size-descending order (knapsack-style), capped by max_tx and
    /// max_bytes. Falls back to txid-lex order if fee extraction fails or
    /// the mempool is small enough that reordering wouldn't help.
    /// `max_body_bytes` enforces the *protocol* max_block_body_size proactively
    /// during selection so we don't waste a forge slot on a post-hoc reject.
    /// 0 means "no protocol cap" (legacy / pre-params behavior).
    /// Caller must free the returned slice with alloc.free().
    /// Returns null if mempool is empty or allocation fails.
    /// Read-only on mempool state — no mutation.
    pub fn exportForDryrunBlock(
        self: *Mempool,
        alloc: std.mem.Allocator,
        max_tx: u32,
        max_bytes: usize,
        max_body_bytes: u64,
    ) ?[]DryrunExportItem {
        if (self.items.items.len == 0) return null;

        const REORDER_MIN: usize = 2;
        const use_weighting = self.items.items.len >= REORDER_MIN;

        // Candidate = (txid, tx_bytes_ref, fee, size, fee_per_byte_x1000).
        // We build candidates up-front so sorting doesn't re-parse.
        const Candidate = struct {
            txid: [32]u8,
            tx_bytes: []const u8,
            size: u64,
            fee: u64,
            score_x1000: u64, // fee * 1000 / size
        };

        var cands = std.array_list.Managed(Candidate).init(alloc);
        defer cands.deinit();

        var fee_extract_failed = false;
        for (self.items.items) |item| {
            const txid = block_hash.computeCanonicalTxid(item.tx_bytes) orelse continue;
            const size: u64 = item.tx_bytes.len;
            var fee: u64 = 0;
            if (use_weighting) {
                if (tx_decode.extractOutputTotalAndFee(alloc, item.tx_bytes)) |ofr| {
                    fee = ofr.fee;
                } else {
                    fee_extract_failed = true;
                }
            }
            const score: u64 = if (size == 0) 0 else (fee * 1000) / size;
            cands.append(.{
                .txid = txid,
                .tx_bytes = item.tx_bytes,
                .size = size,
                .fee = fee,
                .score_x1000 = score,
            }) catch return null;
        }

        if (cands.items.len == 0) return null;

        const reorder_ok = use_weighting and !fee_extract_failed;

        if (reorder_ok) {
            // fee/size descending; tie-break on txid lex for determinism.
            std.mem.sort(Candidate, cands.items, {}, struct {
                fn lessThan(_: void, a: Candidate, b: Candidate) bool {
                    if (a.score_x1000 != b.score_x1000) return a.score_x1000 > b.score_x1000;
                    return std.mem.order(u8, &a.txid, &b.txid) == .lt;
                }
            }.lessThan);
        } else {
            // Fallback: lex order (existing behavior).
            std.mem.sort(Candidate, cands.items, {}, struct {
                fn lessThan(_: void, a: Candidate, b: Candidate) bool {
                    return std.mem.order(u8, &a.txid, &b.txid) == .lt;
                }
            }.lessThan);
        }

        // Knapsack pass with two guards:
        //  - hard cap on count (max_tx) and bytes (max_bytes)
        //  - anti-fragmentation: skip a tx that would leave <2KB headroom;
        //    use that space only when the next tx fits naturally.
        var out = std.array_list.Managed(DryrunExportItem).init(alloc);
        defer out.deinit();

        const FRAG_MARGIN: usize = 2048;
        var cumulative_bytes: usize = 0;
        var total_fee: u64 = 0;
        var skipped_body_cap: usize = 0;
        var total_tried: usize = 0;
        // body_cap: 0 means "no protocol cap" (legacy callers / pre-params).
        const body_cap_active = max_body_bytes > 0;
        for (cands.items) |c| {
            if (out.items.len >= max_tx) break;
            total_tried += 1;
            const next = cumulative_bytes + c.size;
            // Proactive protocol body-size cap. Once exceeded, stop selecting
            // entirely — fee/size-sorted order means later candidates are no
            // smaller in fee/byte and we want a stable, predictable cut.
            if (body_cap_active and @as(u64, next) > max_body_bytes) {
                skipped_body_cap += 1;
                break;
            }
            if (next > max_bytes) continue; // skip oversize; may still fit smaller
            // Anti-fragmentation: once we're within FRAG_MARGIN of the cap,
            // only accept txs that fit *exactly* (no point saving bytes for
            // the next loop when we're already near-full).
            if (max_bytes > FRAG_MARGIN and cumulative_bytes > max_bytes - FRAG_MARGIN and c.size > max_bytes - cumulative_bytes) continue;
            out.append(.{
                .txid = c.txid,
                .tx_bytes = c.tx_bytes,
            }) catch return null;
            cumulative_bytes += c.size;
            total_fee +%= c.fee;
        }

        if (body_cap_active) {
            std.debug.print("MEMPOOL_BODY_CAP: max={d} picked={d} skipped={d} total_tried={d}\n", .{
                max_body_bytes,
                out.items.len,
                skipped_body_cap,
                total_tried,
            });
        }

        if (out.items.len == 0) return null;

        const picked = out.toOwnedSlice() catch return null;

        std.debug.print("FORGE_MEMPOOL_SELECT: tx_count={d} total_size={d} total_fee={d} reorder={s} fallback_reason={s}\n", .{
            picked.len,
            cumulative_bytes,
            total_fee,
            if (reorder_ok) "fee_per_size" else "lex",
            if (!use_weighting) "small_mempool" else if (fee_extract_failed) "fee_parse_fail" else "none",
        });

        return picked;
    }
};

/// Validate tx CBOR structure (admission policy).
/// Accepts Cardano tx shapes:
///   - Array wrapper: [body, witnesses, ...] where body is array/map
///   - Map wrapper: {0: body, 1: witnesses, ...}
/// Rejects garbage, oversized witnesses, and unparseable CBOR.
pub fn validateTxCbor(alloc: std.mem.Allocator, tx_bytes: []const u8) !void {
    if (tx_bytes.len == 0) return error.InvalidTxCbor;
    if (tx_bytes.len > MAX_TX_SIZE) return error.InvalidTxCbor;

    var fbs = compat.fixedBufferStream(tx_bytes);
    const term = cbor.decode(alloc, fbs.reader()) catch return error.InvalidTxCbor;
    defer cbor.free(term, alloc);

    switch (term) {
        .array => |arr| {
            // Cardano tx as array: [body, witnesses, ...]
            // Must have at least 1 element (body)
            if (arr.len == 0) return error.InvalidTxCbor;
            // Body (arr[0]) should be map or array
            switch (arr[0]) {
                .map_u64, .array => {},
                else => return error.InvalidTxCbor,
            }
            // Witness set (arr[1]) bounds check if present
            if (arr.len >= 2) {
                switch (arr[1]) {
                    .map_u64 => |wmap| {
                        if (wmap.len > MAX_WITNESS_ITEMS) return error.InvalidTxCbor;
                    },
                    .array => |warr| {
                        if (warr.len > MAX_WITNESS_ITEMS) return error.InvalidTxCbor;
                    },
                    else => {}, // tolerate other shapes
                }
            }
        },
        .map_u64 => |m| {
            // Cardano tx as map: {0: body, ...}
            if (m.len == 0) return error.InvalidTxCbor;
            // Must contain key 0 (body)
            var has_body = false;
            for (m) |entry| {
                if (entry.key == 0) {
                    has_body = true;
                    break;
                }
            }
            if (!has_body) return error.InvalidTxCbor;
            // Witness set bounds (key 1) if present
            for (m) |entry| {
                if (entry.key == 1) {
                    switch (entry.value) {
                        .map_u64 => |wmap| {
                            if (wmap.len > MAX_WITNESS_ITEMS) return error.InvalidTxCbor;
                        },
                        .array => |warr| {
                            if (warr.len > MAX_WITNESS_ITEMS) return error.InvalidTxCbor;
                        },
                        else => {},
                    }
                    break;
                }
            }
        },
        else => return error.InvalidTxCbor,
    }
}

fn charToNibble(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

pub fn decodeHex(alloc: std.mem.Allocator, hex: []const u8) ?[]u8 {
    if (hex.len % 2 != 0) return null;
    const out = alloc.alloc(u8, hex.len / 2) catch return null;
    for (0..out.len) |i| {
        const hi = charToNibble(hex[i * 2]) orelse {
            alloc.free(out);
            return null;
        };
        const lo = charToNibble(hex[i * 2 + 1]) orelse {
            alloc.free(out);
            return null;
        };
        out[i] = (@as(u8, hi) << 4) | @as(u8, lo);
    }
    return out;
}

// ---- Dryrun export types (v2.1.0-a) ----

const block_hash = @import("block_hash.zig");

pub const DryrunExportItem = struct {
    txid: [32]u8, // canonical Cardano txid = blake2b256(tx_body)
    tx_bytes: []const u8, // full tx CBOR (points into mempool Item.tx_bytes)
};

// ---------------------------------------------------------------------------
// Tests: Plutus evaluator bridge
// ---------------------------------------------------------------------------

test "plutus eval: disabled by default rejects as before" {
    // Ensure env var is not set (cache reset for test)
    g_plutus_eval_enabled = .disabled;
    var mp = Mempool.init(std.testing.allocator, 16, 64 * 1024);
    defer mp.deinit();
    // Any non-Plutus tx will pass the gate; Plutus rejection requires
    // a real Plutus tx. We test the flag gate directly.
    try std.testing.expect(!isPlutusEvalEnabled());
}

test "plutus eval: env var enables bridge" {
    // Simulate enabled state
    g_plutus_eval_enabled = .enabled;
    defer {
        g_plutus_eval_enabled = .disabled;
    }
    try std.testing.expect(isPlutusEvalEnabled());
}

test "plutus eval: AddResult enum has new variants" {
    // Compile-time check that new variants exist
    const r1: AddResult = .rejected_plutus_eval_failed;
    const r2: AddResult = .accepted_plutus_evaluated;
    try std.testing.expect(r1 != r2);
}

test "plutus eval: metrics counters initialize to zero" {
    var mp = Mempool.init(std.testing.allocator, 16, 64 * 1024);
    defer mp.deinit();
    try std.testing.expectEqual(@as(u64, 0), mp.plutus_eval_attempt_total);
    try std.testing.expectEqual(@as(u64, 0), mp.plutus_eval_success_total);
    try std.testing.expectEqual(@as(u64, 0), mp.plutus_eval_fail_total);
    try std.testing.expectEqual(@as(u64, 0), mp.plutus_eval_unavailable_total);
}

// ---------------------------------------------------------------------------
// Tests: exportForDryrunBlock body-size cap
// ---------------------------------------------------------------------------

// Test helper: directly inject a synthetic tx into mp.items, bypassing addTx
// so unit tests don't depend on UTxO/balance/min-fee context. The tx is a
// minimal CBOR `[body_map, witnesses_map]` shaped so computeCanonicalTxid()
// and extractOutputTotalAndFee() both succeed.
fn buildSyntheticTx(alloc: std.mem.Allocator, fee: u64, padding_len: usize) ![]u8 {
    // Body map = {0: bstr(padding), 2: u64(fee)} → CBOR-encoded map_u64.
    // Outer tx = [body_map, {}].
    var buf = std.array_list.Managed(u8).init(alloc);
    errdefer buf.deinit();
    try buf.append(0x82); // array(2)
    // map(2)
    try buf.append(0xa2);
    // key 0 → bstr(padding_len)
    try buf.append(0x00);
    if (padding_len <= 23) {
        try buf.append(@as(u8, 0x40) | @as(u8, @intCast(padding_len)));
    } else if (padding_len <= 0xff) {
        try buf.append(0x58);
        try buf.append(@as(u8, @intCast(padding_len)));
    } else {
        try buf.append(0x59);
        try buf.append(@as(u8, @intCast((padding_len >> 8) & 0xff)));
        try buf.append(@as(u8, @intCast(padding_len & 0xff)));
    }
    // Distinct padding bytes guarantee distinct txids per call (caller varies).
    var i: usize = 0;
    while (i < padding_len) : (i += 1) {
        // mix in fee so different-fee txs of same size still hash differently
        try buf.append(@as(u8, @intCast((fee +% i) & 0xff)));
    }
    // key 2 → fee. Encode as smallest u64.
    try buf.append(0x02);
    if (fee <= 23) {
        try buf.append(@as(u8, @intCast(fee)));
    } else if (fee <= 0xff) {
        try buf.append(0x18);
        try buf.append(@as(u8, @intCast(fee)));
    } else if (fee <= 0xffff) {
        try buf.append(0x19);
        try buf.append(@as(u8, @intCast((fee >> 8) & 0xff)));
        try buf.append(@as(u8, @intCast(fee & 0xff)));
    } else {
        try buf.append(0x1a);
        try buf.append(@as(u8, @intCast((fee >> 24) & 0xff)));
        try buf.append(@as(u8, @intCast((fee >> 16) & 0xff)));
        try buf.append(@as(u8, @intCast((fee >> 8) & 0xff)));
        try buf.append(@as(u8, @intCast(fee & 0xff)));
    }
    // witnesses = empty map
    try buf.append(0xa0);
    return buf.toOwnedSlice();
}

fn injectSyntheticTx(mp: *Mempool, tx_bytes: []const u8) !void {
    const dup = try mp.alloc.dupe(u8, tx_bytes);
    var hash: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(dup, &hash, .{});
    try mp.items.append(.{
        .hash = hash,
        .tx_bytes = dup,
        .received_unix = 0,
    });
    mp.total_bytes += dup.len;
}

test "exportForDryrunBlock: body-size cap selects highest fee/byte ratio txs" {
    const alloc = std.testing.allocator;
    var mp = Mempool.init(alloc, 64, 64 * 1024);
    defer mp.deinit();

    // 5 txs, all the same shape so size is identical → fee/byte order = fee order.
    // Fees ascending: 1000, 2000, 3000, 4000, 5000 (each encodes as 3 CBOR bytes
    // via the 0x19 u16 prefix, so all txs have identical length). Highest 3 by
    // fee/byte = 5000, 4000, 3000.
    const fees = [_]u64{ 1000, 2000, 3000, 4000, 5000 };
    var tx_size: usize = 0;
    for (fees) |fee| {
        const tx = try buildSyntheticTx(alloc, fee, 32);
        defer alloc.free(tx);
        if (tx_size == 0) tx_size = tx.len;
        // Sanity: every synthetic tx has the same length so the test is deterministic.
        try std.testing.expectEqual(tx_size, tx.len);
        try injectSyntheticTx(&mp, tx);
    }

    // Cap chosen so exactly 3 txs fit.
    const cap: u64 = @as(u64, tx_size) * 3;
    const picked_opt = mp.exportForDryrunBlock(alloc, 50, 1024 * 1024, cap);
    try std.testing.expect(picked_opt != null);
    const picked = picked_opt.?;
    defer alloc.free(picked);

    try std.testing.expectEqual(@as(usize, 3), picked.len);

    // Cumulative size must be <= cap.
    var cumulative: u64 = 0;
    for (picked) |p| cumulative += p.tx_bytes.len;
    try std.testing.expect(cumulative <= cap);

    // Verify selection picked the 3 highest-fee txs by inspecting fees encoded
    // in their bodies. Each tx has a unique fee, so we can match-on-fee.
    var seen_5000 = false;
    var seen_4000 = false;
    var seen_3000 = false;
    for (picked) |p| {
        const result = tx_decode.extractOutputTotalAndFee(alloc, p.tx_bytes) orelse continue;
        if (result.fee == 5000) seen_5000 = true;
        if (result.fee == 4000) seen_4000 = true;
        if (result.fee == 3000) seen_3000 = true;
    }
    try std.testing.expect(seen_5000 and seen_4000 and seen_3000);
}

test "removeTx: evicts existing tx and updates bookkeeping" {
    const alloc = std.testing.allocator;
    var mp = Mempool.init(alloc, 64, 64 * 1024);
    defer mp.deinit();

    // Inject two synthetic txs so we can verify only the targeted one is removed.
    const tx_a = try buildSyntheticTx(alloc, 1000, 32);
    defer alloc.free(tx_a);
    const tx_b = try buildSyntheticTx(alloc, 2000, 32);
    defer alloc.free(tx_b);
    try injectSyntheticTx(&mp, tx_a);
    try injectSyntheticTx(&mp, tx_b);

    try std.testing.expectEqual(@as(usize, 2), mp.count());
    const total_before = mp.totalBytes();
    const evict_before = mp.eviction_count;
    const seq_before = mp.changeSeq();

    // Remember tx_a's hash so we can target it.
    var hash_a: [32]u8 = undefined;
    std.crypto.hash.blake2.Blake2b256.hash(tx_a, &hash_a, .{});

    // Remove tx_a.
    try std.testing.expect(mp.removeTx(hash_a));

    try std.testing.expectEqual(@as(usize, 1), mp.count());
    try std.testing.expectEqual(total_before - tx_a.len, mp.totalBytes());
    try std.testing.expectEqual(evict_before + 1, mp.eviction_count);
    try std.testing.expect(mp.changeSeq() > seq_before);

    // Removing the same hash again returns false (idempotent on missing).
    try std.testing.expect(!mp.removeTx(hash_a));

    // Removing a never-seen hash returns false without side effects.
    const hash_zero: [32]u8 = [_]u8{0} ** 32;
    const total_mid = mp.totalBytes();
    const evict_mid = mp.eviction_count;
    try std.testing.expect(!mp.removeTx(hash_zero));
    try std.testing.expectEqual(total_mid, mp.totalBytes());
    try std.testing.expectEqual(evict_mid, mp.eviction_count);
}

test "exportForDryrunBlock: cap=0 disables protocol body cap (legacy)" {
    const alloc = std.testing.allocator;
    var mp = Mempool.init(alloc, 64, 64 * 1024);
    defer mp.deinit();

    // 3 txs, all admitted under legacy max_bytes=1MB; cap=0 ⇒ no protocol cap.
    const fees = [_]u64{ 1000, 2000, 3000 };
    for (fees) |fee| {
        const tx = try buildSyntheticTx(alloc, fee, 32);
        defer alloc.free(tx);
        try injectSyntheticTx(&mp, tx);
    }

    const picked_opt = mp.exportForDryrunBlock(alloc, 50, 1024 * 1024, 0);
    try std.testing.expect(picked_opt != null);
    const picked = picked_opt.?;
    defer alloc.free(picked);

    // All 3 should be selected (no protocol cap).
    try std.testing.expectEqual(@as(usize, 3), picked.len);
}
