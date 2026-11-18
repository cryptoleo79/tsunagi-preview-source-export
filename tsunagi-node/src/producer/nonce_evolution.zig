const std = @import("std");
const compat = @import("compat");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

/// Cardano Praos epoch nonce evolution state.
///
/// The epoch nonce for epoch N is derived from:
///   nonce[N] = blake2b256(nonce[N-1] || candidate_nonce)
/// where candidate_nonce is the accumulated hash of VRF nonce contributions
/// from blocks in the first 80% of epoch N-1.
///
/// VRF nonce contribution per block = blake2b256("N" || vrf_output(64))
/// where "N" is the literal ASCII byte 0x4E.
pub const NonceState = struct {
    /// Current finalized epoch nonce (used for VRF checks this epoch)
    epoch_nonce: [32]u8 = [_]u8{0} ** 32,
    epoch_nonce_valid: bool = false,

    /// Epoch number for which epoch_nonce is valid
    nonce_epoch: u64 = 0,

    /// Running blake2b256 accumulator for candidate nonce
    /// Accumulates: blake2b256("N" || vrf_output) for each block
    accumulator: [32]u8 = [_]u8{0} ** 32,
    accumulator_count: u32 = 0,
    accumulator_epoch: u64 = 0,

    /// Whether accumulation is complete for the current epoch (80% reached)
    candidate_ready: bool = false,
    candidate_nonce: [32]u8 = [_]u8{0} ** 32,
};

/// Process a block's VRF output for nonce evolution.
/// Call this for every received block during chain following.
///
/// epoch: the epoch this block belongs to
/// slot_in_epoch: the slot position within the epoch (0-based)
/// epoch_length: total slots per epoch (86400 on preview, 432000 on mainnet)
/// vrf_output: the 64-byte VRF output from the block header [5][0]
pub fn processBlockVrf(
    state: *NonceState,
    epoch: u64,
    slot_in_epoch: u64,
    epoch_length: u64,
    vrf_output: [64]u8,
) void {
    // Epoch changed — finalize previous accumulation if ready
    if (epoch != state.accumulator_epoch and state.accumulator_count > 0) {
        finalizeAccumulator(state);
    }

    // Start new accumulation for this epoch
    if (epoch != state.accumulator_epoch) {
        state.accumulator = [_]u8{0} ** 32;
        state.accumulator_count = 0;
        state.accumulator_epoch = epoch;
        state.candidate_ready = false;
    }

    // Only accumulate in the first 80% of the epoch
    const cutoff = epoch_length * 4 / 5;
    if (slot_in_epoch >= cutoff) {
        if (!state.candidate_ready and state.accumulator_count > 0) {
            // Just crossed the 80% boundary — candidate is ready
            state.candidate_nonce = state.accumulator;
            state.candidate_ready = true;
            std.debug.print("NONCE_CANDIDATE_READY: epoch={d} vrf_count={d} candidate={x}\n", .{
                epoch, state.accumulator_count, state.candidate_nonce[0..8],
            });
        }
        return; // Don't accumulate past 80%
    }

    // Compute nonce contribution: blake2b256("N" || vrf_output)
    var nonce_input: [1 + 64]u8 = undefined;
    nonce_input[0] = 'N'; // Praos nonce tag
    @memcpy(nonce_input[1..65], &vrf_output);
    var nonce_contribution: [32]u8 = undefined;
    Blake2b256.hash(&nonce_input, &nonce_contribution, .{});

    // XOR into accumulator (Cardano uses XOR for nonce accumulation)
    for (&state.accumulator, nonce_contribution) |*a, c| {
        a.* ^= c;
    }
    state.accumulator_count += 1;
}

