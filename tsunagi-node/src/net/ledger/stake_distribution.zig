const std = @import("std");
const compat = @import("compat");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

/// Pool-focused stake distribution tracker.
/// Tracks delegations to our pool and computes sigma from observed UTxO outputs.
/// Fixed-size, no allocator. Bounded to MAX_CREDENTIALS delegators.
///
/// Approach:
/// 1. Parse delegation certs (type 2) → record credential→pool mappings
/// 2. Parse output addresses → extract stake credential, accumulate lovelace
/// 3. sigma = our_pool_lovelace / total_staked_lovelace

const MAX_CREDENTIALS: usize = 512;

pub const CredentialEntry = struct {
    credential_hash: [28]u8 = std.mem.zeroes([28]u8),
    lovelace: u64 = 0,
    active: bool = false,
};

pub const ConsumedStake = struct {
    stake_credential: [28]u8 = std.mem.zeroes([28]u8),
    lovelace: u64 = 0,
};

/// Source of the current sigma value. Used in PRAOS_STATE log.
pub const SigmaSource = enum(u8) {
    env = 0,
    bootstrap = 1,
    ledger = 2,
};

pub const StakeDistribution = struct {
    /// Our pool's pool_id (28-byte keyhash)
    our_pool_id: [28]u8 = std.mem.zeroes([28]u8),
    our_pool_id_set: bool = false,

    /// Credentials delegated to our pool
    credentials: [MAX_CREDENTIALS]CredentialEntry = [_]CredentialEntry{.{}} ** MAX_CREDENTIALS,
    credential_count: u32 = 0,

    /// Aggregate totals (authoritative — may come from bootstrap OR live)
    our_pool_lovelace: u64 = 0,
    total_staked_lovelace: u64 = 0,

    /// Computed sigma (x1e9 fixed-point)
    sigma_x1e9: u64 = 0,

    /// Phase 4.2 hybrid source tracking
    bootstrap_ready: bool = false,
    live_tracking_ready: bool = false,
    source: SigmaSource = .env,

    /// Stats
    delegations_processed: u64 = 0,
    outputs_processed: u64 = 0,
    stake_registrations: u64 = 0,
    stake_deregistrations: u64 = 0,
    last_update_slot: u64 = 0,
    sigma_updates: u64 = 0,

    /// Set our pool ID from hex string
    pub fn setPoolId(self: *StakeDistribution, pool_id_hex: []const u8) void {
        if (pool_id_hex.len != 56) return;
        _ = std.fmt.hexToBytes(&self.our_pool_id, pool_id_hex) catch return;
        self.our_pool_id_set = true;
    }

    /// Process a delegation certificate: credential delegates to pool_id.
    /// If pool_id matches ours, track the credential.
    /// If credential was ours but now delegates elsewhere, remove it.
    pub fn processDelegation(self: *StakeDistribution, credential_hash: [28]u8, pool_id: [28]u8) void {
        self.delegations_processed += 1;
        self.live_tracking_ready = true;
        const is_ours = self.our_pool_id_set and std.mem.eql(u8, &pool_id, &self.our_pool_id);

        // Check if credential already tracked
        for (&self.credentials) |*entry| {
            if (entry.active and std.mem.eql(u8, &entry.credential_hash, &credential_hash)) {
                if (!is_ours) {
                    // Delegated away from us — remove
                    entry.active = false;
                    self.credential_count -|= 1;
                    self.our_pool_lovelace -|= entry.lovelace;
                    std.debug.print("STAKE_DELEGATION_REMOVED: credential={x} lovelace={d}\n", .{
                        credential_hash[0..8], entry.lovelace,
                    });
                }
                return;
            }
        }

        // New delegation to our pool
        if (is_ours) {
            // Find empty slot
            for (&self.credentials) |*entry| {
                if (!entry.active) {
                    entry.credential_hash = credential_hash;
                    entry.lovelace = 0;
                    entry.active = true;
                    self.credential_count += 1;
                    std.debug.print("STAKE_DELEGATION_ADDED: credential={x} pool=ours count={d}\n", .{
                        credential_hash[0..8], self.credential_count,
                    });
                    return;
                }
            }
            std.debug.print("STAKE_DELEGATION_OVERFLOW: credential_count={d} max={d}\n", .{
                self.credential_count, MAX_CREDENTIALS,
            });
        }
    }

    /// Process a stake registration (cert type 0). Minimal counter-based
    /// tracking — full HashMap-backed set is a future phase.
    pub fn processStakeRegistration(self: *StakeDistribution) void {
        self.stake_registrations += 1;
        self.live_tracking_ready = true;
    }

    /// Process a stake deregistration (cert type 1). If the credential was
    /// one of ours, remove it from the tracker.
    pub fn processStakeDeregistration(self: *StakeDistribution, credential_hash: [28]u8) void {
        self.stake_deregistrations += 1;
        self.live_tracking_ready = true;
        // Scrub from our delegator array if present
        for (&self.credentials) |*entry| {
            if (entry.active and std.mem.eql(u8, &entry.credential_hash, &credential_hash)) {
                entry.active = false;
                self.credential_count -|= 1;
                self.our_pool_lovelace -|= entry.lovelace;
                std.debug.print("STAKE_DEREGISTRATION: credential={x} freed={d}\n", .{
                    credential_hash[0..8], entry.lovelace,
                });
                return;
            }
        }
    }

    /// Process an output: if the stake credential is delegated to us, update its balance.
    /// Also accumulates total_staked_lovelace for all staked outputs.
    /// addr_bytes: raw Shelley address bytes (57+ bytes for base addresses)
    /// lovelace: output value
    pub fn processOutput(self: *StakeDistribution, addr_bytes: []const u8, lovelace: u64) void {
        // Shelley base addresses: header byte type 0-3, length >= 57
        if (addr_bytes.len < 57) return;
        const addr_type = addr_bytes[0] >> 4;
        if (addr_type > 3) return; // Not a base address (no stake credential)

        self.outputs_processed += 1;

        // Stake credential is bytes 29..57 (28 bytes)
        var stake_cred: [28]u8 = undefined;
        @memcpy(&stake_cred, addr_bytes[29..57]);

        // All staked outputs contribute to total
        self.total_staked_lovelace +|= lovelace;

        // Check if this credential is delegated to our pool
        for (&self.credentials) |*entry| {
            if (entry.active and std.mem.eql(u8, &entry.credential_hash, &stake_cred)) {
                entry.lovelace +|= lovelace;
                self.our_pool_lovelace +|= lovelace;
                return;
            }
        }
    }

    /// Process a consumed input: subtract lovelace for the stake credential.
    /// addr_bytes: raw Shelley address bytes of the consumed UTxO
    /// lovelace: consumed amount
    pub fn processInput(self: *StakeDistribution, addr_bytes: []const u8, lovelace: u64) void {
        if (addr_bytes.len < 57) return;
        const addr_type = addr_bytes[0] >> 4;
        if (addr_type > 3) return;

        var stake_cred: [28]u8 = undefined;
        @memcpy(&stake_cred, addr_bytes[29..57]);

        // Subtract from total staked
        self.total_staked_lovelace -|= lovelace;

        // Subtract from our pool if this credential is ours
        for (&self.credentials) |*entry| {
            if (entry.active and std.mem.eql(u8, &entry.credential_hash, &stake_cred)) {
                entry.lovelace -|= lovelace;
                self.our_pool_lovelace -|= lovelace;
                return;
            }
        }
    }

    /// Recompute sigma from accumulated stake.
    pub fn recomputeSigma(self: *StakeDistribution, slot: u64) void {
        self.last_update_slot = slot;
        if (self.total_staked_lovelace == 0 or self.our_pool_lovelace == 0) {
            self.sigma_x1e9 = 0;
            return;
        }
        // sigma_x1e9 = (our_pool_lovelace * 1e9) / total_staked_lovelace
        const num: u128 = @as(u128, self.our_pool_lovelace) * 1_000_000_000;
        const sigma: u64 = @intCast(@min(num / @as(u128, self.total_staked_lovelace), 1_000_000_000));
        if (sigma != self.sigma_x1e9) {
            self.sigma_updates += 1;
            std.debug.print("STAKE_STATE: total_stake={d} pool_stake={d} sigma={d}e-9 slot={d}\n", .{
                self.total_staked_lovelace, self.our_pool_lovelace, sigma, slot,
            });
        }
        self.sigma_x1e9 = sigma;
        // Source-label correctness: once recomputeSigma has produced any
        // non-zero sigma, the displayed value is no longer the env-configured
        // stake_fraction. Promote .env → .bootstrap immediately so PRAOS_STATE
        // logs accurately reflect that σ is live-computed (or Koios-seeded),
        // not env-derived. tryPromoteToLedger handles the further transition
        // to .ledger once min_live_obs outputs have been processed.
        if (self.source == .env) self.source = .bootstrap;
    }

    /// Save state to JSON file.
    pub fn saveState(self: *const StakeDistribution, path: []const u8) void {
        var buf: [512]u8 = undefined;
        const json = std.fmt.bufPrint(&buf,
            \\{{"sigma_x1e9":{d},"our_pool_lovelace":{d},"total_staked_lovelace":{d},"credential_count":{d},"delegations_processed":{d},"outputs_processed":{d},"last_slot":{d},"sigma_updates":{d}}}
        , .{
            self.sigma_x1e9, self.our_pool_lovelace, self.total_staked_lovelace,
            self.credential_count, self.delegations_processed, self.outputs_processed,
            self.last_update_slot, self.sigma_updates,
        }) catch return;
        var f = compat.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
        defer f.close();
        f.writeAll(json) catch {};
    }

    /// Load state from JSON file.
    pub fn loadState(self: *StakeDistribution, path: []const u8) bool {
        var f = compat.fs.cwd().openFile(path, .{}) catch return false;
        defer f.close();
        var buf: [512]u8 = undefined;
        const n = f.readAll(&buf) catch return false;
        const content = buf[0..n];

        self.sigma_x1e9 = parseU64(content, "\"sigma_x1e9\":") orelse return false;
        self.our_pool_lovelace = parseU64(content, "\"our_pool_lovelace\":") orelse 0;
        self.total_staked_lovelace = parseU64(content, "\"total_staked_lovelace\":") orelse 0;
        self.credential_count = @intCast(parseU64(content, "\"credential_count\":") orelse 0);
        self.delegations_processed = parseU64(content, "\"delegations_processed\":") orelse 0;
        self.outputs_processed = parseU64(content, "\"outputs_processed\":") orelse 0;
        self.last_update_slot = parseU64(content, "\"last_slot\":") orelse 0;
        self.sigma_updates = parseU64(content, "\"sigma_updates\":") orelse 0;

        std.debug.print("STAKE_DIST_LOADED: path={s} sigma_x1e9={d} pool_stake={d} total_stake={d}\n", .{
            path, self.sigma_x1e9, self.our_pool_lovelace, self.total_staked_lovelace,
        });
        return true;
    }
};

