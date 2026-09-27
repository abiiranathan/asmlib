/*==============================================================================
 * exp.c - exponential family: exp, exp2, expm1
 *------------------------------------------------------------------------------
 * Freestanding, no libc/libm. The three routines share a double-double (two
 * term) polynomial core evaluated over a narrow reduced argument:
 *
 *   exp2(x): x = k + r,   |r| <= 1/2   ->  2^x = 2^k * 2^r
 *   exp(x) : x = k*ln2 + r, |r| <= ln2/2 -> e^x = 2^k * e^r
 *   expm1(x): (e^x - 1)/x as a polynomial for |x| <= 1/2, otherwise e^x - 1
 *             evaluated with a double-double residual so no cancellation
 *             survives the final subtraction.
 *
 * Coefficients are plain Taylor series for 2^r, e^r and (e^r-1)/r truncated
 * well below the double-double noise floor, so the only remaining error is the
 * final round to double: the results are faithful (< 1 ulp), and the special
 * values (Inf, NaN, signed zero, overflow to +Inf, underflow to +0) are exact.
 *============================================================================*/

#include "math_private.h"

/* --- double-double primitives (Dekker, no FMA required) ------------------ */

/*==============================================================================
 * static double two_sum(double a, double b, double *lo)
 *------------------------------------------------------------------------------
 * Error-free transform for addition: exact a + b with its rounding residual.
 *
 * Parameters:
 *   a  (double)   - first addend; finite
 *   b  (double)   - second addend; finite
 *   lo (double *) - out: residual, a + b == result + *lo
 * Returns:
 *   The correctly rounded value of a + b.
 * Special cases:
 *   NaN and Inf follow ordinary IEEE addition; *lo is meaningful only when the
 *   sum is finite.
 * Accuracy / algorithm:
 *   Branch-free Dekker/Knuth two-sum. With s = fl(a+b) and bb = fl(s-a), the
 *   residual is (a - (s - bb)) + (b - bb); exact unless a + b overflows.
 *============================================================================*/
/* a + b = hi + *lo exactly. */
static double two_sum(double a, double b, double *lo)
{
    double s = a + b;                       /* rounded sum */
    double bb = s - a;                      /* first-order error term */
    *lo = (a - (s - bb)) + (b - bb);        /* exact low-order residual */
    return s;
}

/*==============================================================================
 * static double two_prod(double a, double b, double *lo)
 *------------------------------------------------------------------------------
 * Error-free transform for multiplication: exact a * b with its residual.
 *
 * Parameters:
 *   a  (double)   - first factor; finite
 *   b  (double)   - second factor; finite
 *   lo (double *) - out: residual, a * b == result + *lo
 * Returns:
 *   The correctly rounded value of a * b.
 * Special cases:
 *   NaN/Inf propagate through the IEEE multiply; *lo is meaningful only when
 *   the product is finite and does not overflow.
 * Accuracy / algorithm:
 *   Dekker/Veltkamp two-product with the split multiplier 2^27 + 1, which
 *   splits each factor into 26-bit halves so every partial product is exact.
 *============================================================================*/
/* a * b = hi + *lo exactly (split radix 2^27 + 1). */
static double two_prod(double a, double b, double *lo)
{
    const double split = 134217729.0;       /* 2^27 + 1: Dekker splitter */
    double p = a * b;                       /* rounded high product */
    double ah = a * split;                  /* split a into ah + al ... */
    ah = ah - (ah - a);                     /* ... rounding ah down so al is exact */
    double al = a - ah;                     /* low part of a */
    double bh = b * split;                  /* split b into bh + bl ... */
    bh = bh - (bh - b);                     /* ... rounding bh down so bl is exact */
    double bl = b - bh;                     /* low part of b */
    *lo = ((ah * bh - p) + ah * bl + al * bh) + al * bl;  /* exact residual */
    return p;
}

/*==============================================================================
 * static double dd_mul(double ah, double al, double bh, double bl, double *lo)
 *------------------------------------------------------------------------------
 * Double-double multiply (ah + al) * (bh + bl).
 *
 * Parameters:
 *   ah, al (double)   - high/low limbs of the first operand
 *   bh, bl (double)   - high/low limbs of the second operand
 *   lo     (double *) - out: low limb; result == return + *lo
 * Returns:
 *   The high limb of the product.
 * Special cases:
 *   Inherits NaN/Inf behavior from two_prod and two_sum.
 * Accuracy / algorithm:
 *   two_prod on the high limbs followed by the cross terms ah*bl + al*bh; the
 *   al*bl term is dropped because it lies below 2^-106.
 *============================================================================*/
