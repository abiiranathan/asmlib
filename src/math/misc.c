/*==============================================================================
 * misc.c - nextafter, remquo, integer rounding and quiet NaN
 *------------------------------------------------------------------------------
 * Freestanding, no libc. The nextafter/remquo kernels are adapted from musl
 * libc (MIT; see NOTICE in this directory) and the remaining routines are
 * small wrappers over the exact rint/round already provided by basic.c. No
 * errno, no floating-point environment and no global state are touched.
 *
 *   nextafter(x,y)  next representable double after x toward y (IEEE-754)
 *   remquo(x,y,q)   IEEE remainder, plus the low bits of the quotient in *q
 *   lrint/llrint    round to nearest, ties to even, then convert
 *   lround/llround  round to nearest, ties away from zero, then convert
 *   nan(tag)        a quiet NaN (the tag is ignored)
 *============================================================================*/

#include "upstream.h"

#include <limits.h>             /* LONG_MIN / LLONG_MIN for the range clamp */

/*==============================================================================
 * double ASM_MATH(nextafter)(double x, double y)
 *------------------------------------------------------------------------------
 * The next representable binary64 value after x in the direction of y.
 *
 * Parameters:
 *   x (double) - starting value; any finite, infinite, NaN or zero value.
 *   y (double) - direction; only its position relative to x matters.
 * Returns:
 *   The nearest binary64 value strictly beyond x toward y, with all the usual
 *   IEEE-754 edge behaviour (signed zeros count as neighbours).
 * Special cases:
 *   - either operand NaN -> quiet NaN.
 *   - x == y (including +0.0 and -0.0) -> y.
 *   - x = +/-0, y non-zero -> the smallest subnormal of y's sign.
 *   - a finite x stepping past the largest magnitude -> +/-Inf.
 *   - stepping off the smallest magnitude yields +/-0 of the right sign.
 * Accuracy / algorithm:
 *   Exact; the result is x's bit pattern incremented or decremented in the
 *   direction of y, with the zero/subnormal neighbourhood handled explicitly.
 *============================================================================*/
double ASM_MATH(nextafter)(double x, double y)
{
    union { double f; uint64_t i; } ux = { x }, uy = { y };
    uint64_t ax, ay;
    int e;

    /* ---- NaN poisoning: both operands participate ---- */
    if (isnan(x) || isnan(y))
        return x + y;
    /* ---- identical bit patterns (and x == y numerically) return y ---- */
    if (ux.i == uy.i)
        return y;
    /* ---- magnitudes, ignoring the sign bit ---- */
    ax = ux.i & F64_ABS;
    ay = uy.i & F64_ABS;
    if (ax == 0) {
        /* ---- x is a signed zero: step to the smallest subnormal of y ---- */
        if (ay == 0)
            return y;                       /* both zeros: y wins */
        ux.i = (uy.i & F64_SIGN) | 1;       /* smallest subnormal, y's sign */
    } else if (ax > ay || ((ux.i ^ uy.i) & F64_SIGN)) {
        ux.i--;                             /* move toward the origin */
    } else {
        ux.i++;                             /* move away from the origin */
    }
    /* ---- overflow/underflow signalling (results are unaffected) ---- */
    e = (int)(ux.i >> 52) & 0x7ff;
    if (e == 0x7ff)
        FORCE_EVAL(x + x);                  /* x finite, result +/-Inf */
    if (e == 0)
        FORCE_EVAL(x * x + ux.f * ux.f);    /* result subnormal or zero */
    return ux.f;
}

/*==============================================================================
 * double ASM_MATH(remquo)(double x, double y, int *quo)
 *------------------------------------------------------------------------------
 * The IEEE remainder x - n*y (n = x/y rounded to nearest, ties to even) and
 * the low 31 bits of n, sign included, stored in *quo.
 *
 * Parameters:
 *   x   (double) - dividend; any value, but +/-Inf/NaN produce NaN.
 *   y   (double) - divisor; any non-zero value, but NaN/0 produce NaN.
 *   quo (int *)  - out: the low bits of the integer quotient, signed.
 * Returns:
 *   The nearest-integer remainder with magnitude <= |y|/2; NaN for the
 *   invalid operand combinations below.
 * Special cases:
 *   remquo(+-Inf, y) = NaN, remquo(NaN, y) = NaN, remquo(x, NaN) = NaN
 *   remquo(x, +-0) = NaN
 *   remquo(x, +-Inf) = x with *quo = 0
 *   remquo(+-0, y) = +-0 with *quo = 0
 *   an exact |y|/2 remainder rounds to the even multiple
 * Accuracy / algorithm:
 *   Exact; the same binary long division as remainder(), retaining the low
 *   quotient bits in q so the tie decision and *quo agree with IEEE-754.
 *============================================================================*/
