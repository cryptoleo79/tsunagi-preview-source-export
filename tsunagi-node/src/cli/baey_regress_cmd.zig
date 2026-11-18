const std = @import("std");
const compat = @import("compat");
const Blake2b256 = std.crypto.hash.blake2.Blake2b256;

// BAeY regression harness constants (must match follower.zig)
const RELAY_COUNT: usize = 5;
const SCORE_CAP: f64 = 50.0;
const PEER_PENALTY_COOLDOWN_S: i64 = 30;
const PENALTY_RATE_WINDOW_S: i64 = 10;
const PENALTY_TYPE_COUNT: usize = 8;

// No-thrash invariant
const MAX_SWITCHES_PER_WINDOW: usize = 20;
const THRASH_WINDOW_SIZE: usize = 100;

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

const EventType = enum {
    connect_fail,
    handshake_fail,
    keepalive_timeout,
    stream_error,
    cbor_error,
    block_ok,
    probe_switch,
    density_violation,
    authority_fail,
};

// PeerScore (mirrors follower.zig, stack-allocated, no allocations)
const PeerScore = struct {
    alpha: [RELAY_COUNT]f64,
    beta_val: [RELAY_COUNT]f64,
    sample: [RELAY_COUNT]f64,
    selected: [RELAY_COUNT]u64,
    rng: std.Random.DefaultPrng,
    peer_cooldown_until: [RELAY_COUNT]i64,
    last_penalty_unix: [RELAY_COUNT][PENALTY_TYPE_COUNT]i64,
};

fn initPeerScore(seed: u64) PeerScore {
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
    return score;
}

fn penalizePeer(score: *PeerScore, idx: usize, amount: f64) void {
    score.beta_val[idx] = @min(score.beta_val[idx] + amount, SCORE_CAP);
}

fn rewardPeer(score: *PeerScore, idx: usize, amount: f64) void {
    score.alpha[idx] = @min(score.alpha[idx] + amount, SCORE_CAP);
}

fn penalizePeerRateLimited(score: *PeerScore, idx: usize, amount: f64, ptype: PenaltyType, now: i64) bool {
    const ti = @intFromEnum(ptype);
    if (now - score.last_penalty_unix[idx][ti] < PENALTY_RATE_WINDOW_S) return false;
    score.last_penalty_unix[idx][ti] = now;
    penalizePeer(score, idx, amount);
    switch (ptype) {
        .connect_fail, .handshake_fail, .keepalive_timeout => {
            score.peer_cooldown_until[idx] = now + PEER_PENALTY_COOLDOWN_S;
        },
        else => {},
    }
    return true;
}

fn sampleNormal(rng: *std.Random.DefaultPrng) f64 {
    const rand_a = rng.random().float(f64);
    const rand_b = rng.random().float(f64);
    const r = @sqrt(-2.0 * @log(if (rand_a < 1e-300) 1e-300 else rand_a));
    return r * @cos(2.0 * std.math.pi * rand_b);
}

