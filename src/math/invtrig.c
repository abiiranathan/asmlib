/*==============================================================================
 * invtrig.c - inverse trigonometric routines: asin, acos, atan, atan2
 *------------------------------------------------------------------------------
 * Freestanding, no libc/libm, no errno, no floating-point environment, no
 * mutable global state. Every helper below is static.
 *
 * These are the classic Sun fdlibm reductions, rewritten on top of the local
 * bit-punning helpers so they compile unchanged for wasm32 and x86-64:
 *
 *   atan(x): odd; |x| is folded into [0, 2.4375) by one of the table
 *            identities atan(v)+atan((x-v)/(1+v*x)) (v = 1/2, 1, 3/2) and
 *            |x| >= 2.4375 is handled as pi/2 - atan(1/x). The residual
 *            argument is evaluated with an 11-term minimax polynomial split
 *            into odd/even sums.
 *
 *   asin(x): |x| <= 0.5 uses asin(x) = x + x*x^2*R(x^2) with a rational
 *            minimax R; |x| > 0.5 uses the half-angle identity
 *            asin(x) = pi/2 - 2*asin(sqrt((1-|x|)/2)) with an exact split of
 *            sqrt so no cancellation reaches the result.
 *
 *   acos(x): central band |x| < 0.5 is pi/2 - asin(x) with a compensated
 *            pio2 subtraction; outside it is evaluated directly from the
 *            half-angle form so the result stays faithful all the way to the
 *            endpoints (acos(1) = 0, acos(-1) = pi).
 *
 *   atan2(y,x): the full IEEE special-case table for zeros, infinities and
 *            NaN, then atan(fabs(y/x)) placed in the correct quadrant with a
 *            double-double pi correction.
 *
 * All results are faithful (< 1 ulp); special values are exact.
 *============================================================================*/

#include "math_private.h"

/* --- word helpers -------------------------------------------------------- */

/*==============================================================================
 * static int32_t hi_word(double x)
 *------------------------------------------------------------------------------
 * High 32 bits of the IEEE-754 bit pattern of x: the sign bit, the 11 exponent
 * bits and the top 20 mantissa bits. Used with a mask for cheap sign and
 * exponent-range tests without any floating-point comparison.
 *
 * Parameters:
 *   x (double) - value whose high word is wanted
 * Returns:
 *   the high 32 bits reinterpreted as a signed int32_t (sign bit included)
 * Special cases:
 *   none; pure bit reinterpretation, no arithmetic and no trapping
 * Accuracy / algorithm:
 *   exact - one 64-bit shift and truncating conversion, no rounding
 *============================================================================*/
static int32_t hi_word(double x)
{
    return (int32_t)(f64_bits(x) >> 32);
}

/*==============================================================================
 * static uint32_t lo_word(double x)
 *------------------------------------------------------------------------------
 * Low 32 bits of the IEEE-754 bit pattern of x: the bottom 32 mantissa bits.
 * Combined with hi_word to test "is the whole pattern exactly this constant".
 *
 * Parameters:
 *   x (double) - value whose low word is wanted
 * Returns:
 *   the low 32 bits of the bit pattern, zero-extended into a uint32_t
 * Special cases:
 *   none; pure bit reinterpretation, no arithmetic and no trapping
 * Accuracy / algorithm:
 *   exact - one truncating conversion, no rounding
 *============================================================================*/
static uint32_t lo_word(double x)
{
    return (uint32_t)f64_bits(x);
}

/*==============================================================================
 * static double clear_low(double x)
 *------------------------------------------------------------------------------
 * SET_LOW_WORD(x, 0): zero the low 32 mantissa bits, as fdlibm does to break
 * sqrt(z) into a high part plus an exact correction.
 *
 * Parameters:
 *   x (double) - value to round down to its high 32-bit prefix
 * Returns:
 *   x with the low 32 mantissa bits forced to zero
 * Special cases:
 *   none; operates on the bit pattern, so NaN/Inf/+-0 pass through
 * Accuracy / algorithm:
 *   exact - the masked value is representable, and the discarded remainder
 *   feeds the exact double-double correction term (x - clear_low(x))
 *============================================================================*/