/// Finalize the accumulator and compute the new epoch nonce.
/// Called when epoch boundary is crossed.
fn finalizeAccumulator(state: *NonceState) void {
    if (state.accumulator_count == 0) return;

    // If candidate wasn't marked ready (less than 80% processed), use current state
    if (!state.candidate_ready) {
        state.candidate_nonce = state.accumulator;
        state.candidate_ready = true;
    }

    // new_nonce = blake2b256(prev_nonce || candidate_nonce)
    if (state.epoch_nonce_valid) {
        var combined: [64]u8 = undefined;
        @memcpy(combined[0..32], &state.epoch_nonce);
        @memcpy(combined[32..64], &state.candidate_nonce);
        Blake2b256.hash(&combined, &state.epoch_nonce, .{});
        state.nonce_epoch = state.accumulator_epoch + 1;
        std.debug.print("NONCE_EVOLVED: new_epoch={d} nonce={x} from_vrf_count={d}\n", .{
            state.nonce_epoch, state.epoch_nonce[0..8], state.accumulator_count,
        });
    } else {
        // First epoch — use candidate as initial nonce
        state.epoch_nonce = state.candidate_nonce;
        state.epoch_nonce_valid = true;
        state.nonce_epoch = state.accumulator_epoch + 1;
        std.debug.print("NONCE_INITIAL: epoch={d} nonce={x} from_vrf_count={d}\n", .{
            state.nonce_epoch, state.epoch_nonce[0..8], state.accumulator_count,
        });
    }

    state.candidate_ready = false;
    state.accumulator_count = 0;
}

/// Save nonce state to a JSON file.
pub fn saveState(state: *const NonceState, path: []const u8) void {
    var buf: [512]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{"nonce_epoch":{d},"epoch_nonce":"{x}","epoch_nonce_valid":{s},"accumulator_epoch":{d},"accumulator_count":{d},"candidate_ready":{s}}}
    , .{
        state.nonce_epoch,
        &state.epoch_nonce,
        if (state.epoch_nonce_valid) "true" else "false",
        state.accumulator_epoch,
        state.accumulator_count,
        if (state.candidate_ready) "true" else "false",
    }) catch return;
    var f = compat.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    defer f.close();
    f.writeAll(json) catch {};
    std.debug.print("NONCE_STATE_SAVED: path={s} epoch={d} valid={}\n", .{
        path, state.nonce_epoch, state.epoch_nonce_valid,
    });
}

/// Load nonce state from a JSON file. Returns true if loaded successfully.
pub fn loadState(state: *NonceState, path: []const u8) bool {
    var f = compat.fs.cwd().openFile(path, .{}) catch return false;
    defer f.close();
    var buf: [512]u8 = undefined;
    const n = f.readAll(&buf) catch return false;
    const content = buf[0..n];

    // Simple substring parsing for nonce_epoch and epoch_nonce
    const epoch_key = "\"nonce_epoch\":";
    const nonce_key = "\"epoch_nonce\":\"";
    const valid_key = "\"epoch_nonce_valid\":true";

    if (std.mem.indexOf(u8, content, valid_key) == null) return false;

    if (std.mem.indexOf(u8, content, epoch_key)) |idx| {
        const start = idx + epoch_key.len;
        var end = start;
        while (end < content.len and content[end] >= '0' and content[end] <= '9') end += 1;
        if (end > start) {
            state.nonce_epoch = std.fmt.parseInt(u64, content[start..end], 10) catch return false;
        }
    } else return false;

    if (std.mem.indexOf(u8, content, nonce_key)) |idx| {
        const start = idx + nonce_key.len;
        if (start + 64 <= content.len) {
            _ = std.fmt.hexToBytes(&state.epoch_nonce, content[start .. start + 64]) catch return false;
            state.epoch_nonce_valid = true;
        }
    } else return false;

    std.debug.print("NONCE_STATE_LOADED: path={s} epoch={d} nonce={x}\n", .{
        path, state.nonce_epoch, state.epoch_nonce[0..8],
    });
    return true;
}

/// Module-level circuit breaker for Koios fetch. Protects against hammering
/// Koios when it's down/rate-limiting us.
const CircuitBreaker = struct {
    mu: compat.Mutex = .{},
    consecutive_failures: u32 = 0,
    opened_unix: i64 = 0,
    open_duration_s: i64 = 300, // 5 min
    failure_threshold: u32 = 3,
};
var g_koios_breaker: CircuitBreaker = .{};

/// Mark a fetch failure. If threshold reached, opens breaker.
fn breakerOnFailure() void {
    g_koios_breaker.mu.lock();
    defer g_koios_breaker.mu.unlock();
    g_koios_breaker.consecutive_failures += 1;
    if (g_koios_breaker.consecutive_failures >= g_koios_breaker.failure_threshold and g_koios_breaker.opened_unix == 0) {
        g_koios_breaker.opened_unix = compat.timestamp();
        std.debug.print("NONCE_FETCH_BREAKER_OPEN: threshold={d} hits, cooldown={d}s\n", .{
            g_koios_breaker.failure_threshold, g_koios_breaker.open_duration_s,
        });
    }
}

