/*==============================================================================
 * hyperbolic.c - hyperbolic functions: sinh, cosh, tanh
 *------------------------------------------------------------------------------
 * Freestanding, no libc/libm. The three routines are built on a local
 * double-double (two-term) exponential kernel so that every result is rounded
 * to double exactly once, at the very end:
 *
 *   sinh(x) = 0.5*(e^x - e^-x)
 *   cosh(x) = 0.5*(e^x + e^-x)
 *   tanh(x) = (e^2x - 1)/(e^2x + 1)
 *
 * The double-double exponential uses the same ln2 splitting, Taylor
 * polynomial and Dekker arithmetic as exp.c. For arguments so large that e^x
 * would overflow while sinh/cosh are still finite (|x| in
 * (ln DBL_MAX, ln(2 DBL_MAX)]), the dominant term is evaluated as
 * 0.5*e^x = e^(x-ln2) using the double-double ln2, so there is no
 * intermediate overflow. Results saturate to +-Inf; signed zero, Inf and NaN
 * follow IEEE-754. No errno, no FP environment, no globals.
 *============================================================================*/

#include "math_private.h"

/* --- double-double primitives (Dekker; no FMA required) ------------------ */

typedef struct {
    double hi, lo;
} dd;

/*==============================================================================
 * static double dd_two_sum(double a, double b, double *lo)
 *------------------------------------------------------------------------------
 * a + b = hi + *lo exactly.
 *
 * Parameters:
 *   a  (double)   - first addend
 *   b  (double)   - second addend
 *   lo (double *) - out: exact error a + b - (returned high part)
 * Returns:
 *   the rounded value fl(a + b), with *lo carrying the exact residual.
 * Special cases:
 *   Correct for all finite and infinite inputs; if a + b overflows the error
 *   term is not meaningful, but no caller forms such a sum.
 * Accuracy / algorithm:
 *   Knuth/Dekker two-sum: exact, so (returned value) + *lo == a + b in exact
 *   arithmetic, using only rounded operations and no FMA.
 *============================================================================*/
static double dd_two_sum(double a, double b, double *lo)
{
    double s = a + b;
    double bb = s - a;
    *lo = (a - (s - bb)) + (b - bb);
    return s;
}

/*==============================================================================
 * static double dd_two_prod(double a, double b, double *lo)
 *------------------------------------------------------------------------------
 * a * b = hi + *lo exactly (split radix 2^27 + 1).
 *
 * Parameters:
 *   a  (double)   - multiplicand
 *   b  (double)   - multiplier
 *   lo (double *) - out: exact error a*b - (returned high part)
 * Returns:
 *   the rounded value fl(a * b), with *lo carrying the exact residual.
 * Special cases:
 *   The split is exact only while |a|,|b| stay below ~2^996 (so a*split does
 *   not overflow); every call site uses bounded operands. Overflowing products
 *   are not supported.
 * Accuracy / algorithm:
 *   Dekker product: split both factors into (hi, lo) radix-2^27 pieces and
 *   evaluate the cross terms. (returned value) + *lo == a * b exactly.
 *============================================================================*/
static double dd_two_prod(double a, double b, double *lo)
{
    const double split = 134217729.0;
    double p = a * b;
    double ah = a * split;
    ah = ah - (ah - a);
    double al = a - ah;
    double bh = b * split;
    bh = bh - (bh - b);
    double bl = b - bh;
    *lo = ((ah * bh - p) + ah * bl + al * bh) + al * bl;
    return p;
}

/*==============================================================================
 * static dd dd_add(dd a, dd b)
 *------------------------------------------------------------------------------
 * Adds two double-double numbers, returning a renormalised double-double.
 *
 * Parameters:
 *   a (dd) - first addend
 *   b (dd) - second addend
 * Returns:
 *   a + b as a normalised double-double with |lo| <= ulp(hi)/2.
 * Special cases:
 *   Follows IEEE-754 for Inf/NaN; the hyperbolic routines do not pass such
 *   values here.
 * Accuracy / algorithm:
 *   "Sloppy" Dekker add: two-sum the high parts, absorb both low parts in the
 *   error, then a second two-sum renormalises the unevaluated sum.
 *============================================================================*/
static dd dd_add(dd a, dd b)
{
    double e;
    double s = dd_two_sum(a.hi, b.hi, &e);
    e += a.lo + b.lo;
    double e2;
    s = dd_two_sum(s, e, &e2);
    return (dd){ s, e2 };
}

