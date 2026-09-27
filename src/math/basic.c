/*==============================================================================
 * basic.c - sign, rounding, comparison, scaling and root routines
 *------------------------------------------------------------------------------
 * Freestanding, no libc. Implements the "easy" half of <math.h>: everything
 * that can be done exactly with bit manipulation (sign/rounding/scaling) plus
 * the three roots (sqrt/hypot/cbrt). All results are faithful (< 1 ulp) and
 * honour IEEE-754 special values. No errno, no FP environment, no globals.
 *============================================================================*/

#include "math_private.h"

/* Use the target's native rounding instruction where one exists: SSE4.1
 * roundsd on x86-64 (guaranteed by the library's AVX2 requirement) and
 * f64.floor/ceil/trunc/nearest on wasm. Otherwise fall back to the bit-exact
 * integer manipulation below. */
#if defined(__wasm__) || defined(__SSE4_1__) || defined(__aarch64__)
#define ASMLIB_MATH_FAST_ROUND 1
#else
#define ASMLIB_MATH_FAST_ROUND 0
#endif

/*==============================================================================
 * static double pow2i(int k)
 *------------------------------------------------------------------------------
 * Exact 2^k, saturating outside the representable binary64 range. Used by the
 * subnormal scaling paths below.
 *
 * Parameters:
 *   k (int) - the power of two; any int value is accepted.
 * Returns:
 *   2^k exactly when representable: a normal value for -1022 <= k <= 1023, a
 *   subnormal value for -1074 <= k <= -1023, +Inf for k >= 1024 and +0.0 for
 *   k <= -1075.
 * Special cases:
 *   - k >= 1024  -> +Inf (the scaling factor overflows).
 *   - k <= -1075 -> +0.0 (below half the smallest subnormal).
 *   - k == -1074 -> smallest positive subnormal 2^-1074.
 * Accuracy / algorithm:
 *   Exact; the result is packed directly from the biased exponent field for
 *   normals, or from a lone mantissa bit for subnormals.
 *============================================================================*/
static double pow2i(int k)
{
    /* ---- saturation guard: clamp the two unrepresentable directions ---- */
    if (k >= 1024)
        return F64_INF;
    if (k <= -1075)
        return 0.0;
    /* ---- normal case: bias k and place it in the exponent field ---- */
    if (k >= -1022)
        return f64_from_bits((uint64_t)(k + 1023) << 52);   /* normal 2^k  */
    /* ---- subnormal case: a single mantissa bit, no implicit leading 1 ---- */
    return f64_from_bits(1ULL << (k + 1074));               /* subnormal 2^k */
}

/*==============================================================================
 * double ASM_MATH(fabs)(double x)
 *------------------------------------------------------------------------------
 * Absolute value of x.
 *
 * Parameters:
 *   x (double) - any finite, infinite, NaN or zero value.
 * Returns:
 *   |x|, computed by clearing the sign bit of x.
 * Special cases:
 *   - x = -0.0   -> +0.0.
 *   - x = +0.0   -> +0.0.
 *   - x = +/-Inf -> +Inf.
 *   - x = NaN    -> NaN, payload and quietness preserved.
 * Accuracy / algorithm:
 *   Exact for every input; one AND with the sign-clearing mask F64_ABS.
 *============================================================================*/
double ASM_MATH(fabs)(double x)
{
    /* ---- sign handling: mask off bit 63, leaving magnitude bits ---- */
    return f64_from_bits(f64_bits(x) & F64_ABS);
}

/*==============================================================================
 * double ASM_MATH(copysign)(double x, double y)
 *------------------------------------------------------------------------------
 * Magnitude of x carrying the sign bit of y.
 *
 * Parameters:
 *   x (double) - value supplying the magnitude; its own sign is ignored.
 *   y (double) - value supplying the sign; its magnitude is ignored.
 * Returns:
 *   +/-|x| whose sign bit is y's sign bit.
 * Special cases:
 *   - y negative (including -0.0 and -NaN) -> negative result.
 *   - y non-negative (including +0.0 and +NaN) -> non-negative result.
 *   - x = NaN -> NaN with x's payload and y's sign bit.
 * Accuracy / algorithm:
 *   Exact for all inputs; mask x to its magnitude, then OR in y's sign bit.
 *============================================================================*/