/// Mark a fetch success. Resets breaker.
fn breakerOnSuccess() void {
    g_koios_breaker.mu.lock();
    defer g_koios_breaker.mu.unlock();
    g_koios_breaker.consecutive_failures = 0;
    g_koios_breaker.opened_unix = 0;
}

/// Check if breaker is open and within cooldown. Returns true iff fetch should be skipped.
/// If cooldown expired, resets opened_unix (half-open) so one fetch is allowed.
fn breakerShouldSkip() bool {
    g_koios_breaker.mu.lock();
    defer g_koios_breaker.mu.unlock();
    if (g_koios_breaker.opened_unix == 0) return false;
    const now = compat.timestamp();
    const cooldown_ends = g_koios_breaker.opened_unix + g_koios_breaker.open_duration_s;
    if (now >= cooldown_ends) {
        // Half-open: allow one test fetch. Clear opened_unix but keep failure count
        // so a fresh failure re-opens immediately (extending cooldown).
        g_koios_breaker.opened_unix = 0;
        return false;
    }
    std.debug.print("NONCE_FETCH_BREAKER_OPEN: skip fetch (cooldown ends at unix={d})\n", .{cooldown_ends});
    return true;
}

/// Auto-fetch epoch nonce. Local-first architecture: cardano-cli is the
/// authoritative source (cardano-node IS the chain truth for this host),
/// Koios is observability/bootstrap assistance only. Persisted state in
/// nonce_state.json (loaded at startup) is the tier-3 fallback for cold
/// boot when neither cli nor Koios is available.
///
/// Hierarchy:
///   1. local cardano-cli `query protocol-state` (preferred, no HTTP)
///   2. Koios HTTP (if breaker closed)
///   3. persisted nonce_state.json (loaded at startup, used implicitly
///      if both above fail and existing state is still recent)
///
/// Returns true iff state was updated by tier 1 or tier 2.
pub fn fetchEpochNonce(state: *NonceState, epoch: u64, net: []const u8) bool {
    // Tier 1: local cardano-cli. Bypasses Koios breaker entirely — local
    // source health is independent of external HTTP rate-limiting.
    if (compat.getenv("TSUNAGI_CARDANO_NODE_SOCKET") != null) {
        if (fetchEpochNonceViaCardanoCli(state, epoch)) return true;
    }
    // Tier 2: Koios. Only if the local path failed or is unconfigured,
    // and the Koios breaker isn't currently open.
    if (!breakerShouldSkip()) {
        if (fetchEpochNonceFromKoios(state, epoch, net)) return true;
    }
    return false;
}

/// Monotonic nonce-state writer. Refuses any write whose epoch is STRICTLY
/// LESS than the currently-held nonce_epoch (regression). Cold-boot state
/// (epoch_nonce_valid=false) accepts any write. Always accepts same-epoch
/// writes (refreshing the nonce for the current epoch is safe).
///
/// Centralizes the invariant so every external-source path (cardano-cli,
/// Koios, disk) goes through it. Local-evolution finalizer is also
/// monotonic by construction (accumulator_epoch + 1) but routes through
/// here for symmetric logging.
fn updateStateMonotonic(state: *NonceState, new_epoch: u64, new_nonce: *const [32]u8, source: []const u8) bool {
    if (state.epoch_nonce_valid and new_epoch < state.nonce_epoch) {
        std.debug.print("NONCE_REGRESSION_REFUSED: incoming_epoch={d} current_epoch={d} source={s} incoming_first8={x} current_first8={x}\n", .{
            new_epoch, state.nonce_epoch, source,
            new_nonce[0..8], state.epoch_nonce[0..8],
        });
        return false;
    }
    state.epoch_nonce = new_nonce.*;
    state.epoch_nonce_valid = true;
    state.nonce_epoch = new_epoch;
    return true;
}

