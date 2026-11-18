/// Praos threshold computation using E34 fixed-point arithmetic.
///
/// Ports the vendored NonIntegral.hs (from cardano-ledger) to Zig so that
/// computeThreshX1e12 matches cardano-node's threshold exactly, including
/// the sigma=1.0 edge case.
///
/// Arithmetic: Fixed E34 (34 decimal digits, resolution = 10^34).
/// ln  : generalized continued fraction  (NonIntegral.ln')
/// exp : Taylor series + argument reduction (NonIntegral.exp')
/// activeSlotLog storage: floor(10^34 * ln'(1-f)) then reload
/// Final rounding: floor(T * 10^12)
///
/// Source attribution:
///   Repo: https://github.com/IntersectMBO/cardano-ledger
///   Module: libs/non-integral/src/Cardano/Ledger/NonIntegral.hs
///   License: Apache-2.0

// ───────────────────────────────────────────────────────────
//  E34 fixed-point type
// ───────────────────────────────────────────────────────────

/// Internal storage for E34 values.  i512 holds up to ~10^153,
/// sufficient for continued-fraction numerators/denominators
/// (which grow roughly as n! over ~60 convergence iterations).
const Int = i512;

/// Wider type for multiplication/division intermediates.
const WideInt = i1024;

const RESOLUTION: Int = blk: {
    var r: Int = 1;
    for (0..34) |_| r *= 10;
    break :blk r;
};

/// eps = 10^(-24).  Internal representation: 10^(34-24) = 10^10.
const EPS: Int = blk: {
    var r: Int = 1;
    for (0..10) |_| r *= 10;
    break :blk r;
};

const ZERO: Int = 0;
const ONE: Int = RESOLUTION; // 1.0 in E34

// ───────────────────────────────────────────────────────────
//  E34 arithmetic
// ───────────────────────────────────────────────────────────

fn mul(a: Int, b: Int) Int {
    const wa: WideInt = a;
    const wb: WideInt = b;
    const product = wa * wb;
    return @intCast(@divFloor(product, @as(WideInt, RESOLUTION)));
}

fn divE34(a: Int, b: Int) Int {
    const wa: WideInt = a;
    const wr: WideInt = RESOLUTION;
    const numer = wa * wr;
    return @intCast(@divFloor(numer, @as(WideInt, b)));
}

fn absVal(a: Int) Int {
    return if (a < 0) -a else a;
}

fn fromInt(n: i64) Int {
    return @as(Int, n) * RESOLUTION;
}

/// Convert u64 fraction: fromIntegral(n) / fromIntegral(d)
fn fromFrac(n: u64, d: u64) Int {
    return divE34(@as(Int, n) * RESOLUTION, @as(Int, d) * RESOLUTION);
}

/// Haskell floor :: Fixed E34 -> Integer.
/// Returns floor(val / RESOLUTION).
fn floorVal(a: Int) i64 {
    const f = @divFloor(a, RESOLUTION);
    return @intCast(f);
}

/// Haskell ceiling :: Fixed E34 -> Integer.
fn ceilingVal(a: Int) i64 {
    const f = @divFloor(a, RESOLUTION);
    const rem = a - f * RESOLUTION;
    return @intCast(if (rem != 0) f + 1 else f);
}

// ───────────────────────────────────────────────────────────
//  ipow: integer exponentiation by squaring
//  Matches NonIntegral.ipow / ipow'
// ───────────────────────────────────────────────────────────

fn ipowPos(base: Int, n_arg: i64) Int {
    if (n_arg == 0) return ONE;

    // Iterative exponentiation by squaring
    var result: Int = ONE;
    var b = base;
    var n: u64 = @intCast(n_arg);
    while (n > 0) {
        if (n & 1 == 1) {
            result = mul(result, b);
        }
        b = mul(b, b);
        n >>= 1;
    }
    return result;
}

fn ipow(base: Int, n: i64) Int {
    if (n < 0) return divE34(ONE, ipowPos(base, -n));
    return ipowPos(base, n);
}

// ───────────────────────────────────────────────────────────
//  taylorExp: Taylor series for exp(x)
//  Matches NonIntegral.taylorExp
//
//  exp(x) = 1 + x + x²/2! + x³/3! + ...
//  Terms: nextX = lastX * x / divisor
// ───────────────────────────────────────────────────────────

