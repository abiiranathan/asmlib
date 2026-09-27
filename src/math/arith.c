/*==============================================================================
 * arith.c - exact floating-point remainder operations (fmod, remainder)
 *------------------------------------------------------------------------------
 * Freestanding, no libc. Both routines are exact: the result is produced by
 * binary long division on the normalized 53-bit significands, so there is no
 * rounding error anywhere in the reduction. Special values follow IEEE-754:
 *
 *   fmod(x,+/-0) = NaN, fmod(+/-Inf,y) = NaN, fmod(x,+/-Inf) = x, fmod(NaN,*)=NaN
 *   remainder(x,+/-0) = NaN, remainder(+/-Inf,y) = NaN,
 *   remainder(x,+/-Inf) = x, remainder(NaN,*) = NaN
 *
 * fmod carries the sign of x and has magnitude < |y|; remainder rounds the
 * quotient to nearest with ties to even, tracking the quotient's low bit so
 * exact .5 cases choose the even multiple. No errno, no FP environment, no
 * global state.
 *============================================================================*/

#include "math_private.h"

/*==============================================================================
 * static double signed_zero(double x)
 *------------------------------------------------------------------------------
 * A zero carrying the sign of x (fmod's result sign is always that of x).
 *
 * Parameters:
 *   x (double) - any value; only its sign bit is inspected
 * Returns:
 *   +0.0 when x is positive, -0.0 when x is negative, on every path
 * Special cases:
 *   x = +-0:   returns the same-signed zero (the sign bit is copied verbatim)
 *   x = +-Inf: returns the corresponding signed zero
 *   x = NaN:   would copy the NaN's sign bit; callers filter NaN beforehand
 * Accuracy / algorithm:
 *   exact: masks F64_SIGN out of the raw bit pattern
 *============================================================================*/
static double signed_zero(double x)
{
    return f64_from_bits(f64_bits(x) & F64_SIGN);
}

/*==============================================================================
 * double ASM_MATH(fmod)(double x, double y)
 *------------------------------------------------------------------------------
 * x - n*y for the integer n with the same sign as x/y and |n*y| <= |x|: the
 * C truncated remainder. Sign of x, magnitude strictly less than |y|.
 *
 * Parameters:
 *   x (double) - dividend; any value, but +-Inf/NaN produce NaN
 *   y (double) - divisor; any non-zero value, but NaN/0 produce NaN
 * Returns:
 *   the truncated remainder with x's sign and magnitude strictly below |y|;
 *   a signed zero when x is an exact multiple of y; x itself when |x| < |y|;
 *   NaN for the invalid operand combinations listed below
 * Special cases:
 *   fmod(+-Inf, y) = NaN, fmod(NaN, y) = NaN, fmod(x, NaN) = NaN
 *   fmod(x, +-0) = NaN
 *   fmod(x, +-Inf) = x
 *   |x| == |y| (both finite) -> signed zero carrying x's sign
 * Accuracy / algorithm:
 *   exact: binary long division of the normalized 53-bit significands; no
 *   rounding is performed at any step and no tie can arise
 *============================================================================*/