/* (ah + al) * (bh + bl) = hi + *lo, discarding the al*bl term (< 2^-106). */
static double dd_mul(double ah, double al, double bh, double bl, double *lo)
{
    double e;
    double p = two_prod(ah, bh, &e);        /* p + e = ah*bh exactly */
    e += ah * bl + al * bh;                 /* fold in the cross terms */
    double e2;
    p = two_sum(p, e, &e2);                 /* renormalise into p + e2 */
    *lo = e2;
    return p;
}

/*==============================================================================
 * static double dd_poly(const double *c, int n, double rh, double rl,
 *                       double *lo)
 *------------------------------------------------------------------------------
 * Horner evaluation of a double-double polynomial at (rh + rl).
 *
 * Parameters:
 *   c      (const double *) - coefficient array of (hi, lo) pairs, c[0..n]
 *   n      (int)            - highest coefficient index (polynomial degree)
 *   rh, rl (double)         - high/low limbs of the reduced argument
 *   lo     (double *)       - out: low limb; value == return + *lo
 * Returns:
 *   The high limb of c[0] + c[1]*r + ... + c[n]*r^n.
 * Special cases:
 *   No range restriction; inherits NaN/Inf behavior from the helpers.
 * Accuracy / algorithm:
 *   Each Horner step is a dd_mul followed by adding the (hi, lo) coefficient
 *   pair and a two_sum renormalisation.
 *============================================================================*/
/* Horner evaluation of c[0..n] * (rh + rl); coefficients are (hi, lo) pairs. */
static double dd_poly(const double *c, int n, double rh, double rl, double *lo)
{
    double hi = c[2 * n];                   /* leading coefficient, high limb */
    double low = c[2 * n + 1];              /* leading coefficient, low limb */

    for (int i = n - 1; i >= 0; i--) {       /* accumulate from the top down */
        double m;
        double h = dd_mul(hi, low, rh, rl, &m);   /* acc *= r */
        double e;
        h = two_sum(h, c[2 * i], &e);       /* add coefficient hi part   */
        e += m + c[2 * i + 1];              /* plus product lo + coeff lo */
        double e2;
        h = two_sum(h, e, &e2);             /* renormalise the accumulator */
        hi = h;
        low = e2;
    }
    *lo = low;
    return hi;
}

/* --- coefficient tables (hi, lo pairs), derived from the Taylor series --- */

/* 2^r = sum (ln2)^i/i! * r^i, valid to ~2^-70 on |r| <= 1/2. */
static const double C2[] = {
    0x1.0000000000000p+0, 0x0.0p+0,
    0x1.62e42fefa39efp-1, 0x1.abc9e3b39803fp-56,
    0x1.ebfbdff82c58fp-3, -0x1.5e43a53e44da3p-57,
    0x1.c6b08d704a0c0p-5, -0x1.d331627513351p-59,
    0x1.3b2ab6fba4e77p-7, 0x1.4e65df05a9f75p-62,
    0x1.5d87fe78a6731p-10, 0x1.0717f69a514bfp-66,
    0x1.430912f86c787p-13, 0x1.bd2c2a261ac8dp-67,
    0x1.ffcbfc588b0c7p-17, -0x1.e53ab8cde09c6p-71,
    0x1.62c0223a5c824p-20, -0x1.3800cfc92c41ep-79,
    0x1.b5253d395e7c4p-24, -0x1.2dac78d2d8038p-79,
    0x1.e4cf5158b8ecap-28, -0x1.204bc4d5a312dp-85,
    0x1.e8cac7351bb25p-32, -0x1.f8543350dc6f6p-87,
    0x1.c3bd650fc2986p-36, -0x1.d4a9781e85d12p-92,
    0x1.816193166d0f9p-40, 0x1.8a06b0c03dc6cp-94,
    0x1.314964d5878a9p-44, 0x1.cfc50d89572bbp-98,
    0x1.c36e843b04022p-49, -0x1.984ea80e5635bp-105,
    0x1.38e89ae79f8b4p-53, -0x1.b71c06c4d9c88p-107,
    0x1.98444b41c25a8p-58, -0x1.54f13bff8403fp-113,
    0x1.f7176bdb43696p-63, -0x1.4668963b45e1bp-118,
};

/* e^r = sum r^i/i! * r^i, valid to ~2^-75 on |r| <= 1/2. */
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