fn taylorExp(x: Int) Int {
    var acc: Int = ONE;
    var last_x: Int = ONE;
    var divisor: i64 = 1;
    var n: u32 = 1;
    while (n <= 1000) : (n += 1) {
        const next_x = divE34(mul(last_x, x), fromInt(divisor));
        if (absVal(next_x) < EPS) break;
        acc += next_x;
        last_x = next_x;
        divisor += 1;
    }
    return acc;
}

// ───────────────────────────────────────────────────────────
//  exp': Taylor + argument reduction + ipow
//  Matches NonIntegral.exp'
//
//  exp'(x) = ipow(taylorExp(x/n), n) where n = ceiling(x)
//  For x < 0: exp'(x) = 1 / exp'(-x)
// ───────────────────────────────────────────────────────────

fn expE34(x: Int) Int {
    if (x == ZERO) return ONE;
    if (x < ZERO) return divE34(ONE, expE34(-x));

    // scaleExp: n = ceiling(x), x_ = x / n
    const n = ceilingVal(x);
    if (n == 0) return ONE; // x in (−1, 0] but we already handled x < 0
    const x_ = divE34(x, fromInt(n));
    const te = taylorExp(x_);
    return ipow(te, n);
}

// ───────────────────────────────────────────────────────────
//  Cached exp(1)
// ───────────────────────────────────────────────────────────

var exp1_cached: ?Int = null;

fn getExp1() Int {
    if (exp1_cached) |c| return c;
    const v = expE34(ONE);
    exp1_cached = v;
    return v;
}

// ───────────────────────────────────────────────────────────
//  lncf: generalized continued fraction for ln(1+x)
//  Matches NonIntegral.lncf / cf
//
//  Coefficients:
//    as[0] = x
//    as[n>=1] = x * k^2  where k = (n+1)/2
//    bs[n] = n + 1
//
//  Recurrence:
//    aN = bn * aNm1 + an * aNm2
//    bN = bn * bNm1 + an * bNm2
//    xn = aN / bN
//  Converges when |xn - prev| < eps
// ───────────────────────────────────────────────────────────

fn lncf(x: Int) Int {
    const max_n: u32 = 1000;
    var a_nm2: Int = ONE; // initial aNm2 = 1
    var b_nm2: Int = ZERO; // initial bNm2 = 0
    var a_nm1: Int = ZERO; // initial aNm1 = 0
    var b_nm1: Int = ONE; // initial bNm1 = 1
    var last_xn: ?Int = null;

    var n: u32 = 0;
    while (n <= max_n) : (n += 1) {
        // Compute an
        const an: Int = if (n == 0)
            x
        else blk: {
            const k: i64 = @intCast((@as(u32, n) + 1) / 2);
            break :blk mul(x, fromInt(k * k));
        };

        // Compute bn = n + 1
        const bn: Int = fromInt(@as(i64, n) + 1);

        // Recurrence
        const a_n = mul(bn, a_nm1) + mul(an, a_nm2);
        const b_n = mul(bn, b_nm1) + mul(an, b_nm2);
        const xn = divE34(a_n, b_n);

        // Convergence check
        if (last_xn) |lx| {
            const diff = absVal(xn - lx);
            if (diff < EPS) return xn;
        }

        last_xn = xn;
        a_nm2 = a_nm1;
        b_nm2 = b_nm1;
        a_nm1 = a_n;
        b_nm1 = b_n;
    }

    // maxN reached — return last computed value
    return divE34(a_nm1, b_nm1);
}

// ───────────────────────────────────────────────────────────
//  bound / contract / findE: locate n s.t. e^n <= x < e^(n+1)
//  Matches NonIntegral.bound, contract, findE
// ───────────────────────────────────────────────────────────

fn bound(factor: Int, x: Int, x_lo_init: Int, x_hi_init: Int, l_init: i64, u_init: i64) struct { l: i64, u: i64 } {
    var x_lo = x_lo_init;
    var x_hi = x_hi_init;
    var l = l_init;
    var u = u_init;

    while (true) {
        if (x_lo <= x and x <= x_hi) return .{ .l = l, .u = u };
        x_lo = mul(x_lo, x_lo);
        x_hi = mul(x_hi, x_hi);
        l *= 2;
        u *= 2;
    }

    _ = factor;
    unreachable;
}