double ASM_MATH(fmod)(double x, double y)
{
    /* ---- operand unpacking: raw bits, biased exponents, sign of x ---- */
    uint64_t uxi = f64_bits(x);
    uint64_t uyi = f64_bits(y);
    int ex = (int)(uxi >> 52) & 0x7ff;  /* biased exponent of x */
    int ey = (int)(uyi >> 52) & 0x7ff;  /* biased exponent of y */
    int sx = (int)(uxi >> 63);          /* sign bit of x */
    uint64_t i;                         /* scratch difference */

    /* ---- special-case dispatch: zero divisor, NaN, or non-finite x ---- */
    /* y == 0, y == NaN, or x is Inf/NaN -> NaN.  (uyi << 1) == 0 discards the
     * sign bit and so tests y == +-0 without a floating comparison. */
    if ((uyi << 1) == 0 || f64_isnan(y) || ex == 0x7ff)
        return F64_QNAN;

    /* ---- |x| <= |y| shortcut: result is x, or signed zero on equality ---- */
    /* |x| <= |y|: the result is x, or a signed zero when the magnitudes match. */
    if ((uxi << 1) <= (uyi << 1)) {     /* compare magnitudes: sign bit shifted out */
        if ((uxi << 1) == (uyi << 1))   /* |x| == |y|: exactly one multiple */
            return signed_zero(x);
        return x;                       /* |x| < |y|: already fully reduced */
    }

    /* ---- significand normalization: leading bit at position 52 ---- */
    /* Normalize x and y to 53-bit significands with the leading bit at 52. */
    if (!ex) {
        /* Subnormal x: shift the fraction up until bit 63 sets, counting the
         * matching negative exponent in ex.  uxi << 12 aligns the top fraction
         * bit with the sign bit so a single test drives the loop. */
        for (i = uxi << 12; (i >> 63) == 0; ex--, i <<= 1)
            ;
        uxi <<= -ex + 1;
    } else {
        uxi &= F64_MANT;                /* strip the biased exponent field */
        uxi |= 1ULL << 52;              /* restore the implicit leading 1 */
    }
    if (!ey) {
        /* Same subnormal normalization applied to the divisor y. */
        for (i = uyi << 12; (i >> 63) == 0; ey--, i <<= 1)
            ;
        uyi <<= -ey + 1;
    } else {
        uyi &= F64_MANT;
        uyi |= 1ULL << 52;
    }

    /* ---- binary long division: one quotient bit per reduction step ---- */
    /* Binary long division: bring down one bit of the quotient per step. */
    for (; ex > ey; ex--) {
        i = uxi - uyi;
        if ((i >> 63) == 0) {           /* no borrow: uxi >= uyi */
            if (i == 0)
                return signed_zero(x);  /* exact multiple: remainder is zero */
            uxi = i;                    /* keep the reduced partial remainder */
        }
        uxi <<= 1;                      /* bring down the next bit of x */
    }
    /* Final subtraction at matching exponents; no shift follows. */
    i = uxi - uyi;
    if ((i >> 63) == 0) {
        if (i == 0)
            return signed_zero(x);
        uxi = i;
    }

    /* ---- renormalization: leading bit back to position 52 ---- */
    /* Renormalize the remainder so its leading bit sits at position 52. */
    for (; (uxi >> 52) == 0; uxi <<= 1, ex--)
        ;

    /* ---- sign/rounding adjustment and reconstruction ---- */
    /* Reassemble the result (normal, subnormal, or zero) with x's sign. */
    if (ex > 0) {
        uxi -= 1ULL << 52;              /* drop the implicit leading 1 */
        uxi |= (uint64_t)ex << 52;      /* pack in the biased exponent */
    } else {
        uxi >>= -ex + 1;                /* subnormal: align the fraction */
    }
    uxi |= (uint64_t)sx << 63;          /* final result carries x's sign */
    return f64_from_bits(uxi);
}

/*==============================================================================
 * double ASM_MATH(remainder)(double x, double y)
 *------------------------------------------------------------------------------
 * x - n*y where n is x/y rounded to the nearest integer (ties to even). The
 * reduction below is the same long division as fmod, but it keeps the low bit
 * of the quotient: a remainder exactly equal to |y|/2 pushes the quotient onto
 * a tie, and q%2 selects the even neighbour, matching IEEE-754.
 *
 * Parameters:
 *   x (double) - dividend; any value, but +-Inf/NaN produce NaN
 *   y (double) - divisor; any non-zero value, but NaN/0 produce NaN
 * Returns:
 *   the nearest-integer remainder, with magnitude <= |y|/2; its sign follows
 *   the selected multiple (so it may differ from x's sign); NaN for the
 *   invalid operand combinations listed below; x itself for x = +-0
 * Special cases:
 *   remainder(+-Inf, y) = NaN, remainder(NaN, y) = NaN, remainder(x, NaN) = NaN
 *   remainder(x, +-0) = NaN
 *   remainder(x, +-Inf) = x
 *   remainder(+-0, y) = +-0 (returned unchanged, preserving the sign)
 *   an exact |y|/2 remainder rounds to the even multiple (ties to even)
 * Accuracy / algorithm:
 *   exact: the same binary long division as fmod, retaining the quotient's low
 *   bit q%2 for the tie decision; no rounding error is introduced
 *============================================================================*/