/// Whitespace-tolerant JSON key→hex-string-value finder.
///
/// Matches `"<key>"`, then optional whitespace, then `:`, then optional
/// whitespace, then `"`, then exactly `out.len * 2` hex digits which it
/// decodes into `out`. Returns true on success. Used for parsing fields
/// from cardano-cli pretty-printed output where the canonical Aeson layout
/// is `"key": "value"` with a space after the colon — naive substring
/// matchers built around `"key":"value"` fail under that formatting.
fn findHexStringValue(body: []const u8, key: []const u8, out: []u8) bool {
    var key_buf: [64]u8 = undefined;
    if (key.len + 2 > key_buf.len) return false;
    key_buf[0] = '"';
    @memcpy(key_buf[1 .. 1 + key.len], key);
    key_buf[1 + key.len] = '"';
    const key_quoted = key_buf[0 .. key.len + 2];

    const idx = std.mem.indexOf(u8, body, key_quoted) orelse return false;
    var p: usize = idx + key_quoted.len;
    while (p < body.len and (body[p] == ' ' or body[p] == '\t' or body[p] == '\n' or body[p] == '\r')) : (p += 1) {}
    if (p >= body.len or body[p] != ':') return false;
    p += 1;
    while (p < body.len and (body[p] == ' ' or body[p] == '\t' or body[p] == '\n' or body[p] == '\r')) : (p += 1) {}
    if (p >= body.len or body[p] != '"') return false;
    p += 1;
    const need = out.len * 2;
    if (p + need > body.len) return false;
    _ = std.fmt.hexToBytes(out, body[p .. p + need]) catch return false;
    return true;
}