static double clear_low(double x)
{
    return f64_from_bits(f64_bits(x) & 0xffffffff00000000ULL);
}

/* --- shared constants ---------------------------------------------------- */

static const double
    pio2_hi = 1.57079632679489655800e+00,  /* pi/2, high half  0x3FF921FB54442D18 */
    pio2_lo = 6.12323399573676603587e-17,  /* pi/2, low half   0x3C91A62633145C07 */
    pio4_hi = 7.85398163397448278999e-01,  /* pi/4, high half  0x3FE921FB54442D18 */
    pi      = 3.14159265358979311600e+00,  /* pi               0x400921FB54442D18 */
    pi_lo   = 1.22464679914735317720e-16,  /* pi, low half     0x3CA1A62633145C07 */
    pi_o_4  = 7.85398163397448279000e-01,  /* pi/4  (atan2)                    */
    pi_o_2  = 1.57079632679489655800e+00;  /* pi/2  (atan2)                    */

/* atan(1/2), atan(1), atan(3/2), atan(inf) each split into a high and a low
 * double so the table addition keeps full precision. */
static const double atanhi[] = {
    4.63647609000806093515e-01,
    7.85398163397448278999e-01,
    9.82793723247329054082e-01,
    1.57079632679489655800e+00,
};

static const double atanlo[] = {
    2.26987774529616870924e-17,
    3.06161699786838301793e-17,
    1.39033110312309984516e-17,
    6.12323399573676603587e-17,
};

/* Minimax coefficients for atan on the residual interval (odd terms only). */
static const double aT[] = {
     3.33333333333329318027e-01,
    -1.99999999998764832476e-01,
     1.42857142725034663711e-01,
    -1.11111104054623557880e-01,
     9.09088713343650656196e-02,
    -7.69187620504482999495e-02,
     6.66107313738753120669e-02,
    -5.83357013379057348645e-02,
     4.97687799461593236017e-02,
    -3.65315727442169155270e-02,
     1.62858201153657823623e-02,
};

/* Rational minimax (asin(x)-x)/x^3 = p(t)/q(t), t = x^2, on |x| <= 0.5. */
static const double
    pS0 =  1.66666666666666657415e-01,
    pS1 = -3.25565818622400915405e-01,
    pS2 =  2.01212532134862925881e-01,
    pS3 = -4.00555345006794114027e-02,
    pS4 =  7.91534994289814532176e-04,
    pS5 =  3.47933107596021167570e-05,
    qS1 = -2.40339491173441421878e+00,
    qS2 =  2.02094576023350569471e+00,
    qS3 = -6.88283971605453293030e-01,
    qS4 =  7.70381505559019352791e-02;

/*==============================================================================
 * double ASM_MATH(atan)(double x)
 *------------------------------------------------------------------------------
 * Inverse tangent: the angle in (-pi/2, pi/2) whose tangent is x.
 *
 * Parameters:
 *   x (double) - any value: finite, infinite or NaN
 * Returns:
 *   atan(x) in radians, faithful (< 1 ulp); atan(±Inf) = ±pi/2 and
 *   atan(±0) = ±0 exactly
 * Special cases:
 *   NaN          -> NaN (quieted)
 *   +Inf         -> +pi/2              -Inf -> -pi/2
 *   +-0          -> +-0
 *   |x| < 2^-27  -> x (the polynomial correction is below the rounding step)
 * Accuracy / algorithm:
 *   faithful < 1 ulp; |x| is folded into [0, 0.4375) directly or, for larger
 *   |x|, into (-0.6875, 0.6875] with the table identity
 *   atan(v) + atan((x-v)/(1+v*x)) at v = 1/2, 1, 3/2; |x| >= 2.4375 is
 *   handled as pi/2 - atan(1/x). The residual is evaluated with an 11-term
 *   minimax polynomial split into odd/even sums.
 *============================================================================*/