double ASM_MATH(copysign)(double x, double y)
{
    /* ---- take x's magnitude bits and y's sign bit, then combine ---- */
    return f64_from_bits((f64_bits(x) & F64_ABS) | (f64_bits(y) & F64_SIGN));
}

/*==============================================================================
 * double ASM_MATH(fmin)(double x, double y)
 *------------------------------------------------------------------------------
 * NaN-aware minimum of two doubles (IEEE 754 minNum).
 *
 * Parameters:
 *   x (double) - first operand.
 *   y (double) - second operand.
 * Returns:
 *   The numerically smaller operand; on a signed-zero tie, -0.0.
 * Special cases:
 *   - exactly one operand is NaN -> the other operand is returned.
 *   - both operands are NaN     -> NaN is propagated.
 *   - x == y (including +0.0 and -0.0) -> x when its sign bit is set, else y,
 *     so the negative zero wins the tie.
 * Accuracy / algorithm:
 *   Exact; two NaN tests plus a direct comparison, with an explicit signed-zero
 *   tie-break.
 *============================================================================*/
double ASM_MATH(fmin)(double x, double y)
{
    /* ---- NaN handling: a lone NaN is treated as missing ---- */
    if (f64_isnan(x))
        return y;
    if (f64_isnan(y))
        return x;
    /* ---- signed-zero tie-break: prefer the negative zero ---- */
    if (x == y)
        return f64_signbit(x) ? x : y;      /* both zero: pick -0.0 */
    /* ---- ordinary ordering ---- */
    return x < y ? x : y;
}

/*==============================================================================
 * double ASM_MATH(fmax)(double x, double y)
 *------------------------------------------------------------------------------
 * NaN-aware maximum of two doubles (IEEE 754 maxNum).
 *
 * Parameters:
 *   x (double) - first operand.
 *   y (double) - second operand.
 * Returns:
 *   The numerically larger operand; on a signed-zero tie, +0.0.
 * Special cases:
 *   - exactly one operand is NaN -> the other operand is returned.
 *   - both operands are NaN     -> NaN is propagated.
 *   - x == y (including +0.0 and -0.0) -> y when x's sign bit is set, else x,
 *     so the positive zero wins the tie.
 * Accuracy / algorithm:
 *   Exact; two NaN tests plus a direct comparison, with an explicit signed-zero
 *   tie-break.
 *============================================================================*/
double ASM_MATH(fmax)(double x, double y)
{
    /* ---- NaN handling: a lone NaN is treated as missing ---- */
    if (f64_isnan(x))
        return y;
    if (f64_isnan(y))
        return x;
    /* ---- signed-zero tie-break: prefer the positive zero ---- */
    if (x == y)
        return f64_signbit(x) ? y : x;      /* both zero: pick +0.0 */
    /* ---- ordinary ordering ---- */
    return x > y ? x : y;
}

/*==============================================================================
 * double ASM_MATH(fdim)(double x, double y)
 *------------------------------------------------------------------------------
 * Positive difference max(x - y, +0.0).
 *
 * Parameters:
 *   x (double) - first operand.
 *   y (double) - second operand.
 * Returns:
 *   x - y when x > y, otherwise +0.0 (never a negative zero).
 * Special cases:
 *   - either operand NaN -> quiet NaN.
 *   - x <= y (including equal, infinite operands) -> +0.0.
 *   - x = +Inf, y finite -> +Inf; x finite, y = +Inf -> +0.0.
 * Accuracy / algorithm:
 *   Exact; a single ordered subtraction, so the result cannot overflow or
 *   underflow spuriously.
 *============================================================================*/
