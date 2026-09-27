/*==============================================================================
 * pow.c - x raised to the power y
 *------------------------------------------------------------------------------
 * Freestanding, no libc/libm, no errno, no FP environment, no mutable global
 * state. All helpers are static.
 *
 * For finite positive x the result is built as 2^(y*log2(x)). To keep the
 * final rounding faithful even when x is close to 1 and |y| is large, the
 * logarithm is evaluated as a double-double:
 *
 *     log2(x) = k + 2*atanh(s)/ln2,   s = (m-1)/(m+1),  x = m*2^k
 *
 * with m in [sqrt(1/2), sqrt(2)), and the atanh series evaluated in Dekker
 * double-double arithmetic. The product y*log2(x) is likewise held as a
 * double-double, split into an integer k and a fraction f in [-1/2, 1/2], and
 * 2^f is produced by a double-double Taylor polynomial before an exact
 * power-of-two scaling. Negative bases are handled through |x| and the
 * parity of an integral exponent, exactly as C99 requires.
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
 *   Dekker/Veltkamp two-product using a mantissa bit mask to split each factor
 *   into high and low parts (rather than a large multiplier), so the split
 *   cannot overflow for extreme finite operands; all partial products are
 *   exact and the discarded low-order terms are folded back in.
 *============================================================================*/
/* a * b = hi + *lo exactly. The split uses a bit mask rather than a large
 * multiplier so it cannot overflow for extreme (but finite) operands. */
static double two_prod(double a, double b, double *lo)
{
    const uint64_t mask = 0xfffffffff8000000ULL;    /* keep top 26 sig bits */
    double p = a * b;                       /* rounded high product */
    double ah = f64_from_bits(f64_bits(a) & mask);  /* a truncated to high part */
    double al = a - ah;                     /* a's low part, exact */
    double bh = f64_from_bits(f64_bits(b) & mask);  /* b truncated to high part */
    double bl = b - bh;                     /* b's low part, exact */
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
/* (ah + al) * (bh + bl) = hi + *lo, dropping the al*bl term (< 2^-106). */
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
 * static double dd_div(double nh, double nl, double dh, double dl, double *lo)
 *------------------------------------------------------------------------------
 * Double-double divide (nh + nl) / (dh + dl).
 *
 * Parameters:
 *   nh, nl (double)   - high/low limbs of the numerator
 *   dh, dl (double)   - high/low limbs of the denominator; dh != 0
 *   lo     (double *) - out: low limb; result == return + *lo
 * Returns:
 *   The high limb of the quotient.
 * Special cases:
 *   Inherits NaN/Inf/zero-divide behavior from the underlying IEEE operations.
 * Accuracy / algorithm:
 *   First quotient q0 = nh/dh, then one Newton correction from the exact
 *   residual nh - q0*d, renormalised as q0 + q1.
 *============================================================================*/
/* (nh + nl) / (dh + dl) = hi + *lo, with a single Newton correction. */
static double dd_div(double nh, double nl, double dh, double dl, double *lo)
{
    double q0 = nh / dh;                    /* first quotient approximation */
    double pl;
    double ph = two_prod(q0, dh, &pl);      /* q0*dh = ph + pl exactly */
    pl += q0 * dl;                          /* fold in q0*dl */
    double rl;
    double rh = two_sum(nh, -ph, &rl);      /* residual of nh - q0*dh */
    rl += nl - pl;                          /* include both low limbs */
    double q1 = (rh + rl) / dh;             /* Newton correction term */
    double e;
    double q = two_sum(q0, q1, &e);         /* quotient + its residual */
    *lo = e;
    return q;
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
        h = two_sum(h, c[2 * i], &e);       /* add coefficient hi part    */
        e += m + c[2 * i + 1];              /* plus product lo + coeff lo */
        double e2;
        h = two_sum(h, e, &e2);             /* renormalise the accumulator */
        hi = h;
        low = e2;
    }
    *lo = low;
    return hi;
}

/* --- constants ----------------------------------------------------------- */

/* sqrt(1/2): the reduction split point. */
#define LOG_SQRT_HALF 0x1.6a09e667f3bcdp-1

/* 1/ln2 as a double-double. */
#define IVLN2_HI 0x1.71547652b82fep+0
#define IVLN2_LO 0x1.777d0ffda0d24p-56

/* Q(z) = 1 + z/3 + z^2/5 + z^3/7 + ... = atanh(sqrt(z))/sqrt(z); the series
 * converges quickly because |z| <= 0.03 over the reduced range. Coefficients
 * are (hi, lo) pairs. */
