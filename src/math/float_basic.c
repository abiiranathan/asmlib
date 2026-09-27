/*==============================================================================
 * float_basic.c - single-precision (binary32) basic math routines
 *------------------------------------------------------------------------------
 * Freestanding, no libc. The binary32 companion of basic.c/arith.c/misc.c:
 * sign, rounding, scaling, decomposition, the roots and the neighbouring-value
 * routines for float. Most of the surface is evaluated by promoting to double,
 * where the exact (sign/rounding/scaling/remainder) kernels already live, and
 * rounding the single result back to float once. nextafterf and fmaf need real
 * binary32 work and are implemented from raw bits.
 *
 * fmaf is adapted from musl libc (MIT; see NOTICE in this directory).
 *
 * All routines honour IEEE-754 special values and set no errno. Results are
 * exact where the double kernel is exact and faithful otherwise.
 *============================================================================*/

#include "math_private.h"

/*==============================================================================
 * float ASM_MATH(fabsf)(float x)
 *------------------------------------------------------------------------------
 * Absolute value of x; clears the sign bit. Exact, preserving NaN payloads.
 *============================================================================*/
float ASM_MATH(fabsf)(float x)
{
    return f32_from_bits(f32_bits(x) & F32_ABS);
}

/*==============================================================================
 * float ASM_MATH(copysignf)(float x, float y)
 *------------------------------------------------------------------------------
 * Magnitude of x with the sign bit of y; exact for every input.
 *============================================================================*/
float ASM_MATH(copysignf)(float x, float y)
{
    return f32_from_bits((f32_bits(x) & F32_ABS) | (f32_bits(y) & F32_SIGN));
}

/*==============================================================================
 * float ASM_MATH(fminf)(float x, float y)
 *------------------------------------------------------------------------------
 * NaN-aware minimum; on a signed-zero tie the negative zero wins. Mirrors the
 * double fmin rules exactly.
 *============================================================================*/
float ASM_MATH(fminf)(float x, float y)
{
    if (f32_isnan(x))
        return y;
    if (f32_isnan(y))
        return x;
    if (x == y)
        return f32_signbit(x) ? x : y;
    return x < y ? x : y;
}

/*==============================================================================
 * float ASM_MATH(fmaxf)(float x, float y)
 *------------------------------------------------------------------------------
 * NaN-aware maximum; on a signed-zero tie the positive zero wins. Mirrors the
 * double fmax rules exactly.
 *============================================================================*/
float ASM_MATH(fmaxf)(float x, float y)
{
    if (f32_isnan(x))
        return y;
    if (f32_isnan(y))
        return x;
    if (x == y)
        return f32_signbit(x) ? y : x;
    return x > y ? x : y;
}

/*==============================================================================
 * float ASM_MATH(fdimf)(float x, float y)
 *------------------------------------------------------------------------------
 * Positive difference max(x - y, +0.0); NaN poisons the result.
 *============================================================================*/
float ASM_MATH(fdimf)(float x, float y)
{
    if (f32_isnan(x) || f32_isnan(y))
        return F32_QNAN;
    return x > y ? x - y : 0.0f;
}

/*==============================================================================
 * float ASM_MATH(floorf)(float x)
 * float ASM_MATH(ceilf)(float x)
 * float ASM_MATH(truncf)(float x)
 * float ASM_MATH(roundf)(float x)
 * float ASM_MATH(rintf)(float x)
 * float ASM_MATH(nearbyintf)(float x)
 *------------------------------------------------------------------------------
 * The rounding family, evaluated with the exact double kernels and narrowed
 * once. The integer results always fit a float exactly, so the cast is exact.
 *============================================================================*/
float ASM_MATH(floorf)(float x)
{
    return (float)ASM_MATH(floor)((double)x);
}

float ASM_MATH(ceilf)(float x)
{
    return (float)ASM_MATH(ceil)((double)x);
}

float ASM_MATH(truncf)(float x)
{
    return (float)ASM_MATH(trunc)((double)x);
}

float ASM_MATH(roundf)(float x)
{
    return (float)ASM_MATH(round)((double)x);
}

float ASM_MATH(rintf)(float x)
{
    return (float)ASM_MATH(rint)((double)x);
}

float ASM_MATH(nearbyintf)(float x)
{
    return (float)ASM_MATH(nearbyint)((double)x);
}