double ASM_MATH(remquo)(double x, double y, int *quo)
{
    union { double f; uint64_t i; } ux = { x }, uy = { y };
    int ex = (int)(ux.i >> 52) & 0x7ff;     /* biased exponent of x */
    int ey = (int)(uy.i >> 52) & 0x7ff;     /* biased exponent of y */
    int sx = (int)(ux.i >> 63);             /* sign bit of x */
    int sy = (int)(uy.i >> 63);             /* sign bit of y */
    uint32_t q;                             /* quotient bits */
    uint64_t i;                             /* scratch difference */
    uint64_t uxi = ux.i;                    /* x's significand under construction */

    *quo = 0;
    /* ---- special-case dispatch: zero divisor, NaN, or non-finite x ---- */
    if (uy.i << 1 == 0 || isnan(y) || ex == 0x7ff)
        return (x * y) / (x * y);           /* +-0 divisor / NaN / Inf -> NaN */
    if (ux.i << 1 == 0)
        return x;                           /* x == +-0 -> x, *quo already 0 */

    /* ---- significand normalization: leading bit at position 52 ---- */
    if (!ex) {
        for (i = uxi << 12; i >> 63 == 0; ex--, i <<= 1)
            ;
        uxi <<= -ex + 1;
    } else {
        uxi &= F64_MANT;
        uxi |= 1ULL << 52;
    }
    if (!ey) {
        for (i = uy.i << 12; i >> 63 == 0; ey--, i <<= 1)
            ;
        uy.i <<= -ey + 1;
    } else {
        uy.i &= F64_MANT;
        uy.i |= 1ULL << 52;
    }

    /* ---- |x| < |y| fast path, deferring the rounding edge to `end` ---- */
    q = 0;
    if (ex < ey) {
        if (ex + 1 == ey)
            goto end;                       /* |x| may need rounding to y */
        return x;                           /* strictly below |y|/2 */
    }

    /* ---- binary long division, accumulating the quotient bits in q ---- */
    for (; ex > ey; ex--) {
        i = uxi - uy.i;
        if (i >> 63 == 0) {
            uxi = i;
            q++;
        }
        uxi <<= 1;
        q <<= 1;
    }
    i = uxi - uy.i;
    if (i >> 63 == 0) {
        uxi = i;
        q++;
    }

    /* ---- renormalization: leading bit back to position 52 ---- */
    if (uxi == 0)
        ex = -60;                           /* exact cancellation: zero result */
    else
        for (; uxi >> 52 == 0; uxi <<= 1, ex--)
            ;

end:
    /* ---- sign adjustment and reconstruction of the remainder ---- */
    if (ex > 0) {
        uxi -= 1ULL << 52;
        uxi |= (uint64_t)ex << 52;
    } else {
        uxi >>= -ex + 1;
    }
    ux.i = uxi;
    x = ux.f;                               /* x is now the non-negative remainder */
    if (sy)
        y = -y;                             /* make y positive so 2x > y tests |y|/2 */
    if (ex == ey || (ex + 1 == ey && (2 * x > y || (2 * x == y && q % 2)))) {
        x -= y;                             /* overshot |y|/2: step back one */
        q++;
    }
    q &= 0x7fffffff;                        /* keep only the low 31 quotient bits */
    *quo = sx ^ sy ? -(int)q : (int)q;      /* quotient sign follows x/y */
    return sx ? -x : x;                     /* restore the sign of x */
}

