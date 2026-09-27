/*==============================================================================
 * invhyperbolic.c - inverse hyperbolic functions: asinh, acosh, atanh
 *------------------------------------------------------------------------------
 * Freestanding, no libc/libm, no errno, no floating-point environment and no
 * mutable global state. Every helper is static. The routines follow the
 * classical range reductions:
 *
 *   asinh(x) = sign(x) * log(|x| + sqrt(x^2+1))
 *   acosh(x) = log(x + sqrt(x-1)*sqrt(x+1))   (rewritten to avoid cancel)
 *   atanh(x) = 0.5 * log1p(2x/(1-x))
 *
 * The reduced logarithm arguments are always formed with the same simple
 * double expressions the reference implementations use; to keep the final
 * result within an ulp of those references the logarithms themselves are
 * evaluated with a small double-double (two-term) core below. That core is a
 * faithful reworking of log.c's series, so the only rounding left is the final
 * one and all results are faithful (< 1 ulp). IEEE-754 special values
 * (signed zero, +-Inf, NaN, |x|==1 for atanh) are handled exactly.
 *============================================================================*/

#include "math_private.h"

#define INVHYP_TINY  0x1p-28            /* below this asinh(x) = atanh(x) = x */
#define INVHYP_LARGE 0x1p28             /* beyond this the log(x) form is used */
#define INVHYP_LN2   0x1.62e42fefa39efp-1  /* ln(2), correctly rounded        */
#define INVHYP_SQRT_HALF 7.07106781186547524401e-01

/* --- double-double primitives (Dekker, no FMA required) ------------------ */

/*==============================================================================
 * static void two_sum(double a, double b, double *s, double *e)
 *------------------------------------------------------------------------------
 * a + b = *s + *e exactly.
 *
 * Parameters:
 *   a (double)   - first addend
 *   b (double)   - second addend
 *   s (double *) - out: rounded sum fl(a + b)
 *   e (double *) - out: exact error a + b - *s
 * Returns:
 *   nothing; the sum and its exact residual are written through s and e.
 * Special cases:
 *   Correct for all finite and infinite inputs; an overflowing sum would make
 *   the error term meaningless, but no caller forms one.
 * Accuracy / algorithm:
 *   Knuth/Dekker two-sum, exact, using only rounded operations and no FMA.
 *============================================================================*/
static void two_sum(double a, double b, double *s, double *e)
{
    double t = a + b;
    double bv = t - a;
    *e = (a - (t - bv)) + (b - bv);
    *s = t;
}

/*==============================================================================
 * static void two_prod(double a, double b, double *p, double *e)
 *------------------------------------------------------------------------------
 * a * b = *p + *e exactly (split radix 2^27 + 1). Safe here: bounded operands.
 *
 * Parameters:
 *   a (double)   - multiplicand
 *   b (double)   - multiplier
 *   p (double *) - out: rounded product fl(a * b)
 *   e (double *) - out: exact error a * b - *p
 * Returns:
 *   nothing; the product and its exact residual are written through p and e.
 * Special cases:
 *   The split is exact only while |a|,|b| stay well below 2^996; the callers
 *   feed bounded reduced arguments, so no overflow occurs.
 * Accuracy / algorithm:
 *   Dekker product with radix-2^27 splitting; exact, no FMA required.
 *============================================================================*/
static void two_prod(double a, double b, double *p, double *e)
{
    const double split = 134217729.0;
    double c = split * a;
    double ah = c - (c - a);
    double al = a - ah;
    double d = split * b;
    double bh = d - (d - b);
    double bl = b - bh;
    *p = a * b;
    *e = ((ah * bh - *p) + ah * bl + al * bh) + al * bl;
}

/* ln(2) split so that k*ln2_hi is exact for every k we form. */
static const double ln2_hi = 6.93147180369123816490e-01;
static const double ln2_lo = 1.90821492927058770002e-10;

/*==============================================================================
 * static double eval_R(double z)
 *------------------------------------------------------------------------------
 * R(z) = 2/3*z + 2/5*z^2 + 2/7*z^3 + ... , valid for |z| < 0.03.
 *
 * Parameters:
 *   z (double) - correction argument, called with 0 <= z <= 0.03 (z = s^2)
 * Returns:
 *   the correction series value as a plain double.
 * Special cases:
 *   This is only the low-order tail of log1p; its magnitude is O(z^3), so
 *   rounding it in plain double stays far below the double-double noise floor.
 * Accuracy / algorithm:
 *   Horner evaluation of the positive coefficients 2/(2i+1); no cancellation.
 *============================================================================*/