/*==============================================================================
 * float ASM_MATH(ldexpf)(float x, int n)
 * float ASM_MATH(scalbnf)(float x, int n)
 *------------------------------------------------------------------------------
 * x * 2^n. The exact double scaling is representable as a double, so the final
 * float narrowing performs the single correct rounding (including subnormal
 * results and overflow to +/-Inf). n is first clamped: beyond +-1000 every
 * nonzero float saturates, and the clamp also keeps the double exponent
 * arithmetic away from signed overflow for n = INT_MIN/INT_MAX.
 *============================================================================*/
static int f32_exp_clamp(int n)
{
    if (n > 1000)
        return 1000;
    if (n < -1000)
        return -1000;
    return n;
}

float ASM_MATH(scalbnf)(float x, int n)
{
    return (float)ASM_MATH(scalbn)((double)x, f32_exp_clamp(n));
}

float ASM_MATH(ldexpf)(float x, int n)
{
    return ASM_MATH(scalbnf)(x, n);
}

/*==============================================================================
 * float ASM_MATH(frexpf)(float x, int *exp)
 *------------------------------------------------------------------------------
 * Split x = m * 2^(*exp) with m in [0.5, 1). The double significand is exactly
 * representable as a float. Zero/Inf/NaN pass through with *exp = 0.
 *============================================================================*/
float ASM_MATH(frexpf)(float x, int *exp)
{
    return (float)ASM_MATH(frexp)((double)x, exp);
}

/*==============================================================================
 * float ASM_MATH(modff)(float x, float *iptr)
 *------------------------------------------------------------------------------
 * Split x into truncated integral and fractional parts; both are exactly
 * representable as float.
 *============================================================================*/
float ASM_MATH(modff)(float x, float *iptr)
{
    double ip;
    float frac = (float)ASM_MATH(modf)((double)x, &ip);
    /* The double kernel forms the fraction as x - ip; when x is negative and
     * already integral that subtraction yields +0, losing x's sign.  Restore
     * the required sign of the zero fractional part. */
    if (frac == 0.0f)
        frac = ASM_MATH(copysignf)(0.0f, x);
    *iptr = (float)ip;
    return frac;
}

/*==============================================================================
 * int ASM_MATH(ilogbf)(float x)
 * float ASM_MATH(logbf)(float x)
 *------------------------------------------------------------------------------
 * Exponent extraction. float values are a subset of double, so the double
 * kernels give the same exponent; logb's integer result is exactly a float.
 *============================================================================*/
int ASM_MATH(ilogbf)(float x)
{
    return ASM_MATH(ilogb)((double)x);
}

float ASM_MATH(logbf)(float x)
{
    return (float)ASM_MATH(logb)((double)x);
}

/*==============================================================================
 * float ASM_MATH(fmodf)(float x, float y)
 * float ASM_MATH(remainderf)(float x, float y)
 * float ASM_MATH(remquof)(float x, float y, int *quo)
 *------------------------------------------------------------------------------
 * Exact remainders. The double kernels are exact and their results always fit
 * a binary32 value, so the narrowing cast is exact. The quotient low bits for
 * remquof depend only on the exact integer quotient and are preserved.
 *============================================================================*/
float ASM_MATH(fmodf)(float x, float y)
{
    return (float)ASM_MATH(fmod)((double)x, (double)y);
}

float ASM_MATH(remainderf)(float x, float y)
{
    return (float)ASM_MATH(remainder)((double)x, (double)y);
}

float ASM_MATH(remquof)(float x, float y, int *quo)
{
    return (float)ASM_MATH(remquo)((double)x, (double)y, quo);
}

/*==============================================================================
 * float ASM_MATH(sqrtf)(float x)
 * float ASM_MATH(cbrtf)(float x)
 * float ASM_MATH(hypotf)(float x, float y)
 *------------------------------------------------------------------------------
 * The roots. Evaluated in double (which is correctly rounded for sqrt and
 * faithful for cbrt/hypot) and rounded once to float, well within 1 ulp.
 *============================================================================*/
float ASM_MATH(sqrtf)(float x)
{
    return (float)ASM_MATH(sqrt)((double)x);
}

float ASM_MATH(cbrtf)(float x)
{
    return (float)ASM_MATH(cbrt)((double)x);
}

float ASM_MATH(hypotf)(float x, float y)
{
    return (float)ASM_MATH(hypot)((double)x, (double)y);
}