/* (e^r - 1)/r = sum r^m/(m+1)!, valid to ~2^-72 on |r| <= 1/2. */
static const double CQ[] = {
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
    0x1.2f49b46814157p-57, 0x1.2650f61dbdcb4p-112,
};

/* ln2 = LN2_HI + LN2_LO; the high part has 12 trailing zero mantissa bits so
 * k*LN2_HI is exact for |k| < 2^12 (every k we ever form). */
#define LN2_HI 0x1.62e42fefa3000p-1
#define LN2_LO 0x1.3de6af278ece6p-42
#define INV_LN2 0x1.71547652b82fep+0      /* log2(e) */

/*==============================================================================
 * static double exp_dd(double x, double *lo)
 *------------------------------------------------------------------------------
 * Double-double exponential core: e^x = hi + *lo.
 *
 * Parameters:
 *   x  (double)   - exponent; must already be inside the caller's finite
 *                   overflow/underflow window
 *   lo (double *) - out: low limb; e^x == result + *lo
 * Returns:
 *   The high limb of e^x.
 * Special cases:
 *   No argument screening here; NaN/Inf propagate, and scaling may still
 *   overflow to +Inf or underflow to +0 for extreme x.
 * Accuracy / algorithm:
 *   k = rint(x/ln2), r = x - k*ln2 as a double-double (k*LN2_HI is exact),
 *   then a degree-18 double-double Taylor polynomial for e^r, scaled by 2^k.
 *   Faithful to < 1 ulp.
 *============================================================================*/
/* e^x as hi + *lo, with no argument restriction beyond the caller's range. */
static double exp_dd(double x, double *lo)
{
    /* ---- range reduction: k = round(x/ln2), r = x - k*ln2 ---- */
    double kd = ASM_MATH(rint)(x * INV_LN2);    /* k as a double, nearest even */
    int k = (int)kd;                            /* integer exponent */

    /* r = x - k*ln2 as a double-double; k*LN2_HI is exact. */
    double kh = kd * LN2_HI;                    /* exact high part of k*ln2 */
    double e1;
    double rhi = two_sum(x, -kh, &e1);          /* x - kh = rhi + e1 (exact) */
    double kl = kd * LN2_LO;                    /* low part of k*ln2 */
    double e2;
    double r = two_sum(rhi, e1 - kl, &e2);      /* r = r + e2 */

    /* ---- evaluate e^r and scale by 2^k ---- */
    double plo;
    double phi = dd_poly(CE, 18, r, e2, &plo);  /* e^r, degree-18 polynomial */
    *lo = ASM_MATH(scalbn)(plo, k);             /* exact power-of-two scale */
    return ASM_MATH(scalbn)(phi, k);
}

/*==============================================================================
 * double ASM_MATH(exp2)(double x)
 *------------------------------------------------------------------------------
 * 2^x. Decomposes x into an integer k and r in [-1/2, 1/2], evaluates 2^r with
 * a double-double Taylor polynomial and scales by 2^k (exact exponent bump).
 * Overflow saturates to +Inf, underflow to +0.
 *
 * Parameters:
 *   x (double) - exponent; any value, including NaN and +-Inf
 * Returns:
 *   2^x; +Inf for large x, +0 for very negative x, x (quieted) for NaN.
 * Special cases:
 *   exp2(NaN) = NaN; exp2(+Inf) = +Inf; exp2(-Inf) = +0; overflow to +Inf;
 *   underflow to +0.
 * Accuracy / algorithm:
 *   k = rint(x), r = x - k exactly (Sterbenz), degree-18 double-double
 *   polynomial for 2^r, then scalbn(., k). Faithful to < 1 ulp.
 *============================================================================*/
double ASM_MATH(exp2)(double x)
{
    /* ---- special-case and overflow/underflow screening ---- */
    if (f64_isnan(x))
        return x;                                   /* NaN propagates */
    if (x > 1024.0)
        return F64_INF;                             /* +Inf too */
    if (x < -1075.0)
        return 0.0;                                 /* underflow, -Inf too */

    /* ---- reduction: k = rint(x), r = x - k in [-1/2, 1/2] ---- */
    double kd = ASM_MATH(rint)(x);
    int k = (int)kd;                                /* integer exponent */
    double r = x - kd;                              /* exact by Sterbenz */
    double lo;                                      /* unused: < 1/2 ulp */
    /* ---- evaluate 2^r and scale by 2^k ---- */
    return ASM_MATH(scalbn)(dd_poly(C2, 18, r, 0.0, &lo), k);
}