/// Local fallback: read current epoch nonce from cardano-node via
/// `cardano-cli query protocol-state`. The protocol-state JSON exposes
/// top-level `epochNonce` (32-byte hex) which is the current epoch's
/// leader-election nonce as cardano-node has it.
///
/// Requires TSUNAGI_CARDANO_NODE_SOCKET to be set (typically also set
/// for the acceptance_tracker tip fallback). Optional env:
/// TSUNAGI_CARDANO_CLI (defaults to "cardano-cli"),
/// TSUNAGI_TESTNET_MAGIC (defaults to "2" for preview).
///
/// Does not touch the Koios breaker — independent path.
fn fetchEpochNonceViaCardanoCli(state: *NonceState, requested_epoch: u64) bool {
    const socket = compat.getenv("TSUNAGI_CARDANO_NODE_SOCKET") orelse return false;
    const cli = compat.getenv("TSUNAGI_CARDANO_CLI") orelse "cardano-cli";
    const magic = compat.getenv("TSUNAGI_TESTNET_MAGIC") orelse "2";
    const tmp_path = "/tmp/tsunagi-nonce-protocol-state.json";

    // Run: cardano-cli query protocol-state --testnet-magic <N> --socket-path <S> --out-file <tmp>
    var argv_ps = [_][]const u8{ cli, "query", "protocol-state", "--testnet-magic", magic, "--socket-path", socket, "--out-file", tmp_path };
    var ps_child = compat.Child.init(&argv_ps, std.heap.page_allocator);
    ps_child.stdout_behavior = .Ignore;
    ps_child.stderr_behavior = .Ignore;
    ps_child.spawn() catch {
        std.debug.print("NONCE_FETCH_CLI: spawn failed (protocol-state)\n", .{});
        return false;
    };
    const ps_result = ps_child.wait() catch return false;
    if (ps_result.exited != 0) {
        std.debug.print("NONCE_FETCH_CLI: cardano-cli protocol-state exit={d}\n", .{ps_result.exited});
        return false;
    }

    // Read protocol-state JSON
    var ps_buf: [128 * 1024]u8 = undefined; // protocol-state can be large
    var f = compat.fs.cwd().openFile(tmp_path, .{}) catch {
        std.debug.print("NONCE_FETCH_CLI: cannot open {s}\n", .{tmp_path});
        return false;
    };
    defer f.close();
    defer compat.fs.cwd().deleteFile(tmp_path) catch {};
    const ps_n = f.readAll(&ps_buf) catch return false;
    const ps_body = ps_buf[0..ps_n];

    // cardano-cli pretty-prints JSON with whitespace after the colon, e.g.
    //   "epochNonce": "0abc..."
    // so the parser must tolerate optional whitespace between `:` and the
    // opening string quote.
    var nonce: [32]u8 = undefined;
    if (!findHexStringValue(ps_body, "epochNonce", &nonce)) {
        std.debug.print("NONCE_FETCH_CLI: epochNonce field not found in protocol-state\n", .{});
        return false;
    }

    // Determine which epoch this nonce belongs to via `cardano-cli query tip`.
    // cardano-node's current epoch is the authoritative answer for "what epoch
    // does this nonce apply to" — more accurate than trusting the caller's
    // input (which is derived from slot math and can drift at boundaries).
    var argv_tip = [_][]const u8{ cli, "query", "tip", "--testnet-magic", magic, "--socket-path", socket };
    var tip_child = compat.Child.init(&argv_tip, std.heap.page_allocator);
    tip_child.stdout_behavior = .Pipe;
    tip_child.stderr_behavior = .Ignore;
    tip_child.spawn() catch return false;
    var tip_buf: [4096]u8 = undefined;
    const tip_stdout = tip_child.stdout orelse {
        _ = tip_child.wait() catch {};
        return false;
    };
    const tip_n = tip_stdout.readAll(&tip_buf) catch {
        _ = tip_child.wait() catch {};
        return false;
    };
    const tip_result = tip_child.wait() catch return false;
    if (tip_result.exited != 0) return false;
    const tip_body = tip_buf[0..tip_n];

    const epoch_key = "\"epoch\":";
    const e_idx = std.mem.indexOf(u8, tip_body, epoch_key) orelse {
        std.debug.print("NONCE_FETCH_CLI: epoch field not found in tip\n", .{});
        return false;
    };
    var e_pos = e_idx + epoch_key.len;
    while (e_pos < tip_body.len and (tip_body[e_pos] == ' ' or tip_body[e_pos] == '\t')) : (e_pos += 1) {}
    var e_end = e_pos;
    while (e_end < tip_body.len and tip_body[e_end] >= '0' and tip_body[e_end] <= '9') : (e_end += 1) {}
    if (e_end == e_pos) return false;
    const cli_epoch = std.fmt.parseInt(u64, tip_body[e_pos..e_end], 10) catch return false;

    // Update state with cardano-node's authoritative view, but never regress
    // to an older epoch — the monotonic writer refuses incoming_epoch <
    // current epoch (the "briefly 1295 then back to 1294" oscillation).
    if (cli_epoch != requested_epoch) {
        std.debug.print("NONCE_FETCH_CLI: epoch_mismatch caller_requested={d} cardano_node_epoch={d}\n", .{
            requested_epoch, cli_epoch,
        });
    }
    if (!updateStateMonotonic(state, cli_epoch, &nonce, "cardano_cli")) return false;

    std.debug.print("NONCE_FETCH: success epoch={d} nonce={x} source=cardano_cli\n", .{
        state.nonce_epoch, &state.epoch_nonce,
    });
    return true;
}