/*==============================================================================
 * static long clamp_long(double r)
 * static long long clamp_ll(double r)
 *------------------------------------------------------------------------------
 * Narrow an already-rounded integral double to a signed integer, saturating
 * to the type's minimum when it does not fit (out of range, Inf or NaN).
 *
 * Parameters:
 *   r (double) - an integral double (the output of rint or round).
 * Returns:
 *   (long)r / (long long)r when representable, otherwise LONG_MIN/LLONG_MIN.
 * Special cases:
 *   - NaN, +Inf and -Inf all map to the minimum value.
 *   - the most negative representable value passes through unchanged.
 * Accuracy / algorithm:
 *   The 2^(N-1) threshold is built exactly in double as
 *   (double)(TYPE_MAX/2 + 1) * 2, avoiding any overflow in the conversion.
 *============================================================================*/
static long clamp_long(double r)
{
    double hi = (double)(LONG_MAX / 2 + 1) * 2.0;    /* 2^(bits-1), exact */
    if (isnan(r) || r >= hi || r < -hi)
        return LONG_MIN;
    return (long)r;
}

static long long clamp_ll(double r)
{
    double hi = (double)(LLONG_MAX / 2 + 1) * 2.0;   /* 2^63, exact */
    if (isnan(r) || r >= hi || r < -hi)
        return LLONG_MIN;
    return (long long)r;
}

/*==============================================================================
 * long ASM_MATH(lrint)(double x)
 * long long ASM_MATH(llrint)(double x)
 *------------------------------------------------------------------------------
 * Round x to the nearest integer with ties to even, then convert to a long /
 * long long.
 *
 * Parameters:
 *   x (double) - any value.
 * Returns:
 *   The nearest integer, ties to even; the minimum value of the integer type
 *   for NaN/Inf/out-of-range inputs (matching the usual libm behaviour).
 * Special cases:
 *   - x = +/-0.0          -> 0.
 *   - a tie (e.g. 2.5)    -> the even neighbour (2).
 *   - NaN/Inf/out of range -> LONG_MIN / LLONG_MIN.
 * Accuracy / algorithm:
 *   Exact; rint() supplies the round-to-nearest-even integer, then a
 *   saturating narrowing conversion avoids undefined behaviour.
 *============================================================================*/
long ASM_MATH(lrint)(double x)
{
    return clamp_long(ASM_MATH(rint)(x));
}

long long ASM_MATH(llrint)(double x)
{
    return clamp_ll(ASM_MATH(rint)(x));
}

/*==============================================================================
 * long ASM_MATH(lround)(double x)
 * long long ASM_MATH(llround)(double x)
 *------------------------------------------------------------------------------
 * Round x to the nearest integer with ties away from zero, then convert to a
 * long / long long.
 *
 * Parameters:
 *   x (double) - any value.
 * Returns:
 *   The nearest integer, ties away from zero; the minimum value of the integer
 *   type for NaN/Inf/out-of-range inputs.
 * Special cases:
 *   - x = +/-0.0          -> 0.
 *   - a tie (e.g. 2.5)    -> 3; -0.5 -> -1.
 *   - NaN/Inf/out of range -> LONG_MIN / LLONG_MIN.
 * Accuracy / algorithm:
 *   Exact; round() implements the half-away-from-zero rule and the narrowing
 *   conversion saturates rather than invoking undefined behaviour.
 *============================================================================*/
long ASM_MATH(lround)(double x)
{
    return clamp_long(ASM_MATH(round)(x));
}

long long ASM_MATH(llround)(double x)
{
    return clamp_ll(ASM_MATH(round)(x));
}

/*==============================================================================
 * double ASM_MATH(nan)(const char *tag)
 *------------------------------------------------------------------------------
 * A quiet NaN. The tag string is accepted for source compatibility with the C
 * standard and is otherwise ignored.
 *
 * Parameters:
 *   tag (const char *) - ignored; may be NULL.
 * Returns:
 *   A quiet NaN with the conventional zero payload (sign bit clear).
 * Special cases:
 *   - always returns the same quiet NaN, regardless of tag.
 * Accuracy / algorithm:
 *   The NaN is packed directly from the exponent field plus a quiet bit.
 *============================================================================*/
double ASM_MATH(nan)(const char *tag)
{
    (void)tag;                              /* tag selects a payload elsewhere */
    return F64_QNAN;
}