static const double QC[] = {
    0x1.0000000000000p+0, 0x0.0p+0,
    0x1.5555555555555p-2, 0x1.5555555555555p-56,
    0x1.999999999999ap-3, -0x1.999999999999ap-57,
    0x1.2492492492492p-3, 0x1.2492492492492p-57,
    0x1.c71c71c71c71cp-4, 0x1.c71c71c71c71cp-58,
    0x1.745d1745d1746p-4, -0x1.745d1745d1746p-59,
    0x1.3b13b13b13b14p-4, -0x1.3b13b13b13b14p-58,
    0x1.1111111111111p-4, 0x1.1111111111111p-60,
    0x1.e1e1e1e1e1e1ep-5, 0x1.e1e1e1e1e1ep-61,
    0x1.af286bca1af28p-5, 0x1.af286bca1af28p-59,
    0x1.8618618618618p-5, 0x1.8618618618618p-59,
    0x1.642c8590b2164p-5, 0x1.642c8590b2164p-60,
    0x1.47ae147ae147bp-5, -0x1.eb851eb851eb8p-61,
    0x1.2f684bda12f68p-5, 0x1.2f684bda12f68p-59,
    0x1.1a7b9611a7b96p-5, 0x1.1a7b9611a7b96p-61,
    0x1.0842108421084p-5, 0x1.0842108421084p-60,
    0x1.f07c1f07c1f08p-6, -0x1.f07c1f07c1f08p-61,
    0x1.d41d41d41d41dp-6, 0x1.0750750750750p-60,
    0x1.bacf914c1bad0p-6, -0x1.bacf914c1bad0p-60,
    0x1.a41a41a41a41ap-6, 0x1.0690690690690p-60,
    0x1.8f9c18f9c18fap-6, -0x1.f3831f3831f38p-61,
    0x1.7d05f417d05f4p-6, 0x1.7d05f417d05f4p-62,
    0x1.6c16c16c16c17p-6, -0x1.f49f49f49f49fp-61,
};

/* 2^r = sum (ln2)^i/i! * r^i, valid to ~2^-70 on |r| <= 1/2. Coefficients
 * are (hi, lo) pairs (same table as exp.c uses for exp2). */
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

/*==============================================================================
 * static double log2_dd(double x, double *lo)
 *------------------------------------------------------------------------------
 * Double-double base-2 logarithm: log2(x) = hi + *lo for finite x > 0.
 *
 * Parameters:
 *   x  (double)   - strictly positive, finite argument
 *   lo (double *) - out: low limb; log2(x) == result + *lo
 * Returns:
 *   The high limb of log2(x).
 * Special cases:
 *   Caller guarantees x > 0 and finite; x = 1 returns +0, subnormals reduce
 *   through the k stored by frexp.
 * Accuracy / algorithm:
 *   x is reduced to m*2^k with m in [sqrt(1/2), sqrt(2)), then
 *   log(m) = 2*atanh((m-1)/(m+1)) is evaluated as a double-double atanh series
 *   and scaled by the double-double 1/ln2; the integer k is added last so it
 *   never loses the correction. Roughly 2^-100 relative.
 *============================================================================*/
static double log2_dd(double x, double *lo)
{
    /* ---- reduction: x = m * 2^k with m in [sqrt(1/2), sqrt(2)) ---- */
    int k;
    double m = ASM_MATH(frexp)(x, &k);      /* m in [1/2, 1) */
    if (m < LOG_SQRT_HALF) {
        m *= 2.0;                           /* renormalise m upward ... */
        k -= 1;                             /* ... and account for 2^-1 */
    }

    /* ---- argument transform: s = (m-1)/(m+1), |s| <= 0.1716 ---- */
    double f = m - 1.0;                     /* exact, |f| <= 0.4143 */
    double dl;
    double dh = two_sum(1.0, m, &dl);       /* m + 1 as a double-double */

    double sh, sl;
    sh = dd_div(f, 0.0, dh, dl, &sl);       /* s = (m-1)/(m+1), |s| <= 0.1716 */

    /* ---- z = s*s, |z| <= 0.0295; the atanh series converges fast ---- */
    double zh, zl;
    zh = dd_mul(sh, sl, sh, sl, &zl);       /* z = s*s, |z| <= 0.0295 */

    /* ---- atanh series Q(z) = atanh(s)/s, degree 22 ---- */
    double qlo;
    double qhi = dd_poly(QC, 22, zh, zl, &qlo);

    /* ---- log(m) = 2*s*Q(z) ---- */
    double lh, ll;
    lh = dd_mul(sh, sl, qhi, qlo, &ll);     /* log(m) = 2*s*Q(z) */
    lh *= 2.0;                              /* include the factor 2 ... */
    ll *= 2.0;                              /* ... in both limbs */

    /* ---- log2(m) = log(m) / ln2 ---- */
    double p, pe;
    p = dd_mul(lh, ll, IVLN2_HI, IVLN2_LO, &pe);    /* log2(m) */

    /* ---- add the integer exponent k last, then renormalise ---- */
    double e;
    double Lh = two_sum((double)k, p, &e);  /* k + log2(m) */
    double Ll = e + pe;                     /* collect the low limbs */
    double Llo;
    Lh = two_sum(Lh, Ll, &Llo);             /* final hi + lo normalisation */
    *lo = Llo;
    return Lh;
}