/// Koios path — retains the original behavior, factored out from the
/// public fetchEpochNonce so the cli fallback can be tried independently.
fn fetchEpochNonceFromKoios(state: *NonceState, epoch: u64, net: []const u8) bool {
    // Circuit breaker: skip fetch while cooldown is active.
    if (breakerShouldSkip()) return false;

    // Build Koios URL based on network
    var url_buf: [256]u8 = undefined;
    const base = if (std.mem.eql(u8, net, "preview"))
        "https://preview.koios.rest"
    else if (std.mem.eql(u8, net, "preprod"))
        "https://preprod.koios.rest"
    else
        "https://api.koios.rest"; // mainnet

    const url = std.fmt.bufPrint(&url_buf, "{s}/api/v1/epoch_params?_epoch_no={d}", .{ base, epoch }) catch {
        breakerOnFailure();
        return false;
    };

    // Shell out to curl — minimal, reliable, available on all Linux hosts
    var argv_buf: [3][]const u8 = undefined;
    argv_buf[0] = "curl";
    argv_buf[1] = "-sf";
    argv_buf[2] = url;

    var child = compat.Child.init(&argv_buf, std.heap.page_allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        std.debug.print("NONCE_FETCH: curl spawn failed epoch={d}\n", .{epoch});
        breakerOnFailure();
        return false;
    };

    // Read stdout (max 4KB — Koios response is ~2KB)
    var response_buf: [4096]u8 = undefined;
    const stdout_file = child.stdout orelse {
        _ = child.wait() catch {};
        breakerOnFailure();
        return false;
    };
    const n = stdout_file.readAll(&response_buf) catch {
        _ = child.wait() catch {};
        breakerOnFailure();
        return false;
    };
    const result = child.wait() catch {
        breakerOnFailure();
        return false;
    };
    if (result.exited != 0 or n == 0) {
        std.debug.print("NONCE_FETCH: curl failed epoch={d} exit={d} bytes={d}\n", .{ epoch, result.exited, n });
        breakerOnFailure();
        return false;
    }

    const response = response_buf[0..n];

    // Parse "nonce":"<64hex>" from JSON response
    const nonce_key = "\"nonce\":\"";
    const idx = std.mem.indexOf(u8, response, nonce_key) orelse {
        std.debug.print("NONCE_FETCH: no nonce field in response epoch={d}\n", .{epoch});
        breakerOnFailure();
        return false;
    };
    const start = idx + nonce_key.len;
    if (start + 64 > response.len) {
        breakerOnFailure();
        return false;
    }

    var nonce: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&nonce, response[start .. start + 64]) catch {
        std.debug.print("NONCE_FETCH: bad hex in response epoch={d}\n", .{epoch});
        breakerOnFailure();
        return false;
    };

    // Monotonic write: refuses regression to older epoch (the bug where
    // local slot math says N while state already holds N+1 from cli, then
    // a Koios fetch for epoch N would otherwise overwrite the newer state).
    if (!updateStateMonotonic(state, epoch, &nonce, "koios")) {
        breakerOnSuccess(); // not a Koios failure; just refused regression
        return false;
    }

    std.debug.print("NONCE_FETCH: success epoch={d} nonce={x} source=koios\n", .{
        epoch, &state.epoch_nonce,
    });
    breakerOnSuccess();
    return true;
}

// ── Tests ──────────────────────────────────────────────────────────

test "processBlockVrf accumulates within 80% and stops" {
    var state = NonceState{};
    const vrf_out = [_]u8{0xAA} ** 64;

    // Block at slot 100 of epoch 0, epoch_length=1000 → within 80% (cutoff=800)
    processBlockVrf(&state, 0, 100, 1000, vrf_out);
    try std.testing.expect(state.accumulator_count == 1);
    try std.testing.expect(!state.candidate_ready);

    // Block at slot 850 → past 80%, should mark candidate ready
    processBlockVrf(&state, 0, 850, 1000, vrf_out);
    try std.testing.expect(state.accumulator_count == 1); // not incremented
    try std.testing.expect(state.candidate_ready);
}

test "epoch transition evolves nonce" {
    var state = NonceState{};
    state.epoch_nonce = [_]u8{0x11} ** 32;
    state.epoch_nonce_valid = true;
    state.nonce_epoch = 0;

    const vrf_out = [_]u8{0xBB} ** 64;

    // Accumulate in epoch 1
    processBlockVrf(&state, 1, 100, 1000, vrf_out);
    try std.testing.expect(state.accumulator_count == 1);

    // Cross to epoch 2 → should finalize
    processBlockVrf(&state, 2, 50, 1000, [_]u8{0xCC} ** 64);
    try std.testing.expect(state.epoch_nonce_valid);
    try std.testing.expect(state.nonce_epoch == 2); // evolved for epoch 2
    try std.testing.expect(state.accumulator_epoch == 2);
}

test "saveState and loadState roundtrip" {
    const path = "/tmp/tsunagi-nonce-test.json";

    var state = NonceState{};
    state.epoch_nonce = [_]u8{0x42} ** 32;
    state.epoch_nonce_valid = true;
    state.nonce_epoch = 1265;
    state.accumulator_epoch = 1265;
    state.accumulator_count = 500;

    saveState(&state, path);

    var loaded = NonceState{};
    const ok = loadState(&loaded, path);
    try std.testing.expect(ok);
    try std.testing.expect(loaded.nonce_epoch == 1265);
    try std.testing.expect(loaded.epoch_nonce_valid);
    try std.testing.expectEqualSlices(u8, &state.epoch_nonce, &loaded.epoch_nonce);

    // Cleanup
    compat.fs.cwd().deleteFile(path) catch {};
}