fn parseU64(content: []const u8, key: []const u8) ?u64 {
    const idx = std.mem.indexOf(u8, content, key) orelse return null;
    const start = idx + key.len;
    var end = start;
    while (end < content.len and content[end] >= '0' and content[end] <= '9') : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(u64, content[start..end], 10) catch null;
}

// ── Phase 4.2: Koios bootstrap (cold-start ledger sigma) ───────────

/// Shell out to curl. Returns response bytes on 2xx, null on error/non-2xx.
fn curlFetch(alloc: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    var response_buf: [16384]u8 = undefined;
    const out = compat.runCaptureStdout(alloc, argv, &response_buf) orelse return null;
    return alloc.dupe(u8, out) catch null;
}

fn koiosBase(net: []const u8) []const u8 {
    if (std.mem.eql(u8, net, "preview")) return "https://preview.koios.rest";
    if (std.mem.eql(u8, net, "preprod")) return "https://preprod.koios.rest";
    return "https://api.koios.rest";
}

/// Query pool active_stake via POST /api/v1/pool_info.
/// Returns lovelace value or null on failure.
fn fetchPoolActiveStake(alloc: std.mem.Allocator, net: []const u8, pool_bech32: []const u8) ?u64 {
    const base = koiosBase(net);
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/api/v1/pool_info", .{base}) catch return null;
    var body_buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{{\"_pool_bech32_ids\":[\"{s}\"]}}", .{pool_bech32}) catch return null;

    const argv = [_][]const u8{ "curl", "-sf", "-X", "POST", "-H", "Content-Type: application/json", "--data-binary", body, url };
    const resp = curlFetch(alloc, &argv) orelse return null;
    defer alloc.free(resp);

    // Find "active_stake":<number>
    const key = "\"active_stake\":\"";
    if (std.mem.indexOf(u8, resp, key)) |idx| {
        const start = idx + key.len;
        var end = start;
        while (end < resp.len and resp[end] >= '0' and resp[end] <= '9') : (end += 1) {}
        if (end > start) {
            return std.fmt.parseInt(u64, resp[start..end], 10) catch null;
        }
    }
    // Alternative: "active_stake":123 (no quotes)
    const key2 = "\"active_stake\":";
    if (std.mem.indexOf(u8, resp, key2)) |idx| {
        const start = idx + key2.len;
        var end = start;
        while (end < resp.len and resp[end] >= '0' and resp[end] <= '9') : (end += 1) {}
        if (end > start) {
            return std.fmt.parseInt(u64, resp[start..end], 10) catch null;
        }
    }
    return null;
}

/// Query network total active_stake via GET /api/v1/epoch_info?_epoch_no=N.
fn fetchEpochActiveStake(alloc: std.mem.Allocator, net: []const u8, epoch: u64) ?u64 {
    const base = koiosBase(net);
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/api/v1/epoch_info?_epoch_no={d}", .{ base, epoch }) catch return null;
    const argv = [_][]const u8{ "curl", "-sf", url };
    const resp = curlFetch(alloc, &argv) orelse return null;
    defer alloc.free(resp);
    const key = "\"active_stake\":\"";
    if (std.mem.indexOf(u8, resp, key)) |idx| {
        const start = idx + key.len;
        var end = start;
        while (end < resp.len and resp[end] >= '0' and resp[end] <= '9') : (end += 1) {}
        if (end > start) return std.fmt.parseInt(u64, resp[start..end], 10) catch null;
    }
    const key2 = "\"active_stake\":";
    if (std.mem.indexOf(u8, resp, key2)) |idx| {
        const start = idx + key2.len;
        var end = start;
        while (end < resp.len and resp[end] >= '0' and resp[end] <= '9') : (end += 1) {}
        if (end > start) return std.fmt.parseInt(u64, resp[start..end], 10) catch null;
    }
    return null;
}

/// One bootstrap attempt. Returns true if both stakes were fetched and
/// state.sigma_x1e9 was populated.
pub fn bootstrapFromKoios(
    alloc: std.mem.Allocator,
    state: *StakeDistribution,
    net: []const u8,
    pool_bech32: []const u8,
    epoch: u64,
) bool {
    const pool_active = fetchPoolActiveStake(alloc, net, pool_bech32) orelse {
        std.debug.print("STAKE_BOOTSTRAP_FAILED: pool_info fetch error pool={s}\n", .{pool_bech32});
        return false;
    };
    const total_active = fetchEpochActiveStake(alloc, net, epoch) orelse {
        std.debug.print("STAKE_BOOTSTRAP_FAILED: epoch_info fetch error epoch={d}\n", .{epoch});
        return false;
    };
    if (pool_active == 0 or total_active == 0) {
        std.debug.print("STAKE_BOOTSTRAP_FAILED: zero values pool={d} total={d}\n", .{ pool_active, total_active });
        return false;
    }
    state.our_pool_lovelace = pool_active;
    state.total_staked_lovelace = total_active;
    const num: u128 = @as(u128, pool_active) * 1_000_000_000;
    state.sigma_x1e9 = @intCast(@min(num / @as(u128, total_active), 1_000_000_000));
    state.bootstrap_ready = true;
    // Only downgrade from ledger → bootstrap if we were lower than bootstrap.
    // Prefer ledger if live tracking is already active.
    if (state.source != .ledger) state.source = .bootstrap;
    std.debug.print("STAKE_BOOTSTRAP: pool={d} total={d} sigma_x1e9={d} epoch={d}\n", .{
        pool_active, total_active, state.sigma_x1e9, epoch,
    });
    return true;
}

/// Transition source to .ledger once live tracking has accumulated enough
/// data to be authoritative. Called from follower after block apply.
/// Criterion: live tracking is ready AND we've observed >= MIN_LIVE_OBS
/// block-apply cycles that touched stake state.
pub fn maybePromoteToLedger(state: *StakeDistribution, min_live_obs: u64) void {
    if (state.source == .ledger) return;
    if (!state.live_tracking_ready) return;
    if (state.outputs_processed < min_live_obs) return;
    state.source = .ledger;
    std.debug.print("STAKE_SOURCE_PROMOTED: env|bootstrap → ledger outputs_processed={d} credential_count={d}\n", .{
        state.outputs_processed, state.credential_count,
    });
}

/// Background bootstrap thread. Retries every 60s for up to 20 attempts
/// (20 min), then exits silently. Never blocks startup.
///
/// On success: updates `state` + writes sigma to producer_ctx and flips
/// `ledger_sigma_valid = true`. Also saves to disk if TSUNAGI_HOME is set.
const BootstrapCfg = struct {
    alloc: std.mem.Allocator,
    state: *StakeDistribution,
    producer_ledger_sigma_x1e9: *u64,
    producer_ledger_sigma_valid: *bool,
    producer_ledger_sigma_source_kind: *u8,
    net: []u8,
    pool_bech32: []u8,
    epoch_fn: *const fn () u64, // resolved at call time
};

fn bootstrapThread(cfg: *BootstrapCfg) void {
    var attempt: u32 = 0;
    while (attempt < 20) {
        attempt += 1;
        // Short initial delay so primary follower has a chance to print its first lines
        const initial_wait: u64 = if (attempt == 1) 5 else 60;
        compat.sleep(initial_wait * std.time.ns_per_s);
        const epoch = cfg.epoch_fn();
        if (epoch == 0) continue; // no epoch yet (pre-Shelley or clock not set)
        if (bootstrapFromKoios(cfg.alloc, cfg.state, cfg.net, cfg.pool_bech32, epoch)) {
            cfg.producer_ledger_sigma_x1e9.* = cfg.state.sigma_x1e9;
            cfg.producer_ledger_sigma_valid.* = true;
            cfg.producer_ledger_sigma_source_kind.* = @intFromEnum(cfg.state.source);
            // Persist so restarts don't re-query
            if (compat.getenv("TSUNAGI_HOME")) |home| {
                var path_buf: [512]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buf, "{s}/stake_dist.json", .{home}) catch "";
                if (path.len > 0) cfg.state.saveState(path);
            }
            std.debug.print("STAKE_BOOTSTRAP_DONE: attempts={d} sigma_x1e9={d}\n", .{
                attempt, cfg.state.sigma_x1e9,
            });
            return;
        }
        std.debug.print("STAKE_BOOTSTRAP_RETRY: attempt={d}/20 next_in=60s\n", .{attempt});
    }
    std.debug.print("STAKE_EMPTY_FALLBACK: bootstrap gave up after 20 attempts, env sigma remains\n", .{});
}