/*------------------------------------------------------------------------------
 * Integer tests on y. Any double with magnitude >= 2^53 is an even integer,
 * so only smaller values need a parity check.
 *------------------------------------------------------------------------------*/

/*==============================================================================
 * static int is_integer(double y)
 *------------------------------------------------------------------------------
 * Test whether y represents a mathematical integer.
 *
 * Parameters:
 *   y (double) - value to test
 * Returns:
 *   1 when floor(y) == y, else 0 (also 0 for NaN/Inf).
 * Special cases:
 *   NaN and +-Inf are not integers; +-0.0 and -0.0 are.
 * Accuracy / algorithm:
 *   floor(y) == y is exact for |y| < 2^53 and remains correct for the
 *   integer-valued doubles above it.
 *============================================================================*/
static int is_integer(double y)
{
    return ASM_MATH(floor)(y) == y;
}

/*==============================================================================
 * static int is_odd_integer(double y)
 *------------------------------------------------------------------------------
 * Test whether y is an odd mathematical integer.
 *
 * Parameters:
 *   y (double) - value to test
 * Returns:
 *   1 when y is an odd integer, else 0.
 * Special cases:
 *   Non-integers, NaN/Inf and |y| >= 2^53 all return 0: every double with
 *   magnitude >= 2^53 is an even integer.
 * Accuracy / algorithm:
 *   Convert to long long only once |y| < 2^53, where the value is exactly
 *   representable, and test the low bit.
 *============================================================================*/
static int is_odd_integer(double y)
{
    if (!is_integer(y))
        return 0;                           /* non-integers are never odd */
    if (y >= 9007199254740992.0 || y <= -9007199254740992.0)
        return 0;                           /* |y| >= 2^53: always even */
    long long i = (long long)y;             /* exact: |y| < 2^53 */
    return (i & 1) != 0;                    /* odd iff the low bit is set */
}

/*==============================================================================
 * double ASM_MATH(pow)(double x, double y)
 *------------------------------------------------------------------------------
 * x^y, computed as 2^(y*log2(x)) with a double-double logarithm and product so
 * the final rounding stays faithful even when x is near 1 and |y| is large.
 *
 * Parameters:
 *   x (double) - base; any value, including NaN and +-Inf
 *   y (double) - exponent; any value, including NaN and +-Inf
 * Returns:
 *   x^y, following the C99 special-value rules below; a negative base with a
 *   non-integer exponent yields NaN (domain error, no errno).
 * Special cases (C99 / Annex F):
 *   - pow(x, +-0) = 1 and pow(1, y) = 1 for every x and y, even NaN.
 *   - pow(NaN, y) = NaN and pow(x, NaN) = NaN, except the two rules above.
 *   - pow(-1, +-Inf) = 1.
 *   - pow(+Inf, y) = +Inf for y > 0, +0 for y < 0.
 *   - pow(-Inf, y) = -Inf for y a positive odd integer, +Inf for other y > 0;
 *     -0 for y a negative odd integer, +0 for other y < 0.
 *   - pow(+0, y) = +0 for y > 0, +Inf for y < 0.
 *   - pow(-0, y) = -0 for y a positive odd integer, +0 for other y > 0;
 *     -Inf for y a negative odd integer, +Inf for other y < 0.
 *   - pow(x, +Inf) = +0 for |x| < 1, +Inf for |x| > 1.
 *   - pow(x, -Inf) = +Inf for |x| < 1, +0 for |x| > 1.
 *   - x < 0 with non-integer y is a domain error -> NaN.
 *   - Overflow returns +-Inf; underflow returns +-0, carrying the sign of an
 *     odd-integer exponent when the base is negative.
 * Accuracy / algorithm:
 *   log2_dd() reduction m*2^k with the double-double atanh series; the product
 *   y*log2(x) is held as a double-double, split into an integer k and a
 *   fraction f in [-1/2, 1/2], then reconstructed with a degree-18
 *   double-double 2^f polynomial and an exact scalbn. Faithful to < 1 ulp.
 *============================================================================*/
