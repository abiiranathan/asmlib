/*==============================================================================
 * log.c - natural, binary and decimal logarithms plus log1p
 *------------------------------------------------------------------------------
 * Freestanding, no libc/libm, no errno, no floating-point environment, no
 * mutable global state. All helpers below are static.
 *
 * Every routine first writes x = m * 2^k with m in [sqrt(1/2), sqrt(2)) using
 * asm_frexp (which also normalises subnormals), then sets f = m - 1 (exact by
 * Sterbenz) and s = f/(2+f). Since
 *
 *     log(1+f) = 2*atanh(s) = 2s + 2s^3/3 + 2s^5/5 + ...
 *
 * with z = s^2 this is
 *
 *     log(1+f) = f - f^2/2 + s*(f^2/2 + R(z)),
 *     R(z) = z*(2/3 + (2/5)z + (2/7)z^2 + ...),
 *
 * a full power series in z bounded by |z| < 0.0295 over the reduced range, so
 * a dozen explicit terms reach far below one ulp. The s division only ever
 * multiplies the O(f^3) correction, so its rounding is harmless.
 *
 * log2/log10 reuse that reduction and apply a compensated multiply by the
 * conversion constant before adding k*log2(2) / k*log10(2). log1p uses the
 * same identity directly for moderate x and a two_sum split of 1+x otherwise,
 * so the addition of 1 that would destroy tiny inputs is always compensated.
 *============================================================================*/

#include "math_private.h"

static const double
ln2_hi = 6.93147180369123816490e-01,   /* ln(2) with low mantissa bits clear */
ln2_lo = 1.90821492927058770002e-10,   /* ln(2) - ln2_hi                       */

ivln2hi = 1.44269504072144627571e+00,  /* 1/ln(2), split for exact products    */
ivln2lo = 1.67517131648865118353e-10,

log10_2hi = 3.01029995663611771306e-01, /* log10(2), split                    */
log10_2lo = 3.69423907715893076418e-13,
ivln10hi  = 4.34294481878168880939e-01, /* 1/ln(10), split                    */
ivln10lo  = 2.50829467116452752298e-11;

/* sqrt(1/2): the reduction split point. */
#define LOG_SQRT_HALF 7.07106781186547524401e-01

/*==============================================================================
 * static void two_sum(double a, double b, double *s, double *e)
 *------------------------------------------------------------------------------
 * Exact sum a + b = *s + *e (Knuth's branch-free 2Sum).
 *
 * Parameters:
 *   a, b (double) - the addends; any values whose sum is finite and normal
 *   s (double *)  - receives the rounded sum a + b
 *   e (double *)  - receives the exact rounding error (a + b) - *s
 * Returns:
 *   nothing; both results are written through the pointer arguments
 * Special cases:
 *   requires a + b not to overflow; a subnormal error term is harmless because
 *   the callers only ever evaluate *s + *e once, at the very end
 * Accuracy / algorithm:
 *   exact: *s + *e reproduces a + b to the last bit
 *============================================================================*/
static void two_sum(double a, double b, double *s, double *e)
{
    /* ---- 2Sum: t is the rounded sum, bv is a rounded back out of t ---- */
    double t = a + b;
    double bv = t - a;
    *e = (a - (t - bv)) + (b - bv);     /* the exact residual */
    *s = t;
}

/*==============================================================================
 * static void two_prod(double a, double b, double *p, double *e)
 *------------------------------------------------------------------------------
 * Exact product a * b = *p + *e (Dekker splitting, no FMA required).
 *
 * Parameters:
 *   a, b (double) - the factors; any values whose product is finite and normal
 *   p (double *)  - receives the rounded product a * b
 *   e (double *)  - receives the exact rounding error (a * b) - *p
 * Returns:
 *   nothing; both results are written through the pointer arguments
 * Special cases:
 *   only valid while the products stay in range; the callers multiply reduced
 *   logarithms by constants near 1, so neither overflow nor underflow occurs
 * Accuracy / algorithm:
 *   exact: *p + *e reproduces a * b to the last bit
 *============================================================================*/
static void two_prod(double a, double b, double *p, double *e)
{
    /* ---- split each factor into 26-bit high and low halves ---- */
    const double split = 134217729.0;               /* 2^27 + 1 */
    double c = split * a;
    double ah = c - (c - a);            /* high 26 bits of a */
    double al = a - ah;                 /* low  bits of a */
    double d = split * b;
    double bh = d - (d - b);            /* high 26 bits of b */
    double bl = b - bh;                 /* low  bits of b */
    *p = a * b;
    /* Cross terms recover the part of the product lost to rounding. */
    *e = ((ah * bh - *p) + ah * bl + al * bh) + al * bl;
}

/*==============================================================================
 * static double eval_R(double z)
 *------------------------------------------------------------------------------
 * R(z) = 2/3*z + 2/5*z^2 + 2/7*z^3 + ... , valid for |z| < 0.03.
 *
 * Parameters:
 *   z (double) - the squared reduced argument s^2; here |z| < 0.0295
 * Returns:
 *   the value of the odd series, including its leading factor z
 * Special cases:
 *   none: z is a square, so it is never negative, and the reduction bounds
 *   its magnitude far away from any special value
 * Accuracy / algorithm:
 *   Horner evaluation of twelve explicit terms; convergence over this range is
 *   so fast that the truncation error stays far below one ulp
 *============================================================================*/