/*==============================================================================
 * static dd dd_sub(dd a, dd b)
 *------------------------------------------------------------------------------
 * Subtracts one double-double from another.
 *
 * Parameters:
 *   a (dd) - minuend
 *   b (dd) - subtrahend
 * Returns:
 *   a - b as a normalised double-double.
 * Special cases:
 *   Negating b is exact, so special values behave exactly as in dd_add.
 * Accuracy / algorithm:
 *   dd_add(a, -b).
 *============================================================================*/
static dd dd_sub(dd a, dd b)
{
    return dd_add(a, (dd){ -b.hi, -b.lo });
}

/*==============================================================================
 * static dd dd_scale(dd a, double s)
 *------------------------------------------------------------------------------
 * Multiplies a double-double by a power-of-two scale factor.
 *
 * Parameters:
 *   a (dd)     - value to scale
 *   s (double) - power of two (0.5 at every call site)
 * Returns:
 *   a * s as a double-double.
 * Special cases:
 *   Exact when s is a power of two (all the scaling used here is); a general
 *   s would round both components and break the error-free property.
 * Accuracy / algorithm:
 *   Scale each component independently; both products are exact.
 *============================================================================*/
static dd dd_scale(dd a, double s)
{
    return (dd){ a.hi * s, a.lo * s };
}

/*==============================================================================
 * static dd dd_div(dd n, dd d)
 *------------------------------------------------------------------------------
 * Divides one double-double by another using a first quotient estimate plus a
 * Newton-style residual correction.
 *
 * Parameters:
 *   n (dd) - numerator (assumed finite)
 *   d (dd) - denominator (assumed finite and nonzero)
 * Returns:
 *   n / d as a normalised double-double.
 * Special cases:
 *   n == 0 gives (0,0). d.hi == 0 would divide by zero; the tanh caller always
 *   has d = e^(2a)+1 >= 2. Inf/NaN inputs are not supported.
 * Accuracy / algorithm:
 *   q0 = n.hi/d.hi, subtract q0*d (formed in double-double) from n, then add
 *   the residual corrections q1 + q2; good to ~1 ulp of the quotient.
 *============================================================================*/
static dd dd_div(dd n, dd d)
{
    double q0 = n.hi / d.hi;                    /* first estimate of n/d */
    double plo;
    double phi = dd_two_prod(q0, d.hi, &plo);   /* q0 * d.hi, exact hi+lo */
    plo += q0 * d.lo;                           /* fold in q0 * d.lo */
    dd rem = dd_sub(n, (dd){ phi, plo });   /* n - q0*d */
    double q1 = rem.hi / d.hi;                  /* leading correction term */
    double e;
    double s = dd_two_sum(q0, q1, &e);
    double q2 = (e + rem.lo) / d.hi;            /* trailing correction term */
    double e2;
    s = dd_two_sum(s, q2, &e2);
    return (dd){ s, e2 };
}

/*==============================================================================
 * static double dd_round(dd a)
 *------------------------------------------------------------------------------
 * Rounds a double-double to the nearest double.
 *
 * Parameters:
 *   a (dd) - normalised double-double to round
 * Returns:
 *   the correctly rounded double fl(a.hi + a.lo) nearest to a.
 * Special cases:
 *   Inf/NaN propagate. Because |a.lo| <= ulp(a.hi)/2 the sum is a single
 *   rounding step, so the result is faithful to the double-double value.
 * Accuracy / algorithm:
 *   One addition of the (dependent) unevaluated sum.
 *============================================================================*/
static double dd_round(dd a)
{
    return a.hi + a.lo;
}

/* --- double-double exponential kernel ------------------------------------ */

/*==============================================================================
 * static double dd_mul2(double ah, double al, double bh, double bl, double *lo)
 *------------------------------------------------------------------------------
 * Multiplies two double-double numbers, returning the high part and *lo.
 *
 * Parameters:
 *   ah (double)   - high part of the first factor
 *   al (double)   - low part of the first factor
 *   bh (double)   - high part of the second factor
 *   bl (double)   - low part of the second factor
 *   lo (double *) - out: low part of the product
 * Returns:
 *   the high part of (ah+al)*(bh+bl).
 * Special cases:
 *   Used only inside the exponential kernel, where operands are bounded; no
 *   Inf/NaN reach it and the discarded term cannot overflow.
 * Accuracy / algorithm:
 *   Exact product ah*bh, add the cross terms ah*bl + al*bh, renormalise with
 *   two_sum; the omitted al*bl term is below 2^-106 relative.
 *============================================================================*/