double ASM_MATH(pow)(double x, double y)
{
    /* ---- C99 special cases with priority over NaN handling ---- */
    /* C99: pow(x, +-0) = 1 and pow(1, y) = 1, even for NaN arguments. */
    if (y == 0.0 || x == 1.0)
        return 1.0;

    if (f64_isnan(x) || f64_isnan(y))
        return F64_QNAN;                    /* NaN base or exponent -> NaN */

    /* C99: pow(-1, +-Inf) = 1. */
    if (x == -1.0 && f64_isinf(y))
        return 1.0;

    /* ---- classify the exponent: integer? odd? ---- */
    int yint = is_integer(y);
    int yodd = yint ? is_odd_integer(y) : 0;

    /* ---- infinite exponent: |base| decides between Inf and 0 ---- */
    if (f64_isinf(y)) {
        double ax = ASM_MATH(fabs)(x);
        if (ax > 1.0)
            return y > 0 ? F64_INF : 0.0;   /* |x|>1: inf^+inf=inf, ^-inf=0 */
        return y > 0 ? 0.0 : F64_INF;       /* |x|<1: inf^+inf=0, ^-inf=inf */
    }

    /* ---- infinite base: sign and parity of y decide the result ---- */
    if (f64_isinf(x)) {
        if (!f64_signbit(x))
            return y > 0 ? F64_INF : 0.0;   /* +Inf: 0 < |result| ppt sign(y) */
        if (y > 0)
            return yodd ? -F64_INF : F64_INF;   /* -Inf^odd<0 ..., else +Inf */
        return yodd ? -0.0 : 0.0;           /* -Inf^odd = -0, else +0 */
    }

    /* ---- zero base: signed zero times exponent parity ---- */
    if (x == 0.0) {
        int negz = f64_signbit(x);          /* was it -0.0? */
        if (y > 0)
            return (negz && yodd) ? -0.0 : 0.0;     /* 0^+y = +0, (-0)^odd = -0 */
        return (negz && yodd) ? -F64_INF : F64_INF; /* 0^-y = +Inf, (-0)^odd = -Inf */
    }

    /* ---- negative base: only integral exponents are in the domain ---- */
    int negbase = f64_signbit(x);
    if (negbase && !yint)
        return F64_QNAN;                    /* non-integer power of negative */

    int neg = negbase && yodd;              /* sign of the final result */
    double ax = negbase ? -x : x;           /* reduce to the positive base |x| */

    /* ---- log2(|x|) as a double-double ---- */
    /* p = y*log2(|x|) as a double-double. */
    double Llo;
    double Lhi = log2_dd(ax, &Llo);

    /* ---- cheap overflow/underflow gate; keeps the integer split in range ---- */
    /* Cheap overflow/underflow gate; keeps the integer split in range. */
    double rough = y * Lhi;
    if (rough > 1200.0)
        return neg ? -F64_INF : F64_INF;    /* definite overflow */
    if (rough < -1200.0)
        return neg ? -0.0 : 0.0;            /* definite underflow */

    /* ---- p = y*log2(|x|), renormalised to a double-double ---- */
    double ph, pl;
    ph = two_prod(y, Lhi, &pl);             /* y*Lhi = ph + pl */
    pl += y * Llo;                          /* fold in y*Llo */
    double e;
    ph = two_sum(ph, pl, &e);               /* renormalise into ph + pl */
    pl = e;

    /* ---- split p = k + f with |f| <= 1/2; then 2^p = 2^k * 2^f ---- */
    /* p = k + f, |f| <= 1/2, then 2^p = 2^k * 2^f. */
    double kd = ASM_MATH(rint)(ph);
    int k = (int)kd;                        /* integer part, |k| <= 1200 */
    double fh = ph - kd;                    /* exact by Sterbenz */
    double fl = pl;                         /* low limb of the fraction */

    /* ---- 2^f by double-double polynomial, then exact scaling by 2^k ---- */
    double elo;
    double ehi = dd_poly(C2, 18, fh, fl, &elo);

    double mag = ASM_MATH(scalbn)(ehi + elo, k);
    return neg ? -mag : mag;                /* apply the sign parity */
}