fn sampleGamma(rng: *std.Random.DefaultPrng, shape: f64) f64 {
    if (shape < 0.01) return 0.001;
    if (shape < 1.0) {
        const g = sampleGamma(rng, shape + 1.0);
        const u = rng.random().float(f64);
        const clamped = if (u < 1e-300) 1e-300 else u;
        return g * std.math.pow(f64, clamped, 1.0 / shape);
    }
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

fn pickRelay(score: *PeerScore, now: i64) usize {
    var best_idx: usize = 0;
    var best_sample: f64 = -1.0;
    var best_noncooldown_idx: usize = 0;
    var best_noncooldown_sample: f64 = -1.0;
    var all_in_cooldown: bool = true;

    for (0..RELAY_COUNT) |i| {
        const s = sampleBeta(&score.rng, score.alpha[i], score.beta_val[i]);
        score.sample[i] = s;
        if (s > best_sample) {
            best_sample = s;
            best_idx = i;
        }
        if (score.peer_cooldown_until[i] <= now) {
            all_in_cooldown = false;
            if (s > best_noncooldown_sample) {
                best_noncooldown_sample = s;
                best_noncooldown_idx = i;
            }
        }
    }

    const selected_idx = if (all_in_cooldown) best_idx else best_noncooldown_idx;
    score.selected[selected_idx] += 1;
    return selected_idx;
}

// Generate synthetic events deterministically from seed
const SyntheticEvent = struct {
    offset_s: i64,
    peer_idx: usize,
    event_type: EventType,
};

fn generateSyntheticEvents(seed: u64, buf: []SyntheticEvent) usize {
    const NUM_EVENTS: usize = 50;
    const count = @min(NUM_EVENTS, buf.len);

    for (0..count) |i| {
        // Deterministic: hash(seed ++ event_idx) for type, hash(seed ++ event_idx + 1) for peer
        var input: [16]u8 = undefined;
        std.mem.writeInt(u64, input[0..8], seed, .little);
        std.mem.writeInt(u64, input[8..16], @as(u64, i), .little);
        var h1: [32]u8 = undefined;
        Blake2b256.hash(&input, &h1, .{});

        std.mem.writeInt(u64, input[8..16], @as(u64, i) +% 0x100, .little);
        var h2: [32]u8 = undefined;
        Blake2b256.hash(&input, &h2, .{});

        const event_types = [_]EventType{
            .connect_fail,
            .handshake_fail,
            .keepalive_timeout,
            .stream_error,
            .cbor_error,
            .block_ok,
            .probe_switch,
            .density_violation,
            .authority_fail,
        };

        buf[i] = .{
            .offset_s = @intCast(i * 10), // 10 seconds apart (monotonic)
            .peer_idx = @as(usize, h2[0]) % RELAY_COUNT,
            .event_type = event_types[@as(usize, h1[0]) % event_types.len],
        };
    }
    return count;
}

pub fn run(alloc: std.mem.Allocator, args_it: anytype) u8 {
    var seed: u64 = 1;
    var init_baseline = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--seed")) {
            const val = args_it.next() orelse {
                std.debug.print("ERROR: --seed requires a value\n", .{});
                return 1;
            };
            seed = std.fmt.parseInt(u64, val, 10) catch {
                std.debug.print("ERROR: invalid --seed value: {s}\n", .{val});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "--init-baseline")) {
            init_baseline = true;
        }
    }

    std.debug.print("=== TSUNAGI BAeY Regression ===\n\n", .{});
    std.debug.print("  seed: {d}\n", .{seed});

    // Generate synthetic events
    var events_buf: [50]SyntheticEvent = undefined;
    const num_events = generateSyntheticEvents(seed, &events_buf);
    const events = events_buf[0..num_events];

    std.debug.print("  events: {d} (synthetic)\n\n", .{num_events});

    // Init peer score with deterministic seed
    var score = initPeerScore(seed);

    // Running hasher + thrash detection
    var hasher = Blake2b256.init(.{});
    var last_chosen: usize = 0;
    var switch_count: usize = 0;
    var hard_fault_count: usize = 0;
    var window_switches: usize = 0;
    var thrash_detected = false;

    // Synthetic base time (not wall clock)
    const base_time: i64 = 1000000;

    for (events, 0..) |event, event_idx| {
        const now = base_time + event.offset_s;
        const idx = event.peer_idx;

        // Apply event
        switch (event.event_type) {
            .connect_fail => {
                _ = penalizePeerRateLimited(&score, idx, 1.0, .connect_fail, now);
                hard_fault_count += 1;
            },
            .handshake_fail => {
                _ = penalizePeerRateLimited(&score, idx, 1.0, .handshake_fail, now);
                hard_fault_count += 1;
            },
            .keepalive_timeout => {
                _ = penalizePeerRateLimited(&score, idx, 0.2, .keepalive_timeout, now);
                hard_fault_count += 1;
            },
            .stream_error => {
                _ = penalizePeerRateLimited(&score, idx, 0.2, .stream_error, now);
            },
            .cbor_error => {
                _ = penalizePeerRateLimited(&score, idx, 0.02, .cbor_error, now);
            },
            .block_ok => {
                rewardPeer(&score, idx, 0.02);
            },
            .probe_switch => {
                rewardPeer(&score, idx, 0.1);
            },
            .density_violation => {
                _ = penalizePeerRateLimited(&score, idx, 0.2, .density_violation, now);
            },
            .authority_fail => {
                _ = penalizePeerRateLimited(&score, idx, 0.5, .authority_fail, now);
            },
        }

        // Pick relay after event
        const chosen = pickRelay(&score, now);

        // Track switches
        if (event_idx > 0 and chosen != last_chosen) {
            switch_count += 1;
            window_switches += 1;
        }
        last_chosen = chosen;

        // Check thrash invariant per window
        if (event_idx > 0 and (event_idx + 1) % THRASH_WINDOW_SIZE == 0) {
            if (window_switches > MAX_SWITCHES_PER_WINDOW and hard_fault_count < THRASH_WINDOW_SIZE / 4) {
                thrash_detected = true;
            }
            window_switches = 0;
        }

        // Feed chosen peer index into hasher
        var chosen_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &chosen_buf, @as(u64, chosen), .little);
        hasher.update(&chosen_buf);
    }

    // Feed final state into hasher
    {
        var dbuf: [8]u8 = undefined;
        for (0..RELAY_COUNT) |i| {
            const alpha_u: u64 = @intFromFloat(score.alpha[i] * 1_000_000.0);
            std.mem.writeInt(u64, &dbuf, alpha_u, .little);
            hasher.update(&dbuf);
            const beta_u: u64 = @intFromFloat(score.beta_val[i] * 1_000_000.0);
            std.mem.writeInt(u64, &dbuf, beta_u, .little);
            hasher.update(&dbuf);
        }
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    const hex_chars = "0123456789abcdef";
    var hex: [64]u8 = undefined;
    for (0..32) |i| {
        hex[i * 2] = hex_chars[digest[i] >> 4];
        hex[i * 2 + 1] = hex_chars[digest[i] & 0xf];
    }

    std.debug.print("  computed: {s}\n", .{&hex});
    std.debug.print("  switches: {d}\n", .{switch_count});
    std.debug.print("  hard_faults: {d}\n\n", .{hard_fault_count});

    // Thrash check
    if (thrash_detected) {
        std.debug.print("=== BAeY Regression: FAIL (thrash detected) ===\n", .{});
        return 1;
    }

    // Resolve TSUNAGI_HOME
    const home = compat.getEnvVarOwned(alloc, "TSUNAGI_HOME") catch {
        if (init_baseline) {
            std.debug.print("ERROR: TSUNAGI_HOME not set (required for --init-baseline)\n", .{});
            return 1;
        }
        std.debug.print("  TSUNAGI_HOME not set — cannot compare baseline\n", .{});
        std.debug.print("  Use --init-baseline to create one\n", .{});
        return 1;
    };
    defer alloc.free(home);

    const regress_dir = std.fmt.allocPrint(alloc, "{s}/regress", .{home}) catch return 1;
    defer alloc.free(regress_dir);
    const baseline_path = std.fmt.allocPrint(alloc, "{s}/baey_baseline.json", .{regress_dir}) catch return 1;
    defer alloc.free(baseline_path);

    if (init_baseline) {
        compat.fs.cwd().makePath(regress_dir) catch |e| {
            std.debug.print("ERROR: cannot create {s}: {any}\n", .{ regress_dir, e });
            return 1;
        };
        const json = std.fmt.allocPrint(alloc, "{{\"seed\":{d},\"events\":\"synthetic\",\"blake2b256\":\"{s}\"}}\n", .{ seed, &hex }) catch return 1;
        defer alloc.free(json);
        var file = compat.fs.cwd().createFile(baseline_path, .{}) catch |e| {
            std.debug.print("ERROR: cannot write {s}: {any}\n", .{ baseline_path, e });
            return 1;
        };
        defer file.close();
        file.writeAll(json) catch return 1;
        std.debug.print("  baseline: written to {s}\n\n", .{baseline_path});
        std.debug.print("=== BAeY Regression: BASELINE CREATED ===\n", .{});
        return 0;
    }

    // Normal mode: read and compare
    var file = compat.fs.cwd().openFile(baseline_path, .{}) catch {
        std.debug.print("  baseline: not found at {s}\n", .{baseline_path});
        std.debug.print("  Run with --init-baseline to create one\n", .{});
        return 1;
    };
    defer file.close();
    var buf2: [1024]u8 = undefined;
    const len = file.readAll(&buf2) catch {
        std.debug.print("ERROR: cannot read {s}\n", .{baseline_path});
        return 1;
    };
    const content = buf2[0..len];

    const needle = "\"blake2b256\":\"";
    const start = std.mem.indexOf(u8, content, needle) orelse {
        std.debug.print("ERROR: cannot parse baseline JSON\n", .{});
        return 1;
    };
    const hash_start = start + needle.len;
    if (hash_start + 64 > content.len) {
        std.debug.print("ERROR: baseline hash too short\n", .{});
        return 1;
    }
    const expected = content[hash_start .. hash_start + 64];

    std.debug.print("  expected: {s}\n\n", .{expected});

    if (std.mem.eql(u8, &hex, expected)) {
        std.debug.print("=== BAeY Regression: PASS ===\n", .{});
        return 0;
    } else {
        std.debug.print("=== BAeY Regression: FAIL ===\n", .{});
        return 1;
    }
}