static double dd_mul2(double ah, double al, double bh, double bl, double *lo)
{
    double e;
    double p = dd_two_prod(ah, bh, &e);         /* exact ah*bh */
    e += ah * bl + al * bh;                     /* cross terms; al*bl dropped */
    double e2;
    p = dd_two_sum(p, e, &e2);                  /* renormalise */
    *lo = e2;
    return p;
}

/*==============================================================================
 * static double dd_poly(const double *c, int n, double rh, double rl, double *lo)
 *------------------------------------------------------------------------------
 * Horner evaluation of a polynomial at the double-double point (rh + rl),
 * with coefficients given as double-double pairs.
 *
 * Parameters:
 *   c  (const double *) - coefficients as (hi, lo) pairs: c[2i], c[2i+1]
 *   n  (int)            - polynomial degree
 *   rh (double)         - high part of the argument
 *   rl (double)         - low part of the argument
 *   lo (double *)       - out: low part of the result
 * Returns:
 *   the high part of sum_i c[i] * (rh+rl)^i.
 * Special cases:
 *   Called only with n >= 0 and |rh+rl| <= 1/2, so it cannot overflow.
 * Accuracy / algorithm:
 *   Each Horner step multiplies the accumulator by (rh+rl) with dd_mul2 and
 *   adds c[i] with two_sum; carries roughly 2^-106 of error per step.
 *============================================================================*/
static double dd_poly(const double *c, int n, double rh, double rl, double *lo)
{
    double hi = c[2 * n];                       /* leading coefficient (hi) */
    double low = c[2 * n + 1];                  /* leading coefficient (lo) */

    for (int i = n - 1; i >= 0; i--) {
        double m;
        double h = dd_mul2(hi, low, rh, rl, &m);   /* acc * (rh+rl) */
        double e;
        h = dd_two_sum(h, c[2 * i], &e);        /* + c[i].hi */
        e += m + c[2 * i + 1];                  /* plus both low parts */
        double e2;
        h = dd_two_sum(h, e, &e2);              /* renormalise */
        hi = h;
        low = e2;
    }
    *lo = low;
    return hi;
}

/* e^r = sum r^i/i!, valid to ~2^-75 on |r| <= 1/2. */
static const double CE[] = {
    0x1.0000000000000p+0, 0x0.0p+0,
    0x1.0000000000000p+0, 0x0.0p+0,
    0x1.0000000000000p-1, 0x0.0p+0,
    0x1.5555555555555p-3, 0x1.5555555555555p-57,
    0x1.5555555555555p-5, 0x1.5555555555555p-59,
    0x1.1111111111111p-7, 0x1.1111111111111p-63,
    0x1.6c16c16c16c17p-10, -0x1.f49f49f49f49fp-65,
    0x1.a01a01a01a01ap-13, 0x1.a01a01a01a01ap-73,
    0x1.a01a01a01a01ap-16, 0x1.a01a01a01a01ap-76,
    0x1.71de3a556c734p-19, -0x1.c154f8ddc6c00p-73,
    0x1.27e4fb7789f5cp-22, 0x1.cbbc05b4fa99ap-76,
    0x1.ae64567f544e4p-26, -0x1.c062e06d1f209p-80,
    0x1.1eed8eff8d898p-29, -0x1.2aec959e14c06p-83,
    0x1.6124613a86d09p-33, 0x1.f28e0cc748ebep-87,
    0x1.93974a8c07c9dp-37, 0x1.05d6f8a2efd1fp-92,
    0x1.ae7f3e733b81fp-41, 0x1.1d8656b0ee8cbp-97,
    0x1.ae7f3e733b81fp-45, 0x1.1d8656b0ee8cbp-101,
    0x1.952c77030ad4ap-49, 0x1.ac981465ddc6cp-103,
    0x1.6827863b97d97p-53, 0x1.eec01221a8b0bp-107,
};

/* ln2 = LN2_HI + LN2_LO; the high part has 12 trailing zero mantissa bits. */
#define LN2_HI 0x1.62e42fefa3000p-1
#define LN2_LO 0x1.3de6af278ece6p-42
#define INV_LN2 0x1.71547652b82fep+0      /* log2(e) */

/*==============================================================================
 * static double exp_dd_full(double xh, double xl, double *lo)
 *------------------------------------------------------------------------------
 * e^x as a double-double (hi + lo), for x supplied exactly as xh + xl.
 *
 * Parameters:
 *   xh (double)   - high part of the exponent
 *   xl (double)   - low part of the exponent
 *   lo (double *) - out: low part of the result
 * Returns:
 *   the high part of e^(xh+xl).
 * Special cases:
 *   Overflow/underflow are left to the closing scalbn; the polynomial is
 *   evaluated on |r| <= 1/2 and cannot overflow by itself.
 * Accuracy / algorithm:
 *   Round x/ln2 to an integer k, reduce r = x - k*ln2 in double-double using
 *   the split ln2 constants, evaluate the degree-18 CE series, then scale by
 *   2^k exactly. Good to a few 2^-106 relative.
 *============================================================================*/