double ASM_MATH(fdim)(double x, double y)
{
    /* ---- domain edge: any NaN poisons the result ---- */
    if (f64_isnan(x) || f64_isnan(y))
        return F64_QNAN;
    /* ---- positive part of x - y ---- */
    return x > y ? x - y : 0.0;
}

/*==============================================================================
 * double ASM_MATH(floor)(double x)
 *------------------------------------------------------------------------------
 * Largest integer not greater than x (round toward -Inf).
 *
 * Parameters:
 *   x (double) - any finite, infinite, NaN or zero value.
 * Returns:
 *   floor(x) as a double; the input itself when it is already integral,
 *   infinite or NaN.
 * Special cases:
 *   - x = +/-0.0, +/-Inf, NaN -> x unchanged (sign preserved).
 *   - -1 < x < 0             -> -1.0.
 *   - 0 <= x < 1             -> +0.0.
 * Accuracy / algorithm:
 *   Exact; mask the fractional mantissa bits, adding one unit in the last
 *   place for negatives (a carry may ripple into the exponent field).
 *============================================================================*/
double ASM_MATH(floor)(double x)
{
#if ASMLIB_MATH_FAST_ROUND
    return __builtin_floor(x);                      /* roundsd / f64.floor */
#else
    /* ---- exponent split: raw bits and unbiased exponent ---- */
    uint64_t i = f64_bits(x);                       /* raw IEEE-754 bits */
    int e = (int)((i >> 52) & 0x7ff) - 1023;        /* unbiased exponent */

    if (e >= 52)
        return x;                                   /* integral / Inf / NaN */
    /* ---- domain edge: |x| < 1 ---- */
    if (e < 0) {
        if ((i & F64_ABS) == 0)
            return x;                               /* +/-0 */
        if (i >> 63)
            return f64_from_bits(F64_SIGN | ((uint64_t)1023 << 52)); /* -1 */
        return 0.0;                                 /* (0,1) -> +0 */
    }

    /* ---- rounding split: isolate the fractional mantissa bits ---- */
    uint64_t mask = F64_MANT >> e;                  /* fractional bits */
    if ((i & mask) == 0)
        return x;                                   /* already integral */
    /* ---- reconstruction: carry toward -Inf, truncate positives ---- */
    if (i >> 63)
        i = (i & ~mask) + (mask + 1);               /* negative: away from 0 */
    else
        i &= ~mask;                                 /* positive: toward 0 */
    return f64_from_bits(i);
#endif
}

/*==============================================================================
 * double ASM_MATH(ceil)(double x)
 *------------------------------------------------------------------------------
 * Smallest integer not less than x (round toward +Inf).
 *
 * Parameters:
 *   x (double) - any finite, infinite, NaN or zero value.
 * Returns:
 *   ceil(x) as a double; the input itself when it is already integral,
 *   infinite or NaN.
 * Special cases:
 *   - x = +/-0.0, +/-Inf, NaN -> x unchanged (sign preserved).
 *   - -1 < x < 0             -> -0.0.
 *   - 0 < x < 1              -> +1.0; x = +0.0 stays +0.0.
 * Accuracy / algorithm:
 *   Exact; mask the fractional mantissa bits, adding one unit in the last
 *   place for positives (a carry may ripple into the exponent field).
 *============================================================================*/