/*==============================================================================
 * double ASM_MATH(exp)(double x)
 *------------------------------------------------------------------------------
 * e^x. Reduces x = k*ln2 + r with |r| <= ln2/2 using a two-part ln2, then
 * scales a double-double e^r polynomial by 2^k.
 *
 * Parameters:
 *   x (double) - exponent; any value, including NaN and +-Inf
 * Returns:
 *   e^x; +Inf when x overflows, +0 underflowing; +Inf for x = +Inf and +0 for
 *   x = -Inf; NaN propagates.
 * Special cases:
 *   exp(NaN) = NaN; exp(+Inf) = +Inf; exp(-Inf) = +0; overflow to +Inf at
 *   x > ~709.78; underflow to +0 below ~-745.13; exp(+0) = exp(-0) = 1.
 * Accuracy / algorithm:
 *   exp_dd() core: k = rint(x/ln2), double-double r = x - k*ln2, degree-18
 *   double-double Taylor polynomial, scalbn by 2^k. Faithful to < 1 ulp.
 *============================================================================*/
double ASM_MATH(exp)(double x)
{
    /* ---- special-case and overflow/underflow screening ---- */
    if (f64_isnan(x))
        return x;                                   /* NaN propagates */
    if (f64_isinf(x))
        return x > 0 ? F64_INF : 0.0;               /* e^+Inf / e^-Inf */
    if (x > 710.0)
        return F64_INF;                             /* overflow saturates */
    if (x < -746.0)
        return 0.0;                                 /* underflow flushes to +0 */

    /* ---- general path: double-double exponential core ---- */
    double lo;
    return exp_dd(x, &lo);                          /* lo is below 1/2 ulp */
}

/*==============================================================================
 * double ASM_MATH(expm1)(double x)
 *------------------------------------------------------------------------------
 * e^x - 1, accurate for |x| near zero. A polynomial in x (evaluated as
 * x * (e^x-1)/x) is used for |x| <= 1/2; beyond that e^x - 1 is formed from
 * the double-double exponential so the subtraction never loses significance.
 *
 * Parameters:
 *   x (double) - argument; any value, including NaN and +-Inf
 * Returns:
 *   e^x - 1; +Inf on overflow; -1 for x = -Inf and for very negative x;
 *   +Inf for x = +Inf; NaN propagates.
 * Special cases:
 *   expm1(NaN) = NaN; expm1(+Inf) = +Inf; expm1(-Inf) = -1; expm1(+-0) = +-0
 *   (sign preserved); overflow to +Inf; underflow tends to -1.
 * Accuracy / algorithm:
 *   |x| <= 1/2: x * Q(x) with Q = (e^x-1)/x, degree-18 double-double
 *   polynomial (no cancellation). Otherwise the double-double exp_dd() result
 *   is reduced by 1 and renormalised. Faithful to < 1 ulp.
 *============================================================================*/
double ASM_MATH(expm1)(double x)
{
    /* ---- special-case and overflow/underflow screening ---- */
    if (f64_isnan(x))
        return x;                                   /* NaN propagates */
    if (f64_isinf(x))
        return x > 0 ? F64_INF : -1.0;              /* e^+Inf-1 / e^-Inf-1 */
    if (x > 710.0)
        return F64_INF;                             /* overflow saturates */
    if (x < -750.0)
        return -1.0;                                /* e^x underflows: -1 */

    if (ASM_MATH(fabs)(x) <= 0.5) {
        /* ---- small |x|: x * (e^x-1)/x, cancellation-free ---- */
        double qlo;
        double q = dd_poly(CQ, 18, x, 0.0, &qlo);   /* q = (e^x-1)/x */
        double e;
        double h = two_prod(x, q, &e);              /* x*q = h + e */
        e += x * qlo;                               /* fold the low product */
        double e2;
        return two_sum(h, e, &e2);                  /* renormalise x*q */
    }

    /* ---- large |x|: form e^x - 1 from the double-double exponential ---- */
    double elo;
    double ehi = exp_dd(x, &elo);
    if (f64_isinf(ehi))
        return F64_INF;
    double e;
    double h = two_sum(ehi, -1.0, &e);              /* e^x - 1 = h + e */
    e += elo;                                       /* add exp's low limb */
    double e2;
    return two_sum(h, e, &e2);                      /* renormalise the result */
}