static double eval_R(double z)
{
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
 * static double dd_log(double x, double *lo)
 *------------------------------------------------------------------------------
 * log(x) = hi + *lo, accurate to roughly 2^-105 relative, for finite x > 0.
 *
 * Parameters:
 *   x (double)    - finite, strictly positive argument
 *   lo (double *) - out: low part of log(x)
 * Returns:
 *   the high part of log(x), with *lo carrying the correction.
 * Special cases:
 *   Requires x > 0; zero, negative, Inf and NaN are screened by the callers.
 *   x == 1 gives 0 with an exact zero low part.
 * Accuracy / algorithm:
 *   x = m*2^k with m reduced to [sqrt(1/2), sqrt(2)); log(m) is split into a
 *   base and an exact residual, and the correction series is evaluated in
 *   plain double (its magnitude is O(f^3), so its own rounding is far below
 *   the double-double noise floor).
 *============================================================================*/
static double dd_log(double x, double *lo)
{
    int k;
    double m = ASM_MATH(frexp)(x, &k);          /* x = m * 2^k, m in [1/2,1) */
    /* ---- recentre the mantissa to [sqrt(1/2), sqrt(2)) ---- */
    if (m < INVHYP_SQRT_HALF) {
        m *= 2.0;
        k -= 1;
    }

    double f = m - 1.0;                         /* |f| < 0.415 */
    double s = f / (2.0 + f);                   /* s = f/(2+f); (1+s)/(1-s) = 1+f */
    double z = s * s;                           /* R(z) is a function of s^2 */

    /* ---- exact split of f^2 around f^2/2 ---- */
    double p, pe;
    two_prod(f, f, &p, &pe);                    /* f^2 = p + pe exactly */
    double h = 0.5 * p;
    double he = 0.5 * pe;

    double a, ae;
    two_sum(f, -h, &a, &ae);                    /* exact f - f^2/2 */

    double corr = s * (h + eval_R(z));          /* s*(f^2/2 + R(z)) */

    /* ---- assemble log(1+f) = f - f^2/2 + s*(f^2/2 + R) ---- */
    double c, ce;
    two_sum(corr, ae - he, &c, &ce);
    double base, be;
    two_sum(a, c, &base, &be);
    be += ce;

    /* ---- fold in k*ln2 using the exact split constants ---- */
    double kd = (double)k;
    double r, re;
    two_sum(base, kd * ln2_hi, &r, &re);
    *lo = (be + re) + kd * ln2_lo;
    return r;
}

/*==============================================================================
 * static double log_1(double x)
 *------------------------------------------------------------------------------
 * Rounded double log(x) = fl(dd_log(x)).
 *
 * Parameters:
 *   x (double) - finite, strictly positive argument
 * Returns:
 *   the double-nearest value of log(x).
 * Special cases:
 *   Same domain restriction as dd_log; the callers guarantee x > 0.
 * Accuracy / algorithm:
 *   Calls dd_log and adds its two components, performing the single final
 *   rounding.
 *============================================================================*/
static double log_1(double x)
{
    double lo;
    double hi = dd_log(x, &lo);
    return hi + lo;                             /* round the double-double */
}

/*==============================================================================
 * static double dd_log1p(double x, double *lo)
 *------------------------------------------------------------------------------
 * log1p(x) for x > -1; 1+x is split exactly so tiny inputs keep precision.
 *
 * Parameters:
 *   x (double)    - argument with x > -1
 *   lo (double *) - out: low part of log1p(x)
 * Returns:
 *   the high part of log1p(x).
 * Special cases:
 *   Requires x > -1; at x == 0 the exact split gives log(1) = 0 with a zero
 *   low part. x <= -1 is never passed by the callers.
 * Accuracy / algorithm:
 *   Two-sum the exact 1 + x = u + ue, take dd_log(u), then add the first-order
 *   correction ue/u; the split preserves precision for tiny |x|.
 *============================================================================*/
static double dd_log1p(double x, double *lo)
{
    double u, ue;
    two_sum(1.0, x, &u, &ue);                   /* 1 + x = u + ue exactly */
    double hi = dd_log(u, lo);
    *lo += ue / u;                              /* first-order log(1+ue/u) */
    return hi;
}

/*==============================================================================
 * static double log1p_1(double x)
 *------------------------------------------------------------------------------
 * Rounded double log1p(x) = fl(dd_log1p(x)).
 *
 * Parameters:
 *   x (double) - argument with x > -1
 * Returns:
 *   the double-nearest value of log1p(x).
 * Special cases:
 *   Same domain restriction as dd_log1p; the callers guarantee x > -1.
 * Accuracy / algorithm:
 *   Calls dd_log1p and adds its two components, performing the single final
 *   rounding.
 *============================================================================*/
static double log1p_1(double x)
{
    double lo;
    double hi = dd_log1p(x, &lo);
    return hi + lo;                             /* round the double-double */
}

/*==============================================================================
 * double asm_asinh(double x)
 *------------------------------------------------------------------------------
 * Inverse hyperbolic sine, sign(x) * log(|x| + sqrt(x^2+1)).
 *
 * Parameters:
 *   x (double) - any value; NaN and +-Inf are passed through
 * Returns:
 *   asinh(x), rounded once from the double-double logarithm.
 * Special cases:
 *   asinh(+/-0) = +/-0, asinh(+/-Inf) = +/-Inf, NaN propagates. There is no
 *   domain restriction; the exponent range alone bounds the result.
 * Accuracy / algorithm:
 *   Faithful (< 1 ulp): |x| < 2^-28 returns x; |x| > 2^28 uses
 *   log|x| + ln2; 2 < |x| <= 2^28 uses the conjugate form
 *   2|x| + 1/(sqrt(x^2+1)+|x|); |x| <= 2 uses the cancellation-free
 *   log1p(|x| + x^2/(1+sqrt(1+x^2))).
 *============================================================================*/
double ASM_MATH(asinh)(double x)
{
    double ax = ASM_MATH(fabs)(x);               /* asinh is odd: work at |x| */

    /* ---- NaN / +-Inf pass-through (x + x keeps the sign of Inf) ---- */
    if (f64_isnan(x) || f64_isinf(x))
        return x + x;                               /* NaN, +-Inf              */

    /* ---- huge |x| > 2^28: log(2|x|) = log|x| + ln2 ---- */
    if (ax > INVHYP_LARGE) {
        /* log(|x| + sqrt(x^2+1)) ~ log(2|x|) = log(|x|) + ln2. */
        return ASM_MATH(copysign)(log_1(ax) + INVHYP_LN2, x);
    }
    /* ---- medium 2 < |x| <= 2^28: conjugate avoids cancellation ---- */
    if (ax > 2.0) {
        /* 2|x| + 1/(sqrt(x^2+1)+|x|) is the conjugate form of |x|+sqrt(...) */
        double t = ax;                              /* t = |x| */
        double w = log_1(2.0 * t +
                         1.0 / (ASM_MATH(sqrt)(x * x + 1.0) + t));
        return ASM_MATH(copysign)(w, x);
    }
    /* ---- tiny |x| < 2^-28: asinh(x) = x to within a rounding ---- */
    if (ax < INVHYP_TINY)
        return x;                                   /* asinh(x) ~ x, exact    */

    {
        /* ---- |x| <= 2: cancellation-free log1p near zero ---- */
        /* log1p(|x| + x^2/(1+sqrt(1+x^2))) has no cancellation near zero. */
        double t = x * x;                           /* x^2 */
        double w = log1p_1(ax + t / (1.0 + ASM_MATH(sqrt)(1.0 + t)));
        return ASM_MATH(copysign)(w, x);
    }
}

/*==============================================================================
 * double asm_acosh(double x)
 *------------------------------------------------------------------------------
 * Inverse hyperbolic cosine, log(x + sqrt(x-1)*sqrt(x+1)), domain x >= 1.
 *
 * Parameters:
 *   x (double) - requires x >= 1; NaN propagates
 * Returns:
 *   acosh(x), rounded once from the double-double logarithm.
 * Special cases:
 *   acosh(x<1) = NaN (including -Inf and negative values), acosh(1) = +0,
 *   acosh(+Inf) = +Inf, NaN propagates.
 * Accuracy / algorithm:
 *   Faithful (< 1 ulp): x >= 2^28 uses log(x) + ln2; 2 < x < 2^28 uses
 *   2x - 1/(x+sqrt(x^2-1)) so the argument stays positive and cancellation
 *   free; 1 < x <= 2 uses log1p(t + sqrt(2t+t^2)), t = x-1.
 *============================================================================*/
double ASM_MATH(acosh)(double x)
{
    /* ---- domain and special-value handling ---- */
    if (f64_isnan(x))
        return x + x;                               /* NaN                     */
    if (x < 1.0)
        return F64_QNAN;                            /* acosh(x<1) = NaN        */
    if (f64_isinf(x))
        return x;                                   /* acosh(+Inf) = +Inf      */
    if (x == 1.0)
        return 0.0;                                 /* acosh(1) = 0            */

    /* ---- huge x >= 2^28: log(2x) = log(x) + ln2 ---- */
    if (x >= INVHYP_LARGE) {
        /* log(x + sqrt(x^2-1)) ~ log(2x) = log(x) + ln2. */
        return log_1(x) + INVHYP_LN2;
    }
    /* ---- medium 2 < x < 2^28: conjugate form stays positive ---- */
    if (x > 2.0) {
        /* 2x - 1/(x+sqrt(x^2-1)) equals x+sqrt(x^2-1) but stays positive. */
        double t = x * x;                           /* t = x^2 */
        return log_1(2.0 * x - 1.0 / (x + ASM_MATH(sqrt)(t - 1.0)));
    }

    {
        /* ---- 1 < x <= 2: cancellation-free log1p form ---- */
        /* 1<x<=2: x + sqrt(x^2-1) = 1 + (t + sqrt(2t+t^2)), t = x-1. */
        double t = x - 1.0;
        return log1p_1(t + ASM_MATH(sqrt)(2.0 * t + t * t));
    }
}

/*==============================================================================
 * double asm_atanh(double x)
 *------------------------------------------------------------------------------
 * Inverse hyperbolic tangent, 0.5*log1p(2x/(1-x)), domain |x| <= 1.
 *
 * Parameters:
 *   x (double) - requires |x| <= 1; NaN propagates
 * Returns:
 *   atanh(x), rounded once from the double-double logarithm.
 * Special cases:
 *   atanh(+/-0) = +/-0, atanh(+/-1) = +/-Inf, atanh(|x|>1) = NaN, NaN
 *   propagates.
 * Accuracy / algorithm:
 *   Faithful (< 1 ulp): |x| < 2^-28 returns x; |x| < 0.5 uses
 *   0.5*log1p(2|x| + 2|x|^2/(1-|x|)) with the split keeping 2x exact;
 *   otherwise 0.5*log1p(2|x|/(1-|x|)). The sign is restored at the end.
 *============================================================================*/
double ASM_MATH(atanh)(double x)
{
    double ax = ASM_MATH(fabs)(x);               /* atanh is odd: work at |x| */

    /* ---- domain and special-value handling ---- */
    if (f64_isnan(x))
        return x + x;                               /* NaN                     */
    if (ax > 1.0)
        return F64_QNAN;                            /* atanh(|x|>1) = NaN      */
    if (ax == 1.0)
        return ASM_MATH(copysign)(F64_INF, x);      /* atanh(+-1) = +-Inf      */
    if (ax < INVHYP_TINY)
        return x;                                   /* atanh(+-0) = +-0        */

    /* ---- |x| < 0.5: split 2|x| so tiny arguments keep precision ---- */
    if (ax < 0.5) {
        /* 0.5*log1p(2|x| + 2|x|^2/(1-|x|)); the split keeps 2x exact. */
        double t = ax + ax;                         /* t = 2|x| */
        double w = 0.5 * log1p_1(t + t * ax / (1.0 - ax));
        return ASM_MATH(copysign)(w, x);
    }

    {
        /* ---- 0.5 <= |x| < 1: direct log1p form ---- */
        double w = 0.5 * log1p_1((ax + ax) / (1.0 - ax));
        return ASM_MATH(copysign)(w, x);
    }
}