double ASM_MATH(ceil)(double x)
{
#if ASMLIB_MATH_FAST_ROUND
    return __builtin_ceil(x);                       /* roundsd / f64.ceil */
#else
    /* ---- exponent split: raw bits and unbiased exponent ---- */
    uint64_t i = f64_bits(x);                       /* raw IEEE-754 bits */
    int e = (int)((i >> 52) & 0x7ff) - 1023;        /* unbiased exponent */

    if (e >= 52)
        return x;                                   /* integral / Inf / NaN */
    /* ---- domain edge: |x| < 1 ---- */
    if (e < 0) {
        if ((i & F64_ABS) == 0)
            return x;                               /* +/-0 */
        if (i >> 63)
            return f64_from_bits(F64_SIGN);         /* (-1,0) -> -0 */
        return f64_from_bits((uint64_t)1023 << 52); /* (1,2) -> +1 */
    }

    /* ---- rounding split: isolate the fractional mantissa bits ---- */
    uint64_t mask = F64_MANT >> e;
    if ((i & mask) == 0)
        return x;                                   /* already integral */
    /* ---- reconstruction: carry toward +Inf, truncate negatives ---- */
    if (i >> 63)
        i &= ~mask;                                 /* negative: toward 0 */
    else
        i = (i & ~mask) + (mask + 1);               /* positive: away from 0 */
    return f64_from_bits(i);
#endif
}

/*==============================================================================
 * double ASM_MATH(trunc)(double x)
 *------------------------------------------------------------------------------
 * Integer part of x (round toward zero).
 *
 * Parameters:
 *   x (double) - any finite, infinite, NaN or zero value.
 * Returns:
 *   The integer part of x as a double; the input itself when it is integral,
 *   infinite or NaN.
 * Special cases:
 *   - x = +/-0.0, +/-Inf, NaN -> x unchanged (sign preserved).
 *   - |x| < 1                -> +/-0.0 carrying x's sign.
 * Accuracy / algorithm:
 *   Exact; clears the fractional mantissa bits without any carry.
 *============================================================================*/
double ASM_MATH(trunc)(double x)
{
#if ASMLIB_MATH_FAST_ROUND
    return __builtin_trunc(x);                      /* roundsd / f64.trunc */
#else
    /* ---- exponent split: raw bits and unbiased exponent ---- */
    uint64_t i = f64_bits(x);                       /* raw IEEE-754 bits */
    int e = (int)((i >> 52) & 0x7ff) - 1023;        /* unbiased exponent */

    if (e >= 52)
        return x;                                   /* integral / Inf / NaN */
    /* ---- domain edge: |x| < 1 collapses to a signed zero ---- */
    if (e < 0)
        return f64_from_bits(i & F64_SIGN);         /* +/-0, sign preserved */
    /* ---- drop the fractional mantissa bits (always toward zero) ---- */
    return f64_from_bits(i & ~(F64_MANT >> e));
#endif
}

/*==============================================================================
 * double ASM_MATH(round)(double x)
 *------------------------------------------------------------------------------
 * Round to nearest integer, ties away from zero (the C round() rule).
 *
 * Parameters:
 *   x (double) - any finite, infinite, NaN or zero value.
 * Returns:
 *   The nearest integral double; ties (.5 exactly) go away from zero.
 * Special cases:
 *   - x = +/-0.0, +/-Inf, NaN -> x unchanged (sign preserved).
 *   - |x| < 0.5              -> +/-0.0 with x's sign.
 *   - 0.5 <= |x| < 1         -> +/-1.0.
 *   - already integral       -> x unchanged.
 * Accuracy / algorithm:
 *   Exact; compares the fractional field against the half-ulp bit weight,
 *   adding one unit in the last place when the half is reached or exceeded.
 *============================================================================*/
double ASM_MATH(round)(double x)
{
    /* ---- exponent split: raw bits and unbiased exponent ---- */
    uint64_t i = f64_bits(x);                       /* raw IEEE-754 bits */
    int e = (int)((i >> 52) & 0x7ff) - 1023;        /* unbiased exponent */

    if (e >= 52)
        return x;                                   /* integral / Inf / NaN */
    /* ---- domain edge: |x| < 1 ---- */
    if (e < 0) {
        if ((i & F64_ABS) == 0)
            return x;                               /* +/-0 */
        if (e == -1)                                /* 0.5 <= |x| < 1 */
            return f64_from_bits((i & F64_SIGN) | ((uint64_t)1023 << 52));
        return f64_from_bits(i & F64_SIGN);         /* |x| < 0.5 -> +/-0 */
    }

    /* ---- rounding split: fractional field vs the half-ulp weight ---- */
    uint64_t mask = F64_MANT >> e;                  /* fractional bits */
    uint64_t frac = i & mask;
    uint64_t half = 1ULL << (51 - e);               /* weight of 0.5 ulp */
    /* ---- tie logic: >= half rounds away from zero (symmetric) ---- */
    if (frac >= half)
        i = (i & ~mask) + (mask + 1);               /* away from zero */
    else
        i &= ~mask;
    return f64_from_bits(i);
}