double ASM_MATH(atan)(double x)
{
    double w, s1, s2, z;
    int32_t hx = hi_word(x);
    int32_t ix = hx & 0x7fffffff;
    int32_t id;

    /* ---- special cases: NaN and +-Inf ------------------------------- */
    if (ix >= 0x44100000) {                     /* |x| >= 2^66 */
        if (ix > 0x7ff00000 || (ix == 0x7ff00000 && lo_word(x) != 0))
            return x + x;                       /* NaN */
        return hx > 0 ? atanhi[3] + atanlo[3]   /* atan(+Inf) = +pi/2 */
                      : -atanhi[3] - atanlo[3]; /* atan(-Inf) = -pi/2 */
    }
    /* ---- small argument: |x| < 0.4375 needs no table reduction ------ */
    if (ix < 0x3fdc0000) {                      /* |x| < 0.4375 */
        if (ix < 0x3e400000)                    /* |x| < 2^-27 */
            return x;                           /* serves as atan(±0) = ±0 */
        id = -1;
    } else {
        /* ---- range reduction for 0.4375 <= |x| < 2^66 ---------------- */
        x = ASM_MATH(fabs)(x);                  /* work with |x| from here on */
        if (ix < 0x3ff30000) {                  /* |x| < 1.1875 */
            if (ix < 0x3fe60000) {              /* 7/16 <= |x| < 11/16 */
                id = 0;
                x = (2.0 * x - 1.0) / (2.0 + x);
            } else {                            /* 11/16 <= |x| < 19/16 */
                id = 1;
                x = (x - 1.0) / (x + 1.0);
            }
        } else {
            if (ix < 0x40038000) {              /* |x| < 2.4375 */
                id = 2;
                x = (x - 1.5) / (1.0 + 1.5 * x);
            } else {                            /* 2.4375 <= |x| < 2^66 */
                id = 3;
                x = -1.0 / x;                   /* atan(x) = pi/2 - atan(1/x) */
            }
        }
    }
    /* ---- minimax evaluation on the reduced |x| <= 0.6875 ------------ */
    z = x * x;
    w = z * z;
    s1 = z * (aT[0] + w * (aT[2] + w * (aT[4] + w * (aT[6] +
         w * (aT[8] + w * aT[10])))));
    s2 = w * (aT[1] + w * (aT[3] + w * (aT[5] + w * (aT[7] + w * aT[9]))));
    if (id < 0)
        return x - x * (s1 + s2);               /* atan(x) = x - x^3*(...) */
    /* ---- undo the table reduction, exact high+low correction -------- */
    z = atanhi[id] - ((x * (s1 + s2) - atanlo[id]) - x);
    return hx < 0 ? -z : z;                     /* restore the sign of x */
}

/*==============================================================================
 * double ASM_MATH(asin)(double x)
 *------------------------------------------------------------------------------
 * Inverse sine: the angle in [-pi/2, pi/2] whose sine is x.
 *
 * Parameters:
 *   x (double) - must satisfy |x| <= 1; NaN propagates
 * Returns:
 *   asin(x) in radians, faithful (< 1 ulp); asin(±1) = ±pi/2 and asin(±0) = ±0
 * Special cases:
 *   NaN         -> NaN (quieted)
 *   |x| > 1     -> NaN (domain error; no errno is set)
 *   asin(+1)    -> +pi/2           asin(-1) -> -pi/2
 *   +-0         -> +-0
 *   |x| < 2^-26 -> x (the rational correction is below the rounding step)
 * Accuracy / algorithm:
 *   faithful < 1 ulp; |x| <= 0.5 uses asin(x) = x + x*x^2*R(x^2) with a
 *   rational minimax R; |x| > 0.5 uses the half-angle identity
 *   asin(x) = pi/2 - 2*asin(sqrt((1-|x|)/2)), splitting sqrt into a high part
 *   plus an exact correction so no cancellation reaches the result.
 *============================================================================*/