/// Spawn the bootstrap thread (detached). Caller owns lifetime of state,
/// producer ledger pointers, and the strings we copy into cfg.
pub fn spawnBootstrap(
    alloc: std.mem.Allocator,
    state: *StakeDistribution,
    producer_ledger_sigma_x1e9: *u64,
    producer_ledger_sigma_valid: *bool,
    producer_ledger_sigma_source_kind: *u8,
    net: []const u8,
    pool_bech32: []const u8,
    epoch_fn: *const fn () u64,
) bool {
    if (pool_bech32.len == 0) {
        std.debug.print("STAKE_BOOTSTRAP_SKIP: no pool_bech32 provided\n", .{});
        return false;
    }
    const net_copy = alloc.dupe(u8, net) catch return false;
    const pool_copy = alloc.dupe(u8, pool_bech32) catch {
        alloc.free(net_copy);
        return false;
    };
    const cfg = alloc.create(BootstrapCfg) catch {
        alloc.free(net_copy);
        alloc.free(pool_copy);
        return false;
    };
    cfg.* = .{
        .alloc = alloc,
        .state = state,
        .producer_ledger_sigma_x1e9 = producer_ledger_sigma_x1e9,
        .producer_ledger_sigma_valid = producer_ledger_sigma_valid,
        .producer_ledger_sigma_source_kind = producer_ledger_sigma_source_kind,
        .net = net_copy,
        .pool_bech32 = pool_copy,
        .epoch_fn = epoch_fn,
    };
    const thread = std.Thread.spawn(.{}, bootstrapThread, .{cfg}) catch {
        alloc.free(net_copy);
        alloc.free(pool_copy);
        alloc.destroy(cfg);
        return false;
    };
    thread.detach();
    std.debug.print("STAKE_BOOTSTRAP_SPAWN: net={s} pool={s}\n", .{ net, pool_bech32 });
    return true;
}