fn contract(factor: Int, x: Int, l_init: i64, u_init: i64) i64 {
    var l = l_init;
    var u = u_init;

    while (l + 1 != u) {
        const mid = l + @divFloor(u - l, @as(i64, 2));
        const x_prime = ipow(factor, mid);
        if (x < x_prime) {
            u = mid;
        } else {
            l = mid;
        }
    }
    return l;
}

fn findE(e: Int, x: Int) i64 {
    const inv_e = divE34(ONE, e);
    const b = bound(e, x, inv_e, e, -1, 1);
    return contract(e, x, b.l, b.u);
}

// ───────────────────────────────────────────────────────────
//  splitLn / ln': natural logarithm
//  Matches NonIntegral.splitLn, ln'
//
//  splitLn(x) = (n, x') where:
//    n = findE(e, x)
//    x' = x / e^n - 1
//
//  ln'(x) = n + lncf(x')
// ───────────────────────────────────────────────────────────

fn splitLn(x: Int) struct { n: i64, x_prime: Int } {
    const e = getExp1();
    const n = findE(e, x);
    const en = ipow(e, n);
    const x_prime = divE34(x, en) - ONE;
    return .{ .n = n, .x_prime = x_prime };
}

fn lnE34(x: Int) Int {
    const sp = splitLn(x);
    return fromInt(sp.n) + lncf(sp.x_prime);
}

// ───────────────────────────────────────────────────────────
//  Public API
// ───────────────────────────────────────────────────────────

/// Compute Praos threshold using E34 fixed-point, matching cardano-node exactly.
///
/// Replicates:
///   f     = asc_x1e6 / 1e6
///   sigma = stake_x1e9 / 1e9
///   logRaw    = ln'(1 - f)
///   logStored = floor(fpPrecision * logRaw)   -- activeSlotLog storage
///   c         = fromIntegral logStored / fpPrecision
///   t         = 1 - exp'(sigma * c)
///   result    = max(0, floor(t * 1e12))
pub fn computeThresholdX1e12(stake_fraction_x1e9: u64, asc_x1e6: u64) u64 {
    if (stake_fraction_x1e9 == 0 or asc_x1e6 == 0) return 0;
    if (asc_x1e6 >= 1_000_000) return 1_000_000_000_000;

    // f = asc_x1e6 / 1e6  (E34)
    const f = fromFrac(asc_x1e6, 1_000_000);

    // sigma = stake_x1e9 / 1e9  (E34)
    const sigma = fromFrac(stake_fraction_x1e9, 1_000_000_000);

    // logRaw = ln'(1 - f)
    const log_raw = lnE34(ONE - f);

    // logStored = floor(fpPrecision * logRaw)  as Integer
    // fpPrecision = 10^34 as E34, so fpPrecision * logRaw (E34 mul)
    //   = (RESOLUTION * logRaw) / RESOLUTION = logRaw.
    // BUT in Haskell:  floor(fpPrecision * logRaw) where both are FixedPoint.
    // fpPrecision in E34 internal = 10^34 * 10^34 = 10^68.
    // E34 mul: (10^68 * logRaw_int) / 10^34 = 10^34 * logRaw_int.
    // floor of that: divFloor(10^34 * logRaw_int, 10^34) = logRaw_int.
    // So logStored = logRaw_int = logRaw (the raw internal integer).
    const log_stored: Int = log_raw; // this IS the integer logRaw_int

    // c = fromIntegral logStored / fpPrecision  (E34)
    // fromIntegral logStored = logStored * RESOLUTION (as E34)
    // fpPrecision as E34 internal = RESOLUTION * RESOLUTION
    // E34 div: (fromIntegral_logStored * RESOLUTION) / fpPrecision_int
    //        = (logStored * RESOLUTION * RESOLUTION) / (RESOLUTION * RESOLUTION)
    //        = logStored
    // So c_int = logStored = logRaw_int.
    const c: Int = log_stored;

    // t = 1 - exp'(sigma * c)
    const sigma_c = mul(sigma, c);
    const exp_val = expE34(sigma_c);
    const t = ONE - exp_val;

    // result = max(0, floor(t * 1e12))
    // t * 1e12 in E34: mul(t, fromInt(1e12))
    const t_scaled = mul(t, fromInt(1_000_000_000_000));
    const result = floorVal(t_scaled);
    if (result < 0) return 0;
    return @intCast(result);
}