/*==============================================================================
 * float ASM_MATH(nextafterf)(float x, float y)
 *------------------------------------------------------------------------------
 * The next representable binary32 value after x toward y. Implemented directly
 * on the float bit pattern so the step is one binary32 ulp, not one binary64
 * ulp: increment/decrement away from or toward the origin, with the signed-zero
 * and smallest-subnormal neighbourhood handled explicitly.
 *============================================================================*/
float ASM_MATH(nextafterf)(float x, float y)
{
    uint32_t ux = f32_bits(x), uy = f32_bits(y);
    uint32_t ax, ay;

    if (f32_isnan(x) || f32_isnan(y))
        return x + y;
    if (ux == uy)
        return y;                                   /* identical, incl. +0/+0 */
    ax = ux & F32_ABS;
    ay = uy & F32_ABS;
    if (ax == 0) {
        if (ay == 0)
            return y;                               /* +/-0 -> the other zero */
        ux = (uy & F32_SIGN) | 1u;                  /* smallest subnormal */
    } else if (ax > ay || ((ux ^ uy) & F32_SIGN)) {
        ux--;                                       /* step toward the origin */
    } else {
        ux++;                                       /* step away from the origin */
    }
    return f32_from_bits(ux);
}

/*==============================================================================
 * float ASM_MATH(fmaf)(float x, float y, float z)
 *------------------------------------------------------------------------------
 * Correctly rounded x*y + z with a single rounding. Adapted from musl libc
 * (MIT; see NOTICE). Because x and y are binary32, the product (double)x*(double)y
 * is exact; the double sum xy + z is therefore exact except for one rounding.
 * Exact halfway and subnormal cases are corrected using the residual t, which
 * turns the double result into a round-to-odd value so the final conversion to
 * float rounds once, correctly.
 *============================================================================*/
float ASM_MATH(fmaf)(float x, float y, float z)
{
    double xy = (double)x * (double)y;              /* exact product */
    union { double r; uint64_t i; } u;
    int e, halfway, tiny, s;
    double t;

    u.r = xy + (double)z;
    e = (int)(u.i >> 52) & 0x7ff;
    /* |r| > 0x1p-126 exact-halfway case */
    halfway = (u.i & 0x1fffffff) == 0x10000000;
    /* tiny inexact and tiny halfway cases (float subnormal range) */
    tiny = e <= 0x3ff - 126 && e >= 0x3ff - 149;
    if (!halfway && !tiny)
        return (float)u.r;                          /* common case */
    if (e != 0x7ff) {
        s = (int)(u.i >> 63);
        /* r + t is exactly x*y + z in nearest rounding; otherwise t is a
         * non-zero residual unaffected by the rounding. */
        t = s == (xy < z) ? xy - u.r + z : z - u.r + xy;
        if (t) {
            /* adjust r toward r+t and force the low bit (round to odd) */
            u.i -= (uint64_t)(s ^ (t < 0));
            u.i |= 1u;
        }
    }
    return (float)u.r;
}

/*==============================================================================
 * long ASM_MATH(lrintf)(float x)
 * long long ASM_MATH(llrintf)(float x)
 * long ASM_MATH(lroundf)(float x)
 * long long ASM_MATH(llroundf)(float x)
 *------------------------------------------------------------------------------
 * Round to an integer (nearest-even for lrint/llrint, half away from zero for
 * lround/llround) and convert. The double versions already saturate to the
 * integer type's minimum on NaN/Inf/out-of-range.
 *============================================================================*/
long ASM_MATH(lrintf)(float x)
{
    return ASM_MATH(lrint)((double)x);
}

long long ASM_MATH(llrintf)(float x)
{
    return ASM_MATH(llrint)((double)x);
}

long ASM_MATH(lroundf)(float x)
{
    return ASM_MATH(lround)((double)x);
}

long long ASM_MATH(llroundf)(float x)
{
    return ASM_MATH(llround)((double)x);
}

/*==============================================================================
 * float ASM_MATH(nanf)(const char *tag)
 *------------------------------------------------------------------------------
 * A quiet binary32 NaN; the tag is ignored. Built directly from the exponent
 * field plus the quiet bit.
 *============================================================================*/
float ASM_MATH(nanf)(const char *tag)
{
    (void)tag;
    return F32_QNAN;
}