/*==============================================================================
 * double ASM_MATH(rint)(double x)
 *------------------------------------------------------------------------------
 * Round to nearest integer with ties to even, independent of the FP rounding
 * mode.
 *
 * Parameters:
 *   x (double) - any finite, infinite, NaN or zero value.
 * Returns:
 *   The nearest integral double; an exact .5 tie goes to the even neighbour.
 * Special cases:
 *   - x = +/-0.0, +/-Inf, NaN -> x unchanged (sign preserved).
 *   - |x| < 0.5              -> +/-0.0 with x's sign.
 *   - |x| = 0.5 exactly      -> +/-0.0 (zero is the even neighbour).
 *   - 0.5 < |x| < 1          -> +/-1.0.
 * Accuracy / algorithm:
 *   Exact; compares the fractional field to the half-ulp weight, then applies
 *   round-half-to-even on the tie.
 *============================================================================*/
double ASM_MATH(rint)(double x)
{
#if ASMLIB_MATH_FAST_ROUND
    return __builtin_rint(x);                       /* roundsd / f64.nearest */
#else
    /* ---- exponent split: raw bits and unbiased exponent ---- */
    uint64_t i = f64_bits(x);                       /* raw IEEE-754 bits */
    int e = (int)((i >> 52) & 0x7ff) - 1023;        /* unbiased exponent */

    if (e >= 52)
        return x;                                   /* integral / Inf / NaN */
    /* ---- domain edge: |x| < 1 ---- */
    if (e < 0) {
        if ((i & F64_ABS) == 0)
            return x;                               /* +/-0 */
        if (e == -1) {                              /* 0.5 <= |x| < 1 */
            /* x is already >= 0.5, so the only non-1 case is exactly 0.5
             * (mantissa zero), which rounds to even (0). */
            if (i & F64_MANT)
                return f64_from_bits((i & F64_SIGN) | ((uint64_t)1023 << 52));
            return f64_from_bits(i & F64_SIGN);
        }
        return f64_from_bits(i & F64_SIGN);         /* |x| < 0.5 -> +/-0 */
    }

    /* ---- rounding split: fractional, half-ulp and one-unit bit weights ---- */
    uint64_t mask = F64_MANT >> e;
    uint64_t frac = i & mask;
    uint64_t half = 1ULL << (51 - e);
    uint64_t lsb = mask + 1;                        /* weight of one unit */
    /* ---- nearest, with an exact tie resolved to the even neighbour ---- */
    if (frac < half)
        i &= ~mask;
    else if (frac > half)
        i = (i & ~mask) + lsb;
    else {                                          /* tie: choose even */
        uint64_t base = i & ~mask;
        if (base & lsb)                             /* odd -> round up */
            base += lsb;
        i = base;
    }
    return f64_from_bits(i);
#endif
}

/*==============================================================================
 * double ASM_MATH(nearbyint)(double x)
 *------------------------------------------------------------------------------
 * Round to nearest integer with ties to even, honouring the current rounding
 * mode. The library never changes the FP environment, so this matches rint and
 * wasm's f64.nearest.
 *
 * Parameters:
 *   x (double) - any finite, infinite, NaN or zero value.
 * Returns:
 *   The same result as rint(x).
 * Special cases:
 *   - identical to rint: +/-0.0, +/-Inf and NaN pass through unchanged.
 * Accuracy / algorithm:
 *   Exact; delegates to rint because rounding is fixed to nearest-even.
 *============================================================================*/