// ── Helpers for CBOR address/certificate parsing ──

/// Extract stake credential (28 bytes) from a Shelley base address.
/// Returns null if not a base address or too short.
pub fn extractStakeCredential(addr_bytes: []const u8) ?[28]u8 {
    if (addr_bytes.len < 57) return null;
    const addr_type = addr_bytes[0] >> 4;
    if (addr_type > 3) return null;
    var cred: [28]u8 = undefined;
    @memcpy(&cred, addr_bytes[29..57]);
    return cred;
}

/// Delegation certificate data: [2, [cred_type, cred_hash(28)], pool_keyhash(28)]
pub const DelegationData = struct {
    credential_hash: [28]u8,
    pool_id: [28]u8,
};

// ── Tests ──

test "sigma computation" {
    var dist = StakeDistribution{};
    dist.our_pool_lovelace = 1_009_498_000_000; // ~1M ADA
    dist.total_staked_lovelace = 1_586_000_000_000_000; // ~1.586B ADA
    dist.recomputeSigma(100);
    // Expected: ~636e-9 → sigma_x1e9 ≈ 636
    try std.testing.expect(dist.sigma_x1e9 > 600);
    try std.testing.expect(dist.sigma_x1e9 < 700);
}

test "delegation tracking" {
    var dist = StakeDistribution{};
    const our_pool = [_]u8{0xAA} ** 28;
    const other_pool = [_]u8{0xBB} ** 28;
    const cred1 = [_]u8{0x11} ** 28;
    const cred2 = [_]u8{0x22} ** 28;

    dist.our_pool_id = our_pool;
    dist.our_pool_id_set = true;

    dist.processDelegation(cred1, our_pool);
    try std.testing.expectEqual(@as(u32, 1), dist.credential_count);

    dist.processDelegation(cred2, other_pool);
    try std.testing.expectEqual(@as(u32, 1), dist.credential_count);

    // cred1 re-delegates away
    dist.processDelegation(cred1, other_pool);
    try std.testing.expectEqual(@as(u32, 0), dist.credential_count);
}

test "extractStakeCredential" {
    // Build a 57-byte base address (type 0)
    var addr: [57]u8 = undefined;
    addr[0] = 0x01; // type 0, network 1
    @memset(addr[1..29], 0xAA); // payment
    @memset(addr[29..57], 0xBB); // stake
    const cred = extractStakeCredential(&addr);
    try std.testing.expect(cred != null);
    try std.testing.expectEqual(@as(u8, 0xBB), cred.?[0]);
}