static double exp_dd_full(double xh, double xl, double *lo)
{
    double kd = ASM_MATH(rint)(xh * INV_LN2);   /* k ~ x/ln2, ties to even */
    int k = (int)kd;

    double kh = kd * LN2_HI;                    /* exact */
    double e1;
    double rhi = dd_two_sum(xh, -kh, &e1);      /* r = x - k*ln2 (head) */
    double kl = kd * LN2_LO;
    double e2;
    double r = dd_two_sum(rhi, (e1 - kl) + xl, &e2);  /* exact reduced arg */

    double plo;
    double phi = dd_poly(CE, 18, r, e2, &plo);  /* e^r = sum r^i/i! */
    *lo = ASM_MATH(scalbn)(plo, k);             /* low half scaled by 2^k */
    return ASM_MATH(scalbn)(phi, k);            /* high half scaled by 2^k */
}

/*==============================================================================
 * static dd expdd(double x)
 *------------------------------------------------------------------------------
 * e^x as a normalised double-double for a single double argument.
 *
 * Parameters:
 *   x (double) - exponent
 * Returns:
 *   e^x as (hi, lo), covering the full finite exponential range.
 * Special cases:
 *   Overflow returns +Inf (with a zero low part); underflow returns 0. No
 *   signal is raised and Inf/NaN inputs are not passed by the callers.
 * Accuracy / algorithm:
 *   Thin wrapper that calls exp_dd_full with a zero low word.
 *============================================================================*/
static dd expdd(double x)
{
    double lo;
    double hi = exp_dd_full(x, 0.0, &lo);
    return (dd){ hi, lo };
}

/* ln(DBL_MAX): above it e^x overflows though sinh/cosh may still be finite. */
#define EXP_MID 709.782712893384

/*==============================================================================
 * double asm_sinh(double x)
 *------------------------------------------------------------------------------
 * Hyperbolic sine, 0.5*(e^x - e^-x), evaluated in double-double arithmetic.
 *
 * Parameters:
 *   x (double) - any value; NaN and +-Inf are passed through unchanged
 * Returns:
 *   sinh(x), rounded once from the double-double intermediate.
 * Special cases:
 *   sinh(+/-0) = +/-0, sinh(+/-Inf) = +/-Inf, NaN propagates. Result overflows
 *   to +/-Inf once |x| > ln(2*DBL_MAX) ~ 710.4759.
 * Accuracy / algorithm:
 *   Faithful (< 1 ulp): |x| < 2^-28 returns x (the cubic term is below 1 ulp);
 *   the general path subtracts the two exponentials in double-double so the
 *   cancellation near zero is absorbed; for ln(DBL_MAX) < |x| < 711 the half
 *   exponential e^(|x|-ln2) avoids an intermediate overflow.
 *============================================================================*/
double ASM_MATH(sinh)(double x)
{
    /* ---- magnitude and special-value dispatch ---- */
    uint64_t axb = f64_bits(x) & F64_ABS;

    if (axb >= F64_EXP)                             /* Inf or NaN */
        return x;

    /* ---- tiny argument: sinh(x) = x to within a final rounding ---- */
    if (axb < 0x3e30000000000000ULL)                /* |x| < 2^-28: sinh ~ x */
        return x;

    double a = ASM_MATH(fabs)(x);                   /* sinh is odd: use |x| */
    double r;

    /* ---- cancellation-free difference of the two exponentials ---- */
    if (a < EXP_MID) {
        dd e = expdd(a);                            /* e^|x| */
        dd f = expdd(-a);                           /* e^-|x| */
        r = dd_round(dd_scale(dd_sub(e, f), 0.5));  /* 0.5*(e^|x| - e^-|x|) */
    } else if (a < 711.0) {
        /* ---- overflow-safe half-exponential: 0.5*e^a = e^(a-ln2) ---- */
        dd y = dd_sub((dd){ a, 0.0 }, (dd){ LN2_HI, LN2_LO });
        double lo;                                  /* 0.5*e^a = e^(a-ln2) */
        r = exp_dd_full(y.hi, y.lo, &lo) + lo;
    } else {
        /* ---- saturation: sinh overflows for |x| > ln(2*DBL_MAX) ---- */
        r = F64_INF;
    }

    return f64_signbit(x) ? -r : r;                 /* restore the odd sign */
}