double ASM_MATH(nearbyint)(double x)
{
    /* ---- reconstruction: single rounding mode, so reuse rint ---- */
    return ASM_MATH(rint)(x);
}

/*==============================================================================
 * double ASM_MATH(sqrt)(double x)
 *------------------------------------------------------------------------------
 * Square root, using the target's hardware instruction.
 *
 * Parameters:
 *   x (double) - x >= 0 for a real result; negative inputs are a domain error.
 * Returns:
 *   The correctly rounded sqrt(x).
 * Special cases:
 *   - x = -0.0  -> -0.0 (sqrt(-0) = -0 per IEEE-754).
 *   - x = +0.0  -> +0.0.
 *   - x = +Inf  -> +Inf.
 *   - x < 0     -> NaN (default quiet NaN on x86-64 and wasm).
 *   - x = NaN   -> NaN propagates.
 * Accuracy / algorithm:
 *   Correctly rounded; compiles to sqrtsd on x86-64 and f64.sqrt on wasm.
 *============================================================================*/
double ASM_MATH(sqrt)(double x)
{
    return __builtin_sqrt(x);
}

/*==============================================================================
 * double ASM_MATH(frexp)(double x, int *exp)
 *------------------------------------------------------------------------------
 * Split x into a normalised significand and an exponent, x = m * 2^(*exp).
 *
 * Parameters:
 *   x   (double) - value to decompose; any finite, infinite, NaN or zero value.
 *   exp (int *)  - out: receives the exponent such that x = m * 2^(*exp).
 * Returns:
 *   The significand m in [0.5, 1) for finite x != 0.
 * Special cases:
 *   - x = +/-0.0        -> returns +/-0.0 with *exp = 0.
 *   - x = +/-Inf or NaN -> returns x with *exp = 0.
 *   - subnormal x       -> normalised, with a compensating -64 folded into
 *     *exp after the 2^64 pre-scale.
 * Accuracy / algorithm:
 *   Exact; reads the biased exponent field and rewrites it to 0x3fe so the
 *   significand lies in [0.5, 1).
 *============================================================================*/
double ASM_MATH(frexp)(double x, int *exp)
{
    /* ---- exponent split: classify by the biased exponent field ---- */
    int e = f64_expfield(x);
    /* ---- zero and subnormal: force into the normal range, then correct ---- */
    if (e == 0) {                                   /* zero or subnormal */
        if (x != 0.0) {
            x = ASM_MATH(frexp)(x * 0x1p64, exp);   /* scale into normal range */
            *exp -= 64;                             /* undo the 2^64 scaling */
        } else {
            *exp = 0;
        }
        return x;
    }
    /* ---- Inf and NaN: no significant bits, exponent is meaningless ---- */
    if (e == 0x7ff) {                               /* Inf or NaN */
        *exp = 0;
        return x;
    }
    /* ---- normal: re-bias the fraction to [0.5,1) and report the exponent ---- */
    *exp = e - 0x3fe;                               /* unbiased + 1 */
    return f64_from_bits((f64_bits(x) & ~F64_EXP) | ((uint64_t)0x3fe << 52));
}

/*==============================================================================
 * double ASM_MATH(scalbn)(double x, int n)
 *------------------------------------------------------------------------------
 * Multiply x by 2^n.
 *
 * Parameters:
 *   x (double) - value to scale; any finite, infinite, NaN or zero value.
 *   n (int)    - power of two; may be large positive or negative.
 * Returns:
 *   x * 2^n, exact whenever the result stays in the normal range.
 * Special cases:
 *   - x = +/-0.0, +/-Inf, NaN -> x unchanged (n is ignored).
 *   - overflowing result -> +/-Inf carrying x's sign.
 *   - underflowing result -> rounded subnormal or +/-0.0, as the standard
 *     permits.
 *   - subnormal x is normalised through a 2^54 pre-scale first.
 * Accuracy / algorithm:
 *   Exact for normal results (direct exponent-field adjustment); the final
 *   subnormal step rounds once via an exact power of two.
 *============================================================================*/