double ASM_MATH(asin)(double x)
{
    double t, w, p, q, c, r, s;
    int32_t hx = hi_word(x);
    int32_t ix = hx & 0x7fffffff;
    uint32_t lx = lo_word(x);

    /* ---- special cases: |x| >= 1 (endpoints, out of domain, NaN) ---- */
    if (ix >= 0x3ff00000) {                     /* |x| >= 1 */
        if (((ix - 0x3ff00000) | (int32_t)lx) == 0)
            return x * pio2_hi + x * pio2_lo;   /* asin(±1) = ±pi/2 */
        return (x - x) / (x - x);               /* |x| > 1 or NaN -> NaN */
    }
    /* ---- central band: |x| < 0.5, direct rational approximation ------ */
    if (ix < 0x3fe00000) {                      /* |x| < 0.5 */
        if (ix < 0x3e500000)                    /* |x| < 2^-26 */
            return x;                           /* also asin(±0) = ±0 */
        t = x * x;
        p = t * (pS0 + t * (pS1 + t * (pS2 + t * (pS3 + t * (pS4 + t * pS5)))));
        q = 1.0 + t * (qS1 + t * (qS2 + t * (qS3 + t * qS4)));
        w = p / q;
        return x + x * w;                       /* asin(x) = x + x^3 * R(x^2) */
    }
    /* ---- half-angle identity for 0.5 <= |x| < 1 --------------------- */
    /* 0.5 <= |x| < 1: asin(x) = pi/2 - 2*asin(sqrt((1-|x|)/2)). */
    w = 1.0 - ASM_MATH(fabs)(x);
    t = w * 0.5;
    p = t * (pS0 + t * (pS1 + t * (pS2 + t * (pS3 + t * (pS4 + t * pS5)))));
    q = 1.0 + t * (qS1 + t * (qS2 + t * (qS3 + t * qS4)));
    s = ASM_MATH(sqrt)(t);
    if (ix >= 0x3FEF3333) {                     /* |x| > 0.975 */
        /* close to +-1: sqrt(t) is large enough that the plain form suffices */
        w = p / q;
        t = pio2_hi - (2.0 * (s + s * w) - pio2_lo);
    } else {
        /* ---- double-double split of sqrt(t) on the steeper band ------ */
        w = clear_low(s);                       /* high part of sqrt(t) */
        c = (t - w * w) / (s + w);              /* exact-ish correction */
        r = p / q;
        p = 2.0 * s * r - (pio2_lo - 2.0 * c);
        q = pio4_hi - 2.0 * w;
        t = pio4_hi - (p - q);
    }
    return hx > 0 ? t : -t;                     /* restore the sign of x */
}

/*==============================================================================
 * double ASM_MATH(acos)(double x)
 *------------------------------------------------------------------------------
 * Inverse cosine: the angle in [0, pi] whose cosine is x.
 *
 * Parameters:
 *   x (double) - must satisfy |x| <= 1; NaN propagates
 * Returns:
 *   acos(x) in radians, faithful (< 1 ulp); acos(1) = 0 and acos(-1) = pi
 *   exactly
 * Special cases:
 *   NaN          -> NaN (quieted)
 *   |x| > 1      -> NaN (domain error; no errno is set)
 *   acos(+1)     -> +0 (positive zero)
 *   acos(-1)     -> pi
 *   |x| < 2^-57  -> pi/2 to full precision
 * Accuracy / algorithm:
 *   faithful < 1 ulp; the central band |x| < 0.5 is pi/2 - asin(x) with a
 *   compensated pio2 subtraction; outside it the half-angle form
 *   acos(x) = 2*asin(sqrt((1-x)/2)) or pi - 2*asin(sqrt((1+x)/2)) is used
 *   directly so the result stays faithful all the way to the endpoints.
 *============================================================================*/