/*==============================================================================
 * double asm_cosh(double x)
 *------------------------------------------------------------------------------
 * Hyperbolic cosine, 0.5*(e^x + e^-x), evaluated in double-double arithmetic.
 *
 * Parameters:
 *   x (double) - any value; NaN propagates and +-Inf saturates
 * Returns:
 *   cosh(x), rounded once from the double-double intermediate.
 * Special cases:
 *   cosh(+/-0) = 1, cosh(+/-Inf) = +Inf, NaN propagates. Result overflows to
 *   +Inf once |x| > ln(2*DBL_MAX) ~ 710.4759.
 * Accuracy / algorithm:
 *   Faithful (< 1 ulp): both exponentials are formed in double-double and
 *   summed, so there is no cancellation; for ln(DBL_MAX) < |x| < 711 the half
 *   exponential e^(|x|-ln2) avoids an intermediate overflow.
 *============================================================================*/
double ASM_MATH(cosh)(double x)
{
    /* ---- magnitude and special-value dispatch ---- */
    uint64_t axb = f64_bits(x) & F64_ABS;

    if (axb >= F64_EXP) {                           /* Inf or NaN */
        if (axb > F64_EXP)
            return x;                               /* NaN propagates */
        return F64_INF;                             /* cosh(+-Inf) = +Inf */
    }

    double a = ASM_MATH(fabs)(x);                   /* cosh is even: use |x| */

    /* ---- cancellation-free sum of the two exponentials ---- */
    if (a < EXP_MID) {
        dd e = expdd(a);                            /* e^|x| */
        dd f = expdd(-a);                           /* e^-|x| */
        return dd_round(dd_scale(dd_add(e, f), 0.5));   /* 0.5*(e^|x|+e^-|x|) */
    }
    /* ---- overflow-safe half-exponential: 0.5*e^a = e^(a-ln2) ---- */
    if (a < 711.0) {
        dd y = dd_sub((dd){ a, 0.0 }, (dd){ LN2_HI, LN2_LO });
        double lo;                                  /* 0.5*e^a = e^(a-ln2) */
        return exp_dd_full(y.hi, y.lo, &lo) + lo;
    }
    return F64_INF;                                 /* saturation */
}

/*==============================================================================
 * double asm_tanh(double x)
 *------------------------------------------------------------------------------
 * Hyperbolic tangent, (e^2x - 1)/(e^2x + 1), evaluated in double-double
 * arithmetic.
 *
 * Parameters:
 *   x (double) - any value; NaN propagates and +-Inf saturates
 * Returns:
 *   tanh(x), rounded once from the double-double intermediate.
 * Special cases:
 *   tanh(+/-0) = +/-0, tanh(+/-Inf) = +/-1, NaN propagates. |x| >= 22 already
 *   rounds to +/-1, so the exponential ratio is only formed below that.
 * Accuracy / algorithm:
 *   Faithful (< 1 ulp): |x| < 2^-55 returns x*(1+x), a two-term expansion whose
 *   residual is below 1 ulp; otherwise the ratio is built from e^(2a) in
 *   double-double and divided, keeping e^(2a)-1 cancellation-free.
 *============================================================================*/
double ASM_MATH(tanh)(double x)
{
    /* ---- raw bits for both the magnitude and the sign ---- */
    uint64_t b = f64_bits(x);
    uint64_t axb = b & F64_ABS;

    if (axb >= F64_EXP) {
        if (axb > F64_EXP)
            return x;                               /* NaN propagates */
        return f64_from_bits((b & F64_SIGN) | ((uint64_t)1023 << 52)); /* +/-1 */
    }

    double a = ASM_MATH(fabs)(x);                   /* tanh is odd: use |x| */
    double z;

    if (a < 0x1p-55)                                /* |x| < 2^-55: tanh ~ x */
        return x * (1.0 + x);                       /* cubic term as 1+x */

    /* ---- e^(2a) ratio, with t/d keeping e^(2a)-1 cancellation-free ---- */
    if (a < 22.0) {
        dd e2 = expdd(2.0 * a);                     /* e^(2a) */
        dd t = dd_sub(e2, (dd){ 1.0, 0.0 });        /* e^(2a) - 1 */
        dd d = dd_add(t, (dd){ 2.0, 0.0 });         /* e^(2a) + 1 */
        z = dd_round(dd_div(t, d));                 /* (e^(2a)-1)/(e^(2a)+1) */
    } else {
        z = 1.0;                                    /* rounds to 1 exactly */
    }

    return f64_signbit(x) ? -z : z;                 /* restore the odd sign */
}