double ASM_MATH(remainder)(double x, double y)
{
    /* ---- operand unpacking: bits, exponents and both signs ---- */
    uint64_t uxi = f64_bits(x);
    uint64_t uyi = f64_bits(y);
    int ex = (int)(uxi >> 52) & 0x7ff;  /* biased exponent of x */
    int ey = (int)(uyi >> 52) & 0x7ff;  /* biased exponent of y */
    int sx = (int)(uxi >> 63);          /* sign bit of x */
    int sy = (int)(uyi >> 63);          /* sign bit of y */
    uint32_t q = 0;                     /* quotient bits, low bit used for ties */
    uint64_t i;                         /* scratch difference */

    /* ---- special-case dispatch: zero divisor, NaN, or non-finite x ---- */
    /* y == 0, y == NaN, or x is Inf/NaN -> NaN. */
    if ((uyi << 1) == 0 || f64_isnan(y) || ex == 0x7ff)
        return F64_QNAN;
    if ((uxi << 1) == 0)                /* x == +/-0 -> x */
        return x;

    /* ---- significand normalization: leading bit at position 52 ---- */
    /* Normalize x and y to 53-bit significands with the leading bit at 52. */
    if (!ex) {
        /* Subnormal x: shift up until bit 63 sets, counting ex down. */
        for (i = uxi << 12; (i >> 63) == 0; ex--, i <<= 1)
            ;
        uxi <<= -ex + 1;
    } else {
        uxi &= F64_MANT;                /* strip the biased exponent field */
        uxi |= 1ULL << 52;              /* restore the implicit leading 1 */
    }
    if (!ey) {
        /* Same subnormal normalization applied to the divisor y. */
        for (i = uyi << 12; (i >> 63) == 0; ey--, i <<= 1)
            ;
        uyi <<= -ey + 1;
    } else {
        uyi &= F64_MANT;
        uyi |= 1ULL << 52;
    }

    /* ---- |x| < |y| fast path, deferring the rounding edge to `end` ---- */
    q = 0;
    if (ex < ey) {                      /* |x| < |y| */
        if (ex + 1 == ey)               /* but |x| may need rounding to y */
            goto end;                   /* defer to the tie logic at end */
        return x;                       /* strictly below |y|/2: return x */
    }

    /* ---- binary long division, accumulating the quotient bits in q ---- */
    /* Binary long division, accumulating the quotient bits in q. */
    for (; ex > ey; ex--) {
        i = uxi - uyi;
        if ((i >> 63) == 0) {           /* no borrow: this quotient bit is 1 */
            uxi = i;
            q++;
        }
        uxi <<= 1;                      /* bring down the next dividend bit */
        q <<= 1;                        /* make room for the next quotient bit */
    }
    /* Final subtraction at matching exponents. */
    i = uxi - uyi;
    if ((i >> 63) == 0) {
        uxi = i;
        q++;
    }

    /* ---- renormalization: leading bit back to position 52 ---- */
    /* Renormalize the remainder so its leading bit sits at position 52. */
    if (uxi == 0)
        ex = -60;                       /* exact cancellation: force a zero result */
    else
        for (; (uxi >> 52) == 0; uxi <<= 1, ex--)
            ;

end:
    /* ---- sign adjustment and reconstruction of the remainder ---- */
    /* Reassemble |x| from the reduced significand and its exponent. */
    if (ex > 0) {
        uxi -= 1ULL << 52;              /* drop the implicit leading 1 */
        uxi |= (uint64_t)ex << 52;      /* pack in the biased exponent */
    } else {
        uxi >>= -ex + 1;                /* subnormal: align the fraction */
    }
    x = f64_from_bits(uxi);             /* x is now the non-negative remainder */
    if (sy)
        y = -y;                         /* make y positive so `2x > y` tests |y|/2 */

    /* If the remainder is at least |y|/2, shift toward the nearer multiple;
     * on an exact tie use the low quotient bit to round to even. */
    if (ex == ey || (ex + 1 == ey && (2.0 * x > y || (2.0 * x == y && (q & 1))))) {
        x -= y;                         /* overshot |y|/2: step back one multiple */
        q++;
    }
    return sx ? -x : x;                 /* restore the sign of x */
}