double ASM_MATH(acos)(double x)
{
    double z, p, q, r, w, s, c, df;
    int32_t hx = hi_word(x);
    int32_t ix = hx & 0x7fffffff;
    uint32_t lx = lo_word(x);

    /* ---- special cases: |x| >= 1 (endpoints, out of domain, NaN) ---- */
    if (ix >= 0x3ff00000) {                     /* |x| >= 1 */
        if (((ix - 0x3ff00000) | (int32_t)lx) == 0) {
            if (hx > 0)
                return 0.0;                     /* acos(1) = 0 */
            return pi + 2.0 * pio2_lo;          /* acos(-1) = pi */
        }
        return (x - x) / (x - x);               /* |x| > 1 or NaN -> NaN */
    }
    /* ---- central band: |x| < 0.5, acos(x) = pi/2 - asin(x) ---------- */
    if (ix < 0x3fe00000) {                      /* |x| < 0.5 */
        if (ix <= 0x3c600000)                   /* |x| < 2^-57 */
            return pio2_hi + pio2_lo;           /* pi/2 to full precision */
        z = x * x;
        p = z * (pS0 + z * (pS1 + z * (pS2 + z * (pS3 + z * (pS4 + z * pS5)))));
        q = 1.0 + z * (qS1 + z * (qS2 + z * (qS3 + z * qS4)));
        r = p / q;
        return pio2_hi - (x - (pio2_lo - x * r));   /* pi/2 - asin(x) */
    } else if (hx < 0) {                        /* x < -0.5 */
        /* ---- x in (-1, -0.5): acos(x) = pi - 2*asin(sqrt((1+x)/2)) -- */
        z = (1.0 + x) * 0.5;
        p = z * (pS0 + z * (pS1 + z * (pS2 + z * (pS3 + z * (pS4 + z * pS5)))));
        q = 1.0 + z * (qS1 + z * (qS2 + z * (qS3 + z * qS4)));
        s = ASM_MATH(sqrt)(z);
        r = p / q;
        w = r * s - pio2_lo;                    /* low-order pi/2 correction */
        return pi - 2.0 * (s + w);
    } else {                                    /* x > 0.5 */
        /* ---- x in (0.5, 1): acos(x) = 2*asin(sqrt((1-x)/2)) --------- */
        z = (1.0 - x) * 0.5;
        s = ASM_MATH(sqrt)(z);
        df = clear_low(s);                      /* high part of sqrt(z) */
        c = (z - df * df) / (s + df);           /* exact-ish correction */
        p = z * (pS0 + z * (pS1 + z * (pS2 + z * (pS3 + z * (pS4 + z * pS5)))));
        q = 1.0 + z * (qS1 + z * (qS2 + z * (qS3 + z * qS4)));
        r = p / q;
        w = r * s + c;
        return 2.0 * (df + w);                  /* 2*sqrt(z) with correction */
    }
}

/*==============================================================================
 * double ASM_MATH(atan2)(double y, double x)
 *------------------------------------------------------------------------------
 * Two-argument inverse tangent: the angle in (-pi, pi] made by the point
 * (x, y) with the positive x axis, with the full IEEE-754 special-case table.
 *
 * Parameters:
 *   y (double) - ordinate (numerator of the tangent)
 *   x (double) - abscissa (denominator of the tangent)
 * Returns:
 *   atan2(y, x) in radians, faithful (< 1 ulp); signed zeros, infinities and
 *   the exact multiples of pi/2 and pi/4 come back exactly
 * Special cases:
 *   NaN in either argument        -> NaN (quieted)
 *   y == +-0, x > 0               -> +-0
 *   y == +-0, x < 0 or x == -0    -> +-pi (sign follows y)
 *   y > 0,   x == +-0             -> +pi/2
 *   y < 0,   x == +-0             -> -pi/2
 *   y == +-Inf, x finite          -> +-pi/2 (sign follows y)
 *   y == +-Inf, x == +-Inf        -> +pi/4, +-3pi/4 by quadrant
 *   y finite, x == +Inf           -> +-0 (sign follows y)
 *   y finite, x == -Inf           -> +-pi (sign follows y)
 * Quadrants (m = 2*sx + sy, bit0 = sign of y, bit1 = sign of x):
 *   m=0 (x>0, y>=0) -> atan(y/x)        m=1 (x>0, y<0) -> -atan(|y/x|)
 *   m=2 (x<0, y>=0) -> pi + atan(y/x)   m=3 (x<0, y<0) -> -pi + atan(y/x)
 * Accuracy / algorithm:
 *   faithful < 1 ulp; |y/x| is formed in double and handed to atan, then the
 *   quadrant constant pi (or pi/2 when |y/x| > 2^60) is added with a
 *   double-double pi_lo correction.
 *============================================================================*/