static double eval_R(double z)
{
    /* ---- Horner form: z * (2/3 + z*(2/5 + z*(2/7 + ...))) ---- */
    return z * (0.66666666666666666667
         + z * (0.40000000000000000000
         + z * (0.28571428571428571429
         + z * (0.22222222222222222222
         + z * (0.18181818181818181818
         + z * (0.15384615384615384615
         + z * (0.13333333333333333333
         + z * (0.11764705882352941176
         + z * (0.10526315789473684211
         + z * (0.09523809523809523810
         + z * (0.08695652173913043478
         + z * (0.08000000000000000000))))))))))));
}

/*==============================================================================
 * static double log_m(double x, int *kout)
 *------------------------------------------------------------------------------
 * Reduce a positive finite x to y = log(m) with x = m*2^k, m in
 * [sqrt(1/2), sqrt(2)), and store k. y is faithful to a fraction of an ulp;
 * the callers add the k*ln(2) term with compensation.
 *
 * Parameters:
 *   x (double)   - a positive finite value; the public wrappers reject zero,
 *                  negatives and non-finite inputs before reaching here
 *   kout (int *) - receives the exponent k with x = m * 2^k
 * Returns:
 *   log(m), the near-zero part of log(x); the caller adds k*ln(2)
 * Special cases:
 *   x subnormal: asm_frexp normalizes it and reports the matching, very
 *   negative k, so the reduction stays exact
 * Accuracy / algorithm:
 *   Sterbenz reduction f = m - 1 (exact), s = f/(2+f), z = s^2, then
 *   log(1+f) = f - f^2/2 + s*(f^2/2 + R(z)); the reduction keeps |z| < 0.03,
 *   so the series error stays far below an ulp
 *============================================================================*/
static double log_m(double x, int *kout)
{
    /* ---- argument reduction: x = m * 2^k, m in [sqrt(1/2), sqrt(2)) ---- */
    int k;
    double m = ASM_MATH(frexp)(x, &k);
    if (m < LOG_SQRT_HALF) {
        m *= 2.0;                       /* fold m in [sqrt(1/2),1) up one binade */
        k -= 1;
    }
    *kout = k;

    /* ---- evaluate log(1+f) with the atanh series, s = f/(2+f) ---- */
    double f = m - 1.0;                 /* exact by Sterbenz: |f| < sqrt(2)-1 */
    double s = f / (2.0 + f);
    double z = s * s;
    double hfsq = 0.5 * f * f;
    return f - hfsq + s * (hfsq + eval_R(z));
}

/*==============================================================================
 * double ASM_MATH(log)(double x)
 *------------------------------------------------------------------------------
 * Natural logarithm.
 *
 * Parameters:
 *   x (double) - any value; positive finite values are the valid domain
 * Returns:
 *   ln(x) for x > 0; NaN for x < 0 or x = NaN; -Inf for x = +-0;
 *   +Inf for x = +Inf
 * Special cases:
 *   log(+-0) = -Inf (both signed zeros), log(x < 0) = NaN, log(NaN) = NaN,
 *   log(+Inf) = +Inf; no errno is set on any path
 * Accuracy / algorithm:
 *   log_m reduces x to log(m) + k*ln(2); the k*ln(2) term is added through a
 *   two_sum split (ln2_hi + ln2_lo) so cancellation against y keeps full
 *   precision
 *============================================================================*/
double ASM_MATH(log)(double x)
{
    /* ---- special-case dispatch: NaN / negative / zero / +Inf ---- */
    if (f64_isnan(x) || x < 0.0)
        return F64_QNAN;                            /* NaN, negative (incl -Inf) */
    if (x == 0.0)
        return -F64_INF;                            /* log(+/-0) = -Inf          */
    if (f64_isinf(x))
        return F64_INF;                             /* log(+Inf) = +Inf          */

    /* ---- reduce, then add the k*ln(2) term with compensation ---- */
    int k;
    double y = log_m(x, &k);
    double dk = (double)k;
    double base, err;
    two_sum(dk * ln2_hi, y, &base, &err);           /* exact split of the sum */
    return base + (err + dk * ln2_lo);              /* fold in the low ln(2) part */
}

/*==============================================================================
 * double ASM_MATH(log2)(double x)
 *------------------------------------------------------------------------------
 * Base-2 logarithm.
 *
 * Parameters:
 *   x (double) - any value; positive finite values are the valid domain
 * Returns:
 *   log2(x) for x > 0; NaN for x < 0 or x = NaN; -Inf for x = +-0;
 *   +Inf for x = +Inf
 * Special cases:
 *   log2(+-0) = -Inf, log2(x < 0) = NaN, log2(NaN) = NaN, log2(+Inf) = +Inf
 * Accuracy / algorithm:
 *   log_m reduces to log(m), multiplied by the split constant (ivln2hi +
 *   ivln2lo) using two_prod; the integer exponent k is then added with two_sum
 *============================================================================*/