double ASM_MATH(scalbn)(double x, int n)
{
    /* ---- domain edges: scaling is unobservable for these ---- */
    int e = f64_expfield(x);
    if (e == 0x7ff || x == 0.0)
        return x;                                   /* Inf, NaN, +/-0 */

    /* ---- subnormal scaling: normalise x, folding 54 into n ---- */
    if (e == 0) {                                   /* subnormal: normalise */
        x *= 0x1p54;
        e = f64_expfield(x);
        n -= 54;                                    /* undo the 2^54 pre-scale */
        if (e == 0x7ff)
            return x;
    }

    /* ---- exponent arithmetic: overflow, exact normal, or subnormal ---- */
    int ne = e + n;
    if (ne >= 0x7ff)                                /* overflow to +/-Inf */
        return f64_signbit(x) ? -F64_INF : F64_INF;
    if (ne > 0) {                                   /* stays normal: exact */
        uint64_t u = f64_bits(x);
        u = (u & ~F64_EXP) | ((uint64_t)ne << 52);  /* install the new exponent */
        return f64_from_bits(u);
    }
    /* ---- subnormal result: restore the hidden bit, then scale ---- */
    /* Subnormal result: normalise the exponent, then scale by an exact power
     * of two (the final step may round, as the standard permits). */
    uint64_t u = (f64_bits(x) & ~F64_EXP) | (1ULL << 52);
    return f64_from_bits(u) * pow2i(ne - 1);
}

/*==============================================================================
 * double ASM_MATH(ldexp)(double x, int n)
 *------------------------------------------------------------------------------
 * Multiply x by 2^n (the ldexp spelling of scalbn).
 *
 * Parameters:
 *   x (double) - value to scale; any finite, infinite, NaN or zero value.
 *   n (int)    - power of two.
 * Returns:
 *   x * 2^n; identical to scalbn(x, n).
 * Special cases:
 *   - same as scalbn: +/-0.0, +/-Inf and NaN pass through; overflow -> +/-Inf.
 * Accuracy / algorithm:
 *   As exact as scalbn; a thin forwarding wrapper.
 *============================================================================*/
double ASM_MATH(ldexp)(double x, int n)
{
    /* ---- delegate to the canonical implementation ---- */
    return ASM_MATH(scalbn)(x, n);
}

/*==============================================================================
 * double ASM_MATH(modf)(double x, double *iptr)
 *------------------------------------------------------------------------------
 * Split x into integral and fractional parts, so that x = *iptr + return value.
 *
 * Parameters:
 *   x    (double)   - value to split; any finite, infinite, NaN or zero value.
 *   iptr (double *) - out: receives the integral part, truncated toward zero.
 * Returns:
 *   The signed fractional part x - *iptr, carrying x's sign.
 * Special cases:
 *   - x = NaN -> *iptr = x and the return value is x (NaN).
 *   - x = +/-Inf -> *iptr = x and a signed zero is returned.
 *   - |x| >= 2^52 (already integral) -> *iptr = x and +/-0.0 is returned.
 *   - |x| < 1 -> *iptr = +/-0.0 and x is returned unchanged.
 * Accuracy / algorithm:
 *   Exact; the integer part is masked out of the mantissa and the fraction is
 *   the exact difference x - ip (both operands are within a factor of two).
 *============================================================================*/