double ASM_MATH(atan2)(double y, double x)
{
    double z;
    int32_t k, m;
    int32_t hx = hi_word(x);
    int32_t hy = hi_word(y);
    int32_t ix = hx & 0x7fffffff;
    int32_t iy = hy & 0x7fffffff;
    uint32_t lx = lo_word(x);
    uint32_t ly = lo_word(y);

    /* ---- NaN detection: either operand has a NaN bit pattern -------- */
    if (((ix | (int32_t)((lx | (0u - lx)) >> 31)) > 0x7ff00000) ||
        ((iy | (int32_t)((ly | (0u - ly)) >> 31)) > 0x7ff00000))
        return x + y;                           /* x or y is NaN */
    /* ---- fast path: x == 1.0 reduces to the one-argument atan --------- */
    if (hx == 0x3ff00000 && lx == 0)
        return ASM_MATH(atan)(y);               /* x == 1.0 -> atan(y) */

    /* quadrant/sign table index: bit0 = sign of y, bit1 = sign of x */
    m = (int32_t)((hy >> 31) & 1) | (int32_t)((hx >> 30) & 2);  /* 2*sx + sy */

    /* ---- y == +-0: result is +-0 or +-pi depending on the x sign ---- */
    if ((iy | (int32_t)ly) == 0) {              /* y == 0 */
        switch (m) {
        case 0:
        case 1: return y;                       /* atan2(±0, +anything) = ±0 */
        case 2: return pi;                      /* atan2(+0, -anything) = +pi */
        default: return -pi;                    /* atan2(-0, -anything) = -pi */
        }
    }
    /* ---- x == +-0: result is +-pi/2 (the y sign decides) ------------ */
    if ((ix | (int32_t)lx) == 0)                /* x == 0 */
        return hy < 0 ? -pi_o_2 : pi_o_2;

    /* ---- infinity handling, quadrants taken from m ------------------ */
    if (ix == 0x7ff00000) {                     /* x is ±Inf */
        if (iy == 0x7ff00000) {                 /* y is ±Inf too */
            switch (m) {
            case 0: return pi_o_4;              /* +pi/4  */
            case 1: return -pi_o_4;             /* -pi/4  */
            case 2: return 3.0 * pi_o_4;        /* +3pi/4 */
            default: return -3.0 * pi_o_4;      /* -3pi/4 */
            }
        } else {
            switch (m) {
            case 0: return 0.0;                 /* atan2(+.., +Inf) = +0 */
            case 1: return -0.0;                /* atan2(-.., +Inf) = -0 */
            case 2: return pi;                  /* atan2(+.., -Inf) = +pi */
            default: return -pi;                /* atan2(-.., -Inf) = -pi */
            }
        }
    }
    if (iy == 0x7ff00000)                       /* y is ±Inf, x finite */
        return hy < 0 ? -pi_o_2 : pi_o_2;

    /* ---- finite nonzero x and y: form atan(|y/x|) ------------------- */
    /* compute y/x with the quadrant angle */
    k = (iy - ix) >> 20;                        /* exponent gap of |y| and |x| */
    if (k > 60) {                               /* |y/x| > 2^60 */
        z = pi_o_2 + 0.5 * pi_lo;               /* saturate to pi/2 */
        m &= 1;                                 /* keep only the y-sign bit */
    } else if (hx < 0 && k < -60) {
        z = 0.0;                                /* 0 > |y|/x > -2^-60 */
    } else {
        z = ASM_MATH(atan)(ASM_MATH(fabs)(y / x));  /* safe to divide */
    }
    /* ---- place the angle in the correct quadrant -------------------- */
    switch (m) {
    case 0: return z;                           /* atan(+,+) */
    case 1: return -z;                          /* atan(-,+) */
    case 2: return pi - (z - pi_lo);            /* atan(+,-) */
    default: return (z - pi_lo) - pi;           /* atan(-,-) */
    }
}