double ASM_MATH(log2)(double x)
{
    /* ---- special-case dispatch: NaN / negative / zero / +Inf ---- */
    if (f64_isnan(x) || x < 0.0)
        return F64_QNAN;
    if (x == 0.0)
        return -F64_INF;
    if (f64_isinf(x))
        return F64_INF;

    /* ---- reduce; scale log(m) by 1/ln(2); then add the exponent k ---- */
    int k;
    double y = log_m(x, &k);
    double dk = (double)k;
    double p, pe;
    two_prod(y, ivln2hi, &p, &pe);                  /* exact high product */
    double base, err;
    two_sum(dk, p, &base, &err);                    /* exact split of k + p */
    return base + (err + (pe + y * ivln2lo));       /* low correction terms */
}

/*==============================================================================
 * double ASM_MATH(log10)(double x)
 *------------------------------------------------------------------------------
 * Base-10 logarithm.
 *
 * Parameters:
 *   x (double) - any value; positive finite values are the valid domain
 * Returns:
 *   log10(x) for x > 0; NaN for x < 0 or x = NaN; -Inf for x = +-0;
 *   +Inf for x = +Inf
 * Special cases:
 *   log10(+-0) = -Inf, log10(x < 0) = NaN, log10(NaN) = NaN, log10(+Inf) = +Inf
 * Accuracy / algorithm:
 *   log_m reduces to log(m), multiplied by the split constant (ivln10hi +
 *   ivln10lo) using two_prod; the exponent term k*log10(2) is likewise split
 *   (log10_2hi + log10_2lo) and combined with two_sum
 *============================================================================*/
double ASM_MATH(log10)(double x)
{
    /* ---- special-case dispatch: NaN / negative / zero / +Inf ---- */
    if (f64_isnan(x) || x < 0.0)
        return F64_QNAN;
    if (x == 0.0)
        return -F64_INF;
    if (f64_isinf(x))
        return F64_INF;

    /* ---- reduce; scale log(m) by 1/ln(10); then add k*log10(2) ---- */
    int k;
    double y = log_m(x, &k);
    double dk = (double)k;
    double p, pe;
    two_prod(y, ivln10hi, &p, &pe);                 /* exact high product */
    double base, err;
    two_sum(dk * log10_2hi, p, &base, &err);        /* exact split of the sum */
    return base + (err + (pe + (dk * log10_2lo + y * ivln10lo)));
}

/*==============================================================================
 * double ASM_MATH(log1p)(double x)
 *------------------------------------------------------------------------------
 * Natural logarithm of 1 + x, accurate for tiny x.
 *
 * Parameters:
 *   x (double) - any value; x >= -1 is the valid domain
 * Returns:
 *   ln(1 + x) computed without the rounding of an explicit 1 + x; NaN for
 *   x < -1 or NaN; -Inf for x = -1; +Inf for x = +Inf; x itself for x = +-0
 * Special cases:
 *   log1p(-1) = -Inf, log1p(x < -1) = NaN, log1p(NaN) = NaN,
 *   log1p(+Inf) = +Inf, log1p(+-0) = +-0 (the signed zero is preserved)
 * Accuracy / algorithm:
 *   for |x| < 0.25 the atanh reduction runs directly in f = x, keeping every
 *   bit of tiny inputs; otherwise 1 + x is split exactly with two_sum and the
 *   small correction log1p(e/u) = e/u is added
 *============================================================================*/
double ASM_MATH(log1p)(double x)
{
    /* ---- special-case dispatch: NaN / x < -1 / -1 / +Inf / +-0 ---- */
    if (f64_isnan(x) || x < -1.0)
        return F64_QNAN;                            /* log1p(x < -1) = NaN       */
    if (x == -1.0)
        return -F64_INF;                            /* log1p(-1) = -Inf          */
    if (f64_isinf(x))
        return x;                                   /* log1p(+Inf) = +Inf        */
    if (x == 0.0)
        return x;                                   /* preserves signed zero     */

    /* ---- moderate x: run the reduction directly in f = x (no 1 + x) ---- */
    if (x > -0.25 && x < 0.25) {
        /* Direct reduction in f = x keeps full precision for tiny inputs. */
        double f = x;
        double s = f / (2.0 + f);
        double z = s * s;
        double hfsq = 0.5 * f * f;
        return f - hfsq + s * (hfsq + eval_R(z));
    }

    /* ---- |x| >= 0.25: split 1 + x exactly, then log1p(x) = log(u) + log1p(e/u) ---- */
    /* |x| >= 0.25: split 1 + x exactly, then log1p(x) = log(u) + log1p(e/u). */
    double u, ue;
    two_sum(1.0, x, &u, &ue);                       /* u = fl(1+x), ue = exact error */
    double lu = ASM_MATH(log)(u);
    double t = ue / u;                              /* |t| <= 2^-52; t^2/2 gone */
    return lu + t;
}