double ASM_MATH(modf)(double x, double *iptr)
{
    /* ---- exponent split: raw bits and unbiased exponent ---- */
    uint64_t i = f64_bits(x);
    int e = (int)((i >> 52) & 0x7ff) - 1023;

    /* ---- NaN: store and return the NaN unchanged ---- */
    if (f64_isnan(x)) {                             /* NaN propagates */
        *iptr = x;
        return x;
    }
    /* ---- Inf: integral part is Inf, fraction is a signed zero ---- */
    if (f64_isinf(x)) {                             /* +/-Inf -> +/-0 fraction */
        *iptr = x;
        return f64_signbit(x) ? -0.0 : 0.0;
    }
    /* ---- already integral: no fractional bits remain ---- */
    if (e >= 52) {                                  /* finite and integral */
        *iptr = x;
        return 0.0 * x;                             /* +/-0 */
    }
    /* ---- |x| < 1: the integral part is a signed zero ---- */
    if (e < 0) {                                    /* |x| < 1 */
        *iptr = f64_from_bits(i & F64_SIGN);
        return x;
    }

    /* ---- general split: truncate the mantissa, then subtract exactly ---- */
    double ip = f64_from_bits(i & ~(F64_MANT >> e));
    *iptr = ip;
    return x - ip;                                  /* exact: |x-ip| < 1 */
}

/*==============================================================================
 * int ASM_MATH(ilogb)(double x)
 *------------------------------------------------------------------------------
 * Unbiased exponent of x, i.e. floor(log2(|x|)).
 *
 * Parameters:
 *   x (double) - any finite, infinite, NaN or zero value.
 * Returns:
 *   floor(log2(|x|)) as an int for finite non-zero x.
 * Special cases:
 *   - x = +/-0.0 -> INT_MIN (FP_ILOGB0).
 *   - x = NaN    -> INT_MIN (FP_ILOGBNAN).
 *   - x = +/-Inf -> INT_MAX.
 *   - subnormal x -> the true (very negative) exponent, by normalisation.
 * Accuracy / algorithm:
 *   Exact integer result; bit inspection, with a left-shift normalisation
 *   loop for subnormals.
 *============================================================================*/
int ASM_MATH(ilogb)(double x)
{
    /* ---- sign handling: only the magnitude participates ---- */
    uint64_t a = f64_bits(x) & F64_ABS;
    /* ---- zero has no exponent: report FP_ILOGB0 ---- */
    if (a == 0)
        return -2147483647 - 1;                     /* INT_MIN: FP_ILOGB0 */
    /* ---- Inf/NaN: exponent field 0x7ff is special-cased ---- */
    if (a >= F64_EXP)
        return (a & F64_MANT) ? (-2147483647 - 1)   /* NaN: FP_ILOGBNAN */
                              : 2147483647;         /* +Inf: INT_MAX */
    /* ---- normal values: simply unbias the exponent field ---- */
    int e = (int)((a >> 52) & 0x7ff);
    if (e != 0)
        return e - 1023;
    /* ---- subnormal scaling: shift left until the hidden bit appears ---- */
    while ((a & F64_HID) == 0) {                    /* subnormal: normalise */
        a <<= 1;
        e--;
    }
    return -1022 + e;
}

/*==============================================================================
 * double ASM_MATH(logb)(double x)
 *------------------------------------------------------------------------------
 * floor(log2(|x|)) as a double.
 *
 * Parameters:
 *   x (double) - any finite, infinite, NaN or zero value.
 * Returns:
 *   The unbiased exponent of x as a double.
 * Special cases:
 *   - x = +/-0.0 -> -Inf.
 *   - x = +/-Inf -> +Inf.
 *   - x = NaN    -> NaN propagates.
 *   - subnormal x -> its true (very negative) exponent, via ilogb.
 * Accuracy / algorithm:
 *   Exact; special values are handled directly, otherwise ilogb is cast to
 *   double.
 *============================================================================*/
double ASM_MATH(logb)(double x)
{
    /* ---- special values: NaN and Inf have fixed answers ---- */
    if (f64_isnan(x))
        return x;
    if (f64_isinf(x))
        return F64_INF;
    if (x == 0.0)
        return -F64_INF;
    /* ---- finite non-zero: the integer exponent, widened to double ---- */
    return (double)ASM_MATH(ilogb)(x);
}
